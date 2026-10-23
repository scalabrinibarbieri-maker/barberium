# Estabilização · Etapa 7e · Checkout e planos

Data: 23/10/2026. Base: a main com a etapa 7d publicada (versão `b94dc26`).

Meta da etapa: o "Concluído" com ficha de plano e a aba Planos do Financeiro passam a fazer, eles mesmos, o que quatro remendos faziam por fora. A tela e o que vai para o banco ficam iguais. O banco não muda.

## Diagnóstico

1. **v12.9** (`barberium-v12.9.js`):
   - **aba Planos:** tirava o conteúdo do lugar para criar as abas "Planos" e "Contratos ativos";
   - **Contratos ativos:** desenhava a lista e o contrato, com pagamento integral, ajuste de créditos e cancelar pacote;
   - **"Ajustar créditos" da ficha do cliente:** roubava o clique, então a versão do `team.js` nunca rodava;
   - **campos de número:** num campo com 0, tocar seleciona o 0 e o primeiro dígito entra no lugar dele, em toda a Área da Equipe.

   Ligava-se com timers de 400 e 1200 ms.
2. **v12.17** (em `barberium-v12.17.js`): observava as classes da tela e o foco do aparelho para buscar os contratos de novo, apertando sozinho o botão "Contratos ativos". Ao entrar na aba com "Contratos ativos" aberto, a lista era buscada duas vezes.
3. **v12.20** (em `barberium-v12.17.js`): o último interceptador do `fetch` da Área da Equipe. Espiava qual atendimento estava aberto para injetar a caixa "Cliente de plano" no pagamento, por observer. Depois de usar ou tirar a ficha, fechava a janela, tocava no cartão da agenda e no "Concluído" sozinho, buscando tudo de novo. Se o cartão não estivesse na tela, pedia para abrir de novo à mão.
4. **v12.22** (em `barberium-v12.17.js`): nos valores em reais da comissão de planos, trocava "25.50" por "25,50" antes de salvar. A conta de reais do `team.js` lê o ponto como milhar, e "25.50" viraria R$ 2.550,00. Isso também acontece ao editar um plano salvo, porque o campo volta como "30.5".

## O que mudou

- **`equipe/contratos.js` (novo):** abas, lista de contratos, contrato, pagamento integral, ajuste de créditos e cancelar pacote, com os mesmos ids, textos e mensagens. O `team.js` chama o módulo ao abrir Planos. Voltando ao app com "Contratos ativos" aberto, a lista é buscada de novo, como na v12.17. O "Ajustar créditos" da ficha do cliente abre o mesmo ajuste de antes; o do `team.js`, que nunca rodava, saiu.
- **`equipe/plano-na-comanda.js` (novo):** a caixa "Cliente de plano", desenhada junto com o pagamento. Depois de usar ou tirar a ficha, o pagamento abre de novo direto, já com o valor novo.
- **`equipe/campos-numericos.js` (novo):** o comportamento do campo com 0 e a correção "25.50" → "25,50", que o `team.js` usa ao salvar o plano e ao sair do campo.
- **`index.html`:** as abas "Planos" e "Contratos ativos" vêm escritas no HTML; saem os scripts da v12.9 e da v12.17.
- **Saíram:**
  - `equipe/barberium-v12.9.js` e `equipe/barberium-v12.17.js` (o pacote apaga os dois);
  - o último interceptador do `fetch`, três observers e cinco timers de inicialização.
- **Pequenas melhoras:**
  - **ficha no pagamento:** depois de usar ou tirar a ficha, o pagamento reabre direto, sem piscar o detalhe do atendimento no meio. Funciona mesmo quando o cartão não está na agenda da tela.
  - **mensagens:** cada uma fica na tela o tempo dela; o relógio de outro remendo não apaga mais a mensagem antes da hora.
  - **menos chamadas ao banco:** os contratos não são buscados duas vezes, e o financeiro do atendimento não é buscado de novo para a caixa do plano.

## Testes adicionados

- `testes/e2e/planos.spec.js` (site de teste, só olha, não salva nada):
  - as abas "Planos" e "Contratos ativos";
  - a busca de contratos;
  - "25.50" na comissão por hora vira "25,50";
  - os scripts antigos não carregam.

## Testes executados

Banco local reconstruído com todas as migrations e os dados fictícios, restaurado antes de cada rodada.

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Antes × depois, como ADM da Scalabrini, com um pacote de 3 cortes pago (Cliente 01) e outro a pagar (Cliente 02):<br>• Planos e Contratos ativos, com busca;<br>• pagamento integral em dinheiro;<br>• ajuste de créditos pela aba e pela ficha do cliente;<br>• voltar ao Financeiro;<br>• no "Concluído": usar a ficha, tirar, usar de novo e concluir;<br>• campo com 0;<br>• comissão por atendimento "25.50" e por hora "30.50" salva;<br>• cancelar pacote | Banco igual nas duas versões, linha por linha:<br>• contratos, créditos, pagamentos e histórico dos pacotes;<br>• ficha consumida;<br>• comissão por hora gravada como R$ 30,50.<br>Textos e mensagens iguais. Fotos 7 de 9 idênticas: numa, a mensagem "Pacote cancelado." agora fica os 2,8 s dela (antes sumia antes, pelo relógio de outro remendo); na outra, muda 1 linha de pontos na borda da caixa do plano. Menos chamadas ao banco, como planejado |
| 2 | Passeio antes × depois (cliente, ADM e barbeiro da Scalabrini) | Textos iguais. Fotos da equipe 33 de 34 idênticas: a de Saldos (que esta etapa não toca) pegou o cartão "Casa" no meio do efeito de borda; com mais tempo de espera, as duas versões ficam idênticas. Do site do cliente, as diferenças são de 25 pontos, das animações. Em "Contratos ativos", uma chamada a menos (a lista não é buscada duas vezes) |
| 3 | Todos os testes no navegador (35, com o novo), com 400 ms de atraso em cada chamada | 35 de 35 |
| 4 | Barbeiro conclui o horário de um cliente de pacote usando a ficha, antes × depois | Igual: mesma caixa, "A receber agora R$ 0,00", ficha consumida, mesmas mensagens |
| 5 | ESLint | Nenhum aviso nos arquivos alterados |

## Risco

- **Médio,** porque mexe no pagamento do "Concluído" de cliente com plano e nas ações de contrato (pagamento, créditos, cancelar pacote). As funções do banco e o que vai para elas são os mesmos; no teste local o resultado no banco saiu igual, linha por linha.

## Como reverter

1. **Site:** "Rollback" no Cloudflare para o deploy anterior.
2. **Repositório:** subir de volta, da versão `b94dc26`:
   - `equipe/team.js`, `equipe/team.css`, `equipe/index.html` e `deploy/arquivos-do-site.txt`;
   - os dois arquivos apagados (`equipe/barberium-v12.9.js` e `equipe/barberium-v12.17.js`);
   - e apagar os três módulos novos.

   Todos estão no histórico do Git.
