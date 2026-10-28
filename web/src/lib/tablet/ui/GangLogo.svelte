<script>
  // The single reusable gang-identity badge — every surface that shows a gang
  // (management cards, leaderboard, live rosters, capture/victory banners)
  // renders through this instead of re-implementing the "has a logo? show it
  // : fall back to initials" branch each time. Takes the gang's own data
  // directly (logo/label already come back on every gang list/lookup this
  // resource has) rather than re-fetching by id — most call sites already
  // have the full gang object in hand, so a per-instance fetch would just be
  // an extra round trip for data the caller already loaded.
  import { avatarColor, initials, inkOn } from '../../util/avatar.js';

  export let logo = null;
  export let label = '';
  export let size = 32;
  export let square = true; // gang logos read as a badge/icon, not a person — rounded square by default
  // The admin-set per-gang accent color (Gang Management -> Settings) — used
  // as the no-logo fallback background instead of the auto-generated hash
  // color, so a gang that picked a color actually sees it everywhere this
  // badge renders (leaderboard, live rosters, capture banners), not just on
  // the management card. Falls back to the hash color when a gang never set
  // one (accentColor null/undefined), same as before.
  export let accentColor = null;
</script>

<div
  class="gang-logo"
  class:square
  style="width:{size}px;height:{size}px;font-size:{Math.max(11, size * 0.38)}px;{logo ? '' : `background:${accentColor || avatarColor(label)};color:${inkOn(accentColor || avatarColor(label))}`}"
>
  {#if logo}
    <img src={logo} alt={label} />
  {:else}
    <span>{initials(label)}</span>
  {/if}
</div>

<style>
  .gang-logo {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    border-radius: 50%;
    border: 1px solid var(--tablet-border-strong, rgba(255, 255, 255, 0.12));
    color: var(--lt-ffffff, #fff);
    font-weight: 700;
    letter-spacing: 0.01em;
  }
  .gang-logo.square {
    border-radius: 28%;
  }
  .gang-logo img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
</style>
