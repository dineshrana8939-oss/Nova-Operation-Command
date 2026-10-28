<script>
  // The tag above a reward vehicle inside an opened container, styled as a steel plate (cwTheme.css).
  // The vehicle's name is shown in full: it wraps, it is never cut off.
  import { vehicleRewardInfos } from './vehicleRewardStore.js';
  import './cwTheme.css';

  const money = (val) => '$' + Number(val || 0).toLocaleString('en-US');
</script>

{#each $vehicleRewardInfos as v (v.entityNetId || v.id)}
  <!-- Anchored by its bottom-centre so the tag floats right above the vehicle roof -->
  <div
    class="vehicle-reward-tag-wrap"
    style="left: {v.x * 100}%; top: {v.y * 100}%; transform: translate(-50%, -100%) scale({v.scale ?? 1});"
  >
    <div class="panel cw-plate">
      <div class="cw-strip"></div>

      <div class="head">
        <span class="cw-kicker">Reward vehicle</span>
        <span class="state"><span class="dot"></span>Available</span>
      </div>
      <div class="model">{String(v.modelLabel || v.model || 'Vehicle')}</div>
      {#if v.containerName}<div class="lot cw-kicker">{v.lotNumber ? `Lot ${v.lotNumber} · ` : ''}{v.containerName}</div>{/if}

      <div class="body">
        <div class="cell">
          <div class="cw-kicker">Won by</div>
          <div class="bidder">
            <span class="name">{v.bidderName || 'Winner'}</span>
            {#if v.winnerGangLabel}<span class="gang-tag">{v.winnerGangLabel}</span>{/if}
          </div>
        </div>
        <div class="cell">
          <div class="cw-kicker">Final price</div>
          <div class="price">{money(v.finalPrice)}</div>
        </div>
      </div>

      <div class="foot">
        <span class="cw-key">E</span>
        <span class="hint">{v.canClaim ? 'Claim vehicle' : 'Approach to claim'}</span>
      </div>
    </div>

    <div class="notch"></div>
  </div>
{/each}

<style>
  .vehicle-reward-tag-wrap {
    position: absolute;
    width: 270px;
    pointer-events: none;
    transform-origin: 50% 100%;
    z-index: 998;
    filter: drop-shadow(0 5px 10px rgba(0, 0, 0, 0.55));
    font-family: var(--font-ui);
    user-select: none;
  }
  .lot { padding: 2px 14px 0; }
  .panel { overflow: hidden; /* no backdrop-filter: over the world it is painted as a solid black box in the game browser */ }

  .head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 14px 0; }
  .state {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--cw-green);
  }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--cw-green); }

  .model {
    padding: 4px 14px 9px;
    font-family: var(--cw-display);
    font-size: 19px;
    font-weight: 700;
    line-height: 1.15;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    white-space: normal;
    overflow-wrap: anywhere;
  }

  .body { display: grid; grid-template-columns: 1.3fr 1fr; border-top: 1px solid var(--cw-line-soft); }
  .cell { padding: 8px 10px 9px 14px; min-width: 0; }
  .cell + .cell { border-left: 1px solid var(--cw-line-soft); padding-left: 12px; }
  .bidder { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; margin-top: 3px; }
  .name { font-size: 14px; font-weight: 700; line-height: 1.2; overflow-wrap: anywhere; }
  .gang-tag {
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--cw-blue);
    overflow-wrap: anywhere;
  }
  .price {
    margin-top: 3px;
    font-family: var(--cw-display);
    font-size: 21px;
    font-weight: 700;
    line-height: 1.1;
    color: var(--cw-yellow);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .foot { display: flex; align-items: center; gap: 8px; padding: 8px 14px 10px; border-top: 1px solid var(--cw-line-soft); }
  .hint {
    font-family: var(--cw-display);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.12em;
    text-transform: uppercase;
  }

  .notch {
    width: 10px;
    height: 10px;
    margin: -6px auto 0;
    transform: rotate(45deg);
    background: var(--cw-hull);
    border-right: 1px solid var(--cw-line);
    border-bottom: 1px solid var(--cw-line);
  }
</style>
