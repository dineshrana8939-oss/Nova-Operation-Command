<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import { getSavedRoutes, saveRouteTemplate, updateRouteTemplate, importRouteTemplate, deleteRouteTemplate } from '../../api/savedRoutes.js';
  import { confirmAction } from './confirm.js';
  import Icon from './Icon.svelte';

  // Saved-template bar shared by every route builder (Convoy route, Hot Cargo
  // zones, Airdrop zones, Gang Rally track). "Import Template…" opens a small box
  // listing ONLY the saved templates for this event type — never a long dropdown
  // mixing everything — with search, preview (races) and delete (custom ones).
  // The full library view still lives in the dedicated Saved Routes tab.
  export let kind; // 'CONVOY' | 'HOT_CARGO' | 'GANG_AIRDROP' | 'GANG_RACE' | 'CONTAINER_WARS'
  export let payload; // current data to save — shape depends on kind, see savedRoutes.js
  export let locked = false;
  // When true the import box also offers "Preview on Map": the template is sent
  // to the parent ('preview' event) to draw on its map BEFORE anything is imported.
  export let previewable = false;
  export let replaceWarning = 'Import this template? It REPLACES what\'s currently configured here — anything not saved elsewhere is lost.';
  export let activeTemplateId = null;
  export let activeTemplateName = '';
  export let activeTemplateIsPrebuilt = false;

  const dispatch = createEventDispatcher();

  const KIND_LABELS = {
    CONVOY: 'Convoy Route',
    HOT_CARGO: 'Hot Cargo',
    GANG_AIRDROP: 'Airdrop',
    GANG_RACE: 'Race Track',
    CONTAINER_WARS: 'Container Yard',
  };
  $: kindLabel = KIND_LABELS[kind] || 'Route';

  let savedRoutes = [];
  let selectedId = null;
  let savingTemplate = false;
  let newTemplateName = '';
  let showSaveRow = false;
  let error = '';

  let modalOpen = false;
  let modalMode = 'import'; // 'import' | 'overwrite'
  let search = '';
  let busy = false;
  let modalError = '';
  let notice = '';

  $: customRoutes = savedRoutes.filter((r) => !r.prebuilt);
  // Only this event type's templates, narrowed by the search box.
  $: visibleRoutes = search.trim()
    ? savedRoutes.filter((r) => r.name.toLowerCase().includes(search.trim().toLowerCase()))
    : savedRoutes;
  $: selected = savedRoutes.find((r) => r.id === selectedId) || null;
  $: matchingExisting = customRoutes.find(
    (r) => r.name.toLowerCase() === newTemplateName.trim().toLowerCase()
  );

  async function refresh() {
    const res = await getSavedRoutes();
    if (res && res.ok) {
      savedRoutes = res.routes.filter((r) => (r.kind || 'CONVOY') === kind);
      if (!savedRoutes.some((r) => r.id === selectedId)) selectedId = null;
    }
  }

  onMount(refresh);

  async function openModal() {
    modalMode = 'import';
    modalError = '';
    search = '';
    modalOpen = true;
    await refresh(); // pick up templates saved elsewhere since this screen opened
  }

  async function openOverwriteModal() {
    modalMode = 'overwrite';
    modalError = '';
    search = '';
    modalOpen = true;
    await refresh();
  }

  function closeModal() {
    modalOpen = false;
    busy = false;
  }

  function onKeydown(e) {
    if (modalOpen && e.key === 'Escape') { e.stopPropagation(); closeModal(); }
  }

  async function previewSelected() {
    if (!previewable || !selectedId) return;
    busy = true; modalError = '';
    const res = await importRouteTemplate(selectedId);
    busy = false;
    if (!res || !res.ok) { modalError = (res && res.error) || 'Failed to load the template.'; return; }
    dispatch('preview', res);
    closeModal();
  }

  async function doImport() {
    if (!selectedId) return;
    const tpl = selected;
    const ok = await confirmAction(
      `Import "${tpl ? tpl.name : 'this template'}"? ${replaceWarning}`,
      { title: 'Import Template', danger: true }
    );
    if (!ok) return;
    busy = true; modalError = '';
    const res = await importRouteTemplate(selectedId);
    busy = false;
    if (!res || !res.ok) { modalError = (res && res.error) || 'Failed to import template.'; return; }
    error = '';
    activeTemplateId = res.id || selectedId;
    activeTemplateName = res.name || (selected && selected.name) || '';
    activeTemplateIsPrebuilt = !!(res.prebuilt || (selected && selected.prebuilt));
    dispatch('import', res);
    if (previewable) dispatch('preview', null);
    closeModal();
  }

  async function doUpdate(targetId = activeTemplateId, targetName = activeTemplateName, how = 'update') {
    const tid = targetId || activeTemplateId;
    if (!tid) return;
    const tpl = savedRoutes.find((r) => r.id === tid);
    if (tpl && tpl.prebuilt) {
      error = 'Prebuilt templates are built-in and cannot be overwritten.';
      return;
    }
    const nameToUse = targetName || (tpl ? tpl.name : 'this template');
    const ok = how === 'overwrite'
      ? await confirmAction(
          `Overwrite saved template "${nameToUse}"? Its saved track is REPLACED by what is on this screen now.`,
          { title: 'Overwrite Saved Template', danger: true, confirmLabel: 'Yes, Overwrite' }
        )
      : await confirmAction(
          `Update saved template "${nameToUse}" with the changes you made to it on this screen?`,
          { title: 'Update Saved Template', confirmLabel: 'Yes, Update' }
        );
    if (!ok) return;
    savingTemplate = true;
    error = '';
    const res = await updateRouteTemplate(tid, payload);
    savingTemplate = false;
    if (!res || !res.ok) {
      error = (res && res.error) || 'Failed to update template.';
      return;
    }
    activeTemplateId = tid;
    activeTemplateName = nameToUse;
    activeTemplateIsPrebuilt = false;
    if (modalOpen) closeModal();
    showSaveRow = false;
    newTemplateName = '';
    notice = `Saved template "${nameToUse}" updated successfully.`;
    setTimeout(() => { if (notice.includes(nameToUse)) notice = ''; }, 4500);
    await refresh();
    dispatch('updated', { id: tid, name: nameToUse });
  }

  async function doDelete() {
    if (!selected || selected.prebuilt) return;
    const ok = await confirmAction(`Delete the saved template "${selected.name}"? This can't be undone.`, { title: 'Delete Template', danger: true });
    if (!ok) return;
    const res = await deleteRouteTemplate(selected.id);
    if (!res || !res.ok) { modalError = (res && res.error) || 'Failed to delete the template.'; return; }
    if (selected.id === activeTemplateId) {
      activeTemplateId = null;
      activeTemplateName = '';
    }
    selectedId = null;
    await refresh();
  }

  async function doSave() {
    error = '';
    const trimmed = newTemplateName.trim();
    if (trimmed.length < 2) { error = 'Give it a name (at least 2 characters).'; return; }

    // If matches an existing custom template, update instead
    if (matchingExisting && !matchingExisting.prebuilt) {
      await doUpdate(matchingExisting.id, matchingExisting.name, 'overwrite');
      return;
    }

    savingTemplate = true;
    const res = await saveRouteTemplate(trimmed, kind, payload);
    savingTemplate = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to save template.'; return; }
    activeTemplateId = res.id;
    activeTemplateName = trimmed;
    activeTemplateIsPrebuilt = false;
    newTemplateName = '';
    showSaveRow = false;
    notice = `Saved template "${trimmed}" created successfully.`;
    setTimeout(() => { if (notice.includes(trimmed)) notice = ''; }, 4500);
    await refresh();
    selectedId = res.id;
  }
</script>

<svelte:window on:keydown={onKeydown} />

{#if !locked}
  <div class="template-bar">
    <div class="template-row">
      <div class="template-title"><Icon name="box" size={13} /> Saved {kindLabel} Templates <span class="template-count">({savedRoutes.length})</span></div>
      <span class="template-manage-hint">Full library &amp; cleanup: <strong>Saved Routes</strong> tab in the sidebar</span>
    </div>

    {#if activeTemplateName}
      <div class="template-active-chip">
        <div class="active-chip-left">
          <span class="active-indicator-dot"></span>
          <span>Currently Loaded: <strong>{activeTemplateName}</strong></span>
          {#if activeTemplateIsPrebuilt}
            <span class="active-tag prebuilt">Prebuilt (Read-Only)</span>
          {:else}
            <span class="active-tag ready">Sync Ready</span>
          {/if}
        </div>
        {#if !activeTemplateIsPrebuilt}
          <div class="active-chip-right">
            <button type="button" class="btn btn-xs btn-primary" disabled={savingTemplate} on:click={() => doUpdate(activeTemplateId, activeTemplateName)} title="Quick update this template">
              <Icon name="refresh" size={11} /> Quick Update
            </button>
            <button type="button" class="btn-unlink" on:click={() => { activeTemplateId = null; activeTemplateName = ''; }} title="Unlink to save as a new template">
              Unlink
            </button>
          </div>
        {/if}
      </div>
    {/if}

    <div class="template-row template-actions">
      <button type="button" class="btn btn-steel" on:click={openModal}>
        <Icon name="download" size={13} /> Import Template…
      </button>

      {#if activeTemplateId && !activeTemplateIsPrebuilt}
        <button type="button" class="btn btn-primary" disabled={savingTemplate} on:click={() => doUpdate(activeTemplateId, activeTemplateName)} title="Overwrite '{activeTemplateName}' with current changes">
          <Icon name="refresh" size={13} /> {savingTemplate ? 'Updating...' : `Update "${activeTemplateName}"`}
        </button>
      {:else if customRoutes.length > 0}
        <button type="button" class="btn btn-warning" on:click={openOverwriteModal} title="Select an existing saved template to overwrite with your current changes">
          <Icon name="refresh" size={13} /> Update / Overwrite Existing…
        </button>
      {/if}

      {#if !showSaveRow}
        <button type="button" class="btn btn-steel" on:click={() => { showSaveRow = true; error = ''; }}>
          <Icon name="save" size={13} /> Save Current As...
        </button>
      {/if}
    </div>

    {#if showSaveRow}
      <div class="template-row template-save-row">
        <input type="text" placeholder="Template name" bind:value={newTemplateName} maxlength="100" />
        {#if matchingExisting && !matchingExisting.prebuilt}
          <button type="button" class="btn btn-warning" disabled={savingTemplate} on:click={() => doUpdate(matchingExisting.id, matchingExisting.name, 'overwrite')}>
            <Icon name="refresh" size={13} /> Overwrite "{matchingExisting.name}"
          </button>
        {:else}
          <button type="button" class="btn btn-primary" disabled={savingTemplate} on:click={doSave}>
            {savingTemplate ? 'Saving...' : 'Save As New'}
          </button>
        {/if}
        {#if customRoutes.length > 0}
          <button type="button" class="btn btn-steel" on:click={openOverwriteModal} title="Select an existing template to overwrite">
            <Icon name="refresh" size={13} /> Overwrite Existing…
          </button>
        {/if}
        <button type="button" class="btn" on:click={() => { showSaveRow = false; newTemplateName = ''; error = ''; }}>Cancel</button>
      </div>
      {#if matchingExisting && !matchingExisting.prebuilt}
        <div class="template-match-hint">
          <span>Notice: A template named <strong>"{matchingExisting.name}"</strong> already exists. Clicking <strong>Overwrite</strong> will update it in place.</span>
        </div>
      {/if}
    {/if}
  </div>

  {#if notice}<div class="notice">{notice}</div>{/if}
  {#if error}<div class="error">{error}</div>{/if}
{/if}

{#if modalOpen}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="import-backdrop" on:click|self={closeModal}>
    <div class="import-box" role="dialog" aria-modal="true" aria-label="{modalMode === 'overwrite' ? 'Update / Overwrite' : 'Import'} {kindLabel} template">
      <div class="import-head">
        <div class="import-title">
          <Icon name={modalMode === 'overwrite' ? 'refresh' : 'download'} size={14} />
          {modalMode === 'overwrite' ? `Update / Overwrite ${kindLabel} Template` : `Import ${kindLabel} Template`}
        </div>
        <button class="icon-btn" title="Close" on:click={closeModal}><Icon name="close" size={14} /></button>
      </div>

      {#if modalMode === 'overwrite'}
        <div class="modal-notice-bar">
          Select the saved template you wish to overwrite with your current screen configuration:
        </div>
      {/if}

      <div class="import-search">
        <Icon name="search" size={13} />
        <!-- svelte-ignore a11y-autofocus -->
        <input type="text" placeholder="Search {kindLabel.toLowerCase()} templates…" bind:value={search} autofocus />
        <span class="import-count">{visibleRoutes.length} of {savedRoutes.length}</span>
      </div>

      <div class="import-list">
        {#if savedRoutes.length === 0}
          <div class="import-empty">No saved {kindLabel.toLowerCase()} templates yet. Build one, then use <strong>Save Current As…</strong>.</div>
        {:else if visibleRoutes.length === 0}
          <div class="import-empty">No templates match "{search}".</div>
        {:else}
          {#each visibleRoutes as r (r.id)}
            <button
              type="button"
              class="import-row"
              class:selected={r.id === selectedId}
              on:click={() => (selectedId = r.id)}
              on:dblclick={() => { if (modalMode === 'overwrite') { if (!r.prebuilt) doUpdate(r.id, r.name, 'overwrite'); } else { doImport(); } }}
            >
              <span class="import-name" title={r.name}>{r.name}</span>
              <span class="import-meta">
                {r.pointCount} pt{r.pointCount === 1 ? '' : 's'}
                {#if r.prebuilt}<span class="import-badge">Prebuilt</span>{:else if r.createdByName}· {r.createdByName}{/if}
              </span>
            </button>
          {/each}
        {/if}
      </div>

      {#if modalError}<div class="error import-error">{modalError}</div>{/if}

      <div class="import-foot">
        <button
          class="btn btn-danger"
          title={selected && selected.prebuilt ? 'Prebuilt tracks are built in and cannot be deleted' : 'Delete the selected template'}
          disabled={!selected || selected.prebuilt}
          on:click={doDelete}
        ><Icon name="trash" size={13} /> Delete</button>
        <span class="import-spacer"></span>
        <button class="btn" on:click={closeModal}>Cancel</button>

        {#if previewable && modalMode !== 'overwrite'}
          <button class="btn btn-preview" disabled={!selectedId || busy} on:click={previewSelected}><Icon name="activity" size={13} /> Preview on Map</button>
        {/if}

        {#if selected && !selected.prebuilt && selected.id === activeTemplateId}
          <button
            class="btn btn-primary"
            disabled={busy || savingTemplate}
            title={`Update "${selected.name}" (the track loaded on this screen) with your changes`}
            on:click={() => doUpdate(selected.id, selected.name, 'update')}
          >
            <Icon name="refresh" size={13} /> Update
          </button>
        {/if}

        {#if selected && !selected.prebuilt}
          <button
            class="btn btn-warning"
            disabled={busy || savingTemplate}
            title={`Replace the saved "${selected.name}" with what is on this screen now`}
            on:click={() => doUpdate(selected.id, selected.name, 'overwrite')}
          >
            <Icon name="refresh" size={13} /> Overwrite
          </button>
        {/if}

        {#if modalMode !== 'overwrite'}
          <button class="btn btn-primary" disabled={!selectedId || busy} on:click={doImport}>{busy ? 'Working…' : 'Import'}</button>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .template-bar {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-bottom: 14px;
    padding: 12px;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
  }
  .template-title {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--text-dim);
  }
  .template-count {
    color: var(--text-dim);
    font-weight: 500;
    text-transform: none;
    letter-spacing: normal;
  }
  .template-manage-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .template-manage-hint strong {
    color: var(--text-main);
  }
  .template-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
  }
  .template-actions {
    justify-content: flex-start;
  }
  .template-save-row {
    padding-top: 8px;
    border-top: 1px dashed var(--tablet-border);
  }
  .template-save-row input {
    flex: 1;
    min-width: 0;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 10px;
    font-size: var(--fs-body);
  }
  .template-save-row input:focus {
    outline: none;
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.45);
  }
  .template-save-row input::placeholder {
    color: var(--text-placeholder);
  }

  /* ── Import box ── */
  .import-backdrop {
    position: fixed;
    inset: 0;
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.6);
  }
  .import-box {
    width: min(520px, 92vw);
    max-height: min(560px, 86vh);
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
    background: var(--bg-card-raised, #131518);
    border-bottom: 1px solid var(--tablet-border);
  }
  .import-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #fff);
  }
  .import-search {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 12px 16px 8px;
    padding: 0 12px;
    height: 38px;
    background: var(--input-bg, #0f1113);
    border: 1px solid var(--input-border, #272b31);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
  }
  .import-search input {
    flex: 1;
    min-width: 0;
    background: transparent;
    border: 0;
    outline: none;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-body);
  }
  .import-count {
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    color: var(--text-dim);
    white-space: nowrap;
  }
  .import-list {
    flex: 1;
    min-height: 150px;
    overflow-y: auto;
    padding: 4px 16px 10px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .import-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    width: 100%;
    padding: 12px 14px;
    text-align: left;
    background: var(--lt-0f1113, #0f1113);
    border: 1px solid var(--tablet-border);
    border-radius: var(--r-panel);
    color: var(--text-main);
    transition: background 0.12s ease, border-color 0.12s ease;
  }
  .import-row:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
  }
  .import-row.selected {
    background: var(--c-hover);
    border-color: var(--accent-primary);
  }
  .import-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--fs-body);
    font-weight: 600;
  }
  .import-meta {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .import-badge {
    padding: 1px 7px;
    border-radius: 999px;
    border: 1px solid var(--c-action);
    background: var(--c-action);
    color: var(--on-accent);
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .import-empty {
    padding: 28px 12px;
    text-align: center;
    font-size: var(--fs-body);
    color: var(--text-dim);
    line-height: 1.6;
  }
  .import-error {
    margin: 0 16px 8px;
  }
  .import-foot {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
    padding: 14px 16px;
    border-top: 1px solid var(--tablet-border);
    background: var(--bg-card-raised, #131518);
  }
  .import-foot :global(.btn) {
    min-height: 38px;
    padding: 0 14px;
    white-space: nowrap;
  }
  .import-foot :global(.btn-primary:disabled) {
    background: var(--lt-181b1f, #181b1f);
    border-color: var(--lt-2a2e35, #2a2e35);
    color: #77776f;
    text-shadow: none;
    opacity: 1;
  }
  .import-spacer {
    flex: 1;
  }

  /* ── Active Template Chip & Notifications ── */
  .template-active-chip {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 8px 12px;
    background: rgb(34, 197, 94);
    border: 1px solid rgb(34, 197, 94);
    border-radius: var(--radius-sm, 4px);
    font-size: var(--fs-meta);
    color: #111111;
  }
  .active-chip-left {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .active-indicator-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #22c55e;
    box-shadow: none;
  }
  .active-chip-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .active-tag {
    font-size: var(--fs-meta);
    padding: 2px 6px;
    border-radius: var(--r-tag);
    font-weight: 600;
  }
  .active-tag.ready {
    background: rgb(34, 197, 94);
    color: #111111;
    border: 1px solid rgb(34, 197, 94);
  }
  .active-tag.prebuilt {
    background: rgb(148, 163, 184);
    color: #111111;
    border: 1px solid rgb(148, 163, 184);
  }
  .btn-unlink {
    background: none;
    border: none;
    color: var(--text-dim, #959ca5);
    font-size: var(--fs-meta);
    cursor: pointer;
    text-decoration: underline;
    padding: 2px 4px;
  }
  .btn-unlink:hover {
    color: var(--lt-ffffff, #fff);
  }
  .template-match-hint {
    padding: 8px 12px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    font-size: var(--fs-meta);
    color: var(--lt-fef08a, #fef08a);
    border-left: 3px solid rgb(234, 179, 8);}
  .modal-notice-bar {
    padding: 8px 16px;
    background: rgba(234, 179, 8, 0.1);
    border-bottom: 1px solid rgba(234, 179, 8, 0.25);
    font-size: var(--fs-small);
    color: var(--lt-fde047, #fde047);
  }
  .notice {
    padding: 8px 12px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    color: var(--lt-86efac, #86efac);
    margin-bottom: 8px;
    border-left: 3px solid rgb(34, 197, 94);}
  :global(.btn-warning) {
    background: #d97706 !important;
    border-color: #b45309 !important;
    color: var(--lt-ffffff, #fff) !important;
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.4);
  }
  :global(.btn-warning:hover:not(:disabled)) {
    background: #b45309 !important;
    border-color: #92400e !important;
  }
</style>
