-- 13 · Relatório financeiro numa função só (etapa 7g, parte 3).
-- Um dia D com: corte + sobrancelha no crédito 3x da maquininha (cancelado com reembolso), corte
-- em R$ 50 no Pix + R$ 40 pagos depois no débito da maquininha, corte em dinheiro, venda de 2
-- pomadas no Pix (reembolsada) e um reembolso antigo sem pagamento (atendimento anulado).
-- Os números são os do Relatório de antes da etapa; a etapa só junta as três camadas.

do $$
declare
  v_u uuid := pg_temp.unidade('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_jean uuid := pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_sobr uuid := pg_temp.servico('scalabrini-barbieri', 'sobrancelha');
  v_d date := (now() at time zone 'America/Sao_Paulo')::date - 9;
  v_prov uuid; v_prod uuid; v_venda uuid; a1 uuid; a2 uuid; a3 uuid; a4 uuid; v_total int;
  r jsonb; c record;
begin
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  v_prov := (public.barberium_staff_save_payment_provider(null, 'Maquininha Relatório', true,
    '[{"method":"credit","installments":3,"percentage":5,"fixed_fee_cents":50},{"method":"debit","installments":1,"percentage":1.5,"fixed_fee_cents":0}]') ->> 'id')::uuid;
  v_prod := (public.barberium_staff_save_product(null, 'Pomada Relatório', 'Finalizadores', 'teste', null, null, null, 1000, 3000, 0, true, 0) ->> 'product_id')::uuid;
  perform public.barberium_staff_adjust_product_stock(v_prod, v_u, 10, 'purchase', 'compra teste', 1000);
  a1 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini, v_corte, array[v_sobr], '{}', pg_temp.dia_util(30), '10:00', false, null, null) ->> 'appointment_id')::uuid;
  a2 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_jean, v_corte, '{}', '{}', pg_temp.dia_util(30), '11:00', false, null, null) ->> 'appointment_id')::uuid;
  a3 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 3), null, null, v_vini, v_corte, '{}', '{}', pg_temp.dia_util(30), '12:00', false, null, null) ->> 'appointment_id')::uuid;
  a4 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 4), null, null, v_jean, v_corte, '{}', '{}', pg_temp.dia_util(30), '13:00', false, null, null) ->> 'appointment_id')::uuid;
  perform pg_temp.sistema();
  v_total := (select total_price_cents from public.appointments where id = a1);
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_complete_appointment(a1, jsonb_build_array(jsonb_build_object('method','credit','amount_cents',v_total,'provider_id',v_prov,'installments',3)), 0, null, null);
  perform public.barberium_staff_complete_appointment(a2, '[{"method":"pix","amount_cents":5000}]', 4000, v_d + 7, 'paga depois');
  perform public.barberium_staff_complete_appointment(a3, '[{"method":"cash","amount_cents":9000,"tendered_cents":9000}]', 0, null, null);
  perform public.barberium_staff_complete_appointment(a4, '[{"method":"cash","amount_cents":9000,"tendered_cents":9000}]', 0, null, null);
  v_venda := (public.barberium_staff_complete_product_sale(v_u, pg_temp.cliente('scalabrini-barbieri', 5), v_jean,
    jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 2)), '[{"method":"pix","amount_cents":6000}]', 0, null, null) ->> 'sale_id')::uuid;
  perform public.barberium_staff_record_receivable_payment(a2, jsonb_build_array(jsonb_build_object('method','debit','amount_cents',4000,'provider_id',v_prov,'installments',1)));
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a1, 'cliente desistiu', 'regular', true, 'pix');
  perform public.barberium_staff_refund_product_sale(v_venda, 'devolveu', 'pix');
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a4, 'lançado errado', 'booking_error', false, null);

  -- Tudo o que esta transação gravou vai para as 15h de D; os atendimentos para a manhã de D.
  perform pg_temp.sistema();
  for c in select table_name t, column_name col from information_schema.columns
           where table_schema = 'public' and data_type like 'timestamp%' and column_name not in ('starts_at', 'ends_at') loop
    execute format('update public.%I set %I = $1 where %I = now()', c.t, c.col, c.col) using (v_d + time '15:00') at time zone 'America/Sao_Paulo';
  end loop;
  update public.appointments set starts_at = (v_d + time '09:00') at time zone 'America/Sao_Paulo', ends_at = (v_d + time '09:40') at time zone 'America/Sao_Paulo'
  where id in (a1, a2, a3, a4);
  -- O débito da pendência foi pago às 18h; o reembolso antigo, sem pagamento, é do atendimento anulado.
  update public.appointment_payments set received_at = (v_d + time '18:00') at time zone 'America/Sao_Paulo' where appointment_id = a2 and method = 'debit';
  insert into public.finance_refunds(barbershop_id, unit_id, appointment_id, amount_cents, reason, refund_method, created_at)
  values (pg_temp.barbearia('scalabrini-barbieri'), v_u, a4, 1500, 'reembolso antigo', 'cash', (v_d + time '19:00') at time zone 'America/Sao_Paulo');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  r := public.barberium_staff_finance_report(v_d, v_d, null, 'cash');
  perform pg_temp.igual((select string_agg(k, ',' order by k) from jsonb_object_keys(r) k),
    'accrual_revenue,by_professional,by_provider,by_unit,cash_movements,cash_sessions,commissions,expenses,meta,overview,payments,receivables,refunds',
    'o Relatório tem as mesmas 13 partes de antes');
  perform pg_temp.igual((select string_agg(format('%s/%s/%s: %s transações, %s reembolsadas, bruto %s, reembolsos %s, taxas %s, líquido %s',
      x->>'provider', x->>'method', x->>'installments', x->>'transactions', x->>'refunded_transactions', x->>'gross_cents', x->>'refunds_cents', x->>'fees_cents', x->>'net_cents'), ' | ' order by o)
      from jsonb_array_elements(r -> 'by_provider') with ordinality t(x, o)),
    'Sem provedor/cash/1: 1 transações, 0 reembolsadas, bruto 9000, reembolsos 0, taxas 0, líquido 9000 | '
    || 'Sem provedor/pix/1: 2 transações, 1 reembolsadas, bruto 11000, reembolsos 6000, taxas 0, líquido 5000 | '
    || 'Maquininha Relatório/debit/1: 1 transações, 0 reembolsadas, bruto 4000, reembolsos 0, taxas 60, líquido 3940 | '
    || 'Maquininha Relatório/credit/3: 1 transações, 1 reembolsadas, bruto 10500, reembolsos 10500, taxas 575, líquido -575 | '
    || 'Sem provedor/other/1: 0 transações, 0 reembolsadas, bruto 0, reembolsos 1500, taxas 0, líquido -1500',
    'por provedor: reembolso rateado no pagamento certo, o reembolso sem pagamento em "Sem provedor", transações e reembolsadas por linha');
  perform pg_temp.igual((select string_agg(format('%s %s %s:%s', x->>'source_type', x->>'method', x->>'amount_cents', x->>'refund_status'), ', ' order by x->>'source_type', x->>'method', (x->>'amount_cents')::int)
      from jsonb_array_elements(r -> 'payments') x),
    'appointment cash 9000:paid, appointment credit 10500:refunded, appointment debit 4000:paid, appointment pix 5000:paid, product pix 6000:refunded',
    'recebimentos de D com a situação do reembolso de cada um');
  perform pg_temp.igual((select string_agg(format('%s %s: %s', x->>'source_type', x->>'description', x->>'amount_cents'), ', ' order by (x->>'amount_cents')::int)
      from jsonb_array_elements(r -> 'refunds') x),
    'appointment Corte: 1500, product Produtos: 6000, appointment Corte + Sobrancelha: 10500',
    'reembolsos de D, com serviço + adicional na descrição');
  perform pg_temp.igual(concat_ws(' / ', r -> 'overview' ->> 'net_received_cents',
      (select sum((x->>'net_cents')::int) from jsonb_array_elements(r -> 'by_provider') x),
      (select sum((x->>'net_cents')::int) from jsonb_array_elements(r -> 'by_unit') x),
      (select sum((x->>'net_cents')::int) from jsonb_array_elements(r -> 'by_professional') x)),
    '15865 / 15865 / 15865 / 15865', 'conferência do caixa: Visão geral = provedores = unidades = profissionais');
  perform pg_temp.igual((select string_agg(format('%s %s', x->>'professional', x->>'net_cents'), ', ' order by x->>'professional') from jsonb_array_elements(r -> 'by_professional') x),
    'Jean Dalarmi 7440, Vinicius Nunes 8425', 'por profissional: Jean com o corte pago em duas vezes, a venda reembolsada e o reembolso antigo; Vinicius com o dinheiro e o crédito reembolsado');

  r := public.barberium_staff_finance_report(v_d, v_d, null, 'accrual');
  perform pg_temp.igual((select string_agg(format('%s %s %s', x->>'source_type', x->>'service', x->>'amount_cents'), ', ' order by (x->>'amount_cents')::int) from jsonb_array_elements(r -> 'accrual_revenue') x),
    'product Produtos 6000, appointment Corte 9000, appointment Corte 9000, appointment Corte + Sobrancelha 10500',
    'competência de D: os atendimentos do dia (o anulado não entra, o cancelado com reembolso entra) e a venda (mesmo reembolsada), com serviço + adicional');

  perform pg_temp.erro($q$select public.barberium_staff_finance_report(current_date, current_date - 1, null, 'cash')$q$, 'Período inválido', 'período ao contrário é recusado');
  perform pg_temp.erro($q$select public.barberium_staff_finance_report(current_date, current_date, null, 'outro')$q$, 'Regime inválido', 'regime desconhecido é recusado');
  perform pg_temp.erro(format($q$select public.barberium_staff_finance_report(current_date, current_date, %L, 'cash')$q$, pg_temp.unidade('barbearia-aurora')), 'Unidade inválida',
                       'unidade de outra barbearia é recusada');
  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.erro($q$select public.barberium_staff_finance_report(current_date, current_date, null, 'cash')$q$, 'restritos ao ADM', 'barbeiro não gera o Relatório');
end $$;

-- O Relatório é uma função só: nenhuma outra função com o nome dele, e ele não chama outra camada.
do $$
begin
  perform pg_temp.sistema();
  perform pg_temp.igual((select string_agg(p.proname, ', ' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'public' and p.proname like 'barberium_staff_finance_report%'),
                        'barberium_staff_finance_report', 'só existe a função do Relatório (sem as camadas v12_8 e v12_8_1)');
  perform pg_temp.ok((select p.prosrc !~ 'finance_report' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = 'barberium_staff_finance_report'),
                     'o Relatório não chama outra função de relatório');
end $$;
