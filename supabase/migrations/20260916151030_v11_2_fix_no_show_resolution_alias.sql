create or replace function public.barberium_staff_resolve_no_show_membership_use(p_use_id uuid,p_consume boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public','barberium','auth','pg_temp' as $$
declare m record; v_use record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  select au.*,xcm.barbershop_id into v_use from public.appointment_membership_uses au join public.customer_memberships xcm on xcm.id=au.membership_id
  where au.id=p_use_id and xcm.barbershop_id=m.barbershop_id and au.status='decision_required' for update of au;
  if v_use.id is null then raise exception 'Decisão de falta não encontrada'; end if;
  if v_use.bucket_id is not null then
    update public.membership_credit_buckets set reserved_credits=greatest(0,reserved_credits-v_use.credit_qty),used_credits=used_credits+case when p_consume then v_use.credit_qty else 0 end where id=v_use.bucket_id;
  end if;
  update public.appointment_membership_uses set status=case when p_consume then 'forfeited' else 'released' end,consumed_at=case when p_consume then now() else null end where id=v_use.id;
  insert into public.membership_events(membership_id,event_type,details,actor_member_id)
  values(v_use.membership_id,'no_show_decided',jsonb_build_object('use_id',v_use.id,'appointment_id',v_use.appointment_id,'consume',p_consume,'note',nullif(trim(coalesce(p_note,'')),'')),m.member_id);
  return jsonb_build_object('ok',true,'status',case when p_consume then 'forfeited' else 'released' end);
end $$;
grant execute on function public.barberium_staff_resolve_no_show_membership_use(uuid,boolean,text) to authenticated;

