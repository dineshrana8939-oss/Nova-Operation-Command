<script>
  import { defaultPageSize } from '../../adminPrefs.js';
  // ─── Nova Convoy — Participants (two-level view) ───────────────────────────
  // Level 1: scrollable table of every convoy — each row is clickable.
  // Level 2: click a convoy → see its KPI cards + police/gang member list.
  // Back button returns to the convoy list.
  import { onMount } from 'svelte';
  import { peek, keep } from '../ui/viewCache.js';
  import { getConvoys } from '../../api/convoy.js';
  import Icon from '../ui/Icon.svelte';
  import { kindMeta, kindTag, statusTag } from '../ui/badges.js';
  import SearchBox from '../ui/SearchBox.svelte';
  import FilterSelect from '../ui/FilterSelect.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import { STATUS_LABELS } from '../../constants.js';
  import '../tablet-theme.css';

  // ── state ──────────────────────────────────────────────────────────────────
  let convoys   = peek('participants') || [];
  let loading   = !peek('participants');
  let error     = '';

  // null  = list view   |   object = detail view for that convoy
  let selected  = null;
  // 'police' | 'gang' | null
  let category  = null;
  let userPicked = false;

  // ── data helpers ───────────────────────────────────────────────────────────
  function policeList(c) {
    if (!c || c.kind === 'GANG_AIRDROP') return [];
    const list = (c.policeResolved && c.policeResolved.length)
      ? c.policeResolved
      : (c.policeRoster || []);
    return list.map(entry => {
      if (typeof entry === 'string') {
        return { identifier: entry, name: entry };
      }
      const rawName = entry.name;
      const cleanName = (rawName && rawName !== 'undefined' && rawName !== 'Unknown')
        ? rawName
        : (entry.identifier || 'Officer');
      return {
        identifier: entry.identifier || cleanName,
        name: cleanName,
      };
    });
  }

  function gangRows(c) {
    const out = [];
    for (const [gang, members] of Object.entries(c?.rosterResolved || {})) {
      for (const m of members || []) {
        const id = typeof m === 'string' ? m : m.identifier;
        const name = (typeof m === 'object' && m.name && m.name !== 'undefined' && m.name !== 'Unknown') ? m.name : id;
        out.push({ id, name, gang });
      }
    }
    if (!out.length && c?.gangRoster) {
      for (const [gang, ids] of Object.entries(c.gangRoster)) {
        for (const m of ids || []) {
          const id = typeof m === 'string' ? m : m.identifier;
          const name = (typeof m === 'object' && m.name && m.name !== 'undefined' && m.name !== 'Unknown') ? m.name : id;
          out.push({ id, name, gang });
        }
      }
    }
    return out;
  }

  function kindLabel(k) {
    return k === 'GANG_AIRDROP' ? 'Gang Airdrop' : (k === 'HOT_CARGO' ? 'Hot Cargo' : (k === 'GANG_RACE' ? 'Rally Race' : (k === 'TDM' ? 'TDM Match' : (k === 'CONTAINER_WARS' ? 'Container Wars' : (k === 'GANG_TERRITORY' ? 'Territory Auction' : (k === 'CRACKDOWN' ? 'Operation Crackdown' : 'Convoy'))))));
  }

  // One pill style + icon per kind — Container Wars, Hot Cargo, Rally and TDM
  // used to all render as the orange Convoy pill.
  const TYPE_CLASS = { GANG_AIRDROP: 'type-airdrop', HOT_CARGO: 'type-hot', GANG_RACE: 'type-race', TDM: 'type-tdm', CONTAINER_WARS: 'type-cw', GANG_TERRITORY: 'type-territory', CRACKDOWN: 'type-tdm' };
  const TYPE_ICON = { GANG_AIRDROP: 'parachute', HOT_CARGO: 'flame', GANG_RACE: 'flag', TDM: 'flag', CONTAINER_WARS: 'box', GANG_TERRITORY: 'pin', CRACKDOWN: 'shield' };
  const typeClass = (k) => TYPE_CLASS[k] || 'type-convoy';
  const typeIcon = (k) => TYPE_ICON[k] || 'truck';

  // Presentation only: every status gets its own badge tone (tablet-theme.css)
  // and its readable label instead of the raw enum (UNDER_ATTACK → Under Attack).
  function statusBadge(s) {
    const map = {
      DRAFT: 'draft', SCHEDULED: 'scheduled', STARTING: 'starting', ACTIVE: 'active', CHECKPOINT: 'checkpoint',
      UNDER_ATTACK: 'under-attack', DELIVERY: 'delivery', COMPLETED: 'completed', CAPTURED: 'captured',
      FAILED: 'failed', CANCELLED: 'cancelled',
    };
    return `badge badge-${map[s] || 'draft'}`;
  }
  const statusText = (s) => STATUS_LABELS[s] || s;

  // ── data ───────────────────────────────────────────────────────────────────
  async function refresh() {
    if (!peek('participants')) loading = true;
    const res = await getConvoys();
    if (res && res.ok) {
      convoys = (res.convoys || []).filter((c) => c.kind !== 'GANG_AIRDROP');
      keep('participants', convoys);
      error = '';
      if (selected) {
        const fresh = convoys.find(c => c.id === selected.id);
        if (fresh) selected = fresh;
      }
    } else {
      error = (res && res.error) || 'Failed to load events.';
    }
    loading = false;
  }

  onMount(refresh);

  // ── navigation ─────────────────────────────────────────────────────────────
  function openConvoy(c) {
    selected   = c;
    userPicked = false;
    category   = null;
    const p = policeList(c).length;
    const g = gangRows(c).length;
    category = p > 0 ? 'police' : g > 0 ? 'gang' : null;
  }

  function goBack() {
    selected   = null;
    category   = null;
    userPicked = false;
  }

  function chooseCategory(which) {
    category   = which;
    userPicked = true;
  }

  // ── event list: search + picklists + paging ────────────────────────────────
  const EV_KIND_OPTIONS = [
    { value: 'ALL', label: 'All types' },
    { value: 'CONVOY', label: 'Convoy' },
    { value: 'HOT_CARGO', label: 'Hot Cargo' },
    { value: 'GANG_RACE', label: 'Rally Race' },
    { value: 'TDM', label: 'TDM Match' },
    { value: 'CONTAINER_WARS', label: 'Container Wars' },
    { value: 'GANG_TERRITORY', label: 'Territory Auction' },
    { value: 'CRACKDOWN', label: 'Operation Crackdown' },
  ];
  const EV_STATUS_OPTIONS = [
    { value: 'ALL', label: 'All statuses' },
    { value: 'DRAFT', label: 'Draft' },
    { value: 'SCHEDULED', label: 'Scheduled' },
    { value: 'ACTIVE', label: 'Active' },
    { value: 'COMPLETED', label: 'Completed' },
    { value: 'CAPTURED', label: 'Captured' },
  ];
  let evSearch = '';
  let evKind = 'ALL';
  let evStatus = 'ALL';
  let evPage = 1;
  let evSize = defaultPageSize([10, 15, 25, 50]);

  $: filteredConvoys = convoys.filter((c) => {
    const q = evSearch.toLowerCase().trim();
    if (q && !(c.name || '').toLowerCase().includes(q)) return false;
    if (evKind !== 'ALL' && (c.kind || 'CONVOY') !== evKind) return false;
    if (evStatus !== 'ALL' && c.status !== evStatus) return false;
    return true;
  });
  $: evFiltersActive = evSearch.trim() !== '' || evKind !== 'ALL' || evStatus !== 'ALL';
  $: pagedConvoys = filteredConvoys.slice((evPage - 1) * evSize, evPage * evSize);
  const resetEvPage = () => { evPage = 1; };
  $: resetEvPage(evSearch, evKind, evStatus);

  // ── roster lists (one event's police / gang members) ───────────────────────
  let rSearch = '';
  let rGang = 'ALL';
  let rPage = 1;
  let rSize = defaultPageSize([10, 15, 25, 50]);
  const resetRPage = () => { rPage = 1; };
  // A different event or category starts from a clean filter.
  $: resetRosterFilters(selected && selected.id, category);
  function resetRosterFilters() { rSearch = ''; rGang = 'ALL'; rPage = 1; }
  $: resetRPage(rSearch, rGang);

  $: filteredPolice = policeParticipants.filter((p) => !rSearch.trim() || (p.name || '').toLowerCase().includes(rSearch.toLowerCase().trim()));
  $: gangOptions = [{ value: 'ALL', label: 'All gangs' }, ...[...new Set(gangParticipants.map((g) => g.gang))].sort().map((g) => ({ value: g, label: g }))];
  $: filteredGang = gangParticipants.filter((g) => {
    if (rGang !== 'ALL' && g.gang !== rGang) return false;
    const q = rSearch.toLowerCase().trim();
    return !q || (g.name || '').toLowerCase().includes(q);
  });
  $: pagedPolice = filteredPolice.slice((rPage - 1) * rSize, rPage * rSize);
  $: pagedGang = filteredGang.slice((rPage - 1) * rSize, rPage * rSize);

  // ── reactive ───────────────────────────────────────────────────────────────
  $: policeParticipants = policeList(selected);
  $: gangParticipants   = gangRows(selected);
  $: policeTotal        = policeParticipants.length;
  $: gangTotal          = gangParticipants.length;
</script>

<div class="panel view-enter">
  <!-- ── Panel header ──────────────────────────────────────────────────────── -->
  <div class="panel-header">
    <div class="panel-heading">
      {#if selected}
        <span class="panel-title">
          <button class="back-btn" on:click={goBack} title="Back to event list">
            <Icon name="chevronLeft" size={13} />
            <span>Back</span>
          </button>
          <Icon name="person-group" size={14} />
          Participants
          <span class="breadcrumb-sep">/</span>
          <span class="breadcrumb-name">{selected.name}</span>
        </span>
        <span class="panel-subtitle">Pre-registered roster for this event</span>
      {:else}
        <span class="panel-title"><Icon name="person-group" size={14} /> Participants</span>
        <span class="panel-subtitle">Click an event to view its pre-registered police and gang roster</span>
      {/if}
    </div>
    <button class="btn btn-refresh" on:click={refresh}><Icon name="refresh" size={13} /> Refresh</button>
  </div>

  <div class="panel-body">
    {#if error}
      <div class="error" style="margin-bottom:12px">{error}</div>
    {/if}

    <!-- ══════════════════════════════════════════════════════════════════════
         LEVEL 1 — Convoy / event list
    ══════════════════════════════════════════════════════════════════════ -->
    {#if !selected}
      {#if loading}
        <div class="empty-state">Loading events...</div>
      {:else if convoys.length === 0}
        <div class="empty-state">No events found — create an event to get started.</div>
      {:else}
        <div class="pt-toolbar">
          <SearchBox bind:value={evSearch} placeholder="Search event name..." />
          <FilterSelect label="Event type" bind:value={evKind} options={EV_KIND_OPTIONS} />
          <FilterSelect label="Status" bind:value={evStatus} options={EV_STATUS_OPTIONS} minWidth={140} />
          <div class="pt-meta">
            Showing <strong>{filteredConvoys.length}</strong> of <strong>{convoys.length}</strong>
            {#if evFiltersActive}<button type="button" class="pt-reset" on:click={() => { evSearch = ''; evKind = 'ALL'; evStatus = 'ALL'; }}>Clear filters</button>{/if}
          </div>
        </div>
        <TablePager top bind:page={evPage} bind:pageSize={evSize} total={filteredConvoys.length} noun="events" />
        <table class="data-table">
          <thead>
            <tr>
              <!-- shared proportionally (not fixed pixels + one stretchy name column), so the table fills its width evenly -->
              <th style="width: 5%">#</th>
              <th style="width: 34%">Event Name</th>
              <th style="width: 21%">Type</th>
              <th style="width: 14%">Status</th>
              <th class="col-right" style="width: 10%">Police</th>
              <th class="col-right" style="width: 10%">Gangs</th>
              <th style="width: 4%"></th>
            </tr>
          </thead>
          <tbody>
            {#each pagedConvoys as c, i (c.id)}
              {@const pl = policeList(c).length}
              {@const gl = gangRows(c).length}
              <tr class="event-row" on:click={() => openConvoy(c)}>
                <td class="col-idx">{(evPage - 1) * evSize + i + 1}</td>
                <td class="col-name">
                  <span class="event-name">{c.name}</span>
                </td>
                <td>
                  <span class="tag" style={kindTag(c.kind)}>{kindLabel(c.kind)}</span>
                </td>
                <td><span class="tag" style={statusTag(c.status)}>{statusText(c.status)}</span></td>
                <td class="col-right">
                  {#if c.kind !== 'GANG_AIRDROP'}
                    <span class="count-pill count-police">{pl}</span>
                  {:else}
                    <span class="col-na">—</span>
                  {/if}
                </td>
                <td class="col-right">
                  <span class="count-pill count-gang">{gl}</span>
                </td>
                <td class="col-action">
                  <Icon name="chevronRight" size={13} />
                </td>
              </tr>
            {:else}
              <tr><td colspan="7" class="pt-empty">No events match the current filters.</td></tr>
            {/each}
          </tbody>
        </table>
      {/if}

    <!-- ══════════════════════════════════════════════════════════════════════
         LEVEL 2 — Selected event detail
    ══════════════════════════════════════════════════════════════════════ -->
    {:else}
      <!-- KPI cards row -->
      <div class="kpi-row" style="margin-bottom: 20px">
        {#if selected.kind !== 'GANG_AIRDROP'}
          <button
            class="kpi-link"
            class:kpi-active={category === 'police'}
            style="--ca: var(--kpi-police); --cg: var(--kpi-police-glow)"
            on:click={() => chooseCategory('police')}
          >
            <div class="kpi-icon"><Icon name="shield" size={18} /></div>
            <div class="kpi-body">
              <div class="kpi-label-top">POLICE REGISTERED</div>
              <div class="kpi-num">{policeTotal}</div>
              <div class="kpi-sub">Registered Police Participants</div>
            </div>
          </button>
        {/if}

        <button
          class="kpi-link"
          class:kpi-active={category === 'gang'}
          style="--ca: var(--kpi-gang); --cg: var(--kpi-gang-glow)"
          on:click={() => chooseCategory('gang')}
        >
          <div class="kpi-icon"><Icon name="users" size={18} /></div>
          <div class="kpi-body">
            <div class="kpi-label-top">GANGS REGISTERED</div>
            <div class="kpi-num">{gangTotal}</div>
            <div class="kpi-sub">Registered Gang Participants</div>
          </div>
        </button>
      </div>

      <!-- Member table section -->
      <div class="roster-section">
        <div class="section-title-bar">
          <div class="section-title-wrap">
            <span class="section-heading-title">
              {#if category === 'police'}
                <Icon name="shield" size={13} /> Police Participants ({policeTotal})
              {:else if category === 'gang'}
                <Icon name="users" size={13} /> Gang Participants ({gangTotal})
              {:else}
                <Icon name="person-group" size={13} /> Participants
              {/if}
            </span>
            <span class="section-heading-sub">
              {#if category === 'police'}
                Officers pre-registered for this convoy
              {:else if category === 'gang'}
                Gang members pre-registered for this event
              {:else}
                Select a category above to view participants
              {/if}
            </span>
          </div>
        </div>

        {#if category}
          <div class="pt-toolbar pt-toolbar-roster">
            <SearchBox bind:value={rSearch} placeholder="Search participant name..." width={260} />
            {#if category === 'gang'}
              <FilterSelect label="Gang" bind:value={rGang} options={gangOptions} />
            {/if}
          </div>
        {/if}

        {#if category === 'police'}
          {#if policeParticipants.length === 0}
            <div class="empty-roster">No police officers pre-registered for this event.</div>
          {:else}
            <TablePager top bind:page={rPage} bind:pageSize={rSize} total={filteredPolice.length} noun="officers" />
            <div class="roster-scroll">
              <table class="data-table roster-table">
                <thead>
                  <tr>
                    <th class="th-num">#</th>
                    <th class="th-name">Participant Name</th>
                    <th class="th-status">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {#each pagedPolice as p, i (p.identifier || i)}
                    <tr>
                      <td class="td-num">{(rPage - 1) * rSize + i + 1}</td>
                      <td class="td-name">
                        <div class="participant-row-cell">
                          <span class="user-avatar police"><Icon name="shield" size={12} /></span>
                          <span class="user-name">{p.name}</span>
                        </div>
                      </td>
                      <td class="td-status">
                        <span class="status-badge status-police">Registered</span>
                      </td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}

        {:else if category === 'gang'}
          {#if gangParticipants.length === 0}
            <div class="empty-roster">No gang participants pre-registered for this event.</div>
          {:else}
            <TablePager top bind:page={rPage} bind:pageSize={rSize} total={filteredGang.length} noun="participants" />
            <div class="roster-scroll">
              <table class="data-table roster-table">
                <thead>
                  <tr>
                    <th class="th-num">#</th>
                    <th class="th-name">Participant Name</th>
                    <th class="th-gang">Gang</th>
                    <th class="th-status">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {#each pagedGang as g, i (g.id || i)}
                    <tr>
                      <td class="td-num">{(rPage - 1) * rSize + i + 1}</td>
                      <td class="td-name">
                        <div class="participant-row-cell">
                          <span class="user-avatar gang"><Icon name="users" size={12} /></span>
                          <span class="user-name">{g.name}</span>
                        </div>
                      </td>
                      <td class="td-gang">
                        <span class="gang-pill">{g.gang}</span>
                      </td>
                      <td class="td-status">
                        <span class="status-badge status-gang">Registered</span>
                      </td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}

        {:else}
          <div class="empty-roster">Select a category above to view participants.</div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  /* ── Accent tokens ─────────────────────────────────────────────────────────── */
  :root {
    --kpi-police:      var(--accent-primary);
    --kpi-police-glow: rgba(var(--accent-primary-rgb), 0.20);
    --kpi-gang:        #eceef0;
    --kpi-gang-glow:   rgba(255, 255, 255, 0.20);
  }

  .pt-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    gap: 14px;
    margin-bottom: 14px;
  }
  .pt-toolbar-roster { margin-top: 4px; }
  .pt-meta {
    margin-left: auto;
    align-self: center;
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .pt-meta strong { color: var(--lt-ffffff, #fff); }
  .pt-reset {
    background: transparent;
    border: none;
    padding: 0;
    color: var(--accent-primary-light, #66a3eb);
    font-size: var(--fs-small);
    font-weight: 700;
    cursor: pointer;
  }
  .pt-reset:hover { text-decoration: underline; }
  .pt-empty {
    text-align: center;
    padding: 28px 16px !important;
    color: var(--text-dim);
  }

  /* ── Level 1 — event list table ─────────────────────────────────────────── */
  .event-row {
    cursor: pointer;
    transition: background 0.12s ease;
  }
  .event-row:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04) !important;
  }
  .event-row:hover .col-action {
    opacity: 1;
    color: var(--accent-primary-light);
  }

  .col-idx    { color: var(--tablet-text-faint); font-family: var(--font-mono); font-size: var(--fs-body); }
  .col-name   { font-weight: 600; }
  .col-right  { text-align: right !important; }
  .col-action { text-align: right; opacity: 0.3; transition: opacity 0.15s, color 0.15s; color: var(--text-dim); }
  .col-na     { color: var(--tablet-text-faint); }

  .event-name {
    color: var(--text-main);
    font-size: var(--fs-body);
  }

  /* Type pills */
  .type-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .type-convoy  { color: #111111; background: rgb(238, 138, 43); border: 1px solid rgb(238, 138, 43); }
  .type-hot     { color: #111111; background: rgb(224, 72, 159); border: 1px solid rgb(224, 72, 159); }
  .type-race    { color: #111111; background: rgb(34, 199, 214); border: 1px solid rgb(34, 199, 214); }
  .type-tdm     { color: #111111; background: rgb(229, 72, 77); border: 1px solid rgb(229, 72, 77); }
  .type-cw      { color: #111111; background: rgb(82, 210, 74); border: 1px solid rgb(82, 210, 74); }
  .type-territory { color: #111111; background: rgb(196, 94, 224); border: 1px solid rgb(196, 94, 224); }
  .type-airdrop { color: #111111; background: rgb(155, 123, 255); border: 1px solid rgb(155, 123, 255); }

  /* Count pills in the list */
  .count-pill {
    display: inline-block;
    min-width: 28px;
    text-align: center;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    font-family: var(--font-mono);
  }
  .count-police { color: var(--on-accent); background: var(--c-action); border: 1px solid var(--c-action); }
  .count-gang   { color: var(--lt-eceef0, #eceef0); background: rgba(var(--ink-rgb, 255, 255, 255), 0.12); border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.3); }

  /* ── Breadcrumb / back button ──────────────────────────────────────────────── */
  .back-btn {
    background: none;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    padding: 4px 10px;
    gap: 4px;
    font-size: var(--fs-small);
    font-weight: 600;
    letter-spacing: normal;
    text-transform: none;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    transition: border-color 0.12s, color 0.12s;
    margin-right: 4px;
  }
  .back-btn:hover { border-color: var(--accent-primary); color: var(--accent-primary); }
  .breadcrumb-sep  { color: var(--tablet-text-faint); margin: 0 5px; font-weight: 400; }
  .breadcrumb-name { color: var(--accent-primary-light); font-size: var(--fs-emph); font-weight: var(--fw-heading); }

  /* ── KPI cards row ─────────────────────────────────────────────────────────── */
  .kpi-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 16px;
  }

  .kpi-link {
    display: flex;
    align-items: center;
    gap: 14px;
    width: 100%;
    text-align: left;
    cursor: pointer;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-top: 2.5px solid var(--ca, var(--tablet-border));
    border-radius: var(--radius-md);
    padding: 14px 18px;
    transition: border-color 0.15s, box-shadow 0.15s, transform 0.12s;
  }
  .kpi-link:hover {
    border-color: var(--ca);
    transform: translateY(-2px);
    box-shadow: none;
  }
  .kpi-link.kpi-active {
    border-color: var(--ca);
    border-top-color: var(--ca);
    box-shadow: 0 0 0 1px var(--ca) inset;
  }
  .kpi-link.kpi-active .kpi-icon {
    border-color: var(--ca);
    color: var(--ca);
    background: var(--cg);
  }
  .kpi-link.kpi-active .kpi-label-top { color: var(--text-muted);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
  }
  .kpi-link.kpi-active .kpi-num       { color: var(--ca); }

  .kpi-icon {
    width: 42px;
    height: 42px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--tablet-bg);
    border: 2px solid var(--ca, var(--accent-primary));
    border-radius: 999px;
    color: var(--ca, var(--accent-primary));
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
  }
  .kpi-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .kpi-label-top {
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    transition: color 0.15s;
  }
  .kpi-num {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-weight: 600;
    font-size: 28px;
    line-height: 1.1;
    color: var(--text-main);
    transition: color 0.15s;
    font-variant-numeric: tabular-nums;
  }
  .kpi-sub {
    font-size: var(--fs-meta);
    font-weight: 500;
    color: var(--c-text-3);
    margin-top: 2px;
  }

  /* ── Roster section & title bar ────────────────────────────────────────────── */
  .roster-section {
    background: transparent;
  }
  .section-title-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--tablet-border);
  }
  .section-title-wrap {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }
  .section-heading-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
    display: inline-flex;
    align-items: center;
    gap: 7px;
    letter-spacing: 0.01em;
  }
  .section-heading-sub {
    font-size: var(--fs-small);
    color: var(--tablet-text-faint);
  }

  /* ── Roster table styling ─────────────────────────────────────────────────── */
  .roster-scroll {
    max-height: 420px;
    overflow-y: auto;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
  }

  table.roster-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--fs-body);
  }
  table.roster-table th {
    position: sticky;
    top: 0;
    z-index: 2;
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    padding: var(--tbl-th-y) var(--tbl-x);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    white-space: nowrap;
  }
  table.roster-table td {
    padding: var(--tbl-td-y) var(--tbl-x);
    border-bottom: 1px solid var(--c-line-soft);
    color: var(--text-main);
    vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }
  table.roster-table tbody tr:last-child td {
    border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }
  table.roster-table tbody tr {
    cursor: default;
    transition: background 0.1s ease;
  }
  table.roster-table tbody tr:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.025);
  }

  /* Column alignment and widths */
  .th-num    { width: 50px; text-align: left !important; }
  .th-name   { text-align: left !important; }
  .th-gang   { width: 180px; text-align: left !important; }
  .th-status { width: 130px; text-align: right !important; }

  .td-num    { width: 50px; color: var(--tablet-text-faint); font-family: var(--font-mono); font-size: var(--fs-small); text-align: left; }
  .td-name   { text-align: left; }
  .td-gang   { width: 180px; text-align: left; }
  .td-status { width: 130px; text-align: right; }

  /* Participant cell with avatar */
  .participant-row-cell {
    display: inline-flex;
    align-items: center;
    gap: 10px;
  }
  .user-avatar {
    width: 26px;
    height: 26px;
    border-radius: 999px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .user-avatar.police {
    background: var(--c-hover);
    color: var(--accent-primary);
    border: 1px solid var(--accent-primary);
  }
  .user-avatar.gang {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.15);
    color: var(--lt-eceef0, #eceef0);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.35);
  }
  .user-name {
    font-size: var(--fs-body);
    font-weight: 500;
    color: var(--text-main);
  }

  /* Gang pill badge */
  .gang-pill {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-eceef0, #eceef0);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.35);
  }

  /* Status badges */
  .status-badge {
    display: inline-block;
    padding: 3px 11px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }
  .status-police {
    color: var(--accent-primary);
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
  }
  .status-gang {
    color: var(--lt-eceef0, #eceef0);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.14);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.35);
  }

  .empty-roster {
    padding: 44px 20px;
    text-align: center;
    color: var(--tablet-text-faint);
    font-size: var(--fs-body);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
  }
</style>
