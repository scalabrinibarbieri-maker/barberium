import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator, Alert, Image, Keyboard, KeyboardAvoidingView, Platform, Pressable,
  ScrollView, StyleSheet, Text, TextInput, View,
} from 'react-native';
import { ActionButton } from '../../components/ActionButton';
import { LetterBank } from '../../components/LetterBank';
import { canUseLetterBank } from '../../features/learning/letterBank';
import { MatchBoard } from '../../components/MatchBoard';
import { Page } from '../../components/Page';
import { ProgressBar } from '../../components/ProgressBar';
import { colors, sizes } from '../../constants/theme';
import { ExercisePronunciation } from '../../features/audio/ExercisePronunciation';
import { useFeedbackSounds } from '../../features/audio/useFeedbackSounds';
import { useCourses } from '../../features/courses/CourseProvider';
import type { Lesson } from '../../features/learning/types';
import { correctAnswerLabel, evaluateExercise, gradeExercise } from '../../features/learning/engine';
import { isChoiceExercise, isListeningExercise, isWriteExercise } from '../../features/learning/types';
import { canStartLesson } from '../../features/progress/logic';
import { useProgress } from '../../features/progress/ProgressProvider';

const NAVY = '#071D34';
const BLUE = '#246FEB';
const GREEN = '#188361';
const RED = '#B74D4D';

export default function LessonScreen() {
  const { lessonId } = useLocalSearchParams<{ lessonId: string }>();
  const { progress, ready, completeLesson } = useProgress();
  const { lesson: findLesson, loadLesson, lessonIds } = useCourses();
  const [fallback, setFallback] = useState<Lesson | undefined>();
  const [loadError, setLoadError] = useState(false);
  const lesson = (lessonId ? findLesson(lessonId) : undefined) ?? fallback;
  const [index, setIndex] = useState(0);
  const [answer, setAnswer] = useState('');
  const [checked, setChecked] = useState(false);
  const [correct, setCorrect] = useState(false);
  const [spellingCorrection, setSpellingCorrection] = useState<string | null>(null);
  const [count, setCount] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [audioReady, setAudioReady] = useState(false);
  const [skipped, setSkipped] = useState(false);
  const [inputMode, setInputMode] = useState<'keyboard' | 'letters'>('keyboard');
  const [infoImageError, setInfoImageError] = useState(false);
  const scrollRef = useRef<ScrollView | null>(null);
  const playedFeedback = useRef<string | null>(null);
  const playFeedback = useFeedbackSounds();

  useEffect(() => {
    if (!lessonId || findLesson(lessonId)) return;
    let active = true;
    setLoadError(false);
    void loadLesson(lessonId).then(l => { if (active) setFallback(l); })
      .catch(() => { if (active) setLoadError(true); });
    return () => { active = false; };
  }, [lessonId, findLesson, loadLesson]);

  // Sons somente depois de verificar; nunca ao escolher uma alternativa ou par.
  useEffect(() => {
    if (!checked || skipped) return;
    const questionKey = `${lessonId ?? ''}:${index}`;
    if (playedFeedback.current === questionKey) return;
    playedFeedback.current = questionKey;
    playFeedback(correct);
  }, [checked, skipped, correct, index, lessonId, playFeedback]);

  // A correção pode estar fora da área visível, especialmente após fechar o teclado.
  // Rola novamente depois da animação de fechamento do teclado no Android/iOS.
  useEffect(() => {
    if (!checked) return;
    const first = setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 80);
    const second = setTimeout(() => scrollRef.current?.scrollToEnd({ animated: true }), 300);
    return () => { clearTimeout(first); clearTimeout(second); };
  }, [checked, index]);

  if (!ready) return <Page><ActivityIndicator style={{ marginTop: 80 }} color={colors.primary} /></Page>;
  if (!lesson && lessonId && !loadError) return <Page>
    <ActivityIndicator style={{ marginTop: 80 }} color={colors.primary} />
    <Text style={styles.message}>Carregando lição...</Text>
  </Page>;
  if (!lesson || !canStartLesson(lesson.id, lessonIds, progress)) return <Page><View style={styles.missing}>
    <Text style={styles.errorTitle}>{loadError ? 'Lição indisponível offline' : 'Lição indisponível'}</Text>
    <Text style={styles.message}>Se a unidade não foi baixada, conecte-se à internet para abrir a lição.</Text>
    <ActionButton title="Voltar ao início" onPress={() => router.replace('/')} />
  </View></Page>;

  const question = lesson.exercises[index];
  if (!question) return null;
  const listening = isListeningExercise(question);
  const choice = isChoiceExercise(question);
  const writing = isWriteExercise(question);
  const informative = question.type === 'info';
  const bankAvailable = writing && canUseLetterBank(question.sampleAnswer);
  // É possível desfazer e refazer pares; a avaliação só acontece após todos serem ligados.
  const matchReady = question.type !== 'match' || answer.split('|').filter(Boolean).length === question.pairs.length;
  const canVerify = answer.trim().length > 0 && matchReady && (!listening || audioReady);

  const verify = () => {
    if (checked || !canVerify) return;
    Keyboard.dismiss();
    // Mantém a checagem booleana antiga (XP); a avaliação detalhada só explica a grafia.
    const right = gradeExercise(question, answer);
    setCorrect(right);
    setSpellingCorrection(right ? evaluateExercise(question, answer).spellingCorrection : null);
    setChecked(true);
    if (right) setCount(c => c + 1);
  };
  const next = async () => {
    if (submitting) return;
    if (index < lesson.exercises.length - 1) {
      setIndex(v => v + 1);
      setAnswer(''); setChecked(false); setCorrect(false); setSpellingCorrection(null);
      setAudioReady(false); setSkipped(false); setInputMode('keyboard'); setInfoImageError(false);
      scrollRef.current?.scrollTo({ y: 0, animated: false });
      return;
    }
    setSubmitting(true);
    try {
      const xp = await completeLesson(lesson.id, count, lesson.exercises.length);
      router.replace({ pathname: '/result', params: { lessonId: lesson.id, correct: String(count), xp: String(xp) } });
    } catch {
      Alert.alert('Não foi possível salvar', 'Tente novamente para preservar seu progresso.');
      setSubmitting(false);
    }
  };

  const audioExerciseId = listening ? question.audioExerciseId : question.id;
  const exerciseHint = informative ? 'Leia com atenção antes de continuar.' : question.type === 'match' ? 'Relacione as expressões nas duas colunas.'
    : choice ? 'Escolha a alternativa que faz sentido.' : 'Escreva sua resposta no campo abaixo.';
  const infoCategory = informative ? ({ vocabulary: 'NOVA PALAVRA', culture: 'CULTURA E CONTEXTO', grammar: 'ENTENDA A GRAMÁTICA', tip: 'DICA DE APRENDIZADO' } as const)[question.category ?? 'tip'] : '';
  const feedbackTitle = skipped ? 'Atividade pulada' : correct ? (spellingCorrection ? 'Correto! Ajuste a escrita.' : 'Resposta correta!') : 'Vamos aprender com essa resposta';

  return <Page><KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={styles.layout}>
    <View style={styles.header}>
      <View style={styles.headerTop}>
        <Pressable accessibilityRole="button" accessibilityLabel="Sair da lição" onPress={() => router.back()} style={styles.close}>
          <Text style={styles.cross}>×</Text>
        </Pressable>
        <View style={styles.headerLabel}>
          <Text style={styles.headerEyebrow}>ITALIANO · A1</Text>
          <Text style={styles.headerTitle} numberOfLines={1}>{lesson.title}</Text>
        </View>
        <Text style={styles.counter}>{index + 1}<Text style={styles.counterMuted}>/{lesson.exercises.length}</Text></Text>
      </View>
      <ProgressBar value={(index + (checked ? 1 : 0)) / lesson.exercises.length} />
    </View>

    <ScrollView ref={scrollRef} keyboardShouldPersistTaps="handled"
      showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}
      onContentSizeChange={() => { if (checked) scrollRef.current?.scrollToEnd({ animated: true }); }}>
      <View style={styles.promptCard}>
        <View pointerEvents="none" style={styles.cornerRing} />
        <Text style={styles.cardEyebrow}>{informative ? infoCategory : `QUESTÃO ${String(index + 1).padStart(2, '0')}  ·  ${question.instruction.toUpperCase()}`}</Text>
        <Text style={styles.prompt}>{question.prompt}</Text>
        <Text style={styles.cardHint}>{exerciseHint}</Text>
      </View>

      {question.type === 'info' && <View style={styles.infoSection}>
        {question.image && <View style={styles.infoImageCard}>
          {!infoImageError ? <Image source={{ uri: question.image.url }} style={styles.infoImage} resizeMode="contain"
            accessible accessibilityLabel={question.image.alt} onError={() => setInfoImageError(true)} />
            : <View style={styles.infoImageFallback}><Text style={styles.infoImageFallbackText}>Imagem não disponível. O conteúdo continua abaixo.</Text></View>}
          {question.image.caption && <Text style={styles.infoCaption}>{question.image.caption}</Text>}
        </View>}
        <View style={styles.infoBody}><Text style={styles.infoBodyTitle}>Para entender melhor</Text>
          <Text style={styles.infoBodyText}>{question.explanation}</Text></View>
        <Text style={styles.infoContinueNote}>Nenhuma resposta necessária nesta etapa.</Text>
      </View>}

      {!informative && <ExercisePronunciation key={question.id} exerciseId={audioExerciseId}
        concealText={listening && !checked} onReadyChange={listening ? setAudioReady : undefined} />}

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
              <Text style={[styles.optionNoText, (chosen || showRight) && styles.numberWhite]}>{showRight ? '✓' : showWrong ? '×' : i + 1}</Text>
            </View>
            <Text style={[styles.optionText, showRight && styles.rightText, showWrong && styles.wrongText]}>{option.label}</Text>
          </Pressable>;
        })}
      </View>}

      {writing && <View style={styles.writeSection}>
        <View style={styles.writeHeader}>
          <Text style={styles.sectionLabel}>SUA RESPOSTA</Text>
          {bankAvailable && !checked && <View style={styles.modeSwitcher}>
            <Pressable accessibilityRole="button" accessibilityLabel="Responder digitando no teclado"
              accessibilityState={{ selected: inputMode === 'keyboard' }}
              onPress={() => { if (inputMode !== 'keyboard') { Keyboard.dismiss(); setAnswer(''); setInputMode('keyboard'); } }}
              style={[styles.modeChoice, inputMode === 'keyboard' && styles.modeActive]}>
              <Text style={[styles.modeText, inputMode === 'keyboard' && styles.modeActiveText]}>⌨  Teclado</Text>
            </Pressable>
            <Pressable accessibilityRole="button" accessibilityLabel="Responder tocando em letras embaralhadas"
              accessibilityState={{ selected: inputMode === 'letters' }}
              onPress={() => { if (inputMode !== 'letters') { Keyboard.dismiss(); setAnswer(''); setInputMode('letters'); } }}
              style={[styles.modeChoice, inputMode === 'letters' && styles.modeActive]}>
              <Text style={[styles.modeText, inputMode === 'letters' && styles.modeActiveText]}>▦  Letras</Text>
            </Pressable>
          </View>}
        </View>
        {inputMode === 'letters' && bankAvailable ?
          <LetterBank key={`${question.id}-letters`} sample={question.sampleAnswer} exerciseId={question.id}
            checked={checked} onAnswer={setAnswer} /> :
          <TextInput key={`${question.id}-keyboard`} accessibilityLabel="Sua resposta"
            placeholder={listening ? 'Escreva o que ouviu...' : 'Escreva aqui...'}
            placeholderTextColor="#94A3B7" value={answer} onChangeText={setAnswer}
            editable={!checked} autoCapitalize="sentences" autoCorrect={false}
            returnKeyType="done" style={[styles.input, checked && (correct ? styles.inputCorrect : styles.inputWrong)]} />}
        {checked && inputMode === 'letters' && <Text style={styles.bankSummary}>Resposta montada: {answer}</Text>}
      </View>}

      {question.type === 'match' && <MatchBoard key={question.id} exercise={question} checked={checked} onAnswer={setAnswer} />}

      {listening && !audioReady && !checked && <Text style={styles.audioHint}>
        Aguarde a gravação carregar para responder. Para conteúdo da nuvem, conecte-se à internet na primeira vez.
      </Text>}

      {checked && !informative && <View accessibilityLiveRegion="polite" style={[styles.feedback,
        skipped ? styles.skippedPanel : correct ? styles.good : styles.bad]}>
        <View style={styles.feedbackTop}>
          <View style={[styles.feedbackIcon, skipped ? styles.skipIcon : correct ? styles.goodIcon : styles.badIcon]}>
            <Text style={styles.feedbackSymbol}>{skipped ? '–' : correct ? '✓' : '×'}</Text>
          </View>
          <View style={styles.feedbackCopy}>
            <Text style={[styles.feedbackTitle, skipped ? styles.skippedTitle : correct ? styles.goodTitle : styles.badTitle]}>{feedbackTitle}</Text>
            <Text style={styles.feedbackStatus}>{skipped ? 'Sem pontuação nesta questão' : correct ? (spellingCorrection ? 'Resposta aceita! Veja a grafia correta abaixo.' : 'Muito bem! Continue avançando.') : 'Confira a resposta e continue praticando.'}</Text>
          </View>
        </View>
        {!skipped && correct && spellingCorrection && <View style={styles.spellingPanel}>
          <Text style={styles.spellingLabel}>GRAFIA CORRETA</Text>
          <Text selectable style={styles.spellingValue}>{spellingCorrection}</Text>
        </View>}
        {!skipped && !correct && <View style={styles.correctAnswer}>
          <Text style={styles.answerLabel}>RESPOSTA CORRETA</Text>
          <Text selectable style={styles.answerText}>{correctAnswerLabel(question)}</Text>
        </View>}
        <Text style={styles.feedbackBody}>{skipped
          ? 'A gravação não estava disponível. Você pode continuar sem ganhar pontos nesta atividade.'
          : question.explanation}</Text>
      </View>}
    </ScrollView>

    <View style={styles.bottom}>
      {listening && !audioReady && !checked && <Pressable accessibilityRole="button"
        accessibilityLabel="Pular atividade sem áudio, sem ganhar pontos"
        onPress={() => { Keyboard.dismiss(); setSkipped(true); setCorrect(false); setChecked(true); }}
        style={styles.skip}><Text style={styles.skipText}>Pular atividade sem áudio</Text></Pressable>}
      <Pressable accessibilityRole="button" accessibilityState={{ disabled: submitting || (!informative && !checked && !canVerify) }}
        disabled={submitting || (!informative && !checked && !canVerify)} onPress={informative || checked ? () => { void next(); } : verify}
        style={({ pressed }) => [styles.primaryAction, checked && (correct ? styles.successAction : styles.continueAction),
          (submitting || (!informative && !checked && !canVerify)) && styles.disabledAction, pressed && styles.pressed]}>
        <Text style={styles.actionText}>{submitting ? 'Salvando...' : informative ? (index === lesson.exercises.length - 1 ? 'Concluir lição' : 'Entendi, continuar') : !checked ? 'Verificar resposta' : index === lesson.exercises.length - 1 ? 'Concluir lição' : 'Continuar'}</Text>
        <Text style={styles.actionArrow}>→</Text>
      </Pressable>
    </View>
  </KeyboardAvoidingView></Page>;
}

const styles = StyleSheet.create({
  layout: { flex: 1 },
  missing: { flex: 1, justifyContent: 'center', gap: 18, paddingHorizontal: sizes.page },
  errorTitle: { fontSize: 27, fontWeight: '900', color: colors.ink },
  message: { textAlign: 'center', marginTop: 12, fontSize: 14, color: colors.muted, lineHeight: 21 },
  header: { backgroundColor: '#F7F8FC', paddingHorizontal: sizes.page, paddingTop: 10, paddingBottom: 17, gap: 17 },
  headerTop: { flexDirection: 'row', alignItems: 'center', gap: 13 },
  close: { width: 38, height: 38, borderRadius: 13, backgroundColor: '#E7ECF3', alignItems: 'center', justifyContent: 'center' },
  cross: { fontSize: 27, fontWeight: '400', color: '#526B86', marginTop: -2 },
  headerLabel: { flex: 1, gap: 3 },
  headerEyebrow: { fontSize: 9, letterSpacing: 1.45, fontWeight: '900', color: '#5A7C9F' },
  headerTitle: { color: NAVY, fontWeight: '800', fontSize: 14 },
  counter: { fontSize: 19, fontWeight: '900', color: NAVY },
  counterMuted: { fontSize: 13, fontWeight: '700', color: '#8B9CB1' },
  scroll: { flexGrow: 1, paddingHorizontal: sizes.page, paddingTop: 17, paddingBottom: 42 },
  promptCard: { backgroundColor: NAVY, borderRadius: 24, paddingHorizontal: 23, paddingVertical: 26, overflow: 'hidden', minHeight: 164 },
  cornerRing: { position: 'absolute', width: 190, height: 190, right: -113, top: -108, borderRadius: 95, borderWidth: 24, borderColor: 'rgba(81,163,255,0.08)' },
  cardEyebrow: { color: '#F4BD79', fontSize: 10, fontWeight: '900', letterSpacing: 1.3, lineHeight: 16 },
  prompt: { color: '#FFFFFF', fontWeight: '900', fontSize: 33, letterSpacing: -1.15, lineHeight: 41, marginTop: 15 },
  cardHint: { color: '#B9CDE3', fontSize: 13, lineHeight: 20, marginTop: 11 },
  sectionLabel: { color: '#647F9C', fontSize: 10, fontWeight: '900', letterSpacing: 1.5, marginBottom: 11 },
  choices: { marginTop: 28, gap: 11 },
  choice: { borderRadius: 18, backgroundColor: '#FFFFFF', borderWidth: 1.5, borderColor: '#E0E6EF', paddingHorizontal: 16, paddingVertical: 12, flexDirection: 'row', gap: 15, alignItems: 'center', minHeight: 68 },
  selected: { borderColor: BLUE, backgroundColor: '#EAF2FF' },
  rightChoice: { borderColor: '#3AAF87', backgroundColor: '#E9F9F3' },
  wrongChoice: { borderColor: '#D97E78', backgroundColor: '#FFF0EF' },
  optionNo: { width: 37, height: 37, borderRadius: 12, backgroundColor: '#EEF2F7', alignItems: 'center', justifyContent: 'center' },
  numberSelected: { backgroundColor: BLUE },
  numberRight: { backgroundColor: GREEN },
  numberWrong: { backgroundColor: RED },
  optionNoText: { color: '#697F98', fontSize: 15, fontWeight: '900' },
  numberWhite: { color: '#FFFFFF' },
  optionText: { fontSize: 16, color: NAVY, fontWeight: '800', flex: 1 },
  rightText: { color: '#146748' }, wrongText: { color: '#9C4545' },
  writeSection: { marginTop: 28 },
  input: { borderRadius: 17, backgroundColor: '#FFFFFF', padding: 19, minHeight: 65, borderColor: '#DEE5EF', borderWidth: 1.5, fontSize: 19, color: NAVY, fontWeight: '700' },
  inputCorrect: { borderColor: '#3AAF87', backgroundColor: '#E9F9F3' },
  inputWrong: { borderColor: '#D97E78', backgroundColor: '#FFF0EF' },
  audioHint: { color: colors.muted, fontSize: 12, lineHeight: 19, marginTop: 14 },
  feedback: { marginTop: 27, padding: 18, borderRadius: 21, borderWidth: 1.5 },
  good: { backgroundColor: '#EBFAF4', borderColor: '#9DDFC7' },
  bad: { backgroundColor: '#FFF1EF', borderColor: '#F0C6C0' },
  skippedPanel: { backgroundColor: '#FFF7E9', borderColor: '#EED6A6' },
  feedbackTop: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  feedbackIcon: { width: 44, height: 44, borderRadius: 14, alignItems: 'center', justifyContent: 'center' },
  goodIcon: { backgroundColor: GREEN }, badIcon: { backgroundColor: RED }, skipIcon: { backgroundColor: '#A97D37' },
  feedbackSymbol: { color: '#FFFFFF', fontSize: 24, fontWeight: '900' },
  feedbackCopy: { flex: 1, gap: 3 },
  feedbackTitle: { fontWeight: '900', fontSize: 16, lineHeight: 21 },
  goodTitle: { color: '#126E50' }, badTitle: { color: '#A34441' }, skippedTitle: { color: '#926625' },
  feedbackStatus: { color: '#667C90', fontSize: 12, lineHeight: 17 },
  spellingPanel: { marginTop: 16, backgroundColor: '#FFF8E9', borderColor: '#F0D5A5', borderWidth: 1, borderRadius: 14, padding: 14, gap: 6 },
  spellingLabel: { fontSize: 10, color: '#8B651B', letterSpacing: 1.1, fontWeight: '900' },
  spellingValue: { fontSize: 18, color: NAVY, fontWeight: '900' },
  correctAnswer: { marginTop: 16, borderTopWidth: 1, borderTopColor: 'rgba(134,97,97,0.18)', paddingTop: 15, gap: 7 },
  answerLabel: { color: '#99514E', fontWeight: '900', letterSpacing: 1.1, fontSize: 10 },
  answerText: { color: NAVY, fontWeight: '800', fontSize: 16, lineHeight: 24 },
  feedbackBody: { color: '#40556B', fontSize: 13, lineHeight: 21, marginTop: 15 },
  bottom: { paddingHorizontal: sizes.page, paddingTop: 13, paddingBottom: 7, borderTopWidth: 1, borderTopColor: '#E3EAF2', backgroundColor: '#F7F8FC' },
  primaryAction: { backgroundColor: BLUE, minHeight: 58, borderRadius: 18, paddingHorizontal: 20, flexDirection: 'row', alignItems: 'center', justifyContent: 'center' },
  successAction: { backgroundColor: GREEN },
  continueAction: { backgroundColor: '#15375C' },
  disabledAction: { opacity: 0.4 },
  actionText: { color: '#FFFFFF', fontWeight: '900', fontSize: 16 },
  actionArrow: { position: 'absolute', right: 19, fontSize: 23, fontWeight: '900', color: '#FFFFFF' },
  pressed: { opacity: 0.79 },
  skip: { alignItems: 'center', paddingVertical: 11, marginBottom: 5 },
  skipText: { color: '#6B7F98', fontSize: 13, fontWeight: '700' },
  writeHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 11, gap: 6 },
  modeSwitcher: { flexDirection: 'row', padding: 3, backgroundColor: '#E4ECF7', borderRadius: 12, gap: 3 },
  modeChoice: { paddingVertical: 9, paddingHorizontal: 10, borderRadius: 10 },
  modeActive: { backgroundColor: '#FFFFFF', shadowColor: '#164777', shadowOpacity: 0.09, shadowRadius: 4, elevation: 2 },
  modeText: { color: '#6B829E', fontSize: 11, fontWeight: '800' },
  modeActiveText: { color: '#1A65BD' },
  bankSummary: { marginTop: 10, fontSize: 12, color: '#627F9D' },
  infoSection: { marginTop: 25, gap: 18 },
  infoImageCard: { padding: 12, borderWidth: 1, borderColor: '#E2EAF3', borderRadius: 20, backgroundColor: '#FFFFFF' },
  infoImage: { width: '100%', height: 220, borderRadius: 14, backgroundColor: '#F0F5FB' },
  infoImageFallback: { height: 110, backgroundColor: '#EFF4FA', justifyContent: 'center', alignItems: 'center', borderRadius: 12, padding: 18 },
  infoImageFallbackText: { color: '#7487A0', textAlign: 'center', fontSize: 13 },
  infoCaption: { marginTop: 10, color: '#768CA4', fontSize: 12, lineHeight: 18 },
  infoBody: { borderRadius: 20, backgroundColor: '#FFFFFF', borderWidth: 1, borderColor: '#E1EAF4', padding: 21 },
  infoBodyTitle: { color: '#1C61B0', fontWeight: '900', letterSpacing: 0.2, fontSize: 16, marginBottom: 11 },
  infoBodyText: { color: '#263C55', fontSize: 16, lineHeight: 26 },
  infoContinueNote: { color: '#8197AF', fontSize: 12, textAlign: 'center' },
});
