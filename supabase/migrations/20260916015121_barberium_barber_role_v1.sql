alter table public.barbershop_members drop constraint if exists barbershop_members_role_check;
alter table public.barbershop_members add constraint barbershop_members_role_check check (role = any (array['owner'::text,'admin'::text,'staff'::text,'barber'::text]));

