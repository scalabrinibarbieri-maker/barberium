create table if not exists public.professional_permissions (
  professional_id uuid primary key references public.professionals(id) on delete cascade,
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  permissions jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.professional_permissions enable row level security;
revoke all on public.professional_permissions from anon, authenticated;

create table if not exists public.blocked_time_series (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete cascade,
  professional_id uuid not null references public.professionals(id) on delete cascade,
  weekday int not null check (weekday between 0 and 6),
  start_time time not null,
  end_time time not null,
  starts_on date not null,
  ends_on date,
  reason text,
  is_active boolean not null default true,
  created_by_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_time < end_time),
  check (ends_on is null or ends_on >= starts_on)
);

alter table public.blocked_time_series enable row level security;
revoke all on public.blocked_time_series from anon, authenticated;
create index if not exists idx_block_series_prof_week on public.blocked_time_series(professional_id, weekday) where is_active;

alter table public.blocked_times add column if not exists created_by_member_id uuid references public.barbershop_members(id) on delete set null;
alter table public.blocked_times add column if not exists updated_at timestamptz not null default now();

alter table public.appointments add column if not exists listed_price_cents integer;
alter table public.appointments add column if not exists manual_adjustment_cents integer not null default 0;
alter table public.appointments add column if not exists internal_note text;
alter table public.appointments add column if not exists created_by_member_id uuid references public.barbershop_members(id) on delete set null;

update public.appointments
set listed_price_cents = total_price_cents,
    manual_adjustment_cents = 0
where listed_price_cents is null;

create table if not exists public.appointment_events (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.appointment_events enable row level security;
revoke all on public.appointment_events from anon, authenticated;
create index if not exists idx_appointment_events_appt_created on public.appointment_events(appointment_id, created_at desc);

create or replace function barberium.default_barber_permissions()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'create_appointment', true,
    'cancel_appointment', true,
    'edit_service', true,
    'edit_addons', true,
    'edit_date', true,
    'edit_time', true,
    'edit_value', true,
    'create_block', true,
    'create_recurring_block', true,
    'edit_internal_note', true,
    'mark_completed', true,
    'mark_no_show', true,
    'view_phone', true,
    'view_full_name', true,
    'view_value', true,
    'view_internal_note', true,
    'view_customer_history', true,
    'view_birthday', true,
    'view_own_revenue', true
  )
$$;

create or replace function barberium.effective_permissions(p_professional_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public','barberium','pg_temp'
as $$
  select barberium.default_barber_permissions() || coalesce(
    (select pp.permissions from public.professional_permissions pp where pp.professional_id=p_professional_id),
    '{}'::jsonb
  )
$$;

insert into public.professional_permissions(professional_id,barbershop_id,permissions)
select p.id,p.barbershop_id,barberium.default_barber_permissions()
from public.professionals p
where p.is_active
on conflict (professional_id) do nothing;

create or replace function barberium.permission_enabled(p_permissions jsonb, p_key text)
returns boolean
language sql
immutable
as $$
  select coalesce((p_permissions->>p_key)::boolean,false)
$$;

create or replace function barberium.mask_customer_name(p_name text, p_show_full boolean)
returns text
language sql
immutable
as $$
  select case when p_show_full then p_name else split_part(trim(coalesce(p_name,'')),' ',1) end
$$;

