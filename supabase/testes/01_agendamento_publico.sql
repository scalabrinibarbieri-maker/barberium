-- 01 · Agendamento pelo site do cliente (anônimo): horários livres, choque de horário,
-- validações e o comportamento da etapa 0 para telefone já cadastrado.

do $$
declare
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_sobr uuid := pg_temp.servico('scalabrini-barbieri', 'sobrancelha');
  v_dia date := pg_temp.dia_util(5);
  v_domingo date;
  v_hora time;
  v_slots jsonb;
  r jsonb;
  a record;
begin
  perform pg_temp.anonimo();

  v_slots := public.barberium_get_available_slots('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia);
  perform pg_temp.ok(jsonb_array_length(v_slots) > 0, 'há horários livres num dia útil', v_dia::text);
  v_hora := (v_slots ->> 0)::time;

  select d::date into v_domingo from generate_series(v_dia, v_dia + 7, interval '1 day') d where extract(dow from d) = 0 limit 1;
  v_slots := public.barberium_get_available_slots('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_domingo);
  perform pg_temp.igual(jsonb_array_length(v_slots)::text, '0', 'domingo (fechado) não tem horários');

  -- Agendamento de cliente novo.
  r := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia, v_hora,
                                           'Cliente Novo Teste', '(11) 98888-0001', null, null);
  perform pg_temp.ok(r ? 'appointment_id' or r ? 'id', 'cliente novo consegue agendar', r::text);
  perform pg_temp.ok(nullif(r ->> 'access_token', '') is not null, 'cliente novo recebe o token do perfil');

  perform pg_temp.sistema();
  select ap.*, c.full_name, c.phone_e164 into a
    from public.appointments ap join public.customers c on c.id = ap.customer_id
   where ap.barbershop_id = pg_temp.barbearia('scalabrini-barbieri') and c.phone_e164 = '+5511988880001';
  perform pg_temp.igual(a.status, 'confirmed', 'horário nasce confirmado');
  perform pg_temp.igual(a.total_price_cents::text, '9000', 'preço do corte (R$ 90,00) gravado no horário');
  perform pg_temp.igual(extract(epoch from (a.ends_at - a.starts_at))::int::text, (40 * 60)::text, 'duração do corte: 40 min');
  perform pg_temp.igual(to_char(a.starts_at at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI'),
                        to_char(v_dia + v_hora, 'YYYY-MM-DD HH24:MI'), 'horário gravado no fuso de Brasília');
  perform pg_temp.igual(a.full_name, 'Cliente Novo Teste', 'cadastro criado com o nome digitado');

  -- Choque de horário: o mesmo horário não aparece mais e não pode ser agendado.
  perform pg_temp.anonimo();
  v_slots := public.barberium_get_available_slots('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia);
  perform pg_temp.ok(not (v_slots ? to_char(v_hora, 'HH24:MI')), 'horário ocupado some da lista');
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,%L,'Outro Cliente','(11) 98888-0002',null,null)$q$,
                              v_vini, v_corte, v_dia, v_hora),
                       'SLOT_UNAVAILABLE', 'segundo agendamento no mesmo horário é recusado');

  -- Validações.
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,'03:00','Cliente Madrugada','(11) 98888-0003',null,null)$q$,
                              v_vini, v_corte, v_dia),
                       'SLOT_UNAVAILABLE', 'horário fora do expediente é recusado');
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,'10:00','Cliente Passado','(11) 98888-0004',null,null)$q$,
                              v_vini, v_corte, (now() at time zone 'America/Sao_Paulo')::date - 1),
                       'PAST_SLOT', 'horário no passado é recusado');
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,%L,'Cliente Fone','123',null,null)$q$,
                              v_vini, v_corte, v_dia, v_hora),
                       'INVALID_PHONE', 'telefone inválido é recusado');
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('scalabrini-barbieri','braganca-paulista',%L,%L,'{}',%L,%L,'Ab','(11) 98888-0005',null,null)$q$,
                              v_vini, v_corte, v_dia, v_hora),
                       'INVALID_NAME', 'nome com menos de 3 letras é recusado');
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('barbearia-que-nao-existe','braganca-paulista',%L,%L,'{}',%L,%L,'Cliente X','(11) 98888-0006',null,null)$q$,
                              v_vini, v_corte, v_dia, v_hora),
                       'BARBERSHOP_NOT_FOUND', 'barbearia inexistente é recusada');
  perform pg_temp.erro(format($q$select public.barberium_create_appointment('barbearia-aurora','centro',%L,%L,'{}',%L,'10:00','Cliente Cruzado','(11) 98888-0007',null,null)$q$,
                              v_vini, v_corte, v_dia),
                       'NOT_FOUND|NOT_LINKED|UNAVAILABLE', 'profissional e serviço da Scalabrini não servem para agendar na Aurora');

  -- Adicional: soma preço e duração.
  v_slots := public.barberium_get_available_slots('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, array[v_sobr], v_dia);
  v_hora := (v_slots ->> 0)::time;
  r := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, array[v_sobr], v_dia, v_hora,
                                           'Cliente Adicional', '(11) 98888-0008', null, null);
  perform pg_temp.sistema();
  select ap.* into a from public.appointments ap join public.customers c on c.id = ap.customer_id
   where c.phone_e164 = '+5511988880008';
  perform pg_temp.igual(a.total_price_cents::text, '10500', 'corte + sobrancelha como adicional: R$ 90 + R$ 15');
  perform pg_temp.igual(extract(epoch from (a.ends_at - a.starts_at))::int::text, (50 * 60)::text, 'corte + sobrancelha: 40 + 10 min');
end $$;

-- Telefone que já tem cadastro, agendando sem o token do cliente (regra da etapa 0).
do $$
declare
  v_b uuid := pg_temp.barbearia('scalabrini-barbieri');
  v_vini uuid := pg_temp.profissional('scalabrini-barbieri', 'vinicius-nunes');
  v_corte uuid := pg_temp.servico('scalabrini-barbieri', 'corte');
  v_dia date := pg_temp.dia_util(6);
  v_nome_antes text;
  r jsonb;
  a record;
begin
  select full_name into v_nome_antes from public.customers where barbershop_id = v_b and phone_e164 = '+5511900000003';
  perform pg_temp.anonimo();
  r := public.barberium_create_appointment('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, '{}', v_dia,
         pg_temp.primeiro_horario('scalabrini-barbieri', 'braganca-paulista', v_vini, v_corte, v_dia),
         'Nome Diferente', '(11) 90000-0003', null, null);
  perform pg_temp.ok(coalesce(r ->> 'access_token', '') = '', 'telefone já cadastrado, sem token: não recebe token do perfil', r::text);
  perform pg_temp.igual(r ->> 'profile_linked', 'false', 'resposta avisa que o perfil não foi vinculado');
  perform pg_temp.sistema();
  perform pg_temp.igual((select full_name from public.customers where barbershop_id = v_b and phone_e164 = '+5511900000003'),
                        v_nome_antes, 'nome do cadastro continua o mesmo');
  select * into a from public.appointments where barbershop_id = v_b
     and customer_id = (select id from public.customers where barbershop_id = v_b and phone_e164 = '+5511900000003')
   order by created_at desc limit 1;
  perform pg_temp.ok(a.internal_note like '%Nome informado no site: Nome Diferente%', 'nome digitado vai para a nota interna', a.internal_note);

  perform pg_temp.anonimo();
  perform pg_temp.erro($q$select public.barberium_customer_open_profile('scalabrini-barbieri','Cliente Teste 03','(11) 90000-0003')$q$,
                       'PROFILE_VERIFICATION_REQUIRED', '"Acessar em outro aparelho" exige verificação (pausado)');
end $$;
