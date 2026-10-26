# Estabilização · Etapa 7g (parte 1) · Datas no fuso da barbearia

Data: 23/10/2026. Base: a main com a etapa 7f publicada (versão `3d97773`, 100 migrations).

Meta desta parte: todo relatório e toda data de "hoje" gravada pelo banco passam a usar o dia de Brasília (o fuso da barbearia). A parte 2 leva Saldos para dentro do Financeiro; a parte 3 junta o Relatório numa função só.

## Diagnóstico

O banco roda no horário de Londres (UTC). Muitas funções transformavam data e hora em "dia" sem dizer o fuso (`created_at::date`, `current_date`), e por isso contavam o dia de Londres. Das 21h à meia-noite de Brasília, Londres já está no dia seguinte.

| Onde | Antes, um registro feito às 22:30 de D |
| --- | --- |
| Visão geral do Financeiro, relatório e vendas de produtos, comissões (Minhas comissões, prévia e acerto), cancelamentos por engano | Contava em D+1 |
| Relatório (`barberium_staff_finance_report`), Desempenho, Agenda e Saldos | Já contavam em D (usavam o fuso da barbearia) |
| Planos e pacotes: cancelamento ("vale a partir de hoje"), pausa (fim da pausa), ciclo pago à noite, despesa sem vencimento | Gravavam a data de D+1 |

Ou seja, as telas não batiam entre si.

**Na produção (só leitura):**
- 11 dos 113 pagamentos de atendimento e 15 das 145 comissões foram feitos depois das 21h;
- nenhum mudou de mês até agora;
- os horários marcados nunca passam das 21h, e o pagamento é feito à noite quando o atendimento é concluído tarde.

Também, na noite do último dia do mês, o Relatório podia abrir no mês seguinte: quando o campo do mês estava vazio, `finance-reports.js` usava o mês de Londres.

**Decisão do dono (23/10):** o dia de Brasília em tudo.

## O que mudou

- **Migration `20261023100000_datas_no_fuso_da_barbearia.sql`:**
  - `barberium.usar_fuso_da_barbearia` põe a chamada no fuso da barbearia (`barbershops.timezone`, hoje `America/Sao_Paulo` nas duas), do mesmo jeito que o Relatório já fazia, só até o fim da chamada;
  - 16 funções passam a chamar isso logo no começo: Visão geral, Saldos, relatório e vendas de produtos, Minhas comissões, prévia, acerto e lista de acertos, cancelamentos por engano, cancelar pacote, pagamento integral de plano, decisões sobre pedidos de plano e de pausa, despesa, horários especiais e a atualização da situação dos planos do cliente (pausa e cancelamento programado);
  - em "Minhas comissões" e na lista de acertos, que o site chama sem datas, o período padrão (últimos 90 dias / último ano até hoje) também conta o dia de Brasília.
- **`equipe/finance-reports.js`:** o Relatório abre no mês de hoje em Brasília.
- **O que não muda:**
  - as regras de cada relatório (caixa, competência, o que entra em cada número) e o que é gravado. Muda só o dia em que um registro feito à noite é contado;
  - os horários nas respostas do banco: mesmo instante, escritos com `-03:00` em vez de `+00:00`. A tela já mostrava tudo no horário de Brasília.

## Testes adicionados

- **`supabase/testes/12_datas_no_fuso.sql` (17 conferências).** Cada função é chamada como uma chamada nova do site, começando no horário de Londres. Os registros são feitos às 22:30 de D e às 00:30 de D+1:
  - Visão geral de D e de D+1;
  - Relatório;
  - Saldos;
  - relatório e vendas de produtos;
  - prévia e acerto de comissões;
  - Minhas comissões (com e sem datas);
  - cancelamento por engano;
  - "hoje" ao cancelar pacote, ao lançar despesa e ao atualizar os planos do cliente;
  - nenhuma função usa mais a data de Londres no corpo.

  No banco de antes, 11 dessas conferências falham. Por exemplo, a Visão geral de D mostrava R$ 0 e a de D+1 contava os dois dias.
- **`03_datas_saldos_e_relatorio.sql`:** sai a conferência "vai mudar" das 18 funções com a data de Londres. Era o defeito conhecido que esta etapa corrige; a conferência nova está no arquivo 12.

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Todos os testes do banco, reconstruído do zero com as 101 migrations e os dados fictícios | 383 de 383, nenhum defeito conhecido em aberto |
| 2 | Números antes × depois: 24 atendimentos de dia (entre 9h e 20h) nos últimos 12 dias, com produtos, pendências, cancelamentos e despesas. 152 chamadas: Visão geral e Relatório (caixa e competência), Saldos, produtos, vendas, prévia, Minhas comissões e cancelamentos por engano, dia a dia e em períodos | Todos os números iguais nas 152. Mudam só os horários escritos com `-03:00` (mesmo instante) e a hora em que o Relatório foi gerado |
| 3 | Impressão digital, antes × depois | Só as 17 diferenças esperadas: a função nova e as 16 alteradas |
| 4 | Rollback de verdade, e a migration aplicada de novo pelo pipeline | O rollback volta o banco idêntico ao de antes; a reaplicação deixa idêntico ao de depois |
| 5 | Ensaio do pipeline num banco igual à produção | Roda sem erro e desfaz tudo |
| 6 | As 16 funções na produção (só leitura) | Idênticas às do banco de antes, base da migration |
| 7 | Passeio antes × depois (cliente, ADM e barbeiro), com o banco de cada lado | Textos e chamadas ao banco iguais. Fotos da equipe 34 de 34 idênticas. Do site do cliente, 11 de 13: as outras diferem em até 25 pontos, das animações |
| 8 | Todos os testes no navegador com o banco migrado e 400 ms de atraso | 36 de 36 |

## Risco

- **Alto pelo assunto, baixo pelo tamanho.** A mudança em cada função é uma linha: o fuso da chamada. As contas são as mesmas, e os números de dia saíram iguais. O que muda é o dia dos registros feitos à noite, que é o que foi decidido.
- **Onde aparece:** nas telas de um dia só (Visão geral por dia, Minhas comissões, acertos), e no mês quando um pagamento for feito à noite no último dia do mês.

## Como reverter

1. **Banco:** rodar `docs/etapa7g1_rollback.sql` no SQL Editor. Nenhum dado muda.
2. **Repositório:** apagar a migration `20261023100000_datas_no_fuso_da_barbearia.sql`.
3. **Site:** subir de volta `equipe/finance-reports.js` da versão `3d97773`.

## Validação (26/10)

| O quê | Resultado |
| --- | --- |
| Pacote `pacote-etapa7g1.zip` | A main (`ab89c06`) ficou idêntica à branch da etapa |
| Publicar no teste | Verde em 23/10. O banco de teste ficou com 101 migrations, e os testes no navegador rodaram às 20:06 |
| Publicar em produção | Rodado depois, em 26/10 (a primeira rodada não tinha sido iniciada). Banco real com 101 migrations; a última é `20261023100000 datas_no_fuso_da_barbearia` |
| Banco real (só leitura) | As 17 funções (16 alteradas e a nova) estão idênticas às do banco local com a migration. Numa transação só de leitura, `usar_fuso_da_barbearia` põe a chamada em `America/Sao_Paulo` e o "hoje" da chamada é o dia de Brasília |
| Site real | Versão `ab89c06`, 41 arquivos idênticos aos montados a partir da main |
| Navegador, sem login | Painel, Área da Equipe e site do cliente abrem sem erro de JavaScript |
