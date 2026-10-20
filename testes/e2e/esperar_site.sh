#!/usr/bin/env bash
# Espera o site no ar servir exatamente os arquivos que acabaram de ser montados. O Cloudflare
# leva alguns segundos para trocar a versão depois da publicação; sem esta espera os testes
# poderiam rodar contra a versão anterior. Confere páginas, scripts e estilos (imagens ficam de fora).
# Depois (etapa 4) confere a versão em /versao.json e mostra os cabeçalhos de cache que chegaram;
# cabeçalho diferente do pedido no _headers vira aviso, não erro.
#
# Uso: esperar_site.sh <pasta_montada> <endereço_do_site> [limite_em_segundos]
# Etapa 3. Desde a etapa 4 também é usado pelo "Publicar em produção", depois de publicar.
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
    echo "Site no ar com esta versão (${#ARQUIVOS[@]} arquivos conferidos em $((SECONDS-inicio))s)."
    break
  fi
  if [ $((SECONDS-inicio)) -ge "$LIMITE" ]; then
    echo "::error::Depois de ${LIMITE}s o site ($SITE) ainda serve $diferentes arquivo(s) diferente(s) do que foi publicado (ex.: $exemplo)."
    exit 1
  fi
  echo "Aguardando o site trocar de versão ($diferentes arquivo(s) ainda diferentes)..."
  sleep 10
done

[ -f "$DIST/versao.json" ] || exit 0
versao="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versao"])' "$DIST/versao.json")"
no_ar="$(curl -fsS --max-time 20 "$SITE/versao.json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("versao",""))' || true)"
if [ "$no_ar" != "$versao" ]; then
  echo "::error::$SITE/versao.json diz '${no_ar}', mas a versão publicada é '${versao}'."
  exit 1
fi
echo "Versão no ar: $versao"

cabecalho() { curl -fsSI --max-time 20 "$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="cache-control"{print $2}' | head -1; }
script=app.js
[ -f "$DIST/$script" ] || script=equipe/team.js
RESUMO="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "### Site no ar: versão \`$versao\`"
  echo
  echo "| Arquivo | Cache-Control pedido | Cache-Control que chegou |"
  echo "| --- | --- | --- |"
} >> "$RESUMO"
for par in "/|no-cache" "/$script?v=$versao|no-cache" "/versao.json|no-store"; do
  caminho="${par%%|*}"; pedido="${par##*|}"
  chegou="$(cabecalho "$SITE$caminho" || true)"
  echo "| \`$caminho\` | $pedido | ${chegou:-(nenhum)} |" >> "$RESUMO"
  echo "Cache-Control de $caminho: ${chegou:-(nenhum)}"
  case "$chegou" in
    *"$pedido"*) ;;
    *) echo "::warning::$SITE$caminho chegou com Cache-Control '${chegou}', e o _headers pede '$pedido'. Os endereços com a versão continuam garantindo a troca." ;;
  esac
done
