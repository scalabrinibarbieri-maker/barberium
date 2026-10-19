CREATE OR REPLACE FUNCTION barberium.complete_service_v123(p_appointment_id uuid, p_payments jsonb DEFAULT '[]'::jsonb, p_pending_cents integer DEFAULT 0, p_due_date date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; perms jsonb; a record; pay jsonb; sum_paid int:=0; due_total int; fee int; provider uuid; meth text; amount int; tender int; chg int; inst int; v_session uuid; base_commission int; pct numeric; mode text; basis text; commission_amt int; covered int:=0; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update; if a.id is null then raise exception 'Atendimento inválido'; end if; if a.status<>'confirmed' then raise exception 'Atendimento já finalizado'; end if; if m.role='barber' and a.professional_id<>m.professional_id then raise exception 'Sem permissão'; end if; if m.role='barber' and not barberium.permission_enabled(perms,'mark_completed') then raise exception 'Sem permissão para concluir'; end if; if p_pending_cents<0 then raise exception 'Pendência inválida'; end if; if p_pending_cents>0 and m.role='barber' and not barberium.permission_enabled(perms,'leave_payment_pending') then raise exception 'Sem permissão para deixar pagamento pendente'; end if; select coalesce(sum(coverage_cents),0) into covered from public.appointment_membership_uses where appointment_id=a.id and status='reserved'; due_total:=greatest(0,a.total_price_cents-covered); for pay in select * from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) loop meth:=pay->>'method'; amount:=coalesce((pay->>'amount_cents')::int,0); if meth not in ('pix','cash','debit','credit') or amount<=0 then raise exception 'Pagamento inválido'; end if; provider:=nullif(pay->>'provider_id','')::uuid; inst:=coalesce(nullif(pay->>'installments','')::int,1); tender:=coalesce(nullif(pay->>'tendered_cents','')::int,amount); chg:=case when meth='cash' then greatest(0,tender-amount) else 0 end; fee:=coalesce((pay->>'fee_cents')::int,barberium.payment_fee_cents(provider,meth,inst,amount)); insert into public.appointment_payments(barbershop_id,unit_id,appointment_id,method,amount_cents,tendered_cents,change_cents,provider_id,installments,fee_cents,actor_member_id,note) values(m.barbershop_id,a.unit_id,a.id,meth,amount,case when meth='cash' then tender end,chg,provider,case when meth='credit' then inst end,fee,m.member_id,pay->>'note'); if meth='cash' then select id into v_session from public.cash_sessions where unit_id=a.unit_id and status='open' order by opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,a.unit_id,'payment',amount,'appointment',a.id,'Recebimento de atendimento',m.member_id); end if; end if; sum_paid:=sum_paid+amount; end loop; if sum_paid+p_pending_cents<>due_total then raise exception 'A soma dos pagamentos e da pendência deve ser igual ao valor a receber'; end if; if p_pending_cents>0 then insert into public.appointment_receivables(appointment_id,barbershop_id,unit_id,original_due_cents,paid_cents,status,due_date,note) values(a.id,m.barbershop_id,a.unit_id,p_pending_cents,0,'open',p_due_date,nullif(trim(coalesce(p_note,'')),'')); end if; update public.appointments set status='completed',updated_at=now() where id=a.id; update public.appointment_membership_uses set status='consumed',consumed_at=now() where appointment_id=a.id and status='reserved'; update public.membership_credit_buckets b set reserved_credits=greatest(0,b.reserved_credits-u.qty),used_credits=b.used_credits+u.qty from (select bucket_id,sum(credit_qty)::int qty from public.appointment_membership_uses where appointment_id=a.id and status='consumed' and bucket_id is not null group by bucket_id) u where b.id=u.bucket_id; select coalesce(csr.mode,'percent'),coalesce(csr.percent,cp.default_percent,0),coalesce(cp.basis,(select commission_basis from public.finance_settings fs where fs.barbershop_id=m.barbershop_id and fs.unit_id is null limit 1),'gross') into mode,pct,basis from public.commission_profiles cp left join public.commission_service_rules csr on csr.professional_id=cp.professional_id and csr.service_id=a.service_id where cp.professional_id=a.professional_id; if mode is null then mode:='percent'; pct:=0; end if; if mode<>'none' and coalesce(pct,0)>0 then base_commission:=sum_paid; if basis='net' then base_commission:=sum_paid-coalesce((select sum(fee_cents) from public.appointment_payments where appointment_id=a.id),0); end if; commission_amt:=round(base_commission*(pct/100.0))::int; if commission_amt<>0 then insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents) values(m.barbershop_id,a.unit_id,a.professional_id,a.id,'service',a.service_id,'Comissão de atendimento',base_commission,pct,commission_amt); end if; end if; insert into public.appointment_events(barbershop_id,appointment_id,actor_member_id,event_type,details) values(m.barbershop_id,a.id,m.member_id,'status_changed',jsonb_build_object('from','confirmed','to','completed','paid_cents',sum_paid,'pending_cents',p_pending_cents,'membership_covered_cents',covered)); return jsonb_build_object('ok',true,'appointment_id',a.id,'paid_cents',sum_paid,'pending_cents',p_pending_cents,'membership_covered_cents',covered,'due_total_cents',due_total); end $function$

;

revoke all on function barberium.complete_service_v123(uuid,jsonb,integer,date,text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.barberium_staff_complete_appointment(p_appointment_id uuid,p_payments jsonb default '[]',p_pending_cents integer default 0,p_due_date date default null,p_note text default null) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public','barberium','auth','pg_temp' AS $$
declare m record; a record; s record; service_due int; product_due int:=0; total int; paid int:=0; service_paid int:=0; product_paid int:=0; amt int; sa int; pa int; fee int; sf int; tender int; covered int; v jsonb; sp jsonb:='[]'; pp jsonb:='[]'; res jsonb; pending_service int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 select * into a from public.appointments where id=p_appointment_id and barbershop_id=m.barbershop_id for update;
 if a.id is null or (m.role='barber' and a.professional_id is distinct from m.professional_id) then raise exception 'Atendimento inválido'; end if;
 if a.status<>'confirmed' then raise exception 'Atendimento já finalizado'; end if;
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
end $$;
revoke all on function public.barberium_staff_complete_appointment(uuid,jsonb,integer,date,text) from public,anon;
grant execute on function public.barberium_staff_complete_appointment(uuid,jsonb,integer,date,text) to authenticated,service_role;

create or replace function barberium.complete_product_sale_core(p_sale_id uuid,p_payments jsonb,p_pending_cents integer,p_due_date date,p_note text,p_actor_member_id uuid) returns jsonb language plpgsql security definer set search_path='public','barberium','pg_temp' as $$ declare s record; i record; pay jsonb; pct numeric; comm integer; total integer; cost_total integer; paid integer:=0; amount integer; meth text; provider uuid; inst integer; fee integer; tender integer; chg integer; v_session uuid; begin select * into s from public.product_sales where id=p_sale_id for update; if s.id is null or s.status<>'draft' then raise exception 'Venda de produtos inválida'; end if; select coalesce(sum(line_total_cents),0),coalesce(sum(quantity*unit_cost_cents),0) into total,cost_total from public.product_sale_items where sale_id=s.id; if total<=0 then raise exception 'Venda sem produtos'; end if; if coalesce(p_pending_cents,0)<0 then raise exception 'Pendência inválida'; end if; for i in select * from public.product_sale_items where sale_id=s.id order by product_id,id loop perform barberium.apply_product_stock_change(i.product_id,s.unit_id,-i.quantity,'sale','Venda de produto','product_sale',s.id,p_actor_member_id,i.unit_cost_cents); pct:=case when s.seller_professional_id is null then 0 else barberium.product_commission_percent(s.seller_professional_id,i.product_id) end; comm:=round(i.line_total_cents*(coalesce(pct,0)/100.0))::int; update public.product_sale_items set commission_percent=pct,commission_cents=comm where id=i.id; if comm<>0 then insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents) values(s.barbershop_id,s.unit_id,s.seller_professional_id,s.appointment_id,'product_sale',i.id,'Comissão de produto • '||i.product_name_snapshot,i.line_total_cents,pct,comm); end if; end loop; for pay in select * from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) loop meth:=pay->>'method'; amount:=coalesce((pay->>'amount_cents')::int,0); if meth not in ('pix','cash','debit','credit') or amount<=0 then raise exception 'Pagamento inválido'; end if; provider:=nullif(pay->>'provider_id','')::uuid; if provider is not null and not exists(select 1 from public.payment_providers where id=provider and barbershop_id=s.barbershop_id) then raise exception 'Provedor inválido'; end if; inst:=coalesce(nullif(pay->>'installments','')::int,1); tender:=case when meth='cash' then coalesce(nullif(pay->>'tendered_cents','')::int,amount) else amount end; if meth='cash' and tender<amount then raise exception 'Valor recebido em dinheiro inválido'; end if; chg:=case when meth='cash' then greatest(0,tender-amount) else 0 end; fee:=case when pay ? 'fee_cents' then greatest(0,coalesce((pay->>'fee_cents')::int,0)) else barberium.payment_fee_cents(provider,meth,inst,amount) end; insert into public.product_sale_payments(sale_id,barbershop_id,unit_id,method,amount_cents,tendered_cents,change_cents,provider_id,installments,fee_cents,actor_member_id,note) values(s.id,s.barbershop_id,s.unit_id,meth,amount,case when meth='cash' then tender end,chg,provider,case when meth='credit' then inst end,fee,p_actor_member_id,pay->>'note'); if meth='cash' then select id into v_session from public.cash_sessions where unit_id=s.unit_id and barbershop_id=s.barbershop_id and status='open' order by opened_at desc limit 1; if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,s.barbershop_id,s.unit_id,'payment',amount,'product_sale',s.id,'Recebimento de produtos',p_actor_member_id); end if; end if; paid:=paid+amount; end loop; if paid+coalesce(p_pending_cents,0)<>total then raise exception 'A soma dos pagamentos e da pendência deve ser igual ao total dos produtos'; end if; if coalesce(p_pending_cents,0)>0 then insert into public.product_sale_receivables(sale_id,barbershop_id,unit_id,original_due_cents,paid_cents,status,due_date,note) values(s.id,s.barbershop_id,s.unit_id,p_pending_cents,0,'open',p_due_date,nullif(btrim(coalesce(p_note,'')),'')); end if; update public.product_sales set subtotal_cents=total,total_cents=total,cost_total_cents=cost_total,paid_cents=paid,pending_cents=coalesce(p_pending_cents,0),status='completed',completed_by_member_id=p_actor_member_id,completed_at=now(),updated_at=now(),note=coalesce(nullif(btrim(coalesce(p_note,'')),''),note) where id=s.id; return jsonb_build_object('ok',true,'sale_id',s.id,'total_cents',total,'paid_cents',paid,'pending_cents',coalesce(p_pending_cents,0)); end $$;

create or replace function public.barberium_staff_complete_product_sale(p_unit_id uuid,p_customer_id uuid,p_seller_professional_id uuid,p_items jsonb,p_payments jsonb,p_pending_cents integer default 0,p_due_date date default null,p_note text default null) returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$ declare m record; perms jsonb; seller uuid; sale_id uuid; r jsonb; prod record; qty integer; v_unit uuid; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end; if m.role='barber' and not barberium.permission_enabled(perms,'sell_products') then raise exception 'Sem permissão para vender produtos'; end if; if m.role='barber' then select unit_id into v_unit from public.professionals where id=m.professional_id; if p_unit_id is not null and p_unit_id<>v_unit then raise exception 'Unidade inválida'; end if; seller:=m.professional_id; else v_unit:=p_unit_id; seller:=p_seller_professional_id; end if; if not exists(select 1 from public.units where id=v_unit and barbershop_id=m.barbershop_id and is_active) then raise exception 'Unidade inválida'; end if; if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if; if seller is not null and not exists(select 1 from public.professionals where id=seller and barbershop_id=m.barbershop_id and unit_id=v_unit and is_active) then raise exception 'Profissional responsável inválido'; end if; if coalesce(p_pending_cents,0)>0 and m.role='barber' and not barberium.permission_enabled(perms,'leave_payment_pending') then raise exception 'Sem permissão para deixar pagamento pendente'; end if; insert into public.product_sales(barbershop_id,unit_id,customer_id,seller_professional_id,status,note,created_by_member_id) values(m.barbershop_id,v_unit,p_customer_id,seller,'draft',nullif(btrim(coalesce(p_note,'')),''),m.member_id) returning id into sale_id; for r in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop qty:=coalesce((r->>'quantity')::int,0); if qty<=0 then continue; end if; select * into prod from public.products where id=(r->>'product_id')::uuid and barbershop_id=m.barbershop_id and is_active; if prod.id is null then raise exception 'Produto inválido'; end if; insert into public.product_sale_items(sale_id,product_id,product_name_snapshot,sku_snapshot,quantity,unit_price_cents,unit_cost_cents,line_total_cents) values(sale_id,prod.id,prod.name,prod.sku,qty,prod.price_cents,prod.cost_cents,prod.price_cents*qty); end loop; select coalesce(jsonb_agg(value-'fee_cents'),'[]'::jsonb) into p_payments from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)); return barberium.complete_product_sale_core(sale_id,p_payments,coalesce(p_pending_cents,0),p_due_date,p_note,m.member_id); end $$;

create or replace function public.barberium_staff_product_sale_detail(p_sale_id uuid) returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$ declare m record; s record; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; select * into s from public.product_sales where id=p_sale_id and barbershop_id=m.barbershop_id; if s.id is null or (m.role='barber' and s.seller_professional_id is distinct from m.professional_id) then raise exception 'Venda inválida'; end if; return jsonb_build_object('id',s.id,'status',s.status,'unit_id',s.unit_id,'unit',(select name from public.units where id=s.unit_id),'customer_id',s.customer_id,'customer',(select full_name from public.customers where id=s.customer_id),'appointment_id',s.appointment_id,'seller_professional_id',s.seller_professional_id,'seller',(select name from public.professionals where id=s.seller_professional_id),'subtotal_cents',s.subtotal_cents,'total_cents',s.total_cents,'cost_total_cents',case when m.role in ('owner','admin') then s.cost_total_cents else null end,'paid_cents',s.paid_cents,'pending_cents',s.pending_cents,'note',s.note,'completed_at',s.completed_at,'refunded_at',s.refunded_at,'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.product_name_snapshot,'sku',i.sku_snapshot,'quantity',i.quantity,'unit_price_cents',i.unit_price_cents,'unit_cost_cents',case when m.role in ('owner','admin') then i.unit_cost_cents else null end,'line_total_cents',i.line_total_cents,'commission_percent',i.commission_percent,'commission_cents',i.commission_cents) order by i.created_at) from public.product_sale_items i where i.sale_id=s.id),'[]'::jsonb),'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'method',p.method,'amount_cents',p.amount_cents,'fee_cents',p.fee_cents,'received_at',p.received_at,'installments',p.installments,'provider',(select name from public.payment_providers where id=p.provider_id)) order by p.received_at) from public.product_sale_payments p where p.sale_id=s.id),'[]'::jsonb),'receivable',(select jsonb_build_object('original_due_cents',r.original_due_cents,'paid_cents',r.paid_cents,'remaining_cents',greatest(0,r.original_due_cents-r.paid_cents),'status',r.status,'due_date',r.due_date,'note',r.note) from public.product_sale_receivables r where r.sale_id=s.id),'refund',(select jsonb_build_object('amount_cents',f.amount_cents,'reason',f.reason,'refund_method',f.refund_method,'created_at',f.created_at) from public.finance_refunds f where f.product_sale_id=s.id order by f.created_at desc limit 1)); end $$;

alter table public.product_sales add column if not exists request_id uuid;
create unique index if not exists product_sales_request_key on public.product_sales(barbershop_id,request_id) where request_id is not null;
create or replace function public.barberium_staff_checkout_products(p_request_id uuid,p_unit_id uuid,p_customer_id uuid,p_seller_professional_id uuid,p_items jsonb,p_payments jsonb,p_pending_cents integer default 0,p_due_date date default null,p_note text default null) returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; s record; result jsonb;
begin
 if auth.uid() is null or p_request_id is null then raise exception 'Requisição inválida'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 perform pg_advisory_xact_lock(hashtextextended(m.barbershop_id::text||p_request_id::text,0));
 select * into s from public.product_sales where barbershop_id=m.barbershop_id and request_id=p_request_id;
 if s.id is not null then
  if s.created_by_member_id is distinct from m.member_id then raise exception 'Requisição inválida'; end if;
  return jsonb_build_object('ok',true,'sale_id',s.id,'total_cents',s.total_cents,'repeated',true);
 end if;
 result:=public.barberium_staff_complete_product_sale(p_unit_id,p_customer_id,p_seller_professional_id,p_items,p_payments,p_pending_cents,p_due_date,p_note);
 update public.product_sales set request_id=p_request_id where id=(result->>'sale_id')::uuid;
 return result;
end $$;
revoke all on function public.barberium_staff_checkout_products(uuid,uuid,uuid,uuid,jsonb,jsonb,integer,date,text) from public,anon;
grant execute on function public.barberium_staff_checkout_products(uuid,uuid,uuid,uuid,jsonb,jsonb,integer,date,text) to authenticated,service_role;

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

CREATE OR REPLACE FUNCTION barberium.default_barber_permissions()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'barberium', 'pg_temp'
AS $function$ select jsonb_build_object('sell_products',false,'view_product_stock',false,'create_appointment',true,'cancel_appointment',true,'edit_service',true,'edit_addons',true,'edit_date',true,'edit_time',true,'edit_value',true,'create_block',true,'create_recurring_block',true,'edit_internal_note',true,'mark_completed',true,'mark_no_show',true,'view_phone',true,'view_full_name',true,'view_value',true,'view_internal_note',true,'view_customer_history',true,'view_birthday',true,'view_own_revenue',true,'view_own_commission',true,'leave_payment_pending',false,'register_expense',false,'cash_withdrawal',false,'cash_supply',false,'open_cash',false,'close_cash',false,'confirm_membership_payment',false) $function$

;

CREATE OR REPLACE FUNCTION public.barberium_staff_finance_overview(p_start date, p_end date, p_unit_id uuid DEFAULT NULL::uuid, p_basis text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; gross int; fees int; expenses_paid int; commissions int; receivables int; target int; result int; refunds int; appointment_gross int; membership_gross int; appointment_fees int; membership_fees int; product_gross int; product_fees int; product_pending int; product_cost int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Financeiro geral restrito ao ADM'; end if; if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
 if p_basis='cash' then
   select coalesce(sum(ap.amount_cents),0),coalesce(sum(ap.fee_cents),0) into appointment_gross,appointment_fees from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id);
 else
   select coalesce(sum(a.total_price_cents),0),coalesce(sum((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id)),0) into appointment_gross,appointment_fees from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id);
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
 select coalesce(sum(original_due_cents-paid_cents),0) into receivables from public.appointment_receivables ar where ar.barbershop_id=m.barbershop_id and ar.status<>'paid' and (p_unit_id is null or ar.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into product_pending from public.product_sale_receivables where barbershop_id=m.barbershop_id and status in ('open','partial') and (p_unit_id is null or unit_id=p_unit_id); receivables:=receivables+product_pending;
 select revenue_target_cents into target from public.financial_goals fg where fg.barbershop_id=m.barbershop_id and fg.unit_id is not distinct from p_unit_id and fg.month=date_trunc('month',p_end)::date;
 result:=gross-refunds-fees-commissions-expenses_paid-product_cost;
 return jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'product_revenue_cents',product_gross,'product_cost_cents',product_cost,'service_revenue_cents',appointment_gross,'gross_cents',gross,'refunds_cents',refunds,'fees_cents',fees,'net_received_cents',gross-refunds-fees,'expenses_cents',expenses_paid,'commissions_cents',commissions,'operating_result_cents',result,'receivables_cents',receivables,'revenue_target_cents',target,'target_progress_percent',case when coalesce(target,0)>0 then round((gross-refunds)*100.0/target,1) else null end,'by_method',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_cents',amount) order by amount desc) from (
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
      where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id)
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
    'receivables',coalesce((select jsonb_agg(jsonb_build_object('appointment_id',ar.appointment_id,'unit',u.name,'customer',c.full_name,'service',s.name,'professional',pr.name,'original_due_cents',ar.original_due_cents,'paid_cents',ar.paid_cents,'open_cents',greatest(0,ar.original_due_cents-ar.paid_cents),'status',ar.status,'due_date',ar.due_date,'note',ar.note,'created_at',ar.created_at) order by coalesce(ar.due_date,ar.created_at::date),ar.created_at) from public.appointment_receivables ar join public.appointments a on a.id=ar.appointment_id join public.units u on u.id=ar.unit_id left join public.customers c on c.id=a.customer_id left join public.services s on s.id=a.service_id left join public.professionals pr on pr.id=a.professional_id where ar.barbershop_id=m.barbershop_id and ar.created_at::date<=p_end and (p_unit_id is null or ar.unit_id=p_unit_id)),'[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('sale_id',r.sale_id,'source_type','product','appointment_id',ps.appointment_id,'unit',u.name,'customer',c.full_name,'service','Produtos','professional',pr.name,'original_due_cents',r.original_due_cents,'paid_cents',r.paid_cents,'open_cents',case when r.status='cancelled' then 0 else greatest(0,r.original_due_cents-r.paid_cents) end,'status',r.status,'due_date',r.due_date,'note',r.note,'created_at',r.created_at)) from public.product_sale_receivables r join public.product_sales ps on ps.id=r.sale_id join public.units u on u.id=r.unit_id left join public.customers c on c.id=ps.customer_id left join public.professionals pr on pr.id=ps.seller_professional_id where r.barbershop_id=m.barbershop_id and r.created_at::date<=p_end and (p_unit_id is null or r.unit_id=p_unit_id)),'[]'::jsonb),
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

create or replace function public.barberium_staff_receive_product_balance(p_sale_id uuid,p_payments jsonb) returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; s record; r record; pay jsonb; total int:=0; amt int; fee int; provider uuid; session_id uuid; tender int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 select * into s from public.product_sales where id=p_sale_id and barbershop_id=m.barbershop_id for update;
 if s.id is null or s.status<>'completed' then raise exception 'Venda inválida'; end if;
 select * into r from public.product_sale_receivables where sale_id=s.id for update;
 if r.id is null or r.status not in ('open','partial') then raise exception 'Não existe saldo pendente'; end if;
 for pay in select * from jsonb_array_elements(coalesce(p_payments,'[]')) loop
  amt:=coalesce((pay->>'amount_cents')::int,0); if amt<=0 or coalesce(pay->>'method','') not in ('pix','cash','debit','credit') then raise exception 'Pagamento inválido'; end if;
  provider:=nullif(pay->>'provider_id','')::uuid;
  if provider is not null and not exists(select 1 from public.payment_providers where id=provider and barbershop_id=m.barbershop_id) then raise exception 'Provedor inválido'; end if;
  tender:=coalesce((pay->>'tendered_cents')::int,amt); if pay->>'method'='cash' and tender<amt then raise exception 'Dinheiro recebido insuficiente'; end if;
  fee:=barberium.payment_fee_cents(provider,pay->>'method',coalesce((pay->>'installments')::int,1),amt);
  insert into public.product_sale_payments(sale_id,barbershop_id,unit_id,method,amount_cents,tendered_cents,change_cents,provider_id,installments,fee_cents,actor_member_id)
  values(s.id,s.barbershop_id,s.unit_id,pay->>'method',amt,case when pay->>'method'='cash' then tender end,case when pay->>'method'='cash' then tender-amt else 0 end,provider,coalesce((pay->>'installments')::int,1),fee,m.member_id);
  if pay->>'method'='cash' then
   select id into session_id from public.cash_sessions where unit_id=s.unit_id and status='open' order by opened_at desc limit 1;
   if session_id is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(session_id,s.barbershop_id,s.unit_id,'payment',amt,'product_sale',s.id,'Recebimento de saldo de produtos',m.member_id); end if;
  end if; total:=total+amt;
 end loop;
 if total<=0 or total>r.original_due_cents-r.paid_cents then raise exception 'Valor inválido para o saldo pendente'; end if;
 update public.product_sale_receivables set paid_cents=paid_cents+total,status=case when paid_cents+total=original_due_cents then 'paid' else 'partial' end,updated_at=now() where id=r.id;
 update public.product_sales set paid_cents=paid_cents+total,pending_cents=pending_cents-total,updated_at=now() where id=s.id;
 return jsonb_build_object('ok',true,'paid_cents',total);
end $$;
revoke all on function public.barberium_staff_receive_product_balance(uuid,jsonb) from public,anon;
grant execute on function public.barberium_staff_receive_product_balance(uuid,jsonb) to authenticated,service_role;

