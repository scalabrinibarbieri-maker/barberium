create or replace function public.barberium_staff_membership_options_for_appointment(p_appointment_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; a record; v_date date; v_tz text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;
  select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id;
  if a.id is null then raise exception 'Atendimento inválido'; end if;
  if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if;
  select coalesce(timezone,'America/Sao_Paulo') into v_tz from public.barbershops where id=m.barbershop_id;
  v_date:=(a.starts_at at time zone v_tz)::date;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'membership_id',cm.id,'plan',mp.name,'plan_type',cm.plan_type,
      'benefit_id',pb.id,'bucket_id',cb.id,'covered_service_id',pb.service_id,'covered_service',s.name,
      'target_service_id',t.target_id,'target_service',t.target_name,
      'coverage_cents',barberium.membership_coverage_cents(pb.id,t.target_id),
      'unlimited',pb.unlimited,'available',case when cb.total_credits is null then null else greatest(0,cb.total_credits-cb.used_credits-cb.reserved_credits) end,
      'expires_on',cb.expires_on
    ) order by mp.name,s.name,t.target_name)
    from public.customer_memberships cm
    join public.membership_plans mp on mp.id=cm.plan_id
    join public.membership_plan_versions pv on pv.id=cm.plan_version_id
    join public.membership_plan_benefits pb on pb.plan_version_id=pv.id
    join public.services s on s.id=pb.service_id
    join public.membership_credit_buckets cb on cb.membership_id=cm.id and cb.benefit_id=pb.id
    cross join lateral (
      select a.service_id target_id,(select name from public.services where id=a.service_id) target_name
      union all
      select aa.service_id,aa.name_snapshot from public.appointment_addons aa where aa.appointment_id=a.id
    ) t
    where cm.customer_id=a.customer_id and cm.barbershop_id=m.barbershop_id and cm.status='active'
      and (cb.expires_on is null or cb.expires_on>=v_date)
      and (cb.total_credits is null or cb.total_credits-cb.used_credits-cb.reserved_credits>0)
      and (pb.service_id=t.target_id or exists(select 1 from public.service_components sc where sc.parent_service_id=t.target_id and sc.component_service_id=pb.service_id))
      and not exists(select 1 from public.appointment_membership_uses u where u.appointment_id=a.id and u.benefit_id=pb.id and u.target_service_id=t.target_id and u.status in ('reserved','consumed'))
      and (
        coalesce(pv.rules->>'unit_scope','all')='all'
        or (pv.rules->>'unit_scope'='origin' and cm.origin_unit_id=a.unit_id)
        or (pv.rules->>'unit_scope'='selected' and exists(select 1 from public.membership_plan_units pu where pu.plan_version_id=pv.id and pu.unit_id=a.unit_id))
      )
      and (pb.min_days_between is null or not exists(
        select 1 from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id
        where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed') and ax.id<>a.id
          and abs(((ax.starts_at at time zone v_tz)::date-v_date))<pb.min_days_between
      ))
      and (pb.max_per_week is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed') and date_trunc('week',(ax.starts_at at time zone v_tz))::date=date_trunc('week',v_date)::date)<pb.max_per_week)
      and (pb.max_per_month is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed') and date_trunc('month',(ax.starts_at at time zone v_tz))::date=date_trunc('month',v_date)::date)<pb.max_per_month)
  ),'[]'::jsonb);
end $$;

create or replace function public.barberium_staff_reserve_membership_use(p_appointment_id uuid,p_membership_id uuid,p_benefit_id uuid,p_bucket_id uuid,p_target_service_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; a record; opt jsonb; v_coverage int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id and status='confirmed' for update;
  if a.id is null then raise exception 'Atendimento confirmado não encontrado'; end if;
  select x into opt from jsonb_array_elements(public.barberium_staff_membership_options_for_appointment(p_appointment_id)) x
    where (x->>'membership_id')::uuid=p_membership_id and (x->>'benefit_id')::uuid=p_benefit_id and (x->>'bucket_id')::uuid=p_bucket_id and (x->>'target_service_id')::uuid=p_target_service_id limit 1;
  if opt is null then raise exception 'Benefício indisponível para este atendimento'; end if;
  v_coverage:=(opt->>'coverage_cents')::int;
  insert into public.appointment_membership_uses(appointment_id,membership_id,bucket_id,benefit_id,covered_service_id,target_service_id,status,credit_qty,coverage_cents)
  values(a.id,p_membership_id,p_bucket_id,p_benefit_id,(opt->>'covered_service_id')::uuid,p_target_service_id,'reserved',1,v_coverage);
  update public.membership_credit_buckets set reserved_credits=reserved_credits+1 where id=p_bucket_id;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(p_membership_id,'credit_reserved',jsonb_build_object('appointment_id',a.id,'benefit_id',p_benefit_id,'target_service_id',p_target_service_id,'coverage_cents',v_coverage),m.member_id);
  return jsonb_build_object('ok',true,'coverage_cents',v_coverage);
end $$;

create or replace function public.barberium_staff_release_membership_use(p_use_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; u record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select u.* into u from public.appointment_membership_uses u join public.appointments a on a.id=u.appointment_id where u.id=p_use_id and a.barbershop_id=m.barbershop_id and u.status='reserved' for update;
  if u.id is null then raise exception 'Reserva não encontrada'; end if;
  update public.appointment_membership_uses set status='released' where id=u.id;
  if u.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-u.credit_qty) where id=u.bucket_id; end if;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(u.membership_id,'credit_released',jsonb_build_object('appointment_id',u.appointment_id,'use_id',u.id),m.member_id);
  return jsonb_build_object('ok',true);
end $$;

grant execute on function public.barberium_staff_membership_options_for_appointment(uuid) to authenticated;
grant execute on function public.barberium_staff_reserve_membership_use(uuid,uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.barberium_staff_release_membership_use(uuid) to authenticated;

