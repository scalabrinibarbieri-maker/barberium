-- Barberium · Estabilização · Etapa 6 · 21/10/2026
-- Barbearia ativa explícita na Área da Equipe.
--
-- Antes: barberium.staff_membership() pegava "um" vínculo do login (limit 1 sem ordem). Com
-- um login em duas barbearias, cada chamada podia cair numa barbearia diferente.
-- Agora: o site manda o cabeçalho x-barberium-barbearia com a barbearia do endereço aberto.
--   - Com o cabeçalho: só vale o vínculo do login com aquela barbearia. Login de outra
--     barbearia não entra (o resultado é "sem acesso", como para quem não é da equipe).
--   - Sem o cabeçalho (site antigo em cache, cron, SQL Editor): vale o vínculo só se o login
--     tiver exatamente um. Hoje todo login tem um, então nada muda para quem usa o site antigo.
-- As 126 funções da equipe usam esta função, então todas passam a seguir a mesma regra.
--
-- Rollback: docs/etapa6_rollback.sql

create or replace function barberium.staff_membership()
 returns table(member_id uuid, barbershop_id uuid, barbershop_name text, role text, professional_id uuid, professional_name text, is_active boolean)
 language sql
 security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
  with pedido as (
    select nullif(lower(trim(coalesce(
      nullif(current_setting('request.headers', true), '')::json ->> 'x-barberium-barbearia', ''))), '') as slug
  )
  select
    bm.id,
    bm.barbershop_id,
    b.name,
    bm.role,
    bm.professional_id,
    p.name,
    bm.is_active
  from public.barbershop_members bm
  join public.barbershops b on b.id = bm.barbershop_id
  left join public.professionals p on p.id = bm.professional_id
  cross join pedido
  where bm.auth_user_id = auth.uid()
    and bm.is_active = true
    and (
      (pedido.slug is not null and b.slug = pedido.slug)
      or (pedido.slug is null
          and (select count(*) from public.barbershop_members x where x.auth_user_id = auth.uid() and x.is_active) = 1)
    )
  limit 1
$function$;
