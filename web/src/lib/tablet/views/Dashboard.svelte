<script>
  import { sameData } from '../../util/stable.js';
  import { onMount, onDestroy, createEventDispatcher } from 'svelte';
  import { bootstrap, currentView } from '../../stores.js';
  import { getDashboard, getConvoys, forceEndConvoy } from '../../api/convoy.js';
  import { getActiveConvoys, startRaceCountdown } from '../../api/runtime.js';
  import { clearPlacedPreview } from '../../api/placer.js';
  import { STATUS_LABELS } from '../../constants.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import { themeFor } from '../../hud/eventThemes.js';
  import '../tablet-theme.css';

  const dispatch = createEventDispatcher();

  let stats = { draft: 0, scheduled: 0, active: 0, completed: 0, captured: 0, total: 0 };
  let live = [];
  let recent = [];
  let liveLoaded = false;
  let error = '';
  let expandedId = null; // `gang:<id>` / `police:<id>` — which live card's roster is open
  let ending = {};
  let startingCountdown = {};
  let pollInterval;
  let lastRecentKey = '';

  // `view` is which nav tab clicking each card jumps to — Draft/Scheduled
  // both live in Manage Events (nothing else shows them), Completed/Captured
  // both land in Event History. Active Runs has no tab of its own any more —
  // the live operation cards sit right above these.
  const CARDS = [
    { key: 'total', label: 'Total events', meta: 'All configured events', view: 'convoys' },
    { key: 'draft', label: 'Drafts', meta: 'Not started', view: 'convoys' },
    { key: 'scheduled', label: 'Scheduled', meta: 'Upcoming events', view: 'convoys' },
    { key: 'active', label: 'Active runs', meta: 'Currently running', view: null },
    { key: 'completed', label: 'Completed', meta: 'Finished events', view: 'completed' },
    { key: 'captured', label: 'Captured', meta: 'Recorded outcomes', view: 'completed' },
  ];

  const FEATURE_TOGGLES = [
    { key: 'GangPvp', label: 'Gang PvP' },
    { key: 'NpcPolice', label: 'NPC Police' },
    { key: 'ArmySupport', label: 'Army Support' },
    { key: 'Airdrops', label: 'Airdrops' },
  ];

  const KIND_LABELS = {
    CONVOY: 'Convoy',
    HOT_CARGO: 'Hot Cargo',
    GANG_AIRDROP: 'Gang Airdrop',
    GANG_RACE: 'Rally Race',
    TDM: 'TDM',
    CONTAINER_WARS: 'Container Wars',
    GANG_TERRITORY: 'Territory Auction',
    CRACKDOWN: 'Operation Crackdown',
  };
  const kindLabel = (kind) => KIND_LABELS[kind] || KIND_LABELS.CONVOY;

  // Presentation only: each event kind keeps its HUD identity colour
  // (lib/hud/eventThemes.js) as the strip edge / tag marker on the tablet.
  const KIND_THEME = {
    CONVOY: 'convoy', HOT_CARGO: 'hotcargo', GANG_AIRDROP: 'airdrop', GANG_RACE: 'rally',
    TDM: 'tdm', CONTAINER_WARS: 'containerwars', GANG_TERRITORY: 'territory', CRACKDOWN: 'crackdown',
  };
  const kindColor = (kind) => themeFor(KIND_THEME[kind] || 'convoy').accent;
  // Route strips draw one node per point up to this many; longer routes show a plain bar.
  const MAX_NODES = 24;
  function statusTone(status) {
    if (status === 'UNDER_ATTACK') return 's-attack';
    if (LIVE_STATUSES.includes(status)) return 's-live';
    if (status === 'SCHEDULED') return 's-sched';
    if (status === 'DRAFT') return 's-draft';
    if (status === 'COMPLETED') return 's-done';
    if (status === 'CAPTURED') return 's-captured';
    return 's-ended'; // FAILED / CANCELLED
  }

  const LIVE_STATUSES = ['STARTING', 'ACTIVE', 'CHECKPOINT', 'UNDER_ATTACK', 'DELIVERY'];

  let recentStarted = false;
  async function refreshLive() {
    const firstRecent = !recentStarted;
    if (firstRecent) { recentStarted = true; refreshRecent(); }      // in parallel with the live data on the first load
    const [dash, act] = await Promise.all([getDashboard(), getActiveConvoys()]);
    if (dash && dash.ok && !sameData(dash.dashboard, stats)) stats = dash.dashboard;
    const nextLive = act && act.ok ? act.convoys : [];
    if (!sameData(nextLive, live)) live = nextLive;
    liveLoaded = true;

    // The recent-events list is the heavier call (full definitions), so only
    // refetch it when something actually changed — a run started/ended.
    const key = `${stats.total}:${stats.active}:${stats.completed}:${stats.captured}:${live.map((c) => c.id).join(',')}`;
    if (key !== lastRecentKey) {
      lastRecentKey = key;
      if (!firstRecent) refreshRecent();
    }
  }

  async function refreshRecent() {
    const res = await getConvoys();
    if (!res || !res.ok) return;
    recent = [...res.convoys]
      .sort((a, b) => toMs(b.updatedAt) - toMs(a.updatedAt))
      .slice(0, 5);
  }

  // updatedAt comes through as either an ISO/MySQL datetime string or a raw
  // epoch-ms number depending on how oxmysql serialized the DATETIME column.
  function toMs(value) {
    if (!value) return 0;
    const ms = typeof value === 'number' ? value : Date.parse(value);
    return Number.isNaN(ms) ? 0 : ms;
  }

  function relativeTime(value) {
    const ms = toMs(value);
    if (!ms) return '—';
    const mins = Math.floor((Date.now() - ms) / 60000);
    if (mins < 1) return 'Just now';
    if (mins < 60) return `${mins} min ago`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    if (days === 1) return 'Yesterday';
    if (days < 30) return `${days} days ago`;
    return new Date(ms).toLocaleDateString();
  }

  function pillClass(status) {
    if (LIVE_STATUSES.includes(status)) return 'live';
    if (status === 'DRAFT' || status === 'SCHEDULED') return 'draft';
    if (status === 'COMPLETED') return 'completed';
    return 'ended'; // CAPTURED / FAILED / CANCELLED
  }

  function formatTime(seconds) {
    if (seconds == null) return '--:--';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  const progressPct = (c) =>
    c.totalRoutePoints > 0 ? Math.min(100, Math.round((c.currentRouteIndex / c.totalRoutePoints) * 100)) : 0;

  function toggleRoster(key) {
    expandedId = expandedId === key ? null : key;
  }

  async function forceEnd(c) {
    const ok = await confirmAction(`This immediately terminates "${c.name}" for everyone. This can't be undone.`, { title: 'Force End Event', danger: true });
    if (!ok) return;
    error = '';
    ending = { ...ending, [c.id]: true };
    const res = await forceEndConvoy(c.id);
    ending = { ...ending, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to end event.'; return; }
    refreshLive();
  }

  async function startCountdown(c) {
    clearPlacedPreview();
    error = '';
    startingCountdown = { ...startingCountdown, [c.id]: true };
    const res = await startRaceCountdown(c.id);
    startingCountdown = { ...startingCountdown, [c.id]: false };
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to start countdown.'; return; }
    refreshLive();
  }

  onMount(() => {
    refreshLive();
    pollInterval = setInterval(refreshLive, 5000);
  });
  onDestroy(() => clearInterval(pollInterval));
</script>

<div class="dash view-enter">
  <header class="page-header">
    <div>
      <h1 class="page-title">Operations overview</h1>
      <p class="page-sub">
        {#if !liveLoaded}Loading live operations…
        {:else if live.length}{live.length} event{live.length > 1 ? 's' : ''} running, {stats.scheduled ?? 0} scheduled.
        {:else}Nothing running, {stats.scheduled ?? 0} scheduled.{/if}
      </p>
    </div>
    <div class="head-actions">
      <button class="btn" on:click={() => currentView.set('completed')}><Icon name="history" size={14} /> Event history</button>
      <button class="btn btn-primary" on:click={() => dispatch('new')}><Icon name="plus" size={14} /> Create event</button>
    </div>
  </header>

  {#if error}<div class="error-bar" role="alert"><Icon name="alertCircle" size={15} /> {error}</div>{/if}

  <!-- Live operations: one route strip per running event -->
  {#if live.length > 0}
    <div class="ops">
      {#each live as c (c.id)}
        <section class="op" style="--k:{kindColor(c.kind)}">
          <div class="op-head">
            <div class="op-ident">
              <span class="live-flag"><i></i>Live</span>
              <h2 class="op-name">{c.name}</h2>
              <span class="op-tags">
                <span class="kind" style="--k:{kindColor(c.kind)}">{kindLabel(c.kind)}</span>
                <span class="status {statusTone(c.status)}">{STATUS_LABELS[c.status] || c.status}</span>
              </span>
            </div>
            <div class="op-actions">
              {#if c.kind === 'GANG_RACE' && c.raceGrid}
                <button class="btn btn-primary btn-sm" disabled={startingCountdown[c.id]} title="Racers are gathered — release them and begin race" on:click={() => startCountdown(c)}>
                  <Icon name="play" size={12} /> {startingCountdown[c.id] ? 'Starting…' : 'Start race'}
                </button>
              {/if}
              <button class="btn btn-danger btn-sm" disabled={ending[c.id]} on:click={() => forceEnd(c)}>
                <Icon name="close" size={12} /> {ending[c.id] ? 'Ending…' : 'Force end'}
              </button>
            </div>
          </div>

          <div class="op-body">
            <div class="track" aria-label="{c.kind === 'GANG_RACE' ? 'Stage' : 'Checkpoint'} {c.currentRouteIndex} of {c.totalRoutePoints}">
              <div class="track-rail">
                <span class="track-line"></span>
                <span class="track-fill" style="width:{progressPct(c)}%"></span>
                {#if c.totalRoutePoints > 0 && c.totalRoutePoints <= MAX_NODES}
                  {#each Array(c.totalRoutePoints + 1) as _, i}
                    <span class="node" class:done={i < c.currentRouteIndex} class:here={i === c.currentRouteIndex} class:end={i === c.totalRoutePoints} style="left:{(i / c.totalRoutePoints) * 100}%"></span>
                  {/each}
                {:else}
                  <span class="node here" style="left:{progressPct(c)}%"></span>
                {/if}
              </div>
              <div class="track-labels">
                <span style="left:0%">{c.kind === 'GANG_RACE' ? 'Grid' : 'Start'}</span>
                {#if c.currentRouteIndex > 0 && c.currentRouteIndex < c.totalRoutePoints}
                  <span class="cur mid" style="left:{progressPct(c)}%">{c.kind === 'GANG_RACE' ? 'Stage' : 'CP'} {c.currentRouteIndex}</span>
                {/if}
                <span class="last" style="left:100%">{c.kind === 'GANG_RACE' ? 'Finish' : 'Drop-off'}</span>
              </div>
            </div>

            <div class="op-metrics">
              <div class="metric">
                <div class="metric-label">Time remaining</div>
                <div class="metric-value big">{formatTime(c.deliveryTimeRemaining)}</div>
              </div>
              {#if c.status === 'CHECKPOINT'}
                <div class="metric">
                  <div class="metric-label">Checkpoint timer</div>
                  <div class="metric-value warn">{formatTime(c.checkpointTimeRemaining)}</div>
                </div>
              {/if}
              <div class="metric">
                <div class="metric-label">{c.kind === 'GANG_RACE' ? 'Lead stage' : 'Checkpoint'}</div>
                <div class="metric-value">{c.currentRouteIndex}<small>/{c.totalRoutePoints}</small></div>
              </div>
              <div class="metric">
                <div class="metric-label">Police</div>
                <button class="roster-btn metric-value" aria-expanded={expandedId === `police:${c.id}`} title="Who's signed on as an escort right now" on:click={() => toggleRoster(`police:${c.id}`)}>
                  {c.joinedPoliceEscorts ?? c.policeParticipants}<small>/{c.maxPoliceParticipants || 20}</small>
                  <Icon name={expandedId === `police:${c.id}` ? 'chevronUp' : 'chevronDown'} size={13} />
                </button>
              </div>
              <div class="metric">
                <div class="metric-label">Gangs</div>
                <button class="roster-btn metric-value" aria-expanded={expandedId === `gang:${c.id}`} title="Active gang participants" on:click={() => toggleRoster(`gang:${c.id}`)}>
                  {c.gangParticipants}<small>/{c.maxGangParticipants || 20}</small>
                  <Icon name={expandedId === `gang:${c.id}` ? 'chevronUp' : 'chevronDown'} size={13} />
                </button>
              </div>
            </div>
          </div>

          {#if expandedId === `gang:${c.id}`}
            <div class="ao-roster">
              <div class="roster-title">Gangs in this run</div>
              {#if !c.gangBreakdown || c.gangBreakdown.length === 0}
                <span class="roster-empty">No gangs have joined yet.</span>
              {:else}
                <div class="chip-list">
                  {#each c.gangBreakdown as g (g.name)}
                    <span class="chip">
                      {g.label} <b>{g.count}</b>
                      {#if g.members && g.members.length > 0}
                        <span class="who">{g.members.map((m) => m.name).join(', ')}</span>
                      {/if}
                    </span>
                  {/each}
                </div>
              {/if}
            </div>
          {:else if expandedId === `police:${c.id}`}
            <div class="ao-roster">
              <div class="roster-title">Signed on as escort</div>
              {#if !c.policeEscorts || c.policeEscorts.length === 0}
                <span class="roster-empty">No officers have joined as an escort yet.</span>
              {:else}
                <div class="chip-list">
                  {#each c.policeEscorts as p (p.identifier)}
                    <span class="chip police"><Icon name="shield" size={12} /> {p.name}</span>
                  {/each}
                </div>
              {/if}
            </div>
          {/if}
        </section>
      {/each}
    </div>
  {:else if liveLoaded}
    <section class="op idle">
      <div class="idle-body">
        <div>
          <div class="idle-title">No events running</div>
          <div class="idle-text">Started events appear here with their route, timers and rosters.</div>
        </div>
        <button class="btn" on:click={() => currentView.set('convoys')}><Icon name="list" size={14} /> Manage events</button>
      </div>
    </section>
  {/if}

  <!-- Counter rail -->
  <div class="rail" role="group" aria-label="Event counts">
    {#each CARDS as card}
      {#if card.view}
        <button class="seg clickable" on:click={() => currentView.set(card.view)}>
          <div class="seg-label">{card.label}</div>
          <div class="seg-num">{stats[card.key] ?? 0}</div>
          <div class="seg-meta">{card.meta}</div>
          <span class="seg-go"><Icon name="chevronRight" size={14} /></span>
        </button>
      {:else}
        <div class="seg" class:is-live={card.key === 'active' && (stats.active ?? 0) > 0}>
          <div class="seg-label">{#if card.key === 'active' && (stats.active ?? 0) > 0}<span class="dot"></span>{/if}{card.label}</div>
          <div class="seg-num">{stats[card.key] ?? 0}</div>
          <div class="seg-meta">{card.meta}</div>
        </div>
      {/if}
    {/each}
  </div>

  <div class="dashboard-grid">
    <section class="d-panel">
      <div class="d-panel-header">
        <h2 class="d-panel-title">Recent events</h2>
        <button class="link-btn" on:click={() => currentView.set('convoys')}>View all events</button>
      </div>
      {#if recent.length === 0}
        <div class="table-empty">No events yet. Create one to get started.</div>
      {:else}
        <table class="ev-table">
          <thead>
            <tr><th>Event</th><th class="col-type">Type</th><th>Updated</th><th class="col-status">Status</th></tr>
          </thead>
          <tbody>
            {#each recent as c (c.id)}
              <tr style="--k:{kindColor(c.kind)}">
                <td>
                  <div class="event-name">{c.name}</div>
                  <div class="event-description">{c.shortDescription || c.description || STATUS_LABELS[c.status] || c.status}</div>
                </td>
                <td class="col-type"><span class="kind" style="--k:{kindColor(c.kind)}">{kindLabel(c.kind)}</span></td>
                <td class="event-time">{relativeTime(c.updatedAt)}</td>
                <td class="col-status"><span class="status {statusTone(c.status)}">{STATUS_LABELS[c.status] || c.status}</span></td>
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    </section>

    <div class="side-col">
      <section class="d-panel">
        <div class="d-panel-header">
          <h2 class="d-panel-title">System status</h2>
          <span class="panel-note">Config limits</span>
        </div>
        <div class="d-panel-body">
          {#if $bootstrap}
            <div class="sys-block">
              <div class="sys-row flat">
                <span class="system-name">Event slots</span>
                <span class="system-value">{stats.total}<small> / {$bootstrap.limits.maxConvoys} used</small></span>
              </div>
              {#if $bootstrap.limits.maxConvoys > 0 && $bootstrap.limits.maxConvoys <= 60}
                <div class="slots" style="grid-template-columns:repeat({$bootstrap.limits.maxConvoys}, 1fr)" aria-hidden="true">
                  {#each Array($bootstrap.limits.maxConvoys) as _, i}
                    <i class:live={i < (stats.active ?? 0)} class:used={i >= (stats.active ?? 0) && i < stats.total}></i>
                  {/each}
                </div>
                <div class="slots-legend"><span><i class="lg-live"></i>Live</span><span><i class="lg-used"></i>Saved</span><span><i></i>Free</span></div>
              {:else}
                <div class="progress"><div class="progress-bar" style="width:{Math.min(100, ($bootstrap.limits.maxConvoys ? (stats.total / $bootstrap.limits.maxConvoys) * 100 : 0))}%"></div></div>
              {/if}
            </div>
            <div class="sys-row">
              <span class="system-name">Gang provider</span>
              <span class="system-value cap">{$bootstrap.gangProvider}</span>
            </div>
            <div class="sys-row">
              <span class="system-name">Trucks per convoy</span>
              <span class="system-value">{$bootstrap.limits.maxTrucksPerConvoy}<small> max</small></span>
            </div>
            <div class="sys-row">
              <span class="system-name">Checkpoints per route</span>
              <span class="system-value">{$bootstrap.limits.maxCheckpoints}<small> max</small></span>
            </div>
            <div class="sys-row">
              <span class="system-name">Live refresh</span>
              <span class="system-value ok">Every 5 s</span>
            </div>
          {/if}
        </div>
      </section>

      {#if $bootstrap}
        <section class="d-panel">
          <div class="d-panel-header">
            <h2 class="d-panel-title">Features</h2>
            {#if $bootstrap.isAdmin}
              <button class="link-btn" on:click={() => currentView.set('settings')}>Change in Settings</button>
            {:else}
              <span class="panel-note">Set by admins</span>
            {/if}
          </div>
          <div class="feature-list">
            {#each FEATURE_TOGGLES as toggle}
              <div class="feature" class:off={!$bootstrap.features[toggle.key]}>
                <span class="feature-name">{toggle.label}</span>
                <span class="feature-status"><i></i>{$bootstrap.features[toggle.key] ? 'On' : 'Off'}</span>
              </div>
            {/each}
          </div>
        </section>
      {/if}
    </div>
  </div>
</div>

<style>
  .dash {
    width: 100%;
  }

  /* Page header */
  .page-header {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 16px;
  }
  .page-title {
    margin: 0;
    color: var(--c-text);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 30px;
    line-height: 1;
    font-weight: 700;
    letter-spacing: 0.005em;
  }
  .page-sub {
    margin-top: 6px;
    color: var(--c-text-3);
    font-size: var(--fs-body);
  }
  .head-actions {
    display: flex;
    gap: 8px;
    flex-shrink: 0;
  }
  .error-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 14px;
    padding: 9px 12px;
    border: 1px solid var(--c-line);
    border-left: 3px solid var(--c-live);
    border-radius: var(--r-panel);
    background: var(--c-raised);
    color: var(--lt-ff8f86, #ff8f86);
    font-size: var(--fs-body);
    border-left: 3px solid rgb(255, 93, 80);}

  /* Active operations */
  .ops {
    display: grid;
    gap: 10px;
    margin-bottom: 14px;
  }
  .op {
    --k: #ee8a2b;
    background: var(--glass-panel, var(--c-panel));
    border: 1px solid var(--c-line);
    border-left: 3px solid var(--k);
    border-radius: var(--r-panel);
  }
  .op.idle {
    --k: #3a4048;
    margin-bottom: 14px;
  }
  .op-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    padding: 12px 16px 0;
  }
  .op-ident {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
  }
  .live-flag {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    flex-shrink: 0;
    color: var(--c-live);
    font-size: var(--fs-small);
    font-weight: 700;
  }
  .live-flag i {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--c-live);
    animation: blink 2s ease-in-out infinite;
  }
  @keyframes blink { 50% { opacity: 0.35; } }
  .op-name {
    margin: 0;
    color: var(--c-text);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-section);
    line-height: 1.1;
    font-weight: 700;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .op-tags {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
    margin-left: 4px;
  }
  .op-actions {
    display: flex;
    gap: 8px;
    flex-shrink: 0;
  }
  .op-body {
    display: grid;
    grid-template-columns: minmax(300px, 1fr) auto;
    align-items: end;
    gap: 28px;
    padding: 14px 16px;
  }

  /* Route track — checkpoints as nodes along the run */
  .track-rail {
    position: relative;
    height: 22px;
    margin: 0 8px;
  }
  .track-line,
  .track-fill {
    position: absolute;
    left: 0;
    top: 10px;
    height: 2px;
  }
  .track-line { right: 0; background: var(--c-line); }
  .track-fill { background: var(--k); }
  .node {
    position: absolute;
    top: 5px;
    width: 12px;
    height: 12px;
    margin-left: -6px;
    background: var(--c-panel);
    border: 2px solid #3a4048;
    transform: rotate(45deg);
  }
  .node.done { background: var(--k); border-color: var(--k); }
  .node.end { border-radius: 50%; transform: none; }
  .node.here {
    width: 16px;
    height: 16px;
    margin-left: -8px;
    top: 3px;
    background: var(--c-panel);
    border-color: var(--k);
    box-shadow: 0 0 0 3px var(--c-panel), 0 0 0 4px var(--k);
  }
  .track-labels {
    position: relative;
    height: 18px;
    margin: 4px 8px 0;
    color: var(--c-text-3);
    font-size: var(--fs-meta);
  }
  .track-labels span {
    position: absolute;
    white-space: nowrap;
  }
  .track-labels span:first-child { left: -8px !important; }
  .track-labels .mid { transform: translateX(-50%); }
  .track-labels .last { left: auto !important; right: -8px; }
  .track-labels .cur { color: var(--c-text); font-weight: 600; }

  .op-metrics {
    display: flex;
    align-items: stretch;
  }
  .metric {
    padding: 0 18px;
    border-left: 1px solid var(--c-line);
  }
  .metric:first-child {
    padding-left: 0;
    border-left: 0;
  }
  .metric-label {
    margin-bottom: 3px;
    color: var(--c-text-3);
    font-size: var(--fs-small);
    white-space: nowrap;
  }
  .metric-value {
    color: var(--c-text);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-variant-numeric: tabular-nums;
    font-size: 30px;
    line-height: 1;
    font-weight: 600;
  }
  .metric-value.big { font-size: 34px; }
  .metric-value.warn { color: var(--c-warn); }
  .metric-value small {
    color: var(--c-text-3);
    font-size: var(--fs-emph);
    font-weight: 500;
  }
  .roster-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin: -2px -6px;
    padding: 2px 6px;
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
  }
  .roster-btn:hover,
  .roster-btn[aria-expanded='true'] {
    background: var(--c-raised);
    border-color: var(--c-line);
  }
  .roster-btn :global(svg) { color: var(--c-text-3); }

  .ao-roster {
    padding: 12px 16px 14px;
    border-top: 1px solid var(--c-line);
  }
  .roster-title {
    margin-bottom: 8px;
    color: var(--c-text-3);
    font-size: var(--fs-small);
  }
  .roster-empty {
    color: var(--c-text-3);
    font-size: var(--fs-body);
  }
  .chip-list {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 5px 10px;
    border: 1px solid var(--c-line);
    border-radius: var(--r-xs);
    background: var(--c-base);
    color: var(--c-text);
    font-size: var(--fs-meta);
  }
  .chip b {
    font-family: var(--font-mono);
    font-size: var(--fs-body);
  }
  .chip .who { color: var(--c-text-3); }
  .chip.police :global(svg) { color: var(--c-sched); }

  .idle-body {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 16px;
  }
  .idle-title {
    color: var(--c-text-2);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-section);
    font-weight: 600;
  }
  .idle-text {
    margin-top: 2px;
    color: var(--c-text-3);
    font-size: var(--fs-body);
  }

  /* Kind + status tags */
  .kind {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    color: var(--c-text-2);
    font-size: var(--fs-body);
    font-weight: 600;
    white-space: nowrap;
  }
  .kind::before {
    content: '';
    width: 8px;
    height: 8px;
    flex-shrink: 0;
    background: var(--k);
    transform: rotate(45deg);
  }
  .status {
    --s: #8d949c;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 22px;
    padding: 0 8px;
    border: 1px solid rgba(var(--s-rgb, 138, 144, 151), 0.4);
    background: rgba(var(--s-rgb, 138, 144, 151), 0.11);
    border-radius: var(--r-xs);
    color: var(--s);
    font-size: var(--fs-meta);
    font-weight: 700;
    white-space: nowrap;
  }
  .status::before {
    content: '';
    width: 6px;
    height: 6px;
    border-radius: 1px;
    background: currentColor;
  }
  .status.s-live { --s: #ff5d50; --s-rgb: 255, 93, 80; }
  .status.s-attack { --s: #f2a93b; --s-rgb: 242, 169, 59; }
  .status.s-sched { --s: #7aa7dc; --s-rgb: 122, 167, 220; }
  .status.s-draft { --s: #959ca5; --s-rgb: 154, 162, 171; }
  .status.s-done { --s: #46c98b; --s-rgb: 70, 201, 139; }
  .status.s-captured { --s: #d6a14a; --s-rgb: 214, 161, 74; }
  .status.s-ended::before { background: transparent; border: 1px solid currentColor; }

  /* Counter rail */
  .rail {
    display: grid;
    grid-template-columns: repeat(6, minmax(0, 1fr));
    margin-bottom: 14px;
    background: var(--glass-panel, var(--c-panel));
    border: 1px solid var(--c-line);
    border-radius: var(--r-panel);
  }
  .seg {
    position: relative;
    display: block;
    padding: 12px 16px 13px;
    background: transparent;
    border: 0;
    border-left: 1px solid var(--c-line);
    color: inherit;
    font: inherit;
    text-align: left;
  }
  .seg:first-child { border-left: 0; }
  .seg.clickable {
    cursor: pointer;
    transition: background 0.15s ease;
  }
  .seg.clickable:hover { background: var(--c-raised); }
  .seg.clickable:hover .seg-go { opacity: 1; }
  .seg-label {
    display: flex;
    align-items: center;
    gap: 7px;
    color: var(--c-text-2);
    font-size: var(--fs-small);
    font-weight: 600;
  }
  .seg-num {
    margin-top: 4px;
    color: var(--c-text);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-variant-numeric: tabular-nums;
    font-size: 34px;
    line-height: 1.05;
    font-weight: 700;
  }
  .seg-meta {
    color: var(--c-text-3);
    font-size: var(--fs-small);
  }
  .seg-go {
    position: absolute;
    right: 12px;
    top: 13px;
    color: var(--c-text-3);
    opacity: 0;
    transition: opacity 0.15s ease;
  }
  .seg.is-live .seg-num { color: var(--c-live); }
  .seg .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--c-live);
  }

  /* Panels */
  .dashboard-grid {
    display: grid;
    grid-template-columns: minmax(0, 1.7fr) minmax(300px, 1fr);
    gap: 14px;
    align-items: start;
  }
  .side-col {
    display: grid;
    gap: 14px;
  }
  .d-panel {
    background: var(--glass-panel, var(--c-panel));
    border: 1px solid var(--c-line);
    border-radius: var(--r-panel);
    overflow: hidden;
  }
  .d-panel-header {
    min-height: 48px;
    padding: 8px 14px 8px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    border-bottom: 1px solid var(--c-line);
  }
  .d-panel-title {
    margin: 0;
    color: var(--c-text);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-title);
    line-height: 1.1;
    font-weight: 700;
  }
  .panel-note {
    color: var(--c-text-3);
    font-size: var(--fs-small);
  }
  .link-btn {
    padding: 2px 0;
    background: none;
    border: 0;
    color: var(--c-action);
    font-size: var(--fs-body);
    font-weight: 600;
    cursor: pointer;
  }
  .link-btn:hover {
    color: var(--c-action-hover);
    text-decoration: underline;
    text-underline-offset: 3px;
  }
  .d-panel-body {
    padding: 4px 16px 6px;
  }

  /* Recent events table */
  .ev-table {
    width: 100%;
    border-collapse: collapse;
  }
  .ev-table th {
    height: 34px;
    padding: 0 var(--tbl-x);
    border-bottom: 1px solid var(--c-line);
    color: var(--text-muted);
    font-size: var(--fs-meta);
    font-weight: 600;
    text-align: left;
    white-space: nowrap;
    letter-spacing: 0;
  }
  .ev-table th:first-child,
  .ev-table td:first-child { padding-left: 16px; }
  .ev-table td {
    height: 50px;
    padding: var(--tbl-td-y) var(--tbl-x);
    border-bottom: 1px solid var(--c-line-soft);
    vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }
  .ev-table tbody tr:last-child td { border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }
  .ev-table tbody tr { transition: background 0.12s ease; }
  .ev-table tbody tr:hover { background: var(--c-raised); }
  .ev-table tbody tr td:first-child { box-shadow: inset 2px 0 0 transparent;
    font-variant-numeric: tabular-nums;
  }
  .ev-table tbody tr:hover td:first-child { box-shadow: inset 2px 0 0 var(--k);
    font-variant-numeric: tabular-nums;
  }
  .col-status { width: 1%; }
  .event-name {
    color: var(--c-text);
    font-size: var(--fs-body);
    font-weight: 600;
    line-height: 1.25;
  }
  .event-description {
    max-width: 420px;
    margin-top: 1px;
    overflow: hidden;
    color: var(--c-text-3);
    font-size: var(--fs-small);
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .event-time {
    color: var(--c-text-2);
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
    font-size: var(--fs-emph);
    white-space: nowrap;
  }
  .table-empty {
    padding: 40px 16px;
    color: var(--c-text-3);
    text-align: center;
  }

  /* System status */
  .sys-block {
    padding: 12px 0 10px;
    border-bottom: 1px solid var(--c-line-soft);
  }
  .sys-row {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 0;
    border-bottom: 1px solid var(--c-line-soft);
  }
  .sys-row.flat { padding: 0; border: 0; }
  .sys-row:last-child { border-bottom: 0; }
  .system-name {
    color: var(--c-text-2);
    font-size: var(--fs-body);
    font-weight: 500;
  }
  .system-value {
    color: var(--c-text);
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
    font-size: var(--fs-emph);
    font-weight: 600;
  }
  .system-value small {
    color: var(--c-text-3);
    font-size: var(--fs-body);
    font-weight: 500;
  }
  .system-value.cap { text-transform: capitalize; }
  .system-value.ok { color: var(--c-ok); }
  .slots {
    display: grid;
    gap: 2px;
    margin-top: 8px;
  }
  .slots i {
    height: 10px;
    background: var(--c-hover);
  }
  .slots i.used { background: #8ea9c8; }
  .slots i.live { background: var(--c-live); }
  .slots-legend {
    display: flex;
    gap: 14px;
    margin-top: 7px;
    color: var(--c-text-3);
    font-size: var(--fs-meta);
  }
  .slots-legend span {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .slots-legend i {
    width: 8px;
    height: 8px;
    display: inline-block;
    background: var(--c-hover);
  }
  .slots-legend i.lg-live { background: var(--c-live); }
  .slots-legend i.lg-used { background: #8ea9c8; }
  .progress {
    height: 4px;
    margin-top: 8px;
    border-radius: 1px;
    background: var(--c-hover);
    overflow: hidden;
  }
  .progress-bar {
    height: 100%;
    background: var(--c-action);
    color: var(--on-accent, inherit);
}

  /* Feature indicators */
  .feature-list {
    display: grid;
    grid-template-columns: 1fr 1fr;
  }
  .feature {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 11px 16px;
    border-bottom: 1px solid var(--c-line-soft);
  }
  .feature:nth-child(odd) { border-right: 1px solid var(--c-line-soft); }
  .feature:nth-last-child(-n + 2) { border-bottom: 0; }
  .feature-name {
    color: var(--c-text);
    font-size: var(--fs-body);
    font-weight: 500;
  }
  .feature-status {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    color: var(--c-ok);
    font-size: var(--fs-small);
    font-weight: 700;
  }
  .feature-status i {
    width: 8px;
    height: 8px;
    border-radius: 1px;
    background: currentColor;
  }
  .feature.off .feature-name,
  .feature.off .feature-status { color: var(--c-text-3); }
  .feature.off .feature-status i {
    background: transparent;
    border: 1px solid currentColor;
  }

  @media (prefers-reduced-motion: reduce) {
    .live-flag i { animation: none; }
  }
  @media (max-width: 1350px) {
    .op-body { grid-template-columns: 1fr; gap: 16px; align-items: start; }
    .dashboard-grid { grid-template-columns: 1fr; }
  }
  @media (max-width: 1150px) {
    .rail { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .seg:nth-child(4) { border-left: 0; }
    .seg:nth-child(n + 4) { border-top: 1px solid var(--c-line); }
    .op-head { flex-wrap: wrap; }
    .col-type { display: none; }
  }
</style>
