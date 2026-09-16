-- Barberium v12.2 — fechamento, ajustes e pagamento de comissões

alter table public.commission_settlements
  add column if not exists base_cents integer not null default 0,
  add column if not exists adjustment_cents integer not null default 0,
  add column if not exists note text,
  add column if not exists updated_at timestamptz not null default now();

update public.commission_settlements cs
set base_cents = coalesce(x.base_cents, cs.total_cents),
    adjustment_cents = cs.total_cents - coalesce(x.base_cents, cs.total_cents)
from (
  select settlement_id, coalesce(sum(amount_cents),0)::int base_cents
  from public.commission_entries
  where settlement_id is not null
  group by settlement_id
) x
where cs.id=x.settlement_id
  and cs.base_cents=0;

create table if not exists public.commission_settlement_adjustments (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.commission_settlements(id) on delete cascade,
  amount_cents integer not null check (amount_cents <> 0),
  reason text not null check (length(trim(reason)) > 0),
  actor_member_id uuid references public.barbershop_members(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.commission_settlement_adjustments enable row level security;
create index if not exists commission_settlement_adjustments_settlement_idx
  on public.commission_settlement_adjustments(settlement_id, created_at);
create index if not exists commission_settlements_prof_status_period_idx
  on public.commission_settlements(professional_id,status,period_end desc);

create or replace function public.barberium_staff_commission_preview(
  p_professional_id uuid,
  p_start date,
  p_end date
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v_prof record; v_count int; v_total int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if;
  select p.id,p.name,p.unit_id into v_prof from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id;
  if v_prof.id is null then raise exception 'Profissional inválido'; end if;
  select count(*)::int,coalesce(sum(ce.amount_cents),0)::int into v_count,v_total
  from public.commission_entries ce
  where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id
    and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_start and p_end;
  return jsonb_build_object(
    'professional',jsonb_build_object('id',v_prof.id,'name',v_prof.name,'unit_id',v_prof.unit_id),
    'period_start',p_start,'period_end',p_end,'count',v_count,'total_cents',v_total,
    'entries',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',ce.id,'created_at',ce.created_at,'amount_cents',ce.amount_cents,'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,
        'source_type',ce.source_type,'description',ce.description,'appointment_id',ce.appointment_id,
        'appointment',case when a.id is null then null else jsonb_build_object(
          'starts_at',a.starts_at,
          'customer',coalesce(c.full_name,'Cliente'),
          'service',coalesce(a.service_name_snapshot,s.name,'Serviço'),
          'unit',coalesce(a.unit_name_snapshot,u.name),
          'total_price_cents',a.total_price_cents
        ) end
      ) order by ce.created_at,ce.id)
      from public.commission_entries ce
      left join public.appointments a on a.id=ce.appointment_id
      left join public.customers c on c.id=a.customer_id
      left join public.services s on s.id=a.service_id
      left join public.units u on u.id=ce.unit_id
      where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id
        and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_start and p_end
    ),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_create_commission_settlement(
  p_professional_id uuid,
  p_period_start date,
  p_period_end date,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v_prof record; v_total int; v_count int; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if p_period_start is null or p_period_end is null or p_period_end<p_period_start then raise exception 'Período inválido'; end if;
  select p.id,p.name into v_prof from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id;
  if v_prof.id is null then raise exception 'Profissional inválido'; end if;

  perform 1 from public.commission_entries ce
   where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id
     and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_period_start and p_period_end
   for update;

  select count(*)::int,coalesce(sum(ce.amount_cents),0)::int into v_count,v_total
  from public.commission_entries ce
  where ce.barbershop_id=m.barbershop_id and ce.professional_id=p_professional_id
    and ce.status='open' and ce.settlement_id is null and ce.created_at::date between p_period_start and p_period_end;
  if v_count=0 then raise exception 'Nenhuma comissão em aberto neste período'; end if;
  if v_total<0 then raise exception 'O total em aberto deste período não pode ser negativo'; end if;

  insert into public.commission_settlements(
    barbershop_id,professional_id,period_start,period_end,base_cents,adjustment_cents,total_cents,paid_cents,status,note,created_by_member_id
  ) values (
    m.barbershop_id,p_professional_id,p_period_start,p_period_end,v_total,0,v_total,0,'open',nullif(trim(coalesce(p_note,'')),''),m.member_id
  ) returning id into v_id;

  update public.commission_entries
  set settlement_id=v_id,status='settled'
  where barbershop_id=m.barbershop_id and professional_id=p_professional_id
    and status='open' and settlement_id is null and created_at::date between p_period_start and p_period_end;

  return jsonb_build_object('ok',true,'settlement_id',v_id,'entries',v_count,'total_cents',v_total);
end $$;

create or replace function public.barberium_staff_commission_settlements(
  p_professional_id uuid default null,
  p_start date default (current_date - interval '12 months')::date,
  p_end date default current_date
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if p_start is null or p_end is null or p_end<p_start then raise exception 'Período inválido'; end if;
  if p_professional_id is not null and not exists(select 1 from public.professionals p where p.id=p_professional_id and p.barbershop_id=m.barbershop_id) then raise exception 'Profissional inválido'; end if;
  return jsonb_build_object(
    'professionals',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',p.id,'name',p.name,'unit_id',p.unit_id,
        'unsettled_cents',coalesce(oe.amount,0),
        'in_settlement_cents',coalesce(os.amount,0),
        'due_cents',coalesce(oe.amount,0)+coalesce(os.amount,0)
      ) order by p.sort_order,p.name)
      from public.professionals p
      left join lateral (
        select coalesce(sum(ce.amount_cents),0)::int amount from public.commission_entries ce
        where ce.professional_id=p.id and ce.status='open' and ce.settlement_id is null
      ) oe on true
      left join lateral (
        select coalesce(sum(greatest(0,cs.total_cents-cs.paid_cents)),0)::int amount from public.commission_settlements cs
        where cs.professional_id=p.id and cs.status in ('open','partial')
      ) os on true
      where p.barbershop_id=m.barbershop_id and p.is_active
    ),'[]'::jsonb),
    'settlements',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',cs.id,'professional_id',cs.professional_id,'professional',p.name,
        'period_start',cs.period_start,'period_end',cs.period_end,
        'base_cents',cs.base_cents,'adjustment_cents',cs.adjustment_cents,'total_cents',cs.total_cents,
        'paid_cents',cs.paid_cents,'remaining_cents',greatest(0,cs.total_cents-cs.paid_cents),
        'status',cs.status,'note',cs.note,'created_at',cs.created_at,'closed_at',cs.closed_at
      ) order by cs.period_end desc,cs.created_at desc)
      from public.commission_settlements cs join public.professionals p on p.id=cs.professional_id
      where cs.barbershop_id=m.barbershop_id
        and (p_professional_id is null or cs.professional_id=p_professional_id)
        and cs.period_end>=p_start and cs.period_start<=p_end
    ),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_commission_settlement_detail(p_settlement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
  select cs.*,p.name professional,p.unit_id into v
  from public.commission_settlements cs join public.professionals p on p.id=cs.professional_id
  where cs.id=p_settlement_id and cs.barbershop_id=m.barbershop_id;
  if v.id is null then raise exception 'Acerto não encontrado'; end if;
  if m.role='barber' and v.professional_id<>m.professional_id then raise exception 'Sem acesso'; end if;
  return jsonb_build_object(
    'settlement',jsonb_build_object(
      'id',v.id,'professional_id',v.professional_id,'professional',v.professional,'unit_id',v.unit_id,
      'period_start',v.period_start,'period_end',v.period_end,'base_cents',v.base_cents,'adjustment_cents',v.adjustment_cents,
      'total_cents',v.total_cents,'paid_cents',v.paid_cents,'remaining_cents',greatest(0,v.total_cents-v.paid_cents),
      'status',v.status,'note',v.note,'created_at',v.created_at,'closed_at',v.closed_at
    ),
    'entries',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',ce.id,'created_at',ce.created_at,'description',ce.description,'source_type',ce.source_type,
        'base_cents',ce.base_cents,'rate_percent',ce.rate_percent,'amount_cents',ce.amount_cents,'appointment_id',ce.appointment_id,
        'appointment',case when a.id is null then null else jsonb_build_object(
          'starts_at',a.starts_at,'customer',coalesce(c.full_name,'Cliente'),
          'service',coalesce(a.service_name_snapshot,s.name,'Serviço'),'total_price_cents',a.total_price_cents
        ) end
      ) order by ce.created_at,ce.id)
      from public.commission_entries ce
      left join public.appointments a on a.id=ce.appointment_id
      left join public.customers c on c.id=a.customer_id
      left join public.services s on s.id=a.service_id
      where ce.settlement_id=v.id
    ),'[]'::jsonb),
    'adjustments',coalesce((
      select jsonb_agg(jsonb_build_object('id',a.id,'amount_cents',a.amount_cents,'reason',a.reason,'created_at',a.created_at,'actor',coalesce(pr.name,bm.role)) order by a.created_at)
      from public.commission_settlement_adjustments a left join public.barbershop_members bm on bm.id=a.actor_member_id left join public.professionals pr on pr.id=bm.professional_id
      where a.settlement_id=v.id
    ),'[]'::jsonb),
    'payments',coalesce((
      select jsonb_agg(jsonb_build_object('id',p.id,'amount_cents',p.amount_cents,'payment_method',p.payment_method,'paid_at',p.paid_at,'note',p.note,'actor',coalesce(pr.name,bm.role)) order by p.paid_at)
      from public.commission_settlement_payments p left join public.barbershop_members bm on bm.id=p.actor_member_id left join public.professionals pr on pr.id=bm.professional_id
      where p.settlement_id=v.id
    ),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_adjust_commission_settlement(
  p_settlement_id uuid,
  p_amount_cents integer,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v record; v_adj int; v_total int; v_status text;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if coalesce(p_amount_cents,0)=0 then raise exception 'Ajuste não pode ser zero'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Motivo obrigatório'; end if;
  select * into v from public.commission_settlements where id=p_settlement_id and barbershop_id=m.barbershop_id for update;
  if v.id is null then raise exception 'Acerto não encontrado'; end if;
  if v.status='paid' then raise exception 'Acerto já pago não pode ser alterado'; end if;
  insert into public.commission_settlement_adjustments(settlement_id,amount_cents,reason,actor_member_id)
  values(v.id,p_amount_cents,trim(p_reason),m.member_id);
  select coalesce(sum(amount_cents),0)::int into v_adj from public.commission_settlement_adjustments where settlement_id=v.id;
  v_total:=v.base_cents+v_adj;
  if v_total<0 then raise exception 'O total do acerto não pode ficar negativo'; end if;
  if v_total<v.paid_cents then raise exception 'O total ajustado não pode ficar abaixo do valor já pago'; end if;
  v_status:=case when v_total=v.paid_cents then 'paid' when v.paid_cents>0 then 'partial' else 'open' end;
  update public.commission_settlements set adjustment_cents=v_adj,total_cents=v_total,status=v_status,
    closed_at=case when v_status='paid' then coalesce(closed_at,now()) else null end,updated_at=now() where id=v.id;
  return jsonb_build_object('ok',true,'adjustment_cents',v_adj,'total_cents',v_total,'paid_cents',v.paid_cents,'status',v_status);
end $$;

create or replace function public.barberium_staff_record_commission_settlement_payment(
  p_settlement_id uuid,
  p_amount_cents integer default null,
  p_payment_method text default 'pix',
  p_paid_at timestamptz default now(),
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; v record; v_amount int; v_remaining int; v_paid int; v_status text; v_unit uuid; v_session uuid; v_payment uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if p_payment_method not in ('pix','cash','transfer','other') then raise exception 'Forma de pagamento inválida'; end if;
  select cs.*,p.unit_id into v from public.commission_settlements cs join public.professionals p on p.id=cs.professional_id
  where cs.id=p_settlement_id and cs.barbershop_id=m.barbershop_id for update of cs;
  if v.id is null then raise exception 'Acerto não encontrado'; end if;
  v_remaining:=greatest(0,v.total_cents-v.paid_cents);
  if v_remaining=0 then raise exception 'Acerto já pago'; end if;
  v_amount:=coalesce(p_amount_cents,v_remaining);
  if v_amount<=0 or v_amount>v_remaining then raise exception 'Valor de pagamento inválido'; end if;
  insert into public.commission_settlement_payments(settlement_id,amount_cents,payment_method,paid_at,actor_member_id,note)
  values(v.id,v_amount,p_payment_method,coalesce(p_paid_at,now()),m.member_id,nullif(trim(coalesce(p_note,'')),'')) returning id into v_payment;
  v_paid:=v.paid_cents+v_amount;
  v_status:=case when v_paid>=v.total_cents then 'paid' else 'partial' end;
  update public.commission_settlements set paid_cents=v_paid,status=v_status,
    closed_at=case when v_status='paid' then coalesce(p_paid_at,now()) else null end,updated_at=now() where id=v.id;
  if p_payment_method='cash' then
    v_unit:=v.unit_id;
    select cs.id into v_session from public.cash_sessions cs where cs.barbershop_id=m.barbershop_id and cs.unit_id=v_unit and cs.status='open' order by cs.opened_at desc limit 1;
    if v_session is not null then
      insert into public.cash_movements(cash_session_id,barbershop_id,unit_id,movement_type,amount_cents,reference_type,reference_id,note,actor_member_id)
      values(v_session,m.barbershop_id,v_unit,'expense',-v_amount,'commission_settlement',v_payment,'Pagamento de comissão',m.member_id);
    end if;
  end if;
  return jsonb_build_object('ok',true,'payment_id',v_payment,'amount_cents',v_amount,'paid_cents',v_paid,'remaining_cents',greatest(0,v.total_cents-v_paid),'status',v_status);
end $$;

create or replace function public.barberium_staff_my_commissions(
  p_start date default (current_date - interval '90 days')::date,
  p_end date default current_date
) returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
as $$
declare m record; prof uuid; v_unsettled int; v_settlement_due int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
  prof:=m.professional_id;
  if prof is null then return jsonb_build_object('entries','[]'::jsonb,'settlements','[]'::jsonb,'open_cents',0,'unsettled_cents',0,'in_settlement_cents',0); end if;
  select coalesce(sum(amount_cents),0)::int into v_unsettled from public.commission_entries where professional_id=prof and status='open' and settlement_id is null;
  select coalesce(sum(greatest(0,total_cents-paid_cents)),0)::int into v_settlement_due from public.commission_settlements where professional_id=prof and status in ('open','partial');
  return jsonb_build_object(
    'open_cents',v_unsettled+v_settlement_due,'unsettled_cents',v_unsettled,'in_settlement_cents',v_settlement_due,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',ce.id,'amount_cents',ce.amount_cents,'description',ce.description,'created_at',ce.created_at,'status',ce.status,'settlement_id',ce.settlement_id
    ) order by ce.created_at desc) from public.commission_entries ce where ce.professional_id=prof and ce.created_at::date between p_start and p_end),'[]'::jsonb),
    'settlements',coalesce((select jsonb_agg(jsonb_build_object(
      'id',cs.id,'period_start',cs.period_start,'period_end',cs.period_end,'base_cents',cs.base_cents,'adjustment_cents',cs.adjustment_cents,
      'total_cents',cs.total_cents,'paid_cents',cs.paid_cents,'remaining_cents',greatest(0,cs.total_cents-cs.paid_cents),
      'status',cs.status,'note',cs.note,'created_at',cs.created_at,'closed_at',cs.closed_at
    ) order by cs.period_end desc,cs.created_at desc) from public.commission_settlements cs where cs.professional_id=prof and cs.period_end>=p_start and cs.period_start<=p_end),'[]'::jsonb)
  );
end $$;

revoke all on function public.barberium_staff_commission_preview(uuid,date,date) from public,anon;
revoke all on function public.barberium_staff_create_commission_settlement(uuid,date,date,text) from public,anon;
revoke all on function public.barberium_staff_commission_settlements(uuid,date,date) from public,anon;
revoke all on function public.barberium_staff_commission_settlement_detail(uuid) from public,anon;
revoke all on function public.barberium_staff_adjust_commission_settlement(uuid,integer,text) from public,anon;
revoke all on function public.barberium_staff_record_commission_settlement_payment(uuid,integer,text,timestamptz,text) from public,anon;
revoke all on function public.barberium_staff_my_commissions(date,date) from public,anon;

grant execute on function public.barberium_staff_commission_preview(uuid,date,date) to authenticated;
grant execute on function public.barberium_staff_create_commission_settlement(uuid,date,date,text) to authenticated;
grant execute on function public.barberium_staff_commission_settlements(uuid,date,date) to authenticated;
grant execute on function public.barberium_staff_commission_settlement_detail(uuid) to authenticated;
grant execute on function public.barberium_staff_adjust_commission_settlement(uuid,integer,text) to authenticated;
grant execute on function public.barberium_staff_record_commission_settlement_payment(uuid,integer,text,timestamptz,text) to authenticated;
grant execute on function public.barberium_staff_my_commissions(date,date) to authenticated;
