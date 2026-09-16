-- Barberium v12.0 — execução diária idempotente das renovações
create extension if not exists pg_cron;
do $$
begin
  if not exists(select 1 from cron.job where command='select barberium.process_due_subscription_renewals(current_date);' and active) then
    perform cron.schedule('barberium-subscription-renewal','5 3 * * *','select barberium.process_due_subscription_renewals(current_date);');
  end if;
end $$;
