
create or replace function public.barberium_staff_performance(p_start_date date, p_end_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  v_permissions jsonb;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_summary jsonb;
  v_services jsonb;
  v_products jsonb;
  v_product_revenue bigint:=0;
  v_product_sales int:=0;
  v_product_units int:=0;
  v_service_realized bigint:=0;
  v_service_total bigint:=0;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_end_date<p_start_date or (p_end_date-p_start_date)>366 then raise exception 'Período inválido'; end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  v_permissions:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  if m.role='barber' and not barberium.permission_enabled(v_permissions,'view_own_revenue') then
    raise exception 'Sem permissão para ver faturamento';
  end if;

  select coalesce(timezone,'America/Sao_Paulo')
    into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  v_start:=p_start_date::timestamp at time zone v_tz;
  v_end:=(p_end_date+1)::timestamp at time zone v_tz;

  with ap as (
    select
      a.*,
      greatest(
        0,
        a.total_price_cents
        - coalesce((
            select sum(u.coverage_cents)
            from public.appointment_membership_uses u
            where u.appointment_id=a.id
              and (
                (a.status='confirmed' and u.status='reserved')
                or
                (a.status='completed' and u.status='consumed')
              )
          ),0)
      )::int cash_revenue_cents
    from public.appointments a
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and (m.role in ('owner','admin') or a.professional_id=m.professional_id)
  )
  select jsonb_build_object(
    'appointments',count(*),
    'confirmed',count(*) filter(where status='confirmed'),
    'completed',count(*) filter(where status='completed'),
    'cancelled',count(*) filter(where status='cancelled'),
    'no_show',count(*) filter(where status='no_show'),
    'scheduled_revenue_cents',coalesce(sum(cash_revenue_cents) filter(where status='confirmed'),0),
    'realized_revenue_cents',coalesce(sum(cash_revenue_cents) filter(where status='completed'),0),
    'total_revenue_cents',coalesce(sum(cash_revenue_cents) filter(where status in ('confirmed','completed')),0),
    'average_ticket_cents',
      case
        when count(*) filter(where status='completed')>0
          then round(
            coalesce(sum(cash_revenue_cents) filter(where status='completed'),0)::numeric
            /(count(*) filter(where status='completed'))
          )::int
        else 0
      end
  )
  into v_summary
  from ap;

  with ap as (
    select
      a.id,
      a.status,
      a.total_price_cents,
      a.service_id primary_service_id,
      coalesce(nullif(a.service_name_snapshot,''),s.name) primary_service,
      (
        coalesce(a.base_price_cents,0)
        +coalesce((
          select sum(aa.price_cents)
          from public.appointment_addons aa
          where aa.appointment_id=a.id and aa.item_kind='addon'
        ),0)
      )::int primary_listed,
      coalesce((
        select sum(u.coverage_cents)
        from public.appointment_membership_uses u
        where u.appointment_id=a.id
          and (
            (a.status='confirmed' and u.status='reserved')
            or
            (a.status='completed' and u.status='consumed')
          )
      ),0)::int coverage_total
    from public.appointments a
    join public.services s on s.id=a.service_id
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and a.status in ('confirmed','completed')
      and (m.role in ('owner','admin') or a.professional_id=m.professional_id)
  ),
  components as (
    select
      ap.id appointment_id,
      ap.status,
      ap.primary_service_id service_id,
      ap.primary_service service,
      ap.primary_listed listed_weight,
      coalesce((
        select sum(u.coverage_cents)
        from public.appointment_membership_uses u
        where u.appointment_id=ap.id
          and (
            (ap.status='confirmed' and u.status='reserved')
            or
            (ap.status='completed' and u.status='consumed')
          )
          and (
            u.target_service_id=ap.primary_service_id
            or exists(
              select 1
              from public.appointment_addons ax
              where ax.appointment_id=ap.id
                and ax.item_kind='addon'
                and ax.service_id=u.target_service_id
            )
          )
      ),0)::int coverage_cents,
      1::int is_primary,
      greatest(0,ap.total_price_cents-ap.coverage_total)::int cash_total
    from ap

    union all

    select
      ap.id,
      ap.status,
      aa.service_id,
      aa.name_snapshot,
      aa.price_cents::int,
      coalesce((
        select sum(u.coverage_cents)
        from public.appointment_membership_uses u
        where u.appointment_id=ap.id
          and (
            (ap.status='confirmed' and u.status='reserved')
            or
            (ap.status='completed' and u.status='consumed')
          )
          and u.target_service_id=aa.service_id
      ),0)::int,
      0::int,
      greatest(0,ap.total_price_cents-ap.coverage_total)::int
    from ap
    join public.appointment_addons aa
      on aa.appointment_id=ap.id and aa.item_kind='service'
  ),
  weighted as (
    select
      c.*,
      greatest(0,c.listed_weight-c.coverage_cents)::int cash_weight,
      sum(greatest(0,c.listed_weight-c.coverage_cents))
        over(partition by c.appointment_id)::numeric total_cash_weight
    from components c
  ),
  extras_alloc as (
    select
      w.*,
      case
        when w.is_primary=0 and w.cash_total>0 and w.total_cash_weight>0
          then floor(w.cash_total::numeric*w.cash_weight::numeric/w.total_cash_weight)::int
        else 0
      end allocated_cents
    from weighted w
    where w.is_primary=0
  ),
  component_rows as (
    select
      w.appointment_id,
      w.status,
      w.service_id,
      w.service,
      greatest(
        0,
        w.cash_total
        -coalesce((
          select sum(e.allocated_cents)
          from extras_alloc e
          where e.appointment_id=w.appointment_id
        ),0)
      )::int allocated_cents
    from weighted w
    where w.is_primary=1

    union all

    select
      e.appointment_id,
      e.status,
      e.service_id,
      e.service,
      e.allocated_cents
    from extras_alloc e
  ),
  grouped as (
    select
      service_id,
      service,
      count(*)::int appointments,
      count(*) filter(where status='completed')::int completed,
      coalesce(sum(allocated_cents) filter(where status='confirmed'),0)::bigint scheduled,
      coalesce(sum(allocated_cents) filter(where status='completed'),0)::bigint realized
    from component_rows
    group by service_id,service
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'service_id',service_id,
        'service',service,
        'appointments',appointments,
        'completed',completed,
        'scheduled_revenue_cents',scheduled,
        'realized_revenue_cents',realized
      )
      order by appointments desc,service
    ),
    '[]'::jsonb
  )
  into v_services
  from grouped;

  select
    coalesce(sum(ps.total_cents),0)::bigint,
    count(*)::int
  into v_product_revenue,v_product_sales
  from public.product_sales ps
  where ps.barbershop_id=m.barbershop_id
    and ps.status='completed'
    and ps.completed_at>=v_start
    and ps.completed_at<v_end
    and (m.role in ('owner','admin') or ps.seller_professional_id=m.professional_id);

  select coalesce(sum(psi.quantity),0)::int
  into v_product_units
  from public.product_sales ps
  join public.product_sale_items psi on psi.sale_id=ps.id
  where ps.barbershop_id=m.barbershop_id
    and ps.status='completed'
    and ps.completed_at>=v_start
    and ps.completed_at<v_end
    and (m.role in ('owner','admin') or ps.seller_professional_id=m.professional_id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'product_id',q.product_id,
        'product',q.product,
        'quantity',q.quantity,
        'revenue_cents',q.revenue_cents
      )
      order by q.revenue_cents desc,q.quantity desc,q.product
    ),
    '[]'::jsonb
  )
  into v_products
  from (
    select
      psi.product_id,
      max(psi.product_name_snapshot) product,
      sum(psi.quantity)::int quantity,
      sum(psi.line_total_cents)::bigint revenue_cents
    from public.product_sales ps
    join public.product_sale_items psi on psi.sale_id=ps.id
    where ps.barbershop_id=m.barbershop_id
      and ps.status='completed'
      and ps.completed_at>=v_start
      and ps.completed_at<v_end
      and (m.role in ('owner','admin') or ps.seller_professional_id=m.professional_id)
    group by psi.product_id
  ) q;

  v_service_realized:=coalesce((v_summary->>'realized_revenue_cents')::bigint,0);
  v_service_total:=coalesce((v_summary->>'total_revenue_cents')::bigint,0);

  v_summary:=v_summary||jsonb_build_object(
    'service_realized_revenue_cents',v_service_realized,
    'product_revenue_cents',v_product_revenue,
    'product_sales',v_product_sales,
    'product_units',v_product_units,
    'realized_revenue_cents',v_service_realized+v_product_revenue,
    'total_revenue_cents',v_service_total+v_product_revenue
  );

  return jsonb_build_object(
    'start_date',p_start_date,
    'end_date',p_end_date,
    'scope',case when m.role='barber' then 'own' else 'shop' end,
    'summary',v_summary,
    'services',v_services,
    'products',v_products
  );
end
$function$;

revoke all on function public.barberium_staff_performance(date,date) from public,anon;
grant execute on function public.barberium_staff_performance(date,date) to authenticated,service_role;

