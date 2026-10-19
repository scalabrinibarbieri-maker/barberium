create index if not exists idx_appointment_addons_service on public.appointment_addons(service_id);
create index if not exists idx_appointments_barbershop on public.appointments(barbershop_id);
create index if not exists idx_appointments_unit on public.appointments(unit_id);
create index if not exists idx_appointments_service on public.appointments(service_id);
create index if not exists idx_members_auth_user on public.barbershop_members(auth_user_id);
create index if not exists idx_members_professional on public.barbershop_members(professional_id);
create index if not exists idx_blocked_times_barbershop on public.blocked_times(barbershop_id);
create index if not exists idx_blocked_times_unit on public.blocked_times(unit_id);
create index if not exists idx_business_hours_professional on public.business_hours(professional_id);
create index if not exists idx_customer_tokens_customer on public.customer_access_tokens(customer_id);
create index if not exists idx_professional_services_service on public.professional_services(service_id);
create index if not exists idx_professionals_barbershop on public.professionals(barbershop_id);
create index if not exists idx_service_addons_addon_service on public.service_addons(addon_service_id);
create index if not exists idx_service_addons_barbershop on public.service_addons(barbershop_id);
create index if not exists idx_service_addons_unit on public.service_addons(unit_id);
create index if not exists idx_services_barbershop on public.services(barbershop_id);

