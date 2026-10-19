create table barberium.wa_reminders(appointment_id uuid primary key references public.appointments(id) on delete cascade, starts_at timestamptz not null, due_at timestamptz not null, requested_by uuid references public.barbershop_members(id), sent_at timestamptz, sent_by uuid references public.barbershop_members(id));
create table barberium.wa_devices(id uuid primary key default gen_random_uuid(),member_id uuid not null references public.barbershop_members(id) on delete cascade,session_id uuid not null,endpoint text unique not null,p256dh text not null,auth text not null,enabled boolean not null default true);
create table barberium.wa_jobs(id uuid primary key default gen_random_uuid(),device_id uuid references barberium.wa_devices(id) on delete cascade,appointment_id uuid references barberium.wa_reminders(appointment_id) on delete cascade,starts_at timestamptz not null,state text not null default 'pending',attempts int not null default 0,lease_id uuid,lease_until timestamptz,due_at timestamptz not null, unique(device_id,appointment_id,starts_at));
create index wa_jobs_due on barberium.wa_jobs(due_at) where state in ('pending','sending');
alter table barberium.wa_reminders enable row level security; alter table barberium.wa_devices enable row level security; alter table barberium.wa_jobs enable row level security;
revoke all on barberium.wa_reminders,barberium.wa_devices,barberium.wa_jobs from public,anon,authenticated;
create function barberium.wa_sync() returns trigger language plpgsql security definer set search_path=public,barberium,pg_temp as $$
begin
 if tg_op='UPDATE' and new.starts_at is not distinct from old.starts_at and new.status is not distinct from old.status and new.customer_id is not distinct from old.customer_id and new.professional_id is not distinct from old.professional_id and new.unit_id is not distinct from old.unit_id then return new; end if;
 delete from barberium.wa_reminders where appointment_id=new.id;
 if new.status='confirmed' and new.starts_at>now() then insert into barberium.wa_reminders(appointment_id,starts_at,due_at) values(new.id,new.starts_at,greatest(now(),new.starts_at-interval '2 hours')); end if;
 return new;
end $$;
create trigger wa_appointment_sync after insert or update on public.appointments for each row execute function barberium.wa_sync();
insert into barberium.wa_reminders(appointment_id,starts_at,due_at) select id,starts_at,greatest(now(),starts_at-interval '2 hours') from public.appointments where status='confirmed' and starts_at>now();
create function public.barberium_staff_whatsapp(p_appointment_id uuid default null,p_action text default 'list') returns jsonb language plpgsql security definer set search_path=public,barberium,auth,pg_temp as $$
declare m record; a public.appointments; r barberium.wa_reminders; result jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 if p_action='list' then
 if m.role not in ('owner','admin') then raise exception 'Apenas administrador'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'customer',c.full_name,'professional',p.name,'starts_at',a.starts_at,'sent_at',r.sent_at) order by a.starts_at) from barberium.wa_reminders r join public.appointments a on a.id=r.appointment_id join public.customers c on c.id=a.customer_id join public.professionals p on p.id=a.professional_id where a.barbershop_id=m.barbershop_id and a.status='confirmed' and a.starts_at>now() and r.due_at<=now() and r.sent_at is null),'[]'::jsonb);
 end if;
 select * into a from public.appointments where id=p_appointment_id for update;
 if a.id is null or a.barbershop_id<>m.barbershop_id or (m.role not in ('owner','admin') and a.professional_id is distinct from m.professional_id) then raise exception 'Sem acesso ao agendamento'; end if;
 if a.status<>'confirmed' or a.starts_at<=now() then raise exception 'Este horário não está mais disponível para lembrete'; end if;
 select * into r from barberium.wa_reminders where appointment_id=a.id;
 if p_action='request' then
 update barberium.wa_reminders set requested_by=coalesce(requested_by,m.member_id) where appointment_id=a.id;
 return jsonb_build_object('requested',true,'due_at',r.due_at,'sent_at',r.sent_at);
 end if;
 if p_action='status' then return jsonb_build_object('requested',r.requested_by is not null,'due_at',r.due_at,'sent_at',r.sent_at); end if;
 if m.role not in ('owner','admin') then raise exception 'Apenas administrador'; end if;
 if p_action='sent' then
 update barberium.wa_reminders set sent_at=coalesce(sent_at,now()),sent_by=coalesce(sent_by,m.member_id) where appointment_id=a.id;
 update barberium.wa_jobs set state='cancelled',lease_id=null where appointment_id=a.id and state in ('pending','sending');
 return jsonb_build_object('sent',true);
 end if;
 if p_action<>'message' then raise exception 'Ação inválida'; end if;
 select jsonb_build_object('phone',regexp_replace(c.phone_e164,'[^0-9]','','g'),'message',format('Olá, %s! 💈 Lembrando que seu horário na %s é em %s, às %s, com %s. Esperamos você!',c.full_name,b.name,to_char(a.starts_at at time zone b.timezone,'DD/MM/YYYY'),to_char(a.starts_at at time zone b.timezone,'HH24:MI'),p.name),'sent_at',r.sent_at) into result from public.customers c join public.barbershops b on b.id=a.barbershop_id join public.professionals p on p.id=a.professional_id where c.id=a.customer_id;
 return result;
end $$;
create function public.barberium_staff_wa_device(p_subscription jsonb,p_action text default 'status') returns jsonb language plpgsql security definer set search_path=public,barberium,auth,pg_temp as $$
declare m record; d barberium.wa_devices; ep text:=p_subscription->>'endpoint'; sid uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
 if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Apenas administrador'; end if;
 sid:=(auth.jwt()->>'session_id')::uuid;
 if sid is null or not exists(select 1 from auth.sessions where id=sid and user_id=auth.uid()) then raise exception 'Entre novamente para ativar os avisos'; end if;
 perform 1 from public.barbershop_members where id=m.member_id for update;
 select * into d from barberium.wa_devices where endpoint=ep;
 if d.id is not null and d.member_id<>m.member_id then raise exception 'Este aparelho está vinculado a outro administrador'; end if;
 if p_action='subscribe' then
 if ep is null or length(ep)>2048 or ep !~ '^https://(fcm\.googleapis\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]#]+$' or coalesce(p_subscription#>>'{keys,p256dh}','') !~ '^[A-Za-z0-9_-]{87}$' or coalesce(p_subscription#>>'{keys,auth}','') !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'Inscrição inválida'; end if;
 if d.id is null and (select count(*) from barberium.wa_devices where member_id=m.member_id)>=10 then raise exception 'Limite de aparelhos atingido'; end if;
 insert into barberium.wa_devices(member_id,session_id,endpoint,p256dh,auth) values(m.member_id,sid,ep,p_subscription#>>'{keys,p256dh}',p_subscription#>>'{keys,auth}') on conflict(endpoint) do update set session_id=excluded.session_id,p256dh=excluded.p256dh,auth=excluded.auth,enabled=true;
 elsif p_action='disable' then update barberium.wa_devices set enabled=false where id=d.id;
 elsif p_action<>'status' then raise exception 'Ação inválida'; end if;
 return jsonb_build_object('enabled',exists(select 1 from barberium.wa_devices where endpoint=ep and member_id=m.member_id and enabled and session_id=sid));
end $$;
create function barberium.wa_prepare() returns void language plpgsql security definer set search_path=public,barberium,auth,pg_temp as $$
begin
 insert into barberium.wa_jobs(device_id,appointment_id,starts_at,due_at)
 select d.id,a.id,a.starts_at,r.due_at from barberium.wa_reminders r join public.appointments a on a.id=r.appointment_id join public.barbershop_members m on m.barbershop_id=a.barbershop_id and m.is_active and m.role in ('owner','admin') join barberium.wa_devices d on d.member_id=m.id and d.enabled join auth.sessions s on s.id=d.session_id and s.user_id=m.auth_user_id join public.barbershops b on b.id=a.barbershop_id and b.status='active' where r.sent_at is null and a.status='confirmed' and a.starts_at>now() and r.due_at<=now() on conflict do nothing;
 update barberium.wa_jobs j set state='cancelled',lease_id=null where state in ('pending','sending') and (j.starts_at<=now() or not exists(select 1 from barberium.wa_reminders r join barberium.wa_devices d on d.id=j.device_id join public.barbershop_members m on m.id=d.member_id join auth.sessions s on s.id=d.session_id and s.user_id=m.auth_user_id where r.appointment_id=j.appointment_id and r.starts_at=j.starts_at and r.sent_at is null and d.enabled and m.is_active and m.role in ('owner','admin')));
 delete from barberium.wa_jobs where starts_at<now()-interval '30 days';
end $$;
create function public.barberium_wa_claim() returns jsonb language plpgsql security definer set search_path=barberium,pg_temp as $$
declare outp jsonb; begin
 perform barberium.wa_prepare();
 update barberium.wa_jobs set state='failed' where state='sending' and lease_until<now() and attempts>=5;
 with picked as(select id from barberium.wa_jobs where due_at<=now() and starts_at>now() and attempts<5 and (state='pending' or (state='sending' and lease_until<now())) order by due_at limit 2 for update skip locked), updated as(update barberium.wa_jobs j set state='sending',lease_id=gen_random_uuid(),lease_until=now()+interval '3 minutes',attempts=attempts+1 from picked p where j.id=p.id returning j.id,j.lease_id) select coalesce(jsonb_agg(to_jsonb(updated)),'[]'::jsonb) into outp from updated; return outp; end $$;
create function public.barberium_wa_delivery(p_id uuid,p_lease uuid) returns jsonb language sql security definer set search_path=public,barberium,auth,pg_temp as $$
 select jsonb_build_object('subscription',jsonb_build_object('endpoint',d.endpoint,'keys',jsonb_build_object('p256dh',d.p256dh,'auth',d.auth)),'ttl',60,'payload',jsonb_build_object('title','Lembrete WhatsApp • '||c.full_name,'body',format('%s, às %s, com %s. Toque para preparar o envio.',to_char(a.starts_at at time zone b.timezone,'DD/MM'),to_char(a.starts_at at time zone b.timezone,'HH24:MI'),p.name),'tag','wa-'||a.id,'audience','staff','expires_at',a.starts_at))
 from barberium.wa_jobs j join barberium.wa_devices d on d.id=j.device_id join public.barbershop_members m on m.id=d.member_id join auth.sessions s on s.id=d.session_id and s.user_id=m.auth_user_id join barberium.wa_reminders r on r.appointment_id=j.appointment_id join public.appointments a on a.id=r.appointment_id join public.customers c on c.id=a.customer_id join public.professionals p on p.id=a.professional_id join public.barbershops b on b.id=a.barbershop_id where j.id=p_id and j.lease_id=p_lease and j.state='sending' and j.lease_until>now() and d.enabled and m.is_active and m.role in ('owner','admin') and m.barbershop_id=a.barbershop_id and b.status='active' and r.sent_at is null and a.status='confirmed' and a.starts_at=j.starts_at and a.starts_at>now();
$$;
create function public.barberium_wa_result(p_id uuid,p_lease uuid,p_code int) returns void language plpgsql security definer set search_path=barberium,pg_temp as $$
begin
 if p_code in (404,410) then update barberium.wa_devices set enabled=false where id=(select device_id from barberium.wa_jobs where id=p_id and lease_id=p_lease); end if;
 update barberium.wa_jobs set state=case when p_code between 200 and 299 then 'sent' when p_code=409 then 'cancelled' when attempts<5 and (p_code=0 or p_code=429 or p_code>=500) then 'pending' else 'failed' end,due_at=now()+interval '1 minute'*attempts*attempts,lease_id=null,lease_until=null where id=p_id and lease_id=p_lease and state='sending';
end $$;
revoke all on function barberium.wa_sync(),barberium.wa_prepare(),public.barberium_staff_whatsapp(uuid,text),public.barberium_staff_wa_device(jsonb,text),public.barberium_wa_claim(),public.barberium_wa_delivery(uuid,uuid),public.barberium_wa_result(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.barberium_staff_whatsapp(uuid,text),public.barberium_staff_wa_device(jsonb,text) to authenticated;
grant execute on function public.barberium_wa_claim(),public.barberium_wa_delivery(uuid,uuid),public.barberium_wa_result(uuid,uuid,integer) to service_role;
create or replace function barberium.push_tick() returns bigint language plpgsql security definer set search_path=barberium,vault,net,pg_temp as $$
declare rid bigint; begin
 perform barberium.wa_prepare();
 select net.http_post(url:=c.worker_url,headers:=jsonb_build_object('Content-Type','application/json','x-barberium-push-key',s.decrypted_secret),body:='{}'::jsonb,timeout_milliseconds:=180000) into rid from barberium.push_config c join vault.decrypted_secrets s on s.id=c.cron_secret_id where c.id and c.enabled and (exists(select 1 from barberium.push_jobs j where (j.state='pending' or(j.state='sending' and j.lease_until<now())) and j.due_at<=now()) or exists(select 1 from barberium.wa_jobs j where (j.state='pending' or(j.state='sending' and j.lease_until<now())) and j.due_at<=now())); return rid;
end $$;

