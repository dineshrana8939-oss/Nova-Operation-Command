// The live numbers, commands and keys the User Guide quotes. They come from config.lua (the server sends them with the tablet's
// bootstrap data), so a config change shows up here after a resource restart. Every value has a default for the case where the
// server has not sent it yet. In guideContent.js a value is written as {{name}}.

const pick = (v, d) => (v === undefined || v === null || v === '' ? d : v);

function secondsText(s) {
  s = Math.round(Number(s) || 0);
  if (s >= 60 && s % 60 === 0) { const m = s / 60; return `${m} minute${m === 1 ? '' : 's'}`; }
  return `${s} second${s === 1 ? '' : 's'}`;
}

// 3600 → "1 hour", 900 → "15 minutes", 45 → "45 seconds"
function spanText(s) {
  s = Math.round(Number(s) || 0);
  if (s >= 3600 && s % 3600 === 0) { const h = s / 3600; return `${h} hour${h === 1 ? '' : 's'}`; }
  if (s >= 60 && s % 60 === 0) { const m = s / 60; return `${m} minute${m === 1 ? '' : 's'}`; }
  return `${s} second${s === 1 ? '' : 's'}`;
}

function listText(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

export function buildValues(bootstrap) {
  const bs = bootstrap || {};
  const g = bs.guide || {};
  const tb = bs.tablet || {};
  const lim = bs.limits || {};

  // race tokens: { 1: 5, 2: 3, 3: 2 }
  const tk = g.raceTokens || {};
  const places = Object.keys(tk).map(Number).sort((a, b) => a - b).map((k) => tk[k]);
  const tokenText = places.length
    ? `${listText(places.map(String))} for the first ${places.length === 1 ? 'place' : places.length}, ${pick(g.raceFinishTokens, 1)} for every other finisher`
    : `${pick(g.raceFinishTokens, 1)} for every finisher`;

  // race reminders, in seconds before the start: [600, 300, 180, 120, 60, 30, 10]
  const rem = (Array.isArray(g.raceReminders) ? g.raceReminders : [600, 300, 180, 120, 60, 30, 10]).map(Number).sort((a, b) => b - a);
  const mins = rem.filter((s) => s >= 60 && s % 60 === 0).map((s) => s / 60);
  const secs = rem.filter((s) => !(s >= 60 && s % 60 === 0));
  const remindText = [mins.length ? `${listText(mins.map(String))} minute${mins.length === 1 && mins[0] === 1 ? '' : 's'}` : '', secs.length ? `${listText(secs.map(String))} seconds` : ''].filter(Boolean).join(', then ');

  // lockpick failures by difficulty
  const lf = g.lockFailures || { EASY: 4, MEDIUM: 3, HARD: 2, EXTREME: 1 };
  const lockText = ['EASY', 'MEDIUM', 'HARD', 'EXTREME'].filter((k) => lf[k] != null).map((k) => `${k.charAt(0) + k.slice(1).toLowerCase()} ${lf[k]}`).join(', ');

  // territory war
  const w = g.war || {};
  const wr = (Array.isArray(w.reminders) ? w.reminders : [30, 10, 2]).map(Number).sort((a, b) => b - a);
  const ns = w.noShow || { mode: 'FLAT', xp: 250, percent: 10 };
  const contest = { PAUSE: 'the capture pauses until they are gone', RESET: 'the capture starts over', DECAY: 'the capture slowly drops back' };

  const jobs = Array.isArray(g.policeJobs) && g.policeJobs.length ? g.policeJobs : ['police', 'lspd', 'bcso', 'sheriff', 'state', 'sasp', 'sahp', 'rangers'];

  return {
    tabletCmd: '/' + pick(tb.command, 'eventhub'),
    tabletKey: pick(tb.keybind, 'F7'),
    statusCmd: '/' + pick(g.statusCmd, 'eventstatus'),
    statusKey: pick(g.statusKey, 'F6'),
    raceStartCmd: g.raceStartCmd === '' ? 'the Start Countdown button' : '/' + pick(g.raceStartCmd, 'racestart'),
    soundTestCmd: '/' + pick(g.soundTestCmd, 'soundtest'),
    maxGang: pick(lim.maxGangParticipants, 35),
    maxPolice: pick(lim.maxPoliceParticipants, 35),
    deliveryRadius: pick(g.deliveryRadius, 25),
    startDelay: secondsText(pick(g.startAnnounceDelay, 60)),
    preSchedule: secondsText(pick(g.preScheduleSeconds, 300)),
    hcSearchRadius: pick(g.hcSearchRadius, 150),
    hcBreakdownPct: pick(g.hcBreakdownPct, 8),
    hcMaxSpeed: pick(g.hcMaxSpeed, 16),
    raceTokensText: tokenText,
    raceRemindersText: remindText,
    raceGridRadius: pick(g.raceGridRadius, 40),
    raceGridWait: secondsText(pick(g.raceGridWait, 180)),
    raceFinishWindow: pick(g.raceFinishWindow, 60),
    tdmHp: pick(g.tdmHp, 100),
    tdmPrep: pick(g.tdmPrep, 5),
    tdmRespawn: pick(g.tdmRespawn, 3),
    tdmInvuln: pick(g.tdmInvuln, 3),
    cwCountdown: pick(g.cwCountdown, 30),
    antiSnipeTrigger: pick(g.antiSnipeTrigger, 10),
    antiSnipeExtend: pick(g.antiSnipeExtend, 15),
    lockText,
    cpWait: spanText(pick(g.cpWait, 60)),
    destWarn: pick(g.destWarn, 120),
    airdropDuration: spanText(pick(g.airdropDuration, 420)),
    airdropGuards: pick(g.airdropGuards, 3),
    airdropLockpicks: pick(g.airdropLockpicks, 1),
    airdropLead: pick(g.airdropLead, 15),
    warMinutes: pick(w.minutes, 15),
    warReminders: `${listText(wr.map(String))} minute${wr.length === 1 && wr[0] === 1 ? '' : 's'}`,
    captureSeconds: pick(w.captureSeconds, 60),
    contestText: contest[String(pick(w.contestRule, 'PAUSE')).toUpperCase()] || contest.PAUSE,
    ringRadius: pick(w.ringRadius, 160),
    ringBuffer: pick(w.ringBuffer, 35),
    noShowText: String(ns.mode).toUpperCase() === 'PERCENT' ? `${pick(ns.percent, 10)}% of its XP` : `${pick(ns.xp, 250)} XP`,
    lootWindow: pick(w.lootWindow, 5),
    lootPercent: pick(w.lootPercent, 20),
    shrinkPercent: pick(w.shrinkPercent, 25),
    pairCooldownHours: pick(w.pairCooldownHours, 24),
    challengeCooldown: spanText(pick(w.challengeCooldown, 3600)),
    maxOpenChallenges: pick(w.maxOpen, 3),
    challengeExpire: Number(w.expire) === 0 ? 'never' : spanText(pick(w.expire, 172800)),
    policeJobsText: jobs.join(', '),
    splitXpText: g.splitXp
      ? 'The amount an event pays is the gang\'s total, split between the members who are paid.'
      : 'Each gang member who is paid earns the full amount.',
  };
}

// Replaces every {{name}} in a topic (deeply). An unknown name is left as written so a typo is easy to spot.
export function resolve(node, values) {
  if (typeof node === 'string') return node.replace(/\{\{(\w+)\}\}/g, (m, k) => (values[k] !== undefined ? String(values[k]) : m));
  if (Array.isArray(node)) return node.map((n) => resolve(n, values));
  if (node && typeof node === 'object') {
    const out = {};
    for (const k of Object.keys(node)) out[k] = resolve(node[k], values);
    return out;
  }
  return node;
}
