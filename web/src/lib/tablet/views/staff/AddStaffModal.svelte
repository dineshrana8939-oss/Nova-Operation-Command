<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import { getStaffOnlinePlayers, addStaff } from '../../../api/staff.js';
  import Icon from '../../ui/Icon.svelte';
  import SearchBox from '../../ui/SearchBox.svelte';
  import FilterSelect from '../../ui/FilterSelect.svelte';
  import Modal from './Modal.svelte';

  export let roles = []; // roles the caller may assign

  const dispatch = createEventDispatcher();

  let players = [];
  let loading = true;
  let loadError = '';
  let search = '';
  let selected = null; // an entry of `players`
  let typedId = null;
  let roleId = null;
  let busy = false;
  let error = '';

  $: roleOptions = [{ value: null, label: 'Select a role...' }, ...roles.map((r) => ({ value: r.id, label: r.name }))];
  $: q = search.trim().toLowerCase();
  $: shown = players.filter((p) => !q || String(p.serverId).includes(q) || (p.name || '').toLowerCase().includes(q) || (p.identifier || '').toLowerCase().includes(q));

  async function loadPlayers() {
    loading = true;
    loadError = '';
    const res = await getStaffOnlinePlayers();
    loading = false;
    if (res && res.ok) players = res.players || [];
    else loadError = (res && res.error) || 'Could not load the online players.';
  }
  onMount(loadPlayers);

  function pick(p) {
    if (p.isStaff || busy) return;
    selected = selected && selected.serverId === p.serverId ? null : p;
    if (selected) typedId = null;
    error = '';
  }
  function onType() {
    if (typedId !== null && typedId !== undefined && typedId !== '') selected = null;
    error = '';
  }

  async function submit() {
    error = '';
    let target = null;
    if (selected) target = selected.identifier || selected.serverId;
    else if (typedId !== null && typedId !== undefined && typedId !== '') {
      const n = Number(typedId);
      if (!Number.isInteger(n) || n <= 0) { error = 'Enter a valid server ID (a positive whole number).'; return; }
      target = n;
    } else { error = 'Pick an online player or type a server ID.'; return; }
    if (roleId == null) { error = 'Choose a role for this staff member.'; return; }

    busy = true;
    const res = await addStaff(target, roleId);
    busy = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not add this player as staff.'; return; }
    dispatch('done', res.member || null);
  }
</script>

<Modal title="Add staff" sub="Give an online player access to this panel" icon="userPlus" width={600} {busy} on:close>
  <div class="as-block">
    <div class="as-label">Select an online player</div>
    <SearchBox bind:value={search} placeholder="Search by name, server ID or identifier..." width={0} />
    <div class="as-list" data-testid="player-list">
      {#if loading}
        <div class="as-empty">Loading players...</div>
      {:else if loadError}
        <div class="as-empty err">{loadError} <button class="btn btn-sm" type="button" on:click={loadPlayers}>Retry</button></div>
      {:else if players.length === 0}
        <div class="as-empty">No players are online right now. You can still type a server ID below.</div>
      {:else if shown.length === 0}
        <div class="as-empty">No online player matches "{search}".</div>
      {:else}
        {#each shown as p (p.serverId)}
          <button
            type="button"
            class="as-row"
            class:sel={selected && selected.serverId === p.serverId}
            class:dis={p.isStaff}
            disabled={p.isStaff}
            data-sid={p.serverId}
            title={p.isStaff ? 'Already staff' : ''}
            on:click={() => pick(p)}
          >
            <span class="as-sid">#{p.serverId}</span>
            <span class="as-name">{p.name}</span>
            {#if p.gang}<span class="as-chip" title="Gang">{p.gang}</span>{/if}
            {#if p.job}<span class="as-chip" title="Job">{p.job}</span>{/if}
            {#if p.isStaff}<span class="as-chip staff">already staff</span>{/if}
            {#if selected && selected.serverId === p.serverId}<Icon name="check" size={14} />{/if}
          </button>
        {/each}
      {/if}
    </div>
  </div>

  <div class="as-grid">
    <div class="field">
      <label for="as-sid">Or type a server ID</label>
      <input id="as-sid" type="number" min="1" placeholder="e.g. 14" bind:value={typedId} on:input={onType} on:keydown={(e) => e.key === 'Enter' && submit()} />
    </div>
    <div class="field">
      <!-- svelte-ignore a11y-label-has-associated-control -->
      <label>Role <span class="optional">required</span></label>
      <FilterSelect bind:value={roleId} options={roleOptions} minWidth={200} up title="Role" />
    </div>
  </div>

  <div class="as-note"><Icon name="info" size={13} /> Adding staff never changes the player's gang, job or faction.</div>
  {#if error}<div class="error as-error" role="alert">{error}</div>{/if}

  <svelte:fragment slot="footer">
    <button class="btn" type="button" on:click={() => dispatch('close')} disabled={busy}>Cancel</button>
    <button class="btn btn-primary" type="button" on:click={submit} disabled={busy}><Icon name="plus" size={13} /> {busy ? 'Adding...' : 'Add staff'}</button>
  </svelte:fragment>
</Modal>

<style>
  .as-block { display: flex; flex-direction: column; gap: 8px; margin-bottom: 14px; }
  .as-label { font-size: var(--fs-small); font-weight: 600; color: var(--text-dim); }
  .as-block :global(.tb-search) { min-width: 0 !important; }
  .as-list {
    max-height: 220px; overflow-y: auto;
    border: 1px solid var(--c-line); border-radius: var(--r-ctl); background: var(--c-base);
  }
  .as-empty { padding: 22px 14px; text-align: center; color: var(--text-muted); font-size: var(--fs-small); }
  .as-empty.err { color: var(--red); }
  .as-row {
    width: 100%; display: flex; align-items: center; gap: 10px;
    min-height: 38px; padding: 0 12px; text-align: left;
    background: transparent; border: 0; border-bottom: 1px solid var(--c-line-soft); border-radius: 0;
    color: var(--text-main); font-family: var(--font-ui); font-size: var(--fs-body); cursor: pointer;
  }
  .as-row:last-child { border-bottom: 0; }
  .as-row:hover:not(:disabled) { background: var(--c-raised); }
  .as-row.sel { background: var(--c-hover); box-shadow: inset 2px 0 0 var(--accent-primary); }
  .as-row.sel :global(svg) { margin-left: auto; color: var(--accent-primary); }
  .as-row.dis { opacity: 0.5; cursor: not-allowed; }
  .as-sid { min-width: 44px; color: var(--text-muted); font-variant-numeric: tabular-nums; }
  .as-name { font-weight: 600; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .as-chip {
    height: 20px; padding: 0 7px; display: inline-flex; align-items: center;
    font-size: var(--fs-meta); font-weight: 600; color: var(--text-dim);
    background: var(--c-raised); border: 1px solid var(--c-line); border-radius: var(--r-tag);
  }
  .as-chip.staff { color: var(--accent-primary-light); border-color: rgba(var(--accent-primary-rgb), 0.4); }
  .as-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: start; }
  .as-grid .field { margin-bottom: 10px; }
  .as-note { display: flex; align-items: center; gap: 7px; font-size: var(--fs-small); color: var(--text-muted); }
  .as-note :global(svg) { color: var(--accent-primary-light); flex-shrink: 0; }
  .as-error { margin-top: 10px; }
</style>
