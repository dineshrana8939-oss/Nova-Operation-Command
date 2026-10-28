<script>
  import { onMount, onDestroy } from 'svelte';
  import { civilianRegistrationOpen, civilianRegistrationData } from '../stores.js';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import '../../styles/flat.css';   // this window wears the same theme as the Event Status panel
  import { getCivilianAvailableEvents, joinCivilianEvent } from '../api/convoy.js';
  import { fetchNui } from '../api/nui.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import { themeFor } from '../hud/eventThemes.js';
  import '../tablet/tablet-theme.css';
  import tabletBg from '../../assets/tablet-bg.jpg';

  $: visible = $civilianRegistrationOpen;

  // Each kind of event keeps the colour it has everywhere else (races teal, Container Wars harbour green — eventThemes.js).
  const kindTheme = (kind) => themeFor(kind === 'GANG_RACE' ? 'rally' : 'containerwars');

  let events = [];
  let loading = true;
  let typeFilter = 'all'; // 'all' | 'race' | 'container'
  let timeFilter = 'all'; // 'all' | 'today' | 'upcoming'

  // Confirmation modal state
  let selectedEvent = null;
  let joining = false;
  let joinError = '';

  // Toast state
  let toastMsg = '';
  let toastTimer = null;

  function showToast(msg) {
    toastMsg = msg;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toastMsg = '';
    }, 4000);
  }

  async function loadEvents() {
    loading = true;
    try {
      const res = await getCivilianAvailableEvents();
      if (res && res.ok && Array.isArray(res.events)) {
        events = res.events;
      } else {
        events = [];
      }
    } catch (e) {
      console.warn('[CivilianRegistration] Failed to load events:', e);
      events = [];
    } finally {
      loading = false;
    }
  }

  $: if (visible) {
    loadEvents();
  }

  function closeUI() {
    selectedEvent = null;
    civilianRegistrationOpen.set(false);
    // This one must go straight to the game's own NUI callback (client/modules/civilian_registration.lua), which hands the
    // mouse and keyboard back to the game. It used to go through invoke(), which forwards to a SERVER callback of that
    // name — there is none — so the window closed but the game never got its controls back (the screen looked frozen).
    fetchNui('nova_convoytruck:civilianRegistration:close');
  }

  function handleKeydown(e) {
    if (!visible) return;
    if (e.key === 'Escape') {
      if (selectedEvent) {
        selectedEvent = null;
      } else {
        closeUI();
      }
    }
  }

  onMount(() => {
    window.addEventListener('keydown', handleKeydown);
    return () => {
      window.removeEventListener('keydown', handleKeydown);
      if (toastTimer) clearTimeout(toastTimer);
    };
  });

  function formatSchedule(ev) {
    if (!ev) return 'Scheduled Event';
    if (ev.status === 'ACTIVE' || ev.status === 'RUNNING' || ev.status === 'GRID') {
      return 'Active Now';
    }
    if (ev.scheduledAt) {
      const d = new Date(ev.scheduledAt * 1000);
      const isToday = d.toDateString() === new Date().toDateString();
      const timeStr = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      return isToday ? `Today · ${timeStr}` : `${d.toLocaleDateString([], { month: 'short', day: 'numeric' })} · ${timeStr}`;
    }
    if (ev.recurrence && ev.recurrence.enabled) {
      return `Daily · ${ev.recurrence.time || 'Scheduled'}`;
    }
    return 'Upcoming';
  }

  function isEventToday(ev) {
    if (ev.status === 'ACTIVE' || ev.status === 'RUNNING' || ev.status === 'GRID') return true;
    if (ev.scheduledAt) {
      const d = new Date(ev.scheduledAt * 1000);
      return d.toDateString() === new Date().toDateString();
    }
    if (ev.recurrence && ev.recurrence.enabled) return true;
    return false;
  }

  // Counts for sidebar nav
  $: countAll = events.length;
  $: countRace = events.filter((e) => e.kind === 'GANG_RACE').length;
  $: countContainer = events.filter((e) => e.kind === 'CONTAINER_WARS').length;

  // Filtered event cards
  $: filteredEvents = events.filter((e) => {
    if (typeFilter === 'race' && e.kind !== 'GANG_RACE') return false;
    if (typeFilter === 'container' && e.kind !== 'CONTAINER_WARS') return false;

    const today = isEventToday(e);
    if (timeFilter === 'today' && !today) return false;
    if (timeFilter === 'upcoming' && today) return false;

    return true;
  });

  function openConfirmModal(ev) {
    selectedEvent = ev;
    joinError = '';
  }

  function closeConfirmModal() {
    selectedEvent = null;
    joinError = '';
  }

  async function handleConfirmJoin() {
    if (!selectedEvent) return;
    joining = true;
    joinError = '';
    try {
      const res = await joinCivilianEvent(selectedEvent.id);
      joining = false;
      if (res && res.ok) {
        showToast(res.message || `Successfully registered for ${selectedEvent.name}!`);
        selectedEvent.isRegistered = true;
        closeConfirmModal();
        loadEvents();
      } else {
        joinError = (res && res.error) || 'Registration failed.';
      }
    } catch (err) {
      joining = false;
      joinError = 'Connection error. Please try again.';
    }
  }
</script>

{#if visible}
  <div class="registration-backdrop" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} style="{$gangThemeStyle}" on:click|self={closeUI}>
    <div class="registration-shell" style="--tablet-bg-img: url('{tabletBg}');">
      <!-- Top Header -->
      <header class="reg-top">
        <div class="brand">
          <div class="brand-icon">
            <Icon name="medal" size={18} />
          </div>
          <div>
            <div class="brand-title">Event Registration</div>
            <div class="brand-sub">Available events &amp; upcoming schedules</div>
          </div>
        </div>
        <div class="top-actions">
          <span class="esc-pill"><kbd>ESC</kbd> Close</span>
          <button class="btn-close" on:click={closeUI} title="Close">
            <Icon name="close" size={13} />
          </button>
        </div>
      </header>

      <!-- Two-column Body -->
      <div class="reg-body">
        <!-- Sidebar Navigation -->
        <aside class="reg-aside">
          <div class="nav-section-title">Event Types</div>
          <button
            type="button"
            class="nav-item"
            class:active={typeFilter === 'all'}
            on:click={() => (typeFilter = 'all')}
          >
            <div class="nav-item-label">
              <Icon name="grid" size={14} />
              <span>All Events</span>
            </div>
            <span class="count-badge">{countAll}</span>
          </button>

          <button
            type="button"
            class="nav-item"
            class:active={typeFilter === 'race'}
            on:click={() => (typeFilter = 'race')}
          >
            <div class="nav-item-label">
              <Icon name="flag" size={14} />
              <span>Street Races</span>
            </div>
            <span class="count-badge">{countRace}</span>
          </button>

          <button
            type="button"
            class="nav-item"
            class:active={typeFilter === 'container'}
            on:click={() => (typeFilter = 'container')}
          >
            <div class="nav-item-label">
              <Icon name="box" size={14} />
              <span>Container Wars</span>
            </div>
            <span class="count-badge">{countContainer}</span>
          </button>
        </aside>

        <!-- Main Content Area -->
        <main class="reg-main">
          <!-- Main Content Header -->
          <div class="main-head">
            <div>
              <h2 class="main-title">Open Registrations</h2>
              <p class="main-subtitle">Join a live event or reserve a place in an upcoming scheduled event.</p>
            </div>
            <div class="time-filters">
              <button
                type="button"
                class="time-btn"
                class:active={timeFilter === 'all'}
                on:click={() => (timeFilter = 'all')}
              >
                All
              </button>
              <button
                type="button"
                class="time-btn"
                class:active={timeFilter === 'today'}
                on:click={() => (timeFilter = 'today')}
              >
                Today
              </button>
              <button
                type="button"
                class="time-btn"
                class:active={timeFilter === 'upcoming'}
                on:click={() => (timeFilter = 'upcoming')}
              >
                Upcoming
              </button>
            </div>
          </div>

          <!-- Event Cards List -->
          <div class="event-list">
            {#if loading && events.length === 0}
              <div class="state-message">
                <Icon name="refresh" size={24} />
                <span>Checking available event registrations...</span>
              </div>
            {:else if filteredEvents.length === 0}
              <div class="state-message empty">
                <Icon name="calendar" size={30} />
                <h4>No Events Available</h4>
                <p>There are currently no events open for civilian registration matching your filter.</p>
              </div>
            {:else}
              {#each filteredEvents as ev (ev.id)}
                {@const isRace = ev.kind === 'GANG_RACE'}
                {@const isLive = ev.status === 'ACTIVE' || ev.status === 'RUNNING' || ev.status === 'GRID'}
                {@const isFull = ev.participantCount >= ev.maxParticipants}
                <div class="event-card" class:registered={ev.isRegistered} style="--ev:{kindTheme(ev.kind).accent}; --evRGB:{kindTheme(ev.kind).rgb}">
                  <!-- Info Left -->
                  <div class="event-info">
                    <div class="event-tag-row">
                      <span class="event-type-tag {isRace ? 'race' : 'container'}">
                        <Icon name={isRace ? 'flag' : 'box'} size={11} />
                        {isRace ? 'Street Race' : 'Container War'}
                      </span>
                      <span class="event-status-tag {isLive ? 'live' : 'upcoming'}">
                        {isLive ? 'Active Registration' : 'Scheduled'}
                      </span>
                    </div>

                    <div class="event-name">{ev.name}</div>
                    <div class="event-meta">
                      <span class="meta-item">
                        <Icon name="mapPin" size={11} />
                        {ev.locationName || (isRace ? 'City Circuit' : 'Terminal Docks')}
                      </span>
                      <span class="meta-separator">•</span>
                      <span class="meta-item">
                        <Icon name="users" size={11} />
                        {ev.participantCount} / {ev.maxParticipants} registered
                      </span>
                      {#if ev.entryFee && ev.entryFee > 0}
                        <span class="meta-separator">•</span>
                        <span class="meta-item fee">Fee: ${Number(ev.entryFee).toLocaleString()}</span>
                      {:else}
                        <span class="meta-separator">•</span>
                        <span class="meta-item free">Free Entry</span>
                      {/if}
                    </div>
                    {#if ev.shortDescription && ev.shortDescription.trim() && ev.shortDescription.trim().toLowerCase() !== (ev.name || '').trim().toLowerCase()}
                      <div class="event-desc">{ev.shortDescription}</div>
                    {/if}
                  </div>

                  <!-- Schedule Center -->
                  <div class="event-timing">
                    <div class="timing-label">{formatSchedule(ev)}</div>
                    <div class="timing-status">
                      {#if ev.isRegistered}
                        <span class="status-confirmed">Slot Confirmed</span>
                      {:else if isLive}
                        <span class="status-live">Starting Shortly</span>
                      {:else}
                        <span>Registration Open</span>
                      {/if}
                    </div>
                  </div>

                  <!-- Action Right -->
                  <div class="event-actions">
                    {#if ev.isRegistered}
                      <button type="button" class="btn btn-registered" disabled>
                        <Icon name="check" size={13} />
                        <span>Registered</span>
                      </button>
                    {:else if isFull}
                      <button type="button" class="btn btn-full" disabled>
                        <span>Full</span>
                      </button>
                    {:else}
                      <button
                        type="button"
                        class="btn btn-primary join-btn"
                        on:click={() => openConfirmModal(ev)}
                      >
                        <span>Join Event</span>
                      </button>
                    {/if}
                  </div>
                </div>
              {/each}
            {/if}
          </div>
        </main>
      </div>
    </div>

    <!-- Confirmation Modal Dialog -->
    {#if selectedEvent}
      <div class="confirm-overlay" on:click|self={closeConfirmModal}>
        <div class="confirm-modal">
          <div class="confirm-header">
            <div class="confirm-title-row">
              <Icon name="medal" size={16} />
              <h3>Confirm Participation</h3>
            </div>
            <button class="btn-close" on:click={closeConfirmModal}><Icon name="close" size={12} /></button>
          </div>

          <div class="confirm-body">
            <div class="confirm-message-card">
              <div class="msg-lead">
                Confirm your civilian participation in <span class="event-highlight">{selectedEvent.name}</span>
              </div>
              <p class="msg-sub">
                You will be entered into the official lineup and your standings will be recorded on the civilian leaderboard.
              </p>
            </div>

            {#if joinError}
              <div class="confirm-error">
                <Icon name="alert" size={14} />
                <span>{joinError}</span>
              </div>
            {/if}

            <div class="confirm-details-grid">
              <div class="detail-box">
                <span class="detail-label">Event</span>
                <span class="detail-val">{selectedEvent.name}</span>
              </div>
              <div class="detail-box">
                <span class="detail-label">Discipline</span>
                <span class="detail-val">{selectedEvent.kind === 'GANG_RACE' ? 'Street Race' : 'Container War'}</span>
              </div>
              <div class="detail-box">
                <span class="detail-label">Schedule</span>
                <span class="detail-val">{formatSchedule(selectedEvent)}</span>
              </div>
              <div class="detail-box">
                <span class="detail-label">Location</span>
                <span class="detail-val">{selectedEvent.locationName || 'Official Staging Zone'}</span>
              </div>
              <div class="detail-box">
                <span class="detail-label">Registration Fee</span>
                <span class="detail-val {selectedEvent.entryFee > 0 ? 'text-warn' : 'text-good'}">
                  {selectedEvent.entryFee > 0 ? `$${Number(selectedEvent.entryFee).toLocaleString()}` : 'Free'}
                </span>
              </div>
              <div class="detail-box">
                <span class="detail-label">Lineup Capacity</span>
                <span class="detail-val">{selectedEvent.participantCount} / {selectedEvent.maxParticipants} slots</span>
              </div>
            </div>

            <div class="confirm-notice">
              <Icon name="shield" size={13} />
              <span>Ensure you arrive on time at the event staging area. Event rules apply to all civilian operatives.</span>
            </div>
          </div>

          <div class="confirm-actions">
            <button type="button" class="btn btn-secondary" on:click={closeConfirmModal} disabled={joining}>
              Cancel
            </button>
            <button type="button" class="btn btn-primary" on:click={handleConfirmJoin} disabled={joining}>
              <Icon name="check" size={13} />
              <span>{joining ? 'Registering…' : 'Confirm & Join'}</span>
            </button>
          </div>
        </div>
      </div>
    {/if}

    <!-- Toast Notification -->
    {#if toastMsg}
      <div class="reg-toast">
        <Icon name="check" size={14} />
        <span>{toastMsg}</span>
      </div>
    {/if}
  </div>
{/if}

<style>
  .registration-backdrop {
    position: fixed;
    inset: 0;
    z-index: 9999;
    background: rgba(5, 7, 12, 0.72);
    pointer-events: all;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    user-select: none;
    font-family: var(--font-ui);
    font-variant-numeric: tabular-nums;
    color: var(--text-main, #ffffff);
  }

  .registration-shell {
    width: 980px;
    max-width: 95vw;
    height: 600px;
    max-height: 88vh;
    background-color: #0b0f16;
    /* the first layer is the theme's background shade / gradient (Settings → Appearance); invisible for Graphite, and a gradient
       theme replaces the stock picture (--bg-picture: none) exactly as it does in the Event Status panel */
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent))),
      radial-gradient(ellipse 90% 80% at 50% 30%, rgba(90, 130, 180, 0.16) 0%, rgba(20, 30, 48, 0.45) 55%, rgba(6, 9, 14, 0.88) 100%),
      var(--bg-picture, var(--tablet-bg-img, url('../../assets/tablet-bg.jpg')));
    background-size: cover, cover, cover;
    background-position: center center, center top, center center;
    background-repeat: no-repeat, no-repeat, no-repeat;
    border: 1px solid rgba(110, 140, 180, 0.28);
    border-radius: var(--r-panel);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.7);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  /* Header */
  .reg-top {
    height: 56px;
    flex: 0 0 56px;
    padding: 0 20px;
    background: rgba(12, 16, 24, 0.8);
    border-bottom: 1px solid rgba(110, 140, 180, 0.22);
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .brand-icon {
    width: 34px;
    height: 34px;
    border-radius: var(--r-tag);
    background: #1f2328;
    border: 1px solid #2a2e35;
    color: var(--accent-primary, #4f94e6);
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .brand-title {
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: #ffffff;
  }

  .brand-sub {
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
    margin-top: 1px;
  }

  .top-actions {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .esc-pill {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: #aeb5bd;
    background: #181b1f;
    border: 1px solid #2a2e35;
    border-radius: var(--r-tag);
    padding: 3px 8px;
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .esc-pill kbd {
    font-family: inherit;
    font-weight: 700;
    color: #ffffff;
  }

  .btn-close {
    width: 32px;
    height: 32px;
    border-radius: var(--r-ctl);
    background: #1f2328;
    border: 1px solid #2a2e35;
    color: #aeb5bd;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .btn-close:hover {
    background: rgba(255, 93, 80, 0.15);
    border-color: rgba(255, 93, 80, 0.4);
    color: #ff5d50;
  }

  /* Body */
  .reg-body {
    display: grid;
    grid-template-columns: 220px 1fr;
    flex: 1;
    min-height: 0;
  }

  /* Aside Navigation */
  .reg-aside {
    padding: 16px 12px;
    background: rgba(10, 13, 19, 0.65);
    border-right: 1px solid rgba(110, 140, 180, 0.2);
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .nav-section-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-muted, #aeb5bd);
    padding: 4px 10px 8px;
  }

  .nav-item {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    color: #c9ced4;
    font-size: var(--fs-small);
    font-weight: 600;
    letter-spacing: 0.01em;
    min-height: 40px;
    padding: 0 12px 0 14px;
    background: transparent;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }

  .nav-item :global(svg) {
    width: 16px;
    height: 16px;
    color: #959ca5;
    flex-shrink: 0;
    transition: color 0.15s ease;
  }

  .nav-item:hover {
    background: #1f2328;
    border-color: #2a2e35;
    color: #ffffff;
  }

  .nav-item:hover :global(svg) {
    color: #ffffff;
  }

  .nav-item.active {
    background: #1f2328;
    border-color: #2a2e35;
    color: #ffffff;
    font-weight: 600;
  }

  .nav-item.active :global(svg) {
    color: var(--accent-primary, #4f94e6);
  }

  .nav-item.active::before {
    content: '';
    position: absolute;
    left: -1px;
    top: 7px;
    bottom: 7px;
    width: 3px;
    border-radius: 2px;
    background: var(--accent-primary, #4f94e6);
  }

  .nav-item-label {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .count-badge {
    font-size: var(--fs-meta);
    font-weight: 600;
    font-family: var(--font-mono);
    padding: 2px 7px;
    border-radius: var(--r-tag);
    background: #181b1f;
    border: 1px solid #2a2e35;
    color: #aeb5bd;
    transition: all 0.15s ease;
  }

  .nav-item.active .count-badge {
    background: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.15);
    border-color: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.4);
    color: #ffffff;
  }

  /* Main Area */
  .reg-main {
    padding: 22px 24px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 16px;
    background: transparent;
  }

  .main-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    gap: 16px;
    flex-wrap: wrap;
  }

  .main-title {
    font-size: var(--fs-emph);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: #ffffff;
    margin: 0;
  }

  .main-subtitle {
    font-size: var(--fs-small);
    color: var(--text-muted, #aeb5bd);
    margin: 4px 0 0;
  }

  .time-filters {
    display: inline-flex;
    align-items: center;
    background: rgba(16, 21, 30, 0.6);
    border: 1px solid rgba(110, 140, 180, 0.22);
    border-radius: var(--r-ctl);
    padding: 3px;
    gap: 3px;
  }

  .time-btn {
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    color: #c9ced4;
    padding: 6px 14px;
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .time-btn:hover {
    background: #1f2328;
    color: #ffffff;
  }

  .time-btn.active {
    background: var(--accent-primary, #4f94e6);
    border-color: var(--accent-primary, #4f94e6);
    color: #ffffff;
    text-shadow: none;
  }

  /* Event List & Cards */
  .event-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .state-message {
    padding: 48px 20px;
    text-align: center;
    color: var(--text-muted, #aeb5bd);
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    background: rgba(16, 21, 30, 0.55);
    border: 1px dashed rgba(110, 140, 180, 0.25);
    border-radius: var(--r-panel);
  }

  .state-message.empty h4 {
    margin: 4px 0 0;
    font-size: var(--fs-body);
    font-weight: 700;
    color: #ffffff;
  }

  .state-message.empty p {
    margin: 0;
    font-size: var(--fs-small);
    color: var(--text-muted, #aeb5bd);
  }

  .event-card {
    position: relative;
    display: grid;
    grid-template-columns: 1fr auto auto;
    gap: 20px;
    align-items: center;
    padding: 16px 20px;
    background: rgba(16, 22, 32, 0.78);
    border: 1px solid rgba(110, 140, 180, 0.2);
    border-left: 3px solid var(--ev, var(--accent-primary, #4f94e6));
    border-radius: var(--r-panel);
    box-shadow: none;
    transition: border-color 0.15s ease, background 0.15s ease, transform 0.12s ease;
  }

  .event-card:hover {
    border-color: rgba(110, 140, 180, 0.38);
    background: rgba(24, 32, 46, 0.72);
    transform: translateY(-1px);
  }

  .event-card.registered {
    border-color: rgba(70, 201, 139, 0.4);
    border-left-color: #46c98b;
    background: rgba(70, 201, 139, 0.04);
  }

  .event-tag-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 6px;
  }

  .event-type-tag {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    padding: 3px 8px;
    border-radius: var(--r-tag);
    background: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.12);
    border: 1px solid rgba(var(--accent-primary-rgb, 79, 148, 230), 0.35);
    color: var(--accent-primary, #4f94e6);
  }

  .event-type-tag.container {
    background: rgba(14, 165, 233, 0.12);
    border-color: rgba(14, 165, 233, 0.35);
    color: var(--accent-primary, #4f94e6);
  }

  .event-type-tag.race {
    background: rgba(245, 158, 11, 0.12);
    border-color: rgba(245, 158, 11, 0.35);
    color: #f59e0b;
  }

  .event-status-tag {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    padding: 3px 8px;
    border-radius: var(--r-tag);
    background: #1f2328;
    border: 1px solid #2a2e35;
    color: #aeb5bd;
  }

  .event-status-tag.live {
    background: rgba(70, 201, 139, 0.12);
    border-color: rgba(70, 201, 139, 0.35);
    color: #46c98b;
  }

  .event-status-tag.upcoming {
    background: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.12);
    border-color: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.35);
    color: #7bb6f2;
  }

  .event-name {
    font-size: var(--fs-emph);
    font-weight: 700;
    color: #ffffff;
    line-height: 1.3;
  }

  .event-meta {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    color: var(--text-dim, #c9ced4);
    margin-top: 5px;
    flex-wrap: wrap;
  }

  .meta-item {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .meta-separator {
    color: #3b3e4f;
  }

  .meta-item.free {
    color: #46c98b;
    font-weight: 600;
  }

  .meta-item.fee {
    color: #ffc857;
    font-weight: 600;
  }

  .event-desc {
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
    margin-top: 5px;
    line-height: 1.45;
  }

  /* Timing Center */
  .event-timing {
    text-align: right;
    padding: 0 10px;
  }

  .timing-label {
    font-size: var(--fs-small);
    font-weight: 700;
    color: #ffffff;
  }

  .timing-status {
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
    margin-top: 3px;
  }

  .status-confirmed {
    color: #46c98b;
    font-weight: 600;
  }

  .status-live {
    color: var(--accent-primary, #4f94e6);
    font-weight: 600;
  }

  /* Actions Right */
  .event-actions {
    display: flex;
    justify-content: flex-end;
  }

  .join-btn {
    min-width: 110px;
    height: 38px;
    padding: 0 16px;
    font-size: var(--fs-small);
    font-weight: 600;
    background: var(--accent-primary, #4f94e6);
    border: 1px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-ctl);
    color: #ffffff;
    text-shadow: none;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .join-btn:hover {
    background: var(--accent-primary-light, #66a3eb);
    border-color: var(--accent-primary-light, #66a3eb);
  }

  .btn-registered {
    min-width: 110px;
    height: 38px;
    padding: 0 16px;
    font-size: var(--fs-small);
    font-weight: 600;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    border-radius: var(--r-ctl);
    background: rgba(70, 201, 139, 0.12);
    border: 1px solid rgba(70, 201, 139, 0.35);
    color: #46c98b;
    cursor: default;
  }

  .btn-full {
    min-width: 110px;
    height: 38px;
    padding: 0 16px;
    font-size: var(--fs-small);
    font-weight: 600;
    border-radius: var(--r-ctl);
    background: #1f2328;
    border: 1px solid #2a2e35;
    color: #aeb5bd;
    cursor: not-allowed;
  }

  /* Confirmation Modal */
  .confirm-overlay {
    position: fixed;
    inset: 0;
    background: rgba(5, 7, 12, 0.75);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10001;
    padding: 20px;
  }

  .confirm-modal {
    width: 530px;
    max-width: 94vw;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-panel);
    box-shadow: none;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .confirm-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 20px;
    background: #15171b;
    border-bottom: 1px solid #2a2e35;
  }

  .confirm-title-row {
    display: flex;
    align-items: center;
    gap: 10px;
    color: var(--accent-primary, #4f94e6);
  }

  .confirm-title-row h3 {
    margin: 0;
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: #ffffff;
  }

  .confirm-body {
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  /* Prominent & Neat Confirmation Message Card */
  .confirm-message-card {
    background: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.08);
    border: 1px solid rgba(var(--accent-primary-rgb, 79, 148, 230), 0.28);
    border-left: 4px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-panel);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .msg-lead {
    font-size: var(--fs-emph);
    font-weight: 600;
    color: #e3e6e9;
    line-height: 1.45;
  }

  .event-highlight {
    font-weight: 700;
    color: #ffffff;
    background: rgba(var(--accent-primary-rgb, 79, 148, 230), 0.22);
    border: 1px solid rgba(var(--accent-primary-rgb, 79, 148, 230), 0.45);
    padding: 2px 7px;
    border-radius: var(--r-panel);
    display: inline-block;
  }

  .msg-sub {
    margin: 0;
    font-size: var(--fs-small);
    color: #aeb5bd;
    line-height: 1.5;
  }

  .confirm-error {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    border-radius: var(--r-ctl);
    background: rgba(229, 82, 74, 0.12);
    border: 1px solid rgba(229, 82, 74, 0.35);
    color: #ff5d50;
    font-size: var(--fs-small);
  }

  .confirm-details-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
    background: #15171b;
    border: 1px solid #2a2e35;
    border-radius: var(--r-panel);
    padding: 14px 16px;
  }

  .detail-box {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .detail-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-muted, #aeb5bd);
  }

  .detail-val {
    font-size: var(--fs-body);
    font-weight: 700;
    color: #ffffff;
    margin-top: 1px;
  }

  .text-good { color: #46c98b !important; }
  .text-warn { color: #ffc857 !important; }

  .confirm-notice {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: var(--fs-meta);
    color: #c9ced4;
    background: #15171b;
    border: 1px solid #2a2e35;
    padding: 10px 14px;
    border-radius: var(--r-panel);
  }

  .confirm-notice :global(svg) {
    color: var(--accent-primary, #4f94e6);
    flex-shrink: 0;
  }

  .confirm-actions {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    padding: 14px 20px;
    background: #15171b;
    border-top: 1px solid #2a2e35;
  }

  .confirm-actions .btn {
    height: 38px;
    padding: 0 18px;
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    transition: all 0.15s ease;
  }

  .confirm-actions .btn-secondary {
    background: #1f2328;
    border: 1px solid #2a2e35;
    color: #e3e6e9;
  }

  .confirm-actions .btn-secondary:hover:not(:disabled) {
    background: #272b31;
    border-color: #363b43;
    color: #ffffff;
  }

  .confirm-actions .btn-primary {
    background: var(--accent-primary, #4f94e6);
    border: 1px solid var(--accent-primary, #4f94e6);
    color: #ffffff;
    text-shadow: none;
  }

  .confirm-actions .btn-primary:hover:not(:disabled) {
    background: var(--accent-primary-light, #66a3eb);
    border-color: var(--accent-primary-light, #66a3eb);
  }

  /* Toast Notification */
  .reg-toast {
    position: fixed;
    bottom: 30px;
    left: 50%;
    transform: translateX(-50%);
    z-index: 10002;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 18px;
    background: #181b1f;
    border: 1px solid #46c98b;
    border-radius: var(--r-panel);
    color: #46c98b;
    font-size: var(--fs-small);
    font-weight: 600;
    box-shadow: none;
  }
</style>
