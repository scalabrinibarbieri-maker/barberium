# Estabilização · Etapa 7c · Agendamento da equipe

Data: 22/10/2026. Base: a main com a etapa 7b publicada (versão `19582d8`).

Meta da etapa: "Novo horário", "Novo encaixe" e "Editar atendimento" passam a fazer, eles mesmos, o que dois remendos faziam por fora: vários serviços na mesma comanda e o cliente passageiro. A tela e o que vai para o banco ficam iguais.

## Diagnóstico

1. **v12.13** (`barberium-v12.13.js`): interceptava o `fetch` e trocava cinco chamadas pelas versões `_v12_12`, acrescentando os serviços extras lidos da tela:
   - horários livres;
   - criar horário e criar encaixe;
   - editar horário e editar encaixe.

   Ela também injetava a caixa "Serviços da comanda" por observer e guardava o detalhe do atendimento espiando a resposta do banco, para saber os extras na edição.
2. **v12.21** (dentro de `barberium-v12.17.js`): interceptava a criação e, com o "Cliente passageiro" ligado, trocava a chamada pela versão `_v12_21`. Para o `team.js` aceitar salvar sem cliente, ela apertava sozinha o botão "+ Novo cliente".
3. **As duas se pisavam.** A v12.21 lia os extras pelos botões "Remover" da v12.13. Uma troca feita por uma passava pela outra.

As funções do banco já existiam e funcionam bem:

- `barberium_staff_create_appointment_v12_21` e `barberium_staff_create_walk_in_v12_21`: criam o cliente passageiro quando pedido e, sem passageiro, fazem exatamente o que as `_v12_12` fazem;
- as `_v12_12`: editam e calculam horários livres com os extras.

## O que mudou

- **`equipe/comanda.js` (novo):**
  - a caixa "Serviços da comanda": adicionar, remover, só os serviços que o profissional faz, nem o serviço principal nem um adicional marcado;
  - o botão "Cliente passageiro".

  São os mesmos ids, textos e mensagens de antes.
- **`team.js`:**
  - **o formulário** desenha a caixa e o botão;
  - **preço de tabela e horários livres** contam os extras;
  - **mudar o serviço, o profissional ou os adicionais** tira os extras que deixam de valer ("Um serviço foi removido porque não é compatível com esta seleção.");
  - **criar** chama direto `_v12_21`; **editar e horários livres** chamam direto `_v12_12`. Ou seja, uma função de criar e uma de editar para cada tipo (horário e encaixe).
- **Saíram:** `equipe/barberium-v12.13.js` (o pacote apaga o arquivo) e a v12.21 de `barberium-v12.17.js`. São dois interceptadores de `fetch` e dois observers a menos.
- **Pequena melhora:** desligar o "Cliente passageiro" volta o formulário ao estado inicial. Antes ele ficava num "novo cliente" sem nome, e o erro só aparecia no banco.
- **O banco não muda.** As funções antigas sem `_v12_xx` continuam lá até a etapa 9.

## Testes executados

Banco local reconstruído do zero com as 99 migrations do repositório e os dados fictícios, restaurado antes de cada rodada.

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Antes × depois, como ADM da Scalabrini: Novo horário com Corte + Barba Tradizionale; Novo encaixe com cliente passageiro (Barba + Sobrancelha); editar o horário e tirar a Barba; serviços oferecidos por profissional. Sem atraso e com 400 ms de atraso em cada chamada | Iguais nas duas versões: preço de tabela e valor final (R$ 165,00), horário gravado (R$ 165,00, 85 min, Barba como serviço da comanda), encaixe do passageiro (sem WhatsApp, origem "passenger", R$ 95,00, Sobrancelha), a edição (R$ 90,00, 40 min, sem extra) e as opções de cada profissional. Fotos idênticas pixel a pixel. Pedidos ao banco iguais campo a campo; criar horário normal passou de `_v12_12` para `_v12_21` com passageiro desligado, como planejado |
| 2 | Passeio antes × depois (cliente, ADM e barbeiro da Scalabrini) | Textos iguais e fotos da equipe 34 de 34 idênticas. Em "Novo horário", uma chamada a menos: o catálogo não é mais buscado de novo, porque o `team.js` já o tem. A busca de horários é a mesma |
| 3 | Todos os testes no navegador (33, com o novo `agenda.spec.js`), com 400 ms de atraso em cada chamada | 33 de 33 |
| 4 | ESLint | Nenhum aviso nos arquivos alterados |

## Risco

- **Médio,** porque mexe em como a equipe cria e edita horários. No teste local, os pedidos ao banco saíram iguais aos de antes, campo por campo. A única diferença é a criação normal, que agora usa `_v12_21` com passageiro desligado em vez de `_v12_12`; a `_v12_21` repassa exatamente para a `_v12_12`.

## Como reverter

1. **Site:** "Rollback" no Cloudflare para o deploy anterior.
2. **Repositório:** subir de volta, da versão `19582d8`, `equipe/team.js`, `equipe/barberium-v12.17.js`, `equipe/index.html` e `deploy/arquivos-do-site.txt`, mais o `equipe/barberium-v12.13.js` apagado. Todos estão no histórico do Git.

## Validação (22/10)

| O quê | Resultado |
| --- | --- |
| Pacote `pacote-etapa7c.zip` | A main (`30ff44c`) ficou idêntica à branch da etapa, e o `barberium-v12.13.js` saiu do repositório |
| Publicar no teste e em produção | Verdes, inclusive o teste novo do formulário no site de teste. O banco não mudou (99 migrations) |
| Site real | Versão `30ff44c`. Os 41 arquivos de páginas, scripts e estilos no ar estão idênticos aos montados a partir da main. O deploy de produção não tem mais o `barberium-v12.13.js` |
| Navegador, sem login | Painel, Área da Equipe e site do cliente abrem sem erro de JavaScript |
