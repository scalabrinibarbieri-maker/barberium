do $patch$
declare
  v_def text;
  v_old text := $old$
  professional_refunds as (
    select professional_id,professional,sum(amount_cents)::int refunds_cents
    from (
      select a.professional_id,coalesce(pr.name,'Sem profissional') professional,fr.amount_cents
      from public.finance_refunds fr
      join public.appointments a on a.id=fr.appointment_id
      left join public.professionals pr on pr.id=a.professional_id
      where fr.barbershop_id=m.barbershop_id
        and fr.appointment_id is not null
        and fr.created_at::date between p_start and p_end
$old$;
  v_new text := $new$
  professional_refunds as (
    select professional_id,professional,sum(amount_cents)::int refunds_cents
    from (
      select a.professional_id,coalesce(pr.name,'Sem profissional') professional,fr.amount_cents
      from public.finance_refunds fr
      join public.appointments a on a.id=fr.appointment_id
      left join public.professionals pr on pr.id=a.professional_id
      where fr.barbershop_id=m.barbershop_id
        and fr.appointment_id is not null
        and fr.product_sale_id is null
        and fr.created_at::date between p_start and p_end
$new$;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='barberium_staff_finance_report_v12_8_1_raw';

  if v_def is null then
    raise exception 'Função alvo não encontrada';
  end if;

  if position(v_old in v_def)=0 then
    raise exception 'Trecho alvo de professional_refunds não encontrado';
  end if;

  if length(v_def)-length(replace(v_def,v_old,'')) <> length(v_old) then
    raise exception 'Trecho alvo de professional_refunds não é único';
  end if;

  execute replace(v_def,v_old,v_new);
end
$patch$;

