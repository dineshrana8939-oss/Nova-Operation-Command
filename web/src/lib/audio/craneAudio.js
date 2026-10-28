// ─── Nova Convoy — Gantry crane audio (synthesised) ───────────────────────────────────────────────
// The game's own crane sounds need audio banks that are not always loaded, and a failure is silent. This makes
// the crane's sound itself with the Web Audio API — no sound files, nothing to load — so it is always audible.
//
// The client script (client/modules/container_wars.lua) sends { action: 'craneAudio', state, volume }:
//   state   PICKING_UP | MOVING | PLACING  → a looping machinery sound, pitched for that stage
//           IMPACT                         → the container lands: a heavy thump and a metal clank (the loop stops)
//           VOLUME                         → only changes how loud the loop is (the player walked closer / further)
//           STOP                           → fades the loop out
//   volume  0..1, already scaled by the player's distance to the crane
//
// Every stage is a low drone (two detuned oscillators through a low-pass) with a rumble of filtered noise, whose
// pitch, rumble and "chug" (a slow tremolo, like a motor under load) change per stage.

let ctx = null;
let master = null;     // one gain for the whole crane: follows the distance volume
let loop = null;       // the running loop: { nodes, stage }
let noiseBuf = null;

const MASTER_LEVEL = 0.28;   // overall loudness of the crane at point-blank range

// what each stage sounds like
const STAGES = {
  PICKING_UP: { f: 62, f2: 93, cutoff: 520, rumble: 0.5, chug: 5.5, depth: 0.35, whine: 0.0 },   // hoisting: tense winch
  MOVING:     { f: 46, f2: 69, cutoff: 360, rumble: 0.7, chug: 2.6, depth: 0.25, whine: 0.0 },   // gantry rolling along its rails
  PLACING:    { f: 54, f2: 81, cutoff: 460, rumble: 0.5, chug: 4.2, depth: 0.3,  whine: 0.0 },   // lowering
};

function getCtx() {
  if (ctx) return ctx;
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) return null;
  ctx = new AudioCtx();
  master = ctx.createGain();
  master.gain.value = 0;
  master.connect(ctx.destination);
  return ctx;
}

// two seconds of brown-ish noise, made once and looped
function noise() {
  if (noiseBuf) return noiseBuf;
  const len = ctx.sampleRate * 2;
  noiseBuf = ctx.createBuffer(1, len, ctx.sampleRate);
  const d = noiseBuf.getChannelData(0);
  let last = 0;
  for (let i = 0; i < len; i++) {
    const white = Math.random() * 2 - 1;
    last = (last + 0.02 * white) / 1.02;
    d[i] = last * 3.5;
  }
  return noiseBuf;
}

function setVolume(v, fast) {
  if (!ctx || !master) return;
  const target = Math.max(0, Math.min(1, Number(v) || 0)) * MASTER_LEVEL;
  master.gain.setTargetAtTime(target, ctx.currentTime, fast ? 0.02 : 0.15);
}

function stopLoop(fade = 0.25) {
  if (!loop || !ctx) { loop = null; return; }
  const l = loop;
  loop = null;
  try {
    l.out.gain.cancelScheduledValues(ctx.currentTime);
    l.out.gain.setTargetAtTime(0, ctx.currentTime, fade / 3);
    const end = ctx.currentTime + fade + 0.1;
    l.nodes.forEach((n) => { try { n.stop(end); } catch (e) { /* already stopped */ } });
    setTimeout(() => { try { l.out.disconnect(); } catch (e) { /* ignore */ } }, (fade + 0.3) * 1000);
  } catch (e) { /* ignore */ }
}

function startLoop(stage) {
  const s = STAGES[stage];
  if (!s) return;
  if (loop && loop.stage === stage) return;
  stopLoop(0.18);

  const t = ctx.currentTime;
  const out = ctx.createGain();           // this loop's fade in / out
  out.gain.setValueAtTime(0, t);
  out.gain.setTargetAtTime(1, t, 0.12);
  out.connect(master);

  // the "chug": a slow tremolo on everything
  const trem = ctx.createGain();
  trem.gain.value = 1 - s.depth;
  const lfo = ctx.createOscillator();
  lfo.frequency.value = s.chug;
  const lfoAmt = ctx.createGain();
  lfoAmt.gain.value = s.depth;
  lfo.connect(lfoAmt);
  lfoAmt.connect(trem.gain);
  trem.connect(out);

  // the drone
  const lp = ctx.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.value = s.cutoff;
  lp.Q.value = 1.4;
  lp.connect(trem);
  const o1 = ctx.createOscillator();
  o1.type = 'sawtooth';
  o1.frequency.value = s.f;
  const o2 = ctx.createOscillator();
  o2.type = 'triangle';
  o2.frequency.value = s.f2;
  o2.detune.value = 7;
  const g1 = ctx.createGain(); g1.gain.value = 0.5;
  const g2 = ctx.createGain(); g2.gain.value = 0.4;
  o1.connect(g1); g1.connect(lp);
  o2.connect(g2); g2.connect(lp);

  // the rumble
  const src = ctx.createBufferSource();
  src.buffer = noise();
  src.loop = true;
  const bp = ctx.createBiquadFilter();
  bp.type = 'bandpass';
  bp.frequency.value = 140;
  bp.Q.value = 0.7;
  const ng = ctx.createGain();
  ng.gain.value = s.rumble;
  src.connect(bp); bp.connect(ng); ng.connect(trem);

  [o1, o2, lfo, src].forEach((n) => n.start(t));
  loop = { stage, out, nodes: [o1, o2, lfo, src] };
}

// the container lands: a thump that falls in pitch, a burst of low noise, and a short metal clank
function impact() {
  const t = ctx.currentTime;
  const out = ctx.createGain();
  out.gain.value = 1;
  out.connect(master);

  const thump = ctx.createOscillator();
  thump.type = 'sine';
  thump.frequency.setValueAtTime(95, t);
  thump.frequency.exponentialRampToValueAtTime(28, t + 0.45);
  const tg = ctx.createGain();
  tg.gain.setValueAtTime(1.2, t);
  tg.gain.exponentialRampToValueAtTime(0.001, t + 0.6);
  thump.connect(tg); tg.connect(out);
  thump.start(t); thump.stop(t + 0.65);

  const burst = ctx.createBufferSource();
  burst.buffer = noise();
  const lp = ctx.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.setValueAtTime(900, t);
  lp.frequency.exponentialRampToValueAtTime(120, t + 0.4);
  const bg = ctx.createGain();
  bg.gain.setValueAtTime(1.4, t);
  bg.gain.exponentialRampToValueAtTime(0.001, t + 0.5);
  burst.connect(lp); lp.connect(bg); bg.connect(out);
  burst.start(t, Math.random()); burst.stop(t + 0.55);

  // metal: a few inharmonic partials ringing out
  [210, 340, 553, 811].forEach((f, i) => {
    const o = ctx.createOscillator();
    o.type = 'square';
    o.frequency.value = f;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.14 / (1 + i * 0.6), t + 0.02);
    g.gain.exponentialRampToValueAtTime(0.001, t + 0.35 + i * 0.05);
    const hp = ctx.createBiquadFilter();
    hp.type = 'bandpass';
    hp.frequency.value = f * 1.5;
    hp.Q.value = 3;
    o.connect(hp); hp.connect(g); g.connect(out);
    o.start(t + 0.02); o.stop(t + 0.5);
  });

  setTimeout(() => { try { out.disconnect(); } catch (e) { /* ignore */ } }, 1200);
}

export function handleCraneAudio(data) {
  try {
    if (!data) return;
    const c = getCtx();
    if (!c) return;
    if (c.state === 'suspended') c.resume();
    const state = data.state;
    if (state === 'STOP') { stopLoop(0.4); return; }
    if (state === 'VOLUME') { setVolume(data.volume); return; }
    if (state === 'IMPACT') {
      stopLoop(0.12);
      setVolume(data.volume, true);
      impact();
      return;
    }
    if (STAGES[state]) {
      setVolume(data.volume);
      startLoop(state);
    }
  } catch (e) {
    // audio is a nicety — never let it break the page
  }
}
