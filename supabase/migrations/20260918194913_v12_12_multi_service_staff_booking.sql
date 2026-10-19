
alter table public.appointment_addons
  add column if not exists item_kind text not null default 'addon';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.appointment_addons'::regclass
      and conname='appointment_addons_item_kind_check'
  ) then
    alter table public.appointment_addons
      add constraint appointment_addons_item_kind_check
      check (item_kind in ('addon','service'));
  end if;
end $$;

create or replace function barberium.appointment_addon_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public','barberium','pg_temp'
as $function$
declare
  a public.appointments;
  s public.services;
  ep int;
  ed int;
begin
  select * into a from public.appointments where id=new.appointment_id;
  if a.id is null then raise exception 'APPOINTMENT_NOT_FOUND'; end if;

  if not barberium.professional_service_allowed(a.professional_id,new.service_id) then
    raise exception 'PROFESSIONAL_NOT_LINKED_TO_ADDON';
  end if;

  select * into s
  from public.services
  where id=new.service_id
    and is_active
    and unit_id=a.unit_id;

  if s.id is null then raise exception 'INVALID_ADDON'; end if;

  if coalesce(new.item_kind,'addon')='service' then
    if s.service_kind not in ('service','combo')
       or coalesce((s.settings->>'draft')::boolean,false)
    then raise exception 'INVALID_SERVICE'; end if;
    if new.service_id=a.service_id then raise exception 'DUPLICATE_PRIMARY_SERVICE'; end if;
    ep:=barberium.effective_service_price(a.professional_id,new.service_id);
    ed:=barberium.effective_service_duration(a.professional_id,new.service_id);
  else
    new.item_kind:='addon';
    ep:=barberium.effective_addon_price(a.professional_id,a.service_id,new.service_id);
    ed:=barberium.effective_addon_duration(a.professional_id,a.service_id,new.service_id);
    if ep is null or ed is null then raise exception 'INVALID_ADDON'; end if;
  end if;

  new.name_snapshot:=s.name;
  new.price_cents:=ep;
  new.duration_min:=ed;
  return new;
end
$function$;

create or replace function public.barberium_staff_available_slots_v12_12(
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_exclude_appointment_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  prof public.professionals;
  svc public.services;
  b public.barbershops;
  u public.units;
  v_open time;
  v_close time;
  v_closed boolean;
  v_duration int;
  v_slot int;
  v_cur timestamp;
  v_start timestamptz;
  v_end timestamptz;
  v_extra_ids uuid[];
  result jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  if m.role='barber' then p_professional_id:=m.professional_id; end if;

  select * into prof from public.professionals
  where id=p_professional_id and barbershop_id=m.barbershop_id and is_active;
  if not found then raise exception 'Profissional inválido'; end if;

  select * into svc from public.services
  where id=p_service_id and unit_id=prof.unit_id and is_active;
  if not found then raise exception 'Serviço inválido'; end if;
  if not barberium.professional_service_allowed(prof.id,svc.id) then return result; end if;

  select coalesce(array_agg(distinct x.service_id order by x.service_id),'{}'::uuid[])
  into v_extra_ids
  from unnest(coalesce(p_extra_service_ids,'{}'::uuid[])) as x(service_id);

  if p_service_id=any(v_extra_ids) then raise exception 'O serviço principal não pode ser adicionado novamente'; end if;
  if exists(
    select 1 from unnest(v_extra_ids) x(service_id)
    where x.service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[]))
  ) then raise exception 'O mesmo item não pode ser serviço e adicional'; end if;

  if exists(
    select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    where not exists(
      select 1 from public.service_addons a
      where a.base_service_id=p_service_id and a.addon_service_id=x.service_id and a.is_active
    )
    or not barberium.professional_service_allowed(prof.id,x.service_id)
  ) then raise exception 'Adicional inválido'; end if;

  if exists(
    select 1 from unnest(v_extra_ids) x(service_id)
    where not exists(
      select 1 from public.services es
      where es.id=x.service_id
        and es.unit_id=prof.unit_id
        and es.is_active
        and es.service_kind in ('service','combo')
        and coalesce((es.settings->>'draft')::boolean,false)=false
    )
    or not barberium.professional_service_allowed(prof.id,x.service_id)
  ) then raise exception 'Serviço adicional inválido para este profissional'; end if;

  select * into b from public.barbershops where id=m.barbershop_id;
  select * into u from public.units where id=prof.unit_id;

  v_duration:=
    barberium.effective_service_duration(prof.id,svc.id)
    +coalesce((
      select sum(barberium.effective_addon_duration(prof.id,svc.id,x.service_id))
      from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_duration(prof.id,x.service_id))
      from unnest(v_extra_ids) x(service_id)
    ),0);

  v_slot:=barberium.effective_slot_minutes(prof.id);

  select h.open_time,h.close_time,h.is_closed
  into v_open,v_close,v_closed
  from barberium.effective_business_hours(u.id,prof.id,p_date) h;

  if not found or v_closed then return result; end if;

  v_cur:=p_date::timestamp+v_open;
  while v_cur<p_date::timestamp+v_close loop
    v_start:=v_cur at time zone coalesce(b.timezone,'America/Sao_Paulo');
    v_end:=v_start+make_interval(mins=>v_duration);

    if v_end<=((p_date::timestamp+v_close) at time zone coalesce(b.timezone,'America/Sao_Paulo'))
      and (v_start>=now() or p_exclude_appointment_id is not null)
      and not exists(
        select 1 from public.appointments a
        where a.professional_id=prof.id
          and a.status='confirmed'
          and a.blocks_schedule
          and (p_exclude_appointment_id is null or a.id<>p_exclude_appointment_id)
          and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
      )
      and not barberium.has_block_conflict(u.id,prof.id,v_start,v_end,null,null)
    then
      result:=result||jsonb_build_array(to_char(v_cur,'HH24:MI'));
    end if;

    v_cur:=v_cur+make_interval(mins=>v_slot);
  end loop;

  return result;
end
$function$;

create or replace function public.barberium_staff_create_appointment_v12_12(
  p_customer_id uuid,
  p_full_name text,
  p_phone text,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_time time without time zone,
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
  perms jsonb;
  v_prof public.professionals;
  v_service public.services;
  v_customer public.customers;
  v_b public.barbershops;
  v_phone text;
  v_duration int;
  v_base int;
  v_listed int;
  v_final int;
  v_start timestamptz;
  v_end timestamptz;
  v_appt public.appointments;
  v_extra_ids uuid[];
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  perms:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then
    raise exception 'Sem permissão para criar agendamentos';
  end if;
  if m.role='barber' then p_professional_id:=m.professional_id; end if;

  select * into v_prof from public.professionals
  where id=p_professional_id and barbershop_id=m.barbershop_id and is_active;
  if not found then raise exception 'Profissional inválido'; end if;

  select * into v_service from public.services
  where id=p_service_id and unit_id=v_prof.unit_id and is_active;
  if not found then raise exception 'Serviço inválido'; end if;
  if not barberium.professional_service_allowed(v_prof.id,v_service.id) then
    raise exception 'Profissional não vinculado ao serviço';
  end if;

  select coalesce(array_agg(distinct x.service_id order by x.service_id),'{}'::uuid[])
  into v_extra_ids
  from unnest(coalesce(p_extra_service_ids,'{}'::uuid[])) as x(service_id);

  if p_service_id=any(v_extra_ids) then raise exception 'O serviço principal não pode ser adicionado novamente'; end if;
  if exists(
    select 1 from unnest(v_extra_ids) x(service_id)
    where x.service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[]))
  ) then raise exception 'O mesmo item não pode ser serviço e adicional'; end if;

  if exists(
    select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    where not exists(
      select 1 from public.service_addons a
      where a.base_service_id=p_service_id and a.addon_service_id=x.service_id and a.is_active
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Adicional inválido para este profissional'; end if;

  if exists(
    select 1 from unnest(v_extra_ids) x(service_id)
    where not exists(
      select 1 from public.services es
      where es.id=x.service_id
        and es.unit_id=v_prof.unit_id
        and es.is_active
        and es.service_kind in ('service','combo')
        and coalesce((es.settings->>'draft')::boolean,false)=false
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Serviço adicional inválido para este profissional'; end if;

  if p_customer_id is not null then
    select * into v_customer from public.customers
    where id=p_customer_id and barbershop_id=m.barbershop_id;
    if not found then raise exception 'Cliente inválido'; end if;
  else
    if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'Informe o nome do cliente'; end if;
    v_phone:=barberium.normalize_phone(p_phone);
    if v_phone is null then raise exception 'Informe um WhatsApp válido'; end if;
    select * into v_customer from public.customers
    where barbershop_id=m.barbershop_id and phone_e164=v_phone;
    if found then
      update public.customers
      set full_name=trim(p_full_name),updated_at=now()
      where id=v_customer.id
      returning * into v_customer;
    else
      insert into public.customers(barbershop_id,full_name,phone_e164)
      values(m.barbershop_id,trim(p_full_name),v_phone)
      returning * into v_customer;
    end if;
  end if;

  if p_internal_note is not null and trim(p_internal_note)<>''
     and m.role not in ('owner','admin')
     and not barberium.permission_enabled(perms,'edit_internal_note')
  then raise exception 'Sem permissão para observação interna'; end if;

  select * into v_b from public.barbershops where id=m.barbershop_id;

  v_duration:=
    barberium.effective_service_duration(v_prof.id,v_service.id)
    +coalesce((
      select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x.service_id))
      from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_duration(v_prof.id,x.service_id))
      from unnest(v_extra_ids) x(service_id)
    ),0);

  v_base:=barberium.effective_service_price(v_prof.id,v_service.id);
  v_listed:=
    v_base
    +coalesce((
      select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x.service_id))
      from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_price(v_prof.id,x.service_id))
      from unnest(v_extra_ids) x(service_id)
    ),0);

  v_final:=coalesce(p_final_price_cents,v_listed);
  if v_final<0 then raise exception 'Valor inválido'; end if;
  if v_final<>v_listed
     and m.role not in ('owner','admin')
     and not barberium.permission_enabled(perms,'edit_value')
  then raise exception 'Sem permissão para alterar valor'; end if;

  v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo');
  v_end:=v_start+make_interval(mins=>v_duration);

  if v_start<now() then raise exception 'Não é possível criar horário no passado'; end if;

  if exists(
    select 1 from public.appointments a
    where a.professional_id=v_prof.id
      and a.status='confirmed'
      and a.blocks_schedule
      and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
  ) then raise exception 'Horário ocupado'; end if;

  if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then
    raise exception 'Horário bloqueado';
  end if;

  begin
    insert into public.appointments(
      barbershop_id,unit_id,professional_id,customer_id,service_id,
      starts_at,ends_at,base_price_cents,total_price_cents,listed_price_cents,
      manual_adjustment_cents,internal_note,created_by_member_id
    )
    values(
      m.barbershop_id,v_prof.unit_id,v_prof.id,v_customer.id,v_service.id,
      v_start,v_end,v_base,v_final,v_listed,
      v_final-v_listed,nullif(trim(coalesce(p_internal_note,'')),''),m.member_id
    )
    returning * into v_appt;
  exception when exclusion_violation then
    raise exception 'Horário ocupado';
  end;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    v_appt.id,ad.id,ad.name,
    barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),
    barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id),
    'addon'
  from public.service_addons a
  join public.services ad on ad.id=a.addon_service_id
  where a.base_service_id=v_service.id
    and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[]))
    and a.is_active;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    v_appt.id,es.id,es.name,
    barberium.effective_service_price(v_prof.id,es.id),
    barberium.effective_service_duration(v_prof.id,es.id),
    'service'
  from unnest(v_extra_ids) x(service_id)
  join public.services es on es.id=x.service_id;

  insert into public.appointment_events(
    barbershop_id,appointment_id,actor_member_id,event_type,details
  )
  values(
    m.barbershop_id,v_appt.id,m.member_id,'created',
    jsonb_build_object(
      'professional',v_prof.name,
      'service',v_service.name,
      'extra_service_ids',to_jsonb(v_extra_ids),
      'starts_at',v_start,
      'total_price_cents',v_final
    )
  );

  return jsonb_build_object('ok',true,'appointment_id',v_appt.id);
end
$function$;

create or replace function public.barberium_staff_create_walk_in_v12_12(
  p_customer_id uuid,
  p_full_name text,
  p_phone text,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_time time without time zone,
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
  perms jsonb;
  v_prof public.professionals;
  v_service public.services;
  v_customer public.customers;
  v_b public.barbershops;
  v_phone text;
  v_duration int;
  v_base int;
  v_listed int;
  v_final int;
  v_start timestamptz;
  v_end timestamptz;
  v_appt public.appointments;
  v_extra_ids uuid[];
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  perms:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then
    raise exception 'Sem permissão para criar agendamentos';
  end if;
  if m.role='barber' and p_professional_id is distinct from m.professional_id then
    raise exception 'Encaixe permitido somente na própria agenda';
  end if;

  select * into v_prof from public.professionals
  where id=p_professional_id and barbershop_id=m.barbershop_id and is_active;
  if not found then raise exception 'Profissional inválido'; end if;

  select * into v_service from public.services
  where id=p_service_id and unit_id=v_prof.unit_id and is_active;
  if not found then raise exception 'Serviço inválido'; end if;
  if not barberium.professional_service_allowed(v_prof.id,v_service.id) then
    raise exception 'Profissional não vinculado ao serviço';
  end if;

  select coalesce(array_agg(distinct x.service_id order by x.service_id),'{}'::uuid[])
  into v_extra_ids
  from unnest(coalesce(p_extra_service_ids,'{}'::uuid[])) as x(service_id);

  if p_service_id=any(v_extra_ids) then raise exception 'O serviço principal não pode ser adicionado novamente'; end if;
  if exists(
    select 1 from unnest(v_extra_ids) x(service_id)
    where x.service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[]))
  ) then raise exception 'O mesmo item não pode ser serviço e adicional'; end if;

  if exists(
    select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    where not exists(
      select 1 from public.service_addons a
      where a.base_service_id=p_service_id and a.addon_service_id=x.service_id and a.is_active
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Adicional inválido para este profissional'; end if;

  if exists(
    select 1 from unnest(v_extra_ids) x(service_id)
    where not exists(
      select 1 from public.services es
      where es.id=x.service_id
        and es.unit_id=v_prof.unit_id
        and es.is_active
        and es.service_kind in ('service','combo')
        and coalesce((es.settings->>'draft')::boolean,false)=false
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Serviço adicional inválido para este profissional'; end if;

  if p_customer_id is not null then
    select * into v_customer from public.customers
    where id=p_customer_id and barbershop_id=m.barbershop_id;
    if not found then raise exception 'Cliente inválido'; end if;
  else
    if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'Informe o nome do cliente'; end if;
    v_phone:=barberium.normalize_phone(p_phone);
    if v_phone is null then raise exception 'Informe um WhatsApp válido'; end if;
    select * into v_customer from public.customers
    where barbershop_id=m.barbershop_id and phone_e164=v_phone;
    if found then
      update public.customers
      set full_name=trim(p_full_name),updated_at=now()
      where id=v_customer.id
      returning * into v_customer;
    else
      insert into public.customers(barbershop_id,full_name,phone_e164)
      values(m.barbershop_id,trim(p_full_name),v_phone)
      returning * into v_customer;
    end if;
  end if;

  if p_internal_note is not null and trim(p_internal_note)<>''
     and m.role not in ('owner','admin')
     and not barberium.permission_enabled(perms,'edit_internal_note')
  then raise exception 'Sem permissão para observação interna'; end if;

  select * into v_b from public.barbershops where id=m.barbershop_id;

  v_duration:=
    barberium.effective_service_duration(v_prof.id,v_service.id)
    +coalesce((
      select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x.service_id))
      from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_duration(v_prof.id,x.service_id))
      from unnest(v_extra_ids) x(service_id)
    ),0);

  v_base:=barberium.effective_service_price(v_prof.id,v_service.id);
  v_listed:=
    v_base
    +coalesce((
      select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x.service_id))
      from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_price(v_prof.id,x.service_id))
      from unnest(v_extra_ids) x(service_id)
    ),0);

  v_final:=coalesce(p_final_price_cents,v_listed);
  if v_final<0 then raise exception 'Valor inválido'; end if;
  if v_final<>v_listed
     and m.role not in ('owner','admin')
     and not barberium.permission_enabled(perms,'edit_value')
  then raise exception 'Sem permissão para alterar valor'; end if;

  v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo');
  v_end:=v_start+make_interval(mins=>v_duration);

  begin
    insert into public.appointments(
      barbershop_id,unit_id,professional_id,customer_id,service_id,
      starts_at,ends_at,base_price_cents,total_price_cents,listed_price_cents,
      manual_adjustment_cents,internal_note,created_by_member_id,is_walk_in,blocks_schedule
    )
    values(
      m.barbershop_id,v_prof.unit_id,v_prof.id,v_customer.id,v_service.id,
      v_start,v_end,v_base,v_final,v_listed,
      v_final-v_listed,nullif(trim(coalesce(p_internal_note,'')),''),m.member_id,
      true,coalesce(p_blocks_schedule,false)
    )
    returning * into v_appt;
  exception when exclusion_violation then
    raise exception 'Horário ocupado';
  end;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    v_appt.id,ad.id,ad.name,
    barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),
    barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id),
    'addon'
  from public.service_addons a
  join public.services ad on ad.id=a.addon_service_id
  where a.base_service_id=v_service.id
    and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[]))
    and a.is_active;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    v_appt.id,es.id,es.name,
    barberium.effective_service_price(v_prof.id,es.id),
    barberium.effective_service_duration(v_prof.id,es.id),
    'service'
  from unnest(v_extra_ids) x(service_id)
  join public.services es on es.id=x.service_id;

  insert into public.appointment_events(
    barbershop_id,appointment_id,actor_member_id,event_type,details
  )
  values(
    m.barbershop_id,v_appt.id,m.member_id,'created',
    jsonb_build_object(
      'professional',v_prof.name,
      'service',v_service.name,
      'extra_service_ids',to_jsonb(v_extra_ids),
      'starts_at',v_start,
      'total_price_cents',v_final,
      'is_walk_in',true,
      'blocks_schedule',coalesce(p_blocks_schedule,false)
    )
  );

  return jsonb_build_object('ok',true,'appointment_id',v_appt.id);
end
$function$;

create or replace function public.barberium_staff_update_appointment_v12_12(
  p_appointment_id uuid,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_time time without time zone,
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
  perms jsonb;
  olda public.appointments;
  v_prof public.professionals;
  v_service public.services;
  v_b public.barbershops;
  old_addons uuid[];
  new_addons uuid[];
  old_extras uuid[];
  new_extras uuid[];
  v_duration int;
  v_base int;
  v_listed int;
  v_final int;
  v_start timestamptz;
  v_end timestamptz;
  old_date date;
  old_time time;
  service_changed boolean;
  addons_changed boolean;
  extra_services_changed boolean;
  professional_changed boolean;
  date_changed boolean;
  time_changed boolean;
  value_changed boolean;
  note_changed boolean;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  perms:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  select * into olda from public.appointments where id=p_appointment_id for update;
  if olda.id is null or olda.barbershop_id<>m.barbershop_id then
    raise exception 'Agendamento não encontrado';
  end if;
  if m.role='barber' and olda.professional_id<>m.professional_id then
    raise exception 'Sem permissão para este agendamento';
  end if;
  if m.role='barber' and p_professional_id<>m.professional_id then
    raise exception 'Barbeiro não pode transferir atendimento';
  end if;

  select coalesce(array_agg(service_id order by service_id),'{}'::uuid[])
  into old_addons
  from public.appointment_addons
  where appointment_id=olda.id and item_kind='addon';

  select coalesce(array_agg(service_id order by service_id),'{}'::uuid[])
  into old_extras
  from public.appointment_addons
  where appointment_id=olda.id and item_kind='service';

  select coalesce(array_agg(distinct x order by x),'{}'::uuid[])
  into new_addons
  from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x;

  select coalesce(array_agg(distinct x order by x),'{}'::uuid[])
  into new_extras
  from unnest(coalesce(p_extra_service_ids,'{}'::uuid[])) x;

  select * into v_prof from public.professionals
  where id=p_professional_id and barbershop_id=m.barbershop_id and is_active;
  if not found then raise exception 'Profissional inválido'; end if;

  select * into v_service from public.services
  where id=p_service_id and unit_id=v_prof.unit_id and is_active;
  if not found then raise exception 'Serviço inválido'; end if;
  if not barberium.professional_service_allowed(v_prof.id,v_service.id) then
    raise exception 'Profissional não vinculado ao serviço';
  end if;

  if p_service_id=any(new_extras) then raise exception 'O serviço principal não pode ser adicionado novamente'; end if;
  if exists(
    select 1 from unnest(new_extras) x(service_id)
    where x.service_id=any(new_addons)
  ) then raise exception 'O mesmo item não pode ser serviço e adicional'; end if;

  if exists(
    select 1 from unnest(new_addons) x(service_id)
    where not exists(
      select 1 from public.service_addons a
      where a.base_service_id=p_service_id and a.addon_service_id=x.service_id and a.is_active
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Adicional inválido para este profissional'; end if;

  if exists(
    select 1 from unnest(new_extras) x(service_id)
    where not exists(
      select 1 from public.services es
      where es.id=x.service_id
        and es.unit_id=v_prof.unit_id
        and es.is_active
        and es.service_kind in ('service','combo')
        and coalesce((es.settings->>'draft')::boolean,false)=false
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Serviço adicional inválido para este profissional'; end if;

  select * into v_b from public.barbershops where id=m.barbershop_id;

  old_date:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::date;
  old_time:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::time;

  service_changed:=olda.service_id<>p_service_id;
  addons_changed:=old_addons<>new_addons;
  extra_services_changed:=old_extras<>new_extras;
  professional_changed:=olda.professional_id<>p_professional_id;
  date_changed:=old_date<>p_date;
  time_changed:=old_time<>p_time;
  note_changed:=coalesce(olda.internal_note,'')<>coalesce(nullif(trim(coalesce(p_internal_note,'')),''),'');

  if m.role='barber' then
    if (service_changed or extra_services_changed) and not barberium.permission_enabled(perms,'edit_service') then
      raise exception 'Sem permissão para alterar serviço';
    end if;
    if addons_changed and not barberium.permission_enabled(perms,'edit_addons') then
      raise exception 'Sem permissão para alterar adicionais';
    end if;
    if date_changed and not barberium.permission_enabled(perms,'edit_date') then
      raise exception 'Sem permissão para alterar data';
    end if;
    if time_changed and not barberium.permission_enabled(perms,'edit_time') then
      raise exception 'Sem permissão para alterar horário';
    end if;
    if note_changed and not barberium.permission_enabled(perms,'edit_internal_note') then
      raise exception 'Sem permissão para alterar observação';
    end if;
  end if;

  v_duration:=
    barberium.effective_service_duration(v_prof.id,v_service.id)
    +coalesce((
      select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x.service_id))
      from unnest(new_addons) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_duration(v_prof.id,x.service_id))
      from unnest(new_extras) x(service_id)
    ),0);

  v_base:=barberium.effective_service_price(v_prof.id,v_service.id);
  v_listed:=
    v_base
    +coalesce((
      select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x.service_id))
      from unnest(new_addons) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_price(v_prof.id,x.service_id))
      from unnest(new_extras) x(service_id)
    ),0);

  if m.role in ('owner','admin') or barberium.permission_enabled(perms,'edit_value') then
    v_final:=coalesce(p_final_price_cents,v_listed);
  else
    v_final:=case
      when service_changed or addons_changed or extra_services_changed then v_listed
      else olda.total_price_cents
    end;
    if p_final_price_cents is not null and p_final_price_cents<>v_final then
      raise exception 'Sem permissão para alterar valor';
    end if;
  end if;

  if v_final<0 then raise exception 'Valor inválido'; end if;
  value_changed:=olda.total_price_cents<>v_final;

  v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo');
  v_end:=v_start+make_interval(mins=>v_duration);

  if olda.status='confirmed' and not olda.is_walk_in then
    if exists(
      select 1 from public.appointments a
      where a.professional_id=v_prof.id
        and a.status='confirmed'
        and a.blocks_schedule
        and a.id<>olda.id
        and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
    ) then raise exception 'Horário ocupado'; end if;

    if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then
      raise exception 'Horário bloqueado';
    end if;
  end if;

  begin
    update public.appointments
    set professional_id=v_prof.id,
        unit_id=v_prof.unit_id,
        service_id=v_service.id,
        starts_at=v_start,
        ends_at=v_end,
        base_price_cents=v_base,
        listed_price_cents=v_listed,
        total_price_cents=v_final,
        manual_adjustment_cents=v_final-v_listed,
        internal_note=nullif(trim(coalesce(p_internal_note,'')),''),
        updated_at=now()
    where id=olda.id;
  exception when exclusion_violation then
    raise exception 'Horário ocupado';
  end;

  delete from public.appointment_addons where appointment_id=olda.id;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    olda.id,ad.id,ad.name,
    barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),
    barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id),
    'addon'
  from public.service_addons a
  join public.services ad on ad.id=a.addon_service_id
  where a.base_service_id=v_service.id
    and a.addon_service_id=any(new_addons)
    and a.is_active;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    olda.id,es.id,es.name,
    barberium.effective_service_price(v_prof.id,es.id),
    barberium.effective_service_duration(v_prof.id,es.id),
    'service'
  from unnest(new_extras) x(service_id)
  join public.services es on es.id=x.service_id;

  insert into public.appointment_events(
    barbershop_id,appointment_id,actor_member_id,event_type,details
  )
  values(
    m.barbershop_id,olda.id,m.member_id,'edited',
    jsonb_build_object(
      'professional_changed',professional_changed,
      'old_professional_id',olda.professional_id,
      'new_professional_id',v_prof.id,
      'service_changed',service_changed,
      'old_service_id',olda.service_id,
      'new_service_id',v_service.id,
      'addons_changed',addons_changed,
      'extra_services_changed',extra_services_changed,
      'old_extra_service_ids',to_jsonb(old_extras),
      'new_extra_service_ids',to_jsonb(new_extras),
      'date_changed',date_changed,
      'time_changed',time_changed,
      'value_changed',value_changed,
      'note_changed',note_changed,
      'old_starts_at',olda.starts_at,
      'new_starts_at',v_start,
      'old_total_price_cents',olda.total_price_cents,
      'new_total_price_cents',v_final
    )
  );

  return jsonb_build_object('ok',true,'appointment_id',olda.id);
end
$function$;

create or replace function public.barberium_staff_update_walk_in_v12_12(
  p_appointment_id uuid,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_extra_service_ids uuid[],
  p_date date,
  p_time time without time zone,
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
  v_result jsonb;
  v_old public.appointments;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;

  select * into v_old from public.appointments
  where id=p_appointment_id
  for update;

  if v_old.id is null or not v_old.is_walk_in or v_old.status<>'confirmed' then
    raise exception 'Encaixe não disponível para edição';
  end if;

  v_result:=public.barberium_staff_update_appointment_v12_12(
    p_appointment_id,p_professional_id,p_service_id,p_addon_service_ids,
    p_extra_service_ids,p_date,p_time,p_final_price_cents,p_internal_note
  );

  update public.appointments
  set blocks_schedule=coalesce(p_blocks_schedule,false)
  where id=p_appointment_id;

  return v_result;
end
$function$;

create or replace function public.barberium_staff_appointment_detail(p_appointment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  perms jsonb;
  a public.appointments%rowtype;
  c public.customers;
  p public.professionals;
  s public.services;
  show_phone boolean;
  show_full boolean;
  show_value boolean;
  show_note boolean;
  show_birthday boolean;
  show_history boolean;
  v_service_label text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  perms:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  select * into a from public.appointments where id=p_appointment_id;
  if a.id is null or a.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if;
  if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if;

  select * into c from public.customers where id=a.customer_id;
  select * into p from public.professionals where id=a.professional_id;
  select * into s from public.services where id=a.service_id;

  show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_phone');
  show_full:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_full_name');
  show_value:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_value');
  show_note:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_internal_note');
  show_birthday:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_birthday');
  show_history:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_customer_history');

  v_service_label:=concat_ws(
    ' + ',
    coalesce(a.service_name_snapshot,s.name),
    nullif((
      select string_agg(aa.name_snapshot,' + ' order by aa.name_snapshot)
      from public.appointment_addons aa
      where aa.appointment_id=a.id and aa.item_kind='service'
    ),'')
  );

  return jsonb_build_object(
    'id',a.id,
    'is_walk_in',a.is_walk_in,
    'blocks_schedule',a.blocks_schedule,
    'status',a.status,
    'starts_at',a.starts_at,
    'ends_at',a.ends_at,
    'customer',jsonb_build_object(
      'id',c.id,
      'name',barberium.mask_customer_name(c.full_name,show_full),
      'phone',case when show_phone then c.phone_e164 else null end,
      'birthday',case when show_birthday then c.birthday else null end
    ),
    'professional',jsonb_build_object(
      'id',p.id,
      'name',coalesce(a.professional_name_snapshot,p.name)
    ),
    'service',jsonb_build_object(
      'id',s.id,
      'name',v_service_label,
      'primary_name',coalesce(a.service_name_snapshot,s.name),
      'duration_min',coalesce(a.service_duration_min_snapshot,s.duration_min)
    ),
    'extra_services',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'service_id',aa.service_id,
          'name',aa.name_snapshot,
          'price_cents',case when show_value then aa.price_cents else null end,
          'duration_min',aa.duration_min
        )
        order by aa.name_snapshot
      )
      from public.appointment_addons aa
      where aa.appointment_id=a.id and aa.item_kind='service'
    ),'[]'::jsonb),
    'unit',jsonb_build_object(
      'id',a.unit_id,
      'name',coalesce(a.unit_name_snapshot,(select u.name from public.units u where u.id=a.unit_id))
    ),
    'addons',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'service_id',aa.service_id,
          'name',aa.name_snapshot,
          'price_cents',case when show_value then aa.price_cents else null end,
          'duration_min',aa.duration_min
        )
        order by aa.name_snapshot
      )
      from public.appointment_addons aa
      where aa.appointment_id=a.id and aa.item_kind='addon'
    ),'[]'::jsonb),
    'listed_price_cents',case when show_value then coalesce(a.listed_price_cents,a.total_price_cents) else null end,
    'manual_adjustment_cents',case when show_value then a.manual_adjustment_cents else null end,
    'total_price_cents',case when show_value then a.total_price_cents else null end,
    'internal_note',case when show_note then a.internal_note else null end,
    'permissions',perms,
    'customer_stats',case when show_history then (
      select jsonb_build_object(
        'appointments',count(*),
        'completed',count(*) filter(where status='completed'),
        'cancelled',count(*) filter(where status='cancelled'),
        'no_show',count(*) filter(where status='no_show'),
        'spent_cents',coalesce(sum(total_price_cents) filter(where status='completed'),0)
      )
      from public.appointments ca
      where ca.customer_id=c.id
    ) else null end,
    'events',case when m.role in ('owner','admin') then coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'event_type',e.event_type,
          'details',e.details,
          'created_at',e.created_at,
          'actor',coalesce(ap.name,au.email,'Sistema')
        )
        order by e.created_at desc
      )
      from public.appointment_events e
      left join public.barbershop_members bm on bm.id=e.actor_member_id
      left join public.professionals ap on ap.id=bm.professional_id
      left join auth.users au on au.id=bm.auth_user_id
      where e.appointment_id=a.id
    ),'[]'::jsonb) else '[]'::jsonb end
  );
end
$function$;

create or replace function public.barberium_staff_dashboard(
  p_date date default current_date,
  p_professional_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  v_permissions jsonb;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_filter_prof uuid;
  v_appointments jsonb;
  v_blocks jsonb;
  v_summary jsonb;
  v_show_phone boolean;
  v_show_full boolean;
  v_show_value boolean;
  v_show_note boolean;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  v_permissions:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  v_show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_phone');
  v_show_full:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_full_name');
  v_show_value:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_value');
  v_show_note:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_internal_note');

  if m.role in ('owner','admin') then
    if p_professional_id is not null and not exists(
      select 1 from public.professionals p
      where p.id=p_professional_id and p.barbershop_id=m.barbershop_id and p.is_active
    ) then raise exception 'Profissional inválido'; end if;
    v_filter_prof:=p_professional_id;
  else
    v_filter_prof:=m.professional_id;
  end if;

  select coalesce(timezone,'America/Sao_Paulo')
  into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  v_start:=p_date::timestamp at time zone v_tz;
  v_end:=(p_date+1)::timestamp at time zone v_tz;

  select coalesce(jsonb_agg(x order by (x->>'starts_at')::timestamptz),'[]'::jsonb)
  into v_appointments
  from (
    select jsonb_build_object(
      'kind','appointment',
      'id',a.id,
      'is_walk_in',a.is_walk_in,
      'blocks_schedule',a.blocks_schedule,
      'starts_at',a.starts_at,
      'ends_at',a.ends_at,
      'status',a.status,
      'service_id',s.id,
      'service',concat_ws(
        ' + ',
        coalesce(a.service_name_snapshot,s.name),
        nullif((
          select string_agg(aa.name_snapshot,' + ' order by aa.name_snapshot)
          from public.appointment_addons aa
          where aa.appointment_id=a.id and aa.item_kind='service'
        ),'')
      ),
      'extra_services',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'service_id',aa.service_id,
            'name',aa.name_snapshot,
            'price_cents',case when v_show_value then aa.price_cents else null end,
            'duration_min',aa.duration_min
          )
          order by aa.name_snapshot
        )
        from public.appointment_addons aa
        where aa.appointment_id=a.id and aa.item_kind='service'
      ),'[]'::jsonb),
      'professional_id',p.id,
      'professional',coalesce(a.professional_name_snapshot,p.name),
      'customer',barberium.mask_customer_name(c.full_name,v_show_full),
      'phone',case when v_show_phone then c.phone_e164 else null end,
      'total_price_cents',case when v_show_value then a.total_price_cents else null end,
      'internal_note',case when v_show_note then a.internal_note else null end,
      'addons',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'service_id',aa.service_id,
            'name',aa.name_snapshot,
            'price_cents',case when v_show_value then aa.price_cents else null end,
            'duration_min',aa.duration_min
          )
          order by aa.name_snapshot
        )
        from public.appointment_addons aa
        where aa.appointment_id=a.id and aa.item_kind='addon'
      ),'[]'::jsonb)
    ) x
    from public.appointments a
    join public.services s on s.id=a.service_id
    join public.professionals p on p.id=a.professional_id
    join public.customers c on c.id=a.customer_id
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and (v_filter_prof is null or a.professional_id=v_filter_prof)
  ) q;

  select coalesce(jsonb_agg(x order by (x->>'starts_at')::timestamptz),'[]'::jsonb)
  into v_blocks
  from (
    select jsonb_build_object(
      'kind','block','block_type','single','id',bt.id,
      'starts_at',bt.starts_at,'ends_at',bt.ends_at,'reason',bt.reason,
      'professional_id',p.id,'professional',p.name,'recurring',false
    ) x
    from public.blocked_times bt
    join public.professionals p on p.id=bt.professional_id
    where bt.barbershop_id=m.barbershop_id
      and bt.starts_at<v_end and bt.ends_at>v_start
      and (v_filter_prof is null or bt.professional_id=v_filter_prof)
    union all
    select jsonb_build_object(
      'kind','block','block_type','recurring','id',bs.id,
      'starts_at',(p_date::timestamp+bs.start_time) at time zone v_tz,
      'ends_at',(p_date::timestamp+bs.end_time) at time zone v_tz,
      'reason',bs.reason,'professional_id',p.id,'professional',p.name,
      'recurring',true,'starts_on',bs.starts_on,'ends_on',bs.ends_on
    ) x
    from public.blocked_time_series bs
    join public.professionals p on p.id=bs.professional_id
    where bs.barbershop_id=m.barbershop_id
      and bs.is_active
      and p_date>=bs.starts_on
      and (bs.ends_on is null or p_date<=bs.ends_on)
      and bs.weekday=extract(dow from p_date)::int
      and (v_filter_prof is null or bs.professional_id=v_filter_prof)
  ) q;

  select jsonb_build_object(
    'total',count(*),
    'confirmed',count(*) filter(where status='confirmed'),
    'completed',count(*) filter(where status='completed'),
    'cancelled',count(*) filter(where status='cancelled'),
    'no_show',count(*) filter(where status='no_show'),
    'scheduled_revenue_cents',case
      when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue')
      then coalesce(sum(total_price_cents) filter(where status='confirmed'),0)
      else null end,
    'realized_revenue_cents',case
      when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue')
      then coalesce(sum(total_price_cents) filter(where status='completed'),0)
      else null end,
    'revenue_cents',case
      when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue')
      then coalesce(sum(total_price_cents) filter(where status in ('confirmed','completed')),0)
      else null end
  )
  into v_summary
  from public.appointments a
  where a.barbershop_id=m.barbershop_id
    and a.starts_at>=v_start
    and a.starts_at<v_end
    and (v_filter_prof is null or a.professional_id=v_filter_prof);

  return jsonb_build_object(
    'date',p_date,
    'filter_professional_id',v_filter_prof,
    'member',jsonb_build_object(
      'role',m.role,
      'professional_id',m.professional_id,
      'professional_name',m.professional_name,
      'permissions',v_permissions
    ),
    'summary',v_summary,
    'appointments',v_appointments,
    'blocks',v_blocks
  );
end
$function$;

do $patch$
declare
  v_def text;
  v_old text := $old$
 if v_old.is_walk_in then raise exception 'Para alterar um encaixe, fale com a equipe';end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
$old$;
  v_new text := $new$
 if v_old.is_walk_in then raise exception 'Para alterar um encaixe, fale com a equipe';end if;
 if exists(select 1 from public.appointment_addons aa where aa.appointment_id=v_old.id and aa.item_kind='service') then
   raise exception 'Para alterar um agendamento com mais de um serviço, fale com a equipe';
 end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
$new$;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='barberium_reschedule_appointment';

  if v_def is null then raise exception 'Função de reagendamento não encontrada'; end if;
  if position(v_old in v_def)=0 then raise exception 'Trecho alvo do reagendamento não encontrado'; end if;

  execute replace(v_def,v_old,v_new);
end
$patch$;

revoke all on function public.barberium_staff_available_slots_v12_12(uuid,uuid,uuid[],uuid[],date,uuid) from public,anon;
revoke all on function public.barberium_staff_create_appointment_v12_12(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time,integer,text) from public,anon;
revoke all on function public.barberium_staff_create_walk_in_v12_12(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time,integer,text,boolean) from public,anon;
revoke all on function public.barberium_staff_update_appointment_v12_12(uuid,uuid,uuid,uuid[],uuid[],date,time,integer,text) from public,anon;
revoke all on function public.barberium_staff_update_walk_in_v12_12(uuid,uuid,uuid,uuid[],uuid[],date,time,integer,text,boolean) from public,anon;

grant execute on function public.barberium_staff_available_slots_v12_12(uuid,uuid,uuid[],uuid[],date,uuid) to authenticated,service_role;
grant execute on function public.barberium_staff_create_appointment_v12_12(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time,integer,text) to authenticated,service_role;
grant execute on function public.barberium_staff_create_walk_in_v12_12(uuid,text,text,uuid,uuid,uuid[],uuid[],date,time,integer,text,boolean) to authenticated,service_role;
grant execute on function public.barberium_staff_update_appointment_v12_12(uuid,uuid,uuid,uuid[],uuid[],date,time,integer,text) to authenticated,service_role;
grant execute on function public.barberium_staff_update_walk_in_v12_12(uuid,uuid,uuid,uuid[],uuid[],date,time,integer,text,boolean) to authenticated,service_role;

