<script>
  import { onMount, onDestroy } from 'svelte';
  import { flip } from 'svelte/animate';
  import { cubicOut } from 'svelte/easing';
  import { raceTowerHud, raceGridHud } from './hudStore.js';
  import { themeVars } from './eventThemes.js';

  // Race standings tower, in the style of an arcade racing game: a big position readout on top, the checkpoint progress and the
  // race clock, then the racers in finishing order on slanted tiles with how far each one is behind the leader. Colour = the
  // Gang Rally event colour (eventThemes.js) so it never reads as another event.

  $: visible = $raceTowerHud.visible;
  // The Race event's own name (set in the tablet) — the server sends it as `title`.
  $: title = $raceTowerHud.title || 'Gang Rally';
  $: totalCps = Math.max(1, $raceTowerHud.totalCheckpoints || 1);
  $: myIdentifier = $raceTowerHud.myIdentifier;
  $: localPlayerId = $raceTowerHud.localPlayerId;
  $: rawRacers = $raceTowerHud.racers || [];
  $: maxRows = $raceTowerHud.maxRows || 8;

  let elapsedSeconds = 0;
  let timerInterval = null;
  let wasVisible = false;

  // Fresh clock for every race.
  $: {
    if (visible && !wasVisible) elapsedSeconds = 0;
    wasVisible = visible;
  }

  // The server owns the race clock (it starts at GO); the local tick is only a fallback.
  $: serverClock = typeof $raceTowerHud.elapsedSeconds === 'number';
  $: if (serverClock) elapsedSeconds = $raceTowerHud.elapsedSeconds;

  onMount(() => {
    timerInterval = setInterval(() => {
      if (visible && !serverClock) elapsedSeconds += 1;
    }, 1000);
  });

  onDestroy(() => {
    if (timerInterval) clearInterval(timerInterval);
  });

  function formatTime(totalSecs) {
    const s = Math.max(0, Math.floor(Number(totalSecs) || 0));
    return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  }

  const pad2 = (n) => String(n).padStart(2, '0');
  function suffix(n) {
    const v = n % 100;
    if (v >= 11 && v <= 13) return 'th';
    return ['th', 'st', 'nd', 'rd'][n % 10] || 'th';
  }

  // `cp` = checkpoints this racer has cleared after the start line, sent by the server.
  $: racers = rawRacers
    .map((r, i) => {
      const pos = Number(r.position ?? i + 1);
      const isYou =
        (myIdentifier != null && (r.identifier === myIdentifier || String(r.id) === String(myIdentifier))) ||
        (localPlayerId != null && (String(r.source) === String(localPlayerId) || String(r.id) === String(localPlayerId))) ||
        r.isLocalPlayer === true ||
        r.isPlayer === true;
      const cp = Math.min(totalCps, Math.max(0, Number(r.cp) || 0));
      const rawTeam = (r.team || r.gangLabel || (r.gang !== 'civilian' ? r.gang : '') || '').trim();
      const isCivilian = r.isCivilian === true || r.participantType === 'civilian' || /^(civilian|non-gang|civilian player)$/i.test(rawTeam);
      const team = isCivilian ? '' : rawTeam;
      return {
        ...r,
        position: pos,
        isYou,
        name: r.name || 'Racer',
        team,
        cp,
        pct: r.finished ? 100 : Math.max(4, Math.min(100, (cp / totalCps) * 100)),
        done: r.finished === true,
        out: r.isOut === true,
      };
    })
    .sort((a, b) => a.position - b.position);

  $: player = racers.find((p) => p.isYou);
  $: shown = racers.slice(0, maxRows);
  // If the local racer is ranked below the visible rows, pin them at the bottom.
  $: pinned = player && !shown.includes(player) ? player : null;
  $: myCp = player ? player.cp : 0;
  $: leaderCp = racers.length ? Math.max(...racers.map((r) => (r.done ? totalCps : r.cp))) : 0;
  // the position the big readout shows: yours, or the leader's if you are only watching
  $: bigPos = player ? player.position : (racers[0]?.position || 1);

  // One keyed list (top rows, then the pinned local racer if they're below them) so a row that changes rank glides to its new
  // slot with animate:flip instead of snapping.
  $: rows = pinned ? [...shown, pinned] : shown;
  const keyOf = (r) => r.identifier || r.name;

  // "how far behind the leader", in checkpoints (the server sends no time gaps)
  function gapText(p) {
    if (p.done) return 'Finished';
    if (p.out) return 'Out';
    if (p.position === 1) return 'Leader';
    const behind = leaderCp - p.cp;
    return behind > 0 ? `−${behind} CP` : 'Same CP';
  }

  // Who just gained / lost places, for a short marker on the moving tile.
  let prevPos = {};
  let moved = {};
  function trackMoves(list) {
    const next = {};
    const fresh = {};
    for (const r of list) {
      const k = keyOf(r);
      next[k] = r.position;
      const before = prevPos[k];
      if (before != null && r.position < before) fresh[k] = 'up';
      else if (before != null && r.position > before) fresh[k] = 'down';
    }
    prevPos = next;
    const keys = Object.keys(fresh);
    if (keys.length) {
      moved = { ...moved, ...fresh };
      setTimeout(() => {
        const cur = { ...moved };
        for (const k of keys) if (cur[k] === fresh[k]) delete cur[k];
        moved = cur;
      }, 1800);
    }
  }
  $: trackMoves(racers);

  function posClass(p) {
    if (p.position === 1) return 'p1';
    if (p.position === 2) return 'p2';
    if (p.position === 3) return 'p3';
    return '';
  }

  $: grid = $raceGridHud;
  // HH:MM:SS, so a wait of an hour or more reads correctly
  $: gridTime = (() => {
    const s = Math.max(0, Math.floor(Number(grid.seconds) || 0));
    const p = (n) => String(n).padStart(2, '0');
    return `${p(Math.floor(s / 3600))}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}`;
  })();
</script>

{#if grid.visible}
  <div class="grid-wait" style={themeVars('rally')}>
    <div class="gw-skin">
      <span class="gw-flag" aria-hidden="true">
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3v18M6 4h11l-2.5 3.5L17 11H6"/></svg>
      </span>
      <div class="gw-text">
        <div class="gw-label">{grid.label}</div>
        {#if grid.sub}<div class="gw-sub">{grid.sub}</div>{/if}
      </div>
      <div class="gw-time">{gridTime}</div>
    </div>
  </div>
{/if}

{#if visible}
  <div class="tower" style={themeVars('rally')} aria-label="Race standings">
    <!-- position, checkpoint and clock -->
    <header class="top">
      <div class="top-skin">
        <div class="pos-block">
          <span class="pos-num">{bigPos}</span><span class="pos-suf">{suffix(bigPos)}</span>
          <span class="pos-of">/ {racers.length}</span>
        </div>
        <div class="top-info">
          <div class="event" title={title}>{title}</div>
          <div class="stats">
            <div class="stat"><span class="k">Checkpoint</span><span class="v">{pad2(myCp)}<i>/{pad2(totalCps)}</i></span></div>
            <div class="stat"><span class="k">Time</span><span class="v">{formatTime(elapsedSeconds)}</span></div>
          </div>
        </div>
        <span class="live"><i></i>Live</span>
      </div>
      <!-- one segment per checkpoint -->
      <div class="pips" aria-hidden="true">
        {#each Array(Math.min(totalCps, 30)) as _, i}
          <i class:on={i < Math.round((myCp / totalCps) * Math.min(totalCps, 30))}></i>
        {/each}
      </div>
    </header>

    <!-- racers in finishing order -->
    <div class="list">
      {#each rows as p (keyOf(p))}
        <div class="row {posClass(p)}" class:me={p.isYou} class:out={p.out} animate:flip={{ duration: 520, easing: cubicOut }}>
          <div class="skin">
            <div class="pos"><span>{p.position}</span></div>
            <div class="who">
              <div class="name">
                <span class="nm">{p.name}</span>
                {#if p.isYou}<b class="you">You</b>{/if}
                {#if moved[keyOf(p)] === 'up'}<i class="mv up" aria-label="Gained a place"></i>{/if}
                {#if moved[keyOf(p)] === 'down'}<i class="mv down" aria-label="Lost a place"></i>{/if}
              </div>
              {#if p.team}<div class="team">{p.team}</div>{/if}
            </div>
            <div class="gap" class:done={p.done}><span>{gapText(p)}</span></div>
            <i class="bar" style="width:{p.pct}%"></i>
          </div>
        </div>
      {/each}

      {#if racers.length === 0}
        <div class="empty">Waiting for racers…</div>
      {/if}
    </div>
  </div>
{/if}

<style>
  /* ── Pre-start timer: a small pill, top-left, so it never gets in anyone's way ──────────── */
  .grid-wait {
    position: fixed;
    top: 70px;
    left: 24px;
    z-index: 9991;
    max-width: 300px;
    pointer-events: none;
    user-select: none;
    font-family: var(--font-ui);
    color: #fff;
  }
  .gw-skin {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 6px 16px 6px 12px;
    background: rgba(10, 13, 19, 0.92);
    border-left: 4px solid var(--accent, #22c7d6);
    transform: skewX(-10deg);
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.5);
  }
  .gw-flag, .gw-text, .gw-time { transform: skewX(10deg); }
  .gw-flag { flex: none; display: grid; place-items: center; color: var(--accent2, #5ee0ee); }
  .gw-text { min-width: 0; }
  .gw-label { font-size: 12.5px; font-weight: 700; color: #c9ced4; white-space: nowrap; }
  .gw-sub { max-width: 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; color: #8d949c; }
  .gw-time { flex: none; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 24px; font-weight: 800; line-height: 1; font-variant-numeric: tabular-nums; }

  /* ── Standings tower ────────────────────────────────────────────────── */
  .tower {
    position: fixed;
    top: 70px;
    left: 24px;
    z-index: 9990;
    width: 392px;
    pointer-events: none;
    user-select: none;
    font-family: var(--font-ui);
    color: #f1f3f5;
    --gold: #ffd64a;
    --silver: #d5e1e8;
    --bronze: #ef9b69;
  }

  /* the slanted top block */
  .top { margin-bottom: 8px; }
  .top-skin {
    position: relative;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 10px 18px 10px 18px;
    background: linear-gradient(100deg, rgba(var(--accentRGB), 0.22), rgba(10, 13, 19, 0.96) 46%), rgba(10, 13, 19, 0.96);
    border-left: 5px solid var(--accent);
    transform: skewX(-10deg);
    box-shadow: 0 10px 26px rgba(0, 0, 0, 0.55);
  }
  .top-skin > * { transform: skewX(10deg); }
  .pos-block { display: flex; align-items: baseline; flex: none; font-family: var(--font-display); font-stretch: var(--stretch-display); font-style: italic; }
  .pos-num { font-size: 58px; font-weight: 800; line-height: 0.95; color: #fff; }
  .pos-suf { margin-left: 2px; font-size: 22px; font-weight: 800; color: var(--accent2); }
  .pos-of { margin-left: 8px; font-size: 18px; font-weight: 700; color: #8d949c; }
  .top-info { min-width: 0; flex: 1; }
  .event { font-size: 13.5px; font-weight: 700; color: #aeb5bd; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .stats { display: flex; gap: 20px; margin-top: 4px; }
  .stat { display: flex; flex-direction: column; }
  .k { font-size: 12px; font-weight: 600; color: #8d949c; }
  .v { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 21px; font-weight: 700; line-height: 1.1; font-variant-numeric: tabular-nums; color: #fff; }
  .v i { font-style: normal; font-size: 15px; font-weight: 600; color: #8d949c; }
  .live { flex: none; display: inline-flex; align-items: center; gap: 6px; padding: 3px 9px; border-radius: 4px; font-size: 12.5px; font-weight: 800; letter-spacing: 0.5px; text-transform: uppercase;
    color: #04181a; background: var(--accent); }
  .live i { width: 6px; height: 6px; border-radius: 50%; background: #04181a; animation: livePulse 1.4s ease-in-out infinite; }
  @keyframes livePulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }

  /* checkpoint segments, straight under the block */
  .pips { display: flex; gap: 3px; height: 6px; margin: 6px 4px 0 6px; transform: skewX(-10deg); }
  .pips i { flex: 1; background: rgba(255, 255, 255, 0.14); transition: background 0.25s; }
  .pips i.on { background: var(--accent); }

  /* rows */
  .list { display: flex; flex-direction: column; }
  .row { margin: 3px 0; }
  .skin {
    position: relative;
    display: grid;
    grid-template-columns: 54px minmax(0, 1fr) auto;
    align-items: center;
    height: 48px;
    background: rgba(12, 15, 21, 0.94);
    border-left: 4px solid #3a424b;
    transform: skewX(-10deg);
    overflow: hidden;
  }
  .row.p1 .skin { border-left-color: var(--gold); }
  .row.p2 .skin { border-left-color: var(--silver); }
  .row.p3 .skin { border-left-color: var(--bronze); }
  .row.me .skin { background: linear-gradient(100deg, rgba(var(--accentRGB), 0.34), rgba(14, 18, 25, 0.95) 80%); border-left-color: var(--accent); }
  .row.out .skin { opacity: 0.5; }

  /* the position number sits on its own slab */
  .pos { align-self: stretch; display: grid; place-items: center; background: rgba(255, 255, 255, 0.07); }
  .pos span { display: inline-block; transform: skewX(10deg); font-family: var(--font-display); font-stretch: var(--stretch-display); font-style: italic; font-size: 26px; font-weight: 800; line-height: 1; font-variant-numeric: tabular-nums; color: #e4e8ec; }
  .row.p1 .pos { background: var(--gold); }
  .row.p2 .pos { background: var(--silver); }
  .row.p3 .pos { background: var(--bronze); }
  .row.p1 .pos span, .row.p2 .pos span, .row.p3 .pos span { color: #14110a; }
  .row.me:not(.p1):not(.p2):not(.p3) .pos { background: var(--accent); }
  .row.me:not(.p1):not(.p2):not(.p3) .pos span { color: #04181a; }

  .who { min-width: 0; padding: 0 10px; transform: skewX(10deg); }
  .name { display: flex; align-items: center; gap: 7px; min-width: 0; }
  .nm { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 16px; font-weight: 700; color: #fff; }
  .you { flex: none; padding: 1px 6px; border-radius: 3px; font-size: 11.5px; font-weight: 800; text-transform: uppercase; color: #04181a; background: var(--accent2); }
  .team { margin-top: 1px; font-size: 12.5px; color: #8d949c; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  /* gained / lost a place */
  .mv { flex: none; width: 0; height: 0; border-left: 5px solid transparent; border-right: 5px solid transparent; animation: mvIn 0.3s ease-out; }
  .mv.up { border-bottom: 8px solid #46c98b; }
  .mv.down { border-top: 8px solid #ff5d50; }
  @keyframes mvIn { from { opacity: 0; transform: scale(0.5); } to { opacity: 1; transform: none; } }

  .gap { padding: 0 16px 0 6px; transform: skewX(10deg); text-align: right; white-space: nowrap; }
  .gap span { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 16px; font-weight: 700; font-variant-numeric: tabular-nums; color: #aeb5bd; }
  .row.p1 .gap span { color: var(--gold); }
  .gap.done span { color: #6fe3a0; }

  /* progress along the course, a thin line under the tile */
  .bar { position: absolute; left: 0; bottom: 0; height: 3px; background: var(--accent); transition: width 0.4s ease; }
  .row.out .bar { background: #6b7480; }

  .empty { padding: 16px; text-align: center; font-size: 14px; color: #8d949c; background: rgba(12, 15, 21, 0.9); }

  @media (prefers-reduced-motion: reduce) {
    .live i, .mv { animation: none; }
    .bar, .pips i { transition: none; }
  }
</style>
