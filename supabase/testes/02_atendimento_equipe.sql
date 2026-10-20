-- 02 · Atendimento pela Área da Equipe: criar horário, choque, concluir com pagamento,
-- comissão, cancelar (futuro e concluído, com e sem estorno) e o que cada papel pode fazer.

do $$
declare
  v_b uuid := pg_temp.barbearia('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_jean uuid := pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_c1 uuid := pg_temp.cliente('scalabrini-barbieri', 1);
  v_c2 uuid := pg_temp.cliente('scalabrini-barbieri', 2);
  v_dia date := pg_temp.dia_util(8);
  r jsonb;
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid;
  x record;
begin
  -- Quem é quem.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_me();
  perform pg_temp.igual(r ->> 'role', 'admin', 'ADM da Scalabrini entra como admin');
  perform pg_temp.igual(r ->> 'barbershop_id', v_b::text, 'ADM enxerga a própria barbearia');
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  r := public.barberium_staff_me();
  perform pg_temp.igual(r ->> 'role', 'barber', 'barbeiro entra como barber');
  perform pg_temp.igual(r ->> 'professional_id', v_vini::text, 'barbeiro está ligado ao Vinicius');
  perform pg_temp.anonimo();
  perform pg_temp.erro('select public.barberium_staff_me()', 'Não autenticado|permission denied', 'sem login não há acesso à equipe');

  -- Criar horário pela equipe e choque de horário.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a1 := (public.barberium_staff_create_appointment_v12_21(v_c1, null, null, v_vini, v_corte, '{}', '{}', v_dia, '14:00', false, null, null) ->> 'appointment_id')::uuid;
  perform pg_temp.ok(a1 is not null, 'ADM cria horário para um cliente');
  perform pg_temp.erro(format($q$select public.barberium_staff_create_appointment_v12_21(%L,null,null,%L,%L,'{}','{}',%L,'14:20',false,null,null)$q$, v_c2, v_vini, v_corte, v_dia),
                       'Horário ocupado', 'horário que encosta noutro do mesmo barbeiro é recusado');
  a2 := (public.barberium_staff_create_appointment_v12_21(v_c2, null, null, v_vini, v_corte, '{}', '{}', v_dia, '15:00', false, null, null) ->> 'appointment_id')::uuid;
  a3 := (public.barberium_staff_create_appointment_v12_21(v_c2, null, null, v_vini, v_corte, '{}', '{}', v_dia, '16:00', false, null, null) ->> 'appointment_id')::uuid;
  a4 := (public.barberium_staff_create_appointment_v12_21(v_c2, null, null, v_vini, v_corte, '{}', '{}', v_dia, '17:00', false, null, null) ->> 'appointment_id')::uuid;

  perform pg_temp.funciona(format($q$select public.barberium_staff_create_appointment_v12_21(%L,null,null,%L,%L,'{}','{}',%L,'14:00',false,null,null)$q$, v_c1, v_jean, v_corte, v_dia),
                           'o mesmo cliente pode ter dois horários no mesmo momento, com barbeiros diferentes (a confirmar se é o desejado)');

  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  r := public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 3), null, null, v_jean, v_corte, '{}', '{}', v_dia, '18:00', false, null, null);
  perform pg_temp.sistema();
  perform pg_temp.igual((select professional_id::text from public.appointments where id = (r ->> 'appointment_id')::uuid), v_vini::text,
                        'barbeiro que pede horário para outro barbeiro: o horário vai para ele mesmo, sem aviso');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a5 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 3), null, null, v_jean, v_corte, '{}', '{}', v_dia, '14:00', false, null, null) ->> 'appointment_id')::uuid;
  perform pg_temp.ok(a5 is not null, 'ADM marca horário para o Jean');

  -- Concluir com pagamento: comissão de 50% para o barbeiro.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_complete_appointment(a1, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
  perform pg_temp.igual(r ->> 'paid_cents', '9000', 'ADM conclui o corte recebendo R$ 90 no Pix');
  perform pg_temp.sistema();
  perform pg_temp.igual((select status from public.appointments where id = a1), 'completed', 'horário fica concluído');
  perform pg_temp.igual((select string_agg(method || ':' || amount_cents, ',') from public.appointment_payments where appointment_id = a1), 'pix:9000', 'pagamento gravado');
  perform pg_temp.igual((select string_agg(source_type || ':' || amount_cents || ':' || status, ',') from public.commission_entries where appointment_id = a1),
                        'service:4500:open', 'comissão de 50% (R$ 45) em aberto para o barbeiro');
  perform pg_temp.igual((select professional_id::text from public.commission_entries where appointment_id = a1), v_vini::text, 'comissão é do Vinicius');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_complete_appointment(%L,'[{"method":"pix","amount_cents":9000}]',0,null,null)$q$, a1),
                       'já finalizado', 'não dá para concluir duas vezes');
  perform pg_temp.erro(format($q$select public.barberium_staff_complete_appointment(%L,'[{"method":"pix","amount_cents":5000}]',0,null,null)$q$, a3),
                       'devem somar', 'pagamento menor que o total, sem pendência, é recusado');
  perform pg_temp.erro(format($q$select public.barberium_staff_complete_appointment(%L,'[{"method":"boleto","amount_cents":9000}]',0,null,null)$q$, a3),
                       'Pagamento inválido', 'forma de pagamento desconhecida é recusada');

  -- Barbeiro conclui em dinheiro (com troco) e deixa pendência só com permissão.
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  r := public.barberium_staff_complete_appointment(a2, '[{"method":"cash","amount_cents":9000,"tendered_cents":10000}]', 0, null, null);
  perform pg_temp.igual(r ->> 'paid_cents', '9000', 'barbeiro conclui o próprio atendimento em dinheiro');
  perform pg_temp.erro(format($q$select public.barberium_staff_complete_appointment(%L,'[]',9000,null,null)$q$, a3),
                       'Sem', 'barbeiro sem a permissão "deixar pendente" não pode concluir sem receber');
  perform pg_temp.erro(format($q$select public.barberium_staff_complete_appointment(%L,'[{"method":"pix","amount_cents":9000}]',0,null,null)$q$, a5),
                       'Atendimento inválido', 'barbeiro não conclui atendimento de outro barbeiro');

  -- Cancelar horário futuro.
  r := public.barberium_staff_set_appointment_status(a3, 'cancelled');
  perform pg_temp.sistema();
  select status, cancellation_kind into x from public.appointments where id = a3;
  perform pg_temp.igual(x.status || '/' || x.cancellation_kind, 'cancelled/regular', 'barbeiro com permissão cancela horário futuro (cancelamento normal)');
  update public.professional_permissions set permissions = permissions || '{"cancel_appointment": false}' where professional_id = v_vini;
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_set_appointment_status(%L,'cancelled')$q$, a4),
                       'permiss', 'barbeiro sem a permissão de cancelar não cancela');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_set_appointment_status(a4, 'no_show');
  perform pg_temp.sistema();
  perform pg_temp.igual((select status from public.appointments where id = a4), 'no_show', 'ADM marca "não compareceu"');

  -- Cancelar atendimento concluído (barbeiro volta a ter a permissão de cancelar).
  perform pg_temp.sistema();
  update public.professional_permissions set permissions = permissions || '{"cancel_appointment": true}' where professional_id = v_vini;
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_cancel_completed_appointment_v12_23(%L,'teste','booking_error',false,null)$q$, a1),
                       'Somente o ADM', 'barbeiro não cancela atendimento concluído');
  perform pg_temp.erro(format($q$select public.barberium_staff_set_appointment_status(%L,'cancelled')$q$, a1),
                       'finalizado', 'o cancelamento comum também recusa atendimento concluído');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_cancel_completed_appointment_v12_23(a1, 'lançado errado', 'booking_error', false, null);
  perform pg_temp.igual(r ->> 'voided_service_payment_cents', '9000', 'ADM anula atendimento lançado errado (sem estorno)');
  perform pg_temp.sistema();
  perform pg_temp.igual((select status || '/' || cancellation_kind from public.appointments where id = a1), 'cancelled/booking_error', 'fica cancelado como engano');
  perform pg_temp.igual((select count(*)::text from public.appointment_payments where appointment_id = a1), '0', 'o pagamento lançado errado some');
  perform pg_temp.igual((select count(*)::text from public.commission_entries where appointment_id = a1), '0', 'a comissão em aberto some');
  perform pg_temp.igual((select count(*)::text from public.finance_refunds where appointment_id = a1), '0', 'não gera estorno');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_cancel_completed_appointment_v12_23(a2, 'cliente desistiu', 'regular', true, 'pix');
  perform pg_temp.igual(r ->> 'service_refund_cents', '9000', 'ADM cancela concluído devolvendo R$ 90 no Pix');
  perform pg_temp.sistema();
  perform pg_temp.igual((select string_agg(amount_cents || ':' || refund_method, ',') from public.finance_refunds where appointment_id = a2), '9000:pix', 'estorno registrado');
  perform pg_temp.igual((select count(*)::text from public.appointment_payments where appointment_id = a2), '1', 'o pagamento original continua (houve dinheiro de verdade)');
  perform pg_temp.igual((select string_agg(source_type || ':' || amount_cents, ',' order by amount_cents desc) from public.commission_entries where appointment_id = a2),
                        'service:4500,appointment_cancellation:-4500', 'comissão é estornada com um lançamento negativo');
end $$;
