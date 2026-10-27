# Estabilização · Etapa 7g (parte 3) · Relatório numa função só

Data: 26/10/2026. Base: a main com a parte 2 da 7g publicada (versão `04b644d`, 101 migrations).

Meta desta parte: o Relatório financeiro (botão "Relatório" do Financeiro, em PDF ou CSV) passa a ser calculado por uma função só, com os mesmos números. O site não muda.

## Diagnóstico

O Relatório chama `barberium_staff_finance_report`, que era montada em três camadas. Duas delas vieram de remendos aplicados direto na produção em 17/09 (v12.8 e v12.8.1), registrados só depois, na etapa 1:

| Camada | O que fazia |
| --- | --- |
| 1. `barberium_staff_finance_report_v12_8_raw` (75 linhas) | Montava o relatório inteiro: resumo do topo, recebimentos, competência, reembolsos, despesas, comissões, contas a receber, caixa e os resumos por provedor, unidade e profissional |
| 2. `barberium_staff_finance_report_v12_8_1_raw` (567 linhas) | Chamava a 1 e refazia recebimentos (com o rateio dos reembolsos), competência e os resumos por provedor, unidade e profissional. O que a 1 tinha feito dessas partes ia fora |
| 3. `barberium_staff_finance_report` (109 linhas) | Chamava a 2, recontava as transações de cada provedor e refazia a lista de reembolsos (com serviço + adicionais na descrição) |

Problemas:

- **Contas em dobro.** Cada relatório fazia as mesmas contas duas vezes.
- **Correção difícil.** Para corrigir algo, era preciso saber em qual camada mexer. A correção da v12.11 (reembolso de produto contado duas vezes no profissional) teve de procurar um trecho de texto dentro da camada 2 e trocá-lo.

## O que mudou

**Migration `20261026100000_relatorio_numa_funcao.sql`:**

- `barberium_staff_finance_report` passa a ser uma função só, com as contas escritas uma vez:
  - resumo do topo (o mesmo da Visão geral), despesas, comissões, contas a receber e caixa: como na camada 1;
  - recebimentos, competência e resumos por provedor, unidade e profissional: como na camada 2;
  - reembolsos e contagem de transações por provedor: como na camada 3.
- O texto da função nova foi montado por um programa a partir das três funções atuais (os trechos de cada camada copiados como estão), sem redigitar as contas.
- Os mesmos avisos, na mesma ordem: login, só ADM, período inválido, regime inválido, unidade inválida.
- As duas camadas de baixo são apagadas. Só o `service_role` podia chamá-las, e nada além do Relatório as usava: nem o site, nem outra função, nem a função de convite. Na produção, só o próprio Relatório citava as duas.

**Única diferença:** a ordem de linhas empatadas no resumo por provedor (mesmo líquido e mesmo provedor, por exemplo "Sem provedor · Dinheiro R$ 0" e "Sem provedor · Crédito R$ 0"). Antes, a ordem entre elas dependia do caminho que o banco escolhia; agora segue a forma de pagamento e as parcelas. Nenhum número muda.

**Mais rápido:** 50 relatórios do mês com movimento variado levavam 504 ms e agora levam 294 ms (cerca de 40% a menos).

**O que não muda:**
- o site (`finance-reports.js` é o mesmo);
- o PDF e o CSV;
- o que é gravado no banco.

## Testes adicionados

**`supabase/testes/13_relatorio.sql` (13 conferências).** O dia D tem:
- corte + sobrancelha no crédito 3x da maquininha, cancelado com reembolso;
- corte com R$ 50 no Pix e R$ 40 pagos depois no débito da maquininha;
- corte em dinheiro;
- venda de 2 pomadas no Pix, reembolsada;
- um reembolso antigo sem pagamento, de um atendimento anulado.

Confere:
- as 13 partes do Relatório;
- o resumo por provedor linha a linha: transações, reembolsadas, bruto, reembolsos, taxas e líquido, inclusive "Sem provedor · outro" com o reembolso sem pagamento;
- a situação de cada recebimento;
- as descrições dos reembolsos, inclusive com adicional;
- a conferência do caixa: Visão geral = provedores = unidades = profissionais (R$ 158,65);
- os valores por profissional;
- a competência de D;
- os quatro avisos (período, regime, unidade de outra barbearia, barbeiro);
- que o Relatório é uma função só e não chama outra camada.

No banco de antes, as 11 conferências de números passam iguais, e só as 2 de estrutura falham, como esperado.

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Todos os testes do banco, reconstruído do zero com as 102 migrations e os dados fictícios | 396 de 396, nenhum defeito conhecido em aberto |
| 2 | Relatório antigo × novo no mesmo banco e na mesma transação. Ver "Movimento variado" abaixo | Todos os números iguais. Só 24 chamadas mudam, e só na ordem de linhas empatadas por provedor |
| 3 | Relatório baixado pelo site (ADM, CSV): banco igual à produção com o mesmo movimento, antes e depois de aplicar a migration nele. 22 relatórios: mês, 30 dias, dias soltos e 3 dias, nos dois regimes, consolidado e por unidade, completo, recebimentos e faturamento | 22 de 22 CSVs idênticos (fora a hora em que foi gerado); 22 de 22 respostas do banco idênticas, 1.057 linhas nas listas |
| 4 | Impressão digital, antes × depois | Só as 3 diferenças esperadas: o Relatório alterado e as 2 camadas apagadas |
| 5 | Rollback de verdade, e a migration aplicada de novo pelo pipeline | O rollback volta o banco idêntico ao de antes; a reaplicação deixa idêntico ao de depois |
| 6 | Ensaio do pipeline num banco igual à produção | Roda sem erro e desfaz tudo |
| 7 | As 3 funções na produção (só leitura) | Idênticas às do banco de antes, inclusive as permissões; 101 migrations |
| 8 | Todos os testes no navegador com o banco migrado e 400 ms de atraso | 37 de 37 |
| 9 | Pacote aplicado numa cópia da main de produção, como faz o "Aplicar pacote" | Repositório idêntico ao da etapa |

**Movimento variado (teste 2).** São 13 rodadas: só os dados fictícios, e depois cada um dos 12 testes do banco, cada um com o seu movimento. Por cima de tudo, um movimento variado espalhado em 20 dias:
- crédito 3x e débito com taxa da maquininha, Pix e dinheiro no mesmo atendimento;
- pagamento às 22h49;
- pendência paga dias depois;
- serviço com adicional;
- cancelamentos com reembolso (um deles com pendência);
- vendas reembolsadas (uma com pendência);
- pacotes cancelados com reembolso proporcional e manual;
- reembolso antigo de pacote sem o pagamento ligado, reembolso sem pagamento e reembolso maior que o pago;
- despesas, caixa aberto e fechado;
- a Aurora com as duas unidades.

Em cada rodada, as duas barbearias foram comparadas:
- 91 dias soltos e 5 períodos mais longos;
- nos dois regimes;
- consolidado, por unidade e com unidade de outra barbearia;
- com os pedidos inválidos.

Ao todo, 18.084 comparações, inclusive as mensagens de erro.

**Observação (já era assim, não muda):** no regime de competência, o resumo por provedor soma recebimentos (caixa). Por isso, a linha "Conferência" do PDF pode mostrar provedores diferente do DRE quando o que foi feito no período não é o que foi recebido nele.

## Risco

- **Médio pelo assunto, baixo pela forma.** É o relatório financeiro do dono, mas as contas foram copiadas das funções atuais por um gerador, não redigitadas. Os números saíram iguais em todas as comparações, com reembolsos, pendências, taxas, planos e duas unidades.
- **Onde aparece se algo der errado:** só no botão "Relatório" do Financeiro (PDF e CSV). A Visão geral, Saldos e as outras telas não usam esta função.

## Como reverter

1. **Banco:** rodar `docs/etapa7g3_rollback.sql` no SQL Editor. Ele recria as duas camadas (só para o `service_role`, como antes) e o Relatório de antes. Nenhum dado muda.
2. **Repositório:** apagar a migration `20261026100000_relatorio_numa_funcao.sql` e o teste `supabase/testes/13_relatorio.sql`.
3. **Site:** nada a fazer.

## Validação (27/10)

| O quê | Resultado |
| --- | --- |
| Pacote `pacote-etapa7g3.zip` | A main (`6204752`) ficou idêntica à branch da etapa |
| Publicar no teste e Publicar em produção | Os dois sites estão na versão `6204752` |
| Banco real e banco de teste (só leitura) | 102 migrations; a última é `20261026100000 relatorio_numa_funcao` (na produção, aplicada pelo pipeline). Só existe `barberium_staff_finance_report`, idêntica à do banco reconstruído com a migration, inclusive nas permissões; as duas camadas antigas não existem mais |
| Site real e site de teste | 42 arquivos idênticos aos montados a partir da main. O `versao.json` só muda no formato da hora |
| Navegador, sem login | Painel, Área da Equipe e site do cliente abrem sem erro de JavaScript |
