# Estabilização · Etapa 6B · Painel do dono do SaaS

Data: 21/10/2026. Base: a main com a etapa 6 publicada (versão `04904ab`).

Meta da etapa: o dono do Barberium cadastra uma barbearia nova sozinho, pelo celular, sem SQL e sem mexer no Supabase. A barbearia ganha um endereço, e o dono dela recebe pelo WhatsApp um convite para criar a senha.

Decisões do dono (21/10):

- **Onde fica o painel:** em https://barberium.pages.dev/painel/, que abre só com o login de quem é dono do Barberium.
- **Como o dono da barbearia recebe o acesso:** por um link de convite mandado pelo WhatsApp. O e-mail ficou de fora porque o Supabase, sem um serviço de e-mail próprio, só manda e-mail para quem é da equipe do projeto. E esse serviço precisaria de um domínio.
- **Endereço da barbearia:** `nome.barberium.pages.dev`, grátis, enquanto não houver um domínio do Barberium.
- **O que entra nesta primeira versão:** cadastrar a barbearia e o dono dela. Suspender barbearias e ver os números de cada uma ficam para depois.

## Diagnóstico

1. **Não havia como cadastrar uma barbearia.** Barbearia, unidade, endereço e acesso da equipe só existiam por SQL. Não havia nenhuma função para criar a barbearia nem o login do dono dela.
2. **Não havia o papel de "dono do Barberium".** Só existiam os papéis dentro de cada barbearia: proprietário, ADM e barbeiro.
3. **O e-mail de convite do Supabase não chega a quem está fora da equipe do projeto.** Isso vale até existir um serviço de e-mail próprio (documentação: "Send emails with custom SMTP").
4. **A página do site tinha a Scalabrini escrita à mão,** além do que o JavaScript troca:
   - título e descrição, que aparecem no Google e na prévia do link no WhatsApp;
   - WhatsApp, mapa e horário do cartão da unidade;
   - logo da tela de abertura e ícone do app.

   Uma barbearia nova apareceria com a Scalabrini na prévia do WhatsApp.

## O que mudou

### Banco (migration `20261021200000_painel_dono_do_saas`)

| O quê | Para quê |
| --- | --- |
| `barberium.platform_admins` | Quem é dono do Barberium. Ninguém entra por migration: o primeiro é cadastrado pelo SQL Editor (passo a passo abaixo) |
| `barberium.barbershop_invites` | Convites do painel: e-mail, nome e WhatsApp do convidado e quando o link foi gerado |
| `barberium_platform_whoami()` | O painel pergunta se o login é dono do Barberium |
| `barberium_platform_barbershops()` | Lista do painel: barbearias, endereços, unidades, proprietários e ADMs com o último acesso, e convites |
| `barberium_platform_create_barbershop(...)` | Cria tudo numa transação só: barbearia, primeira unidade, horário inicial, endereço `nome.barberium.pages.dev` (unidade fixa) e convite. Confere nome, endereço (3 a 28 letras, sem repetir nem usar nome reservado), estado, WhatsApp e e-mail |
| `barberium_platform_invite_detail(id)` | A função de convite lê o convite, com o login de quem chamou |
| `barberium_platform_link_invite(id, login)` | Só o servidor (service_role) chama: liga o login criado à barbearia como **Proprietário**, se o e-mail do login for o do convite |

Todas as funções do painel recusam quem não é dono do Barberium ("Acesso somente para o dono do Barberium"). Visitante não chama nenhuma delas.

**Como uma barbearia nova começa:**

- **Site do cliente em manutenção,** com a mensagem "Estamos preparando a agenda online. Em breve você poderá agendar por aqui."
- **Logo do Barberium, capa neutra (`assets/capa-padrao.webp`) e o nome da barbearia no rótulo da capa.** Nada da Scalabrini.
- **Horário de segunda a sábado, das 9h às 19h,** e os serviços de rascunho "Corte" e "Barba", como toda unidade nova.
- **Regras de agenda:** 30 dias à frente, intervalo de 15 minutos e antecedência mínima de 30 minutos.

O dono da barbearia ajusta tudo isso na Área da Equipe e abre o site em Ajustes.

### Função de convite (`supabase/functions/barberium-convite`)

1. Confere no banco, com o login de quem chamou, se é dono do Barberium, e lê o convite.
2. Cria o login do convidado no Supabase sem mandar e-mail (`generate_link`). Se o e-mail já tem login, gera um link de senha nova para o mesmo login.
3. Liga o login à barbearia.
4. Devolve o código do link.

A lógica fica em `logica.js` e usa só `fetch`, sem biblioteca. Por isso ela roda igual no Supabase e nos testes do computador.

### Área da Equipe: "Crie sua senha" (`equipe/convite.js`)

O link abre a Área da Equipe com `?convite=...`. A tela:

- troca o login por "Crie sua senha" e confere a senha antes de gastar o link (8 caracteres no mínimo, as duas iguais);
- confere o código no Supabase (ele vale uma vez só), grava a senha e entra;
- tira o código do endereço depois de usado.

Link vencido ou já usado mostra: "Este link venceu ou já foi usado. Peça um link novo para quem te convidou."

### Painel (`painel/`)

- **Login do dono do Barberium.** Outro login vê "Este login não é dono do Barberium."
- **Lista de barbearias:**
  - endereço, unidades e tamanho da equipe;
  - proprietário, com "último acesso" ou "ainda não entrou";
  - botão de **convite**, para quem ainda não entrou, ou de **senha nova**, para quem já entrou e esqueceu a senha.
- **Nova barbearia:** o endereço é sugerido a partir do nome, sem acento.
- **Mensagem pronta,** com botão **Enviar pelo WhatsApp** (já com o número do dono) e **Copiar mensagem**. Ela traz o link do convite, o endereço da Área da Equipe e o do site dos clientes.

### Endereços `nome.barberium.pages.dev`

- **Um ramo por barbearia:** cada endereço é um ramo do projeto `barberium` no Cloudflare Pages, com a mesma versão da produção.
- **Cópia personalizada** (`deploy/personalizar_barbearia.py`): título, descrição, ícone, logo, WhatsApp, mapa e nome do app da barbearia. O horário escrito à mão vira "Veja os horários livres ao agendar". Se algum trecho esperado não existir, a publicação para em vez de publicar com texto da Scalabrini.
- **`deploy/publicar_enderecos.sh`:** lê no banco (só leitura) os endereços das barbearias ativas, publica cada um e confere a versão no ar.
- **Quando os endereços são publicados:**
  - **Publicar em produção:** depois do site principal, publica todos os endereços.
  - **Publicar endereços** (workflow novo): de hora em hora e à mão, publica só os endereços novos ou desatualizados.
- **A Scalabrini não muda:** continua no `scalabrinibarbiere.com` e no `barberium.pages.dev`, sem personalização.

### Workflows

- **Publicar no teste e Publicar em produção:** publicam a função de convite (`supabase functions deploy ... --no-verify-jwt --use-api`). Isso precisa do segredo novo **`SUPABASE_ACCESS_TOKEN`**.
- **Publicar em produção** também publica os endereços.
- **Publicar endereços** (`enderecos.yml`): novo.
- **Ordem de envio:** os três pulam a parte nova quando a versão ainda não tem a função ou o script. Assim, a ordem de envio dos arquivos não deixa nada vermelho.

## Configuração única (o dono faz uma vez)

1. **Token do Supabase:** em https://supabase.com/dashboard/account/tokens, crie um token chamado "GitHub Barberium". Guarde-o no GitHub como segredo `SUPABASE_ACCESS_TOKEN`. Esse token tem acesso amplo à sua conta do Supabase: não o compartilhe com ninguém.
2. **Você como dono do Barberium:** depois da publicação em produção, rode no SQL Editor do Supabase (projeto de produção), com o seu e-mail de login:

   ```sql
   insert into barberium.platform_admins (auth_user_id)
   select id from auth.users where email = 'SEU-EMAIL-AQUI'
   returning auth_user_id;
   ```

   Ele devolve 1 linha. Se devolver 0, o e-mail está diferente do login.

## Como cadastrar uma barbearia

1. Abra https://barberium.pages.dev/painel/ e entre com o seu login de sempre.
2. Toque em **+ Nova barbearia** e preencha: nome, endereço, primeira unidade e o dono da barbearia (nome, e-mail e WhatsApp).
3. Toque em **Cadastrar e gerar convite**.
4. Para o endereço entrar no ar agora, vá em GitHub → Actions → **Publicar endereços** → Run workflow. Sem isso, ele entra sozinho em até 1 hora.
5. Toque em **Enviar pelo WhatsApp**. O link vale uma vez só e vence depois de pouco tempo (no Supabase, o padrão é 1 hora). Se vencer, toque no botão de convite da barbearia, na lista, para gerar outro.
6. O dono da barbearia abre o link, cria a senha e entra. Depois, na Área da Equipe, ele cadastra serviços, barbeiros e horários e desliga a manutenção em Ajustes.

## Limites conhecidos

- **Os endereços `nome.barberium.pages.dev` não aparecem no Google.** O Cloudflare marca os ramos como "não indexar". A barbearia que quiser aparecer na busca precisa de domínio próprio, que fica para a etapa dos endereços.
- **Barbeiros da barbearia nova:** o dono dela cadastra os barbeiros na Área da Equipe, mas o login de cada barbeiro ainda é criado à mão. O próximo passo é a equipe convidar os próprios barbeiros com o mesmo link.
- **Endereço novo leva até 1 hora,** ou um toque em Publicar endereços.
- **Suspender barbearia e ver os números de cada uma** ficaram de fora desta versão, como decidido.

## Testes adicionados

| Onde | Testes |
| --- | --- |
| `supabase/testes/08_painel_do_dono.sql` (32 conferências) | Quem usa o painel (visitante, ADM de barbearia, dono). Cadastro: padrões neutros, horário, serviços de rascunho, convite, endereço abrindo a barbearia nova fixa na unidade. Recusas: endereço repetido, reservado, com espaço; e-mail e estado inválidos. Convite: só o servidor liga o login, o e-mail precisa ser o do convite, gerar de novo não duplica. O dono novo entra como Proprietário só pelo endereço da barbearia dele e não vira dono do Barberium |
| `testes/e2e/painel.spec.js` (2 testes, no site de teste, com a função de verdade) | ADM de barbearia não entra no painel. O dono do Barberium cadastra (ou reaproveita) a "Barbearia Painel Teste", gera o link, e o convidado cria a senha e entra como Proprietário |
| Dados fictícios do banco de teste | Login `dono.barberium@example.com`, dono do Barberium só no teste |

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Banco reconstruído como a produção + etapa 6B + dados fictícios; todos os testes do banco | 276 conferências, 0 falhas |
| 2 | Ensaio da migration; rollback (`docs/etapa6b_rollback.sql`) e impressão digital do banco | Ensaio ok. O rollback volta à impressão digital de antes, e aplicar de novo dá igual |
| 3 | Fluxo completo no computador, com um Supabase local que imita o convite (`generate_link`, `verify` e troca de senha). Passos: dono entra no painel, cadastra, gera o convite; o convidado cria a senha, entra como Proprietário e depois entra com e-mail e senha; o link usado não funciona de novo; o site do cliente da barbearia nova abre em manutenção com o logo do Barberium | 18 de 18, tanto com a chave antiga do servidor (`SUPABASE_SERVICE_ROLE_KEY`) quanto com a nova (`SUPABASE_SECRET_KEYS`), que a função prefere quando existe |
| 4 | Cópia personalizada aberta no próprio endereço (`nome.barberium.pages.dev`, apontado para o computador) | Nenhum "Scalabrini" no HTML que o WhatsApp e o Google leem, nem na tela. O dono entra pela Área da Equipe sem `?barbearia=` |
| 5 | `publicar_enderecos.sh` com Cloudflare simulado | Publica e confere cada endereço. A segunda rodada não publica nada, porque tudo já está na versão |
| 6 | Todos os testes no navegador (28), com uma cópia local do site e do Supabase | 28 de 28 |
| 7 | Passeio antes × depois (cliente, ADM e barbeiro da Scalabrini), com o banco restaurado antes de cada passeio | Mesmas chamadas ao banco e mesmos textos em todas as telas. Fotos da equipe: 34 de 34 idênticas. Fotos do site do cliente: 7 de 13; as outras diferem só pelas animações, como entre duas rodadas do site antigo |
| 8 | ESLint, shellcheck e actionlint | Nenhum erro |

## Risco

- **Baixo para a Scalabrini:** nada do que ela usa mudou. A Área da Equipe só ganhou a tela de convite, que aparece apenas com `?convite=` no endereço.
- **Token do Supabase no GitHub:** é um segredo poderoso. Só os workflows do repositório o usam, e pedidos de fora (forks) não recebem segredos.
- **Barbearia criada fica no banco mesmo se o convite falhar.** O painel avisa, e o convite pode ser gerado de novo pela lista.

## Como reverter

1. **Site:** "Rollback" no Cloudflare para o deploy anterior.
2. **Função:** no Supabase, Edge Functions → `barberium-convite` → Delete.
3. **Banco:** rodar `docs/etapa6b_rollback.sql` no SQL Editor. As barbearias já cadastradas continuam e funcionam; somem só a lista de donos e os convites.
4. **Repositório:** apagar a migration `20261021200000_painel_dono_do_saas.sql` e, se quiser, o workflow `enderecos.yml`.
