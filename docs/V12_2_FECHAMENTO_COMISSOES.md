# Barberium v12.2 — Fechamento e pagamento de comissões

## Objetivo
Transformar o cálculo de comissão já existente em um fluxo operacional completo de fechamento e pagamento, com histórico auditável para ADM e consulta pelo profissional.

## Fluxo do ADM
Em **Financeiro → Comissões → Acertos** o ADM pode:

1. visualizar o valor ainda não fechado de cada profissional;
2. visualizar o saldo já colocado em acertos e ainda não quitado;
3. criar um novo acerto escolhendo profissional e período;
4. pré-visualizar todos os lançamentos de comissão que entrarão no fechamento;
5. fechar o período e congelar aqueles lançamentos dentro de um acerto;
6. registrar ajustes positivos ou negativos, sempre com motivo obrigatório;
7. registrar pagamento parcial ou integral;
8. informar forma e data do pagamento;
9. consultar lançamentos, ajustes e pagamentos do acerto a qualquer momento.

## Situações do acerto
- **Em aberto**: nenhum pagamento registrado.
- **Parcial**: existe pagamento, mas ainda há saldo.
- **Pago**: saldo totalmente quitado.

Um fechamento cujo total líquido seja R$ 0,00 é encerrado automaticamente como pago.

## Pagamento em dinheiro
Pagamento de comissão em dinheiro exige caixa aberto na unidade atual do profissional. O valor é lançado como saída no caixa, sem duplicar a comissão na DRE.

## Visão do profissional
O barbeiro com permissão `view_own_commission` passa a ter:

- aba **A receber**;
- aba **Pagas**;
- saldo total a receber;
- valor ainda aguardando fechamento;
- valor já colocado em acertos;
- acesso aos detalhes dos próprios acertos, lançamentos, ajustes e pagamentos.

O profissional não recebe permissão para criar, ajustar ou pagar acertos.

## Auditoria e segurança
- Ajustes preservam valor, motivo, autor e data/hora.
- Pagamentos preservam valor, forma, autor, data/hora e observação.
- Lançamentos incluídos em um acerto deixam de aparecer como disponíveis para novo fechamento.
- RPCs administrativas da v12.2 não são executáveis por `anon`; somente usuários autenticados entram no fluxo e a função valida o papel ADM internamente.
