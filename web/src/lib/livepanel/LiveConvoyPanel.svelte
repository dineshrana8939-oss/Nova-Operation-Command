<script>
  import { onMount, onDestroy } from 'svelte';
  import { fade, scale } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';
  import { livePanelOpen, livePanelBrand, gangVersion } from '../stores.js';
  import { fetchNui } from '../api/nui.js';
  import {
    getActiveConvoys, joinConvoyGang, leaveConvoyGang, getRosterConvoys, setConvoyRoster, setGangRegistered,
    getUpcomingConvoys,
    unregisterSelfFromGangConvoy, getStatusPanelAccess,
  } from '../api/runtime.js';
  import { addOwnGangMember, removeOwnGangMember, setOwnGangLeader, setOwnGangLogo, getAvailableGangRecruits } from '../api/gang.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import StatStrip from './components/StatStrip.svelte';
  import ConvoyTable from './components/ConvoyTable.svelte';
  import ConvoyDrawer from './components/ConvoyDrawer.svelte';
  import RosterDrawer from './components/RosterDrawer.svelte';
  import MyRegistrationsTable from './components/MyRegistrationsTable.svelte';
  import LeaderboardView from './components/LeaderboardView.svelte';
  import TournamentView from './components/TournamentView.svelte';
  import GangManagementView from './components/GangManagementView.svelte';
  import GangSettingsView from './components/GangSettingsView.svelte';
  import GangGuideView from './components/GangGuideView.svelte';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import { newDots } from '../tablet/ui/newDots.js';
  import { rivalsVersion } from '../territory/territoryStore.js';
  import '../../styles/flat.css';
  import { get } from 'svelte/store';
  import { crosshairPanelOpen } from '../hud/hudStore.js';
  import GangTerritoryView from '../territory/GangTerritoryView.svelte';
  import ToastNotification from './components/ToastNotification.svelte';
  import ConfirmModal from '../tablet/ui/ConfirmModal.svelte';   // the shared 'are you sure?' dialog: without it every confirmAction() here waits for ever
  import '../tablet/tablet-theme.css';
  import eventGradient from '../../assets/tablet-bg.jpg';   // the Event Hub's own background (the CSS name stays --event-bg-img)

  // Roles here are capability-driven so a leader-granted role sees exactly the
  // tabs it was given: My Gang needs manageGang, My Registrations needs
  // registerRoster. showGangTabs still keeps ordinary on-duty police out of
  // gang views entirely.
  const TABS = [
    { id: 'convoys', label: 'Events', icon: 'list', subtitle: 'Browse upcoming and active events' },
    { id: 'registered', label: 'My Registrations', icon: 'check', requires: 'canRegisterRoster', hidePolice: true, subtitle: 'Convoys your gang has registered for' },
    { id: 'tournament', label: 'Tournaments', icon: 'flag', hidePolice: true, subtitle: 'TDM tournament groups, matches and bracket' },
    { id: 'leaderboard', label: 'Leaderboard', icon: 'trophy', hidePolice: true, subtitle: 'Track gang performance across convoy activities' },
    { id: 'territory', label: 'Map Zone', icon: 'pin', hidePolice: true, subtitle: 'Your zone on the live map, your earned Gang XP, expansion and rivals' },
    { id: 'mygang', label: 'My Gang', icon: 'users', requires: 'canSeeGang', hidePolice: true, subtitle: 'Gang operations & member roster management' },
    { id: 'settings', label: 'Settings', icon: 'gear', subtitle: 'Theme, click sounds and your custom crosshair' },
    { id: 'guide', label: 'Guide', icon: 'fileText', hidePolice: true, subtitle: 'A quick guide for gang players' },
  ];

  // A tab with no `requires` is always visible; otherwise the named capability
  // flag above must be true for it to appear.
  //
  // Until the first access response lands (accessLoaded false) permission-gated
  // tabs are rendered rather than hidden — assuming "hidden" was what caused
  // the leader's own tabs to vanish for the first few seconds of the very first
  // open. Once a real answer arrives the flag is authoritative and they hide
  // correctly for someone genuinely without the capability.
  // Any gang member may open My Gang (read-only); editing needs manageGang.
  function capFor(name) {
    if (name === 'canSeeGang') return canManageGang || !!roster?.gangName;
    return name === 'canManageGang' ? canManageGang : canRegisterRoster;
  }
  function tabVisible(t) {
    if (t.requires && accessLoaded && !capFor(t.requires)) return false;
    if (t.hidePolice && accessLoaded && !showGangTabs) return false;
    return true;
  }

  let activeTab = 'convoys';

  // Server-decided capabilities for this panel (see
  // nova_convoytruck:getStatusPanelAccess). The command itself is gated
  // server-side, so by the time this component mounts the player is already
  // authorized — these flags only control WHICH tabs they see.
  //
  // canManageGang / canRegisterRoster are the caller's EFFECTIVE capabilities,
  // resolved server-side from their gang role (a leader always holds both; a
  // member holds whatever their role was granted). Admins who don't lead a gang
  // manage gangs from the tablet's admin panel instead — deliberately separate
  // surfaces.
  let canManageGang = false;
  let panelIsLeader = false;
  // Signing the gang up for events on the leader's behalf. Also role-driven, so
  // a member the leader granted 'registerRoster' sees the register controls.
  let canRegisterRoster = false;

  // False until the first permission fetch resolves. This is what stops the
  // panel painting with only the ungated tabs (Convoys + Leaderboard) on the
  // very first open: tabVisible() below treats "not yet known" as "show it",
  // and the nav bar renders a placeholder until access is actually resolved.
  // Previously the flags simply started at false — indistinguishable from a
  // real "no permission" answer — so a leader saw 2 tabs until the next 4s
  // poll (or a close/reopen, since the component is never destroyed and the
  // flags stayed true from last time).
  let accessLoaded = false;

  // WHY the register buttons / My Registrations / role tools may be missing (from the server's access answer), so the panel says it
  // instead of silently hiding them: an on-duty government job, or a gang role without "Register for Events".
  let accessWhy = { govJob: null, missing: null, rank: null };
  $: whyText = accessWhy.govJob
    ? `You are on duty as ${accessWhy.govJob}, so the gang tools (registering the gang, My Gang) are switched off. Go off duty to get them back.`
    : accessWhy.missing === 'role'
      ? `Your gang role (${accessWhy.rank || 'Member'}) is not allowed to register the gang for events. Ask your gang leader — or an admin, under Gang Management → Roles & Permissions — to switch on “Register for Events” for it.`
      : '';

  // Live ticking clock
  let now = new Date();
  let clockInterval;
  onMount(() => { clockInterval = setInterval(() => { now = new Date(); }, 1000); });
  onDestroy(() => clearInterval(clockInterval));
  $: clock = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

  // Core Data
  let convoys = [];
  let isPolice = false;
  let myGang = null;
  let error = '';
  let pollInterval;
  let upcomingConvoys = [];
  let unregisteringSelf = {};

  // Gang Roster & Membership State
  let roster = { isLeader: false, gangName: null, members: [], convoys: [] };
  let rosterLoaded = false;
  let rosterDraft = {}; // convoyId -> Set(identifier)
  let rosterSaving = {};
  let rosterError = '';

  let memberBusy = false;
  let memberError = '';
  let logoBusy = false;
  let availableRecruits = [];

  // Active Drawers
  let drawerConvoy = null; // Convoy currently open in the right-side detail drawer
  let rosterConvoy = null; // Convoy currently open in the mission roster preparation drawer

  // Local Toast System
  let toasts = [];
  let toastId = 0;
  function showToast(message, type = 'info', title = '') {
    const id = ++toastId;
    toasts = [...toasts, { id, message, type, title }];
    setTimeout(() => {
      toasts = toasts.filter((t) => t.id !== id);
    }, 4500);
  }
  function dismissToast(id) {
    toasts = toasts.filter((t) => t.id !== id);
  }

  // A gang leader is shown gang-leader tooling even if they're also on a
  // police job — being an on-duty officer shouldn't erase the fact that they
  // lead a gang (same combination the server now allows). The hidePolice
  // exclusion exists to keep ordinary cops out of gang views, not to strip a
  // leader of their own gang.
  // Government view (a gang member on an on-duty police / EMS / government job): every gang tab is hidden, the Events tab lists only
  // Convoy, Rally Race and Container Wars (the server filters the list), and the server gives them no gang capabilities.
  // Decided by DUTY on the server, so going off duty gives the gang tabs back.
  let govView = false;
  $: showGangTabs = !govView;
  // a tab that just became hidden must not stay open
  $: if (accessLoaded && govView && activeTab !== 'convoys' && activeTab !== 'settings') activeTab = 'convoys';

  // My Gang is gated on the manageGang CAPABILITY, not on leadership — that's
  // the whole point of the role permissions: the leader can hand this tab to a
  // trusted role. My Registrations is likewise driven by its own capability, so
  // the two can be granted independently.
  $: if (activeTab === 'mygang' && accessLoaded && rosterLoaded && !canManageGang && !roster?.gangName) activeTab = 'convoys';
  $: if (activeTab === 'registered' && accessLoaded && !canRegisterRoster) activeTab = 'convoys';

  // Format scheduled timestamps
  function formatScheduled(ts) {
    if (!ts) return 'Unscheduled';
    const d = new Date(ts * 1000);
    const dateStr = d.toLocaleDateString([], { day: '2-digit', month: 'short', year: 'numeric' });
    const timeStr = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return `${dateStr} • ${timeStr}`;
  }

  // Merged convoys for the Convoys table
  $: allConvoys = [
    ...convoys,
    ...upcomingConvoys.filter((u) => !convoys.some((c) => c.id === u.id)),
  ];

  // Registered Convoys where gang has registered
  // a small dot on a tab when something new appeared there since it was last opened (see ui/newDots.js)
  const tabDots = newDots('nova_gang_new_dots');
  $: tabDots.update({
    convoys: allConvoys.length ? allConvoys.map((c) => c.id).join(',') : null,   // a new event was published
    territory: String($rivalsVersion),                                         // a rival challenge / war changed
  }, activeTab);
  $: registeredConvoys = (canRegisterRoster || roster.isLeader || panelIsLeader)
    ? upcomingConvoys.filter((c) => {
        const rc = roster.convoys?.find((x) => x.id === c.id);
        const hasRoster = rc && rc.roster && rc.roster.length > 0;
        return hasRoster || c.gangRegistered;
      })
    : upcomingConvoys.filter((c) => c.gangRegistered);

  // Priority Featured Convoy: next active or next upcoming convoy
  $: featuredConvoy = convoys.length > 0 ? convoys[0] : (upcomingConvoys.length > 0 ? upcomingConvoys[0] : null);

  // Compact Stats Strip for Convoys tab
  $: upcomingCount = upcomingConvoys.length;
  $: regOpenCount = upcomingConvoys.filter((c) => {
    const max = c.maxGangParticipants || 5;
    const rc = roster.convoys?.find((x) => x.id === c.id);
    return (rc?.roster?.length || 0) < max;
  }).length;
  $: activeCount = convoys.length;
  $: completedEstimated = 12; // Base stat for completed runs
  $: convoyTabStats = [
    { label: 'Upcoming', value: upcomingCount, icon: 'calendar', accent: '#5aa9e6' },
    { label: 'Registration Open', value: regOpenCount, icon: 'zap', accent: '#e0b252' },
    { label: 'Active Runs', value: activeCount, icon: 'truck', accent: '#70b982' },
    { label: 'Completed Missions', value: completedEstimated, icon: 'checkCircle', accent: '#a78bdb' },
  ];

  // Guards against overlapping poll cycles. These 4 calls used to run as
  // sequential awaits, which caused two real bugs: (1) each awaited gap left
  // the panel rendering with a MIX of fresh and stale reactive state for a
  // moment — e.g. isPolice just updated but canManageGang/panelIsLeader
  // still holding the previous cycle's value — visible as permission-driven
  // tabs/badges flickering; and (2) if one cycle's round-trip was slow (a
  // server hitch), the next setInterval(refresh, 4000) tick fired on top of
  // it, so two getStatusPanelAccess() calls could be in flight at once and
  // whichever response landed LAST won — even if it was the OLDER, slower
  // one carrying stale permissions. Running the independent fetches
  // together via Promise.all collapses the inconsistent-state window to
  // one atomic update, and the isRefreshing guard stops cycles from
  // overlapping in the first place.
  let isRefreshing = false;
  // Every refresh takes a ticket; a response that is no longer the newest ticket
  // is dropped, so a slow older answer can never overwrite a fresher one (which
  // is what briefly hid the leader's tabs after opening the panel).
  let refreshSeq = 0;
  let deniedStreak = 0;
  // The poll below also re-asks whether THIS character may use the panel at all. A player who switches character while it is open
  // (gang character -> EMS / police character) gets the panel closed instead of a gang view for someone who is not in the gang.
  let notAllowedStreak = 0;
  // The poll runs every 4 s. Replacing the data with an identical copy would still re-render the whole table (and every
  // derived list), so each answer is compared with the previous one and only applied when something really changed.
  const lastSig = { active: '', roster: '', upcoming: '' };
  // slowToo = also ask the (rarely changing) permission answer and the full roster. The 4 s poll does that every 5th time only (20 s);
  // every explicit refresh() (after an action, on open) still asks for everything at once.
  async function refresh(slowToo = true) {
    if (isRefreshing) return;
    isRefreshing = true;
    const ticket = ++refreshSeq;
    try {      // Each call is caught individually — a single failed round-trip (a
      // slow first-open NUI call, a network hiccup) must not blank out the
      // other three. Promise.all alone would reject the WHOLE batch on any
      // one failure, silently skipping canManageGang/canRegisterRoster too
      // and leaving the leader's own tabs missing until the next poll (or a
      // manual close/reopen) happened to succeed.
      const [res, accessRes, rosterRes, upcomingRes] = await Promise.all([
        getActiveConvoys().catch(() => null),
        slowToo ? getStatusPanelAccess().catch(() => null) : Promise.resolve(null),
        slowToo ? getRosterConvoys().catch(() => null) : Promise.resolve(null),
        getUpcomingConvoys().catch(() => null),
      ]);

      if (ticket !== refreshSeq) return;

      if (res && res.ok) {
        if (res.govView !== undefined) govView = !!res.govView;
        const sig = JSON.stringify([res.convoys, res.isPolice, res.myGang]);
        if (sig !== lastSig.active) {
          lastSig.active = sig;
          convoys = res.convoys || [];
          isPolice = res.isPolice;
          myGang = res.myGang;
        }
      }

      // Refreshed alongside the convoy data so a promotion/demotion or an
      // admin grant/revoke lands without needing the panel reopened.
      if (accessRes && accessRes.ok && accessRes.allowed === false) {
        notAllowedStreak += 1;
        if (notAllowedStreak >= 2) { notAllowedStreak = 0; close(); return; }
      } else if (accessRes) {
        notAllowedStreak = 0;
      }
      if (accessRes && accessRes.ok) {
        govView = !!accessRes.govView;
        accessWhy = { govJob: accessRes.govJob || null, missing: accessRes.missing || null, rank: accessRes.gangRank || null };
        const next = {
          manage: !!accessRes.canManageGang,
          leader: !!accessRes.isLeader,
          register: !!accessRes.canRegisterRoster,
        };
        // Gaining a capability applies at once. Losing one must be confirmed by a
        // second answer, so a single odd response (gang data still syncing right
        // after open) can't strip a leader's tabs.
        const losing = accessLoaded && ((canManageGang && !next.manage) || (panelIsLeader && !next.leader) || (canRegisterRoster && !next.register));
        deniedStreak = losing ? deniedStreak + 1 : 0;
        if (!losing || deniedStreak >= 2) {
          canManageGang = next.manage;
          panelIsLeader = next.leader;
          canRegisterRoster = next.register;
          deniedStreak = 0;
        }
        // Marks the permission answer as authoritative — only now may the
        // gated tabs actually hide (see tabVisible's accessLoaded check).
        accessLoaded = true;
      }

      if (rosterRes && rosterRes.ok && JSON.stringify(rosterRes) === lastSig.roster) {
        rosterLoaded = true;           // nothing changed since the last poll
      } else if (rosterRes && rosterRes.ok) {
        lastSig.roster = JSON.stringify(rosterRes);
        roster = rosterRes;
        rosterLoaded = true;
        const draft = { ...rosterDraft };
        const stillOpen = new Set(rosterRes.convoys.map((c) => c.id));
        for (const c of rosterRes.convoys) {
          if (!(c.id in draft)) draft[c.id] = new Set(c.roster || []);
        }
        for (const id of Object.keys(draft)) {
          if (!stillOpen.has(Number(id)) && !stillOpen.has(id)) delete draft[id];
        }
        rosterDraft = draft;
      }

      if (upcomingRes && upcomingRes.ok) {
        const sig = JSON.stringify([upcomingRes.convoys, upcomingRes.isPolice]);
        if (sig !== lastSig.upcoming) {
          lastSig.upcoming = sig;
          upcomingConvoys = upcomingRes.convoys || [];
          if (upcomingRes.isPolice !== undefined) isPolice = upcomingRes.isPolice;
        }
      }

      if (activeTab === 'mygang' && canManageGang && !memberBusy) {
        loadRecruits();
      }
    } finally {
      isRefreshing = false;
    }
  }

  async function loadRecruits() {
    const res = await getAvailableGangRecruits();
    if (res && res.ok) availableRecruits = res.players || [];
  }

  // Open Mission Roster Preparation Drawer
  // Container Wars / Territory Auction: the whole gang registers (or unregisters) with one click, no member picking
  async function toggleGangRegistration(convoy, forceOff = false) {
    const on = !forceOff && !registeredConvoys.some((rc) => rc.id === convoy.id);
    const res = await setGangRegistered(convoy.id, on);
    if (!res || !res.ok) {
      showToast((res && res.error) || 'Could not change the registration.', 'error', on ? 'Register Failed' : 'Unregister Failed');
      return;
    }
    showToast(on ? `Your gang is registered for "${convoy.name}": every member may bid.` : 'Gang successfully unregistered from event.', on ? 'success' : 'warning', on ? 'Gang Registered' : 'Unregistered');
    refresh();
  }

  function openRosterPreparation(convoy) {
    if (!convoy) return;
    if (convoy.registrationMode === 'NONE') return;
    if (convoy.registrationMode === 'GANG') { toggleGangRegistration(convoy); return; }
    if (!rosterDraft[convoy.id]) {
      const entry = roster.convoys.find((c) => c.id === convoy.id);
      rosterDraft = { ...rosterDraft, [convoy.id]: new Set(entry?.roster || []) };
    }
    rosterError = '';
    rosterConvoy = convoy;
  }

  function handleToggleRosterMember(e) {
    const identifier = e.detail.identifier;
    if (!rosterConvoy) return;
    const convoyId = rosterConvoy.id;
    const entry = roster.convoys.find((rc) => rc.id === convoyId);
    const max = entry?.maxGangParticipants || rosterConvoy.maxGangParticipants || 5;
    const set = new Set(rosterDraft[convoyId] || []);

    if (set.has(identifier)) {
      set.delete(identifier);
      rosterError = '';
    } else {
      if (set.size >= max) {
        rosterError = `This event allows a maximum of ${max} gang operatives. Remove someone first.`;
        showToast(rosterError, 'warning', 'Roster Limit');
        return;
      }
      rosterError = '';
      set.add(identifier);
    }
    rosterDraft = { ...rosterDraft, [convoyId]: set };
  }

  function handleClearRoster() {
    if (!rosterConvoy) return;
    rosterDraft = { ...rosterDraft, [rosterConvoy.id]: new Set() };
    rosterError = '';
  }

  async function handleSaveRoster() {
    if (!rosterConvoy) return;
    const convoyId = rosterConvoy.id;
    rosterError = '';
    rosterSaving = { ...rosterSaving, [convoyId]: true };
    const identifiers = Array.from(rosterDraft[convoyId] || []);
    const res = await setConvoyRoster(convoyId, identifiers);
    rosterSaving = { ...rosterSaving, [convoyId]: false };

    if (!res || !res.ok) {
      const msg = (res && res.error) || 'Failed to save roster.';
      rosterError = msg;
      showToast(msg, 'error', 'Save Failed');
      return;
    }

    showToast(`Roster deployed for "${rosterConvoy.name}" (${identifiers.length} members).`, 'success', 'Roster Deployed');
    rosterConvoy = null;
    refresh();
  }

  async function handleUnregisterGang(convoyId) {
    const target = upcomingConvoys.find((c) => c.id === convoyId);
    if (target && target.registrationMode === 'GANG') { await toggleGangRegistration(target, true); return; }
    rosterError = '';
    rosterSaving = { ...rosterSaving, [convoyId]: true };
    const res = await setConvoyRoster(convoyId, []);
    rosterSaving = { ...rosterSaving, [convoyId]: false };

    if (!res || !res.ok) {
      const msg = (res && res.error) || 'Failed to unregister.';
      rosterError = msg;
      showToast(msg, 'error', 'Unregister Failed');
      return;
    }

    rosterDraft = { ...rosterDraft, [convoyId]: new Set() };
    showToast('Gang successfully unregistered from event.', 'warning', 'Unregistered');
    if (rosterConvoy?.id === convoyId) rosterConvoy = null;
    refresh();
  }

  // Active convoy participation
  async function handleJoinConvoy(id) {
    const res = await joinConvoyGang(id);
    if (!res || !res.ok) {
      showToast((res && res.error) || 'Failed to join event.', 'error', 'Error');
      return;
    }
    showToast('Joined the active event.', 'success', 'Event Joined');
    refresh();
  }

  async function handleLeaveConvoy(id) {
    const res = await leaveConvoyGang(id);
    if (res && res.ok) {
      showToast('Left the event.', 'info', 'Left Event');
      refresh();
    }
  }

  // Gang Management Actions
  async function handleAddMember(e) {
    const target = e.detail.serverId || e.detail.target;
    memberError = '';
    memberBusy = true;
    const res = await addOwnGangMember(target, e.detail.rank);
    memberBusy = false;

    if (!res || !res.ok) {
      const msg = (res && res.error) || 'Failed to add member.';
      memberError = msg;
      showToast(msg, 'error', 'Recruitment Failed');
      return;
    }

    showToast(`Player "${target}" joined the gang.`, 'success', 'Member Added');
    availableRecruits = availableRecruits.filter((p) => String(p.serverId) !== String(target) && String(p.name).toLowerCase() !== String(target).toLowerCase());
    refresh();
  }

  async function handleRemoveMember(e) {
    const identifier = e.detail.identifier;
    memberError = '';
    memberBusy = true;
    const res = await removeOwnGangMember(identifier);
    memberBusy = false;

    if (!res || !res.ok) {
      const msg = (res && res.error) || 'Failed to remove member.';
      memberError = msg;
      showToast(msg, 'error', 'Removal Failed');
      return;
    }

    showToast('Member removed from gang.', 'warning', 'Member Removed');
    refresh();
  }

  async function handlePromoteMember(e) {
    const identifier = e.detail.identifier;
    memberError = '';
    memberBusy = true;
    const res = await setOwnGangLeader(identifier);
    memberBusy = false;

    if (!res || !res.ok) {
      const msg = (res && res.error) || 'Failed to promote member.';
      memberError = msg;
      showToast(msg, 'error', 'Promotion Failed');
      return;
    }

    showToast('Leadership transferred successfully.', 'success', 'Promotion');
    refresh();
  }

  async function handleUploadLogo(e) {
    logoBusy = true;
    const res = await setOwnGangLogo(e.detail);
    logoBusy = false;
    if (res && res.ok) {
      showToast('Gang insignia logo updated.', 'success', 'Logo Saved');
    }
    refresh();
  }

  async function handleRemoveLogo() {
    logoBusy = true;
    await setOwnGangLogo(null);
    logoBusy = false;
    showToast('Gang insignia logo removed.', 'info', 'Logo Removed');
    refresh();
  }

  function close() {
    livePanelOpen.set(false);
    drawerConvoy = null;
    rosterConvoy = null;
    fetchNui('livepanel:close', {});
  }

  function handleKeydown(e) {
    // Esc closes the crosshair designer first (when it was opened from Settings), not this whole panel
    if (e.key === 'Escape' && !drawerConvoy && !rosterConvoy && !get(crosshairPanelOpen)) close();
  }

  // Opening the panel must ALWAYS start a fresh cycle. Previously this called
  // refresh() through the same isRefreshing guard as the 4s poll, so if a
  // previous cycle had been left in flight (or a stale one was still awaiting
  // a slow round-trip), the first refresh of the new open was silently
  // dropped and the panel sat on its old — or default — permission state until
  // the next poll. Clearing the guard on open makes the toggle deterministic.
  $: if ($livePanelOpen) {
    isRefreshing = false;
    deniedStreak = 0;
    refresh();
    clearInterval(pollInterval);
    let pollN = 0;
    pollInterval = setInterval(() => refresh(++pollN % 5 === 0), 4000);
  } else {
    clearInterval(pollInterval);
    resetCharacterState();
  }

  // Everything this panel knows about the player belongs to ONE character (gang member, police officer, EMS ... — a player
  // can keep several). The component stays mounted between openings, so without this the next opening — possibly as another
  // character — would start from the previous character's tabs and gang tools until the first answer arrived.
  function resetCharacterState() {
    accessLoaded = false;
    accessWhy = { govJob: null, missing: null, rank: null };
    govView = false;
    canManageGang = false;
    panelIsLeader = false;
    canRegisterRoster = false;
    isPolice = false;
    myGang = null;
    convoys = [];
    upcomingConvoys = [];
    roster = { isLeader: false, gangName: null, members: [], convoys: [] };
    rosterLoaded = false;
    rosterDraft = {};
    availableRecruits = [];
    lastSig.active = ''; lastSig.roster = ''; lastSig.upcoming = '';
    activeTab = 'convoys';
    drawerConvoy = null;
    rosterConvoy = null;
  }

  // A role, rank, member or setting of a gang changed (the admin tablet edits the very same data this panel shows): re-ask for
  // the permissions and the roster now, so a tab the player just gained or lost shows up without waiting for the 20 s poll.
  let gangSeenN = 0;
  $: if ($gangVersion.n !== gangSeenN) {
    gangSeenN = $gangVersion.n;
    if ($livePanelOpen) { if (isRefreshing) setTimeout(() => refresh(true), 400); else refresh(true); }
  }

  onDestroy(() => clearInterval(pollInterval));
</script>

<svelte:window on:keydown={handleKeydown} />

{#if $livePanelOpen}
  <div class="backdrop" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} style="--event-bg-img: url('{eventGradient}');{$gangThemeStyle}" transition:fade={{ duration: 140 }}>
    <div class="frame" transition:scale={{ duration: 180, start: 0.97, opacity: 0, easing: cubicOut }}>
      <!-- Titlebar Header -->
      <header class="titlebar">
        <div class="titlebar-left">
          <span class="pulse-dot"></span>
          <div class="titlebar-title-group">
            <span class="title">{$livePanelBrand.title}</span>
            {#if $livePanelBrand.badge}<span class="titlebar-badge">{$livePanelBrand.badge}</span>{/if}
          </div>
        </div>

        <nav class="nav-segment-bar" aria-label="Main Navigation">
          <div class="nav-tabs-wrapper">
            {#each TABS as t}
              {#if tabVisible(t)}
                <button
                  class="nav-tab"
                  class:active={activeTab === t.id}
                  title={t.label}
                  on:click={() => {
                    activeTab = t.id;
                    if (t.id === 'mygang' && canManageGang) loadRecruits();
                  }}
                >
                  <Icon name={t.icon} size={15} />
                  <span class="nav-label">{t.label}</span>
                  {#if t.id === 'convoys' && allConvoys.length > 0}
                    <span class="nav-pill">{allConvoys.length}</span>
                  {:else if t.id === 'registered' && registeredConvoys.length > 0}
                    <span class="nav-pill active-pill">{registeredConvoys.length}</span>
                  {/if}
                  {#if $tabDots[t.id] && activeTab !== t.id}<i class="new-dot" title="Something new" aria-label="Something new"></i>{/if}
                </button>
              {/if}
            {/each}
          </div>
        </nav>

        <div class="titlebar-right">
          <div class="clock-display">
            <Icon name="clock" size={13} />
            <span>{clock}</span>
          </div>
          <button class="close-btn" on:click={close} title="Close Panel (ESC)">
            <Icon name="close" size={14} />
          </button>
        </div>
      </header>

      <!-- Panel Body Content -->
      <main class="panel-body">
        {#if error}
          <div class="error-banner">
            <Icon name="warning" size={14} />
            <span>{error}</span>
          </div>
        {/if}
        {#if whyText && accessLoaded && (activeTab === 'convoys' || activeTab === 'mygang' || activeTab === 'registered')}
          <div class="error-banner why-banner" role="status">
            <Icon name="info" size={14} />
            <span>{whyText}</span>
          </div>
        {/if}

        <!-- TAB 1: CONVOYS -->
        {#if activeTab === 'convoys'}
          <div class="view-header">
            <div class="view-title-col">
              <h2 class="view-title">Events</h2>
              <p class="view-subtitle">Browse upcoming and active events</p>
            </div>
          </div>

          <!-- Compact Statistics Strip -->
          <StatStrip stats={convoyTabStats} />

          <!-- Convoy Event List Table -->
          <div class="table-flex-grow">
            <ConvoyTable
              convoys={allConvoys}
              priorityConvoyId={featuredConvoy?.id}
              {isPolice}
              isLeader={roster.isLeader}
              {canRegisterRoster}
              {registeredConvoys}
              {formatScheduled}
              on:viewDetails={(e) => (drawerConvoy = e.detail)}
              on:register={(e) => openRosterPreparation(e.detail)}
              on:join={(e) => handleJoinConvoy(e.detail)}
              on:leave={(e) => handleLeaveConvoy(e.detail)}
            />
          </div>

        <!-- TAB 2: REGISTERED (My Registrations) -->
        {:else if activeTab === 'registered'}
          <div class="view-header">
            <div class="view-title-col">
              <h2 class="view-title">My Registrations</h2>
              <p class="view-subtitle">Convoys your gang has registered for</p>
            </div>
          </div>

          <MyRegistrationsTable
            {registeredConvoys}
            {roster}
            isLeader={roster.isLeader}
            {canRegisterRoster}
            {formatScheduled}
            on:editRoster={(e) => openRosterPreparation(e.detail)}
            on:viewDetails={(e) => (drawerConvoy = e.detail)}
            on:unregisterAll={(e) => handleUnregisterGang(e.detail)}
            on:browseConvoys={() => (activeTab = 'convoys')}
            on:join={(e) => handleJoinConvoy(e.detail)}
            on:leave={(e) => handleLeaveConvoy(e.detail)}
          />

        <!-- TAB: TDM TOURNAMENTS -->
        {:else if activeTab === 'tournament'}
          <TournamentView myGangName={roster.gangName || myGang?.name} />

        <!-- TAB 3: LEADERBOARD -->
        {:else if activeTab === 'leaderboard'}
          <LeaderboardView myGangName={roster.gangName || myGang?.name} />

        <!-- TAB: TERRITORY (live map, Gang XP, expansion, rivals) -->
        {:else if activeTab === 'territory'}
          <GangTerritoryView allowCreateTerritory={false} isGangPanel={true} />

        <!-- TAB 4: MY GANG -->
        {:else if activeTab === 'mygang'}
        <GangManagementView
          {roster}
          {availableRecruits}
          {logoBusy}
          {memberBusy}
          {memberError}
          {canManageGang}
          isLeader={panelIsLeader}
          on:changed={refresh}
          on:uploadLogo={handleUploadLogo}
          on:removeLogo={handleRemoveLogo}
          on:addMember={handleAddMember}
          on:removeMember={handleRemoveMember}
          on:promoteMember={handlePromoteMember}
          on:refreshRecruits={loadRecruits}
        />

        <!-- TAB: SETTINGS (this tablet's theme, click sounds, your crosshair) -->
        {:else if activeTab === 'settings'}
          <div class="view-header">
            <div class="view-title-col">
              <h2 class="view-title">Settings</h2>
              <p class="view-subtitle">Theme, click sounds and your custom crosshair</p>
            </div>
          </div>
          <GangSettingsView />

        <!-- TAB: GUIDE (player quick guide) -->
        {:else if activeTab === 'guide'}
          <div class="view-header">
            <div class="view-title-col">
              <h2 class="view-title">Quick Guide</h2>
              <p class="view-subtitle">How to use this tablet</p>
            </div>
          </div>
          <GangGuideView />
        {/if}
      </main>
    </div>

    <!-- Right-Side Details Drawer -->
    <ConvoyDrawer
      convoy={drawerConvoy}
      isOpen={!!drawerConvoy}
      {isPolice}
      isLeader={roster.isLeader}
      {canRegisterRoster}
      {myGang}
      {roster}
      isRegistered={drawerConvoy && registeredConvoys.some((rc) => rc.id === drawerConvoy.id)}
      {formatScheduled}
      on:close={() => (drawerConvoy = null)}
      on:register={(e) => openRosterPreparation(e.detail)}
      on:join={(e) => handleJoinConvoy(e.detail)}
      on:leave={(e) => handleLeaveConvoy(e.detail)}
    />

    <!-- Mission Crew Roster Preparation Drawer -->
    <RosterDrawer
      isOpen={!!rosterConvoy}
      convoy={rosterConvoy}
      rosterEntry={rosterConvoy && roster.convoys.find((rc) => rc.id === rosterConvoy.id)}
      members={roster.members || []}
      draftSet={rosterConvoy ? (rosterDraft[rosterConvoy.id] || new Set()) : new Set()}
      saving={rosterConvoy && rosterSaving[rosterConvoy.id]}
      error={rosterError}
      {formatScheduled}
      on:toggleMember={handleToggleRosterMember}
      on:clear={handleClearRoster}
      on:cancel={() => (rosterConvoy = null)}
      on:save={handleSaveRoster}
      on:unregisterAll={() => rosterConvoy && handleUnregisterGang(rosterConvoy.id)}
    />

    <!-- Toast Notifications -->
    <ToastNotification {toasts} onDismiss={dismissToast} />
    <ConfirmModal />
  </div>
{/if}

<style>
  /* Convoy Status shell — tactical top bar with inline navigation, near-black
     surfaces and a faint ambient grid (see the Convoy Status sample). Token
     overrides are scoped to .backdrop so every child (StatStrip, ConvoyTable,
     drawers…) inherits them without touching the shared theme. */
  .backdrop {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--ltc-3-3-5, 3, 3, 5), 0.6);
    pointer-events: all;
    z-index: 100;

    /* Same theme as the Operations Hub tablet: every colour, border, shadow
       and font token comes from styles/theme.css, so nothing is overridden
       here. The one local token is "your gang", which uses the primary
       accent. */
    --gang: var(--accent-primary);
    --gang-rgb: var(--accent-primary-rgb);

    /* Event Status sits on the deep-blue gradient picture. Instead of near-black cards, every surface is a deep-navy
       pane, so the gradient still shows through but the panel reads dark blue:
         card    = deep navy glass (tiles, tables, side cards)
         raised  = the same, a step lighter (chips, badges, icon wells)
         inset   = nearly-navy-black (search boxes, table heads, segmented controls)
       Text stays white / pale blue-grey for contrast. */
    --text-dim: #d3e0f0;
    --text-muted: #b4c6dc;
    --text-placeholder: #8fa6c2;
    --tablet-text-faint: #b4c6dc;

    --es-card: rgba(20, 26, 36, 0.6);
    --es-card-hover: rgba(30, 38, 52, 0.72);
    --es-raised: rgba(34, 42, 56, 0.68);
    --es-inset: rgba(11, 15, 22, 0.72);
    --es-line: rgba(110, 140, 180, 0.2);
    --es-line-soft: rgba(110, 140, 180, 0.12);
    --es-line-strong: rgba(130, 165, 210, 0.32);
    --es-solid: #131a26;   /* opaque, for dropdown lists */
    --es-accent: #2d66b0;
    --es-accent-hover: #3874c4;
    --es-edge: inset 0 1px 0 rgba(150, 180, 220, 0.06);   /* the pane's lit top edge */

    --tablet-panel: var(--es-card);
    /* the other surface names the shared components read: all on the same glass */
    --tablet-bg: var(--es-inset);
    --tablet-border-hover: var(--es-line-strong);
    --bg-base: var(--es-inset);
    --bg-surface: var(--es-card);
    --bg-card: var(--es-card);
    --bg-card-raised: var(--es-raised);
    --bg-card-hover: var(--es-card-hover);
    --panel-bg: var(--es-card);
    --panel-border: var(--es-line);
    --c-bezel: transparent;
    --input-bg-hover: rgba(16, 22, 32, 0.8);
    --input-bg-focus: rgba(18, 26, 38, 0.9);
    --input-border-hover: var(--es-line-strong);
    --tablet-panel-alt: var(--es-card);
    --card-bg: var(--es-card);
    --tablet-border: var(--es-line);
    --tablet-border-strong: var(--es-line-strong);
    --input-bg: var(--es-inset);
    --input-border: var(--es-line);
    /* surfaces used by the shared tablet components inside this panel */
    --c-base: var(--es-inset);
    --c-panel: var(--es-card);
    --c-raised: var(--es-raised);
    --c-hover: var(--es-card-hover);
    --c-line: var(--es-line);
    --c-line-soft: var(--es-line-soft);
    /* popups, drawers and confirm boxes opened from this panel follow the chosen Appearance background: the theme's opaque
       surface (--es-solid, set per background) under its colour wash (--frame-shade-img / --frame-shade; none for Graphite) */
    --surface-dialog:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent))),
      linear-gradient(180deg, var(--es-solid) 0%, var(--es-solid) 100%);
    --surface-dialog-bar: var(--es-inset);
    --border-dialog: var(--es-line-strong);

    font-family: var(--font-ui);
    font-variant-numeric: tabular-nums;
  }

  /* Sized against the viewport so it always fits on screen, yet uses almost
     all of it. */
  .frame {
    width: min(1800px, 97vw);
    height: min(1000px, 95vh);
    display: flex;
    flex-direction: column;
    background-color: var(--lt-07090d, #07090d);
    /* the deep-blue gradient picture, only lightly shaded (a little more at the bottom, where it is brightest,
       so white text keeps its contrast) */
    /* the first layer is the Settings → Appearance background veil (invisible for the default Graphite) */
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent)));
    background-size: cover;
    background-position: center center;
    background-repeat: no-repeat;
    border: 1px solid rgba(85, 118, 160, 0.3);
    border-radius: var(--r-panel);
    overflow: hidden;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.65);
  }

  /* Top command bar: brand · navigation · clock/close */
  .titlebar {
    height: 64px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 28px;
    padding: 0 24px;
    background: rgba(var(--ltc-8-12-18, 8, 12, 18), 0.55);
    border-bottom: 1px solid var(--es-line);
    box-shadow: none;
  }

  /* native dropdown lists need an opaque colour (a see-through list is unreadable) */
  .backdrop :global(select option) { background: var(--es-solid); color: var(--lt-ffffff, #fff); }
  .backdrop :global(select optgroup) { background: var(--es-solid); color: var(--text-muted); }

  .titlebar-left {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .pulse-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--accent-primary);
    flex-shrink: 0;
    color: var(--on-accent, inherit);
}

  .titlebar-title-group {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .title {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-weight: 700;
    font-size: var(--fs-title);
    letter-spacing: -0.01em;
    color: var(--lt-eceef0, #eceef0);
    white-space: nowrap;
  }

  .titlebar-badge {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: var(--text-main);
    background: var(--btn-soft, var(--c-hover));
    border: 1px solid var(--btn-soft-line, var(--c-line));
    padding: 3px 9px;
    border-radius: var(--r-tag);
  }

  .titlebar-right {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-left: auto;
  }

  .clock-display {
    display: flex;
    align-items: center;
    gap: 8px;
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    font-weight: 500;
    color: var(--lt-c9ced4, #c9ced4);
  }

  .close-btn {
    width: 32px;
    height: 32px;
    border-radius: var(--r-ctl);
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--lt-c9ced4, #c9ced4);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }

  .close-btn:hover {
    color: var(--lt-ffffff, #fff);
    border-color: var(--c-line);
    background: var(--c-hover);
  }

  .nav-segment-bar {
    flex: 1;
    min-width: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .nav-segment-bar::-webkit-scrollbar {
    display: none;
  }

  .nav-tabs-wrapper {
    display: flex;
    align-items: center;
    gap: 6px;
    width: max-content;
  }

  .nav-tab {
    height: 48px;
    display: inline-flex;
    align-items: center;
    gap: 9px;
    padding: 0 clamp(8px, 0.8vw, 18px);   /* follows the screen width so every tab fits at 1366-1920 px */
    border-radius: var(--r-ctl);
    background: transparent;
    border: 1px solid transparent;
    color: var(--lt-e3e6e9, #e3e6e9);
    font-size: var(--fs-emph);
    font-weight: 600;
    cursor: pointer;
    box-shadow: none;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
    white-space: nowrap;
  }
  .nav-tab :global(svg) { width: 19px; height: 19px; }
  /* a small screen: only the open tab shows its name, the others are icons (their name is the tooltip) so none is ever cut off */
  @media (max-width: 1400px) {
    .nav-tab:not(.active) .nav-label { display: none; }
    .nav-tab { padding: 0 12px; }
  }
  @media (max-width: 1700px) {
    .nav-tab { font-size: var(--fs-body); gap: 7px; }
    .nav-tab :global(svg) { width: 17px; height: 17px; }
  }

  .nav-tab:hover {
    color: var(--lt-ffffff, #fff);
    background: var(--es-card-hover);
    border-color: var(--es-line);
  }

  /* the open tab is the theme's accent, solid (the same as the Operations Hub's top tabs) */
  .nav-tab.active {
    color: var(--on-accent);
    background: var(--c-action);
    border-color: var(--c-action);
    box-shadow: none;
  }
  .nav-tab.active :global(svg) {
    color: var(--on-accent);
  }
  .nav-tab.active .nav-pill { background: var(--on-accent); border-color: var(--on-accent); color: var(--c-action); }

  .nav-pill {
    min-width: 20px;
    height: 20px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--r-tag);
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--lt-e3e6e9, #e3e6e9);
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 0 5px;
  }

  .nav-pill.active-pill {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }

  /* Body */
  .panel-body {
    flex: 1;
    min-height: 0;
    /* a view taller than the window (Leaderboard / My Registrations with many rows) scrolls here; it used to be clipped at the bottom */
    overflow-x: hidden;
    overflow-y: auto;
    padding: 18px 28px 28px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    background: transparent;
  }

  /* Makes the events table fill remaining body height after the KPI strip */
  .table-flex-grow {
    flex: 1;
    min-height: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  /* Stretch ConvoyTable root to fill its parent flex wrapper */
  .table-flex-grow :global(.convoy-table-container) {
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }

  /* Allow the scrollable rows area inside ConvoyTable to use available height */
  .table-flex-grow :global(.table-responsive) {
    max-height: none;
    flex: 1;
    min-height: 0;
    overflow-y: auto;
  }

  .error-banner.why-banner { color: #ffc857; border-color: var(--c-line); background: var(--c-raised);
    border-left: 3px solid rgb(255, 200, 87);}
  .error-banner {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 11px 16px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-panel);
    color: var(--tablet-danger);
    font-size: var(--fs-body);
    font-weight: 500;
    border-left: 3px solid #ef4444;}

  /* used by the Tournaments tab too (a child component), so not scoped to this file */
  :global(.view-header) {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 14px;
    flex-wrap: wrap;
  }

  /* used by the Tournaments tab too (a child component), so not scoped to this file */
  :global(.view-title-col) {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  /* used by the Tournaments tab too (a child component), so not scoped to this file */
  :global(.view-title) {
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-weight: 700;
    font-size: var(--fs-title);
    letter-spacing: -0.015em;
    color: var(--lt-ffffff, #fff);
    margin: 0;
    line-height: 24px;
  }

  /* used by the Tournaments tab too (a child component), so not scoped to this file */
  :global(.view-subtitle) {
    font-size: var(--fs-small);
    font-weight: 500;
    color: var(--text-muted, #aeb5bd);
    margin: 0;
    line-height: 18px;
  }

  @media (max-width: 1100px) {
    .titlebar { padding: 0 18px; gap: 16px; }
    .panel-body { padding: 20px; }
  }

  @media (max-width: 900px) {
    .frame {
      width: 100vw;
      height: 100vh;
      border-radius: 0;
      border: none;
    }
    .titlebar-badge, .clock-display { display: none; }
  }
</style>
