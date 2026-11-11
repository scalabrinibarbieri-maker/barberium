/**
 * V61: o título de cada coluna do "Ligue os pares".
 *
 * Antes a coluna da direita dizia sempre "PORTUGUÊS", mesmo quando as duas colunas estavam no
 * idioma do curso (pergunta → resposta, singular → plural) ou quando um lado era só número,
 * horário, preço ou letra. Agora cada coluna é lida pelo conteúdo:
 * - "course": no idioma do curso (título com a bandeira e o nome do curso);
 * - "portuguese": em português;
 * - "neutral": só números, horários, preços, letras soltas ou pronúncia (/…/) — fica sem título.
 * Na dúvida, mantém o que já era: esquerda no idioma do curso, direita em português.
 *
 * As pistas vêm de palavras curtas típicas de cada idioma, de letras que só um dos idiomas usa e,
 * dentro de uma lição, do vocabulário da própria lição (respostas e falas em italiano de um lado;
 * enunciados e explicações em português do outro).
 */
import { withoutReading } from '../typography/annotatedText.ts';
import type { Exercise, MatchExercise } from './types';

export type ColumnLanguage = 'course' | 'portuguese' | 'neutral';
export type MatchColumns = { left: ColumnLanguage; right: ColumnLanguage };

const words = (s: string) => new Set(s.split(' '));

// Palavras curtas do português que não existem (ou quase não aparecem) nos idiomas dos cursos.
// Ficaram de fora as ambíguas com o italiano: a, o, e, da, no, come, quanto, tu, lei.
const PT = words('os as um uma uns umas de do dos das em nos nas ao aos à às pelo pela pelos pelas que para por com sem ' +
  'é são está estão estou sou somos tem têm tenho temos você vocês eu ele ela eles elas nós meu minha meus minhas seu sua seus suas ' +
  'não sim muito muita mais isso isto este esta esse essa aquele aquela aqui ali até também como onde quando qual quem ' +
  'obrigado obrigada olá oi tchau bom boa dia noite tarde hoje amanhã ontem fica vire siga gosto gostaria preciso quero');

const TARGET: Record<string, Set<string>> = {
  it: words('il lo la i gli le un uno una di del dello della dei degli delle nel nello nella nei nelle sul sullo sulla sui sulle ' +
    'al allo alla ai agli alle dal dallo dalla dai dalle è sono che non per con mio mia miei mie tuo tua questo questa questi queste ' +
    'quello quella quel quei quegli ci si mi ti io lui noi voi loro ho hai ha abbiamo avete hanno anche molto dove ' +
    'perché ciao grazie prego buongiorno buonasera sì costa costano vorrei'),
  en: words('the an is are am i you he she we they my your his her our their this that these those what where when how who and of to ' +
    'in on at for with does not yes please thank thanks hello hi clock pound pounds half past ' +
    'one two three four five six seven eight nine ten eleven twelve twenty thirty forty fifty'),
  es: words('el los la las un una unos unas del y es son en con muy usted yo tú él ella nosotros hola gracias buenos buenas días noches ' +
    'qué dónde cómo cuándo mi mis tu tus su sus'),
  fr: words('le la les un une des du et est sont je tu il elle nous vous ils elles ce cette ces mon ma mes ton ta tes son sa ses qui ' +
    'ne pas oui non bonjour merci avec pour dans au aux très'),
  de: words('der die den dem ein eine einen und ist sind ich du er sie wir ihr nicht ja nein mit für von zu im am bitte danke hallo guten tag'),
};

// Letras que denunciam o idioma (sem as que o português divide com o curso).
// Palavras do português que também são comuns no idioma do curso: não contam como pista.
const SHARED: Record<string, Set<string>> = { es: words('como que para por de con este esta esa ese'), fr: words('de que') };

const TARGET_LETTERS: Record<string, RegExp> = { it: /[èìòù]/u, es: /[ñ¿¡]/u, fr: /[èëïîûùœ]/u, de: /[äöüß]/u };
const NON_LATIN: Record<string, RegExp> = {
  he: /[֐-׿]/u, ar: /[؀-ۿ]/u, ja: /[぀-ヿ一-鿿]/u, zh: /[一-鿿]/u, ko: /[가-힯ᄀ-ᇿ]/u,
};
function ptLetters(course: string): RegExp {
  // ã e õ só existem no português; ç â ê ô também aparecem no francês; á í ú também no espanhol.
  return new RegExp(`[ãõ${course === 'fr' ? '' : 'çâêô'}${['it', 'en', 'de'].includes(course) ? 'áíú' : ''}]`, 'u');
}

function tokens(text: string): string[] {
  return withoutReading(text).toLocaleLowerCase('pt-BR').normalize('NFC').replace(/[’ʼ`´']/gu, ' ')
    .split(/[^\p{L}]+/u).filter(Boolean);
}

/** Neutro: sem letras (números, horários, preços), pronúncia entre barras ou uma ou duas letras maiúsculas. */
function neutral(label: string): boolean {
  const t = withoutReading(label).trim();
  return !/\p{L}/u.test(t) || /^\/.+\/$/u.test(t) || /^\p{Lu}{1,2}$/u.test(t);
}

export type LessonVocabulary = { course: Set<string>; portuguese: Set<string> };

/**
 * Vocabulário da lição: o que com certeza está no idioma do curso (respostas, falas, áudios, colunas do curso nas tabelas)
 * e o que com certeza está em português (traduções, colunas "Português", textos das explicações sem as citações).
 * Enunciados e explicações curtas ficam de fora: costumam misturar os dois idiomas ("Complete a frase: Giulia è ___").
 */
export function lessonVocabulary(exercises: readonly Exercise[] | undefined): LessonVocabulary | undefined {
  if (!exercises?.length) return undefined;
  const course = new Set<string>(), portuguese = new Set<string>();
  const add = (set: Set<string>, text: unknown) => { if (typeof text === 'string') for (const w of tokens(text)) set.add(w); };
  const addPortuguese = (text: unknown) => {
    if (typeof text !== 'string') return;
    // Trechos entre aspas ou *ênfase* nas explicações são palavras do curso citadas no meio do português.
    const quoted = text.match(/“[^”]*”|"[^"]*"|\*[^*]+\*/gu) ?? [];
    for (const q of quoted) add(course, q);
    add(portuguese, text.replace(/“[^”]*”|"[^"]*"|\*[^*]+\*/gu, ' '));
  };
  for (const raw of exercises) {
    const ex = raw as Exercise & Record<string, unknown>;
    if (ex.type === 'match') continue;
    if (ex.type === 'speak') { add(course, ex.prompt); addPortuguese(ex.translation); }
    // Respostas escritas só contam quando o exercício não pede a tradução para o português.
    const toPortuguese = /portugu/i.test(`${ex.prompt} ${ex.instruction}`);
    const answers = [ex.sampleAnswer, ...(Array.isArray(ex.acceptedAnswers) ? ex.acceptedAnswers : [])];
    for (const a of answers) add(toPortuguese ? portuguese : course, a);
    if (typeof ex.audioText === 'string') add(course, ex.audioText);
    if (Array.isArray(ex.turns)) for (const t of ex.turns as Record<string, unknown>[]) {
      if (t.type === 'line') add(course, t.text);
      else if (Array.isArray(t.options)) for (const o of t.options as Record<string, unknown>[]) add(course, o.label);
    }
    if (Array.isArray(ex.words)) for (const w of ex.words as Record<string, unknown>[]) { add(course, w.term); addPortuguese(w.meaning); }
    if (Array.isArray(ex.blocks)) for (const b of ex.blocks as Record<string, unknown>[]) {
      if (b.type === 'text' || b.type === 'tip') addPortuguese(b.text);
      if (b.type === 'example' && Array.isArray(b.lines)) for (const l of b.lines as Record<string, unknown>[]) { add(course, l.it); addPortuguese(l.pt); }
      if (b.type === 'table' && Array.isArray(b.rows) && Array.isArray(b.columns)) {
        const target = typeof b.italian === 'number' ? b.italian : 0;
        const cols = b.columns as string[];
        for (const row of b.rows as string[][]) row.forEach((cell, i) => {
          if (i === target) add(course, cell);
          else if (/portugu/i.test(String(cols[i] ?? ''))) add(portuguese, cell);
        });
      }
    }
  }
  return { course, portuguese };
}

type Vote = 'course' | 'portuguese' | null;

/** Pista forte do idioma do curso: escrita própria, letra exclusiva ou palavra curta típica. */
function strongCourseClue(label: string, course: string): boolean {
  const script = NON_LATIN[course];
  if (script) return script.test(label);
  return Boolean(TARGET_LETTERS[course]?.test(withoutReading(label).toLocaleLowerCase('pt-BR'))) || tokens(label).some(w => TARGET[course]?.has(w));
}

function vote(label: string, course: string, vocab: LessonVocabulary | undefined): Vote {
  const text = withoutReading(label).toLocaleLowerCase('pt-BR');
  const script = NON_LATIN[course];
  if (script) return script.test(label) ? 'course' : null;
  const target = TARGET[course];
  // Pista forte (palavra curta típica ou letra exclusiva) vale 2; palavra do vocabulário da lição vale 1.
  let c = TARGET_LETTERS[course]?.test(text) ? 2 : 0;
  let p = ptLetters(course).test(text) ? 2 : 0;
  for (const w of tokens(label)) {
    const inTarget = target?.has(w) ?? false, inPt = PT.has(w) && !inTarget && !(SHARED[course]?.has(w) ?? false);
    if (inTarget) c += 2;
    if (inPt) p += 2;
    if (vocab && !inTarget && !inPt) {
      const vc = vocab.course.has(w), vp = vocab.portuguese.has(w);
      if (vc && !vp) c++;
      if (vp && !vc) p++;
    }
  }
  return c > p ? 'course' : p > c ? 'portuguese' : null;
}

const allNeutral = (labels: readonly string[]) => labels.length > 0 && labels.every(neutral);

/**
 * A coluna da direita só deixa de ser "português" com pista firme: mais votos do curso que do português,
 * pelo menos metade das linhas (que não são números) votando no curso e alguma pista forte do curso.
 */
function rightColumn(labels: readonly string[], course: string, vocab: LessonVocabulary | undefined): ColumnLanguage {
  if (allNeutral(labels)) return 'neutral';
  let c = 0, p = 0, n = 0;
  for (const label of labels) {
    if (neutral(label)) continue;
    n++;
    const v = vote(label, course, vocab);
    if (v === 'course') c++; else if (v === 'portuguese') p++;
  }
  // O vocabulário da lição sozinho não basta: precisa de pelo menos uma pista forte do curso na coluna.
  return c > p && c * 2 >= n && labels.some(l => strongCourseClue(l, course)) ? 'course' : 'portuguese';
}

export function matchColumns(exercise: Pick<MatchExercise, 'pairs'>, course: string, lesson?: readonly Exercise[]): MatchColumns {
  const left = exercise.pairs.map(p => p.left), right = exercise.pairs.map(p => p.right);
  // A esquerda é sempre o idioma do curso nos exercícios do Lunivo; só some o título quando é só número ou símbolo.
  return { left: allNeutral(left) ? 'neutral' : 'course', right: rightColumn(right, course, lessonVocabulary(lesson)) };
}
