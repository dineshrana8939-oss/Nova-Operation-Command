<script>
  import { checkpointHud } from './hudStore.js';
  import TimerCard from './TimerCard.svelte';
</script>

{#if $checkpointHud.visible}
  <TimerCard
    wide
    eventKey="convoy"
    icon="checkpoint"
    kicker="CHECKPOINT DEFENSE // STAGE {$checkpointHud.index} OF {$checkpointHud.total}"
    title={$checkpointHud.paused ? 'CONVOY STOPPED // TIMER PAUSED' : 'DEFEND CONVOY & SECURE PERIMETER'}
    paused={$checkpointHud.paused}
    seconds={$checkpointHud.seconds}
    maxSeconds={$checkpointHud.maxSeconds}
  />
{/if}
