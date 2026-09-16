-- Barberium v12.0 — Configurações gerais, serviços, vínculos, combos e dias especiais

begin;

-- ---------- Catálogo / histórico ----------
alter table public.services add column if not exists service_kind text not null default 'service';
alter table public.services add column if not exists description text;

do $$ begin
  if not exists (
    select 1 from pg_constraint where conname='services_service_kind_check' and conrelid='public.services'::regclass
  ) then
    alter table public.services add constraint services_service_kind_check
      check (service_kind in ('service','addon','combo'));
  end if;
end $$;

alter table public.service_components add column if not exists sort_order integer not null default 0;

-- Combos históricos já existentes são reconhecidos pela composição cadastrada.
update public.services s set service_kind='combo'
where s.service_kind='service' and exists(select 1 from public.service_components sc where sc.parent_service_id=s.id);

alter table public.appointments add column if not exists service_name_snapshot text;
alter table public.appointments add column if not exists service_duration_min_snapshot integer;

update public.appointments a
set service_name_snapshot = coalesce(a.service_name_snapshot,s.name),
    service_duration_min_snapshot = coalesce(a.service_duration_min_snapshot,
      greatest(1,round(extract(epoch from (a.ends_at-a.starts_at))/60)::int),s.duration_min)
from public.services s
where s.id=a.service_id
  and (a.service_name_snapshot is null or a.service_duration_min_snapshot is null);

-- ---------- Dias / horários especiais ----------
create table if not exists public.special_business_hours (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete cascade,
  professional_id uuid references public.professionals(id) on delete cascade,
  special_date date not null,
  open_time time,
  close_time time,
  is_closed boolean not null default false,
  note text,
  created_by_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint special_business_hours_valid check (
    is_closed or (open_time is not null and close_time is not null and close_time > open_time)
  )
);
create unique index if not exists special_business_hours_unit_date_key
  on public.special_business_hours(unit_id,special_date) where professional_id is null;
create unique index if not exists special_business_hours_prof_date_key
  on public.special_business_hours(unit_id,professional_id,special_date) where professional_id is not null;
create index if not exists idx_special_business_hours_unit_date on public.special_business_hours(unit_id,special_date);

alter table public.special_business_hours enable row level security;

-- ---------- Storage de imagens ----------
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
select 'barberium-service-images','barberium-service-images',true,5242880,array['image/jpeg','image/png','image/webp']::text[]
where not exists(select 1 from storage.buckets where id='barberium-service-images');

-- Recria políticas com nomes conhecidos para ser idempotente.
drop policy if exists "barberium_service_images_insert" on storage.objects;
drop policy if exists "barberium_service_images_update" on storage.objects;
drop policy if exists "barberium_service_images_delete" on storage.objects;

create policy "barberium_service_images_insert"
on storage.objects for insert to authenticated
with check (
  bucket_id='barberium-service-images'
  and exists(
    select 1 from barberium.staff_membership() m
    where m.role in ('owner','admin')
      and split_part(name,'/',1)=m.barbershop_id::text
  )
);

create policy "barberium_service_images_update"
on storage.objects for update to authenticated
using (
  bucket_id='barberium-service-images'
  and exists(
    select 1 from barberium.staff_membership() m
    where m.role in ('owner','admin')
      and split_part(name,'/',1)=m.barbershop_id::text
  )
)
with check (
  bucket_id='barberium-service-images'
  and exists(
    select 1 from barberium.staff_membership() m
    where m.role in ('owner','admin')
      and split_part(name,'/',1)=m.barbershop_id::text
  )
);

create policy "barberium_service_images_delete"
on storage.objects for delete to authenticated
using (
  bucket_id='barberium-service-images'
  and exists(
    select 1 from barberium.staff_membership() m
    where m.role in ('owner','admin')
      and split_part(name,'/',1)=m.barbershop_id::text
  )
);

-- ---------- Helpers ----------
create or replace function barberium.make_slug(p_text text)
returns text
language sql immutable
set search_path='public','barberium','pg_temp'
as $$
  select trim(both '-' from regexp_replace(
    lower(translate(coalesce(p_text,''),
      'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
      'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')),
    '[^a-z0-9]+','-','g'))
$$;

create or replace function barberium.unique_service_slug(p_unit_id uuid,p_name text,p_ignore_id uuid default null)
returns text
language plpgsql
security definer
set search_path='public','barberium','pg_temp'
as $$
declare base text; candidate text; i int:=1;
begin
  base:=nullif(barberium.make_slug(p_name),'');
  if base is null then base:='servico'; end if;
  candidate:=base;
  while exists(select 1 from public.services s where s.unit_id=p_unit_id and s.slug=candidate and (p_ignore_id is null or s.id<>p_ignore_id)) loop
    i:=i+1; candidate:=base||'-'||i;
  end loop;
  return candidate;
end $$;

create or replace function barberium.professional_service_allowed(p_professional_id uuid,p_service_id uuid)
returns boolean
language sql stable security definer
set search_path='public','barberium','pg_temp'
as $$
  select exists(
    select 1
    from public.services s
    join public.professionals p on p.id=p_professional_id and p.unit_id=s.unit_id and p.is_active
    join public.professional_services ps on ps.professional_id=p.id and ps.service_id=s.id and ps.is_active
    where s.id=p_service_id and s.is_active
      and coalesce((s.settings->>'draft')::boolean,false)=false
      and (
        s.service_kind<>'combo'
        or not exists(select 1 from public.service_components z where z.parent_service_id=s.id)
        or not exists(
          select 1
          from public.service_components sc
          where sc.parent_service_id=s.id
            and not exists(
              select 1 from public.professional_services cps
              join public.services cs on cs.id=cps.service_id and cs.is_active
              where cps.professional_id=p.id and cps.service_id=sc.component_service_id and cps.is_active
            )
        )
      )
  )
$$;

create or replace function barberium.effective_service_price(p_professional_id uuid,p_service_id uuid)
returns integer
language sql stable security definer
set search_path='public','barberium','pg_temp'
as $$
  select coalesce(ps.custom_price_cents,s.price_cents)
  from public.services s
  left join public.professional_services ps on ps.service_id=s.id and ps.professional_id=p_professional_id and ps.is_active
  where s.id=p_service_id
$$;

create or replace function barberium.effective_service_duration(p_professional_id uuid,p_service_id uuid)
returns integer
language sql stable security definer
set search_path='public','barberium','pg_temp'
as $$
  select coalesce(ps.custom_duration_min,s.duration_min)
  from public.services s
  left join public.professional_services ps on ps.service_id=s.id and ps.professional_id=p_professional_id and ps.is_active
  where s.id=p_service_id
$$;

-- ---------- Bootstrap de configurações ----------
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
    'units',coalesce((select jsonb_agg(jsonb_build_object(
      'id',u.id,'name',u.name,'slug',u.slug,'city',u.city,'state',u.state,'whatsapp',u.whatsapp,'maps_url',u.maps_url,'is_active',u.is_active,'settings',u.settings
    ) order by u.created_at,u.name) from public.units u where u.barbershop_id=m.barbershop_id),'[]'::jsonb),
    'professionals',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'unit_id',p.unit_id,'name',p.name,'slug',p.slug,'image_path',p.image_path,'is_active',p.is_active,'sort_order',p.sort_order,'settings',p.settings
    ) order by p.sort_order,p.name) from public.professionals p where p.barbershop_id=m.barbershop_id),'[]'::jsonb),
    'subscription_plans',coalesce((select jsonb_agg(jsonb_build_object(
      'id',mp.id,'name',mp.name,'is_active',mp.is_active,'version_id',pv.id,'version_no',pv.version_no,'price_cents',pv.price_cents,'rules',pv.rules
    ) order by mp.name)
      from public.membership_plans mp
      join public.membership_plan_versions pv on pv.plan_id=mp.id and pv.version_no=mp.current_version_no
      where mp.barbershop_id=m.barbershop_id and mp.plan_type='subscription'),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_save_barbershop_settings(p_name text,p_timezone text default 'America/Sao_Paulo')
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
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

create or replace function public.barberium_staff_save_unit(
  p_unit_id uuid,p_name text,p_city text,p_state text,p_whatsapp text,p_maps_url text,p_is_active boolean,p_settings jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; v_id uuid; v_slug text; base text; i int:=1;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome da unidade inválido'; end if;

  if p_unit_id is null then
    base:=nullif(barberium.make_slug(p_name),''); if base is null then base:='unidade'; end if;
    v_slug:=base;
    while exists(select 1 from public.units u where u.barbershop_id=m.barbershop_id and u.slug=v_slug) loop i:=i+1; v_slug:=base||'-'||i; end loop;
    insert into public.units(barbershop_id,name,slug,city,state,whatsapp,maps_url,is_active,settings)
    values(m.barbershop_id,trim(p_name),v_slug,nullif(trim(coalesce(p_city,'')),''),nullif(trim(coalesce(p_state,'')),''),nullif(trim(coalesce(p_whatsapp,'')),''),nullif(trim(coalesce(p_maps_url,'')),''),coalesce(p_is_active,true),coalesce(p_settings,'{}'::jsonb))
    returning id into v_id;
    insert into public.business_hours(unit_id,professional_id,weekday,open_time,close_time,is_closed)
      select v_id,null,d,null,null,true from generate_series(0,6) d
      on conflict do nothing;
  else
    select id into v_id from public.units where id=p_unit_id and barbershop_id=m.barbershop_id;
    if v_id is null then raise exception 'Unidade inválida'; end if;
    update public.units set name=trim(p_name),city=nullif(trim(coalesce(p_city,'')),''),state=nullif(trim(coalesce(p_state,'')),''),
      whatsapp=nullif(trim(coalesce(p_whatsapp,'')),''),maps_url=nullif(trim(coalesce(p_maps_url,'')),''),is_active=coalesce(p_is_active,true),
      settings=coalesce(p_settings,'{}'::jsonb),updated_at=now() where id=v_id;
  end if;
  return jsonb_build_object('ok',true,'unit_id',v_id);
end $$;

-- ---------- Profissionais ----------
create or replace function public.barberium_staff_save_professional(
  p_professional_id uuid,p_unit_id uuid,p_name text,p_image_path text,p_is_active boolean,p_sort_order integer default 0
)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; v_id uuid; base text; slugv text; i int:=1;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome inválido'; end if;
  if p_professional_id is null then
    base:=nullif(barberium.make_slug(p_name),''); if base is null then base:='profissional'; end if;
    slugv:=base;
    while exists(select 1 from public.professionals p where p.unit_id=p_unit_id and p.slug=slugv) loop i:=i+1; slugv:=base||'-'||i; end loop;
    insert into public.professionals(barbershop_id,unit_id,name,slug,image_path,is_active,sort_order)
    values(m.barbershop_id,p_unit_id,trim(p_name),slugv,nullif(trim(coalesce(p_image_path,'')),''),coalesce(p_is_active,true),coalesce(p_sort_order,0)) returning id into v_id;
    insert into public.professional_services(professional_id,service_id,is_active)
      select v_id,s.id,true from public.services s where s.unit_id=p_unit_id and s.is_active and coalesce((s.settings->>'draft')::boolean,false)=false
      on conflict(professional_id,service_id) do update set is_active=excluded.is_active;
  else
    select id into v_id from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id;
    if v_id is null then raise exception 'Profissional inválido'; end if;
    update public.professionals set unit_id=p_unit_id,name=trim(p_name),image_path=nullif(trim(coalesce(p_image_path,'')),''),is_active=coalesce(p_is_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now() where id=v_id;
  end if;
  return jsonb_build_object('ok',true,'professional_id',v_id);
end $$;

create or replace function public.barberium_staff_delete_professional(p_professional_id uuid)
returns boolean
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  update public.professionals set is_active=false,updated_at=now() where id=p_professional_id and barbershop_id=m.barbershop_id;
  if not found then raise exception 'Profissional inválido'; end if;
  update public.professional_services set is_active=false where professional_id=p_professional_id;
  return true;
end $$;

-- ---------- Horários semanais ----------
create or replace function public.barberium_staff_business_hours(p_unit_id uuid,p_professional_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('weekday',d.d,'open_time',to_char(h.open_time,'HH24:MI'),'close_time',to_char(h.close_time,'HH24:MI'),'is_closed',coalesce(h.is_closed,true)) order by d.d)
    from generate_series(0,6) d(d)
    left join public.business_hours h on h.unit_id=p_unit_id and h.weekday=d.d and h.professional_id is not distinct from p_professional_id),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_save_business_hours(p_unit_id uuid,p_professional_id uuid,p_hours jsonb)
returns boolean
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; x jsonb; wd int; closed boolean; ot time; ct time;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_hours,'[]'::jsonb)) loop
    wd:=(x->>'weekday')::int; if wd<0 or wd>6 then raise exception 'Dia inválido'; end if;
    closed:=coalesce((x->>'is_closed')::boolean,false);
    ot:=nullif(x->>'open_time','')::time; ct:=nullif(x->>'close_time','')::time;
    if not closed and (ot is null or ct is null or ct<=ot) then raise exception 'Horário inválido'; end if;
    insert into public.business_hours(unit_id,professional_id,weekday,open_time,close_time,is_closed)
    values(p_unit_id,p_professional_id,wd,case when closed then null else ot end,case when closed then null else ct end,closed)
    on conflict(unit_id,professional_id,weekday) do update set open_time=excluded.open_time,close_time=excluded.close_time,is_closed=excluded.is_closed;
  end loop;
  return true;
end $$;

-- ---------- Dias especiais ----------
create or replace function public.barberium_staff_special_hours(p_unit_id uuid,p_professional_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'date',h.special_date,'open_time',to_char(h.open_time,'HH24:MI'),'close_time',to_char(h.close_time,'HH24:MI'),'is_closed',h.is_closed,'note',h.note,'professional_id',h.professional_id) order by h.special_date)
    from public.special_business_hours h where h.barbershop_id=m.barbershop_id and h.unit_id=p_unit_id and h.professional_id is not distinct from p_professional_id and h.special_date>=current_date-30),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_save_special_hour(
  p_id uuid,p_unit_id uuid,p_professional_id uuid,p_date date,p_open_time time,p_close_time time,p_is_closed boolean,p_note text
)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  if not coalesce(p_is_closed,false) and (p_open_time is null or p_close_time is null or p_close_time<=p_open_time) then raise exception 'Horário inválido'; end if;
  if p_id is null then
    select id into v_id from public.special_business_hours where unit_id=p_unit_id and professional_id is not distinct from p_professional_id and special_date=p_date;
    if v_id is null then
      insert into public.special_business_hours(barbershop_id,unit_id,professional_id,special_date,open_time,close_time,is_closed,note,created_by_member_id)
      values(m.barbershop_id,p_unit_id,p_professional_id,p_date,case when p_is_closed then null else p_open_time end,case when p_is_closed then null else p_close_time end,coalesce(p_is_closed,false),nullif(trim(coalesce(p_note,'')),''),m.member_id)
      returning id into v_id;
    else
      update public.special_business_hours set open_time=case when p_is_closed then null else p_open_time end,close_time=case when p_is_closed then null else p_close_time end,is_closed=coalesce(p_is_closed,false),note=nullif(trim(coalesce(p_note,'')),''),updated_at=now() where id=v_id;
    end if;
  else
    update public.special_business_hours set special_date=p_date,open_time=case when p_is_closed then null else p_open_time end,close_time=case when p_is_closed then null else p_close_time end,is_closed=coalesce(p_is_closed,false),note=nullif(trim(coalesce(p_note,'')),''),updated_at=now()
    where id=p_id and barbershop_id=m.barbershop_id and unit_id=p_unit_id returning id into v_id;
    if v_id is null then raise exception 'Dia especial inválido'; end if;
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
end $$;

create or replace function public.barberium_staff_delete_special_hour(p_id uuid)
returns boolean
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  delete from public.special_business_hours where id=p_id and barbershop_id=m.barbershop_id;
  return found;
end $$;

-- ---------- Serviços / adicionais / combos ----------
create or replace function public.barberium_staff_seed_default_services(p_unit_id uuid)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; c uuid; b uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if exists(select 1 from public.services s where s.unit_id=p_unit_id) then return jsonb_build_object('ok',true,'created',false); end if;

  insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,sort_order,is_active,settings,service_kind)
  values(m.barbershop_id,p_unit_id,'Corte','corte',0,45,'45 min',10,true,jsonb_build_object('draft',true),'service') returning id into c;
  insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,sort_order,is_active,settings,service_kind)
  values(m.barbershop_id,p_unit_id,'Barba','barba',0,30,'30 min',20,true,jsonb_build_object('draft',true),'service') returning id into b;
  insert into public.professional_services(professional_id,service_id,is_active)
  select p.id,x.sid,true from public.professionals p cross join (values(c),(b)) x(sid) where p.unit_id=p_unit_id and p.is_active
  on conflict(professional_id,service_id) do update set is_active=true;
  return jsonb_build_object('ok',true,'created',true,'service_ids',jsonb_build_array(c,b));
end $$;

create or replace function public.barberium_staff_service_settings(p_unit_id uuid)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;

  return jsonb_build_object(
    'unit',(select jsonb_build_object('id',u.id,'name',u.name,'settings',u.settings) from public.units u where u.id=p_unit_id),
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'image_path',p.image_path,'is_active',p.is_active) order by p.sort_order,p.name) from public.professionals p where p.unit_id=p_unit_id and p.is_active),'[]'::jsonb),
    'services',coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'slug',s.slug,'kind',s.service_kind,'description',s.description,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,
      'image_path',s.image_path,'is_active',s.is_active,'draft',coalesce((s.settings->>'draft')::boolean,false),'sort_order',s.sort_order,
      'addon_ids',coalesce((select jsonb_agg(sa.addon_service_id order by sa.sort_order) from public.service_addons sa where sa.base_service_id=s.id and sa.is_active),'[]'::jsonb),
      'component_ids',coalesce((select jsonb_agg(sc.component_service_id order by sc.sort_order) from public.service_components sc where sc.parent_service_id=s.id),'[]'::jsonb),
      'professional_links',coalesce((select jsonb_agg(jsonb_build_object(
        'professional_id',p.id,'professional',p.name,'linked',coalesce(ps.is_active,false),'custom_price_cents',ps.custom_price_cents,'custom_duration_min',ps.custom_duration_min,
        'combo_eligible',case when s.service_kind<>'combo' or not exists(select 1 from public.service_components z where z.parent_service_id=s.id) then true else not exists(select 1 from public.service_components z where z.parent_service_id=s.id and not exists(select 1 from public.professional_services cps where cps.professional_id=p.id and cps.service_id=z.component_service_id and cps.is_active)) end
      ) order by p.sort_order,p.name) from public.professionals p left join public.professional_services ps on ps.professional_id=p.id and ps.service_id=s.id where p.unit_id=p_unit_id and p.is_active),'[]'::jsonb)
    ) order by s.is_active desc,s.sort_order,s.name) from public.services s where s.unit_id=p_unit_id),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_save_catalog_item(
  p_service_id uuid,
  p_unit_id uuid,
  p_kind text,
  p_name text,
  p_description text,
  p_price_cents integer,
  p_duration_min integer,
  p_image_path text,
  p_sort_order integer,
  p_professional_links jsonb,
  p_addon_service_ids uuid[] default '{}'::uuid[],
  p_component_service_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; sid uuid; link jsonb; pid uuid; linked boolean; cp int; cd int; x uuid; ordern int:=0; created boolean:=false;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_kind not in ('service','addon','combo') then raise exception 'Tipo inválido'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Informe o nome'; end if;
  if coalesce(p_price_cents,-1)<0 then raise exception 'Valor inválido'; end if;
  if coalesce(p_duration_min,0)<5 or p_duration_min>480 then raise exception 'Duração inválida'; end if;

  if p_kind='combo' then
    if cardinality(coalesce(p_component_service_ids,'{}'::uuid[]))<2 then raise exception 'Combo precisa de pelo menos dois serviços'; end if;
    if exists(select 1 from unnest(p_component_service_ids) q where not exists(select 1 from public.services s where s.id=q and s.unit_id=p_unit_id and s.is_active and s.service_kind='service')) then raise exception 'Componente inválido'; end if;
  else
    p_component_service_ids:='{}'::uuid[];
  end if;

  if p_kind in ('service','combo') then
    if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) q where not exists(select 1 from public.services s where s.id=q and s.unit_id=p_unit_id and s.is_active and s.service_kind<>'combo')) then raise exception 'Adicional inválido'; end if;
  else
    p_addon_service_ids:='{}'::uuid[];
  end if;

  if p_service_id is null then
    insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,image_path,sort_order,is_active,settings,service_kind,description)
    values(m.barbershop_id,p_unit_id,trim(p_name),barberium.unique_service_slug(p_unit_id,p_name,null),p_price_cents,p_duration_min,p_duration_min||' min',nullif(trim(coalesce(p_image_path,'')),''),coalesce(p_sort_order,0),true,'{}'::jsonb,p_kind,nullif(trim(coalesce(p_description,'')),''))
    returning id into sid;
    created:=true;
  else
    select id into sid from public.services where id=p_service_id and barbershop_id=m.barbershop_id and unit_id=p_unit_id;
    if sid is null then raise exception 'Serviço inválido'; end if;
    update public.services set name=trim(p_name),price_cents=p_price_cents,duration_min=p_duration_min,duration_label=p_duration_min||' min',
      image_path=nullif(trim(coalesce(p_image_path,'')),''),sort_order=coalesce(p_sort_order,0),is_active=true,service_kind=p_kind,description=nullif(trim(coalesce(p_description,'')),''),
      settings=coalesce(settings,'{}'::jsonb)-'draft',updated_at=now() where id=sid;
  end if;

  delete from public.service_components where parent_service_id=sid;
  ordern:=0;
  foreach x in array coalesce(p_component_service_ids,'{}'::uuid[]) loop
    ordern:=ordern+1;
    insert into public.service_components(parent_service_id,component_service_id,quantity,sort_order) values(sid,x,1,ordern);
  end loop;

  update public.service_addons set is_active=false where base_service_id=sid;
  ordern:=0;
  foreach x in array coalesce(p_addon_service_ids,'{}'::uuid[]) loop
    ordern:=ordern+1;
    insert into public.service_addons(barbershop_id,unit_id,base_service_id,addon_service_id,addon_price_cents,addon_duration_min,sort_order,is_active)
    select m.barbershop_id,p_unit_id,sid,a.id,a.price_cents,a.duration_min,ordern,true from public.services a where a.id=x
    on conflict(base_service_id,addon_service_id) do update set addon_price_cents=excluded.addon_price_cents,addon_duration_min=excluded.addon_duration_min,sort_order=excluded.sort_order,is_active=true;
  end loop;

  -- Se o item é um adicional, sincroniza os vínculos existentes em serviços-base.
  if p_kind='addon' then
    update public.service_addons sa set addon_price_cents=p_price_cents,addon_duration_min=p_duration_min
    where sa.addon_service_id=sid and sa.is_active;
  end if;

  -- O JSON representa o estado completo dos vínculos da unidade.
  for link in select * from jsonb_array_elements(coalesce(p_professional_links,'[]'::jsonb)) loop
    pid:=(link->>'professional_id')::uuid;
    linked:=coalesce((link->>'linked')::boolean,false);
    cp:=nullif(link->>'custom_price_cents','')::int;
    cd:=nullif(link->>'custom_duration_min','')::int;
    if not exists(select 1 from public.professionals p where p.id=pid and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id and p.is_active) then raise exception 'Profissional inválido'; end if;
    if cp is not null and cp<0 then raise exception 'Preço personalizado inválido'; end if;
    if cd is not null and (cd<5 or cd>480) then raise exception 'Duração personalizada inválida'; end if;
    if p_kind='combo' and linked and exists(
      select 1 from public.service_components sc where sc.parent_service_id=sid
      and not exists(select 1 from public.professional_services cps where cps.professional_id=pid and cps.service_id=sc.component_service_id and cps.is_active)
    ) then raise exception 'O profissional precisa executar todos os serviços do combo'; end if;
    insert into public.professional_services(professional_id,service_id,is_active,custom_price_cents,custom_duration_min)
    values(pid,sid,linked,case when linked then cp else null end,case when linked then cd else null end)
    on conflict(professional_id,service_id) do update set is_active=excluded.is_active,custom_price_cents=excluded.custom_price_cents,custom_duration_min=excluded.custom_duration_min;
  end loop;

  -- Profissionais omitidos no estado completo ficam desvinculados.
  update public.professional_services ps set is_active=false,custom_price_cents=null,custom_duration_min=null
  where ps.service_id=sid and exists(select 1 from public.professionals p where p.id=ps.professional_id and p.unit_id=p_unit_id)
    and not exists(select 1 from jsonb_array_elements(coalesce(p_professional_links,'[]'::jsonb)) j where (j->>'professional_id')::uuid=ps.professional_id);

  return jsonb_build_object('ok',true,'service_id',sid,'created',created);
end $$;

create or replace function public.barberium_staff_set_catalog_image(p_service_id uuid,p_image_path text)
returns boolean
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  update public.services set image_path=nullif(trim(coalesce(p_image_path,'')),''),updated_at=now() where id=p_service_id and barbershop_id=m.barbershop_id;
  if not found then raise exception 'Serviço inválido'; end if;
  return true;
end $$;

create or replace function public.barberium_staff_delete_catalog_item(p_service_id uuid)
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; affected int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  update public.services set is_active=false,updated_at=now() where id=p_service_id and barbershop_id=m.barbershop_id;
  if not found then raise exception 'Serviço inválido'; end if;
  update public.professional_services set is_active=false where service_id=p_service_id;
  update public.service_addons set is_active=false where base_service_id=p_service_id or addon_service_id=p_service_id;
  select count(*) into affected from public.service_components sc join public.services s on s.id=sc.parent_service_id where sc.component_service_id=p_service_id and s.is_active;
  return jsonb_build_object('ok',true,'dependent_combos',affected);
end $$;

-- ---------- Catálogo público enriquecido ----------
create or replace function public.barberium_get_catalog(p_barbershop_slug text,p_unit_slug text)
returns jsonb
language sql stable security definer
set search_path='public','barberium'
as $$
with b as(select * from public.barbershops where slug=p_barbershop_slug and status='active' limit 1),
u as(select u.* from public.units u join b on b.id=u.barbershop_id where u.slug=p_unit_slug and u.is_active limit 1)
select jsonb_build_object(
 'barbershop',jsonb_build_object('id',b.id,'name',b.name,'slug',b.slug,'timezone',b.timezone,'settings',b.settings),
 'unit',jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug,'city',u.city,'state',u.state,'whatsapp',u.whatsapp,'maps_url',u.maps_url,'settings',u.settings),
 'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path) order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active),'[]'::jsonb),
 'services',coalesce((select jsonb_agg(jsonb_build_object(
   'id',s.id,'name',s.name,'slug',s.slug,'kind',s.service_kind,'description',s.description,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,'image_path',s.image_path,
   'professional_links',coalesce((select jsonb_agg(jsonb_build_object('professional_id',p.id,'price_cents',barberium.effective_service_price(p.id,s.id),'duration_min',barberium.effective_service_duration(p.id,s.id)) order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active and barberium.professional_service_allowed(p.id,s.id)),'[]'::jsonb),
   'professional_ids',coalesce((select jsonb_agg(p.id order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active and barberium.professional_service_allowed(p.id,s.id)),'[]'::jsonb),
   'addons',coalesce((select jsonb_agg(jsonb_build_object(
      'service_id',ad.id,'name',ad.name,'slug',ad.slug,'description',ad.description,'price_cents',ad.price_cents,'duration_min',ad.duration_min,'image_path',ad.image_path,
      'professional_links',coalesce((select jsonb_agg(jsonb_build_object('professional_id',p2.id,'price_cents',barberium.effective_service_price(p2.id,ad.id),'duration_min',barberium.effective_service_duration(p2.id,ad.id)) order by p2.sort_order,p2.name) from public.professionals p2 where p2.unit_id=u.id and p2.is_active and barberium.professional_service_allowed(p2.id,ad.id)),'[]'::jsonb),
      'professional_ids',coalesce((select jsonb_agg(p2.id order by p2.sort_order,p2.name) from public.professionals p2 where p2.unit_id=u.id and p2.is_active and barberium.professional_service_allowed(p2.id,ad.id)),'[]'::jsonb)
   ) order by a.sort_order,ad.name) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=s.id and a.is_active and ad.is_active and coalesce((ad.settings->>'draft')::boolean,false)=false),'[]'::jsonb),
   'components',coalesce((select jsonb_agg(jsonb_build_object('service_id',cs.id,'name',cs.name,'quantity',sc.quantity) order by sc.sort_order,cs.name) from public.service_components sc join public.services cs on cs.id=sc.component_service_id where sc.parent_service_id=s.id),'[]'::jsonb)
 ) order by s.sort_order,s.name) from public.services s where s.unit_id=u.id and s.is_active and s.service_kind in ('service','combo') and coalesce((s.settings->>'draft')::boolean,false)=false
   and (s.service_kind<>'combo' or not exists(select 1 from public.service_components sc join public.services cs on cs.id=sc.component_service_id where sc.parent_service_id=s.id and not cs.is_active))
 ),'[]'::jsonb)
) from b,u;
$$;

-- Staff catalog também recebe descrição, tipo, imagem e vínculos.
create or replace function public.barberium_staff_catalog()
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; v_permissions jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  v_permissions:=case when m.role in ('owner','admin') then '{}'::jsonb else barberium.effective_permissions(m.professional_id) end;
  return jsonb_build_object(
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path) order by p.sort_order,p.name) from public.professionals p where p.barbershop_id=m.barbershop_id and p.is_active and (m.role in ('owner','admin') or p.id=m.professional_id)),'[]'::jsonb),
    'services',coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'slug',s.slug,'kind',s.service_kind,'description',s.description,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,'image_path',s.image_path,
      'professional_ids',coalesce((select jsonb_agg(ps.professional_id) from public.professional_services ps where ps.service_id=s.id and ps.is_active),'[]'::jsonb),
      'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',ad.id,'name',ad.name,'price_cents',ad.price_cents,'duration_min',ad.duration_min,'description',ad.description,'image_path',ad.image_path) order by sa.sort_order,ad.name) from public.service_addons sa join public.services ad on ad.id=sa.addon_service_id where sa.base_service_id=s.id and sa.is_active and ad.is_active),'[]'::jsonb)
    ) order by s.sort_order,s.name) from public.services s where s.barbershop_id=m.barbershop_id and s.is_active and s.service_kind in ('service','combo') and coalesce((s.settings->>'draft')::boolean,false)=false),'[]'::jsonb),
    'units',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug) order by u.name) from public.units u where u.barbershop_id=m.barbershop_id and u.is_active),'[]'::jsonb),
    'permissions',v_permissions
  );
end $$;

-- ---------- Grants ----------
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
revoke all on function public.barberium_staff_seed_default_services(uuid) from anon;
revoke all on function public.barberium_staff_service_settings(uuid) from anon;
revoke all on function public.barberium_staff_save_catalog_item(uuid,uuid,text,text,text,integer,integer,text,integer,jsonb,uuid[],uuid[]) from anon;
revoke all on function public.barberium_staff_set_catalog_image(uuid,text) from anon;
revoke all on function public.barberium_staff_delete_catalog_item(uuid) from anon;

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
grant execute on function public.barberium_staff_seed_default_services(uuid) to authenticated;
grant execute on function public.barberium_staff_service_settings(uuid) to authenticated;
grant execute on function public.barberium_staff_save_catalog_item(uuid,uuid,text,text,text,integer,integer,text,integer,jsonb,uuid[],uuid[]) to authenticated;
grant execute on function public.barberium_staff_set_catalog_image(uuid,text) to authenticated;
grant execute on function public.barberium_staff_delete_catalog_item(uuid) to authenticated;

commit;
