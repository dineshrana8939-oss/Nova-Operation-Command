<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import DifficultyBadge from './DifficultyBadge.svelte';

  export let convoy;
  export let isPolice = false;
  export let isLeader = false;
  export let isRegistered = false;
  export let registeredCount = 0;
  export let formatScheduled = (ts) => ts;

  const dispatch = createEventDispatcher();

  function kindIcon(kind) {
    if (kind === 'HOT_CARGO') return 'flame';
    if (kind === 'GANG_AIRDROP') return 'parachute';
    if (kind === 'GANG_RACE' || kind === 'TDM') return 'flag';
    return 'truck';
  }

  function kindLabel(kind) {
    if (kind === 'HOT_CARGO') return 'Hot Cargo';
    if (kind === 'GANG_AIRDROP') return 'Gang Airdrop';
    if (kind === 'GANG_RACE') return 'Gang Rally Race';
    if (kind === 'TDM') return 'TDM Match';
    return 'Convoy';
  }

  $: maxGangs = convoy?.maxGangParticipants || 5;
  $: maxPolice = convoy?.maxPoliceParticipants || 20;
  $: isFull = !isPolice ? registeredCount >= maxGangs : (convoy?.policeRegisteredCount || 0) >= maxPolice;
</script>

{#if convoy}
  <div class="featured-card">
    <div class="featured-glow"></div>
    <div class="featured-inner">
      <div class="featured-top-bar">
        <div class="eyebrow">
          <span class="live-dot"></span>
          <span class="eyebrow-text">Priority Operation</span>
          <span class="kind-tag">
            <Icon name={kindIcon(convoy.kind)} size={12} />
            <span>{kindLabel(convoy.kind)}</span>
          </span>
        </div>
        <div class="top-status">
          <StatusBadge
            status={convoy.status === 'DRAFT' || convoy.status === 'SCHEDULED' ? (isFull ? 'FULL' : 'REGISTRATION_OPEN') : convoy.status}
          />
        </div>
      </div>

      <div class="featured-content">
        <div class="title-col">
          <h2 class="featured-title">{convoy.name}</h2>
          {#if convoy.shortDescription}
            <p class="featured-desc">{convoy.shortDescription}</p>
          {/if}
        </div>

        <div class="meta-grid">
          <div class="meta-item">
            <span class="meta-label">Cargo</span>
            <div class="meta-value cargo-val">
              <Icon name="box" size={13} />
              <span>{convoy.cargo?.type || 'Standard'}</span>
            </div>
          </div>

          <div class="meta-item">
            <span class="meta-label">Difficulty</span>
            <div class="meta-value">
              <DifficultyBadge difficulty={convoy.difficulty || 'MEDIUM'} />
            </div>
          </div>

          <div class="meta-item">
            <span class="meta-label">Departure</span>
            <div class="meta-value date-val">
              <Icon name="calendar" size={13} />
              <span>{convoy.scheduledAt ? formatScheduled(convoy.scheduledAt) : 'Unscheduled'}</span>
            </div>
          </div>

          <div class="meta-item">
            <span class="meta-label">{isPolice ? 'Escort Slots' : 'Gang Roster'}</span>
            <div class="meta-value count-val">
              <span class="count-num">
                {isPolice ? (convoy.policeRegisteredCount || 0) : registeredCount}
                <span class="count-max">/{isPolice ? maxPolice : maxGangs}</span>
              </span>
              <div class="mini-bar">
                <div
                  class="mini-bar-fill"
                  style="width: {Math.min(100, Math.round(((isPolice ? (convoy.policeRegisteredCount || 0) : registeredCount) / (isPolice ? maxPolice : maxGangs)) * 100))}%"
                ></div>
              </div>
            </div>
          </div>
        </div>

        <div class="featured-actions">
          <button class="btn btn-outline" on:click={() => dispatch('viewDetails', convoy)}>
            <Icon name="eye" size={13} />
            <span>View Details</span>
          </button>

          {#if !isPolice && isLeader && (convoy.status === 'DRAFT' || convoy.status === 'SCHEDULED')}
            <button class="btn btn-primary" on:click={() => dispatch('register', convoy)}>
              <Icon name={isRegistered ? 'edit' : 'plus'} size={13} />
              <span>{isRegistered ? 'Edit Roster' : 'Register Gang'}</span>
            </button>
          {:else if !isPolice && convoy.status === 'ACTIVE' && convoy.gangPvp}
            {#if convoy.joined}
              <button class="btn btn-danger" on:click={() => dispatch('leave', convoy.id)}>
                Leave Convoy
              </button>
            {:else}
              <button class="btn btn-primary" on:click={() => dispatch('join', convoy.id)}>
                <Icon name="crosshair" size={13} />
                <span>Join Event</span>
              </button>
            {/if}
          {/if}
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  // NOTE: this card is no longer rendered by the Convoys tab — its job is done
  // by the priority-row highlight in ConvoyTable (see priorityConvoyId there).
  // Kept styled to match the tablet theme so that if it's ever reused, it
  // doesn't reintroduce the old pure-black/glow palette.

  .featured-card {
    position: relative;
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md, 3px);
    margin-bottom: 20px;
    overflow: hidden;
    box-shadow: var(--shadow-soft);
    transition: border-color 0.2s ease;
  }

  .featured-card:hover {
    border-color: var(--tablet-border-strong);
  }

  .featured-glow {
    position: absolute;
    top: 0;
    left: 0;
    bottom: 0;
    width: 3px;
    background: var(--accent-primary);
    color: var(--on-accent, inherit);
}

  .featured-inner {
    padding: 18px 22px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .featured-top-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }

  .eyebrow {
    display: inline-flex;
    align-items: center;
    gap: 8px;
  }

  .live-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--accent-primary, #c9ced4);
    box-shadow: none;
    animation: none;
    color: var(--on-accent, inherit);
}

  @keyframes livePulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.4; transform: scale(1.3); }
  }

  .eyebrow-text {
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--accent-primary-light);
  }

  .kind-tag {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: var(--radius-sm, 5px);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    color: var(--text-label);
    letter-spacing: 0.02em;
  }

  .featured-content {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    flex-wrap: wrap;
  }

  .title-col {
    min-width: 220px;
    flex: 1 1 240px;
  }

  .featured-title {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-section);
    font-weight: var(--fw-heading);
    color: var(--text-main);
    margin: 0;
    line-height: 1.3;
  }

  .featured-desc {
    font-size: var(--fs-body);
    color: var(--text-dim);
    margin: 5px 0 0;
    line-height: 1.5;
    max-width: 480px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .meta-grid {
    display: flex;
    align-items: center;
    gap: 20px;
    flex-wrap: wrap;
  }

  .meta-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .meta-label {
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-eceef0, #eceef0);
  }

  .meta-value {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff);
  }

  .cargo-val {
    color: var(--lt-eceef0, #eceef0);
    font-weight: 700;
    font-family: var(--font-mono);
  }

  .date-val {
    color: var(--lt-ffffff, #ffffff);
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    font-weight: 600;
  }

  .count-val {
    flex-direction: column;
    align-items: flex-start;
    gap: 3px;
  }

  .count-num {
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
  }

  .count-max {
    color: var(--lt-eceef0, #eceef0);
    font-size: var(--fs-small);
    font-weight: 600;
  }

  .mini-bar {
    width: 68px;
    height: 5px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-radius: 5px;
    overflow: hidden;
  }

  .mini-bar-fill {
    height: 100%;
    background: var(--accent-primary, #c9ced4);
    border-radius: var(--r-panel);
    transition: width 0.3s ease;
    color: var(--on-accent, inherit);
}

  .featured-actions {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 8px 16px;
    border-radius: var(--r-ctl);
    font-size: var(--fs-body);
    font-weight: 700;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
    white-space: nowrap;
    border: 1px solid transparent;
  }

  .btn-outline {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border-color: #2e3a52;
    color: var(--lt-ffffff, #ffffff);
  }

  .btn-outline:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    border-color: #4b5a7a;
    color: var(--lt-ffffff, #ffffff);
  }

  .btn-primary {
    background: var(--accent-primary, #c9ced4);
    color: var(--on-accent, #ffffff);
    box-shadow: none;
  }

  .btn-primary:hover:not(:disabled) {
    background: #8d949c;
    box-shadow: none;
    transform: translateY(-1px);
  }

  .btn-primary:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    box-shadow: none;
  }

  .btn-danger {
    background: rgba(217, 115, 111, 0.16);
    border-color: rgba(217, 115, 111, 0.4);
    color: var(--lt-ff8a80, #ff8a80);
  }

  .btn-danger:hover {
    background: #d9736f;
    color: var(--lt-ffffff, #ffffff);
  }

  @media (max-width: 900px) {
    .featured-content {
      flex-direction: column;
      align-items: flex-start;
      gap: 14px;
    }
    .meta-grid {
      width: 100%;
      justify-content: space-between;
    }
    .featured-actions {
      width: 100%;
      justify-content: flex-end;
    }
  }
</style>
