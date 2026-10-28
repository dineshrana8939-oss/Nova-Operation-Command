<script>
  import { fade, scale } from 'svelte/transition';
  import { tdmRespawn } from './hudStore.js';

  $: pct = $tdmRespawn.total > 0 ? Math.max(0, ($tdmRespawn.seconds - 1) / $tdmRespawn.total) * 100 : 0;
</script>

<!-- Shown to the player who was just taken out in TDM: who did it and how long
     until they are back. Bottom-centre so it never covers the kill feed. -->
{#if $tdmRespawn.visible}
  <div class="wrap" in:fade={{ duration: 180 }} out:fade={{ duration: 220 }}>
    <div class="card" in:scale={{ start: 0.9, duration: 250 }}>
      <div class="kicker">Eliminated</div>
      {#if $tdmRespawn.killer}<div class="killer">by <b>{$tdmRespawn.killer}</b></div>{/if}
      <div class="row">
        <span class="label">Respawning in</span>
        {#key $tdmRespawn.seconds}<span class="count">{$tdmRespawn.seconds}</span>{/key}
      </div>
      <div class="bar"><div class="fill" style="width:{pct}%"></div></div>
    </div>
  </div>
{/if}

<style>
  .wrap {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: flex-end;
    justify-content: center;
    padding-bottom: 18vh;
    background: transparent;
    pointer-events: none;
    z-index: 9990;
    font-family: var(--font-ui);
  }
  .card {
    min-width: 320px;
    padding: 16px 28px 18px;
    text-align: center;
    background: rgba(23, 24, 33, 0.95);
    border: 1px solid #2a2e35;
    border-top: 3px solid #ff5d50;
    border-radius: var(--r-panel);
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.65);
  }
  .kicker {
    font-size: 18px;
    font-weight: 800;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: #ff5d50;
  }
  .killer {
    margin-top: 4px;
    font-size: 13.5px;
    font-weight: 600;
    color: #b2b4c1;
  }
  .killer b {
    color: #f0f0f5;
    font-weight: 700;
  }
  .row {
    margin-top: 10px;
    display: flex;
    align-items: baseline;
    justify-content: center;
    gap: 12px;
  }
  .label {
    font-size: 12.5px;
    font-weight: 700;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: #b2b4c1;
  }
  .count {
    display: inline-block;
    font-size: 42px;
    line-height: 1;
    font-weight: 800;
    color: #ffffff;
    font-variant-numeric: tabular-nums;
    animation: tick 0.4s cubic-bezier(0.2, 1.4, 0.4, 1) both;
  }
  @keyframes tick {
    from { transform: scale(1.3); opacity: 0.5; }
    to { transform: scale(1); opacity: 1; }
  }
  .bar {
    margin-top: 12px;
    height: 5px;
    background: rgba(255, 255, 255, 0.08);
    border-radius: 3px;
    overflow: hidden;
  }
  .fill {
    height: 100%;
    background: #ff5d50;
    border-radius: var(--r-ctl);
    transition: width 1s linear;
  }
</style>
