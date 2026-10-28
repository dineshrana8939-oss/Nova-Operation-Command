<script>
  // The live tournament tree — header, stage indicator, current/next match,
  // group standings + fixtures, knockout bracket, champion. Pure display of
  // the server's tournament view (tournament.lua's buildView); shared by the
  // admin Tournaments tab and the gang Event Status panel so both always show
  // the same thing. `myGang` (gang panel only) highlights that gang, its
  // opponent and its road to the final and dims finished unrelated paths.
  import { createEventDispatcher, onDestroy } from 'svelte';
  import Icon from '../tablet/ui/Icon.svelte';
  import {
    CARD_W, CARD_H, COL_GAP, layoutBracket, slotText, gangLabel, gangColor, formatClock, computeMyPath,
  } from './tournamentUtil.js';

  export let t;
  export let myGang = null;
  // Admin: clicking a waiting match emits `matchClick` so it can be given a result.
  export let selectable = false;
  // Admin screen supplies its own title bar (tournament switcher), so it can hide ours.
  export let showTitle = true;

  const dispatch = createEventDispatcher();

  // ── view mode (group vs knockout) ─────────────────────────────────────────
  // Follows the tournament automatically (groups until qualification, then
  // the bracket) until the viewer picks one — the other stage always stays
  // available, so the group results never disappear once knockout starts.
  let viewMode = null;
  let lastId = null;
  $: if (t && t.id !== lastId) { lastId = t.id; viewMode = null; }
  // The tree is the main view: open on the bracket whenever there is one, except while the
  // group stage is actually being played (then the standings matter more).
  $: mode = viewMode || ((t?.status === 'LIVE' && !t?.qualified && (t?.groups || []).length) ? 'GROUP' : (hasKo ? 'KO' : 'GROUP'));

  // ── ticking clocks between server polls ───────────────────────────────────
  let clock = null;
  let sinceUpdate = 0;
  $: {
    clock = t?.currentMatch?.live?.timeRemaining ?? null;
    sinceUpdate = 0;
  }
  const iv = setInterval(() => {
    sinceUpdate += 1;
    if (clock != null && clock > 0 && t?.currentMatch?.live?.phase === 'ACTIVE') clock -= 1;
  }, 1000);
  onDestroy(() => clearInterval(iv));

  // ── derived data ──────────────────────────────────────────────────────────
  $: label = (g) => gangLabel(t, g);
  $: liveMatch = t?.currentMatch ? (t.matches || []).find((m) => m.id === t.currentMatch.id) : null;
  $: nextMatch = t?.nextMatchId ? (t.matches || []).find((m) => m.id === t.nextMatchId) : null;
  $: myPath = computeMyPath(t, myGang);
  $: routeIds = myPath?.route || new Set();
  $: layout = layoutBracket(t?.matches || []);
  $: hasKo = layout.cards.length > 0;
  $: allMatches = [...(t?.matches || [])].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));

  let zoom = 1;
  function setZoom(d) {
    zoom = d === 0 ? 1 : Math.max(0.6, Math.min(1.5, Math.round((zoom + d) * 100) / 100));
  }
  // A knockout column is 'current' while it still has a live or waiting match.
  const roundIsCurrent = (r) => r.some((m) => m.status === 'LIVE' || m.status === 'READY');
  $: finalCard = layout.cards.find((c) => c.m.round === layout.rounds.length);
  $: bracketWidth = layout.width + (hasKo ? COL_GAP + CARD_W : 0);
  $: stageIdx = (t?.stages || []).findIndex((s) => s.key === t?.currentStage);
  $: allDone = t?.status === 'COMPLETED';

  $: statusText = t?.status === 'LIVE' ? 'LIVE'
    : t?.status === 'COMPLETED' ? 'COMPLETED'
    : t?.status === 'CANCELLED' ? 'CANCELLED'
    : t?.status === 'SCHEDULED' ? (t.registrationOpen ? 'REGISTRATION OPEN' : 'UPCOMING')
    : 'DRAFT';

  $: autoStartIn = (t?.status === 'LIVE' && t.autoAdvance && !liveMatch && nextMatch && t.nextMatchAt)
    ? Math.max(0, t.nextMatchAt - (t.serverNow + sinceUpdate))
    : null;

  function matchStatusWord(m) {
    if (m.status === 'LIVE') return 'LIVE';
    if (m.status === 'COMPLETE') return m.decidedBy === 'BYE' ? 'BYE' : 'COMPLETED';
    return 'UPCOMING';
  }

  // Live scores come from the running TDM match, not the stored result.
  function scoreOf(m, side) {
    if (m.status === 'LIVE' && t.currentMatch?.id === m.id && t.currentMatch.live) {
      return side === 0 ? t.currentMatch.live.scoreA : t.currentMatch.live.scoreB;
    }
    if (m.status === 'COMPLETE') {
      if (m.decidedBy === 'BYE') return '';
      if (m.walkover && m.walkover !== 'BYE') return 'W/O';
      return side === 0 ? m.scoreA : m.scoreB;
    }
    return '';
  }

  function isWinner(m, side) {
    const gang = side === 0 ? m.a?.gang : m.b?.gang;
    return m.status === 'COMPLETE' && !!m.winner && m.winner === gang;
  }
  function isLoser(m, side) {
    const gang = side === 0 ? m.a?.gang : m.b?.gang;
    return m.status === 'COMPLETE' && !!m.winner && !!gang && m.winner !== gang;
  }

  function footerText(m) {
    if (m.status === 'LIVE') return 'IN PROGRESS';
    if (m.status !== 'COMPLETE') return '';
    if (m.decidedBy === 'BYE') return `${label(m.winner)} • ADVANCES (BYE)`;
    if (!m.winner) return m.doubleForfeit ? 'DOUBLE FORFEIT' : 'DRAW';
    const extra = m.walkover ? ' (W/O)' : (m.decidedBy === 'SEED' ? ' (SEED)' : '');
    return `${label(m.winner)} • WINNER${extra}`;
  }

  function groupMatches(gi) {
    return (t.matches || []).filter((m) => m.stage === 'GROUP' && m.group === gi + 1);
  }

  function qualStatus(g, row) {
    if (!t.qualified) return null;
    return row.rank <= t.cfg.advance ? 'QUALIFIED' : 'ELIMINATED';
  }

  function clickMatch(m) {
    if (selectable) dispatch('matchClick', m);
  }

  const STATUS_TONE = { LIVE: 'live', COMPLETED: 'done', 'REGISTRATION OPEN': 'reg', UPCOMING: 'up', DRAFT: 'up', CANCELLED: 'cancel' };
</script>

{#if t}
<div class="tt">
  <!-- ── Header ───────────────────────────────────────────────────────────── -->
  {#if showTitle}
  <header class="tt-head">
    {#if showTitle}
    <div class="tt-title-row">
      <Icon name="trophy" size={18} />
      <h2>{t.name}</h2>
      <span class="pill tone-{STATUS_TONE[statusText]}">{#if statusText === 'LIVE'}<i class="dot"></i>{/if}{statusText}</span>
      {#if t.edition > 1 || t.seriesId}<span class="edition">EDITION {String(t.edition).padStart(2, '0')}</span>{/if}
      <span class="when">{t.schedule?.startLabel || ''}{t.schedule?.type && t.schedule.type !== 'ONE_TIME' ? ` · ${t.schedule.type}` : ''}</span>
    </div>
    {/if}
    <div class="tt-stats">
      <div class="stat"><span class="k">Current stage</span><span class="v">{(t.stages || []).find((s) => s.key === t.currentStage)?.label || '—'}</span></div>
      <div class="stat wide"><span class="k">{liveMatch ? 'Current match' : 'Next match'}</span>
        <span class="v">{#if liveMatch}{slotText(t, liveMatch.a).text} vs {slotText(t, liveMatch.b).text}{:else if nextMatch}{slotText(t, nextMatch.a).text} vs {slotText(t, nextMatch.b).text}{:else}—{/if}</span>
      </div>
      <div class="stat"><span class="k">Match timer</span><span class="v mono">{liveMatch ? formatClock(clock) : (autoStartIn != null ? `in ${formatClock(autoStartIn)}` : '--:--')}</span></div>
      <div class="stat"><span class="k">Status</span><span class="v">{liveMatch ? 'LIVE' : statusText}</span></div>
    </div>
  </header>
  {/if}

  <!-- ── Stage indicator ──────────────────────────────────────────────────── -->
  <div class="stage-bar">
    {#each t.stages || [] as s, i}
      <div class="stage" class:current={!allDone && i === stageIdx} class:done={allDone || i < stageIdx}>
        <span class="n">{i + 1}</span><span>{s.label}</span>
      </div>
      {#if i < (t.stages || []).length - 1}<span class="sep"></span>{/if}
    {/each}
  </div>

  <!-- ── Live / next match ────────────────────────────────────────────────── -->
  {#if liveMatch}
    <section class="feature live">
      <div class="f-label">CURRENT MATCH · {liveMatch.label}</div>
      <div class="f-board">
        <div class="f-team" class:me={liveMatch.a.gang === myGang}>
          <span class="nm">{slotText(t, liveMatch.a).text}</span>
          <span class="sc mono">{scoreOf(liveMatch, 0)}</span>
        </div>
        <div class="f-mid"><span class="vs">VS</span><span class="pill tone-live"><i class="dot"></i>LIVE</span><span class="mono rem">{formatClock(clock)} REMAINING</span></div>
        <div class="f-team right" class:me={liveMatch.b.gang === myGang}>
          <span class="sc mono">{scoreOf(liveMatch, 1)}</span>
          <span class="nm">{slotText(t, liveMatch.b).text}</span>
        </div>
      </div>
    </section>
  {:else if nextMatch && t.status === 'LIVE'}
    <section class="feature">
      <div class="f-label">NEXT MATCH · {nextMatch.label}</div>
      <div class="f-board">
        <div class="f-team" class:me={nextMatch.a.gang === myGang}><span class="nm">{slotText(t, nextMatch.a).text}</span></div>
        <div class="f-mid"><span class="vs">VS</span>{#if autoStartIn != null}<span class="mono rem">STARTS IN {formatClock(autoStartIn)}</span>{:else if !t.autoAdvance}<span class="rem">WAITING FOR ADMIN</span>{/if}</div>
        <div class="f-team right" class:me={nextMatch.b.gang === myGang}><span class="nm">{slotText(t, nextMatch.b).text}</span></div>
      </div>
      {#if t.lastError}<div class="warn"><Icon name="warning" size={12} /> {t.lastError}</div>{/if}
    </section>
  {/if}

  {#if t.champion}
    <section class="champion">
      <Icon name="crown" size={22} />
      <div><div class="c-k">CHAMPION</div><div class="c-v">{label(t.champion)}</div></div>
    </section>
  {/if}

  <!-- ── My gang (gang panel) ─────────────────────────────────────────────── -->
  {#if myPath}
    <section class="mine-panel">
      <div class="m-cell"><span class="k">Your gang</span><span class="v">{label(myPath.gang)}</span></div>
      <div class="m-cell"><span class="k">Group</span><span class="v">{myPath.group ? `${myPath.group.name} · ${myPath.row ? `#${myPath.row.rank}` : '—'}` : '—'}</span></div>
      <div class="m-cell"><span class="k">Current round</span><span class="v">{myPath.current ? (myPath.current.stage === 'GROUP' ? `Group · MD ${myPath.current.round}` : myPath.current.roundName) : '—'}</span></div>
      <div class="m-cell"><span class="k">Opponent</span><span class="v">{myPath.opponent || '—'}</span></div>
      {#if myPath.nextOpponent}<div class="m-cell"><span class="k">If you win</span><span class="v">{myPath.nextOpponent}</span></div>{/if}
      <div class="m-cell"><span class="k">Status</span><span class="v st-{myPath.status.toLowerCase()}">{myPath.status}</span></div>
    </section>
  {/if}

  <!-- ── Tree shell: tabs + zoom, then Bracket / Matches / Standings ─────── -->
  <div class="shell">
    <div class="toolbar">
      <div class="tabs">
        <button class:active={mode === 'KO'} on:click={() => (viewMode = 'KO')}>Bracket</button>
        <button class:active={mode === 'MATCHES'} on:click={() => (viewMode = 'MATCHES')}>Matches</button>
        <button class:active={mode === 'GROUP'} on:click={() => (viewMode = 'GROUP')}>Standings</button>
      </div>
      <div class="tool-right">
      <slot name="tools" />
      {#if mode === 'KO' && hasKo}
        <div class="tools">
          <button title="Zoom out" on:click={() => setZoom(-0.1)}>−</button>
          <button title="Reset zoom" class="zoom-label" on:click={() => setZoom(0)}>{Math.round(zoom * 100)}%</button>
          <button title="Zoom in" on:click={() => setZoom(0.1)}>+</button>
        </div>
      {/if}
      </div>
    </div>

    <!-- Bracket -->
    {#if mode === 'KO'}
      {#if !hasKo}
        <div class="empty flat">The bracket appears once the draw is made.</div>
      {:else}
        {#if !t.qualified}<div class="ko-note">Slots like “GROUP A #1” fill in automatically when the group stage finishes.</div>{/if}
        <div class="viewport">
          <div class="canvas" style="width:{bracketWidth * zoom + 40}px;height:{(layout.height + 70) * zoom}px">
            <div class="bracket" style="width:{bracketWidth}px;height:{layout.height}px;transform:scale({zoom})">
              <svg width={bracketWidth} height={layout.height}>
                {#each layout.lines as l}
                  <path d={l.d} class:route={routeIds.has(l.from) && routeIds.has(l.to)} />
                {/each}
                {#if finalCard}
                  <path class="gold" d={`M${finalCard.x + CARD_W} ${finalCard.y + CARD_H / 2} H${finalCard.x + CARD_W + COL_GAP}`} />
                {/if}
              </svg>

              {#each layout.rounds as r, ri}
                <div class="round-name" class:current={roundIsCurrent(r)} style="left:{ri * (CARD_W + COL_GAP)}px;width:{CARD_W}px">
                  <span>{r[0].roundName}</span><small>{r.length} {r.length === 1 ? 'MATCH' : 'MATCHES'}</small>
                </div>
              {/each}

              {#each layout.cards as c (c.m.id)}
                {@const m = c.m}
                {@const involvesMe = m.a.gang === myGang || m.b.gang === myGang}
                <button type="button" class="mc {m.status.toLowerCase()}" class:route={routeIds.has(m.id)}
                  class:dim={myGang && m.status === 'COMPLETE' && !involvesMe && !routeIds.has(m.id)}
                  class:clickable={selectable && m.status === 'READY'}
                  style="left:{c.x}px;top:{c.y}px;width:{CARD_W}px;height:{CARD_H}px"
                  on:click={() => clickMatch(m)}>
                  <div class="mc-top"><span>{m.label}</span><span class="st st-{matchStatusWord(m).toLowerCase()}">{#if m.status === 'LIVE'}● {/if}{matchStatusWord(m)}</span></div>
                  {#each [m.a, m.b] as side, si}
                    {@const s = slotText(t, side)}
                    <div class="mc-row" class:win={isWinner(m, si)} class:lose={isLoser(m, si)} class:tbd={s.tbd} class:me={side.gang && side.gang === myGang}
                      style="--gc:{side.gang ? gangColor(t, side.gang) : '#555c5e'}">
                      <span class="nm">{s.text}{#if isLoser(m, si)}<em>OUT</em>{/if}</span>
                      <span class="sc mono">{scoreOf(m, si)}</span>
                    </div>
                  {/each}
                  <div class="mc-foot">{footerText(m)}</div>
                </button>
              {/each}

              {#if finalCard}
                <div class="champ-card" class:won={!!t.champion} style="left:{finalCard.x + CARD_W + COL_GAP}px;top:{finalCard.y}px;width:{CARD_W}px;height:{CARD_H}px">
                  <Icon name="crown" size={16} />
                  <div class="cc-k">CHAMPION</div>
                  <div class="cc-v" class:me={!!myGang && t.champion === myGang}>{t.champion ? label(t.champion) : 'TBD'}</div>
                </div>
              {/if}
            </div>
          </div>
        </div>

        <div class="legend">
          <div class="legend-block">
            <span class="legend-title">GANGS</span>
            {#each t.cfg?.gangs || [] as g (g)}
              <span class="legend-item"><i class="swatch" style="background:{gangColor(t, g)}"></i>{label(g)}</span>
            {/each}
          </div>
          <div class="legend-block">
            <span class="legend-title">MATCH STATUS</span>
            <span class="legend-item"><i class="swatch win"></i>Advanced</span>
            <span class="legend-item"><i class="swatch live"></i>Live</span>
            <span class="legend-item"><i class="swatch tbd"></i>Pending</span>
          </div>
        </div>
      {/if}
    {/if}

    <!-- Matches: every fixture in play order -->
    {#if mode === 'MATCHES'}
      {#if !(t.matches || []).length}
        <div class="empty flat">No matches yet — they are generated when the draw is made.</div>
      {:else}
        <div class="match-list">
          <div class="ml-head"><span>#</span><span>Stage</span><span class="r">Team A</span><span class="c">Score</span><span>Team B</span><span class="r">Status</span></div>
          {#each allMatches as m (m.id)}
            <button type="button" class="ml-row" class:live={m.status === 'LIVE'} class:done={m.status === 'COMPLETE'}
              class:clickable={selectable && m.status === 'READY'} on:click={() => clickMatch(m)}>
              <span class="mono ml-n">{m.label}</span>
              <span class="ml-stage">{m.stage === 'GROUP' ? `Group ${(t.groups || [])[m.group - 1]?.name || ''} · MD${m.round}` : m.roundName}</span>
              <span class="ml-a r" class:win={isWinner(m, 0)}><i class="swatch" style="background:{m.a?.gang ? gangColor(t, m.a.gang) : '#555c5e'}"></i>{slotText(t, m.a).text}</span>
              <span class="ml-sc mono c">
                {#if m.status === 'LIVE'}{scoreOf(m, 0)} – {scoreOf(m, 1)}
                {:else if m.status === 'COMPLETE'}{m.walkover ? 'W/O' : `${m.scoreA} – ${m.scoreB}`}
                {:else}vs{/if}
              </span>
              <span class="ml-b" class:win={isWinner(m, 1)}><i class="swatch" style="background:{m.b?.gang ? gangColor(t, m.b.gang) : '#555c5e'}"></i>{slotText(t, m.b).text}</span>
              <span class="ml-st r st-{matchStatusWord(m).toLowerCase()}">{matchStatusWord(m)}</span>
            </button>
          {/each}
        </div>
      {/if}
    {/if}

    <!-- Standings: group tables + their fixtures -->
    {#if mode === 'GROUP'}
      {#if !(t.groups || []).length}
        <div class="empty flat">The draw has not been made yet.</div>
      {:else}
        <div class="groups">
          {#each t.groups as g, gi (g.name)}
            <section class="group">
              <div class="g-head"><span>GROUP {g.name}</span><span class="g-sub">TOP {t.cfg.advance} QUALIFY</span></div>
              <table>
                <thead><tr><th class="c-rank">#</th><th class="c-name">Team</th><th>P</th><th>W</th><th>D</th><th>L</th><th>K</th><th>+/−</th><th class="c-pts">PTS</th></tr></thead>
                <tbody>
                  {#each g.standings as r (r.gang)}
                    {@const qs = qualStatus(g, r)}
                    <tr class:me={r.gang === myGang} class:cut={r.rank === t.cfg.advance} class:out={qs === 'ELIMINATED'}>
                      <td class="c-rank">{r.rank}</td>
                      <td class="c-name"><i class="swatch" style="background:{gangColor(t, r.gang)}"></i>{label(r.gang)}{#if qs}<em class="q q-{qs.toLowerCase()}">{qs}</em>{/if}</td>
                      <td>{r.played}</td><td>{r.won}</td><td>{r.drawn}</td><td>{r.lost}</td>
                      <td>{r.kf}</td><td>{r.diff > 0 ? '+' : ''}{r.diff}</td>
                      <td class="c-pts">{r.points}</td>
                    </tr>
                  {/each}
                </tbody>
              </table>
              <div class="fixtures">
                {#each groupMatches(gi) as m (m.id)}
                  <button type="button" class="fx" class:live={m.status === 'LIVE'} class:done={m.status === 'COMPLETE'}
                    class:clickable={selectable && m.status === 'READY'} class:mine={m.a.gang === myGang || m.b.gang === myGang}
                    on:click={() => clickMatch(m)}>
                    <span class="fx-md">MD{m.round}</span>
                    <span class="fx-a" class:win={isWinner(m, 0)}>{label(m.a.gang)}</span>
                    <span class="fx-sc mono">
                      {#if m.status === 'LIVE'}{scoreOf(m, 0)} – {scoreOf(m, 1)}
                      {:else if m.status === 'COMPLETE'}{m.walkover ? 'W/O' : `${m.scoreA} – ${m.scoreB}`}
                      {:else}vs{/if}
                    </span>
                    <span class="fx-b" class:win={isWinner(m, 1)}>{label(m.b.gang)}</span>
                    <span class="fx-st st-{matchStatusWord(m).toLowerCase()}">{matchStatusWord(m)}</span>
                  </button>
                {/each}
              </div>
            </section>
          {/each}
        </div>
      {/if}
    {/if}
  </div>
</div>
{/if}

<style>
  /* Flat, sharp and quiet on purpose — no glow, no gradients. The tree is the
     point; everything else just frames it. */
  .tt {
    --tt-mine: #22d3ee;
    --tt-line: rgba(255, 255, 255, 0.16);
    display: flex;
    flex-direction: column;
    gap: 14px;
    color: var(--text-main);
  }
  .mono { font-family: var(--font-mono); }
  .empty {
    padding: 36px 16px;
    text-align: center;
    color: var(--text-dim);
    border: 1px dashed var(--tablet-border-strong);
    border-radius: var(--radius-md);
    font-size: var(--fs-body);
  }

  /* Header */
  .tt-head {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-md);
    padding: 14px 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .tt-title-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; color: var(--accent-primary); }
  .tt-title-row h2 {
    margin: 0;
    font-size: var(--fs-title);
    letter-spacing: 0.01em;
    color: var(--text-main);
  }
  .edition, .when { font-size: var(--fs-small); color: var(--text-dim); font-family: var(--font-mono); letter-spacing: 0.01em; }
  .when { margin-left: auto; }
  .pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    border: 1px solid var(--tablet-border-strong);
    color: var(--text-dim);
  }
  .pill .dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; animation: blink 1.4s infinite; }
  .tone-live { color: var(--accent-primary); border-color: var(--accent-primary); background: var(--c-hover); }
  .tone-done { color: var(--green); border-color: rgba(112, 185, 130, 0.4); }
  .tone-reg { color: var(--tt-mine); border-color: rgba(34, 211, 238, 0.45); }
  .tone-cancel { color: var(--red); border-color: rgba(217, 115, 111, 0.4); }
  @keyframes blink { 50% { opacity: 0.25; } }

  .tt-stats { display: grid; grid-template-columns: 1fr 2fr 1fr 1fr; gap: 10px; }
  .stat {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 9px 12px;
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }
  .stat .k { font-size: var(--fs-meta); letter-spacing: 0.01em; color: var(--text-muted); }
  .stat .v { font-size: var(--fs-body); font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  /* Stage indicator */
  .stage-bar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .stage {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border-radius: var(--r-ctl);
    border: 1px solid var(--tablet-border);
    background: var(--tablet-panel);
    color: var(--text-muted);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
  }
  .stage .n {
    width: 18px; height: 18px; border-radius: 50%;
    display: inline-flex; align-items: center; justify-content: center;
    font-size: var(--fs-meta); border: 1px solid currentColor;
  }
  .stage.done { color: var(--green); }
  .stage.current { color: var(--on-accent, #ffffff);
    text-shadow: none; background: var(--accent-primary); border-color: var(--accent-primary); }
  .sep { width: 18px; height: 1px; background: var(--tt-line); }

  /* Live / next feature */
  .feature {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-md);
    padding: 10px 18px;
  }
  .feature.live { border-color: rgba(var(--accent-primary-rgb), 0.55); }
  .f-label { font-size: var(--fs-small); letter-spacing: 0.01em; color: var(--text-muted); margin-bottom: 10px; }
  .f-board { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; gap: 18px; }
  .f-team { display: flex; align-items: baseline; gap: 16px; min-width: 0; }
  .f-team.right { justify-content: flex-end; }
  .f-team .nm { font-size: var(--fs-title); font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .f-team .sc { font-size: 30px; font-weight: 700; color: var(--accent-primary);
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .f-team.me .nm { color: var(--tt-mine); }
  .f-mid { display: flex; flex-direction: column; align-items: center; gap: 6px; }
  .vs { font-size: var(--fs-small); letter-spacing: 0.01em; color: var(--text-muted); }
  .rem { font-size: var(--fs-small); color: var(--text-dim); letter-spacing: 0.01em; }
  .warn { margin-top: 10px; font-size: var(--fs-small); color: var(--tablet-warn); display: flex; align-items: center; gap: 6px; }

  .champion {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px 18px;
    border-radius: var(--radius-md);
    border: 1px solid var(--accent-primary);
    background: var(--c-hover);
    color: var(--accent-primary);
  }
  .c-k { font-size: var(--fs-small); letter-spacing: 0.01em; }
  .c-v { font-size: var(--fs-section); font-weight: 700; color: var(--text-main);
    font-family: var(--font-display); font-stretch: var(--stretch-display); }

  /* My gang */
  .mine-panel {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    padding: 12px 14px;
    border: 1px solid var(--c-line);
    border-radius: var(--radius-md);
    background: var(--c-raised);
    border-left: 3px solid rgb(34, 211, 238);}
  .m-cell { display: flex; flex-direction: column; gap: 2px; min-width: 120px; }
  .m-cell .k { font-size: var(--fs-meta); letter-spacing: 0.01em; color: var(--text-muted); }
  .m-cell .v { font-size: var(--fs-body); font-weight: 700; }
  .st-live { color: var(--accent-primary); }
  .st-qualified, .st-champion, .st-completed, .st-winner { color: var(--green); }
  .st-eliminated { color: var(--red); }
  .st-upcoming { color: var(--text-dim); }

  /* Groups */
  .groups { display: grid; grid-template-columns: repeat(auto-fit, minmax(430px, 1fr)); gap: 14px; }
  .group { background: var(--tablet-panel); border: 1px solid var(--tablet-border-strong); border-radius: var(--radius-md); overflow: hidden; }
  .g-head {
    display: flex; justify-content: space-between; align-items: center;
    padding: 10px 14px;
    background: var(--bg-card-raised);
    border-bottom: 1px solid var(--tablet-border);
    font-weight: 700; letter-spacing: 0.01em; font-size: var(--fs-body);
  }
  .g-sub { font-size: var(--fs-meta); color: var(--text-muted); font-weight: 600; }
  table { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  th { font-size: var(--fs-meta); letter-spacing: 0; color: var(--text-muted); text-align: center; padding: 7px 5px; font-weight: 600;
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }
  td { text-align: center; padding: 8px 5px; font-variant-numeric: tabular-nums; }
  .c-name {
    text-align: left !important;
  }
  td.c-name {
    font-weight: 600;
  }
  .c-rank {
    width: 26px;
  }
  td.c-rank {
    color: var(--text-muted);
  }
  .c-pts {
    width: 42px;
  }
  td.c-pts {
    font-weight: 500;
    color: var(--accent-primary);
  }
  th.c-name { padding-left: 8px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0;
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }
  tr.cut td { border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }
  tr.out { opacity: 0.55; }
  tr.me td { background: rgba(34, 211, 238, 0.08);
    font-variant-numeric: tabular-nums;
  }
  tr.me .c-name { color: var(--tt-mine); }
  em.q { font-style: normal; margin-left: 8px; font-size: var(--fs-meta); letter-spacing: 0.01em; padding: 1px 5px; border-radius: var(--r-panel); border: 1px solid; }
  .q-qualified { color: var(--green); }
  .q-eliminated { color: var(--red); }

  .fixtures { border-top: 1px solid var(--tablet-border-strong); }
  .fx {
    display: grid;
    grid-template-columns: 38px 1fr 64px 1fr 82px;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 12px;
    background: transparent;
    border: 0;
    border-top: 1px solid var(--tablet-border);
    color: var(--text-dim);
    font-size: var(--fs-small);
    text-align: left;
    cursor: default;
  }
  .fx:first-child { border-top: 0; }
  .fx.clickable { cursor: pointer; }
  .fx.clickable:hover { background: var(--bg-card-hover); }
  .fx.mine { background: rgba(34, 211, 238, 0.06); }
  .fx.live { background: var(--c-hover); }
  .fx-md { font-size: var(--fs-meta); color: var(--text-muted); font-family: var(--font-mono); }
  .fx-a { text-align: right; font-weight: 600; }
  .fx-b { font-weight: 600; }
  .fx .win { color: var(--lt-ffffff, #fff); font-weight: 700; }
  .fx-sc { text-align: center; color: var(--text-main); }
  .fx-st { font-size: var(--fs-meta); letter-spacing: 0.01em; text-align: right; font-weight: 700; }

  /* Tree shell — toolbar + canvas, after the EventHub tournament-tree mock-up,
     kept to the tablet's flat charcoal/gold look (no glow, no gradients). */
  .shell {
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-md);
    overflow: hidden;
    background: var(--tablet-bg);
  }
  .toolbar {
    height: 50px;
    padding: 0 12px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--bg-card-raised);
    border-bottom: 1px solid var(--tablet-border);
  }
  .tabs, .tools { display: flex; gap: 4px; }
  .tool-right { display: flex; align-items: center; gap: 14px; }
  .tabs button {
    height: 32px;
    padding: 0 16px;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    background: transparent;
    color: var(--text-muted);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    cursor: pointer;
  }
  .tabs button:hover { color: var(--text-main); }
  .tabs button.active {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .tools button {
    min-width: 32px;
    height: 32px;
    padding: 0 8px;
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--r-ctl);
    background: var(--tablet-panel-alt);
    color: var(--text-dim);
    font-size: var(--fs-body);
    font-weight: 700;
    cursor: pointer;
  }
  .tools button:hover { color: var(--text-main); border-color: var(--tablet-border-hover); }
  .tools .zoom-label { min-width: 56px; font-size: var(--fs-small); font-family: var(--font-mono); }
  .empty.flat { border: 0; border-radius: 0; }

  /* Bracket canvas: faint blueprint grid so the tree reads as a board. */
  .ko-note {
    padding: 9px 14px;
    font-size: var(--fs-small);
    color: var(--text-muted);
    border-bottom: 1px solid var(--tablet-border);
  }
  .viewport {
    overflow: auto;
    max-height: 640px;
    background-color: var(--tablet-bg);
    background-image:
      linear-gradient(rgba(255, 255, 255, 0.016) 1px, transparent 1px),
      linear-gradient(90deg, rgba(255, 255, 255, 0.016) 1px, transparent 1px);
    background-size: 28px 28px;
  }
  .canvas { position: relative; padding: 58px 20px 24px; box-sizing: content-box; }
  .bracket { position: relative; transform-origin: top left; }
  .bracket svg { position: absolute; left: 0; top: 0; pointer-events: none; }
  .bracket svg path { fill: none; stroke: #414749; stroke-width: 1.5; }
  .bracket svg path.gold { stroke: var(--accent-primary-dim); }
  .bracket svg path.route { stroke: var(--tt-mine); stroke-width: 2; }

  .round-name {
    position: absolute;
    top: -46px;
    height: 34px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 12px;
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--r-ctl);
    background: var(--bg-card-raised);
    color: var(--text-main);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
  }
  .round-name small { color: var(--text-muted); font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; }
  .round-name.current { border-color: rgba(var(--accent-primary-rgb), 0.6); color: var(--accent-primary-light); background: var(--es-raised, #1a1711); }

  .mc {
    position: absolute;
    display: flex;
    flex-direction: column;
    padding: 0;
    text-align: left;
    background: var(--es-inset, #0f1113);
    border: 1px solid #30353c;
    border-radius: var(--r-ctl);
    overflow: hidden;
    color: var(--text-main);
    cursor: default;
  }
  .mc.clickable { cursor: pointer; }
  .mc.clickable:hover { border-color: var(--accent-primary); }
  .mc.live { border-color: var(--green); }
  .mc.route { border-color: var(--tt-mine); }
  .mc.dim { opacity: 0.45; }
  .mc-top {
    display: flex; justify-content: space-between; align-items: center;
    padding: 0 10px; height: 20px;
    font-size: var(--fs-meta); letter-spacing: 0.01em; font-weight: 700; color: var(--text-muted);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.025);
    border-bottom: 1px solid var(--es-line, #22262c);
  }
  .mc-top .st { font-size: var(--fs-meta); }
  .st-live { color: var(--green); }
  .mc-row {
    position: relative;
    display: flex; justify-content: space-between; align-items: center; gap: 8px;
    padding: 0 10px 0 13px; height: 22px;
    font-size: var(--fs-small); font-weight: 700;
    border-bottom: 1px solid var(--es-line, #22262c);
    background: var(--es-inset, #131518);
  }
  .mc-row::before {
    content: '';
    position: absolute; left: 0; top: 0; bottom: 0; width: 3px;
    background: var(--gc, #555c5e);
  }
  .mc-row .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .mc-row .nm em { font-style: normal; margin-left: 6px; font-size: var(--fs-meta); letter-spacing: 0.01em; color: var(--red); }
  .mc-row .sc { font-weight: 700; color: var(--text-muted); }
  .mc-row.tbd { color: var(--text-muted); font-weight: 700; }
  .mc-row.win { background: var(--c-hover); }
  .mc-row.win .sc { color: var(--accent-primary-light); }
  .mc-row.lose { color: var(--text-muted); }
  .mc-row.me { color: var(--tt-mine); }
  .mc.live .mc-row .sc { color: var(--green); }
  .mc-foot {
    margin-top: auto;
    height: 20px; display: flex; align-items: center;
    padding: 0 10px;
    font-size: var(--fs-meta); letter-spacing: 0.01em; font-weight: 700; color: var(--accent-primary-light);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .champ-card {
    position: absolute;
    display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px;
    border: 1px dashed var(--tablet-border-strong);
    border-radius: var(--r-ctl);
    color: var(--text-muted);
  }
  .champ-card.won { border: 1px solid var(--accent-primary); background: var(--c-hover); color: var(--accent-primary-light); }
  .cc-k { font-size: var(--fs-meta); letter-spacing: 0.01em; font-weight: 700; }
  .cc-v { font-size: var(--fs-emph); font-weight: 700; color: var(--text-main); }
  .cc-v.me { color: var(--tt-mine); }

  /* Legend */
  .legend {
    display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px 24px;
    padding: 11px 14px;
    border-top: 1px solid var(--tablet-border);
    background: var(--bg-card-raised);
  }
  .legend-block { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
  .legend-title { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-muted); }
  .legend-item { display: inline-flex; align-items: center; gap: 6px; font-size: var(--fs-small); color: var(--text-dim); font-weight: 600; }
  .swatch { display: inline-block; width: 9px; height: 9px; border-radius: 2px; background: #555c5e; flex-shrink: 0; }
  .swatch.win { background: var(--accent-primary-light);
    color: var(--on-accent, inherit);
}
  .swatch.live { background: var(--green); border-radius: 50%; }
  .swatch.tbd { background: #555c5e; }
  .c-name .swatch { margin-right: 8px; vertical-align: middle; }

  /* Matches list */
  .match-list { display: flex; flex-direction: column; }
  .ml-head, .ml-row {
    display: grid;
    grid-template-columns: 64px 1.2fr 1.4fr 90px 1.4fr 110px;
    align-items: center;
    gap: 12px;
    padding: 0 16px;
    text-align: left;
  }
  .ml-head {
    height: 38px;
    background: var(--bg-card-raised);
    border-bottom: 1px solid var(--tablet-border);
    font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-muted);
  }
  .ml-row {
    width: 100%;
    min-height: 46px;
    background: transparent;
    border: 0;
    border-top: 1px solid var(--tablet-border);
    color: var(--text-dim);
    font-size: var(--fs-body);
    cursor: default;
  }
  .ml-head + .ml-row { border-top: 0; }
  .ml-row.clickable { cursor: pointer; }
  .ml-row.clickable:hover { background: var(--bg-card-hover); }
  .ml-row.live { background: rgba(98, 168, 121, 0.07); }
  .ml-row .r, .ml-head .r { text-align: right; }
  .ml-row .c, .ml-head .c { text-align: center; }
  .ml-a, .ml-b { font-weight: 700; display: flex; align-items: center; gap: 8px; }
  .ml-a { justify-content: flex-end; }
  .ml-a.win, .ml-b.win { color: var(--lt-ffffff, #fff); }
  .ml-sc { color: var(--text-main); font-weight: 700; }
  .ml-n { color: var(--text-muted); font-size: var(--fs-meta); }
  .ml-stage { font-size: var(--fs-small); }
  .ml-st { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; }
</style>
