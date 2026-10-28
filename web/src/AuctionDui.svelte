<script>
  // The page the game loads into a DUI (see client/modules/territory.lua): ONLY the auction board, no tablet, no HUD.
  // The client feeds it the same messages the normal UI gets (territory:auctionState / auctionTick / auctionView).
  import { onMount } from 'svelte';
  import AuctionTv from './lib/hud/AuctionTv.svelte';
  import { handleTerritoryMessage } from './lib/territory/territoryStore.js';

  function onMessage(event) {
    const data = event.data;
    if (data && typeof data.action === 'string' && data.action.startsWith('territory:')) handleTerritoryMessage(data);
  }
  onMount(() => {
    window.addEventListener('message', onMessage);
    return () => window.removeEventListener('message', onMessage);
  });
</script>

<AuctionTv />

<style>
  :global(html), :global(body) { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #0a0b10; }
  :global(#app) { width: 100%; height: 100%; }
</style>
