
create or replace function public.barberium_staff_checkout_membership_context(p_appointment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  a record;
  v_permissions jsonb;
  v_plans jsonb;
  v_options jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;

  select ap.* into a
  from public.appointments ap
  where ap.id=p_appointment_id
    and ap.barbershop_id=m.barbershop_id;

  if a.id is null then raise exception 'Atendimento inválido'; end if;
  if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if;

  v_permissions:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  if m.role='barber' and not barberium.permission_enabled(v_permissions,'mark_completed') then
    raise exception 'Sem permissão para concluir atendimento';
  end if;

  perform barberium.refresh_customer_membership_states(a.customer_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'membership_id',cm.id,
    'plan',mp.name,
    'plan_type',cm.plan_type,
    'status',cm.status
  ) order by mp.name),'[]'::jsonb)
  into v_plans
  from public.customer_memberships cm
  join public.membership_plans mp on mp.id=cm.plan_id
  where cm.customer_id=a.customer_id
    and cm.barbershop_id=m.barbershop_id
    and cm.status in ('active','paused','overdue');

  v_options:=case when a.status='confirmed'
    then public.barberium_staff_membership_options_for_appointment(a.id)
    else '[]'::jsonb
  end;

  return jsonb_build_object(
    'has_plan',jsonb_array_length(v_plans)>0,
    'plans',v_plans,
    'options',coalesce(v_options,'[]'::jsonb)
  );
end
$function$;

create or replace function public.barberium_staff_reserve_membership_use(
  p_appointment_id uuid,
  p_membership_id uuid,
  p_benefit_id uuid,
  p_bucket_id uuid,
  p_target_service_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  a record;
  perms jsonb;
  opt jsonb;
  v_coverage int;
  v_existing uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;

  select ap.* into a
  from public.appointments ap
  where ap.id=p_appointment_id
    and ap.barbershop_id=m.barbershop_id
    and ap.status='confirmed'
  for update of ap;

  if a.id is null then raise exception 'Atendimento confirmado não encontrado'; end if;

  if m.role='barber' then
    if a.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if;
    perms:=barberium.effective_permissions(m.professional_id);
    if not barberium.permission_enabled(perms,'mark_completed') then
      raise exception 'Sem permissão para concluir atendimento';
    end if;
  elsif m.role not in ('owner','admin') then
    raise exception 'Sem permissão';
  end if;

  select u0.id into v_existing
  from public.appointment_membership_uses u0
  where u0.appointment_id=a.id
    and u0.membership_id=p_membership_id
    and u0.benefit_id=p_benefit_id
    and u0.target_service_id=p_target_service_id
    and u0.status in ('reserved','consumed')
  limit 1;

  if v_existing is not null then
    return jsonb_build_object('ok',true,'use_id',v_existing,'already_reserved',true);
  end if;

  select x into opt
  from jsonb_array_elements(public.barberium_staff_membership_options_for_appointment(p_appointment_id)) x
  where (x->>'membership_id')::uuid=p_membership_id
    and (x->>'benefit_id')::uuid=p_benefit_id
    and (((x->>'bucket_id') is null and p_bucket_id is null) or (x->>'bucket_id')::uuid=p_bucket_id)
    and (x->>'target_service_id')::uuid=p_target_service_id
  limit 1;

  if opt is null then raise exception 'Benefício indisponível para este atendimento'; end if;

  v_coverage:=(opt->>'coverage_cents')::int;

  insert into public.appointment_membership_uses(
    appointment_id,membership_id,bucket_id,benefit_id,
    covered_service_id,target_service_id,status,credit_qty,coverage_cents
  )
  values(
    a.id,p_membership_id,p_bucket_id,p_benefit_id,
    (opt->>'covered_service_id')::uuid,p_target_service_id,'reserved',1,v_coverage
  )
  returning id into v_existing;

  if p_bucket_id is not null then
    update public.membership_credit_buckets
    set reserved_credits=reserved_credits+1
    where id=p_bucket_id;
  end if;

  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(
    p_membership_id,'benefit_reserved',
    jsonb_build_object(
      'appointment_id',a.id,
      'benefit_id',p_benefit_id,
      'target_service_id',p_target_service_id,
      'coverage_cents',v_coverage,
      'plan_type',opt->>'plan_type'
    ),
    m.member_id
  );

  return jsonb_build_object('ok',true,'use_id',v_existing,'coverage_cents',v_coverage);
end
$function$;

create or replace function public.barberium_staff_release_membership_use(p_use_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  u record;
  a record;
  perms jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;

  select u0.*,a0.professional_id,a0.status appointment_status,a0.barbershop_id
  into u
  from public.appointment_membership_uses u0
  join public.appointments a0 on a0.id=u0.appointment_id
  where u0.id=p_use_id
    and a0.barbershop_id=m.barbershop_id
    and u0.status='reserved'
  for update of u0;

  if u.id is null then raise exception 'Reserva não encontrada'; end if;

  if m.role='barber' then
    if u.professional_id<>m.professional_id or u.appointment_status<>'confirmed' then
      raise exception 'Sem acesso';
    end if;
    perms:=barberium.effective_permissions(m.professional_id);
    if not barberium.permission_enabled(perms,'mark_completed') then
      raise exception 'Sem permissão para concluir atendimento';
    end if;
  elsif m.role not in ('owner','admin') then
    raise exception 'Sem permissão';
  end if;

  update public.appointment_membership_uses
  set status='released'
  where id=u.id;

  if u.bucket_id is not null then
    update public.membership_credit_buckets
    set reserved_credits=greatest(0,reserved_credits-u.credit_qty)
    where id=u.bucket_id;
  end if;

  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(
    u.membership_id,'credit_released',
    jsonb_build_object('appointment_id',u.appointment_id,'use_id',u.id),
    m.member_id
  );

  return jsonb_build_object('ok',true);
end
$function$;

revoke all on function public.barberium_staff_checkout_membership_context(uuid) from public,anon;
grant execute on function public.barberium_staff_checkout_membership_context(uuid) to authenticated,service_role;

revoke all on function public.barberium_staff_reserve_membership_use(uuid,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.barberium_staff_reserve_membership_use(uuid,uuid,uuid,uuid,uuid) to authenticated,service_role;

revoke all on function public.barberium_staff_release_membership_use(uuid) from public,anon;
grant execute on function public.barberium_staff_release_membership_use(uuid) to authenticated,service_role;

