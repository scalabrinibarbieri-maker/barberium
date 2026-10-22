# Estabilização · Etapa 6C · Convite de barbeiros e alertas de profissional novo

Data: 22/10/2026. Base: a main com o painel do dono publicado (versão `730e152`).

Meta da etapa:

- **Convite pela barbearia.** O ADM da barbearia convida os próprios barbeiros pela Área da Equipe, com o mesmo link pelo WhatsApp do painel.
- **Alerta no painel.** Todo profissional novo na agenda de uma barbearia vira um alerta no painel do dono do Barberium. O dono do Barberium avisa o dono da barbearia (sem dizer o valor) e decide se cobra aquele profissional na próxima fatura, além da mensalidade ou anuidade.

Decisões do dono (22/10):

- **O que gera o alerta:** profissional novo na agenda (cadastrado ou reativado), com ou sem login.
- **Como avisar o dono da barbearia:** pelo WhatsApp, por enquanto. O e-mail fica para quando houver um serviço de e-mail próprio. A mensagem diz que o custo do novo profissional será enviado nas próximas horas, sem mostrar valor, porque ele pode variar.
- **Cobrança:** o painel registra a decisão por profissional: **cobrar** (com o valor) ou **não cobrar**. Assim se forma a lista da próxima fatura. As faturas em si ficam para uma etapa depois.
- **Liberação:** o barbeiro já trabalha na hora. A cobrança não bloqueia nada.

## Diagnóstico

1. **O login de cada barbeiro era criado à mão.** A barbearia cadastrava o profissional na agenda, mas ninguém conseguia dar a ele um acesso sem SQL.
2. **A função de convite só aceitava o dono do Barberium.** A barbearia não tinha como gerar o link.
3. **Ninguém ficava sabendo de um profissional novo.** Não havia registro de quando uma barbearia aumentava a equipe, e é isso que define a cobrança por profissional.
4. **Sem um serviço de e-mail próprio,** o Supabase só manda e-mail para quem é da equipe do projeto (a mesma limitação da etapa 6B).

## O que mudou

### Banco (migration `20261022100000_convite_barbeiros_e_alertas`)

| O quê | Para quê |
| --- | --- |
| `barberium.barbershop_invites` ganha `professional_id` e o papel `barber` | Convite de barbeiro, sempre ligado a um profissional da mesma barbearia |
| `barberium_staff_invite_barber(profissional, e-mail, WhatsApp)` | O ADM da barbearia cria o convite de um profissional dele, ativo |
| `barberium_invite_detail(convite)` | A função de convite lê o convite. Pode pedir: o dono do Barberium (qualquer convite) ou o ADM da barbearia do convite (só convite de barbeiro) |
| `barberium_platform_link_invite` | Agora liga o barbeiro ao profissional do convite. Quem já é ADM ou proprietário continua como está |
| `barberium.professional_charges` | Um alerta por profissional novo ou reativado: quando, se o dono foi avisado, a decisão (pendente, cobrar ou não cobrar), o valor e quem decidiu |
| Gatilho em `public.professionals` | Cria o alerta quando um profissional entra ativo ou volta a ficar ativo. Mudar o nome ou desativar não gera alerta |
| `barberium_platform_professional_charges()` | Lista do painel: pendentes, os que vão para a próxima fatura e os "não cobrar" dos últimos 15 dias |
| `barberium_platform_charge_notified(alerta)` | Marca que o dono da barbearia foi avisado |
| `barberium_platform_decide_charge(alerta, cobrar, valor)` | Registra a decisão. Cobrar exige um valor. Dá para mudar até a fatura sair |
| `barberium_platform_barbershops()` | Cada barbearia mostra os profissionais ativos, os alertas pendentes e a próxima fatura (quantos profissionais e o total) |

**Regras do convite, contra entregar a conta de outra pessoa:**

- profissional que já tem login só recebe link para o mesmo e-mail (vira "senha nova");
- e-mail que já é login de outra pessoa no Barberium é recusado;
- profissional que entra como ADM ou proprietário não recebe link pela barbearia (a senha dele é trocada pelo suporte do Barberium);
- barbeiro não convida ninguém, e ADM não convida profissional de outra barbearia;
- se a função de convite cair no meio (login criado, mas não ligado), o mesmo convite pode ser gerado de novo para aquele e-mail.

Os alertas e as decisões só o dono do Barberium vê. Nenhuma barbearia vê o valor.

### Função de convite (`supabase/functions/barberium-convite`)

- Lê o convite pela função nova, então aceita também o ADM da barbearia (só para convite de barbeiro).
- Se o e-mail já tem login e o banco não permite a senha nova, responde "Este e-mail já tem login no Barberium".
- Se o banco estiver sem esta etapa (depois de um rollback), volta a usar a função antiga do painel. O convite do dono de barbearia continua funcionando.

### Área da Equipe (`equipe/convite-barbeiros.js` e `equipe/team.js`)

Na aba Equipe, cada profissional ativo ganhou um botão:

- **Convidar,** para quem não tem login. O ADM informa o e-mail (que será o login) e o WhatsApp do barbeiro.
- **Senha nova,** para quem já tem login e esqueceu a senha. O e-mail vem preenchido e não muda.

A mensagem sai pronta, com **Enviar pelo WhatsApp** e **Copiar mensagem**. O barbeiro abre o link, cria a senha na tela "Crie sua senha" da etapa 6B e entra como **Barbeiro**, vendo só o que o ADM liberou em Permissões.

### Painel (`painel/`)

- **Profissionais novos** (antes da lista de barbearias), com o número de alertas para decidir. Cada alerta mostra a barbearia, o profissional, "Novo" ou "Voltou", a data e a situação.
- **Avisar pelo WhatsApp:** abre o WhatsApp do dono da barbearia com a mensagem, sem valor:

  > Olá, Paula! Aqui é do Barberium. Recebemos a inclusão de Diego Souza na equipe da Barbearia Aurora. Nas próximas horas, enviaremos o custo deste novo profissional.

  O número é o do convite do dono da barbearia. Barbearias de antes do painel (como a Scalabrini) usam o WhatsApp da unidade. Sem número, o WhatsApp abre para escolher o contato. Depois do toque, o alerta mostra "Dono avisado em".
- **Cobrar** (com o valor em reais) ou **Não cobrar.** A decisão aparece no alerta, e dá para trocar até a fatura sair.
- **No cartão de cada barbearia:** profissionais ativos, quantos estão para decidir e "Próxima fatura: + N profissionais · R$ X (além da mensalidade)".

## Limites conhecidos

- **Ainda não há fatura.** O painel guarda a lista do que entra na próxima fatura. Gerar e cobrar a fatura (mensalidade ou anuidade + profissionais) fica para a etapa das faturas, que também marca cada item como faturado.
- **Aviso por WhatsApp, não por e-mail,** até existir um serviço de e-mail próprio (precisa de um domínio do Barberium).
- **O valor é um só por profissional.** Se a cobrança for todo mês, a etapa das faturas decide como repetir.
- **O link do convite vence em pouco tempo** (padrão do Supabase: 1 hora). Se vencer, o ADM gera outro pelo mesmo botão.

## Testes adicionados

| Onde | Testes |
| --- | --- |
| `supabase/testes/09_convite_barbeiros_e_alertas.sql` (34 conferências) | Convite: ADM convida barbeiro dele; recusas (e-mail de outra pessoa, e-mail inválido, profissional de outra barbearia, profissional inativo, barbeiro convidando); senha nova só para o mesmo e-mail; login de convite que caiu no meio pode receber o link de novo, login solto não. O servidor liga o login como barbeiro do profissional, e ele entra na Área da Equipe. Alertas: profissional novo gera alerta; nome ou desativar não; reativar gera outro. Só o dono do Barberium vê e decide. Cobrar exige valor; a decisão entra e sai da próxima fatura; depois de faturado, não muda. O aviso vai para o nome e o WhatsApp do dono da barbearia |
| `testes/e2e/barbeiros.spec.js` (2 testes, no site de teste, com a função de verdade) | O ADM da Aurora convida o Rafael Costa (ou gera a senha nova, nas rodadas seguintes); ele cria a senha e entra como Barbeiro, sem a aba Equipe. Um profissional novo na Aurora vira alerta no painel: aviso sem valor, "Dono avisado", cobrar R$ 25,00 (entra na próxima fatura) e depois não cobrar. No fim, o profissional volta a ficar inativo |
| `testes/e2e/painel.spec.js` | Ajuste: procura a barbearia só na lista de barbearias |

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Banco reconstruído como a produção (97 migrations); ensaio da migration nova | Ensaio ok, e a impressão digital não mudou (o ensaio desfaz tudo) |
| 2 | Migration aplicada + dados fictícios; todos os testes do banco | 311 conferências, 0 falhas |
| 3 | Rollback (`docs/etapa6c_rollback.sql`) e impressão digital | Volta exatamente à impressão digital de antes (9 partes). Aplicar de novo dá a mesma de depois, e o teste 09 passa de novo |
| 4 | Banco depois do rollback + site da etapa 6B + função de convite nova | O fluxo completo do painel (cadastrar barbearia, convite, dono cria a senha e entra) passa, 18 de 18: a função usa a função antiga do banco |
| 5 | Fluxo completo no computador (banco local + Supabase local que imita o convite) | 31 de 31. ADM da Aurora: Convidar, recusa de e-mail de outra pessoa, mensagem e WhatsApp; Rafael cria a senha e entra como Barbeiro, sem a aba Equipe; Senha nova; login normal. Painel: alerta, contador, aviso sem valor, "Dono avisado", cobrar R$ 25,00 (próxima fatura da Aurora), não cobrar, reativar gera "Voltou". Sem erro de JavaScript |
| 6 | Todos os testes no navegador (30), com uma cópia local do site e do Supabase; e de novo os do painel e dos barbeiros | 30 de 30. Na segunda rodada, 4 de 4: o Rafael recebe "Senha nova", e o profissional do alerta é reativado e termina inativo |
| 7 | Passeio antes × depois (cliente, ADM e barbeiro da Scalabrini), com o banco restaurado antes de cada passeio | Cliente e barbeiro: iguais. ADM: a única diferença é o botão novo na aba Equipe ("Senha nova" para o Vinicius, que já tem login, e "Convidar" para o Jean). Mesmas chamadas ao banco |
| 8 | ESLint nos arquivos novos e alterados | Nenhum erro novo (os avisos do `team.js` já existiam) |
| 9 | Produção (só leitura): profissionais e logins da Scalabrini | Vinicius Nunes e Jean Dalarmi têm login de barbeiro: os dois verão "Senha nova". Nenhum profissional está ligado a ADM ou proprietário |

## Risco

- **Baixo para a Scalabrini.** No site do cliente, nada mudou. Na Área da Equipe, a aba Equipe ganhou o botão Convidar ou Senha nova em cada profissional.
- **Alerta a cada profissional novo, também na Scalabrini.** Como ela é do próprio dono do Barberium, basta marcar "Não cobrar".
- **Convite de barbeiro dá acesso à barbearia.** As regras acima impedem gerar link para o login de outra pessoa. O barbeiro entra só com o papel de barbeiro e as permissões que o ADM liberou.
- **O gatilho roda a cada cadastro de profissional.** Ele só grava uma linha. Se falhar, o cadastro do profissional também falha. Os testes cobrem cadastrar, renomear, desativar e reativar.

## Como reverter

1. **Site:** "Rollback" no Cloudflare para o deploy anterior.
2. **Banco:** rodar `docs/etapa6c_rollback.sql` no SQL Editor. Os barbeiros que já entraram continuam entrando. Somem os convites de barbeiro, os alertas e as decisões de cobrança.
3. **Função de convite:** pode ficar como está. Sem esta etapa no banco, ela usa a função antiga e o convite do dono de barbearia continua funcionando.
4. **Repositório:** apagar a migration `20261022100000_convite_barbeiros_e_alertas.sql`.
