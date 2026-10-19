create or replace function public.barberium_staff_cancel_package(p_membership_id uuid,p_reason text,p_manual_refund_cents int default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_cm record; mode text; paid int; total int; used int; refund int:=0; pay record; refund_id uuid; ratio numeric:=0; ce record; q record; v_unit_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Motivo obrigatório'; end if;
  select xcm.*,v.rules into v_cm from public.customer_memberships xcm join public.membership_plan_versions v on v.id=xcm.plan_version_id
  where xcm.id=p_membership_id and xcm.barbershop_id=m.barbershop_id for update of xcm;
  if v_cm.id is null or v_cm.plan_type<>'package' then raise exception 'Pacote inválido'; end if;
  if v_cm.status in ('cancelled','expired') then raise exception 'Pacote já encerrado'; end if;
  mode:=coalesce(v_cm.rules->>'refund_mode','nonrefundable');

  select coalesce(sum(pb.quantity),0) into total from public.membership_plan_benefits pb where pb.plan_version_id=v_cm.plan_version_id and not pb.unlimited;
  select coalesce(sum(b.used_credits),0) into used from public.membership_credit_buckets b where b.membership_id=v_cm.id;
  if mode='no_after_use' and used>0 then raise exception 'Este pacote não permite cancelamento após o primeiro uso'; end if;
  select coalesce(sum(mp.amount_cents),0) into paid from public.membership_payments mp where mp.membership_id=v_cm.id;
  if mode='manual' then
    if p_manual_refund_cents is null or p_manual_refund_cents<0 or p_manual_refund_cents>paid then raise exception 'Informe um reembolso manual válido'; end if;
    refund:=p_manual_refund_cents;
  elsif mode='proportional' then
    if exists(select 1 from public.membership_plan_benefits pb where pb.plan_version_id=v_cm.plan_version_id and pb.unlimited) then raise exception 'Pacote ilimitado exige reembolso manual'; end if;
    refund:=case when total>0 then round(paid*greatest(0,total-least(used,total))::numeric/total)::int else 0 end;
  elsif mode='no_after_use' then refund:=paid;
  else refund:=0;
  end if;
  refund:=least(paid,greatest(0,refund));

  for q in select u.bucket_id,sum(u.credit_qty)::int qty from public.appointment_membership_uses u where u.membership_id=v_cm.id and u.status='reserved' and u.bucket_id is not null group by u.bucket_id loop
    update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-q.qty) where id=q.bucket_id;
  end loop;
  update public.appointment_membership_uses set status='released' where membership_id=v_cm.id and status='reserved';
  update public.customer_memberships set status='cancelled',renewal_blocked=true,cancel_effective_on=current_date,cancelled_at=now(),updated_at=now() where id=v_cm.id;

  select mp.id,mp.method into pay from public.membership_payments mp where mp.membership_id=v_cm.id order by mp.paid_at limit 1;
  v_unit_id:=coalesce(v_cm.origin_unit_id,(select u.id from public.units u where u.barbershop_id=m.barbershop_id and u.is_active order by u.created_at limit 1));
  if refund>0 then
    insert into public.finance_refunds(barbershop_id,unit_id,appointment_id,membership_id,membership_payment_id,amount_cents,reason,actor_member_id,refund_method)
    values(m.barbershop_id,v_unit_id,null,v_cm.id,pay.id,refund,trim(p_reason),m.member_id,pay.method) returning id into refund_id;
    ratio:=case when paid>0 then refund::numeric/paid else 0 end;
    for ce in select * from public.commission_entries where barbershop_id=m.barbershop_id and source_type='membership_sale' and source_id=v_cm.id and amount_cents>0 loop
      insert into public.commission_entries(barbershop_id,unit_id,professional_id,appointment_id,source_type,source_id,description,base_cents,rate_percent,amount_cents,status)
      values(ce.barbershop_id,ce.unit_id,ce.professional_id,null,'membership_refund',refund_id,'Estorno de comissão por reembolso de pacote',-round(ce.base_cents*ratio)::int,ce.rate_percent,-round(ce.amount_cents*ratio)::int,'open');
    end loop;
    if pay.method='cash' then
      insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
      select cs.id,m.barbershop_id,v_unit_id,'refund',-refund,'membership_refund',refund_id,'Reembolso de pacote',m.member_id
      from public.cash_sessions cs where cs.unit_id=v_unit_id and cs.status='open' order by cs.opened_at desc limit 1;
    end if;
  end if;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(v_cm.id,'package_cancelled',jsonb_build_object('refund_mode',mode,'refund_cents',refund,'reason',trim(p_reason),'refund_id',refund_id),m.member_id);
  return jsonb_build_object('ok',true,'refund_mode',mode,'refund_cents',refund,'refund_id',refund_id);
end $$;
grant execute on function public.barberium_staff_cancel_package(uuid,text,int) to authenticated;

