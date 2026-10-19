# shellcheck shell=bash
# Funções para montar as URLs de conexão nos workflows. Uso: source supabase/pipeline/conexao.sh
# Nenhuma função imprime senha: as URLs só vão para variáveis.

# Segredos colados pelo celular às vezes chegam com espaço ou quebra de linha no começo ou no fim.
_limpar() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_codificar() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# No GitHub, esconde dos logs a senha do teste na forma em que ela entra na URL.
# Isto roda ao carregar o arquivo (fora de qualquer "$(...)"), porque o aviso ao GitHub
# precisa sair na saída normal do passo. Dentro de "$(url_staging)" ele iria parar na URL.
if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "${STAGING_DB_SENHA:-}" ]; then
  echo "::add-mask::$(_codificar "$(_limpar "$STAGING_DB_SENHA")")"
fi

# Produção: o segredo SUPABASE_DB_URL já é a URL completa (pooler, modo session).
url_producao() {
  local u; u="$(_limpar "${SUPABASE_DB_URL:-}")"
  [ -n "$u" ] || { echo "Falta o segredo SUPABASE_DB_URL." >&2; return 1; }
  printf '%s' "$u"
}

# Teste: o segredo STAGING_DB_SENHA é só a senha; o resto vem de supabase/staging/projeto.env.
# O endereço do pooler varia por projeto (aws-0, aws-1...), então testamos até um responder.
url_staging() {
  local raiz senha enc host u
  raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck disable=SC1091
  . "$raiz/staging/projeto.env"
  senha="$(_limpar "${STAGING_DB_SENHA:-}")"
  [ -n "$senha" ] || { echo "Falta o segredo STAGING_DB_SENHA." >&2; return 1; }
  enc="$(_codificar "$senha")"
  for host in aws-0 aws-1 aws-2; do
    u="postgresql://postgres.${STAGING_REF}:${enc}@${host}-${STAGING_REGIAO}.pooler.supabase.com:5432/postgres?sslmode=require&connect_timeout=10"
    if "${PSQL:-psql}" "$u" -X -q -At -c 'select 1' >/dev/null 2>&1; then
      printf '%s' "$u"
      return 0
    fi
  done
  echo "Não consegui conectar no banco de teste (projeto ${STAGING_REF}). Confira o segredo STAGING_DB_SENHA." >&2
  return 1
}
