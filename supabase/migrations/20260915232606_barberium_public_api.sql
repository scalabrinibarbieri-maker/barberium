create or replace function barberium.normalize_phone(p_phone text)
returns text language sql immutable as $$
  select case
    when regexp_replace(coalesce(p_phone,''),'\D','','g') ~ '^55[1-9][0-9]{9,10}$' then '+'||regexp_replace(p_phone,'\D','','g')
    when regexp_replace(coalesce(p_phone,''),'\D','','g') ~ '^[1-9][0-9]{9,10}$' then '+55'||regexp_replace(p_phone,'\D','','g')
    else null end
$$;

create or replace function barberium.valid_customer_token(p_customer_id uuid,p_token text)
returns boolean language sql stable security definer set search_path=public,barberium,extensions as $$
  select exists(select 1 from public.customer_access_tokens t where t.customer_id=p_customer_id and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_token,''),'sha256'))
$$;

create or replace function public.barberium_get_catalog(p_barbershop_slug text,p_unit_slug text)
returns jsonb language sql stable security definer set search_path=public,barberium as $$
with b as(select * from public.barbershops where slug=p_barbershop_slug and status='active' limit 1),
u as(select u.* from public.units u join b on b.id=u.barbershop_id where u.slug=p_unit_slug and u.is_active limit 1)
select jsonb_build_object(
 'barbershop',jsonb_build_object('id',b.id,'name',b.name,'slug',b.slug,'timezone',b.timezone,'settings',b.settings),
 'unit',jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug,'city',u.city,'state',u.state,'whatsapp',u.whatsapp,'maps_url',u.maps_url,'settings',u.settings),
 'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path) order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active),'[]'::jsonb),
 'services',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,'image_path',s.image_path,'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',ad.id,'name',ad.name,'slug',ad.slug,'price_cents',a.addon_price_cents,'duration_min',a.addon_duration_min,'image_path',ad.image_path) order by a.sort_order,ad.name) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=s.id and a.is_active and ad.is_active),'[]'::jsonb)) order by s.sort_order,s.name) from public.services s where s.unit_id=u.id and s.is_active),'[]'::jsonb)
) from b,u;
$$;

grant execute on function public.barberium_get_catalog(text,text) to anon,authenticated;

create or replace function public.barberium_get_available_slots(p_barbershop_slug text,p_unit_slug text,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date)
returns jsonb language plpgsql stable security definer set search_path=public,barberium as $$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_open time; v_close time; v_closed boolean; v_duration int; v_slot int; v_cur timestamp; v_start timestamptz; v_end timestamptz; v_result jsonb:='[]'::jsonb;
begin
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'INVALID_ADDON'; end if;
 v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_slot:=coalesce((v_u.settings->>'slot_minutes')::int,10);
 select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=v_u.id and h.professional_id=p_professional_id and h.weekday=extract(dow from p_date)::int;
 if not found then select h.open_time,h.close_time,h.is_closed into v_open,v_close,v_closed from public.business_hours h where h.unit_id=v_u.id and h.professional_id is null and h.weekday=extract(dow from p_date)::int; end if;
 if not found or v_closed then return '[]'::jsonb; end if;
 v_cur:=p_date::timestamp+v_open;
 while v_cur+make_interval(mins=>v_duration)<=p_date::timestamp+v_close loop
   v_start:=v_cur at time zone v_b.timezone; v_end:=(v_cur+make_interval(mins=>v_duration)) at time zone v_b.timezone;
   if v_start>=now()
      and not exists(select 1 from public.appointments a where a.professional_id=p_professional_id and a.status='confirmed' and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)'))
      and not exists(select 1 from public.blocked_times bt where bt.unit_id=v_u.id and (bt.professional_id is null or bt.professional_id=p_professional_id) and tstzrange(bt.starts_at,bt.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then
      v_result:=v_result||jsonb_build_array(to_char(v_cur,'HH24:MI'));
   end if;
   v_cur:=v_cur+make_interval(mins=>v_slot);
 end loop;
 return v_result;
end;$$;

grant execute on function public.barberium_get_available_slots(text,text,uuid,uuid,uuid[],date) to anon,authenticated;

create or replace function public.barberium_create_appointment(p_barbershop_slug text,p_unit_slug text,p_professional_id uuid,p_service_id uuid,p_addon_service_ids uuid[],p_date date,p_time time,p_full_name text,p_phone text,p_birthday date default null,p_existing_token text default null)
returns jsonb language plpgsql security definer set search_path=public,barberium,extensions as $$
declare v_b public.barbershops; v_u public.units; v_s public.services; v_customer public.customers; v_phone text; v_duration int; v_base int; v_total int; v_start timestamptz; v_end timestamptz; v_appt public.appointments; v_plain_token text; v_issue_token boolean:=false;
begin
 if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'INVALID_NAME'; end if;
 v_phone:=barberium.normalize_phone(p_phone); if v_phone is null then raise exception 'INVALID_PHONE'; end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active'; if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found then raise exception 'UNIT_NOT_FOUND'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active)) then raise exception 'INVALID_ADDON'; end if;
 select * into v_customer from public.customers where barbershop_id=v_b.id and phone_e164=v_phone;
 if found then update public.customers set full_name=trim(p_full_name),birthday=coalesce(p_birthday,birthday) where id=v_customer.id returning * into v_customer;
 else insert into public.customers(barbershop_id,full_name,phone_e164,birthday) values(v_b.id,trim(p_full_name),v_phone,p_birthday) returning * into v_customer; v_issue_token:=true; end if;
 v_duration:=coalesce((select custom_duration_min from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.duration_min)+coalesce((select sum(a.addon_duration_min) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_base:=coalesce((select custom_price_cents from public.professional_services where professional_id=p_professional_id and service_id=p_service_id),v_s.price_cents);
 v_total:=v_base+coalesce((select sum(a.addon_price_cents) from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active),0);
 v_start:=(p_date::timestamp+p_time) at time zone v_b.timezone; v_end:=v_start+make_interval(mins=>v_duration);
 if v_start<now() then raise exception 'PAST_SLOT'; end if;
 if not(to_char(p_time,'HH24:MI')=any(array(select jsonb_array_elements_text(public.barberium_get_available_slots(p_barbershop_slug,p_unit_slug,p_professional_id,p_service_id,coalesce(p_addon_service_ids,'{}'::uuid[]),p_date))))) then raise exception 'SLOT_UNAVAILABLE'; end if;
 begin insert into public.appointments(barbershop_id,unit_id,professional_id,customer_id,service_id,starts_at,ends_at,base_price_cents,total_price_cents) values(v_b.id,v_u.id,p_professional_id,v_customer.id,p_service_id,v_start,v_end,v_base,v_total) returning * into v_appt; exception when exclusion_violation then raise exception 'SLOT_UNAVAILABLE'; end;
 insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min) select v_appt.id,ad.id,ad.name,a.addon_price_cents,a.addon_duration_min from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;
 if v_issue_token then v_plain_token:=encode(extensions.gen_random_bytes(32),'hex'); insert into public.customer_access_tokens(customer_id,token_hash) values(v_customer.id,extensions.digest(v_plain_token,'sha256'));
 elsif p_existing_token is not null and barberium.valid_customer_token(v_customer.id,p_existing_token) then update public.customer_access_tokens set last_used_at=now() where customer_id=v_customer.id and token_hash=extensions.digest(p_existing_token,'sha256') and revoked_at is null; end if;
 return jsonb_build_object('appointment_id',v_appt.id,'customer_id',v_customer.id,'access_token',v_plain_token,'starts_at',v_appt.starts_at,'ends_at',v_appt.ends_at,'total_price_cents',v_appt.total_price_cents);
end;$$;

grant execute on function public.barberium_create_appointment(text,text,uuid,uuid,uuid[],date,time,text,text,date,text) to anon,authenticated;

create or replace function public.barberium_get_customer_portal(p_barbershop_slug text,p_access_token text)
returns jsonb language sql stable security definer set search_path=public,barberium,extensions as $$
with b as(select id from public.barbershops where slug=p_barbershop_slug and status='active'),t as(select t.customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join b on b.id=c.barbershop_id where t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1),c as(select c.* from public.customers c join t on t.customer_id=c.id)
select jsonb_build_object('customer',(select jsonb_build_object('id',c.id,'full_name',c.full_name,'phone_e164',c.phone_e164,'birthday',c.birthday) from c),'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'status',a.status,'starts_at',a.starts_at,'ends_at',a.ends_at,'total_price_cents',a.total_price_cents,'service',jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'duration_label',s.duration_label),'professional',jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path),'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',aa.service_id,'name',aa.name_snapshot,'price_cents',aa.price_cents,'duration_min',aa.duration_min)) from public.appointment_addons aa where aa.appointment_id=a.id),'[]'::jsonb)) order by a.starts_at desc) from public.appointments a join c on c.id=a.customer_id join public.services s on s.id=a.service_id join public.professionals p on p.id=a.professional_id),'[]'::jsonb));
$$;

grant execute on function public.barberium_get_customer_portal(text,text) to anon,authenticated;

create or replace function public.barberium_cancel_appointment(p_barbershop_slug text,p_access_token text,p_appointment_id uuid)
returns boolean language plpgsql security definer set search_path=public,barberium,extensions as $$
declare v_customer_id uuid; v_n int;
begin
 select t.customer_id into v_customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join public.barbershops b on b.id=c.barbershop_id where b.slug=p_barbershop_slug and b.status='active' and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
 if v_customer_id is null then raise exception 'INVALID_TOKEN'; end if;
 update public.appointments set status='cancelled',cancelled_at=now() where id=p_appointment_id and customer_id=v_customer_id and status='confirmed' and starts_at>now(); get diagnostics v_n=row_count; return v_n=1;
end;$$;

grant execute on function public.barberium_cancel_appointment(text,text,uuid) to anon,authenticated;

create or replace function public.barberium_update_customer_profile(p_barbershop_slug text,p_access_token text,p_full_name text,p_birthday date)
returns jsonb language plpgsql security definer set search_path=public,barberium,extensions as $$
declare v_customer public.customers;
begin
 select c.* into v_customer from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join public.barbershops b on b.id=c.barbershop_id where b.slug=p_barbershop_slug and b.status='active' and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
 if not found then raise exception 'INVALID_TOKEN'; end if;
 update public.customers set full_name=trim(p_full_name),birthday=p_birthday where id=v_customer.id returning * into v_customer;
 return jsonb_build_object('id',v_customer.id,'full_name',v_customer.full_name,'phone_e164',v_customer.phone_e164,'birthday',v_customer.birthday);
end;$$;

grant execute on function public.barberium_update_customer_profile(text,text,text,date) to anon,authenticated;

