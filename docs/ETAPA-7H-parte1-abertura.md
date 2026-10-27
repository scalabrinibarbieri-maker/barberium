# Estabilização · Etapa 7h (parte 1) · Abertura do site do cliente

Data: 27/10/2026. Base: a main com a etapa 7g completa (versão `6204752`, 102 migrations).

**A etapa 7h (site do cliente) vai em 4 partes, por decisão do dono (27/10):**
1. abertura do site;
2. serviços (barra Continuar, nome em italiano, duração);
3. animações e planos;
4. acesso em outro aparelho.

**Decisões do dono para as próximas partes:**
- o acesso em outro aparelho volta por um link de uso único que a barbearia envia pelo WhatsApp;
- o nome em italiano vira um campo opcional no cadastro do serviço.

## Diagnóstico

A abertura do site do cliente era montada por dois arquivos que não conversavam:

- **`app.js`** buscava o catálogo (serviços, profissionais, unidade) e desenhava as telas.
- **O remendo `barberium-client-v12.24.js`** (v12.24 a v12.47, 848 linhas):
  - buscava o catálogo de novo, só para aplicar a marca da barbearia;
  - injetava o próprio CSS;
  - decidia sozinho a manutenção;
  - vigiava a página inteira com um `MutationObserver` para reescrever textos;
  - trazia junto a entrada animada da capa (v12.44), com outro vigia esperando a tela de abertura sair.

O remendo v12.38 busca o catálogo uma terceira vez (sai na parte 2).

**Defeito (anotado na etapa 3):** a tela de abertura saía quando o catálogo do remendo chegava, ou em 2,2 s. Quem tocava em "Agendar" antes do catálogo do `app.js` chegar via a lista de serviços vazia, e ela não se corrigia sozinha. Com internet lenta, o cliente ficava numa tela vazia.

**Defeito para outras barbearias:** o botão "Abrir WhatsApp" de "Solicitar exclusão dos meus dados" apontava sempre para o WhatsApp da Scalabrini.

## O que mudou

- **`cliente/marca.js` (novo).** É o que o remendo fazia com o catálogo, chamado pelo `app.js` com o mesmo catálogo:
  - nome, unidade, logo, capa, textos da página inicial, WhatsApp e mapa;
  - a tela de manutenção;
  - o logo guardado para a tela de abertura;
  - a capa invisível até a foto certa carregar.

  Os textos que dependiam do vigia (confirmação do horário, perfil) já saem certos do `app.js`.
- **`cliente/capa.js` (novo).** A entrada animada da capa. O `app.js` a toca quando o site aparece, sem vigia. O logo com o brilho vem pronto no `index.html`.
- **`cliente/abertura.css` (novo).** O CSS que o remendo injetava, igual.
- **`app.js`:**
  - o catálogo é buscado uma vez só;
  - a ordem da abertura é: catálogo → marca → foto da capa → o site aparece;
  - "Agendar" tocado antes do catálogo mostra "Carregando serviços…" e a lista quando ele chega;
  - em manutenção ou sem catálogo, o site não busca os horários do cliente nem as notificações (ficavam por trás da tela de manutenção);
  - o endereço e a chave do banco vêm de `shared/config.js`;
  - o WhatsApp de "Solicitar exclusão" é o da unidade. Na Scalabrini é o mesmo número; numa barbearia sem WhatsApp cadastrado, o botão não aparece.
- **`index.html`:**
  - o logo da capa vem dentro da moldura do brilho;
  - entra `cliente/abertura.css`;
  - sai o `barberium-client-v12.24.js`.
- **Migration `20261027100000_catalogo_diz_manutencao.sql`.** O catálogo devolve `unit.maintenance`, com a mesma regra que o banco já usa para recusar agendar (sem a chave ou nula = ligada; só `false` abre). O site só obedece. Se o banco não mandar essa informação (rollback), o site usa a regra de antes.
- **Apagado:** `barberium-client-v12.24.js`.
- **`deploy/arquivos-do-site.txt`:** troca o remendo pelos três arquivos novos.

**O que não muda:**
- a aparência e os textos;
- a animação, quadro a quadro;
- a tela de manutenção;
- quem aparece em cada barbearia.

## Testes adicionados

- **`supabase/testes/14_site_do_cliente.sql` (4 conferências):**
  - o catálogo diz manutenção ligada sem a chave, nula ou `true`, e desligada com `false`, sempre igual ao que o banco usa para recusar agendar;
  - o resto do catálogo não muda.
- **`testes/e2e/abertura.spec.js` (2 testes, só olham):**
  - a capa termina a entrada, o brilho do logo tem a imagem e o remendo não é mais pedido;
  - com o catálogo demorando 3,5 s, "Agendar" tocado logo ao abrir mostra "Carregando serviços…" e depois os serviços.
- **`testes/e2e/cliente.spec.js`:** só o comentário sobre o defeito, agora corrigido.

## Testes executados

Banco local igual ao da produção (102 migrations), com a Área do cliente da Scalabrini igual à da produção: textos, destaques, duração escondida e uma capa própria. Site de antes = a main.

| # | Teste | Resultado |
| --- | --- | --- |
| 1 | Abertura antes × depois, em 9 cenários. Ver a lista abaixo da tabela | Fotos idênticas na abertura (com e sem animação), na Aurora, nas duas manutenções e sem catálogo. A entrada animada é igual (mesmas classes aos 0, 300 e 900 ms). Textos, título, descrição, links, logo guardado e tela de manutenção iguais. Diferenças, todas esperadas: catálogo buscado 2 vezes em vez de 3; "Agendar" cedo antes ficava vazio e agora mostra os 11 serviços; em manutenção, o site não pede mais a configuração de notificações por trás da tela; exclusão na Aurora sem o WhatsApp da Scalabrini |
| 2 | Passeio do cliente antes × depois (agendar, ver, perfil, cancelar), na Scalabrini e na Aurora com escolha de unidade | Textos e chamadas iguais, menos uma busca do catálogo. Fotos: 9 de 13 e 11 de 14 idênticas; as outras diferem em 17 pontos fracos no topo, de transição |
| 3 | Todos os testes do banco, reconstruído do zero com 103 migrations e os dados fictícios | 400 de 400 |
| 4 | Impressão digital antes × depois; rollback de verdade; reaplicação pelo pipeline; ensaio num banco igual à produção | Só a diferença esperada (o catálogo). O rollback volta idêntico ao de antes, a reaplicação ao de depois, e o ensaio roda e desfaz |
| 5 | Catálogo na produção (só leitura) | Idêntico ao do banco de antes, inclusive as permissões |
| 6 | Todos os testes no navegador com o banco migrado e 400 ms de atraso | 39 de 39, inclusive os 2 novos |
| 7 | Publicação de outra barbearia (`personalizar_barbearia.py`) com o `index.html` novo | Funciona: todos os trechos trocados existem e não sobra nada da Scalabrini |
| 8 | Conferência do código (`node --check` e ESLint) | Sem erros. `app.js` com 1 aviso antigo (variável sem uso), 1 a menos que antes |
| 9 | Pacote aplicado numa cópia da main de produção, como faz o "Aplicar pacote" | Repositório idêntico ao da etapa. Sites de produção e de teste montam sem referência faltando |

**Cenários do teste 1:**
- abertura com animação;
- abertura sem animação;
- "Agendar" tocado logo ao abrir, com o catálogo demorando 3,5 s;
- sem catálogo;
- Aurora;
- "Solicitar exclusão" na Scalabrini e na Aurora;
- manutenção ligada;
- manutenção sem a chave.

## Risco

- **Médio pelo assunto, baixo pelo efeito agora.** É a primeira tela do cliente, mas o site da Scalabrini está em manutenção na produção. Hoje o cliente vê só a tela de manutenção, que é idêntica.
- **Se algo der errado:** na abertura do site do cliente. A Área da Equipe não muda.

## Como reverter

1. **Banco:** rodar `docs/etapa7h1_rollback.sql` no SQL Editor. O site novo continua funcionando sem a informação nova.
2. **Repositório:**
   - apagar a migration `20261027100000_catalogo_diz_manutencao.sql`;
   - apagar os testes `14_site_do_cliente.sql` e `abertura.spec.js`.
3. **Site:**
   - subir de volta, da versão `6204752`, `index.html`, `app.js`, `barberium-client-v12.24.js` e `deploy/arquivos-do-site.txt`;
   - apagar a pasta `cliente/`.
