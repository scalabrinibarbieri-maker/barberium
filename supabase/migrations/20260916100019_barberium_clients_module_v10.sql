alter table public.customers alter column phone_e164 drop not null;
alter table public.customers add column if not exists persistent_note text;
alter table public.customers add column if not exists preferred_unit_id uuid references public.units(id) on delete set null;
alter table public.customers add column if not exists imported_at timestamptz;
alter table public.customers add column if not exists import_source text;

create table if not exists public.client_campaign_templates (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  name text not null,
  message text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.client_campaign_templates enable row level security;
create index if not exists idx_client_campaign_templates_shop on public.client_campaign_templates(barbershop_id, created_at desc);

create table if not exists public.client_campaigns (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  title text not null,
  audience_type text not null,
  message_mode text not null check (message_mode in ('single','personalized')),
  message_template text not null,
  scheduled_at timestamptz,
  status text not null default 'ready' check (status in ('ready','scheduled','completed','cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.client_campaigns enable row level security;
create index if not exists idx_client_campaigns_shop on public.client_campaigns(barbershop_id, created_at desc);

create table if not exists public.client_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.client_campaigns(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  name_snapshot text not null,
  phone_snapshot text not null,
  unit_snapshot text,
  days_absent_snapshot integer,
  message_snapshot text not null,
  created_at timestamptz not null default now(),
  unique(campaign_id, customer_id)
);
alter table public.client_campaign_recipients enable row level security;
create index if not exists idx_campaign_recipients_campaign on public.client_campaign_recipients(campaign_id);

create or replace function barberium.customer_main_unit(p_customer_id uuid)
returns uuid
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(
    (select c.preferred_unit_id from public.customers c where c.id=p_customer_id),
    (select a.unit_id
       from public.appointments a
      where a.customer_id=p_customer_id and a.status='completed'
      group by a.unit_id
      order by count(*) desc, max(a.starts_at) desc
      limit 1),
    (select a.unit_id from public.appointments a where a.customer_id=p_customer_id order by a.starts_at desc limit 1)
  )
$$;

create or replace function public.barberium_staff_catalog()
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
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
    'units',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug) order by u.name) from public.units u where u.barbershop_id=m.barbershop_id and u.is_active),'[]'::jsonb),
    'permissions',v_permissions
  );
end;
$$;

create or replace function public.barberium_staff_search_customers(p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; perms jsonb; show_phone boolean; show_full boolean; show_birthday boolean; q text; q_digits text; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then raise exception 'Sem permissão para criar agendamentos'; end if;
  show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_phone');
  show_full:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_full_name');
  show_birthday:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_birthday');
  q:=trim(coalesce(p_query,'')); q_digits:=regexp_replace(q,'\D','','g');
  select coalesce(jsonb_agg(x order by x->>'name'),'[]'::jsonb) into result
  from (
    select jsonb_build_object('id',c.id,'name',barberium.mask_customer_name(c.full_name,show_full),'phone',case when show_phone then c.phone_e164 else null end,'has_phone',c.phone_e164 is not null,'birthday',case when show_birthday then c.birthday else null end) x
    from public.customers c
    where c.barbershop_id=m.barbershop_id and (q='' or c.full_name ilike '%'||q||'%' or (q_digits<>'' and coalesce(c.phone_e164,'') like '%'||q_digits||'%'))
    order by c.full_name limit 20
  ) s;
  return result;
end;
$$;

create or replace function public.barberium_staff_customers(p_query text default '', p_without_phone boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; q text; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  q:=trim(coalesce(p_query,''));
  select coalesce(jsonb_agg(x order by lower(x->>'name')),'[]'::jsonb) into result
  from (
    select jsonb_build_object(
      'id',c.id,'name',c.full_name,'phone',c.phone_e164,'birthday',c.birthday,
      'persistent_note',c.persistent_note,
      'main_unit_id',mu.id,'main_unit',mu.name,
      'last_visit',lv.last_visit,
      'appointments',coalesce(st.total,0),'completed',coalesce(st.completed,0),'spent_cents',coalesce(st.spent,0)
    ) x
    from public.customers c
    left join public.units mu on mu.id=barberium.customer_main_unit(c.id)
    left join lateral (select max(a.starts_at) filter (where a.status='completed') last_visit from public.appointments a where a.customer_id=c.id) lv on true
    left join lateral (select count(*) total,count(*) filter(where a.status='completed') completed,coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) spent from public.appointments a where a.customer_id=c.id) st on true
    where c.barbershop_id=m.barbershop_id
      and (not p_without_phone or c.phone_e164 is null)
      and (q='' or c.full_name ilike '%'||q||'%' or coalesce(c.phone_e164,'') ilike '%'||regexp_replace(q,'\D','','g')||'%')
  ) s;
  return result;
end;
$$;

create or replace function public.barberium_staff_customer_detail(p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; c public.customers%rowtype; main_unit uuid; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select * into c from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id;
  if c.id is null then raise exception 'Cliente não encontrado'; end if;
  main_unit:=barberium.customer_main_unit(c.id);
  select jsonb_build_object(
    'id',c.id,'name',c.full_name,'phone',c.phone_e164,'birthday',c.birthday,'persistent_note',c.persistent_note,
    'preferred_unit_id',c.preferred_unit_id,'main_unit_id',main_unit,
    'main_unit',(select name from public.units where id=main_unit),
    'first_unit',(select u.name from public.appointments a join public.units u on u.id=a.unit_id where a.customer_id=c.id order by a.starts_at asc limit 1),
    'last_unit',(select u.name from public.appointments a join public.units u on u.id=a.unit_id where a.customer_id=c.id order by a.starts_at desc limit 1),
    'imported_at',c.imported_at,'import_source',c.import_source,
    'stats',(select jsonb_build_object(
      'appointments',count(*),'completed',count(*) filter(where a.status='completed'),'cancelled',count(*) filter(where a.status='cancelled'),'no_show',count(*) filter(where a.status='no_show'),
      'spent_cents',coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0),
      'average_ticket_cents',case when count(*) filter(where a.status='completed')>0 then round(coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0)::numeric/(count(*) filter(where a.status='completed')))::int else 0 end,
      'last_visit',max(a.starts_at) filter(where a.status='completed'),
      'next_visit',min(a.starts_at) filter(where a.status='confirmed' and a.starts_at>now())
    ) from public.appointments a where a.customer_id=c.id),
    'visits_by_unit',coalesce((select jsonb_agg(jsonb_build_object('unit_id',q.unit_id,'unit',q.unit,'visits',q.visits,'spent_cents',q.spent) order by q.visits desc,q.unit) from (select u.id unit_id,u.name unit,count(*) filter(where a.status='completed') visits,coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) spent from public.appointments a join public.units u on u.id=a.unit_id where a.customer_id=c.id group by u.id,u.name) q),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'starts_at',a.starts_at,'status',a.status,'service',s.name,'professional',p.name,'unit',u.name,'total_price_cents',a.total_price_cents) order by a.starts_at desc) from public.appointments a join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id join public.units u on u.id=a.unit_id where a.customer_id=c.id),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.barberium_staff_update_customer(p_customer_id uuid,p_full_name text,p_phone text,p_birthday date,p_preferred_unit_id uuid,p_persistent_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, extensions, auth, pg_temp
as $$
declare m record; c public.customers%rowtype; v_phone text; dup uuid; target uuid; merged boolean:=false;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select * into c from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id for update;
  if c.id is null then raise exception 'Cliente não encontrado'; end if;
  if length(trim(coalesce(p_full_name,'')))<2 then raise exception 'Nome inválido'; end if;
  if p_preferred_unit_id is not null and not exists(select 1 from public.units u where u.id=p_preferred_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  v_phone:=case when trim(coalesce(p_phone,''))='' then null else barberium.normalize_phone(p_phone) end;
  if trim(coalesce(p_phone,''))<>'' and v_phone is null then raise exception 'WhatsApp inválido'; end if;
  if v_phone is not null then select id into dup from public.customers where barbershop_id=m.barbershop_id and phone_e164=v_phone and id<>c.id limit 1; end if;
  if dup is not null then
    target:=dup; merged:=true;
    update public.appointments set customer_id=target where customer_id=c.id;
    update public.customer_access_tokens set customer_id=target where customer_id=c.id;
    update public.customers set
      full_name=trim(p_full_name),
      birthday=coalesce(p_birthday,birthday),
      preferred_unit_id=coalesce(p_preferred_unit_id,preferred_unit_id),
      persistent_note=case when trim(coalesce(p_persistent_note,''))<>'' then p_persistent_note else persistent_note end,
      updated_at=now()
    where id=target;
    delete from public.customers where id=c.id;
  else
    target:=c.id;
    update public.customers set full_name=trim(p_full_name),phone_e164=v_phone,birthday=p_birthday,preferred_unit_id=p_preferred_unit_id,persistent_note=nullif(trim(coalesce(p_persistent_note,'')),''),updated_at=now() where id=target;
  end if;
  return jsonb_build_object('ok',true,'customer_id',target,'merged',merged);
end;
$$;

create or replace function public.barberium_staff_import_customers(p_rows jsonb,p_source text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; r jsonb; nm text; ph text; norm text; bd date; note text; existing uuid; inserted int:=0; updated int:=0; no_phone int:=0; skipped int:=0;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  if jsonb_typeof(p_rows)<>'array' then raise exception 'Arquivo inválido'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    nm:=trim(coalesce(r->>'name',''));
    if nm='' then skipped:=skipped+1; continue; end if;
    ph:=trim(coalesce(r->>'phone','')); norm:=case when ph='' then null else barberium.normalize_phone(ph) end;
    bd:=case when coalesce(r->>'birthday','') ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'birthday')::date else null end;
    note:=nullif(trim(coalesce(r->>'note','')),'');
    existing:=null;
    if norm is not null then select id into existing from public.customers where barbershop_id=m.barbershop_id and phone_e164=norm limit 1; end if;
    if existing is not null then
      update public.customers set
        full_name=case when nm<>'' then nm else full_name end,
        birthday=coalesce(bd,birthday),
        persistent_note=coalesce(note,persistent_note),
        imported_at=now(),import_source=coalesce(nullif(trim(p_source),''),import_source),updated_at=now()
      where id=existing;
      updated:=updated+1;
    else
      insert into public.customers(barbershop_id,full_name,phone_e164,birthday,persistent_note,imported_at,import_source)
      values(m.barbershop_id,nm,norm,bd,note,now(),nullif(trim(p_source),''));
      inserted:=inserted+1;
      if norm is null then no_phone:=no_phone+1; end if;
    end if;
  end loop;
  return jsonb_build_object('inserted',inserted,'updated',updated,'without_phone',no_phone,'skipped',skipped);
end;
$$;

create or replace function public.barberium_staff_client_reports(p_months integer default 6)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; tz text; today date; months int; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select timezone into tz from public.barbershops where id=m.barbershop_id; tz:=coalesce(tz,'America/Sao_Paulo'); today:=(now() at time zone tz)::date; months:=greatest(1,least(coalesce(p_months,6),24));
  with bd as (
    select c.id,c.full_name,c.phone_e164,c.birthday,
      case when make_date(extract(year from today)::int,extract(month from c.birthday)::int,least(extract(day from c.birthday)::int,28)) < today
           then make_date(extract(year from today)::int+1,extract(month from c.birthday)::int,least(extract(day from c.birthday)::int,28))
           else make_date(extract(year from today)::int,extract(month from c.birthday)::int,least(extract(day from c.birthday)::int,28)) end next_birthday
    from public.customers c where c.barbershop_id=m.barbershop_id and c.phone_e164 is not null and c.birthday is not null
  ), month_series as (
    select generate_series(date_trunc('month',today)::date-(months-1)*interval '1 month',date_trunc('month',today)::date,interval '1 month')::date month_start
  ), pro_month as (
    select ms.month_start,p.id professional_id,p.name professional,
      count(a.*) filter(where a.status='completed') completed,
      count(distinct a.customer_id) filter(where a.status='completed') customers,
      count(a.*) filter(where a.status='cancelled') cancelled,
      count(a.*) filter(where a.status='no_show') no_show,
      coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) revenue,
      count(distinct a.customer_id) filter(where a.status='completed' and not exists(select 1 from public.appointments old where old.customer_id=a.customer_id and old.status='completed' and old.starts_at<a.starts_at)) new_clients,
      count(distinct a.customer_id) filter(where a.status='completed' and exists(select 1 from public.appointments old where old.customer_id=a.customer_id and old.status='completed' and old.starts_at<a.starts_at)) returning_clients
    from month_series ms cross join public.professionals p
    left join public.appointments a on a.professional_id=p.id and a.starts_at >= (ms.month_start::timestamp at time zone tz) and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
    where p.barbershop_id=m.barbershop_id and p.is_active
    group by ms.month_start,p.id,p.name
  )
  select jsonb_build_object(
    'summary',(select jsonb_build_object(
      'customers',count(*),
      'average_ticket_cents',coalesce((select round(avg(a.total_price_cents))::int from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed'),0),
      'spent_cents',coalesce((select sum(a.total_price_cents) from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed'),0)
    ) from public.customers c where c.barbershop_id=m.barbershop_id),
    'birthdays',jsonb_build_object(
      'today',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday) order by full_name) from bd where next_birthday=today),'[]'::jsonb),
      'week',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday,'next_birthday',next_birthday) order by next_birthday,full_name) from bd where next_birthday between today and today+6),'[]'::jsonb),
      'month',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday,'next_birthday',next_birthday) order by next_birthday,full_name) from bd where date_trunc('month',next_birthday)=date_trunc('month',today)),'[]'::jsonb)
    ),
    'evolution',coalesce((select jsonb_agg(jsonb_build_object(
      'month',ms.month_start,
      'customers_total',(select count(*) from public.customers c where c.barbershop_id=m.barbershop_id and c.created_at < (ms.month_start+interval '1 month')),
      'new_customers',(select count(*) from public.customers c where c.barbershop_id=m.barbershop_id and c.created_at >= ms.month_start and c.created_at < ms.month_start+interval '1 month'),
      'completed',(select count(*) from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at >= (ms.month_start::timestamp at time zone tz) and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)),
      'revenue_cents',(select coalesce(sum(a.total_price_cents),0) from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at >= (ms.month_start::timestamp at time zone tz) and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)),
      'ticket_cents',(select coalesce(round(avg(a.total_price_cents))::int,0) from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at >= (ms.month_start::timestamp at time zone tz) and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz))
    ) order by ms.month_start) from month_series ms),'[]'::jsonb),
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('month',month_start,'professional_id',professional_id,'professional',professional,'completed',completed,'customers',customers,'new_clients',new_clients,'returning_clients',returning_clients,'cancelled',cancelled,'no_show',no_show,'revenue_cents',revenue,'ticket_cents',case when completed>0 then round(revenue::numeric/completed)::int else 0 end) order by month_start,professional) from pro_month),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.barberium_staff_campaign_audience(p_audience text)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; tz text; today date; lo int; hi int; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select timezone into tz from public.barbershops where id=m.barbershop_id; tz:=coalesce(tz,'America/Sao_Paulo'); today:=(now() at time zone tz)::date;
  lo:=case p_audience when 'absent_10_20' then 10 when 'absent_20_30' then 20 when 'absent_30_60' then 30 when 'absent_60_100' then 60 when 'absent_100_plus' then 100 else null end;
  hi:=case p_audience when 'absent_10_20' then 19 when 'absent_20_30' then 29 when 'absent_30_60' then 59 when 'absent_60_100' then 99 else null end;
  if lo is not null then
    select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.full_name,'phone',c.phone_e164,'days_absent',(today-lv.last_date),'unit',u.name) order by (today-lv.last_date) desc,c.full_name),'[]'::jsonb) into result
    from public.customers c
    join lateral (select max((a.starts_at at time zone tz)::date) last_date from public.appointments a where a.customer_id=c.id and a.status='completed') lv on lv.last_date is not null
    left join public.units u on u.id=barberium.customer_main_unit(c.id)
    where c.barbershop_id=m.barbershop_id and c.phone_e164 is not null
      and (today-lv.last_date)>=lo and (hi is null or (today-lv.last_date)<=hi)
      and not exists(select 1 from public.appointments f where f.customer_id=c.id and f.status='confirmed' and f.starts_at>now());
  elsif p_audience in ('birthday_today','birthday_week','birthday_month') then
    with bd as (
      select c.id,c.full_name,c.phone_e164,c.birthday,u.name unit,
        case when make_date(extract(year from today)::int,extract(month from c.birthday)::int,least(extract(day from c.birthday)::int,28)) < today
          then make_date(extract(year from today)::int+1,extract(month from c.birthday)::int,least(extract(day from c.birthday)::int,28))
          else make_date(extract(year from today)::int,extract(month from c.birthday)::int,least(extract(day from c.birthday)::int,28)) end next_birthday
      from public.customers c left join public.units u on u.id=barberium.customer_main_unit(c.id)
      where c.barbershop_id=m.barbershop_id and c.phone_e164 is not null and c.birthday is not null
    )
    select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday,'unit',unit) order by next_birthday,full_name),'[]'::jsonb) into result from bd
    where (p_audience='birthday_today' and next_birthday=today)
       or (p_audience='birthday_week' and next_birthday between today and today+6)
       or (p_audience='birthday_month' and date_trunc('month',next_birthday)=date_trunc('month',today));
  else raise exception 'Público inválido'; end if;
  return result;
end;
$$;

create or replace function public.barberium_staff_save_campaign_template(p_name text,p_message text)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; rid uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  if trim(coalesce(p_name,''))='' or trim(coalesce(p_message,''))='' then raise exception 'Nome e mensagem são obrigatórios'; end if;
  insert into public.client_campaign_templates(barbershop_id,name,message,created_by) values(m.barbershop_id,trim(p_name),p_message,auth.uid()) returning id into rid;
  return jsonb_build_object('ok',true,'id',rid);
end;
$$;

create or replace function public.barberium_staff_campaign_templates()
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'message',message) order by created_at desc),'[]'::jsonb) into result from public.client_campaign_templates where barbershop_id=m.barbershop_id;
  return result;
end;
$$;

create or replace function public.barberium_staff_create_campaign(p_title text,p_audience text,p_message_mode text,p_message_template text,p_scheduled_at timestamptz,p_customer_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; cid uuid; statusv text; c record; daysv int; unitv text; msg text; n int:=0; tz text; today date;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  if p_message_mode not in ('single','personalized') then raise exception 'Modo inválido'; end if;
  if coalesce(array_length(p_customer_ids,1),0)=0 then raise exception 'Selecione ao menos um cliente'; end if;
  select timezone into tz from public.barbershops where id=m.barbershop_id; tz:=coalesce(tz,'America/Sao_Paulo'); today:=(now() at time zone tz)::date;
  statusv:=case when p_scheduled_at is not null and p_scheduled_at>now() then 'scheduled' else 'ready' end;
  insert into public.client_campaigns(barbershop_id,title,audience_type,message_mode,message_template,scheduled_at,status,created_by) values(m.barbershop_id,coalesce(nullif(trim(p_title),''),'Campanha'),p_audience,p_message_mode,p_message_template,p_scheduled_at,statusv,auth.uid()) returning id into cid;
  for c in select cu.id,cu.full_name,cu.phone_e164,u.name unit,(select max((a.starts_at at time zone tz)::date) from public.appointments a where a.customer_id=cu.id and a.status='completed') last_date from public.customers cu left join public.units u on u.id=barberium.customer_main_unit(cu.id) where cu.barbershop_id=m.barbershop_id and cu.id=any(p_customer_ids) and cu.phone_e164 is not null loop
    daysv:=case when c.last_date is null then null else today-c.last_date end;
    unitv:=c.unit;
    msg:=p_message_template;
    if p_message_mode='personalized' then
      msg:=replace(msg,'{nome}',split_part(c.full_name,' ',1));
      msg:=replace(msg,'{dias_sem_vir}',coalesce(daysv::text,''));
      msg:=replace(msg,'{unidade}',coalesce(unitv,''));
    end if;
    insert into public.client_campaign_recipients(campaign_id,customer_id,name_snapshot,phone_snapshot,unit_snapshot,days_absent_snapshot,message_snapshot) values(cid,c.id,c.full_name,c.phone_e164,unitv,daysv,msg);
    n:=n+1;
  end loop;
  return jsonb_build_object('ok',true,'campaign_id',cid,'recipients',n,'status',statusv);
end;
$$;

create or replace function public.barberium_staff_campaigns()
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'title',c.title,'audience_type',c.audience_type,'message_mode',c.message_mode,'scheduled_at',c.scheduled_at,'status',case when c.status='scheduled' and c.scheduled_at<=now() then 'ready' else c.status end,'created_at',c.created_at,'recipients',(select count(*) from public.client_campaign_recipients r where r.campaign_id=c.id)) order by c.created_at desc),'[]'::jsonb) into result from public.client_campaigns c where c.barbershop_id=m.barbershop_id;
  return result;
end;
$$;

create or replace function public.barberium_staff_campaign_detail(p_campaign_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; c public.client_campaigns%rowtype; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  select * into c from public.client_campaigns where id=p_campaign_id and barbershop_id=m.barbershop_id; if c.id is null then raise exception 'Campanha não encontrada'; end if;
  select jsonb_build_object('id',c.id,'title',c.title,'audience_type',c.audience_type,'message_mode',c.message_mode,'message_template',c.message_template,'scheduled_at',c.scheduled_at,'status',case when c.status='scheduled' and c.scheduled_at<=now() then 'ready' else c.status end,'created_at',c.created_at,
    'recipients',coalesce((select jsonb_agg(jsonb_build_object('customer_id',r.customer_id,'name',r.name_snapshot,'phone',r.phone_snapshot,'unit',r.unit_snapshot,'days_absent',r.days_absent_snapshot,'message',r.message_snapshot,'returned',exists(select 1 from public.appointments a where a.customer_id=r.customer_id and a.created_at>c.created_at and a.status in ('confirmed','completed'))) order by r.name_snapshot) from public.client_campaign_recipients r where r.campaign_id=c.id),'[]'::jsonb)) into result;
  return result;
end;
$$;

revoke all on function public.barberium_staff_customers(text,boolean) from public,anon;
revoke all on function public.barberium_staff_customer_detail(uuid) from public,anon;
revoke all on function public.barberium_staff_update_customer(uuid,text,text,date,uuid,text) from public,anon;
revoke all on function public.barberium_staff_import_customers(jsonb,text) from public,anon;
revoke all on function public.barberium_staff_client_reports(integer) from public,anon;
revoke all on function public.barberium_staff_campaign_audience(text) from public,anon;
revoke all on function public.barberium_staff_save_campaign_template(text,text) from public,anon;
revoke all on function public.barberium_staff_campaign_templates() from public,anon;
revoke all on function public.barberium_staff_create_campaign(text,text,text,text,timestamptz,uuid[]) from public,anon;
revoke all on function public.barberium_staff_campaigns() from public,anon;
revoke all on function public.barberium_staff_campaign_detail(uuid) from public,anon;
grant execute on function public.barberium_staff_customers(text,boolean) to authenticated;
grant execute on function public.barberium_staff_customer_detail(uuid) to authenticated;
grant execute on function public.barberium_staff_update_customer(uuid,text,text,date,uuid,text) to authenticated;
grant execute on function public.barberium_staff_import_customers(jsonb,text) to authenticated;
grant execute on function public.barberium_staff_client_reports(integer) to authenticated;
grant execute on function public.barberium_staff_campaign_audience(text) to authenticated;
grant execute on function public.barberium_staff_save_campaign_template(text,text) to authenticated;
grant execute on function public.barberium_staff_campaign_templates() to authenticated;
grant execute on function public.barberium_staff_create_campaign(text,text,text,text,timestamptz,uuid[]) to authenticated;
grant execute on function public.barberium_staff_campaigns() to authenticated;
grant execute on function public.barberium_staff_campaign_detail(uuid) to authenticated;

