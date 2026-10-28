<script>
  import { truckOverhead } from './hudStore.js';
  import TruckHealthCard from './TruckHealthCard.svelte';

  // World-space truck health: this only positions the shared TruckHealthCard
  // at the point the client thread projected (World3dToScreen2d) above each
  // truck. The card itself — and therefore the look — is identical to the
  // in-truck readout.
</script>

{#each $truckOverhead as t (t.id)}
  <div
    class="truck-health-pos"
    style="left:{(t.x * 100).toFixed(3)}%; top:{(t.y * 100).toFixed(3)}%; transform: translate(-50%, -100%) scale({t.s || 1})"
  >
    <TruckHealthCard label={t.label} pct={t.pct} broken={t.broken} kind={t.kind} />
  </div>
{/each}

<style>
  .truck-health-pos {
    position: fixed;
    pointer-events: none;
    z-index: 9970;
    will-change: left, top, transform;
  }
</style>
