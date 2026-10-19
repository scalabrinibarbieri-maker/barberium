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
declare v_b uuid; v_customer uuid; cm record; v_min int; v_max int; v_id uuid;
begin
  if p_action_type not in ('pause','cancel') then raise exception 'Ação inválida'; end if;
  select id into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id
  where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  perform barberium.refresh_customer_membership_states(v_customer);
  select cm.*,pv.rules into cm from public.customer_memberships cm join public.membership_plan_versions pv on pv.id=cm.plan_version_id
  where cm.id=p_membership_id and cm.customer_id=v_customer and cm.barbershop_id=v_b for update;
  if cm.id is null then raise exception 'Plano não encontrado'; end if;
  if cm.plan_type<>'subscription' then raise exception 'Esta solicitação é exclusiva para assinaturas'; end if;
  if cm.status not in ('active','paused','overdue') then raise exception 'Assinatura não está disponível para esta solicitação'; end if;

  if p_action_type='pause' then
    if cm.status<>'active' then raise exception 'Somente assinatura ativa pode ser pausada'; end if;
    if not coalesce((cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    if cm.status='paused' then raise exception 'Assinatura já está pausada'; end if;
    if coalesce(p_requested_days,0)<=0 then raise exception 'Informe a duração da pausa'; end if;
    v_min:=nullif(cm.rules->>'pause_min_days','')::int; v_max:=nullif(cm.rules->>'pause_max_days','')::int;
    if v_min is not null and p_requested_days<v_min then raise exception 'Pausa abaixo do mínimo permitido'; end if;
    if v_max is not null and p_requested_days>v_max then raise exception 'Pausa acima do máximo permitido'; end if;
  else
    if not coalesce((cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite solicitação de cancelamento'; end if;
    if cm.renewal_blocked then raise exception 'O cancelamento desta assinatura já está programado'; end if;
  end if;

  insert into public.membership_action_requests(barbershop_id,customer_id,membership_id,action_type,requested_days,customer_note)
  values(v_b,v_customer,cm.id,p_action_type,case when p_action_type='pause' then p_requested_days end,nullif(trim(coalesce(p_note,'')),''))
  on conflict(membership_id,action_type) where status='pending'
  do update set requested_days=excluded.requested_days,customer_note=excluded.customer_note,created_at=now()
  returning id into v_id;
  insert into public.membership_events(membership_id,event_type,details) values(cm.id,'customer_action_requested',jsonb_build_object('request_id',v_id,'action',p_action_type,'requested_days',p_requested_days));
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
declare m record; r record; cm record; v_days int; v_mode text; q record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select r.*,v.rules,cm.plan_type,cm.status membership_status,cm.current_cycle_end,cm.paused_until,cm.renewal_blocked
  into r from public.membership_action_requests r join public.customer_memberships cm on cm.id=r.membership_id join public.membership_plan_versions v on v.id=cm.plan_version_id
  where r.id=p_request_id and r.barbershop_id=m.barbershop_id and r.status='pending' for update of r;
  if r.id is null then raise exception 'Solicitação inválida'; end if;
  if not p_approve then
    update public.membership_action_requests set status='rejected',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(r.membership_id,'customer_action_rejected',jsonb_build_object('request_id',r.id,'action',r.action_type,'note',p_decision_note),m.member_id);
    return jsonb_build_object('ok',true,'status','rejected');
  end if;

  select cm.*,v.rules into cm from public.customer_memberships cm join public.membership_plan_versions v on v.id=cm.plan_version_id where cm.id=r.membership_id for update;
  if cm.plan_type<>'subscription' then raise exception 'Ação disponível apenas para assinatura'; end if;

  if r.action_type='pause' then
    if not coalesce((cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    v_days:=greatest(1,coalesce(r.requested_days,0));
    if nullif(cm.rules->>'pause_min_days','')::int is not null and v_days<(cm.rules->>'pause_min_days')::int then raise exception 'Pausa abaixo do mínimo'; end if;
    if nullif(cm.rules->>'pause_max_days','')::int is not null and v_days>(cm.rules->>'pause_max_days')::int then raise exception 'Pausa acima do máximo'; end if;
    update public.customer_memberships set status='paused',pause_started_at=now(),paused_until=current_date+v_days,
      current_cycle_end=case when current_cycle_end is null then null else current_cycle_end+v_days end,
      cancel_effective_on=case when cancel_effective_on is null then null else cancel_effective_on+v_days end,updated_at=now()
    where id=cm.id;
    update public.membership_cycles set cycle_end=cycle_end+v_days where membership_id=cm.id and cycle_start<=current_date and cycle_end>=current_date and status='paid';
    update public.membership_credit_buckets set expires_on=expires_on+v_days where membership_id=cm.id and expires_on is not null and expires_on>=current_date;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm.id,'paused',jsonb_build_object('request_id',r.id,'days',v_days,'resume_on',current_date+v_days,'note',p_decision_note),m.member_id);
  else
    if not coalesce((cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite cancelamento'; end if;
    v_mode:=coalesce(cm.rules->>'cancel_mode','end_cycle');
    if v_mode='immediate' or cm.current_cycle_end is null then
      for q in select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where membership_id=cm.id and status='reserved' and bucket_id is not null group by bucket_id loop
        update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-q.qty) where id=q.bucket_id;
      end loop;
      update public.appointment_membership_uses set status='released' where membership_id=cm.id and status='reserved';
      update public.customer_memberships set status='cancelled',renewal_blocked=true,cancel_effective_on=current_date,cancelled_at=now(),pause_started_at=null,paused_until=null,updated_at=now() where id=cm.id;
    else
      update public.customer_memberships set renewal_blocked=true,cancel_effective_on=cm.current_cycle_end,updated_at=now() where id=cm.id;
    end if;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm.id,'cancellation_approved',jsonb_build_object('request_id',r.id,'mode',v_mode,'effective_on',case when v_mode='immediate' then current_date else cm.current_cycle_end end,'note',p_decision_note),m.member_id);
  end if;
  update public.membership_action_requests set status='approved',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
  return jsonb_build_object('ok',true,'status','approved');
end $$;

