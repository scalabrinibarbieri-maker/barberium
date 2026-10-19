# Estabilização · Etapa 2 · Ambiente de teste e publicação em duas fases

Data: 19/10/2026. Base: commit f7a5737 da main.

Meta da etapa: toda mudança é testada num banco e num site de teste, com dados fictícios, antes de chegar na produção. A produção só é publicada à mão, depois da conferência. O guia de uso é o [COMO-PUBLICAR.md](COMO-PUBLICAR.md).

## Diagnóstico

1. **Todo envio para a main ia direto para a produção.** O deploy rodava a cada push, sem teste e sem confirmação.
2. **Não havia onde testar de verdade.** Para testar login, site e banco juntos, só existia a produção. Os testes da etapa 0 rodaram na produção, dentro de transações desfeitas, no tenant Aurora.
3. **O banco de produção era alterado fora do GitHub**, por quem tivesse acesso ao painel.
4. **O deploy não era determinístico.** Ele usava `wrangler@latest` e copiava "todo `.js` da raiz": uma versão nova do wrangler, ou um arquivo esquecido na raiz, ia para o ar sem ninguém decidir.

## O que mudou

### Supabase

| Item | Detalhe |
| --- | --- |
| Projeto `barberium-staging` (ref `neiountvnbhxmbenovmm`) | Segundo projeto do plano grátis, em Canada (Central), criado pelo dono em 19/10. O banco é montado só pelas migrations do repositório |
| Segredo `STAGING_DB_SENHA` | Senha do banco de teste. O workflow monta a conexão sozinho e testa os endereços do pooler até um responder |
| Segredo `STAGING_SENHA_TESTE` | Senha dos 3 logins de teste |

A produção não foi alterada nesta etapa.

### Repositório

| Arquivo | O que é |
| --- | --- |
| `supabase/pipeline/aplicar_migrations.sh` | Aplica as migrations pendentes num banco. É o mesmo script na reconstrução local, no teste e na produção. Recusa histórico sem arquivo, migration fora de ordem e arquivo com BEGIN/COMMIT próprio. Todas as pendentes rodam numa transação só (ou entram todas, ou nenhuma). `--ensaio` roda e desfaz |
| `supabase/pipeline/conexao.sh` | Monta as conexões de produção e de teste a partir dos segredos. Ignora espaços e quebras de linha nas pontas e não imprime senha |
| `supabase/pipeline/instalar_postgres.sh` | Instala o Postgres 17 e o pg_cron no runner. Antes isso estava repetido em cada workflow |
| `supabase/reconstrucao/reconstruir.sh` | Passa a usar o `aplicar_migrations.sh` e aceita uma lista de versões, para reconstruir o banco exatamente como a produção está |
| `supabase/reconstrucao/plataforma_supabase.sql` | `auth.users` e `auth.identities` com as mesmas colunas da produção, para testar os logins fictícios localmente |
| `supabase/reconstrucao/comparar_impressao.py` | Novas opções `--alvo teste` (mensagens), `--exigir-todas` (depois de publicar, migration faltando vira erro) e `--titulo` |
| `supabase/staging/projeto.env` | Ref, região, endereço e chave publicável do teste. São valores públicos, como os da produção que já aparecem no site |
| `supabase/staging/dados_ficticios.sql` | Cria os logins de teste, a equipe da Scalabrini de teste, a Barbearia Aurora (com os mesmos IDs da produção), 6 clientes fictícios em cada uma e 2 horários futuros em cada uma, marcados pelo próprio fluxo do site. Pode rodar várias vezes sem duplicar. Aborta se o banco tiver cara de produção |
| `deploy/arquivos-do-site.txt` | Lista explícita do que vai para o ar: 49 arquivos, os mesmos do deploy antigo, menos 2 `.gitkeep`. 3 deles estão marcados "sem uso" e saem na etapa 9 |
| `deploy/montar_site.sh` | Monta o site a partir da lista. No teste, troca o endereço e a chave pela do banco de teste, põe a faixa "AMBIENTE DE TESTE" e o prefixo [TESTE] no título, e pede aos buscadores para não indexar |
| `deploy/conferir_referencias.py` | Para o deploy se alguma página ou o service worker carregar um arquivo que não está na lista |
| `.github/workflows/staging.yml` | **Novo: "Publicar no teste".** Faz os testes, aplica as migrations no teste, cria os dados fictícios, confere que o teste ficou igual ao banco reconstruído e publica o site de teste |
| `.github/workflows/cloudflare-pages.yml` | **Agora é "Publicar em produção"**, e só roda à mão. Exige a caixa "Já conferi o site de teste" e que a mesma versão tenha passado no teste. Depois roda os testes, o ensaio, a aplicação, a conferência da produção e por fim o site. O nome do arquivo ficou o antigo de propósito: o envio dele substitui o deploy automático, sem precisar apagar nada |
| `.github/workflows/banco-reproduzivel.yml` | Compara a produção com uma reconstrução **só das versões que a produção tem**. Antes, uma migration nova ainda não publicada aparecia como diferença. Depois prova que as migrations novas rodam. Agora também pode ser chamado pelos outros workflows |
| `.github/workflows/aplicar-pacote.yml` | Depois do pacote, dispara "Publicar no teste", a menos que só tenha mudado documentação |
| `docs/COMO-PUBLICAR.md` | Guia de uso para o dia a dia |

Versões fixas: wrangler 4.146.0 (de 01/10/2026), Node 22, `actions/checkout@v6`, `actions/setup-node@v6` e `actions/upload-artifact@v6`. Estas três já rodam em Node 24, então some o aviso de Node 20.

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Reconstrução local pelo script novo, comparada com a produção | Idêntica |
| 2 | Produção simulada + 2 migrations novas, a segunda dependendo da primeira: reconstrução só com as versões da produção | Idêntica à produção; as 2 aparecem como "ainda não publicada" |
| 3 | Ensaio das 2 na produção simulada | Rodam juntas; nada muda (histórico continua com 92 e a função não existe) |
| 4 | Aplicação das 2 | Produção simulada fica idêntica ao banco reconstruído completo |
| 5 | Rodar de novo | "nenhuma migration pendente" |
| 6 | Versão no banco sem arquivo no repositório | Recusa (código 2) |
| 7 | Migration nova com data mais antiga que a última aplicada | Recusa (código 3) |
| 8 | Migration com COMMIT próprio | Recusa (código 4) |
| 9 | 2 migrations, a segunda com erro | O ensaio já falha. Na aplicação, nenhuma das duas entra: histórico e tabelas intactos |
| 10 | Projeto novo, sem histórico, como o teste estará na primeira rodada | 92 migrations em 1,6 s; dados fictícios criados; teste idêntico ao banco reconstruído |
| 11 | Segunda publicação no teste | Nada pendente; dados fictícios não duplicam |
| 12 | Logins de teste (local) | A senha confere nos 3 (bcrypt, o formato do login do Supabase); o barbeiro fica ligado ao Vinicius da Scalabrini de teste. O login de verdade é conferido na primeira publicação no teste |
| 13 | Dados fictícios num banco com 72 clientes e sem a marca de teste | Aborta antes de gravar |
| 14 | Senha de teste com menos de 12 caracteres | Aborta |
| 15 | Site de produção pela lista nova × deploy antigo | Idênticos, arquivo por arquivo (só as 2 `.gitkeep` saem) |
| 16 | Site de teste | Nenhum endereço ou chave da produção sobrando; faixa, título e "noindex" presentes |
| 17 | Arquivo carregado pela equipe e faltando na lista | O deploy para e mostra qual arquivo falta |
| 18 | Conexão com senha cheia de símbolos (`@ / # : %`), espaço e quebra de linha nas pontas | URL correta; o pooler certo é encontrado |
| 19 | Projeto de teste real, só leitura | Mesmas colunas de `auth.users` e mesmas permissões padrão da produção |
| 20 | `actionlint` (com `shellcheck`) nos 5 workflows e `shellcheck` nos scripts | Sem apontamentos |

## Risco

- **Banco de produção: nenhum nesta etapa.** Daqui para frente, migration só entra na produção pelo "Publicar em produção", depois do teste, do ensaio e numa transação só.
- **Mudança de hábito:** enviar arquivos não publica mais o site real. Depois de conferir o teste, é preciso rodar "Publicar em produção".
- **Primeira rodada do teste:** pode aparecer alguma diferença própria do Supabase que não existe na reconstrução local. Se acontecer, só o teste é afetado, e eu corrijo.
- **O site de teste é público.** Mas ele só tem dados fictícios e pede para não ser indexado. Quem criar conta lá não ganha acesso a nenhuma barbearia.

## Como reverter

- **Voltar ao deploy automático antigo:** reenviar a versão anterior do `cloudflare-pages.yml`, que está no histórico do GitHub.
- **Teste:** apagar o projeto `barberium-staging` no Supabase e os segredos `STAGING_*`. Não afeta a produção.
- **Site de produção:** usar o rollback do Cloudflare (está no [COMO-PUBLICAR.md](COMO-PUBLICAR.md)).

## Ajustes depois da subida (19/10)

| O que aconteceu | Causa | Correção |
| --- | --- | --- |
| A primeira rodada de "Publicar no teste" falhou ao conectar no banco de teste: `missing "=" after "::add-mask::***"` | O aviso que esconde a senha nos logs saía dentro de `$(url_staging)` e foi parar no começo da URL. O teste local não pegou porque rodou sem `GITHUB_ACTIONS=true` | O aviso agora sai quando o `conexao.sh` é carregado, fora da URL. Testado com os passos exatos dos dois workflows, `GITHUB_ACTIONS=true` e um pooler simulado (aws-0 recusa, aws-1 responde). O teste rodou do banco vazio até o site montado, e a produção até a conferência final, com uma migration nova de exemplo |

## Pendências

1. A edge function de notificações não está no teste. Para publicá-la lá, é preciso um token de acesso do Supabase como segredo. Sem ela, as notificações ficam desligadas no teste.
2. Backup das imagens do Storage (pendência da etapa 0).
3. Etapa 3: testes de caracterização rodando no teste. Com os logins de teste, dá para usar o Playwright como cliente, barbeiro e ADM.
