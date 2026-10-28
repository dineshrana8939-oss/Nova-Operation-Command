<script>
  import { createEventDispatcher } from 'svelte';
  import { bootstrap } from '../../stores.js';
  import { teleportToPosition, startHarbourPlacer } from '../../api/route.js';
  import Icon from './Icon.svelte';
  import { reveal } from './reveal.js';
  import '../tablet-theme.css';

  // One placeable ped (start trigger, race organizer, vehicle ped, weapon
  // vendor, token vendor...). The host owns the data and the "stand here and
  // press the button" logic — this only presents it and raises events:
  //   on:set    — place the ped. The main button is "Place with Hologram": a see-through copy of the ped follows the
  //               crosshair (F freezes it, G drops it to the ground, E confirms) and the event carries the chosen spot
  //               as e.detail = { x, y, z, heading }. "Use My Position" raises the same event with no detail, which the
  //               host answers with the player's own position (what every host already did).
  //   on:clear  — remove the placed position
  //   on:toggle — enable/disable (only when `toggleable`)
  // Teleport is handled here (admin only), same call every host already used.
  export let title = '';
  export let description = '';
  export let pos = null; // { x, y, z, heading } or null when nothing is placed
  export let locked = false;
  export let toggleable = false;
  export let enabled = true;
  export let busy = false;
  export let clearable = true;
  export let note = '';
  export let model = '';   // the ped's model, for the placement hologram (defaults to pos.model)
  // true (the default, for every ped in every event): the hologram starts at the crosshair, in front of the admin, so it
  // appears where they are looking — not frozen at the spot the ped was last placed, which may be far away. Pass false only
  // to reopen it frozen at its saved spot.
  export let startAtCrosshair = true;
  // true: one tight line (status, coordinates, small buttons) for forms that list many peds. Same events, same behaviour.
  export let compact = false;

  const dispatch = createEventDispatcher();

  $: placed = !!pos && pos.x != null;

  // A ped placed/moved while the tablet was away: bring the row into view.
  let rowEl;
  let lastKey;
  let awaitingSet = false;
  function requestSet() {
    awaitingSet = true;
    setTimeout(() => { awaitingSet = false; }, 5000);
    dispatch('set');
  }
  // The hologram: the game window takes over (the tablet steps aside), the admin places the ped, and the tablet returns.
  let placing = false;
  let placeNote = '';
  async function placeWithHologram() {
    if (placing || busy || locked) return;
    placing = true;
    placeNote = '';
    let res = null;
    try {
      res = await startHarbourPlacer({
        kind: 'ped', index: 1, model: model || pos?.model || '', label: title,
        ...(startAtCrosshair ? {} : { x: pos?.x, y: pos?.y, z: pos?.z, heading: pos?.heading }),
      });
    } catch (e) { res = null; }
    placing = false;
    if (!res) { placeNote = 'The game did not answer — is the resource running?'; return; }
    if (!res.ok) {
      if (res.error === 'busy') placeNote = 'A placer is already open.';
      else if (res.error) placeNote = 'The hologram could not start (the ped model may be missing in this game build).';
      return;   // cancelled: nothing changes
    }
    awaitingSet = true;
    setTimeout(() => { awaitingSet = false; }, 5000);
    dispatch('set', { x: res.x, y: res.y, z: res.z, heading: res.heading });
  }

  $: key = placed ? `${pos.x},${pos.y},${pos.z}` : null;
  $: if (key !== lastKey) {
    const first = lastKey === undefined;
    lastKey = key;
    // Only for a placement the admin just asked for — never when a saved
    // convoy loads into the form and fills the row.
    if (!first && key && awaitingSet) { awaitingSet = false; setTimeout(() => reveal(rowEl), 150); }
  }
  $: fmt = (n) => Number(n || 0).toFixed(1);
  $: status = toggleable && !enabled ? 'disabled' : placed ? 'placed' : 'empty';
  $: statusLabel = status === 'disabled' ? 'Disabled' : status === 'placed' ? 'Placed' : 'Not placed';
</script>

{#if compact}
<div class="ped-compact" bind:this={rowEl} class:is-disabled={status === 'disabled'}>
  <span class="badge" class:badge-completed={status === 'placed'} class:badge-scheduled={status === 'empty'} class:badge-draft={status === 'disabled'}>{statusLabel}</span>
  <span class="pc-coords">
    {#if placed}
      <span><em>X</em> {fmt(pos.x)}</span><span><em>Y</em> {fmt(pos.y)}</span><span><em>Z</em> {fmt(pos.z)}</span><span><em>H</em> {Number(pos.heading || 0).toFixed(0)}°</span>
    {:else}
      <span class="ped-none">No position yet. Press Hologram, aim where the ped should stand and confirm.</span>
    {/if}
  </span>
  <span class="pc-actions">
    {#if !locked}
      <button type="button" class="btn btn-primary" disabled={busy || placing} on:click={placeWithHologram} title="A see-through copy of the ped follows your crosshair. F freezes it, G puts it on the ground, E confirms."><Icon name="eye" size={14} /> {placing ? 'Placing…' : (placed ? 'Move' : 'Hologram')}</button>
      <button type="button" class="btn btn-steel" disabled={busy || placing} on:click={requestSet} title="Put the ped exactly where you are standing now"><Icon name="pin" size={14} /> My position</button>
    {/if}
    {#if placed && $bootstrap?.isAdmin}
      <button type="button" class="btn btn-steel" on:click={() => teleportToPosition(pos.x, pos.y, pos.z, pos.heading || 0)} title="Teleport to this ped"><Icon name="teleport" size={14} /> Teleport</button>
    {/if}
    <slot name="actions" />
    {#if placed && clearable && !locked}
      <button type="button" class="btn btn-danger" disabled={busy} on:click={() => dispatch('clear')} title="Remove the position"><Icon name="trash" size={14} /></button>
    {/if}
  </span>
  {#if note}<div class="ped-note">{note}</div>{/if}
  {#if placeNote}<div class="ped-note ped-warn">{placeNote}</div>{/if}
</div>
{:else}
<div class="ped-row" bind:this={rowEl} class:is-disabled={status === 'disabled'}>
  <div class="ped-top">
    <div class="ped-icon"><Icon name="user" size={18} /></div>
    <div class="ped-main">
      <div class="ped-title">{title}</div>
      {#if description}<div class="ped-desc">{description}</div>{/if}
    </div>
    <span class="badge" class:badge-completed={status === 'placed'} class:badge-scheduled={status === 'empty'} class:badge-draft={status === 'disabled'}>{statusLabel}</span>
  </div>

  <div class="ped-coords">
    {#if placed}
      <span><em>X</em> {fmt(pos.x)}</span>
      <span><em>Y</em> {fmt(pos.y)}</span>
      <span><em>Z</em> {fmt(pos.z)}</span>
      <span><em>Heading</em> {Number(pos.heading || 0).toFixed(0)}°</span>
    {:else}
      <span class="ped-none">No position set — press Place with Hologram, aim where the ped should stand and confirm.</span>
    {/if}
  </div>

  {#if note}<div class="ped-note">{note}</div>{/if}
  {#if placeNote}<div class="ped-note ped-warn">{placeNote}</div>{/if}

  <div class="ped-actions">
    {#if !locked}
      <button type="button" class="btn btn-primary" disabled={busy || placing} on:click={placeWithHologram} title="A see-through copy of the ped follows your crosshair. F freezes it, G puts it on the ground, E confirms.">
        <Icon name="eye" size={15} /> {placing ? 'Placing…' : (placed ? 'Move with Hologram' : 'Place with Hologram')}
      </button>
      <button type="button" class="btn btn-steel" disabled={busy || placing} on:click={requestSet} title="Put the ped exactly where you are standing now">
        <Icon name="pin" size={15} /> Use My Position
      </button>
    {/if}
    {#if placed && $bootstrap?.isAdmin}
      <button type="button" class="btn btn-steel" on:click={() => teleportToPosition(pos.x, pos.y, pos.z, pos.heading || 0)}>
        <Icon name="teleport" size={15} /> Teleport
      </button>
    {/if}
    {#if toggleable && !locked}
      <button type="button" class="btn btn-secondary" disabled={busy} on:click={() => dispatch('toggle')}>
        {enabled ? 'Disable' : 'Enable'}
      </button>
    {/if}
    <slot name="actions" />
    {#if placed && clearable && !locked}
      <button type="button" class="btn btn-danger" disabled={busy} on:click={() => dispatch('clear')}>
        <Icon name="trash" size={15} /> Remove
      </button>
    {/if}
  </div>

  <slot />
</div>
{/if}

<style>
  .ped-row {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px 18px;
    margin-bottom: 12px;
    background: var(--tablet-panel, #181b1f);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-panel);
    box-shadow: none;
  }
  .ped-row.is-disabled {
    opacity: 0.8;
  }
  .ped-top {
    display: flex;
    align-items: flex-start;
    gap: 14px;
  }
  .ped-icon {
    width: 40px;
    height: 40px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--btn-secondary-bg, #1f2328);
    border: 1px solid var(--btn-secondary-border, #2a2e35);
    border-radius: var(--r-tag);
    color: var(--accent-primary-light);
  }
  .ped-main {
    flex: 1;
    min-width: 0;
  }
  .ped-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .ped-desc {
    margin-top: 4px;
    font-size: var(--fs-small);
    line-height: 1.55;
    color: var(--text-dim);
  }
  .ped-coords {
    display: flex;
    flex-wrap: wrap;
    gap: 8px 22px;
    padding: 10px 14px;
    background: var(--tablet-bg, #131518);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-panel);
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    color: var(--lt-ffffff, #fff);
  }
  .ped-coords em {
    font-style: normal;
    margin-right: 6px;
    color: var(--text-muted);
  }
  .ped-none {
    font-family: var(--font-ui);
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .ped-note {
    font-size: var(--fs-small);
    line-height: 1.5;
    color: var(--accent-primary-light);
  }
  .ped-warn {
    color: var(--lt-f0c36d, #f0c36d);
  }
  .ped-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }

  /* compact: one line */
  .ped-compact { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 12px; padding: 7px 10px; margin-bottom: 0; background: var(--tablet-panel-alt, var(--tablet-panel)); border: 1px solid var(--tablet-border); border-radius: var(--r-panel); }
  .ped-compact.is-disabled { opacity: 0.8; }
  .pc-coords { display: flex; flex-wrap: wrap; gap: 4px 14px; flex: 1 1 220px; min-width: 0; font-family: var(--font-mono); font-size: var(--fs-small); color: var(--lt-ffffff, #fff); }
  .pc-coords em { font-style: normal; margin-right: 4px; color: var(--text-muted); }
  .pc-actions { display: flex; flex-wrap: wrap; gap: 6px; margin-left: auto; }
  .pc-actions :global(.btn) { padding: 5px 11px; font-size: var(--fs-small); min-height: 30px; }
  .ped-compact .ped-note { flex: 1 1 100%; font-size: var(--fs-small); }
</style>
