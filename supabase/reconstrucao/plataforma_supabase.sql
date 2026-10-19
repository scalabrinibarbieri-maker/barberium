-- Barberium · base da plataforma Supabase para reconstruir o banco do zero fora do Supabase.
-- Recria só o que as migrations do Barberium usam e que, num projeto Supabase, já vem pronto:
-- papéis, schemas auth/storage/vault/extensions, funções auth.uid()/jwt()/role(), tabelas
-- mínimas de auth e storage, cofre (vault) sem criptografia e as permissões padrão de public.
-- Não é usado em produção nem no staging; serve para o teste "banco vazio + migrations = produção".

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin noinherit bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_admin') then create role supabase_admin superuser; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_auth_admin') then create role supabase_auth_admin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_storage_admin') then create role supabase_storage_admin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_functions_admin') then create role supabase_functions_admin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='dashboard_user') then create role dashboard_user; end if;
end $$;
grant anon, authenticated, service_role to authenticator;
grant anon, authenticated, service_role to postgres;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

grant usage on schema public to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to postgres, anon, authenticated, service_role;

-- auth
create schema if not exists auth authorization supabase_admin;
grant usage on schema auth to anon, authenticated, service_role, postgres;
create type auth.aal_level as enum ('aal1','aal2','aal3');
-- Mesmas colunas de auth.users e auth.identities da produção (lidas em 19/10/2026),
-- para os dados fictícios do banco de teste poderem ser testados aqui também.
create table auth.users(
  instance_id uuid, id uuid primary key, aud varchar(255), role varchar(255), email varchar(255),
  encrypted_password varchar(255), email_confirmed_at timestamptz, invited_at timestamptz,
  confirmation_token varchar(255), confirmation_sent_at timestamptz, recovery_token varchar(255),
  recovery_sent_at timestamptz, email_change_token_new varchar(255), email_change varchar(255),
  email_change_sent_at timestamptz, last_sign_in_at timestamptz, raw_app_meta_data jsonb,
  raw_user_meta_data jsonb, is_super_admin boolean, created_at timestamptz, updated_at timestamptz,
  phone text default null, phone_confirmed_at timestamptz, phone_change text default '',
  phone_change_token varchar(255) default '', phone_change_sent_at timestamptz,
  confirmed_at timestamptz generated always as (least(email_confirmed_at, phone_confirmed_at)) stored,
  email_change_token_current varchar(255) default '', email_change_confirm_status smallint default 0,
  banned_until timestamptz, reauthentication_token varchar(255) default '', reauthentication_sent_at timestamptz,
  is_sso_user boolean not null default false, deleted_at timestamptz, is_anonymous boolean not null default false
);
create table auth.identities(
  provider_id text not null, user_id uuid not null references auth.users(id) on delete cascade,
  identity_data jsonb not null, provider text not null, last_sign_in_at timestamptz,
  created_at timestamptz, updated_at timestamptz,
  email text generated always as (lower(identity_data ->> 'email')) stored,
  id uuid primary key default gen_random_uuid(), unique (provider_id, provider)
);
grant select, insert, update, delete on auth.users, auth.identities to postgres;
create table auth.sessions(
  id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz, updated_at timestamptz, aal auth.aal_level, not_after timestamptz,
  refreshed_at timestamp, user_agent text, ip inet, tag text
);
grant select on auth.users, auth.sessions to postgres;
create or replace function auth.uid() returns uuid language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $f$;
create or replace function auth.role() returns text language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text $f$;
create or replace function auth.jwt() returns jsonb language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), ''))::jsonb $f$;
create or replace function auth.email() returns text language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))::text $f$;
grant execute on function auth.uid(), auth.role(), auth.jwt(), auth.email() to anon, authenticated, service_role, postgres;

-- storage
create schema if not exists storage authorization supabase_admin;
grant usage on schema storage to anon, authenticated, service_role, postgres;
create table storage.buckets(
  id text primary key, name text not null, owner uuid, created_at timestamptz default now(), updated_at timestamptz default now(),
  public boolean default false, avif_autodetection boolean default false, file_size_limit bigint, allowed_mime_types text[], owner_id text
);
create table storage.objects(
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid,
  created_at timestamptz default now(), updated_at timestamptz default now(), last_accessed_at timestamptz default now(),
  metadata jsonb, path_tokens text[], version text, owner_id text, user_metadata jsonb
);
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;
grant all on storage.buckets, storage.objects to postgres, service_role;
grant select, insert, update, delete on storage.buckets, storage.objects to anon, authenticated;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $f$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'),1)-1] $f$;
create or replace function storage.filename(name text) returns text language sql immutable as $f$ select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'),1)] $f$;
create or replace function storage.extension(name text) returns text language sql immutable as $f$ select reverse(split_part(reverse(name), '.', 1)) $f$;

-- vault (sem criptografia: só a forma)
create schema if not exists vault authorization supabase_admin;
grant usage on schema vault to postgres, service_role;
create table vault.secrets(
  id uuid primary key default gen_random_uuid(), name text unique, description text not null default '',
  secret text not null, key_id uuid, nonce bytea, created_at timestamptz not null default current_timestamp,
  updated_at timestamptz not null default current_timestamp
);
create view vault.decrypted_secrets as
  select id, name, description, secret, secret as decrypted_secret, key_id, nonce, created_at, updated_at from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text default null, new_description text default '', new_key_id uuid default null)
returns uuid language sql as $f$ insert into vault.secrets(secret,name,description,key_id) values(new_secret,new_name,coalesce(new_description,''),new_key_id) returning id $f$;
grant select on vault.secrets, vault.decrypted_secrets to postgres, service_role;

-- cron: extensão real (pg_cron), como no Supabase
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
