with ins_b as (
 insert into public.barbershops(name,slug,timezone,settings)
 values('Scalabrini Barbieri','scalabrini-barbieri','America/Sao_Paulo',jsonb_build_object('brand','premium','primary_color','#0b2418','accent_color','#d2a64c'))
 on conflict(slug) do update set name=excluded.name,timezone=excluded.timezone,settings=excluded.settings
 returning id
), b as (
 select id from ins_b union all select id from public.barbershops where slug='scalabrini-barbieri' limit 1
), ins_u as (
 insert into public.units(barbershop_id,name,slug,city,state,whatsapp,maps_url,settings)
 select id,'II Unidade — Bragança Paulista','braganca-paulista','Bragança Paulista','SP','+5511945246544','https://maps.app.goo.gl/ztpb7NShYtjQES897?g_st=ac',jsonb_build_object('slot_minutes',10) from b
 on conflict(barbershop_id,slug) do update set name=excluded.name,city=excluded.city,state=excluded.state,whatsapp=excluded.whatsapp,maps_url=excluded.maps_url,settings=excluded.settings
 returning id,barbershop_id
), u as (
 select id,barbershop_id from ins_u union all select u.id,u.barbershop_id from public.units u join b on b.id=u.barbershop_id where u.slug='braganca-paulista' limit 1
)
insert into public.professionals(barbershop_id,unit_id,name,slug,sort_order,image_path)
select barbershop_id,id,'Vinicius Nunes','vinicius-nunes',1,'assets/vinicius-nunes.webp' from u
union all
select barbershop_id,id,'Jean Dalarmi','jean-dalarmi',2,'assets/jean-dalarmi.webp' from u
on conflict(unit_id,slug) do update set name=excluded.name,sort_order=excluded.sort_order,image_path=excluded.image_path,is_active=true;

with b as (select id from public.barbershops where slug='scalabrini-barbieri'),u as (select u.id,u.barbershop_id from public.units u join b on b.id=u.barbershop_id where u.slug='braganca-paulista')
insert into public.services(barbershop_id,unit_id,name,slug,price_cents,duration_min,duration_label,image_path,sort_order)
select barbershop_id,id,'Corte','corte',9000,40,'30–40 min','assets/corte.webp',1 from u union all
select barbershop_id,id,'Barba Tradizionale','barba-tradizionale',7500,45,'35–45 min','assets/barba-tradizionale.webp',2 from u union all
select barbershop_id,id,'Combo Corte + Barba','combo-corte-barba',15500,75,'1h15','assets/combo-corte-barba.webp',3 from u union all
select barbershop_id,id,'Barboterapia','barboterapia',14500,60,'1h','assets/barboterapia.webp',4 from u union all
select barbershop_id,id,'Combo Corte + Barboterapia','combo-corte-barboterapia',21500,90,'1h30','assets/combo-corte-barboterapia.webp',5 from u union all
select barbershop_id,id,'Corte + Barba + Sobrancelha','corte-barba-sobrancelha',17500,60,'1h','assets/corte-barba-sobrancelha.webp',6 from u union all
select barbershop_id,id,'Barba Express','barba-express',6000,20,'20 min','assets/barba-express.webp',7 from u union all
select barbershop_id,id,'Corte + Barba Express','corte-barba-express',14000,40,'40 min','assets/corte-barba-express.webp',8 from u union all
select barbershop_id,id,'Sobrancelha','sobrancelha',2000,10,'10 min','assets/sobrancelha.webp',9 from u union all
select barbershop_id,id,'Pezinho Detalhes','pezinho-detalhes',2500,10,'10 min','assets/pezinho-detalhes.webp',10 from u union all
select barbershop_id,id,'Cabeça Raspada','cabeca-raspada',6000,60,'30–60 min','assets/cabeca-raspada.webp',11 from u
on conflict(unit_id,slug) do update set name=excluded.name,price_cents=excluded.price_cents,duration_min=excluded.duration_min,duration_label=excluded.duration_label,image_path=excluded.image_path,sort_order=excluded.sort_order,is_active=true;

insert into public.professional_services(professional_id,service_id)
select p.id,s.id from public.professionals p join public.services s on s.unit_id=p.unit_id where p.is_active and s.is_active
on conflict(professional_id,service_id) do update set is_active=true;

with u as(select id from public.units where slug='braganca-paulista' and barbershop_id=(select id from public.barbershops where slug='scalabrini-barbieri'))
insert into public.business_hours(unit_id,professional_id,weekday,open_time,close_time,is_closed)
select id,null::uuid,d,'10:00'::time,'20:00'::time,false from u cross join generate_series(1,6) d
union all select id,null::uuid,0,null::time,null::time,true from u
on conflict(unit_id,professional_id,weekday) do update set open_time=excluded.open_time,close_time=excluded.close_time,is_closed=excluded.is_closed;

with u as(select id,barbershop_id from public.units where slug='braganca-paulista' and barbershop_id=(select id from public.barbershops where slug='scalabrini-barbieri')),
s as(select * from public.services where unit_id=(select id from u)),pairs(base,addon,price,dur,ord) as(values
 ('corte','sobrancelha',1500,10,1),
 ('barba-tradizionale','sobrancelha',1500,10,1),
 ('barba-tradizionale','pezinho-detalhes',2500,10,2),
 ('combo-corte-barba','sobrancelha',1500,10,1),
 ('barboterapia','sobrancelha',1500,10,1),
 ('barboterapia','pezinho-detalhes',2500,10,2),
 ('combo-corte-barboterapia','sobrancelha',1500,10,1),
 ('barba-express','sobrancelha',1500,10,1),
 ('barba-express','pezinho-detalhes',2500,10,2),
 ('corte-barba-express','sobrancelha',1500,10,1),
 ('cabeca-raspada','sobrancelha',1500,10,1))
insert into public.service_addons(barbershop_id,unit_id,base_service_id,addon_service_id,addon_price_cents,addon_duration_min,sort_order)
select u.barbershop_id,u.id,b.id,a.id,p.price,p.dur,p.ord from pairs p cross join u join s b on b.slug=p.base join s a on a.slug=p.addon
on conflict(base_service_id,addon_service_id) do update set addon_price_cents=excluded.addon_price_cents,addon_duration_min=excluded.addon_duration_min,sort_order=excluded.sort_order,is_active=true;

