/** Modelos de exercício do Lunivo, independentes de React Native. */
export type BaseExercise = { id: string; prompt: string; instruction: string; explanation: string };
export type ChoiceOption = { id: string; label: string };
export type ChoiceExercise = BaseExercise & {
  type: 'choice'; options: readonly ChoiceOption[]; correctOptionId: string;
};
export type WriteExercise = BaseExercise & {
  type: 'write'; acceptedAnswers: readonly string[]; sampleAnswer: string;
};
export type ListenChoiceExercise = BaseExercise & {
  type: 'listen_choice'; audioExerciseId: string;
  options: readonly ChoiceOption[]; correctOptionId: string;
};
export type ListenWriteExercise = BaseExercise & {
  type: 'listen_write'; audioExerciseId: string;
  acceptedAnswers: readonly string[]; sampleAnswer: string;
};
export type MatchExercise = BaseExercise & {
  type: 'match'; pairs: readonly { id: string; left: string; right: string }[];
};
/** Tela instrutiva: não exige resposta e não gera XP adicional. */
export type InfoExercise = BaseExercise & {
  type: 'info';
  category?: 'vocabulary' | 'culture' | 'grammar' | 'tip';
  image?: { url: string; alt: string; caption?: string };
};
export type Exercise = ChoiceExercise | WriteExercise | ListenChoiceExercise | ListenWriteExercise | MatchExercise | InfoExercise;
export type Lesson = { id: string; title: string; subtitle: string; unit: number; exercises: readonly Exercise[] };
export function isListeningExercise(exercise: Exercise): exercise is ListenChoiceExercise | ListenWriteExercise {
  return exercise.type === 'listen_choice' || exercise.type === 'listen_write';
}
export function isChoiceExercise(exercise: Exercise): exercise is ChoiceExercise | ListenChoiceExercise {
  return exercise.type === 'choice' || exercise.type === 'listen_choice';
}
export function isWriteExercise(exercise: Exercise): exercise is WriteExercise | ListenWriteExercise {
  return exercise.type === 'write' || exercise.type === 'listen_write';
}
