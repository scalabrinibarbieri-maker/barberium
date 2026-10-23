-- 11 · Status do atendimento e dinheiro (etapa 7d, parte 2).
-- 1. Mapa de quem leva um atendimento de um status para outro (ADM, barbeiro com e sem
--    permissão, barbeiro com atendimento de outro): cada combinação, com a mensagem de hoje.
-- 2. O que cada passagem faz com o dinheiro: pagamentos, caixa, reembolsos, pendências,
--    comissões, fichas de pacote, venda de produto e estoque.
-- 3. Só atendimento confirmado pode ser editado (decisão do dono, 22/10).
-- 4. A trava na tabela: passagem fora do mapa é recusada mesmo por dentro do banco.
-- 5. Site do cliente: remarcar e cancelar continuam funcionando com a trava.

-- Foto do dinheiro de um atendimento.
create function pg_temp.foto(p_a uuid) returns text language sql stable security definer as $f$
  select concat_ws(' | ',
    a.status || coalesce('/' || a.cancellation_kind, ''),
    'pag ' || coalesce((select string_agg(method || ':' || amount_cents, ',' order by method, amount_cents) from public.appointment_payments where appointment_id = a.id), '-'),
    'caixa ' || coalesce((select string_agg(cm.movement_type || ':' || cm.amount_cents, ',' order by cm.movement_type, cm.amount_cents) from public.cash_movements cm
                          where (cm.reference_type = 'appointment' and cm.reference_id = a.id)
                             or (cm.reference_type in ('product_sale', 'product_sale_refund') and cm.reference_id in (select id from public.product_sales where appointment_id = a.id))
                             or (cm.reference_id in (select id from public.finance_refunds where appointment_id = a.id))), '-'),
    'estorno ' || coalesce((select string_agg(amount_cents || ':' || coalesce(refund_method, '?') || case when product_sale_id is not null then ':produto' else '' end, ',' order by amount_cents) from public.finance_refunds where appointment_id = a.id), '-'),
    'pendente ' || coalesce((select string_agg(status || ':' || original_due_cents || ':' || paid_cents, ',') from public.appointment_receivables where appointment_id = a.id), '-'),
    'comissão ' || coalesce((select string_agg(source_type || ':' || amount_cents || ':' || status, ',' order by source_type, amount_cents) from public.commission_entries where appointment_id = a.id), '-'),
    'ficha ' || coalesce((select string_agg(u.status || ' ' || b.reserved_credits || 'r/' || b.used_credits || 'u', ',') from public.appointment_membership_uses u left join public.membership_credit_buckets b on b.id = u.bucket_id where u.appointment_id = a.id), '-'),
    'venda ' || coalesce((select string_agg(status || ':' || paid_cents || ':' || pending_cents, ',') from public.product_sales where appointment_id = a.id), '-'))
  from public.appointments a where a.id = p_a $f$;
create function pg_temp.estoque(p_prod uuid, p_unit uuid) returns text language sql stable security definer as $f$
  select coalesce(sum(quantity_delta), 0)::text from public.product_stock_movements where product_id = p_prod and unit_id = p_unit $f$;
-- Tenta um comando e devolve 'ok' ou a mensagem de erro (o efeito fica, se funcionar).
create function pg_temp.tenta(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $f$;
grant execute on all functions in schema pg_temp to public;

-- 1. Mapa de quem pode mudar o quê.
create temp table _mapa(papel text, de text, para text, resultado text);
grant all on _mapa to public;
do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_jean uuid := pg_temp.profissional('scalabrini-barbieri', 'jean-dalarmi');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(40);
  papel text; de text; para text; a uuid; h int := 0; msg text; x record;
begin
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  foreach papel in array array['adm', 'barbeiro-proprio', 'barbeiro-sem-permissao', 'barbeiro-de-outro'] loop
    foreach de in array array['confirmed', 'completed', 'cancelled', 'no_show'] loop
      foreach para in array array['confirmed', 'completed', 'cancelled', 'no_show', 'cancelled_booking_error'] loop
        perform pg_temp.sistema();
        update public.professional_permissions set permissions = permissions || '{"cancel_appointment": true, "mark_no_show": true, "mark_completed": true}' where professional_id = v_vini;
        perform pg_temp.como(pg_temp.adm_scalabrini());
        h := h + 1;
        a := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1 + h % 5), null, null,
                case when papel = 'barbeiro-de-outro' then v_jean else v_vini end, v_corte, '{}', '{}', v_dia + (h / 12),
                time '08:00' + make_interval(mins => 45 * (h % 12)), true, null, null) ->> 'appointment_id')::uuid;
        if de = 'completed' then perform public.barberium_staff_complete_appointment(a, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
        elsif de = 'cancelled' then perform public.barberium_staff_cancel_appointment_v2(a, 'regular', 'preparo');
        elsif de = 'no_show' then perform public.barberium_staff_set_appointment_status(a, 'no_show');
        end if;
        if papel = 'barbeiro-sem-permissao' then
          perform pg_temp.sistema();
          update public.professional_permissions set permissions = permissions || '{"cancel_appointment": false, "mark_no_show": false, "mark_completed": false}' where professional_id = v_vini;
        end if;
        perform pg_temp.como(case when papel = 'adm' then pg_temp.adm_scalabrini() else pg_temp.barbeiro_scalabrini() end);
        msg := pg_temp.tenta(case when para = 'completed'
                 then format($q$select public.barberium_staff_complete_appointment(%L, '[{"method":"pix","amount_cents":9000}]', 0, null, null)$q$, a)
                 else format('select public.barberium_staff_set_appointment_status(%L, %L)', a, para) end);
        perform pg_temp.sistema();
        if msg = 'ok' then msg := 'ok:' || (select status from public.appointments where id = a); end if;
        insert into _mapa values (papel, de, para, msg);
      end loop;
    end loop;
  end loop;
  for x in select * from (values
    ('adm', 'cancelled>cancelled=ok:cancelled; cancelled>cancelled_booking_error=ok:cancelled; cancelled>completed=Atendimento já finalizado; cancelled>confirmed=ok:confirmed; cancelled>no_show=ok:no_show; completed>cancelled=Use Cancelar atendimento concluído para registrar a devolução e reverter produtos e comissões; completed>cancelled_booking_error=Use Cancelar atendimento concluído para registrar a devolução e reverter produtos e comissões; completed>completed=Atendimento já finalizado; completed>confirmed=Use Cancelar atendimento concluído para registrar a devolução e reverter produtos e comissões; completed>no_show=Use Cancelar atendimento concluído para registrar a devolução e reverter produtos e comissões; confirmed>cancelled=ok:cancelled; confirmed>cancelled_booking_error=ok:cancelled; confirmed>completed=ok:completed; confirmed>confirmed=ok:confirmed; confirmed>no_show=ok:no_show; no_show>cancelled=ok:cancelled; no_show>cancelled_booking_error=ok:cancelled; no_show>completed=Atendimento já finalizado; no_show>confirmed=ok:confirmed; no_show>no_show=ok:no_show'),
    ('barbeiro-de-outro', 'cancelled>cancelled=Sem permissão para este agendamento; cancelled>cancelled_booking_error=Sem permissão para este agendamento; cancelled>completed=Atendimento inválido; cancelled>confirmed=Sem permissão para este agendamento; cancelled>no_show=Sem permissão para este agendamento; completed>cancelled=Sem permissão para este agendamento; completed>cancelled_booking_error=Sem permissão para este agendamento; completed>completed=Atendimento inválido; completed>confirmed=Sem permissão para este agendamento; completed>no_show=Sem permissão para este agendamento; confirmed>cancelled=Sem permissão para este agendamento; confirmed>cancelled_booking_error=Sem permissão para este agendamento; confirmed>completed=Atendimento inválido; confirmed>confirmed=Sem permissão para este agendamento; confirmed>no_show=Sem permissão para este agendamento; no_show>cancelled=Sem permissão para este agendamento; no_show>cancelled_booking_error=Sem permissão para este agendamento; no_show>completed=Atendimento inválido; no_show>confirmed=Sem permissão para este agendamento; no_show>no_show=Sem permissão para este agendamento'),
    ('barbeiro-proprio', 'cancelled>cancelled=Este atendimento já foi finalizado; cancelled>cancelled_booking_error=Este atendimento já foi finalizado; cancelled>completed=Atendimento já finalizado; cancelled>confirmed=Somente o ADM pode restaurar para confirmado; cancelled>no_show=Este atendimento já foi finalizado; completed>cancelled=Este atendimento já foi finalizado; completed>cancelled_booking_error=Este atendimento já foi finalizado; completed>completed=Atendimento já finalizado; completed>confirmed=Somente o ADM pode restaurar para confirmado; completed>no_show=Este atendimento já foi finalizado; confirmed>cancelled=ok:cancelled; confirmed>cancelled_booking_error=ok:cancelled; confirmed>completed=ok:completed; confirmed>confirmed=Somente o ADM pode restaurar para confirmado; confirmed>no_show=ok:no_show; no_show>cancelled=Este atendimento já foi finalizado; no_show>cancelled_booking_error=Este atendimento já foi finalizado; no_show>completed=Atendimento já finalizado; no_show>confirmed=Somente o ADM pode restaurar para confirmado; no_show>no_show=Este atendimento já foi finalizado'),
    ('barbeiro-sem-permissao', 'cancelled>cancelled=Sem permissão para cancelar; cancelled>cancelled_booking_error=Sem permissão para cancelar; cancelled>completed=Atendimento já finalizado; cancelled>confirmed=Somente o ADM pode restaurar para confirmado; cancelled>no_show=Sem permissão para marcar falta; completed>cancelled=Sem permissão para cancelar; completed>cancelled_booking_error=Sem permissão para cancelar; completed>completed=Atendimento já finalizado; completed>confirmed=Somente o ADM pode restaurar para confirmado; completed>no_show=Sem permissão para marcar falta; confirmed>cancelled=Sem permissão para cancelar; confirmed>cancelled_booking_error=Sem permissão para cancelar; confirmed>completed=Sem permissão para concluir; confirmed>confirmed=Somente o ADM pode restaurar para confirmado; confirmed>no_show=Sem permissão para marcar falta; no_show>cancelled=Sem permissão para cancelar; no_show>cancelled_booking_error=Sem permissão para cancelar; no_show>completed=Atendimento já finalizado; no_show>confirmed=Somente o ADM pode restaurar para confirmado; no_show>no_show=Sem permissão para marcar falta')) as e(papel, esperado)
  loop
    perform pg_temp.igual((select string_agg(m.de || '>' || m.para || '=' || m.resultado, '; ' order by m.de, m.para) from _mapa m where m.papel = x.papel), x.esperado,
                          'mapa de status: ' || x.papel || ' (20 combinações iguais às de antes)');
  end loop;
end $$;

-- 2. Dinheiro em cada passagem.
do $$
declare
  v_u uuid := pg_temp.unidade('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(20);
  v_prod uuid; v_plan uuid; o jsonb; r jsonb;
  a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid; a6 uuid; a7 uuid;
begin
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  v_prod := (public.barberium_staff_save_product(null, 'Pomada Teste', 'Finalizadores', 'teste', null, null, null, 1000, 3000, 0, true, 0) ->> 'product_id')::uuid;
  perform public.barberium_staff_adjust_product_stock(v_prod, v_u, 10, 'purchase', 'compra teste', 1000);
  perform public.barberium_staff_open_cash(v_u, 0);

  -- Concluir com produto, em dinheiro, e cancelar com reembolso em dinheiro.
  a1 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini, v_corte, '{}', '{}', v_dia, '09:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_set_appointment_products(a1, v_vini, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1)));
  perform public.barberium_staff_complete_appointment(a1, '[{"method":"cash","amount_cents":12000,"tendered_cents":12000}]', 0, null, null);
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a1), 'completed | pag cash:9000 | caixa payment:3000,payment:9000 | estorno - | pendente - | comissão service:4500:open | ficha - | venda completed:3000:0',
                        'concluir corte + pomada em dinheiro: R$ 90 do corte e R$ 30 da pomada no caixa, comissão de R$ 45');
  perform pg_temp.igual(pg_temp.estoque(v_prod, v_u), '9', 'a pomada sai do estoque');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a1, 'cliente desistiu', 'regular', true, 'cash');
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a1), 'cancelled/regular | pag cash:9000 | caixa payment:3000,payment:9000,refund:-9000,refund:-3000 | estorno 3000:cash:produto,9000:cash | pendente - | comissão appointment_cancellation:-4500:open,service:4500:open | ficha - | venda refunded:3000:0',
                        'cancelar concluído com reembolso em dinheiro: devolve R$ 90 + R$ 30 pelo caixa e estorna a comissão');
  perform pg_temp.igual(pg_temp.estoque(v_prod, v_u), '10', 'a pomada volta ao estoque');

  -- Concluir com produto no Pix e anular (engano, sem reembolso).
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a2 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_vini, v_corte, '{}', '{}', v_dia, '10:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_set_appointment_products(a2, v_vini, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 2)));
  perform public.barberium_staff_complete_appointment(a2, '[{"method":"pix","amount_cents":15000}]', 0, null, null);
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a2), 'completed | pag pix:9000 | caixa - | estorno - | pendente - | comissão service:4500:open | ficha - | venda completed:6000:0',
                        'concluir corte + 2 pomadas no Pix (o Pix não passa pelo caixa)');
  perform pg_temp.igual(pg_temp.estoque(v_prod, v_u), '8', 'as 2 pomadas saem do estoque');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a2, 'lançado errado', 'booking_error', false, null);
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a2), 'cancelled/booking_error | pag - | caixa - | estorno - | pendente - | comissão - | ficha - | venda cancelled:0:0',
                        'anular lançamento errado: some o pagamento, a venda e a comissão, sem reembolso');
  perform pg_temp.igual(pg_temp.estoque(v_prod, v_u), '10', 'as pomadas voltam ao estoque');

  -- Concluir com pendência e anular.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a3 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 3), null, null, v_vini, v_corte, '{}', '{}', v_dia, '11:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_complete_appointment(a3, '[{"method":"pix","amount_cents":5000}]', 4000, v_dia + 7, 'paga depois');
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a3), 'completed | pag pix:5000 | caixa - | estorno - | pendente open:4000:0 | comissão service:2500:open | ficha - | venda -',
                        'concluir com R$ 50 pagos e R$ 40 pendentes: comissão só sobre o recebido');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a3, 'lançado errado', 'booking_error', false, null);
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a3), 'cancelled/booking_error | pag - | caixa - | estorno - | pendente cancelled:4000:0 | comissão - | ficha - | venda -',
                        'anular cancela também a pendência');

  -- Pacote com 3 cortes (falta conta como uso).
  perform pg_temp.como(pg_temp.adm_scalabrini());
  v_plan := (public.barberium_staff_save_membership_plan(null, 'Pacote Teste', null, 'package', 15000, 'team', false, true,
    jsonb_build_object('no_show_rule', 'lose', 'combo_credit_mode', 'full_retail', 'unit_scope', 'all', 'benefit_model', 'credits',
                       'allow_manual_extension', true, 'credit_valid_on_appointment_date', true, 'commission', jsonb_build_object('type', 'none'),
                       'credit_validity', 'no_expiry', 'fixed_validity_days', 90, 'refund_mode', 'nonrefundable', 'credits_personal', true),
    jsonb_build_array(jsonb_build_object('service_id', v_corte, 'quantity', 3, 'unlimited', false, 'extra_discount_percent', 0, 'rules', '{}'::jsonb)),
    array[v_u]) ->> 'plan_id')::uuid;
  perform public.barberium_staff_assign_membership(pg_temp.cliente('scalabrini-barbieri', 4), v_plan, v_u, current_date, true, 'pix');
  a4 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 4), null, null, v_vini, v_corte, '{}', '{}', v_dia, '13:00', false, null, null) ->> 'appointment_id')::uuid;
  a5 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 4), null, null, v_vini, v_corte, '{}', '{}', v_dia, '14:00', false, null, null) ->> 'appointment_id')::uuid;
  a6 := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 4), null, null, v_vini, v_corte, '{}', '{}', v_dia, '15:00', false, null, null) ->> 'appointment_id')::uuid;
  foreach a7 in array array[a4, a5, a6] loop
    o := public.barberium_staff_membership_options_for_appointment(a7) -> 0;
    perform public.barberium_staff_reserve_membership_use(a7, (o ->> 'membership_id')::uuid, (o ->> 'benefit_id')::uuid, (o ->> 'bucket_id')::uuid, (o ->> 'target_service_id')::uuid);
  end loop;
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a4), 'confirmed | pag - | caixa - | estorno - | pendente - | comissão - | ficha reserved 3r/0u | venda -',
                        'pacote: 3 horários com a ficha reservada');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_cancel_appointment_v2(a4, 'regular', 'cliente desmarcou');
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a4), 'cancelled/regular | pag - | caixa - | estorno - | pendente - | comissão - | ficha released 2r/0u | venda -',
                        'cancelar devolve a ficha reservada');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_set_appointment_status(a5, 'no_show');
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a5), 'no_show | pag - | caixa - | estorno - | pendente - | comissão - | ficha forfeited 1r/1u | venda -',
                        'falta com a regra "conta como uso": a ficha é gasta');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_set_appointment_status(%L, 'confirmed')$q$, a5), 'histórico de consumo',
                       'falta que gastou ficha não volta para confirmado');
  perform public.barberium_staff_complete_appointment(a6, '[]', 0, null, null);
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a6), 'completed | pag - | caixa - | estorno - | pendente - | comissão - | ficha consumed 0r/2u | venda -',
                        'concluir pelo pacote: nada a receber, a ficha é usada');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform public.barberium_staff_cancel_completed_appointment_v12_23(a6, 'lançado errado', 'booking_error', false, null);
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a6), 'cancelled/booking_error | pag - | caixa - | estorno - | pendente - | comissão - | ficha released 0r/1u | venda -',
                        'anular atendimento do pacote devolve a ficha');

  -- Voltar para confirmado.
  perform pg_temp.como(pg_temp.adm_scalabrini());
  perform pg_temp.erro(format($q$select public.barberium_staff_set_appointment_status(%L, 'confirmed')$q$, a1), 'histórico de consumo ou estorno',
                       'cancelado com reembolso não volta para confirmado');
  perform public.barberium_staff_set_appointment_status(a4, 'confirmed');
  perform public.barberium_staff_set_appointment_status(a2, 'confirmed');
  perform pg_temp.sistema();
  perform pg_temp.igual(pg_temp.foto(a4), 'confirmed | pag - | caixa - | estorno - | pendente - | comissão - | ficha released 0r/1u | venda -',
                        'ADM volta um cancelado para confirmado (a ficha não é reservada de novo)');
  perform pg_temp.igual(pg_temp.foto(a2), 'confirmed | pag - | caixa - | estorno - | pendente - | comissão - | ficha - | venda cancelled:0:0',
                        'ADM volta um lançamento anulado para confirmado (sem pagamento, para lançar certo)');
end $$;

-- 3. Editar só atendimento confirmado.
do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(23);
  st text; a uuid; h int := 0;
begin
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  foreach st in array array['completed', 'cancelled', 'no_show', 'confirmed'] loop
    perform pg_temp.como(pg_temp.adm_scalabrini());
    h := h + 1;
    a := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', h), null, null, v_vini, v_corte, '{}', '{}', v_dia, time '09:00' + make_interval(hours => h), false, null, null) ->> 'appointment_id')::uuid;
    if st = 'completed' then perform public.barberium_staff_complete_appointment(a, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
    elsif st = 'cancelled' then perform public.barberium_staff_cancel_appointment_v2(a, 'regular', 'teste');
    elsif st = 'no_show' then perform public.barberium_staff_set_appointment_status(a, 'no_show');
    end if;
    if st = 'confirmed' then
      perform pg_temp.funciona(format($q$select public.barberium_staff_update_appointment_v12_12(%L, %L, %L, '{}', '{}', %L, %L, 8000, 'ajuste')$q$, a, v_vini, v_corte, v_dia, time '09:00' + make_interval(hours => h)),
                               'atendimento confirmado continua editável (valor de R$ 90 para R$ 80)');
      perform pg_temp.como(pg_temp.barbeiro_scalabrini());
      perform pg_temp.funciona(format($q$select public.barberium_staff_update_appointment_v12_12(%L, %L, %L, '{}', '{}', %L, %L, null, 'nota do barbeiro')$q$, a, v_vini, v_corte, v_dia, time '09:00' + make_interval(hours => h)),
                               'barbeiro continua editando o próprio horário confirmado');
    else
      perform pg_temp.erro(format($q$select public.barberium_staff_update_appointment_v12_12(%L, %L, %L, '{}', '{}', %L, %L, 1000, 'depois')$q$, a, v_vini, v_corte, v_dia, time '09:00' + make_interval(hours => h)),
                           'Somente atendimento confirmado pode ser editado', 'não edita atendimento ' || st || ' (Editar atendimento)');
      perform pg_temp.erro(format($q$select public.barberium_staff_update_appointment(%L, %L, %L, '{}', %L, %L, 1000, 'depois')$q$, a, v_vini, v_corte, v_dia, time '09:00' + make_interval(hours => h)),
                           'Somente atendimento confirmado pode ser editado', 'não edita atendimento ' || st || ' (função antiga de editar)');
    end if;
  end loop;
end $$;

-- 4. Trava na tabela.
do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(26);
  a uuid; c uuid;
begin
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini, v_corte, '{}', '{}', v_dia, '09:00', false, null, null) ->> 'appointment_id')::uuid;
  c := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_vini, v_corte, '{}', '{}', v_dia, '10:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_complete_appointment(a, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
  perform public.barberium_staff_cancel_appointment_v2(c, 'regular', 'teste');
  perform pg_temp.sistema();
  perform pg_temp.erro_cmd(format($q$update public.appointments set status = 'confirmed' where id = %L$q$, a), 'não permitida: completed → confirmed',
                           'nem por dentro do banco um concluído volta para confirmado sem passar pelo cancelamento');
  perform pg_temp.erro_cmd(format($q$update public.appointments set status = 'no_show' where id = %L$q$, a), 'não permitida: completed → no_show',
                           'concluído não vira falta');
  perform pg_temp.erro_cmd(format($q$update public.appointments set status = 'completed' where id = %L$q$, c), 'não permitida: cancelled → completed',
                           'cancelado não vira concluído sem pagamento');
  perform pg_temp.ok(barberium.transicao_de_status_permitida('confirmed', 'completed') and barberium.transicao_de_status_permitida('completed', 'cancelled')
                     and barberium.transicao_de_status_permitida('cancelled', 'confirmed') and barberium.transicao_de_status_permitida('no_show', 'cancelled'),
                     'o mapa tem as passagens de hoje (concluir, cancelar concluído, restaurar, falta → cancelado)');
end $$;

-- 5. Site do cliente: remarcar (cancela e confirma de novo por dentro) e cancelar.
do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(29);
  v_horas jsonb; r jsonb; v_token text; a uuid;
begin
  perform pg_temp.anonimo();
  perform pg_temp.site_da_barbearia('scalabrini-barbieri');
  perform pg_temp.sistema();
  update public.units set settings = coalesce(settings, '{}'::jsonb) || '{"client_maintenance_mode": false, "cancel_before_minutes": 0}' where id = pg_temp.unidade('scalabrini-barbieri');
  perform pg_temp.anonimo();
  v_horas := public.barberium_get_available_slots('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia);
  r := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia, (v_horas ->> 0)::time,
                                           'Cliente Status Teste', '(11) 98888-0711', null, null);
  v_token := r ->> 'access_token';
  a := coalesce((r ->> 'appointment_id')::uuid, (r ->> 'id')::uuid);
  perform pg_temp.funciona(format($q$select public.barberium_reschedule_appointment('scalabrini-barbieri', 'braganca-paulista', %L, %L, %L, %L, '{}', %L, %L)$q$,
                                  v_token, a, v_vini, v_corte, v_dia, (v_horas ->> 1)::time), 'cliente remarca pelo site com a trava ligada');
  perform public.barberium_reschedule_appointment('scalabrini-barbieri', 'braganca-paulista', v_token, a, v_vini, v_corte, '{}', v_dia, (v_horas ->> 1)::time);
  perform pg_temp.sistema();
  perform pg_temp.igual((select status || ' ' || to_char(starts_at at time zone 'America/Sao_Paulo', 'HH24:MI') from public.appointments where id = a),
                        'confirmed ' || to_char((v_horas ->> 1)::time, 'HH24:MI'), 'horário remarcado continua confirmado, no horário novo');
  perform pg_temp.anonimo();
  perform pg_temp.igual(public.barberium_cancel_appointment('scalabrini-barbieri', v_token, a)::text, 'true', 'cliente cancela pelo site');
  perform pg_temp.igual(public.barberium_cancel_appointment('scalabrini-barbieri', v_token, a)::text, 'false', 'cancelar de novo não faz nada');
end $$;
