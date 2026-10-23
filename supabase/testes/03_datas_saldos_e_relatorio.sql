-- 03 · Datas perto da meia-noite de Brasília e Saldos × Relatório financeiro.
-- Dois atendimentos concluídos e depois "movidos" para um dia D no passado:
--   A: começa 23:00 de D e é pago às 23:59 de D (Pix, R$ 90; comissão R$ 45)
--   B: começa 00:01 de D+1 e é pago às 00:01 de D+1 (dinheiro, R$ 75; comissão R$ 37,50)
-- Em UTC, os dois caem no mesmo dia (D+1). Cada tela precisa separar pelo fuso da barbearia.

do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_d date := (now() at time zone 'America/Sao_Paulo')::date - 7;
  a uuid; b uuid;
  r jsonb;
begin
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini,
          pg_temp.servico('scalabrini-barbieri', 'corte'), '{}', '{}', pg_temp.dia_util(8), '14:00', false, null, null) ->> 'appointment_id')::uuid;
  b := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_vini,
          pg_temp.servico('scalabrini-barbieri', 'barba-tradizionale'), '{}', '{}', pg_temp.dia_util(8), '15:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_complete_appointment(a, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
  perform public.barberium_staff_complete_appointment(b, '[{"method":"cash","amount_cents":7500}]', 0, null, null);

  perform pg_temp.sistema();
  update public.appointments set starts_at = (v_d + time '23:00') at time zone 'America/Sao_Paulo',
                                 ends_at = (v_d + time '23:40') at time zone 'America/Sao_Paulo' where id = a;
  update public.appointment_payments set received_at = (v_d + time '23:59') at time zone 'America/Sao_Paulo' where appointment_id = a;
  update public.commission_entries set created_at = (v_d + time '23:59') at time zone 'America/Sao_Paulo' where appointment_id = a;
  update public.appointments set starts_at = (v_d + 1 + time '00:01') at time zone 'America/Sao_Paulo',
                                 ends_at = (v_d + 1 + time '00:46') at time zone 'America/Sao_Paulo' where id = b;
  update public.appointment_payments set received_at = (v_d + 1 + time '00:01') at time zone 'America/Sao_Paulo' where appointment_id = b;
  update public.commission_entries set created_at = (v_d + 1 + time '00:01') at time zone 'America/Sao_Paulo' where appointment_id = b;

  perform pg_temp.como(pg_temp.adm_scalabrini());
  -- Relatório financeiro (caixa e competência).
  r := public.barberium_staff_finance_report(v_d, v_d, null, 'cash') -> 'overview';
  perform pg_temp.igual(r ->> 'gross_cents', '9000', 'relatório (caixa) do dia D: só o pagamento das 23:59');
  perform pg_temp.igual(r ->> 'commissions_cents', '4500', 'relatório do dia D: comissão de D');
  r := public.barberium_staff_finance_report(v_d + 1, v_d + 1, null, 'cash') -> 'overview';
  perform pg_temp.igual(r ->> 'gross_cents', '7500', 'relatório (caixa) do dia D+1: só o pagamento das 00:01');
  perform pg_temp.igual(r ->> 'commissions_cents', '3750', 'relatório do dia D+1: comissão de D+1');
  r := public.barberium_staff_finance_report(v_d, v_d, null, 'accrual') -> 'overview';
  perform pg_temp.igual(r ->> 'gross_cents', '9000', 'relatório (competência) do dia D: atendimento das 23:00');

  -- Saldos (tela de saldos rápidos) batem com o relatório.
  r := public.barberium_staff_balance_quick(v_d, v_d, null);
  perform pg_temp.igual(r -> 'categories' -> 'services' ->> 'gross_cents', '9000', 'Saldos do dia D: R$ 90, igual ao relatório');
  perform pg_temp.igual(r ->> 'commissions_cents', '4500', 'Saldos do dia D: comissão igual ao relatório');
  perform pg_temp.igual(r ->> 'timezone', 'America/Sao_Paulo', 'Saldos usam o fuso da barbearia');
  r := public.barberium_staff_balance_quick(v_d + 1, v_d + 1, null);
  perform pg_temp.igual(r -> 'categories' -> 'services' ->> 'gross_cents', '7500', 'Saldos do dia D+1: R$ 75, igual ao relatório');
  r := public.barberium_staff_balance_quick(v_d, v_d + 1, null);
  perform pg_temp.igual(r -> 'categories' -> 'services' ->> 'gross_cents', '16500', 'Saldos de D a D+1 somam os dois');

  -- Desempenho e agenda.
  r := public.barberium_staff_performance(v_d, v_d) -> 'summary';
  perform pg_temp.igual(r ->> 'completed', '1', 'Desempenho do dia D: 1 atendimento concluído');
  perform pg_temp.igual(r ->> 'realized_revenue_cents', '9000', 'Desempenho do dia D: R$ 90 realizados');
  r := public.barberium_staff_dashboard(v_d, null);
  perform pg_temp.ok(r::text like '%' || a || '%' and r::text not like '%' || b || '%', 'agenda do dia D mostra o atendimento das 23:00 e não o das 00:01');

  -- Visão do barbeiro.
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  r := public.barberium_staff_performance_v12_33(v_d, v_d) -> 'summary';
  perform pg_temp.igual(r ->> 'commission_cents', '4500', 'barbeiro vê a comissão do dia D no Desempenho');
  r := public.barberium_staff_my_commissions(v_d, v_d);
  perform pg_temp.igual(jsonb_array_length(r -> 'entries')::text, '1', 'Minhas comissões do dia D: só o lançamento de D');
  perform pg_temp.igual(r ->> 'open_cents', '8250', 'Minhas comissões: "em aberto" soma tudo que está aberto, de qualquer dia (R$ 82,50)');
end $$;

-- A conferência das funções que usavam a data de Londres (current_date em UTC) mudou para o
-- arquivo 12 (etapa 7g): agora todas trabalham no fuso da barbearia.
