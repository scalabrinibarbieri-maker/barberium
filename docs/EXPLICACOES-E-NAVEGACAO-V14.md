# Lunivo V14 — Navegação, explicações e letras

## Navegação
- A aba selecionada é desabilitada: tocar em Aprender novamente não inicia uma nova rota nem provoca a faixa branca observada no Android.
- Toques repetidos em outra aba são bloqueados até completar a transição.
- Cursos e Perfil: fade curto (180 ms); lições mantêm transição de avanço; resultado usa fade de 200 ms.
- Não muda URLs, deep links, login, XP ou identificadores.

## Etapas informativas (tipo `info`)
`info` é **uma etapa dentro de uma lição**, misturável com `write`, `choice`, `match`, etc. Não há novas etapas informativas no catálogo existente.

Modelo de uma futura etapa, dentro de `lessons[].exercises[]` no curso R2:

```json
{
  "type": "info",
  "id": "q30",
  "instruction": "Conheça a cultura",
  "prompt": "O café na Itália",
  "explanation": "Na Itália, um espresso faz parte da rotina.\nEm diferentes regiões, você encontrará costumes distintos.",
  "category": "culture",
  "image": {
    "url": "https://seu-cdn-publico.example/images/cafe.jpg",
    "alt": "Uma xícara de espresso sobre o balcão",
    "caption": "Um espresso no balcão italiano"
  }
}
```

- `category` opcional: `vocabulary`, `culture`, `grammar`, `tip`.
- `image` opcional: HTTPS público, `url`, `alt` obrigatório e `caption` opcional; nada de HTML/WebView.
- `explanation` até 1800 caracteres; aceita quebras de linha normais.
- A imagem carrega online; se indisponível, mostra mensagem e mantém o texto. **O cache offline das futuras imagens não está implementado**. Áudios e downloads já existentes continuam intactos.
- A etapa informativa não verifica resposta e não gera XP nem toca som de acerto/erro. O usuário usa `Entendi, continuar`.
- Cada lição remota ainda deve conter ao menos um exercício avaliativo.
- Ao publicar imagens, hospedá-las em CDN HTTPS público; arquivos de imagem não devem ser anexados ao ZIP `curso-lunivo-*.zip` (o publicador atual aceita apenas os JSONs).

## Letras embaralhadas
- Nos exercícios `write` e `listen_write` com até 42 caracteres, há um seletor `Teclado / Letras` acima da resposta.
- Tocar nas letras constrói a resposta sem teclado; suporta letras repetidas, palavras e espaços automáticos, apagar e limpar.
- O aluno pode voltar ao teclado; alternar de modo reinicia a resposta daquela questão para evitar mistura acidental.
- Ao verificar, continua valendo o motor de correção de grafia V13, feedback sonoro V10 e XP original.
- Respostas muito longas usam apenas o teclado para manter os botões acessíveis.
