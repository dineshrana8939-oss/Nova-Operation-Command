<script>
  import { onMount, onDestroy } from 'svelte';
  import { peek, keep } from '../ui/viewCache.js';
  import { getSavedRoutes, getSavedRouteDetail, deleteRouteTemplate, deleteAllRouteTemplates, saveRouteTemplate, updateRouteTemplate } from '../../api/savedRoutes.js';
  import { startRouteRecording, teleportToPosition, testContainerWarsCrane, testRaceRoute } from '../../api/route.js';
  import { confirmAction } from '../ui/confirm.js';
  import { perms } from '../../perms.js';
  import { bootstrap, routeRecordingResult } from '../../stores.js';
  import Icon from '../ui/Icon.svelte';
  import { kindMeta, kindTag, statusTag } from '../ui/badges.js';
  import RoutePreviewMap from '../ui/RoutePreviewMap.svelte';
  import tabletBg from '../../../assets/tablet-bg.jpg';

  let renameModal = null;
  let renaming = false;
  let renameError = '';

  function openRename(r) {
    if (r.prebuilt) return;
    renameError = '';
    renameModal = { id: r.id, name: r.name, oldName: r.name };
  }

  async function submitRename() {
    if (!renameModal) return;
    const trimmed = renameModal.name.trim();
    if (trimmed.length < 2) {
      renameError = 'Name must be at least 2 characters.';
      return;
    }
    renaming = true;
    renameError = '';
    const res = await updateRouteTemplate(renameModal.id, { name: trimmed });
    renaming = false;
    if (!res || !res.ok) {
      renameError = (res && res.error) || 'Failed to rename route template.';
      return;
    }
    renameModal = null;
    await refresh();
  }

  // Own top-level tablet section (sidebar nav, same level as Announcements/
  // Gangs & Permissions) — dedicated purely to VIEWING and MANAGING every
  // saved route template server-wide: search, see who made it and when,
  // preview it on the map, delete one, or wipe all of them. Actually
  // IMPORTING a template into a convoy still happens from that convoy's own
  // Route tab (the compact picker there), since importing only makes sense
  // with a specific convoy open to import INTO — there's no "convoy"
  // context here to import into.
  // Colors match TYPE_COLOR_JS.ROUTE (mapGeometry.js) for CONVOY, the Hot
  // Cargo banner's own accent for HOT_CARGO, and TYPE_COLOR_JS.AIRDROP /
  // AirdropZones' own zone-card border for GANG_AIRDROP — same accent a
  // saved template of that kind is already shown in on its own config screen.
  const KIND_INFO = {
    CONVOY: { label: 'Convoy', color: '#ee8a2b' },
    HOT_CARGO: { label: 'Hot Cargo', color: '#e0489f' },
    GANG_AIRDROP: { label: 'Airdrop', color: '#9b7bff' },
    GANG_RACE: { label: 'Rally Race', color: '#22c7d6' },
    CONTAINER_WARS: { label: 'Container Yard', color: '#ffc857' },
  };
  function kindInfo(kind) {
    return KIND_INFO[kind] || KIND_INFO.CONVOY;
  }

  let savedRoutes = peek('savedRoutes') || [];
  let search = '';
  let filterKind = 'ALL';
  let loading = !peek('savedRoutes');
  let error = '';

  $: filtered = savedRoutes.filter((r) => {
    const matchesSearch = !search.trim() || r.name.toLowerCase().includes(search.trim().toLowerCase());
    const matchesKind = filterKind === 'ALL' || r.kind === filterKind;
    return matchesSearch && matchesKind;
  });

  // ── paging: 121 routes in one list is a lot to scroll ──────────────────────
  let page = 1;
  let pageSize = 20;   // 0 = all
  $: totalPages = pageSize === 0 ? 1 : Math.max(1, Math.ceil(filtered.length / pageSize));
  $: if (page > totalPages) page = totalPages;
  $: pageStart = pageSize === 0 ? 0 : (page - 1) * pageSize;
  $: pageRows = pageSize === 0 ? filtered : filtered.slice(pageStart, pageStart + pageSize);
  // a new search or type filter starts again from the first page
  let lastFilterKey = '';
  $: {
    const key = `${search}|${filterKind}`;
    if (key !== lastFilterKey) { lastFilterKey = key; page = 1; }
  }

  async function refresh() {
    if (!peek('savedRoutes')) loading = true;
    const res = await getSavedRoutes();
    loading = false;
    if (res && res.ok) {
      savedRoutes = keep('savedRoutes', res.routes);
    } else {
      error = (res && res.error) || 'Failed to load saved route templates.';
    }
  }

  onMount(refresh);

  function formatDate(ts) {
    if (!ts) return '';
    const d = new Date(ts);
    if (isNaN(d.getTime())) return '';
    return `${d.toLocaleDateString()} ${d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
  }

  // Prebuilt tracks are built in — only templates users created can be deleted.
  $: customCount = savedRoutes.filter((r) => !r.prebuilt).length;

  async function deleteOne(r) {
    if (r.prebuilt) return;
    const ok = await confirmAction(`Delete the saved route "${r.name}"? This can't be undone.`, { title: 'Delete Route Template', danger: true });
    if (!ok) return;
    error = '';
    const res = await deleteRouteTemplate(r.id);
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to delete route template.'; return; }
    await refresh();
  }

  // ── multi-select delete ────────────────────────────────────────────────────
  // Ticked template ids; always reassigned (never mutated) so the template re-renders. They survive paging and
  // filtering, so a selection can be built up across pages. Prebuilt tracks can't be ticked.
  let selectedIds = [];
  let bulkDeleting = false;
  $: canDelete = !!$perms['savedroutes.delete'];
  $: selectableFiltered = filtered.filter((r) => !r.prebuilt);
  $: pageSelectable = pageRows.filter((r) => !r.prebuilt);
  $: selectedCount = savedRoutes.filter((r) => !r.prebuilt && selectedIds.includes(r.id)).length;
  $: pageSelectedCount = pageSelectable.filter((r) => selectedIds.includes(r.id)).length;

  function toggleSelected(id) {
    selectedIds = selectedIds.includes(id) ? selectedIds.filter((x) => x !== id) : [...selectedIds, id];
  }

  function togglePageSelected() {
    const ids = pageSelectable.map((r) => r.id);
    selectedIds = pageSelectedCount === ids.length
      ? selectedIds.filter((x) => !ids.includes(x))
      : [...new Set([...selectedIds, ...ids])];
  }

  async function deleteSelected() {
    const targets = savedRoutes.filter((r) => !r.prebuilt && selectedIds.includes(r.id));
    if (targets.length === 0 || bulkDeleting) return;
    const ok = await confirmAction(`Delete the ${targets.length} selected saved route template${targets.length === 1 ? '' : 's'}? This can't be undone.`, { title: 'Delete Selected Templates', danger: true, confirmLabel: 'Yes, Delete Selected' });
    if (!ok) return;
    error = '';
    bulkDeleting = true;
    let failed = 0;
    let lastError = '';
    for (const r of targets) {
      const res = await deleteRouteTemplate(r.id);
      if (!res || !res.ok) { failed++; lastError = (res && res.error) || ''; }
    }
    bulkDeleting = false;
    selectedIds = [];
    if (failed > 0) error = `${failed} of ${targets.length} templates could not be deleted${lastError ? `: ${lastError}` : '.'}`;
    await refresh();
  }

  async function deleteAll() {
    if (customCount === 0) return;
    const ok = await confirmAction(`Delete all ${customCount} custom saved route templates? Prebuilt tracks are kept. This can't be undone.`, { title: 'Delete All Route Templates', danger: true, confirmLabel: 'Yes, Delete Everything' });
    if (!ok) return;
    error = '';
    const res = await deleteAllRouteTemplates();
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to delete all route templates.'; return; }
    search = '';
    await refresh();
  }

  // Preview mode — clicking Preview swaps the whole screen to just the map
  // (no vectors/coordinates, same RoutePreviewMap used in every event's own
  // config screen) with a Back button, rather than an inline expansion, so
  // the list underneath stays clean either way. RoutePreviewMap already
  // knows how to draw all three shapes (hotCargo / zones / route), so this
  // just picks which props to feed it based on the saved row's own kind.
  let previewing = null; // { name, kind, route, checkpoints, airdrops, hotCargo, zones, rallyStages } | null
  let previewLoading = false;
  let previewError = '';

  async function openPreview(r) {
    previewLoading = true;
    previewError = '';
    const res = await getSavedRouteDetail(r.id);
    previewLoading = false;
    if (!res || !res.ok) { previewError = (res && res.error) || 'Failed to load route preview.'; return; }
    const kind = res.kind || 'CONVOY';
    // a container yard is shown as its pickup spots, then its drop spots
    const yard = kind === 'CONTAINER_WARS' ? ((res.containerWars || {}).yard || {}) : null;
    const yardRoute = yard
      ? [
          ...(yard.pickups || []).map((p, i) => ({ id: 'pk' + i, order: i, x: p.x, y: p.y, z: p.z, heading: p.heading || 0, type: 'ROUTE' })),
          ...(yard.drops || []).map((p, i) => ({ id: 'dp' + i, order: 100 + i, x: p.x, y: p.y, z: p.z, heading: p.heading || 0, type: 'DESTINATION' })),
        ]
      : null;
    previewing = {
      id: r.id,
      name: r.name,
      kind,
      route: yardRoute || res.route || [],
      checkpoints: res.checkpoints || [],
      airdrops: res.airdrops || [],
      hotCargo: kind === 'HOT_CARGO' ? { spawnZones: res.spawnZones || [], dropoffZones: res.dropoffZones || [] } : null,
      zones: kind === 'GANG_AIRDROP' ? (res.airdropZones || []) : [],
      rallyStages: kind === 'GANG_RACE' ? (res.rallyStages || []) : [],
    };
  }

  function closePreview() {
    previewing = null;
  }

  // ── Teleport / Test run ──
  // Go to where a saved template is (its first point) to see it in the world. A saved Container Wars yard can also
  // be played with the crane Test Run right from here, without loading it into the harbour first.
  let goBusy = '';
  let goNote = '';
  const hasXY = (p) => p && p.x != null && p.y != null;
  function firstPointOf(res) {
    const kind = res.kind || 'CONVOY';
    if (kind === 'CONTAINER_WARS') {
      const y = (res.containerWars || {}).yard || {};
      return [...(y.pickups || []), ...(y.drops || []), ...(y.dummies || [])].find(hasXY) || null;
    }
    if (kind === 'HOT_CARGO') return [...(res.spawnZones || []), ...(res.dropoffZones || [])].find(hasXY) || null;
    if (kind === 'GANG_AIRDROP') return (res.airdropZones || []).find(hasXY) || null;
    if (kind === 'GANG_RACE') return (res.rallyStages || []).find(hasXY) || (res.route || []).find(hasXY) || null;
    return (res.route || []).find(hasXY) || null;
  }
  async function teleportToTemplate(r) {
    if (goBusy) return;
    goBusy = 'tp:' + r.id;
    goNote = '';
    const res = await getSavedRouteDetail(r.id);
    const p = res && res.ok ? firstPointOf(res) : null;
    if (p) await teleportToPosition(p.x, p.y, (Number(p.z) || 0) + 1.0);
    else goNote = `"${r.name}" has no position to go to.`;
    goBusy = '';
  }

  let cwModal = null; // { route, res, yard, pickups, cranes }

  async function startContainerTestModal(r) {
    if (goBusy) return;
    goBusy = 'run:' + r.id;
    goNote = '';
    const res = await getSavedRouteDetail(r.id);
    goBusy = '';
    if (!res || !res.ok) {
      goNote = (res && res.error) || 'Failed to load route template detail.';
      return;
    }
    const yard = (res.containerWars || {}).yard || {};
    const pickups = yard.pickups || [];
    const cranes = yard.cranes || (yard.crane && yard.crane.x != null ? [yard.crane] : []);
    if (pickups.length <= 1 && cranes.length <= 1) {
      await testRunTemplate(r, 1, false, res);
      return;
    }
    cwModal = { route: r, res, yard, pickups, cranes };
  }

  async function testRunTemplate(r, index = 1, cycleAll = false, cachedRes = null) {
    if (goBusy) return;
    goBusy = 'run:' + r.id;
    goNote = '';
    cwModal = null;
    const res = cachedRes || await getSavedRouteDetail(r.id);
    if (!res || !res.ok) {
      goNote = (res && res.error) || 'Failed to load route template detail.';
      goBusy = '';
      return;
    }

    if (r.kind === 'GANG_RACE') {
      const stages = res.rallyStages || [];
      if (!stages.length) {
        goNote = `"${r.name}" has no stages configured to test.`;
        goBusy = '';
        return;
      }
      const startPt = stages.find((s) => s.kind === 'START') || stages[0];
      if (hasXY(startPt)) {
        await teleportToPosition(startPt.x, startPt.y, (Number(startPt.z) || 0) + 1.0, startPt.heading || 0);
      }
      const raceProps = res.eventProps || res.props || [];
      const run = await testRaceRoute({
        stages,
        props: raceProps,
      });
      if (run && run.ok === false) {
        goNote = 'The race test run could not start.';
      }
      goBusy = '';
      return;
    }

    const yard = (res.containerWars || {}).yard;
    const pick = yard && (yard.pickups || [])[index - 1];
    const drop = yard && ((yard.drops || [])[index - 1] || (yard.drops || [])[0]);
    if (!yard || !hasXY(drop)) {
      goNote = `"${r.name}" needs a drop spot to run the crane test.`;
      goBusy = '';
      return;
    }
    const near = hasXY(pick) ? pick : drop;
    const d = $bootstrap?.containerWars?.defaults || {};
    await teleportToPosition(near.x + 12, near.y, (Number(near.z) || 0) + 1.0);
    const run = await testContainerWarsCrane({
      model: (pick && (pick.model || pick.mapModel)) || 'prop_container_05a',
      index,
      cycleAll,
      yard,
      props: res.eventProps || (yard && yard.props) || [],
      travelSeconds: Number(d.craneTravelSeconds) || 8,
      liftHeight: Number(d.craneLiftHeight) || 12,
      carryPath: d.carryPath,
      carryCurve: d.carryCurve,
    });
    if (run && run.ok === false) goNote = run.error === 'missing_positions' ? 'That layout has no drop spot for this container.' : 'The test run could not start.';
    goBusy = '';
  }

  // ── Standalone Route Recording by Driving ──
  let recordingModal = false;
  let recordTargetKind = 'GANG_RACE';
  let savePromptModal = false;
  let recordedPointsToSave = [];
  let newTemplateName = '';
  let saveError = '';
  let savingRoute = false;

  const unsubRecord = routeRecordingResult.subscribe((msg) => {
    if (!msg || msg.target !== 'SAVED_ROUTES_RECORD') return;
    const pts = msg.points || [];
    routeRecordingResult.set(null);
    if (pts.length > 0) {
      recordedPointsToSave = pts;
      newTemplateName = recordTargetKind === 'GANG_RACE' ? 'New Street Race Track' : 'New Convoy Route';
      savePromptModal = true;
      saveError = '';
    }
  });

  onDestroy(() => {
    unsubRecord();
  });

  function startDriveRecording() {
    recordingModal = false;
    startRouteRecording({ supportsAirdrop: recordTargetKind === 'CONVOY', target: 'SAVED_ROUTES_RECORD' });
  }

  async function saveRecordedRoute() {
    if (!newTemplateName.trim()) {
      saveError = 'Please enter a name for the route.';
      return;
    }
    savingRoute = true;
    saveError = '';
    let payload = {};
    if (recordTargetKind === 'GANG_RACE') {
      const hasDest = recordedPointsToSave.length > 1;
      const rallyStages = recordedPointsToSave.map((p, i) => {
        const isFirst = i === 0;
        const isLast = hasDest && i === recordedPointsToSave.length - 1;
        const kind = isFirst ? 'START' : (isLast ? 'DESTINATION' : 'CHECKPOINT');
        const name = kind === 'START' ? 'Grid Start Line' : (kind === 'DESTINATION' ? 'Finish Line' : `Checkpoint ${i + 1}`);
        return {
          id: 'stage_' + (i + 1),
          order: i,
          name,
          label: name,
          kind,
          x: p.x,
          y: p.y,
          z: p.z,
          heading: p.heading || 0,
          radius: 20,
        };
      });
      payload = { rallyStages };
    } else {
      payload = {
        route: recordedPointsToSave.map((p, i) => ({
          id: 'pt_' + (i + 1),
          order: i,
          x: p.x,
          y: p.y,
          z: p.z,
          heading: p.heading || 0,
          type: p.type || 'ROUTE',
        })),
        checkpoints: [],
        airdrops: [],
      };
    }
    const res = await saveRouteTemplate(newTemplateName.trim(), recordTargetKind, payload);
    savingRoute = false;
    if (res && res.ok) {
      savePromptModal = false;
      recordedPointsToSave = [];
      await refresh();
    } else {
      saveError = (res && res.error) || 'Failed to save route template.';
    }
  }
</script>

<div class="saved-routes-panel view-enter" style="--tablet-bg-img: url('{tabletBg}');">
{#if previewing}
  <div class="header-row">
    <button class="btn btn-back" on:click={closePreview}><Icon name="chevronLeft" size={13} /> Back</button>
    <div class="section-title">
      {previewing.name}
      <span class="tag" style={kindTag(previewing.kind)}>{kindInfo(previewing.kind).label}</span>
    </div>
    <div class="spacer" />
    {#if previewing.id}
      <button class="btn btn-steel" disabled={!!goBusy} on:click={() => teleportToTemplate(previewing)}><Icon name="teleport" size={13} /> Teleport</button>
      {#if previewing.kind === 'CONTAINER_WARS'}
        <button class="btn btn-refresh" disabled={!!goBusy} on:click={() => startContainerTestModal(previewing)}><Icon name="play" size={13} /> Test Run</button>
      {/if}
    {/if}
  </div>
  {#if goNote}<div class="error">{goNote}</div>{/if}
  <RoutePreviewMap
    route={previewing.route}
    checkpoints={previewing.checkpoints}
    airdrops={previewing.airdrops}
    hotCargo={previewing.hotCargo}
    zones={previewing.zones}
    rallyStages={previewing.rallyStages}
    eventKind={previewing.kind}
    height={520}
  />
{:else}
  <div class="header-row">
    <div class="section-title">Saved Route Templates <span class="count">{savedRoutes.length}</span></div>
    <div class="header-actions">
      {#if $perms['savedroutes.create']}
        <button class="btn btn-primary" on:click={() => (recordingModal = true)}>
          <Icon name="pin" size={13} /> Add Route by Driving
        </button>
      {/if}
      {#if $perms['savedroutes.manage']}
        <button class="btn btn-danger" disabled={customCount === 0} title="Deletes only the templates you created — prebuilt tracks are kept" on:click={deleteAll}>
          <Icon name="trash" size={13} /> Delete All Custom
        </button>
      {/if}
    </div>
  </div>

  <p class="hint">
    Every route template saved from any convoy's Route tab or created by driving lives here, independent of whichever event created it. Saved tracks and routes can be immediately selected and used for races or convoys.
  </p>

  <div class="search-row">
    <Icon name="box" size={14} />
    <input type="text" placeholder="Search saved routes by name..." bind:value={search} />
    <select class="type-filter-select" bind:value={filterKind} title="Filter by event type">
      <option value="ALL">All Event Types</option>
      <option value="CONVOY">Convoy</option>
      <option value="HOT_CARGO">Hot Cargo</option>
      <option value="GANG_AIRDROP">Airdrop</option>
      <option value="GANG_RACE">Rally Race</option>
      <option value="CONTAINER_WARS">Container Yard</option>
    </select>
    <div class="pager">
      <button type="button" class="pager-btn" disabled={page <= 1} on:click={() => (page = 1)} title="First page" aria-label="First page">«</button>
      <button type="button" class="pager-btn" disabled={page <= 1} on:click={() => (page = Math.max(1, page - 1))} title="Previous page" aria-label="Previous page">‹</button>
      <span class="pager-info" title="Page {page} of {totalPages}">
        {#if !filtered.length}
          0 of 0
        {:else if pageSize === 0}
          All {filtered.length}
        {:else}
          <b>{pageStart + 1}–{Math.min(pageStart + pageSize, filtered.length)}</b> of {filtered.length}
        {/if}
      </span>
      <button type="button" class="pager-btn" disabled={page >= totalPages} on:click={() => (page = Math.min(totalPages, page + 1))} title="Next page" aria-label="Next page">›</button>
      <button type="button" class="pager-btn" disabled={page >= totalPages} on:click={() => (page = totalPages)} title="Last page" aria-label="Last page">»</button>
      <select class="type-filter-select pager-size" bind:value={pageSize} on:change={() => (page = 1)} aria-label="Routes per page" title="Routes per page">
        <option value={10}>10 / page</option>
        <option value={20}>20 / page</option>
        <option value={50}>50 / page</option>
        <option value={100}>100 / page</option>
        <option value={0}>All</option>
      </select>
    </div>
  </div>

  {#if error}<div class="error">{error}</div>{/if}
  {#if goNote}<div class="error">{goNote}</div>{/if}
  {#if previewError}<div class="error">{previewError}</div>{/if}

  {#if loading}
    <div class="empty-note">Loading...</div>
  {:else if savedRoutes.length === 0}
    <div class="empty-note">No saved route templates yet. Build a route in Create Event → Route/Race Setup tab, then "Save Current As..." to add one here.</div>
  {:else if filtered.length === 0}
    <div class="empty-note">No saved routes match "{search}".</div>
  {:else}
    {#if canDelete}
      <div class="select-bar">
        <span class="select-info">{selectedCount > 0 ? `${selectedCount} selected` : 'Tick the boxes to pick which templates to delete'}</span>
        {#if selectedCount > 0 && selectedCount < selectableFiltered.length}
          <button class="btn btn-steel" on:click={() => (selectedIds = [...new Set([...selectedIds, ...selectableFiltered.map((r) => r.id)])])}>Select all {selectableFiltered.length}</button>
        {/if}
        {#if selectedCount > 0}
          <button class="btn btn-steel" on:click={() => (selectedIds = [])}>Clear</button>
          <button class="btn btn-danger" disabled={bulkDeleting} on:click={deleteSelected}>
            <Icon name="trash" size={13} /> {bulkDeleting ? 'Deleting...' : `Delete Selected (${selectedCount})`}
          </button>
        {/if}
      </div>
    {/if}
    <div class="template-table" class:has-check={canDelete}>
      <div class="table-row table-head">
        {#if canDelete}
          <div class="col-check">
            <input type="checkbox" title="Select every deletable template on this page" disabled={pageSelectable.length === 0}
              checked={pageSelectable.length > 0 && pageSelectedCount === pageSelectable.length}
              indeterminate={pageSelectedCount > 0 && pageSelectedCount < pageSelectable.length}
              on:change={togglePageSelected} />
          </div>
        {/if}
        <div class="col-sno">S.No</div>
        <div class="col-name">Name / Date</div>
        <div class="col-type">Type</div>
        <div class="col-points">Points</div>
        <div class="col-created">Created By</div>
        <div class="col-actions">Actions</div>
      </div>
      {#each pageRows as r, i (r.id)}
        <div class="table-row" class:row-selected={selectedIds.includes(r.id)}>
          {#if canDelete}
            <div class="col-check">
              {#if !r.prebuilt}
                <input type="checkbox" title="Select for bulk delete" checked={selectedIds.includes(r.id)} on:change={() => toggleSelected(r.id)} />
              {/if}
            </div>
          {/if}
          <div class="col-sno">{pageStart + i + 1}</div>
          <div class="col-name" title={r.name}>
            <span class="name-main">{r.name}</span>
            <span class="name-date">{formatDate(r.createdAt) || '—'}</span>
          </div>
          <div class="col-type">
            <span class="tag" style={kindTag(r.kind)}>{kindInfo(r.kind).label}</span>
          </div>
          <div class="col-points">{r.pointCount}</div>
          <div class="col-created" title={r.createdByName || ''}>{r.createdByName || '—'}</div>
          <div class="col-actions">
            {#if r.kind !== 'CONTAINER_WARS'}
              <button class="btn btn-preview" disabled={previewLoading} on:click={() => openPreview(r)}><Icon name="activity" size={13} /> Preview</button>
            {/if}
            <button class="btn btn-steel" disabled={!!goBusy} title="Teleport to this template's first point" on:click={() => teleportToTemplate(r)}><Icon name="teleport" size={13} /> Teleport</button>
            {#if r.kind === 'CONTAINER_WARS'}
              <button class="btn btn-refresh" disabled={!!goBusy} title="Play the test run for this saved layout" on:click={() => startContainerTestModal(r)}><Icon name="play" size={13} /> Test Run</button>
            {/if}
            {#if r.prebuilt}
              <span class="tag" style="background:var(--c-raised); border-color:var(--c-line); color:var(--text-dim);" title="Built-in track — cannot be deleted">Prebuilt</span>
            {:else}
              <button class="btn btn-steel" title="Rename this saved template" on:click={() => openRename(r)}><Icon name="edit" size={13} /> Rename</button>
              {#if $perms['savedroutes.delete']}
                <button class="btn btn-danger" title="Delete this saved template" on:click={() => deleteOne(r)}><Icon name="trash" size={13} /> Delete</button>
              {/if}
            {/if}
          </div>
        </div>
      {/each}
    </div>
  {/if}
{/if}
</div>

{#if renameModal}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="import-backdrop" on:click|self={() => (renameModal = null)}>
    <div class="import-box" style="max-width: 440px;" role="dialog" aria-modal="true">
      <div class="import-head">
        <span class="import-title"><Icon name="edit" size={14} /> Rename Template</span>
        <button class="icon-btn btn-close" on:click={() => (renameModal = null)}><Icon name="x" size={13} /></button>
      </div>
      <div class="rename-body">
        <label for="rename-route-input" class="rename-label">Template name</label>
        <input
          id="rename-route-input"
          type="text"
          class="name-input"
          bind:value={renameModal.name}
          maxlength="100"
          placeholder="Template name"
          on:keydown={(e) => { if (e.key === 'Enter') submitRename(); }}
        />
        <span class="rename-hint">Was “{renameModal.oldName}”. Shown in every Saved Routes list and template picker.</span>
        {#if renameError}
          <div class="error" style="margin: 0;">{renameError}</div>
        {/if}
      </div>
      <div class="import-foot">
        <button class="btn btn-back" on:click={() => (renameModal = null)}>Cancel</button>
        <button class="btn btn-primary" disabled={renaming || !renameModal.name.trim()} on:click={submitRename}>
          {renaming ? 'Updating...' : 'Save Name'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if recordingModal}
  <div class="import-backdrop" on:click|self={() => (recordingModal = false)}>
    <div class="import-box" style="max-width: 440px;">
      <div class="import-head">
        <span class="import-title"><Icon name="pin" size={14} /> Add Route by Driving</span>
        <button class="icon-btn btn-close" on:click={() => (recordingModal = false)}><Icon name="x" size={13} /></button>
      </div>
      <div style="padding: 16px; display: flex; flex-direction: column; gap: 14px;">
        <p class="hint" style="margin: 0;">
          Select the route type to record. The tablet will close, allowing you to drive the route in-game. Press <strong>[E]</strong> to place checkpoints along the road, <strong>[Backspace]</strong> to undo, and <strong>[Enter]</strong> to finish.
        </p>
        <div style="display: flex; gap: 10px;">
          <button
            type="button"
            class="chip-btn"
            style="flex: 1; padding: 10px;"
            class:active={recordTargetKind === 'GANG_RACE'}
            on:click={() => (recordTargetKind = 'GANG_RACE')}
          >
            Rally Race Track
          </button>
          <button
            type="button"
            class="chip-btn"
            style="flex: 1; padding: 10px;"
            class:active={recordTargetKind === 'CONVOY'}
            on:click={() => (recordTargetKind = 'CONVOY')}
          >
            Convoy Route
          </button>
        </div>
      </div>
      <div class="import-foot">
        <button class="btn btn-back" on:click={() => (recordingModal = false)}>Cancel</button>
        <button class="btn btn-primary" on:click={startDriveRecording}>
          <Icon name="pin" size={13} /> Start Recording
        </button>
      </div>
    </div>
  </div>
{/if}

{#if savePromptModal}
  <div class="import-backdrop" on:click|self={() => (savePromptModal = false)}>
    <div class="import-box" style="max-width: 440px;">
      <div class="import-head">
        <span class="import-title"><Icon name="check" size={14} /> Save Recorded Route</span>
        <button class="icon-btn btn-close" on:click={() => (savePromptModal = false)}><Icon name="x" size={13} /></button>
      </div>
      <div style="padding: 16px; display: flex; flex-direction: column; gap: 14px;">
        <p class="hint" style="margin: 0;">
          Recorded <strong>{recordedPointsToSave.length}</strong> points for <strong>{recordTargetKind === 'GANG_RACE' ? 'Race Track' : 'Convoy Route'}</strong>. Enter a template name to save this route.
        </p>
        <div class="search-row" style="margin: 0;">
          <input
            type="text"
            placeholder="Route template name..."
            bind:value={newTemplateName}
            on:keydown={(e) => e.key === 'Enter' && saveRecordedRoute()}
          />
        </div>
        {#if saveError}
          <div class="error" style="margin: 0;">{saveError}</div>
        {/if}
      </div>
      <div class="import-foot">
        <button class="btn btn-back" on:click={() => (savePromptModal = false)}>Cancel</button>
        <button class="btn btn-primary btn-save" disabled={savingRoute} on:click={saveRecordedRoute}>
          {savingRoute ? 'Saving...' : 'Save Template'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if cwModal}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="import-backdrop" on:click|self={() => (cwModal = null)}>
    <div class="import-box" style="max-width: 500px;" role="dialog" aria-modal="true">
      <div class="import-head">
        <span class="import-title"><Icon name="play" size={14} /> Test Run: {cwModal.route.name}</span>
        <button class="icon-btn btn-close" on:click={() => (cwModal = null)}><Icon name="x" size={13} /></button>
      </div>
      <div style="padding: 16px; display: flex; flex-direction: column; gap: 14px;">
        <p class="hint" style="margin: 0;">
          This harbour layout contains <strong>{cwModal.cranes.length} Gantry Crane(s)</strong> and <strong>{cwModal.pickups.length} Container Pickup Spot(s)</strong>.
        </p>
        <div class="cw-modal-actions">
          <button class="btn btn-primary btn-block" on:click={() => testRunTemplate(cwModal.route, 1, true, cwModal.res)}>
            <Icon name="play" size={13} /> <span>Test All Cranes &amp; Containers (Full Cycle)</span>
          </button>
          {#if cwModal.pickups.length > 0}
            <div class="cw-modal-divider"><span>OR TEST SPECIFIC SPOT</span></div>
            <div class="cw-spot-grid">
              {#each cwModal.pickups as p, idx}
                <button class="btn btn-steel" on:click={() => testRunTemplate(cwModal.route, idx + 1, false, cwModal.res)}>
                  <Icon name="truck-ramp-box" size={12} />
                  <span>Spot #{idx + 1} {p.assignedCrane ? `(Crane #${p.assignedCrane})` : ''}</span>
                </button>
              {/each}
            </div>
          {/if}
        </div>
      </div>
      <div class="import-foot">
        <button class="btn btn-back" on:click={() => (cwModal = null)}>Close</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .header-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
    gap: 10px;
  }
  .spacer {
    width: 76px; /* balances the Back button's width so the title stays visually centered */
  }
  .section-title {
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--text-main);
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .count {
    font-size: var(--fs-small);
    font-weight: 500;
    text-transform: none;
    letter-spacing: normal;
    color: var(--text-dim);
  }
  .hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin-bottom: 16px;
  }
  .search-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 16px;
    color: var(--text-dim);
  }
  .search-row input {
    flex: 1;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 10px 12px;
    font-size: var(--fs-body);
  }
  .search-row input:focus {
    outline: none;
    border-color: var(--accent-primary);
  }
  .search-row input::placeholder {
    color: var(--text-placeholder);
  }
  .type-filter-select {
    height: 38px;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 0 12px;
    font-size: var(--fs-small);
    font-weight: 500;
    cursor: pointer;
  }
  .type-filter-select:focus {
    outline: none;
    border-color: var(--accent-primary);
  }
  /* pager: sits in the search row, each part keeps its own width so nothing overlaps */
  .pager { display: inline-flex; align-items: center; gap: 6px; flex: none; white-space: nowrap; }
  .pager-btn {
    width: 34px; height: 38px; padding: 0; display: inline-flex; align-items: center; justify-content: center;
    background: var(--tablet-bg); border: 1px solid var(--tablet-border); border-radius: var(--radius-sm);
    color: var(--text-main); font-size: var(--fs-emph); line-height: 1; cursor: pointer;
  }
  .pager-btn:hover:not(:disabled) { border-color: var(--accent-primary); }
  .pager-btn:disabled { opacity: 0.35; cursor: default; }
  .pager-info { min-width: 86px; text-align: center; font-size: var(--fs-meta); color: var(--text-dim); }
  .pager-info b { color: var(--text-main); font-weight: 600; }
  .pager-size { padding: 0 8px; }
  .btn-block {
    width: 100%;
    justify-content: center;
  }
  .cw-modal-actions {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .cw-modal-divider {
    display: flex;
    align-items: center;
    text-align: center;
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
  }
  .cw-modal-divider::before,
  .cw-modal-divider::after {
    content: '';
    flex: 1;
    border-bottom: 1px solid var(--tablet-border);
  }
  .cw-modal-divider span {
    padding: 0 8px;
  }
  .cw-spot-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: 8px;
  }
  .empty-note {
    font-size: var(--fs-body);
    color: var(--text-dim);
    padding: 20px 0;
    text-align: center;
  }

  /* Excel-style gridded table — one bordered container with a real grid of
     cell dividers (vertical + horizontal lines) instead of separate rounded
     row "cards" with no column separators. Each .table-row is still its own
     CSS grid (for the fixed column widths), but padding/borders now live on
     the individual cells (`.table-row > div`) so the vertical lines actually
     line up between the header and every data row beneath it. */
  .template-table {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-sm);
    overflow-x: auto;
    overflow-y: hidden;
  }
  .table-row {
    display: grid;
    /* Every column but Name is a fixed/bounded width so the row's total
       width is deterministic — previously the trailing Actions column was
       `auto` (content-sized), which could grow past the row's fixed 1fr/px
       budget and squeeze Created By/Date into overlapping, "colliding" text
       instead of just wrapping or shrinking. */
    /* Name used to be the only flexible (fr) column, so it soaked up EVERY
       bit of leftover width on a wide panel regardless of how long the name
       actually was. Capped it to a sane max instead and made Created By the
       flexible one — a creator's name varies a lot less in length, but
       giving it the leftover space (rather than nobody) keeps the row
       filling the panel without one column dominating it. */
    /* The Actions column has to hold the widest row. That is a route you saved yourself that can also be test-run
       (a race or a container yard): Preview, Teleport, Test Run, Rename and Delete side by side, ~520px — at 440px the
       first button spilled left over the Date column. A row never gets narrower than its columns: on a smaller panel
       the table scrolls sideways instead of piling the cells on top of each other. */
    /* (smaller fonts and buttons below keep those five buttons to ~460px, so the column stays at 480px) */
    /* S.No | Name + date (takes all the spare width) | Type | Points | Created By | Actions */
    grid-template-columns: 60px minmax(160px, 1fr) 160px 70px 130px 480px;
    min-width: 1060px;
    align-items: center;
    gap: 0;
    background: var(--tablet-panel-alt);
    border-bottom: 1px solid var(--tablet-border);
  }
  .template-table .table-row:last-child {
    border-bottom: none;
  }
  /* extra leading checkbox column for multi-select delete */
  .template-table.has-check .table-row {
    grid-template-columns: 44px 60px minmax(160px, 1fr) 160px 70px 130px 480px;
    min-width: 1104px;
  }
  .table-row > .col-check {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 9px 0;
  }
  .col-check input {
    width: 17px;
    height: 17px;
    margin: 0;
    cursor: pointer;
    accent-color: var(--accent-primary, #c9a24a);
  }
  .table-row.row-selected {
    background: color-mix(in srgb, var(--accent-primary, #c9a24a) 10%, var(--tablet-panel-alt));
  }
  .select-bar {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    margin-bottom: 10px;
  }
  .select-info {
    margin-right: auto;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .table-row > div {
    padding: 9px 10px;
    font-size: var(--fs-meta);
    border-right: 1px solid var(--tablet-border);
    min-width: 0;
    /* Baseline for EVERY cell, header included — a cell whose text doesn't
       fit its column used to just overflow straight into the next one with
       no clipping at all (the header's "S.No"/"Name" cells bleeding into
       each other as "S.NONAME") instead of eliding or wrapping. */
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .table-row > div:last-child {
    border-right: none;
  }
  /* The Event Type cell needs extra horizontal breathing room — its badge is
     a solid pill with its own internal padding, and at the shared 12px cell
     padding the tag sat flush against the column's divider line. A wider
     column + a little more cell padding keeps the pill clear of both
     borders. */
  .table-row .col-type {
    padding-left: 16px;
    padding-right: 16px;
  }
  .table-head {
    background: color-mix(in srgb, var(--tablet-border-strong) 30%, var(--tablet-panel));
    border-bottom: 2px solid var(--tablet-border-strong);
  }
  .table-head > div {
    border-right: 1px solid var(--tablet-border-strong);
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #ffffff);
  }
  .table-head > div:last-child {
    border-right: none;
  }
  .col-sno {
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .col-name {
    min-width: 0;
    color: var(--text-main);
    font-size: var(--fs-small);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .col-name .name-main,
  .col-name .name-date {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .col-name .name-date {
    margin-top: 2px;
    font-size: var(--fs-meta);
    font-weight: 500;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  /* the header cell is a single line, so keep its label on the shared style */
  .table-head .col-name { font-size: var(--fs-meta); }
  .col-type {
    min-width: 0;
  }
  .type-badge {
    display: inline-flex;
    align-items: center;
    padding: 3px 9px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    white-space: nowrap;
    /* Solid-ish colour fill + near-white text reads as an actual tag from
       across the row — the old colour-on-dark-background version (colour
       text, near-transparent background) had too little contrast to read
       at a glance, which is exactly what got flagged. */
    color: var(--lt-ffffff, #ffffff);
    border: 1px solid var(--badge-color);
    background: color-mix(in srgb, var(--badge-color) 55%, var(--tablet-panel-alt));
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.4);
  }
  .col-points, .col-created, .col-date {
    font-size: var(--fs-meta);
    color: var(--text-dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }
  .col-actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    flex-wrap: nowrap;
    gap: 6px;
    flex-shrink: 0;
    min-width: 0;
    /* the shared cell rule clips overflow; keep the buttons' own borders visible */
    overflow: visible !important;
    padding-left: 6px !important;
    padding-right: 10px !important;
  }
  /* Compact row actions: the global .btn is 38px tall with 18px side padding,
     which made Preview + Delete wider than this column and pile onto each
     other. Same buttons, tighter, never wrapping. */
  .col-actions .btn {
    min-height: 30px;
    padding: 0 8px;
    gap: 5px;
    font-size: var(--fs-meta);
    white-space: nowrap;
    flex-shrink: 0;
  }
  .col-actions .type-badge {
    flex-shrink: 0;
  }

  .import-backdrop {
    position: fixed;
    inset: 0;
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.7);
  }
  .import-box {
    width: min(520px, 92vw);
    display: flex;
    flex-direction: column;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-panel);
    box-shadow: none;
    overflow: hidden;
  }
  .import-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: var(--lt-0f1113, #0f1113);
    border-bottom: 1px solid var(--tablet-border);
  }
  .import-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-family: var(--font-display);
    font-stretch: var(--stretch-display);
    font-size: var(--fs-title);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--c-text);
  }
  .import-title :global(svg) { color: var(--c-action); }

  /* Rename dialog body: labelled, padded field with the shared focus ring */
  .rename-body {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 18px 16px 16px;
  }
  .rename-label {
    color: var(--text-dim);
    font-size: var(--fs-small);
    font-weight: 600;
  }
  .name-input {
    width: 100%;
    height: 40px;
    padding: 0 12px;
    background: var(--input-bg, #121418);
    border: 1px solid var(--input-border, #2e333a);
    border-radius: var(--r-ctl);
    color: var(--c-text);
    font-family: var(--font-ui);
    font-size: var(--fs-body);
    font-weight: 500;
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
  }
  .name-input:hover { border-color: var(--input-border-hover, #3a4048); }
  .name-input:focus {
    outline: none;
    border-color: var(--c-action);
    box-shadow: 0 0 0 3px rgba(var(--accent-primary-rgb), 0.18);
  }
  .rename-hint {
    overflow: hidden;
    color: var(--c-text-3);
    font-size: var(--fs-meta);
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .import-foot {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding: 12px 16px;
    border-top: 1px solid var(--tablet-border);
    background: var(--lt-0f1113, #0f1113);
  }
  .icon-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 1px solid var(--tablet-border);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
    cursor: pointer;
  }
  .icon-btn:hover {
    color: var(--lt-ffffff, #fff);
    border-color: var(--tablet-border-strong);
  }
  .chip-btn {
    background: var(--tablet-bg, #0f1113);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .chip-btn.active {
    background: var(--c-action);
    border-color: var(--accent-primary);
    color: var(--on-accent);
  }

  /* ── Custom Slate Gradient Background for Saved Routes ── */
  .saved-routes-panel {
    --card-bg: rgba(20, 26, 36, 0.45);
    --tablet-panel: rgba(20, 26, 36, 0.55);
    --tablet-panel-alt: rgba(14, 19, 27, 0.5);
    --tablet-border: rgba(110, 140, 180, 0.18);
    --tablet-border-strong: rgba(130, 165, 210, 0.28);
    --input-bg: rgba(11, 15, 22, 0.7);
    --input-border: rgba(110, 140, 180, 0.22);
    background: transparent;
    border: 1px solid rgba(85, 118, 160, 0.22);
    border-radius: var(--radius-md, 12px);
    padding: 22px 24px;
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.4);
    position: relative;
    min-height: 100%;
  }

  .saved-routes-panel .header-row {
    margin-bottom: 12px;
  }

  .saved-routes-panel .search-row {
    background: rgba(var(--ltc-11-15-22, 11, 15, 22), 0.7);
    border: 1px solid rgba(110, 140, 180, 0.2);
  }

  .saved-routes-panel .template-table {
    background: rgba(var(--ltc-14-18-26, 14, 18, 26), 0.6);
    border: 1px solid rgba(110, 140, 180, 0.2);
  }

  .saved-routes-panel .table-head {
    background: rgba(var(--ltc-20-26-38, 20, 26, 38), 0.85);
    border-bottom: 2px solid rgba(120, 155, 200, 0.3);
  }

  .saved-routes-panel .table-row {
    background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.5);
    border-bottom: 1px solid rgba(110, 140, 180, 0.14);
  }

  .saved-routes-panel .table-row:hover {
    background: rgba(var(--ltc-30-42-60, 30, 42, 60), 0.7);
  }
</style>
