-- Barberium · Etapa 6 · ROLLBACK
-- Volta o banco exatamente a como estava em 21/10/2026, antes da etapa 6.
-- Atenção: reabre o que a etapa 6 fechou (ligações entre barbearias, permissões padrão,
-- meta financeira em unidade de outra barbearia). Use só se a etapa 6 quebrar algo.
--
-- Ordem:
--   1. Cloudflare: volte o site para o deploy anterior à etapa 6 (o site novo precisa da
--      função barberium_resolve_tenant, que este arquivo apaga).
--   2. Supabase, SQL Editor: rode este arquivo inteiro. Ou entra tudo, ou nada.
--   3. Repositório: apague os 4 arquivos supabase/migrations/20261021*_etapa6_*.sql, senão a
--      próxima publicação aplica a etapa 6 de novo.

begin;

-- 4. Permissões e correções (20261021100300)

CREATE OR REPLACE FUNCTION public.barberium_staff_save_financial_goal(p_unit_id uuid, p_month date, p_revenue_target_cents integer, p_net_target_cents integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$ declare m record; normalized date; v_id uuid; begin if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if; normalized:=date_trunc('month',p_month)::date; select id into v_id from public.financial_goals where barbershop_id=m.barbershop_id and unit_id is not distinct from p_unit_id and month=normalized; if v_id is null then insert into public.financial_goals(barbershop_id,unit_id,month,revenue_target_cents,net_target_cents) values(m.barbershop_id,p_unit_id,normalized,p_revenue_target_cents,p_net_target_cents) returning id into v_id; else update public.financial_goals set revenue_target_cents=p_revenue_target_cents,net_target_cents=p_net_target_cents,updated_at=now() where id=v_id; end if; return jsonb_build_object('ok',true,'id',v_id); end $function$;

grant execute on function public.barberium_staff_balance_quick(date, date, uuid) to anon;
grant execute on function public.barberium_staff_free_ranges(date, uuid) to anon;
grant execute on function public.barberium_staff_performance_v12_33(date, date) to anon;

alter default privileges for role postgres in schema extensions revoke execute on functions from public;
alter default privileges for role postgres grant execute on functions to public;
alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated;
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated;

-- Antes da etapa 6, visitante e usuário logado tinham privilégio direto em todas as tabelas,
-- menos nestas 16, fechadas desde antes. A tabela de endereços sai no passo 1, mais abaixo.
drop table public.barbershop_domains;
grant all on all tables in schema public to anon, authenticated;
grant all on all sequences in schema public to anon, authenticated;
revoke all on table public.appointment_addons, public.appointment_events, public.appointments, public.barbershop_members, public.barbershops, public.blocked_time_series, public.blocked_times, public.business_hours, public.customer_access_tokens, public.customers, public.professional_permissions, public.professional_services, public.professionals, public.service_addons, public.services, public.units from anon, authenticated;

-- 3. Ligações entre tabelas (20261021100200)
alter table public.appointment_events drop constraint appointment_events_actor_member_id_barbearia_fkey;
alter table public.appointment_events drop constraint appointment_events_appointment_id_barbearia_fkey;
alter table public.appointment_payments drop constraint appointment_payments_actor_member_id_barbearia_fkey;
alter table public.appointment_payments drop constraint appointment_payments_appointment_id_barbearia_fkey;
alter table public.appointment_payments drop constraint appointment_payments_provider_id_barbearia_fkey;
alter table public.appointment_payments drop constraint appointment_payments_unit_id_barbearia_fkey;
alter table public.appointment_receivables drop constraint appointment_receivables_appointment_id_barbearia_fkey;
alter table public.appointment_receivables drop constraint appointment_receivables_unit_id_barbearia_fkey;
alter table public.appointments drop constraint appointments_created_by_member_id_barbearia_fkey;
alter table public.appointments drop constraint appointments_customer_id_barbearia_fkey;
alter table public.appointments drop constraint appointments_professional_id_barbearia_fkey;
alter table public.appointments drop constraint appointments_service_id_barbearia_fkey;
alter table public.appointments drop constraint appointments_unit_id_barbearia_fkey;
alter table public.barbershop_members drop constraint barbershop_members_professional_id_barbearia_fkey;
alter table public.blocked_time_series drop constraint blocked_time_series_created_by_member_id_barbearia_fkey;
alter table public.blocked_time_series drop constraint blocked_time_series_professional_id_barbearia_fkey;
alter table public.blocked_time_series drop constraint blocked_time_series_unit_id_barbearia_fkey;
alter table public.blocked_times drop constraint blocked_times_created_by_member_id_barbearia_fkey;
alter table public.blocked_times drop constraint blocked_times_professional_id_barbearia_fkey;
alter table public.blocked_times drop constraint blocked_times_unit_id_barbearia_fkey;
alter table public.cash_movements drop constraint cash_movements_actor_member_id_barbearia_fkey;
alter table public.cash_movements drop constraint cash_movements_cash_session_id_barbearia_fkey;
alter table public.cash_movements drop constraint cash_movements_unit_id_barbearia_fkey;
alter table public.cash_sessions drop constraint cash_sessions_closed_by_member_id_barbearia_fkey;
alter table public.cash_sessions drop constraint cash_sessions_opened_by_member_id_barbearia_fkey;
alter table public.commission_entries drop constraint commission_entries_appointment_id_barbearia_fkey;
alter table public.commission_entries drop constraint commission_entries_professional_id_barbearia_fkey;
alter table public.commission_entries drop constraint commission_entries_settlement_id_barbearia_fkey;
alter table public.commission_entries drop constraint commission_entries_unit_id_barbearia_fkey;
alter table public.commission_settlements drop constraint commission_settlements_created_by_member_id_barbearia_fkey;
alter table public.commission_settlements drop constraint commission_settlements_professional_id_barbearia_fkey;
alter table public.customer_memberships drop constraint customer_memberships_created_by_member_id_barbearia_fkey;
alter table public.customer_memberships drop constraint customer_memberships_customer_id_barbearia_fkey;
alter table public.customer_memberships drop constraint customer_memberships_next_plan_id_barbearia_fkey;
alter table public.customer_memberships drop constraint customer_memberships_plan_id_barbearia_fkey;
alter table public.customers drop constraint customers_preferred_unit_id_barbearia_fkey;
alter table public.expenses drop constraint expenses_category_id_barbearia_fkey;
alter table public.expenses drop constraint expenses_created_by_member_id_barbearia_fkey;
alter table public.expenses drop constraint expenses_paid_by_member_id_barbearia_fkey;
alter table public.expenses drop constraint expenses_recurring_expense_id_barbearia_fkey;
alter table public.expenses drop constraint expenses_unit_id_barbearia_fkey;
alter table public.finance_refunds drop constraint finance_refunds_actor_member_id_barbearia_fkey;
alter table public.finance_refunds drop constraint finance_refunds_appointment_id_barbearia_fkey;
alter table public.finance_refunds drop constraint finance_refunds_membership_id_barbearia_fkey;
alter table public.finance_refunds drop constraint finance_refunds_product_sale_id_barbearia_fkey;
alter table public.finance_refunds drop constraint finance_refunds_unit_id_barbearia_fkey;
alter table public.finance_settings drop constraint finance_settings_unit_id_barbearia_fkey;
alter table public.financial_goals drop constraint financial_goals_unit_id_barbearia_fkey;
alter table public.membership_action_requests drop constraint membership_action_requests_customer_id_barbearia_fkey;
alter table public.membership_action_requests drop constraint membership_action_requests_decided_by_member_id_barbearia_fkey;
alter table public.membership_action_requests drop constraint membership_action_requests_membership_id_barbearia_fkey;
alter table public.membership_requests drop constraint membership_requests_customer_id_barbearia_fkey;
alter table public.membership_requests drop constraint membership_requests_decided_by_member_id_barbearia_fkey;
alter table public.membership_requests drop constraint membership_requests_plan_id_barbearia_fkey;
alter table public.product_commission_profiles drop constraint product_commission_profiles_professional_id_barbearia_fkey;
alter table public.product_inventory drop constraint product_inventory_product_id_barbearia_fkey;
alter table public.product_inventory drop constraint product_inventory_unit_id_barbearia_fkey;
alter table public.product_sale_payments drop constraint product_sale_payments_actor_member_id_barbearia_fkey;
alter table public.product_sale_payments drop constraint product_sale_payments_provider_id_barbearia_fkey;
alter table public.product_sale_payments drop constraint product_sale_payments_sale_id_barbearia_fkey;
alter table public.product_sale_payments drop constraint product_sale_payments_unit_id_barbearia_fkey;
alter table public.product_sale_receivables drop constraint product_sale_receivables_sale_id_barbearia_fkey;
alter table public.product_sale_receivables drop constraint product_sale_receivables_unit_id_barbearia_fkey;
alter table public.product_sales drop constraint product_sales_appointment_id_barbearia_fkey;
alter table public.product_sales drop constraint product_sales_completed_by_member_id_barbearia_fkey;
alter table public.product_sales drop constraint product_sales_created_by_member_id_barbearia_fkey;
alter table public.product_sales drop constraint product_sales_customer_id_barbearia_fkey;
alter table public.product_sales drop constraint product_sales_seller_professional_id_barbearia_fkey;
alter table public.product_sales drop constraint product_sales_unit_id_barbearia_fkey;
alter table public.product_stock_movements drop constraint product_stock_movements_actor_member_id_barbearia_fkey;
alter table public.product_stock_movements drop constraint product_stock_movements_product_id_barbearia_fkey;
alter table public.product_stock_movements drop constraint product_stock_movements_unit_id_barbearia_fkey;
alter table public.professional_permissions drop constraint professional_permissions_professional_id_barbearia_fkey;
alter table public.professionals drop constraint professionals_unit_id_barbearia_fkey;
alter table public.recurring_expenses drop constraint recurring_expenses_category_id_barbearia_fkey;
alter table public.recurring_expenses drop constraint recurring_expenses_created_by_member_id_barbearia_fkey;
alter table public.recurring_expenses drop constraint recurring_expenses_unit_id_barbearia_fkey;
alter table public.service_addons drop constraint service_addons_addon_service_id_barbearia_fkey;
alter table public.service_addons drop constraint service_addons_base_service_id_barbearia_fkey;
alter table public.service_addons drop constraint service_addons_unit_id_barbearia_fkey;
alter table public.services drop constraint services_unit_id_barbearia_fkey;
alter table public.special_business_hours drop constraint special_business_hours_created_by_member_id_barbearia_fkey;
alter table public.special_business_hours drop constraint special_business_hours_professional_id_barbearia_fkey;
alter table public.special_business_hours drop constraint special_business_hours_unit_id_barbearia_fkey;
alter table public.appointments drop constraint appointments_id_barbershop_id_key;
alter table public.barbershop_members drop constraint barbershop_members_id_barbershop_id_key;
alter table public.cash_sessions drop constraint cash_sessions_id_barbershop_id_key;
alter table public.commission_settlements drop constraint commission_settlements_id_barbershop_id_key;
alter table public.customer_memberships drop constraint customer_memberships_id_barbershop_id_key;
alter table public.customers drop constraint customers_id_barbershop_id_key;
alter table public.expense_categories drop constraint expense_categories_id_barbershop_id_key;
alter table public.membership_plans drop constraint membership_plans_id_barbershop_id_key;
alter table public.payment_providers drop constraint payment_providers_id_barbershop_id_key;
alter table public.product_sales drop constraint product_sales_id_barbershop_id_key;
alter table public.products drop constraint products_id_barbershop_id_key;
alter table public.recurring_expenses drop constraint recurring_expenses_id_barbershop_id_key;
alter table public.services drop constraint services_id_barbershop_id_key;

-- 2. Barbearia ativa na Área da Equipe (20261021100100)
create or replace function barberium.staff_membership()
 returns table(member_id uuid, barbershop_id uuid, barbershop_name text, role text, professional_id uuid, professional_name text, is_active boolean)
 language sql
 security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
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
  where bm.auth_user_id = auth.uid()
    and bm.is_active = true
  limit 1
$function$;

-- 1. Endereço → barbearia (20261021100000). A tabela já saiu acima.
drop function public.barberium_resolve_tenant(text, text, text);
drop function barberium.normalizar_host(text);

-- Histórico de migrations do Supabase.
delete from supabase_migrations.schema_migrations
 where version in ('20261021100000', '20261021100100', '20261021100200', '20261021100300');

commit;
