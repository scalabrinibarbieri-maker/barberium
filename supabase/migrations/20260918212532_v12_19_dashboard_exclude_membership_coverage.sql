
create or replace function public.barberium_staff_dashboard(p_date date default current_date, p_professional_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $function$
declare
  m record;
  v_permissions jsonb;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_filter_prof uuid;
  v_appointments jsonb;
  v_blocks jsonb;
  v_summary jsonb;
  v_show_phone boolean;
  v_show_full boolean;
  v_show_value boolean;
  v_show_note boolean;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;

  v_permissions:=case when m.role in ('owner','admin')
    then barberium.default_barber_permissions()
    else barberium.effective_permissions(m.professional_id)
  end;

  v_show_phone:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_phone');
  v_show_full:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_full_name');
  v_show_value:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_value');
  v_show_note:=m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_internal_note');

  if m.role in ('owner','admin') then
    if p_professional_id is not null and not exists(
      select 1 from public.professionals p
      where p.id=p_professional_id and p.barbershop_id=m.barbershop_id and p.is_active
    ) then raise exception 'Profissional inválido'; end if;
    v_filter_prof:=p_professional_id;
  else
    v_filter_prof:=m.professional_id;
  end if;

  select coalesce(timezone,'America/Sao_Paulo')
  into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  v_start:=p_date::timestamp at time zone v_tz;
  v_end:=(p_date+1)::timestamp at time zone v_tz;

  select coalesce(jsonb_agg(x order by (x->>'starts_at')::timestamptz),'[]'::jsonb)
  into v_appointments
  from (
    select jsonb_build_object(
      'kind','appointment',
      'id',a.id,
      'is_walk_in',a.is_walk_in,
      'blocks_schedule',a.blocks_schedule,
      'starts_at',a.starts_at,
      'ends_at',a.ends_at,
      'status',a.status,
      'service_id',s.id,
      'service',concat_ws(
        ' + ',
        coalesce(a.service_name_snapshot,s.name),
        nullif((
          select string_agg(aa.name_snapshot,' + ' order by aa.name_snapshot)
          from public.appointment_addons aa
          where aa.appointment_id=a.id and aa.item_kind='service'
        ),'')
      ),
      'extra_services',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'service_id',aa.service_id,
            'name',aa.name_snapshot,
            'price_cents',case when v_show_value then aa.price_cents else null end,
            'duration_min',aa.duration_min
          )
          order by aa.name_snapshot
        )
        from public.appointment_addons aa
        where aa.appointment_id=a.id and aa.item_kind='service'
      ),'[]'::jsonb),
      'professional_id',p.id,
      'professional',coalesce(a.professional_name_snapshot,p.name),
      'customer',barberium.mask_customer_name(c.full_name,v_show_full),
      'phone',case when v_show_phone then c.phone_e164 else null end,
      'total_price_cents',case when v_show_value then a.total_price_cents else null end,
      'internal_note',case when v_show_note then a.internal_note else null end,
      'addons',coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'service_id',aa.service_id,
            'name',aa.name_snapshot,
            'price_cents',case when v_show_value then aa.price_cents else null end,
            'duration_min',aa.duration_min
          )
          order by aa.name_snapshot
        )
        from public.appointment_addons aa
        where aa.appointment_id=a.id and aa.item_kind='addon'
      ),'[]'::jsonb)
    ) x
    from public.appointments a
    join public.services s on s.id=a.service_id
    join public.professionals p on p.id=a.professional_id
    join public.customers c on c.id=a.customer_id
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and (v_filter_prof is null or a.professional_id=v_filter_prof)
  ) q;

  select coalesce(jsonb_agg(x order by (x->>'starts_at')::timestamptz),'[]'::jsonb)
  into v_blocks
  from (
    select jsonb_build_object(
      'kind','block','block_type','single','id',bt.id,
      'starts_at',bt.starts_at,'ends_at',bt.ends_at,'reason',bt.reason,
      'professional_id',p.id,'professional',p.name,'recurring',false
    ) x
    from public.blocked_times bt
    join public.professionals p on p.id=bt.professional_id
    where bt.barbershop_id=m.barbershop_id
      and bt.starts_at<v_end and bt.ends_at>v_start
      and (v_filter_prof is null or bt.professional_id=v_filter_prof)
    union all
    select jsonb_build_object(
      'kind','block','block_type','recurring','id',bs.id,
      'starts_at',(p_date::timestamp+bs.start_time) at time zone v_tz,
      'ends_at',(p_date::timestamp+bs.end_time) at time zone v_tz,
      'reason',bs.reason,'professional_id',p.id,'professional',p.name,
      'recurring',true,'starts_on',bs.starts_on,'ends_on',bs.ends_on
    ) x
    from public.blocked_time_series bs
    join public.professionals p on p.id=bs.professional_id
    where bs.barbershop_id=m.barbershop_id
      and bs.is_active
      and p_date>=bs.starts_on
      and (bs.ends_on is null or p_date<=bs.ends_on)
      and bs.weekday=extract(dow from p_date)::int
      and (v_filter_prof is null or bs.professional_id=v_filter_prof)
  ) q;

  with day_appointments as (
    select
      a.status,
      greatest(
        0,
        a.total_price_cents
        - coalesce((
            select sum(u.coverage_cents)
            from public.appointment_membership_uses u
            where u.appointment_id=a.id
              and (
                (a.status='confirmed' and u.status='reserved')
                or
                (a.status='completed' and u.status='consumed')
              )
          ),0)
      )::int cash_revenue_cents
    from public.appointments a
    where a.barbershop_id=m.barbershop_id
      and a.starts_at>=v_start
      and a.starts_at<v_end
      and (v_filter_prof is null or a.professional_id=v_filter_prof)
  )
  select jsonb_build_object(
    'total',count(*),
    'confirmed',count(*) filter(where status='confirmed'),
    'completed',count(*) filter(where status='completed'),
    'cancelled',count(*) filter(where status='cancelled'),
    'no_show',count(*) filter(where status='no_show'),
    'scheduled_revenue_cents',case
      when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue')
      then coalesce(sum(cash_revenue_cents) filter(where status='confirmed'),0)
      else null end,
    'realized_revenue_cents',case
      when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue')
      then coalesce(sum(cash_revenue_cents) filter(where status='completed'),0)
      else null end,
    'revenue_cents',case
      when m.role in ('owner','admin') or barberium.permission_enabled(v_permissions,'view_own_revenue')
      then coalesce(sum(cash_revenue_cents) filter(where status in ('confirmed','completed')),0)
      else null end
  )
  into v_summary
  from day_appointments;

  return jsonb_build_object(
    'date',p_date,
    'filter_professional_id',v_filter_prof,
    'member',jsonb_build_object(
      'role',m.role,
      'professional_id',m.professional_id,
      'professional_name',m.professional_name,
      'permissions',v_permissions
    ),
    'summary',v_summary,
    'appointments',v_appointments,
    'blocks',v_blocks
  );
end
$function$;

revoke all on function public.barberium_staff_dashboard(date,uuid) from public,anon;
grant execute on function public.barberium_staff_dashboard(date,uuid) to authenticated,service_role;

