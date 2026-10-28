// One colour identity per event kind, deliberately spread around the hue wheel
// so no two events (or an event and a status colour) read alike on screen:
//
//   convoy   orange  ~27°     hotcargo magenta ~326°    police  blue   ~213°
//   airdrop  violet  ~255°    rally    teal    ~186°    practice lime  ~75°
//   tdm      red     ~359°    server   gold    ~42°  (admin broadcasts)
//   territory  violet ~290° (the gap between airdrop violet and hot-cargo magenta): the territory AUCTION and everything about it
//   rivals     royal blue ~229° (the red-vs-blue banner art): every gang RIVAL notification - challenges, scheduled wars, war results
//   containerwars  harbour green ~116° (the green of the shipping containers; sits in the gap between lime and mint)
//   success/danger/warn are STATUS colours, used only when a message isn't
//   tied to any event at all.
//
// `rgb` feeds rgba(var(--accentRGB), a) in the HUD styles.

export const THEMES = {
  convoy:   { label: 'CONVOY',          accent: '#ee8a2b', accent2: '#ffb56b', rgb: '238,138,43',  icon: 'convoy',   footer: 'TACTICAL COMMAND' },
  airdrop:  { label: 'AIRDROP',         accent: '#9b7bff', accent2: '#c2b0ff', rgb: '155,123,255', icon: 'airdrop',  footer: 'SUPPLY CONTROL' },
  hotcargo: { label: 'HOT CARGO',       accent: '#e0489f', accent2: '#ff86c8', rgb: '224,72,159',  icon: 'hotcargo', footer: 'MISSION CONTROL' },
  rally:    { label: 'GANG RALLY',      accent: '#22c7d6', accent2: '#7ce8f2', rgb: '34,199,214',  icon: 'rally',    footer: 'RACE CONTROL' },
  tdm:      { label: 'TEAM DEATHMATCH', accent: '#e5484d', accent2: '#ff8a8d', rgb: '229,72,77',   icon: 'tdm',      footer: 'COMBAT CONTROL' },
  containerwars: { label: 'CONTAINER WARS', accent: '#52d24a', accent2: '#8ae885', rgb: '82,210,74', icon: 'containerwars', footer: 'AUCTION CONTROL' },
  territory: { label: 'GANG TERRITORY', accent: '#c45ee0', accent2: '#dc92ee', rgb: '196,94,224', icon: 'territory', footer: 'TERRITORY CONTROL' },
  crackdown: { label: 'OPERATION CRACKDOWN', accent: '#d6336c', accent2: '#ff7aa2', rgb: '214,51,108', icon: 'police', footer: 'CRACKDOWN CONTROL' },
  rivals:   { label: 'GANG RIVALS',     accent: '#5b7bff', accent2: '#98adff', rgb: '91,123,255',  icon: 'rivals',   footer: 'RIVAL CONTROL' },
  police:   { label: 'POLICE DISPATCH', accent: '#4f94e6', accent2: '#8fbef5', rgb: '79,148,230',  icon: 'police',   footer: 'DISPATCH' },
  practice: { label: 'PRACTICE RANGE',  accent: '#a3d62f', accent2: '#cdee6f', rgb: '163,214,47',  icon: 'tdm',      footer: 'RANGE CONTROL' },
  server:   { label: 'SERVER',          accent: '#368fe9', accent2: '#5ba5ef', rgb: '54,143,233',  icon: 'info',     footer: 'OPERATIONS BROADCAST' },
  success:  { label: 'CONFIRMED',       accent: '#46d69a', accent2: '#75e4b5', rgb: '70,214,154',  icon: 'success',  footer: 'MISSION CONTROL' },
  danger:   { label: 'PRIORITY ALERT',  accent: '#ff5d50', accent2: '#ff857c', rgb: '255,93,80',   icon: 'danger',   footer: 'DISPATCH // PRIORITY' },
  warn:     { label: 'WARNING',         accent: '#ffc857', accent2: '#ffd982', rgb: '255,200,87',  icon: 'danger',   footer: 'TACTICAL WARNING' },
};

export function themeFor(key) {
  return THEMES[key] || THEMES.server;
}

// Inline-style string that sets the three CSS variables every HUD card reads.
export function themeVars(key) {
  const t = themeFor(key);
  return `--accent:${t.accent};--accent2:${t.accent2};--accentRGB:${t.rgb}`;
}

// Announcements only carry a loose `type` ('start' | 'success' | 'checkpoint' |
// 'warn' | 'danger' | 'info' | 'airdrop' | 'hotcargo' | 'convoy' | 'rally')
// plus free text, so the owning event is inferred from both. The event wins
// over status: "Airdrop started" is violet, not success-green — the status is
// carried by the badge text instead. Status colours only apply when nothing
// identifies an event.
const RIVAL_WORDS = /\b(rivals?|wars?|challenge[ds]?|contested|captured|defended|no show)\b/;
export function inferEventKey(type, title = '', message = '') {
  const t = `${title} ${message}`.toLowerCase();
  // the server sends every territory banner as type 'territory': the ones about a rival challenge / war are the Gang Rivals event
  if (type === 'territory' && RIVAL_WORDS.test(t)) return 'rivals';
  if (type && THEMES[type] && !['success', 'danger', 'warn', 'server'].includes(type)) return type;
  if (type === 'checkpoint') return 'convoy';

  if (t.includes('police pursuit') || t.includes('suspects fleeing') || t.includes('police dispatch') || t.includes('10-99')) {
    return t.includes('hot cargo') || t.includes('hot_cargo') ? 'hotcargo' : 'police';
  }
  if (t.includes('rally') || t.includes('race') || t.includes('racer') || t.includes('podium')) return 'rally';
  if (t.includes('airdrop') || t.includes('supply drop') || t.includes('crate')) return 'airdrop';
  if (t.includes('hot cargo') || t.includes('hot_cargo') || t.includes('hijack')) return 'hotcargo';
  if (t.includes('deathmatch') || t.includes('tdm') || t.includes('tournament') || t.includes('kill limit')) return 'tdm';
  if (RIVAL_WORDS.test(t) && (t.includes('territory') || type === 'territory')) return 'rivals';
  if (t.includes('territory') || t.includes('rival challenge')) return 'territory';
  if (t.includes('practice range')) return 'practice';
  if (t.includes('convoy') || t.includes('checkpoint') || t.includes('truck') || t.includes('ambush') || t.includes('escort')) return 'convoy';

  if (type === 'danger' || t.includes('failed') || t.includes('destroyed')) return 'danger';
  if (type === 'success' || t.includes('delivered') || t.includes('secured')) return 'success';
  if (type === 'warn' || t.includes('warning')) return 'warn';
  return 'server';
}

// Right-hand badge for a Container Wars banner (the server can also send its own, e.g. "ROUND 2 / 4").
export function containerWarsStatus(title = '') {
  const t = title.toLowerCase();
  if (t.includes('upcoming') || t.includes('starting soon')) return 'STARTING SOON';
  if (t.includes('final round incoming')) return 'FINAL SOON';
  if (t.includes('final round') && t.includes('bidding')) return 'FINAL BIDDING';
  if (t.includes('final round')) return 'FINAL ROUND';
  if (t.includes('bidding open')) return 'BIDDING OPEN';
  if (t.includes('opening')) return 'OPENING';
  if (t.includes('payment failed')) return 'UNPAID';
  if (t.includes('no bids') || t.includes('unsold')) return 'UNSOLD';
  if (t.includes('won')) return 'SOLD';
  if (t.includes('cancelled')) return 'STAND DOWN';
  if (t.includes('concluded')) return 'CLOSED';
  const round = t.match(/round\s+(\d+)/);
  if (round) return `ROUND ${round[1]}`;
  return 'AUCTION';
}

// Short right-hand badge text describing WHAT happened, independent of colour.
export function statusFor(type, title = '') {
  const t = title.toLowerCase();
  if (t.includes('upcoming') || t.includes('starting soon')) return 'STARTING SOON';
  if (t.includes('hijacked')) return 'HIJACKED';
  if (t.includes('captured')) return 'CAPTURED';
  if (t.includes('delivered') || t.includes('secured')) return 'SECURED';
  if (t.includes('failed') || t.includes('destroyed') || t.includes('lost')) return 'FAILED';
  if (t.includes('cancelled') || t.includes('terminated')) return 'STAND DOWN';
  if (t.includes('champion') || t.includes('winner') || t.includes('complete') || t.includes('concluded') || t.includes('ended')) return 'CONCLUDED';
  if (t.includes('disabled') || t.includes('critical') || t.includes('ambush') || t.includes('warning')) return 'HIGH PRIORITY';
  if (t.includes('started') || t.includes('departed') || t.includes('live')) return 'LIVE';
  if (type === 'danger') return 'HIGH PRIORITY';
  if (type === 'success') return 'CONFIRMED';
  if (type === 'warn') return 'WARNING';
  return 'BROADCAST';
}

// "#rrggbb" / "#rgb" -> "r,g,b" for the --accentRGB variable; falls back to
// the server blue when a gang's accent isn't a plain hex colour.
export function hexToRgb(hex, fallback = '54,143,233') {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(hex || '').trim());
  if (!m) return fallback;
  let h = m[1];
  if (h.length === 3) h = h.split('').map((c) => c + c).join('');
  const n = parseInt(h, 16);
  return `${(n >> 16) & 255},${(n >> 8) & 255},${n & 255}`;
}
