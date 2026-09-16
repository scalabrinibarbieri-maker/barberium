-- Barberium v11.1 — relatórios financeiros
-- Aplicada no Supabase em 16/09/2026.

create or replace function public.barberium_staff_finance_report(
  p_start date,
  p_end date,
  p_unit_id uuid default null,
  p_basis text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  v_overview jsonb;
  v_unit_name text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Relatórios financeiros restritos ao ADM';
  end if;
  if p_start is null or p_end is null or p_end < p_start then raise exception 'Período inválido'; end if;
  if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;

  if p_unit_id is not null then
    select u.name into v_unit_name from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id;
    if v_unit_name is null then raise exception 'Unidade inválida'; end if;
  else
    v_unit_name:='Consolidado da empresa';
  end if;

  v_overview:=public.barberium_staff_finance_overview(p_start,p_end,p_unit_id,p_basis);

  return jsonb_build_object(
    'meta',jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'unit_id',p_unit_id,'unit_name',v_unit_name,'generated_at',now()),
    'overview',v_overview,
    'payments',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',ap.id,'date',ap.received_at,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,
        'method',ap.method,'provider',pp.name,'installments',ap.installments,'amount_cents',ap.amount_cents,
        'fee_cents',ap.fee_cents,'net_cents',ap.amount_cents-ap.fee_cents,'note',ap.note
      ) order by ap.received_at desc)
      from public.appointment_payments ap
      join public.appointments a on a.id=ap.appointment_id
      join public.units u on u.id=ap.unit_id
      left join public.customers c on c.id=a.customer_id
      left join public.services s on s.id=a.service_id
      left join public.professionals pr on pr.id=a.professional_id
      left join public.payment_providers pp on pp.id=ap.provider_id
      where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end
        and (p_unit_id is null or ap.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'accrual_revenue',coalesce((
      select jsonb_agg(jsonb_build_object(
        'appointment_id',a.id,'date',a.starts_at,'unit',u.name,'customer',c.full_name,'service',s.name,
        'professional',pr.name,'amount_cents',a.total_price_cents
      ) order by a.starts_at desc)
      from public.appointments a
      join public.units u on u.id=a.unit_id
      left join public.customers c on c.id=a.customer_id
      left join public.services s on s.id=a.service_id
      left join public.professionals pr on pr.id=a.professional_id
      where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end
        and (p_unit_id is null or a.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'expenses',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',e.id,'unit',u.name,'category',ec.name,'description',e.description,'amount_cents',e.amount_cents,
        'due_date',e.due_date,'status',e.status,'payment_method',e.payment_method,'paid_from_cash',e.paid_from_cash,
        'paid_at',e.paid_at,'note',e.note
      ) order by e.due_date desc,e.created_at desc)
      from public.expenses e
      join public.units u on u.id=e.unit_id
      left join public.expense_categories ec on ec.id=e.category_id
      where e.barbershop_id=m.barbershop_id
        and (e.due_date between p_start and p_end or (e.paid_at is not null and e.paid_at::date between p_start and p_end))
        and (p_unit_id is null or e.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'commissions',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',ce.id,'date',ce.created_at,'unit',u.name,'professional',pr.name,'source_type',ce.source_type,
        'description',ce.description,'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,'amount_cents',ce.amount_cents,
        'status',ce.status
      ) order by ce.created_at desc)
      from public.commission_entries ce
      join public.units u on u.id=ce.unit_id
      join public.professionals pr on pr.id=ce.professional_id
      where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end
        and (p_unit_id is null or ce.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'receivables',coalesce((
      select jsonb_agg(jsonb_build_object(
        'appointment_id',ar.appointment_id,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,
        'original_due_cents',ar.original_due_cents,'paid_cents',ar.paid_cents,
        'open_cents',greatest(0,ar.original_due_cents-ar.paid_cents),'status',ar.status,'due_date',ar.due_date,
        'note',ar.note,'created_at',ar.created_at
      ) order by coalesce(ar.due_date,ar.created_at::date),ar.created_at)
      from public.appointment_receivables ar
      join public.appointments a on a.id=ar.appointment_id
      join public.units u on u.id=ar.unit_id
      left join public.customers c on c.id=a.customer_id
      left join public.services s on s.id=a.service_id
      left join public.professionals pr on pr.id=a.professional_id
      where ar.barbershop_id=m.barbershop_id and ar.created_at::date<=p_end
        and (p_unit_id is null or ar.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'cash_sessions',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',cs.id,'unit',u.name,'status',cs.status,'opening_balance_cents',cs.opening_balance_cents,
        'opened_at',cs.opened_at,'expected_closing_cents',cs.expected_closing_cents,
        'counted_closing_cents',cs.counted_closing_cents,'difference_cents',cs.difference_cents,
        'closing_justification',cs.closing_justification,'closed_at',cs.closed_at
      ) order by cs.opened_at desc)
      from public.cash_sessions cs
      join public.units u on u.id=cs.unit_id
      where cs.barbershop_id=m.barbershop_id and cs.opened_at::date<=p_end
        and coalesce(cs.closed_at::date,p_end)>=p_start and (p_unit_id is null or cs.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'cash_movements',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',cm.id,'date',cm.created_at,'unit',u.name,'type',cm.movement_type,'amount_cents',cm.amount_cents,
        'reference_type',cm.reference_type,'note',cm.note
      ) order by cm.created_at desc)
      from public.cash_movements cm
      join public.units u on u.id=cm.unit_id
      where cm.barbershop_id=m.barbershop_id and cm.created_at::date between p_start and p_end
        and (p_unit_id is null or cm.unit_id=p_unit_id)
    ),'[]'::jsonb),
    'by_provider',coalesce((
      select jsonb_agg(jsonb_build_object(
        'provider',provider,'method',method,'installments',installments,'gross_cents',gross_cents,
        'fees_cents',fees_cents,'net_cents',gross_cents-fees_cents,'transactions',transactions
      ) order by gross_cents desc)
      from (
        select coalesce(pp.name,'Sem provedor') provider,ap.method,coalesce(ap.installments,1) installments,
          sum(ap.amount_cents)::int gross_cents,sum(ap.fee_cents)::int fees_cents,count(*)::int transactions
        from public.appointment_payments ap
        left join public.payment_providers pp on pp.id=ap.provider_id
        where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end
          and (p_unit_id is null or ap.unit_id=p_unit_id)
        group by coalesce(pp.name,'Sem provedor'),ap.method,coalesce(ap.installments,1)
      ) q
    ),'[]'::jsonb),
    'by_unit',coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_id',u.id,'unit',u.name,'gross_cents',coalesce(x.gross_cents,0),'fees_cents',coalesce(x.fees_cents,0),
        'net_cents',coalesce(x.gross_cents,0)-coalesce(x.fees_cents,0)
      ) order by u.name)
      from public.units u
      left join lateral (
        select sum(ap.amount_cents)::int gross_cents,sum(ap.fee_cents)::int fees_cents
        from public.appointment_payments ap
        where ap.barbershop_id=m.barbershop_id and ap.unit_id=u.id and ap.received_at::date between p_start and p_end
      ) x on true
      where u.barbershop_id=m.barbershop_id and (p_unit_id is null or u.id=p_unit_id)
    ),'[]'::jsonb),
    'by_professional',coalesce((
      select jsonb_agg(jsonb_build_object(
        'professional_id',pr.id,'professional',pr.name,'completed_cents',coalesce(x.completed_cents,0),
        'completed_count',coalesce(x.completed_count,0),'commission_cents',coalesce(y.commission_cents,0)
      ) order by pr.name)
      from public.professionals pr
      left join lateral (
        select sum(a.total_price_cents)::int completed_cents,count(*)::int completed_count
        from public.appointments a
        where a.barbershop_id=m.barbershop_id and a.professional_id=pr.id and a.status='completed'
          and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)
      ) x on true
      left join lateral (
        select sum(ce.amount_cents)::int commission_cents
        from public.commission_entries ce
        where ce.barbershop_id=m.barbershop_id and ce.professional_id=pr.id
          and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)
      ) y on true
      where pr.barbershop_id=m.barbershop_id and pr.is_active
    ),'[]'::jsonb)
  );
end
$function$;

grant execute on function public.barberium_staff_finance_report(date,date,uuid,text) to authenticated;
