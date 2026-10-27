-- 14 · Site do cliente (etapa 7h).
-- Parte 1: o catálogo diz se a unidade está em manutenção (unit.maintenance), com a mesma regra
-- que faz o banco recusar agendar (barberium.unidade_em_manutencao). O site só obedece.

do $$
declare
  v_unidade uuid := pg_temp.unidade('scalabrini-barbieri');
  v_antes jsonb;
  r jsonb;
  v_casos text := '';
  c record;
begin
  perform pg_temp.sistema();
  select settings into v_antes from public.units where id = v_unidade;
  for c in select * from (values (1, 'sem a chave', null::jsonb), (2, 'nula', 'null'::jsonb), (3, 'true', 'true'::jsonb), (4, 'false', 'false'::jsonb), (5, 'texto "false"', '"false"'::jsonb)) x(n, nome, valor) order by n loop
    perform pg_temp.sistema();
    update public.units set settings = case when c.valor is null then settings - 'client_maintenance_mode'
                                            else jsonb_set(settings, '{client_maintenance_mode}', c.valor) end
    where id = v_unidade;
    perform pg_temp.anonimo();
    r := public.barberium_get_catalog('scalabrini-barbieri', 'braganca-paulista');
    perform pg_temp.sistema();
    v_casos := v_casos || format('%s=%s%s ', c.nome, r -> 'unit' ->> 'maintenance',
      case when (r -> 'unit' ->> 'maintenance')::boolean = barberium.unidade_em_manutencao((select settings from public.units where id = v_unidade)) then '' else '(DIFERENTE do banco)' end);
  end loop;
  perform pg_temp.igual(btrim(v_casos), 'sem a chave=true nula=true true=true false=false texto "false"=false',
                        'catálogo: unit.maintenance segue a regra do banco (sem a chave ou nula = ligada; só false abre)');

  -- O resto do catálogo não muda: as mesmas partes, e as configurações da unidade inteiras.
  perform pg_temp.sistema();
  update public.units set settings = v_antes where id = v_unidade;
  perform pg_temp.anonimo();
  r := public.barberium_get_catalog('scalabrini-barbieri', 'braganca-paulista');
  perform pg_temp.igual((select string_agg(k, ',' order by k) from jsonb_object_keys(r) k), 'barbershop,professionals,services,unit', 'catálogo: as mesmas 4 partes');
  perform pg_temp.igual((select string_agg(k, ',' order by k) from jsonb_object_keys(r -> 'unit') k),
                        'city,id,maintenance,maps_url,name,settings,slug,state,whatsapp', 'catálogo: a unidade ganha só "maintenance"');
  perform pg_temp.sistema();
  perform pg_temp.igual((r -> 'unit' -> 'settings')::text, v_antes::text, 'catálogo: as configurações da unidade vêm inteiras, como antes');
end $$;
