-- Barberium v11 follow-up já aplicado em produção.
-- Opções de pagamento e cadastro de provedores/maquininhas.

create or replace function public.barberium_staff_payment_options()
returns jsonb language plpgsql security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Sem acesso'; end if;
  return jsonb_build_object('providers',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'is_active',p.is_active,
      'fees',coalesce((select jsonb_agg(jsonb_build_object('method',r.method,'installments',r.installments,'percentage',r.percentage,'fixed_fee_cents',r.fixed_fee_cents) order by r.method,r.installments) from public.payment_fee_rules r where r.provider_id=p.id and r.is_active),'[]'::jsonb)
    ) order by p.name) from public.payment_providers p where p.barbershop_id=m.barbershop_id and p.is_active
  ),'[]'::jsonb));
end $$;

create or replace function public.barberium_staff_save_payment_provider(p_provider_id uuid,p_name text,p_is_active boolean default true,p_fee_rules jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v_id uuid; r jsonb; v_method text; v_inst int; v_pct numeric; v_fixed int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if trim(coalesce(p_name,''))='' then raise exception 'Informe o nome do provedor'; end if;
  if p_provider_id is null then
    insert into public.payment_providers(barbershop_id,name,is_active) values(m.barbershop_id,trim(p_name),coalesce(p_is_active,true))
    on conflict(barbershop_id,name) do update set is_active=excluded.is_active,updated_at=now() returning id into v_id;
  else
    update public.payment_providers set name=trim(p_name),is_active=coalesce(p_is_active,true),updated_at=now()
    where id=p_provider_id and barbershop_id=m.barbershop_id returning id into v_id;
    if v_id is null then raise exception 'Provedor inválido'; end if;
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_fee_rules,'[]'::jsonb)) loop
    v_method:=r->>'method'; v_inst:=coalesce((r->>'installments')::int,1); v_pct:=coalesce((r->>'percentage')::numeric,0); v_fixed:=coalesce((r->>'fixed_fee_cents')::int,0);
    if v_method not in ('pix','debit','credit') or v_inst<1 or v_pct<0 or v_fixed<0 then raise exception 'Regra de taxa inválida'; end if;
    insert into public.payment_fee_rules(provider_id,method,installments,percentage,fixed_fee_cents,is_active)
    values(v_id,v_method,v_inst,v_pct,v_fixed,coalesce((r->>'is_active')::boolean,true))
    on conflict(provider_id,method,installments) do update set percentage=excluded.percentage,fixed_fee_cents=excluded.fixed_fee_cents,is_active=excluded.is_active,updated_at=now();
  end loop;
  return jsonb_build_object('ok',true,'id',v_id);
end $$;
