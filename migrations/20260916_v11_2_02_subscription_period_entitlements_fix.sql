-- Barberium v11.2 hotfix
-- Assinaturas são benefícios por período/ciclo, sem carteira persistente de créditos.
-- Pacotes continuam usando membership_credit_buckets.
-- Também corrige colisões de nomes de variáveis/aliases em RPCs v11.2.

create or replace function barberium.release_membership_credits(p_membership_id uuid,p_cycle_id uuid)
returns void language plpgsql security definer set search_path to 'public','barberium','pg_temp' as $$
declare v_membership record; ben record; expiry date; credit_validity text;
begin
  select xcm.*,pv.rules as version_rules into v_membership
  from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id
  where xcm.id=p_membership_id;
  if v_membership.id is null then return; end if;

  -- Assinatura não possui carteira de créditos. O ciclo pago apenas libera o direito temporal.
  if v_membership.plan_type='subscription' then
    if p_cycle_id is not null then update public.membership_cycles set credits_released=true where id=p_cycle_id; end if;
    return;
  end if;

  -- Pacote: libera os créditos comprados.
  for ben in select b.* from public.membership_plan_benefits b where b.plan_version_id=v_membership.plan_version_id loop
    credit_validity:=coalesce(v_membership.version_rules->>'credit_validity','no_expiry');
    expiry:=null;
    if credit_validity='fixed_days' then
      expiry:=coalesce(v_membership.started_at::date,current_date)+greatest(1,coalesce((v_membership.version_rules->>'fixed_validity_days')::int,30));
    else
      expiry:=v_membership.valid_until;
    end if;
    insert into public.membership_credit_buckets(membership_id,cycle_id,benefit_id,total_credits,expires_on)
    values(v_membership.id,null,ben.id,case when ben.unlimited then null else ben.quantity end,expiry);
  end loop;
end $$;

create or replace function public.barberium_staff_record_membership_payment(p_membership_id uuid,p_cycle_id uuid default null,p_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_cm record; cyc record; amount int; v_session uuid; v_unit uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'confirm_membership_payment') then raise exception 'Sem permissão para confirmar pagamento de plano'; end if;
 if p_method not in ('pix','cash','debit','credit') then raise exception 'Forma de pagamento inválida'; end if;

 select xcm.*,pv.price_cents into v_cm
 from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id
 where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update of xcm;
 if v_cm.id is null then raise exception 'Plano do cliente inválido'; end if;
 v_unit:=coalesce(v_cm.origin_unit_id,(select u.id from public.units u where u.barbershop_id=m.barbershop_id and u.is_active order by u.created_at limit 1));

 if v_cm.plan_type='subscription' then
   select mc.* into cyc from public.membership_cycles mc
   where mc.id=coalesce(p_cycle_id,(select mc2.id from public.membership_cycles mc2 where mc2.membership_id=v_cm.id and mc2.status in ('pending','overdue') order by mc2.due_date limit 1))
     and mc.membership_id=v_cm.id for update of mc;
   if cyc.id is null then raise exception 'Mensalidade pendente não encontrada'; end if;
   if exists(select 1 from public.membership_payments mp where mp.cycle_id=cyc.id) then raise exception 'Mensalidade já paga'; end if;
   amount:=cyc.amount_cents;
   insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id)
   values(v_cm.id,cyc.id,amount,p_method,m.member_id);
   update public.membership_cycles set status='paid',paid_at=now(),credits_released=true where id=cyc.id;
   update public.customer_memberships
   set status='active',started_at=coalesce(started_at,now()),current_cycle_start=cyc.cycle_start,current_cycle_end=cyc.cycle_end,updated_at=now()
   where id=v_cm.id;
 else
   if exists(select 1 from public.membership_payments mp where mp.membership_id=v_cm.id) then raise exception 'Pacote já foi pago'; end if;
   amount:=v_cm.price_cents;
   insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id)
   values(v_cm.id,amount,p_method,m.member_id);
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),updated_at=now() where id=v_cm.id;
   perform barberium.release_membership_credits(v_cm.id,null);
 end if;

 if p_method='cash' and v_unit is not null then
   select cs.id into v_session from public.cash_sessions cs where cs.unit_id=v_unit and cs.status='open' order by cs.opened_at desc limit 1;
   if v_session is not null then
     insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
     values(v_session,m.barbershop_id,v_unit,'payment',amount,'membership',v_cm.id,'Pagamento integral de plano',m.member_id);
   end if;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id)
 values(v_cm.id,'payment_confirmed',jsonb_build_object('amount_cents',amount,'method',p_method,'payment_required_full',true),m.member_id);
 return jsonb_build_object('ok',true,'amount_cents',amount,'status','active');
end $$;

create or replace function public.barberium_customer_request_membership_action(
  p_barbershop_slug text,p_access_token text,p_membership_id uuid,p_action_type text,p_requested_days int default null,p_note text default null
)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_b uuid; v_customer uuid; v_cm record; v_min int; v_max int; v_id uuid;
begin
  if p_action_type not in ('pause','cancel') then raise exception 'Ação inválida'; end if;
  select b.id into v_b from public.barbershops b where b.slug=p_barbershop_slug and b.status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id
  where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  perform barberium.refresh_customer_membership_states(v_customer);
  select xcm.*,pv.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id
  where xcm.id=p_membership_id and xcm.customer_id=v_customer and xcm.barbershop_id=v_b for update of xcm;
  if v_cm.id is null then raise exception 'Plano não encontrado'; end if;
  if v_cm.plan_type<>'subscription' then raise exception 'Esta solicitação é exclusiva para assinaturas'; end if;
  if v_cm.status not in ('active','paused','overdue') then raise exception 'Assinatura não está disponível para esta solicitação'; end if;

  if p_action_type='pause' then
    if v_cm.status<>'active' then raise exception 'Somente assinatura ativa pode ser pausada'; end if;
    if not coalesce((v_cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    if coalesce(p_requested_days,0)<=0 then raise exception 'Informe a duração da pausa'; end if;
    v_min:=nullif(v_cm.rules->>'pause_min_days','')::int; v_max:=nullif(v_cm.rules->>'pause_max_days','')::int;
    if v_min is not null and p_requested_days<v_min then raise exception 'Pausa abaixo do mínimo permitido'; end if;
    if v_max is not null and p_requested_days>v_max then raise exception 'Pausa acima do máximo permitido'; end if;
  else
    if not coalesce((v_cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite solicitação de cancelamento'; end if;
    if v_cm.renewal_blocked then raise exception 'O cancelamento desta assinatura já está programado'; end if;
  end if;

  insert into public.membership_action_requests(barbershop_id,customer_id,membership_id,action_type,requested_days,customer_note)
  values(v_b,v_customer,v_cm.id,p_action_type,case when p_action_type='pause' then p_requested_days end,nullif(trim(coalesce(p_note,'')),''))
  on conflict(membership_id,action_type) where status='pending'
  do update set requested_days=excluded.requested_days,customer_note=excluded.customer_note,created_at=now()
  returning id into v_id;
  insert into public.membership_events(membership_id,event_type,details)
  values(v_cm.id,'customer_action_requested',jsonb_build_object('request_id',v_id,'action',p_action_type,'requested_days',p_requested_days));
  return jsonb_build_object('ok',true,'request_id',v_id);
end $$;

create or replace function public.barberium_staff_decide_membership_action_request(p_request_id uuid,p_approve boolean,p_decision_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; r record; v_cm record; v_days int; v_mode text; q record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select req.*,v.rules,xcm.plan_type,xcm.status membership_status,xcm.current_cycle_end,xcm.paused_until,xcm.renewal_blocked
  into r from public.membership_action_requests req
  join public.customer_memberships xcm on xcm.id=req.membership_id
  join public.membership_plan_versions v on v.id=xcm.plan_version_id
  where req.id=p_request_id and req.barbershop_id=m.barbershop_id and req.status='pending' for update of req;
  if r.id is null then raise exception 'Solicitação inválida'; end if;
  if not p_approve then
    update public.membership_action_requests set status='rejected',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id)
    values(r.membership_id,'customer_action_rejected',jsonb_build_object('request_id',r.id,'action',r.action_type,'note',p_decision_note),m.member_id);
    return jsonb_build_object('ok',true,'status','rejected');
  end if;

  select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id where xcm.id=r.membership_id for update of xcm;
  if v_cm.plan_type<>'subscription' then raise exception 'Ação disponível apenas para assinatura'; end if;

  if r.action_type='pause' then
    if v_cm.status<>'active' then raise exception 'Somente assinatura ativa pode ser pausada'; end if;
    if not coalesce((v_cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    v_days:=greatest(1,coalesce(r.requested_days,0));
    if nullif(v_cm.rules->>'pause_min_days','')::int is not null and v_days<(v_cm.rules->>'pause_min_days')::int then raise exception 'Pausa abaixo do mínimo'; end if;
    if nullif(v_cm.rules->>'pause_max_days','')::int is not null and v_days>(v_cm.rules->>'pause_max_days')::int then raise exception 'Pausa acima do máximo'; end if;
    update public.customer_memberships set status='paused',pause_started_at=now(),paused_until=current_date+v_days,
      current_cycle_end=case when current_cycle_end is null then null else current_cycle_end+v_days end,
      cancel_effective_on=case when cancel_effective_on is null then null else cancel_effective_on+v_days end,updated_at=now()
    where id=v_cm.id;
    update public.membership_cycles set cycle_end=cycle_end+v_days where membership_id=v_cm.id and cycle_start<=current_date and cycle_end>=current_date and status='paid';
    insert into public.membership_events(membership_id,event_type,details,actor_member_id)
    values(v_cm.id,'paused',jsonb_build_object('request_id',r.id,'days',v_days,'resume_on',current_date+v_days,'note',p_decision_note),m.member_id);
  else
    if not coalesce((v_cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite cancelamento'; end if;
    v_mode:=coalesce(v_cm.rules->>'cancel_mode','end_cycle');
    if v_mode='immediate' or v_cm.current_cycle_end is null then
      for q in select u.bucket_id,sum(u.credit_qty)::int qty from public.appointment_membership_uses u where u.membership_id=v_cm.id and u.status='reserved' and u.bucket_id is not null group by u.bucket_id loop
        update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-q.qty) where id=q.bucket_id;
      end loop;
      update public.appointment_membership_uses set status='released' where membership_id=v_cm.id and status='reserved';
      update public.customer_memberships set status='cancelled',renewal_blocked=true,cancel_effective_on=current_date,cancelled_at=now(),pause_started_at=null,paused_until=null,updated_at=now() where id=v_cm.id;
    else
      update public.customer_memberships set renewal_blocked=true,cancel_effective_on=v_cm.current_cycle_end,updated_at=now() where id=v_cm.id;
    end if;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id)
    values(v_cm.id,'cancellation_approved',jsonb_build_object('request_id',r.id,'mode',v_mode,'effective_on',case when v_mode='immediate' then current_date else v_cm.current_cycle_end end,'note',p_decision_note),m.member_id);
  end if;
  update public.membership_action_requests set status='approved',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
  return jsonb_build_object('ok',true,'status','approved');
end $$;

create or replace function public.barberium_staff_cancel_package(p_membership_id uuid,p_reason text,p_manual_refund_cents int default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
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

  -- Reembolso proporcional usa a quantidade originalmente comprada na versão do pacote.
  -- Ajustes manuais de cortesia/correção não aumentam o valor reembolsável.
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
end $$;

create or replace function public.barberium_customer_membership_booking_options(
  p_barbershop_slug text,p_access_token text,p_unit_slug text,p_service_id uuid,p_addon_service_ids uuid[],p_date date
)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_b uuid; v_u uuid; v_customer uuid; v_tz text;
begin
  select b.id,coalesce(b.timezone,'America/Sao_Paulo') into v_b,v_tz from public.barbershops b where b.slug=p_barbershop_slug and b.status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select u.id into v_u from public.units u where u.barbershop_id=v_b and u.slug=p_unit_slug and u.is_active;
  if v_u is null then raise exception 'UNIT_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id
  where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  perform barberium.refresh_customer_membership_states(v_customer);

  return coalesce((
    with targets as (
      select p_service_id target_id,(select s.name from public.services s where s.id=p_service_id) target_name
      union all
      select x,(select s.name from public.services s where s.id=x) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x
    ), opts as (
      -- Pacotes: usam carteira real de créditos.
      select cm.id membership_id,mp.name plan,cm.plan_type,pb.id benefit_id,cb.id bucket_id,pb.service_id covered_service_id,s.name covered_service,
             t.target_id,t.target_name,barberium.membership_coverage_cents(pb.id,t.target_id) coverage_cents,pb.unlimited,
             case when cb.total_credits is null then null else greatest(0,cb.total_credits-cb.used_credits-cb.reserved_credits) end available,cb.expires_on
      from public.customer_memberships cm
      join public.membership_plans mp on mp.id=cm.plan_id
      join public.membership_plan_versions pv on pv.id=cm.plan_version_id
      join public.membership_plan_benefits pb on pb.plan_version_id=pv.id
      join public.services s on s.id=pb.service_id
      join public.membership_credit_buckets cb on cb.membership_id=cm.id and cb.benefit_id=pb.id
      cross join targets t
      where cm.customer_id=v_customer and cm.barbershop_id=v_b and cm.plan_type='package' and cm.status='active'
        and (cb.expires_on is null or cb.expires_on>=p_date)
        and (cb.total_credits is null or cb.total_credits-cb.used_credits-cb.reserved_credits>0)
        and (pb.service_id=t.target_id or exists(select 1 from public.service_components sc where sc.parent_service_id=t.target_id and sc.component_service_id=pb.service_id))
        and (coalesce(pv.rules->>'unit_scope','all')='all' or (pv.rules->>'unit_scope'='origin' and cm.origin_unit_id=v_u) or (pv.rules->>'unit_scope'='selected' and exists(select 1 from public.membership_plan_units pu where pu.plan_version_id=pv.id and pu.unit_id=v_u)))
        and (pb.min_days_between is null or not exists(select 1 from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and abs(((ax.starts_at at time zone v_tz)::date-p_date))<pb.min_days_between))
        and (pb.max_per_week is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and date_trunc('week',(ax.starts_at at time zone v_tz))::date=date_trunc('week',p_date)::date)<pb.max_per_week)
        and (pb.max_per_month is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and date_trunc('month',(ax.starts_at at time zone v_tz))::date=date_trunc('month',p_date)::date)<pb.max_per_month)
      union all
      -- Assinaturas: direito por período/ciclo; quantidade é limite de uso do ciclo, sem bucket.
      select cm.id,mp.name,cm.plan_type,pb.id,null::uuid,pb.service_id,s.name,t.target_id,t.target_name,
             barberium.membership_coverage_cents(pb.id,t.target_id),pb.unlimited,
             case when pb.unlimited then null else greatest(0,pb.quantity-(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end)) end,
             cm.current_cycle_end
      from public.customer_memberships cm
      join public.membership_plans mp on mp.id=cm.plan_id
      join public.membership_plan_versions pv on pv.id=cm.plan_version_id
      join public.membership_plan_benefits pb on pb.plan_version_id=pv.id
      join public.services s on s.id=pb.service_id
      cross join targets t
      where cm.customer_id=v_customer and cm.barbershop_id=v_b and cm.plan_type='subscription' and cm.status='active'
        and cm.current_cycle_start is not null and cm.current_cycle_end is not null and p_date between cm.current_cycle_start and cm.current_cycle_end
        and (pb.unlimited or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end)<coalesce(pb.quantity,0))
        and (pb.service_id=t.target_id or exists(select 1 from public.service_components sc where sc.parent_service_id=t.target_id and sc.component_service_id=pb.service_id))
        and (coalesce(pv.rules->>'unit_scope','all')='all' or (pv.rules->>'unit_scope'='origin' and cm.origin_unit_id=v_u) or (pv.rules->>'unit_scope'='selected' and exists(select 1 from public.membership_plan_units pu where pu.plan_version_id=pv.id and pu.unit_id=v_u)))
        and (pb.min_days_between is null or not exists(select 1 from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and abs(((ax.starts_at at time zone v_tz)::date-p_date))<pb.min_days_between))
        and (pb.max_per_week is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and date_trunc('week',(ax.starts_at at time zone v_tz))::date=date_trunc('week',p_date)::date)<pb.max_per_week)
        and (pb.max_per_month is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and date_trunc('month',(ax.starts_at at time zone v_tz))::date=date_trunc('month',p_date)::date)<pb.max_per_month)
    )
    select jsonb_agg(jsonb_build_object('membership_id',membership_id,'plan',plan,'plan_type',plan_type,'benefit_id',benefit_id,'bucket_id',bucket_id,
      'covered_service_id',covered_service_id,'covered_service',covered_service,'target_service_id',target_id,'target_service',target_name,
      'coverage_cents',coverage_cents,'unlimited',unlimited,'available',available,'expires_on',expires_on) order by plan,covered_service,target_name)
    from opts
  ),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_membership_options_for_appointment(p_appointment_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; a record; v_date date; v_tz text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
  select ap.* into a from public.appointments ap where ap.id=p_appointment_id and ap.barbershop_id=m.barbershop_id;
  if a.id is null then raise exception 'Atendimento inválido'; end if;
  if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if;
  select coalesce(b.timezone,'America/Sao_Paulo') into v_tz from public.barbershops b where b.id=m.barbershop_id;
  v_date:=(a.starts_at at time zone v_tz)::date;
  perform barberium.refresh_customer_membership_states(a.customer_id);

  return coalesce((
    with targets as (
      select a.service_id target_id,(select s.name from public.services s where s.id=a.service_id) target_name
      union all select aa.service_id,aa.name_snapshot from public.appointment_addons aa where aa.appointment_id=a.id
    ), opts as (
      select cm.id membership_id,mp.name plan,cm.plan_type,pb.id benefit_id,cb.id bucket_id,pb.service_id covered_service_id,s.name covered_service,
             t.target_id,t.target_name,barberium.membership_coverage_cents(pb.id,t.target_id) coverage_cents,pb.unlimited,
             case when cb.total_credits is null then null else greatest(0,cb.total_credits-cb.used_credits-cb.reserved_credits) end available,cb.expires_on
      from public.customer_memberships cm join public.membership_plans mp on mp.id=cm.plan_id join public.membership_plan_versions pv on pv.id=cm.plan_version_id
      join public.membership_plan_benefits pb on pb.plan_version_id=pv.id join public.services s on s.id=pb.service_id
      join public.membership_credit_buckets cb on cb.membership_id=cm.id and cb.benefit_id=pb.id cross join targets t
      where cm.customer_id=a.customer_id and cm.barbershop_id=m.barbershop_id and cm.plan_type='package' and cm.status='active'
        and (cb.expires_on is null or cb.expires_on>=v_date) and (cb.total_credits is null or cb.total_credits-cb.used_credits-cb.reserved_credits>0)
        and (pb.service_id=t.target_id or exists(select 1 from public.service_components sc where sc.parent_service_id=t.target_id and sc.component_service_id=pb.service_id))
        and not exists(select 1 from public.appointment_membership_uses u where u.appointment_id=a.id and u.benefit_id=pb.id and u.target_service_id=t.target_id and u.status in ('reserved','consumed','forfeited','decision_required'))
        and (coalesce(pv.rules->>'unit_scope','all')='all' or (pv.rules->>'unit_scope'='origin' and cm.origin_unit_id=a.unit_id) or (pv.rules->>'unit_scope'='selected' and exists(select 1 from public.membership_plan_units pu where pu.plan_version_id=pv.id and pu.unit_id=a.unit_id)))
        and (pb.min_days_between is null or not exists(select 1 from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and abs(((ax.starts_at at time zone v_tz)::date-v_date))<pb.min_days_between))
        and (pb.max_per_week is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and date_trunc('week',(ax.starts_at at time zone v_tz))::date=date_trunc('week',v_date)::date)<pb.max_per_week)
        and (pb.max_per_month is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and date_trunc('month',(ax.starts_at at time zone v_tz))::date=date_trunc('month',v_date)::date)<pb.max_per_month)
      union all
      select cm.id,mp.name,cm.plan_type,pb.id,null::uuid,pb.service_id,s.name,t.target_id,t.target_name,barberium.membership_coverage_cents(pb.id,t.target_id),pb.unlimited,
             case when pb.unlimited then null else greatest(0,pb.quantity-(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end)) end,
             cm.current_cycle_end
      from public.customer_memberships cm join public.membership_plans mp on mp.id=cm.plan_id join public.membership_plan_versions pv on pv.id=cm.plan_version_id
      join public.membership_plan_benefits pb on pb.plan_version_id=pv.id join public.services s on s.id=pb.service_id cross join targets t
      where cm.customer_id=a.customer_id and cm.barbershop_id=m.barbershop_id and cm.plan_type='subscription' and cm.status='active'
        and cm.current_cycle_start is not null and cm.current_cycle_end is not null and v_date between cm.current_cycle_start and cm.current_cycle_end
        and (pb.unlimited or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end)<coalesce(pb.quantity,0))
        and (pb.service_id=t.target_id or exists(select 1 from public.service_components sc where sc.parent_service_id=t.target_id and sc.component_service_id=pb.service_id))
        and not exists(select 1 from public.appointment_membership_uses u where u.appointment_id=a.id and u.benefit_id=pb.id and u.target_service_id=t.target_id and u.status in ('reserved','consumed','forfeited','decision_required'))
        and (coalesce(pv.rules->>'unit_scope','all')='all' or (pv.rules->>'unit_scope'='origin' and cm.origin_unit_id=a.unit_id) or (pv.rules->>'unit_scope'='selected' and exists(select 1 from public.membership_plan_units pu where pu.plan_version_id=pv.id and pu.unit_id=a.unit_id)))
        and (pb.min_days_between is null or not exists(select 1 from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and abs(((ax.starts_at at time zone v_tz)::date-v_date))<pb.min_days_between))
        and (pb.max_per_week is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and date_trunc('week',(ax.starts_at at time zone v_tz))::date=date_trunc('week',v_date)::date)<pb.max_per_week)
        and (pb.max_per_month is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and ax.id<>a.id and date_trunc('month',(ax.starts_at at time zone v_tz))::date=date_trunc('month',v_date)::date)<pb.max_per_month)
    )
    select jsonb_agg(jsonb_build_object('membership_id',membership_id,'plan',plan,'plan_type',plan_type,'benefit_id',benefit_id,'bucket_id',bucket_id,
      'covered_service_id',covered_service_id,'covered_service',covered_service,'target_service_id',target_id,'target_service',target_name,
      'coverage_cents',coverage_cents,'unlimited',unlimited,'available',available,'expires_on',expires_on) order by plan,covered_service,target_name) from opts
  ),'[]'::jsonb);
end $$;

create or replace function public.barberium_customer_reserve_membership_use(
  p_barbershop_slug text,p_access_token text,p_appointment_id uuid,p_membership_id uuid,p_benefit_id uuid,p_bucket_id uuid,p_target_service_id uuid
)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_b uuid; v_customer uuid; a record; v_tz text; v_date date; v_unit_slug text; v_addons uuid[]; opt jsonb; v_coverage int; v_existing uuid;
begin
  select b.id,coalesce(b.timezone,'America/Sao_Paulo') into v_b,v_tz from public.barbershops b where b.slug=p_barbershop_slug and b.status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  select ap.*,u.slug unit_slug into a from public.appointments ap join public.units u on u.id=ap.unit_id where ap.id=p_appointment_id and ap.barbershop_id=v_b and ap.customer_id=v_customer and ap.status='confirmed' for update of ap;
  if a.id is null then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  select u0.id into v_existing from public.appointment_membership_uses u0 where u0.appointment_id=a.id and u0.membership_id=p_membership_id and u0.benefit_id=p_benefit_id and u0.target_service_id=p_target_service_id and u0.status in ('reserved','consumed') limit 1;
  if v_existing is not null then return jsonb_build_object('ok',true,'use_id',v_existing,'already_reserved',true); end if;
  v_date:=(a.starts_at at time zone v_tz)::date; v_unit_slug:=a.unit_slug;
  select coalesce(array_agg(aa.service_id),'{}'::uuid[]) into v_addons from public.appointment_addons aa where aa.appointment_id=a.id;
  select x into opt from jsonb_array_elements(public.barberium_customer_membership_booking_options(p_barbershop_slug,p_access_token,v_unit_slug,a.service_id,v_addons,v_date)) x
  where (x->>'membership_id')::uuid=p_membership_id and (x->>'benefit_id')::uuid=p_benefit_id
    and (((x->>'bucket_id') is null and p_bucket_id is null) or (x->>'bucket_id')::uuid=p_bucket_id)
    and (x->>'target_service_id')::uuid=p_target_service_id limit 1;
  if opt is null then raise exception 'BENEFIT_UNAVAILABLE'; end if;
  v_coverage:=(opt->>'coverage_cents')::int;
  insert into public.appointment_membership_uses(appointment_id,membership_id,bucket_id,benefit_id,covered_service_id,target_service_id,status,credit_qty,coverage_cents)
  values(a.id,p_membership_id,p_bucket_id,p_benefit_id,(opt->>'covered_service_id')::uuid,p_target_service_id,'reserved',1,v_coverage) returning id into v_existing;
  if p_bucket_id is not null then update public.membership_credit_buckets set reserved_credits=reserved_credits+1 where id=p_bucket_id; end if;
  insert into public.membership_events(membership_id,event_type,details)
  values(p_membership_id,'benefit_reserved',jsonb_build_object('appointment_id',a.id,'benefit_id',p_benefit_id,'target_service_id',p_target_service_id,'coverage_cents',v_coverage,'plan_type',opt->>'plan_type','source','customer_site'));
  return jsonb_build_object('ok',true,'use_id',v_existing,'coverage_cents',v_coverage);
end $$;

create or replace function public.barberium_staff_reserve_membership_use(p_appointment_id uuid,p_membership_id uuid,p_benefit_id uuid,p_bucket_id uuid,p_target_service_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; a record; opt jsonb; v_coverage int; v_existing uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select ap.* into a from public.appointments ap where ap.id=p_appointment_id and ap.barbershop_id=m.barbershop_id and ap.status='confirmed' for update of ap;
  if a.id is null then raise exception 'Atendimento confirmado não encontrado'; end if;
  select u0.id into v_existing from public.appointment_membership_uses u0 where u0.appointment_id=a.id and u0.membership_id=p_membership_id and u0.benefit_id=p_benefit_id and u0.target_service_id=p_target_service_id and u0.status in ('reserved','consumed') limit 1;
  if v_existing is not null then return jsonb_build_object('ok',true,'use_id',v_existing,'already_reserved',true); end if;
  select x into opt from jsonb_array_elements(public.barberium_staff_membership_options_for_appointment(p_appointment_id)) x
  where (x->>'membership_id')::uuid=p_membership_id and (x->>'benefit_id')::uuid=p_benefit_id
    and (((x->>'bucket_id') is null and p_bucket_id is null) or (x->>'bucket_id')::uuid=p_bucket_id)
    and (x->>'target_service_id')::uuid=p_target_service_id limit 1;
  if opt is null then raise exception 'Benefício indisponível para este atendimento'; end if;
  v_coverage:=(opt->>'coverage_cents')::int;
  insert into public.appointment_membership_uses(appointment_id,membership_id,bucket_id,benefit_id,covered_service_id,target_service_id,status,credit_qty,coverage_cents)
  values(a.id,p_membership_id,p_bucket_id,p_benefit_id,(opt->>'covered_service_id')::uuid,p_target_service_id,'reserved',1,v_coverage) returning id into v_existing;
  if p_bucket_id is not null then update public.membership_credit_buckets set reserved_credits=reserved_credits+1 where id=p_bucket_id; end if;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(p_membership_id,'benefit_reserved',jsonb_build_object('appointment_id',a.id,'benefit_id',p_benefit_id,'target_service_id',p_target_service_id,'coverage_cents',v_coverage,'plan_type',opt->>'plan_type'),m.member_id);
  return jsonb_build_object('ok',true,'use_id',v_existing,'coverage_cents',v_coverage);
end $$;

create or replace function public.barberium_get_customer_portal(p_barbershop_slug text,p_access_token text)
returns jsonb language sql stable security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
with b as(select id,coalesce(timezone,'America/Sao_Paulo') tz from public.barbershops where slug=p_barbershop_slug and status='active'),
t as(select t.customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join b on b.id=c.barbershop_id where t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1),
c as(select c.* from public.customers c join t on t.customer_id=c.id)
select jsonb_build_object(
 'customer',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'phone_e164',c.phone_e164,'birthday',c.birthday) from c),
 'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'status',a.status,'starts_at',a.starts_at,'ends_at',a.ends_at,'total_price_cents',a.total_price_cents,'service',jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'duration_label',s.duration_label),'professional',jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path),'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',aa.price_cents,'duration_min',aa.duration_min)) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb)) order by a.starts_at desc) from public.appointments a join c on c.id=a.customer_id join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id),'[]'::jsonb),
 'memberships',coalesce((select jsonb_agg(jsonb_build_object(
   'id',cm.id,'plan_id',cm.plan_id,'name',mp.name,'plan_type',cm.plan_type,'status',cm.status,'price_cents',pv.price_cents,'started_at',cm.started_at,'valid_until',cm.valid_until,'current_cycle_start',cm.current_cycle_start,'current_cycle_end',cm.current_cycle_end,'rules',pv.rules,
   'credits',case when cm.plan_type='package' then coalesce((select jsonb_agg(jsonb_build_object('bucket_id',cb.id,'benefit_id',pb.id,'service_id',pb.service_id,'service',s.name,'total',cb.total_credits,'used',cb.used_credits,'reserved',cb.reserved_credits,'available',case when cb.total_credits is null then null else greatest(0,cb.total_credits-cb.used_credits-cb.reserved_credits) end,'expires_on',cb.expires_on,'unlimited',pb.unlimited) order by s.name) from public.membership_credit_buckets cb join public.membership_plan_benefits pb on pb.id=cb.benefit_id join public.services s on s.id=pb.service_id where cb.membership_id=cm.id),'[]'::jsonb)
             when cm.status='pending' then '[]'::jsonb
             else coalesce((select jsonb_agg(jsonb_build_object('bucket_id',null,'benefit_id',pb.id,'service_id',pb.service_id,'service',s.name,'total',pb.quantity,
               'used',(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id join b on true where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('consumed','forfeited') and (ax.starts_at at time zone b.tz)::date between cm.current_cycle_start and cm.current_cycle_end),
               'reserved',(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id join b on true where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','decision_required') and (ax.starts_at at time zone b.tz)::date between cm.current_cycle_start and cm.current_cycle_end),
               'available',case when pb.unlimited then null else greatest(0,pb.quantity-(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id join b on true where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and (ax.starts_at at time zone b.tz)::date between cm.current_cycle_start and cm.current_cycle_end)) end,
               'expires_on',cm.current_cycle_end,'unlimited',pb.unlimited) order by s.name) from public.membership_plan_benefits pb join public.services s on s.id=pb.service_id where pb.plan_version_id=cm.plan_version_id),'[]'::jsonb) end,
   'cycles',coalesce((select jsonb_agg(jsonb_build_object('id',mc.id,'start',mc.cycle_start,'end',mc.cycle_end,'due_date',mc.due_date,'grace_until',mc.grace_until,'amount_cents',mc.amount_cents,'status',mc.status,'paid_at',mc.paid_at) order by mc.cycle_start desc) from public.membership_cycles mc where mc.membership_id=cm.id),'[]'::jsonb)
 ) order by cm.created_at desc) from public.customer_memberships cm join c on c.id=cm.customer_id join public.membership_plans mp on mp.id=cm.plan_id join public.membership_plan_versions pv on pv.id=cm.plan_version_id),'[]'::jsonb),
 'membership_requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'plan_id',r.plan_id,'plan',p.name,'status',r.status,'created_at',r.created_at) order by r.created_at desc) from public.membership_requests r join c on c.id=r.customer_id join public.membership_plans p on p.id=r.plan_id),'[]'::jsonb)
);
$$;

create or replace function public.barberium_staff_customer_memberships(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_tz text;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; if m.role='barber' then raise exception 'Acesso restrito ao ADM'; end if;
 if not exists(select 1 from public.customers c where c.id=p_customer_id and c.barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if;
 perform barberium.refresh_customer_membership_states(p_customer_id);
 select coalesce(b.timezone,'America/Sao_Paulo') into v_tz from public.barbershops b where b.id=m.barbershop_id;
 return coalesce((select jsonb_agg(jsonb_build_object(
   'id',cm.id,'plan_id',cm.plan_id,'name',p.name,'plan_type',cm.plan_type,'status',cm.status,'price_cents',v.price_cents,'started_at',cm.started_at,'valid_until',cm.valid_until,'current_cycle_start',cm.current_cycle_start,'current_cycle_end',cm.current_cycle_end,
   'paused_until',cm.paused_until,'pause_started_at',cm.pause_started_at,'renewal_blocked',cm.renewal_blocked,'cancel_effective_on',cm.cancel_effective_on,'rules',v.rules,
   'credits',case when cm.plan_type='package' then coalesce((select jsonb_agg(jsonb_build_object('bucket_id',b.id,'benefit_id',b.benefit_id,'service_id',pb.service_id,'service',s.name,'total',b.total_credits,'used',b.used_credits,'reserved',b.reserved_credits,'available',case when b.total_credits is null then null else greatest(0,b.total_credits-b.used_credits-b.reserved_credits) end,'expires_on',b.expires_on,'unlimited',pb.unlimited) order by s.name) from public.membership_credit_buckets b join public.membership_plan_benefits pb on pb.id=b.benefit_id join public.services s on s.id=pb.service_id where b.membership_id=cm.id),'[]'::jsonb)
             when cm.status='pending' then '[]'::jsonb
             else coalesce((select jsonb_agg(jsonb_build_object('bucket_id',null,'benefit_id',pb.id,'service_id',pb.service_id,'service',s.name,'total',pb.quantity,
               'used',(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('consumed','forfeited') and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end),
               'reserved',(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','decision_required') and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end),
               'available',case when pb.unlimited then null else greatest(0,pb.quantity-(select count(*)::int from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed','forfeited','decision_required') and (ax.starts_at at time zone v_tz)::date between cm.current_cycle_start and cm.current_cycle_end)) end,
               'expires_on',cm.current_cycle_end,'unlimited',pb.unlimited) order by s.name) from public.membership_plan_benefits pb join public.services s on s.id=pb.service_id where pb.plan_version_id=cm.plan_version_id),'[]'::jsonb) end,
   'cycles',coalesce((select jsonb_agg(jsonb_build_object('id',mc.id,'start',mc.cycle_start,'end',mc.cycle_end,'due_date',mc.due_date,'grace_until',mc.grace_until,'amount_cents',mc.amount_cents,'status',mc.status,'paid_at',mc.paid_at) order by mc.cycle_start desc) from public.membership_cycles mc where mc.membership_id=cm.id),'[]'::jsonb),
   'events',coalesce((select jsonb_agg(jsonb_build_object('type',me.event_type,'details',me.details,'created_at',me.created_at) order by me.created_at desc) from public.membership_events me where me.membership_id=cm.id),'[]'::jsonb)
 ) order by cm.created_at desc)
 from public.customer_memberships cm join public.membership_plans p on p.id=cm.plan_id join public.membership_plan_versions v on v.id=cm.plan_version_id
 where cm.customer_id=p_customer_id and cm.barbershop_id=m.barbershop_id),'[]'::jsonb);
end $$;

grant execute on function public.barberium_customer_membership_booking_options(text,text,text,uuid,uuid[],date) to anon,authenticated;
grant execute on function public.barberium_customer_reserve_membership_use(text,text,uuid,uuid,uuid,uuid,uuid) to anon,authenticated;
grant execute on function public.barberium_staff_membership_options_for_appointment(uuid) to authenticated;
grant execute on function public.barberium_staff_reserve_membership_use(uuid,uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.barberium_get_customer_portal(text,text) to anon,authenticated;
grant execute on function public.barberium_staff_customer_memberships(uuid) to authenticated;
grant execute on function public.barberium_staff_record_membership_payment(uuid,uuid,text) to authenticated;
grant execute on function public.barberium_customer_request_membership_action(text,text,uuid,text,int,text) to anon,authenticated;
grant execute on function public.barberium_staff_decide_membership_action_request(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_cancel_package(uuid,text,int) to authenticated;

-- Corrige alias/record da decisão de no-show.
create or replace function public.barberium_staff_resolve_no_show_membership_use(p_use_id uuid,p_consume boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_use record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select au.*,xcm.barbershop_id into v_use from public.appointment_membership_uses au join public.customer_memberships xcm on xcm.id=au.membership_id
  where au.id=p_use_id and xcm.barbershop_id=m.barbershop_id and au.status='decision_required' for update of au;
  if v_use.id is null then raise exception 'Decisão de falta não encontrada'; end if;
  if v_use.bucket_id is not null then
    update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty),used_credits=used_credits+case when p_consume then v_use.credit_qty else 0 end where id=v_use.bucket_id;
  end if;
  update public.appointment_membership_uses set status=case when p_consume then 'forfeited' else 'released' end,consumed_at=case when p_consume then now() else null end where id=v_use.id;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(v_use.membership_id,'no_show_decided',jsonb_build_object('use_id',v_use.id,'appointment_id',v_use.appointment_id,'consume',p_consume,'note',nullif(trim(coalesce(p_note,'')),'')),m.member_id);
  return jsonb_build_object('ok',true,'status',case when p_consume then 'forfeited' else 'released' end);
end $$;
grant execute on function public.barberium_staff_resolve_no_show_membership_use(uuid,boolean,text) to authenticated;
