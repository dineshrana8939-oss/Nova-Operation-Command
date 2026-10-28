<script>
  import { removeStaff } from '../../../api/staff.js';
  import { confirmAction } from '../../ui/confirm.js';
  import Icon from '../../ui/Icon.svelte';
  import SearchBox from '../../ui/SearchBox.svelte';
  import FilterSelect from '../../ui/FilterSelect.svelte';
  import AddStaffModal from './AddStaffModal.svelte';
  import EditStaffModal from './EditStaffModal.svelte';

  export let ov;
  export let ok = (msg) => {};
  export let fail = (res, fallback) => {};
  export let reload = async () => {};

  let search = '';
  let roleFilter = 'all';
  let statusFilter = 'all';
  let adding = false;
  let editingId = null;
  let busyId = null;

  $: staff = ov.staff || [];
  // ONE list: the staff records plus the server administrators (ACE permission — not stored as staff, so shown read-only in the
  // same table with the role "Server administrator"). Sorted by role (Owner first), then by name.
  $: adminRows = (ov.owners || []).filter((o) => o.kind === "serverAdmin").map((o) => ({
    ...o, virtual: true, roleId: "serverAdmin", status: "active", locked: true,
    lockedReason: "Server administrators have full access through the server permission and are managed outside this list.",
  }));
  $: roleRank = (id) => { if (id === "serverAdmin") return -1; const i = roles.findIndex((r) => r.id === id); return i < 0 ? 999 : i; };
  $: allRows = [...adminRows, ...staff].sort((a, b) => roleRank(a.roleId) - roleRank(b.roleId) || (a.playerName || "").toLowerCase().localeCompare((b.playerName || "").toLowerCase()));
  $: roles = ov.roles || [];
  $: me = ov.me || {};
  $: roleOptions = [{ value: 'all', label: 'All roles' }, ...(adminRows.length ? [{ value: 'serverAdmin', label: 'Server administrator' }] : []), ...roles.map((r) => ({ value: r.id, label: r.name }))];
  const statusOptions = [
    { value: 'all', label: 'All statuses' },
    { value: 'active', label: 'Active' },
    { value: 'disabled', label: 'Disabled' },
    { value: 'revoked', label: 'Revoked' },
  ];
  $: q = search.trim().toLowerCase();
  $: filtered = allRows.filter((s) =>
    (roleFilter === 'all' || s.roleId === roleFilter) &&
    (statusFilter === 'all' || s.status === statusFilter) &&
    (!q || (s.playerName || '').toLowerCase().includes(q) || (s.identifier || '').toLowerCase().includes(q) || String(s.serverId ?? '') === q)
  );
  $: filtersOn = !!q || roleFilter !== 'all' || statusFilter !== 'all';
  $: assignable = roles.filter((r) => r.assignable !== false);
  $: editing = editingId ? staff.find((s) => s.identifier === editingId) || null : null;
  const statusClass = { active: 'badge-completed', disabled: 'badge-cancelled', revoked: 'badge-failed' };
  const when = (t) => (t ? String(t).slice(0, 16) : '');

  function clearFilters() { search = ''; roleFilter = 'all'; statusFilter = 'all'; }

  const lockTip = (s, perm, permMsg) => (s.locked ? (s.lockedReason || 'This staff member is protected.') : !perm ? permMsg : '');

  async function remove(s) {
    const yes = await confirmAction(`Remove ${s.playerName} from staff? They lose every staff permission and their overrides are deleted. This cannot be undone.`, { title: `Remove staff - ${s.playerName}`, danger: true, confirmLabel: 'Remove staff' });
    if (!yes) return;
    busyId = s.identifier;
    const res = await removeStaff(s.identifier);
    busyId = null;
    if (res && res.ok) { ok(`${s.playerName} was removed from staff.`); await reload(); } else { fail(res, 'Could not remove this staff member.'); }
  }

  async function onAdded(e) {
    adding = false;
    const m = e.detail;
    ok(m ? `${m.playerName} added as ${m.roleName || 'staff'}.` : 'Staff member added.');
    await reload();
  }
  async function onSaved(e) {
    editingId = null;
    ok(`Saved changes for ${e.detail.name}.`);
    await reload();
  }
</script>

<div class="kpi-row st-kpis">
  <div class="kpi-card"><div class="kpi-icon"><Icon name="users" size={16} /></div><div><div class="kpi-value" data-kpi="total">{ov.stats.total}</div><div class="kpi-label">Total staff</div></div></div>
  <div class="kpi-card"><div class="kpi-icon"><Icon name="checkCircle" size={16} /></div><div><div class="kpi-value" data-kpi="active">{ov.stats.active}</div><div class="kpi-label">Active</div></div></div>
  <div class="kpi-card"><div class="kpi-icon"><Icon name="alertCircle" size={16} /></div><div><div class="kpi-value" data-kpi="inactive">{(ov.stats.disabled || 0) + (ov.stats.revoked || 0)}</div><div class="kpi-label">Disabled / Revoked</div></div></div>
  <div class="kpi-card"><div class="kpi-icon"><Icon name="shield" size={16} /></div><div><div class="kpi-value" data-kpi="roles">{ov.stats.roles}</div><div class="kpi-label">Roles</div></div></div>
</div>

<div class="st-toolbar">
  <SearchBox bind:value={search} placeholder="Search by name or identifier..." width={280} />
  <FilterSelect bind:value={roleFilter} options={roleOptions} minWidth={160} title="Filter by role" />
  <FilterSelect bind:value={statusFilter} options={statusOptions} minWidth={160} title="Filter by status" />
  {#if filtersOn}<button class="btn btn-sm" type="button" on:click={clearFilters}>Clear filters</button>{/if}
  <span class="st-spacer"></span>
  <span class="st-count">{filtered.length} of {allRows.length}</span>
  {#if me.canCreate}
    <button class="btn btn-primary" type="button" on:click={() => (adding = true)}><Icon name="userPlus" size={14} /> Add staff</button>
  {/if}
</div>

{#if allRows.length === 0}
  <div class="empty-state">No staff yet.{#if me.canCreate} Use <b>Add staff</b> to give an online player access.{/if}</div>
{:else if filtered.length === 0}
  <div class="empty-state">No staff match these filters. <button class="btn btn-sm" type="button" on:click={clearFilters}>Clear filters</button></div>
{:else}
  <div class="st-wrap">
    <table class="data-table st-table">
      <thead>
        <tr>
          <th style="width: 20%">Name</th>
          <th style="width: 13%">Identifier</th>
          <th style="width: 14%">Job</th>
          <th style="width: 14%">Role</th>
          <th style="width: 8%">Status</th>
          <th style="width: 11%">Updated</th>
          <th style="text-align: right">Actions</th>
        </tr>
      </thead>
      <tbody>
        {#each filtered as s (s.identifier)}
          <tr data-ident={s.identifier} class:dim={s.status !== 'active'}>
            <td>
              <div class="st-name">
                <span class="st-dot" class:on={s.isOnline} title={s.isOnline ? `Online${s.serverId != null ? ' (#' + s.serverId + ')' : ''}` : 'Offline'}></span>
                <span class="st-pname" title={s.playerName}>{s.playerName}</span>
                {#if s.isSelf}<span class="st-you">You</span>{/if}
              </div>
            </td>
            <td class="st-ident" title={s.identifier}>{s.identifier}</td>
            <td class="st-job" title={s.job || ''}>{s.job || '—'}</td>
            <td><span class="badge st-role" class:st-admin={s.virtual} title={s.roleName || 'No role'}>{s.roleName || 'No role'}</span></td>
            <td><span class="badge {statusClass[s.status] || 'badge-draft'}">{s.status}</span></td>
            <td class="st-when">{s.virtual ? 'Server permission' : when(s.updatedAt || s.createdAt)}</td>
            <td>
              <div class="st-acts">
                <button class="btn btn-sm" type="button" data-act="edit" disabled={s.locked || !me.canEdit || busyId === s.identifier}
                  title={lockTip(s, me.canEdit, 'You do not have permission to edit staff.')} on:click={() => (editingId = s.identifier)}>
                  <Icon name="edit" size={12} /> Manage
                </button>
                <button class="btn btn-sm btn-danger" type="button" data-act="remove" disabled={s.locked || !me.canDelete || busyId === s.identifier}
                  title={lockTip(s, me.canDelete, 'You do not have permission to remove staff.')} on:click={() => remove(s)}>
                  <Icon name="trash" size={12} /> Remove staff
                </button>
              </div>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}

{#if adding}
  <AddStaffModal roles={assignable} on:close={() => (adding = false)} on:done={onAdded} />
{/if}
{#if editing}
  <EditStaffModal member={editing} {roles} sections={ov.sections || []} {me} on:close={() => (editingId = null)} on:saved={onSaved} on:stale={reload} />
{/if}

<style>
  .st-kpis { margin-bottom: 14px; }
  .st-role.st-admin { color: var(--yellow); }
  .st-toolbar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
  .st-toolbar :global(.fs-btn) { height: 36px; }
  .st-spacer { flex: 1; }
  .st-count { font-size: var(--fs-small); color: var(--text-muted); }
  .st-wrap { border: 1px solid var(--c-line); border-radius: var(--r-panel); overflow: hidden; }
  .st-table { table-layout: fixed; }
  .st-table tbody tr { cursor: default; }
  .st-table tbody tr.dim .st-pname { color: var(--text-dim); }
  .st-job { color: var(--text-dim); font-size: var(--fs-small); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .st-sub { margin: 2px 0 0 16px; font-size: var(--fs-meta); color: var(--text-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .st-table td { vertical-align: middle; padding-top: var(--tbl-td-y); padding-bottom: var(--tbl-td-y); }
  .st-name { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .st-dot { width: 8px; height: 8px; border-radius: 50%; background: #5b626a; flex-shrink: 0; }
  .st-dot.on { background: var(--green); }
  .st-pname { font-weight: 600; color: var(--text-main); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .st-you {
    height: 18px; padding: 0 6px; display: inline-flex; align-items: center; flex-shrink: 0;
    font-size: var(--fs-meta); font-weight: 700; color: var(--accent-primary-light);
    border: 1px solid rgba(var(--accent-primary-rgb), 0.45); border-radius: var(--r-tag);
  }
  .st-ident { font-family: var(--font-mono); font-size: var(--fs-small); color: var(--text-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .st-role { color: var(--accent-primary-light); max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .st-when { color: var(--text-dim); font-size: var(--fs-small); white-space: nowrap; }
  .st-acts { display: flex; gap: 6px; justify-content: flex-end; flex-wrap: nowrap; white-space: nowrap; }
  .st-table td:last-child { width: 1%; }   /* the two buttons stay side by side instead of stacking */
  .st-acts :global(.btn.btn-sm) { padding: 0 9px; }
</style>
