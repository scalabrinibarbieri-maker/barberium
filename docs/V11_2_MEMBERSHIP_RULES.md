# Barberium v11.2 — Assinaturas e Pacotes

Compilação de 16/09/2026. Este checkpoint transforma em fluxo operacional as decisões fechadas após a v11.1.

## Pagamento integral
- Assinatura e pacote são criados como `pending`.
- Assinaturas só liberam os benefícios do período e pacotes só liberam seus créditos/sessões após o pagamento integral.
- Não existe ativação por pagamento parcial.
- A confirmação do pagamento registra o valor integral devido.

## Diferença entre assinatura e pacote
- **Assinatura:** funciona por período/ciclo. Quantidades configuradas nos benefícios são limites de uso do ciclo, não carteira de créditos acumuláveis.
- **Pacote:** funciona por créditos/sessões, com saldo total, usado, reservado e disponível.

## Pausa e cancelamento de assinatura
- O plano pode permitir ou bloquear solicitação de pausa.
- Pode definir pausa mínima e máxima.
- O cliente solicita pelo site; a ação só ocorre após aprovação do ADM.
- Pausa só pode ser aplicada a assinatura ativa.
- Ao aprovar a pausa, vigência/benefícios são congelados e o fim do ciclo é empurrado pelo mesmo número de dias.
- O plano pode permitir ou bloquear solicitação de cancelamento.
- Cancelamento pode ser imediato ou ao final do ciclo já pago.
- Cancelamento ao fim do ciclo bloqueia a próxima renovação.
- Todas as solicitações e decisões permanecem no histórico.

## Pacotes
- ADM pode adicionar ou remover créditos de um benefício finito.
- Todo ajuste exige quantidade inteira, motivo obrigatório, autor, data/hora e evento permanente.
- O total nunca pode ficar abaixo do que já foi usado ou reservado.
- Cancelamento/reembolso respeita a política da versão do pacote:
  - não reembolsável;
  - proporcional ao saldo não usado;
  - valor manual definido pelo ADM;
  - não permite cancelamento após primeiro uso.
- No modo proporcional, o cálculo usa a quantidade originalmente comprada; créditos adicionados manualmente como cortesia não aumentam o valor reembolsável.
- Reembolso é lançado no Financeiro.
- Quando houver comissão de venda vinculada ao pacote, o reembolso gera ajuste negativo proporcional.
- Reembolso em dinheiro movimenta o caixa físico aberto da unidade.

## Falta do cliente
- Regra continua configurável por plano: manter benefício, contar como uso ou decisão do ADM.
- A regra agora é aplicada benefício por benefício, inclusive em uso misto.
- Quando for `ADM decide`, a reserva fica pendente até o ADM escolher `Contar como uso` ou `Manter benefício`.

## Financeiro
- Pagamentos de assinaturas/pacotes entram no faturamento.
- Reembolsos entram como estorno e reduzem líquido/resultado operacional.
- Relatórios PDF/CSV v11.2 incluem pagamentos de planos e seção de reembolsos.

## Arquivos desta atualização
- `migrations/20260916_v11_2_01_membership_rules.sql`
- `migrations/20260916_v11_2_02_subscription_period_entitlements_fix.sql`
- `migrations/20260916_v11_2_03_staff_rpc_hardening.sql`
- `equipe/team.js`
- `equipe/finance-reports.js`
- `equipe/index.html`
- `membership.js`
- `membership.css`
- `index.html`
- `sw.js`

## Validação desta compilação
- Assinatura paga integralmente: ativação + uso por ciclo sem criar `membership_credit_buckets`.
- Pacote: pagamento integral + ajuste manual + uso + reembolso proporcional.
- Pausa e cancelamento: solicitação do cliente, aprovação ADM, congelamento e extensão do ciclo.
- No-show: manter, contar como uso e decisão do ADM.
- Relatórios: pagamentos de planos e reembolsos entram no Financeiro.
- Todos os cenários de teste foram executados em transações com rollback; nenhum cliente/plano de teste permaneceu no banco.
