# Barberium — Checkpoint v12.2

Checkpoint compilado em 16/09/2026.

## Entregue neste checkpoint

- Fluxo ADM de fechamento de comissões por profissional e período.
- Prévia de lançamentos antes do fechamento.
- Acertos com estados Em aberto, Parcial e Pago.
- Ajustes positivos/negativos auditáveis, com motivo obrigatório.
- Pagamentos parciais e integrais com forma, data e observação.
- Pagamento em dinheiro integrado ao caixa da unidade quando houver caixa aberto; sem caixa aberto, o pagamento em dinheiro é bloqueado.
- Histórico permanente dos lançamentos, ajustes e pagamentos de cada acerto.
- Área do barbeiro com A receber, Pagas, saldo não fechado e saldo em acertos.
- Segurança: novas RPCs de equipe sem execução anônima.

## Compatibilidade

A v12.2 parte da v12.1 e preserva:
- agenda e grade individual por profissional;
- configurações da barbearia;
- serviços, adicionais e combos;
- assinaturas e pacotes;
- financeiro e relatórios;
- clientes, campanhas, permissões e histórico.

## Banco de produção
As migrations deste checkpoint já foram aplicadas ao Supabase de produção.
