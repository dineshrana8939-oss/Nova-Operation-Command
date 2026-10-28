// ─── Territory paint geometry (browser side) ───────────────────────────────────
// Mirrors server/modules/territory_geo.lua: a painted territory is a set of cells on a world grid and is stored as row
// spans [iy, ix0, ix1]. Cell (ix, iy) covers world x in [ix*cs, (ix+1)*cs), y in [iy*cs, (iy+1)*cs).
// The brush, the eraser, undo and redo are all plain set operations on those cells.

export const OFFSET = 32768;
export const SPAN = 65536;
const MAX_INDEX = OFFSET - 2;

export const cellKey = (ix, iy) => (iy + OFFSET) * SPAN + (ix + OFFSET);
export const cellOf = (k) => ({ ix: (k % SPAN) - OFFSET, iy: Math.floor(k / SPAN) - OFFSET });

export function cellsFromSpans(spans) {
  const set = new Set();
  for (const s of spans || []) {
    const iy = s[0];
    for (let ix = s[1]; ix <= s[2]; ix++) set.add(cellKey(ix, iy));
  }
  return set;
}

export function spansFromCells(set) {
  const rows = new Map();
  for (const k of set) {
    const { ix, iy } = cellOf(k);
    let list = rows.get(iy);
    if (!list) rows.set(iy, (list = []));
    list.push(ix);
  }
  const out = [];
  const iys = [...rows.keys()].sort((a, b) => a - b);
  for (const iy of iys) {
    const list = rows.get(iy).sort((a, b) => a - b);
    let x0 = list[0];
    let prev = list[0];
    for (let i = 1; i < list.length; i++) {
      if (list[i] !== prev + 1) {
        out.push([iy, x0, prev]);
        x0 = list[i];
      }
      prev = list[i];
    }
    out.push([iy, x0, prev]);
  }
  return out;
}

export function countSpans(spans) {
  let n = 0;
  for (const s of spans || []) n += s[2] - s[1] + 1;
  return n;
}

// Paints (add) or erases (!add) every cell whose CENTRE lies inside the circle. Returns how many cells changed.
export function stampCircle(set, x, y, radius, cs, add, onCell) {
  const r2 = radius * radius;
  const ix0 = Math.floor((x - radius) / cs);
  const ix1 = Math.floor((x + radius) / cs);
  const iy0 = Math.floor((y - radius) / cs);
  const iy1 = Math.floor((y + radius) / cs);
  let changed = 0;
  for (let iy = iy0; iy <= iy1; iy++) {
    if (iy < -MAX_INDEX || iy > MAX_INDEX) continue;
    const cy = (iy + 0.5) * cs - y;
    for (let ix = ix0; ix <= ix1; ix++) {
      if (ix < -MAX_INDEX || ix > MAX_INDEX) continue;
      const cx = (ix + 0.5) * cs - x;
      if (cx * cx + cy * cy > r2) continue;
      const k = cellKey(ix, iy);
      if (add) {
        if (!set.has(k)) { set.add(k); changed++; if (onCell) onCell(ix, iy, true); }
      } else if (set.delete(k)) { changed++; if (onCell) onCell(ix, iy, false); }
    }
  }
  return changed;
}

export const fillCircle = stampCircle;

// A stroke from (x0,y0) to (x1,y1): stamps along the segment so a fast drag leaves no gaps.
export function strokeSegment(set, x0, y0, x1, y1, radius, cs, add, onCell) {
  const dist = Math.hypot(x1 - x0, y1 - y0);
  const step = Math.max(cs * 0.5, radius * 0.35);
  const n = Math.max(1, Math.ceil(dist / step));
  let changed = 0;
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    changed += stampCircle(set, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, radius, cs, add, onCell);
  }
  return changed;
}

// Fills (add) or erases (!add) a bounding rectangle between (x0, y0) and (x1, y1).
export function fillRectangle(set, x0, y0, x1, y1, cs, add = true, onCell) {
  const minX = Math.min(x0, x1);
  const maxX = Math.max(x0, x1);
  const minY = Math.min(y0, y1);
  const maxY = Math.max(y0, y1);
  const ix0 = Math.floor(minX / cs);
  const ix1 = Math.floor(maxX / cs);
  const iy0 = Math.floor(minY / cs);
  const iy1 = Math.floor(maxY / cs);
  let changed = 0;
  for (let iy = iy0; iy <= iy1; iy++) {
    if (iy < -MAX_INDEX || iy > MAX_INDEX) continue;
    for (let ix = ix0; ix <= ix1; ix++) {
      if (ix < -MAX_INDEX || ix > MAX_INDEX) continue;
      const k = cellKey(ix, iy);
      if (add) {
        if (!set.has(k)) { set.add(k); changed++; if (onCell) onCell(ix, iy, true); }
      } else if (set.delete(k)) { changed++; if (onCell) onCell(ix, iy, false); }
    }
  }
  return changed;
}

// Fills (add) or erases (!add) a polygon formed by an array of 2D world points [{x, y}, ...].
// If 4 points are given, automatically closes the 4-point shape and rasterizes all enclosed cells.
export function fillPolygon(set, points, cs, add = true, onCell) {
  if (!points || points.length < 3) return 0;
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const p of points) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.y > maxY) maxY = p.y;
  }
  const ix0 = Math.floor(minX / cs);
  const ix1 = Math.floor(maxX / cs);
  const iy0 = Math.floor(minY / cs);
  const iy1 = Math.floor(maxY / cs);
  let changed = 0;
  const n = points.length;
  for (let iy = iy0; iy <= iy1; iy++) {
    if (iy < -MAX_INDEX || iy > MAX_INDEX) continue;
    const cy = (iy + 0.5) * cs;
    for (let ix = ix0; ix <= ix1; ix++) {
      if (ix < -MAX_INDEX || ix > MAX_INDEX) continue;
      const cx = (ix + 0.5) * cs;
      let inside = false;
      let j = n - 1;
      for (let i = 0; i < n; i++) {
        const pi = points[i];
        const pj = points[j];
        if (((pi.y > cy) !== (pj.y > cy)) && (cx < (pj.x - pi.x) * (cy - pi.y) / (pj.y - pi.y) + pi.x)) {
          inside = !inside;
        }
        j = i;
      }
      if (inside) {
        const k = cellKey(ix, iy);
        if (add) {
          if (!set.has(k)) { set.add(k); changed++; if (onCell) onCell(ix, iy, true); }
        } else if (set.delete(k)) { changed++; if (onCell) onCell(ix, iy, false); }
      }
    }
  }
  return changed;
}

// Bounding box (in cells) of one or more span lists, or null when empty.
export function bounds(...lists) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, n = 0;
  for (const spans of lists) {
    for (const s of spans || []) {
      n += s[2] - s[1] + 1;
      if (s[1] < minX) minX = s[1];
      if (s[2] > maxX) maxX = s[2];
      if (s[0] < minY) minY = s[0];
      if (s[0] > maxY) maxY = s[0];
    }
  }
  return n ? { minX, minY, maxX, maxY, cells: n } : null;
}

// World-space centroid of span lists (weighted by cells), or null when empty.
export function centroid(cs, ...lists) {
  let sx = 0, sy = 0, n = 0;
  for (const spans of lists) {
    for (const s of spans || []) {
      const len = s[2] - s[1] + 1;
      n += len;
      sx += ((s[1] + s[2] + 1) / 2) * len;
      sy += (s[0] + 0.5) * len;
    }
  }
  return n ? { x: (sx / n) * cs, y: (sy / n) * cs, cells: n } : null;
}

export function setHas(set, ix, iy) {
  return set.has(cellKey(ix, iy));
}

// Do two cell sets touch (side / corner neighbours, or overlap)? Used for the editor's live "touches X" hint — the server
// recomputes it authoritatively whenever it matters.
export function touching(a, b) {
  const [small, big] = a.size <= b.size ? [a, b] : [b, a];
  for (const k of small) {
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        if (big.has(k + dy * SPAN + dx)) return true;
      }
    }
  }
  return false;
}

export function hexToRgb(hex, fallback = [229, 72, 77]) {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(hex || '').trim());
  if (!m) return fallback;
  let h = m[1];
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  const n = parseInt(h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export const rgba = (hex, a) => {
  const [r, g, b] = hexToRgb(hex);
  return `rgba(${r},${g},${b},${a})`;
};

// A fresh territory area as the event form stores it.
export function blankArea(index, cfg = {}) {
  const d = cfg.auction?.defaults || {};
  return {
    id: `territory_${index}`,
    name: `Territory ${index}`,
    description: '',
    startingOwner: '',
    auctioned: true,
    startingBid: d.startingBid ?? 100000,
    minBidIncrement: d.minBidIncrement ?? 10000,
    order: index,
    xpValue: 0,
    color: cfg.defaultColor || '#e5484d',
    image: '',
    imagePos: null,
    showName: true,
    location: null,
    blip: { enabled: true, sprite: cfg.blip?.sprite ?? 310, colour: '', scale: cfg.blip?.scale ?? 0.85, shortRange: true, label: '' },
    base: { cs: cfg.cellSize || 25, spans: [] },
    expansions: [],
    capture: {
      enabled: true,
      ped: { model: cfg.war?.capture?.pedModel || 'g_m_y_mexgoon_01', x: null, y: null, z: null, heading: 0 },
      anim: { dict: cfg.war?.capture?.anim?.dict || '', clip: cfg.war?.capture?.anim?.clip || '' },
      seconds: cfg.war?.capture?.seconds ?? 60,
      radius: cfg.war?.capture?.radius ?? 6,
      interactDistance: cfg.war?.capture?.interactDistance ?? 2.5,
      contestRule: cfg.war?.capture?.contestRule || 'PAUSE',
    },
    props: [],
  };
}

export const slug = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9_-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 64);
