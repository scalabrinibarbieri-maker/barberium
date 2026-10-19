
do $patch$
declare
  v_def text;
  v_start int;
  v_end int;
  v_new text := $new$
 if exists(select 1 from public.appointment_addons aa where aa.appointment_id=a.id and aa.item_kind='service') then
   declare
     v_default_pct numeric:=0;
     v_commission_base_total int:=0;
     v_fee_total int:=0;
     v_remaining_base int:=0;
     r record;
     v_component_base int:=0;
   begin
     select coalesce(cp.default_percent,0),
            coalesce(cp.basis,(select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross')
       into v_default_pct,basis
     from public.commission_profiles cp
     where cp.professional_id=a.professional_id;

     if not found then
       v_default_pct:=0;
       basis:=coalesce((select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross');
     end if;

     select coalesce(sum(fee_cents),0)::int
       into v_fee_total
     from public.appointment_payments
     where appointment_id=a.id;

     v_commission_base_total:=case when basis='net' then greatest(0,sum_paid-v_fee_total) else sum_paid end;
     v_remaining_base:=v_commission_base_total;

     for r in
       with primary_component as (
         select
           a.service_id,
           coalesce(nullif(a.service_name_snapshot,''),s.name) service_name,
           (
             coalesce(a.base_price_cents,0)
             +coalesce((
               select sum(aa.price_cents)
               from public.appointment_addons aa
               where aa.appointment_id=a.id and aa.item_kind='addon'
             ),0)
           )::int listed_weight,
           greatest(0,
             coalesce(a.base_price_cents,0)
             +coalesce((
               select sum(aa.price_cents)
               from public.appointment_addons aa
               where aa.appointment_id=a.id and aa.item_kind='addon'
             ),0)
             -coalesce((
               select sum(amu.coverage_cents)
               from public.appointment_membership_uses amu
               where amu.appointment_id=a.id
                 and amu.status='consumed'
                 and (
                   amu.target_service_id=a.service_id
                   or exists(
                     select 1 from public.appointment_addons ax
                     where ax.appointment_id=a.id
                       and ax.item_kind='addon'
                       and ax.service_id=amu.target_service_id
                   )
                 )
             ),0)
           )::int cash_weight,
           1::int sort_order
         from public.services s
         where s.id=a.service_id
       ),
       extra_components as (
         select
           aa.service_id,
           aa.name_snapshot service_name,
           aa.price_cents::int listed_weight,
           greatest(0,
             aa.price_cents
             -coalesce((
               select sum(amu.coverage_cents)
               from public.appointment_membership_uses amu
               where amu.appointment_id=a.id
                 and amu.status='consumed'
                 and amu.target_service_id=aa.service_id
             ),0)
           )::int cash_weight,
           0::int sort_order
         from public.appointment_addons aa
         where aa.appointment_id=a.id and aa.item_kind='service'
       ),
       all_components as (
         select * from extra_components
         union all
         select * from primary_component
       ),
       weighted as (
         select c.*,
           sum(cash_weight) over() total_cash_weight,
           sum(listed_weight) over() total_listed_weight
         from all_components c
       ),
       normalized as (
         select *,
           case
             when total_cash_weight>0 then cash_weight
             when total_listed_weight>0 then listed_weight
             when sort_order=1 then 1
             else 0
           end::numeric weight,
           case
             when total_cash_weight>0 then total_cash_weight
             when total_listed_weight>0 then total_listed_weight
             else 1
           end::numeric total_weight
         from weighted
       )
       select n.*,
         row_number() over(order by sort_order,service_name,service_id) rn,
         count(*) over() cnt
       from normalized n
       order by sort_order,service_name,service_id
     loop
       if r.rn=r.cnt then
         v_component_base:=greatest(0,v_remaining_base);
       else
         v_component_base:=least(
           greatest(0,v_remaining_base),
           greatest(0,round(v_commission_base_total*(r.weight/nullif(r.total_weight,0)))::int)
         );
       end if;
       v_remaining_base:=v_remaining_base-v_component_base;

       select coalesce(csr.mode,'percent'),coalesce(csr.percent,v_default_pct,0)
         into mode,pct
       from (select 1) q
       left join public.commission_service_rules csr
         on csr.professional_id=a.professional_id
        and csr.service_id=r.service_id;

       if mode<>'none' and coalesce(pct,0)>0 and v_component_base>0 then
         commission_amt:=round(v_component_base*(pct/100.0))::int;
         if commission_amt<>0 then
           insert into public.commission_entries(
             barbershop_id,unit_id,professional_id,appointment_id,
             source_type,source_id,description,base_cents,rate_percent,amount_cents
           )
           values(
             m.barbershop_id,a.unit_id,a.professional_id,a.id,
             'service',r.service_id,'Comissão de atendimento • '||r.service_name,
             v_component_base,pct,commission_amt
           );
         end if;
       end if;
     end loop;
   end;
 else
   select coalesce(csr.mode,'percent'),coalesce(csr.percent,cp.default_percent,0),coalesce(cp.basis,(select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross')
     into mode,pct,basis
   from public.commission_profiles cp
   left join public.commission_service_rules csr
     on csr.professional_id=cp.professional_id and csr.service_id=a.service_id
   where cp.professional_id=a.professional_id;

   if mode is null then mode:='percent'; pct:=0; end if;

   if mode<>'none' and coalesce(pct,0)>0 then
     base_commission:=sum_paid;
     if basis='net' then
       base_commission:=sum_paid-coalesce((select sum(fee_cents) from public.appointment_payments where appointment_id=a.id),0);
     end if;
     commission_amt:=round(base_commission*(pct/100.0))::int;
     if commission_amt<>0 then
       insert into public.commission_entries(
         barbershop_id,unit_id,professional_id,appointment_id,
         source_type,source_id,description,base_cents,rate_percent,amount_cents
       )
       values(
         m.barbershop_id,a.unit_id,a.professional_id,a.id,
         'service',a.service_id,'Comissão de atendimento',
         base_commission,pct,commission_amt
       );
     end if;
   end if;
 end if;
$new$;
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='barberium' and p.proname='complete_service_v123';

  if v_def is null then raise exception 'complete_service_v123 não encontrada'; end if;

  v_start:=strpos(v_def,' select coalesce(csr.mode');
  v_end:=strpos(v_def,' insert into public.appointment_events');

  if v_start=0 or v_end=0 or v_end<=v_start then
    raise exception 'Trecho de comissão não encontrado';
  end if;

  v_def:=substr(v_def,1,v_start-1)||v_new||substr(v_def,v_end);
  execute v_def;
end
$patch$;

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
      )::int primary_listed
    from public.appointments a
    join public.services s on s.id=a.service_id
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and a.status in ('confirmed','completed')
      and (m.role in ('owner','admin') or a.professional_id=m.professional_id)
  ),
  extras as (
    select
      ap.id appointment_id,
      aa.service_id,
      aa.name_snapshot service,
      aa.price_cents::int listed_cents,
      case
        when (ap.primary_listed+coalesce((
          select sum(ax.price_cents)
          from public.appointment_addons ax
          where ax.appointment_id=ap.id and ax.item_kind='service'
        ),0))>0
        then round(
          ap.total_price_cents::numeric
          * aa.price_cents::numeric
          / (ap.primary_listed+coalesce((
              select sum(ax.price_cents)
              from public.appointment_addons ax
              where ax.appointment_id=ap.id and ax.item_kind='service'
            ),0))::numeric
        )::int
        else 0
      end allocated_cents
    from ap
    join public.appointment_addons aa
      on aa.appointment_id=ap.id and aa.item_kind='service'
  ),
  component_rows as (
    select
      ap.id appointment_id,
      ap.status,
      ap.primary_service_id service_id,
      ap.primary_service service,
      (
        ap.total_price_cents
        -coalesce((select sum(e.allocated_cents) from extras e where e.appointment_id=ap.id),0)
      )::int allocated_cents
    from ap

    union all

    select
      ap.id,
      ap.status,
      e.service_id,
      e.service,
      e.allocated_cents
    from ap
    join extras e on e.appointment_id=ap.id
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

