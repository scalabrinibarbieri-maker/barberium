-- 04 · Isolamento entre barbearias. O ADM da Barbearia Aurora chama TODAS as funções da equipe
-- que recebem algum ID, passando IDs da Scalabrini. Para cada uma:
--   BLOQUEADA  a função deu erro (não necessariamente por causa da barbearia: o detalhe mostra a mensagem);
--   SEM EFEITO funcionou, não mudou nada da Scalabrini e não devolveu dado dela;
--   VAZOU      mudou dado da Scalabrini ou devolveu dado dela. É falha de segurança.
--   MISTUROU   gravou dado da Aurora apontando para um ID da Scalabrini (ex.: meta da Aurora
--              na unidade da Scalabrini). Não expõe nada, mas mistura as barbearias.
-- Hoje só existe uma barbearia de verdade, então um vazamento só seria explorável por quem fosse
-- ADM de outra. Mesmo assim, precisa estar fechado antes da segunda barbearia (etapa 6).
-- Vazamentos já conhecidos ficam na lista "conhecidos" abaixo: passam como "vai mudar" e falham
-- quando forem corrigidos (para a lista ser atualizada) ou se aparecer um novo.

-- Objetos da Scalabrini usados como alvo.
do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(9);
  v_unit uuid := pg_temp.unidade('scalabrini-barbieri');
  r jsonb; a_ok uuid; a_done uuid;
begin
  perform pg_temp.como(pg_temp.adm_scalabrini());
  a_ok := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 1), null, null, v_vini, v_corte, '{}', '{}', v_dia, '10:00', false, null, null) ->> 'appointment_id')::uuid;
  a_done := (public.barberium_staff_create_appointment_v12_21(pg_temp.cliente('scalabrini-barbieri', 2), null, null, v_vini, v_corte, '{}', '{}', v_dia, '11:00', false, null, null) ->> 'appointment_id')::uuid;
  perform public.barberium_staff_complete_appointment(a_done, '[{"method":"pix","amount_cents":9000}]', 0, null, null);
  perform public.barberium_staff_create_block(v_vini, v_dia, '15:00', '16:00', 'bloqueio de teste', false, null);
  perform public.barberium_staff_save_special_hour(null, v_unit, null, v_dia + 14, '10:00', '14:00', false, 'teste');
  perform public.barberium_staff_save_expense_category(null, 'Categoria Teste', true);
  perform public.barberium_staff_save_payment_provider(null, 'Maquininha Teste', true, '[]');
  perform public.barberium_staff_save_product(null, 'Pomada Teste', 'Finalizadores', 'teste', null, null, null, 1000, 3000, 0, true, 0);
  -- O período vai até o dia do atendimento finalizado acima (daqui a alguns dias), senão a comissão dele fica de fora.
  perform public.barberium_staff_create_commission_settlement(v_vini, (now() at time zone 'America/Sao_Paulo')::date - 60, v_dia + 1, 'teste');
  perform pg_temp.sistema();
  create temp table _alvo(tipo text primary key, id uuid);
  grant all on _alvo to public;
  insert into _alvo values
    ('appointment', a_ok), ('appointment_done', a_done),
    ('customer', pg_temp.cliente('scalabrini-barbieri', 3)), ('professional', v_vini), ('unit', v_unit),
    ('service', v_corte), ('addon', pg_temp.servico('scalabrini-barbieri', 'sobrancelha'));
  insert into _alvo select 'block', id from public.blocked_times where professional_id = v_vini limit 1;
  insert into _alvo select 'special_hour', id from public.special_business_hours where unit_id = v_unit limit 1;
  insert into _alvo select 'category', id from public.expense_categories where barbershop_id = pg_temp.barbearia('scalabrini-barbieri') limit 1;
  insert into _alvo select 'provider', id from public.payment_providers where barbershop_id = pg_temp.barbearia('scalabrini-barbieri') limit 1;
  insert into _alvo select 'product', id from public.products where barbershop_id = pg_temp.barbearia('scalabrini-barbieri') limit 1;
  insert into _alvo select 'settlement', id from public.commission_settlements where barbershop_id = pg_temp.barbearia('scalabrini-barbieri') limit 1;
end $$;

-- "Foto" de tudo que não é da Aurora: tabela -> md5 das linhas.
create function pg_temp.foto() returns jsonb language plpgsql security definer as $$
declare t record; h text; v jsonb := '{}';
begin
  for t in
    select c.relname,
           exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'barbershop_id' and not a.attisdropped) as tem_b
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' order by 1
  loop
    execute format('select md5(coalesce(string_agg(x::text, ''|'' order by x::text), '''')) from public.%I x %s', t.relname,
                   case when t.tem_b then 'where x.barbershop_id is distinct from ''a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46''' else '' end)
      into h;
    v := v || jsonb_build_object(t.relname, jsonb_build_object('h', h, 'b', t.tem_b));
  end loop;
  return v;
end $$;

-- Marcas da Scalabrini que não podem aparecer no que a Aurora recebe.
create function pg_temp.marcas_scalabrini() returns text[] language sql stable security definer as $$
  select array_agg(m) from (
    select id::text m from public.barbershops where slug = 'scalabrini-barbieri'
    union all select id::text from public.units where barbershop_id = pg_temp.barbearia('scalabrini-barbieri')
    union all select id::text from public.professionals where barbershop_id = pg_temp.barbearia('scalabrini-barbieri')
    union all select id::text from public.customers where barbershop_id = pg_temp.barbearia('scalabrini-barbieri')
    union all select id::text from public.appointments where barbershop_id = pg_temp.barbearia('scalabrini-barbieri')
    union all select 'Vinicius Nunes' union all select 'Jean Dalarmi' union all select 'Bragança'
  ) z $$;

-- Tabelas onde alguma linha da Aurora cita um ID da Scalabrini.
create function pg_temp.misturas() returns text language plpgsql security definer as $$
declare t record; v_ids text[]; v_achou boolean; v_lista text;
begin
  select array_agg(m) into v_ids from unnest(pg_temp.marcas_scalabrini()) m where m ~ '^[0-9a-f]{8}-';
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'barbershop_id' and not a.attisdropped)
    order by 1
  loop
    execute format('select exists (select 1 from public.%I x where x.barbershop_id = ''a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46'' and x::text ~ %L)',
                   t.relname, array_to_string(v_ids, '|')) into v_achou;
    if v_achou then v_lista := concat_ws(',', v_lista, t.relname); end if;
  end loop;
  return v_lista;
end $$;

-- Valor de teste para cada parâmetro, pelo nome e pelo tipo.
create function pg_temp.valor(p_funcao text, p_param text, p_tipo text) returns text language plpgsql stable security definer as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  alvo text;
  function_done boolean := p_funcao ~ 'cancel_completed|receivable|finance|appointment_products|set_appointment_products|checkout_membership';
begin
  if p_tipo = 'uuid' then
    alvo := case
      when p_param in ('p_appointment_id', 'p_exclude_appointment_id') then case when function_done then 'appointment_done' else 'appointment' end
      when p_param in ('p_customer_id') then 'customer'
      when p_param in ('p_professional_id', 'p_seller_professional_id') then 'professional'
      when p_param in ('p_unit_id', 'p_preferred_unit_id') then 'unit'
      when p_param in ('p_service_id', 'p_target_service_id') then 'service'
      when p_param = 'p_block_id' then 'block'
      when p_param = 'p_product_id' then 'product'
      when p_param = 'p_settlement_id' then 'settlement'
      when p_param = 'p_category_id' then 'category'
      when p_param = 'p_provider_id' then 'provider'
      when p_param = 'p_id' and p_funcao ~ 'special_hour' then 'special_hour'
      when p_param = 'p_id' and p_funcao ~ 'expense_category' then 'category'
      else null end;
    return coalesce(quote_literal((select id from _alvo where tipo = alvo)::text), quote_literal(gen_random_uuid()::text)) || '::uuid';
  elsif p_tipo = 'uuid[]' then
    return case p_param
      when 'p_addon_service_ids' then format('array[%L]::uuid[]', (select id from _alvo where tipo = 'addon'))
      when 'p_customer_ids' then format('array[%L]::uuid[]', (select id from _alvo where tipo = 'customer'))
      when 'p_unit_ids' then format('array[%L]::uuid[]', (select id from _alvo where tipo = 'unit'))
      else '''{}''::uuid[]' end;
  elsif p_tipo = 'text' then
    return quote_literal(case
      when p_param = 'p_status' then 'cancelled'
      when p_param = 'p_cancellation_kind' then 'regular'
      when p_param in ('p_refund_method', 'p_payment_method', 'p_method') then 'pix'
      when p_param in ('p_basis', 'p_commission_basis', 'p_dre_default_basis') then 'cash'
      when p_param = 'p_kind' and p_funcao ~ 'block' then 'single'
      when p_param = 'p_kind' then 'service'
      when p_param = 'p_type' then 'supply'
      when p_param = 'p_movement_type' then 'adjustment'
      when p_param = 'p_action' and p_funcao ~ 'whatsapp' then 'request'
      when p_param = 'p_action' then 'status'
      when p_param = 'p_action_type' then 'pause'
      when p_param = 'p_audience' then 'all'
      when p_param = 'p_message_mode' then 'manual'
      when p_param = 'p_settlement_cycle' then 'monthly'
      when p_param = 'p_plan_type' then 'package'
      when p_param = 'p_acquisition_mode' then 'both'
      when p_param in ('p_cycle_mode', 'p_first_cycle_mode', 'p_late_payment_cycle_mode') then 'fixed_day'
      when p_param = 'p_timezone' then 'America/Sao_Paulo'
      when p_param = 'p_phone' then '(11) 97777-0000'
      when p_param = 'p_whatsapp' then '+5511977770000'
      when p_param in ('p_full_name', 'p_name', 'p_title') then 'Teste Isolamento'
      when p_param = 'p_query' then ''
      when p_param = 'p_image_path' then 'barberium.svg'
      when p_param = 'p_state' then 'SP'
      else 'teste de isolamento' end);
  elsif p_tipo in ('integer', 'bigint', 'smallint') then
    return case
      when p_param ~ 'percent' then '10'
      when p_param in ('p_months', 'p_days', 'p_requested_days', 'p_delta', 'p_quantity_delta', 'p_fixed_day', 'p_grace_days', 'p_sort_order') then '1'
      when p_param = 'p_limit' then '10'
      when p_param = 'p_slot_minutes' then '10'
      when p_param = 'p_duration_min' then '30'
      when p_param in ('p_pending_cents', 'p_counted_cents', 'p_opening_balance_cents', 'p_min_stock', 'p_manual_refund_cents') then '0'
      else '100' end;
  elsif p_tipo = 'numeric' then return '10';
  elsif p_tipo = 'boolean' then
    return case when p_param in ('p_approve', 'p_is_active', 'p_consume', 'p_mark_paid') then 'true' else 'false' end;
  elsif p_tipo = 'date' then
    if p_param in ('p_birthday', 'p_ends_on') then return 'null::date'; end if;
    return quote_literal(case
      when p_param in ('p_start', 'p_period_start', 'p_start_date') then hoje - 60
      when p_param in ('p_end', 'p_period_end', 'p_end_date') then hoje + 60
      when p_param = 'p_month' then date_trunc('month', hoje)::date
      else pg_temp.dia_util(9) end) || '::date';
  elsif p_tipo like 'timestamp%' then
    return quote_literal((now() + interval '1 day')::text) || '::timestamptz';
  elsif p_tipo like 'time%' then
    return quote_literal(case when p_param ~ 'end|close' then '11:00' else '10:00' end) || '::time';
  elsif p_tipo = 'jsonb' then
    return quote_literal(case
      when p_param = 'p_payments' then '[{"method":"pix","amount_cents":100}]'
      when p_param in ('p_items', 'p_hours', 'p_service_rules', 'p_rows', 'p_fee_rules', 'p_overrides', 'p_benefits', 'p_professional_links') then '[]'
      when p_param = 'p_permissions' then '{"cancel_appointment": true}'
      else '{}' end) || '::jsonb';
  end if;
  return 'null';
end $$;

-- Varredura.
do $$
declare
  f record; v_sql text; v_args text; v_res text; v_msg text; v_estado text;
  antes jsonb; depois jsonb; v_mudou text; v_mudou_b boolean; v_marca text; v_situacao text; v_mistura text; v_mistura_antes text;
  marcas text[] := pg_temp.marcas_scalabrini();
  -- Vazamentos conhecidos. A etapa 6 corrigiu o único que existia (a meta financeira gravada na
  -- unidade de outra barbearia); um novo que aparecer faz o teste falhar.
  conhecidos text[] := array[]::text[];
  n_bloq int := 0; n_sem int := 0; n_vaz int := 0; n_mis int := 0;
begin
  antes := pg_temp.foto();
  v_mistura_antes := pg_temp.misturas();
  perform pg_temp.ok(v_mistura_antes is null, 'antes da varredura nenhuma linha da Aurora cita a Scalabrini', v_mistura_antes);
  for f in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as ident, p.proargnames, p.proargtypes::oid[] as tipos
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'barberium_staff%'
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
      and pg_get_function_identity_arguments(p.oid) ~ 'uuid'
    order by p.proname, ident
  loop
    select string_agg(format('%s => %s', nome, pg_temp.valor(f.proname, nome, format_type(tipo, null))), ', ' order by i)
      into v_args
      from unnest(f.proargnames[1:array_length(f.tipos, 1)], f.tipos) with ordinality as x(nome, tipo, i);
    v_sql := format('select (public.%I(%s))::text', f.proname, v_args);
    v_res := null; v_msg := null; v_estado := null; v_mudou := null; v_mudou_b := false; v_marca := null; v_mistura := null;
    begin
      perform pg_temp.como(pg_temp.adm_aurora());
      execute v_sql into v_res;
      perform pg_temp.sistema();
      depois := pg_temp.foto();
      select string_agg(k, ','), bool_or((depois -> k ->> 'b')::boolean) into v_mudou, v_mudou_b
        from jsonb_object_keys(depois) k where depois -> k ->> 'h' is distinct from antes -> k ->> 'h';
      select m into v_marca from unnest(marcas) m where position(m in coalesce(v_res, '')) > 0 limit 1;
      v_mistura := pg_temp.misturas();
      raise exception using errcode = 'P0999', message = '__funcionou__';
    exception when others then
      v_estado := sqlstate; v_msg := sqlerrm;
    end;
    perform pg_temp.sistema();
    if v_estado <> 'P0999' then
      v_situacao := 'BLOQUEADA'; n_bloq := n_bloq + 1;
      perform pg_temp.ok(true, format('%s(%s): bloqueada', f.proname, f.ident), v_msg);
    elsif v_mudou_b or v_marca is not null then
      v_situacao := 'VAZOU'; n_vaz := n_vaz + 1;
      if f.proname || '(' || f.ident || ')' = any(conhecidos) then
        perform pg_temp.vai_mudar(true, format('%s(%s): VAZOU (conhecido)', f.proname, f.ident),
                                  coalesce('mudou: ' || v_mudou, '') || coalesce(' devolveu: ' || v_marca, ''));
      else
        perform pg_temp.ok(false, format('%s(%s): VAZOU', f.proname, f.ident),
                           coalesce('mudou: ' || v_mudou, '') || coalesce(' devolveu: ' || v_marca, ''));
      end if;
    elsif v_mistura is not null then
      v_situacao := 'MISTUROU'; n_mis := n_mis + 1;
      if f.proname || '(' || f.ident || ')' = any(conhecidos) then
        perform pg_temp.vai_mudar(true, format('%s(%s): MISTUROU (conhecido)', f.proname, f.ident), 'linhas da Aurora citando a Scalabrini em: ' || v_mistura);
      else
        perform pg_temp.ok(false, format('%s(%s): MISTUROU', f.proname, f.ident), 'linhas da Aurora citando a Scalabrini em: ' || v_mistura);
      end if;
    else
      v_situacao := 'SEM EFEITO'; n_sem := n_sem + 1;
      perform pg_temp.ok(true, format('%s(%s): funcionou sem tocar na Scalabrini', f.proname, f.ident),
                         coalesce('mudou só tabelas sem barbearia: ' || v_mudou, left(coalesce(v_res, ''), 120)));
    end if;
  end loop;
  perform pg_temp.ok(true, format('resumo: %s bloqueadas, %s sem efeito, %s vazaram, %s misturaram', n_bloq, n_sem, n_vaz, n_mis));
end $$;
