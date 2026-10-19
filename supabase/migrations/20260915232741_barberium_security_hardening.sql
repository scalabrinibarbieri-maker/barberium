alter function barberium.touch_updated_at() set search_path = public, barberium;
alter function barberium.normalize_phone(text) set search_path = public, barberium;

revoke all on function barberium.touch_updated_at() from public, anon, authenticated;
revoke all on function barberium.normalize_phone(text) from public, anon, authenticated;
revoke all on function barberium.valid_customer_token(uuid,text) from public, anon, authenticated;

revoke all on function public.barberium_get_catalog(text,text) from public, authenticated;
revoke all on function public.barberium_get_available_slots(text,text,uuid,uuid,uuid[],date) from public, authenticated;
revoke all on function public.barberium_create_appointment(text,text,uuid,uuid,uuid[],date,time,text,text,date,text) from public, authenticated;
revoke all on function public.barberium_get_customer_portal(text,text) from public, authenticated;
revoke all on function public.barberium_cancel_appointment(text,text,uuid) from public, authenticated;
revoke all on function public.barberium_update_customer_profile(text,text,text,date) from public, authenticated;
revoke all on function public.barberium_reschedule_appointment(text,text,text,uuid,uuid,uuid,uuid[],date,time) from public, authenticated;

grant execute on function public.barberium_get_catalog(text,text) to anon;
grant execute on function public.barberium_get_available_slots(text,text,uuid,uuid,uuid[],date) to anon;
grant execute on function public.barberium_create_appointment(text,text,uuid,uuid,uuid[],date,time,text,text,date,text) to anon;
grant execute on function public.barberium_get_customer_portal(text,text) to anon;
grant execute on function public.barberium_cancel_appointment(text,text,uuid) to anon;
grant execute on function public.barberium_update_customer_profile(text,text,text,date) to anon;
grant execute on function public.barberium_reschedule_appointment(text,text,text,uuid,uuid,uuid,uuid[],date,time) to anon;

