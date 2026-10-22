import type { Exercise, Lesson } from '../learning/types';

/** Contrato público v1: as lições locais e remotas continuam com os mesmos IDs. */
export type CourseLessonSummary = { id: string; title: string; subtitle: string; exerciseCount: number };
export type CourseUnitSummary = {
  id: string; language: string; level: string; order: number; title: string; subtitle: string;
  revision: number; lessons: CourseLessonSummary[];
};
export type CourseCatalog = { version: 1; units: CourseUnitSummary[] };
export type CourseUnit = { version: 1; unitId: string; revision: number; lessons: Lesson[] };
export const EMPTY_CATALOG: CourseCatalog = { version: 1, units: [] };
export const BUNDLED_LESSONS = new Set(['it-a1-01', 'it-a1-02', 'it-a1-03']);
const UNIT_ID = /^[a-z]{2}-(?:a1|a2|b1|b2|c1|c2)-u[0-9]{2,4}$/;
const LESSON_ID = /^[a-z]{2}-(?:a1|a2|b1|b2|c1|c2)-[0-9]{2,4}$/;
const EXERCISE_ID = /^q[0-9]{2,6}$/;
const STR = (value: unknown, max: number) => typeof value === 'string' && value.trim().length > 0 && value.length <= max;
const OBJ = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === 'object' && !Array.isArray(value);
const INTEGER = (value: unknown, min: number, max: number) => Number.isSafeInteger(value) && Number(value) >= min && Number(value) <= max;
function fail(): never { throw new Error('CONTEUDO_REMOTO_INVALIDO'); }

/** Somente HTTPS público para imagens remotas (evita file:, data:, javascript: e hosts locais). */
export function validLessonImageUrl(input: unknown): input is string {
  if (typeof input !== 'string' || input.length > 700 || !input.startsWith('https://')) return false;
  try {
    const url = new URL(input);
    if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.port) return false;
    const hostname = url.hostname.toLowerCase();
    if (!hostname.includes('.') || hostname === 'localhost' || hostname.endsWith('.localhost') ||
        hostname.endsWith('.local') || hostname.endsWith('.internal') || /^(?:\d{1,3}\.){3}\d{1,3}$/.test(hostname) ||
        hostname === '[::1]' || hostname === '[::]') return false;
    return true;
  } catch { return false; }
}

export function parseCourseCatalog(input: unknown): CourseCatalog {
  if (!OBJ(input) || input.version !== 1 || !Array.isArray(input.units) || input.units.length > 100) fail();
  const units: CourseUnitSummary[] = [];
  const unitIds = new Set<string>();
  const lessonIds = new Set<string>(BUNDLED_LESSONS);
  for (const raw of input.units) {
    if (!OBJ(raw) || typeof raw.id !== 'string' || !UNIT_ID.test(raw.id) ||
        !STR(raw.language, 24) || !STR(raw.level, 2) || !STR(raw.title, 90) || !STR(raw.subtitle, 180) ||
        !INTEGER(raw.order, 2, 9999) || !INTEGER(raw.revision, 1, 99999) ||
        !Array.isArray(raw.lessons) || raw.lessons.length < 1 || raw.lessons.length > 20 || unitIds.has(raw.id)) fail();
    if (raw.id.slice(0, 2) !== raw.language || raw.id.split('-')[1]?.toUpperCase() !== raw.level) fail();
    unitIds.add(raw.id);
    const lessons: CourseLessonSummary[] = [];
    for (const entry of raw.lessons) {
      if (!OBJ(entry) || typeof entry.id !== 'string' || !LESSON_ID.test(entry.id) ||
          !entry.id.startsWith(raw.id.slice(0, 5) + '-') || lessonIds.has(entry.id) ||
          !STR(entry.title, 90) || !STR(entry.subtitle, 180) || !INTEGER(entry.exerciseCount, 2, 30)) fail();
      lessonIds.add(entry.id);
      lessons.push({ id: entry.id, title: String(entry.title), subtitle: String(entry.subtitle), exerciseCount: Number(entry.exerciseCount) });
    }
    units.push({ id: raw.id, language: String(raw.language), level: String(raw.level),
      title: String(raw.title), subtitle: String(raw.subtitle), order: Number(raw.order),
      revision: Number(raw.revision), lessons });
  }
  units.sort((a, b) => a.language.localeCompare(b.language) || a.level.localeCompare(b.level) || a.order - b.order);
  return { version: 1, units };
}

function validateExercise(value: unknown): value is Exercise {
  if (!OBJ(value) || !STR(value.id, 16) || typeof value.id !== 'string' || !EXERCISE_ID.test(value.id) ||
      !STR(value.prompt, 500) || !STR(value.instruction, 150) ||
      !STR(value.explanation, value.type === 'info' ? 1800 : 700)) return false;
  if (value.type === 'info') {
    if (value.category !== undefined && !['vocabulary', 'culture', 'grammar', 'tip'].includes(String(value.category))) return false;
    if (value.image !== undefined) {
      if (!OBJ(value.image) || !validLessonImageUrl(value.image.url) || !STR(value.image.alt, 180) ||
          (value.image.caption !== undefined && !STR(value.image.caption, 240))) return false;
    }
    return Object.keys(value).every(key => ['type', 'id', 'prompt', 'instruction', 'explanation', 'category', 'image'].includes(key));
  }
  if (value.type === 'choice' || value.type === 'listen_choice') {
    if (!Array.isArray(value.options) || value.options.length < 2 || value.options.length > 6 || !STR(value.correctOptionId, 20)) return false;
    const ids = new Set<string>();
    for (const opt of value.options) {
      if (!OBJ(opt) || !STR(opt.id, 20) || !STR(opt.label, 160) || ids.has(String(opt.id))) return false;
      ids.add(String(opt.id));
    }
    if (!ids.has(String(value.correctOptionId))) return false;
    return value.type !== 'listen_choice' || (typeof value.audioExerciseId === 'string' && EXERCISE_ID.test(value.audioExerciseId));
  }
  if (value.type === 'write' || value.type === 'listen_write') {
    if (!Array.isArray(value.acceptedAnswers) || value.acceptedAnswers.length < 1 || value.acceptedAnswers.length > 10 ||
        !value.acceptedAnswers.every((x: unknown) => STR(x, 180)) || !STR(value.sampleAnswer, 180)) return false;
    return value.type !== 'listen_write' || (typeof value.audioExerciseId === 'string' && EXERCISE_ID.test(value.audioExerciseId));
  }
  if (value.type === 'match') {
    if (!Array.isArray(value.pairs) || value.pairs.length < 2 || value.pairs.length > 8) return false;
    const ids = new Set<string>();
    for (const pair of value.pairs) {
      if (!OBJ(pair) || !STR(pair.id, 30) || !STR(pair.left, 100) || !STR(pair.right, 100) ||
          !/^[a-z0-9-]{1,30}$/.test(String(pair.id)) || ids.has(String(pair.id))) return false;
      ids.add(String(pair.id));
    }
    return true;
  }
  return false;
}

export function parseCourseUnit(input: unknown, summary: CourseUnitSummary): CourseUnit {
  if (!OBJ(input) || input.version !== 1 || input.unitId !== summary.id || input.revision !== summary.revision ||
      !Array.isArray(input.lessons) || input.lessons.length !== summary.lessons.length) fail();
  const exerciseIds = new Set<string>();
  const lessons: Lesson[] = [];
  for (let i = 0; i < input.lessons.length; i++) {
    const entry = input.lessons[i];
    const expected = summary.lessons[i];
    if (!OBJ(entry) || !expected || entry.id !== expected.id || entry.title !== expected.title || entry.subtitle !== expected.subtitle ||
        entry.unit !== summary.order || !Array.isArray(entry.exercises) || entry.exercises.length !== expected.exerciseCount) fail();
    if (entry.exercises.every((ex: unknown) => OBJ(ex) && ex.type === 'info')) fail();
    for (const ex of entry.exercises) {
      if (!validateExercise(ex) || exerciseIds.has(ex.id)) fail();
      exerciseIds.add(ex.id);
    }
    lessons.push(entry as unknown as Lesson);
  }
  return { version: 1, unitId: summary.id, revision: summary.revision, lessons } as CourseUnit;
}
export function unitObjectKey(unit: Pick<CourseUnitSummary, 'id' | 'revision'>): string {
  if (!UNIT_ID.test(unit.id) || !INTEGER(unit.revision, 1, 99999)) fail();
  return `courses/v1/units/${unit.id}-r${unit.revision}.json`;
}
