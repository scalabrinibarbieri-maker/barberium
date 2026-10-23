# Estabilização · Etapa 7d (parte 2) · Regras de status num lugar só

Data: 22/10/2026. Base: a main com a parte 1 publicada (versão `e448df2`, 99 migrations).

Meta desta parte: as regras de quem pode levar um atendimento de um status para outro passam a morar num lugar só, dentro do banco, com testes do que cada passagem faz com o dinheiro. O site não muda.

## Diagnóstico

Cinco funções do banco mudam o status de um atendimento, e todas as passagens possíveis saem delas:

| Função | Passagem |
| --- | --- |
| mudar status (equipe) | cancelar, marcar falta, voltar para confirmado |
| concluir (equipe) | confirmado → concluído, com pagamento |
| cancelar concluído (ADM) | concluído → cancelado, com ou sem reembolso |
| cancelar pelo site do cliente | confirmado → cancelado |
| remarcar pelo site do cliente | confirmado → cancelado → confirmado no horário novo, por dentro |

As regras de papel e permissão estavam copiadas dentro de cada função, em seis lugares, e cada cópia tinha o seu texto. Por exemplo:

- "só o ADM cancela concluído" aparecia três vezes;
- "barbeiro só mexe no que é dele" aparecia com três mensagens diferentes.

Nada impedia uma função nova (ou um remendo) de gravar uma passagem que não existe, como concluído → confirmado sem passar pelo cancelamento.

Levantei o mapa completo de hoje: 4 papéis × 4 status de partida × 5 pedidos, 80 combinações, cada uma com a mensagem exata. Duas brechas apareceram. O site nunca as usa, mas alguém com login e a API conseguiria:

1. **Editar atendimento que não está confirmado.** O site só mostra "Editar atendimento" para horário confirmado, mas o banco deixava editar um concluído, cancelado ou com falta. No teste, um corte pago em R$ 90 virou R$ 10, e o pagamento e a comissão continuaram de R$ 90 e R$ 45.
2. **Passagens que o site não oferece:** o ADM consegue levar cancelado ↔ falta e "cancelar de novo" um já cancelado, o que troca o tipo dele (de engano para normal).

Decisão do dono (22/10): travar a 1ª e deixar a 2ª como está.

## O que mudou

Tudo numa migration, `20261022300000_regras_de_status.sql`:

- **`barberium.regra_de_status`:** todas as regras de papel e permissão, por ação (mudar status, concluir, cancelar concluído, editar), com as mesmas mensagens de antes e na mesma ordem. As funções do site chamam essa regra no lugar das cópias que tinham. O que elas fazem com dinheiro não mudou: pagamentos, caixa, reembolsos, pendências, comissões, fichas de pacote e estoque.
- **Trava na tabela de atendimentos** (`barberium.transicao_de_status_permitida` + gatilho): nenhuma função consegue gravar uma passagem fora do mapa. O mapa é exatamente o que já existia:
  - confirmado → concluído, cancelado ou falta;
  - concluído → cancelado;
  - cancelado ou falta → confirmado;
  - cancelado ↔ falta.

  Fora dele, o banco recusa com "Mudança de status não permitida".
- **Editar só atendimento confirmado:** nas duas funções de editar horário ("Somente atendimento confirmado pode ser editado"). Os encaixes já eram travados assim.
- **Não mudaram:**
  - as travas de dinheiro para voltar um atendimento para confirmado (não volta com reembolso, ficha gasta ou pagamento);
  - as funções do site do cliente, que já só cancelam e remarcam horário confirmado.
- **Detalhe sem efeito na tela:** se um barbeiro sem a permissão "concluir" pedir para concluir pela API com um pagamento inválido, a recusa agora é "Sem permissão para concluir", não o erro do pagamento. O botão nem aparece para ele no site.

## Testes adicionados

`supabase/testes/11_status_e_dinheiro.sql`, 39 conferências:

- **Mapa:** as 80 combinações com o resultado de hoje.
- **Dinheiro em cada passagem,** com foto de pagamentos, caixa, reembolsos, pendências, comissões, fichas, venda e estoque:
  - concluir com produto em dinheiro;
  - cancelar com reembolso em dinheiro (devolve pelo caixa, estorna a comissão, devolve o estoque);
  - anular lançamento errado com produto no Pix;
  - anular com pendência;
  - pacote: cancelar devolve a ficha, falta gasta a ficha, anular devolve a ficha;
  - voltar para confirmado: o que pode e o que não pode.
- **Editar:** só confirmado, nas duas funções de editar, para ADM e barbeiro.
- **A trava:** recusa concluído → confirmado, concluído → falta e cancelado → concluído, mesmo por dentro do banco.
- **Site do cliente:** remarcar e cancelar continuam funcionando com a trava.

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Teste novo no banco de antes (igual à produção) | O mapa e o dinheiro passam iguais. Só falham as 9 conferências das regras novas (editar e trava), como esperado |
| 2 | Todos os testes do banco, reconstruído do zero com as 100 migrations e os dados fictícios | 367 de 367 |
| 3 | Impressão digital, antes × depois | Só as 13 diferenças esperadas: 4 funções novas, 8 funções com a regra trocada e o gatilho novo |
| 4 | Rollback de verdade, e a migration aplicada de novo pelo pipeline | O rollback volta o banco idêntico ao de antes (99 migrations); a reaplicação deixa idêntico ao de depois |
| 5 | Ensaio do pipeline num banco igual à produção | Roda sem erro e desfaz tudo |
| 6 | As 8 funções na produção (só leitura) | Idênticas às do banco de antes, base da migration |
| 7 | Site da parte 1 com o banco sem × com a migration:<br>• os 5 cancelamentos;<br>• novo horário, encaixe com passageiro e editar;<br>• permissão do barbeiro tirada ou dada com o app aberto | Tudo igual: banco, telas, mensagens e fotos |
| 8 | Passeio sem × com a migration (cliente, ADM e barbeiro) | Textos e chamadas ao banco iguais. Fotos da equipe 34 de 34 idênticas. Do site do cliente, 9 de 13: as outras diferem em até 25 pontos, das animações. O cliente cancela o horário igual |
| 9 | Todos os testes no navegador com o banco migrado e 400 ms de atraso | 34 de 34. Na 1ª rodada, um teste da troca de versão do site (que não usa o banco) passou do tempo esperando o service worker; passou ao rodar de novo, e a rodada completa seguinte deu 34 de 34 |

## Risco

- **Médio.** As funções de concluir e cancelar mexem em dinheiro. O corpo delas, a parte do dinheiro, ficou igual; só a conferência de quem pode foi trocada pela chamada à regra. O mapa e as fotos de dinheiro saíram iguais nos testes.
- **A trava pode recusar uma passagem que eu não previ.** Levantei todas as funções que gravam status (são 5), e todas as passagens delas estão no mapa. Se acontecer, o atendimento não muda e aparece "Mudança de status não permitida"; o rollback desfaz em um passo.

## Como reverter

1. **Banco:** rodar `docs/etapa7d2_rollback.sql` no SQL Editor. Nenhum dado muda, e o site não precisa voltar.
2. **Repositório:** apagar a migration `20261022300000_regras_de_status.sql`.

## Validação (23/10)

| O quê | Resultado |
| --- | --- |
| Pacote `pacote-etapa7d2.zip` | A main (`b94dc26`) ficou idêntica à branch da etapa |
| Publicar no teste e em produção | Verdes. Na produção: 100 migrations, a última é `20261022300000 regras_de_status`, e a trava está na tabela de atendimentos |
| Banco real (só leitura) | As 12 funções (8 trocadas e 4 novas) estão idênticas às do banco local com a migration. A regra responde certo: editar concluído é recusado e confirmado pode; barbeiro não cancela concluído; concluído → confirmado fora do mapa |
| Site real | Versão `b94dc26`, 41 arquivos idênticos aos montados a partir da main (o site não mudou nesta parte) |
| Navegador, sem login | Painel, Área da Equipe e site do cliente abrem sem erro de JavaScript |
