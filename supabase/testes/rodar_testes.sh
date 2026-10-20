#!/usr/bin/env bash
# Roda os testes de caracterização (supabase/testes/NN_*.sql) num banco que já tenha as
# migrations e os dados fictícios. Cada arquivo roda numa transação desfeita no fim.
#
# Uso: rodar_testes.sh --url URL [arquivo.sql ...]
# Sai com 1 se algum teste falhar. Um teste "vai mudar" (defeito conhecido) não falha
# enquanto o comportamento continuar o mesmo; quando mudar, falha para o teste ser revisto.
set -euo pipefail
export LC_ALL=C.UTF-8
URL=""
ARQS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    *) ARQS+=("$1"); shift ;;
  esac
done
[ -n "$URL" ] || { echo "faltou --url" >&2; exit 64; }
PASTA="$(cd "$(dirname "$0")" && pwd)"
PSQL="${PSQL:-psql}"
if [ ${#ARQS[@]} -eq 0 ]; then
  for f in "$PASTA"/[0-9]*.sql; do ARQS+=("$f"); done
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
total=0; falhas=0; conhecidos=0; erros_arquivo=0
RESUMO="${GITHUB_STEP_SUMMARY:-/dev/null}"
{ echo "## Testes de caracterização"; echo; } >> "$RESUMO"

for arq in "${ARQS[@]}"; do
  nome="$(basename "$arq" .sql)"
  cat > "$TMP/rodar.sql" <<SQL
begin;
\\i '$PASTA/_harness.sql'
\\i '$arq'
select pg_temp.sistema();
\\pset format unaligned
\\pset tuples_only on
\\pset fieldsep '\\t'
\\echo @@RESULTADOS@@
select ok, vai_mudar, replace(descricao, E'\\t', ' '), replace(coalesce(detalhe, ''), E'\\n', ' ') from _resultado order by n;
rollback;
SQL
  if ! "$PSQL" "$URL" -X -q -v ON_ERROR_STOP=1 -f "$TMP/rodar.sql" > "$TMP/saida.txt" 2> "$TMP/erro.txt"; then
    echo "✗ $nome: o arquivo parou no meio"
    { grep -v '^NOTICE\|^psql:.*NOTICE' "$TMP/erro.txt" || true; } | sed -n '1,8s/^/    /p'
    echo "- ✗ **$nome**: o arquivo parou no meio" >> "$RESUMO"
    erros_arquivo=$((erros_arquivo+1))
    continue
  fi
  echo "== $nome"
  n_arq=0; f_arq=0
  while IFS=$'\t' read -r ok muda desc det; do
    total=$((total+1)); n_arq=$((n_arq+1))
    if [ "$ok" = t ] && [ "$muda" = t ]; then
      conhecidos=$((conhecidos+1)); echo "  ~ $desc  (defeito conhecido, vai mudar) ${det:+— $det}"
    elif [ "$ok" = t ]; then
      echo "  ✓ $desc"
    else
      falhas=$((falhas+1)); f_arq=$((f_arq+1))
      if [ "$muda" = t ]; then echo "  ✗ $desc  (era defeito conhecido e o comportamento mudou: revise o teste) — $det"
      else echo "  ✗ $desc — $det"; fi
    fi
  done < <(sed -n '/^@@RESULTADOS@@$/,$p' "$TMP/saida.txt" | tail -n +2)
  if [ "$f_arq" = 0 ]; then echo "- ✓ $nome: $n_arq conferências" >> "$RESUMO"
  else echo "- ✗ **$nome**: $f_arq de $n_arq falharam" >> "$RESUMO"; fi
done

echo
echo "RESULTADO: $total conferências, $falhas falha(s), $conhecidos defeito(s) conhecido(s) registrado(s), $erros_arquivo arquivo(s) interrompido(s)."
{ echo; echo "**$total conferências, $falhas falha(s), $conhecidos defeito(s) conhecido(s), $erros_arquivo arquivo(s) interrompido(s).**"; } >> "$RESUMO"
[ "$falhas" = 0 ] && [ "$erros_arquivo" = 0 ]
