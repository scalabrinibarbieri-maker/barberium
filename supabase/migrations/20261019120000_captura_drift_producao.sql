-- CAPTURA · criada em 19/10/2026 (estabilização, etapa 1)
-- Traz para o histórico o que existia só no banco de produção, aplicado direto sem migration:
--   * 3 funções: barberium_staff_cancel_completed_appointment_v12_23 (v12.23),
--     barberium_staff_free_ranges e barberium_staff_performance_v12_33 (v12.33);
--   * permissões de execução alteradas direto no banco em 4 funções
--     (acesso ao perfil, relatório financeiro e suas duas camadas internas).
-- Em produção é um no-op: as definições e permissões são exatamente as que já estão lá.
-- Por isso foi registrada no histórico do Supabase SEM ser executada lá.
-- Num banco vazio, depois de todas as migrations anteriores, deixa o schema igual ao de produção.

CREATE OR REPLACE FUNCTION public.barberium_staff_cancel_completed_appointment_v12_23(p_appointment_id uuid, p_reason text, p_cancellation_kind text DEFAULT 'booking_error'::text, p_is_refund boolean DEFAULT false, p_refund_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  a record;
  sale record;
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
  v_kind text:=coalesce(nullif(btrim(p_cancellation_kind),''),'booking_error');
  v_raw jsonb;
  v_result jsonb;
  v_event_id uuid;
  v_refunds_before uuid[];
  v_service_paid int:=0;
  v_product_paid int:=0;
  v_service_pending int:=0;
  v_product_pending int:=0;
  v_has_settled_commission boolean:=false;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Somente o ADM pode cancelar um atendimento concluído';
  end if;

  if v_reason is null or length(v_reason)<3 then
    raise exception 'Informe o motivo do cancelamento';
  end if;

  if v_kind not in ('regular','booking_error') then
    raise exception 'Tipo de cancelamento inválido';
  end if;

  if coalesce(p_is_refund,false) then
    if coalesce(p_refund_method,'') not in ('pix','cash','debit','credit','transfer','other') then
      raise exception 'Selecione a forma da devolução';
    end if;

    v_result:=public.barberium_staff_cancel_completed_appointment_v2(
      p_appointment_id,
      v_reason,
      p_refund_method,
      v_kind
    );

    select e.id into v_event_id
    from public.appointment_events e
    where e.appointment_id=p_appointment_id
      and e.event_type='cancelled_with_refund'
    order by e.created_at desc,e.id desc
    limit 1;

    if v_event_id is not null then
      update public.appointment_events
      set details=coalesce(details,'{}'::jsonb)||jsonb_build_object(
        'is_refund',true,
        'cancellation_kind',v_kind,
        'reason',v_reason
      )
      where id=v_event_id;
    end if;

    return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('is_refund',true);
  end if;

  select * into a
  from public.appointments
  where id=p_appointment_id
    and barbershop_id=m.barbershop_id
  for update;

  if a.id is null then raise exception 'Atendimento não encontrado'; end if;

  select e.details into v_result
  from public.appointment_events e
  where e.appointment_id=a.id
    and e.event_type='cancelled_without_refund'
  order by e.created_at desc,e.id desc
  limit 1;

  if a.status='cancelled' and v_result is not null then
    return v_result||jsonb_build_object('ok',true,'already_cancelled',true,'is_refund',false);
  end if;

  if a.status<>'completed' then
    raise exception 'Este atendimento não está concluído';
  end if;

  select coalesce(sum(ap.amount_cents),0)::int
    into v_service_paid
  from public.appointment_payments ap
  where ap.appointment_id=a.id;

  select coalesce(sum(greatest(0,ar.original_due_cents-ar.paid_cents)),0)::int
    into v_service_pending
  from public.appointment_receivables ar
  where ar.appointment_id=a.id
    and ar.status in ('open','partial');

  select * into sale
  from public.product_sales ps
  where ps.appointment_id=a.id
  for update;

  if sale.id is not null then
    v_product_paid:=coalesce(sale.paid_cents,0);
    v_product_pending:=coalesce(sale.pending_cents,0);
  end if;

  select coalesce(array_agg(fr.id),'{}'::uuid[])
    into v_refunds_before
  from public.finance_refunds fr
  where fr.appointment_id=a.id;

  select exists(
    select 1
    from public.commission_entries ce
    where ce.appointment_id=a.id
      and ce.source_type in (
        'service','membership_usage','appointment_cancellation',
        'product_sale','product_refund'
      )
      and (ce.settlement_id is not null or ce.status<>'open')
  ) into v_has_settled_commission;

  -- Reaproveita a rotina consolidada para devolver estoque, liberar ficha,
  -- cancelar pendências e criar as reversões necessárias.
  -- Usa "other" para não criar movimentação de caixa de devolução.
  v_raw:=public.barberium_staff_cancel_completed_appointment_v12_7_raw(
    a.id,
    v_reason,
    'other'
  );

  -- A entrada registrada era operacionalmente inválida: não houve dinheiro real.
  delete from public.cash_movements cm
  where cm.barbershop_id=m.barbershop_id
    and cm.movement_type='payment'
    and (
      (cm.reference_type='appointment' and cm.reference_id=a.id)
      or
      (sale.id is not null and cm.reference_type='product_sale' and cm.reference_id=sale.id)
    );

  delete from public.appointment_payments ap
  where ap.appointment_id=a.id;

  if sale.id is not null then
    delete from public.product_sale_payments psp
    where psp.sale_id=sale.id;

    update public.product_sales
    set status='cancelled',
        paid_cents=0,
        pending_cents=0,
        refunded_at=null,
        updated_at=now()
    where id=sale.id;

    update public.product_stock_movements
    set movement_type='sale_return',
        reason='Correção operacional: '||v_reason
    where reference_type='product_sale_refund'
      and reference_id=sale.id
      and movement_type='refund';
  end if;

  -- Remove somente os "reembolsos" que a rotina antiga acabou de gerar.
  delete from public.finance_refunds fr
  where fr.appointment_id=a.id
    and not (fr.id=any(coalesce(v_refunds_before,'{}'::uuid[])));

  -- Se nada desse atendimento já foi liquidado em acerto, a anulação pode
  -- limpar os lançamentos de comissão de ida e volta, evitando poluição.
  if not v_has_settled_commission then
    delete from public.commission_entries ce
    where ce.appointment_id=a.id
      and ce.settlement_id is null
      and ce.status='open'
      and ce.source_type in (
        'service','membership_usage','appointment_cancellation',
        'product_sale','product_refund'
      );
  end if;

  update public.appointments
  set cancellation_kind=v_kind,
      cancellation_reason=v_reason,
      updated_at=now()
  where id=a.id;

  select e.id into v_event_id
  from public.appointment_events e
  where e.appointment_id=a.id
    and e.event_type='cancelled_with_refund'
  order by e.created_at desc,e.id desc
  limit 1;

  v_result:=coalesce(v_raw,'{}'::jsonb)||jsonb_build_object(
    'ok',true,
    'appointment_id',a.id,
    'from','completed',
    'to','cancelled',
    'reason',v_reason,
    'cancellation_kind',v_kind,
    'is_refund',false,
    'refund_method',null,
    'service_refund_cents',0,
    'product_refund_cents',0,
    'voided_service_payment_cents',v_service_paid,
    'voided_product_payment_cents',v_product_paid,
    'service_pending_cancelled_cents',v_service_pending,
    'product_pending_cancelled_cents',v_product_pending
  );

  if v_event_id is not null then
    update public.appointment_events
    set event_type='cancelled_without_refund',
        details=v_result
    where id=v_event_id;
  else
    insert into public.appointment_events(
      barbershop_id,appointment_id,actor_member_id,event_type,details
    )
    values(
      m.barbershop_id,a.id,m.member_id,'cancelled_without_refund',v_result
    );
  end if;

  return v_result;
end
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_free_ranges(p_date date DEFAULT CURRENT_DATE, p_professional_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  v_tz text;
  v_filter_prof uuid;
  pr record;
  hrs record;
  occ record;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_cursor timestamptz;
  v_gap_end timestamptz;
  v_slot_minutes int;
  v_elapsed_minutes numeric;
  v_ranges jsonb;
  v_result jsonb := '[]'::jsonb;
  v_today date;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  select coalesce(timezone,'America/Sao_Paulo')
    into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  v_today := (now() at time zone v_tz)::date;

  if m.role in ('owner','admin') then
    if p_professional_id is not null and not exists(
      select 1
      from public.professionals p
      where p.id=p_professional_id
        and p.barbershop_id=m.barbershop_id
        and p.is_active
    ) then
      raise exception 'Profissional inválido';
    end if;
    v_filter_prof := p_professional_id;
  else
    v_filter_prof := m.professional_id;
  end if;

  for pr in
    select
      p.id,
      p.name,
      p.unit_id,
      p.settings as professional_settings,
      u.name as unit_name,
      u.settings as unit_settings
    from public.professionals p
    join public.units u on u.id=p.unit_id
    where p.barbershop_id=m.barbershop_id
      and p.is_active
      and (v_filter_prof is null or p.id=v_filter_prof)
    order by p.sort_order,p.name
  loop
    v_ranges := '[]'::jsonb;

    select *
      into hrs
    from barberium.effective_business_hours(pr.unit_id,pr.id,p_date)
    limit 1;

    if not found or coalesce(hrs.is_closed,false) or hrs.open_time is null or hrs.close_time is null then
      v_result := v_result || jsonb_build_array(
        jsonb_build_object(
          'professional_id',pr.id,
          'professional',pr.name,
          'unit_id',pr.unit_id,
          'unit',pr.unit_name,
          'is_closed',true,
          'ranges','[]'::jsonb
        )
      );
      continue;
    end if;

    v_day_start := (p_date::timestamp + hrs.open_time) at time zone v_tz;
    v_day_end := (p_date::timestamp + hrs.close_time) at time zone v_tz;

    v_slot_minutes := greatest(
      5,
      least(
        120,
        coalesce(
          nullif(pr.professional_settings->>'slot_minutes','')::int,
          nullif(pr.unit_settings->>'slot_minutes','')::int,
          10
        )
      )
    );

    if p_date < v_today then
      v_cursor := v_day_end;
    elsif p_date = v_today then
      v_cursor := greatest(v_day_start,now());

      if v_cursor < v_day_end then
        v_elapsed_minutes := extract(epoch from (v_cursor-v_day_start))/60.0;
        v_cursor := v_day_start
          + make_interval(
              mins => (ceil(v_elapsed_minutes/v_slot_minutes)*v_slot_minutes)::int
            );
      end if;
    else
      v_cursor := v_day_start;
    end if;

    if v_cursor < v_day_start then v_cursor := v_day_start; end if;
    if v_cursor > v_day_end then v_cursor := v_day_end; end if;

    for occ in
      select q.starts_at,q.ends_at
      from (
        select a.starts_at,a.ends_at
        from public.appointments a
        where a.barbershop_id=m.barbershop_id
          and a.professional_id=pr.id
          and a.blocks_schedule
          and a.status in ('confirmed','completed')
          and a.starts_at<v_day_end
          and a.ends_at>v_day_start

        union all

        select bt.starts_at,bt.ends_at
        from public.blocked_times bt
        where bt.barbershop_id=m.barbershop_id
          and bt.professional_id=pr.id
          and bt.starts_at<v_day_end
          and bt.ends_at>v_day_start

        union all

        select
          (p_date::timestamp+bs.start_time) at time zone v_tz,
          (p_date::timestamp+bs.end_time) at time zone v_tz
        from public.blocked_time_series bs
        where bs.barbershop_id=m.barbershop_id
          and bs.professional_id=pr.id
          and bs.is_active
          and p_date>=bs.starts_on
          and (bs.ends_on is null or p_date<=bs.ends_on)
          and bs.weekday=extract(dow from p_date)::int
      ) q
      order by q.starts_at,q.ends_at
    loop
      if occ.ends_at <= v_cursor then
        continue;
      end if;

      if occ.starts_at > v_cursor then
        v_gap_end := least(occ.starts_at,v_day_end);

        if v_gap_end > v_cursor
           and extract(epoch from (v_gap_end-v_cursor))/60 >= v_slot_minutes then
          v_ranges := v_ranges || jsonb_build_array(
            jsonb_build_object(
              'starts_at',v_cursor,
              'ends_at',v_gap_end,
              'start',to_char(v_cursor at time zone v_tz,'HH24:MI'),
              'end',to_char(v_gap_end at time zone v_tz,'HH24:MI'),
              'duration_min',floor(extract(epoch from (v_gap_end-v_cursor))/60)::int
            )
          );
        end if;
      end if;

      v_cursor := greatest(v_cursor,occ.ends_at);

      if v_cursor >= v_day_end then
        exit;
      end if;
    end loop;

    if v_cursor < v_day_end
       and extract(epoch from (v_day_end-v_cursor))/60 >= v_slot_minutes then
      v_ranges := v_ranges || jsonb_build_array(
        jsonb_build_object(
          'starts_at',v_cursor,
          'ends_at',v_day_end,
          'start',to_char(v_cursor at time zone v_tz,'HH24:MI'),
          'end',to_char(v_day_end at time zone v_tz,'HH24:MI'),
          'duration_min',floor(extract(epoch from (v_day_end-v_cursor))/60)::int
        )
      );
    end if;

    v_result := v_result || jsonb_build_array(
      jsonb_build_object(
        'professional_id',pr.id,
        'professional',pr.name,
        'unit_id',pr.unit_id,
        'unit',pr.unit_name,
        'is_closed',false,
        'open_time',to_char(v_day_start at time zone v_tz,'HH24:MI'),
        'close_time',to_char(v_day_end at time zone v_tz,'HH24:MI'),
        'slot_minutes',v_slot_minutes,
        'ranges',v_ranges
      )
    );
  end loop;

  return jsonb_build_object(
    'date',p_date,
    'professional_id',v_filter_prof,
    'professionals',v_result
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_performance_v12_33(p_start_date date, p_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_data jsonb;
  v_commission bigint := 0;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  v_data := public.barberium_staff_performance(p_start_date,p_end_date);

  if m.role='barber' and m.professional_id is not null then
    select coalesce(timezone,'America/Sao_Paulo')
      into v_tz
    from public.barbershops
    where id=m.barbershop_id;

    v_start := p_start_date::timestamp at time zone v_tz;
    v_end := (p_end_date+1)::timestamp at time zone v_tz;

    select coalesce(sum(ce.amount_cents),0)::bigint
      into v_commission
    from public.commission_entries ce
    left join public.appointments a on a.id=ce.appointment_id
    where ce.barbershop_id=m.barbershop_id
      and ce.professional_id=m.professional_id
      and (
        (
          ce.appointment_id is not null
          and a.starts_at>=v_start
          and a.starts_at<v_end
        )
        or
        (
          ce.appointment_id is null
          and ce.created_at>=v_start
          and ce.created_at<v_end
        )
      );
  end if;

  v_data := jsonb_set(
    v_data,
    '{summary,commission_cents}',
    to_jsonb(v_commission),
    true
  );

  return v_data;
end
$function$;

revoke all on function public.barberium_staff_cancel_completed_appointment_v12_23(uuid, text, text, boolean, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_cancel_completed_appointment_v12_23(uuid, text, text, boolean, text) to authenticated;
grant execute on function public.barberium_staff_cancel_completed_appointment_v12_23(uuid, text, text, boolean, text) to service_role;

revoke all on function public.barberium_staff_free_ranges(date, uuid) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_free_ranges(date, uuid) to anon;
grant execute on function public.barberium_staff_free_ranges(date, uuid) to authenticated;
grant execute on function public.barberium_staff_free_ranges(date, uuid) to service_role;

revoke all on function public.barberium_staff_performance_v12_33(date, date) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_performance_v12_33(date, date) to anon;
grant execute on function public.barberium_staff_performance_v12_33(date, date) to authenticated;
grant execute on function public.barberium_staff_performance_v12_33(date, date) to service_role;

revoke all on function public.barberium_customer_open_profile(text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_customer_open_profile(text, text, text) to anon;
grant execute on function public.barberium_customer_open_profile(text, text, text) to authenticated;
grant execute on function public.barberium_customer_open_profile(text, text, text) to service_role;

revoke all on function public.barberium_staff_finance_report(date, date, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_finance_report(date, date, uuid, text) to authenticated;
grant execute on function public.barberium_staff_finance_report(date, date, uuid, text) to service_role;

revoke all on function public.barberium_staff_finance_report_v12_8_1_raw(date, date, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_finance_report_v12_8_1_raw(date, date, uuid, text) to service_role;

revoke all on function public.barberium_staff_finance_report_v12_8_raw(date, date, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.barberium_staff_finance_report_v12_8_raw(date, date, uuid, text) to service_role;

