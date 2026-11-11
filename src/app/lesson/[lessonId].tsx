import { AudioPracticeView } from '../../components/AudioPracticeView';
import { ExerciseVideoView } from '../../components/ExerciseVideoView';
import { CourseGate } from '../../components/CourseGate';
import { contentDirection } from '../../features/vocabulary/review';
import { router, useLocalSearchParams, type ErrorBoundaryProps } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import { LearningText as Text } from '../../components/LearningText';
import {
  Alert, Animated, Easing, Keyboard, KeyboardAvoidingView, Pressable,
  ScrollView, StyleSheet, TextInput, View,
} from 'react-native';
import { LessonSkeleton } from '../../components/ui/Skeleton';
import { ActionButton } from '../../components/ActionButton';
import { AnimatedInstructionCue } from '../../components/AnimatedInstructionCue';
import { InfoContent, RichText } from '../../components/InfoContent';
import { answerFxStyle, ComboChip, FeedbackBadge, FeedbackPanel, ScreenFlash } from '../../components/FeedbackFx';
import { InfoPicture } from '../../components/InfoPicture';
import { LetterBank } from '../../components/LetterBank';
import { canUseLetterBank } from '../../features/learning/letterBank';
import { WordBank } from '../../components/WordBank';
import { canUseWordBank } from '../../features/learning/wordBank';
import { MatchBoard } from '../../components/MatchBoard';
import { ConversationExerciseView } from '../../components/ConversationExercise';
import { lessonGradedCount, lessonScoringTotal } from '../../features/learning/conversation';
import { SpeakExerciseView, SpeechSkipSheet, type SpeechSkipChoice } from '../../components/SpeakExercise';
import { PicturesExerciseView, type PicturesResult } from '../../components/PicturesExercise';
import { pictureSceneKey, pictureUrl } from '../../features/learning/pictures';
import type { PictureWord } from '../../features/learning/types';
import { withoutSpeak, type SpeechGrade } from '../../features/learning/speech';
import { useOnboarding } from '../../features/onboarding/OnboardingProvider';
import { speechActive } from '../../features/onboarding/model';
import { PremiumLoopAura } from '../../components/PremiumLoopAura';
import { Page } from '../../components/Page';
import { ProgressBar } from '../../components/ProgressBar';
import { LinearGradient } from 'expo-linear-gradient';
import { CTAButton, IconButton } from '../../components/ui/Buttons';
import { Icon } from '../../components/ui/Icon';
import { Scene } from '../../components/ui/Scene';
import { useSceneImage } from '../../features/covers/useScene';
import { useCovers } from '../../features/covers/CoverProvider';
import { infoSceneKey } from '../../features/covers/sceneSlots';
import { fonts, palette, sizes } from '../../constants/theme';
import { ExercisePronunciation } from '../../features/audio/ExercisePronunciation';
import { useFeedbackSounds } from '../../features/audio/useFeedbackSounds';
import { useCourses } from '../../features/courses/CourseProvider';
import { asksForStudiedLanguage, courseInfo, courseOfLesson, freeLessonIds, levelOfLesson, orderedIdsForLesson } from '../../features/courses/registry';
import { applyLessonVariant } from '../../features/courses/schema';
import { AudioLocaleProvider } from '../../features/audio/AudioLocale';
import { useActiveCourse } from '../../features/courses/useActiveCourse';
import { localInfoImageSource } from '../../features/courses/localInfoImage';
import type { Lesson, UsageNote } from '../../features/learning/types';
import { correctAnswerLabel, evaluateExercise } from '../../features/learning/engine';
import { assessmentOutcome } from '../../features/learning/assessment';
import { isChoiceExercise, isListeningExercise, isWriteExercise } from '../../features/learning/types';
import { hintFor } from '../../features/learning/hint';
import { canStartLesson } from '../../features/progress/logic';
import { useProgress } from '../../features/progress/ProgressProvider';
import { computeStreak, daysFromLegacy, localStudyDay } from '../../features/progress/streak';
import { wordsForExercise } from '../../features/vocabulary/logic';
import { useAuth } from '../../features/auth/AuthProvider';
import { useLives } from '../../features/lives/LivesProvider';
import { useLeague } from '../../features/leagues/LeagueProvider';
import { MAX_HALVES, lessonNeedsAccount, lessonUsesServerLives, makeAttemptId, mistakeId } from '../../features/lives/model';
import { AccountGate } from '../../components/lives/AccountGate';
import { LifeHearts } from '../../components/lives/LifeHearts';
import { LivesSheet } from '../../components/lives/LivesSheet';
import { PracticeRestore } from '../../components/lives/PracticeRestore';
import { RouteErrorScreen, SafeBoundary, SafeNotice } from '../../components/SafeBoundary';
import { guarded, recordCrash, setCrashContext } from '../../features/diagnostics/crashLog';

export default function LessonScreen() {
  const { lessonId } = useLocalSearchParams<{ lessonId: string }>();
  return <CourseGate courseId={(lessonId ?? '').slice(0, 2)}><LessonContent /></CourseGate>;
}
/** V51: um erro na lição mostra esta tela em vez de fechar o app (o progresso salvo continua). */
export function ErrorBoundary(props: ErrorBoundaryProps) {
  return <RouteErrorScreen {...props} where="lição" title="A lição encontrou um problema" />;
}
function LessonContent() {
  const { lessonId } = useLocalSearchParams<{ lessonId: string }>();
  const { progress, ready, completeLesson, recordVocabulary } = useProgress();
  const { loadLesson, catalog, imageUri } = useCourses();
  // V43: cada curso tem a própria sequência (uma lição de inglês nunca trava o italiano).
  const course = courseInfo(courseOfLesson(lessonId ?? ''));
  // V44: o cartão da pergunta e as imagens das explicações são trocáveis no painel /admin (por curso).
  const lessonCardScene = useSceneImage('lesson-card', course.id);
  const assessmentCardScene = useSceneImage('assessment-card', course.id);
  const { sceneFor } = useCovers();
  // V44: variante do curso desta lição (inglês britânico ou americano): áudios e palavras.
  const { variantFor } = useActiveCourse();
  const variant = variantFor(course.id);
  const variantRef = useRef(variant.id);
  variantRef.current = variant.id;
  // V44: exercícios de fala. Desligados (Perfil) ou pausados ("Não posso falar agora") saem da lição.
  const { settings, setSpeech } = useOnboarding();
  const speechOnRef = useRef(speechActive(settings?.speech));
  speechOnRef.current = speechActive(settings?.speech);
  const courseOrder = useMemo(() => orderedIdsForLesson(catalog, lessonId ?? ''), [catalog, lessonId]);
  const freeLessons = useMemo(() => freeLessonIds(catalog), [catalog]);
  const [resolved, setResolved] = useState<Lesson | undefined>();
  const loaderRef = useRef(loadLesson);
  loaderRef.current = loadLesson;
  const [loadError, setLoadError] = useState(false);
  const lesson = resolved?.id === lessonId ? resolved : undefined;
  const [index, setIndex] = useState(0);
  const [answer, setAnswer] = useState('');
  const [checked, setChecked] = useState(false);
  const [correct, setCorrect] = useState(false);
  const [spellingCorrection, setSpellingCorrection] = useState<string | null>(null);
  const [usageSuggestion, setUsageSuggestion] = useState<Pick<UsageNote, 'preferred' | 'explanation'> | null>(null);
  const [count, setCount] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [audioReady, setAudioReady] = useState(false);
  const [audioUnavailable, setAudioUnavailable] = useState(false);
  const [audioTakingLong, setAudioTakingLong] = useState(false);
  const [skipped, setSkipped] = useState(false);
  // V44: fala pulada não pontua e não entra no total (desligar a fala nunca reprova uma avaliação).
  const [speakSkipped, setSpeakSkipped] = useState(0);
  const [speakSheet, setSpeakSheet] = useState(false);
  // V45: "Imagem e palavra" — trava a rolagem enquanto o aluno arrasta a imagem.
  const [dragging, setDragging] = useState(false);
  const [picturesResult, setPicturesResult] = useState<PicturesResult | null>(null);
  // 'bank': peças para tocar (palavras se a resposta for uma frase; letras se for uma palavra só).
  // V40: é o modo padrão; o teclado fica como opção ao lado. Respostas longas demais para peças
  // (mais de 12 palavras ou 42 letras) continuam no teclado automaticamente.
  const [inputMode, setInputMode] = useState<'keyboard' | 'bank'>('bank');
  const [infoImageError, setInfoImageError] = useState(false);
  // V51: questão que não pôde ser exibida/corrigida (chave lição:índice). A lição segue com "Pular questão".
  const [brokenKey, setBrokenKey] = useState<string | null>(null);
  const scrollRef = useRef<ScrollView | null>(null);
  const playedFeedback = useRef<string | null>(null);
  const playFeedback = useFeedbackSounds();
  // Acertos seguidos: o som de acerto sobe de tom e aparece o selo “N seguidas”.
  const [combo, setCombo] = useState(0);
  const [flashKey, setFlashKey] = useState(0);
  const pulse = useRef(new Animated.Value(0)).current;
  const shake = useRef(new Animated.Value(0)).current;
  // V41: vidas. Sem conta (só unidade 1) = treino livre (vidas locais que se restauram ao zerar);
  // unidade 2+ = conta obrigatória e vidas do servidor (meia-noite de Brasília, anúncio ou Premium).
  // V47: com conta, a unidade 1 também usa as vidas da conta (as mesmas mostradas na Home).
  const { user, ready: authReady } = useAuth();
  const lives = useLives();
  // V52: refazer uma lição já concluída também conta na liga da semana (até 30 XP).
  const league = useLeague();
  const [attemptId] = useState(() => makeAttemptId());
  const [practiceHalves, setPracticeHalves] = useState(MAX_HALVES);
  const [livesSheet, setLivesSheet] = useState(false);
  const [restoreOpen, setRestoreOpen] = useState(false);
  const startChecked = useRef(false);
  const serverLives = Boolean(lessonId) && lessonUsesServerLives(lessonId ?? '', freeLessons, Boolean(user));
  const unlimited = lives.unlimited;
  const halves = unlimited ? MAX_HALVES : serverLives ? lives.halves : practiceHalves;
  const outOfLives = !unlimited && halves === 0;

  // Abriu a lição já sem vidas (com conta, em qualquer unidade): a folha aparece antes da primeira questão.
  useEffect(() => {
    if (startChecked.current || !resolved || resolved.id !== lessonId || !serverLives || !user || !lives.ready || lives.syncing) return;
    startChecked.current = true;
    // Se a meia-noite já passou, o servidor recarrega em instantes: não assusta com a folha.
    if (!lives.unlimited && lives.halves === 0 && (lives.msToReset() ?? 1) > 0) setLivesSheet(true);
  }, [resolved, lessonId, serverLives, user, lives]);

  useEffect(() => {
    if (!lessonId) return;
    let active = true;
    setResolved(undefined);
    setLoadError(false);
    // Resolve the lesson BEFORE showing its first exercise. This avoids inserting
    // remote info mid-session and shifting index / XP / question count.
    // V44: aplica as palavras da variante escolhida (ex.: inglês americano) uma vez, ao abrir.
    void loaderRef.current(lessonId).then(l => {
      if (!active) return;
      const lesson = applyLessonVariant(l, variantRef.current);
      setResolved(speechOnRef.current ? lesson : withoutSpeak(lesson));
    })
      .catch(() => { if (active) setLoadError(true); });
    return () => { active = false; };
  }, [lessonId]);

  // Sons e animações somente depois de verificar; nunca ao escolher uma alternativa ou par.
  useEffect(() => {
    if (!checked || skipped) return;
    const questionKey = `${lessonId ?? ''}:${index}`;
    if (playedFeedback.current === questionKey) return;
    playedFeedback.current = questionKey;
    // V51: som e animação são enfeites: uma falha aqui é registrada e nunca fecha a lição.
    try { playFeedback(correct, combo); } catch (error) { recordCrash('handler', error, 'lição · som da correção'); }
    setFlashKey(k => k + 1);
    try {
      // Acerto: a resposta cresce e volta. Erro: a resposta dá uma tremida.
      const value = correct ? pulse : shake;
      value.setValue(0);
      Animated.timing(value, { toValue: 1, duration: correct ? 520 : 480, easing: correct ? Easing.out(Easing.quad) : Easing.linear, useNativeDriver: true }).start();
    } catch (error) { recordCrash('handler', error, 'lição · animação da correção'); }
  }, [checked, skipped, correct, combo, index, lessonId, playFeedback, pulse, shake]);

  // A correção pode estar fora da área visível, especialmente após fechar o teclado.
  // Rola novamente depois da animação de fechamento do teclado no Android/iOS.
  useEffect(() => {
    if (!checked) return;
    const first = setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 80);
    const second = setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 300);
    return () => { clearTimeout(first); clearTimeout(second); };
  }, [checked, index]);

  // V57: com o teclado aberto, a caixa de resposta fica à vista (no Android de tela cheia o teclado
  // não encolhe a tela sozinho). A lição sobe com o teclado e a rolagem vai até a caixa.
  const typingRef = useRef(false);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const sub = Keyboard.addListener('keyboardDidShow', () => {
      if (!typingRef.current) return;
      clearTimeout(timer);
      timer = setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 80);
    });
    return () => { clearTimeout(timer); sub.remove(); };
  }, []);
  // V57: dica usada nesta questão (uma vez por questão).
  const [hintKey, setHintKey] = useState<string | null>(null);

  // Não exponha falha de rede durante o carregamento normal nem durante seekTo.
  // Após uma espera prolongada, permite seguir sem áudio caso o download trave.
  useEffect(() => {
    setAudioTakingLong(false);
    if (audioReady || checked) return;
    const timer = setTimeout(() => setAudioTakingLong(true), 12000);
    return () => clearTimeout(timer);
  }, [audioReady, checked, index]);

  // V60: esqueleto da lição (barra, enunciado e alternativas) no lugar do círculo girando.
  if (!ready) return <Page><LessonSkeleton /></Page>;
  if (lessonId && lessonNeedsAccount(lessonId, freeLessons) && authReady && !user) return <Page><AccountGate /></Page>;
  if (!lesson && lessonId && !loadError) return <Page><LessonSkeleton /></Page>;
  if (!lesson || !canStartLesson(lesson.id, courseOrder, progress)) return <Page><View style={styles.missing}>
    <View style={styles.missingIcon}><Icon name={loadError ? 'cloud' : 'lock'} size={30} color={palette.sky} /></View>
    <Text style={styles.errorTitle}>{loadError ? 'Lição indisponível offline' : 'Lição indisponível'}</Text>
    <Text style={styles.message}>Se a unidade não foi baixada, conecte-se à internet para abrir a lição.</Text>
    <ActionButton title="Voltar ao início" onPress={() => router.dismissTo('/')} />
  </View></Page>;

  const question = lesson.exercises[index];
  if (!question) return null;
  const exerciseKey = `${lesson.id}:${index}`;
  const broken = brokenKey === exerciseKey;
  const markBroken = () => setBrokenKey(exerciseKey);
  // V51: se algo der errado, o relatório diz exatamente em que questão o aluno estava.
  setCrashContext(`lição ${lesson.id} · questão ${index + 1}/${lesson.exercises.length} (${question.id}, ${question.type})${checked ? ' · corrigida' : ''}`);
  const studiedTodayBefore = computeStreak(daysFromLegacy(progress.lastStudiedAt, progress.studyDays), localStudyDay(new Date())).studiedToday;
  const listening = isListeningExercise(question);
  const choice = isChoiceExercise(question);
  const writing = isWriteExercise(question);
  // V44: "Escreva em italiano/inglês": ouvir antes entregaria a resposta. O áudio só aparece
  // depois que o aluno tenta (verificar).
  const audioAfterAnswer = question.type === 'write' && asksForStudiedLanguage(question.instruction);
  const practice = question.type === 'shadowing' || question.type === 'listening';
  const informative = question.type === 'info' || practice;
  const wordsMode = writing && canUseWordBank(question.sampleAnswer);
  const bankAvailable = writing && (wordsMode || canUseLetterBank(question.sampleAnswer));
  // É possível desfazer e refazer pares; a avaliação só acontece após todos serem ligados.
  const matchReady = question.type !== 'match' || answer.split('|').filter(Boolean).length === question.pairs.length;
  const selfChecked = question.type === 'conversation' || question.type === 'speak' || question.type === 'pictures';
  const canVerify = !selfChecked && answer.trim().length > 0 && matchReady && (!listening || audioReady);
  // V57: digitando (só teclado, ou o aluno escolheu o teclado): botão "Dica", uma vez por questão.
  const typing = writing && !checked && (!bankAvailable || inputMode === 'keyboard');
  typingRef.current = typing;
  const hint = writing ? hintFor(question, course.id) : null;
  const hintUsed = hintKey === exerciseKey;

  // Meia vida por erro. Premium não perde; sem conta (unidade 1), perde só no treino local.
  const loseHalves = (ids: string[]) => {
    if (!ids.length || unlimited) return;
    if (serverLives) lives.recordMistakes(lesson.id, ids);
    else setPracticeHalves(h => Math.max(0, h - ids.length));
  };
  const finishConversation = (points: number, total: number) => {
    if (checked || question.type !== 'conversation') return;
    // Pontos por pausa respondida, evitando punir toda a conversa por um erro.
    // Cada resposta errada na conversa custa meia vida.
    loseHalves(Array.from({ length: Math.max(0, total - points) }, (_, k) => mistakeId(attemptId, question.id, k)));
    setCorrect(points > 0);
    setCombo(c => (points === total ? c + 1 : 0));
    setChecked(true);
    setCount(c => c + points);
  };
  // V44: fala: errar a pronúncia não custa vida (o microfone falha, o sotaque varia).
  const finishSpeak = (grade: SpeechGrade) => {
    if (checked || question.type !== 'speak') return;
    setCorrect(grade.correct);
    setChecked(true);
    setCombo(c => (grade.correct ? c + 1 : 0));
    if (grade.correct) setCount(c => c + 1);
    void recordVocabulary(wordsForExercise(lesson.id, question), grade.correct)
      .catch(e => console.warn('Vocabulário não salvo:', e));
  };
  // V45: imagem e palavra. Errar não tira vida; vale o ponto se errar no máximo metade das palavras.
  const finishPictures = (result: PicturesResult) => {
    if (checked || question.type !== 'pictures') return;
    setPicturesResult(result);
    setCorrect(result.passed);
    setChecked(true);
    setCombo(c => (result.passed ? c + 1 : 0));
    if (result.passed) setCount(c => c + 1);
    const words = wordsForExercise(lesson.id, question);
    const missed = new Set(question.words.filter(w => result.missed.includes(w.id)).map(w => w.term));
    const good = words.filter(w => !missed.has(w.term));
    const bad = words.filter(w => missed.has(w.term));
    if (good.length) void recordVocabulary(good, true).catch(e => console.warn('Vocabulário não salvo:', e));
    if (bad.length) void recordVocabulary(bad, false).catch(e => console.warn('Vocabulário não salvo:', e));
  };
  const pictureFor = (word: PictureWord) => sceneFor(pictureSceneKey(question.id, word.id)) ?? { uri: imageUri(lesson.id, pictureUrl(word.image)) };
  const skipSpeak = (choice: SpeechSkipChoice) => {
    if (checked || question.type !== 'speak') return;
    setSpeakSkipped(n => n + 1);
    setSkipped(true); setCorrect(false); setChecked(true);
    if (choice === 'once') return;
    void setSpeech(choice === 'hour'
      ? { enabled: true, pausedUntil: new Date(Date.now() + 60 * 60 * 1000).toISOString() }
      : { enabled: false, pausedUntil: null });
    // As próximas falas desta lição saem agora (a atual continua no lugar: o índice não muda).
    setResolved(current => (current ? withoutSpeak(current, index + 1) : current));
  };
  const verify = () => {
    if (checked || !canVerify) return;
    Keyboard.dismiss();
    // Única avaliação para XP, ortografia e uso idiomático.
    const result = evaluateExercise(question, answer);
    const right = result.correct;
    setCorrect(right);
    setSpellingCorrection(result.spellingCorrection);
    setUsageSuggestion(result.usageSuggestion ?? null);
    setChecked(true);
    setCombo(c => (right ? c + 1 : 0));
    if (right) setCount(c => c + 1);
    else loseHalves([mistakeId(attemptId, question.id)]);
    // Cada questão reforça ou enfraquece o vocabulário correspondente.
    // Associações parcialmente corretas não penalizam todas as palavras do conjunto.
    if (question.type !== 'match' || right) {
      void recordVocabulary(wordsForExercise(lesson.id, question), right)
        .catch(e => console.warn('Vocabulário não salvo:', e));
    }
  };
  const next = async () => {
    if (submitting) return;
    if (question.type === 'info') {
      // A etapa instrutiva registra exposição, mas não concede XP nem altera a streak.
      try { await recordVocabulary(wordsForExercise(lesson.id, question), true); }
      catch (e) { console.warn('Vocabulário não salvo:', e); }
    }
    if (index < lesson.exercises.length - 1) {
      setIndex(v => v + 1);
      setAnswer(''); setChecked(false); setCorrect(false); setSpellingCorrection(null); setUsageSuggestion(null);
      setAudioReady(false); setAudioUnavailable(false); setAudioTakingLong(false); setSkipped(false); setInputMode('bank'); setInfoImageError(false);
      setPicturesResult(null); setDragging(false);
      scrollRef.current?.scrollTo({ y: 0, animated: false });
      return;
    }
    setSubmitting(true);
    try {
      // A prova não pode conceder XP, alterar streak nem liberar o módulo seguinte sem aprovação.
      // V44: exercícios de fala pulados ou desligados não entram no total.
      const infoOnly = lesson.exercises.every(ex => ex.type === 'info' || ex.type === 'shadowing' || ex.type === 'listening');
      // Mantém a pontuação anterior das lições mistas, mas informações puras têm total zero.
      const assessmentTotal = Math.max(1, lessonScoringTotal(lesson) - speakSkipped);
      const finalTotal = infoOnly ? 0 : assessmentTotal;
      const graded = String(infoOnly ? 0 : Math.max(1, lessonGradedCount(lesson) - speakSkipped));
      if (lesson.assessment && !assessmentOutcome(count, assessmentTotal, lesson.assessment.passPercent).passed) {
        router.replace({ pathname: '/result', params: { lessonId: lesson.id, correct: String(count), xp: '0',
          assessmentPassed: '0', streakCelebration: '0', graded } });
        return;
      }
      const alreadyDone = progress.completedLessonIds.includes(lesson.id);
      const xp = await completeLesson(lesson.id, count, finalTotal);
      if (alreadyDone && !infoOnly) {
        try { league.recordPractice(attemptId, count, finalTotal); } catch { /* a liga nunca impede a conclusão */ }
      }
      router.replace({ pathname: '/result', params: { lessonId: lesson.id, correct: String(count), xp: String(xp), graded,
        assessmentPassed: lesson.assessment ? '1' : '',
        streakCelebration: studiedTodayBefore ? '0' : '1' } });
    } catch {
      Alert.alert('Não foi possível salvar', 'Tente novamente para preservar seu progresso.');
      setSubmitting(false);
    }
  };

  const audioExerciseId = listening ? question.audioExerciseId : question.id;
  const exerciseHint = practice ? 'Ouça e acompanhe o texto. Pratique no seu ritmo.' : informative ? 'Leia com atenção antes de continuar.' : question.type === 'pictures' ? 'Conheça as palavras pelas imagens e depois arraste cada imagem até a palavra certa.' : question.type === 'speak' ? 'Ouça, toque no microfone e diga a frase em voz alta.' : question.type === 'conversation' ? 'Acompanhe o diálogo e escolha suas respostas quando a conversa parar.' : question.type === 'match' ? 'Relacione as expressões nas duas colunas.'
    : choice ? 'Escolha a alternativa que faz sentido.'
    : inputMode === 'bank' && bankAvailable ? (wordsMode ? 'Toque nas palavras para montar a frase.' : 'Toque nas letras para montar a palavra.')
    : 'Escreva sua resposta no campo abaixo.';
  const infoCategory = practice ? (question.type === 'shadowing' ? 'SHADOWING' : 'LISTENING') : question.type === 'info' ? ({ vocabulary: 'NOVA PALAVRA', culture: 'CULTURA E CONTEXTO', grammar: 'ENTENDA A GRAMÁTICA', tip: 'DICA DE APRENDIZADO' } as const)[question.category ?? 'tip'] : '';
  const speaking = question.type === 'speak';
  const picturing = question.type === 'pictures';
  const feedbackTitle = picturing ? (correct ? 'Palavras associadas!' : 'Vamos reforçar essas palavras') : skipped ? (speaking ? 'Exercício de fala pulado' : 'Atividade pulada') : speaking ? (correct ? 'Pronúncia aprovada!' : 'Quase lá! Continue treinando a fala.') : correct ? (usageSuggestion ? `Resposta aceita! Uma dica de ${course.adjective}.` : spellingCorrection ? 'Correto! Ajuste a escrita.' : 'Resposta correta!') : 'Vamos aprender com essa resposta';

  // "Para na hora": sem vidas, o Continuar abre as opções (anúncio, Premium ou sair).
  // Sem conta (treino livre da unidade 1), as vidas se restauram com animação e a lição segue.
  const proceed = () => {
    if (outOfLives && serverLives) { setLivesSheet(true); return; }
    if (outOfLives) { setRestoreOpen(true); return; }
    void next();
  };
  // V51: toques protegidos. Um erro aqui não chega ao React Native (que fecharia o app): fica
  // registrado e a questão mostra "Pular questão".
  const safeVerify = guarded('verificar', verify, markBroken);
  const safeProceed = guarded('continuar', proceed, markBroken);
  const safeFinishConversation = guarded('fim da conversa', finishConversation, markBroken);
  const safeFinishSpeak = guarded('fim da fala', finishSpeak, markBroken);
  const safeFinishPictures = guarded('fim de imagem e palavra', finishPictures, markBroken);
  const safeSkipSpeak = guarded('pular fala', skipSpeak, markBroken);
  // Questão quebrada: segue para a próxima sem pontuar (a lição continua, o app não fecha).
  const skipBroken = guarded('pular questão com erro', () => { setBrokenKey(null); void next(); });
  const lastStep = index === lesson.exercises.length - 1;
  const actionDisabled = submitting || (!informative && !checked && !canVerify);
  const actionLabel = submitting ? 'Salvando...' : informative ? (lastStep ? 'Concluir lição' : 'Entendi, continuar') : !checked ? 'Verificar resposta' : lastStep ? 'Concluir lição' : 'Continuar';

  return <AudioLocaleProvider value={variant.id}><Page><KeyboardAvoidingView behavior="padding" style={styles.layout}>
    <View style={styles.header}>
      <View style={styles.headerTop}>
        <IconButton icon="close" size={42} accessibilityLabel="Sair da lição" onPress={() => router.back()} />
        <View style={styles.headerLabel}>
          <Text style={styles.headerEyebrow}>{lesson.assessment ? `AVALIAÇÃO FINAL · ${levelOfLesson(lesson.id)}` : `${course.upper} · ${levelOfLesson(lesson.id)}`}</Text>
          <Text style={styles.headerTitle} numberOfLines={1}>{lesson.title}</Text>
        </View>
        <View style={styles.counterPill}>
          <Text style={styles.counter}>{index + 1}<Text style={styles.counterMuted}>/{lesson.exercises.length}</Text></Text>
        </View>
      </View>
      <View style={styles.progressRow}>
        <View style={styles.progressTrack}><ProgressBar value={(index + (checked ? 1 : 0)) / lesson.exercises.length} /></View>
        <View style={[styles.livesPill, outOfLives && styles.livesPillEmpty]}>
          <LifeHearts halves={halves} unlimited={unlimited} size={17} gap={2} />
        </View>
      </View>
    </View>

    <ScrollView ref={scrollRef} keyboardShouldPersistTaps="handled" scrollEnabled={!dragging}
      showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}
      onContentSizeChange={() => { if (checked) scrollRef.current?.scrollToEnd({ animated: true }); }}>
      {/* V51: se a questão não puder ser desenhada (antes ou depois de verificar), só ela é trocada por
          um aviso; a lição e o app continuam abertos. */}
      {broken ? <SafeNotice title="Esta questão teve um problema"
        body="Seu progresso está salvo. Toque em “Pular questão” para continuar a lição; esta questão não conta pontos." />
      : <SafeBoundary where={`lição ${lesson.id} · questão ${index + 1} (${question.id}, ${question.type})${checked ? ' · corrigida' : ''}`}
        resetKey={exerciseKey} onError={markBroken} fallback={() => null}>
      <View style={styles.promptCard}>
        <LinearGradient pointerEvents="none" colors={['rgba(56,104,170,0.5)', 'rgba(16,40,74,0)', 'rgba(16,40,74,0)']}
          locations={[0, 0.55, 1]} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }} style={StyleSheet.absoluteFill} />
        <Scene source={lesson.assessment ? assessmentCardScene : lessonCardScene} left={0.6} bottom={0.5} opacity={0.55} style={styles.promptScene} />
        <PremiumLoopAura variant="lesson" opacity={1} />
        <Text style={styles.cardEyebrow}>{informative ? infoCategory : `QUESTÃO ${String(index + 1).padStart(2, '0')}  ·  ${question.instruction.toUpperCase()}`}</Text>
        <AnimatedInstructionCue key={`${question.id}:${question.instruction}`} text={informative ? infoCategory : question.instruction} />
        <Text style={[styles.prompt, contentDirection(question.prompt) === 'rtl' && { writingDirection: 'rtl', fontFamily: undefined }]}>{question.prompt}</Text>
        <Text style={styles.cardHint}>{exerciseHint}</Text>
      </View>

      {question.video && <ExerciseVideoView key={question.id + '-video'} video={question.video} />}
      {practice && <AudioPracticeView key={question.id} exercise={question} />}
      {question.type === 'info' && <View style={styles.infoSection}>
        {question.image && <View style={styles.infoImageCard}>
          {!infoImageError ? <InfoPicture source={sceneFor(infoSceneKey(question.id)) ?? localInfoImageSource(question.image.url) ?? { uri: imageUri(lesson.id, question.image.url) }}
            label={question.image.alt} onError={() => setInfoImageError(true)} />
            : <View style={styles.infoImageFallback}><Text style={styles.infoImageFallbackText}>Imagem não disponível. O conteúdo continua abaixo.</Text></View>}
          {question.image.caption && <Text style={styles.infoCaption}>{question.image.caption}</Text>}
        </View>}
        <InfoContent key={question.id} exercise={question} />
        <Text style={styles.infoContinueNote}>Nenhuma resposta necessária nesta etapa.</Text>
      </View>}

      {/* V44b: com áudio publicado, "Escreva em inglês" mostra o aviso e o áudio só depois de verificar;
          sem gravação para este exercício, nada aparece (nem a promessa de áudio). */}
      {!informative && question.type !== 'conversation' && question.type !== 'pictures' && <ExercisePronunciation key={question.id} exerciseId={audioExerciseId}
        locked={audioAfterAnswer && !checked}
        concealText={listening && !checked} onReadyChange={listening ? setAudioReady : undefined}
        onUnavailableChange={listening ? setAudioUnavailable : undefined} />}

      <Animated.View style={answerFxStyle(pulse, shake)}>
      {choice && <View style={styles.choices}>
        <Text style={styles.sectionLabel}>SUA RESPOSTA</Text>
        {question.options.map((option, i) => {
          const chosen = answer === option.id;
          const showRight = checked && option.id === question.correctOptionId;
          const showWrong = checked && chosen && !showRight;
          return <Pressable key={option.id} accessibilityRole="button"
            accessibilityState={{ selected: chosen, disabled: checked }}
            accessibilityLabel={`Opção ${i + 1}: ${option.label}${checked && showRight ? ', correta' : checked && showWrong ? ', incorreta' : ''}`}
            disabled={checked} onPress={() => setAnswer(option.id)}
            style={({ pressed }) => [styles.choice, chosen && !checked && styles.selected,
              showRight && styles.rightChoice, showWrong && styles.wrongChoice, pressed && styles.pressed]}>
            <View style={[styles.optionNo, chosen && !checked && styles.numberSelected,
              showRight && styles.numberRight, showWrong && styles.numberWrong]}>
              {showRight ? <Icon name="check" size={18} color="#05291E" strokeWidth={2.8} />
                : showWrong ? <Icon name="close" size={17} color="#FFFFFF" strokeWidth={2.6} />
                : <Text style={[styles.optionNoText, chosen && styles.numberDark]}>{i + 1}</Text>}
            </View>
            <Text style={[styles.optionText, showRight && styles.rightText, showWrong && styles.wrongText]}>{option.label}</Text>
          </Pressable>;
        })}
      </View>}

      {writing && <View style={styles.writeSection}>
        <View style={styles.writeHeader}>
          <Text style={[styles.sectionLabel, styles.sectionLabelInline]}>SUA RESPOSTA</Text>
          {bankAvailable && !checked && <View style={styles.modeSwitcher}>
            <Pressable accessibilityRole="button"
              accessibilityLabel={wordsMode ? 'Responder tocando em palavras embaralhadas' : 'Responder tocando em letras embaralhadas'}
              accessibilityState={{ selected: inputMode === 'bank' }}
              onPress={() => { if (inputMode !== 'bank') { Keyboard.dismiss(); setAnswer(''); setInputMode('bank'); } }}
              style={[styles.modeChoice, inputMode === 'bank' && styles.modeActive]}>
              <Icon name="grid" size={15} color={inputMode === 'bank' ? palette.ink : palette.muted} strokeWidth={2} />
              <Text style={[styles.modeText, inputMode === 'bank' && styles.modeActiveText]}>{wordsMode ? 'Palavras' : 'Letras'}</Text>
            </Pressable>
            <Pressable accessibilityRole="button" accessibilityLabel="Responder digitando no teclado"
              accessibilityState={{ selected: inputMode === 'keyboard' }}
              onPress={() => { if (inputMode !== 'keyboard') { Keyboard.dismiss(); setAnswer(''); setInputMode('keyboard'); } }}
              style={[styles.modeChoice, inputMode === 'keyboard' && styles.modeActive]}>
              <Icon name="keyboard" size={15} color={inputMode === 'keyboard' ? palette.ink : palette.muted} strokeWidth={2} />
              <Text style={[styles.modeText, inputMode === 'keyboard' && styles.modeActiveText]}>Teclado</Text>
            </Pressable>
          </View>}
        </View>
        {inputMode === 'bank' && bankAvailable ? (wordsMode
          ? <WordBank key={`${question.id}-words`} exercise={question} lesson={lesson.exercises}
            checked={checked} correct={correct} onAnswer={setAnswer} />
          : <LetterBank key={`${question.id}-letters`} sample={question.sampleAnswer} exerciseId={question.id}
            checked={checked} onAnswer={setAnswer} />) :
          <TextInput keyboardAppearance="dark" key={`${question.id}-keyboard`} accessibilityLabel="Sua resposta"
            placeholder={listening ? 'Escreva o que ouviu...' : 'Escreva aqui...'}
            placeholderTextColor={palette.faint} value={answer} onChangeText={setAnswer}
            editable={!checked} autoCapitalize="sentences" autoCorrect={false} selectionColor={palette.sky}
            returnKeyType="done" onFocus={() => setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 350)}
            style={[styles.input, contentDirection(question.sampleAnswer) === 'rtl' && { writingDirection: 'rtl', textAlign: 'right', lineHeight: 36, fontSize: 22 }, checked && (correct ? styles.inputCorrect : styles.inputWrong)]} />}
        {hint && (typing || hintUsed) && (hintUsed
          ? <View style={styles.hintCard} accessibilityLiveRegion="polite">
            <Icon name="bulb" size={17} color={palette.gold} strokeWidth={2} />
            <View style={styles.hintCopy}><Text style={styles.hintLabel}>DICA</Text><Text style={styles.hintText}>{hint}</Text></View>
          </View>
          : <Pressable accessibilityRole="button" accessibilityLabel="Ver uma dica (uma vez nesta questão)"
            onPress={() => setHintKey(exerciseKey)} style={({ pressed }) => [styles.hintButton, pressed && styles.pressed]}>
            <Icon name="bulb" size={16} color={palette.gold} strokeWidth={2} />
            <Text style={styles.hintButtonText}>Dica</Text>
            <Text style={styles.hintButtonNote}>· uma vez</Text>
          </Pressable>)}
        {checked && inputMode === 'bank' && bankAvailable && !wordsMode && <Text style={styles.bankSummary}>Resposta montada: {answer}</Text>}
      </View>}

      {question.type === 'pictures' && <PicturesExerciseView key={question.id} exercise={question} imageFor={pictureFor}
        checked={checked} onFinish={safeFinishPictures} onDragging={setDragging} />}
      {question.type === 'speak' && <SpeakExerciseView key={question.id} exercise={question} locale={variant.id} checked={checked}
        onFinish={safeFinishSpeak} onCantSpeak={() => setSpeakSheet(true)} />}
      {question.type === 'match' && <MatchBoard key={question.id} exercise={question} checked={checked} onAnswer={setAnswer} course={course} flag={variant.flag}
        lesson={lesson.exercises} />}
      </Animated.View>
      {question.type === 'conversation' && <ConversationExerciseView key={question.id} exercise={question}
        onFinish={safeFinishConversation} onAdvance={() => scrollRef.current?.scrollToEnd({ animated: true })} />}

      {listening && !audioReady && (audioUnavailable || audioTakingLong) && !checked && <Text style={styles.audioHint}>
        {audioUnavailable ? 'Esta gravação está indisponível no momento. Verifique a conexão ou continue sem áudio.'
          : 'A gravação está demorando para carregar. Você pode continuar sem áudio se preferir.'}
      </Text>}

      {checked && !informative && question.type !== 'conversation' && <FeedbackPanel key={`fb-${index}`}
        tone={skipped ? 'skip' : correct ? 'good' : 'bad'} style={[styles.feedback,
        skipped ? styles.skippedPanel : correct ? styles.good : styles.bad]}>
        <View style={styles.feedbackTop}>
          <FeedbackBadge tone={skipped ? 'skip' : correct ? 'good' : 'bad'} />
          <View style={styles.feedbackCopy}>
            {!skipped && correct && combo >= 2 && <ComboChip combo={combo} />}
            <Text style={[styles.feedbackTitle, skipped ? styles.skippedTitle : correct ? styles.goodTitle : styles.badTitle]}>{feedbackTitle}</Text>
            <Text style={styles.feedbackStatus}>{picturing && picturesResult ? `Você acertou ${picturesResult.firstTry.length} de ${picturesResult.total} de primeira. Erros aqui não tiram vidas.` : skipped ? (speaking ? 'Não conta no total da lição' : 'Sem pontuação nesta questão') : speaking ? (correct ? 'Muito bem! O reconhecimento entendeu a frase.' : 'Exercícios de fala não tiram vidas.') : correct ? (usageSuggestion ? (spellingCorrection ? 'Você acertou. Confira a grafia e a forma mais natural abaixo.' : 'Você acertou. Veja a expressão mais natural abaixo.') : spellingCorrection ? 'Resposta aceita! Veja a grafia correta abaixo.' : 'Muito bem! Continue avançando.') : 'Confira a resposta e continue praticando.'}</Text>
          </View>
        </View>
        {!skipped && correct && spellingCorrection && <View style={styles.spellingPanel}>
          <Text style={styles.spellingLabel}>GRAFIA CORRETA</Text>
          <Text selectable style={styles.spellingValue}>{spellingCorrection}</Text>
        </View>}
        {!skipped && correct && usageSuggestion && <View style={styles.usagePanel}>
          <Text style={styles.usageLabel}>FORMA MAIS NATURAL</Text>
          <Text selectable style={styles.usageValue}>{usageSuggestion.preferred}</Text>
          <RichText text={usageSuggestion.explanation} style={styles.usageExplanation} strongStyle={styles.feedbackStrong} />
        </View>}
        {!skipped && !correct && <View style={styles.correctAnswer}>
          <Text style={styles.answerLabel}>{speaking ? 'FRASE PARA TREINAR' : picturing ? 'PALAVRAS DESTA ETAPA' : 'RESPOSTA CORRETA'}</Text>
          <Text selectable style={styles.answerText}>{correctAnswerLabel(question)}</Text>
        </View>}
        {/* V44b: *palavra* na explicação vira destaque (antes aparecia o asterisco). */}
        <RichText style={styles.feedbackBody} strongStyle={styles.feedbackStrong} text={skipped
          ? speaking ? 'Tudo bem! Para mudar quando os exercícios de fala aparecem, vá em Perfil › Exercícios de fala.'
            : 'A gravação não estava disponível. Você pode continuar sem ganhar pontos nesta atividade.'
          : question.explanation} />
      </FeedbackPanel>}
      </SafeBoundary>}
    </ScrollView>

    <ScreenFlash tone={skipped ? 'skip' : correct ? 'good' : 'bad'} flashKey={flashKey} />

    <View style={styles.bottom}>
      <LinearGradient pointerEvents="none" colors={['rgba(5,12,24,0)', 'rgba(5,12,24,0.92)']} locations={[0, 0.4]} style={styles.bottomFade} />
      {listening && !audioReady && (audioUnavailable || audioTakingLong) && !checked && <Pressable accessibilityRole="button"
        accessibilityLabel="Pular atividade sem áudio, sem ganhar pontos"
        onPress={() => { Keyboard.dismiss(); setSkipped(true); setCorrect(false); setChecked(true); }}
        style={styles.skip}><Text style={styles.skipText}>Pular atividade sem áudio</Text></Pressable>}
      {broken ? <CTAButton label={submitting ? 'Salvando...' : lastStep ? 'Concluir lição' : 'Pular questão'}
        disabled={submitting} icon="arrowRight" onPress={skipBroken} />
      : (!selfChecked || checked) && <CTAButton label={actionLabel}
        tone={checked && correct && !skipped ? 'success' : 'sky'} disabled={actionDisabled}
        icon={checked && lastStep ? 'check' : 'arrowRight'}
        onPress={checked ? safeProceed : informative ? () => { void next(); } : safeVerify} />}
    </View>

    <LivesSheet visible={livesSheet} mode="empty" exitLabel="Sair da lição"
      onClose={() => setLivesSheet(false)}
      onExit={() => router.back()}
      onRestored={() => { if (checked) void next(); }} />
    <SpeechSkipSheet visible={speakSheet} onClose={() => setSpeakSheet(false)} onChoose={safeSkipSpeak} />
    <PracticeRestore visible={restoreOpen} onContinue={() => {
      setRestoreOpen(false);
      setPracticeHalves(MAX_HALVES);
      void next();
    }} />
  </KeyboardAvoidingView></Page></AudioLocaleProvider>;
}

const PROMPT = '#10284A';
const styles = StyleSheet.create({
  layout: { flex: 1 },
  missing: { flex: 1, justifyContent: 'center', gap: 16, paddingHorizontal: sizes.page },
  missingIcon: { width: 68, height: 68, borderRadius: 22, alignSelf: 'center', alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: palette.lineStrong, backgroundColor: 'rgba(20,46,82,0.6)' },
  errorTitle: { fontSize: 28, fontFamily: fonts.serif, color: palette.text, textAlign: 'center' },
  message: { textAlign: 'center', marginTop: 4, fontSize: 14, color: palette.muted, lineHeight: 21 },
  header: { paddingHorizontal: sizes.page, paddingTop: 6, paddingBottom: 14, gap: 14 },
  progressRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  progressTrack: { flex: 1 },
  livesPill: { flexDirection: 'row', alignItems: 'center', borderRadius: 12, paddingHorizontal: 7, paddingVertical: 4,
    backgroundColor: 'rgba(60,34,56,0.5)', borderWidth: 1, borderColor: 'rgba(255,150,170,0.26)' },
  livesPillEmpty: { borderColor: 'rgba(242,139,142,0.6)', backgroundColor: 'rgba(110,40,56,0.5)' },
  headerTop: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  headerLabel: { flex: 1, gap: 2 },
  headerEyebrow: { fontSize: 11.5, letterSpacing: 1.1, fontWeight: '800', color: palette.gold },
  headerTitle: { color: palette.text, fontFamily: fonts.serifSemi, fontSize: 16 },
  counterPill: { borderRadius: 12, borderWidth: 1, borderColor: palette.line, backgroundColor: 'rgba(20,46,82,0.55)', paddingHorizontal: 10, paddingVertical: 6 },
  counter: { fontSize: 15, fontWeight: '900', color: palette.text },
  counterMuted: { fontSize: 12, fontWeight: '700', color: palette.dim },
  scroll: { flexGrow: 1, paddingHorizontal: sizes.page, paddingTop: 6, paddingBottom: 40 },
  promptCard: { backgroundColor: PROMPT, borderRadius: 26, paddingHorizontal: 20, paddingVertical: 22, overflow: 'hidden', minHeight: 164,
    position: 'relative', borderWidth: 1, borderColor: 'rgba(130,180,240,0.30)', boxShadow: '0px 14px 34px rgba(0,8,24,0.4)' },
  promptScene: { position: 'absolute', top: 0, right: 0, width: '62%', height: 200 },
  cardEyebrow: { color: palette.gold, fontSize: 11.5, fontWeight: '800', letterSpacing: 1.1, lineHeight: 15 },
  prompt: { color: '#FFFFFF', fontFamily: fonts.serif, fontSize: 32, letterSpacing: -0.6, lineHeight: 38, marginTop: 16,
    textShadowColor: 'rgba(0,0,0,0.4)', textShadowRadius: 10 },
  cardHint: { color: '#BCD0E6', fontSize: 13, lineHeight: 19, marginTop: 9 },
  sectionLabel: { color: palette.muted, fontSize: 11.5, fontWeight: '800', letterSpacing: 1.1, marginBottom: 10 },
  sectionLabelInline: { marginBottom: 0 },
  choices: { marginTop: 26, gap: 10 },
  choice: { borderRadius: 18, backgroundColor: 'rgba(16,38,68,0.72)', borderWidth: 1.3, borderColor: 'rgba(138,180,235,0.22)',
    paddingHorizontal: 14, paddingVertical: 11, flexDirection: 'row', gap: 14, alignItems: 'center', minHeight: 62 },
  selected: { borderColor: palette.sky, backgroundColor: 'rgba(52,110,190,0.30)', boxShadow: '0px 0px 16px rgba(110,180,255,0.28)' },
  rightChoice: { borderColor: 'rgba(91,214,164,0.75)', backgroundColor: 'rgba(40,128,98,0.24)' },
  wrongChoice: { borderColor: 'rgba(242,139,142,0.7)', backgroundColor: 'rgba(140,58,72,0.24)' },
  optionNo: { width: 36, height: 36, borderRadius: 12, backgroundColor: 'rgba(140,186,240,0.12)', borderWidth: 1, borderColor: 'rgba(140,186,240,0.22)',
    alignItems: 'center', justifyContent: 'center' },
  numberSelected: { backgroundColor: palette.sky, borderColor: palette.sky },
  numberRight: { backgroundColor: palette.success, borderColor: palette.success },
  numberWrong: { backgroundColor: palette.dangerDeep, borderColor: palette.dangerDeep },
  optionNoText: { color: palette.muted, fontSize: 14.5, fontWeight: '900' },
  numberDark: { color: palette.ink },
  optionText: { fontSize: 16, color: palette.text, fontWeight: '700', flex: 1 },
  rightText: { color: '#A8F0D2' }, wrongText: { color: '#FFC2C4' },
  writeSection: { marginTop: 26 },
  hintButton: { alignSelf: 'flex-start', flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 12, paddingHorizontal: 14, paddingVertical: 9,
    borderRadius: 16, borderWidth: 1, borderColor: 'rgba(241,191,122,0.5)', backgroundColor: 'rgba(70,52,30,0.45)' },
  hintButtonText: { color: palette.gold, fontSize: 14, fontWeight: '800' },
  hintButtonNote: { color: palette.muted, fontSize: 12, fontWeight: '600' },
  hintCard: { flexDirection: 'row', alignItems: 'flex-start', gap: 10, marginTop: 12, paddingHorizontal: 14, paddingVertical: 12,
    borderRadius: 16, borderWidth: 1, borderColor: 'rgba(241,191,122,0.5)', backgroundColor: 'rgba(70,52,30,0.5)' },
  hintCopy: { flex: 1, gap: 2 },
  hintLabel: { color: palette.gold, fontSize: 11.5, fontWeight: '800', letterSpacing: 1.1 },
  hintText: { color: palette.text, fontSize: 15, lineHeight: 21, fontWeight: '600' },
  input: { borderRadius: 18, backgroundColor: 'rgba(12,30,56,0.8)', paddingHorizontal: 18, paddingVertical: 16, minHeight: 62,
    borderColor: 'rgba(140,186,240,0.32)', borderWidth: 1.3, fontSize: 19, color: palette.text, fontWeight: '700' },
  inputCorrect: { borderColor: 'rgba(91,214,164,0.75)', backgroundColor: 'rgba(40,128,98,0.2)' },
  inputWrong: { borderColor: 'rgba(242,139,142,0.7)', backgroundColor: 'rgba(140,58,72,0.2)' },
  audioHint: { color: palette.muted, fontSize: 12, lineHeight: 19, marginTop: 14 },
  feedback: { marginTop: 24, padding: 17, borderRadius: 22, borderWidth: 1 },
  good: { backgroundColor: 'rgba(30,96,76,0.30)', borderColor: 'rgba(91,214,164,0.45)' },
  bad: { backgroundColor: 'rgba(110,44,58,0.30)', borderColor: 'rgba(242,139,142,0.42)' },
  skippedPanel: { backgroundColor: 'rgba(110,84,40,0.28)', borderColor: 'rgba(241,191,122,0.42)' },
  feedbackTop: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  feedbackCopy: { flex: 1, gap: 3 },
  feedbackTitle: { fontFamily: fonts.serif, fontSize: 17.5, lineHeight: 22 },
  goodTitle: { color: '#A8F0D2' }, badTitle: { color: '#FFC2C4' }, skippedTitle: { color: palette.gold },
  feedbackStatus: { color: palette.textSoft, fontSize: 12, lineHeight: 17 },
  spellingPanel: { marginTop: 14, backgroundColor: 'rgba(241,191,122,0.10)', borderColor: 'rgba(241,191,122,0.4)', borderWidth: 1, borderRadius: 14, padding: 13, gap: 5 },
  spellingLabel: { fontSize: 11.5, color: palette.gold, letterSpacing: 1.1, fontWeight: '800' },
  spellingValue: { fontSize: 18, color: palette.text, fontWeight: '800' },
  usagePanel: { marginTop: 14, backgroundColor: 'rgba(140,200,255,0.10)', borderColor: 'rgba(140,200,255,0.36)', borderWidth: 1, borderRadius: 14, padding: 14, gap: 6 },
  usageLabel: { fontSize: 11.5, color: palette.sky, letterSpacing: 1.1, fontWeight: '800' },
  usageValue: { fontSize: 18, color: palette.text, fontWeight: '800', lineHeight: 25 },
  usageExplanation: { fontSize: 13, color: palette.textSoft, lineHeight: 20 },
  correctAnswer: { marginTop: 14, borderTopWidth: 1, borderTopColor: 'rgba(255,200,200,0.16)', paddingTop: 13, gap: 6 },
  answerLabel: { color: '#FFB3B6', fontWeight: '800', letterSpacing: 1.1, fontSize: 11.5 },
  answerText: { color: palette.text, fontWeight: '800', fontSize: 17, lineHeight: 24 },
  feedbackBody: { color: palette.textSoft, fontSize: 13.5, lineHeight: 21, marginTop: 13 },
  feedbackStrong: { color: '#FFFFFF', fontWeight: '800' },
  bottom: { paddingHorizontal: sizes.page, paddingTop: 12, paddingBottom: 6 },
  bottomFade: { position: 'absolute', left: 0, right: 0, top: -28, bottom: 0 },
  pressed: { opacity: 0.8 },
  skip: { alignItems: 'center', paddingVertical: 10, marginBottom: 6 },
  skipText: { color: palette.muted, fontSize: 13, fontWeight: '700', textDecorationLine: 'underline' },
  writeHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 11, gap: 6 },
  modeSwitcher: { flexDirection: 'row', padding: 3, backgroundColor: 'rgba(16,38,68,0.8)', borderRadius: 13, gap: 3,
    borderWidth: 1, borderColor: palette.line },
  modeChoice: { flexDirection: 'row', alignItems: 'center', gap: 5, paddingVertical: 7, paddingHorizontal: 10, borderRadius: 10 },
  modeActive: { backgroundColor: palette.sky },
  modeText: { color: palette.muted, fontSize: 11.5, fontWeight: '800' },
  modeActiveText: { color: palette.ink },
  bankSummary: { marginTop: 10, fontSize: 12, color: palette.muted },
  infoSection: { marginTop: 22, gap: 16 },
  infoImageCard: { marginHorizontal: -6 },
  infoImageFallback: { height: 110, backgroundColor: 'rgba(8,20,38,0.6)', justifyContent: 'center', alignItems: 'center', borderRadius: 12, padding: 18 },
  infoImageFallbackText: { color: palette.muted, textAlign: 'center', fontSize: 13 },
  infoCaption: { marginTop: 2, marginHorizontal: 12, color: palette.muted, fontSize: 12, lineHeight: 18, textAlign: 'center' },
  infoContinueNote: { color: palette.dim, fontSize: 12, textAlign: 'center' },
});
