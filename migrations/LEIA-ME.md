# Pasta histórica: não usar

Desde a etapa 1 da estabilização (19/10/2026), **a fonte oficial do banco é `supabase/migrations/`**.

Esta pasta guarda os arquivos SQL como foram enviados entre as versões v11 e v12.10, mais a etapa 0. Ela fica no repositório só como registro e está incompleta:

- Das 90 migrations aplicadas em produção até 19/10, só 9 aparecem aqui com a mesma versão ou o mesmo nome. As outras existiam só no histórico do banco.
- Vários nomes usam só a data (`20260916_...`), sem a hora. Por isso não dá para saber a ordem em que foram aplicados.
- `20261019_etapa0_seguranca.sql` tem o mesmo SQL que `supabase/migrations/20261019115931_etapa0_seguranca_identidade_isolamento.sql`. Muda só nos comentários.

**Não rode nenhum destes arquivos.** Vários deles recriam funções em versões antigas e desfariam correções que já estão em produção.

Toda mudança nova no banco entra como arquivo em `supabase/migrations/`, no formato `<AAAAMMDDHHMMSS>_<nome>.sql`. O workflow "Banco reproduzível" confere esses arquivos com a produção.
