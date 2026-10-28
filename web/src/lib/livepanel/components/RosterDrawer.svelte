<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import { avatarColor, initials } from '../../util/avatar.js';
  import tabletBg from '../../../assets/tablet-bg.jpg';

  export let isOpen = false;
  export let convoy = null;
  export let rosterEntry = null;
  export let members = [];
  export let draftSet = new Set();
  export let saving = false;
  export let error = '';
  export let formatScheduled = (ts) => ts;

  const dispatch = createEventDispatcher();

  let memberSearch = '';
  let memberFilter = 'all'; // 'all', 'online', 'offline'

  function close() {
    dispatch('cancel');
  }

  function handleKeydown(e) {
    if (e.key === 'Escape' && isOpen) close();
  }

  $: maxCapacity = rosterEntry?.maxGangParticipants || convoy?.maxGangParticipants || 5;
  $: selectedCount = draftSet.size;
  $: isAtCap = selectedCount >= maxCapacity;
  $: isAlreadyRegistered = !!(rosterEntry?.roster && rosterEntry.roster.length > 0);

  // Filter members on the left
  $: filteredMembers = members.filter((m) => {
    if (memberFilter === 'online' && !m.online) return false;
    if (memberFilter === 'offline' && m.online) return false;
    if (memberSearch.trim()) {
      const q = memberSearch.toLowerCase().trim();
      const matchName = m.name?.toLowerCase().includes(q);
      const matchRank = m.rank?.toLowerCase().includes(q);
      if (!matchName && !matchRank) return false;
    }
    return true;
  });

  // Selected members list on the right
  $: selectedMembers = members.filter((m) => draftSet.has(m.identifier));

  function toggle(identifier) {
    const isPicked = draftSet.has(identifier);
    if (!isPicked && isAtCap) {
      return;
    }
    dispatch('toggleMember', { identifier });
  }

  function removeSelected(identifier) {
    dispatch('toggleMember', { identifier });
  }

  function clearAll() {
    dispatch('clear');
  }

  function handleSave() {
    dispatch('save');
  }
</script>

<svelte:window on:keydown={handleKeydown} />

{#if isOpen && convoy}
  <div class="roster-backdrop" on:click={close}></div>

  <aside class="roster-panel" style="--tablet-bg-img: url('{tabletBg}');" aria-label="Prepare Event Roster">
    <!-- Top Header -->
    <div class="roster-header">
      <div class="header-main">
        <div class="eyebrow">
          <span class="eyebrow-chip">{convoy.kind === 'GANG_RACE' ? 'Rally Driver Squad' : 'Mission Crew Deployment'}</span>
          <span class="meta-tag">{convoy.kind === 'GANG_RACE' ? 'STREET RACE' : (convoy.cargo?.type || 'CARGO')} • {convoy.difficulty || 'MEDIUM'}</span>
          {#if convoy.scheduledAt}
            <span class="meta-time">{formatScheduled(convoy.scheduledAt)}</span>
          {/if}
        </div>
        <h2 class="mission-title">{convoy.name}</h2>
        <p class="mission-sub">{convoy.kind === 'GANG_RACE' ? 'Select the designated driver(s) from your gang to represent you on the starting grid.' : 'Select the operative squad from your gang authorized for this tactical operation.'}</p>
      </div>

      <button class="btn-close" on:click={close} title="Close (ESC)">
        <Icon name="close" size={16} />
      </button>
    </div>

    <!-- Error message if any -->
    {#if error}
      <div class="error-banner">
        <Icon name="warning" size={14} />
        <span>{error}</span>
      </div>
    {/if}

    <!-- Two-Column Body -->
    <div class="roster-columns">
      <!-- LEFT COLUMN: All Gang Members -->
      <div class="column col-members">
        <div class="column-header">
          <div class="col-title-group">
            <span class="col-title">Gang Roster</span>
            <span class="badge-count">{members.length} Total</span>
          </div>

          <!-- Filters: All | Online | Offline -->
          <div class="filter-pills">
            <button
              class="pill-btn"
              class:active={memberFilter === 'all'}
              on:click={() => (memberFilter = 'all')}
            >
              All
            </button>
            <button
              class="pill-btn"
              class:active={memberFilter === 'online'}
              on:click={() => (memberFilter = 'online')}
            >
              Online ({members.filter((m) => m.online).length})
            </button>
            <button
              class="pill-btn"
              class:active={memberFilter === 'offline'}
              on:click={() => (memberFilter = 'offline')}
            >
              Offline ({members.filter((m) => !m.online).length})
            </button>
          </div>
        </div>

        <!-- Search input -->
        <div class="search-wrap">
          <Icon name="search" size={13} />
          <input
            type="text"
            placeholder="Search gang members..."
            bind:value={memberSearch}
          />
          {#if memberSearch}
            <button class="clear-btn" on:click={() => (memberSearch = '')}>
              <Icon name="close" size={12} />
            </button>
          {/if}
        </div>

        <!-- Member items list -->
        <div class="members-scroll">
          {#if filteredMembers.length === 0}
            <div class="empty-state-card">
              <Icon name="users" size={24} />
              <p>No members found matching your filter.</p>
            </div>
          {:else}
            {#each filteredMembers as m (m.identifier)}
              {@const isSelected = draftSet.has(m.identifier)}
              {@const isDisabled = !isSelected && isAtCap}
              <div
                class="member-item"
                class:selected={isSelected}
                class:disabled={isDisabled}
                on:click={() => toggle(m.identifier)}
                role="button"
                tabindex="0"
                on:keydown={(e) => e.key === 'Enter' && toggle(m.identifier)}
              >
                <!-- Checkbox state -->
                <div class="select-checkbox" class:checked={isSelected}>
                  {#if isSelected}
                    <Icon name="check" size={12} />
                  {/if}
                </div>

                <!-- Avatar -->
                <div class="avatar-wrap">
                  <span class="avatar" style="background: {avatarColor(m.name || m.identifier)}">
                    {initials(m.name || m.identifier)}
                  </span>
                  <span class="status-indicator" class:online={m.online}></span>
                </div>

                <!-- Member Info -->
                <div class="member-details">
                  <span class="member-name">{m.name}</span>
                  <div class="member-meta">
                    <span class="member-role">{m.rank || 'Member'}</span>
                    {#if m.isLeader || m.identifier === rosterEntry?.leaderIdentifier}
                      <span class="leader-badge">LEADER</span>
                    {/if}
                    <span class="online-status" class:online={m.online}>
                      {m.online ? '● Online' : 'Offline'}
                    </span>
                  </div>
                </div>

                <!-- Cap warning tag if disabled -->
                {#if isDisabled}
                  <span class="cap-tag">Cap Reached</span>
                {/if}
              </div>
            {/each}
          {/if}
        </div>
      </div>

      <!-- RIGHT COLUMN: Selected Squad -->
      <div class="column col-squad">
        <div class="column-header">
          <div class="col-title-group">
            <span class="col-title">Selected Crew</span>
            <span class="badge-count" class:at-cap={isAtCap}>
              {selectedCount} / {maxCapacity} Max
            </span>
          </div>

          <!-- Capacity Bar -->
          <div class="cap-meter">
            <div
              class="cap-meter-fill"
              class:full={isAtCap}
              style="width: {Math.min(100, Math.round((selectedCount / maxCapacity) * 100))}%"
            ></div>
          </div>
        </div>

        {#if isAtCap}
          <div class="cap-notice">
            <Icon name="info" size={13} />
            <span>Roster is at max capacity ({maxCapacity}/{maxCapacity}). Deselect a member to swap.</span>
          </div>
        {/if}

        <div class="squad-scroll">
          {#if selectedMembers.length === 0}
            <div class="empty-crew-card">
              <div class="crew-radar-icon">
                <Icon name="users" size={28} />
              </div>
              <h4 class="empty-crew-title">No Crew Members Selected</h4>
              <p class="empty-crew-sub">
                Select operatives from the gang list on the left to build your tactical mission squad.
              </p>
            </div>
          {:else}
            <div class="squad-list">
              {#each selectedMembers as m, idx (m.identifier)}
                <div class="squad-card">
                  <span class="squad-slot">#{idx + 1}</span>
                  <span class="avatar-mini" style="background: {avatarColor(m.name || m.identifier)}">
                    {initials(m.name || m.identifier)}
                  </span>
                  <div class="squad-name-col">
                    <span class="squad-name">{m.name}</span>
                    <span class="squad-status" class:online={m.online}>
                      {m.online ? 'Online' : 'Offline'}
                    </span>
                  </div>
                  <button
                    class="btn-remove-squad"
                    title="Remove from roster"
                    on:click|stopPropagation={() => removeSelected(m.identifier)}
                  >
                    <Icon name="close" size={13} />
                  </button>
                </div>
              {/each}
            </div>
          {/if}
        </div>
      </div>
    </div>

    <!-- Sticky Footer -->
    <div class="roster-footer">
      <div class="footer-left">
        {#if selectedCount > 0}
          <button class="btn btn-ghost" on:click={clearAll}>
            Clear Selection
          </button>
        {/if}
      </div>

      <div class="footer-right">
        <button class="btn btn-outline" disabled={saving} on:click={close}>
          Cancel
        </button>

        {#if isAlreadyRegistered}
          <button
            class="btn btn-danger"
            disabled={saving}
            on:click={() => dispatch('unregisterAll')}
            title="Unregister entire gang from this event"
          >
            Unregister Gang
          </button>
        {/if}

        <button
          class="btn btn-primary btn-save"
          disabled={saving || selectedCount === 0}
          on:click={handleSave}
        >
          <Icon name="check" size={14} />
          <span>{saving ? 'Saving Deployment...' : 'Save Roster'}</span>
        </button>
      </div>
    </div>
  </aside>
{/if}

<style>
  /* No backdrop-filter here — animating opacity while a blur filter is
     active forces a full-screen blur recompute every single frame of the
     fade, which is real, noticeable jank on CEF (the freeze this drawer
     used to cause on open). A flat darker scrim gives the same visual
     separation without the per-frame cost. */
  .roster-backdrop {
    position: fixed;
    inset: 0;
    background: var(--scrim-heavy, rgba(0, 0, 0, 0.82));
    z-index: 300;
    animation: fadeIn 0.15s ease-out;
  }

  @keyframes fadeIn {
    from { opacity: 0; }
    to { opacity: 1; }
  }

  .roster-panel {
    position: fixed;
    top: 0;
    right: 0;
    bottom: 0;
    width: 820px;
    max-width: 95vw;
    background-color: var(--lt-07090d, #07090d);
    /* the first layer is the theme's background shade / gradient (Settings → Appearance); invisible for Graphite */
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent)));
    background-size: cover;
    background-position: center top;
    background-repeat: no-repeat;
    border-left: 1px solid rgba(104, 152, 208, 0.3);
    display: flex;
    flex-direction: column;
    z-index: 301;
    box-shadow: -16px 0 40px rgba(0, 0, 0, 0.6);
    animation: slideInRoster 0.24s cubic-bezier(0.16, 1, 0.3, 1) both;
  }

  @keyframes slideInRoster {
    from { transform: translateX(100%); }
    to { transform: translateX(0); }
  }

  .roster-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    padding: 18px 24px;
    border-bottom: 1px solid rgba(110, 160, 215, 0.2);
    background: rgba(var(--ltc-8-12-18, 8, 12, 18), 0.65);
    gap: 16px;
  }

  .header-main {
    display: flex;
    flex-direction: column;
    gap: 7px;
  }

  .eyebrow {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .eyebrow-chip {
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: var(--accent-primary-light);
  }

  .meta-tag {
    padding: 3px 9px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    color: var(--text-dim);
  }

  .meta-time {
    font-size: var(--fs-small);
    color: var(--text-label);
  }

  .mission-title {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-section);
    font-weight: var(--fw-heading);
    color: var(--text-main);
    margin: 0;
    line-height: 1.3;
  }

  .mission-sub {
    font-size: var(--fs-body);
    color: var(--text-dim);
    margin: 0;
    line-height: 1.5;
  }

  .btn-close {
    background: transparent;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    color: var(--text-dim);
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease;
  }

  .btn-close:hover {
    color: var(--tablet-danger);
    border-color: var(--tablet-danger);
    background: var(--c-hover);
  }

  .error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 11px 24px;
    background: var(--c-raised);
    border-bottom: 1px solid rgba(var(--red-rgb), 0.4);
    color: var(--tablet-danger);
    font-size: var(--fs-body);
    font-weight: 600;
    border-left: 3px solid #ef4444;}

  /* Two-column Roster Body */
  .roster-columns {
    flex: 1;
    min-height: 0;
    display: grid;
    grid-template-columns: 1fr 1fr;
    grid-template-rows: minmax(0, 1fr);   /* the row is the drawer height, not the height of its content: a long roster scrolls inside its column */
    overflow: hidden;
  }

  .column {
    display: flex;
    flex-direction: column;
    min-height: 0;
    padding: 16px 20px;
    overflow: hidden;
  }

  .col-members {
    border-right: 1px solid rgba(110, 160, 215, 0.18);
    background: transparent;
  }

  .col-squad {
    background: transparent;
  }

  .column-header {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-bottom: 12px;
  }

  .col-title-group {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .col-title {
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main);
  }

  .badge-count {
    font-size: var(--fs-meta);
    font-weight: var(--fw-value);
    color: var(--text-dim);
    background: var(--tablet-panel-alt);
    padding: 2px 9px;
    border-radius: 999px;
    border: 1px solid var(--tablet-border);
  }

  .badge-count.at-cap {
    color: var(--on-accent);
    border-color: var(--c-action);
    background: var(--c-action);
  }

  .filter-pills {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .pill-btn {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    color: var(--text-dim);
    padding: 4px 10px;
    border-radius: var(--radius-sm, 5px);
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease;
  }

  .pill-btn:hover {
    color: var(--text-main);
    border-color: var(--tablet-border-strong);
  }

  .pill-btn.active {
    background: var(--es-accent, #4f94e6);
    border-color: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #eceef0);
    font-weight: 600;
  }

  .search-wrap {
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    padding: 0 10px;
    height: 34px;
    color: var(--text-dim);
    margin-bottom: 12px;
  }

  .search-wrap:focus-within {
    border-color: var(--accent-primary);
  }

  .search-wrap input {
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-main);
    font-size: var(--fs-small);
    width: 100%;
  }

  .search-wrap input::placeholder {
    color: var(--text-placeholder);
    opacity: 1;
  }

  .clear-btn {
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
    display: flex;
  }

  .clear-btn:hover {
    color: var(--text-main);
  }

  .members-scroll,
  .squad-scroll {
    flex: 1;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding-right: 4px;
  }

  /* Member item card */
  .member-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
    user-select: none;
  }

  .member-item:hover:not(.disabled) {
    background: var(--tablet-panel);
    border-color: var(--tablet-border-strong);
  }

  .member-item.selected {
    background: var(--c-hover);
    border-color: var(--accent-primary);
    box-shadow: none;
  }

  /* Deliberately NOT dimmed — the old 0.45 opacity made an at-capacity row's
     text unreadable. The muted background alone reads as "unavailable". */
  .member-item.disabled {
    cursor: not-allowed;
    background: var(--c-base);
  }

  .select-checkbox {
    width: 18px;
    height: 18px;
    border-radius: var(--radius-sm, 5px);
    border: 1px solid var(--tablet-border-strong);
    background: var(--c-raised);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--lt-ffffff, #fff);
    flex-shrink: 0;
    transition: background 0.15s ease, border-color 0.15s ease;
  }

  .select-checkbox.checked {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, inherit);
}

  .avatar-wrap {
    position: relative;
    flex-shrink: 0;
  }

  .avatar {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
  }

  .status-indicator {
    position: absolute;
    bottom: -1px;
    right: -1px;
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--text-placeholder);
    border: 2px solid var(--tablet-panel-alt);
  }

  .status-indicator.online {
    background: var(--tablet-success);
  }

  .member-details {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .member-name {
    font-size: var(--fs-body);
    font-weight: var(--fw-nav);
    color: var(--text-main);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .member-meta {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
  }

  .member-role {
    color: var(--text-dim);
  }

  .leader-badge {
    background: rgb(255, 200, 87);
    border: 1px solid rgb(255, 200, 87);
    color: #111111;
    padding: 2px 6px;
    border-radius: var(--radius-sm, 5px);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }

  .online-status {
    color: var(--text-dim);
    font-size: var(--fs-meta);
  }

  .online-status.online {
    color: var(--tablet-success);
  }

  .cap-tag {
    font-size: var(--fs-meta);
    color: #111111;
    background: rgb(255, 200, 87);
    border: 1px solid rgb(255, 200, 87);
    padding: 2px 7px;
    border-radius: var(--radius-sm, 5px);
  }

  /* Capacity meter on right column */
  .cap-meter {
    width: 100%;
    height: 5px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border-radius: 5px;
    overflow: hidden;
  }

  .cap-meter-fill {
    height: 100%;
    background: var(--accent-primary);
    border-radius: var(--r-panel);
    transition: width 0.3s ease;
    color: var(--on-accent, inherit);
}

  .cap-meter-fill.full {
    background: var(--tablet-warn);
  }

  .cap-notice {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 10px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--radius-sm, 5px);
    color: var(--tablet-warn);
    font-size: var(--fs-small);
    margin-bottom: 10px;
    border-left: 3px solid rgb(255, 200, 87);}

  /* Squad Cards */
  .squad-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .squad-card {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 12px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    transition: border-color 0.15s ease;
  }

  .squad-card:hover {
    border-color: var(--tablet-border-strong);
  }

  .squad-slot {
    font-size: var(--fs-meta);
    font-weight: var(--fw-value);
    color: var(--accent-primary-light);
    width: 20px;
  }

  .avatar-mini {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
    flex-shrink: 0;
  }

  .squad-name-col {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .squad-name {
    font-size: var(--fs-body);
    font-weight: var(--fw-nav);
    color: var(--text-main);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .squad-status {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }

  .squad-status.online {
    color: var(--tablet-success);
  }

  .btn-remove-squad {
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm, 5px);
    transition: color 0.12s ease, background 0.12s ease;
  }

  .btn-remove-squad:hover {
    color: var(--tablet-danger);
    background: var(--c-hover);
  }

  /* Empty crew state */
  .empty-crew-card {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    padding: 40px 16px;
    gap: 9px;
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-md, 3px);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.01);
    height: 100%;
  }

  .crew-radar-icon {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    color: var(--text-dim);
    margin-bottom: 4px;
  }

  .empty-crew-title {
    font-size: var(--fs-body);
    font-weight: var(--fw-heading);
    color: var(--text-main);
    margin: 0;
  }

  .empty-crew-sub {
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin: 0;
    max-width: 260px;
    line-height: 1.5;
  }

  .empty-state-card {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 30px 12px;
    color: var(--text-dim);
    gap: 9px;
    font-size: var(--fs-small);
    text-align: center;
  }

  /* Sticky Footer */
  .roster-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 15px 24px;
    border-top: 1px solid rgba(110, 160, 215, 0.2);
    background: rgba(var(--ltc-8-12-18, 8, 12, 18), 0.65);
    gap: 12px;
  }

  .footer-left {
    display: flex;
    align-items: center;
  }

  .footer-right {
    display: flex;
    align-items: center;
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

  .btn-ghost {
    background: transparent;
    border-color: transparent;
    color: var(--text-dim);
    padding: 7px 11px;
    font-size: var(--fs-small);
  }

  .btn-ghost:hover {
    color: var(--text-main);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
  }

  .btn-outline:hover:not(:disabled) {
    background: var(--c-hover);
    border-color: var(--c-line);
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

  .btn-save {
    background: var(--es-accent, #4f94e6);
    border-color: var(--es-accent, #4f94e6);
    color: var(--on-es-accent, #eceef0);
    font-weight: 700;
  }

  .btn-save:hover:not(:disabled) {
    background: var(--es-accent-hover, #66a3eb);
    border-color: var(--es-accent-hover, #66a3eb);
  }

  .btn-save:disabled,
  .btn:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  @media (max-width: 768px) {
    .roster-columns {
      grid-template-columns: 1fr;
      overflow-y: auto;
    }
    .col-members {
      border-right: none;
      border-bottom: 1px solid var(--tablet-border);
    }
  }
</style>
