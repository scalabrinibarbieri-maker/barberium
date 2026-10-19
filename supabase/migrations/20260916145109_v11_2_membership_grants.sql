grant execute on function public.barberium_staff_finance_report(date,date,uuid,text) to authenticated;
grant execute on function public.barberium_customer_refresh_membership_states(text,text) to anon,authenticated;
grant execute on function public.barberium_customer_membership_actions_state(text,text) to anon,authenticated;
grant execute on function public.barberium_customer_request_membership_action(text,text,uuid,text,int,text) to anon,authenticated;
grant execute on function public.barberium_staff_membership_action_requests() to authenticated;
grant execute on function public.barberium_staff_membership_actions_state(uuid) to authenticated;
grant execute on function public.barberium_staff_decide_membership_action_request(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_adjust_package_credit(uuid,uuid,int,text) to authenticated;
grant execute on function public.barberium_staff_cancel_package(uuid,text,int) to authenticated;
grant execute on function public.barberium_staff_resolve_no_show_membership_use(uuid,boolean,text) to authenticated;
grant execute on function public.barberium_staff_set_appointment_status(uuid,text) to authenticated;
grant execute on function public.barberium_staff_assign_membership(uuid,uuid,uuid,date,boolean,text) to authenticated;
grant execute on function public.barberium_staff_record_membership_payment(uuid,uuid,text) to authenticated;
grant execute on function public.barberium_staff_finance_overview(date,date,uuid,text) to authenticated;

