import type { Exercise, MatchExercise, WriteExercise, ListenWriteExercise } from './types';

export function normalizeAnswer(input: string): string {
  return input.normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLocaleLowerCase('pt-BR').replace(/[.,!?;:]+/g, ' ').replace(/\s+/g, ' ').trim();
}

/** Preserva acentos para distinguir uma resposta exata de um acento ausente. */
function preserveAccents(input: string): string {
  return input.normalize('NFC').toLocaleLowerCase('pt-BR')
    .replace(/[.,!?;:]+/g, ' ').replace(/\s+/g, ' ').trim();
}

export type GradingResult = {
  correct: boolean;
  /** Se preenchido, a resposta foi aceita, mas a grafia deve ser apresentada ao aluno. */
  spellingCorrection: string | null;
};

const INCORRECT: GradingResult = { correct: false, spellingCorrection: null };
const EXACT: GradingResult = { correct: true, spellingCorrection: null };

type Edit = { kind: 'insert-delete' | 'substitution' | 'transposition'; position: number } | null;

/**
 * Retorna somente UM erro de digitação: inclusão, omissão, troca de letra ou
 * inversão de caracteres vizinhos. Jamais aceita dois erros numa palavra.
 * A comparação é feita após normalizar pontuação, acentos e caixa.
 */
function oneEdit(expected: string, typed: string): Edit {
  const a = expected.length, b = typed.length;
  if (Math.abs(a - b) > 1 || expected === typed) return null;
  let i = 0;
  while (i < Math.min(a, b) && expected[i] === typed[i]) i++;
  if (a === b) {
    if (i + 1 < a && expected[i] === typed[i + 1] && expected[i + 1] === typed[i] &&
        expected.slice(i + 2) === typed.slice(i + 2)) return { kind: 'transposition', position: i };
    if (expected.slice(i + 1) === typed.slice(i + 1)) return { kind: 'substitution', position: i };
    return null;
  }
  if (a > b && expected.slice(i + 1) === typed.slice(i)) return { kind: 'insert-delete', position: i };
  if (b > a && typed.slice(i + 1) === expected.slice(i)) return { kind: 'insert-delete', position: i };
  return null;
}

/**
 * Regra deliberadamente conservadora: palavras curtas ficam exatas; substituição
 * no final pode representar plural, gênero ou conjugação, então não é tolerada.
 * Apenas um erro no total da frase; não tolera palavras omitidas ou extras.
 * Não é dicionário e não pretende identificar todas as mudanças semânticas.
 */
function minorTypingError(accepted: string, typed: string): boolean {
  const a = accepted.split(' '), b = typed.split(' ');
  if (a.length !== b.length) return false;
  let edits = 0;
  for (let i = 0; i < a.length; i++) {
    const word = a[i]!, attempt = b[i]!;
    if (word === attempt) continue;
    if (word.length < 6 || attempt.length < 5) return false;
    const edit = oneEdit(word, attempt);
    if (!edit) return false;
    // Flexões costumam estar nas duas últimas posições da palavra.
    if (edit.kind === 'substitution' && (word.length < 7 || edit.position >= word.length - 2)) return false;
    // Alterações de um sufixo também podem mudar número e tempo verbal.
    if (edit.kind === 'insert-delete' && edit.position >= word.length - 1) return false;
    edits++;
    if (edits > 1) return false;
  }
  return edits === 1;
}

function preferredSpelling(exercise: WriteExercise | ListenWriteExercise, match: string): string {
  return normalizeAnswer(exercise.sampleAnswer) === normalizeAnswer(match)
    ? exercise.sampleAnswer : match;
}

/** Avaliação detalhada sem mudar o contrato booleano antigo de gradeExercise(). */
export function evaluateExercise(exercise: Exercise, answer: string): GradingResult {
  if (exercise.type === 'info') return INCORRECT; // Tela instrutiva não é uma resposta.
  if (exercise.type === 'match') return gradeMatchingExercise(exercise, answer) ? EXACT : INCORRECT;
  if (exercise.type === 'choice' || exercise.type === 'listen_choice')
    return answer === exercise.correctOptionId ? EXACT : INCORRECT;

  const normalized = normalizeAnswer(answer);
  if (!normalized) return INCORRECT;
  // Exatos e variantes aceitas SEMPRE ganham antes da heurística.
  const exact = exercise.acceptedAnswers.find(expected => normalizeAnswer(expected) === normalized);
  if (exact) {
    const spellingCorrection = preserveAccents(exact) === preserveAccents(answer)
      ? null : preferredSpelling(exercise, exact);
    return { correct: true, spellingCorrection };
  }
  const close = exercise.acceptedAnswers.find(expected => minorTypingError(normalizeAnswer(expected), normalized));
  return close ? { correct: true, spellingCorrection: preferredSpelling(exercise, close) } : INCORRECT;
}

/** Pares codificados em string para manter a interface única de correção das lições. */
export function encodeMatches(matches: Readonly<Record<string, string>>): string {
  return Object.entries(matches).sort(([a], [b]) => a.localeCompare(b))
    .map(([left, right]) => `${left}:${right}`).join('|');
}

export function gradeMatchingExercise(exercise: MatchExercise, answer: string): boolean {
  if (!answer) return false;
  const expected = new Set(exercise.pairs.map(p => p.id));
  const entries = answer.split('|').map(part => part.split(':'));
  if (entries.length !== exercise.pairs.length) return false;
  const lefts = new Set<string>();
  const rights = new Set<string>();
  for (const entry of entries) {
    if (entry.length !== 2) return false;
    const [left, right] = entry;
    if (!left || !right || !expected.has(left) || !expected.has(right) || lefts.has(left) || rights.has(right)) return false;
    lefts.add(left);
    rights.add(right);
    if (left !== right) return false;
  }
  return lefts.size === expected.size && rights.size === expected.size;
}

/** Compatibilidade com todas as lições, testes, XP e motor já publicados. */
export function gradeExercise(exercise: Exercise, answer: string): boolean {
  return evaluateExercise(exercise, answer).correct;
}

export function correctAnswerLabel(exercise: Exercise): string {
  if (exercise.type === 'info') return '';
  if (exercise.type === 'match') return exercise.pairs.map(p => `${p.left} — ${p.right}`).join(' · ');
  if (exercise.type === 'write' || exercise.type === 'listen_write') return exercise.sampleAnswer;
  return exercise.options.find(o => o.id === exercise.correctOptionId)?.label ?? '';
}
