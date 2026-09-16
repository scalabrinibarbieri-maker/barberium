# Barberium v12.3 — Produtos, estoque e venda interna

## Entregue

- Aba Produtos na área da equipe, com catálogo, vendas, relatório e comissões.
- Cadastro com foto, nome, categoria, descrição, SKU/código de barras opcional, custo, preço, mínimo e status.
- Estoque por unidade: entradas, saldo inicial, ajustes e perdas com motivo e histórico.
- Venda de balcão com cliente opcional e profissional responsável.
- Produtos no atendimento, com cobrança conjunta de serviço e produtos.
- Pix, dinheiro, débito e crédito; pagamento dividido, troco e pendência conforme permissões.
- Saldo de produtos pode ser recebido pelo ADM no detalhe da venda.
- Baixa somente na conclusão; erro em pagamento ou falta de estoque desfaz toda a operação.
- Repetição da mesma requisição de venda de balcão não gera outra venda.
- Estorno integral devolve estoque e cria reversão da comissão. Um segundo estorno é recusado.
- Cancelar um atendimento ainda aberto remove o rascunho de produtos sem movimentar estoque.
- Atendimento com venda concluída exige estorno dos produtos antes de cancelar, para registrar a forma de devolução escolhida pelo ADM.
- Comissão de produtos com padrão por profissional e substituição por produto, independente da configuração dos serviços.
- Produtos e serviços têm recebimentos, custos e bases de comissão separados internamente.
- Relatórios financeiros incluem recebimentos, provedores, unidades, pendências e estornos de produtos; DRE inclui custo dos produtos vendidos.
- Permissões de vender produtos e consultar estoque disponíveis em Equipe. ADM tem acesso; novas permissões de barbeiro ficam desativadas até o ADM habilitar.
- Sem loja pública.

## Regras de cálculo

Na cobrança conjunta, cada parcela recebida é distribuída proporcionalmente entre serviço (após benefício de plano) e produtos. O arredondamento é cumulativo em centavos. A taxa de cada pagamento é calculada uma única vez e dividida entre as duas partes. A comissão de serviços usa somente a parte do serviço; a de produtos usa as linhas de produtos. A comissão de produtos é registrada na conclusão da venda, inclusive quando há saldo pendente, seguindo a base do módulo recuperado.

Comissões de produtos são lançamentos identificados como `product_sale` e estornos como `product_refund`. Os acertos existentes recebem esses lançamentos, sem misturar as regras de cálculo com as de serviços.

## Estado recuperado

A migration `20260916192322_v12_3_products_stock_sales` já existia no banco quando esta conversa começou. O GitHub ainda correspondia à v12.2. A mensagem anterior dizendo que nada havia sido aplicado estava incorreta. A base foi recuperada e completada, sem recriar as tabelas.

## Validação

- Teste transacional real no Supabase, encerrado com ROLLBACK: cadastro, estoque, comissão personalizada, repetição idempotente, estorno e sua repetição, cobrança conjunta, comissão de serviço preservada, cancelamento de rascunho, recebimento de saldo, falta de estoque, atomicidade e autenticação.
- Nenhum produto de teste permaneceu no banco.
- JavaScript: verificação de sintaxe dos seis arquivos.
- Interface em Chromium, viewport 390 × 844, com respostas de API simuladas: cadastro, estoque, quantidade, duas formas de pagamento, troco, payload da venda, personalização da comissão e cobrança conjunta.
- Inspeção visual das telas de produtos e pagamento em celular; ajuste da navegação com seis abas.
- A interface foi testada com dados simulados; as regras financeiras e de estoque foram testadas separadamente no banco real com rollback. Não foi realizada venda real de cliente para teste.
- Verificação de segurança manteve o modelo existente: tabelas com RLS e sem acesso direto; operações por funções com autenticação e autorização. Os avisos informativos de RLS sem políticas e funções SECURITY DEFINER são compatíveis com esse modelo. Aviso já existente de proteção contra senhas vazadas não foi alterado.

## Operação

Abra a Área da Equipe → Produtos. Cadastre o produto e registre seu saldo inicial na unidade. Para vender no atendimento, abra a ficha e use “Adicionar / alterar produtos”. Para balcão, use “Venda de balcão”. Configure os percentuais em Produtos → Comissões.

Atualização do banco já aplicada. Arquivos de migrations são registros versionados; não é necessário executar SQL manualmente na instalação atual.

## Publicação pendente

O banco está atualizado, mas a publicação dos arquivos no GitHub foi recusada com HTTP 403 (`Resource not accessible by integration`) ao criar a árvore do commit. Nenhum commit da v12.3 foi criado nesta conversa. O pacote entregue atualiza a v12.2; preserve os arquivos de imagem e demais arquivos existentes no repositório.
