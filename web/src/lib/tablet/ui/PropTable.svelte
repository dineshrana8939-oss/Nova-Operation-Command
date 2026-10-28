<script>
  // ── Unified Prop Table ────────────────────────────────────────────────────────
  // Clean, structured prop table used across all events (Convoy, Airdrop, Hot Cargo,
  // Gang Rally, TDM, and Container Wars).
  // Features:
  // · Top toolbar: stats (Stacks/Objects, Pods/Vehicles, Solid/Ghost) + bulk actions
  // · Filter bar: search, compact pagination, model/height/physics dropdowns, view toggle
  // · 7-column table: #, Model, World Position (X, Y, Z), Heading, Height, Physics, Actions
  // · List (strip) mode
  import { createEventDispatcher } from 'svelte';
  import Icon from './Icon.svelte';
  import FilterSelect from './FilterSelect.svelte';
  import '../tablet-theme.css';

  export let items = [];
  export let locked = false;
  export let busy = false;
  export let zoneOf = null;          // (item) => string | '' : the checkpoint / zone an object belongs to
  export let maxItems = 150;
  export let modelColumnLabel = 'Prop Model';
  export let showStacksBulk = true;
  export let stacked = false;        // force the height controls even when every item is 1 high

  const dispatch = createEventDispatcher();

  let search = '';
  let filterModel = 'ALL';
  let filterHeight = 'ALL';
  let filterType = 'ALL';
  let filterSolid = 'ALL';
  let page = 1;
  let pageSize = 15;
  let viewMode = 'table'; // 'table' | 'strip'
  let confirmRemoveAll = false;

  const fmt = (n) => (Number.isFinite(Number(n)) ? Number(n).toFixed(1) : '–');
  const isVehicle = (o) => o.kind === 'vehicle';

  $: list = Array.isArray(items) ? items : [];
  $: vehicleCount = list.filter(isVehicle).length;
  $: propCount = list.length - vehicleCount;
  $: solidCount = list.filter((o) => o.collision !== false).length;
  $: ghostCount = list.length - solidCount;
  $: allSolid = list.length > 0 && ghostCount === 0;
  $: allGhost = list.length > 0 && solidCount === 0;
  $: allHeight = (n) => list.length > 0 && list.every((o) => (Number(o.stack) || 1) === n);
  $: totalPods = list.reduce((acc, o) => acc + Math.max(1, Number(o.stack) || 1), 0);
  $: hasStacks = stacked || list.some((o) => Number(o.stack) > 1);
  $: showZones = typeof zoneOf === 'function' && list.some((o) => zoneOf(o));
  $: models = Array.from(new Set(list.map((o) => o.model).filter(Boolean)));

  $: modelOptions = [{ value: 'ALL', label: `All Models (${models.length})` }, ...models.map((m) => ({ value: m, label: m }))];
  const heightOptions = [
    { value: 'ALL', label: 'All Heights' },
    { value: '1', label: '1 High' },
    { value: '2', label: '2 High' },
    { value: '3', label: '3 High' },
    { value: '4', label: '4+ High' },
  ];
  const physicsOptions = [
    { value: 'ALL', label: 'All Physics' },
    { value: 'solid', label: 'Solid only' },
    { value: 'nonsolid', label: 'Ghost (non-solid)' },
  ];
  const pageSizeOptions = [
    { value: 15, label: '15 / page' },
    { value: 20, label: '20 / page' },
    { value: 30, label: '30 / page' },
    { value: 50, label: '50 / page' },
    { value: 0, label: 'All' },
  ];

  $: filtered = list
    .map((o, i) => ({ ...o, index: i }))
    .filter((o) => {
      if (filterModel !== 'ALL' && o.model !== filterModel) return false;
      if (filterHeight !== 'ALL') {
        const stk = String(o.stack || 1);
        if (filterHeight === '4') {
          if (Number(o.stack || 1) < 4) return false;
        } else if (stk !== filterHeight) {
          return false;
        }
      }
      if (filterSolid === 'solid' && o.collision === false) return false;
      if (filterSolid === 'nonsolid' && o.collision !== false) return false;
      const q = search.trim().toLowerCase();
      if (q) {
        const hay = [String(o.index + 1), o.model || '', `${o.x},${o.y},${o.z}`, showZones ? (zoneOf(o) || '') : ''].join(' ').toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });

  $: totalPages = Math.max(1, pageSize === 0 ? 1 : Math.ceil(filtered.length / pageSize));
  $: if (page > totalPages) page = totalPages;
  $: if (page < 1) page = 1;
  $: visible = pageSize === 0 ? filtered : filtered.slice((page - 1) * pageSize, page * pageSize);

  function resetFilters() { search = ''; filterModel = 'ALL'; filterHeight = 'ALL'; filterSolid = 'ALL'; page = 1; }

  function removeAll() {
    if (!confirmRemoveAll) { confirmRemoveAll = true; setTimeout(() => (confirmRemoveAll = false), 4000); return; }
    confirmRemoveAll = false;
    dispatch('removeAll');
  }
</script>

<div class="prop-table-card">
  <!-- Top Stats & Bulk Toolbar -->
  <div class="dummy-toolbar">
    <div class="dummy-stats">
      <div class="stat-chip">
        <Icon name="box" size={13} />
        <span>{hasStacks ? 'Stacks' : 'Objects'}: <strong>{list.length} / {maxItems}</strong></span>
      </div>
      {#if hasStacks && totalPods !== list.length}
        <div class="stat-chip">
          <Icon name="layers" size={13} />
          <span>Total Pods: <strong>{totalPods}</strong></span>
        </div>
      {/if}
      {#if vehicleCount > 0}
        <div class="stat-chip">
          <Icon name="truck" size={13} />
          <span>Vehicles: <strong>{vehicleCount}</strong></span>
        </div>
      {/if}
      <div class="stat-chip">
        <span class="dot-solid"></span>
        <span>Solid: <strong>{solidCount}</strong></span>
        <span class="dot-ghost" style="margin-left: 6px;"></span>
        <span>Ghost: <strong>{ghostCount}</strong></span>
      </div>
    </div>

    {#if list.length}
      <div class="dummy-bulk-actions">
        <div class="bulk-group">
          <span class="bulk-label">Set all to</span>
          <div class="seg-group">
            <button type="button" class:on={allSolid} aria-pressed={allSolid} on:click={() => dispatch('bulk', { collision: true })} disabled={locked || busy} title="Set collision solid for all objects">Solid</button>
            <button type="button" class:on={allGhost} aria-pressed={allGhost} on:click={() => dispatch('bulk', { collision: false })} disabled={locked || busy} title="Disable collision for all objects">Non-solid</button>
          </div>
        </div>
        {#if showStacksBulk && hasStacks}
          <div class="bulk-group">
            <span class="bulk-label">Height (high)</span>
            <div class="seg-group">
              <button type="button" class:on={allHeight(1)} aria-pressed={allHeight(1)} on:click={() => dispatch('bulk', { stack: 1 })} disabled={locked || busy}>1</button>
              <button type="button" class:on={allHeight(2)} aria-pressed={allHeight(2)} on:click={() => dispatch('bulk', { stack: 2 })} disabled={locked || busy}>2</button>
              <button type="button" class:on={allHeight(3)} aria-pressed={allHeight(3)} on:click={() => dispatch('bulk', { stack: 3 })} disabled={locked || busy}>3</button>
            </div>
          </div>
        {/if}
        <button type="button" class="btn btn-xs btn-danger bulk-remove" on:click={removeAll} disabled={locked || busy}>
          <Icon name="trash" size={12} /><span>{confirmRemoveAll ? 'Click again to confirm' : 'Remove all'}</span>
        </button>
      </div>
    {/if}
  </div>

  <!-- Search & Filter Controls -->
  {#if list.length}
    <div class="dummy-filter-bar">
      <div class="search-input-wrap">
        <Icon name="search" size={13} />
        <input
          type="text"
          placeholder="Search by #, model, or coordinates..."
          bind:value={search}
          on:input={() => (page = 1)}
        />
        {#if search}
          <button type="button" class="clear-search-btn" on:click={() => { search = ''; page = 1; }}>×</button>
        {/if}
      </div>

      <!-- Pager -->
      <div class="pager">
        <button type="button" class="pager-btn" disabled={page <= 1} on:click={() => (page = 1)} title="First page" aria-label="First page">«</button>
        <button type="button" class="pager-btn" disabled={page <= 1} on:click={() => (page = Math.max(1, page - 1))} title="Previous page" aria-label="Previous page">‹</button>
        <span class="pager-info" title="Page {page} of {totalPages}">
          {#if !filtered.length}
            0 of 0
          {:else if pageSize === 0}
            All {filtered.length}
          {:else}
            <b>{(page - 1) * pageSize + 1}–{Math.min(page * pageSize, filtered.length)}</b> of {filtered.length}
          {/if}
        </span>
        <button type="button" class="pager-btn" disabled={page >= totalPages} on:click={() => (page = Math.min(totalPages, page + 1))} title="Next page" aria-label="Next page">›</button>
        <button type="button" class="pager-btn" disabled={page >= totalPages} on:click={() => (page = totalPages)} title="Last page" aria-label="Last page">»</button>
        <FilterSelect bind:value={pageSize} options={pageSizeOptions} title="Objects per page" minWidth={118} on:change={() => (page = 1)} />
      </div>

      <div class="filter-group">
        <FilterSelect bind:value={filterModel} options={modelOptions} title="Filter by model" minWidth={160} on:change={() => (page = 1)} />

        {#if hasStacks}
          <FilterSelect bind:value={filterHeight} options={heightOptions} title="Filter by stack height" minWidth={140} on:change={() => (page = 1)} />
        {/if}

        <FilterSelect bind:value={filterSolid} options={physicsOptions} title="Filter by physics" minWidth={140} on:change={() => (page = 1)} />

        <div class="view-toggle">
          <button type="button" class="btn-toggle" class:active={viewMode === 'table'} on:click={() => (viewMode = 'table')} title="Compact Table View">
            Table
          </button>
          <button type="button" class="btn-toggle" class:active={viewMode === 'strip'} on:click={() => (viewMode = 'strip')} title="Expanded Strip View">
            List
          </button>
        </div>
      </div>
    </div>
  {/if}

  <!-- Items View -->
  {#if !list.length}
    <div class="empty-dummies">
      <Icon name="box" size={26} />
      <p>Nothing stored yet. Everything you place with the Prop Placer is listed here.</p>
    </div>
  {:else if !filtered.length}
    <div class="empty-dummies">
      <p>No stored objects match your search filter.</p>
      <button type="button" class="btn btn-xs btn-steel" on:click={resetFilters}>
        Reset Filters
      </button>
    </div>
  {:else if viewMode === 'table'}
    <!-- Table view: position split into X / Y / Z so the numbers line up and the
         model column takes the remaining width (no dead gap between columns). -->
    <div class="dummy-table-wrap">
      <table class="dummy-table">
        <thead>
          <tr>
            <th class="c-idx">#</th>
            <th class="c-model">{modelColumnLabel}</th>
            <th class="c-num">X</th>
            <th class="c-num">Y</th>
            <th class="c-num">Z</th>
            <th class="c-num c-head">Heading</th>
            <th class="c-tag">Height</th>
            <th class="c-tag">Physics</th>
            <th class="c-act">Actions</th>
          </tr>
        </thead>
        <tbody>
          {#each visible as o (o.index)}
            <tr>
              <td class="c-idx">{o.index + 1}</td>
              <td class="c-model">
                <div class="model-cell">
                  <span class="dummy-model-text" title={o.model}>{o.model}</span>
                  {#if isVehicle(o)}
                    <span class="type-pill veh">Vehicle</span>
                  {/if}
                  {#if showZones && zoneOf(o)}
                    <span class="zone-pill" title={zoneOf(o)}>{zoneOf(o)}</span>
                  {/if}
                </div>
              </td>
              <td class="c-num">{fmt(o.x)}</td>
              <td class="c-num">{fmt(o.y)}</td>
              <td class="c-num">{fmt(o.z)}</td>
              <td class="c-num c-head">{fmt(o.heading)}°</td>
              <td class="c-tag">
                {#if isVehicle(o)}
                  <span class="muted-dash">—</span>
                {:else}
                  <span class="stack-badge">{o.stack || 1} High</span>
                {/if}
              </td>
              <td class="c-tag">
                <span class="phys-badge {o.collision === false ? 'ghost' : 'solid'}">
                  {o.collision === false ? 'Non-solid' : 'Solid'}
                </span>
              </td>
              <td class="c-act">
                <div class="table-actions">
                  <button type="button" class="btn btn-xs btn-edit" on:click={() => dispatch('edit', o.index)} disabled={locked || busy} title="Edit in Prop Placer">
                    <Icon name="edit" size={12} /><span>Edit</span>
                  </button>
                  <button type="button" class="btn btn-xs" on:click={() => dispatch('teleport', o.index)} title="Teleport to object">
                    <Icon name="teleport" size={12} /><span>Teleport</span>
                  </button>
                  <button type="button" class="btn btn-xs btn-danger" on:click={() => dispatch('remove', o.index)} disabled={locked || busy} title="Remove object">
                    <Icon name="trash" size={12} /><span>Remove</span>
                  </button>
                </div>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {:else}
    <!-- List view: one aligned row per object (index · model · position · tags · actions) -->
    <div class="dummy-strip-wrap">
      {#each visible as o (o.index)}
        <div class="dummy-strip-item">
          <span class="strip-idx">{o.index + 1}</span>
          <div class="strip-main">
            <span class="dummy-model-text" title={o.model}>{o.model}</span>
            <span class="strip-pos">{fmt(o.x)}, {fmt(o.y)}, {fmt(o.z)} <span class="strip-sep">·</span> {fmt(o.heading)}°</span>
          </div>
          <div class="strip-tags">
            {#if isVehicle(o)}
              <span class="type-pill veh">Vehicle</span>
            {:else}
              <span class="stack-badge">{o.stack || 1} High</span>
            {/if}
            <span class="phys-badge {o.collision === false ? 'ghost' : 'solid'}">{o.collision === false ? 'Non-solid' : 'Solid'}</span>
            {#if showZones && zoneOf(o)}<span class="zone-pill" title={zoneOf(o)}>{zoneOf(o)}</span>{/if}
          </div>
          <div class="table-actions">
            <button type="button" class="btn btn-xs btn-edit" on:click={() => dispatch('edit', o.index)} disabled={locked || busy} title="Edit in Prop Placer">
              <Icon name="eye" size={12} /><span>Edit</span>
            </button>
            <button type="button" class="btn btn-xs" on:click={() => dispatch('teleport', o.index)} title="Teleport to object">
              <Icon name="teleport" size={12} /><span>Teleport</span>
            </button>
            <button type="button" class="btn btn-xs btn-danger" on:click={() => dispatch('remove', o.index)} disabled={locked || busy} title="Remove object">
              <Icon name="trash" size={12} /><span>Remove</span>
            </button>
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .prop-table-card {
    border: 1px solid var(--c-line);
    border-radius: var(--r-panel);
    background: var(--c-panel);
    overflow: hidden;
  }

  /* ── Stats & bulk toolbar ── */
  .dummy-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px;
    padding: 12px 16px;
    border-bottom: 1px solid var(--c-line);
  }
  .dummy-stats {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .stat-chip {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 32px;
    padding: 0 12px;
    background: var(--c-base);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    font-weight: 500;
    color: var(--c-text-2);
    white-space: nowrap;
  }
  .stat-chip :global(svg) { color: var(--c-text-3); }
  .stat-chip strong {
    color: var(--c-text);
    font-family: var(--font-display);
    font-stretch: var(--stretch-display);
    font-size: var(--fs-emph);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }
  .dot-solid,
  .dot-ghost {
    width: 7px;
    height: 7px;
    border-radius: 50%;
  }
  .dot-solid { background: var(--c-ok); }
  .dot-ghost { background: var(--c-warn); }
  .dummy-bulk-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .dummy-bulk-actions { gap: 14px; }
  .bulk-group { display: inline-flex; align-items: center; gap: 8px; }
  .bulk-label { color: var(--c-text-3); font-size: var(--fs-meta); font-weight: 600; }
  .seg-group { display: inline-flex; height: 28px; border: 1px solid var(--c-line); border-radius: var(--r-ctl); overflow: hidden; }
  .seg-group button { padding: 0 12px; background: var(--c-panel); border: none; color: var(--c-text-2); font-size: var(--fs-meta); font-weight: 600; cursor: pointer; }
  .seg-group button + button { border-left: 1px solid var(--c-line); }
  .seg-group button:hover:not(:disabled) { background: var(--c-raised); color: var(--c-text); }
  .seg-group button { min-width: 34px; transition: background 0.12s ease, color 0.12s ease; }
  .seg-group button:active:not(:disabled) { transform: translateY(1px); }
  .seg-group button:focus-visible { outline: 2px solid var(--c-action); outline-offset: -2px; }
  /* the value every object has right now; nothing is lit while they are mixed */
  .seg-group button.on { background: var(--c-action); color: var(--on-accent, #ffffff); font-weight: 700; }
  .seg-group button.on:hover:not(:disabled) { background: var(--c-action); color: var(--on-accent, #ffffff); }
  .seg-group button:disabled { opacity: 0.45; cursor: default; }
  .bulk-remove { margin-left: 6px; }

  /* ── Filter bar ── */
  .dummy-filter-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    padding: 10px 16px;
    background: var(--c-base);
    border-bottom: 1px solid var(--c-line);
  }
  .search-input-wrap {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 36px;
    flex: 1 1 240px;
    min-width: 220px;
    max-width: 340px;
    padding: 0 12px;
    background: var(--c-panel);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    color: var(--c-text-3);
  }
  .search-input-wrap:focus-within { border-color: var(--c-action); }
  .search-input-wrap input {
    flex: 1;
    min-width: 0;
    height: 100%;
    background: transparent;
    border: none;
    color: var(--c-text);
    font-size: var(--fs-small);
    outline: none;
  }
  .clear-search-btn {
    padding: 0 2px;
    background: none;
    border: none;
    color: var(--c-text-3);
    font-size: var(--fs-emph);
    line-height: 1;
    cursor: pointer;
  }
  .pager {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    flex: none;
    white-space: nowrap;
  }
  .pager-btn {
    width: 32px;
    height: 32px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--c-panel);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    color: var(--c-text);
    font-size: var(--fs-emph);
    line-height: 1;
    cursor: pointer;
  }
  .pager-btn:hover:not(:disabled) { background: var(--c-raised); border-color: #3a4048; }
  .pager-btn:disabled { opacity: 0.35; cursor: default; }
  .pager-info {
    min-width: 84px;
    text-align: center;
    font-size: var(--fs-small);
    font-weight: 500;
    color: var(--c-text-3);
    font-variant-numeric: tabular-nums;
  }
  .pager-info b { color: var(--c-text); font-weight: 600; }
  .filter-group {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    margin-left: auto;
  }
  .view-toggle {
    display: inline-flex;
    height: 36px;
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    overflow: hidden;
  }
  .btn-toggle {
    padding: 0 14px;
    background: var(--c-panel);
    border: none;
    color: var(--c-text-2);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
  }
  .btn-toggle + .btn-toggle { border-left: 1px solid var(--c-line); }
  .btn-toggle:hover { color: var(--c-text); background: var(--c-raised); }
  .btn-toggle.active { background: var(--c-action); color: var(--on-accent, #ffffff);
    text-shadow: none; }

  /* ── Table ── */
  .dummy-table-wrap {
    max-height: 540px;
    overflow: auto;
  }
  .dummy-table {
    width: 100%;
    min-width: 900px;
    table-layout: fixed;
    border-collapse: collapse;
    text-align: left;
  }
  .dummy-table th {
    position: sticky;
    top: 0;
    z-index: 2;
    height: 38px;
    padding: 0 16px;
    background: var(--lt-15171b, #15171b);
    border-bottom: 1px solid var(--c-line);
    color: var(--text-muted);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    white-space: nowrap;
  }
  .dummy-table td {
    height: 46px;
    padding: 0 16px;
    border-bottom: 1px solid var(--c-line-soft);
    color: var(--c-text-2);
    font-size: var(--fs-small);
    vertical-align: middle;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  .dummy-table tbody tr:last-child td { border-bottom: 0; }
  .dummy-table tbody tr { transition: background 0.12s ease; }
  .dummy-table tbody tr:nth-child(even) { background: rgba(var(--ink-rgb, 255, 255, 255), 0.018); }
  .dummy-table tbody tr:hover { background: rgba(var(--ink-rgb, 255, 255, 255), 0.03); }

  /* column roles: fixed widths, the model is only as wide as its name needs, the actions take the spare width */
  .c-idx { width: 4%; color: var(--c-text-3); text-align: center; }
  .c-model { width: 18%; }
  .c-num { width: 9%; text-align: right; }
  th.c-num:nth-of-type(5) { width: 7%; }
  td.c-num { color: var(--c-text); }
  .c-head { width: 9%; }
  td.c-head { color: var(--c-text-2); }
  .c-tag { width: 10%; padding-left: 28px !important; }
  .c-act { text-align: left; }
  td.c-act .table-actions { justify-content: flex-start; }
  /* thin rule between the position numbers and the rest, so X Y Z Heading read as one group */
  .c-head { border-right: 1px solid var(--c-line-soft); padding-right: 20px !important; }
  td.c-idx { font-variant-numeric: tabular-nums; font-weight: 600; }

  .model-cell {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }
  .dummy-model-text {
    max-width: 320px;
    overflow: hidden;
    color: var(--c-text);
    font-size: var(--fs-body);
    font-weight: 600;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .type-pill,
  .zone-pill,
  .stack-badge,
  .phys-badge {
    display: inline-flex;
    align-items: center;
    height: 22px;
    padding: 0 8px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    white-space: nowrap;
  }
  .type-pill {
    background: rgb(155, 123, 255);
    border: 1px solid rgb(155, 123, 255);
    color: #111111;
  }
  .zone-pill {
    max-width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
    background: var(--c-base);
    border: 1px solid var(--c-line);
    color: var(--c-text-2);
  }
  .stack-badge {
    background: var(--c-base);
    border: 1px solid transparent;
    color: var(--c-text-2);
  }
  .phys-badge.solid {
    background: rgb(70, 201, 139);
    border: 1px solid rgb(70, 201, 139);
    color: #111111;
  }
  .phys-badge.ghost {
    background: transparent;
    border: 1px solid var(--c-line);
    color: var(--c-text-3);
  }
  .muted-dash { color: var(--c-text-3); }
  .table-actions {
    display: inline-flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
  }
  /* row buttons: same compact size as every other table's row actions */
  .table-actions :global(.btn) {
    height: 28px;
    min-height: 28px;
    padding: 0 9px;
    gap: 5px;
    font-size: var(--fs-meta);
  }
  .table-actions :global(.icon-only) {
    width: 28px;
    padding: 0;
    justify-content: center;
  }

  /* ── List view ── */
  .dummy-strip-wrap {
    display: flex;
    flex-direction: column;
    max-height: 540px;
    overflow-y: auto;
  }
  .dummy-strip-item {
    display: grid;
    grid-template-columns: 40px minmax(0, 1fr) auto auto;
    align-items: center;
    gap: 14px;
    min-height: 56px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--c-line-soft);
    transition: background 0.12s ease;
  }
  .dummy-strip-item:last-child { border-bottom: 0; }
  .dummy-strip-item:hover { background: rgba(var(--ink-rgb, 255, 255, 255), 0.03); }
  .strip-idx {
    color: var(--c-text-3);
    font-size: var(--fs-small);
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
  .strip-main {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .strip-pos {
    color: var(--c-text-3);
    font-size: var(--fs-meta);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .strip-sep { margin: 0 4px; }
  .strip-tags {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  /* ── Empty states ── */
  .empty-dummies {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 36px 16px;
    color: var(--c-text-3);
    text-align: center;
  }
  .empty-dummies p {
    margin: 0;
    font-size: var(--fs-small);
  }
</style>
