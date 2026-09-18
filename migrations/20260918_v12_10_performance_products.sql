-- Barberium v12.10 — produtos no Resumo/Desempenho.
-- Backend de produção já recebeu esta migration.
-- Mantém as métricas de serviços existentes e acrescenta produtos concluídos.

create or replace function public.barberium_staff_performance(p_start_date date, p_end_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'barberium', 'auth', 'pg_temp'
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

  select jsonb_build_object(
    'appointments',count(*),
    'confirmed',count(*) filter(where a.status='confirmed'),
    'completed',count(*) filter(where a.status='completed'),
    'cancelled',count(*) filter(where a.status='cancelled'),
    'no_show',count(*) filter(where a.status='no_show'),
    'scheduled_revenue_cents',coalesce(sum(a.total_price_cents) filter(where a.status='confirmed'),0),
    'realized_revenue_cents',coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0),
    'total_revenue_cents',coalesce(sum(a.total_price_cents) filter(where a.status in ('confirmed','completed')),0),
    'average_ticket_cents',
      case
        when count(*) filter(where a.status='completed')>0
          then round(
            coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0)::numeric
            /(count(*) filter(where a.status='completed'))
          )::int
        else 0
      end
  )
  into v_summary
  from public.appointments a
  where a.barbershop_id=m.barbershop_id
    and a.starts_at>=v_start
    and a.starts_at<v_end
    and (m.role in ('owner','admin') or a.professional_id=m.professional_id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'service',q.service,
        'appointments',q.appointments,
        'completed',q.completed,
        'scheduled_revenue_cents',q.scheduled,
        'realized_revenue_cents',q.realized
      )
      order by q.appointments desc,q.service
    ),
    '[]'::jsonb
  )
  into v_services
  from (
    select
      coalesce(a.service_name_snapshot,s.name) service,
      count(*) appointments,
      count(*) filter(where a.status='completed') completed,
      coalesce(sum(a.total_price_cents) filter(where a.status='confirmed'),0)::bigint scheduled,
      coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0)::bigint realized
    from public.appointments a
    join public.services s on s.id=a.service_id
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and a.status in ('confirmed','completed')
      and (m.role in ('owner','admin') or a.professional_id=m.professional_id)
    group by coalesce(a.service_name_snapshot,s.name)
  ) q;

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
