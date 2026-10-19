create table barberium.booking_jobs(id uuid primary key default gen_random_uuid(),device_id uuid not null references barberium.wa_devices(id) on delete cascade,appointment_id uuid not null references public.appointments(id) on delete cascade,professional_id uuid not null,customer_id uuid not null,starts_at timestamptz not null,expires_at timestamptz not null,state text not null default 'pending',attempts int not null default 0,lease_id uuid,lease_until timestamptz,due_at timestamptz not null default now(),unique(device_id,appointment_id));
create index booking_jobs_due on barberium.booking_jobs(due_at) where state in ('pending','sending');
alter table barberium.booking_jobs enable row level security;
revoke all on barberium.booking_jobs from public,anon,authenticated;
create function barberium.booking_notify() returns trigger language plpgsql security definer set search_path=public,barberium,auth,pg_temp as $$
begin
 if new.status<>'confirmed' or new.starts_at<=now() or new.created_by_member_id is not null then return new;end if;
 insert into barberium.booking_jobs(device_id,appointment_id,professional_id,customer_id,starts_at,expires_at)
 select d.id,new.id,new.professional_id,new.customer_id,new.starts_at,least(new.starts_at,now()+interval '30 minutes') from barberium.wa_devices d join public.barbershop_members m on m.id=d.member_id join auth.sessions s on s.id=d.session_id and s.user_id=m.auth_user_id join public.barbershops b on b.id=m.barbershop_id
 where d.enabled and m.is_active and b.status='active' and m.barbershop_id=new.barbershop_id and (m.role in ('owner','admin') or (m.role='barber' and m.professional_id=new.professional_id)) and (s.not_after is null or s.not_after>now()) on conflict do nothing;
 return new;
end $$;
create trigger booking_team_notify after insert on public.appointments for each row execute function barberium.booking_notify();
create function public.barberium_booking_delivery(p_id uuid,p_lease uuid) returns jsonb language sql security definer set search_path=public,barberium,auth,pg_temp as $$
 select jsonb_build_object('subscription',jsonb_build_object('endpoint',d.endpoint,'keys',jsonb_build_object('p256dh',d.p256dh,'auth',d.auth)),'ttl',greatest(1,least(60,extract(epoch from j.expires_at-now())::int)),'payload',jsonb_build_object('title','Novo agendamento 💈','body',format('%s marcou para %s, às %s, com %s.',barberium.mask_customer_name(c.full_name,m.role in ('owner','admin') or barberium.permission_enabled(barberium.effective_permissions(m.professional_id),'view_full_name')),to_char(a.starts_at at time zone b.timezone,'DD/MM'),to_char(a.starts_at at time zone b.timezone,'HH24:MI'),p.name),'tag','booking-'||a.id,'audience','staff','appointment_id',a.id,'expires_at',j.expires_at))
 from barberium.booking_jobs j join barberium.wa_devices d on d.id=j.device_id join public.barbershop_members m on m.id=d.member_id join auth.sessions s on s.id=d.session_id and s.user_id=m.auth_user_id join public.appointments a on a.id=j.appointment_id join public.customers c on c.id=a.customer_id join public.professionals p on p.id=a.professional_id join public.barbershops b on b.id=a.barbershop_id
 where j.id=p_id and j.lease_id=p_lease and j.state='sending' and j.lease_until>now() and j.expires_at>now() and d.enabled and m.is_active and b.status='active' and m.barbershop_id=a.barbershop_id and (m.role in ('owner','admin') or(m.role='barber' and m.professional_id=a.professional_id)) and (s.not_after is null or s.not_after>now()) and a.status='confirmed' and a.starts_at=j.starts_at and a.professional_id=j.professional_id and a.customer_id=j.customer_id and a.starts_at>now();
$$;
create or replace function public.barberium_staff_wa_device(p_subscription jsonb,p_action text default 'status') returns jsonb language plpgsql security definer set search_path=public,barberium,auth,pg_temp as $$
declare m record; d barberium.wa_devices; ep text:=p_subscription->>'endpoint'; sid uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
 if m.member_id is null or m.role not in ('owner','admin','barber') then raise exception 'Sem acesso à equipe'; end if;
 sid:=(auth.jwt()->>'session_id')::uuid;
 if sid is null or not exists(select 1 from auth.sessions where id=sid and user_id=auth.uid()) then raise exception 'Entre novamente para ativar os avisos'; end if;
 perform 1 from public.barbershop_members where id=m.member_id for update;
 select * into d from barberium.wa_devices where endpoint=ep;
 if d.id is not null and d.member_id<>m.member_id then raise exception 'Este aparelho está vinculado a outro profissional'; end if;
 if p_action='subscribe' then
 if ep is null or length(ep)>2048 or ep !~ '^https://(fcm\.googleapis\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]#]+$' or coalesce(p_subscription#>>'{keys,p256dh}','') !~ '^[A-Za-z0-9_-]{87}$' or coalesce(p_subscription#>>'{keys,auth}','') !~ '^[A-Za-z0-9_-]{22}$' then raise exception 'Inscrição inválida'; end if;
 if d.id is null and (select count(*) from barberium.wa_devices where member_id=m.member_id)>=10 then raise exception 'Limite de aparelhos atingido'; end if;
 insert into barberium.wa_devices(member_id,session_id,endpoint,p256dh,auth) values(m.member_id,sid,ep,p_subscription#>>'{keys,p256dh}',p_subscription#>>'{keys,auth}') on conflict(endpoint) do update set session_id=excluded.session_id,p256dh=excluded.p256dh,auth=excluded.auth,enabled=true;
 elsif p_action='disable' then update barberium.wa_devices set enabled=false where id=d.id;
 elsif p_action<>'status' then raise exception 'Ação inválida'; end if;
 return jsonb_build_object('enabled',exists(select 1 from barberium.wa_devices where endpoint=ep and member_id=m.member_id and enabled and session_id=sid));
end $$;
create function public.barberium_booking_claim() returns jsonb language plpgsql security definer set search_path=barberium,pg_temp as $$
declare outp jsonb; begin
 
 update barberium.booking_jobs set state='cancelled',lease_id=null where state in ('pending','sending') and expires_at<=now();
 delete from barberium.booking_jobs where expires_at<now()-interval '30 days';
 update barberium.booking_jobs set state='failed' where state='sending' and lease_until<now() and attempts>=5;
 with picked as(select id from barberium.booking_jobs where due_at<=now() and expires_at>now() and attempts<5 and (state='pending' or (state='sending' and lease_until<now())) order by due_at limit 2 for update skip locked), updated as(update barberium.booking_jobs j set state='sending',lease_id=gen_random_uuid(),lease_until=now()+interval '3 minutes',attempts=attempts+1 from picked p where j.id=p.id returning j.id,j.lease_id) select coalesce(jsonb_agg(to_jsonb(updated)),'[]'::jsonb) into outp from updated; return outp; end $$;
create function public.barberium_booking_result(p_id uuid,p_lease uuid,p_code int) returns void language plpgsql security definer set search_path=barberium,pg_temp as $$
begin
 if p_code in (404,410) then update barberium.wa_devices set enabled=false where id=(select device_id from barberium.booking_jobs where id=p_id and lease_id=p_lease); end if;
 update barberium.booking_jobs set state=case when p_code between 200 and 299 then 'sent' when p_code=409 then 'cancelled' when attempts<5 and (p_code=0 or p_code=429 or p_code>=500) then 'pending' else 'failed' end,due_at=now()+interval '1 minute'*attempts*attempts,lease_id=null,lease_until=null where id=p_id and lease_id=p_lease and state='sending';
end $$;
create or replace function barberium.push_tick() returns bigint language plpgsql security definer set search_path=barberium,vault,net,pg_temp as $$
declare rid bigint; begin
 perform barberium.wa_prepare();
 select net.http_post(url:=c.worker_url,headers:=jsonb_build_object('Content-Type','application/json','x-barberium-push-key',s.decrypted_secret),body:='{}'::jsonb,timeout_milliseconds:=180000) into rid from barberium.push_config c join vault.decrypted_secrets s on s.id=c.cron_secret_id where c.id and c.enabled and (exists(select 1 from barberium.push_jobs j where (j.state='pending' or(j.state='sending' and j.lease_until<now())) and j.due_at<=now()) or exists(select 1 from barberium.wa_jobs j where (j.state='pending' or(j.state='sending' and j.lease_until<now())) and j.due_at<=now()) or exists(select 1 from barberium.booking_jobs j where (j.state='pending' or(j.state='sending' and j.lease_until<now())) and j.due_at<=now())); return rid;
end $$;

revoke all on function barberium.booking_notify(),public.barberium_booking_claim(),public.barberium_booking_delivery(uuid,uuid),public.barberium_booking_result(uuid,uuid,int) from public,anon,authenticated;
grant execute on function public.barberium_booking_claim(),public.barberium_booking_delivery(uuid,uuid),public.barberium_booking_result(uuid,uuid,int) to service_role;

