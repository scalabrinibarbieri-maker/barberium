// Barberium · configuração comum (etapa 5, 20/10/2026).
// Endereço e chave pública do Supabase. São valores públicos (o navegador precisa deles).
// A montagem do site de teste (deploy/montar_site.sh) troca os dois pelos do banco de teste.
export const SUPABASE_URL = 'https://pmvvawbaqylspxfmxezw.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_CveglntZGjChE89lPcsQcg_EvBnYmKo';

// Onde a Área da Equipe guarda o login no aparelho. Mudar o nome desconecta todo mundo.
export const CHAVE_SESSAO_EQUIPE = 'barberium_staff_auth_v1';
