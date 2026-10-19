do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as proc
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'barberium_staff_%'
  loop
    execute format('revoke all on function %s from public, anon', r.proc);
    execute format('grant execute on function %s to authenticated, service_role', r.proc);
  end loop;
end $$;

