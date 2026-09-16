-- Barberium v12.0 — vínculos reais na agenda, dias especiais e snapshots históricos

create or replace function barberium.effective_addon_price(p_professional_id uuid,p_base_service_id uuid,p_addon_service_id uuid)
returns integer language sql stable security definer set search_path='public','barberium','pg_temp' as $$
  select coalesce(ps.custom_price_cents,sa.addon_price_cents,ad.price_cents)
  from public.service_addons sa join public.services ad on ad.id=sa.addon_service_id
  left join public.professional_services ps on ps.professional_id=p_professional_id and ps.service_id=ad.id and ps.is_active
  where sa.base_service_id=p_base_service_id and sa.addon_service_id=p_addon_service_id and sa.is_active and ad.is_active
$$;

create or replace function barberium.effective_addon_duration(p_professional_id uuid,p_base_service_id uuid,p_addon_service_id uuid)
returns integer language sql stable security definer set search_path='public','barberium','pg_temp' as $$
  select coalesce(ps.custom_duration_min,sa.addon_duration_min,ad.duration_min)
  from public.service_addons sa join public.services ad on ad.id=sa.addon_service_id
  left join public.professional_services ps on ps.professional_id=p_professional_id and ps.service_id=ad.id and ps.is_active
  where sa.base_service_id=p_base_service_id and sa.addon_service_id=p_addon_service_id and sa.is_active and ad.is_active
$$;

create or replace function barberium.effective_business_hours(p_unit_id uuid,p_professional_id uuid,p_date date)
returns table(open_time time,close_time time,is_closed boolean)
language plpgsql stable security definer set search_path='public','barberium','pg_temp' as $$
begin
  return query select h.open_time,h.close_time,h.is_closed from public.special_business_hours h where h.unit_id=p_unit_id and h.professional_id=p_professional_id and h.special_date=p_date limit 1;
  if found then return; end if;
  return query select h.open_time,h.close_time,h.is_closed from public.special_business_hours h where h.unit_id=p_unit_id and h.professional_id is null and h.special_date=p_date limit 1;
  if found then return; end if;
  return query select h.open_time,h.close_time,h.is_closed from public.business_hours h where h.unit_id=p_unit_id and h.professional_id=p_professional_id and h.weekday=extract(dow from p_date)::int limit 1;
  if found then return; end if;
  return query select h.open_time,h.close_time,h.is_closed from public.business_hours h where h.unit_id=p_unit_id and h.professional_id is null and h.weekday=extract(dow from p_date)::int limit 1;
end $$;

create or replace function barberium.appointment_snapshot_guard()
returns trigger language plpgsql security definer set search_path='public','barberium','pg_temp' as $$
declare s public.services; d int;
begin
  if tg_op='INSERT' or new.service_id is distinct from old.service_id or new.professional_id is distinct from old.professional_id then
    if not barberium.professional_service_allowed(new.professional_id,new.service_id) then raise exception 'PROFESSIONAL_NOT_LINKED'; end if;
    select * into s from public.services where id=new.service_id and is_active;
    if s.id is null then raise exception 'SERVICE_NOT_FOUND'; end if;
    d:=barberium.effective_service_duration(new.professional_id,new.service_id);
    new.service_name_snapshot:=s.name;
    new.service_duration_min_snapshot:=d;
  end if;
  return new;
end $$;
drop trigger if exists trg_appointment_snapshot_guard on public.appointments;
create trigger trg_appointment_snapshot_guard before insert or update of service_id,professional_id on public.appointments for each row execute function barberium.appointment_snapshot_guard();

create or replace function barberium.appointment_addon_guard()
returns trigger language plpgsql security definer set search_path='public','barberium','pg_temp' as $$
declare a public.appointments; s public.services; ep int; ed int;
begin
  select * into a from public.appointments where id=new.appointment_id;
  if a.id is null then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  if not barberium.professional_service_allowed(a.professional_id,new.service_id) then raise exception 'PROFESSIONAL_NOT_LINKED_TO_ADDON'; end if;
  select * into s from public.services where id=new.service_id and is_active; if s.id is null then raise exception 'INVALID_ADDON'; end if;
  ep:=barberium.effective_addon_price(a.professional_id,a.service_id,new.service_id);
  ed:=barberium.effective_addon_duration(a.professional_id,a.service_id,new.service_id);
  if ep is null or ed is null then raise exception 'INVALID_ADDON'; end if;
  new.name_snapshot:=s.name; new.price_cents:=ep; new.duration_min:=ed; return new;
end $$;
drop trigger if exists trg_appointment_addon_guard on public.appointment_addons;
create trigger trg_appointment_addon_guard before insert or update of appointment_id,service_id on public.appointment_addons for each row execute function barberium.appointment_addon_guard();

create or replace function public.barberium_get_available_slots(p_barbershop_slug text,p_unit_slug text,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date)
returns jsonb language plpgsql stable security definer set search_path='public','barberium' as $$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_min_advance int; v_days_ahead int; v_must_finish boolean; v_cur timestamp; v_start timestamptz; v_end timestamptz; v_result jsonb:='[]'::jsonb;
begin
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active and service_kind in ('service','combo') and coalesce((settings->>'draft')::boolean,false)=false; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not barberium.professional_service_allowed(p_professional_id,p_service_id) then return '[]'::jsonb; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(p_professional_id,x)) then raise exception 'INVALID_ADDON'; end if;
 v_duration:=barberium.effective_service_duration(p_professional_id,p_service_id)+coalesce((select sum(barberium.effective_addon_duration(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_slot:=coalesce((v_u.settings->>'slot_minutes')::int,10); v_min_advance:=coalesce((v_u.settings->>'min_advance_minutes')::int,0); v_days_ahead:=coalesce((v_u.settings->>'days_ahead')::int,30); v_must_finish:=coalesce((v_u.settings->>'must_finish_by_close')::boolean,true);
 if p_date < (now() at time zone v_b.timezone)::date or p_date > ((now() at time zone v_b.timezone)::date + v_days_ahead) then return '[]'::jsonb; end if;
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from barberium.effective_business_hours(v_u.id,p_professional_id,p_date) h; if not found or v_closed then return '[]'::jsonb; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur < p_date::timestamp+v_close loop
   v_start:=v_cur at time zone v_b.timezone; v_end:=(v_cur+make_interval(mins=>v_duration)) at time zone v_b.timezone;
   if (not v_must_finish or v_end<=((p_date::timestamp+v_close) at time zone v_b.timezone)) and v_start>=now()+make_interval(mins=>v_min_advance)
      and not exists(select 1 from public.appointments a where a.professional_id=p_professional_id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
      and not barberium.has_block_conflict(v_u.id,p_professional_id,v_start,v_end,null,null) then v_result:=v_result||jsonb_build_array(to_char(v_cur,'HH24:MI')); end if;
   v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop;
 return v_result;
end $$;

create or replace function public.barberium_staff_available_slots(p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_exclude_appointment_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; prof public.professionals; svc public.services; b public.barbershops; u public.units; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_cur timestamp; v_start timestamptz; v_end timestamptz; result jsonb:='[]'::jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if; if m.role='barber' then p_professional_id:=m.professional_id; end if;
 select * into prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if;
 select * into svc from public.services where id=p_service_id and unit_id=prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if;
 if not barberium.professional_service_allowed(prof.id,svc.id) then return result; end if;
 select * into b from public.barbershops where id=m.barbershop_id; select * into u from public.units where id=prof.unit_id;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(prof.id,x)) then raise exception 'Adicional inválido'; end if;
 v_duration:=barberium.effective_service_duration(prof.id,svc.id)+coalesce((select sum(barberium.effective_addon_duration(prof.id,svc.id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0); v_slot:=coalesce((u.settings->>'slot_minutes')::int,10);
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from barberium.effective_business_hours(u.id,prof.id,p_date) h; if not found or v_closed then return result; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur<p_date::timestamp+v_close loop
  v_start:=v_cur at time zone coalesce(b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration);
  if v_end<=((p_date::timestamp+v_close) at time zone coalesce(b.timezone,'America/Sao_Paulo')) and (v_start>=now() or p_exclude_appointment_id is not null)
    and not exists(select 1 from public.appointments a where a.professional_id=prof.id and a.status='confirmed' and (p_exclude_appointment_id is null or a.id<>p_exclude_appointment_id) and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
    and not barberium.has_block_conflict(u.id,prof.id,v_start,v_end,null,null) then result:=result||jsonb_build_array(to_char(v_cur,'HH24:MI')); end if;
  v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop; return result;
end $$;

create or replace function public.barberium_create_appointment(p_barbershop_slug text,p_unit_slug text,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_time time,p_full_name text,p_phone text,p_birthday date default null,p_existing_token text default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','extensions' as $$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_customer public.customers; v_phone text; v_duration int; v_base int; v_total int; v_start timestamptz; v_end timestamptz; v_appt public.appointments; v_plain_token text; v_issue_token boolean:=false;
begin
 if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'INVALID_NAME'; end if; v_phone:=barberium.normalize_phone(p_phone); if v_phone is null then raise exception 'INVALID_PHONE'; end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active and service_kind in ('service','combo') and coalesce((settings->>'draft')::boolean,false)=false; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 if not barberium.professional_service_allowed(p_professional_id,p_service_id) then raise exception 'PROFESSIONAL_NOT_LINKED'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(p_professional_id,x)) then raise exception 'INVALID_ADDON'; end if;
 select * into v_customer from public.customers where barbershop_id=v_b.id and phone_e164=v_phone;
 if found then update public.customers set full_name=trim(p_full_name),birthday=coalesce(p_birthday,birthday) where id=v_customer.id returning * into v_customer; else insert into public.customers(barbershop_id,full_name,phone_e164,birthday) values(v_b.id,trim(p_full_name),v_phone,p_birthday) returning * into v_customer; v_issue_token:=true; end if;
 v_duration:=barberium.effective_service_duration(p_professional_id,p_service_id)+coalesce((select sum(barberium.effective_addon_duration(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_base:=barberium.effective_service_price(p_professional_id,p_service_id); v_total:=v_base+coalesce((select sum(barberium.effective_addon_price(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_start:=(p_date::timestamp+p_time) at time zone v_b.timezone; v_end:=v_start+make_interval(mins=>v_duration); if v_start<now() then raise exception 'PAST_SLOT'; end if;
 if not(to_char(p_time,'HH24:MI')=any(array(select jsonb_array_elements_text(public.barberium_get_available_slots(p_barbershop_slug,p_unit_slug,p_professional_id,p_service_id,coalesce(p_addon_service_ids,'{}'::uuid[]),p_date))))) then raise exception 'SLOT_UNAVAILABLE'; end if;
 begin insert into public.appointments(barbershop_id,unit_id,professional_id,customer_id,service_id,starts_at,ends_at,base_price_cents,total_price_cents,listed_price_cents,manual_adjustment_cents) values(v_b.id,v_u.id,p_professional_id,v_customer.id,p_service_id,v_start,v_end,v_base,v_total,v_total,0) returning * into v_appt; exception when exclusion_violation then raise exception 'SLOT_UNAVAILABLE'; end;
 insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min) select v_appt.id,ad.id,ad.name,barberium.effective_addon_price(p_professional_id,p_service_id,ad.id),barberium.effective_addon_duration(p_professional_id,p_service_id,ad.id) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;
 if v_issue_token then v_plain_token:=encode(extensions.gen_random_bytes(32),'hex'); insert into public.customer_access_tokens(customer_id,token_hash) values(v_customer.id,extensions.digest(v_plain_token,'sha256')); elsif p_existing_token is not null and barberium.valid_customer_token(v_customer.id,p_existing_token) then update public.customer_access_tokens set last_used_at=now() where customer_id=v_customer.id and token_hash=extensions.digest(p_existing_token,'sha256') and revoked_at is null; end if;
 select * into v_appt from public.appointments where id=v_appt.id;
 return jsonb_build_object('appointment_id',v_appt.id,'customer_id',v_customer.id,'access_token',v_plain_token,'starts_at',v_appt.starts_at,'ends_at',v_appt.ends_at,'total_price_cents',v_appt.total_price_cents);
end $$;

create or replace function public.barberium_staff_create_appointment(p_customer_id uuid,p_full_name text,p_phone text,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_time time,p_final_price_cents integer default null,p_internal_note text default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_prof public.professionals; v_service public.services; v_customer public.customers; v_b public.barbershops; v_phone text; v_duration int; v_base int; v_listed int; v_final int; v_start timestamptz; v_end timestamptz; v_appt public.appointments;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then raise exception 'Sem permissão para criar agendamentos'; end if;
 if m.role='barber' then p_professional_id:=m.professional_id; end if; select * into v_prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if; select * into v_service from public.services where id=p_service_id and unit_id=v_prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if; if not barberium.professional_service_allowed(v_prof.id,v_service.id) then raise exception 'Profissional não vinculado ao serviço'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(v_prof.id,x)) then raise exception 'Adicional inválido para este profissional'; end if;
 if p_customer_id is not null then select * into v_customer from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id; if not found then raise exception 'Cliente inválido'; end if; else if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'Informe o nome do cliente'; end if; v_phone:=barberium.normalize_phone(p_phone); if v_phone is null then raise exception 'Informe um WhatsApp válido'; end if; select * into v_customer from public.customers where barbershop_id=m.barbershop_id and phone_e164=v_phone; if found then update public.customers set full_name=trim(p_full_name),updated_at=now() where id=v_customer.id returning * into v_customer; else insert into public.customers(barbershop_id,full_name,phone_e164) values(m.barbershop_id,trim(p_full_name),v_phone) returning * into v_customer; end if; end if;
 if p_internal_note is not null and trim(p_internal_note)<>'' and m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'edit_internal_note') then raise exception 'Sem permissão para observação interna'; end if;
 select * into v_b from public.barbershops where id=m.barbershop_id; v_duration:=barberium.effective_service_duration(v_prof.id,v_service.id)+coalesce((select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0); v_base:=barberium.effective_service_price(v_prof.id,v_service.id); v_listed:=v_base+coalesce((select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0); v_final:=coalesce(p_final_price_cents,v_listed); if v_final<0 then raise exception 'Valor inválido'; end if; if v_final<>v_listed and m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'edit_value') then raise exception 'Sem permissão para alterar valor'; end if;
 v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration); if v_start<now() then raise exception 'Não é possível criar horário no passado'; end if;
 if exists(select 1 from public.appointments a where a.professional_id=v_prof.id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Horário ocupado'; end if; if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then raise exception 'Horário bloqueado'; end if;
 begin insert into public.appointments(barbershop_id,unit_id,professional_id,customer_id,service_id,starts_at,ends_at,base_price_cents,total_price_cents,listed_price_cents,manual_adjustment_cents,internal_note,created_by_member_id) values(m.barbershop_id,v_prof.unit_id,v_prof.id,v_customer.id,v_service.id,v_start,v_end,v_base,v_final,v_listed,v_final-v_listed,nullif(trim(coalesce(p_internal_note,'')),''),m.member_id) returning * into v_appt; exception when exclusion_violation then raise exception 'Horário ocupado'; end;
 insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min) select v_appt.id,ad.id,ad.name,barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=v_service.id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;
 insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,v_appt.id,m.member_id,'created',jsonb_build_object('professional',v_prof.name,'service',v_service.name,'starts_at',v_start,'total_price_cents',v_final)); return jsonb_build_object('ok',true,'appointment_id',v_appt.id);
end $$;

create or replace function public.barberium_staff_update_appointment(p_appointment_id uuid,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_time time,p_final_price_cents integer default null,p_internal_note text default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; olda public.appointments; v_prof public.professionals; v_service public.services; v_b public.barbershops; old_addons uuid[]; new_addons uuid[]; v_duration int; v_base int; v_listed int; v_final int; v_start timestamptz; v_end timestamptz; old_date date; old_time time; service_changed boolean; addons_changed boolean; professional_changed boolean; date_changed boolean; time_changed boolean; value_changed boolean; note_changed boolean;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 select * into olda from public.appointments where id=p_appointment_id for update; if olda.id is null or olda.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if; if m.role='barber' and olda.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if; if m.role='barber' and p_professional_id<>m.professional_id then raise exception 'Barbeiro não pode transferir atendimento'; end if;
 select coalesce(array_agg(service_id order by service_id),'{}'::uuid[]) into old_addons from public.appointment_addons where appointment_id=olda.id; select coalesce(array_agg(x order by x),'{}'::uuid[]) into new_addons from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x;
 select * into v_prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if; select * into v_service from public.services where id=p_service_id and unit_id=v_prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if; if not barberium.professional_service_allowed(v_prof.id,v_service.id) then raise exception 'Profissional não vinculado ao serviço'; end if; if exists(select 1 from unnest(new_addons) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(v_prof.id,x)) then raise exception 'Adicional inválido para este profissional'; end if;
 select * into v_b from public.barbershops where id=m.barbershop_id; old_date:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::date; old_time:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::time; service_changed:=olda.service_id<>p_service_id; addons_changed:=old_addons<>new_addons; professional_changed:=olda.professional_id<>p_professional_id; date_changed:=old_date<>p_date; time_changed:=old_time<>p_time; note_changed:=coalesce(olda.internal_note,'')<>coalesce(nullif(trim(coalesce(p_internal_note,'')),''),'');
 if m.role='barber' then if service_changed and not barberium.permission_enabled(perms,'edit_service') then raise exception 'Sem permissão para alterar serviço'; end if; if addons_changed and not barberium.permission_enabled(perms,'edit_addons') then raise exception 'Sem permissão para alterar adicionais'; end if; if date_changed and not barberium.permission_enabled(perms,'edit_date') then raise exception 'Sem permissão para alterar data'; end if; if time_changed and not barberium.permission_enabled(perms,'edit_time') then raise exception 'Sem permissão para alterar horário'; end if; if note_changed and not barberium.permission_enabled(perms,'edit_internal_note') then raise exception 'Sem permissão para alterar observação'; end if; end if;
 v_duration:=barberium.effective_service_duration(v_prof.id,v_service.id)+coalesce((select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x)) from unnest(new_addons) x),0); v_base:=barberium.effective_service_price(v_prof.id,v_service.id); v_listed:=v_base+coalesce((select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x)) from unnest(new_addons) x),0);
 if m.role in ('owner','admin') or barberium.permission_enabled(perms,'edit_value') then v_final:=coalesce(p_final_price_cents,v_listed); else v_final:=case when service_changed or addons_changed then v_listed else olda.total_price_cents end; if p_final_price_cents is not null and p_final_price_cents<>v_final then raise exception 'Sem permissão para alterar valor'; end if; end if; if v_final<0 then raise exception 'Valor inválido'; end if; value_changed:=olda.total_price_cents<>v_final;
 v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration); if olda.status='confirmed' then if exists(select 1 from public.appointments a where a.professional_id=v_prof.id and a.status='confirmed' and a.id<>olda.id and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Horário ocupado'; end if; if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then raise exception 'Horário bloqueado'; end if; end if;
 begin update public.appointments set professional_id=v_prof.id,unit_id=v_prof.unit_id,service_id=v_service.id,starts_at=v_start,ends_at=v_end,base_price_cents=v_base,listed_price_cents=v_listed,total_price_cents=v_final,manual_adjustment_cents=v_final-v_listed,internal_note=nullif(trim(coalesce(p_internal_note,'')),''),updated_at=now() where id=olda.id; exception when exclusion_violation then raise exception 'Horário ocupado'; end;
 delete from public.appointment_addons where appointment_id=olda.id; insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min) select olda.id,ad.id,ad.name,barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=v_service.id and a.addon_service_id=any(new_addons) and a.is_active;
 insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,olda.id,m.member_id,'edited',jsonb_build_object('professional_changed',professional_changed,'old_professional_id',olda.professional_id,'new_professional_id',v_prof.id,'service_changed',service_changed,'old_service_id',olda.service_id,'new_service_id',v_service.id,'addons_changed',addons_changed,'date_changed',date_changed,'time_changed',time_changed,'value_changed',value_changed,'note_changed',note_changed,'old_starts_at',olda.starts_at,'new_starts_at',v_start,'old_total_price_cents',olda.total_price_cents,'new_total_price_cents',v_final)); return jsonb_build_object('ok',true,'appointment_id',olda.id);
end $$;
