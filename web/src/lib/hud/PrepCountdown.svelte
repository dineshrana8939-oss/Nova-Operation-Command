<script>
  import { prepCountdown } from './hudStore.js';
  import TimerCard from './TimerCard.svelte';
</script>

{#if $prepCountdown.visible}
  <!-- Police-facing head start, so it carries the police colour. -->
  <TimerCard
    wide
    eventKey="police"
    kicker="PREPARATION PHASE // POLICE HEAD START"
    title="CONVOY DEPARTURE IMMINENT"
    urgentAt={10}
    seconds={$prepCountdown.seconds}
    maxSeconds={$prepCountdown.maxSeconds}
  />
{/if}
