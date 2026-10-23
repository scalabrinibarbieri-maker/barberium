-- Barberium · Etapa 7d (parte 2) · Regras de status num lugar só · 22/10/2026
--
-- Antes, cada função que muda o status de um atendimento tinha a sua cópia das regras de
-- quem pode fazer o quê (mudar status, concluir, cancelar concluído). Agora:
--
-- 1. barberium.regra_de_status: todas as regras de papel e permissão, por ação, com as
--    mesmas mensagens de antes e na mesma ordem. As funções do site chamam esta regra
--    (por barberium.conferir_status) no lugar das cópias que tinham.
-- 2. barberium.transicao_de_status_permitida + gatilho na tabela de atendimentos: nenhuma
--    função consegue gravar uma passagem de status fora do mapa. O mapa é exatamente o que
--    já era possível (decisão do dono, 22/10): confirmado → concluído, cancelado ou falta;
--    concluído → cancelado; cancelado ou falta → confirmado; cancelado ↔ falta.
-- 3. Mudança de regra (decisão do dono, 22/10): só atendimento confirmado pode ser editado.
--    O site já era assim; o banco deixava editar um atendimento concluído, cancelado ou com
--    falta (por exemplo, trocar o valor de um corte já pago, sem mexer no pagamento nem na
--    comissão). Os encaixes já eram travados assim pela função deles.
--
-- O que não muda: o que cada função faz com dinheiro (pagamentos, caixa, reembolsos,
-- pendências, comissões, fichas de plano e estoque), as travas de dinheiro para reabrir um
-- atendimento, e as funções do site do cliente (cancelar e remarcar só horário confirmado).
--
-- Rollback: docs/etapa7d2_rollback.sql

create or replace function barberium.regra_de_status(p_acao text, p_papel text, p_perms jsonb, p_proprio boolean, p_de text, p_para text)
 returns text
 language plpgsql
 immutable
 set search_path to 'pg_catalog'
as $function$
-- Devolve a mensagem de recusa, ou null quando pode. p_papel: owner, admin, staff ou barber;
-- p_perms: permissões do barbeiro; p_proprio: o atendimento é do próprio barbeiro.
begin
  if p_acao = 'mudar' then
    -- Cancelar, marcar falta ou restaurar para confirmado (barberium_staff_set_appointment_status).
    if p_papel = 'barber' then
      if not p_proprio then return 'Sem permissão para este agendamento'; end if;
      if p_para = 'no_show' and not barberium.permission_enabled(p_perms, 'mark_no_show') then return 'Sem permissão para marcar falta'; end if;
      if p_para = 'cancelled' and not barberium.permission_enabled(p_perms, 'cancel_appointment') then return 'Sem permissão para cancelar'; end if;
      if p_para = 'confirmed' then return 'Somente o ADM pode restaurar para confirmado'; end if;
      if p_de <> 'confirmed' then return 'Este atendimento já foi finalizado'; end if;
    end if;
    if p_de = 'completed' then
      return 'Use Cancelar atendimento concluído para registrar a devolução e reverter produtos e comissões';
    end if;
    return null;
  elsif p_acao = 'concluir' then
    -- Concluir com pagamento (barberium_staff_complete_appointment).
    if p_papel = 'barber' and not p_proprio then return 'Atendimento inválido'; end if;
    if p_de <> 'confirmed' then return 'Atendimento já finalizado'; end if;
    if p_papel = 'barber' and not barberium.permission_enabled(p_perms, 'mark_completed') then return 'Sem permissão para concluir'; end if;
    return null;
  elsif p_acao = 'cancelar_concluido' then
    -- Cancelar atendimento concluído, com ou sem reembolso. p_de nulo: confere só quem pede.
    if p_papel is null or p_papel not in ('owner', 'admin') then return 'Somente o ADM pode cancelar um atendimento concluído'; end if;
    if p_de is not null and p_de <> 'completed' then return 'Este atendimento não está concluído'; end if;
    return null;
  elsif p_acao = 'editar' then
    -- Editar serviço, horário, valor ou observação.
    if p_de is distinct from 'confirmed' then return 'Somente atendimento confirmado pode ser editado'; end if;
    return null;
  end if;
  raise exception 'Ação de status desconhecida: %', p_acao;
end
$function$;
revoke all on function barberium.regra_de_status(text, text, jsonb, boolean, text, text) from public;
comment on function barberium.regra_de_status(text, text, jsonb, boolean, text, text) is
  'Etapa 7d: quem pode mudar o status de um atendimento (mudar, concluir, cancelar_concluido, editar). Devolve a mensagem de recusa ou null.';

create or replace function barberium.conferir_status(p_acao text, p_papel text, p_perms jsonb, p_proprio boolean, p_de text, p_para text)
 returns void
 language plpgsql
 immutable
 set search_path to 'pg_catalog'
as $function$
declare v_recusa text := barberium.regra_de_status(p_acao, p_papel, p_perms, p_proprio, p_de, p_para);
begin
  if v_recusa is not null then raise exception '%', v_recusa; end if;
end
$function$;
revoke all on function barberium.conferir_status(text, text, jsonb, boolean, text, text) from public;
comment on function barberium.conferir_status(text, text, jsonb, boolean, text, text) is
  'Etapa 7d: barberium.regra_de_status que recusa com erro (a mesma mensagem de antes).';

create or replace function barberium.transicao_de_status_permitida(p_de text, p_para text)
 returns boolean
 language sql
 immutable
 set search_path to 'pg_catalog'
as $function$
  select p_de is not distinct from p_para
      or (p_de, p_para) in (('confirmed', 'completed'), ('confirmed', 'cancelled'), ('confirmed', 'no_show'),
                            ('completed', 'cancelled'),
                            ('cancelled', 'confirmed'), ('cancelled', 'no_show'),
                            ('no_show', 'confirmed'), ('no_show', 'cancelled'))
$function$;
revoke all on function barberium.transicao_de_status_permitida(text, text) from public;
comment on function barberium.transicao_de_status_permitida(text, text) is
  'Etapa 7d: mapa das passagens de status de um atendimento (as que já existiam em 22/10).';

create or replace function barberium.trava_transicao_de_status()
 returns trigger
 language plpgsql
 set search_path to 'pg_catalog'
as $function$
begin
  if not barberium.transicao_de_status_permitida(old.status, new.status) then
    raise exception 'Mudança de status não permitida: % → %', old.status, new.status;
  end if;
  return new;
end
$function$;
revoke all on function barberium.trava_transicao_de_status() from public;

drop trigger if exists trg_appointments_transicao_de_status on public.appointments;
create trigger trg_appointments_transicao_de_status
  before update of status on public.appointments
  for each row when (old.status is distinct from new.status)
  execute function barberium.trava_transicao_de_status();

CREATE OR REPLACE FUNCTION public.barberium_staff_set_appointment_status_v12_7_raw(p_appointment_id uuid, p_status text)
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
  -- Etapa 7d: quem pode mudar para qual status mora em barberium.regra_de_status.
  perform barberium.conferir_status('mudar',m.role,perms,not coalesce(a.professional_id<>m.professional_id,false),a.status,p_status);
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
end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_complete_appointment(p_appointment_id uuid, p_payments jsonb DEFAULT '[]'::jsonb, p_pending_cents integer DEFAULT 0, p_due_date date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; a record; s record; service_due int; product_due int:=0; total int; paid int:=0; service_paid int:=0; product_paid int:=0; amt int; sa int; pa int; fee int; sf int; tender int; covered int; v jsonb; sp jsonb:='[]'; pp jsonb:='[]'; res jsonb; pending_service int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update;
 if a.id is null then raise exception 'Atendimento inválido'; end if;
 -- Etapa 7d: regra em barberium.regra_de_status (inclui a permissão "concluir" do barbeiro).
 perform barberium.conferir_status('concluir',m.role,case when m.role='barber' then barberium.effective_permissions(m.professional_id) end,a.professional_id is not distinct from m.professional_id,a.status,'completed');
 select * into s from public.product_sales where appointment_id=a.id for update;
 if s.id is not null and s.status='draft' then product_due:=s.total_cents; end if;
 select coalesce(sum(coverage_cents),0) into covered from public.appointment_membership_uses where appointment_id=a.id and status='reserved';
 service_due:=greatest(0,a.total_price_cents-covered); total:=service_due+product_due;
 if p_pending_cents is null or p_pending_cents<0 then raise exception 'Pendência inválida'; end if;
 for v in select * from jsonb_array_elements(coalesce(p_payments,'[]')) loop
  amt:=coalesce((v->>'amount_cents')::int,0);
  if amt<=0 or coalesce(v->>'method','') not in ('pix','cash','debit','credit') then raise exception 'Pagamento inválido'; end if;
  if nullif(v->>'provider_id','') is not null and not exists(select 1 from public.payment_providers where id=(v->>'provider_id')::uuid and barbershop_id=m.barbershop_id) then raise exception 'Provedor inválido'; end if;
  tender:=coalesce((v->>'tendered_cents')::int,amt);
  if v->>'method'='cash' and tender<amt then raise exception 'Valor recebido em dinheiro inválido'; end if;
  paid:=paid+amt;
  if paid>total then raise exception 'Pagamento excede total'; end if;
  sa:=case when total>0 then round(paid::numeric*service_due/total)::int-service_paid else 0 end; pa:=amt-sa;
  fee:=barberium.payment_fee_cents(nullif(v->>'provider_id','')::uuid,v->>'method',coalesce((v->>'installments')::int,1),amt);
  sf:=round(fee::numeric*sa/amt)::int;
  if sa>0 then sp:=sp||jsonb_build_array(v||jsonb_build_object('amount_cents',sa,'fee_cents',sf,'tendered_cents',sa+case when v->>'method'='cash' and pa=0 then tender-amt else 0 end)); end if;
  if pa>0 then pp:=pp||jsonb_build_array(v||jsonb_build_object('amount_cents',pa,'fee_cents',fee-sf,'tendered_cents',pa+case when v->>'method'='cash' then tender-amt else 0 end)); end if;
  service_paid:=service_paid+sa; product_paid:=product_paid+pa;
 end loop;
 if paid+p_pending_cents<>total then raise exception 'Pagamentos e pendência devem somar serviços e produtos'; end if;
 if p_pending_cents>0 and m.role='barber' and not barberium.permission_enabled(barberium.effective_permissions(m.professional_id),'leave_payment_pending') then raise exception 'Sem permissão para deixar pagamento pendente'; end if; pending_service:=service_due-service_paid;
 res:=barberium.complete_service_v123(a.id,sp,pending_service,p_due_date,p_note);
 if product_due>0 then perform barberium.complete_product_sale_core(s.id,pp,product_due-product_paid,p_due_date,p_note,m.member_id); end if;
 return res||jsonb_build_object('product_total_cents',product_due,'paid_cents',paid,'pending_cents',p_pending_cents,'due_total_cents',total);
end $function$;

CREATE OR REPLACE FUNCTION barberium.complete_service_v123(p_appointment_id uuid, p_payments jsonb DEFAULT '[]'::jsonb, p_pending_cents integer DEFAULT 0, p_due_date date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; perms jsonb; a record; pay jsonb; sum_paid int:=0; due_total int; fee int; provider uuid; meth text; amount int; tender int; chg int; inst int; v_session uuid; base_commission int; pct numeric; mode text; basis text; commission_amt int; covered int:=0; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update; if a.id is null then raise exception 'Atendimento inválido'; end if; perform barberium.conferir_status('concluir',m.role,perms,not coalesce(a.professional_id<>m.professional_id,false),a.status,'completed'); if p_pending_cents<0 then raise exception 'Pendência inválida'; end if; if p_pending_cents>0 and m.role='barber' and not barberium.permission_enabled(perms,'leave_payment_pending') then raise exception 'Sem permissão para deixar pagamento pendente'; end if; select coalesce(sum(coverage_cents),0) into covered from public.appointment_membership_uses where appointment_id=a.id and status='reserved'; due_total:=greatest(0,a.total_price_cents-covered); for pay in select * from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) loop meth:=pay->>'method'; amount:=coalesce((pay->>'amount_cents')::int,0); if meth not in ('pix','cash','debit','credit') or amount<=0 then raise exception 'Pagamento inválido'; end if; provider:=nullif(pay->>'provider_id','')::uuid; inst:=coalesce(nullif(pay->>'installments','')::int,1); tender:=coalesce(nullif(pay->>'tendered_cents','')::int,amount); chg:=case when meth='cash' then greatest(0,tender-amount) else 0 end; fee:=coalesce((pay->>'fee_cents')::int,barberium.payment_fee_cents(provider,meth,inst,amount)); insert into public.appointment_payments(barbershop_id,unit_id,appointment_id,method,amount_cents,tendered_cents,change_cents,provider_id,installments,fee_cents,actor_member_id,note) values(m.barbershop_id,a.unit_id,a.id,meth,amount,case when meth='cash' then tender end,chg,provider,case when meth='credit' then inst end,fee,m.member_id,pay->>'note'); if meth='cash' then select id into v_session from public.cash_sessions where unit_id=a.unit_id and status='open' order by opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,a.unit_id,'payment',amount,'appointment',a.id,'Recebimento de atendimento',m.member_id); end if; end if; sum_paid:=sum_paid+amount; end loop; if sum_paid+p_pending_cents<>due_total then raise exception 'A soma dos pagamentos e da pendência deve ser igual ao valor a receber'; end if; if p_pending_cents>0 then insert into public.appointment_receivables(appointment_id,barbershop_id,unit_id,original_due_cents,paid_cents,status,due_date,note) values(a.id,m.barbershop_id,a.unit_id,p_pending_cents,0,'open',p_due_date,nullif(trim(coalesce(p_note,'')),'')); end if; update public.appointments set status='completed',updated_at=now() where id=a.id; update public.appointment_membership_uses set status='consumed',consumed_at=now() where appointment_id=a.id and status='reserved'; update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-u.qty),used_credits=b.used_credits+u.qty from (select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where appointment_id=a.id and status='consumed' and bucket_id is not null group by bucket_id) u where b.id=u.bucket_id;
 if exists(select 1 from public.appointment_addons aa where aa.appointment_id=a.id and aa.item_kind='service') then
   declare
     v_default_pct numeric:=0;
     v_commission_base_total int:=0;
     v_fee_total int:=0;
     v_remaining_base int:=0;
     r record;
     v_component_base int:=0;
   begin
     select coalesce(cp.default_percent,0),
            coalesce(cp.basis,(select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross')
       into v_default_pct,basis
     from public.commission_profiles cp
     where cp.professional_id=a.professional_id;

     if not found then
       v_default_pct:=0;
       basis:=coalesce((select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross');
     end if;

     select coalesce(sum(fee_cents),0)::int
       into v_fee_total
     from public.appointment_payments
     where appointment_id=a.id;

     v_commission_base_total:=case when basis='net' then greatest(0,sum_paid-v_fee_total) else sum_paid end;
     v_remaining_base:=v_commission_base_total;

     for r in
       with primary_component as (
         select
           a.service_id,
           coalesce(nullif(a.service_name_snapshot,''),s.name) service_name,
           (
             coalesce(a.base_price_cents,0)
             +coalesce((
               select sum(aa.price_cents)
               from public.appointment_addons aa
               where aa.appointment_id=a.id and aa.item_kind='addon'
             ),0)
           )::int listed_weight,
           greatest(0,
             coalesce(a.base_price_cents,0)
             +coalesce((
               select sum(aa.price_cents)
               from public.appointment_addons aa
               where aa.appointment_id=a.id and aa.item_kind='addon'
             ),0)
             -coalesce((
               select sum(amu.coverage_cents)
               from public.appointment_membership_uses amu
               where amu.appointment_id=a.id
                 and amu.status='consumed'
                 and (
                   amu.target_service_id=a.service_id
                   or exists(
                     select 1 from public.appointment_addons ax
                     where ax.appointment_id=a.id
                       and ax.item_kind='addon'
                       and ax.service_id=amu.target_service_id
                   )
                 )
             ),0)
           )::int cash_weight,
           1::int sort_order
         from public.services s
         where s.id=a.service_id
       ),
       extra_components as (
         select
           aa.service_id,
           aa.name_snapshot service_name,
           aa.price_cents::int listed_weight,
           greatest(0,
             aa.price_cents
             -coalesce((
               select sum(amu.coverage_cents)
               from public.appointment_membership_uses amu
               where amu.appointment_id=a.id
                 and amu.status='consumed'
                 and amu.target_service_id=aa.service_id
             ),0)
           )::int cash_weight,
           0::int sort_order
         from public.appointment_addons aa
         where aa.appointment_id=a.id and aa.item_kind='service'
       ),
       all_components as (
         select * from extra_components
         union all
         select * from primary_component
       ),
       weighted as (
         select c.*,
           sum(cash_weight) over() total_cash_weight,
           sum(listed_weight) over() total_listed_weight
         from all_components c
       ),
       normalized as (
         select *,
           case
             when total_cash_weight>0 then cash_weight
             when total_listed_weight>0 then listed_weight
             when sort_order=1 then 1
             else 0
           end::numeric weight,
           case
             when total_cash_weight>0 then total_cash_weight
             when total_listed_weight>0 then total_listed_weight
             else 1
           end::numeric total_weight
         from weighted
       )
       select n.*,
         row_number() over(order by sort_order,service_name,service_id) rn,
         count(*) over() cnt
       from normalized n
       order by sort_order,service_name,service_id
     loop
       if r.rn=r.cnt then
         v_component_base:=greatest(0,v_remaining_base);
       else
         v_component_base:=least(
           greatest(0,v_remaining_base),
           greatest(0,round(v_commission_base_total*(r.weight/nullif(r.total_weight,0)))::int)
         );
       end if;
       v_remaining_base:=v_remaining_base-v_component_base;

       select coalesce(csr.mode,'percent'),coalesce(csr.percent,v_default_pct,0)
         into mode,pct
       from (select 1) q
       left join public.commission_service_rules csr
         on csr.professional_id=a.professional_id
        and csr.service_id=r.service_id;

       if mode<>'none' and coalesce(pct,0)>0 and v_component_base>0 then
         commission_amt:=round(v_component_base*(pct/100.0))::int;
         if commission_amt<>0 then
           insert into public.commission_entries(
             barbershop_id,unit_id,professional_id,appointment_id,
             source_type,source_id,description,base_cents,rate_percent,amount_cents
           )
           values(
             m.barbershop_id,a.unit_id,a.professional_id,a.id,
             'service',r.service_id,'Comissão de atendimento • '||r.service_name,
             v_component_base,pct,commission_amt
           );
         end if;
       end if;
     end loop;
   end;
 else
   select coalesce(csr.mode,'percent'),coalesce(csr.percent,cp.default_percent,0),coalesce(cp.basis,(select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross')
     into mode,pct,basis
   from public.commission_profiles cp
   left join public.commission_service_rules csr
     on csr.professional_id=cp.professional_id and csr.service_id=a.service_id
   where cp.professional_id=a.professional_id;

   if mode is null then mode:='percent'; pct:=0; end if;

   if mode<>'none' and coalesce(pct,0)>0 then
     base_commission:=sum_paid;
     if basis='net' then
       base_commission:=sum_paid-coalesce((select sum(fee_cents) from public.appointment_payments where appointment_id=a.id),0);
     end if;
     commission_amt:=round(base_commission*(pct/100.0))::int;
     if commission_amt<>0 then
       insert into public.commission_entries(
         barbershop_id,unit_id,professional_id,appointment_id,
         source_type,source_id,description,base_cents,rate_percent,amount_cents
       )
       values(
         m.barbershop_id,a.unit_id,a.professional_id,a.id,
         'service',a.service_id,'Comissão de atendimento',
         base_commission,pct,commission_amt
       );
     end if;
   end if;
 end if;
 insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from','confirmed','to','completed','paid_cents',sum_paid,'pending_cents',p_pending_cents,'membership_covered_cents',covered)); return jsonb_build_object('ok',true,'appointment_id',a.id,'paid_cents',sum_paid,'pending_cents',p_pending_cents,'membership_covered_cents',covered,'due_total_cents',due_total); end $function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_cancel_completed_appointment_v12_7_raw(p_appointment_id uuid, p_reason text, p_refund_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; a record; sale record; ce record; usage record; previous jsonb; result jsonb; service_refund int:=0; product_refund int:=0; service_pending int:=0; product_pending int:=0; covered int:=0; service_due int:=0; cash_session uuid; refund_id uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership();
 perform barberium.conferir_status('cancelar_concluido',case when m.member_id is not null then m.role end,null,true,null,'cancelled');
 if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento'; end if;
 if coalesce(p_refund_method,'') not in ('pix','cash','debit','credit','transfer','other') then raise exception 'Selecione a forma de devolução'; end if;
 select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update;
 if a.id is null then raise exception 'Atendimento não encontrado'; end if;
 select details into previous from public.appointment_events where appointment_id=a.id and event_type='cancelled_with_refund' order by created_at desc limit 1;
 if a.status='cancelled' and previous is not null then return previous||jsonb_build_object('ok',true,'already_cancelled',true); end if;
 perform barberium.conferir_status('cancelar_concluido',m.role,null,true,a.status,'cancelled');
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
end $function$;

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
  perform barberium.conferir_status('cancelar_concluido',case when m.member_id is not null then m.role end,null,true,null,'cancelled');

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

  perform barberium.conferir_status('cancelar_concluido',m.role,null,true,a.status,'cancelled');

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

CREATE OR REPLACE FUNCTION public.barberium_staff_cancel_completed_appointment_v2(p_appointment_id uuid, p_reason text, p_refund_method text, p_cancellation_kind text DEFAULT 'regular'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
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
  perform barberium.conferir_status('cancelar_concluido',case when m.member_id is not null then m.role end,null,true,null,'cancelled');

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
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_update_appointment_v12_12(p_appointment_id uuid, p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_extra_service_ids uuid[], p_date date, p_time time without time zone, p_final_price_cents integer DEFAULT NULL::integer, p_internal_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare
  m record;
  perms jsonb;
  olda public.appointments;
  v_prof public.professionals;
  v_service public.services;
  v_b public.barbershops;
  old_addons uuid[];
  new_addons uuid[];
  old_extras uuid[];
  new_extras uuid[];
  v_duration int;
  v_base int;
  v_listed int;
  v_final int;
  v_start timestamptz;
  v_end timestamptz;
  old_date date;
  old_time time;
  service_changed boolean;
  addons_changed boolean;
  extra_services_changed boolean;
  professional_changed boolean;
  date_changed boolean;
  time_changed boolean;
  value_changed boolean;
  note_changed boolean;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  perms:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  select * into olda from public.appointments where id=p_appointment_id for update;
  if olda.id is null or olda.barbershop_id<>m.barbershop_id then
    raise exception 'Agendamento não encontrado';
  end if;
  if m.role='barber' and olda.professional_id<>m.professional_id then
    raise exception 'Sem permissão para este agendamento';
  end if;
  if m.role='barber' and p_professional_id<>m.professional_id then
    raise exception 'Barbeiro não pode transferir atendimento';
  end if;
  perform barberium.conferir_status('editar',m.role,perms,true,olda.status,null);

  select coalesce(array_agg(service_id order by service_id),'{}'::uuid[])
  into old_addons
  from public.appointment_addons
  where appointment_id=olda.id and item_kind='addon';

  select coalesce(array_agg(service_id order by service_id),'{}'::uuid[])
  into old_extras
  from public.appointment_addons
  where appointment_id=olda.id and item_kind='service';

  select coalesce(array_agg(distinct x order by x),'{}'::uuid[])
  into new_addons
  from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x;

  select coalesce(array_agg(distinct x order by x),'{}'::uuid[])
  into new_extras
  from unnest(coalesce(p_extra_service_ids,'{}'::uuid[])) x;

  select * into v_prof from public.professionals
  where id=p_professional_id and barbershop_id=m.barbershop_id and is_active;
  if not found then raise exception 'Profissional inválido'; end if;

  select * into v_service from public.services
  where id=p_service_id and unit_id=v_prof.unit_id and is_active;
  if not found then raise exception 'Serviço inválido'; end if;
  if not barberium.professional_service_allowed(v_prof.id,v_service.id) then
    raise exception 'Profissional não vinculado ao serviço';
  end if;

  if p_service_id=any(new_extras) then raise exception 'O serviço principal não pode ser adicionado novamente'; end if;
  if exists(
    select 1 from unnest(new_extras) x(service_id)
    where x.service_id=any(new_addons)
  ) then raise exception 'O mesmo item não pode ser serviço e adicional'; end if;

  if exists(
    select 1 from unnest(new_addons) x(service_id)
    where not exists(
      select 1 from public.service_addons a
      where a.base_service_id=p_service_id and a.addon_service_id=x.service_id and a.is_active
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Adicional inválido para este profissional'; end if;

  if exists(
    select 1 from unnest(new_extras) x(service_id)
    where not exists(
      select 1 from public.services es
      where es.id=x.service_id
        and es.unit_id=v_prof.unit_id
        and es.is_active
        and es.service_kind in ('service','combo')
        and coalesce((es.settings->>'draft')::boolean,false)=false
    )
    or not barberium.professional_service_allowed(v_prof.id,x.service_id)
  ) then raise exception 'Serviço adicional inválido para este profissional'; end if;

  select * into v_b from public.barbershops where id=m.barbershop_id;

  old_date:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::date;
  old_time:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::time;

  service_changed:=olda.service_id<>p_service_id;
  addons_changed:=old_addons<>new_addons;
  extra_services_changed:=old_extras<>new_extras;
  professional_changed:=olda.professional_id<>p_professional_id;
  date_changed:=old_date<>p_date;
  time_changed:=old_time<>p_time;
  note_changed:=coalesce(olda.internal_note,'')<>coalesce(nullif(trim(coalesce(p_internal_note,'')),''),'');

  if m.role='barber' then
    if (service_changed or extra_services_changed) and not barberium.permission_enabled(perms,'edit_service') then
      raise exception 'Sem permissão para alterar serviço';
    end if;
    if addons_changed and not barberium.permission_enabled(perms,'edit_addons') then
      raise exception 'Sem permissão para alterar adicionais';
    end if;
    if date_changed and not barberium.permission_enabled(perms,'edit_date') then
      raise exception 'Sem permissão para alterar data';
    end if;
    if time_changed and not barberium.permission_enabled(perms,'edit_time') then
      raise exception 'Sem permissão para alterar horário';
    end if;
    if note_changed and not barberium.permission_enabled(perms,'edit_internal_note') then
      raise exception 'Sem permissão para alterar observação';
    end if;
  end if;

  v_duration:=
    barberium.effective_service_duration(v_prof.id,v_service.id)
    +coalesce((
      select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x.service_id))
      from unnest(new_addons) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_duration(v_prof.id,x.service_id))
      from unnest(new_extras) x(service_id)
    ),0);

  v_base:=barberium.effective_service_price(v_prof.id,v_service.id);
  v_listed:=
    v_base
    +coalesce((
      select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x.service_id))
      from unnest(new_addons) x(service_id)
    ),0)
    +coalesce((
      select sum(barberium.effective_service_price(v_prof.id,x.service_id))
      from unnest(new_extras) x(service_id)
    ),0);

  if m.role in ('owner','admin') or barberium.permission_enabled(perms,'edit_value') then
    v_final:=coalesce(p_final_price_cents,v_listed);
  else
    v_final:=case
      when service_changed or addons_changed or extra_services_changed then v_listed
      else olda.total_price_cents
    end;
    if p_final_price_cents is not null and p_final_price_cents<>v_final then
      raise exception 'Sem permissão para alterar valor';
    end if;
  end if;

  if v_final<0 then raise exception 'Valor inválido'; end if;
  value_changed:=olda.total_price_cents<>v_final;

  v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo');
  v_end:=v_start+make_interval(mins=>v_duration);

  if olda.status='confirmed' and not olda.is_walk_in then
    if exists(
      select 1 from public.appointments a
      where a.professional_id=v_prof.id
        and a.status='confirmed'
        and a.blocks_schedule
        and a.id<>olda.id
        and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')
    ) then raise exception 'Horário ocupado'; end if;

    if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then
      raise exception 'Horário bloqueado';
    end if;
  end if;

  begin
    update public.appointments
    set professional_id=v_prof.id,
        unit_id=v_prof.unit_id,
        service_id=v_service.id,
        starts_at=v_start,
        ends_at=v_end,
        base_price_cents=v_base,
        listed_price_cents=v_listed,
        total_price_cents=v_final,
        manual_adjustment_cents=v_final-v_listed,
        internal_note=nullif(trim(coalesce(p_internal_note,'')),''),
        updated_at=now()
    where id=olda.id;
  exception when exclusion_violation then
    raise exception 'Horário ocupado';
  end;

  delete from public.appointment_addons where appointment_id=olda.id;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    olda.id,ad.id,ad.name,
    barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),
    barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id),
    'addon'
  from public.service_addons a
  join public.services ad on ad.id=a.addon_service_id
  where a.base_service_id=v_service.id
    and a.addon_service_id=any(new_addons)
    and a.is_active;

  insert into public.appointment_addons(
    appointment_id,service_id,name_snapshot,price_cents,duration_min,item_kind
  )
  select
    olda.id,es.id,es.name,
    barberium.effective_service_price(v_prof.id,es.id),
    barberium.effective_service_duration(v_prof.id,es.id),
    'service'
  from unnest(new_extras) x(service_id)
  join public.services es on es.id=x.service_id;

  insert into public.appointment_events(
    barbershop_id,appointment_id,actor_member_id,event_type,details
  )
  values(
    m.barbershop_id,olda.id,m.member_id,'edited',
    jsonb_build_object(
      'professional_changed',professional_changed,
      'old_professional_id',olda.professional_id,
      'new_professional_id',v_prof.id,
      'service_changed',service_changed,
      'old_service_id',olda.service_id,
      'new_service_id',v_service.id,
      'addons_changed',addons_changed,
      'extra_services_changed',extra_services_changed,
      'old_extra_service_ids',to_jsonb(old_extras),
      'new_extra_service_ids',to_jsonb(new_extras),
      'date_changed',date_changed,
      'time_changed',time_changed,
      'value_changed',value_changed,
      'note_changed',note_changed,
      'old_starts_at',olda.starts_at,
      'new_starts_at',v_start,
      'old_total_price_cents',olda.total_price_cents,
      'new_total_price_cents',v_final
    )
  );

  return jsonb_build_object('ok',true,'appointment_id',olda.id);
end
$function$;

CREATE OR REPLACE FUNCTION public.barberium_staff_update_appointment(p_appointment_id uuid, p_professional_id uuid, p_service_id uuid, p_addon_service_ids uuid[], p_date date, p_time time without time zone, p_final_price_cents integer DEFAULT NULL::integer, p_internal_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; perms jsonb; olda public.appointments; v_prof public.professionals; v_service public.services; v_b public.barbershops; old_addons uuid[]; new_addons uuid[]; v_duration int; v_base int; v_listed int; v_final int; v_start timestamptz; v_end timestamptz; old_date date; old_time time; service_changed boolean; addons_changed boolean; professional_changed boolean; date_changed boolean; time_changed boolean; value_changed boolean; note_changed boolean;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 select * into olda from public.appointments where id=p_appointment_id for update; if olda.id is null or olda.barbershop_id<>m.barbershop_id then raise exception 'Agendamento não encontrado'; end if; if m.role='barber' and olda.professional_id<>m.professional_id then raise exception 'Sem permissão para este agendamento'; end if; if m.role='barber' and p_professional_id<>m.professional_id then raise exception 'Barbeiro não pode transferir atendimento'; end if; perform barberium.conferir_status('editar',m.role,perms,true,olda.status,null);
 select coalesce(array_agg(service_id order by service_id),'{}'::uuid[]) into old_addons from public.appointment_addons where appointment_id=olda.id; select coalesce(array_agg(x order by x),'{}'::uuid[]) into new_addons from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) x;
 select * into v_prof from public.professionals where id=p_professional_id and barbershop_id=m.barbershop_id and is_active; if not found then raise exception 'Profissional inválido'; end if; select * into v_service from public.services where id=p_service_id and unit_id=v_prof.unit_id and is_active; if not found then raise exception 'Serviço inválido'; end if; if not barberium.professional_service_allowed(v_prof.id,v_service.id) then raise exception 'Profissional não vinculado ao serviço'; end if; if exists(select 1 from unnest(new_addons) x where not exists(select 1 from public.service_addons a where a.base_service_id=p_service_id and a.addon_service_id=x and a.is_active) or not barberium.professional_service_allowed(v_prof.id,x)) then raise exception 'Adicional inválido para este profissional'; end if;
 select * into v_b from public.barbershops where id=m.barbershop_id; old_date:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::date; old_time:=(olda.starts_at at time zone coalesce(v_b.timezone,'America/Sao_Paulo'))::time; service_changed:=olda.service_id<>p_service_id; addons_changed:=old_addons<>new_addons; professional_changed:=olda.professional_id<>p_professional_id; date_changed:=old_date<>p_date; time_changed:=old_time<>p_time; note_changed:=coalesce(olda.internal_note,'')<>coalesce(nullif(trim(coalesce(p_internal_note,'')),''),'');
 if m.role='barber' then if service_changed and not barberium.permission_enabled(perms,'edit_service') then raise exception 'Sem permissão para alterar serviço'; end if; if addons_changed and not barberium.permission_enabled(perms,'edit_addons') then raise exception 'Sem permissão para alterar adicionais'; end if; if date_changed and not barberium.permission_enabled(perms,'edit_date') then raise exception 'Sem permissão para alterar data'; end if; if time_changed and not barberium.permission_enabled(perms,'edit_time') then raise exception 'Sem permissão para alterar horário'; end if; if note_changed and not barberium.permission_enabled(perms,'edit_internal_note') then raise exception 'Sem permissão para alterar observação'; end if; end if;
 v_duration:=barberium.effective_service_duration(v_prof.id,v_service.id)+coalesce((select sum(barberium.effective_addon_duration(v_prof.id,v_service.id,x)) from unnest(new_addons) x),0); v_base:=barberium.effective_service_price(v_prof.id,v_service.id); v_listed:=v_base+coalesce((select sum(barberium.effective_addon_price(v_prof.id,v_service.id,x)) from unnest(new_addons) x),0);
 if m.role in ('owner','admin') or barberium.permission_enabled(perms,'edit_value') then v_final:=coalesce(p_final_price_cents,v_listed); else v_final:=case when service_changed or addons_changed then v_listed else olda.total_price_cents end; if p_final_price_cents is not null and p_final_price_cents<>v_final then raise exception 'Sem permissão para alterar valor'; end if; end if; if v_final<0 then raise exception 'Valor inválido'; end if; value_changed:=olda.total_price_cents<>v_final;
 v_start:=(p_date::timestamp+p_time) at time zone coalesce(v_b.timezone,'America/Sao_Paulo'); v_end:=v_start+make_interval(mins=>v_duration); if olda.status='confirmed' and not olda.is_walk_in then if exists(select 1 from public.appointments a where a.professional_id=v_prof.id and a.status='confirmed' and a.blocks_schedule and a.id<>olda.id and tstzrange(a.starts_at,a.ends_at,'[)')&&tstzrange(v_start,v_end,'[)')) then raise exception 'Horário ocupado'; end if; if barberium.has_block_conflict(v_prof.unit_id,v_prof.id,v_start,v_end,null,null) then raise exception 'Horário bloqueado'; end if; end if;
 begin update public.appointments set professional_id=v_prof.id,unit_id=v_prof.unit_id,service_id=v_service.id,starts_at=v_start,ends_at=v_end,base_price_cents=v_base,listed_price_cents=v_listed,total_price_cents=v_final,manual_adjustment_cents=v_final-v_listed,internal_note=nullif(trim(coalesce(p_internal_note,'')),''),updated_at=now() where id=olda.id; exception when exclusion_violation then raise exception 'Horário ocupado'; end;
 delete from public.appointment_addons where appointment_id=olda.id; insert into public.appointment_addons(appointment_id,service_id,name_snapshot,price_cents,duration_min) select olda.id,ad.id,ad.name,barberium.effective_addon_price(v_prof.id,v_service.id,ad.id),barberium.effective_addon_duration(v_prof.id,v_service.id,ad.id) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=v_service.id and a.addon_service_id=any(new_addons) and a.is_active;
 insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,olda.id,m.member_id,'edited',jsonb_build_object('professional_changed',professional_changed,'old_professional_id',olda.professional_id,'new_professional_id',v_prof.id,'service_changed',service_changed,'old_service_id',olda.service_id,'new_service_id',v_service.id,'addons_changed',addons_changed,'date_changed',date_changed,'time_changed',time_changed,'value_changed',value_changed,'note_changed',note_changed,'old_starts_at',olda.starts_at,'new_starts_at',v_start,'old_total_price_cents',olda.total_price_cents,'new_total_price_cents',v_final)); return jsonb_build_object('ok',true,'appointment_id',olda.id);
end $function$;
