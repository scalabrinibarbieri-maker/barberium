create or replace function public.barberium_staff_search_customers(p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; perms jsonb; show_phone boolean; show_full boolean; show_birthday boolean; q text; q_digits text; result jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  perms:=case when m.role in ('owner','admin') then barberium.default_barber_permissions() else barberium.effective_permissions(m.professional_id) end;
  if m.role not in ('owner','admin') and not barberium.permission_enabled(perms,'create_appointment') then raise exception 'Sem permissão para criar agendamentos'; end if;
  show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_phone');
  show_full:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_full_name');
  show_birthday:=m.role in ('owner','admin') or barberium.permission_enabled(perms,'view_birthday');
  q:=trim(coalesce(p_query,'')); q_digits:=regexp_replace(q,'\D','','g');
  select coalesce(jsonb_agg(x order by x->>'name'),'[]'::jsonb) into result
  from (
    select jsonb_build_object('id',c.id,'name',barberium.mask_customer_name(c.full_name,show_full),'phone',case when show_phone then c.phone_e164 else null end,'birthday',case when show_birthday then c.birthday else null end) x
    from public.customers c
    where c.barbershop_id=m.barbershop_id and (q='' or c.full_name ilike '%'||q||'%' or (q_digits<>'' and c.phone_e164 like '%'||q_digits||'%'))
    order by c.full_name limit 20
  ) s;
  return result;
end;
$$;

