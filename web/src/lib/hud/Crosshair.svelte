<script>
  import { tweened } from 'svelte/motion';
  import { cubicOut } from 'svelte/easing';
  import { crosshairCfg, crosshairActive, crosshairPulse } from './hudStore.js';
  import CrosshairShape from './CrosshairShape.svelte';

  // Gap kicks outwards on every shot, then eases back.
  const kick = tweened(0, { duration: 0 });
  let lastPulse = 0;
  $: if ($crosshairPulse !== lastPulse) {
    lastPulse = $crosshairPulse;
    kick.set(Math.max(3, $crosshairCfg.gap * 0.5 + 2), { duration: 0 }).then(() => kick.set(0, { duration: 170, easing: cubicOut }));
  }
</script>

{#if $crosshairActive && $crosshairCfg.enabled}
  <div class="xh"><CrosshairShape cfg={$crosshairCfg} kick={$kick} /></div>
{/if}

<style>
  .xh {
    position: fixed;
    left: 50%;
    top: 50%;
    transform: translate(-50%, -50%);
    pointer-events: none;
    z-index: 9970;
    line-height: 0;
  }
</style>
