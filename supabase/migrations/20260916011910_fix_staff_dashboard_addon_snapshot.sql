create or replace function public.barberium_staff_dashboard(p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare
  m record;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_items jsonb;
  v_summary jsonb;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then
    raise exception 'Usuário sem acesso à equipe';
  end if;

  select timezone into v_tz from public.barbershops where id = m.barbershop_id;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');
  v_start := (p_date::timestamp at time zone v_tz);
  v_end := ((p_date + 1)::timestamp at time zone v_tz);

  select coalesce(jsonb_agg(x order by x->>'starts_at'), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', a.id,
      'starts_at', a.starts_at,
      'ends_at', a.ends_at,
      'status', a.status,
      'total_price_cents', a.total_price_cents,
      'service', s.name,
      'professional_id', p.id,
      'professional', p.name,
      'customer', c.full_name,
      'phone', c.phone_e164,
      'addons', coalesce((
        select jsonb_agg(jsonb_build_object('name', aa.name_snapshot, 'price_cents', aa.price_cents) order by aa.name_snapshot)
        from public.appointment_addons aa
        where aa.appointment_id = a.id
      ), '[]'::jsonb)
    ) as x
    from public.appointments a
    join public.services s on s.id = a.service_id
    join public.professionals p on p.id = a.professional_id
    join public.customers c on c.id = a.customer_id
    where a.barbershop_id = m.barbershop_id
      and a.starts_at >= v_start
      and a.starts_at < v_end
      and (m.role in ('owner','admin') or a.professional_id = m.professional_id)
  ) q;

  select jsonb_build_object(
    'total', count(*),
    'confirmed', count(*) filter (where status='confirmed'),
    'completed', count(*) filter (where status='completed'),
    'cancelled', count(*) filter (where status='cancelled'),
    'no_show', count(*) filter (where status='no_show'),
    'revenue_cents', coalesce(sum(total_price_cents) filter (where status in ('confirmed','completed')),0)
  )
  into v_summary
  from public.appointments a
  where a.barbershop_id = m.barbershop_id
    and a.starts_at >= v_start
    and a.starts_at < v_end
    and (m.role in ('owner','admin') or a.professional_id = m.professional_id);

  return jsonb_build_object(
    'date', p_date,
    'member', jsonb_build_object(
      'role', m.role,
      'professional_id', m.professional_id,
      'professional_name', m.professional_name
    ),
    'summary', v_summary,
    'appointments', v_items
  );
end;
$$;

