# Barberium — Checkpoint v11 completo
## Financeiro + Assinaturas/Pacotes

**Data:** 16/09/2026  
**Base anterior:** v10 — Clientes  
**Objetivo:** registrar, sem depender da conversa, todas as decisões de produto aprovadas até a compilação da v11 e indicar o que já está operacional no núcleo testável.

---

## 1. Escopo e princípios

- Barberium é um SaaS operacional para barbearias; o Financeiro deve dar controle real sem virar internet banking.
- Não controlar saldos de contas bancárias. Pode registrar meio/provedor de entrada e saída para taxas, conferência e relatórios.
- Multiunidade: cada unidade possui seus próprios movimentos e o ADM pode ver uma unidade ou o **Consolidado da empresa**.
- Profissional vê apenas o próprio financeiro/comissões; não vê caixa geral, despesas, faturamento da empresa ou dados de outros profissionais.
- Histórico financeiro deve ser auditável e exportável em PDF/CSV quando o módulo de exportação estiver concluído.

---

## 2. Recebimento ao concluir atendimento

Ao marcar um atendimento como **Concluído**, deve abrir a etapa de pagamento. Métodos iniciais:

- Pix
- Dinheiro
- Débito
- Crédito

Regras:

- Pagamento dividido é permitido.
- A soma dos pagamentos deve fechar o valor a receber, salvo parcela explicitamente deixada como **Pagamento pendente**.
- Dinheiro aceita valor entregue e calcula troco; em split, troco é apenas sobre a parte em dinheiro.
- A referência financeira é o valor final realmente cobrado, já considerando ajustes/descontos.
- Atendimento pode ficar com recebimento total ou parcial futuro; registrar vencimento opcional, observação, recebimentos posteriores e saldo.
- Cartão parcelado é recebimento da venda, não dívida do cliente.

---

## 3. Caixa diário

**Opcional por unidade.** Mesmo desligado, pagamentos, receita, taxas, comissões, despesas e relatórios continuam funcionando.

Quando ligado:

- abertura e saldo inicial;
- entradas em dinheiro;
- trocos;
- sangrias;
- suprimentos;
- despesas pagas com dinheiro do caixa;
- saldo esperado;
- fechamento com valor contado.

Diferença no fechamento:

- calcular falta/sobra;
- justificativa obrigatória;
- registrar responsável e horário;
- preservar em histórico/exportação.

---

## 4. Despesas

Categorias personalizadas pelo ADM: criar, renomear e desativar.

Despesa registra:

- valor;
- data;
- descrição;
- categoria;
- forma de pagamento;
- se saiu do caixa físico;
- observação.

Despesa em dinheiro do caixa reduz o saldo físico esperado.

**Despesas recorrentes** são aprovadas com categoria, descrição, valor, recorrência, dia de vencimento, forma, início e fim opcional. Estados: **Prevista** e **Paga**. Prevista não entra como saída realizada até ser paga.

---

## 5. Provedores e taxas

- Múltiplas maquininhas/provedores.
- Taxas próprias por débito, crédito 1x/2x/3x..., percentual, taxa fixa e Pix se houver.
- Na conclusão em cartão: método → provedor → parcelas.
- Split pode misturar, por exemplo, Pix + crédito Stone 2x.
- Relatórios devem separar bruto, taxas e líquido, inclusive por provedor.

---

## 6. Comissões de serviços avulsos

ADM configura:

- porcentagem padrão por profissional;
- override por serviço;
- serviço sem comissão;
- ciclo de acerto semanal, quinzenal ou mensal;
- base da comissão: **bruto pago** ou **líquido após taxas**.

A comissão normal usa o valor efetivamente recebido da parte avulsa do atendimento.

Acertos:

- Em aberto → Parcialmente pago → Pago;
- pagamentos parciais com data, valor, forma e saldo restante;
- histórico fechado não é reescrito.

Estorno/reembolso:

- se comissão ainda não paga, ajustar o saldo aberto;
- se já paga, criar ajuste negativo no próximo acerto, vinculado ao atendimento original.

---

## 7. Permissões financeiras

ADM sempre tem acesso. Por profissional, permissões independentes:

- deixar pagamento pendente;
- registrar despesa;
- registrar sangria;
- registrar suprimento;
- abrir caixa;
- fechar caixa;
- confirmar pagamento de assinatura/pacote;
- visualizar a própria comissão.

Conceder uma ação não concede visão geral do Financeiro.

---

## 8. DRE e metas

DRE simplificado:

**Receita bruta − taxas de pagamento − comissões − despesas = resultado operacional estimado.**

O ADM pode analisar por:

- **regime de caixa**;
- **regime de competência**.

Escolhe padrão nas configurações e pode trocar no relatório/exportação sem alterar lançamentos.

Metas financeiras estão aprovadas: meta mensal por unidade e/ou visão consolidada, progresso, valor realizado e quanto falta.

---

# ASSINATURAS E PACOTES

## 9. Conceito

- **Assinatura:** recorrente por ciclos, mas sem cobrança automática nesta primeira fase.
- **Pacote:** compra fechada, sem renovação obrigatória.
- O Barberium controla valores, vencimentos, pagamentos, créditos, validade, histórico e comissão.
- Máximo inicial por cliente: **1 assinatura ativa + 1 pacote ativo**.
- Créditos são pessoais e intransferíveis.

---

## 10. Conteúdo do plano

Cada plano pode conter vários serviços/benefícios:

- quantidade definida, por exemplo 4 × Corte;
- **ilimitado**;
- desconto percentual em serviços extras.

Benefício ilimitado pode ter regras opcionais por serviço:

- sem limite real;
- intervalo mínimo entre atendimentos;
- máximo por semana;
- máximo por mês.

---

## 11. Aquisição e visibilidade

Por plano, o ADM escolhe:

- somente equipe/ADM;
- somente cliente pelo site;
- ambos.

Também há **Exibir publicamente** independente do meio de aquisição.

No site, nesta fase:

**cliente solicita → barbearia recebe → ADM confirma adesão/pagamento → benefícios são liberados.**

Não existe cobrança automática nesta versão.

---

## 12. Créditos, reserva e consumo

- Crédito fica **reservado no agendamento**.
- Só é **consumido quando o atendimento é concluído**.
- Cancelamento libera a reserva.
- Não é possível reservar mais créditos do que os disponíveis.
- Validade é conferida pela **data do atendimento**, não pela data em que o agendamento foi criado.
- Se assinatura e pacote cobrirem o mesmo serviço, o cliente escolhe qual plano usar; o ADM também pode escolher em lançamento manual.

No perfil do cliente, mostrar:

- nome do plano;
- data da compra/adesão;
- valor;
- status;
- próxima renovação/vencimento;
- validade;
- benefícios;
- total de créditos;
- usados;
- reservados;
- disponíveis;
- ilimitado quando aplicável;
- histórico.

---

## 13. Validade

Configurável por plano:

- expira no fim do ciclo;
- acumula por X ciclos;
- acumula sem prazo;
- pacote válido por X dias;
- pacote sem validade.

ADM pode prorrogar validade manualmente em exceções.

---

## 14. Falta / no-show

Configurável por plano:

- perde o crédito;
- crédito continua disponível;
- decisão manual do ADM naquele caso.

---

## 15. Pausa e cancelamento

Por assinatura:

- cancelamento imediato;
- cancelamento no fim do ciclo;
- pausa por período configurado;
- durante a pausa, validade pode congelar ou continuar correndo;
- reativação preserva todo histórico.

Pacote pode ter suspensão temporária e prorrogação de validade.

Cancelamento/reembolso de pacote é configurável:

- não reembolsável;
- reembolso proporcional;
- valor manual definido pelo ADM;
- sem cancelamento depois do primeiro uso.

Qualquer devolução deve refletir no Financeiro e nas comissões sem apagar histórico.

---

## 16. Ciclos de assinatura

Modo do ciclo configurável:

- aniversário da adesão;
- mês-calendário.

No primeiro ciclo de mês-calendário, configurável:

- cobrar/liberar tudo;
- proporcional;
- primeiro ciclo personalizado;
- começar no próximo ciclo.

Na renovação:

- nova mensalidade nasce como **Pendente**;
- novos créditos só são liberados após confirmação de pagamento;
- troca de plano agendada entra nessa renovação.

Upgrade/downgrade ocorre **sempre no próximo ciclo**, nunca no meio do ciclo atual.

---

## 17. Atraso e tolerância

Por assinatura, configurar tolerância:

- nenhuma;
- quantidade de dias predefinida/personalizada.

Durante a tolerância, comportamento do plano é configurável. Depois do prazo, mensalidade passa a **Atrasada** e novos usos podem ser bloqueados conforme regra do plano.

A situação aparece claramente no perfil do cliente, inclusive vencimento, dias de atraso e tolerância.

---

## 18. Crédito antecipado

Somente o ADM pode liberar crédito antecipado do próximo ciclo.

- uso fica auditado;
- no próximo ciclo pago, o crédito antecipado já é descontado da nova franquia;
- se a próxima mensalidade ultrapassar a tolerância sem pagamento, o atendimento antecipado vira **pendência avulsa pelo preço normal do serviço**.

---

## 19. Uso misto e combos

No mesmo atendimento pode existir:

- parte coberta por crédito;
- parte paga avulsa;
- desconto em extras se o plano oferecer.

Exemplo: plano cobre Corte e cliente faz Corte + Sobrancelha. Corte usa crédito; Sobrancelha é cobrada normalmente.

Crédito também pode ser usado como componente de um serviço maior/Combo. Exemplo: crédito de Corte em Combo Corte + Barba.

O valor do abatimento no combo é configurável por plano:

- valor avulso integral do componente;
- rateio proporcional do desconto do combo.

Financeiro e comissão devem separar parte coberta pelo plano da parte avulsa.

---

## 20. Multiunidade dos planos

Por plano:

- todas as unidades;
- unidades selecionadas;
- apenas unidade de origem.

O cliente deve visualizar onde o plano é válido.

---

## 21. Versionamento imutável

Editar um plano não reescreve contratos/históricos antigos.

- pacote já comprado mantém preço, créditos, validade e regras da versão adquirida;
- assinatura mantém regras do ciclo atual;
- alteração passa a valer a partir da próxima renovação;
- versões antigas continuam disponíveis para auditoria/histórico.

---

## 22. Comissão específica de assinatura/pacote

Dentro de **Financeiro → Comissões → Assinaturas/Pacotes**, cada plano possui sua própria metodologia, independente da comissão normal dos serviços:

1. **Por hora** — remunera pelo tempo atendido.
2. **Por fichas** — ADM define pesos/fichas dos serviços e percentual do valor do plano destinado ao fundo de comissões.
3. **Por atendimento** — valor fixo em R$ por utilização/serviço.
4. **Por venda** — premia a venda conforme a regra do plano.
5. **Sem comissão**.

Regras aprovadas:

- se for por atendimento/hora/fichas, recebe quem efetivamente prestou o serviço;
- cliente pertence ao plano, não a um barbeiro;
- valores consideram a economia real do plano, não a soma artificial dos preços avulsos;
- venda originada diretamente pelo site **não gera comissão por venda**;
- venda registrada por equipe/barbeiro só gera comissão de venda se o plano tiver essa modalidade/regra configurada;
- modalidades diferentes podem coexistir em planos diferentes.

---

## 23. Histórico/auditoria de plano

Linha do tempo do cliente deve guardar, no mínimo:

- adesão/compra;
- pagamentos;
- renovações;
- criação/reserva/consumo/liberação de créditos;
- faltas;
- pausa/reativação;
- cancelamento;
- prorrogação;
- crédito antecipado;
- troca futura de plano;
- reembolsos;
- ajustes administrativos.

---

# 24. Estado técnico da v11 compilada

## Núcleo operacional já implementado/testável

- etapa de pagamento na conclusão de atendimento;
- Pix, dinheiro, débito e crédito;
- split payment;
- troco;
- pagamento pendente;
- provedores/taxas;
- caixa básico e movimentos;
- despesas e categorias;
- DRE/visão financeira básica e metas;
- configuração normal de comissão por profissional/serviço;
- visão da própria comissão do barbeiro;
- criação/versionamento de assinaturas/pacotes;
- quantidade e ilimitado com limites de frequência;
- escopo por unidade;
- aquisição/visibilidade;
- solicitação pelo site;
- ativação/pagamento de plano;
- exibição de “Meus planos” no perfil;
- reserva de crédito no agendamento;
- liberação no cancelamento;
- consumo na conclusão;
- crédito aplicado a componente de combo;
- comissão de plano por atendimento, hora e fichas no núcleo;
- separação entre valor coberto pelo plano e parte avulsa na conclusão.

## Decisões já congeladas, mas fluxos avançados ainda não finalizados nesta v11 testável

- geração/baixa completa de despesas recorrentes;
- fechamento/pagamento de ciclos de comissão pela interface;
- estorno/chargeback completo pela interface;
- exportação financeira PDF/CSV;
- pausa/cancelamento/prorrogação/troca futura de plano pela interface;
- automação completa de criação de novos ciclos, atraso e mudança de status;
- crédito antecipado + conversão automática em dívida avulsa;
- reembolso de pacote pela interface;
- comissão **por venda** operacional;
- primeiro ciclo personalizado;
- ferramentas administrativas completas para todas as exceções.

Esses itens **não são decisões pendentes**: as regras acima já estão aprovadas. São etapas de implementação posteriores a este núcleo testável.

---

## 25. Ponto de retomada depois do teste

Depois de testar a v11 no site, continuar o desenho/implementação a partir das regras avançadas de Assinaturas/Pacotes e, em seguida, detalhar Metas/relatórios financeiros sem refazer as decisões deste documento.
