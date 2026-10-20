-- 06 · Caixa (abrir, receber, suprimento, fechar com diferença) e acerto de comissões
-- (fechar o período, pagar o barbeiro e o que acontece se um atendimento acertado for anulado).

do $$
declare
  v_unit uuid := pg_temp.unidade('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  a1 uuid; a2 uuid; v_acerto uuid;
  r jsonb;
begin
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.erro(format('select public.barberium_staff_open_cash(%L, 10000)', v_unit), 'permiss|ADM|Sem', 'barbeiro sem permissão não abre o caixa');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_open_cash(v_unit, 10000);
  perform pg_temp.igual(r ->> 'ok', 'true', 'ADM abre o caixa com R$ 100 de troco');
  perform pg_temp.erro(format('select public.barberium_staff_open_cash(%L, 10000)', v_unit), '.', 'não abre um segundo caixa com o primeiro aberto');

  a1 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini,
           pg_temp.servico('scalabrini-barbieri', 'corte'), '{}', '{}', pg_temp.dia_util(8), '14:00', false, null, null) ->> 'appointment_id')::uuid;
  a2 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_vini,
           pg_temp.servico('scalabrini-barbieri', 'barba-tradizionale'), '{}', '{}', pg_temp.dia_util(8), '15:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_complete_appointment(a1, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
  perform public.barberium_staff_complete_appointment(a2, '[{"method":"cash","amount_cents":7500,"tendered_cents":10000}]', 0, null, null);
  perform public.barberium_staff_cash_movement(v_unit, 'supply', 5000, 'reforço de troco');

  r := public.barberium_staff_cash_status(v_unit);
  perform pg_temp.igual((select string_agg(m ->> 'type' || ':' || (m ->> 'amount_cents'), ',' order by m ->> 'type') from jsonb_array_elements(r -> 'movements') m),
                        'payment:7500,supply:5000', 'caixa registra só o recebimento em dinheiro (o Pix não passa pelo caixa) e o suprimento');
  perform pg_temp.erro(format($q$select public.barberium_staff_cash_movement(%L, 'retirada', 100, null)$q$, v_unit), 'Movimento inválido', 'tipo de movimento desconhecido é recusado');

  r := public.barberium_staff_close_cash(v_unit, 22000, 'conferido no fim do dia');
  perform pg_temp.igual(r ->> 'expected_cents', '22500', 'esperado no fechamento: R$ 100 + R$ 75 + R$ 50');
  perform pg_temp.igual(r ->> 'difference_cents', '-500', 'contado R$ 220: diferença de -R$ 5 registrada');

  -- Acerto de comissões.
  r := public.barberium_staff_create_commission_settlement(v_vini, v_hoje - 30, v_hoje + 30, 'acerto de teste');
  v_acerto := (r ->> 'settlement_id')::uuid;
  perform pg_temp.igual((r ->> 'entries') || ':' || (r ->> 'total_cents'), '2:8250', 'acerto junta as 2 comissões: R$ 45 + R$ 37,50');
  r := public.barberium_staff_record_commission_settlement_payment(v_acerto, 8250, 'pix', now(), 'pago no Pix');
  perform pg_temp.igual((r ->> 'status') || ':' || (r ->> 'remaining_cents'), 'paid:0', 'pagamento do acerto quita o valor');

  perform pg_temp.sistema();
  perform pg_temp.igual((select string_agg(status, ',' order by amount_cents) from public.commission_entries where professional_id = v_vini),
                        'settled,settled', 'as comissões ficam marcadas como acertadas');

  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  r := public.barberium_staff_my_commissions(v_hoje - 30, v_hoje + 30);
  perform pg_temp.igual(r ->> 'open_cents', '0', 'barbeiro: nada em aberto depois do acerto');

  -- Anular um atendimento que já entrou num acerto pago.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a1, 'lançado errado', 'booking_error', false, null);
  perform pg_temp.sistema();
  perform pg_temp.igual((select string_agg(source_type || ':' || amount_cents || ':' || status, ',' order by amount_cents)
                           from public.commission_entries where professional_id = v_vini),
                        'appointment_cancellation:-4500:open,service:3750:settled,service:4500:settled',
                        'anular atendimento já acertado não apaga a comissão paga: entra um desconto de -R$ 45 para o próximo acerto');
end $$;
