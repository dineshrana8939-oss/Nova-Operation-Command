<script>
  // Operation Crackdown HUD: the gang on the left, the police on the right, the time in the middle. There are no points: each side
  // shows how many of its fighters are still standing. A one-line status says what is happening to YOU (prepare / fight / outside the
  // zone / eliminated). The out-of-zone warning is the shared overlay in TerritoryHud.svelte. Everything is sent by the server.
  import { crackdownHud } from './crackdownStore.js';
  import { themeVars } from './eventThemes.js';
  import './hud-shared.css';

  const clock = (s) => `${String(Math.floor(Math.max(0, s) / 60)).padStart(2, '0')}:${String(Math.max(0, Math.floor(s)) % 60).padStart(2, '0')}`;

  const pct = (n, total) => (total > 0 ? Math.max(0, Math.min(100, Math.round((Number(n) / total) * 100))) : 0);

  $: st = $crackdownHud.state;
  $: t = $crackdownHud.tick;
  $: res = $crackdownHud.result;
  $: prep = t?.phase === 'PREP';
  $: mine = t?.side || st?.side;
  $: out = !!t?.eliminated;
  // a start area was drawn for my side: during the countdown the line says whether I am standing in it
  $: needStart = prep && t?.hasStart === true;
  $: line = !t ? '' : out ? 'ELIMINATED — you are out of this operation' : needStart ? (t.inStart ? 'IN YOUR START AREA — stay inside until the timer ends' : `GET INSIDE YOUR ${mine === 'POLICE' ? 'POLICE' : 'GANG'} START AREA`) : prep ? 'PREPARE — get to the combat zone' : t.alive === false ? 'You are down' : t.inside === false ? 'Outside the combat zone — get back in' : 'FIGHT — if you go down, you are out';
  $: bad = !!t && (out || (needStart && !t.inStart) || (!prep && (t.inside === false || t.alive === false)));
  $: good = !!t && !bad && (needStart ? t.inStart : !prep);

  // the last ten seconds of the countdown are shown big in the middle of the screen, and "FIGHT!" for a moment when the fight opens
  let lastPhase = null, goUntil = 0, nowMs = Date.now();
  $: if (t) {
    if (lastPhase === 'PREP' && t.phase === 'ACTIVE') goUntil = Date.now() + 3500;
    lastPhase = t.phase;
    nowMs = Date.now();
  }
  $: bigCount = t && prep && t.secondsLeft <= 10 ? Math.max(0, Math.ceil(t.secondsLeft)) : null;
  $: showGo = t && !prep && nowMs < goUntil;
</script>

{#if st && t}
  <div class="cd" style={themeVars('crackdown')}>
    <div class="cd-top">
      <div class="cd-side gang" class:me={mine === 'GANG'}>
        <div class="cd-tag"><i>{mine === 'GANG' ? 'YOUR GANG' : 'GANG'}</i></div>
        <div class="cd-name">{t.gangLabel}</div>
        <div class="cd-count"><b>{t.gangStanding}</b><span>/ {t.gangTotal} standing</span></div>
        <div class="cd-bar"><div style="width: {pct(t.gangStanding, t.gangTotal)}%"></div></div>
      </div>
      <div class="cd-mid">
        <div class="cd-phase" class:live={!prep}>{prep ? 'FIGHT OPENS IN' : 'TIME LEFT'}</div>
        <div class="cd-clock">{clock(t.secondsLeft)}</div>
        <div class="cd-score"><b>{t.gangStanding}</b><u>VS</u><b>{t.policeStanding}</b></div>
      </div>
      <div class="cd-side police r" class:me={mine === 'POLICE'}>
        <div class="cd-tag"><i>{mine === 'POLICE' ? 'YOUR TEAM' : 'LAW'}</i></div>
        <div class="cd-name">POLICE</div>
        <div class="cd-count"><span>standing /</span><b>{t.policeStanding}</b><span>{t.policeTotal}</span></div>
        <div class="cd-bar"><div style="width: {pct(t.policeStanding, t.policeTotal)}%"></div></div>
      </div>
    </div>
    <div class="cd-line" class:bad class:live={good}><i></i>{line}</div>
    {#if t.kills > 0}<div class="cd-me">Your kills <b>{t.kills}</b></div>{/if}
    {#if t.feed && t.feed.length}
      <div class="cd-feed">
        {#each t.feed.slice(-3) as f}<div>{f.text}</div>{/each}
      </div>
    {/if}
  </div>
  <!-- outside .cd: its transform would make these fixed elements relative to the panel -->
  {#if bigCount !== null}<div class="cd-big" class:red={bigCount <= 3}>{bigCount}</div>{/if}
  {#if showGo}<div class="cd-big go">FIGHT!</div>{/if}
{/if}

{#if res}
  <div class="cd-res" style={themeVars('crackdown')}>
    <b>{res.winnerLabel ? `WINNER: ${String(res.winnerLabel).toUpperCase()}` : (res.result === 'DRAW' ? 'DRAW' : 'OPERATION OVER')}</b>
    <span>{res.message}</span>
  </div>
{/if}

<style>
  /* flat, no glow: two solid team colours (gang red / police blue) on a dark plate, the clock in the middle */
  .cd { position: fixed; top: 16px; left: 50%; transform: translateX(-50%); width: 640px; z-index: 9990; pointer-events: none; font-family: var(--font-ui); color: #f4f4f7; }
  .cd-top { position: relative; display: grid; grid-template-columns: 1fr 168px 1fr; background: #0d0e14; border: 1px solid #262a33; border-radius: 10px; overflow: hidden; }
  .cd-top::before { content: ''; position: absolute; left: 0; right: 0; top: 0; height: 3px; background: linear-gradient(90deg, #ef4444 50%, #3b82f6 50%); }
  .cd-side { padding: 14px 16px 12px; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .cd-side.r { text-align: right; align-items: flex-end; }
  .cd-tag i { font-style: normal; font-size: 10px; letter-spacing: 0.16em; font-weight: 800; color: #6b7280; }
  .cd-side.me .cd-tag i { color: #0d0e14; padding: 2px 7px; border-radius: 4px; }
  .cd-side.gang.me .cd-tag i { background: #ef4444; }
  .cd-side.police.me .cd-tag i { background: #3b82f6; }
  .cd-name { font-weight: 800; font-size: 19px; line-height: 1.1; text-transform: uppercase; letter-spacing: 0.03em; max-width: 100%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .gang .cd-name { color: #ff8a8a; }
  .police .cd-name { color: #8ab8ff; }
  .cd-count { display: flex; align-items: baseline; gap: 6px; font-variant-numeric: tabular-nums; }
  .cd-count b { font-size: 24px; font-weight: 800; color: #fff; line-height: 1; }
  .cd-count span { font-size: 11px; color: #8b93a3; font-weight: 600; letter-spacing: 0.04em; }
  .cd-bar { width: 100%; height: 5px; border-radius: 3px; background: #1c1f28; overflow: hidden; margin-top: 4px; }
  .cd-bar div { height: 100%; border-radius: 3px; transition: width 0.4s ease; }
  .gang .cd-bar div { background: #ef4444; }
  .police .cd-bar div { background: #3b82f6; margin-left: auto; }
  .cd-mid { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; padding: 14px 6px 10px; background: #090a0f; border-left: 1px solid #262a33; border-right: 1px solid #262a33; }
  .cd-phase { font-size: 9.5px; letter-spacing: 0.14em; font-weight: 800; color: #ffc857; white-space: nowrap; }
  .cd-phase.live { color: #46c98b; }
  .cd-clock { font-size: 34px; font-weight: 800; line-height: 1; font-variant-numeric: tabular-nums; letter-spacing: 0.02em; }
  .cd-score { display: flex; align-items: center; gap: 8px; font-variant-numeric: tabular-nums; margin-top: 2px; }
  .cd-score b { font-size: 14px; font-weight: 800; color: #cbd0de; }
  .cd-score u { text-decoration: none; color: #4b5260; font-size: 9px; font-weight: 800; letter-spacing: 0.1em; }
  .cd-line { margin-top: 6px; display: flex; align-items: center; justify-content: center; gap: 9px; text-align: center; font-size: 12px; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; background: #0d0e14; border: 1px solid #262a33; border-radius: 10px; padding: 8px 12px; color: #cbd0de; }
  .cd-line i { flex: none; width: 8px; height: 8px; border-radius: 50%; background: #ffc857; }
  .cd-line.live { color: #46c98b; border-color: #1f5a41; }
  .cd-line.live i { background: #46c98b; }
  .cd-line.bad { color: #ff8a80; border-color: #6b2a25; }
  .cd-line.bad i { background: #ff5d50; }
  .cd-big { position: fixed; left: 50%; top: 34vh; transform: translateX(-50%); font-size: 120px; font-weight: 900; line-height: 1; color: #fff; text-shadow: 0 4px 0 #000c; font-variant-numeric: tabular-nums; }
  .cd-big.red { color: #ff6b5e; }
  .cd-big.go { color: #46c98b; font-size: 96px; letter-spacing: 0.04em; }
  .cd-me { margin-top: 5px; text-align: center; font-size: 12px; color: #cbd0de; background: #0d0e14; border: 1px solid #262a33; border-radius: 10px; padding: 5px 8px; }
  .cd-me b { color: #fff; }
  .cd-feed { margin-top: 5px; display: flex; flex-direction: column; gap: 3px; font-size: 11.5px; color: #cbd0de; }
  .cd-feed div { background: #0d0e14; border: 1px solid #262a33; border-radius: 8px; padding: 4px 10px; }
  .cd-res { position: fixed; top: 100px; left: 50%; transform: translateX(-50%); z-index: 9991; pointer-events: none; text-align: center; background: rgba(13, 14, 20, 0.97); border: 1px solid var(--accent); border-radius: 8px; padding: 10px 22px; max-width: 620px; font-family: var(--font-ui); color: #f4f4f7; }
  .cd-res b { display: block; font-size: 18px; letter-spacing: 0.06em; }
  .cd-res span { display: block; margin-top: 4px; font-size: 13px; color: #cbd0de; }
</style>
