-- Barberium v12.0 — snapshots completos, reagendamento efetivo e versões futuras de assinatura

alter table public.appointments add column if not exists professional_name_snapshot text;
alter table public.appointments add column if not exists unit_name_snapshot text;
update public.appointments a set professional_name_snapshot=coalesce(a.professional_name_snapshot,p.name) from public.professionals p where p.id=a.professional_id and a.professional_name_snapshot is null;
update public.appointments a set unit_name_snapshot=coalesce(a.unit_name_snapshot,u.name) from public.units u where u.id=a.unit_id and a.unit_name_snapshot is null;

create or replace function barberium.appointment_snapshot_guard()
returns trigger language plpgsql security definer set search_path='public','barberium','pg_temp' as $$
declare s public.services; p public.professionals; u public.units; d int;
begin
  if tg_op='INSERT' or new.service_id is distinct from old.service_id or new.professional_id is distinct from old.professional_id then
    if not barberium.professional_service_allowed(new.professional_id,new.service_id) then raise exception 'PROFESSIONAL_NOT_LINKED'; end if;
    select * into s from public.services where id=new.service_id and is_active;
    if s.id is null then raise exception 'SERVICE_NOT_FOUND'; end if;
    d:=barberium.effective_service_duration(new.professional_id,new.service_id);
    new.service_name_snapshot:=s.name;
    new.service_duration_min_snapshot:=d;
  end if;
  if tg_op='INSERT' or new.professional_id is distinct from old.professional_id then
    select * into p from public.professionals where id=new.professional_id;
    if p.id is null then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
    new.professional_name_snapshot:=p.name;
  end if;
  if tg_op='INSERT' or new.unit_id is distinct from old.unit_id then
    select * into u from public.units where id=new.unit_id;
    if u.id is null then raise exception 'UNIT_NOT_FOUND'; end if;
    new.unit_name_snapshot:=u.name;
  end if;
  return new;
end $$;

drop trigger if exists trg_appointment_snapshot_guard on public.appointments;
create trigger trg_appointment_snapshot_guard before insert or update of service_id,professional_id,unit_id on public.appointments for each row execute function barberium.appointment_snapshot_guard();

create or replace function public.barberium_reschedule_appointment(p_barbershop_slug text,p_unit_slug text,p_access_token text,p_appointment_id uuid,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_time time)
returns jsonb language plpgsql security definer set search_path='public','barberium','extensions','pg_temp' as $$
declare v_customer_id uuid; v_old public.appointments; v_b public.barbershops; v_u public.units; v_s public.services; v_duration int; v_base int; v_total int; v_start timestamptz; v_end timestamptz; v_limit int;
begin
 select t.customer_id into v_customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join public.barbershops b on b.id=c.barbershop_id where b.slug=p_barbershop_slug and b.status='active' and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
 if v_customer_id is null then raise exception 'INVALID_TOKEN'; end if;
 select * into v_old from public.appointments where id=p_appointment_id and customer_id=v_customer_id and status='confirmed' for update; if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found or v_u.id<>v_old.unit_id then raise exception 'UNIT_NOT_FOUND'; end if;
 v_limit:=coalesce((v_u.settings->>'reschedule_before_minutes')::int,0); if v_old.starts_at<now()+make_interval(mins=>v_limit) then raise exception 'RESCHEDULE_WINDOW_CLOSED'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active and service_kind in ('service','combo') and coalesce((settings->>'draft')::boolean,false)=false; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 if not barberium.professional_service_allowed(p_professional_id,p_service_id) then raise exception 'PROFESSIONAL_NOT_LINKED'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(p_professional_id,x)) then raise exception 'INVALID_ADDON'; end if;
 update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-q.qty) from (select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where appointment_id=v_old.id and status='reserved' and bucket_id is not null group by bucket_id) q where b.id=q.bucket_id;
 update public.appointment_membership_uses set status='released' where appointment_id=v_old.id and status='reserved';
 update public.appointments set status='cancelled' where id=v_old.id;
 if not(to_char(p_time,'HH24:MI')=any(array(select jsonb_array_elements_text(public.barberium_get_available_slots(p_barbershop_slug,p_unit_slug,p_professional_id,p_service_id,coalesce(p_addon_service_ids,'{}'::uuid[]),p_date))))) then raise exception 'SLOT_UNAVAILABLE'; end if;
 v_duration:=barberium.effective_service_duration(p_professional_id,p_service_id)+coalesce((select sum(barberium.effective_addon_duration(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_base:=barberium.effective_service_price(p_professional_id,p_service_id);
 v_total:=v_base+coalesce((select sum(barberium.effective_addon_price(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_start:=(p_date::timestamp+p_time) at time zone v_b.timezone; v_end:=v_start+make_interval(mins=>v_duration);
 update public.appointments set professional_id=p_professional_id,unit_id=v_u.id,service_id=p_service_id,starts_at=v_start,ends_at=v_end,base_price_cents=v_base,listed_price_cents=v_total,total_price_cents=v_total,manual_adjustment_cents=0,status='confirmed',cancelled_at=null,updated_at=now() where id=v_old.id;
 delete from public.appointment_addons where appointment_id=v_old.id;
 insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min)
 select v_old.id,ad.id,ad.name,barberium.effective_addon_price(p_professional_id,p_service_id,ad.id),barberium.effective_addon_duration(p_professional_id,p_service_id,ad.id)
 from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;
 return jsonb_build_object('appointment_id',v_old.id,'starts_at',v_start,'ends_at',v_end,'total_price_cents',v_total);
end $$;

create or replace function public.barberium_get_customer_portal(p_barbershop_slug text,p_access_token text)
returns jsonb language sql stable security definer set search_path='public','barberium','extensions','pg_temp' as $$
with b as(select id,coalesce(timezone,'America/Sao_Paulo') tz from public.barbershops where slug=p_barbershop_slug and status='active'),
t as(select t.customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join b on b.id=c.barbershop_id where t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1),
c as(select c.* from public.customers c join t on t.customer_id=c.id)
select jsonb_build_object(
 'customer',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'phone_e164',c.phone_e164,'birthday',c.birthday) from c),
 'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'status',a.status,'starts_at',a.starts_at,'ends_at',a.ends_at,'total_price_cents',a.total_price_cents,
   'service',jsonb_build_object('id',s.id,'name',coalesce(a.service_name_snapshot,s.name),'slug',s.slug,'duration_label',coalesce(a.service_duration_min_snapshot,s.duration_min)::text||' min','duration_min',coalesce(a.service_duration_min_snapshot,s.duration_min)),
   'professional',jsonb_build_object('id',p.id,'name',coalesce(a.professional_name_snapshot,p.name),'slug',p.slug,'image_path',p.image_path),
   'unit',jsonb_build_object('id',u.id,'name',coalesce(a.unit_name_snapshot,u.name),'slug',u.slug),
   'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',aa.price_cents,'duration_min',aa.duration_min)) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb)) order by a.starts_at desc)
   from public.appointments a join c on c.id=a.customer_id join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id join public.units u on u.id=a.unit_id),'[]'::jsonb),
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

create or replace function public.barberium_staff_appointment_detail(p_appointment_id uuid)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; a public.appointments%rowtype; c public.customers; p public.professionals; s public.services; show_phone boolean; show_full boolean; show_value boolean; show_note boolean; show_birthday boolean; show_history boolean;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 select * into a from public.appointments where id=p_appointment_id; if a.id is null or a.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if; if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if;
 select * into c from public.customers where id=a.customer_id; select * into p from public.professionals where id=a.professional_id; select * into s from public.services where id=a.service_id;
 show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_phone'); show_full:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_full_name'); show_value:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_value'); show_note:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_internal_note'); show_birthday:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_birthday'); show_history:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_customer_history');
 return jsonb_build_object('id',a.id,'status',a.status,'starts_at',a.starts_at,'ends_at',a.ends_at,
   'customer',jsonb_build_object('id',c.id,'name',barberium.mask_customer_name(c.full_name,show_full),'phone',case when show_phone then c.phone_e164 else null end,'birthday',case when show_birthday then c.birthday else null end),
   'professional',jsonb_build_object('id',p.id,'name',coalesce(a.professional_name_snapshot,p.name)),
   'service',jsonb_build_object('id',s.id,'name',coalesce(a.service_name_snapshot,s.name),'duration_min',coalesce(a.service_duration_min_snapshot,s.duration_min)),
   'unit',jsonb_build_object('id',a.unit_id,'name',coalesce(a.unit_name_snapshot,(select u.name from public.units u where u.id=a.unit_id))),
   'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',case when show_value then aa.price_cents else null end,'duration_min',aa.duration_min) order by aa.name_snapshot) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb),
   'listed_price_cents',case when show_value then coalesce(a.listed_price_cents,a.total_price_cents) else null end,'manual_adjustment_cents',case when show_value then a.manual_adjustment_cents else null end,'total_price_cents',case when show_value then a.total_price_cents else null end,'internal_note',case when show_note then a.internal_note else null end,'permissions',perms,
   'customer_stats',case when show_history then (select jsonb_build_object('appointments',count(*),'completed',count(*) filter(where status='completed'),'cancelled',count(*) filter(where status='cancelled'),'no_show',count(*) filter(where status='no_show'),'spent_cents',coalesce(sum(total_price_cents) filter(where status='completed'),0)) from public.appointments ca where ca.customer_id=c.id) else null end,
   'events',case when m.role in ('owner','admin') then coalesce((select jsonb_agg(jsonb_build_object('event_type',e.event_type,'details',e.details,'created_at',e.created_at,'actor',coalesce(ap.name,au.email,'Sistema')) order by e.created_at desc) from public.appointment_events e left join public.barbershop_members bm on bm.id=e.actor_member_id left join public.professionals ap on ap.id=bm.professional_id left join auth.users au on au.id=bm.auth_user_id where e.appointment_id=a.id),'[]'::jsonb) else '[]'::jsonb end);
end $$;

create or replace function public.barberium_staff_dashboard(p_date date default current_date,p_professional_id uuid default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_permissions jsonb; v_tz text; v_start timestamptz; v_end timestamptz; v_filter_prof uuid; v_appointments jsonb; v_blocks jsonb; v_summary jsonb; v_show_phone boolean; v_show_full boolean; v_show_value boolean; v_show_note boolean;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
 v_permissions:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; v_show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_phone'); v_show_full:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_full_name'); v_show_value:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_value'); v_show_note:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_internal_note');
 if m.role in ('owner','admin') then if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id and p.is_active) then raise exception 'Profissional inválido'; end if; v_filter_prof:=p_professional_id; else v_filter_prof:=m.professional_id; end if;
 select coalesce(timezone,'America/Sao_Paulo') into v_tz from public.barbershops where id=m.barbershop_id; v_start:=p_date::timestamp at time zone v_tz; v_end:=(p_date+1)::timestamp at time zone v_tz;
 select coalesce(jsonb_agg(x order by (x->>'starts_at')::timestamptz),'[]'::jsonb) into v_appointments from (
   select jsonb_build_object('kind','appointment','id',a.id,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,'service_id',s.id,'service',coalesce(a.service_name_snapshot,s.name),'professional_id',p.id,'professional',coalesce(a.professional_name_snapshot,p.name),'customer',barberium.mask_customer_name(c.full_name,v_show_full),'phone',case when v_show_phone then c.phone_e164 else null end,'total_price_cents',case when v_show_value then a.total_price_cents else null end,'internal_note',case when v_show_note then a.internal_note else null end,'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',case when v_show_value then aa.price_cents else null end,'duration_min',aa.duration_min) order by aa.name_snapshot) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb)) x
   from public.appointments a join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id join public.customers c on c.id=a.customer_id where a.barbershop_id=m.barbershop_id and a.starts_at>=v_start and a.starts_at<v_end and (v_filter_prof is null or a.professional_id=v_filter_prof)) q;
 select coalesce(jsonb_agg(x order by (x->>'starts_at')::timestamptz),'[]'::jsonb) into v_blocks from (
   select jsonb_build_object('kind','block','block_type','single','id',bt.id,'starts_at',bt.starts_at,'ends_at',bt.ends_at,'reason',bt.reason,'professional_id',p.id,'professional',p.name,'recurring',false) x from public.blocked_times bt join public.professionals p on p.id=bt.professional_id where bt.barbershop_id=m.barbershop_id and bt.starts_at<v_end and bt.ends_at>v_start and (v_filter_prof is null or bt.professional_id=v_filter_prof)
   union all select jsonb_build_object('kind','block','block_type','recurring','id',bs.id,'starts_at',(p_date::timestamp+bs.start_time) at time zone v_tz,'ends_at',(p_date::timestamp+bs.end_time) at time zone v_tz,'reason',bs.reason,'professional_id',p.id,'professional',p.name,'recurring',true,'starts_on',bs.starts_on,'ends_on',bs.ends_on) x from public.blocked_time_series bs join public.professionals p on p.id=bs.professional_id where bs.barbershop_id=m.barbershop_id and bs.is_active and p_date>=bs.starts_on and (bs.ends_on is null or p_date<=bs.ends_on) and bs.weekday=extract(dow from p_date)::int and (v_filter_prof is null or bs.professional_id=v_filter_prof)) q;
 select jsonb_build_object('total',count(*),'confirmed',count(*) filter(where status='confirmed'),'completed',count(*) filter(where status='completed'),'cancelled',count(*) filter(where status='cancelled'),'no_show',count(*) filter(where status='no_show'),'scheduled_revenue_cents',case when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue') then coalesce(sum(total_price_cents) filter(where status='confirmed'),0) else null end,'realized_revenue_cents',case when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue') then coalesce(sum(total_price_cents) filter(where status='completed'),0) else null end,'revenue_cents',case when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue') then coalesce(sum(total_price_cents) filter(where status in ('confirmed','completed')),0) else null end) into v_summary from public.appointments a where a.barbershop_id=m.barbershop_id and a.starts_at>=v_start and a.starts_at<v_end and (v_filter_prof is null or a.professional_id=v_filter_prof);
 return jsonb_build_object('date',p_date,'filter_professional_id',v_filter_prof,'member',jsonb_build_object('role',m.role,'professional_id',m.professional_id,'professional_name',m.professional_name,'permissions',v_permissions),'summary',v_summary,'appointments',v_appointments,'blocks',v_blocks);
end $$;

create or replace function public.barberium_staff_customer_detail(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; c public.customers%rowtype; main_unit uuid; result jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if; select * into c from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id; if c.id is null then raise exception 'Cliente não encontrado'; end if; main_unit:=barberium.customer_main_unit(c.id);
 select jsonb_build_object('id',c.id,'name',c.full_name,'phone',c.phone_e164,'birthday',c.birthday,'persistent_note',c.persistent_note,'preferred_unit_id',c.preferred_unit_id,'main_unit_id',main_unit,'main_unit',(select name from public.units where id=main_unit),
   'first_unit',(select coalesce(a.unit_name_snapshot,u.name) from public.appointments a join public.units u on u.id=a.unit_id where a.customer_id=c.id order by a.starts_at asc limit 1),'last_unit',(select coalesce(a.unit_name_snapshot,u.name) from public.appointments a join public.units u on u.id=a.unit_id where a.customer_id=c.id order by a.starts_at desc limit 1),'imported_at',c.imported_at,'import_source',c.import_source,
   'stats',(select jsonb_build_object('appointments',count(*),'completed',count(*) filter(where a.status='completed'),'cancelled',count(*) filter(where a.status='cancelled'),'no_show',count(*) filter(where a.status='no_show'),'spent_cents',coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0),'average_ticket_cents',case when count(*) filter(where a.status='completed')>0 then round(coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0)::numeric/(count(*) filter(where a.status='completed')))::int else 0 end,'last_visit',max(a.starts_at) filter(where a.status='completed'),'next_visit',min(a.starts_at) filter(where a.status='confirmed' and a.starts_at>now())) from public.appointments a where a.customer_id=c.id),
   'visits_by_unit',coalesce((select jsonb_agg(jsonb_build_object('unit_id',q.unit_id,'unit',q.unit,'visits',q.visits,'spent_cents',q.spent) order by q.visits desc,q.unit) from (select a.unit_id,coalesce(max(a.unit_name_snapshot),max(u.name)) unit,count(*) filter(where a.status='completed') visits,coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) spent from public.appointments a join public.units u on u.id=a.unit_id where a.customer_id=c.id group by a.unit_id) q),'[]'::jsonb),
   'history',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'starts_at',a.starts_at,'status',a.status,'service',coalesce(a.service_name_snapshot,s.name),'professional',coalesce(a.professional_name_snapshot,p.name),'unit',coalesce(a.unit_name_snapshot,u.name),'total_price_cents',a.total_price_cents) order by a.starts_at desc) from public.appointments a join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id join public.units u on u.id=a.unit_id where a.customer_id=c.id),'[]'::jsonb)) into result; return result;
end $$;

create or replace function public.barberium_staff_performance(p_start_date date,p_end_date date)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_permissions jsonb; v_tz text; v_start timestamptz; v_end timestamptz; v_summary jsonb; v_services jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; if p_end_date<p_start_date or (p_end_date-p_start_date)>366 then raise exception 'Período inválido'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if; v_permissions:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; if m.role='barber' and not barberium.permission_enabled(v_permissions,'view_own_revenue') then raise exception 'Sem permissão para ver faturamento'; end if;
 select coalesce(timezone,'America/Sao_Paulo') into v_tz from public.barbershops where id=m.barbershop_id; v_start:=p_start_date::timestamp at time zone v_tz; v_end:=(p_end_date+1)::timestamp at time zone v_tz;
 select jsonb_build_object('appointments',count(*),'confirmed',count(*) filter(where a.status='confirmed'),'completed',count(*) filter(where a.status='completed'),'cancelled',count(*) filter(where a.status='cancelled'),'no_show',count(*) filter(where a.status='no_show'),'scheduled_revenue_cents',coalesce(sum(a.total_price_cents) filter(where a.status='confirmed'),0),'realized_revenue_cents',coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0),'total_revenue_cents',coalesce(sum(a.total_price_cents) filter(where a.status in ('confirmed','completed')),0),'average_ticket_cents',case when count(*) filter(where a.status='completed')>0 then round(coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0)::numeric/(count(*) filter(where a.status='completed')))::int else 0 end) into v_summary from public.appointments a where a.barbershop_id=m.barbershop_id and a.starts_at>=v_start and a.starts_at<v_end and (m.role in ('owner','admin') or a.professional_id=m.professional_id);
 select coalesce(jsonb_agg(jsonb_build_object('service',q.service,'appointments',q.appointments,'completed',q.completed,'scheduled_revenue_cents',q.scheduled,'realized_revenue_cents',q.realized) order by q.appointments desc,q.service),'[]'::jsonb) into v_services from (select coalesce(a.service_name_snapshot,s.name) service,count(*) appointments,count(*) filter(where a.status='completed') completed,coalesce(sum(a.total_price_cents) filter(where a.status='confirmed'),0)::bigint scheduled,coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0)::bigint realized from public.appointments a join public.services s on s.id=a.service_id where a.barbershop_id=m.barbershop_id and a.starts_at>=v_start and a.starts_at<v_end and a.status in ('confirmed','completed') and (m.role in ('owner','admin') or a.professional_id=m.professional_id) group by coalesce(a.service_name_snapshot,s.name)) q;
 return jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'scope',case when m.role='barber' then 'own' else 'shop' end,'summary',v_summary,'services',v_services);
end $$;

create or replace function public.barberium_staff_upcoming(p_days integer default 7)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_items jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
 select coalesce(jsonb_agg(x order by x->>'starts_at'),'[]'::jsonb) into v_items from (select jsonb_build_object('id',a.id,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,'service',coalesce(a.service_name_snapshot,s.name),'professional',coalesce(a.professional_name_snapshot,p.name),'customer',c.full_name,'phone',c.phone_e164,'total_price_cents',a.total_price_cents) x from public.appointments a join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id join public.customers c on c.id=a.customer_id where a.barbershop_id=m.barbershop_id and a.starts_at>=now() and a.starts_at<now()+make_interval(days=>greatest(1,least(coalesce(p_days,7),31))) and a.status='confirmed' and (m.role in ('owner','admin') or a.professional_id=m.professional_id)) q; return v_items;
end $$;

-- Ao editar uma assinatura, a versão nova entra no próximo ciclo para assinantes existentes.
create or replace function public.barberium_staff_save_membership_plan(p_plan_id uuid,p_name text,p_description text,p_plan_type text,p_price_cents integer,p_acquisition_mode text,p_public_visible boolean,p_is_active boolean,p_rules jsonb,p_benefits jsonb,p_unit_ids uuid[] default '{}'::uuid[])
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_plan uuid; v_ver int; v_ver_id uuid; v_old_type text; b jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if trim(coalesce(p_name,''))='' or p_plan_type not in ('subscription','package') or p_price_cents<0 or p_acquisition_mode not in ('team','site','both') then raise exception 'Dados do plano inválidos'; end if; if jsonb_array_length(coalesce(p_benefits,'[]'::jsonb))=0 then raise exception 'Adicione ao menos um benefício'; end if;
 if p_plan_id is null then insert into public.membership_plans(barbershop_id,name,description,plan_type,acquisition_mode,public_visible,is_active,current_version_no) values(m.barbershop_id,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_plan_type,p_acquisition_mode,coalesce(p_public_visible,false),coalesce(p_is_active,true),1) returning id,current_version_no into v_plan,v_ver;
 else select id,current_version_no+1,plan_type into v_plan,v_ver,v_old_type from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id; if v_plan is null then raise exception 'Plano inválido'; end if; if v_old_type<>p_plan_type and exists(select 1 from public.customer_memberships cm where cm.plan_id=v_plan and cm.status not in ('cancelled','expired')) then raise exception 'Não altere o tipo de um plano que já possui clientes'; end if; update public.membership_plans set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),plan_type=p_plan_type,acquisition_mode=p_acquisition_mode,public_visible=coalesce(p_public_visible,false),is_active=coalesce(p_is_active,true),current_version_no=v_ver,updated_at=now() where id=v_plan; end if;
 insert into public.membership_plan_versions(plan_id,version_no,price_cents,rules) values(v_plan,v_ver,p_price_cents,coalesce(p_rules,'{}'::jsonb)) returning id into v_ver_id;
 for b in select * from jsonb_array_elements(p_benefits) loop if not exists(select 1 from public.services s where s.id=(b->>'service_id')::uuid and s.barbershop_id=m.barbershop_id) then raise exception 'Serviço inválido no benefício'; end if; insert into public.membership_plan_benefits(plan_version_id,service_id,quantity,unlimited,extra_discount_percent,min_days_between,max_per_week,max_per_month,rules,sort_order) values(v_ver_id,(b->>'service_id')::uuid,case when coalesce((b->>'unlimited')::boolean,false) then null else greatest(1,coalesce((b->>'quantity')::int,1)) end,coalesce((b->>'unlimited')::boolean,false),coalesce((b->>'extra_discount_percent')::numeric,0),nullif(b->>'min_days_between','')::int,nullif(b->>'max_per_week','')::int,nullif(b->>'max_per_month','')::int,coalesce(b->'rules','{}'::jsonb),coalesce((b->>'sort_order')::int,0)); end loop;
 if coalesce(p_rules->>'unit_scope','all')='selected' then insert into public.membership_plan_units(plan_version_id,unit_id) select v_ver_id,u from unnest(coalesce(p_unit_ids,'{}'::uuid[])) u where exists(select 1 from public.units x where x.id=u and x.barbershop_id=m.barbershop_id); end if;
 if p_plan_id is not null and p_plan_type='subscription' then update public.customer_memberships set next_plan_id=v_plan,next_plan_version_id=v_ver_id,updated_at=now() where plan_id=v_plan and plan_type='subscription' and status in ('pending','active','paused','overdue'); end if;
 return jsonb_build_object('ok',true,'plan_id',v_plan,'version_id',v_ver_id,'version_no',v_ver,'scheduled_existing_subscriptions',p_plan_id is not null and p_plan_type='subscription');
end $$;

revoke all on function public.barberium_staff_save_membership_plan(uuid,text,text,text,integer,text,boolean,boolean,jsonb,jsonb,uuid[]) from anon;
grant execute on function public.barberium_staff_save_membership_plan(uuid,text,text,text,integer,text,boolean,boolean,jsonb,jsonb,uuid[]) to authenticated;
