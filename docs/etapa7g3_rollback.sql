-- Barberium · Etapa 7g (parte 3) · Relatório numa função só · ROLLBACK
-- Volta o Relatório às três camadas de antes da migration 20261026100000: recria as duas funções de
-- baixo (só para o service_role, como antes) e o Relatório que chama a de cima. Nenhum dado muda.
--
-- Ordem:
--   1. Supabase, SQL Editor: rode este arquivo inteiro. Ou entra tudo, ou nada.
--   2. Repositório: apague supabase/migrations/20261026100000_relatorio_numa_funcao.sql.

begin;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_report_v12_8_raw(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; v_overview jsonb; v_unit_name text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Relatórios financeiros restritos ao ADM'; end if;
  if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if;
  if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
  if p_unit_id is not null then
    select u.name into v_unit_name from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id;
    if v_unit_name is null then raise exception 'Unidade inválida'; end if;
  else v_unit_name:='Consolidado da empresa'; end if;
  v_overview:=public.barberium_staff_finance_overview(p_start,p_end,p_unit_id,p_basis);
  return jsonb_build_object(
    'meta',jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'unit_id',p_unit_id,'unit_name',v_unit_name,'generated_at',now()),
    'overview',v_overview,
    'payments',coalesce((select jsonb_agg(x order by (x->>'date')::timestamptz desc) from (
      select jsonb_build_object('id',ap.id,'source_type','appointment','date',ap.received_at,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'method',ap.method,'provider',pp.name,'installments',ap.installments,'amount_cents',ap.amount_cents,'fee_cents',ap.fee_cents,'net_cents',ap.amount_cents-ap.fee_cents,'note',ap.note) x
      from public.appointment_payments ap join public.appointments a on a.id=ap.appointment_id join public.units u on u.id=ap.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id left join public.payment_providers pp on pp.id=ap.provider_id
      where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
      union all
      select jsonb_build_object('id',mpay.id,'source_type','membership','date',mpay.paid_at,'unit',u.name,'customer',c.full_name,'service',case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,'professional',null,'method',mpay.method,'provider',pp.name,'installments',mpay.installments,'amount_cents',mpay.amount_cents,'fee_cents',mpay.fee_cents,'net_cents',mpay.amount_cents-mpay.fee_cents,'note',null) x
      from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id join public.customers c on c.id=cm.customer_id join public.membership_plans pl on pl.id=cm.plan_id left join public.units u on u.id=cm.origin_unit_id left join public.payment_providers pp on pp.id=mpay.provider_id
      where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      union all
      select jsonb_build_object('id',pay.id,'source_type','product','date',pay.received_at,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'method',pay.method,'provider',pp.name,'installments',pay.installments,'amount_cents',pay.amount_cents,'fee_cents',pay.fee_cents,'net_cents',pay.amount_cents-pay.fee_cents,'note',pay.note)
      from public.product_sale_payments pay join public.product_sales ps on ps.id=pay.sale_id join public.units u on u.id=ps.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id left join public.payment_providers pp on pp.id=pay.provider_id
      where ps.barbershop_id=m.barbershop_id and pay.received_at::date between p_start and p_end and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) q),'[]'::jsonb),
    'accrual_revenue',coalesce((select jsonb_agg(x order by (x->>'date')::timestamptz desc) from (
      select jsonb_build_object('appointment_id',a.id,'source_type','appointment','date',a.starts_at,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'amount_cents',case when a.status='cancelled' then coalesce((select (ev.details->>'service_due_cents')::int from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund' order by ev.created_at desc limit 1),a.total_price_cents) else greatest(0,a.total_price_cents-coalesce((select sum(u.coverage_cents) from public.appointment_membership_uses u where u.appointment_id=a.id and u.status='consumed'),0)) end) x
      from public.appointments a join public.units u on u.id=a.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id
      where a.barbershop_id=m.barbershop_id and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund')) and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select jsonb_build_object('appointment_id',null,'source_type','membership','date',mpay.paid_at,'unit',u.name,'customer',c.full_name,'service',case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,'professional',null,'amount_cents',mpay.amount_cents) x
      from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id join public.customers c on c.id=cm.customer_id join public.membership_plans pl on pl.id=cm.plan_id left join public.units u on u.id=cm.origin_unit_id
      where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      union all
      select jsonb_build_object('appointment_id',ps.appointment_id,'source_type','product','date',ps.completed_at,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'amount_cents',ps.total_cents)
      from public.product_sales ps join public.units u on u.id=ps.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id
      where ps.barbershop_id=m.barbershop_id and ps.status in ('completed','refunded') and ps.completed_at::date between p_start and p_end and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) q),'[]'::jsonb),
    'refunds',coalesce((select jsonb_agg(jsonb_build_object('id',fr.id,'date',fr.created_at,'unit',u.name,'source_type',case when fr.product_sale_id is not null then 'product' when fr.membership_id is not null then 'membership' else 'appointment' end,'customer',coalesce(pc.full_name,mc.full_name,ac.full_name),'description',coalesce(case when fr.product_sale_id is not null then 'Produtos' end,case when cm.plan_type='subscription' then 'Assinatura: '||mpl.name when cm.plan_type='package' then 'Pacote: '||mpl.name end,asv.name),'method',fr.refund_method,'amount_cents',fr.amount_cents,'reason',fr.reason) order by fr.created_at desc)
      from public.finance_refunds fr join public.units u on u.id=fr.unit_id left join public.customer_memberships cm on cm.id=fr.membership_id left join public.membership_plans mpl on mpl.id=cm.plan_id left join public.customers mc on mc.id=cm.customer_id left join public.appointments aa on aa.id=fr.appointment_id left join public.customers ac on ac.id=aa.customer_id left join public.services asv on asv.id=aa.service_id left join public.product_sales ps on ps.id=fr.product_sale_id left join public.customers pc on pc.id=ps.customer_id
      where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id)),'[]'::jsonb),
    'expenses',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'unit',u.name,'category',ec.name,'description',e.description,'amount_cents',e.amount_cents,'due_date',e.due_date,'status',e.status,'payment_method',e.payment_method,'paid_from_cash',e.paid_from_cash,'paid_at',e.paid_at,'note',e.note) order by e.due_date desc,e.created_at desc) from public.expenses e join public.units u on u.id=e.unit_id left join public.expense_categories ec on ec.id=e.category_id where e.barbershop_id=m.barbershop_id and (e.due_date between p_start and p_end or (e.paid_at is not null and e.paid_at::date between p_start and p_end)) and (p_unit_id is null or e.unit_id=p_unit_id)),'[]'::jsonb),
    'commissions',coalesce((select jsonb_agg(jsonb_build_object('id',ce.id,'date',ce.created_at,'unit',u.name,'professional',pr.name,'source_type',ce.source_type,'description',ce.description,'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,'amount_cents',ce.amount_cents,'status',ce.status) order by ce.created_at desc) from public.commission_entries ce join public.units u on u.id=ce.unit_id join public.professionals pr on pr.id=ce.professional_id where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)),'[]'::jsonb),
    'receivables',coalesce((select jsonb_agg(jsonb_build_object('appointment_id',ar.appointment_id,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'original_due_cents',ar.original_due_cents,'paid_cents',ar.paid_cents,'open_cents',case when ar.status='cancelled' then 0 else greatest(0,ar.original_due_cents-ar.paid_cents) end,'status',ar.status,'due_date',ar.due_date,'note',ar.note,'created_at',ar.created_at) order by coalesce(ar.due_date,ar.created_at::date),ar.created_at) from public.appointment_receivables ar join public.appointments a on a.id=ar.appointment_id join public.units u on u.id=ar.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id where ar.barbershop_id=m.barbershop_id and ar.created_at::date<=p_end and (p_unit_id is null or ar.unit_id=p_unit_id)),'[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('sale_id',r.sale_id,'source_type','product','appointment_id',ps.appointment_id,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'original_due_cents',r.original_due_cents,'paid_cents',r.paid_cents,'open_cents',case when r.status='cancelled' then 0 else greatest(0,r.original_due_cents-r.paid_cents) end,'status',r.status,'due_date',r.due_date,'note',r.note,'created_at',r.created_at)) from public.product_sale_receivables r join public.product_sales ps on ps.id=r.sale_id join public.units u on u.id=r.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id where r.barbershop_id=m.barbershop_id and r.created_at::date<=p_end and (p_unit_id is null or r.unit_id=p_unit_id)),'[]'::jsonb),
    'cash_sessions',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'unit',u.name,'status',cs.status,'opening_balance_cents',cs.opening_balance_cents,'opened_at',cs.opened_at,'expected_closing_cents',cs.expected_closing_cents,'counted_closing_cents',cs.counted_closing_cents,'difference_cents',cs.difference_cents,'closing_justification',cs.closing_justification,'closed_at',cs.closed_at) order by cs.opened_at desc) from public.cash_sessions cs join public.units u on u.id=cs.unit_id where cs.barbershop_id=m.barbershop_id and cs.opened_at::date<=p_end and coalesce(cs.closed_at::date,p_end)>=p_start and (p_unit_id is null or cs.unit_id=p_unit_id)),'[]'::jsonb),
    'cash_movements',coalesce((select jsonb_agg(jsonb_build_object('id',mov.id,'date',mov.created_at,'unit',u.name,'type',mov.movement_type,'amount_cents',mov.amount_cents,'reference_type',mov.reference_type,'note',mov.note) order by mov.created_at desc) from public.cash_movements mov join public.units u on u.id=mov.unit_id where mov.barbershop_id=m.barbershop_id and mov.created_at::date between p_start and p_end and (p_unit_id is null or mov.unit_id=p_unit_id)),'[]'::jsonb),
    'by_provider',coalesce((select jsonb_agg(jsonb_build_object('provider',provider,'method',method,'installments',installments,'gross_cents',gross_cents,'fees_cents',fees_cents,'net_cents',gross_cents-fees_cents,'transactions',transactions) order by gross_cents desc) from (
      select provider,method,installments,sum(amount_cents)::int gross_cents,sum(fee_cents)::int fees_cents,count(*)::int transactions from (
        select coalesce(pp.name,'Sem provedor') provider,ap.method,coalesce(ap.installments,1) installments,ap.amount_cents,ap.fee_cents from public.appointment_payments ap left join public.payment_providers pp on pp.id=ap.provider_id where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
        union all
        select coalesce(pp.name,'Sem provedor'),mpay.method,coalesce(mpay.installments,1),mpay.amount_cents,mpay.fee_cents from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id left join public.payment_providers pp on pp.id=mpay.provider_id where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
        union all
        select coalesce(pp.name,'Sem provedor'),pay.method,coalesce(pay.installments,1),pay.amount_cents,pay.fee_cents from public.product_sale_payments pay left join public.payment_providers pp on pp.id=pay.provider_id where pay.barbershop_id=m.barbershop_id and pay.received_at::date between p_start and p_end and (p_unit_id is null or pay.unit_id=p_unit_id)
      ) z group by provider,method,installments
    ) q),'[]'::jsonb),
    'by_unit',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'unit',u.name,'gross_cents',coalesce(x.gross_cents,0),'fees_cents',coalesce(x.fees_cents,0),'net_cents',coalesce(x.gross_cents,0)-coalesce(x.fees_cents,0)) order by u.name) from public.units u left join lateral (
      select sum(amount_cents)::int gross_cents,sum(fee_cents)::int fees_cents from (
        select ap.amount_cents,ap.fee_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.unit_id=u.id and ap.received_at::date between p_start and p_end
        union all select mpay.amount_cents,mpay.fee_cents from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id where cm.barbershop_id=m.barbershop_id and cm.origin_unit_id=u.id and mpay.paid_at::date between p_start and p_end
        union all select pay.amount_cents,pay.fee_cents from public.product_sale_payments pay where pay.barbershop_id=m.barbershop_id and pay.unit_id=u.id and pay.received_at::date between p_start and p_end
      ) z
    ) x on true where u.barbershop_id=m.barbershop_id and (p_unit_id is null or u.id=p_unit_id)),'[]'::jsonb),
    'by_professional',coalesce((select jsonb_agg(jsonb_build_object('professional_id',pr.id,'professional',pr.name,'completed_cents',coalesce(x.completed_cents,0),'completed_count',coalesce(x.completed_count,0),'commission_cents',coalesce(y.commission_cents,0)) order by pr.name) from public.professionals pr left join lateral (select sum(case when a.status='cancelled' then coalesce((select (ev.details->>'service_due_cents')::int from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund' order by ev.created_at desc limit 1),a.total_price_cents) else greatest(0,a.total_price_cents-coalesce((select sum(u.coverage_cents) from public.appointment_membership_uses u where u.appointment_id=a.id and u.status='consumed'),0)) end)::int completed_cents,count(*)::int completed_count from public.appointments a where a.barbershop_id=m.barbershop_id and a.professional_id=pr.id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)) x on true left join lateral (select sum(ce.amount_cents)::int commission_cents from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.professional_id=pr.id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)) y on true where pr.barbershop_id=m.barbershop_id and pr.is_active),'[]'::jsonb)
  );
end $function$;

revoke all on function public.barberium_staff_finance_report_v12_8_raw(date, date, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_finance_report_v12_8_raw(date, date, uuid, text) to service_role;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_report_v12_8_1_raw(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  v_base jsonb;
  v_patch jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Relatórios financeiros restritos ao ADM';
  end if;

  v_base := public.barberium_staff_finance_report_v12_8_raw(p_start,p_end,p_unit_id,p_basis);

  with
  appt_service_names as (
    select
      a.id appointment_id,
      concat_ws(' + ',
        coalesce(nullif(a.service_name_snapshot,''),s.name),
        nullif(string_agg(aa.name_snapshot,' + ' order by aa.name_snapshot) filter (where aa.appointment_id is not null),'')
      ) service_name
    from public.appointments a
    left join public.services s on s.id=a.service_id
    left join public.appointment_addons aa on aa.appointment_id=a.id
    where a.barbershop_id=m.barbershop_id
    group by a.id,a.service_name_snapshot,s.name
  ),
  payment_base as (
    select
      'appointment'::text source_type,
      ap.id payment_id,
      ap.appointment_id source_id,
      ap.received_at payment_date,
      ap.unit_id,
      u.name unit,
      c.full_name customer,
      sn.service_name service,
      a.professional_id,
      pr.name professional,
      ap.method,
      ap.provider_id,
      coalesce(pp.name,'Sem provedor') provider,
      coalesce(ap.installments,1) installments,
      ap.amount_cents,
      coalesce(ap.fee_cents,0) fee_cents,
      ap.note
    from public.appointment_payments ap
    join public.appointments a on a.id=ap.appointment_id
    join public.units u on u.id=ap.unit_id
    left join public.customers c on c.id=a.customer_id
    left join appt_service_names sn on sn.appointment_id=a.id
    left join public.professionals pr on pr.id=a.professional_id
    left join public.payment_providers pp on pp.id=ap.provider_id
    where ap.barbershop_id=m.barbershop_id

    union all

    select
      'membership', mp.id, mp.membership_id, mp.paid_at, cm.origin_unit_id,
      u.name, c.full_name,
      case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,
      null::uuid, null::text, mp.method, mp.provider_id, coalesce(pp.name,'Sem provedor'),
      coalesce(mp.installments,1), mp.amount_cents, coalesce(mp.fee_cents,0), null::text
    from public.membership_payments mp
    join public.customer_memberships cm on cm.id=mp.membership_id
    join public.customers c on c.id=cm.customer_id
    join public.membership_plans pl on pl.id=cm.plan_id
    left join public.units u on u.id=cm.origin_unit_id
    left join public.payment_providers pp on pp.id=mp.provider_id
    where cm.barbershop_id=m.barbershop_id

    union all

    select
      'product', pay.id, pay.sale_id, pay.received_at, pay.unit_id,
      u.name, c.full_name, 'Produtos',
      ps.seller_professional_id, pr.name, pay.method, pay.provider_id, coalesce(pp.name,'Sem provedor'),
      coalesce(pay.installments,1), pay.amount_cents, coalesce(pay.fee_cents,0), pay.note
    from public.product_sale_payments pay
    join public.product_sales ps on ps.id=pay.sale_id
    join public.units u on u.id=pay.unit_id
    left join public.customers c on c.id=ps.customer_id
    left join public.professionals pr on pr.id=ps.seller_professional_id
    left join public.payment_providers pp on pp.id=pay.provider_id
    where ps.barbershop_id=m.barbershop_id
  ),
  appt_refund_totals as (
    select fr.appointment_id source_id,sum(fr.amount_cents)::int refund_cents
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.appointment_id is not null
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id)
    group by fr.appointment_id
  ),
  appt_ranked as (
    select pb.*,
      coalesce(sum(pb.amount_cents) over(partition by pb.source_id order by pb.payment_date,pb.payment_id rows between unbounded preceding and 1 preceding),0)::int prev_amount
    from payment_base pb
    where pb.source_type='appointment'
  ),
  appt_alloc as (
    select 'appointment'::text source_type,r.payment_id,
      greatest(0,least(r.amount_cents,t.refund_cents-r.prev_amount))::int refund_cents
    from appt_ranked r
    join appt_refund_totals t on t.source_id=r.source_id
    where t.refund_cents-r.prev_amount>0
  ),
  membership_direct_alloc as (
    select 'membership'::text source_type,fr.membership_payment_id payment_id,sum(fr.amount_cents)::int refund_cents
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.membership_payment_id is not null
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id)
    group by fr.membership_payment_id
  ),
  membership_refund_totals as (
    select fr.membership_id source_id,sum(fr.amount_cents)::int refund_cents
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.membership_id is not null
      and fr.membership_payment_id is null
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id)
    group by fr.membership_id
  ),
  membership_ranked as (
    select pb.*,
      coalesce(sum(pb.amount_cents) over(partition by pb.source_id order by pb.payment_date,pb.payment_id rows between unbounded preceding and 1 preceding),0)::int prev_amount
    from payment_base pb
    where pb.source_type='membership'
  ),
  membership_fallback_alloc as (
    select 'membership'::text source_type,r.payment_id,
      greatest(0,least(r.amount_cents,t.refund_cents-r.prev_amount))::int refund_cents
    from membership_ranked r
    join membership_refund_totals t on t.source_id=r.source_id
    where t.refund_cents-r.prev_amount>0
  ),
  product_refund_totals as (
    select fr.product_sale_id source_id,sum(fr.amount_cents)::int refund_cents
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.product_sale_id is not null
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id)
    group by fr.product_sale_id
  ),
  product_ranked as (
    select pb.*,
      coalesce(sum(pb.amount_cents) over(partition by pb.source_id order by pb.payment_date,pb.payment_id rows between unbounded preceding and 1 preceding),0)::int prev_amount
    from payment_base pb
    where pb.source_type='product'
  ),
  product_alloc as (
    select 'product'::text source_type,r.payment_id,
      greatest(0,least(r.amount_cents,t.refund_cents-r.prev_amount))::int refund_cents
    from product_ranked r
    join product_refund_totals t on t.source_id=r.source_id
    where t.refund_cents-r.prev_amount>0
  ),
  refund_alloc as (
    select source_type,payment_id,sum(refund_cents)::int refund_cents
    from (
      select * from appt_alloc
      union all select * from membership_direct_alloc
      union all select * from membership_fallback_alloc
      union all select * from product_alloc
    ) q
    group by source_type,payment_id
  ),
  current_payments as (
    select pb.*,coalesce(ra.refund_cents,0)::int refund_cents,
      (pb.amount_cents-coalesce(ra.refund_cents,0)-pb.fee_cents)::int net_cents
    from payment_base pb
    left join refund_alloc ra on ra.source_type=pb.source_type and ra.payment_id=pb.payment_id
    where pb.payment_date::date between p_start and p_end
      and (p_unit_id is null or pb.unit_id=p_unit_id)
  ),
  provider_gross as (
    select provider,method,installments,
      count(*) filter(where amount_cents-coalesce(refund_cents,0)>0)::int transactions,
      sum(amount_cents)::int gross_cents,
      sum(fee_cents)::int fees_cents
    from current_payments
    group by provider,method,installments
  ),
  provider_refunds as (
    select pb.provider,pb.method,pb.installments,sum(ra.refund_cents)::int refunds_cents
    from refund_alloc ra
    join payment_base pb on pb.source_type=ra.source_type and pb.payment_id=ra.payment_id
    group by pb.provider,pb.method,pb.installments
  ),
  refund_totals as (
    select coalesce(sum(fr.amount_cents),0)::int total_refunds
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id)
  ),
  allocated_total as (
    select coalesce(sum(refund_cents),0)::int allocated_refunds from refund_alloc
  ),
  provider_rows_raw as (
    select
      coalesce(g.provider,r.provider) provider,
      coalesce(g.method,r.method) method,
      coalesce(g.installments,r.installments,1) installments,
      coalesce(g.transactions,0)::int transactions,
      coalesce(g.gross_cents,0)::int gross_cents,
      coalesce(r.refunds_cents,0)::int refunds_cents,
      0::int cancelled_pending_cents,
      coalesce(g.fees_cents,0)::int fees_cents
    from provider_gross g
    full join provider_refunds r using(provider,method,installments)

    union all

    select 'Sem provedor','other',1,0,0,
      greatest(0,rt.total_refunds-at.allocated_refunds),0,0
    from refund_totals rt,allocated_total at
    where rt.total_refunds>at.allocated_refunds

    union all

    select 'Sem recebimento','pending_cancelled',1,0,0,0,
      coalesce((v_base->'overview'->>'cancelled_pending_cents')::int,0),0
    where coalesce((v_base->'overview'->>'cancelled_pending_cents')::int,0)>0
  ),
  provider_rows as (
    select *, (gross_cents-refunds_cents-cancelled_pending_cents-fees_cents)::int net_cents
    from provider_rows_raw
  ),
  unit_basis_rows as (
    select unit_id,sum(gross_cents)::int gross_cents,sum(fees_cents)::int fees_cents
    from (
      select cp.unit_id,cp.amount_cents gross_cents,cp.fee_cents fees_cents
      from current_payments cp
      where p_basis='cash'
      union all
      select a.unit_id,
        (case when a.status='cancelled' then
          coalesce((select (ev.details->>'service_due_cents')::int
                    from public.appointment_events ev
                    where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund'
                    order by ev.created_at desc limit 1),a.total_price_cents)
         else greatest(0,a.total_price_cents-coalesce((select sum(amu.coverage_cents)
                    from public.appointment_membership_uses amu
                    where amu.appointment_id=a.id and amu.status='consumed'),0))
         end)::int gross_cents,
        coalesce((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id),0)::int fees_cents
      from public.appointments a
      where p_basis='accrual'
        and a.barbershop_id=m.barbershop_id
        and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund'))
        and a.starts_at::date between p_start and p_end
        and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select cm.origin_unit_id,mp.amount_cents,coalesce(mp.fee_cents,0)
      from public.membership_payments mp
      join public.customer_memberships cm on cm.id=mp.membership_id
      where p_basis='accrual'
        and cm.barbershop_id=m.barbershop_id
        and mp.paid_at::date between p_start and p_end
        and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      union all
      select ps.unit_id,ps.total_cents,
        coalesce((select sum(pay.fee_cents) from public.product_sale_payments pay where pay.sale_id=ps.id),0)::int
      from public.product_sales ps
      where p_basis='accrual'
        and ps.barbershop_id=m.barbershop_id
        and ps.status in ('completed','refunded')
        and ps.completed_at::date between p_start and p_end
        and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) x
    group by unit_id
  ),
  unit_refunds as (
    select fr.unit_id,sum(fr.amount_cents)::int refunds_cents
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id)
    group by fr.unit_id
  ),
  unit_pending as (
    select unit_id,sum(amount_cents)::int cancelled_pending_cents
    from (
      select a.unit_id,coalesce((ev.details->>'service_pending_cancelled_cents')::int,0) amount_cents
      from public.appointment_events ev
      join public.appointments a on a.id=ev.appointment_id
      where p_basis='accrual'
        and ev.barbershop_id=m.barbershop_id
        and ev.event_type='cancelled_with_refund'
        and ev.created_at::date between p_start and p_end
        and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select ps.unit_id,coalesce(ps.pending_cents,0)
      from public.product_sales ps
      where p_basis='accrual'
        and ps.barbershop_id=m.barbershop_id
        and ps.status='refunded'
        and ps.refunded_at::date between p_start and p_end
        and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) q
    group by unit_id
  ),
  unit_rows as (
    select
      u.id unit_id,u.name unit,
      coalesce(b.gross_cents,0)::int gross_cents,
      coalesce(r.refunds_cents,0)::int refunds_cents,
      coalesce(pc.cancelled_pending_cents,0)::int cancelled_pending_cents,
      coalesce(b.fees_cents,0)::int fees_cents,
      (coalesce(b.gross_cents,0)-coalesce(r.refunds_cents,0)-coalesce(pc.cancelled_pending_cents,0)-coalesce(b.fees_cents,0))::int net_cents
    from public.units u
    left join unit_basis_rows b on b.unit_id=u.id
    left join unit_refunds r on r.unit_id=u.id
    left join unit_pending pc on pc.unit_id=u.id
    where u.barbershop_id=m.barbershop_id
      and (p_unit_id is null or u.id=p_unit_id)
  ),
  professional_basis_rows as (
    select professional_id,professional,sum(gross_cents)::int gross_cents,sum(fees_cents)::int fees_cents
    from (
      select cp.professional_id,coalesce(cp.professional,'Planos / sem profissional') professional,
        cp.amount_cents gross_cents,cp.fee_cents fees_cents
      from current_payments cp
      where p_basis='cash'
      union all
      select a.professional_id,coalesce(pr.name,'Sem profissional'),
        (case when a.status='cancelled' then
          coalesce((select (ev.details->>'service_due_cents')::int
                    from public.appointment_events ev
                    where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund'
                    order by ev.created_at desc limit 1),a.total_price_cents)
         else greatest(0,a.total_price_cents-coalesce((select sum(amu.coverage_cents)
                    from public.appointment_membership_uses amu
                    where amu.appointment_id=a.id and amu.status='consumed'),0))
         end)::int,
        coalesce((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id),0)::int
      from public.appointments a
      left join public.professionals pr on pr.id=a.professional_id
      where p_basis='accrual'
        and a.barbershop_id=m.barbershop_id
        and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund'))
        and a.starts_at::date between p_start and p_end
        and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select null::uuid,'Planos / sem profissional',mp.amount_cents,coalesce(mp.fee_cents,0)
      from public.membership_payments mp
      join public.customer_memberships cm on cm.id=mp.membership_id
      where p_basis='accrual'
        and cm.barbershop_id=m.barbershop_id
        and mp.paid_at::date between p_start and p_end
        and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      union all
      select ps.seller_professional_id,coalesce(pr.name,'Sem profissional'),ps.total_cents,
        coalesce((select sum(pay.fee_cents) from public.product_sale_payments pay where pay.sale_id=ps.id),0)::int
      from public.product_sales ps
      left join public.professionals pr on pr.id=ps.seller_professional_id
      where p_basis='accrual'
        and ps.barbershop_id=m.barbershop_id
        and ps.status in ('completed','refunded')
        and ps.completed_at::date between p_start and p_end
        and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) x
    group by professional_id,professional
  ),
  professional_refunds as (
    select professional_id,professional,sum(amount_cents)::int refunds_cents
    from (
      select a.professional_id,coalesce(pr.name,'Sem profissional') professional,fr.amount_cents
      from public.finance_refunds fr
      join public.appointments a on a.id=fr.appointment_id
      left join public.professionals pr on pr.id=a.professional_id
      where fr.barbershop_id=m.barbershop_id
        and fr.appointment_id is not null
        and fr.product_sale_id is null
        and fr.created_at::date between p_start and p_end
        and (p_unit_id is null or fr.unit_id=p_unit_id)
      union all
      select ps.seller_professional_id,coalesce(pr.name,'Sem profissional'),fr.amount_cents
      from public.finance_refunds fr
      join public.product_sales ps on ps.id=fr.product_sale_id
      left join public.professionals pr on pr.id=ps.seller_professional_id
      where fr.barbershop_id=m.barbershop_id
        and fr.product_sale_id is not null
        and fr.created_at::date between p_start and p_end
        and (p_unit_id is null or fr.unit_id=p_unit_id)
      union all
      select null::uuid,'Planos / sem profissional',fr.amount_cents
      from public.finance_refunds fr
      where fr.barbershop_id=m.barbershop_id
        and fr.membership_id is not null
        and fr.created_at::date between p_start and p_end
        and (p_unit_id is null or fr.unit_id=p_unit_id)
    ) q
    group by professional_id,professional
  ),
  professional_pending as (
    select professional_id,professional,sum(amount_cents)::int cancelled_pending_cents
    from (
      select a.professional_id,coalesce(pr.name,'Sem profissional') professional,
        coalesce((ev.details->>'service_pending_cancelled_cents')::int,0) amount_cents
      from public.appointment_events ev
      join public.appointments a on a.id=ev.appointment_id
      left join public.professionals pr on pr.id=a.professional_id
      where p_basis='accrual'
        and ev.barbershop_id=m.barbershop_id
        and ev.event_type='cancelled_with_refund'
        and ev.created_at::date between p_start and p_end
        and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select ps.seller_professional_id,coalesce(pr.name,'Sem profissional'),coalesce(ps.pending_cents,0)
      from public.product_sales ps
      left join public.professionals pr on pr.id=ps.seller_professional_id
      where p_basis='accrual'
        and ps.barbershop_id=m.barbershop_id
        and ps.status='refunded'
        and ps.refunded_at::date between p_start and p_end
        and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) q
    group by professional_id,professional
  ),
  professional_commissions as (
    select ce.professional_id,sum(ce.amount_cents)::int commission_cents
    from public.commission_entries ce
    where ce.barbershop_id=m.barbershop_id
      and ce.created_at::date between p_start and p_end
      and (p_unit_id is null or ce.unit_id=p_unit_id)
    group by ce.professional_id
  ),
  professional_completed as (
    select a.professional_id,count(*)::int completed_count,
      coalesce(sum(greatest(0,a.total_price_cents-coalesce((select sum(amu.coverage_cents)
        from public.appointment_membership_uses amu
        where amu.appointment_id=a.id and amu.status='consumed'),0))),0)::int completed_cents
    from public.appointments a
    where a.barbershop_id=m.barbershop_id
      and a.status='completed'
      and a.starts_at::date between p_start and p_end
      and (p_unit_id is null or a.unit_id=p_unit_id)
    group by a.professional_id
  ),
  professional_keys as (
    select p.id professional_id,p.name professional
    from public.professionals p
    where p.barbershop_id=m.barbershop_id and p.is_active
    union
    select professional_id,professional from professional_basis_rows
    union
    select professional_id,professional from professional_refunds
    union
    select professional_id,professional from professional_pending
  ),
  professional_rows as (
    select
      k.professional_id,k.professional,
      coalesce(c.completed_count,0)::int completed_count,
      coalesce(c.completed_cents,0)::int completed_cents,
      coalesce(b.gross_cents,0)::int gross_cents,
      coalesce(r.refunds_cents,0)::int refunds_cents,
      coalesce(pc.cancelled_pending_cents,0)::int cancelled_pending_cents,
      coalesce(b.fees_cents,0)::int fees_cents,
      (coalesce(b.gross_cents,0)-coalesce(r.refunds_cents,0)-coalesce(pc.cancelled_pending_cents,0)-coalesce(b.fees_cents,0))::int net_cents,
      coalesce(cm.commission_cents,0)::int commission_cents
    from professional_keys k
    left join professional_basis_rows b on b.professional_id is not distinct from k.professional_id and b.professional=k.professional
    left join professional_refunds r on r.professional_id is not distinct from k.professional_id and r.professional=k.professional
    left join professional_pending pc on pc.professional_id is not distinct from k.professional_id and pc.professional=k.professional
    left join professional_commissions cm on cm.professional_id is not distinct from k.professional_id
    left join professional_completed c on c.professional_id is not distinct from k.professional_id
  ),
  accrual_rows as (
    select jsonb_build_object(
      'appointment_id',a.id,'source_type','appointment','date',a.starts_at,'unit',u.name,
      'customer',c.full_name,'service',sn.service_name,'professional',pr.name,
      'amount_cents',
      case when a.status='cancelled' then
        coalesce((select (ev.details->>'service_due_cents')::int from public.appointment_events ev
                  where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund'
                  order by ev.created_at desc limit 1),a.total_price_cents)
      else greatest(0,a.total_price_cents-coalesce((select sum(amu.coverage_cents)
                  from public.appointment_membership_uses amu
                  where amu.appointment_id=a.id and amu.status='consumed'),0)) end,
      'refund_cents',coalesce((select sum(fr.amount_cents) from public.finance_refunds fr
                  where fr.appointment_id=a.id and fr.created_at::date between p_start and p_end),0)
    ) x
    from public.appointments a
    join public.units u on u.id=a.unit_id
    left join public.customers c on c.id=a.customer_id
    left join public.professionals pr on pr.id=a.professional_id
    left join appt_service_names sn on sn.appointment_id=a.id
    where a.barbershop_id=m.barbershop_id
      and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund'))
      and a.starts_at::date between p_start and p_end
      and (p_unit_id is null or a.unit_id=p_unit_id)
    union all
    select jsonb_build_object(
      'appointment_id',null,'source_type','membership','date',mp.paid_at,'unit',u.name,
      'customer',c.full_name,'service',case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,
      'professional',null,'amount_cents',mp.amount_cents,'refund_cents',
      coalesce((select sum(fr.amount_cents) from public.finance_refunds fr
                where fr.membership_payment_id=mp.id and fr.created_at::date between p_start and p_end),0)
    )
    from public.membership_payments mp
    join public.customer_memberships cm on cm.id=mp.membership_id
    join public.customers c on c.id=cm.customer_id
    join public.membership_plans pl on pl.id=cm.plan_id
    left join public.units u on u.id=cm.origin_unit_id
    where cm.barbershop_id=m.barbershop_id
      and mp.paid_at::date between p_start and p_end
      and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
    union all
    select jsonb_build_object(
      'appointment_id',ps.appointment_id,'source_type','product','date',ps.completed_at,'unit',u.name,
      'customer',c.full_name,'service','Produtos','professional',pr.name,'amount_cents',ps.total_cents,
      'refund_cents',coalesce((select sum(fr.amount_cents) from public.finance_refunds fr
                  where fr.product_sale_id=ps.id and fr.created_at::date between p_start and p_end),0)
    )
    from public.product_sales ps
    join public.units u on u.id=ps.unit_id
    left join public.customers c on c.id=ps.customer_id
    left join public.professionals pr on pr.id=ps.seller_professional_id
    where ps.barbershop_id=m.barbershop_id
      and ps.status in ('completed','refunded')
      and ps.completed_at::date between p_start and p_end
      and (p_unit_id is null or ps.unit_id=p_unit_id)
  ),
  patch as (
    select jsonb_build_object(
      'payments',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',cp.payment_id,'source_type',cp.source_type,'date',cp.payment_date,'unit',cp.unit,
          'customer',cp.customer,'service',cp.service,'professional',cp.professional,'method',cp.method,
          'provider',cp.provider,'installments',cp.installments,'amount_cents',cp.amount_cents,
          'refund_cents',cp.refund_cents,'fee_cents',cp.fee_cents,'net_cents',cp.net_cents,
          'refund_status',case when cp.refund_cents>=cp.amount_cents and cp.refund_cents>0 then 'refunded'
                               when cp.refund_cents>0 then 'partial_refund' else 'paid' end,
          'note',cp.note
        ) order by cp.payment_date desc)
        from current_payments cp
      ),'[]'::jsonb),
      'accrual_revenue',coalesce((select jsonb_agg(x order by (x->>'date')::timestamptz desc) from accrual_rows),'[]'::jsonb),
      'by_provider',coalesce((select jsonb_agg(jsonb_build_object(
        'provider',provider,'method',method,'installments',installments,'transactions',transactions,
        'gross_cents',gross_cents,'refunds_cents',refunds_cents,'cancelled_pending_cents',cancelled_pending_cents,
        'fees_cents',fees_cents,'net_cents',net_cents
      ) order by net_cents desc,provider) from provider_rows),'[]'::jsonb),
      'by_unit',coalesce((select jsonb_agg(to_jsonb(unit_rows) order by unit) from unit_rows),'[]'::jsonb),
      'by_professional',coalesce((select jsonb_agg(to_jsonb(professional_rows) order by professional) from professional_rows),'[]'::jsonb)
    ) value
  )
  select value into v_patch from patch;

  return v_base || v_patch;
end
$function$;

revoke all on function public.barberium_staff_finance_report_v12_8_1_raw(date, date, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_finance_report_v12_8_1_raw(date, date, uuid, text) to service_role;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_report(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  v_tz text;
  v_base jsonb;
  v_providers jsonb;
  v_refunds jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Relatórios financeiros restritos ao ADM';
  end if;

  select coalesce(timezone,'America/Sao_Paulo')
    into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  perform set_config('TimeZone',coalesce(v_tz,'America/Sao_Paulo'),true);

  v_base := public.barberium_staff_finance_report_v12_8_1_raw(
    p_start,p_end,p_unit_id,p_basis
  );

  select coalesce(jsonb_agg(
    r || jsonb_build_object(
      'transactions',
        coalesce((
          select count(*)::int
          from jsonb_array_elements(v_base->'payments') p
          where coalesce(p->>'provider','')=coalesce(r->>'provider','')
            and coalesce(p->>'method','')=coalesce(r->>'method','')
            and coalesce((p->>'installments')::int,1)=coalesce((r->>'installments')::int,1)
        ),0),
      'refunded_transactions',
        coalesce((
          select count(*)::int
          from jsonb_array_elements(v_base->'payments') p
          where coalesce(p->>'provider','')=coalesce(r->>'provider','')
            and coalesce(p->>'method','')=coalesce(r->>'method','')
            and coalesce((p->>'installments')::int,1)=coalesce((r->>'installments')::int,1)
            and coalesce((p->>'refund_cents')::int,0)>0
        ),0)
    )
    order by coalesce((r->>'net_cents')::int,0) desc
  ),'[]'::jsonb)
  into v_providers
  from jsonb_array_elements(v_base->'by_provider') r;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',fr.id,
      'date',fr.created_at,
      'unit',u.name,
      'source_type',case when fr.product_sale_id is not null then 'product'
                         when fr.membership_id is not null then 'membership'
                         else 'appointment' end,
      'customer',coalesce(pc.full_name,mc.full_name,ac.full_name),
      'description',coalesce(
        case when fr.product_sale_id is not null then 'Produtos' end,
        case when cm.plan_type='subscription' then 'Assinatura: '||mpl.name
             when cm.plan_type='package' then 'Pacote: '||mpl.name end,
        apdesc.description
      ),
      'method',fr.refund_method,
      'amount_cents',fr.amount_cents,
      'reason',fr.reason
    )
    order by fr.created_at desc
  ),'[]'::jsonb)
  into v_refunds
  from public.finance_refunds fr
  join public.units u on u.id=fr.unit_id
  left join public.customer_memberships cm on cm.id=fr.membership_id
  left join public.membership_plans mpl on mpl.id=cm.plan_id
  left join public.customers mc on mc.id=cm.customer_id
  left join public.appointments aa on aa.id=fr.appointment_id
  left join public.customers ac on ac.id=aa.customer_id
  left join public.product_sales ps on ps.id=fr.product_sale_id
  left join public.customers pc on pc.id=ps.customer_id
  left join lateral (
    select concat_ws(' + ',
      coalesce(nullif(a.service_name_snapshot,''),s.name),
      nullif(string_agg(ad.name_snapshot,' + ' order by ad.name_snapshot),'')
    ) description
    from public.appointments a
    left join public.services s on s.id=a.service_id
    left join public.appointment_addons ad on ad.appointment_id=a.id
    where a.id=fr.appointment_id
    group by a.id,a.service_name_snapshot,s.name
  ) apdesc on true
  where fr.barbershop_id=m.barbershop_id
    and fr.created_at::date between p_start and p_end
    and (p_unit_id is null or fr.unit_id=p_unit_id);

  return v_base || jsonb_build_object(
    'by_provider',v_providers,
    'refunds',v_refunds
  );
end
$function$;

delete from supabase_migrations.schema_migrations where version = '20261026100000';

commit;
