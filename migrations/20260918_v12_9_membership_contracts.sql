-- Barberium v12.9 — leitura administrativa de contratos ativos em Planos.
-- Backend de produção já recebeu esta etapa.
-- Reaproveita a mesma estrutura de barberium_staff_customer_memberships para não duplicar regras de negócio.

create or replace function public.barberium_staff_membership_contracts()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare
  m record;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  select * into m from barberium.staff_membership();

  if m.member_id is null or m.role not in ('owner','admin') then
    raise exception 'Acesso somente para ADM';
  end if;

  return coalesce((
    select jsonb_agg(x.contract order by lower(x.contract->>'customer'), lower(x.contract->>'name'), x.contract->>'started_at')
    from (
      select
        membership.value ||
        jsonb_build_object(
          'customer_id', c.id,
          'customer', c.full_name,
          'phone', c.phone_e164
        ) as contract
      from (
        select distinct c.id, c.full_name, c.phone_e164
        from public.customers c
        join public.customer_memberships cm
          on cm.customer_id = c.id
         and cm.barbershop_id = c.barbershop_id
        where c.barbershop_id = m.barbershop_id
          and cm.status in ('active','paused','overdue','pending')
      ) c
      cross join lateral jsonb_array_elements(
        public.barberium_staff_customer_memberships(c.id)
      ) as membership(value)
      where membership.value->>'status' in ('active','paused','overdue','pending')
    ) x
  ), '[]'::jsonb);
end
$function$;

revoke all on function public.barberium_staff_membership_contracts() from public, anon;
grant execute on function public.barberium_staff_membership_contracts() to authenticated, service_role;
