-- Barberium v11.2 — hardening final das RPCs de equipe.
-- Backend de produção já recebeu esta etapa.

revoke execute on function public.barberium_staff_adjust_package_credit(uuid,uuid,int,text) from public,anon;
revoke execute on function public.barberium_staff_cancel_package(uuid,text,int) from public,anon;
revoke execute on function public.barberium_staff_decide_membership_action_request(uuid,boolean,text) from public,anon;
revoke execute on function public.barberium_staff_membership_action_requests() from public,anon;
revoke execute on function public.barberium_staff_membership_actions_state(uuid) from public,anon;
revoke execute on function public.barberium_staff_resolve_no_show_membership_use(uuid,boolean,text) from public,anon;
revoke execute on function public.barberium_staff_record_membership_payment(uuid,uuid,text) from public,anon;
revoke execute on function public.barberium_staff_customer_memberships(uuid) from public,anon;
revoke execute on function public.barberium_staff_membership_options_for_appointment(uuid) from public,anon;
revoke execute on function public.barberium_staff_reserve_membership_use(uuid,uuid,uuid,uuid,uuid) from public,anon;

grant execute on function public.barberium_staff_adjust_package_credit(uuid,uuid,int,text) to authenticated;
grant execute on function public.barberium_staff_cancel_package(uuid,text,int) to authenticated;
grant execute on function public.barberium_staff_decide_membership_action_request(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_membership_action_requests() to authenticated;
grant execute on function public.barberium_staff_membership_actions_state(uuid) to authenticated;
grant execute on function public.barberium_staff_resolve_no_show_membership_use(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_record_membership_payment(uuid,uuid,text) to authenticated;
grant execute on function public.barberium_staff_customer_memberships(uuid) to authenticated;
grant execute on function public.barberium_staff_membership_options_for_appointment(uuid) to authenticated;
grant execute on function public.barberium_staff_reserve_membership_use(uuid,uuid,uuid,uuid,uuid) to authenticated;
