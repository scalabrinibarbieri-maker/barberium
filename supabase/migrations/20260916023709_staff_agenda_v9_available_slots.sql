create or replace function public.barberium_staff_available_slots(
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_date date,
  p_exclude_appointment_id uuid default null
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record; prof public.professionals; svc public.services; b public.barbershops; u public.units;
  v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_cur timestamp; v_start timestamptz; v_end timestamptz; result jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  if m.role='barber' then p_professional_id:=m.professional_id; end if;
  select * into prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if;
  select * into svc from public.services where id=p_service_id and unit_id=prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if;
  select * into b from public.barbershops where id=m.barbershop_id; select * into u from public.units where id=prof.unit_id;
  if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'Adicional inválido'; end if;
  v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=prof.id and service_id=svc.id),svc.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=svc.id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
  v_slot:=coalesce((u.settings->>'slot_minutes')::int,10);
  select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=u.id and h.professional_id=prof.id and h.weekday=extract(dow from p_date)::int;
  if not found then select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=u.id and h.professional_id is null and h.weekday=extract(dow from p_date)::int; end if;
  if not found or v_closed then return result; end if;
  v_cur:=p_date::timestamp+v_open;
  while v_cur < p_date::timestamp+v_close loop
    v_start:=v_cur at time zone coalesce(b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration);
    if v_end<=((p_date::timestamp+v_close) at time zone coalesce(b.timezone,'America/Sao_Paulo'))
      and (v_start>=now() or p_exclude_appointment_id is not null)
      and not exists(select 1 from public.appointments a where a.professional_id=prof.id and a.status='confirmed' and (p_exclude_appointment_id is null or a.id<>p_exclude_appointment_id) and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
      and not barberium.has_block_conflict(u.id,prof.id,v_start,v_end,null,null)
    then result:=result||jsonb_build_array(to_char(v_cur,'HH24:MI')); end if;
    v_cur:=v_cur+make_interval(mins=>v_slot);
  end loop;
  return result;
end;
$$;
revoke all on function public.barberium_staff_available_slots(uuid,uuid,uuid[],date,uuid) from public,anon;
grant execute on function public.barberium_staff_available_slots(uuid,uuid,uuid[],date,uuid) to authenticated;

