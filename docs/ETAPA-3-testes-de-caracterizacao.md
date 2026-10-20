# Estabilização · Etapa 3 · Testes de caracterização

Data: 19/10/2026. Base: a main depois do pacote-etapa2c.

Meta da etapa: registrar, em testes automáticos, como o sistema se comporta **hoje**. Isso vale para o que está certo e para os defeitos já conhecidos. Assim, as próximas etapas (4 a 9) podem mexer no banco e no site sabendo na hora se algo mudou sem querer.

Nada do sistema mudou nesta etapa: nenhuma migration, nenhum arquivo do site. Só entram testes e os passos que os rodam.

## Diagnóstico

1. **Não havia nenhum teste do comportamento.** A etapa 1 confere a *estrutura* do banco (tabelas, funções, permissões). A etapa 2 confere que o teste e a produção batem com o repositório. Mas nenhuma das duas sabia dizer se agendar, cancelar, fechar o caixa ou calcular a comissão continua dando o mesmo resultado.
2. **As regras de negócio estão quase todas no banco**, em funções que o site chama. São 155 funções. Por isso a maior parte dos testes é em SQL, chamando essas funções do jeito que o site chama, com o papel de cada pessoa (visitante, cliente, barbeiro, ADM).
3. **O isolamento entre barbearias nunca tinha sido testado função por função.** Hoje só existe uma barbearia de verdade, mas a etapa 6 prepara a entrada da segunda.

## O que mudou

### Repositório

| Arquivo | O que é |
| --- | --- |
| `supabase/testes/_harness.sql` | Ferramentas dos testes: trocar de papel (visitante, cliente, barbeiro, ADM, sistema), conferir resultado, esperar um erro e achar barbearia, unidade, profissional, serviço e cliente pelo nome. Um teste que "espera erro" sempre desfaz o que fez, mesmo que o comando funcione |
| `supabase/testes/01_agendamento_publico.sql` | Site do cliente: horários livres, domingo fechado, cliente novo agenda (preço, duração e fuso), choque de horário, horário passado, telefone e nome inválidos, barbearia inexistente, adicional, telefone já cadastrado sem token |
| `supabase/testes/02_atendimento_equipe.sql` | Área da Equipe: papéis, agendamento pela equipe, choque, finalizar com Pix e dinheiro, comissão, pagamento que não soma, permissões do barbeiro, cancelar, não compareceu, anular atendimento finalizado (erro de lançamento e estorno) |
| `supabase/testes/03_datas_saldos_e_relatorio.sql` | Pagamentos às 23h59 e às 00h01 (horário de Brasília) caem no dia certo do relatório financeiro (caixa e competência), dos Saldos, do Desempenho, do Painel e de Minhas comissões |
| `supabase/testes/04_isolamento_entre_barbearias.sql` | O ADM da Barbearia Aurora chama **todas** as 95 funções da equipe que recebem um ID, passando IDs da Scalabrini. Antes e depois de cada chamada, ele tira uma "foto" de todas as tabelas para ver se algo da Scalabrini mudou ou foi devolvido |
| `supabase/testes/05_acesso_e_permissoes.sql` | O que um visitante sem login pode chamar (lista fechada de 21 funções), usuário logado sem barbearia, barbeiro × ADM e o token do cliente (não serve em outra barbearia nem para outro cliente) |
| `supabase/testes/06_caixa_e_acerto_de_comissoes.sql` | Abrir e fechar o caixa (com diferença), suprimento, acerto de comissões, pagamento do acerto e o que acontece ao anular um atendimento já acertado |
| `supabase/testes/rodar_testes.sh` | Roda os arquivos acima, cada um numa transação **desfeita no fim**, e escreve o resumo no GitHub |
| `testes/e2e/` | Testes num navegador de verdade (Playwright 1.56.0, tela de celular, fuso de São Paulo), **só contra o site de teste**. O endereço da produção é recusado. São 5 testes: o cliente agenda, vê em "Meus horários" e cancela; senha errada não entra; o ADM vê agenda, clientes, financeiro e equipe; o barbeiro não vê clientes nem equipe; e o ADM da Aurora só enxerga a Aurora |
| `testes/e2e/esperar_site.sh` | Espera o Cloudflare trocar o site de teste para a versão nova antes de testar |
| `.github/workflows/banco-reproduzivel.yml` | Ganha 2 passos no fim: "Dados fictícios no banco local" e "Testes de caracterização" |
| `.github/workflows/staging.yml` | Ganha a parte "Testar o site de teste", que roda depois de publicar o site de teste |

### Onde os testes rodam

| Workflow | Testes do banco | Testes no navegador |
| --- | --- | --- |
| Publicar no teste | Sim, num banco montado do zero no próprio GitHub | Sim, no site de teste, depois de publicado |
| Publicar em produção | Sim, antes de tocar na produção | Não precisa: a mesma versão já passou no teste |
| Banco reproduzível (segunda de manhã) | Sim | Não |

Os testes do banco **nunca rodam na produção**. Eles rodam num Postgres descartável dentro do GitHub, montado pelas mesmas migrations, com os mesmos dados fictícios do teste.

## Como ler o resultado

Cada conferência aparece com um destes sinais:

| Sinal | Significa |
| --- | --- |
| ✓ | O sistema se comportou como hoje |
| ~ | **Defeito conhecido**, registrado de propósito. Passa enquanto continuar igual. Quando uma etapa corrigir, o teste falha para lembrar de atualizá-lo |
| ✗ | **O comportamento mudou.** Se a mudança foi de propósito, o teste é atualizado junto. Se não foi, é um problema e nada vai para a produção |

## O que os testes encontraram

Nenhum vazamento de dados entre barbearias. Das 95 funções da equipe chamadas com IDs de outra barbearia, 85 recusaram, 9 não fizeram nada e 1 misturou (item 1 abaixo).

| # | Achado | Gravidade | Onde fica registrado | Quando trata |
| --- | --- | --- | --- | --- |
| 1 | O ADM de uma barbearia consegue salvar a **meta financeira** da própria barbearia apontando para uma unidade de outra. Não mostra nem muda nada da outra, mas mistura os dados | Média, só com 2 barbearias | 04, defeito conhecido | Etapa 6 |
| 2 | 3 funções da equipe (Saldos, horários livres e desempenho) ainda podem ser **chamadas por quem não fez login**. Elas recusam por dentro ("Não autenticado"), mas a permissão não devia existir | Baixa | 05, defeito conhecido | Etapa 6 |
| 3 | 18 funções usam a **data do servidor (UTC)** em vez da data de Brasília. Das 21h à meia-noite, "hoje" para elas já é amanhã | Média | 03, defeito conhecido | Etapa 7g |
| 4 | Quando o barbeiro tenta marcar um horário para **outro barbeiro**, o horário vai para ele mesmo, sem aviso | Baixa (a tela do barbeiro só oferece ele mesmo) | 02 | A decidir |
| 5 | O **mesmo cliente** pode ter dois horários no mesmo momento, com barbeiros diferentes | A confirmar se é o desejado | 02 | A decidir |
| 6 | Em "Minhas comissões", o **em aberto** soma tudo que está aberto, de qualquer período, e não só do período escolhido | A confirmar se é o desejado | 03 | A decidir |
| 7 | No site do cliente, tocar em **Agendar antes do catálogo carregar** deixa a lista de serviços vazia. Em internet lenta, o cliente vê uma tela vazia | Média | Os testes no navegador esperam o catálogo para não falhar à toa | Etapa 7h |
| 8 | O site do cliente reescreve o título da página. No teste, o "[TESTE]" do título some; a faixa laranja continua | Nenhuma (só no teste) | — | — |

Também ficaram registradas regras que estão certas e agora não podem mudar sem querer:

- o Pix não passa pelo caixa, mas o dinheiro e o suprimento passam;
- quando um atendimento já acertado é anulado, a comissão paga não some, e entra um desconto para o próximo acerto;
- o token do cliente não abre perfil nem cancela nada em outra barbearia;
- a tentativa de cancelar o horário de outro cliente responde "não" e não mexe no horário.

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Os 6 arquivos num banco montado do zero (92 migrations + dados fictícios), exatamente como no GitHub | 214 conferências, 0 falhas, 3 defeitos conhecidos, em menos de 1 segundo |
| 2 | Rodado às 21h de Brasília, quando a data UTC já é o dia seguinte | Passa: os testes de data usam o fuso de Brasília |
| 3 | Rodar 2 vezes seguidas no mesmo banco | Mesmo resultado: cada arquivo desfaz tudo no fim |
| 4 | Erro de propósito: liberar uma função da equipe para visitante | O teste 05 falha e mostra qual função entrou na lista |
| 5 | Testes no navegador contra o site de teste real (cliente e senha errada) | Passam. O cliente agenda o primeiro horário livre e cancela no fim |
| 6 | Os 5 testes no navegador contra uma cópia local do site de teste ligada a um banco local com os mesmos dados fictícios (para conferir os logins sem usar a senha de verdade) | 5 de 5 passam |
| 7 | Erro de propósito: mostrar a aba Clientes para o barbeiro | O teste do barbeiro falha |
| 8 | Espera do site: versão igual × versão diferente | Igual: segue em 8 s. Diferente: espera e para com o nome do arquivo |
| 9 | `actionlint` nos 5 workflows e `shellcheck` em todos os scripts | Sem apontamentos |

O login com a senha de verdade nos testes no navegador é conferido na primeira rodada de "Publicar no teste".

## Risco

- **Produção: nenhum.** Os testes do banco rodam num banco descartável do GitHub, e os do navegador só no site de teste.
- **"Publicar no teste" fica uns 3 minutos mais longo** (instalar o navegador e rodar os 5 testes).
- **Cada rodada marca e cancela 1 horário na Scalabrini de teste**, com um cliente "Teste Automatico". Isso vai acumulando clientes fictícios no teste, o que não afeta nada.
- **Teste instável:** um teste no navegador pode falhar por lentidão da internet. Ele já tenta uma segunda vez sozinho. Se ainda falhar, dá para rodar de novo só a parte que falhou (ver o [COMO-PUBLICAR.md](COMO-PUBLICAR.md)).
- **Uma mudança de propósito vai deixar algum teste vermelho.** É o esperado: nas próximas etapas, cada correção vem com o teste atualizado no mesmo pacote.

## Como reverter

- **Tirar os testes do caminho:** reenviar as versões anteriores de `banco-reproduzivel.yml` e `staging.yml` (estão no histórico do GitHub). As pastas `supabase/testes` e `testes/e2e` podem ficar; sem os workflows, nada as roda.
- Nada no banco ou no site precisa ser desfeito.
