# Estabilização · Etapa 4 · Cache e versão

Data: 20/10/2026. Base: a main depois do `pacote-etapa3.zip` e dos workflows da etapa 3.

Meta da etapa: acabar com o "num celular funciona, no outro aparece a versão antiga" antes de mexer no resto. Cada publicação passa a ter um número de versão, e o celular troca sozinho para a versão nova.

Nada muda na aparência nem no funcionamento do site, e as notificações continuam iguais. O banco não foi alterado.

## Diagnóstico

Medido em 20/10, no site real e no código da main.

1. **O domínio guarda scripts e fotos por 4 horas no navegador.** As páginas chegam com `max-age=0`, mas `app.js`, `sw.js` e as fotos chegam com `max-age=14400`. Isso vem da configuração do domínio no Cloudflare; o site de teste (`pages.dev`) não tem. Os endereços dos scripts não mudam quando o conteúdo muda: na auditoria, `presentation-settings-v12.28.js?v=12.28` teve 5 conteúdos diferentes com o mesmo endereço. Então um celular podia pegar a página nova com o script velho guardado, por até 4 horas.
2. **Dois service workers brigando pelo mesmo lugar.** O site do cliente registrava `sw.js?v=12.4`, e a Área da Equipe registrava `sw.js?v=12.6`. Para o navegador, são dois diferentes. Num celular que usa as duas áreas, cada troca reinstalava tudo e baixava de novo o pré-cache: 44 arquivos, 15 deles fotos (1,9 MB).
3. **O cache tinha nome escrito à mão** (`scalabrini-client-v12-48`). As fotos guardadas só eram trocadas quando alguém lembrava de mudar esse nome. O service worker também guardava, até a próxima troca de nome, tudo o que o site buscava de fora: as fotos enviadas pela equipe (que ficam no Supabase) e as bibliotecas de PDF.
4. **Arquivo que não existe vira a página inicial.** O Cloudflare responde com a página inicial e status 200, e o service worker guardava essa página no lugar do script, sem acusar erro.
5. **Site aberto em segundo plano nunca recarrega.** No celular, o site instalado na tela de início, ou uma aba esquecida, fica com a versão que estava na memória até ser fechado de vez.

## O que mudou

### Como funciona agora

- **Número de versão:** cada publicação ganha um número, que são as 7 primeiras letras do commit. Ele vai no fim do endereço de todo script e estilo (`app.js?v=47f0edc`), numa marca dentro das duas páginas e no arquivo `/versao.json`.
  - Como cada publicação tem endereços novos, nenhum navegador reaproveita o script da versão anterior, nem com o cache de 4 horas do domínio.
- **Um service worker só,** o mesmo endereço (`/sw.js`) e o mesmo escopo nas duas áreas. Cada versão tem o próprio cache (`barberium-<versão>`), e quando ela assume, os caches das versões anteriores são apagados, inclusive o antigo `scalabrini-client-*`.
- **Pré-cache mínimo:** só as duas páginas, para abrirem sem internet. Scripts e estilos continuam vindo sempre da internet, como antes. As fotos do site ficam guardadas a partir da primeira vez que aparecem, até a próxima versão. O que vem de fora do site não passa mais pelo service worker. Também só é guardado o que veio do tipo certo, então uma página no lugar de um script não entra.
- **Troca sozinha (`shared/atualizacao.js`):** a página confere `/versao.json` e recarrega sozinha quando sai uma versão nova, em dois momentos:
  - quando a pessoa volta para o site depois de 10 minutos ou mais fora dele;
  - quando a tela fica 30 minutos aberta sem ninguém mexer.

  Ela nunca recarrega com a janela aberta (finalizar, cancelar, editar), com o cursor num campo ou com um agendamento do cliente em andamento; nesses casos, espera a próxima vez. Se a recarga não trouxer a versão nova, ela não insiste nessa aba.
- **Cabeçalhos de cache explícitos (`_headers`):**
  - páginas, scripts, estilos e o próprio service worker com `no-cache`, ou seja, o navegador sempre confere se mudou;
  - `/versao.json` com `no-store`;
  - as fotos continuam como estão.
- **Conferência depois de publicar:** "Publicar no teste" e "Publicar em produção" esperam o site no ar trocar de versão. Depois conferem `/versao.json` e mostram, no resumo da rodada, os cabeçalhos de cache que chegaram.

### Arquivos

| Arquivo | Mudança |
| --- | --- |
| `sw.js` | Reescrito: versão carimbada, cache por versão, pré-cache só das páginas, só o próprio site passa por ele, só guarda o tipo certo. O trecho das notificações é **idêntico, byte a byte**, ao de antes |
| `shared/atualizacao.js` | Novo. Confere a versão e recarrega no momento certo |
| `app.js`, `push.js`, `equipe/team.js` | Uma linha em cada: o registro do service worker passa a ser o mesmo nas duas áreas (`sw.js`, escopo da raiz, sem cache na conferência) |
| `index.html`, `equipe/index.html` | Uma linha em cada: carregam `shared/atualizacao.js` |
| `deploy/carimbar_versao.py` | Novo. Carimba a versão nas páginas, nos scripts, no service worker e em `versao.json`. Para a publicação se algo ficar sem carimbo |
| `deploy/montar_site.sh` | Chama o carimbo e escreve o `_headers` nos dois sites (o de teste continua com o "não indexar") |
| `deploy/arquivos-do-site.txt` | Entra `shared/atualizacao.js` |
| `testes/e2e/esperar_site.sh` | Além de esperar a troca, confere a versão no ar e mostra os cabeçalhos de cache. Cabeçalho diferente vira aviso, não erro |
| `testes/e2e/versao.spec.js` | Novo, com 8 testes da troca de versão (abaixo). Roda sozinho em "Testar o site de teste", que já roda todos os testes da pasta |
| `supabase/testes/rodar_testes.sh` | Ajuste pequeno: quando um arquivo de teste do banco para no meio, o resumo final continua aparecendo |
| `testes/e2e/fixtures/sw-antes-da-etapa4.js` | Cópia do service worker que está hoje no ar, para testar a passagem dos celulares para o novo |
| `testes/e2e/cliente.spec.js`, `equipe.spec.js` | Conferem que as páginas do site de teste têm a versão |
| `.github/workflows/cloudflare-pages.yml` | Novo passo no fim: "Conferir o site no ar" |
| `docs/COMO-PUBLICAR.md` | Nova seção "Qual versão está no ar" |

## Testes adicionados

Os testes novos rodam no GitHub, dentro de "Testar o site de teste". Eles montam duas versões do site de teste (`aaaaaaa` e `bbbbbbb`), servem as duas dentro do próprio GitHub e simulam uma publicação com o site aberto:

| # | Teste |
| --- | --- |
| 1 | Publicação nova: quem volta depois de 3 minutos continua na versão antiga; quem volta depois de 11 minutos recebe a nova sozinho. O cache da antiga é apagado, e sobra um service worker só |
| 2 | Com o cursor num campo, não recarrega. Depois que a pessoa sai do campo, recarrega |
| 3 | Com a janela da Área da Equipe aberta, não recarrega. Depois que ela fecha, recarrega |
| 4 | Se a janela abrir bem no meio da preparação da troca, desiste e espera a próxima vez |
| 5 | Página aberta na tela, sem ninguém mexer: com 29 minutos não recarrega, com 32 recarrega |
| 6 | Se a recarga não trouxer a versão nova, recarrega uma vez só, sem ficar em ciclo |
| 7 | Celular com o service worker de hoje (`scalabrini-client-v12-48`) passa para o novo, o cache velho é apagado, e a Área da Equipe usa o mesmo service worker |
| 8 | Arquivo inexistente: a página inicial que volta no lugar não é guardada como script; os scripts e a página de verdade são guardados |

## Testes executados

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Os 8 testes acima | Passam. A suíte inteira rodou 5 vezes seguidas: 40 de 40 |
| 2 | Erro de propósito: tirar a proteção do campo em uso, e depois a nova conferência antes de recarregar | Os testes 2 e 4 falham, como deviam |
| 3 | Os 5 testes no navegador da etapa 3 contra o site novo (cópia local do site de teste ligada a um banco local com os dados fictícios), com e sem service worker | 5 de 5 nos dois casos |
| 4 | Montar o site 2 vezes do mesmo commit | Idêntico, arquivo por arquivo |
| 5 | Site de produção de hoje × montagem da main | Idênticos, byte a byte: o domínio não reescreve nada. Por isso a conferência depois de publicar pode comparar arquivo por arquivo |
| 6 | Conferência depois de publicar contra um servidor sem `_headers` | Passa, com aviso dos cabeçalhos |
| 7 | Os 6 arquivos de testes do banco (etapa 3) | 214 conferências, 0 falhas (nada no banco mudou) |
| 8 | `actionlint` nos workflows e `shellcheck` nos scripts | Sem apontamentos |
| 9 | Pacote aplicado numa cópia da main, como o "Aplicar pacote" faz, e os passos do GitHub repetidos nela: montar os dois sites e rodar os 8 testes | Igual ao repositório; os dois sites montam e os 8 testes passam |

Encontrado durante os testes: se a página recarrega bem no meio da troca do service worker, o Chrome mantém o antigo ativo por mais um tempo. Por isso a página espera o novo assumir (até 5 segundos) antes de recarregar. Mesmo quando o antigo demora a sair, ele já busca páginas e scripts da internet, então a versão que aparece é a nova.

## Risco

- **Baixo.** A mudança é toda no site e pode ser revertida pelo Cloudflare em segundos.
- **Recarga automática:** é a única coisa nova que a pessoa pode perceber. Ela só acontece depois de uma publicação, e só num momento sem nada em andamento. O pior caso é a agenda voltar para o dia de hoje quando a pessoa volta para o site depois de 10 minutos fora.
- **iPhone:** aqui só dá para testar no Chrome. O código usa recursos comuns que o Safari também tem. Vale abrir o site de teste num iPhone depois da publicação no teste.
- **Cabeçalhos no domínio real:** a configuração de cache do domínio pode continuar mandando as 4 horas por cima do `_headers`. Isso aparece como aviso no resumo do "Publicar em produção". Mesmo assim, a troca está garantida pelos endereços com a versão; só as fotos podem levar até 4 horas para trocar, como hoje.
- **Primeira vez em cada celular:** o service worker antigo é trocado pelo novo na primeira visita depois da publicação, e o cache antigo de 1,9 MB é apagado.

## Como reverter

- **Site:** no Cloudflare, "Rollback" para o deploy anterior (está no [COMO-PUBLICAR.md](COMO-PUBLICAR.md)). Os celulares voltam ao service worker antigo na visita seguinte.
- **Repositório:** reenviar as versões anteriores dos arquivos da tabela acima, que estão no histórico do GitHub. Sem o `deploy/carimbar_versao.py`, o `montar_site.sh` da etapa 3 volta a publicar sem versão.
