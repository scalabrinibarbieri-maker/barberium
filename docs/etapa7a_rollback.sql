-- Barberium · Etapa 7a · Ajustes da unidade e manutenção no banco · ROLLBACK
-- Volta as três funções como eram antes da migration 20261022200000 e apaga a regra de
-- manutenção do banco. Nenhum dado muda.
--
-- Ordem:
--   1. Cloudflare: volte o site para o deploy anterior PRIMEIRO. O site novo manda só as
--      chaves que mudou ao salvar a unidade; com o banco antigo, isso apagaria as outras.
--   2. Supabase, SQL Editor: rode este arquivo inteiro. Ou entra tudo, ou nada.
--   3. Repositório: apague supabase/migrations/20261022200000_ajustes_e_manutencao.sql.

begin;

CREATE OR REPLACE FUNCTION public.barberium_staff_save_unit(p_unit_id uuid, p_name text, p_city text, p_state text, p_whatsapp text, p_maps_url text, p_is_active boolean, p_settings jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; v_id uuid; v_slug text; base text; i int:=1;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome da unidade inválido'; end if;
  if p_unit_id is null then
    base:=nullif(barberium.make_slug(p_name),''); if base is null then base:='unidade'; end if; v_slug:=base;
    while exists(select 1 from public.units u where u.barbershop_id=m.barbershop_id and u.slug=v_slug) loop i:=i+1; v_slug:=base||'-'||i; end loop;
    insert into public.units(barbershop_id,name,slug,city,state,whatsapp,maps_url,is_active,settings)
    values(m.barbershop_id,trim(p_name),v_slug,nullif(trim(coalesce(p_city,'')),''),nullif(trim(coalesce(p_state,'')),''),nullif(trim(coalesce(p_whatsapp,'')),''),nullif(trim(coalesce(p_maps_url,'')),''),coalesce(p_is_active,true),coalesce(p_settings,'{}'::jsonb)) returning id into v_id;
    insert into public.business_hours(unit_id,professional_id,weekday,open_time,close_time,is_closed) select v_id,null,d,null,null,true from generate_series(0,6) d on conflict do nothing;
  else
    select id into v_id from public.units where id=p_unit_id and barbershop_id=m.barbershop_id; if v_id is null then raise exception 'Unidade inválida'; end if;
    update public.units set name=trim(p_name),city=nullif(trim(coalesce(p_city,'')),''),state=nullif(trim(coalesce(p_state,'')),''),whatsapp=nullif(trim(coalesce(p_whatsapp,'')),''),maps_url=nullif(trim(coalesce(p_maps_url,'')),''),is_active=coalesce(p_is_active,true),settings=coalesce(p_settings,'{}'::jsonb),updated_at=now() where id=v_id;
  end if;
  return jsonb_build_object('ok',true,'unit_id',v_id);
end $function$;

CREATE OR REPLACE FUNCTION public.barberium_create_appointment(p_barbershop_slug text, p_unit_slug text, p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_date date, p_time time without time zone, p_full_name text, p_phone text, p_birthday date DEFAULT NULL::date, p_existing_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'extensions'
AS $function$
declare
  v_b public.barbershops;
  v_u public.units;
  v_s public.services;
  v_customer public.customers;
  v_phone text;
  v_duration int;
  v_base int;
  v_total int;
  v_start timestamptz;
  v_end timestamptz;
  v_appt public.appointments;
  v_plain_token text;
  v_owner boolean:=false;
  v_new_customer boolean:=false;
  v_site_note text;
begin
  if length(trim(coalesce(p_full_name,'')))<3 then raise exception 'INVALID_NAME'; end if;
  v_phone:=barberium.normalize_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE'; end if;

  select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
  if not found then raise exception 'BARBERSHOP_NOT_FOUND'; end if;

  select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active;
  if not found then raise exception 'UNIT_NOT_FOUND'; end if;

  select * into v_s from public.services
  where id=p_service_id and unit_id=v_u.id and is_active
    and service_kind in ('service','combo')
    and coalesce((settings->>'draft')::boolean,false)=false;
  if not found then raise exception 'SERVICE_NOT_FOUND'; end if;

  if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active)
    then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;

  if not barberium.professional_service_allowed(p_professional_id,p_service_id)
    then raise exception 'PROFESSIONAL_NOT_LINKED'; end if;

  if exists(
    select 1
    from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x
    where not exists(
      select 1 from public.service_addons a
      where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active
    )
    or not barberium.professional_service_allowed(p_professional_id,x)
  ) then raise exception 'INVALID_ADDON'; end if;

  select * into v_customer
  from public.customers
  where barbershop_id=v_b.id and phone_e164=v_phone;

  if found then
    -- Etapa 0 (19/10/2026): o cadastro de um cliente existente só é alterado por quem
    -- prova ser o dono, com um token válido deste mesmo cliente salvo no aparelho.
    v_owner:=p_existing_token is not null
      and barberium.valid_customer_token(v_customer.id,p_existing_token);
    if v_owner then
      update public.customers
      set full_name=trim(p_full_name),
          birthday=coalesce(p_birthday,birthday)
      where id=v_customer.id
      returning * into v_customer;
    elsif lower(regexp_replace(trim(p_full_name),'\s+',' ','g'))
          <>lower(regexp_replace(trim(coalesce(v_customer.full_name,'')),'\s+',' ','g')) then
      -- Sem prova de posse o nome cadastrado fica; a equipe vê o nome digitado na nota interna.
      v_site_note:='Nome informado no site: '||trim(p_full_name);
    end if;
  else
    insert into public.customers(barbershop_id,full_name,phone_e164,birthday)
    values(v_b.id,trim(p_full_name),v_phone,p_birthday)
    returning * into v_customer;
    v_new_customer:=true;
  end if;

  v_duration:=barberium.effective_service_duration(p_professional_id,p_service_id)
    +coalesce((
      select sum(barberium.effective_addon_duration(p_professional_id,p_service_id,x))
      from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x
    ),0);

  v_base:=barberium.effective_service_price(p_professional_id,p_service_id);
  v_total:=v_base+coalesce((
    select sum(barberium.effective_addon_price(p_professional_id,p_service_id,x))
    from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x
  ),0);

  v_start:=(p_date::timestamp+p_time) at time zone v_b.timezone;
  v_end:=v_start+make_interval(mins=>v_duration);

  if v_start<now() then raise exception 'PAST_SLOT'; end if;

  if not(
    to_char(p_time,'HH24:MI')=any(
      array(
        select jsonb_array_elements_text(
          public.barberium_get_available_slots(
            p_barbershop_slug,p_unit_slug,p_professional_id,p_service_id,
            coalesce(p_addon_service_ids,'{}'::uuid[]),p_date
          )
        )
      )
    )
  ) then raise exception 'SLOT_UNAVAILABLE'; end if;

  begin
    insert into public.appointments(
      barbershop_id,unit_id,professional_id,customer_id,service_id,
      starts_at,ends_at,base_price_cents,total_price_cents,
      listed_price_cents,manual_adjustment_cents,internal_note
    )
    values(
      v_b.id,v_u.id,p_professional_id,v_customer.id,p_service_id,
      v_start,v_end,v_base,v_total,v_total,0,v_site_note
    )
    returning * into v_appt;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE';
  end;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min
  )
  select
    v_appt.id,ad.id,ad.name,
    barberium.effective_addon_price(p_professional_id,p_service_id,ad.id),
    barberium.effective_addon_duration(p_professional_id,p_service_id,ad.id)
  from public.service_addons a
  join public.services ad on ad.id=a.addon_service_id
  where a.base_service_id=p_service_id
    and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[]))
    and a.is_active;

  if v_owner then
    v_plain_token:=p_existing_token;
    update public.customer_access_tokens
      set last_used_at=now()
    where customer_id=v_customer.id
      and token_hash=extensions.digest(p_existing_token,'sha256')
      and revoked_at is null;
  elsif v_new_customer then
    v_plain_token:=encode(extensions.gen_random_bytes(32),'hex');
    insert into public.customer_access_tokens(customer_id,token_hash,last_used_at)
    values(v_customer.id,extensions.digest(v_plain_token,'sha256'),now());
  else
    -- Etapa 0: telefone já cadastrado, sem token desse cliente no aparelho.
    -- O horário é criado, mas nenhum acesso ao perfil é entregue.
    v_plain_token:=null;
  end if;

  select * into v_appt from public.appointments where id=v_appt.id;

  return jsonb_build_object(
    'appointment_id',v_appt.id,
    'customer_id',v_customer.id,
    'access_token',v_plain_token,
    'profile_linked',v_plain_token is not null,
    'starts_at',v_appt.starts_at,
    'ends_at',v_appt.ends_at,
    'total_price_cents',v_appt.total_price_cents
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.barberium_reschedule_appointment(p_barbershop_slug text, p_unit_slug text, p_access_token text, p_appointment_id uuid, p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_date date, p_time time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'extensions', 'pg_temp'
AS $function$
declare v_customer_id uuid; v_old public.appointments; v_b public.barbershops; v_u public.units; v_s public.services; v_duration int; v_base int; v_total int; v_start timestamptz; v_end timestamptz; v_limit int;
begin
 select t.customer_id into v_customer_id from public.customer_access_tokens t join public.customers c on c.id=t.customer_id join public.barbershops b on b.id=c.barbershop_id where b.slug=p_barbershop_slug and b.status='active' and t.revoked_at is null and t.token_hash=extensions.digest(coalesce(p_access_token,''),'sha256') limit 1;
 if v_customer_id is null then raise exception 'INVALID_TOKEN'; end if;
 select * into v_old from public.appointments where id=p_appointment_id and customer_id=v_customer_id and status='confirmed' for update; if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
 if v_old.is_walk_in then raise exception 'Para alterar um encaixe, fale com a equipe';end if;
 if exists(select 1 from public.appointment_addons aa where aa.appointment_id=v_old.id and aa.item_kind='service') then
   raise exception 'Para alterar um agendamento com mais de um serviço, fale com a equipe';
 end if;
 select * into v_b from public.barbershops where slug=p_barbershop_slug and status='active';
 select * into v_u from public.units where barbershop_id=v_b.id and slug=p_unit_slug and is_active; if not found or v_u.id<>v_old.unit_id then raise exception 'UNIT_NOT_FOUND'; end if;
 v_limit:=coalesce((v_u.settings->>'reschedule_before_minutes')::int,0); if v_old.starts_at<now()+make_interval(mins=>v_limit) then raise exception 'RESCHEDULE_WINDOW_CLOSED'; end if;
 select * into v_s from public.services where id=p_service_id and unit_id=v_u.id and is_active and service_kind in ('service','combo') and coalesce((settings->>'draft')::boolean,false)=false; if not found then raise exception 'SERVICE_NOT_FOUND'; end if;
 if not exists(select 1 from public.professionals where id=p_professional_id and unit_id=v_u.id and is_active) then raise exception 'PROFESSIONAL_NOT_FOUND'; end if;
 if not barberium.professional_service_allowed(p_professional_id,p_service_id) then raise exception 'PROFESSIONAL_NOT_LINKED'; end if;
 if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(p_professional_id,x)) then raise exception 'INVALID_ADDON'; end if;
 update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-q.qty) from (select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where appointment_id=v_old.id and status='reserved' and bucket_id is not null group by bucket_id) q where b.id=q.bucket_id;
 update public.appointment_membership_uses set status='released' where appointment_id=v_old.id and status='reserved';
 update public.appointments set status='cancelled' where id=v_old.id;
 if not(to_char(p_time,'HH24:MI')=any(array(select jsonb_array_elements_text(public.barberium_get_available_slots(p_barbershop_slug,p_unit_slug,p_professional_id,p_service_id,coalesce(p_addon_service_ids,'{}'::uuid[]),p_date))))) then raise exception 'SLOT_UNAVAILABLE'; end if;
 v_duration:=barberium.effective_service_duration(p_professional_id,p_service_id)+coalesce((select sum(barberium.effective_addon_duration(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_base:=barberium.effective_service_price(p_professional_id,p_service_id);
 v_total:=v_base+coalesce((select sum(barberium.effective_addon_price(p_professional_id,p_service_id,x)) from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x),0);
 v_start:=(p_date::timestamp+p_time) at time zone v_b.timezone; v_end:=v_start+make_interval(mins=>v_duration);
 update public.appointments set professional_id=p_professional_id,unit_id=v_u.id,service_id=p_service_id,starts_at=v_start,ends_at=v_end,base_price_cents=v_base,listed_price_cents=v_total,total_price_cents=v_total,manual_adjustment_cents=0,status='confirmed',cancelled_at=null,updated_at=now() where id=v_old.id;
 delete from public.appointment_addons where appointment_id=v_old.id;
 insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min)
 select v_old.id,ad.id,ad.name,barberium.effective_addon_price(p_professional_id,p_service_id,ad.id),barberium.effective_addon_duration(p_professional_id,p_service_id,ad.id)
 from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=p_service_id and a.addon_service_id=any(coalesce(p_addon_service_ids,'{}'::uuid[])) and a.is_active;
 return jsonb_build_object('appointment_id',v_old.id,'starts_at',v_start,'ends_at',v_end,'total_price_cents',v_total);
end $function$;

drop function barberium.unidade_em_manutencao(jsonb);

delete from supabase_migrations.schema_migrations where version = '20261022200000';

commit;
