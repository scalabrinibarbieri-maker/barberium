create or replace function public.barberium_staff_appointment_detail(p_appointment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record; perms jsonb; a public.appointments%rowtype; c public.customers; p public.professionals; s public.services;
  show_phone boolean; show_full boolean; show_value boolean; show_note boolean; show_birthday boolean; show_history boolean;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
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
  return jsonb_build_object(
    'id',a.id,'status',a.status,'starts_at',a.starts_at,'ends_at',a.ends_at,
    'customer',jsonb_build_object('id',c.id,'name',barberium.mask_customer_name(c.full_name,show_full),'phone',case when show_phone then c.phone_e164 else null end,'birthday',case when show_birthday then c.birthday else null end),
    'professional',jsonb_build_object('id',p.id,'name',p.name),
    'service',jsonb_build_object('id',s.id,'name',s.name),
    'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',case when show_value then aa.price_cents else null end,'duration_min',aa.duration_min) order by aa.name_snapshot) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb),
    'listed_price_cents',case when show_value then coalesce(a.listed_price_cents,a.total_price_cents) else null end,
    'manual_adjustment_cents',case when show_value then a.manual_adjustment_cents else null end,
    'total_price_cents',case when show_value then a.total_price_cents else null end,
    'internal_note',case when show_note then a.internal_note else null end,
    'permissions',perms,
    'customer_stats',case when show_history then (select jsonb_build_object('appointments',count(*),'completed',count(*) filter(where status='completed'),'cancelled',count(*) filter(where status='cancelled'),'no_show',count(*) filter(where status='no_show'),'spent_cents',coalesce(sum(total_price_cents) filter(where status='completed'),0)) from public.appointments ca where ca.customer_id=c.id) else null end,
    'events',case when m.role in ('owner','admin') then coalesce((select jsonb_agg(jsonb_build_object('event_type',e.event_type,'details',e.details,'created_at',e.created_at,'actor',coalesce(ap.name,au.email,'Sistema')) order by e.created_at desc) from public.appointment_events e left join public.barbershop_members bm on bm.id=e.actor_member_id left join public.professionals ap on ap.id=bm.professional_id left join auth.users au on au.id=bm.auth_user_id where e.appointment_id=a.id),'[]'::jsonb) else '[]'::jsonb end
  );
end;
$$;

create or replace function public.barberium_staff_team()
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'professional_id',p.id,'name',p.name,'image_path',p.image_path,'is_active',p.is_active,
    'login_active',coalesce(bm.is_active,false),'login_email',u.email,
    'permissions',barberium.effective_permissions(p.id)
  ) order by p.sort_order,p.name)
  from public.professionals p
  left join public.barbershop_members bm on bm.professional_id=p.id and bm.barbershop_id=m.barbershop_id
  left join auth.users u on u.id=bm.auth_user_id
  where p.barbershop_id=m.barbershop_id),'[]'::jsonb);
end;
$$;

create or replace function public.barberium_staff_set_permissions(p_professional_id uuid,p_permissions jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; clean jsonb; k text; allowed text[]:=array['create_appointment','cancel_appointment','edit_service','edit_addons','edit_date','edit_time','edit_value','create_block','create_recurring_block','edit_internal_note','mark_completed','mark_no_show','view_phone','view_full_name','view_value','view_internal_note','view_customer_history','view_birthday','view_own_revenue'];
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  clean:='{}'::jsonb;
  foreach k in array allowed loop
    clean:=clean||jsonb_build_object(k,coalesce((p_permissions->>k)::boolean,false));
  end loop;
  insert into public.professional_permissions(professional_id,barbershop_id,permissions,updated_at)
  values(p_professional_id,m.barbershop_id,clean,now())
  on conflict(professional_id) do update set permissions=excluded.permissions,updated_at=now();
  return jsonb_build_object('ok',true,'permissions',clean);
end;
$$;

create or replace function public.barberium_staff_create_block(
  p_professional_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_reason text default null,
  p_recurring boolean default false,
  p_ends_on date default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; perms jsonb; prof public.professionals; b public.barbershops; v_start timestamptz; v_end timestamptz; v_id uuid; v_weekday int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_start_time>=p_end_time then raise exception 'Horário de bloqueio inválido'; end if;
  if p_ends_on is not null and p_ends_on<p_date then raise exception 'Data final inválida'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if m.role='barber' then
    p_professional_id:=m.professional_id;
    if p_recurring and not barberium.permission_enabled(perms,'create_recurring_block') then raise exception 'Sem permissão para bloqueio recorrente'; end if;
    if not p_recurring and not barberium.permission_enabled(perms,'create_block') then raise exception 'Sem permissão para bloquear horário'; end if;
  end if;
  select * into prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if;
  select * into b from public.barbershops where id=m.barbershop_id;
  v_start:=(p_date::timestamp+p_start_time) at time zone coalesce(b.timezone,'America/Sao_Paulo');
  v_end:=(p_date::timestamp+p_end_time) at time zone coalesce(b.timezone,'America/Sao_Paulo');

  if not p_recurring then
    if exists(select 1 from public.appointments a where a.professional_id=prof.id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Existe atendimento neste período'; end if;
    if barberium.has_block_conflict(prof.unit_id,prof.id,v_start,v_end,null,null) then raise exception 'Já existe bloqueio neste período'; end if;
    insert into public.blocked_times(barbershop_id,unit_id,professional_id,starts_at,ends_at,reason,created_by_member_id,updated_at)
    values(m.barbershop_id,prof.unit_id,prof.id,v_start,v_end,nullif(trim(coalesce(p_reason,'')),''),m.member_id,now()) returning id into v_id;
    return jsonb_build_object('ok',true,'kind','single','id',v_id);
  end if;

  v_weekday:=extract(dow from p_date)::int;
  if exists(
    select 1 from public.appointments a
    where a.professional_id=prof.id and a.status='confirmed'
      and (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::date>=p_date
      and (p_ends_on is null or (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::date<=p_ends_on)
      and extract(dow from (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::date)::int=v_weekday
      and (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::time<p_end_time
      and (a.ends_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::time>p_start_time
  ) then raise exception 'Existe atendimento em uma das repetições'; end if;
  if exists(select 1 from public.blocked_time_series bs where bs.professional_id=prof.id and bs.is_active and bs.weekday=v_weekday and daterange(bs.starts_on,coalesce(bs.ends_on,'infinity'::date),'[]')&&daterange(p_date,coalesce(p_ends_on,'infinity'::date),'[]') and tsrange(p_date::timestamp+bs.start_time,p_date::timestamp+bs.end_time,'[)')&&tsrange(p_date::timestamp+p_start_time,p_date::timestamp+p_end_time,'[)')) then raise exception 'Já existe bloqueio recorrente neste período'; end if;
  insert into public.blocked_time_series(barbershop_id,unit_id,professional_id,weekday,start_time,end_time,starts_on,ends_on,reason,created_by_member_id)
  values(m.barbershop_id,prof.unit_id,prof.id,v_weekday,p_start_time,p_end_time,p_date,p_ends_on,nullif(trim(coalesce(p_reason,'')),''),m.member_id) returning id into v_id;
  return jsonb_build_object('ok',true,'kind','recurring','id',v_id);
end;
$$;

create or replace function public.barberium_staff_update_block(
  p_block_id uuid,
  p_kind text,
  p_professional_id uuid,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_reason text default null,
  p_ends_on date default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; perms jsonb; prof public.professionals; b public.barbershops; v_start timestamptz; v_end timestamptz; owner_prof uuid; v_weekday int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_start_time>=p_end_time then raise exception 'Horário de bloqueio inválido'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if p_kind='single' then select professional_id into owner_prof from public.blocked_times where id=p_block_id and barbershop_id=m.barbershop_id;
  elsif p_kind='recurring' then select professional_id into owner_prof from public.blocked_time_series where id=p_block_id and barbershop_id=m.barbershop_id and is_active;
  else raise exception 'Tipo de bloqueio inválido'; end if;
  if owner_prof is null then raise exception 'Bloqueio não encontrado'; end if;
  if m.role='barber' then
    if owner_prof<>m.professional_id then raise exception 'Sem permissão para este bloqueio'; end if;
    p_professional_id:=m.professional_id;
    if p_kind='single' and not barberium.permission_enabled(perms,'create_block') then raise exception 'Sem permissão para editar bloqueio'; end if;
    if p_kind='recurring' and not barberium.permission_enabled(perms,'create_recurring_block') then raise exception 'Sem permissão para editar bloqueio recorrente'; end if;
  end if;
  select * into prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if;
  select * into b from public.barbershops where id=m.barbershop_id;
  v_start:=(p_date::timestamp+p_start_time) at time zone coalesce(b.timezone,'America/Sao_Paulo'); v_end:=(p_date::timestamp+p_end_time) at time zone coalesce(b.timezone,'America/Sao_Paulo');
  if p_kind='single' then
    if exists(select 1 from public.appointments a where a.professional_id=prof.id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Existe atendimento neste período'; end if;
    if barberium.has_block_conflict(prof.unit_id,prof.id,v_start,v_end,p_block_id,null) then raise exception 'Já existe bloqueio neste período'; end if;
    update public.blocked_times set professional_id=prof.id,unit_id=prof.unit_id,starts_at=v_start,ends_at=v_end,reason=nullif(trim(coalesce(p_reason,'')),''),updated_at=now() where id=p_block_id;
  else
    if p_ends_on is not null and p_ends_on<p_date then raise exception 'Data final inválida'; end if;
    v_weekday:=extract(dow from p_date)::int;
    if exists(select 1 from public.appointments a where a.professional_id=prof.id and a.status='confirmed' and (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::date>=p_date and (p_ends_on is null or (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::date<=p_ends_on) and extract(dow from (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::date)::int=v_weekday and (a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::time<p_end_time and (a.ends_at at time zone coalesce(b.timezone,'America/Sao_Paulo'))::time>p_start_time) then raise exception 'Existe atendimento em uma das repetições'; end if;
    update public.blocked_time_series set professional_id=prof.id,unit_id=prof.unit_id,weekday=v_weekday,start_time=p_start_time,end_time=p_end_time,starts_on=p_date,ends_on=p_ends_on,reason=nullif(trim(coalesce(p_reason,'')),''),updated_at=now() where id=p_block_id;
  end if;
  return jsonb_build_object('ok',true,'id',p_block_id,'kind',p_kind);
end;
$$;

create or replace function public.barberium_staff_delete_block(p_block_id uuid,p_kind text)
returns boolean
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; perms jsonb; owner_prof uuid; n int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if p_kind='single' then select professional_id into owner_prof from public.blocked_times where id=p_block_id and barbershop_id=m.barbershop_id;
  elsif p_kind='recurring' then select professional_id into owner_prof from public.blocked_time_series where id=p_block_id and barbershop_id=m.barbershop_id;
  else raise exception 'Tipo de bloqueio inválido'; end if;
  if owner_prof is null then return false; end if;
  if m.role='barber' then
    if owner_prof<>m.professional_id then raise exception 'Sem permissão para este bloqueio'; end if;
    if p_kind='single' and not barberium.permission_enabled(perms,'create_block') then raise exception 'Sem permissão para remover bloqueio'; end if;
    if p_kind='recurring' and not barberium.permission_enabled(perms,'create_recurring_block') then raise exception 'Sem permissão para remover bloqueio recorrente'; end if;
  end if;
  if p_kind='single' then delete from public.blocked_times where id=p_block_id;
  else update public.blocked_time_series set is_active=false,updated_at=now() where id=p_block_id; end if;
  get diagnostics n=row_count; return n=1;
end;
$$;

revoke all on function public.barberium_staff_appointment_detail(uuid) from public,anon;
revoke all on function public.barberium_staff_team() from public,anon;
revoke all on function public.barberium_staff_set_permissions(uuid,jsonb) from public,anon;
revoke all on function public.barberium_staff_create_block(uuid,date,time,time,text,boolean,date) from public,anon;
revoke all on function public.barberium_staff_update_block(uuid,text,uuid,date,time,time,text,date) from public,anon;
revoke all on function public.barberium_staff_delete_block(uuid,text) from public,anon;
grant execute on function public.barberium_staff_appointment_detail(uuid) to authenticated;
grant execute on function public.barberium_staff_team() to authenticated;
grant execute on function public.barberium_staff_set_permissions(uuid,jsonb) to authenticated;
grant execute on function public.barberium_staff_create_block(uuid,date,time,time,text,boolean,date) to authenticated;
grant execute on function public.barberium_staff_update_block(uuid,text,uuid,date,time,time,text,date) to authenticated;
grant execute on function public.barberium_staff_delete_block(uuid,text) to authenticated;

