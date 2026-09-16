-- Barberium v12.0 — valores efetivos de adicionais por serviço e profissional

create or replace function public.barberium_get_catalog(p_barbershop_slug text,p_unit_slug text)
returns jsonb
language sql stable security definer
set search_path='public','barberium'
as $$
with b as(select * from public.barbershops where slug=p_barbershop_slug and status='active' limit 1),
u as(select u.* from public.units u join b on b.id=u.barbershop_id where u.slug=p_unit_slug and u.is_active limit 1)
select jsonb_build_object(
 'barbershop',jsonb_build_object('id',b.id,'name',b.name,'slug',b.slug,'timezone',b.timezone,'settings',b.settings),
 'unit',jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug,'city',u.city,'state',u.state,'whatsapp',u.whatsapp,'maps_url',u.maps_url,'settings',u.settings),
 'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path) order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active),'[]'::jsonb),
 'services',coalesce((select jsonb_agg(jsonb_build_object(
   'id',s.id,'name',s.name,'slug',s.slug,'kind',s.service_kind,'description',s.description,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,'image_path',s.image_path,
   'professional_links',coalesce((select jsonb_agg(jsonb_build_object('professional_id',p.id,'price_cents',barberium.effective_service_price(p.id,s.id),'duration_min',barberium.effective_service_duration(p.id,s.id)) order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active and barberium.professional_service_allowed(p.id,s.id)),'[]'::jsonb),
   'professional_ids',coalesce((select jsonb_agg(p.id order by p.sort_order,p.name) from public.professionals p where p.unit_id=u.id and p.is_active and barberium.professional_service_allowed(p.id,s.id)),'[]'::jsonb),
   'addons',coalesce((select jsonb_agg(jsonb_build_object(
      'service_id',ad.id,'name',ad.name,'slug',ad.slug,'description',ad.description,'price_cents',a.addon_price_cents,'duration_min',a.addon_duration_min,'image_path',ad.image_path,
      'professional_links',coalesce((select jsonb_agg(jsonb_build_object('professional_id',p2.id,'price_cents',barberium.effective_addon_price(p2.id,s.id,ad.id),'duration_min',barberium.effective_addon_duration(p2.id,s.id,ad.id)) order by p2.sort_order,p2.name) from public.professionals p2 where p2.unit_id=u.id and p2.is_active and barberium.professional_service_allowed(p2.id,ad.id)),'[]'::jsonb),
      'professional_ids',coalesce((select jsonb_agg(p2.id order by p2.sort_order,p2.name) from public.professionals p2 where p2.unit_id=u.id and p2.is_active and barberium.professional_service_allowed(p2.id,ad.id)),'[]'::jsonb)
   ) order by a.sort_order,ad.name) from public.service_addons a join public.services ad on ad.id=a.addon_service_id where a.base_service_id=s.id and a.is_active and ad.is_active and coalesce((ad.settings->>'draft')::boolean,false)=false),'[]'::jsonb),
   'components',coalesce((select jsonb_agg(jsonb_build_object('service_id',cs.id,'name',cs.name,'quantity',sc.quantity) order by sc.sort_order,cs.name) from public.service_components sc join public.services cs on cs.id=sc.component_service_id where sc.parent_service_id=s.id),'[]'::jsonb)
 ) order by s.sort_order,s.name) from public.services s where s.unit_id=u.id and s.is_active and s.service_kind in ('service','combo') and coalesce((s.settings->>'draft')::boolean,false)=false
   and (s.service_kind<>'combo' or not exists(select 1 from public.service_components sc join public.services cs on cs.id=sc.component_service_id where sc.parent_service_id=s.id and not cs.is_active))
 ),'[]'::jsonb)
) from b,u;
$$;


create or replace function public.barberium_staff_catalog()
returns jsonb
language plpgsql security definer
set search_path='public','barberium','auth','pg_temp'
as $$
declare m record; v_permissions jsonb;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into m from barberium.staff_membership();
  if m.member_id is null then raise exception 'Usuário sem acesso à equipe'; end if;
  v_permissions:=case when m.role in ('owner','admin') then '{}'::jsonb else barberium.effective_permissions(m.professional_id) end;
  return jsonb_build_object(
    'professionals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'slug',p.slug,'image_path',p.image_path) order by p.sort_order,p.name) from public.professionals p where p.barbershop_id=m.barbershop_id and p.is_active and (m.role in ('owner','admin') or p.id=m.professional_id)),'[]'::jsonb),
    'services',coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.name,'slug',s.slug,'kind',s.service_kind,'description',s.description,'price_cents',s.price_cents,'duration_min',s.duration_min,'duration_label',s.duration_label,'image_path',s.image_path,
      'professional_ids',coalesce((select jsonb_agg(ps.professional_id) from public.professional_services ps where ps.service_id=s.id and ps.is_active),'[]'::jsonb),
      'addons',coalesce((select jsonb_agg(jsonb_build_object('service_id',ad.id,'name',ad.name,'price_cents',sa.addon_price_cents,'duration_min',sa.addon_duration_min,'description',ad.description,'image_path',ad.image_path,'professional_links',coalesce((select jsonb_agg(jsonb_build_object('professional_id',p2.id,'price_cents',barberium.effective_addon_price(p2.id,s.id,ad.id),'duration_min',barberium.effective_addon_duration(p2.id,s.id,ad.id)) order by p2.sort_order,p2.name) from public.professionals p2 where p2.unit_id=s.unit_id and p2.is_active and barberium.professional_service_allowed(p2.id,ad.id)),'[]'::jsonb)) order by sa.sort_order,ad.name) from public.service_addons sa join public.services ad on ad.id=sa.addon_service_id where sa.base_service_id=s.id and sa.is_active and ad.is_active),'[]'::jsonb)
    ) order by s.sort_order,s.name) from public.services s where s.barbershop_id=m.barbershop_id and s.is_active and s.service_kind in ('service','combo') and coalesce((s.settings->>'draft')::boolean,false)=false),'[]'::jsonb),
    'units',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name,'slug',u.slug) order by u.name) from public.units u where u.barbershop_id=m.barbershop_id and u.is_active),'[]'::jsonb),
    'permissions',v_permissions
  );
end $$;


