create or replace function barberium.sync_appointment_price_fields()
returns trigger
language plpgsql
set search_path to 'public','barberium','pg_temp'
as $$
begin
  if tg_op='INSERT' then
    if new.listed_price_cents is null then new.listed_price_cents:=new.total_price_cents; end if;
    new.manual_adjustment_cents:=coalesce(new.manual_adjustment_cents,new.total_price_cents-new.listed_price_cents);
  elsif tg_op='UPDATE' then
    if new.total_price_cents is distinct from old.total_price_cents
       and new.listed_price_cents is not distinct from old.listed_price_cents
       and new.manual_adjustment_cents is not distinct from old.manual_adjustment_cents then
      new.listed_price_cents:=new.total_price_cents;
      new.manual_adjustment_cents:=0;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_sync_appointment_price_fields on public.appointments;
create trigger trg_sync_appointment_price_fields before insert or update on public.appointments for each row execute function barberium.sync_appointment_price_fields();

