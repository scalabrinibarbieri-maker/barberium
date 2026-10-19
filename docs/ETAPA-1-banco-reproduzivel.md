# Estabilização · Etapa 1 · Banco reproduzível

Data: 19/10/2026. Base: commit d7be377 da main.

Meta da etapa: **banco vazio + migrations do repositório = banco de produção** (funções, tabelas, colunas, índices, triggers, permissões, jobs agendados, buckets). Isso agora é conferido automaticamente.

## Diagnóstico

1. **O histórico do banco não estava no repositório.** A produção tem 90 migrations registradas. A pasta `migrations/` do repositório tinha 25 arquivos, e só 9 deles batem em versão ou nome com o que está registrado. Não dava para recriar o banco a partir do GitHub.
2. **Mudanças feitas direto no banco, sem migration:**
   - 3 funções existiam só na produção: `barberium_staff_cancel_completed_appointment_v12_23` (v12.23), `barberium_staff_free_ranges` e `barberium_staff_performance_v12_33` (v12.33).
   - As permissões de 4 funções foram mudadas direto: `barberium_customer_open_profile`, `barberium_staff_finance_report` e as duas camadas internas do relatório financeiro.
   - O relatório financeiro v12.8.1 (17/09) renomeou e criou funções direto no banco. Sem ele, a migration v12.11 (`20260918193258`) falha num banco vazio com "Função alvo não encontrada".
3. **A edge function `barberium-push` e a configuração dela** (`verify_jwt = false`) só existiam no Supabase.
4. **Nada avisava** quando alguém mudava o banco pelo painel sem deixar registro.

## O que mudou

### Repositório

| Arquivo | O que é |
| --- | --- |
| `supabase/migrations/` (92 arquivos) | O histórico completo: as 90 migrations exportadas da produção, mais as 2 novas abaixo |
| `supabase/migrations/20260917210000_retroativo_v12_8_1_relatorio_financeiro.sql` | Reconstitui o que o v12.8.1 fez direto no banco, para a v12.11 poder ser reaplicada |
| `supabase/migrations/20261019120000_captura_drift_producao.sql` | Traz as 3 funções que só existiam na produção e iguala as permissões das 7 funções envolvidas |
| `supabase/reconstrucao/plataforma_supabase.sql` | Recria num Postgres comum o que o Supabase já traz pronto: papéis, `auth.uid()`, `storage`, `vault` e `pg_cron` |
| `supabase/reconstrucao/stubs/` | Versão de teste do `pg_net`: grava os pedidos numa fila e não envia nada |
| `supabase/reconstrucao/reconstruir.sh` | Cria um Postgres 17 vazio e aplica a base e as 92 migrations, nessa ordem |
| `supabase/reconstrucao/impressao_digital.sql` | Resume o schema inteiro num JSON (sem nenhum dado de cliente) |
| `supabase/reconstrucao/comparar_impressao.py` | Compara a produção com o banco reconstruído e confere o histórico de migrations |
| `supabase/functions/barberium-push/index.ts` | Código da edge function, igual à versão 4 publicada |
| `supabase/config.toml` | Configuração do Supabase CLI 2.120.0, com `verify_jwt = false` para a edge function |
| `.github/workflows/banco-reproduzivel.yml` | **Novo.** Reconstrói o banco do zero e compara com a produção, que é lida em modo somente leitura |
| `.github/workflows/aplicar-pacote.yml` | **Novo.** Você envia um `pacote-*.zip` pelo celular e ele descompacta, faz o commit e dispara o deploy e a conferência |
| `.github/workflows/cloudflare-pages.yml` | Não publica quando o push traz só o ZIP. Faz um deploy por vez, na ordem. A mensagem do commit passa por variável, para não virar comando |
| `migrations/LEIA-ME.md` | Marca a pasta antiga como histórica |

A pasta de conferência se chama `supabase/reconstrucao/` e não `supabase/tests/` de propósito. O comando `supabase test db --linked` executa tudo o que está em `supabase/tests/` **contra a produção**, e a base da plataforma não pode rodar lá.

### Banco de produção

Nenhuma função, permissão, tabela ou dado foi alterado. Mudam só duas linhas na tabela de controle do Supabase (`supabase_migrations.schema_migrations`): as 2 migrations novas ficam **registradas sem serem executadas**, porque a produção já está no estado que elas descrevem.

Status: feito em 19/10/2026 às 16h45. O pedido de permissão não aparece no celular, então o próprio dono rodou o comando no SQL Editor do Supabase. O comando tinha sido testado antes numa transação desfeita. Nas 2 linhas do histórico ficou uma nota apontando para o arquivo no repositório, no lugar do SQL completo. Repositório e produção têm as mesmas 92 versões (conferido pelo md5 da lista).

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Postgres 17 vazio + base da plataforma + 92 migrations | Todas aplicadas, sem erro, em cerca de 2 s |
| 2 | Comparação campo a campo: produção × reconstruído (203 funções, 67 tabelas, views e sequências, extensões, 2 jobs, 2 buckets, 7 políticas do storage, permissões de schema e padrões) | 0 diferenças |
| 3 | A mesma comparação refeita depois de todos os ajustes, pelo resumo (md5) de cada uma das 9 seções, lido na produção | As 9 seções idênticas |
| 4 | A comparação detecta problemas? Simulei uma permissão alterada, uma função a menos, um job a mais e uma versão sem arquivo | Pegou as 4 coisas e falhou, como devia |
| 5 | Leitura da produção em modo somente leitura | Um `create table` nesse modo é recusado pelo banco |
| 6 | As 7 funções da captura, conferidas na produção sem alterar | md5 e permissões exatamente como na migration |
| 7 | Aplicador de pacote: ZIP correto, ZIP com `../`, caminho absoluto, `.github/`, `.GIT/`, barra invertida e link simbólico, ZIP com pasta por fora, `_remover.txt` apontando para `.github/` e `../` | O correto foi aplicado. Os perigosos foram recusados inteiros, sem gravar nada. A pasta por fora foi removida certinho |
| 8 | Disparo do deploy e da conferência depois do pacote | Dispara só o que mudou. Se o disparo falhar, vira aviso com instrução |
| 9 | `actionlint` (com `shellcheck`) nos 3 workflows e `shellcheck` no script | Sem apontamentos |
| 10 | `config.toml` lido pelo CLI 2.120.0; edge function comparada com a versão publicada | Ok; idêntica |

## Risco

- **Banco: nenhum.** O registro só acrescenta 2 linhas de controle.
- **Site: baixo.** O deploy mudou em 3 pontos pequenos. Se algo der errado, o deploy não roda e o site continua com a versão atual no ar.
- **Aplicador de pacote:** escreve na main. Só quem tem acesso de escrita ao repositório consegue disparar. Ele recusa qualquer caminho perigoso e não toca em `.github/`.
- **Conferência do banco:** usa a mesma conexão do backup (`SUPABASE_DB_URL`), sempre em modo somente leitura. A primeira rodada pode mostrar 2 avisos amarelos ("não consta no histórico da produção") até o registro ser feito. É esperado.

## Como reverter

- **Repositório:** apague os arquivos novos ou volte `cloudflare-pages.yml` para a versão anterior, que está no histórico do GitHub.
- **Banco (registro):** `delete from supabase_migrations.schema_migrations where version in ('20260917210000','20261019120000');`. Isso apaga só as 2 linhas de controle.

## Como usar daqui para frente

- **Quando "Banco reproduzível" falhar:** alguém mudou o banco sem migration, ou uma migration nova não foi aplicada. O log diz exatamente o que difere. O jeito certo de corrigir é transformar a mudança num arquivo novo em `supabase/migrations/`.
- **Mudança nova no banco:** sempre como arquivo `supabase/migrations/<AAAAMMDDHHMMSS>_<nome>.sql`, testado antes numa transação desfeita.
- **Não rode** `supabase db push`, `supabase config push` nem `supabase test db --linked` à mão. A aplicação automática fica para a etapa 2.

## Ajustes depois da subida (19/10)

| O que aconteceu | Causa | Correção |
| --- | --- | --- |
| A primeira rodada de "Banco reproduzível" falhou em 23 s, na leitura da produção | O segredo `SUPABASE_DB_URL` termina com uma quebra de linha. O psql procurou o banco `"postgres\n"`; o login em si funcionou (log do pooler do Supabase às 19:20 UTC). O CLI do backup ignora a quebra, por isso o backup roda | O workflow agora remove espaços e quebras de linha da URL antes de conectar. Testado localmente com a mesma URL quebrada: o erro foi reproduzido e corrigido |
| O deploy apareceu duplicado: `cloudflare-pages.yml` (antigo) e `cloudflare-pages-2.yml` | O celular renomeou o arquivo baixado, porque já havia um com o mesmo nome | Apagar `cloudflare-pages-2.yml` e reenviar `cloudflare-pages.yml` com o nome exato (agora dentro de um ZIP, que preserva os nomes) |
| A Área da Equipe antiga (v11.2) continuava no ar em `scalabrinibarbieri-maker.github.io/barberium/assets/` | O GitHub Pages está ligado neste repositório e publica tudo o que está nele. A etapa 0 tirou esses arquivos só do Cloudflare | Este pacote apaga `assets/index.html`, `assets/team.js` e `assets/finance-reports.js` do repositório (ficam no histórico do Git). O Cloudflare não muda, porque já não os publicava. Recomendado também desligar o GitHub Pages, que mantém uma cópia não oficial do site |

## Pendências

1. ~~Registrar as 2 migrations no histórico da produção.~~ Feito em 19/10.
2. Desligar o GitHub Pages (Settings > Pages), se ninguém usa o endereço `github.io`.
3. Tornar o repositório privado no fim da estabilização. Os workflows continuam funcionando, dentro do limite de minutos do plano.
4. Etapa 2: ambiente de testes (staging) e aplicação de migrations pelo GitHub Actions.
