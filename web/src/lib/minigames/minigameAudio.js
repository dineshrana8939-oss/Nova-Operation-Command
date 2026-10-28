// ─── Nova Convoy — Native Minigame Synthesized Audio ──────────────────────
// Built-in Web Audio API synthesizers — zero external sound files required.

// One shared AudioContext for the whole minigame suite, created lazily on
// first use. Spinning up a new AudioContext per tone (the old behaviour) is
// real, avoidable overhead — games like Hotwire/Quicktime/Mash fire several
// tones a second, and each fresh context allocates its own OS-level audio
// device handle that the browser doesn't free instantly.
let sharedCtx = null;

function getCtx() {
  if (sharedCtx) return sharedCtx;
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) return null;
  sharedCtx = new AudioCtx();
  return sharedCtx;
}

function playTone(freq, type = 'sine', duration = 0.08, volume = 0.18) {
  try {
    const ctx = getCtx();
    if (!ctx) return;
    // Browsers suspend a context created/resumed outside a user gesture;
    // the NUI focus grant that opens the minigame counts as one, so this
    // resolves immediately in practice and is a no-op once running.
    if (ctx.state === 'suspended') ctx.resume();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = type;
    osc.frequency.value = freq;
    gain.gain.setValueAtTime(volume, ctx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + duration);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + duration);
  } catch (e) {
    // Ignore audio context block if user has not interacted
  }
}

export function sfxSuccess() {
  playTone(523.25, 'triangle', 0.1, 0.2); // C5
  setTimeout(() => playTone(659.25, 'triangle', 0.1, 0.2), 90); // E5
  setTimeout(() => playTone(783.99, 'triangle', 0.22, 0.25), 180); // G5
}

export function sfxFail() {
  playTone(260, 'sawtooth', 0.12, 0.25);
  setTimeout(() => playTone(180, 'sawtooth', 0.25, 0.25), 100);
}

export function sfxClick() {
  playTone(1100, 'sine', 0.04, 0.15);
}

export function sfxLatch() {
  playTone(850, 'triangle', 0.05, 0.2);
  setTimeout(() => playTone(1400, 'sine', 0.07, 0.2), 30);
}

export function sfxTick() {
  playTone(600, 'square', 0.02, 0.08);
}
