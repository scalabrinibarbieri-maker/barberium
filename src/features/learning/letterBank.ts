/** Letras embaralhadas para responder com uma mão. Não guarda nem revela a ordem correta. */
export type LetterTile = { id: number; letter: string };
const clean = (word: string) => Array.from(word.normalize('NFC')).filter(c => !/\s/u.test(c));
export function makeLetterTiles(sample: string, seed: number): LetterTile[] {
  const tiles = clean(sample).map((letter, id) => ({ id, letter }));
  let n = (seed >>> 0) || 0x9e3779b9;
  for (let i = tiles.length - 1; i > 0; i--) {
    n ^= n << 13; n ^= n >>> 17; n ^= n << 5;
    const j = (n >>> 0) % (i + 1);
    [tiles[i], tiles[j]] = [tiles[j]!, tiles[i]!];
  }
  // Nunca apresentar as letras diretamente na ordem da solução.
  if (tiles.length > 2 && tiles.every((tile, i) => tile.id === i)) tiles.reverse();
  return tiles;
}

export function composeLetterAnswer(sample: string, tiles: readonly LetterTile[], selected: readonly number[]): string {
  const byId = new Map(tiles.map(t => [t.id, t.letter]));
  const chars: string[] = [];
  const chosen = new Set<number>();
  for (const id of selected) {
    if (chosen.has(id) || !byId.has(id)) continue;
    chosen.add(id);
    chars.push(byId.get(id)!);
  }
  const words = sample.normalize('NFC').trim().split(/\s+/u).map(clean);
  const boundaries = new Set<number>();
  let count = 0;
  for (const word of words.slice(0, -1)) { count += word.length; boundaries.add(count); }
  return chars.map((c, index) => `${index > 0 && boundaries.has(index) ? ' ' : ''}${c}`).join('');
}

/** Evita exibir dezenas de chips num telefone pequeno. */
export function canUseLetterBank(sample: string): boolean {
  const total = clean(sample).length;
  return total >= 1 && total <= 42;
}
