create or replace function barberium.has_block_conflict(
  p_unit_id uuid,
  p_professional_id uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_exclude_block_id uuid default null,
  p_exclude_series_id uuid default null
)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public','barberium','pg_temp'
as $$
declare
  v_tz text;
  v_date date;
  v_start_time time;
  v_end_time time;
begin
  select coalesce(b.timezone,'America/Sao_Paulo') into v_tz
  from public.units u join public.barbershops b on b.id=u.barbershop_id
  where u.id=p_unit_id;

  v_date := (p_start at time zone v_tz)::date;
  v_start_time := (p_start at time zone v_tz)::time;
  v_end_time := (p_end at time zone v_tz)::time;

  if exists(
    select 1 from public.blocked_times bt
    where bt.unit_id=p_unit_id
      and (bt.professional_id is null or bt.professional_id=p_professional_id)
      and (p_exclude_block_id is null or bt.id<>p_exclude_block_id)
      and tstzrange(bt.starts_at,bt.ends_at,'[)') && tstzrange(p_start,p_end,'[)')
  ) then return true; end if;

  if exists(
    select 1 from public.blocked_time_series bs
    where bs.unit_id=p_unit_id
      and bs.professional_id=p_professional_id
      and bs.is_active
      and (p_exclude_series_id is null or bs.id<>p_exclude_series_id)
      and v_date>=bs.starts_on
      and (bs.ends_on is null or v_date<=bs.ends_on)
      and bs.weekday=extract(dow from v_date)::int
      and tsrange(v_date::timestamp+bs.start_time,v_date::timestamp+bs.end_time,'[)') &&
          tsrange(v_date::timestamp+v_start_time,v_date::timestamp+v_end_time,'[)')
  ) then return true; end if;

  return false;
end;
$$;

create or replace function public.barberium_get_available_slots(p_barbershop_slug text, p_unit_slug text, p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_date date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','barberium'
as $$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_min_advance int; v_days_ahead int; v_must_finish boolean; v_cur timestamp; v_start timestamptz; v_end timestamptz; v_result jsonb:='[]'::jsonb;
begin
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'INVALID_ADDON'; end if;
 v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_slot:=coalesce((v_u.settings->>'slot_minutes')::int,10);
 v_min_advance:=coalesce((v_u.settings->>'min_advance_minutes')::int,0);
 v_days_ahead:=coalesce((v_u.settings->>'days_ahead')::int,30);
 v_must_finish:=coalesce((v_u.settings->>'must_finish_by_close')::boolean,true);
 if p_date < (now() at time zone v_b.timezone)::date or p_date > ((now() at time zone v_b.timezone)::date + v_days_ahead) then return '[]'::jsonb; end if;
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=v_u.id and h.professional_id=p_professional_id and h.weekday=extract(dow from p_date)::int;
 if not found then select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=v_u.id and h.professional_id is null and h.weekday=extract(dow from p_date)::int; end if;
 if not found or v_closed then return '[]'::jsonb; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur < p_date::timestamp+v_close loop
   v_start:=v_cur at time zone v_b.timezone; v_end:=(v_cur+make_interval(mins=>v_duration)) at time zone v_b.timezone;
   if (not v_must_finish or v_end <= ((p_date::timestamp+v_close) at time zone v_b.timezone))
      and v_start>=now()+make_interval(mins=>v_min_advance)
      and not exists(select 1 from public.appointments a where a.professional_id=p_professional_id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
      and not barberium.has_block_conflict(v_u.id,p_professional_id,v_start,v_end,null,null) then
      v_result:=v_result||jsonb_build_array(to_char(v_cur,'HH24:MI'));
   end if;
   v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop;
 return v_result;
end;
$$;

create or replace function public.barberium_staff_me()
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record;
  v_permissions jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  v_permissions := case when m.role in ('owner','admin') then '{}'::jsonb else barberium.effective_permissions(m.professional_id) end;
  return jsonb_build_object(
    'member_id',m.member_id,'barbershop_id',m.barbershop_id,'barbershop_name',m.barbershop_name,
    'role',m.role,'professional_id',m.professional_id,'professional_name',m.professional_name,
    'permissions',v_permissions
  );
end;
$$;

create or replace function public.barberium_staff_catalog()
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v_permissions jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  v_permissions := case when m.role in ('owner','admin') then '{}'::jsonb else barberium.effective_permissions(m.professional_id) end;
  return jsonb_build_object(
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path) order by p.sort_order,p.name) from public.professionals p where p.barbershop_id=m.barbershop_id and p.is_active and (m.role in ('owner','admin') or p.id=m.professional_id)),'[]'::jsonb),
    'services',coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'slug',s.slug,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,
      'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',ad.id,'name',ad.name,'price_cents',sa.addon_price_cents,'duration_min',sa.addon_duration_min) order by sa.sort_order,ad.name) from public.service_addons sa join public.services ad on ad.id=sa.addon_service_id where sa.base_service_id=s.id and sa.is_active),'[]'::jsonb)
    ) order by s.sort_order,s.name) from public.services s where s.barbershop_id=m.barbershop_id and s.is_active),'[]'::jsonb),
    'permissions',v_permissions
  );
end;
$$;

revoke all on function public.barberium_staff_catalog() from public,anon;
grant execute on function public.barberium_staff_catalog() to authenticated;

