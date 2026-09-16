# Barberium v12 — Regras de Configurações, Serviços e Renovações

## Catálogo
Cada item possui um `service_kind`: `service`, `addon` ou `combo`.

### Serviço
Pode ter nome, descrição, imagem, preço, duração, ordem, profissionais vinculados e adicionais permitidos.

### Adicional
É um item reutilizável que pode ser oferecido como extra apenas nos serviços/combos aos quais estiver vinculado. O preço/duração efetivos podem variar por profissional.

### Combo
É composto por dois ou mais serviços reais. A composição é registrada em `service_components`. Um profissional só pode executar o combo se estiver habilitado em todos os componentes. Isso permite que regras de cobertura de planos/pacotes reconheçam serviços contidos no combo.

## Vínculos
`professional_services` define se um profissional executa determinado item e permite `custom_price_cents` e `custom_duration_min`.

Valores efetivos:
- Serviço: override do profissional -> padrão do serviço.
- Adicional: override do profissional -> valor específico do vínculo adicional -> padrão do adicional.

## Histórico
Agendamentos preservam snapshots de nome/duração do serviço, nome do profissional e nome da unidade. Alterar/excluir o cadastro atual não reescreve o histórico antigo.

## Renovação de assinatura
- `anniversary`: renova pelo dia da adesão.
- `calendar`: acompanha mês-calendário.
- `fixed_day`: renova em dia fixo configurado pela barbearia.

O primeiro ciclo aceita `full`, `proportional`, `custom` ou `next_cycle`.

A nova mensalidade só nasce no vencimento. O ciclo fica pendente e sem novos benefícios até pagamento integral. O atraso após tolerância aceita dois comportamentos configuráveis: manter datas originais ou iniciar ciclo na data do pagamento.

O job `barberium-subscription-renewal` chama diariamente `barberium.process_due_subscription_renewals(current_date)` e é idempotente.
