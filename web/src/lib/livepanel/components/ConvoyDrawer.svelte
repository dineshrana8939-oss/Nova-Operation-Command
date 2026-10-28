<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import DifficultyBadge from './DifficultyBadge.svelte';
  import tabletBg from '../../../assets/tablet-bg.jpg';

  export let convoy = null;
  export let isOpen = false;
  export let isPolice = false;
  export let isLeader = false;
  // See ConvoyTable's identical prop — role-permission-driven, display-only.
  export let canRegisterRoster = false;
  export let myGang = null;
  export let roster = null;
  export let isRegistered = false;
  export let formatScheduled = (ts) => ts;

  const dispatch = createEventDispatcher();

  function formatTime(seconds) {
    if (seconds == null) return '--:--';
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  function timerUrgency(seconds) {
    if (seconds == null) return 'neutral';
    if (seconds <= 30) return 'danger';
    if (seconds <= 90) return 'warn';
    return 'ok';
  }

  function kindIcon(kind) {
    if (kind === 'HOT_CARGO') return 'flame';
    if (kind === 'GANG_AIRDROP') return 'parachute';
    if (kind === 'GANG_RACE' || kind === 'TDM') return 'flag';
    if (kind === 'CONTAINER_WARS') return 'box';
    if (kind === 'GANG_TERRITORY') return 'pin';
    if (kind === 'CRACKDOWN') return 'shield';
    return 'truck';
  }

  function kindLabel(kind) {
    if (kind === 'HOT_CARGO') return 'Hot Cargo';
    if (kind === 'GANG_AIRDROP') return 'Gang Airdrop';
    if (kind === 'GANG_RACE') return 'Gang Rally Race';
    if (kind === 'TDM') return 'TDM Match';
    if (kind === 'CONTAINER_WARS') return 'Container Wars';
    if (kind === 'GANG_TERRITORY') return 'Territory Auction';
    if (kind === 'CRACKDOWN') return 'Operation Crackdown';
    return 'Convoy';
  }

  function close() {
    dispatch('close');
  }

  function handleKeydown(e) {
    if (e.key === 'Escape' && isOpen) close();
  }

  $: isUpcoming = convoy && (convoy.status === 'DRAFT' || convoy.status === 'SCHEDULED' || convoy.status === 'NOT_STARTED');
  $: isActive = convoy && ['STARTING', 'ACTIVE', 'CHECKPOINT', 'UNDER_ATTACK', 'DELIVERY'].includes(convoy.status);
  $: maxGangs = convoy?.maxGangParticipants || 5;
  $: maxPolice = convoy?.maxPoliceParticipants || 20;
  $: regMode = convoy?.registrationMode || 'ROSTER';
  $: regCount = isPolice ? (convoy?.policeRegisteredCount || 0) : (convoy?.gangParticipants || (isRegistered ? 1 : 0));
  $: capLimit = isPolice ? maxPolice : maxGangs;
</script>

<svelte:window on:keydown={handleKeydown} />

{#if isOpen && convoy}
  <!-- Backdrop overlay -->
  <div class="drawer-backdrop" on:click={close}></div>

  <!-- Drawer panel -->
  <aside class="drawer-panel" style="--tablet-bg-img: url('{tabletBg}');" aria-label="Event Details">
    <!-- Header -->
    <div class="drawer-header">
      <div class="header-left">
        <span class="kind-chip">
          <Icon name={kindIcon(convoy.kind)} size={13} />
          <span>{kindLabel(convoy.kind)}</span>
        </span>
        <h2 class="drawer-title">{convoy.name}</h2>
      </div>
      <button class="drawer-close" on:click={close} title="Close drawer (ESC)">
        <Icon name="close" size={16} />
      </button>
    </div>

    <!-- Body -->
    <div class="drawer-body">
      <!-- Status & Badges -->
      <div class="status-strip">
        <StatusBadge status={convoy.status} />
        <DifficultyBadge difficulty={convoy.difficulty || 'MEDIUM'} />
      </div>

      <!-- Description -->
      {#if convoy.shortDescription}
        <div class="desc-box">
          <p>{convoy.shortDescription}</p>
        </div>
      {/if}

      <!-- Core Spec Tiles -->
      <div class="spec-grid">
        <div class="spec-tile">
          <span class="spec-label">{convoy.kind === 'GANG_RACE' ? 'Prize Stakes' : (convoy.kind === 'TDM' ? 'Match Format' : 'Cargo Type')}</span>
          <div class="spec-val cargo">
            <Icon name={(convoy.kind === 'GANG_RACE' || convoy.kind === 'TDM') ? 'flag' : 'box'} size={13} />
            <span>{convoy.kind === 'TDM' ? (convoy.tdm?.matchFormat === 'TOURNAMENT' ? 'Tournament' : 'Standard') : (convoy.cargo?.type || (convoy.kind === 'GANG_RACE' ? 'Stakes & Cash' : 'Standard'))}</span>
          </div>
        </div>

        <div class="spec-tile">
          <span class="spec-label">{isActive ? 'Event Mode' : 'Departure'}</span>
          <div class="spec-val">
            {#if isActive}
              <span class="live-active-tag">● Live In Progress</span>
            {:else if convoy.scheduledAt}
              <Icon name="calendar" size={13} />
              <span>{formatScheduled(convoy.scheduledAt)}</span>
            {:else}
              <span class="muted-val">Unscheduled</span>
            {/if}
          </div>
        </div>

        <div class="spec-tile">
          <span class="spec-label">{isPolice ? 'Police Escorts' : 'Gang Capacity'}</span>
          <div class="spec-val">
            <span class="cap-val">{regCount} <span class="cap-max">/ {capLimit}</span></span>
          </div>
          <div class="progress-bar">
            <div class="progress-fill" style="width: {Math.min(100, Math.round((regCount / capLimit) * 100))}%"></div>
          </div>
        </div>

        {#if isActive && convoy.kind === 'TDM' && convoy.tdm}
          <div class="spec-tile">
            <span class="spec-label">Live Match Score</span>
            <div class="spec-val progress-val">
              <span>{convoy.tdm.gangLabelA} <strong>{convoy.tdm.scoreA}</strong> — <strong>{convoy.tdm.scoreB}</strong> {convoy.tdm.gangLabelB}</span>
            </div>
          </div>
        {:else if isActive && convoy.totalRoutePoints}
          <div class="spec-tile">
            <span class="spec-label">Route Progress</span>
            <div class="spec-val progress-val">
              <span>{convoy.currentRouteIndex || 0} / {convoy.totalRoutePoints} Waypoints</span>
            </div>
            <div class="progress-bar">
              <div class="progress-fill" style="width: {Math.min(100, Math.round(((convoy.currentRouteIndex || 0) / convoy.totalRoutePoints) * 100))}%"></div>
            </div>
          </div>
        {/if}
      </div>

      <!-- Live Timers (If active) -->
      {#if isActive && (convoy.deliveryTimeRemaining != null || convoy.checkpointTimeRemaining != null)}
        <div class="section-card">
          <span class="section-card-title">Live Operational Clocks</span>
          <div class="timer-grid">
            {#if convoy.checkpointTimeRemaining != null}
              <div class="timer-box urgency-{timerUrgency(convoy.checkpointTimeRemaining)}">
                <div class="timer-header">
                  <Icon name="shield" size={13} />
                  <span>Checkpoint</span>
                </div>
                <span class="timer-digits">{formatTime(convoy.checkpointTimeRemaining)}</span>
              </div>
            {/if}
            {#if convoy.deliveryTimeRemaining != null}
              <div class="timer-box urgency-{timerUrgency(convoy.deliveryTimeRemaining)}">
                <div class="timer-header">
                  <Icon name={convoy.kind === 'TDM' ? 'flag' : 'clock'} size={13} />
                  <span>{convoy.kind === 'TDM' ? 'Match Clock' : 'Delivery Limit'}</span>
                </div>
                <span class="timer-digits">{formatTime(convoy.deliveryTimeRemaining)}</span>
              </div>
            {/if}
          </div>
        </div>
      {/if}

      <!-- Gang / Escort Standing Info -->
      {#if !isPolice && myGang}
        <div class="section-card">
          <span class="section-card-title">Your Gang Status</span>
          <div class="gang-status-row">
            <div class="gang-info">
              <span class="gang-name">{roster?.gangLabel || roster?.gangName || myGang.label || myGang.name || 'Your Gang'}</span>
              <span class="gang-sub">
                {roster?.members?.length || 0} Total Members in Gang
              </span>
            </div>
            {#if isRegistered}
              <span class="reg-pill"><Icon name="check" size={11} /> Gang Registered</span>
            {:else}
              <span class="unreg-pill">Not Registered</span>
            {/if}
          </div>
        </div>
      {:else if isPolice}
        <div class="section-card">
          <span class="section-card-title">Escort Department</span>
          {#if convoy.kind === 'CONVOY'}
            <p class="police-hint">On-duty officers are on escort duty automatically — there is nothing to sign up for.</p>
          {:else if convoy.kind === 'GANG_RACE' || convoy.kind === 'CONTAINER_WARS'}
            <p class="police-hint">Officers join this event at its registration ped, not from this panel.</p>
          {:else}
            <p class="police-hint">This event is not joined from this panel.</p>
          {/if}
        </div>
      {/if}
    </div>

    <!-- Actions Footer -->
    <div class="drawer-footer">
      <button class="btn btn-outline" on:click={close}>Close</button>

      {#if !isPolice && canRegisterRoster && isUpcoming && regMode !== 'NONE'}
        <button class="btn" class:btn-primary={!(regMode === 'GANG' && isRegistered)} class:btn-danger={regMode === 'GANG' && isRegistered} on:click={() => { close(); dispatch('register', convoy); }}>
          <Icon name={regMode === 'GANG' ? (isRegistered ? 'close' : 'plus') : (isRegistered ? 'edit' : 'plus')} size={13} />
          <span>{regMode === 'GANG' ? (isRegistered ? 'Unregister Gang' : 'Register Gang') : (isRegistered ? 'Edit Roster' : 'Register Gang')}</span>
        </button>
      {:else if !isPolice && isActive && convoy.kind === 'TDM'}
        <!-- No live join/leave for a running TDM match — registration is
             locked in before it starts (Runtime.leaveGang/joinGang know
             nothing about tdm_runtime.lua's own participant table, so this
             button would be a confusing no-op mid-match rather than
             actually pulling the player out of combat). -->
        <span class="police-hint">Match is live — registration is locked until it ends.</span>
      {:else if !isPolice && isActive && convoy.gangPvp}
        {#if convoy.joined}
          <button class="btn btn-danger" on:click={() => dispatch('leave', convoy.id)}>
            Leave Event
          </button>
        {:else}
          <button class="btn btn-primary" on:click={() => dispatch('join', convoy.id)}>
            <Icon name="crosshair" size={13} />
            <span>Join Event</span>
          </button>
        {/if}
      {/if}
    </div>
  </aside>
{/if}

<style>
  .drawer-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.2);
    z-index: 200;
    animation: fadeIn 0.15s ease-out;
  }

  @keyframes fadeIn {
    from { opacity: 0; }
    to { opacity: 1; }
  }

  .drawer-panel {
    position: fixed;
    top: 0;
    right: 0;
    bottom: 0;
    width: 460px;
    max-width: 90vw;
    background-color: var(--lt-07090d, #07090d);
    /* the first layer is the theme's background shade / gradient (Settings → Appearance); invisible for Graphite */
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent)));
    background-size: cover, cover;
    background-position: center top, center center;
    background-repeat: no-repeat, no-repeat;
    border-left: 1px solid rgba(170, 212, 255, 0.3);
    display: flex;
    flex-direction: column;
    z-index: 201;
    box-shadow: -12px 0 40px rgba(0, 0, 0, 0.65);
    animation: slideIn 0.22s cubic-bezier(0.16, 1, 0.3, 1) both;
  }

  @keyframes slideIn {
    from { transform: translateX(100%); }
    to { transform: translateX(0); }
  }

  .drawer-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    padding: 16px 20px;
    border-bottom: 1px solid rgba(110, 160, 215, 0.22);
    background: rgba(var(--ltc-8-12-18, 8, 12, 18), 0.6);
    gap: 12px;
  }

  .header-left {
    display: flex;
    flex-direction: column;
    gap: 7px;
    min-width: 0;
  }

  .kind-chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 9px;
    border-radius: var(--radius-sm, 5px);
    background: var(--c-action);
    border: 1px solid var(--c-action);
    color: var(--on-accent);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    width: fit-content;
  }

  .drawer-title {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-title);
    font-weight: var(--fw-heading);
    color: var(--text-main);
    margin: 0;
    line-height: 1.3;
    word-break: break-word;
  }

  .drawer-close {
    background: transparent;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    color: var(--text-dim);
    width: 30px;
    height: 30px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease;
  }

  .drawer-close:hover {
    color: var(--tablet-danger);
    border-color: var(--tablet-danger);
    background: var(--c-hover);
  }

  .drawer-body {
    flex: 1;
    overflow-y: auto;
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    background: transparent;
  }

  .status-strip {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .desc-box {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 13px 14px;
    font-size: var(--fs-body);
    color: var(--text-dim);
    line-height: 1.6;
  }

  .desc-box p {
    margin: 0;
  }

  .spec-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
  }

  .spec-tile {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 11px 12px;
    display: flex;
    flex-direction: column;
    gap: 5px;
    min-width: 0;
  }

  .spec-label {
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    color: var(--text-dim);
  }

  .spec-val {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-body);
    font-weight: var(--fw-value);
    color: var(--text-main);
    min-width: 0;
  }

  .spec-val.cargo {
    color: var(--accent-primary-light);
  }

  .muted-val {
    color: var(--text-dim);
    font-weight: var(--fw-body);
  }

  .live-active-tag {
    color: var(--tablet-success);
    font-weight: 600;
    font-size: var(--fs-meta);
  }

  .cap-val {
    font-size: var(--fs-body);
  }

  .cap-max {
    color: var(--text-dim);
    font-size: var(--fs-small);
  }

  .progress-val {
    color: var(--tablet-success);
    font-size: var(--fs-small);
    font-weight: var(--fw-value);
  }

  .progress-bar {
    width: 100%;
    height: 5px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    border-radius: 5px;
    overflow: hidden;
    margin-top: 4px;
  }

  .progress-fill {
    height: 100%;
    background: var(--accent-primary);
    border-radius: var(--r-panel);
    transition: width 0.3s ease;
    color: var(--on-accent, inherit);
}

  .section-card {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 15px;
    display: flex;
    flex-direction: column;
    gap: 11px;
  }

  .section-card-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-label);
  }

  .timer-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px;
  }

  .timer-box {
    background: var(--c-raised);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 9px 10px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .timer-header {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }

  .timer-digits {
    font-size: var(--fs-title);
    font-weight: var(--fw-value);
    line-height: 1.15;
  }

  .timer-box.urgency-ok { border-color: rgba(48, 209, 88, 0.45); color: var(--tablet-success); }
  .timer-box.urgency-warn { border-color: rgba(255, 200, 87, 0.45); color: var(--tablet-warn); }
  .timer-box.urgency-danger { border-color: rgba(var(--red-rgb), 0.5); color: var(--tablet-danger); }

  .gang-status-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }

  .gang-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .gang-name {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
  }

  .gang-sub {
    font-size: var(--fs-small);
    color: var(--text-dim);
  }

  .reg-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 9px;
    border-radius: var(--radius-sm, 5px);
    background: rgb(48, 209, 88);
    border: 1px solid rgb(48, 209, 88);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
  }

  .unreg-pill {
    display: inline-flex;
    align-items: center;
    padding: 3px 9px;
    border-radius: var(--radius-sm, 5px);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.07);
    border: 1px solid var(--tablet-border);
    color: var(--text-dim);
    font-size: var(--fs-meta);
  }

  .police-alert {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 9px 11px;
    border-radius: var(--radius-sm, 5px);
    font-size: var(--fs-small);
    line-height: 1.45;
  }

  .police-alert.ok {
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--tablet-success);
    border-left: 3px solid rgb(48, 209, 88);}

  .police-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin: 0;
    line-height: 1.45;
  }

  .drawer-footer {
    padding: 15px 20px;
    border-top: 1px solid rgba(110, 160, 215, 0.22);
    background: rgba(var(--ltc-8-12-18, 8, 12, 18), 0.65);
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 10px;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 9px 16px;
    border-radius: var(--radius-sm, 5px);
    font-family: var(--font-ui);
    font-size: var(--fs-body);
    font-weight: 700;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
    border: 1px solid var(--tablet-border-strong);
    background: var(--tablet-panel-alt);
    color: var(--text-main);
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

  .btn-primary:disabled {
    opacity: 0.45;
    cursor: not-allowed;
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
</style>
