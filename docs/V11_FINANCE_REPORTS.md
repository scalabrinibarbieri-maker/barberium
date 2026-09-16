# Barberium v11.1 — Relatórios financeiros

Adição ao Financeiro aprovada em 16/09/2026.

## Operacional
- Botão **Gerar relatório** dentro do Financeiro.
- Filtros por data inicial/final, unidade ou consolidado e regime Caixa/Competência.
- Tipos: Financeiro completo, Faturamento, Recebimentos/Taxas/Provedores, Despesas, Comissões, Contas a Receber, Caixa e DRE/Resultado.
- Exportação em **PDF** e **CSV**.
- Relatório completo inclui consolidação por unidade e resumo por profissional.
- Acesso restrito a proprietário/ADM no backend.

## Backend
RPC: `barberium_staff_finance_report(date,date,uuid,text)`.
