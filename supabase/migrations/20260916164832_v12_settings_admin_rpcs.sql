create or replace function public.barberium_staff_settings_bootstrap()
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  return jsonb_build_object(
    'barbershop',(select jsonb_build_object('id',b.id,'name',b.name,'slug',b.slug,'timezone',b.timezone,'settings',b.settings) from public.barbershops b where b.id=m.barbershop_id),
    'units',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug,'city',u.city,'state',u.state,'whatsapp',u.whatsapp,'maps_url',u.maps_url,'is_active',u.is_active,'settings',u.settings) order by u.created_at,u.name) from public.units u where u.barbershop_id=m.barbershop_id),'[]'::jsonb),
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'unit_id',p.unit_id,'name',p.name,'slug',p.slug,'image_path',p.image_path,'is_active',p.is_active,'sort_order',p.sort_order,'settings',p.settings) order by p.sort_order,p.name) from public.professionals p where p.barbershop_id=m.barbershop_id),'[]'::jsonb),
    'subscription_plans',coalesce((select jsonb_agg(jsonb_build_object('id',mp.id,'name',mp.name,'is_active',mp.is_active,'version_id',pv.id,'version_no',pv.version_no,'price_cents',pv.price_cents,'rules',pv.rules) order by mp.name) from public.membership_plans mp join public.membership_plan_versions pv on pv.plan_id=mp.id and pv.version_no=mp.current_version_no where mp.barbershop_id=m.barbershop_id and mp.plan_type='subscription'),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_save_barbershop_settings(p_name text,p_timezone text default 'America/Sao_Paulo')
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome inválido'; end if;
  if trim(coalesce(p_timezone,''))='' then raise exception 'Fuso horário inválido'; end if;
  update public.barbershops set name=trim(p_name),timezone=trim(p_timezone),updated_at=now() where id=m.barbershop_id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.barberium_staff_save_unit(p_unit_id uuid,p_name text,p_city text,p_state text,p_whatsapp text,p_maps_url text,p_is_active boolean,p_settings jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_id uuid; v_slug text; base text; i int:=1;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome da unidade inválido'; end if;
  if p_unit_id is null then
    base:=nullif(barberium.make_slug(p_name),''); if base is null then base:='unidade'; end if; v_slug:=base;
    while exists(select 1 from public.units u where u.barbershop_id=m.barbershop_id and u.slug=v_slug) loop i:=i+1; v_slug:=base||'-'||i; end loop;
    insert into public.units(barbershop_id,name,slug,city,state,whatsapp,maps_url,is_active,settings)
    values(m.barbershop_id,trim(p_name),v_slug,nullif(trim(coalesce(p_city,'')),''),nullif(trim(coalesce(p_state,'')),''),nullif(trim(coalesce(p_whatsapp,'')),''),nullif(trim(coalesce(p_maps_url,'')),''),coalesce(p_is_active,true),coalesce(p_settings,'{}'::jsonb)) returning id into v_id;
    insert into public.business_hours(unit_id,professional_id,weekday,open_time,close_time,is_closed) select v_id,null,d,null,null,true from generate_series(0,6) d on conflict do nothing;
  else
    select id into v_id from public.units where id=p_unit_id and barbershop_id=m.barbershop_id; if v_id is null then raise exception 'Unidade inválida'; end if;
    update public.units set name=trim(p_name),city=nullif(trim(coalesce(p_city,'')),''),state=nullif(trim(coalesce(p_state,'')),''),whatsapp=nullif(trim(coalesce(p_whatsapp,'')),''),maps_url=nullif(trim(coalesce(p_maps_url,'')),''),is_active=coalesce(p_is_active,true),settings=coalesce(p_settings,'{}'::jsonb),updated_at=now() where id=v_id;
  end if;
  return jsonb_build_object('ok',true,'unit_id',v_id);
end $$;

create or replace function public.barberium_staff_save_professional(p_professional_id uuid,p_unit_id uuid,p_name text,p_image_path text,p_is_active boolean,p_sort_order integer default 0)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_id uuid; base text; slugv text; i int:=1;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome inválido'; end if;
  if p_professional_id is null then
    base:=nullif(barberium.make_slug(p_name),''); if base is null then base:='profissional'; end if; slugv:=base;
    while exists(select 1 from public.professionals p where p.unit_id=p_unit_id and p.slug=slugv) loop i:=i+1; slugv:=base||'-'||i; end loop;
    insert into public.professionals(barbershop_id,unit_id,name,slug,image_path,is_active,sort_order) values(m.barbershop_id,p_unit_id,trim(p_name),slugv,nullif(trim(coalesce(p_image_path,'')),''),coalesce(p_is_active,true),coalesce(p_sort_order,0)) returning id into v_id;
    insert into public.professional_services(professional_id,service_id,is_active) select v_id,s.id,true from public.services s where s.unit_id=p_unit_id and s.is_active and coalesce((s.settings->>'draft')::boolean,false)=false on conflict(professional_id,service_id) do update set is_active=excluded.is_active;
  else
    select id into v_id from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id; if v_id is null then raise exception 'Profissional inválido'; end if;
    update public.professionals set unit_id=p_unit_id,name=trim(p_name),image_path=nullif(trim(coalesce(p_image_path,'')),''),is_active=coalesce(p_is_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now() where id=v_id;
  end if;
  return jsonb_build_object('ok',true,'professional_id',v_id);
end $$;

create or replace function public.barberium_staff_delete_professional(p_professional_id uuid)
returns boolean language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  update public.professionals set is_active=false,updated_at=now() where id=p_professional_id and barbershop_id=m.barbershop_id; if not found then raise exception 'Profissional inválido'; end if;
  update public.professional_services set is_active=false where professional_id=p_professional_id; return true;
end $$;

create or replace function public.barberium_staff_business_hours(p_unit_id uuid,p_professional_id uuid default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('weekday',d.d,'open_time',to_char(h.open_time,'HH24:MI'),'close_time',to_char(h.close_time,'HH24:MI'),'is_closed',coalesce(h.is_closed,true)) order by d.d) from generate_series(0,6) d(d) left join public.business_hours h on h.unit_id=p_unit_id and h.weekday=d.d and h.professional_id is not distinct from p_professional_id),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_save_business_hours(p_unit_id uuid,p_professional_id uuid,p_hours jsonb)
returns boolean language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; x jsonb; wd int; closed boolean; ot time; ct time;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_hours,'[]'::jsonb)) loop
    wd:=(x->>'weekday')::int; if wd<0 or wd>6 then raise exception 'Dia inválido'; end if; closed:=coalesce((x->>'is_closed')::boolean,false); ot:=nullif(x->>'open_time','')::time; ct:=nullif(x->>'close_time','')::time;
    if not closed and (ot is null or ct is null or ct<=ot) then raise exception 'Horário inválido'; end if;
    insert into public.business_hours(unit_id,professional_id,weekday,open_time,close_time,is_closed) values(p_unit_id,p_professional_id,wd,case when closed then null else ot end,case when closed then null else ct end,closed)
    on conflict(unit_id,professional_id,weekday) do update set open_time=excluded.open_time,close_time=excluded.close_time,is_closed=excluded.is_closed;
  end loop; return true;
end $$;

create or replace function public.barberium_staff_special_hours(p_unit_id uuid,p_professional_id uuid default null)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'date',h.special_date,'open_time',to_char(h.open_time,'HH24:MI'),'close_time',to_char(h.close_time,'HH24:MI'),'is_closed',h.is_closed,'note',h.note,'professional_id',h.professional_id) order by h.special_date) from public.special_business_hours h where h.barbershop_id=m.barbershop_id and h.unit_id=p_unit_id and h.professional_id is not distinct from p_professional_id and h.special_date>=current_date-30),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_save_special_hour(p_id uuid,p_unit_id uuid,p_professional_id uuid,p_date date,p_open_time time,p_close_time time,p_is_closed boolean,p_note text)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  if not coalesce(p_is_closed,false) and (p_open_time is null or p_close_time is null or p_close_time<=p_open_time) then raise exception 'Horário inválido'; end if;
  if p_id is null then
    select id into v_id from public.special_business_hours where unit_id=p_unit_id and professional_id is not distinct from p_professional_id and special_date=p_date;
    if v_id is null then
      insert into public.special_business_hours(barbershop_id,unit_id,professional_id,special_date,open_time,close_time,is_closed,note,created_by_member_id) values(m.barbershop_id,p_unit_id,p_professional_id,p_date,case when p_is_closed then null else p_open_time end,case when p_is_closed then null else p_close_time end,coalesce(p_is_closed,false),nullif(trim(coalesce(p_note,'')),''),m.member_id) returning id into v_id;
    else
      update public.special_business_hours set open_time=case when p_is_closed then null else p_open_time end,close_time=case when p_is_closed then null else p_close_time end,is_closed=coalesce(p_is_closed,false),note=nullif(trim(coalesce(p_note,'')),''),updated_at=now() where id=v_id;
    end if;
  else
    update public.special_business_hours set special_date=p_date,open_time=case when p_is_closed then null else p_open_time end,close_time=case when p_is_closed then null else p_close_time end,is_closed=coalesce(p_is_closed,false),note=nullif(trim(coalesce(p_note,'')),''),updated_at=now() where id=p_id and barbershop_id=m.barbershop_id and unit_id=p_unit_id returning id into v_id;
    if v_id is null then raise exception 'Dia especial inválido'; end if;
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
end $$;

create or replace function public.barberium_staff_delete_special_hour(p_id uuid)
returns boolean language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  delete from public.special_business_hours where id=p_id and barbershop_id=m.barbershop_id; return found;
end $$;

revoke all on function public.barberium_staff_settings_bootstrap() from anon;
revoke all on function public.barberium_staff_save_barbershop_settings(text,text) from anon;
revoke all on function public.barberium_staff_save_unit(uuid,text,text,text,text,text,boolean,jsonb) from anon;
revoke all on function public.barberium_staff_save_professional(uuid,uuid,text,text,boolean,integer) from anon;
revoke all on function public.barberium_staff_delete_professional(uuid) from anon;
revoke all on function public.barberium_staff_business_hours(uuid,uuid) from anon;
revoke all on function public.barberium_staff_save_business_hours(uuid,uuid,jsonb) from anon;
revoke all on function public.barberium_staff_special_hours(uuid,uuid) from anon;
revoke all on function public.barberium_staff_save_special_hour(uuid,uuid,uuid,date,time,time,boolean,text) from anon;
revoke all on function public.barberium_staff_delete_special_hour(uuid) from anon;
grant execute on function public.barberium_staff_settings_bootstrap() to authenticated;
grant execute on function public.barberium_staff_save_barbershop_settings(text,text) to authenticated;
grant execute on function public.barberium_staff_save_unit(uuid,text,text,text,text,text,boolean,jsonb) to authenticated;
grant execute on function public.barberium_staff_save_professional(uuid,uuid,text,text,boolean,integer) to authenticated;
grant execute on function public.barberium_staff_delete_professional(uuid) to authenticated;
grant execute on function public.barberium_staff_business_hours(uuid,uuid) to authenticated;
grant execute on function public.barberium_staff_save_business_hours(uuid,uuid,jsonb) to authenticated;
grant execute on function public.barberium_staff_special_hours(uuid,uuid) to authenticated;
grant execute on function public.barberium_staff_save_special_hour(uuid,uuid,uuid,date,time,time,boolean,text) to authenticated;
grant execute on function public.barberium_staff_delete_special_hour(uuid) to authenticated;

