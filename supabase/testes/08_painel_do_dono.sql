-- 08 · Painel do dono do SaaS: só o dono do Barberium usa; cadastro de barbearia com unidade,
-- padrões neutros, endereço <nome>.barberium.pages.dev e convite; o login do convite entra na
-- Área da Equipe pelo endereço da barbearia nova.

-- Quem pode usar o painel.
do $$
begin
  perform pg_temp.anonimo();
  perform pg_temp.erro('select public.barberium_platform_barbershops()', 'permission denied|Não autenticado', 'visitante não usa o painel');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.igual(pg_temp.roda('select public.barberium_platform_whoami()') ->> 'is_admin', 'false', 'ADM de barbearia não é dono do Barberium');
  perform pg_temp.erro('select public.barberium_platform_barbershops()', 'somente para o dono do Barberium', 'ADM de barbearia não vê a lista de barbearias');
  perform pg_temp.erro($q$select public.barberium_platform_create_barbershop('Invasora', 'invasora', null, null, null, null, 'X Y', 'x@example.com')$q$,
                       'somente para o dono do Barberium', 'ADM de barbearia não cadastra barbearia');
  perform pg_temp.erro(format('select public.barberium_platform_link_invite(%L, %L)', gen_random_uuid(), pg_temp.adm_scalabrini()),
                       'permission denied', 'usuário logado não liga convite (só a função do servidor)');
  perform pg_temp.como(pg_temp.dono_barberium());
  perform pg_temp.igual(pg_temp.roda('select public.barberium_platform_whoami()') ->> 'is_admin', 'true', 'o dono do Barberium é reconhecido');
  perform pg_temp.ok(jsonb_array_length(pg_temp.roda('select public.barberium_platform_barbershops()')) >= 2, 'o dono vê todas as barbearias');
  perform pg_temp.anonimo();
  perform pg_temp.erro('select count(*) from barberium.platform_admins', 'permission denied', 'visitante não lê a lista de donos');
  perform pg_temp.como(pg_temp.dono_barberium());
  perform pg_temp.erro('select count(*) from barberium.platform_admins', 'permission denied', 'nem o próprio dono lê a lista direto (só pelas funções)');
end $$;

-- Cadastro.
do $$
declare r jsonb; v_b uuid; v_u record; v_lista jsonb; v_inv uuid;
begin
  perform pg_temp.como(pg_temp.dono_barberium());
  r := pg_temp.roda($q$select public.barberium_platform_create_barbershop('Barbearia do Teste', 'barbearia-do-teste', 'Unidade Centro',
                       'Atibaia', 'sp', '(11) 98888-7777', 'Ana Souza', ' Ana.Souza@Example.com ', '11 97777-6666')$q$);
  perform pg_temp.igual(r ->> 'host', 'barbearia-do-teste.barberium.pages.dev', 'endereço grátis do Barberium com o nome escolhido');
  v_b := (r ->> 'barbershop_id')::uuid;

  perform pg_temp.sistema();
  select * into v_u from public.units where barbershop_id = v_b;
  select id into v_inv from barberium.barbershop_invites where barbershop_id = v_b;
  perform pg_temp.igual(concat_ws('|', v_u.name, v_u.slug, v_u.city, v_u.state, v_u.whatsapp), 'Unidade Centro|unidade-centro|Atibaia|SP|+5511988887777',
                        'primeira unidade com nome, cidade, estado e WhatsApp normalizados');
  perform pg_temp.igual(v_u.settings ->> 'client_maintenance_mode', 'true', 'site do cliente começa em manutenção');
  perform pg_temp.igual(concat_ws('|', v_u.settings ->> 'client_logo_url', v_u.settings ->> 'client_hero_image_url', v_u.settings ->> 'client_hero_label'),
                        '/barberium.svg|/assets/capa-padrao.webp|Barbearia do Teste', 'padrões neutros: logo do Barberium, capa neutra, nome da barbearia');
  perform pg_temp.igual((select count(*)::text from public.business_hours where unit_id = v_u.id and not is_closed), '6', 'horário inicial de segunda a sábado');
  perform pg_temp.igual((select string_agg(name, ',' order by sort_order) from public.services where unit_id = v_u.id), 'Corte,Barba',
                        'serviços de rascunho criados como em toda unidade nova');
  perform pg_temp.igual((select email || '|' || role || '|' || whatsapp from barberium.barbershop_invites where barbershop_id = v_b),
                        'ana.souza@example.com|owner|5511977776666', 'convite do dono da barbearia guardado (e-mail em minúsculas)');
  perform pg_temp.igual((select count(*)::text from public.barbershop_members where barbershop_id = v_b), '0', 'ninguém tem acesso antes do link do convite');

  perform pg_temp.anonimo();
  r := public.barberium_resolve_tenant('barbearia-do-teste.barberium.pages.dev');
  perform pg_temp.igual(concat_ws('|', r #>> '{barbershop,slug}', r #>> '{unit,slug}', r ->> 'unit_fixed', r ->> 'logo_url'),
                        'barbearia-do-teste|unidade-centro|true|/barberium.svg', 'o endereço novo abre a barbearia nova, fixa na unidade');

  perform pg_temp.como(pg_temp.dono_barberium());
  perform pg_temp.erro($q$select public.barberium_platform_create_barbershop('Outra', 'barbearia-do-teste', null, null, null, null, 'X Y', 'x@example.com')$q$,
                       'já em uso', 'endereço repetido é recusado');
  perform pg_temp.erro($q$select public.barberium_platform_create_barbershop('Outra', 'staging', null, null, null, null, 'X Y', 'x@example.com')$q$,
                       'reservado', 'endereço reservado (staging) é recusado');
  perform pg_temp.erro($q$select public.barberium_platform_create_barbershop('Outra', 'Com Espaço', null, null, null, null, 'X Y', 'x@example.com')$q$,
                       'minúsculas', 'endereço com espaço ou maiúscula é recusado');
  perform pg_temp.erro($q$select public.barberium_platform_create_barbershop('Outra', 'outra-barbearia', null, null, null, null, 'X Y', 'sem-arroba')$q$,
                       'E-mail', 'e-mail inválido é recusado');
  perform pg_temp.erro($q$select public.barberium_platform_create_barbershop('Outra', 'outra-barbearia', null, null, 'São Paulo', null, 'X Y', 'x@example.com')$q$,
                       'Estado', 'estado com mais de 2 letras é recusado');

  v_lista := pg_temp.roda('select public.barberium_platform_barbershops()');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(v_lista) e where e ->> 'slug' = 'barbearia-do-teste'
                             and e -> 'hosts' ? 'barbearia-do-teste.barberium.pages.dev' and jsonb_array_length(e -> 'invites') = 1),
                     'a lista do painel mostra a barbearia nova com endereço e convite');
  r := pg_temp.roda(format('select public.barberium_platform_invite_detail(%L)', v_inv));
  perform pg_temp.igual(concat_ws('|', r ->> 'email', r ->> 'host', r ->> 'barbershop_name'), 'ana.souza@example.com|barbearia-do-teste.barberium.pages.dev|Barbearia do Teste',
                        'detalhe do convite para a função de convite');
end $$;

-- Convite: a função do servidor liga o login criado à barbearia, e ele entra pelo endereço dela.
do $$
declare v_b uuid; v_i uuid; v_user uuid := gen_random_uuid(); v_outro uuid := gen_random_uuid();
begin
  perform pg_temp.como(pg_temp.dono_barberium());
  v_b := (pg_temp.roda($q$select public.barberium_platform_create_barbershop('Barbearia Convite', 'barbearia-convite', null, 'Jundiaí', 'SP', null,
                         'Bruno Dono', 'bruno.dono@example.com')$q$) ->> 'barbershop_id')::uuid;
  perform pg_temp.sistema();
  select id into v_i from barberium.barbershop_invites where barbershop_id = v_b;
  insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated', 'bruno.dono@example.com', now(), now(), '{}', '{}'),
         ('00000000-0000-0000-0000-000000000000', v_outro, 'authenticated', 'authenticated', 'outra.pessoa@example.com', now(), now(), '{}', '{}');

  perform pg_temp.servidor();
  perform pg_temp.erro_cmd(format('select public.barberium_platform_link_invite(%L, %L)', v_i, v_outro), 'não é o do convite',
                           'convite não liga o login de outro e-mail');
  perform pg_temp.igual(pg_temp.roda(format('select public.barberium_platform_link_invite(%L, %L)', v_i, v_user)) ->> 'ok', 'true',
                        'a função do servidor liga o login do convite');
  perform pg_temp.funciona(format('select public.barberium_platform_link_invite(%L, %L)', v_i, v_user), 'gerar o link de novo não duplica o acesso');

  perform pg_temp.sistema();
  perform pg_temp.igual((select role || '|' || is_active from public.barbershop_members where barbershop_id = v_b and auth_user_id = v_user), 'owner|true',
                        'dono da barbearia nova entra como Proprietário');
  perform pg_temp.como(v_user);
  perform pg_temp.site_da_barbearia('barbearia-convite');
  perform pg_temp.igual(pg_temp.roda('select public.barberium_staff_me()') ->> 'role', 'owner', 'ele entra na Área da Equipe pelo endereço da barbearia nova');
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.erro('select public.barberium_staff_me()', 'sem acesso', 'e não entra pelo endereço de outra barbearia');
  perform pg_temp.site_da_barbearia(null);
  perform pg_temp.igual(pg_temp.roda('select public.barberium_platform_whoami()') ->> 'is_admin', 'false', 'dono de barbearia não vira dono do Barberium');
end $$;
