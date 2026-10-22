#!/usr/bin/env bash
# Publica o site em cada endereço <nome>.barberium.pages.dev cadastrado pelo painel do dono.
# Cada endereço é um ramo do projeto "barberium" no Cloudflare Pages, com uma cópia do site
# montado (a mesma versão da produção) personalizada para a barbearia (deploy/personalizar_barbearia.py).
#
# Uso: deploy/publicar_enderecos.sh <pasta_do_site_montado> [--so-faltando]
#   --so-faltando  publica só os endereços que ainda não estão nesta versão (o resto fica).
# Precisa: SUPABASE_DB_URL (lido em modo somente leitura), CLOUDFLARE_API_TOKEN,
# CLOUDFLARE_ACCOUNT_ID, PSQL e WRANGLER (wrangler com versão fixa).
set -euo pipefail
DIST="${1:?pasta do site montado}"
SO_FALTANDO="${2:-}"
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PSQL="${PSQL:-psql}"
: "${WRANGLER:?}"
# shellcheck disable=SC1091
source "$RAIZ/supabase/pipeline/conexao.sh"
URL="$(url_producao)"
VERSAO="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versao"])' "$DIST/versao.json")"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$DIST/versao.json")"
q() { "$PSQL" "$URL" -X -q -At -v ON_ERROR_STOP=1 -c 'set default_transaction_read_only = on' -c "$1"; }

mapfile -t HOSTS < <(q "select d.host from public.barbershop_domains d join public.barbershops b on b.id = d.barbershop_id
                        where d.host like '%.barberium.pages.dev' and d.host <> 'barberium.pages.dev' and b.status = 'active' order by 1")
echo "${#HOSTS[@]} endereço(s) de barbearia no Barberium. Versão da produção: $VERSAO"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
publicados=0; iguais=0
for host in "${HOSTS[@]}"; do
  ramo="${host%.barberium.pages.dev}"
  if ! [[ "$ramo" =~ ^[a-z0-9]([a-z0-9-]{1,26}[a-z0-9])$ ]] || [[ "$ramo" == main || "$ramo" == staging ]]; then
    echo "::warning::$host: nome de ramo inválido ou reservado, pulado."; continue
  fi
  if [ "$SO_FALTANDO" = "--so-faltando" ]; then
    no_ar="$(curl -fsS -m 15 "https://$host/versao.json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("versao",""))' 2>/dev/null || true)"
    if [ "$no_ar" = "$VERSAO" ]; then iguais=$((iguais+1)); continue; fi
  fi
  dados="$(q "select public.barberium_resolve_tenant('$host')::text")"
  copia="$TMP/$ramo"
  cp -a "$DIST" "$copia"
  python3 "$RAIZ/deploy/personalizar_barbearia.py" "$copia" "$dados"
  npx --yes "$WRANGLER" pages deploy "$copia" --project-name=barberium --branch="$ramo" \
    --commit-hash="$COMMIT" --commit-message="Endereço da barbearia: $host" > "$TMP/$ramo.log" 2>&1 \
    || { cat "$TMP/$ramo.log"; echo "::error::Falhou a publicação de $host"; exit 1; }
  for _ in $(seq 1 36); do
    no_ar="$(curl -fsS -m 15 "https://$host/versao.json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("versao",""))' 2>/dev/null || true)"
    [ "$no_ar" = "$VERSAO" ] && break
    sleep 5
  done
  [ "$no_ar" = "$VERSAO" ] || { echo "::error::$host não mostrou a versão $VERSAO depois de 3 minutos"; exit 1; }
  echo "  no ar: https://$host/ (versão $VERSAO)"
  publicados=$((publicados+1))
done
echo "Publicados: $publicados. Já estavam nesta versão: $iguais."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "## Endereços das barbearias: $publicados publicado(s), $iguais já em dia (versão $VERSAO)" >> "$GITHUB_STEP_SUMMARY"
fi
