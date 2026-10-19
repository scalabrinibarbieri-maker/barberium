create or replace function public.barberium_customer_membership_booking_options(p_barbershop_slug text,p_access_token text,p_unit_slug text,p_service_id uuid,p_addon_service_ids uuid[],p_date date)
returns jsonb
language plpgsql security definer
set search_path to 'public','barberium','extensions','pg_temp'
as $$
declare v_b uuid; v_u uuid; v_customer uuid; v_tz text;
begin
  select id,coalesce(timezone,'America/Sao_Paulo') into v_b,v_tz from public.barbershops where slug=p_barbershop_slug and status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select id into v_u from public.units where barbershop_id=v_b and slug=p_unit_slug and is_active;
  if v_u is null then raise exception 'UNIT_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
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
      select p_service_id target_id,(select name from public.services where id=p_service_id) target_name
      union all
      select x,(select name from public.services where id=x) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x
    ) t
    where cm.customer_id=v_customer and cm.barbershop_id=v_b and cm.status='active'
      and (cb.expires_on is null or cb.expires_on>=p_date)
      and (cb.total_credits is null or cb.total_credits-cb.used_credits-cb.reserved_credits>0)
      and (pb.service_id=t.target_id or exists(select 1 from public.service_components sc where sc.parent_service_id=t.target_id and sc.component_service_id=pb.service_id))
      and (
        coalesce(pv.rules->>'unit_scope','all')='all'
        or (pv.rules->>'unit_scope'='origin' and cm.origin_unit_id=v_u)
        or (pv.rules->>'unit_scope'='selected' and exists(select 1 from public.membership_plan_units pu where pu.plan_version_id=pv.id and pu.unit_id=v_u))
      )
      and (pb.min_days_between is null or not exists(
        select 1 from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id
        where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed')
          and abs(((ax.starts_at at time zone v_tz)::date-p_date))<pb.min_days_between
      ))
      and (pb.max_per_week is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed') and date_trunc('week',(ax.starts_at at time zone v_tz))::date=date_trunc('week',p_date)::date)<pb.max_per_week)
      and (pb.max_per_month is null or (select count(*) from public.appointment_membership_uses ux join public.appointments ax on ax.id=ux.appointment_id where ux.membership_id=cm.id and ux.benefit_id=pb.id and ux.status in ('reserved','consumed') and date_trunc('month',(ax.starts_at at time zone v_tz))::date=date_trunc('month',p_date)::date)<pb.max_per_month)
  ),'[]'::jsonb);
end $$;

create or replace function public.barberium_customer_reserve_membership_use(p_barbershop_slug text,p_access_token text,p_appointment_id uuid,p_membership_id uuid,p_benefit_id uuid,p_bucket_id uuid,p_target_service_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public','barberium','extensions','pg_temp'
as $$
declare v_b uuid; v_customer uuid; a record; v_tz text; v_date date; v_unit_slug text; v_addons uuid[]; opt jsonb; v_coverage int;
begin
  select id,coalesce(timezone,'America/Sao_Paulo') into v_b,v_tz from public.barbershops where slug=p_barbershop_slug and status='active';
  if v_b is null then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
  select t.customer_id into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id where c.barbershop_id=v_b and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
  if v_customer is null then raise exception 'INVALID_TOKEN'; end if;
  select a.*,u.slug unit_slug into a from public.appointments a join public.units u on u.id=a.unit_id where a.id=p_appointment_id and a.barbershop_id=v_b and a.customer_id=v_customer and a.status='confirmed' for update;
  if a.id is null then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  v_date:=(a.starts_at at time zone v_tz)::date; v_unit_slug:=a.unit_slug;
  select coalesce(array_agg(service_id),'{}'::uuid[]) into v_addons from public.appointment_addons where appointment_id=a.id;
  select x into opt from jsonb_array_elements(public.barberium_customer_membership_booking_options(p_barbershop_slug,p_access_token,v_unit_slug,a.service_id,v_addons,v_date)) x
  where (x->>'membership_id')::uuid=p_membership_id and (x->>'benefit_id')::uuid=p_benefit_id and (x->>'bucket_id')::uuid=p_bucket_id and (x->>'target_service_id')::uuid=p_target_service_id limit 1;
  if opt is null then raise exception 'BENEFIT_UNAVAILABLE'; end if;
  v_coverage:=(opt->>'coverage_cents')::int;
  insert into public.appointment_membership_uses(appointment_id,membership_id,bucket_id,benefit_id,covered_service_id,target_service_id,status,credit_qty,coverage_cents)
  values(a.id,p_membership_id,p_bucket_id,p_benefit_id,(opt->>'covered_service_id')::uuid,p_target_service_id,'reserved',1,v_coverage);
  update public.membership_credit_buckets set reserved_credits=reserved_credits+1 where id=p_bucket_id;
  insert into public.membership_events(membership_id,event_type,details) values(p_membership_id,'credit_reserved',jsonb_build_object('appointment_id',a.id,'benefit_id',p_benefit_id,'target_service_id',p_target_service_id,'coverage_cents',v_coverage,'source','customer_site'));
  return jsonb_build_object('ok',true,'coverage_cents',v_coverage);
end $$;

grant execute on function public.barberium_customer_membership_booking_options(text,text,text,uuid,uuid[],date) to anon,authenticated;
grant execute on function public.barberium_customer_reserve_membership_use(text,text,uuid,uuid,uuid,uuid,uuid) to anon,authenticated;

