// Older FiveM browser builds (the game's CEF before Chromium 111) do not understand color-mix(): a declaration that uses it is dropped, so
// a nav tab, chip or tag would lose its background / text colour. This build step puts a plain-colour declaration right BEFORE every
// declaration that uses color-mix(); a browser that knows color-mix() reads the original after it and overrides the fallback, an older
// one keeps the fallback. Text colours fall back to the colour being mixed in; borders and backgrounds fall back to the colour it is mixed with
// (or nothing, when that is transparent), so nothing is ever painted in a harsher colour than intended.

function matchParen(s, open) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')' && --depth === 0) return i;
  }
  return -1;
}

function splitTop(args) {
  const out = []; let depth = 0; let cur = '';
  for (const ch of args) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; } else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

// text-like properties keep the colour being mixed in; borders, outlines and backgrounds fall back to the quiet colour (a full-strength border would be harsher than the faint one intended)
const COLOURISH = /^(color|fill|stroke|caret-color|text-decoration-color|accent-color)$/;
// 'red 40%' / 'var(--g, #fff) var(--mix, 100%)' -> the colour only (a trailing percentage, or a var() standing in for one, is dropped)
function stripPct(v) {
  const toks = []; let depth = 0; let cur = '';
  for (const ch of v.trim()) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (/\s/.test(ch) && depth === 0) { if (cur) toks.push(cur); cur = ''; } else cur += ch;
  }
  if (cur) toks.push(cur);
  if (toks.length > 1 && (/^[\d.]+%$/.test(toks[toks.length - 1]) || toks[toks.length - 1].startsWith('var('))) toks.pop();
  return toks.join(' ');
}

function fallbackFor(value, prop) {
  let out = ''; let i = 0;
  for (;;) {
    const at = value.indexOf('color-mix(', i);
    if (at < 0) { out += value.slice(i); break; }
    const open = at + 'color-mix'.length;
    const close = matchParen(value, open);
    if (close < 0) return null;
    const parts = splitTop(value.slice(open + 1, close));   // [ 'in srgb', 'X p%', 'Y' ]
    const x = parts[1] ? stripPct(parts[1]) : 'transparent';
    const y = parts[2] ? stripPct(parts[2]) : 'transparent';
    out += value.slice(i, at) + (COLOURISH.test(prop) ? x : (y === 'transparent' ? 'transparent' : y));
    i = close + 1;
  }
  return out;
}

export function addColorMixFallbacks(css) {
  let out = ''; let pos = 0; let count = 0;
  for (;;) {
    const at = css.indexOf('color-mix(', pos);
    if (at < 0) { out += css.slice(pos); break; }
    // the declaration around it: from the previous ; { or } to the next ; or } outside any parentheses
    let start = at;
    while (start > pos && !';{}'.includes(css[start - 1])) start--;
    let end = start; let depth = 0;
    for (; end < css.length; end++) {
      const ch = css[end];
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
      else if (depth === 0 && (ch === ';' || ch === '}')) break;
    }
    const decl = css.slice(start, end);
    const colon = decl.indexOf(':');
    const prop = colon > 0 ? decl.slice(0, colon).trim() : '';
    let fb = null;
    if (prop && !prop.startsWith('--')) { const v = fallbackFor(decl.slice(colon + 1), prop); if (v != null) fb = `${prop}:${v}`; }
    out += css.slice(pos, start) + (fb ? fb + ';' : '') + decl;
    count++;
    pos = end;
  }
  return { css: out, count };
}

export default function colorMixFallback() {
  return {
    name: 'color-mix-fallback',
    enforce: 'post',
    generateBundle(_, bundle) {
      for (const file of Object.values(bundle)) {
        if (file.type === 'asset' && /\.css$/.test(file.fileName)) {
          const { css, count } = addColorMixFallbacks(String(file.source));
          if (count) { file.source = css; console.log(`[color-mix-fallback] ${file.fileName}: ${count} declarations got a plain fallback`); }
        }
      }
    },
  };
}
