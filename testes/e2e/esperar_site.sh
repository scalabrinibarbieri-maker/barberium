#!/usr/bin/env bash
# Espera o site de teste servir exatamente os arquivos que acabaram de ser montados. O Cloudflare
# leva alguns segundos para trocar a versão depois da publicação; sem esta espera os testes
# poderiam rodar contra a versão anterior. Confere páginas, scripts e estilos (imagens ficam de fora).
#
# Uso: esperar_site.sh <pasta_montada> <endereço_do_site> [limite_em_segundos]
set -euo pipefail
DIST="${1:?pasta montada por deploy/montar_site.sh}"
SITE="${2:?endereço do site de teste}"
LIMITE="${3:-180}"
SITE="${SITE%/}"

mapfile -t ARQUIVOS < <(cd "$DIST" && find . -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' \) | sed 's#^\./##' | sort)
[ "${#ARQUIVOS[@]}" -gt 0 ] || { echo "nenhum arquivo para conferir em $DIST" >&2; exit 1; }

inicio=$SECONDS
while :; do
  diferentes=0; exemplo=""
  for f in "${ARQUIVOS[@]}"; do
    caminho="$f"
    case "$f" in index.html|*/index.html) caminho="${f%index.html}" ;; esac
    if ! curl -fsSL --max-time 20 "$SITE/$caminho" 2>/dev/null | cmp -s - "$DIST/$f"; then
      diferentes=$((diferentes+1)); exemplo="$f"
    fi
  done
  if [ "$diferentes" -eq 0 ]; then
    echo "Site de teste no ar com esta versão (${#ARQUIVOS[@]} arquivos conferidos em $((SECONDS-inicio))s)."
    exit 0
  fi
  if [ $((SECONDS-inicio)) -ge "$LIMITE" ]; then
    echo "::error::Depois de ${LIMITE}s o site de teste ainda serve $diferentes arquivo(s) diferente(s) do que foi publicado (ex.: $exemplo)."
    exit 1
  fi
  echo "Aguardando o site de teste trocar de versão ($diferentes arquivo(s) ainda diferentes)..."
  sleep 10
done
