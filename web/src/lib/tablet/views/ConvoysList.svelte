<script>
  import { sameData } from '../../util/stable.js';
  import { defaultPageSize } from '../../adminPrefs.js';
  import { perms } from '../../perms.js';
  import { inkOn } from '../../util/avatar.js';
  import { onMount, onDestroy, createEventDispatcher } from 'svelte';
  import { peek, keep } from '../ui/viewCache.js';
  import { getConvoys, deleteConvoy, updateConvoy, forceEndConvoy, reuseConvoy, cloneConvoy } from '../../api/convoy.js';
  import { startConvoy, testRunConvoy, startRaceCountdown } from '../../api/runtime.js';
  import { clearPlacedPreview } from '../../api/placer.js';
  import { STATUS_LABELS } from '../../constants.js';
  import { confirmAction } from '../ui/confirm.js';
  import { convoyListVersion, bootstrap, announceEventId, currentView, viewSub } from '../../stores.js';
import { territoryReadiness } from '../../territory/territoryRender.js';
  import Icon from '../ui/Icon.svelte';
  import '../tablet-theme.css';

  const dispatch = createEventDispatcher();
  let convoys = peek('convoys') || [];
  let loading = !peek('convoys');
  let error = '';
  let busy = {};

  // silent: a remote change (someone ELSE created/edited/deleted a convoy)
  // re-fetches in the background without flashing the full "Loading..."
  // state over a list this player might already be reading.
  async function refresh(silent) {
    if (!silent && !peek('convoys')) loading = true;
    const res = await getConvoys();
    const nextConvoys = res && res.ok ? res.convoys : [];
    if (res && res.ok) keep('convoys', nextConvoys);
    if (!sameData(nextConvoys, convoys)) convoys = nextConvoys;
    if (!silent) loading = false;
  }

  // Skips the very first change notification after mount — refresh()
  // already runs once on its own below, so reacting to that too would just
  // be a redundant duplicate fetch.
  let sawInitialVersion = false;
  const unsubConvoyListVersion = convoyListVersion.subscribe(() => {
    if (!sawInitialVersion) { sawInitialVersion = true; return; }
    refresh(true);
  });
  onDestroy(unsubConvoyListVersion);

  // Mirrors CreateConvoy's own readiness checklist — lets the list itself
  // tell you a convoy can't start yet, instead of only finding out after
  // opening the editor and clicking through to Review. Branches by kind the
  // same way CreateConvoy's own `readiness` does — a GANG_AIRDROP event has
  // no trucks/route at all, so gating it on those would make it un-startable
  // from this list forever.
  function readyToStart(c) {
    if (!c.name || c.name.trim().length < 3) return false;
    if (c.kind === 'GANG_AIRDROP') {
      return (c.airdropZones || []).length > 0 && c.airdropZones.every((z) => z.x != null) && c.settings.gangPvp;
    }
    if (c.kind === 'GANG_RACE') {
      const stages = c.rallyStages || [];
      return stages.length > 0 && stages.every((s) => s.x != null && s.y != null);
    }
    if (c.kind === 'HOT_CARGO') {
      const hc = c.hotCargo || {};
      return (hc.spawnZones || []).length > 0 && (hc.dropoffZones || []).length > 0;
    }
    // TDM and Operation Crackdown were missing here, so they fell through to the convoy rule (trucks + route), which they never have:
    // their Start button stayed greyed out in this list while the Review page of the editor (which knows their own checklist) allowed it.
    if (c.kind === 'TDM') {
      const tdm = c.tdm || {};
      if (tdm.matchFormat === 'TOURNAMENT') return false;   // arenas are played from the Tournament tab
      const ag = (c.settings && c.settings.allowedGangs) || {};
      const gangs = ag.mode === 'SELECTED' ? (ag.gangs || []).length : 0;
      return gangs === 2 && (tdm.duration || 0) > 0 && (tdm.zone?.points || []).length >= 3
        && ((tdm.spawnPoints || []).length > 0 || (tdm.respawnZoneRed?.points || []).length >= 3 || (tdm.respawnZoneBlue?.points || []).length >= 3);
    }
    if (c.kind === 'CRACKDOWN') {
      const cd = c.crackdown || {};
      return !!cd.targetGang && !!(cd.zone && cd.zone.center && Number.isFinite(Number(cd.zone.center.x)));
    }
    if (c.kind === 'GANG_TERRITORY') {
      return territoryReadiness(c).filter((r) => !r.label.startsWith('Auction date')).every((r) => r.ok);
    }
    if (c.kind === 'CONTAINER_WARS') {
      const cw = c.containerWars || {};
      const containers = cw.containers || [];
      return containers.length > 0 && containers.every((con) => con.dropCoords && con.dropCoords.x != null);
    }
    return (
      c.trucks.length > 0 &&
      c.trucks.some((t) => t.role === 'PRIMARY_CARGO' || t.role === 'SECONDARY_CARGO') &&
      c.route.some((p) => p.type === 'START') &&
      c.route.some((p) => p.type === 'DESTINATION')
    );
  }

  async function start(c) {
    if (!readyToStart(c)) return;
    const isAirdrop = c.kind === 'GANG_AIRDROP';
    const ok = await confirmAction(`Start "${c.name}" now? This goes live for everyone immediately.`, { title: `Start ${kindLabel(c.kind)}` });
    if (!ok) return;
    clearPlacedPreview();
    error = '';
    busy = { ...busy, [c.id]: true };
    const res = await startConvoy(c.id);
    busy = { ...busy, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || `Failed to start ${kindLabel(c.kind).toLowerCase()}.`; return; }
    refresh();
  }

  // A rehearsal: the event really runs, but every notification goes to the admin only; nothing is paid, posted or saved.
  async function testRun(c) {
    if (!readyToStart(c)) return;
    const ok = await confirmAction(`Conduct a test run of "${c.name}"?

The event runs for real, but every notification, banner and announcement goes to YOU only. Nobody else on the server receives anything, nothing is posted to Discord, no money, XP or items are paid, and nothing is saved to Event History or the leaderboards. Its trucks, props and peds still exist in the world, and no other event can start until it ends.`, { title: 'Test run', confirmLabel: 'Yes, test run' });
    if (!ok) return;
    clearPlacedPreview();
    error = '';
    busy = { ...busy, [c.id]: true };
    const res = await testRunConvoy(c.id);
    busy = { ...busy, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || 'Could not start the test run.'; return; }
    refresh();
  }

  // Opens Announcements → Event Announcements with this event's announcement window ready (title, message, audience, preview).
  function announceNow(c) {
    announceEventId.set(c.id);
    viewSub.set('events');
    currentView.set('announcements');
  }

  async function beginCountdown(c) {
    clearPlacedPreview();
    error = '';
    busy = { ...busy, [c.id]: true };
    const res = await startRaceCountdown(c.id);
    busy = { ...busy, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || 'Could not start the countdown.'; return; }
    refresh();
  }

  async function cancel(c) {
    const ok = await confirmAction(`Cancel "${c.name}"? It stays in history as cancelled instead of being deleted.`, { title: `Cancel ${kindLabel(c.kind)}`, danger: true });
    if (!ok) return;
    error = '';
    busy = { ...busy, [c.id]: true };
    const res = await updateConvoy(c.id, { ...c, status: 'CANCELLED' });
    busy = { ...busy, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || `Failed to cancel ${kindLabel(c.kind).toLowerCase()}.`; return; }
    refresh();
  }

  async function remove(id, name, kind) {
    const typeLabel = kind === 'GANG_AIRDROP' ? 'Airdrop' : (kind === 'HOT_CARGO' ? 'Hot Cargo Run' : (kind === 'GANG_RACE' ? 'Rally Race' : (kind === 'TDM' ? 'TDM Match' : (kind === 'CONTAINER_WARS' ? 'Container Wars' : (kind === 'GANG_TERRITORY' ? 'Gang Territory Auction' : 'Convoy')))));
    const ok = await confirmAction(`This permanently deletes "${name}". This can't be undone.`, { title: `Delete ${typeLabel}`, danger: true });
    if (!ok) return;
    error = '';
    const res = await deleteConvoy(id);
    if (!res || !res.ok) { error = (res && res.error) || `Failed to delete ${typeLabel.toLowerCase()}.`; return; }
    refresh();
  }

  const LIVE_STATUSES = ['STARTING', 'ACTIVE', 'CHECKPOINT', 'UNDER_ATTACK', 'DELIVERY'];
  const REUSABLE_STATUSES = ['CANCELLED', 'COMPLETED', 'CAPTURED', 'FAILED'];

  // A convoy or airdrop that's actually running has live peds/crates/participants.
  async function endLive(c) {
    const typeLabel = kindLabel(c.kind);
    const ok = await confirmAction(`This immediately terminates "${c.name}" for everyone. This can't be undone.`, { title: `Force End ${typeLabel}`, danger: true });
    if (!ok) return;
    error = '';
    busy = { ...busy, [c.id]: true };
    const res = await forceEndConvoy(c.id);
    busy = { ...busy, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || `Failed to end ${typeLabel.toLowerCase()}.`; return; }
    refresh();
  }

  // Reuses the SAME definition (trucks/route/settings or airdrop zones)
  async function reuse(c) {
    const typeLabel = kindLabel(c.kind);
    const msg = `Reset "${c.name}" back to a draft so it can be started again with the same settings?`;
    const ok = await confirmAction(msg, { title: `Reuse ${typeLabel}` });
    if (!ok) return;
    error = '';
    busy = { ...busy, [c.id]: true };
    const res = await reuseConvoy(c.id);
    busy = { ...busy, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || `Failed to reuse ${typeLabel.toLowerCase()}.`; return; }
    refresh();
  }

  let cloneModalOpen = false;
  let cloneTargetConvoy = null;
  let cloneNewName = '';
  let cloneError = '';
  let cloning = false;

  function openCloneModal(c) {
    cloneTargetConvoy = c;
    cloneNewName = `${c.name} (Copy)`;
    cloneError = '';
    cloneModalOpen = true;
  }

  async function doClone() {
    if (!cloneNewName.trim() || cloneNewName.trim().length < 3) {
      cloneError = 'Event name must be at least 3 characters.';
      return;
    }
    cloning = true;
    cloneError = '';
    const res = await cloneConvoy(cloneTargetConvoy.id, cloneNewName.trim());
    cloning = false;
    if (res && res.ok) {
      cloneModalOpen = false;
      cloneTargetConvoy = null;
      cloneNewName = '';
      refresh();
      if (res.convoy && res.convoy.id) {
        dispatch('select', res.convoy.id);
      }
    } else {
      cloneError = (res && res.error) || 'Failed to clone event.';
    }
  }

  function badgeClass(status) {
    return `badge badge-${status.toLowerCase().replace('_', '-')}`;
  }

  // Human label for each event kind — used by the delete/force-end/start
  // confirmations so a Rally Race is never described as a Convoy.
  // solid fills: a hard colour per event type, lettering black or white by contrast (no tint, no glow)
  const KIND_CONFIG = {
    CONVOY: { label: 'Convoy', color: '#ee8a2b', bg: 'rgba(238, 138, 43, 0.12)', border: 'rgba(238, 138, 43, 0.45)' },
    HOT_CARGO: { label: 'Hot Cargo', color: '#e0489f', bg: 'rgba(224, 72, 159, 0.12)', border: 'rgba(224, 72, 159, 0.45)' },
    GANG_AIRDROP: { label: 'Airdrop', color: '#9b7bff', bg: 'rgba(155, 123, 255, 0.12)', border: 'rgba(155, 123, 255, 0.45)' },
    GANG_RACE: { label: 'Rally Race', color: '#22c7d6', bg: 'rgba(34, 199, 214, 0.12)', border: 'rgba(34, 199, 214, 0.45)' },
    TDM: { label: 'TDM', color: '#e5484d', bg: 'rgba(229, 72, 77, 0.12)', border: 'rgba(229, 72, 77, 0.45)' },
    CONTAINER_WARS: { label: 'Container Wars', color: '#52d24a', bg: 'rgba(82, 210, 74, 0.12)', border: 'rgba(82, 210, 74, 0.45)' },
    GANG_TERRITORY: { label: 'Territory', color: '#c45ee0', bg: 'rgba(196, 94, 224, 0.12)', border: 'rgba(196, 94, 224, 0.45)' },
    CRACKDOWN: { label: 'Crackdown', color: '#3b82f6', bg: 'rgba(59, 130, 246, 0.12)', border: 'rgba(59, 130, 246, 0.45)' },
  };
  const kindStyle = (kind) => { const c = getKindMeta(kind).color; return `background:${c}; border-color:${c}; color:${inkOn(c)};`; };

  const KIND_ALIASES = {
    AIRDROP: 'GANG_AIRDROP',
    'RALLY RACE': 'GANG_RACE',
    RALLY_RACE: 'GANG_RACE',
    'HOT CARGO': 'HOT_CARGO',
    'CONTAINER WARS': 'CONTAINER_WARS',
    TERRITORY: 'GANG_TERRITORY',
  };

  function normalizeKind(kind) {
    const raw = String(kind || 'CONVOY').toUpperCase().trim();
    return KIND_ALIASES[raw] || raw;
  }

  function getKindMeta(kind) {
    const norm = normalizeKind(kind);
    return KIND_CONFIG[norm] || KIND_CONFIG.CONVOY;
  }

  const DIFFICULTY_CONFIG = {
    EASY: { color: '#34d399', bg: 'rgba(52, 211, 153, 0.14)', border: 'rgba(52, 211, 153, 0.45)' },
    MEDIUM: { color: '#fbbf24', bg: 'rgba(251, 191, 36, 0.14)', border: 'rgba(251, 191, 36, 0.45)' },
    HARD: { color: '#f87171', bg: 'rgba(248, 113, 113, 0.14)', border: 'rgba(248, 113, 113, 0.45)' },
  };
  function getDiffMeta(diff) {
    const raw = String(diff || '').toUpperCase().trim();
    return DIFFICULTY_CONFIG[raw] || null;
  }

  // Human label for each event kind
  function kindLabel(kind) {
    return getKindMeta(kind).label;
  }
  const KIND_INFO = KIND_CONFIG;

  // c.updatedAt comes through as either an ISO/MySQL datetime string or a
  // raw epoch-ms number depending on how oxmysql serialized the DATETIME
  // column — handle both rather than printing whichever one shows up raw.
  function formatDate(value) {
    if (!value) return '—';
    const ms = typeof value === 'number' ? value : Date.parse(value);
    if (!ms || Number.isNaN(ms)) return String(value);
    return new Date(ms).toLocaleString([], { year: '2-digit', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  }

  onMount(refresh);

  // ── table: search, filters, pagination ──────────────────────────────────────
  let searchQuery = '';
  let kindFilter = 'ALL';
  let statusFilter = 'ALL';
  let pageSize = defaultPageSize([5, 10, 15, 25, 50]);
  let currentPage = 1;
  const PAGE_SIZES = [5, 10, 15, 25, 50];
  const STATUS_FILTERS = [
    { id: 'ALL', label: 'All statuses' },
    { id: 'DRAFT', label: 'Draft' },
    { id: 'SCHEDULED', label: 'Scheduled' },
    { id: 'LIVE', label: 'Live now' },
    { id: 'COMPLETED', label: 'Completed' },
    { id: 'CAPTURED', label: 'Captured' },
    { id: 'FAILED', label: 'Failed' },
    { id: 'CANCELLED', label: 'Cancelled' },
  ];
  function statusGroup(c) {
    if (c.racePending || LIVE_STATUSES.includes(c.status)) return 'LIVE';
    return c.status; // DRAFT | SCHEDULED | COMPLETED | CAPTURED | FAILED | CANCELLED
  }

  // One colour per status, used by the summary strip, the row edge and the badge, so a status reads the same everywhere here.
  // UNDER_ATTACK is a live status that gets its own colour because it needs attention.
  // Red is kept for Cancelled alone, so the one status that was stopped by hand cannot be mistaken for another.
  const STATUS_COLOR = {
    DRAFT: '#c9b68a',        // sand
    SCHEDULED: '#5aa0ff',    // blue
    LIVE: '#2fd27a',         // green: running now
    UNDER_ATTACK: '#f2a93b', // amber: a live event that needs attention
    COMPLETED: '#3cc7e8',    // cyan
    CAPTURED: '#b58cff',     // violet
    FAILED: '#ff8a3d',       // orange
    CANCELLED: '#ef4444',    // red
  };
  const statusKey = (c) => (c.status === 'UNDER_ATTACK' ? 'UNDER_ATTACK' : statusGroup(c));
  const statusColor = (key) => STATUS_COLOR[key] || '#7b8497';
  function rgba(hex, a) {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
  }
  const badgeStyle = (key) => {
    const col = statusColor(key);
    return `color:${inkOn(col)}; background:${col}; border-color:${col};`;
  };
  $: statusCounts = convoys.reduce((acc, c) => {
    const k = statusGroup(c);
    acc[k] = (acc[k] || 0) + 1;
    return acc;
  }, {});
  function pickStatus(id) { statusFilter = statusFilter === id ? 'ALL' : id; }
  $: filtered = convoys.filter((c) => {
    if (kindFilter !== 'ALL') {
      const k = normalizeKind(c.kind);
      if (k !== kindFilter && (c.kind || 'CONVOY') !== kindFilter) return false;
    }
    if (statusFilter !== 'ALL' && statusGroup(c) !== statusFilter) return false;
    const q = searchQuery.toLowerCase().trim();
    if (!q) return true;
    return (c.name || '').toLowerCase().includes(q) || (c.createdByName || '').toLowerCase().includes(q) || (c.cargo?.type || '').toLowerCase().includes(q);
  });
  $: totalCount = filtered.length;
  $: totalPages = Math.max(1, Math.ceil(totalCount / pageSize));
  // the page actually shown: never past the last page, even in the same tick a filter shrank the list
  $: pageNo = Math.min(Math.max(1, currentPage), totalPages);
  $: pageStart = (pageNo - 1) * pageSize;
  $: pageRows = filtered.slice(pageStart, pageStart + pageSize);
  // Back to page 1 whenever the question changes (only the arguments are tracked).
  const resetPage = () => { currentPage = 1; };
  $: resetPage(searchQuery, kindFilter, statusFilter, pageSize);
  // While a race is in its "starts in N minutes" lead-in, keep the list fresh so the
  // row flips from "Starting soon" to Live (or Cancelled) without a manual refresh.
  let leadPoll = null;
  $: if (convoys.some((c) => c.racePending)) {
    if (!leadPoll) leadPoll = setInterval(() => refresh(true), 3000);
  } else if (leadPoll) {
    clearInterval(leadPoll);
    leadPoll = null;
  }
  onDestroy(() => { if (leadPoll) clearInterval(leadPoll); });
</script>

<div class="panel">
  <div class="panel-header">
    <span class="panel-title"><Icon name="list" size={14} /> All Events <span class="count-pill">{convoys.length}</span></span>
    <div style="display:flex; gap:8px;">
      <button class="btn btn-refresh" on:click={refresh}><Icon name="refresh" size={13} /> Refresh</button>
      <button class="btn btn-primary" on:click={() => dispatch('new')}><Icon name="plus" size={13} /> New Event</button>
    </div>
  </div>
  <div class="ev-filters">
    <div class="ev-search">
      <Icon name="search" size={13} />
      <input type="text" placeholder="Search name, creator or cargo..." bind:value={searchQuery} />
      {#if searchQuery}<button class="ev-clear" on:click={() => (searchQuery = '')} aria-label="Clear search"><Icon name="close" size={12} /></button>{/if}
    </div>
    <label class="ev-select"><span>Type</span>
      <select bind:value={kindFilter}>
        <option value="ALL">All types</option>
        {#each Object.entries(KIND_INFO) as [id, k]}<option value={id}>{k.label}</option>{/each}
      </select>
    </label>
    <label class="ev-select"><span>Status</span>
      <select bind:value={statusFilter}>
        {#each STATUS_FILTERS as s}<option value={s.id}>{s.label}</option>{/each}
      </select>
    </label>
    <label class="ev-select"><span>Rows</span>
      <select bind:value={pageSize}>
        {#each PAGE_SIZES as n}<option value={n}>{n}</option>{/each}
      </select>
    </label>
  </div>
  {#if convoys.length > 0}
    <div class="st-strip" role="group" aria-label="Filter by status">
      <button type="button" class="st-chip" class:on={statusFilter === 'ALL'} style="--st:#e5e7eb" aria-pressed={statusFilter === 'ALL'} on:click={() => (statusFilter = 'ALL')}>
        <span class="st-dot"></span>
        <span class="st-name">All</span>
        <span class="st-num">{convoys.length}</span>
      </button>
      {#each STATUS_FILTERS.filter((s) => s.id !== 'ALL') as s (s.id)}
        <button
          type="button"
          class="st-chip"
          class:on={statusFilter === s.id}
          class:zero={!statusCounts[s.id]}
          style="--st:{statusColor(s.id)}"
          aria-pressed={statusFilter === s.id}
          on:click={() => pickStatus(s.id)}
        >
          <span class="st-dot"></span>
          <span class="st-name">{s.label}</span>
          <span class="st-num">{statusCounts[s.id] || 0}</span>
        </button>
      {/each}
    </div>
  {/if}
  <div class="panel-body">
    {#if error}<div class="error" style="margin-bottom:10px">{error}</div>{/if}
    {#if loading}
      <div class="empty-state">Loading...</div>
    {:else if convoys.length === 0}
      <div class="empty-state">Nothing here yet — create your first event to get started.</div>
    {:else}
      <div class="ev-card">
        <!-- TOP TOOLBAR & PAGINATION -->
        <div class="excel-toolbar">
          <div class="excel-info">
            <span class="excel-sheet-pill"><Icon name="grid" size={12} /> Events Database</span>
            <span class="excel-count">
              {#if totalCount > 0}Showing <strong>{pageStart + 1}–{Math.min(pageStart + pageSize, totalCount)}</strong> of <strong>{totalCount}</strong> events{:else}0 events{/if}
            </span>
          </div>
          <div class="excel-pagination-top">
            <button class="ev-page-btn" disabled={pageNo === 1} on:click={() => (currentPage = 1)} title="First page"><Icon name="chevronLeft" size={12} /><Icon name="chevronLeft" size={12} /></button>
            <button class="ev-page-btn" disabled={pageNo === 1} on:click={() => (currentPage = pageNo - 1)} title="Previous page"><Icon name="chevronLeft" size={12} /></button>
            <span class="ev-page-current">Page {pageNo} / {totalPages}</span>
            <button class="ev-page-btn" disabled={pageNo === totalPages} on:click={() => (currentPage = pageNo + 1)} title="Next page"><Icon name="chevronRight" size={12} /></button>
            <button class="ev-page-btn" disabled={pageNo === totalPages} on:click={() => (currentPage = totalPages)} title="Last page"><Icon name="chevronRight" size={12} /><Icon name="chevronRight" size={12} /></button>
          </div>
        </div>

        <div class="ev-scroll">
          <table class="ev-table excel-grid">
            <thead>
              <tr class="excel-header-row">
                <th class="c-idx">#</th>
                <th class="c-name">Event Name</th>
                <th class="c-type">Type</th>
                <th class="c-status">Status</th>
                <th class="c-by">Created By</th>
                <th class="c-date">Updated</th>
                <th class="c-act">Actions</th>
              </tr>
            </thead>
            <tbody>
              {#each pageRows as c, i (c.id)}
                <tr style="--st:{statusColor(statusKey(c))}" on:click={() => dispatch('edit', c.id)}>
                  <td class="c-idx">{pageStart + i + 1}</td>
                  <td class="c-name" title={c.name}><span class="excel-cell-text">{c.name}</span></td>
                  <td class="c-type">
                    <span class="excel-type-badge" style={kindStyle(c.kind)}>
                      <span class="type-dot" style="background: {inkOn(getKindMeta(c.kind).color)};"></span>
                      {getKindMeta(c.kind).label}
                    </span>
                  </td>
                  <td class="c-status">
                    {#if c.racePending}
                      <span class={badgeClass('ACTIVE')} style={badgeStyle('LIVE')}>Starting soon</span>
                    {:else}
                      <span class={badgeClass(c.status)} style={badgeStyle(statusKey(c))}>{STATUS_LABELS[c.status] || c.status}</span>
                    {/if}
                  </td>
                  <td class="c-by" title={c.createdByName || ''}>{c.createdByName || '—'}</td>
                  <td class="c-date">{formatDate(c.updatedAt)}</td>
                  <td class="c-act">
                    <div class="excel-actions">
                      {#if c.racePending}
                        <button class="ex-btn ex-start" disabled={busy[c.id]} title="Skip wait & open start grid" on:click|stopPropagation={() => beginCountdown(c)}><Icon name="play" size={11} /> Start Now</button>
                        <button class="ex-btn ex-danger" disabled={busy[c.id]} title="Cancel race before start" on:click|stopPropagation={() => endLive(c)}><Icon name="close" size={11} /> Force End</button>
                      {:else if c.status === 'DRAFT'}
                        <button
                          class="ex-btn ex-start"
                          disabled={busy[c.id] || !readyToStart(c)}
                          title={readyToStart(c) ? 'Start this event now' : 'Missing required setup — click Edit to review'}
                          on:click|stopPropagation={() => start(c)}
                        ><Icon name="play" size={11} /> Start</button>
                        <button class="ex-btn ex-clone" disabled={busy[c.id]} title="Open the announcement window for this event (Announcements → Event Announcements)" on:click|stopPropagation={() => announceNow(c)}><Icon name="megaphone" size={11} /> Announce</button>
                        {#if c.kind !== 'GANG_TERRITORY'}
                          <button class="ex-btn ex-clone" disabled={busy[c.id] || !readyToStart(c)} title="Run it as a rehearsal: notifications go to you only, nothing is paid or saved" on:click|stopPropagation={() => testRun(c)}><Icon name="eye" size={11} /> Test run</button>
                        {/if}
                      {:else if c.status === 'SCHEDULED'}
                        <button
                          class="ex-btn ex-start"
                          disabled={busy[c.id] || !readyToStart(c)}
                          title={readyToStart(c) ? 'Start this event now' : 'Missing required setup — click Edit to review'}
                          on:click|stopPropagation={() => start(c)}
                        ><Icon name="play" size={11} /> Start</button>
                        <button class="ex-btn ex-clone" disabled={busy[c.id]} title="Open the announcement window for this event (Announcements → Event Announcements)" on:click|stopPropagation={() => announceNow(c)}><Icon name="megaphone" size={11} /> Announce</button>
                        {#if c.kind !== 'GANG_TERRITORY'}
                          <button class="ex-btn ex-clone" disabled={busy[c.id] || !readyToStart(c)} title="Run it as a rehearsal: notifications go to you only, nothing is paid or saved" on:click|stopPropagation={() => testRun(c)}><Icon name="eye" size={11} /> Test run</button>
                        {/if}
                        <button class="ex-btn ex-cancel" disabled={busy[c.id]} title="Cancel scheduled run" on:click|stopPropagation={() => cancel(c)}><Icon name="close" size={11} /> Cancel</button>
                      {:else if LIVE_STATUSES.includes(c.status)}
                        {#if c.kind === 'GANG_RACE' && c.raceGrid}
                          <button class="ex-btn ex-start" disabled={busy[c.id]} title="Racers are gathering — start countdown" on:click|stopPropagation={() => beginCountdown(c)}><Icon name="play" size={11} /> Countdown</button>
                        {/if}
                        <button class="ex-btn ex-danger" disabled={busy[c.id]} title="Force end this event immediately" on:click|stopPropagation={() => endLive(c)}><Icon name="close" size={11} /> Force End</button>
                      {:else if REUSABLE_STATUSES.includes(c.status)}
                        <button class="ex-btn ex-reuse" disabled={busy[c.id]} title="Reset to Draft with the same settings" on:click|stopPropagation={() => reuse(c)}><Icon name="refresh" size={11} /> Reuse</button>
                      {/if}
                      {#if c.status === 'DRAFT' && !c.racePending}
                        <button class="ex-btn ex-edit" title="Open this event in the editor" on:click|stopPropagation={() => dispatch('edit', c.id)}><Icon name="edit" size={11} /> Edit</button>
                      {/if}
                      <button class="ex-btn ex-clone" disabled={busy[c.id]} title="Clone this event configuration as a new event" on:click|stopPropagation={() => openCloneModal(c)}><Icon name="copy" size={11} /> Clone</button>
                      {#if $perms['convoys.delete']}
                        <button class="ex-btn ex-danger" disabled={LIVE_STATUSES.includes(c.status) || c.racePending} title={(LIVE_STATUSES.includes(c.status) || c.racePending) ? 'Force End it first — cannot delete a running event' : 'Delete event'} on:click|stopPropagation={() => remove(c.id, c.name, c.kind)}><Icon name="trash" size={11} /> Delete</button>
                      {/if}
                    </div>
                  </td>
                </tr>
              {:else}
                <tr class="no-hover"><td colspan="7" class="ev-empty">No events match your filters.</td></tr>
              {/each}
            </tbody>
          </table>
        </div>
      </div>
    {/if}
  </div>
</div>
{#if cloneModalOpen}
  <div class="modal-backdrop" on:click|self={() => (cloneModalOpen = false)}>
    <div class="clone-modal">
      <div class="clone-modal-head">
        <span class="clone-modal-title"><Icon name="copy" size={14} /> Clone Event</span>
        <button class="icon-btn" on:click={() => (cloneModalOpen = false)}><Icon name="x" size={13} /></button>
      </div>
      <div class="clone-modal-body">
        <p class="clone-hint">
          Cloning creates a new independent copy of <strong>{cloneTargetConvoy?.name}</strong> with all its routes, rewards, and settings preserved.
        </p>
        <div class="clone-field">
          <label for="clone-name-input">New Event Name</label>
          <input
            id="clone-name-input"
            type="text"
            bind:value={cloneNewName}
            placeholder="e.g. Illegal Street Race – Saturday"
            maxlength="60"
            on:keydown={(e) => e.key === 'Enter' && doClone()}
          />
        </div>
        {#if cloneError}
          <div class="error" style="margin-top:8px;">{cloneError}</div>
        {/if}
      </div>
      <div class="clone-modal-foot">
        <button class="btn" on:click={() => (cloneModalOpen = false)}>Cancel</button>
        <button class="btn btn-primary" disabled={cloning} on:click={doClone}>
          {cloning ? 'Cloning...' : 'Clone Event'}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .count-pill { margin-left: 8px; padding: 1px 9px; border-radius: 999px; background: var(--c-raised, #1f2328); border: 1px solid var(--c-line, #2a2e35); font-size: var(--fs-meta); color: var(--lt-aeb5bd, #aeb5bd); }

  /* ── filter bar ─────────────────────────────────────────────── */
  .ev-filters { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 10px 18px; border-bottom: 1px solid var(--tablet-border); background: var(--tablet-panel-alt); }
  .ev-search { display: flex; align-items: center; gap: 9px; height: 36px; flex: 1; min-width: 240px; max-width: 380px; padding: 0 12px; background: var(--c-panel, #181b1f); border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-ctl); color: var(--text-dim); }
  .ev-search:focus-within { border-color: var(--accent-primary); }
  .ev-search input { flex: 1; min-width: 0; background: transparent; border: none; outline: none; color: var(--text-main, #fff); font-size: var(--fs-body); }
  .ev-search input::placeholder { color: var(--text-placeholder); opacity: 1; }
  .ev-clear { display: flex; background: transparent; border: none; color: var(--text-dim); cursor: pointer; }
  .ev-clear:hover { color: var(--lt-ffffff, #fff); }
  .ev-select { display: flex; align-items: center; gap: 8px; font-size: var(--fs-small); font-weight: 700; color: var(--text-dim); }
  .ev-select select { height: 36px; padding: 0 10px; background: var(--c-panel, #181b1f); border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-ctl); color: var(--text-main, #fff); font-size: var(--fs-body); font-weight: 600; cursor: pointer; outline: none; }
  .ev-select:first-of-type { margin-left: auto; }

  /* ── Excel Toolbar & Top Pagination ──────────────────────────── */
  .excel-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 9px 14px;
    background: var(--bg-surface, #15171b);
    border-bottom: 1px solid var(--c-line, #2a2e35);
  }
  .excel-info {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .excel-sheet-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px;
    background: var(--c-raised, #1f2328);
    border: 1px solid #33374d;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-93c5fd, #93c5fd);
    letter-spacing: 0.01em;
  }
  .excel-count {
    font-size: var(--fs-meta);
    color: #8d949c;
  }
  .excel-count strong {
    color: var(--lt-eceef0, #eceef0);
    font-weight: 700;
  }
  .excel-pagination-top {
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .ev-page-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 28px;
    height: 28px;
    padding: 0 5px;
    background: var(--c-raised, #1f2328);
    border: 1px solid #30353c;
    border-radius: var(--r-ctl);
    color: var(--lt-aeb5bd, #aeb5bd);
    cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease;
  }
  .ev-page-btn:hover:not(:disabled) {
    background: var(--c-line, #2a2e35);
    border-color: #454a66;
    color: var(--lt-ffffff, #ffffff);
  }
  .ev-page-btn:disabled {
    opacity: 0.3;
    cursor: not-allowed;
  }
  .ev-page-current {
    min-width: 82px;
    text-align: center;
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--lt-e3e6e9, #e3e6e9);
    padding: 0 4px;
    letter-spacing: 0.02em;
  }

  /* ── Excel Data Grid Structure ───────────────────────────────── */
  .ev-card {
    background: var(--c-base, #131518);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-panel);
    overflow: hidden;
    box-shadow: none;
  }
  .ev-scroll {
    overflow: auto;
    max-height: clamp(340px, 60vh, 660px);
  }
  .ev-table.excel-grid {
    width: 100%;
    border-collapse: separate;
    border-spacing: 0;
    font-size: var(--fs-body);
    color: var(--lt-c9ced4, #c9ced4);
    background: var(--bg-surface, #15171b);
  }

  /* Column Headers (Excel header band) */
  .excel-header-row th {
    position: sticky;
    top: 0;
    z-index: 2;
    padding: var(--tbl-th-y) var(--tbl-x);
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    color: var(--text-muted);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    text-align: left;
    white-space: nowrap;
    user-select: none;
  }
  .excel-header-row th:last-child {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0;
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }

  /* Status summary strip: one chip per status, in that status's colour; pressing one filters the list to it */
  .st-strip {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    padding: 0 16px 12px;
  }
  .st-chip {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--r-ctl);
    background: transparent;
    color: var(--lt-c9ced4, #c9ced4);
    font: inherit;
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    transition: border-color 0.12s ease, background 0.12s ease;
  }
  .st-chip:hover { border-color: var(--st); }
  .st-chip.on {
    border-color: var(--st);
    background: var(--st);
    color: #0a0a0a;
  }
  .st-chip.on .st-num { background: #0a0a0a; color: #fff; }
  .st-chip.on .st-dot { background: #0a0a0a; }
  .st-chip.zero:not(.on) { opacity: 0.5; }
  .st-dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--st);
  }
  .st-num {
    min-width: 20px;
    padding: 1px 7px;
    border-radius: 3px;
    background: var(--st);
    color: #0d1117;
    font-size: var(--fs-meta);
    font-weight: 800;
    text-align: center;
    font-variant-numeric: tabular-nums;
  }

  /* the row's status colour, as a bar on its left edge */
  .excel-grid td.c-idx { box-shadow: inset 4px 0 0 var(--st); }

  /* Excel Grid Cells */
  .excel-grid td {
    padding: var(--tbl-td-y) var(--tbl-x);
    border-bottom: 1px solid var(--c-line-soft);
    vertical-align: middle;
    color: var(--lt-eceef0, #eceef0);
    background: transparent;
    font-variant-numeric: tabular-nums;
  }
  .excel-grid td:last-child {
    font-variant-numeric: tabular-nums;
  }

  /* Row striping & hover */
  .excel-grid tbody tr {
    cursor: pointer;
    background: var(--c-base, #131518);
    transition: background 0.12s ease;
  }
  .excel-grid tbody tr:nth-child(even) {
    background: var(--c-panel, #181b1f);
  }
  .excel-grid tbody tr:hover {
    background: var(--lt-22262c, #22262c);
  }
  .excel-grid tbody tr.no-hover {
    cursor: default;
    background: var(--c-base, #131518) !important;
  }

  /* Column widths & alignment */
  .c-idx {
    width: 38px;
    text-align: center !important;
    font-variant-numeric: tabular-nums;
  }
  td.c-idx {
    color: #7c848d !important;
    font-weight: 500;
    font-size: var(--fs-meta);
    background: rgba(0, 0, 0, 0.18) !important;
  }
  /* the name gets the room the other columns leave; a long one wraps to two lines instead of being cut short */
  .c-name {
    min-width: 220px;
  }
  td.c-name {
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff) !important;
  }
  .excel-cell-text {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    overflow: hidden;
    white-space: normal;
    overflow-wrap: anywhere;
    line-height: 1.3;
  }
  .c-type {
    width: 122px;
    white-space: nowrap;
  }
  .c-status {
    width: 112px;
    white-space: nowrap;
  }
  .c-by {
    max-width: 120px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  td.c-by {
    color: var(--lt-aeb5bd, #aeb5bd) !important;
    font-size: var(--fs-meta);
  }
  .c-date {
    width: 116px;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  td.c-date {
    color: #8d949c !important;
    font-size: var(--fs-meta);
  }
  .c-act {
    text-align: right !important;
    width: 1%;
    white-space: nowrap;
    padding-right: 10px !important;
  }
  .ev-empty {
    text-align: center;
    padding: 32px 16px !important;
    color: #7c848d !important;
    font-style: italic;
  }

  /* ── Event Type Badges (Custom distinct colors) ──────────────── */
  .excel-type-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px;
    border-radius: var(--r-tag);
    border-width: 1px;
    border-style: solid;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    white-space: nowrap;
  }
  .type-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
    box-shadow: none;
  }

  /* ── Excel Action Buttons ────────────────────────────────────── */
  .excel-actions {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    justify-content: flex-end;
  }
  /* Row actions: Edit / Clone / Reuse each have their own colour;
     colour is kept for Start (go), Cancel (caution) and Delete / Force end. */
  .ex-btn {
    height: 28px;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 0 7px;
    font-size: var(--fs-meta);
    font-weight: 600;
    border-radius: var(--r-ctl);
    border: 1px solid var(--c-line, #2a2e35);
    background: var(--c-raised, #1f2328);
    color: var(--lt-c9ced4, #c9ced4);
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease;
    user-select: none;
  }
  .ex-btn:hover:not(:disabled) {
    background: var(--c-hover, #272b31);
    border-color: #3a4048;
    color: var(--lt-eceef0, #eceef0);
  }
  .ex-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .ex-start {
    color: var(--lt-46c98b, #46c98b);
    background: rgba(70, 201, 139, 0.1);
    border-color: rgba(70, 201, 139, 0.4);
  }
  .ex-start:hover:not(:disabled) {
    color: #15171b;
    background: #46c98b;
    border-color: #46c98b;
  }

  /* Edit = blue, Clone = violet, Reuse = teal: flat tint, solid fill on hover (same style as Start / Cancel) */
  .ex-edit {
    color: #6aa8ff;
    background: rgba(106, 168, 255, 0.1);
    border-color: rgba(106, 168, 255, 0.4);
  }
  .ex-edit:hover:not(:disabled) {
    color: #0b1626;
    background: #6aa8ff;
    border-color: #6aa8ff;
  }
  .ex-clone {
    color: #b794f6;
    background: rgba(183, 148, 246, 0.1);
    border-color: rgba(183, 148, 246, 0.4);
  }
  .ex-clone:hover:not(:disabled) {
    color: #150d26;
    background: #b794f6;
    border-color: #b794f6;
  }
  .ex-reuse {
    color: #2dd4bf;
    background: rgba(45, 212, 191, 0.1);
    border-color: rgba(45, 212, 191, 0.4);
  }
  .ex-reuse:hover:not(:disabled) {
    color: #06201c;
    background: #2dd4bf;
    border-color: #2dd4bf;
  }

  .ex-cancel {
    color: var(--lt-f2a93b, #f2a93b);
    background: rgba(242, 169, 59, 0.1);
    border-color: rgba(242, 169, 59, 0.4);
  }
  .ex-cancel:hover:not(:disabled) {
    color: #1d1405;
    background: #f2a93b;
    border-color: #f2a93b;
  }

  .ex-danger {
    color: var(--lt-ff8076, #ff8076);
    background: transparent;
    border-color: rgba(255, 93, 80, 0.45);
  }
  .ex-danger:hover:not(:disabled) {
    color: var(--lt-ffa39b, #ffa39b);
    background: rgba(255, 93, 80, 0.14);
    border-color: #ff5d50;
  }

  .modal-backdrop {
    position: fixed;
    inset: 0;
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.7);
  }
  .clone-modal {
    width: min(460px, 92vw);
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-panel);
    box-shadow: none;
    overflow: hidden;
  }
  .clone-modal-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: var(--bg-surface, #15171b);
    border-bottom: 1px solid var(--c-line, #2a2e35);
  }
  .clone-modal-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #fff);
  }
  .clone-modal-body {
    padding: 18px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .clone-hint {
    font-size: var(--fs-body);
    color: var(--text-dim, #c9ced4);
    line-height: 1.5;
    margin: 0;
  }
  .clone-hint strong {
    color: var(--lt-ffffff, #fff);
  }
  .clone-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .clone-field label {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--lt-c9ced4, #c9ced4);
    letter-spacing: 0.01em;
  }
  .clone-field input {
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-c9ced4, #c9ced4);
    padding: 9px 12px;
    font-size: var(--fs-body);
    outline: none;
    transition: border-color 0.15s ease;
  }
  .clone-field input:focus {
    border-color: var(--accent-primary);
    box-shadow: 0 0 0 2px rgba(var(--accent-primary-rgb), 0.2);
  }
  .clone-modal-foot {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding: 12px 16px;
    background: var(--bg-surface, #15171b);
    border-top: 1px solid var(--c-line, #2a2e35);
  }

  /* a narrower screen drops the least useful columns instead of pushing the Actions column out of view */
  @media (max-width: 1500px) {
    .excel-grid .c-by, .excel-grid .c-date { display: none; }
  }
  @media (max-width: 1300px) {
  }
</style>
