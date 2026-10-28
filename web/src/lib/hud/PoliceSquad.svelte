<script>
  import { policeSquad, hudHealthHidden } from './hudStore.js';
  import { themeFor } from './eventThemes.js';
  import { hudIcon } from './hudIcons.js';
  import TeamHealthPanel from './TeamHealthPanel.svelte';

  // Dead/downed officers drop off the list (server already omits them too).
  $: visibleRoster = ($policeSquad.roster || []).filter((o) => o.alive);
  $: members = visibleRoster.map((o) => ({
    id: o.identifier,
    name: o.name,
    hp: o.health || 0,
    armour: o.armour || 0,
    status: 'active',
  }));
  const t = themeFor('police');
</script>

{#if $policeSquad.visible && visibleRoster.length > 0 && !$hudHealthHidden}
  <TeamHealthPanel
    title="Police Escort"
    sub="Convoy Team Health"
    footerRight="TEAM STATUS"
    accent={t.accent}
    accent2={t.accent2}
    accentRGB={t.rgb}
    {members}
    activeCount={visibleRoster.length}
    ariaLabel="Police Escort HUD"
    kind="police"
  >
    <svelte:fragment slot="mark">{@html hudIcon('police')}</svelte:fragment>
  </TeamHealthPanel>
{/if}
