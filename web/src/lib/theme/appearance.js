// ─── Nova Convoy — tablet appearance (accent colour + background) ────────────────────────────────
// One place that knows the accent presets and the background variants. The Admin Panel (Operations Hub) and the
// Gang Tablet (Event Status panel) each keep their OWN choice (adminPrefs / gangPrefs) and apply it as CSS custom
// properties on their own root element, so changing one never touches the other. The default pick (Blue + Graphite)
// produces NO overrides at all, so the interfaces look exactly as they always did until someone chooses otherwise.
// Three themes, nothing else. Each is an accent (the colour of the primary buttons) on a background; a saved choice is still
// stored as { accent, bgTheme } (so adminPrefs / gangPrefs keep their shape) and an older save is migrated to the nearest theme:
//   bw  Black + White   accent 'white'  on 'black'    white primary buttons, black button text
//   bb  Black + Blue    accent 'blue'   on 'black'    blue primary buttons, white button text   (the default)
//   bg  Black + Gold    accent 'gold'   on 'black'    gold primary buttons, black button text
// Token layers (primitive -> semantic -> the names the components already read): the values below are the primitives, themeVars() writes
// them out under the existing semantic names (--c-*, --bg-*, --tablet-*, --es-*, --text-*, --accent-*), and styles/flat.css gives the
// components their flat, rectangular, glow-free shape from those same tokens.
export const DEFAULT_ACCENT = 'blue';
export const DEFAULT_BG = 'black';

// base = primary buttons / highlights, light = hover (and icon tint), dim = pressed, solid / solidHover = the filled-button shade the
// Event Status panel uses (--es-accent).
export const ACCENTS = {
  white: { label: 'White', base: '#f5f5f5', light: '#e2e2e2', dim: '#c8c8c8', solid: '#f5f5f5', solidHover: '#e2e2e2', mono: true, ink: '#080808', onLight: { base: '#111111', solid: '#111111' } },
  blue:  { label: 'Blue',  base: '#2563eb', light: '#3b72f0', dim: '#1d4fc4', solid: '#2563eb', solidHover: '#3b72f0', ink: '#ffffff', onLight: { base: '#2563eb', solid: '#2563eb' } },
  gold:  { label: 'Gold',  base: '#eab308', light: '#facc15', dim: '#ca8a04', solid: '#eab308', solidHover: '#facc15', ink: '#0a0a0a', onLight: { base: '#eab308', solid: '#eab308' } },
};

// Backgrounds. admin = the opaque surfaces of the Operations Hub; gang = the Event Status panel's surfaces; glass = the bars / cards drawn
// over the frame; shadeImg = one flat colour laid over the frame's picture (so there is NO picture, no wash, no gradient);
// swatch = three chips for the picker + preview.
export const BACKGROUNDS = {
  black: {
    label: 'Black', swatch: ['#050505', '#111111', '#292929'], flat: true, previewText: '#f5f5f5',
    shade: 'rgba(5, 5, 5, 1)', shadeImg: 'linear-gradient(#050505, #050505)',
    admin: { base: '#050505', surface: '#0b0b0b', panel: '#111111', raised: '#181818', hover: '#212121', line: '#292929', lineStrong: '#3a3a3a', lineHover: '#4a4a4a', sidebar: '#050505', sidebar2: '#050505', input: '#0b0b0b', inputHover: '#101010', inputFocus: '#141414', inputBorder: '#2e2e2e', inputBorderHover: '#444444' },
    gang: { card: '#111111', hover: '#1b1b1b', raised: '#181818', inset: '#0b0b0b', solid: '#0b0b0b' },
    glass: { bar: '#0b0b0b', panel: '#111111', head: '#0b0b0b' },
  },
};

export const ACCENT_IDS = Object.keys(ACCENTS);
export const BG_IDS = Object.keys(BACKGROUNDS);

// The three themes the picker offers (the only selectable combinations).
export const THEMES = {
  bw: { label: 'Black + White', accent: 'white', bgTheme: 'black' },
  bb: { label: 'Black + Blue',  accent: 'blue',  bgTheme: 'black' },
  bg: { label: 'Black + Gold',  accent: 'gold',  bgTheme: 'black' },
};
export const THEME_IDS = Object.keys(THEMES);
export const DEFAULT_THEME = 'bb';
export function themeIdOf(accent, bgTheme) {
  return THEME_IDS.find((id) => THEMES[id].accent === accent && THEMES[id].bgTheme === bgTheme) || DEFAULT_THEME;
}

// Black + Blue is the default look of BOTH tablets. A browser that saved another theme before this rule existed is put back on blue ONCE
// (a marker is stored with the first load); after that the player's own pick in Settings is kept.
const BLUE_ONCE = 'nova_theme_blue_default_v1';
export function blueDefaultOnce(p, scopeKey) {
  try {
    if (typeof localStorage === 'undefined') return p;
    const mark = BLUE_ONCE + ':' + scopeKey;
    if (localStorage.getItem(mark)) return p;
    localStorage.setItem(mark, '1');
    return { ...p, accent: 'blue', bgTheme: 'black' };
  } catch (e) { return p; }
}

export const DEFAULT_APPEARANCE = { accent: DEFAULT_ACCENT, bgTheme: DEFAULT_BG, clickSounds: true };

// Whatever is stored (an old save from the many-colour era, an old White theme, hand-edited storage) is mapped to the nearest of the three
// themes: the white accent -> Black + White; the gold accent -> Black + Gold; everything else -> Black + Blue.
export function cleanAppearance(p) {
  const src = p && typeof p === 'object' ? p : {};
  let id;
  if (THEMES[src.theme]) id = src.theme;
  else if (src.accent === 'white' && src.bgTheme === 'black') id = 'bw';
  else if (src.accent === 'gold' && src.bgTheme === 'black') id = 'bg';
  else id = 'bb';
  return { accent: THEMES[id].accent, bgTheme: THEMES[id].bgTheme, clickSounds: src.clickSounds !== false };
}

// ── colour maths ─────────────────────────────────────────────────────────────────────────────────
const rgbOf = (hex) => {
  const n = parseInt(hex.replace('#', ''), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const hex2 = (n) => Math.round(Math.min(255, Math.max(0, n))).toString(16).padStart(2, '0');
const toHex = (r, g, b) => `#${hex2(r)}${hex2(g)}${hex2(b)}`;
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
// blend two hex colours (t = how much of b)
const mixHex = (a, b, t) => { const A = rgbOf(a), B = rgbOf(b); return toHex(A[0] + (B[0] - A[0]) * t, A[1] + (B[1] - A[1]) * t, A[2] + (B[2] - A[2]) * t); };

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h;
  if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return [h * 60, s, l];
}
function hslToRgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  let r = 0, g = 0, b = 0;
  if (h < 60) [r, g, b] = [c, x, 0];
  else if (h < 120) [r, g, b] = [x, c, 0];
  else if (h < 180) [r, g, b] = [0, c, x];
  else if (h < 240) [r, g, b] = [0, x, c];
  else if (h < 300) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
}
const luminance = (r, g, b) => {
  const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
const contrast = (a, b) => { const [hi, lo] = a > b ? [a, b] : [b, a]; return (hi + 0.05) / (lo + 0.05); };

// black or white text, whichever reads better on this fill
const INK_DARK = '#0b1118';
function textOn(fillHex) {
  const [r, g, b] = rgbOf(fillHex);
  const lf = luminance(r, g, b);
  const white = contrast(1, lf);
  const dark = contrast(luminance(...rgbOf(INK_DARK)), lf);
  return white >= dark ? '#ffffff' : INK_DARK;
}

// darken a colour (keeping its hue) until its luminance is low enough for >= 5:1 on the palest light surfaces
function inkOf(hex) {
  let k = 1;
  const [r, g, b] = rgbOf(hex);
  while (k > 0.2 && luminance(r * k, g * k, b * k) > 0.1) k -= 0.02;
  return toHex(r * k, g * k, b * k);
}

function accentVars(id, onLightBg) {
  const a = ACCENTS[id];
  const ll = onLightBg ? a.onLight : null;
  const base = ll ? ll.base : a.base;
  const solid = ll ? ll.solid : a.solid;
  // on the Light background hover goes a little darker (lighter hover would wash out), and the icon / link tint stays dark enough
  const dark = (hex, k) => { const [r, g, b] = rgbOf(hex); return toHex(r * k, g * k, b * k); };
  const light = ll ? dark(base, 0.88) : a.light;
  const dim = ll ? dark(base, 0.78) : a.dim;
  const solidHover = ll ? dark(solid, 0.9) : a.solidHover;
  const rgb = rgbOf(base).join(', ');
  const solidRgb = rgbOf(solid).join(', ');
  const lightRgb = rgbOf(light).join(', ');
  const v = {
    // the Event Status panel's active tab / stat tile tints (defaults live next to where they are used)
    '--nav-active-bg': `rgba(${solidRgb}, ${onLightBg ? 0.16 : 0.46})`,
    '--nav-active-border': `rgba(${lightRgb}, ${onLightBg ? 0.6 : 0.55})`,
    '--stat-active-border': `rgba(${lightRgb}, 0.4)`,
    '--stat-icon-color': onLightBg ? dim : light,
    '--accent-primary': base,
    '--accent-primary-rgb': rgb,
    '--accent-primary-light': light,
    // accent-coloured TEXT on the Light background: the accent darkened until it clears 5:1 (pale accents like Yellow / Gold become a dark amber / brown)
    ...(onLightBg ? { '--accent-text': inkOf(base) } : {}),
    '--accent-primary-dim': dim,
    '--accent-glow': `rgba(${rgb}, 0.3)`,
    '--accent-dim': `rgba(${rgb}, ${onLightBg ? 0.1 : 0.12})`,
    '--accent-border': `rgba(${rgb}, 0.5)`,
    // tokens that are written out once at :root, so a scoped override has to repeat them
    '--c-action': base,
    '--c-action-hover': light,
    '--input-focus-border': base,
    '--metal-gold': base,
    '--metal-gold-hover': light,
    '--metal-edge-gold': base,
    '--es-accent': solid,
    '--es-accent-hover': solidHover,
    '--toggle-on': base,
    // readable text ON a filled button, worked out from the actual fill colour (bright admin fills vs the darker gang fills)
    '--on-accent': textOn(base),
    '--on-es-accent': textOn(solid),
    '--metal-gold-text': textOn(base),
  };
  // the text on a filled primary button is the accent's own ink (black on white, white on blue / black), whatever textOn() would pick
  Object.assign(v, { '--on-accent': a.ink, '--on-es-accent': a.ink, '--metal-gold-text': a.ink, '--accent-glow': 'transparent' });
  if (a.mono && !onLightBg) {
    // white fills on black: an active tab / tile is a faint white wash with a white edge (the tinted fill would turn white-on-white)
    Object.assign(v, {
      '--nav-active-bg': 'rgba(255, 255, 255, 0.12)', '--nav-active-border': 'rgba(255, 255, 255, 0.5)', '--stat-active-border': 'rgba(255, 255, 255, 0.4)',
      '--stat-icon-color': '#ffffff', '--accent-dim': 'rgba(255, 255, 255, 0.1)', '--accent-border': 'rgba(255, 255, 255, 0.5)',
    });
  }
  // the soft button look: the theme's accent blended into the raised surface (a muted shade of the theme, not a new colour)
  Object.assign(v, { '--btn-soft': mixHex('#181818', base, 0.26), '--btn-soft-hover': mixHex('#181818', base, 0.38), '--btn-soft-line': mixHex('#292929', base, 0.5) });
  for (const k of ['dashboard', 'convoys', 'create', 'active', 'completed', 'gangs', 'leaderboard', 'settings', 'announcements', 'participants', 'savedroutes', 'tournaments']) {
    v[`--accent-${k}`] = base;
  }
  return v;
}

// semantic layer shared by every theme: the corner scale (rectangular: 4 px controls, 6 px panels), Inter, the action colours
const SHAPE_FONT = {
  '--r-xs': '5px', '--r-tag': '5px', '--r-ctl': '7px', '--r-panel': '10px', '--r-frame': '12px',
  '--font-ui': "'Inter Variable', 'Inter', 'Segoe UI', -apple-system, BlinkMacSystemFont, Arial, sans-serif",
  '--font-display': "'Inter Variable', 'Inter', 'Segoe UI', -apple-system, BlinkMacSystemFont, Arial, sans-serif",
  '--font-body': "'Inter Variable', 'Inter', 'Segoe UI', -apple-system, BlinkMacSystemFont, Arial, sans-serif",
  '--font-mono': "'Inter Variable', 'Inter', 'Segoe UI', -apple-system, BlinkMacSystemFont, Arial, sans-serif",
  // the type scale: body 14, small 13, meta / labels 12, section titles 17, page titles 26
  '--fs-meta': '12px', '--fs-small': '13px', '--fs-body': '14px', '--fs-emph': '15px', '--fs-title': '17px', '--fs-section': '26px',
  '--stretch-display': '100%',
  '--act-create': '#22c55e', '--act-danger': '#b5433e', '--act-danger-ink': '#ffffff', '--act-info': '#3b82f6', '--act-ink': '#0a0a0a',
};
// Event Status type scale (admin keeps SHAPE_FONT's): meta 11.5, small 12.5, body 13.5, emph 14.5, titles 16, big headings 20
const GANG_SCALE = { '--fs-meta': '11.5px', '--fs-small': '12.5px', '--fs-body': '13.5px', '--fs-emph': '14.5px', '--fs-title': '16px', '--fs-section': '20px', '--fs-page': '22px' };
const DARK_TEXT = {
  '--text-main': '#f5f5f5', '--text-label': '#f5f5f5', '--text-dim': '#b0b0b0', '--text-muted': '#b0b0b0',
  '--text-placeholder': '#8a8a8a', '--text-faint': '#9a9a9a', '--tablet-text-faint': '#9a9a9a',
  '--c-text': '#f5f5f5', '--c-text-2': '#b0b0b0', '--c-text-3': '#9a9a9a', '--text-strong': '#ffffff',
};

function commonBgVars(s) {
  const v = { ...SHAPE_FONT, ...(s.light ? {} : DARK_TEXT) };
  if (s.glass) {
    v['--glass-bar'] = s.glass.bar;
    v['--glass-panel'] = s.glass.panel;
    v['--glass-head'] = s.glass.head;
  }
  if (s.shade) v['--frame-shade'] = s.shade;
  if (s.shadeImg) {
    v['--frame-shade-img'] = s.shadeImg;
    // a gradient theme replaces the stock blue picture under the window (the frames read --bg-picture first)
    v['--bg-picture'] = 'none';
  }
  if (s.frameBase) v['--frame-base'] = s.frameBase;
  return v;
}

function adminBgVars(id) {
  const s = BACKGROUNDS[id];
  const b = s.admin;
  const out = commonBgVars(s);
  if (!b) return out;
  return {
    ...out,
    '--c-base': b.base, '--c-panel': b.panel, '--c-raised': b.raised, '--c-hover': b.hover, '--c-line': b.line, '--c-line-soft': b.raised,
    '--bg-base': b.base, '--bg-surface': b.surface, '--bg-card': b.panel, '--bg-card-raised': b.raised, '--bg-card-hover': b.hover,
    '--tablet-bg': b.base, '--tablet-panel': b.panel, '--tablet-panel-alt': b.surface,
    '--tablet-border': b.line, '--tablet-border-strong': b.lineStrong, '--tablet-border-hover': b.lineHover,
    '--panel-bg': b.panel, '--panel-border': b.line, '--card-bg': b.panel,
    '--app-frame': b.base, '--topbar-bg': b.surface, '--sidebar-bg': b.sidebar, '--sidebar-bottom-bg': b.sidebar2,
    '--header-bg': b.surface, '--form-bg': b.panel, '--steps-bg': b.surface,
    '--doctrine-bar-bg': b.surface, '--doctrine-card-bg': b.panel, '--doctrine-card-hover': b.raised, '--doctrine-card-active': b.hover,
    '--input-bg': b.input, '--input-bg-hover': b.inputHover, '--input-bg-focus': b.inputFocus,
    '--input-border': b.inputBorder, '--input-border-hover': b.inputBorderHover,
    '--surface-dialog': b.panel, '--surface-dialog-bar': b.surface, '--border-dialog': b.lineStrong,
    // the Event Status surface names, so components shared with the gang tablet (the territory map's toolbar...) follow this theme too
    '--es-raised': b.raised, '--es-card': b.panel, '--es-card-hover': b.hover, '--es-inset': b.input, '--es-solid': b.panel,
    ...(BACKGROUNDS[id].light ? {} : { '--es-line': b.line, '--es-line-soft': b.line, '--es-line-strong': b.lineStrong }),
  };
}

function gangBgVars(id) {
  const s = BACKGROUNDS[id];
  const g = s.gang;
  const out = commonBgVars(s);
  if (!g) return out;
  return {
    ...out,
    '--es-card': g.card, '--es-card-hover': g.hover, '--es-raised': g.raised, '--es-inset': g.inset, '--es-solid': g.solid,
    // the shared surface names the Event Status panel's components read (they point at the es tokens above)
    '--tablet-panel': g.card, '--panel-bg': g.card, '--card-bg': g.card, '--bg-card': g.card, '--bg-surface': g.card,
    '--tablet-panel-alt': g.card, '--bg-card-raised': g.raised, '--bg-card-hover': g.hover,
    '--tablet-bg': g.inset, '--bg-base': g.inset, '--input-bg': g.inset,
    '--c-base': g.inset, '--c-panel': g.card, '--c-raised': g.raised, '--c-hover': g.hover,
    '--surface-dialog': g.solid, '--surface-dialog-bar': g.card,
    ...(s.light ? {} : { '--es-line': s.admin.line, '--es-line-soft': s.admin.line, '--es-line-strong': s.admin.lineStrong }),
  };
}

// scope: 'admin' | 'gang'. Returns {} for the default pick.
export function themeVars(scope, accent, bgTheme) {
  const out = {};
  const bg = BACKGROUNDS[bgTheme] ? bgTheme : DEFAULT_BG;
  const ac = ACCENTS[accent] ? accent : DEFAULT_ACCENT;
  Object.assign(out, accentVars(ac, !!BACKGROUNDS[bg].light));
  Object.assign(out, scope === 'gang' ? gangBgVars(bg) : adminBgVars(bg));
  // the Event Status panel is read at a glance in game: a smaller, tighter scale than the admin tablet
  if (scope === 'gang') Object.assign(out, GANG_SCALE);
  return out;
}

// the form a `style=""` attribute takes
export function themeStyle(scope, accent, bgTheme) {
  return Object.entries(themeVars(scope, accent, bgTheme)).map(([k, v]) => `${k}:${v}`).join(';');
}

// Switching the theme restyles the whole window. Every control has a short colour transition, so without this the switch
// animates thousands of elements at once (visible as a stutter in the game's browser). Transitions are switched off for
// the instant of the change (see styles/theme.css .theme-switching) and restored right after it has been painted.
export function applyThemeQuietly(apply) {
  const root = typeof document !== 'undefined' ? document.documentElement : null;
  if (root) root.classList.add('theme-switching');
  try { apply(); } finally {
    if (root) {
      const done = () => setTimeout(() => root.classList.remove('theme-switching'), 120);
      if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => requestAnimationFrame(done)); else done();
    }
  }
}
