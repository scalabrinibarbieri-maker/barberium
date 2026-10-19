create or replace function public.barberium_staff_adjust_package_credit(p_membership_id uuid,p_bucket_id uuid,p_delta int,p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; cm record; b record; before_total int; after_total int; service_name text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if coalesce(p_delta,0)=0 then raise exception 'Informe uma quantidade diferente de zero'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Motivo obrigatório'; end if;
  select * into cm from public.customer_memberships where id=p_membership_id and barbershop_id=m.barbershop_id for update;
  if cm.id is null or cm.plan_type<>'package' then raise exception 'Pacote inválido'; end if;
  select cb.*,s.name into b from public.membership_credit_buckets cb join public.membership_plan_benefits pb on pb.id=cb.benefit_id join public.services s on s.id=pb.service_id
  where cb.id=p_bucket_id and cb.membership_id=cm.id for update;
  if b.id is null then raise exception 'Benefício inválido'; end if;
  if b.total_credits is null then raise exception 'Benefício ilimitado não aceita ajuste de créditos'; end if;
  before_total:=b.total_credits; after_total:=before_total+p_delta;
  if after_total<b.used_credits+b.reserved_credits then raise exception 'O saldo não pode ficar abaixo do que já foi usado ou reservado'; end if;
  if after_total<0 then raise exception 'Saldo inválido'; end if;
  update public.membership_credit_buckets set total_credits=after_total where id=b.id;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm.id,'package_credit_adjusted',jsonb_build_object('bucket_id',b.id,'service',b.name,'delta',p_delta,'before_total',before_total,'after_total',after_total,'reason',trim(p_reason)),m.member_id);
  return jsonb_build_object('ok',true,'before_total',before_total,'after_total',after_total,'available',greatest(0,after_total-b.used_credits-b.reserved_credits));
end $$;

create or replace function public.barberium_staff_cancel_package(p_membership_id uuid,p_reason text,p_manual_refund_cents int default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; cm record; mode text; paid int; total int; used int; refund int:=0; pay record; refund_id uuid; ratio numeric:=0; ce record; q record; v_unit_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Motivo obrigatório'; end if;
  select cm.*,v.rules into cm from public.customer_memberships cm join public.membership_plan_versions v on v.id=cm.plan_version_id
  where cm.id=p_membership_id and cm.barbershop_id=m.barbershop_id for update;
  if cm.id is null or cm.plan_type<>'package' then raise exception 'Pacote inválido'; end if;
  if cm.status in ('cancelled','expired') then raise exception 'Pacote já encerrado'; end if;
  mode:=coalesce(cm.rules->>'refund_mode','nonrefundable');
  select coalesce(sum(total_credits),0),coalesce(sum(used_credits),0) into total,used from public.membership_credit_buckets where membership_id=cm.id and total_credits is not null;
  if mode='no_after_use' and used>0 then raise exception 'Este pacote não permite cancelamento após o primeiro uso'; end if;
  select coalesce(sum(amount_cents),0) into paid from public.membership_payments where membership_id=cm.id;
  if mode='manual' then
    if p_manual_refund_cents is null or p_manual_refund_cents<0 or p_manual_refund_cents>paid then raise exception 'Informe um reembolso manual válido'; end if;
    refund:=p_manual_refund_cents;
  elsif mode='proportional' then
    if exists(select 1 from public.membership_credit_buckets where membership_id=cm.id and total_credits is null) then raise exception 'Pacote ilimitado exige reembolso manual'; end if;
    refund:=case when total>0 then round(paid*greatest(0,total-used)::numeric/total)::int else 0 end;
  elsif mode='no_after_use' then refund:=paid;
  else refund:=0;
  end if;
  refund:=least(paid,greatest(0,refund));
  for q in select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where membership_id=cm.id and status='reserved' and bucket_id is not null group by bucket_id loop
    update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-q.qty) where id=q.bucket_id;
  end loop;
  update public.appointment_membership_uses set status='released' where membership_id=cm.id and status='reserved';
  update public.customer_memberships set status='cancelled',renewal_blocked=true,cancel_effective_on=current_date,cancelled_at=now(),updated_at=now() where id=cm.id;
  select mp.id,mp.method into pay from public.membership_payments mp where mp.membership_id=cm.id order by mp.paid_at limit 1;
  v_unit_id:=coalesce(cm.origin_unit_id,(select u.id from public.units u where u.barbershop_id=m.barbershop_id and u.is_active order by u.created_at limit 1));
  if refund>0 then
    insert into public.finance_refunds(barbershop_id,unit_id,appointment_id,membership_id,membership_payment_id,amount_cents,reason,actor_member_id,refund_method)
    values(m.barbershop_id,v_unit_id,null,cm.id,pay.id,refund,trim(p_reason),m.member_id,pay.method) returning id into refund_id;
    ratio:=case when paid>0 then refund::numeric/paid else 0 end;
    for ce in select * from public.commission_entries where barbershop_id=m.barbershop_id and source_type='membership_sale' and source_id=cm.id and amount_cents>0 loop
      insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents,status)
      values(ce.barbershop_id,ce.unit_id,ce.professional_id,null,'membership_refund',refund_id,'Estorno de comissão por reembolso de pacote',-round(ce.base_cents*ratio)::int,ce.rate_percent,-round(ce.amount_cents*ratio)::int,'open');
    end loop;
    if pay.method='cash' then
      insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
      select cs.id,m.barbershop_id,v_unit_id,'refund',-refund,'membership_refund',refund_id,'Reembolso de pacote',m.member_id
      from public.cash_sessions cs where cs.unit_id=v_unit_id and cs.status='open' order by cs.opened_at desc limit 1;
    end if;
  end if;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm.id,'package_cancelled',jsonb_build_object('refund_mode',mode,'refund_cents',refund,'reason',trim(p_reason),'refund_id',refund_id),m.member_id);
  return jsonb_build_object('ok',true,'refund_mode',mode,'refund_cents',refund,'refund_id',refund_id);
end $$;

create or replace function public.barberium_staff_resolve_no_show_membership_use(p_use_id uuid,p_consume boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; u record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select u.*,cm.barbershop_id into u from public.appointment_membership_uses u join public.customer_memberships cm on cm.id=u.membership_id
  where u.id=p_use_id and cm.barbershop_id=m.barbershop_id and u.status='decision_required' for update;
  if u.id is null then raise exception 'Decisão de falta não encontrada'; end if;
  if u.bucket_id is not null then
    update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-u.credit_qty),used_credits=used_credits+case when p_consume then u.credit_qty else 0 end where id=u.bucket_id;
  end if;
  update public.appointment_membership_uses set status=case when p_consume then 'forfeited' else 'released' end,consumed_at=case when p_consume then now() else null end where id=u.id;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(u.membership_id,'no_show_decided',jsonb_build_object('use_id',u.id,'appointment_id',u.appointment_id,'consume',p_consume,'note',nullif(trim(coalesce(p_note,'')),'')),m.member_id);
  return jsonb_build_object('ok',true,'status',case when p_consume then 'forfeited' else 'released' end);
end $$;

create or replace function public.barberium_staff_set_appointment_status(p_appointment_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; a public.appointments%rowtype; v_use record; v_rule text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_status not in ('confirmed','completed','cancelled','no_show') then raise exception 'Status inválido'; end if;
  if p_status='completed' then raise exception 'Use a etapa de pagamento para concluir o atendimento'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  select * into a from public.appointments where id=p_appointment_id for update;
  if a.id is null or a.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if;
  if m.role='barber' then
    if a.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if;
    if p_status='no_show' and not barberium.permission_enabled(perms,'mark_no_show') then raise exception 'Sem permissão para marcar falta'; end if;
    if p_status='cancelled' and not barberium.permission_enabled(perms,'cancel_appointment') then raise exception 'Sem permissão para cancelar'; end if;
    if p_status='confirmed' then raise exception 'Somente o ADM pode restaurar para confirmado'; end if;
    if a.status<>'confirmed' then raise exception 'Este atendimento já foi finalizado'; end if;
  end if;
  if a.status=p_status then return jsonb_build_object('ok',true,'status',a.status); end if;
  if p_status='confirmed' and exists(select 1 from public.appointment_payments where appointment_id=a.id) then raise exception 'Atendimento com movimentação financeira não pode ser restaurado diretamente'; end if;
  if p_status='no_show' then
    for v_use in
      select u.id,u.bucket_id,u.credit_qty,u.membership_id,coalesce(v.rules->>'no_show_rule','keep') no_show_rule
      from public.appointment_membership_uses u join public.customer_memberships cm on cm.id=u.membership_id join public.membership_plan_versions v on v.id=cm.plan_version_id
      where u.appointment_id=a.id and u.status='reserved' for update of u
    loop
      v_rule:=v_use.no_show_rule;
      if v_rule='lose' then
        update public.appointment_membership_uses set status='forfeited',consumed_at=now() where id=v_use.id;
        if v_use.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty),used_credits=used_credits+v_use.credit_qty where id=v_use.bucket_id; end if;
      elsif v_rule='admin' then
        update public.appointment_membership_uses set status='decision_required' where id=v_use.id;
      else
        update public.appointment_membership_uses set status='released' where id=v_use.id;
        if v_use.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty) where id=v_use.bucket_id; end if;
      end if;
    end loop;
  elsif p_status='cancelled' then
    for v_use in select id,bucket_id,credit_qty from public.appointment_membership_uses where appointment_id=a.id and status='reserved' for update loop
      if v_use.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty) where id=v_use.bucket_id; end if;
      update public.appointment_membership_uses set status='released' where id=v_use.id;
    end loop;
  end if;
  begin
    update public.appointments set status=p_status,cancelled_at=case when p_status='cancelled' then now() else null end,updated_at=now() where id=a.id;
  exception when exclusion_violation then raise exception 'Horário já foi ocupado por outro atendimento'; end;
  insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from',a.status,'to',p_status));
  return jsonb_build_object('ok',true,'appointment_id',a.id,'status',p_status);
end $$;

