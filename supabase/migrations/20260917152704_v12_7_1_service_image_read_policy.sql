create policy barberium_service_images_select on storage.objects for select to authenticated using(bucket_id='barberium-service-images' and exists(select 1 from barberium.staff_membership() m where m.role in ('owner','admin') and split_part(objects.name,'/',1)=m.barbershop_id::text));

