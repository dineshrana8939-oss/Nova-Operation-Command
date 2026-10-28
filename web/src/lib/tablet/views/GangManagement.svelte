<script>
  import { defaultPageSize } from '../../adminPrefs.js';
  import { onMount, onDestroy } from 'svelte';
  import {
    getGangs, createGang, deleteGang, updateGang, addGangMember, removeGangMember, getGangRecruitsAdmin,
    setGangLeader, setGangMemberRank, setGangLogo, setGangAccentColor,
    getAdminGangRoles, setAdminGangRolePermission, saveAdminGangRole, renameAdminGangRole, deleteAdminGangRole,
  } from '../../api/gang.js';
  import { GANG_PERMISSIONS, DEFAULT_GANG_ROLE } from '../../gangPerms.js';
  import { peek, keep } from '../ui/viewCache.js';
  import { bootstrap, gangVersion } from '../../stores.js';
  import { can, canSeeSection } from '../../perms.js';
  import { territoryState, xpBoard, refreshTerritoryState } from '../../territory/territoryStore.js';
  import { getXpBoard, adminDisbandGang } from '../../api/territory.js';
  import GangAdminTools from './GangAdminTools.svelte';
  import { confirmAction } from '../ui/confirm.js';
  import { avatarColor, initials } from '../../util/avatar.js';
  import Icon from '../ui/Icon.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import GangLogo from '../ui/GangLogo.svelte';
  import GangLogoUpload from '../ui/GangLogoUpload.svelte';
  import SearchBox from '../ui/SearchBox.svelte';
  import FilterSelect from '../ui/FilterSelect.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import SubTabs from '../ui/SubTabs.svelte';
  import '../tablet-theme.css';

  // One place for everything about a gang. Territory / XP / notices / warnings need the territory (Map Zone) permission; the server
  // checks every action again, this only hides what the admin cannot use.
  const TAB_LABELS = { Members: 'Members', Roles: 'Roles & Permissions', Territory: 'Territory Control', XP: 'Gang XP', Messages: 'Notices & Warnings', Admin: 'Administration' };
  const TAB_ICONS = { Members: 'users', Roles: 'shield', Territory: 'pin', XP: 'zap', Messages: 'megaphone', Admin: 'gear' };
  $: gangOps = !!$bootstrap && canSeeSection($bootstrap.perms, 'mapzone');
  $: subTabItems = detailTabs.map((t) => ({ id: t, label: TAB_LABELS[t], icon: TAB_ICONS[t] }));
  $: detailTabs = ['Members', 'Roles', ...(gangOps ? ['Territory', 'XP', 'Messages'] : []), 'Admin'];

  // The gang list is remembered for the session (stale-while-revalidate): coming back to this tab shows the last list at once and
  // refreshes it in the background instead of flashing "Loading gangs…" and then jumping to the real height.
  let gangs = peek('gangs') || [];
  let loading = !peek('gangs');
  let selectedId = null;
  let detailTab = 'Members';
  let creating = false;
  let newGang = { name: '', label: '', maxMembers: 20 };
  let newMember = { serverId: '', rank: 'Member', showForm: false };
  let error = '';
  let logoBusy = false;
  let settingsDraft = null;
  let settingsSaving = false;
  let settingsSavedFlash = false;
  let settingsSavedFlashTimer;

  $: selected = gangs.find((g) => g.id === selectedId) || null;

  // ── Gang list: search + status picklist + paging ───────────────────────────
  const GANG_STATUS_OPTIONS = [
    { value: 'ALL', label: 'All statuses' },
    { value: 'ACTIVE', label: 'Active' },
    { value: 'SUSPENDED', label: 'Suspended' },
  ];
  let gSearch = '';
  let gStatus = 'ALL';
  let gPage = 1;
  let gSize = defaultPageSize([10, 15, 25, 50]);
  const leaderNameOf = (g) => g.members.find((m) => m.identifier === g.leaderIdentifier)?.name || '';

  $: filteredGangs = gangs.filter((g) => {
    const q = gSearch.toLowerCase().trim();
    if (q && !((g.label || '').toLowerCase().includes(q) || (g.name || '').toLowerCase().includes(q) || leaderNameOf(g).toLowerCase().includes(q))) return false;
    if (gStatus === 'ACTIVE' && !g.canParticipate) return false;
    if (gStatus === 'SUSPENDED' && g.canParticipate) return false;
    return true;
  });
  $: gFiltersActive = gSearch.trim() !== '' || gStatus !== 'ALL';
  $: pagedGangs = filteredGangs.slice((gPage - 1) * gSize, gPage * gSize);
  const resetGPage = () => { gPage = 1; };
  $: resetGPage(gSearch, gStatus);

  // ── Member list inside a gang: search + rank/online picklists + paging ─────
  const MEMBER_STATUS_OPTIONS = [
    { value: 'ALL', label: 'Online & offline' },
    { value: 'ONLINE', label: 'Online' },
    { value: 'OFFLINE', label: 'Offline' },
  ];
  let mSearch = '';
  let mStatus = 'ALL';
  let mRank = 'ALL';
  let mPage = 1;
  let mSize = defaultPageSize([10, 15, 25, 50]);
  const rankOfMember = (g, m) => (g.leaderIdentifier === m.identifier ? 'Leader' : (m.rank || 'Member'));
  $: memberRankOptions = selected
    ? [{ value: 'ALL', label: 'All ranks' }, ...[...new Set(selected.members.map((m) => rankOfMember(selected, m)))].sort().map((r) => ({ value: r, label: r }))]
    : [{ value: 'ALL', label: 'All ranks' }];
  $: filteredMembers = selected ? selected.members.filter((m) => {
    const q = mSearch.toLowerCase().trim();
    if (q && !((m.name || m.identifier || '').toLowerCase().includes(q))) return false;
    if (mStatus === 'ONLINE' && !m.online) return false;
    if (mStatus === 'OFFLINE' && m.online) return false;
    if (mRank !== 'ALL' && rankOfMember(selected, m) !== mRank) return false;
    return true;
  }) : [];
  $: pagedMembers = filteredMembers.slice((mPage - 1) * mSize, mPage * mSize);
  const resetMPage = () => { mPage = 1; };
  $: resetMPage(mSearch, mStatus, mRank);
  // opening a different gang starts from clean filters
  function resetMemberFilters() { mSearch = ''; mStatus = 'ALL'; mRank = 'ALL'; mPage = 1; }
  $: resetMemberFilters(selectedId);
  $: readOnly = $bootstrap && $bootstrap.gangProvider !== 'internal';
  // Rebuilds settingsDraft from `selected` — but `selected` is a NEW object
  // reference every time refresh() re-fetches gangs from the server (create/
  // remove/toggle/save/add-member/etc. all call it), so this used to
  // silently wipe whatever the admin was mid-typing into Gang Name/Max
  // Members/Accent Color the moment ANY other action in this panel (e.g.
  // the participation toggle sitting right there in the same form)
  // triggered a refresh. Only re-syncs when the SELECTED GANG ID actually
  // changes, not on every refetch of the same gang.
  let settingsDraftId = null;
  $: if (selected && selected.id !== settingsDraftId) {
    // maxMembers falls back to 20 here — a gang created without one set
    // (or one predating this field) left the input looking blank/broken
    // instead of showing what the server was actually already enforcing.
    settingsDraft = { label: selected.label, maxMembers: selected.maxMembers || 20, accentColor: selected.accentColor || avatarColor(selected.label || selected.name) };
    settingsDraftId = selected.id;
  } else if (!selected) {
    settingsDraftId = null;
  }

  // silent = a background re-read (after an action, or because the server said this gang changed): no "Loading" state at all
  async function refresh(silent = false) {
    if (!silent && !gangs.length) loading = true;
    const res = await getGangs();
    if (res && res.ok) { gangs = keep('gangs', res.gangs || []); }
    else if (!silent) gangs = [];
    if (selectedId && !gangs.find((g) => g.id === selectedId)) {
      selectedId = null;
    }
    loading = false;
  }

  // ── Roles & permissions of the open gang ───────────────────────────────────
  // The very same roles (one stored list, one set of server rules) the gang's leader edits in Event Status. A role is a rank
  // name plus what it may do; a member can only be given a role that exists here.
  const PERMS = GANG_PERMISSIONS;
  let rolePerms = {};
  let serverRanks = [];
  let rolesGangId = null;
  let rolesError = '';
  let rolesBusy = false;
  let selectedRole = '';
  async function loadRoles() {
    if (!selected) return;
    const id = selected.id;
    const res = await getAdminGangRoles(id).catch(() => null);
    if (!selected || selected.id !== id) return;          // another gang was opened meanwhile
    rolesGangId = id;
    if (!res || !res.ok) { rolesError = (res && res.error) || 'Could not load the roles.'; return; }
    rolesError = '';
    rolePerms = res.permissions || {};
    serverRanks = Array.isArray(res.ranks) ? res.ranks : [];
    if (res.maxRoles != null) maxRoles = Number(res.maxRoles);
    if (res.customRoles != null) customRoles = Number(res.customRoles);
  }
  let maxRoles = 5;            // roles of its own a gang may have (Config.GangRoles.maxCustomRoles), from the server
  let customRoles = 0;
  $: atRoleLimit = customRoles >= maxRoles;
  // opening another gang loads ITS roles (the Members tab needs them for the rank pickers too)
  $: if (selected && selected.id !== rolesGangId) { rolePerms = {}; serverRanks = []; selectedRole = ''; loadRoles(); }
  $: if (!selected) rolesGangId = null;

  $: roles = serverRanks
    .map((r) => ({ name: r.name, count: r.count || 0, leaderRole: !!r.isLeaderRole }))
    .sort((a, b) => (b.leaderRole - a.leaderRole) || (a.name === DEFAULT_GANG_ROLE ? -1 : b.name === DEFAULT_GANG_ROLE ? 1 : a.name.localeCompare(b.name)));
  $: if (!roles.some((r) => r.name === selectedRole)) selectedRole = roles[0]?.name || '';
  $: currentRole = roles.find((r) => r.name === selectedRole) || null;
  // what a member can be given: every role but the leader's own
  $: roleChoices = roles.filter((r) => !r.leaderRole).map((r) => r.name);
  // the role a member really holds: the leader is always "Leader" (whatever rank is stored), nobody else can hold that name
  const roleOfMember = (g, m) => (m.identifier === g.leaderIdentifier ? 'Leader' : (m.rank && m.rank !== 'Leader' ? m.rank : DEFAULT_GANG_ROLE));
  $: roleHolders = currentRole && selected ? selected.members.filter((m) => roleOfMember(selected, m) === currentRole.name) : [];
  $: has = (role, key) => !!role && (role.leaderRole || rolePerms[role.name]?.[key] === true);
  $: canEditRole = (role) => !!role && !readOnly && !role.leaderRole;

  async function runRoleAction(fn, fallback) {
    rolesBusy = true;
    const res = await fn().catch(() => null);
    rolesBusy = false;
    if (!res || !res.ok) { rolesError = (res && res.error) || fallback; return false; }
    rolesError = '';
    await Promise.all([loadRoles(), refresh(true)]);
    return true;
  }
  const togglePerm = (role, key) => canEditRole(role) && !rolesBusy && runRoleAction(() => setAdminGangRolePermission(selected.id, role.name, key, !has(role, key)), 'Failed to save permission.');

  let roleForm = null;               // null | { mode: 'create' | 'rename', name, perms: {…}, error }
  function openCreateRole() {
    if (atRoleLimit) { rolesError = `A gang can have at most ${maxRoles} roles of its own (besides Leader and Member). Delete one first.`; return; }
    roleForm = { mode: 'create', name: '', perms: { registerRoster: true }, error: '' };
  }
  function openRenameRole() { if (currentRole) roleForm = { mode: 'rename', name: currentRole.name, perms: {}, error: '' }; }
  async function submitRoleForm() {
    const name = roleForm.name.trim();
    if (!name) { roleForm.error = 'Give the role a name.'; return; }
    if (roleForm.mode === 'create') {
      if (roles.some((r) => r.name.toLowerCase() === name.toLowerCase())) { roleForm.error = 'That role already exists.'; return; }
      if (await runRoleAction(() => saveAdminGangRole(selected.id, name, roleForm.perms), 'Failed to create the role.')) { selectedRole = name; roleForm = null; }
      else roleForm.error = rolesError;
    } else {
      if (name === currentRole.name) { roleForm = null; return; }
      if (await runRoleAction(() => renameAdminGangRole(selected.id, currentRole.name, name), 'Failed to rename the role.')) { selectedRole = name; roleForm = null; }
      else roleForm.error = rolesError;
    }
  }
  async function deleteRole() {
    if (!currentRole) return;
    const ok = await confirmAction(`Delete the role "${currentRole.name}"?\n\n${currentRole.count ? `${currentRole.count} member${currentRole.count === 1 ? '' : 's'} holding it become "${DEFAULT_GANG_ROLE}".` : 'Nobody holds it.'}\n\nThe gang's leader sees the change in Event Status at once.`, { title: 'Delete Role', danger: true, confirmLabel: 'Delete role' });
    if (!ok) return;
    selectedRole = '';
    await runRoleAction(() => deleteAdminGangRole(selected.id, currentRole.name), 'Failed to delete the role.');
  }
  $: if (detailTab !== 'Roles') roleForm = null;

  // Whenever the server says a gang changed (an admin here, the gang's leader in Event Status, a member joining…) read it again
  // — quietly, and once for a burst of changes.
  let gvSeen = false;
  let gvTimer;
  const unsubGang = gangVersion.subscribe(() => {
    if (!gvSeen) { gvSeen = true; return; }          // the first callback is the current value, not a change
    clearTimeout(gvTimer);
    gvTimer = setTimeout(() => { refresh(true); if (selected) loadRoles(); }, 120);
  });
  onDestroy(() => { unsubGang(); clearTimeout(gvTimer); });

  // The detail view now REPLACES the gang list entirely (see the template's
  // {#if !selected} / {#if selected} split) rather than expanding below it,
  // so there's no longer anything above it to scroll past.
  function toggleManage(gang) {
    if (selectedId === gang.id) {
      selectedId = null;
    } else {
      selectedId = gang.id;
      detailTab = 'Members';
    }
  }

  function closeManage() {
    selectedId = null;
  }

  // Discards whatever was typed and clears any leftover error — a fresh
  // "New Gang" open (e.g. after accidentally clicking the button) should
  // never carry a half-filled name or a stale validation message over.
  function cancelCreate() {
    creating = false;
    error = '';
    newGang = { name: '', label: '', maxMembers: 20 };
  }

  async function createNewGang() {
    error = '';
    if (newGang.name.trim().length < 2) { error = 'Gang name is too short.'; return; }
    const res = await createGang(newGang.name, newGang.label || newGang.name, Number(newGang.maxMembers) || 20);
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to create gang.'; return; }
    creating = false;
    newGang = { name: '', label: '', maxMembers: 20 };
    await refresh();
  }

  let disbandMode = 'RELEASE';       // RELEASE (territories become unclaimed) | DELETE (removed from the map)
  let disbandReason = '';
  let disbanding = false;
  $: ownedTerr = selected ? ($territoryState.territories || []).filter((t) => t.owner === selected.name) : [];
  $: atWar = ownedTerr.some((t) => t.busy);
  $: richDisband = !!$bootstrap && can($bootstrap.perms, 'territories.manage');   // the version that also settles the territories
  async function removeGang(gang) {
    error = '';
    if (atWar) { error = 'One of its territories has a war on it. Cancel or finish the war first.'; return; }
    const terrText = richDisband
      ? (ownedTerr.length ? ` Its ${ownedTerr.length} territor${ownedTerr.length === 1 ? 'y' : 'ies'} (${ownedTerr.map((t) => t.name).join(', ')}) will be ${disbandMode === 'DELETE' ? 'REMOVED from the map' : 'made unclaimed'}.` : ' It owns no territory.')
      : '';
    const ok = await confirmAction(`Disband "${gang.label}"?

All members are removed from the gang and the gang is deleted.${terrText}

This cannot be undone.`, { title: 'Disband Gang', danger: true, confirmLabel: 'Disband gang' });
    if (!ok) return;
    disbanding = true;
    const res = richDisband ? await adminDisbandGang(gang.name, disbandMode, disbandReason) : await deleteGang(gang.id);
    disbanding = false;
    if (!res || res.ok === false) { error = (res && res.error) || 'The gang could not be disbanded.'; return; }
    disbandReason = '';
    selectedId = null;
    refreshTerritoryState();
    await refresh();
  }

  async function toggleParticipation(gang) {
    await updateGang(gang.id, { label: gang.label, leaderIdentifier: gang.leaderIdentifier, maxMembers: gang.maxMembers, canParticipate: !gang.canParticipate, logo: gang.logo, accentColor: gang.accentColor });
    await refresh();
  }

  async function saveSettings() {
    if (!selected) return;
    error = '';
    if (!settingsDraft.label || !settingsDraft.label.trim()) {
      error = 'Gang name cannot be blank.';
      return;
    }
    settingsSaving = true;
    const res = await updateGang(selected.id, {
      label: settingsDraft.label.trim(),
      leaderIdentifier: selected.leaderIdentifier,
      maxMembers: Number(settingsDraft.maxMembers) || 20,
      canParticipate: selected.canParticipate,
      logo: selected.logo,
      accentColor: settingsDraft.accentColor,
    });
    settingsSaving = false;
    // updateGang used to silently report success even when the underlying
    // DB write failed — this used to look like "nothing I type ever saves"
    // with zero indication of why. Now it actually surfaces the failure.
    if (!res || !res.ok) {
      error = (res && res.error) || 'Failed to save gang settings.';
      return;
    }
    settingsSavedFlash = true;
    clearTimeout(settingsSavedFlashTimer);
    settingsSavedFlashTimer = setTimeout(() => (settingsSavedFlash = false), 2000);
    await refresh();
  }

  async function uploadLogo(e) {
    if (!selected) return;
    logoBusy = true;
    await setGangLogo(selected.id, e.detail);
    logoBusy = false;
    await refresh();
  }

  async function removeLogo() {
    if (!selected) return;
    logoBusy = true;
    await setGangLogo(selected.id, null);
    logoBusy = false;
    await refresh();
  }

  // ── Invite Member: pick an online player and a rank from lists (no typing a raw ID) ──
  let recruits = [];
  let manualTarget = '';        // a server ID (or a player name) typed in instead of picking from the list
  let recruitsLoading = false;

  async function loadRecruits() {
    recruitsLoading = true;
    const res = await getGangRecruitsAdmin();
    recruits = res && res.ok ? (res.players || []) : [];
    recruitsLoading = false;
    // a player who was picked but has gone offline / joined a gang meanwhile must not stay selected
    if (newMember.serverId && !recruits.some((p) => String(p.serverId) === String(newMember.serverId))) newMember.serverId = '';
  }
  function toggleInviteForm() {
    newMember.showForm = !newMember.showForm;
    if (newMember.showForm) { manualTarget = ''; newMember.rank = DEFAULT_GANG_ROLE; loadRecruits(); }
  }

  // Only roles that exist can be given (create one under Roles & Permissions); the server refuses anything else.
  $: rankChoices = roleChoices.length ? roleChoices : [DEFAULT_GANG_ROLE];
  // a member's picker always lists their current rank too, even if it is not in the list yet
  const rankOptionsFor = (choices, current) => (choices.includes(current) ? choices : [current, ...choices]);

  async function addMember() {
    error = '';
    // a typed server ID / name wins over the list; the server finds the player and re-checks eligibility
    const target = String(manualTarget || '').trim() || newMember.serverId;
    if (!target) { error = 'Pick a player, or type a server ID.'; return; }
    const rank = (newMember.rank || '').trim() || 'Member';
    const res = await addGangMember(selected.id, target, rank);
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to add member.'; return; }
    newMember = { serverId: '', rank: DEFAULT_GANG_ROLE, showForm: false };
    manualTarget = '';
    await refresh(true);
    loadRoles();
  }

  async function removeMember(identifier, name) {
    const ok = await confirmAction(`Remove ${name || identifier} from the gang?`, { title: 'Remove Member', danger: true });
    if (!ok) return;
    await removeGangMember(selected.id, identifier);
    await refresh();
  }

  async function makeLeader(identifier, name) {
    const ok = await confirmAction(`Promote ${name || identifier} to Gang Leader?\n\nThe current leader will become a normal member.`, {
      title: 'Promote to Leader',
      confirmLabel: 'Promote',
    });
    if (!ok) return;
    await setGangLeader(selected.id, identifier);
    await refresh();
  }

  async function changeRank(identifier, rank) {
    error = '';
    const res = await setGangMemberRank(selected.id, identifier, rank);
    if (!res || !res.ok) error = (res && res.error) || 'Could not change the role.';
    await refresh(true);
    loadRoles();
  }

  // the XP / land numbers of the gang list come from the same live XP table the Map Zone uses
  $: xpRows = Object.fromEntries(($xpBoard.gangs || []).map((g) => [g.gang, g]));
  $: xpOf = (n) => (xpRows[n] ? xpRows[n].totalXp : null);
  $: terrOf = (n) => (xpRows[n] ? xpRows[n].territories : null);

  onMount(async () => {
    refresh();
    refreshTerritoryState();
    if (!$xpBoard.loaded) { const r = await getXpBoard(); if (r && r.ok) xpBoard.set({ loaded: true, gangs: r.gangs || [] }); }
  });
</script>

<div class="gang-mgmt view-enter">
  {#if creating}
  <div class="panel">
    <div class="panel-header">
      <div class="panel-heading">
        <span class="panel-title"><Icon name="plus" size={14} /> New Gang</span>
      </div>
    </div>
    <div class="panel-body">
      <div class="page-sub">Register a new gang</div>
      {#if error}<div class="error">{error}</div>{/if}
      <div class="settings-section">
        <div class="field"><label>Name (internal id)</label><input bind:value={newGang.name} placeholder="the_lost" /></div>
        <div class="field"><label>Display Label</label><input bind:value={newGang.label} placeholder="The Lost MC" /></div>
        <div class="field"><label>Max Members</label><input type="number" min="1" bind:value={newGang.maxMembers} /></div>
        <div class="save-row">
          <button class="btn btn-primary" on:click={createNewGang}><Icon name="check" size={13} /> Create</button>
          <button class="btn" on:click={cancelCreate}><Icon name="close" size={12} /> Cancel</button>
        </div>
      </div>
    </div>
  </div>
{:else if !selected}
  <div class="panel">
    <div class="panel-header">
      <div class="panel-heading">
        <span class="panel-title">
          <Icon name="users" size={14} /> Gang Management
          {#if gangs.length > 0}
            <span class="count">({gangs.length} gang{gangs.length === 1 ? '' : 's'})</span>
          {/if}
        </span>
      </div>
      <div class="panel-actions">
        <button class="btn btn-refresh" on:click={refresh} title="Refresh gang roster">
          <Icon name="refresh" size={13} /> Refresh
        </button>
        <button class="btn btn-primary" on:click={() => (creating = true)} disabled={readOnly}>
          <Icon name="plus" size={13} /> New Gang
        </button>
      </div>
    </div>
    <div class="panel-body">
      <div class="page-sub">Manage your registered gangs, roster, permissions, and settings</div>

      {#if readOnly}
        <div class="empty-state">Gang roster is managed by the framework/custom provider — read-only here.</div>
      {/if}

      {#if loading}
        <div class="empty-state">Loading gangs...</div>
      {:else if gangs.length === 0}
        <div class="empty-state">No gangs registered yet. Click "+ New Gang" to add your first gang.</div>
      {:else}
        <div class="gm-toolbar">
          <SearchBox bind:value={gSearch} placeholder="Search gang, tag or leader..." />
          <FilterSelect label="Status" bind:value={gStatus} options={GANG_STATUS_OPTIONS} minWidth={150} />
          <div class="gm-meta">
            {#if gFiltersActive}<button type="button" class="gm-reset" on:click={() => { gSearch = ''; gStatus = 'ALL'; }}>Clear filters</button>{/if}
          </div>
        </div>
        <TablePager top bind:page={gPage} bind:pageSize={gSize} total={filteredGangs.length} noun="gangs" />
        <div class="gang-table-wrap">
          <table class="data-table gang-table">
            <thead>
              <tr>
                <th class="col-index">#</th>
                <th class="col-gang">Gang Name</th>
                <th class="col-tag">Tag / ID</th>
                <th class="col-leader">Leader</th>
                <th class="col-members">Members</th>
                <th class="col-online">Online</th>
                <th class="col-xp">Gang XP</th>
                <th class="col-terr">Territories</th>
                <th class="col-status">Status</th>
                <th class="col-actions">Actions</th>
              </tr>
            </thead>
            <tbody>
              {#each pagedGangs as gang, i (gang.id)}
                <tr class="gang-row" class:active={gang.id === selectedId} style="--row-accent:{gang.accentColor || avatarColor(gang.label || gang.name)}">
                  <td class="col-index">{(gPage - 1) * gSize + i + 1}</td>
                  <td class="col-gang">
                    <div class="gang-row-identity">
                      <GangLogo logo={gang.logo} label={gang.label || gang.name} accentColor={gang.accentColor} size={24} />
                      <span class="gang-name-text">{gang.label || 'Unnamed Gang'}</span>
                    </div>
                  </td>
                  <td class="col-tag">
                    <span class="gang-tag-pill">{(gang.name || '').toUpperCase()}</span>
                  </td>
                  <td class="col-leader">
                    {gang.members.find((m) => m.identifier === gang.leaderIdentifier)?.name || '—'}
                  </td>
                  <td class="col-members">
                    <span class="count-num">{gang.members.length}</span>
                    <span class="count-max">/ {gang.maxMembers ?? '—'}</span>
                  </td>
                  <td class="col-online">
                    <span class="online-cell">
                      <i class:is-online={(gang.onlineCount ?? 0) > 0}></i>
                      {gang.onlineCount ?? 0}
                    </span>
                  </td>
                  <td class="col-xp">{xpOf(gang.name) == null ? '—' : Number(xpOf(gang.name)).toLocaleString()}</td>
                  <td class="col-terr">{terrOf(gang.name) == null ? '—' : terrOf(gang.name)}</td>
                  <td class="col-status">
                    <span class="status-pill" class:online={gang.canParticipate}>
                      <i></i>{gang.canParticipate ? 'Active' : 'Suspended'}
                    </span>
                  </td>
                  <td class="col-actions">
                    <button
                      class="btn btn-sm btn-manage"
                      class:btn-active={gang.id === selectedId}
                      on:click|stopPropagation={() => toggleManage(gang)}
                      title={gang.id === selectedId ? 'Close gang settings' : 'Manage gang and settings'}
                    >
                      {#if gang.id === selectedId}
                        <Icon name="close" size={11} /> Close
                      {:else}
                        <Icon name="gear" size={11} /> Manage <Icon name="chevronRight" size={10} />
                      {/if}
                    </button>
                  </td>
                </tr>
              {:else}
                <tr><td colspan="10" class="gm-empty">No gangs match the current filters.</td></tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </div>
  </div>
  {/if}

  {#if selected}
    <div class="panel detail-panel">
      <div class="panel-header">
        <span class="panel-title">
          <GangLogo logo={selected.logo} label={selected.label || selected.name} accentColor={selected.accentColor} size={26} />
          {selected.label || 'Unnamed Gang'} <span class="gm-tag">{(selected.name || '').toUpperCase()}</span>
        </span>
        <button class="btn" on:click={closeManage} title="Back to the gang list"><Icon name="chevronLeft" size={12} /> All gangs</button>
      </div>

      <div class="panel-body gm-pane">
        {#if error}<div class="gm-alert" role="alert">{error}</div>{/if}

        <div class="kpi-row gm-kpis">
          <div class="kpi-card"><div class="kpi-icon"><Icon name="crown" size={16} /></div><div class="gm-kcell"><div class="kpi-value gm-kv text" title={selected.members.find((m) => m.identifier === selected.leaderIdentifier)?.name || ''}>{selected.members.find((m) => m.identifier === selected.leaderIdentifier)?.name || '—'}</div><div class="kpi-label">Leader</div></div></div>
          <div class="kpi-card"><div class="kpi-icon"><Icon name="users" size={16} /></div><div><div class="kpi-value gm-kv">{selected.members.length}/{selected.maxMembers ?? '—'}</div><div class="kpi-label">Members</div></div></div>
          <div class="kpi-card"><div class="kpi-icon"><Icon name="activity" size={16} /></div><div><div class="kpi-value gm-kv">{selected.onlineCount ?? 0}</div><div class="kpi-label">Online</div></div></div>
          {#if gangOps}
            <div class="kpi-card"><div class="kpi-icon"><Icon name="zap" size={16} /></div><div><div class="kpi-value gm-kv">{xpOf(selected.name) == null ? '—' : Number(xpOf(selected.name)).toLocaleString()}</div><div class="kpi-label">Gang XP</div></div></div>
            <div class="kpi-card"><div class="kpi-icon"><Icon name="pin" size={16} /></div><div><div class="kpi-value gm-kv">{terrOf(selected.name) == null ? '—' : terrOf(selected.name)}</div><div class="kpi-label">Territories</div></div></div>
          {/if}
        </div>

        <SubTabs tabs={subTabItems} bind:active={detailTab} />

        <!-- ═════════════ Members ═════════════ -->
        {#if detailTab === 'Members'}
          <section class="gm-card">
            <header class="gm-card-head">
              <span class="gm-ico"><Icon name="users" size={18} /></span>
              <div class="gm-titles">
                <h3>Members</h3>
                <p>{selected.members.length} of {selected.maxMembers ?? '—'} places taken · {selected.onlineCount ?? 0} online now</p>
              </div>
              {#if !readOnly}
                <button type="button" class="btn btn-primary" on:click={toggleInviteForm}><Icon name="userPlus" size={14} /> {newMember.showForm ? 'Close' : 'Invite member'}</button>
              {/if}
            </header>

            {#if !readOnly && newMember.showForm}
              <div class="invite-row">
                <div class="field">
                  <label for="gm-player">Player <span class="muted-count">{recruits.length} online, not in a gang</span></label>
                  <div class="pick-row">
                    <select id="gm-player" bind:value={newMember.serverId} disabled={recruitsLoading}>
                      <option value="">{recruitsLoading ? 'Loading players…' : (recruits.length ? 'Select a player…' : 'No eligible players online')}</option>
                      {#each recruits as p (p.serverId)}
                        <option value={p.serverId}>{p.name} · ID {p.serverId}</option>
                      {/each}
                    </select>
                    <button type="button" class="btn" title="Reload the online player list" on:click={loadRecruits} disabled={recruitsLoading}><Icon name="refresh" size={13} /></button>
                  </div>
                </div>
                <div class="field">
                  <label for="gm-sid">Or type a server ID <span class="muted-count">or a name</span></label>
                  <input id="gm-sid" type="text" inputmode="numeric" placeholder="e.g. 12" maxlength="40" bind:value={manualTarget} on:keydown={(e) => e.key === 'Enter' && addMember()} />
                </div>
                <div class="field">
                  <label for="gm-rank">Role <span class="muted-count">create more under Roles &amp; Permissions</span></label>
                  <select id="gm-rank" bind:value={newMember.rank}>
                    {#each rankChoices as r}<option value={r}>{r}</option>{/each}
                  </select>
                </div>
                <button type="button" class="btn btn-primary invite-go" on:click={addMember} disabled={!newMember.serverId && !String(manualTarget).trim()}><Icon name="check" size={13} /> Add to gang</button>
              </div>
            {/if}

            {#if selected.members.length === 0}
              <div class="gm-empty-block">No members yet.</div>
            {:else}
              <div class="gm-toolbar">
                <SearchBox bind:value={mSearch} placeholder="Search member name..." width={280} />
                <FilterSelect label="Role" bind:value={mRank} options={memberRankOptions} minWidth={150} />
                <FilterSelect label="Presence" bind:value={mStatus} options={MEMBER_STATUS_OPTIONS} minWidth={160} />
              </div>
              <div class="tbl-card">
                <TablePager flush top bind:page={mPage} bind:pageSize={mSize} total={filteredMembers.length} noun="members" />
                <table class="data-table member-table">
                  <thead>
                    <tr>
                      <th>Player</th>
                      <th>Role</th>
                      <th>Status</th>
                      <th class="col-actions">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {#each pagedMembers as m (m.identifier)}
                      <tr>
                        <td>
                          <div class="member-cell">
                            <div class="member-avatar" style="background:{avatarColor(m.name || m.identifier)}">{initials(m.name || m.identifier)}</div>
                            <span>{m.name || m.identifier}</span>
                          </div>
                        </td>
                        <td>
                          {#if selected.leaderIdentifier === m.identifier}
                            <span class="badge badge-completed">Leader</span>
                          {:else if !readOnly}
                            <select class="rank-select" value={m.rank || DEFAULT_GANG_ROLE} on:change={(e) => changeRank(m.identifier, e.currentTarget.value)} aria-label="Role of {m.name || m.identifier}">
                              {#each rankOptionsFor(rankChoices, m.rank || DEFAULT_GANG_ROLE) as r}<option value={r}>{r}</option>{/each}
                            </select>
                          {:else}
                            <span class="rank-text">{m.rank}</span>
                          {/if}
                        </td>
                        <td><span class="status-pill" class:online={m.online}><i></i>{m.online ? 'Online' : 'Offline'}</span></td>
                        <td class="col-actions">
                          {#if selected.leaderIdentifier !== m.identifier}
                            <div class="member-actions">
                              <button class="icon-btn icon-btn-text promote-btn" title="Make this member the gang leader" on:click={() => makeLeader(m.identifier, m.name)} disabled={readOnly}>
                                <Icon name="crown" size={13} />
                                <span>Make leader</span>
                              </button>
                              <button class="icon-btn danger icon-btn-text" title="Remove member from gang" on:click={() => removeMember(m.identifier, m.name)} disabled={readOnly}>
                                <Icon name="trash" size={13} />
                                <span>Remove</span>
                              </button>
                            </div>
                          {/if}
                        </td>
                      </tr>
                    {:else}
                      <tr><td colspan="4" class="gm-empty">No members match the current filters.</td></tr>
                    {/each}
                  </tbody>
                </table>
              </div>
            {/if}
          </section>

        <!-- ═════════════ Roles & Permissions ═════════════ -->
        {:else if detailTab === 'Roles'}
          <section class="gm-card">
            <header class="gm-card-head">
              <span class="gm-ico"><Icon name="shield" size={18} /></span>
              <div class="gm-titles">
                <h3>Roles &amp; Permissions</h3>
                <p>The same roles the gang's leader sees under Event Status. Change them here or there — both update at once. <b class="role-limit" class:full={atRoleLimit}>{customRoles} of {maxRoles} own roles used</b></p>
              </div>
              {#if !readOnly}
                <button type="button" class="btn btn-primary" on:click={openCreateRole} disabled={atRoleLimit} title={atRoleLimit ? 'Role limit reached — delete a role first' : 'Create a role'}><Icon name="plus" size={14} /> Create role</button>
              {/if}
            </header>
            {#if rolesError}<div class="gm-alert flat" role="alert">{rolesError}</div>{/if}

            <div class="roles-layout">
              <div class="role-list" role="listbox" aria-label="Roles">
                {#each roles as r (r.name)}
                  <button type="button" role="option" aria-selected={r.name === selectedRole} class="role-item" class:active={r.name === selectedRole} on:click={() => { selectedRole = r.name; roleForm = null; }}>
                    <span class="ri-top">
                      <b>{r.name}</b>
                      {#if r.leaderRole}<em class="ri-tag">Leader</em>{:else if r.name === DEFAULT_GANG_ROLE}<em class="ri-tag dim">Default</em>{/if}
                    </span>
                    <span class="ri-sub">{r.count} member{r.count === 1 ? '' : 's'}</span>
                    <span class="ri-perms">
                      {#each PERMS as p (p.key)}<i class:on={has(r, p.key)} title={p.label}>{p.label}</i>{/each}
                    </span>
                  </button>
                {:else}
                  <div class="gm-empty-block">Loading roles…</div>
                {/each}
              </div>

              <div class="role-detail">
                {#if roleForm}
                  <div class="role-form">
                    <h4>{roleForm.mode === 'create' ? 'Create a role' : `Rename "${currentRole?.name}"`}</h4>
                    {#if roleForm.error}<div class="gm-alert flat" role="alert">{roleForm.error}</div>{/if}
                    <div class="field">
                      <label for="gm-role-name">Role name</label>
                      <input id="gm-role-name" type="text" maxlength="40" placeholder="e.g. Captain, Enforcer" bind:value={roleForm.name} on:keydown={(e) => e.key === 'Enter' && submitRoleForm()} />
                    </div>
                    {#if roleForm.mode === 'create'}
                      <div class="perm-list">
                        {#each PERMS as p (p.key)}
                          <label class="perm-check">
                            <input type="checkbox" bind:checked={roleForm.perms[p.key]} />
                            <span><b>{p.label}</b><small>{p.hint}</small></span>
                          </label>
                        {/each}
                      </div>
                    {/if}
                    <div class="save-row">
                      <button type="button" class="btn btn-primary" on:click={submitRoleForm} disabled={rolesBusy}>{roleForm.mode === 'create' ? 'Create role' : 'Save name'}</button>
                      <button type="button" class="btn" on:click={() => (roleForm = null)}>Cancel</button>
                    </div>
                  </div>
                {:else if currentRole}
                  <header class="rd-head">
                    <div>
                      <h4>{currentRole.name}{currentRole.leaderRole ? ' — Gang Leader' : ''}</h4>
                      <p>
                        {#if currentRole.leaderRole}The leader automatically holds every permission and cannot be changed.
                        {:else if currentRole.name === DEFAULT_GANG_ROLE}The default role every new member starts with. Its permissions can be changed; it cannot be renamed or deleted.
                        {:else}Switch a permission on to give it to everyone who holds this role.{/if}
                      </p>
                    </div>
                    {#if !readOnly && !currentRole.leaderRole && currentRole.name !== DEFAULT_GANG_ROLE}
                      <div class="rd-actions">
                        <button type="button" class="btn" on:click={openRenameRole}><Icon name="edit" size={13} /> Rename</button>
                        <button type="button" class="btn btn-danger" on:click={deleteRole} disabled={rolesBusy}><Icon name="trash" size={13} /> Delete</button>
                      </div>
                    {/if}
                  </header>

                  <div class="perm-rows">
                    {#each PERMS as p (p.key)}
                      <div class="perm-row">
                        <div class="pr-text"><b>{p.label}</b><small>{p.hint}</small></div>
                        <button type="button" class="sw" class:on={has(currentRole, p.key)} role="switch" aria-checked={has(currentRole, p.key)} aria-label={p.label}
                          disabled={!canEditRole(currentRole) || rolesBusy} on:click={() => togglePerm(currentRole, p.key)}><span></span></button>
                      </div>
                    {/each}
                  </div>

                  <div class="holders">
                    <span class="holders-label">Who holds it ({roleHolders.length})</span>
                    <div class="holders-list">
                      {#each roleHolders as m (m.identifier)}
                        <span class="holder"><i style="background:{avatarColor(m.name || m.identifier)}">{initials(m.name || m.identifier)}</i>{m.name || m.identifier}</span>
                      {:else}
                        <em>Nobody yet — give it to a member from the Members tab.</em>
                      {/each}
                    </div>
                  </div>
                {/if}
              </div>
            </div>
          </section>

        {:else if detailTab === 'Territory'}
          <GangAdminTools gang={selected.name} section="territory" />
        {:else if detailTab === 'XP'}
          <GangAdminTools gang={selected.name} section="xp" />
        {:else if detailTab === 'Messages'}
          <GangAdminTools gang={selected.name} section="messages" />

        <!-- ═════════════ Administration ═════════════ -->
        {:else if detailTab === 'Admin' && settingsDraft}
          <div class="admin-grid">
            <section class="gm-card">
              <header class="gm-card-head">
                <span class="gm-ico"><Icon name="image" size={18} /></span>
                <div class="gm-titles"><h3>Branding</h3><p>The logo shown next to the gang everywhere.</p></div>
              </header>
              <GangLogoUpload logo={selected.logo} label={selected.label} accentColor={settingsDraft.accentColor} disabled={readOnly} busy={logoBusy} on:upload={uploadLogo} on:remove={removeLogo} />
            </section>

            <section class="gm-card">
              <header class="gm-card-head">
                <span class="gm-ico"><Icon name="gear" size={18} /></span>
                <div class="gm-titles"><h3>Settings</h3><p>Name, colour, size and whether the gang can join events.</p></div>
              </header>
              <div class="field-row">
                <div class="field"><label for="gm-name">Gang name</label><input id="gm-name" type="text" bind:value={settingsDraft.label} disabled={readOnly} /></div>
                <div class="field"><label for="gm-tag">Gang tag <span class="optional">internal id, fixed</span></label><input id="gm-tag" type="text" value={(selected.name || '').toUpperCase()} disabled /></div>
              </div>
              <div class="field-row">
                <div class="field">
                  <label for="gm-color">Accent colour</label>
                  <div class="color-field">
                    <input id="gm-color" class="color-input" type="color" bind:value={settingsDraft.accentColor} disabled={readOnly} />
                    <span class="color-hex">{(settingsDraft.accentColor || '').toUpperCase()}</span>
                  </div>
                </div>
                <div class="field"><label for="gm-max">Maximum members</label><input id="gm-max" type="number" min="1" bind:value={settingsDraft.maxMembers} disabled={readOnly} /></div>
              </div>
              <div class="gm-switch-row">
                <div><b>Event participation</b><small>Allowed to take part in convoys and the other events.</small></div>
                <button type="button" class="sw" class:on={!!selected.canParticipate} role="switch" aria-checked={!!selected.canParticipate} aria-label="Allowed to participate" disabled={readOnly} on:click={() => toggleParticipation(selected)}><span></span></button>
              </div>
              {#if !readOnly}
                <div class="save-row">
                  <button class="btn btn-primary" on:click={saveSettings} disabled={settingsSaving}>{settingsSaving ? 'Saving...' : 'Save settings'}</button>
                  {#if settingsSavedFlash}<span class="saved-flash"><Icon name="check" size={13} /> Saved</span>{/if}
                </div>
              {/if}
            </section>
          </div>

          <!-- the one place a gang is disbanded -->
          <section class="gm-card gm-danger">
            <header class="gm-card-head">
              <span class="gm-ico red"><Icon name="warning" size={18} /></span>
              <div class="gm-titles">
                <h3>Disband gang</h3>
                <p>
                  All members are removed and the gang is deleted. This cannot be undone.
                  {#if richDisband}
                    Members online are told first.
                    {#if ownedTerr.length}<b>{ownedTerr.length} territor{ownedTerr.length === 1 ? 'y' : 'ies'}:</b> {ownedTerr.map((t) => t.name).join(', ')}.{:else}This gang owns no territory.{/if}
                  {/if}
                </p>
              </div>
            </header>
            {#if richDisband && ownedTerr.length}
              <div class="field">
                <label for="gm-dz-mode">Its territories</label>
                <div class="dz-seg" id="gm-dz-mode" role="group" aria-label="What happens to its territories">
                  <button type="button" class:on={disbandMode === 'RELEASE'} on:click={() => (disbandMode = 'RELEASE')}>Make unclaimed</button>
                  <button type="button" class:on={disbandMode === 'DELETE'} on:click={() => (disbandMode = 'DELETE')}>Remove from map</button>
                </div>
              </div>
            {/if}
            <div class="dz-row">
              {#if richDisband}
                <div class="field"><label for="gm-dz-reason">Reason <span class="optional">shown to the members and in Discord</span></label><input id="gm-dz-reason" type="text" maxlength="160" bind:value={disbandReason} placeholder="e.g. Repeated rule breaking" /></div>
              {/if}
              <button class="btn btn-danger" on:click={() => removeGang(selected)} disabled={readOnly || disbanding || atWar}><Icon name="trash" size={13} /> {disbanding ? 'Disbanding…' : 'Disband gang'}</button>
            </div>
            {#if atWar}<div class="gm-alert flat">A war is running on one of its territories. Cancel or finish it first.</div>{/if}
          </section>
        {/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .gang-mgmt {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  .panel-heading {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .panel-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .count {
    color: var(--text-dim);
    font-size: var(--fs-small);
    font-weight: 500;
  }

  .page-sub {
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-bottom: 14px;
  }

  /* Excel-style table presentation for added gangs */
  .gang-table-wrap {
    max-height: 480px;
    overflow-y: auto;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    background: var(--glass-panel, var(--tablet-panel));
  }
  :global(.tp.top + .gang-table-wrap) {
    border-top: none;
    border-top-left-radius: 0;
    border-top-right-radius: 0;
  }
  :global(.tp.top + .member-table) {
    border-top-left-radius: 0;
    border-top-right-radius: 0;
  }

  .gang-table {
    width: 100%;
    margin: 0;
    border-collapse: collapse;
    font-size: var(--fs-body);
    border: none;
  }
  .gang-table thead th {
    position: sticky;
    top: 0;
    background: var(--glass-head, var(--c-panel));
    z-index: 2;
    padding: var(--tbl-th-y) var(--tbl-x);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
    user-select: none;
    text-align: left;
  }
  .gang-table thead th:last-child {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0;
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }

  .gang-table tbody tr {
    transition: background 0.12s ease;
    border-bottom: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.07);
    box-shadow: none;
  }
  .gang-table tbody tr:nth-child(even) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
  }
  .gang-table tbody tr:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
  }
  .gang-table tbody tr.active {
    background: var(--c-hover);
    box-shadow: inset 0 0 0 1px rgba(var(--accent-primary-rgb), 0.4);
  }

  .gang-table td {
    padding: var(--tbl-td-y) var(--tbl-x);
    vertical-align: middle;
    color: var(--text-main);
    border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }
  .gang-table td:last-child {
    font-variant-numeric: tabular-nums;
  }

  .col-index {
    width: 44px;
    text-align: center;
    border-right: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.12) !important;
  }
  td.col-index {
    color: var(--text-dim);
    font-size: var(--fs-small);
    font-family: var(--font-mono);
    font-weight: 500;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
  }
  .col-gang {
    min-width: 160px;
  }
  .col-tag {
    width: 100px;
  }
  .col-leader {
    min-width: 140px;
  }
  td.col-leader {
    color: var(--text-main);
  }
  .col-members {
    width: 100px;
    white-space: nowrap;
  }
  .col-online {
    width: 80px;
    white-space: nowrap;
  }
  .col-status {
    width: 100px;
    white-space: nowrap;
  }
  .col-actions {
    width: 110px;
    text-align: right;
    white-space: nowrap;
  }

  .gang-row-identity {
    display: flex;
    align-items: center;
    gap: 10px;
    font-weight: 600;
  }
  .gang-name-text {
    font-size: var(--fs-body);
    color: var(--text-main);
  }

  .gang-tag-pill {
    display: inline-block;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-radius: var(--r-tag);
    padding: 2px 7px;
    font-size: var(--fs-meta);
    font-family: var(--font-mono);
    font-weight: 600;
    color: var(--text-dim);
    letter-spacing: 0.01em;
  }

  .count-num {
    font-weight: 500;
    color: var(--text-main);
  }
  .count-max {
    color: var(--text-dim);
    font-size: var(--fs-small);
  }

  .online-cell {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .online-cell i {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.2);
    display: inline-block;
  }
  .online-cell i.is-online {
    background: var(--tablet-success);
  }

  /* Filled/highlighted by default — this is the row's one primary call to
     action, so it shouldn't read as just another neutral outline button
     among the row's other text. Flips to a quieter outlined "Close" once
     this gang is the one being managed, so the highlight always points at
     the action actually available right now. */
  .btn-manage {
    background: var(--accent-primary);
    border: 1px solid var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    font-size: var(--fs-small);
    font-weight: 700;
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    display: inline-flex;
    align-items: center;
    gap: 5px;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
    cursor: pointer;
  }
  .btn-manage:hover {
    background: var(--accent-primary-light);
    border-color: var(--accent-primary-light);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .btn-manage.btn-active {
    background: var(--glass-head, var(--c-raised, #1f2328));
    border-color: var(--c-line, #2a2e35);
    color: #ff5d50;
  }
  .btn-manage.btn-active:hover {
    background: rgba(255, 93, 80, 0.15);
    border-color: rgba(255, 93, 80, 0.5);
    color: #ff5d50;
  }


  .detail-panel {
    margin-top: 4px;
  }
  .col-xp, .col-terr { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .dz-seg { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; padding: 4px; max-width: 420px; background: var(--glass-head, rgba(8, 11, 16, 0.5)); border: 1px solid var(--tablet-border); border-radius: var(--r-ctl, 8px); }
  .dz-seg button { height: 36px; border-radius: 6px; font-weight: 600; font-size: var(--fs-body); color: var(--text-dim); }
  .dz-seg button.on { color: #ffb020; background: rgba(255, 176, 32, 0.18); }



  .invite-row {
    display: flex;
    align-items: flex-end;
    gap: 12px;
    padding: 14px;
    margin-bottom: 14px;
    background: var(--glass-head, var(--tablet-panel-alt));
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
  }
  .invite-row .field {
    margin-bottom: 0;
    flex: 1;
    min-width: 0;
  }
  .pick-row { display: flex; gap: 8px; }
  .pick-row select { flex: 1; min-width: 0; }
  .muted-count { font-weight: 500; color: var(--text-muted, #aeb5bd); }
  .member-table {
    margin-top: 4px;
  }
  .member-table tbody tr {
    transition: background 0.12s ease;
  }
  .member-table tbody tr:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.03);
  }
  .member-cell {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .member-avatar {
    width: 28px;
    height: 28px;
    border-radius: 999px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .rank-text {
    color: var(--text-dim);
  }
  .status-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: var(--fs-meta);
    color: var(--tablet-text-faint);
  }
  .status-pill i {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--tablet-text-faint);
    display: inline-block;
  }
  .status-pill.online {
    color: var(--tablet-success);
  }
  .status-pill.online i {
    background: var(--tablet-success);
  }
  .col-actions {
    text-align: right;
    width: 220px;
  }
  .member-actions {
    display: inline-flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    white-space: nowrap;
  }
  .icon-btn {
    height: 30px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    background: transparent;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease;
  }
  .icon-btn.icon-btn-text {
    width: auto;
    padding: 0 12px;
    white-space: nowrap;
  }
  .icon-btn.promote-btn {
    background: var(--c-action);
    border-color: var(--c-action);
    color: var(--on-accent);
  }
  .icon-btn.promote-btn:hover:not(:disabled) {
    color: var(--lt-ffffff, #ffffff);
    border-color: var(--accent-primary);
    background: var(--c-hover);
  }
  .icon-btn.danger {
    background: rgba(220, 53, 69, 0.10);
    border-color: rgba(220, 53, 69, 0.35);
    color: #ff6b6b;
  }
  .icon-btn.danger:hover:not(:disabled) {
    color: var(--lt-ffffff, #ffffff);
    border-color: #ff5252;
    background: rgba(220, 53, 69, 0.25);
  }
  .icon-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }


  .save-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .saved-flash {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--tablet-success);
    animation: savedFlashIn 0.15s ease-out both;
  }
  @keyframes savedFlashIn {
    from { opacity: 0; transform: translateY(2px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .settings-section {
    margin-bottom: 16px;
    padding: 18px;
    background: var(--glass-head, var(--tablet-panel-alt));
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
  }
  .settings-section:last-child {
    margin-bottom: 0;
  }
  .color-field {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .color-input {
    width: 42px;
    height: 42px;
    flex-shrink: 0;
    padding: 4px;
    background: var(--glass-head, var(--tablet-bg));
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    cursor: pointer;
  }
  .color-hex {
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    font-weight: var(--fw-value);
    color: var(--text-dim);
    letter-spacing: 0.01em;
  }
  .optional {
    font-weight: 400;
    text-transform: none;
    letter-spacing: 0;
    color: var(--tablet-text-faint);
    margin-left: 6px;
  }

  .error {
    color: var(--tablet-danger);
    font-size: var(--fs-body);
    margin-bottom: 10px;
  }

  .gm-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    gap: 14px;
    margin-bottom: 14px;
  }
  .gm-meta {
    margin-left: auto;
    align-self: center;
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .gm-reset {
    background: transparent;
    border: none;
    padding: 0;
    color: var(--accent-primary-light, #66a3eb);
    font-size: var(--fs-small);
    font-weight: 700;
    cursor: pointer;
  }
  .gm-reset:hover { text-decoration: underline; }
  .gm-empty {
    text-align: center;
    padding: 28px 16px !important;
    color: var(--text-dim);
  }

  /* ── Manage view ───────────────────────────────────────────────────────────────────────────────────────
     One header, one flat underline tab strip, and every section is a card with the same head (icon · title · line of help · action),
     so Members, Roles, Territory, XP, Notices and Administration all read as one family. Colours are theme tokens only. */
  /* Surfaces follow the chosen theme: the panel is see-through (the gradient of the window shows), the header / tab strip / cards are the
     theme's own tinted glass, and boxes INSIDE a card are only a faint light overlay — never a fixed black fill on top of another one. */
  .gang-mgmt .panel { background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.6)); }
  .gang-mgmt .panel-header { background: var(--glass-head, rgba(var(--ltc-12-16-24, 12, 16, 24), 0.6)); }
  .detail-panel { overflow: hidden; background: transparent; box-shadow: none; }


  .detail-panel .panel-body.gm-pane { background: transparent; display: flex; flex-direction: column; gap: 18px; padding: 24px 28px 32px; }

  .gm-card { display: flex; flex-direction: column; gap: 18px; min-width: 0; padding: 22px 24px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border); border-radius: var(--r-panel, 12px); }
  .gm-card-head { display: flex; align-items: center; gap: 14px; padding-bottom: 16px; border-bottom: 1px solid var(--tablet-border); }
  .gm-ico { flex: none; width: 42px; height: 42px; display: grid; place-items: center; border-radius: 10px; color: var(--accent-primary-light, #7bb6f2); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .gm-ico.red { color: #111111; background: rgb(229, 72, 77); border-color: rgb(229, 72, 77); }
  .gm-titles { flex: 1; min-width: 0; }
  .gm-titles h3 { margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; line-height: 1.1; }
  .gm-titles p { margin: 5px 0 0; font-size: var(--fs-small); line-height: 1.5; color: var(--text-muted, #8d949c); }
  .gm-titles p b { color: var(--text-dim); }
  .gm-alert { padding: 10px 14px; border: 1px solid var(--c-line); border-radius: var(--r-ctl, 8px); background: var(--c-raised); color: #ff8a8d; font-size: var(--fs-body);
    border-left: 3px solid rgb(229, 72, 77);}
  .gm-alert.flat { margin: 0; }
  .gm-empty-block { padding: 30px 16px; text-align: center; color: var(--text-muted, #8d949c); }

  /* fields inside a card */
  .gm-card .field { margin: 0; }
  .gm-card .field > label { display: block; margin-bottom: 8px; font-size: var(--fs-body); font-weight: 600; color: var(--text-dim); }
  .gm-card .field input[type='text'], .gm-card .field input[type='number'] { box-sizing: border-box; width: 100%; min-height: 46px; padding: 0 14px; font-size: var(--fs-body); }
  .gm-card .field-row { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }

  /* members */
  .gm-card .gm-toolbar { margin: 0; }
  .invite-row { display: grid; grid-template-columns: 1.4fr 1fr 1fr auto; align-items: end; gap: 16px; padding: 18px 20px; margin: 0; border-radius: var(--r-ctl, 8px); background: rgba(var(--ink-rgb, 255, 255, 255), 0.035); border: 1px solid var(--tablet-border); }
  .invite-row .field { flex: none; }
  .invite-go { height: 46px; white-space: nowrap; }
  .tbl-card { overflow-x: auto; border: 1px solid var(--tablet-border); border-radius: var(--r-panel, 12px); background: rgba(var(--ink-rgb, 255, 255, 255), 0.035); }
  .tbl-card .member-table { width: 100%; margin: 0; border: 0; }
  .tbl-card .member-table th { padding: var(--tbl-th-y) var(--tbl-x); }
  .tbl-card .member-table td { padding: var(--tbl-td-y) var(--tbl-x); }
  .tbl-card .member-table tbody tr:last-child td { border-bottom: 0; }
  .rank-select { height: 36px; min-width: 150px; padding: 0 10px; font-size: var(--fs-body); font-weight: 600; }

  /* roles */
  .roles-layout { display: grid; grid-template-columns: minmax(240px, 310px) minmax(0, 1fr); gap: 20px; align-items: start; }
  .role-list { display: flex; flex-direction: column; gap: 8px; }
  .role-item { display: flex; flex-direction: column; align-items: flex-start; gap: 5px; width: 100%; padding: 12px 14px; text-align: left; color: var(--text-main); background: rgba(var(--ink-rgb, 255, 255, 255), 0.035); border: 1px solid var(--tablet-border); border-radius: var(--r-ctl, 8px); cursor: pointer; transition: border-color 0.12s ease, background 0.12s ease; }
  .role-item:hover { border-color: var(--tablet-border-strong); }
  .role-item.active { background: var(--c-hover); border-color: var(--accent-primary); }
  .ri-top { display: flex; align-items: center; gap: 8px; }
  .ri-top b { font-size: var(--fs-body); }
  .ri-tag { font-style: normal; padding: 2px 9px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 700; color: #f2c35b; background: rgba(242, 195, 91, 0.14); }
  .ri-tag.dim { color: var(--text-muted); background: rgba(255, 255, 255, 0.07); }
  .role-limit { margin-left: 8px; font-weight: 600; color: var(--text-dim); }
  .role-limit.full { color: #ffb020; }
  .ri-sub { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .ri-perms { display: flex; flex-wrap: wrap; gap: 5px; }
  .ri-perms i { font-style: normal; padding: 2px 9px; border-radius: 999px; font-size: var(--fs-meta); color: var(--text-muted); background: rgba(255, 255, 255, 0.04); border: 1px solid var(--tablet-border); opacity: 0.5; }
  .ri-perms i.on { opacity: 1; color: #46c98b; background: rgba(70, 201, 139, 0.12); border-color: rgba(70, 201, 139, 0.4); }
  .role-detail { display: flex; flex-direction: column; gap: 18px; min-height: 280px; padding: 20px 22px; background: rgba(var(--ink-rgb, 255, 255, 255), 0.035); border: 1px solid var(--tablet-border); border-radius: var(--r-panel, 12px); }
  .rd-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; }
  .rd-head h4, .role-form h4 { margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; }
  .rd-head p { margin: 5px 0 0; font-size: var(--fs-small); line-height: 1.5; color: var(--text-muted, #8d949c); }
  .rd-actions { display: flex; flex: none; gap: 8px; }
  .perm-rows { display: flex; flex-direction: column; overflow: hidden; border: 1px solid var(--tablet-border); border-radius: var(--r-ctl, 8px); }
  .perm-row { display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 14px 16px; border-bottom: 1px solid var(--c-line-soft, rgba(110, 140, 180, 0.12)); }
  .perm-row:last-child { border-bottom: 0; }
  .pr-text b, .gm-switch-row b { display: block; font-size: var(--fs-body); }
  .pr-text small, .gm-switch-row small { display: block; margin-top: 3px; font-size: var(--fs-small); line-height: 1.4; color: var(--text-muted, #8d949c); }
  .sw { position: relative; flex: none; width: 46px; height: 26px; padding: 0; border: 1px solid var(--tablet-border-strong, #363b43); border-radius: 999px; background: rgba(255, 255, 255, 0.08); cursor: pointer; transition: background 0.14s ease, border-color 0.14s ease; }
  .sw span { position: absolute; top: 2px; left: 2px; width: 20px; height: 20px; border-radius: 50%; background: #c9ced4; transition: transform 0.14s ease, background 0.14s ease; }
  .sw.on { background: var(--accent-primary); border-color: var(--accent-primary); }
  .sw.on span { transform: translateX(20px); background: #fff; }
  .sw:disabled { opacity: 0.45; cursor: not-allowed; }
  .holders { display: flex; flex-direction: column; gap: 10px; }
  .holders-label { font-size: var(--fs-small); font-weight: 600; color: var(--text-dim); }
  .holders-list { display: flex; flex-wrap: wrap; gap: 8px; }
  .holders-list em { font-style: normal; font-size: var(--fs-small); color: var(--text-muted, #8d949c); }
  .holder { display: inline-flex; align-items: center; gap: 8px; padding: 4px 12px 4px 4px; border-radius: 999px; font-size: var(--fs-small); font-weight: 600; background: var(--glass-panel, rgba(255, 255, 255, 0.05)); border: 1px solid var(--tablet-border); }
  .holder i { display: grid; place-items: center; width: 24px; height: 24px; border-radius: 50%; font-style: normal; font-size: var(--fs-meta); font-weight: 700; color: #fff; }
  .role-form { display: flex; flex-direction: column; gap: 16px; max-width: 560px; }
  .perm-list { display: flex; flex-direction: column; gap: 10px; }
  .perm-check { display: flex; align-items: flex-start; gap: 12px; padding: 12px 14px; border: 1px solid var(--tablet-border); border-radius: var(--r-ctl, 8px); cursor: pointer; }
  .perm-check input { margin-top: 3px; }
  .perm-check b { display: block; font-size: var(--fs-body); }
  .perm-check small { display: block; margin-top: 2px; font-size: var(--fs-small); color: var(--text-muted, #8d949c); }

  /* administration */
  .admin-grid { display: grid; grid-template-columns: minmax(320px, 1fr) minmax(0, 2fr); gap: 18px; align-items: stretch; }
  .gm-switch-row { display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 14px 16px; border: 1px solid var(--tablet-border); border-radius: var(--r-ctl, 8px); background: rgba(var(--ink-rgb, 255, 255, 255), 0.035); }
  .gm-danger { border-color: rgba(255, 93, 80, 0.45); }
  .dz-row { display: flex; align-items: flex-end; gap: 16px; }
  .dz-row .field { flex: 1; }
  .dz-row .btn { flex: none; min-height: 46px; }
  @media (max-width: 1150px) {
    .admin-grid, .roles-layout { grid-template-columns: 1fr; }
    .invite-row { grid-template-columns: 1fr 1fr; }
  }

  /* ── Tablet look (same language as Staff Management): the standard panel + header, the tablet's KPI tiles and sub-tabs, and FLAT
     sections — a ruled title and the content, no icon chips and no card inside the panel. ── */
  .gang-mgmt .detail-panel { margin-top: 4px; background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.76); box-shadow: none; }
  .gang-mgmt .detail-panel .panel-title :global(.gl), .gang-mgmt .detail-panel .panel-title :global(img) { flex: none; }
  .gm-tag { margin-left: 4px; padding: 2px 8px; border: 1px solid var(--c-line); border-radius: var(--r-tag, 4px); font-family: var(--font-ui); font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0.04em; color: var(--text-muted); }
  .gm-kpis { grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; }
  .gm-kpis .kpi-card, .gm-kcell { min-width: 0; }
  .gm-kv { font-size: 24px; }
  .gm-kv.text { font-size: var(--fs-section); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .detail-panel .panel-body.gm-pane { padding: 18px 18px 22px; gap: 14px; }
  .detail-panel .gm-card { gap: 14px; padding: 0; background: transparent; border: 0; border-radius: 0; }
  .detail-panel .gm-card-head { gap: 12px; padding-bottom: 10px; border-bottom: 1px solid var(--c-line); }
  .detail-panel .gm-ico { display: none; }
  .detail-panel .gm-titles h3 { font-size: var(--fs-emph); font-weight: 700; }
</style>
