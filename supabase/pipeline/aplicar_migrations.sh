#!/usr/bin/env bash
# Aplica num banco as migrations de supabase/migrations que ainda não estão no histórico dele
# (supabase_migrations.schema_migrations). Usado igual no banco de teste, na produção e na
# reconstrução local, para que o caminho testado seja o mesmo que vai para a produção.
#
# Uso: aplicar_migrations.sh --url URL [--ensaio] [--somente ARQUIVO] [--autor NOME]
#   --ensaio    roda cada migration pendente e desfaz (rollback). Não altera nada.
#   --somente   aplica só as versões listadas no arquivo (uma por linha). Usado para
#               reconstruir localmente o banco exatamente como a produção está.
#   --autor     vai para a coluna created_by do histórico (padrão: pipeline).
#
# Regras (qualquer uma falha e nada mais é aplicado):
#   * o banco não pode ter versão no histórico sem arquivo no repositório;
#   * uma migration pendente não pode ser mais antiga que a última já aplicada;
#   * o arquivo não pode ter BEGIN/COMMIT/ROLLBACK próprios;
#   * todas as pendentes rodam numa transação só, junto com o registro no histórico:
#     ou entram todas, ou nenhuma.
set -euo pipefail
export LC_ALL=C

URL="" ; ENSAIO=0 ; SOMENTE="" ; AUTOR="pipeline"
PASTA="$(cd "$(dirname "$0")/../migrations" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --ensaio) ENSAIO=1; shift ;;
    --somente) SOMENTE="$2"; shift 2 ;;
    --autor) AUTOR="$2"; shift 2 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 64 ;;
  esac
done
[ -n "$URL" ] || { echo "faltou --url" >&2; exit 64; }

PSQL="${PSQL:-psql}"
q() { "$PSQL" "$URL" -X -q -At -v ON_ERROR_STOP=1 "$@"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Histórico do banco (vazio se a tabela ainda não existe).
if [ "$(q -c "select to_regclass('supabase_migrations.schema_migrations') is not null")" = "t" ]; then
  q -c "select version from supabase_migrations.schema_migrations order by 1" > "$TMP/banco.txt"
  TEM_HISTORICO=1
else
  : > "$TMP/banco.txt"
  TEM_HISTORICO=0
fi

# Arquivos do repositório.
for f in "$PASTA"/*.sql; do basename "$f"; done | sort > "$TMP/arquivos.txt"
cut -d_ -f1 "$TMP/arquivos.txt" > "$TMP/repo.txt"
if [ "$(sort -u "$TMP/repo.txt" | wc -l)" -ne "$(wc -l < "$TMP/repo.txt")" ]; then
  echo "ERRO: duas migrations com a mesma versão em supabase/migrations." >&2; exit 2
fi

sem_arquivo="$(comm -23 <(sort "$TMP/banco.txt") "$TMP/repo.txt")"
if [ -n "$sem_arquivo" ]; then
  echo "ERRO: o banco tem versões aplicadas sem arquivo no repositório:" >&2
  while read -r x; do echo "  $x" >&2; done <<< "$sem_arquivo"
  exit 2
fi

comm -13 <(sort "$TMP/banco.txt") "$TMP/repo.txt" > "$TMP/pendentes.txt"
if [ -n "$SOMENTE" ]; then
  grep -xFf <(tr -d '\r' < "$SOMENTE" | sed '/^$/d') "$TMP/pendentes.txt" > "$TMP/p2.txt" || true
  mv "$TMP/p2.txt" "$TMP/pendentes.txt"
fi

ultima="$(tail -n1 "$TMP/banco.txt")"
# Confere todas as pendentes antes de rodar qualquer coisa.
n=0
: > "$TMP/rodar.sql"
echo "begin;" >> "$TMP/rodar.sql"
if [ "$ENSAIO" = 0 ] && [ "$TEM_HISTORICO" = 0 ]; then
  echo "create schema if not exists supabase_migrations;" >> "$TMP/rodar.sql"
  echo "create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text, created_by text, idempotency_key text unique, rollback text[]);" >> "$TMP/rodar.sql"
fi
while read -r v; do
  [ -n "$v" ] || continue
  if [ -n "$ultima" ] && [[ "$v" < "$ultima" ]]; then
    echo "ERRO: a migration $v é mais antiga que a última aplicada ($ultima). Renomeie com uma versão nova." >&2
    exit 3
  fi
  arq="$PASTA/$(grep "^${v}_" "$TMP/arquivos.txt")"
  nome="$(basename "$arq" .sql)"; nome="${nome#"${v}"_}"
  if grep -Eiq '^[[:space:]]*(commit|rollback|begin[[:space:]]*(transaction|work)?)[[:space:]]*;' "$arq"; then
    echo "ERRO: $(basename "$arq") controla transação por conta própria (BEGIN/COMMIT/ROLLBACK)." >&2
    exit 4
  fi
  {
    printf '%s\n' "\\echo '>> $(basename "$arq")'" "\\i '$arq'"
    if [ "$ENSAIO" = 0 ]; then
      printf '%s\n' "\\set versao '$v'" "\\set nome '$nome'" "\\set conteudo \`cat '$arq'\`"
      echo "insert into supabase_migrations.schema_migrations(version, name, statements, created_by) values (:'versao', :'nome', array[:'conteudo'], :'autor');"
    fi
  } >> "$TMP/rodar.sql"
  n=$((n+1))
done < "$TMP/pendentes.txt"
if [ "$ENSAIO" = 1 ]; then echo "rollback;" >> "$TMP/rodar.sql"; else echo "commit;" >> "$TMP/rodar.sql"; fi

if [ "$n" = 0 ]; then
  echo "OK: nenhuma migration pendente."
  exit 0
fi

# Todas as pendentes numa transação só: ou entram todas, ou nenhuma.
if ! q -v autor="$AUTOR" -f "$TMP/rodar.sql" > "$TMP/saida.txt" 2> "$TMP/erro.txt"; then
  falhou="$(grep '^>> ' "$TMP/saida.txt" | tail -n1 | cut -c4-)"
  echo "ERRO na migration ${falhou:-?}. Nada foi aplicado (a transação foi desfeita):" >&2
  grep -v '^NOTICE' "$TMP/erro.txt" | head -20 >&2
  exit 1
fi
grep '^>> ' "$TMP/saida.txt" | cut -c4- | while read -r f; do
  if [ "$ENSAIO" = 1 ]; then echo "  ensaio ok: $f"; else echo "  aplicada: $f"; fi
done
if [ "$ENSAIO" = 1 ]; then
  echo "ENSAIO OK: $n migration(s) pendente(s) rodam sem erro, juntas (tudo desfeito)."
else
  echo "OK: $n migration(s) aplicada(s)."
fi
