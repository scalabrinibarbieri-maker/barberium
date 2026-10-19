
create or replace function public.barberium_staff_create_appointment_v12_21(
  p_customer_id uuid,
  p_full_name text,
  p_phone text,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_time time without time zone,
  p_is_passenger boolean,
  p_final_price_cents integer default null,
  p_internal_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  v_customer_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  if coalesce(p_is_passenger,false) then
    insert into public.customers(
      barbershop_id,full_name,phone_e164,marketing_opt_in,import_source
    )
    values(
      m.barbershop_id,'Cliente passageiro',null,false,'passenger'
    )
    returning id into v_customer_id;
  else
    v_customer_id:=p_customer_id;
  end if;

  return public.barberium_staff_create_appointment_v12_12(
    v_customer_id,
    case when coalesce(p_is_passenger,false) then null else p_full_name end,
    case when coalesce(p_is_passenger,false) then null else p_phone end,
    p_professional_id,
    p_service_id,
    p_addon_service_ids,
    p_extra_service_ids,
    p_date,
    p_time,
    p_final_price_cents,
    p_internal_note
  );
end
$function$;

create or replace function public.barberium_staff_create_walk_in_v12_21(
  p_customer_id uuid,
  p_full_name text,
  p_phone text,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_time time without time zone,
  p_is_passenger boolean,
  p_final_price_cents integer default null,
  p_internal_note text default null,
  p_blocks_schedule boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  v_customer_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  if coalesce(p_is_passenger,false) then
    insert into public.customers(
      barbershop_id,full_name,phone_e164,marketing_opt_in,import_source
    )
    values(
      m.barbershop_id,'Cliente passageiro',null,false,'passenger'
    )
    returning id into v_customer_id;
  else
    v_customer_id:=p_customer_id;
  end if;

  return public.barberium_staff_create_walk_in_v12_12(
    v_customer_id,
    case when coalesce(p_is_passenger,false) then null else p_full_name end,
    case when coalesce(p_is_passenger,false) then null else p_phone end,
    p_professional_id,
    p_service_id,
    p_addon_service_ids,
    p_extra_service_ids,
    p_date,
    p_time,
    p_final_price_cents,
    p_internal_note,
    p_blocks_schedule
  );
end
$function$;

create or replace function public.barberium_staff_search_customers(p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  perms jsonb;
  show_phone boolean;
  show_full boolean;
  show_birthday boolean;
  q text;
  q_digits text;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  perms:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  if m.role not in ('owner','admin')
     and not barberium.permission_enabled(perms,'create_appointment')
  then raise exception 'Sem permissão para criar agendamentos'; end if;

  show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_phone');
  show_full:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_full_name');
  show_birthday:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_birthday');

  q:=trim(coalesce(p_query,''));
  q_digits:=regexp_replace(q,'\D','','g');

  select coalesce(jsonb_agg(x order by x->>'name'),'[]'::jsonb)
  into result
  from (
    select jsonb_build_object(
      'id',c.id,
      'name',barberium.mask_customer_name(c.full_name,show_full),
      'phone',case when show_phone then c.phone_e164 else null end,
      'has_phone',c.phone_e164 is not null,
      'birthday',case when show_birthday then c.birthday else null end
    ) x
    from public.customers c
    where c.barbershop_id=m.barbershop_id
      and coalesce(c.import_source,'')<>'passenger'
      and (
        q=''
        or c.full_name ilike '%'||q||'%'
        or (q_digits<>'' and coalesce(c.phone_e164,'') like '%'||q_digits||'%')
      )
    order by c.full_name
    limit 20
  ) s;

  return result;
end
$function$;

create or replace function public.barberium_staff_customers(
  p_query text default '',
  p_without_phone boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  q text;
  q_digits text;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Acesso exclusivo do ADM';
  end if;

  q:=trim(coalesce(p_query,''));
  q_digits:=regexp_replace(q,'\D','','g');

  select coalesce(jsonb_agg(x order by lower(x->>'name')),'[]'::jsonb)
  into result
  from (
    select jsonb_build_object(
      'id',c.id,
      'name',c.full_name,
      'phone',c.phone_e164,
      'birthday',c.birthday,
      'persistent_note',c.persistent_note,
      'main_unit_id',mu.id,
      'main_unit',mu.name,
      'last_visit',lv.last_visit,
      'appointments',coalesce(st.total,0),
      'completed',coalesce(st.completed,0),
      'spent_cents',coalesce(st.spent,0)
    ) x
    from public.customers c
    left join public.units mu on mu.id=barberium.customer_main_unit(c.id)
    left join lateral (
      select max(a.starts_at) filter(where a.status='completed') last_visit
      from public.appointments a
      where a.customer_id=c.id
    ) lv on true
    left join lateral (
      select
        count(*) total,
        count(*) filter(where a.status='completed') completed,
        coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) spent
      from public.appointments a
      where a.customer_id=c.id
    ) st on true
    where c.barbershop_id=m.barbershop_id
      and coalesce(c.import_source,'')<>'passenger'
      and (not p_without_phone or c.phone_e164 is null)
      and (
        q=''
        or c.full_name ilike '%'||q||'%'
        or (q_digits<>'' and coalesce(c.phone_e164,'') like '%'||q_digits||'%')
      )
  ) s;

  return result;
end
$function$;

create or replace function public.barberium_staff_client_reports(p_months integer default 6)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  tz text;
  today date;
  months int;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Acesso exclusivo do ADM';
  end if;

  select timezone into tz
  from public.barbershops
  where id=m.barbershop_id;

  tz:=coalesce(tz,'America/Sao_Paulo');
  today:=(now() at time zone tz)::date;
  months:=greatest(1,least(coalesce(p_months,6),24));

  with real_customers as (
    select c.*
    from public.customers c
    where c.barbershop_id=m.barbershop_id
      and coalesce(c.import_source,'')<>'passenger'
  ),
  bd as (
    select
      c.id,c.full_name,c.phone_e164,c.birthday,
      barberium.next_birthday(c.birthday,today) next_birthday
    from real_customers c
    where c.phone_e164 is not null
      and c.birthday is not null
  ),
  month_series as (
    select generate_series(
      date_trunc('month',today)::date-(months-1)*interval '1 month',
      date_trunc('month',today)::date,
      interval '1 month'
    )::date month_start
  ),
  pro_month_base as (
    select
      ms.month_start,
      p.id professional_id,
      p.name professional,
      count(a.*) filter(where a.status='completed') completed,
      count(distinct a.customer_id) filter(
        where a.status='completed'
          and exists(select 1 from real_customers rc where rc.id=a.customer_id)
      ) customers,
      count(a.*) filter(where a.status='cancelled') cancelled,
      count(a.*) filter(where a.status='no_show') no_show,
      coalesce(sum(a.total_price_cents) filter(where a.status='completed'),0) revenue
    from month_series ms
    cross join public.professionals p
    left join public.appointments a
      on a.professional_id=p.id
      and a.starts_at >= (ms.month_start::timestamp at time zone tz)
      and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
    where p.barbershop_id=m.barbershop_id
      and p.is_active
    group by ms.month_start,p.id,p.name
  ),
  pro_client_month as (
    select
      ms.month_start,
      p.id professional_id,
      a.customer_id,
      bool_or(
        not exists(
          select 1
          from public.appointments old
          where old.customer_id=a.customer_id
            and old.status='completed'
            and old.starts_at < (ms.month_start::timestamp at time zone tz)
        )
      ) as is_new
    from month_series ms
    cross join public.professionals p
    join public.appointments a
      on a.professional_id=p.id
      and a.status='completed'
      and a.starts_at >= (ms.month_start::timestamp at time zone tz)
      and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
    join real_customers rc on rc.id=a.customer_id
    where p.barbershop_id=m.barbershop_id
      and p.is_active
    group by ms.month_start,p.id,a.customer_id
  ),
  pro_month as (
    select
      b.*,
      coalesce((
        select count(*)
        from pro_client_month x
        where x.month_start=b.month_start
          and x.professional_id=b.professional_id
          and x.is_new
      ),0) new_clients,
      coalesce((
        select count(*)
        from pro_client_month x
        where x.month_start=b.month_start
          and x.professional_id=b.professional_id
          and not x.is_new
      ),0) returning_clients
    from pro_month_base b
  )
  select jsonb_build_object(
    'summary',(
      select jsonb_build_object(
        'customers',(select count(*) from real_customers),
        'average_ticket_cents',coalesce((
          select round(avg(a.total_price_cents))::int
          from public.appointments a
          where a.barbershop_id=m.barbershop_id
            and a.status='completed'
        ),0),
        'spent_cents',coalesce((
          select sum(a.total_price_cents)
          from public.appointments a
          where a.barbershop_id=m.barbershop_id
            and a.status='completed'
        ),0)
      )
    ),
    'birthdays',jsonb_build_object(
      'today',coalesce((
        select jsonb_agg(
          jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday)
          order by full_name
        )
        from bd
        where next_birthday=today
      ),'[]'::jsonb),
      'week',coalesce((
        select jsonb_agg(
          jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday,'next_birthday',next_birthday)
          order by next_birthday,full_name
        )
        from bd
        where next_birthday between today and today+6
      ),'[]'::jsonb),
      'month',coalesce((
        select jsonb_agg(
          jsonb_build_object('id',id,'name',full_name,'phone',phone_e164,'birthday',birthday,'next_birthday',next_birthday)
          order by next_birthday,full_name
        )
        from bd
        where date_trunc('month',next_birthday)=date_trunc('month',today)
      ),'[]'::jsonb)
    ),
    'evolution',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'month',ms.month_start,
          'customers_total',(
            select count(*)
            from real_customers c
            where c.created_at < (ms.month_start+interval '1 month')
          ),
          'new_customers',(
            select count(*)
            from real_customers c
            where c.created_at >= ms.month_start
              and c.created_at < ms.month_start+interval '1 month'
          ),
          'completed',(
            select count(*)
            from public.appointments a
            where a.barbershop_id=m.barbershop_id
              and a.status='completed'
              and a.starts_at >= (ms.month_start::timestamp at time zone tz)
              and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
          ),
          'revenue_cents',(
            select coalesce(sum(a.total_price_cents),0)
            from public.appointments a
            where a.barbershop_id=m.barbershop_id
              and a.status='completed'
              and a.starts_at >= (ms.month_start::timestamp at time zone tz)
              and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
          ),
          'ticket_cents',(
            select coalesce(round(avg(a.total_price_cents))::int,0)
            from public.appointments a
            where a.barbershop_id=m.barbershop_id
              and a.status='completed'
              and a.starts_at >= (ms.month_start::timestamp at time zone tz)
              and a.starts_at < ((ms.month_start+interval '1 month')::timestamp at time zone tz)
          )
        )
        order by ms.month_start
      )
      from month_series ms
    ),'[]'::jsonb),
    'professionals',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'month',month_start,
          'professional_id',professional_id,
          'professional',professional,
          'completed',completed,
          'customers',customers,
          'new_clients',new_clients,
          'returning_clients',returning_clients,
          'cancelled',cancelled,
          'no_show',no_show,
          'revenue_cents',revenue,
          'ticket_cents',case when completed>0 then round(revenue::numeric/completed)::int else 0 end
        )
        order by month_start,professional
      )
      from pro_month
    ),'[]'::jsonb)
  )
  into result;

  return result;
end
$function$;

revoke execute on function public.barberium_staff_create_appointment_v12_21(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time without time zone,boolean,integer,text) from public,anon;
grant execute on function public.barberium_staff_create_appointment_v12_21(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time without time zone,boolean,integer,text) to authenticated,service_role;

revoke execute on function public.barberium_staff_create_walk_in_v12_21(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time without time zone,boolean,integer,text,boolean) from public,anon;
grant execute on function public.barberium_staff_create_walk_in_v12_21(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time without time zone,boolean,integer,text,boolean) to authenticated,service_role;

