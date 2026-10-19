-- Executar após provisionar o Vault e publicar a Edge Function.
create or replace function barberium.push_tick() returns bigint language sql security definer
set search_path=barberium,vault,net,pg_temp as $$
 select net.http_post(url:=c.worker_url,
 headers:=jsonb_build_object('Content-Type','application/json','x-barberium-push-key',s.decrypted_secret),
 body:='{}'::jsonb,timeout_milliseconds:=120000)
 from barberium.push_config c join vault.decrypted_secrets s on s.id=c.cron_secret_id where c.id and c.enabled and exists(select 1 from barberium.push_jobs j where (j.state='pending' or (j.state='sending' and j.lease_until<now())) and j.due_at<=now());
$$;
revoke all on function barberium.push_tick() from public,anon,authenticated;
select cron.schedule('barberium-push-every-minute','* * * * *','select barberium.push_tick();');

