-- Stub do pg_net: cria o schema net e as funções que as migrations do Barberium chamam.
-- Não envia nada; existe só para o schema poder ser reconstruído fora do Supabase.
create schema if not exists net;
create table if not exists net.http_request_queue(id bigserial primary key, method text, url text, headers jsonb, body bytea, timeout_milliseconds int);
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb, headers jsonb default '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language sql as $$ insert into net.http_request_queue(method,url,headers,timeout_milliseconds) values('POST',url,headers,timeout_milliseconds) returning id $$;
create or replace function net.http_get(url text, params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language sql as $$ insert into net.http_request_queue(method,url,headers,timeout_milliseconds) values('GET',url,headers,timeout_milliseconds) returning id $$;
