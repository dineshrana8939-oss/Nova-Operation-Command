<script>
  import { getStaffLog } from '../../../api/staff.js';
  import Icon from '../../ui/Icon.svelte';

  export let tick = 0; // bumps whenever the overview reloads, so the log follows staff changes

  const LABELS = {
    'staff.add': 'Staff added',
    'staff.remove': 'Staff removed',
    'staff.role': 'Role changed',
    'staff.permissions': 'Permissions changed',
    'staff.status': 'Status changed',
    'role.create': 'Role created',
    'role.update': 'Role updated',
    'role.delete': 'Role deleted',
  };
  const label = (code) => LABELS[code] || code;
  const when = (t) => (t ? String(t).slice(0, 16) : '');

  let entries = [];
  let loading = false;
  let error = '';
  let loaded = false;

  async function load(_tick) {
    loading = true;
    error = '';
    const res = await getStaffLog(200);
    loading = false;
    loaded = true;
    if (res && res.ok) entries = res.entries || [];
    else error = (res && res.error) || 'Could not load the activity log.';
  }
  $: load(tick);
</script>

<div class="at-bar">
  <span class="at-sub">The most recent 200 changes to staff, roles and permissions.</span>
  <button class="btn btn-sm" type="button" on:click={() => load(tick)} disabled={loading}><Icon name="refresh" size={13} /> {loading ? 'Loading...' : 'Refresh'}</button>
</div>

{#if error}
  <div class="error at-error" role="alert">{error}</div>
{/if}

{#if !loaded && loading}
  <div class="empty-state">Loading activity...</div>
{:else if entries.length === 0 && !error}
  <div class="empty-state">No activity yet. Changes to staff and roles will be listed here.</div>
{:else if entries.length}
  <div class="at-wrap">
    <table class="data-table at-table">
      <thead>
        <tr>
          <th style="width: 150px">Time</th>
          <th style="width: 170px">Admin</th>
          <th style="width: 180px">Action</th>
          <th style="width: 190px">Target</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
        {#each entries as e (e.id)}
          <tr>
            <td class="at-time">{when(e.createdAt)}</td>
            <td class="at-ell" title={e.actorIdentifier || ''}>{e.actorName || '-'}</td>
            <td><span class="at-act">{label(e.action)}</span></td>
            <td class="at-ell" title={e.targetIdentifier || ''}>{e.targetName || '-'}</td>
            <td class="at-details" title={e.details || ''}>{e.details || ''}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}

<style>
  .at-bar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
  .at-sub { font-size: var(--fs-small); color: var(--text-muted); }
  .at-error { margin-bottom: 10px; }
  .at-wrap { border: 1px solid var(--c-line); border-radius: var(--r-panel); overflow: hidden; }
  .at-table { table-layout: fixed; }
  .at-table tbody tr { cursor: default; }
  .at-table td { height: 42px; }
  .at-time { font-variant-numeric: tabular-nums; color: var(--text-dim); white-space: nowrap; }
  .at-ell, .at-details { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .at-details { color: var(--text-dim); }
  .at-act { font-weight: 600; color: var(--text-main); }
</style>
