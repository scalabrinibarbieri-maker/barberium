-- Barberium · Convite de barbeiros e alertas de profissional novo · ROLLBACK
-- Tira do banco a etapa 6C (migration 20261022100000) e volta o painel do dono como estava na
-- etapa 6B. Os barbeiros que já entraram pelo convite CONTINUAM entrando (são acessos normais
-- da barbearia). Somem: os convites de barbeiro, os alertas de profissional novo e as decisões
-- de cobrança (anote antes as que estão em "cobrar", se precisar delas).
--
-- Ordem:
--   1. Cloudflare: volte o site para o deploy anterior (sem o botão Convidar e sem os alertas).
--   2. Supabase, SQL Editor: rode este arquivo inteiro. Ou entra tudo, ou nada.
--      A função barberium-convite pode ficar como está: sem a etapa 6C no banco, ela usa a
--      função antiga do painel e o convite do dono de barbearia segue funcionando.
--   3. Repositório: apague supabase/migrations/20261022100000_convite_barbeiros_e_alertas.sql,
--      senão a próxima publicação aplica de novo.

begin;

drop trigger trg_alerta_profissional_novo on public.professionals;
drop function barberium.alerta_profissional_novo();
drop function public.barberium_platform_decide_charge(uuid, boolean, integer, text);
drop function public.barberium_platform_charge_notified(uuid);
drop function public.barberium_platform_professional_charges();
drop function barberium.contato_do_dono(uuid);
drop table barberium.professional_charges;

drop function public.barberium_staff_invite_barber(uuid, text, text);
drop function public.barberium_invite_detail(uuid);
drop function barberium.login_orfao_do_convite(uuid, uuid, uuid);
delete from barberium.barbershop_invites where role = 'barber';
alter table barberium.barbershop_invites drop constraint barbershop_invites_professional_barbearia_fkey;
alter table barberium.barbershop_invites drop constraint barbershop_invites_barbeiro_tem_profissional;
alter table barberium.barbershop_invites drop constraint barbershop_invites_role_valido;
alter table barberium.barbershop_invites drop column professional_id;
alter table barberium.barbershop_invites add constraint barbershop_invites_role_valido check (role in ('owner', 'admin'));

-- As duas funções do painel, como eram na etapa 6B (20261021200000).
create or replace function public.barberium_platform_barbershops()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
begin
  perform barberium.exigir_dono_do_saas();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'slug', b.slug, 'name', b.name, 'status', b.status, 'created_at', b.created_at,
      'hosts', coalesce((select jsonb_agg(d.host order by d.host) from public.barbershop_domains d where d.barbershop_id = b.id), '[]'::jsonb),
      'units', coalesce((select jsonb_agg(jsonb_build_object('name', u.name, 'city', u.city, 'state', u.state, 'is_active', u.is_active) order by u.name)
                         from public.units u where u.barbershop_id = b.id), '[]'::jsonb),
      'managers', coalesce((select jsonb_agg(jsonb_build_object('email', au.email, 'role', m.role, 'is_active', m.is_active,
                                                                'last_sign_in_at', au.last_sign_in_at) order by au.email)
                            from public.barbershop_members m join auth.users au on au.id = m.auth_user_id
                            where m.barbershop_id = b.id and m.role in ('owner', 'admin')), '[]'::jsonb),
      'invites', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'full_name', i.full_name,
                                                               'whatsapp', i.whatsapp, 'created_at', i.created_at,
                                                               'link_generated_at', i.link_generated_at,
                                                               'last_sign_in_at', au.last_sign_in_at) order by i.created_at)
                           from barberium.barbershop_invites i left join auth.users au on au.id = i.auth_user_id
                           where i.barbershop_id = b.id), '[]'::jsonb),
      'staff_count', (select count(*) from public.barbershop_members m where m.barbershop_id = b.id and m.is_active)
    ) order by b.created_at, b.name)
    from public.barbershops b), '[]'::jsonb);
end
$function$;

create or replace function public.barberium_platform_link_invite(p_invite uuid, p_auth_user uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'barberium', 'auth', 'pg_temp'
as $function$
declare
  i barberium.barbershop_invites;
  v_email text;
begin
  select * into i from barberium.barbershop_invites where id = p_invite for update;
  if i.id is null then raise exception 'Convite não encontrado'; end if;
  select lower(email) into v_email from auth.users where id = p_auth_user;
  if v_email is null or v_email <> i.email then raise exception 'O login não é o do convite'; end if;
  insert into public.barbershop_members (barbershop_id, auth_user_id, role, is_active)
  values (i.barbershop_id, p_auth_user, i.role, true)
  on conflict (barbershop_id, auth_user_id) do update set is_active = true,
    role = case when public.barbershop_members.role in ('owner', 'admin') then public.barbershop_members.role else excluded.role end;
  update barberium.barbershop_invites set auth_user_id = p_auth_user, link_generated_at = now() where id = i.id;
  return jsonb_build_object('ok', true, 'barbershop_id', i.barbershop_id);
end
$function$;

delete from supabase_migrations.schema_migrations where version = '20261022100000';

commit;
