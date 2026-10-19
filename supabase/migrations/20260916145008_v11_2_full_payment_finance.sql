create or replace function public.barberium_staff_assign_membership(p_customer_id uuid,p_plan_id uuid,p_unit_id uuid,p_start_date date default current_date,p_mark_paid boolean default false,p_payment_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; p record; v record; cm_id uuid; cyc_id uuid; cycle_start date; cycle_end date; due date; grace int; first_mode text; amount int; validity text; valid_until date;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and barbershop_id=m.barbershop_id) then raise exception 'Cliente inválido'; end if;
 select * into p from public.membership_plans where id=p_plan_id and barbershop_id=m.barbershop_id and is_active; if p.id is null then raise exception 'Plano inválido'; end if;
 select * into v from public.membership_plan_versions where plan_id=p.id and version_no=p.current_version_no;
 if p.plan_type='subscription' then
   cycle_start:=p_start_date;
   if coalesce(v.rules->>'cycle_mode','anniversary')='calendar' then cycle_start:=date_trunc('month',p_start_date)::date; cycle_end:=(date_trunc('month',p_start_date)+interval '1 month - 1 day')::date; else cycle_end:=(p_start_date+interval '1 month - 1 day')::date; end if;
   first_mode:=coalesce(v.rules->>'first_cycle_mode','full'); amount:=v.price_cents;
   if first_mode='next_cycle' and coalesce(v.rules->>'cycle_mode','anniversary')='calendar' then cycle_start:=(date_trunc('month',p_start_date)+interval '1 month')::date; cycle_end:=(cycle_start+interval '1 month - 1 day')::date; end if;
   if first_mode='proportional' and coalesce(v.rules->>'cycle_mode','anniversary')='calendar' and cycle_start<p_start_date then amount:=round(v.price_cents*((cycle_end-p_start_date+1)::numeric/(cycle_end-cycle_start+1)))::int; cycle_start:=p_start_date; end if;
   due:=p_start_date; grace:=greatest(0,coalesce((v.rules->>'grace_days')::int,0));
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,current_cycle_start,current_cycle_end,created_by_member_id)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,cycle_start,cycle_end,m.member_id) returning id into cm_id;
   insert into public.membership_cycles(membership_id,cycle_start,cycle_end,due_date,grace_until,amount_cents,status,credits_released,paid_at,is_first_cycle) values(cm_id,cycle_start,cycle_end,due,due+grace,amount,'pending',false,null,true) returning id into cyc_id;
 else
   validity:=coalesce(v.rules->>'credit_validity','no_expiry'); valid_until:=case when validity='fixed_days' then p_start_date+greatest(1,coalesce((v.rules->>'fixed_validity_days')::int,30)) else null end;
   insert into public.customer_memberships(barbershop_id,customer_id,plan_id,plan_version_id,plan_type,origin_unit_id,status,started_at,valid_until,created_by_member_id)
   values(m.barbershop_id,p_customer_id,p.id,v.id,p.plan_type,p_unit_id,'pending',null,valid_until,m.member_id) returning id into cm_id;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm_id,'created',jsonb_build_object('paid',false,'plan_version_id',v.id,'payment_required_full',true),m.member_id);
 if p_mark_paid then perform public.barberium_staff_record_membership_payment(cm_id,cyc_id,p_payment_method); end if;
 return jsonb_build_object('ok',true,'membership_id',cm_id,'cycle_id',cyc_id,'status',case when p_mark_paid then 'active' else 'pending' end);
exception when unique_violation then raise exception 'Cliente já possui um plano deste tipo ativo'; end $$;

create or replace function public.barberium_staff_record_membership_payment(p_membership_id uuid,p_cycle_id uuid default null,p_method text default 'pix')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; perms jsonb; cm record; cyc record; amount int; v_session uuid; v_unit uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if; perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
 if m.role='barber' and not barberium.permission_enabled(perms,'confirm_membership_payment') then raise exception 'Sem permissão para confirmar pagamento de plano'; end if;
 if p_method not in ('pix','cash','debit','credit') then raise exception 'Forma de pagamento inválida'; end if;
 select cm.*,pv.price_cents into cm from public.customer_memberships cm join public.membership_plan_versions pv on pv.id=cm.plan_version_id where cm.id=p_membership_id and cm.barbershop_id=m.barbershop_id for update; if cm.id is null then raise exception 'Plano do cliente inválido'; end if;
 v_unit:=coalesce(cm.origin_unit_id,(select id from public.units where barbershop_id=m.barbershop_id and is_active order by created_at limit 1));
 if cm.plan_type='subscription' then
   select * into cyc from public.membership_cycles where id=coalesce(p_cycle_id,(select id from public.membership_cycles where membership_id=cm.id and status in ('pending','overdue') order by due_date limit 1)) and membership_id=cm.id for update; if cyc.id is null then raise exception 'Mensalidade pendente não encontrada'; end if;
   if exists(select 1 from public.membership_payments where cycle_id=cyc.id) then raise exception 'Mensalidade já paga'; end if;
   amount:=cyc.amount_cents;
   insert into public.membership_payments(membership_id,cycle_id,amount_cents,method,actor_member_id) values(cm.id,cyc.id,amount,p_method,m.member_id);
   update public.membership_cycles set status='paid',paid_at=now() where id=cyc.id;
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),current_cycle_start=cyc.cycle_start,current_cycle_end=cyc.cycle_end,updated_at=now() where id=cm.id;
   if not cyc.credits_released then perform barberium.release_membership_credits(cm.id,cyc.id); end if;
 else
   if exists(select 1 from public.membership_payments where membership_id=cm.id) then raise exception 'Pacote já foi pago'; end if;
   amount:=cm.price_cents;
   insert into public.membership_payments(membership_id,amount_cents,method,actor_member_id) values(cm.id,amount,p_method,m.member_id);
   update public.customer_memberships set status='active',started_at=coalesce(started_at,now()),updated_at=now() where id=cm.id;
   perform barberium.release_membership_credits(cm.id,null);
 end if;
 if p_method='cash' and v_unit is not null then
   select id into v_session from public.cash_sessions where unit_id=v_unit and status='open' order by opened_at desc limit 1;
   if v_session is not null then insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id) values(v_session,m.barbershop_id,v_unit,'payment',amount,'membership',cm.id,'Pagamento integral de plano',m.member_id); end if;
 end if;
 insert into public.membership_events(membership_id,event_type,details,actor_member_id) values(cm.id,'payment_confirmed',jsonb_build_object('amount_cents',amount,'method',p_method,'payment_required_full',true),m.member_id);
 return jsonb_build_object('ok',true,'amount_cents',amount,'status','active');
end $$;

create or replace function public.barberium_staff_finance_overview(p_start date,p_end date,p_unit_id uuid default null,p_basis text default 'cash')
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; gross int; fees int; expenses_paid int; commissions int; receivables int; target int; result int; refunds int; appointment_gross int; membership_gross int; appointment_fees int; membership_fees int;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Financeiro geral restrito ao ADM'; end if; if p_basis not in ('cash','accrual') then raise exception 'Regime inválido'; end if;
 if p_basis='cash' then
   select coalesce(sum(ap.amount_cents),0),coalesce(sum(ap.fee_cents),0) into appointment_gross,appointment_fees from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id);
 else
   select coalesce(sum(a.total_price_cents),0),coalesce(sum((select sum(ap.fee_cents) from public.appointment_payments ap where ap.appointment_id=a.id)),0) into appointment_gross,appointment_fees from public.appointments a where a.barbershop_id=m.barbershop_id and a.status='completed' and a.starts_at::date between p_start and p_end and (p_unit_id is null or a.unit_id=p_unit_id);
 end if;
 select coalesce(sum(mp.amount_cents),0),coalesce(sum(mp.fee_cents),0) into membership_gross,membership_fees from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id);
 gross:=appointment_gross+membership_gross; fees:=appointment_fees+membership_fees;
 select coalesce(sum(fr.amount_cents),0) into refunds from public.finance_refunds fr where fr.barbershop_id=m.barbershop_id and fr.created_at::date between p_start and p_end and (p_unit_id is null or fr.unit_id=p_unit_id);
 select coalesce(sum(e.amount_cents),0) into expenses_paid from public.expenses e where e.barbershop_id=m.barbershop_id and e.status='paid' and (case when p_basis='cash' then coalesce(e.paid_at::date,e.due_date) else e.due_date end) between p_start and p_end and (p_unit_id is null or e.unit_id=p_unit_id);
 select coalesce(sum(ce.amount_cents),0) into commissions from public.commission_entries ce where ce.barbershop_id=m.barbershop_id and ce.created_at::date between p_start and p_end and (p_unit_id is null or ce.unit_id=p_unit_id);
 select coalesce(sum(original_due_cents-paid_cents),0) into receivables from public.appointment_receivables ar where ar.barbershop_id=m.barbershop_id and ar.status<>'paid' and (p_unit_id is null or ar.unit_id=p_unit_id);
 select revenue_target_cents into target from public.financial_goals fg where fg.barbershop_id=m.barbershop_id and fg.unit_id is not distinct from p_unit_id and fg.month=date_trunc('month',p_end)::date;
 result:=gross-refunds-fees-commissions-expenses_paid;
 return jsonb_build_object('start',p_start,'end',p_end,'basis',p_basis,'gross_cents',gross,'refunds_cents',refunds,'fees_cents',fees,'net_received_cents',gross-refunds-fees,'expenses_cents',expenses_paid,'commissions_cents',commissions,'operating_result_cents',result,'receivables_cents',receivables,'revenue_target_cents',target,'target_progress_percent',case when coalesce(target,0)>0 then round((gross-refunds)*100.0/target,1) else null end,'by_method',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_cents',amount) order by amount desc) from (
   select method,sum(amount_cents)::int amount from (
     select ap.method,ap.amount_cents from public.appointment_payments ap where ap.barbershop_id=m.barbershop_id and ap.received_at::date between p_start and p_end and (p_unit_id is null or ap.unit_id=p_unit_id)
     union all
     select mp.method,mp.amount_cents from public.membership_payments mp join public.customer_memberships cm on cm.id=mp.membership_id where cm.barbershop_id=m.barbershop_id and mp.paid_at::date between p_start and p_end and (p_unit_id is null or cm.origin_unit_id=p_unit_id)
   ) x group by method
 ) q),'[]'::jsonb));
end $$;

