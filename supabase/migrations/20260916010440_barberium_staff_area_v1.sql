create or replace function barberium.staff_membership()
returns table (
  member_id uuid,
  barbershop_id uuid,
  barbershop_name text,
  role text,
  professional_id uuid,
  professional_name text,
  is_active boolean
)
language sql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
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
$$;

create or replace function public.barberium_staff_me()
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare
  m record;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then
    raise exception 'Usuário sem acesso à equipe';
  end if;

  return jsonb_build_object(
    'member_id', m.member_id,
    'barbershop_id', m.barbershop_id,
    'barbershop_name', m.barbershop_name,
    'role', m.role,
    'professional_id', m.professional_id,
    'professional_name', m.professional_name
  );
end;
$$;

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
      'phone', c.phone,
      'addons', coalesce((
        select jsonb_agg(jsonb_build_object('name', aa.name, 'price_cents', aa.price_cents) order by aa.name)
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

create or replace function public.barberium_staff_set_appointment_status(
  p_appointment_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare
  m record;
  a public.appointments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;
  if p_status not in ('confirmed','completed','cancelled','no_show') then
    raise exception 'Status inválido';
  end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then
    raise exception 'Usuário sem acesso à equipe';
  end if;

  select * into a from public.appointments where id = p_appointment_id for update;
  if a.id is null or a.barbershop_id <> m.barbershop_id then
    raise exception 'Agendamento não encontrado';
  end if;
  if m.role not in ('owner','admin') and a.professional_id <> m.professional_id then
    raise exception 'Sem permissão para este agendamento';
  end if;

  update public.appointments
  set status = p_status,
      cancelled_at = case when p_status='cancelled' then now() else null end,
      updated_at = now()
  where id = p_appointment_id;

  return jsonb_build_object('ok',true,'appointment_id',p_appointment_id,'status',p_status);
end;
$$;

create or replace function public.barberium_staff_upcoming(p_days integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium, auth, pg_temp
as $$
declare
  m record;
  v_items jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  select coalesce(jsonb_agg(x order by x->>'starts_at'), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id',a.id,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,
      'service',s.name,'professional',p.name,'customer',c.full_name,'phone',c.phone,
      'total_price_cents',a.total_price_cents
    ) x
    from public.appointments a
    join public.services s on s.id=a.service_id
    join public.professionals p on p.id=a.professional_id
    join public.customers c on c.id=a.customer_id
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=now()
      and a.starts_at<now() + make_interval(days=>greatest(1,least(coalesce(p_days,7),31)))
      and a.status='confirmed'
      and (m.role in ('owner','admin') or a.professional_id=m.professional_id)
  ) q;
  return v_items;
end;
$$;

revoke all on function public.barberium_staff_me() from public, anon;
revoke all on function public.barberium_staff_dashboard(date) from public, anon;
revoke all on function public.barberium_staff_set_appointment_status(uuid,text) from public, anon;
revoke all on function public.barberium_staff_upcoming(integer) from public, anon;

grant execute on function public.barberium_staff_me() to authenticated;
grant execute on function public.barberium_staff_dashboard(date) to authenticated;
grant execute on function public.barberium_staff_set_appointment_status(uuid,text) to authenticated;
grant execute on function public.barberium_staff_upcoming(integer) to authenticated;

create index if not exists idx_members_auth_active on public.barbershop_members(auth_user_id) where is_active=true;

