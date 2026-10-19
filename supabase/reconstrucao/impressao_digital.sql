-- Impressão digital do schema do Barberium: tudo o que define o comportamento do banco,
-- sem os dados. Roda igual em produção e no banco reconstruído; os dois resultados devem ser idênticos.
with
fn as (
  select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' as k,
         json_build_object('src_md5',md5(p.prosrc),'secdef',p.prosecdef,'config',coalesce(array_to_string(p.proconfig,';'),''),
           'volatile',p.provolatile,'lang',l.lanname,'returns',pg_get_function_result(p.oid),'kind',p.prokind,
           'args',pg_get_function_arguments(p.oid),'owner',pg_get_userbyid(p.proowner),
           'acl',(select string_agg(x::text,',' order by x::text) from unnest(coalesce(p.proacl,'{}'::aclitem[])) x)) as v
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang
  where n.nspname in ('public','barberium') and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
),
rel as (
  select n.nspname||'.'||c.relname as k,
         json_build_object('kind',c.relkind,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,'owner',pg_get_userbyid(c.relowner),
           'acl',(select string_agg(x::text,',' order by x::text) from unnest(coalesce(c.relacl,'{}'::aclitem[])) x),
           'comment',obj_description(c.oid,'pg_class'),
           'view',case when c.relkind in ('v','m') then md5(pg_get_viewdef(c.oid)) end,
           'columns',(select json_object_agg(a.attname, concat_ws(' | ',format_type(a.atttypid,a.atttypmod),case when a.attnotnull then 'not null' end,
                        pg_get_expr(ad.adbin,ad.adrelid),nullif(a.attidentity,''),nullif(a.attgenerated,'')) order by a.attname)
                      from pg_attribute a left join pg_attrdef ad on ad.adrelid=a.attrelid and ad.adnum=a.attnum
                      where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),
           'constraints',(select json_object_agg(co.conname,pg_get_constraintdef(co.oid) order by co.conname) from pg_constraint co where co.conrelid=c.oid),
           'indexes',(select json_object_agg(i.relname,pg_get_indexdef(i.oid) order by i.relname) from pg_index x join pg_class i on i.oid=x.indexrelid where x.indrelid=c.oid),
           'triggers',(select json_object_agg(t.tgname,pg_get_triggerdef(t.oid) order by t.tgname) from pg_trigger t where t.tgrelid=c.oid and not t.tgisinternal),
           'policies',(select json_object_agg(po.policyname,concat_ws(' | ',po.cmd,array_to_string(po.roles,','),po.qual,po.with_check) order by po.policyname) from pg_policies po where po.schemaname=n.nspname and po.tablename=c.relname)
         ) as v
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname in ('public','barberium') and c.relkind in ('r','p','v','m','S','f')
    and not exists(select 1 from pg_depend d where d.objid=c.oid and d.deptype='e')
),
typ as (
  select n.nspname||'.'||t.typname as k,
         json_build_object('type',t.typtype,'labels',(select string_agg(e.enumlabel,',' order by e.enumsortorder) from pg_enum e where e.enumtypid=t.oid)) as v
  from pg_type t join pg_namespace n on n.oid=t.typnamespace
  where n.nspname in ('public','barberium') and t.typtype in ('e','d') 
)
select json_build_object(
  'functions',(select json_object_agg(k,v order by k) from fn),
  'relations',(select json_object_agg(k,v order by k) from rel),
  'types',(select json_object_agg(k,v order by k) from typ),
  'extensions',(select json_object_agg(e.extname,n.nspname order by e.extname) from pg_extension e join pg_namespace n on n.oid=e.extnamespace
                where e.extname in ('btree_gist','pgcrypto','uuid-ossp','pg_cron','pg_net')),
  'cron_jobs',(select json_object_agg(jobname,concat_ws(' | ',schedule,regexp_replace(command,'\s+',' ','g'),active) order by jobname) from cron.job),
  'buckets',(select json_object_agg(id,concat_ws(' | ',public,file_size_limit,array_to_string(allowed_mime_types,',')) order by id) from storage.buckets),
  'storage_policies',(select json_object_agg(policyname,concat_ws(' | ',cmd,array_to_string(roles,','),qual,with_check) order by policyname) from pg_policies where schemaname='storage'),
  'schema_acl',(select json_object_agg(nspname,(select string_agg(x::text,',' order by x::text) from unnest(coalesce(nspacl,'{}'::aclitem[])) x) order by nspname) from pg_namespace where nspname in ('public','barberium')),
  'default_acl',(select json_object_agg(coalesce(n.nspname,'*')||':'||d.defaclobjtype::text,(select string_agg(x::text,',' order by x::text) from unnest(d.defaclacl) x) order by coalesce(n.nspname,'*')||':'||d.defaclobjtype::text)
                 from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace where pg_get_userbyid(d.defaclrole)='postgres' and (n.nspname in ('public','barberium') or n.nspname is null))
)::text as fingerprint;
