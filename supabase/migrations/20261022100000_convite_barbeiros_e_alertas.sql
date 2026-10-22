-- Barberium · Convite de barbeiros e alertas de profissional novo · 22/10/2026
--
-- 1. A barbearia convida os próprios barbeiros: o ADM gera, na Área da Equipe, um link de
--    convite para o profissional (mesma função de convite do painel do dono). O barbeiro cria
--    a senha e entra com o papel "barbeiro", ligado àquele profissional.
-- 2. Toda vez que uma barbearia cadastra ou reativa um profissional na agenda, nasce um alerta
--    no painel do dono do Barberium (barberium.professional_charges). O dono avisa o dono da
--    barbearia pelo WhatsApp (sem valor) e decide: cobrar (com o valor, que entra na próxima
--    fatura, além da mensalidade/anuidade) ou não cobrar. O profissional já pode trabalhar
--    antes da decisão.
--
-- Rollback: docs/etapa6c_rollback.sql

-- 1. Convites também para barbeiro.
alter table barberium.barbershop_invites add column professional_id uuid;
alter table barberium.barbershop_invites drop constraint barbershop_invites_role_valido;
alter table barberium.barbershop_invites add constraint barbershop_invites_role_valido check (role in ('owner', 'admin', 'barber'));
alter table barberium.barbershop_invites add constraint barbershop_invites_barbeiro_tem_profissional
  check ((role = 'barber') = (professional_id is not null));
alter table barberium.barbershop_invites add constraint barbershop_invites_professional_barbearia_fkey
  foreign key (professional_id, barbershop_id) references public.professionals(id, barbershop_id) on delete cascade;

-- Login criado por um convite de barbeiro deste profissional que não chegou a ser ligado (a
-- função de convite caiu no meio): não é de mais ninguém, então pode receber o link de novo.
create or replace function barberium.login_orfao_do_convite(p_user uuid, p_barbershop uuid, p_professional uuid)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
  select p_user is not null and p_professional is not null
     and not exists (select 1 from public.barbershop_members x where x.auth_user_id = p_user)
     and not exists (select 1 from barberium.platform_admins a where a.auth_user_id = p_user)
     and exists (select 1 from barberium.barbershop_invites i join auth.users u on lower(u.email) = i.email
                 where u.id = p_user and i.barbershop_id = p_barbershop and i.professional_id = p_professional and i.role = 'barber')
$function$;
revoke all on function barberium.login_orfao_do_convite(uuid, uuid, uuid) from public;

-- ADM da barbearia convida um profissional dela. Regras contra tomar a conta de outra pessoa:
--   - se o profissional já tem login, só o mesmo e-mail (vira link de senha nova);
--   - e-mail que já tem login no Barberium e não é deste profissional é recusado;
--   - profissional que entra como ADM ou proprietário não recebe link pela barbearia.
create or replace function public.barberium_staff_invite_barber(p_professional_id uuid, p_email text, p_whatsapp text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare
  m record;
  p public.professionals;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_whats text := nullif(regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'), '');
  v_ligado record;
  v_user uuid;
  v_inv uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner', 'admin') then raise exception 'Acesso somente para ADM'; end if;
  select * into p from public.professionals where id = p_professional_id and barbershop_id = m.barbershop_id;
  if p.id is null then raise exception 'Profissional inválido'; end if;
  if not p.is_active then raise exception 'Profissional inativo: ative antes de convidar'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido'; end if;
  if v_whats is not null and length(v_whats) not between 10 and 13 then raise exception 'WhatsApp: DDD e número'; end if;
  if v_whats is not null and length(v_whats) <= 11 then v_whats := '55' || v_whats; end if;

  select bm.auth_user_id, bm.role, lower(u.email) as email into v_ligado
  from public.barbershop_members bm join auth.users u on u.id = bm.auth_user_id
  where bm.barbershop_id = m.barbershop_id and bm.professional_id = p.id
  order by bm.is_active desc limit 1;
  if v_ligado.auth_user_id is not null and v_ligado.role in ('owner', 'admin') then
    raise exception 'Este profissional entra como ADM: a senha dele é trocada pelo suporte do Barberium';
  end if;
  if v_ligado.auth_user_id is not null and v_ligado.email <> v_email then
    raise exception 'Este profissional já tem login com outro e-mail';
  end if;
  select id into v_user from auth.users where lower(email) = v_email;
  if v_user is not null and v_user is distinct from v_ligado.auth_user_id
     and not barberium.login_orfao_do_convite(v_user, m.barbershop_id, p.id) then
    raise exception 'Este e-mail já tem login no Barberium. Use outro e-mail ou fale com o suporte do Barberium';
  end if;

  insert into barberium.barbershop_invites (barbershop_id, email, full_name, whatsapp, role, professional_id, created_by)
  values (m.barbershop_id, v_email, p.name, v_whats, 'barber', p.id, auth.uid())
  returning id into v_inv;
  return jsonb_build_object('invite_id', v_inv, 'senha_nova', v_ligado.auth_user_id is not null);
end
$function$;

-- Detalhe do convite para a função de convite. Pode pedir: o dono do Barberium (qualquer
-- convite) ou o ADM/proprietário da barbearia do convite (só convite de barbeiro).
-- pode_senha_nova diz se, quando o e-mail já tem login, a função pode gerar link de senha nova.
create or replace function public.barberium_invite_detail(p_invite uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare
  i barberium.barbershop_invites;
  b public.barbershops;
  v_dono boolean;
  v_user uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  v_dono := barberium.is_platform_admin();
  select * into i from barberium.barbershop_invites where id = p_invite;
  if i.id is null then raise exception 'Convite não encontrado'; end if;
  if not v_dono and (i.role <> 'barber' or not exists (
       select 1 from public.barbershop_members x where x.auth_user_id = auth.uid() and x.barbershop_id = i.barbershop_id
          and x.is_active and x.role in ('owner', 'admin'))) then
    raise exception 'Sem permissão para este convite';
  end if;
  select * into b from public.barbershops where id = i.barbershop_id;
  select id into v_user from auth.users where lower(email) = i.email;
  return jsonb_build_object(
    'id', i.id, 'email', i.email, 'full_name', i.full_name, 'whatsapp', i.whatsapp, 'role', i.role,
    'barbershop_name', b.name, 'barbershop_slug', b.slug, 'barbershop_status', b.status,
    'host', coalesce((select d.host from public.barbershop_domains d where d.barbershop_id = b.id
                      order by (d.host like '%.barberium.pages.dev') desc, d.host limit 1), ''),
    'pode_senha_nova', v_user is null or v_dono or exists (
       select 1 from public.barbershop_members x where x.auth_user_id = v_user and x.barbershop_id = i.barbershop_id
          and x.professional_id = i.professional_id and x.role = 'barber')
       or (i.role = 'barber' and barberium.login_orfao_do_convite(v_user, i.barbershop_id, i.professional_id)));
end
$function$;

-- Liga o login criado à barbearia do convite (só o servidor). Barbeiro: papel "barber",
-- ligado ao profissional do convite. Quem já é ADM ou proprietário ali continua como está.
create or replace function public.barberium_platform_link_invite(p_invite uuid, p_auth_user uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare
  i barberium.barbershop_invites;
  v_email text;
begin
  select * into i from barberium.barbershop_invites where id = p_invite for update;
  if i.id is null then raise exception 'Convite não encontrado'; end if;
  select lower(email) into v_email from auth.users where id = p_auth_user;
  if v_email is null or v_email <> i.email then raise exception 'O login não é o do convite'; end if;
  insert into public.barbershop_members (barbershop_id, auth_user_id, role, professional_id, is_active)
  values (i.barbershop_id, p_auth_user, i.role, i.professional_id, true)
  on conflict (barbershop_id, auth_user_id) do update set is_active = true,
    role = case when public.barbershop_members.role in ('owner', 'admin') then public.barbershop_members.role else excluded.role end,
    professional_id = coalesce(excluded.professional_id, public.barbershop_members.professional_id);
  update barberium.barbershop_invites set auth_user_id = p_auth_user, link_generated_at = now() where id = i.id;
  return jsonb_build_object('ok', true, 'barbershop_id', i.barbershop_id);
end
$function$;

-- 2. Alertas de profissional novo e decisão de cobrança.
create table barberium.professional_charges (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  professional_id uuid,
  professional_name text not null,
  evento text not null,
  created_at timestamptz not null default now(),
  avisado_em timestamptz,
  decisao text not null default 'pendente',
  valor_cents integer,
  observacao text,
  decidido_em timestamptz,
  decidido_por uuid references auth.users(id) on delete set null,
  faturado_em timestamptz,
  constraint professional_charges_evento_valido check (evento in ('novo', 'reativado')),
  constraint professional_charges_decisao_valida check (decisao in ('pendente', 'cobrar', 'nao_cobrar')),
  constraint professional_charges_valor_quando_cobra check ((decisao = 'cobrar') = (valor_cents is not null) and coalesce(valor_cents, 1) > 0),
  constraint professional_charges_professional_barbearia_fkey
    foreign key (professional_id, barbershop_id) references public.professionals(id, barbershop_id) on delete set null (professional_id)
);
create index professional_charges_barbershop_id_idx on barberium.professional_charges(barbershop_id);
create index professional_charges_em_aberto_idx on barberium.professional_charges(created_at) where faturado_em is null;
alter table barberium.professional_charges enable row level security;
revoke all on barberium.professional_charges from public, anon, authenticated;
comment on table barberium.professional_charges is
  'Profissional novo ou reativado numa barbearia: alerta no painel do dono do Barberium e decisão de cobrança na próxima fatura.';

create or replace function barberium.alerta_profissional_novo()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'pg_temp'
as $function$
begin
  if tg_op = 'INSERT' and new.is_active then
    insert into barberium.professional_charges (barbershop_id, professional_id, professional_name, evento)
    values (new.barbershop_id, new.id, new.name, 'novo');
  elsif tg_op = 'UPDATE' and new.is_active and not old.is_active then
    insert into barberium.professional_charges (barbershop_id, professional_id, professional_name, evento)
    values (new.barbershop_id, new.id, new.name, 'reativado');
  end if;
  return null;
end
$function$;
create trigger trg_alerta_profissional_novo
  after insert or update of is_active on public.professionals
  for each row execute function barberium.alerta_profissional_novo();

-- Contato do dono da barbearia para o aviso: o do convite de proprietário mais recente; sem
-- convite (barbearias de antes do painel), o WhatsApp da unidade.
create or replace function barberium.contato_do_dono(p_barbershop uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'barberium', 'pg_temp'
as $function$
  select jsonb_build_object(
    'nome', (select i.full_name from barberium.barbershop_invites i where i.barbershop_id = p_barbershop and i.role = 'owner' order by i.created_at desc limit 1),
    'whatsapp', coalesce(
      (select i.whatsapp from barberium.barbershop_invites i where i.barbershop_id = p_barbershop and i.role = 'owner' and i.whatsapp is not null order by i.created_at desc limit 1),
      (select nullif(regexp_replace(coalesce(u.whatsapp, ''), '\D', '', 'g'), '') from public.units u
        where u.barbershop_id = p_barbershop and u.is_active and coalesce(u.whatsapp, '') <> '' order by u.created_at limit 1)))
$function$;

-- Lista do painel: pendentes, os que vão para a próxima fatura e os "não cobrar" dos últimos 15 dias.
create or replace function public.barberium_platform_professional_charges()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
begin
  perform barberium.exigir_dono_do_saas();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'barbershop_slug', b.slug, 'barbershop_name', b.name,
      'professional_name', c.professional_name, 'professional_ativo', coalesce(p.is_active, false),
      'evento', c.evento, 'created_at', c.created_at, 'avisado_em', c.avisado_em,
      'decisao', c.decisao, 'valor_cents', c.valor_cents, 'observacao', c.observacao, 'decidido_em', c.decidido_em,
      'contato', barberium.contato_do_dono(b.id))
      order by (c.decisao = 'pendente') desc, c.created_at desc)
    from barberium.professional_charges c
    join public.barbershops b on b.id = c.barbershop_id
    left join public.professionals p on p.id = c.professional_id
    where c.faturado_em is null
      and (c.decisao <> 'nao_cobrar' or c.decidido_em > now() - interval '15 days')), '[]'::jsonb);
end
$function$;

create or replace function public.barberium_platform_charge_notified(p_charge uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'pg_temp'
as $function$
begin
  perform barberium.exigir_dono_do_saas();
  update barberium.professional_charges set avisado_em = now() where id = p_charge;
  if not found then raise exception 'Alerta não encontrado'; end if;
  return jsonb_build_object('ok', true);
end
$function$;

create or replace function public.barberium_platform_decide_charge(p_charge uuid, p_cobrar boolean, p_valor_cents integer default null, p_observacao text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'pg_temp'
as $function$
declare c barberium.professional_charges;
begin
  perform barberium.exigir_dono_do_saas();
  select * into c from barberium.professional_charges where id = p_charge for update;
  if c.id is null then raise exception 'Alerta não encontrado'; end if;
  if c.faturado_em is not null then raise exception 'Já faturado: não dá para mudar'; end if;
  if p_cobrar is null then raise exception 'Escolha cobrar ou não cobrar'; end if;
  if p_cobrar and (p_valor_cents is null or p_valor_cents <= 0 or p_valor_cents > 10000000) then
    raise exception 'Valor inválido';
  end if;
  update barberium.professional_charges
     set decisao = case when p_cobrar then 'cobrar' else 'nao_cobrar' end,
         valor_cents = case when p_cobrar then p_valor_cents end,
         observacao = nullif(btrim(coalesce(p_observacao, '')), ''),
         decidido_em = now(), decidido_por = auth.uid()
   where id = c.id;
  return jsonb_build_object('ok', true);
end
$function$;

-- Lista de barbearias do painel: agora com alertas pendentes e o que entra na próxima fatura.
create or replace function public.barberium_platform_barbershops()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
begin
  perform barberium.exigir_dono_do_saas();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'slug', b.slug, 'name', b.name, 'status', b.status, 'created_at', b.created_at,
      'hosts', coalesce((select jsonb_agg(d.host order by d.host) from public.barbershop_domains d where d.barbershop_id = b.id), '[]'::jsonb),
      'units', coalesce((select jsonb_agg(jsonb_build_object('name', u.name, 'city', u.city, 'state', u.state, 'is_active', u.is_active) order by u.name)
                         from public.units u where u.barbershop_id = b.id), '[]'::jsonb),
      'managers', coalesce((select jsonb_agg(jsonb_build_object('email', au.email, 'role', m.role, 'is_active', m.is_active,
                                                                'last_sign_in_at', au.last_sign_in_at) order by au.email)
                            from public.barbershop_members m join auth.users au on au.id = m.auth_user_id
                            where m.barbershop_id = b.id and m.role in ('owner', 'admin')), '[]'::jsonb),
      'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'full_name', i.full_name,
                                                               'whatsapp', i.whatsapp, 'created_at', i.created_at,
                                                               'link_generated_at', i.link_generated_at,
                                                               'last_sign_in_at', au.last_sign_in_at) order by i.created_at)
                           from barberium.barbershop_invites i left join auth.users au on au.id = i.auth_user_id
                           where i.barbershop_id = b.id and i.role in ('owner', 'admin')), '[]'::jsonb),
      'staff_count', (select count(*) from public.barbershop_members m where m.barbershop_id = b.id and m.is_active),
      'professionals_active', (select count(*) from public.professionals p where p.barbershop_id = b.id and p.is_active),
      'alertas_pendentes', (select count(*) from barberium.professional_charges c where c.barbershop_id = b.id and c.decisao = 'pendente'),
      'proxima_fatura', jsonb_build_object(
        'profissionais', (select count(*) from barberium.professional_charges c where c.barbershop_id = b.id and c.decisao = 'cobrar' and c.faturado_em is null),
        'total_cents', (select coalesce(sum(c.valor_cents), 0) from barberium.professional_charges c where c.barbershop_id = b.id and c.decisao = 'cobrar' and c.faturado_em is null))
    ) order by b.created_at, b.name)
    from public.barbershops b), '[]'::jsonb);
end
$function$;

revoke execute on function public.barberium_staff_invite_barber(uuid, text, text) from public, anon;
revoke execute on function public.barberium_invite_detail(uuid) from public, anon;
revoke execute on function public.barberium_platform_professional_charges() from public, anon;
revoke execute on function public.barberium_platform_charge_notified(uuid) from public, anon;
revoke execute on function public.barberium_platform_decide_charge(uuid, boolean, integer, text) from public, anon;
grant execute on function public.barberium_staff_invite_barber(uuid, text, text) to authenticated, service_role;
grant execute on function public.barberium_invite_detail(uuid) to authenticated, service_role;
grant execute on function public.barberium_platform_professional_charges() to authenticated, service_role;
grant execute on function public.barberium_platform_charge_notified(uuid) to authenticated, service_role;
grant execute on function public.barberium_platform_decide_charge(uuid, boolean, integer, text) to authenticated, service_role;
