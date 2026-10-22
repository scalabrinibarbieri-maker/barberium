#!/usr/bin/env bash
# Monta a pasta que vai para o Cloudflare Pages a partir da lista explícita deploy/arquivos-do-site.txt.
# Uso: deploy/montar_site.sh <pasta_destino> <producao|teste>
#   producao: os arquivos vão como estão (apontando para o banco de produção).
#   teste:    troca o endereço e a chave pública do Supabase pelos do banco de teste
#             (supabase/staging/projeto.env), põe uma faixa "AMBIENTE DE TESTE" nas páginas
#             e pede aos buscadores para não indexar.
# Nos dois casos (etapa 4) carimba a versão da publicação (o commit) nos endereços dos scripts,
# nas páginas, no service worker e em versao.json, e escreve os cabeçalhos de cache (_headers).
# A versão vem de COMMIT_SITE, GITHUB_SHA ou do commit atual; VERSAO_SITE força outra (só para testes).
set -euo pipefail
DEST="${1:?pasta de destino}"
AMB="${2:?producao ou teste}"
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
LISTA="$RAIZ/deploy/arquivos-do-site.txt"
PROD_URL='https://pmvvawbaqylspxfmxezw.supabase.co'
PROD_CHAVE='sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo'

case "$AMB" in producao|teste) ;; *) echo "ambiente inválido: $AMB" >&2; exit 64 ;; esac
rm -rf "$DEST"; mkdir -p "$DEST"

n=0
while IFS= read -r linha || [ -n "$linha" ]; do
  f="${linha%%#*}"; f="$(printf '%s' "$f" | tr -d '[:space:]')"
  [ -n "$f" ] || continue
  case "$f" in
    /*|*..*) echo "ERRO: caminho não permitido na lista: $f" >&2; exit 1 ;;
    assets/*.html|assets/*.js) echo "ERRO: assets/ é só para imagens: $f" >&2; exit 1 ;;
  esac
  [ -f "$RAIZ/$f" ] || { echo "ERRO: $f está na lista mas não existe no repositório." >&2; exit 1; }
  install -D -m 0644 "$RAIZ/$f" "$DEST/$f"
  n=$((n+1))
done < "$LISTA"
echo "$n arquivos copiados da lista."

COMMIT="${COMMIT_SITE:-${GITHUB_SHA:-$(git -C "$RAIZ" rev-parse HEAD 2>/dev/null || true)}}"
[ -n "$COMMIT" ] || { echo "ERRO: sem commit para carimbar a versão (rode dentro do repositório)." >&2; exit 1; }
VERSAO="${VERSAO_SITE:-${COMMIT:0:7}}"
DATA="$(git -C "$RAIZ" log -1 --format=%cI "$COMMIT" 2>/dev/null || true)"
python3 "$RAIZ/deploy/carimbar_versao.py" "$DEST" "$VERSAO" "$COMMIT" "$DATA"

# Cabeçalhos de cache. Páginas, scripts, estilos e o service worker: o navegador sempre confere
# se mudou (no-cache). versao.json: nunca guardado. Imagens: o padrão do Cloudflare.
cat > "$DEST/_headers" <<'CABECALHOS'
# Gerado por deploy/montar_site.sh (etapa 4).
/
  Cache-Control: no-cache
/index.html
  Cache-Control: no-cache
/equipe/
  Cache-Control: no-cache
/equipe/index.html
  Cache-Control: no-cache
/*.js
  Cache-Control: no-cache
/*.css
  Cache-Control: no-cache
/site.webmanifest
  Cache-Control: no-cache
/versao.json
  Cache-Control: no-store
CABECALHOS

python3 "$RAIZ/deploy/conferir_referencias.py" "$DEST"

if [ "$AMB" = teste ]; then
  # shellcheck disable=SC1091
  . "$RAIZ/supabase/staging/projeto.env"
  : "${STAGING_URL:?}" "${STAGING_CHAVE_PUBLICA:?}"
  grep -rlF -e "$PROD_URL" -e "$PROD_CHAVE" "$DEST" --include='*.js' --include='*.html' | while read -r arq; do
    sed -i -e "s#${PROD_URL}#${STAGING_URL}#g" -e "s#${PROD_CHAVE}#${STAGING_CHAVE_PUBLICA}#g" "$arq"
  done
  if grep -rqF -e "$PROD_URL" -e "$PROD_CHAVE" "$DEST"; then
    echo "ERRO: sobrou endereço ou chave da produção no site de teste:" >&2
    grep -rlF -e "$PROD_URL" -e "$PROD_CHAVE" "$DEST" >&2
    exit 1
  fi
  faixa='<div style="position:fixed;left:0;right:0;bottom:0;z-index:2147483647;background:#b45309;color:#fff;font:600 12px/1.7 system-ui,sans-serif;text-align:center;padding:2px 8px;pointer-events:none">AMBIENTE DE TESTE · dados fictícios · não é o site real</div>'
  for pagina in "$DEST/index.html" "$DEST/equipe/index.html" "$DEST/painel/index.html"; do
    python3 - "$pagina" "$faixa" <<'PY'
import sys
caminho, faixa = sys.argv[1], sys.argv[2]
html = open(caminho, encoding="utf-8").read()
if "</body>" not in html or "<title>" not in html:
    sys.exit(f"página sem <title> ou </body>: {caminho}")
html = html.replace("<title>", "<title>[TESTE] ", 1).replace("</body>", faixa + "\n</body>", 1)
open(caminho, "w", encoding="utf-8").write(html)
PY
  done
  printf '/*\n  X-Robots-Tag: noindex, nofollow\n' >> "$DEST/_headers"
  echo "Site de TESTE montado: aponta para ${STAGING_URL}."
else
  if [ -f "$RAIZ/supabase/staging/projeto.env" ]; then
    # shellcheck disable=SC1091
    . "$RAIZ/supabase/staging/projeto.env"
    if grep -rqF -e "${STAGING_URL:-@@nada@@}" -e "${STAGING_CHAVE_PUBLICA:-@@nada@@}" "$DEST"; then
      echo "ERRO: o site de produção tem endereço ou chave do banco de teste." >&2
      exit 1
    fi
  fi
  grep -rqF "$PROD_URL" "$DEST" || { echo "ERRO: o site de produção não aponta para o banco de produção." >&2; exit 1; }
  echo "Site de PRODUÇÃO montado: aponta para ${PROD_URL}."
fi
