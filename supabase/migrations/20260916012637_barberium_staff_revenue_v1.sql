create or replace function public.barberium_staff_dashboard(p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
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
    'scheduled_revenue_cents', coalesce(sum(total_price_cents) filter (where status='confirmed'),0),
    'realized_revenue_cents', coalesce(sum(total_price_cents) filter (where status='completed'),0),
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

create or replace function public.barberium_staff_performance(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare
  m record;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_summary jsonb;
  v_services jsonb;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  if p_end_date < p_start_date then
    raise exception 'Período inválido';
  end if;

  if (p_end_date - p_start_date) > 366 then
    raise exception 'Período máximo de 366 dias';
  end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then
    raise exception 'Usuário sem acesso à equipe';
  end if;

  if m.role = 'barber' and m.professional_id is null then
    raise exception 'Barbeiro sem profissional vinculado';
  end if;

  select timezone into v_tz from public.barbershops where id = m.barbershop_id;
  v_tz := coalesce(v_tz, 'America/Sao_Paulo');
  v_start := (p_start_date::timestamp at time zone v_tz);
  v_end := ((p_end_date + 1)::timestamp at time zone v_tz);

  select jsonb_build_object(
    'appointments', count(*),
    'confirmed', count(*) filter (where a.status='confirmed'),
    'completed', count(*) filter (where a.status='completed'),
    'cancelled', count(*) filter (where a.status='cancelled'),
    'no_show', count(*) filter (where a.status='no_show'),
    'scheduled_revenue_cents', coalesce(sum(a.total_price_cents) filter (where a.status='confirmed'),0),
    'realized_revenue_cents', coalesce(sum(a.total_price_cents) filter (where a.status='completed'),0),
    'total_revenue_cents', coalesce(sum(a.total_price_cents) filter (where a.status in ('confirmed','completed')),0),
    'average_ticket_cents', case
      when count(*) filter (where a.status='completed') > 0
      then round((coalesce(sum(a.total_price_cents) filter (where a.status='completed'),0)::numeric / (count(*) filter (where a.status='completed'))))::int
      else 0
    end
  ) into v_summary
  from public.appointments a
  where a.barbershop_id = m.barbershop_id
    and a.starts_at >= v_start
    and a.starts_at < v_end
    and (m.role in ('owner','admin') or a.professional_id = m.professional_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'service', q.service,
    'appointments', q.appointments,
    'completed', q.completed,
    'scheduled_revenue_cents', q.scheduled_revenue_cents,
    'realized_revenue_cents', q.realized_revenue_cents
  ) order by q.appointments desc, q.service), '[]'::jsonb)
  into v_services
  from (
    select
      s.name as service,
      count(*) as appointments,
      count(*) filter (where a.status='completed') as completed,
      coalesce(sum(a.total_price_cents) filter (where a.status='confirmed'),0)::bigint as scheduled_revenue_cents,
      coalesce(sum(a.total_price_cents) filter (where a.status='completed'),0)::bigint as realized_revenue_cents
    from public.appointments a
    join public.services s on s.id = a.service_id
    where a.barbershop_id = m.barbershop_id
      and a.starts_at >= v_start
      and a.starts_at < v_end
      and a.status in ('confirmed','completed')
      and (m.role in ('owner','admin') or a.professional_id = m.professional_id)
    group by s.id, s.name
  ) q;

  return jsonb_build_object(
    'start_date', p_start_date,
    'end_date', p_end_date,
    'scope', case when m.role='barber' then 'own' else 'shop' end,
    'member', jsonb_build_object(
      'role', m.role,
      'professional_id', m.professional_id,
      'professional_name', m.professional_name
    ),
    'summary', v_summary,
    'services', v_services
  );
end;
$$;

revoke all on function public.barberium_staff_performance(date,date) from public, anon;
grant execute on function public.barberium_staff_performance(date,date) to authenticated;
revoke all on function public.barberium_staff_dashboard(date) from public, anon;
grant execute on function public.barberium_staff_dashboard(date) to authenticated;

