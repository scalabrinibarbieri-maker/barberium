-- Barberium · Painel do dono do SaaS · ROLLBACK
-- Tira do banco o painel do dono (migration 20261021200000). As barbearias, unidades, endereços
-- e acessos já criados pelo painel CONTINUAM: são dados, e funcionam sem o painel. Só somem a
-- lista de donos do Barberium e os convites.
--
-- Ordem:
--   1. Cloudflare: volte o site para o deploy anterior ao painel.
--   2. Supabase: apague a função barberium-convite (Edge Functions → barberium-convite → Delete).
--   3. Supabase, SQL Editor: rode este arquivo inteiro. Ou entra tudo, ou nada.
--   4. Repositório: apague supabase/migrations/20261021200000_painel_dono_do_saas.sql, senão a
--      próxima publicação aplica de novo.

begin;

drop function public.barberium_platform_link_invite(uuid, uuid);
drop function public.barberium_platform_invite_detail(uuid);
drop function public.barberium_platform_create_barbershop(text, text, text, text, text, text, text, text, text);
drop function public.barberium_platform_barbershops();
drop function public.barberium_platform_whoami();
drop function barberium.slug_reservado(text);
drop function barberium.endereco_barberium(text);
drop function barberium.exigir_dono_do_saas();
drop function barberium.is_platform_admin();
drop table barberium.barbershop_invites;
drop table barberium.platform_admins;

delete from supabase_migrations.schema_migrations where version = '20261021200000';

commit;
