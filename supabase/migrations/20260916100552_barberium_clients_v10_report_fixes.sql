create or replace function barberium.next_birthday(p_birthday date,p_today date)
returns date
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare y int; m int; d int; last_d int; candidate date;
begin
  if p_birthday is null or p_today is null then return null; end if;
  y:=extract(year from p_today)::int; m:=extract(month from p_birthday)::int; d:=extract(day from p_birthday)::int;
  last_d:=extract(day from (make_date(y,m,1)+interval '1 month - 1 day'))::int;
  candidate:=make_date(y,m,least(d,last_d));
  if candidate < p_today then
    y:=y+1;
    last_d:=extract(day from (make_date(y,m,1)+interval '1 month - 1 day'))::int;
    candidate:=make_date(y,m,least(d,last_d));
  end if;
  return candidate;
end;
$$;

create or replace function public.barberium_staff_customers(p_query text default '', p_without_phone boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare m record; q text; q_digits text; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso exclusivo do ADM'; end if;
  q:=trim(coalesce(p_query,'')); q_digits:=regexp_replace(q,'\D','','g');
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
      and (q='' or c.full_name ilike '%'||q||'%' or (q_digits<>'' and coalesce(c.phone_e164,'') like '%'||q_digits||'%'))
  ) s;
  return result;
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
    select c.id,c.full_name,c.phone_e164,c.birthday,barberium.next_birthday(c.birthday,today) next_birthday
    from public.customers c where c.barbershop_id=m.barbershop_id and c.phone_e164 is not null and c.birthday is not null
  ), month_series as (
    select generate_series(date_trunc('month',today)::date-(months-1)*interval '1 month',date_trunc('month',today)::date,interval '1 month')::date month_start
  ), pro_month_base as (
    select ms.month_start,p.id professional_id,p.name professional,
      count(a.*) filter(where a.status='completed') completed,
      count(distinct a.customer_id) filter(where a.status='completed') customers,
      count(a.*) filter(where a.status='cancelled') cancelled,
      count(a.*) filter(where a.status='no_show') no_show,
      coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) revenue
    from month_series ms cross join public.professionals p
    left join public.appointments a on a.professional_id=p.id and a.starts_at >= (ms.month_start::timestamp at time zone tz) and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
    where p.barbershop_id=m.barbershop_id and p.is_active
    group by ms.month_start,p.id,p.name
  ), pro_client_month as (
    select ms.month_start,p.id professional_id,a.customer_id,
      bool_or(not exists(select 1 from public.appointments old where old.customer_id=a.customer_id and old.status='completed' and old.starts_at < (ms.month_start::timestamp at time zone tz))) as is_new
    from month_series ms cross join public.professionals p
    join public.appointments a on a.professional_id=p.id and a.status='completed' and a.starts_at >= (ms.month_start::timestamp at time zone tz) and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
    where p.barbershop_id=m.barbershop_id and p.is_active
    group by ms.month_start,p.id,a.customer_id
  ), pro_month as (
    select b.*,
      coalesce((select count(*) from pro_client_month x where x.month_start=b.month_start and x.professional_id=b.professional_id and x.is_new),0) new_clients,
      coalesce((select count(*) from pro_client_month x where x.month_start=b.month_start and x.professional_id=b.professional_id and not x.is_new),0) returning_clients
    from pro_month_base b
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
      select c.id,c.full_name,c.phone_e164,c.birthday,u.name unit,barberium.next_birthday(c.birthday,today) next_birthday
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

