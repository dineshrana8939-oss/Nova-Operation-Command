<script>
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import { GANG_PERMISSIONS } from '../../gangPerms.js';
  import { gangVersion } from '../../stores.js';
  import TablePager from '../../tablet/ui/TablePager.svelte';
  import GangLogoUpload from '../../tablet/ui/GangLogoUpload.svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import StatStrip from './StatStrip.svelte';
  import {
    getGangRolePermissions, setGangRolePermission, setOwnGangMemberRank,
    saveGangRole, renameGangRole, deleteGangRole
  } from '../../api/gang.js';

  export let roster = null;
  export let availableRecruits = [];
  export let logoBusy = false;
  export let memberBusy = false;
  export let memberError = '';
  // Caller's effective rights (server-decided). Without manageGang the view is
  // read-only: roster and roles are visible, nothing can be changed.
  export let canManageGang = false;
  export let isLeader = false;

  const dispatch = createEventDispatcher();

  // the same permission list the admin tablet shows (one shared module)
  const PERMISSIONS = GANG_PERMISSIONS;

  let tab = 'overview'; // 'overview' | 'members'

  // ── Defensive normalisation: a missing/odd field must never blank the tab ───
  $: members = (Array.isArray(roster?.members) ? roster.members : [])
    .filter((m) => m && m.identifier)
    .map((m) => ({
      identifier: m.identifier,
      name: String(m.name || m.identifier),
      serverId: m.serverId,
      online: !!m.online,
      // the leader holds the Leader role whatever rank is stored for them; nobody else can hold that name
      rank: m.identifier === roster?.leaderIdentifier ? 'Leader' : (String(m.rank || 'Member') === 'Leader' ? 'Member' : String(m.rank || 'Member')),
      isLeader: m.identifier === roster?.leaderIdentifier,
    }));
  $: gangLabel = roster?.gangLabel || roster?.gangName || 'Your Gang';
  $: onlineCount = members.filter((m) => m.online).length;
  $: leader = members.find((m) => m.isLeader);
  $: leaderName = leader?.name || roster?.leaderName || '—';
  $: leaderRank = leader?.rank || 'Leader';
  $: gangTiles = [
    { label: 'Total Members', value: members.length, icon: 'users', accent: '#5aa9e6', note: 'Registered gang operatives' },
    { label: 'Active Online', value: onlineCount, icon: 'activity', accent: '#70b982', note: 'Currently online' },
    { label: 'Gang Leader', value: leaderName, icon: 'crown', accent: '#e0b252', note: leaderRank },
    { label: 'Roles Configured', value: roles.length, icon: 'shield', accent: '#a78bdb', note: 'Access hierarchy tiers' },
  ];

  // ── Roles ──────────────────────────────────────────────────────────────────
  let rolePerms = {};
  let serverRanks = [];
  let rolesError = '';
  let selectedRole = '';
  let saving = {};

  let maxRoles = 5;                 // how many roles of its own a gang may have (Config.GangRoles.maxCustomRoles), from the server
  let customRoles = 0;
  let rolesLoaded = false;          // one load per visit: an empty answer must not trigger the reactive re-load below forever
  // EVERY member may read the roles (what each allows, who holds it); only manageGang changes them
  async function loadRoles() {
    rolesLoaded = true;
    const res = await getGangRolePermissions().catch(() => null);
    if (!res || !res.ok) { rolesError = (res && res.error) || ''; return; }
    rolesError = '';
    rolePerms = res.permissions || {};
    serverRanks = Array.isArray(res.ranks) ? res.ranks : [];
    if (res.maxRoles != null) maxRoles = Number(res.maxRoles);
    if (res.customRoles != null) customRoles = Number(res.customRoles);
  }
  $: atRoleLimit = customRoles >= maxRoles;

  // Roles = ranks held by members + roles created but not yet assigned.
  $: roles = serverRanks.length ? serverRanks
    .filter((r) => r && r.name)
    .map((r) => ({ name: r.name, count: r.count || 0, leaderRole: !!r.isLeaderRole }))
    .sort((a, b) => (b.leaderRole - a.leaderRole) || (a.name === 'Member' ? -1 : b.name === 'Member' ? 1 : a.name.localeCompare(b.name)))
  : (() => {
    const map = new Map();
    // A role is the untouchable "leader role" only when the leader is its SOLE
    // holder. Ranks default to 'Member' for everyone, so if the leader still has
    // 'Member' and so do ordinary members, that role must stay editable.
    for (const m of members) {
      const r = map.get(m.rank) || { name: m.rank, count: 0, hasLeader: false, hasOthers: false, leaderRole: false };
      r.count += 1;
      if (m.isLeader) r.hasLeader = true; else r.hasOthers = true;
      r.leaderRole = r.hasLeader && !r.hasOthers;
      map.set(m.rank, r);
    }
    for (const r of serverRanks) {
      if (r && r.name && !map.has(r.name)) map.set(r.name, { name: r.name, count: 0, leaderRole: false });
    }
    for (const name of Object.keys(rolePerms)) {
      if (!map.has(name)) map.set(name, { name, count: 0, leaderRole: false });
    }
    if (!map.has('Member')) map.set('Member', { name: 'Member', count: 0, leaderRole: false });
    return [...map.values()].sort((a, b) => (b.leaderRole - a.leaderRole) || a.name.localeCompare(b.name));
  })();
  $: if (!roles.some((r) => r.name === selectedRole)) selectedRole = roles[0]?.name || '';
  $: currentRole = roles.find((r) => r.name === selectedRole) || null;

  function has(role, key) {
    if (!role) return false;
    if (role.leaderRole) return true;
    return rolePerms[role.name]?.[key] === true;
  }

  async function toggle(role, key) {
    if (!canManageGang || !role || role.leaderRole) return;
    const id = `${role.name}:${key}`;
    if (saving[id]) return;
    saving = { ...saving, [id]: true };
    const res = await setGangRolePermission(role.name, key, !has(role, key)).catch(() => null);
    saving = { ...saving, [id]: false };
    if (!res || !res.ok) { rolesError = (res && res.error) || 'Failed to save permission.'; return; }
    rolesError = '';
    await loadRoles();
  }

  // Add-role modal
  let roleModal = false;
  let newRole = { name: '', perms: {} };
  let roleFormError = '';
  function openCreateRole() {
    if (atRoleLimit) { rolesError = `A gang can have at most ${maxRoles} roles of its own (besides Leader and Member). Delete one first.`; return; }
    newRole = { name: '', perms: { registerRoster: true } };
    roleFormError = '';
    roleModal = true;
  }
  async function createRole() {
    const name = newRole.name.trim();
    if (!name) { roleFormError = 'Give the role a name.'; return; }
    if (roles.some((r) => r.name.toLowerCase() === name.toLowerCase())) { roleFormError = 'That role already exists.'; return; }
    const res = await saveGangRole(name, newRole.perms).catch(() => null);
    if (!res || !res.ok) { roleFormError = (res && res.error) || 'Failed to create role.'; return; }
    roleModal = false;
    roleFormError = '';
    await loadRoles();
    selectedRole = name;
  }

  // Rename role modal
  let renameModal = false;
  let renameOldRole = '';
  let renameNewRole = '';
  let renameError = '';
  function openRenameRole(r) {
    renameOldRole = r.name;
    renameNewRole = r.name;
    renameError = '';
    renameModal = true;
  }
  async function submitRenameRole() {
    const newName = renameNewRole.trim();
    if (!newName) { renameError = 'Enter a new role name.'; return; }
    if (newName === renameOldRole) { renameModal = false; return; }
    const res = await renameGangRole(renameOldRole, newName).catch(() => null);
    if (!res || !res.ok) { renameError = (res && res.error) || 'Failed to rename role.'; return; }
    renameModal = false;
    await loadRoles();
    selectedRole = newName;
    dispatch('changed');
  }

  // Delete role confirmation
  let confirmDeleteRole = false;
  async function submitDeleteRole() {
    if (!currentRole || currentRole.leaderRole) return;
    const res = await deleteGangRole(currentRole.name).catch(() => null);
    confirmDeleteRole = false;
    if (!res || !res.ok) { rolesError = (res && res.error) || 'Failed to delete role.'; return; }
    await loadRoles();
    selectedRole = roles[0]?.name || '';
    dispatch('changed');
  }

  // ── Members: filter, search, paging ────────────────────────────────────────
  let filter = 'all';
  let search = '';
  let pageSize = 20;
  let page = 1;

  $: filtered = members.filter((m) => {
    if (filter === 'online' && !m.online) return false;
    if (filter === 'offline' && m.online) return false;
    if (filter === 'leader' && !m.isLeader) return false;
    const q = search.trim().toLowerCase();
    return !q || m.name.toLowerCase().includes(q) || m.rank.toLowerCase().includes(q) || String(m.serverId ?? '').includes(q);
  });
  $: totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));
  $: if (page > totalPages) page = totalPages;
  $: start = (page - 1) * pageSize;
  $: pageRows = filtered.slice(start, start + pageSize);
  $: { filter; search; pageSize; page = 1; }

  function initials(name) {
    const p = String(name).trim().split(/\s+/).filter(Boolean);
    return ((p[0]?.[0] || '?') + (p[1]?.[0] || '')).toUpperCase();
  }

  // ── Manage drawer ──────────────────────────────────────────────────────────
  let drawer = null;
  let drawerRole = '';
  let confirmRemove = false;
  let drawerError = '';
  let drawerBusy = false;

  function openDrawer(m) { drawer = m; drawerRole = m.rank; confirmRemove = false; drawerError = ''; }
  function closeDrawer() { drawer = null; }

  async function saveDrawer() {
    if (!drawer) return;
    if (drawerRole === drawer.rank) { closeDrawer(); return; }
    drawerBusy = true;
    const res = await setOwnGangMemberRank(drawer.identifier, drawerRole).catch(() => null);
    drawerBusy = false;
    if (!res || !res.ok) { drawerError = (res && res.error) || 'Could not change the role.'; return; }
    closeDrawer();
    dispatch('changed');
  }
  function promote() { dispatch('promoteMember', { identifier: drawer.identifier }); closeDrawer(); }
  function remove() { dispatch('removeMember', { identifier: drawer.identifier }); closeDrawer(); }

  // ── Add member modal ───────────────────────────────────────────────────────
  let addModal = false;
  let manualInput = '';
  let addRole = 'Member';
  let recruitSearch = '';
  $: recruits = (Array.isArray(availableRecruits) ? availableRecruits : []).filter(
    (p) => !recruitSearch.trim() || String(p.name || '').toLowerCase().includes(recruitSearch.trim().toLowerCase()) || String(p.serverId || '').includes(recruitSearch.trim())
  );
  function openAdd() {
    addModal = true;
    manualInput = '';
    recruitSearch = '';
    dispatch('refreshRecruits');
  }
  function addPlayer(target) {
    if (!String(target).trim()) return;
    dispatch('addMember', { target: String(target).trim(), rank: addRole });
  }
  function submitManualAdd() {
    if (!String(manualInput).trim()) return;
    addPlayer(manualInput);
    manualInput = '';
  }

  // a role / rank / member changed anywhere (the admin tablet edits the same data): read the roles again at once
  let unsubGang;
  let gangSeen = false;
  onMount(() => {
    loadRoles();
    unsubGang = gangVersion.subscribe(() => {
      if (!gangSeen) { gangSeen = true; return; }   // the first callback is the current value, not a change
      loadRoles();
    });
  });
  onDestroy(() => { if (unsubGang) unsubGang(); });
  $: if (!rolesLoaded && !Object.keys(rolePerms).length && !serverRanks.length) loadRoles();
</script>

<div class="mg">
  <div class="gtabs" role="tablist">
    <button class="gtab" class:active={tab === 'overview'} role="tab" on:click={() => (tab = 'overview')}>
      <Icon name="activity" size={14} />
      <span>Gang Overview</span>
    </button>
    <button class="gtab" class:active={tab === 'members'} role="tab" on:click={() => (tab = 'members')}>
      <Icon name="users" size={14} />
      <span>Members</span>
      <span class="gtab-count">{members.length}</span>
    </button>
  </div>

  {#if memberError}<div class="err">{memberError}</div>{/if}

  {#if !roster || !roster.gangName}
    <div class="panel empty-state">
      <div class="empty-title">No gang data yet</div>
      <div class="empty-sub">Your gang details are still loading, or you are not in a gang.</div>
    </div>
  {:else if tab === 'overview'}
    <div class="hero">
      <div class="hero-logo">
        <GangLogoUpload
          logo={roster.gangLogo}
          label={gangLabel}
          accentColor={roster.gangAccentColor}
          busy={logoBusy}
          disabled={!canManageGang}
          on:upload={(e) => dispatch('uploadLogo', e.detail)}
          on:remove={() => dispatch('removeLogo')}
        />
      </div>
      <div class="hero-info">
        <div class="hero-top">
          <span class="pill"><span class="dot on"></span>Operational</span>
          <span class="gid">GANG: {roster.gangName}</span>
        </div>
        <div class="hero-name">{gangLabel}</div>
        <div class="hero-desc">Manage gang hierarchy, member roster, role permissions and event access.</div>
        <div class="chips">
          <span class="chip">Gang Leader: {leaderName}</span>
          {#if canManageGang}<span class="chip verified">Authority: Verified</span>{/if}
        </div>
      </div>
      {#if canManageGang}
        <button class="btn primary" on:click={openAdd}>
          <Icon name="plus" size={13} />
          <span>Add Member</span>
        </button>
      {/if}
    </div>

    <StatStrip stats={gangTiles} />

    <!-- Role & Permission Management Section -->
    <div class="panel">
      <div class="panel-head">
        <div>
          <div class="panel-title">
            <Icon name="shield" size={16} />
            <span>Role &amp; Permission Management</span>
          </div>
          <div class="panel-sub">
            {#if canManageGang}Create custom roles, rename them, and individually configure permissions.{:else}What each role of your gang may do. Only a member with “Manage Gang” can change roles.{/if}
            <b class="role-limit" class:full={atRoleLimit}>{customRoles} of {maxRoles} own roles used</b>
          </div>
        </div>
        {#if canManageGang}
          <button class="btn primary" on:click={openCreateRole} disabled={atRoleLimit} title={atRoleLimit ? 'Role limit reached — delete a role first' : 'Create a role'}>
            <Icon name="plus" size={13} />
            <span>Create Role</span>
          </button>
        {/if}
      </div>
      {#if rolesError}<div class="err flat">{rolesError}</div>{/if}

      <div class="roles-grid">
        <div class="role-list">
          <div class="role-list-header">ROLES</div>
          {#each roles as r (r.name)}
            <button class="role-item" class:active={r.name === selectedRole} on:click={() => (selectedRole = r.name)}>
              <div class="role-name">{r.name}</div>
              <div class="role-count">{r.count} {r.count === 1 ? 'member' : 'members'}</div>
            </button>
          {/each}
        </div>

        <div class="role-detail">
          {#if currentRole}
            <div class="role-detail-header">
              <div>
                <div class="detail-title">{currentRole.name}{currentRole.leaderRole ? ' — Gang Leader' : ''}</div>
                <div class="detail-sub">
                  {currentRole.leaderRole ? 'The leader automatically holds every permission.' : canManageGang ? 'Toggle individual permissions to grant them to everyone assigned this role.' : 'Permissions granted to this role.'}
                </div>
              </div>
              {#if canManageGang && !currentRole.leaderRole}
                <div class="role-actions">
                  <button class="btn small" on:click={() => openRenameRole(currentRole)}>
                    <Icon name="edit" size={12} />
                    <span>Rename</span>
                  </button>
                  {#if !confirmDeleteRole}
                    <button class="btn small danger" on:click={() => (confirmDeleteRole = true)}>
                      <Icon name="trash" size={12} />
                      <span>Delete</span>
                    </button>
                  {:else}
                    <div class="confirm-inline">
                      <span>Delete role?</span>
                      <button class="btn small danger" on:click={submitDeleteRole}>Yes</button>
                      <button class="btn small" on:click={() => (confirmDeleteRole = false)}>No</button>
                    </div>
                  {/if}
                </div>
              {/if}
            </div>

            <div class="access-title">Individually Configurable Permissions</div>
            <div class="access-grid">
              {#each PERMISSIONS as p (p.key)}
                <button
                  class="access"
                  class:on={has(currentRole, p.key)}
                  disabled={!canManageGang || currentRole.leaderRole || saving[`${currentRole.name}:${p.key}`]}
                  on:click={() => toggle(currentRole, p.key)}
                >
                  <span class="check">{has(currentRole, p.key) ? '✓' : ''}</span>
                  <span class="access-text">
                    <span class="access-name">{p.label}</span>
                    <span class="access-desc">{p.hint}</span>
                  </span>
                </button>
              {/each}
            </div>
          {/if}
        </div>
      </div>
    </div>
  {:else}
    <!-- Members Management View (Dark charcoal / Orange accent redesign) -->
    <div class="panel">
      <div class="panel-head">
        <div class="panel-title">
          <Icon name="users" size={16} />
          <span>Member Roster</span>
          <span class="count">{members.length} {members.length === 1 ? 'Member' : 'Members'}</span>
        </div>
        {#if canManageGang}
          <button class="btn primary" on:click={openAdd}>
            <Icon name="plus" size={13} />
            <span>Add Member</span>
          </button>
        {/if}
      </div>

      <div class="toolbar">
        <button class="filter" class:active={filter === 'all'} on:click={() => (filter = 'all')}>All ({members.length})</button>
        <button class="filter" class:active={filter === 'online'} on:click={() => (filter = 'online')}>Online ({onlineCount})</button>
        <button class="filter" class:active={filter === 'offline'} on:click={() => (filter = 'offline')}>Offline ({members.length - onlineCount})</button>
        <button class="filter" class:active={filter === 'leader'} on:click={() => (filter = 'leader')}>Leaders</button>
        <div class="search-wrap">
          <Icon name="search" size={13} />
          <input class="search-input" placeholder="Search by name, role or ID..." bind:value={search} />
        </div>
      </div>

      {#if filtered.length === 0}
        <div class="empty-state">
          <div class="empty-title">{members.length === 0 ? 'No members yet' : 'No members match'}</div>
          <div class="empty-sub">{members.length === 0 ? 'Add someone using their Member Name or Server ID to build your roster.' : 'Try a different filter or search query.'}</div>
        </div>
      {:else}
        <TablePager top bind:page bind:pageSize total={filtered.length} noun="members" sizes={[10, 20, 50, 100]} />
        <div class="table-wrap">
          <table class="member-table">
            <thead>
              <tr>
                <th>Member</th>
                <th>Role</th>
                <th>Status</th>
                <th class="right">{canManageGang ? 'Action' : ''}</th>
              </tr>
            </thead>
            <tbody>
              {#each pageRows as m (m.identifier)}
                <tr>
                  <td>
                    <div class="who">
                      <div class="avatar">{initials(m.name)}</div>
                      <div>
                        <div class="m-name">{m.name}</div>
                        <div class="m-sub">{m.serverId != null && m.online ? `ID: ${m.serverId}` : m.isLeader ? 'Leader' : 'Member'}</div>
                      </div>
                    </div>
                  </td>
                  <td>
                    <span class="role-tag" class:leader={m.isLeader}>{m.isLeader ? 'Leader' : m.rank}</span>
                  </td>
                  <td>
                    <span class="status">
                      <span class="dot" class:on={m.online}></span>
                      <span>{m.online ? 'Online' : 'Offline'}</span>
                    </span>
                  </td>
                  <td class="right">
                    {#if canManageGang && !(m.isLeader && !isLeader)}
                      <button class="btn small" on:click={() => openDrawer(m)}>Manage</button>
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>
  {/if}
</div>

<!-- Manage member drawer -->
{#if drawer}
  <div class="backdrop" on:click|self={closeDrawer} role="presentation">
    <aside class="drawer">
      <div class="modal-head">
        <div>
          <div class="modal-title">Manage Member</div>
          <div class="modal-sub">Update role assignment and authority</div>
        </div>
        <button class="x" on:click={closeDrawer} aria-label="Close">✕</button>
      </div>

      <div class="d-member">
        <div class="avatar big">{initials(drawer.name)}</div>
        <div>
          <div class="m-name">{drawer.name}</div>
          <div class="m-sub">{drawer.online ? 'Online' : 'Offline'}</div>
        </div>
      </div>

      {#if drawerError}<div class="err flat">{drawerError}</div>{/if}

      {#if !drawer.isLeader}
        <div class="d-section">
          <div class="d-label">Role Assignment</div>
          <select class="input" bind:value={drawerRole}>
            {#each roles.filter((r) => !r.leaderRole) as r (r.name)}
              <option value={r.name}>{r.name}</option>
            {/each}
          </select>
        </div>

        <div class="d-section">
          <div class="d-label">Actions</div>
          {#if isLeader}
            <button class="d-action" disabled={memberBusy} on:click={promote}>
              <Icon name="crown" size={13} />
              <span>Promote to Gang Leader</span>
            </button>
          {/if}
          {#if !confirmRemove}
            <button class="d-action danger" on:click={() => (confirmRemove = true)}>
              <Icon name="trash" size={13} />
              <span>Remove Member from Gang</span>
            </button>
          {:else}
            <div class="confirm">
              <span>Remove {drawer.name} from the gang?</span>
              <button class="btn small danger" disabled={memberBusy} on:click={remove}>Yes, remove</button>
              <button class="btn small" on:click={() => (confirmRemove = false)}>No</button>
            </div>
          {/if}
        </div>
      {:else}
        <div class="d-section">
          <div class="m-sub">The leader's role cannot be modified here.</div>
        </div>
      {/if}

      <div class="d-foot">
        <button class="btn" on:click={closeDrawer}>Cancel</button>
        {#if !drawer.isLeader}
          <button class="btn primary" disabled={drawerBusy} on:click={saveDrawer}>Save Changes</button>
        {/if}
      </div>
    </aside>
  </div>
{/if}

<!-- Create role modal -->
{#if roleModal}
  <div class="backdrop center" on:click|self={() => (roleModal = false)} role="presentation">
    <div class="modal">
      <div class="modal-head">
        <div>
          <div class="modal-title">Create Custom Role</div>
          <div class="modal-sub">Enter role name and configure individual permissions.</div>
        </div>
        <button class="x" on:click={() => (roleModal = false)} aria-label="Close">✕</button>
      </div>

      {#if roleFormError}<div class="err flat">{roleFormError}</div>{/if}

      <div class="form">
        <label class="field">
          <span>Role Name</span>
          <input class="input" maxlength="40" placeholder="e.g. Captain, Sergeant, Enforcer" bind:value={newRole.name} />
        </label>

        <div class="field">
          <span>Permissions</span>
          <div class="perm-grid">
            {#each PERMISSIONS as p (p.key)}
              <label class="perm" class:checked={newRole.perms[p.key]}>
                <input type="checkbox" bind:checked={newRole.perms[p.key]} />
                <span class="perm-label">{p.label}</span>
              </label>
            {/each}
          </div>
        </div>
      </div>

      <div class="d-foot">
        <button class="btn" on:click={() => (roleModal = false)}>Cancel</button>
        <button class="btn primary" on:click={createRole}>Create Role</button>
      </div>
    </div>
  </div>
{/if}

<!-- Rename role modal -->
{#if renameModal}
  <div class="backdrop center" on:click|self={() => (renameModal = false)} role="presentation">
    <div class="modal small">
      <div class="modal-head">
        <div>
          <div class="modal-title">Rename Role</div>
          <div class="modal-sub">Change name from "{renameOldRole}"</div>
        </div>
        <button class="x" on:click={() => (renameModal = false)} aria-label="Close">✕</button>
      </div>

      {#if renameError}<div class="err flat">{renameError}</div>{/if}

      <div class="form">
        <label class="field">
          <span>New Role Name</span>
          <input class="input" maxlength="40" bind:value={renameNewRole} />
        </label>
      </div>

      <div class="d-foot">
        <button class="btn" on:click={() => (renameModal = false)}>Cancel</button>
        <button class="btn primary" on:click={submitRenameRole}>Save Name</button>
      </div>
    </div>
  </div>
{/if}

<!-- Add member modal (Supports Member Name or Server ID) -->
{#if addModal}
  <div class="backdrop center" on:click|self={() => (addModal = false)} role="presentation">
    <div class="modal">
      <div class="modal-head">
        <div>
          <div class="modal-title">Add Gang Member</div>
          <div class="modal-sub">Add by Member Name or Server ID, or select an online recruit.</div>
        </div>
        <button class="x" on:click={() => (addModal = false)} aria-label="Close">✕</button>
      </div>

      <div class="form">
        <label class="field">
          <span>Role to Assign</span>
          <select class="input" bind:value={addRole}>
            {#each roles.filter((r) => !r.leaderRole) as r (r.name)}
              <option value={r.name}>{r.name}</option>
            {/each}
          </select>
        </label>

        <!-- Direct search/add by Member Name or Server ID -->
        <div class="field">
          <span>Add by Member Name or Server ID</span>
          <div class="manual-input-row">
            <input
              class="input"
              placeholder="Enter Player Name or Server ID (e.g. 1 or John_Doe)"
              bind:value={manualInput}
              on:keydown={(e) => e.key === 'Enter' && submitManualAdd()}
            />
            <button class="btn primary" disabled={!manualInput.trim()} on:click={submitManualAdd}>
              <Icon name="plus" size={13} />
              <span>Add</span>
            </button>
          </div>
        </div>

        <!-- Online recruit list -->
        <div class="field">
          <div class="recruit-header">
            <span>Online Available Recruits</span>
            <input
              class="recruit-filter"
              placeholder="Filter online players..."
              bind:value={recruitSearch}
            />
          </div>
          <div class="recruits">
            {#if recruits.length === 0}
              <div class="pad">
                <span class="m-sub">No unassigned online players found.</span>
              </div>
            {:else}
              {#each recruits as p (p.serverId)}
                <div class="recruit">
                  <div class="avatar small">{initials(p.name || '?')}</div>
                  <div class="grow">
                    <div class="m-name">{p.name}</div>
                    <div class="m-sub">Server ID: {p.serverId}</div>
                  </div>
                  <button class="btn small primary" on:click={() => addPlayer(p.serverId)}>
                    + Add
                  </button>
                </div>
              {/each}
            {/if}
          </div>
        </div>
      </div>

      <div class="d-foot">
        <button class="btn" on:click={() => (addModal = false)}>Close</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .mg {
    display: flex;
    flex-direction: column;
    gap: 16px;
    width: 100%;
    color: var(--lt-eceef0, #eceef0);
  }

  .gtabs {
    display: flex;
    gap: 6px;
    padding: 0 16px;
    background: var(--c-base);
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
  }

  .gtab {
    position: relative;
    height: 48px;
    padding: 0 16px;
    border: 0;
    background: transparent;
    color: var(--text-dim, #c9ced4);
    font-size: var(--fs-body);
    font-weight: 600;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 8px;
    transition: color 0.15s ease;
  }

  .gtab:hover {
    color: var(--lt-ffffff, #ffffff);
  }

  .gtab.active {
    color: var(--lt-ffffff, #ffffff);
    font-weight: 700;
  }

  .gtab.active::after {
    content: '';
    position: absolute;
    left: 12px;
    right: 12px;
    bottom: -1px;
    height: 2px;
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, inherit);
}

  .gtab-count {
    min-width: 20px;
    height: 18px;
    padding: 0 5px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--r-tag);
    background: var(--c-action);
    color: var(--on-accent);
    font-size: var(--fs-meta);
    font-weight: 700;
  }

  .panel {
    background: var(--c-panel);
    border: 1px solid var(--c-raised);
    border-radius: var(--r-panel);
    overflow: hidden;
  }
  .panel :global(.tp) {
    border-left: none;
    border-right: none;
    border-top: none;
    border-radius: 0;
    border-bottom: 1px solid var(--c-raised);
    background: var(--c-base);
  }

  .panel-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 16px 20px;
    border-bottom: 1px solid var(--c-raised);
    background: var(--c-base);
  }

  .panel-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
  }

  .panel-sub {
    margin-top: 3px;
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
  }

  .count {
    padding: 2px 7px;
    border-radius: var(--r-tag);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-dim, #c9ced4);
  }

  .hero {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    gap: 24px;
    align-items: center;
    padding: 22px 24px;
    background: var(--c-panel);
    border: 1px solid var(--c-raised);
    border-radius: var(--r-panel);
  }

  .hero-top {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 6px;
  }

  .pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 9px;
    border: 1px solid rgb(112, 185, 130);
    border-radius: 999px;
    background: rgb(112, 185, 130);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
  }

  .gid {
    color: var(--text-dim, #c9ced4);
    font-size: var(--fs-small);
    font-weight: 600;
  }

  .hero-name {
    font-size: var(--fs-section);
    line-height: 30px;
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
  }

  .hero-desc {
    margin-top: 5px;
    color: var(--text-dim, #c9ced4);
    font-size: var(--fs-body);
    line-height: 19px;
    max-width: 680px;
  }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 14px;
  }

  .chip {
    padding: 5px 10px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-tag);
    background: var(--c-base);
    color: var(--text-dim, #c9ced4);
    font-size: var(--fs-meta);
  }

  .chip.verified {
    border-color: var(--c-action);
    color: var(--on-accent);
    background: var(--c-action);
  }

  /* Roles Grid */
  .role-limit { margin-left: 8px; font-weight: 600; color: var(--text-dim, #c9ced4); }
  .role-limit.full { color: #ffb020; }
  .roles-grid {
    display: grid;
    grid-template-columns: 240px minmax(0, 1fr);
    min-height: 280px;
  }

  .role-list {
    padding: 12px;
    border-right: 1px solid var(--c-raised);
    background: var(--c-base);
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .role-list-header {
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--text-muted, #aeb5bd);
    letter-spacing: 0.01em;
    padding: 4px 8px;
  }

  .role-item {
    padding: 9px 12px;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    background: transparent;
    color: var(--text-dim, #c9ced4);
    text-align: left;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .role-item:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.03);
    color: var(--lt-ffffff, #ffffff);
  }

  .role-item.active {
    background: var(--c-base);
    border-color: var(--c-raised);
    color: var(--lt-ffffff, #ffffff);
    border-left: 3px solid var(--accent-primary);
  }

  .role-name {
    font-size: var(--fs-body);
    font-weight: 700;
  }

  .role-count {
    margin-top: 2px;
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
  }

  .role-detail {
    padding: 20px 24px;
  }

  .role-detail-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    padding-bottom: 16px;
    border-bottom: 1px solid var(--c-raised);
  }

  .detail-title {
    font-size: var(--fs-emph);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
  }

  .detail-sub {
    margin-top: 4px;
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
  }

  .role-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .confirm-inline {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
  }

  .access-title {
    margin-top: 18px;
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--accent-primary);
  }

  .access-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    margin-top: 12px;
  }

  .access {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 11px 13px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    color: var(--text-dim, #c9ced4);
    text-align: left;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .access:disabled {
    cursor: default;
  }

  .access:not(:disabled):hover {
    border-color: rgba(var(--accent-primary-rgb), 0.4);
    color: var(--lt-ffffff, #ffffff);
  }

  .access.on {
    border-color: rgba(var(--accent-primary-rgb), 0.5);
    background: rgba(var(--accent-primary-rgb), 0.05);
    color: var(--lt-ffffff, #ffffff);
  }

  .check {
    width: 20px;
    height: 20px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-tag);
    background: var(--c-base);
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--accent-primary);
  }

  .access.on .check {
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #ffffff);
    text-shadow: none;
    border-color: var(--es-accent, #4f94e6);
  }

  .access-text {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  .access-name {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
  }

  .access-desc {
    margin-top: 2px;
    font-size: var(--fs-meta);
    color: var(--text-dim, #c9ced4);
    line-height: 15px;
  }

  /* Toolbar */
  .toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 20px;
    border-bottom: 1px solid var(--c-raised);
    background: var(--c-panel);
    flex-wrap: wrap;
  }

  .filter {
    height: 32px;
    padding: 0 12px;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    background: transparent;
    color: var(--text-dim, #c9ced4);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.12s ease;
  }

  .filter:hover {
    color: var(--lt-ffffff, #ffffff);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.03);
  }

  .filter.active {
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #ffffff);
    text-shadow: none;
    font-weight: 700;
  }

  .search-wrap {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--c-base);
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    padding: 0 10px;
    height: 32px;
    color: var(--text-muted, #aeb5bd);
    width: 260px;
  }

  .search-wrap:focus-within {
    border-color: var(--es-accent, #4f94e6);
    color: var(--accent-primary);
  }

  .search-input {
    background: transparent;
    border: none;
    outline: none;
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-small);
    width: 100%;
  }

  .search-input::placeholder {
    color: var(--text-muted, #aeb5bd);
  }

  /* Table */
  .table-wrap {
    overflow-x: auto;
  }

  .member-table {
    width: 100%;
    border-collapse: collapse;
  }

  .member-table th {
    height: 40px;
    padding: 0 var(--tbl-x);
    text-align: left;
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    white-space: nowrap;
  }

  .member-table td {
    height: 52px;
    padding: var(--tbl-td-y) var(--tbl-x);
    border-bottom: 1px solid var(--c-line-soft);
    font-size: var(--fs-body);
    vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }

  .member-table tbody tr:hover {
    background: rgba(var(--accent-primary-rgb), 0.03);
  }

  .right {
    text-align: right;
  }

  .who {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .avatar {
    width: 36px;
    height: 36px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--r-tag);
    background: var(--c-base);
    border: 1px solid var(--c-raised);
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--accent-primary);
  }

  .avatar.small {
    width: 28px;
    height: 28px;
    font-size: var(--fs-meta);
  }

  .avatar.big {
    width: 44px;
    height: 44px;
    font-size: var(--fs-body);
  }

  .m-name {
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff);
  }

  .m-sub {
    margin-top: 1px;
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
  }

  .role-tag {
    display: inline-flex;
    padding: 3px 8px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-tag);
    background: var(--c-base);
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-dim, #c9ced4);
  }

  .role-tag.leader {
    border-color: var(--c-action);
    background: var(--c-action);
    color: var(--on-accent);
    font-weight: 600;
  }

  .status {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #4a5160;
  }

  .dot.on {
    background: #70b982;
    box-shadow: none;
  }

  .foot {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 48px;
    padding: 0 20px;
    border-top: 1px solid var(--c-raised);
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
  }

  .page-size {
    margin-left: auto;
    height: 28px;
    padding: 0 8px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-small);
    outline: none;
  }

  .pager {
    display: flex;
    gap: 4px;
  }

  .pg {
    min-width: 30px;
    height: 28px;
    padding: 0 8px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    color: var(--text-dim, #c9ced4);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
  }

  .pg:hover:not(:disabled) {
    color: var(--lt-ffffff, #ffffff);
    border-color: var(--es-accent, #4f94e6);
  }

  .pg.active {
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #ffffff);
    text-shadow: none;
    border-color: var(--es-accent, #4f94e6);
  }

  .pg:disabled {
    opacity: 0.4;
    cursor: default;
  }

  /* Buttons */
  .btn {
    height: 34px;
    padding: 0 14px;
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    background: var(--c-raised);
    color: var(--lt-c9ced4, #c9ced4);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    transition: all 0.15s ease;
  }

  .btn:hover:not(:disabled) {
    background: var(--c-hover);
    color: var(--lt-ffffff, #ffffff);
    border-color: #3b4254;
  }

  .btn.primary {
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #ffffff);
    text-shadow: none;
    border-color: var(--es-accent, #4f94e6);
    font-weight: 700;
  }

  .btn.primary:hover:not(:disabled) {
    background: var(--es-accent-hover, #66a3eb);
    border-color: var(--es-accent-hover, #66a3eb);
  }

  .btn.small {
    height: 28px;
    padding: 0 10px;
    font-size: var(--fs-meta);
  }

  .btn.danger:hover:not(:disabled) {
    background: #d9463e;
    border-color: #d9463e;
    color: var(--lt-ffffff, #ffffff);
  }

  .btn:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .empty-state {
    padding: 36px 20px;
    text-align: center;
  }

  .empty-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
  }

  .empty-sub {
    margin-top: 4px;
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
  }

  .err {
    padding: 10px 14px;
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    background: var(--c-raised);
    color: var(--lt-ff8a80, #ff8a80);
    font-size: var(--fs-small);
    border-left: 3px solid rgb(255, 69, 58);}

  .err.flat {
    margin: 12px 20px 0;
  }

  /* Modals & Drawers */
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 200;
    background: rgba(0, 0, 0, 0.8);
  }

  .backdrop.center {
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .drawer {
    position: absolute;
    top: 0;
    right: 0;
    width: min(420px, 92vw);
    height: 100%;
    padding: 20px;
    overflow-y: auto;
    background: var(--surface-dialog);
    border-left: 1px solid var(--c-line);
    display: flex;
    flex-direction: column;
  }

  .modal {
    width: min(560px, 92vw);
    max-height: 86vh;
    overflow-y: auto;
    padding: 20px;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-panel);
  }

  .modal.small {
    width: min(420px, 92vw);
  }

  .modal-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--c-raised);
  }

  .modal-title {
    font-size: var(--fs-emph);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
  }

  .modal-sub {
    margin-top: 2px;
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
  }

  .x {
    width: 28px;
    height: 28px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    color: var(--text-dim, #c9ced4);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .x:hover {
    color: var(--lt-ffffff, #ffffff);
    border-color: #3b4254;
  }

  .d-member {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px 0;
    border-bottom: 1px solid var(--c-raised);
  }

  .d-section {
    padding: 16px 0;
    border-bottom: 1px solid var(--c-raised);
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .d-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim, #c9ced4);
  }

  .d-action {
    min-height: 36px;
    padding: 0 12px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    color: var(--lt-ffffff, #ffffff);
    text-align: left;
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 8px;
    transition: all 0.15s ease;
  }

  .d-action:hover:not(:disabled) {
    background: var(--c-raised);
  }

  .d-action.danger:hover {
    border-color: rgba(255, 69, 58, 0.4);
    background: rgba(255, 69, 58, 0.15);
    color: #ff6b6b;
  }

  .confirm {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
    font-size: var(--fs-small);
  }

  .confirm span {
    flex: 1 1 100%;
    margin-bottom: 4px;
  }

  .d-foot {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 16px;
    margin-top: auto;
  }

  .form {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-top: 14px;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .field > span {
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-dim, #c9ced4);
  }

  .input {
    width: 100%;
    height: 36px;
    padding: 0 10px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-small);
    outline: none;
    transition: border-color 0.15s ease;
  }

  .input:focus {
    border-color: var(--es-accent, #4f94e6);
  }

  .manual-input-row {
    display: flex;
    gap: 6px;
  }

  .manual-input-row .input {
    flex: 1;
  }

  .perm-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
    max-height: 240px;
    overflow-y: auto;
    padding-right: 4px;
  }

  .perm {
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 8px 10px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-dim, #c9ced4);
    cursor: pointer;
    transition: all 0.12s ease;
  }

  .perm:hover {
    border-color: #3b4254;
    color: var(--lt-ffffff, #ffffff);
  }

  .perm.checked {
    border-color: var(--accent-primary);
    background: var(--c-hover);
    color: var(--lt-ffffff, #ffffff);
  }

  .perm input {
    accent-color: var(--accent-primary);
  }

  .recruit-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 4px;
  }

  .recruit-filter {
    height: 26px;
    padding: 0 8px;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-tag);
    background: var(--c-base);
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-meta);
    outline: none;
    width: 160px;
  }

  .recruits {
    max-height: 200px;
    overflow-y: auto;
    border: 1px solid var(--c-raised);
    border-radius: var(--r-ctl);
    background: var(--c-base);
  }

  .recruit {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    border-bottom: 1px solid var(--c-raised);
  }

  .recruit:last-child {
    border-bottom: 0;
  }

  .grow {
    flex: 1;
    min-width: 0;
  }

  .pad {
    padding: 14px;
    text-align: center;
  }

  @media (max-width: 1100px) {
    .hero { grid-template-columns: 1fr; text-align: center; justify-items: center; }
    .hero-top, .chips { justify-content: center; }
    .roles-grid { grid-template-columns: 1fr; }
    .role-list { border-right: 0; border-bottom: 1px solid var(--lt-1f2328, #1f2328); flex-direction: row; overflow-x: auto; }
    .role-item { min-width: 140px; }
    .access-grid, .perm-grid { grid-template-columns: 1fr; }
  }
</style>
