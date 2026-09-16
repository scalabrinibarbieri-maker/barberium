-- Barberium v12.2 — guardas finais do fechamento de comissão

create or replace function public.barberium_staff_create_commission_settlement(
  p_professional_id uuid,
  p_period_start date,
  p_period_end date,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v_prof record; v_total int; v_count int; v_id uuid; v_status text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if p_period_start is null or p_period_end is null or p_period_end<p_period_start then raise exception 'Período inválido'; end if;
  select p.id,p.name into v_prof from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id;
  if v_prof.id is null then raise exception 'Profissional inválido'; end if;
  perform 1 from public.commission_entries ce
   where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id
     and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_period_start and p_period_end
   for update;
  select count(*)::int,coalesce(sum(ce.amount_cents),0)::int into v_count,v_total
  from public.commission_entries ce
  where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id
    and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_period_start and p_period_end;
  if v_count=0 then raise exception 'Nenhuma comissão em aberto neste período'; end if;
  if v_total<0 then raise exception 'O total em aberto deste período não pode ser negativo'; end if;
  v_status:=case when v_total=0 then 'paid' else 'open' end;
  insert into public.commission_settlements(
    barbershop_id,professional_id,period_start,period_end,base_cents,adjustment_cents,total_cents,paid_cents,status,note,closed_at,created_by_member_id
  ) values (
    m.barbershop_id,p_professional_id,p_period_start,p_period_end,v_total,0,v_total,0,v_status,nullif(trim(coalesce(p_note,'')),''),case when v_total=0 then now() else null end,m.member_id
  ) returning id into v_id;
  update public.commission_entries set settlement_id=v_id,status='settled'
  where barbershop_id=m.barbershop_id and professional_id=p_professional_id
    and status='open' and settlement_id is null and created_at::date between p_period_start and p_period_end;
  return jsonb_build_object('ok',true,'settlement_id',v_id,'entries',v_count,'total_cents',v_total,'status',v_status);
end $$;

create or replace function public.barberium_staff_record_commission_settlement_payment(
  p_settlement_id uuid,
  p_amount_cents integer default null,
  p_payment_method text default 'pix',
  p_paid_at timestamptz default now(),
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v record; v_amount int; v_remaining int; v_paid int; v_status text; v_unit uuid; v_session uuid; v_payment uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if p_payment_method not in ('pix','cash','transfer','other') then raise exception 'Forma de pagamento inválida'; end if;
  select cs.*,p.unit_id into v from public.commission_settlements cs join public.professionals p on p.id=cs.professional_id
  where cs.id=p_settlement_id and cs.barbershop_id=m.barbershop_id for update of cs;
  if v.id is null then raise exception 'Acerto não encontrado'; end if;
  v_remaining:=greatest(0,v.total_cents-v.paid_cents);
  if v_remaining=0 then raise exception 'Acerto já pago'; end if;
  v_amount:=coalesce(p_amount_cents,v_remaining);
  if v_amount<=0 or v_amount>v_remaining then raise exception 'Valor de pagamento inválido'; end if;
  if p_payment_method='cash' then
    v_unit:=v.unit_id;
    select cs.id into v_session from public.cash_sessions cs where cs.barbershop_id=m.barbershop_id and cs.unit_id=v_unit and cs.status='open' order by cs.opened_at desc limit 1;
    if v_session is null then raise exception 'Abra o caixa da unidade antes de pagar comissão em dinheiro'; end if;
  end if;
  insert into public.commission_settlement_payments(settlement_id,amount_cents,payment_method,paid_at,actor_member_id,note)
  values(v.id,v_amount,p_payment_method,coalesce(p_paid_at,now()),m.member_id,nullif(trim(coalesce(p_note,'')),'')) returning id into v_payment;
  v_paid:=v.paid_cents+v_amount;
  v_status:=case when v_paid>=v.total_cents then 'paid' else 'partial' end;
  update public.commission_settlements set paid_cents=v_paid,status=v_status,
    closed_at=case when v_status='paid' then coalesce(p_paid_at,now()) else null end,updated_at=now() where id=v.id;
  if p_payment_method='cash' then
    insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
    values(v_session,m.barbershop_id,v_unit,'expense',-v_amount,'commission_settlement',v_payment,'Pagamento de comissão',m.member_id);
  end if;
  return jsonb_build_object('ok',true,'payment_id',v_payment,'amount_cents',v_amount,'paid_cents',v_paid,'remaining_cents',greatest(0,v.total_cents-v_paid),'status',v_status);
end $$;

revoke all on function public.barberium_staff_create_commission_settlement(uuid,date,date,text) from public,anon;
revoke all on function public.barberium_staff_record_commission_settlement_payment(uuid,integer,text,timestamptz,text) from public,anon;
grant execute on function public.barberium_staff_create_commission_settlement(uuid,date,date,text) to authenticated;
grant execute on function public.barberium_staff_record_commission_settlement_payment(uuid,integer,text,timestamptz,text) to authenticated;
