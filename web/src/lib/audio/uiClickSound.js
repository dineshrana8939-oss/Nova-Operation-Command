// ─── Nova Convoy — UI click sound ─────────────────────────────────────────────────────────────────
// One delegated listener for the whole NUI: any click on a tab, button, toggle, dropdown, link or other
// pointer-cursor element plays Config.Sounds.uiClick (served by client/modules/sound.lua).

import { get } from 'svelte/store';
import { fetchNui, isEnvBrowser } from '../api/nui.js';
import { handlePlaySound } from './soundPlayer.js';
import { adminPrefs } from '../adminPrefs.js';
import { gangPrefs } from '../gangPrefs.js';
import { tabletOpen, livePanelOpen } from '../stores.js';

const CLICKABLE = 'button, a[href], summary, select, label, input[type="checkbox"], input[type="radio"], input[type="range"], [role="button"], [role="tab"], [role="switch"], [role="menuitem"], [role="option"], [role="checkbox"], [data-click-sound]';
const SKIP = '[data-no-click-sound], .minigame-backdrop';
const MAX_DEPTH = 6;

let cfg = null; // { enabled, file, volume }
let loading = false;
let lastAt = 0;

async function loadConfig(tries = 0) {
  if (cfg || loading) return;
  if (isEnvBrowser()) { cfg = { enabled: false }; return; }
  loading = true;
  try {
    const res = await fetchNui('uiSoundConfig');
    if (res && typeof res === 'object') cfg = res;
  } catch (e) {
    /* the client script may not have registered the callback yet */
  }
  loading = false;
  if (cfg) prepareBuffer();
  else if (tries < 12) setTimeout(() => loadConfig(tries + 1), 1500);
}

function isDisabled(el) {
  return el.disabled === true || el.getAttribute('aria-disabled') === 'true' || el.classList.contains('disabled');
}

function findClickable(start) {
  let el = start;
  for (let i = 0; el && el !== document.body && i < MAX_DEPTH; i++, el = el.parentElement) {
    if (el.nodeType !== 1) continue;
    if (el.matches(SKIP)) return null;
    if (isDisabled(el)) return null;
    if (el.matches(CLICKABLE)) {
      // a label only counts when it wraps / points at a control
      if (el.tagName === 'LABEL' && !el.control) continue;
      return el;
    }
    if (getComputedStyle(el).cursor === 'pointer') return el;
  }
  return null;
}

// The file is decoded once into memory and played through Web Audio, so a press makes sound instantly
// (an <audio> element has to re-load / re-buffer on every play, which is the lag you hear).
let ctx = null;
let buffer = null;
let gain = null;
let decoding = false;

function resourceName() {
  return typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'nova_convoytruck';
}

async function prepareBuffer() {
  if (buffer || decoding || !cfg || !cfg.enabled) return;
  decoding = true;
  try {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    ctx = ctx || new AC({ latencyHint: 'interactive' });
    gain = ctx.createGain();
    gain.connect(ctx.destination);
    // the context is created before the first click, so it starts suspended; the first press resumes it (see onPress)
    const res = await fetch(`nui://${resourceName()}/sounds/${encodeURIComponent(cfg.file)}`);
    buffer = await ctx.decodeAudioData(await res.arrayBuffer());
  } catch (e) {
    buffer = null; /* the game could not hand the file over as data: use pre-loaded audio elements below */
    buildPool();
  }
  decoding = false;
}

// Fallback: a few <audio> elements loaded once and rewound on every press (no re-load, so no lag)
let pool = [];
let poolAt = 0;
function buildPool() {
  if (pool.length || !cfg || !cfg.file) return;
  try {
    for (let i = 0; i < 3; i++) {
      const a = new Audio(`nui://${resourceName()}/sounds/${encodeURIComponent(cfg.file)}`);
      a.preload = 'auto';
      a.volume = Math.max(0, Math.min(1, Number(cfg.volume) || 0));
      a.load();
      pool.push(a);
    }
  } catch (e) {
    pool = [];
  }
}

function play() {
  if (!buffer && !pool.length) buildPool();
  if (buffer && ctx && ctx.state !== 'running') {
    // a suspended context makes no sound: wake it, and use a plain audio element for this press
    ctx.resume().catch(() => {});
    if (!pool.length) buildPool();
    if (pool.length) {
      const a = pool[poolAt++ % pool.length];
      a.volume = Math.max(0, Math.min(1, Number(cfg.volume) || 0));
      try { a.currentTime = 0; } catch (e) { /* not seekable yet */ }
      a.play().catch(() => {});
      return;
    }
  }
  if (buffer && ctx) {
    const src = ctx.createBufferSource();
    src.buffer = buffer;
    gain.gain.value = Math.max(0, Math.min(1, Number(cfg.volume) || 0));
    src.connect(gain);
    src.start(0);
  } else if (pool.length) {
    const a = pool[poolAt++ % pool.length];
    try { a.currentTime = 0; } catch (e) { /* not seekable yet */ }
    a.play().catch(() => {});
  } else {
    handlePlaySound({ file: cfg.file, volume: cfg.volume });
  }
}

// The two tablets each carry their own "UI Click Sounds" switch: the Admin Panel's root is marked data-ui-scope="admin",
// the Gang Tablet's data-ui-scope="gang". A press inside one whose switch is off stays silent; every other window keeps
// the sound as configured. Only this click sound is affected — never gameplay audio, announcements or other sounds.
// A press outside both panels (a confirm dialog or modal that is drawn at the top of the page) used to ignore the switches and always
// played. It now follows whichever panel is open: the Admin Panel's switch while the tablet is open, otherwise the Gang Tablet's.
function silencedByPrefs(target) {
  const scope = target && target.closest ? target.closest('[data-ui-scope]') : null;
  let which = scope ? scope.getAttribute('data-ui-scope') : '';
  if (!which) which = get(tabletOpen) ? 'admin' : 'gang';
  if (which === 'admin') return get(adminPrefs).clickSounds === false;
  return get(gangPrefs).clickSounds === false;
}

// pointerdown, not click: click only fires when the mouse button is released
function onPress(e) {
  if (ctx && ctx.state === 'suspended' && e.isTrusted) ctx.resume().catch(() => {});   // any real press unlocks the audio
  if (!cfg) { loadConfig(); return; }
  if (!cfg.enabled || !e.isTrusted || e.button !== 0) return;
  if (silencedByPrefs(e.target)) return;
  const now = performance.now();
  if (now - lastAt < 50) return;
  if (!findClickable(e.target)) return;
  lastAt = now;
  play();
}

export function initUiClickSound() {
  loadConfig();
  document.addEventListener('pointerdown', onPress, true);
  return () => document.removeEventListener('pointerdown', onPress, true);
}
