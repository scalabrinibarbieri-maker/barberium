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

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
select 'barberium-service-images','barberium-service-images',true,5242880,array['image/jpeg','image/png','image/webp']::text[]
where not exists(select 1 from storage.buckets where id='barberium-service-images');

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

