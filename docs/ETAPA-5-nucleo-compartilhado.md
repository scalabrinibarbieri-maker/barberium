# Estabilização · Etapa 5 · Núcleo compartilhado

Data: 20/10/2026. Base: a main com a etapa 4 publicada (versão `54c101b`).

Meta da etapa: trocar as cópias do código de login e de conversa com o banco da Área da Equipe por um núcleo só, sem mudar nenhuma tela.

O banco e o site do cliente não mudam nesta etapa.

## Diagnóstico

1. **14 cópias do mesmo código.** 12 arquivos da Área da Equipe tinham a própria cópia (o `barberium-v12.17.js` tinha 3). Cada uma lia o login do aparelho, chamava o banco e, ao receber "401" (login vencido), renovava o login sozinha. Havia ainda uma 15ª renovação, solta, antes do envio de fotos em Ajustes.
2. **Renovações ao mesmo tempo derrubam o login.** O Supabase troca o refresh token a cada renovação, e o antigo deixa de valer. Quando dois módulos recebem "401" juntos, os dois renovam com o mesmo token: um consegue, o outro é recusado. A tela daquele módulo dá erro, e se for a agenda, a Área da Equipe volta para o login. O teste abaixo reproduziu isso com o código de antes: o barbeiro foi desconectado na 2ª vez em que o login venceu.
3. **Nenhuma chamada tinha prazo.** Uma resposta que não volta deixava a tela em "Carregando" para sempre.
4. **Cada módulo escolhe por qual caminho a chamada passa.** Alguns módulos interceptam as chamadas de outros (a etapa 7 desfaz isso). Três cópias usavam de propósito o fetch guardado antes de certos interceptadores. O núcleo precisava manter exatamente o mesmo caminho para cada módulo.

## O que mudou

### Núcleo (`shared/`)

| Arquivo | O que faz |
| --- | --- |
| `shared/config.js` | Endereço e chave pública do Supabase e o nome do login guardado no aparelho, num lugar só. A montagem do site de teste troca os dois primeiros pelos do banco de teste, como antes |
| `shared/api.js` | Login e chamadas da Área da Equipe, com as regras abaixo |

Regras do `shared/api.js`:

- **Uma renovação por vez no aparelho:** as chamadas que recebem "401" juntas esperam a mesma renovação. Entre abas, isso usa um recurso do navegador (Web Locks), presente nos navegadores atuais; no Safari do iPhone, desde 2022.
- **Antes de renovar, relê o login guardado.** Se outro módulo ou outra aba já renovou, usa o login novo e não renova de novo.
- **Refresh token recusado não é tentado de novo,** para não piorar a situação.
- **Prazo:** 30 segundos para chamadas ao banco e 120 segundos para envio de fotos. Depois disso aparece "A conexão demorou demais. Confira a internet e tente de novo." no lugar do "Carregando" sem fim. O próprio Supabase corta consultas em 8 segundos, então nenhuma chamada que funciona hoje passa perto de 30.
- **Erros:** a mensagem é a mesma de antes, então as telas mostram o mesmo texto. O erro também passa a trazer o status HTTP e o código do banco (ex.: `P0001`), para as próximas etapas tratarem cada caso sem depender do texto.
- **Mesmo caminho de antes:** cada módulo cria o seu cliente dizendo qual fetch usava. A maioria usa o fetch do momento da chamada, que passa pelos interceptadores, como antes. Os módulos v12.13, v12.20 e v12.24 continuam com o fetch que guardavam.

### Arquivos da Área da Equipe (um commit para cada)

`team.js`, `agenda-cancelados-v12.8.js`, `cancel-permission-v12.45.js`, `finance-reports.js`, `settings.js`, `barberium-v12.9.js`, `barberium-v12.10.js`, `barberium-v12.13.js`, `barberium-v12.17.js` (v12.20, v12.23 e v12.24), `presentation-settings-v12.28.js`, `staff-tools-v12.33.js` e `balances-v12.39.js`.

Em cada um, a cópia saiu e entrou uma linha que usa o núcleo, com os mesmos nomes de função de antes. O resto do arquivo não mudou. No total foram **442 linhas a menos e 73 a mais** nesses 12 arquivos.

O envio de fotos em Ajustes (`settings.js`) usa a renovação do núcleo, com as mesmas mensagens de antes.

O `barberium-v12.12.js` também tem uma cópia, mas nenhuma página carrega esse arquivo. Ele sai na etapa 9, com os outros arquivos sem uso.

### O que ficou para depois, e por quê

- **`shared/dates.js` e `shared/money.js`:** o plano previa os dois nesta etapa. Criar agora seria publicar arquivos que nenhuma tela usa, porque trocar as datas e os valores dos módulos muda comportamento. A data de "hoje", por exemplo, hoje vem do relógio do aparelho. Eles entram junto com o primeiro uso: datas na etapa 7g (fuso da barbearia) e valores quando os módulos de cada área forem refeitos.
- **Site do cliente:** ele não tem login de equipe; usa só a chave pública e o token do cliente. As chamadas dele passam para o núcleo na etapa 6, junto com o "tenant por domínio", que já mexe na configuração do site do cliente.

## Testes adicionados

`testes/e2e/sessao.spec.js` tem 8 testes. Eles rodam no GitHub dentro de "Testar o site de teste", com o site montado e o Supabase simulado no navegador. Nesse Supabase simulado, o refresh token vale uma vez só.

| # | Teste |
| --- | --- |
| 1 | 8 chamadas ao mesmo tempo, de 3 módulos, com o login vencido: 1 renovação, todas funcionam, login novo guardado |
| 2 | Duas abas com o login vencido ao mesmo tempo: 1 renovação no aparelho |
| 3 | Outra aba renovou enquanto a chamada estava no caminho: usa o login novo, sem renovar |
| 4 | Refresh token recusado: o erro tem a mesma mensagem de antes ("JWT expired"), com status e código, e a segunda chamada não tenta renovar de novo |
| 5 | Sem login: chama sem token e não tenta renovar |
| 6 | Mensagens de erro iguais às de antes para os 5 formatos de resposta do Supabase, mais status e código |
| 7 | Módulo com o próprio fetch: as 3 chamadas (a que recebeu 401, a renovação e a nova tentativa) passam por ele |
| 8 | Chamada que não responde: nada até 29 s; aos 31 s, a mensagem de prazo esgotado |

## Testes executados

Feitos com uma cópia local do site de teste ligada a um banco local com os dados fictícios. A cópia usava um Supabase local que imita o real, com o refresh token de uso único.

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | **Passeio antes × depois**, refeito depois de cada arquivo trocado. Login como ADM e como barbeiro, 25 passos cada: agenda, horários livres, cancelados, novo horário, abrir atendimento, Resumo, Clientes, Financeiro (Saldos, Visão, Caixa, Comissões, Acertos, Minhas comissões, Planos, Contratos), Produtos, Equipe e Ajustes. Para cada passo foram gravadas as chamadas ao banco, o texto da tela, a foto da tela e os erros | Idêntico ao de antes: as mesmas chamadas, com os mesmos dados, o mesmo texto e os mesmos avisos no console. As fotos da tela também são idênticas. A exceção é a tela de Saldos, que às vezes muda uns pixels nas fotos dos barbeiros; isso acontece até entre duas rodadas do código antigo, porque as fotos terminam de carregar em momentos diferentes |
| 2 | **Login vencendo** a cada rodada e dois módulos chamando o banco ao mesmo tempo (agenda do dia seguinte e Horários livres), 4 rodadas | **Antes:** em toda rodada, 2 renovações e 1 recusada; a chamada recusada falhou; o barbeiro foi desconectado na 2ª rodada. **Depois:** 1 renovação por rodada, nenhuma recusada, todas as chamadas funcionaram, ninguém foi desconectado |
| 3 | Envio de foto em Ajustes com o login a menos de 60 s de vencer | Antes e depois: renova uma vez, envia a foto e grava o caminho |
| 4 | Os 21 testes no navegador (5 do site, 8 da troca de versão, 8 da sessão) | 21 de 21 |
| 5 | Erro de propósito no núcleo, um de cada vez: sem a trava, sem a trava entre abas, sem reler o login, sem lembrar a recusa, sem prazo | Cada um faz o teste correspondente falhar |
| 6 | Verificação do código com ESLint (variável sem definição, nome repetido) | Nenhum erro. Ficaram só os 9 avisos de variável sem uso que já existiam antes |
| 7 | Site de produção montado | O núcleo com a versão carimbada (`?v=`) nos 15 imports; endereço e chave da produção só no `shared/config.js`, no site do cliente e no arquivo sem uso `barberium-v12.12.js` |

## Risco

- **Baixo a médio, porque mexe no login.** Se algo der errado, a equipe pode não conseguir entrar. Proteções:
  - o passeio antes × depois foi idêntico;
  - os testes do site de teste entram com os 3 logins de verdade antes de qualquer publicação;
  - a volta é pelo Cloudflare, em segundos.
- **Prazo de 30 s:** uma chamada que antes ficaria pendurada agora mostra erro. Isso é o esperado.
- **Navegador sem Web Locks** (Safari anterior a 2022): dentro da mesma aba a proteção vale igual. Entre duas abas renovando no mesmo instante, ainda pode haver conflito, como antes.
- **Ninguém é desconectado na publicação:** o login guardado continua no mesmo lugar e no mesmo formato.

## Como reverter

- **Site:** "Rollback" no Cloudflare para o deploy anterior (está no [COMO-PUBLICAR.md](COMO-PUBLICAR.md)). Não há nada no banco para desfazer.
- **Repositório:** cada arquivo tem o seu commit, então dá para voltar um arquivo só. Os arquivos que voltarem passam a usar a própria cópia de novo, e os outros continuam no núcleo. Os dois convivem, porque leem o mesmo login guardado.

## Validação (21/10)

| O quê | Resultado |
| --- | --- |
| Aplicar pacote (`pacote-etapa5.zip`) e Publicar no teste | Verdes. O "Publicar em produção" só roda se a mesma versão passou no teste, inclusive nos testes no navegador com os logins de verdade |
| Publicar em produção | Site real na versão `3f9b73a`. Os 35 arquivos de páginas, scripts e estilos no ar estão idênticos aos montados a partir da main |
| Site real aberto no Chrome, só leitura | Área da Equipe e site do cliente na versão `3f9b73a`, nenhum erro na página e nenhum arquivo faltando. Um login com senha errada passa pelo núcleo e volta com a mensagem de sempre. Um service worker só |
