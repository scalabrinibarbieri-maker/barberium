-- v12.3.1: cancelamento integral de atendimento concluído.
alter table public.appointment_receivables drop constraint appointment_receivables_status_check;
alter table public.appointment_receivables add constraint appointment_receivables_status_check check(status in ('open','partial','paid','cancelled'));
create unique index if not exists commission_appointment_cancellation_once on public.commission_entries(source_id) where source_type='appointment_cancellation';
create or replace function public.barberium_staff_cancel_completed_appointment(p_appointment_id uuid,p_reason text,p_refund_method text) returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; a record; sale record; ce record; usage record; previous jsonb; result jsonb; service_refund int:=0; product_refund int:=0; service_pending int:=0; product_pending int:=0; covered int:=0; service_due int:=0; cash_session uuid; refund_id uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership();
 if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Somente o ADM pode cancelar um atendimento concluído'; end if;
 if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento'; end if;
 if coalesce(p_refund_method,'') not in ('pix','cash','debit','credit','transfer','other') then raise exception 'Selecione a forma de devolução'; end if;
 select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update;
 if a.id is null then raise exception 'Atendimento não encontrado'; end if;
 select details into previous from public.appointment_events where appointment_id=a.id and event_type='cancelled_with_refund' order by created_at desc limit 1;
 if a.status='cancelled' and previous is not null then return previous||jsonb_build_object('ok',true,'already_cancelled',true); end if;
 if a.status<>'completed' then raise exception 'Este atendimento não está concluído'; end if;
 select coalesce(sum(coverage_cents),0) into covered from public.appointment_membership_uses where appointment_id=a.id and status='consumed';
 service_due:=greatest(0,a.total_price_cents-covered);
 select greatest(0,coalesce((select sum(amount_cents) from public.appointment_payments where appointment_id=a.id),0)-coalesce((select sum(amount_cents) from public.finance_refunds where appointment_id=a.id and product_sale_id is null and membership_id is null),0)) into service_refund;
 select coalesce(sum(greatest(0,original_due_cents-paid_cents)),0) into service_pending from public.appointment_receivables where appointment_id=a.id and status in ('open','partial');
 select * into sale from public.product_sales where appointment_id=a.id for update;
 if sale.id is not null and sale.status='completed' then
  product_refund:=sale.paid_cents;product_pending:=sale.pending_cents;
 end if;
 if p_refund_method='cash' and service_refund+product_refund>0 then
  select id into cash_session from public.cash_sessions where unit_id=a.unit_id and barbershop_id=m.barbershop_id and status='open' order by opened_at desc limit 1 for update;
  if cash_session is null then raise exception 'Abra o caixa da unidade antes de registrar a devolução em dinheiro'; end if;
 end if;
 if sale.id is not null and sale.status='completed' then
  perform public.barberium_staff_refund_product_sale(sale.id,p_reason,p_refund_method);
 elsif sale.id is not null and sale.status='draft' then
  delete from public.product_sales where id=sale.id;
 end if;
 if service_refund>0 then
  insert into public.finance_refunds(barbershop_id,unit_id,appointment_id,amount_cents,reason,actor_member_id,refund_method)
  values(m.barbershop_id,a.unit_id,a.id,service_refund,btrim(p_reason),m.member_id,p_refund_method) returning id into refund_id;
  if p_refund_method='cash' then
   insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
   values(cash_session,m.barbershop_id,a.unit_id,'refund',-service_refund,'appointment_refund',refund_id,'Cancelamento de atendimento: '||btrim(p_reason),m.member_id);
  end if;
 end if;
 update public.appointment_receivables set status='cancelled',updated_at=now() where appointment_id=a.id and status in ('open','partial');
 for ce in select * from public.commission_entries where appointment_id=a.id and source_type in ('service','membership_usage') and amount_cents<>0 order by id for update loop
  insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents,status)
  values(ce.barbershop_id,ce.unit_id,ce.professional_id,a.id,'appointment_cancellation',ce.id,'Estorno de comissão • cancelamento do atendimento',-ce.base_cents,ce.rate_percent,-ce.amount_cents,'open') on conflict(source_id) where source_type='appointment_cancellation' do nothing;
 end loop;
 for usage in select * from public.appointment_membership_uses where appointment_id=a.id and status in ('consumed','reserved','forfeited','decision_required') order by bucket_id,id for update loop
  if usage.bucket_id is not null then
   update public.membership_credit_buckets set used_credits=greatest(0,used_credits-case when usage.status in ('consumed','forfeited') then usage.credit_qty else 0 end),reserved_credits=greatest(0,reserved_credits-case when usage.status in ('reserved','decision_required') then usage.credit_qty else 0 end) where id=usage.bucket_id;
  end if;
  update public.appointment_membership_uses set status='released' where id=usage.id;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(usage.membership_id,'benefit_returned',jsonb_build_object('appointment_id',a.id,'use_id',usage.id,'reason',p_reason),m.member_id);
 end loop;
 update public.appointments set status='cancelled',cancelled_at=now(),updated_at=now() where id=a.id;
 result:=jsonb_build_object('ok',true,'appointment_id',a.id,'from','completed','to','cancelled','reason',btrim(p_reason),'refund_method',p_refund_method,'service_refund_cents',service_refund,'product_refund_cents',product_refund,'service_pending_cancelled_cents',service_pending,'product_pending_cancelled_cents',product_pending,'service_due_cents',service_due,'membership_covered_cents',covered);
 insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'cancelled_with_refund',result);
 return result;
end $$;
revoke all on function public.barberium_staff_cancel_completed_appointment(uuid,text,text) from public,anon;
grant execute on function public.barberium_staff_cancel_completed_appointment(uuid,text,text) to authenticated,service_role;

CREATE OR REPLACE FUNCTION public.barberium_staff_set_appointment_status(p_appointment_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; perms jsonb; a public.appointments%rowtype; v_use record; v_rule text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if p_status not in ('confirmed','completed','cancelled','no_show') then raise exception 'Status inválido'; end if;
  if p_status='completed' then raise exception 'Use a etapa de pagamento para concluir o atendimento'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  select * into a from public.appointments where id=p_appointment_id for update;
  if a.id is null or a.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if;
  if m.role='barber' then
    if a.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if;
    if p_status='no_show' and not barberium.permission_enabled(perms,'mark_no_show') then raise exception 'Sem permissão para marcar falta'; end if;
    if p_status='cancelled' and not barberium.permission_enabled(perms,'cancel_appointment') then raise exception 'Sem permissão para cancelar'; end if;
    if p_status='confirmed' then raise exception 'Somente o ADM pode restaurar para confirmado'; end if;
    if a.status<>'confirmed' then raise exception 'Este atendimento já foi finalizado'; end if;
  end if;
  if a.status='completed' then raise exception 'Use Cancelar atendimento concluído para registrar a devolução e reverter produtos e comissões'; end if;
  if p_status='confirmed' and (exists(select 1 from public.appointment_events where appointment_id=a.id and event_type='cancelled_with_refund') or exists(select 1 from public.appointment_membership_uses where appointment_id=a.id and status in ('consumed','forfeited'))) then raise exception 'Atendimento com histórico de consumo ou estorno não pode ser reaberto. Crie um novo agendamento'; end if;
  if a.status=p_status then return jsonb_build_object('ok',true,'status',a.status); end if;
  if p_status='confirmed' and exists(select 1 from public.appointment_payments where appointment_id=a.id) then raise exception 'Atendimento com movimentação financeira não pode ser restaurado diretamente'; end if;
  if p_status='no_show' then
    for v_use in
      select u.id,u.bucket_id,u.credit_qty,u.membership_id,coalesce(v.rules->>'no_show_rule','keep') no_show_rule
      from public.appointment_membership_uses u join public.customer_memberships cm on cm.id=u.membership_id join public.membership_plan_versions v on v.id=cm.plan_version_id
      where u.appointment_id=a.id and u.status='reserved' for update of u
    loop
      v_rule:=v_use.no_show_rule;
      if v_rule='lose' then
        update public.appointment_membership_uses set status='forfeited',consumed_at=now() where id=v_use.id;
        if v_use.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty),used_credits=used_credits+v_use.credit_qty where id=v_use.bucket_id; end if;
      elsif v_rule='admin' then
        update public.appointment_membership_uses set status='decision_required' where id=v_use.id;
      else
        update public.appointment_membership_uses set status='released' where id=v_use.id;
        if v_use.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty) where id=v_use.bucket_id; end if;
      end if;
    end loop;
  elsif p_status='cancelled' then
    for v_use in select id,bucket_id,credit_qty from public.appointment_membership_uses where appointment_id=a.id and status='reserved' for update loop
      if v_use.bucket_id is not null then update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty) where id=v_use.bucket_id; end if;
      update public.appointment_membership_uses set status='released' where id=v_use.id;
    end loop;
  end if;
  if p_status in ('cancelled','no_show') then
    if exists(select 1 from public.product_sales where appointment_id=a.id and status='completed') then
      raise exception 'Estorne os produtos deste atendimento antes de cancelar. Escolha a forma de devolução no detalhe da venda';
    end if;
    delete from public.product_sales where appointment_id=a.id and status='draft';
  end if;
  begin
    update public.appointments set status=p_status,cancelled_at=case when p_status='cancelled' then now() else null end,updated_at=now() where id=a.id;
  exception when exclusion_violation then raise exception 'Horário já foi ocupado por outro atendimento'; end;
  insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from',a.status,'to',p_status));
  return jsonb_build_object('ok',true,'appointment_id',a.id,'status',p_status);
end $function$

;

CREATE OR REPLACE FUNCTION public.barberium_staff_record_receivable_payment(p_appointment_id uuid, p_payments jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; r record; pay jsonb; sum_paid int:=0; amount int; meth text; provider uuid; inst int; fee int; remaining int; v_session uuid; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; if m.role not in ('owner','admin') then raise exception 'Recebimento de pendências restrito ao ADM'; end if; perform 1 from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id and status='completed' for update; if not found then raise exception 'Atendimento não disponível para recebimento'; end if; select * into r from public.appointment_receivables where appointment_id=p_appointment_id and barbershop_id=m.barbershop_id for update; if r.appointment_id is null or r.status not in ('open','partial') then raise exception 'Pendência não encontrada'; end if; for pay in select * from jsonb_array_elements(p_payments) loop meth:=pay->>'method'; amount:=coalesce((pay->>'amount_cents')::int,0); provider:=nullif(pay->>'provider_id','')::uuid; inst:=coalesce(nullif(pay->>'installments','')::int,1); if amount<=0 then raise exception 'Pagamento inválido'; end if; fee:=barberium.payment_fee_cents(provider,meth,inst,amount); insert into public.appointment_payments(barbershop_id,unit_id,appointment_id,method,amount_cents,provider_id,installments,fee_cents,actor_member_id) values(m.barbershop_id,r.unit_id,p_appointment_id,meth,amount,provider,case when meth='credit' then inst end,fee,m.member_id); if meth='cash' then select id into v_session from public.cash_sessions where unit_id=r.unit_id and status='open' order by opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,r.unit_id,'payment',amount,'appointment',p_appointment_id,'Recebimento de pendência',m.member_id); end if; end if; sum_paid:=sum_paid+amount; end loop; remaining:=r.original_due_cents-r.paid_cents; if sum_paid<=0 or sum_paid>remaining then raise exception 'Valor inválido'; end if; update public.appointment_receivables set paid_cents=paid_cents+sum_paid,status=case when paid_cents+sum_paid>=original_due_cents then 'paid' else 'partial' end,updated_at=now() where appointment_id=p_appointment_id; return jsonb_build_object('ok',true,'received_cents',sum_paid,'remaining_cents',remaining-sum_paid); end $function$

;

CREATE OR REPLACE FUNCTION public.barberium_staff_appointment_finance(p_appointment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; a record; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id; if a.id is null then raise exception 'Atendimento inválido'; end if; if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if; return jsonb_build_object('refunds_cents',coalesce((select sum(amount_cents) from public.finance_refunds where appointment_id=a.id and product_sale_id is null and membership_id is null),0),'total_price_cents',a.total_price_cents,'membership_covered_cents',coalesce((select sum(coverage_cents) from public.appointment_membership_uses where appointment_id=a.id and status in ('reserved','consumed')),0),'paid_cents',coalesce((select sum(amount_cents) from public.appointment_payments where appointment_id=a.id),0),'fees_cents',coalesce((select sum(fee_cents) from public.appointment_payments where appointment_id=a.id),0),'receivable',(select jsonb_build_object('original_due_cents',r.original_due_cents,'paid_cents',r.paid_cents,'remaining_cents',case when r.status='cancelled' then 0 else r.original_due_cents-r.paid_cents end,'status',r.status,'due_date',r.due_date,'note',r.note) from public.appointment_receivables r where r.appointment_id=a.id),'uses',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'status',u.status,'coverage_cents',u.coverage_cents,'service',s.name,'plan',p.name) order by u.created_at) from public.appointment_membership_uses u join public.services s on s.id=u.covered_service_id join public.customer_memberships cm on cm.id=u.membership_id join public.membership_plans p on p.id=cm.plan_id where u.appointment_id=a.id),'[]'::jsonb)); end $function$

;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_overview(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; gross int; fees int; expenses_paid int; commissions int; receivables int; target int; result int; refunds int; appointment_gross int; membership_gross int; appointment_fees int; membership_fees int; product_gross int; product_fees int; product_pending int; product_cost int; cancelled_pending int:=0;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Financeiro geral restrito ao ADM'; end if; if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
 if p_basis='cash' then
   select coalesce(sum(ap.amount_cents),0),coalesce(sum(ap.fee_cents),0) into appointment_gross,appointment_fees from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id);
 else
   select coalesce(sum(a.total_price_cents),0),coalesce(sum((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id)),0) into appointment_gross,appointment_fees from public.appointments a where a.barbershop_id=m.barbershop_id and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund')) and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id);
 end if;
 select coalesce(sum(mp.amount_cents),0),coalesce(sum(mp.fee_cents),0) into membership_gross,membership_fees from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id);
 if p_basis='cash' then
 select coalesce(sum(amount_cents),0),coalesce(sum(fee_cents),0) into product_gross,product_fees from public.product_sale_payments where barbershop_id=m.barbershop_id and received_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id);
 else
 select coalesce(sum(total_cents),0),coalesce(sum((select sum(fee_cents) from public.product_sale_payments where sale_id=ps.id)),0) into product_gross,product_fees from public.product_sales ps where barbershop_id=m.barbershop_id and status in ('completed','refunded') and completed_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id);
 end if;
 select coalesce(sum(cost_total_cents),0) into product_cost from public.product_sales where barbershop_id=m.barbershop_id and status='completed' and completed_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id);
 gross:=appointment_gross+membership_gross+product_gross; fees:=appointment_fees+membership_fees+product_fees;
 select coalesce(sum(fr.amount_cents),0) into refunds from public.finance_refunds fr where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id);
 select coalesce(sum(e.amount_cents),0) into expenses_paid from public.expenses e where e.barbershop_id=m.barbershop_id and e.status='paid' and (case when p_basis='cash' then coalesce(e.paid_at::date,e.due_date) else e.due_date end) between p_start and p_end and (p_unit_id is null or e.unit_id=p_unit_id);
 select coalesce(sum(ce.amount_cents),0) into commissions from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into receivables from public.appointment_receivables ar where ar.barbershop_id=m.barbershop_id and ar.status in ('open','partial') and (p_unit_id is null or ar.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into product_pending from public.product_sale_receivables where barbershop_id=m.barbershop_id and status in ('open','partial') and (p_unit_id is null or unit_id=p_unit_id); receivables:=receivables+product_pending;
 select revenue_target_cents into target from public.financial_goals fg where fg.barbershop_id=m.barbershop_id and fg.unit_id is not distinct from p_unit_id and fg.month=date_trunc('month',p_end)::date;
 if p_basis='accrual' then select coalesce(sum((ev.details->>'service_pending_cancelled_cents')::int+(ev.details->>'product_pending_cancelled_cents')::int),0) into cancelled_pending from public.appointment_events ev join public.appointments ap on ap.id=ev.appointment_id where ev.barbershop_id=m.barbershop_id and ev.event_type='cancelled_with_refund' and ev.created_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id); end if;
 result:=gross-refunds-cancelled_pending-fees-commissions-expenses_paid-product_cost;
 return jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'product_revenue_cents',product_gross,'product_cost_cents',product_cost,'service_revenue_cents',appointment_gross,'gross_cents',gross,'refunds_cents',refunds,'fees_cents',fees,'cancelled_pending_cents',cancelled_pending,'net_received_cents',gross-refunds-cancelled_pending-fees,'expenses_cents',expenses_paid,'commissions_cents',commissions,'operating_result_cents',result,'receivables_cents',receivables,'revenue_target_cents',target,'target_progress_percent',case when coalesce(target,0)>0 then round((gross-refunds)*100.0/target,1) else null end,'by_method',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_cents',amount) order by amount desc) from (
   select method,sum(amount_cents)::int amount from (
     select ap.method,ap.amount_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
     union all
     select mp.method,mp.amount_cents from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
     union all select method,amount_cents from public.product_sale_payments where barbershop_id=m.barbershop_id and received_at::date between p_start and p_end and (p_unit_id is null or unit_id=p_unit_id)
   ) x group by method
 ) q),'[]'::jsonb));
end $function$

;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_report(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; v_overview jsonb; v_unit_name text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Relatórios financeiros restritos ao ADM'; end if;
  if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if;
  if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
  if p_unit_id is not null then
    select u.name into v_unit_name from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id;
    if v_unit_name is null then raise exception 'Unidade inválida'; end if;
  else v_unit_name:='Consolidado da empresa'; end if;
  v_overview:=public.barberium_staff_finance_overview(p_start,p_end,p_unit_id,p_basis);
  return jsonb_build_object(
    'meta',jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'unit_id',p_unit_id,'unit_name',v_unit_name,'generated_at',now()),
    'overview',v_overview,
    'payments',coalesce((select jsonb_agg(x order by (x->>'date')::timestamptz desc) from (
      select jsonb_build_object('id',ap.id,'source_type','appointment','date',ap.received_at,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'method',ap.method,'provider',pp.name,'installments',ap.installments,'amount_cents',ap.amount_cents,'fee_cents',ap.fee_cents,'net_cents',ap.amount_cents-ap.fee_cents,'note',ap.note) x
      from public.appointment_payments ap join public.appointments a on a.id=ap.appointment_id join public.units u on u.id=ap.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id left join public.payment_providers pp on pp.id=ap.provider_id
      where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
      union all
      select jsonb_build_object('id',mpay.id,'source_type','membership','date',mpay.paid_at,'unit',u.name,'customer',c.full_name,'service',case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,'professional',null,'method',mpay.method,'provider',pp.name,'installments',mpay.installments,'amount_cents',mpay.amount_cents,'fee_cents',mpay.fee_cents,'net_cents',mpay.amount_cents-mpay.fee_cents,'note',null) x
      from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id join public.customers c on c.id=cm.customer_id join public.membership_plans pl on pl.id=cm.plan_id left join public.units u on u.id=cm.origin_unit_id left join public.payment_providers pp on pp.id=mpay.provider_id
      where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      union all
      select jsonb_build_object('id',pay.id,'source_type','product','date',pay.received_at,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'method',pay.method,'provider',pp.name,'installments',pay.installments,'amount_cents',pay.amount_cents,'fee_cents',pay.fee_cents,'net_cents',pay.amount_cents-pay.fee_cents,'note',pay.note)
      from public.product_sale_payments pay join public.product_sales ps on ps.id=pay.sale_id join public.units u on u.id=ps.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id left join public.payment_providers pp on pp.id=pay.provider_id
      where ps.barbershop_id=m.barbershop_id and pay.received_at::date between p_start and p_end and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) q),'[]'::jsonb),
    'accrual_revenue',coalesce((select jsonb_agg(x order by (x->>'date')::timestamptz desc) from (
      select jsonb_build_object('appointment_id',a.id,'source_type','appointment','date',a.starts_at,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'amount_cents',a.total_price_cents) x
      from public.appointments a join public.units u on u.id=a.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id
      where a.barbershop_id=m.barbershop_id and (a.status='completed' or exists(select 1 from public.appointment_events ev where ev.appointment_id=a.id and ev.event_type='cancelled_with_refund')) and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)
      union all
      select jsonb_build_object('appointment_id',null,'source_type','membership','date',mpay.paid_at,'unit',u.name,'customer',c.full_name,'service',case when cm.plan_type='subscription' then 'Assinatura: '||pl.name else 'Pacote: '||pl.name end,'professional',null,'amount_cents',mpay.amount_cents) x
      from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id join public.customers c on c.id=cm.customer_id join public.membership_plans pl on pl.id=cm.plan_id left join public.units u on u.id=cm.origin_unit_id
      where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
      union all
      select jsonb_build_object('appointment_id',ps.appointment_id,'source_type','product','date',ps.completed_at,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'amount_cents',ps.total_cents)
      from public.product_sales ps join public.units u on u.id=ps.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id
      where ps.barbershop_id=m.barbershop_id and ps.status in ('completed','refunded') and ps.completed_at::date between p_start and p_end and (p_unit_id is null or ps.unit_id=p_unit_id)
    ) q),'[]'::jsonb),
    'refunds',coalesce((select jsonb_agg(jsonb_build_object('id',fr.id,'date',fr.created_at,'unit',u.name,'source_type',case when fr.product_sale_id is not null then 'product' when fr.membership_id is not null then 'membership' else 'appointment' end,'customer',coalesce(pc.full_name,mc.full_name,ac.full_name),'description',coalesce(case when fr.product_sale_id is not null then 'Produtos' end,case when cm.plan_type='subscription' then 'Assinatura: '||mpl.name when cm.plan_type='package' then 'Pacote: '||mpl.name end,asv.name),'method',fr.refund_method,'amount_cents',fr.amount_cents,'reason',fr.reason) order by fr.created_at desc)
      from public.finance_refunds fr join public.units u on u.id=fr.unit_id left join public.customer_memberships cm on cm.id=fr.membership_id left join public.membership_plans mpl on mpl.id=cm.plan_id left join public.customers mc on mc.id=cm.customer_id left join public.appointments aa on aa.id=fr.appointment_id left join public.customers ac on ac.id=aa.customer_id left join public.services asv on asv.id=aa.service_id left join public.product_sales ps on ps.id=fr.product_sale_id left join public.customers pc on pc.id=ps.customer_id
      where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id)),'[]'::jsonb),
    'expenses',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'unit',u.name,'category',ec.name,'description',e.description,'amount_cents',e.amount_cents,'due_date',e.due_date,'status',e.status,'payment_method',e.payment_method,'paid_from_cash',e.paid_from_cash,'paid_at',e.paid_at,'note',e.note) order by e.due_date desc,e.created_at desc) from public.expenses e join public.units u on u.id=e.unit_id left join public.expense_categories ec on ec.id=e.category_id where e.barbershop_id=m.barbershop_id and (e.due_date between p_start and p_end or (e.paid_at is not null and e.paid_at::date between p_start and p_end)) and (p_unit_id is null or e.unit_id=p_unit_id)),'[]'::jsonb),
    'commissions',coalesce((select jsonb_agg(jsonb_build_object('id',ce.id,'date',ce.created_at,'unit',u.name,'professional',pr.name,'source_type',ce.source_type,'description',ce.description,'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,'amount_cents',ce.amount_cents,'status',ce.status) order by ce.created_at desc) from public.commission_entries ce join public.units u on u.id=ce.unit_id join public.professionals pr on pr.id=ce.professional_id where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)),'[]'::jsonb),
    'receivables',coalesce((select jsonb_agg(jsonb_build_object('appointment_id',ar.appointment_id,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'original_due_cents',ar.original_due_cents,'paid_cents',ar.paid_cents,'open_cents',case when ar.status='cancelled' then 0 else greatest(0,ar.original_due_cents-ar.paid_cents) end,'status',ar.status,'due_date',ar.due_date,'note',ar.note,'created_at',ar.created_at) order by coalesce(ar.due_date,ar.created_at::date),ar.created_at) from public.appointment_receivables ar join public.appointments a on a.id=ar.appointment_id join public.units u on u.id=ar.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id where ar.barbershop_id=m.barbershop_id and ar.created_at::date<=p_end and (p_unit_id is null or ar.unit_id=p_unit_id)),'[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('sale_id',r.sale_id,'source_type','product','appointment_id',ps.appointment_id,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'original_due_cents',r.original_due_cents,'paid_cents',r.paid_cents,'open_cents',case when r.status='cancelled' then 0 else greatest(0,r.original_due_cents-r.paid_cents) end,'status',r.status,'due_date',r.due_date,'note',r.note,'created_at',r.created_at)) from public.product_sale_receivables r join public.product_sales ps on ps.id=r.sale_id join public.units u on u.id=r.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id where r.barbershop_id=m.barbershop_id and r.created_at::date<=p_end and (p_unit_id is null or r.unit_id=p_unit_id)),'[]'::jsonb),
    'cash_sessions',coalesce((select jsonb_agg(jsonb_build_object('id',cs.id,'unit',u.name,'status',cs.status,'opening_balance_cents',cs.opening_balance_cents,'opened_at',cs.opened_at,'expected_closing_cents',cs.expected_closing_cents,'counted_closing_cents',cs.counted_closing_cents,'difference_cents',cs.difference_cents,'closing_justification',cs.closing_justification,'closed_at',cs.closed_at) order by cs.opened_at desc) from public.cash_sessions cs join public.units u on u.id=cs.unit_id where cs.barbershop_id=m.barbershop_id and cs.opened_at::date<=p_end and coalesce(cs.closed_at::date,p_end)>=p_start and (p_unit_id is null or cs.unit_id=p_unit_id)),'[]'::jsonb),
    'cash_movements',coalesce((select jsonb_agg(jsonb_build_object('id',mov.id,'date',mov.created_at,'unit',u.name,'type',mov.movement_type,'amount_cents',mov.amount_cents,'reference_type',mov.reference_type,'note',mov.note) order by mov.created_at desc) from public.cash_movements mov join public.units u on u.id=mov.unit_id where mov.barbershop_id=m.barbershop_id and mov.created_at::date between p_start and p_end and (p_unit_id is null or mov.unit_id=p_unit_id)),'[]'::jsonb),
    'by_provider',coalesce((select jsonb_agg(jsonb_build_object('provider',provider,'method',method,'installments',installments,'gross_cents',gross_cents,'fees_cents',fees_cents,'net_cents',gross_cents-fees_cents,'transactions',transactions) order by gross_cents desc) from (
      select provider,method,installments,sum(amount_cents)::int gross_cents,sum(fee_cents)::int fees_cents,count(*)::int transactions from (
        select coalesce(pp.name,'Sem provedor') provider,ap.method,coalesce(ap.installments,1) installments,ap.amount_cents,ap.fee_cents from public.appointment_payments ap left join public.payment_providers pp on pp.id=ap.provider_id where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
        union all
        select coalesce(pp.name,'Sem provedor'),mpay.method,coalesce(mpay.installments,1),mpay.amount_cents,mpay.fee_cents from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id left join public.payment_providers pp on pp.id=mpay.provider_id where cm.barbershop_id=m.barbershop_id and mpay.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
        union all
        select coalesce(pp.name,'Sem provedor'),pay.method,coalesce(pay.installments,1),pay.amount_cents,pay.fee_cents from public.product_sale_payments pay left join public.payment_providers pp on pp.id=pay.provider_id where pay.barbershop_id=m.barbershop_id and pay.received_at::date between p_start and p_end and (p_unit_id is null or pay.unit_id=p_unit_id)
      ) z group by provider,method,installments
    ) q),'[]'::jsonb),
    'by_unit',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'unit',u.name,'gross_cents',coalesce(x.gross_cents,0),'fees_cents',coalesce(x.fees_cents,0),'net_cents',coalesce(x.gross_cents,0)-coalesce(x.fees_cents,0)) order by u.name) from public.units u left join lateral (
      select sum(amount_cents)::int gross_cents,sum(fee_cents)::int fees_cents from (
        select ap.amount_cents,ap.fee_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.unit_id=u.id and ap.received_at::date between p_start and p_end
        union all select mpay.amount_cents,mpay.fee_cents from public.membership_payments mpay join public.customer_memberships cm on cm.id=mpay.membership_id where cm.barbershop_id=m.barbershop_id and cm.origin_unit_id=u.id and mpay.paid_at::date between p_start and p_end
        union all select pay.amount_cents,pay.fee_cents from public.product_sale_payments pay where pay.barbershop_id=m.barbershop_id and pay.unit_id=u.id and pay.received_at::date between p_start and p_end
      ) z
    ) x on true where u.barbershop_id=m.barbershop_id and (p_unit_id is null or u.id=p_unit_id)),'[]'::jsonb),
    'by_professional',coalesce((select jsonb_agg(jsonb_build_object('professional_id',pr.id,'professional',pr.name,'completed_cents',coalesce(x.completed_cents,0),'completed_count',coalesce(x.completed_count,0),'commission_cents',coalesce(y.commission_cents,0)) order by pr.name) from public.professionals pr left join lateral (select sum(a.total_price_cents)::int completed_cents,count(*)::int completed_count from public.appointments a where a.barbershop_id=m.barbershop_id and a.professional_id=pr.id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)) x on true left join lateral (select sum(ce.amount_cents)::int commission_cents from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.professional_id=pr.id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id)) y on true where pr.barbershop_id=m.barbershop_id and pr.is_active),'[]'::jsonb)
  );
end $function$

;

