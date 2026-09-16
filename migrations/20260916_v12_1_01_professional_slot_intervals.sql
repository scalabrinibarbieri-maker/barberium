-- Barberium v12.1 — grade/listagem de horários individual por profissional

create or replace function barberium.effective_slot_minutes(p_professional_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'public','barberium','pg_temp'
as $function$
  select greatest(5, least(120,
    coalesce(
      nullif(p.settings->>'slot_minutes','')::int,
      nullif(u.settings->>'slot_minutes','')::int,
      10
    )
  ))
  from public.professionals p
  join public.units u on u.id=p.unit_id
  where p.id=p_professional_id
$function$;

revoke all on function barberium.effective_slot_minutes(uuid) from public, anon, authenticated;

create or replace function public.barberium_staff_save_professional_agenda_settings(
  p_professional_id uuid,
  p_slot_minutes integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare m record; v_settings jsonb; v_effective int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  if p_slot_minutes is not null and (p_slot_minutes<5 or p_slot_minutes>120) then raise exception 'Intervalo deve ficar entre 5 e 120 minutos'; end if;

  update public.professionals p
  set settings=case
      when p_slot_minutes is null then coalesce(p.settings,'{}'::jsonb)-'slot_minutes'
      else jsonb_set(coalesce(p.settings,'{}'::jsonb),'{slot_minutes}',to_jsonb(p_slot_minutes),true)
    end,
    updated_at=now()
  where p.id=p_professional_id;

  v_effective:=barberium.effective_slot_minutes(p_professional_id);
  select settings into v_settings from public.professionals where id=p_professional_id;
  return jsonb_build_object('ok',true,'professional_id',p_professional_id,'slot_minutes',p_slot_minutes,'effective_slot_minutes',v_effective,'settings',v_settings);
end
$function$;

revoke all on function public.barberium_staff_save_professional_agenda_settings(uuid,integer) from public, anon;
grant execute on function public.barberium_staff_save_professional_agenda_settings(uuid,integer) to authenticated;

create or replace function public.barberium_get_available_slots(p_barbershop_slug text, p_unit_slug text, p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_date date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','barberium'
as $function$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_min_advance int; v_days_ahead int; v_must_finish boolean; v_cur timestamp; v_start timestamptz; v_end timestamptz; v_result jsonb:='[]'::jsonb;
begin
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active and service_kind in ('service','combo') and coalesce((settings->>'draft')::boolean,false)=false; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not barberium.professional_service_allowed(p_professional_id,p_service_id) then return '[]'::jsonb; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(p_professional_id,x)) then raise exception 'INVALID_ADDON'; end if;
 v_duration:=barberium.effective_service_duration(p_professional_id,p_service_id)+coalesce((select sum(barberium.effective_addon_duration(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_slot:=barberium.effective_slot_minutes(p_professional_id);
 v_min_advance:=coalesce((v_u.settings->>'min_advance_minutes')::int,0); v_days_ahead:=coalesce((v_u.settings->>'days_ahead')::int,30); v_must_finish:=coalesce((v_u.settings->>'must_finish_by_close')::boolean,true);
 if p_date < (now() at time zone v_b.timezone)::date or p_date > ((now() at time zone v_b.timezone)::date + v_days_ahead) then return '[]'::jsonb; end if;
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from barberium.effective_business_hours(v_u.id,p_professional_id,p_date) h; if not found or v_closed then return '[]'::jsonb; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur < p_date::timestamp+v_close loop
   v_start:=v_cur at time zone v_b.timezone; v_end:=(v_cur+make_interval(mins=>v_duration)) at time zone v_b.timezone;
   if (not v_must_finish or v_end<=((p_date::timestamp+v_close) at time zone v_b.timezone)) and v_start>=now()+make_interval(mins=>v_min_advance) and not exists(select 1 from public.appointments a where a.professional_id=p_professional_id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) and not barberium.has_block_conflict(v_u.id,p_professional_id,v_start,v_end,null,null) then v_result:=v_result||jsonb_build_array(to_char(v_cur,'HH24:MI')); end if;
   v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop;
 return v_result;
end
$function$;

create or replace function public.barberium_staff_available_slots(p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_date date, p_exclude_appointment_id uuid default null::uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare m record; prof public.professionals; svc public.services; b public.barbershops; u public.units; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_cur timestamp; v_start timestamptz; v_end timestamptz; result jsonb:='[]'::jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
 if m.role='barber' then p_professional_id:=m.professional_id; end if;
 select * into prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if;
 select * into svc from public.services where id=p_service_id and unit_id=prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if;
 if not barberium.professional_service_allowed(prof.id,svc.id) then return result; end if;
 select * into b from public.barbershops where id=m.barbershop_id; select * into u from public.units where id=prof.unit_id;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(prof.id,x)) then raise exception 'Adicional inválido'; end if;
 v_duration:=barberium.effective_service_duration(prof.id,svc.id)+coalesce((select sum(barberium.effective_addon_duration(prof.id,svc.id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_slot:=barberium.effective_slot_minutes(prof.id);
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from barberium.effective_business_hours(u.id,prof.id,p_date) h; if not found or v_closed then return result; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur<p_date::timestamp+v_close loop
   v_start:=v_cur at time zone coalesce(b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration);
   if v_end<=((p_date::timestamp+v_close) at time zone coalesce(b.timezone,'America/Sao_Paulo')) and (v_start>=now() or p_exclude_appointment_id is not null) and not exists(select 1 from public.appointments a where a.professional_id=prof.id and a.status='confirmed' and (p_exclude_appointment_id is null or a.id<>p_exclude_appointment_id) and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) and not barberium.has_block_conflict(u.id,prof.id,v_start,v_end,null,null) then result:=result||jsonb_build_array(to_char(v_cur,'HH24:MI')); end if;
   v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop;
 return result;
end
$function$;
