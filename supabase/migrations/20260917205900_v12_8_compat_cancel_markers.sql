do $$
begin
  if to_regprocedure('public.barberium_staff_set_appointment_status_v12_7_raw(uuid,text)') is null then
    alter function public.barberium_staff_set_appointment_status(uuid,text)
      rename to barberium_staff_set_appointment_status_v12_7_raw;
  end if;
  if to_regprocedure('public.barberium_staff_cancel_completed_appointment_v12_7_raw(uuid,text,text)') is null then
    alter function public.barberium_staff_cancel_completed_appointment(uuid,text,text)
      rename to barberium_staff_cancel_completed_appointment_v12_7_raw;
  end if;
end $$;

create or replace function public.barberium_staff_cancel_appointment_v2(
  p_appointment_id uuid,
  p_cancellation_kind text default 'regular',
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record;
  r jsonb;
  v_kind text:=coalesce(nullif(btrim(p_cancellation_kind),''),'regular');
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
  v_event_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if v_kind not in ('regular','booking_error') then raise exception 'Tipo de cancelamento inválido'; end if;
  if v_reason is null or length(v_reason)<3 then raise exception 'Informe o motivo do cancelamento'; end if;

  r:=public.barberium_staff_set_appointment_status_v12_7_raw(p_appointment_id,'cancelled');
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  update public.appointments
  set cancellation_kind=v_kind,
      cancellation_reason=v_reason,
      updated_at=now()
  where id=p_appointment_id and barbershop_id=m.barbershop_id;

  select e.id into v_event_id
  from public.appointment_events e
  where e.appointment_id=p_appointment_id and e.event_type='status_changed'
  order by e.created_at desc,e.id desc
  limit 1;
  if v_event_id is not null then
    update public.appointment_events
    set details=coalesce(details,'{}'::jsonb)||jsonb_build_object('cancellation_kind',v_kind,'reason',v_reason)
    where id=v_event_id;
  end if;

  return coalesce(r,'{}'::jsonb)||jsonb_build_object('cancellation_kind',v_kind,'reason',v_reason);
end;
$$;

create or replace function public.barberium_staff_cancel_completed_appointment_v2(
  p_appointment_id uuid,
  p_reason text,
  p_refund_method text,
  p_cancellation_kind text default 'regular'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record;
  r jsonb;
  v_kind text:=coalesce(nullif(btrim(p_cancellation_kind),''),'regular');
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
  v_event_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if v_kind not in ('regular','booking_error') then raise exception 'Tipo de cancelamento inválido'; end if;
  if v_reason is null or length(v_reason)<3 then raise exception 'Informe o motivo do cancelamento'; end if;

  r:=public.barberium_staff_cancel_completed_appointment_v12_7_raw(p_appointment_id,v_reason,p_refund_method);

  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Somente o ADM pode cancelar um atendimento concluído'; end if;

  update public.appointments
  set cancellation_kind=v_kind,
      cancellation_reason=v_reason,
      updated_at=now()
  where id=p_appointment_id and barbershop_id=m.barbershop_id;

  select e.id into v_event_id
  from public.appointment_events e
  where e.appointment_id=p_appointment_id and e.event_type='cancelled_with_refund'
  order by e.created_at desc,e.id desc
  limit 1;
  if v_event_id is not null then
    update public.appointment_events
    set details=coalesce(details,'{}'::jsonb)||jsonb_build_object('cancellation_kind',v_kind)
    where id=v_event_id;
  end if;

  return coalesce(r,'{}'::jsonb)||jsonb_build_object('cancellation_kind',v_kind,'reason',v_reason);
end;
$$;

create or replace function public.barberium_staff_set_appointment_status(
  p_appointment_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
begin
  if p_status='cancelled_booking_error' then
    return public.barberium_staff_cancel_appointment_v2(
      p_appointment_id,
      'booking_error',
      'Engano / erro de agendamento'
    );
  elsif p_status='cancelled' then
    return public.barberium_staff_cancel_appointment_v2(
      p_appointment_id,
      'regular',
      'Cancelamento normal'
    );
  end if;
  return public.barberium_staff_set_appointment_status_v12_7_raw(p_appointment_id,p_status);
end;
$$;

create or replace function public.barberium_staff_cancel_completed_appointment(
  p_appointment_id uuid,
  p_reason text,
  p_refund_method text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  v_reason text:=btrim(coalesce(p_reason,''));
  v_kind text:='regular';
begin
  if v_reason like '[ERRO_AGENDAMENTO]%' then
    v_kind:='booking_error';
    v_reason:=nullif(btrim(substr(v_reason,length('[ERRO_AGENDAMENTO]')+1)),'');
    if v_reason is null then v_reason:='Engano / erro de agendamento'; end if;
  end if;
  return public.barberium_staff_cancel_completed_appointment_v2(
    p_appointment_id,
    v_reason,
    p_refund_method,
    v_kind
  );
end;
$$;

create or replace function public.barberium_staff_my_commissions(
  p_start date default (current_date-'90 days'::interval)::date,
  p_end date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record;
  prof uuid;
  v_unsettled int;
  v_settlement_due int;
  v_booking_errors int;
  v_entries jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;
  prof:=m.professional_id;
  if prof is null then
    return jsonb_build_object('entries','[]'::jsonb,'settlements','[]'::jsonb,'open_cents',0,'unsettled_cents',0,'in_settlement_cents',0,'booking_error_cancellations',0);
  end if;

  select coalesce(sum(amount_cents),0)::int into v_unsettled
  from public.commission_entries
  where professional_id=prof and status='open' and settlement_id is null;

  select coalesce(sum(greatest(0,total_cents-paid_cents)),0)::int into v_settlement_due
  from public.commission_settlements
  where professional_id=prof and status in ('open','partial');

  select count(*)::int into v_booking_errors
  from public.appointments a
  where a.professional_id=prof
    and a.barbershop_id=m.barbershop_id
    and a.cancellation_kind='booking_error'
    and a.cancelled_at::date between p_start and p_end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',ce.id,
    'amount_cents',ce.amount_cents,
    'description',ce.description,
    'created_at',ce.created_at,
    'status',ce.status,
    'settlement_id',ce.settlement_id
  ) order by ce.created_at desc),'[]'::jsonb)
  into v_entries
  from public.commission_entries ce
  left join public.appointments a on a.id=ce.appointment_id
  where ce.professional_id=prof
    and ce.created_at::date between p_start and p_end
    and coalesce(a.cancellation_kind,'regular')<>'booking_error';

  if v_booking_errors>0 then
    v_entries:=jsonb_build_array(jsonb_build_object(
      'id',null,
      'amount_cents',0,
      'description','Cancelamentos por erro de agendamento: '||v_booking_errors,
      'created_at',p_end::timestamp+interval '23 hours 59 minutes',
      'status','open',
      'settlement_id',null,
      'booking_error_summary',true
    ))||v_entries;
  end if;

  return jsonb_build_object(
    'open_cents',v_unsettled+v_settlement_due,
    'unsettled_cents',v_unsettled,
    'in_settlement_cents',v_settlement_due,
    'booking_error_cancellations',v_booking_errors,
    'entries',v_entries,
    'settlements',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',cs.id,
        'period_start',cs.period_start,
        'period_end',cs.period_end,
        'base_cents',cs.base_cents,
        'adjustment_cents',cs.adjustment_cents,
        'total_cents',cs.total_cents,
        'paid_cents',cs.paid_cents,
        'remaining_cents',greatest(0,cs.total_cents-cs.paid_cents),
        'status',cs.status,
        'note',cs.note,
        'created_at',cs.created_at,
        'closed_at',cs.closed_at
      ) order by cs.period_end desc,cs.created_at desc)
      from public.commission_settlements cs
      where cs.professional_id=prof and cs.period_end>=p_start and cs.period_start<=p_end
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.barberium_staff_set_appointment_status_v12_7_raw(uuid,text) from public,anon,authenticated;
revoke all on function public.barberium_staff_cancel_completed_appointment_v12_7_raw(uuid,text,text) from public,anon,authenticated;
revoke all on function public.barberium_staff_set_appointment_status(uuid,text) from public,anon;
revoke all on function public.barberium_staff_cancel_completed_appointment(uuid,text,text) from public,anon;
grant execute on function public.barberium_staff_set_appointment_status(uuid,text) to authenticated;
grant execute on function public.barberium_staff_cancel_completed_appointment(uuid,text,text) to authenticated;

