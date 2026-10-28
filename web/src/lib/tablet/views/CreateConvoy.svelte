<script>
  import { KIND_TABS } from '../eventKinds.js';
  import { createEventDispatcher, onMount, onDestroy, tick } from 'svelte';
  import { getConvoy, createConvoy, updateConvoy, scheduleConvoy, scheduleRecurringConvoy, unscheduleConvoy, getServerTime } from '../../api/convoy.js';
  import { getGangs } from '../../api/gang.js';
  import { startConvoy, startRaceCountdown } from '../../api/runtime.js';
  import { getPlayerPosition } from '../../api/route.js';
  import {
    getEquipmentVendorLocation, setEquipmentVendorLocation, setEquipmentVendorEnabled,
    getEscortShopLocation, setEscortShopLocation, setEscortShopEnabled,
  } from '../../api/equipment.js';
  import { clearPlacedPreview } from '../../api/placer.js';
  import { CARGO_TYPES, DIFFICULTIES } from '../../constants.js';
  import { bootstrap, currentView, tournamentIntent } from '../../stores.js';
  import { perms } from '../../perms.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import SubTabs from '../ui/SubTabs.svelte';
  import PedRow from '../ui/PedRow.svelte';
  import RewardListEditor from '../ui/RewardListEditor.svelte';
  import DateTimePicker from '../ui/DateTimePicker.svelte';
  import TruckConfig from './TruckConfig.svelte';
  import RouteBuilder from './RouteBuilder.svelte';
  import AirdropZones from './AirdropZones.svelte';
  import HotCargoConfig from './HotCargoConfig.svelte';
  import RallyRaceConfig from './RallyRaceConfig.svelte';
  import TdmConfig from './TdmConfig.svelte';
  import ContainerWarsConfig from './ContainerWarsConfig.svelte';
  import TerritoryConfig from './TerritoryConfig.svelte';
  import CrackdownConfig from './CrackdownConfig.svelte';
  import TerritoryRivals from '../../territory/TerritoryRivals.svelte';
  import { territoryReadiness } from '../../territory/territoryRender.js';
  import PropsPanel from '../ui/PropsPanel.svelte';
  import FormSectionHead from '../ui/FormSectionHead.svelte';
  import GangSelector from '../ui/GangSelector.svelte';
  import '../tablet-theme.css';
  import tabletBg from '../../../assets/tablet-bg.jpg';

  export let convoyId = null;
  const dispatch = createEventDispatcher();

  const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const CONVOY_TABS = ['General', 'Route', 'Trucks', 'Props', 'Review'];
  const AIRDROP_TABS = ['General', 'Airdrop Zones', 'Props', 'Review'];
  const HOT_CARGO_TABS = ['Form', 'Trucks', 'Hot Cargo Drops', 'Props', 'Review'];
  const RALLY_TABS = ['General', 'Race Setup', 'Props', 'Review'];
  const TDM_TABS = ['General', 'Match Setup', 'Props', 'Review'];
  // 'Auction Rules' = Auction Rules + Timers & Pacing; 'Lots & Arena' = Container Lots & Rewards + Bidding Perimeter & Peds
  const CONTAINER_WARS_TABS = ['General', 'Container Wars Setup', 'Props', 'Lots & Arena', 'Auction Rules', 'Review'];
  // Gang Territory Auction: the three specialized tabs
  const TERRITORY_TABS = ['Auction Setup', 'Lots & Bidding', 'Review'];
  // Operation Crackdown (Gang vs Police): everything lives in CrackdownConfig.svelte
  const CRACKDOWN_TABS = ['Operation Setup', 'Combat Zone', 'Rewards & Rules', 'Review'];
  // the tab each event type opens on
  const firstTab = (k) => (k === 'HOT_CARGO' ? 'Form' : k === 'GANG_TERRITORY' ? 'Auction Setup' : k === 'CRACKDOWN' ? 'Operation Setup' : 'General');
  let activeTab = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_form_tab')) || 'General';

  function scrollToTop() {
    tick().then(() => {
      const contentEl = document.querySelector('.content') || document.querySelector('.panel');
      if (contentEl) {
        contentEl.scrollTo({ top: 0, behavior: 'smooth' });
        contentEl.scrollTop = 0;
      }
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
  }

  function setTab(tab) {
    activeTab = tab;
    scrollToTop();
  }

  function nextTab() {
    const idx = TABS.indexOf(activeTab);
    if (idx >= 0 && idx < TABS.length - 1) {
      activeTab = TABS[idx + 1];
      scrollToTop();
    }
  }

  function prevTab() {
    const idx = TABS.indexOf(activeTab);
    if (idx > 0) {
      activeTab = TABS[idx - 1];
      scrollToTop();
    }
  }

  function blank() {
    return {
      name: '',
      shortDescription: '',
      detailedDescription: '',
      // 'CONVOY' (default, everyone with tablet access) or 'GANG_AIRDROP'
      // (admin-only — see the Event Type selector below, hidden entirely
      // from non-admins so a police-job tablet user can't even see the option).
      kind: 'CONVOY',
      cargo: { type: 'CUSTOM', description: '' },
      reward: [{ type: 'MONEY', amount: 0, pool: '' }],
      difficulty: 'MEDIUM',
      eventDuration: 1200,
      maxGangParticipants: 20,
      maxPoliceParticipants: 20,
      maxEscortVehicles: 4,
      escortVehicleHealth: 5000,
      status: 'DRAFT',
      settings: { gangPvp: true, npcPolice: false, armySupport: false, announcements: true, failurePolicy: 'FAIL', lockpicksRequired: '', forceDriveBy: true, requireEscortProximity: true, startAnnounceDelaySeconds: '', maxGangs: 0, maxMembersPerGang: 0, announceStartTime: '', announceEndTime: '', announceMessage: '', allowedGangs: { mode: 'ALL', gangs: [] }, raceEntryMode: 'TEAM', raceVehicleMode: 'OWN', raceCollision: 'ON', raceGridWaitSeconds: '', raceVehicles: [], raceVehiclePed: null, eventAccess: 'GANGS', civilianPed: { enabled: true, x: null, y: null, z: null, heading: 0, model: 'a_m_y_runner_01' } },
      trucks: [],
      route: [],
      checkpoints: [],
      airdrops: [],
      airdropZones: [],
      hotCargo: {
        truckCount: 2,
        policeAlert: true,
        policeAlertBufferSeconds: 45,
        trucks: [],
        spawnZones: [],
        dropoffZones: [],
        salvageReward: [],
      },
      rallyStages: [],
      // GANG_RACE only — see server/modules/convoy_manager.lua's sanitizeDefinition
      // for the full contract. Each is its own reward list, same shape as `reward`.
      positionRewards: { first: [], second: [], third: [], participation: [] },
      // TDM only — see sanitizeTdmConfig in convoy_manager.lua. Participating
      // gangs are NOT stored here — that reuses settings.allowedGangs (mode
      // SELECTED) below, same as Hot Cargo/Gang Airdrop's gang picker.
      tdm: { matchFormat: 'STANDARD', duration: 600, killLimit: 0, zone: {}, weaponVendor: {}, spawnPoints: [], bracket: {} },
      // CONTAINER_WARS only — see sanitizeContainerWarsConfig in convoy_manager.lua
      // GANG_TERRITORY only — see sanitizeTerritoryConfig in convoy_manager.lua (TerritoryConfig.svelte fills the rest)
      territory: { auction: {}, areas: [] },
      // CRACKDOWN only — see sanitizeCrackdownConfig in convoy_manager.lua (CrackdownConfig.svelte fills the rest)
      crackdown: { targetGang: '', zone: {}, prepSeconds: 120, outsideSeconds: 30, minGang: 1, minPolice: 1, gangLoseXpPenalty: 0, policeReward: [], messages: {} },
      containerWars: {
        maxContainers: 4,
        containersPerRound: 4,
        crane: { x: null, y: null, z: null, heading: 0, model: 'prop_dock_crane_02' },
        zone: { points: [] },
        containers: [],
      },
      // Props / vehicles placed with the shared Prop Placer for the whole event (Props tab)
      props: [],
      breaks: [],
      ambushes: [],
      policeRoster: [],
      policeResolved: [],
      rosterResolved: {},
      // blank() always creates a fresh CONVOY-kind draft (see `kind: 'CONVOY'`
      // just above) — the Gang Rally ped model is set later, once the admin
      // actually switches kind (switchKind) or loads a GANG_RACE draft (the
      // fixup a few lines into save()). This referenced an undeclared `kind`
      // and threw "ReferenceError: kind is not defined" every time this
      // screen opened.
      startPed: { enabled: false, x: null, y: null, z: null, heading: 0, model: 's_m_y_cop_01' },
      // Recurring auto-start — WEEKLY fires on dayOfWeek, MONTHLY on
      // dayOfMonth, YEARLY on month+dayOfMonth, all at hour:minute or a
      // random time window.
      recurrence: { enabled: false, type: 'WEEKLY', mode: 'EXACT', dayOfWeek: 0, dayOfMonth: 1, month: 1, hour: 12, minute: 0, windowStartHour: 20, windowStartMinute: 0, windowEndHour: 22, windowEndMinute: 0 },
    };
  }

  // ── the Props tab: every event kind places its objects with the same Prop Placer ──
  const PROP_CONTEXTS = { CONVOY: 'event', GANG_AIRDROP: 'airdrop', HOT_CARGO: 'hotcargo', GANG_RACE: 'rally', TDM: 'tdm', CONTAINER_WARS: 'container_wars' };
  const PROP_TITLES = {
    CONVOY: 'Convoy props', GANG_AIRDROP: 'Airdrop props', HOT_CARGO: 'Hot Cargo props',
    GANG_RACE: 'Rally props', TDM: 'Arena props', CONTAINER_WARS: 'Container Wars props',
  };
  $: propContext = PROP_CONTEXTS[form.kind] || 'event';
  // (no fixed camera anchor: the placer starts over the placed props, or at the player when there are none)

  function buildEventGuides(f) {
    if (!f) return [];
    const out = [];
    const num = (v) => (v === null || v === undefined || v === '' ? NaN : Number(v));
    const joined = (pts) => {
      // the line that joins consecutive points, so the whole route can be seen while placing props
      for (let i = 0; i + 1 < pts.length; i++) {
        const a = pts[i], b = pts[i + 1];
        out.push({ kind: 'route', x: a.x, y: a.y, z: a.z, x2: b.x, y2: b.y, z2: b.z });
      }
    };

    // A Rally Race: its start, every checkpoint, its finish and the route between them
    if (f.kind === 'GANG_RACE') {
      const stages = (Array.isArray(f.rallyStages) ? f.rallyStages : [])
        .map((s, i) => ({ s, i }))
        .filter(({ s }) => Number.isFinite(num(s.x)) && Number.isFinite(num(s.y)))
        .sort((p, q) => (num(p.s.order) || p.i) - (num(q.s.order) || q.i))
        .map(({ s }) => ({ ...s, x: num(s.x), y: num(s.y), z: Number.isFinite(num(s.z)) ? num(s.z) : 0 }));
      let cpNo = 0;
      stages.forEach((s) => {
        const kind = s.kind === 'START' ? 'race_start' : s.kind === 'DESTINATION' ? 'race_finish' : 'race_checkpoint';
        if (kind === 'race_checkpoint') cpNo += 1;
        const base = kind === 'race_start' ? 'Start' : kind === 'race_finish' ? 'Finish' : `Checkpoint ${cpNo}`;
        out.push({ kind, x: s.x, y: s.y, z: s.z, radius: Number(s.radius) || 20, label: s.name && s.name !== base ? `${base} · ${s.name}` : base });
      });
      joined(stages);
    }

    // A Convoy: the line along its route, under the checkpoint zones below
    if (f.kind === 'CONVOY') {
      const pts = (Array.isArray(f.route) ? f.route : [])
        .filter((p) => p.type !== 'AIRDROP' && Number.isFinite(num(p.x)) && Number.isFinite(num(p.y)))
        .map((p, i) => ({ p, i }))
        .sort((a, b) => (num(a.p.order) || a.i) - (num(b.p.order) || b.i))
        .map(({ p }) => ({ x: num(p.x), y: num(p.y), z: Number.isFinite(num(p.z)) ? num(p.z) : 0 }));
      joined(pts);
    }

    if (f.kind === 'CONVOY') {
      const cps = (Array.isArray(f.checkpoints) ? f.checkpoints : []).filter((c) => !c.supportOnly);
      const r = Array.isArray(f.route) ? f.route : [];
      cps.forEach((cp, idx) => {
        const pt = r.find((p) => p.id === cp.routePointId);
        const x = pt?.x ?? cp.x;
        const y = pt?.y ?? cp.y;
        const z = pt?.z ?? cp.z;
        const heading = pt?.heading ?? cp.heading ?? 0;
        const radius = cp.radius || 15;
        if (x != null && y != null && z != null) {
          out.push({
            kind: 'checkpoint',
            x: Number(x), y: Number(y), z: Number(z),
            h: Number(heading),
            L: radius * 2,
            W: radius * 2,
            H: 4.0,
            label: cp.label || `Checkpoint #${idx + 1}`,
          });
        }
      });
    }
    return out;
  }


  let form = blank();
  let saving = false;
  let error = '';
  let loadedId = null;
  let scheduleInput = '';
  let scheduling = false;

  // Gang Access picker (HOT_CARGO/GANG_AIRDROP General tab) — the server's
  // own admin-added gang list, fetched once so "Selected Gangs" mode has
  // something to check boxes against. Loaded regardless of kind (cheap,
  // rarely more than a handful of gangs) rather than re-fetching every time
  // the admin flips the Event Type selector.
  let availableGangs = [];
  async function loadAvailableGangs() {
    const res = await getGangs();
    if (res && res.ok) availableGangs = res.gangs || [];
  }
  loadAvailableGangs();

  function ensureAllowedGangs() {
    if (!form) return;
    if (!form.settings) form.settings = {};
    if (!form.settings.allowedGangs || typeof form.settings.allowedGangs !== 'object') {
      form.settings.allowedGangs = { mode: 'ALL', gangs: [] };
    }
    if (!form.settings.allowedGangs.mode) form.settings.allowedGangs.mode = 'ALL';
    if (!Array.isArray(form.settings.allowedGangs.gangs)) form.settings.allowedGangs.gangs = [];
  }

  $: if (form && form.settings) {
    if (!form.settings.allowedGangs || typeof form.settings.allowedGangs !== 'object') {
      form.settings.allowedGangs = { mode: 'ALL', gangs: [] };
    } else {
      if (!form.settings.allowedGangs.mode) form.settings.allowedGangs.mode = 'ALL';
      if (!Array.isArray(form.settings.allowedGangs.gangs)) form.settings.allowedGangs.gangs = [];
    }
  }

  function setAllowedGangsMode(mode) {
    ensureAllowedGangs();
    form.settings.allowedGangs.mode = mode;
  }
  function toggleAllowedGang(name) {
    ensureAllowedGangs();
    const list = form.settings.allowedGangs.gangs;
    const i = list.indexOf(name);
    if (i === -1) list.push(name);
    else list.splice(i, 1);
    form.settings.allowedGangs.gangs = [...list];
    touch();
  }

  function touch() {
    form = form;
    scheduleDraftSave();
  }

  // Single merged "Schedule" card's frequency picker — 'ONCE' reuses the
  // exact one-off scheduleInput/schedule() flow below (never touches
  // form.recurrence), any other value flips form.recurrence.enabled on and
  // sets its type, reusing the existing recurring sub-form as-is. This is
  // purely local UI state; what actually gets sent to the server is either
  // scheduleConvoy(exact timestamp) or scheduleRecurringConvoy(computes the
  // first occurrence itself from form.recurrence) — see activateRecurring.
  let scheduleFrequency = 'ONCE';
  $: if (form && form.recurrence) {
    scheduleFrequency = form.recurrence.enabled ? form.recurrence.type : 'ONCE';
  }
  function setScheduleFrequency(freq) {
    scheduleFrequency = freq;
    if (freq === 'ONCE') {
      form.recurrence.enabled = false;
    } else {
      form.recurrence.enabled = true;
      form.recurrence.type = freq;
      seedRecurrenceScratch();
    }
  }

  // Recurrence "which day" calendar pickers (Monthly/Yearly) — DateTimePicker
  // only speaks a full "YYYY-MM-DDTHH:mm" value, so these scratch strings
  // carry a throwaway year/time just so it has something to parse; only the
  // month/day the admin actually clicks gets read back out into
  // form.recurrence below. Seeded explicitly (seedRecurrenceScratch, called
  // from load() and the cadence dropdown's on:change) rather than a reactive
  // statement — a $: block deriving scratch FROM form while another $: block
  // writes scratch BACK into form is a genuine cycle (form -> scratch ->
  // form), which Svelte's compiler flat out refuses to build.
  const pad2 = (n) => String(n || 1).padStart(2, '0');
  let monthlyDayScratch = '';
  let yearlyDateScratch = '';
  function seedRecurrenceScratch() {
    if (form.recurrence.type === 'MONTHLY') monthlyDayScratch = `2001-01-${pad2(form.recurrence.dayOfMonth)}T00:00`;
    if (form.recurrence.type === 'YEARLY') yearlyDateScratch = `2001-${pad2(form.recurrence.month)}-${pad2(form.recurrence.dayOfMonth)}T00:00`;
  }
  $: {
    const m = /-(\d{2})T/.exec(monthlyDayScratch);
    if (m) form.recurrence.dayOfMonth = Number(m[1]);
  }
  $: {
    const m = /^\d{4}-(\d{2})-(\d{2})T/.exec(yearlyDateScratch);
    if (m) { form.recurrence.month = Number(m[1]); form.recurrence.dayOfMonth = Number(m[2]); }
  }

  function offsetLabel() {
    const h = $bootstrap?.scheduleUtcOffsetHours ?? 0;
    if (!h) return 'UTC';
    return `UTC${h > 0 ? '+' : ''}${h}`;
  }

  function formatScheduledAt(ts) {
    if (!ts) return '—';
    return new Date(ts * 1000).toLocaleString();
  }

  // Human-readable cadence description for the "Recurring — Scheduled" state
  // (e.g. "Every Monday at 9:00 PM", "Monthly on day 1 (Unpredictable Window)")
  // — mirrors Scheduler.formatScheduleSummary server-side, kept in sync by hand
  // since it's purely cosmetic (the server is always the source of truth for
  // the actual next scheduledAt timestamp shown right next to this).
  function fmtHourMinute(h, m) {
    const ampm = h >= 12 ? 'PM' : 'AM';
    const h12 = h % 12 || 12;
    return `${h12}:${String(m).padStart(2, '0')} ${ampm}`;
  }
  $: scheduleSummary = (() => {
    const r = form.recurrence;
    if (!r || !r.enabled) return '';
    const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    let freq = r.type === 'DAILY' ? 'Daily'
      : r.type === 'WEEKLY' ? `Every ${DAY_NAMES[r.dayOfWeek || 0]}`
      : r.type === 'MONTHLY' ? `Monthly on day ${r.dayOfMonth || 1}`
      : `Yearly on ${MONTH_NAMES[(r.month || 1) - 1]} ${r.dayOfMonth || 1}`;
    if (r.mode === 'WINDOW') {
      return `${freq} between ${fmtHourMinute(r.windowStartHour || 0, r.windowStartMinute || 0)} and ${fmtHourMinute(r.windowEndHour || 0, r.windowEndMinute || 0)} (Unpredictable Window)`;
    }
    return `${freq} at ${fmtHourMinute(r.hour || 0, r.minute || 0)}`;
  })();

  // The datetime-local input is interpreted as wall-clock time in whatever
  // Config.ScheduleUtcOffsetHours says (see Scheduler.toUtcTimestamp), not
  // the admin's own browser timezone — so "now" for the purposes of this
  // field has to be computed the same way, using UTC getters throughout,
  // rather than `new Date().toLocaleString()` which would silently mix in
  // the browser's local timezone instead.
  function pad(n) { return String(n).padStart(2, '0'); }
  function toInputValue(d) {
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
  }
  // Only for the human-readable "server time now" readout below — the min=
  // bound passed to DateTimePicker stays 24-hour (toInputValue above), since
  // that's compared directly against the picker's own internal value format.
  function to12Hour(d) {
    const h24 = d.getUTCHours();
    const h12 = (h24 % 12) || 12;
    return `${pad(h12)}:${pad(d.getUTCMinutes())} ${h24 >= 12 ? 'PM' : 'AM'}`;
  }

  // `new Date()` alone is the ADMIN'S OWN PC clock (the NUI is just a CEF
  // browser running on their machine) — silently wrong the moment that PC's
  // clock drifts from the actual FXServer host, while still being labeled
  // "Server time now" and used to gate "that time has already passed"
  // validation. clockSkewMs anchors every tick to the real authoritative
  // instant instead: fetched once via getServerTime() (Scheduler.nowUtc(),
  // the same clock the scheduler poll loop itself runs on), then every
  // second's `now` is (this browser's own elapsed time since the fetch) +
  // (the true server instant at fetch time) — correct even if the PC clock
  // is off by hours, and still ticks smoothly without repolling every second.
  let clockSkewMs = 0;
  let clockSynced = false;
  async function syncServerClock() {
    const res = await getServerTime();
    if (res && res.ok && res.utc) {
      clockSkewMs = res.utc * 1000 - Date.now();
      clockSynced = true;
    }
  }

  // Only ticks while the Review tab (the only place `now` is actually shown)
  // is active — CreateConvoy stays mounted for the tablet's whole session
  // (see below), so an unconditional setInterval here would keep recomputing
  // offsetNow/minScheduleValue/nowDisplay every second forever, even while
  // looking at General/Trucks/Route.
  let now = new Date();
  let nowTimer = null;
  $: {
    if (activeTab === 'Review' && !nowTimer) {
      if (!clockSynced) syncServerClock();
      now = new Date(Date.now() + clockSkewMs);
      nowTimer = setInterval(() => (now = new Date(Date.now() + clockSkewMs)), 1000);
    } else if (activeTab !== 'Review' && nowTimer) {
      clearInterval(nowTimer);
      nowTimer = null;
    }
  }
  onDestroy(() => clearInterval(nowTimer));

  $: offsetNow = new Date(now.getTime() + (($bootstrap?.scheduleUtcOffsetHours ?? 0) * 3600000));
  $: minScheduleValue = toInputValue(offsetNow);
  $: nowDisplay = `${pad(offsetNow.getUTCFullYear())}-${pad(offsetNow.getUTCMonth() + 1)}-${pad(offsetNow.getUTCDate())}  ${to12Hour(offsetNow)}`;

  function formatRewardSummary(rewards) {
    if (!rewards || rewards.length === 0) return 'None';
    return rewards.map((r) => {
      const type = (r.type || '').toUpperCase();
      if (type === 'VEHICLE') {
        const name = (r.pool && r.pool.trim()) ? r.pool.trim() : (r.model || 'Vehicle');
        const mode = r.mode === 'SPAWN' ? 'Spawn at dock' : 'Garage';
        return `🚗 ${name} (${r.model || 'car'}, ${mode})`;
      }
      if (type === 'ITEMS') {
        return `📦 ${r.amount || 1}x ${r.pool || 'item'}`;
      }
      if (type === 'GANG_XP') {
        return `⭐ ${Number(r.amount || 0).toLocaleString()} Gang XP`;
      }
      if (type === 'TOKENS') {
        return `🪙 ${Number(r.amount || 0).toLocaleString()} Race Tokens`;
      }
      return `$${Number(r.amount || 0).toLocaleString()}`;
    }).join(', ');
  }

  function formatCountdown(scheduledAtUtc, nowDate) {
    if (!scheduledAtUtc) return '';
    const diff = scheduledAtUtc - Math.floor(nowDate.getTime() / 1000);
    if (diff <= 0) return 'due now';
    const h = Math.floor(diff / 3600);
    const m = Math.floor((diff % 3600) / 60);
    const s = diff % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
  }

  // Event Duration (form.eventDuration) is the OVERALL convoy clock — the
  // whole window police have to escort the trucks to the destination AND
  // finish delivering (see the deliveryTimeRemaining rework in
  // convoy_runtime.lua's monitor()), not just a post-arrival grace period.
  // Always a real number (never blank, unlike the delay field below), so
  // this is just an H/M/S-friendly view over the same raw-seconds value.
  let durationHours = 0, durationMinutes = 0, durationSeconds = 0;

  function syncDurationFromForm() {
    const total = Math.max(0, Number(form.eventDuration) || 0);
    durationHours = Math.floor(total / 3600);
    durationMinutes = Math.floor((total % 3600) / 60);
    durationSeconds = total % 60;
    // Allow the reactive write-back now that H/M/S are properly seeded.
    durationSynced = true;
  }

  // Guard: prevents the reactive write-back from firing on component init
  // (when durationHours/Minutes/Seconds are all 0) and overwriting
  // form.eventDuration with 0 before syncDurationFromForm() has been called.
  // Set to true only inside syncDurationFromForm() so the reactive block only
  // runs after the H/M/S values have been properly seeded from the saved form.
  let durationSynced = false;

  $: if (durationSynced) {
    form.eventDuration = (Number(durationHours) || 0) * 3600 + (Number(durationMinutes) || 0) * 60 + (Number(durationSeconds) || 0);
  }

  // Police Head Start (settings.startAnnounceDelaySeconds) is stored as a
  // plain number of seconds (or '' for "server default") but that's an
  // awkward unit for an admin to type directly for anything more than a
  // couple minutes — this splits it into H/M/S inputs for editing, while
  // the underlying field/API contract stays exactly the same raw-seconds
  // value it always was.
  let delayMode = 'default'; // 'default' | 'custom'
  let delayHours = 0, delayMinutes = 0, delaySeconds = 0;

  function syncDelayFromForm() {
    const v = form.settings.startAnnounceDelaySeconds;
    if (v === '' || v == null) {
      delayMode = 'default';
      delayHours = 0; delayMinutes = 0; delaySeconds = 0;
    } else {
      delayMode = 'custom';
      const total = Math.max(0, Number(v) || 0);
      delayHours = Math.floor(total / 3600);
      delayMinutes = Math.floor((total % 3600) / 60);
      delaySeconds = total % 60;
    }
  }

  // Only writes when in 'custom' mode — switching TO 'default' clears the
  // field directly (see the radio's own on:change below) rather than racing
  // this reactive block, which would otherwise immediately recompute it
  // from delayHours/Minutes/Seconds and stomp the '' back to a number.
  $: if (delayMode === 'custom') {
    form.settings.startAnnounceDelaySeconds = (Number(delayHours) || 0) * 3600 + (Number(delayMinutes) || 0) * 60 + (Number(delaySeconds) || 0);
  }

  function useServerDefaultDelay() {
    delayMode = 'default';
    delayHours = 0; delayMinutes = 0; delaySeconds = 0;
    form.settings.startAnnounceDelaySeconds = '';
  }

  // Autosaves the in-progress editor state to localStorage as the admin
  // works — every field edit (route points, checkpoint radii, truck configs,
  // whatever), not just on an explicit Save click. Keyed per-convoy (or
  // "new" for a not-yet-created draft) so it survives exactly the situations
  // that used to lose work: a resource restart mid-edit (this session has
  // had a LOT of those — a full NUI reload wipes all in-memory Svelte state
  // unconditionally), or clicking "Edit" again on the same convoy from
  // Manage Convoys/History (which forces load() to re-fetch and used to
  // stomp on whatever unsaved changes were already sitting in the editor).
  // localStorage lives in the NUI browser profile, not this script's memory,
  // so it's the one thing that actually survives a restart.
  const DRAFT_PREFIX = 'nova_convoy_draft_';
  function draftKey(id) { return `${DRAFT_PREFIX}${id || 'new'}`; }
  function readDraft(id) {
    try {
      const raw = localStorage.getItem(draftKey(id));
      return raw ? JSON.parse(raw) : null;
    } catch (e) { return null; }
  }
  function writeDraft(id, data) {
    try { localStorage.setItem(draftKey(id), JSON.stringify(data)); } catch (e) { /* private mode / quota — draft just won't persist */ }
  }
  function clearDraft(id) {
    try { localStorage.removeItem(draftKey(id)); } catch (e) {}
  }
  let draftSaveTimer;
  function scheduleDraftSave() {
    if (!form) return;
    clearTimeout(draftSaveTimer);
    // 800ms debounce — every keystroke/coord-nudge would otherwise hit
    // localStorage far more often than the data actually needs saving.
    draftSaveTimer = setTimeout(() => writeDraft(loadedId, form), 800);
  }
  // References `form` so Svelte re-runs this on every mutation anywhere
  // inside it (route/checkpoints/trucks/settings all bind back into form).
  // Skipped while locked: a locked (non-DRAFT/SCHEDULED) convoy is read-only
  // here, so there's never a genuine unsaved edit to protect — and saving
  // one anyway used to be the actual bug behind "can't edit a draft event."
  // Merely OPENING a convoy while it was ACTIVE/COMPLETED/CANCELLED/etc.
  // wrote a draft snapshot (with that locked status baked in) to
  // localStorage under that convoy's id. If the convoy was later reset back
  // to Draft (e.g. via Reuse) and reopened, load() below would restore that
  // stale draft — whose `status` field still said e.g. COMPLETED — so
  // `locked` came out true again even though the DB said DRAFT, and every
  // field stayed disabled with no way to tell why.
  $: if (form && !locked) scheduleDraftSave();

  // Shown once, right after a draft gets silently restored, so the admin
  // knows why the editor didn't come up blank/at-last-saved and has a way
  // back out if they'd rather discard it.
  let restoredDraft = false;
  async function discardDraft() {
    clearDraft(loadedId);
    restoredDraft = false;
    await load(loadedId);
  }

  // Used to unconditionally discard a restored "new" draft whose kind
  // wasn't CONVOY (switchKind lets the admin change kind WHILE still in the
  // shared "new" slot, e.g. Convoy -> Gang Airdrop, all before ever getting
  // a real id) — meant to stop the Create tab surprising the admin with a
  // stale Rally/Airdrop/Hot Cargo form when they just wanted a blank
  // Convoy. In practice this meant "draft autosave doesn't actually work
  // for Airdrop/Hot Cargo/Rally" for anyone who filled one in and hit a
  // reload before ever saving — every OTHER kind's autosave (once it has a
  // real convoy id) already worked fine, and load(id) below re-asserts the
  // server's own kind regardless, so there's nothing kind-specific left to
  // protect once a draft has an id. The restoredDraft banner just below
  // already tells the admin a draft came back and offers Discard & Reload
  // — that's the real safety net; unconditionally wiping the data on top
  // of it was the actual bug, not a second necessary layer of protection.
  function normalizeDraft(draft) {
    return draft || null;
  }

  async function load(id) {
    if (!id) {
      const draft = normalizeDraft(readDraft(null));
      form = draft || blank();
      restoredDraft = !!draft;
      loadedId = null;
      const savedTab = typeof localStorage !== 'undefined' ? localStorage.getItem('nova_convoy_last_form_tab') : null;
      if (savedTab && TABS.includes(savedTab)) {
        activeTab = savedTab;
      } else {
        activeTab = firstTab(form.kind);
      }
      syncDelayFromForm();
      syncDurationFromForm();
      return;
    }
    const res = await getConvoy(id);
    if (res && res.ok) {
      const draft = readDraft(id);
      form = draft || res.convoy;
      const savedTab = typeof localStorage !== 'undefined' ? localStorage.getItem('nova_convoy_last_form_tab') : null;
      if (savedTab && TABS.includes(savedTab)) {
        activeTab = savedTab;
      }
      // status is server-owned lifecycle state, not something the admin
      // edits in this form — a restored draft must never override it with
      // whatever it happened to be the last time this convoy was opened
      // (see the scheduleDraftSave guard above for why an old draft could
      // disagree with the DB at all). Self-heals any draft already stuck
      // with a stale status from before this fix.
      form.status = res.convoy.status;
      restoredDraft = !!draft;
      if (!form.settings.failurePolicy) form.settings.failurePolicy = 'FAIL'; // convoys saved before this setting existed
      if (form.settings.lockpicksRequired == null) form.settings.lockpicksRequired = '';
      if (form.settings.startAnnounceDelaySeconds == null) form.settings.startAnnounceDelaySeconds = ''; // convoys saved before this setting existed
      if (form.settings.maxGangs == null) form.settings.maxGangs = 0; // convoys saved before this setting existed
      if (form.settings.maxMembersPerGang == null) form.settings.maxMembersPerGang = 0;
      if (form.settings.forceDriveBy == null) form.settings.forceDriveBy = true; // convoys saved before this setting existed
      if (form.settings.requireEscortProximity == null) form.settings.requireEscortProximity = true; // convoys saved before this setting existed
      if (form.settings.announceStartTime == null) form.settings.announceStartTime = ''; // convoys saved before this setting existed
      if (form.settings.announceEndTime == null) form.settings.announceEndTime = '';
      if (form.settings.announceMessage == null) form.settings.announceMessage = '';
      if (!form.settings.allowedGangs) form.settings.allowedGangs = { mode: 'ALL', gangs: [] }; // convoys saved before this setting existed
      // Race/airdrop/hot-cargo definitions never fill the convoy-only arrays,
      // and a NULL JSON column comes back as undefined — anything reading
      // form.trucks/route/etc. (readiness, Review summary) would throw and
      // leave the editor half-rendered.
      if (!Array.isArray(form.trucks)) form.trucks = [];
      if (!Array.isArray(form.route)) form.route = [];
      if (!Array.isArray(form.checkpoints)) form.checkpoints = [];
      if (Array.isArray(form.pointSupport)) {
        const have = new Set(form.checkpoints.map((c) => c.routePointId));
        for (const ps of form.pointSupport) if (ps && !have.has(ps.routePointId)) form.checkpoints.push({ ...ps, supportOnly: true });
      }
      delete form.pointSupport;
      if (!Array.isArray(form.airdrops)) form.airdrops = [];
      if (!form.settings.raceEntryMode) form.settings.raceEntryMode = 'TEAM';
      if (!form.settings.raceVehicleMode) form.settings.raceVehicleMode = 'OWN';
      if (!form.settings.raceCollision) form.settings.raceCollision = 'ON';
      if (form.settings.raceGridWaitSeconds == null) form.settings.raceGridWaitSeconds = '';
      if (!Array.isArray(form.settings.raceVehicles)) form.settings.raceVehicles = [];
      if (!form.settings.eventAccess) form.settings.eventAccess = 'GANGS';
      if (!form.settings.civilianPed) form.settings.civilianPed = { enabled: true, x: null, y: null, z: null, heading: 0, model: form.kind === 'CONTAINER_WARS' ? 's_m_m_dockwork_01' : 'a_m_y_runner_01' };
      if (form.kind === 'GANG_RACE' && form.settings.raceEntryMode === 'TEAM' && !(form.settings.maxMembersPerGang > 0)) form.settings.maxMembersPerGang = 2;
      if (!form.breaks) form.breaks = [];
      if (!form.ambushes) form.ambushes = [];
      if (!form.kind) form.kind = 'CONVOY'; // convoys saved before this setting existed
      if (!form.airdropZones) form.airdropZones = [];
      if (!form.hotCargo) form.hotCargo = { truckCount: 2, policeAlert: true, policeAlertBufferSeconds: 45, trucks: [], spawnZones: [], dropoffZones: [], salvageReward: [] };
      if (form.hotCargo.truckCount == null) form.hotCargo.truckCount = 2;
      if (form.hotCargo.policeAlert == null) form.hotCargo.policeAlert = true;
      if (!Array.isArray(form.hotCargo.spawnZones)) form.hotCargo.spawnZones = [];
      if (!Array.isArray(form.hotCargo.dropoffZones)) form.hotCargo.dropoffZones = [];
      if (!Array.isArray(form.hotCargo.salvageReward)) form.hotCargo.salvageReward = [];
      // Migrates a Hot Cargo saved before the Trucks section existed: it had
      // one global truckModel + a vehiclesToSpawn count instead of a real
      // truck list. Synthesizes that many Random-mode entries from the old
      // model so an existing saved run doesn't just lose its trucks.
      if (!Array.isArray(form.hotCargo.trucks) || form.hotCargo.trucks.length === 0) {
        const legacyCount = Number(form.hotCargo.vehiclesToSpawn) || 0;
        const legacyModel = form.hotCargo.truckModel || 'brickade';
        const synth = [];
        for (let i = 0; i < Math.max(legacyCount, form.kind === 'HOT_CARGO' && !Array.isArray(form.hotCargo.trucks) ? 2 : 0); i++) {
          synth.push({
            id: `truck_${Date.now()}_${i}`,
            name: `Cargo Truck ${i + 1}`,
            model: legacyModel,
            mode: 'RANDOM',
            x: null, y: null, z: null, heading: 0,
            guardCount: 0, guardWeapon: 'WEAPON_CARBINERIFLE', guardModel: 'g_m_y_salvagoon_01',
            guardAggressiveness: 'high', shootAnyone: true,
          });
        }
        form.hotCargo.trucks = synth;
      }
      delete form.hotCargo.vehiclesToSpawn;
      delete form.hotCargo.truckModel;
      if (!form.rallyStages) form.rallyStages = [];
      // A draft saved before positionRewards existed (or restored from a
      // stale localStorage copy) comes back with this whole key missing —
      // the Review tab and RewardListEditor bindings read
      // form.positionRewards.first/second/third/participation completely
      // unguarded, so an undefined positionRewards threw "Cannot read
      // properties of undefined (reading 'first')" and left the editor dead.
      if (!form.positionRewards) form.positionRewards = { first: [], second: [], third: [], participation: [] };
      if (!Array.isArray(form.positionRewards.first)) form.positionRewards.first = [];
      if (!Array.isArray(form.positionRewards.second)) form.positionRewards.second = [];
      if (!Array.isArray(form.positionRewards.third)) form.positionRewards.third = [];
      if (!Array.isArray(form.positionRewards.participation)) form.positionRewards.participation = [];
      // A draft saved before TDM existed (or a non-TDM event) comes back with
      // no `tdm` key at all — everything in Match Setup/Review reads
      // form.tdm.* unguarded.
      if (!form.tdm) form.tdm = { matchFormat: 'STANDARD', duration: 600, killLimit: 0, zone: {}, weaponVendor: {}, spawnPoints: [], bracket: {} };
      if (!form.tdm.matchFormat) form.tdm.matchFormat = 'STANDARD';
      if (form.tdm.duration == null) form.tdm.duration = 600;
      if (form.tdm.killLimit == null) form.tdm.killLimit = 0;
      if (!form.tdm.zone) form.tdm.zone = {};
      if (!form.tdm.weaponVendor) form.tdm.weaponVendor = {};
      if (!Array.isArray(form.tdm.spawnPoints)) form.tdm.spawnPoints = [];
      if (!form.tdm.bracket) form.tdm.bracket = {};
      if (!form.crackdown || typeof form.crackdown !== 'object') form.crackdown = blank().crackdown;
      if (!form.containerWars) form.containerWars = { maxContainers: 4, containersPerRound: 1, crane: { x: null, y: null, z: null, heading: 0, model: 'prop_dock_crane_02' }, zone: { points: [] }, containers: [] };
      if (form.containerWars.maxContainers == null) form.containerWars.maxContainers = 4;
      if (form.containerWars.containersPerRound == null) form.containerWars.containersPerRound = 1;
      if (!form.containerWars.crane) form.containerWars.crane = { x: null, y: null, z: null, heading: 0, model: 'prop_dock_crane_02' };
      if (!form.containerWars.zone) form.containerWars.zone = { points: [] };
      if (!Array.isArray(form.containerWars.containers)) form.containerWars.containers = [];
      if (!Array.isArray(form.props)) form.props = [];   // events saved before the Prop Placer existed
      if (!form.territory || typeof form.territory !== 'object') form.territory = { auction: {}, areas: [] };
      if (!form.policeRoster) form.policeRoster = [];
      if (!form.policeResolved) form.policeResolved = [];
      if (!form.rosterResolved) form.rosterResolved = {};
      // Normalizes an old single-object reward shape into the list shape —
      // the server already migrates this (see db.lua decodeReward), this is
      // just a defensive backstop.
      if (!Array.isArray(form.reward)) form.reward = form.reward && form.reward.type ? [form.reward] : [];
      if (!form.startPed) form.startPed = { enabled: false, x: null, y: null, z: null, heading: 0, model: form.kind === 'GANG_RACE' ? 'g_m_m_chicold_01' : 's_m_y_cop_01' };
      if (form.kind === 'GANG_RACE' && (!form.startPed.model || form.startPed.model === 's_m_y_cop_01')) form.startPed.model = 'g_m_m_chicold_01';
      if (form.maxEscortVehicles == null) form.maxEscortVehicles = 4; // convoys saved before this setting existed
      if (form.escortVehicleHealth == null) form.escortVehicleHealth = 5000;
      if (form.maxPoliceParticipants == null || form.maxPoliceParticipants <= 0) form.maxPoliceParticipants = 20;
      if (form.maxGangParticipants == null || form.maxGangParticipants <= 0) form.maxGangParticipants = 20;
      if (!form.recurrence) form.recurrence = { enabled: false, type: 'WEEKLY', mode: 'EXACT', dayOfWeek: 0, dayOfMonth: 1, month: 1, hour: 12, minute: 0, windowStartHour: 20, windowStartMinute: 0, windowEndHour: 22, windowEndMinute: 0 };
      if (!form.recurrence.mode) form.recurrence.mode = 'EXACT';
      if (form.recurrence.windowStartHour == null) form.recurrence.windowStartHour = 20;
      if (form.recurrence.windowStartMinute == null) form.recurrence.windowStartMinute = 0;
      if (form.recurrence.windowEndHour == null) form.recurrence.windowEndHour = 22;
      if (form.recurrence.windowEndMinute == null) form.recurrence.windowEndMinute = 0;
      if (form.recurrence.month == null) form.recurrence.month = 1; // convoys saved before Yearly cadence existed
      seedRecurrenceScratch();
      loadedId = id;
      syncDelayFromForm();
      syncDurationFromForm();
    }
  }

  // Switching the event type on a NEW draft starts that type's own data from
  // scratch — otherwise a route / stage list / zone list typed for the
  // previous type stays inside the same form object and gets saved and shown
  // as part of the new event (cross-event vector bleed).
  function switchKind(kind) {
    const b = blank();
    form.kind = kind;
    form.route = b.route;
    form.checkpoints = b.checkpoints;
    form.airdrops = b.airdrops;
    form.airdropZones = b.airdropZones;
    form.hotCargo = b.hotCargo;
    form.rallyStages = b.rallyStages;
    form.tdm = b.tdm;
    form.containerWars = b.containerWars;
    form.territory = b.territory;
    form.crackdown = b.crackdown;
    form.props = b.props;
    if (kind !== 'CONVOY') form.settings.gangPvp = true;
    if (kind === 'GANG_RACE') {
      form.settings.raceEntryMode = 'TEAM';
      form.settings.maxMembersPerGang = 2;
      form.settings.raceVehicleMode = 'OWN';
      form.settings.raceCollision = 'ON';
      form.settings.raceVehicles = [];
      form.settings.raceVehiclePed = null;
      form.settings.civilianPed = { enabled: true, x: null, y: null, z: null, heading: 0, model: 'a_m_y_runner_01' };
    }
    if (kind === 'CONTAINER_WARS') {
      form.settings.civilianPed = { enabled: true, x: null, y: null, z: null, heading: 0, model: 's_m_m_dockwork_01' };
    }
    if (kind === 'TDM') {
      // TDM is invite-only by design — starting from ALL would let every
      // gang on the server think they can register (see setGangRoster's
      // server-side hard gate, which would then reject them anyway).
      form.settings.allowedGangs = { mode: 'SELECTED', gangs: [] };
    }
    if (kind === 'CRACKDOWN') {
      form.name = form.name || 'Operation Crackdown';
      form.settings.allowedGangs = { mode: 'ALL', gangs: [] };
      form.eventDuration = 1200;
    }
    if (kind === 'GANG_TERRITORY') {
      form.settings.allowedGangs = { mode: 'ALL', gangs: [] };
      form.settings.eventAccess = 'GANGS';
      form.eventDuration = 1800;
    }
    activeTab = firstTab(kind);
  }

  // A plain Convoy needs Create Event → Create; every other kind needs Create Event → Manage (the server enforces both).
  $: kindInfo = KIND_TABS.find((k) => k.id === form.kind) || KIND_TABS[0];
  $: canSpecialKinds = !!$perms['create.manage'];
  $: visibleKindTabs = KIND_TABS.filter((k) => canSpecialKinds || k.id === 'CONVOY');
  // Without that permission only Convoy events can be built here
  $: if ($bootstrap && !canSpecialKinds && form.kind !== 'CONVOY') {
    switchKind('CONVOY');
  }

  // Picking a different type while a saved event is open starts a NEW event of that type (a saved event keeps its type).
  async function pickKind(kind) {
    if (locked || kind === form.kind) return;
    if (loadedId) {
      const label = (KIND_TABS.find((k) => k.id === kind) || {}).full || 'event';
      const ok = await confirmAction(`Start a new ${label}? "${form.name || 'This event'}" stays saved as it is — only unsaved changes to it are discarded.`, { title: 'Create a different event type' });
      if (!ok) return;
      resetToNew();
    }
    switchKind(kind);
  }
  function resetToNew() {
    convoyId = null;
    loadedId = null;
    clearDraft(null); // don't let a leftover "new" draft reappear on the next blank editor
    if (typeof localStorage !== 'undefined') {
      localStorage.removeItem('nova_convoy_last_edit_id');
      localStorage.removeItem('nova_convoy_last_form_tab');
    }
    form = blank();
    restoredDraft = false;
    error = '';
    activeTab = firstTab(form.kind);
    syncDelayFromForm();
    syncDurationFromForm();
    dispatch('reset');
  }

  $: load(convoyId);

  // These three MUST come after `$: load(convoyId)`: load() replaces `form` (a restored draft of another event type, or a saved event), and a
  // reactive statement that sits above it never re-runs in the same pass: the step tabs and the form body kept the previous type's
  // (Convoy) layout while the title and the type picker already showed the restored type (Territory Auction).
  $: TABS = form.kind === 'CRACKDOWN' ? CRACKDOWN_TABS : form.kind === 'GANG_TERRITORY' ? TERRITORY_TABS : form.kind === 'GANG_AIRDROP' ? AIRDROP_TABS : (form.kind === 'HOT_CARGO' ? HOT_CARGO_TABS : (form.kind === 'GANG_RACE' ? RALLY_TABS : (form.kind === 'TDM' ? TDM_TABS : (form.kind === 'CONTAINER_WARS' ? CONTAINER_WARS_TABS : CONVOY_TABS))));
  $: if (!TABS.includes(activeTab)) {
    const saved = typeof localStorage !== 'undefined' ? localStorage.getItem('nova_convoy_last_form_tab') : null;
    if (saved && TABS.includes(saved)) {
      activeTab = saved;
    } else {
      activeTab = TABS[0];
    }
  }
  $: if (typeof localStorage !== 'undefined' && activeTab && TABS.includes(activeTab)) {
    localStorage.setItem('nova_convoy_last_form_tab', activeTab);
  }

  let savedFlash = false;
  let savedFlashTimer;

  // Deliberately does NOT navigate away or reset activeTab — it used to
  // dispatch 'saved' here too, which bounced you back out to the Convoys
  // list (and reset back to the General tab) every single time you saved,
  // no matter which tab you were working in. Now it just saves in place;
  // leaving the editor is a separate, explicit choice (the sidebar, or
  // actually starting the convoy).
  async function save() {
    error = '';
    if (form.name.trim().length < 3) {
      error = form.kind === 'CRACKDOWN' ? 'Operation name must be at least 3 characters.' : form.kind === 'HOT_CARGO' ? 'Hot Cargo Run name must be at least 3 characters.' : (form.kind === 'GANG_AIRDROP' ? 'Airdrop name must be at least 3 characters.' : (form.kind === 'GANG_RACE' ? 'Rally Race name must be at least 3 characters.' : (form.kind === 'TDM' ? 'TDM Match name must be at least 3 characters.' : (form.kind === 'GANG_TERRITORY' ? 'Territory Auction name must be at least 3 characters.' : 'Convoy name must be at least 3 characters.'))));
      return;
    }
    if (form.kind === 'CONVOY') {
      const pCount = Number(form.maxPoliceParticipants);
      if (isNaN(pCount) || pCount < 0) {
        error = 'Max Police Participants must be 0 or more.';
        return;
      }
      if (pCount === 0) {
        const proceed = await confirmAction(
          'Max Police Participants is set to 0. This will completely disable police escort registration and escort roles for this convoy. Are you sure you want 0 police escorts?',
          { title: 'Confirm 0 Police Escorts', confirmLabel: 'Yes, Disable Police Escorts' }
        );
        if (!proceed) return;
      }
    }
    // Container Wars: a round's containers all stand on the yard's spots at once, so a round cannot hold more
    // containers than there are spots. The server would quietly lower it; refuse it here instead and say why.
    if (form.kind === 'CONTAINER_WARS') {
      const nSpots = ($bootstrap?.containerWars?.harbour?.pickups || []).length;
      const perRound = Number(form.containerWars?.containersPerRound) || 1;
      if (nSpots > 0 && perRound > nSpots) {
        error = `Containers per round (${perRound}) is more than the ${nSpots} spot${nSpots === 1 ? '' : 's'} placed in the yard. Lower it, or add spots in Container Wars Setup, then save again.`;
        return;
      }
    }
    // The server rebuilds the live route by SORTING on each point's own
    // `order` field (sortedRoute() in convoy_runtime.lua), not by its
    // position in this array — so a stale `order` (e.g. a point added after
    // an existing DESTINATION, then dragged earlier in RouteBuilder's list)
    // would have the convoy silently visit it in the OLD order at runtime no
    // matter where it visually sat in the editor. Re-stamped from actual
    // array position right before every save so it can never drift out of
    // sync again, regardless of which reorder path (drag, move up/down, a
    // future one) touched it last.
    if (Array.isArray(form.route) && form.route.length > 0) {
      form.route = form.route.map((p, i) => ({ ...p, order: i }));
    }
    saving = true;
    const wasNewDraftKey = loadedId; // capture before it changes below — null means the "new" draft slot
    const res = loadedId ? await updateConvoy(loadedId, form) : await createConvoy(form);
    saving = false;
    if (!res || !res.ok) {
      error = (res && res.error) || (form.kind === 'HOT_CARGO' ? 'Failed to save hot cargo run.' : (form.kind === 'GANG_AIRDROP' ? 'Failed to save airdrop.' : (form.kind === 'GANG_RACE' ? 'Failed to save rally race.' : (form.kind === 'TDM' ? 'Failed to save TDM match.' : (form.kind === 'GANG_TERRITORY' ? 'Failed to save territory auction.' : 'Failed to save convoy.')))));
      return;
    }
    // Now safely committed to the DB — the local shadow copy has done its
    // job and would just be dead weight (or worse, a stale trap) from here on.
    clearDraft(wasNewDraftKey);
    loadedId = res.convoy.id;
    clearDraft(loadedId);
    restoredDraft = false;
    form = res.convoy;
    savedFlash = true;
    clearTimeout(savedFlashTimer);
    savedFlashTimer = setTimeout(() => (savedFlash = false), 4000);

    // A saved Tournament-format TDM is only an arena — the actual tournament
    // is created in the Tournament tab. Offer to go there right now so the
    // admin is never left wondering what the next step is.
    const arena = form.kind === 'TDM' && form.tdm?.matchFormat === 'TOURNAMENT';
    const arenaReady = (form.tdm?.zone?.points || []).length >= 3 && ((form.tdm?.spawnPoints || []).length > 0 || (form.tdm?.respawnZoneRed?.points || []).length >= 3 || (form.tdm?.respawnZoneBlue?.points || []).length >= 3);
    if (arena && arenaReady) {
      const go = await confirmAction(
        `"${form.name}" is saved as a tournament arena.

Next step: create the tournament itself — pick the gangs, groups and start time — in the Tournament tab. Go there now?`,
        { title: 'Arena saved', confirmLabel: 'Create tournament', cancelLabel: 'Not now' }
      );
      if (go) {
        tournamentIntent.set('create');
        currentView.set('tournaments');
      }
    } else if (arena) {
      error = 'Arena saved — place the combat zone (3+ points) and at least one spawn point before using it in a tournament.';
    }
  }

  // PUBLISH EVENT (Review tab): saves the event, then schedules it for the Event Date + Auction Start Time from Auction Setup —
  // the existing draft → scheduled lifecycle. Publishing also puts the territories on every gang map.
  async function publishTerritory() {
    error = '';
    const au = form.territory?.auction || {};
    if (!au.date || !au.startTime) { error = 'Set the Event Date and the Auction Start Time in Auction Setup first.'; activeTab = 'Auction Setup'; return; }
    const dt = `${au.date}T${au.startTime}`;
    if (minScheduleValue && dt < minScheduleValue) { error = `That time has already passed (server clock is ${offsetLabel()} ${nowDisplay}).`; return; }
    await save();
    if (!loadedId || error) return;
    scheduling = true;
    const res = await scheduleConvoy(loadedId, dt);
    scheduling = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to publish the event.'; return; }
    form = res.convoy;
    dispatch('saved', res.convoy);
  }

  async function launch() {
    if (!loadedId) {
      await save();
      if (!loadedId) return;
    }
    // A Tournament-format TDM is an arena template, never started on its
    // own — the Tournament tab creates and runs the actual tournament.
    if (form.kind === 'TDM' && form.tdm?.matchFormat === 'TOURNAMENT') {
      error = 'A Tournament TDM is an arena for the Tournament tab — save it, then create the tournament there.';
      return;
    }
    const summary = form.kind === 'CRACKDOWN'
      ? `Operation Crackdown: ${form.name}\n${form.crackdown?.targetGang || '?'} vs the Police\nPreparation: ${form.crackdown?.prepSeconds}s, fight: ${Math.round(form.eventDuration / 60)} min\n\nThe announcement goes out to the whole server now; the gang's online members and every officer on duty fight inside the zone.`
      : form.kind === 'GANG_TERRITORY'
      ? `Gang Territory Auction: ${form.name}\nTerritories: ${(form.territory?.areas || []).filter((a) => a.auctioned !== false).length} for auction\nDuration: ${Math.round(form.eventDuration / 60)} min\n\nThe auction opens for every eligible gang the moment it starts; the winners become the territories' persistent owners.`
      : form.kind === 'CONTAINER_WARS'
      ? `Container Wars: ${form.name}\nContainers: ${(form.containerWars?.containers || []).length}\nPer round: ${form.containerWars?.containersPerRound || 4}\n\nThe harbour auction opens for every eligible gang the moment it starts.`
      : form.kind === 'TDM'
      ? `TDM Match: ${form.name}\nGangs: ${(form.settings.allowedGangs?.gangs || []).join(' vs ')}\nDuration: ${Math.round((form.tdm?.duration || 0) / 60)} min\n\nBoth gangs' online, registered members will be pulled into the match the moment it starts.`
      : form.kind === 'GANG_AIRDROP'
      ? `Gang Airdrop Event: ${form.name}\nZones: ${form.airdropZones.length}\nDuration: ${Math.round(form.eventDuration / 60)} min\n\nThis is completely invisible to police — open to all gangs across the server.`
      : form.kind === 'HOT_CARGO'
      ? `Hot Cargo Run: ${form.name}\nTrucks: ${(form.hotCargo?.trucks || []).length}\nDropoffs: ${(form.hotCargo?.dropoffZones || []).length}\nPolice Buffer: ${form.hotCargo?.policeAlertBufferSeconds || 45}s\n\nContraband vehicles will spawn silently. Police dispatch alerts when driver buffer expires.`
      : form.kind === 'GANG_RACE'
      ? `Gang Rally / Street Race: ${form.name}\nCheckpoints: ${(form.rallyStages || []).length}\nDuration: ${Math.round(form.eventDuration / 60)} min\n\nPure driving skill competition. Police will ONLY be notified with pursuit blips after the race finishes!`
      : `Convoy: ${form.name}\nTrucks: ${form.trucks.length}\nRoute points: ${form.route.length}\nCheckpoints: ${form.checkpoints.filter((c) => !c.supportOnly).length}\nGang limit: ${form.maxGangParticipants}`;
    const ok = await confirmAction(
      `${summary}\n\nThis makes the server authoritative for the event — it will go live for everyone immediately.`,
      { title: form.kind === 'CRACKDOWN' ? 'Start Operation Crackdown' : form.kind === 'CONTAINER_WARS' ? 'Start Container Wars' : form.kind === 'HOT_CARGO' ? 'Start Hot Cargo Run' : (form.kind === 'GANG_AIRDROP' ? 'Start Gang Airdrop Event' : (form.kind === 'GANG_RACE' ? 'Start Gang Rally Race' : (form.kind === 'TDM' ? 'Start TDM Match' : 'Start Convoy'))) }
    );
    if (!ok) return;
    saving = true;
    clearPlacedPreview();
    const res = await startConvoy(loadedId);
    saving = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to start event.'; return; }
    dispatch('saved', res.convoy);
  }

  let countdownBusy = false;
  async function beginCountdown() {
    error = '';
    countdownBusy = true;
    clearPlacedPreview();
    const res = await startRaceCountdown(loadedId);
    countdownBusy = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not start the countdown.'; return; }
    form = { ...form, raceGrid: false };
  }

  async function schedule() {
    error = '';
    if (!scheduleInput) { error = 'Pick a date/time first.'; return; }
    if (scheduleInput < minScheduleValue) { error = `That time has already passed (server clock is ${offsetLabel()} ${nowDisplay}).`; return; }
    if (!loadedId) {
      await save();
      if (!loadedId) return;
    }
    scheduling = true;
    const res = await scheduleConvoy(loadedId, scheduleInput);
    scheduling = false;
    if (!res || !res.ok) { error = (res && res.error) || (form.kind === 'HOT_CARGO' ? 'Failed to schedule hot cargo run.' : (form.kind === 'GANG_AIRDROP' ? 'Failed to schedule airdrop.' : (form.kind === 'GANG_TERRITORY' ? 'Failed to schedule territory auction.' : 'Failed to schedule convoy.'))); return; }
    form = res.convoy;
    dispatch('saved', res.convoy);
  }

  // Activates a repeating cadence — the server computes the first fire time
  // itself from form.recurrence (same rule Scheduler.rearm reuses for every
  // occurrence after this one), so there's nothing here to pick manually.
  async function activateRecurring() {
    error = '';
    if (!loadedId) {
      await save();
      if (!loadedId) return;
    } else {
      // The cadence fields (frequency/day/hour/window) must be saved first —
      // scheduleRecurringConvoy reads form.recurrence straight from the DB.
      await save();
    }
    scheduling = true;
    const res = await scheduleRecurringConvoy(loadedId);
    scheduling = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to activate the recurring schedule.'; return; }
    form = res.convoy;
    dispatch('saved', res.convoy);
  }

  async function unschedule() {
    error = '';
    scheduling = true;
    const res = await unscheduleConvoy(loadedId);
    scheduling = false;
    if (!res || !res.ok) { error = (res && res.error) || (form.kind === 'HOT_CARGO' ? 'Failed to unschedule hot cargo run.' : (form.kind === 'GANG_AIRDROP' ? 'Failed to unschedule airdrop.' : (form.kind === 'GANG_TERRITORY' ? 'Failed to unschedule territory auction.' : 'Failed to unschedule convoy.'))); return; }
    form = res.convoy;
    dispatch('saved', res.convoy);
  }

  // Walk to the spot in-game, then click this — same "use my current
  // position" pattern as NPC spawn zones and the equipment vendor location.
  // Doesn't save on its own; the placed coords are just part of the form
  // like any other field until you hit Save.
  // The first placement also switches the ped on — a position with the ped
  // still disabled would silently never spawn.
  // (e.detail: the spot chosen with the placement hologram; without it, where the player stands)
  async function setStartPedHere(e) {
    const pos = e?.detail?.x != null ? e.detail : await getPlayerPosition();
    if (!pos || pos.x == null) return;
    form.startPed = { ...form.startPed, enabled: form.startPed.x ? form.startPed.enabled : true, x: pos.x, y: pos.y, z: pos.z, heading: pos.heading ?? 0 };
  }

  function toggleStartPed() {
    form.startPed = { ...form.startPed, enabled: !form.startPed.enabled };
  }

  function clearStartPed() {
    form.startPed = { ...form.startPed, x: null, y: null, z: null, heading: 0 };
  }

  async function setCivilianPedHere(e) {
    const pos = e?.detail?.x != null ? e.detail : await getPlayerPosition();
    if (!pos || pos.x == null) return;
    form.settings.civilianPed = {
      ...(form.settings?.civilianPed || {}),
      enabled: form.settings?.civilianPed?.x ? form.settings.civilianPed.enabled : true,
      x: pos.x,
      y: pos.y,
      z: pos.z,
      heading: pos.heading ?? 0,
      model: form.settings?.civilianPed?.model || (form.kind === 'CONTAINER_WARS' ? 's_m_m_dockwork_01' : 'a_m_y_runner_01'),
    };
  }

  function toggleCivilianPed() {
    form.settings.civilianPed = {
      ...(form.settings?.civilianPed || {}),
      enabled: !(form.settings?.civilianPed?.enabled !== false),
    };
  }

  function clearCivilianPed() {
    form.settings.civilianPed = {
      ...(form.settings?.civilianPed || {}),
      x: null,
      y: null,
      z: null,
      heading: 0,
    };
  }

  // ── Police Equipment Vendor & Escort Vehicle Shop ──
  let vendorLocation = null;
  let vendorEnabled = true;
  let vendorBusy = false;
  let escortLocation = null;
  let escortEnabled = true;
  let escortBusy = false;

  async function loadVendorAndEscort() {
    try {
      const vRes = await getEquipmentVendorLocation();
      if (vRes) {
        vendorEnabled = vRes.enabled !== false;
        vendorLocation = vRes;
      }
      const eRes = await getEscortShopLocation();
      if (eRes) {
        escortEnabled = eRes.enabled !== false;
        escortLocation = eRes;
      }
    } catch (err) {
      console.warn('Failed to load vendor/escort locations', err);
    }
  }

  onMount(() => {
    loadVendorAndEscort();
  });

  $: if (routeSub === 'peds' && !vendorLocation && !escortLocation) {
    loadVendorAndEscort();
  }

  $: if (form?.settings?.equipmentVendor?.x != null && !vendorLocation) {
    vendorLocation = form.settings.equipmentVendor;
    vendorEnabled = form.settings.equipmentVendor.enabled !== false;
  }
  $: if (form?.settings?.escortShop?.x != null && !escortLocation) {
    escortLocation = form.settings.escortShop;
    escortEnabled = form.settings.escortShop.enabled !== false;
  }

  async function setVendorHere(e) {
    const spot = e?.detail?.x != null ? e.detail : await getPlayerPosition();
    if (!spot || spot.x == null) return;
    vendorBusy = true;
    const res = await setEquipmentVendorLocation({ x: spot.x, y: spot.y, z: spot.z, heading: spot.heading ?? 0 });
    vendorBusy = false;
    if (res && res.ok && res.location) {
      vendorLocation = { ...vendorLocation, ...res.location, enabled: vendorEnabled };
    } else {
      vendorLocation = { ...vendorLocation, x: spot.x, y: spot.y, z: spot.z, heading: spot.heading ?? 0, enabled: vendorEnabled };
    }
    if (form && form.settings) {
      form.settings.equipmentVendor = { ...vendorLocation };
    }
    touch();
  }

  async function toggleVendor() {
    const next = !vendorEnabled;
    vendorBusy = true;
    const res = await setEquipmentVendorEnabled(next);
    vendorBusy = false;
    if (res && res.ok) {
      vendorEnabled = next;
      if (vendorLocation) vendorLocation = { ...vendorLocation, enabled: next };
      if (form && form.settings) {
        form.settings.equipmentVendor = { ...(form.settings.equipmentVendor || {}), enabled: next };
      }
      touch();
    }
  }

  async function setEscortShopHere(e) {
    const spot = e?.detail?.x != null ? e.detail : await getPlayerPosition();
    if (!spot || spot.x == null) return;
    escortBusy = true;
    const res = await setEscortShopLocation({ x: spot.x, y: spot.y, z: spot.z, heading: spot.heading ?? 0 });
    escortBusy = false;
    if (res && res.ok && res.location) {
      escortLocation = { ...escortLocation, ...res.location, enabled: escortEnabled };
    } else {
      escortLocation = { ...escortLocation, x: spot.x, y: spot.y, z: spot.z, heading: spot.heading ?? 0, enabled: escortEnabled };
    }
    if (form && form.settings) {
      form.settings.escortShop = { ...escortLocation };
    }
    touch();
  }

  async function toggleEscortShop() {
    const next = !escortEnabled;
    escortBusy = true;
    const res = await setEscortShopEnabled(next);
    escortBusy = false;
    if (res && res.ok) {
      escortEnabled = next;
      if (escortLocation) escortLocation = { ...escortLocation, enabled: next };
      if (form && form.settings) {
        form.settings.escortShop = { ...(form.settings.escortShop || {}), enabled: next };
      }
      touch();
    }
  }

  // Convoy (Route) and Gang Rally (Race Setup) split their placement tools
  // into Vectors (route points) and Ped Positions (every placeable ped).
  const PED_SUBTABS = [
    { id: 'vectors', label: 'Vectors', icon: 'route' },
    { id: 'peds', label: 'Ped Positions', icon: 'user' },
  ];
  let routeSub = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_route_sub')) || 'vectors';
  $: if (typeof localStorage !== 'undefined' && routeSub) {
    localStorage.setItem('nova_convoy_last_route_sub', routeSub);
  }

  let raceSub = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_race_sub')) || 'vectors';
  $: if (typeof localStorage !== 'undefined' && raceSub) {
    localStorage.setItem('nova_convoy_last_race_sub', raceSub);
  }

  // Mirrors Runtime.start()'s own server-side checks (server/modules/convoy_runtime.lua)
  // so "why did starting fail" is answered before the admin even clicks the
  // button, instead of after a generic server error comes back.
  // Mirrors the server's own rule (ConvoyManager.update: "Only draft or
  // scheduled convoys can be edited.") — once a convoy has actually started
  // (or already finished), editing it here would just fail at Save time with
  // a generic error; locking the form up front is a lot less confusing than
  // letting someone type into fields that were never going to save.
  $: locked = !!loadedId && form.status !== 'DRAFT' && form.status !== 'SCHEDULED';

  $: readiness = form.kind === 'CRACKDOWN'
    ? (() => {
        const cd = form.crackdown || {};
        const z = cd.zone || {};
        const gangOk = !!cd.targetGang && (availableGangs.length === 0 || availableGangs.some((g) => g.name === cd.targetGang));
        return [
          { label: 'Operation name is at least 3 characters', ok: form.name.trim().length >= 3 },
          { label: 'Target gang picked (Operation Setup tab)', ok: gangOk },
          { label: 'Combat zone placed on the map (Combat Zone tab)', ok: !!(z.center && Number.isFinite(Number(z.center.x)) && Number.isFinite(Number(z.center.y))) },
          { label: 'Preparation time and fight duration set', ok: Number(cd.prepSeconds) >= 10 && Number(form.eventDuration) >= 60 },
          { label: 'A gang reward is set (the winning gang is paid nothing otherwise)', ok: (form.reward || []).length > 0 },
          { label: 'The police on duty are recognised automatically — nothing to assign', ok: true },
        ];
      })()
    : form.kind === 'GANG_TERRITORY'
    ? territoryReadiness(form).filter((r) => !r.label.startsWith('Auction date'))   // a date is only needed to publish on a schedule, not to start now
    : form.kind === 'GANG_AIRDROP'
    ? [
        { label: 'Airdrop name is at least 3 characters', ok: form.name.trim().length >= 3 },
        // random mode picks from the zones you placed, so both modes need zones with positions
        {
          label: form.settings?.randomizeLocations
            ? 'At least one airdrop zone to pick from'
            : 'At least one airdrop zone configured',
          ok: form.airdropZones.length > 0,
        },
        {
          label: 'Every zone has a position set',
          ok: form.airdropZones.every((z) => z.x != null),
        },
      ]
    : form.kind === 'HOT_CARGO'
    ? (() => {
        // isRealZone mirrors the server's own isRealZonePos (doStartHotCargo,
        // convoy_runtime.lua) exactly — (0,0) is the tablet's own "never
        // placed" sentinel for a blank zone, not a real in-world spot, so it
        // must be excluded the same way there or this checklist could show
        // green for a zone the server will silently skip at start.
        const isRealZone = (v) => v && v.x != null && v.y != null && v.z != null && !(Number(v.x) === 0 && Number(v.y) === 0);
        const truckCount = (form.hotCargo?.trucks || []).length;
        const validSpawnZones = (form.hotCargo?.spawnZones || []).filter(isRealZone);
        const validDropZones = (form.hotCargo?.dropoffZones || []).filter(isRealZone);
        return [
          { label: 'Hot Cargo name is at least 3 characters', ok: form.name.trim().length >= 3 },
          { label: 'At least one cargo truck added in Trucks tab', ok: truckCount > 0 },
          // Every truck ALWAYS draws from the shuffled spawn-zone pool now —
          // there is no per-truck manual spawn vector fallback any more
          // (removed server-side; a truck's own x/y/z is never read for
          // positioning), so a zone-less truck config was never actually
          // going to spawn anything despite this checklist previously
          // showing green for it.
          { label: 'At least one spawn zone with a position set', ok: validSpawnZones.length > 0 },
          {
            label: `Enough spawn zones for every truck (${validSpawnZones.length} zone${validSpawnZones.length === 1 ? '' : 's'} for ${truckCount} truck${truckCount === 1 ? '' : 's'})`,
            ok: truckCount === 0 || validSpawnZones.length >= truckCount,
          },
          { label: 'At least one dropoff destination configured', ok: (form.hotCargo?.dropoffZones || []).length > 0 },
          { label: 'Every dropoff destination has a position set', ok: (form.hotCargo?.dropoffZones || []).every((d) => d.x != null) },
          // Informational, not blocking — dropoffs are randomly assigned per
          // truck same as spawn zones now, but unlike a spawn-zone shortfall
          // (which stops a truck spawning at all) a dropoff shortfall just
          // means some trucks end up sharing a destination this run, which
          // still works fine, just with less variety.
          ...(truckCount > 0 && validDropZones.length > 0 && validDropZones.length < truckCount
            ? [{ label: `Only ${validDropZones.length} dropoff${validDropZones.length === 1 ? '' : 's'} for ${truckCount} trucks — some will share a destination this run`, ok: true }]
            : []),
          { label: form.hotCargo?.policeAlert !== false ? `Police alert active (${form.hotCargo?.policeAlertBufferSeconds || 45}s stealth buffer)` : 'Police alert disabled (covert operation)', ok: true },
        ];
      })()
    : form.kind === 'GANG_RACE'
    ? [
        { label: 'Rally/Race name is at least 3 characters', ok: form.name.trim().length >= 3 },
        { label: 'At least one checkpoint or stage added', ok: (form.rallyStages || []).length > 0 },
        { label: 'Every checkpoint has coordinates set', ok: (form.rallyStages || []).every((s) => s.x != null) },
        { label: 'Rally has a START stage', ok: (form.rallyStages || []).some((s, i) => (s.kind ? s.kind === 'START' : i === 0)) },
        { label: 'Rally has a DESTINATION stage', ok: (form.rallyStages || []).some((s, i, a) => (s.kind ? s.kind === 'DESTINATION' : i === a.length - 1)) },
        { label: 'Gang participation enabled', ok: form.settings.gangPvp },
        { label: 'Police end-of-race pursuit dispatch enabled', ok: true },
        ...(form.settings.raceVehicleMode === 'PROVIDED' ? [{ label: 'Provided vehicles: at least one vehicle added and the vehicle ped placed', ok: (form.settings.raceVehicles || []).length > 0 && !!(form.settings.raceVehiclePed && form.settings.raceVehiclePed.x != null) }] : []),
      ]
    : form.kind === 'TDM'
    ? (() => {
        const gangCount = (form.settings.allowedGangs?.mode === 'SELECTED') ? (form.settings.allowedGangs.gangs || []).length : 0;
        const isTournament = form.tdm?.matchFormat === 'TOURNAMENT';
        return [
          { label: 'TDM Match name is at least 3 characters', ok: form.name.trim().length >= 3 },
          ...(isTournament
            ? [{ label: 'Tournament arena — gangs, draw and bracket are set up in the Tournament tab', ok: true }]
            : [{ label: `Standard TDM requires exactly 2 gangs (${gangCount} selected)`, ok: gangCount === 2 }]),
          { label: 'Match duration configured', ok: (form.tdm?.duration || 0) > 0 },
          { label: 'Combat zone polygon placed (at least 3 points, Match Setup tab)', ok: (form.tdm?.zone?.points || []).length >= 3 },
          { label: 'A respawn spawn point placed, or a team base perimeter drawn', ok: (form.tdm?.spawnPoints || []).length > 0 || (form.tdm?.respawnZoneRed?.points || []).length >= 3 || (form.tdm?.respawnZoneBlue?.points || []).length >= 3 },
          { label: 'Weapon vendor placed (optional but recommended)', ok: true },
        ];
      })()
    : form.kind === 'CONTAINER_WARS'
    ? (() => {
        const containers = form.containerWars?.containers || [];
        const hasPositions = containers.length > 0 && containers.every((c) => (c.dropCoords && c.dropCoords.x != null) || (c.drop && c.drop.x != null));
        const maxLots = Number($bootstrap?.containerWars?.maxLots) || 40;
        const nSpots = ($bootstrap?.containerWars?.harbour?.pickups || []).length;
        const perRound = Number(form.containerWars?.containersPerRound) || 1;
        const vehExcess = containers.some((c) => {
          const vehs = (c.rewards || []).filter((r) => (r.type || '').toUpperCase() === 'VEHICLE');
          return vehs.length > 1 || vehs.some((r) => (Number(r.amount) || 1) > 1);
        });
        return [
          { label: 'Container Wars name is at least 3 characters', ok: form.name.trim().length >= 3 },
          { label: `At least 1 container lot configured (max ${maxLots})`, ok: containers.length >= 1 && containers.length <= maxLots },
          { label: nSpots > 0 ? `Containers per round (${perRound}) fits the yard's ${nSpots} spot${nSpots === 1 ? '' : 's'}` : 'Containers per round fits the yard', ok: nSpots === 0 || perRound <= nSpots },
          { label: 'The harbour drop spot is set (config.lua)', ok: hasPositions },
          { label: 'Bidding perimeter drawn (or the harbour default is used)', ok: (form.containerWars?.zone?.points || []).length >= 3 || (($bootstrap?.containerWars?.harbour?.zone?.points) || []).length >= 3 },
          { label: 'Harbour crane is configured (config.lua)', ok: !!(form.containerWars?.crane && form.containerWars.crane.x != null) },
          { label: 'Gang participation enabled', ok: form.settings.gangPvp },
          { label: 'Vehicle rewards limit (maximum 1 vehicle per container)', ok: !vehExcess },
        ];
      })()
    : [
        { label: 'Convoy name is at least 3 characters', ok: form.name.trim().length >= 3 },
        { label: 'At least one truck added', ok: form.trucks.length > 0 },
        { label: 'At least one cargo truck (Primary or Secondary role)', ok: form.trucks.some((t) => t.role === 'PRIMARY_CARGO' || t.role === 'SECONDARY_CARGO') },
        { label: 'Route has a START point', ok: form.route.some((p) => p.type === 'START') },
        { label: 'Route has a DESTINATION point', ok: form.route.some((p) => p.type === 'DESTINATION') },
        { label: 'Gang PvP is enabled (required for gangs to join)', ok: form.settings.gangPvp },
        { label: form.maxPoliceParticipants > 0 ? `Police escorts enabled (${form.maxPoliceParticipants} spots)` : 'Police escorts disabled (0 spots — no police can join)', ok: true },
      ];
  $: canStart = readiness.every((r) => r.ok);
</script>

<div class="panel view-enter create-convoy-panel" style="--tablet-bg-img: url('{tabletBg}');">
  <div class="panel-header">
    <span class="panel-title">
      <Icon name={kindInfo.icon} size={14} />
      {loadedId ? `Edit ${kindInfo.title} #${loadedId}` : `Create ${kindInfo.full}`}
    </span>
    {#if loadedId}
      <button type="button" class="btn" on:click={resetToNew} title="Clear loaded event and create a new one">
        <Icon name="plus" size={13} />
        <span>New Event</span>
      </button>
    {/if}
  </div>

  {#if restoredDraft}
    <div class="draft-banner">
      <Icon name="activity" size={13} />
      <span>Restored unsaved changes from your last session here. Click <strong>Save</strong> below to keep them, or discard to reload the last saved version.</span>
      <button type="button" class="link-btn" on:click={discardDraft}>Discard & Reload from Server</button>
    </div>
  {/if}

  <!-- Event type selector: only when CREATING. An event that already exists keeps its type (switching it would start a different
       event), so editing shows no picker at all. -->
  {#if !loadedId}
  <div class="mode-tabs" role="tablist" aria-label="Event type">
    {#each visibleKindTabs as k (k.id)}
      <button
        type="button"
        role="tab"
        aria-selected={form.kind === k.id}
        class="mode-tab"
        class:active={form.kind === k.id}
        style="--k:{k.accent}"
        disabled={locked}
        title={k.desc + (loadedId && form.kind !== k.id ? ' — starts a new event' : '')}
        on:click={() => pickKind(k.id)}
      >
        <span class="mode-icon"><Icon name={k.icon} size={15} /></span>
        <span class="mode-tab-title">{k.title}</span>
      </button>
    {/each}
  </div>
  {/if}
  <div class="tabs">
    {#each TABS as tab, i}
      <button class="tab" class:active={activeTab === tab} on:click={() => setTab(tab)}>
        <span class="tab-step">{i + 1}</span>{tab}
      </button>
    {/each}
  </div>

  <div class="panel-body">
    {#if locked}
      <div class="lock-notice">
        <Icon name="shield" size={14} />
        This {form.kind === 'CRACKDOWN' ? 'operation' : form.kind === 'GANG_AIRDROP' ? 'airdrop event' : (form.kind === 'HOT_CARGO' ? 'hot cargo run' : (form.kind === 'GANG_RACE' ? 'gang rally' : (form.kind === 'TDM' ? 'TDM match' : (form.kind === 'CONTAINER_WARS' ? 'container wars auction' : (form.kind === 'GANG_TERRITORY' ? 'gang territory auction' : 'convoy')))))} is <strong>{form.status}</strong> — configuration is locked and can no longer be edited.
      </div>
      {#if form.kind === 'GANG_RACE' && form.raceGrid}
        <div class="lock-notice">
          <Icon name="flag" size={14} />
          Racers are gathering on the start grid.
          <button type="button" class="btn primary" disabled={countdownBusy} on:click={beginCountdown}><Icon name="play" size={12} /> Start Countdown</button>
        </div>
      {/if}
    {/if}
    {#if activeTab === 'General' || activeTab === 'Form'}
      {#if form.kind === 'HOT_CARGO'}
        <!-- 1. FORM TAB: General Hot Cargo Event Information -->
        <FormSectionHead title="Event Details" />
        <div class="field">
          <label>Event Name</label>
          <input
            type="text"
            bind:value={form.name}
            maxlength="100"
            placeholder="e.g. Los Santos Contraband Run"
            disabled={locked}
          />
        </div>
        <div class="field">
          <label>Description</label>
          <input type="text" bind:value={form.shortDescription} maxlength="255" placeholder="One line summary shown on lists" disabled={locked} />
        </div>
        <div class="field">
          <label>Detailed Description</label>
          <textarea
            bind:value={form.detailedDescription}
            maxlength="4000"
            placeholder="Full briefing text for gangs and police pursuit"
            disabled={locked}
          ></textarea>
        </div>

        <FormSectionHead title="Announcement" hint="shown in the banner" />
        <div class="field-row">
          <div class="field">
            <label>Announced Start Time <span class="optional">shown in banner</span></label>
            <input type="text" bind:value={form.settings.announceStartTime} maxlength="60" placeholder="e.g. 9:00 PM" disabled={locked} />
          </div>
          <div class="field">
            <label>Announced End Time <span class="optional">optional</span></label>
            <input type="text" bind:value={form.settings.announceEndTime} maxlength="60" placeholder="e.g. 10:30 PM" disabled={locked} />
          </div>
        </div>
        <div class="field">
          <label>Custom Announcement Message <span class="optional">extra line shown in the banner</span></label>
          <textarea bind:value={form.settings.announceMessage} maxlength="500" placeholder="e.g. Sponsored by the Ballas — double rewards tonight" disabled={locked}></textarea>
        </div>

        <FormSectionHead title="Duration & Trucks" />
        <div class="field">
          <label>Event Duration <span class="optional">total operation mission time</span></label>
          <div class="hms-row">
            <div class="field">
              <label>Hours</label>
              <input type="number" min="0" max="2" bind:value={durationHours} disabled={locked} />
            </div>
            <div class="field">
              <label>Minutes</label>
              <input type="number" min="0" max="59" bind:value={durationMinutes} disabled={locked} />
            </div>
            <div class="field">
              <label>Seconds</label>
              <input type="number" min="0" max="59" bind:value={durationSeconds} disabled={locked} />
            </div>
          </div>
        </div>

        <div class="field">
          <label>Number of Cargo Trucks <span class="optional">how many trucks to spawn at event start (e.g. 2)</span></label>
          <input
            type="number"
            min="1"
            max="20"
            bind:value={form.hotCargo.truckCount}
            placeholder="2"
            disabled={locked}
          />
        </div>

        <FormSectionHead title="Participation & Rules" />
        <div class="field" style="margin-top:14px">
          <label>Participation / Registration Requirements <span class="optional">who can hijack &amp; loot</span></label>
          <div class="chip-row">
            <button type="button" class="chip-btn" class:active={(form.settings?.allowedGangs?.mode || 'ALL') === 'ALL'} disabled={locked} on:click={() => setAllowedGangsMode('ALL')}>All Gangs</button>
            <button type="button" class="chip-btn" class:active={(form.settings?.allowedGangs?.mode || 'ALL') === 'SELECTED'} disabled={locked} on:click={() => setAllowedGangsMode('SELECTED')}>Selected Gangs</button>
          </div>
          {#if (form.settings?.allowedGangs?.mode || 'ALL') === 'SELECTED'}
            {#if availableGangs.length === 0}
              <div class="gang-picker-empty">No gangs have been added yet — see Gangs &amp; Permissions.</div>
            {:else}
              <div class="gang-picker-list">
                {#each availableGangs as g (g.id)}
                  <label class="gang-picker-item">
                    <input type="checkbox" checked={form.settings?.allowedGangs?.gangs?.includes(g.name)} disabled={locked} on:change={() => toggleAllowedGang(g.name)} />
                    <span>{g.label || g.name}</span>
                  </label>
                {/each}
              </div>
            {/if}
          {/if}
        </div>

        <div class="field" style="margin-top:14px">
          <label>Police Alert <span class="optional">notify police dispatch when truck is hijacked</span></label>
          <div class="chip-row">
            <button type="button" class="chip-btn" class:active={form.hotCargo.policeAlert !== false} disabled={locked} on:click={() => (form.hotCargo.policeAlert = true)}>Police Alert ON</button>
            <button type="button" class="chip-btn" class:active={form.hotCargo.policeAlert === false} disabled={locked} on:click={() => (form.hotCargo.policeAlert = false)}>Police Alert OFF</button>
          </div>
        </div>

        {#if form.hotCargo.policeAlert !== false}
          <div class="field">
            <label>Police Stealth Buffer (Seconds) <span class="optional">silent grace period after driver enters seat before dispatch</span></label>
            <input type="number" min="0" max="600" bind:value={form.hotCargo.policeAlertBufferSeconds} disabled={locked} placeholder="45" />
          </div>
        {/if}

        <div class="field" style="margin-top:14px">
          <label>Event End Condition <span class="optional">what happens if every truck ends up disabled or destroyed without delivery</span></label>
          <select bind:value={form.settings.failurePolicy} disabled={locked}>
            <option value="FAIL">End Event Immediately as Failed</option>
            <option value="CONTINUE">Keep Event Running (until timeout / Force End)</option>
          </select>
        </div>
      {:else if form.kind === 'CONTAINER_WARS'}
        <!-- 1. GENERAL TAB: Container Wars Event Information -->
        <FormSectionHead title="Event Details" />
        <div class="field">
          <label>Container Wars Auction Name</label>
          <input
            type="text"
            bind:value={form.name}
            maxlength="100"
            placeholder="e.g. Ocean Docks Container Yard Auction"
            disabled={locked}
          />
        </div>
        <div class="field">
          <label>Short Description</label>
          <input type="text" bind:value={form.shortDescription} maxlength="255" placeholder="e.g. High-stakes harbour container auction & bidding battle" disabled={locked} />
        </div>
        <div class="field">
          <label>Detailed Briefing</label>
          <textarea
            bind:value={form.detailedDescription}
            maxlength="4000"
            placeholder="Full auction briefing and rules shown to competing gangs..."
            disabled={locked}
          ></textarea>
        </div>

        <FormSectionHead title="Announcement" hint="shown in the banner" />
        <div class="field-row">
          <div class="field">
            <label>Announced Start Time <span class="optional">shown in banner</span></label>
            <input type="text" bind:value={form.settings.announceStartTime} maxlength="60" placeholder="e.g. 9:00 PM" disabled={locked} />
          </div>
          <div class="field">
            <label>Announced End Time <span class="optional">optional</span></label>
            <input type="text" bind:value={form.settings.announceEndTime} maxlength="60" placeholder="e.g. 10:30 PM" disabled={locked} />
          </div>
        </div>
        <div class="field">
          <label>Custom Announcement Message <span class="optional">extra line shown in the banner</span></label>
          <textarea bind:value={form.settings.announceMessage} maxlength="500" placeholder="e.g. Rare vehicle & military equipment containers arriving tonight" disabled={locked}></textarea>
        </div>

        <FormSectionHead title="Participation" />
        <div class="field" style="margin-top:14px">
          <label>Event Access <span class="optional">who is eligible to participate</span></label>
          <div class="chip-row">
            <button type="button" class="chip-btn" class:active={(form.settings?.eventAccess || 'GANGS') === 'GANGS'} disabled={locked} on:click={() => (form.settings.eventAccess = 'GANGS')}>Open to Gangs</button>
            <button type="button" class="chip-btn" class:active={(form.settings?.eventAccess || 'GANGS') === 'EVERYONE'} disabled={locked} on:click={() => (form.settings.eventAccess = 'EVERYONE')}>Open to Everyone</button>
          </div>
          <p class="field-hint" style="margin-top:4px;">
            {(form.settings?.eventAccess || 'GANGS') === 'EVERYONE' ? 'Civilians register via the civilian registration ped (place it in Lots & Arena → Bidding Perimeter & Peds). Gang members register via Event Status panel.' : 'Only registered gangs can bid.'}
          </p>
        </div>
        <!-- Which gangs may enter only matters for a gangs-only event. Open to Everyone lets every gang in, so the block is
             hidden (what was picked is kept, in case the admin switches back; the server ignores it while the event is
             open to everyone). -->
        {#if (form.settings?.eventAccess || 'GANGS') !== 'EVERYONE'}
          <div style="margin-top:14px">
            <GangSelector
              {availableGangs}
              title="Gang Access Requirements"
              hint="who can enter &amp; bid"
              allLabel="All Gangs (Open Auction)"
              selectedLabel="Selected Gangs (Invite-Only)"
              {locked}
              bind:allowedGangs={form.settings.allowedGangs}
              on:change={touch}
            />
          </div>
        {/if}

        <div class="field-row" style="margin-top:14px">
          <div class="field">
            <label>Max Competing Gangs <span class="optional">0 = unlimited</span></label>
            <input type="number" min="0" max="50" bind:value={form.settings.maxGangs} disabled={locked} placeholder="0" />
          </div>
          <div class="field">
            <label>Max Members Per Gang <span class="optional">0 = unlimited</span></label>
            <input type="number" min="0" max="50" bind:value={form.settings.maxMembersPerGang} disabled={locked} placeholder="0" />
          </div>
        </div>

        <FormSectionHead title="Bidding Rules" />
        <div class="field" style="margin-top:14px">
          <label>Anti-Snipe Extension Window (Seconds) <span class="optional">timer extension when a bid is placed near expiry</span></label>
          <input type="number" min="0" max="60" bind:value={form.settings.antiSnipeBufferSeconds} disabled={locked} placeholder="10" />
          <p class="field-hint" style="margin-top:4px;">Adds 10 seconds if any gang places a bid in the final 10 seconds, preventing unfair last-second sniping.</p>
        </div>
      {:else}
        <FormSectionHead title="Event Details" />
        <div class="field">
          <label>{form.kind === 'GANG_AIRDROP' ? 'Airdrop Operation Name' : (form.kind === 'GANG_RACE' ? 'Rally Race Name' : (form.kind === 'TDM' ? 'TDM Match Name' : 'Convoy Name'))}</label>
          <input
            type="text"
            bind:value={form.name}
            maxlength="100"
            placeholder={form.kind === 'GANG_AIRDROP' ? 'e.g. Sandy Shores Cache Drop' : (form.kind === 'GANG_RACE' ? 'e.g. Vinewood Midnight Sprint' : (form.kind === 'TDM' ? 'e.g. Grove Street Showdown' : 'e.g. Black Cargo'))}
            disabled={locked}
          />
        </div>
        <div class="field">
          <label>Short Description</label>
          <input type="text" bind:value={form.shortDescription} maxlength="255" placeholder="One line summary shown on lists" disabled={locked} />
        </div>
        <div class="field">
          <label>Detailed Description</label>
          <textarea
            bind:value={form.detailedDescription}
            maxlength="4000"
            placeholder={form.kind === 'GANG_AIRDROP' ? 'Full briefing text shown to competing gangs' : (form.kind === 'GANG_RACE' ? 'Full briefing text for participating street racers' : (form.kind === 'TDM' ? 'Full briefing text shown to the participating gangs' : 'Full briefing text shown to police/gangs'))}
            disabled={locked}
          ></textarea>
        </div>

        <FormSectionHead title="Announcement" hint="shown in the banner" />
        <div class="field-row">
          <div class="field">
            <label>Announced Start Time <span class="optional">shown in the banner — informational only, does not drive scheduling</span></label>
            <input type="text" bind:value={form.settings.announceStartTime} maxlength="60" placeholder="e.g. 9:00 PM" disabled={locked} />
          </div>
          <div class="field">
            <label>Announced End Time <span class="optional">optional</span></label>
            <input type="text" bind:value={form.settings.announceEndTime} maxlength="60" placeholder="e.g. 10:30 PM" disabled={locked} />
          </div>
        </div>
        <div class="field">
          <label>Custom Announcement Message <span class="optional">extra line shown in the banner when this event is announced or force-started</span></label>
          <textarea bind:value={form.settings.announceMessage} maxlength="500" placeholder="e.g. Sponsored by the Ballas — double rewards tonight" disabled={locked}></textarea>
        </div>

        {#if form.kind !== 'TDM'}
        <FormSectionHead title={form.kind === 'GANG_RACE' ? 'Prizes' : (form.kind === 'GANG_AIRDROP' ? 'Crate & Difficulty' : 'Cargo & Difficulty')} />
        <div class="field-row">
          <div class="field">
            <label>{form.kind === 'GANG_AIRDROP' ? 'Airdrop Crate Loot Type' : (form.kind === 'GANG_RACE' ? 'Rally Prize / Stakes Type' : 'Cargo Type')}</label>
            <select bind:value={form.cargo.type} disabled={locked}>
              {#each CARGO_TYPES as t}<option value={t}>{t}</option>{/each}
            </select>
          </div>
          <div class="field">
            <label>{form.kind === 'GANG_AIRDROP' ? 'Crate Contents Description' : (form.kind === 'GANG_RACE' ? 'Rally Prize Description' : 'Cargo Description')}</label>
            <input
              type="text"
              bind:value={form.cargo.description}
              maxlength="255"
              placeholder={form.kind === 'GANG_AIRDROP' ? 'e.g. Military rifles and contraband' : (form.kind === 'GANG_RACE' ? 'e.g. Slips, cash prize & black market parts' : 'e.g. Military-grade rifles')}
              disabled={locked}
            />
          </div>
        </div>
        {/if}

        {#if form.kind === 'GANG_RACE'}
          <div class="reward-and-position-row">
            <div class="field">
              <label>Position Rewards <span class="optional">set the payout for each finishing place — a slot left empty pays nothing</span></label>
              <div class="position-rewards-grid">
                <div class="position-reward-slot">
                  <div class="position-reward-label">🥇 1st Place</div>
                  <RewardListEditor bind:rewards={form.positionRewards.first} disabled={locked} allowTokens={true} />
                </div>
                <div class="position-reward-slot">
                  <div class="position-reward-label">🥈 2nd Place</div>
                  <RewardListEditor bind:rewards={form.positionRewards.second} disabled={locked} allowTokens={true} />
                </div>
                <div class="position-reward-slot">
                  <div class="position-reward-label">🥉 3rd Place</div>
                  <RewardListEditor bind:rewards={form.positionRewards.third} disabled={locked} allowTokens={true} />
                </div>
                <div class="position-reward-slot">
                  <div class="position-reward-label">🎟️ Participation <span class="optional">everyone else who finished</span></div>
                  <RewardListEditor bind:rewards={form.positionRewards.participation} disabled={locked} allowTokens={true} />
                </div>
              </div>
            </div>
          </div>
        {/if}

        {#if form.kind !== 'GANG_RACE' && form.kind !== 'TDM'}
          <div class="field">
            <label>Event Difficulty</label>
            <select bind:value={form.difficulty} disabled={locked}>
              {#each DIFFICULTIES as d}<option value={d}>{d}</option>{/each}
            </select>
          </div>
        {/if}

        {#if form.kind === 'GANG_AIRDROP'}
          <FormSectionHead title="Duration & Access" />
          <div class="field">
            <label>Airdrop Event Duration <span class="optional">total active duration</span></label>
            <div class="hms-row">
              <div class="field">
                <label>Hours</label>
                <input type="number" min="0" max="2" bind:value={durationHours} disabled={locked} />
              </div>
              <div class="field">
                <label>Minutes</label>
                <input type="number" min="0" max="59" bind:value={durationMinutes} disabled={locked} />
              </div>
              <div class="field">
                <label>Seconds</label>
                <input type="number" min="0" max="59" bind:value={durationSeconds} disabled={locked} />
              </div>
            </div>
          </div>

          <div style="margin-top:14px">
            <GangSelector
              {availableGangs}
              title="Gang Access"
              hint="who can loot this event"
              {locked}
              bind:allowedGangs={form.settings.allowedGangs}
              on:change={touch}
            />
          </div>

          <!-- The drop count and the "rotate spots" switch live on the Airdrop Zones tab only (one place, not two). -->
        {:else if form.kind === 'GANG_RACE'}
        <FormSectionHead title="Race Format" />
        <div class="field">
          <label>Rally / Race Duration <span class="optional">max time to complete</span></label>
          <div class="hms-row">
            <div class="field">
              <label>Hours</label>
              <input type="number" min="0" max="2" bind:value={durationHours} disabled={locked} />
            </div>
            <div class="field">
              <label>Minutes</label>
              <input type="number" min="0" max="59" bind:value={durationMinutes} disabled={locked} />
            </div>
            <div class="field">
              <label>Seconds</label>
              <input type="number" min="0" max="59" bind:value={durationSeconds} disabled={locked} />
            </div>
          </div>
        </div>

        <!-- A per-gang limit only makes sense when the race is for gangs; an Open to Everyone race has no gang limit, so the
             choice is hidden then (what was picked is kept in case you switch back). -->
        {#if (form.settings?.eventAccess || 'GANGS') !== 'EVERYONE'}
          <div class="field">
            <label>Racers per gang <span class="optional">how many racers one gang may bring</span></label>
            <div class="chip-row">
              <button type="button" class="chip-btn" class:active={(form.settings.raceEntryMode || 'TEAM') === 'TEAM'} disabled={locked}
                on:click={() => { form.settings.raceEntryMode = 'TEAM'; if (!(form.settings.maxMembersPerGang > 0)) form.settings.maxMembersPerGang = 2; }}>Limited per gang</button>
              <button type="button" class="chip-btn" class:active={form.settings.raceEntryMode === 'OPEN'} disabled={locked}
                on:click={() => { form.settings.raceEntryMode = 'OPEN'; }}>No limit per gang</button>
            </div>
          </div>
        {/if}

        <div class="field">
          <label>Vehicle Collision</label>
          <div class="chip-row">
            <button type="button" class="chip-btn" class:active={(form.settings.raceCollision || 'ON') === 'ON'} disabled={locked}
              on:click={() => { form.settings.raceCollision = 'ON'; }}>Collision On</button>
            <button type="button" class="chip-btn" class:active={form.settings.raceCollision === 'OFF'} disabled={locked}
              on:click={() => { form.settings.raceCollision = 'OFF'; }}>Collision Off (Ghost)</button>
          </div>
        </div>

        <div class="field">
          <label>1. Wait before the start grid opens <span class="optional">a "Race starts in HH:MM:SS" timer after you press Start, so people can get ready. Server default = no wait (the grid opens at once); set Custom to add one</span></label>
          <div class="delay-mode-row">
            <label class="radio-inline"><input type="radio" name="raceLeadMode" value="default" checked={delayMode === 'default'} on:change={useServerDefaultDelay} disabled={locked} /> Server default</label>
            <label class="radio-inline"><input type="radio" name="raceLeadMode" value="custom" checked={delayMode === 'custom'} on:change={() => (delayMode = 'custom')} disabled={locked} /> Custom</label>
          </div>
          {#if delayMode === 'custom'}
            <div class="hms-row">
              <div class="field">
                <label>Hours</label>
                <input type="number" min="0" bind:value={delayHours} disabled={locked} />
              </div>
              <div class="field">
                <label>Minutes</label>
                <input type="number" min="0" max="59" bind:value={delayMinutes} disabled={locked} />
              </div>
              <div class="field">
                <label>Seconds</label>
                <input type="number" min="0" max="59" bind:value={delaySeconds} disabled={locked} />
              </div>
            </div>
          {/if}
        </div>

        <div class="field">
          <label>2. Time on the grid before the 3-2-1 <span class="optional">seconds racers have, after the wait above, to reach the start line; the 3-2-1 starts sooner once everyone is in position — blank = server default</span></label>
          <input type="number" min="15" max="1800" placeholder="e.g. 120" bind:value={form.settings.raceGridWaitSeconds} disabled={locked} />
        </div>

        <FormSectionHead title="Entrants & Access" />
        <div class="field" style="margin-top:14px">
          <label>Event Access <span class="optional">who is eligible to participate</span></label>
          <div class="chip-row">
            <button type="button" class="chip-btn" class:active={(form.settings?.eventAccess || 'GANGS') === 'GANGS'} disabled={locked} on:click={() => (form.settings.eventAccess = 'GANGS')}>Open to Gangs</button>
            <button type="button" class="chip-btn" class:active={(form.settings?.eventAccess || 'GANGS') === 'EVERYONE'} disabled={locked} on:click={() => (form.settings.eventAccess = 'EVERYONE')}>Open to Everyone</button>
          </div>
          <p class="field-hint" style="margin-top:4px;">
            {(form.settings?.eventAccess || 'GANGS') === 'EVERYONE' ? 'Civilians register via the race registration ped. Gang members register via Event Status panel.' : 'Only registered gangs can race.'}
          </p>
        </div>
        {#if (form.settings?.eventAccess || 'GANGS') === 'EVERYONE'}
          <div style="margin-top: 14px;">
            <PedRow
              title="Civilian Registration Ped"
              description="Placement for the civilian registration ped for this race. Civilians interact here to join the race."
              pos={form.settings.civilianPed}
              toggleable
              enabled={form.settings.civilianPed?.enabled !== false}
              {locked}
              on:set={setCivilianPedHere}
              on:toggle={toggleCivilianPed}
              on:clear={clearCivilianPed}
            />
          </div>
        {/if}
        <div class="field-row">
          <div class="field">
            <label>Max Racers (Total)</label>
            <input type="number" min="1" max="100" bind:value={form.maxGangParticipants} disabled={locked} />
          </div>
          {#if (form.settings.raceEntryMode || 'TEAM') === 'TEAM' && (form.settings?.eventAccess || 'GANGS') !== 'EVERYONE'}
            <div class="field">
              <label>Racers Per Gang</label>
              <input type="number" min="1" max="20" bind:value={form.settings.maxMembersPerGang} disabled={locked} />
            </div>
          {/if}
          <div class="field">
            <label>Max Competing Gangs <span class="optional">0 = unlimited</span></label>
            <input type="number" min="0" max="20" bind:value={form.settings.maxGangs} disabled={locked} />
          </div>
        </div>

        <!-- Which gangs may enter only matters for a gangs-only race: Open to Everyone already lets every gang (and civilians)
             in, so this second "who can enter" block is hidden then (what was picked is kept in case you switch back). -->
        {#if (form.settings?.eventAccess || 'GANGS') !== 'EVERYONE'}
          <div style="margin-top:14px">
            <GangSelector
              {availableGangs}
              title="Gang Access"
              hint="which gangs can enter"
              {locked}
              bind:allowedGangs={form.settings.allowedGangs}
              on:change={touch}
            />
          </div>
        {/if}
      {:else if form.kind === 'TDM'}
        <div class="tdm-general-hint">
          <Icon name="flag" size={14} />
          <span>Match format, duration, kill limit and the participating gangs picker are on the <strong>Match Setup</strong> tab.</span>
        </div>
      {:else}
        <FormSectionHead title="Duration & Participants" />
        <div class="field">
          <label>Event Duration <span class="optional">total time to escort + deliver</span></label>
          <div class="hms-row">
            <div class="field">
              <label>Hours</label>
              <input type="number" min="0" max="2" bind:value={durationHours} disabled={locked} />
            </div>
            <div class="field">
              <label>Minutes</label>
              <input type="number" min="0" max="59" bind:value={durationMinutes} disabled={locked} />
            </div>
            <div class="field">
              <label>Seconds</label>
              <input type="number" min="0" max="59" bind:value={durationSeconds} disabled={locked} />
            </div>
          </div>
        </div>

        <div class="field-row">
          <div class="field">
            <label>Max Gang Participants <span class="optional">0 = none</span></label>
            <input type="number" min="0" bind:value={form.maxGangParticipants} disabled={locked} />
          </div>
          <div class="field">
            <label>Max Police Participants <span class="optional">0 = none</span></label>
            <input type="number" min="0" bind:value={form.maxPoliceParticipants} disabled={locked} />
          </div>
        </div>

        <div class="field">
          <label>Max Number of Gangs <span class="optional">0 = unlimited</span></label>
          <input type="number" min="0" max="20" bind:value={form.settings.maxGangs} disabled={locked} />
        </div>

        <div class="field">
          <label>Max Escort Vehicles From Shop Ped</label>
          <input type="number" min="0" bind:value={form.maxEscortVehicles} disabled={locked} />
        </div>

        <FormSectionHead title="Rules & Timing" />
        <div class="field">
          <label>Lockpicks to Loot a Lost Truck <span class="optional">blank = default</span></label>
          <input type="text" inputmode="numeric" placeholder="e.g. 3" bind:value={form.settings.lockpicksRequired} disabled={locked} />
        </div>

        <div class="field">
          <label>Police Head Start Delay</label>
          <div class="delay-mode-row">
            <label class="radio-inline"><input type="radio" name="delayMode" value="default" checked={delayMode === 'default'} on:change={useServerDefaultDelay} disabled={locked} /> Server default</label>
            <label class="radio-inline"><input type="radio" name="delayMode" value="custom" checked={delayMode === 'custom'} on:change={() => (delayMode = 'custom')} disabled={locked} /> Custom</label>
          </div>
          {#if delayMode === 'custom'}
            <div class="hms-row">
              <div class="field">
                <label>Hours</label>
                <input type="number" min="0" bind:value={delayHours} disabled={locked} />
              </div>
              <div class="field">
                <label>Minutes</label>
                <input type="number" min="0" max="59" bind:value={delayMinutes} disabled={locked} />
              </div>
              <div class="field">
                <label>Seconds</label>
                <input type="number" min="0" max="59" bind:value={delaySeconds} disabled={locked} />
              </div>
            </div>
          {/if}
        </div>
      {/if}
      {/if}

      <!-- Container Wars has no toggles here (its bidding / access rules are above), so no empty heading for it -->
      {#if form.kind !== 'CONTAINER_WARS'}
      <FormSectionHead title="Event Options" />
      <div class="toggle-group">
        {#if form.kind === 'CONVOY'}
          <Toggle label="Gang PvP" bind:checked={form.settings.gangPvp} disabled={locked} />
          <Toggle label="Server announcements" bind:checked={form.settings.announcements} disabled={locked} />
          <Toggle label="Allow Drive-By Shooting for Participants (Rifles, SMGs, Pistols)" bind:checked={form.settings.forceDriveBy} disabled={locked} />
          <Toggle label="Require Police Escort Proximity" bind:checked={form.settings.requireEscortProximity} disabled={locked} />
        {:else if form.kind === 'HOT_CARGO'}
          <Toggle label="Server announcements" bind:checked={form.settings.announcements} disabled={locked} />
          <Toggle label="Allow Drive-By Shooting for Participants (Rifles, SMGs, Pistols)" bind:checked={form.settings.forceDriveBy} disabled={locked} />
        {:else if form.kind === 'GANG_RACE'}
          <Toggle label="Server announcements" bind:checked={form.settings.announcements} disabled={locked} />
        {:else if form.kind === 'GANG_AIRDROP'}
          <Toggle label="Server announcements" bind:checked={form.settings.announcements} disabled={locked} />
        {:else if form.kind === 'TDM'}
          <Toggle label="Server announcements" bind:checked={form.settings.announcements} disabled={locked} />
        {/if}
      </div>
      {/if}
    {:else if activeTab === 'Trucks' || activeTab === 'Cargo Trucks'}
      {#if form.kind === 'HOT_CARGO'}
        <HotCargoConfig bind:hotCargo={form.hotCargo} {locked} section="trucks" />
      {:else}
        <TruckConfig bind:trucks={form.trucks} bind:reward={form.reward} bind:escortHealth={form.escortVehicleHealth} {locked} />
      {/if}
    {:else if activeTab === 'Route'}
      <SubTabs tabs={PED_SUBTABS} bind:active={routeSub} />
      <!-- Both panes stay mounted (hidden, not destroyed) so an in-progress
           route recording / map preview survives flipping to Ped Positions. -->
      <div class:hidden={routeSub !== 'vectors'}>
        <RouteBuilder bind:route={form.route} bind:checkpoints={form.checkpoints} bind:airdrops={form.airdrops} bind:props={form.props} settings={form.settings} trucks={form.trucks} {locked} />
      </div>
      {#if routeSub === 'peds'}
        <PedRow
          title="Start Trigger Ped"
          description="Police-only — a physical ped police interact with to start the convoy. Works instantly if this convoy isn't scheduled yet; if it IS scheduled, police still have to wait for the due time."
          pos={form.startPed}
          toggleable
          enabled={!!form.startPed.enabled}
          {locked}
          on:set={setStartPedHere}
          on:toggle={toggleStartPed}
          on:clear={clearStartPed}
        />
        <PedRow
          title="Police Equipment Vendor"
          description="The tactical throwables shop ped (not a convoy checkpoint NPC) — server-wide, not tied to any one convoy's truck list. Only purchasable while a convoy is actually active."
          pos={vendorLocation}
          model={$bootstrap?.pedModels?.equipmentVendor || 's_m_y_cop_01'}
          toggleable
          enabled={vendorEnabled}
          busy={vendorBusy}
          clearable={false}
          {locked}
          on:set={setVendorHere}
          on:toggle={toggleVendor}
        />
        <PedRow
          title="Escort Vehicle Shop"
          description="The ped police can request an on-demand escort vehicle from — not tied to any one convoy's truck list."
          pos={escortLocation}
          model={$bootstrap?.pedModels?.escortShop || 's_m_y_cop_01'}
          toggleable
          enabled={escortEnabled}
          busy={escortBusy}
          clearable={false}
          {locked}
          on:set={setEscortShopHere}
          on:toggle={toggleEscortShop}
        />
      {/if}
    {:else if activeTab === 'Airdrop Zones'}
      <AirdropZones bind:zones={form.airdropZones} bind:settings={form.settings} bind:props={form.props} eventDuration={form.eventDuration} {locked} />
    {:else if activeTab === 'Route Builder' || activeTab === 'Hot Cargo Drops'}
      <HotCargoConfig bind:hotCargo={form.hotCargo} {locked} section="drops" />
    {:else if activeTab === 'Race Setup'}
      <SubTabs tabs={PED_SUBTABS} bind:active={raceSub} />
      <RallyRaceConfig bind:rallyStages={form.rallyStages} bind:props={form.props} {locked} bind:settings={form.settings} view={raceSub}>
        <PedRow
          slot="organizer"
          title="Race Organizer Ped"
          description="Spawns the race master at the starting grid. Racers line up and interact with this ped to initiate the race countdown."
          pos={form.startPed}
          toggleable
          enabled={!!form.startPed.enabled}
          {locked}
          on:set={setStartPedHere}
          on:toggle={toggleStartPed}
          on:clear={clearStartPed}
        />
        {#if form.settings?.eventAccess === 'EVERYONE'}
          <PedRow
            slot="civilianPed"
            title="Civilian Registration Ped"
            description="Allows normal civilians to sign up for this race. Displays an ox_lib confirmation dialog upon interaction."
            pos={form.settings.civilianPed}
            toggleable
            enabled={form.settings.civilianPed?.enabled !== false}
            {locked}
            on:set={setCivilianPedHere}
            on:toggle={toggleCivilianPed}
            on:clear={clearCivilianPed}
          />
        {/if}
      </RallyRaceConfig>
    {:else if activeTab === 'Match Setup'}
      <TdmConfig bind:tdm={form.tdm} bind:reward={form.reward} bind:settings={form.settings} {locked} {availableGangs} />
    {:else if activeTab === 'Auction Setup' || activeTab === 'Lots & Bidding'}
      <TerritoryConfig section={activeTab === 'Auction Setup' ? 'setup' : 'areas'} bind:form {locked} {availableGangs} {loadedId} on:save={save} />
    {:else if activeTab === 'Review' && form.kind === 'GANG_TERRITORY'}
      <TerritoryConfig section="review" bind:form {locked} {availableGangs} {loadedId} on:save={save} on:publish={publishTerritory} />
    {:else if activeTab === 'Operation Setup' || activeTab === 'Combat Zone' || activeTab === 'Rewards & Rules'}
      <CrackdownConfig section={activeTab === 'Operation Setup' ? 'setup' : activeTab === 'Combat Zone' ? 'zone' : 'rewards'} bind:form {locked} {availableGangs} />
    {:else if activeTab === 'Container Wars Setup'}
      <ContainerWarsConfig section="yard" bind:containerWars={form.containerWars} bind:props={form.props} {locked} />
    {:else if activeTab === 'Props'}
      {#if form.kind === 'CONTAINER_WARS'}
        <ContainerWarsConfig section="props" bind:containerWars={form.containerWars} bind:props={form.props} {locked} />
      {:else}
        <!-- Convoy: its checkpoints' stored props / vehicles are part of this list (same saved data the Route tab edits). -->
        <PropsPanel
          bind:props={form.props}
          bind:checkpoints={form.checkpoints}
          withCheckpoints={form.kind === 'CONVOY'}
          route={form.route}
          eventKey={String(loadedId ?? form.id ?? 'draft')}
          context={propContext}
          title={PROP_TITLES[form.kind] || 'Event props'}
          guides={buildEventGuides(form)}
          {locked}
        />
      {/if}
    {:else if activeTab === 'Auction Rules'}
      <ContainerWarsConfig section="auction" bind:containerWars={form.containerWars} bind:props={form.props} {locked} />
    {:else if activeTab === 'Lots & Arena'}
      <ContainerWarsConfig section="lots" bind:containerWars={form.containerWars} bind:props={form.props} {locked}>
        <!-- The row is always here so the ped can be placed (the card used to be empty unless the event was already open
             to everyone, which looked like the button was missing). The ped only appears in the world for events open to
             everyone, and the note says so. -->
        <div slot="civilianPed" class="ped-slot">
          {#if (form.settings?.eventAccess || 'GANGS') !== 'EVERYONE'}
            <div class="ped-note">
              <span>This ped only appears in the world when <b>Event Access</b> is <b>Open to Everyone</b>. This event is open to gangs only, so no registration ped will be placed.</span>
              <button type="button" class="btn btn-xs" on:click={() => (form.settings.eventAccess = 'EVERYONE')} disabled={locked}>Open to Everyone</button>
            </div>
          {/if}
          <PedRow
            title="Civilian Registration Ped"
            description="Placement for the civilian registration ped at the docks. Civilians interact here to join the Container War auction."
            pos={form.settings.civilianPed}
            toggleable
            enabled={form.settings.civilianPed?.enabled !== false}
            {locked}
            on:set={setCivilianPedHere}
            on:toggle={toggleCivilianPed}
            on:clear={clearCivilianPed}
          />
        </div>
      </ContainerWarsConfig>
    {:else if activeTab === 'Review'}
      <div class="checklist">
        <div class="checklist-title">Ready to Start?</div>
        {#each readiness as r (r.label)}
          <div class="check-row" class:ok={r.ok}>
            <Icon name={r.ok ? 'check' : 'close'} size={13} />
            <span>{r.label}</span>
          </div>
        {/each}
      </div>
      <div class="summary-grid">
        {#if form.kind === 'HOT_CARGO'}
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#4f94e6; font-weight:700;">1. Event Summary</div>
            <div class="summary-value">{form.name || '—'}</div>
            <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6;">
              <div><strong>Description:</strong> {form.shortDescription || form.detailedDescription || '—'}</div>
              <div><strong>Duration:</strong> {Math.round(form.eventDuration / 60)} minutes</div>
              <div><strong>Cargo Trucks to Spawn:</strong> {form.hotCargo?.truckCount || (form.hotCargo?.trucks || []).length || 2} truck(s)</div>
              <div><strong>Police Alert:</strong> {form.hotCargo?.policeAlert !== false ? `Enabled (${form.hotCargo?.policeAlertBufferSeconds || 45}s stealth window)` : 'Disabled (Covert)'}</div>
              <div><strong>End Condition:</strong> {form.settings?.failurePolicy === 'FAIL' ? 'End event immediately as failed if all trucks lost' : 'Keep running until duration timeout'}</div>
            </div>
          </div>

          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#4f94e6; font-weight:700;">2. Trucks Configuration ({(form.hotCargo?.trucks || []).length} Configured)</div>
            {#if (form.hotCargo?.trucks || []).length === 0}
              <div class="summary-value" style="font-size:var(--fs-small); color:var(--text-dim);">No trucks configured.</div>
            {:else}
              <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6; display:flex; flex-direction:column; gap:6px;">
                {#each form.hotCargo?.trucks || [] as t, i}
                  <div style="padding:6px 10px; background:var(--tablet-panel); border-radius:var(--radius-sm); border:1px solid var(--tablet-border);">
                    <div style="font-weight:700; color:var(--text-main);">#{i + 1} {t.name || 'Cargo Truck'} &bull; {t.model || 'hauler'} &bull; {t.health || 2500} HP</div>
                    <div style="font-size:var(--fs-small); margin-top:2px;">
                      <span style="color:#4f94e6;">🏆 Delivery Reward:</span> {formatRewardSummary(t.deliveryReward)} &bull; 
                      <span style="color:#38bdf8;">🔓 Hijack Reward:</span> {formatRewardSummary(t.hijackReward)}
                    </div>
                  </div>
                {/each}
              </div>
            {/if}
          </div>

          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#4f94e6; font-weight:700;">3. Hot Cargo Drops Summary</div>
            <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6;">
              <div><strong>Truck Spawn Mode:</strong> {form.hotCargo?.spawnMode || 'RANDOM'} SPAWN</div>
              <div><strong>Spawn Zones:</strong> {(form.hotCargo?.spawnZones || []).length} configured candidate zone(s)</div>
              <div><strong>Destination Zones:</strong> {(form.hotCargo?.dropoffZones || []).length} delivery dropoff destination(s)</div>
              <div><strong>Hostile NPC Guards:</strong> {(form.hotCargo?.spawnZones || []).reduce((a, z) => a + (z.guardCount || 0), 0) + (form.hotCargo?.dropoffZones || []).reduce((a, d) => a + (d.guardCount || 0), 0)} guards guarding zones &amp; dropoffs</div>
              <div><strong>Placement Status:</strong> {(form.hotCargo?.trucks || []).filter(t => t.mode === 'MANUAL' && t.x != null).length} / {(form.hotCargo?.trucks || []).length} manual positions set</div>
            </div>
          </div>
        {:else if form.kind === 'TDM'}
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#4f94e6; font-weight:700;">1. Event Summary</div>
            <div class="summary-value">{form.name || '—'}</div>
            <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6;">
              <div><strong>Match Format:</strong> {form.tdm?.matchFormat === 'TOURNAMENT' ? 'Tournament arena (played from the Tournament tab)' : 'Standard TDM'}</div>
              <div><strong>Match Duration:</strong> {Math.round((form.tdm?.duration || 0) / 60)} minutes</div>
              <div><strong>Kill Limit:</strong> {form.tdm?.killLimit ? `${form.tdm.killLimit} kills` : 'None (timer only)'}</div>
              <div><strong>Reward:</strong> {formatRewardSummary(form.reward)} <span class="optional">(paid to the winning gang)</span></div>
            </div>
          </div>
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#4f94e6; font-weight:700;">2. Participating Gangs ({(form.settings?.allowedGangs?.gangs || []).length} selected)</div>
            {#if (form.settings?.allowedGangs?.gangs || []).length === 0}
              <div class="summary-value" style="font-size:var(--fs-small); color:var(--text-dim);">No gangs selected yet — see Match Setup.</div>
            {:else}
              <div class="roster-chip-list">
                {#each form.settings.allowedGangs.gangs as gangName}
                  <span class="roster-chip">{(availableGangs.find(g => g.name === gangName) || {}).label || gangName}</span>
                {/each}
              </div>
            {/if}
          </div>
        {:else if form.kind === 'CRACKDOWN'}
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#d6336c; font-weight:700;">Operation Crackdown</div>
            <div class="summary-value">{form.name || '—'}</div>
            <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6;">
              <div><strong>Sides:</strong> {(availableGangs.find((g) => g.name === form.crackdown?.targetGang) || {}).label || form.crackdown?.targetGang || '— no gang —'} vs the Police (on duty, recognised automatically)</div>
              <div><strong>Zone:</strong> {form.crackdown?.zone?.shape === 'square' ? `Square, ${Math.round((form.crackdown?.zone?.size || 0) * 2)} m wide` : `Circle, ${Math.round(form.crackdown?.zone?.radius || 0)} m radius`}{form.crackdown?.zone?.center ? '' : ' (not placed)'}</div>
              <div><strong>Timing:</strong> {form.crackdown?.prepSeconds || 0}s preparation, then {Math.round((form.eventDuration || 0) / 60)} minutes of fighting</div>
              <div><strong>Rules:</strong> no points — anyone who goes down is eliminated; the side with fighters left wins, at time the side with more standing wins (equal = draw)</div>
              <div><strong>Outside the zone:</strong> eliminated after {form.crackdown?.outsideSeconds}s</div>
              <div><strong>Minimum fighters:</strong> {form.crackdown?.minGang} gang · {form.crackdown?.minPolice} police on duty when the fight opens</div>
              <div><strong>Gang reward:</strong> {formatRewardSummary(form.reward)}</div>
              <div><strong>Police reward:</strong> {formatRewardSummary(form.crackdown?.policeReward)}{form.crackdown?.gangLoseXpPenalty ? ` · the gang loses ${form.crackdown.gangLoseXpPenalty} Gang XP if the police win` : ''}</div>
            </div>
          </div>
        {:else if form.kind === 'CONTAINER_WARS'}
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#38bdf8; font-weight:700;">1. Container Wars Overview</div>
            <div class="summary-value">{form.name || '—'}</div>
            <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6;">
              <div><strong>Description:</strong> {form.shortDescription || form.detailedDescription || 'Harbour dock container yard auction'}</div>
              <div><strong>Total Containers:</strong> {(form.containerWars?.containers || []).length} / {form.containerWars?.maxContainers || 4} configured</div>
              <div><strong>Containers Per Round:</strong> {form.containerWars?.containersPerRound || 4} ({Math.ceil(((form.containerWars?.containers || []).length || 1) / (form.containerWars?.containersPerRound || 4))} total round(s))</div>
              <div><strong>Bidding Zone:</strong> {(form.containerWars?.zone?.points || []).length} polygon vertices</div>
              <div><strong>Yard:</strong> Fixed harbour — one drop spot, the gantry crane moves each container</div>
              <div><strong>Crane:</strong> {form.containerWars?.crane?.useWorldCrane ? 'Existing map crane' : 'Spawned crane prop'} &bull; travel {form.containerWars?.craneTravelSeconds ?? 8}s &bull; hoist {form.containerWars?.craneLiftHeight ?? 14}m</div>
              <div><strong>Pacing:</strong> settle {form.containerWars?.settleSeconds ?? 2}s &bull; opening {form.containerWars?.openSeconds ?? 3}s &bull; lot gap {form.containerWars?.lotGapSeconds ?? 3}s &bull; round break {form.containerWars?.roundBreakSeconds ?? 10}s &bull; final round {form.containerWars?.finalRoundEnabled !== false && (form.containerWars?.containers || []).length > 1 ? `on (break ${form.containerWars?.finalRoundBreakSeconds ?? 30}s)` : 'off'} &bull; carry {form.containerWars?.carryPath === 'STRAIGHT' ? 'straight line' : 'smooth arc curve'}</div>
              <div><strong>Anti-snipe:</strong> {(form.containerWars?.antiSnipeExtendSeconds ?? 10) > 0 ? `+${form.containerWars?.antiSnipeExtendSeconds ?? 10}s when a bid lands in the last ${form.containerWars?.antiSnipeWindowSeconds ?? 10}s` : 'off'}</div>
              <div><strong>Crane Coords:</strong> {form.containerWars?.crane?.x != null ? `${form.containerWars.crane.x.toFixed(1)}, ${form.containerWars.crane.y.toFixed(1)}, ${form.containerWars.crane.z.toFixed(1)}` : 'Not set'}</div>
            </div>
          </div>
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#38bdf8; font-weight:700;">2. Configured Containers ({(form.containerWars?.containers || []).length})</div>
            {#if (form.containerWars?.containers || []).length === 0}
              <div class="summary-value" style="font-size:var(--fs-small); color:var(--text-dim);">No containers configured yet — see the Lots &amp; Arena tab.</div>
            {:else}
              <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6; display:flex; flex-direction:column; gap:6px;">
                {#each form.containerWars?.containers || [] as c, i}
                  <div style="padding:6px 10px; background:var(--tablet-panel); border-radius:var(--radius-sm); border:1px solid var(--tablet-border);">
                    <div style="font-weight:700; color:var(--text-main);">#{i + 1} {c.name || `Container #${i + 1}`} &bull; Start Bid: ${(c.startingBid || 5000).toLocaleString()} &bull; Min Increment: ${(c.minBidIncrement || 1000).toLocaleString()} &bull; Duration: {c.auctionDuration || 45}s &bull; Model: <span style="font-family:var(--font-mono); font-size:var(--fs-meta); color:#38bdf8;">{c.model || 'default'}</span></div>
                    <div style="font-size:var(--fs-small); margin-top:2px;">
                      <span style="color:#38bdf8;">📦 Rewards:</span> {formatRewardSummary(c.rewards)}
                    </div>
                  </div>
                {/each}
              </div>
            {/if}
          </div>
          <div class="summary-card" style="grid-column: 1 / -1;">
            <div class="summary-label" style="color:#38bdf8; font-weight:700;">3. Participation &amp; Auction Rules</div>
            <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6;">
              <div><strong>Event Access:</strong> {(form.settings?.eventAccess || 'GANGS') === 'EVERYONE' ? 'Open to Everyone (Gangs & Civilians)' : 'Open to Gangs'}</div>
              <div><strong>Gang Eligibility:</strong> {(form.settings?.allowedGangs?.mode || 'ALL') === 'ALL' ? 'Open to all registered gangs' : `Invite-only (${(form.settings?.allowedGangs?.gangs || []).length} gangs selected)`}</div>
              <div><strong>Capacity Limits:</strong> {form.settings?.maxGangs > 0 ? `${form.settings.maxGangs} gangs max` : 'Unlimited gangs'} &bull; {form.settings?.maxMembersPerGang > 0 ? `${form.settings.maxMembersPerGang} members per gang` : 'Unlimited members per gang'}</div>
              <div><strong>Anti-Snipe Protection:</strong> {form.settings?.antiSnipeBufferSeconds !== 0 ? `Active (${form.settings?.antiSnipeBufferSeconds || 10}s extension buffer)` : 'Disabled'}</div>
            </div>
          </div>
        {:else}
          <div class="summary-card">
            <div class="summary-label">Event Name</div>
            <div class="summary-value">{form.name || '—'}</div>
          </div>
          <div class="summary-card">
            <div class="summary-label">{form.kind === 'GANG_RACE' ? 'Race Stakes / Prizes' : 'Cargo'}</div>
            <div class="summary-value">{form.cargo.type}{form.cargo.description ? ` — ${form.cargo.description}` : ''}</div>
          </div>
          {#if form.kind === 'CONVOY'}
            <div class="summary-card" style="grid-column: 1 / -1;">
              <div class="summary-label" style="color:#4f94e6; font-weight:700;">Truck Cargo Rewards</div>
              <div class="summary-sub" style="font-size:var(--fs-small); color:var(--text-dim); margin-top:6px; line-height:1.6; display:flex; flex-direction:column; gap:6px;">
                {#each form.trucks || [] as t, i}
                  <div style="padding:6px 10px; background:var(--tablet-panel); border-radius:var(--radius-sm); border:1px solid var(--tablet-border);">
                    <div style="font-weight:700; color:var(--text-main);">#{i + 1} {t.label || t.model || 'Truck'} ({t.role || 'PRIMARY_CARGO'})</div>
                    <div style="font-size:var(--fs-small); margin-top:2px;">
                      <span style="color:#4f94e6;">💰 Cargo Reward:</span> {formatRewardSummary(t.reward || t.rewards || form.reward)}
                    </div>
                  </div>
                {/each}
              </div>
            </div>
          {:else if form.kind !== 'GANG_AIRDROP' && form.kind !== 'GANG_RACE'}
            <div class="summary-card">
              <div class="summary-label">Reward</div>
              <div class="summary-value">{formatRewardSummary(form.reward)}</div>
            </div>
          {/if}
          {#if form.kind === 'GANG_RACE'}
            <div class="summary-card">
              <div class="summary-label">Position Rewards</div>
              <div class="summary-value position-rewards-summary">
                <div>🥇 {formatRewardSummary(form.positionRewards.first)}</div>
                <div>🥈 {formatRewardSummary(form.positionRewards.second)}</div>
                <div>🥉 {formatRewardSummary(form.positionRewards.third)}</div>
                <div>🎟️ {formatRewardSummary(form.positionRewards.participation)}</div>
              </div>
            </div>
          {/if}
          {#if form.kind !== 'GANG_RACE'}
            <div class="summary-card">
              <div class="summary-label">Difficulty</div>
              <div class="summary-value">{form.difficulty}</div>
            </div>
          {/if}
          <div class="summary-card">
            <div class="summary-label">Duration</div>
            <div class="summary-value">{Math.round(form.eventDuration / 60)} min</div>
          </div>
          {#if form.kind === 'GANG_AIRDROP'}
            <div class="summary-card">
              <div class="summary-label">Airdrop Zones</div>
              <div class="summary-value">
                {form.settings?.randomizeLocations
                  ? `${Math.min(Number(form.settings?.airdropCount) || form.airdropZones.length, form.airdropZones.length)} of your ${form.airdropZones.length} zones, picked at random each run`
                  : `${form.airdropZones.length} zones`}
                ({form.settings?.airdropPlacement === 'SIMULTANEOUS' ? 'All at once' : (form.settings?.airdropPlacement === 'MANUAL' ? 'Custom timings' : 'Auto-staggered')})
              </div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Participation</div>
              <div class="summary-value">Open to all active gangs</div>
            </div>
          {:else if form.kind === 'GANG_RACE'}
            <div class="summary-card">
              <div class="summary-label">Event Access</div>
              <div class="summary-value">{(form.settings?.eventAccess || 'GANGS') === 'EVERYONE' ? 'Open to Everyone (Gangs & Civilians)' : 'Open to Gangs'}</div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Total Stages / Checkpoints</div>
              <div class="summary-value">{(form.rallyStages || []).length} Checkpoints</div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Vehicle Entry</div>
              <div class="summary-value">Gang / Street Owned Vehicles</div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Police Response</div>
              <div class="summary-value">Pursuit Alert ONLY After Race Conclusion</div>
            </div>
          {:else}
            <div class="summary-card">
              <div class="summary-label">Participant Limits</div>
              <div class="summary-value">{form.maxGangParticipants} gang / {form.maxPoliceParticipants} police</div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Escort Vehicles</div>
              <div class="summary-value">{form.maxEscortVehicles} from shop ped</div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Trucks</div>
              <div class="summary-value">{form.trucks.length}</div>
            </div>
            <div class="summary-card">
              <div class="summary-label">Route Points</div>
              <div class="summary-value">{form.route.length} ({form.checkpoints.filter((c) => !c.supportOnly).length} checkpoints)</div>
            </div>
          {/if}
        {/if}
        {#if form.kind !== 'GANG_RACE' && form.kind !== 'HOT_CARGO' && form.kind !== 'TDM' && form.kind !== 'CONTAINER_WARS' && form.kind !== 'CRACKDOWN'}
          <div class="summary-card">
            <div class="summary-label">Drive-By Shooting</div>
            <div class="summary-value">{form.settings.forceDriveBy ? 'Enabled (All Weapons)' : 'Disabled'}</div>
          </div>
        {/if}
      </div>
    {/if}

    {#if activeTab === 'Review' && !locked && form.kind !== 'GANG_TERRITORY'}
      <div class="launch-section">
        <div class="checklist-title"><Icon name="activity" size={14} /> Launch Options</div>

        <div class="launch-card">
          <div class="launch-card-head">
            <span class="launch-card-title">Schedule</span>
            {#if form.status === 'SCHEDULED'}
              <span class="badge badge-scheduled">{form.recurrence.enabled ? 'Recurring — Scheduled' : 'Scheduled'}</span>
            {:else}
              <span class="badge badge-draft">Not scheduled</span>
            {/if}
          </div>

          {#if form.status === 'SCHEDULED'}
            <div class="launch-row">
              <div class="launch-info">
                {#if form.recurrence.enabled}
                  <span class="v">{scheduleSummary}</span>
                  <span class="hint">Next fires {formatScheduledAt(form.scheduledAt)} — T-minus {formatCountdown(form.scheduledAt, now)}</span>
                {:else}
                  <span class="v">Fires at {formatScheduledAt(form.scheduledAt)} (your local time)</span>
                  <span class="hint">T-minus {formatCountdown(form.scheduledAt, now)}</span>
                {/if}
              </div>
              <button class="btn btn-danger" on:click={unschedule} disabled={scheduling}>{scheduling ? 'Working...' : 'Unschedule'}</button>
            </div>
          {:else}
            <p class="hint">Choose how often this should run — a one-time start, or a recurring cadence that automatically re-arms itself for its next run when the event ends, with no admin action needed.</p>

            <div class="field" style="margin-top:16px">
              <label>Frequency</label>
              <div class="chip-row">
                <button type="button" class="chip-btn" class:active={scheduleFrequency === 'ONCE'} disabled={locked} on:click={() => setScheduleFrequency('ONCE')}>Once (No Repeat)</button>
                <button type="button" class="chip-btn" class:active={scheduleFrequency === 'DAILY'} disabled={locked} on:click={() => setScheduleFrequency('DAILY')}>Daily</button>
                <button type="button" class="chip-btn" class:active={scheduleFrequency === 'WEEKLY'} disabled={locked} on:click={() => setScheduleFrequency('WEEKLY')}>Weekly</button>
                <button type="button" class="chip-btn" class:active={scheduleFrequency === 'MONTHLY'} disabled={locked} on:click={() => setScheduleFrequency('MONTHLY')}>Monthly</button>
                <button type="button" class="chip-btn" class:active={scheduleFrequency === 'YEARLY'} disabled={locked} on:click={() => setScheduleFrequency('YEARLY')}>Yearly</button>
              </div>
            </div>

            {#if scheduleFrequency === 'ONCE'}
              <div class="launch-row" style="margin-top:16px">
                <DateTimePicker bind:value={scheduleInput} min={minScheduleValue} />
                <button class="btn btn-primary" on:click={schedule} disabled={scheduling}>{scheduling ? 'Scheduling...' : 'Schedule'}</button>
              </div>
              <div class="server-clock"><Icon name="dot" size={9} /> Server time now ({offsetLabel()}): <span class="v">{nowDisplay}</span></div>
            {:else}
              {#if form.recurrence.type === 'DAILY'}
                <!-- Daily triggers every day -->
              {:else if form.recurrence.type === 'WEEKLY'}
                <div class="field">
                  <label>Day of Week</label>
                  <select bind:value={form.recurrence.dayOfWeek} disabled={locked}>
                    {#each DAY_NAMES as label, i (i)}<option value={i}>{label}</option>{/each}
                  </select>
                </div>
              {:else if form.recurrence.type === 'MONTHLY'}
                <div class="field">
                  <label>Day of Month <span class="optional">pick from the calendar — capped at 28 so it exists every month</span></label>
                  <DateTimePicker bind:value={monthlyDayScratch} hideTime maxDay={28} />
                </div>
              {:else}
                <div class="field">
                  <label>Date <span class="optional">fires on this month and day every year</span></label>
                  <DateTimePicker bind:value={yearlyDateScratch} hideTime />
                </div>
              {/if}

              <!-- Mode Selection: Exact Time vs Random Window -->
            <div class="field" style="margin-top:16px">
              <label>Timing Mode</label>
              <div class="chip-row">
                <button
                  type="button"
                  class="chip-btn"
                  class:active={form.recurrence.mode === 'EXACT'}
                  disabled={locked}
                  on:click={() => (form.recurrence.mode = 'EXACT')}
                >
                  Exact Time
                </button>
                <button
                  type="button"
                  class="chip-btn"
                  class:active={form.recurrence.mode === 'WINDOW'}
                  disabled={locked}
                  on:click={() => (form.recurrence.mode = 'WINDOW')}
                >
                  🎲 Unpredictable Time Window
                </button>
              </div>
            </div>

            {#if form.recurrence.mode === 'WINDOW'}
              <div class="field-row" style="margin-top:16px">
                <div class="field">
                  <label>Window Start Time</label>
                  <div class="hms-row">
                    <div class="field">
                      <label class="sub">Hour <span class="optional">0-23</span></label>
                      <input type="number" min="0" max="23" bind:value={form.recurrence.windowStartHour} disabled={locked} />
                    </div>
                    <div class="field">
                      <label class="sub">Minute</label>
                      <input type="number" min="0" max="59" bind:value={form.recurrence.windowStartMinute} disabled={locked} />
                    </div>
                  </div>
                </div>
                <div class="field">
                  <label>Window End Time</label>
                  <div class="hms-row">
                    <div class="field">
                      <label class="sub">Hour <span class="optional">0-23</span></label>
                      <input type="number" min="0" max="23" bind:value={form.recurrence.windowEndHour} disabled={locked} />
                    </div>
                    <div class="field">
                      <label class="sub">Minute</label>
                      <input type="number" min="0" max="59" bind:value={form.recurrence.windowEndMinute} disabled={locked} />
                    </div>
                  </div>
                </div>
              </div>
              <div class="unpredictable-note">
                <Icon name="activity" size={13} />
                <span>
                  <strong>Anti-Camping Protection:</strong> The server randomly rolls an unpredictable start time inside this window for every cycle (e.g. 8:17 PM, 9:04 PM). Players only see the active window range, preventing predictable event camping.
                </span>
              </div>
            {:else}
              <div class="hms-row" style="margin-top:16px">
                <div class="field">
                  <label>Hour <span class="optional">0-23</span></label>
                  <input type="number" min="0" max="23" bind:value={form.recurrence.hour} disabled={locked} />
                </div>
                <div class="field">
                  <label>Minute</label>
                  <input type="number" min="0" max="59" bind:value={form.recurrence.minute} disabled={locked} />
                </div>
              </div>
            {/if}

            <p class="hint">Times are in the server's configured schedule offset ({offsetLabel()}) — the same one shown next to "Server time now" above.</p>

            <div class="launch-row" style="margin-top:16px">
              <button class="btn btn-primary" on:click={activateRecurring} disabled={scheduling}>{scheduling ? 'Activating...' : 'Activate Recurring Schedule'}</button>
            </div>
            {/if}
          {/if}
        </div>

      </div>
    {/if}

    {#if error}<div class="error">{error}</div>{/if}

    <div class="actions">
      {#if activeTab !== TABS[0]}
        <button type="button" class="btn btn-back" on:click={prevTab}>
          <Icon name="chevronLeft" size={13} />
          <span>Back</span>
        </button>
      {/if}
      {#if !locked}
        <button class="btn btn-save" class:btn-saved={savedFlash} on:click={save} disabled={saving}>
          <Icon name={savedFlash ? 'check' : 'save'} size={13} />
          <span>{saving ? 'Saving…' : savedFlash ? 'Changes Saved!' : loadedId ? 'Save Changes' : (form.kind === 'CRACKDOWN' ? 'Save Operation Draft' : form.kind === 'HOT_CARGO' ? 'Save Hot Cargo Draft' : (form.kind === 'GANG_AIRDROP' ? 'Save Airdrop Draft' : (form.kind === 'GANG_RACE' ? 'Save Rally Draft' : (form.kind === 'TDM' ? 'Save TDM Draft' : (form.kind === 'CONTAINER_WARS' ? 'Save Container Wars Draft' : (form.kind === 'GANG_TERRITORY' ? 'Save Territory Draft' : 'Save Convoy Draft'))))))}</span>
        </button>
      {/if}
      {#if activeTab !== 'Review'}
        <button type="button" class="btn btn-next" on:click={nextTab} disabled={TABS.indexOf(activeTab) >= TABS.length - 1}>
          <span>Next: {TABS[Math.min(TABS.indexOf(activeTab) + 1, TABS.length - 1)] || 'Next'}</span>
          <Icon name="arrowRight" size={13} />
        </button>
      {/if}
      {#if activeTab === 'Review' && (form.status === 'DRAFT' || form.status === 'SCHEDULED' || !loadedId)}
        <button
          class="btn btn-primary btn-launch"
          on:click={launch}
          disabled={saving || !canStart || (form.kind === 'TDM' && form.tdm?.matchFormat === 'TOURNAMENT')}
          title={(form.kind === 'TDM' && form.tdm?.matchFormat === 'TOURNAMENT') ? 'Tournament arenas are played from the Tournament tab' : (canStart ? '' : 'Fix the checklist above first')}
        >{form.kind === 'CRACKDOWN' ? 'Start Operation →' : form.kind === 'HOT_CARGO' ? 'Start Hot Cargo →' : (form.kind === 'GANG_AIRDROP' ? 'Start Airdrop →' : (form.kind === 'GANG_RACE' ? 'Start Gang Rally →' : (form.kind === 'TDM' ? 'Start TDM Match →' : (form.kind === 'CONTAINER_WARS' ? 'Start Container Wars →' : (form.kind === 'GANG_TERRITORY' ? 'Start Auction Now →' : 'Start Convoy →')))))}</button>
      {/if}
    </div>
  </div>
</div>

<style>
  .position-rewards-summary {
    display: flex;
    flex-direction: column;
    gap: 2px;
    font-size: var(--fs-small);
  }
  .reward-and-position-row {
    display: grid;
    grid-template-columns: 1fr;
    gap: 20px;
    align-items: start;
  }
  .position-rewards-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 12px;
  }
  .position-reward-slot {
    background: var(--tablet-panel-alt, rgba(255, 255, 255, 0.03));
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 4px);
    padding: 10px 12px;
  }
  .position-reward-label {
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-main);
    margin-bottom: 8px;
  }
  .position-reward-label .optional {
    text-transform: none;
    font-weight: 400;
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-left: 4px;
  }
  @media (max-width: 1100px) {
    .reward-and-position-row {
      grid-template-columns: 1fr;
    }
    .position-rewards-grid {
      grid-template-columns: 1fr;
    }
  }

  .draft-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 18px;
    background: var(--lt-111316, #111316);
    border-bottom: 1px solid var(--tablet-border);
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-small);
  }
  .draft-banner span {
    flex: 1;
  }
  .link-btn {
    flex-shrink: 0;
    background: transparent;
    border: none;
    color: var(--accent-primary);
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    font-weight: 600;
    text-decoration: underline;
    cursor: pointer;
    white-space: nowrap;
  }
  .link-btn:hover {
    color: var(--text-main);
  }
  /* Event-type selector: a single compact bar, one accent colour per event type */
  .mode-tabs {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
    gap: 10px;
    padding: 12px 20px;
    background: var(--doctrine-bar-bg);
    border-bottom: 1px solid var(--tablet-border);
  }
  .mode-tab {
    --k: var(--accent-primary);
    position: relative;
    overflow: hidden;
    display: flex;
    align-items: center;
    justify-content: flex-start;
    gap: 12px;
    height: 56px;
    padding: 0 16px;
    background: var(--doctrine-card-bg);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }
  .mode-tab:hover:not(:disabled) {
    background: var(--doctrine-card-hover);
    border-color: color-mix(in srgb, var(--k) 60%, transparent);
    color: var(--lt-ffffff, #fff);
  }
  .mode-tab.active {
    background: color-mix(in srgb, var(--k) 16%, var(--c-base, #131518));
    border-color: var(--k);
    color: var(--lt-ffffff, #fff);
  }
  .mode-tab.active::after {
    content: '';
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 3px;
    background: var(--k);
  }
  .mode-tab:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
  .mode-icon {
    flex: 0 0 auto;
    width: 34px;
    height: 34px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--r-tag);
    background: color-mix(in srgb, var(--k) 18%, var(--c-panel, #181b1f));
    border: 1px solid color-mix(in srgb, var(--k) 45%, transparent);
    color: color-mix(in srgb, var(--k) 70%, var(--lt-ffffff, #fff));
  }
  .mode-tab.active .mode-icon {
    background: var(--k);
    border-color: var(--k);
    color: var(--lt-ffffff, #fff);
  }
  /* the full name always shows: a long one (Container Wars, Territory Auction) wraps to two lines instead of being cut */
  .mode-tab-title {
    min-width: 0;
    font-size: var(--fs-emph);
    font-weight: 700;
    letter-spacing: 0.01em;
    line-height: 1.15;
    white-space: normal;
    overflow-wrap: anywhere;
  }
  /* Numbered steps bar */
  .tabs {
    display: flex;
    height: 58px;
    border-bottom: 1px solid var(--tablet-border);
    background: var(--steps-bg);
    overflow-x: auto;
  }
  .tab {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 9px;
    min-width: 150px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
    border: none;
    border-right: 1px solid var(--tablet-border);
    color: var(--text-dim);
    font-weight: 600;
    font-size: var(--fs-emph);
    letter-spacing: 0.01em;
    padding: 0 26px;
    white-space: nowrap;
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }
  .tab:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    color: var(--lt-ffffff, #ffffff);
  }
  .tab.active {
    background: var(--c-raised, #1f2328);
    color: var(--lt-ffffff, #ffffff);
  }
  .tab.active::after {
    content: '';
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 4px;
    background: var(--accent-primary);
    box-shadow: none;
    color: var(--on-accent, inherit);
}
  .tab-step {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.35);
    color: var(--lt-ffffff, #fff);
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .tab.active .tab-step {
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    background: var(--accent-primary);
    font-weight: 700;
  }
  .toggle-group {
    margin-top: 6px;
    border-top: 1px solid rgba(var(--accent-primary-rgb), 0.1);
  }
  .summary-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
  }
  .summary-card {
    padding: 10px 14px;
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
  }
  .summary-label {
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    margin-bottom: 10px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
  }
  .summary-value {
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--text-main);
  }
  .error {
    color: var(--tablet-danger);
    font-size: var(--fs-body);
    margin-top: 10px;
  }
  .lock-notice {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 16px;
    padding: 10px 14px;
    border-radius: var(--radius-sm);
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--yellow);
    font-size: var(--fs-body);
    border-left: 3px solid #f59e0b;}
  .lock-notice strong {
    color: var(--text-main);
  }
  .launch-section {
    margin-top: 18px;
  }
  .launch-card {
    padding: 20px 22px;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
    margin-bottom: 14px;
  }
  .launch-card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin: -20px -22px 16px;
    padding: 10px 22px;
    background: var(--topbar-bg, #15171b);
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--radius-md) var(--radius-md) 0 0;
  }
  .launch-card-title {
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main);
  }
  .hint {
    display: block;
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 0 0 14px;
  }
  .launch-row {
    display: flex;
    align-items: center;
    gap: 14px;
    flex-wrap: wrap;
  }
  .launch-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .launch-row .v {
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    color: var(--text-main);
  }
  .server-clock {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 16px;
    padding-top: 14px;
    border-top: 1px solid var(--tablet-border);
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .server-clock .v {
    font-family: var(--font-mono);
    color: var(--text-main);
  }
  .actions {
    margin-top: 18px;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 14px;
    flex-wrap: wrap;
  }
  .saved-flash {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--tablet-success);
    animation: fadeIn 0.15s ease-out both;
  }
  .btn-saved {
    background: rgba(70, 200, 120, 0.15) !important;
    border-color: var(--tablet-success, #46c878) !important;
    color: var(--tablet-success, #46c878) !important;
    transition: background 0.2s, border-color 0.2s, color 0.2s;
  }
  @keyframes fadeIn {
    from { opacity: 0; transform: translateY(2px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .field-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: -3px 0 8px;
  }
  .field label .optional {
    text-transform: none;
    font-weight: 400;
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-left: 4px;
  }
  .delay-mode-row {
    display: flex;
    gap: 18px;
    margin-bottom: 10px;
  }
  .radio-inline {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-body);
    font-weight: 500;
    color: var(--text-main);
    text-transform: none;
    cursor: pointer;
  }
  .radio-inline input[type='radio'] {
    accent-color: var(--accent-primary);
    width: 14px;
    height: 14px;
  }
  .hms-row {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }
  .hms-row .field {
    margin-bottom: 0;
  }
  .checklist {
    margin-bottom: 16px;
    padding: 14px 16px;
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
  }
  .roster-block {
    margin-top: 10px;
  }
  .roster-block-label {
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim);
    margin-bottom: 6px;
  }
  .roster-empty {
    font-size: var(--fs-small);
    color: var(--text-dim);
    font-style: italic;
  }
  .roster-chip-list {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .roster-chip {
    padding: 3px 9px;
    border-radius: 999px;
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border-strong);
    font-size: var(--fs-meta);
    color: var(--text-main);
  }
  .roster-gang-row {
    margin-bottom: 8px;
  }
  .roster-gang-name {
    display: block;
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff);
    margin-bottom: 4px;
  }
  .tdm-general-hint {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 14px;
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-small);
  }
  .ped-slot { display: flex; flex-direction: column; gap: 10px; }
  .ped-note { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 10px 14px; border: 1px solid var(--c-line); border-radius: var(--r-panel); background: var(--c-raised); color: var(--lt-e8d3a3, #e8d3a3); font-size: var(--fs-meta); line-height: 1.5;
    border-left: 3px solid rgb(240, 195, 109);}
  .ped-note span { flex: 1; min-width: 240px; }
  .ped-note b { color: var(--lt-ffffff, #fff); }
  .checklist-title {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: -14px -16px 12px;
    padding: 9px 16px;
    background: var(--topbar-bg, #15171b);
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--radius-md) var(--radius-md) 0 0;
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main);
  }
  .check-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 0;
    font-size: var(--fs-body);
    color: var(--tablet-danger);
  }
  .check-row.ok {
    color: var(--tablet-success);
  }
  .chip-row {
    display: flex;
    gap: 8px;
    margin-top: 6px;
    flex-wrap: wrap;
  }
  .gang-picker-list {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 10px;
  }
  .gang-picker-item {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border-strong);
    color: var(--text-main);
    font-size: var(--fs-small);
    font-weight: 500;
    cursor: pointer;
  }
  .gang-picker-item input[type='checkbox'] {
    accent-color: var(--accent-primary);
    width: 14px;
    height: 14px;
    cursor: pointer;
  }
  .gang-picker-empty {
    margin-top: 10px;
    padding: 12px;
    text-align: center;
    color: var(--text-dim);
    font-size: var(--fs-small);
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
  }
  .chip-btn {
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border-strong);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
  }
  .chip-btn:hover:not(:disabled) {
    border-color: var(--accent-primary);
    color: var(--text-main);
  }
  .chip-btn.active:hover:not(:disabled),
  .chip-btn.active {
    background: var(--c-raised, #1f2328);
    border-color: var(--accent-primary);
    color: var(--lt-ffffff, #ffffff);
    font-weight: 600;
  }
  .unpredictable-note {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    margin-top: 10px;
    padding: 10px 12px;
    border-radius: var(--radius-sm, 4px);
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--lt-ffc857, #ffc857);
    font-size: var(--fs-small);
    line-height: 1.45;
    border-left: 3px solid rgb(255, 200, 87);}

  /* ── Custom Slate Gradient Background for Create Event Form ── */
  .create-convoy-panel {
    --card-bg: rgba(20, 26, 36, 0.45);
    --tablet-panel: rgba(20, 26, 36, 0.5);
    --tablet-panel-alt: rgba(14, 19, 27, 0.5);
    --doctrine-bar-bg: rgba(12, 16, 23, 0.7);
    --doctrine-card-bg: rgba(18, 24, 34, 0.6);
    --doctrine-card-hover: rgba(28, 38, 54, 0.75);
    --steps-bg: rgba(10, 14, 21, 0.65);
    --input-bg: rgba(11, 15, 22, 0.7);
    --input-bg-hover: rgba(16, 22, 32, 0.8);
    --input-bg-focus: rgba(18, 26, 38, 0.9);
    --input-border: rgba(110, 140, 180, 0.22);
    --input-border-hover: rgba(140, 175, 220, 0.38);
    --tablet-border: rgba(110, 140, 180, 0.16);
    --tablet-border-strong: rgba(130, 165, 210, 0.26);
    background: transparent;
    border: 1px solid rgba(85, 118, 160, 0.22);
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.4);
    position: relative;
  }

  .create-convoy-panel :global(.panel-header),
  .create-convoy-panel > .panel-header {
    background: rgba(var(--ltc-11-15-22, 11, 15, 22), 0.75);
    border-bottom: 1px solid rgba(110, 140, 180, 0.2);
  }

  .create-convoy-panel :global(.mode-tabs),
  .create-convoy-panel > .mode-tabs {
    background: rgba(var(--ltc-11-15-22, 11, 15, 22), 0.68);
    border-bottom: 1px solid rgba(110, 140, 180, 0.16);
  }

  .create-convoy-panel :global(.tabs),
  .create-convoy-panel > .tabs {
    background: rgba(var(--ltc-9-13-19, 9, 13, 19), 0.62);
    border-bottom: 1px solid rgba(110, 140, 180, 0.16);
  }

  .create-convoy-panel :global(.panel-body),
  .create-convoy-panel > .panel-body {
    background: transparent;
  }
</style>
