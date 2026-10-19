-- Barberium · Estabilização · Etapa 0 · 19/10/2026
-- Segurança: identidade do cliente e isolamento entre barbearias.
--
-- 1. barberium_customer_open_profile: suspenso. Aceitava qualquer nome, sobrescrevia o
--    cadastro e devolvia token do perfil para quem soubesse só o telefone.
-- 2. barberium_create_appointment: cliente existente só tem nome/aniversário alterados e só
--    recebe token se o aparelho já tiver um token válido dele. Cliente novo continua recebendo
--    token. Sem prova de posse, o horário é criado, nada do cadastro muda e, se o nome digitado
--    for diferente, ele vai para a nota interna do atendimento.
-- 3. barberium_staff_save_commission_config, barberium_staff_open_cash,
--    barberium_staff_assign_membership: passam a recusar profissional, serviço ou unidade de
--    outra barbearia.
-- 4. FKs compostas: unidade e profissional precisam ser da mesma barbearia da linha.
--
-- Nenhum dado é alterado. Rollback: migrations/rollback/20261019_etapa0_seguranca_rollback.sql

CREATE OR REPLACE FUNCTION public.barberium_customer_open_profile(p_barbershop_slug text, p_full_name text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'extensions'
AS $function$
begin
  -- Etapa 0 (19/10/2026): acesso por nome + WhatsApp suspenso.
  -- A versão anterior aceitava qualquer nome, sobrescrevia o cadastro e devolvia
  -- um token do perfil para quem soubesse apenas o telefone. Volta quando houver
  -- verificação de posse do número (código no WhatsApp ou link enviado pela barbearia).
  raise exception 'PROFILE_VERIFICATION_REQUIRED'
    using hint='O acesso ao perfil exige verificação do WhatsApp.';
end
$function$;

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

CREATE OR REPLACE FUNCTION public.barberium_staff_save_commission_config(p_professional_id uuid, p_default_percent numeric, p_settlement_cycle text, p_basis text, p_service_rules jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; r jsonb; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; if not exists(select 1 from public.professionals pr where pr.id=p_professional_id and pr.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if; if exists(select 1 from jsonb_array_elements(coalesce(p_service_rules,'[]'::jsonb)) sr where not exists(select 1 from public.services s join public.units u on u.id=s.unit_id where s.id=(sr->>'service_id')::uuid and u.barbershop_id=m.barbershop_id)) then raise exception 'Serviço inválido'; end if; if p_default_percent<0 or p_default_percent>100 or p_settlement_cycle not in ('weekly','biweekly','monthly') or p_basis not in ('gross','net') then raise exception 'Configuração inválida'; end if; insert into public.commission_profiles(professional_id,barbershop_id,default_percent,settlement_cycle,basis) values(p_professional_id,m.barbershop_id,p_default_percent,p_settlement_cycle,p_basis) on conflict(professional_id) do update set default_percent=excluded.default_percent,settlement_cycle=excluded.settlement_cycle,basis=excluded.basis,updated_at=now(); for r in select * from jsonb_array_elements(coalesce(p_service_rules,'[]'::jsonb)) loop insert into public.commission_service_rules(professional_id,service_id,mode,percent) values(p_professional_id,(r->>'service_id')::uuid,coalesce(r->>'mode','percent'),nullif(r->>'percent','')::numeric) on conflict(professional_id,service_id) do update set mode=excluded.mode,percent=excluded.percent,updated_at=now(); end loop; return jsonb_build_object('ok',true); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_open_cash(p_unit_id uuid, p_opening_balance_cents integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; perms jsonb; v_id uuid; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; if m.role='barber' and not barberium.permission_enabled(perms,'open_cash') then raise exception 'Sem permissão para abrir caixa'; end if; if p_opening_balance_cents<0 then raise exception 'Saldo inicial inválido'; end if; if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if; insert into public.cash_sessions(barbershop_id,unit_id,opening_balance_cents,opened_by_member_id) values(m.barbershop_id,p_unit_id,p_opening_balance_cents,m.member_id) returning id into v_id; return jsonb_build_object('ok',true,'id',v_id); exception when unique_violation then raise exception 'Já existe um caixa aberto nesta unidade'; end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_assign_membership(p_customer_id uuid, p_plan_id uuid, p_unit_id uuid, p_start_date date DEFAULT CURRENT_DATE, p_mark_paid boolean DEFAULT false, p_payment_method text DEFAULT 'pix'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; p record; v record; cm_id uuid; cyc_id uuid; cycle_start date; cycle_end date; due date; grace int; first_mode text; amount int; validity text; valid_until date; mode text; dayn int; next_due date; prev_due date; full_days int; used_days int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; if not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if; if p_unit_id is not null and not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if; select * into p from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id and is_active; if p.id is null then raise exception 'Plano inválido'; end if; select * into v from public.membership_plan_versions where plan_id=p.id and version_no=p.current_version_no;
 if p.plan_type='subscription' then mode:=barberium.normalized_cycle_mode(v.rules); dayn:=case mode when 'calendar_month' then 1 when 'fixed_day' then greatest(1,least(31,coalesce(nullif(v.rules->>'fixed_day','')::int,1))) else extract(day from p_start_date)::int end; first_mode:=coalesce(v.rules->>'first_cycle_mode','full'); if first_mode not in ('full','proportional','custom','next_cycle') then first_mode:='full'; end if; grace:=greatest(0,coalesce(nullif(v.rules->>'grace_days','')::int,0)); amount:=v.price_cents; if mode='signup_date' then cycle_start:=p_start_date; next_due:=barberium.next_renewal_after(cycle_start,dayn,0); cycle_end:=next_due-1; else next_due:=barberium.next_renewal_after(p_start_date-1,dayn,0); if next_due=p_start_date then next_due:=barberium.next_renewal_after(p_start_date,dayn,0); end if; if first_mode='next_cycle' then cycle_start:=next_due; cycle_end:=barberium.next_renewal_after(cycle_start,dayn,0)-1; else cycle_start:=p_start_date; cycle_end:=next_due-1; end if; end if; if first_mode='proportional' and mode<>'signup_date' and cycle_start=p_start_date then prev_due:=barberium.previous_renewal_before(next_due,dayn,0); full_days:=greatest(1,next_due-prev_due); used_days:=greatest(1,next_due-p_start_date); amount:=round(v.price_cents*(used_days::numeric/full_days))::int; elsif first_mode='custom' then amount:=greatest(0,coalesce(nullif(v.rules->>'first_cycle_custom_amount_cents','')::int,v.price_cents)); end if; due:=cycle_start; insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,current_cycle_start,current_cycle_end,created_by_member_id,cycle_mode,renewal_day,renewal_shift_days) values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,cycle_start,cycle_end,m.member_id,mode,dayn,0) returning id into cm_id; insert into public.membership_cycles(membership_id,cycle_start,cycle_end,due_date,grace_until,amount_cents,status,credits_released,paid_at,is_first_cycle,sequence_no) values(cm_id,cycle_start,cycle_end,due,due+grace,amount,'pending',false,null,true,1) returning id into cyc_id;
 else validity:=coalesce(v.rules->>'credit_validity','no_expiry'); valid_until:=case when validity='fixed_days' then p_start_date+greatest(1,coalesce((v.rules->>'fixed_validity_days')::int,30)) else null end; insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,valid_until,created_by_member_id) values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,valid_until,m.member_id) returning id into cm_id; end if; insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm_id,'created',jsonb_build_object('paid',false,'plan_version_id',v.id,'payment_required_full',true),m.member_id); if p_mark_paid then perform public.barberium_staff_record_membership_payment(cm_id,cyc_id,p_payment_method); end if; return jsonb_build_object('ok',true,'membership_id',cm_id,'cycle_id',cyc_id,'status',case when p_mark_paid then 'active' else 'pending' end); exception when unique_violation then raise exception 'Cliente já possui um plano deste tipo ativo'; end $function$;

alter table public.units
  add constraint units_id_barbershop_id_key unique (id, barbershop_id);

alter table public.professionals
  add constraint professionals_id_barbershop_id_key unique (id, barbershop_id);

alter table public.cash_sessions
  add constraint cash_sessions_unit_same_barbershop_fkey
  foreign key (unit_id, barbershop_id) references public.units(id, barbershop_id);

alter table public.commission_profiles
  add constraint commission_profiles_professional_same_barbershop_fkey
  foreign key (professional_id, barbershop_id) references public.professionals(id, barbershop_id)
  on delete cascade;

alter table public.customer_memberships
  add constraint customer_memberships_origin_unit_same_barbershop_fkey
  foreign key (origin_unit_id, barbershop_id) references public.units(id, barbershop_id)
  on delete set null (origin_unit_id);

