alter function barberium.default_barber_permissions() set search_path='barberium','pg_temp';
alter function barberium.permission_enabled(jsonb,text) set search_path='barberium','pg_temp';
alter function barberium.mask_customer_name(text,boolean) set search_path='barberium','pg_temp';

