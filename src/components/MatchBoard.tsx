import { withoutReading } from '../features/typography/annotatedText';
import { useEffect, useMemo, useRef, useState } from 'react';
import { LearningText as Text } from './LearningText';
import { Animated, Easing, Pressable, StyleSheet, View } from 'react-native';
import type { Exercise, MatchExercise } from '../features/learning/types';
import { matchColumns, type ColumnLanguage } from '../features/learning/matchColumns';
import { encodeMatches } from '../features/learning/engine';
import { EMPTY_MATCH, PAIR_COLORS, pressMatch, rightColumnOrder, type MatchState, type Side } from '../features/learning/match';
import { palette } from '../constants/theme';
import type { CourseInfo } from '../features/courses/registry';
import { Flag } from './ui/Flag';
import { Icon } from './ui/Icon';

type TileState = 'idle' | 'selected' | 'paired' | 'correct' | 'wrong';

function rgba(hex: string, alpha: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
}

/**
 * V44: "Ligue as expressões" redesenhado (lógica pura e testada em features/learning/match.ts).
 * - Começa por qualquer lado; tocar em QUALQUER parte de um par desfaz o par (não importa qual foi tocada primeiro).
 * - Cada par ganha uma cor e um número próprios. Verde e vermelho só aparecem depois de "Verificar resposta".
 * - Animações no thread nativo: entrada em cascata, seleção que levanta, par que "encaixa", acerto que pulsa e erro que treme.
 * V61: o título de cada coluna vem do conteúdo (features/learning/matchColumns.ts): idioma do curso, português ou nenhum
 * (números, horários, letras). Antes a direita dizia sempre "PORTUGUÊS", mesmo com italiano dos dois lados.
 */
export function MatchBoard({ exercise, checked, onAnswer, course, flag, lesson }: {
  exercise: MatchExercise;
  checked: boolean;
  onAnswer: (encoded: string) => void;
  /** V43: idioma do curso (rótulo da coluna da esquerda). */
  course: Pick<CourseInfo, 'id' | 'name' | 'adjective' | 'upper'>;
  /** V44: bandeira da variante (ex.: gb, us). */
  flag?: string;
  /** V61: exercícios da lição, para reconhecer o idioma de cada coluna pelo vocabulário da própria lição. */
  lesson?: readonly Exercise[];
}) {
  const [board, setBoard] = useState<MatchState>(EMPTY_MATCH);
  const { selected, matches, colorOf } = board;
  const rightOrder = useMemo(() => rightColumnOrder(exercise.pairs, exercise.id), [exercise.pairs, exercise.id]);
  const columns = useMemo(() => matchColumns(exercise, course.id, lesson), [exercise, course.id, lesson]);
  const spoken = (lang: ColumnLanguage, label: string) => lang === 'course' ? `${course.name}: ${label}` : lang === 'portuguese' ? `Português: ${label}` : label;
  const leftOf = (rightId: string) => Object.keys(matches).find(id => matches[id] === rightId);
  const total = exercise.pairs.length;
  const formed = Object.keys(matches).length;

  useEffect(() => { if (checked) setBoard(b => (b.selected ? { ...b, selected: null } : b)); }, [checked]);

  const press = (side: Side, id: string) => {
    if (checked) return;
    const next = pressMatch(board, side, id);
    setBoard(next);
    if (next.matches !== board.matches) onAnswer(encodeMatches(next.matches));
  };

  const stateOf = (side: Side, id: string, leftId: string | undefined): TileState => {
    if (leftId !== undefined) {
      if (!checked) return 'paired';
      return matches[leftId] === leftId ? 'correct' : 'wrong';
    }
    return selected?.side === side && selected.id === id ? 'selected' : 'idle';
  };

  const correctCount = Object.keys(matches).filter(left => matches[left] === left).length;
  const pairLabel = (leftId: string) => `par ${(colorOf[leftId] ?? 0) + 1}`;

  return <View style={styles.wrap}>
    <View style={styles.guide}>
      <Icon name="info" size={15} color={palette.sky} strokeWidth={2.2} />
      <Text style={styles.hint}>Toque numa palavra de cada lado para formar o par. Para desfazer, toque em qualquer parte do par.</Text>
    </View>
    <View style={styles.columns}>
      <View style={styles.column}>
        <ColumnHeading language={columns.left} course={course} flag={flag} />
        {exercise.pairs.map((pair, i) => {
          const leftId = matches[pair.id] ? pair.id : undefined;
          const state = stateOf('left', pair.id, leftId);
          return <MatchTile key={pair.id} label={pair.left} state={state} index={i}
            color={leftId !== undefined ? PAIR_COLORS[colorOf[leftId] ?? 0] : undefined}
            badge={leftId !== undefined ? String((colorOf[leftId] ?? 0) + 1) : undefined}
            candidate={!checked && selected?.side === 'right' && state === 'idle'}
            disabled={checked} onPress={() => press('left', pair.id)}
            accessibilityLabel={`${spoken(columns.left, pair.left)}${state === 'selected' ? ', selecionado' : ''}${leftId !== undefined
              ? checked ? state === 'correct' ? ', associação correta' : ', associação incorreta' : `, ${pairLabel(leftId)}; toque para desfazer` : ''}`} />;
        })}
      </View>
      <View style={styles.column}>
        <ColumnHeading language={columns.right} course={course} flag={flag} />
        {rightOrder.map((pair, i) => {
          const leftId = leftOf(pair.id);
          const state = stateOf('right', pair.id, leftId);
          return <MatchTile key={pair.id} label={pair.right} state={state} index={total + i}
            color={leftId !== undefined ? PAIR_COLORS[colorOf[leftId] ?? 0] : undefined}
            badge={leftId !== undefined ? String((colorOf[leftId] ?? 0) + 1) : undefined}
            candidate={!checked && selected?.side === 'left' && state === 'idle'}
            disabled={checked} onPress={() => press('right', pair.id)}
            accessibilityLabel={`${spoken(columns.right, pair.right)}${state === 'selected' ? ', selecionado' : ''}${leftId !== undefined
              ? checked ? state === 'correct' ? ', associação correta' : ', associação incorreta' : `, ${pairLabel(leftId)}; toque para desfazer` : ''}`} />;
        })}
      </View>
    </View>
    <View style={styles.progressRow}>
      {exercise.pairs.map((pair, i) => {
        const left = Object.keys(matches)[i];
        const color = left === undefined ? null
          : checked ? (matches[left] === left ? palette.success : palette.danger) : PAIR_COLORS[colorOf[left] ?? 0];
        return <View key={pair.id} style={[styles.segment, color ? { backgroundColor: color } : null]} />;
      })}
    </View>
    <Text accessibilityLiveRegion="polite" style={styles.counter}>
      {checked ? `${correctCount} de ${total} pares corretos` : formed === total ? 'Todos os pares formados. Verifique a resposta.' : `${formed} de ${total} pares formados`}
    </Text>
  </View>;
}

/** Título da coluna; vazio (com a mesma altura) quando a coluna é só número, horário ou letra. */
function ColumnHeading({ language, course, flag }: { language: ColumnLanguage; course: Pick<CourseInfo, 'upper'>; flag?: string }) {
  if (language === 'neutral') return <View style={styles.headingRow} />;
  if (language === 'portuguese') return <View style={styles.headingRow}><Text style={styles.heading}>PORTUGUÊS</Text></View>;
  return <View style={styles.headingRow}>
    {flag ? <Flag country={flag} width={16} /> : null}
    <Text style={styles.heading}>{course.upper}</Text>
  </View>;
}

function MatchTile({ label, state, color, badge, candidate, index, disabled, onPress, accessibilityLabel }: {
  label: string; state: TileState; color?: string; badge?: string; candidate: boolean; index: number;
  disabled: boolean; onPress: () => void; accessibilityLabel: string;
}) {
  const appear = useRef(new Animated.Value(0)).current;
  const scale = useRef(new Animated.Value(1)).current;
  const shake = useRef(new Animated.Value(0)).current;
  const fill = useRef(new Animated.Value(0)).current;
  const verdict = useRef(new Animated.Value(0)).current;
  const glow = useRef(new Animated.Value(0)).current;
  const mounted = useRef(false);
  // Mantém a cor do par enquanto ela some (ao desfazer, a camada esmaece em vez de sumir de uma vez).
  const lastColor = useRef(color);
  if (color) lastColor.current = color;
  const tint = lastColor.current;

  useEffect(() => {
    const entrance = Animated.timing(appear, { toValue: 1, duration: 340, delay: 40 * index, easing: Easing.out(Easing.cubic), useNativeDriver: true });
    entrance.start();
    return () => entrance.stop();
  }, [appear, index]);

  useEffect(() => {
    const filled = state === 'paired' ? 1 : 0;
    const judged = state === 'correct' || state === 'wrong' ? 1 : 0;
    const lifted = state === 'selected' ? 1 : 0;
    if (!mounted.current) { mounted.current = true; fill.setValue(filled); verdict.setValue(judged); glow.setValue(lifted); return; }
    const spring = (toValue: number, stiffness = 260, damping = 14) => Animated.spring(scale, { toValue, stiffness, damping, mass: 0.7, useNativeDriver: true });
    const motion = state === 'selected' ? spring(1.045)
      : state === 'paired' ? Animated.sequence([Animated.timing(scale, { toValue: 0.92, duration: 90, useNativeDriver: true }), spring(1, 240, 9)])
      : state === 'correct' ? Animated.sequence([Animated.delay(30 * (index % 8)), spring(1.06, 320, 10), spring(1, 260, 12)])
      : state === 'wrong' ? Animated.sequence([Animated.delay(30 * (index % 8)), ...[-8, 8, -6, 6, -3, 0].map(x =>
        Animated.timing(shake, { toValue: x, duration: 55, easing: Easing.linear, useNativeDriver: true }))])
      : spring(1);
    const all = Animated.parallel([
      Animated.timing(fill, { toValue: filled, duration: 200, easing: Easing.out(Easing.cubic), useNativeDriver: true }),
      Animated.timing(verdict, { toValue: judged, duration: 240, easing: Easing.out(Easing.cubic), useNativeDriver: true }),
      Animated.timing(glow, { toValue: lifted, duration: 160, useNativeDriver: true }),
      motion,
    ]);
    all.start();
    return () => all.stop();
  }, [state, index, fill, verdict, glow, scale, shake]);

  const judgedColor = state === 'wrong' ? palette.danger : palette.success;
  const badgeColor = state === 'correct' ? palette.successDeep : state === 'wrong' ? palette.dangerDeep : color ?? palette.blue;
  return <Animated.View style={{ opacity: appear, transform: [
    { translateY: appear.interpolate({ inputRange: [0, 1], outputRange: [14, 0] }) }, { scale }, { translateX: shake }] }}>
    <Pressable accessibilityRole="button" accessibilityLabel={withoutReading(accessibilityLabel)}
      accessibilityState={{ selected: state === 'selected', disabled }} disabled={disabled} onPress={onPress}
      style={({ pressed }) => [styles.tile, candidate && styles.candidate, pressed && styles.pressed]}>
      {tint ? <Animated.View pointerEvents="none" style={[styles.layer, { opacity: fill, backgroundColor: rgba(tint, 0.2), borderColor: tint }]} /> : null}
      <Animated.View pointerEvents="none" style={[styles.layer, { opacity: verdict, backgroundColor: rgba(judgedColor, 0.2), borderColor: judgedColor }]} />
      <Animated.View pointerEvents="none" style={[styles.layer, styles.glow, { opacity: glow }]} />
      <Text style={[styles.tileText, state !== 'idle' && styles.strong]}>{label}</Text>
      {badge ? <View style={[styles.badge, { backgroundColor: badgeColor }]}>
        {state === 'correct' ? <Icon name="check" size={11} color="#FFFFFF" strokeWidth={3.2} />
          : state === 'wrong' ? <Icon name="close" size={11} color="#FFFFFF" strokeWidth={3.2} />
          : <Text style={styles.badgeText}>{badge}</Text>}
      </View> : null}
    </Pressable>
  </Animated.View>;
}

const styles = StyleSheet.create({
  wrap: { marginTop: 20, gap: 14 },
  guide: { flexDirection: 'row', alignItems: 'center', gap: 9, paddingHorizontal: 2 },
  hint: { flex: 1, color: palette.muted, fontSize: 12.5, lineHeight: 18 },
  columns: { flexDirection: 'row', gap: 10 },
  column: { flex: 1, gap: 10 },
  headingRow: { flexDirection: 'row', alignItems: 'center', gap: 7, height: 18, marginBottom: 1 },
  heading: { color: palette.muted, fontSize: 11.5, fontWeight: '800', letterSpacing: 1.1 },
  tile: { minHeight: 62, borderRadius: 18, borderWidth: 1.3, borderColor: 'rgba(138,180,235,0.22)', backgroundColor: 'rgba(16,38,68,0.74)',
    alignItems: 'center', justifyContent: 'center', paddingVertical: 12, paddingHorizontal: 22, overflow: 'hidden' },
  candidate: { borderColor: 'rgba(140,200,255,0.5)' },
  layer: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, borderRadius: 18, borderWidth: 1.6 },
  glow: { borderColor: palette.skyLight, backgroundColor: 'rgba(84,150,240,0.24)' },
  tileText: { color: palette.text, fontSize: 15, fontWeight: '700', textAlign: 'center', lineHeight: 20 },
  strong: { fontWeight: '900', color: '#FFFFFF' },
  badge: { position: 'absolute', top: 6, right: 6, minWidth: 18, height: 18, borderRadius: 9, paddingHorizontal: 4,
    alignItems: 'center', justifyContent: 'center' },
  badgeText: { color: palette.ink, fontSize: 11, fontWeight: '900' },
  progressRow: { flexDirection: 'row', gap: 5, marginTop: 2 },
  segment: { flex: 1, height: 5, borderRadius: 3, backgroundColor: 'rgba(138,180,235,0.16)' },
  counter: { textAlign: 'center', color: palette.muted, fontSize: 11.5, lineHeight: 17 },
  pressed: { opacity: 0.85 },
});
