import { router } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator, Alert, AppState, Pressable, RefreshControl, ScrollView,
  StyleSheet, Text, View, Image,
} from 'react-native';
import { Page } from '../components/Page';
import { LESSONS } from '../features/learning/data';
import { useCourses } from '../features/courses/CourseProvider';
import type { CourseUnitSummary } from '../features/courses/schema';
import { useOnboarding } from '../features/onboarding/OnboardingProvider';
import { canStartLesson } from '../features/progress/logic';
import { computeStreak, daysFromLegacy, localStudyDay } from '../features/progress/streak';
import { useProgress } from '../features/progress/ProgressProvider';

// V9: camada visual nativa. Os identificadores, provedores, rotas e operações
// continuam os mesmos das versões anteriores. Nenhum progresso é recalculado.
const NAVY = '#071625';
const INK = '#102840';
const MUTED = '#71859F';
const SKY = '#86C9FF';
const BLUE = '#3279F5';
const GOLD = '#F6C27E';
const PAPER = '#F4F7FC';

const formatNumber = (number: number) => String(number).padStart(2, '0');

type LessonTileProps = {
  title: string;
  subtitle: string;
  exerciseCount: number;
  number: number;
  done: boolean;
  unlocked: boolean;
  busy: boolean;
  last: boolean;
  onPress: () => void;
};

function LessonTile({ title, subtitle, exerciseCount, number, done, unlocked, busy, last, onPress }: LessonTileProps) {
  const available = unlocked && !busy;
  const label = done ? 'CONCLUÍDA' : unlocked ? 'PRÓXIMA CONQUISTA' : 'BLOQUEADA';
  return (
    <View style={styles.pathStep}>
      <View style={styles.rail}>
        <View style={[styles.lessonOrbHalo, done && styles.orbHaloDone, !unlocked && styles.orbHaloLocked]}>
          <View style={[styles.lessonOrb, done ? styles.orbDone : unlocked ? styles.orbActive : styles.orbLocked]}>
            <Text style={[styles.orbSymbol, !unlocked && styles.orbSymbolLocked]}>{done ? '✓' : unlocked ? '▶' : '—'}</Text>
          </View>
        </View>
        {!last && <View style={[styles.railLine, done && styles.railLineDone]} />}
      </View>
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ disabled: !available }}
        accessibilityLabel={`${title}, lição ${number}, ${done ? 'concluída' : unlocked ? 'disponível' : 'bloqueada'}`}
        disabled={!available}
        onPress={onPress}
        style={({ pressed }) => [
          styles.lessonCard, unlocked && !done && styles.lessonCardActive,
          done && styles.lessonCardDone, !unlocked && styles.lessonCardLocked,
          pressed && styles.pressed,
        ]}
      >
        <View style={styles.lessonCardTop}>
          <Text style={[styles.lessonEyebrow, done && styles.eyebrowDone, !unlocked && styles.eyebrowLocked]}>
            LIÇÃO {formatNumber(number)}  /  {label}
          </Text>
          <Text style={[styles.lessonChevron, !unlocked && styles.arrowDisabled]}>›</Text>
        </View>
        <Text style={styles.lessonTitle}>{title}</Text>
        <Text style={styles.lessonSubtitle}>{subtitle}</Text>
        <View style={styles.lessonCardFooter}>
          <View style={styles.lessonExercisePill}>
            <Text style={styles.lessonExerciseText}>{exerciseCount} exercícios</Text>
          </View>
          {done && <Text style={styles.reviewText}>Revisar ↗</Text>}
        </View>
      </Pressable>
    </View>
  );
}

function DockIcon({ kind, active }: { kind: 'learn' | 'courses' | 'profile'; active: boolean }) {
  const tint = active ? BLUE : '#96A8BF';
  if (kind === 'learn') return (
    <View style={styles.iconCanvas}>
      <View style={[styles.homeRoof, { borderColor: tint }]} />
      <View style={[styles.homeBody, { borderColor: tint }]}>
        <View style={[styles.homeDoor, { backgroundColor: tint }]} />
      </View>
    </View>
  );
  if (kind === 'courses') return (
    <View style={styles.iconCanvas}>
      <View style={[styles.bookShape, { borderColor: tint }]}>
        <View style={[styles.bookCenter, { backgroundColor: tint }]} />
      </View>
    </View>
  );
  return (
    <View style={styles.iconCanvas}>
      <View style={[styles.personHead, { borderColor: tint }]} />
      <View style={[styles.personShoulders, { borderColor: tint }]} />
    </View>
  );
}

function DockItem({ title, kind, selected, onPress }: {
  title: string; kind: 'learn' | 'courses' | 'profile'; selected: boolean; onPress: () => void;
}) {
  // Impede que toques rápidos disparem várias transições sobrepostas.
  const navigating = useRef(false);
  const open = () => {
    if (selected || navigating.current) return;
    navigating.current = true;
    // Permite navegar novamente ao retornar à Home, mas ignora taps em rajada.
    setTimeout(() => { navigating.current = false; }, 600);
    onPress();
  };
  return (
    <Pressable accessibilityRole="tab" accessibilityLabel={title} accessibilityState={{ selected, disabled: selected }}
      disabled={selected} onPress={open} style={({ pressed }) => [styles.dockItem, selected && styles.dockItemSelected, pressed && styles.pressed]}>
      <DockIcon kind={kind} active={selected} />
      <Text style={[styles.dockLabel, selected && styles.dockLabelSelected]}>{title}</Text>
    </Pressable>
  );
}

export default function Home() {
  const { progress, ready } = useProgress();
  const { settings } = useOnboarding();
  const { catalog, ready: coursesReady, refreshing, refresh, downloaded, download, remove, loadUnit } = useCourses();
  const [busy, setBusy] = useState(false);
  const [today, setToday] = useState(() => localStudyDay(new Date()));
  useEffect(() => {
    const subscription = AppState.addEventListener('change', state => {
      if (state === 'active') setToday(localStudyDay(new Date()));
    });
    return () => subscription.remove();
  }, []);
  const streak = useMemo(() => computeStreak(daysFromLegacy(progress.lastStudiedAt, progress.studyDays), today),
    [progress.lastStudiedAt, progress.studyDays, today]);

  // Mantém a sequência e os mesmos IDs utilizados no XP e na sincronização.
  const italianUnits = useMemo(() => catalog.units.filter(unit => unit.language === 'it'), [catalog.units]);
  const orderedIds = useMemo(() => [
    ...LESSONS.map(lesson => lesson.id),
    ...italianUnits.flatMap(unit => unit.lessons.map(lesson => lesson.id)),
  ], [italianUnits]);
  const completedIds = progress.completedLessonIds;
  const completed = orderedIds.filter(id => completedIds.includes(id)).length;
  const progressRatio = orderedIds.length ? completed / orderedIds.length : 0;
  const nextId = orderedIds.find(id => !completedIds.includes(id)) ?? LESSONS[0]?.id;
  const nextLocal = LESSONS.find(lesson => lesson.id === nextId);
  const nextRemote = italianUnits.flatMap(unit => unit.lessons.map(lesson => ({ unit, lesson })))
    .find(item => item.lesson.id === nextId);
  const allDone = orderedIds.length > 0 && completed === orderedIds.length;
  const nextTitle = nextLocal?.title ?? nextRemote?.lesson.title ?? 'Primeiras palavras';
  const nextSubtitle = nextLocal?.subtitle ?? nextRemote?.lesson.subtitle ?? 'Sua próxima conquista começa aqui';

  const run = async (operation: () => Promise<void>, errorMessage: string) => {
    if (busy) return;
    setBusy(true);
    try { await operation(); }
    catch (error) {
      console.warn('Falha na operação de conteúdo do Lunivo:', error instanceof Error ? error.message : 'erro');
      Alert.alert('Não foi possível concluir', errorMessage);
    } finally { setBusy(false); }
  };

  const openRemoteLesson = (unit: CourseUnitSummary, lessonId: string) => {
    void run(async () => {
      await loadUnit(unit);
      router.push({ pathname: '/lesson/[lessonId]', params: { lessonId } });
    }, 'Conecte-se à internet ou baixe esta unidade para estudá-la offline.');
  };

  const resume = () => {
    if (!ready || busy || !nextId) return;
    if (nextLocal) {
      router.push({ pathname: '/lesson/[lessonId]', params: { lessonId: nextLocal.id } });
    } else if (nextRemote) {
      openRemoteLesson(nextRemote.unit, nextRemote.lesson.id);
    }
  };

  const removeDownloadedUnit = (unit: CourseUnitSummary) => {
    Alert.alert('Remover unidade baixada?',
      'Os arquivos dessa unidade serão removidos do celular. Suas lições concluídas e seu progresso continuarão salvos.', [
        { text: 'Cancelar', style: 'cancel' },
        { text: 'Remover', style: 'destructive', onPress: () => {
          void run(() => remove(unit), 'Não foi possível remover o download. Tente novamente.');
        } },
      ]);
  };

  return (
    <Page>
      <View style={styles.screen}>
        <ScrollView style={styles.scroll} contentContainerStyle={styles.scrollContent}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { void refresh(); }}
            tintColor={SKY} colors={[BLUE]} progressBackgroundColor="#FFFFFF" />}>
          <View style={styles.darkSection}>
            <View pointerEvents="none" style={styles.ambientTop} />
            <View pointerEvents="none" style={styles.ambientSmall} />
            <View style={styles.brandRow}>
              <View style={styles.brandIdentity}>
                <Image source={require('../../assets/lunivo-logo.png')} resizeMode="contain"
                  style={styles.brandLogo} accessible accessibilityLabel="Logo Lunivo" />
                <Text style={styles.brandCaption}>seu idioma novo.</Text>
              </View>
              <Pressable accessibilityRole="button" accessibilityLabel="Abrir meu perfil"
                onPress={() => router.push('/profile')}
                style={({ pressed }) => [styles.avatar, pressed && styles.pressed]}>
                <DockIcon kind="profile" active={false} />
              </Pressable>
            </View>

            <View style={styles.badgeRow}>
              <View style={styles.languageChip}>
                <Text style={styles.languageFlag}>🇮🇹</Text>
                <Text style={styles.languageLabel}>ITALIANO  <Text style={styles.languageLevel}>A1</Text></Text>
              </View>
              <View style={styles.xpChip}>
                <View style={styles.xpGem} />
                <Text style={styles.xpNumber}>{progress.totalXp} XP</Text>
              </View>
            </View>

            <View style={styles.streakBanner} accessibilityLabel={`Sequência de ${streak.current} dias. ${streak.studiedToday ? 'Estudo de hoje concluído.' : 'Estude hoje para manter a sequência.'}`}>
              <View style={styles.streakFlame}><Text style={styles.streakFlameIcon}>🔥</Text></View>
              <View style={styles.streakCopy}>
                <Text style={styles.streakTitle}>{streak.current} {streak.current === 1 ? 'dia seguido' : 'dias seguidos'}</Text>
                <Text style={styles.streakSubtitle}>{streak.studiedToday ? 'Sua sequência está garantida hoje' : streak.current > 0 ? 'Uma lição hoje mantém sua sequência' : 'Conclua uma lição e comece sua sequência'}</Text>
              </View>
              <Text style={styles.streakToday}>{streak.studiedToday ? '✓ HOJE' : 'HOJE'}</Text>
            </View>

            <View style={styles.heroIntroduction}>
              <Text style={styles.sectionOverline}>O SEU PRÓXIMO PASSO</Text>
              <Text style={styles.introductionTitle}>Seu caminho continua.</Text>
            </View>

            <View style={styles.heroCard}>
              <View pointerEvents="none" style={styles.heroCircleBig} />
              <View pointerEvents="none" style={styles.heroCircleSmall} />
              <View style={styles.heroCardTop}>
                <View style={styles.heroStatus}>
                  <View style={styles.heroStatusDot} />
                  <Text style={styles.heroStatusText}>{allDone ? 'CURSO CONCLUÍDO' : 'CONTINUE APRENDENDO'}</Text>
                </View>
                <View style={styles.heroNumberBadge}><Text style={styles.heroNumberText}>{formatNumber(completed + (allDone ? 0 : 1))}</Text></View>
              </View>
              <Text style={styles.heroTitle}>{allDone ? 'Que jornada incrível.' : nextTitle}</Text>
              <Text style={styles.heroText}>{allDone ? 'Suas conquistas ficam com você. Que tal revisar?' : nextSubtitle}</Text>
              <View style={styles.heroDivider} />
              <View style={styles.heroProgressRow}>
                <Text style={styles.heroProgressLabel}>PROGRESSO DO CURSO</Text>
                <Text style={styles.heroProgressNumber}>{completed} / {orderedIds.length}</Text>
              </View>
              <View style={styles.progressTrack} accessibilityRole="progressbar"
                accessibilityValue={{ min: 0, max: 100, now: Math.round(progressRatio * 100) }}>
                <View style={[styles.progressFill, { width: `${Math.round(progressRatio * 100)}%` as `${number}%` }]} />
              </View>
              <Pressable accessibilityRole="button" disabled={!ready || busy || !nextId}
                accessibilityLabel={allDone ? 'Revisar primeira lição' : `Continuar com ${nextTitle}`}
                onPress={resume}
                style={({ pressed }) => [styles.startButton, (!ready || busy || !nextId) && styles.disabledButton, pressed && styles.pressed]}>
                <Text style={styles.startButtonLabel}>{allDone ? 'Revisar lição' : 'Continuar aprendendo'}</Text>
                <View style={styles.startButtonArrow}><Text style={styles.startArrowText}>→</Text></View>
              </Pressable>
            </View>

            <View style={styles.miniStats}>
              <View style={styles.miniStat}>
                <Text style={styles.miniStatValue}>{formatNumber(completed)}</Text>
                <Text style={styles.miniStatCaption}>LIÇÕES FEITAS</Text>
              </View>
              <View style={styles.miniSeparator} />
              <View style={styles.miniStat}>
                <Text style={styles.miniStatValue}>{settings?.dailyGoalMinutes ?? '—'} <Text style={styles.miniStatUnit}>min</Text></Text>
                <Text style={styles.miniStatCaption}>META DIÁRIA</Text>
              </View>
              <View style={styles.miniSeparator} />
              <View style={styles.miniStat}>
                <Text style={styles.miniStatValue}>{formatNumber(orderedIds.length)}</Text>
                <Text style={styles.miniStatCaption}>LIÇÕES NO CURSO</Text>
              </View>
            </View>
          </View>

          <View style={styles.learningSurface}>
            <View style={styles.journeyHeading}>
              <View style={styles.headingCopy}>
                <Text style={styles.eyebrow}>O CAMINHO É SEU</Text>
                <Text style={styles.journeyTitle}>Sua jornada</Text>
                <Text style={styles.journeySubtitle}>Uma conquista de cada vez.</Text>
              </View>
              <View style={styles.journeyCount}><Text style={styles.journeyCountText}>{completed}/{orderedIds.length}</Text></View>
            </View>

            <View style={styles.unitBanner}>
              <View style={styles.unitEmblem}><Text style={styles.unitEmblemText}>01</Text></View>
              <View style={styles.unitContent}>
                <Text style={styles.unitOverline}>ITALIANO · A1 · UNIDADE 01</Text>
                <Text style={styles.unitName}>Primeiros passos</Text>
                <Text style={styles.unitSubtitle}>Comece a falar desde a primeira lição</Text>
              </View>
            </View>
            <View style={styles.offlineBadge}><View style={styles.offlineDot} /><Text style={styles.offlineText}>Disponível offline neste aparelho</Text></View>

            <View style={styles.pathList}>
              {!ready ? <ActivityIndicator color={BLUE} style={styles.spinner} /> : LESSONS.map((lesson, index) => (
                <LessonTile key={lesson.id} title={lesson.title} subtitle={lesson.subtitle}
                  exerciseCount={lesson.exercises.length} number={index + 1}
                  done={completedIds.includes(lesson.id)} unlocked={canStartLesson(lesson.id, orderedIds, progress)}
                  busy={busy} last={index === LESSONS.length - 1}
                  onPress={() => router.push({ pathname: '/lesson/[lessonId]', params: { lessonId: lesson.id } })} />
              ))}
            </View>

            {!coursesReady && <ActivityIndicator color={BLUE} style={styles.spinner} />}
            {italianUnits.map(unit => {
              const offline = downloaded(unit);
              return <View key={`${unit.id}-r${unit.revision}`} style={styles.remoteSection}>
                <View style={styles.remoteHeader}>
                  <View style={styles.remoteNumber}><Text style={styles.remoteNumberText}>{formatNumber(unit.order)}</Text></View>
                  <View style={styles.unitContent}>
                    <Text style={styles.remoteOverline}>ITALIANO {unit.level} · UNIDADE {formatNumber(unit.order)}</Text>
                    <Text style={styles.remoteTitle}>{unit.title}</Text>
                    <Text style={styles.remoteSubtitle}>{unit.subtitle}</Text>
                  </View>
                </View>
                <View style={styles.remoteActions}>
                  <View style={styles.remoteAvailability}>
                    <View style={[styles.availabilityDot, offline && styles.availabilityOffline]} />
                    <Text style={styles.availabilityText}>{offline ? 'Salva offline' : 'Conteúdo online'}</Text>
                  </View>
                  {!offline ? <Pressable accessibilityRole="button" accessibilityLabel={`Baixar ${unit.title} para estudar offline`}
                    disabled={busy} onPress={() => { void run(() => download(unit), 'Confira a conexão. Todas as gravações obrigatórias precisam estar disponíveis.'); }}>
                    <Text style={styles.remoteActionLabel}>{busy ? 'Aguarde…' : '↓ Baixar unidade'}</Text>
                  </Pressable> : <Pressable accessibilityRole="button" accessibilityLabel={`Remover download de ${unit.title}`}
                    disabled={busy} onPress={() => removeDownloadedUnit(unit)}>
                    <Text style={styles.remoteRemoveLabel}>Remover download</Text>
                  </Pressable>}
                </View>
                <View style={styles.pathList}>
                  {unit.lessons.map((lesson, index) => (
                    <LessonTile key={lesson.id} title={lesson.title} subtitle={lesson.subtitle}
                      exerciseCount={lesson.exerciseCount} number={orderedIds.indexOf(lesson.id) + 1}
                      done={completedIds.includes(lesson.id)}
                      unlocked={ready && canStartLesson(lesson.id, orderedIds, progress)} busy={busy}
                      last={index === unit.lessons.length - 1}
                      onPress={() => openRemoteLesson(unit, lesson.id)} />
                  ))}
                </View>
              </View>;
            })}

            <Pressable accessibilityRole="button" accessibilityLabel="Explorar outras unidades"
              onPress={() => router.push('/courses')}
              style={({ pressed }) => [styles.exploreCard, pressed && styles.pressed]}>
              <View style={styles.exploreIcon}><View style={styles.exploreBook}><View style={styles.exploreBookLine} /></View></View>
              <View style={styles.exploreContent}>
                <Text style={styles.exploreTitle}>Explore outras unidades</Text>
                <Text style={styles.exploreSubtitle}>Novos conteúdos e downloads</Text>
              </View>
              <View style={styles.exploreArrowCircle}><Text style={styles.exploreArrow}>→</Text></View>
            </Pressable>
            {coursesReady && italianUnits.length === 0 &&
              <Text style={styles.nextHint}>Novas unidades aparecerão aqui assim que forem publicadas.</Text>}
            <Text style={styles.closingText}>Seu próximo capítulo começa a cada lição.</Text>
          </View>
        </ScrollView>

        <View style={styles.dockArea}>
          <View style={styles.dock}>
            <DockItem title="Aprender" kind="learn" selected onPress={() => router.replace('/')} />
            <DockItem title="Cursos" kind="courses" selected={false} onPress={() => router.push('/courses')} />
            <DockItem title="Perfil" kind="profile" selected={false} onPress={() => router.push('/profile')} />
          </View>
        </View>
      </View>
    </Page>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: PAPER },
  scroll: { flex: 1 },
  scrollContent: { paddingBottom: 14 },
  darkSection: { backgroundColor: NAVY, paddingHorizontal: 22, paddingTop: 15, paddingBottom: 43, overflow: 'hidden' },
  ambientTop: { position: 'absolute', top: -235, right: -174, width: 405, height: 405, borderRadius: 215, backgroundColor: '#0B3054', opacity: 0.8 },
  ambientSmall: { position: 'absolute', top: 171, left: -220, width: 330, height: 330, borderRadius: 165, backgroundColor: '#0A345B', opacity: 0.35 },
  brandRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  brandIdentity: { alignItems: 'flex-start', justifyContent: 'center' },
  brandLogo: { width: 162, height: 52 },
  brandCaption: { marginTop: 0, marginLeft: 3, color: '#B8CDE4', fontSize: 11, fontWeight: '700', letterSpacing: 0.35 },
  avatar: { width: 46, height: 46, borderRadius: 16, borderWidth: 1, borderColor: '#315270', backgroundColor: '#153451', alignItems: 'center', justifyContent: 'center' },
  badgeRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginTop: 19 },
  languageChip: { flexDirection: 'row', alignItems: 'center', borderRadius: 13, backgroundColor: '#153C5C', borderWidth: 1, borderColor: '#245479', paddingVertical: 9, paddingHorizontal: 12, gap: 8 },
  languageFlag: { fontSize: 17 },
  languageLabel: { color: '#E9F4FF', fontSize: 11, fontWeight: '900', letterSpacing: 0.8 },
  languageLevel: { color: '#8FCBFF' },
  xpChip: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 13, paddingVertical: 11, borderRadius: 14, backgroundColor: '#223A4A', gap: 8 },
  xpGem: { width: 9, height: 9, transform: [{ rotate: '45deg' }], backgroundColor: GOLD, borderRadius: 2 },
  xpNumber: { fontSize: 12, fontWeight: '900', color: '#FFE0AF' },
  streakBanner: { marginTop: 17, paddingVertical: 13, paddingHorizontal: 14, backgroundColor: '#102E4F',
    borderWidth: 1, borderColor: '#30547A', borderRadius: 18, flexDirection: 'row', alignItems: 'center', gap: 10 },
  streakFlame: { width: 41, height: 41, borderRadius: 14, backgroundColor: '#173D63', alignItems: 'center', justifyContent: 'center' },
  streakFlameIcon: { fontSize: 22 },
  streakCopy: { flex: 1 },
  streakTitle: { color: '#F5F8FF', fontSize: 15, fontWeight: '900' },
  streakSubtitle: { color: '#A9C5E4', fontSize: 10, lineHeight: 15, marginTop: 3 },
  streakToday: { color: '#FFCA88', fontSize: 9, fontWeight: '900', letterSpacing: 0.5 },
  heroIntroduction: { marginTop: 21, marginBottom: 18 },
  sectionOverline: { fontSize: 10, fontWeight: '900', color: GOLD, letterSpacing: 2.0 },
  introductionTitle: { color: '#F5F9FF', fontSize: 26, fontWeight: '900', letterSpacing: -0.8, lineHeight: 32, marginTop: 9 },
  introductionSubtitle: { fontSize: 13, color: '#A5BEDB', marginTop: 10, lineHeight: 20 },
  heroCard: { backgroundColor: '#12365D', borderRadius: 26, padding: 19, borderWidth: 1, borderColor: '#26557C', overflow: 'hidden' },
  heroCircleBig: { position: 'absolute', right: -85, top: -120, height: 255, width: 255, borderRadius: 128, backgroundColor: '#20598B', opacity: 0.39 },
  heroCircleSmall: { position: 'absolute', right: -70, top: 57, height: 164, width: 164, borderRadius: 82, borderColor: '#72B7F0', borderWidth: 1, opacity: 0.2 },
  heroCardTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  heroStatus: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  heroStatusDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: '#7DD9D6' },
  heroStatusText: { color: '#BBD9F6', fontSize: 9, fontWeight: '900', letterSpacing: 1.1 },
  heroNumberBadge: { height: 31, width: 35, borderRadius: 11, borderWidth: 1, borderColor: '#578AB4', backgroundColor: '#25527B', justifyContent: 'center', alignItems: 'center' },
  heroNumberText: { color: '#DFF2FF', fontSize: 13, fontWeight: '900' },
  heroTitle: { color: '#FFFFFF', fontSize: 28, fontWeight: '900', lineHeight: 34, letterSpacing: -0.7, marginTop: 15 },
  heroText: { color: '#B8D3EB', fontSize: 13.5, lineHeight: 20, marginTop: 6 },
  heroDivider: { height: 1, backgroundColor: '#3A6487', marginTop: 23, marginBottom: 17, opacity: 0.9 },
  heroProgressRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 },
  heroProgressLabel: { color: '#A4C1DD', fontSize: 9, fontWeight: '900', letterSpacing: 1 },
  heroProgressNumber: { color: '#E1F3FF', fontSize: 12, fontWeight: '900' },
  progressTrack: { height: 7, borderRadius: 6, backgroundColor: '#355C7C', overflow: 'hidden' },
  progressFill: { height: '100%', borderRadius: 6, backgroundColor: SKY },
  startButton: { height: 54, marginTop: 22, backgroundColor: SKY, borderRadius: 15, alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 15, flexDirection: 'row' },
  startButtonLabel: { fontWeight: '900', color: NAVY, fontSize: 14.5, marginLeft: 5, flexShrink: 1 },
  startButtonArrow: { width: 35, height: 35, borderRadius: 11, backgroundColor: '#63B2F6', alignItems: 'center', justifyContent: 'center' },
  startArrowText: { color: NAVY, fontWeight: '800', fontSize: 23, marginTop: -2 },
  disabledButton: { opacity: 0.55 },
  pressed: { opacity: 0.74 },
  miniStats: { flexDirection: 'row', alignItems: 'center', marginTop: 18, paddingHorizontal: 3 },
  miniStat: { flex: 1, alignItems: 'center', gap: 6 },
  miniStatValue: { color: '#ECF8FF', fontSize: 22, fontWeight: '900', letterSpacing: -0.4 },
  miniStatUnit: { color: '#D1E7FA', fontWeight: '600', fontSize: 12 },
  miniStatCaption: { color: '#8FAAC3', fontSize: 8, fontWeight: '800', letterSpacing: 0.8, textAlign: 'center' },
  miniSeparator: { height: 32, width: 1, backgroundColor: '#29445E' },
  learningSurface: { backgroundColor: PAPER, marginTop: -24, borderTopLeftRadius: 29, borderTopRightRadius: 29, paddingTop: 32, paddingHorizontal: 20, paddingBottom: 29 },
  journeyHeading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 24 },
  headingCopy: { flex: 1 },
  eyebrow: { fontSize: 9, letterSpacing: 1.7, fontWeight: '900', color: '#3776D3' },
  journeyTitle: { color: INK, fontSize: 27, fontWeight: '900', letterSpacing: -0.85, marginTop: 5 },
  journeySubtitle: { color: MUTED, fontSize: 12, marginTop: 3 },
  journeyCount: { borderRadius: 13, paddingHorizontal: 13, paddingVertical: 9, backgroundColor: '#E4EEFC' },
  journeyCountText: { color: '#2B6DCA', fontSize: 12, fontWeight: '900' },
  unitBanner: { flexDirection: 'row', alignItems: 'center', padding: 17, backgroundColor: '#DDEAFE', borderRadius: 20, gap: 13 },
  unitEmblem: { width: 51, height: 55, backgroundColor: '#FFFFFF', borderRadius: 15, justifyContent: 'center', alignItems: 'center', borderWidth: 1, borderColor: '#C2D6F6' },
  unitEmblemText: { color: BLUE, fontSize: 20, fontWeight: '900' },
  unitContent: { flex: 1 },
  unitOverline: { color: '#4D7EC2', fontSize: 9, fontWeight: '900', letterSpacing: 0.8 },
  unitName: { color: INK, fontSize: 17, fontWeight: '900', marginTop: 3 },
  unitSubtitle: { color: '#637E9F', fontSize: 11, lineHeight: 16, marginTop: 4 },
  offlineBadge: { flexDirection: 'row', alignItems: 'center', gap: 7, paddingVertical: 14, paddingHorizontal: 8 },
  offlineDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: '#25AB86' },
  offlineText: { fontSize: 11, fontWeight: '700', color: '#378D76' },
  pathList: { marginTop: 3 },
  pathStep: { flexDirection: 'row', alignItems: 'stretch', minHeight: 139, gap: 9 },
  rail: { width: 57, alignItems: 'center', paddingTop: 16 },
  lessonOrbHalo: { width: 55, height: 55, borderRadius: 28, borderWidth: 1, borderColor: '#B2D0FF', backgroundColor: '#E3EFFF', alignItems: 'center', justifyContent: 'center' },
  orbHaloDone: { backgroundColor: '#DDF8EA', borderColor: '#BCEBD4' },
  orbHaloLocked: { backgroundColor: '#F0F3F7', borderColor: '#E3E9F0' },
  lessonOrb: { width: 44, height: 44, borderRadius: 23, justifyContent: 'center', alignItems: 'center' },
  orbActive: { backgroundColor: BLUE },
  orbDone: { backgroundColor: '#2BAF84' },
  orbLocked: { backgroundColor: '#BDCBDB' },
  orbSymbol: { fontSize: 19, color: '#FFFFFF', fontWeight: '900' },
  orbSymbolLocked: { color: '#F4F7FC', fontSize: 16 },
  railLine: { backgroundColor: '#D5E3F5', width: 3, flex: 1, borderRadius: 4, marginVertical: 4 },
  railLineDone: { backgroundColor: '#9CDDC6' },
  lessonCard: { flex: 1, marginBottom: 13, padding: 15, backgroundColor: '#FFFFFF', borderRadius: 19, borderWidth: 1, borderColor: '#E2EAF5', minWidth: 0 },
  lessonCardActive: { borderColor: '#75ABFF', backgroundColor: '#FFFFFF', elevation: 3, shadowColor: '#3E79C9', shadowOffset: { width: 0, height: 3 }, shadowOpacity: 0.11, shadowRadius: 9 },
  lessonCardDone: { backgroundColor: '#FBFFFD', borderColor: '#D6EEE4' },
  lessonCardLocked: { opacity: 0.61 },
  lessonCardTop: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 6 },
  lessonEyebrow: { color: '#4E86DB', fontSize: 8.5, fontWeight: '900', letterSpacing: 0.5, flexShrink: 1 },
  eyebrowDone: { color: '#319A78' },
  eyebrowLocked: { color: '#8797AA' },
  lessonChevron: { color: BLUE, fontSize: 21, lineHeight: 20 },
  arrowDisabled: { color: '#A2AFBE' },
  lessonTitle: { color: INK, fontWeight: '900', fontSize: 17, letterSpacing: -0.2, marginTop: 9 },
  lessonSubtitle: { color: MUTED, fontSize: 12, marginTop: 5 },
  lessonCardFooter: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 5, marginTop: 14 },
  lessonExercisePill: { borderRadius: 8, backgroundColor: '#EFF5FD', paddingHorizontal: 9, paddingVertical: 6 },
  lessonExerciseText: { fontSize: 10, color: '#54769A', fontWeight: '700' },
  reviewText: { fontSize: 10, color: '#26936B', fontWeight: '800' },
  spinner: { marginVertical: 23 },
  remoteSection: { marginTop: 27 },
  remoteHeader: { flexDirection: 'row', alignItems: 'center', padding: 16, backgroundColor: '#E4ECFA', borderRadius: 20, gap: 12 },
  remoteNumber: { width: 51, height: 55, backgroundColor: '#FFFFFF', borderRadius: 15, justifyContent: 'center', alignItems: 'center' },
  remoteNumberText: { color: BLUE, fontSize: 19, fontWeight: '900' },
  remoteOverline: { color: '#517FC3', fontSize: 9, fontWeight: '900', letterSpacing: 0.7 },
  remoteTitle: { color: INK, fontSize: 17, fontWeight: '900', marginTop: 4 },
  remoteSubtitle: { color: '#6A80A1', fontSize: 11, marginTop: 3 },
  remoteActions: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 8, paddingVertical: 17, paddingHorizontal: 4 },
  remoteAvailability: { flexDirection: 'row', alignItems: 'center', gap: 6, flexShrink: 1 },
  availabilityDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: '#6797D4' },
  availabilityOffline: { backgroundColor: '#21A97D' },
  availabilityText: { color: '#64819D', fontSize: 10.5, fontWeight: '700' },
  remoteActionLabel: { color: '#2670D9', fontSize: 11, fontWeight: '900' },
  remoteRemoveLabel: { color: '#7989A0', fontSize: 11, fontWeight: '700' },
  exploreCard: { flexDirection: 'row', alignItems: 'center', gap: 13, marginTop: 22, padding: 16, backgroundColor: '#FFFFFF', borderColor: '#DCE7F6', borderWidth: 1, borderRadius: 21 },
  exploreIcon: { width: 48, height: 48, borderRadius: 15, backgroundColor: '#E8F2FF', justifyContent: 'center', alignItems: 'center' },
  exploreBook: { width: 24, height: 22, borderRadius: 3, borderWidth: 2, borderColor: BLUE, justifyContent: 'center', alignItems: 'center' },
  exploreBookLine: { width: 2, height: 18, backgroundColor: BLUE },
  exploreContent: { flex: 1 },
  exploreTitle: { fontSize: 14.5, fontWeight: '900', color: INK },
  exploreSubtitle: { color: MUTED, fontSize: 11, marginTop: 4 },
  exploreArrowCircle: { width: 30, height: 30, backgroundColor: '#EAF2FF', borderRadius: 11, justifyContent: 'center', alignItems: 'center' },
  exploreArrow: { color: BLUE, fontSize: 20, marginTop: -2 },
  nextHint: { marginTop: 12, paddingHorizontal: 15, fontSize: 11, color: '#8A9DB4', textAlign: 'center', lineHeight: 17 },
  closingText: { color: '#9AA9BC', textAlign: 'center', fontSize: 11.5, marginTop: 25 },
  dockArea: { backgroundColor: PAPER, paddingTop: 7, paddingHorizontal: 16, paddingBottom: 2 },
  dock: { borderWidth: 1, borderColor: '#E0E9F4', backgroundColor: '#FFFFFF', borderRadius: 23, height: 67, flexDirection: 'row', padding: 6, elevation: 8, shadowColor: '#214C81', shadowOpacity: 0.08, shadowOffset: { width: 0, height: -2 }, shadowRadius: 13 },
  dockItem: { flex: 1, borderRadius: 17, alignItems: 'center', justifyContent: 'center', gap: 3 },
  dockItemSelected: { backgroundColor: '#EAF3FF' },
  dockLabel: { color: '#94A4BB', fontSize: 10, fontWeight: '700' },
  dockLabelSelected: { color: BLUE, fontWeight: '900' },
  iconCanvas: { width: 23, height: 24, alignItems: 'center', justifyContent: 'center' },
  homeRoof: { position: 'absolute', top: 2, width: 14, height: 14, borderLeftWidth: 2, borderTopWidth: 2, transform: [{ rotate: '45deg' }], borderTopLeftRadius: 2 },
  homeBody: { width: 17, height: 12, borderLeftWidth: 2, borderRightWidth: 2, borderBottomWidth: 2, position: 'absolute', bottom: 2, alignItems: 'center', justifyContent: 'flex-end', borderBottomLeftRadius: 2, borderBottomRightRadius: 2 },
  homeDoor: { width: 5, height: 7, borderTopLeftRadius: 2, borderTopRightRadius: 2 },
  bookShape: { width: 22, height: 18, borderWidth: 2, borderTopLeftRadius: 5, borderBottomLeftRadius: 3, borderTopRightRadius: 5, borderBottomRightRadius: 3, justifyContent: 'center', alignItems: 'center' },
  bookCenter: { width: 2, height: 15 },
  personHead: { width: 10, height: 10, borderWidth: 2, borderRadius: 5, position: 'absolute', top: 1 },
  personShoulders: { width: 21, height: 10, borderWidth: 2, borderBottomWidth: 0, borderTopLeftRadius: 13, borderTopRightRadius: 13, position: 'absolute', bottom: 2 },
});
