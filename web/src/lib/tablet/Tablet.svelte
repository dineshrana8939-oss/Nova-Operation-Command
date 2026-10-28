<script>
  import { NAV_GROUPS } from './navGroups.js';
  import { onMount, onDestroy, tick } from 'svelte';
  import { fade, scale } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';
  import { tabletOpen, tabletMinimized, currentView, viewSub, bootstrap, staffVersion } from '../stores.js';
  import { canSeeSection } from '../perms.js';
  import { fetchNui } from '../api/nui.js';
  import { getBootstrap, getDashboard } from '../api/convoy.js';
  import { newDots } from './ui/newDots.js';
  import { gangVersion } from '../stores.js';
  import { rivalsVersion } from '../territory/territoryStore.js';
  import Icon from './ui/Icon.svelte';
  import AdminTopNav from './ui/AdminTopNav.svelte';
  import ConfirmModal from './ui/ConfirmModal.svelte';
  import Dashboard from './views/Dashboard.svelte';
  import ConvoysList from './views/ConvoysList.svelte';
  import CreateConvoy from './views/CreateConvoy.svelte';
  import Participants from './views/Participants.svelte';
  import CompletedConvoys from './views/CompletedConvoys.svelte';
  import GangManagement from './views/GangManagement.svelte';
  import Leaderboard from './views/Leaderboard.svelte';
  import CivilianLeaderboard from './views/CivilianLeaderboard.svelte';
  import Settings from './views/Settings.svelte';
  import Announcements from './views/Announcements.svelte';
  import SavedRoutes from './views/SavedRoutes.svelte';
  import Tournaments from './views/Tournaments.svelte';
  import TournamentTreePage from './views/TournamentTreePage.svelte';
  import TerritoryAdmin from './views/TerritoryAdmin.svelte';
  import Guide from './views/Guide.svelte';
  import StaffManagement from './views/StaffManagement.svelte';
  import { adminPrefs, adminThemeStyle } from '../adminPrefs.js';
  import '../../styles/flat.css';
  import GangTerritoryView from '../territory/GangTerritoryView.svelte';
  import TerritoryRivals from '../territory/TerritoryRivals.svelte';
  import tabletBg from '../../assets/tablet-bg.jpg';
  import eventGradient from '../../assets/event-gradient.jpg';

  const NAV = NAV_GROUPS.flatMap((g) => g.items);

  let denied = false;
  let loading = true;
  export let editConvoyId = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_edit_id')) ? Number(localStorage.getItem('nova_convoy_last_edit_id')) : null;

  $: if (typeof localStorage !== 'undefined') {
    if (editConvoyId != null) {
      localStorage.setItem('nova_convoy_last_edit_id', String(editConvoyId));
    } else {
      localStorage.removeItem('nova_convoy_last_edit_id');
    }
  }

  // Tabs access control. The SERVER decides (getBootstrap -> `perms`: every 'section.action' key this player holds, from
  // their staff role + overrides, or all of them for a real server admin). A section shows in the sidebar and can be
  // opened only when it is both Visible and Viewable; a hidden section is never rendered even if it is navigated to
  // directly (e.g. from a saved last-tab). This is only the display: every action is checked again on the server.
  const tabAllowed = (item, bs) => !!bs && canSeeSection(bs.perms, item.perm || item.id);
  $: visibleNav = NAV.filter((item) => tabAllowed(item, $bootstrap));
  $: visibleGroups = NAV_GROUPS.map((g) => ({ ...g, items: g.items.filter((item) => tabAllowed(item, $bootstrap)) })).filter((g) => g.items.length > 0);
  // An item opens a view (its own id, or 'view') and maybe one sub page of it (Announcements, Settings). World Peds used to be a view
  // of its own: a remembered 'worldpeds' now opens Settings on its World Peds page.
  $: if ($currentView === 'worldpeds') { viewSub.set('worldpeds'); currentView.set('settings'); }
  const isActiveItem = (i, v, sb) => (i.view || i.id) === v && (!i.sub || i.sub === sb);
  // land on the first section this person may open when the current one is not theirs (or was just taken away)
  $: if ($bootstrap && $currentView !== 'worldpeds') {
    const same = visibleNav.filter((i) => (i.view || i.id) === $currentView);
    if (!same.length) {
      const first = visibleNav[0];
      currentView.set(first ? (first.view || first.id) : 'dashboard');
      viewSub.set(first && first.sub ? first.sub : null);
    } else if (!same.some((i) => !i.sub || i.sub === $viewSub)) {
      viewSub.set(same[0].sub || null);
    }
  }
  // Switching tabs: the menu answers at once and the page follows one frame later. Building a heavy page (a hundred inputs, tables,
  // maps) blocks the browser for a moment; doing it in the same frame as the click made the whole tablet feel stuck before the
  // highlight even moved. The scroll position of the content area starts at the top for every page.
  let mountView = $currentView;
  let mountSub = $viewSub;
  let contentEl;
  let mountRaf = 0;
  // The scheduling lives in a function on purpose: a reactive block that itself reads and assigns `mountRaf` re-triggers itself
  // every time the frame callback assigns it, cancelling the very frame it just queued — the page then never swapped.
  function scheduleMount() {
    cancelAnimationFrame(mountRaf);
    mountRaf = requestAnimationFrame(() => {
      mountRaf = requestAnimationFrame(() => {
        mountView = currentViewNow;
        mountSub = viewSubNow;
        if (contentEl) contentEl.scrollTop = 0;
      });
    });
  }
  $: currentViewNow = $currentView;
  $: viewSubNow = $viewSub;
  $: if (currentViewNow !== mountView || viewSubNow !== mountSub) scheduleMount();
  onDestroy(() => cancelAnimationFrame(mountRaf));

  $: activeItem = visibleNav.find((i) => isActiveItem(i, $currentView, $viewSub)) || null;
  $: viewAllowed = !!$bootstrap && !!activeItem && canSeeSection($bootstrap.perms, activeItem.perm || activeItem.id);
  // Only shows the blocking "Authenticating with dispatch..." screen on the
  // FIRST open of the session (no cached bootstrap yet) — every open after
  // that reuses whatever's already in the store and shows the tablet
  // instantly, refreshing bootstrap silently in the background instead of
  // gating the UI on a fresh round-trip every single time. Permission/
  // feature changes still get picked up (just a moment after the tablet is
  // already visible, not before), and denied still flips true retroactively
  // if a background refresh ever reveals access was actually revoked.
  async function load() {
    const hadBootstrap = !!$bootstrap;
    if (!hadBootstrap) loading = true;
    const res = await getBootstrap();
    if (!res || res.ok === false) {
      loading = false;
      if (hadBootstrap) {
        // access was taken away while (or since) the tablet was open: forget what it knew and close it
        bootstrap.set(null);
        if ($tabletOpen) close();
        return;
      }
      denied = true;
      return;
    }
    bootstrap.set(res);
    denied = false;
    loading = false;
  }

  // Fires every time the tablet actually opens, not just once on first
  // mount — the tablet frame now stays mounted permanently (see below, this
  // is what fixes an in-progress Create Convoy draft getting wiped every
  // time you close/reopen), so a plain onMount would only ever fetch
  // bootstrap once for the whole play session instead of picking up
  // permission/feature changes on each open.
  //
  // Deliberately does NOT force the view back to Dashboard here — this used
  // to, but the user explicitly asked to land back on whichever tab was
  // open when the tablet was last closed instead (having to navigate back
  // to e.g. Settings from Dashboard every single time was the actual
  // complaint). currentView (stores.js) already persists to localStorage
  // and survives a full resource restart on its own, so simply not
  // resetting it here is the whole fix.
  $: if ($tabletOpen) {
    load();
  }

  // The server says this player's staff access (or the staff lists) changed: re-read the permissions now, so sections
  // appear / disappear immediately, or the tablet closes if access is gone.
  let seenStaffVersion = 0;
  $: if ($staffVersion !== seenStaffVersion) {
    seenStaffVersion = $staffVersion;
    if ($tabletOpen) load();
  }

  function close() {
    tabletOpen.set(false);
    fetchNui('tablet:close', {});
  }

  function handleKeydown(e) {
    if (e.key === 'Escape' && $tabletOpen) close();
  }

  // Preserves editConvoyId and the current draft when switching tabs, so
  // navigating to dashboard or saved routes and back returns to the exact
  // event you were editing. Starting a brand new draft is done explicitly
  // via startNewConvoy().
  // Editing an existing event happens on the Create Event screen, but it was opened from Manage Events (or Event History) and is not
  // "creating": the menu keeps Manage Events lit. Pressing Create Event meanwhile starts a NEW event instead of re-showing the edit.
  $: editingExisting = $currentView === 'create' && editConvoyId != null;
  $: navCurrent = editingExisting ? 'convoys' : $currentView;

  function selectItem(item) {
    if (item.id === 'create' && editingExisting) { startNewConvoy(); return; }
    currentView.set(item.view || item.id);
    viewSub.set(item.sub || null);
  }

  function startNewConvoy() {
    editConvoyId = null;
    if (typeof localStorage !== 'undefined') {
      localStorage.removeItem('nova_convoy_last_edit_id');
      localStorage.removeItem('nova_convoy_last_form_tab');
    }
    currentView.set('create');
  }

  // Edit & Reuse (Convoy History) and Edit (Manage Convoys) both just did
  // `editConvoyId = id`, which Svelte's CreateConvoy prop-reactivity ignores
  // if `id` is already the CURRENT value (e.g. reusing a convoy you were
  // already viewing) — no re-render means CreateConvoy's own $: load(convoyId)
  // never re-fires, so it kept showing the stale pre-reuse data (still
  // "CANCELLED") even though the server had already reset it to DRAFT.
  // Toggling through null first forces a real value change either way.
  async function editConvoy(id) {
    editConvoyId = null;
    await tick();
    editConvoyId = id;
    currentView.set('create');
  }

  // ── "something new" dots on the tabs ────────────────────────────────────────────────────────────────────────────────────
  // What each page holds is read as a signature (counts / versions the tablet already receives, plus one light overview read every 20 s while
  // the tablet is open); a page whose signature changed since it was last opened gets a dot (ui/newDots.js).
  const tabDots = newDots('nova_admin_new_dots');
  let overview = null;
  let overviewTimer;
  async function pollOverview() {
    if (!$tabletOpen) return;
    try { const r = await getDashboard(); if (r && r.ok && r.dashboard) overview = r.dashboard; } catch (e) { /* the dots just wait */ }
  }
  onMount(() => { pollOverview(); overviewTimer = setInterval(pollOverview, 20000); });
  onDestroy(() => clearInterval(overviewTimer));
  $: openPageId = (NAV.find((i) => isActiveItem(i, $currentView, $viewSub)) || {}).id;
  $: tabDots.update({
    convoys: overview ? `${overview.total}|${overview.scheduled}` : null,                       // an event was created or scheduled
    completed: overview ? `${overview.completed}|${overview.captured}|${overview.cancelled}` : null, // a run finished: a new history record
    rivals: String($rivalsVersion),                                                              // a challenge arrived or changed
    gangs: String($gangVersion && $gangVersion.n),
    staff: String($staffVersion),
  }, editingExisting ? 'convoys' : openPageId);

  // $: clock = new Date()... alone never re-runs — Svelte's reactivity only
  // tracks variable references, not "call this again over time," so the
  // clock was frozen at whatever moment the tablet opened. Tick `now` on an
  // actual interval and derive the display string from that instead.
  let now = new Date();
  let clockInterval;
  onMount(() => {
    clockInterval = setInterval(() => { now = new Date(); }, 1000);
  });
  onDestroy(() => clearInterval(clockInterval));

  // 'top' (default): floating tabs across the top; 'side': the classic rail
  $: navTop = $adminPrefs.navLayout !== 'side';
  // "Operations Hub — Admin: <name>": the signed-in name lives in the title bar, next to the role badge
  $: roleLabel = $bootstrap?.branding?.tabletBadge || ($bootstrap ? ($bootstrap.isAdmin ? 'Admin' : $bootstrap.isPolice ? 'Police' : 'Staff') : '');

  $: clock = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: !$adminPrefs.clock24 });
  $: if (typeof document !== 'undefined' && $bootstrap?.branding?.tabletTitle) {
    document.title = $bootstrap.branding.tabletTitle;
  }
</script>

<svelte:window on:keydown={handleKeydown} />

{#if $tabletOpen}
  <div class="backdrop" class:tablet-hidden={$tabletMinimized} data-ui-scope="admin" data-bg={$adminPrefs.bgTheme} style={$adminThemeStyle} transition:fade={{ duration: 140 }}>
    <div class="frame" style="--tablet-bg-img: url('{tabletBg}'); --event-bg-img: url('{eventGradient}');" transition:scale={{ duration: 180, start: 0.97, opacity: 0, easing: cubicOut }}>
      <div class="titlebar">
        <div class="titlebar-left">
          <span class="mark" aria-hidden="true"><svg width="10" height="10" viewBox="0 0 10 10"><rect x="1" y="1" width="8" height="8" fill="none" stroke="currentColor" stroke-width="2" /></svg></span>
          <span class="title">{$bootstrap?.branding?.tabletTitle || 'Operations Hub'}</span>
          {#if $bootstrap}
            <span class="who" title={$bootstrap.playerName}>
              <span class="who-dash" aria-hidden="true">—</span>
              <span class="who-role">{roleLabel}</span>{#if $bootstrap.playerName}<span class="who-colon">:</span><span class="who-name">{$bootstrap.playerName}</span>{/if}
            </span>
          {/if}
        </div>
        <div class="titlebar-right">
          <span class="clock">{clock}</span>
          <button class="close" on:click={close}><Icon name="close" size={14} /></button>
        </div>
      </div>

      {#if loading}
        <div class="empty-state">Authenticating with dispatch...</div>
      {:else if denied}
        <div class="empty-state">Access denied — you are not authorized to use this terminal.</div>
      {:else}
        <div class="body" class:col={navTop}>
          {#if navTop}
            <AdminTopNav groups={visibleGroups} current={navCurrent} sub={$viewSub} dots={$tabDots} on:select={(e) => selectItem(e.detail)} />
          {:else}
          <nav class="sidebar" class:compact={$adminPrefs.sidebar === 'compact'}>
            <div class="nav-list">
              {#each visibleGroups as group (group.title)}
                <div class="nav-group" style="--g: {group.color}">
                  <div class="nav-group-title">{group.title}</div>
                  {#each group.items as item (item.id)}
                    <button class="nav-item" class:active={isActiveItem(item, $currentView, $viewSub)} on:click={() => selectItem(item)}>
                      <Icon name={item.icon} size={16} />
                      <span>{item.label}</span>
                    </button>
                  {/each}
                </div>
              {/each}
            </div>
          </nav>
          {/if}
          <main class="content" style="--view-accent: var(--accent-primary)" bind:this={contentEl}>
            <!-- Create Convoy stays mounted permanently (hidden via CSS, not
                 destroyed) so its unsaved form state survives switching to
                 another tab and back — everything else below still swaps
                 normally, since none of them hold user input worth
                 preserving and staying mounted would mean their own polling
                 (setInterval fetches) running constantly in the background
                 for no reason. -->
            {#if !!$bootstrap && canSeeSection($bootstrap.perms, 'create')}
            <div class:hidden-view={mountView !== 'create'}>
              <CreateConvoy
                convoyId={editConvoyId}
                on:saved={() => currentView.set('convoys')}
                on:reset={() => {
                  editConvoyId = null;
                  if (typeof localStorage !== 'undefined') {
                    localStorage.removeItem('nova_convoy_last_edit_id');
                    localStorage.removeItem('nova_convoy_last_form_tab');
                  }
                }}
              />
            </div>
            {/if}
            {#if !viewAllowed}
              <!-- nothing: this person has no section to show (their access is being re-read) -->
            {:else if mountView === 'dashboard'}
              <Dashboard on:new={startNewConvoy} />
            {:else if mountView === 'convoys'}
              <ConvoysList on:edit={(e) => editConvoy(e.detail)} on:new={startNewConvoy} />
            {:else if mountView === 'participants'}
              <Participants />
            {:else if mountView === 'completed'}
              <CompletedConvoys on:edit={(e) => editConvoy(e.detail)} />
            {:else if mountView === 'gangs'}
              <GangManagement />
            {:else if mountView === 'leaderboard'}
              <Leaderboard />
            {:else if mountView === 'civilianleaderboard'}
              <CivilianLeaderboard />
            {:else if mountView === 'mapzone'}
              <div class="panel view-enter"><div class="panel-header"><span class="panel-title">{activeItem ? activeItem.label : 'Territory Map'}</span></div><div class="panel-body"><GangTerritoryView allowCreateTerritory={true} isGangPanel={false} /></div></div>
            {:else if mountView === 'territories'}
              <TerritoryAdmin />
            {:else if mountView === 'rivals'}
              <div class="panel view-enter">
                <div class="panel-header"><span class="panel-title">Rival Wars &amp; Challenges</span></div>
                <div class="panel-body"><TerritoryRivals /></div>
              </div>
            {:else if mountView === 'tournaments'}
              <Tournaments />
            {:else if mountView === 'tournamenttree'}
              <TournamentTreePage />
            {:else if mountView === 'tournamenthistory'}
              <Tournaments historyOnly={true} />
            {:else if mountView === 'announcements'}
              <Announcements />
            {:else if mountView === 'savedroutes'}
              <SavedRoutes />
            {:else if mountView === 'staff'}
              <StaffManagement />
            {:else if mountView === 'settings'}
              <Settings />
            {:else if mountView === 'guide'}
              <Guide />
            {/if}
          </main>
        </div>
      {/if}
      <ConfirmModal />
    </div>
  </div>
{/if}

<style>
  /* Field dispatch terminal shell — physical bezel, flat graphite inside. */
  /* The territory screens are shared with the gang panel and read its --es-* surface tokens. In the admin tablet those resolve to
     the admin theme's own tokens, so cards, inputs and lines take the chosen background / accent instead of a fixed dark grey. */
  .backdrop {
    --es-card: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72));
    --es-card-hover: var(--c-hover, #272b31);
    --es-raised: var(--c-raised, #1f2328);
    --es-inset: var(--glass-head, rgba(var(--ltc-8-11-16, 8, 11, 16), 0.5));
    --es-line: var(--tablet-border, #2a2e35);
    --es-line-strong: var(--tablet-border-strong, #363b43);
    --es-line-soft: var(--c-line-soft, #1f2328);
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--ltc-4-5-6, 4, 5, 6), 0.62);
    pointer-events: all;
    opacity: 1;
    transition: opacity 0.16s ease;
  }
  .backdrop.tablet-hidden {
    opacity: 0;
    pointer-events: none;
  }

  /* Sized against the viewport so it always fits on screen (never taller than
     the game window) yet uses nearly all of it. The 7px outline is the
     device bezel; inside, everything is flat. */
  .frame {
    position: relative;
    width: min(1720px, calc(96vw - 14px));
    height: min(960px, calc(94vh - 14px));
    background-color: var(--lt-07090d, #07090d);
    /* the first layer is the Settings → Appearance background veil (invisible for the default Graphite) */
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent)));
    background-size: cover;
    background-position: center center;
    background-repeat: no-repeat;
    border: 1px solid rgba(85, 118, 160, 0.3);
    border-radius: var(--r-frame);
    outline: 7px solid var(--c-bezel);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.7);
  }

  .titlebar {
    height: 44px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 12px 0 18px;
    border-bottom: 1px solid rgba(110, 140, 180, 0.2);
    background: rgba(var(--ltc-10-12-16, 10, 12, 16), 0.88);
  }
  .titlebar-left {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
  }
  .mark {
    width: 18px;
    height: 18px;
    flex-shrink: 0;
    display: grid;
    place-items: center;
    border: 1px solid var(--c-line);
    border-radius: var(--r-tag);
    color: var(--c-action);
  }
  .title {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-weight: 600;
    font-size: var(--fs-title);
    letter-spacing: 0.02em;
    color: var(--c-text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .who {
    display: inline-flex;
    align-items: baseline;
    min-width: 0;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-title);
    font-weight: 600;
    letter-spacing: 0.02em;
    white-space: nowrap;
  }
  .who-dash { margin-right: 8px; color: var(--c-text-3); }
  .who-role { color: var(--c-text-2); }
  .who-colon { margin-right: 6px; color: var(--c-text-2); }
  .who-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; color: var(--c-action); }
  .titlebar-right {
    display: flex;
    align-items: center;
    gap: 14px;
  }
  .clock {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-weight: 600;
    font-size: var(--fs-title);
    color: var(--c-text);
    min-width: 48px;
    text-align: right;
  }
  .close {
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    color: var(--c-text-2);
    width: 30px;
    height: 30px;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }
  .close:hover {
    background: rgba(255, 93, 80, 0.12);
    border-color: rgba(255, 93, 80, 0.5);
    color: var(--lt-ff8076, #ff8076);
  }

  .body {
    flex: 1;
    display: flex;
    min-height: 0;
  }
  /* floating top tabs: the menu sits above the page, the page gets the whole width */
  .body.col { flex-direction: column; }
  .body.col .content { padding-top: 14px; }

  /* Sidebar: darker rail, grouped, blue edge marks the open screen */
  .sidebar {
    width: 240px;
    flex-shrink: 0;
    position: relative;
    border-right: 1px solid rgba(110, 140, 180, 0.18);
    /* translucent, like the panels, so the frame's gradient shows through the rail instead of a flat black slab */
    background:
      linear-gradient(180deg, rgba(var(--ltc-30-42-58, 30, 42, 58), 0.5) 0%, rgba(var(--ltc-12-16-23, 12, 16, 23), 0.55) 55%, rgba(var(--ltc-8-10-15, 8, 10, 15), 0.7) 100%);
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    z-index: 1;
  }
  .nav-list {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    justify-content: flex-start;
    gap: 12px;
    padding: 10px 8px 20px;
    overflow-y: auto;
  }
  .nav-group {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  /* Each group has one hue (--g, from NAV_GROUPS): its heading, a fading rule after the heading, the icon tiles,
     and the active tab all use it, so the rail reads as seven colour-coded sections. */
  .nav-group-title {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 10px 5px;
    font-family: var(--font-ui);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    white-space: nowrap;
    color: color-mix(in srgb, var(--g, var(--c-text-3)) var(--g-text-mix, 100%), #000);
  }
  .nav-group-title::after {
    content: '';
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, color-mix(in srgb, var(--g, #9fb0c7) 45%, transparent) 0%, transparent 100%);
  }
  .nav-item {
    position: relative;
    display: flex;
    align-items: center;
    gap: 10px;
    text-align: left;
    background: transparent;
    border: 0;
    border-radius: var(--r-ctl);
    color: var(--c-text-2);
    font-family: var(--font-ui);
    font-size: clamp(13.5px, 1.4vh, 15px);
    line-height: 16px;
    font-weight: 500;
    min-height: clamp(30px, 3.4vh, 38px);
    padding: 0 10px 0 6px;
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }
  /* the icon sits in a tinted tile in the group's hue */
  .nav-item :global(svg) {
    box-sizing: border-box;
    width: 26px;
    height: 26px;
    padding: 5px;
    flex-shrink: 0;
    border-radius: 7px;
    color: color-mix(in srgb, var(--g, #9fb0c7) var(--g-text-mix, 100%), #000);
    background: color-mix(in srgb, var(--g, #9fb0c7) 13%, transparent);
    border: 1px solid color-mix(in srgb, var(--g, #9fb0c7) 24%, transparent);
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, transform 0.15s ease;
  }
  .nav-item:hover {
    background: linear-gradient(90deg, color-mix(in srgb, var(--g, #9fb0c7) 14%, transparent) 0%, color-mix(in srgb, var(--g, #9fb0c7) 2%, transparent) 100%);
    color: var(--c-text);
  }
  .nav-item:hover :global(svg) {
    background: color-mix(in srgb, var(--g, #9fb0c7) 24%, transparent);
    border-color: color-mix(in srgb, var(--g, #9fb0c7) 45%, transparent);
  }
  /* the open screen: a solid tile with a dark glyph, a hue-tinted row and a marker on the rail's edge */
  .nav-item.active {
    background: linear-gradient(90deg, color-mix(in srgb, var(--g, #4f94e6) 26%, transparent) 0%, color-mix(in srgb, var(--g, #4f94e6) 6%, transparent) 100%);
    color: var(--c-text);
    font-weight: 600;
  }
  .nav-item.active :global(svg) {
    color: #0b0f16;
    background: var(--g, var(--c-action));
    border-color: var(--g, var(--c-action));
  }
  .nav-item.active::before {
    content: '';
    position: absolute;
    left: -8px;
    top: 6px;
    bottom: 6px;
    width: 3px;
    border-radius: 0 3px 3px 0;
    background: var(--g, var(--c-action));
  }
  .sidebar.compact .nav-list { gap: 8px; padding-bottom: 10px; }
  .sidebar.compact .nav-item { min-height: 29px; font-size: var(--fs-small); }
  .sidebar.compact .nav-item :global(svg) { width: 22px; height: 22px; padding: 4px; }

  .content {
    flex: 1;
    min-width: 0;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 20px 22px 24px;
    background: transparent;
    -webkit-overflow-scrolling: touch;
    overscroll-behavior-y: contain;
  }
  .hidden-view {
    display: none;
  }

  .empty-state {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--c-text-3);
    font-size: var(--fs-body);
  }

  @media (max-width: 1150px) {
    .sidebar { width: 206px; }
    .content { padding: 16px 16px 20px; }
  }
</style>
