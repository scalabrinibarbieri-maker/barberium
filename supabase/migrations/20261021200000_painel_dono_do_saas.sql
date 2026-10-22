-- Barberium · Painel do dono do SaaS · 21/10/2026
-- O dono do Barberium cadastra uma barbearia nova pelo painel (barberium.pages.dev/painel/):
-- barbearia, primeira unidade com padrões neutros, endereço <nome>.barberium.pages.dev e o
-- convite do dono da barbearia. O convite vira um link que o painel manda pelo WhatsApp; o
-- login é criado pela função barberium-convite (Supabase), que usa as funções do item 3.
--
-- 1. barberium.platform_admins: quem é dono do Barberium. Ninguém vira dono por migration; o
--    primeiro é cadastrado no SQL Editor (docs/ETAPA-6B-painel-do-dono.md).
-- 2. Funções do painel, só para donos do Barberium (o resto recebe "Acesso somente para o dono
--    do Barberium").
-- 3. Funções que só a função de convite usa (service_role).
--
-- Nada do que existe muda. Rollback: docs/etapa6b_rollback.sql

create table barberium.platform_admins (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table barberium.platform_admins enable row level security;
revoke all on barberium.platform_admins from public, anon, authenticated;
comment on table barberium.platform_admins is 'Donos do Barberium (SaaS): podem usar o painel. Cadastro pelo SQL Editor.';

create table barberium.barbershop_invites (
  id uuid primary key default gen_random_uuid(),
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  email text not null,
  full_name text not null,
  whatsapp text,
  role text not null default 'owner',
  auth_user_id uuid references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  link_generated_at timestamptz,
  constraint barbershop_invites_email_valido check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint barbershop_invites_role_valido check (role in ('owner', 'admin'))
);
create index barbershop_invites_barbershop_id_idx on barberium.barbershop_invites(barbershop_id);
alter table barberium.barbershop_invites enable row level security;
revoke all on barberium.barbershop_invites from public, anon, authenticated;
comment on table barberium.barbershop_invites is 'Convites de acesso à Área da Equipe feitos pelo painel do dono do Barberium.';

create or replace function barberium.is_platform_admin()
 returns boolean
 language sql
 stable security definer
 set search_path to 'barberium', 'pg_temp'
as $function$
  select auth.uid() is not null and exists (select 1 from barberium.platform_admins where auth_user_id = auth.uid())
$function$;

create or replace function barberium.exigir_dono_do_saas()
 returns void
 language plpgsql
 stable security definer
 set search_path to 'barberium', 'pg_temp'
as $function$
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  if not barberium.is_platform_admin() then raise exception 'Acesso somente para o dono do Barberium'; end if;
end
$function$;

-- Endereço grátis do Barberium para cada barbearia (publicado como ramo do Cloudflare Pages).
create or replace function barberium.endereco_barberium(p_slug text)
 returns text
 language sql
 immutable
as $function$
  select p_slug || '.barberium.pages.dev'
$function$;

-- Nomes que não podem virar endereço: ramos do próprio site e nomes de sistema.
create or replace function barberium.slug_reservado(p_slug text)
 returns boolean
 language sql
 immutable
as $function$
  select p_slug = any (array['main','staging','teste','test','preview','dev','prod','producao','www','painel','admin',
    'api','app','equipe','barberium','assets','shared','static','cdn','mail','email','suporte','ajuda','help','status',
    'docs','blog','login','conta','pagamento','pagamentos'])
$function$;

-- 2. Painel.

create or replace function public.barberium_platform_whoami()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  return jsonb_build_object(
    'is_admin', barberium.is_platform_admin(),
    'email', (select email from auth.users where id = auth.uid()));
end
$function$;

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
                           where i.barbershop_id = b.id), '[]'::jsonb),
      'staff_count', (select count(*) from public.barbershop_members m where m.barbershop_id = b.id and m.is_active)
    ) order by b.created_at, b.name)
    from public.barbershops b), '[]'::jsonb);
end
$function$;

create or replace function public.barberium_platform_create_barbershop(
  p_name text, p_slug text, p_unit_name text, p_city text, p_state text, p_whatsapp text,
  p_admin_name text, p_admin_email text, p_admin_whatsapp text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_slug text := lower(btrim(coalesce(p_slug, '')));
  v_unit text := btrim(coalesce(nullif(btrim(p_unit_name), ''), 'Unidade principal'));
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_state text := upper(nullif(btrim(coalesce(p_state, '')), ''));
  v_whats text := nullif(regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'), '');
  v_admin text := btrim(coalesce(p_admin_name, ''));
  v_email text := lower(btrim(coalesce(p_admin_email, '')));
  v_admin_whats text := nullif(regexp_replace(coalesce(p_admin_whatsapp, ''), '\D', '', 'g'), '');
  v_host text;
  v_b uuid;
  v_u uuid;
  v_unit_slug text;
  v_invite uuid;
begin
  perform barberium.exigir_dono_do_saas();
  if length(v_name) not between 2 and 80 then raise exception 'Nome da barbearia: de 2 a 80 letras'; end if;
  -- Até 28: é o limite que o Cloudflare Pages garante para o nome do ramo virar endereço.
  if v_slug !~ '^[a-z0-9]([a-z0-9-]{0,26}[a-z0-9])?$' or length(v_slug) < 3 or v_slug ~ '--' then
    raise exception 'Endereço: de 3 a 28 letras minúsculas, números ou hífen, sem acento';
  end if;
  if barberium.slug_reservado(v_slug) then raise exception 'Endereço reservado: escolha outro'; end if;
  v_host := barberium.endereco_barberium(v_slug);
  if exists (select 1 from public.barbershops where slug = v_slug)
     or exists (select 1 from public.barbershop_domains where host = v_host) then
    raise exception 'Endereço já em uso: escolha outro';
  end if;
  if length(v_unit) > 80 then raise exception 'Nome da unidade: até 80 letras'; end if;
  if v_state is not null and v_state !~ '^[A-Z]{2}$' then raise exception 'Estado: a sigla com 2 letras (ex.: SP)'; end if;
  if v_whats is not null and length(v_whats) not between 10 and 13 then raise exception 'WhatsApp da unidade: DDD e número'; end if;
  if length(v_admin) not between 2 and 80 then raise exception 'Nome do dono da barbearia: de 2 a 80 letras'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail do dono da barbearia inválido'; end if;
  if v_admin_whats is not null and length(v_admin_whats) not between 10 and 13 then raise exception 'WhatsApp do dono: DDD e número'; end if;
  -- WhatsApp no formato da unidade da Scalabrini (+55...).
  if v_whats is not null and length(v_whats) <= 11 then v_whats := '55' || v_whats; end if;
  if v_admin_whats is not null and length(v_admin_whats) <= 11 then v_admin_whats := '55' || v_admin_whats; end if;

  insert into public.barbershops (name, slug, status, timezone, settings)
  values (v_name, v_slug, 'active', 'America/Sao_Paulo', jsonb_build_object('criada_pelo_painel', true))
  returning id into v_b;

  v_unit_slug := coalesce(nullif(trim(both '-' from regexp_replace(lower(
                   translate(v_unit, 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
                                     'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn')), '[^a-z0-9]+', '-', 'g')), ''), 'principal');
  -- A unidade começa em manutenção: o site do cliente só abre depois que o dono da barbearia
  -- cadastrar serviços, equipe e horários e desligar a manutenção em Ajustes.
  insert into public.units (barbershop_id, name, slug, city, state, whatsapp, settings)
  values (v_b, v_unit, left(v_unit_slug, 40), v_city, v_state, case when v_whats is null then null else '+' || v_whats end,
          jsonb_build_object(
            'days_ahead', 30, 'slot_minutes', 15, 'min_advance_minutes', 30, 'must_finish_by_close', true,
            'cancel_before_minutes', 0, 'reschedule_before_minutes', 0,
            'client_maintenance_mode', true,
            'client_maintenance_message', 'Estamos preparando a agenda online. Em breve você poderá agendar por aqui.',
            'client_logo_url', '/barberium.svg',
            'client_hero_image_url', '/assets/capa-padrao.webp',
            'client_hero_label', v_name,
            'client_hero_title', 'Agende seu horário.',
            'client_header_subtitle', concat_ws(' • ', v_unit, v_city),
            'client_services_bullets', jsonb_build_array('Cortes e barba', 'Combos com hora marcada', 'Valores e duração na hora de agendar')))
  returning id into v_u;

  -- Horário inicial: segunda a sábado, 9h às 19h. O dono da barbearia ajusta em Ajustes.
  insert into public.business_hours (unit_id, professional_id, weekday, open_time, close_time, is_closed)
  select v_u, null, d, case when d = 0 then null else '09:00'::time end, case when d = 0 then null else '19:00'::time end, d = 0
  from generate_series(0, 6) d;

  insert into public.barbershop_domains (host, barbershop_id, unit_id) values (v_host, v_b, v_u);

  insert into barberium.barbershop_invites (barbershop_id, email, full_name, whatsapp, role, created_by)
  values (v_b, v_email, v_admin, v_admin_whats, 'owner', auth.uid())
  returning id into v_invite;

  return jsonb_build_object('barbershop_id', v_b, 'slug', v_slug, 'host', v_host, 'invite_id', v_invite);
end
$function$;

create or replace function public.barberium_platform_invite_detail(p_invite uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare r jsonb;
begin
  perform barberium.exigir_dono_do_saas();
  select jsonb_build_object('id', i.id, 'email', i.email, 'full_name', i.full_name, 'whatsapp', i.whatsapp, 'role', i.role,
                            'barbershop_name', b.name, 'barbershop_slug', b.slug, 'barbershop_status', b.status,
                            'host', coalesce((select d.host from public.barbershop_domains d where d.barbershop_id = b.id
                                              order by (d.host like '%.barberium.pages.dev') desc, d.host limit 1), ''))
    into r
  from barberium.barbershop_invites i join public.barbershops b on b.id = i.barbershop_id
  where i.id = p_invite;
  if r is null then raise exception 'Convite não encontrado'; end if;
  return r;
end
$function$;

-- 3. Só a função de convite (service_role): liga o login criado à barbearia do convite.
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
  insert into public.barbershop_members (barbershop_id, auth_user_id, role, is_active)
  values (i.barbershop_id, p_auth_user, i.role, true)
  on conflict (barbershop_id, auth_user_id) do update set is_active = true,
    role = case when public.barbershop_members.role in ('owner', 'admin') then public.barbershop_members.role else excluded.role end;
  update barberium.barbershop_invites set auth_user_id = p_auth_user, link_generated_at = now() where id = i.id;
  return jsonb_build_object('ok', true, 'barbershop_id', i.barbershop_id);
end
$function$;

revoke execute on function public.barberium_platform_whoami() from public, anon;
revoke execute on function public.barberium_platform_barbershops() from public, anon;
revoke execute on function public.barberium_platform_create_barbershop(text, text, text, text, text, text, text, text, text) from public, anon;
revoke execute on function public.barberium_platform_invite_detail(uuid) from public, anon;
revoke execute on function public.barberium_platform_link_invite(uuid, uuid) from public, anon, authenticated;
grant execute on function public.barberium_platform_whoami() to authenticated, service_role;
grant execute on function public.barberium_platform_barbershops() to authenticated, service_role;
grant execute on function public.barberium_platform_create_barbershop(text, text, text, text, text, text, text, text, text) to authenticated, service_role;
grant execute on function public.barberium_platform_invite_detail(uuid) to authenticated, service_role;
grant execute on function public.barberium_platform_link_invite(uuid, uuid) to service_role;
