# Barberium — Checkpoint v12.0

Data: 16/09/2026

## Escopo fechado nesta versão

A v12 transforma a área administrativa em uma configuração real de catálogo e operação da barbearia, preservando o histórico e ampliando as regras de assinatura.

### Configurações da barbearia
- Nova seção **Configurações** para ADM/owner.
- Dados gerais da barbearia e das unidades.
- Cadastro/edição de profissionais.
- Horários semanais por unidade e por profissional.
- Dias e horários especiais, inclusive fechamento excepcional.
- Regras de antecedência e grade da agenda.

### Serviços, adicionais e combos
- Catálogo editável pelo ADM.
- Itens do tipo **Serviço**, **Adicional** e **Combo**.
- Nome, imagem, descrição opcional, valor padrão, duração padrão e ordem.
- A descrição aparece para o cliente no agendamento.
- Imagens personalizadas são armazenadas em bucket próprio do Supabase Storage.
- Exclusão lógica: o item deixa o catálogo ativo sem apagar o histórico dos atendimentos existentes.
- Adicionais podem ser vinculados apenas aos serviços/combos desejados.
- Aba **Vínculos** por item, com profissionais habilitados individualmente.
- Preço e duração podem ser sobrescritos por profissional.
- Na ausência de sobrescrita, são usados os valores padrão do item.
- Combo é composto por serviços reais; o profissional só fica elegível para o combo quando executa todos os seus componentes.
- Benefícios de assinatura/pacote conseguem reconhecer a composição de combos.

### Catálogo inicial
- Novas unidades/tenants recebem automaticamente **Corte** e **Barba** como rascunhos editáveis.
- Não são copiados os serviços específicos da Scalabrini para novos negócios.

### Agenda e histórico
- Agenda pública e da equipe respeitam vínculo profissional/serviço.
- Preço e duração efetivos consideram as sobrescritas do profissional.
- Adicionais também consideram preço/duração efetivos por profissional.
- Horários especiais substituem o horário semanal na data configurada.
- O calendário do cliente usa o total de dias de antecedência configurado na unidade.
- Agendamentos guardam snapshots de serviço, profissional, unidade e duração para não mudar o histórico quando o catálogo for alterado ou excluído.

### Assinaturas — ciclos e renovação
- Nova mensalidade é gerada somente na data de renovação.
- Novo ciclo nasce **Pendente**.
- Benefícios do ciclo são liberados apenas após pagamento integral.
- Modos de ciclo: data da adesão, mês-calendário e dia fixo escolhido pela barbearia.
- Primeiro ciclo: integral, proporcional, valor personalizado ou início no próximo vencimento.
- Pagamento após tolerância: configurável entre manter o ciclo original ou iniciar novo ciclo na data do pagamento.
- Alteração de plano cria nova versão e agenda a versão para assinaturas existentes no próximo ciclo, preservando o ciclo atual.
- Renovação diária é processada automaticamente por job idempotente no banco.

## Segurança
- RPCs `barberium_staff_*` têm execução removida do papel `anon` e permitida para `authenticated`/`service_role`.
- Upload de imagens usa bucket público para leitura, mas INSERT/UPDATE/DELETE exigem usuário autenticado owner/admin e caminho da própria barbearia.
- O projeto continua usando RLS sem policies de leitura direta em várias tabelas, pois o acesso principal passa por RPCs SECURITY DEFINER com validação interna.

## Arquivos front-end v12
- `app.js`
- `styles.css`
- `index.html`
- `sw.js`
- `equipe/index.html`
- `equipe/team.js`
- `equipe/team.css`
- `equipe/settings.js`
- `equipe/settings.css`

## Migrações consolidadas no pacote
1. `20260916_v12_01_settings_services.sql`
2. `20260916_v12_02_subscription_renewal.sql`
3. `20260916_v12_03_booking_history.sql`
4. `20260916_v12_04_history_readers_plan_versions.sql`
5. `20260916_v12_05_subscription_daily_job.sql`
6. `20260916_v12_06_staff_rpc_grants.sql`
7. `20260916_v12_07_catalog_addon_effective_values.sql`
8. `20260916_v12_08_default_catalog_on_unit.sql`

## Fora deste checkpoint
- UI completa de despesas recorrentes/projeções.
- Liquidação administrativa de comissões.
- Reembolso/chargeback genérico de atendimento.
- Upgrade/downgrade com tela dedicada além da troca versionada no próximo ciclo.
- Execução avançada de descontos em serviços extras.
- Demais hardenings arquiteturais globais indicados pelos advisors do Supabase.
