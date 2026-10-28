<script>
  // World Peds: the permanent peds that belong to no event. They stand where they are placed here, all the time, for
  // everyone — whether or not any race or TDM event exists. Moving or switching one off applies at once, no restart.
  import { onMount } from 'svelte';
  import { listWorldPeds, setWorldPed, setWorldPedEnabled } from '../../api/worldPeds.js';
  import Icon from '../ui/Icon.svelte';
  import PedRow from '../ui/PedRow.svelte';
  import '../tablet-theme.css';

  // what each ped is for (the server only knows id / label / model / position)
  const ABOUT = {
    token_vendor: {
      title: 'Race Token Vendor',
      description: 'Anyone with race tokens can trade them here for a special vehicle. The tokens come from finishing gang rallies; the ped itself is always there.',
    },
    practice: {
      title: 'TDM Practice Range Instructor',
      description: 'Gang members start a solo or squad TDM practice session from this ped. Anyone who is not in a gang is told so.',
    },
  };

  let peds = [];
  let loading = true;
  let busy = {};
  let note = {};
  let error = '';

  async function load() {
    const res = await listWorldPeds();
    if (res && res.ok) peds = res.peds || [];
    else error = (res && res.error) || 'Could not load the peds.';
    loading = false;
  }
  onMount(load);

  const posOf = (p) => (p && p.x != null ? { x: p.x, y: p.y, z: p.z, heading: p.heading, model: p.model } : null);

  function patch(id, entry) {
    peds = peds.map((p) => (p.id === id ? { ...p, ...entry } : p));
  }

  async function place(id, e) {
    busy = { ...busy, [id]: true };
    note = { ...note, [id]: '' };
    const placed = e?.detail?.x != null ? e.detail : null;     // the hologram's spot, else the server uses where you stand
    const res = await setWorldPed(id, placed);
    busy = { ...busy, [id]: false };
    if (res && res.ok) { patch(id, res.ped); note = { ...note, [id]: placed ? 'Moved — it is there for everyone now.' : 'Moved to where you are standing.' }; }
    else note = { ...note, [id]: (res && res.error) || 'Could not move the ped.' };
  }

  async function toggle(id) {
    const cur = peds.find((p) => p.id === id);
    if (!cur) return;
    busy = { ...busy, [id]: true };
    const res = await setWorldPedEnabled(id, !cur.enabled);
    busy = { ...busy, [id]: false };
    if (res && res.ok) patch(id, res.ped);
    else note = { ...note, [id]: (res && res.error) || 'Could not change the ped.' };
  }
</script>

<div class="panel view-enter">
  <div class="panel-header"><span class="panel-title"><Icon name="user" size={14} /> World Peds</span></div>
  <div class="panel-body">
    <p class="intro">Permanent peds that are not tied to any event. They stay in the world wherever you place them, whether or not a race or TDM event exists. Changes apply to everyone online immediately — no restart.</p>

    {#if error}<div class="gt-error">{error}</div>{/if}
    {#if loading}
      <div class="empty">Loading…</div>
    {:else}
      {#each peds as p (p.id)}
        <PedRow
          title={ABOUT[p.id]?.title || p.label}
          description={ABOUT[p.id]?.description || ''}
          pos={posOf(p)}
          model={p.model || ''}
          toggleable
          startAtCrosshair
          enabled={p.enabled}
          busy={!!busy[p.id]}
          clearable={false}
          note={note[p.id] || ''}
          on:set={(e) => place(p.id, e)}
          on:toggle={() => toggle(p.id)}
        />
      {/each}
    {/if}
  </div>
</div>

<style>
  .intro { margin: 0 0 14px; color: var(--text-dim, #c9ced4); font-size: var(--fs-body); line-height: 1.55; }
  .empty { padding: 24px; text-align: center; color: var(--text-dim, #aeb5bd); }
  .gt-error { margin-bottom: 12px; padding: 10px 14px; border-radius: var(--r-ctl); background: var(--c-raised); border: 1px solid var(--c-line); color: var(--lt-ff9d94, #ff9d94);
    border-left: 3px solid rgb(255, 93, 80);}
</style>
