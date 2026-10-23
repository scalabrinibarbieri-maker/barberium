-- 12 · Datas no fuso da barbearia (etapa 7g, parte 1).
-- Cada chamada do site é uma transação nova no horário de Londres (UTC). Aqui, antes de cada
-- função, o fuso volta para UTC (pg_temp.chamada_nova), para a função mostrar sozinha em que
-- dia conta cada registro.
--   A: corte + 2 pomadas, pago às 22:30 de D no Pix (R$ 150; comissão R$ 45);
--   B: corte pago às 00:30 de D+1 em dinheiro (R$ 90; comissão R$ 45).
-- Em UTC, os dois caem em D+1. No dia de Brasília, A é de D e B é de D+1.

create function pg_temp.chamada_nova() returns void language sql as $f$
  select set_config('TimeZone', 'UTC', true);
$f$;
grant execute on all functions in schema pg_temp to public;

do $$
declare
  v_u uuid := pg_temp.unidade('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_d date := (now() at time zone 'America/Sao_Paulo')::date - 9;
  v_prod uuid; a uuid; b uuid; c uuid; v_noite timestamptz; v_madrugada timestamptz;
  r jsonb;
begin
  v_noite := (v_d + time '22:30') at time zone 'America/Sao_Paulo';
  v_madrugada := (v_d + 1 + time '00:30') at time zone 'America/Sao_Paulo';
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  v_prod := (public.barberium_staff_save_product(null, 'Pomada Fuso', 'Finalizadores', 'teste', null, null, null, 1000, 3000, 0, true, 0) ->> 'product_id')::uuid;
  perform public.barberium_staff_adjust_product_stock(v_prod, v_u, 10, 'purchase', 'compra teste', 1000);
  a := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini, v_corte, '{}', '{}', pg_temp.dia_util(30), '10:00', false, null, null) ->> 'appointment_id')::uuid;
  b := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_vini, v_corte, '{}', '{}', pg_temp.dia_util(30), '11:00', false, null, null) ->> 'appointment_id')::uuid;
  c := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 3), null, null, v_vini, v_corte, '{}', '{}', pg_temp.dia_util(30), '12:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_set_appointment_products(a, v_vini, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 2)));
  perform public.barberium_staff_complete_appointment(a, '[{"method":"pix","amount_cents":15000}]', 0, null, null);
  perform public.barberium_staff_complete_appointment(b, '[{"method":"cash","amount_cents":9000,"tendered_cents":9000}]', 0, null, null);
  perform public.barberium_staff_cancel_appointment_v2(c, 'booking_error', 'marcado errado');

  -- A acontece às 22:30 de D, B às 00:30 de D+1, e C é cancelado por engano às 22:30 de D.
  perform pg_temp.sistema();
  update public.appointments set starts_at = (v_d + time '21:00') at time zone 'America/Sao_Paulo', ends_at = (v_d + time '21:40') at time zone 'America/Sao_Paulo' where id = a;
  update public.appointment_payments set received_at = v_noite, created_at = v_noite where appointment_id = a;
  update public.commission_entries set created_at = v_noite where appointment_id = a;
  update public.product_sales set completed_at = v_noite, created_at = v_noite where appointment_id = a;
  update public.product_sale_payments set received_at = v_noite where sale_id in (select id from public.product_sales where appointment_id = a);
  update public.appointments set starts_at = (v_d + 1 + time '00:05') at time zone 'America/Sao_Paulo', ends_at = (v_d + 1 + time '00:45') at time zone 'America/Sao_Paulo' where id = b;
  update public.appointment_payments set received_at = v_madrugada, created_at = v_madrugada where appointment_id = b;
  update public.commission_entries set created_at = v_madrugada where appointment_id = b;
  update public.appointments set cancelled_at = v_noite where id = c;

  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_finance_overview(v_d, v_d, null, 'cash');
  perform pg_temp.igual(r ->> 'service_revenue_cents' || '/' || (r ->> 'product_revenue_cents') || '/' || (r ->> 'commissions_cents'), '9000/6000/4500',
                        'Visão geral (caixa) de D: o corte e as pomadas pagos às 22:30 e a comissão deles');
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_finance_overview(v_d + 1, v_d + 1, null, 'cash');
  perform pg_temp.igual(r ->> 'service_revenue_cents' || '/' || (r ->> 'product_revenue_cents') || '/' || (r ->> 'commissions_cents'), '9000/0/4500',
                        'Visão geral (caixa) de D+1: só o corte das 00:30');
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_finance_report(v_d, v_d, null, 'cash') -> 'overview';
  perform pg_temp.igual(r ->> 'gross_cents', '15000', 'Relatório (caixa) de D: R$ 150, igual à Visão geral (já era no fuso da barbearia)');

  perform pg_temp.chamada_nova();
  r := public.barberium_staff_balance_quick(v_d, v_d, null);
  perform pg_temp.igual(r -> 'categories' -> 'services' ->> 'gross_cents', '9000', 'Saldos de D: o corte das 22:30');
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_product_report(v_d, v_d, null);
  perform pg_temp.igual(r ->> 'units_sold' || '/' || (r ->> 'revenue_cents'), '2/6000', 'relatório de produtos de D: as 2 pomadas das 22:30');
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_product_sales(v_d, v_d, null, null, 50);
  perform pg_temp.igual(jsonb_array_length(coalesce(r -> 'sales', r))::text, '1', 'vendas de produtos de D: a venda das 22:30');
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_commission_preview(v_vini, v_d, v_d);
  perform pg_temp.igual((r ->> 'count') || ':' || (r ->> 'total_cents'), '1:4500', 'prévia do acerto de D: só a comissão das 22:30');
  perform pg_temp.chamada_nova();
  perform pg_temp.igual(public.barberium_staff_booking_error_count(v_d, v_d)::text, '1', 'cancelamento por engano das 22:30 conta em D');

  perform pg_temp.como(pg_temp.barbeiro_scalabrini());
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_my_commissions(v_d, v_d);
  perform pg_temp.igual((select sum((e ->> 'amount_cents')::int)::text from jsonb_array_elements(r -> 'entries') e) || '/' || (r ->> 'booking_error_cancellations'), '4500/1',
                        'Minhas comissões de D: os lançamentos das 22:30 (R$ 45 do corte; a pomada não tem comissão) e o cancelamento por engano das 22:30');
  perform pg_temp.chamada_nova();
  r := public.barberium_staff_my_commissions();
  perform pg_temp.ok(jsonb_array_length(r -> 'entries') >= 2, 'Minhas comissões sem datas (como o site chama): últimos 90 dias até hoje em Brasília');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.chamada_nova();
  begin
    r := public.barberium_staff_create_commission_settlement(v_vini, v_d, v_d, 'acerto de D');
  exception when others then
    r := jsonb_build_object('entries', sqlerrm);
  end;
  perform pg_temp.igual((r ->> 'entries') || ':' || coalesce(r ->> 'total_cents', ''), '1:4500', 'acerto do dia D junta só a comissão das 22:30');
  perform pg_temp.chamada_nova();
  perform pg_temp.funciona('select public.barberium_staff_commission_settlements()', 'lista de acertos sem datas (como o site chama) continua funcionando');
end $$;

-- Datas de "hoje" gravadas pelas funções: no dia de Brasília.
do $$
declare
  v_u uuid := pg_temp.unidade('scalabrini-barbieri');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_plan uuid; v_mem uuid; r jsonb;
begin
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  v_plan := (public.barberium_staff_save_membership_plan(null, 'Pacote Fuso', null, 'package', 15000, 'team', false, true,
    jsonb_build_object('no_show_rule','keep','combo_credit_mode','full_retail','unit_scope','all','benefit_model','credits','allow_manual_extension',true,'credit_valid_on_appointment_date',true,'commission',jsonb_build_object('type','none'),'credit_validity','no_expiry','fixed_validity_days',90,'refund_mode','nonrefundable','credits_personal',true),
    jsonb_build_array(jsonb_build_object('service_id', v_corte, 'quantity', 2, 'unlimited', false, 'extra_discount_percent', 0, 'rules', '{}'::jsonb)), array[v_u]) ->> 'plan_id')::uuid;
  v_mem := (public.barberium_staff_assign_membership(pg_temp.cliente('scalabrini-barbieri', 5), v_plan, v_u, v_hoje, true, 'pix') ->> 'membership_id')::uuid;
  perform pg_temp.chamada_nova();
  perform public.barberium_staff_cancel_package(v_mem, 'teste do fuso', null);
  perform pg_temp.igual(current_setting('TimeZone'), 'America/Sao_Paulo', 'cancelar pacote trabalha no fuso da barbearia');
  perform pg_temp.sistema();
  perform pg_temp.igual((select cancel_effective_on::text from public.customer_memberships where id = v_mem), v_hoje::text, 'pacote cancelado vale a partir de hoje em Brasília');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.chamada_nova();
  perform public.barberium_staff_create_expense(v_u, null, 'Despesa do fuso', 1000, null, 'paid', 'pix', false, null);
  perform pg_temp.sistema();
  perform pg_temp.igual((select due_date::text from public.expenses where description = 'Despesa do fuso'), v_hoje::text, 'despesa sem vencimento vence hoje em Brasília');

  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.chamada_nova();
  perform public.barberium_staff_customer_memberships(pg_temp.cliente('scalabrini-barbieri', 5));
  perform pg_temp.igual(current_setting('TimeZone'), 'America/Sao_Paulo', 'atualizar a situação dos planos do cliente (pausa e cancelamento programado) usa o fuso da barbearia');
end $$;

-- Toda função que usa a data de hoje no corpo trabalha no fuso da barbearia (a liberação de
-- créditos só é chamada pela confirmação de pagamento, que já está no fuso).
do $$
declare v_lista text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_lista
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'barberium') and p.prokind = 'f'
    and p.prosrc ~* '\mcurrent_date\M'
    and p.prosrc !~* 'usar_fuso_da_barbearia|set_config\(''TimeZone'''
    and p.proname <> 'release_membership_credits';
  perform pg_temp.igual(coalesce(v_lista, ''), '', 'nenhuma função usa a data de Londres no corpo');
end $$;
