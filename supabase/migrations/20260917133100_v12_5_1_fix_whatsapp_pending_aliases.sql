CREATE OR REPLACE FUNCTION public.barberium_staff_whatsapp(p_appointment_id uuid DEFAULT NULL::uuid, p_action text DEFAULT 'list'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'barberium', 'auth', 'pg_temp'
AS $function$
declare m record; a public.appointments; r barberium.wa_reminders; result jsonb;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 select * into m from barberium.staff_membership(); if m.member_id is null then raise exception 'Sem acesso'; end if;
 if p_action='list' then
 if m.role not in ('owner','admin') then raise exception 'Apenas administrador'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',appt.id,'customer',c.full_name,'professional',p.name,'starts_at',appt.starts_at,'sent_at',rem.sent_at) order by appt.starts_at) from barberium.wa_reminders rem join public.appointments appt on appt.id=rem.appointment_id join public.customers c on c.id=appt.customer_id join public.professionals p on p.id=appt.professional_id where appt.barbershop_id=m.barbershop_id and appt.status='confirmed' and appt.starts_at>now() and rem.due_at<=now() and rem.sent_at is null),'[]'::jsonb);
 end if;
 select * into a from public.appointments where id=p_appointment_id for update;
 if a.id is null or a.barbershop_id<>m.barbershop_id or (m.role not in ('owner','admin') and a.professional_id is distinct from m.professional_id) then raise exception 'Sem acesso ao agendamento'; end if;
 if a.status<>'confirmed' or a.starts_at<=now() then raise exception 'Este horário não está mais disponível para lembrete'; end if;
 select * into r from barberium.wa_reminders where appointment_id=a.id;
 if p_action='request' then
 update barberium.wa_reminders set requested_by=coalesce(requested_by,m.member_id) where appointment_id=a.id;
 return jsonb_build_object('requested',true,'due_at',r.due_at,'sent_at',r.sent_at);
 end if;
 if p_action='status' then return jsonb_build_object('requested',r.requested_by is not null,'due_at',r.due_at,'sent_at',r.sent_at); end if;
 if m.role not in ('owner','admin') then raise exception 'Apenas administrador'; end if;
 if p_action='sent' then
 update barberium.wa_reminders set sent_at=coalesce(sent_at,now()),sent_by=coalesce(sent_by,m.member_id) where appointment_id=a.id;
 update barberium.wa_jobs set state='cancelled',lease_id=null where appointment_id=a.id and state in ('pending','sending');
 return jsonb_build_object('sent',true);
 end if;
 if p_action<>'message' then raise exception 'Ação inválida'; end if;
 select jsonb_build_object('phone',regexp_replace(c.phone_e164,'[^0-9]','','g'),'message',format('Olá, %s! 💈 Lembrando que seu horário na %s é em %s, às %s, com %s. Esperamos você!',c.full_name,b.name,to_char(a.starts_at at time zone b.timezone,'DD/MM/YYYY'),to_char(a.starts_at at time zone b.timezone,'HH24:MI'),p.name),'sent_at',r.sent_at) into result from public.customers c join public.barbershops b on b.id=a.barbershop_id join public.professionals p on p.id=a.professional_id where c.id=a.customer_id;
 return result;
end $function$
;

