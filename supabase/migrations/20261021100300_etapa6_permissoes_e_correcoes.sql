-- Barberium · Estabilização · Etapa 6 · 21/10/2026
-- Permissões padrão fechadas e as duas correções que os testes da etapa 3 apontaram.
--
-- 1. Tabelas: visitante (anon) e usuário logado (authenticated) perdem os privilégios diretos
--    nas tabelas. Hoje eles já não leem nada (todas têm RLS e nenhuma policy); o site só usa
--    funções. Isto é uma segunda trava: uma tabela nova criada sem RLS também não fica aberta.
-- 2. Padrões para objetos novos: tabela, sequência ou função criada daqui em diante não fica
--    liberada para anon/authenticated sem um GRANT explícito na própria migration.
-- 3. Saldos, horários livres e desempenho da equipe deixam de ser executáveis por visitante.
--    Elas já recusavam por dentro ("Não autenticado").
-- 4. barberium_staff_save_financial_goal confere se a unidade é da barbearia do login. Antes,
--    o ADM de uma barbearia gravava a meta dele apontando para a unidade de outra.
--
-- Rollback: docs/etapa6_rollback.sql

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
-- O PostgreSQL também libera toda função nova para PUBLIC (todo mundo), e isso só se desliga
-- no padrão geral, sem "in schema". Vale só para o que o postgres criar daqui em diante:
--   - public: anon e authenticated deixam de herdar; o service_role continua pelo padrão do esquema;
--   - barberium: ninguém além do postgres usa esse esquema (anon, authenticated e service_role
--     não têm acesso a ele), então nada muda na prática;
--   - extensions: continua como antes (linha abaixo), para extensão nova funcionar como hoje.
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema extensions grant execute on functions to public;

revoke execute on function public.barberium_staff_balance_quick(date, date, uuid) from public, anon;
revoke execute on function public.barberium_staff_free_ranges(date, uuid) from public, anon;
revoke execute on function public.barberium_staff_performance_v12_33(date, date) from public, anon;

CREATE OR REPLACE FUNCTION public.barberium_staff_save_financial_goal(p_unit_id uuid, p_month date, p_revenue_target_cents integer, p_net_target_cents integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; normalized date; v_id uuid; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  -- Etapa 6: a unidade precisa ser desta barbearia.
  if p_unit_id is not null and not exists (select 1 from public.units where id=p_unit_id and barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  normalized:=date_trunc('month',p_month)::date; select id into v_id from public.financial_goals where barbershop_id=m.barbershop_id and unit_id is not distinct from p_unit_id and month=normalized; if v_id is null then insert into public.financial_goals(barbershop_id,unit_id,month,revenue_target_cents,net_target_cents) values(m.barbershop_id,p_unit_id,normalized,p_revenue_target_cents,p_net_target_cents) returning id into v_id; else update public.financial_goals set revenue_target_cents=p_revenue_target_cents,net_target_cents=p_net_target_cents,updated_at=now() where id=v_id; end if; return jsonb_build_object('ok',true,'id',v_id); end $function$;
