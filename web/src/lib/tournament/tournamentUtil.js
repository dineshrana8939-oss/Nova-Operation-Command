// Shared by the on-screen tournament tree and the PNG/PDF export so both
// draw the exact same bracket from the exact same data.

export const CARD_W = 214;
export const CARD_H = 88;
export const COL_GAP = 58;
export const ROW_GAP = 16;

export function gangLabel(t, name) {
  if (!name) return null;
  return (t?.gangs && t.gangs[name]?.label) || name;
}

// What to print on one side of a match card: the real gang once known,
// otherwise the slot's placeholder ("GROUP A #1", "WINNER SF1"), or BYE.
export function slotText(t, side) {
  if (!side) return { text: 'TBD', tbd: true };
  if (side.gang) return { text: gangLabel(t, side.gang), tbd: false };
  if (side.bye) return { text: 'BYE', tbd: true, bye: true };
  return { text: side.src?.label || 'TBD', tbd: true };
}

export function formatClock(seconds) {
  if (seconds == null || isNaN(seconds)) return '--:--';
  const s = Math.max(0, Math.floor(seconds));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

// Lays the knockout rounds out on a fixed grid: round 1 stacked evenly, every
// later match centred between the two matches that feed it. Returns card
// boxes plus the elbow connectors between them.
export function layoutBracket(matches) {
  const ko = (matches || []).filter((m) => m.stage === 'KO');
  if (!ko.length) return { cards: [], lines: [], width: 0, height: 0, rounds: [] };

  const rounds = [];
  for (const m of ko) {
    (rounds[m.round - 1] = rounds[m.round - 1] || []).push(m);
  }
  rounds.forEach((r) => r.sort((a, b) => a.index - b.index));

  const pos = {}; // id -> { x, y }
  rounds.forEach((r, ri) => {
    r.forEach((m, i) => {
      const x = ri * (CARD_W + COL_GAP);
      let y;
      if (ri === 0) {
        y = i * (CARD_H + ROW_GAP);
      } else {
        const fa = pos[rounds[ri - 1][2 * i]?.id];
        const fb = pos[rounds[ri - 1][2 * i + 1]?.id];
        y = fa && fb ? (fa.y + fb.y) / 2 : (fa ? fa.y : 0);
      }
      pos[m.id] = { x, y };
    });
  });

  const cards = ko.map((m) => ({ m, x: pos[m.id].x, y: pos[m.id].y }));
  const lines = [];
  rounds.forEach((r, ri) => {
    if (ri === 0) return;
    r.forEach((m, i) => {
      for (const feeder of [rounds[ri - 1][2 * i], rounds[ri - 1][2 * i + 1]]) {
        if (!feeder) continue;
        const from = pos[feeder.id];
        const to = pos[m.id];
        const x1 = from.x + CARD_W;
        const y1 = from.y + CARD_H / 2;
        const x2 = to.x;
        const y2 = to.y + CARD_H / 2;
        const xm = x1 + COL_GAP / 2;
        lines.push({ from: feeder.id, to: m.id, d: `M${x1} ${y1} H${xm} V${y2} H${x2}` });
      }
    });
  });

  const width = rounds.length * CARD_W + (rounds.length - 1) * COL_GAP;
  const height = Math.max(...cards.map((c) => c.y + CARD_H));
  return { cards, lines, width, height, rounds };
}

// Everything the gang-specific view needs about "where am I": group + rank,
// the match they're in / about to play, opponent, next possible opponent,
// status, and the set of matches on their road to the final.
export function computeMyPath(t, gang) {
  if (!t || !gang || !t.cfg?.gangs?.includes(gang)) return null;

  let group = null;
  for (const g of t.groups || []) {
    if (g.gangs.includes(gang)) group = g;
  }
  const row = group?.standings?.find((r) => r.gang === gang) || null;

  const mine = (t.matches || []).filter((m) => m.a?.gang === gang || m.b?.gang === gang);
  const pending = mine.filter((m) => m.status !== 'COMPLETE').sort((a, b) => a.order - b.order);
  const current = mine.find((m) => m.status === 'LIVE') || pending[0] || null;

  const groupDone = !!t.qualified;
  const qualifiedEntry = (t.qualified || []).find((q) => q.gang === gang) || null;
  const lostKo = mine.some((m) => m.stage === 'KO' && m.status === 'COMPLETE' && m.winner && m.winner !== gang);

  let status = 'UPCOMING';
  if (t.champion === gang) status = 'CHAMPION';
  else if (t.status === 'CANCELLED') status = 'CANCELLED';
  else if ((groupDone && !qualifiedEntry) || lostKo) status = 'ELIMINATED';
  else if (current?.status === 'LIVE') status = 'LIVE';
  else if (groupDone && qualifiedEntry) status = 'QUALIFIED';

  let opponent = null;
  if (current) {
    const side = current.a?.gang === gang ? current.b : current.a;
    opponent = slotText(t, side).text;
  }

  // Downstream chain of knockout matches from `current` (their route to the final).
  const route = new Set();
  let nextOpponent = null;
  if (status !== 'ELIMINATED' && current) {
    let cursor = current.stage === 'KO' ? current : null;
    if (!cursor) {
      const seed = qualifiedEntry?.seed;
      cursor = (t.matches || []).find((m) => m.stage === 'KO' && m.round === 1 &&
        (m.a?.src?.seed === seed || m.b?.src?.seed === seed)) || null;
    }
    let first = true;
    while (cursor) {
      route.add(cursor.id);
      const next = (t.matches || []).find((m) => m.stage === 'KO' &&
        (m.a?.src?.match === cursor.id || m.b?.src?.match === cursor.id));
      if (next && first && current.stage === 'KO') {
        const other = next.a?.src?.match === cursor.id ? next.b : next.a;
        nextOpponent = slotText(t, other).text;
      }
      first = false;
      cursor = next || null;
    }
  }

  return { gang, group, row, current, opponent, nextOpponent, status, route, qualifiedEntry };
}

// One colour per gang for the tree's team stripes and legend: the gang's own
// accent colour when it has a usable one, otherwise a stable pick from a
// muted palette (same gang → same colour everywhere).
const GANG_PALETTE = ['#c75b63', '#5c91bd', '#62a879', '#9272ad', '#c08750', '#5e9d9c', '#cba14f', '#b5708f'];
export function gangColor(t, name) {
  if (!name) return null;
  const c = t?.gangs?.[name]?.accentColor;
  if (typeof c === 'string' && /^#[0-9a-f]{3,8}$/i.test(c)) return c;
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return GANG_PALETTE[h % GANG_PALETTE.length];
}
