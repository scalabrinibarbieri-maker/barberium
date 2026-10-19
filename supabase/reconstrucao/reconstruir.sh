#!/usr/bin/env bash
# Reconstrói o banco do Barberium do zero: Postgres 17 vazio + base da plataforma + migrations.
# Uso: supabase/reconstrucao/reconstruir.sh <porta> [arquivo_de_versoes]
#   Sem o arquivo, aplica todas as migrations de supabase/migrations.
#   Com o arquivo (uma versão por linha), aplica só essas: é como a produção está hoje.
# Requer postgresql-17 e postgresql-17-cron. As migrations passam pelo mesmo script usado no
# banco de teste e na produção (supabase/pipeline/aplicar_migrations.sh).
set -euo pipefail
export LC_ALL=C
PORT="${1:-5433}"
VERSOES="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN=/usr/lib/postgresql/17/bin
DATA="$(mktemp -d /tmp/barberium-pg.XXXXXX)"
sudo cp "$ROOT/reconstrucao/stubs/pg_net.control" "$ROOT/reconstrucao/stubs/pg_net--0.20.4.sql" /usr/share/postgresql/17/extension/
sudo chown postgres:postgres "$DATA"
sudo -u postgres "$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
sudo -u postgres tee -a "$DATA/postgresql.conf" >/dev/null <<CONF
port = $PORT
listen_addresses = '127.0.0.1'
unix_socket_directories = '/tmp'
shared_preload_libraries = 'pg_cron'
cron.database_name = 'postgres'
timezone = 'UTC'
CONF
sudo -u postgres "$PGBIN/pg_ctl" -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
echo "$DATA" > /tmp/barberium-pg-datadir
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 \
  -f "$ROOT/reconstrucao/plataforma_supabase.sql" >/dev/null
ARGS=(--url "postgresql://postgres@127.0.0.1:${PORT}/postgres" --autor reconstrucao)
[ -n "$VERSOES" ] && ARGS+=(--somente "$VERSOES")
PSQL="$PGBIN/psql" bash "$ROOT/pipeline/aplicar_migrations.sh" "${ARGS[@]}" > /tmp/barberium-reconstrucao.log
n="$("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -At -c 'select count(*) from supabase_migrations.schema_migrations')"
echo "OK: $n migrations aplicadas num banco vazio (porta $PORT)."
