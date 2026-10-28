<script>
  // The "Props" tab every event uses. The Prop Placer is the single source of truth: this panel shows exactly what
  // the placer saved, opens it on that same list, and files what comes back.
  //
  //   <PropsPanel bind:props={form.props} bind:checkpoints={form.checkpoints} route={form.route} eventKey={id}
  //               context="event" {guides} {locked} />
  //
  //  · The list is the event's own objects (form.props) PLUS, for a convoy, every checkpoint's stored objects
  //    (cp.barricadeProps / cp.decorVehicles) - so "0 placed" can only mean nothing is saved anywhere.
  //  · Stored Props / Stored Vehicles count the SAVED data, never the entities currently in the world.
  //  · PROP SPAWN MODE only shows / hides this saved layout in the world for the admin (local copies, tracked by
  //    event id + object id so the same layout is never doubled). It never edits or deletes the saved data;
  //    the live event spawns its own objects when it starts and removes them when it ends.
  import { onMount, onDestroy } from 'svelte';
  import { bootstrap, tabletOpen } from '../../stores.js';
  import { get } from 'svelte/store';
  import { openPropPlacer, previewPlacedProps, clearPlacedPreview, placedPreviewStatus } from '../../api/placer.js';
  import { teleportToPosition } from '../../api/route.js';
  import { vehicleSetFrom, collectObjects, distributeObjects, centroidOf, objectKey } from './propData.js';
  import Icon from './Icon.svelte';
  import PropTable from './PropTable.svelte';
  import SpawnModeStrip from './SpawnModeStrip.svelte';
  import '../tablet-theme.css';

  export let props = [];
  export let checkpoints = null;      // convoy: its checkpoints (their stored objects are part of this list)
  export let withCheckpoints = true;  // false for every event that has no checkpoints of its own
  export let route = [];
  export let eventKey = 'draft';
  export let context = 'event';
  export let title = 'Event props';
  export let startCategory = undefined;
  export let locked = false;
  export let guides = undefined;

  let propSpawnMode = false;
  let busy = false;
  let notice = '';
  let failures = [];
  let nonce = 0;
  let refreshTimer = null;

  const FAIL_REASON = {
    model_not_in_game: 'this model does not exist in this game build',
    model_load_timeout: 'the model did not load in time',
    create_failed: 'the game refused to create it',
    bad_position: 'its saved position is invalid',
    no_model: 'it has no model',
  };

  $: vset = vehicleSetFrom($bootstrap);
  $: hasCps = withCheckpoints && Array.isArray(checkpoints) && checkpoints.length > 0;
  $: all = collectObjects({ props, checkpoints: hasCps ? checkpoints : [] }, vset);
  $: spawnList = all.map((o) => ({ ...o, key: objectKey(eventKey, o) }));
  $: zoneLabels = Object.fromEntries((checkpoints || []).map((cp, i) => [cp.routePointId, cp.label || `Checkpoint #${i + 1}`]));
  $: zoneOf = (o) => (o.cpId ? (zoneLabels[o.cpId] || 'Checkpoint') : '');
  $: maxItems = 150;

  $: intro = hasCps
    ? 'Using the Prop Placer, you can add props and vehicles directly inside the checkpoint zones (or anywhere else on the route). All placed objects will be saved with the event and used automatically.'
    : 'Using the Prop Placer, you can add props and vehicles anywhere for this event. All placed objects will be saved with the event and used automatically.';

  // Files a changed flat list back where it belongs (event list / checkpoint) - the single write path.
  function commit(list) {
    if (hasCps) {
      const res = distributeObjects(list, { checkpoints, route }, vset);
      props = res.props;
      checkpoints = checkpoints;
    } else {
      props = list.map(({ cpId, ...o }) => o);
    }
  }

  async function openPlacer(opts = {}) {
    if (busy || locked) return;
    busy = true;
    notice = '';
    const wasOn = propSpawnMode;
    let res = null;
    try {
      res = await openPropPlacer({
        context,
        title,
        objects: all,
        // no fixed anchor: the placer starts over the props that are placed now, or at the player when there are none
        // (an anchor like the route's first point kept pulling the camera to where props used to be)
        focus: opts.focus || undefined,
        startCategory,
        selectIndex: opts.selectIndex,
        guides,
      });
    } catch (e) { res = null; }
    busy = false;
    if (res && res.ok && Array.isArray(res.objects)) {
      commit(res.objects);
      notice = `Saved ${res.objects.length} object${res.objects.length === 1 ? '' : 's'} in the event configuration.`;
    } else if (res && res.error === 'busy') {
      notice = 'The Prop Placer is already open.';
    } else if (res && res.error === 'placer_error') {
      notice = 'The placer stopped on an error — nothing was changed (details in F8).';
    }
    // opening the placer clears the in-world copies; Spawn Mode comes back on its own with the saved layout
    if (wasOn) { propSpawnMode = true; nonce += 1; }
  }

  const place = () => openPlacer();
  // Preview: the same placer, on the stored objects, starting over their area - nothing is created or duplicated
  const previewStored = () => openPlacer({ focus: centroidOf(all) || undefined });
  const editObject = (e) => openPlacer({ selectIndex: e.detail + 1 });

  function teleport(e) {
    const o = all[e.detail];
    if (o && o.x != null) teleportToPosition(o.x, o.y, o.z, o.heading || 0);
  }
  const removeObject = (e) => commit(all.filter((_, i) => i !== e.detail));
  const removeEverything = () => commit([]);
  const bulk = (e) => commit(all.map((o) => ({ ...o, ...e.detail })));

  // ── PROP SPAWN MODE (runtime view only) ─────────────────────────────────────
  async function runSpawn(list) {
    if (!propSpawnMode) return;
    let res = null;
    try { res = await previewPlacedProps(list); } catch (e) { res = null; }
    if (!propSpawnMode) { clearPlacedPreview(); return; }      // switched off while it was spawning
    if (!res) { notice = 'The game did not answer — is the resource running?'; return; }
    failures = Array.isArray(res.failed) ? res.failed : [];
    if (failures.length) console.warn('[NovaConvoy] Prop Spawn Mode — not spawned:', failures);
    const bits = [`${res.spawned || 0} spawned`];
    if (res.reused) bits.push(`${res.reused} already standing`);
    notice = failures.length
      ? `Prop Spawn Mode: ON — ${bits.join(', ')}, ${failures.length} FAILED (listed below).`
      : `Prop Spawn Mode: ON — ${list.length} saved object${list.length === 1 ? '' : 's'} in the world (${bits.join(', ')}).`;
  }

  function scheduleSpawn(list) {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => runSpawn(list), 150);
  }
  // runs whenever the saved layout changes while the mode is on (add / edit / remove all show up immediately)
  $: if (propSpawnMode && !busy) scheduleSpawn(spawnList, nonce);

  function togglePropSpawnMode() {
    if (propSpawnMode) {
      propSpawnMode = false;
      window.__novaSpawnOwner = null;
      clearTimeout(refreshTimer);
      clearPlacedPreview();
      failures = [];
      notice = 'Prop Spawn Mode: OFF — world copies removed. The saved props and vehicles are untouched.';
      return;
    }
    failures = [];
    propSpawnMode = true;
    window.__novaSpawnOwner = `props:${eventKey}`;
    notice = all.length ? 'Prop Spawn Mode: ON — spawning the saved layout…' : 'Prop Spawn Mode: ON — nothing is saved yet; whatever you place will appear here.';
  }

  function handleMessage(e) {
    if (e && e.data && e.data.action === 'propSpawnMode:reset' && !busy) { propSpawnMode = false; window.__novaSpawnOwner = null; }
  }

  // Closing the tablet (Esc) unmounts this panel but the preview keeps standing so it can be walked up to; it is only
  // removed when the mode is turned off, when this panel is left with the tablet open, or by the server. Reopening the
  // tablet picks the standing preview up again.
  onMount(async () => {
    window.addEventListener('message', handleMessage);
    if (window.__novaSpawnOwner !== `props:${eventKey}`) return;
    try {
      const s = await placedPreviewStatus();
      if (s && s.count > 0) { propSpawnMode = true; notice = 'Prop Spawn Mode: ON — the preview from before is still standing.'; }
      else window.__novaSpawnOwner = null;
    } catch (e) { /* stays off */ }
  });
  onDestroy(() => {
    window.removeEventListener('message', handleMessage);
    clearTimeout(refreshTimer);
    if (propSpawnMode && get(tabletOpen)) { clearPlacedPreview(); window.__novaSpawnOwner = null; }
  });
</script>

<section class="props-panel-root">
  <header class="card-head">
    <div class="card-head-left">
      <div class="step"><Icon name="box" size={14} /></div>
      <div class="text">
        <h3>{title}</h3>
        <p>{intro}</p>
      </div>
    </div>
    <div class="card-head-actions">
      <button type="button" class="btn btn-sm btn-primary" on:click={place} disabled={locked || busy}>
        <Icon name="move" size={12} /><span>{busy ? 'Placer open…' : (all.length ? 'Open in Prop Placer' : 'Place with Prop Placer')}</span>
      </button>
      <button type="button" class="btn btn-sm btn-steel" on:click={previewStored} disabled={locked || busy || !all.length} title="Open the Prop Placer on the stored objects, starting over their area">
        <Icon name="eye" size={12} /><span>Preview</span>
      </button>
    </div>
  </header>

  <!-- PROP SPAWN MODE: runtime view of the saved layout; never edits it -->
  <SpawnModeStrip active={propSpawnMode} on:toggle={togglePropSpawnMode} />

  {#if notice}<p class="notice">{notice}</p>{/if}
  {#if failures.length}
    <ul class="failures">
      {#each failures as f}<li><b>{f.model}</b> ({f.key}) — {FAIL_REASON[f.reason] || f.reason}</li>{/each}
    </ul>
  {/if}

  <PropTable
    items={all}
    {zoneOf}
    {locked}
    {busy}
    {maxItems}
    on:edit={editObject}
    on:teleport={teleport}
    on:remove={removeObject}
    on:removeAll={removeEverything}
    on:bulk={bulk}
  />
</section>

<style>
  .props-panel-root {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    padding: 14px 18px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-panel);
  }
  .card-head-left {
    display: flex;
    align-items: center;
    gap: 14px;
    flex: 1;
    min-width: 0;
  }
  .text { flex: 1; min-width: 0; }
  .text h3 { margin: 0; font-size: var(--fs-body); font-weight: 700; color: var(--text-main); }
  .text p { margin: 3px 0 0; font-size: var(--fs-small); line-height: 1.45; color: var(--text-dim); }
  .step { flex-shrink: 0; width: 28px; height: 28px; display: grid; place-items: center; border-radius: var(--r-ctl); background: var(--lt-1f2328, #1f2328); border: 1px solid var(--lt-2a2e35, #2a2e35); color: var(--lt-7bb6f2, #7bb6f2); }
  .card-head-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }
  .card-head-actions :global(.btn) {
    min-height: 34px;
    font-size: var(--fs-small);
  }

  .notice { margin: 0; padding: 8px 12px; border-radius: var(--r-panel); font-size: var(--fs-small); color: var(--lt-f0c36d, #f0c36d); background: var(--c-raised); border: 1px solid var(--c-line);
    border-left: 3px solid rgb(255, 200, 87);}
  .failures { margin: 0; padding: 8px 12px 8px 28px; border-radius: var(--r-panel); font-size: var(--fs-meta); line-height: 1.6; color: var(--lt-ff9d94, #ff9d94); background: var(--c-raised); border: 1px solid var(--c-line);
    border-left: 3px solid rgb(255, 93, 80);}
  .failures b { color: var(--lt-ffffff, #fff); font-family: var(--font-mono); font-weight: 600; }
</style>
