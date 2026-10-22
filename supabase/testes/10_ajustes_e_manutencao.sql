-- 10 · Etapa 7a: salvar a unidade grava só as chaves enviadas, e a manutenção da Área do
-- Cliente vale também no banco (o site do cliente não agenda nem reagenda).

-- Regra da manutenção: a mesma da tela (sem a chave, ou nula, conta como ligada).
do $$
begin
  perform pg_temp.sistema();
  perform pg_temp.igual(concat_ws('|',
      barberium.unidade_em_manutencao('{}'),
      barberium.unidade_em_manutencao('{"client_maintenance_mode": null}'),
      barberium.unidade_em_manutencao('{"client_maintenance_mode": true}'),
      barberium.unidade_em_manutencao('{"client_maintenance_mode": false}'),
      barberium.unidade_em_manutencao('{"client_maintenance_mode": "false"}'),
      barberium.unidade_em_manutencao(null)),
    't|t|t|f|f|t', 'manutenção: sem a chave ou nula = ligada; só true liga; false abre (igual à tela)');
end $$;

-- Salvar a unidade.
do $$
declare
  v_centro uuid;
  v_antes jsonb;
  v_depois jsonb;
  r jsonb;
  v_nova uuid;
begin
  perform pg_temp.sistema();
  select id into v_centro from public.units where barbershop_id = pg_temp.barbearia('barbearia-aurora') and slug = 'centro';
  update public.units set settings = settings || '{"x_teste_a": "1", "x_teste_b": "1"}' where id = v_centro;
  select settings into v_antes from public.units where id = v_centro;

  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  r := pg_temp.roda(format($q$select public.barberium_staff_save_unit(%L, 'Unidade Centro', 'Campinas', 'SP', null, null, true, '{"x_teste_b": "2"}')$q$, v_centro));
  perform pg_temp.igual(r ->> 'ok', 'true', 'ADM salva a unidade mandando só uma chave');
  perform pg_temp.sistema();
  select settings into v_depois from public.units where id = v_centro;
  perform pg_temp.igual(concat_ws('|', v_depois ->> 'x_teste_a', v_depois ->> 'x_teste_b'), '1|2', 'a chave enviada muda; a outra continua');
  perform pg_temp.igual((v_depois - 'x_teste_b')::text, (v_antes - 'x_teste_b')::text, 'nenhuma outra configuração da unidade se perde (aparência, manutenção, regras da agenda)');

  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.roda(format($q$select public.barberium_staff_save_unit(%L, 'Unidade Centro', 'Campinas', 'SP', null, null, true, null)$q$, v_centro));
  perform pg_temp.sistema();
  perform pg_temp.igual((select settings from public.units where id = v_centro)::text, v_depois::text, 'sem configurações no pedido, nada muda nelas');

  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  perform pg_temp.erro(format($q$select public.barberium_staff_save_unit(%L, 'Unidade Centro', 'Campinas', 'SP', null, null, true, '[1, 2]')$q$, v_centro),
                       'Configurações da unidade inválidas', 'configurações que não são um objeto são recusadas');
  perform pg_temp.roda(format($q$select public.barberium_staff_save_unit(%L, 'Unidade Centro', 'Campinas', 'SP', null, null, true, '{"x_teste_a": null}')$q$, v_centro));
  perform pg_temp.sistema();
  perform pg_temp.igual(coalesce((select settings -> 'x_teste_a' from public.units where id = v_centro)::text, 'sumiu'), 'null',
                        'mandar a chave com valor vazio (null) grava vazio');

  perform pg_temp.como(pg_temp.adm_aurora());
  perform pg_temp.site_da_barbearia('barbearia-aurora');
  v_nova := (pg_temp.roda($q$select public.barberium_staff_save_unit(null, 'Unidade Teste 7a', 'Campinas', 'SP', null, null, true, '{"slot_minutes": 15}')$q$) ->> 'unit_id')::uuid;
  perform pg_temp.sistema();
  perform pg_temp.igual((select settings::text from public.units where id = v_nova), '{"slot_minutes": 15}', 'unidade nova nasce com as configurações enviadas');

  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.erro(format($q$select public.barberium_staff_save_unit(%L, 'X', null, null, null, null, true, '{}')$q$, v_centro),
                       'somente para ADM', 'barbeiro não salva unidade');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_save_unit(%L, 'Unidade Centro', null, null, null, null, true, '{"x_teste_b": "9"}')$q$, v_centro),
                       'Unidade inválida', 'ADM não salva unidade de outra barbearia');
  perform pg_temp.site_da_barbearia(null);
end $$;

-- Manutenção no banco: o site do cliente não agenda nem reagenda; cancelar continua; a equipe agenda.
do $$
declare
  v_unidade uuid := pg_temp.unidade('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(9);
  v_hora time;
  v_hora2 time;
  r jsonb;
  v_tok text;
  v_ap uuid;
begin
  perform pg_temp.sistema();
  update public.units set settings = settings || '{"client_maintenance_mode": true}' where id = v_unidade;
  v_hora := pg_temp.primeiro_horario('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, v_dia);

  perform pg_temp.anonimo();
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,%L,'Cliente Manutencao','(11) 97777-0001',null,null)$q$,
                              v_vini, v_corte, v_dia, v_hora), 'UNIT_IN_MAINTENANCE', 'em manutenção, o site do cliente não agenda');

  perform pg_temp.sistema();
  update public.units set settings = settings - 'client_maintenance_mode' where id = v_unidade;
  perform pg_temp.anonimo();
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,%L,'Cliente Manutencao','(11) 97777-0001',null,null)$q$,
                              v_vini, v_corte, v_dia, v_hora), 'UNIT_IN_MAINTENANCE', 'unidade que nunca salvou a manutenção conta como fechada (igual à tela)');

  perform pg_temp.sistema();
  update public.units set settings = settings || '{"client_maintenance_mode": false}' where id = v_unidade;
  perform pg_temp.anonimo();
  r := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia, v_hora,
                                           'Cliente Manutencao', '(11) 97777-0001', null, null);
  perform pg_temp.ok(r ? 'appointment_id', 'com a manutenção desligada, o site do cliente agenda', r::text);
  v_tok := r ->> 'access_token';
  v_ap := (r ->> 'appointment_id')::uuid;

  -- Liga a manutenção com o horário já marcado.
  perform pg_temp.sistema();
  update public.units set settings = settings || '{"client_maintenance_mode": true}' where id = v_unidade;
  v_hora2 := pg_temp.primeiro_horario('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, v_dia + 1);
  perform pg_temp.anonimo();
  perform pg_temp.erro(format($q$select public.barberium_reschedule_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,%L,%L,'{}',%L,%L)$q$,
                              v_tok, v_ap, v_vini, v_corte, v_dia + 1, v_hora2), 'UNIT_IN_MAINTENANCE', 'em manutenção, o cliente não reagenda');
  perform pg_temp.sistema();
  perform pg_temp.igual((select status from public.appointments where id = v_ap), 'confirmed', 'o horário recusado no reagendamento continua confirmado');
  perform pg_temp.anonimo();
  perform pg_temp.igual(pg_temp.roda(format($q$select public.barberium_cancel_appointment('scalabrini-barbieri', %L, %L)$q$, v_tok, v_ap))::text, 'true',
                        'em manutenção, o cliente ainda pode cancelar o próprio horário');

  -- A equipe agenda normalmente com a manutenção ligada.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini, v_corte, '{}', '{}', v_dia, v_hora, false, null, null);
  perform pg_temp.ok(r ? 'appointment_id', 'em manutenção, a equipe continua agendando pela Área da Equipe', r::text);
end $$;
