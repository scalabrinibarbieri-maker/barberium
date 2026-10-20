-- Funções de apoio dos testes de caracterização (etapa 3). Carregado no começo de cada
-- arquivo de teste, dentro de uma transação que é desfeita no fim: nada fica no banco.
--
-- Quem chama:      pg_temp.como(usuario)  pg_temp.anonimo()  pg_temp.sistema()
-- Conferências:    pg_temp.ok(condicao, descricao [, detalhe])
--                  pg_temp.igual(obtido, esperado, descricao)        (texto)
--                  pg_temp.erro(sql, padrao_da_mensagem, descricao)  espera um erro (sempre desfeito)
--                  pg_temp.funciona(sql, descricao)                  espera sucesso (sempre desfeito)
--                  pg_temp.roda(sql) -> jsonb                        executa e devolve o resultado
--                  pg_temp.vai_mudar(condicao, descricao, detalhe)   comportamento atual que é
--                     um defeito conhecido: passa enquanto continuar igual e avisa quando mudar
-- Dados de teste:  pg_temp.id(...) e pg_temp.dia_util(...)

create temp table _resultado (
  n serial primary key,
  ok boolean not null,
  vai_mudar boolean not null default false,
  descricao text not null,
  detalhe text
);
grant all on _resultado to public;
grant all on sequence _resultado_n_seq to public;

create function pg_temp.como(p_usuario uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_usuario, 'role', 'authenticated')::text, true);
  select set_config('role', 'authenticated', true);
$$;

create function pg_temp.anonimo() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role":"anon"}', true);
  select set_config('role', 'anon', true);
$$;

create function pg_temp.sistema() returns void language sql as $$
  select set_config('role', 'postgres', true);
  select set_config('request.jwt.claims', '', true);
$$;

create function pg_temp.ok(p_condicao boolean, p_descricao text, p_detalhe text default null)
returns boolean language sql as $$
  insert into _resultado(ok, descricao, detalhe) values (coalesce(p_condicao, false), p_descricao, p_detalhe)
  returning ok;
$$;

create function pg_temp.igual(p_obtido text, p_esperado text, p_descricao text)
returns boolean language sql as $$
  select pg_temp.ok(p_obtido is not distinct from p_esperado, p_descricao,
                    format('obtido: %s | esperado: %s', coalesce(p_obtido, 'null'), coalesce(p_esperado, 'null')));
$$;

create function pg_temp.vai_mudar(p_condicao boolean, p_descricao text, p_detalhe text default null)
returns boolean language sql as $$
  insert into _resultado(ok, vai_mudar, descricao, detalhe)
  values (coalesce(p_condicao, false), true, p_descricao, p_detalhe)
  returning ok;
$$;

-- Executa um comando e devolve o resultado em jsonb (null se o comando não devolver nada).
create function pg_temp.roda(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'select to_jsonb(x) from (' || p_sql || ') as x(v)' into r;
  return r -> 'v';
end $$;

-- Espera um erro cuja mensagem combine com o padrão (expressão regular, sem diferenciar maiúsculas).
-- O comando é sempre desfeito, mesmo se funcionar: a conferência não deixa efeito no banco.
create function pg_temp.erro(p_sql text, p_padrao text, p_descricao text)
returns boolean language plpgsql as $$
declare v_msg text; v_estado text;
begin
  begin
    perform pg_temp.roda(p_sql);
    raise exception using errcode = 'P0999', message = '__funcionou__';
  exception when others then
    v_msg := sqlerrm; v_estado := sqlstate;
  end;
  if v_estado = 'P0999' then
    return pg_temp.ok(false, p_descricao, 'esperava erro "' || p_padrao || '", mas o comando funcionou');
  end if;
  return pg_temp.ok(v_msg ~* p_padrao, p_descricao, 'mensagem: ' || v_msg);
end $$;

-- Espera que o comando funcione. Também é sempre desfeito.
create function pg_temp.funciona(p_sql text, p_descricao text)
returns boolean language plpgsql as $$
declare v_msg text; v_estado text; v_res jsonb;
begin
  begin
    v_res := pg_temp.roda(p_sql);
    raise exception using errcode = 'P0999', message = '__funcionou__';
  exception when others then
    v_msg := sqlerrm; v_estado := sqlstate;
  end;
  return pg_temp.ok(v_estado = 'P0999', p_descricao,
                    case when v_estado = 'P0999' then left(coalesce(v_res::text, ''), 300) else 'erro: ' || v_msg end);
end $$;

-- IDs dos dados fictícios (supabase/staging/dados_ficticios.sql), procurados pelo slug.
-- "security definer": funcionam mesmo quando o teste está agindo como usuário da equipe.
create function pg_temp.barbearia(p_slug text) returns uuid language sql stable security definer as $$
  select id from public.barbershops where slug = p_slug $$;
create function pg_temp.unidade(p_slug_barbearia text) returns uuid language sql stable security definer as $$
  select u.id from public.units u where u.barbershop_id = pg_temp.barbearia(p_slug_barbearia) order by u.created_at limit 1 $$;
create function pg_temp.profissional(p_slug_barbearia text, p_slug text) returns uuid language sql stable security definer as $$
  select p.id from public.professionals p where p.barbershop_id = pg_temp.barbearia(p_slug_barbearia) and p.slug = p_slug $$;
create function pg_temp.servico(p_slug_barbearia text, p_slug text) returns uuid language sql stable security definer as $$
  select s.id from public.services s where s.barbershop_id = pg_temp.barbearia(p_slug_barbearia) and s.slug = p_slug $$;
create function pg_temp.cliente(p_slug_barbearia text, p_numero int) returns uuid language sql stable security definer as $$
  select c.id from public.customers c where c.barbershop_id = pg_temp.barbearia(p_slug_barbearia)
     and c.full_name = format('Cliente Teste %s', lpad(p_numero::text, 2, '0')) $$;

-- Usuários de teste (IDs fixos).
create function pg_temp.adm_scalabrini() returns uuid language sql immutable as $$ select '5a000000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.barbeiro_scalabrini() returns uuid language sql immutable as $$ select '5a000000-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.adm_aurora() returns uuid language sql immutable as $$ select '5a000000-0000-4000-8000-000000000003'::uuid $$;

-- Primeiro dia de segunda a sábado a partir de hoje + p_dias (no fuso de Brasília).
create function pg_temp.dia_util(p_dias int) returns date language sql stable security definer as $$
  select d::date from generate_series((now() at time zone 'America/Sao_Paulo')::date + p_dias,
                                      (now() at time zone 'America/Sao_Paulo')::date + p_dias + 7, interval '1 day') d
  where extract(dow from d) between 1 and 6 order by d limit 1 $$;

-- Primeiro horário livre do site para um profissional/serviço num dia.
create function pg_temp.primeiro_horario(p_barbearia text, p_unidade text, p_prof uuid, p_serv uuid, p_dia date)
returns time language sql stable security definer as $$
  select (public.barberium_get_available_slots(p_barbearia, p_unidade, p_prof, p_serv, '{}'::uuid[], p_dia) ->> 0)::time $$;
