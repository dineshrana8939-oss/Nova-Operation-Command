<script>
  import { fly } from 'svelte/transition';
  import { playerHealth } from './hudStore.js';

  // The bar the player sees in practice / TDM. It always reads 0-100; how much real health sits behind it is the
  // game's business (Config.PracticeRange.hiddenHealthMultiplier), not this component's.
  let lastHp = null;
  let hitFlash = false;
  let flashTimer = null;
  let lost = 0;            // points taken by the latest hit, shown as a floating "−N"
  let lostKey = 0;
  let healed = false;

  $: maxHp = Math.max(1, $playerHealth.max || 100);
  $: currentHp = Math.max(0, Math.min(maxHp, $playerHealth.hp || 0));
  $: pct = Math.max(0, Math.min(100, (currentHp / maxHp) * 100));
  $: tone = pct > 60 ? '#46c98b' : pct > 30 ? '#ffc857' : '#ff5d50';
  $: status = pct <= 30 ? 'Critical' : pct <= 60 ? 'Wounded' : pct < 100 ? 'Healthy' : 'Full health';

  $: if ($playerHealth.visible) {
    if (lastHp !== null && currentHp < lastHp) {
      lost = Math.round(lastHp - currentHp);
      lostKey += 1;
      hitFlash = true;
      clearTimeout(flashTimer);
      flashTimer = setTimeout(() => { hitFlash = false; }, 260);
    }
    healed = lastHp !== null && currentHp > lastHp;
    lastHp = currentHp;
  } else {
    lastHp = null;
    lost = 0;
  }
</script>

{#if $playerHealth.visible}
  <div class="hp" class:hit={hitFlash} class:low={pct <= 30} style="--tone:{tone}" transition:fly={{ y: 24, duration: 220 }} role="status" aria-label={`Health ${Math.round(currentHp)} of ${Math.round(maxHp)}`}>
    {#if lost > 0}
      {#key lostKey}<span class="lost" aria-hidden="true">−{lost}</span>{/key}
    {/if}

    <div class="row">
      <span class="icon" aria-hidden="true">
        <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M12 21s-7.5-4.6-9.6-9.2C1 8.6 2.8 5 6.3 5c2 0 3.5 1 4.5 2.4h2.4C14.2 6 15.700 5 17.700 5c3.500 0 5.300 3.600 3.900 6.800C19.500 16.400 12 21 12 21z"/></svg>
      </span>
      <div class="label">
        <span class="name">Health</span>
        <span class="state" class:up={healed}>{status}</span>
      </div>
      <div class="num">
        <b>{Math.round(currentHp)}</b><span>/ {Math.round(maxHp)}</span>
      </div>
    </div>

    <div class="track">
      <i class="ghost" style="width:{pct}%"></i>
      <i class="fill" style="width:{pct}%"></i>
      <i class="notches"></i>
    </div>
  </div>
{/if}

<style>
  .hp {
    position: fixed;
    bottom: 34px;
    left: 50%;
    transform: translateX(-50%);
    width: 330px;
    padding: 12px 16px 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    font-family: var(--font-ui);
    color: #eceef0;
    background: rgba(12, 16, 23, 0.94);
    border: 1px solid rgba(130, 165, 210, 0.3);
    border-radius: 14px;
    box-shadow: 0 10px 28px rgba(0, 0, 0, 0.6);
    pointer-events: none;
    z-index: 9985;
    transition: border-color 0.2s ease;
  }
  .hp.hit { border-color: #ff5d50; }
  .hp.low { animation: pulse 1s ease-in-out infinite; }
  @keyframes pulse {
    0%, 100% { border-color: rgba(255, 93, 80, 0.55); }
    50% { border-color: #ff5d50; }
  }

  .row { display: flex; align-items: center; gap: 12px; }
  .icon {
    flex: none; width: 36px; height: 36px; display: grid; place-items: center; border-radius: 10px;
    color: var(--tone); background: color-mix(in srgb, var(--tone) 16%, transparent);
    border: 1px solid color-mix(in srgb, var(--tone) 42%, transparent);
    transition: color 0.25s, background 0.25s, border-color 0.25s;
  }
  .label { display: flex; flex-direction: column; min-width: 0; line-height: 1.2; }
  .name { font-size: 15px; font-weight: 600; color: #fff; }
  .state { font-size: 13px; color: var(--tone); transition: color 0.25s; }
  .state.up { color: #46c98b; }
  .num { margin-left: auto; display: flex; align-items: baseline; gap: 5px; font-variant-numeric: tabular-nums; }
  .num b {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 30px; font-weight: 700; line-height: 1; color: #fff;
  }
  .num span { font-size: 13px; color: #8d949c; }

  .track { position: relative; height: 10px; border-radius: 5px; background: rgba(255, 255, 255, 0.09); overflow: hidden; }
  .track i { position: absolute; inset: 0 auto 0 0; border-radius: 5px; }
  .fill { background: var(--tone); transition: width 0.18s cubic-bezier(0.2, 0.8, 0.2, 1), background 0.25s; }
  /* the "what you just lost" trail: it hangs back, then catches up to the real value */
  .ghost { background: rgba(255, 255, 255, 0.55); transition: width 0.7s ease-out 0.3s; }
  .notches { inset: 0; width: 100%; border-radius: 0; background: repeating-linear-gradient(90deg, transparent 0 24.4%, rgba(7, 9, 13, 0.7) 24.4% 25%); }

  .lost {
    position: absolute; right: 18px; top: -8px;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 20px; font-weight: 700; color: #ff5d50;
    animation: lost 0.9s ease-out forwards;
  }
  @keyframes lost {
    from { opacity: 1; transform: translateY(0); }
    to { opacity: 0; transform: translateY(-22px); }
  }

  @media (prefers-reduced-motion: reduce) {
    .hp.low, .lost { animation: none; }
    .fill, .ghost { transition: none; }
  }
</style>
