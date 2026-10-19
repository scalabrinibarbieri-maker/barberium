create or replace function public.barberium_staff_search_customers(p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; perms jsonb; show_phone boolean; show_full boolean; show_birthday boolean; q text; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then raise exception 'Sem permissão para criar agendamentos'; end if;
  show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_phone');
  show_full:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_full_name');
  show_birthday:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_birthday');
  q:=trim(coalesce(p_query,''));
  select coalesce(jsonb_agg(x order by x->>'name'),'[]'::jsonb) into result
  from (
    select jsonb_build_object('id',c.id,'name',barberium.mask_customer_name(c.full_name,show_full),'phone',case when show_phone then c.phone_e164 else null end,'birthday',case when show_birthday then c.birthday else null end) x
    from public.customers c
    where c.barbershop_id=m.barbershop_id and (q='' or c.full_name ilike '%'||q||'%' or c.phone_e164 like '%'||regexp_replace(q,'\D','','g')||'%')
    order by c.full_name limit 20
  ) s;
  return result;
end;
$$;

create or replace function public.barberium_staff_create_appointment(
  p_customer_id uuid,
  p_full_name text,
  p_phone text,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_date date,
  p_time time,
  p_final_price_cents integer default null,
  p_internal_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record; perms jsonb; v_prof public.professionals; v_service public.services; v_customer public.customers; v_b public.barbershops;
  v_phone text; v_duration int; v_base int; v_listed int; v_final int; v_start timestamptz; v_end timestamptz; v_appt public.appointments;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then raise exception 'Sem permissão para criar agendamentos'; end if;

  if m.role='barber' then p_professional_id:=m.professional_id; end if;
  select * into v_prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active;
  if not found then raise exception 'Profissional inválido'; end if;
  select * into v_service from public.services where id=p_service_id and unit_id=v_prof.unit_id and is_active;
  if not found then raise exception 'Serviço inválido'; end if;
  if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'Adicional inválido'; end if;

  if p_customer_id is not null then
    select * into v_customer from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id;
    if not found then raise exception 'Cliente inválido'; end if;
  else
    if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'Informe o nome do cliente'; end if;
    v_phone:=barberium.normalize_phone(p_phone); if v_phone is null then raise exception 'Informe um WhatsApp válido'; end if;
    select * into v_customer from public.customers where barbershop_id=m.barbershop_id and phone_e164=v_phone;
    if found then
      update public.customers set full_name=trim(p_full_name),updated_at=now() where id=v_customer.id returning * into v_customer;
    else
      insert into public.customers(barbershop_id,full_name,phone_e164) values(m.barbershop_id,trim(p_full_name),v_phone) returning * into v_customer;
    end if;
  end if;

  if p_internal_note is not null and trim(p_internal_note)<>'' and m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'edit_internal_note') then raise exception 'Sem permissão para observação interna'; end if;

  select * into v_b from public.barbershops where id=m.barbershop_id;
  v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=v_prof.id and service_id=v_service.id),v_service.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=v_service.id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
  v_base:=coalesce((select custom_price_cents from public.professional_services where professional_id=v_prof.id and service_id=v_service.id),v_service.price_cents);
  v_listed:=v_base+coalesce((select sum(a.addon_price_cents) from public.service_addons a where a.base_service_id=v_service.id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
  v_final:=coalesce(p_final_price_cents,v_listed);
  if v_final<0 then raise exception 'Valor inválido'; end if;
  if v_final<>v_listed and m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'edit_value') then raise exception 'Sem permissão para alterar valor'; end if;
  v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo');
  v_end:=v_start+make_interval(mins=>v_duration);
  if v_start<now() then raise exception 'Não é possível criar horário no passado'; end if;
  if exists(select 1 from public.appointments a where a.professional_id=v_prof.id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Horário ocupado'; end if;
  if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then raise exception 'Horário bloqueado'; end if;

  begin
    insert into public.appointments(barbershop_id,unit_id,professional_id,customer_id,service_id,starts_at,ends_at,base_price_cents,total_price_cents,listed_price_cents,manual_adjustment_cents,internal_note,created_by_member_id)
    values(m.barbershop_id,v_prof.unit_id,v_prof.id,v_customer.id,v_service.id,v_start,v_end,v_base,v_final,v_listed,v_final-v_listed,nullif(trim(coalesce(p_internal_note,'')),''),m.member_id)
    returning * into v_appt;
  exception when exclusion_violation then raise exception 'Horário ocupado'; end;

  insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min)
  select v_appt.id,ad.id,ad.name,a.addon_price_cents,a.addon_duration_min from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=v_service.id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;

  insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details)
  values(m.barbershop_id,v_appt.id,m.member_id,'created',jsonb_build_object('professional',v_prof.name,'service',v_service.name,'starts_at',v_start,'total_price_cents',v_final));

  return jsonb_build_object('ok',true,'appointment_id',v_appt.id);
end;
$$;

create or replace function public.barberium_staff_update_appointment(
  p_appointment_id uuid,
  p_professional_id uuid,
  p_service_id uuid,
  p_addon_service_ids uuid[],
  p_date date,
  p_time time,
  p_final_price_cents integer default null,
  p_internal_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record; perms jsonb; olda public.appointments; v_prof public.professionals; v_service public.services; v_b public.barbershops;
  old_addons uuid[]; new_addons uuid[]; v_duration int; v_base int; v_listed int; v_final int; v_start timestamptz; v_end timestamptz;
  old_date date; old_time time; service_changed boolean; addons_changed boolean; professional_changed boolean; date_changed boolean; time_changed boolean; value_changed boolean; note_changed boolean;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  select * into olda from public.appointments where id=p_appointment_id for update;
  if olda.id is null or olda.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if;
  if m.role='barber' and olda.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if;
  if m.role='barber' and p_professional_id<>m.professional_id then raise exception 'Barbeiro não pode transferir atendimento'; end if;

  select coalesce(array_agg(service_id order by service_id),'{}'::uuid[]) into old_addons from public.appointment_addons where appointment_id=olda.id;
  select coalesce(array_agg(x order by x),'{}'::uuid[]) into new_addons from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x;
  select * into v_prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if;
  select * into v_service from public.services where id=p_service_id and unit_id=v_prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if;
  if exists(select 1 from unnest(new_addons) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'Adicional inválido'; end if;
  select * into v_b from public.barbershops where id=m.barbershop_id;
  old_date:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::date;
  old_time:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::time;
  service_changed:=olda.service_id<>p_service_id;
  addons_changed:=old_addons<>new_addons;
  professional_changed:=olda.professional_id<>p_professional_id;
  date_changed:=old_date<>p_date;
  time_changed:=old_time<>p_time;
  note_changed:=coalesce(olda.internal_note,'')<>coalesce(nullif(trim(coalesce(p_internal_note,'')),''),'');

  if m.role='barber' then
    if service_changed and not barberium.permission_enabled(perms,'edit_service') then raise exception 'Sem permissão para alterar serviço'; end if;
    if addons_changed and not barberium.permission_enabled(perms,'edit_addons') then raise exception 'Sem permissão para alterar adicionais'; end if;
    if date_changed and not barberium.permission_enabled(perms,'edit_date') then raise exception 'Sem permissão para alterar data'; end if;
    if time_changed and not barberium.permission_enabled(perms,'edit_time') then raise exception 'Sem permissão para alterar horário'; end if;
    if note_changed and not barberium.permission_enabled(perms,'edit_internal_note') then raise exception 'Sem permissão para alterar observação'; end if;
  end if;

  v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=v_prof.id and service_id=v_service.id),v_service.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=v_service.id and a.addon_service_id=any(new_addons) and a.is_active),0);
  v_base:=coalesce((select custom_price_cents from public.professional_services where professional_id=v_prof.id and service_id=v_service.id),v_service.price_cents);
  v_listed:=v_base+coalesce((select sum(a.addon_price_cents) from public.service_addons a where a.base_service_id=v_service.id and a.addon_service_id=any(new_addons) and a.is_active),0);
  if m.role in ('owner','admin') or barberium.permission_enabled(perms,'edit_value') then
    v_final:=coalesce(p_final_price_cents,v_listed);
  else
    v_final:=case when service_changed or addons_changed then v_listed else olda.total_price_cents end;
    if p_final_price_cents is not null and p_final_price_cents<>v_final then raise exception 'Sem permissão para alterar valor'; end if;
  end if;
  if v_final<0 then raise exception 'Valor inválido'; end if;
  value_changed:=olda.total_price_cents<>v_final;

  v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration);
  if olda.status='confirmed' then
    if exists(select 1 from public.appointments a where a.professional_id=v_prof.id and a.status='confirmed' and a.id<>olda.id and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Horário ocupado'; end if;
    if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then raise exception 'Horário bloqueado'; end if;
  end if;

  begin
    update public.appointments set professional_id=v_prof.id,unit_id=v_prof.unit_id,service_id=v_service.id,starts_at=v_start,ends_at=v_end,base_price_cents=v_base,listed_price_cents=v_listed,total_price_cents=v_final,manual_adjustment_cents=v_final-v_listed,internal_note=nullif(trim(coalesce(p_internal_note,'')),''),updated_at=now() where id=olda.id;
  exception when exclusion_violation then raise exception 'Horário ocupado'; end;
  delete from public.appointment_addons where appointment_id=olda.id;
  insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min)
  select olda.id,ad.id,ad.name,a.addon_price_cents,a.addon_duration_min from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=v_service.id and a.addon_service_id=any(new_addons) and a.is_active;

  insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details)
  values(m.barbershop_id,olda.id,m.member_id,'edited',jsonb_build_object(
    'professional_changed',professional_changed,'old_professional_id',olda.professional_id,'new_professional_id',v_prof.id,
    'service_changed',service_changed,'old_service_id',olda.service_id,'new_service_id',v_service.id,
    'addons_changed',addons_changed,'date_changed',date_changed,'time_changed',time_changed,'value_changed',value_changed,'note_changed',note_changed,
    'old_starts_at',olda.starts_at,'new_starts_at',v_start,'old_total_price_cents',olda.total_price_cents,'new_total_price_cents',v_final
  ));
  return jsonb_build_object('ok',true,'appointment_id',olda.id);
end;
$$;

create or replace function public.barberium_staff_set_appointment_status(p_appointment_id uuid,p_status text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; perms jsonb; a public.appointments%rowtype;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_status not in ('confirmed','completed','cancelled','no_show') then raise exception 'Status inválido'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  select * into a from public.appointments where id=p_appointment_id for update;
  if a.id is null or a.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if;
  if m.role='barber' then
    if a.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if;
    if p_status='completed' and not barberium.permission_enabled(perms,'mark_completed') then raise exception 'Sem permissão para concluir'; end if;
    if p_status='no_show' and not barberium.permission_enabled(perms,'mark_no_show') then raise exception 'Sem permissão para marcar falta'; end if;
    if p_status='cancelled' and not barberium.permission_enabled(perms,'cancel_appointment') then raise exception 'Sem permissão para cancelar'; end if;
    if p_status='confirmed' then raise exception 'Somente o ADM pode restaurar para confirmado'; end if;
    if a.status<>'confirmed' then raise exception 'Este atendimento já foi finalizado'; end if;
  end if;
  if a.status=p_status then return jsonb_build_object('ok',true,'status',a.status); end if;
  if p_status='confirmed' and barberium.has_block_conflict(a.unit_id,a.professional_id,a.starts_at,a.ends_at,null,null) then raise exception 'Horário bloqueado'; end if;
  begin
    update public.appointments set status=p_status,cancelled_at=case when p_status='cancelled' then now() else null end,updated_at=now() where id=a.id;
  exception when exclusion_violation then raise exception 'Horário já foi ocupado por outro atendimento'; end;
  insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from',a.status,'to',p_status));
  return jsonb_build_object('ok',true,'appointment_id',a.id,'status',p_status);
end;
$$;

revoke all on function public.barberium_staff_search_customers(text) from public,anon;
revoke all on function public.barberium_staff_create_appointment(uuid,text,text,uuid,uuid,uuid[],date,time,integer,text) from public,anon;
revoke all on function public.barberium_staff_update_appointment(uuid,uuid,uuid,uuid[],date,time,integer,text) from public,anon;
revoke all on function public.barberium_staff_set_appointment_status(uuid,text) from public,anon;
grant execute on function public.barberium_staff_search_customers(text) to authenticated;
grant execute on function public.barberium_staff_create_appointment(uuid,text,text,uuid,uuid,uuid[],date,time,integer,text) to authenticated;
grant execute on function public.barberium_staff_update_appointment(uuid,uuid,uuid,uuid[],date,time,integer,text) to authenticated;
grant execute on function public.barberium_staff_set_appointment_status(uuid,text) to authenticated;

