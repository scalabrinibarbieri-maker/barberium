
create or replace function public.barberium_staff_balance_quick(
  p_start date default current_date,
  p_end date default current_date,
  p_unit_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, barberium
as $$
declare
  m record;
  v_tz text;
  v_is_manager boolean := false;
  v_can_view_own boolean := false;

  v_service_gross integer := 0;
  v_service_fees integer := 0;
  v_service_refunds integer := 0;

  v_product_gross integer := 0;
  v_product_fees integer := 0;
  v_product_refunds integer := 0;

  v_membership_gross integer := 0;
  v_membership_fees integer := 0;
  v_membership_refunds integer := 0;

  v_commissions integer := 0;
  v_professionals jsonb := '[]'::jsonb;
  v_entries jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  if p_start is null or p_end is null or p_start > p_end then
    raise exception 'Período inválido';
  end if;

  select * into m from barberium.staff_membership();
  if m.member_id is null then
    raise exception 'Sem acesso';
  end if;

  select coalesce(timezone,'America/Sao_Paulo')
    into v_tz
  from public.barbershops
  where id=m.barbershop_id;

  perform set_config('TimeZone',coalesce(v_tz,'America/Sao_Paulo'),true);

  v_is_manager := m.role in ('owner','admin');

  if not v_is_manager then
    if m.professional_id is null then
      raise exception 'Profissional não vinculado';
    end if;

    select coalesce((pp.permissions->>'view_own_commission')::boolean,false)
      into v_can_view_own
    from public.professional_permissions pp
    where pp.barbershop_id=m.barbershop_id
      and pp.professional_id=m.professional_id;

    if not coalesce(v_can_view_own,false) then
      raise exception 'Sem permissão para visualizar comissões';
    end if;
  end if;

  if p_unit_id is not null and not exists(
    select 1 from public.units u
    where u.id=p_unit_id and u.barbershop_id=m.barbershop_id
  ) then
    raise exception 'Unidade inválida';
  end if;

  if v_is_manager then
    select coalesce(sum(ap.amount_cents),0)::int,
           coalesce(sum(ap.fee_cents),0)::int
      into v_service_gross,v_service_fees
    from public.appointment_payments ap
    where ap.barbershop_id=m.barbershop_id
      and ap.received_at::date between p_start and p_end
      and (p_unit_id is null or ap.unit_id=p_unit_id);

    select coalesce(sum(psp.amount_cents),0)::int,
           coalesce(sum(psp.fee_cents),0)::int
      into v_product_gross,v_product_fees
    from public.product_sale_payments psp
    where psp.barbershop_id=m.barbershop_id
      and psp.received_at::date between p_start and p_end
      and (p_unit_id is null or psp.unit_id=p_unit_id);

    select coalesce(sum(mp.amount_cents),0)::int,
           coalesce(sum(mp.fee_cents),0)::int
      into v_membership_gross,v_membership_fees
    from public.membership_payments mp
    join public.customer_memberships cm on cm.id=mp.membership_id
    where cm.barbershop_id=m.barbershop_id
      and mp.paid_at::date between p_start and p_end
      and (p_unit_id is null or cm.origin_unit_id=p_unit_id);

    select
      coalesce(sum(fr.amount_cents) filter (
        where fr.appointment_id is not null
          and fr.product_sale_id is null
          and fr.membership_id is null
      ),0)::int,
      coalesce(sum(fr.amount_cents) filter (
        where fr.product_sale_id is not null
      ),0)::int,
      coalesce(sum(fr.amount_cents) filter (
        where fr.membership_id is not null
      ),0)::int
      into v_service_refunds,v_product_refunds,v_membership_refunds
    from public.finance_refunds fr
    where fr.barbershop_id=m.barbershop_id
      and fr.created_at::date between p_start and p_end
      and (p_unit_id is null or fr.unit_id=p_unit_id);
  end if;

  select coalesce(sum(ce.amount_cents),0)::int
    into v_commissions
  from public.commission_entries ce
  where ce.barbershop_id=m.barbershop_id
    and ce.created_at::date between p_start and p_end
    and (p_unit_id is null or ce.unit_id=p_unit_id)
    and (v_is_manager or ce.professional_id=m.professional_id);

  with pro_keys as (
    select p.id,p.name,p.image_path,p.sort_order
    from public.professionals p
    where p.barbershop_id=m.barbershop_id
      and p.is_active=true
      and (v_is_manager or p.id=m.professional_id)
      and (
        p_unit_id is null
        or p.unit_id=p_unit_id
        or exists(
          select 1
          from public.commission_entries ce
          where ce.professional_id=p.id
            and ce.barbershop_id=m.barbershop_id
            and ce.unit_id=p_unit_id
            and ce.created_at::date between p_start and p_end
        )
      )
  ),
  sums as (
    select
      ce.professional_id,
      coalesce(sum(ce.amount_cents),0)::int as commission_cents,
      coalesce(sum(ce.amount_cents) filter (
        where ce.source_type in ('service','appointment_cancellation')
      ),0)::int as service_commission_cents,
      coalesce(sum(ce.amount_cents) filter (
        where ce.source_type='product_sale'
      ),0)::int as product_commission_cents,
      coalesce(sum(ce.amount_cents) filter (
        where ce.source_type='membership_usage'
      ),0)::int as membership_commission_cents
    from public.commission_entries ce
    where ce.barbershop_id=m.barbershop_id
      and ce.created_at::date between p_start and p_end
      and (p_unit_id is null or ce.unit_id=p_unit_id)
      and (v_is_manager or ce.professional_id=m.professional_id)
    group by ce.professional_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'professional_id',k.id,
      'name',k.name,
      'image_path',k.image_path,
      'commission_cents',coalesce(s.commission_cents,0),
      'service_commission_cents',coalesce(s.service_commission_cents,0),
      'product_commission_cents',coalesce(s.product_commission_cents,0),
      'membership_commission_cents',coalesce(s.membership_commission_cents,0)
    )
    order by k.sort_order,k.name
  ),'[]'::jsonb)
  into v_professionals
  from pro_keys k
  left join sums s on s.professional_id=k.id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',ce.id,
      'professional_id',ce.professional_id,
      'professional',p.name,
      'category',case
        when ce.source_type='product_sale' then 'products'
        when ce.source_type='membership_usage' then 'memberships'
        else 'services'
      end,
      'source_type',ce.source_type,
      'description',ce.description,
      'amount_cents',ce.amount_cents,
      'status',ce.status,
      'created_at',ce.created_at
    )
    order by ce.created_at desc
  ),'[]'::jsonb)
  into v_entries
  from public.commission_entries ce
  join public.professionals p on p.id=ce.professional_id
  where ce.barbershop_id=m.barbershop_id
    and ce.created_at::date between p_start and p_end
    and (p_unit_id is null or ce.unit_id=p_unit_id)
    and (v_is_manager or ce.professional_id=m.professional_id);

  return jsonb_build_object(
    'start',p_start,
    'end',p_end,
    'timezone',v_tz,
    'role',case when v_is_manager then 'manager' else 'barber' end,
    'unit_id',p_unit_id,
    'categories',jsonb_build_object(
      'services',jsonb_build_object(
        'gross_cents',v_service_gross,
        'refunds_cents',v_service_refunds,
        'fees_cents',v_service_fees,
        'net_cents',v_service_gross-v_service_refunds-v_service_fees
      ),
      'products',jsonb_build_object(
        'gross_cents',v_product_gross,
        'refunds_cents',v_product_refunds,
        'fees_cents',v_product_fees,
        'net_cents',v_product_gross-v_product_refunds-v_product_fees
      ),
      'memberships',jsonb_build_object(
        'gross_cents',v_membership_gross,
        'refunds_cents',v_membership_refunds,
        'fees_cents',v_membership_fees,
        'net_cents',v_membership_gross-v_membership_refunds-v_membership_fees
      )
    ),
    'net_received_cents',
      (v_service_gross-v_service_refunds-v_service_fees)
      +(v_product_gross-v_product_refunds-v_product_fees)
      +(v_membership_gross-v_membership_refunds-v_membership_fees),
    'commissions_cents',v_commissions,
    'house_cents',case when v_is_manager then
      (v_service_gross-v_service_refunds-v_service_fees)
      +(v_product_gross-v_product_refunds-v_product_fees)
      +(v_membership_gross-v_membership_refunds-v_membership_fees)
      -v_commissions
      else null end,
    'professionals',v_professionals,
    'entries',v_entries
  );
end;
$$;

revoke all on function public.barberium_staff_balance_quick(date,date,uuid) from public;
grant execute on function public.barberium_staff_balance_quick(date,date,uuid) to authenticated;

