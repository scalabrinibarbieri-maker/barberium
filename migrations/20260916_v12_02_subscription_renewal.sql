-- Barberium v12.0 — Renovação automática e regras de ciclo das assinaturas

alter table public.customer_memberships add column if not exists cycle_mode text;
alter table public.customer_memberships add column if not exists renewal_day integer;
alter table public.customer_memberships add column if not exists renewal_shift_days integer not null default 0;
alter table public.membership_cycles add column if not exists sequence_no integer;

update public.membership_cycles mc
set sequence_no=q.rn
from (
  select id,row_number() over(partition by membership_id order by cycle_start,created_at,id)::int rn
  from public.membership_cycles
) q where q.id=mc.id and mc.sequence_no is null;

create unique index if not exists membership_cycles_membership_sequence_key
  on public.membership_cycles(membership_id,sequence_no) where sequence_no is not null;

create or replace function barberium.month_day(p_month date,p_day integer)
returns date language sql immutable set search_path='pg_catalog' as $$
  select date_trunc('month',p_month)::date +
    ((least(greatest(coalesce(p_day,1),1),extract(day from (date_trunc('month',p_month)+interval '1 month - 1 day'))::int)-1)::int)
$$;

create or replace function barberium.next_renewal_after(p_after date,p_day integer,p_shift integer default 0)
returns date language plpgsql immutable set search_path='pg_catalog','barberium' as $$
declare m date; d date; i int:=0;
begin
  m:=date_trunc('month',p_after)::date;
  loop
    d:=barberium.month_day(m,p_day)+coalesce(p_shift,0);
    if d>p_after then return d; end if;
    m:=(m+interval '1 month')::date; i:=i+1;
    if i>24 then raise exception 'Não foi possível calcular renovação'; end if;
  end loop;
end $$;

create or replace function barberium.previous_renewal_before(p_before date,p_day integer,p_shift integer default 0)
returns date language plpgsql immutable set search_path='pg_catalog','barberium' as $$
declare m date; d date; i int:=0;
begin
  m:=date_trunc('month',p_before)::date;
  loop
    d:=barberium.month_day(m,p_day)+coalesce(p_shift,0);
    if d<p_before then return d; end if;
    m:=(m-interval '1 month')::date; i:=i+1;
    if i>24 then raise exception 'Não foi possível calcular renovação anterior'; end if;
  end loop;
end $$;

create or replace function barberium.normalized_cycle_mode(p_rules jsonb)
returns text language sql immutable set search_path='pg_catalog' as $$
  select case coalesce(p_rules->>'cycle_mode','signup_date')
    when 'anniversary' then 'signup_date'
    when 'calendar' then 'calendar_month'
    when 'calendar_month' then 'calendar_month'
    when 'fixed_day' then 'fixed_day'
    else 'signup_date' end
$$;

create or replace function barberium.subscription_refresh_one(p_membership_id uuid,p_as_of date default current_date)
returns void language plpgsql security definer
set search_path='public','barberium','pg_temp' as $$
declare cm record; cyc record; pv record; mode text; dayn int; shift int; next_start date; next_end date; grace int; seq int;
begin
  select xcm.*,v.rules into cm
  from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id
  where xcm.id=p_membership_id and xcm.plan_type='subscription' for update of xcm;
  if cm.id is null or cm.status in ('cancelled','expired','paused') then return; end if;

  select * into cyc from public.membership_cycles where membership_id=cm.id order by sequence_no desc nulls last,cycle_start desc limit 1 for update;
  if cyc.id is null then return; end if;

  if cyc.status in ('pending','overdue') then
    if cyc.status='pending' and cyc.grace_until is not null and p_as_of>cyc.grace_until then
      update public.membership_cycles set status='overdue' where id=cyc.id;
      update public.customer_memberships set status='overdue',updated_at=now() where id=cm.id;
    else
      update public.customer_memberships set status=cyc.status,updated_at=now() where id=cm.id and status<>cyc.status;
    end if;
    return;
  end if;

  if cyc.status='paid' and p_as_of<=cyc.cycle_end then
    if cm.status<>'active' then update public.customer_memberships set status='active',updated_at=now() where id=cm.id; end if;
    return;
  end if;

  if cyc.status<>'paid' or p_as_of<=cyc.cycle_end then return; end if;

  next_start:=cyc.cycle_end+1;
  if cm.renewal_blocked and cm.cancel_effective_on is not null and next_start>=cm.cancel_effective_on then
    update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),updated_at=now() where id=cm.id;
    insert into public.membership_events(membership_id,event_type,details) values(cm.id,'cancelled_effective',jsonb_build_object('effective_on',cm.cancel_effective_on));
    return;
  end if;

  if cm.next_plan_version_id is not null then
    update public.customer_memberships set plan_id=coalesce(next_plan_id,plan_id),plan_version_id=next_plan_version_id,next_plan_id=null,next_plan_version_id=null,updated_at=now() where id=cm.id;
    select xcm.*,v.rules into cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id where xcm.id=cm.id;
    mode:=barberium.normalized_cycle_mode(cm.rules);
    dayn:=case mode when 'calendar_month' then 1 when 'fixed_day' then greatest(1,least(31,coalesce((cm.rules->>'fixed_day')::int,1))) else coalesce(cm.renewal_day,extract(day from coalesce(cm.started_at,now()))::int) end;
    update public.customer_memberships set cycle_mode=mode,renewal_day=dayn where id=cm.id;
    cm.cycle_mode:=mode; cm.renewal_day:=dayn;
  end if;

  mode:=coalesce(cm.cycle_mode,barberium.normalized_cycle_mode(cm.rules));
  dayn:=coalesce(cm.renewal_day,case mode when 'calendar_month' then 1 when 'fixed_day' then greatest(1,least(31,coalesce((cm.rules->>'fixed_day')::int,1))) else extract(day from next_start)::int end);
  shift:=coalesce(cm.renewal_shift_days,0);
  next_end:=barberium.next_renewal_after(next_start,dayn,shift)-1;
  if next_end<next_start then next_end:=(next_start+interval '1 month - 1 day')::date; end if;
  grace:=greatest(0,coalesce((cm.rules->>'grace_days')::int,0));
  seq:=coalesce(cyc.sequence_no,1)+1;

  insert into public.membership_cycles(membership_id,cycle_start,cycle_end,due_date,grace_until,amount_cents,status,credits_released,paid_at,is_first_cycle,sequence_no)
  values(cm.id,next_start,next_end,next_start,next_start+grace,(select price_cents from public.membership_plan_versions where id=cm.plan_version_id),'pending',false,null,false,seq)
  on conflict do nothing;
  update public.customer_memberships set status='pending',current_cycle_start=next_start,current_cycle_end=next_end,cycle_mode=mode,renewal_day=dayn,updated_at=now() where id=cm.id;
  insert into public.membership_events(membership_id,event_type,details) values(cm.id,'renewal_generated',jsonb_build_object('cycle_start',next_start,'cycle_end',next_end,'due_date',next_start,'status','pending'));
end $$;

create or replace function barberium.process_due_subscription_renewals(p_as_of date default current_date)
returns integer language plpgsql security definer set search_path='public','barberium','pg_temp' as $$
declare r record; n int:=0;
begin
  for r in select id from public.customer_memberships where plan_type='subscription' and status in ('active','pending','overdue') loop
    perform barberium.subscription_refresh_one(r.id,p_as_of); n:=n+1;
  end loop;
  return n;
end $$;

create or replace function barberium.refresh_customer_membership_states(p_customer_id uuid)
returns void language plpgsql security definer set search_path='public','barberium','pg_temp' as $$
declare r record;
begin
  for r in select id,paused_until,renewal_blocked,cancel_effective_on from public.customer_memberships where customer_id=p_customer_id and status='paused' and paused_until is not null and paused_until<=current_date for update loop
    if r.renewal_blocked and r.cancel_effective_on is not null and r.cancel_effective_on<current_date then
      update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),pause_started_at=null,paused_until=null,updated_at=now() where id=r.id;
      insert into public.membership_events(membership_id,event_type,details) values(r.id,'cancelled_effective',jsonb_build_object('effective_on',r.cancel_effective_on));
    else
      update public.customer_memberships set status='active',pause_started_at=null,paused_until=null,updated_at=now() where id=r.id;
      insert into public.membership_events(membership_id,event_type,details) values(r.id,'pause_finished',jsonb_build_object('resumed_on',current_date));
    end if;
  end loop;
  for r in select id,cancel_effective_on from public.customer_memberships where customer_id=p_customer_id and status in ('active','pending','overdue') and renewal_blocked and cancel_effective_on is not null and cancel_effective_on<current_date for update loop
    update public.customer_memberships set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),updated_at=now() where id=r.id;
    insert into public.membership_events(membership_id,event_type,details) values(r.id,'cancelled_effective',jsonb_build_object('effective_on',r.cancel_effective_on));
  end loop;
  for r in select id from public.customer_memberships where customer_id=p_customer_id and plan_type='subscription' and status in ('active','pending','overdue') loop
    perform barberium.subscription_refresh_one(r.id,current_date);
  end loop;
end $$;

create or replace function public.barberium_staff_assign_membership(p_customer_id uuid,p_plan_id uuid,p_unit_id uuid,p_start_date date default current_date,p_mark_paid boolean default false,p_payment_method text default 'pix')
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; p record; v record; cm_id uuid; cyc_id uuid; cycle_start date; cycle_end date; due date; grace int; first_mode text; amount int; validity text; valid_until date; mode text; dayn int; next_due date; prev_due date; full_days int; used_days int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if;
 select * into p from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id and is_active; if p.id is null then raise exception 'Plano inválido'; end if;
 select * into v from public.membership_plan_versions where plan_id=p.id and version_no=p.current_version_no;
 if p.plan_type='subscription' then
   mode:=barberium.normalized_cycle_mode(v.rules);
   dayn:=case mode when 'calendar_month' then 1 when 'fixed_day' then greatest(1,least(31,coalesce(nullif(v.rules->>'fixed_day','')::int,1))) else extract(day from p_start_date)::int end;
   first_mode:=coalesce(v.rules->>'first_cycle_mode','full'); if first_mode not in ('full','proportional','custom','next_cycle') then first_mode:='full'; end if;
   grace:=greatest(0,coalesce(nullif(v.rules->>'grace_days','')::int,0)); amount:=v.price_cents;
   if mode='signup_date' then
     cycle_start:=p_start_date; next_due:=barberium.next_renewal_after(cycle_start,dayn,0); cycle_end:=next_due-1;
   else
     next_due:=barberium.next_renewal_after(p_start_date-1,dayn,0);
     if next_due=p_start_date then next_due:=barberium.next_renewal_after(p_start_date,dayn,0); end if;
     if first_mode='next_cycle' then cycle_start:=next_due; cycle_end:=barberium.next_renewal_after(cycle_start,dayn,0)-1; else cycle_start:=p_start_date; cycle_end:=next_due-1; end if;
   end if;
   if first_mode='proportional' and mode<>'signup_date' and cycle_start=p_start_date then
     prev_due:=barberium.previous_renewal_before(next_due,dayn,0); full_days:=greatest(1,next_due-prev_due); used_days:=greatest(1,next_due-p_start_date); amount:=round(v.price_cents*(used_days::numeric/full_days))::int;
   elsif first_mode='custom' then amount:=greatest(0,coalesce(nullif(v.rules->>'first_cycle_custom_amount_cents','')::int,v.price_cents)); end if;
   due:=cycle_start;
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,current_cycle_start,current_cycle_end,created_by_member_id,cycle_mode,renewal_day,renewal_shift_days)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,cycle_start,cycle_end,m.member_id,mode,dayn,0) returning id into cm_id;
   insert into public.membership_cycles(membership_id,cycle_start,cycle_end,due_date,grace_until,amount_cents,status,credits_released,paid_at,is_first_cycle,sequence_no) values(cm_id,cycle_start,cycle_end,due,due+grace,amount,'pending',false,null,true,1) returning id into cyc_id;
 else
   validity:=coalesce(v.rules->>'credit_validity','no_expiry'); valid_until:=case when validity='fixed_days' then p_start_date+greatest(1,coalesce((v.rules->>'fixed_validity_days')::int,30)) else null end;
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,valid_until,created_by_member_id) values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,valid_until,m.member_id) returning id into cm_id;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm_id,'created',jsonb_build_object('paid',false,'plan_version_id',v.id,'payment_required_full',true),m.member_id);
 if p_mark_paid then perform public.barberium_staff_record_membership_payment(cm_id,cyc_id,p_payment_method); end if;
 return jsonb_build_object('ok',true,'membership_id',cm_id,'cycle_id',cyc_id,'status',case when p_mark_paid then 'active' else 'pending' end);
exception when unique_violation then raise exception 'Cliente já possui um plano deste tipo ativo'; end $$;

create or replace function public.barberium_staff_record_membership_payment(p_membership_id uuid,p_cycle_id uuid default null,p_method text default 'pix')
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_cm record; cyc record; amount int; v_session uuid; v_unit uuid; late_mode text; grace int; mode text; dayn int; new_end date;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'confirm_membership_payment') then raise exception 'Sem permissão para confirmar pagamento de plano'; end if;
 if p_method not in ('pix','cash','debit','credit') then raise exception 'Forma de pagamento inválida'; end if;
 select xcm.*,pv.price_cents,pv.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions pv on pv.id=xcm.plan_version_id where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update of xcm;
 if v_cm.id is null then raise exception 'Plano do cliente inválido'; end if;
 v_unit:=coalesce(v_cm.origin_unit_id,(select u.id from public.units u where u.barbershop_id=m.barbershop_id and u.is_active order by u.created_at limit 1));
 if v_cm.plan_type='subscription' then
   perform barberium.subscription_refresh_one(v_cm.id,current_date);
   select mc.* into cyc from public.membership_cycles mc where mc.id=coalesce(p_cycle_id,(select mc2.id from public.membership_cycles mc2 where mc2.membership_id=v_cm.id and mc2.status in ('pending','overdue') order by mc2.due_date limit 1)) and mc.membership_id=v_cm.id for update of mc;
   if cyc.id is null then raise exception 'Mensalidade pendente não encontrada'; end if; if exists(select 1 from public.membership_payments mp where mp.cycle_id=cyc.id) then raise exception 'Mensalidade já paga'; end if;
   amount:=cyc.amount_cents; late_mode:=coalesce(v_cm.rules->>'late_payment_cycle_mode','retroactive');
   if cyc.status='overdue' and late_mode='from_payment' then
     mode:=coalesce(v_cm.cycle_mode,barberium.normalized_cycle_mode(v_cm.rules)); dayn:=extract(day from current_date)::int;
     new_end:=barberium.next_renewal_after(current_date,dayn,0)-1;
     update public.membership_cycles set cycle_start=current_date,cycle_end=new_end,due_date=current_date,grace_until=current_date,status='pending' where id=cyc.id;
     update public.customer_memberships set current_cycle_start=current_date,current_cycle_end=new_end,cycle_mode='signup_date',renewal_day=dayn,renewal_shift_days=0 where id=v_cm.id;
     cyc.cycle_start:=current_date; cyc.cycle_end:=new_end;
   end if;
   insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id) values(v_cm.id,cyc.id,amount,p_method,m.member_id);
   update public.membership_cycles set status='paid',paid_at=now(),credits_released=true where id=cyc.id;
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),current_cycle_start=cyc.cycle_start,current_cycle_end=cyc.cycle_end,updated_at=now() where id=v_cm.id;
 else
   if exists(select 1 from public.membership_payments mp where mp.membership_id=v_cm.id) then raise exception 'Pacote já foi pago'; end if; amount:=v_cm.price_cents;
   insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id) values(v_cm.id,amount,p_method,m.member_id);
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),updated_at=now() where id=v_cm.id; perform barberium.release_membership_credits(v_cm.id,null);
 end if;
 if p_method='cash' and v_unit is not null then select cs.id into v_session from public.cash_sessions cs where cs.unit_id=v_unit and cs.status='open' order by cs.opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,v_unit,'payment',amount,'membership',v_cm.id,'Pagamento integral de plano',m.member_id); end if; end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'payment_confirmed',jsonb_build_object('amount_cents',amount,'method',p_method,'payment_required_full',true,'late_cycle_mode',case when v_cm.plan_type='subscription' then coalesce(late_mode,'retroactive') else null end),m.member_id);
 if v_cm.plan_type='subscription' then perform barberium.subscription_refresh_one(v_cm.id,current_date); end if;
 return jsonb_build_object('ok',true,'amount_cents',amount,'status',(select status from public.customer_memberships where id=v_cm.id));
end $$;

create or replace function public.barberium_staff_update_subscription_cycle_rules(p_plan_id uuid,p_cycle_mode text,p_fixed_day integer,p_first_cycle_mode text,p_first_cycle_custom_amount_cents integer,p_grace_days integer,p_late_payment_cycle_mode text)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; mp record; oldv record; newv uuid; ver int; nr jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select * into mp from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id and plan_type='subscription'; if mp.id is null then raise exception 'Assinatura inválida'; end if;
  if p_cycle_mode not in ('signup_date','calendar_month','fixed_day') then raise exception 'Modo de ciclo inválido'; end if;
  if p_cycle_mode='fixed_day' and (p_fixed_day is null or p_fixed_day<1 or p_fixed_day>31) then raise exception 'Dia fixo inválido'; end if;
  if p_first_cycle_mode not in ('full','proportional','custom','next_cycle') then raise exception 'Primeiro ciclo inválido'; end if;
  if p_first_cycle_mode='custom' and coalesce(p_first_cycle_custom_amount_cents,-1)<0 then raise exception 'Valor personalizado inválido'; end if;
  if p_late_payment_cycle_mode not in ('retroactive','from_payment') then raise exception 'Regra de atraso inválida'; end if;
  select * into oldv from public.membership_plan_versions where plan_id=mp.id and version_no=mp.current_version_no;
  ver:=mp.current_version_no+1;
  nr:=coalesce(oldv.rules,'{}'::jsonb)||jsonb_build_object('cycle_mode',p_cycle_mode,'first_cycle_mode',p_first_cycle_mode,'grace_days',greatest(0,coalesce(p_grace_days,0)),'late_payment_cycle_mode',p_late_payment_cycle_mode);
  if p_cycle_mode='fixed_day' then nr:=nr||jsonb_build_object('fixed_day',p_fixed_day); else nr:=nr-'fixed_day'; end if;
  if p_first_cycle_mode='custom' then nr:=nr||jsonb_build_object('first_cycle_custom_amount_cents',p_first_cycle_custom_amount_cents); else nr:=nr-'first_cycle_custom_amount_cents'; end if;
  insert into public.membership_plan_versions(plan_id,version_no,price_cents,rules) values(mp.id,ver,oldv.price_cents,nr) returning id into newv;
  insert into public.membership_plan_benefits(plan_version_id,service_id,quantity,unlimited,extra_discount_percent,min_days_between,max_per_week,max_per_month,rules,sort_order) select newv,service_id,quantity,unlimited,extra_discount_percent,min_days_between,max_per_week,max_per_month,rules,sort_order from public.membership_plan_benefits where plan_version_id=oldv.id;
  insert into public.membership_plan_units(plan_version_id,unit_id) select newv,unit_id from public.membership_plan_units where plan_version_id=oldv.id;
  update public.membership_plans set current_version_no=ver,updated_at=now() where id=mp.id;
  update public.customer_memberships set next_plan_id=mp.id,next_plan_version_id=newv,updated_at=now() where plan_id=mp.id and plan_type='subscription' and status in ('active','paused','pending','overdue');
  return jsonb_build_object('ok',true,'version_id',newv,'version_no',ver,'rules',nr);
end $$;

-- Pausa desloca também todas as renovações futuras daquele cliente.
create or replace function public.barberium_staff_decide_membership_action_request(p_request_id uuid,p_approve boolean,p_decision_note text default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; r record; v_cm record; v_days int; v_mode text; q record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select req.*,v.rules,xcm.plan_type,xcm.status membership_status,xcm.current_cycle_end,xcm.paused_until,xcm.renewal_blocked into r from public.membership_action_requests req join public.customer_memberships xcm on xcm.id=req.membership_id join public.membership_plan_versions v on v.id=xcm.plan_version_id where req.id=p_request_id and req.barbershop_id=m.barbershop_id and req.status='pending' for update of req;
  if r.id is null then raise exception 'Solicitação inválida'; end if;
  if not p_approve then update public.membership_action_requests set status='rejected',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id; insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(r.membership_id,'customer_action_rejected',jsonb_build_object('request_id',r.id,'action',r.action_type,'note',p_decision_note),m.member_id); return jsonb_build_object('ok',true,'status','rejected'); end if;
  select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id where xcm.id=r.membership_id for update of xcm; if v_cm.plan_type<>'subscription' then raise exception 'Ação disponível apenas para assinatura'; end if;
  if r.action_type='pause' then
    if v_cm.status<>'active' then raise exception 'Somente assinatura ativa pode ser pausada'; end if; if not coalesce((v_cm.rules->>'allow_pause')::boolean,true) then raise exception 'Este plano não permite pausa'; end if;
    v_days:=greatest(1,coalesce(r.requested_days,0)); if nullif(v_cm.rules->>'pause_min_days','')::int is not null and v_days<(v_cm.rules->>'pause_min_days')::int then raise exception 'Pausa abaixo do mínimo'; end if; if nullif(v_cm.rules->>'pause_max_days','')::int is not null and v_days>(v_cm.rules->>'pause_max_days')::int then raise exception 'Pausa acima do máximo'; end if;
    update public.customer_memberships set status='paused',pause_started_at=now(),paused_until=current_date+v_days,current_cycle_end=case when current_cycle_end is null then null else current_cycle_end+v_days end,cancel_effective_on=case when cancel_effective_on is null then null else cancel_effective_on+v_days end,renewal_shift_days=renewal_shift_days+v_days,updated_at=now() where id=v_cm.id;
    update public.membership_cycles set cycle_end=cycle_end+v_days where membership_id=v_cm.id and cycle_start<=current_date and cycle_end>=current_date and status='paid';
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'paused',jsonb_build_object('request_id',r.id,'days',v_days,'resume_on',current_date+v_days,'note',p_decision_note),m.member_id);
  else
    if not coalesce((v_cm.rules->>'allow_cancel')::boolean,true) then raise exception 'Este plano não permite cancelamento'; end if; v_mode:='end_cycle';
    update public.customer_memberships set renewal_blocked=true,cancel_effective_on=v_cm.current_cycle_end,updated_at=now() where id=v_cm.id;
    insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(v_cm.id,'cancellation_approved',jsonb_build_object('request_id',r.id,'mode',v_mode,'effective_on',v_cm.current_cycle_end,'note',p_decision_note),m.member_id);
  end if;
  update public.membership_action_requests set status='approved',decision_note=nullif(trim(coalesce(p_decision_note,'')),''),decided_at=now(),decided_by_member_id=m.member_id where id=r.id;
  return jsonb_build_object('ok',true,'status','approved');
end $$;

revoke all on function public.barberium_staff_update_subscription_cycle_rules(uuid,text,integer,text,integer,integer,text) from anon;
grant execute on function public.barberium_staff_update_subscription_cycle_rules(uuid,text,integer,text,integer,integer,text) to authenticated;
