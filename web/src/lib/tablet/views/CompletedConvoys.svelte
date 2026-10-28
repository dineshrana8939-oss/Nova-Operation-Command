<script>
  import { defaultPageSize } from '../../adminPrefs.js';
  import { perms } from '../../perms.js';
  import { onMount, createEventDispatcher } from 'svelte';
  import { peek, keep } from '../ui/viewCache.js';
  import { getConvoyHistory, getConvoyEvents, reuseConvoy, deleteConvoyHistory, clearConvoyHistory } from '../../api/convoy.js';
  import { getGangs } from '../../api/gang.js';
  import { STATUS_LABELS } from '../../constants.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import GangLogo from '../ui/GangLogo.svelte';
  import AuditReportModal from '../ui/AuditReportModal.svelte';
  import { kindMeta, kindTag, statusTag } from '../ui/badges.js';
  import { downloadReportPdf } from '../../util/reportPdf.js';
  import TablePager from '../ui/TablePager.svelte';
  import { bootstrap } from '../../stores.js';
  import '../tablet-theme.css';

  const dispatch = createEventDispatcher();

  let history = peek('history')?.history || [];
  let loading = !peek('history');
  let gangByName = peek('history')?.gangByName || {};
  let error = '';
  let busy = {};
  let viewingReport = null;
  let pdfBusyId = null;
  let pdfNote = null;   // { ok, message } after a PDF download
  async function savePdf(h) {
    if (pdfBusyId) return;
    pdfBusyId = h.id; pdfNote = null;
    pdfNote = await downloadReportPdf(h.id);
    pdfBusyId = null;
  }

  // Per-row event log (truck/airdrop lockpick successes, who captured it) —
  // fetched on demand per convoy, not bundled into the history payload,
  // since most rows never get expanded.
  let expandedId = null;
  let events = [];
  let eventsLoading = false;

  const EVENT_LABELS = {
    TRUCK_LOOTED: 'Truck Looted',
    AIRDROP_LOOTED: 'Airdrop Looted',
    CONVOY_CAPTURED: 'Convoy Captured',
  };
  // Mirrors ConvoyManager.reuse's own REUSABLE_STATUSES server-side — kept
  // in sync manually since this is just for disabling/relabeling the button
  // ahead of the click, the server is still the one actually enforcing it.
  const REUSABLE_STATUSES = ['CANCELLED', 'COMPLETED', 'CAPTURED', 'FAILED'];

  async function refresh() {
    if (!peek('history')) loading = true;
    const [historyRes, gangsRes] = await Promise.all([getConvoyHistory(300), getGangs()]);
    history = historyRes && historyRes.ok ? historyRes.history : [];
    gangByName = {};
    if (gangsRes && gangsRes.ok) {
      for (const g of gangsRes.gangs) gangByName[g.name] = g;
    }
    if (historyRes && historyRes.ok) keep('history', { history, gangByName });
    loading = false;
  }

  async function toggleEvents(h) {
    if (expandedId === h.id) { expandedId = null; return; }
    expandedId = h.id;
    events = [];
    if (!h.convoy_definition_id) return;
    eventsLoading = true;
    const res = await getConvoyEvents(h.convoy_definition_id);
    events = res && res.ok ? res.events : [];
    eventsLoading = false;
  }

  function badgeClass(status) {
    return `badge badge-${(status || '').toLowerCase().replace('_', '-')}`;
  }

  // ── what each row says about THAT kind of event (all read from the saved report, so it matches the Report button) ──
  // The result line is built by the server when the event ends; rows saved before that existed get one from their columns.
  function resultLine(h) {
    const line = h.summary_line;   // pulled out of the saved report by the server; the full report is only loaded when a row is opened
    if (line) return line;
    switch (h.kind) {
      case 'GANG_AIRDROP': return '—';
      case 'HOT_CARGO': return `${h.checkpoints_completed ?? 0} of ${h.truck_count ?? 0} trucks delivered · ${h.destroyed_trucks ?? 0} destroyed`;
      case 'GANG_RACE': return `${h.checkpoints_completed ?? 0} checkpoints`;
      case 'TDM': case 'CONTAINER_WARS': case 'GANG_TERRITORY': case 'CRACKDOWN': return h.reward_summary || '—';
      default: return `${h.truck_count ?? 0} trucks · ${h.destroyed_trucks ?? 0} destroyed · ${h.checkpoints_completed ?? 0} checkpoints`;
    }
  }

  // Who won, in words: the winning gang (with its logo, handled in the row) or the report's own winner text.
  function winnerText(h) {
    const w = h.report_winner;
    if (!w || /^none\b/i.test(w)) return '';
    return w;
  }

  // What the run really paid (the report's summary), falling back to the stored column for old rows.
  function rewardText(h) {
    const r = h.report_rewards || h.reward_summary;
    return r && r !== 'None' ? r : '';
  }

  function playersText(h) {
    const parts = [];
    if (h.kind === 'CONVOY' && h.police_participants > 0) parts.push(`${h.police_participants} police`);
    const noun = h.kind === 'GANG_RACE' ? 'racers' : h.kind === 'TDM' ? 'players' : 'gang';
    if (h.gang_participants > 0) parts.push(`${h.gang_participants} ${noun}`);
    return parts.length ? parts.join(' · ') : '—';
  }

  function formatDuration(seconds) {
    if (!seconds) return '—';
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}m ${s}s`;
  }

  function formatTimestamp(ts) {
    if (!ts) return '—';
    const d = new Date(ts);
    return isNaN(d) ? String(ts) : d.toLocaleString();
  }

  // Resets the SAME convoy definition back to Draft (same trucks/route/
  // settings) and opens it directly in the editor — the point of doing this
  // from History specifically is to tweak the route/whatever slightly based
  // on how the last run went before starting it again, not just blindly
  // rerunning it as-is.
  async function editAndReuse(h) {
    if (!h.convoy_definition_id) return;
    error = '';
    const ok = await confirmAction(
      `Reset "${h.name}" back to a draft (same trucks/route/settings) and open it for editing?`,
      { title: 'Edit & Reuse Event' }
    );
    if (!ok) return;
    busy = { ...busy, [h.id]: true };
    const res = await reuseConvoy(h.convoy_definition_id);
    busy = { ...busy, [h.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to reuse event.'; return; }
    dispatch('edit', h.convoy_definition_id);
  }

  // Only removes this one past-run record — the underlying convoy
  // definition (and any OTHER history rows from replaying it) are untouched.
  async function deleteHistory(h) {
    error = '';
    const ok = await confirmAction(
      `Permanently delete the history record for "${h.name}" (${formatDuration(h.duration)}, ${STATUS_LABELS[h.outcome] || h.outcome})? This cannot be undone.`,
      { title: 'Delete History Record', danger: true }
    );
    if (!ok) return;
    busy = { ...busy, [h.id]: true };
    const res = await deleteConvoyHistory(h.id);
    busy = { ...busy, [h.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to delete history record.'; return; }
    history = history.filter((row) => row.id !== h.id);
    if (expandedId === h.id) expandedId = null;
  }

  // Wipes every past-run record at once — the underlying convoy definitions
  // (and any events log tied to them) are untouched, only this table empties.
  let clearingAll = false;
  async function clearAll() {
    error = '';
    const ok = await confirmAction(
      `Permanently delete all ${history.length} history record${history.length === 1 ? '' : 's'}? This cannot be undone.`,
      { title: 'Clear All History', danger: true }
    );
    if (!ok) return;
    clearingAll = true;
    const res = await clearConvoyHistory();
    clearingAll = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to clear history.'; return; }
    history = [];
    expandedId = null;
  }

  // ── Search + picklist filters ─────────────────────────────────────────────
  // Name search plus two dropdowns (event type, outcome). All three combine.
  const KIND_OPTIONS = [
    { id: 'CONVOY', label: 'Convoy' },
    { id: 'GANG_AIRDROP', label: 'Airdrop' },
    { id: 'HOT_CARGO', label: 'Hot Cargo' },
    { id: 'GANG_RACE', label: 'Gang Rally' },
    { id: 'TDM', label: 'TDM' },
    { id: 'CONTAINER_WARS', label: 'Container Wars' },
    { id: 'GANG_TERRITORY', label: 'Territory Auction / War' },
    { id: 'CRACKDOWN', label: 'Operation Crackdown' },
  ];
  const OUTCOME_OPTIONS = ['COMPLETED', 'CAPTURED', 'FAILED', 'CANCELLED'];

  let searchQuery = '';
  let kindFilter = 'ALL';
  let outcomeFilter = 'ALL';

  // Rows from before 'kind' was recorded are plain convoys.
  const kindOf = (h) => h.kind || 'CONVOY';

  $: filteredHistory = history.filter((h) => {
    const q = searchQuery.toLowerCase().trim();
    if (q && !(h.name || '').toLowerCase().includes(q)) return false;
    if (kindFilter !== 'ALL' && kindOf(h) !== kindFilter) return false;
    if (outcomeFilter !== 'ALL' && h.outcome !== outcomeFilter) return false;
    return true;
  });
  let hPage = 1;
  let hSize = defaultPageSize([5, 10, 15, 25, 50]);
  $: pagedHistory = filteredHistory.slice((hPage - 1) * hSize, hPage * hSize);
  // back to page 1 whenever the filters change (only the arguments are tracked)
  const resetHPage = () => { hPage = 1; };
  $: resetHPage(searchQuery, kindFilter, outcomeFilter);
  $: filtersActive = searchQuery.trim() !== '' || kindFilter !== 'ALL' || outcomeFilter !== 'ALL';

  function clearFilters() {
    searchQuery = '';
    kindFilter = 'ALL';
    outcomeFilter = 'ALL';
  }

  onMount(refresh);
</script>

<style>
  .table-scroll {
    overflow-x: auto;
  }
  .hist-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    gap: 14px;
    margin-bottom: 14px;
  }
  .hist-search {
    display: flex;
    align-items: center;
    gap: 10px;
    height: 36px;
    min-width: 280px;
    padding: 0 12px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
  }
  .hist-search:focus-within { border-color: var(--accent-primary); }
  .hist-search input {
    flex: 1;
    min-width: 0;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-main, #fff);
    font-size: var(--fs-body);
  }
  .hist-search input::placeholder { color: var(--text-placeholder); opacity: 1; }
  .hist-clear {
    display: flex;
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
  }
  .hist-clear:hover { color: var(--lt-ffffff, #fff); }
  .hist-select {
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim);
  }
  .hist-select select {
    height: 36px;
    min-width: 160px;
    padding: 0 12px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-main, #fff);
    font-size: var(--fs-body);
    font-weight: 600;
    letter-spacing: 0;
    text-transform: none;
    cursor: pointer;
    outline: none;
  }
  .hist-select select:hover,
  .hist-select select:focus { border-color: var(--tablet-border-strong, #363b43); }
  .hist-meta {
    margin-left: auto;
    align-self: center;
    font-size: var(--fs-small);
    color: var(--text-dim);
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .hist-meta strong { color: var(--lt-ffffff, #fff); }
  .hist-reset {
    background: transparent;
    border: none;
    padding: 0;
    color: var(--accent-primary-light, #66a3eb);
    font-size: var(--fs-small);
    font-weight: 700;
    cursor: pointer;
  }
  .hist-reset:hover { text-decoration: underline; }
  .hist-empty {
    text-align: center;
    padding: 28px 16px !important;
    color: var(--text-dim);
  }
  /* Slightly tighter than the shared data-table default (14px) — this table
     has more columns than most, and the actions column needs the room now
     that it has text labels again instead of icon-only buttons. */
  .table-scroll table.data-table th,
  .table-scroll table.data-table td {
    padding: var(--tbl-td-y) var(--tbl-x);
  }
  .gang-cell {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    white-space: nowrap;
  }
  .col-name {
    white-space: nowrap;
    min-width: 140px;
  }
  .cell-wrap { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; max-width: 210px; line-height: 1.35; }
  .cell-clip { display: inline-block; max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom; }
  .pdf-note { margin-bottom: 8px; padding: 8px 12px; border-radius: 8px; font-size: var(--fs-small); color: var(--lt-7ee2b2, #7ee2b2); background: var(--c-raised); border: 1px solid var(--c-line);
    border-left: 3px solid rgb(70, 201, 139);}
  .pdf-note.bad { color: var(--lt-ffb4ad, #ffb4ad); background: var(--c-raised); border-color: var(--c-line);
    border-left: 3px solid rgb(255, 93, 80);}
  .nowrap {
    white-space: nowrap;
  }
  /* Numeric columns (Duration → Gang count) right-aligned so values compare
     down the column; header follows its values. Column order is fixed in the
     markup above, so positional selectors are safe here. */
  .data-table :global(th.col-dur),
  .data-table :global(td.col-dur) {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
  /* the event name and its kind badge stay on ONE line (a long name is cut with an ellipsis, the full name is on hover) */
  .data-table :global(td.col-name) {
    white-space: nowrap;
    min-width: 180px;
  }
  .hname { display: inline-block; max-width: 280px; overflow: hidden; text-overflow: ellipsis; vertical-align: bottom; margin-right: 6px; }
  /* the result line also stays on one line; hover shows all of it */
  /* the result line wraps to two lines (it used to be cut with an ellipsis, which also pushed the action buttons out of view on a small screen) */
  .cell-result { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; white-space: normal; line-height: 1.3; }
  .row-actions {
    display: flex;
    gap: 5px;
    flex-wrap: nowrap;
    justify-content: flex-end;
  }
  .row-btn {
    height: 28px;
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 0 8px;
    white-space: nowrap;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
    transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease;
  }
  .row-btn:hover:not(:disabled) {
    color: var(--text-main);
    border-color: var(--accent-primary);
    background: var(--c-hover);
  }
  .row-btn.edit {
    color: var(--lt-46c98b, #46c98b);
    background: rgba(70, 201, 139, 0.14);
    border-color: rgba(70, 201, 139, 0.5);
  }
  .row-btn.edit:hover:not(:disabled) {
    color: var(--lt-ffffff, #ffffff);
    background: rgba(70, 201, 139, 0.28);
    border-color: #46c98b;
  }
  .row-btn.primary {
    color: var(--accent-primary-light);
    border-color: var(--accent-primary);
  }
  .row-btn.primary:hover:not(:disabled) {
    background: var(--c-hover);
  }
  .row-btn.danger {
    color: var(--tablet-danger);
    border-color: rgba(var(--red-rgb), 0.5);
  }
  .row-btn.danger:hover:not(:disabled) {
    background: var(--c-hover);
    border-color: var(--tablet-danger);
  }
  .row-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }
  .events-row td {
    padding: var(--tbl-td-y) var(--tbl-x);
    background: var(--tablet-panel-alt);
    font-variant-numeric: tabular-nums;
  }
  .events-empty {
    color: var(--tablet-text-faint);
    font-size: var(--fs-body);
  }
  .events-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .event-item {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: var(--fs-body);
    color: var(--text-main);
    padding: 6px 0;
    border-bottom: 1px solid var(--tablet-border);
  }
  .event-item:last-child {
    border-bottom: none;
  }
  .event-type {
    font-weight: 600;
    color: var(--lt-eceef0, #eceef0);
    min-width: 120px;
  }
  .event-gang {
    color: var(--text-main);
    font-weight: 600;
  }
  .event-detail {
    color: var(--text-dim);
    flex: 1;
  }
  .event-time {
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    color: var(--tablet-text-faint);
  }
  .kind-badge {
    display: inline-block;
    margin-left: 6px;
    padding: 1px 7px;
    border-radius: 999px;
    /* no modifier = Gang Airdrop (violet, eventThemes airdrop) */
    background: rgb(155, 123, 255);
    border: 1px solid rgb(155, 123, 255);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }
  .kind-badge-hot {
    background: rgb(224, 72, 159);
    border-color: rgb(224, 72, 159);
    color: #111111;
  }
  .kind-badge-tdm {
    background: rgb(229, 72, 77);
    border-color: rgb(229, 72, 77);
    color: #111111;
  }
  .kind-badge-convoy {
    background: rgb(238, 138, 43);
    border-color: rgb(238, 138, 43);
    color: #111111;
  }
  .kind-badge-race {
    background: rgb(34, 199, 214);
    border-color: rgb(34, 199, 214);
    color: #111111;
  }
  .kind-badge-territory {
    background: rgb(196, 94, 224);
    border-color: rgb(196, 94, 224);
    color: #111111;
  }
  .kind-badge-rivals {
    background: rgb(91, 123, 255);
    border-color: rgb(91, 123, 255);
    color: #111111;
  }
  .kind-badge-cw {
    background: rgb(82, 210, 74);
    border-color: rgb(82, 210, 74);
    color: #111111;
  }
  .data-table td.col-name {
    font-weight: 600;
  }
</style>

<div class="panel">
  <div class="panel-header">
    <span class="panel-title"><Icon name="history" size={14} /> Event History</span>
    <div style="display:flex; gap:8px;">
      <button class="btn btn-refresh" on:click={refresh}><Icon name="refresh" size={13} /> Refresh</button>
      {#if $perms['completed.manage']}
        <button class="btn btn-danger" disabled={loading || clearingAll || history.length === 0} on:click={clearAll}>
          <Icon name="trash" size={13} /> Clear All
        </button>
      {/if}
    </div>
  </div>
  <div class="panel-body">
    {#if error}<div class="error" style="margin-bottom:10px">{error}</div>{/if}
    {#if loading}
      <div class="empty-state">Loading...</div>
    {:else if history.length === 0}
      <div class="empty-state">No events have finished yet.</div>
    {:else}
      <div class="hist-toolbar">
        <div class="hist-search">
          <Icon name="search" size={13} />
          <input type="text" placeholder="Search event name..." bind:value={searchQuery} />
          {#if searchQuery}
            <button class="hist-clear" on:click={() => (searchQuery = '')} aria-label="Clear search"><Icon name="close" size={12} /></button>
          {/if}
        </div>
        <label class="hist-select">
          <span>Event type</span>
          <select bind:value={kindFilter}>
            <option value="ALL">All types</option>
            {#each KIND_OPTIONS as k}<option value={k.id}>{k.label}</option>{/each}
          </select>
        </label>
        <label class="hist-select">
          <span>Outcome</span>
          <select bind:value={outcomeFilter}>
            <option value="ALL">All outcomes</option>
            {#each OUTCOME_OPTIONS as o}<option value={o}>{STATUS_LABELS[o] || o}</option>{/each}
          </select>
        </label>
        <div class="hist-meta">
          {#if filtersActive}<button class="hist-reset" on:click={clearFilters}>Clear filters</button>{/if}
        </div>
      </div>
      {#if pdfNote}<div class="pdf-note" class:bad={!pdfNote.ok}>{pdfNote.message}</div>{/if}
      <TablePager top bind:page={hPage} bind:pageSize={hSize} total={filteredHistory.length} noun="events" sizes={[5, 10, 15, 25, 50]} />
      <div class="table-scroll">
      <table class="data-table">
        <thead>
          <tr>
            <th class="col-name">Event Name</th><th class="col-type">Type</th><th class="col-outcome">Outcome</th><th>Winner</th><th class="col-result">Result</th><th class="col-dur">Duration</th><th class="col-act">Actions</th>
          </tr>
        </thead>
        <tbody>
          {#each pagedHistory as h (h.id)}
            <!-- reuse: finished, can be reset to a draft · open: already back in Manage Events as a draft/scheduled event, so open it
                 · running: it is live right now · gone: nothing behind this row to reuse (deleted event, territory auction / war) -->
            {@const reuseState = !h.convoy_definition_id ? 'gone'
              : REUSABLE_STATUSES.includes(h.currentStatus) ? 'reuse'
              : (h.currentStatus === 'DRAFT' || h.currentStatus === 'SCHEDULED') ? 'open'
              : h.currentStatus ? 'running' : 'gone'}
            <tr>
              <td class="col-name">
                <span class="hname" title={h.name}>{h.name}</span>
              </td>
              <td class="col-type">
                {#if h.kind === 'GANG_TERRITORY' && (h.name || '').startsWith('Territory War')}
                  <span class="tag" style={kindTag(h.kind, '#5b7bff')}>Territory War</span>
                {:else if h.kind === 'GANG_TERRITORY'}
                  <span class="tag" style={kindTag(h.kind)}>Territory Auction</span>
                {:else}
                  <span class="tag" style={kindTag(h.kind)}>{kindMeta(h.kind).label}</span>
                {/if}
              </td>
              <td class="col-outcome"><span class="tag" style={statusTag(h.outcome)}>{STATUS_LABELS[h.outcome] || h.outcome}</span></td>
              <td>
                {#if h.winning_gang && gangByName[h.winning_gang]}
                  <span class="gang-cell"><GangLogo logo={gangByName[h.winning_gang].logo} label={gangByName[h.winning_gang].label} accentColor={gangByName[h.winning_gang].accentColor} size={22} />{gangByName[h.winning_gang].label}</span>
                {:else if h.winning_gang}
                  {h.winning_gang}
                {:else if winnerText(h)}
                  <span class="cell-clip" title={winnerText(h)}>{winnerText(h)}</span>
                {:else}
                  —
                {/if}
              </td>
              <td><span class="cell-result" title={resultLine(h)}>{resultLine(h)}</span></td>
              <td class="nowrap col-dur">{formatDuration(h.duration)}</td>
              <td><div class="row-actions">
                <button class="row-btn" on:click={() => viewingReport = h} title="View After-Action Audit Report">
                  <Icon name="fileText" size={12} /> Report
                </button>
                <button class="row-btn" disabled={pdfBusyId === h.id} on:click={() => savePdf(h)} title="Download this report as a PDF">
                  <Icon name="download" size={12} /> PDF
                </button>
                <button class="row-btn" on:click={() => toggleEvents(h)}>
                  <Icon name={expandedId === h.id ? 'chevronUp' : 'chevronDown'} size={12} /> Events
                </button>
                <button
                  class="row-btn edit"
                  disabled={reuseState === 'gone' || reuseState === 'running' || busy[h.id]}
                  title={reuseState === 'gone'
                    ? (h.kind === 'GANG_TERRITORY' ? 'Territory auctions and wars are not events you can reuse' : 'The original event was deleted, so there is nothing to reuse')
                    : reuseState === 'running'
                      ? `This event is running right now (${STATUS_LABELS[h.currentStatus] || h.currentStatus}) — reuse it once it has finished`
                      : reuseState === 'open'
                        ? `Already reset since this run — it is "${STATUS_LABELS[h.currentStatus] || h.currentStatus}" in Manage Events. Open it in the editor.`
                        : 'Reset to Draft with the same trucks/route/settings, then open it to tweak'}
                  on:click={() => (reuseState === 'open' ? dispatch('edit', h.convoy_definition_id) : editAndReuse(h))}
                ><Icon name="edit" size={12} /> {reuseState === 'open' ? 'Open' : reuseState === 'running' ? 'Running' : reuseState === 'gone' ? 'Unavailable' : 'Reuse'}</button>
                {#if $perms['completed.delete']}
                  <button
                    class="row-btn danger"
                    disabled={busy[h.id]}
                    title="Permanently delete this history record"
                    on:click={() => deleteHistory(h)}
                  ><Icon name="trash" size={12} /> Delete</button>
                {/if}
              </div></td>
            </tr>
            {#if expandedId === h.id}
              <tr class="events-row">
                <td colspan="7">
                  {#if eventsLoading}
                    <span class="events-empty">Loading...</span>
                  {:else if events.length === 0}
                    <span class="events-empty">No lockpick/capture events recorded for this run — either nothing was looted, or it finished before this log existed.</span>
                  {:else}
                    <div class="events-list">
                      {#each events as e (e.id)}
                        <div class="event-item">
                          <span class="event-type">{EVENT_LABELS[e.event_type] || e.event_type}</span>
                          <span class="event-gang">{e.gang_label || e.gang_name || '—'}</span>
                          <span class="event-detail">{e.detail || ''}{e.player_name ? ` — ${e.player_name}` : ''}</span>
                          <span class="event-time">{formatTimestamp(e.created_at)}</span>
                        </div>
                      {/each}
                    </div>
                  {/if}
                </td>
              </tr>
            {/if}
          {:else}
            <tr><td colspan="7" class="hist-empty">No events match the current filters.</td></tr>
          {/each}
        </tbody>
      </table>
      </div>
    {/if}
  </div>
</div>

{#if viewingReport}
  <AuditReportModal historyItem={viewingReport} on:close={() => viewingReport = null} />
{/if}
