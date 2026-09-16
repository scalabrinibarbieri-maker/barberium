-- Barberium v12.0 — catálogo inicial automático para toda nova unidade/tenant.
-- Garante Corte + Barba como rascunhos mesmo quando a unidade nasce fora da UI de Configurações.

create or replace function barberium.seed_default_catalog_on_new_unit()
returns trigger
language plpgsql
security definer
set search_path='public','barberium','pg_temp'
as $$
begin
  if not exists(select 1 from public.services s where s.unit_id=new.id) then
    insert into public.services(
      barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,
      sort_order,is_active,settings,service_kind
    ) values
      (new.barbershop_id,new.id,'Corte','corte',0,45,'45 min',10,true,jsonb_build_object('draft',true),'service'),
      (new.barbershop_id,new.id,'Barba','barba',0,30,'30 min',20,true,jsonb_build_object('draft',true),'service');
  end if;
  return new;
end $$;

drop trigger if exists trg_seed_default_catalog_on_new_unit on public.units;
create trigger trg_seed_default_catalog_on_new_unit
after insert on public.units
for each row execute function barberium.seed_default_catalog_on_new_unit();
