-- Barberium · Etapa 7g (parte 1) · Datas no fuso da barbearia · ROLLBACK
-- Volta as 16 funções ao texto de antes da migration 20261023100000 e apaga
-- barberium.usar_fuso_da_barbearia. Nenhum dado muda (só o dia em que os relatórios contam
-- um registro feito à noite volta a ser o de Londres).
--
-- Ordem:
--   1. Supabase, SQL Editor: rode este arquivo inteiro. Ou entra tudo, ou nada.
--   2. Repositório: apague supabase/migrations/20261023100000_datas_no_fuso_da_barbearia.sql.

begin;

CREATE OR REPLACE FUNCTION public.barberium_staff_balance_quick(p_start date DEFAULT CURRENT_DATE, p_end date DEFAULT CURRENT_DATE, p_unit_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium'
AS $function$
declare
  m record;
  v_tz text;
  v_is_manager boolean := false;
  v_can_view_own boolean := false;

  v_service_gross integer := 0;
  v_service_fees integer := 0;
  v_service_refunds integer := 0;

  v_product_gross integer := 0;
  v_product_fees integer := 0;
  v_product_refunds integer := 0;

  v_membership_gross integer := 0;
  v_membership_fees integer := 0;
  v_membership_refunds integer := 0;

  v_commissions integer := 0;
  v_professionals jsonb := '[]'::jsonb;
  v_entries jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  if p_start is null or p_end is null or p_start > p_end then
    raise exception 'Período inválido';
  end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then
    raise exception 'Sem acesso';
  end if;

  select coalesce(timezone,'America/Sao_Paulo')
    into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  perform set_config('TimeZone',coalesce(v_tz,'America/Sao_Paulo'),true);

  v_is_manager := m.role in ('owner','admin');

  if not v_is_manager then
    if m.professional_id is null then
      raise exception 'Profissional não vinculado';
    end if;

    select coalesce((pp.permissions->>'view_own_commission')::boolean,false)
      into v_can_view_own
    from public.professional_permissions pp
    where pp.barbershop_id=m.barbershop_id
      and pp.professional_id=m.professional_id;

    if not coalesce(v_can_view_own,false) then
      raise exception 'Sem permissão para visualizar comissões';
    end if;
  end if;

  if p_unit_id is not null and not exists(
    select 1 from public.units u
    where u.id=p_unit_id and u.barbershop_id=m.barbershop_id
  ) then
    raise exception 'Unidade inválida';
  end if;

  if v_is_manager then
    /* SERVIÇOS:
       A data efetiva é a data do atendimento, não a data em que o caixa foi fechado.
       Ainda somamos apenas pagamentos realmente registrados. */
    select
      coalesce(sum(ap.amount_cents),0)::int,
      coalesce(sum(ap.fee_cents),0)::int
      into v_service_gross,v_service_fees
    from public.appointment_payments ap
    join public.appointments a on a.id=ap.appointment_id
    where ap.barbershop_id=m.barbershop_id
      and a.starts_at::date between p_start and p_end
      and (p_unit_id is null or ap.unit_id=p_unit_id);

    select coalesce(sum(fr.amount_cents),0)::int
      into v_service_refunds
    from public.finance_refunds fr
    join public.appointments a on a.id=fr.appointment_id
    where fr.barbershop_id=m.barbershop_id
      and fr.appointment_id is not null
      and fr.product_sale_id is null
      and fr.membership_id is null
      and a.starts_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id);

    /* PRODUTOS:
       Se a venda veio de um atendimento, usa a data do atendimento.
       Venda avulsa usa a data da conclusão/venda. */
    select
      coalesce(sum(psp.amount_cents),0)::int,
      coalesce(sum(psp.fee_cents),0)::int
      into v_product_gross,v_product_fees
    from public.product_sale_payments psp
    join public.product_sales ps on ps.id=psp.sale_id
    left join public.appointments a on a.id=ps.appointment_id
    where psp.barbershop_id=m.barbershop_id
      and coalesce(a.starts_at,ps.completed_at,psp.received_at)::date between p_start and p_end
      and (p_unit_id is null or psp.unit_id=p_unit_id);

    select coalesce(sum(fr.amount_cents),0)::int
      into v_product_refunds
    from public.finance_refunds fr
    join public.product_sales ps on ps.id=fr.product_sale_id
    left join public.appointments a on a.id=ps.appointment_id
    where fr.barbershop_id=m.barbershop_id
      and fr.product_sale_id is not null
      and coalesce(a.starts_at,ps.completed_at,fr.created_at)::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id);

    /* ASSINATURAS/PACOTES:
       Não pertencem a um atendimento específico, então seguem a data do pagamento. */
    select
      coalesce(sum(mp.amount_cents),0)::int,
      coalesce(sum(mp.fee_cents),0)::int
      into v_membership_gross,v_membership_fees
    from public.membership_payments mp
    join public.customer_memberships cm on cm.id=mp.membership_id
    where cm.barbershop_id=m.barbershop_id
      and mp.paid_at::date between p_start and p_end
      and (p_unit_id is null or cm.origin_unit_id=p_unit_id);

    select coalesce(sum(fr.amount_cents),0)::int
      into v_membership_refunds
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.membership_id is not null
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id);
  end if;

  /* COMISSÕES:
     Se existe atendimento associado, a comissão pertence à data do atendimento.
     Comissão de produto ligado a atendimento também acompanha o atendimento.
     Demais casos usam a data própria do lançamento. */
  with effective_commissions as (
    select
      ce.*,
      coalesce(
        a.starts_at,
        pa.starts_at,
        ps.completed_at,
        ce.created_at
      ) as effective_at
    from public.commission_entries ce
    left join public.appointments a
      on a.id=ce.appointment_id
    left join public.product_sales ps
      on ce.source_type='product_sale'
     and ps.id=ce.source_id
    left join public.appointments pa
      on pa.id=ps.appointment_id
    where ce.barbershop_id=m.barbershop_id
      and (p_unit_id is null or ce.unit_id=p_unit_id)
      and (v_is_manager or ce.professional_id=m.professional_id)
  )
  select coalesce(sum(amount_cents),0)::int
    into v_commissions
  from effective_commissions
  where effective_at::date between p_start and p_end;

  with effective_commissions as (
    select
      ce.*,
      coalesce(
        a.starts_at,
        pa.starts_at,
        ps.completed_at,
        ce.created_at
      ) as effective_at
    from public.commission_entries ce
    left join public.appointments a
      on a.id=ce.appointment_id
    left join public.product_sales ps
      on ce.source_type='product_sale'
     and ps.id=ce.source_id
    left join public.appointments pa
      on pa.id=ps.appointment_id
    where ce.barbershop_id=m.barbershop_id
      and (p_unit_id is null or ce.unit_id=p_unit_id)
      and (v_is_manager or ce.professional_id=m.professional_id)
  ),
  pro_keys as (
    select p.id,p.name,p.image_path,p.sort_order
    from public.professionals p
    where p.barbershop_id=m.barbershop_id
      and p.is_active=true
      and (v_is_manager or p.id=m.professional_id)
      and (
        p_unit_id is null
        or p.unit_id=p_unit_id
        or exists(
          select 1
          from effective_commissions ec
          where ec.professional_id=p.id
            and ec.effective_at::date between p_start and p_end
        )
      )
  ),
  sums as (
    select
      ec.professional_id,
      coalesce(sum(ec.amount_cents),0)::int as commission_cents,
      coalesce(sum(ec.amount_cents) filter (
        where ec.source_type in ('service','appointment_cancellation')
      ),0)::int as service_commission_cents,
      coalesce(sum(ec.amount_cents) filter (
        where ec.source_type='product_sale'
      ),0)::int as product_commission_cents,
      coalesce(sum(ec.amount_cents) filter (
        where ec.source_type='membership_usage'
      ),0)::int as membership_commission_cents
    from effective_commissions ec
    where ec.effective_at::date between p_start and p_end
    group by ec.professional_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'professional_id',k.id,
      'name',k.name,
      'image_path',k.image_path,
      'commission_cents',coalesce(s.commission_cents,0),
      'service_commission_cents',coalesce(s.service_commission_cents,0),
      'product_commission_cents',coalesce(s.product_commission_cents,0),
      'membership_commission_cents',coalesce(s.membership_commission_cents,0)
    )
    order by k.sort_order,k.name
  ),'[]'::jsonb)
  into v_professionals
  from pro_keys k
  left join sums s on s.professional_id=k.id;

  with effective_commissions as (
    select
      ce.*,
      coalesce(
        a.starts_at,
        pa.starts_at,
        ps.completed_at,
        ce.created_at
      ) as effective_at
    from public.commission_entries ce
    left join public.appointments a
      on a.id=ce.appointment_id
    left join public.product_sales ps
      on ce.source_type='product_sale'
     and ps.id=ce.source_id
    left join public.appointments pa
      on pa.id=ps.appointment_id
    where ce.barbershop_id=m.barbershop_id
      and (p_unit_id is null or ce.unit_id=p_unit_id)
      and (v_is_manager or ce.professional_id=m.professional_id)
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',ec.id,
      'professional_id',ec.professional_id,
      'professional',p.name,
      'category',case
        when ec.source_type='product_sale' then 'products'
        when ec.source_type='membership_usage' then 'memberships'
        else 'services'
      end,
      'source_type',ec.source_type,
      'description',ec.description,
      'amount_cents',ec.amount_cents,
      'status',ec.status,
      'created_at',ec.created_at,
      'effective_at',ec.effective_at
    )
    order by ec.effective_at desc,ec.created_at desc
  ),'[]'::jsonb)
  into v_entries
  from effective_commissions ec
  join public.professionals p on p.id=ec.professional_id
  where ec.effective_at::date between p_start and p_end;

  return jsonb_build_object(
    'start',p_start,
    'end',p_end,
    'timezone',v_tz,
    'date_rule','appointment_date',
    'role',case when v_is_manager then 'manager' else 'barber' end,
    'unit_id',p_unit_id,
    'categories',jsonb_build_object(
      'services',jsonb_build_object(
        'gross_cents',v_service_gross,
        'refunds_cents',v_service_refunds,
        'fees_cents',v_service_fees,
        'net_cents',v_service_gross-v_service_refunds-v_service_fees
      ),
      'products',jsonb_build_object(
        'gross_cents',v_product_gross,
        'refunds_cents',v_product_refunds,
        'fees_cents',v_product_fees,
        'net_cents',v_product_gross-v_product_refunds-v_product_fees
      ),
      'memberships',jsonb_build_object(
        'gross_cents',v_membership_gross,
        'refunds_cents',v_membership_refunds,
        'fees_cents',v_membership_fees,
        'net_cents',v_membership_gross-v_membership_refunds-v_membership_fees
      )
    ),
    'net_received_cents',
      (v_service_gross-v_service_refunds-v_service_fees)
      +(v_product_gross-v_product_refunds-v_product_fees)
      +(v_membership_gross-v_membership_refunds-v_membership_fees),
    'commissions_cents',v_commissions,
    'house_cents',case when v_is_manager then
      (v_service_gross-v_service_refunds-v_service_fees)
      +(v_product_gross-v_product_refunds-v_product_fees)
      +(v_membership_gross-v_membership_refunds-v_membership_fees)
      -v_commissions
      else null end,
    'professionals',v_professionals,
    'entries',v_entries
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_booking_error_count(p_start date DEFAULT ((CURRENT_DATE - '90 days'::interval))::date, p_end date DEFAULT CURRENT_DATE)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  v_count integer:=0;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;

  select count(*)::int into v_count
  from public.appointments a
  where a.barbershop_id=m.barbershop_id
    and a.cancellation_kind='booking_error'
    and a.cancelled_at::date between p_start and p_end
    and (m.role in ('owner','admin') or a.professional_id=m.professional_id);

  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_cancel_package(p_membership_id uuid, p_reason text, p_manual_refund_cents integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; v_cm record; mode text; paid int; total int; used int; refund int:=0; pay record; refund_id uuid; ratio numeric:=0; ce record; q record; v_unit_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Motivo obrigatório'; end if;
  select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id
  where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update of xcm;
  if v_cm.id is null or v_cm.plan_type<>'package' then raise exception 'Pacote inválido'; end if;
  if v_cm.status in ('cancelled','expired') then raise exception 'Pacote já encerrado'; end if;
  mode:=coalesce(v_cm.rules->>'refund_mode','nonrefundable');

  select coalesce(sum(pb.quantity),0) into total from public.membership_plan_benefits pb where pb.plan_version_id=v_cm.plan_version_id and not pb.unlimited;
  select coalesce(sum(b.used_credits),0) into used from public.membership_credit_buckets b where b.membership_id=v_cm.id;
  if mode='no_after_use' and used>0 then raise exception 'Este pacote não permite cancelamento após o primeiro uso'; end if;
  select coalesce(sum(mp.amount_cents),0) into paid from public.membership_payments mp where mp.membership_id=v_cm.id;
  if mode='manual' then
    if p_manual_refund_cents is null or p_manual_refund_cents<0 or p_manual_refund_cents>paid then raise exception 'Informe um reembolso manual válido'; end if;
    refund:=p_manual_refund_cents;
  elsif mode='proportional' then
    if exists(select 1 from public.membership_plan_benefits pb where pb.plan_version_id=v_cm.plan_version_id and pb.unlimited) then raise exception 'Pacote ilimitado exige reembolso manual'; end if;
    refund:=case when total>0 then round(paid*greatest(0,total-least(used,total))::numeric/total)::int else 0 end;
  elsif mode='no_after_use' then refund:=paid;
  else refund:=0;
  end if;
  refund:=least(paid,greatest(0,refund));

  for q in select u.bucket_id,sum(u.credit_qty)::int qty from public.appointment_membership_uses u where u.membership_id=v_cm.id and u.status='reserved' and u.bucket_id is not null group by u.bucket_id loop
    update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-q.qty) where id=q.bucket_id;
  end loop;
  update public.appointment_membership_uses set status='released' where membership_id=v_cm.id and status='reserved';
  update public.customer_memberships set status='cancelled',renewal_blocked=true,cancel_effective_on=current_date,cancelled_at=now(),updated_at=now() where id=v_cm.id;

  select mp.id,mp.method into pay from public.membership_payments mp where mp.membership_id=v_cm.id order by mp.paid_at limit 1;
  v_unit_id:=coalesce(v_cm.origin_unit_id,(select u.id from public.units u where u.barbershop_id=m.barbershop_id and u.is_active order by u.created_at limit 1));
  if refund>0 then
    insert into public.finance_refunds(barbershop_id,unit_id,appointment_id,membership_id,membership_payment_id,amount_cents,reason,actor_member_id,refund_method)
    values(m.barbershop_id,v_unit_id,null,v_cm.id,pay.id,refund,trim(p_reason),m.member_id,pay.method) returning id into refund_id;
    ratio:=case when paid>0 then refund::numeric/paid else 0 end;
    for ce in select * from public.commission_entries where barbershop_id=m.barbershop_id and source_type='membership_sale' and source_id=v_cm.id and amount_cents>0 loop
      insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents,status)
      values(ce.barbershop_id,ce.unit_id,ce.professional_id,null,'membership_refund',refund_id,'Estorno de comissão por reembolso de pacote',-round(ce.base_cents*ratio)::int,ce.rate_percent,-round(ce.amount_cents*ratio)::int,'open');
    end loop;
    if pay.method='cash' then
      insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
      select cs.id,m.barbershop_id,v_unit_id,'refund',-refund,'membership_refund',refund_id,'Reembolso de pacote',m.member_id
      from public.cash_sessions cs where cs.unit_id=v_unit_id and cs.status='open' order by cs.opened_at desc limit 1;
    end if;
  end if;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(v_cm.id,'package_cancelled',jsonb_build_object('refund_mode',mode,'refund_cents',refund,'reason',trim(p_reason),'refund_id',refund_id),m.member_id);
  return jsonb_build_object('ok',true,'refund_mode',mode,'refund_cents',refund,'refund_id',refund_id);
end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_commission_preview(p_professional_id uuid, p_start date, p_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; v_prof record; v_count int; v_total int; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if; select p.id,p.name,p.unit_id into v_prof from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id; if v_prof.id is null then raise exception 'Profissional inválido'; end if; select count(*)::int,coalesce(sum(ce.amount_cents),0)::int into v_count,v_total from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_start and p_end; return jsonb_build_object('professional',jsonb_build_object('id',v_prof.id,'name',v_prof.name,'unit_id',v_prof.unit_id),'period_start',p_start,'period_end',p_end,'count',v_count,'total_cents',v_total,'entries',coalesce((select jsonb_agg(jsonb_build_object('id',ce.id,'created_at',ce.created_at,'amount_cents',ce.amount_cents,'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,'source_type',ce.source_type,'description',ce.description,'appointment_id',ce.appointment_id,'appointment',case when a.id is null then null else jsonb_build_object('starts_at',a.starts_at,'customer',coalesce(c.full_name,'Cliente'),'service',coalesce(a.service_name_snapshot,s.name,'Serviço'),'unit',coalesce(a.unit_name_snapshot,u.name),'total_price_cents',a.total_price_cents) end) order by ce.created_at,ce.id) from public.commission_entries ce left join public.appointments a on a.id=ce.appointment_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.units u on u.id=ce.unit_id where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_start and p_end),'[]'::jsonb)); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_commission_settlements(p_professional_id uuid DEFAULT NULL::uuid, p_start date DEFAULT ((CURRENT_DATE - '1 year'::interval))::date, p_end date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if; if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if; return jsonb_build_object('professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'unit_id',p.unit_id,'unsettled_cents',coalesce(oe.amount,0),'in_settlement_cents',coalesce(os.amount,0),'due_cents',coalesce(oe.amount,0)+coalesce(os.amount,0)) order by p.sort_order,p.name) from public.professionals p left join lateral(select coalesce(sum(ce.amount_cents),0)::int amount from public.commission_entries ce where ce.professional_id=p.id and ce.status='open' and ce.settlement_id is null) oe on true left join lateral(select coalesce(sum(greatest(0,cs.total_cents-cs.paid_cents)),0)::int amount from public.commission_settlements cs where cs.professional_id=p.id and cs.status in ('open','partial')) os on true where p.barbershop_id=m.barbershop_id and p.is_active),'[]'::jsonb),'settlements',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'professional_id',cs.professional_id,'professional',p.name,'period_start',cs.period_start,'period_end',cs.period_end,'base_cents',cs.base_cents,'adjustment_cents',cs.adjustment_cents,'total_cents',cs.total_cents,'paid_cents',cs.paid_cents,'remaining_cents',greatest(0,cs.total_cents-cs.paid_cents),'status',cs.status,'note',cs.note,'created_at',cs.created_at,'closed_at',cs.closed_at) order by cs.period_end desc,cs.created_at desc) from public.commission_settlements cs join public.professionals p on p.id=cs.professional_id where cs.barbershop_id=m.barbershop_id and (p_professional_id is null or cs.professional_id=p_professional_id) and cs.period_end>=p_start and cs.period_start<=p_end),'[]'::jsonb)); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_create_commission_settlement(p_professional_id uuid, p_period_start date, p_period_end date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; v_prof record; v_total int; v_count int; v_id uuid; v_status text; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; if p_period_start is null or p_period_end is null or p_period_end<p_period_start then raise exception 'Período inválido'; end if; select p.id,p.name into v_prof from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id; if v_prof.id is null then raise exception 'Profissional inválido'; end if; perform 1 from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_period_start and p_period_end for update; select count(*)::int,coalesce(sum(ce.amount_cents),0)::int into v_count,v_total from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_period_start and p_period_end; if v_count=0 then raise exception 'Nenhuma comissão em aberto neste período'; end if; if v_total<0 then raise exception 'O total em aberto deste período não pode ser negativo'; end if; v_status:=case when v_total=0 then 'paid' else 'open' end; insert into public.commission_settlements(barbershop_id,professional_id,period_start,period_end,base_cents,adjustment_cents,total_cents,paid_cents,status,note,closed_at,created_by_member_id) values(m.barbershop_id,p_professional_id,p_period_start,p_period_end,v_total,0,v_total,0,v_status,nullif(trim(coalesce(p_note,'')),''),case when v_total=0 then now() else null end,m.member_id) returning id into v_id; update public.commission_entries set settlement_id=v_id,status='settled' where barbershop_id=m.barbershop_id and professional_id=p_professional_id and status='open' and settlement_id is null and created_at::date between p_period_start and p_period_end; return jsonb_build_object('ok',true,'settlement_id',v_id,'entries',v_count,'total_cents',v_total,'status',v_status); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_create_expense(p_unit_id uuid, p_category_id uuid, p_description text, p_amount_cents integer, p_due_date date, p_status text, p_payment_method text DEFAULT NULL::text, p_paid_from_cash boolean DEFAULT false, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; perms jsonb; v_id uuid; v_session uuid; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; if m.role='barber' and not barberium.permission_enabled(perms,'register_expense') then raise exception 'Sem permissão para registrar despesa'; end if; if not exists(select 1 from public.units where id=p_unit_id and barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if; if p_category_id is not null and not exists(select 1 from public.expense_categories where id=p_category_id and barbershop_id=m.barbershop_id) then raise exception 'Categoria inválida'; end if; if p_amount_cents<=0 or trim(coalesce(p_description,''))='' or p_status not in ('predicted','paid') then raise exception 'Dados da despesa inválidos'; end if; insert into public.expenses(barbershop_id,unit_id,category_id,description,amount_cents,due_date,status,payment_method,paid_from_cash,paid_at,note,created_by_member_id,paid_by_member_id) values(m.barbershop_id,p_unit_id,p_category_id,trim(p_description),p_amount_cents,coalesce(p_due_date,current_date),p_status,p_payment_method,coalesce(p_paid_from_cash,false),case when p_status='paid' then now() end,nullif(trim(coalesce(p_note,'')),''),m.member_id,case when p_status='paid' then m.member_id end) returning id into v_id; if p_status='paid' and p_paid_from_cash then select id into v_session from public.cash_sessions where unit_id=p_unit_id and status='open' order by opened_at desc limit 1; if v_session is null then raise exception 'Abra o caixa antes de pagar a despesa em dinheiro do caixa'; end if; insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,p_unit_id,'expense',-p_amount_cents,'expense',v_id,p_description,m.member_id); end if; return jsonb_build_object('ok',true,'id',v_id); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_decide_membership_action_request(p_request_id uuid, p_approve boolean, p_decision_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; r record; v_cm record; v_days int; v_mode text;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 select req.*,v.rules,xcm.plan_type,xcm.status membership_status,xcm.current_cycle_end,xcm.paused_until,xcm.renewal_blocked into r from public.membership_action_requests req join public.customer_memberships xcm on xcm.id=req.membership_id join public.membership_plan_versions v on v.id=xcm.plan_version_id where req.id=p_request_id and req.barbershop_id=m.barbershop_id and req.status='pending' for update of req; if r.id is null then raise exception 'Solicitação inválida'; end if;
 if not p_approve then update public.membership_action_requests set status='rejected',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id; insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(r.membership_id,'customer_action_rejected',jsonb_build_object('request_id',r.id,'action',r.action_type,'note',p_decision_note),m.member_id); return jsonb_build_object('ok',true,'status','rejected'); end if;
 select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id where xcm.id=r.membership_id for update of xcm; if v_cm.plan_type<>'subscription' then raise exception 'Ação disponível apenas para assinatura'; end if;
 if r.action_type='pause' then if v_cm.status<>'active' then raise exception 'Somente assinatura ativa pode ser pausada'; end if; if not coalesce((v_cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if; v_days:=greatest(1,coalesce(r.requested_days,0)); if nullif(v_cm.rules->>'pause_min_days','')::int is not null and v_days<(v_cm.rules->>'pause_min_days')::int then raise exception 'Pausa abaixo do mínimo'; end if; if nullif(v_cm.rules->>'pause_max_days','')::int is not null and v_days>(v_cm.rules->>'pause_max_days')::int then raise exception 'Pausa acima do máximo'; end if; update public.customer_memberships set status='paused',pause_started_at=now(),paused_until=current_date+v_days,current_cycle_end=case when current_cycle_end is null then null else current_cycle_end+v_days end,cancel_effective_on=case when cancel_effective_on is null then null else cancel_effective_on+v_days end,renewal_shift_days=renewal_shift_days+v_days,updated_at=now() where id=v_cm.id; update public.membership_cycles set cycle_end=cycle_end+v_days where membership_id=v_cm.id and cycle_start<=current_date and cycle_end>=current_date and status='paid'; insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'paused',jsonb_build_object('request_id',r.id,'days',v_days,'resume_on',current_date+v_days,'note',p_decision_note),m.member_id);
 else if not coalesce((v_cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite cancelamento'; end if; v_mode:='end_cycle'; update public.customer_memberships set renewal_blocked=true,cancel_effective_on=v_cm.current_cycle_end,updated_at=now() where id=v_cm.id; insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'cancellation_approved',jsonb_build_object('request_id',r.id,'mode',v_mode,'effective_on',v_cm.current_cycle_end,'note',p_decision_note),m.member_id); end if;
 update public.membership_action_requests set status='approved',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id; return jsonb_build_object('ok',true,'status','approved');
end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_decide_membership_request(p_request_id uuid, p_approve boolean, p_unit_id uuid, p_mark_paid boolean DEFAULT false, p_payment_method text DEFAULT 'pix'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; r record; result jsonb; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; select * into r from public.membership_requests where id=p_request_id and barbershop_id=m.barbershop_id and status='pending' for update; if r.id is null then raise exception 'Solicitação inválida'; end if; if p_approve then result:=public.barberium_staff_assign_membership(r.customer_id,r.plan_id,p_unit_id,current_date,p_mark_paid,p_payment_method); update public.membership_requests set status='approved',decided_at=now(),decided_by_member_id=m.member_id where id=r.id; else update public.membership_requests set status='rejected',decided_at=now(),decided_by_member_id=m.member_id where id=r.id; result:=jsonb_build_object('ok',true); end if; return result; end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_overview(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; gross int; fees int; expenses_paid int; commissions int; receivables int; target int; result int; refunds int; appointment_gross int; membership_gross int; appointment_fees int; membership_fees int; product_gross int; product_fees int; product_pending int; product_cost int; cancelled_pending int:=0;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Financeiro geral restrito ao ADM'; end if; if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
 if p_basis='cash' then
   select coalesce(sum(ap.amount_cents),0),coalesce(sum(ap.fee_cents),0) into appointment_gross,appointment_fees from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id);
 else
   select coalesce(sum(case when a.status='cancelled' then coalesce((select (ev.details->>'service_due_cents')::int from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund' order by ev.created_at desc limit 1),a.total_price_cents) else greatest(0,a.total_price_cents-coalesce((select sum(u.coverage_cents) from public.appointment_membership_uses u where u.appointment_id=a.id and u.status='consumed'),0)) end),0),coalesce(sum((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id)),0) into appointment_gross,appointment_fees from public.appointments a where a.barbershop_id=m.barbershop_id and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund')) and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id);
 end if;
 select coalesce(sum(mp.amount_cents),0),coalesce(sum(mp.fee_cents),0) into membership_gross,membership_fees from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id);
 if p_basis='cash' then
 select coalesce(sum(amount_cents),0),coalesce(sum(fee_cents),0) into product_gross,product_fees from public.product_sale_payments where barbershop_id=m.barbershop_id and received_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id);
 else
 select coalesce(sum(total_cents),0),coalesce(sum((select sum(fee_cents) from public.product_sale_payments where sale_id=ps.id)),0) into product_gross,product_fees from public.product_sales ps where barbershop_id=m.barbershop_id and status in ('completed','refunded') and completed_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id);
 end if;
 select coalesce(sum(cost_total_cents),0) into product_cost from public.product_sales where barbershop_id=m.barbershop_id and status='completed' and completed_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id);
 gross:=appointment_gross+membership_gross+product_gross; fees:=appointment_fees+membership_fees+product_fees;
 select coalesce(sum(fr.amount_cents),0) into refunds from public.finance_refunds fr where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id);
 select coalesce(sum(e.amount_cents),0) into expenses_paid from public.expenses e where e.barbershop_id=m.barbershop_id and e.status='paid' and (case when p_basis='cash' then coalesce(e.paid_at::date,e.due_date) else e.due_date end) between p_start and p_end and (p_unit_id is null or e.unit_id=p_unit_id);
 select coalesce(sum(ce.amount_cents),0) into commissions from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into receivables from public.appointment_receivables ar where ar.barbershop_id=m.barbershop_id and ar.status in ('open','partial') and (p_unit_id is null or ar.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into product_pending from public.product_sale_receivables where barbershop_id=m.barbershop_id and status in ('open','partial') and (p_unit_id is null or unit_id=p_unit_id); receivables:=receivables+product_pending;
 select revenue_target_cents into target from public.financial_goals fg where fg.barbershop_id=m.barbershop_id and fg.unit_id is not distinct from p_unit_id and fg.month=date_trunc('month',p_end)::date;
 if p_basis='accrual' then select coalesce(sum((ev.details->>'service_pending_cancelled_cents')::int),0) into cancelled_pending from public.appointment_events ev join public.appointments ap on ap.id=ev.appointment_id where ev.barbershop_id=m.barbershop_id and ev.event_type='cancelled_with_refund' and ev.created_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id); cancelled_pending:=cancelled_pending+coalesce((select sum(pending_cents) from public.product_sales where barbershop_id=m.barbershop_id and status='refunded' and refunded_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id)),0); end if;
 result:=gross-refunds-cancelled_pending-fees-commissions-expenses_paid-product_cost;
 return jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'product_revenue_cents',product_gross,'product_cost_cents',product_cost,'service_revenue_cents',appointment_gross,'gross_cents',gross,'refunds_cents',refunds,'fees_cents',fees,'cancelled_pending_cents',cancelled_pending,'net_received_cents',gross-refunds-cancelled_pending-fees,'expenses_cents',expenses_paid,'commissions_cents',commissions,'operating_result_cents',result,'receivables_cents',receivables,'revenue_target_cents',target,'target_progress_percent',case when coalesce(target,0)>0 then round((gross-refunds)*100.0/target,1) else null end,'by_method',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_cents',amount) order by amount desc) from (
   select method,sum(amount_cents)::int amount from (
     select ap.method,ap.amount_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
     union all
     select mp.method,mp.amount_cents from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
     union all select method,amount_cents from public.product_sale_payments where barbershop_id=m.barbershop_id and received_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id)
   ) x group by method
 ) q),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_my_commissions(p_start date DEFAULT ((CURRENT_DATE - '90 days'::interval))::date, p_end date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  prof uuid;
  v_unsettled int;
  v_settlement_due int;
  v_booking_errors int;
  v_entries jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;
  prof:=m.professional_id;
  if prof is null then
    return jsonb_build_object('entries','[]'::jsonb,'settlements','[]'::jsonb,'open_cents',0,'unsettled_cents',0,'in_settlement_cents',0,'booking_error_cancellations',0);
  end if;

  select coalesce(sum(amount_cents),0)::int into v_unsettled
  from public.commission_entries
  where professional_id=prof and status='open' and settlement_id is null;

  select coalesce(sum(greatest(0,total_cents-paid_cents)),0)::int into v_settlement_due
  from public.commission_settlements
  where professional_id=prof and status in ('open','partial');

  select count(*)::int into v_booking_errors
  from public.appointments a
  where a.professional_id=prof
    and a.barbershop_id=m.barbershop_id
    and a.cancellation_kind='booking_error'
    and a.cancelled_at::date between p_start and p_end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',ce.id,
    'amount_cents',ce.amount_cents,
    'description',ce.description,
    'created_at',ce.created_at,
    'status',ce.status,
    'settlement_id',ce.settlement_id
  ) order by ce.created_at desc),'[]'::jsonb)
  into v_entries
  from public.commission_entries ce
  left join public.appointments a on a.id=ce.appointment_id
  where ce.professional_id=prof
    and ce.created_at::date between p_start and p_end
    and coalesce(a.cancellation_kind,'regular')<>'booking_error';

  if v_booking_errors>0 then
    v_entries:=jsonb_build_array(jsonb_build_object(
      'id',null,
      'amount_cents',0,
      'description','Cancelamentos por erro de agendamento: '||v_booking_errors,
      'created_at',p_end::timestamp+interval '23 hours 59 minutes',
      'status','open',
      'settlement_id',null,
      'booking_error_summary',true
    ))||v_entries;
  end if;

  return jsonb_build_object(
    'open_cents',v_unsettled+v_settlement_due,
    'unsettled_cents',v_unsettled,
    'in_settlement_cents',v_settlement_due,
    'booking_error_cancellations',v_booking_errors,
    'entries',v_entries,
    'settlements',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',cs.id,
        'period_start',cs.period_start,
        'period_end',cs.period_end,
        'base_cents',cs.base_cents,
        'adjustment_cents',cs.adjustment_cents,
        'total_cents',cs.total_cents,
        'paid_cents',cs.paid_cents,
        'remaining_cents',greatest(0,cs.total_cents-cs.paid_cents),
        'status',cs.status,
        'note',cs.note,
        'created_at',cs.created_at,
        'closed_at',cs.closed_at
      ) order by cs.period_end desc,cs.created_at desc)
      from public.commission_settlements cs
      where cs.professional_id=prof and cs.period_end>=p_start and cs.period_start<=p_end
    ),'[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_product_report(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; v_unit uuid; rev integer; refunds integer; cost integer; units_sold integer; sales_count integer; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; if m.role='barber' then select unit_id into v_unit from public.professionals where id=m.professional_id; else v_unit:=p_unit_id; end if; select coalesce(sum(sp.amount_cents),0) into rev from public.product_sale_payments sp join public.product_sales s on s.id=sp.sale_id where sp.barbershop_id=m.barbershop_id and sp.received_at::date between p_start and p_end and (v_unit is null or sp.unit_id=v_unit) and (m.role in ('owner','admin') or s.seller_professional_id=m.professional_id); select coalesce(sum(fr.amount_cents),0) into refunds from public.finance_refunds fr join public.product_sales s on s.id=fr.product_sale_id where fr.barbershop_id=m.barbershop_id and fr.product_sale_id is not null and fr.created_at::date between p_start and p_end and (v_unit is null or fr.unit_id=v_unit) and (m.role in ('owner','admin') or s.seller_professional_id=m.professional_id); select coalesce(sum(i.quantity*i.unit_cost_cents),0),coalesce(sum(i.quantity),0),count(distinct s.id) into cost,units_sold,sales_count from public.product_sales s join public.product_sale_items i on i.sale_id=s.id where s.barbershop_id=m.barbershop_id and s.status='completed' and s.completed_at::date between p_start and p_end and (v_unit is null or s.unit_id=v_unit) and (m.role in ('owner','admin') or s.seller_professional_id=m.professional_id); return jsonb_build_object('start',p_start,'end',p_end,'revenue_cents',rev,'refunds_cents',refunds,'net_revenue_cents',rev-refunds,'cost_cents',case when m.role in ('owner','admin') then cost else null end,'gross_profit_estimate_cents',case when m.role in ('owner','admin') then (rev-refunds-cost) else null end,'units_sold',units_sold,'sales_count',sales_count,'low_stock',coalesce((select jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.name,'quantity',coalesce(i.quantity,0),'min_stock',p.min_stock) order by coalesce(i.quantity,0),p.name) from public.products p left join public.product_inventory i on i.product_id=p.id and i.unit_id=coalesce(v_unit,(select id from public.units where barbershop_id=m.barbershop_id and is_active order by created_at limit 1)) where p.barbershop_id=m.barbershop_id and p.is_active and coalesce(i.quantity,0)<=p.min_stock),'[]'::jsonb),'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',q.product_id,'name',q.name,'quantity',q.qty,'revenue_cents',q.revenue) order by q.revenue desc,q.qty desc) from (select i.product_id,max(i.product_name_snapshot) name,sum(i.quantity)::int qty,sum(i.line_total_cents)::int revenue from public.product_sales s join public.product_sale_items i on i.sale_id=s.id where s.barbershop_id=m.barbershop_id and s.status='completed' and s.completed_at::date between p_start and p_end and (v_unit is null or s.unit_id=v_unit) and (m.role in ('owner','admin') or s.seller_professional_id=m.professional_id) group by i.product_id order by revenue desc limit 10) q),'[]'::jsonb)); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_product_sales(p_start date DEFAULT ((CURRENT_DATE - '30 days'::interval))::date, p_end date DEFAULT CURRENT_DATE, p_unit_id uuid DEFAULT NULL::uuid, p_customer_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'status',x.status,'unit_id',x.unit_id,'unit',u.name,'customer_id',x.customer_id,'customer',c.full_name,'appointment_id',x.appointment_id,'seller_professional_id',x.seller_professional_id,'seller',pr.name,'total_cents',x.total_cents,'paid_cents',x.paid_cents,'pending_cents',x.pending_cents,'cost_total_cents',case when m.role in ('owner','admin') then x.cost_total_cents else null end,'completed_at',x.completed_at,'refunded_at',x.refunded_at,'items',coalesce((select sum(i.quantity) from public.product_sale_items i where i.sale_id=x.id),0)) order by x.completed_at desc) from (select * from public.product_sales s where s.barbershop_id=m.barbershop_id and s.status in ('completed','refunded') and s.completed_at::date between p_start and p_end and (p_unit_id is null or s.unit_id=p_unit_id) and (p_customer_id is null or s.customer_id=p_customer_id) and (m.role in ('owner','admin') or s.seller_professional_id=m.professional_id) order by s.completed_at desc limit greatest(1,least(coalesce(p_limit,100),500))) x join public.units u on u.id=x.unit_id left join public.customers c on c.id=x.customer_id left join public.professionals pr on pr.id=x.seller_professional_id),'[]'::jsonb); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_record_membership_payment(p_membership_id uuid, p_cycle_id uuid DEFAULT NULL::uuid, p_method text DEFAULT 'pix'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; perms jsonb; v_cm record; cyc record; amount int; v_session uuid; v_unit uuid; late_mode text; dayn int; new_end date;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; if m.role='barber' and not barberium.permission_enabled(perms,'confirm_membership_payment') then raise exception 'Sem permissão para confirmar pagamento de plano'; end if; if p_method not in ('pix','cash','debit','credit') then raise exception 'Forma de pagamento inválida'; end if;
 select xcm.*,pv.price_cents,pv.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update of xcm; if v_cm.id is null then raise exception 'Plano do cliente inválido'; end if; v_unit:=coalesce(v_cm.origin_unit_id,(select u.id from public.units u where u.barbershop_id=m.barbershop_id and u.is_active order by u.created_at limit 1));
 if v_cm.plan_type='subscription' then
   perform barberium.subscription_refresh_one(v_cm.id,current_date);
   select mc.* into cyc from public.membership_cycles mc where mc.id=coalesce(p_cycle_id,(select mc2.id from public.membership_cycles mc2 where mc2.membership_id=v_cm.id and mc2.status in ('pending','overdue') order by mc2.due_date limit 1)) and mc.membership_id=v_cm.id for update of mc;
   if cyc.id is null then raise exception 'Mensalidade pendente não encontrada'; end if; if exists(select 1 from public.membership_payments mp where mp.cycle_id=cyc.id) then raise exception 'Mensalidade já paga'; end if; amount:=cyc.amount_cents; late_mode:=coalesce(v_cm.rules->>'late_payment_cycle_mode','retroactive');
   if cyc.status='overdue' and late_mode='from_payment' then dayn:=extract(day from current_date)::int; new_end:=barberium.next_renewal_after(current_date,dayn,0)-1; update public.membership_cycles set cycle_start=current_date,cycle_end=new_end,due_date=current_date,grace_until=current_date,status='pending' where id=cyc.id; update public.customer_memberships set current_cycle_start=current_date,current_cycle_end=new_end,cycle_mode='signup_date',renewal_day=dayn,renewal_shift_days=0 where id=v_cm.id; cyc.cycle_start:=current_date; cyc.cycle_end:=new_end; end if;
   insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id) values(v_cm.id,cyc.id,amount,p_method,m.member_id); update public.membership_cycles set status='paid',paid_at=now(),credits_released=true where id=cyc.id; update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),current_cycle_start=cyc.cycle_start,current_cycle_end=cyc.cycle_end,updated_at=now() where id=v_cm.id;
 else
   if exists(select 1 from public.membership_payments mp where mp.membership_id=v_cm.id) then raise exception 'Pacote já foi pago'; end if; amount:=v_cm.price_cents; insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id) values(v_cm.id,amount,p_method,m.member_id); update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),updated_at=now() where id=v_cm.id; perform barberium.release_membership_credits(v_cm.id,null);
 end if;
 if p_method='cash' and v_unit is not null then select cs.id into v_session from public.cash_sessions cs where cs.unit_id=v_unit and cs.status='open' order by cs.opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,v_unit,'payment',amount,'membership',v_cm.id,'Pagamento integral de plano',m.member_id); end if; end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'payment_confirmed',jsonb_build_object('amount_cents',amount,'method',p_method,'payment_required_full',true,'late_cycle_mode',case when v_cm.plan_type='subscription' then coalesce(late_mode,'retroactive') else null end),m.member_id); if v_cm.plan_type='subscription' then perform barberium.subscription_refresh_one(v_cm.id,current_date); end if; return jsonb_build_object('ok',true,'amount_cents',amount,'status',(select status from public.customer_memberships where id=v_cm.id));
end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_special_hours(p_unit_id uuid, p_professional_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'date',h.special_date,'open_time',to_char(h.open_time,'HH24:MI'),'close_time',to_char(h.close_time,'HH24:MI'),'is_closed',h.is_closed,'note',h.note,'professional_id',h.professional_id) order by h.special_date) from public.special_business_hours h where h.barbershop_id=m.barbershop_id and h.unit_id=p_unit_id and h.professional_id is not distinct from p_professional_id and h.special_date>=current_date-30),'[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION barberium.refresh_customer_membership_states(p_customer_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'pg_temp'
AS $function$ declare r record; begin for r in select id,paused_until,renewal_blocked,cancel_effective_on from public.customer_memberships where customer_id=p_customer_id and status='paused' and paused_until is not null and paused_until<=current_date for update loop if r.renewal_blocked and r.cancel_effective_on is not null and r.cancel_effective_on<current_date then update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),pause_started_at=null,paused_until=null,updated_at=now() where id=r.id; insert into public.membership_events(membership_id,event_type,details) values(r.id,'cancelled_effective',jsonb_build_object('effective_on',r.cancel_effective_on)); else update public.customer_memberships set status='active',pause_started_at=null,paused_until=null,updated_at=now() where id=r.id; insert into public.membership_events(membership_id,event_type,details) values(r.id,'pause_finished',jsonb_build_object('resumed_on',current_date)); end if; end loop; for r in select id,cancel_effective_on from public.customer_memberships where customer_id=p_customer_id and status in ('active','pending','overdue') and renewal_blocked and cancel_effective_on is not null and cancel_effective_on<current_date for update loop update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),updated_at=now() where id=r.id; insert into public.membership_events(membership_id,event_type,details) values(r.id,'cancelled_effective',jsonb_build_object('effective_on',r.cancel_effective_on)); end loop; for r in select id from public.customer_memberships where customer_id=p_customer_id and plan_type='subscription' and status in ('active','pending','overdue') loop perform barberium.subscription_refresh_one(r.id,current_date); end loop; end $function$;

drop function barberium.usar_fuso_da_barbearia(uuid);

delete from supabase_migrations.schema_migrations where version = '20261023100000';

commit;
