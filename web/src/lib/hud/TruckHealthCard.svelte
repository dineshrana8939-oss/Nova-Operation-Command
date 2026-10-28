<script>
  // The floating truck health readout shown above every convoy / hot cargo truck (placed by TruckOverheadHealth.svelte):
  // no box, just the truck's name in small caps over a big percentage - green, amber at 60% and red at 25% - in the same
  // style as the in-truck "TRUCK HEALTH" readout (HotCargoTruckHealth.svelte). A disabled truck shows 0% and STALLED.
  // A towed trailer has no health of its own: this always shows the truck's.
  export let label = 'Truck';
  export let pct = 100;
  export let broken = false;
  export let kind = 'convoy'; // kept for callers; the colour follows the health, not the event

  // the client already counts the number down smoothly (also to 0 for a disabled truck), so it is shown as it comes
  $: value = Math.max(0, Math.min(100, Math.round(pct)));
  $: tone = broken || value <= 25 ? 'danger' : value <= 60 ? 'warning' : '';
</script>

<div class="floating">
  <div class="name">{label}</div>
  <div class="readout {tone}"><span>{value}</span><span class="percent">%</span></div>
  {#if broken}<div class="stalled">Stalled</div>{/if}
</div>

<style>
  .floating {
    --good: #29ed91;
    --warning: #ffc247;
    --danger: #ff565f;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2px;
    white-space: nowrap;
    pointer-events: none;
    user-select: none;
    font-family: Inter, 'Segoe UI', Arial, sans-serif;
    animation: floatIn 0.4s cubic-bezier(0.2, 0.8, 0.2, 1) both;
  }
  .name {
    color: #fff;
    font-size: 12px;
    font-weight: 850;
    letter-spacing: 1.6px;
    text-transform: uppercase;
    text-shadow: 0 2px 3px rgba(0, 0, 0, 0.95), 0 0 8px rgba(0, 0, 0, 0.45);
  }
  .readout {
    display: flex;
    align-items: baseline;
    gap: 2px;
    color: var(--good);
    font-weight: 900;
    font-size: 36px;
    line-height: 1;
    letter-spacing: -1.4px;
    text-shadow: 0 2px 3px rgba(0, 0, 0, 0.9), 0 0 8px rgba(0, 0, 0, 0.4);
    font-variant-numeric: tabular-nums;
  }
  .percent { font-size: 0.68em; letter-spacing: -1px; margin-left: 1px; }
  .readout.warning { color: var(--warning); }
  .readout.danger { color: var(--danger); }
  .stalled {
    color: var(--danger);
    font-size: 10.5px;
    font-weight: 850;
    letter-spacing: 1.6px;
    text-transform: uppercase;
    text-shadow: 0 2px 3px rgba(0, 0, 0, 0.95);
  }
  @keyframes floatIn {
    from { opacity: 0; transform: translateY(6px); }
    to { opacity: 1; transform: translateY(0); }
  }
</style>
