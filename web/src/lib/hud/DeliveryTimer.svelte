<script>
  import { deliveryHud } from './hudStore.js';
  import TimerCard from './TimerCard.svelte';

  // The event that owns the clock decides its colour, icon and wording (kind
  // is sent by the server): Airdrop is violet, Hot Cargo magenta, the default
  // convoy delivery orange — see eventThemes.js.
  const KIND_META = {
    AIRDROP: { eventKey: 'airdrop', name: 'AIRDROP', kicker: 'MISSION CLOCK //', state: 'ACTIVE' },
    HOT_CARGO: { eventKey: 'hotcargo', name: 'HOT CARGO', kicker: 'MISSION CLOCK //', state: 'ACTIVE' },
    DELIVERY: { eventKey: 'convoy', name: 'DELIVERY', kicker: 'MISSION CLOCK //', state: 'IN PROGRESS' },
  };
  $: meta = KIND_META[$deliveryHud.kind] || KIND_META.DELIVERY;
</script>

{#if $deliveryHud.visible}
  <TimerCard
    eventKey={meta.eventKey}
    kicker={meta.kicker}
    name={meta.name}
    state={meta.state}
    seconds={$deliveryHud.seconds}
    maxSeconds={$deliveryHud.maxSeconds}
  />
{/if}
