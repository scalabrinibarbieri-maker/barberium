-- Barberium v12.4: push transacional. Chaves são provisionadas separadamente no Vault.
create extension if not exists pg_net with schema extensions;
create table barberium.push_config (
 id boolean primary key default true check(id), public_key text not null,
 private_secret_id uuid not null, cron_secret_id uuid not null,
 subject text not null, worker_url text not null, enabled boolean not null default false
);
create table barberium.push_devices (
 id uuid primary key default gen_random_uuid(), barbershop_id uuid not null references public.barbershops(id) on delete cascade,
 customer_id uuid not null references public.customers(id) on delete cascade,
 token_id uuid not null references public.customer_access_tokens(id) on delete cascade,
 endpoint text not null unique, p256dh text not null, auth text not null,
 enabled boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 last_test_at timestamptz
);
create table barberium.push_jobs (
 id uuid primary key default gen_random_uuid(), device_id uuid not null references barberium.push_devices(id) on delete cascade,
 appointment_id uuid references public.appointments(id) on delete cascade,
 kind text not null check(kind in ('confirmation','changed','cancelled','reminder24','reminder2','welcome','test')),
 starts_snapshot timestamptz, status_snapshot text,
 due_at timestamptz not null, expires_at timestamptz not null,
 state text not null default 'pending' check(state in ('pending','sending','sent','cancelled','failed')),
 attempts integer not null default 0, lease_until timestamptz, lease_id uuid,
 sent_at timestamptz, last_code integer, created_at timestamptz not null default now()
);
create index push_jobs_due on barberium.push_jobs(due_at) where state in ('pending','sending');
create index push_jobs_appointment on barberium.push_jobs(appointment_id);
create index push_devices_customer on barberium.push_devices(customer_id) where enabled;
alter table barberium.push_config enable row level security;
alter table barberium.push_devices enable row level security;
alter table barberium.push_jobs enable row level security;
revoke all on barberium.push_config,barberium.push_devices,barberium.push_jobs from public,anon,authenticated;

create function barberium.push_customer(p_slug text,p_token text) returns public.customer_access_tokens
language plpgsql security definer set search_path=public,barberium,extensions,pg_temp as $$
declare t public.customer_access_tokens;
begin
 select x.* into t from public.customer_access_tokens x join public.customers c on c.id=x.customer_id
 join public.barbershops b on b.id=c.barbershop_id
 where b.slug=p_slug and b.status='active' and x.revoked_at is null and x.token_hash=extensions.digest(coalesce(p_token,''),'sha256') limit 1;
 if t.id is null then raise exception 'Acesso do cliente inválido. Abra seu agendamento neste aparelho.' using errcode='42501'; end if;
 return t;
end $$;

create function barberium.push_schedule(p_appointment uuid,p_device uuid,p_kind text default null) returns void
language plpgsql security definer set search_path=public,barberium,pg_temp as $$
declare a public.appointments; begin
 select * into a from public.appointments where id=p_appointment;
 if a.id is null then return; end if;
 if p_kind is not null then
 insert into barberium.push_jobs(device_id,appointment_id,kind,starts_snapshot,status_snapshot,due_at,expires_at)
 values(p_device,a.id,p_kind,a.starts_at,a.status,now(),case when p_kind='cancelled' then now()+interval '24 hours' else least(now()+interval '30 minutes',a.starts_at) end);
 end if;
 if a.status='confirmed' and a.starts_at>now() then
 insert into barberium.push_jobs(device_id,appointment_id,kind,starts_snapshot,status_snapshot,due_at,expires_at)
 select p_device,a.id,v.kind,a.starts_at,a.status,a.starts_at-v.early,least(a.starts_at,a.starts_at-v.early+interval '30 minutes')
 from (values('reminder24',interval '24 hours'),('reminder2',interval '2 hours')) v(kind,early)
 where a.starts_at-v.early>now();
 end if;
end $$;

create function barberium.push_appointment_changed() returns trigger
language plpgsql security definer set search_path=public,barberium,pg_temp as $$
declare d record; k text; begin
 if tg_op='UPDATE' then
 if row(new.starts_at,new.status,new.professional_id,new.service_id,new.unit_id,new.customer_id) is not distinct from row(old.starts_at,old.status,old.professional_id,old.service_id,old.unit_id,old.customer_id) then return new; end if;
 update barberium.push_jobs set state='cancelled',lease_id=null where appointment_id=new.id and state in ('pending','sending');
 end if;
 if new.status='confirmed' and new.starts_at>now() then k:=case when tg_op='INSERT' then 'confirmation' else 'changed' end;
 elsif new.status='cancelled' and tg_op='UPDATE' and old.status<>'cancelled' then k:='cancelled';
 else return new; end if;
 for d in select id from barberium.push_devices where customer_id=new.customer_id and barbershop_id=new.barbershop_id and enabled loop
 perform barberium.push_schedule(new.id,d.id,k);
 end loop;
 return new;
end $$;
create trigger barberium_push_appointment after insert or update on public.appointments for each row execute function barberium.push_appointment_changed();

create function public.barberium_push_public_config() returns jsonb
language sql stable security definer set search_path=barberium,pg_temp as $$
 select coalesce((select jsonb_build_object('public_key',public_key,'enabled',enabled) from barberium.push_config where id),jsonb_build_object('enabled',false));
$$;

create function public.barberium_push_subscribe(p_barbershop_slug text,p_access_token text,p_subscription jsonb) returns jsonb
language plpgsql security definer set search_path=public,barberium,pg_temp as $$
declare t public.customer_access_tokens; c public.customers; d barberium.push_devices; ep text:=p_subscription->>'endpoint'; a record; fresh boolean;
begin
 t:=barberium.push_customer(p_barbershop_slug,p_access_token);
 select * into c from public.customers where id=t.customer_id for update;
 if not coalesce((select enabled from barberium.push_config where id),false) then raise exception 'Notificações temporariamente indisponíveis.'; end if;
 if ep is null or length(ep)>2048 or ep !~ '^https://(fcm\.googleapis\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]#]+$'
 or coalesce(p_subscription#>>'{keys,p256dh}','') !~ '^[A-Za-z0-9_-]{87}=?$' or coalesce(p_subscription#>>'{keys,auth}','') !~ '^[A-Za-z0-9_-]{22}={0,2}$' then raise exception 'Inscrição de notificações inválida.'; end if;
 select * into d from barberium.push_devices where endpoint=ep for update;
 if d.id is not null and d.customer_id<>c.id then raise exception 'Este aparelho está vinculado a outro cliente. Desative as notificações antes de trocar de perfil.'; end if;
 fresh:=d.id is null or not d.enabled;
 if d.id is null and (select count(*) from barberium.push_devices where customer_id=c.id)>=10 then raise exception 'Limite de aparelhos atingido. Solicite ajuda à barbearia.'; end if;
 insert into barberium.push_devices(barbershop_id,customer_id,token_id,endpoint,p256dh,auth)
 values(c.barbershop_id,c.id,t.id,ep,p_subscription#>>'{keys,p256dh}',p_subscription#>>'{keys,auth}')
 on conflict(endpoint) do update set token_id=excluded.token_id,p256dh=excluded.p256dh,auth=excluded.auth,enabled=true,updated_at=now() returning * into d;
 if fresh then
 update barberium.push_jobs set state='cancelled',lease_id=null where device_id=d.id and state in ('pending','sending');
 insert into barberium.push_jobs(device_id,kind,due_at,expires_at) values(d.id,'welcome',now(),now()+interval '10 minutes');
 for a in select id from public.appointments where customer_id=c.id and barbershop_id=c.barbershop_id and status='confirmed' and starts_at>now() loop
 perform barberium.push_schedule(a.id,d.id,null);
 end loop;
 end if;
 return jsonb_build_object('enabled',true,'device_id',d.id);
end $$;

create function public.barberium_push_device(p_barbershop_slug text,p_access_token text,p_endpoint text,p_action text default 'status') returns jsonb
language plpgsql security definer set search_path=public,barberium,pg_temp as $$
declare t public.customer_access_tokens; d barberium.push_devices;begin
 t:=barberium.push_customer(p_barbershop_slug,p_access_token);
 select * into d from barberium.push_devices where endpoint=p_endpoint and customer_id=t.customer_id for update;
 if d.id is null then return jsonb_build_object('enabled',false);end if;
 if p_action='disable' then
 update barberium.push_devices set enabled=false,updated_at=now() where id=d.id;
 update barberium.push_jobs set state='cancelled',lease_id=null where device_id=d.id and state in ('pending','sending');d.enabled:=false;
 elsif p_action='test' and d.enabled then
 if d.last_test_at>now()-interval '5 minutes' then raise exception 'Aguarde cinco minutos antes de testar novamente.';end if;
 update barberium.push_devices set last_test_at=now() where id=d.id;
 insert into barberium.push_jobs(device_id,kind,due_at,expires_at) values(d.id,'test',now(),now()+interval '5 minutes');
 elsif p_action not in ('status','test') then raise exception 'Ação inválida.';end if;
 return jsonb_build_object('enabled',d.enabled,'device_id',d.id);
end $$;

-- Apenas o serviço de envio pode ler chaves ou retirar trabalhos da fila.
create function public.barberium_push_worker_config(p_secret text) returns jsonb
language sql security definer set search_path=barberium,vault,pg_temp as $$
 select jsonb_build_object('publicKey',c.public_key,'privateKey',v.decrypted_secret,'subject',c.subject)
 from barberium.push_config c join vault.decrypted_secrets v on v.id=c.private_secret_id
 join vault.decrypted_secrets s on s.id=c.cron_secret_id where c.id and c.enabled and s.decrypted_secret=p_secret;
$$;
create function public.barberium_push_claim() returns jsonb
language plpgsql security definer set search_path=barberium,public,pg_temp as $$
declare result jsonb;begin
 update barberium.push_jobs j set state='cancelled',lease_id=null where state in ('pending','sending') and (expires_at<=now() or not exists(select 1 from barberium.push_devices d join public.customer_access_tokens t on t.id=d.token_id where d.id=j.device_id and d.enabled and t.revoked_at is null));
 update barberium.push_jobs set state='failed',lease_id=null where state='sending' and lease_until<now() and attempts>=5;
 with batch as(select id from barberium.push_jobs where (state='pending' or (state='sending' and lease_until<now())) and due_at<=now() and expires_at>now() and attempts<5 order by due_at limit 10 for update skip locked),
 claimed as(update barberium.push_jobs j set state='sending',attempts=attempts+1,lease_until=now()+interval '3 minutes',lease_id=gen_random_uuid() from batch where j.id=batch.id returning j.id,j.lease_id)
 select coalesce(jsonb_agg(to_jsonb(claimed)),'[]'::jsonb) into result from claimed;
 delete from barberium.push_jobs where created_at<now()-interval '30 days' and state in ('sent','failed','cancelled');
 return result;
end $$;
create function public.barberium_push_delivery(p_id uuid,p_lease uuid) returns jsonb
language plpgsql security definer set search_path=barberium,public,pg_temp as $$
declare j barberium.push_jobs; d barberium.push_devices; a public.appointments; b public.barbershops; title text; body text;begin
 select * into j from barberium.push_jobs where id=p_id and lease_id=p_lease and state='sending' and expires_at>now();
 if j.id is null then return null;end if;
 select * into d from barberium.push_devices where id=j.device_id and enabled;
 if d.id is null or not exists(select 1 from public.customer_access_tokens where id=d.token_id and revoked_at is null) then return null;end if;
 select * into b from public.barbershops where id=d.barbershop_id and status='active';if b.id is null then return null;end if;
 if j.appointment_id is not null then
 select * into a from public.appointments where id=j.appointment_id and customer_id=d.customer_id and barbershop_id=d.barbershop_id and starts_at=j.starts_snapshot and status=j.status_snapshot;
 if a.id is null or (j.kind<>'cancelled' and (a.status<>'confirmed' or a.starts_at<=now())) then return null;end if;
 title:=case j.kind when 'confirmation' then 'Agendamento confirmado' when 'changed' then 'Seu agendamento foi atualizado' when 'cancelled' then 'Agendamento cancelado' else 'Lembrete do seu horário' end;
 body:=case when j.kind='cancelled' then 'Seu horário foi cancelado. Confira seus agendamentos no Barberium.' else
 'Seu horário é '||to_char(a.starts_at at time zone coalesce(b.timezone,'America/Sao_Paulo'),'DD/MM "às" HH24:MI')||'. '||coalesce(a.unit_name_snapshot,'Confira a unidade no site.') end;
 else title:='Notificações ativadas';body:=case when j.kind='test' then 'Tudo certo! Este celular pode receber os lembretes do Barberium.' else 'Você receberá lembretes dos seus próximos horários neste celular.' end;end if;
 return jsonb_build_object('subscription',jsonb_build_object('endpoint',d.endpoint,'keys',jsonb_build_object('p256dh',d.p256dh,'auth',d.auth)),
 'payload',jsonb_build_object('title',title,'body',body,'tag','barberium-'||coalesce(a.id,j.id)::text,'url','?view=appointments','expires_at',j.expires_at),
 'ttl',greatest(1,least(60,extract(epoch from j.expires_at-now())::int)));
end $$;
create function public.barberium_push_result(p_id uuid,p_lease uuid,p_code integer) returns void
language plpgsql security definer set search_path=barberium,pg_temp as $$
declare j barberium.push_jobs;begin
 select * into j from barberium.push_jobs where id=p_id and lease_id=p_lease and state='sending' for update;
 if j.id is null then return;end if;
 if p_code in (404,410) then
 update barberium.push_devices set enabled=false where id=j.device_id;
 update barberium.push_jobs set state='cancelled',lease_id=null,last_code=p_code where device_id=j.device_id and state in ('pending','sending');return;
 end if;
 update barberium.push_jobs set state=case when p_code between 200 and 299 then 'sent' when p_code=409 then 'cancelled'
 when (p_code=0 or p_code=429 or p_code>=500) and attempts<5 and expires_at>now()+interval '1 minute' then 'pending' else 'failed' end,
 sent_at=case when p_code between 200 and 299 then now() else null end,last_code=p_code,lease_id=null,lease_until=null,due_at=now()+make_interval(secs=>least(900,60*attempts*attempts)) where id=j.id;
end $$;

revoke all on function barberium.push_customer(text,text),barberium.push_schedule(uuid,uuid,text),barberium.push_appointment_changed() from public,anon,authenticated;
revoke all on function public.barberium_push_public_config(),public.barberium_push_subscribe(text,text,jsonb),public.barberium_push_device(text,text,text,text) from public;
grant execute on function public.barberium_push_public_config(),public.barberium_push_subscribe(text,text,jsonb),public.barberium_push_device(text,text,text,text) to anon,authenticated;
revoke all on function public.barberium_push_worker_config(text),public.barberium_push_claim(),public.barberium_push_delivery(uuid,uuid),public.barberium_push_result(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.barberium_push_worker_config(text),public.barberium_push_claim(),public.barberium_push_delivery(uuid,uuid),public.barberium_push_result(uuid,uuid,integer) to service_role;

