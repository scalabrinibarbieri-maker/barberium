-- 05 · Quem pode chamar o quê: visitante sem login, usuário sem vínculo, barbeiro × ADM e o
-- token do cliente (que não pode servir em outra barbearia nem com outro cliente).

-- Lista fechada do que um visitante sem login consegue executar. Função nova aberta ao público
-- faz este teste falhar de propósito: precisa ser uma decisão consciente.
do $$
declare v_lista text; v_esperada text := concat_ws(', ',
  'barberium_cancel_appointment', 'barberium_create_appointment', 'barberium_customer_membership_actions_state',
  'barberium_customer_membership_booking_options', 'barberium_customer_open_profile', 'barberium_customer_refresh_membership_states',
  'barberium_customer_request_membership_action', 'barberium_customer_reserve_membership_use', 'barberium_get_available_slots',
  'barberium_get_catalog', 'barberium_get_customer_portal', 'barberium_public_membership_plans', 'barberium_push_device',
  'barberium_push_public_config', 'barberium_push_subscribe', 'barberium_request_membership', 'barberium_reschedule_appointment',
  'barberium_resolve_tenant', 'barberium_update_customer_profile');
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_lista
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
    and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  perform pg_temp.igual(v_lista, v_esperada, 'funções abertas a visitante sem login: as 19 do site do cliente (etapa 6: entra a do endereço, saem as 3 da equipe)');
  perform pg_temp.ok(not has_schema_privilege('anon', 'barberium', 'USAGE') and not has_schema_privilege('authenticated', 'barberium', 'USAGE'),
                     'o schema interno "barberium" é fechado para o site');
  perform pg_temp.igual((select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname not like 'barberium\_%'
                            and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                            and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')), '0',
                        'nenhuma função fora do padrão barberium_ aberta para usuários logados');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.barberium_staff_balance_quick(date,date,uuid)', 'EXECUTE')
                     and not has_function_privilege('anon', 'public.barberium_staff_free_ranges(date,uuid)', 'EXECUTE')
                     and not has_function_privilege('anon', 'public.barberium_staff_performance_v12_33(date,date)', 'EXECUTE'),
    'Saldos, horários livres e desempenho da equipe não são mais executáveis por visitante (etapa 6)');
end $$;

-- Visitante e usuário sem vínculo com barbearia.
do $$
begin
  perform pg_temp.anonimo();
  perform pg_temp.erro('select public.barberium_staff_balance_quick(current_date - 1, current_date, null)', 'permission denied|Não autenticado', 'visitante não lê Saldos');
  perform pg_temp.erro('select public.barberium_staff_free_ranges(current_date, null)', 'permission denied|Não autenticado', 'visitante não lê horários livres da equipe');
  perform pg_temp.erro('select public.barberium_staff_performance_v12_33(current_date - 1, current_date)', 'permission denied|Não autenticado', 'visitante não lê desempenho');
  perform pg_temp.erro('select public.barberium_staff_finance_report(current_date - 1, current_date, null, ''cash'')', 'permission denied|Não autenticado',
                       'visitante não chama o relatório financeiro');

  perform pg_temp.como('11111111-1111-4111-8111-111111111111');
  perform pg_temp.erro('select public.barberium_staff_me()', 'sem acesso', 'usuário logado sem vínculo não entra na equipe');
  perform pg_temp.erro('select public.barberium_staff_balance_quick(current_date - 1, current_date, null)', 'Sem acesso', 'usuário sem vínculo não lê Saldos');
  perform pg_temp.erro('select public.barberium_staff_finance_report(current_date - 1, current_date, null, ''cash'')', 'restritos ao ADM|sem acesso',
                       'usuário sem vínculo não lê o relatório financeiro');
end $$;

-- Barbeiro × ADM.
do $$
declare v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
begin
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.erro('select public.barberium_staff_finance_report(current_date - 30, current_date, null, ''cash'')', 'restritos ao ADM', 'barbeiro não vê o relatório financeiro');
  perform pg_temp.erro('select public.barberium_staff_balance_quick(current_date - 30, current_date, null)', 'Sem permissão', 'barbeiro não vê os Saldos da barbearia');
  perform pg_temp.erro(format($q$select public.barberium_staff_save_commission_config(%L, 90, 'monthly', 'gross', '[]')$q$, v_vini), 'somente para ADM', 'barbeiro não muda a própria comissão');
  perform pg_temp.erro(format($q$select public.barberium_staff_set_permissions(%L, '{"cancel_appointment":true}')$q$, v_vini), 'somente para ADM', 'barbeiro não muda as próprias permissões');
  perform pg_temp.erro(format($q$select public.barberium_staff_save_unit(%L, 'X', 'X', 'SP', null, null, true, '{}')$q$, pg_temp.unidade('scalabrini-barbieri')),
                       'somente para ADM', 'barbeiro não muda a unidade (nem a manutenção do site)');
  perform pg_temp.erro('select public.barberium_staff_team()', 'somente para ADM', 'barbeiro não vê a equipe');
  perform pg_temp.erro('select public.barberium_staff_customers('''', false)', 'exclusivo do ADM', 'barbeiro não vê a lista completa de clientes');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.funciona('select public.barberium_staff_finance_report(current_date - 30, current_date, null, ''cash'')', 'ADM vê o relatório financeiro');
  perform pg_temp.funciona('select public.barberium_staff_balance_quick(current_date - 30, current_date, null)', 'ADM vê os Saldos');
  perform pg_temp.funciona('select public.barberium_staff_team()', 'ADM vê a equipe');
end $$;

-- Token do cliente.
do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(5);
  r1 jsonb; r2 jsonb; tok1 text; tok2 text; ap1 uuid; ap2 uuid;
begin
  perform pg_temp.anonimo();
  r1 := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia,
          pg_temp.primeiro_horario('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, v_dia), 'Cliente Portal Um', '(11) 96666-0001', null, null);
  r2 := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia,
          pg_temp.primeiro_horario('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, v_dia), 'Cliente Portal Dois', '(11) 96666-0002', null, null);
  tok1 := r1 ->> 'access_token'; ap1 := (r1 ->> 'appointment_id')::uuid;
  tok2 := r2 ->> 'access_token'; ap2 := (r2 ->> 'appointment_id')::uuid;

  perform pg_temp.ok((public.barberium_get_customer_portal('scalabrini-barbieri', tok1) -> 'appointments')::text like '%' || ap1 || '%',
                     'cliente vê o próprio horário em "Meus horários"');
  perform pg_temp.ok((public.barberium_get_customer_portal('scalabrini-barbieri', tok1) -> 'appointments')::text not like '%' || ap2 || '%',
                     'cliente não vê o horário de outro cliente');
  perform pg_temp.igual(public.barberium_get_customer_portal('barbearia-aurora', tok1) ->> 'customer', null,
                        'token da Scalabrini não abre perfil na Aurora');
  perform pg_temp.erro(format($q$select public.barberium_cancel_appointment('barbearia-aurora', %L, %L)$q$, tok1, ap1), 'INVALID_TOKEN', 'token da Scalabrini não cancela nada pela Aurora');
  perform pg_temp.igual(pg_temp.roda(format($q$select public.barberium_cancel_appointment('scalabrini-barbieri', %L, %L)$q$, tok1, ap2))::text,
                        'false', 'cliente não cancela o horário de outro cliente (a função responde "false")');
  perform pg_temp.sistema();
  perform pg_temp.igual((select status from public.appointments where id = ap2), 'confirmed', 'o horário do outro cliente continua confirmado');
  perform pg_temp.anonimo();
  perform pg_temp.erro(format($q$select public.barberium_cancel_appointment('scalabrini-barbieri', 'token-falso', %L)$q$, ap1), 'INVALID_TOKEN', 'token falso não cancela');
  perform pg_temp.funciona(format($q$select public.barberium_cancel_appointment('scalabrini-barbieri', %L, %L)$q$, tok1, ap1), 'cliente cancela o próprio horário');
end $$;
