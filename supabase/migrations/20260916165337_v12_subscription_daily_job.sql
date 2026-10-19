create extension if not exists pg_cron with schema pg_catalog;
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname='barberium-subscription-renewals';
exception when others then null; end $$;
select cron.schedule('barberium-subscription-renewals','5 3 * * *',$job$select barberium.process_due_subscription_renewals(current_date);$job$);

