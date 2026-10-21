-- 07 · Etapa 6: barbearia pelo endereço, barbearia ativa da equipe, ligações sempre dentro da
-- mesma barbearia e permissões padrão fechadas.

-- Endereço → barbearia.
do $$
declare r jsonb;
begin
  perform pg_temp.anonimo();
  r := public.barberium_resolve_tenant('www.ScalabriniBarbiere.com:443');
  perform pg_temp.igual(concat_ws('|', r #>> '{barbershop,slug}', r #>> '{unit,slug}', r ->> 'unit_fixed', r ->> 'host'),
                        'scalabrini-barbieri|braganca-paulista|true|scalabrinibarbiere.com',
                        'o endereço da Scalabrini abre a Scalabrini, fixo em Bragança (sem www., sem porta, maiúsculas tanto faz)');
  r := public.barberium_resolve_tenant('scalabrinibarbiere.com', 'barbearia-aurora');
  perform pg_temp.igual(r #>> '{barbershop,slug}', 'scalabrini-barbieri',
                        'no endereço real, ?barbearia=outra é ignorado');
  perform pg_temp.erro($q$select public.barberium_resolve_tenant('barbearia-que-nao-existe.com.br')$q$, 'TENANT_NOT_FOUND',
                       'endereço não cadastrado não abre barbearia nenhuma');
  perform pg_temp.erro('select * from public.barbershop_domains', 'permission denied', 'visitante não lê a tabela de endereços');
  perform pg_temp.ok(r ? 'units' and jsonb_array_length(r -> 'units') >= 1, 'a resposta traz a lista de unidades ativas');
  perform pg_temp.igual(coalesce(r ->> 'logo_url', '(sem logo)'), '(sem logo)', 'sem logo cadastrado em Ajustes, logo_url vem vazio');

  -- Endereço de teste, que aceita trocar de barbearia, e endereço sem unidade fixa.
  perform pg_temp.sistema();
  insert into public.barbershop_domains (host, barbershop_id, unit_id, allow_tenant_param)
  select 'teste.exemplo', id, null, true from public.barbershops where slug = 'scalabrini-barbieri';
  perform pg_temp.anonimo();
  r := public.barberium_resolve_tenant('teste.exemplo', 'barbearia-aurora');
  perform pg_temp.igual(concat_ws('|', r #>> '{barbershop,slug}', coalesce(r #>> '{unit,slug}', '(escolher)'), r ->> 'unit_fixed'),
                        'barbearia-aurora|(escolher)|false', 'endereço de teste abre outra barbearia com ?barbearia= e pede a unidade');
  perform pg_temp.igual(r ->> 'logo_url', '/barberium.svg', 'sem unidade escolhida, o logo vem da primeira unidade que tem logo');
  r := public.barberium_resolve_tenant('teste.exemplo', 'barbearia-aurora', 'centro');
  perform pg_temp.igual(r #>> '{unit,slug}', 'centro', 'a unidade escolhida pelo cliente volta preenchida');
  r := public.barberium_resolve_tenant('teste.exemplo', null, 'unidade-que-nao-existe');
  perform pg_temp.igual(coalesce(r #>> '{unit,slug}', '(escolher)'), '(escolher)', 'unidade inexistente: pede para escolher de novo');

  perform pg_temp.sistema();
  perform pg_temp.erro_cmd($q$update public.barbershops set status = 'inactive' where slug = 'barbearia-aurora';
                         select public.barberium_resolve_tenant('teste.exemplo', 'barbearia-aurora')$q$,
                       'TENANT_NOT_FOUND', 'barbearia inativa não abre');
  perform pg_temp.erro_cmd($q$insert into public.barbershop_domains (host, barbershop_id)
                         select 'WWW.Errado.com', id from public.barbershops limit 1$q$, 'barbershop_domains_host_valido',
                       'endereço é guardado em minúsculas e sem www.');
  perform pg_temp.erro_cmd($q$insert into public.barbershop_domains (host, barbershop_id, unit_id)
                         select 'mistura.exemplo', b.id, u.id from public.barbershops b, public.units u
                         where b.slug = 'barbearia-aurora' and u.slug = 'braganca-paulista'$q$, 'barbershop_domains_unit_id_barbershop_id_fkey',
                       'endereço não aponta para unidade de outra barbearia');
end $$;

-- Barbearia ativa na Área da Equipe.
do $$
declare v_aurora uuid := pg_temp.barbearia('barbearia-aurora');
begin
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.igual(pg_temp.roda('select public.barberium_staff_me()') ->> 'role', 'admin', 'ADM entra pelo endereço da própria barbearia');
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.erro('select public.barberium_staff_me()', 'sem acesso', 'ADM da Scalabrini não entra pelo endereço da Aurora');
  perform pg_temp.site_da_barbearia(null);
  perform pg_temp.igual(pg_temp.roda('select public.barberium_staff_me()') ->> 'role', 'admin',
                        'sem o cabeçalho (site antigo), quem tem um vínculo só continua entrando');

  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.erro('select public.barberium_staff_me()', 'sem acesso', 'barbeiro não entra pelo endereço de outra barbearia');

  -- Um login com vínculo em duas barbearias.
  perform pg_temp.sistema();
  insert into public.barbershop_members (barbershop_id, auth_user_id, role) values (v_aurora, pg_temp.adm_scalabrini(), 'admin');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.site_da_barbearia(null);
  perform pg_temp.erro('select public.barberium_staff_me()', 'sem acesso', 'login em duas barbearias sem dizer qual: não cai numa ao acaso');
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.ok(pg_temp.roda('select public.barberium_staff_team()')::text like '%Lucas Mendes%'
                     and pg_temp.roda('select public.barberium_staff_team()')::text not like '%Vinicius%',
                     'no endereço da Aurora, o mesmo login vê só a equipe da Aurora');
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.ok(pg_temp.roda('select public.barberium_staff_team()')::text like '%Vinicius%'
                     and pg_temp.roda('select public.barberium_staff_team()')::text not like '%Lucas Mendes%',
                     'no endereço da Scalabrini, o mesmo login vê só a equipe da Scalabrini');
  perform pg_temp.site_da_barbearia(null);
end $$;

-- Ligações sempre dentro da mesma barbearia (FKs compostas).
do $$
declare v_falta text;
begin
  perform pg_temp.sistema();
  select string_agg(c.conrelid::regclass || '.' || a.attname, ', ' order by 1) into v_falta
  from pg_constraint c
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
  where c.contype = 'f' and c.connamespace = 'public'::regnamespace and array_length(c.conkey, 1) = 1
    and exists (select 1 from pg_attribute x where x.attrelid = c.conrelid and x.attname = 'barbershop_id' and not x.attisdropped)
    and exists (select 1 from pg_attribute x where x.attrelid = c.confrelid and x.attname = 'barbershop_id' and not x.attisdropped)
    and not exists (
      select 1 from pg_constraint k
      where k.contype = 'f' and k.conrelid = c.conrelid and k.confrelid = c.confrelid and array_length(k.conkey, 1) = 2
        and k.conkey[1] = c.conkey[1]);
  perform pg_temp.igual(v_falta, null, 'toda ligação entre tabelas de barbearia exige a mesma barbearia dos dois lados (tabela nova também)');

  perform pg_temp.erro_cmd(format($q$update public.appointments set customer_id = %L where id = (select id from public.appointments where barbershop_id = %L limit 1)$q$,
                              pg_temp.cliente('barbearia-aurora', 1), pg_temp.barbearia('scalabrini-barbieri')),
                       'appointments_customer_id_barbearia_fkey', 'o banco recusa atendimento da Scalabrini com cliente da Aurora');
  perform pg_temp.erro_cmd(format($q$update public.professionals set unit_id = %L where id = %L$q$,
                              pg_temp.unidade('barbearia-aurora'), pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes')),
                       'professionals_unit_id_barbearia_fkey|professionals_unit_id', 'o banco recusa barbeiro da Scalabrini numa unidade da Aurora');
end $$;

-- Permissões padrão.
do $$
begin
  perform pg_temp.sistema();
  perform pg_temp.igual((select count(*)::text from information_schema.role_table_grants
                          where table_schema = 'public' and grantee in ('anon', 'authenticated')), '0',
                        'visitante e usuário logado não têm privilégio direto em nenhuma tabela');
  create table public.__teste_tabela_nova (id int);
  create function public.__teste_funcao_nova() returns int language sql as 'select 1';
  perform pg_temp.ok(not has_table_privilege('anon', 'public.__teste_tabela_nova', 'SELECT')
                     and not has_table_privilege('authenticated', 'public.__teste_tabela_nova', 'SELECT'),
                     'tabela nova nasce fechada para visitante e usuário logado');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.__teste_funcao_nova()', 'EXECUTE')
                     and not has_function_privilege('authenticated', 'public.__teste_funcao_nova()', 'EXECUTE'),
                     'função nova nasce fechada: precisa de GRANT explícito na migration');
  perform pg_temp.ok(has_function_privilege('service_role', 'public.__teste_funcao_nova()', 'EXECUTE'),
                     'o service_role (funções do servidor) continua podendo usar função nova');
  create function extensions.__teste_funcao_nova() returns int language sql as 'select 1';
  perform pg_temp.ok(has_function_privilege('anon', 'extensions.__teste_funcao_nova()', 'EXECUTE'),
                     'função nova de extensão continua liberada como antes');
end $$;

-- Meta financeira (o vazamento que a etapa 3 encontrou).
do $$
begin
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.erro(format('select public.barberium_staff_save_financial_goal(%L, current_date, 100000)', pg_temp.unidade('scalabrini-barbieri')),
                       'Unidade inválida', 'ADM da Aurora não grava meta na unidade da Scalabrini');
  perform pg_temp.funciona(format('select public.barberium_staff_save_financial_goal(%L, current_date, 100000)', pg_temp.unidade('barbearia-aurora')),
                           'ADM da Aurora grava meta na própria unidade');
end $$;
