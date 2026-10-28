<script>
  // The bar at the top of the screen while a won reward car waits in its container: who won it, which container and car, and how
  // long the winner has left to claim it. Toggled with /cwvehicle. It sits under the auction timer when that is showing.
  // Styled as a steel plate (cwTheme.css); every line wraps, nothing is cut off.
  import { vehicleClaimBar } from './vehicleClaimStore.js';
  import { containerTimer } from './containerTimerStore.js';
  import './cwTheme.css';

  const money = (val) => '$' + Number(val || 0).toLocaleString('en-US');
  const mmss = (s) => {
    s = Math.max(0, Math.floor(Number(s) || 0));
    return String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
  };

  $: v = $vehicleClaimBar;
  $: pct = v && v.total ? Math.max(0, Math.min(100, (v.remaining / v.total) * 100)) : 0;
  $: urgent = !!v && v.remaining <= 30;
</script>

{#if v}
  <div class="claim-bar cw-plate" class:below={$containerTimer.visible} class:urgent>
    <div class="cw-strip"></div>
    <div class="row">
      <div class="text">
        <div class="cw-kicker">Reward vehicle{v.lot ? ` · Lot ${v.lot}` : ''}{v.container ? ` · ${v.container}` : ''}</div>
        <div class="model">{v.vehicle || 'Vehicle'}</div>
      </div>
      <div class="time" aria-label="Claim time left">{mmss(v.remaining)}</div>
    </div>
    <div class="track"><span style="width: {pct}%"></span></div>
    <div class="meta">
      <div class="cell">
        <div class="cw-kicker">Won by</div>
        <div class="who">{v.winner || 'Winner'}{#if v.winnerGang}<span class="gang">{v.winnerGang}</span>{/if}</div>
      </div>
      <div class="cell">
        <div class="cw-kicker">Final price</div>
        <div class="price">{money(v.price)}</div>
      </div>
      {#if v.plate}
        <div class="cell">
          <div class="cw-kicker">Plate</div>
          <div class="plate">{v.plate}</div>
        </div>
      {/if}
    </div>
    <div class="foot">
      <span class="cw-key">E</span>
      <span class="hint">{v.mine ? 'Walk up to the vehicle and claim it' : 'Reserved for the winning bidder'}</span>
    </div>
  </div>
{/if}

<style>
  .claim-bar {
    position: fixed;
    top: 14px;
    left: 50%;
    transform: translateX(-50%);
    width: 460px;
    max-width: calc(100vw - 32px);
    overflow: hidden;
    font-family: var(--font-ui);
    pointer-events: none;
    z-index: 39;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.5);
  }
  /* the auction timer holds the top of the screen while a bid is running: the bar steps below it */
  .claim-bar.below { top: 132px; }

  .row { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 9px 16px 8px; }
  .text { min-width: 0; }
  .model {
    margin-top: 3px;
    font-family: var(--cw-display);
    font-size: 19px;
    font-weight: 700;
    line-height: 1.15;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    white-space: normal;
    overflow-wrap: anywhere;
  }
  .time {
    flex: 0 0 auto;
    font-family: var(--cw-display);
    font-size: 32px;
    font-weight: 700;
    line-height: 1;
    letter-spacing: 0.03em;
    font-variant-numeric: tabular-nums;
    color: var(--cw-yellow);
  }
  .urgent .time { color: var(--cw-red); }

  .track { height: 4px; margin: 0 16px; background: var(--cw-line-soft); }
  .track span { display: block; height: 100%; background: var(--cw-green); transition: width 0.4s linear; }
  .urgent .track span { background: var(--cw-red); }

  .meta { display: flex; gap: 0; margin-top: 8px; border-top: 1px solid var(--cw-line-soft); }
  .cell { flex: 1 1 0; min-width: 0; padding: 8px 12px 9px 16px; }
  .cell + .cell { border-left: 1px solid var(--cw-line-soft); padding-left: 12px; }
  .who { margin-top: 3px; font-size: 14px; font-weight: 700; line-height: 1.2; overflow-wrap: anywhere; }
  .gang {
    display: block;
    margin-top: 2px;
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--cw-blue);
  }
  .price {
    margin-top: 3px;
    font-family: var(--cw-display);
    font-size: 19px;
    font-weight: 700;
    line-height: 1.1;
    color: var(--cw-yellow);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .plate { margin-top: 3px; font-family: var(--cw-display); font-size: 16px; font-weight: 700; letter-spacing: 0.1em; white-space: nowrap; }

  .foot { display: flex; align-items: center; gap: 8px; padding: 8px 16px 10px; border-top: 1px solid var(--cw-line-soft); }
  .hint {
    font-family: var(--cw-display);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }
</style>
