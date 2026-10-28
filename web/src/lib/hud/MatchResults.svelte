<script>
  import { matchResultsOpen, matchResultsData } from '../stores.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import { fetchNui } from '../api/nui.js';
  import '../tablet/tablet-theme.css';

  let activeTab = 'players';

  $: data = $matchResultsData;
  $: isPractice = data.mode === 'practice';

  function kd(k, d) {
    return d > 0 ? (k / d).toFixed(2) : (k || 0).toFixed(2);
  }

  $: rankedPlayers = [...(data.players || [])].sort((a, b) => {
    if ((b.points || 0) !== (a.points || 0)) return (b.points || 0) - (a.points || 0);
    if ((b.kills || 0) !== (a.kills || 0)) return (b.kills || 0) - (a.kills || 0);
    return (a.deaths || 0) - (b.deaths || 0);
  });
  $: top = rankedPlayers[0] || null;
  $: totalKills = (data.players || []).reduce((n, p) => n + (p.kills || 0), 0);
  $: bestKd = [...(data.players || [])].sort((a, b) => {
    const ra = a.deaths ? a.kills / a.deaths : a.kills;
    const rb = b.deaths ? b.kills / b.deaths : b.kills;
    return rb - ra;
  })[0] || null;
  $: mostKills = [...(data.players || [])].sort((a, b) => (b.kills || 0) - (a.kills || 0))[0] || null;

  // Victory / Defeat splash (TDM only): shown first, then the results panel.
  let splashOn = false;
  let wasOpen = false;
  let splashTimer = null;
  function skipSplash() {
    splashOn = false;
    clearTimeout(splashTimer);
  }
  $: if ($matchResultsOpen && !wasOpen) {
    wasOpen = true;
    activeTab = 'players';
    if (data.outcome && !data.outcome.noSplash) {
      splashOn = true;
      clearTimeout(splashTimer);
      splashTimer = setTimeout(() => (splashOn = false), 7000);
    }
  } else if (!$matchResultsOpen && wasOpen) {
    wasOpen = false;
    splashOn = false;
    clearTimeout(splashTimer);
  }
  const PIPS = 10;
  function filled(score, target) {
    return Math.round(Math.min(1, (score || 0) / Math.max(1, target || 1)) * PIPS);
  }
  const WORD = { victory: 'VICTORY', defeat: 'DEFEAT', draw: 'DRAW' };

  function close() {
    matchResultsOpen.set(false);
    fetchNui('matchResults:close'); // releases NUI focus on the Lua side
  }

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); if (splashOn) skipSplash(); else close(); }
  }
</script>

<svelte:window on:keydown={$matchResultsOpen ? onKey : undefined} />

{#if $matchResultsOpen && splashOn && data.outcome}
  {@const o = data.outcome}
  {@const mineA = o.myTeam !== 'B'}
  {@const me = mineA ? { label: o.labelA, score: o.scoreA, mvp: o.mvpA } : { label: o.labelB, score: o.scoreB, mvp: o.mvpB }}
  {@const foe = mineA ? { label: o.labelB, score: o.scoreB, mvp: o.mvpB } : { label: o.labelA, score: o.scoreA, mvp: o.mvpA }}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="splash {o.result}" on:click={skipSplash}>
    <div class="band">
      <div class="word">{WORD[o.result] || 'MATCH OVER'}</div>
      <div class="reason">» {o.reasonText} «</div>
    </div>

    <div class="versus">
      <div class="vside mine">
        <div class="vlabel">{me.label}</div>
        <div class="vrow">
          <div class="pips">{#each Array(PIPS) as _, i}<i class:on={i < filled(me.score, o.target)} style="animation-delay:{0.7 + i * 0.06}s"></i>{/each}</div>
          <div class="vscore">{me.score}</div>
        </div>
      </div>
      <div class="vs">VS</div>
      <div class="vside foe">
        <div class="vlabel">{foe.label}</div>
        <div class="vrow">
          <div class="vscore">{foe.score}</div>
          <div class="pips">{#each Array(PIPS) as _, i}<i class:on={i < filled(foe.score, o.target)} style="animation-delay:{0.7 + i * 0.06}s"></i>{/each}</div>
        </div>
      </div>
    </div>

    <div class="mvps">
      {#if me.mvp}
        <div class="chip mine"><span class="chip-tag">Your MVP</span><span class="chip-name">{me.mvp.name}</span><span class="chip-stat">{me.mvp.kills} K · {me.mvp.deaths} D</span></div>
      {/if}
      {#if foe.mvp}
        <div class="chip foe"><span class="chip-tag">Enemy MVP</span><span class="chip-name">{foe.mvp.name}</span><span class="chip-stat">{foe.mvp.kills} K · {foe.mvp.deaths} D</span></div>
      {/if}
    </div>

    <div class="splash-hint"><b>ESC</b> Continue to results</div>
  </div>
{/if}

{#if $matchResultsOpen && !splashOn}
  <div class="overlay">
    <div class="panel" role="dialog" aria-label={isPractice ? 'Practice results' : 'Match results'}>
      <header class="header">
        <span class="mark"><Icon name={isPractice ? 'crosshair' : 'flag'} size={20} /></span>
        <div class="heading">
          <h1>{data.eventName || (isPractice ? 'Practice range' : 'TDM match')}</h1>
          <p>{isPractice ? 'Practice session complete' : 'Match complete'} · {(data.players || []).length} player{(data.players || []).length === 1 ? '' : 's'}{data.duration ? ' · ' + data.duration : ''}</p>
        </div>
        {#if !isPractice}
          <div class="score-block">
            <div class="score">{data.scoreA ?? 0} – {data.scoreB ?? 0}</div>
            <div class="score-caption">Final team score</div>
          </div>
        {/if}
        <span class="saved"><Icon name="checkCircle" size={15} /> Results saved</span>
      </header>

      {#if top}
        <section class="top-card">
          <span class="crown"><Icon name="trophy" size={24} /></span>
          <div class="top-main">
            <span class="top-tag">{isPractice ? 'Top score' : 'MVP'}</span>
            <strong class="top-name">{top.name}</strong>
            {#if top.team}<span class="top-sub">{top.team}</span>{/if}
          </div>
          <div class="top-stats">
            <div class="stat"><span class="stat-value">{top.kills || 0}</span><span class="stat-label">Kills</span></div>
            <div class="stat"><span class="stat-value">{top.deaths || 0}</span><span class="stat-label">Deaths</span></div>
            <div class="stat"><span class="stat-value gold">{(top.points || 0).toLocaleString()}</span><span class="stat-label">Points</span></div>
          </div>
        </section>
      {/if}

      <div class="tabs" role="tablist">
        <button type="button" role="tab" aria-selected={activeTab === 'players'} class="tab" class:active={activeTab === 'players'} on:click={() => (activeTab = 'players')}>Players</button>
        <button type="button" role="tab" aria-selected={activeTab === 'summary'} class="tab" class:active={activeTab === 'summary'} on:click={() => (activeTab = 'summary')}>Summary</button>
      </div>

      {#if activeTab === 'players'}
        <div class="table-wrap">
          <div class="table-head">
            <span>Rank</span><span>Player</span><span class="hc">Kills</span><span class="hc">Deaths</span><span class="hc">K/D</span><span class="r">Points</span>
          </div>
          <div class="table-body">
            {#each rankedPlayers as p, i (p.name + i)}
              <div class="row" class:you={p.you}>
                <span class="pos"><i class="rank r{i < 3 ? i + 1 : 0}">{i + 1}</i></span>
                <span class="name-cell">
                  <span class="name">{p.name}{#if p.you}<span class="badge you">You</span>{/if}</span>
                  {#if p.team}<span class="team">{p.team}</span>{/if}
                </span>
                <span class="c kills">{p.kills || 0}</span>
                <span class="c deaths">{p.deaths || 0}</span>
                <span class="c">{kd(p.kills || 0, p.deaths || 0)}</span>
                <span class="r points">{(p.points || 0).toLocaleString()}</span>
              </div>
            {/each}
          </div>
        </div>
      {:else}
        <div class="summary-grid">
          <div class="summary-card">
            <span class="summary-label">Total eliminations</span>
            <span class="summary-value">{totalKills}</span>
            <span class="summary-sub">Across all players</span>
          </div>
          <div class="summary-card">
            <span class="summary-label">Duration</span>
            <span class="summary-value">{data.duration || '—'}</span>
            <span class="summary-sub">Time played</span>
          </div>
          <div class="summary-card">
            <span class="summary-label">Best K/D</span>
            <span class="summary-value">{bestKd ? kd(bestKd.kills || 0, bestKd.deaths || 0) : '0.00'}</span>
            <span class="summary-sub">{bestKd?.name || '—'}</span>
          </div>
        </div>
        <div class="awards">
          <div class="award">
            <span class="award-ico"><Icon name="crosshair" size={18} /></span>
            <div><span class="award-title">Most eliminations</span><strong class="award-name">{mostKills?.name || '—'}</strong><span class="award-sub">{mostKills ? `${mostKills.kills || 0} kills` : '—'}</span></div>
          </div>
          <div class="award">
            <span class="award-ico"><Icon name="shield" size={18} /></span>
            <div><span class="award-title">Best survival</span><strong class="award-name">{bestKd?.name || '—'}</strong><span class="award-sub">{bestKd ? `${kd(bestKd.kills || 0, bestKd.deaths || 0)} K/D` : '—'}</span></div>
          </div>
        </div>
      {/if}

      <footer class="footer">
        <span class="footer-text">{isPractice ? 'Practice results are personal and not added to any leaderboard.' : 'Recorded to the TDM leaderboard.'}</span>
        <button type="button" class="btn btn-primary close-btn" on:click={close}><kbd>Esc</kbd> Close</button>
      </footer>
    </div>
  </div>
{/if}

<style>
  /* This screen is read at a glance right after leaving the range. #app is pointer-events:none, so the overlay opts back in. */
  .overlay {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.62);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 6000;
    pointer-events: all;
    font-family: var(--font-ui);
    font-variant-numeric: tabular-nums;
  }
  h1, p { margin: 0; }
  button { font-family: inherit; cursor: pointer; }
  button:focus-visible { outline: 2px solid #7bb6f2; outline-offset: 2px; }

  .panel {
    width: 860px;
    max-width: 95vw;
    max-height: 92vh;
    display: flex;
    flex-direction: column;
    gap: 18px;
    padding: 24px 28px;
    color: var(--c-text, #eceef0);
    background-color: #07090d;
    background-image: radial-gradient(ellipse 95% 65% at 50% 15%, rgba(65, 86, 111, 0.42) 0%, rgba(18, 25, 36, 0.76) 52%, rgba(6, 8, 12, 0.96) 100%);
    border: 1px solid rgba(130, 165, 210, 0.34);
    border-radius: 16px;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.65);
    animation: pop 0.2s ease-out both;
    overflow-y: auto;
  }
  @keyframes pop { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
  @media (prefers-reduced-motion: reduce) { .panel { animation: none; } }

  /* header */
  .header { display: flex; align-items: center; gap: 14px; padding-bottom: 16px; border-bottom: 1px solid rgba(110, 140, 180, 0.22); }
  .mark {
    flex: none; width: 46px; height: 46px; display: grid; place-items: center; border-radius: 11px;
    color: #7bb6f2; background: rgba(79, 148, 230, 0.16); border: 1px solid rgba(79, 148, 230, 0.4);
  }
  .heading { min-width: 0; }
  .heading h1 { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 30px; font-weight: 700; line-height: 1.05; }
  .heading p { margin-top: 4px; font-size: 14.5px; color: var(--c-text-3, #8d949c); }
  .score-block { margin-left: auto; text-align: center; }
  .score { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 40px; font-weight: 700; line-height: 1; }
  .score-caption { margin-top: 4px; font-size: 13px; color: var(--c-text-3, #8d949c); }
  .saved {
    margin-left: auto; display: inline-flex; align-items: center; gap: 7px; height: 32px; padding: 0 13px; border-radius: 16px;
    font-size: 14px; font-weight: 600; color: #46c98b; background: rgba(70, 201, 139, 0.12); border: 1px solid rgba(70, 201, 139, 0.4);
  }
  .score-block + .saved { margin-left: 0; }

  /* top player */
  .top-card {
    display: flex; align-items: center; gap: 18px; padding: 16px 20px; border-radius: 14px;
    background: linear-gradient(90deg, rgba(242, 195, 91, 0.14), rgba(16, 21, 30, 0.8) 55%);
    border: 1px solid rgba(242, 195, 91, 0.38);
  }
  .crown {
    flex: none; width: 52px; height: 52px; display: grid; place-items: center; border-radius: 12px;
    color: #f2c35b; background: rgba(242, 195, 91, 0.14); border: 1px solid rgba(242, 195, 91, 0.45);
  }
  .top-main { min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .top-tag { font-size: 14px; font-weight: 600; color: #f2c35b; }
  .top-name { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 26px; font-weight: 700; line-height: 1.1; color: #fff; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .top-sub { font-size: 14px; color: var(--c-text-3, #8d949c); }
  .top-stats { margin-left: auto; display: flex; gap: 30px; }
  .stat { text-align: center; }
  .stat-value { display: block; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 32px; font-weight: 700; line-height: 1; color: #fff; }
  .stat-value.gold { color: #f2c35b; }
  .stat-label { display: block; margin-top: 5px; font-size: 13.5px; color: var(--c-text-3, #8d949c); }

  /* tabs */
  .tabs { display: inline-flex; align-self: flex-start; gap: 4px; padding: 4px; border-radius: 11px; background: rgba(0, 0, 0, 0.32); border: 1px solid rgba(110, 140, 180, 0.22); }
  .tab { height: 34px; padding: 0 20px; border-radius: 8px; border: 0; background: transparent; font-size: 15px; font-weight: 600; color: var(--c-text-3, #8d949c); transition: background 0.15s, color 0.15s; }
  .tab:hover { color: #fff; }
  .tab.active { color: #fff; background: rgba(79, 148, 230, 0.28); }

  /* players: rows scroll inside the panel so the header and Close stay visible */
  .table-wrap { border: 1px solid rgba(110, 140, 180, 0.22); border-radius: 12px; overflow: hidden; }
  .table-body { max-height: 300px; overflow-y: auto; scrollbar-width: thin; scrollbar-color: rgba(130, 165, 210, 0.3) transparent; }
  .table-head, .row { display: grid; grid-template-columns: 64px 1fr 90px 90px 90px 110px; align-items: center; gap: 10px; padding: 0 18px; }
  .table-head { height: 40px; background: rgba(0, 0, 0, 0.3); font-size: 14px; font-weight: 600; color: var(--c-text-3, #8d949c); }
  .row { min-height: 58px; background: rgba(16, 21, 30, 0.62); border-top: 1px solid rgba(110, 140, 180, 0.16); }
  .row.you { background: linear-gradient(90deg, rgba(79, 148, 230, 0.2), rgba(16, 21, 30, 0.7)); box-shadow: inset 3px 0 0 #4f94e6; }
  .rank { display: inline-grid; place-items: center; width: 30px; height: 30px; border-radius: 50%; font-style: normal; font-size: 15px; font-weight: 700; color: var(--c-text-2, #c9ced4); background: rgba(255, 255, 255, 0.07); }
  .rank.r1 { color: #2a1e00; background: #f2c35b; }
  .rank.r2 { color: #1b1f24; background: #c4cbd3; }
  .rank.r3 { color: #2a1708; background: #d08a52; }
  .name-cell { display: flex; flex-direction: column; min-width: 0; }
  .name { font-size: 17px; font-weight: 600; color: #fff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .team { font-size: 13.5px; color: var(--c-text-3, #8d949c); }
  .c { text-align: center; font-size: 18px; font-weight: 600; }
  .hc { text-align: center; }
  .r { text-align: right; }
  .kills { color: #46c98b; }
  .deaths { color: #ff6b5e; }
  .points { font-size: 18px; font-weight: 700; color: #fff; }
  .badge { display: inline-block; margin-left: 10px; vertical-align: middle; font-size: 12.5px; font-weight: 600; padding: 1px 8px; border-radius: 6px; }
  .badge.you { color: #7bb6f2; background: rgba(79, 148, 230, 0.16); border: 1px solid rgba(79, 148, 230, 0.4); }

  /* summary */
  .summary-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  .summary-card { display: flex; flex-direction: column; gap: 6px; padding: 18px 20px; border-radius: 12px; background: rgba(16, 21, 30, 0.72); border: 1px solid rgba(110, 140, 180, 0.22); }
  .summary-label { font-size: 14.5px; color: var(--c-text-3, #8d949c); }
  .summary-value { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 32px; font-weight: 700; line-height: 1.05; color: #fff; }
  .summary-sub { font-size: 14px; color: var(--c-text-2, #c9ced4); }
  .awards { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .award { display: flex; align-items: center; gap: 14px; padding: 16px 18px; border-radius: 12px; background: rgba(16, 21, 30, 0.72); border: 1px solid rgba(110, 140, 180, 0.22); }
  .award > div { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .award-ico { flex: none; width: 40px; height: 40px; display: grid; place-items: center; border-radius: 10px; color: #f2c35b; background: rgba(242, 195, 91, 0.14); border: 1px solid rgba(242, 195, 91, 0.4); }
  .award-title { font-size: 14px; color: #f2c35b; }
  .award-name { font-size: 18px; font-weight: 600; color: #fff; }
  .award-sub { font-size: 14px; color: var(--c-text-3, #8d949c); }

  /* footer */
  .footer { display: flex; justify-content: space-between; align-items: center; gap: 16px; padding-top: 16px; border-top: 1px solid rgba(110, 140, 180, 0.22); }
  .footer-text { font-size: 14px; color: var(--c-text-3, #8d949c); }
  .close-btn { display: inline-flex; align-items: center; gap: 10px; min-height: 42px; padding: 0 20px; font-size: 15px; }
  kbd { font: 600 12px var(--font-ui); padding: 2px 7px; border-radius: 5px; color: #fff; border: 1px solid rgba(255, 255, 255, 0.5); background: rgba(255, 255, 255, 0.12); }

  /* ── Victory / Defeat splash ───────────────────────────────────────────── */
  .splash {
    --acc: #4f94e6;
    --acc-light: #5ba5ef;
    position: absolute;
    inset: 0;
    z-index: 6100;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 26px;
    background: radial-gradient(ellipse at center, rgba(8, 8, 10, 0.55), rgba(0, 0, 0, 0.88));
    pointer-events: all;
    cursor: pointer;
    animation: splashIn 0.35s ease-out both;
  }
  .splash.defeat { --acc: #ff5d50; --acc-light: #ff857c; }
  .splash.draw { --acc: #8fb4d9; --acc-light: #c4daf0; }
  @keyframes splashIn { from { opacity: 0; } to { opacity: 1; } }

  .band {
    position: relative;
    width: 100%;
    padding: 26px 0 22px;
    text-align: center;
    overflow: hidden;
    background: linear-gradient(180deg, rgba(20, 20, 22, 0.94), rgba(10, 10, 12, 0.94));
    border-top: 3px solid var(--acc);
    border-bottom: 3px solid var(--acc);
    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4);
    animation: bandIn 0.55s cubic-bezier(0.2, 0.9, 0.2, 1) both;
  }
  .band::after {
    content: '';
    position: absolute;
    top: 0;
    left: -30%;
    width: 25%;
    height: 100%;
    background: linear-gradient(100deg, transparent, rgba(255, 255, 255, 0.22), transparent);
    transform: skewX(-20deg);
    animation: bandSweep 1.3s ease-out 0.5s both;
  }
  @keyframes bandIn { from { transform: scaleY(0.2); opacity: 0; } to { transform: scaleY(1); opacity: 1; } }
  @keyframes bandSweep { from { left: -30%; } to { left: 125%; } }
  .word {
    font-size: 104px;
    line-height: 1;
    font-weight: 900;
    font-style: italic;
    color: var(--acc-light);
    text-shadow: 0 0 34px var(--acc), 0 4px 0 rgba(0, 0, 0, 0.6);
    animation: wordIn 0.8s cubic-bezier(0.2, 1.1, 0.3, 1) 0.15s both;
  }
  @keyframes wordIn {
    from { letter-spacing: 46px; opacity: 0; transform: scale(1.25); }
    to { letter-spacing: 18px; opacity: 1; transform: scale(1); }
  }
  .reason {
    margin-top: 10px;
    font-size: 16px;
    font-weight: 800;
    letter-spacing: 4px;
    color: var(--tablet-text-soft, #b4bac0);
    animation: fadeUp 0.5s ease-out 0.7s both;
  }
  @keyframes fadeUp { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }

  .versus {
    display: flex;
    align-items: center;
    gap: 30px;
    animation: fadeUp 0.5s ease-out 0.55s both;
  }
  .vside { display: flex; flex-direction: column; gap: 8px; }
  .vside.mine { align-items: flex-end; }
  .vside.foe { align-items: flex-start; }
  .vlabel { font-size: 15px; font-weight: 900; letter-spacing: 1px; text-transform: uppercase; color: var(--tablet-text-soft, #b4bac0); }
  .vside.mine .vlabel { color: var(--acc-light); }
  .vrow { display: flex; align-items: center; gap: 16px; }
  .vscore { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 64px; line-height: 1; font-weight: 900; color: var(--text-main, #fff); min-width: 44px; text-align: center; }
  .vside.mine .vscore { color: var(--acc-light); }
  .vs { font-size: 26px; font-weight: 900; letter-spacing: 1.5px; color: var(--tablet-text-soft, #b4bac0); }
  .pips { display: flex; gap: 6px; }
  .pips i {
    display: block;
    width: 22px;
    height: 22px;
    border-radius: var(--r-tag);
    background: rgba(255, 255, 255, 0.09);
    border: 1px solid rgba(255, 255, 255, 0.12);
  }
  .vside.mine .pips i.on { background: var(--acc); border-color: var(--acc-light); box-shadow: none; animation: pipIn 0.3s ease-out both; }
  .vside.foe .pips i.on { background: #8a8f96; border-color: #b4bac0; animation: pipIn 0.3s ease-out both; }
  @keyframes pipIn { from { transform: scale(0.3); opacity: 0; } to { transform: scale(1); opacity: 1; } }

  .mvps { display: flex; gap: 18px; animation: fadeUp 0.5s ease-out 1.1s both; }
  .chip {
    min-width: 280px;
    display: grid;
    grid-template-columns: auto 1fr;
    grid-template-areas: 'tag tag' 'name stat';
    align-items: baseline;
    gap: 2px 14px;
    padding: 10px 18px;
    background: linear-gradient(90deg, rgba(24, 22, 18, 0.95), rgba(12, 12, 14, 0.95));
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-left: 4px solid #8a8f96;
    border-radius: var(--r-tag);
  }
  .chip.mine { border-left-color: var(--acc); }
  .chip-tag { grid-area: tag; font-size: 12px; font-weight: 900; letter-spacing: 0.8px; text-transform: uppercase; color: var(--tablet-text-soft, #b4bac0); }
  .chip.mine .chip-tag { color: var(--acc-light); }
  .chip-name { grid-area: name; font-size: 19px; font-weight: 900; color: var(--text-main, #fff); }
  .chip-stat { grid-area: stat; justify-self: end; font-family: var(--font-mono); font-size: 14px; font-weight: 800; color: var(--tablet-text-soft, #b4bac0); }

  .splash-hint { font-size: 13px; font-weight: 800; letter-spacing: 0.6px; text-transform: uppercase; color: var(--tablet-text-soft, #b4bac0); animation: fadeUp 0.5s ease-out 1.6s both; }
  .splash-hint b { margin-right: 6px; padding: 1px 6px; border: 1px solid currentColor; border-radius: var(--r-ctl); }
</style>
