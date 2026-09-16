-- Barberium v11 — Financeiro + Assinaturas/Pacotes
-- Migração aditiva. Não remove dados existentes.

create table if not exists public.finance_settings (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid references public.units(id) on delete cascade,
  use_cash_register boolean not null default false,
  commission_basis text not null default 'gross' check (commission_basis in ('gross','net')),
  dre_default_basis text not null default 'cash' check (dre_default_basis in ('cash','accrual')),
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists finance_settings_scope_uq on public.finance_settings(barbershop_id, coalesce(unit_id,'00000000-0000-0000-0000-000000000000'::uuid));

create table if not exists public.payment_providers (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(barbershop_id,name)
);

create table if not exists public.payment_fee_rules (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.payment_providers(id) on delete cascade,
  method text not null check (method in ('pix','debit','credit')),
  installments int not null default 1 check (installments >= 1 and installments <= 36),
  percentage numeric(8,4) not null default 0 check (percentage >= 0),
  fixed_fee_cents int not null default 0 check (fixed_fee_cents >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider_id,method,installments)
);

create table if not exists public.appointment_payments (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  method text not null check (method in ('pix','cash','debit','credit')),
  amount_cents int not null check (amount_cents > 0),
  tendered_cents int,
  change_cents int not null default 0 check (change_cents >= 0),
  provider_id uuid references public.payment_providers(id) on delete set null,
  installments int check (installments is null or installments >= 1),
  fee_cents int not null default 0 check (fee_cents >= 0),
  received_at timestamptz not null default now(),
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists appointment_payments_appt_idx on public.appointment_payments(appointment_id);
create index if not exists appointment_payments_unit_received_idx on public.appointment_payments(unit_id,received_at);

create table if not exists public.appointment_receivables (
  appointment_id uuid primary key references public.appointments(id) on delete cascade,
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  original_due_cents int not null check (original_due_cents >= 0),
  paid_cents int not null default 0 check (paid_cents >= 0),
  status text not null default 'open' check (status in ('open','partial','paid')),
  due_date date,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists appointment_receivables_status_idx on public.appointment_receivables(barbershop_id,status,due_date);

create table if not exists public.finance_refunds (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  amount_cents int not null check (amount_cents > 0),
  reason text,
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  status text not null default 'open' check (status in ('open','closed')),
  opening_balance_cents int not null default 0 check (opening_balance_cents >= 0),
  opened_at timestamptz not null default now(),
  opened_by_member_id uuid references public.barbershop_members(id) on delete set null,
  expected_closing_cents int,
  counted_closing_cents int,
  difference_cents int,
  closing_justification text,
  closed_at timestamptz,
  closed_by_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists cash_sessions_one_open_per_unit on public.cash_sessions(unit_id) where status='open';
create index if not exists cash_sessions_unit_opened_idx on public.cash_sessions(unit_id,opened_at desc);

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  cash_session_id uuid not null references public.cash_sessions(id) on delete cascade,
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  movement_type text not null check (movement_type in ('payment','expense','withdrawal','supply','change','refund','adjustment')),
  amount_cents int not null,
  reference_type text,
  reference_id uuid,
  note text,
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists cash_movements_session_idx on public.cash_movements(cash_session_id,created_at);

create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(barbershop_id,name)
);

create table if not exists public.recurring_expenses (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  category_id uuid references public.expense_categories(id) on delete set null,
  description text not null,
  amount_cents int not null check (amount_cents > 0),
  recurrence text not null default 'monthly' check (recurrence in ('weekly','monthly','yearly')),
  due_day int,
  payment_method text,
  starts_on date not null,
  ends_on date,
  is_active boolean not null default true,
  note text,
  created_by_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  category_id uuid references public.expense_categories(id) on delete set null,
  recurring_expense_id uuid references public.recurring_expenses(id) on delete set null,
  description text not null,
  amount_cents int not null check (amount_cents > 0),
  due_date date not null default current_date,
  status text not null default 'predicted' check (status in ('predicted','paid')),
  payment_method text,
  paid_from_cash boolean not null default false,
  paid_at timestamptz,
  note text,
  created_by_member_id uuid references public.barbershop_members(id) on delete set null,
  paid_by_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists expenses_unit_due_idx on public.expenses(unit_id,due_date,status);

create table if not exists public.commission_profiles (
  professional_id uuid primary key references public.professionals(id) on delete cascade,
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  default_percent numeric(7,4) not null default 0 check (default_percent >= 0 and default_percent <= 100),
  settlement_cycle text not null default 'monthly' check (settlement_cycle in ('weekly','biweekly','monthly')),
  basis text not null default 'gross' check (basis in ('gross','net')),
  updated_at timestamptz not null default now()
);

create table if not exists public.commission_service_rules (
  id uuid primary key default gen_random_uuid(),
  professional_id uuid not null references public.professionals(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  mode text not null default 'percent' check (mode in ('percent','none')),
  percent numeric(7,4) check (percent is null or (percent >= 0 and percent <= 100)),
  updated_at timestamptz not null default now(),
  unique(professional_id,service_id)
);

create table if not exists public.commission_entries (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete restrict,
  professional_id uuid not null references public.professionals(id) on delete cascade,
  appointment_id uuid references public.appointments(id) on delete set null,
  source_type text not null default 'service',
  source_id uuid,
  description text,
  base_cents int not null default 0,
  rate_percent numeric(7,4),
  amount_cents int not null,
  status text not null default 'open' check (status in ('open','settled')),
  settlement_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists commission_entries_prof_status_idx on public.commission_entries(professional_id,status,created_at);
create index if not exists commission_entries_appt_idx on public.commission_entries(appointment_id);

create table if not exists public.commission_settlements (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  professional_id uuid not null references public.professionals(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  total_cents int not null default 0,
  paid_cents int not null default 0,
  status text not null default 'open' check (status in ('open','partial','paid')),
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  created_by_member_id uuid references public.barbershop_members(id) on delete set null
);

create table if not exists public.commission_settlement_payments (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.commission_settlements(id) on delete cascade,
  amount_cents int not null check (amount_cents > 0),
  payment_method text,
  paid_at timestamptz not null default now(),
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  note text
);

alter table public.commission_entries
  drop constraint if exists commission_entries_settlement_fk;
alter table public.commission_entries
  add constraint commission_entries_settlement_fk foreign key (settlement_id) references public.commission_settlements(id) on delete set null;

create table if not exists public.financial_goals (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid references public.units(id) on delete cascade,
  month date not null,
  revenue_target_cents int check (revenue_target_cents is null or revenue_target_cents >= 0),
  net_target_cents int check (net_target_cents is null or net_target_cents >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists financial_goals_scope_month_uq on public.financial_goals(barbershop_id,coalesce(unit_id,'00000000-0000-0000-0000-000000000000'::uuid),month);

-- Composição dos serviços: permite usar crédito de um serviço como parte de um combo.
create table if not exists public.service_components (
  parent_service_id uuid not null references public.services(id) on delete cascade,
  component_service_id uuid not null references public.services(id) on delete cascade,
  quantity int not null default 1 check (quantity > 0),
  primary key(parent_service_id,component_service_id),
  check(parent_service_id<>component_service_id)
);

create table if not exists public.membership_plans (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  name text not null,
  description text,
  plan_type text not null check (plan_type in ('subscription','package')),
  acquisition_mode text not null default 'team' check (acquisition_mode in ('team','site','both')),
  public_visible boolean not null default false,
  is_active boolean not null default true,
  current_version_no int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(barbershop_id,name)
);

create table if not exists public.membership_plan_versions (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.membership_plans(id) on delete cascade,
  version_no int not null,
  price_cents int not null check (price_cents >= 0),
  rules jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(plan_id,version_no)
);

create table if not exists public.membership_plan_benefits (
  id uuid primary key default gen_random_uuid(),
  plan_version_id uuid not null references public.membership_plan_versions(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  quantity int,
  unlimited boolean not null default false,
  extra_discount_percent numeric(7,4) not null default 0 check (extra_discount_percent >= 0 and extra_discount_percent <= 100),
  min_days_between int check (min_days_between is null or min_days_between >= 0),
  max_per_week int check (max_per_week is null or max_per_week > 0),
  max_per_month int check (max_per_month is null or max_per_month > 0),
  rules jsonb not null default '{}'::jsonb,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  check(unlimited or (quantity is not null and quantity > 0))
);

create table if not exists public.membership_plan_units (
  plan_version_id uuid not null references public.membership_plan_versions(id) on delete cascade,
  unit_id uuid not null references public.units(id) on delete cascade,
  primary key(plan_version_id,unit_id)
);

create table if not exists public.customer_memberships (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  plan_id uuid not null references public.membership_plans(id) on delete restrict,
  plan_version_id uuid not null references public.membership_plan_versions(id) on delete restrict,
  plan_type text not null check (plan_type in ('subscription','package')),
  origin_unit_id uuid references public.units(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','active','paused','overdue','cancelled','expired')),
  started_at timestamptz,
  current_cycle_start date,
  current_cycle_end date,
  valid_until date,
  next_plan_id uuid references public.membership_plans(id) on delete set null,
  next_plan_version_id uuid references public.membership_plan_versions(id) on delete set null,
  paused_until date,
  cancelled_at timestamptz,
  created_by_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists customer_one_live_subscription on public.customer_memberships(customer_id) where plan_type='subscription' and status in ('pending','active','paused','overdue');
create unique index if not exists customer_one_live_package on public.customer_memberships(customer_id) where plan_type='package' and status in ('pending','active','paused','overdue');

create table if not exists public.membership_cycles (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.customer_memberships(id) on delete cascade,
  cycle_start date not null,
  cycle_end date not null,
  due_date date not null,
  grace_until date,
  amount_cents int not null check (amount_cents >= 0),
  status text not null default 'pending' check (status in ('pending','paid','overdue','cancelled')),
  credits_released boolean not null default false,
  paid_at timestamptz,
  is_first_cycle boolean not null default false,
  created_at timestamptz not null default now(),
  unique(membership_id,cycle_start)
);

create table if not exists public.membership_credit_buckets (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.customer_memberships(id) on delete cascade,
  cycle_id uuid references public.membership_cycles(id) on delete cascade,
  benefit_id uuid not null references public.membership_plan_benefits(id) on delete restrict,
  total_credits int,
  used_credits int not null default 0 check (used_credits >= 0),
  reserved_credits int not null default 0 check (reserved_credits >= 0),
  advanced_credits int not null default 0 check (advanced_credits >= 0),
  expires_on date,
  created_at timestamptz not null default now(),
  check(total_credits is null or total_credits >= 0)
);
create index if not exists membership_credit_membership_idx on public.membership_credit_buckets(membership_id,expires_on);

create table if not exists public.appointment_membership_uses (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  membership_id uuid not null references public.customer_memberships(id) on delete cascade,
  bucket_id uuid references public.membership_credit_buckets(id) on delete set null,
  benefit_id uuid not null references public.membership_plan_benefits(id) on delete restrict,
  covered_service_id uuid not null references public.services(id) on delete restrict,
  target_service_id uuid not null references public.services(id) on delete restrict,
  status text not null default 'reserved' check (status in ('reserved','consumed','released','forfeited','decision_required')),
  credit_qty int not null default 1 check (credit_qty > 0),
  coverage_cents int not null default 0 check (coverage_cents >= 0),
  advanced boolean not null default false,
  created_at timestamptz not null default now(),
  consumed_at timestamptz
);
create index if not exists appointment_membership_uses_appt_idx on public.appointment_membership_uses(appointment_id,status);

create table if not exists public.membership_events (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.customer_memberships(id) on delete cascade,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.membership_requests (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  plan_id uuid not null references public.membership_plans(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by_member_id uuid references public.barbershop_members(id) on delete set null
);
create unique index if not exists membership_requests_one_pending on public.membership_requests(customer_id,plan_id) where status='pending';

create table if not exists public.membership_payments (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.customer_memberships(id) on delete cascade,
  cycle_id uuid references public.membership_cycles(id) on delete set null,
  amount_cents int not null check (amount_cents > 0),
  method text not null check (method in ('pix','cash','debit','credit')),
  provider_id uuid references public.payment_providers(id) on delete set null,
  installments int,
  fee_cents int not null default 0,
  paid_at timestamptz not null default now(),
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now()
);

-- RLS: acesso somente via RPCs SECURITY DEFINER.
do $$
declare t text;
begin
  foreach t in array array[
    'finance_settings','payment_providers','payment_fee_rules','appointment_payments','appointment_receivables','finance_refunds','cash_sessions','cash_movements','expense_categories','recurring_expenses','expenses','commission_profiles','commission_service_rules','commission_entries','commission_settlements','commission_settlement_payments','financial_goals','service_components','membership_plans','membership_plan_versions','membership_plan_benefits','membership_plan_units','customer_memberships','membership_cycles','membership_credit_buckets','appointment_membership_uses','membership_events','membership_requests','membership_payments'
  ] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end $$;

-- Mapeamento inicial dos combos atuais da Scalabrini, sem IDs hardcoded.
insert into public.service_components(parent_service_id,component_service_id)
select p.id,c.id
from public.services p join public.services c on c.barbershop_id=p.barbershop_id and c.unit_id=p.unit_id
where (p.slug,c.slug) in (
  ('combo-corte-barba','corte'),('combo-corte-barba','barba-tradizionale'),
  ('combo-corte-barboterapia','corte'),('combo-corte-barboterapia','barboterapia'),
  ('corte-barba-sobrancelha','corte'),('corte-barba-sobrancelha','barba-tradizionale'),('corte-barba-sobrancelha','sobrancelha'),
  ('corte-barba-express','corte'),('corte-barba-express','barba-express')
)
on conflict do nothing;

-- Categorias iniciais úteis. O ADM pode editar/desativar.
insert into public.expense_categories(barbershop_id,name)
select b.id,x.name from public.barbershops b cross join (values ('Água'),('Produtos'),('Limpeza'),('Aluguel'),('Energia'),('Marketing'),('Manutenção')) x(name)
where b.status='active'
on conflict do nothing;

-- Permissões v11.
create or replace function barberium.default_barber_permissions()
returns jsonb language sql immutable set search_path to 'barberium','pg_temp' as $$
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
    'view_own_revenue', true,
    'view_own_commission', true,
    'leave_payment_pending', false,
    'register_expense', false,
    'cash_withdrawal', false,
    'cash_supply', false,
    'open_cash', false,
    'close_cash', false,
    'confirm_membership_payment', false
  )
$$;

create or replace function public.barberium_staff_set_permissions(p_professional_id uuid, p_permissions jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; clean jsonb; k text; allowed text[]:=array[
'create_appointment','cancel_appointment','edit_service','edit_addons','edit_date','edit_time','edit_value','create_block','create_recurring_block','edit_internal_note','mark_completed','mark_no_show','view_phone','view_full_name','view_value','view_internal_note','view_customer_history','view_birthday','view_own_revenue','view_own_commission','leave_payment_pending','register_expense','cash_withdrawal','cash_supply','open_cash','close_cash','confirm_membership_payment'];
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  clean:='{}'::jsonb;
  foreach k in array allowed loop clean:=clean||jsonb_build_object(k,coalesce((p_permissions->>k)::boolean,false)); end loop;
  insert into public.professional_permissions(professional_id,barbershop_id,permissions,updated_at)
  values(p_professional_id,m.barbershop_id,clean,now())
  on conflict(professional_id) do update set permissions=excluded.permissions,updated_at=now();
  return jsonb_build_object('ok',true,'permissions',clean);
end $$;

-- Calcula taxa conforme provedor/tipo/parcela.
create or replace function barberium.payment_fee_cents(p_provider uuid,p_method text,p_installments int,p_amount int)
returns int language sql stable set search_path to 'public','barberium','pg_temp' as $$
  select coalesce((select round(p_amount*(r.percentage/100.0))::int+r.fixed_fee_cents
    from public.payment_fee_rules r
    where r.provider_id=p_provider and r.method=p_method and r.installments=coalesce(p_installments,1) and r.is_active limit 1),0)
$$;

-- Valor coberto por um benefício. Para combos, usa composição e respeita a regra full_retail/proportional do plano.
create or replace function barberium.membership_coverage_cents(p_benefit_id uuid,p_target_service_id uuid)
returns int language plpgsql stable set search_path to 'public','barberium','pg_temp' as $$
declare b record; target_price int; component_price int; components_sum int; mode text;
begin
  select mb.service_id, mpv.rules into b
  from public.membership_plan_benefits mb join public.membership_plan_versions mpv on mpv.id=mb.plan_version_id
  where mb.id=p_benefit_id;
  if b.service_id is null then return 0; end if;
  select price_cents into target_price from public.services where id=p_target_service_id;
  select price_cents into component_price from public.services where id=b.service_id;
  if b.service_id=p_target_service_id then return least(coalesce(component_price,0),coalesce(target_price,0)); end if;
  if not exists(select 1 from public.service_components sc where sc.parent_service_id=p_target_service_id and sc.component_service_id=b.service_id) then return 0; end if;
  mode:=coalesce(b.rules->>'combo_credit_mode','full_retail');
  if mode='proportional' then
    select coalesce(sum(s.price_cents*sc.quantity),0) into components_sum from public.service_components sc join public.services s on s.id=sc.component_service_id where sc.parent_service_id=p_target_service_id;
    if components_sum<=0 then return least(component_price,target_price); end if;
    return least(target_price,round(target_price*(component_price::numeric/components_sum))::int);
  end if;
  return least(component_price,target_price);
end $$;

-- Configurações do financeiro.
create or replace function public.barberium_staff_finance_settings()
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 return jsonb_build_object(
  'global',coalesce((select jsonb_build_object('use_cash_register',use_cash_register,'commission_basis',commission_basis,'dre_default_basis',dre_default_basis,'settings',settings) from public.finance_settings where barbershop_id=m.barbershop_id and unit_id is null),'{}'::jsonb),
  'units',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'settings',coalesce((select jsonb_build_object('use_cash_register',f.use_cash_register,'commission_basis',f.commission_basis,'dre_default_basis',f.dre_default_basis,'settings',f.settings) from public.finance_settings f where f.barbershop_id=m.barbershop_id and f.unit_id=u.id),'{}'::jsonb)) order by u.name) from public.units u where u.barbershop_id=m.barbershop_id and u.is_active),'[]'::jsonb),
  'providers',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'is_active',p.is_active,'fees',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'method',r.method,'installments',r.installments,'percentage',r.percentage,'fixed_fee_cents',r.fixed_fee_cents,'is_active',r.is_active) order by r.method,r.installments) from public.payment_fee_rules r where r.provider_id=p.id),'[]'::jsonb)) order by p.name) from public.payment_providers p where p.barbershop_id=m.barbershop_id),'[]'::jsonb)
 );
end $$;

create or replace function public.barberium_staff_save_finance_settings(p_unit_id uuid,p_use_cash_register boolean,p_commission_basis text,p_dre_default_basis text,p_settings jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_id uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if p_unit_id is not null and not exists(select 1 from public.units where id=p_unit_id and barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
 if p_commission_basis not in ('gross','net') or p_dre_default_basis not in ('cash','accrual') then raise exception 'Configuração inválida'; end if;
 select id into v_id from public.finance_settings where barbershop_id=m.barbershop_id and unit_id is not distinct from p_unit_id;
 if v_id is null then
   insert into public.finance_settings(barbershop_id,unit_id,use_cash_register,commission_basis,dre_default_basis,settings) values(m.barbershop_id,p_unit_id,coalesce(p_use_cash_register,false),p_commission_basis,p_dre_default_basis,coalesce(p_settings,'{}'::jsonb)) returning id into v_id;
 else
   update public.finance_settings set use_cash_register=coalesce(p_use_cash_register,false),commission_basis=p_commission_basis,dre_default_basis=p_dre_default_basis,settings=coalesce(p_settings,'{}'::jsonb),updated_at=now() where id=v_id;
 end if;
 return jsonb_build_object('ok',true,'id',v_id);
end $$;

create or replace function public.barberium_staff_save_payment_provider(p_provider_id uuid,p_name text,p_is_active boolean,p_fees jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_id uuid; f jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'Informe o nome do provedor'; end if;
 if p_provider_id is null then insert into public.payment_providers(barbershop_id,name,is_active) values(m.barbershop_id,trim(p_name),coalesce(p_is_active,true)) returning id into v_id;
 else update public.payment_providers set name=trim(p_name),is_active=coalesce(p_is_active,true),updated_at=now() where id=p_provider_id and barbershop_id=m.barbershop_id returning id into v_id; end if;
 if v_id is null then raise exception 'Provedor inválido'; end if;
 for f in select * from jsonb_array_elements(coalesce(p_fees,'[]'::jsonb)) loop
   insert into public.payment_fee_rules(provider_id,method,installments,percentage,fixed_fee_cents,is_active)
   values(v_id,f->>'method',coalesce((f->>'installments')::int,1),coalesce((f->>'percentage')::numeric,0),coalesce((f->>'fixed_fee_cents')::int,0),coalesce((f->>'is_active')::boolean,true))
   on conflict(provider_id,method,installments) do update set percentage=excluded.percentage,fixed_fee_cents=excluded.fixed_fee_cents,is_active=excluded.is_active,updated_at=now();
 end loop;
 return jsonb_build_object('ok',true,'id',v_id);
end $$;

-- Despesas.
create or replace function public.barberium_staff_expense_categories()
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'is_active',is_active) order by name) from public.expense_categories where barbershop_id=m.barbershop_id),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_save_expense_category(p_id uuid,p_name text,p_is_active boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_id uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'Informe a categoria'; end if;
 if p_id is null then insert into public.expense_categories(barbershop_id,name,is_active) values(m.barbershop_id,trim(p_name),p_is_active) on conflict(barbershop_id,name) do update set is_active=excluded.is_active,updated_at=now() returning id into v_id;
 else update public.expense_categories set name=trim(p_name),is_active=p_is_active,updated_at=now() where id=p_id and barbershop_id=m.barbershop_id returning id into v_id; end if;
 return jsonb_build_object('ok',true,'id',v_id);
end $$;

create or replace function public.barberium_staff_expenses(p_start date,p_end date,p_unit_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 if m.role='barber' then raise exception 'Financeiro geral restrito ao ADM'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'unit_id',e.unit_id,'unit',u.name,'category_id',e.category_id,'category',c.name,'description',e.description,'amount_cents',e.amount_cents,'due_date',e.due_date,'status',e.status,'payment_method',e.payment_method,'paid_from_cash',e.paid_from_cash,'paid_at',e.paid_at,'note',e.note) order by e.due_date desc,e.created_at desc)
 from public.expenses e join public.units u on u.id=e.unit_id left join public.expense_categories c on c.id=e.category_id
 where e.barbershop_id=m.barbershop_id and e.due_date between p_start and p_end and (p_unit_id is null or e.unit_id=p_unit_id)),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_create_expense(p_unit_id uuid,p_category_id uuid,p_description text,p_amount_cents int,p_due_date date,p_status text,p_payment_method text default null,p_paid_from_cash boolean default false,p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_id uuid; v_session uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'register_expense') then raise exception 'Sem permissão para registrar despesa'; end if;
 if not exists(select 1 from public.units where id=p_unit_id and barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
 if p_category_id is not null and not exists(select 1 from public.expense_categories where id=p_category_id and barbershop_id=m.barbershop_id) then raise exception 'Categoria inválida'; end if;
 if p_amount_cents<=0 or trim(coalesce(p_description,''))='' or p_status not in ('predicted','paid') then raise exception 'Dados da despesa inválidos'; end if;
 insert into public.expenses(barbershop_id,unit_id,category_id,description,amount_cents,due_date,status,payment_method,paid_from_cash,paid_at,note,created_by_member_id,paid_by_member_id)
 values(m.barbershop_id,p_unit_id,p_category_id,trim(p_description),p_amount_cents,coalesce(p_due_date,current_date),p_status,p_payment_method,coalesce(p_paid_from_cash,false),case when p_status='paid' then now() end,nullif(trim(coalesce(p_note,'')),''),m.member_id,case when p_status='paid' then m.member_id end) returning id into v_id;
 if p_status='paid' and p_paid_from_cash then
   select id into v_session from public.cash_sessions where unit_id=p_unit_id and status='open' order by opened_at desc limit 1;
   if v_session is null then raise exception 'Abra o caixa antes de pagar a despesa em dinheiro do caixa'; end if;
   insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,p_unit_id,'expense',-p_amount_cents,'expense',v_id,p_description,m.member_id);
 end if;
 return jsonb_build_object('ok',true,'id',v_id);
end $$;

-- Caixa.
create or replace function public.barberium_staff_cash_status(p_unit_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; s record; expected int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 if m.role='barber' and m.professional_id is null then raise exception 'Sem acesso'; end if;
 select * into s from public.cash_sessions where unit_id=p_unit_id and barbershop_id=m.barbershop_id and status='open' order by opened_at desc limit 1;
 if s.id is null then return jsonb_build_object('open',false); end if;
 select s.opening_balance_cents+coalesce(sum(amount_cents),0) into expected from public.cash_movements where cash_session_id=s.id;
 return jsonb_build_object('open',true,'id',s.id,'unit_id',s.unit_id,'opened_at',s.opened_at,'opening_balance_cents',s.opening_balance_cents,'expected_balance_cents',expected,'movements',coalesce((select jsonb_agg(jsonb_build_object('id',cm.id,'type',cm.movement_type,'amount_cents',cm.amount_cents,'note',cm.note,'created_at',cm.created_at) order by cm.created_at desc) from public.cash_movements cm where cm.cash_session_id=s.id),'[]'::jsonb));
end $$;

create or replace function public.barberium_staff_open_cash(p_unit_id uuid,p_opening_balance_cents int default 0)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_id uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'open_cash') then raise exception 'Sem permissão para abrir caixa'; end if;
 if p_opening_balance_cents<0 then raise exception 'Saldo inicial inválido'; end if;
 insert into public.cash_sessions(barbershop_id,unit_id,opening_balance_cents,opened_by_member_id) values(m.barbershop_id,p_unit_id,p_opening_balance_cents,m.member_id) returning id into v_id;
 return jsonb_build_object('ok',true,'id',v_id);
exception when unique_violation then raise exception 'Já existe um caixa aberto nesta unidade'; end $$;

create or replace function public.barberium_staff_cash_movement(p_unit_id uuid,p_type text,p_amount_cents int,p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; v_session uuid; v_signed int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if p_type not in ('withdrawal','supply') or p_amount_cents<=0 then raise exception 'Movimento inválido'; end if;
 if m.role='barber' and ((p_type='withdrawal' and not barberium.permission_enabled(perms,'cash_withdrawal')) or (p_type='supply' and not barberium.permission_enabled(perms,'cash_supply'))) then raise exception 'Sem permissão para este movimento'; end if;
 select id into v_session from public.cash_sessions where unit_id=p_unit_id and barbershop_id=m.barbershop_id and status='open' order by opened_at desc limit 1; if v_session is null then raise exception 'Não há caixa aberto'; end if;
 v_signed:=case when p_type='withdrawal' then -p_amount_cents else p_amount_cents end;
 insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,note,actor_member_id) values(v_session,m.barbershop_id,p_unit_id,p_type,v_signed,nullif(trim(coalesce(p_note,'')),''),m.member_id);
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.barberium_staff_close_cash(p_unit_id uuid,p_counted_cents int,p_justification text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; s record; expected int; diff int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'close_cash') then raise exception 'Sem permissão para fechar caixa'; end if;
 select * into s from public.cash_sessions where unit_id=p_unit_id and barbershop_id=m.barbershop_id and status='open' for update; if s.id is null then raise exception 'Não há caixa aberto'; end if;
 select s.opening_balance_cents+coalesce(sum(amount_cents),0) into expected from public.cash_movements where cash_session_id=s.id; diff:=p_counted_cents-expected;
 if diff<>0 and trim(coalesce(p_justification,''))='' then raise exception 'Informe a justificativa da diferença'; end if;
 update public.cash_sessions set status='closed',expected_closing_cents=expected,counted_closing_cents=p_counted_cents,difference_cents=diff,closing_justification=nullif(trim(coalesce(p_justification,'')),''),closed_at=now(),closed_by_member_id=m.member_id where id=s.id;
 return jsonb_build_object('ok',true,'expected_cents',expected,'counted_cents',p_counted_cents,'difference_cents',diff);
end $$;

-- Comissões normais.
create or replace function public.barberium_staff_commission_config()
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 return jsonb_build_object('professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'default_percent',coalesce(cp.default_percent,0),'settlement_cycle',coalesce(cp.settlement_cycle,'monthly'),'basis',coalesce(cp.basis,'gross'),'services',coalesce((select jsonb_agg(jsonb_build_object('service_id',s.id,'service',s.name,'mode',coalesce(csr.mode,'percent'),'percent',csr.percent) order by s.sort_order,s.name) from public.services s left join public.commission_service_rules csr on csr.service_id=s.id and csr.professional_id=p.id where s.barbershop_id=m.barbershop_id and s.is_active),'[]'::jsonb)) order by p.sort_order,p.name) from public.professionals p left join public.commission_profiles cp on cp.professional_id=p.id where p.barbershop_id=m.barbershop_id and p.is_active),'[]'::jsonb));
end $$;

create or replace function public.barberium_staff_save_commission_config(p_professional_id uuid,p_default_percent numeric,p_settlement_cycle text,p_basis text,p_service_rules jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; r jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if p_default_percent<0 or p_default_percent>100 or p_settlement_cycle not in ('weekly','biweekly','monthly') or p_basis not in ('gross','net') then raise exception 'Configuração inválida'; end if;
 insert into public.commission_profiles(professional_id,barbershop_id,default_percent,settlement_cycle,basis) values(p_professional_id,m.barbershop_id,p_default_percent,p_settlement_cycle,p_basis) on conflict(professional_id) do update set default_percent=excluded.default_percent,settlement_cycle=excluded.settlement_cycle,basis=excluded.basis,updated_at=now();
 for r in select * from jsonb_array_elements(coalesce(p_service_rules,'[]'::jsonb)) loop
   insert into public.commission_service_rules(professional_id,service_id,mode,percent) values(p_professional_id,(r->>'service_id')::uuid,coalesce(r->>'mode','percent'),nullif(r->>'percent','')::numeric)
   on conflict(professional_id,service_id) do update set mode=excluded.mode,percent=excluded.percent,updated_at=now();
 end loop;
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.barberium_staff_my_commissions(p_start date default (current_date-interval '90 days')::date,p_end date default current_date)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; prof uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 prof:=m.professional_id; if m.role in ('owner','admin') and prof is null then return jsonb_build_object('entries','[]'::jsonb,'settlements','[]'::jsonb,'open_cents',0); end if;
 return jsonb_build_object('open_cents',coalesce((select sum(amount_cents) from public.commission_entries where professional_id=prof and status='open'),0),'entries',coalesce((select jsonb_agg(jsonb_build_object('id',ce.id,'amount_cents',ce.amount_cents,'description',ce.description,'created_at',ce.created_at,'status',ce.status) order by ce.created_at desc) from public.commission_entries ce where ce.professional_id=prof and ce.created_at::date between p_start and p_end),'[]'::jsonb),'settlements',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'period_start',cs.period_start,'period_end',cs.period_end,'total_cents',cs.total_cents,'paid_cents',cs.paid_cents,'status',cs.status) order by cs.period_end desc) from public.commission_settlements cs where cs.professional_id=prof),'[]'::jsonb));
end $$;

-- Planos / assinaturas / pacotes.
create or replace function public.barberium_staff_membership_plans()
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'description',p.description,'plan_type',p.plan_type,'acquisition_mode',p.acquisition_mode,'public_visible',p.public_visible,'is_active',p.is_active,'version_no',p.current_version_no,'version_id',v.id,'price_cents',v.price_cents,'rules',v.rules,'active_clients',(select count(*) from public.customer_memberships cm where cm.plan_id=p.id and cm.status in ('active','paused','overdue','pending')),'benefits',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'service_id',b.service_id,'service',s.name,'quantity',b.quantity,'unlimited',b.unlimited,'extra_discount_percent',b.extra_discount_percent,'min_days_between',b.min_days_between,'max_per_week',b.max_per_week,'max_per_month',b.max_per_month,'rules',b.rules) order by b.sort_order,s.name) from public.membership_plan_benefits b join public.services s on s.id=b.service_id where b.plan_version_id=v.id),'[]'::jsonb),'units',coalesce((select jsonb_agg(u.id) from public.membership_plan_units pu join public.units u on u.id=pu.unit_id where pu.plan_version_id=v.id),'[]'::jsonb)) order by p.is_active desc,p.name)
 from public.membership_plans p join public.membership_plan_versions v on v.plan_id=p.id and v.version_no=p.current_version_no where p.barbershop_id=m.barbershop_id),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_save_membership_plan(p_plan_id uuid,p_name text,p_description text,p_plan_type text,p_price_cents int,p_acquisition_mode text,p_public_visible boolean,p_is_active boolean,p_rules jsonb,p_benefits jsonb,p_unit_ids uuid[] default '{}'::uuid[])
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_plan uuid; v_ver int; v_ver_id uuid; b jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if trim(coalesce(p_name,''))='' or p_plan_type not in ('subscription','package') or p_price_cents<0 or p_acquisition_mode not in ('team','site','both') then raise exception 'Dados do plano inválidos'; end if;
 if jsonb_array_length(coalesce(p_benefits,'[]'::jsonb))=0 then raise exception 'Adicione ao menos um benefício'; end if;
 if p_plan_id is null then
   insert into public.membership_plans(barbershop_id,name,description,plan_type,acquisition_mode,public_visible,is_active,current_version_no) values(m.barbershop_id,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_plan_type,p_acquisition_mode,coalesce(p_public_visible,false),coalesce(p_is_active,true),1) returning id,current_version_no into v_plan,v_ver;
 else
   select id,current_version_no+1 into v_plan,v_ver from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id; if v_plan is null then raise exception 'Plano inválido'; end if;
   update public.membership_plans set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),plan_type=p_plan_type,acquisition_mode=p_acquisition_mode,public_visible=coalesce(p_public_visible,false),is_active=coalesce(p_is_active,true),current_version_no=v_ver,updated_at=now() where id=v_plan;
 end if;
 insert into public.membership_plan_versions(plan_id,version_no,price_cents,rules) values(v_plan,v_ver,p_price_cents,coalesce(p_rules,'{}'::jsonb)) returning id into v_ver_id;
 for b in select * from jsonb_array_elements(p_benefits) loop
   if not exists(select 1 from public.services s where s.id=(b->>'service_id')::uuid and s.barbershop_id=m.barbershop_id) then raise exception 'Serviço inválido no benefício'; end if;
   insert into public.membership_plan_benefits(plan_version_id,service_id,quantity,unlimited,extra_discount_percent,min_days_between,max_per_week,max_per_month,rules,sort_order)
   values(v_ver_id,(b->>'service_id')::uuid,case when coalesce((b->>'unlimited')::boolean,false) then null else greatest(1,coalesce((b->>'quantity')::int,1)) end,coalesce((b->>'unlimited')::boolean,false),coalesce((b->>'extra_discount_percent')::numeric,0),nullif(b->>'min_days_between','')::int,nullif(b->>'max_per_week','')::int,nullif(b->>'max_per_month','')::int,coalesce(b->'rules','{}'::jsonb),coalesce((b->>'sort_order')::int,0));
 end loop;
 if coalesce(p_rules->>'unit_scope','all')='selected' then
   insert into public.membership_plan_units(plan_version_id,unit_id) select v_ver_id,u from unnest(coalesce(p_unit_ids,'{}'::uuid[])) u where exists(select 1 from public.units x where x.id=u and x.barbershop_id=m.barbershop_id);
 end if;
 return jsonb_build_object('ok',true,'plan_id',v_plan,'version_id',v_ver_id,'version_no',v_ver);
end $$;

create or replace function barberium.release_membership_credits(p_membership_id uuid,p_cycle_id uuid)
returns void language plpgsql security definer set search_path to 'public','barberium','pg_temp' as $$
declare cm record; v record; expiry date; credit_validity text; carry int;
begin
 select cm.*,pv.rules from public.customer_memberships cm join public.membership_plan_versions pv on pv.id=cm.plan_version_id where cm.id=p_membership_id into cm; if cm.id is null then return; end if;
 for v in select b.* from public.membership_plan_benefits b where b.plan_version_id=cm.plan_version_id loop
   credit_validity:=coalesce(cm.rules->>'credit_validity',case when cm.plan_type='subscription' then 'cycle_end' else 'no_expiry' end);
   expiry:=null;
   if cm.plan_type='subscription' then
     if credit_validity='cycle_end' then select cycle_end into expiry from public.membership_cycles where id=p_cycle_id;
     elsif credit_validity='carry_cycles' then carry:=greatest(1,coalesce((cm.rules->>'carry_cycles')::int,1)); select (cycle_end + (carry||' months')::interval)::date into expiry from public.membership_cycles where id=p_cycle_id;
     end if;
   else
     if credit_validity='fixed_days' then expiry:=coalesce(cm.started_at::date,current_date)+greatest(1,coalesce((cm.rules->>'fixed_validity_days')::int,30)); else expiry:=cm.valid_until; end if;
   end if;
   insert into public.membership_credit_buckets(membership_id,cycle_id,benefit_id,total_credits,expires_on) values(cm.id,p_cycle_id,v.id,case when v.unlimited then null else v.quantity end,expiry);
 end loop;
 if p_cycle_id is not null then update public.membership_cycles set credits_released=true where id=p_cycle_id; end if;
end $$;

create or replace function public.barberium_staff_assign_membership(p_customer_id uuid,p_plan_id uuid,p_unit_id uuid,p_start_date date default current_date,p_mark_paid boolean default false,p_payment_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; p record; v record; cm_id uuid; cyc_id uuid; cycle_start date; cycle_end date; due date; grace int; first_mode text; amount int; validity text; valid_until date;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if;
 select * into p from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id and is_active; if p.id is null then raise exception 'Plano inválido'; end if;
 select * into v from public.membership_plan_versions where plan_id=p.id and version_no=p.current_version_no;
 if p.plan_type='subscription' then
   cycle_start:=p_start_date;
   if coalesce(v.rules->>'cycle_mode','anniversary')='calendar' then cycle_start:=date_trunc('month',p_start_date)::date; cycle_end:=(date_trunc('month',p_start_date)+interval '1 month - 1 day')::date; else cycle_end:=(p_start_date+interval '1 month - 1 day')::date; end if;
   first_mode:=coalesce(v.rules->>'first_cycle_mode','full'); amount:=v.price_cents;
   if first_mode='next_cycle' and coalesce(v.rules->>'cycle_mode','anniversary')='calendar' then cycle_start:=(date_trunc('month',p_start_date)+interval '1 month')::date; cycle_end:=(cycle_start+interval '1 month - 1 day')::date; end if;
   if first_mode='proportional' and coalesce(v.rules->>'cycle_mode','anniversary')='calendar' and cycle_start<p_start_date then amount:=round(v.price_cents*((cycle_end-p_start_date+1)::numeric/(cycle_end-cycle_start+1)))::int; cycle_start:=p_start_date; end if;
   due:=p_start_date; grace:=greatest(0,coalesce((v.rules->>'grace_days')::int,0));
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,current_cycle_start,current_cycle_end,created_by_member_id)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,case when p_mark_paid then 'active' else 'pending' end,case when p_mark_paid then now() end,cycle_start,cycle_end,m.member_id) returning id into cm_id;
   insert into public.membership_cycles(membership_id,cycle_start,cycle_end,due_date,grace_until,amount_cents,status,credits_released,paid_at,is_first_cycle) values(cm_id,cycle_start,cycle_end,due,due+grace,amount,case when p_mark_paid then 'paid' else 'pending' end,false,case when p_mark_paid then now() end,true) returning id into cyc_id;
   if p_mark_paid then
     insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id) values(cm_id,cyc_id,amount,p_payment_method,m.member_id);
     perform barberium.release_membership_credits(cm_id,cyc_id);
   end if;
 else
   validity:=coalesce(v.rules->>'credit_validity','no_expiry'); valid_until:=case when validity='fixed_days' then p_start_date+greatest(1,coalesce((v.rules->>'fixed_validity_days')::int,30)) else null end;
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,valid_until,created_by_member_id)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,case when p_mark_paid then 'active' else 'pending' end,case when p_mark_paid then now() end,valid_until,m.member_id) returning id into cm_id;
   if p_mark_paid then insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id) values(cm_id,v.price_cents,p_payment_method,m.member_id); perform barberium.release_membership_credits(cm_id,null); end if;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm_id,'created',jsonb_build_object('paid',p_mark_paid,'plan_version_id',v.id),m.member_id);
 return jsonb_build_object('ok',true,'membership_id',cm_id,'cycle_id',cyc_id);
exception when unique_violation then raise exception 'Cliente já possui um plano deste tipo ativo'; end $$;

create or replace function public.barberium_staff_record_membership_payment(p_membership_id uuid,p_cycle_id uuid default null,p_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; cm record; cyc record; amount int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'confirm_membership_payment') then raise exception 'Sem permissão para confirmar pagamento de plano'; end if;
 select cm.*,pv.price_cents from public.customer_memberships cm join public.membership_plan_versions pv on pv.id=cm.plan_version_id where cm.id=p_membership_id and cm.barbershop_id=m.barbershop_id for update into cm; if cm.id is null then raise exception 'Plano do cliente inválido'; end if;
 if cm.plan_type='subscription' then
   select * into cyc from public.membership_cycles where id=coalesce(p_cycle_id,(select id from public.membership_cycles where membership_id=cm.id and status in ('pending','overdue') order by due_date limit 1)) and membership_id=cm.id for update; if cyc.id is null then raise exception 'Mensalidade pendente não encontrada'; end if;
   amount:=cyc.amount_cents; update public.membership_cycles set status='paid',paid_at=now() where id=cyc.id; insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id) values(cm.id,cyc.id,amount,p_method,m.member_id);
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),current_cycle_start=cyc.cycle_start,current_cycle_end=cyc.cycle_end,updated_at=now() where id=cm.id;
   if not cyc.credits_released then perform barberium.release_membership_credits(cm.id,cyc.id); end if;
 else
   if exists(select 1 from public.membership_payments where membership_id=cm.id) then raise exception 'Pacote já foi pago'; end if; amount:=cm.price_cents; insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id) values(cm.id,amount,p_method,m.member_id); update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),updated_at=now() where id=cm.id; perform barberium.release_membership_credits(cm.id,null);
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm.id,'payment_confirmed',jsonb_build_object('amount_cents',amount,'method',p_method),m.member_id);
 return jsonb_build_object('ok',true,'amount_cents',amount);
end $$;

create or replace function public.barberium_staff_customer_memberships(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 if m.role='barber' then raise exception 'Acesso restrito ao ADM'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',cm.id,'plan_id',cm.plan_id,'name',p.name,'plan_type',cm.plan_type,'status',cm.status,'price_cents',v.price_cents,'started_at',cm.started_at,'valid_until',cm.valid_until,'current_cycle_start',cm.current_cycle_start,'current_cycle_end',cm.current_cycle_end,'rules',v.rules,'credits',coalesce((select jsonb_agg(jsonb_build_object('bucket_id',b.id,'benefit_id',b.benefit_id,'service_id',pb.service_id,'service',s.name,'total',b.total_credits,'used',b.used_credits,'reserved',b.reserved_credits,'available',case when b.total_credits is null then null else greatest(0,b.total_credits-b.used_credits-b.reserved_credits) end,'expires_on',b.expires_on,'unlimited',pb.unlimited) order by s.name) from public.membership_credit_buckets b join public.membership_plan_benefits pb on pb.id=b.benefit_id join public.services s on s.id=pb.service_id where b.membership_id=cm.id),'[]'::jsonb),'cycles',coalesce((select jsonb_agg(jsonb_build_object('id',mc.id,'start',mc.cycle_start,'end',mc.cycle_end,'due_date',mc.due_date,'grace_until',mc.grace_until,'amount_cents',mc.amount_cents,'status',mc.status,'paid_at',mc.paid_at) order by mc.cycle_start desc) from public.membership_cycles mc where mc.membership_id=cm.id),'[]'::jsonb),'events',coalesce((select jsonb_agg(jsonb_build_object('type',me.event_type,'details',me.details,'created_at',me.created_at) order by me.created_at desc) from public.membership_events me where me.membership_id=cm.id),'[]'::jsonb)) order by cm.created_at desc)
 from public.customer_memberships cm join public.membership_plans p on p.id=cm.plan_id join public.membership_plan_versions v on v.id=cm.plan_version_id where cm.customer_id=p_customer_id and cm.barbershop_id=m.barbershop_id),'[]'::jsonb);
end $$;

-- Planos visíveis ao cliente.
create or replace function public.barberium_public_membership_plans(p_barbershop_slug text,p_unit_slug text)
returns jsonb language sql stable security definer set search_path to 'public','barberium','pg_temp' as $$
with b as(select id from public.barbershops where slug=p_barbershop_slug and status='active'),u as(select u.id from public.units u join b on b.id=u.barbershop_id where u.slug=p_unit_slug and u.is_active)
select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'description',p.description,'plan_type',p.plan_type,'price_cents',v.price_cents,'rules',v.rules,'benefits',coalesce((select jsonb_agg(jsonb_build_object('service_id',pb.service_id,'service',s.name,'quantity',pb.quantity,'unlimited',pb.unlimited,'extra_discount_percent',pb.extra_discount_percent,'min_days_between',pb.min_days_between,'max_per_week',pb.max_per_week,'max_per_month',pb.max_per_month) order by pb.sort_order,s.name) from public.membership_plan_benefits pb join public.services s on s.id=pb.service_id where pb.plan_version_id=v.id),'[]'::jsonb)) order by p.name),'[]'::jsonb)
from public.membership_plans p join b on b.id=p.barbershop_id join public.membership_plan_versions v on v.plan_id=p.id and v.version_no=p.current_version_no
where p.is_active and p.public_visible and p.acquisition_mode in ('site','both') and (coalesce(v.rules->>'unit_scope','all')='all' or (v.rules->>'unit_scope'='origin') or exists(select 1 from public.membership_plan_units pu join u on u.id=pu.unit_id where pu.plan_version_id=v.id));
$$;

create or replace function public.barberium_request_membership(p_barbershop_slug text,p_access_token text,p_plan_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
declare v_customer uuid; v_b uuid; v_plan record; v_id uuid;
begin
 select id into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1; if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
 select * into v_plan from public.membership_plans where id=p_plan_id and barbershop_id=v_b and is_active and public_visible and acquisition_mode in ('site','both'); if v_plan.id is null then raise exception 'PLAN_NOT_AVAILABLE'; end if;
 if exists(select 1 from public.customer_memberships where customer_id=v_customer and plan_type=v_plan.plan_type and status in ('pending','active','paused','overdue')) then raise exception 'Você já possui um plano deste tipo em andamento'; end if;
 insert into public.membership_requests(barbershop_id,customer_id,plan_id) values(v_b,v_customer,v_plan.id) on conflict(customer_id,plan_id) where status='pending' do update set created_at=now() returning id into v_id;
 return jsonb_build_object('ok',true,'request_id',v_id);
end $$;

create or replace function public.barberium_staff_membership_requests()
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'customer_id',c.id,'customer',c.full_name,'phone',c.phone_e164,'plan_id',p.id,'plan',p.name,'plan_type',p.plan_type,'created_at',r.created_at) order by r.created_at) from public.membership_requests r join public.customers c on c.id=r.customer_id join public.membership_plans p on p.id=r.plan_id where r.barbershop_id=m.barbershop_id and r.status='pending'),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_decide_membership_request(p_request_id uuid,p_approve boolean,p_unit_id uuid,p_mark_paid boolean default false,p_payment_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; r record; result jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 select * into r from public.membership_requests where id=p_request_id and barbershop_id=m.barbershop_id and status='pending' for update; if r.id is null then raise exception 'Solicitação inválida'; end if;
 if p_approve then result:=public.barberium_staff_assign_membership(r.customer_id,r.plan_id,p_unit_id,current_date,p_mark_paid,p_payment_method); update public.membership_requests set status='approved',decided_at=now(),decided_by_member_id=m.member_id where id=r.id; else update public.membership_requests set status='rejected',decided_at=now(),decided_by_member_id=m.member_id where id=r.id; result:=jsonb_build_object('ok',true); end if;
 return result;
end $$;

-- Portal passa a incluir planos do cliente.
create or replace function public.barberium_get_customer_portal(p_barbershop_slug text,p_access_token text)
returns jsonb language sql stable security definer set search_path to 'public','barberium','extensions','pg_temp' as $$
with b as(select id from public.barbershops where slug=p_barbershop_slug and status='active'),t as(select t.customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join b on b.id=c.barbershop_id where t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1),c as(select c.* from public.customers c join t on t.customer_id=c.id)
select jsonb_build_object(
'customer',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'phone_e164',c.phone_e164,'birthday',c.birthday) from c),
'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'status',a.status,'starts_at',a.starts_at,'ends_at',a.ends_at,'total_price_cents',a.total_price_cents,'service',jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'duration_label',s.duration_label),'professional',jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path),'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',aa.price_cents,'duration_min',aa.duration_min)) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb)) order by a.starts_at desc) from public.appointments a join c on c.id=a.customer_id join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id),'[]'::jsonb),
'memberships',coalesce((select jsonb_agg(jsonb_build_object('id',cm.id,'plan_id',cm.plan_id,'name',mp.name,'plan_type',cm.plan_type,'status',cm.status,'price_cents',pv.price_cents,'started_at',cm.started_at,'valid_until',cm.valid_until,'current_cycle_start',cm.current_cycle_start,'current_cycle_end',cm.current_cycle_end,'rules',pv.rules,'credits',coalesce((select jsonb_agg(jsonb_build_object('service_id',pb.service_id,'service',s.name,'total',cb.total_credits,'used',cb.used_credits,'reserved',cb.reserved_credits,'available',case when cb.total_credits is null then null else greatest(0,cb.total_credits-cb.used_credits-cb.reserved_credits) end,'expires_on',cb.expires_on,'unlimited',pb.unlimited) order by s.name) from public.membership_credit_buckets cb join public.membership_plan_benefits pb on pb.id=cb.benefit_id join public.services s on s.id=pb.service_id where cb.membership_id=cm.id),'[]'::jsonb),'cycles',coalesce((select jsonb_agg(jsonb_build_object('id',mc.id,'start',mc.cycle_start,'end',mc.cycle_end,'due_date',mc.due_date,'grace_until',mc.grace_until,'amount_cents',mc.amount_cents,'status',mc.status,'paid_at',mc.paid_at) order by mc.cycle_start desc) from public.membership_cycles mc where mc.membership_id=cm.id),'[]'::jsonb)) order by cm.created_at desc) from public.customer_memberships cm join c on c.id=cm.customer_id join public.membership_plans mp on mp.id=cm.plan_id join public.membership_plan_versions pv on pv.id=cm.plan_version_id),'[]'::jsonb),
'membership_requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'plan_id',r.plan_id,'plan',p.name,'status',r.status,'created_at',r.created_at) order by r.created_at desc) from public.membership_requests r join c on c.id=r.customer_id join public.membership_plans p on p.id=r.plan_id),'[]'::jsonb)
);
$$;

-- Finalização financeira do atendimento.
create or replace function public.barberium_staff_complete_appointment(p_appointment_id uuid,p_payments jsonb default '[]'::jsonb,p_pending_cents int default 0,p_due_date date default null,p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; a record; pay jsonb; sum_paid int:=0; due_total int; fee int; provider uuid; meth text; amount int; tender int; chg int; inst int; v_session uuid; base_commission int; pct numeric; mode text; basis text; commission_amt int; covered int:=0;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update; if a.id is null then raise exception 'Atendimento inválido'; end if; if a.status<>'confirmed' then raise exception 'Atendimento já finalizado'; end if; if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem permissão'; end if; if m.role='barber' and not barberium.permission_enabled(perms,'mark_completed') then raise exception 'Sem permissão para concluir'; end if;
 if p_pending_cents<0 then raise exception 'Pendência inválida'; end if; if p_pending_cents>0 and m.role='barber' and not barberium.permission_enabled(perms,'leave_payment_pending') then raise exception 'Sem permissão para deixar pagamento pendente'; end if;
 select coalesce(sum(coverage_cents),0) into covered from public.appointment_membership_uses where appointment_id=a.id and status='reserved';
 due_total:=greatest(0,a.total_price_cents-covered);
 for pay in select * from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) loop
   meth:=pay->>'method'; amount:=coalesce((pay->>'amount_cents')::int,0); if meth not in ('pix','cash','debit','credit') or amount<=0 then raise exception 'Pagamento inválido'; end if;
   provider:=nullif(pay->>'provider_id','')::uuid; inst:=coalesce(nullif(pay->>'installments','')::int,1); tender:=coalesce(nullif(pay->>'tendered_cents','')::int,amount); chg:=case when meth='cash' then greatest(0,tender-amount) else 0 end; fee:=barberium.payment_fee_cents(provider,meth,inst,amount);
   insert into public.appointment_payments(barbershop_id,unit_id,appointment_id,method,amount_cents,tendered_cents,change_cents,provider_id,installments,fee_cents,actor_member_id,note) values(m.barbershop_id,a.unit_id,a.id,meth,amount,case when meth='cash' then tender end,chg,provider,case when meth='credit' then inst end,fee,m.member_id,pay->>'note');
   if meth='cash' then select id into v_session from public.cash_sessions where unit_id=a.unit_id and status='open' order by opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,a.unit_id,'payment',amount,'appointment',a.id,'Recebimento de atendimento',m.member_id); end if; end if;
   sum_paid:=sum_paid+amount;
 end loop;
 if sum_paid+p_pending_cents<>due_total then raise exception 'A soma dos pagamentos e da pendência deve ser igual ao valor a receber'; end if;
 if p_pending_cents>0 then insert into public.appointment_receivables(appointment_id,barbershop_id,unit_id,original_due_cents,paid_cents,status,due_date,note) values(a.id,m.barbershop_id,a.unit_id,p_pending_cents,0,'open',p_due_date,nullif(trim(coalesce(p_note,'')),'')); end if;
 update public.appointments set status='completed',updated_at=now() where id=a.id;
 update public.appointment_membership_uses set status='consumed',consumed_at=now() where appointment_id=a.id and status='reserved';
 update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-u.qty),used_credits=b.used_credits+u.qty from (select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where appointment_id=a.id and status='consumed' and bucket_id is not null group by bucket_id) u where b.id=u.bucket_id;
 select coalesce(csr.mode,'percent'),coalesce(csr.percent,cp.default_percent,0),coalesce(cp.basis,(select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross') into mode,pct,basis from public.commission_profiles cp left join public.commission_service_rules csr on csr.professional_id=cp.professional_id and csr.service_id=a.service_id where cp.professional_id=a.professional_id;
 if mode is null then mode:='percent'; pct:=0; end if;
 if mode<>'none' and coalesce(pct,0)>0 then
   base_commission:=sum_paid; if basis='net' then base_commission:=sum_paid-coalesce((select sum(fee_cents) from public.appointment_payments where appointment_id=a.id),0); end if; commission_amt:=round(base_commission*(pct/100.0))::int;
   if commission_amt<>0 then insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents) values(m.barbershop_id,a.unit_id,a.professional_id,a.id,'service',a.service_id,'Comissão de atendimento',base_commission,pct,commission_amt); end if;
 end if;
 insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from','confirmed','to','completed','paid_cents',sum_paid,'pending_cents',p_pending_cents,'membership_covered_cents',covered));
 return jsonb_build_object('ok',true,'appointment_id',a.id,'paid_cents',sum_paid,'pending_cents',p_pending_cents,'membership_covered_cents',covered,'due_total_cents',due_total);
end $$;

create or replace function public.barberium_staff_record_receivable_payment(p_appointment_id uuid,p_payments jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; r record; a record; pay jsonb; sum_paid int:=0; amount int; meth text; provider uuid; inst int; fee int; remaining int; v_session uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 select * into r from public.appointment_receivables where appointment_id=p_appointment_id and barbershop_id=m.barbershop_id for update; if r.appointment_id is null or r.status='paid' then raise exception 'Pendência não encontrada'; end if; select * into a from public.appointments where id=p_appointment_id;
 for pay in select * from jsonb_array_elements(p_payments) loop meth:=pay->>'method'; amount:=coalesce((pay->>'amount_cents')::int,0); provider:=nullif(pay->>'provider_id','')::uuid; inst:=coalesce(nullif(pay->>'installments','')::int,1); if amount<=0 then raise exception 'Pagamento inválido'; end if; fee:=barberium.payment_fee_cents(provider,meth,inst,amount); insert into public.appointment_payments(barbershop_id,unit_id,appointment_id,method,amount_cents,provider_id,installments,fee_cents,actor_member_id) values(m.barbershop_id,r.unit_id,p_appointment_id,meth,amount,provider,case when meth='credit' then inst end,fee,m.member_id); if meth='cash' then select id into v_session from public.cash_sessions where unit_id=r.unit_id and status='open' order by opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,r.unit_id,'payment',amount,'appointment',p_appointment_id,'Recebimento de pendência',m.member_id); end if; end if; sum_paid:=sum_paid+amount; end loop;
 remaining:=r.original_due_cents-r.paid_cents; if sum_paid<=0 or sum_paid>remaining then raise exception 'Valor inválido'; end if; update public.appointment_receivables set paid_cents=paid_cents+sum_paid,status=case when paid_cents+sum_paid>=original_due_cents then 'paid' else 'partial' end,updated_at=now() where appointment_id=p_appointment_id;
 return jsonb_build_object('ok',true,'received_cents',sum_paid,'remaining_cents',remaining-sum_paid);
end $$;

-- Financeiro / DRE simplificado.
create or replace function public.barberium_staff_finance_overview(p_start date,p_end date,p_unit_id uuid default null,p_basis text default 'cash')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; gross int; fees int; expenses_paid int; commissions int; receivables int; target int; result int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Financeiro geral restrito ao ADM'; end if; if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
 if p_basis='cash' then
   select coalesce(sum(ap.amount_cents),0),coalesce(sum(ap.fee_cents),0) into gross,fees from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id);
 else
   select coalesce(sum(a.total_price_cents),0),coalesce(sum((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id)),0) into gross,fees from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id);
 end if;
 select coalesce(sum(e.amount_cents),0) into expenses_paid from public.expenses e where e.barbershop_id=m.barbershop_id and e.status='paid' and (case when p_basis='cash' then coalesce(e.paid_at::date,e.due_date) else e.due_date end) between p_start and p_end and (p_unit_id is null or e.unit_id=p_unit_id);
 select coalesce(sum(ce.amount_cents),0) into commissions from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into receivables from public.appointment_receivables ar where ar.barbershop_id=m.barbershop_id and ar.status<>'paid' and (p_unit_id is null or ar.unit_id=p_unit_id);
 select revenue_target_cents into target from public.financial_goals fg where fg.barbershop_id=m.barbershop_id and fg.unit_id is not distinct from p_unit_id and fg.month=date_trunc('month',p_end)::date;
 result:=gross-fees-commissions-expenses_paid;
 return jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'gross_cents',gross,'fees_cents',fees,'net_received_cents',gross-fees,'expenses_cents',expenses_paid,'commissions_cents',commissions,'operating_result_cents',result,'receivables_cents',receivables,'revenue_target_cents',target,'target_progress_percent',case when coalesce(target,0)>0 then round(gross*100.0/target,1) else null end,'by_method',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_cents',amount) order by amount desc) from (select method,sum(amount_cents)::int amount from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id) group by method) q),'[]'::jsonb),'by_provider',coalesce((select jsonb_agg(jsonb_build_object('provider',provider,'gross_cents',gross,'fees_cents',fee,'net_cents',gross-fee) order by gross desc) from (select coalesce(pp.name,'Sem provedor') provider,sum(ap.amount_cents)::int gross,sum(ap.fee_cents)::int fee from public.appointment_payments ap left join public.payment_providers pp on pp.id=ap.provider_id where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id) group by coalesce(pp.name,'Sem provedor')) q),'[]'::jsonb));
end $$;

create or replace function public.barberium_staff_save_financial_goal(p_unit_id uuid,p_month date,p_revenue_target_cents int,p_net_target_cents int default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; normalized date; v_id uuid;
begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; normalized:=date_trunc('month',p_month)::date; select id into v_id from public.financial_goals where barbershop_id=m.barbershop_id and unit_id is not distinct from p_unit_id and month=normalized; if v_id is null then insert into public.financial_goals(barbershop_id,unit_id,month,revenue_target_cents,net_target_cents) values(m.barbershop_id,p_unit_id,normalized,p_revenue_target_cents,p_net_target_cents) returning id into v_id; else update public.financial_goals set revenue_target_cents=p_revenue_target_cents,net_target_cents=p_net_target_cents,updated_at=now() where id=v_id; end if; return jsonb_build_object('ok',true,'id',v_id); end $$;

-- O status "Concluído" passa pelo fluxo financeiro; demais status continuam aqui.
create or replace function public.barberium_staff_set_appointment_status(p_appointment_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; a public.appointments%rowtype; rule text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_status not in ('confirmed','completed','cancelled','no_show') then raise exception 'Status inválido'; end if;
  if p_status='completed' then raise exception 'Use a etapa de pagamento para concluir o atendimento'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  select * into a from public.appointments where id=p_appointment_id for update; if a.id is null or a.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if;
  if m.role='barber' then if a.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if; if p_status='no_show' and not barberium.permission_enabled(perms,'mark_no_show') then raise exception 'Sem permissão para marcar falta'; end if; if p_status='cancelled' and not barberium.permission_enabled(perms,'cancel_appointment') then raise exception 'Sem permissão para cancelar'; end if; if p_status='confirmed' then raise exception 'Somente o ADM pode restaurar para confirmado'; end if; if a.status<>'confirmed' then raise exception 'Este atendimento já foi finalizado'; end if; end if;
  if a.status=p_status then return jsonb_build_object('ok',true,'status',a.status); end if;
  if p_status='confirmed' and exists(select 1 from public.appointment_payments where appointment_id=a.id) then raise exception 'Atendimento com movimentação financeira não pode ser restaurado diretamente'; end if;
  if p_status='no_show' then
    for rule in select coalesce(v.rules->>'no_show_rule','keep') from public.appointment_membership_uses u join public.customer_memberships cm on cm.id=u.membership_id join public.membership_plan_versions v on v.id=cm.plan_version_id where u.appointment_id=a.id and u.status='reserved' loop
      if rule='lose' then update public.appointment_membership_uses set status='forfeited',consumed_at=now() where appointment_id=a.id and status='reserved';
      elsif rule='admin' then update public.appointment_membership_uses set status='decision_required' where appointment_id=a.id and status='reserved';
      else update public.appointment_membership_uses set status='released' where appointment_id=a.id and status='reserved'; end if;
    end loop;
    update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-q.qty),used_credits=b.used_credits+q.used from (select bucket_id,sum(credit_qty)::int qty,sum(case when status='forfeited' then credit_qty else 0 end)::int used from public.appointment_membership_uses where appointment_id=a.id and bucket_id is not null and status in ('forfeited','released') group by bucket_id) q where b.id=q.bucket_id;
  elsif p_status='cancelled' then
    update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-q.qty) from (select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where appointment_id=a.id and status='reserved' and bucket_id is not null group by bucket_id) q where b.id=q.bucket_id;
    update public.appointment_membership_uses set status='released' where appointment_id=a.id and status='reserved';
  end if;
  begin update public.appointments set status=p_status,cancelled_at=case when p_status='cancelled' then now() else null end,updated_at=now() where id=a.id; exception when exclusion_violation then raise exception 'Horário já foi ocupado por outro atendimento'; end;
  insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from',a.status,'to',p_status));
  return jsonb_build_object('ok',true,'appointment_id',a.id,'status',p_status);
end $$;

-- Enriquecer detalhe do atendimento com situação financeira e créditos reservados.
create or replace function public.barberium_staff_appointment_finance(p_appointment_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; a record;
begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id; if a.id is null then raise exception 'Atendimento inválido'; end if; if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if; return jsonb_build_object('total_price_cents',a.total_price_cents,'membership_covered_cents',coalesce((select sum(coverage_cents) from public.appointment_membership_uses where appointment_id=a.id and status in ('reserved','consumed')),0),'paid_cents',coalesce((select sum(amount_cents) from public.appointment_payments where appointment_id=a.id),0),'fees_cents',coalesce((select sum(fee_cents) from public.appointment_payments where appointment_id=a.id),0),'receivable',(select jsonb_build_object('original_due_cents',r.original_due_cents,'paid_cents',r.paid_cents,'remaining_cents',r.original_due_cents-r.paid_cents,'status',r.status,'due_date',r.due_date,'note',r.note) from public.appointment_receivables r where r.appointment_id=a.id),'uses',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'status',u.status,'coverage_cents',u.coverage_cents,'service',s.name,'plan',p.name) order by u.created_at) from public.appointment_membership_uses u join public.services s on s.id=u.covered_service_id join public.customer_memberships cm on cm.id=u.membership_id join public.membership_plans p on p.id=cm.plan_id where u.appointment_id=a.id),'[]'::jsonb)); end $$;

-- Grants para RPCs expostas.
grant execute on function public.barberium_staff_finance_settings() to authenticated;
grant execute on function public.barberium_staff_save_finance_settings(uuid,boolean,text,text,jsonb) to authenticated;
grant execute on function public.barberium_staff_save_payment_provider(uuid,text,boolean,jsonb) to authenticated;
grant execute on function public.barberium_staff_expense_categories() to authenticated;
grant execute on function public.barberium_staff_save_expense_category(uuid,text,boolean) to authenticated;
grant execute on function public.barberium_staff_expenses(date,date,uuid) to authenticated;
grant execute on function public.barberium_staff_create_expense(uuid,uuid,text,int,date,text,text,boolean,text) to authenticated;
grant execute on function public.barberium_staff_cash_status(uuid) to authenticated;
grant execute on function public.barberium_staff_open_cash(uuid,int) to authenticated;
grant execute on function public.barberium_staff_cash_movement(uuid,text,int,text) to authenticated;
grant execute on function public.barberium_staff_close_cash(uuid,int,text) to authenticated;
grant execute on function public.barberium_staff_commission_config() to authenticated;
grant execute on function public.barberium_staff_save_commission_config(uuid,numeric,text,text,jsonb) to authenticated;
grant execute on function public.barberium_staff_my_commissions(date,date) to authenticated;
grant execute on function public.barberium_staff_membership_plans() to authenticated;
grant execute on function public.barberium_staff_save_membership_plan(uuid,text,text,text,int,text,boolean,boolean,jsonb,jsonb,uuid[]) to authenticated;
grant execute on function public.barberium_staff_assign_membership(uuid,uuid,uuid,date,boolean,text) to authenticated;
grant execute on function public.barberium_staff_record_membership_payment(uuid,uuid,text) to authenticated;
grant execute on function public.barberium_staff_customer_memberships(uuid) to authenticated;
grant execute on function public.barberium_staff_membership_requests() to authenticated;
grant execute on function public.barberium_staff_decide_membership_request(uuid,boolean,uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_complete_appointment(uuid,jsonb,int,date,text) to authenticated;
grant execute on function public.barberium_staff_record_receivable_payment(uuid,jsonb) to authenticated;
grant execute on function public.barberium_staff_finance_overview(date,date,uuid,text) to authenticated;
grant execute on function public.barberium_staff_save_financial_goal(uuid,date,int,int) to authenticated;
grant execute on function public.barberium_staff_appointment_finance(uuid) to authenticated;
grant execute on function public.barberium_public_membership_plans(text,text) to anon,authenticated;
grant execute on function public.barberium_request_membership(text,text,uuid) to anon,authenticated;

