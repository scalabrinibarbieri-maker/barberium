# Estabilização · Etapa 7g (parte 2) · Saldos dentro do Financeiro

Data: 26/10/2026. Base: a main com a parte 1 da 7g publicada (versão `ab89c06`, 101 migrations).

Meta desta parte: a aba Saldos do Financeiro deixa de ser um remendo carregado por fora (`balances-v12.39.js`) e passa a fazer parte do próprio Financeiro, sem mudar a tela nem os números. O banco não muda.

## Diagnóstico

O `equipe/balances-v12.39.js` (585 linhas) era carregado à parte e montava a aba Saldos por cima da tela já pronta:

- **Montagem.** Criava o botão "Saldos" e o painel com JavaScript, e injetava o próprio CSS numa tag `<style>`. Para pegar a tela já desenhada, tentava de novo depois de 300 ms e de 1 s.
- **Fechamento.** Para saber quando fechar, ouvia todos os cliques da página e observava o painel do Financeiro com um `MutationObserver`:
  - fechava em qualquer clique numa aba do Financeiro ou em outro painel;
  - ao voltar para o Financeiro, fechava 80 ms depois.
- **Dependência escondida.** O Financeiro (`team.js`) não sabia que a aba existia. Era o remendo que escondia os outros painéis e os controles de período do ADM, e que os mostrava de volta.

Funcionava, mas dependia de tempos e de cliques ouvidos de fora. É o mesmo tipo de remendo que as etapas 7d a 7f tiraram do resto da Área da Equipe.

**Achado do teste novo:** Saldos tocado logo depois de abrir o Financeiro, enquanto ele ainda carrega (internet lenta), se perdia:
- o ADM voltava para a Visão, e Saldos ficava "Carregando…" escondido;
- o barbeiro ficava com a tela em branco, sem nenhuma aba marcada (o relógio de 80 ms da v12.39 fechava Saldos, e nada abria no lugar).

Agora Saldos abre e continua aberto.

## O que mudou

- **`equipe/saldos.js` (novo).** É a lógica da v12.39 passada para um módulo do Financeiro, com os mesmos textos, cálculos e chamadas ao banco (`barberium_staff_balance_quick`):
  - `ligarSaldos`: liga datas, atalhos (hoje, ontem, 7 dias, mês) e unidade;
  - `abrirSaldos`: abre a aba;
  - `fecharSaldos`: fecha a aba e devolve os controles do ADM;
  - `saldosAberto`: diz se Saldos está aberta.
- **`equipe/index.html`.**
  - O botão "Saldos" passa a ser o primeiro das abas do Financeiro.
  - O painel de Saldos (`#financeBalancesTab`) vem escrito no HTML, escondido.
  - Sai a linha que carregava `balances-v12.39.js`.
- **`equipe/team.css`.** Recebe o CSS que a v12.39 injetava, igual.
- **`equipe/team.js`.** Quatro ligações:
  - liga Saldos junto com o resto do Financeiro;
  - trocar de aba do Financeiro fecha Saldos;
  - tocar em qualquer painel do menu fecha Saldos (como antes);
  - ao terminar de carregar, o Financeiro só abre a aba de sempre se Saldos não estiver aberta.
- **`deploy/arquivos-do-site.txt`.** Sai `equipe/balances-v12.39.js` e entra `equipe/saldos.js`.
- **Apagado:** `equipe/balances-v12.39.js`.

**O que não muda:**
- a tela (mesmos cartões, mesmos detalhes da Casa e de cada profissional), fora o toque rápido acima;
- os números;
- quem vê o quê (o ADM vê a Casa e a equipe, o barbeiro vê só a própria comissão).

## Testes adicionados

- **`testes/e2e/saldos.spec.js`.** Roda no site de teste, só olha e não grava nada. Com o ADM:
  - "Saldos" é a primeira aba do Financeiro; tocada logo ao abrir o Financeiro, abre o painel, esconde os controles de período e continua aberta;
  - mostra as 3 categorias, o atalho do mês e a Casa com o detalhe;
  - trocar para a Visão fecha Saldos e devolve os controles;
  - o `balances-v12.39.js` não é mais pedido, e não há erro de JavaScript.

## Testes executados

Banco local igual ao da produção (101 migrations), com atendimentos, produtos e comissões de hoje e dos últimos dias. O site de antes é a main (`ab89c06`).

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Saldos antes × depois, com 400 ms de atraso em cada chamada. ADM e barbeiro: hoje, ontem, 7 dias, mês, data à mão, detalhe da Casa e do profissional, trocar de aba, sair e voltar ao Financeiro, toque rápido | Textos, números e chamadas ao banco iguais. Fotos: 6 de 10 idênticas; 2 diferem só no horário de um lançamento criado pelo próprio teste (16:26 × 16:27); 2 são o toque rápido, que agora abre Saldos (antes: Visão para o ADM, tela em branco para o barbeiro). No toque rápido do ADM, uma chamada a menos (a Visão não é carregada por trás de Saldos) |
| 2 | Passeio antes × depois (cliente, ADM e barbeiro) | Textos e chamadas ao banco iguais. Equipe: 33 de 34 fotos idênticas; a outra (Saldos) difere em 386 pontos fracos nas fotos dos cartões, do desenho da imagem. Cliente: 11 de 13; as outras, das animações |
| 3 | Todos os testes no navegador, com 400 ms de atraso | 37 de 37, inclusive o novo `saldos.spec.js` (que achou o toque rápido) |
| 4 | Conferência do código (`node --check` e ESLint) | Sem erros. `team.js` continua com os 2 avisos antigos de variável sem uso |
| 5 | Pacote aplicado numa cópia da main de produção, como faz o "Aplicar pacote" | Repositório idêntico ao da etapa. Sites de produção e de teste montam sem nenhuma referência faltando, e sem o `balances-v12.39.js` |

## Risco

- **Baixo.** Só o site muda, numa aba que só lê. O banco e os números são os mesmos.
- **Onde aparece se algo der errado:** na aba Saldos do Financeiro. O pior caso é a aba não abrir, ou os controles de período do ADM não voltarem ao trocar de aba. As outras abas não dependem de Saldos.

## Como reverter

1. **Site:** subir de volta, da versão `ab89c06`:
   - `equipe/balances-v12.39.js`;
   - `equipe/index.html`;
   - `equipe/team.css`;
   - `equipe/team.js`;
   - `deploy/arquivos-do-site.txt`.
2. **Repositório:** apagar `equipe/saldos.js` e `testes/e2e/saldos.spec.js`.
3. **Banco:** nada a fazer.
