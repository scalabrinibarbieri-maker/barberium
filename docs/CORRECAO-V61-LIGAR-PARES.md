# V61: título das colunas no "Ligue os pares"

Base: V60 aplicada. Pacote: `pacote-v61-ligar-pares.zip`. Só o app muda: não precisa publicar o servidor nem reimportar unidades.

## O problema

No "Ligue os pares", a coluna da direita dizia sempre **PORTUGUÊS**. Isso aparecia errado quando:

- as duas colunas estão em italiano: pergunta → resposta ("Quanto costa questa mela?" → "Costa due euro."), singular → plural ("il libro" → "i libri");
- um lado é só número, horário, preço ou letra ("2", "09:00", "€3", "H").

## O que mudou

Cada coluna agora ganha o título pelo próprio conteúdo:

- **Idioma do curso** (bandeira + ITALIANO, INGLÊS…): quando as linhas estão no idioma do curso;
- **PORTUGUÊS**: quando estão em português, como antes;
- **Sem título**: quando a coluna é só número, horário, preço, letra solta ou pronúncia entre barras. A linha do título continua lá, vazia, para as colunas ficarem alinhadas.

A esquerda continua sendo o idioma do curso (ou fica sem título quando é só número/horário). A direita só deixa de ser "PORTUGUÊS" quando a pista é firme. Na dúvida, fica como era.

Como o app decide (`src/features/learning/matchColumns.ts`):

- **Palavras curtas típicas de cada idioma:** *il, gli, sono, è…* no italiano; *você, não, uma…* no português. As que existem nos dois idiomas não contam (*quanto, come, da, no*).
- **Letras exclusivas:** *è, ò* no italiano; *ã, õ* no português.
- **Vocabulário da própria lição:**
  - contam como italiano as respostas, as falas, os áudios e a coluna em italiano das tabelas;
  - contam como português as traduções e as colunas "Português".
  - Os enunciados ficam de fora, porque misturam os dois idiomas.
- **Escritas próprias:** nos cursos de hebraico, árabe, japonês, chinês e coreano, vale a escrita do curso.

O leitor de tela também anuncia o idioma certo de cada lado ("Italiano: Costa due euro.").

## Conferido

- **Exercícios publicados:** rodei a regra nos 283 "Ligue os pares" publicados (italiano, inglês, hebraico e árabe). 20 mudam de título, e todos os 20 estavam errados antes. Nenhuma coluna em português virou outro idioma. Exemplos:
  - *Costa due euro*, *i libri*, *in cucina*, *È l'una* e *two pounds* passaram a mostrar o idioma do curso;
  - os números, horários, preços e letras ficaram sem título.
- **Revisão:** a tela de Revisão usa o mesmo quadro e continua mostrando ITALIANO | PORTUGUÊS.
- **Testes:** `tests/v61-match-columns.test.mjs` (7 testes). A suíte inteira passa (364) e o `tsc` está limpo.
