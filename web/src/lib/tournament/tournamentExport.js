// Tournament tree export — PNG, PDF and CSV. The PNG is drawn from scratch on
// a canvas as a proper printed bracket (not a screenshot of the admin UI);
// the PDF is that same image wrapped in a one-page PDF.
//
// FiveM's NUI browser can't be relied on to honour a normal browser download,
// so every export returns bytes and the caller BOTH tries a browser download
// and offers to save the file on the server (tournament:saveExport).

import { CARD_W, CARD_H, COL_GAP, layoutBracket, slotText, gangLabel } from './tournamentUtil.js';

const FONT = "'Inter','Segoe UI',Arial,sans-serif";
const MONO = "'Inter','Segoe UI',Arial,sans-serif";
const C = {
  bg: '#0d0e14', panel: '#141620', panel2: '#171821', line: '#2b2d3b', text: '#d8d8e1',
  dim: '#b4b8c4', muted: '#b2b4c1', accent: '#368fe9', green: '#46d69a', red: '#ff5d50', gold: '#368fe9',
};

export function safeFileName(t, ext) {
  const base = String(t.name || 'tournament').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'tournament';
  return `${base}_edition${String(t.edition || 1).padStart(2, '0')}_${t.id}.${ext}`;
}

function fmtDate(t) {
  const ts = t.completedAt || t.startedAt || t.schedule?.startAt;
  return ts ? new Date(ts * 1000).toLocaleString() : '';
}

// ── CSV ──────────────────────────────────────────────────────────────────────

function csvCell(v) {
  const s = v == null ? '' : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function buildCsv(t) {
  const L = (g) => gangLabel(t, g) || '';
  const rows = [];
  const push = (...cells) => rows.push(cells.map(csvCell).join(','));

  push('Tournament', t.name);
  push('Edition', t.edition);
  push('Date', fmtDate(t));
  push('Status', t.status);
  push('Champion', t.champion ? L(t.champion) : '');
  push('Participating gangs', (t.cfg?.gangs || []).map(L).join(' | '));
  rows.push('');

  push('GROUP STANDINGS');
  push('Group', 'Rank', 'Gang', 'Played', 'Won', 'Drawn', 'Lost', 'Kills For', 'Kills Against', 'Diff', 'Points', 'Qualified');
  for (const g of t.groups || []) {
    for (const r of g.standings || []) {
      const q = t.qualified ? (r.rank <= t.cfg.advance ? 'YES' : 'NO') : '';
      push(g.name, r.rank, L(r.gang), r.played, r.won, r.drawn, r.lost, r.kf, r.ka, r.diff, r.points, q);
    }
  }
  rows.push('');

  push('MATCH RESULTS');
  push('Match', 'Stage', 'Team A', 'Score A', 'Score B', 'Team B', 'Winner', 'Status', 'Note');
  for (const m of t.matches || []) {
    const a = slotText(t, m.a).text;
    const b = slotText(t, m.b).text;
    const note = m.decidedBy === 'BYE' ? 'BYE' : (m.walkover ? 'Walkover' : (m.decidedBy === 'SEED' ? 'Decided by seed' : (m.doubleForfeit ? 'Double forfeit' : '')));
    push(m.label, m.stage === 'GROUP' ? 'Group' : m.roundName, a, m.status === 'COMPLETE' ? m.scoreA : '', m.status === 'COMPLETE' ? m.scoreB : '', b,
      m.winner ? L(m.winner) : '', m.status, note);
  }
  return rows.join('\r\n');
}

// ── PNG ──────────────────────────────────────────────────────────────────────

function fit(ctx, text, maxW) {
  if (ctx.measureText(text).width <= maxW) return text;
  let s = text;
  while (s.length > 1 && ctx.measureText(s + '…').width > maxW) s = s.slice(0, -1);
  return s + '…';
}

function rect(ctx, x, y, w, h, fill, stroke) {
  ctx.fillStyle = fill;
  ctx.fillRect(x, y, w, h);
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 1; ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1); }
}

function text(ctx, s, x, y, { size = 14, weight = 400, color = C.text, align = 'left', font = FONT, maxW } = {}) {
  ctx.font = `${weight} ${size}px ${font}`;
  ctx.fillStyle = color;
  ctx.textAlign = align;
  ctx.textBaseline = 'middle';
  ctx.fillText(maxW ? fit(ctx, s, maxW) : s, x, y);
}

// Two passes: the first only measures (dry run) so the canvas can be sized to
// fit exactly, the second draws.
function paint(ctx, t, dry) {
  const W = ctx.canvas.width;
  const PAD = 40;
  const L = (g) => gangLabel(t, g) || '';
  let y = 0;

  // Header
  if (!dry) rect(ctx, 0, 0, W, 132, C.panel);
  if (!dry) rect(ctx, 0, 128, W, 4, C.accent);
  text(ctx, (t.name || '').toUpperCase(), PAD, 46, { size: 32, weight: 800 });
  text(ctx, `EDITION ${String(t.edition || 1).padStart(2, '0')}  ·  ${fmtDate(t)}  ·  ${String(t.status || '').toUpperCase()}`, PAD, 82, { size: 14, color: C.dim, font: MONO });
  text(ctx, `${(t.cfg?.gangs || []).length} gangs  ·  ${t.cfg?.groupCount} group(s)  ·  top ${t.cfg?.advance} advance`, PAD, 106, { size: 13, color: C.muted, font: MONO });
  if (t.champion) {
    text(ctx, 'CHAMPION', W - PAD, 46, { size: 12, weight: 700, color: C.gold, align: 'right' });
    text(ctx, L(t.champion).toUpperCase(), W - PAD, 78, { size: 30, weight: 800, color: C.text, align: 'right' });
  }
  y = 132 + 34;

  // Participating gangs + group assignments + standings
  text(ctx, 'GROUP STAGE', PAD, y, { size: 13, weight: 800, color: C.accent });
  y += 22;
  const groups = t.groups || [];
  const gcols = Math.max(1, Math.min(groups.length, Math.floor((W - PAD * 2 + 16) / 470)));
  const gw = Math.floor((W - PAD * 2 - (gcols - 1) * 16) / gcols);
  let rowY = y;
  let maxH = 0;
  groups.forEach((g, gi) => {
    const col = gi % gcols;
    if (col === 0 && gi > 0) { rowY += maxH + 16; maxH = 0; }
    const x = PAD + col * (gw + 16);
    const rows = g.standings || [];
    const matches = (t.matches || []).filter((m) => m.stage === 'GROUP' && m.group === gi + 1);
    const h = 30 + 22 + rows.length * 26 + 10 + matches.length * 20 + 10;
    maxH = Math.max(maxH, h);
    if (dry) return;
    rect(ctx, x, rowY, gw, h, C.panel, C.line);
    rect(ctx, x, rowY, gw, 30, C.panel2);
    text(ctx, `GROUP ${g.name}`, x + 12, rowY + 15, { size: 13, weight: 800 });
    text(ctx, `TOP ${t.cfg.advance} QUALIFY`, x + gw - 12, rowY + 15, { size: 10, color: C.muted, align: 'right', weight: 700 });
    // column layout
    const cols = { rank: x + 14, name: x + 34, p: x + gw - 200, w: x + gw - 170, d: x + gw - 140, l: x + gw - 110, k: x + gw - 80, diff: x + gw - 50, pts: x + gw - 16 };
    let ry = rowY + 30 + 11;
    [['P', cols.p], ['W', cols.w], ['D', cols.d], ['L', cols.l], ['K', cols.k], ['+/-', cols.diff], ['PTS', cols.pts]].forEach(([s, cx]) =>
      text(ctx, s, cx, ry, { size: 10, color: C.muted, align: cx === cols.pts ? 'right' : 'center', weight: 700 }));
    ry += 15;
    rows.forEach((r) => {
      const q = t.qualified ? (r.rank <= t.cfg.advance ? 'Q' : 'E') : '';
      const dim = q === 'E';
      text(ctx, String(r.rank), cols.rank, ry + 6, { size: 12, color: C.muted, align: 'center' });
      text(ctx, L(r.gang).toUpperCase(), cols.name, ry + 6, { size: 13, weight: 700, color: dim ? C.muted : C.text, maxW: gw - 260 });
      if (q) {
        ctx.font = `700 13px ${FONT}`;
        const nameW = Math.min(ctx.measureText(L(r.gang).toUpperCase()).width, gw - 260);
        text(ctx, q === 'Q' ? 'QUALIFIED' : 'ELIMINATED', cols.name + nameW + 10, ry + 7, { size: 8, weight: 700, color: q === 'Q' ? C.green : C.red });
      }
      [[r.played, cols.p], [r.won, cols.w], [r.drawn, cols.d], [r.lost, cols.l], [r.kf, cols.k], [(r.diff > 0 ? '+' : '') + r.diff, cols.diff]].forEach(([v, cx]) =>
        text(ctx, String(v), cx, ry + 6, { size: 12, color: C.dim, align: 'center', font: MONO }));
      text(ctx, String(r.points), cols.pts, ry + 6, { size: 14, weight: 800, color: C.accent, align: 'right', font: MONO });
      if (r.rank === t.cfg.advance) { ctx.strokeStyle = 'rgba(54,143,233,0.6)'; ctx.setLineDash([4, 3]); ctx.beginPath(); ctx.moveTo(x + 8, ry + 19.5); ctx.lineTo(x + gw - 8, ry + 19.5); ctx.stroke(); ctx.setLineDash([]); }
      ry += 26;
    });
    ry += 6;
    matches.forEach((m) => {
      const a = L(m.a.gang), b = L(m.b.gang);
      const res = m.status === 'COMPLETE' ? (m.walkover ? 'W/O' : `${m.scoreA} - ${m.scoreB}`) : 'vs';
      text(ctx, `MD${m.round}`, x + 12, ry + 8, { size: 9, color: C.muted, font: MONO });
      text(ctx, a.toUpperCase(), x + gw / 2 - 34, ry + 8, { size: 11, align: 'right', weight: m.winner === m.a.gang ? 800 : 500, color: m.winner === m.a.gang ? C.text : C.dim, maxW: gw / 2 - 70 });
      text(ctx, res, x + gw / 2, ry + 8, { size: 11, align: 'center', font: MONO });
      text(ctx, b.toUpperCase(), x + gw / 2 + 34, ry + 8, { size: 11, weight: m.winner === m.b.gang ? 800 : 500, color: m.winner === m.b.gang ? C.text : C.dim, maxW: gw / 2 - 70 });
      ry += 20;
    });
  });
  y = rowY + maxH + 34;

  // Knockout bracket
  const layout = layoutBracket(t.matches || []);
  if (layout.cards.length) {
    text(ctx, 'KNOCKOUT STAGE', PAD, y, { size: 13, weight: 800, color: C.accent });
    y += 40;
    const bw = layout.width + COL_GAP + CARD_W;
    const ox = Math.max(PAD, Math.floor((W - bw) / 2));
    if (!dry) {
      layout.rounds.forEach((r, ri) => text(ctx, r[0].roundName, ox + ri * (CARD_W + COL_GAP) + CARD_W / 2, y - 16, { size: 10, weight: 700, color: C.muted, align: 'center' }));
      ctx.strokeStyle = C.line; ctx.lineWidth = 1.5;
      layout.lines.forEach((l) => {
        ctx.save(); ctx.translate(ox, y); ctx.stroke(new Path2D(l.d)); ctx.restore();
      });
      const final = layout.cards.find((c) => c.m.round === layout.rounds.length);
      if (final) {
        ctx.save(); ctx.translate(ox, y); ctx.stroke(new Path2D(`M${final.x + CARD_W} ${final.y + CARD_H / 2} H${final.x + CARD_W + COL_GAP}`)); ctx.restore();
        const cx = ox + final.x + CARD_W + COL_GAP;
        const cy = y + final.y;
        rect(ctx, cx, cy, CARD_W, CARD_H, t.champion ? 'rgba(255,214,10,0.08)' : C.panel, t.champion ? C.gold : C.line);
        text(ctx, 'CHAMPION', cx + CARD_W / 2, cy + 26, { size: 10, weight: 700, color: t.champion ? C.gold : C.muted, align: 'center' });
        text(ctx, t.champion ? L(t.champion).toUpperCase() : 'TBD', cx + CARD_W / 2, cy + 54, { size: 19, weight: 800, align: 'center', maxW: CARD_W - 16 });
      }
      layout.cards.forEach(({ m, x: mx, y: my }) => {
        const x0 = ox + mx, y0 = y + my;
        rect(ctx, x0, y0, CARD_W, CARD_H, C.panel, m.status === 'LIVE' ? C.accent : C.line);
        rect(ctx, x0 + 1, y0 + 1, CARD_W - 2, 19, C.panel2);
        text(ctx, m.label, x0 + 9, y0 + 11, { size: 9, weight: 700, color: C.muted });
        text(ctx, m.status === 'COMPLETE' ? (m.decidedBy === 'BYE' ? 'BYE' : 'COMPLETED') : (m.status === 'LIVE' ? 'LIVE' : 'UPCOMING'), x0 + CARD_W - 9, y0 + 11, { size: 8.5, weight: 700, color: m.status === 'LIVE' ? C.accent : C.muted, align: 'right' });
        [m.a, m.b].forEach((side, si) => {
          const s = slotText(t, side);
          const won = m.status === 'COMPLETE' && m.winner && m.winner === side.gang;
          const lost = m.status === 'COMPLETE' && m.winner && side.gang && m.winner !== side.gang;
          const ry = y0 + 21 + si * 22;
          if (won) rect(ctx, x0 + 1, ry, 3, 22, C.green);
          text(ctx, s.text.toUpperCase(), x0 + 12, ry + 11, { size: 12, weight: s.tbd ? 500 : 700, color: s.tbd || lost ? C.muted : C.text, maxW: CARD_W - 70 });
          const sc = m.status === 'COMPLETE' ? (m.decidedBy === 'BYE' ? '' : (m.walkover ? 'W/O' : String(si === 0 ? m.scoreA : m.scoreB))) : '';
          text(ctx, sc, x0 + CARD_W - 10, ry + 11, { size: 13, weight: 800, align: 'right', font: MONO });
        });
        let foot = '';
        if (m.status === 'COMPLETE') foot = m.decidedBy === 'BYE' ? `${L(m.winner)} • ADVANCES` : (m.winner ? `${L(m.winner)} • WINNER` : 'DRAW');
        ctx.strokeStyle = C.line; ctx.beginPath(); ctx.moveTo(x0 + 1, y0 + CARD_H - 20.5); ctx.lineTo(x0 + CARD_W - 1, y0 + CARD_H - 20.5); ctx.stroke();
        text(ctx, foot.toUpperCase(), x0 + 9, y0 + CARD_H - 10, { size: 9, weight: 700, color: C.green, maxW: CARD_W - 18 });
      });
    }
    y += layout.height + 34;
  }

  if (!dry) text(ctx, `Generated ${new Date().toLocaleString()}`, W - PAD, y, { size: 10, color: C.muted, align: 'right', font: MONO });
  y += 26;
  return y;
}

export function renderCanvas(t) {
  const groups = (t.groups || []).length;
  const layout = layoutBracket(t.matches || []);
  const bracketW = layout.cards.length ? layout.width + COL_GAP + CARD_W + 80 : 0;
  const width = Math.max(1280, Math.min(2400, Math.max(bracketW, groups >= 3 ? 1560 : 1280)));
  const probe = document.createElement('canvas');
  probe.width = width;
  probe.height = 10;
  const pctx = probe.getContext('2d');
  const height = Math.ceil(paint(pctx, t, true));

  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  rect(ctx, 0, 0, width, height, C.bg);
  paint(ctx, t, false);
  return canvas;
}

function dataUrlToBytes(dataUrl) {
  const b64 = dataUrl.slice(dataUrl.indexOf(',') + 1);
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

export function bytesToBase64(bytes) {
  let bin = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  return btoa(bin);
}

export function buildPng(t) {
  return dataUrlToBytes(renderCanvas(t).toDataURL('image/png'));
}

// One page, sized to the image, image embedded as a DCT (JPEG) stream.
export function buildPdf(t) {
  const canvas = renderCanvas(t);
  const jpeg = dataUrlToBytes(canvas.toDataURL('image/jpeg', 0.92));
  const w = Math.round(canvas.width * 0.6);
  const h = Math.round(canvas.height * 0.6);
  const enc = new TextEncoder();
  const chunks = [];
  const offsets = [];
  let len = 0;
  const add = (data) => {
    const b = typeof data === 'string' ? enc.encode(data) : data;
    chunks.push(b);
    len += b.length;
  };
  const obj = (n, body) => { offsets[n] = len; add(`${n} 0 obj\n`); add(body); add('\nendobj\n'); };

  add('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  obj(3, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`);
  offsets[4] = len;
  add(`4 0 obj\n<< /Type /XObject /Subtype /Image /Width ${canvas.width} /Height ${canvas.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`);
  add(jpeg);
  add('\nendstream\nendobj\n');
  const content = `q ${w} 0 0 ${h} 0 0 cm /Im0 Do Q`;
  obj(5, `<< /Length ${content.length} >>\nstream\n${content}\nendstream`);
  const xref = len;
  add(`xref\n0 6\n0000000000 65535 f \n`);
  for (let i = 1; i <= 5; i++) add(`${String(offsets[i]).padStart(10, '0')} 00000 n \n`);
  add(`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`);

  const out = new Uint8Array(len);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}

// Best-effort browser download; returns nothing meaningful — callers also
// offer the save-on-server route because NUI often swallows this silently.
export function tryDownload(bytes, fileName, mime) {
  try {
    const blob = new Blob([bytes], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
  } catch (e) {
    /* ignored — see comment above */
  }
}

export const MIME = { png: 'image/png', pdf: 'application/pdf', csv: 'text/csv' };
