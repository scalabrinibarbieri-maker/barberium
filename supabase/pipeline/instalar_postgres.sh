#!/usr/bin/env bash
# Instala o Postgres 17 e o pg_cron (repositório oficial do PostgreSQL) no runner do GitHub,
# sem criar o cluster padrão: reconstruir.sh cria o dele, numa porta própria.
set -euo pipefail
sudo install -d /etc/postgresql-common/createcluster.d
echo 'create_main_cluster = false' | sudo tee /etc/postgresql-common/createcluster.d/00-barberium.conf >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq postgresql-common >/dev/null
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null
sudo apt-get install -y -qq postgresql-17 postgresql-17-cron >/dev/null
/usr/lib/postgresql/17/bin/postgres --version
