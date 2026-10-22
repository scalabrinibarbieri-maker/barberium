-- 09 · Convite de barbeiros pela barbearia e alertas de profissional novo no painel do dono do
-- Barberium (aviso e decisão de cobrança).

-- Convite de barbeiro.
do $$
declare r jsonb; v_inv uuid; v_user uuid := gen_random_uuid(); v_rafael uuid := pg_temp.profissional('barbearia-aurora', 'rafael-costa');
begin
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  r := pg_temp.roda(format($q$select public.barberium_staff_invite_barber(%L, ' Rafael.Novo@Example.com ', '(19) 98888-1111')$q$, v_rafael));
  perform pg_temp.igual(r ->> 'senha_nova', 'false', 'ADM convida um barbeiro dele com e-mail novo');
  v_inv := (r ->> 'invite_id')::uuid;
  r := pg_temp.roda(format('select public.barberium_invite_detail(%L)', v_inv));
  perform pg_temp.igual(concat_ws('|', r ->> 'email', r ->> 'role', r ->> 'full_name', r ->> 'whatsapp', r ->> 'pode_senha_nova'),
                        'rafael.novo@example.com|barber|Rafael Costa|5519988881111|true', 'o ADM lê o convite do barbeiro dele (para a função de convite)');

  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'adm.scalabrini@example.com')$q$, v_rafael),
                       'já tem login no Barberium', 'e-mail que já é login de outra pessoa é recusado (o link daria a senha dela)');
  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'sem-arroba')$q$, v_rafael), 'E-mail inválido', 'e-mail inválido é recusado');
  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'x@example.com')$q$, pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi')),
                       'Profissional inválido', 'ADM não convida profissional de outra barbearia');

  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'y@example.com')$q$, pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi')),
                       'somente para ADM', 'barbeiro não convida ninguém');
  perform pg_temp.erro(format('select public.barberium_invite_detail(%L)', v_inv), 'Sem permissão', 'barbeiro não lê convite');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.erro(format('select public.barberium_invite_detail(%L)', v_inv), 'Sem permissão', 'ADM de outra barbearia não lê o convite');

  -- Barbeiro que já tem login: só o mesmo e-mail, e vira link de senha nova.
  r := pg_temp.roda(format($q$select public.barberium_staff_invite_barber(%L, 'barbeiro.scalabrini@example.com')$q$, pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes')));
  perform pg_temp.igual(r ->> 'senha_nova', 'true', 'barbeiro que já tem login recebe link de senha nova');
  perform pg_temp.igual(pg_temp.roda(format('select public.barberium_invite_detail(%L)', r ->> 'invite_id')) ->> 'pode_senha_nova', 'true',
                        'e a função pode gerar a senha nova, porque é o barbeiro deste profissional');
  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'outro.email@example.com')$q$, pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes')),
                       'já tem login com outro e-mail', 'profissional com login não recebe convite para outro e-mail');

  -- Profissional inativo.
  perform pg_temp.sistema();
  update public.professionals set is_active = false where id = pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'jean.novo@example.com')$q$, pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi')),
                       'inativo', 'profissional inativo não recebe convite');

  -- O servidor liga o login criado: barbeiro do Rafael, só na Aurora.
  perform pg_temp.sistema();
  insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated', 'rafael.novo@example.com', now(), now(), '{}', '{}');
  perform pg_temp.servidor();
  perform pg_temp.igual(pg_temp.roda(format('select public.barberium_platform_link_invite(%L, %L)', v_inv, v_user)) ->> 'ok', 'true', 'o servidor liga o login ao convite do barbeiro');
  perform pg_temp.sistema();
  perform pg_temp.igual((select role || '|' || (professional_id = v_rafael) from public.barbershop_members where auth_user_id = v_user), 'barber|true',
                        'entra como barbeiro, ligado ao Rafael');
  perform pg_temp.como(v_user);
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.igual(pg_temp.roda('select public.barberium_staff_me()') ->> 'role', 'barber', 'o barbeiro entra na Área da Equipe da Aurora');
  perform pg_temp.site_da_barbearia(null);
end $$;

-- Login que um convite deste profissional criou e não chegou a ligar (a função caiu no meio):
-- pode receber o link de novo. Login solto, de outra origem, continua recusado.
do $$
declare r jsonb; v_lucas uuid := pg_temp.profissional('barbearia-aurora', 'lucas-mendes');
begin
  perform pg_temp.sistema();
  insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'orfao@example.com', now(), now(), '{}', '{}'),
         ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', 'solto@example.com', now(), now(), '{}', '{}');
  insert into barberium.barbershop_invites (barbershop_id, email, full_name, role, professional_id, created_by)
  values (pg_temp.barbearia('barbearia-aurora'), 'orfao@example.com', 'Lucas Mendes', 'barber', v_lucas, pg_temp.adm_aurora());
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  r := pg_temp.roda(format($q$select public.barberium_staff_invite_barber(%L, 'orfao@example.com')$q$, v_lucas));
  perform pg_temp.igual(pg_temp.roda(format('select public.barberium_invite_detail(%L)', r ->> 'invite_id')) ->> 'pode_senha_nova', 'true',
                        'login criado por convite deste profissional e não ligado: recebe o link de novo');
  perform pg_temp.erro(format($q$select public.barberium_staff_invite_barber(%L, 'solto@example.com')$q$, v_lucas),
                       'já tem login no Barberium', 'login solto, sem convite deste profissional, é recusado');
  perform pg_temp.site_da_barbearia(null);
end $$;

-- Convite de proprietário (feito pelo painel) não é lido pela barbearia.
do $$
declare v_inv uuid;
begin
  perform pg_temp.como(pg_temp.dono_barberium());
  v_inv := (pg_temp.roda($q$select public.barberium_platform_create_barbershop('Barbearia Alerta', 'barbearia-alerta', null, 'Jundiaí', 'SP', null,
                          'Paula Dona', 'paula@example.com', '11 97777-0000')$q$) ->> 'invite_id')::uuid;
  perform pg_temp.igual(pg_temp.roda(format('select public.barberium_invite_detail(%L)', v_inv)) ->> 'role', 'owner', 'o dono do Barberium lê o convite de proprietário');
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.erro(format('select public.barberium_invite_detail(%L)', v_inv), 'Sem permissão', 'ADM de barbearia não lê convite de proprietário');

  -- Profissional novo nessa barbearia: o aviso vai para o dono do convite, no WhatsApp dele.
  perform pg_temp.sistema();
  insert into public.professionals (barbershop_id, unit_id, name, slug, is_active)
  select u.barbershop_id, u.id, 'Profissional da Paula', 'profissional-da-paula', true from public.units u where u.barbershop_id = pg_temp.barbearia('barbearia-alerta');
  perform pg_temp.como(pg_temp.dono_barberium());
  perform pg_temp.igual((select concat_ws('|', e #>> '{contato,nome}', e #>> '{contato,whatsapp}') from jsonb_array_elements(pg_temp.roda('select public.barberium_platform_professional_charges()')) e
                         where e ->> 'professional_name' = 'Profissional da Paula'), 'Paula Dona|5511977770000', 'o aviso vai para o nome e o WhatsApp do dono da barbearia');
end $$;

-- Alertas de profissional novo e decisão de cobrança.
do $$
declare
  v_centro uuid;
  v_prof uuid;
  v_alerta uuid;
  r jsonb;
  v_lista jsonb;
  v_aurora jsonb;
  v_pendentes bigint;
begin
  perform pg_temp.sistema();
  select u.id into v_centro from public.units u where u.barbershop_id = pg_temp.barbearia('barbearia-aurora') and u.slug = 'centro';
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  v_prof := (pg_temp.roda(format($q$select public.barberium_staff_save_professional(null, %L, 'Diego Alerta', null, true)$q$, v_centro)) ->> 'professional_id')::uuid;
  perform pg_temp.sistema();
  perform pg_temp.igual((select string_agg(evento || '|' || decisao || '|' || professional_name, ',') from barberium.professional_charges where professional_id = v_prof),
                        'novo|pendente|Diego Alerta', 'profissional novo na agenda gera alerta pendente');

  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.roda(format($q$select public.barberium_staff_save_professional(%L, %L, 'Diego Alerta Silva', null, true)$q$, v_prof, v_centro));
  perform pg_temp.roda(format('select to_jsonb(public.barberium_staff_delete_professional(%L))', v_prof));
  perform pg_temp.sistema();
  perform pg_temp.igual((select count(*)::text from barberium.professional_charges where professional_id = v_prof), '1',
                        'mudar o nome ou desativar não gera alerta');
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.roda(format($q$select public.barberium_staff_save_professional(%L, %L, 'Diego Alerta Silva', null, true)$q$, v_prof, v_centro));
  perform pg_temp.sistema();
  perform pg_temp.igual((select string_agg(evento, ',' order by created_at, evento) from barberium.professional_charges where professional_id = v_prof), 'novo,reativado',
                        'reativar gera outro alerta');
  select id into v_alerta from barberium.professional_charges where professional_id = v_prof and evento = 'novo';

  perform pg_temp.anonimo();
  perform pg_temp.erro('select count(*) from barberium.professional_charges', 'permission denied', 'visitante não lê os alertas');
  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.erro('select public.barberium_platform_professional_charges()', 'somente para o dono do Barberium', 'ADM de barbearia não vê os alertas do painel');
  perform pg_temp.erro(format('select public.barberium_platform_decide_charge(%L, false)', v_alerta), 'somente para o dono do Barberium', 'ADM de barbearia não decide cobrança');

  perform pg_temp.como(pg_temp.dono_barberium());
  v_lista := pg_temp.roda('select public.barberium_platform_professional_charges()');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(v_lista) e where e ->> 'id' = v_alerta::text and e ->> 'barbershop_name' = 'Barbearia Aurora'
                             and e ->> 'decisao' = 'pendente' and (e -> 'professional_ativo')::boolean),
                     'o dono do Barberium vê o alerta, com a barbearia');
  perform pg_temp.funciona(format('select public.barberium_platform_charge_notified(%L)', v_alerta), 'o dono marca que avisou a barbearia');
  perform pg_temp.roda(format('select public.barberium_platform_charge_notified(%L)', v_alerta));
  perform pg_temp.erro(format('select public.barberium_platform_decide_charge(%L, true)', v_alerta), 'Valor inválido', 'cobrar exige o valor');
  perform pg_temp.erro(format('select public.barberium_platform_decide_charge(%L, true, 0)', v_alerta), 'Valor inválido', 'valor zero é recusado');
  perform pg_temp.roda(format($q$select public.barberium_platform_decide_charge(%L, true, 2990, 'primeiro mês')$q$, v_alerta));
  v_aurora := (select e from jsonb_array_elements(pg_temp.roda('select public.barberium_platform_barbershops()')) e where e ->> 'slug' = 'barbearia-aurora');
  perform pg_temp.sistema();
  v_pendentes := (select count(*) from barberium.professional_charges where barbershop_id = pg_temp.barbearia('barbearia-aurora') and decisao = 'pendente');
  perform pg_temp.igual(concat_ws('|', v_aurora #>> '{proxima_fatura,profissionais}', v_aurora #>> '{proxima_fatura,total_cents}', v_aurora ->> 'alertas_pendentes', v_pendentes > 0),
                        concat_ws('|', 1, 2990, v_pendentes, true), 'decidido "cobrar": entra na próxima fatura da barbearia (o outro alerta segue pendente)');
  perform pg_temp.como(pg_temp.dono_barberium());
  perform pg_temp.roda(format('select public.barberium_platform_decide_charge(%L, false)', v_alerta));
  v_aurora := (select e from jsonb_array_elements(pg_temp.roda('select public.barberium_platform_barbershops()')) e where e ->> 'slug' = 'barbearia-aurora');
  perform pg_temp.igual(v_aurora #>> '{proxima_fatura,total_cents}', '0', 'mudar para "não cobrar" tira da próxima fatura');

  perform pg_temp.sistema();
  perform pg_temp.igual((select concat_ws('|', decisao, coalesce(valor_cents::text, '-'), (avisado_em is not null)::text, (decidido_por = pg_temp.dono_barberium())::text)
                         from barberium.professional_charges where id = v_alerta), 'nao_cobrar|-|true|true', 'decisão guardada com quem decidiu e o aviso');
  update barberium.professional_charges set faturado_em = now() where id = v_alerta;
  perform pg_temp.como(pg_temp.dono_barberium());
  perform pg_temp.erro(format('select public.barberium_platform_decide_charge(%L, true, 1000)', v_alerta), 'Já faturado', 'depois de faturado, não muda');
end $$;
