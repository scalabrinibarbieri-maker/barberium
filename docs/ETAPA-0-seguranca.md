# Estabilização · Etapa 0 · Segurança

Data: 19/10/2026. Base: commit 5ae53e7 da main.

## Diagnóstico

1. **Perfil de cliente aberto por telefone.** `barberium_customer_open_profile` (v12.32, chamada sem login) aceitava qualquer nome com 3 letras, sobrescrevia o nome do cadastro e devolvia um token do perfil para quem soubesse só o telefone. Com o token: histórico, aniversário, cancelar e reagendar horários, pedir pausa ou cancelamento de plano.
2. **Agendamento público fazia o mesmo.** `barberium_create_appointment` trocava nome e aniversário de um cliente existente e entregava token novo do perfil.
3. **Escrita entre barbearias.** `barberium_staff_save_commission_config` alterava a comissão de barbeiro de outra barbearia; `barberium_staff_open_cash` e `barberium_staff_assign_membership` aceitavam unidade de outra barbearia.
4. **Área da Equipe antiga no ar.** O deploy publicava `assets/index.html`, `assets/team.js` e `assets/finance-reports.js` (v11.2) em `/assets/`, ligados ao banco de produção.
5. **Sem backup automático.**
6. **Nomes de clientes** em `Readme.me` e `LEIA-ME-v12.22.txt`, num repositório público.

Nenhum token foi emitido por `barberium_customer_open_profile` até 19/10: os 2 tokens sem agendamento junto são de 16/09, antes da função existir. Não há sinal de abuso, então nenhuma sessão de cliente foi derrubada.

## O que mudou

### Banco (aplicado em produção, migration `20261019115931`)

| Função ou tabela | Antes | Agora |
| --- | --- | --- |
| `barberium_customer_open_profile` | Nome + telefone abriam o perfil | Responde `PROFILE_VERIFICATION_REQUIRED`; nada é lido ou alterado |
| `barberium_create_appointment`, cliente novo | Cria cadastro e devolve token | Igual |
| `barberium_create_appointment`, telefone já cadastrado, aparelho com token desse cliente | Atualiza nome/aniversário, reusa token | Igual |
| `barberium_create_appointment`, telefone já cadastrado, sem token dele | Sobrescrevia nome/aniversário e devolvia token | Cria o horário; cadastro intacto; não devolve token (`profile_linked: false`). Se o nome digitado for diferente, ele vai para a nota interna: "Nome informado no site: ..." |
| `barberium_staff_save_commission_config` | Aceitava barbeiro e serviço de outra barbearia | Recusa: "Profissional inválido" / "Serviço inválido" |
| `barberium_staff_open_cash` | Aceitava unidade de outra barbearia | Recusa: "Unidade inválida" |
| `barberium_staff_assign_membership` | Aceitava unidade de outra barbearia | Recusa: "Unidade inválida" |
| `cash_sessions`, `commission_profiles`, `customer_memberships` | Sem garantia de mesma barbearia | FKs compostas: unidade/profissional precisam ser da mesma barbearia da linha |

Permissões das funções (quem pode executar) não mudaram. Nenhum dado foi alterado.

### Repositório (este pacote)

| Arquivo | Mudança |
| --- | --- |
| `.github/workflows/cloudflare-pages.yml` | Tira a Área da Equipe v11.2 de `assets/` do deploy e barra qualquer HTML/JS novo em `assets/` |
| `.github/workflows/backup-banco.yml` | Novo: backup diário criptografado (AES-256), guardado 90 dias como artefato do GitHub |
| `app.js` | Se o agendamento não vincular o perfil, a confirmação explica que o horário está confirmado e orienta falar com a barbearia |
| `client-profile-v12.32.js` | Mensagem clara quando o acesso por nome + WhatsApp está pausado |
| `index.html`, `sw.js` | Versões dos dois arquivos acima e cache do service worker passam para v12.48, para os aparelhos pegarem o JS novo |
| `Readme.me`, `LEIA-ME-v12.22.txt` | Nomes de clientes removidos |
| `migrations/20261019_etapa0_seguranca.sql` | A migration aplicada |
| `docs/etapa0_rollback.sql` | Volta exata às funções anteriores |
| `docs/etapa0_teste_transacional.sql` | Os 14 testes desta etapa |

## Testes executados

Todos no tenant de teste "Barbearia Aurora", dentro de transação desfeita no fim. Rodados antes de aplicar e de novo depois, em produção, com o mesmo resultado:

| # | Cenário | Resultado |
| --- | --- | --- |
| T1 | Cliente novo agenda pelo site | Horário criado, recebe token |
| T2 | Mesmo telefone, sem token, outro nome | Horário criado, sem token, nome do cadastro intacto, nome digitado na nota interna |
| T3 | Mesmo telefone com o token dele, nome novo | Mesmo token, nome atualizado |
| T4 | "Acessar em outro aparelho" | `PROFILE_VERIFICATION_REQUIRED`, nada muda |
| T5 | ADM da Aurora altera comissão de barbeiro da Scalabrini | Recusado |
| T6 | ADM da Aurora altera comissão do próprio barbeiro | Ok |
| T7 | Regra de comissão com serviço da Scalabrini | Recusada |
| T8 | Abrir caixa em unidade da Scalabrini | Recusado |
| T9 | Abrir caixa na própria unidade | Ok |
| T10 | Plano com unidade da Scalabrini | Recusado |
| T10b | Plano com a própria unidade | Passa da checagem de unidade |
| T11 | Inserir caixa misturando barbearias direto na tabela | Barrado pela FK |
| T12 | Mudar comissão de barbearia direto na tabela | Barrado pela FK |
| Extra | Chamada externa pela API pública | `PROFILE_VERIFICATION_REQUIRED` |

A comissão real dos barbeiros da Scalabrini foi conferida antes e depois de cada rodada: sem alteração.

Também foram simulados localmente: a etapa de preparo do deploy (só imagens em `dist/assets`; a trava barra JS em `assets/`) e a criptografia do backup (gera, descriptografa e confere os 5 arquivos).

## Risco

- **Baixo.** A Área da Equipe usa as funções de comissão, caixa e plano só com IDs da própria barbearia; para ela nada muda.
- Cliente que já tem cadastro (por exemplo, criado pela equipe) e agenda pela primeira vez num aparelho novo não vê esse horário em "Meus horários" até existir verificação por WhatsApp. O horário é criado normalmente. Hoje o site do cliente está em manutenção, então ninguém é afetado agora.

## Como reverter

- **Banco:** rodar `docs/etapa0_rollback.sql` no SQL Editor do Supabase. Isso reabre as brechas; use só se algo da equipe quebrar.
- **Site:** reenviar as versões anteriores dos arquivos (estão no histórico do GitHub) ou, no Cloudflare Pages, promover o deploy anterior.

## Pendências desta etapa

1. ~~Criar os segredos `SUPABASE_DB_URL` e `BACKUP_PASSPHRASE` no GitHub e rodar o backup uma vez à mão.~~ Feito em 19/10. Para não depender da API do GitHub, a versão do CLI ficou fixa em 2.120.0. O backup rodou com sucesso e está agendado para todo dia.
2. Tornar o repositório privado: fica para o fim da estabilização, por decisão do dono.
3. Backup das imagens do Storage: fica para a etapa 2 (precisa da chave de serviço como segredo).
4. Deploys antigos do Cloudflare Pages continuam acessíveis pelo endereço próprio de cada deploy (`*.barberium.pages.dev`). Não expõem dados além do que a API já controla, mas podem ser apagados no painel do Cloudflare.
