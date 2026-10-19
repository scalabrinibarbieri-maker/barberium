create or replace function barberium.membership_usage_commission_trigger()
returns trigger
language plpgsql security definer
set search_path to 'public','barberium','pg_temp'
as $$
declare a record; cm record; pv record; ben record; c jsonb; ctype text; amount int:=0; base int:=0; rate numeric:=null; hourly int; duration_min int; points numeric; total_points numeric; pool_pct numeric;
begin
  if new.status<>'consumed' or old.status='consumed' then return new; end if;
  select * into a from public.appointments where id=new.appointment_id;
  select cm.*,mp.name plan_name into cm from public.customer_memberships cm join public.membership_plans mp on mp.id=cm.plan_id where cm.id=new.membership_id;
  select * into pv from public.membership_plan_versions where id=cm.plan_version_id;
  select pb.*,s.duration_min,s.name service_name into ben from public.membership_plan_benefits pb join public.services s on s.id=pb.service_id where pb.id=new.benefit_id;
  c:=coalesce(pv.rules->'commission','{}'::jsonb); ctype:=coalesce(c->>'type','none');
  if ctype='attendance' then
    amount:=coalesce((c->'service_amounts'->>new.covered_service_id::text)::int,0); base:=new.coverage_cents;
  elsif ctype='hour' then
    hourly:=coalesce((c->>'hourly_rate_cents')::int,0); duration_min:=coalesce(ben.duration_min,0); amount:=round(hourly*(duration_min/60.0))::int; base:=hourly;
  elsif ctype='tickets' then
    pool_pct:=coalesce((c->>'pool_percent')::numeric,0); points:=coalesce((c->'service_points'->>new.covered_service_id::text)::numeric,0);
    select coalesce(sum((case when b.unlimited then coalesce(b.max_per_month,1) else b.quantity end)*coalesce((c->'service_points'->>b.service_id::text)::numeric,0)),0) into total_points from public.membership_plan_benefits b where b.plan_version_id=pv.id;
    if total_points>0 and points>0 then amount:=round(pv.price_cents*(pool_pct/100.0)*(points/total_points))::int; base:=pv.price_cents; rate:=pool_pct; end if;
  end if;
  if amount<>0 then
    insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents)
    values(a.barbershop_id,a.unit_id,a.professional_id,a.id,'membership_usage',new.id,concat('Comissão • ',cm.plan_name,' • ',ben.service_name),base,rate,amount);
  end if;
  return new;
end $$;

drop trigger if exists trg_membership_usage_commission on public.appointment_membership_uses;
create trigger trg_membership_usage_commission after update of status on public.appointment_membership_uses for each row execute function barberium.membership_usage_commission_trigger();

