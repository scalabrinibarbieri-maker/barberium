-- Barberium v11.2 — regras operacionais de assinaturas e pacotes
-- Pagamento integral, pausa/cancelamento de assinatura, ajustes de pacote,
-- cancelamento/reembolso de pacote e decisão de no-show.

alter table public.customer_memberships
  add column if not exists pause_started_at timestamptz,
  add column if not exists renewal_blocked boolean not null default false,
  add column if not exists cancel_effective_on date;

create table if not exists public.membership_action_requests(
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  membership_id uuid not null references public.customer_memberships(id) on delete cascade,
  action_type text not null check(action_type in ('pause','cancel')),
  requested_days int,
  customer_note text,
  status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
  decision_note text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by_member_id uuid references public.barbershop_members(id) on delete set null
);
create unique index if not exists membership_action_requests_one_pending
  on public.membership_action_requests(membership_id,action_type) where status='pending';
alter table public.membership_action_requests enable row level security;

alter table public.finance_refunds alter column appointment_id drop not null;
alter table public.finance_refunds
  add column if not exists membership_id uuid references public.customer_memberships(id) on delete set null,
  add column if not exists membership_payment_id uuid references public.membership_payments(id) on delete set null,
  add column if not exists refund_method text;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='finance_refunds_source_check' and conrelid='public.finance_refunds'::regclass) then
    alter table public.finance_refunds add constraint finance_refunds_source_check check (appointment_id is not null or membership_id is not null);
  end if;
end $$;

create or replace function barberium.refresh_customer_membership_states(p_customer_id uuid)
returns void language plpgsql security definer set search_path to 'public','barberium','pg_temp' as $$
declare r record;
begin
  for r in
    select id,paused_until,renewal_blocked,cancel_effective_on
    from public.customer_memberships
    where customer_id=p_customer_id and status='paused' and paused_until is not null and paused_until<=current_date
    for update
  loop
    if r.renewal_blocked and r.cancel_effective_on is not null and r.cancel_effective_on<current_date then
      update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),pause_started_at=null,paused_until=null,updated_at=now() where id=r.id;
      insert into public.membership_events(membership_id,event_type,details) values(r.id,'cancelled_effective',jsonb_build_object('effective_on',r.cancel_effective_on));
    else
      update public.customer_memberships set status='active',pause_started_at=null,paused_until=null,updated_at=now() where id=r.id;
      insert into public.membership_events(membership_id,event_type,details) values(r.id,'pause_finished',jsonb_build_object('resumed_on',current_date));
    end if;
  end loop;

  for r in
    select id,cancel_effective_on from public.customer_memberships
    where customer_id=p_customer_id and status in ('active','overdue') and renewal_blocked and cancel_effective_on is not null and cancel_effective_on<current_date
    for update
  loop
    update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),updated_at=now() where id=r.id;
    insert into public.membership_events(membership_id,event_type,details) values(r.id,'cancelled_effective',jsonb_build_object('effective_on',r.cancel_effective_on));
  end loop;
end $$;

create or replace function public.barberium_customer_refresh_membership_states(p_barbershop_slug text,p_access_token text)
returns boolean language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_b uuid; v_customer uuid;
begin
  select id into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer
  from public.customer_access_tokens t join public.customers c on c.id=t.customer_id
  where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  perform barberium.refresh_customer_membership_states(v_customer);
  return true;
end $$;

create or replace function public.barberium_customer_membership_actions_state(p_barbershop_slug text,p_access_token text)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_b uuid; v_customer uuid;
begin
  select id into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer
  from public.customer_access_tokens t join public.customers c on c.id=t.customer_id
  where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  perform barberium.refresh_customer_membership_states(v_customer);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'membership_id',cm.id,'status',cm.status,'plan_type',cm.plan_type,'paused_until',cm.paused_until,
      'pause_started_at',cm.pause_started_at,'renewal_blocked',cm.renewal_blocked,'cancel_effective_on',cm.cancel_effective_on,
      'rules',pv.rules,
      'action_requests',coalesce((select jsonb_agg(jsonb_build_object('id',ar.id,'action_type',ar.action_type,'requested_days',ar.requested_days,'status',ar.status,'created_at',ar.created_at,'decided_at',ar.decided_at,'decision_note',ar.decision_note) order by ar.created_at desc) from public.membership_action_requests ar where ar.membership_id=cm.id),'[]'::jsonb)
    ) order by cm.created_at desc)
    from public.customer_memberships cm join public.membership_plan_versions pv on pv.id=cm.plan_version_id
    where cm.customer_id=v_customer and cm.barbershop_id=v_b
  ),'[]'::jsonb);
end $$;

create or replace function public.barberium_customer_request_membership_action(
  p_barbershop_slug text,p_access_token text,p_membership_id uuid,p_action_type text,p_requested_days int default null,p_note text default null
)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_b uuid; v_customer uuid; v_cm record; v_min int; v_max int; v_id uuid;
begin
  if p_action_type not in ('pause','cancel') then raise exception 'Ação inválida'; end if;
  select id into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id
  where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  perform barberium.refresh_customer_membership_states(v_customer);
  select xcm.*,pv.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id
  where xcm.id=p_membership_id and xcm.customer_id=v_customer and xcm.barbershop_id=v_b for update;
  if v_cm.id is null then raise exception 'Plano não encontrado'; end if;
  if v_cm.plan_type<>'subscription' then raise exception 'Esta solicitação é exclusiva para assinaturas'; end if;
  if v_cm.status not in ('active','paused','overdue') then raise exception 'Assinatura não está disponível para esta solicitação'; end if;

  if p_action_type='pause' then
    if v_cm.status<>'active' then raise exception 'Somente assinatura ativa pode ser pausada'; end if;
    if not coalesce((v_cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    if v_cm.status='paused' then raise exception 'Assinatura já está pausada'; end if;
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
  insert into public.membership_events(membership_id,event_type,details) values(v_cm.id,'customer_action_requested',jsonb_build_object('request_id',v_id,'action',p_action_type,'requested_days',p_requested_days));
  return jsonb_build_object('ok',true,'request_id',v_id);
end $$;

create or replace function public.barberium_staff_membership_action_requests()
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.id,'membership_id',r.membership_id,'action_type',r.action_type,'requested_days',r.requested_days,'customer_note',r.customer_note,
    'created_at',r.created_at,'customer_id',c.id,'customer',c.full_name,'phone',c.phone_e164,'plan',p.name,'plan_type',cm.plan_type,
    'membership_status',cm.status,'rules',v.rules,'current_cycle_end',cm.current_cycle_end,'paused_until',cm.paused_until
  ) order by r.created_at) from public.membership_action_requests r
  join public.customer_memberships cm on cm.id=r.membership_id join public.customers c on c.id=r.customer_id
  join public.membership_plans p on p.id=cm.plan_id join public.membership_plan_versions v on v.id=cm.plan_version_id
  where r.barbershop_id=m.barbershop_id and r.status='pending'),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_membership_actions_state(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if;
  perform barberium.refresh_customer_membership_states(p_customer_id);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'membership_id',cm.id,'status',cm.status,'plan_type',cm.plan_type,'paused_until',cm.paused_until,'pause_started_at',cm.pause_started_at,
    'renewal_blocked',cm.renewal_blocked,'cancel_effective_on',cm.cancel_effective_on,'rules',v.rules,
    'action_requests',coalesce((select jsonb_agg(jsonb_build_object('id',ar.id,'action_type',ar.action_type,'requested_days',ar.requested_days,'status',ar.status,'created_at',ar.created_at,'decided_at',ar.decided_at,'decision_note',ar.decision_note) order by ar.created_at desc) from public.membership_action_requests ar where ar.membership_id=cm.id),'[]'::jsonb)
  ) order by cm.created_at desc) from public.customer_memberships cm join public.membership_plan_versions v on v.id=cm.plan_version_id
  where cm.customer_id=p_customer_id and cm.barbershop_id=m.barbershop_id),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_decide_membership_action_request(p_request_id uuid,p_approve boolean,p_decision_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; r record; v_cm record; v_days int; v_mode text; q record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select req.*,v.rules,xcm.plan_type,xcm.status membership_status,xcm.current_cycle_end,xcm.paused_until,xcm.renewal_blocked
  into r from public.membership_action_requests req join public.customer_memberships xcm on xcm.id=req.membership_id join public.membership_plan_versions v on v.id=xcm.plan_version_id
  where req.id=p_request_id and req.barbershop_id=m.barbershop_id and req.status='pending' for update of req;
  if r.id is null then raise exception 'Solicitação inválida'; end if;
  if not p_approve then
    update public.membership_action_requests set status='rejected',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(r.membership_id,'customer_action_rejected',jsonb_build_object('request_id',r.id,'action',r.action_type,'note',p_decision_note),m.member_id);
    return jsonb_build_object('ok',true,'status','rejected');
  end if;

  select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id where xcm.id=r.membership_id for update;
  if v_cm.plan_type<>'subscription' then raise exception 'Ação disponível apenas para assinatura'; end if;

  if r.action_type='pause' then
    if not coalesce((v_cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    v_days:=greatest(1,coalesce(r.requested_days,0));
    if nullif(v_cm.rules->>'pause_min_days','')::int is not null and v_days<(v_cm.rules->>'pause_min_days')::int then raise exception 'Pausa abaixo do mínimo'; end if;
    if nullif(v_cm.rules->>'pause_max_days','')::int is not null and v_days>(v_cm.rules->>'pause_max_days')::int then raise exception 'Pausa acima do máximo'; end if;
    update public.customer_memberships set status='paused',pause_started_at=now(),paused_until=current_date+v_days,
      current_cycle_end=case when current_cycle_end is null then null else current_cycle_end+v_days end,
      cancel_effective_on=case when cancel_effective_on is null then null else cancel_effective_on+v_days end,updated_at=now()
    where id=v_cm.id;
    update public.membership_cycles set cycle_end=cycle_end+v_days where membership_id=v_cm.id and cycle_start<=current_date and cycle_end>=current_date and status='paid';
    update public.membership_credit_buckets set expires_on=expires_on+v_days where membership_id=v_cm.id and expires_on is not null and expires_on>=current_date;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'paused',jsonb_build_object('request_id',r.id,'days',v_days,'resume_on',current_date+v_days,'note',p_decision_note),m.member_id);
  else
    if not coalesce((v_cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite cancelamento'; end if;
    v_mode:=coalesce(v_cm.rules->>'cancel_mode','end_cycle');
    if v_mode='immediate' or v_cm.current_cycle_end is null then
      for q in select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where membership_id=v_cm.id and status='reserved' and bucket_id is not null group by bucket_id loop
        update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-q.qty) where id=q.bucket_id;
      end loop;
      update public.appointment_membership_uses set status='released' where membership_id=v_cm.id and status='reserved';
      update public.customer_memberships set status='cancelled',renewal_blocked=true,cancel_effective_on=current_date,cancelled_at=now(),pause_started_at=null,paused_until=null,updated_at=now() where id=v_cm.id;
    else
      update public.customer_memberships set renewal_blocked=true,cancel_effective_on=v_cm.current_cycle_end,updated_at=now() where id=v_cm.id;
    end if;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'cancellation_approved',jsonb_build_object('request_id',r.id,'mode',v_mode,'effective_on',case when v_mode='immediate' then current_date else v_cm.current_cycle_end end,'note',p_decision_note),m.member_id);
  end if;
  update public.membership_action_requests set status='approved',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
  return jsonb_build_object('ok',true,'status','approved');
end $$;

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
declare m record; v_cm record; mode text; paid int; total int; used int; refund int:=0; pay record; refund_id uuid; ratio numeric:=0; ce record; q record; v_unit_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Motivo obrigatório'; end if;
  select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id
  where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update;
  if v_cm.id is null or v_cm.plan_type<>'package' then raise exception 'Pacote inválido'; end if;
  if v_cm.status in ('cancelled','expired') then raise exception 'Pacote já encerrado'; end if;
  mode:=coalesce(v_cm.rules->>'refund_mode','nonrefundable');

  select coalesce(sum(total_credits),0),coalesce(sum(used_credits),0) into total,used from public.membership_credit_buckets where membership_id=v_cm.id and total_credits is not null;
  if mode='no_after_use' and used>0 then raise exception 'Este pacote não permite cancelamento após o primeiro uso'; end if;
  select coalesce(sum(amount_cents),0) into paid from public.membership_payments where membership_id=v_cm.id;
  if mode='manual' then
    if p_manual_refund_cents is null or p_manual_refund_cents<0 or p_manual_refund_cents>paid then raise exception 'Informe um reembolso manual válido'; end if;
    refund:=p_manual_refund_cents;
  elsif mode='proportional' then
    if exists(select 1 from public.membership_credit_buckets where membership_id=v_cm.id and total_credits is null) then raise exception 'Pacote ilimitado exige reembolso manual'; end if;
    refund:=case when total>0 then round(paid*greatest(0,total-used)::numeric/total)::int else 0 end;
  elsif mode='no_after_use' then refund:=paid;
  else refund:=0;
  end if;
  refund:=least(paid,greatest(0,refund));

  for q in select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where membership_id=v_cm.id and status='reserved' and bucket_id is not null group by bucket_id loop
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
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'package_cancelled',jsonb_build_object('refund_mode',mode,'refund_cents',refund,'reason',trim(p_reason),'refund_id',refund_id),m.member_id);
  return jsonb_build_object('ok',true,'refund_mode',mode,'refund_cents',refund,'refund_id',refund_id);
end $$;

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
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_use.membership_id,'no_show_decided',jsonb_build_object('use_id',v_use.id,'appointment_id',v_use.appointment_id,'consume',p_consume,'note',nullif(trim(coalesce(p_note,'')),'')),m.member_id);
  return jsonb_build_object('ok',true,'status',case when p_consume then 'forfeited' else 'released' end);
end $$;


-- No-show por benefício: cada uso reservado segue a regra do seu próprio plano.
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

-- Ativação sempre depende de pagamento integral: cria pendente primeiro e só ativa após registrar o valor total.
create or replace function public.barberium_staff_assign_membership(p_customer_id uuid,p_plan_id uuid,p_unit_id uuid,p_start_date date default current_date,p_mark_paid boolean default false,p_payment_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; p record; v record; cm_id uuid; cyc_id uuid; cycle_start date; cycle_end date; due date; grace int; first_mode text; amount int; validity text; valid_until date;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if;
 select * into p from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id and is_active; if p.id is null then raise exception 'Plano inválido'; end if;
 select * into v from public.membership_plan_versions where plan_id=p.id and version_no=p.current_version_no;
 if p.plan_type='subscription' then
   cycle_start:=p_start_date;
   if coalesce(v.rules->>'cycle_mode','anniversary')='calendar' then cycle_start:=date_trunc('month',p_start_date)::date; cycle_end:=(date_trunc('month',p_start_date)+interval '1 month - 1 day')::date; else cycle_end:=(p_start_date+interval '1 month - 1 day')::date; end if;
   first_mode:=coalesce(v.rules->>'first_cycle_mode','full'); amount:=v.price_cents;
   if first_mode='next_cycle' and coalesce(v.rules->>'cycle_mode','anniversary')='calendar' then cycle_start:=(date_trunc('month',p_start_date)+interval '1 month')::date; cycle_end:=(cycle_start+interval '1 month - 1 day')::date; end if;
   if first_mode='proportional' and coalesce(v.rules->>'cycle_mode','anniversary')='calendar' and cycle_start<p_start_date then amount:=round(v.price_cents*((cycle_end-p_start_date+1)::numeric/(cycle_end-cycle_start+1)))::int; cycle_start:=p_start_date; end if;
   due:=p_start_date; grace:=greatest(0,coalesce((v.rules->>'grace_days')::int,0));
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,current_cycle_start,current_cycle_end,created_by_member_id)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,cycle_start,cycle_end,m.member_id) returning id into cm_id;
   insert into public.membership_cycles(membership_id,cycle_start,cycle_end,due_date,grace_until,amount_cents,status,credits_released,paid_at,is_first_cycle) values(cm_id,cycle_start,cycle_end,due,due+grace,amount,'pending',false,null,true) returning id into cyc_id;
 else
   validity:=coalesce(v.rules->>'credit_validity','no_expiry'); valid_until:=case when validity='fixed_days' then p_start_date+greatest(1,coalesce((v.rules->>'fixed_validity_days')::int,30)) else null end;
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,valid_until,created_by_member_id)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,valid_until,m.member_id) returning id into cm_id;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm_id,'created',jsonb_build_object('paid',false,'plan_version_id',v.id,'payment_required_full',true),m.member_id);
 if p_mark_paid then perform public.barberium_staff_record_membership_payment(cm_id,cyc_id,p_payment_method); end if;
 return jsonb_build_object('ok',true,'membership_id',cm_id,'cycle_id',cyc_id,'status',case when p_mark_paid then 'active' else 'pending' end);
exception when unique_violation then raise exception 'Cliente já possui um plano deste tipo ativo'; end $$;

-- Pagamento do plano sempre registra o valor integral devido antes de ativar.
create or replace function public.barberium_staff_record_membership_payment(p_membership_id uuid,p_cycle_id uuid default null,p_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_cm record; cyc record; amount int; v_session uuid; v_unit uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'confirm_membership_payment') then raise exception 'Sem permissão para confirmar pagamento de plano'; end if;
 if p_method not in ('pix','cash','debit','credit') then raise exception 'Forma de pagamento inválida'; end if;
 select xcm.*,pv.price_cents into v_cm from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update; if v_cm.id is null then raise exception 'Plano do cliente inválido'; end if;
 v_unit:=coalesce(v_cm.origin_unit_id,(select id from public.units where barbershop_id=m.barbershop_id and is_active order by created_at limit 1));
 if v_cm.plan_type='subscription' then
   select * into cyc from public.membership_cycles where id=coalesce(p_cycle_id,(select id from public.membership_cycles where membership_id=v_cm.id and status in ('pending','overdue') order by due_date limit 1)) and membership_id=v_cm.id for update; if cyc.id is null then raise exception 'Mensalidade pendente não encontrada'; end if;
   if exists(select 1 from public.membership_payments where cycle_id=cyc.id) then raise exception 'Mensalidade já paga'; end if;
   amount:=cyc.amount_cents;
   insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id) values(v_cm.id,cyc.id,amount,p_method,m.member_id);
   update public.membership_cycles set status='paid',paid_at=now() where id=cyc.id;
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),current_cycle_start=cyc.cycle_start,current_cycle_end=cyc.cycle_end,updated_at=now() where id=v_cm.id;
   if not cyc.credits_released then perform barberium.release_membership_credits(v_cm.id,cyc.id); end if;
 else
   if exists(select 1 from public.membership_payments where membership_id=v_cm.id) then raise exception 'Pacote já foi pago'; end if;
   amount:=v_cm.price_cents;
   insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id) values(v_cm.id,amount,p_method,m.member_id);
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),updated_at=now() where id=v_cm.id;
   perform barberium.release_membership_credits(v_cm.id,null);
 end if;
 if p_method='cash' and v_unit is not null then
   select id into v_session from public.cash_sessions where unit_id=v_unit and status='open' order by opened_at desc limit 1;
   if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,v_unit,'payment',amount,'membership',v_cm.id,'Pagamento integral de plano',m.member_id); end if;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'payment_confirmed',jsonb_build_object('amount_cents',amount,'method',p_method,'payment_required_full',true),m.member_id);
 return jsonb_build_object('ok',true,'amount_cents',amount,'status','active');
end $$;

-- Financeiro passa a incluir pagamentos de planos e reembolsos.
create or replace function public.barberium_staff_finance_overview(p_start date,p_end date,p_unit_id uuid default null,p_basis text default 'cash')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; gross int; fees int; expenses_paid int; commissions int; receivables int; target int; result int; refunds int; appointment_gross int; membership_gross int; appointment_fees int; membership_fees int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Financeiro geral restrito ao ADM'; end if; if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
 if p_basis='cash' then
   select coalesce(sum(ap.amount_cents),0),coalesce(sum(ap.fee_cents),0) into appointment_gross,appointment_fees from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id);
 else
   select coalesce(sum(a.total_price_cents),0),coalesce(sum((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id)),0) into appointment_gross,appointment_fees from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id);
 end if;
 select coalesce(sum(mp.amount_cents),0),coalesce(sum(mp.fee_cents),0) into membership_gross,membership_fees from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id);
 gross:=appointment_gross+membership_gross; fees:=appointment_fees+membership_fees;
 select coalesce(sum(fr.amount_cents),0) into refunds from public.finance_refunds fr where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id);
 select coalesce(sum(e.amount_cents),0) into expenses_paid from public.expenses e where e.barbershop_id=m.barbershop_id and e.status='paid' and (case when p_basis='cash' then coalesce(e.paid_at::date,e.due_date) else e.due_date end) between p_start and p_end and (p_unit_id is null or e.unit_id=p_unit_id);
 select coalesce(sum(ce.amount_cents),0) into commissions from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into receivables from public.appointment_receivables ar where ar.barbershop_id=m.barbershop_id and ar.status<>'paid' and (p_unit_id is null or ar.unit_id=p_unit_id);
 select revenue_target_cents into target from public.financial_goals fg where fg.barbershop_id=m.barbershop_id and fg.unit_id is not distinct from p_unit_id and fg.month=date_trunc('month',p_end)::date;
 result:=gross-refunds-fees-commissions-expenses_paid;
 return jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'gross_cents',gross,'refunds_cents',refunds,'fees_cents',fees,'net_received_cents',gross-refunds-fees,'expenses_cents',expenses_paid,'commissions_cents',commissions,'operating_result_cents',result,'receivables_cents',receivables,'revenue_target_cents',target,'target_progress_percent',case when coalesce(target,0)>0 then round((gross-refunds)*100.0/target,1) else null end,'by_method',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_cents',amount) order by amount desc) from (
   select method,sum(amount_cents)::int amount from (
     select ap.method,ap.amount_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
     union all
     select mp.method,mp.amount_cents from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
   ) x group by method
 ) q),'[]'::jsonb));
end $$;


-- Relatório financeiro v11.2: inclui pagamentos e reembolsos de planos/pacotes.
create or replace function public.barberium_staff_finance_report(
  p_start date,p_end date,p_unit_id uuid default null,p_basis text default 'cash'
)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $function$
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
    ) q),'[]'::jsonb),
    'accrual_revenue',coalesce((select jsonb_agg(x order by (x->>'date')::timestamptz desc) from (
      select jsonb_build_object('appointment_id',a.id,'source_type','appointment','date',a.starts_at,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'amount_cents',a.total_price_cents) x
      from public.appointments a join public.units u on u.id=a.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id
      where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select jsonb_build_object('appointment_id',null,'source_type','membership','date',mpay.paid_at,'unit',u.name,'customer',c.full_name,'service',case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,'professional',null,'amount_cents',mpay.amount_cents) x
      from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id join public.customers c on c.id=cm.customer_id join public.membership_plans pl on pl.id=cm.plan_id left join public.units u on u.id=cm.origin_unit_id
      where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
    ) q),'[]'::jsonb),
    'refunds',coalesce((select jsonb_agg(jsonb_build_object('id',fr.id,'date',fr.created_at,'unit',u.name,'source_type',case when fr.membership_id is not null then 'membership' else 'appointment' end,'customer',coalesce(mc.full_name,ac.full_name),'description',coalesce(case when cm.plan_type='subscription' then 'Assinatura: '||mpl.name when cm.plan_type='package' then 'Pacote: '||mpl.name end,asv.name),'method',fr.refund_method,'amount_cents',fr.amount_cents,'reason',fr.reason) order by fr.created_at desc)
      from public.finance_refunds fr join public.units u on u.id=fr.unit_id left join public.customer_memberships cm on cm.id=fr.membership_id left join public.membership_plans mpl on mpl.id=cm.plan_id left join public.customers mc on mc.id=cm.customer_id left join public.appointments aa on aa.id=fr.appointment_id left join public.customers ac on ac.id=aa.customer_id left join public.services asv on asv.id=aa.service_id
      where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id)),'[]'::jsonb),
    'expenses',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'unit',u.name,'category',ec.name,'description',e.description,'amount_cents',e.amount_cents,'due_date',e.due_date,'status',e.status,'payment_method',e.payment_method,'paid_from_cash',e.paid_from_cash,'paid_at',e.paid_at,'note',e.note) order by e.due_date desc,e.created_at desc) from public.expenses e join public.units u on u.id=e.unit_id left join public.expense_categories ec on ec.id=e.category_id where e.barbershop_id=m.barbershop_id and (e.due_date between p_start and p_end or (e.paid_at is not null and e.paid_at::date between p_start and p_end)) and (p_unit_id is null or e.unit_id=p_unit_id)),'[]'::jsonb),
    'commissions',coalesce((select jsonb_agg(jsonb_build_object('id',ce.id,'date',ce.created_at,'unit',u.name,'professional',pr.name,'source_type',ce.source_type,'description',ce.description,'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,'amount_cents',ce.amount_cents,'status',ce.status) order by ce.created_at desc) from public.commission_entries ce join public.units u on u.id=ce.unit_id join public.professionals pr on pr.id=ce.professional_id where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)),'[]'::jsonb),
    'receivables',coalesce((select jsonb_agg(jsonb_build_object('appointment_id',ar.appointment_id,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'original_due_cents',ar.original_due_cents,'paid_cents',ar.paid_cents,'open_cents',greatest(0,ar.original_due_cents-ar.paid_cents),'status',ar.status,'due_date',ar.due_date,'note',ar.note,'created_at',ar.created_at) order by coalesce(ar.due_date,ar.created_at::date),ar.created_at) from public.appointment_receivables ar join public.appointments a on a.id=ar.appointment_id join public.units u on u.id=ar.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id where ar.barbershop_id=m.barbershop_id and ar.created_at::date<=p_end and (p_unit_id is null or ar.unit_id=p_unit_id)),'[]'::jsonb),
    'cash_sessions',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'unit',u.name,'status',cs.status,'opening_balance_cents',cs.opening_balance_cents,'opened_at',cs.opened_at,'expected_closing_cents',cs.expected_closing_cents,'counted_closing_cents',cs.counted_closing_cents,'difference_cents',cs.difference_cents,'closing_justification',cs.closing_justification,'closed_at',cs.closed_at) order by cs.opened_at desc) from public.cash_sessions cs join public.units u on u.id=cs.unit_id where cs.barbershop_id=m.barbershop_id and cs.opened_at::date<=p_end and coalesce(cs.closed_at::date,p_end)>=p_start and (p_unit_id is null or cs.unit_id=p_unit_id)),'[]'::jsonb),
    'cash_movements',coalesce((select jsonb_agg(jsonb_build_object('id',mov.id,'date',mov.created_at,'unit',u.name,'type',mov.movement_type,'amount_cents',mov.amount_cents,'reference_type',mov.reference_type,'note',mov.note) order by mov.created_at desc) from public.cash_movements mov join public.units u on u.id=mov.unit_id where mov.barbershop_id=m.barbershop_id and mov.created_at::date between p_start and p_end and (p_unit_id is null or mov.unit_id=p_unit_id)),'[]'::jsonb),
    'by_provider',coalesce((select jsonb_agg(jsonb_build_object('provider',provider,'method',method,'installments',installments,'gross_cents',gross_cents,'fees_cents',fees_cents,'net_cents',gross_cents-fees_cents,'transactions',transactions) order by gross_cents desc) from (
      select provider,method,installments,sum(amount_cents)::int gross_cents,sum(fee_cents)::int fees_cents,count(*)::int transactions from (
        select coalesce(pp.name,'Sem provedor') provider,ap.method,coalesce(ap.installments,1) installments,ap.amount_cents,ap.fee_cents from public.appointment_payments ap left join public.payment_providers pp on pp.id=ap.provider_id where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
        union all
        select coalesce(pp.name,'Sem provedor'),mpay.method,coalesce(mpay.installments,1),mpay.amount_cents,mpay.fee_cents from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id left join public.payment_providers pp on pp.id=mpay.provider_id where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      ) z group by provider,method,installments
    ) q),'[]'::jsonb),
    'by_unit',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'unit',u.name,'gross_cents',coalesce(x.gross_cents,0),'fees_cents',coalesce(x.fees_cents,0),'net_cents',coalesce(x.gross_cents,0)-coalesce(x.fees_cents,0)) order by u.name) from public.units u left join lateral (
      select sum(amount_cents)::int gross_cents,sum(fee_cents)::int fees_cents from (
        select ap.amount_cents,ap.fee_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.unit_id=u.id and ap.received_at::date between p_start and p_end
        union all select mpay.amount_cents,mpay.fee_cents from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id where cm.barbershop_id=m.barbershop_id and cm.origin_unit_id=u.id and mpay.paid_at::date between p_start and p_end
      ) z
    ) x on true where u.barbershop_id=m.barbershop_id and (p_unit_id is null or u.id=p_unit_id)),'[]'::jsonb),
    'by_professional',coalesce((select jsonb_agg(jsonb_build_object('professional_id',pr.id,'professional',pr.name,'completed_cents',coalesce(x.completed_cents,0),'completed_count',coalesce(x.completed_count,0),'commission_cents',coalesce(y.commission_cents,0)) order by pr.name) from public.professionals pr left join lateral (select sum(a.total_price_cents)::int completed_cents,count(*)::int completed_count from public.appointments a where a.barbershop_id=m.barbershop_id and a.professional_id=pr.id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)) x on true left join lateral (select sum(ce.amount_cents)::int commission_cents from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.professional_id=pr.id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)) y on true where pr.barbershop_id=m.barbershop_id and pr.is_active),'[]'::jsonb)
  );
end $function$;

grant execute on function public.barberium_staff_finance_report(date,date,uuid,text) to authenticated;

grant execute on function public.barberium_customer_refresh_membership_states(text,text) to anon,authenticated;
grant execute on function public.barberium_customer_membership_actions_state(text,text) to anon,authenticated;
grant execute on function public.barberium_customer_request_membership_action(text,text,uuid,text,int,text) to anon,authenticated;
grant execute on function public.barberium_staff_membership_action_requests() to authenticated;
grant execute on function public.barberium_staff_membership_actions_state(uuid) to authenticated;
grant execute on function public.barberium_staff_decide_membership_action_request(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_adjust_package_credit(uuid,uuid,int,text) to authenticated;
grant execute on function public.barberium_staff_cancel_package(uuid,text,int) to authenticated;
grant execute on function public.barberium_staff_resolve_no_show_membership_use(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_set_appointment_status(uuid,text) to authenticated;
grant execute on function public.barberium_staff_assign_membership(uuid,uuid,uuid,date,boolean,text) to authenticated;
grant execute on function public.barberium_staff_record_membership_payment(uuid,uuid,text) to authenticated;
grant execute on function public.barberium_staff_finance_overview(date,date,uuid,text) to authenticated;


-- ===== v11.2 HOTFIX: ASSINATURA POR PERÍODO, SEM CARTEIRA DE CRÉDITOS =====
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

-- Hotfix adicional: decisão de no-show sem colisão de alias.
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
