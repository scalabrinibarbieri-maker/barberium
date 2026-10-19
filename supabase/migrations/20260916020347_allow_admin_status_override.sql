create or replace function public.barberium_staff_set_appointment_status(p_appointment_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','barberium','auth','pg_temp'
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

  select * into a
  from public.appointments
  where id = p_appointment_id
  for update;

  if a.id is null or a.barbershop_id <> m.barbershop_id then
    raise exception 'Agendamento não encontrado';
  end if;

  if m.role in ('owner','admin') then
    -- ADM/Proprietário pode corrigir qualquer status da unidade,
    -- inclusive reabrir um atendimento concluído/cancelado/falta.
    null;
  else
    if a.professional_id <> m.professional_id then
      raise exception 'Sem permissão para este agendamento';
    end if;

    -- Barbeiro pode apenas finalizar o próprio horário confirmado.
    if a.status <> 'confirmed' then
      raise exception 'Este atendimento já foi finalizado';
    end if;
    if p_status not in ('completed','no_show') then
      raise exception 'Sem permissão para esta alteração de status';
    end if;
  end if;

  if a.status = p_status then
    return jsonb_build_object('ok',true,'appointment_id',p_appointment_id,'status',a.status);
  end if;

  update public.appointments
  set status = p_status,
      cancelled_at = case when p_status='cancelled' then now() else null end,
      updated_at = now()
  where id = p_appointment_id;

  return jsonb_build_object('ok',true,'appointment_id',p_appointment_id,'status',p_status);
end;
$$;

revoke all on function public.barberium_staff_set_appointment_status(uuid,text) from public, anon;
grant execute on function public.barberium_staff_set_appointment_status(uuid,text) to authenticated;

