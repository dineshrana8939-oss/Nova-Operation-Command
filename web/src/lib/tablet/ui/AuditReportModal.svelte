<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import { getReportPdf } from '../../api/convoy.js';
  import { downloadReportPdf, resendReportToDiscord } from '../../util/reportPdf.js';
  import { bootstrap } from '../../stores.js';
  import { STATUS_LABELS } from '../../constants.js';
  import Icon from './Icon.svelte';
  import '../tablet-theme.css';

  export let historyItem = null;

  const dispatch = createEventDispatcher();

  let loadingReport = false;
  let reportData = null;
  let pdfBusy = false;
  let pdfNote = null;   // { ok, message } after a PDF / Discord action

  $: if (historyItem) {
    reportData = historyItem.reportData || null;
  }

  $: opName = ($bootstrap?.branding?.operationName) || 'Nova Convoy';
  // TDM and Container Wars reports carry their own wording + column headings
  // (server/modules/report_builder.lua); the other kinds leave this null and
  // use the Convoy / Airdrop / Hot Cargo / Rally text below.
  $: L = reportData?.labels || null;
  $: docTitle = L?.docTitle
    ? `${opName} -- ${L.docTitle}`.toUpperCase()
    : historyItem?.kind === 'GANG_AIRDROP'
    ? `${opName} -- GANG AIRDROP OPERATION REPORT`.toUpperCase()
    : historyItem?.kind === 'HOT_CARGO'
    ? `${opName} -- HOT CARGO OPERATION REPORT`.toUpperCase()
    : historyItem?.kind === 'GANG_RACE'
    ? `${opName} -- GANG RALLY / STREET RACE REPORT`.toUpperCase()
    : ($bootstrap?.branding?.pdfTitle || `${opName} -- AFTER-ACTION REPORT`).replace('%s', opName.toUpperCase());

  // Mirrors pdf_generator.lua's own outcome-label branching exactly, so the
  // tablet's on-screen report and the downloadable PDF never disagree about
  // what happened — this used to only special-case GANG_AIRDROP, so a
  // completed race showed the same "DELIVERED" badge the PDF used to.
  $: outcomeBadgeLabel = (() => {
    const k = historyItem?.kind;
    const o = historyItem?.outcome;
    if (L?.outcomeLabel) return L.outcomeLabel;
    if (o === 'COMPLETED') {
      if (k === 'GANG_AIRDROP') return 'COMPLETED';
      if (k === 'GANG_RACE') return 'RACE WON';
      return 'DELIVERED';
    }
    if (o === 'CAPTURED') return k === 'GANG_AIRDROP' ? 'LOOTED' : 'CAPTURED';
    if (o === 'FAILED') {
      if (k === 'GANG_AIRDROP') return 'EXPIRED';
      if (k === 'HOT_CARGO') return 'UNDELIVERED';
      if (k === 'GANG_RACE') return 'NO FINISHERS';
      return 'FAILED';
    }
    return o || 'CANCELLED';
  })();
  // Both AIRDROP and HOT_CARGO are open, gang-vs-gang events with no single
  // "official dispatch" — the old code only ever gave AIRDROP that framing
  // and let HOT_CARGO fall through to the CONVOY-only "Police Escort" /
  // "Official Dispatch" language, which is meaningless for it (Hot Cargo
  // has no police-escort role at all).
  $: isOpenGangEvent = historyItem?.kind === 'GANG_AIRDROP' || historyItem?.kind === 'HOT_CARGO';

  const KIND_NAMES = {
    CONVOY: 'Convoy', GANG_AIRDROP: 'Gang Airdrop', HOT_CARGO: 'Hot Cargo',
    GANG_RACE: 'Gang Rally', TDM: 'Team Deathmatch', CONTAINER_WARS: 'Container Wars', GANG_TERRITORY: 'Gang Territory', CRACKDOWN: 'Operation Crackdown',
  };
  const str = (v) => (typeof v === 'string' && v.trim() !== '' ? v : null);

  // "At a glance" facts — built from the history row itself so they are there even when
  // the saved report body is missing or still loading; the report data only refines them.
  $: summary = (() => {
    const h = historyItem || {};
    const rd = reportData || {};
    const k = h.kind || rd.kind || 'CONVOY';
    const rewards = str(rd.rewards) || str(h.reward_summary);
    const list = [
      { label: 'Event Type', value: KIND_NAMES[k] || k },
      { label: 'Started By', value: str(rd.startedByName) || str(h.created_by) || 'System / Dispatch' },
      { label: 'Started', value: str(rd.startTimeStr) || formatTimestamp(h.started_at) },
      { label: 'Ended', value: str(rd.endTimeStr) || formatTimestamp(h.ended_at) },
      { label: 'Duration', value: formatDuration(h.duration || rd.durationSeconds) },
      { label: 'Result', value: STATUS_LABELS[h.outcome] || h.outcome || '—' },
    ];
    if (rd.forcedByName) list.push({ label: 'Force-Ended By', value: rd.forcedByName });
    list.push({ label: 'Winner', value: str(rd.winner) || str(h.winning_gang) || 'None' });
    // one plain sentence of how THIS kind of event went, written by the server when it ended
    if (str(rd.summaryLine)) list.push({ label: 'What happened', value: rd.summaryLine, wide: true });
    const f = rd.fleet || {};
    const police = rd.roster?.policeCount ?? h.police_participants ?? 0;
    const gangs = rd.roster?.gangCount ?? h.gang_participants ?? 0;
    if (k === 'CONVOY') {
      list.push({ label: 'Trucks', value: `${f.total ?? h.truck_count ?? 0} total · ${f.delivered || 0} delivered · ${f.captured || 0} captured · ${f.destroyed ?? h.destroyed_trucks ?? 0} destroyed` });
      list.push({ label: 'Checkpoints', value: String(h.checkpoints_completed || 0) });
      list.push({ label: 'Participants', value: `${police} police, ${gangs} gang members` });
    } else if (k === 'HOT_CARGO') {
      list.push({ label: 'Vehicles', value: `${f.delivered || 0} delivered of ${f.total || h.truck_count || 0} · ${f.disabled || 0} disabled · ${f.destroyed || 0} destroyed · ${f.hijacked || 0} hijacked` });
      list.push({ label: 'Participants', value: `${gangs} gang members` });
    } else if (k === 'GANG_AIRDROP') {
      list.push({ label: 'Drop Zones', value: `${rd.airdropCaptures?.length || 0} claimed of ${f.total || h.truck_count || 0}` });
      list.push({ label: 'Participants', value: `${gangs} gang members` });
    } else if (k === 'GANG_RACE') {
      list.push({ label: 'Racers', value: String(gangs) });
    } else if (k === 'TDM') {
      list.push({ label: 'Players', value: String(rd.roster?.gangCount ?? h.gang_participants ?? 0) });
    } else if (k === 'CONTAINER_WARS') {
      list.push({ label: 'Lots Sold', value: `${rd.fleet?.delivered || 0} of ${rd.fleet?.total || 0}` });
      list.push({ label: 'Bidding Gangs', value: String(rd.roster?.gangCount ?? h.gang_participants ?? 0) });
    } else if (k === 'CRACKDOWN') {
      list.push({ label: 'Fighters', value: `${rd.roster?.policeCount ?? h.police_participants ?? 0} police · ${rd.roster?.gangCount ?? h.gang_participants ?? 0} gang members` });
    } else if (k === 'GANG_TERRITORY') {
      // an auction (lots sold) or a territory war (gangs present) — the report's own labels say which
      if (rd.cargoDescription === 'Territory War') {
        list.push({ label: 'Gangs Present', value: String(rd.roster?.gangCount ?? h.gang_participants ?? 0) });
      } else {
        list.push({ label: 'Territories Sold', value: `${rd.fleet?.delivered || 0} of ${rd.fleet?.total || 0}` });
        list.push({ label: 'Bidding Gangs', value: String(rd.roster?.gangCount ?? h.gang_participants ?? 0) });
      }
    }
    if (str(rd.cargoDescription) && k !== 'TDM' && k !== 'CONTAINER_WARS' && k !== 'GANG_TERRITORY' && k !== 'CRACKDOWN') list.push({ label: 'Cargo', value: rd.cargoDescription });
    list.push({ label: 'Rewards', value: rewards && rewards !== 'None' ? rewards : 'None', wide: true });
    return list;
  })();

  onMount(async () => {
    if (!reportData && historyItem && historyItem.id) {
      loadingReport = true;
      const res = await getReportPdf(historyItem.id, false);
      loadingReport = false;
      if (res && res.ok && res.reportData) {
        reportData = res.reportData;
      }
    }
  });

  function formatDuration(seconds) {
    if (!seconds) return '0m 00s';
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}m ${s < 10 ? '0' : ''}${s}s`;
  }

  function formatTimestamp(ts) {
    if (!ts) return '—';
    const d = new Date(ts);
    return isNaN(d) ? String(ts) : d.toLocaleString();
  }

  async function savePdf() {
    if (!historyItem?.id || pdfBusy) return;
    pdfBusy = true; pdfNote = null;
    pdfNote = await downloadReportPdf(historyItem.id);
    pdfBusy = false;
  }

  async function sendToDiscord() {
    if (!historyItem?.id || pdfBusy) return;
    pdfBusy = true; pdfNote = null;
    pdfNote = await resendReportToDiscord(historyItem.id);
    pdfBusy = false;
  }

  function close() {
    dispatch('close');
  }
</script>

<style>
  /* position:absolute + inset:0 (not fixed/100vw) so this fills the tablet
     frame exactly like ConfirmModal's overlay does. The tablet's .frame has a
     transform (frameIn animation + will-change), which makes position:fixed
     resolve against .frame instead of the viewport — 100vw/100vh then spilled
     past the frame and got clipped by its overflow:hidden, so the dialog
     appeared shoved sideways out of the tablet instead of centered on it. */
  .modal-backdrop {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0.75);
    z-index: 1000;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    box-sizing: border-box;
  }
  .modal-dialog {
    width: 100%;
    max-width: 100%;
    height: 100%;
    max-height: 100%;
    /* the same gradient + backdrop picture as the tablet frame (Tablet.svelte .frame), so the report matches the screens under it */
    background-color: var(--lt-07090d, #07090d);
    /* the first layer is the theme's background shade / gradient (Settings → Appearance); invisible for Graphite */
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent)));
    background-size: cover;
    background-position: center center;
    background-repeat: no-repeat;
    border: 1px solid rgba(85, 118, 160, 0.3);
    border-radius: var(--radius-md, 4px);
    box-shadow: none;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .modal-header {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px;
    background: var(--glass-bar, rgba(10, 12, 16, 0.88));
    border-bottom: 1px solid rgba(110, 140, 180, 0.2);
  }
  .header-left {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .header-icon {
    width: 34px;
    height: 34px;
    border-radius: var(--radius-sm, 4px);
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    color: var(--accent-primary);
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .header-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
    letter-spacing: 0.01em;
  }
  .header-sub {
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-top: 2px;
    font-family: var(--font-mono);
  }
  .header-actions {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .close-btn {
    width: 32px;
    height: 32px;
    background: transparent;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .pdf-btn { display: inline-flex; align-items: center; gap: 6px; height: 32px; padding: 0 12px; border-radius: var(--radius-sm); background: var(--c-action); border: 1px solid var(--c-action); color: var(--on-accent); font-size: var(--fs-small); font-weight: 600; cursor: pointer; }
  .pdf-btn:hover:not(:disabled) { background: var(--c-hover); color: var(--lt-ffffff, #fff); }
  .pdf-btn:disabled { opacity: 0.55; cursor: progress; }
  .pdf-note { flex-shrink: 0; padding: 8px 20px; font-size: var(--fs-small); color: var(--lt-7ee2b2, #7ee2b2); background: rgba(70, 201, 139, 0.1); border-bottom: 1px solid rgba(70, 201, 139, 0.35); }
  .pdf-note.bad { color: var(--lt-ffb4ad, #ffb4ad); background: rgba(255, 93, 80, 0.1); border-bottom-color: rgba(255, 93, 80, 0.4); }
  .close-btn:hover {
    color: var(--text-main);
    border-color: var(--text-main);
  }
  /* flex:1 + min-height:0 gives the body the dialog's leftover height so it scrolls; without them it grew past the dialog
     and the bottom was clipped. The blocks inside must not shrink either, or they squash and cut their own rows off. */
  .modal-body {
    flex: 1 1 auto;
    min-height: 0;
    padding: 24px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }
  .modal-body > * { flex-shrink: 0; }
  .kpi-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
  }
  .kpi-card {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 16px 18px;
    min-width: 0;
  }
  .kpi-card .kpi-value,
  .kpi-card .kpi-sub {
    overflow-wrap: anywhere;
    font-size: var(--fs-meta);
    font-weight: 500;
    color: var(--c-text-3);
  }
  .kpi-label {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0;
    margin-bottom: 6px;
  }
  .kpi-value {
    font-size: var(--fs-emph);
    font-weight: 700;
    color: var(--text-main);
    line-height: 1.35;
  }
  .kpi-sub {
    font-size: var(--fs-meta);
    color: var(--c-text-3);
    margin-top: 5px;
    line-height: 1.4;
    font-weight: 500;
  }
  .facts-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
  }
  .fact {
    padding: 11px 14px;
    border-right: 1px solid rgba(110, 140, 180, 0.14);
    border-bottom: 1px solid rgba(110, 140, 180, 0.14);
    min-width: 0;
  }
  .fact-wide { grid-column: 1 / -1; border-right: none; }
  .fact-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--tablet-text-faint);
    letter-spacing: 0.01em;
    margin-bottom: 3px;
  }
  .fact-value {
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--text-main);
    overflow-wrap: anywhere;
    line-height: 1.35;
  }
  .status-pill {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 9999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: #181b1f;
  }
  .status-delivered { background: #46c98b; color: #111316; }
  .status-captured { background: #ff5d50; color: var(--lt-ffffff, #ffffff); }
  .status-failed { background: #ff5d50; color: var(--lt-ffffff, #ffffff); }
  .status-cancelled { background: #aeb5bd; color: #111316; }

  .section {
    background: var(--glass-panel, rgba(16, 21, 30, 0.78));
    border: 1px solid rgba(110, 140, 180, 0.22);
    border-radius: var(--radius-sm, 4px);
    overflow: hidden;
  }
  .section-header {
    padding: 10px 14px;
    background: var(--glass-head, rgba(12, 16, 24, 0.7));
    border-bottom: 1px solid rgba(110, 140, 180, 0.18);
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-main, #ffffff);
    display: flex;
    align-items: center;
    gap: 8px;
    letter-spacing: 0.01em;
  }
  .audit-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--fs-body);
  }
  .audit-table th {
    background: var(--c-panel);
    color: var(--text-muted);
    font-weight: 600;
    text-align: left;
    padding: 8px 12px;
    border-bottom: 1px solid var(--c-line);
    font-size: var(--fs-meta);
    letter-spacing: 0;
    white-space: nowrap;
  }
  .audit-table td {
    padding: 9px 12px;
    border-bottom: 1px solid var(--c-line-soft);
    color: var(--text-main, #c9ced4);
    font-variant-numeric: tabular-nums;
  }
  .audit-table tr:last-child td {
    border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }
  .audit-table tr.alert-row td {
    background: rgba(255, 93, 80, 0.08);
    font-variant-numeric: tabular-nums;
  }
  .time-cell {
    font-family: var(--font-mono);
    color: var(--text-dim, #c9ced4);
    white-space: nowrap;
  }
  .actor-name {
    font-weight: 600;
  }
  .actor-faction {
    display: inline-block;
    padding: 1px 6px;
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    border-radius: var(--r-ctl);
    color: var(--accent-primary);
    font-size: var(--fs-small);
    margin-left: 4px;
  }
  .alert-tag {
    display: inline-block;
    padding: 1px 6px;
    background: rgb(255, 93, 80);
    border: 1px solid rgb(255, 93, 80);
    border-radius: var(--r-tag);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
    margin-right: 4px;
  }
  .hijack-tag {
    display: inline-block;
    padding: 1px 6px;
    background: rgb(255, 200, 87);
    border: 1px solid rgb(255, 200, 87);
    border-radius: var(--r-tag);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
    margin-right: 4px;
  }
  .evidence-text {
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    color: var(--lt-46c98b, #46c98b);
  }
  .timeline-box {
    padding: 12px 14px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    font-family: var(--font-mono);
    font-size: var(--fs-small);
  }
  .timeline-entry {
    color: var(--text-dim);
    line-height: 1.4;
  }
  .empty-note {
    padding: 14px;
    color: var(--tablet-text-faint);
    font-size: var(--fs-small);
    font-style: italic;
  }
</style>

<div class="modal-backdrop" on:click|self={close}>
  <div class="modal-dialog">
    <div class="modal-header">
      <div class="header-left">
        <div class="header-icon">
          <Icon name="fileText" size={18} />
        </div>
        <div>
          <div class="header-title">{docTitle}</div>
          <div class="header-sub">
            OPERATION: {historyItem ? historyItem.name : '—'} &nbsp;|&nbsp;
            REF: #{historyItem ? historyItem.id : '—'} &nbsp;|&nbsp;
            CONCLUDED: {historyItem ? formatTimestamp(historyItem.ended_at) : '—'}
          </div>
        </div>
      </div>
      <div class="header-actions" style="display:flex; align-items:center; gap:8px;">
        <button class="pdf-btn" disabled={pdfBusy} on:click={savePdf} title="Download this report as a PDF"><Icon name="fileText" size={13} /> {pdfBusy ? 'Working…' : 'Download PDF'}</button>
        <button class="pdf-btn" disabled={pdfBusy} on:click={sendToDiscord} title="Post the PDF report to the Discord channel">Send to Discord</button>
        <button class="close-btn" on:click={close} title="Close">
          <Icon name="close" size={14} />
        </button>
      </div>
    </div>

    {#if pdfNote}<div class="pdf-note" class:bad={!pdfNote.ok}>{pdfNote.message}</div>{/if}
    <div class="modal-body">
      {#if loadingReport}
        <div class="empty-note">Loading audit data...</div>
      {/if}

      <!-- At a glance: the main facts of the run -->
      <div class="section">
        <div class="section-header"><Icon name="fileText" size={14} /> Event Summary</div>
        <div class="facts-grid">
          {#each summary as f}
            <div class="fact" class:fact-wide={f.wide}>
              <div class="fact-label">{f.label}</div>
              <div class="fact-value">{f.value}</div>
            </div>
          {/each}
        </div>
      </div>

      <!-- 4-Card KPI Overview Grid -->
      <div class="kpi-grid">
        <div class="kpi-card">
          <div class="kpi-label">Outcome Status</div>
          <div>
            {#if historyItem?.outcome === 'COMPLETED'}
              <span class="status-pill status-delivered">{outcomeBadgeLabel}</span>
            {:else if historyItem?.outcome === 'CAPTURED'}
              <span class="status-pill status-captured">{outcomeBadgeLabel}</span>
            {:else if historyItem?.outcome === 'FAILED'}
              <span class="status-pill status-failed">{outcomeBadgeLabel}</span>
            {:else}
              <span class="status-pill status-cancelled">{outcomeBadgeLabel}</span>
            {/if}
          </div>
          {#if !L?.outcomeLabel}
            <div class="kpi-sub">
              {STATUS_LABELS[historyItem?.outcome] || historyItem?.outcome || 'Status'}
            </div>
          {/if}
        </div>

        <div class="kpi-card">
          <div class="kpi-label">{L?.winnerTitle || (isOpenGangEvent ? 'Top Gang / Victor' : historyItem?.kind === 'GANG_RACE' ? 'Race Winner' : 'Primary Victor')}</div>
          <div class="kpi-value" style="font-size: var(--fs-body);">
            {reportData?.winner || historyItem?.winning_gang || (historyItem?.outcome === 'COMPLETED' ? (isOpenGangEvent ? 'Contesting Gangs' : historyItem?.kind === 'GANG_RACE' ? 'Independent Racer' : 'Police Escort') : 'None')}
          </div>
          <div class="kpi-sub">
            {L?.winnerSub ?? (reportData?.winningGang ? `Gang: ${reportData.winningGang}` : (isOpenGangEvent ? 'Open Gang Event' : historyItem?.kind === 'GANG_RACE' ? 'No Faction Payout' : 'Official Dispatch'))}
          </div>
        </div>

        <div class="kpi-card">
          <div class="kpi-label">{L?.forcesTitle || 'Duration & Forces'}</div>
          <div class="kpi-value">
            {formatDuration(historyItem?.duration)}
          </div>
          <div class="kpi-sub">
            {#if L?.forces}
              {L.forces}
            {:else if historyItem?.kind === 'GANG_AIRDROP'}
              Gangs Engaged: {historyItem?.gang_participants || 0}
            {:else}
              Police: {historyItem?.police_participants || 0} &nbsp;|&nbsp; Gangs: {historyItem?.gang_participants || 0}
            {/if}
          </div>
        </div>

        <div class="kpi-card">
          <div class="kpi-label">
            {L?.card4?.title || (historyItem?.kind === 'GANG_AIRDROP' ? 'Supply Drops & Crates' : historyItem?.kind === 'HOT_CARGO' ? 'Contraband Vehicles' : historyItem?.kind === 'GANG_RACE' ? 'Reward Pool' : 'Fleet & Cargo')}
          </div>
          <div class="kpi-value" style="font-size: var(--fs-body);">
            {#if L?.card4}
              {L.card4.main}
            {:else if historyItem?.kind === 'GANG_AIRDROP'}
              {reportData?.airdropCaptures?.length || 0} / {reportData?.fleet?.total || historyItem?.truck_count || 0} Drop Zones Claimed
            {:else if historyItem?.kind === 'HOT_CARGO'}
              {reportData?.fleet?.delivered || 0} Delivered ({reportData?.fleet?.total || historyItem?.truck_count || 0} Spawned)
            {:else if historyItem?.kind === 'GANG_RACE'}
              {reportData?.summaryLine || reportData?.rewards || historyItem?.reward_summary || 'None'}
            {:else}
              {reportData?.fleet?.delivered ?? 0} of {reportData?.fleet?.total ?? historyItem?.truck_count ?? 0} Trucks Delivered ({reportData?.fleet?.destroyed ?? historyItem?.destroyed_trucks ?? 0} Lost)
            {/if}
          </div>
          <div class="kpi-sub">
            {L?.card4?.sub ?? (historyItem?.kind === 'GANG_AIRDROP' ? 'Gang Supply Drops'
              : historyItem?.kind === 'HOT_CARGO' ? 'Contraband Vehicles Spawned'
              : historyItem?.kind === 'GANG_RACE' ? `Racers: ${historyItem?.gang_participants || 0}`
              : (reportData?.cargoDescription || historyItem?.reward_summary || 'Convoy Cargo'))}
          </div>
        </div>
      </div>

      <!-- Section 1: Interceptions & Cargo Audit -->
      <div class="section">
        <div class="section-header">
          <Icon name={historyItem?.kind === 'GANG_AIRDROP' ? 'parachute' : (historyItem?.kind === 'GANG_RACE' || historyItem?.kind === 'TDM') ? 'flag' : historyItem?.kind === 'CONTAINER_WARS' ? 'box' : historyItem?.kind === 'GANG_TERRITORY' ? 'pin' : historyItem?.kind === 'CRACKDOWN' ? 'shield' : historyItem?.kind === 'HOT_CARGO' ? 'flame' : 'truck'} size={14} />
          {L?.sec1Title || (historyItem?.kind === 'GANG_AIRDROP' ? 'Airdrop Drops & Crate Claims Audit'
            : historyItem?.kind === 'HOT_CARGO' ? 'Hot Cargo Pursuit & Reward Audit'
            : historyItem?.kind === 'GANG_RACE' ? 'Race Incident & Pursuit Log'
            : 'Interceptions & Cargo Breach Audit')}
        </div>
        {#if reportData?.interceptions && reportData.interceptions.length > 0}
          <table class="audit-table">
            <thead>
              <tr>
                <th>{L?.sec1Cols?.[0] ?? 'Time'}</th>
                <th>{L?.sec1Cols?.[1] ?? (historyItem?.kind === 'GANG_AIRDROP' ? 'Drop Zone' : historyItem?.kind === 'HOT_CARGO' ? 'Target / Zone' : 'Target')}</th>
                <th>{L?.sec1Cols?.[2] ?? (historyItem?.kind === 'GANG_AIRDROP' ? 'Access Method' : historyItem?.kind === 'HOT_CARGO' ? 'Status / Action' : 'Breach Method')}</th>
                <th>{L?.sec1Cols?.[3] ?? (historyItem?.kind === 'GANG_AIRDROP' ? 'Claiming Gang & Actor' : historyItem?.kind === 'HOT_CARGO' ? 'Delivering Operative' : 'Actor & Faction')}</th>
                <th>{L?.sec1Cols?.[4] ?? (historyItem?.kind === 'GANG_AIRDROP' ? 'Crate Loot Secured' : historyItem?.kind === 'HOT_CARGO' ? 'Drop Crate / Rewards' : 'Evidence / Loot Extracted')}</th>
              </tr>
            </thead>
            <tbody>
              {#each reportData.interceptions as item}
                <tr class:alert-row={item.isAlert || item.isPolice}>
                  <td class="time-cell">{item.time}</td>
                  <td><strong>{item.target}</strong></td>
                  <td>{item.method}</td>
                  <td>
                    {#if item.isPolice}
                      <span class="alert-tag">POLICE FAIL-RP</span>
                    {:else if item.method === 'PvP Loot Hijack'}
                      <span class="hijack-tag">HIJACK</span>
                    {/if}
                    <span class="actor-name">{item.actorName}</span>
                    {#if item.faction}
                      <span class="actor-faction">{item.faction}</span>
                    {/if}
                  </td>
                  <td>
                    <span class="evidence-text">{item.evidence}</span>
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        {:else}
          <div class="empty-note">
            {L?.sec1Empty ?? (historyItem?.kind === 'GANG_AIRDROP'
              ? 'No supply drop crates were cracked or looted during this airdrop operation.'
              : historyItem?.kind === 'HOT_CARGO'
              ? 'No contraband vehicles were successfully delivered during this Hot Cargo run.'
              : historyItem?.kind === 'GANG_RACE'
              ? 'No pursuit or incident events were logged during this race.'
              : 'No individual cargo interceptions or breaches recorded for this operation.')}
          </div>
        {/if}
      </div>

      <!-- Extra detail tables (Container Wars lot details) -->
      {#each reportData?.extraTables || [] as xt}
        <div class="section">
          <div class="section-header"><Icon name="box" size={14} /> {xt.title}</div>
          <table class="audit-table">
            <thead><tr>{#each xt.cols as col}<th>{col.label}</th>{/each}</tr></thead>
            <tbody>
              {#each xt.rows as row}
                <tr>{#each row as cell}<td>{cell}</td>{/each}</tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/each}

      <!-- Section 2: Faction Scorecard -->
      <div class="section">
        <div class="section-header">
          <Icon name="users" size={14} /> {L?.sec2Title || 'Faction Engagement & Scorecard'}
        </div>
        {#if L?.sec2Cols && reportData?.gangScorecard && reportData.gangScorecard.length > 0}
          <table class="audit-table">
            <thead>
              <tr>
                <th>Faction / Gang</th>
                {#each L.sec2Cols as col}<th>{col}</th>{/each}
              </tr>
            </thead>
            <tbody>
              {#each reportData.gangScorecard as sc}
                <tr>
                  <td><strong>{sc.label || sc.name}</strong></td>
                  {#each sc.cells || [] as cell}<td>{cell}</td>{/each}
                </tr>
              {/each}
            </tbody>
          </table>
        {:else if reportData?.gangScorecard && reportData.gangScorecard.length > 0}
          <table class="audit-table">
            <thead>
              <tr>
                <th>Faction / Gang</th>
                <th>{historyItem?.kind === 'GANG_AIRDROP' ? 'Operatives' : historyItem?.kind === 'GANG_RACE' ? 'Racers Entered' : 'Units'}</th>
                {#if historyItem?.kind === 'GANG_RACE'}
                  <th>Result</th>
                {:else}
                  {#if historyItem?.kind !== 'GANG_AIRDROP'}
                    <th>Trucks</th>
                  {/if}
                  <th>{historyItem?.kind === 'GANG_AIRDROP' ? 'Drops Secured' : 'Airdrops'}</th>
                  {#if historyItem?.kind !== 'GANG_AIRDROP'}
                    <th>Hijacks</th>
                  {/if}
                {/if}
                <th>Rewards Secured</th>
              </tr>
            </thead>
            <tbody>
              {#each reportData.gangScorecard as sc}
                <tr>
                  <td><strong>{sc.label || sc.name}</strong></td>
                  <td>{sc.units}</td>
                  {#if historyItem?.kind === 'GANG_RACE'}
                    <td>{reportData?.winningGang && sc.name === reportData.winningGang ? 'Winner' : 'Participated'}</td>
                    <td><span class="evidence-text">{reportData?.winningGang && sc.name === reportData.winningGang ? (reportData?.rewards || 'None') : 'None'}</span></td>
                  {:else}
                    {#if historyItem?.kind !== 'GANG_AIRDROP'}
                      <td>{sc.trucksCaptured}</td>
                    {/if}
                    <td>{sc.airdropsCaptured}</td>
                    {#if historyItem?.kind !== 'GANG_AIRDROP'}
                      <td>{sc.hijacks}</td>
                    {/if}
                    <td><span class="evidence-text">{sc.rewardSummary}</span></td>
                  {/if}
                </tr>
              {/each}
            </tbody>
          </table>
        {:else}
          <div class="empty-note">
            {L?.sec2Empty ?? (historyItem?.kind === 'GANG_AIRDROP'
              ? 'No gangs actively registered crate captures during this airdrop operation.'
              : historyItem?.kind === 'GANG_RACE'
              ? 'No gang-affiliated racers were entered in this race.'
              : 'No hostile gang factions were actively engaged in this operation.')}
          </div>
        {/if}
      </div>

      <!-- Section 3: Police Conduct & Corrupt RP Audit (if alerts exist) -->
      {#if reportData?.policeAudit && reportData.policeAudit.length > 0}
        <div class="section">
          <div class="section-header" style="color: #e38a86;">
            <Icon name="warning" size={14} /> Internal Affairs: Police Conduct & Loot Audit
          </div>
          <table class="audit-table">
            <thead>
              <tr>
                <th>Time</th>
                <th>Incident Type</th>
                <th>Officer</th>
                <th>Job Grade</th>
                <th>Evidence / Target</th>
              </tr>
            </thead>
            <tbody>
              {#each reportData.policeAudit as pa}
                <tr class="alert-row">
                  <td class="time-cell">{pa.timeStr}</td>
                  <td><span class="alert-tag">{pa.type}</span></td>
                  <td><strong>{pa.officerName}</strong> ({pa.officerIdentifier})</td>
                  <td>{pa.job} (Grade {pa.jobGrade})</td>
                  <td><span class="evidence-text">{pa.target}: {pa.items}</span></td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}

      <!-- Section 4: Chronological Incident Timeline -->
      <div class="section">
        <div class="section-header">
          <Icon name="activity" size={14} /> Chronological Incident Timeline
        </div>
        {#if reportData?.timeline && reportData.timeline.length > 0}
          <div class="timeline-box">
            {#each reportData.timeline as t}
              <div class="timeline-entry">{t}</div>
            {/each}
          </div>
        {:else}
          <div class="empty-note">
            No timeline logs available for this operation.
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>

