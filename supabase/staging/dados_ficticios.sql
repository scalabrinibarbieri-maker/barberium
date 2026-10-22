-- Dados fictícios do banco de TESTE (staging). Roda a cada publicação no teste e pode rodar
-- quantas vezes for preciso: só cria o que ainda não existe.
--
-- NUNCA rodar na produção. Duas travas:
--   1. o workflow só passa a conexão do banco de teste para este arquivo;
--   2. o primeiro bloco aborta se o banco tiver cara de produção (mais de 50 clientes
--      sem a marca "teste" em staging_meta.ambiente).
--
-- Variáveis (psql -v): senha = senha dos logins de teste (segredo STAGING_SENHA_TESTE).
--
-- O que existe depois de rodar:
--   Scalabrini Barbieri (teste)  slug scalabrini-barbieri  (criada pelas migrations, com dados públicos)
--     adm.scalabrini@example.com       ADM
--     barbeiro.scalabrini@example.com  barbeiro, ligado a "Vinicius Nunes"
--   Barbearia Aurora             slug barbearia-aurora     (mesmos IDs do tenant de teste da produção)
--     adm.aurora@example.com           ADM
--   dono.barberium@example.com         dono do Barberium (painel em /painel/)
--   6 clientes fictícios em cada uma e alguns horários futuros marcados pelo próprio site.

\set ON_ERROR_STOP on
\o /dev/null
select set_config('barberium.senha_teste', :'senha', false);
\o

-- Trava contra produção + marca de ambiente (schema fora da impressão digital).
do $$
declare v_marca text; v_clientes int;
begin
  if length(coalesce(current_setting('barberium.senha_teste', true), '')) < 12 then
    raise exception 'STAGING_SENHA_TESTE ausente ou com menos de 12 caracteres';
  end if;
  if to_regclass('staging_meta.ambiente') is not null then
    execute 'select valor from staging_meta.ambiente where chave = ''ambiente''' into v_marca;
  end if;
  select count(*) into v_clientes from public.customers;
  if coalesce(v_marca, '') <> 'teste' and v_clientes > 50 then
    raise exception 'ABORTADO: este banco tem % clientes e não é o banco de teste.', v_clientes;
  end if;
end $$;
create schema if not exists staging_meta;
revoke all on schema staging_meta from public, anon, authenticated;
create table if not exists staging_meta.ambiente (chave text primary key, valor text not null);
insert into staging_meta.ambiente values ('ambiente', 'teste') on conflict (chave) do nothing;
insert into staging_meta.ambiente values ('ultimos_dados_ficticios', now()::text)
  on conflict (chave) do update set valor = excluded.valor;

-- Usuários de teste (IDs fixos). A senha é atualizada a cada execução.
do $$
declare
  u record;
  v_senha text := current_setting('barberium.senha_teste');
begin
  for u in
    select * from (values
      ('5a000000-0000-4000-8000-000000000001'::uuid, 'adm.scalabrini@example.com'),
      ('5a000000-0000-4000-8000-000000000002'::uuid, 'barbeiro.scalabrini@example.com'),
      ('5a000000-0000-4000-8000-000000000003'::uuid, 'adm.aurora@example.com'),
      ('5a000000-0000-4000-8000-000000000004'::uuid, 'dono.barberium@example.com')
    ) as t(id, email)
  loop
    if not exists (select 1 from auth.users where id = u.id) then
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        confirmation_token, recovery_token, email_change_token_new, email_change,
        raw_app_meta_data, raw_user_meta_data, is_super_admin, created_at, updated_at
      ) values (
        '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
        extensions.crypt(v_senha, extensions.gen_salt('bf')), now(),
        '', '', '', '',
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, false, now(), now()
      );
      insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (u.id::text, u.id,
              jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
              'email', now(), now(), now());
    else
      update auth.users
         set encrypted_password = extensions.crypt(v_senha, extensions.gen_salt('bf')),
             updated_at = now()
       where id = u.id
         and encrypted_password is distinct from extensions.crypt(v_senha, encrypted_password);
    end if;
  end loop;
end $$;

-- Scalabrini (teste): equipe, comissão e permissões.
do $$
declare
  v_b uuid := (select id from public.barbershops where slug = 'scalabrini-barbieri');
  v_vini uuid;
begin
  if v_b is null then raise exception 'Scalabrini não existe no banco de teste (migrations não aplicadas?)'; end if;
  select id into v_vini from public.professionals where barbershop_id = v_b and slug = 'vinicius-nunes';

  insert into public.barbershop_members (barbershop_id, auth_user_id, role, professional_id)
  values (v_b, '5a000000-0000-4000-8000-000000000001', 'admin', null),
         (v_b, '5a000000-0000-4000-8000-000000000002', 'barber', v_vini)
  on conflict (barbershop_id, auth_user_id) do nothing;

  insert into public.commission_profiles (professional_id, barbershop_id, default_percent, settlement_cycle, basis, updated_at)
  select p.id, v_b, 50, 'monthly', 'gross', now()
  from public.professionals p
  where p.barbershop_id = v_b
    and not exists (select 1 from public.commission_profiles c where c.professional_id = p.id);

  insert into public.professional_permissions (professional_id, barbershop_id, permissions, updated_at)
  select p.id, v_b, '{
      "edit_date": true, "edit_time": true, "open_cash": false, "close_cash": false,
      "edit_value": true, "view_phone": false, "view_value": true, "cash_supply": false,
      "edit_addons": true, "create_block": true, "edit_service": true, "mark_no_show": true,
      "sell_products": true, "view_birthday": true, "mark_completed": true, "view_full_name": true,
      "cash_withdrawal": false, "register_expense": false, "view_own_revenue": true,
      "cancel_appointment": true, "create_appointment": true, "edit_internal_note": true,
      "view_internal_note": true, "view_product_stock": false, "view_own_commission": true,
      "leave_payment_pending": false, "view_customer_history": false,
      "create_recurring_block": false, "confirm_membership_payment": false
    }'::jsonb, now()
  from public.professionals p
  where p.barbershop_id = v_b
    and not exists (select 1 from public.professional_permissions x where x.professional_id = p.id);
end $$;

-- Barbearia Aurora: mesmos IDs do tenant de teste da produção.
insert into public.barbershops (id, name, slug, status, settings, timezone)
values ('a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46', 'Barbearia Aurora', 'barbearia-aurora', 'active',
        '{"test_tenant": true}', 'America/Sao_Paulo')
on conflict (id) do nothing;

insert into public.units (id, barbershop_id, name, slug, city, state, settings)
values ('d086f4b3-ae4e-4e3d-b9d5-0c0568120bb0', 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46',
        'Unidade Centro', 'centro', 'Campinas', 'SP', '{
          "days_ahead": 14, "test_tenant": true, "slot_minutes": 30,
          "client_logo_url": "/barberium.svg", "client_hero_label": "Barbearia Aurora",
          "client_hero_title": "Seu estilo começa aqui.", "min_advance_minutes": 15,
          "must_finish_by_close": true, "client_hero_image_url": "",
          "client_header_subtitle": "Unidade Centro • Campinas"
        }')
on conflict (id) do nothing;

insert into public.professionals (id, barbershop_id, unit_id, name, slug, settings, image_path, sort_order)
values ('acceeafe-6a81-4924-8938-7141c43346a7', 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46',
        'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0', 'Lucas Mendes', 'lucas-mendes', '{}', 'barberium.svg', 10),
       ('becd9f01-749f-4e0a-ace3-c7878e348b8c', 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46',
        'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0', 'Rafael Costa', 'rafael-costa', '{}', 'barberium.svg', 20)
on conflict (id) do nothing;

insert into public.services (id, barbershop_id, unit_id, name, slug, price_cents, duration_min, duration_label,
                             image_path, sort_order, service_kind, description)
select v.id::uuid, 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46', 'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0',
       v.name, v.slug, v.price, v.dur, v.label, 'barberium.svg', v.ord, v.kind, v.descr
from (values
  ('5d7821b6-6ddf-4ccc-908a-8a004f4b2ff3', 'Corte Clássico', 'corte-classico', 5500, 45, '45 min', 10, 'service', 'Corte tradicional com acabamento completo.'),
  ('781769cf-50d3-4689-88e5-98cc6683161e', 'Barba Premium',  'barba-premium',  4500, 30, '30 min', 20, 'service', 'Barba com acabamento e finalização.'),
  ('fe78ed03-c5c2-4774-b86c-aa8cb2956acf', 'Sobrancelha',    'sobrancelha',    2000, 15, '15 min', 30, 'addon',   'Design e acabamento de sobrancelha.'),
  ('53def0c3-67de-46ee-967d-d161f6ab7dc7', 'Pezinho',        'pezinho',        1500, 15, '15 min', 40, 'addon',   'Acabamento de contornos e nuca.'),
  ('820db0fc-2f59-41cf-a835-000912e53265', 'Corte + Barba',  'corte-barba',    9000, 75, '1h15',   50, 'combo',   'Combo completo de corte e barba.')
) as v(id, name, slug, price, dur, label, ord, kind, descr)
on conflict do nothing;

insert into public.service_addons (barbershop_id, unit_id, base_service_id, addon_service_id,
                                   addon_price_cents, addon_duration_min, sort_order)
select 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46', 'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0', b.id, a.id, v.price, 15, v.ord
from (values
  ('barba-premium',  'sobrancelha', 1800, 10),
  ('corte-barba',    'sobrancelha', 1800, 10),
  ('corte-barba',    'pezinho',     1200, 20),
  ('corte-classico', 'sobrancelha', 1800, 10),
  ('corte-classico', 'pezinho',     1200, 20)
) as v(base, addon, price, ord)
join public.services b on b.unit_id = 'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0' and b.slug = v.base
join public.services a on a.unit_id = 'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0' and a.slug = v.addon
on conflict do nothing;

insert into public.professional_services (professional_id, service_id)
select p.id, s.id from public.professionals p join public.services s on s.unit_id = p.unit_id
where p.barbershop_id = 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46'
on conflict do nothing;

insert into public.business_hours (unit_id, professional_id, weekday, open_time, close_time, is_closed)
select 'd086f4b3-ae4e-4e3d-b9d5-0c0568120bb0', null::uuid, d,
       case when d = 0 then null else '09:00'::time end,
       case when d = 0 then null else '19:00'::time end,
       d = 0
from generate_series(0, 6) d
on conflict do nothing;

insert into public.barbershop_members (barbershop_id, auth_user_id, role)
values ('a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46', '5a000000-0000-4000-8000-000000000003', 'admin')
on conflict (barbershop_id, auth_user_id) do nothing;

-- Etapa 6: segunda unidade da Aurora, para testar a escolha de unidade no site do cliente.
insert into public.units (id, barbershop_id, name, slug, city, state, settings)
values ('aa000000-0000-4000-8000-000000000002', 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46',
        'Unidade Norte', 'norte', 'Campinas', 'SP', '{
          "days_ahead": 14, "test_tenant": true, "slot_minutes": 30, "client_logo_url": "/barberium.svg",
          "client_hero_label": "Barbearia Aurora", "client_hero_title": "Seu estilo começa aqui.",
          "min_advance_minutes": 15, "must_finish_by_close": true, "client_hero_image_url": "",
          "client_header_subtitle": "Unidade Norte • Campinas", "client_maintenance_mode": false
        }')
on conflict (id) do nothing;
insert into public.professionals (id, barbershop_id, unit_id, name, slug, settings, image_path, sort_order)
values ('aa000000-0000-4000-8000-000000000003', 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46',
        'aa000000-0000-4000-8000-000000000002', 'Bruno Lima', 'bruno-lima', '{}', 'barberium.svg', 10)
on conflict (id) do nothing;
insert into public.services (id, barbershop_id, unit_id, name, slug, price_cents, duration_min, duration_label,
                             image_path, sort_order, service_kind, description)
values ('aa000000-0000-4000-8000-000000000004', 'a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46',
        'aa000000-0000-4000-8000-000000000002', 'Corte Norte', 'corte-norte', 6000, 45, '45 min',
        'barberium.svg', 10, 'service', 'Corte da Unidade Norte.')
on conflict (id) do nothing;
insert into public.professional_services (professional_id, service_id)
values ('aa000000-0000-4000-8000-000000000003', 'aa000000-0000-4000-8000-000000000004')
on conflict do nothing;
insert into public.business_hours (unit_id, professional_id, weekday, open_time, close_time, is_closed)
select 'aa000000-0000-4000-8000-000000000002', null::uuid, d,
       case when d = 0 then null else '09:00'::time end,
       case when d = 0 then null else '19:00'::time end,
       d = 0
from generate_series(0, 6) d
on conflict do nothing;

-- Painel do dono do SaaS: o login de teste dono.barberium@example.com é dono do Barberium
-- (só no banco de teste; na produção o dono é cadastrado pelo SQL Editor).
insert into barberium.platform_admins (auth_user_id)
values ('5a000000-0000-4000-8000-000000000004')
on conflict (auth_user_id) do nothing;

-- Etapa 6: endereços de teste. Abrem a Scalabrini de teste (unidade de Bragança) e aceitam
-- ?barbearia=slug para abrir outra barbearia, como a Aurora. 127.0.0.1 é o computador onde
-- os testes rodam; "localhost" fica de fora de propósito, para testar endereço não cadastrado.
insert into public.barbershop_domains (host, barbershop_id, unit_id, allow_tenant_param)
select h.host, b.id, u.id, true
from public.barbershops b
join public.units u on u.barbershop_id = b.id and u.slug = 'braganca-paulista'
cross join (values ('staging.barberium.pages.dev'), ('127.0.0.1')) as h(host)
where b.slug = 'scalabrini-barbieri'
on conflict (host) do nothing;

-- No teste, o site do cliente começa aberto. Sem a chave, o site trata como "em manutenção";
-- se alguém salvar a opção pela Área da Equipe de teste, o valor salvo é respeitado.
update public.units
   set settings = coalesce(settings, '{}'::jsonb) || '{"client_maintenance_mode": false}'::jsonb
 where not (coalesce(settings, '{}'::jsonb) ? 'client_maintenance_mode');

-- Etapa 6: o rótulo da capa deixou de ter "Casa Scalabrini" como padrão no código (o padrão
-- agora é o nome da barbearia). A produção já tem o rótulo salvo; o teste fica igual a ela.
update public.units u
   set settings = coalesce(u.settings, '{}'::jsonb) || '{"client_hero_label": "Casa Scalabrini"}'::jsonb
  from public.barbershops b
 where b.id = u.barbershop_id and b.slug = 'scalabrini-barbieri' and u.slug = 'braganca-paulista'
   and not (coalesce(u.settings, '{}'::jsonb) ? 'client_hero_label');

-- Clientes fictícios (telefones da faixa 9000-00xx, que não existe).
insert into public.customers (barbershop_id, full_name, phone_e164)
select b.id, format('Cliente Teste %s', lpad(n::text, 2, '0')),
       format('+5511%s%s', case b.slug when 'scalabrini-barbieri' then '900000' else '910000' end, lpad(n::text, 3, '0'))
from public.barbershops b cross join generate_series(1, 6) n
where b.slug in ('scalabrini-barbieri', 'barbearia-aurora')
on conflict (barbershop_id, phone_e164) do nothing;

-- Horários futuros marcados pelo próprio fluxo do site, só se a barbearia ainda não tem nenhum.
do $$
declare
  t record; v_prof uuid; v_serv uuid; v_dia date; v_slots text[]; v_feitos int; i int;
begin
  for t in
    select * from (values
      ('scalabrini-barbieri', 'braganca-paulista', 'vinicius-nunes', 'corte', '900000'),
      ('barbearia-aurora',    'centro',            'lucas-mendes',   'corte-classico', '910000')
    ) as x(shop, unit, prof, serv, faixa)
  loop
    if exists (select 1 from public.appointments a join public.barbershops b on b.id = a.barbershop_id where b.slug = t.shop) then
      continue;
    end if;
    select p.id into v_prof from public.professionals p join public.barbershops b on b.id = p.barbershop_id
     where b.slug = t.shop and p.slug = t.prof;
    select s.id into v_serv from public.services s join public.barbershops b on b.id = s.barbershop_id
     where b.slug = t.shop and s.slug = t.serv;
    v_feitos := 0;
    for i in 1..14 loop
      exit when v_feitos >= 2;
      v_dia := current_date + i;
      select array(select jsonb_array_elements_text(
               public.barberium_get_available_slots(t.shop, t.unit, v_prof, v_serv, '{}'::uuid[], v_dia)))
        into v_slots;
      if coalesce(array_length(v_slots, 1), 0) = 0 then continue; end if;
      begin
        perform public.barberium_create_appointment(t.shop, t.unit, v_prof, v_serv, '{}'::uuid[], v_dia,
          v_slots[1]::time, format('Cliente Teste %s', lpad((v_feitos + 1)::text, 2, '0')),
          format('+5511%s%s', t.faixa, lpad((v_feitos + 1)::text, 3, '0')), null, null);
        v_feitos := v_feitos + 1;
      exception when others then
        raise notice 'Horário de teste não criado (% em %): %', t.shop, v_dia, sqlerrm;
      end;
    end loop;
    raise notice '%: % horário(s) de teste criado(s)', t.shop, v_feitos;
  end loop;
end $$;

select format('Dados fictícios ok: %s barbearias, %s membros da equipe, %s clientes, %s horários',
  (select count(*) from public.barbershops),
  (select count(*) from public.barbershop_members),
  (select count(*) from public.customers),
  (select count(*) from public.appointments)) as resumo;
