<script>
  // Gang Territory Auction event configuration (Create Event → "Gang Territory Auction"):
  //   section="setup"   Auction Setup — event details, recurring scheduling, gangs, polygon auction perimeter, announcements
  //   section="areas"   Lots & Bidding — sub-tabs: Territories (the list, leader peds, blips, war defense) · Projectors · Bidding & Anti-snipe (rules + XP calculator)
  //   section="review"  Review        — checklist, territory list, save draft & publish event
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import { bootstrap, zoneRecordingResult } from '../../stores.js';
  import { getPlayerPosition, teleportToPosition, previewProjectorScreen, drawContainerWarsPerimeter, previewContainerWarsZone } from '../../api/route.js';
  import { getServerTime } from '../../api/convoy.js';
  import { openPropPlacer } from '../../api/placer.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import SubTabs from '../ui/SubTabs.svelte';
  import DateTimePicker from '../ui/DateTimePicker.svelte';
  import FormSectionHead from '../ui/FormSectionHead.svelte';
  import GangSelector from '../ui/GangSelector.svelte';
  import TerritoryAreaCard from '../ui/TerritoryAreaCard.svelte';
  import { money, territoryReadiness, gangIndex } from '../../territory/territoryRender.js';
  import { countSpans, slug } from '../../territory/territoryGeometry.js';
  import '../tablet-theme.css';

  export let section = 'setup';
  export let form;
  export let locked = false;
  export let availableGangs = [];
  export let loadedId = null;

  const dispatch = createEventDispatcher();

  $: cfg = $bootstrap?.territory || {};
  $: auctionDefaults = cfg.auction?.defaults || {};
  $: projectorModel = cfg.auction?.projectorModel || 'prop_runlight_g';

  // ── Random Gang Leader Ped Pool ─────────────────────────────────────────────
  const GANG_LEADER_PEDS = [
    'g_m_y_mexgoon_01', 'g_m_y_mexgoon_02', 'g_m_y_mexgoon_03',
    'g_m_y_ballaorig_01', 'g_m_y_ballaeast_01', 'g_m_y_famca_01',
    'g_m_y_famdnf_01', 'g_m_y_salvagoon_01', 'g_m_y_salvagoon_02',
    'g_m_y_korlieut_01', 'g_m_y_strpunk_01', 'csb_vagosfun',
    'g_m_m_chigoon_01', 'g_m_m_chigoon_02', 'g_m_y_azteca_01',
    'ig_claypain', 'ig_ortega', 'g_m_y_lost_01', 'g_m_y_lost_02',
  ];
  function getRandomGangPed() {
    return GANG_LEADER_PEDS[Math.floor(Math.random() * GANG_LEADER_PEDS.length)];
  }

  // ── make sure the form has every field this screen reads ────────────────────
  function ensure() {
    if (!form) return;
    if (!form.territory || typeof form.territory !== 'object') form.territory = {};
    const t = form.territory;
    if (!t.auction) t.auction = {};
    const a = t.auction;
    const fill = (k, v) => { if (a[k] === undefined) a[k] = v; };
    fill('date', ''); fill('startTime', '');
    fill('lotSeconds', auctionDefaults.lotSeconds ?? 90);
    fill('lotGapSeconds', auctionDefaults.lotGapSeconds ?? 20);
    fill('introSeconds', auctionDefaults.introSeconds ?? 30);
    fill('startingBid', auctionDefaults.startingBid ?? 100000);
    fill('minBidIncrement', auctionDefaults.minBidIncrement ?? 10000);
    fill('antiSnipeEnabled', cfg.auction?.antiSnipe?.enabled !== false);
    fill('antiSnipeWindowSeconds', cfg.auction?.antiSnipe?.triggerSeconds ?? 10);
    fill('antiSnipeExtendSeconds', cfg.auction?.antiSnipe?.extendSeconds ?? 15);
    fill('zoneRadius', cfg.auction?.zoneRadius ?? 12);
    fill('location', null); fill('projector', null);
    if (!a.zone) a.zone = { points: [] };
    if (!a.zonePoints) a.zonePoints = [];
    if (!a.announce) a.announce = { preEvent: true, start: true, lots: true, result: true, ended: true };
    if (!Array.isArray(t.areas)) t.areas = [];
    for (const ar of t.areas) {
      if (!ar.base) ar.base = { cs: cfg.cellSize || 25, spans: [] };
      if (!ar.capture) {
        ar.capture = {
          enabled: true,
          ped: { model: getRandomGangPed(), x: null, y: null, z: null, heading: 0 },
          seconds: 60,
          radius: 15,
          interactDistance: 2.5,
          contestRule: 'PAUSE',
        };
      }
      // Capture and War are ALWAYS enabled by default (toggle removed)
      ar.capture.enabled = true;
      if (!ar.capture.ped) ar.capture.ped = { model: getRandomGangPed(), x: null, y: null, z: null, heading: 0 };
      if (!ar.capture.ped.model) ar.capture.ped.model = getRandomGangPed();
      if (!ar.capture.seconds) ar.capture.seconds = 60;
      if (!ar.capture.radius) ar.capture.radius = 15;
      if (!ar.capture.interactDistance) ar.capture.interactDistance = 2.5;
      if (!ar.capture.contestRule) ar.capture.contestRule = 'PAUSE';

      // Leader Ped acts as the map sprite blip & primary reference anchor
      if (ar.capture.ped.x != null && (!ar.location || ar.location.x == null)) {
        ar.location = { x: ar.capture.ped.x, y: ar.capture.ped.y, z: ar.capture.ped.z };
      } else if (ar.location && ar.location.x != null && ar.capture.ped.x == null) {
        ar.capture.ped.x = ar.location.x;
        ar.capture.ped.y = ar.location.y;
        ar.capture.ped.z = ar.location.z;
      }

      if (!ar.blip) ar.blip = { enabled: true, sprite: 310, scale: 0.85 };
      ar.blip.enabled = true;
      if (!ar.blip.sprite) ar.blip.sprite = 310;
      if (!ar.blip.scale) ar.blip.scale = 0.85;

      if (ar.spriteType === undefined) ar.spriteType = 'GTA_SPRITE';
      if (ar.customLogo === undefined) ar.customLogo = '';
      if (!ar.color) ar.color = '#c45ee0';
      if (ar.auctioned === undefined) ar.auctioned = true;
      if (ar.startingBid === undefined) ar.startingBid = a.startingBid ?? 100000;
      if (ar.minBidIncrement === undefined) ar.minBidIncrement = a.minBidIncrement ?? 10000;
      if (!Array.isArray(ar.props)) ar.props = [];
    }
    if (!form.settings) form.settings = {};
    if (!form.settings.allowedGangs) form.settings.allowedGangs = { mode: 'ALL', gangs: [] };
    if (form.settings.announcements === undefined) form.settings.announcements = true;
    form.settings.eventAccess = 'GANGS';

    // Standardized recurrence format matching other events
    if (!form.recurrence || typeof form.recurrence !== 'object') {
      form.recurrence = {
        enabled: false,
        type: 'ONCE',
        mode: 'EXACT',
        dayOfWeek: 5,
        dayOfMonth: 1,
        month: 1,
        hour: 18,
        minute: 0,
        windowStartHour: 18,
        windowStartMinute: 0,
        windowEndHour: 21,
        windowEndMinute: 0,
      };
    }
    form.territory = t;
  }
  $: if (form && cfg) ensure();

  $: a = form?.territory?.auction || {};
  $: areas = form?.territory?.areas || [];

  function touchTerritory() { form.territory = form.territory; }

  // ── Scheduling & Recurrence ─────────────────────────────────────────────────
  const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const pad = (n) => String(n).padStart(2, '0');
  const to12Hour = (d) => {
    let h = d.getUTCHours();
    const m = pad(d.getUTCMinutes());
    const ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return `${h}:${m} ${ampm}`;
  };
  const toInputValue = (d) => `${pad(d.getUTCFullYear())}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
  const offsetLabel = () => {
    const o = $bootstrap?.scheduleUtcOffsetHours ?? 0;
    if (o === 0) return 'UTC';
    return `UTC${o > 0 ? '+' : ''}${o}`;
  };

  let clockSkewMs = 0;
  let now = new Date();
  let nowTimer = null;
  onMount(async () => {
    try {
      const res = await getServerTime();
      if (res && res.ok && res.utc) {
        clockSkewMs = res.utc * 1000 - Date.now();
      }
    } catch (e) {}
    now = new Date(Date.now() + clockSkewMs);
    nowTimer = setInterval(() => { now = new Date(Date.now() + clockSkewMs); }, 1000);
  });
  onDestroy(() => { if (nowTimer) clearInterval(nowTimer); });

  $: offsetNow = new Date(now.getTime() + (($bootstrap?.scheduleUtcOffsetHours ?? 0) * 3600000));
  $: minScheduleValue = toInputValue(offsetNow);
  $: nowDisplay = `${pad(offsetNow.getUTCFullYear())}-${pad(offsetNow.getUTCMonth() + 1)}-${pad(offsetNow.getUTCDate())}  ${to12Hour(offsetNow)}`;

  let scheduleFrequency = 'ONCE';
  let scheduleInput = '';
  let monthlyDayScratch = '';
  let yearlyDateScratch = '';
  let schedSeeded = false;

  $: if (!schedSeeded && form) {
    if (form.recurrence && form.recurrence.enabled) {
      scheduleFrequency = form.recurrence.type || 'DAILY';
      seedRecurrenceScratch();
    } else {
      scheduleFrequency = 'ONCE';
      const base = form.scheduledStartTime || (a.date && a.startTime ? `${a.date}T${a.startTime}` : '');
      scheduleInput = base || toInputValue(offsetNow);
    }
    schedSeeded = true;
  }

  function setScheduleFrequency(freq) {
    scheduleFrequency = freq;
    if (freq === 'ONCE') {
      form.recurrence.enabled = false;
      if (!scheduleInput) scheduleInput = toInputValue(offsetNow);
      syncOnceSchedule(scheduleInput);
    } else {
      form.recurrence.enabled = true;
      form.recurrence.type = freq;
      seedRecurrenceScratch();
    }
    touchTerritory();
  }

  function seedRecurrenceScratch() {
    const d = Math.max(1, Math.min(28, Number(form.recurrence?.dayOfMonth) || 1));
    const m = Math.max(1, Math.min(12, Number(form.recurrence?.month) || 1));
    monthlyDayScratch = `2024-01-${pad(d)}T00:00`;
    yearlyDateScratch = `2024-${pad(m)}-${pad(d)}T00:00`;
  }

  function syncMonthlyDay(v) {
    const m = /^\d{4}-\d{2}-(\d{2})T/.exec(v || '');
    if (m && form?.recurrence) {
      form.recurrence.dayOfMonth = Math.min(28, Math.max(1, parseInt(m[1], 10)));
    }
  }
  $: syncMonthlyDay(monthlyDayScratch);

  function syncYearlyDate(v) {
    const m = /^\d{4}-(\d{2})-(\d{2})T/.exec(v || '');
    if (m && form?.recurrence) {
      form.recurrence.month = Math.min(12, Math.max(1, parseInt(m[1], 10)));
      form.recurrence.dayOfMonth = Math.min(28, Math.max(1, parseInt(m[2], 10)));
    }
  }
  $: syncYearlyDate(yearlyDateScratch);

  function syncOnceSchedule(v) {
    if (!v) return;
    form.scheduledStartTime = v;
    const parts = v.split('T');
    if (parts.length === 2 && form?.territory?.auction) {
      form.territory.auction.date = parts[0];
      form.territory.auction.startTime = parts[1];
    }
  }
  $: syncOnceSchedule(scheduleInput);

  // Auction Duration in minutes
  let durationMin = 30;
  let durationSeeded = false;
  $: if (!durationSeeded && form) {
    durationMin = Math.max(0, Math.round((Number(form.eventDuration) || (auctionDefaults.eventMinutes || 30) * 60) / 60));
    durationSeeded = true;
  }
  function syncDuration(min) {
    const s = (Number(min) || 0) <= 0 ? 0 : Math.min(120, Number(min)) * 60;   // 0 = the default length (server side)
    if (durationSeeded && form && form.eventDuration !== s) form.eventDuration = s;
  }
  $: syncDuration(durationMin);

  $: scheduleSummary = (() => {
    if (scheduleFrequency === 'ONCE') {
      return scheduleInput ? `Once at ${scheduleInput.replace('T', ' ')}` : 'One-time (not scheduled)';
    }
    const r = form?.recurrence;
    if (!r) return 'Not scheduled';
    const timeStr = r.mode === 'WINDOW'
      ? `between ${pad(r.windowStartHour)}:${pad(r.windowStartMinute)} and ${pad(r.windowEndHour)}:${pad(r.windowEndMinute)}`
      : `at ${pad(r.hour)}:${pad(r.minute)}`;
    if (r.type === 'DAILY') return `Daily ${timeStr}`;
    if (r.type === 'WEEKLY') return `Weekly on ${DAY_NAMES[r.dayOfWeek] || 'day'} ${timeStr}`;
    if (r.type === 'MONTHLY') return `Monthly on day ${r.dayOfMonth} ${timeStr}`;
    if (r.type === 'YEARLY') return `Yearly on month ${r.month}, day ${r.dayOfMonth} ${timeStr}`;
    return 'Recurring';
  })();

  // ── Participating Gangs ─────────────────────────────────────────────────────
  $: gangsMode = form?.settings?.allowedGangs?.mode || 'ALL';

  // ── Auction Zone (Container Wars Polygon Perimeter System) ─────────────────
  $: zonePoints = a.zone?.points || a.zonePoints || [];
  $: zoneReady = zonePoints.length >= 3;
  $: zoneStats = (() => {
    if (!zoneReady) return null;
    let areaVal = 0;
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (let i = 0; i < zonePoints.length; i++) {
      const p = zonePoints[i];
      const q = zonePoints[(i + 1) % zonePoints.length];
      areaVal += p.x * q.y - q.x * p.y;
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    return { area: Math.round(Math.abs(areaVal) / 2), w: Math.round(maxX - minX), h: Math.round(maxY - minY) };
  })();

  let isRecordingZone = false;
  let busyZone = false;

  async function recordZone() {
    if (locked) return;
    isRecordingZone = true;
    try {
      await drawContainerWarsPerimeter({ target: 'TERRITORY' });
    } finally {
      isRecordingZone = false;
    }
  }

  function clearZone() {
    if (locked) return;
    form.territory.auction.zone = { points: [] };
    form.territory.auction.zonePoints = [];
    touchTerritory();
  }

  async function previewZone(teleport) {
    if (zonePoints.length < 3 || busyZone) return;
    busyZone = true;
    const fallbackZ = zonePoints[0]?.z ?? 20.0;
    if (teleport) {
      const p = zonePoints[0];
      await teleportToPosition(p.x, p.y, (p.z && Math.abs(p.z) > 0.01) ? p.z : fallbackZ);
    }
    await previewContainerWarsZone(zonePoints, fallbackZ);
    busyZone = false;
  }

  $: if ($zoneRecordingResult && $zoneRecordingResult.points && $zoneRecordingResult.points.length >= 3) {
    if ($zoneRecordingResult.target === 'TERRITORY' || isRecordingZone) {
      const pts = $zoneRecordingResult.points;
      form.territory.auction.zone = { points: pts };
      form.territory.auction.zonePoints = pts;
      let cx = 0, cy = 0, cz = 0;
      for (const p of pts) { cx += p.x; cy += p.y; cz += (p.z || 0); }
      form.territory.auction.location = { x: cx / pts.length, y: cy / pts.length, z: cz / pts.length };
      touchTerritory();
      isRecordingZone = false;
      zoneRecordingResult.set(null);
    }
  }

  // ── Lots & Bidding sub-tabs (Territories · Projectors · Bidding & Anti-snipe) ──────────────────────────
  let areasSubTab = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_territory_areas_sub')) || 'territories';
  $: if (typeof localStorage !== 'undefined') localStorage.setItem('nova_convoy_last_territory_areas_sub', areasSubTab);

  let openId = null;
  $: if (section === 'areas' && openId === null && areas.length === 1) openId = areas[0].id;

  // ── Territory Management & Random Gang Leader Assignment ─────────────────────
  function addArea() {
    const n = areas.length + 1;
    const randomPed = getRandomGangPed();
    const ar = {
      id: `territory_${n}`,
      name: `Territory ${n}`,
      description: '',
      color: '#c45ee0',
      startingOwner: '',
      order: n,
      xpValue: 500,
      auctioned: true,
      startingBid: a.startingBid ?? 100000,
      minBidIncrement: a.minBidIncrement ?? 10000,
      spriteType: 'GTA_SPRITE',
      customLogo: '',
      blip: { enabled: true, sprite: 310, scale: 0.85 },
      capture: {
        enabled: true,
        ped: { model: randomPed, x: null, y: null, z: null, heading: 0 },
        seconds: 60,
        radius: 15,
        interactDistance: 2.5,
        contestRule: 'PAUSE',
      },
      location: null,
      base: { cs: cfg.cellSize || 25, spans: [] },
    };
    while (areas.some((x) => x.id === ar.id)) ar.id = `${ar.id}_${Math.random().toString(36).slice(2, 5)}`;
    form.territory.areas = [...areas, ar];
  }

  async function removeArea(i) {
    const ar = areas[i];
    const ok = await confirmAction(`Remove "${ar.name}" from this auction event?`, { title: 'Remove territory', danger: true, confirmLabel: 'Remove' });
    if (!ok) return;
    form.territory.areas = areas.filter((_, k) => k !== i);
  }

  function moveArea(i, d) {
    const j = i + d;
    if (j < 0 || j >= areas.length) return;
    const list = [...areas];
    [list[i], list[j]] = [list[j], list[i]];
    list.forEach((x, k) => (x.order = k + 1));
    form.territory.areas = list;
  }

  function renameId(ar) { ar.id = slug(ar.id) || ar.id; touchTerritory(); }

  // ── Projector Placement ─────────────────────────────────────────────────────
  let projBusy = false;
  let projNote = '';
  // "Edit Projector" and "Preview In-World" both open the Prop Placer window on the projector. A preview opens on the placed
  // projector so you can fly around it; on a locked event nothing it changes is kept.
  async function placeProjector(preview = false) {
    if (projBusy || (locked && !preview)) return;
    projBusy = true; projNote = '';
    const cur = a.projector;
    const hasCur = !!(cur && cur.x != null);
    let res = null;
    try {
      res = await openPropPlacer({
        context: 'territory_projector', title: preview ? 'Auction projector — preview' : 'Auction projector',
        objects: hasCur ? [cur] : [],
        autoCreate: hasCur ? undefined : { model: projectorModel, fallbacks: cfg.auction?.projectorModelFallbacks || [] },
        selectIndex: hasCur ? 1 : undefined,
        // nothing placed: no anchor, so the camera (and the new projector) start where the player stands
        focus: hasCur ? { x: cur.x, y: cur.y, z: cur.z } : undefined,
      });
    } catch (e) { res = null; }
    projBusy = false;
    if (locked) return;
    if (res && res.ok && Array.isArray(res.objects)) {
      const o = res.objects[0];
      if (o) {
        form.territory.auction.projector = {
          model: projectorModel, kind: 'object', x: o.x, y: o.y, z: o.z, heading: o.heading ?? 0, rx: o.rx, ry: o.ry,
          uid: o.uid || cur?.uid || `projector_${loadedId || 'new'}`, eventId: loadedId || null, territoryId: cur?.territoryId || '',
          screenScale: cur?.screenScale ?? 1,
        };
        projNote = 'Projector placement saved in event configuration.';
      } else {
        form.territory.auction.projector = null;
        projNote = 'Projector placement removed.';
      }
      touchTerritory();
    } else if (res && res.error === 'busy') projNote = 'The Prop Placer is already open.';
    else if (res && res.error) projNote = 'The placer stopped on an error — nothing was changed.';
  }

  // "Set My Position": the projector goes where the admin stands, facing the way they face. The ped's coordinates are
  // about a metre above the ground, so the prop is dropped that far; "Edit Projector" fine-tunes it afterwards.
  async function setProjectorHere() {
    if (locked || projBusy) return;
    projBusy = true; projNote = '';
    let pos = null;
    try { pos = await getPlayerPosition(); } catch (e) { pos = null; }
    projBusy = false;
    if (!pos || pos.x == null) { projNote = 'The game did not answer — is the resource running?'; return; }
    const cur = a.projector;
    form.territory.auction.projector = {
      model: projectorModel, kind: 'object',
      x: Number(Number(pos.x).toFixed(2)), y: Number(Number(pos.y).toFixed(2)), z: Number((Number(pos.z) - 1.0).toFixed(2)),
      heading: Number(Number(pos.heading || 0).toFixed(1)), rx: 0, ry: 0,
      uid: cur?.uid || `projector_${loadedId || 'new'}`, eventId: loadedId || null, territoryId: cur?.territoryId || '',
      screenScale: cur?.screenScale ?? 1,
    };
    projNote = 'Projector set to your position. Use Edit Projector to fine-tune it.';
    touchTerritory();
  }

  // Teleport to the projector, or - before one is placed - to the auction area so you can stand where it should go.
  function teleportToProjector() {
    const p = a.projector && a.projector.x != null ? a.projector : (a.location && a.location.x != null ? a.location : null);
    if (!p) { projNote = 'Nothing to teleport to yet — place the projector or record the auction zone first.'; return; }
    teleportToPosition(p.x, p.y, p.z, p.heading || 0);
  }

  // ── Screen size: how big the auction board is drawn over the projector (saved with the event, shown when bidding starts) ──
  $: scr = cfg.auction?.screen || {};
  $: scrMin = Number(scr.minScale) || 0.4;
  $: scrMax = Number(scr.maxScale) || 3.0;
  $: scrBaseW = Number(scr.width) || 6.4;
  $: scrBaseH = Number(scr.height) || 3.6;
  $: scale = Math.min(scrMax, Math.max(scrMin, Number(a.projector?.screenScale) || 1));
  $: boardW = scrBaseW * scale;
  $: boardH = scrBaseH * scale;
  // the to-scale picture: the board next to a 1.8 m person, one metre = ppm pixels
  const PIC_W = 420, PIC_H = 170;
  $: scrLift = Number(scr.lift) || 3;
  $: ppm = Math.min((PIC_W - 70) / Math.max(boardW, 1), (PIC_H - 24) / Math.max(boardH + scrLift, 1.8));
  $: boardY = PIC_H - 12 - (scrLift + boardH) * ppm;
  function setScale(v) {
    if (locked || !a.projector) return;
    form.territory.auction.projector.screenScale = Math.round(Math.min(scrMax, Math.max(scrMin, Number(v) || 1)) * 20) / 20;
    touchTerritory();
  }
  async function previewScreenSize() {
    const p = a.projector;
    if (!p || p.x == null) return;
    projNote = 'The tablet steps aside and the board is drawn in the world for about 25 seconds: stand near the projector (Teleport button) to see it. Press ENTER to come back to the tablet.';
    await previewProjectorScreen(p.x, p.y, p.z, scale);
  }

  function clearProjector() {
    form.territory.auction.projector = null;
    touchTerritory();
  }

  // ── Review ───────────────────────────────────────────────────────────────────
  $: readiness = territoryReadiness(form || {});
  $: allReady = readiness.every((r) => r.ok);
  $: gangLabelOf = (n) => (availableGangs.find((g) => g.name === n) || {}).label || n;
  $: participating = gangsMode === 'SELECTED' ? (form?.settings?.allowedGangs?.gangs || []).map(gangLabelOf) : ['All gangs'];
  $: startsText = scheduleSummary;
  $: ownerOf = (id) => gangLabelOf(id) || '—';
</script>

<!-- ═══════════════════════════ 1. AUCTION SETUP ═══════════════════════════ -->
{#if section === 'setup'}
  <FormSectionHead title="Event Details" />
  <div class="field">
    <label>Event Name</label>
    <input type="text" bind:value={form.name} maxlength="100" placeholder="e.g. Los Santos Gang Territory Auction" disabled={locked} />
  </div>
  <div class="field">
    <label>Description</label>
    <input type="text" bind:value={form.shortDescription} maxlength="255" placeholder="One line shown in event lists" disabled={locked} />
  </div>
  <div class="field">
    <label>Detailed Briefing <span class="optional">rules and what is at stake</span></label>
    <textarea bind:value={form.detailedDescription} maxlength="4000" placeholder="Full briefing for the gangs" disabled={locked}></textarea>
  </div>

  <FormSectionHead title="Schedule & Recurrence" hint="Choose a one-time start or recurring cadence that re-arms automatically" />
  <div class="field">
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
    <div class="field-row" style="margin-top:12px; align-items: flex-start;">
      <div class="field" style="flex: 1 1 320px; max-width: 380px;">
        <label>Auction Start Date &amp; Time</label>
        <DateTimePicker bind:value={scheduleInput} min={minScheduleValue} />
        <div class="server-clock" style="margin-top:6px"><Icon name="dot" size={9} /> Server time now ({offsetLabel()}): <span class="v">{nowDisplay}</span></div>
      </div>
      <div class="field" style="flex: 1 1 240px; max-width: 280px;">
        <label>Auction Duration <span class="optional">minutes</span></label>
        <input type="number" min="0" max="120" bind:value={durationMin} disabled={locked} />
        <span class="hint" style="margin-top: 4px; display: block;">Total window for bidding across all territories. 0 = the default length. Players see an "Auction ends in" timer for it.</span>
      </div>
    </div>
  {:else}
    <div class="field-row" style="margin-top:12px; align-items: flex-start;">
      {#if form.recurrence.type === 'WEEKLY'}
        <div class="field" style="flex: 1 1 200px;">
          <label>Day of Week</label>
          <select bind:value={form.recurrence.dayOfWeek} disabled={locked}>
            {#each DAY_NAMES as label, i (i)}<option value={i}>{label}</option>{/each}
          </select>
        </div>
      {:else if form.recurrence.type === 'MONTHLY'}
        <div class="field" style="flex: 1 1 200px;">
          <label>Day of Month <span class="optional">max 28 so it exists in every month</span></label>
          <DateTimePicker bind:value={monthlyDayScratch} hideTime maxDay={28} />
        </div>
      {:else if form.recurrence.type === 'YEARLY'}
        <div class="field" style="flex: 1 1 200px;">
          <label>Date <span class="optional">month and day each year</span></label>
          <DateTimePicker bind:value={yearlyDateScratch} hideTime />
        </div>
      {/if}

      <div class="field" style="flex: 1 1 220px;">
        <label>Timing Mode</label>
        <div class="chip-row">
          <button type="button" class="chip-btn" class:active={form.recurrence.mode === 'EXACT'} disabled={locked} on:click={() => { form.recurrence.mode = 'EXACT'; touchTerritory(); }}>Exact Time</button>
          <button type="button" class="chip-btn" class:active={form.recurrence.mode === 'WINDOW'} disabled={locked} on:click={() => { form.recurrence.mode = 'WINDOW'; touchTerritory(); }}>Unpredictable Window</button>
        </div>
      </div>
    </div>

    {#if form.recurrence.mode === 'EXACT'}
      <div class="field-row" style="margin-top:8px;">
        <div class="field inline">
          <label>Start Hour (0–23)</label>
          <input type="number" min="0" max="23" bind:value={form.recurrence.hour} disabled={locked} />
        </div>
        <div class="field inline">
          <label>Start Minute (0–59)</label>
          <input type="number" min="0" max="59" bind:value={form.recurrence.minute} disabled={locked} />
        </div>
      </div>
    {:else}
      <div class="field-row" style="margin-top:8px;">
        <div class="field inline"><label>Window Start Hour</label><input type="number" min="0" max="23" bind:value={form.recurrence.windowStartHour} disabled={locked} /></div>
        <div class="field inline"><label>Start Minute</label><input type="number" min="0" max="59" bind:value={form.recurrence.windowStartMinute} disabled={locked} /></div>
        <div class="field inline"><label>Window End Hour</label><input type="number" min="0" max="23" bind:value={form.recurrence.windowEndHour} disabled={locked} /></div>
        <div class="field inline"><label>End Minute</label><input type="number" min="0" max="59" bind:value={form.recurrence.windowEndMinute} disabled={locked} /></div>
      </div>
      <div class="unpredictable-note">
        <Icon name="info" size={13} />
        <span>The event randomly starts at any unpredictable moment between {pad(form.recurrence.windowStartHour || 0)}:{pad(form.recurrence.windowStartMinute || 0)} and {pad(form.recurrence.windowEndHour || 0)}:{pad(form.recurrence.windowEndMinute || 0)}.</span>
      </div>
    {/if}
  {/if}

  <FormSectionHead title="Participating Gangs" hint="Gangs allowed to participate in this territory auction" />
  <GangSelector
    title="Allowed Gangs"
    hint="who can place bids in this territory auction"
    {locked}
    bind:allowedGangs={form.settings.allowedGangs}
    on:change={touchTerritory}
  />

  <FormSectionHead title="Auction Perimeter (Bidding Arena)" hint="where eligible gang members stand to bid" />
  <section class="card">
    <header class="card-head">
      <div class="step"><Icon name="map" size={14} /></div>
      <div>
        <h3>Bidding Perimeter (Arena Boundary)</h3>
        <p>Bidders must stand inside this boundary at the auction house to place bids. Left-click points on the ground, Backspace to undo, Enter to save.</p>
      </div>
      <span class="state" class:ok={zoneReady}>{zoneReady ? `${zonePoints.length} points` : 'Not set'}</span>
    </header>

    <div class="zone-row">
      <div class="zone-stats">
        {#if zoneStats}
          <div><b>{zoneStats.area.toLocaleString()}</b><span>m² area</span></div>
          <div><b>{zoneStats.w} × {zoneStats.h}</b><span>m bounding box</span></div>
          <div><b>{zonePoints.length}</b><span>corner points</span></div>
        {:else}
          <p class="hint" style="margin:0">Click Draw Perimeter, aim at ground corners, and left-click to drop points.</p>
        {/if}
      </div>
      <div class="actions">
        <button type="button" class="btn btn-sm btn-preview" on:click={recordZone} disabled={locked || isRecordingZone}>
          <Icon name="flag" size={12} /><span>{isRecordingZone ? 'Drawing…' : (zoneReady ? 'Redraw Perimeter' : 'Draw Perimeter')}</span>
        </button>
        {#if zoneReady}
          <button type="button" class="btn btn-sm btn-refresh" on:click={() => previewZone(false)} disabled={busyZone}><Icon name="eye" size={12} /><span>Preview Here</span></button>
          <button type="button" class="btn btn-sm" on:click={() => previewZone(true)} disabled={busyZone}><Icon name="teleport" size={12} /><span>Teleport &amp; Preview</span></button>
          <button type="button" class="btn btn-sm btn-danger" on:click={clearZone} disabled={locked}><Icon name="trash" size={12} /><span>Clear</span></button>
        {/if}
      </div>
    </div>
  </section>

<!-- ═══════════════════════════ 2. LOTS & BIDDING ═══════════════════════════ -->
{:else if section === 'areas'}
  <SubTabs
    bind:active={areasSubTab}
    tabs={[
      { id: 'territories', label: 'Territories', icon: 'flag', count: areas.length },
      { id: 'projectors', label: 'Projectors', icon: 'eye', count: (a.projector && a.projector.x != null) ? 'Placed' : '0' },
      { id: 'bidding', label: 'Bidding & Anti-snipe', icon: 'gear' },
    ]}
  />

  {#if areasSubTab === 'territories'}
    <FormSectionHead title="Territories" hint={`${areas.length} configured`}>
      {#if !locked}<button type="button" class="btn btn-primary head-btn" on:click={addArea}><Icon name="plus" size={13} /> Add Territory</button>{/if}
    </FormSectionHead>

    <details class="explain" open={areas.length === 0}>
      <summary><Icon name="info" size={14} /> What is a territory, and what is its Leader Ped for?</summary>
      <div class="explain-body">
        <p>Each territory is a piece of the map that one gang can own. Gangs win it at this auction (or you hand it out as the starting owner), grow it with Gang XP, and fight rival gangs for it in territory wars.</p>
        <p><b>The Leader Ped</b> is the gang boss NPC that stands at the territory. Where you place him is where the territory <i>is</i>. That single spot is:</p>
        <ul>
          <li><b>The map blip.</b> Every player sees its sprite, the territory name and the owner gang on the map.</li>
          <li><b>The war capture point.</b> In a war, attackers talk to the Leader Ped (within the talk distance) and hold the capture radius around him until the capture bar fills.</li>
          <li><b>The loot spot.</b> After a war, the winning gang loots Gang XP from him.</li>
          <li><b>The ground ring</b> in the owner's colour that appears when players come near.</li>
        </ul>
        <p>Add a territory, give it a name, owner and starting bid on its row, then press the eye button to place the Leader Ped with the hologram. Press <b>Edit</b> only when you need the rest (war capture settings, ped model, blip sprite).</p>
      </div>
    </details>

    {#if areas.length === 0}
      <div class="empty">No territories yet. Click "Add Territory" to create one.</div>
    {/if}

    {#each areas as ar, i (ar.id + '_' + i)}
      <TerritoryAreaCard
        {ar} index={i} count={areas.length} open={openId === ar.id} {locked} {availableGangs} pedPool={GANG_LEADER_PEDS}
        on:toggle={() => (openId = openId === ar.id ? null : ar.id)}
        on:move={(e) => moveArea(i, e.detail)}
        on:remove={() => removeArea(i)}
        on:rename={() => { renameId(ar); openId = ar.id; }}
        on:change={touchTerritory}
      />
    {/each}
  {:else if areasSubTab === 'projectors'}
    <!-- Auction Projector 3D World Placement -->
    <section class="card">
      <header class="card-head">
        <div class="step"><Icon name="eye" size={14} /></div>
        <div>
          <h3>Auction Projector Placement <code>{projectorModel}</code></h3>
          <p>Place the 3D auction projector anchor in the world. It serves as the physical anchor for the floating auction display.</p>
        </div>
        <span class="state" class:ok={a.projector && a.projector.x != null}>
          {a.projector && a.projector.x != null ? 'Placed' : 'Not placed'}
        </span>
      </header>

      <div class="proj-card" style="margin:0">
        <div class="proj-main">
          <div class="loc-row">
            {#if a.projector && a.projector.x != null}
              <span><em>X</em> {Number(a.projector.x).toFixed(1)}</span>
              <span><em>Y</em> {Number(a.projector.y).toFixed(1)}</span>
              <span><em>Z</em> {Number(a.projector.z).toFixed(1)}</span>
              <span><em>Heading</em> {Number(a.projector.heading || 0).toFixed(0)}°</span>
            {:else}
              <span class="muted">No projector placed yet. Click "Place Projector" to position it in-world using the Prop Placer.</span>
            {/if}
          </div>
          {#if projNote}<div class="note">{projNote}</div>{/if}
        </div>
        {#if a.projector && a.projector.x != null}
          <div class="scr-size">
            <div class="scr-ctl">
              <label for="scr-range">Screen size <span class="optional">how big players see the auction board</span></label>
              <div class="scr-row">
                <input id="scr-range" type="range" min={scrMin} max={scrMax} step="0.05" value={scale} disabled={locked} on:input={(e) => setScale(e.currentTarget.value)} />
                <input type="number" class="scr-num" min={Math.round(scrMin * 100)} max={Math.round(scrMax * 100)} step="5" value={Math.round(scale * 100)} disabled={locked} on:change={(e) => setScale(Number(e.currentTarget.value) / 100)} /><span class="scr-pct">%</span>
                <button type="button" class="btn btn-steel" disabled={locked || scale === 1} on:click={() => setScale(1)}>Reset</button>
              </div>
              <div class="scr-read"><b>{boardW.toFixed(1)} × {boardH.toFixed(1)} m</b> <span class="muted">· 100% = {scrBaseW} × {scrBaseH} m · saved with the event and shown when bidding starts</span></div>
              <div class="btn-row" style="margin:10px 0 0">
                <button type="button" class="btn btn-steel" on:click={previewScreenSize} title="Draw the board at this size in the world, next to the projector"><Icon name="eye" size={14} /> Preview Size In-World</button>
              </div>
            </div>
            <svg class="scr-pic" viewBox="0 0 {PIC_W} {PIC_H}" width={PIC_W} height={PIC_H} role="img" aria-label="The auction board drawn to scale next to a 1.8 metre person">
              <line x1="8" y1={PIC_H - 12} x2={PIC_W - 8} y2={PIC_H - 12} class="scr-ground" />
              <rect x="40" y={boardY} width={boardW * ppm} height={boardH * ppm} class="scr-board" />
              <text x={40 + (boardW * ppm) / 2} y={boardY + (boardH * ppm) / 2 + 4} text-anchor="middle" class="scr-txt">{boardW.toFixed(1)} × {boardH.toFixed(1)} m</text>
              <rect x="14" y={PIC_H - 12 - 1.8 * ppm} width={0.5 * ppm} height={1.8 * ppm} rx="2" class="scr-person" />
              <text x="14" y={PIC_H - 16 - 1.8 * ppm} class="scr-txt small">1.8 m</text>
            </svg>
          </div>
        {/if}
        <div class="btn-row" style="margin-top:12px">
          {#if !locked}
            <button type="button" class="btn btn-primary" disabled={projBusy} on:click={() => placeProjector(false)}>
              <Icon name="eye" size={14} /> {projBusy ? 'Placing…' : (a.projector && a.projector.x != null ? 'Edit Projector' : 'Place Projector')}
            </button>
            <button type="button" class="btn btn-steel" disabled={projBusy} on:click={setProjectorHere} title="Put the projector exactly where you are standing now"><Icon name="pin" size={14} /> Set My Position</button>
          {/if}
          {#if $bootstrap?.isAdmin}
            <button type="button" class="btn btn-steel" on:click={teleportToProjector} title={a.projector && a.projector.x != null ? 'Teleport to the projector' : 'Teleport to the auction area'}><Icon name="teleport" size={14} /> Teleport</button>
          {/if}
          {#if a.projector && a.projector.x != null}
            <button type="button" class="btn btn-steel" disabled={projBusy} on:click={() => placeProjector(true)} title="Open the Prop Placer on the projector to look at it in the world"><Icon name="eye" size={14} /> Preview In-World</button>
            {#if !locked}
              <button type="button" class="btn btn-danger" on:click={clearProjector}><Icon name="trash" size={13} /> Remove Placement</button>
            {/if}
          {/if}
        </div>
      </div>
    </section>
  {:else if areasSubTab === 'bidding'}
    <!-- Global Auction Bidding Rules & Anti-Snipe -->
    <section class="card rules-card">
      <header class="card-head">
        <div class="step"><Icon name="gear" size={14} /></div>
        <div>
          <h3>Auction Bidding Rules &amp; Anti-Snipe</h3>
          <p>Global auction settings for territory bidding, timers, and sniping protection.</p>
        </div>
      </header>
      <div class="field-row">
        <div class="field"><label>Default Starting Bid ($)</label><input type="number" min="0" bind:value={a.startingBid} disabled={locked} /></div>
        <div class="field"><label>Minimum Bid Increment ($)</label><input type="number" min="100" bind:value={a.minBidIncrement} disabled={locked} /></div>
      </div>
      <div class="field-row">
        <div class="field"><label>Bidding Time per Territory <span class="optional">seconds</span></label><input type="number" min="15" max="900" bind:value={a.lotSeconds} disabled={locked} /></div>
        <div class="field"><label>Pause Between Territories <span class="optional">seconds</span></label><input type="number" min="3" max="300" bind:value={a.lotGapSeconds} disabled={locked} /></div>
        <div class="field"><label>Intro / Buffer Before Bidding <span class="optional">seconds</span></label><input type="number" min="0" max="600" bind:value={a.introSeconds} disabled={locked} /></div>
      </div>
      <div class="toggle-group" style="margin-top:10px">
        <Toggle label="Anti-snipe extension (late bid adds time)" bind:checked={a.antiSnipeEnabled} disabled={locked} />
      </div>
      {#if a.antiSnipeEnabled}
        <div class="field-row">
          <div class="field"><label>Window <span class="optional">bid placed in the last X seconds…</span></label><input type="number" min="0" max="60" bind:value={a.antiSnipeWindowSeconds} disabled={locked} /></div>
          <div class="field"><label>Extension <span class="optional">…extends bidding by X seconds</span></label><input type="number" min="0" max="120" bind:value={a.antiSnipeExtendSeconds} disabled={locked} /></div>
        </div>
      {/if}
    </section>

  {/if}

<!-- ═══════════════════════════ 3. REVIEW ═══════════════════════════ -->
{:else if section === 'review'}
  <div class="review-grid">
    <div class="review-card wide">
      <div class="rc-title">{form.name || 'Untitled event'}</div>
      <div class="rc-sub">{form.shortDescription}</div>
      <div class="rc-kv"><span>Status</span><b>{form.status || 'DRAFT'}</b></div>
      <div class="rc-kv"><span>Schedule</span><b>{startsText}</b></div>
      <div class="rc-kv"><span>Duration</span><b>{durationMin > 0 ? durationMin + ' minutes' : 'default (' + (auctionDefaults.eventMinutes || 30) + ' minutes)'}</b></div>
      <div class="rc-kv"><span>Participating gangs</span><b>{participating.join(', ') || '—'}</b></div>
      <div class="rc-kv"><span>Territories</span><b>{areas.length} ({areas.filter((x) => x.auctioned !== false).length} up for auction)</b></div>
      <div class="rc-kv"><span>Bidding</span><b>{a.lotSeconds}s per territory · {a.lotGapSeconds}s gap · anti-snipe {a.antiSnipeEnabled ? `+${a.antiSnipeExtendSeconds}s` : 'off'}</b></div>
      <div class="rc-kv"><span>Auction zone</span><b>{zoneReady ? `${zonePoints.length} points (${zoneStats ? zoneStats.area : 0}m²)` : (a.location && a.location.x != null ? `${Number(a.location.x).toFixed(0)}, ${Number(a.location.y).toFixed(0)}` : 'Not set')}</b></div>
      <div class="rc-kv"><span>Projector</span><b>{a.projector && a.projector.x != null ? `${projectorModel} placed` : 'Not placed'}</b></div>
    </div>
    <div class="review-card">
      <div class="rc-title">Configuration Checklist</div>
      {#each readiness as r (r.label)}
        <div class="check-row" class:ok={r.ok}><Icon name={r.ok ? 'check' : 'close'} size={13} /><span>{r.label}</span></div>
      {/each}
    </div>
  </div>

  <FormSectionHead title="Territories List" hint={`${areas.length} configured for auction`} />
  <div class="tbl-wrap">
    <table class="tbl">
      <thead>
        <tr>
          <th>#</th>
          <th>Territory</th>
          <th>Starting Owner</th>
          <th>Starting Bid</th>
          <th>Min Raise</th>
          <th>XP Value</th>
          <th>Leader Ped (Vector)</th>
          <th>NPC Model</th>
          <th>Map Blip / Sprite</th>
          <th>War Defense</th>
        </tr>
      </thead>
      <tbody>
        {#each areas as x, i (x.id)}
          <tr>
            <td>{i + 1}</td>
            <td><span class="swatch" style="background:{x.color}"></span> {x.name} <code>{x.id}</code></td>
            <td>{x.startingOwner ? ownerOf(x.startingOwner) : '—'}</td>
            <td>{x.auctioned === false ? 'Not auctioned' : money(x.startingBid)}</td>
            <td>{x.auctioned === false ? '—' : money(x.minBidIncrement)}</td>
            <td>{x.xpValue}</td>
            <td class:bad={x.capture?.ped?.x == null}>
              {#if x.capture?.ped?.x != null}
                {Number(x.capture.ped.x).toFixed(1)}, {Number(x.capture.ped.y).toFixed(1)}, {Number(x.capture.ped.z).toFixed(1)}
              {:else}
                Not placed
              {/if}
            </td>
            <td><code>{x.capture?.ped?.model || '—'}</code></td>
            <td>
              {#if x.spriteType === 'CUSTOM_LOGO'}
                <span class="chip">Custom Logo</span>
              {:else}
                <span class="chip">Sprite #{x.blip?.sprite || 310}</span>
              {/if}
            </td>
            <td>{x.capture?.seconds}s · {x.capture?.radius}m ({x.capture?.contestRule})</td>
          </tr>
        {/each}
        {#if areas.length === 0}
          <tr><td colspan="10" class="muted" style="text-align:center; padding:18px;">No territories configured yet.</td></tr>
        {/if}
      </tbody>
    </table>
  </div>

  {#if !locked}
    <div class="review-actions">
      <button type="button" class="btn btn-save" on:click={() => dispatch('save')}><Icon name="save" size={14} /> SAVE DRAFT</button>
      <button type="button" class="btn btn-primary" disabled={!allReady} title={allReady ? '' : 'Finish the checklist first'} on:click={() => dispatch('publish')}><Icon name="megaphone" size={14} /> PUBLISH EVENT</button>
      <span class="muted">Publish saves and arms the schedule ({startsText}). Territories appear on the map live once active.</span>
    </div>
  {/if}
{/if}

<style>
  .hint { font-size: var(--fs-small); color: var(--text-muted, #aeb5bd); margin: 6px 0 12px; line-height: 1.55; }
  .muted { color: var(--text-muted, #aeb5bd); font-size: var(--fs-small); }
  .note { margin: 8px 0; padding: 8px 12px; border: 1px solid var(--tablet-border); border-radius: var(--r-ctl); background: var(--bg-surface, #15171b); font-size: var(--fs-small); color: var(--lt-c9ced4, #c9ced4); }
  .empty { padding: 28px; text-align: center; border: 1px dashed var(--tablet-border); border-radius: var(--r-panel); color: var(--text-muted, #aeb5bd); }
  .field-row { display: flex; gap: 14px; flex-wrap: wrap; }
  .field-row > .field { flex: 1 1 180px; }
  .field.inline { flex: 0 0 160px; margin: 0; }
  .btn-row { display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap; margin: 8px 0 14px; }
  .loc-row { display: flex; gap: 18px; flex-wrap: wrap; align-items: center; font-size: var(--fs-body); margin: 6px 0; }
  .loc-row em { font-style: normal; color: var(--text-muted, #aeb5bd); margin-right: 5px; font-size: var(--fs-meta); }
  .chip-row { display: flex; gap: 8px; flex-wrap: wrap; margin: 8px 0; }
  .chip-btn { background: var(--c-raised, #1f2328); border: 1px solid var(--c-line, #2a2e35); color: var(--lt-c9ced4, #c9ced4); border-radius: var(--r-tag); padding: 8px 14px; font-weight: 600; font-size: var(--fs-meta); }
  .chip-btn:hover:not(:disabled) { background: var(--c-hover, #272b31); }
  .chip-btn.active { border-color: var(--accent-primary); color: var(--on-accent); background: var(--c-action); }
  .toggle-group { display: flex; flex-direction: column; gap: 8px; margin: 8px 0 12px; }

  /* card & zone styling matching Container Wars */
  .card {
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-panel);
    padding: 16px 18px;
    margin: 12px 0 16px;
  }
  .card-head {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 14px;
  }
  .card-head .step {
    width: 28px;
    height: 28px;
    border-radius: var(--r-ctl);
    background: var(--c-hover);
    color: var(--accent-primary);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .card-head h3 {
    margin: 0;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .card-head p {
    margin: 2px 0 0;
    font-size: var(--fs-small);
    color: var(--text-muted, #aeb5bd);
  }
  .card-head .state {
    margin-left: auto;
    font-size: var(--fs-meta);
    padding: 3px 10px;
    border-radius: 999px;
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    color: var(--lt-aeb5bd, #aeb5bd);
    font-weight: 600;
  }
  .card-head .state.ok {
    border-color: #46c98b;
    color: var(--lt-46c98b, #46c98b);
    background: rgba(70, 201, 139, 0.1);
  }
  .zone-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
    padding: 12px 14px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--lt-22262c, #22262c);
    border-radius: var(--r-panel);
  }
  .zone-stats {
    display: flex;
    gap: 20px;
    flex-wrap: wrap;
    font-size: var(--fs-small);
  }
  .zone-stats div {
    display: flex;
    flex-direction: column;
  }
  .zone-stats b {
    font-size: var(--fs-emph);
    color: var(--lt-ffffff, #fff);
  }
  .zone-stats span {
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
  }
  .btn-sm {
    padding: 6px 12px;
    font-size: var(--fs-small);
    border-radius: var(--r-ctl);
  }
  .unpredictable-note {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    margin-top: 10px;
    padding: 10px 12px;
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    border-radius: var(--r-ctl);
    font-size: var(--fs-meta);
    color: var(--lt-c9ced4, #c9ced4);
    line-height: 1.5;
  }
  .server-clock {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 8px;
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
  }
  .server-clock .v {
    color: var(--lt-ffc857, #ffc857);
    font-weight: 600;
  }

  .scr-size { display: flex; gap: 24px; align-items: center; flex-wrap: wrap; margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--c-line); }
  .scr-ctl { flex: 1 1 320px; min-width: 280px; }
  .scr-ctl label { display: block; font-weight: 700; margin-bottom: 8px; }
  .scr-row { display: flex; align-items: center; gap: 10px; }
  .scr-row input[type='range'] { flex: 1; accent-color: var(--accent-primary); }
  .scr-num { width: 74px; text-align: right; }
  .scr-pct { color: var(--text-muted); }
  .scr-read { margin-top: 8px; }
  .scr-pic { flex: none; background: var(--c-base); border: 1px solid var(--c-line); border-radius: var(--r-ctl); }
  .scr-ground { stroke: var(--c-line); stroke-width: 1; }
  .scr-board { fill: var(--c-raised); stroke: var(--c-action); stroke-width: 2; }
  .scr-person { fill: var(--text-dim); }
  .scr-txt { fill: var(--text-main); font-size: 12px; font-weight: 700; }
  .scr-txt.small { font-size: 10.5px; fill: var(--text-dim); font-weight: 600; }
  .proj-card { border: 1px solid var(--c-line, #2a2e35); background: var(--c-panel, #181b1f); border-radius: var(--r-panel); padding: 14px 16px; margin: 8px 0 14px; }
  .head-btn { margin-left: auto; }

  /* the territory list: see ui/TerritoryAreaCard.svelte */
  .explain { margin: 0 0 10px; border: 1px solid var(--tablet-border); border-radius: var(--r-panel); background: var(--tablet-panel); }
  .explain summary { display: flex; align-items: center; gap: 8px; padding: 9px 14px; cursor: pointer; font-size: var(--fs-small); font-weight: 600; color: var(--text-dim, #c9ced4); list-style: none; }
  .explain summary::-webkit-details-marker { display: none; }
  .explain summary :global(svg) { color: var(--lt-7bb6f2, #7bb6f2); }
  .explain[open] summary { border-bottom: 1px solid var(--tablet-border); color: var(--lt-ffffff, #fff); }
  .explain-body { padding: 10px 16px 12px; font-size: var(--fs-small); line-height: 1.6; color: var(--text-dim, #c9ced4); }
  .explain-body p { margin: 0 0 8px; }
  .explain-body ul { margin: 0 0 8px; padding-left: 20px; }
  .explain-body li { margin-bottom: 3px; }
  .explain-body b { color: var(--lt-ffffff, #fff); }
  .swatch { display: inline-block; width: 13px; height: 13px; border-radius: 4px; border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.25); flex-shrink: 0; }
  .chip { display: inline-flex; align-items: center; background: var(--tablet-panel); border: 1px solid var(--tablet-border); border-radius: 999px; padding: 2px 10px; font-size: var(--fs-meta); color: var(--lt-c9ced4, #c9ced4); margin-right: 4px; }
  td code { font-size: var(--fs-meta); color: var(--lt-c5aaff, #c5aaff); background: rgba(155, 123, 255, 0.1); padding: 1px 6px; border-radius: var(--r-panel); margin-left: 6px; font-variant-numeric: tabular-nums; }

  .form-subhead { margin: 16px 0 8px; font-weight: 700; font-size: var(--fs-small); letter-spacing: 0.02em; color: var(--lt-e3e6e9, #e3e6e9); border-bottom: 1px solid var(--c-line, #2a2e35); padding-bottom: 5px; }
  .color-row { display: flex; gap: 8px; }
  .color-row input[type='color'] { width: 48px; padding: 2px; height: 40px; }
  .logo-input-preview-row { display: flex; gap: 8px; align-items: center; }
  .logo-preview-box { width: 40px; height: 40px; border-radius: var(--r-ctl); background: var(--bg-surface, #15171b); border: 1px solid var(--c-line, #2a2e35); display: flex; align-items: center; justify-content: center; overflow: hidden; flex-shrink: 0; }
  .logo-preview-box img { max-width: 100%; max-height: 100%; object-fit: contain; }

  /* review */
  .review-grid { display: grid; grid-template-columns: 1.4fr 1fr; gap: 14px; margin-bottom: 14px; }
  .review-card { background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); padding: 14px 16px; }
  .rc-title { font-size: var(--fs-emph); font-weight: 700; margin-bottom: 4px; }
  .rc-sub { color: var(--text-muted, #aeb5bd); font-size: var(--fs-small); margin-bottom: 8px; }
  .rc-kv { display: flex; justify-content: space-between; gap: 14px; padding: 6px 0; border-top: 1px solid var(--c-raised, #1f2328); font-size: var(--fs-small); }
  .rc-kv span { color: var(--text-muted, #aeb5bd); }
  .rc-kv b { text-align: right; font-weight: 600; }
  .check-row { display: flex; align-items: center; gap: 8px; padding: 5px 0; font-size: var(--fs-small); color: var(--lt-ff8a80, #ff8a80); }
  .check-row.ok { color: var(--lt-46c98b, #46c98b); }
  .tbl-wrap { overflow-x: auto; border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); }
  .tbl { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  .tbl th { text-align: left; padding: var(--tbl-th-y) var(--tbl-x); background: var(--c-panel); color: var(--text-muted); font-weight: 600; border-bottom: 1px solid var(--c-line); white-space: nowrap;
    font-size: var(--fs-meta);
    letter-spacing: 0;
  }
  .tbl td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft); vertical-align: top;
    font-variant-numeric: tabular-nums;
  }
  .tbl td.bad { color: #ff5d50; font-weight: 500;
    font-variant-numeric: tabular-nums;
  }
  .review-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--c-line, #2a2e35); }
  @media (max-width: 1150px) { .review-grid { grid-template-columns: 1fr; } }
</style>
