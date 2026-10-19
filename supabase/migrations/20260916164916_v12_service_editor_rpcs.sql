create or replace function public.barberium_staff_seed_default_services(p_unit_id uuid)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; c uuid; b uuid;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if exists(select 1 from public.services s where s.unit_id=p_unit_id) then return jsonb_build_object('ok',true,'created',false); end if;
  insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,sort_order,is_active,settings,service_kind) values(m.barbershop_id,p_unit_id,'Corte','corte',0,45,'45 min',10,true,jsonb_build_object('draft',true),'service') returning id into c;
  insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,sort_order,is_active,settings,service_kind) values(m.barbershop_id,p_unit_id,'Barba','barba',0,30,'30 min',20,true,jsonb_build_object('draft',true),'service') returning id into b;
  insert into public.professional_services(professional_id,service_id,is_active) select p.id,x.sid,true from public.professionals p cross join (values(c),(b)) x(sid) where p.unit_id=p_unit_id and p.is_active on conflict(professional_id,service_id) do update set is_active=true;
  return jsonb_build_object('ok',true,'created',true,'service_ids',jsonb_build_array(c,b));
end $$;

create or replace function public.barberium_staff_service_settings(p_unit_id uuid)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  return jsonb_build_object(
    'unit',(select jsonb_build_object('id',u.id,'name',u.name,'settings',u.settings) from public.units u where u.id=p_unit_id),
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'image_path',p.image_path,'is_active',p.is_active) order by p.sort_order,p.name) from public.professionals p where p.unit_id=p_unit_id and p.is_active),'[]'::jsonb),
    'services',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'kind',s.service_kind,'description',s.description,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,'image_path',s.image_path,'is_active',s.is_active,'draft',coalesce((s.settings->>'draft')::boolean,false),'sort_order',s.sort_order,'addon_ids',coalesce((select jsonb_agg(sa.addon_service_id order by sa.sort_order) from public.service_addons sa where sa.base_service_id=s.id and sa.is_active),'[]'::jsonb),'component_ids',coalesce((select jsonb_agg(sc.component_service_id order by sc.sort_order) from public.service_components sc where sc.parent_service_id=s.id),'[]'::jsonb),'professional_links',coalesce((select jsonb_agg(jsonb_build_object('professional_id',p.id,'professional',p.name,'linked',coalesce(ps.is_active,false),'custom_price_cents',ps.custom_price_cents,'custom_duration_min',ps.custom_duration_min,'combo_eligible',case when s.service_kind<>'combo' or not exists(select 1 from public.service_components z where z.parent_service_id=s.id) then true else not exists(select 1 from public.service_components z where z.parent_service_id=s.id and not exists(select 1 from public.professional_services cps where cps.professional_id=p.id and cps.service_id=z.component_service_id and cps.is_active)) end) order by p.sort_order,p.name) from public.professionals p left join public.professional_services ps on ps.professional_id=p.id and ps.service_id=s.id where p.unit_id=p_unit_id and p.is_active),'[]'::jsonb)) order by s.is_active desc,s.sort_order,s.name) from public.services s where s.unit_id=p_unit_id),'[]'::jsonb)
  );
end $$;

create or replace function public.barberium_staff_save_catalog_item(p_service_id uuid,p_unit_id uuid,p_kind text,p_name text,p_description text,p_price_cents integer,p_duration_min integer,p_image_path text,p_sort_order integer,p_professional_links jsonb,p_addon_service_ids uuid[] default '{}'::uuid[],p_component_service_ids uuid[] default '{}'::uuid[])
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; sid uuid; link jsonb; pid uuid; linked boolean; cp int; cd int; x uuid; ordern int:=0; created boolean:=false;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership();
  if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  if not exists(select 1 from public.units u where u.id=p_unit_id and u.barbershop_id=m.barbershop_id) then raise exception 'Unidade inválida'; end if;
  if p_kind not in ('service','addon','combo') then raise exception 'Tipo inválido'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Informe o nome'; end if;
  if coalesce(p_price_cents,-1)<0 then raise exception 'Valor inválido'; end if;
  if coalesce(p_duration_min,0)<5 or p_duration_min>480 then raise exception 'Duração inválida'; end if;
  if p_kind='combo' then
    if cardinality(coalesce(p_component_service_ids,'{}'::uuid[]))<2 then raise exception 'Combo precisa de pelo menos dois serviços'; end if;
    if exists(select 1 from unnest(p_component_service_ids) q where not exists(select 1 from public.services s where s.id=q and s.unit_id=p_unit_id and s.is_active and s.service_kind='service')) then raise exception 'Componente inválido'; end if;
  else p_component_service_ids:='{}'::uuid[]; end if;
  if p_kind in ('service','combo') then
    if exists(select 1 from unnest(coalesce(p_addon_service_ids,'{}'::uuid[])) q where not exists(select 1 from public.services s where s.id=q and s.unit_id=p_unit_id and s.is_active and s.service_kind<>'combo')) then raise exception 'Adicional inválido'; end if;
  else p_addon_service_ids:='{}'::uuid[]; end if;
  if p_service_id is null then
    insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,image_path,sort_order,is_active,settings,service_kind,description) values(m.barbershop_id,p_unit_id,trim(p_name),barberium.unique_service_slug(p_unit_id,p_name,null),p_price_cents,p_duration_min,p_duration_min||' min',nullif(trim(coalesce(p_image_path,'')),''),coalesce(p_sort_order,0),true,'{}'::jsonb,p_kind,nullif(trim(coalesce(p_description,'')),'')) returning id into sid; created:=true;
  else
    select id into sid from public.services where id=p_service_id and barbershop_id=m.barbershop_id and unit_id=p_unit_id; if sid is null then raise exception 'Serviço inválido'; end if;
    update public.services set name=trim(p_name),slug=barberium.unique_service_slug(p_unit_id,p_name,sid),price_cents=p_price_cents,duration_min=p_duration_min,duration_label=p_duration_min||' min',image_path=nullif(trim(coalesce(p_image_path,'')),''),sort_order=coalesce(p_sort_order,0),is_active=true,service_kind=p_kind,description=nullif(trim(coalesce(p_description,'')),''),settings=coalesce(settings,'{}'::jsonb)-'draft',updated_at=now() where id=sid;
  end if;
  delete from public.service_components where parent_service_id=sid; ordern:=0;
  foreach x in array coalesce(p_component_service_ids,'{}'::uuid[]) loop ordern:=ordern+1; insert into public.service_components(parent_service_id,component_service_id,quantity,sort_order) values(sid,x,1,ordern); end loop;
  update public.service_addons set is_active=false where base_service_id=sid; ordern:=0;
  foreach x in array coalesce(p_addon_service_ids,'{}'::uuid[]) loop
    ordern:=ordern+1;
    insert into public.service_addons(barbershop_id,unit_id,base_service_id,addon_service_id,addon_price_cents,addon_duration_min,sort_order,is_active) select m.barbershop_id,p_unit_id,sid,a.id,a.price_cents,a.duration_min,ordern,true from public.services a where a.id=x on conflict(base_service_id,addon_service_id) do update set addon_price_cents=excluded.addon_price_cents,addon_duration_min=excluded.addon_duration_min,sort_order=excluded.sort_order,is_active=true;
  end loop;
  if p_kind='addon' then update public.service_addons sa set addon_price_cents=p_price_cents,addon_duration_min=p_duration_min where sa.addon_service_id=sid and sa.is_active; end if;
  for link in select * from jsonb_array_elements(coalesce(p_professional_links,'[]'::jsonb)) loop
    pid:=(link->>'professional_id')::uuid; linked:=coalesce((link->>'linked')::boolean,false); cp:=nullif(link->>'custom_price_cents','')::int; cd:=nullif(link->>'custom_duration_min','')::int;
    if not exists(select 1 from public.professionals p where p.id=pid and p.unit_id=p_unit_id and p.barbershop_id=m.barbershop_id and p.is_active) then raise exception 'Profissional inválido'; end if;
    if cp is not null and cp<0 then raise exception 'Preço personalizado inválido'; end if; if cd is not null and (cd<5 or cd>480) then raise exception 'Duração personalizada inválida'; end if;
    if p_kind='combo' and linked and exists(select 1 from public.service_components sc where sc.parent_service_id=sid and not exists(select 1 from public.professional_services cps where cps.professional_id=pid and cps.service_id=sc.component_service_id and cps.is_active)) then raise exception 'O profissional precisa executar todos os serviços do combo'; end if;
    insert into public.professional_services(professional_id,service_id,is_active,custom_price_cents,custom_duration_min) values(pid,sid,linked,case when linked then cp else null end,case when linked then cd else null end) on conflict(professional_id,service_id) do update set is_active=excluded.is_active,custom_price_cents=excluded.custom_price_cents,custom_duration_min=excluded.custom_duration_min;
  end loop;
  update public.professional_services ps set is_active=false,custom_price_cents=null,custom_duration_min=null where ps.service_id=sid and exists(select 1 from public.professionals p where p.id=ps.professional_id and p.unit_id=p_unit_id) and not exists(select 1 from jsonb_array_elements(coalesce(p_professional_links,'[]'::jsonb)) j where (j->>'professional_id')::uuid=ps.professional_id);
  return jsonb_build_object('ok',true,'service_id',sid,'created',created);
end $$;

create or replace function public.barberium_staff_set_catalog_image(p_service_id uuid,p_image_path text)
returns boolean language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  update public.services set image_path=nullif(trim(coalesce(p_image_path,'')),''),updated_at=now() where id=p_service_id and barbershop_id=m.barbershop_id; if not found then raise exception 'Serviço inválido'; end if; return true;
end $$;

create or replace function public.barberium_staff_delete_catalog_item(p_service_id uuid)
returns jsonb language plpgsql security definer set search_path='public','barberium','auth','pg_temp' as $$
declare m record; affected int;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if; select * into m from barberium.staff_membership(); if m.member_id is null or m.role not in ('owner','admin') then raise exception 'Acesso somente para ADM'; end if;
  update public.services set is_active=false,updated_at=now() where id=p_service_id and barbershop_id=m.barbershop_id; if not found then raise exception 'Serviço inválido'; end if;
  update public.professional_services set is_active=false where service_id=p_service_id; update public.service_addons set is_active=false where base_service_id=p_service_id or addon_service_id=p_service_id;
  select count(*) into affected from public.service_components sc join public.services s on s.id=sc.parent_service_id where sc.component_service_id=p_service_id and s.is_active;
  return jsonb_build_object('ok',true,'dependent_combos',affected);
end $$;

revoke all on function public.barberium_staff_seed_default_services(uuid) from anon;
revoke all on function public.barberium_staff_service_settings(uuid) from anon;
revoke all on function public.barberium_staff_save_catalog_item(uuid,uuid,text,text,text,integer,integer,text,integer,jsonb,uuid[],uuid[]) from anon;
revoke all on function public.barberium_staff_set_catalog_image(uuid,text) from anon;
revoke all on function public.barberium_staff_delete_catalog_item(uuid) from anon;
grant execute on function public.barberium_staff_seed_default_services(uuid) to authenticated;
grant execute on function public.barberium_staff_service_settings(uuid) to authenticated;
grant execute on function public.barberium_staff_save_catalog_item(uuid,uuid,text,text,text,integer,integer,text,integer,jsonb,uuid[],uuid[]) to authenticated;
grant execute on function public.barberium_staff_set_catalog_image(uuid,text) to authenticated;
grant execute on function public.barberium_staff_delete_catalog_item(uuid) to authenticated;

