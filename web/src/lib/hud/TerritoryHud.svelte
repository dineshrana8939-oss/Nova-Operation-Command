<script>
  // In-game HUD of the Gang Territory system (flat, matte — like the other event HUDs):
  //   · (the auction board is not here any more: it hangs in the world over the projector, see AuctionTv.svelte)
  //   · the WAR HUD — countdown, capture state and progress (TAKING TERRITORY... / TERRITORY CONTESTED), who is present.
  import { territoryHud } from '../territory/territoryStore.js';
  import { themeVars } from './eventThemes.js';
  import './hud-shared.css';

  const clock = (s) => `${String(Math.floor(Math.max(0, s) / 60)).padStart(2, '0')}:${String(Math.max(0, s) % 60).padStart(2, '0')}`;

  $: war = $territoryHud.war;
  $: w = war?.war;
  $: wt = war?.tick;
  $: capState = wt?.state || w?.state || 'IDLE';
  $: capPct = wt && wt.captureSeconds ? Math.min(100, (wt.progress / wt.captureSeconds) * 100) : 0;
  $: secondsLeft = wt ? wt.secondsLeft : w?.secondsLeft || 0;
  $: atkTotal = wt?.attackersTotal ?? w?.attackersTotal ?? 0;
  $: defTotal = wt?.defendersTotal ?? w?.defendersTotal ?? 0;
  $: atkAlive = wt?.attackersAlive ?? w?.attackersAlive ?? 0;
  $: defAlive = wt?.defendersAlive ?? w?.defendersAlive ?? 0;
  $: atkIn = wt?.attackersPresent ?? w?.attackersPresent ?? 0;
  $: defIn = wt?.defendersPresent ?? w?.defendersPresent ?? 0;
  const CAP_TEXT = { IDLE: 'CAPTURE POINT READY', CAPTURING: 'TAKING TERRITORY...', CONTESTED: 'TERRITORY CONTESTED', PAUSED: 'CAPTURE PAUSED' };
  $: res = $territoryHud.warResult;
  $: oob = $territoryHud.outOfBounds;
  $: isEliminated = wt?.eliminated ?? w?.eliminated ?? false;
  $: elimBlocked = $territoryHud.eliminatedBlocked;
</script>

{#if w}
  <div class="war" style={themeVars('rivals')}>
    <div class="war-top">
      <div class="war-side">
        <div class="war-team-head">
          <span>{w.attackerLabel}</span>
          <i>ATTACKER</i>
        </div>
        <div class="war-team-meta">
          <span class="war-pill total" title="Team A Total Members on Server"><i class="fa-solid fa-users"></i> {atkTotal} Total</span>
          <span class="war-pill zone" title="Team A Alive in Zone"><i class="fa-solid fa-crosshairs"></i> {atkIn} in Zone</span>
        </div>
      </div>
      <div class="war-mid">
        <b>{clock(secondsLeft)}</b>
        <span>TERRITORY WAR · {w.territoryName}</span>
        {#if isEliminated}
          <div class="war-elim-pill"><i class="fa-solid fa-skull"></i> ELIMINATED (SPECTATOR)</div>
        {/if}
      </div>
      <div class="war-side r">
        <div class="war-team-head">
          <span>{w.defenderLabel}</span>
          <i>DEFENDER</i>
        </div>
        <div class="war-team-meta r">
          <span class="war-pill zone" title="Team B Alive in Zone"><i class="fa-solid fa-shield"></i> {defIn} in Zone</span>
          <span class="war-pill total" title="Team B Total Members on Server"><i class="fa-solid fa-users"></i> {defTotal} Total</span>
        </div>
      </div>
    </div>
    <div class="war-cap" class:contested={capState === 'CONTESTED'} class:capturing={capState === 'CAPTURING'}>
      <div class="war-cap-text">{CAP_TEXT[capState] || capState}</div>
      <div class="war-bar"><i style="width:{capPct}%"></i></div>
      <div class="war-fighters-grid">
        <div class="fighter-col left">
          <span class="fighter-team">{w.attackerLabel}</span>
          <span class="fighter-count"><b>{atkIn}</b> in zone · {atkTotal} total members</span>
        </div>
        <div class="fighter-vs">VS</div>
        <div class="fighter-col right">
          <span class="fighter-team">{w.defenderLabel}</span>
          <span class="fighter-count"><b>{defIn}</b> in zone · {defTotal} total members</span>
        </div>
      </div>
    </div>
    {#if w.role === 'ATTACKER' && capState === 'IDLE'}<div class="war-hint">Reach the territory leader and use <b>Take Territory</b></div>{/if}
    {#if w.role === 'DEFENDER'}<div class="war-hint">Defend the capture point — stand in it to contest</div>{/if}
  </div>
{/if}

{#if oob && oob.active}
  <div class="war-oob-card">
    <div class="oob-pulsing-badge">
      <i class="fa-solid fa-triangle-exclamation"></i>
    </div>
    <div class="oob-body">
      <div class="oob-title">{oob.title || 'WARNING: OUT OF RIVAL ZONE!'}</div>
      <div class="oob-subtitle">{oob.subtitle || 'Return to the combat area or you will be eliminated'}</div>
      <div class="oob-bar-wrap">
        <div class="oob-bar" style="width: {Math.max(0, Math.min(100, (oob.secondsLeft / (oob.maxSeconds || 35)) * 100))}%"></div>
      </div>
    </div>
    <div class="oob-countdown">
      <b>{oob.secondsLeft}</b><span>SEC</span>
    </div>
  </div>
{/if}

{#if elimBlocked && elimBlocked.active}
  <div class="war-elim-card">
    <div class="elim-pulsing-badge">
      <i class="fa-solid fa-ban"></i>
    </div>
    <div class="elim-body">
      <div class="elim-title">ACCESS DENIED — ELIMINATED FIGHTER</div>
      <div class="elim-subtitle">{elimBlocked.message || 'You were eliminated from this rival war! Revived players cannot re-enter the combat zone.'}</div>
    </div>
  </div>
{/if}

{#if res}
  <div class="war-res" style={themeVars('rivals')}>
    <b>{res.winnerLabel ? `WINNER: ${res.winnerLabel.toUpperCase()}` : 'WAR OVER'}</b>
    <span>{res.message}</span>
  </div>
{/if}

<style>
  .war { position: fixed; top: 18px; left: 50%; transform: translateX(-50%); width: 560px; z-index: 9990; pointer-events: none; font-family: var(--font-ui); color: #f4f4f7; }
  .war-top { display: grid; grid-template-columns: 1fr 180px 1fr; align-items: center; background: rgba(13, 14, 20, 0.96); border: 1px solid #2a2e35; border-radius: var(--r-ctl); min-height: 66px; padding: 6px 0; overflow: hidden; border-top: 3px solid var(--accent); }
  .war-side { padding: 0 12px; display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .war-side.r { text-align: right; }
  .war-team-head { display: flex; flex-direction: column; }
  .war-side.r .war-team-head { align-items: flex-end; }
  .war-side span { font-weight: 800; font-size: 13.5px; text-transform: uppercase; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .war-side i { font-style: normal; font-size: 10px; letter-spacing: 0.12em; color: var(--accent2); font-weight: 800; }
  .war-team-meta { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; margin-top: 2px; }
  .war-team-meta.r { justify-content: flex-end; }
  .war-pill { font-size: 10px; font-weight: 700; padding: 2px 6px; border-radius: var(--r-tag); background: rgba(255, 255, 255, 0.08); color: #cbd0de; display: inline-flex; align-items: center; gap: 4px; }
  .war-pill.zone { background: rgba(70, 201, 139, 0.15); color: #46c98b; border: 1px solid rgba(70, 201, 139, 0.3); }
  .war-pill.total { background: rgba(196, 94, 224, 0.15); color: #d896ff; border: 1px solid rgba(196, 94, 224, 0.3); }
  .war-mid { text-align: center; border-left: 1px solid #2a2e35; border-right: 1px solid #2a2e35; background: rgba(0, 0, 0, 0.25); height: 100%; display: flex; flex-direction: column; justify-content: center; align-items: center; }
  .war-mid b { font-size: 21px; font-variant-numeric: tabular-nums; }
  .war-mid span { font-size: 10px; letter-spacing: 0.08em; color: #ffc857; font-weight: 800; text-transform: uppercase; padding: 0 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .war-elim-pill { display: inline-flex; align-items: center; justify-content: center; gap: 4px; font-size: 10px; font-weight: 900; letter-spacing: 0.08em; color: #ff5252; background: rgba(255, 59, 48, 0.2); border: 1px solid rgba(255, 59, 48, 0.5); border-radius: var(--r-tag); padding: 1px 6px; margin-top: 2px; text-transform: uppercase; }
  .war-cap { margin-top: 6px; background: rgba(13, 14, 20, 0.96); border: 1px solid #2a2e35; border-radius: var(--r-ctl); padding: 8px 12px 9px; }
  .war-cap.capturing { border-color: #46c98b; }
  .war-cap.contested { border-color: #ff5d50; }
  .war-cap-text { font-size: 12.5px; font-weight: 800; letter-spacing: 0.1em; text-align: center; }
  .war-cap.contested .war-cap-text { color: #ff8a80; }
  .war-cap.capturing .war-cap-text { color: #46c98b; }
  .war-bar { height: 7px; background: rgba(255, 255, 255, 0.1); border-radius: 4px; margin: 7px 0 5px; overflow: hidden; }
  .war-bar i { display: block; height: 100%; background: #46c98b; transition: width 0.9s linear; }
  .war-cap.contested .war-bar i { background: #ff5d50; }
  .war-fighters-grid { display: flex; justify-content: space-between; align-items: center; margin-top: 6px; padding-top: 6px; border-top: 1px solid #23252f; font-size: 11px; }
  .fighter-col { display: flex; flex-direction: column; min-width: 0; }
  .fighter-col.right { text-align: right; }
  .fighter-team { font-weight: 800; color: #cbd0de; text-transform: uppercase; font-size: 10.5px; }
  .fighter-count { color: #8d92a5; font-size: 10.5px; }
  .fighter-count b { color: #46c98b; }
  .fighter-vs { font-weight: 900; font-size: 10px; color: #ffc857; padding: 0 8px; }
  .war-hint { margin-top: 5px; text-align: center; font-size: 12px; color: #cbd0de; background: rgba(13, 14, 20, 0.9); border: 1px solid #2a2e35; border-radius: var(--r-ctl); padding: 4px 8px; }
  .war-res { position: fixed; top: 100px; left: 50%; transform: translateX(-50%); z-index: 9991; pointer-events: none; text-align: center; background: rgba(13, 14, 20, 0.97); border: 1px solid var(--accent); border-radius: var(--r-ctl); padding: 10px 22px; max-width: 620px; font-family: var(--font-ui); color: #f4f4f7; }
  .war-res b { display: block; font-size: 17px; letter-spacing: 0.06em; color: var(--accent2); }
  .war-res span { font-size: 12.5px; color: #cbd0de; }

  /* Out-of-Bounds Combat Warning Card */
  .war-oob-card {
    position: fixed; top: 140px; left: 50%; transform: translateX(-50%); width: 490px; z-index: 9995;
    background: rgba(22, 10, 12, 0.96); border: 2px solid #ff3b30; border-radius: var(--r-panel);
    box-shadow: 0 0 25px rgba(255, 59, 48, 0.5), inset 0 0 15px rgba(255, 59, 48, 0.2);
    display: flex; align-items: center; gap: 14px; padding: 10px 16px;
    font-family: var(--font-ui); color: #fff;
    animation: oobPulse 1.2s infinite ease-in-out; pointer-events: none;
  }
  @keyframes oobPulse {
    0%, 100% { box-shadow: 0 0 20px rgba(255, 59, 48, 0.4); border-color: #ff3b30; }
    50% { box-shadow: 0 0 35px rgba(255, 59, 48, 0.8); border-color: #ff6961; }
  }
  .oob-pulsing-badge { font-size: 26px; color: #ff3b30; display: flex; align-items: center; justify-content: center; animation: oobIconBlink 0.8s infinite alternate; }
  @keyframes oobIconBlink { 0% { transform: scale(1); opacity: 0.8; } 100% { transform: scale(1.15); opacity: 1; } }
  .oob-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .oob-title { font-weight: 900; font-size: 13.5px; letter-spacing: 0.08em; color: #ff5252; text-transform: uppercase; }
  .oob-subtitle { font-size: 11px; color: #e2e8f0; font-weight: 500; }
  .oob-bar-wrap { height: 5px; background: rgba(255, 255, 255, 0.15); border-radius: 3px; overflow: hidden; margin-top: 5px; }
  .oob-bar { height: 100%; background: #ff3b30; transition: width 0.9s linear; }
  .oob-countdown { text-align: center; min-width: 52px; background: rgba(0, 0, 0, 0.4); border: 1px solid rgba(255, 59, 48, 0.4); border-radius: var(--r-tag); padding: 4px 6px; }
  .oob-countdown b { display: block; font-size: 20px; font-weight: 900; color: #ff5252; font-variant-numeric: tabular-nums; line-height: 1; }
  .oob-countdown span { font-size: 10px; letter-spacing: 0.1em; color: #ff9999; font-weight: 800; }

  /* Eliminated Fighter Barrier Card */
  .war-elim-card {
    position: fixed; top: 140px; left: 50%; transform: translateX(-50%); width: 510px; z-index: 9996;
    background: rgba(26, 8, 12, 0.97); border: 2px solid #ff3b30; border-radius: var(--r-panel);
    box-shadow: 0 0 30px rgba(255, 59, 48, 0.6), inset 0 0 18px rgba(255, 59, 48, 0.3);
    display: flex; align-items: center; gap: 14px; padding: 12px 18px;
    font-family: var(--font-ui); color: #fff;
    animation: oobPulse 1.2s infinite ease-in-out; pointer-events: none;
  }
  .elim-pulsing-badge { font-size: 28px; color: #ff3b30; display: flex; align-items: center; justify-content: center; animation: oobIconBlink 0.8s infinite alternate; }
  .elim-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .elim-title { font-weight: 900; font-size: 13.5px; letter-spacing: 0.08em; color: #ff5252; text-transform: uppercase; }
  .elim-subtitle { font-size: 11px; color: #fecaca; font-weight: 500; line-height: 1.35; }
</style>
