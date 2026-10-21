# Estabilização · Etapa 6 · Barbearia pelo endereço

Data: 21/10/2026. Base: a main com a etapa 5 publicada (versão `3f9b73a`).

Meta da etapa: preparar o Barberium para ter outras barbearias além da Scalabrini, sem mudar nada para a Scalabrini.

- O site descobre de qual barbearia é pelo endereço em que foi aberto.
- O banco garante que os dados de uma barbearia nunca se misturam com os de outra.

Decisões do dono (21/10):

- **Endereço:** cada barbearia pode usar o próprio domínio ou um endereço do Barberium. As duas formas funcionam.
- **Unidades:** a barbearia escolhe se cada endereço abre uma unidade fixa ou se o cliente escolhe a unidade. O ADM continua vendo os relatórios de todas as unidades.
- **Cadastro de barbearias novas:** pelo painel do dono do SaaS, na próxima etapa. Esta etapa prepara o banco e o site para ele.

## Diagnóstico

Medido em 21/10, no banco de produção (só leitura) e no código da main.

1. **A barbearia estava escrita no código.**
   - `scalabrini-barbieri` e `braganca-paulista` apareciam em 6 arquivos do site do cliente, junto com o nome do login guardado no aparelho.
   - A Área da Equipe tinha "Scalabrini Barbieri" fixo no título, na tela de login, no topo e nos PDFs.
   - Uma segunda barbearia não tinha como ter site.
2. **A equipe podia cair na barbearia errada.**
   - Toda função da equipe (são 126) descobre a barbearia do login pela `barberium.staff_membership()`.
   - Essa função pegava "um" vínculo do login, sem ordem.
   - Com um login na equipe de duas barbearias, cada chamada podia cair numa barbearia diferente.
   - Hoje nenhum login tem dois vínculos, então isso ainda não aconteceu.
3. **Ligações entre tabelas sem trava de barbearia.** O banco tem 87 ligações entre tabelas que pertencem a uma barbearia, por exemplo um atendimento que aponta para um cliente.
   - Só 3 exigiam que os dois lados fossem da mesma barbearia (feitas na etapa 0). Nas outras 84, isso dependia de cada função lembrar de conferir.
   - Conferido em 21/10: nenhuma linha na produção aponta para outra barbearia.
4. **Permissões abertas por padrão.**
   - Visitante (`anon`) e usuário logado (`authenticated`) tinham todos os privilégios em 44 das 60 tabelas. Hoje ninguém lê nada por esse caminho, porque todas as tabelas têm RLS sem policy.
   - O padrão do banco liberava para eles toda tabela, sequência e função criada daqui em diante. Então uma tabela nova criada sem RLS ficaria aberta.
   - Três funções da equipe (Saldos, horários livres e desempenho) podiam ser chamadas por visitante. Elas recusavam por dentro ("Não autenticado").
5. **Meta financeira em unidade de outra barbearia.** O defeito que os testes da etapa 3 registraram: o ADM de uma barbearia conseguia gravar uma meta apontando para a unidade de outra.

## O que mudou

### Banco (4 migrations, aplicadas na publicação em produção)

| Migration | O que faz |
| --- | --- |
| `20261021100000_etapa6_dominios_e_tenant` | Tabela `barbershop_domains`: endereço do site → barbearia, com unidade fixa opcional. Função pública `barberium_resolve_tenant`, que o site chama ao abrir. Cadastra `scalabrinibarbiere.com` e `barberium.pages.dev`, os dois fixos em Bragança, como hoje |
| `20261021100100_etapa6_barbearia_ativa_na_equipe` | `staff_membership()` passa a usar a barbearia do endereço, que o site manda no cabeçalho `x-barberium-barbearia`. Sem o cabeçalho, vale o vínculo só se o login tiver um, como hoje. Login com dois vínculos e sem cabeçalho: sem acesso, em vez de cair numa barbearia ao acaso |
| `20261021100200_etapa6_fks_mesma_barbearia` | As 84 ligações passam a exigir a mesma barbearia dos dois lados. Cada trava nova apaga e atualiza exatamente como a ligação que já existia, então apagar um registro faz o mesmo de antes |
| `20261021100300_etapa6_permissoes_e_correcoes` | Tira os privilégios diretos de visitante e usuário logado nas tabelas. Tabela, sequência e função criadas daqui em diante nascem fechadas, e cada migration precisa liberar o que for público. As 3 funções da equipe deixam de ser chamáveis por visitante. A meta financeira confere se a unidade é da barbearia do login |

Endereços:

- Os endereços reais ignoram `?barbearia=`.
- Os endereços de teste aceitam. São eles o site de teste e o `127.0.0.1` dos testes no computador, cadastrados só no banco de teste.

### Site do cliente

- **`shared/tenant.js` (novo):** ao abrir, pergunta ao banco de qual barbearia é o endereço e em qual unidade.
  - Endereço com unidade fixa (a Scalabrini): abre direto, como hoje.
  - Sem unidade fixa e com mais de uma unidade: mostra "Escolha a unidade". A escolha fica guardada no aparelho, e o botão "Trocar unidade" aparece no cartão da unidade.
  - Endereço não cadastrado: "Endereço não encontrado". Sem internet: "Sem conexão", com "Tentar de novo".
- **`app.js`, `barberium-client-v12.24.js`, `membership.js`, `client-profile-v12.32.js` e `service-cta-v12.38.js`:** usam a barbearia e a unidade do endereço no lugar do texto fixo.
- **Login do cliente no aparelho:** um por barbearia. A Scalabrini mantém o nome de antes (`barberium_scalabrini_session_v1`), então nenhum cliente é desconectado.
- **Textos e padrões:**
  - A confirmação do horário e o texto de privacidade usam o nome da barbearia.
  - O círculo do perfil, sem cliente identificado, mostra as iniciais da barbearia (continua "SB" na Scalabrini).
  - O rótulo da capa, quando não está preenchido em Ajustes, passa a ser o nome da barbearia, e não mais "Casa Scalabrini". A Scalabrini da produção já tem "Casa Scalabrini" salvo em Ajustes, então nada muda para ela.
- **Logo da tela de abertura:** guardado pelo endereço do site. O nome de antes continua valendo para quem já tinha aberto o site.

### Área da Equipe

- **`shared/api.js`:** toda chamada ao banco leva o cabeçalho com a barbearia do endereço. Cada login entra só pelo endereço da própria barbearia.
- **`team.js` e `finance-reports.js`:** título, tela de login, topo e os PDFs (clientes e relatórios financeiros) usam o nome da barbearia do cadastro. Se a barbearia tiver logo em Ajustes → Apresentação, ele aparece na tela de login e no topo.
- **`equipe/index.html`:** a página não traz mais o nome escrito. Ele aparece quando o endereço é confirmado, uma fração de segundo depois de abrir.

### O que muda para a Scalabrini

Só uma coisa aparece diferente: na Área da Equipe, o nome vem do cadastro da barbearia. Lá está **"Scalabrini Barbiere"**, como no site do cliente; antes, a Área da Equipe tinha "Scalabrini Barbieri" escrito à mão. Isso aparece:

- no título da aba;
- na tela de login;
- no topo;
- nos PDFs.

Para mudar o nome, basta mudar o cadastro.

### Limites conhecidos (ficam para as próximas etapas)

- **O conteúdo fixo da página do cliente ainda é o da Scalabrini.** São os itens abaixo; o painel do dono do SaaS deve preencher os padrões de cada barbearia nova:
  - título e descrição que aparecem no Google e na prévia de links do WhatsApp;
  - horário de funcionamento do cartão da unidade ("Segunda a sábado, 10:00 — 20:00");
  - foto da capa e logo, quando a barbearia não cadastrou os dela;
  - textos de serviços, quando não preenchidos;
  - nome e ícone do app instalado;
  - ícone das notificações.
- **Na tela, a Scalabrini nunca aparece para outra barbearia,** exceto pela foto da capa e pelo logo, enquanto ela não cadastrar os dela em Ajustes → Apresentação. A página montada por barbearia está prevista na etapa 7h.
- **Endereço novo:** cadastrar na tabela `barbershop_domains` (pelo painel da próxima etapa) e adicionar o domínio no projeto do Cloudflare Pages.
  - Os endereços de cada publicação do Cloudflare (`<código>.barberium.pages.dev`) não estão cadastrados e mostram "Endereço não encontrado". É de propósito.
- **Chamadas do site do cliente:** continuam com as próprias cópias. O plano da etapa 5 previa passar essas chamadas para o núcleo nesta etapa, mas isso muda o tratamento de erro das telas do cliente. Fica para a etapa 7, quando os módulos do cliente forem refeitos.
- **Login de teste da Aurora na produção:** passa a precisar de um endereço da Aurora. Esse login nunca foi usado; o endereço será decidido junto com o painel.

## Testes adicionados

| Onde | Testes |
| --- | --- |
| `supabase/testes/07_tenant_dominios_e_permissoes.sql` (novo, 30 conferências) | Endereço → barbearia (com `www.`, porta, maiúsculas), `?barbearia=` ignorado no endereço real, endereço não cadastrado, visitante não lê a tabela, endereço de teste, unidade escolhida e inválida, barbearia inativa, logo. Equipe: cabeçalho da própria barbearia, de outra, sem cabeçalho, barbeiro, login em duas barbearias. Toda ligação entre tabelas de barbearia (inclusive de tabela nova) exige a mesma barbearia. Permissões: nenhuma tabela aberta, tabela e função novas nascem fechadas, `service_role` continua. Meta financeira |
| `supabase/testes/04_…` e `05_…` | O defeito da meta saiu da lista de conhecidos. Lista de funções do visitante atualizada: +1 (`barberium_resolve_tenant`), −3 (as da equipe) |
| `testes/e2e/tenant.spec.js` (novo, 4 testes no navegador, com o banco de teste) | Endereço não cadastrado. Unidade fixa. Aurora com duas unidades: escolher, lembrar e trocar. Sem conexão e "Tentar de novo" |
| `testes/e2e/equipe.spec.js` (+1) | ADM da Aurora entra pelo endereço da Aurora. O ADM da Scalabrini **não** entra pelo endereço da Aurora: isso prova que o cabeçalho chega ao banco, porque sem ele o ADM entraria |
| Dados fictícios do banco de teste | Segunda unidade da Aurora (Unidade Norte, com Bruno Lima e Corte Norte) e os endereços de teste |

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Banco reconstruído como a produção + etapa 6 + dados fictícios; todos os testes do banco | 244 conferências, 0 falhas |
| 2 | Ensaio das 4 migrations (rodam e desfazem) | OK |
| 3 | Produção (só leitura): ligações que a etapa 6 trava | 87 ligações, 0 linhas apontando para outra barbearia |
| 4 | Rollback: etapa 6 → `docs/etapa6_rollback.sql` → impressão digital do banco | Idêntica à de antes da etapa 6. Aplicar a etapa 6 de novo depois do rollback: igual à primeira vez, testes verdes |
| 5 | **Passeio antes × depois**, com o banco local restaurado antes de cada passeio. Site do cliente: agendar, confirmar, Meus horários, perfil, cancelar (13 telas). Área da Equipe: ADM e barbeiro (24 telas cada) | Mesmas chamadas ao banco, com os mesmos dados, e o mesmo texto em todas as telas. A única chamada a mais é a do endereço, uma vez ao abrir. Toda chamada da equipe levou o cabeçalho da Scalabrini. Fotos das telas da equipe: 45 de 45 idênticas. Fotos do site do cliente: 10 de 13 idênticas; as outras 3 diferem só pelas animações, como acontece entre duas rodadas do próprio site antigo (6 de 13 idênticas) |
| 6 | Site antigo com o banco novo (o passeio "antes" do item 5 rodou no banco com a etapa 6) | Funciona igual. Quem estiver com o site antigo aberto durante a publicação não é afetado |
| 7 | 28 cenários no site novo: Aurora com escolha de unidade, agendamento na Unidade Norte, login do cliente separado por barbearia, lembrar e trocar a unidade, `?unidade=`, endereço não cadastrado (site e equipe), sem conexão, equipe da Aurora pelo endereço da Aurora, ADM de uma barbearia no endereço da outra | 28 de 28 |
| 8 | Todos os testes no navegador (26), com uma cópia local do site e do Supabase | 26 de 26 |
| 9 | Erro de propósito: sem o cabeçalho da barbearia no núcleo | O teste novo da equipe falha, como deveria |
| 10 | ESLint nos 9 arquivos alterados | Nenhum erro. Os mesmos 6 avisos de antes (variável sem uso) |

## Risco

- **Médio, por ser a primeira etapa que muda o banco desde a etapa 0.** Proteções:
  - tudo foi testado no banco reconstruído igual à produção;
  - o ensaio roda na própria produção antes de aplicar;
  - o rollback devolve o banco exatamente como estava;
  - o site antigo funciona com o banco novo.
- **Site novo depende de uma chamada a mais ao abrir.**
  - Se o banco não responder, aparece "Sem conexão", com "Tentar de novo". Antes, aparecia "Agendamentos temporariamente indisponíveis".
  - A chamada é pequena e acontece junto com o carregamento da página.
- **Travas novas nas ligações:** uma função antiga que tentasse ligar dados de duas barbearias passa a dar erro, em vez de gravar errado. Os testes não encontraram nenhuma.
- **Permissões padrão:** uma migration futura que criar função pública precisa liberar com GRANT. Se esquecer, os testes do banco acusam antes de chegar na produção.

## Como reverter

Na ordem:

1. **Site:** "Rollback" no Cloudflare para o deploy anterior (está no [COMO-PUBLICAR.md](COMO-PUBLICAR.md)). Isso vem primeiro porque o site novo precisa do banco novo.
2. **Banco:** rodar `docs/etapa6_rollback.sql` inteiro no SQL Editor do Supabase. Ou entra tudo, ou nada.
3. **Repositório:** apagar os 4 arquivos `supabase/migrations/20261021*_etapa6_*.sql`. Sem isso, a próxima publicação aplica a etapa 6 de novo.
