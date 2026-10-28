<script>
  import TablePager from '../../tablet/ui/TablePager.svelte';
  import { createEventDispatcher } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import DifficultyBadge from './DifficultyBadge.svelte';

  export let convoys = []; // Merged list of upcoming and active convoys
  export let isPolice = false;
  export let isLeader = false;
  // Signing the gang up for events on the leader's behalf. Comes from the
  // server's role permissions, so a member the leader granted 'registerRoster'
  // gets the register controls too. Display-only — the write is re-checked
  // server-side in ConvoyManager.setGangRoster.
  export let canRegisterRoster = false;
  export let registeredConvoys = []; // Convoys where gang is registered
  // The next active (or next upcoming) convoy — previously rendered as a large
  // standalone "Priority Operation" card above this table. It's a row highlight
  // now instead: same information, no extra vertical space, and it can't
  // crowd the columns because it lives inside the row it describes.
  export let priorityConvoyId = null;
  export let formatScheduled = (ts) => ts;

  const dispatch = createEventDispatcher();

  // Search & Filter state
  let searchQuery = '';
  let statusTab = 'all'; // 'all', 'upcoming', 'active', 'completed'
  let selectedCargo = 'ALL';
  let selectedDifficulty = 'ALL';
  let selectedStatus = 'ALL';
  let sortBy = 'departure'; // 'departure', 'name', 'difficulty'

  // Pagination state
  let currentPage = 1;
  let pageSize = 10;

  const CARGO_OPTIONS = ['ALL', 'WEAPONS', 'DRUGS', 'CASH', 'CONTRABAND', 'MILITARY', 'HIGH_VALUE', 'CUSTOM'];
  const DIFFICULTY_OPTIONS = ['ALL', 'EASY', 'MEDIUM', 'HARD', 'EXTREME'];

  const KIND_LABELS = {
    CONVOY: 'Convoy', GANG_AIRDROP: 'Gang Airdrop', HOT_CARGO: 'Hot Cargo',
    GANG_RACE: 'Gang Rally', TDM: 'TDM Match', CONTAINER_WARS: 'Container Wars', GANG_TERRITORY: 'Territory Auction', CRACKDOWN: 'Operation Crackdown',
  };
  const kindLabel = (kind) => KIND_LABELS[kind] || 'Convoy';
  // 'CONTRABAND' / 'HIGH_VALUE' -> 'Contraband' / 'High Value'
  const titleCase = (v) => String(v || '').toLowerCase().split(/[_\s]+/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(' ');
  const cargoLabel = (c) => c.kind === 'TDM' ? 'Match' : titleCase(c.cargo?.type || (c.kind === 'GANG_RACE' ? 'Stakes' : 'Standard'));

  function kindIcon(kind) {
    if (kind === 'HOT_CARGO') return 'flame';
    if (kind === 'GANG_AIRDROP') return 'parachute';
    if (kind === 'GANG_RACE' || kind === 'TDM') return 'flag';
    return 'truck';
  }

  function isUpcoming(status) {
    return status === 'DRAFT' || status === 'SCHEDULED' || status === 'NOT_STARTED';
  }

  function isActive(status) {
    return ['STARTING', 'ACTIVE', 'CHECKPOINT', 'UNDER_ATTACK', 'DELIVERY'].includes(status);
  }

  function isCompleted(status) {
    return ['COMPLETED', 'CAPTURED', 'FAILED', 'CANCELLED'].includes(status);
  }

  // Filter & sort logic
  $: filteredConvoys = convoys.filter((c) => {
    // Primary Tab filter
    if (statusTab === 'upcoming' && !isUpcoming(c.status)) return false;
    if (statusTab === 'active' && !isActive(c.status)) return false;
    if (statusTab === 'completed' && !isCompleted(c.status)) return false;

    // Search query
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase().trim();
      const matchName = c.name?.toLowerCase().includes(q);
      const matchCargo = c.cargo?.type?.toLowerCase().includes(q);
      const matchDesc = c.shortDescription?.toLowerCase().includes(q);
      if (!matchName && !matchCargo && !matchDesc) return false;
    }

    // Cargo filter
    if (selectedCargo !== 'ALL') {
      if ((c.cargo?.type || 'CUSTOM').toUpperCase() !== selectedCargo) return false;
    }

    // Difficulty filter
    if (selectedDifficulty !== 'ALL') {
      if ((c.difficulty || 'MEDIUM').toUpperCase() !== selectedDifficulty) return false;
    }

    // Status filter
    if (selectedStatus !== 'ALL') {
      if (c.status !== selectedStatus) return false;
    }

    return true;
  }).sort((a, b) => {
    if (sortBy === 'name') {
      return (a.name || '').localeCompare(b.name || '');
    }
    if (sortBy === 'difficulty') {
      const order = { EASY: 1, MEDIUM: 2, HARD: 3, EXTREME: 4 };
      return (order[b.difficulty] || 0) - (order[a.difficulty] || 0);
    }
    // Default: Departure / Activity
    if (isActive(a.status) && !isActive(b.status)) return -1;
    if (!isActive(a.status) && isActive(b.status)) return 1;
    const timeA = a.scheduledAt || 0;
    const timeB = b.scheduledAt || 0;
    return timeA - timeB;
  });

  // Pagination calculation
  $: totalCount = filteredConvoys.length;
  $: totalPages = Math.max(1, Math.ceil(totalCount / pageSize));
  $: if (currentPage > totalPages) currentPage = totalPages;
  $: paginatedConvoys = filteredConvoys.slice((currentPage - 1) * pageSize, currentPage * pageSize);

  function resetFilters() {
    searchQuery = '';
    statusTab = 'all';
    selectedCargo = 'ALL';
    selectedDifficulty = 'ALL';
    selectedStatus = 'ALL';
    currentPage = 1;
  }
</script>

<div class="convoy-table-container">
  <!-- Controls Bar: Search & Filters -->
  <div class="table-controls">
    <div class="tab-filters">
      <button
        class="tab-pill"
        class:active={statusTab === 'all'}
        on:click={() => { statusTab = 'all'; currentPage = 1; }}
      >
        All Events <span class="tab-count">{convoys.length}</span>
      </button>
      <button
        class="tab-pill"
        class:active={statusTab === 'upcoming'}
        on:click={() => { statusTab = 'upcoming'; currentPage = 1; }}
      >
        Upcoming <span class="tab-count">{convoys.filter((c) => isUpcoming(c.status)).length}</span>
      </button>
      <button
        class="tab-pill"
        class:active={statusTab === 'active'}
        on:click={() => { statusTab = 'active'; currentPage = 1; }}
      >
        Active <span class="tab-count">{convoys.filter((c) => isActive(c.status)).length}</span>
      </button>
      <button
        class="tab-pill"
        class:active={statusTab === 'completed'}
        on:click={() => { statusTab = 'completed'; currentPage = 1; }}
      >
        Completed <span class="tab-count">{convoys.filter((c) => isCompleted(c.status)).length}</span>
      </button>
    </div>

    <div class="filter-actions">
      <!-- Search input -->
      <div class="search-box">
        <Icon name="search" size={13} />
        <input
          type="text"
          placeholder="Search event or cargo..."
          bind:value={searchQuery}
          on:input={() => (currentPage = 1)}
        />
        {#if searchQuery}
          <button class="clear-search" on:click={() => { searchQuery = ''; currentPage = 1; }}>
            <Icon name="close" size={12} />
          </button>
        {/if}
      </div>

      <!-- Dropdown filters -->
      <div class="select-group">
        <div class="select-wrap" title="Filter by cargo">
          <select bind:value={selectedCargo} on:change={() => (currentPage = 1)}>
            <option value="ALL">Cargo: All</option>
            {#each CARGO_OPTIONS.filter((x) => x !== 'ALL') as cargo}
              <option value={cargo}>{cargo}</option>
            {/each}
          </select>
          <div class="select-arrow"><Icon name="chevronDown" size={11} /></div>
        </div>

        <div class="select-wrap" title="Filter by difficulty">
          <select bind:value={selectedDifficulty} on:change={() => (currentPage = 1)}>
            <option value="ALL">Difficulty: All</option>
            {#each DIFFICULTY_OPTIONS.filter((x) => x !== 'ALL') as diff}
              <option value={diff}>{diff}</option>
            {/each}
          </select>
          <div class="select-arrow"><Icon name="chevronDown" size={11} /></div>
        </div>

        <div class="select-wrap" title="Sort by">
          <select bind:value={sortBy}>
            <option value="departure">Sort: Departure</option>
            <option value="name">Sort: Name (A-Z)</option>
            <option value="difficulty">Sort: Difficulty</option>
          </select>
          <div class="select-arrow"><Icon name="chevronDown" size={11} /></div>
        </div>
      </div>
    </div>
  </div>

  <!-- Events Table -->
  <TablePager top bind:page={currentPage} bind:pageSize total={totalCount} noun="events" sizes={[5, 10, 15, 25, 50]} />
  <div class="table-responsive">
    <table class="modern-table">
      <thead>
        <tr>
          <th class="col-event">Event</th>
          <th class="col-cargo">Cargo</th>
          <th class="col-diff">Difficulty</th>
          <th class="col-time">Departure / Progress</th>
          <th class="col-reg">{isPolice ? 'Escorts' : 'Registration'}</th>
          <th class="col-status">Status</th>
          <th class="col-action">Action</th>
        </tr>
      </thead>
      <tbody>
        {#if paginatedConvoys.length === 0}
          <tr>
            <td colspan="7" class="empty-cell">
              <div class="empty-wrap">
                <Icon name="truck" size={32} />
                <p class="empty-title">No Events Found</p>
                <p class="empty-sub">There are no events matching your search or active filters.</p>
                {#if searchQuery || statusTab !== 'all' || selectedCargo !== 'ALL' || selectedDifficulty !== 'ALL'}
                  <button class="btn btn-outline btn-sm" on:click={resetFilters}>Clear Filters</button>
                {/if}
              </div>
            </td>
          </tr>
        {:else}
          {#each paginatedConvoys as c (c.id)}
            {@const isReg = registeredConvoys.some((rc) => rc.id === c.id)}
            {@const gangCap = c.maxGangParticipants || 5}
            {@const policeCap = c.maxPoliceParticipants || 20}
            {@const regMode = c.registrationMode || 'ROSTER'}
            {@const regCount = isPolice ? (c.policeRegisteredCount || 0) : (c.gangParticipants || (isReg ? 1 : 0))}
            {@const capLimit = isPolice ? policeCap : gangCap}
            {@const isPriority = priorityConvoyId != null && c.id === priorityConvoyId}
            <tr
              class="table-row"
              class:priority-row={isPriority}
              title={isPriority ? 'Priority operation — next up' : undefined}
              on:click={() => dispatch('viewDetails', c)}
            >
              <!-- Event Name & Kind -->
              <td class="col-event">
                <div class="event-cell">
                  {#if isPriority}
                    <!-- Priority marker: a pulsing dot in the row's own gutter
                         rather than a separate card above the table. Absolute
                         so it never widens the column or squeezes the name. -->
                    <span class="priority-dot" aria-label="Priority operation"></span>
                  {/if}
                  <span class="event-icon" class:active-glow={isActive(c.status)}>
                    <Icon name={kindIcon(c.kind)} size={14} />
                  </span>
                  <div class="event-text">
                    <span class="event-name">{c.name}</span>
                    <span class="event-type">
                      {kindLabel(c.kind)}
                      {#if isPriority}
                        <span class="priority-tag">Priority</span>
                      {/if}
                    </span>
                  </div>
                </div>
              </td>

              <!-- Cargo -->
              <td class="col-cargo">
                <div class="cargo-tag">
                  <Icon name={(c.kind === 'GANG_RACE' || c.kind === 'TDM') ? 'flag' : 'box'} size={12} />
                  <span>{cargoLabel(c)}</span>
                </div>
              </td>

              <!-- Difficulty -->
              <td class="col-diff">
                <DifficultyBadge difficulty={c.difficulty || 'MEDIUM'} />
              </td>

              <!-- Departure / Time -->
              <td class="col-time">
                {#if isActive(c.status)}
                  <div class="active-time">
                    {#if c.kind === 'GANG_RACE'}
                      <span class="active-pulse">🏁 Race In Progress</span>
                    {:else if c.kind === 'TDM' && c.tdm}
                      <span class="active-pulse">{c.tdm.gangLabelA} {c.tdm.scoreA} - {c.tdm.scoreB} {c.tdm.gangLabelB}</span>
                    {:else if c.totalRoutePoints}
                      <span class="progress-text">{c.currentRouteIndex || 0} / {c.totalRoutePoints} Waypoints</span>
                      <div class="mini-progress"><div class="mini-progress-fill" style="width: {Math.min(100, Math.round(((c.currentRouteIndex || 0) / c.totalRoutePoints) * 100))}%"></div></div>
                    {:else}
                      <span class="active-pulse">● En Route</span>
                    {/if}
                  </div>
                {:else if c.scheduledAt}
                  <span class="time-text">{formatScheduled(c.scheduledAt)}</span>
                {:else}
                  <span class="time-muted">Unscheduled</span>
                {/if}
              </td>

              <!-- Registration Capacity -->
              <td class="col-reg">
                <div class="reg-cell">
                  <div class="reg-top">
                    {#if !isPolice && regMode === 'NONE'}
                      <span class="reg-count"><span class="reg-max">Open to everyone</span></span>
                    {:else if !isPolice && regMode === 'GANG'}
                      <span class="reg-count">{c.gangsRegistered || 0}<span class="reg-max"> {(c.gangsRegistered || 0) === 1 ? 'gang' : 'gangs'} registered</span></span>
                    {:else}
                      <span class="reg-count">{regCount}<span class="reg-max"> / {capLimit}</span></span>
                      <span class="reg-pct">{Math.min(100, Math.round((regCount / capLimit) * 100))}%</span>
                    {/if}
                  </div>
                  {#if isPolice || regMode === 'ROSTER'}
                    <div class="mini-progress">
                      <div
                        class="mini-progress-fill"
                        class:warn={regCount >= capLimit}
                        style="width: {Math.min(100, Math.round((regCount / capLimit) * 100))}%"
                      ></div>
                    </div>
                  {/if}
                </div>
              </td>

              <!-- Status -->
              <td class="col-status">
                <StatusBadge
                  status={isUpcoming(c.status) ? ((regMode === 'ROSTER' || isPolice) && regCount >= capLimit ? 'FULL' : 'OPEN') : c.status}
                />
              </td>

              <!-- Action button -->
              <td class="col-action" on:click|stopPropagation>
                <div class="action-cell">
                  {#if !isPolice && canRegisterRoster && isUpcoming(c.status) && regMode !== 'NONE'}
                    <button class="btn btn-sm" class:btn-primary={!(regMode === 'GANG' && isReg)} class:btn-danger={regMode === 'GANG' && isReg} on:click={() => dispatch('register', c)}>
                      <Icon name={regMode === 'GANG' ? (isReg ? 'close' : 'plus') : (isReg ? 'edit' : 'plus')} size={12} />
                      <span>{regMode === 'GANG' ? (isReg ? 'Unregister Gang' : 'Register Gang') : (isReg ? 'Edit Roster' : 'Register')}</span>
                    </button>
                  {:else if !isPolice && isActive(c.status) && c.kind === 'TDM'}
                    <span class="time-muted">Match live</span>
                  {:else if !isPolice && isActive(c.status) && c.gangPvp}
                    {#if c.joined}
                      <button class="btn btn-danger btn-sm" on:click={() => dispatch('leave', c.id)}>
                        Leave
                      </button>
                    {:else}
                      <button class="btn btn-primary btn-sm" on:click={() => dispatch('join', c.id)}>
                        Join
                      </button>
                    {/if}
                  {:else}
                    <button class="btn btn-outline btn-sm" on:click={() => dispatch('viewDetails', c)}>
                      View
                    </button>
                  {/if}
                </div>
              </td>
            </tr>
          {/each}
        {/if}
      </tbody>
    </table>
  </div>
</div>

<style>
  .convoy-table-container {
    display: flex;
    flex-direction: column;
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md, 3px);
    overflow: hidden;
    box-shadow: var(--shadow-soft);
    min-height: 0;
  }

  .table-controls {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    padding: 12px 16px;
    border-bottom: 1px solid var(--tablet-border);
    background: var(--tablet-panel-alt);
    flex-wrap: wrap;
  }

  .tab-filters {
    display: flex;
    align-items: center;
    gap: 6px;
    background: var(--c-panel);
    padding: 4px;
    border-radius: var(--radius-sm, 5px);
    border: 1px solid var(--tablet-border);
  }

  .tab-pill {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 7px 14px;
    border-radius: var(--radius-sm, 5px);
    background: transparent;
    border: none;
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }

  .tab-pill:hover {
    color: var(--text-main);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
  }

  .tab-pill.active {
    background: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #eceef0);
    font-weight: 600;
  }

  .tab-count {
    font-size: var(--fs-meta);
    font-weight: var(--fw-value);
    background: rgba(var(--ltc-4-30-66, 4, 30, 66), 0.45);
    padding: 1px 7px;
    border-radius: 999px;
  }

  /* on the accent-filled active tab the count is outlined in the button's own text colour, so it keeps the button's contrast whatever the fill */
  .tab-pill.active .tab-count {
    background: transparent;
    box-shadow: inset 0 0 0 1px currentColor;
    color: inherit;
  }

  .filter-actions {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }

  .search-box {
    display: flex;
    align-items: center;
    gap: 10px;
    background: var(--c-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 0 12px;
    height: 36px;
    color: var(--text-dim);
    min-width: 240px;
  }

  .search-box:focus-within {
    border-color: var(--accent-primary);
  }

  .search-box input {
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-main);
    font-size: var(--fs-body);
    font-weight: var(--fw-body);
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
    align-items: center;
  }

  .clear-search:hover {
    color: var(--text-main);
  }

  .select-group {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .select-wrap {
    position: relative;
    display: flex;
    align-items: center;
  }

  .select-wrap select {
    appearance: none;
    background: var(--c-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 0 30px 0 12px;
    height: 36px;
    color: var(--text-main);
    font-size: var(--fs-body);
    font-weight: var(--fw-nav);
    cursor: pointer;
    outline: none;
  }

  .select-wrap select option {
    background: var(--tablet-panel);
    color: var(--text-main);
  }

  .select-wrap select:hover,
  .select-wrap select:focus {
    border-color: var(--tablet-border-strong);
  }

  .select-arrow {
    position: absolute;
    right: 10px;
    pointer-events: none;
    color: var(--text-dim);
    display: flex;
  }

  /* Bounded + independently scrollable so a full page of rows (12) never
     forces the whole panel body to scroll past the stat cards/filters just
     to reach the pagination footer below it — only the row list scrolls.
     Sized to comfortably fit ~7 compact rows before it kicks in. */
  .table-responsive {
    overflow-x: auto;
    overflow-y: auto;
    max-height: clamp(360px, 60vh, 680px);
    flex: 1;
    min-height: 0;
    width: 100%;
  }

  /* Excel-style grid: a border on every side of the table plus a vertical
     rule between each column (not just the horizontal row dividers this
     used to have), matching the tablet's own gang-table presentation. */
  .modern-table {
    width: 100%;
    border-collapse: separate;
    border-spacing: 0 5px;
    text-align: left;
    font-size: var(--fs-body);
  }

  /* Real <th> weight, not 12px uppercase monospace shouting — the tablet's
     data-table language is regular-case and readable. Sticky so the column
     headers stay visible while the row list above scrolls. */
  .modern-table th {
    position: sticky;
    top: 0;
    z-index: 1;
    background: var(--c-panel);
    color: var(--text-muted);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    height: 44px;
    padding: 0 var(--tbl-x);
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }

  .modern-table th:last-child {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0;
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }

  /* Individual glass tile per row (border-spacing on .modern-table above
     separates them) — a low-alpha white fill/border here reads as invisible
     against this panel's near-black background, same contrast bug the admin
     tablet's .kpi-card had, so this uses the same flat, clearly-lighter
     solid instead. */
  .table-row {
    background: var(--es-card);
    cursor: pointer;
    transition: background 0.12s ease, box-shadow 0.12s ease;
  }

  .table-row:hover {
    background: var(--es-card-hover);
  }

  .table-row td {
    padding: var(--tbl-td-y) var(--tbl-x);
    height: 52px;
    vertical-align: middle;
    color: var(--lt-e3e6e9, #e3e6e9);
    border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }

  .table-row td:first-child {
    border-top-left-radius: var(--r-panel);
    border-bottom-left-radius: var(--r-panel);
    font-variant-numeric: tabular-nums;
  }

  .table-row td:last-child {
    border-top-right-radius: var(--r-panel);
    border-bottom-right-radius: var(--r-panel);
    font-variant-numeric: tabular-nums;
  }

  /* ─── Priority row ────────────────────────────────────────────────────────
     Replaces the old standalone "Priority Operation" card. A tinted ground +
     a left accent rule marks which event is next up, without adding height or
     competing for width with the columns. */
  .table-row.priority-row {
    background: rgba(var(--gang-rgb, 79, 148, 230), 0.1);
    box-shadow: none;
  }

  .table-row.priority-row:hover {
    background: rgba(var(--gang-rgb, 79, 148, 230), 0.16);
  }

  /* Sits in the gutter to the left of the icon. Positioned absolute inside a
     relative .event-cell so it costs the event column no horizontal space —
     the name and type text keep their full width. */
  .event-cell {
    position: relative;
    display: flex;
    align-items: center;
    gap: 14px;
    padding-left: 6px;
  }

  .priority-dot {
    position: absolute;
    left: -9px;
    top: 50%;
    transform: translateY(-50%);
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--gang, #4f94e6);
    animation: none;
  }

  @keyframes priorityBlink {
    0%, 100% { opacity: 1; transform: translateY(-50%) scale(1); }
    50% { opacity: 0.3; transform: translateY(-50%) scale(0.75); }
  }

  /* Inline marker beside the event-type line — "CONVOY  ·  PRIORITY". */
  .priority-tag {
    margin-left: 7px;
    padding: 1px 6px;
    border-radius: var(--radius-sm, 5px);
    background: var(--btn-soft, var(--c-raised));
    border: 1px solid var(--btn-soft-line, var(--c-line));
    color: var(--text-main);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }

  .event-icon {
    width: 32px;
    height: 32px;
    border-radius: var(--r-tag);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border: 1px solid var(--tablet-border);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-label);
    flex-shrink: 0;
  }

  /* "Active" state marker — a brighter border and colour, no blur/glow. */
  .event-icon.active-glow {
    color: var(--tablet-success);
    border-color: color-mix(in srgb, var(--tablet-success) 55%, transparent);
  }

  .event-text {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .event-name {
    font-weight: 600;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-body);
    letter-spacing: -0.01em;
    line-height: 1.35;
  }

  .event-type {
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    /* Was #eceef0 at 11.5px — dim enough to disappear at a glance. Full
       --text-dim and a step up in size; still clearly secondary to the name
       because it sits below it, not because it's faded. */
    color: var(--text-dim);
    letter-spacing: 0.02em;
    line-height: 1.3;
  }

  .cargo-tag {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    color: var(--lt-ffffff, #fff);
    font-weight: 500;
    letter-spacing: 0.02em;
  }

  .time-text {
    font-size: var(--fs-body);
    font-weight: 500;
    color: var(--text-main);
  }

  .time-muted {
    font-size: var(--fs-body);
    font-weight: 500;
    color: var(--text-dim);
  }

  .active-time {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .progress-text {
    font-size: var(--fs-body);
    color: var(--tablet-success);
    font-weight: var(--fw-value);
  }

  .active-pulse {
    font-size: var(--fs-body);
    color: var(--tablet-success);
    font-weight: 500;
  }

  .reg-cell {
    display: flex;
    flex-direction: column;
    gap: 6px;
    width: 112px;
  }

  .reg-count {
    font-size: var(--fs-body);
    font-variant-numeric: tabular-nums;
    font-weight: var(--fw-value);
    color: var(--text-main);
  }

  .reg-top {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
  }
  .reg-pct {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }
  .reg-cell .mini-progress {
    width: 100%;
  }

  .reg-max {
    color: var(--text-dim);
    font-size: var(--fs-body);
    font-weight: var(--fw-body);
  }

  .mini-progress {
    width: 68px;
    height: 5px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    border-radius: 5px;
    overflow: hidden;
  }

  .mini-progress-fill {
    height: 100%;
    background: var(--accent-primary);
    border-radius: var(--r-panel);
    transition: width 0.3s ease;
    color: var(--on-accent, inherit);
}

  .mini-progress-fill.warn {
    background: var(--tablet-warn);
  }

  .action-cell {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
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

  .btn-sm {
    padding: 7px 14px;
    font-size: var(--fs-body);
  }

  .btn:hover:not(:disabled) {
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

  .btn-primary:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  .btn-danger {
    border-color: #ef4444;
    color: #ffffff;
    background: #ef4444;
  }

  .btn-danger:hover:not(:disabled) {
    background: var(--c-hover);
    border-color: var(--tablet-danger);
  }

  .empty-cell {
    padding: 40px 16px !important;
    text-align: center;
  }

  .empty-wrap {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 9px;
    color: var(--text-dim);
  }

  .empty-title {
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--text-main);
    margin: 0;
  }

  .empty-sub {
    font-size: var(--fs-body);
    color: var(--text-dim);
    margin: 0;
    max-width: 360px;
    line-height: 1.5;
  }

  /* Pagination Bar */
  .table-pagination {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 13px 18px;
    background: var(--tablet-panel-alt);
    border-top: 1px solid var(--tablet-border);
    font-size: var(--fs-body);
    color: var(--text-dim);
    flex-wrap: wrap;
    gap: 10px;
  }

  .pagination-info strong {
    color: var(--text-main);
    font-weight: var(--fw-value);
  }

  .pagination-controls {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .btn-page {
    width: 32px;
    height: 32px;
    border-radius: var(--radius-sm, 5px);
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    color: var(--text-main);
    cursor: pointer;
    transition: border-color 0.12s ease, background 0.12s ease;
  }

  .btn-page:hover:not(:disabled) {
    color: var(--text-main);
    border-color: var(--tablet-border-strong);
    background: var(--tablet-panel-alt);
    border-color: var(--tablet-border-strong);
    background: var(--tablet-panel-alt);
  }

  .btn-page:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .page-numbers {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .btn-page-num {
    min-width: 32px;
    height: 32px;
    padding: 0 8px;
    border-radius: var(--radius-sm, 5px);
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    color: var(--text-main);
    font-size: var(--fs-body);
    font-weight: var(--fw-value);
    cursor: pointer;
    transition: border-color 0.12s ease;
  }

  .btn-page-num:hover {
    color: var(--text-main);
    border-color: var(--tablet-border-strong);
  }

  .btn-page-num.active {
    background: var(--es-accent, #4f94e6);
    border-color: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #eceef0);
    font-weight: 700;
  }

  .page-ellipsis {
    color: var(--text-dim);
    padding: 0 4px;
  }
</style>
