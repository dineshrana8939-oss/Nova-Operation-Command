<script>
  import { onMount, onDestroy } from 'svelte';
  import { minigameState, closeMinigame } from './minigameStore.js';
  import { sfxSuccess, sfxFail, sfxClick, sfxLatch, sfxTick } from './minigameAudio.js';
  import { fetchNui } from '../api/nui.js';
  import { extraGames } from './extraGames.js';

  // ─── Input probe ───────────────────────────────────────────────────────
  // Works for EVERY game (it sits on window in the capture phase, before any
  // game's own handlers). The first mouse press / key press logs
  // "[minigame] input OK"; if nothing arrives within 8s of a game starting,
  // it logs a warning and tells the Lua side, which prints whether NUI focus
  // is held. That is how you tell, game by game, whether input reaches it.
  let probeSeen = false;
  let probeTimer = null;
  function onProbeInput(e) {
    if (probeSeen) return;
    probeSeen = true;
    console.log('[minigame] input OK (' + e.type + ') game=' + game);
  }
  function stopInputProbe() {
    if (probeTimer) { clearTimeout(probeTimer); probeTimer = null; }
    window.removeEventListener('mousedown', onProbeInput, true);
    window.removeEventListener('keydown', onProbeInput, true);
  }
  function startInputProbe() {
    stopInputProbe();
    probeSeen = false;
    window.addEventListener('mousedown', onProbeInput, true);
    window.addEventListener('keydown', onProbeInput, true);
    const g = game;
    probeTimer = setTimeout(() => {
      if (!probeSeen && active) {
        console.warn('[minigame] NO mouse/keyboard input reached the overlay in 8s, game=' + g);
        fetchNui('nova_convoytruck:minigame:noInput', { game: g });
      }
    }, 8000);
  }
  $: if (!active) stopInputProbe();

  $: active = $minigameState.active;
  $: game = $minigameState.game || 'lugnuts';
  $: difficulty = $minigameState.difficulty || 2;
  $: title = $minigameState.title || 'SKILL CHECK';
  $: maxDuration = $minigameState.duration || 18;

  let canvasEl;
  let animFrame;
  let timerInterval;
  let timeRemaining = 18;
  let outcome = null; // null | 'success' | 'fail'
  let isShaking = false;
  let inputReadyTime = 0;

  // Cleanup helper
  let gameCleanup = null;

  // ─── Extended minigame bridge ──────────────────────────────────────────
  // A second batch of games, ported from a standalone vanilla-JS pack whose
  // games all shared this exact same run(api) shape (board/cfg/startTimer/
  // setDots/succeed/fail/etc). Rather than re-writing each one as a
  // from-scratch Svelte canvas function like the 20 above, they're pasted
  // in near-verbatim under EXT_RUNNERS and driven through this bridge, which
  // just maps their `api.*` calls onto this component's own existing
  // timer/outcome state. Re-themed to THIS app's palette (not the source
  // pack's teal one) via the --accent/--success/--danger custom properties
  // read by every pasted game — see the :global(:root) block in <style>.
  let extBoardEl;
  let isExtGame = false;
  let extHint = '';
  let extTag = '';
  let dotsTotal = 0;
  let dotsStates = [];
  let extExpireCb = null; // set by a game's own api.startTimer(seconds, onExpire)

  function apiStartTimer(seconds, onExpire) {
    maxDuration = seconds;
    extExpireCb = onExpire || null;
    startTimer();
  }
  function makeApi(diff) {
    return {
      get board() { return extBoardEl; },
      set board(v) { extBoardEl = v; },
      cfg: { difficulty: diff },
      startTimer: apiStartTimer,
      stopTimer,
      addTime: (ms) => { timeRemaining = Math.min(maxDuration, timeRemaining + ms / 1000); },
      setDots: (total, states) => { dotsTotal = total; dotsStates = states || []; },
      setHint: (t) => { extHint = t || ''; },
      setTag: (t) => { extTag = t || ''; },
      succeed: handleWin,
      fail: handleFail,
      shake: triggerShake,
      sfx: (name) => {
        if (name === 'latch' || name === 'zap' || name === 'good' || name === 'whoosh') sfxLatch();
        else if (name === 'bad' || name === 'error') sfxFail();
        else if (name === 'tick') sfxTick();
        else sfxClick();
      },
      rand: (a, b) => a + Math.random() * (b - a),
      randInt: (a, b) => Math.floor(a + Math.random() * (b - a + 1)),
    };
  }

  $: if (active && (canvasEl || extBoardEl)) {
    initGame();
  }

  function triggerShake() {
    isShaking = true;
    sfxFail();
    setTimeout(() => { isShaking = false; }, 400);
  }

  function handleWin() {
    if (outcome) return;
    outcome = 'success';
    sfxSuccess();
    stopTimer();
    setTimeout(() => {
      closeMinigame(true);
      outcome = null;
    }, 600);
  }

  function handleFail() {
    if (outcome) return;
    // Suppress any premature failure from lingering mouse clicks or keydown events
    // that fired during target/interaction initiation before minigame was visible
    if (performance.now() < inputReadyTime) {
      console.warn('[minigame] Suppressed premature failure during initial grace period');
      return;
    }
    outcome = 'fail';
    triggerShake();
    stopTimer();
    setTimeout(() => {
      closeMinigame(false);
      outcome = null;
    }, 600);
  }

  function startTimer() {
    stopTimer();
    timeRemaining = maxDuration;
    timerInterval = setInterval(() => {
      timeRemaining -= 0.1;
      if (timeRemaining <= 0) {
        timeRemaining = 0;
        const cb = extExpireCb;
        extExpireCb = null;
        stopTimer();
        if (cb) cb(); else handleFail();
      }
    }, 100);
  }

  function stopTimer() {
    if (timerInterval) clearInterval(timerInterval);
    timerInterval = null;
  }

  // Fully SYNCHRONOUS, no `await tick()` anywhere in here — matching the
  // reference eye_minigames project's `open()` (html/engine.js), which is
  // also one flat synchronous function. That reference never needs to wait
  // for anything because its #board container already exists in the DOM
  // long before any message can arrive; the same is now true here since
  // MinigameOverlay is always-mounted (see the removed {#if active} note
  // near the markup below) — canvasEl/extBoardEl are bound once, at this
  // component's own initial page-load mount, well before the player can
  // possibly trigger a minigame. Every previous fix in this area (a bounded
  // retry across animation frames, then a single tick()) was patching
  // around an async gap that plain synchronous code doesn't have at all —
  // removing the gap entirely instead of widening the retry window around it.
  function initGame() {
    outcome = null;
    inputReadyTime = performance.now() + 450;
    extHint = '';
    extTag = '';
    dotsTotal = 0;
    dotsStates = [];
    extExpireCb = null;
    if (gameCleanup) {
      try {
        if (typeof gameCleanup === 'function') gameCleanup();
        else if (gameCleanup && typeof gameCleanup.destroy === 'function') gameCleanup.destroy();
      } catch (e) { console.error(e); }
      gameCleanup = null;
    }
    if (animFrame) {
      cancelAnimationFrame(animFrame);
      animFrame = null;
    }

    if (extBoardEl) extBoardEl.innerHTML = '';
    startInputProbe();
    startTimer();

    // Kept in sync with client/modules/minigames.lua's ALL_GAMES — 70 games total
    const ALL_GAMES = [
      'lugnuts', 'skillcheck', 'quicktime', 'hotwire', 'reaction',
      'keypad', 'livewire', 'lockpick', 'mash', 'targets', 'lightsout',
      'stacker', 'slidepuzzle', 'vaultspin', 'pulse', 'breachmatrix',
      'cascade', 'tripwire', 'constellation', 'fingerprint',
      'thermite', 'lasergrid', 'forge', 'archery', 'parry',
      'cuttheright', 'decrypt', 'vaultdrill', 'pickpocket',
      'animus', 'beltsort', 'bluff', 'bonepin', 'breathalyzer', 'cashcount',
      'chopshop', 'cooking', 'counterfeit', 'crafting', 'crane', 'daemonrun',
      'dataheist', 'deadcalm', 'diving', 'drilling', 'eaglevision', 'fishing',
      'flatline', 'gaslight', 'getaway', 'ghostsignal', 'harvest', 'hottrace',
      'intrusion', 'jammer', 'locksmith', 'mining', 'overflow', 'override',
      'packing', 'paintspray', 'partsort', 'pillpress', 'resonance', 'steadydose',
      'suture', 'titration', 'toolbox', 'vitals', 'welding',
    ];
    const chosen = (game === 'random' || !game)
      ? ALL_GAMES[Math.floor(Math.random() * ALL_GAMES.length)]
      : game;

    const runners = {
      lugnuts: runLugnuts,
      skillcheck: runSkillCheck,
      quicktime: runQuicktime,
      hotwire: runHotwire,
      reaction: runReaction,
      keypad: runKeypad,
      livewire: runLivewire,
      lockpick: runLockpick,
      mash: runMash,
      targets: runTargets,
      lightsout: runLightsOut,
      stacker: runStacker,
      slidepuzzle: runSlidePuzzle,
      vaultspin: runVaultSpin,
      pulse: runPulse,
      breachmatrix: runBreachMatrix,
      cascade: runCascade,
      tripwire: runTripwire,
      constellation: runConstellation,
      fingerprint: runFingerprint,
    };
    const extRunners = {
      thermite: extThermite,
      lasergrid: extLasergrid,
      forge: extForge,
      archery: extArchery,
      parry: extParry,
      cuttheright: extCutTheRight,
      decrypt: extDecrypt,
      vaultdrill: extVaultDrill,
      pickpocket: extPickpocket,
    };

    if (extRunners[chosen] || (extraGames && extraGames[chosen])) {
      isExtGame = true;
      if (!extBoardEl) {
        console.error('[minigame] extBoardEl missing at game start for', chosen);
        handleFail();
        return;
      }
      const extraDef = extraGames && extraGames[chosen];
      if (extraDef) {
        if (extraDef.title) title = extraDef.title;
        if (extraDef.hint) extHint = extraDef.hint;
      }
      try {
        const runner = extraDef ? extraDef.run : extRunners[chosen];
        gameCleanup = runner(makeApi(difficulty));
      } catch (err) {
        console.error('Extended minigame failed to run:', err);
        handleFail();
      }
    } else {
      isExtGame = false;
      if (!canvasEl) {
        console.error('[minigame] canvasEl missing at game start for', chosen);
        handleFail();
        return;
      }
      try {
        gameCleanup = (runners[chosen] || runLugnuts)();
      } catch (err) {
        console.error('Canvas minigame failed to run:', err);
        handleFail();
      }
    }
  }

  // ─── 1. LUG NUTS (WHEEL TORQUE) ──────────────────────────────────────────
  function runLugnuts() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');
    const cx = W / 2, cy = H / 2 - 25;

    const N = 5;
    const order = [0, 2, 4, 1, 3]; // star pattern
    const nuts = [];
    for (let i = 0; i < N; i++) {
      const a = -Math.PI / 2 + i * (Math.PI * 2 / N);
      nuts.push({ x: cx + Math.cos(a) * 85, y: cy + Math.sin(a) * 85, set: false });
    }

    let step = 0;
    let t = 0;
    const band = Math.max(0.12, 0.28 - difficulty * 0.035);
    const lo = 0.58, hi = lo + band;
    const spd = 0.014 + difficulty * 0.005;

    function attempt() {
      if (outcome || performance.now() < inputReadyTime) return;
      if (t >= lo && t <= hi) {
        nuts[order[step]].set = true;
        sfxLatch();
        step++;
        t = 0;
        if (step >= N) {
          handleWin();
        }
      } else {
        triggerShake();
        timeRemaining = Math.max(0, timeRemaining - 2.0);
        t = 0;
      }
    }

    function onKey(e) {
      if (e.code === 'Space') {
        e.preventDefault();
        attempt();
      }
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', attempt);

    function drawNut(x, y, r, col, glow) {
      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(Math.PI / 6);
      ctx.beginPath();
      for (let k = 0; k < 6; k++) {
        const a = k * Math.PI / 3;
        const px = Math.cos(a) * r, py = Math.sin(a) * r;
        k ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
      }
      ctx.closePath();
      ctx.fillStyle = col;
      ctx.shadowColor = glow ? col : 'transparent';
      ctx.shadowBlur = glow ? 14 : 0;
      ctx.fill();
      ctx.restore();
    }

    function loop() {
      if (!outcome) {
        t += spd;
        if (t > 1) t = 0;
      }

      ctx.clearRect(0, 0, W, H);

      // Wheel Rim Visual
      ctx.strokeStyle = 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 20;
      ctx.beginPath();
      ctx.arc(cx, cy, 85, 0, Math.PI * 2);
      ctx.stroke();

      ctx.fillStyle = 'rgba(255,255,255,0.03)';
      ctx.beginPath();
      ctx.arc(cx, cy, 65, 0, Math.PI * 2);
      ctx.fill();

      // Center Hub
      ctx.fillStyle = '#0f172a';
      ctx.strokeStyle = '#ffd60a';
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.arc(cx, cy, 32, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = '#ffd60a';
      ctx.font = 'bold 12px monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(`NUT ${step}/${N}`, cx, cy);

      // Nuts
      const activeNut = outcome ? -1 : order[step];
      nuts.forEach((n, i) => {
        const isDone = n.set;
        const isActive = i === activeNut;
        const col = isDone ? '#30d158' : (isActive ? '#ff8c33' : 'rgba(255,255,255,0.25)');
        drawNut(n.x, n.y, 14, col, isDone || isActive);
      });

      // Bottom Torque Gauge
      const gx = 45, gy = H - 35, gw = W - 90, gh = 14;
      ctx.fillStyle = 'rgba(255,255,255,0.07)';
      ctx.fillRect(gx, gy, gw, gh);

      // Green Band
      ctx.fillStyle = 'rgba(48, 209, 88, 0.45)';
      ctx.fillRect(gx + gw * lo, gy, gw * (hi - lo), gh);

      // Torque Needle
      const inZone = t >= lo && t <= hi;
      ctx.fillStyle = inZone ? '#30d158' : '#ff8c33';
      ctx.shadowColor = inZone ? '#30d158' : '#ff8c33';
      ctx.shadowBlur = inZone ? 12 : 6;
      ctx.fillRect(gx + gw * t - 3, gy - 4, 6, gh + 8);
      ctx.shadowBlur = 0;

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '11px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('SPACE / CLICK IN GREEN TORQUE ZONE', cx, gy - 8);

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', attempt);
    };
  }

  // ─── 2. SKILL CHECK (RADIAL NEEDLE) ──────────────────────────────────────
  function runSkillCheck() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');
    const cx = W / 2, cy = H / 2, R = 110;

    const need = 3;
    let done = 0;
    let mistakes = 0;
    const maxMistakes = 2; // Allow 2 misses with shake & time penalty before outright failure
    const zoneSize = Math.max(0.24, 0.65 - difficulty * 0.08);
    const speed = 0.024 + difficulty * 0.012;
    let ang = 0, dir = 1, zoneStart = 0;

    function newZone() {
      zoneStart = Math.random() * Math.PI * 2;
      dir = Math.random() < 0.5 ? 1 : -1;
      ang = zoneStart + Math.PI + (Math.random() - 0.5);
    }
    newZone();

    function attempt() {
      if (outcome || performance.now() < inputReadyTime) return;
      let d = ang - zoneStart;
      d = ((d % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2);
      if (d <= zoneSize) {
        done++;
        sfxLatch();
        if (done >= need) {
          handleWin();
        } else {
          newZone();
        }
      } else {
        triggerShake();
        mistakes++;
        timeRemaining = Math.max(0, timeRemaining - 2.5);
        if (mistakes >= maxMistakes || timeRemaining <= 0) {
          handleFail();
        } else {
          newZone();
        }
      }
    }

    function onKey(e) {
      if (e.code === 'Space') {
        e.preventDefault();
        attempt();
      }
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', attempt);

    function loop() {
      if (!outcome) ang += speed * dir;

      ctx.clearRect(0, 0, W, H);

      // Track Circle
      ctx.strokeStyle = 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 16;
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, Math.PI * 2);
      ctx.stroke();

      // Green Target Arc
      ctx.strokeStyle = '#30d158';
      ctx.shadowColor = '#30d158';
      ctx.shadowBlur = 14;
      ctx.beginPath();
      ctx.arc(cx, cy, R, zoneStart, zoneStart + zoneSize);
      ctx.stroke();
      ctx.shadowBlur = 0;

      // Rotating Marker Needle
      const mx = cx + Math.cos(ang) * R, my = cy + Math.sin(ang) * R;
      ctx.fillStyle = '#fff';
      ctx.shadowColor = '#ff8c33';
      ctx.shadowBlur = 14;
      ctx.beginPath();
      ctx.arc(mx, my, 11, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;

      // Center Counter
      ctx.fillStyle = '#ff8c33';
      ctx.font = 'bold 36px monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(`${done}/${need}`, cx, cy);

      ctx.fillStyle = 'rgba(255,255,255,0.6)';
      ctx.font = '12px monospace';
      ctx.fillText('SPACE / CLICK IN GREEN', cx, cy + 32);

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', attempt);
    };
  }

  // ─── 3. QUICKTIME (KEY SEQUENCE) ─────────────────────────────────────────
  let qteKeys = [];
  let qteIndex = 0;
  let qteTimeProgress = 1.0;
  function runQuicktime() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const pool = ['Q', 'W', 'E', 'R', 'A', 'S', 'D', 'F'];
    const count = 4 + difficulty;
    qteKeys = [];
    for (let i = 0; i < count; i++) {
      qteKeys.push(pool[Math.floor(Math.random() * pool.length)]);
    }
    qteIndex = 0;

    const perKeySeconds = Math.max(0.9, 2.2 - difficulty * 0.3);
    let keyStart = performance.now();
    let mistakes = 0;
    const maxMistakes = 2;

    function onKey(e) {
      if (outcome || performance.now() < inputReadyTime) return;
      const k = e.key.toUpperCase();
      if (!pool.includes(k)) return;
      e.preventDefault();
      if (k === qteKeys[qteIndex]) {
        sfxLatch();
        qteIndex++;
        keyStart = performance.now();
        if (qteIndex >= count) {
          handleWin();
        }
      } else {
        triggerShake();
        mistakes++;
        keyStart = performance.now();
        timeRemaining = Math.max(0, timeRemaining - 2.0);
        if (mistakes >= maxMistakes || timeRemaining <= 0) {
          handleFail();
        }
      }
    }
    window.addEventListener('keydown', onKey);

    function loop() {
      const elapsed = (performance.now() - keyStart) / 1000;
      qteTimeProgress = Math.max(0, 1 - elapsed / perKeySeconds);

      if (qteTimeProgress <= 0 && !outcome) {
        handleFail();
        return;
      }

      ctx.clearRect(0, 0, W, H);

      // Title & Instruction
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('PRESS KEYS IN ORDER', W / 2, 50);

      // Render Keys
      const keyW = 46, gap = 12;
      const totalW = qteKeys.length * keyW + (qteKeys.length - 1) * gap;
      const startX = (W - totalW) / 2;
      const keyY = H / 2 - 25;

      qteKeys.forEach((k, i) => {
        const x = startX + i * (keyW + gap);
        const isDone = i < qteIndex;
        const isActive = i === qteIndex;

        ctx.fillStyle = isDone ? 'rgba(48, 209, 88, 0.2)' : (isActive ? 'rgba(255, 140, 51, 0.25)' : 'rgba(255,255,255,0.05)');
        ctx.strokeStyle = isDone ? '#30d158' : (isActive ? '#ff8c33' : 'rgba(255,255,255,0.15)');
        ctx.lineWidth = isActive ? 3 : 2;

        ctx.fillRect(x, keyY, keyW, keyW);
        ctx.strokeRect(x, keyY, keyW, keyW);

        ctx.fillStyle = isDone ? '#30d158' : (isActive ? '#fff' : 'rgba(255,255,255,0.4)');
        ctx.font = 'bold 20px monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(k, x + keyW / 2, keyY + keyW / 2);
      });

      // Individual Key Timer Bar
      const barW = 260, barH = 8;
      const barX = (W - barW) / 2, barY = H / 2 + 55;
      ctx.fillStyle = 'rgba(255,255,255,0.08)';
      ctx.fillRect(barX, barY, barW, barH);

      ctx.fillStyle = qteTimeProgress < 0.3 ? '#ff453a' : '#ff8c33';
      ctx.fillRect(barX, barY, barW * qteTimeProgress, barH);

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
    };
  }

  // ─── 4. HOTWIRE (WIRE MATCH & SPARK) ─────────────────────────────────────
  function runHotwire() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const pairCount = 3 + Math.min(2, Math.floor(difficulty / 2));
    const colors = ['#ff453a', '#3b82f6', '#ffd60a', '#30d158', '#a855f7'];
    const order = [...Array(pairCount).keys()];
    const rightOrder = order.slice().sort(() => Math.random() - 0.5);

    const gap = (H - 140) / (pairCount - 1 || 1);
    const left = order.map((i) => ({ x: 50, y: 50 + i * gap, c: colors[i], done: false }));
    const right = rightOrder.map((cIdx, i) => ({ x: W - 50, y: 50 + i * gap, c: colors[cIdx], done: false }));

    let selectedLeft = null;
    let mouse = { x: 0, y: 0 };
    let phase = 'wires'; // 'wires' | 'spark'
    let sparkReady = false;
    const connectedWires = [];
    let sparkPos = 50, sparkDir = 1;
    const sparkZoneW = Math.max(45, 80 - difficulty * 10);
    const sparkZoneX = 80 + Math.random() * (W - 160 - sparkZoneW);
    const sparkSpeed = 2.4 + difficulty * 0.8;

    function getCoords(e) {
      const rect = canvasEl.getBoundingClientRect();
      return {
        x: (e.clientX - rect.left) * (W / rect.width),
        y: (e.clientY - rect.top) * (H / rect.height),
      };
    }

    function onMouseDown(e) {
      if (outcome || phase !== 'wires') return;
      const pt = getCoords(e);
      const clickedLeft = left.find((n) => Math.hypot(n.x - pt.x, n.y - pt.y) < 18);
      if (clickedLeft && !clickedLeft.done) {
        selectedLeft = clickedLeft;
        sfxClick();
      }
    }

    function onMouseMove(e) {
      mouse = getCoords(e);
    }

    function onMouseUp(e) {
      if (outcome || phase !== 'wires' || !selectedLeft) return;
      const pt = getCoords(e);
      const clickedRight = right.find((n) => Math.hypot(n.x - pt.x, n.y - pt.y) < 18);
      if (clickedRight && clickedRight.c === selectedLeft.c && !clickedRight.done) {
        selectedLeft.done = true;
        clickedRight.done = true;
        connectedWires.push({ a: selectedLeft, b: clickedRight, c: selectedLeft.c });
        sfxLatch();
        if (connectedWires.length >= pairCount) {
          phase = 'spark';
          sparkPos = 50;
          sparkDir = 1;
          setTimeout(() => { sparkReady = true; }, 400);
        }
      } else if (clickedRight) {
        handleFail();
      }
      selectedLeft = null;
    }

    function onClick() {
      if (phase === 'spark' && !outcome && sparkReady) {
        if (sparkPos >= sparkZoneX && sparkPos <= sparkZoneX + sparkZoneW) {
          handleWin();
        } else {
          handleFail();
        }
      }
    }

    function onKey(e) {
      if (e.code === 'Space' && phase === 'spark' && sparkReady) {
        e.preventDefault();
        onClick();
      }
    }

    canvasEl.addEventListener('mousedown', onMouseDown);
    canvasEl.addEventListener('mousemove', onMouseMove);
    canvasEl.addEventListener('mouseup', onMouseUp);
    canvasEl.addEventListener('click', onClick);
    window.addEventListener('keydown', onKey);

    function drawWire(x1, y1, x2, y2, color, width) {
      ctx.strokeStyle = color;
      ctx.lineWidth = width;
      ctx.lineCap = 'round';
      ctx.shadowColor = color;
      ctx.shadowBlur = 8;
      const mx = (x1 + x2) / 2;
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2);
      ctx.stroke();
      ctx.shadowBlur = 0;
    }

    function loop() {
      ctx.clearRect(0, 0, W, H);

      // Connected Wires
      connectedWires.forEach((w) => drawWire(w.a.x, w.a.y, w.b.x, w.b.y, w.c, 5));

      // Active dragged wire
      if (selectedLeft) {
        drawWire(selectedLeft.x, selectedLeft.y, mouse.x, mouse.y, selectedLeft.c, 4);
      }

      // Draw Terminals
      const drawTerminal = (n) => {
        ctx.fillStyle = n.done ? n.c : '#0f172a';
        ctx.strokeStyle = n.c;
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.arc(n.x, n.y, 11, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
      };
      left.forEach(drawTerminal);
      right.forEach(drawTerminal);

      if (phase === 'wires') {
        ctx.fillStyle = 'rgba(255,255,255,0.7)';
        ctx.font = '12px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('CONNECT MATCHING COLORED WIRES', W / 2, 28);
      } else {
        // Ignition Spark Phase
        const ty = H - 35;
        ctx.fillStyle = 'rgba(255,255,255,0.08)';
        ctx.fillRect(40, ty - 12, W - 80, 24);

        ctx.fillStyle = 'rgba(48, 209, 88, 0.4)';
        ctx.fillRect(sparkZoneX, ty - 12, sparkZoneW, 24);

        if (!outcome && sparkReady) {
          sparkPos += sparkDir * sparkSpeed;
          if (sparkPos > W - 50) { sparkPos = W - 50; sparkDir = -1; }
          if (sparkPos < 50) { sparkPos = 50; sparkDir = 1; }
        }

        ctx.fillStyle = '#fff';
        ctx.fillRect(sparkPos - 2, ty - 16, 4, 32);

        ctx.fillStyle = sparkReady ? '#30d158' : '#ffd60a';
        ctx.font = 'bold 12px monospace';
        ctx.textAlign = 'center';
        ctx.fillText(sparkReady ? 'SPACE / CLICK IN GREEN TO IGNITE ENGINE' : 'WIRES MATCHED — GET READY...', W / 2, ty - 22);
      }

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      canvasEl.removeEventListener('mousedown', onMouseDown);
      canvasEl.removeEventListener('mousemove', onMouseMove);
      canvasEl.removeEventListener('mouseup', onMouseUp);
      canvasEl.removeEventListener('click', onClick);
      window.removeEventListener('keydown', onKey);
    };
  }

  // ─── 5. REACTION (REFLEX TRIGGER) ────────────────────────────────────────
  function runReaction() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    let state = 'standby'; // 'standby' | 'ready' | 'go'
    let greenTime = 0;
    let falseStarts = 0;
    const maxFalseStarts = 2;
    let timeout = null;

    function scheduleGo(delay) {
      if (timeout) clearTimeout(timeout);
      timeout = setTimeout(() => {
        state = 'go';
        greenTime = performance.now();
        sfxLatch();
      }, delay);
    }
    scheduleGo(1800 + Math.random() * 2200);

    function attempt() {
      if (outcome || performance.now() < inputReadyTime) return;
      if (state === 'go') {
        const reactionMs = performance.now() - greenTime;
        if (reactionMs < 750) {
          handleWin();
        } else {
          handleFail();
        }
      } else {
        // False start
        triggerShake();
        falseStarts++;
        timeRemaining = Math.max(0, timeRemaining - 2.5);
        if (falseStarts >= maxFalseStarts || timeRemaining <= 0) {
          if (timeout) clearTimeout(timeout);
          handleFail();
        } else {
          state = 'standby';
          scheduleGo(1500 + Math.random() * 1500);
        }
      }
    }

    function onKey(e) {
      if (e.code === 'Space') {
        e.preventDefault();
        attempt();
      }
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', attempt);

    function loop() {
      ctx.clearRect(0, 0, W, H);

      // Reaction lights
      const lightR = 26;
      const lx = [W / 2 - 70, W / 2, W / 2 + 70];
      const ly = H / 2 - 20;

      lx.forEach((x, i) => {
        ctx.fillStyle = state === 'go' ? '#30d158' : '#ff453a';
        ctx.shadowColor = state === 'go' ? '#30d158' : '#ff453a';
        ctx.shadowBlur = state === 'go' ? 18 : 10;
        ctx.beginPath();
        ctx.arc(x, ly, lightR, 0, Math.PI * 2);
        ctx.fill();
        ctx.shadowBlur = 0;
      });

      ctx.fillStyle = state === 'go' ? '#30d158' : '#fff';
      ctx.font = 'bold 24px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(state === 'go' ? 'GO! PRESS SPACE!' : 'WAIT FOR GREEN LIGHT...', W / 2, H / 2 + 65);

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      clearTimeout(timeout);
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', attempt);
    };
  }

  // ─── 6. KEYPAD (MEMORY BYPASS) ────────────────────────────────────────────
  function runKeypad() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const cols = 3, rows = 2, pad = 16;
    const cellW = 90, cellH = 70;
    const gridW = cols * cellW + (cols - 1) * pad, gridH = rows * cellH + (rows - 1) * pad;
    const startX = (W - gridW) / 2, startY = 120;
    const cells = [];
    for (let i = 0; i < cols * rows; i++) {
      cells.push({
        x: startX + (i % cols) * (cellW + pad),
        y: startY + Math.floor(i / cols) * (cellH + pad),
        n: i + 1,
      });
    }

    const seqLen = Math.min(cells.length + 2, 3 + difficulty);
    const sequence = [];
    for (let i = 0; i < seqLen; i++) sequence.push(Math.floor(Math.random() * cells.length));

    let phase = 'showing'; // 'showing' | 'input'
    let showIndex = 0;
    let flashUntil = 0;
    let playerIndex = 0;
    const stepMs = Math.max(320, 620 - difficulty * 60);

    const showTimer = setInterval(() => {
      if (outcome) return;
      if (showIndex >= sequence.length) {
        clearInterval(showTimer);
        phase = 'input';
        return;
      }
      flashUntil = performance.now() + stepMs * 0.6;
      sfxTick();
      showIndex++;
    }, stepMs);

    function cellAt(px, py) {
      return cells.find((c) => px >= c.x && px <= c.x + cellW && py >= c.y && py <= c.y + cellH);
    }

    function pressCell(idx) {
      if (outcome || phase !== 'input') return;
      if (idx === sequence[playerIndex]) {
        sfxLatch();
        cells[idx].hit = performance.now() + 220;
        playerIndex++;
        if (playerIndex >= sequence.length) handleWin();
      } else {
        cells[idx].miss = performance.now() + 220;
        handleFail();
      }
    }

    function onClick(e) {
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);
      const c = cellAt(px, py);
      if (c) pressCell(cells.indexOf(c));
    }

    function onKey(e) {
      const n = Number(e.key);
      if (n >= 1 && n <= cells.length) {
        e.preventDefault();
        pressCell(n - 1);
      }
    }

    canvasEl.addEventListener('click', onClick);
    window.addEventListener('keydown', onKey);

    function loop() {
      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(phase === 'showing' ? 'MEMORIZE THE SEQUENCE' : `REPEAT IT — CLICK OR PRESS 1-${cells.length}`, W / 2, 60);

      ctx.fillStyle = '#ff8c33';
      ctx.font = 'bold 13px monospace';
      ctx.fillText(phase === 'showing' ? `${showIndex}/${sequence.length}` : `${playerIndex}/${sequence.length}`, W / 2, 85);

      const now = performance.now();
      cells.forEach((c, i) => {
        const isFlash = phase === 'showing' && showIndex > 0 && sequence[showIndex - 1] === i && now < flashUntil;
        const isHit = c.hit && now < c.hit;
        const isMiss = c.miss && now < c.miss;
        ctx.fillStyle = isMiss ? 'rgba(255, 69, 58, 0.5)' : isHit ? 'rgba(48, 209, 88, 0.5)' : isFlash ? 'rgba(255, 140, 51, 0.55)' : 'rgba(255,255,255,0.06)';
        ctx.strokeStyle = isMiss ? '#ff453a' : isHit ? '#30d158' : isFlash ? '#ff8c33' : 'rgba(255,255,255,0.18)';
        ctx.lineWidth = 2;
        ctx.fillRect(c.x, c.y, cellW, cellH);
        ctx.strokeRect(c.x, c.y, cellW, cellH);

        ctx.fillStyle = isFlash || isHit ? '#fff' : 'rgba(255,255,255,0.6)';
        ctx.font = 'bold 22px monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(String(c.n), c.x + cellW / 2, c.y + cellH / 2);
      });

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      clearInterval(showTimer);
      canvasEl.removeEventListener('click', onClick);
      window.removeEventListener('keydown', onKey);
    };
  }

  // ─── 7. LIVEWIRE (CURRENT STEADYING) ──────────────────────────────────────
  function runLivewire() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    let value = 0.5; // 0..1
    let held = false;
    const riseSpeed = 0.011 + difficulty * 0.002;
    const noiseAmp = 0.006 + difficulty * 0.0015;
    const bandHalfWidth = Math.max(0.09, 0.2 - difficulty * 0.02);
    let bandCenter = 0.5;
    const bandDrift = 0.15 + difficulty * 0.03;
    let t = 0;

    let heldMs = 0;
    const requiredMs = Math.max(1800, 3400 - difficulty * 250);

    function onKeyDown(e) {
      if (e.code === 'Space') { e.preventDefault(); held = true; }
    }
    function onKeyUp(e) {
      if (e.code === 'Space') held = false;
    }
    function onMouseDown() { held = true; }
    function onMouseUp() { held = false; }
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    canvasEl.addEventListener('mousedown', onMouseDown);
    window.addEventListener('mouseup', onMouseUp);

    function loop() {
      if (!outcome) {
        t += 0.016;
        bandCenter = 0.5 + Math.sin(t * bandDrift) * 0.28;
        value += (held ? riseSpeed : -riseSpeed) + (Math.random() - 0.5) * noiseAmp;
        value = Math.max(0, Math.min(1, value));

        const inBand = Math.abs(value - bandCenter) <= bandHalfWidth;
        if (inBand) {
          heldMs += 16;
          if (heldMs >= requiredMs) handleWin();
        } else if (value <= 0.02 || value >= 0.98) {
          handleFail();
        }
      }

      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('HOLD [SPACE] TO KEEP CURRENT IN THE GREEN ZONE', W / 2, 40);

      const barX = 60, barY = 70, barW = 30, barH = 220;
      ctx.fillStyle = 'rgba(255,255,255,0.06)';
      ctx.fillRect(barX, barY, barW, barH);

      const bandY = barY + barH * (1 - Math.min(1, bandCenter + bandHalfWidth));
      const bandH = barH * bandHalfWidth * 2;
      ctx.fillStyle = 'rgba(48, 209, 88, 0.4)';
      ctx.fillRect(barX, bandY, barW, bandH);

      const needleY = barY + barH * (1 - value);
      ctx.fillStyle = value <= 0.05 || value >= 0.95 ? '#ff453a' : '#ff8c33';
      ctx.shadowColor = ctx.fillStyle;
      ctx.shadowBlur = 10;
      ctx.fillRect(barX - 6, needleY - 3, barW + 12, 6);
      ctx.shadowBlur = 0;

      // Progress ring
      const cx = 250, cy = 175, r = 70;
      const pct = Math.min(1, heldMs / requiredMs);
      ctx.strokeStyle = 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 14;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.stroke();

      ctx.strokeStyle = '#30d158';
      ctx.shadowColor = '#30d158';
      ctx.shadowBlur = 10;
      ctx.lineWidth = 14;
      ctx.beginPath();
      ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * pct);
      ctx.stroke();
      ctx.shadowBlur = 0;

      ctx.fillStyle = '#fff';
      ctx.font = 'bold 20px monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(`${Math.floor(pct * 100)}%`, cx, cy);

      ctx.fillStyle = 'rgba(255,255,255,0.5)';
      ctx.font = '11px monospace';
      ctx.fillText('STABLE', cx, cy + 26);

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      canvasEl.removeEventListener('mousedown', onMouseDown);
      window.removeEventListener('mouseup', onMouseUp);
    };
  }

  // ─── 8. LOCKPICK (TUMBLER PICK) ───────────────────────────────────────────
  function runLockpick() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const N = Math.min(7, 4 + Math.floor(difficulty / 2));
    const pinW = Math.min(40, (W - 60) / N - 8);
    const totalW = N * pinW + (N - 1) * 8;
    const startX = (W - totalW) / 2;
    const barY = 90, barH = 160;

    const pins = [];
    for (let i = 0; i < N; i++) {
      const zoneSize = Math.max(0.14, 0.32 - difficulty * 0.03);
      pins.push({ zone: Math.random() * (1 - zoneSize), zoneSize, t: 0, dir: 1, set: false });
    }
    let current = 0;
    const speed = 0.016 + difficulty * 0.006;

    function attempt() {
      if (outcome) return;
      const p = pins[current];
      if (p.t >= p.zone && p.t <= p.zone + p.zoneSize) {
        p.set = true;
        sfxLatch();
        current++;
        if (current >= N) handleWin();
      } else {
        triggerShake();
        timeRemaining = Math.max(0, timeRemaining - 1.5);
      }
    }

    function onKey(e) {
      if (e.code === 'Space') { e.preventDefault(); attempt(); }
    }
    window.addEventListener('keydown', onKey);

    function loop() {
      if (!outcome && current < N) {
        const p = pins[current];
        p.t += speed * p.dir;
        if (p.t > 1) { p.t = 1; p.dir = -1; }
        if (p.t < 0) { p.t = 0; p.dir = 1; }
      }

      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`SPACE TO SET PIN ${Math.min(current + 1, N)}/${N} IN THE GREEN ZONE`, W / 2, 45);

      pins.forEach((p, i) => {
        const x = startX + i * (pinW + 8);
        ctx.fillStyle = 'rgba(255,255,255,0.06)';
        ctx.fillRect(x, barY, pinW, barH);

        const zy = barY + barH * (1 - p.zone - p.zoneSize);
        const zh = barH * p.zoneSize;
        ctx.fillStyle = p.set ? 'rgba(48, 209, 88, 0.35)' : 'rgba(48, 209, 88, 0.25)';
        ctx.fillRect(x, zy, pinW, zh);

        if (p.set) {
          ctx.fillStyle = '#30d158';
          ctx.fillRect(x, barY, pinW, barH);
        } else if (i === current) {
          const py = barY + barH * (1 - p.t);
          ctx.fillStyle = '#ff8c33';
          ctx.shadowColor = '#ff8c33';
          ctx.shadowBlur = 10;
          ctx.fillRect(x - 2, py - 3, pinW + 4, 6);
          ctx.shadowBlur = 0;
        }

        ctx.strokeStyle = 'rgba(255,255,255,0.2)';
        ctx.lineWidth = 2;
        ctx.strokeRect(x, barY, pinW, barH);
      });

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
    };
  }

  // ─── 9. MASH (BUTTON MASH) ────────────────────────────────────────────────
  function runMash() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    let fill = 0; // 0..100
    const perPress = Math.max(3.5, 6 - difficulty * 0.5);
    const decayPerFrame = 0.35 + difficulty * 0.12;
    let pulse = 0;

    function onKey(e) {
      if (outcome) return;
      if (e.code === 'Space') {
        e.preventDefault();
        fill = Math.min(100, fill + perPress);
        pulse = 1;
        sfxClick();
        if (fill >= 100) handleWin();
      }
    }
    function onClick() {
      if (outcome) return;
      fill = Math.min(100, fill + perPress);
      pulse = 1;
      sfxClick();
      if (fill >= 100) handleWin();
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', onClick);

    function loop() {
      if (!outcome) {
        fill = Math.max(0, fill - decayPerFrame);
        pulse = Math.max(0, pulse - 0.06);
      }

      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('MASH [SPACE] / CLICK — FILL THE METER', W / 2, 50);

      const barX = 45, barY = H / 2 - 20, barW = W - 90, barH = 40;
      ctx.fillStyle = 'rgba(255,255,255,0.07)';
      ctx.fillRect(barX, barY, barW, barH);

      const fillW = barW * (fill / 100);
      const grad = ctx.createLinearGradient(barX, 0, barX + barW, 0);
      grad.addColorStop(0, '#ff8c33');
      grad.addColorStop(1, '#30d158');
      ctx.fillStyle = grad;
      ctx.fillRect(barX, barY, fillW, barH);

      ctx.strokeStyle = 'rgba(255,255,255,0.25)';
      ctx.lineWidth = 2;
      ctx.strokeRect(barX, barY, barW, barH);

      ctx.fillStyle = '#fff';
      ctx.font = `bold ${28 + pulse * 6}px monospace`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(`${Math.floor(fill)}%`, W / 2, barY + barH / 2 - 45);

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', onClick);
    };
  }

  // ─── 10. TARGETS (TARGET PRACTICE) ────────────────────────────────────────
  function runTargets() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const required = 5 + Math.floor(difficulty / 2);
    const maxMisses = 3;
    let hits = 0, misses = 0;
    const lifeMs = Math.max(500, 1000 - difficulty * 90);
    const radius = Math.max(16, 26 - difficulty * 1.5);
    let target = null;

    function spawn() {
      target = {
        x: radius + 10 + Math.random() * (W - radius * 2 - 20),
        y: radius + 60 + Math.random() * (H - radius * 2 - 100),
        bornAt: performance.now(),
      };
    }
    spawn();

    function onClick(e) {
      if (outcome || !target) return;
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);
      const dist = Math.hypot(px - target.x, py - target.y);
      if (dist <= radius) {
        hits++;
        sfxLatch();
        target = null;
        if (hits >= required) { handleWin(); return; }
        spawn();
      } else {
        misses++;
        triggerShake();
        if (misses >= maxMisses) { handleFail(); return; }
      }
    }
    canvasEl.addEventListener('click', onClick);

    function loop() {
      if (!outcome && target) {
        const age = performance.now() - target.bornAt;
        if (age >= lifeMs) {
          misses++;
          target = null;
          if (misses >= maxMisses) {
            handleFail();
          } else {
            spawn();
          }
        }
      }

      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('CLICK THE TARGETS BEFORE THEY VANISH', W / 2, 40);

      ctx.fillStyle = '#ff8c33';
      ctx.font = 'bold 13px monospace';
      ctx.fillText(`HITS ${hits}/${required}   MISSES ${misses}/${maxMisses}`, W / 2, 62);

      if (target && !outcome) {
        const age = performance.now() - target.bornAt;
        const lifePct = Math.max(0, 1 - age / lifeMs);
        ctx.strokeStyle = 'rgba(255,255,255,0.15)';
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.arc(target.x, target.y, radius + 8, 0, Math.PI * 2);
        ctx.stroke();

        ctx.strokeStyle = lifePct < 0.3 ? '#ff453a' : '#ff8c33';
        ctx.shadowColor = ctx.strokeStyle;
        ctx.shadowBlur = 10;
        ctx.lineWidth = 4;
        ctx.beginPath();
        ctx.arc(target.x, target.y, radius + 8, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * lifePct);
        ctx.stroke();
        ctx.shadowBlur = 0;

        ctx.fillStyle = '#ffd60a';
        ctx.beginPath();
        ctx.arc(target.x, target.y, radius, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = '#0f172a';
        ctx.beginPath();
        ctx.arc(target.x, target.y, radius * 0.45, 0, Math.PI * 2);
        ctx.fill();
      }

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      canvasEl.removeEventListener('click', onClick);
    };
  }

  // ─── 11. LIGHTS OUT (CIRCUIT PUZZLE) ──────────────────────────────────────
  function runLightsOut() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const size = difficulty <= 2 ? 3 : 4;
    const cell = 60, gap = 6;
    const gridW = size * cell + (size - 1) * gap;
    const startX = (W - gridW) / 2, startY = 90;

    let grid = Array.from({ length: size }, () => Array(size).fill(false));
    function toggle(r, c) {
      [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]].forEach(([dr, dc]) => {
        const nr = r + dr, nc = c + dc;
        if (nr >= 0 && nr < size && nc >= 0 && nc < size) grid[nr][nc] = !grid[nr][nc];
      });
    }
    // Scramble from a solved (all-off) grid — any config reached this way is
    // always solvable, since toggling the same cells again undoes it exactly.
    const scrambleMoves = size * size + difficulty;
    for (let i = 0; i < scrambleMoves; i++) {
      toggle(Math.floor(Math.random() * size), Math.floor(Math.random() * size));
    }
    if (grid.every((row) => row.every((v) => !v))) toggle(0, 0); // guard against an all-off scramble

    function onClick(e) {
      if (outcome) return;
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);
      const c = Math.floor((px - startX) / (cell + gap));
      const r = Math.floor((py - startY) / (cell + gap));
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      if (px - (startX + c * (cell + gap)) > cell || py - (startY + r * (cell + gap)) > cell) return;
      sfxClick();
      toggle(r, c);
      if (grid.every((row) => row.every((v) => !v))) handleWin();
    }
    canvasEl.addEventListener('click', onClick);

    function loop() {
      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('CLICK TO TOGGLE — CLEAR ALL THE LIGHTS', W / 2, 50);

      for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
          const x = startX + c * (cell + gap), y = startY + r * (cell + gap);
          const on = grid[r][c];
          ctx.fillStyle = on ? 'rgba(255, 214, 10, 0.55)' : 'rgba(255,255,255,0.05)';
          ctx.strokeStyle = on ? '#ffd60a' : 'rgba(255,255,255,0.18)';
          ctx.shadowColor = on ? '#ffd60a' : 'transparent';
          ctx.shadowBlur = on ? 10 : 0;
          ctx.lineWidth = 2;
          ctx.fillRect(x, y, cell, cell);
          ctx.strokeRect(x, y, cell, cell);
          ctx.shadowBlur = 0;
        }
      }

      if (!outcome) {
        animFrame = requestAnimationFrame(loop);
      }
    }

    animFrame = requestAnimationFrame(loop);

    return () => {
      canvasEl.removeEventListener('click', onClick);
    };
  }

  // ─── 12. STACKER (CARGO TOWER) ────────────────────────────────────────────
  function runStacker() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const required = 5 + Math.floor(difficulty / 2);
    const baseW = 220, blockH = 22, floorY = H - 30;
    let stack = [{ x: (W - baseW) / 2, w: baseW }];
    let placed = 0;
    let curW = baseW, curX = 0, dir = 1;
    const speed = 1.6 + difficulty * 0.4;

    function attempt() {
      if (outcome) return;
      const below = stack[stack.length - 1];
      const left = Math.max(curX, below.x);
      const right = Math.min(curX + curW, below.x + below.w);
      const overlap = right - left;
      if (overlap <= 10) { handleFail(); return; }
      sfxLatch();
      stack.push({ x: left, w: overlap });
      curW = overlap;
      placed++;
      if (placed >= required) { handleWin(); return; }
      curX = 0;
      dir = 1;
    }

    function onKey(e) {
      if (e.code === 'Space') { e.preventDefault(); attempt(); }
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', attempt);

    function loop() {
      if (!outcome) {
        curX += speed * dir;
        if (curX + curW > W) { curX = W - curW; dir = -1; }
        if (curX < 0) { curX = 0; dir = 1; }
      }

      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`SPACE / CLICK TO DROP — CRATES STACKED ${placed}/${required}`, W / 2, 30);

      const visibleLevels = Math.min(stack.length, 8);
      for (let i = 0; i < visibleLevels; i++) {
        const level = stack[stack.length - visibleLevels + i];
        const y = floorY - (visibleLevels - i) * blockH;
        ctx.fillStyle = i === visibleLevels - 1 ? '#ff8c33' : 'rgba(255, 140, 51, 0.4)';
        ctx.fillRect(level.x, y, level.w, blockH - 4);
      }

      const moveY = floorY - (visibleLevels + 1) * blockH;
      ctx.fillStyle = '#ffd60a';
      ctx.shadowColor = '#ffd60a';
      ctx.shadowBlur = 8;
      ctx.fillRect(curX, moveY, curW, blockH - 4);
      ctx.shadowBlur = 0;

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', attempt);
    };
  }

  // ─── 13. SLIDE PUZZLE (CARGO MANIFEST) ────────────────────────────────────
  function runSlidePuzzle() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const size = difficulty <= 2 ? 3 : 4;
    const cell = 70, gap = 4;
    const gridW = size * cell + (size - 1) * gap;
    const startX = (W - gridW) / 2, startY = 60;

    let tiles = Array.from({ length: size * size }, (_, i) => (i + 1) % (size * size));
    let blank = tiles.indexOf(0);
    for (let i = 0; i < size * size * 20; i++) {
      const r = Math.floor(blank / size), c = blank % size;
      const neighbors = [];
      if (r > 0) neighbors.push(blank - size);
      if (r < size - 1) neighbors.push(blank + size);
      if (c > 0) neighbors.push(blank - 1);
      if (c < size - 1) neighbors.push(blank + 1);
      const swapWith = neighbors[Math.floor(Math.random() * neighbors.length)];
      [tiles[blank], tiles[swapWith]] = [tiles[swapWith], tiles[blank]];
      blank = swapWith;
    }

    function isSolved() {
      for (let i = 0; i < size * size - 1; i++) if (tiles[i] !== i + 1) return false;
      return true;
    }

    function onClick(e) {
      if (outcome) return;
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);
      const c = Math.floor((px - startX) / (cell + gap));
      const r = Math.floor((py - startY) / (cell + gap));
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      const idx = r * size + c;
      const br = Math.floor(blank / size), bc = blank % size;
      if ((Math.abs(br - r) === 1 && bc === c) || (Math.abs(bc - c) === 1 && br === r)) {
        sfxClick();
        [tiles[blank], tiles[idx]] = [tiles[idx], tiles[blank]];
        blank = idx;
        if (isSolved()) handleWin();
      }
    }
    canvasEl.addEventListener('click', onClick);

    function loop() {
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('REASSEMBLE THE CARGO MANIFEST', W / 2, 35);

      for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
          const idx = r * size + c;
          const v = tiles[idx];
          const x = startX + c * (cell + gap), y = startY + r * (cell + gap);
          if (v === 0) continue;
          ctx.fillStyle = 'rgba(255, 140, 51, 0.18)';
          ctx.strokeStyle = '#ff8c33';
          ctx.lineWidth = 2;
          ctx.fillRect(x, y, cell, cell);
          ctx.strokeRect(x, y, cell, cell);
          ctx.fillStyle = '#fff';
          ctx.font = 'bold 22px monospace';
          ctx.textAlign = 'center';
          ctx.textBaseline = 'middle';
          ctx.fillText(String(v), x + cell / 2, y + cell / 2);
        }
      }

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => canvasEl.removeEventListener('click', onClick);
  }

  // ─── 14. VAULT SPIN (SAFE DIAL) ───────────────────────────────────────────
  function runVaultSpin() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');
    const cx = W / 2, cy = H / 2 + 10, R = 110;

    const N = 3 + Math.floor(difficulty / 2);
    const zoneSize = Math.max(0.10, 0.22 - difficulty * 0.02);
    const targets = [];
    for (let i = 0; i < N; i++) targets.push({ ang: Math.random() * Math.PI * 2, hit: false });
    let needleAng = 0;
    const speed = 0.02 + difficulty * 0.006;
    let hits = 0, misses = 0;
    const maxMisses = 3;

    function angDist(a, b) {
      const d = Math.abs(a - b) % (Math.PI * 2);
      return Math.min(d, Math.PI * 2 - d);
    }

    function attempt() {
      if (outcome) return;
      const t = targets.find((tg) => !tg.hit && angDist(needleAng, tg.ang) <= zoneSize);
      if (t) {
        t.hit = true;
        hits++;
        sfxLatch();
        if (hits >= N) handleWin();
      } else {
        misses++;
        triggerShake();
        if (misses >= maxMisses) handleFail();
      }
    }
    function onKey(e) {
      if (e.code === 'Space') { e.preventDefault(); attempt(); }
    }
    window.addEventListener('keydown', onKey);

    function loop() {
      if (!outcome) needleAng = (needleAng + speed) % (Math.PI * 2);

      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`SPACE ON EACH MARK — ${hits}/${N} (MISSES ${misses}/${maxMisses})`, W / 2, 40);

      ctx.strokeStyle = 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 16;
      ctx.beginPath();
      ctx.arc(cx, cy, R, 0, Math.PI * 2);
      ctx.stroke();

      targets.forEach((t) => {
        ctx.strokeStyle = t.hit ? '#30d158' : '#ffd60a';
        ctx.shadowColor = ctx.strokeStyle;
        ctx.shadowBlur = 10;
        ctx.lineWidth = 14;
        ctx.beginPath();
        ctx.arc(cx, cy, R, t.ang - zoneSize, t.ang + zoneSize);
        ctx.stroke();
        ctx.shadowBlur = 0;
      });

      const nx = cx + Math.cos(needleAng) * R, ny = cy + Math.sin(needleAng) * R;
      ctx.fillStyle = '#fff';
      ctx.shadowColor = '#ff8c33';
      ctx.shadowBlur = 12;
      ctx.beginPath();
      ctx.arc(nx, ny, 9, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => window.removeEventListener('keydown', onKey);
  }

  // ─── 15. PULSE (RADIO BEACON) ─────────────────────────────────────────────
  function runPulse() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');
    const cx = W / 2, cy = H / 2;

    const required = 5 + Math.floor(difficulty / 2);
    const beatMs = Math.max(650, 1100 - difficulty * 90);
    const tolerance = 0.22;
    let hits = 0, misses = 0;
    const maxMisses = 3;
    const startedAt = performance.now();

    function beatPhase() {
      const elapsed = (performance.now() - startedAt) % beatMs;
      return elapsed / beatMs;
    }

    function attempt() {
      if (outcome) return;
      const phase = beatPhase();
      const dist = Math.min(phase, 1 - phase);
      if (dist <= tolerance) {
        hits++;
        sfxLatch();
        if (hits >= required) handleWin();
      } else {
        misses++;
        triggerShake();
        if (misses >= maxMisses) handleFail();
      }
    }
    function onKey(e) {
      if (e.code === 'Space') { e.preventDefault(); attempt(); }
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', attempt);

    function loop() {
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`HIT [SPACE] ON THE BEACON PULSE — ${hits}/${required} (MISSES ${misses}/${maxMisses})`, W / 2, 40);

      const phase = beatPhase();
      const pulseR = 30 + phase * 70;
      const onBeat = Math.min(phase, 1 - phase) <= tolerance;

      ctx.strokeStyle = onBeat ? '#30d158' : 'rgba(255, 140, 51, 0.5)';
      ctx.lineWidth = 4;
      ctx.globalAlpha = 1 - phase * 0.7;
      ctx.beginPath();
      ctx.arc(cx, cy, pulseR, 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = 1;

      ctx.fillStyle = onBeat ? '#30d158' : '#ff8c33';
      ctx.shadowColor = ctx.fillStyle;
      ctx.shadowBlur = onBeat ? 20 : 8;
      ctx.beginPath();
      ctx.arc(cx, cy, 24, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', attempt);
    };
  }

  // ─── 16. BREACH MATRIX (SUM THE ACCESS CODE) ──────────────────────────────
  function runBreachMatrix() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const cols = 4, rows = 3, cell = 78, gap = 8;
    const gridW = cols * cell + (cols - 1) * gap, gridH = rows * cell + (rows - 1) * gap;
    const startX = (W - gridW) / 2, startY = 90;

    const cells = [];
    for (let i = 0; i < cols * rows; i++) cells.push({ v: 1 + Math.floor(Math.random() * 9), picked: false });
    const solutionSize = 2 + (difficulty >= 3 ? 1 : 0);
    const indices = [...Array(cells.length).keys()].sort(() => Math.random() - 0.5).slice(0, solutionSize);
    const target = indices.reduce((s, i) => s + cells[i].v, 0);

    let sum = 0;
    const maxWrong = 3;
    let wrong = 0;

    function onClick(e) {
      if (outcome) return;
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);
      const c = Math.floor((px - startX) / (cell + gap));
      const r = Math.floor((py - startY) / (cell + gap));
      if (r < 0 || r >= rows || c < 0 || c >= cols) return;
      const idx = r * cols + c;
      const cellObj = cells[idx];
      if (!cellObj || cellObj.picked) return;

      cellObj.picked = true;
      sum += cellObj.v;
      if (sum === target) { sfxSuccess(); handleWin(); return; }
      if (sum > target) {
        wrong++;
        triggerShake();
        cells.forEach((cc) => { cc.picked = false; });
        sum = 0;
        if (wrong >= maxWrong) { handleFail(); return; }
      } else {
        sfxClick();
      }
    }
    canvasEl.addEventListener('click', onClick);

    function loop() {
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`SELECT CELLS THAT SUM TO ${target}`, W / 2, 40);
      ctx.fillStyle = '#ff8c33';
      ctx.font = 'bold 13px monospace';
      ctx.fillText(`CURRENT: ${sum}   WRONG: ${wrong}/${maxWrong}`, W / 2, 62);

      cells.forEach((c, i) => {
        const r = Math.floor(i / cols), col = i % cols;
        const x = startX + col * (cell + gap), y = startY + r * (cell + gap);
        ctx.fillStyle = c.picked ? 'rgba(48, 209, 88, 0.35)' : 'rgba(255,255,255,0.06)';
        ctx.strokeStyle = c.picked ? '#30d158' : 'rgba(255,255,255,0.2)';
        ctx.lineWidth = 2;
        ctx.fillRect(x, y, cell, cell);
        ctx.strokeRect(x, y, cell, cell);
        ctx.fillStyle = '#fff';
        ctx.font = 'bold 22px monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(String(c.v), x + cell / 2, y + cell / 2);
      });

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => canvasEl.removeEventListener('click', onClick);
  }

  // ─── 17. CASCADE (SORT THE CONTRABAND) ────────────────────────────────────
  function runCascade() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const required = 5 + Math.floor(difficulty / 2);
    const maxMisses = 3;
    let hits = 0, misses = 0;
    const targetLineY = H - 60;
    const fallSpeed = 1.6 + difficulty * 0.5;
    const spawnEveryMs = Math.max(450, 900 - difficulty * 80);
    const shapes = ['circle', 'square', 'triangle'];
    const targetShape = shapes[Math.floor(Math.random() * shapes.length)];
    let items = [];
    let lastSpawn = 0;

    function spawn(now) {
      const isTarget = Math.random() < 0.45;
      items.push({
        x: 40 + Math.random() * (W - 80),
        y: -20,
        shape: isTarget ? targetShape : shapes[Math.floor(Math.random() * shapes.length)],
        resolved: false,
      });
      lastSpawn = now;
    }

    function tryHit() {
      if (outcome) return;
      let best = null, bestDist = Infinity;
      items.forEach((it) => {
        if (it.resolved) return;
        const d = Math.abs(it.y - targetLineY);
        if (d < bestDist) { bestDist = d; best = it; }
      });
      if (!best || bestDist > 26) return;
      best.resolved = true;
      if (best.shape === targetShape) {
        hits++;
        sfxLatch();
        if (hits >= required) handleWin();
      } else {
        misses++;
        triggerShake();
        if (misses >= maxMisses) handleFail();
      }
    }
    function onKey(e) {
      if (e.code === 'Space') { e.preventDefault(); tryHit(); }
    }
    window.addEventListener('keydown', onKey);
    canvasEl.addEventListener('click', tryHit);

    function drawShape(it) {
      ctx.fillStyle = it.shape === targetShape ? '#ff8c33' : 'rgba(255,255,255,0.35)';
      ctx.beginPath();
      if (it.shape === 'circle') {
        ctx.arc(it.x, it.y, 14, 0, Math.PI * 2);
      } else if (it.shape === 'square') {
        ctx.rect(it.x - 13, it.y - 13, 26, 26);
      } else {
        ctx.moveTo(it.x, it.y - 15);
        ctx.lineTo(it.x + 14, it.y + 12);
        ctx.lineTo(it.x - 14, it.y + 12);
        ctx.closePath();
      }
      ctx.fill();
    }

    function loop(now) {
      if (!outcome) {
        if (now - lastSpawn > spawnEveryMs) spawn(now);
        items.forEach((it) => { if (!it.resolved) it.y += fallSpeed; });
        items.forEach((it) => {
          if (!it.resolved && it.y > H + 20) {
            it.resolved = true;
            if (it.shape === targetShape) {
              misses++;
              if (misses >= maxMisses) handleFail();
            }
          }
        });
        items = items.filter((it) => it.y < H + 40);
      }

      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`HIT [SPACE] ONLY ON THE ${targetShape.toUpperCase()} — ${hits}/${required} (MISS ${misses}/${maxMisses})`, W / 2, 30);

      ctx.strokeStyle = '#ffd60a';
      ctx.setLineDash([6, 6]);
      ctx.beginPath();
      ctx.moveTo(20, targetLineY);
      ctx.lineTo(W - 20, targetLineY);
      ctx.stroke();
      ctx.setLineDash([]);

      items.forEach(drawShape);

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => {
      window.removeEventListener('keydown', onKey);
      canvasEl.removeEventListener('click', tryHit);
    };
  }

  // ─── 18. TRIPWIRE (STEADY HAND CORRIDOR) ──────────────────────────────────
  function runTripwire() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const pathWidth = Math.max(26, 46 - difficulty * 4);
    const margin = 30;
    const waypoints = [];
    const segments = 5;
    for (let i = 0; i <= segments; i++) {
      const x = margin + (i / segments) * (W - margin * 2);
      const y = H / 2 + Math.sin(i * 1.7 + difficulty) * 90 * (i > 0 && i < segments ? 1 : 0.3);
      waypoints.push({ x, y });
    }

    let progress = 0;
    let started = false;
    let failed = false;

    function pathPoint(t) {
      const segCount = waypoints.length - 1;
      const segT = t * segCount;
      const i = Math.min(segCount - 1, Math.floor(segT));
      const localT = segT - i;
      const a = waypoints[i], b = waypoints[i + 1];
      return { x: a.x + (b.x - a.x) * localT, y: a.y + (b.y - a.y) * localT };
    }

    function onMouseMove(e) {
      if (outcome || failed) return;
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);

      if (!started) {
        const start = waypoints[0];
        if (Math.hypot(start.x - px, start.y - py) <= pathWidth / 2) {
          started = true;
        } else {
          return;
        }
      }

      // Check if player reached the exit goal (yellow dot at the end)
      const endPt = waypoints[waypoints.length - 1];
      const distToEnd = Math.hypot(endPt.x - px, endPt.y - py);
      if (distToEnd <= Math.max(26, pathWidth * 0.75) || progress >= 0.94) {
        handleWin();
        return;
      }

      let bestT = progress, bestDist = Infinity;
      for (let t = Math.max(0, progress - 0.08); t <= Math.min(1.0, progress + 0.20); t += 0.01) {
        const p = pathPoint(t);
        const d = Math.hypot(p.x - px, p.y - py);
        if (d < bestDist) { bestDist = d; bestT = t; }
      }
      const endSample = pathPoint(1.0);
      const endD = Math.hypot(endSample.x - px, endSample.y - py);
      if (endD < bestDist) { bestDist = endD; bestT = 1.0; }

      if (bestDist > pathWidth / 2) {
        // If within exit vicinity or high progress, forgive wall check and award win
        if (distToEnd <= pathWidth || progress >= 0.90) {
          handleWin();
          return;
        }
        failed = true;
        triggerShake();
        handleFail();
        return;
      }

      progress = Math.max(progress, bestT);
      if (progress >= 0.94 || distToEnd <= Math.max(26, pathWidth * 0.75)) handleWin();
    }
    canvasEl.addEventListener('mousemove', onMouseMove);

    function loop() {
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(started ? "GUIDE THE CURSOR — DON'T TOUCH THE WALLS" : 'MOVE TO THE GREEN DOT TO BEGIN', W / 2, 22);

      ctx.strokeStyle = 'rgba(255,255,255,0.1)';
      ctx.lineWidth = pathWidth;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      waypoints.forEach((p, i) => (i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y)));
      ctx.stroke();

      ctx.strokeStyle = '#ff8c33';
      ctx.lineWidth = 2;
      ctx.stroke();

      ctx.fillStyle = '#30d158';
      ctx.beginPath();
      ctx.arc(waypoints[0].x, waypoints[0].y, 10, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = '#ffd60a';
      ctx.beginPath();
      ctx.arc(waypoints[waypoints.length - 1].x, waypoints[waypoints.length - 1].y, 10, 0, Math.PI * 2);
      ctx.fill();

      const cur = pathPoint(progress);
      ctx.fillStyle = '#fff';
      ctx.shadowColor = '#ff8c33';
      ctx.shadowBlur = 10;
      ctx.beginPath();
      ctx.arc(cur.x, cur.y, 7, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => canvasEl.removeEventListener('mousemove', onMouseMove);
  }

  // ─── 19. CONSTELLATION (GPS WAYPOINT TRACE) ───────────────────────────────
  function runConstellation() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');

    const N = Math.min(9, 4 + difficulty);
    const stars = [];
    const minDist = 46;
    for (let i = 0; i < N; i++) {
      let pos, tries = 0;
      do {
        pos = { x: 30 + Math.random() * (W - 60), y: 70 + Math.random() * (H - 110) };
        tries++;
      } while (tries < 30 && stars.some((s) => Math.hypot(s.x - pos.x, s.y - pos.y) < minDist));
      stars.push({ x: pos.x, y: pos.y, n: i + 1 });
    }

    let next = 1;
    let misses = 0;
    const maxMisses = 3;
    const path = [];

    function onClick(e) {
      if (outcome) return;
      const rect = canvasEl.getBoundingClientRect();
      const px = (e.clientX - rect.left) * (W / rect.width);
      const py = (e.clientY - rect.top) * (H / rect.height);
      const star = stars.find((s) => Math.hypot(s.x - px, s.y - py) <= 16);
      if (!star) return;
      if (star.n === next) {
        sfxLatch();
        path.push(star);
        next++;
        if (next > N) handleWin();
      } else {
        // A single mis-click used to fail the whole attempt instantly —
        // every other click-based game here (e.g. cascade) allows a few
        // misses before actually failing; this one didn't, which read as
        // "broken/too harsh" rather than a real skill check, especially
        // since a slightly-off click on a small 16px star hit zone is easy
        // to do by accident.
        misses++;
        triggerShake();
        if (misses >= maxMisses) handleFail();
      }
    }
    canvasEl.addEventListener('click', onClick);

    function loop() {
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`TRACE THE ROUTE WAYPOINTS IN ORDER — ${next - 1}/${N} (MISS ${misses}/${maxMisses})`, W / 2, 30);

      if (path.length > 1) {
        ctx.strokeStyle = '#ff8c33';
        ctx.lineWidth = 2;
        ctx.beginPath();
        path.forEach((s, i) => (i === 0 ? ctx.moveTo(s.x, s.y) : ctx.lineTo(s.x, s.y)));
        ctx.stroke();
      }

      stars.forEach((s) => {
        const done = s.n < next;
        ctx.fillStyle = done ? '#30d158' : '#ffd60a';
        ctx.shadowColor = ctx.fillStyle;
        ctx.shadowBlur = s.n === next ? 14 : 6;
        ctx.beginPath();
        ctx.arc(s.x, s.y, 13, 0, Math.PI * 2);
        ctx.fill();
        ctx.shadowBlur = 0;

        ctx.fillStyle = '#0f172a';
        ctx.font = 'bold 12px monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(String(s.n), s.x, s.y);
      });

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => canvasEl.removeEventListener('click', onClick);
  }

  // ─── 20. FINGERPRINT (SECURITY SCANNER) ───────────────────────────────────
  function runFingerprint() {
    const W = 380, H = 340;
    canvasEl.width = W; canvasEl.height = H;
    const ctx = canvasEl.getContext('2d');
    const cx = W / 2, cy = H / 2 + 10, R = 100;

    const N = 4 + Math.floor(difficulty / 2);
    const zoneSize = Math.max(0.10, 0.2 - difficulty * 0.018);
    const marks = [];
    for (let i = 0; i < N; i++) marks.push({ ang: (i / N) * Math.PI * 2 + Math.random() * 0.3, set: false });
    marks.sort((a, b) => a.ang - b.ang);

    let scanAng = 0;
    const speed = 0.018 + difficulty * 0.005;
    let current = 0;

    function attempt() {
      if (outcome) return;
      const m = marks[current];
      const d = Math.abs(scanAng - m.ang);
      if (Math.min(d, Math.PI * 2 - d) <= zoneSize) {
        m.set = true;
        sfxLatch();
        current++;
        if (current >= N) handleWin();
      } else {
        triggerShake();
        timeRemaining = Math.max(0, timeRemaining - 1.5);
      }
    }
    function onKey(e) {
      if (e.code === 'Space') { e.preventDefault(); attempt(); }
    }
    window.addEventListener('keydown', onKey);

    function loop() {
      if (!outcome) scanAng = (scanAng + speed) % (Math.PI * 2);

      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      ctx.font = '12px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(`SPACE ON EACH SCAN MARK — ${current}/${N}`, W / 2, 35);

      for (let ring = 0; ring < 3; ring++) {
        ctx.strokeStyle = 'rgba(255,255,255,0.06)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(cx, cy, R - ring * 18, 0, Math.PI * 2);
        ctx.stroke();
      }

      marks.forEach((m, i) => {
        const isCurrent = i === current;
        ctx.strokeStyle = m.set ? '#30d158' : (isCurrent ? '#ffd60a' : 'rgba(255,255,255,0.25)');
        ctx.shadowColor = ctx.strokeStyle;
        ctx.shadowBlur = isCurrent || m.set ? 10 : 0;
        ctx.lineWidth = 10;
        ctx.beginPath();
        ctx.arc(cx, cy, R, m.ang - zoneSize, m.ang + zoneSize);
        ctx.stroke();
        ctx.shadowBlur = 0;
      });

      const sx = cx + Math.cos(scanAng) * R, sy = cy + Math.sin(scanAng) * R;
      ctx.fillStyle = '#ff8c33';
      ctx.shadowColor = '#ff8c33';
      ctx.shadowBlur = 12;
      ctx.beginPath();
      ctx.arc(sx, sy, 8, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;

      if (!outcome) animFrame = requestAnimationFrame(loop);
    }
    animFrame = requestAnimationFrame(loop);

    return () => window.removeEventListener('keydown', onKey);
  }

  // ─── EXTENDED PACK — ported from the standalone vanilla-JS engine, kept
  // close to their original code (they already only touch api.board/DOM/
  // Canvas2D, nothing framework-specific) so future additions from the same
  // pack stay a near copy-paste. Colors come from --accent/--success/
  // --danger (see :global(:root) in <style>), not hardcoded, so they match
  // this app's palette instead of the source pack's teal one. ────────────

  // ─── 21. THERMITE (MEMORY GRID) ─────────────────────────────────────────
  function extThermite(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const N = 4 + Math.floor(diff / 2);
    const litCount = 3 + diff;
    const cell = Math.min(64, Math.floor(300 / N));
    const W = cell * N, H = cell * N;

    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    cvs.style.cursor = 'pointer';
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    const target = new Set();
    while (target.size < Math.min(litCount, N * N)) target.add(api.randInt(0, N * N - 1));
    const picked = new Set();
    let phase = 'show', ended = false, wrong = 0;
    const maxWrong = Math.max(1, 4 - diff);
    api.setDots(target.size);

    const showMs = Math.max(1200, 2600 - diff * 250);
    api.setTag('MEMORIZE');
    const showTimeout = setTimeout(() => { if (!ended) { phase = 'input'; api.setTag('REPRODUCE'); api.startTimer(Math.max(8, 16 - diff), () => finish(false)); } }, showMs);

    function rel(e) {
      const b = cvs.getBoundingClientRect();
      const x = (e.clientX - b.left) * (cvs.width / b.width);
      const y = (e.clientY - b.top) * (cvs.height / b.height);
      return Math.floor(y / cell) * N + Math.floor(x / cell);
    }
    function onClick(e) {
      if (phase !== 'input' || ended) return;
      const idx = rel(e);
      if (idx < 0 || idx >= N * N || picked.has(idx)) return;
      if (target.has(idx)) {
        picked.add(idx); api.sfx('zap');
        api.setDots(target.size, Array.from({ length: target.size }, (_, i) => i < picked.size ? 'done' : ''));
        if (picked.size >= target.size) finish(true);
      } else {
        wrong++; api.shake();
        if (wrong >= maxWrong) finish(false);
      }
    }
    cvs.addEventListener('click', onClick);
    function finish(ok) { if (ended) return; ended = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 300); }

    function draw() {
      ctx.clearRect(0, 0, W, H);
      for (let i = 0; i < N * N; i++) {
        const r = Math.floor(i / N), c = i % N;
        const x = c * cell, y = r * cell;
        let fill = 'rgba(255,255,255,0.05)';
        if (phase === 'show' && target.has(i)) fill = 'rgba(255,138,0,0.7)';
        if (picked.has(i)) fill = 'var(--success)';
        ctx.fillStyle = fill === 'var(--success)' ? (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim() : fill;
        if ((phase === 'show' && target.has(i)) || picked.has(i)) { ctx.shadowColor = picked.has(i) ? ctx.fillStyle : '#ff8a00'; ctx.shadowBlur = 16; }
        ctx.fillRect(x + 3, y + 3, cell - 6, cell - 6);
        ctx.shadowBlur = 0;
        ctx.strokeStyle = 'rgba(255,255,255,0.08)';
        ctx.strokeRect(x + 3, y + 3, cell - 6, cell - 6);
      }
      const dngC = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff453a').trim();
      for (let i = 0; i < maxWrong; i++) {
        ctx.fillStyle = i < wrong ? dngC : 'rgba(255,255,255,0.15)';
        ctx.beginPath(); ctx.arc(10 + i * 14, H - 8, 4, 0, Math.PI * 2); ctx.fill();
      }
      loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => { clearTimeout(showTimeout); cvs.removeEventListener('click', onClick); cancelAnimationFrame(loop); };
  }

  // ─── 22. LASER GRID (INFILTRATION) ──────────────────────────────────────
  function extLasergrid(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const W = 460, H = 280;
    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    cvs.style.cursor = 'none';
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    const laserCount = 3 + diff;
    const lasers = [];
    for (let i = 0; i < laserCount; i++) {
      const horizontal = Math.random() < 0.5;
      lasers.push({
        horizontal,
        pos: api.rand(60, (horizontal ? H : W) - 60),
        dir: Math.random() < 0.5 ? 1 : -1,
        speed: 0.6 + diff * 0.35 + Math.random() * 0.6
      });
    }
    let player = { x: 24, y: H / 2 }, ended = false, hasMouse = false;
    const exit = { x: W - 30, y: H / 2, r: 22 };

    function rel(e) {
      const b = cvs.getBoundingClientRect();
      return { x: (e.clientX - b.left) * (cvs.width / b.width), y: (e.clientY - b.top) * (cvs.height / b.height) };
    }
    function onMove(e) { const p = rel(e); player = p; hasMouse = true; }
    cvs.addEventListener('mousemove', onMove);

    api.setTag('INFILTRATE');
    api.startTimer(Math.max(12, 22 - diff * 1.6), () => finish(false));
    function finish(ok) { if (ended) return; ended = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

    function draw() {
      const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#ffd60a').trim();
      const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff453a').trim();
      const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim();
      ctx.clearRect(0, 0, W, H);
      ctx.strokeStyle = 'rgba(255,255,255,0.1)'; ctx.lineWidth = 2; ctx.strokeRect(8, 8, W - 16, H - 16);

      ctx.fillStyle = suc; ctx.shadowColor = suc; ctx.shadowBlur = 16;
      ctx.beginPath(); ctx.arc(exit.x, exit.y, exit.r, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;
      ctx.fillStyle = '#0a0e14'; ctx.font = '9px monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText('EXIT', exit.x, exit.y);

      let hit = false;
      lasers.forEach((l) => {
        if (!ended) {
          l.pos += l.dir * l.speed;
          const max = l.horizontal ? H - 16 : W - 16;
          if (l.pos > max) { l.pos = max; l.dir = -1; }
          if (l.pos < 16) { l.pos = 16; l.dir = 1; }
        }
        ctx.strokeStyle = dng; ctx.lineWidth = 2; ctx.shadowColor = dng; ctx.shadowBlur = 8;
        ctx.beginPath();
        if (l.horizontal) { ctx.moveTo(10, l.pos); ctx.lineTo(W - 10, l.pos); if (Math.abs(player.y - l.pos) < 8) hit = true; }
        else { ctx.moveTo(l.pos, 10); ctx.lineTo(l.pos, H - 10); if (Math.abs(player.x - l.pos) < 8) hit = true; }
        ctx.stroke(); ctx.shadowBlur = 0;
      });

      if (hasMouse) {
        ctx.fillStyle = hit ? dng : acc; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = 12;
        ctx.beginPath(); ctx.arc(player.x, player.y, 8, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;
      } else {
        ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '12px monospace'; ctx.textAlign = 'left';
        ctx.fillText('move your mouse from the left edge', 20, H / 2);
      }

      if (!ended && hasMouse) {
        if (hit) { api.shake(); finish(false); return; }
        if (Math.hypot(player.x - exit.x, player.y - exit.y) < exit.r) { finish(true); return; }
      }
      loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => { cvs.removeEventListener('mousemove', onMove); cancelAnimationFrame(loop); };
  }

  // ─── 23. FORGE (BLACKSMITH STRIKE TIMING) ───────────────────────────────
  function extForge(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const W = 400, H = 280;

    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    cvs.style.cursor = 'pointer';
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    const need = 4 + diff;
    const maxClang = Math.max(2, 5 - diff);
    const lo = 0.55, hi = lo + Math.max(0.14, 0.3 - diff * 0.03);
    const rise = 0.3 + diff * 0.06, drop = (hi - lo) + 0.18;
    let heat = 0.15, made = 0, clang = 0, done = false, flash = 0, last = performance.now();

    api.setDots(need);
    function strike() {
      if (done) return;
      if (heat >= lo && heat <= hi) {
        made++; flash = 6; api.sfx('latch'); heat = Math.max(0.05, heat - drop);
        api.setDots(need, Array.from({ length: need }, (_, i) => i < made ? 'done' : ''));
        if (made >= need) { done = true; api.stopTimer(); api.setTag('FORGED'); document.removeEventListener('keydown', key); setTimeout(() => api.succeed(), 300); }
      } else {
        clang++; api.shake(); api.sfx('error'); heat = Math.max(0.05, heat - 0.1);
        if (clang >= maxClang) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 300); }
      }
    }
    function key(e) { if (e.code === 'Space') { e.preventDefault(); strike(); } }
    document.addEventListener('keydown', key);
    cvs.addEventListener('click', strike);

    api.setTag('HEATING');
    api.startTimer(Math.max(18, 30 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 200); } });

    function heatColor(h) {
      if (h < 0.35) return 'rgb(90,30,20)';
      if (h < lo) return 'rgb(' + Math.round(150 + h * 120) + ',60,30)';
      if (h <= hi) return 'rgb(255,' + Math.round(120 + (h - lo) * 200) + ',40)';
      return 'rgb(255,' + Math.round(220 + h * 35) + ',' + Math.round(150 + h * 100) + ')';
    }

    function draw() {
      const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim();
      const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#ffd60a').trim();
      const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff453a').trim();
      const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
      if (!done) { heat = Math.min(1, heat + rise * dt); if (heat >= 1) { done = true; api.stopTimer(); api.setTag('BURNT'); api.shake(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 300); } }
      if (flash > 0) flash--;
      ctx.clearRect(0, 0, W, H);

      ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(W / 2 - 90, H - 70, 180, 26); ctx.fillRect(W / 2 - 30, H - 44, 60, 30);
      const inB = heat >= lo && heat <= hi;
      ctx.fillStyle = heatColor(heat); ctx.shadowColor = heatColor(heat); ctx.shadowBlur = 10 + heat * 26 + flash * 4;
      ctx.fillRect(W / 2 - 70, H - 92 - (flash ? 4 : 0), 140, 18); ctx.shadowBlur = 0;
      ctx.strokeStyle = inB ? suc : 'rgba(255,255,255,0.15)'; ctx.lineWidth = 2; ctx.strokeRect(W / 2 - 70, H - 92 - (flash ? 4 : 0), 140, 18);

      const gx = W - 60, gy = 30, gw = 26, gh = H - 120;
      ctx.fillStyle = 'rgba(255,255,255,0.07)'; ctx.fillRect(gx, gy, gw, gh);
      ctx.fillStyle = 'rgba(48,209,88,0.18)'; ctx.fillRect(gx, gy + gh * (1 - hi), gw, gh * (hi - lo));
      ctx.fillStyle = 'rgba(255,69,58,0.18)'; ctx.fillRect(gx, gy, gw, gh * 0.06);
      const hy = gy + gh * (1 - heat);
      ctx.fillStyle = inB ? suc : (heat > hi ? dng : acc); ctx.fillRect(gx - 4, hy - 2, gw + 8, 4);
      ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '9px monospace'; ctx.textAlign = 'center'; ctx.fillText('HEAT', gx + gw / 2, H - 78);

      ctx.fillStyle = 'rgba(255,255,255,0.45)'; ctx.font = '11px monospace'; ctx.textAlign = 'center';
      ctx.fillText('SHAPED ' + made + ' / ' + need, W / 2 - 20, 28);
      for (let i = 0; i < maxClang; i++) { ctx.fillStyle = i < clang ? dng : 'rgba(255,255,255,0.15)'; ctx.beginPath(); ctx.arc(20 + i * 14, 22, 4, 0, Math.PI * 2); ctx.fill(); }

      if (!done) loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); };
  }

  // ─── 24. ARCHERY (LONGSHOT) ──────────────────────────────────────────────
  function extArchery(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const W = 460, H = 300;

    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    cvs.style.cursor = 'crosshair';
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    const bow = { x: 56, y: H - 60 };
    const g = 0.4, k = 0.17, maxPull = 150;
    const rounds = 2 + Math.floor(diff / 2);
    const tgR = Math.max(17, 32 - diff * 3);
    const aidLen = diff <= 2 ? 90 : diff <= 4 ? 46 : 24;
    const wind = diff >= 4 ? (Math.random() < 0.5 ? -1 : 1) * (0.015 + diff * 0.006) : 0;
    let round = 0, aiming = false, aim = { x: 0, y: 0 }, arrow = null, done = false;

    api.setDots(rounds);
    function newTarget() { return { x: 280 + Math.random() * (W - 320), y: 55 + Math.random() * (H - 150) }; }
    let target = newTarget();

    function rel(e) { const b = cvs.getBoundingClientRect(); return { x: (e.clientX - b.left) * (W / b.width), y: (e.clientY - b.top) * (H / b.height) }; }
    function setAim(r) { aim = { x: r.x - bow.x, y: r.y - bow.y }; const m = Math.hypot(aim.x, aim.y); if (m > maxPull) { aim.x *= maxPull / m; aim.y *= maxPull / m; } }
    function onDown(e) { if (done || arrow) return; aiming = true; setAim(rel(e)); }
    function onMove(e) { if (aiming) setAim(rel(e)); }
    function loose() { if (!aiming) return; aiming = false; if (Math.hypot(aim.x, aim.y) < 14) return; arrow = { x: bow.x, y: bow.y, vx: aim.x * k, vy: aim.y * k }; api.sfx('whoosh'); }
    function onLeave() { aiming = false; }
    cvs.addEventListener('mousedown', onDown);
    cvs.addEventListener('mousemove', onMove);
    cvs.addEventListener('mouseup', loose);
    cvs.addEventListener('mouseleave', onLeave);

    api.setTag('AIM');
    api.startTimer(Math.max(22, 38 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

    function draw() {
      const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#ffd60a').trim();
      const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim();
      if (arrow && !done) {
        arrow.vy += g; arrow.vx += wind; arrow.x += arrow.vx; arrow.y += arrow.vy;
        if (Math.hypot(arrow.x - target.x, arrow.y - target.y) < tgR) {
          round++; api.sfx('good'); api.setDots(rounds, Array.from({ length: rounds }, (_, i) => i < round ? 'done' : ''));
          if (round >= rounds) { done = true; api.stopTimer(); api.setTag('BULLSEYE'); setTimeout(() => api.succeed(), 300); return; }
          target = newTarget(); arrow = null;
        } else if (arrow.y > H - 14 || arrow.x > W + 20 || arrow.x < -20 || arrow.y < -60) { arrow = null; api.sfx('bad'); }
      }
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = 'rgba(255,255,255,0.05)'; ctx.fillRect(0, H - 12, W, 12);

      ctx.strokeStyle = suc; ctx.lineWidth = 2; ctx.shadowColor = suc; ctx.shadowBlur = 10;
      ctx.beginPath(); ctx.arc(target.x, target.y, tgR, 0, Math.PI * 2); ctx.stroke();
      ctx.beginPath(); ctx.arc(target.x, target.y, tgR * 0.55, 0, Math.PI * 2); ctx.stroke(); ctx.shadowBlur = 0;
      ctx.fillStyle = suc; ctx.beginPath(); ctx.arc(target.x, target.y, 3, 0, Math.PI * 2); ctx.fill();

      if (aiming && Math.hypot(aim.x, aim.y) >= 14) {
        let sx = bow.x, sy = bow.y, vx = aim.x * k, vy = aim.y * k;
        ctx.fillStyle = 'rgba(255,255,255,0.4)';
        for (let i = 0; i < aidLen; i++) {
          vy += g; vx += wind; sx += vx; sy += vy;
          if (sy > H - 12 || sx > W + 10 || sx < -10) break;
          if (i % 3 === 0) { ctx.beginPath(); ctx.arc(sx, sy, 2, 0, Math.PI * 2); ctx.fill(); }
        }
      }

      ctx.strokeStyle = acc; ctx.lineWidth = 3;
      ctx.beginPath(); ctx.arc(bow.x, bow.y, 14, -Math.PI / 2.1, Math.PI / 2.1); ctx.stroke();
      if (aiming) {
        const ex = bow.x + aim.x, ey = bow.y + aim.y, ang = Math.atan2(aim.y, aim.x);
        ctx.strokeStyle = acc; ctx.lineWidth = 2;
        ctx.beginPath(); ctx.moveTo(bow.x, bow.y); ctx.lineTo(ex, ey); ctx.stroke();
        ctx.save(); ctx.translate(ex, ey); ctx.rotate(ang);
        ctx.fillStyle = acc; ctx.beginPath(); ctx.moveTo(9, 0); ctx.lineTo(-2, -5); ctx.lineTo(-2, 5); ctx.closePath(); ctx.fill();
        ctx.restore();
      }

      if (arrow) {
        const a = Math.atan2(arrow.vy, arrow.vx);
        ctx.save(); ctx.translate(arrow.x, arrow.y); ctx.rotate(a);
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(-12, 0); ctx.lineTo(8, 0); ctx.stroke();
        ctx.fillStyle = acc; ctx.beginPath(); ctx.moveTo(8, 0); ctx.lineTo(2, -3); ctx.lineTo(2, 3); ctx.closePath(); ctx.fill();
        ctx.restore();
      }
      if (!done) loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => {
      cancelAnimationFrame(loop);
      cvs.removeEventListener('mousedown', onDown);
      cvs.removeEventListener('mousemove', onMove);
      cvs.removeEventListener('mouseup', loose);
      cvs.removeEventListener('mouseleave', onLeave);
    };
  }

  // ─── 25. PARRY (DEFLECT) ─────────────────────────────────────────────────
  function extParry(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const W = 320, H = 300, cx = W / 2, cy = H / 2;

    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    const need = 4 + diff;
    const maxMiss = Math.max(2, 5 - diff);
    const speed = 0.012 + diff * 0.004;
    const winLo = 0.72;
    const guardR = 30, maxR = 150;
    const DIRS = { L: [-1, 0], U: [0, -1], R: [1, 0] };
    let strike = null, gap = 16, made = 0, miss = 0, done = false, flash = 0, flashCol = '';

    api.setDots(need);
    function spawn() { const d = ['L', 'U', 'R'][api.randInt(0, 2)]; strike = { dir: d, t: 0 }; }
    function resolve(ok) {
      const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim();
      const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff453a').trim();
      strike = null; gap = 14; flash = 7; flashCol = ok ? suc : dng;
      if (ok) { made++; api.sfx('latch'); api.setDots(need, Array.from({ length: need }, (_, i) => i < made ? 'done' : '')); if (made >= need) { done = true; api.stopTimer(); api.setTag('FLAWLESS'); document.removeEventListener('keydown', key); setTimeout(() => api.succeed(), 300); return; } }
      else { miss++; api.shake(); if (miss >= maxMiss) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 300); return; } }
    }
    function key(e) {
      if (done || !strike) return;
      let d = null;
      if (e.code === 'ArrowLeft' || e.code === 'KeyA') d = 'L';
      else if (e.code === 'ArrowUp' || e.code === 'KeyW') d = 'U';
      else if (e.code === 'ArrowRight' || e.code === 'KeyD') d = 'R';
      if (!d) return;
      e.preventDefault();
      resolve(d === strike.dir && strike.t >= winLo);
    }
    document.addEventListener('keydown', key);

    api.setTag('GUARD');
    api.setHint('Press [A] [W] [D] or Arrow Keys to parry strikes inside the ring');
    api.startTimer(Math.max(18, 30 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 200); } });

    function draw() {
      const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim();
      const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff453a').trim();
      if (!done) {
        if (strike) { strike.t += speed; if (strike.t >= 1) resolve(false); }
        else if (gap > 0) { gap--; if (gap === 0) spawn(); }
      }
      if (flash > 0) flash--;
      ctx.clearRect(0, 0, W, H);

      // On-screen instructions
      ctx.fillStyle = 'rgba(255,255,255,0.75)';
      ctx.font = 'bold 11px monospace';
      ctx.textAlign = 'center';
      ctx.fillText('PRESS [A] [W] [D] OR ARROWS INSIDE THE RING', cx, 22);

      const inWin = strike && strike.t >= winLo;
      ctx.strokeStyle = inWin ? suc : 'rgba(255,255,255,0.18)'; ctx.lineWidth = inWin ? 4 : 2;
      ctx.shadowColor = inWin ? suc : 'transparent'; ctx.shadowBlur = inWin ? 14 : 0;
      ctx.beginPath(); ctx.arc(cx, cy, guardR + 24, 0, Math.PI * 2); ctx.stroke(); ctx.shadowBlur = 0;

      ctx.fillStyle = flash > 0 ? flashCol : 'rgba(255,255,255,0.12)';
      ctx.shadowColor = flash > 0 ? flashCol : 'transparent'; ctx.shadowBlur = flash > 0 ? 18 : 0;
      ctx.beginPath(); ctx.arc(cx, cy, guardR, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;

      if (strike) {
        const v = DIRS[strike.dir];
        const r = maxR - (maxR - (guardR + 8)) * strike.t;
        const sx = cx + v[0] * r, sy = cy + v[1] * r;
        ctx.save(); ctx.translate(sx, sy); ctx.rotate(Math.atan2(-v[1], -v[0]));
        ctx.fillStyle = inWin ? suc : dng; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = 12;
        ctx.beginPath(); ctx.moveTo(14, 0); ctx.lineTo(-10, -10); ctx.lineTo(-10, 10); ctx.closePath(); ctx.fill();
        ctx.restore(); ctx.shadowBlur = 0;
      }

      ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '11px monospace'; ctx.textAlign = 'center';
      ctx.fillText('PARRIED ' + made + ' / ' + need, cx, H - 14);
      if (!done) loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); };
  }

  // ─── 26. CUT THE RIGHT ONE (WIRE DEFUSAL) ───────────────────────────────
  function extCutTheRight(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const count = Math.min(7, 3 + diff);
    const palette = [
      { n: 'RED', c: '#ff4d6d' }, { n: 'BLUE', c: '#5b8cff' },
      { n: 'GREEN', c: '#39d98a' }, { n: 'YELLOW', c: '#ffd23f' },
      { n: 'WHITE', c: '#e8edf2' }, { n: 'PURPLE', c: '#c06bff' },
      { n: 'ORANGE', c: '#ff8a00' }
    ];
    const wires = palette.slice(0, count).sort(() => Math.random() - 0.5);

    const idx = api.randInt(0, count - 1);
    const target = wires[idx];
    const clues = [
      `Cut the ${target.n} wire.`,
      `The safe wire is position #${idx + 1} from the top.`,
      `Cut the wire that is NOT adjacent to any wire of its own color — cut ${target.n}.`,
      `Serial ends odd → cut the ${target.n} wire.`,
      `Disarm code maps to ${target.n}.`
    ];
    const clue = clues[api.randInt(0, Math.min(clues.length - 1, diff))];

    const box = document.createElement('div');
    box.style.cssText = 'width:100%;display:flex;flex-direction:column;gap:16px;';
    box.innerHTML = `
      <div style="padding:12px 14px;border:1px solid var(--danger);border-radius:8px;
                  background:rgba(255,69,58,0.08);">
          <div class="mg-label" style="color:var(--danger);">DEFUSAL CLUE</div>
          <div style="font-size:15px;">${clue}</div>
      </div>
      <div id="wires" style="display:flex;flex-direction:column;gap:10px;"></div>`;
    api.board.appendChild(box);
    const wbox = box.querySelector('#wires');

    let dead = false;
    wires.forEach((w, i) => {
      const row = document.createElement('div');
      row.style.cssText = `display:flex;align-items:center;gap:12px;cursor:pointer;`;
      row.innerHTML = `
          <span style="width:22px;text-align:right;color:var(--muted);font-size:13px;">${i + 1}</span>
          <div class="mg-wire" style="flex:1;height:14px;border-radius:7px;
               background:${w.c};box-shadow:0 0 12px ${w.c};transition:all .2s;"></div>
          <span style="width:60px;font-size:12px;color:var(--muted);">${w.n}</span>`;
      row.addEventListener('click', () => {
        if (dead) return;
        if (w === target) {
          dead = true;
          row.querySelector('.mg-wire').style.opacity = '0.25';
          api.stopTimer();
          setTimeout(() => api.succeed(), 250);
        } else {
          dead = true;
          api.shake();
          api.stopTimer();
          setTimeout(() => api.fail(), 200);
        }
      });
      wbox.appendChild(row);
    });

    api.setTag('ARMED');
    api.startTimer(Math.max(8, 18 - diff * 2), () => api.fail());
    return () => {};
  }

  // ─── 27. DECRYPT (TYPE THE TOKEN) ───────────────────────────────────────
  function extDecrypt(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const need = 3 + diff;
    const tokenLen = 4 + diff;
    const pool = 'abcdef0123456789xZ#$%&@';

    let cleared = 0, target = '', typed = '';
    api.setDots(need);

    const box = document.createElement('div');
    box.style.cssText = 'width:100%;display:flex;flex-direction:column;gap:14px;';
    box.innerHTML = `
        <div id="stream" style="height:150px;overflow:hidden;font-size:13px;line-height:1.5;
             color:rgba(48,209,88,0.55);border:1px solid var(--line);border-radius:8px;
             padding:10px;background:rgba(0,0,0,.3);white-space:pre-wrap;"></div>
        <div style="display:flex;flex-direction:column;gap:8px;align-items:center;">
            <div class="mg-label">DECRYPT TOKEN</div>
            <div id="target" style="font-size:30px;letter-spacing:6px;font-weight:700;"></div>
            <div id="typed" style="font-size:20px;letter-spacing:6px;color:var(--accent);min-height:26px;"></div>
        </div>`;
    api.board.appendChild(box);
    const streamEl = box.querySelector('#stream');
    const targetEl = box.querySelector('#target');
    const typedEl  = box.querySelector('#typed');

    function junk(n) {
      let s = '';
      for (let i = 0; i < n; i++) s += pool[Math.floor(Math.random() * pool.length)];
      return s;
    }
    function newToken() {
      target = ''; typed = '';
      for (let i = 0; i < tokenLen; i++) target += pool[Math.floor(Math.random() * pool.length)];
      render();
    }
    function render() {
      let html = '';
      for (let i = 0; i < target.length; i++) {
        const done = i < typed.length;
        html += `<span style="color:${done ? 'var(--success)' : 'var(--muted)'};">${target[i]}</span>`;
      }
      targetEl.innerHTML = html;
      typedEl.textContent = typed || ' ';
    }

    let lines = [];
    const feedSpeed = 420 - diff * 50;
    const feed = setInterval(() => {
      lines.push('> ' + junk(api.randInt(20, 40)));
      if (lines.length > 9) lines.shift();
      streamEl.textContent = lines.join('\n');
    }, feedSpeed);

    function key(e) {
      if (e.key === 'Enter' || e.code === 'Space') {
        e.preventDefault();
        if (typed === target) {
          cleared++;
          const st = []; for (let i = 0; i < need; i++) st[i] = i < cleared ? 'done' : '';
          api.setDots(need, st);
          if (cleared >= need) { finishGame(true); return; }
          newToken();
        } else { api.shake(); typed = ''; render(); }
        return;
      }
      if (e.key === 'Backspace') { typed = typed.slice(0, -1); render(); return; }
      if (e.key.length === 1) {
        const ch = e.key;
        if (target[typed.length] === ch) { typed += ch; render(); }
        else { typed = ''; api.shake(); render(); }
      }
    }
    document.addEventListener('keydown', key);

    function finishGame(ok) {
      clearInterval(feed);
      document.removeEventListener('keydown', key);
      api.stopTimer();
      setTimeout(() => ok ? api.succeed() : api.fail(), 200);
    }

    api.startTimer(Math.max(12, 28 - diff * 2), () => finishGame(false));
    newToken();
    return () => { clearInterval(feed); document.removeEventListener('keydown', key); };
  }

  // ─── 28. VAULT DRILL (STOP IN THE CORE) ─────────────────────────────────
  function extVaultDrill(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const points = 3 + Math.floor(diff / 1.3);
    const W = 340, H = 300, cx = W / 2, cy = H / 2, R = 110;

    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    cvs.style.cursor = 'pointer';
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    const drillPts = [];
    for (let i = 0; i < points; i++) {
      const a = (i / points) * Math.PI * 2 - Math.PI / 2;
      drillPts.push({ x: cx + Math.cos(a) * R, y: cy + Math.sin(a) * R, done: false });
    }
    let cur = 0, prog = 0, dir = 1, ended = false;
    const speed = 1.2 + diff * 0.5;
    const coreLow = 42, coreHigh = 58;
    api.setDots(points);

    function attempt() {
      if (ended || cur >= points) return;
      if (prog >= coreLow && prog <= coreHigh) {
        drillPts[cur].done = true; api.sfx('zap'); cur++; prog = 0;
        api.setDots(points, drillPts.map((p) => p.done ? 'done' : ''));
        if (cur >= points) finish(true);
      } else { api.shake(); finish(false); }
    }
    function key(e) { if (e.code === 'Space') { e.preventDefault(); attempt(); } }
    document.addEventListener('keydown', key);
    cvs.addEventListener('click', attempt);

    api.setTag('DRILLING');
    api.startTimer(Math.max(12, 24 - diff * 2), () => finish(false));
    function finish(ok) { if (ended) return; ended = true; document.removeEventListener('keydown', key); api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

    function draw() {
      const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#ffd60a').trim();
      const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#30d158').trim();
      if (!ended && cur < points) { prog += dir * speed; if (prog > 100) { prog = 100; dir = -1; } if (prog < 0) { prog = 0; dir = 1; } }
      ctx.clearRect(0, 0, W, H);

      ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = 3;
      ctx.beginPath(); ctx.arc(cx, cy, R + 16, 0, Math.PI * 2); ctx.stroke();
      ctx.fillStyle = 'rgba(255,255,255,0.04)'; ctx.beginPath(); ctx.arc(cx, cy, R - 6, 0, Math.PI * 2); ctx.fill();

      drillPts.forEach((p) => {
        const isCur = !p.done && drillPts.indexOf(p) === cur && !ended;
        ctx.fillStyle = p.done ? suc : (isCur ? acc : 'rgba(255,255,255,0.2)');
        ctx.strokeStyle = ctx.fillStyle; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = isCur ? 12 : (p.done ? 10 : 0);
        ctx.beginPath(); ctx.arc(p.x, p.y, 12, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;
      });

      ctx.fillStyle = '#fff'; ctx.font = 'bold 20px monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(cur + '/' + points, cx, cy - 14);

      const bw = 140, bx = cx - bw / 2, by = cy + 18;
      ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(bx, by, bw, 14);
      ctx.fillStyle = 'rgba(48,209,88,0.25)'; ctx.fillRect(bx + bw * coreLow / 100, by, bw * (coreHigh - coreLow) / 100, 14);
      ctx.strokeStyle = suc; ctx.lineWidth = 1; ctx.strokeRect(bx + bw * coreLow / 100, by, bw * (coreHigh - coreLow) / 100, 14);
      ctx.fillStyle = '#fff'; ctx.fillRect(bx + bw * prog / 100 - 1.5, by - 3, 3, 20);
      loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); };
  }

  // ─── 29. PICKPOCKET (HOLD & RELEASE) ────────────────────────────────────
  function extPickpocket(api) {
    const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
    const W = 360, H = 280;

    const cvs = document.createElement('canvas');
    cvs.width = W; cvs.height = H;
    cvs.style.cursor = 'pointer';
    api.board.appendChild(cvs);
    const ctx = cvs.getContext('2d');

    let progress = 0, suspicion = 0, holding = false, done = false;
    let glanceT = api.rand(1.4, 2.6), glancing = false, glanceLeft = 0, warn = 0;
    const riseP = 0.16 + diff * 0.02;
    const riseS = 0.30 + diff * 0.06;
    const fallS = 0.45 + diff * 0.05;
    let last = performance.now();

    function down(e) { if (e.code === 'Space') { e.preventDefault(); holding = true; } }
    function up(e) { if (e.code === 'Space') { e.preventDefault(); holding = false; } }
    function mdown() { holding = true; }
    function mup() { holding = false; }
    document.addEventListener('keydown', down);
    document.addEventListener('keyup', up);
    cvs.addEventListener('mousedown', mdown);
    cvs.addEventListener('mouseup', mup);
    cvs.addEventListener('mouseleave', mup);

    api.setTag('STEADY');
    api.startTimer(Math.max(16, 26 - diff * 2), () => fail('TIME'));
    function clean() { document.removeEventListener('keydown', down); document.removeEventListener('keyup', up); }
    function fail(m) { if (done) return; done = true; api.setTag(m || 'CAUGHT'); api.shake(); clean(); api.stopTimer(); setTimeout(() => api.fail(), 250); }
    function win() { if (done) return; done = true; clean(); api.stopTimer(); api.setTag('LIFTED'); setTimeout(() => api.succeed(), 250); }

    function bar(x, y, w, h, v, col, label) {
      ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(x, y, w, h);
      ctx.fillStyle = col; ctx.fillRect(x, y, w * Math.min(1, v), h);
      ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '9px monospace'; ctx.textAlign = 'left';
      ctx.fillText(label, x, y - 3);
    }

    function draw() {
      const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#ffd60a').trim();
      const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff453a').trim();
      const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
      if (!done) {
        if (!glancing) {
          glanceT -= dt;
          warn = glanceT < 0.55 ? (0.55 - glanceT) / 0.55 : 0;
          if (glanceT <= 0) { glancing = true; glanceLeft = api.rand(0.7, 1.1); }
        } else {
          glanceLeft -= dt; warn = 1;
          if (holding) { fail('SPOTTED'); return; }
          if (glanceLeft <= 0) { glancing = false; glanceT = Math.max(0.9, api.rand(1.3, 2.6) - diff * 0.12); warn = 0; }
        }
        if (holding) { progress = Math.min(1, progress + riseP * dt); suspicion = Math.min(1, suspicion + riseS * dt); }
        else suspicion = Math.max(0, suspicion - fallS * dt);
        if (suspicion >= 1) { fail('TOO BOLD'); return; }
        if (progress >= 1) { win(); return; }
      }

      ctx.clearRect(0, 0, W, H);
      const cx = W / 2, hy = 92;
      ctx.fillStyle = 'rgba(255,255,255,0.08)';
      ctx.beginPath(); ctx.arc(cx, hy, 38, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.moveTo(cx - 58, H - 6); ctx.lineTo(cx - 34, hy + 28); ctx.lineTo(cx + 34, hy + 28); ctx.lineTo(cx + 58, H - 6); ctx.closePath(); ctx.fill();

      const openA = 2 + warn * 12;
      ctx.fillStyle = warn > 0.5 ? dng : 'rgba(255,255,255,0.4)';
      ctx.beginPath(); ctx.ellipse(cx, hy - 4, 13, openA, 0, 0, Math.PI * 2); ctx.fill();
      if (warn > 0.5) { ctx.fillStyle = '#0a0e14'; ctx.beginPath(); ctx.arc(cx, hy - 4, 4, 0, Math.PI * 2); ctx.fill(); }

      ctx.fillStyle = holding ? acc : 'rgba(255,255,255,0.3)';
      ctx.shadowColor = holding ? acc : 'transparent'; ctx.shadowBlur = holding ? 10 : 0;
      ctx.beginPath(); ctx.arc(cx + 44, hy + 52, holding ? 9 : 6, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;

      bar(40, H - 30, W - 80, 10, progress, acc, 'LIFT ' + Math.round(progress * 100) + '%');
      bar(40, H - 14, W - 80, 8, suspicion, suspicion > 0.7 ? dng : 'rgba(255,150,0,0.85)', 'HEAT');

      if (!done) loop = requestAnimationFrame(draw);
    }
    let loop = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(loop); clean(); cvs.removeEventListener('mousedown', mdown); cvs.removeEventListener('mouseup', mup); cvs.removeEventListener('mouseleave', mup); };
  }

  onDestroy(() => {
    stopTimer();
    if (gameCleanup) {
      if (typeof gameCleanup === 'function') gameCleanup();
      else if (gameCleanup && typeof gameCleanup.destroy === 'function') gameCleanup.destroy();
    }
    if (animFrame) cancelAnimationFrame(animFrame);
  });

  function handleKeydown(e) {
    if (e.key === 'Escape' && active) closeMinigame(false);
  }
</script>

<svelte:window on:keydown={handleKeydown} />

<!-- Always mounted, never conditionally created/destroyed — visibility is
     a plain CSS class toggle (class:hidden-overlay), same architecture as
     the reference eye_minigames project's static #root/#board (shown via
     classList.remove('hidden'), never re-created). This is the real fix
     for the "minigame never appears, NUI focus stuck" reports: with an
     {#if active} wrapper, canvasEl/extBoardEl only exist between when
     Svelte mounts this block and when it's next destroyed — a bind:this
     race on whichever tick that mount lands on (worst on the very first
     minigame of a session, before either element had ever existed). Kept
     permanently in the DOM, both refs are bound once, at this component's
     own initial mount, long before any minigame ever starts, so there is no
     "not ready yet" window left to race at all. -->
<div class="minigame-backdrop" class:hidden-overlay={!active} class:shake={isShaking}>
    <div class="minigame-card" class:ext-wide={isExtGame} class:success-border={outcome === 'success'} class:fail-border={outcome === 'fail'}>
      <!-- Top Outcome Notification Bar (on top, not in middle of game) -->
      {#if outcome === 'success'}
        <div class="top-outcome-bar success">
          <span class="outcome-icon">✔</span>
          <span class="outcome-txt">SUCCESSFUL</span>
        </div>
      {:else if outcome === 'fail'}
        <div class="top-outcome-bar fail">
          <span class="outcome-icon">✕</span>
          <span class="outcome-txt">FAILED</span>
        </div>
      {/if}

      <!-- Header -->
      <div class="minigame-header">
        <div class="header-left">
          <span class="badge-tag">{isExtGame && extTag ? extTag : 'NOVA RALLY'}</span>
          <h2 class="title">{title}</h2>
        </div>
        <div class="header-right">
          <div class="difficulty-stars">
            {#each Array(difficulty) as _}
              <span class="star">★</span>
            {/each}
          </div>
          <button class="close-btn" on:click={() => closeMinigame(false)} title="Cancel [ESC]">✕</button>
        </div>
      </div>

      <!-- Timer Bar -->
      <div class="timer-track">
        <div class="timer-fill" style="width: {(timeRemaining / maxDuration) * 100}%;"></div>
      </div>

      <!-- Canvas Play Area -->
      <div class="canvas-wrap" class:ext-wide={isExtGame} on:click={() => canvasEl?.focus()}>
        <canvas bind:this={canvasEl} class:hidden-board={isExtGame}></canvas>
        <div class="ext-board" class:hidden-board={!isExtGame} bind:this={extBoardEl}></div>
      </div>

      {#if isExtGame && dotsTotal > 0}
        <div class="ext-dots">
          {#each Array(dotsTotal) as _, i}
            <span class="ext-dot" class:done={dotsStates[i] === 'done'} class:fail={dotsStates[i] === 'fail'}></span>
          {/each}
        </div>
      {/if}

      <!-- Footer Info -->
      <div class="minigame-footer">
        {#if isExtGame}
          <span class="hint-txt">{extHint || 'Complete the task'}</span>
        {:else}
          <span class="hint-key">[SPACE]</span>
          <span class="hint-txt">Interact / Execute</span>
        {/if}
        <span class="time-readout">{timeRemaining.toFixed(1)}s</span>
      </div>
    </div>
  </div>

<style>
  .minigame-backdrop {
    position: fixed;
    inset: 0;
    z-index: 99999;
    /* #app is pointer-events:none (theme.css) so the HUD never blocks the
       game — every window that needs the mouse must opt back in, or clicks
       fall straight through it. Without this no minigame was clickable. */
    pointer-events: all;
    background: rgba(13, 14, 20, 0.92);
    display: flex;
    align-items: center;
    justify-content: center;
    user-select: none;
    font-family: var(--font-ui);
  }

  .hidden-overlay {
    display: none !important;
  }

  .minigame-card {
    background: rgba(14, 18, 28, 0.95);
    border: 1px solid rgba(255, 255, 255, 0.12);
    box-shadow: 0 20px 50px rgba(0, 0, 0, 0.7), 0 0 25px rgba(255, 140, 51, 0.12);
    border-radius: 12px;
    width: 440px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transition: border-color 0.2s, box-shadow 0.2s;
  }

  .success-border {
    border-color: #30d158 !important;
    box-shadow: 0 0 35px rgba(48, 209, 88, 0.4) !important;
  }

  .fail-border {
    border-color: #ff453a !important;
    box-shadow: 0 0 35px rgba(255, 69, 58, 0.4) !important;
  }

  .minigame-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 20px;
    background: rgba(255, 255, 255, 0.03);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
  }

  .badge-tag {
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.75px;
    color: #ffd60a;
    display: block;
    margin-bottom: 2px;
  }

  .title {
    margin: 0;
    font-size: 16px;
    font-weight: 800;
    letter-spacing: 0.5px;
    color: #f8fafc;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .difficulty-stars {
    color: #ffd60a;
    font-size: 14px;
    letter-spacing: 1px;
  }

  .close-btn {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    font-size: 16px;
    cursor: pointer;
    transition: color 0.15s;
    padding: 4px;
  }

  .close-btn:hover {
    color: #ff453a;
  }

  .timer-track {
    width: 100%;
    height: 4px;
    background: rgba(255, 255, 255, 0.08);
  }

  .timer-fill {
    height: 100%;
    background: linear-gradient(90deg, #ff8c33, #30d158);
    transition: width 0.1s linear;
  }

  .canvas-wrap {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(6, 9, 15, 0.85);
    padding: 10px 0;
  }
  .canvas-wrap.ext-wide {
    padding: 18px 22px;
  }

  canvas {
    display: block;
    cursor: pointer;
  }

  .hidden-board {
    display: none !important;
  }

  /* Extended-pack games render into this plain div via createElement/
     innerHTML instead of a bound canvas — width matches minigame-card.ext-wide
     below so their original ~460-480px layouts aren't cramped. */
  .ext-board {
    width: 100%;
    max-width: 480px;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  :global(.ext-board canvas) {
    display: block;
  }

  .minigame-card.ext-wide {
    width: 520px;
  }

  .ext-dots {
    display: flex;
    justify-content: center;
    gap: 7px;
    padding: 10px 0 0;
  }
  .ext-dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.14);
    transition: background 0.2s, box-shadow 0.2s;
  }
  .ext-dot.done {
    background: #30d158;
    box-shadow: 0 0 10px rgba(48, 209, 88, 0.7);
  }
  .ext-dot.fail {
    background: #ff453a;
    box-shadow: 0 0 10px rgba(255, 69, 58, 0.7);
  }

  /* ── Theme vars + shared classes for the pasted extended-pack games ──────
     Those games build their markup via document.createElement/innerHTML,
     which Svelte's scoped CSS can't reach — hence :global(). Colors match
     THIS app's palette (amber accent / green success / red danger), not the
     source pack's original teal theme, so newly-added games automatically
     match without editing their pasted code. */
  :global(:root) {
    --accent: #ffd60a;
    --success: #30d158;
    --danger: #ff453a;
    --line: rgba(255, 255, 255, 0.1);
    --muted: #9aa0ac;
    --text: #d8d8e1;
    --bg: #131518;
    --panel: #181b1f;
    --display: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    --mono: 'Azeret Mono', ui-monospace, monospace;
  }
  .minigame-backdrop :global(.mg-label) {
    font-size: 12px;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 6px;
  }
  .minigame-backdrop :global(.mg-wire) {
    display: block;
  }
  .minigame-backdrop :global(.btn) {
    font-family: var(--display);
    font-weight: 600;
    letter-spacing: 0.5px;
    font-size: 13px;
    padding: 10px 18px;
    border-radius: 6px;
    border: 1px solid var(--line);
    background: #1f2328;
    color: var(--text);
    cursor: pointer;
    transition: all 0.15s;
  }
  .minigame-backdrop :global(.btn:hover) {
    border-color: #4f94e6;
    background: #272b31;
  }
  .minigame-backdrop :global(.btn.danger) {
    background: rgba(255, 93, 80, 0.15);
    border-color: rgba(255, 93, 80, 0.4);
    color: #ff5d50;
  }
  .minigame-backdrop :global(.btn.danger:hover) {
    border-color: #ff5d50;
    background: rgba(255, 93, 80, 0.3);
  }
  .minigame-backdrop :global(.label) {
    font-size: 11px;
    letter-spacing: 1.5px;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 8px;
  }
  .minigame-backdrop :global(.glow-accent) { color: var(--accent); }
  .minigame-backdrop :global(.glow-success) { color: var(--success); }
  .minigame-backdrop :global(.glow-danger) { color: var(--danger); }

  .top-outcome-bar {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 42px;
    z-index: 100;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 2px;
    text-transform: uppercase;
    border-radius: 12px 12px 0 0;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
    animation: topSlideIn 0.22s cubic-bezier(0.16, 1, 0.3, 1) both;
  }

  .top-outcome-bar.success {
    background: #30d158;
    color: #131518;
    border-bottom: 2px solid #28b84d;
  }

  .top-outcome-bar.fail {
    background: #ff453a;
    color: #ffffff;
    border-bottom: 2px solid #e0382e;
  }

  .outcome-icon {
    font-size: 16px;
    font-weight: 900;
  }

  .outcome-txt {
    font-family: var(--font-mono);
  }

  @keyframes topSlideIn {
    from {
      opacity: 0;
      transform: translateY(-100%);
    }
    to {
      opacity: 1;
      transform: translateY(0);
    }
  }

  .minigame-footer {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 20px;
    background: rgba(255, 255, 255, 0.02);
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    font-size: 13px;
    color: rgba(255, 255, 255, 0.5);
  }

  .hint-key {
    background: rgba(255, 255, 255, 0.12);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono);
    font-weight: 700;
    color: #fff;
  }

  .time-readout {
    margin-left: auto;
    font-family: var(--font-mono);
    font-weight: 700;
    color: #ffd60a;
  }

  @keyframes popIn {
    0% { transform: scale(0.9); opacity: 0; }
    100% { transform: scale(1); opacity: 1; }
  }

  .shake {
    animation: shakeAnim 0.35s cubic-bezier(0.36, 0.07, 0.19, 0.97) both;
  }

  @keyframes shakeAnim {
    10%, 90% { transform: translate3d(-2px, 0, 0); }
    20%, 80% { transform: translate3d(4px, 0, 0); }
    30%, 50%, 70% { transform: translate3d(-6px, 0, 0); }
    40%, 60% { transform: translate3d(6px, 0, 0); }
  }
</style>
