update public.units
set settings = settings || jsonb_build_object(
  'slot_minutes', coalesce((settings->>'slot_minutes')::int,10),
  'min_advance_minutes', coalesce((settings->>'min_advance_minutes')::int,0),
  'days_ahead', coalesce((settings->>'days_ahead')::int,30),
  'cancel_before_minutes', coalesce((settings->>'cancel_before_minutes')::int,0),
  'reschedule_before_minutes', coalesce((settings->>'reschedule_before_minutes')::int,0),
  'must_finish_by_close', coalesce((settings->>'must_finish_by_close')::boolean,true)
)
where slug='braganca-paulista' and barbershop_id=(select id from public.barbershops where slug='scalabrini-barbieri');

create or replace function public.barberium_get_available_slots(p_barbershop_slug text,p_unit_slug text,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date)
returns jsonb language plpgsql stable security definer set search_path=public,barberium as $$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_min_advance int; v_days_ahead int; v_must_finish boolean; v_cur timestamp; v_start timestamptz; v_end timestamptz; v_result jsonb:='[]'::jsonb;
begin
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'INVALID_ADDON'; end if;
 v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_slot:=coalesce((v_u.settings->>'slot_minutes')::int,10);
 v_min_advance:=coalesce((v_u.settings->>'min_advance_minutes')::int,0);
 v_days_ahead:=coalesce((v_u.settings->>'days_ahead')::int,30);
 v_must_finish:=coalesce((v_u.settings->>'must_finish_by_close')::boolean,true);
 if p_date < (now() at time zone v_b.timezone)::date or p_date > ((now() at time zone v_b.timezone)::date + v_days_ahead) then return '[]'::jsonb; end if;
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=v_u.id and h.professional_id=p_professional_id and h.weekday=extract(dow from p_date)::int;
 if not found then select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=v_u.id and h.professional_id is null and h.weekday=extract(dow from p_date)::int; end if;
 if not found or v_closed then return '[]'::jsonb; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur < p_date::timestamp+v_close loop
   v_start:=v_cur at time zone v_b.timezone; v_end:=(v_cur+make_interval(mins=>v_duration)) at time zone v_b.timezone;
   if (not v_must_finish or v_end <= ((p_date::timestamp+v_close) at time zone v_b.timezone))
      and v_start>=now()+make_interval(mins=>v_min_advance)
      and not exists(select 1 from public.appointments a where a.professional_id=p_professional_id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
      and not exists(select 1 from public.blocked_times bt where bt.unit_id=v_u.id and (bt.professional_id is null or bt.professional_id=p_professional_id) and tstzrange(bt.starts_at,bt.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then
      v_result:=v_result||jsonb_build_array(to_char(v_cur,'HH24:MI'));
   end if;
   v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop;
 return v_result;
end;$$;

create or replace function public.barberium_cancel_appointment(p_barbershop_slug text,p_access_token text,p_appointment_id uuid)
returns boolean language plpgsql security definer set search_path=public,barberium,extensions as $$
declare v_customer_id uuid; v_n int; v_limit int; v_start timestamptz;
begin
 select t.customer_id into v_customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join public.barbershops b on b.id=c.barbershop_id where b.slug=p_barbershop_slug and b.status='active' and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
 if v_customer_id is null then raise exception 'INVALID_TOKEN'; end if;
 select a.starts_at,coalesce((u.settings->>'cancel_before_minutes')::int,0) into v_start,v_limit from public.appointments a join public.units u on u.id=a.unit_id where a.id=p_appointment_id and a.customer_id=v_customer_id and a.status='confirmed';
 if not found then return false; end if;
 if v_start < now()+make_interval(mins=>v_limit) then raise exception 'CANCELLATION_WINDOW_CLOSED'; end if;
 update public.appointments set status='cancelled',cancelled_at=now() where id=p_appointment_id and customer_id=v_customer_id and status='confirmed'; get diagnostics v_n=row_count; return v_n=1;
end;$$;

create or replace function public.barberium_reschedule_appointment(p_barbershop_slug text,p_unit_slug text,p_access_token text,p_appointment_id uuid,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_time time)
returns jsonb language plpgsql security definer set search_path=public,barberium,extensions as $$
declare v_customer_id uuid; v_old public.appointments; v_b public.barbershops; v_u public.units; v_s public.services; v_duration int; v_base int; v_total int; v_start timestamptz; v_end timestamptz; v_limit int;
begin
 select t.customer_id into v_customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join public.barbershops b on b.id=c.barbershop_id where b.slug=p_barbershop_slug and b.status='active' and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
 if v_customer_id is null then raise exception 'INVALID_TOKEN'; end if;
 select * into v_old from public.appointments where id=p_appointment_id and customer_id=v_customer_id and status='confirmed'; if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found or v_u.id<>v_old.unit_id then raise exception 'UNIT_NOT_FOUND'; end if;
 v_limit:=coalesce((v_u.settings->>'reschedule_before_minutes')::int,0); if v_old.starts_at<now()+make_interval(mins=>v_limit) then raise exception 'RESCHEDULE_WINDOW_CLOSED'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'INVALID_ADDON'; end if;
 update public.appointments set status='cancelled' where id=v_old.id;
 if not(to_char(p_time,'HH24:MI')=any(array(select jsonb_array_elements_text(public.barberium_get_available_slots(p_barbershop_slug,p_unit_slug,p_professional_id,p_service_id,coalesce(p_addon_service_ids,'{}'::uuid[]),p_date))))) then raise exception 'SLOT_UNAVAILABLE'; end if;
 v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_base:=coalesce((select custom_price_cents from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.price_cents);
 v_total:=v_base+coalesce((select sum(a.addon_price_cents) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_start:=(p_date::timestamp+p_time) at time zone v_b.timezone; v_end:=v_start+make_interval(mins=>v_duration);
 update public.appointments set professional_id=p_professional_id,service_id=p_service_id,starts_at=v_start,ends_at=v_end,base_price_cents=v_base,total_price_cents=v_total,status='confirmed',cancelled_at=null where id=v_old.id;
 delete from public.appointment_addons where appointment_id=v_old.id;
 insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min) select v_old.id,ad.id,ad.name,a.addon_price_cents,a.addon_duration_min from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;
 return jsonb_build_object('appointment_id',v_old.id,'starts_at',v_start,'ends_at',v_end,'total_price_cents',v_total);
end;$$;

grant execute on function public.barberium_reschedule_appointment(text,text,text,uuid,uuid,uuid,uuid[],date,time) to anon,authenticated;

