import { router, useLocalSearchParams } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';
import { Page } from '../components/Page';
import { ActionButton } from '../components/ActionButton';
import { colors, sizes } from '../constants/theme';
import { useCourses } from '../features/courses/CourseProvider';
import { useProgress } from '../features/progress/ProgressProvider';
import { computeStreak, daysFromLegacy, localStudyDay } from '../features/progress/streak';

export default function Result() {
  const { lessonId, correct, xp } = useLocalSearchParams<{ lessonId: string; correct: string; xp: string }>();
  const {lesson: findLesson} = useCourses();
  const {progress} = useProgress();
  const lesson = lessonId ? findLesson(lessonId) : undefined;
  if (!lesson) return <Page><View style={styles.layout}><Text style={styles.title}>Resultado indisponível</Text><ActionButton title="Voltar" onPress={() => router.replace('/')} /></View></Page>;
  const gradedCount = lesson.exercises.filter(exercise => exercise.type !== 'info').length;
  const correctCount = Math.min(gradedCount, Math.max(0, Number(correct) || 0));
  const earned = Math.max(0, Number(xp) || 0);
  const streak = computeStreak(daysFromLegacy(progress.lastStudiedAt, progress.studyDays), localStudyDay(new Date()));
  return <Page><View style={styles.layout}>
    <View style={styles.medal}><Text style={{fontSize:64}}>✦</Text></View><Text style={styles.kicker}>LIÇÃO CONCLUÍDA</Text>
    <Text style={styles.title}>Bravissimo!</Text><Text style={styles.subtitle}>Você terminou “{lesson.title}”. Continue avançando!</Text>
    <View style={styles.stats}><View style={styles.stat}><Text style={styles.number}>{correctCount}/{gradedCount}</Text><Text style={styles.legend}>Respostas certas</Text></View>
      <View style={styles.stat}><Text style={styles.number}>+{earned}</Text><Text style={styles.legend}>XP conquistados</Text></View></View>
    {earned === 0 && <Text style={styles.note}>Ao repetir uma lição, o XP não é contado novamente.</Text>}
    <View style={styles.streakCard} accessibilityLiveRegion="polite">
      <Text style={styles.streakIcon}>🔥</Text>
      <View style={styles.streakCopy}>
        <Text style={styles.streakTitle}>{streak.current} {streak.current === 1 ? 'dia seguido' : 'dias seguidos'}</Text>
        <Text style={styles.streakText}>{streak.studiedToday ? 'Estudo de hoje registrado. Volte amanhã para continuar!' : 'Continue praticando para manter sua sequência.'}</Text>
      </View>
    </View>
    <View style={styles.bottom}><ActionButton title="Continuar aprendendo" onPress={() => router.replace('/')} /></View>
  </View></Page>;
}
const styles = StyleSheet.create({
  layout: { flex: 1, paddingHorizontal: sizes.page, alignItems: 'center', justifyContent: 'center' },
  medal: { width: 136, height: 136, borderRadius: 68, backgroundColor: colors.orangeSoft, alignItems: 'center', justifyContent: 'center', marginBottom: 25 },
  kicker: { color: colors.primary, letterSpacing: 1.5, fontSize: 12, fontWeight: '900' },
  title: { fontSize: 38, fontWeight: '900', color: colors.ink, marginTop: 10 },
  subtitle: { color: colors.muted, fontSize: 16, lineHeight: 24, textAlign: 'center', marginTop: 12, maxWidth: 300 },
  stats: { flexDirection: 'row', gap: 12, marginTop: 25, width: '100%' },
  stat: { flex: 1, backgroundColor: '#FFFFFF', padding: 17, borderRadius: 17, borderWidth: 1, borderColor: colors.line, alignItems: 'center' },
  number: { fontSize: 23, fontWeight: '900', color: colors.primary },
  legend: { fontSize: 12, color: colors.muted, marginTop: 8, textAlign: 'center' },
  note: { fontSize: 12, color: colors.muted, textAlign: 'center', marginTop: 15 },
  streakCard: { width: '100%', marginTop: 20, padding: 16, borderRadius: 19, backgroundColor: '#102E4F', borderWidth: 1, borderColor: '#2C537A', flexDirection: 'row', alignItems: 'center', gap: 12 },
  streakIcon: { fontSize: 28 }, streakCopy: { flex: 1 },
  streakTitle: { color: '#FFFFFF', fontSize: 17, fontWeight: '900' },
  streakText: { color: '#C7DDF5', fontSize: 12, lineHeight: 18, marginTop: 4 },
  bottom: { width: '100%', marginTop: 30 },
});
