# Estabilização · Etapa 7a · Ajustes, marca e manutenção

Data: 22/10/2026. Base: a main com a etapa 6C publicada (versão `34518b3`).

Meta da etapa: tirar da tela de Ajustes os remendos que se corrigiam uns aos outros e fazer a manutenção do site do cliente valer também no banco. Para quem usa, a tela fica igual.

## Diagnóstico

1. **Salvar a unidade apagava o que outra tela tinha acabado de salvar.** `barberium_staff_save_unit` trocava as configurações inteiras da unidade pelas que a tela tinha. A tela de Ajustes guarda as configurações de quando abriu, então salvar a aparência e depois as regras da agenda devolvia os valores antigos.
2. **Três remendos tentavam esconder isso:**
   - **v12.24** (em `barberium-v12.17.js`): injetava o cartão "Área do cliente" por observer e reescrevia, dentro do `fetch`, todo salvar da unidade com a aparência guardada;
   - **v12.28/v12.47** (`presentation-settings-v12.28.js`): injetava apresentação e manutenção no mesmo cartão, com um observer no documento inteiro, e trocava o salvar da v12.24;
   - **v12.42** (mesmo arquivo): salvava por XHR para fugir da proteção da v12.24, que recolocava a aparência antiga.
3. **Mesmo com os remendos, o defeito aparece.** No passeio local, ligar a manutenção no cartão e depois salvar as regras da agenda **desligou a manutenção de novo**, sem aviso. O mesmo vale para a apresentação da página inicial.
4. **A manutenção era só uma camada na tela.** O site do cliente mostra "temporariamente indisponível", mas o banco aceitava agendamento e reagendamento por fora (direto na API).

## O que mudou

### Banco (migration `20261022200000_ajustes_e_manutencao`)

| O quê | Para quê |
| --- | --- |
| `barberium_staff_save_unit` | Grava só as chaves de configuração que recebe; as outras continuam. Recusa configurações que não são um objeto |
| `barberium.unidade_em_manutencao(settings)` | A regra da tela, num lugar só: sem a chave `client_maintenance_mode`, ou nula, conta como manutenção ligada; só `false` abre |
| `barberium_create_appointment` e `barberium_reschedule_appointment` | Com a unidade em manutenção, recusam com `UNIT_IN_MAINTENANCE` |

Com a manutenção ligada:

- **Continua:** a equipe agenda pela Área da Equipe, e o cliente pode cancelar o próprio horário.
- **Para:** o site do cliente não agenda nem reagenda, nem por fora.

### Área da Equipe

- **`equipe/area-do-cliente.js` (novo):** o cartão "Área do cliente" de Ajustes → Barbearia. São os mesmos campos, textos, ids e mensagens de antes, desenhados junto com a tela, sem observer. Ele salva só as chaves dele, com os dados da unidade buscados na hora (como antes).
- **`equipe/settings.js`:** desenha o cartão logo abaixo de "Barbearia". O formulário da unidade manda só as regras da agenda.
- **Saíram** a v12.24 de `barberium-v12.17.js` e a v12.28/v12.47 e a v12.42 de `presentation-settings-v12.28.js`. Nesse arquivo ficou só a v12.29, que sai na etapa 7b.
- **O rótulo "Ajustes"** do menu agora está no `index.html`, sem observer. Os estilos do cartão e do login mais alto foram para `settings.css` e `team.css`.

Ao todo, saem da Área da Equipe dois interceptadores de `fetch` (v12.24 e v12.42) e três observers (o do cartão, o do menu e o do documento inteiro). O terceiro interceptador do mesmo arquivo, o da v12.29, fica para a 7b.

### Site do cliente

`app.js` ganhou a mensagem para a recusa do banco: "A agenda online está fechada no momento. Fale com a barbearia pelo WhatsApp." Ela só aparece se alguém estiver com o site aberto quando a manutenção for ligada.

## Testes adicionados

| Onde | Testes |
| --- | --- |
| `supabase/testes/10_ajustes_e_manutencao.sql` (17 conferências) | A regra da manutenção igual à da tela. Salvar a unidade: a chave enviada muda e as outras ficam; sem configurações, nada muda; formato inválido é recusado; unidade nova nasce com o que foi enviado; barbeiro e ADM de outra barbearia não salvam. Manutenção: o site não agenda (ligada, ou nunca salva), agenda quando desligada, não reagenda; o cliente ainda cancela; a equipe ainda agenda |
| `testes/e2e/ajustes.spec.js` (2 testes, no site de teste) | O ADM da Aurora abre Ajustes → Barbearia, vê o cartão completo e salva. O banco recusa agendamento pela API na "Barbearia Painel Teste", que está em manutenção |

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Banco reconstruído como a produção (98 migrations); ensaio da migration nova | Ensaio ok |
| 2 | Migration aplicada + dados fictícios; todos os testes do banco | 328 conferências, 0 falhas |
| 3 | Rollback (`docs/etapa7a_rollback.sql`) e impressão digital | Volta exatamente à impressão digital de antes. Aplicar de novo dá a mesma de depois |
| 4 | Cartão "Área do cliente" antes × depois, no computador | Textos, valores dos campos, ordem na tela e imagens iguais; foto do cartão idêntica pixel a pixel. O rótulo do menu continua "Ajustes". Duas chamadas a menos ao banco ao abrir |
| 5 | Salvar a aparência (manutenção ligada) e depois as regras da agenda, sem recarregar | **Antes: a manutenção voltou a ficar desligada** (o defeito). Depois: a grade de 15 min foi gravada e o título e a manutenção ficaram como salvos |
| 6 | Envio da logo pelo cartão | Vai para a pasta `client/logo` da unidade e fica salva |
| 7 | Todos os testes no navegador (32), com uma cópia local do site e do Supabase | 32 de 32 |
| 8 | Passeio antes × depois (cliente, ADM e barbeiro da Scalabrini), com o banco restaurado antes de cada passeio | Iguais nos três. Fotos da equipe: 34 de 34 idênticas. Site do cliente: 10 de 13; as outras diferem só pelas animações |
| 9 | ESLint nos arquivos alterados | Nenhum erro (o aviso que sobrou no `settings.js` já existia) |

## Primeira publicação no teste (22/10): vermelha, corrigida

O "Publicar no teste" da primeira versão (`64fde54`) ficou vermelho. O teste novo do navegador pegou um defeito que já existia em `settings.js`. Quem toca numa aba de Ajustes (Barbearia, Serviços…) antes de a tela terminar de carregar recebe um erro de JavaScript ("Cannot read properties of null (reading 'barbershop')"). A tela se desenha logo depois, então ninguém percebia.

No computador local o banco responde rápido demais para isso acontecer. Com 400 ms de atraso em cada chamada, como na rede de verdade, o erro aparece na versão publicada e também na versão anterior à 7a. A correção: tocar na aba antes do carregamento só escolhe a aba, e a tela desenha quando os dados chegam. Com o atraso, os 32 testes do navegador passam.

A publicação em produção não chegou a acontecer, porque ela só aceita a versão que passou no teste.

## Risco

- **Baixo.** A tela é a mesma. O que muda de comportamento é o defeito corrigido: salvar uma parte não desfaz mais a outra.
- **Manutenção no banco:** unidade que nunca salvou a manutenção passa a recusar agendamento pelo site, como a tela já mostrava. **Na produção, a Scalabrini está assim hoje** (o site está em manutenção). Quando o dono reabrir em Ajustes → Barbearia → Área do cliente, desligando a manutenção, o agendamento volta.

## Como reverter

1. **Site PRIMEIRO:** "Rollback" no Cloudflare para o deploy anterior. O site novo manda só as chaves que mudou; com o banco antigo, isso apagaria as outras.
2. **Banco:** rodar `docs/etapa7a_rollback.sql` no SQL Editor. Nenhum dado muda.
3. **Repositório:** apagar a migration `20261022200000_ajustes_e_manutencao.sql`.

## Validação (22/10)

| O quê | Resultado |
| --- | --- |
| Pacotes `pacote-etapa7a.zip` e `pacote-etapa7a-correcao.zip` | A main (`f31eedf`) ficou idêntica à branch da etapa |
| Publicar no teste (com a correção) | Verde. No teste, o ADM da Aurora salvou o cartão "Área do cliente" pelo teste do navegador, e a manutenção da unidade continuou como estava |
| Publicar em produção | Migration `20261022200000` aplicada pelo pipeline. Banco real idêntico ao reconstruído só com o repositório (99 migrations, 9 partes da impressão digital) |
| Site real | Versão `f31eedf`. Os 43 arquivos de páginas, scripts e estilos no ar estão idênticos aos montados a partir da main |
| Navegador, sem login | Painel, Área da Equipe e site do cliente abrem sem erro de JavaScript |
| Manutenção no banco, na produção | A Scalabrini nunca salvou a manutenção, então conta como fechada. Um pedido de agendamento direto na API foi recusado com `UNIT_IN_MAINTENANCE`, antes de gravar qualquer coisa |
