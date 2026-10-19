#!/usr/bin/env bash
# Reconstrói o banco do Barberium do zero: Postgres 17 vazio + base da plataforma + todas as migrations.
# Uso: supabase/reconstrucao/reconstruir.sh <porta>   (padrão 5433). Requer postgresql-17 e postgresql-17-cron.
set -euo pipefail
export LC_ALL=C   # ordem das migrations = ordem dos nomes, byte a byte
PORT="${1:-5433}"
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
PSQL=("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -f "$ROOT/reconstrucao/plataforma_supabase.sql" >/dev/null
n=0
for f in "$ROOT"/migrations/*.sql; do
  n=$((n+1))
  if ! "${PSQL[@]}" --single-transaction -f "$f" >/dev/null 2>/tmp/barberium-migration-erro.txt; then
    echo "ERRO na migration $n: $(basename "$f")"
    grep -v '^NOTICE' /tmp/barberium-migration-erro.txt | head -10
    exit 1
  fi
done
echo "OK: $n migrations aplicadas num banco vazio (porta $PORT)."
