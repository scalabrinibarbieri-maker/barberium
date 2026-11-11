import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { matchColumns, lessonVocabulary } from '../src/features/learning/matchColumns.ts';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const pairs = (list) => ({ pairs: list.map(([left, right], i) => ({ id: `p${i + 1}`, left, right })) });

test('V61: tradução comum continua ITALIANO | PORTUGUÊS', () => {
  assert.deepEqual(matchColumns(pairs([['la casa', 'a casa'], ['il libro', 'o livro'], ['la sedia', 'a cadeira'], ['il letto', 'a cama']]), 'it'),
    { left: 'course', right: 'portuguese' });
  assert.deepEqual(matchColumns(pairs([['Buonasera.', 'Boa noite (ao chegar).'], ['Arrivederci.', 'Até logo.'], ['Prego.', 'De nada.']]), 'it'),
    { left: 'course', right: 'portuguese' });
  assert.deepEqual(matchColumns(pairs([['tea', 'chá'], ['coffee', 'café'], ['milk', 'leite'], ['water', 'água']]), 'en'),
    { left: 'course', right: 'portuguese' });
});

test('V61: italiano dos dois lados (pergunta → resposta, singular → plural) mostra ITALIANO nas duas colunas', () => {
  assert.deepEqual(matchColumns(pairs([['Quanto costa questa mela?', 'Costa due euro.'], ['Quanto costano queste mele?', 'Costano quattro euro.'],
    ['Quanto costa questo panino?', 'Costa cinque euro.'], ['Quanto costano questi panini?', 'Costano sei euro.']]), 'it'), { left: 'course', right: 'course' });
  assert.deepEqual(matchColumns(pairs([['il libro', 'i libri'], ['lo zaino', 'gli zaini'], ['l’amica', 'le amiche'], ['la sorella', 'le sorelle']]), 'it'),
    { left: 'course', right: 'course' });
  assert.deepEqual(matchColumns(pairs([['Giulia', 'in cucina'], ['le chiavi', 'sul tavolo'], ['il libro', 'sotto il divano'], ['il tavolo', 'vicino alla finestra']]), 'it'),
    { left: 'course', right: 'course' });
});

test('V61: números, horários, preços, letras e pronúncia ficam sem título', () => {
  assert.deepEqual(matchColumns(pairs([['due', '2'], ['cinque', '5'], ['dieci', '10'], ['venti', '20']]), 'it'), { left: 'course', right: 'neutral' });
  assert.deepEqual(matchColumns(pairs([['01:00', 'È l’una.'], ['02:00', 'Sono le due.'], ['08:00', 'Sono le otto.'], ['12:00', 'È mezzogiorno.']]), 'it'),
    { left: 'neutral', right: 'course' });
  assert.deepEqual(matchColumns(pairs([['un euro', '€1'], ['due euro', '€2'], ['tre euro', '€3']]), 'it'), { left: 'course', right: 'neutral' });
  assert.deepEqual(matchColumns(pairs([['acca', 'H'], ['cu', 'Q'], ['vu', 'V'], ['zeta', 'Z']]), 'it'), { left: 'course', right: 'neutral' });
  assert.deepEqual(matchColumns(pairs([['car', '/kɑː/'], ['hot', '/hɒt/'], ['bird', '/bɜːd/']]), 'en'), { left: 'course', right: 'neutral' });
  assert.deepEqual(matchColumns(pairs([['£2.00', 'two pounds'], ['£2.50', 'two pounds fifty'], ['£5.00', 'five pounds']]), 'en'), { left: 'neutral', right: 'course' });
});

test('V61: só o vocabulário da lição não troca o português, e palavras dos dois idiomas não contam', () => {
  // Lição "suja": a resposta de um exercício de tradução para o português não entra como italiano.
  const lesson = [
    { id: 'q1', type: 'write', prompt: 'Traduza para o português: la sedia', instruction: 'Escreva em português.', explanation: 'x',
      sampleAnswer: 'a cadeira', acceptedAnswers: ['a cadeira'] },
    { id: 'q2', type: 'write', prompt: 'Escreva em italiano: a cama', instruction: 'Escreva a frase completa em italiano.', explanation: 'x',
      sampleAnswer: 'il letto', acceptedAnswers: ['il letto'] },
  ];
  const vocab = lessonVocabulary(lesson);
  assert.ok(vocab.portuguese.has('cadeira') && !vocab.course.has('cadeira'));
  assert.ok(vocab.course.has('letto'));
  assert.deepEqual(matchColumns(pairs([['il divano', 'o sofá'], ['il letto', 'a cama'], ['la sedia', 'a cadeira'], ['la finestra', 'a janela']]), 'it', lesson),
    { left: 'course', right: 'portuguese' });
  assert.deepEqual(matchColumns(pairs([['un biglietto', 'uma passagem'], ['due biglietti', 'duas passagens'], ['andata e ritorno', 'ida e volta'],
    ['quanto costa?', 'quanto custa?']]), 'it'), { left: 'course', right: 'portuguese' });
});

test('V61: plural italiano reconhecido pelo vocabulário da lição', () => {
  const lesson = [
    { id: 'q1', type: 'info', prompt: 'Plural', instruction: 'Leia', explanation: 'x', blocks: [
      { type: 'table', columns: ['Italiano', 'Português'], rows: [['la mela → le mele', 'a maçã → as maçãs'], ['il panino → i panini', 'o sanduíche → os sanduíches'],
        ['la bottiglia → le bottiglie', 'a garrafa → as garrafas']] }] },
  ];
  assert.deepEqual(matchColumns(pairs([['mela', 'mele'], ['bottiglia', 'bottiglie'], ['panino', 'panini'], ['caffè', 'caffè (não muda)']]), 'it', lesson),
    { left: 'course', right: 'course' });
});

test('V61: cursos com outra escrita usam a própria escrita', () => {
  assert.deepEqual(matchColumns(pairs([['סֵפֶר⟦Séfer⟧', 'Livro'], ['בַּיִת⟦Báyit⟧', 'Casa'], ['מַיִם⟦Máyim⟧', 'Água']]), 'he'), { left: 'course', right: 'portuguese' });
  assert.deepEqual(matchColumns(pairs([['水', 'água'], ['本', 'livro'], ['猫', 'gato']]), 'ja'), { left: 'course', right: 'portuguese' });
});

test('V61: o quadro usa os títulos calculados; a lição passa o próprio vocabulário', () => {
  const board = read('src/components/MatchBoard.tsx');
  assert.match(board, /matchColumns\(exercise, course\.id, lesson\)/);
  assert.match(board, /<ColumnHeading language=\{columns\.left\}/);
  assert.match(board, /<ColumnHeading language=\{columns\.right\}/);
  assert.equal((board.match(/>PORTUGUÊS<\/Text>/g) ?? []).length, 1, '"PORTUGUÊS" só dentro do título calculado');
  assert.match(board, /language === 'neutral'\) return <View style=\{styles\.headingRow\} \/>/);
  assert.match(read('src/app/lesson/[lessonId].tsx'), /lesson=\{lesson\.exercises\}/);
});
