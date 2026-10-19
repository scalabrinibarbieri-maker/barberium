-- Teste da etapa 0 (19/10/2026). Pode ser rodado a qualquer momento no SQL Editor do Supabase.
-- Termina com um erro proposital, então o banco desfaz tudo o que o teste fez.
-- Usa só a barbearia de teste (Aurora); nenhum cliente real é tocado.
-- O resultado vem na mensagem de erro, uma linha por teste. Qualquer linha com FALHOU é problema.

do $t$
declare
  aurora uuid:='a0b9b1f2-487d-4f66-b04f-f3ebc4cd0c46';
  a_unit uuid:='d086f4b3-ae4e-4e3d-b9d5-0c0568120bb0';
  a_prof uuid:='acceeafe-6a81-4924-8938-7141c43346a7';
  a_svc uuid:='5d7821b6-6ddf-4ccc-908a-8a004f4b2ff3';
  a_admin uuid:='5f507165-86fa-4e6c-a615-f9de8dc245fa';
  s_prof uuid:='5d974247-4f0e-4392-8c19-9c9bd08b528d';
  s_unit uuid:='4be1838e-b62c-4073-a290-54a40014a31d';
  s_svc uuid; s_pct numeric; s_pct_after numeric;
  d date; slots jsonb; n int; t1 time; t2 time; t3 time;
  r jsonb; out text:=''; tok text; cust uuid; nm text; note text; ntok_before int; ntok_after int;
begin
  update public.barbershops set status='active' where id=aurora;
  select id into s_svc from public.services where unit_id=s_unit and is_active limit 1;
  select default_percent into s_pct from public.commission_profiles where professional_id=s_prof;
  for i in 1..21 loop
    d:=current_date+i;
    slots:=public.barberium_get_available_slots('barbearia-aurora','centro',a_prof,a_svc,'{}',d);
    n:=jsonb_array_length(slots);
    exit when n>=3;
  end loop;
  t1:=(slots->>0)::time; t2:=(slots->>(n/2))::time; t3:=(slots->>(n-1))::time;
  out:=out||format(E'\n[preparo] %s horarios em %s; usando %s, %s, %s', n, d, t1, t2, t3);

  -- T1: cliente novo pelo site recebe token
  perform set_config('role','anon',true);
  r:=public.barberium_create_appointment('barbearia-aurora','centro',a_prof,a_svc,'{}',d,t1,'Cliente Teste Etapa','11987650001',null,null);
  perform set_config('role','postgres',true);
  tok:=r->>'access_token'; cust:=(r->>'customer_id')::uuid;
  out:=out||format(E'\nT1 cliente novo: horario criado=%s token=%s profile_linked=%s', r ? 'appointment_id', tok is not null, r->>'profile_linked');

  -- T2: mesmo telefone, sem token, outro nome
  select count(*) into ntok_before from public.customer_access_tokens where customer_id=cust;
  perform set_config('role','anon',true);
  r:=public.barberium_create_appointment('barbearia-aurora','centro',a_prof,a_svc,'{}',d,t2,'Outra Pessoa Qualquer','11987650001',null,null);
  perform set_config('role','postgres',true);
  select full_name into nm from public.customers where id=cust;
  select internal_note into note from public.appointments where id=(r->>'appointment_id')::uuid;
  select count(*) into ntok_after from public.customer_access_tokens where customer_id=cust;
  out:=out||format(E'\nT2 existente sem token: horario criado=%s token=%s profile_linked=%s nome_no_cadastro=%s nota_interna=%s tokens_antes=%s depois=%s', r ? 'appointment_id', r->>'access_token' is not null, r->>'profile_linked', nm, note, ntok_before, ntok_after);

  -- T3: mesmo telefone COM o token dele, novo nome
  perform set_config('role','anon',true);
  r:=public.barberium_create_appointment('barbearia-aurora','centro',a_prof,a_svc,'{}',d,t3,'Cliente Teste Renomeado','11987650001',null,tok);
  perform set_config('role','postgres',true);
  select full_name into nm from public.customers where id=cust;
  out:=out||format(E'\nT3 existente com token: mesmo token=%s profile_linked=%s nome_no_cadastro=%s', r->>'access_token'=tok, r->>'profile_linked', nm);

  -- T4: acesso por nome + WhatsApp
  select count(*) into ntok_before from public.customer_access_tokens where customer_id=cust;
  begin
    perform set_config('role','anon',true);
    r:=public.barberium_customer_open_profile('barbearia-aurora','Invasor Qualquer','11987650001');
    out:=out||E'\nT4 FALHOU: open_profile devolveu perfil';
  exception when others then
    out:=out||format(E'\nT4 open_profile: %s', sqlerrm);
  end;
  perform set_config('role','postgres',true);
  select full_name into nm from public.customers where id=cust;
  select count(*) into ntok_after from public.customer_access_tokens where customer_id=cust;
  out:=out||format(' | nome_no_cadastro=%s tokens_antes=%s depois=%s', nm, ntok_before, ntok_after);

  -- Equipe: ADM da Aurora tentando mexer na Scalabrini
  perform set_config('request.jwt.claims', json_build_object('sub',a_admin,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a_admin::text, true);
  perform set_config('role','authenticated',true);
  begin
    perform public.barberium_staff_save_commission_config(s_prof,99,'monthly','gross','[]'::jsonb);
    out:=out||E'\nT5 FALHOU: alterou comissao de barbeiro da Scalabrini';
  exception when others then out:=out||format(E'\nT5 comissao de barbeiro de outra barbearia: %s', sqlerrm); end;
  begin
    perform public.barberium_staff_save_commission_config(a_prof,40,'monthly','gross',jsonb_build_array(jsonb_build_object('service_id',a_svc,'mode','percent','percent',45)));
    out:=out||E'\nT6 comissao do proprio barbeiro: ok';
  exception when others then out:=out||format(E'\nT6 FALHOU: %s', sqlerrm); end;
  begin
    perform public.barberium_staff_save_commission_config(a_prof,40,'monthly','gross',jsonb_build_array(jsonb_build_object('service_id',s_svc,'mode','percent','percent',45)));
    out:=out||E'\nT7 FALHOU: aceitou servico da Scalabrini';
  exception when others then out:=out||format(E'\nT7 regra com servico de outra barbearia: %s', sqlerrm); end;
  begin
    perform public.barberium_staff_open_cash(s_unit,0);
    out:=out||E'\nT8 FALHOU: abriu caixa na unidade da Scalabrini';
  exception when others then out:=out||format(E'\nT8 caixa em unidade de outra barbearia: %s', sqlerrm); end;
  begin
    perform public.barberium_staff_open_cash(a_unit,0);
    out:=out||E'\nT9 caixa na propria unidade: ok';
  exception when others then out:=out||format(E'\nT9 FALHOU: %s', sqlerrm); end;
  begin
    perform public.barberium_staff_assign_membership(cust,gen_random_uuid(),s_unit);
    out:=out||E'\nT10 FALHOU: aceitou unidade da Scalabrini';
  exception when others then out:=out||format(E'\nT10 plano com unidade de outra barbearia: %s', sqlerrm); end;
  begin
    perform public.barberium_staff_assign_membership(cust,gen_random_uuid(),a_unit);
    out:=out||E'\nT10b inesperado: criou plano inexistente';
  exception when others then out:=out||format(E'\nT10b propria unidade passa da checagem e para em: %s', sqlerrm); end;
  perform set_config('role','postgres',true);

  -- FKs compostas, direto na tabela
  begin
    insert into public.cash_sessions(barbershop_id,unit_id,opening_balance_cents) values(aurora,s_unit,0);
    out:=out||E'\nT11 FALHOU: tabela aceitou caixa misturando barbearias';
  exception when others then out:=out||format(E'\nT11 FK caixa: %s', split_part(sqlerrm,'"',4)); end;
  begin
    update public.commission_profiles set barbershop_id=aurora where professional_id=s_prof;
    out:=out||E'\nT12 FALHOU: tabela aceitou comissao misturando barbearias';
  exception when others then out:=out||format(E'\nT12 FK comissao: %s', split_part(sqlerrm,'"',4)); end;
  select default_percent into s_pct_after from public.commission_profiles where professional_id=s_prof;
  out:=out||format(E'\n[checagem] comissao padrao do Vinicius antes=%s depois=%s', s_pct, s_pct_after);

  raise exception 'RESULTADOS (tudo desfeito):%', out;
end $t$;
