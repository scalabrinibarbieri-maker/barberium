import { useEffect, useMemo, useRef, useState } from 'react';
import { Animated, Pressable, StyleSheet, Text, View } from 'react-native';
import { canUseLetterBank, composeLetterAnswer, makeLetterTiles } from '../features/learning/letterBank';

const NAVY = '#102A48';
const BLUE = '#2C70DC';

/** Montado apenas no modo Letras: o teclado fica fechado e a resposta é construída por toques. */
export function LetterBank({ sample, exerciseId, checked, onAnswer }: {
  sample: string; exerciseId: string; checked: boolean; onAnswer: (value: string) => void;
}) {
  const [seed] = useState(() => Date.now() + exerciseId.split('').reduce((n, c) => n + c.charCodeAt(0), 0));
  const tiles = useMemo(() => makeLetterTiles(sample, seed), [sample, seed]);
  const [picked, setPicked] = useState<number[]>([]);
  const entrance = useRef(new Animated.Value(0)).current;
  const tapScale = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    const animation = Animated.spring(entrance, { toValue: 1, friction: 8, tension: 60, useNativeDriver: true });
    animation.start();
    return () => animation.stop();
  }, [entrance]);

  const submit = (updated: number[]) => {
    if (checked) return;
    setPicked(updated);
    onAnswer(composeLetterAnswer(sample, tiles, updated));
    tapScale.setValue(0.975);
    Animated.spring(tapScale, { toValue: 1, friction: 4, tension: 175, useNativeDriver: true }).start();
  };
  const used = new Set(picked);
  const result = composeLetterAnswer(sample, tiles, picked);

  if (!canUseLetterBank(sample)) return <Text style={styles.note}>Esta resposta é longa. Use o teclado para escrevê-la.</Text>;

  return <Animated.View style={[styles.container, { opacity: entrance,
    transform: [{ translateY: entrance.interpolate({ inputRange: [0, 1], outputRange: [13, 0] }) }] }]}>
    <Text style={styles.caption}>MONTE SUA RESPOSTA</Text>
    <Animated.View style={[styles.answerBox, { transform: [{ scale: tapScale }] }]}>
      <Text accessibilityLiveRegion="polite" style={[styles.answerText, !result && styles.placeholder]}>
        {result || 'Toque nas letras abaixo'}
      </Text>
      <Text style={styles.answerCount}>{picked.length}/{tiles.length}</Text>
    </Animated.View>
    <View style={styles.controls}>
      <Text style={styles.guidance}>Toque na ordem desejada</Text>
      <View style={styles.controlActions}>
        <Pressable accessibilityRole="button" accessibilityLabel="Apagar última letra" disabled={checked || !picked.length}
          onPress={() => submit(picked.slice(0, -1))} style={styles.smallButton}>
          <Text style={[styles.controlText, (!picked.length || checked) && styles.dim]}>⌫  Apagar</Text>
        </Pressable>
        <Pressable accessibilityRole="button" accessibilityLabel="Limpar resposta" disabled={checked || !picked.length}
          onPress={() => submit([])} style={styles.smallButton}>
          <Text style={[styles.controlText, (!picked.length || checked) && styles.dim]}>Limpar</Text>
        </Pressable>
      </View>
    </View>
    <View style={styles.letters}>
      {tiles.map(tile => {
        const taken = used.has(tile.id);
        return <Pressable key={`${exerciseId}-${tile.id}`} accessibilityRole="button"
          accessibilityLabel={`Letra ${tile.letter}${taken ? ', usada' : ''}`}
          accessibilityState={{ disabled: checked || taken }} disabled={checked || taken}
          onPress={() => submit([...picked, tile.id])}
          style={({ pressed }) => [styles.letter, taken && styles.taken,
            pressed && !taken && styles.pressed]}>
          <Text style={[styles.letterText, taken && styles.takenText]}>{tile.letter.toUpperCase()}</Text>
        </Pressable>;
      })}
    </View>
    <Text style={styles.note}>As letras estão embaralhadas. Você também pode voltar ao teclado.</Text>
  </Animated.View>;
}

const styles = StyleSheet.create({
  container: { marginTop: 2 },
  caption: { color: '#647F9C', fontSize: 10, fontWeight: '900', letterSpacing: 1.4, marginBottom: 11 },
  answerBox: { borderRadius: 17, borderColor: '#A8C8F3', borderWidth: 1.5, backgroundColor: '#F2F7FF', paddingHorizontal: 16,
    minHeight: 67, flexDirection: 'row', alignItems: 'center', gap: 10, justifyContent: 'space-between' },
  answerText: { color: NAVY, fontSize: 20, fontWeight: '800', flex: 1, lineHeight: 28 },
  placeholder: { color: '#899FB9', fontSize: 14, fontWeight: '600' },
  answerCount: { color: BLUE, fontSize: 11, fontWeight: '900' },
  controls: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginTop: 13, marginBottom: 13, gap: 4 },
  guidance: { color: '#768CA7', fontSize: 11, flexShrink: 1 },
  controlActions: { flexDirection: 'row', gap: 5 },
  smallButton: { borderRadius: 10, paddingVertical: 8, paddingHorizontal: 8, backgroundColor: '#E9F0FA' },
  controlText: { color: '#2766B8', fontSize: 11, fontWeight: '800' }, dim: { opacity: 0.4 },
  letters: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 8 },
  letter: { width: 48, minHeight: 52, alignItems: 'center', justifyContent: 'center', borderRadius: 13,
    backgroundColor: '#FFFFFF', borderWidth: 1.5, borderColor: '#D5E2F2', elevation: 2,
    shadowColor: '#22528C', shadowOpacity: 0.06, shadowRadius: 4, shadowOffset: { width: 0, height: 2 } },
  letterText: { fontSize: 19, fontWeight: '900', color: NAVY },
  taken: { backgroundColor: '#EAF1FA', borderColor: '#E4EAF3', elevation: 0, opacity: 0.37 },
  takenText: { color: '#94A7BE' }, pressed: { transform: [{ scale: 0.92 }], borderColor: BLUE, backgroundColor: '#E8F2FF' },
  note: { color: '#8497AF', fontSize: 11, lineHeight: 17, textAlign: 'center', marginTop: 15 },
});
