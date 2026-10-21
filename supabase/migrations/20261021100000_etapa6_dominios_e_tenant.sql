-- Barberium · Estabilização · Etapa 6 · 21/10/2026
-- Tenant pelo endereço. Cada endereço (domínio ou subdomínio) aponta para uma barbearia e,
-- se ela quiser, para uma unidade fixa. Sem unidade fixa, o site do cliente mostra a escolha
-- de unidade. O site deixa de ter "scalabrini-barbieri" escrito no código: ele pergunta ao
-- banco, pelo endereço em que foi aberto, de qual barbearia é.
--
-- Endereços de teste (staging, computador local) podem trocar de barbearia por ?barbearia=slug
-- (allow_tenant_param). Os endereços reais não aceitam esse parâmetro.
--
-- Nenhum dado existente é alterado. Rollback: docs/etapa6_rollback.sql

create table public.barbershop_domains (
  host text primary key,
  barbershop_id uuid not null references public.barbershops(id) on delete cascade,
  unit_id uuid,
  allow_tenant_param boolean not null default false,
  created_at timestamptz not null default now(),
  constraint barbershop_domains_host_valido
    check (host ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' and host !~ '^www\.'),
  constraint barbershop_domains_unit_id_barbershop_id_fkey
    foreign key (unit_id, barbershop_id) references public.units(id, barbershop_id) on delete set null (unit_id)
);
create index barbershop_domains_barbershop_id_idx on public.barbershop_domains(barbershop_id);
alter table public.barbershop_domains enable row level security;
revoke all on public.barbershop_domains from public, anon, authenticated;
comment on table public.barbershop_domains is
  'Endereço do site → barbearia (e unidade fixa, opcional). host em minúsculas, sem www. e sem porta.';

-- Endereço como o banco guarda: minúsculas, sem porta e sem "www.".
create or replace function barberium.normalizar_host(p_host text)
 returns text
 language sql
 immutable
as $function$
  select regexp_replace(regexp_replace(lower(trim(coalesce(p_host, ''))), ':[0-9]+$', ''), '^www\.', '')
$function$;

-- Pública: o site chama ao abrir, com o próprio endereço. Devolve a barbearia, a unidade
-- (fixa pelo endereço ou escolhida pelo cliente) e a lista de unidades ativas.
create or replace function public.barberium_resolve_tenant(p_host text, p_barbershop_slug text default null, p_unit_slug text default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium'
as $function$
declare
  v_host text := barberium.normalizar_host(p_host);
  v_param text := nullif(lower(trim(coalesce(p_barbershop_slug, ''))), '');
  v_unidade text := nullif(lower(trim(coalesce(p_unit_slug, ''))), '');
  d public.barbershop_domains;
  b public.barbershops;
  u public.units;
  v_fixa boolean := false;
begin
  select * into d from public.barbershop_domains where host = v_host;
  if not found then
    raise exception 'TENANT_NOT_FOUND' using hint = 'Endereço não cadastrado: ' || v_host;
  end if;

  if v_param is not null and d.allow_tenant_param then
    select * into b from public.barbershops where slug = v_param and status = 'active';
  else
    select * into b from public.barbershops where id = d.barbershop_id and status = 'active';
    if d.unit_id is not null then
      select * into u from public.units where id = d.unit_id and barbershop_id = b.id and is_active;
      v_fixa := found;
    end if;
  end if;
  if b.id is null then
    raise exception 'TENANT_NOT_FOUND' using hint = 'Barbearia inexistente ou inativa.';
  end if;

  if u.id is null and v_unidade is not null then
    select * into u from public.units where barbershop_id = b.id and slug = v_unidade and is_active;
  end if;

  return jsonb_build_object(
    'host', v_host,
    'barbershop', jsonb_build_object('slug', b.slug, 'name', b.name, 'timezone', b.timezone, 'settings', b.settings),
    'unit_fixed', v_fixa,
    'unit', case when u.id is null then null else jsonb_build_object(
      'slug', u.slug, 'name', u.name, 'city', u.city, 'state', u.state, 'whatsapp', u.whatsapp, 'maps_url', u.maps_url) end,
    'units', coalesce((select jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'city', x.city, 'state', x.state) order by x.name)
                       from public.units x where x.barbershop_id = b.id and x.is_active), '[]'::jsonb),
    -- Logo cadastrado em Ajustes (o da unidade aberta; sem unidade, o da primeira que tiver).
    'logo_url', coalesce(nullif(u.settings ->> 'client_logo_url', ''),
                         (select nullif(x.settings ->> 'client_logo_url', '') from public.units x
                           where x.barbershop_id = b.id and x.is_active and nullif(x.settings ->> 'client_logo_url', '') is not null
                           order by x.name limit 1)),
    'allow_tenant_param', d.allow_tenant_param
  );
end
$function$;
revoke execute on function public.barberium_resolve_tenant(text, text, text) from public;
grant execute on function public.barberium_resolve_tenant(text, text, text) to anon, authenticated, service_role;

-- Endereços de hoje: o site da Scalabrini e o endereço principal do projeto no Cloudflare.
-- Ambos abrem fixos na unidade de Bragança Paulista, como hoje.
insert into public.barbershop_domains (host, barbershop_id, unit_id)
select h.host, b.id, u.id
from public.barbershops b
join public.units u on u.barbershop_id = b.id and u.slug = 'braganca-paulista'
cross join (values ('scalabrinibarbiere.com'), ('barberium.pages.dev')) as h(host)
where b.slug = 'scalabrini-barbieri'
on conflict (host) do nothing;
