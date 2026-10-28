<script>
  import { gangSquad, hudHealthHidden } from './hudStore.js';
  import { themeFor, hexToRgb } from './eventThemes.js';
  import TeamHealthPanel from './TeamHealthPanel.svelte';
  import GangLogo from '../tablet/ui/GangLogo.svelte';

  // Dead/downed members drop off the list (the server already omits them;
  // this is a second guard against a stale update).
  $: visibleRoster = ($gangSquad.roster || []).filter((m) => !m.online || m.alive);
  $: onlineCount = visibleRoster.filter((m) => m.online && m.alive).length;

  // A gang keeps its own identity colour; a gang with none set falls back to
  // the neutral server gold rather than borrowing another event's colour.
  $: fallback = themeFor('server');
  $: accent = $gangSquad.gang?.accentColor && /^#/.test($gangSquad.gang.accentColor) ? $gangSquad.gang.accentColor : fallback.accent;
  $: accentRGB = hexToRgb(accent, fallback.rgb);

  $: members = visibleRoster.map((m) => ({
    id: m.identifier,
    name: m.name,
    hp: m.online && m.alive ? m.health : 0,
    armour: m.armour || 0,
    status: !m.online ? 'offline' : m.alive ? 'active' : 'down',
  }));
</script>

{#if $gangSquad.visible && visibleRoster.length > 0 && !$hudHealthHidden}
  <TeamHealthPanel
    title={$gangSquad.gang?.label || 'Gang Crew'}
    sub="Convoy Team Health"
    footerRight="CREW STATUS"
    {accent}
    accent2={accent}
    {accentRGB}
    {members}
    activeCount={onlineCount}
    ariaLabel="Gang Squad HUD"
    kind="gang"
  >
    <svelte:fragment slot="mark">
      {#if $gangSquad.gang}
        <GangLogo logo={$gangSquad.gang.logo} label={$gangSquad.gang.label} accentColor={$gangSquad.gang.accentColor} size={26} />
      {:else}
        <span class="mark-fallback" style="background:{accent}"></span>
      {/if}
    </svelte:fragment>
  </TeamHealthPanel>
{/if}

<style>
  .mark-fallback {
    width: 9px;
    height: 9px;
    transform: rotate(45deg);
  }
</style>
