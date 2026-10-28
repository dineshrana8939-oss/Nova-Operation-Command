<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import DifficultyBadge from './DifficultyBadge.svelte';
  import StatStrip from './StatStrip.svelte';
  import { avatarColor, initials } from '../../util/avatar.js';
  import TablePager from '../../tablet/ui/TablePager.svelte';

  export let registeredConvoys = []; // list of convoy objects that gang is registered for
  export let roster = null; // gang roster object with members and convoys
  export let isLeader = false;
  // Role-permission-driven (see GangService.SetRolePermission): a member the
  // leader granted 'registerRoster' may set the roster on their behalf.
  export let canRegisterRoster = false;
  export let formatScheduled = (ts) => ts;

  const dispatch = createEventDispatcher();

  let searchQuery = '';
  let statusFilter = 'all'; // 'all', 'upcoming', 'active', 'completed'
  let selectedRegistration = null; // clicked convoy for detail preview

  function isUpcoming(status) {
    return status === 'DRAFT' || status === 'SCHEDULED' || status === 'NOT_STARTED';
  }

  function isActive(status) {
    return ['STARTING', 'ACTIVE', 'CHECKPOINT', 'UNDER_ATTACK', 'DELIVERY'].includes(status);
  }

  function isCompleted(status) {
    return ['COMPLETED', 'CAPTURED', 'FAILED', 'CANCELLED'].includes(status);
  }

  // Readable kind line (was the raw enum, e.g. CONTAINER_WARS)
  const KIND_NAMES = { CONVOY: 'CONVOY', GANG_AIRDROP: 'GANG AIRDROP', HOT_CARGO: 'HOT CARGO', GANG_RACE: 'GANG RALLY', TDM: 'TDM MATCH', CONTAINER_WARS: 'CONTAINER WARS', GANG_TERRITORY: 'TERRITORY AUCTION' };

  // Count stats
  $: upcomingCount = registeredConvoys.filter((c) => isUpcoming(c.status)).length;
  $: activeCount = registeredConvoys.filter((c) => isActive(c.status)).length;
  $: completedCount = registeredConvoys.filter((c) => c.status === 'COMPLETED' || c.status === 'CAPTURED').length;
  $: cancelledCount = registeredConvoys.filter((c) => c.status === 'CANCELLED' || c.status === 'FAILED').length;

  $: statItems = [
    { label: 'Upcoming', value: upcomingCount, icon: 'calendar', accent: '#5aa9e6' },
    { label: 'Active Runs', value: activeCount, icon: 'truck', accent: '#70b982' },
    { label: 'Completed', value: completedCount, icon: 'checkCircle', accent: '#a78bdb' },
    { label: 'Cancelled / Failed', value: cancelledCount, icon: 'alertCircle', accent: '#e0707e' },
  ];

  // Filter list
  $: filteredConvoys = registeredConvoys.filter((c) => {
    if (statusFilter === 'upcoming' && !isUpcoming(c.status)) return false;
    if (statusFilter === 'active' && !isActive(c.status)) return false;
    if (statusFilter === 'completed' && !isCompleted(c.status)) return false;

    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase().trim();
      const matchName = c.name?.toLowerCase().includes(q);
      const matchCargo = c.cargo?.type?.toLowerCase().includes(q);
      if (!matchName && !matchCargo) return false;
    }

    return true;
  });

  // pagination: 10 per page by default, back to page 1 whenever the search / status filter changes
  let regPage = 1;
  let regSize = 10;
  $: pagedConvoys = filteredConvoys.slice((regPage - 1) * regSize, regPage * regSize);
  const resetRegPage = () => { regPage = 1; };
  $: resetRegPage(searchQuery, statusFilter);

  function getRosterMembers(convoyId) {
    const entry = roster?.convoys?.find((rc) => rc.id === convoyId);
    if (!entry || !entry.roster) return [];
    return (roster.members || []).filter((m) => entry.roster.includes(m.identifier));
  }

  function getRosterCount(convoyId) {
    const entry = roster?.convoys?.find((rc) => rc.id === convoyId);
    return entry?.roster?.length || 0;
  }
</script>

<div class="registrations-view">
  <!-- Top Stat Strip -->
  <StatStrip stats={statItems} />

  <!-- Search and Tabs -->
  <div class="controls-bar">
    <div class="status-tabs">
      <button
        class="tab-btn"
        class:active={statusFilter === 'all'}
        on:click={() => (statusFilter = 'all')}
      >
        All Registrations <span class="counter">{registeredConvoys.length}</span>
      </button>
      <button
        class="tab-btn"
        class:active={statusFilter === 'upcoming'}
        on:click={() => (statusFilter = 'upcoming')}
      >
        Upcoming <span class="counter">{upcomingCount}</span>
      </button>
      <button
        class="tab-btn"
        class:active={statusFilter === 'active'}
        on:click={() => (statusFilter = 'active')}
      >
        Active <span class="counter">{activeCount}</span>
      </button>
      <button
        class="tab-btn"
        class:active={statusFilter === 'completed'}
        on:click={() => (statusFilter = 'completed')}
      >
        Completed <span class="counter">{completedCount + cancelledCount}</span>
      </button>
    </div>

    <div class="search-box">
      <Icon name="search" size={13} />
      <input
        type="text"
        placeholder="Search registrations..."
        bind:value={searchQuery}
      />
      {#if searchQuery}
        <button class="clear-search" on:click={() => (searchQuery = '')}>
          <Icon name="close" size={12} />
        </button>
      {/if}
    </div>
  </div>

  <!-- Content Table -->
  <div class="table-card">
    <TablePager top bind:page={regPage} bind:pageSize={regSize} total={filteredConvoys.length} noun="registrations" sizes={[5, 10, 15, 25, 50]} />
    <div class="table-responsive">
      <table class="reg-table">
        <thead>
          <tr>
            <th>Event</th>
            <th>Date / Departure</th>
            <th>Cargo</th>
            <th>Difficulty</th>
            <th>Roster Crew</th>
            <th>Status</th>
            <th>Action</th>
          </tr>
        </thead>
        <tbody>
          {#if filteredConvoys.length === 0}
            <tr>
              <td colspan="7" class="empty-cell">
                <div class="empty-box">
                  <div class="empty-icon-wrap">
                    <Icon name="list" size={28} />
                  </div>
                  <h4 class="empty-title">
                    {registeredConvoys.length === 0 ? 'No Events Registered Yet' : 'No Matching Registrations'}
                  </h4>
                  <p class="empty-desc">
                    {registeredConvoys.length === 0
                      ? 'Your gang has not signed up for any upcoming events. Browse open events and register your crew.'
                      : 'No registered event matches the active search or status filter.'}
                  </p>
                  {#if registeredConvoys.length === 0}
                    <button class="btn btn-primary btn-sm" on:click={() => dispatch('browseConvoys')}>
                      <Icon name="truck" size={13} />
                      <span>Browse Events</span>
                    </button>
                  {/if}
                </div>
              </td>
            </tr>
          {:else}
            {#each pagedConvoys as c (c.id)}
              {@const crewMembers = getRosterMembers(c.id)}
              {@const crewCount = crewMembers.length}
              {@const maxCap = c.maxGangParticipants || 5}
              <tr
                class="reg-row"
                class:active-row={selectedRegistration?.id === c.id}
                on:click={() => (selectedRegistration = selectedRegistration?.id === c.id ? null : c)}
              >
                <!-- Convoy Name -->
                <td class="col-name">
                  <div class="convoy-name-cell">
                    <span class="kind-icon">
                      <Icon name={c.kind === 'HOT_CARGO' ? 'flame' : (c.kind === 'GANG_AIRDROP' ? 'parachute' : ((c.kind === 'GANG_RACE' || c.kind === 'TDM') ? 'flag' : (c.kind === 'CONTAINER_WARS' ? 'box' : 'truck')))} size={13} />
                    </span>
                    <div class="name-text">
                      <span class="convoy-name">{c.name}</span>
                      <span class="convoy-kind">{KIND_NAMES[c.kind] || 'CONVOY'}</span>
                    </div>
                  </div>
                </td>

                <!-- Date / Departure -->
                <td class="col-date">
                  <span class="date-text">{c.scheduledAt ? formatScheduled(c.scheduledAt) : 'Unscheduled'}</span>
                </td>

                <!-- Cargo -->
                <td class="col-cargo">
                  <span class="cargo-tag">
                    <Icon name="box" size={11} />
                    <span>{c.cargo?.type || 'STANDARD'}</span>
                  </span>
                </td>

                <!-- Difficulty -->
                <td class="col-diff">
                  <DifficultyBadge difficulty={c.difficulty || 'MEDIUM'} />
                </td>

                <!-- Crew Roster Chips / Count -->
                <td class="col-crew">
                  <div class="crew-summary">
                    <span class="crew-count">{crewCount} / {maxCap}</span>
                    <div class="crew-mini-avatars">
                      {#each crewMembers.slice(0, 3) as m (m.identifier)}
                        <span
                          class="crew-dot-avatar"
                          style="background: {avatarColor(m.name || m.identifier)}"
                          title={m.name}
                        >
                          {initials(m.name || m.identifier)}
                        </span>
                      {/each}
                      {#if crewMembers.length > 3}
                        <span class="crew-more">+{crewMembers.length - 3}</span>
                      {/if}
                    </div>
                  </div>
                </td>

                <!-- Status -->
                <td class="col-status">
                  <StatusBadge status={c.status} />
                </td>

                <!-- Action -->
                <td class="col-action" on:click|stopPropagation>
                  <div class="action-wrap">
                    {#if canRegisterRoster && isUpcoming(c.status)}
                      {#if c.registrationMode !== 'GANG'}
                        <button class="btn btn-primary btn-xs" on:click={() => dispatch('editRoster', c)}>
                          <Icon name="edit" size={11} />
                          <span>Edit Roster</span>
                        </button>
                      {/if}
                      <button class="btn btn-danger btn-xs" on:click={() => dispatch('unregisterAll', c.id)}>
                        Unregister
                      </button>
                    {:else if isActive(c.status) && c.kind === 'TDM'}
                      <span class="convoy-kind">Match live</span>
                    {:else if isActive(c.status)}
                      {#if c.joined}
                        <button class="btn btn-danger btn-xs" on:click={() => dispatch('leave', c.id)}>
                          Leave
                        </button>
                      {:else}
                        <button class="btn btn-primary btn-xs" on:click={() => dispatch('join', c.id)}>
                          Join
                        </button>
                      {/if}
                    {:else}
                      <button class="btn btn-outline btn-xs" on:click={() => dispatch('viewDetails', c)}>
                        View
                      </button>
                    {/if}
                  </div>
                </td>
              </tr>

              <!-- Expandable Inline Details if clicked -->
              {#if selectedRegistration?.id === c.id}
                <tr class="details-row">
                  <td colspan="7">
                    <div class="inline-details-box">
                      <div class="detail-header">
                        <span class="detail-label">Registered Roster Details — {c.name}</span>
                        <div class="detail-actions">
                          {#if canRegisterRoster && isUpcoming(c.status)}
                            <button class="btn btn-primary btn-xs" on:click={() => dispatch('editRoster', c)}>
                              <Icon name="edit" size={11} />
                              <span>Modify Squad</span>
                            </button>
                          {/if}
                        </div>
                      </div>

                      <div class="crew-grid">
                        {#if crewMembers.length === 0}
                          <span class="no-crew">No crew members selected. Click "Edit Roster" to deploy members.</span>
                        {:else}
                          {#each crewMembers as m (m.identifier)}
                            <div class="crew-member-pill">
                              <span class="member-av" style="background: {avatarColor(m.name || m.identifier)}">
                                {initials(m.name || m.identifier)}
                              </span>
                              <div class="member-meta">
                                <span class="name">{m.name}</span>
                                <span class="role">{m.rank || 'Member'}</span>
                              </div>
                              <span class="status-dot" class:online={m.online}></span>
                            </div>
                          {/each}
                        {/if}
                      </div>
                    </div>
                  </td>
                </tr>
              {/if}
            {/each}
          {/if}
        </tbody>
      </table>
    </div>
  </div>
</div>

<style>
  .registrations-view {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .controls-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md, 3px);
    padding: 11px 14px;
    flex-wrap: wrap;
  }

  .status-tabs {
    display: flex;
    align-items: center;
    gap: 6px;
    background: var(--c-panel);
    padding: 4px;
    border-radius: var(--radius-sm, 5px);
    border: 1px solid var(--tablet-border);
  }

  .tab-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 7px 14px;
    border-radius: var(--radius-sm, 5px);
    background: transparent;
    border: none;
    color: var(--text-dim);
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }

  .tab-btn:hover {
    color: var(--text-main);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
  }

  .tab-btn.active {
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #eceef0);
    font-weight: 700;
  }

  .counter {
    font-size: var(--fs-meta);
    font-weight: var(--fw-value);
    background: rgba(var(--ltc-4-30-66, 4, 30, 66), 0.45);
    padding: 1px 6px;
    border-radius: 999px;
  }

  .search-box {
    display: flex;
    align-items: center;
    gap: 6px;
    background: var(--c-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 0 12px;
    height: 34px;
    color: var(--text-dim);
    min-width: 180px;
  }

  .search-box:focus-within {
    border-color: var(--accent-primary);
  }

  .search-box input {
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-main);
    font-size: var(--fs-small);
    width: 100%;
  }

  .search-box input::placeholder {
    color: var(--text-placeholder);
    opacity: 1;
  }

  .clear-search {
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
    display: flex;
  }

  .clear-search:hover {
    color: var(--text-main);
  }

  .table-card {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md, 3px);
    overflow: hidden;
    box-shadow: var(--shadow-soft);
  }

  .table-responsive {
    overflow-x: auto;
    width: 100%;
  }

  /* Excel-style grid, matching ConvoyTable/LeaderboardView's presentation —
     a border around the table plus a vertical rule between each column. */
  .reg-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--fs-body);
    text-align: left;
    border: none;
  }

  .reg-table th {
    background: var(--c-panel);
    color: var(--text-muted);
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: var(--tbl-th-y) var(--tbl-x);
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
    letter-spacing: 0;
  }

  .reg-table th:last-child {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0;
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }

  .reg-row {
    border-bottom: 1px solid var(--tablet-border);
    cursor: pointer;
    transition: background 0.12s ease;
  }

  .reg-row:nth-child(even) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
  }

  .reg-row:hover {
    background: rgba(var(--accent-primary-rgb), 0.06);
  }

  .reg-row.active-row {
    background: var(--c-hover);
    border-bottom-color: var(--tablet-border-strong);
  }

  .reg-row td {
    padding: var(--tbl-td-y) var(--tbl-x);
    vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }

  .reg-row td:last-child {
    font-variant-numeric: tabular-nums;
  }

  .convoy-name-cell {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .kind-icon {
    width: 30px;
    height: 30px;
    border-radius: var(--radius-sm, 5px);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--accent-primary-light);
    flex-shrink: 0;
  }

  .name-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .convoy-name {
    font-weight: 600;
    color: var(--text-main);
  }

  .convoy-kind {
    font-size: var(--fs-meta);
    color: var(--text-dim);
    letter-spacing: 0.01em;
  }

  .date-text {
    font-size: var(--fs-small);
    color: var(--text-label);
  }

  .cargo-tag {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: var(--fs-meta);
    color: var(--accent-primary-light);
    font-weight: 600;
  }

  .crew-summary {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .crew-count {
    font-weight: var(--fw-value);
    color: var(--text-main);
    font-size: var(--fs-body);
  }

  .crew-mini-avatars {
    display: flex;
    align-items: center;
  }

  .crew-dot-avatar {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
    margin-left: -5px;
    border: 2px solid var(--tablet-panel);
  }

  .crew-dot-avatar:first-child {
    margin-left: 0;
  }

  .crew-more {
    font-size: var(--fs-meta);
    color: var(--text-dim);
    margin-left: 4px;
  }

  .action-wrap {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    border-radius: var(--radius-sm, 5px);
    font-family: var(--font-ui);
    font-weight: 700;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
    border: 1px solid var(--tablet-border-strong);
    background: var(--tablet-panel-alt);
    color: var(--text-main);
    white-space: nowrap;
  }

  .btn-xs {
    padding: 4px 9px;
    font-size: var(--fs-meta);
  }

  .btn-sm {
    padding: 7px 12px;
    font-size: var(--fs-small);
  }

  .btn-outline:hover:not(:disabled) {
    background: var(--c-hover);
    border-color: var(--c-line);
  }

  .btn-primary {
    background: var(--es-accent, #4f94e6);
    border-color: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #eceef0);
    font-weight: 700;
  }

  .btn-primary:hover:not(:disabled) {
    background: var(--es-accent-hover, #66a3eb);
    border-color: var(--es-accent-hover, #66a3eb);
  }

  .btn-danger {
    background: #ef4444;
    border-color: #ef4444;
    color: #ffffff;
  }

  .btn-danger:hover:not(:disabled) {
    background: var(--c-hover);
    border-color: var(--tablet-danger);
  }

  /* Inline expandable details */
  .details-row td {
    padding: 0 !important;
    background: var(--c-base);
    border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }

  .inline-details-box {
    padding: 14px 20px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .detail-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .detail-label {
    font-size: var(--fs-small);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: var(--text-label);
  }

  .crew-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 8px;
  }

  .crew-member-pill {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
  }

  .member-av {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
  }

  .member-meta {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  .member-meta .name {
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    color: var(--text-main);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .member-meta .role {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }

  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-placeholder);
    flex-shrink: 0;
  }

  .status-dot.online {
    background: var(--tablet-success);
  }

  .no-crew {
    font-size: var(--fs-small);
    color: var(--text-dim);
    grid-column: 1 / -1;
  }

  /* Empty state */
  .empty-cell {
    padding: 40px 16px !important;
    text-align: center;
  }

  .empty-box {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 9px;
  }

  .empty-icon-wrap {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-dim);
  }

  .empty-title {
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--text-main);
    margin: 0;
  }

  .empty-desc {
    font-size: var(--fs-small);
    color: var(--text-dim);
    max-width: 360px;
    margin: 0;
    line-height: 1.5;
  }
  .table-card :global(.tp.top) { border: none; border-bottom: 1px solid var(--es-line); border-radius: 0; }

  /* the date and time stay on one line ("PM" used to drop to a line of its own) */
  .date-text { white-space: nowrap; }
</style>
