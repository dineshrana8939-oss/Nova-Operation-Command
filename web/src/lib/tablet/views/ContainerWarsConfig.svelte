<script>
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import { get } from 'svelte/store';
  import SubTabs from '../ui/SubTabs.svelte';
  import {
    teleportToPosition, drawContainerWarsPerimeter, checkModels,
    previewContainerWarsZone, testContainerWarsCrane, startHarbourPlacer, planCraneCarry, getPlayerPosition,
  } from '../../api/route.js';
  import { invoke } from '../../api/nui.js';
  import { openPropPlacer, previewPlacedProps, clearPlacedPreview, placedPreviewStatus } from '../../api/placer.js';
  import SpawnModeStrip from '../ui/SpawnModeStrip.svelte';
  import PropTable from '../ui/PropTable.svelte';
  import { zoneRecordingResult, bootstrap, tabletOpen } from '../../stores.js';
  import Icon from '../ui/Icon.svelte';
  import { confirmAction } from '../ui/confirm.js';
  import { renumberAuto, reindexAfterRemoval } from '../../util/autoName.js';
  import RewardListEditor from '../ui/RewardListEditor.svelte';
  import ModelPicker from '../ui/ModelPicker.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import SavedTemplatePicker from '../ui/SavedTemplatePicker.svelte';
  import '../tablet-theme.css';

  export let containerWars = {
    maxContainers: 4,
    containersPerRound: 1,
    crane: {},
    zone: { points: [] },
    containers: [],
  };
  export let locked = false;
  export let props = [];

  const dispatch = createEventDispatcher();

  // ── config & bootstrap defaults ───────────────────────────────────────────
  $: cat = $bootstrap?.containerWars || {};
  $: cwd = cat.defaults || {};
  $: harbour = cat.harbour || null;
  $: pickups = harbour?.pickups || [];
  $: dummies = harbour?.dummies || [];
  $: dummyModels = (harbour?.dummyModels && harbour.dummyModels.length)
    ? harbour.dummyModels.map((m) => ({ id: m.model, label: `${m.label || m.model} (${m.model})` }))
    : (harbour?.dummyModel ? [{ id: harbour.dummyModel, label: harbour.dummyModel }] : []);
  $: dummyModelIds = dummyModels.map((m) => m.id);
  $: dummyChoices = dummyModels.filter((m) => modelOk[m.id] !== false);
  $: maxDummies = num(harbour?.maxDummies, 150);
  let notice = '';

  $: drops = (harbour?.drops && harbour.drops.length) ? harbour.drops : (harbour?.drop ? [harbour.drop] : []);
  $: craneNow = cat.craneResolved || harbour?.crane || null;

  const MAX_CRANES = 6;
  $: cranes = (cat.cranesResolved && cat.cranesResolved.length) ? cat.cranesResolved : (craneNow && craneNow.x != null ? [craneNow] : []);
  $: craneAssign = cat.craneAssign || [];
  $: unreachableSpots = craneAssign.map((a, i) => (a && !a.reachable && (pickups[i] || drops[i]) ? i + 1 : 0)).filter(Boolean);
  const craneServes = (assign, ci) => (assign || []).map((a, i) => (a && a.crane === ci + 1 && a.reachable ? i + 1 : 0)).filter(Boolean);
  const craneRow = (c) => ({ x: c.x, y: c.y, z: c.z, heading: c.heading || 0, uid: c.uid });
  const num = (v, fallback) => (v !== null && v !== undefined && v !== '' && Number.isFinite(Number(v)) ? Number(v) : fallback);
  let MAX_CONTAINERS = 10;   // most SPOTS the yard can hold
  $: MAX_CONTAINERS = Math.max(1, Math.min(num(harbour?.maxContainers, 10), num(cwd.maxContainers, 10)));
  // most auction LOTS: they take the yard's spots in turn, round after round, so this is not limited by the spots
  let MAX_LOTS = 40;
  $: MAX_LOTS = Math.max(MAX_CONTAINERS, num(cat.maxLots, 40));

  // ── models ─────────────────────────────────────────────────────────────────
  const FALLBACK_CONTAINER_MODELS = [
    { id: 'tr_prop_tr_container_01a', label: 'Red Cargo Container with Doors (tr_prop_tr_container_01a)' },
    { id: 'tr_prop_tr_container_01c', label: 'Blue Cargo Container with Doors (tr_prop_tr_container_01c)' },
    { id: 'tr_prop_tr_container_01f', label: 'Green Cargo Container with Doors (tr_prop_tr_container_01f)' },
    { id: 'tr_prop_tr_container_01g', label: 'Orange Cargo Container with Doors (tr_prop_tr_container_01g)' },
    { id: 'tr_prop_tr_container_01h', label: 'Yellow Cargo Container with Doors (tr_prop_tr_container_01h)' },
    { id: 'tr_prop_tr_container_01i', label: 'Steel Cargo Container with Doors (tr_prop_tr_container_01i)' },
    { id: 'prop_container_ld', label: 'Large Open-End Container (prop_container_ld)', vehicleSafe: true },
  ];
  const toChoices = (list, fallback) =>
    Array.isArray(list) && list.length ? list.map((m) => ({ id: m.model, label: `${m.label || m.model} (${m.model})`, vehicleSafe: m.vehicleSafe === true })) : fallback;
  // picklist text: drop the trailing "(model_id)" and the redundant "with Doors"; the full label stays in the tooltip
  const shortLabel = (l) => String(l).replace(/\s*\([^)]*\)\s*$/, '').replace(/\s+with Doors$/i, '');
  let CONTAINER_MODELS = FALLBACK_CONTAINER_MODELS;
  $: CONTAINER_MODELS = toChoices(cat.containerModels, FALLBACK_CONTAINER_MODELS);

  function hasBothVehicleAndLoot(rewards) {
    if (!Array.isArray(rewards) || rewards.length < 2) return false;
    const hasVeh = rewards.some((r) => r && (r.type === 'VEHICLE' || r.type === 'vehicle'));
    const hasOther = rewards.some((r) => r && r.type !== 'VEHICLE' && r.type !== 'vehicle');
    return hasVeh && hasOther;
  }

  let modelOk = {};
  let checkedKey = '';
  async function verifyModels(ids) {
    const key = ids.join('|');
    if (!ids.length || key === checkedKey) return;
    checkedKey = key;
    try {
      const res = await checkModels(ids);
      if (res && res.ok && res.results) modelOk = res.results;
    } catch (e) { /* preview fallback */ }
  }
  $: verifyModels([...CONTAINER_MODELS.map((m) => m.id), ...dummyModelIds]);
  $: containerChoices = CONTAINER_MODELS.filter((m) => modelOk[m.id] !== false);

  // ── defaults / normalization ───────────────────────────────────────────────
  let TIMING_DEFAULTS = {};
  $: TIMING_DEFAULTS = {
    craneTravelSeconds: num(cwd.craneTravelSeconds, 8),
    craneLiftHeight: num(cwd.craneLiftHeight, 12),
    hookReturnSeconds: num(cwd.hookReturnSeconds, 0),
    hookDescendSeconds: num(cwd.hookDescendSeconds, 0.5),
    lotGapSeconds: num(cwd.lotGapSeconds, 3),
    roundBreakSeconds: num(cwd.roundBreakSeconds, 10),
    settleSeconds: num(cwd.settleSeconds, 2),
    openSeconds: num(cwd.openSeconds, 3),
    startCountdownSeconds: num(cwd.startCountdownSeconds, 30),
    antiSnipeWindowSeconds: num(cat.antiSnipe?.triggerSeconds, 10),
    antiSnipeExtendSeconds: num(cat.antiSnipe?.extendSeconds, 15),
    auctionOrder: 'IN_ORDER',
    finalRoundEnabled: cwd.finalRoundEnabled !== false,
    finalRoundBreakSeconds: num(cwd.finalRoundBreakSeconds, 30),
    finalRoundAuctionSeconds: num(cwd.finalRoundAuctionSeconds, 0),
    carryPath: cwd.carryPath === 'STRAIGHT' ? 'STRAIGHT' : 'CURVE',
    carryCurve: num(cwd.carryCurve, 0.4),
  };

  $: if (!containerWars.containers) containerWars.containers = [];
  $: if (containerWars.maxContainers == null) containerWars.maxContainers = num(cwd.containersPerRound, 4);
  $: if (!containerWars.zone) containerWars.zone = { points: [] };
  // Only values that are MISSING get their default. A field the admin has just cleared (null) is left empty while they type:
  // filling it here on every keystroke put the default back under the cursor, so typing "12" became "812".
  $: for (const [k, v] of Object.entries(TIMING_DEFAULTS)) {
    if (containerWars[k] === undefined) containerWars[k] = v;
  }
  // Gang XP for the winning gang of a lot (kept out of TIMING_DEFAULTS: "Reset timing" must not touch it)
  $: if (containerWars.gangXpOnWin === undefined) containerWars.gangXpOnWin = false;
  $: if (containerWars.gangXpAmount === undefined) containerWars.gangXpAmount = 100;

  // The range the server accepts for each timing value (convoy_manager.lua clamps to these). The setup shows — and the
  // totals add up — what the event will REALLY use: an empty field means the default, a number outside the range is cut to it.
  const TIMING_LIMITS = {
    craneTravelSeconds: [3, 30], craneLiftHeight: [3, 60], settleSeconds: [0, 15],
    hookReturnSeconds: [0, 20], hookDescendSeconds: [0.3, 20],
    openSeconds: [0, 15], lotGapSeconds: [5, 120], roundBreakSeconds: [3, 120], startCountdownSeconds: [0, 300],
  };
  // reactive (not a plain function) so a tile that calls eff('…') redraws when the field changes
  $: eff = (k) => {
    const [lo, hi] = TIMING_LIMITS[k] || [0, 9999];
    const raw = containerWars[k];
    const n = raw === null || raw === '' || raw === undefined ? NaN : Number(raw);
    const base = Number.isFinite(n) ? n : Number(TIMING_DEFAULTS[k]) || 0;
    return Math.max(lo, Math.min(hi, base));
  };
  // when the admin leaves a timing field, it shows the value the event will use
  const fixTiming = (k) => { if (!locked) containerWars[k] = eff(k); };
  $: if (containerWars.containersPerRound == null) containerWars.containersPerRound = 1;

  const clampInt = (v, lo, hi, dflt) => {
    const n = Math.round(Number(v));
    return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : dflt;
  };
  const hasCoords = (c) => !!c && c.x != null && c.y != null && c.z != null;
  const fmt = (n) => (n == null ? '—' : Number(n).toFixed(1));

  // ── derived summaries ──────────────────────────────────────────────────────
  $: containers = containerWars.containers || [];
  $: modelAlias = cat.containerModelAlias || {};
  function swapRemovedModels() {
    const list = containerWars.containers || [];
    if (!locked && list.some((c) => modelAlias[c.model])) {
      containerWars.containers = list.map((c) => (modelAlias[c.model] ? { ...c, model: modelAlias[c.model] } : c));
    }
  }
  $: swapRemovedModels(modelAlias, containerWars.containers);
  $: totalCount = containers.length;
  // Rounds: each takes the next `perRound` lots. The lots stand on the yard's spots all at once, so a round can hold
  // no more lots than the yard has spots (perRoundTooBig is the error the setup shows; Save and Start refuse it).
  $: spotCount = pickups.length;
  $: perRound = Math.max(1, Math.floor(Number(containerWars.containersPerRound) || 1));
  $: perRoundTooBig = spotCount > 0 && perRound > spotCount;
  $: totalRounds = Math.max(1, Math.ceil(totalCount / perRound));
  $: finalOn = containerWars.finalRoundEnabled !== false && totalRounds > 1;
  $: roundsList = Array.from({ length: totalRounds }, (_, r) => {
    const start = r * perRound + 1;
    const end = Math.min(totalCount, (r + 1) * perRound);
    return { round: r + 1, start, end, count: Math.max(0, end - start + 1), final: finalOn && r + 1 === totalRounds };
  });
  // the yard spot lot number i (0-based) stands on — lots take the spots in turn and start over when they run out
  // (reactive declarations, not plain functions: the markup re-draws a call like spotOf(i) only when the NAME it uses
  //  changes — a function that reads spotCount inside would never be re-run when it does)
  $: spotOf = (i) => (spotCount > 0 ? (i % spotCount) + 1 : i + 1);

  $: speedMul = Math.max(0.25, Math.min(4, num(cwd.craneSpeedMultiplier, 1)));
  // the empty hook going down onto a container and back up after the drop (a return of 0 = the pace of the lowering, 30% of the trip)
  $: hookExtraSeconds = (eff('hookDescendSeconds') + (eff('hookReturnSeconds') || eff('craneTravelSeconds') * 0.3)) / speedMul;
  $: estSeconds = (() => {
    let t = 0;
    for (const c of containers) {
      t += eff('craneTravelSeconds') / speedMul + hookExtraSeconds + eff('settleSeconds') + eff('openSeconds') + (Number(c.auctionDuration) || 0) + eff('lotGapSeconds');
    }
    return t + totalRounds * eff('roundBreakSeconds');
  })();
  $: avgAuction = totalCount ? Math.round(containers.reduce((a, c) => a + (Number(c.auctionDuration) || 0), 0) / totalCount) : Number(bulk.auctionDuration) || 0;
  const fmtDuration = (s) => {
    const m = Math.floor(s / 60);
    return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m ${String(Math.round(s % 60)).padStart(2, '0')}s`;
  };

  // ── explicit crane ↔ spot ↔ drop matrix ────────────────────────────────────
  $: linkageMatrix = pickups.map((p, i) => {
    const assignedCraneIdx = p.assignedCrane ? Number(p.assignedCrane) : null;
    const autoCraneIdx = (craneAssign[i] && craneAssign[i].crane) || 1;
    const effectiveCraneIdx = assignedCraneIdx || autoCraneIdx;
    const effectiveCrane = cranes[effectiveCraneIdx - 1];

    const assignedDropIdx = p.assignedDrop ? Number(p.assignedDrop) : (i + 1 <= drops.length ? i + 1 : 1);
    const effectiveDrop = drops[assignedDropIdx - 1];

    const hasCrane = !!effectiveCrane;
    const hasDrop = !!effectiveDrop;
    const reachable = craneAssign[i] ? craneAssign[i].reachable !== false : true;

    let status = 'ok';
    let label = 'LINKED';
    let warning = '';
    if (!hasCrane) {
      status = 'unassigned-crane';
      label = 'UNASSIGNED CRANE';
      warning = 'No valid crane is assigned to this spot.';
    } else if (!hasDrop) {
      status = 'unassigned-drop';
      label = 'UNASSIGNED DROP';
      warning = 'No valid drop pad is assigned to this spot.';
    } else if (!reachable) {
      status = 'unreachable';
      label = 'OUT OF REACH';
      warning = 'The crane cannot reach both this spot and its drop pad.';
    }

    return {
      spotIndex: i + 1,
      spot: p,
      model: p.model || p.mapModel || 'prop_container_05a',
      assignedCraneIdx,
      effectiveCraneIdx,
      effectiveCrane,
      hasCrane,
      assignedDropIdx,
      effectiveDrop,
      hasDrop,
      reachable,
      status,
      label,
      warning,
    };
  });

  const dropServes = (dropIdx) => {
    return linkageMatrix.filter((l) => l.assignedDropIdx === dropIdx).map((l) => l.spotIndex);
  };

  // ── sync harbour to draft ─────────────────────────────────────────────────
  const same = (a, b) => JSON.stringify(a || null) === JSON.stringify(b || null);
  $: if (harbour && !locked) syncHarbour(harbour, containers.length);
  function syncHarbour(h, count) {
    let changed = false;
    const rc = cat.craneResolved || h.crane;
    const crane = rc ? { x: rc.x, y: rc.y, z: rc.z, heading: rc.heading || 0, model: rc.model || h.crane?.model } : {};
    if (!same(containerWars.crane, crane)) { containerWars.crane = crane; changed = true; }
    containerWars.containers = containers.map((c, i) => {
      const p = h.pickups && h.pickups[i];
      const targetDropIdx = (p && p.assignedDrop) || (i + 1);
      const d = (h.drops && h.drops[targetDropIdx - 1]) || (h.drops && h.drops[i]) || h.drop;
      const drop = d ? { x: d.x, y: d.y, z: d.z + num(h.dropZOffset, 0), heading: d.heading || 0 } : null;
      const pickup = p ? { x: p.x, y: p.y, z: p.z, heading: p.heading || 0 } : null;
      if (!same(c.dropCoords, drop) || !same(c.pickupCoords, pickup)) { changed = true; return { ...c, dropCoords: drop, pickupCoords: pickup }; }
      return c;
    });
    if (!changed) containerWars.containers = containers;
  }

  // ── bidding perimeter ──────────────────────────────────────────────────────
  $: zonePoints = containerWars.zone?.points || [];
  $: zoneReady = zonePoints.length >= 3;
  $: usingDefaultZone = !zoneReady && (harbour?.zone?.points?.length || 0) >= 3;
  $: zoneStats = (() => {
    if (!zoneReady) return null;
    let a = 0;
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (let i = 0; i < zonePoints.length; i++) {
      const p = zonePoints[i];
      const q = zonePoints[(i + 1) % zonePoints.length];
      a += p.x * q.y - q.x * p.y;
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    return { area: Math.round(Math.abs(a) / 2), w: Math.round(maxX - minX), h: Math.round(maxY - minY) };
  })();

  let isRecordingZone = false;
  $: if ($zoneRecordingResult && $zoneRecordingResult.points && $zoneRecordingResult.points.length >= 3 && (!$zoneRecordingResult.target || $zoneRecordingResult.target === 'CONTAINER_WARS')) {
    containerWars.zone = { points: $zoneRecordingResult.points };
    isRecordingZone = false;
    zoneRecordingResult.set(null);
  }

  // ── wizard sections & sub-tabs ───────────────────────────────────────────
  export let section = 'yard'; // 'yard' | 'props' | 'auction' (Auction Rules tab) | 'lots' (Lots & Arena tab)
  let busy = {};
  // The auction settings are split over two main tabs, two sub-tabs each:
  //   'auction'  Auction Rules   → Auction Rules · Timers & Pacing         (how the auction runs)
  //   'lots'     Lots & Arena    → Rounds & Container Lots · Bidding Perimeter & Peds   (what is auctioned and where)
  const SUB_DEFAULT = { auction: 'rules', lots: 'auction' };
  let auctionSub = (typeof localStorage !== 'undefined' && localStorage.getItem(`nova_convoy_last_cw_${section}_sub`)) || SUB_DEFAULT[section] || 'rules';
  $: AUCTION_SUBS = section === 'lots'
    ? [
        { id: 'auction', label: `1. Rounds & Container Lots (${totalCount})`, icon: 'box', count: totalCount },
        { id: 'arena', label: '2. Bidding Perimeter & Peds', icon: 'pin' },
      ]
    : [
        { id: 'rules', label: '1. Auction Rules', icon: 'shield' },
        { id: 'timing', label: '2. Timers & Pacing', icon: 'clock' },
      ];
  // a remembered sub-tab from before the split may not exist in this tab any more
  $: if (!AUCTION_SUBS.some((s) => s.id === auctionSub)) auctionSub = AUCTION_SUBS[0].id;
  $: if (typeof localStorage !== 'undefined' && auctionSub && (section === 'auction' || section === 'lots')) {
    localStorage.setItem(`nova_convoy_last_cw_${section}_sub`, auctionSub);
  }

  const setBusy = (k, v) => (busy = { ...busy, [k]: v });
  const teleportTo = (c) => hasCoords(c) && teleportToPosition(c.x, c.y, c.z);

  // ── containers ─────────────────────────────────────────────────────────────
  const blankLot = (idx) => {
    const spotPick = pickups[spotOf(idx - 1) - 1];
    return {
      id: `cw_cont_${Date.now()}_${idx}`,
      name: `Container #${idx}`,
      model: spotPick?.model || 'tr_prop_tr_container_01a',
      startingBid: num(cwd.startingBid, 5000),
      minBidIncrement: num(cwd.minBidIncrement, 1000),
      auctionDuration: num(cwd.auctionDuration, 45),
      rewards: [{ type: 'MONEY', amount: 50000, pool: '' }],
    };
  };
  // "Container #1, #2…" always matches each lot's position, so removing one never leaves a gap or a duplicate name.
  $: if (containerWars && !locked) {
    const renamed = renumberAuto(containerWars.containers, 'Container #');
    if (renamed !== containerWars.containers) containerWars.containers = renamed;
  }
  const syncLotCount = () => { containerWars.maxContainers = Math.max(1, containerWars.containers.length); };
  function addContainer() {
    if (locked || containers.length >= MAX_LOTS) return;
    containerWars.containers = [...containers, blankLot(containers.length + 1)];
    syncLotCount();
  }
  function removeContainer(index) {
    if (locked) return;
    containerWars.containers = containers.filter((_, i) => i !== index);
    syncLotCount();
  }

  // ── rounds ─────────────────────────────────────────────────────────────────
  // A copy of a lot for a later round: same model, bids and rewards, a fresh id, and its "Container #n" name renumbered.
  const lotCopy = (src, idx) => {
    const c = JSON.parse(JSON.stringify(src));
    c.id = `cw_cont_${Date.now()}_${idx}`;
    if (/^Container #\d+$/.test(c.name || '')) c.name = `Container #${idx}`;
    return c;
  };
  function setPerRound(v) {
    if (locked) return;
    const n = Math.floor(Number(v));
    containerWars.containersPerRound = Number.isFinite(n) && n >= 1 ? n : 1;
  }
  // "Rounds" sets how many lots there are: perRound × rounds. New rounds start as a copy of the round before (the
  // same slots, so only what differs needs editing); fewer rounds drop the lots at the end, after asking.
  async function setRounds(v) {
    if (locked) return;
    const r = Math.max(1, Math.floor(Number(v)) || 1);
    const want = Math.min(MAX_LOTS, perRound * r);
    const have = containers.length;
    if (want === have) return;
    if (want > have) {
      const next = [...containers];
      for (let k = have; k < want; k++) next.push(k >= perRound ? lotCopy(next[k - perRound], k + 1) : blankLot(k + 1));
      containerWars.containers = next;
      if (perRound * r > MAX_LOTS) notice = `The most lots one event can hold is ${MAX_LOTS}.`;
    } else {
      const ok = await confirmAction(`Remove the last ${have - want} lot${have - want === 1 ? '' : 's'} (their bids and rewards are lost)?`, { title: 'Fewer rounds', danger: true });
      if (!ok) return;
      containerWars.containers = containers.slice(0, want);
    }
    syncLotCount();
  }
  async function copyRoundToAll(round) {
    if (locked || totalRounds < 2) return;
    const ok = await confirmAction(`Copy the model, bids and rewards of Round ${round} onto the same slots of every other round? What those lots have now is replaced (their names stay).`, { title: 'Copy round to all rounds', confirmLabel: 'Copy' });
    if (!ok) return;
    const src = containers.slice((round - 1) * perRound, round * perRound);
    containerWars.containers = containers.map((c, i) => {
      if (Math.floor(i / perRound) + 1 === round) return c;
      const from = src[i % perRound];
      if (!from) return c;
      const f = JSON.parse(JSON.stringify(from));
      return { ...c, model: f.model, startingBid: f.startingBid, minBidIncrement: f.minBidIncrement, auctionDuration: f.auctionDuration, rewards: f.rewards };
    });
    notice = `Round ${round} copied to the other ${totalRounds - 1} round${totalRounds === 2 ? '' : 's'}.`;
  }
  // ── each round's announcement banner ──────────────────────────────────────
  // containerWars.rounds[n-1] = { title, message }: the banner everyone sees when round n begins. Empty = the default
  // text (the placeholders show what that is). {round} {rounds} {lots} {names} are filled in by the server.
  $: if (!Array.isArray(containerWars.rounds)) containerWars.rounds = [];
  $: roundBanner = (round) => (containerWars.rounds || [])[round - 1] || { title: '', message: '' };
  function setBanner(round, key, value) {
    if (locked) return;
    const next = [...(containerWars.rounds || [])];
    while (next.length < round) next.push({ title: '', message: '' });
    next[round - 1] = { ...(next[round - 1] || {}), [key]: value };
    containerWars.rounds = next;
  }
  $: defaultBannerTitle = (r) => (r.final ? 'CONTAINER WARS — FINAL ROUND' : `CONTAINER WARS — ROUND ${r.round} / ${totalRounds}`);
  const defaultBannerText = (r) => {
    const many = r.count > 1;
    if (r.final) return many ? 'The last containers are being lowered into the yard. This is the final auction — everything is on the line.' : 'The last container is being lowered into the yard. This is the final auction — everything is on the line.';
    return many ? 'The harbour crane is placing the containers into the staging area...' : 'The harbour crane is placing the container into the staging area...';
  };
  $: fillBanner = (text, r) => {
    const names = containers.slice(r.start - 1, r.end).map((c, k) => c.name || `Container #${r.start + k}`).join(', ');
    return String(text || '')
      .split('{round}').join(String(r.round))
      .split('{rounds}').join(String(totalRounds))
      .split('{lots}').join(String(r.count))
      .split('{names}').join(names);
  };

  // collapsible rounds in the lot list (round 1 starts open; a single round is always open)
  let openRounds = { 1: true };
  $: isOpen = (round) => totalRounds === 1 || !!openRounds[round];   // reactive, or clicking a round's header would not redraw
  const toggleRound = (round) => (openRounds = { ...openRounds, [round]: !openRounds[round] });
  const setAllRounds = (open) => (openRounds = Object.fromEntries(Array.from({ length: totalRounds }, (_, r) => [r + 1, open])));
  // cash prizes of one round, for the header of a collapsed round
  $: roundCash = (r) => containers.slice(r.start - 1, r.end).reduce((sum, c) => sum + (c.rewards || []).reduce((s, w) => s + (w.type === 'MONEY' ? Number(w.amount) || 0 : 0), 0), 0);
  const fmtMoney = (n) => '$' + Math.round(n).toLocaleString('en-US');

  // ── Test Crane Run ─────────────────────────────────────────────────────────
  let testIndex = 0; // 0 = all cranes (full sequence), 1..N = specific spot
  $: testCount = Math.max(1, totalCount, pickups.length, drops.length);
  $: if (testIndex > testCount) testIndex = 0;
  async function testRun() {
    notice = '';
    if (!harbour || !hasCoords(drops[0] || harbour.drop)) {
      notice = 'The harbour has no drop spot in config.lua (Config.ContainerWars.harbour.drops).';
      return;
    }
    setBusy('test', true);
    let res = null;
    const cycleAll = testIndex === 0;
    const runIdx = cycleAll ? 1 : testIndex;
    try {
      const near = pickups[runIdx - 1] && hasCoords(pickups[runIdx - 1]) ? pickups[runIdx - 1] : (drops[runIdx - 1] || drops[0] || harbour.drop);
      await teleportToPosition(near.x + 12, near.y, near.z + 1.0);
      res = await testContainerWarsCrane({
        model: containers[runIdx - 1]?.model || pickups[runIdx - 1]?.model || 'prop_container_05a',
        index: runIdx,
        cycleAll,
        travelSeconds: containerWars.craneTravelSeconds, liftHeight: containerWars.craneLiftHeight,
        carryPath: containerWars.carryPath, carryCurve: containerWars.carryCurve,
      });
    } catch (e) {
      res = null;
    } finally {
      setBusy('test', false);
    }
    if (!res) notice = 'The game did not answer — is the resource running?';
    else if (res.ok === false) {
      notice = res.error === 'invalid_model' ? 'That container model could not be loaded.'
        : res.error === 'busy' ? 'A test run is already playing.'
        : res.error === 'test_failed' ? 'The test run stopped on an error (details in F8).'
        : 'The test run could not start.';
    }
  }

  // ── saving harbour & placers ───────────────────────────────────────────────
  async function saveHarbour(payload) {
    let res = null;
    try { res = await invoke('nova_convoytruck:harbour:save', payload); } catch (e) { res = null; }
    if (res && res.ok) {
      bootstrap.update((b) => ({ ...b, containerWars: { ...(b?.containerWars || {}), harbour: res.harbour, craneResolved: res.craneResolved, cranesResolved: res.cranesResolved, craneAssign: res.craneAssign } }));
      return true;
    }
    notice = (res && res.error) || 'Could not save the harbour layout.';
    return false;
  }

  async function updateSpotProp(index, patch) {
    const next = pickups.map((p, i) => (i === index ? { ...p, ...patch } : { ...p }));
    // Whatever container model is configured in the Container Spot section automatically reflects in the Reward section
    if (patch.model && Array.isArray(containerWars.containers)) {
      containerWars.containers = containerWars.containers.map((c, lotIdx) => {
        if (spotOf(lotIdx) === index + 1) {
          return { ...c, model: patch.model };
        }
        return c;
      });
    }
    await saveHarbour({ pickups: next });
  }

  async function updateDropProp(index, patch) {
    const next = drops.map((d, i) => (i === index ? { ...d, ...patch } : { ...d }));
    await saveHarbour({ drops: next });
  }

  const PLACER_ERRORS = {
    spawn_failed: 'The game could not create that hologram. Check the model name in config.lua.',
    no_gantry: 'The crane model has no gantry description in config.lua.',
    placer_error: 'The placer stopped on an error (details in F8).',
    busy: 'A placer is already open.',
  };

  async function place(kind, index) {
    if (busy.place || busy.test) return;
    notice = '';
    setBusy('place', true);
    const list = kind === 'pickup' ? pickups : drops;
    const cur = kind === 'crane' ? cranes[index] : list[index];
    let res = null;
    try {
      res = await startHarbourPlacer({
        kind, index: index + 1,
        model: cur?.model || containers[index]?.model || 'prop_container_05a',
        x: cur?.x, y: cur?.y, z: cur?.z, heading: cur?.heading,
      });
    } catch (e) { res = null; }
    setBusy('place', false);
    if (!res) { notice = 'The game did not answer — is the resource running?'; return; }
    if (!res.ok) { if (res.error) notice = PLACER_ERRORS[res.error] || 'The placer could not start.'; return; }

    let saved;
    if (kind === 'crane') {
      const next = cranes.map(craneRow);
      next[index] = { ...(next[index] || {}), x: res.x, y: res.y, z: res.z, heading: res.heading };
      saved = await saveHarbour({ cranes: next, crane: { auto: false } });
    } else {
      const next = list.map((p) => ({ ...p }));
      next[index] = { ...(next[index] || {}), x: res.x, y: res.y, z: res.z, heading: res.heading };
      saved = await saveHarbour(kind === 'pickup' ? { pickups: next } : { drops: next });
    }
    if (!saved) return;
    testIndex = kind === 'crane' ? 1 : Math.min(testCount, index + 1);
    notice = 'Position saved. Use "Test Crane Run" on the right side to watch.';
  }

  async function removeCrane(index) {
    if (busy.place || busy.test) return;
    // spots hold their crane as a number ("crane #2"), so the numbers above the removed crane shift down with the list
    const spots = reindexAfterRemoval(pickups, 'assignedCrane', index + 1);
    if (await saveHarbour({ cranes: cranes.filter((_, i) => i !== index).map(craneRow), pickups: spots })) notice = `Crane #${index + 1} removed.`;
  }

  async function removeSpot(kind, index) {
    if (busy.place || busy.test) return;
    const list = kind === 'pickup' ? pickups : kind === 'drop' ? drops : dummies;
    const next = list.filter((_, i) => i !== index);
    // spots hold their drop pad as a number ("drop #3"), so removing a drop pad re-points the spots that used it
    const payload = kind === 'pickup' ? { pickups: next }
      : kind === 'drop' ? { drops: next, pickups: reindexAfterRemoval(pickups, 'assignedDrop', index + 1) }
      : { dummies: next };
    if (await saveHarbour(payload)) notice = 'Removed.';
  }

  // ── spots management ───────────────────────────────────────────────────────

  // ── PROP SPAWN MODE for the harbour stacks (preview only) ───────────────────
  // The stacks stand in the world only while a Container Wars event runs (the server builds them at its start). Spawn Mode
  // shows local copies on this admin's client so the layout can be checked first; they are removed when it is turned off
  // and, by the server, the moment an event starts and builds the real ones (so nothing is doubled).
  let spawnOn = false;
  let spawnNonce = 0;
  let spawnNotice = '';
  let spawnFails = [];
  let spawnTimer;
  $: spawnList = dummies.map((d, i) => ({ ...d, key: `harbour-dummy:${d.uid || i}` }));

  async function runSpawn(list) {
    if (!spawnOn) return;
    // the parked gantry cranes (frame, cabin, wheels) are previewed with the stacks
    let parts = [];
    try { const r = await invoke('nova_convoytruck:harbour:craneParts'); if (r && r.ok) parts = r.parts || []; } catch (e) { /* stacks only */ }
    let res = null;
    try { res = await previewPlacedProps([...list, ...parts]); } catch (e) { res = null; }
    if (!spawnOn) { clearPlacedPreview(); return; }
    if (!res) { spawnNotice = 'The game did not answer — is the resource running?'; return; }
    spawnFails = Array.isArray(res.failed) ? res.failed : [];
    const cranes = new Set(parts.map((q) => String(q.key).split(':')[1])).size;
    spawnNotice = spawnFails.length
      ? `Spawn Mode: ON — ${spawnFails.length} object(s) could not be created (model missing in this game build).`
      : `Spawn Mode: ON — ${list.length} stack(s) and ${cranes} crane(s) previewed in the world. They are replaced by the real ones when an event starts.`;
  }
  const scheduleSpawn = (list) => { clearTimeout(spawnTimer); spawnTimer = setTimeout(() => runSpawn(list), 150); };
  // whenever the saved stacks change while the mode is on (add / edit / remove show up at once)
  $: if (spawnOn && !busy.place) scheduleSpawn(spawnList, spawnNonce);

  async function toggleSpawn() {
    if (spawnOn) {
      spawnOn = false; spawnFails = [];
      window.__novaSpawnOwner = null;
      clearTimeout(spawnTimer);
      clearPlacedPreview();
      spawnNotice = 'Spawn Mode: OFF — preview removed. The saved stacks are untouched.';
      return;
    }
    // a running event already has the real stacks standing: a preview on top would double them
    let live = false;
    try { const r = await invoke('nova_convoytruck:harbour:get'); live = !!(r && r.dummiesLive); } catch (e) { /* assume not live */ }
    if (live) { spawnNotice = 'A Container Wars event is running, so the stacks are already standing in the world. No preview needed.'; return; }
    spawnFails = [];
    spawnOn = true;
    window.__novaSpawnOwner = 'cw-harbour';
    spawnNotice = dummies.length ? 'Spawn Mode: ON — spawning the saved stacks…' : 'Spawn Mode: ON — no stacks are saved yet; the gantry cranes and whatever you place will appear here.';
  }
  // the server clears every preview when an event starts (the real stacks take over) and the placer clears it when it opens
  const onSpawnMessage = (e) => { if (e && e.data && e.data.action === 'propSpawnMode:reset' && !busy.place) { spawnOn = false; spawnFails = []; window.__novaSpawnOwner = null; } };
  // Closing the tablet (Esc) unmounts this view but the preview must keep standing so it can be walked up to; it
  // is only removed when the mode is turned off, when this tab is left with the tablet open, or by the server.
  // Reopening the tablet picks the standing preview up again.
  onMount(async () => {
    window.addEventListener('message', onSpawnMessage);
    if (window.__novaSpawnOwner !== 'cw-harbour') return;
    try {
      const s = await placedPreviewStatus();
      if (s && s.count > 0) { spawnOn = true; spawnNotice = 'Spawn Mode: ON — the preview from before is still standing.'; }
      else window.__novaSpawnOwner = null;
    } catch (e) { /* stays off */ }
  });
  onDestroy(() => {
    window.removeEventListener('message', onSpawnMessage);
    clearTimeout(spawnTimer);
    if (spawnOn && get(tabletOpen)) { clearPlacedPreview(); window.__novaSpawnOwner = null; }
  });

  // ── Prop Placer integration for dummy stacks ───────────────────────────────
  async function placeDummies(selectIndex) {
    if (busy.place || busy.test) return;
    notice = '';
    setBusy('place', true);
    const spawnWasOn = spawnOn;
    let current = dummies;
    try {
      const fresh = await invoke('nova_convoytruck:harbour:get');
      if (fresh && fresh.ok && fresh.harbour) {
        current = fresh.harbour.dummies || [];
        bootstrap.update((b) => ({ ...b, containerWars: { ...(b?.containerWars || {}), harbour: fresh.harbour, craneResolved: fresh.craneResolved, cranesResolved: fresh.cranesResolved, craneAssign: fresh.craneAssign } }));
      }
    } catch (e) { /* use cached */ }
    // no anchor: starts over the dummies that exist now, or at the player when there are none
    let res = null;
    try {
      res = await openPropPlacer({
        context: 'container_yard',
        title: 'Harbour dummy containers',
        objects: current,
        selectIndex,
      });
    } catch (e) { res = null; }
    setBusy('place', false);
    if (spawnWasOn) { spawnOn = true; spawnNonce += 1; }
    if (!res) { notice = 'The game did not answer — is the resource running?'; return; }
    if (!res.ok) { if (res.error) notice = PLACER_ERRORS[res.error] || 'The placer could not start.'; return; }
    const kept = (res.objects || []).slice(0, maxDummies);
    const pods = kept.reduce((n, o) => n + Math.max(1, Number(o.stack) || 1), 0);
    if (await saveHarbour({ dummies: kept })) {
      notice = kept.length
        ? `Saved ${kept.length} dummy stack(s) (${pods} containers) in the harbour.`
        : 'All dummy containers removed.';
    }
  }

  async function setAllDummies(patch) {
    if (!dummies.length) return;
    if (await saveHarbour({ dummies: dummies.map((d) => ({ ...d, ...patch })) })) notice = 'Updated every dummy.';
  }
  async function clearDummies() {
    if (await saveHarbour({ dummies: [] })) notice = 'All dummy containers removed.';
  }
  async function setAuto(on) {
    if (busy.place || busy.test) return;
    if (await saveHarbour({ crane: { auto: on } })) {
      notice = on ? 'Crane auto-centering enabled. Press Test Crane Run to preview.' : 'Manual crane position locked.';
    }
  }

  // ── saved templates ────────────────────────────────────────────────────────
  $: yardPayload = {
    yard: {
      crane: harbour?.crane && hasCoords(craneNow) ? { x: craneNow.x, y: craneNow.y, z: craneNow.z, heading: craneNow.heading || 0, auto: harbour.crane.auto === true } : null,
      cranes: cranes.map(craneRow),
      pickups: pickups.map((p) => ({ ...p })),
      drops: drops.map((p) => ({ ...p })),
      dummies: dummies.map((d) => ({ ...d })),
      carry: harbour?.carry || {},
      props: Array.isArray(props) ? props.map((p) => ({ ...p })) : [],
    },
    zone: { points: containerWars.zone?.points || [] },
    props: Array.isArray(props) ? props.map((p) => ({ ...p })) : [],
  };
  async function applyYardTemplate(e) {
    const res = e.detail;
    if (!res || res.kind !== 'CONTAINER_WARS' || !res.yard) return;
    const y = res.yard;
    const payload = { pickups: y.pickups || [], drops: y.drops || [], dummies: y.dummies || [], carry: y.carry || {} };
    if (Array.isArray(y.cranes) && y.cranes.length) payload.cranes = y.cranes.map(craneRow);
    if (y.crane && y.crane.x != null) payload.crane = { x: y.crane.x, y: y.crane.y, z: y.crane.z, heading: y.crane.heading || 0, auto: y.crane.auto === true };
    if (await saveHarbour(payload)) {
      if (!locked && res.zone && (res.zone.points || []).length >= 3) containerWars.zone = { points: res.zone.points };
      if (res.props || res.eventProps) props = res.props || res.eventProps || [];
      notice = `Loaded layout "${res.name}". Dummies and props are rebuilt in world.`;
    }
  }

  // ── bidding perimeter actions ──────────────────────────────────────────────
  async function recordZone() {
    if (locked) return;
    isRecordingZone = true;
    try { await drawContainerWarsPerimeter(); } finally { isRecordingZone = false; }
  }
  const clearZone = () => { if (!locked) containerWars.zone = { points: [] }; };
  $: fallbackZ = (drops[0] || harbour?.drop)?.z ?? 6.0;
  async function previewZone(teleport) {
    const pts = zoneReady ? zonePoints : (harbour?.zone?.points || []);
    if (pts.length < 3 || busy.zone) return;
    setBusy('zone', true);
    if (teleport) {
      const p = pts[0];
      await teleportToPosition(p.x, p.y, (p.z && Math.abs(p.z) > 0.01) ? p.z : fallbackZ);
    }
    await previewContainerWarsZone(pts, fallbackZ);
    setBusy('zone', false);
  }

  // ── bulk auction defaults ──────────────────────────────────────────────────
  let bulk = { startingBid: 5000, minBidIncrement: 1000, auctionDuration: 45 };
  let bulkInit = false;
  $: if (!bulkInit && cat.defaults) {
    bulkInit = true;
    bulk = { startingBid: num(cwd.startingBid, 5000), minBidIncrement: num(cwd.minBidIncrement, 1000), auctionDuration: num(cwd.auctionDuration, 45) };
  }
  function applyBulk() {
    if (locked) return;
    containerWars.containers = containers.map((c) => ({
      ...c,
      startingBid: Number(bulk.startingBid) || 0,
      minBidIncrement: Number(bulk.minBidIncrement) || 100,
      auctionDuration: clampInt(bulk.auctionDuration, 15, 300, num(cwd.auctionDuration, 45)),
    }));
  }
  let selectedBatchSlot = 0;
  function resetLotToDefaults(idx) {
    if (locked || !containers[idx]) return;
    const next = [...containers];
    next[idx] = {
      ...next[idx],
      startingBid: Number(bulk.startingBid) || 5000,
      minBidIncrement: Number(bulk.minBidIncrement) || 1000,
      auctionDuration: clampInt(bulk.auctionDuration, 15, 300, num(cwd.auctionDuration, 45)),
    };
    containerWars.containers = next;
  }
  function applyDefaultsToSlot(slotNum) {
    if (locked || !slotNum) return;
    containerWars.containers = containers.map((c, i) => {
      if (spotOf(i) === Number(slotNum)) {
        return {
          ...c,
          startingBid: Number(bulk.startingBid) || 5000,
          minBidIncrement: Number(bulk.minBidIncrement) || 1000,
          auctionDuration: clampInt(bulk.auctionDuration, 15, 300, num(cwd.auctionDuration, 45)),
        };
      }
      return c;
    });
    notice = `Applied default bid rules to all lots using Yard Slot #${slotNum}.`;
    setTimeout(() => { if (notice) notice = ''; }, 3500);
  }
  function applyEscalatingBids() {
    if (locked || !containers.length) return;
    const base = Number(bulk.startingBid) || 5000;
    const step = Number(bulk.minBidIncrement) || 1000;
    containerWars.containers = containers.map((c, i) => {
      const lotStart = Math.round((base + i * (step * 2)) / 500) * 500;
      return {
        ...c,
        startingBid: lotStart,
        minBidIncrement: step,
      };
    });
    notice = 'Applied ascending tiered starting bids across all lots.';
    setTimeout(() => { if (notice) notice = ''; }, 3500);
  }
  const resetTiming = () => { if (!locked) containerWars = { ...containerWars, ...TIMING_DEFAULTS }; };

  // ── Reward Vehicle Safe Staging Area ─────────────────────────────────────
  const hasVehicleReward = (rewards) => {
    return (rewards || []).some((r) => String(r.type || r.rewardType || '').toUpperCase() === 'VEHICLE');
  };

  const getFirstVehicleModel = (rewards) => {
    const found = (rewards || []).find((r) => String(r.type || r.rewardType || '').toUpperCase() === 'VEHICLE');
    return (found && (found.model || found.pool)) || 'sultan';
  };

  const placeLotVehicleSafe = async (lotIdx, model = 'sultan') => {
    if (locked) return;
    const c = containers[lotIdx];
    if (!c) return;
    setBusy('placeVehSafe', true);
    const cur = c.vehicleSafeCoords || containerWars.vehicleSafeCoords || {};
    let res = null;
    try {
      res = await startHarbourPlacer({
        kind: 'vehicle',
        model: model || 'sultan',
        x: cur.x, y: cur.y, z: cur.z, heading: cur.heading,
        label: `Lot #${lotIdx + 1} Reward Vehicle Staging`,
      });
    } catch (e) { res = null; }
    setBusy('placeVehSafe', false);
    if (!res || !res.ok) return;
    c.vehicleSafeCoords = {
      x: Number(res.x.toFixed(2)),
      y: Number(res.y.toFixed(2)),
      z: Number(res.z.toFixed(2)),
      heading: Number((res.heading || 0).toFixed(1)),
    };
    containers = [...containers];
    notice = `Lot #${lotIdx + 1} vehicle staging spot set at X: ${c.vehicleSafeCoords.x}, Y: ${c.vehicleSafeCoords.y}.`;
  };

  const setLotVehicleSafeCurrent = async (lotIdx) => {
    if (locked) return;
    const c = containers[lotIdx];
    if (!c) return;
    try {
      const pos = await getPlayerPosition();
      if (pos && pos.x != null) {
        c.vehicleSafeCoords = {
          x: Number(pos.x.toFixed(2)),
          y: Number(pos.y.toFixed(2)),
          z: Number(pos.z.toFixed(2)),
          heading: Number((pos.heading || 0).toFixed(1)),
        };
        containers = [...containers];
        notice = `Lot #${lotIdx + 1} vehicle staging spot set to your current position.`;
      }
    } catch (e) {}
  };

  const teleportToLotVehicleSafe = async (lotIdx) => {
    const c = containers[lotIdx];
    const cur = (c && c.vehicleSafeCoords) || containerWars.vehicleSafeCoords;
    if (cur && cur.x != null) {
      await teleportToPosition(cur.x, cur.y, cur.z, cur.heading);
    }
  };

  const clearLotVehicleSafe = (lotIdx) => {
    if (locked) return;
    const c = containers[lotIdx];
    if (!c) return;
    c.vehicleSafeCoords = null;
    containers = [...containers];
    notice = `Lot #${lotIdx + 1} vehicle staging spot reset to default.`;
  };
</script>

<div class="cw">
  <!-- Top Bar -->
  <div class="preset-bar">
    <div class="preset-info">
      <Icon name={section === 'props' ? 'move' : (section === 'auction' ? 'shield' : (section === 'lots' ? 'award' : 'box'))} size={15} />
      <span>
        {#if section === 'yard'}
          Container Wars — {harbour?.label || 'Terminal Harbour'} Logistics
        {:else if section === 'props'}
          Container Wars — Harbour Decor &amp; Dummy Stacks
        {:else if section === 'lots'}
          Container Wars — Lots, Rewards &amp; Arena Access
        {:else}
          Container Wars — Auction Rules &amp; Pacing
        {/if}
      </span>
    </div>
    <div class="actions">
    </div>
  </div>

  {#if notice}<div class="notice">{notice}</div>{/if}

  {#if section === 'auction' || section === 'lots'}
    <SubTabs tabs={AUCTION_SUBS} bind:active={auctionSub} />
  {/if}

  <!-- Layout with Main Form (Full Width) -->
  <div class="cw-layout cw-layout-full">
    <div class="cw-main full-width">

      <!-- ═════════ SECTION 1: YARD / HARBOUR LOGISTICS ═════════ -->
      {#if section === 'yard'}
        <!-- Gantry Fleet & Simulation Card -->
        <section class="card">
          <header class="card-head">
            <div class="step">1</div>
            <div>
              <h3>Gantry Crane Fleet &amp; Simulation</h3>
              <p>Place and manage heavy gantry cranes. Each crane serves spots along its rail travel line and trolley span.</p>
            </div>
            <div class="actions">
              {#if cranes.length < MAX_CRANES}
                <button type="button" class="btn btn-sm btn-primary" on:click={() => place('crane', cranes.length)} disabled={busy.place || busy.test}>
                  <Icon name="plus" size={12} /><span>Add Crane #{cranes.length + 1}</span>
                </button>
              {/if}
              {#if cranes.length <= 1 && !harbour?.crane?.auto}
                <button type="button" class="btn btn-sm" on:click={() => setAuto(true)} disabled={busy.place || busy.test} title="Auto-center crane position">
                  <Icon name="refresh" size={12} /><span>Auto-Center</span>
                </button>
              {/if}
            </div>
          </header>

          {#if harbour}
            <SavedTemplatePicker
              kind="CONTAINER_WARS"
              payload={yardPayload}
              locked={false}
              replaceWarning="Loading replaces cranes, container spots, drop points, dummy containers, and planned paths for the entire server."
              on:import={applyYardTemplate}
            />
          {/if}

          {#if !harbour}
            <p class="hint warn">Harbour configuration is missing from config.lua (Config.ContainerWars.harbour).</p>
          {:else}
            <div class="plan">
              <div class="plan-head">
                <b>Active Gantries ({cranes.length} / {MAX_CRANES})</b>
                <span>Model: {harbour.crane?.model || 'prop_dock_rtg_ld'}</span>
              </div>
              {#each cranes as c, i}
                {@const serves = craneServes(craneAssign, i)}
                <div class="yard-row">
                  <div class="mono">
                    <span class="idx-badge">Crane #{i + 1}</span>
                    <span>{fmt(c.x)}, {fmt(c.y)}, {fmt(c.z)} · {fmt(c.heading)}°</span>
                    <small class="muted"> — {serves.length ? `Carries spot${serves.length > 1 ? 's' : ''} ${serves.map((n) => '#' + n).join(', ')}` : 'Currently idle (no assigned spots)'}</small>
                  </div>
                  <div class="actions">
                    <button type="button" class="btn btn-xs btn-preview" on:click={() => place('crane', i)} disabled={busy.place || busy.test}>
                      <Icon name="eye" size={11} /><span>Position Hologram</span>
                    </button>
                    <button type="button" class="btn btn-xs btn-teleport" on:click={() => teleportTo(c)} disabled={!hasCoords(c)} title="Teleport to this gantry">
                      <Icon name="teleport" size={11} /><span>Teleport</span>
                    </button>
                    <button type="button" class="btn btn-xs btn-danger" on:click={() => removeCrane(i)} disabled={busy.place || busy.test} title="Remove this crane"><Icon name="close" size={11} /></button>
                  </div>
                </div>
              {/each}
              {#if !cranes.length}
                <div class="yard-row"><div class="mono muted">No cranes configured. Add a crane hologram below.</div></div>
              {/if}
            </div>

            <!-- Integrated Simulation & Test Run Bar -->
            <div class="sim-box">
              <div class="sim-header">
                <div class="sim-title">
                  <Icon name="play" size={13} />
                  <b>Live Crane Simulation &amp; Audio Preview</b>
                </div>
                <div class="audio-sync-badge">
                  <Icon name="volume" size={11} />
                  <span>Audio Sync: Hoist, trolley travel, container placement &amp; hydraulic release</span>
                </div>
              </div>
              <div class="sim-controls">
                <div class="sim-select-wrap">
                  <label for="cw-sim-select">Simulation Target:</label>
                  <select id="cw-sim-select" bind:value={testIndex} disabled={busy.test || busy.place}>
                    <option value={0}>▶ Test All Cranes (Full Sequential Cycle)</option>
                    {#each pickups as p, pi}
                      <option value={pi + 1}>Container #{pi + 1} (Crane #{linkageMatrix[pi]?.effectiveCraneIdx || 1} → Drop #{linkageMatrix[pi]?.assignedDropIdx || 1})</option>
                    {/each}
                  </select>
                </div>
                <button type="button" class="btn btn-primary" on:click={testRun} disabled={busy.test || busy.place || !harbour || !pickups.length}>
                  <Icon name="play" size={13} />
                  <span>{busy.test ? 'Simulating Crane…' : (testIndex === 0 ? 'Run All Cranes Test' : `Run Crane Simulation (#${testIndex})`)}</span>
                </button>
              </div>
            </div>
          {/if}
        </section>

        <!-- Container Spots Card -->
        <section class="card">
          <header class="card-head">
            <div class="step">2</div>
            <div>
              <h3>Container Pickup Spots</h3>
              <p>Configure prize container locations, assign physical container props, and link specific cranes.</p>
            </div>
            <div class="actions">
              {#if pickups.length < MAX_CONTAINERS}
                <button type="button" class="btn btn-xs btn-primary" on:click={() => place('pickup', pickups.length)} disabled={busy.place || busy.test}>
                  <Icon name="plus" size={11} /><span>Add Spot #{pickups.length + 1}</span>
                </button>
              {/if}
            </div>
          </header>

          <div class="rows-scroll">
            <div class="rows-inner spot-rows">
              <div class="row-head spot-row-cols">
                <span>Spot</span>
                <span>Assigned Crane</span>
                <span>Delivery Drop</span>
                <span>Container Model</span>
                <span>Position</span>
                <span>Placement</span>
                <span></span>
              </div>
              {#each pickups as p, i}
                {@const lInfo = linkageMatrix[i]}
                <div class="list-row spot-row-cols" class:has-warn={lInfo.status !== 'ok'}>
                  <div class="cell spot-id">
                    <span class="idx-badge">Spot #{i + 1}</span>
                    <span class="status-badge {lInfo.status}">{lInfo.label}</span>
                  </div>

                  <div class="cell">
                    <select aria-label="Assigned crane for spot {i + 1}" value={p.assignedCrane || ''} on:change={(e) => updateSpotProp(i, { assignedCrane: e.target.value ? Number(e.target.value) : null })}>
                      <option value="">Auto (Closest Reachable)</option>
                      {#each cranes as _, ci}
                        <option value={ci + 1}>Crane #{ci + 1}</option>
                      {/each}
                    </select>
                  </div>

                  <div class="cell">
                    <select aria-label="Delivery drop for spot {i + 1}" value={p.assignedDrop || (i + 1)} on:change={(e) => updateSpotProp(i, { assignedDrop: Number(e.target.value) })}>
                      {#each drops as _, di}
                        <option value={di + 1}>Drop Pad #{di + 1}</option>
                      {/each}
                    </select>
                  </div>

                  <div class="cell">
                    <select class="model-select" aria-label="Container model for spot {i + 1}" title={(containerChoices.find((m) => m.id === (p.model || 'tr_prop_tr_container_01a')) || {}).label} value={p.model || 'tr_prop_tr_container_01a'} on:change={(e) => updateSpotProp(i, { model: e.target.value })}>
                      {#each containerChoices as m}
                        <option value={m.id} title={m.label}>{shortLabel(m.label)}</option>
                      {/each}
                    </select>
                  </div>

                  <div class="cell mono coords">
                    <span>{fmt(p.x)}, {fmt(p.y)}, {fmt(p.z)} · {fmt(p.heading)}°</span>
                    {#if p.mapModel}<small class="muted">Hides map prop: {p.mapModel}</small>{/if}
                  </div>

                  <div class="cell actions">
                    <button type="button" class="btn btn-xs btn-preview" on:click={() => place('pickup', i)} disabled={busy.place || busy.test}>
                      <Icon name="eye" size={11} /><span>Hologram</span>
                    </button>
                    <button type="button" class="btn btn-xs btn-teleport" on:click={() => teleportTo(p)} disabled={!hasCoords(p)} title="Teleport to this spot">
                      <Icon name="teleport" size={11} /><span>Teleport</span>
                    </button>
                  </div>

                  <button type="button" class="btn-x" on:click={() => removeSpot('pickup', i)} disabled={busy.place || busy.test} title="Remove spot">
                    <Icon name="trash" size={12} />
                  </button>
                </div>
              {/each}
            </div>
          </div>
        </section>

        <!-- Drop Pads Card -->
        <section class="card">
          <header class="card-head">
            <div class="step">3</div>
            <div>
              <h3>Container Drop Pads</h3>
              <p>Where the gantry crane sets down the containers on the ground inside the auction area.</p>
            </div>
            <div class="actions">
              {#if drops.length < MAX_CONTAINERS}
                <button type="button" class="btn btn-xs btn-primary" on:click={() => place('drop', drops.length)} disabled={busy.place || busy.test}>
                  <Icon name="plus" size={11} /><span>Add Drop Pad #{drops.length + 1}</span>
                </button>
              {/if}
            </div>
          </header>

          <div class="rows-scroll">
            <div class="rows-inner drop-rows">
              <div class="row-head drop-row-cols">
                <span>Drop Pad</span>
                <span>Delivers</span>
                <span>Position</span>
                <span>Placement</span>
                <span></span>
              </div>
              {#each drops as d, i}
                {@const delivSpots = dropServes(i + 1)}
                <div class="list-row drop-row-cols">
                  <div class="cell"><span class="idx-badge">Drop Pad #{i + 1}</span></div>
                  <div class="cell">
                    <span class="chip">
                      {delivSpots.length ? `Delivers Spot${delivSpots.length > 1 ? 's' : ''} ${delivSpots.map((n) => '#' + n).join(', ')}` : 'No spots targeting this pad'}
                    </span>
                  </div>
                  <div class="cell mono coords">
                    <span>{fmt(d.x)}, {fmt(d.y)}, {fmt(d.z)} · {fmt(d.heading)}°</span>
                  </div>
                  <div class="cell actions">
                    <button type="button" class="btn btn-xs btn-preview" on:click={() => place('drop', i)} disabled={busy.place || busy.test}>
                      <Icon name="eye" size={11} /><span>Hologram</span>
                    </button>
                    <button type="button" class="btn btn-xs btn-teleport" on:click={() => teleportTo(d)} disabled={!hasCoords(d)} title="Teleport to this drop pad">
                      <Icon name="teleport" size={11} /><span>Teleport</span>
                    </button>
                  </div>
                  <button type="button" class="btn-x" on:click={() => removeSpot('drop', i)} disabled={busy.place || busy.test} title="Remove drop pad">
                    <Icon name="trash" size={12} />
                  </button>
                </div>
              {/each}
            </div>
          </div>
        </section>
      {/if}

    <!-- ═════════ SECTION 2: PROPS & DUMMIES ═════════ -->
    {#if section === 'props'}
        <!-- Harbour Decor & Dummy Stacks (Prop Placer Integration) -->
        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="box" size={14} /></div>
            <div>
              <h3>Harbour Decor &amp; Dummy Stacks</h3>
              <p>Decorative container stacks placed with the shared <b>Prop Placer</b>. They stand in the harbour only while a Container Wars event is running; use Spawn Mode to preview them.</p>
            </div>
            <div class="actions">
              <button type="button" class="btn btn-sm btn-primary" on:click={() => placeDummies()} disabled={busy.place || busy.test}>
                <Icon name="move" size={12} /><span>{dummies.length ? 'Open in Prop Placer' : 'Place with Prop Placer'}</span>
              </button>
            </div>
          </header>

          <SpawnModeStrip active={spawnOn} on:toggle={toggleSpawn}
            offText="Off: the stacks and gantry cranes are only built when a Container Wars event starts."
            onText="The saved stacks and gantry cranes are standing in the world on your client. Starting an event replaces them with the real ones." />
          {#if spawnNotice}<p class="notice" style="margin:0;">{spawnNotice}</p>{/if}
          <PropTable
            items={dummies}
            locked={busy.place || busy.test}
            maxItems={maxDummies}
            modelColumnLabel="Container Model"
            stacked
            on:edit={(e) => placeDummies(e.detail + 1)}
            on:teleport={(e) => teleportTo(dummies[e.detail])}
            on:remove={(e) => removeSpot('dummy', e.detail)}
            on:removeAll={clearDummies}
            on:bulk={(e) => setAllDummies(e.detail)}
          />
        </section>
    <!-- ═════════ SECTION 3: AUCTION & REWARDS ═════════ -->
    {:else if section === 'auction' || section === 'lots'}
      {#if auctionSub === 'rules'}
        <!-- ═════════ SUB-TAB 1: AUCTION RULES & PROGRESSION ═════════ -->
        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="shield" size={14} /></div>
            <div>
              <h3>Bidding Rules &amp; Prices</h3>
              <p>Set the default bids first, then fine-tune the price of each lot. Rounds and lot order are set in Lots &amp; Arena.</p>
            </div>
            <span class="state ok">{totalCount} lot{totalCount === 1 ? '' : 's'} · {totalRounds} round{totalRounds === 1 ? '' : 's'}</span>
          </header>

          <!-- Phase 1: Bidding Rules -->
          <div class="phase-card">
            <div class="phase-head">
              <h4>Phase 1 · Default Bidding Rules</h4>
              <span>Starting bids, minimum raises, and bulk propagation across all lots.</span>
            </div>
            <div class="phase-body">
              <div class="grid3">
                <div class="field">
                  <label for="b-start">Default Starting Bid</label>
                  <div class="unit"><span class="cur">$</span><input id="b-start" type="number" min="0" step="500" bind:value={bulk.startingBid} disabled={locked} /></div>
                  <small>Opening bid applied to new lots</small>
                </div>
                <div class="field">
                  <label for="b-step">Minimum Bid Increment</label>
                  <div class="unit"><span class="cur">$</span><input id="b-step" type="number" min="100" step="100" bind:value={bulk.minBidIncrement} disabled={locked} /></div>
                  <small>Minimum raise above current highest bid</small>
                </div>
                <div class="field">
                  <label for="b-secs">Default Auction Timer</label>
                  <div class="unit"><input id="b-secs" type="number" min="15" max="300" bind:value={bulk.auctionDuration} disabled={locked} /><span>sec</span></div>
                  <small>Standard countdown time per container</small>
                </div>
              </div>

              <div class="row-end" style="margin-top: 10px;">
                <button type="button" class="btn btn-sm btn-primary apply-btn" on:click={applyBulk} disabled={locked || totalCount === 0}>
                  <Icon name="check" size={12} /><span>Apply Defaults to All {totalCount} Lots</span>
                </button>
              </div>
            </div>
          </div>

          <!-- Phase 2: Individual Container & Yard Slot Bidding Prices -->
          <div class="phase-card">
            <div class="phase-head" style="display: flex; align-items: center; justify-content: space-between;">
              <div>
                <h4>Phase 2 · Individual Container &amp; Yard Slot Bidding Prices</h4>
                <span>Fine-tune starting bids, minimum increments, and timers for each container lot or yard slot.</span>
              </div>
              <div class="matrix-head-badges" style="display: flex; gap: 8px; align-items: center;">
                <span class="chip" style="font-size: var(--fs-meta); padding: 3px 8px;">{totalCount} Lots</span>
                <span class="chip" style="font-size: var(--fs-meta); padding: 3px 8px;">{spotCount} Yard Slots</span>
              </div>
            </div>

            <div class="phase-body" style="padding: 12px 14px;">
              {#if totalCount === 0}
                <div class="empty-cell" style="text-align: center; color: var(--text-dim); padding: 20px;">
                  No container lots configured. Add lots in the "Lots &amp; Arena" tab to get started.
                </div>
              {:else}
                <!-- Slot Quick-Batch Toolbar -->
                <div class="slot-toolbar" style="display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 12px; flex-wrap: wrap;">
                  <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
                    <span style="font-size: var(--fs-meta); font-weight: 700; text-transform: uppercase; color: var(--text-dim);">Quick Tools:</span>
                    <button type="button" class="btn btn-xs btn-outline" on:click={applyEscalatingBids} disabled={locked} title="Apply progressive ascending start bids across all lots">
                      <span>📈 Ascending Tiers</span>
                    </button>
                    {#if spotCount > 0}
                      <div class="slot-batch-dropdown" style="display: flex; align-items: center; gap: 6px;">
                        <span style="font-size: var(--fs-meta); color: var(--text-dim);">By Slot:</span>
                        <select class="matrix-select" style="height: 28px; font-size: var(--fs-meta); padding: 0 6px; width: auto;" bind:value={selectedBatchSlot}>
                          <option value={0}>Select Slot...</option>
                          {#each Array.from({ length: spotCount }, (_, s) => s + 1) as slotNum}
                            <option value={slotNum}>Slot #{slotNum} (All Rounds)</option>
                          {/each}
                        </select>
                        {#if selectedBatchSlot > 0}
                          <button type="button" class="btn btn-xs btn-primary" on:click={() => applyDefaultsToSlot(selectedBatchSlot)} disabled={locked}>
                            <span>Apply Defaults to Slot #{selectedBatchSlot}</span>
                          </button>
                        {/if}
                      </div>
                    {/if}
                  </div>

                  <div style="font-size: var(--fs-meta); color: var(--text-dim);">
                    Total Opening Value: <b style="color: #55c98a;">${containers.reduce((sum, c) => sum + (Number(c.startingBid) || 0), 0).toLocaleString()}</b>
                  </div>
                </div>

                <!-- Matrix Table -->
                <div class="matrix-table-wrap">
                  <table class="matrix-table">
                    <thead>
                      <tr>
                        <th style="width: 85px;">Lot #</th>
                        <th style="width: 105px;">Yard Slot</th>
                        <th>Container Name</th>
                        <th style="width: 155px;">Starting Bid ($)</th>
                        <th style="width: 155px;">Min Increment ($)</th>
                        <th style="width: 125px;">Timer (Sec)</th>
                        <th style="width: 80px; text-align: right;">Action</th>
                      </tr>
                    </thead>
                    <tbody>
                      {#each containers as c, i}
                        {@const slotNum = spotOf(i)}
                        {@const roundNum = Math.floor(i / perRound) + 1}
                        {@const isFinal = finalOn && roundNum === totalRounds}
                        <tr class="matrix-row">
                          <td>
                            <span class="idx-badge" style="font-weight: 800;">Lot #{i + 1}</span>
                            <small style="display: block; font-size: var(--fs-meta); color: var(--text-dim);">{isFinal ? 'Final Rd' : `Round ${roundNum}`}</small>
                          </td>
                          <td>
                            <span class="chip" style="font-size: var(--fs-meta); padding: 2px 6px; background: rgba(79, 148, 230, 0.15); border: 1px solid rgba(79, 148, 230, 0.35); color: #70b4ff;">
                              Slot #{slotNum}
                            </span>
                          </td>
                          <td>
                            <input
                              type="text"
                              style="width: 100%; height: 30px; background: #181b1f; border: 1px solid #2a2e35; border-radius: 6px; color: #fff; font-size: var(--fs-meta); padding: 0 8px;"
                              bind:value={c.name}
                              placeholder={`Container #${i + 1}`}
                              disabled={locked}
                            />
                          </td>
                          <td>
                            <div class="unit" style="height: 30px;">
                              <span class="cur" style="color: #55c98a;">$</span>
                              <input
                                type="number"
                                min="0"
                                step="500"
                                style="height: 100%; font-size: var(--fs-meta); font-weight: 700; color: #55c98a;"
                                bind:value={c.startingBid}
                                disabled={locked}
                              />
                            </div>
                          </td>
                          <td>
                            <div class="unit" style="height: 30px;">
                              <span class="cur" style="color: #ffc857;">$</span>
                              <input
                                type="number"
                                min="100"
                                step="100"
                                style="height: 100%; font-size: var(--fs-meta); font-weight: 700; color: #ffc857;"
                                bind:value={c.minBidIncrement}
                                disabled={locked}
                              />
                            </div>
                          </td>
                          <td>
                            <div class="unit" style="height: 30px;">
                              <input
                                type="number"
                                min="15"
                                max="300"
                                style="height: 100%; font-size: var(--fs-meta);"
                                bind:value={c.auctionDuration}
                                disabled={locked}
                              />
                              <span style="font-size: var(--fs-meta);">s</span>
                            </div>
                          </td>
                          <td style="text-align: right;">
                            <button
                              type="button"
                              class="btn btn-xs btn-outline"
                              on:click={() => resetLotToDefaults(i)}
                              disabled={locked}
                              title="Reset this container to the default bid rules above"
                            >
                              Defaults
                            </button>
                          </td>
                        </tr>
                      {/each}
                    </tbody>
                  </table>
                </div>
              {/if}
            </div>
          </div>

        </section>

      {:else if auctionSub === 'timing'}
        <!-- ═════════ SUB-TAB 2: TIMERS & STAGE PACING ═════════ -->
        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="clock" size={14} /></div>
            <div>
              <h3>Container Event Timers &amp; Stage Pacing</h3>
              <p>Every container goes through the same 5 steps, in this order. The bar shows the step each setting below belongs to. Values are in seconds unless it says metres.</p>
            </div>
            <span class="state ok">≈ {fmtDuration(estSeconds)} total duration</span>
          </header>

          <!-- Timeline Flow Bar -->
          <div class="flow" aria-label="Timeline of one container lot">
            <div class="fs"><small>Step 0 · Countdown</small><b>{eff('startCountdownSeconds')}s</b><span>once, when the event starts</span></div>
            <div class="fa">→</div>
            <div class="fs"><small>Step 1 · Crane delivers</small><b>{Math.round((eff('craneTravelSeconds') / speedMul + hookExtraSeconds + eff('settleSeconds')) * 10) / 10}s</b><span>lift, carry, lower, settle</span></div>
            <div class="fa">→</div>
            <div class="fs"><small>Step 2 · Bids locked</small><b>{eff('openSeconds')}s</b><span>container on pad, nobody can bid yet</span></div>
            <div class="fa">→</div>
            <div class="fs hi"><small>Step 3 · Live bidding</small><b>{avgAuction}s</b><span>{Number(containerWars.antiSnipeExtendSeconds) > 0 ? `+${containerWars.antiSnipeExtendSeconds}s anti-snipe` : 'fixed duration'}</span></div>
            <div class="fa">→</div>
            <div class="fs"><small>Step 4 · Winner claims</small><b>{eff('lotGapSeconds')}s</b><span>then the next container starts at step 1</span></div>
          </div>

          <div class="phase-card">
            <div class="phase-head">
              <h4>Phase 1 · Before the Event</h4>
              <span><b>Step 0 · happens once</b> — from pressing <i>Start Container War</i> until the crane first moves.</span>
            </div>
            <div class="phase-body">
              <div class="grid2">
                <div class="field">
                  <label for="t-start">Start Countdown</label>
                  <div class="unit"><input id="t-start" type="number" min="0" max="300" bind:value={containerWars.startCountdownSeconds} on:blur={() => fixTiming('startCountdownSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>Players see a <b>STARTING SOON</b> banner while this counts down, so they can reach the docks.</small>
                </div>
              </div>
            </div>
          </div>

          <div class="phase-card">
            <div class="phase-head">
              <h4>Phase 2 · Crane Delivers the Container</h4>
              <span><b>Step 1 · repeats for every container</b> — from the hook lowering onto the container until it rests on the drop pad.</span>
            </div>
            <div class="phase-body">
              <div class="grid2">
                <div class="field">
                  <label for="t-hook-down">1. Hook Lowers Onto Container</label>
                  <div class="unit"><input id="t-hook-down" type="number" min="0.3" max="20" step="0.1" bind:value={containerWars.hookDescendSeconds} on:blur={() => fixTiming('hookDescendSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>The empty hook comes down onto the container before lifting it.</small>
                </div>
                <div class="field">
                  <label for="t-travel">2. Carry Time (lift → pad → lower)</label>
                  <div class="unit"><input id="t-travel" type="number" min="3" max="30" bind:value={containerWars.craneTravelSeconds} on:blur={() => fixTiming('craneTravelSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>The whole trip with the container on the hook: up, across to the drop pad, and down.</small>
                </div>
                <div class="field">
                  <label for="t-lift">2. Carry Height</label>
                  <div class="unit"><input id="t-lift" type="number" min="3" max="60" bind:value={containerWars.craneLiftHeight} on:blur={() => fixTiming('craneLiftHeight')} disabled={locked} /><span>m</span></div>
                  <small>How high (metres) the container is lifted while it travels sideways.</small>
                </div>
                <div class="field">
                  <label for="t-settle">3. Settle Pause After Touchdown</label>
                  <div class="unit"><input id="t-settle" type="number" min="0" max="15" bind:value={containerWars.settleSeconds} on:blur={() => fixTiming('settleSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>A short wait once the container touches the pad, before the hook lets go.</small>
                </div>
                <div class="field">
                  <label for="t-hook-return">4. Empty Hook Climbs Back</label>
                  <div class="unit"><input id="t-hook-return" type="number" min="0" max="20" step="0.5" bind:value={containerWars.hookReturnSeconds} on:blur={() => fixTiming('hookReturnSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>Only the look of the crane: how slowly the empty hook rises after letting go. 0 = same speed as lowering.</small>
                </div>
              </div>

              <!-- Carry Path Trajectory -->
              <div class="carry-mode-box" style="margin-top: 10px;">
                <span class="sub">Carry Trajectory Curve</span>
                <div class="seg seg-sm">
                  <button type="button" class:on={containerWars.carryPath !== 'STRAIGHT'} on:click={() => (containerWars.carryPath = 'CURVE')} disabled={locked}>Smooth Arc Curve</button>
                  <button type="button" class:on={containerWars.carryPath === 'STRAIGHT'} on:click={() => (containerWars.carryPath = 'STRAIGHT')} disabled={locked}>Direct Linear Line</button>
                </div>
                <small style="display:block; margin-top:6px; color:var(--text-dim); line-height:1.45;">
                  Controls how the gantry crane trolley transports the container from the pickup spot to the drop pad. <b>Direct Linear Line</b> travels directly in a straight line. <b>Smooth Arc Curve</b> swings the trolley outward in a curved arc to avoid colliding with stacked containers in the yard.
                </small>
                {#if containerWars.carryPath !== 'STRAIGHT'}
                  <div class="bend-row" style="margin-top:8px;">
                    <label for="t-bend">Arc Bend Curvature:</label>
                    <input id="t-bend" type="range" min="10" max="100" step="1" value={Math.round((Number(containerWars.carryCurve) || 0.4) * 100)} on:input={(e) => (containerWars.carryCurve = Number(e.currentTarget.value) / 100)} disabled={locked} />
                    <b>{Math.round((Number(containerWars.carryCurve) || 0.4) * 100)}%</b>
                  </div>
                {/if}
              </div>
            </div>
          </div>

          <div class="phase-card">
            <div class="phase-head">
              <h4>Phase 3 · Bidding on the Container</h4>
              <span><b>Steps 2–3 · repeats for every container</b> — the container is on the pad: first a locked pause, then live bidding.</span>
            </div>
            <div class="phase-body">
              <div class="grid3">
                <div class="field">
                  <label for="t-open">Bids Locked Pause</label>
                  <div class="unit"><input id="t-open" type="number" min="0" max="30" bind:value={containerWars.openSeconds} on:blur={() => fixTiming('openSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>The container sits closed on the pad and nobody can bid yet. Bidding opens when this ends.</small>
                </div>
                <div class="field">
                  <label for="t-snipe">Anti-Snipe: Late-Bid Window</label>
                  <div class="unit"><input id="t-snipe" type="number" min="0" max="30" bind:value={containerWars.antiSnipeWindowSeconds} disabled={locked} /><span>sec</span></div>
                  <small>If someone bids when this many seconds or fewer are left on the bidding clock, the clock is extended.</small>
                </div>
                <div class="field">
                  <label for="t-ext">Anti-Snipe: Time Added</label>
                  <div class="unit"><input id="t-ext" type="number" min="0" max="60" bind:value={containerWars.antiSnipeExtendSeconds} disabled={locked} /><span>sec</span></div>
                  <small>How many seconds a late bid adds to the clock. 0 turns anti-snipe off.</small>
                </div>
              </div>
              <small style="display:block;">How long bidding lasts is set <b>per container</b>, in the <b>Bidding Rules &amp; Prices</b> sub-tab (Default Auction Timer / Timer column).</small>
            </div>
          </div>

          <div class="phase-card">
            <div class="phase-head">
              <h4>Phase 4 · After the Container Is Sold</h4>
              <span><b>Step 4 · after each sale</b> — the winner collects the reward, then the event moves on.</span>
            </div>
            <div class="phase-body">
              <div class="grid2">
                <div class="field">
                  <label for="t-gap">Winner Claim Time</label>
                  <div class="unit"><input id="t-gap" type="number" min="5" max="120" bind:value={containerWars.lotGapSeconds} on:blur={() => fixTiming('lotGapSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>Time the winner has to open the container and take the reward before the next container starts.</small>
                </div>
                <div class="field">
                  <label for="t-break">Break Between Rounds</label>
                  <div class="unit"><input id="t-break" type="number" min="3" max="120" bind:value={containerWars.roundBreakSeconds} on:blur={() => fixTiming('roundBreakSeconds')} disabled={locked} /><span>sec</span></div>
                  <small>Extra pause after the last container of a round, before the next round begins.</small>
                </div>
              </div>
              {#if containerWars.finalRoundEnabled && totalRounds > 1}
                <div class="grid2">
                <div class="field">
                  <label for="t-fbreak">Final Round Warning Break</label>
                  <div class="unit"><input id="t-fbreak" type="number" min="3" max="300" bind:value={containerWars.finalRoundBreakSeconds} disabled={locked} /><span>sec</span></div>
                  <small>Pause with a FINAL ROUND alert before the very last container.</small>
                </div>
                <div class="field">
                  <label for="t-fauc">Final Container Bidding Time</label>
                  <div class="unit"><input id="t-fauc" type="number" min="0" max="300" bind:value={containerWars.finalRoundAuctionSeconds} disabled={locked} /><span>sec</span></div>
                  <small>Bidding time for the last container only. 0 = use its normal timer.</small>
                </div>
                </div>
              {/if}

              <div class="actions" style="justify-content: flex-end; margin-top: 4px;">
                <button type="button" class="btn btn-sm btn-outline" on:click={resetTiming} disabled={locked}>
                  <Icon name="refresh" size={12} /><span>Reset All Timing to Defaults</span>
                </button>
              </div>
            </div>
          </div>
        </section>

      {:else if auctionSub === 'auction'}
        <!-- ═════════ CONTAINER LOTS & REWARDS ═════════ -->
        <!-- Rounds first: they decide how many lots exist and how they are grouped below -->
        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="flag" size={14} /></div>
            <div>
              <h3>Rounds &amp; Auction Order</h3>
              <p>Start here: how many containers go up per round, how many rounds, and in what order. The lots below follow this layout.</p>
            </div>
            <span class="state ok">{totalCount} lot{totalCount === 1 ? '' : 's'} · {totalRounds} round{totalRounds === 1 ? '' : 's'}</span>
          </header>

              <div class="grid3">
                <div class="field">
                  <label for="cw-per-round">Containers Per Round</label>
                  <div class="unit">
                    <input id="cw-per-round" class:bad={perRoundTooBig} type="number" min="1" max={Math.max(1, spotCount)} value={perRound} on:change={(e) => setPerRound(e.target.value)} disabled={locked} />
                    <span>of {spotCount} spot{spotCount === 1 ? '' : 's'}</span>
                  </div>
                  {#if perRoundTooBig}
                    <small class="err">A round can't hold more containers than the yard has spots: {perRound} per round, but only {spotCount} spot{spotCount === 1 ? '' : 's'} placed. Lower it or add spots in Container Wars Setup.</small>
                  {:else}
                    <small>They are all craned in and auctioned one after another, then cleared for the next round.</small>
                  {/if}
                </div>

                <div class="field">
                  <label for="cw-rounds">Rounds</label>
                  <div class="unit">
                    <input id="cw-rounds" type="number" min="1" max={Math.max(1, Math.floor(MAX_LOTS / perRound))} value={totalRounds} on:change={(e) => setRounds(e.target.value)} disabled={locked || perRoundTooBig} />
                    <span>= {totalCount} lot{totalCount === 1 ? '' : 's'}</span>
                  </div>
                  <small>New rounds copy the round before; edit only what differs in the lots below. Rounds reuse the same spots.</small>
                </div>

                <div class="field">
                  <span class="lbl-heading">Auction Sequence Order</span>
                  <div class="seg seg-sm">
                    <button type="button" class:on={containerWars.auctionOrder !== 'RANDOM'} on:click={() => (containerWars.auctionOrder = 'IN_ORDER')} disabled={locked}>List Order</button>
                    <button type="button" class:on={containerWars.auctionOrder === 'RANDOM'} on:click={() => (containerWars.auctionOrder = 'RANDOM')} disabled={locked}>Randomized</button>
                  </div>
                  <small>{containerWars.auctionOrder === 'RANDOM' ? 'Shuffles all the lots (and so their rewards) across every round.' : 'Lot #1 first, then #2, #3 … in the order of the lot list.'}</small>
                </div>
              </div>

              <!-- Round List Chips -->
              <div class="rounds">
                {#each roundsList as r}
                  <div class="round-chip" class:final={r.final}>
                    <b>{r.final ? `Round ${r.round} · FINAL` : `Round ${r.round}`}</b>
                    <span>{r.count === 0 ? 'empty' : (r.count === 1 ? `Lot #${r.start}` : `Lots #${r.start}–#${r.end}`)}</span>
                  </div>
                {/each}
              </div>

              <!-- Final Round Special Banner -->
              <div class="final-round-box">
                <Toggle label="Announce the last container as the dramatic FINAL ROUND" bind:checked={containerWars.finalRoundEnabled} disabled={locked || totalRounds < 2} />
                {#if containerWars.finalRoundEnabled && totalRounds > 1}
                  <small style="display:block; margin-top:8px;">The warning break and the final lot's bidding time are set in <b>Auction Rules → Timers &amp; Pacing</b>, Phase 4.</small>
                {/if}
              </div>
        </section>


        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="box" size={14} /></div>
            <div>
              <h3>Container Auction Lots <span class="count">({totalCount} / {MAX_LOTS})</span></h3>
              <p>Each lot has its own prop model, opening bid, duration and rewards. Lots are grouped by round; a round's lots stand on the yard's spots in turn, and the next round reuses those spots.</p>
            </div>
            <div class="actions">
              {#if totalRounds > 1}
                <button type="button" class="btn btn-sm" on:click={() => setAllRounds(!roundsList.every((r) => isOpen(r.round)))}>
                  <Icon name={roundsList.every((r) => isOpen(r.round)) ? 'chevronUp' : 'chevronDown'} size={13} /><span>{roundsList.every((r) => isOpen(r.round)) ? 'Collapse rounds' : 'Expand rounds'}</span>
                </button>
              {/if}
              <button type="button" class="btn btn-primary btn-sm" on:click={addContainer} disabled={locked || totalCount >= MAX_LOTS}>
                <Icon name="plus" size={13} /><span>Add Container Lot</span>
              </button>
            </div>
          </header>

          <div class="final-round-box">
            <Toggle label="Gang XP for the winning gang of each container" bind:checked={containerWars.gangXpOnWin} disabled={locked} />
            {#if containerWars.gangXpOnWin}
              <div class="field" style="margin-top:8px; max-width:260px;">
                <label for="cw-gxp">Gang XP per container won</label>
                <div class="unit"><input id="cw-gxp" type="number" min="0" max="1000000" bind:value={containerWars.gangXpAmount} disabled={locked} /><span>XP</span></div>
              </div>
            {/if}
            <small style="display:block; margin-top:8px;">When a gang member wins a container's bidding, their gang earns this XP (car lots too) — also when the event is open to civilians. A civilian winner earns none.</small>
          </div>

          {#if perRoundTooBig}
            <div class="notice err-note">Containers per round ({perRound}) is more than the yard's {spotCount} spot{spotCount === 1 ? '' : 's'}. Fix it in Rounds &amp; Auction Order above before saving.</div>
          {/if}

          {#if totalCount === 0}
            <div class="empty">
              <Icon name="box" size={26} />
              <p>No container lots configured.</p>
              <span>Add a lot above to get started.</span>
            </div>
          {:else}
            <div class="stack">
              {#each containers as c, i (c.id || i)}
                {#if i % perRound === 0}
                  {@const r = roundsList[Math.floor(i / perRound)]}
                  <div class="round-head" class:final={r.final}>
                    <button type="button" class="round-toggle" on:click={() => toggleRound(r.round)} aria-expanded={isOpen(r.round)} disabled={totalRounds === 1}>
                      <Icon name={isOpen(r.round) ? 'chevronDown' : 'chevronRight'} size={14} />
                      <b>{r.final ? `Round ${r.round} · FINAL` : `Round ${r.round}`}</b>
                      <span>{r.count === 1 ? `Lot #${r.start}` : `Lots #${r.start}–#${r.end}`}</span>
                      <span class="round-cash">cash prizes {fmtMoney(roundCash(r))}</span>
                    </button>
                    {#if totalRounds > 1}
                      <button type="button" class="btn btn-xs" on:click={() => copyRoundToAll(r.round)} disabled={locked} title="Copy this round's model, bids and rewards onto the same slots of every other round">
                        <Icon name="copy" size={11} /><span>Copy to all rounds</span>
                      </button>
                    {/if}
                  </div>
                  {#if isOpen(r.round)}
                    {@const b = roundBanner(r.round)}
                    <div class="banner-card">
                      <div class="banner-head">
                        <Icon name="volume" size={13} />
                        <b>Round {r.round} announcement banner</b>
                        <small>Shown to everyone when this round begins. Leave empty for the default. You can use <code>{'{round}'}</code> <code>{'{rounds}'}</code> <code>{'{lots}'}</code> <code>{'{names}'}</code>.</small>
                      </div>
                      <div class="banner-fields">
                        <label class="banner-f">
                          <span>Title</span>
                          <input type="text" maxlength="60" value={b.title || ''} placeholder={defaultBannerTitle(r)} on:input={(e) => setBanner(r.round, 'title', e.target.value)} disabled={locked} />
                        </label>
                        <label class="banner-f">
                          <span>Story</span>
                          <textarea rows="2" maxlength="300" value={b.message || ''} placeholder={defaultBannerText(r)} on:input={(e) => setBanner(r.round, 'message', e.target.value)} disabled={locked}></textarea>
                        </label>
                      </div>
                      {#if (b.title || '').trim() || (b.message || '').trim()}
                        <div class="banner-preview" class:final={r.final}>
                          <b>{fillBanner((b.title || '').trim() ? b.title : defaultBannerTitle(r), r)}</b>
                          <span>{fillBanner((b.message || '').trim() ? b.message : defaultBannerText(r), r)}</span>
                        </div>
                      {/if}
                    </div>
                  {/if}
                {/if}
                {#if isOpen(Math.floor(i / perRound) + 1)}
                <div class="ccard">
                  <div class="ccard-head">
                    <span class="idx">Lot #{i + 1}</span>
                    <input class="cname" type="text" bind:value={c.name} placeholder={`Container #${i + 1}`} disabled={locked} />
                    <span class="chip">{pickups[spotOf(i) - 1] ? `Spot #${spotOf(i)}` : 'Direct crane hoist'}</span>
                    <button type="button" class="btn-x" on:click={() => removeContainer(i)} disabled={locked} title="Delete container"><Icon name="trash" size={13} /></button>
                  </div>

                  <div class="ccard-body">
                    <div class="two">
                      <div class="field">
                        <span class="lbl">Container Prop Model (Spawns During Event)</span>
                        <ModelPicker bind:value={c.model} presets={(hasVehicleReward(c.rewards) && containerChoices.some((m) => m.vehicleSafe) ? containerChoices.filter((m) => m.vehicleSafe) : containerChoices).concat(containerChoices.some((m) => m.id === c.model) || !c.model ? [] : [{ id: c.model, label: c.model }])} disabled={locked} placeholder="prop_container_ld" />
                      </div>
                      <div class="field">
                        <span class="lbl">Custom Lot Bidding</span>
                        <div class="bid-row">
                          <label>Start $<input type="number" min="0" step="500" bind:value={c.startingBid} disabled={locked} /></label>
                          <label>Step $<input type="number" min="100" step="100" bind:value={c.minBidIncrement} disabled={locked} /></label>
                          <label>Secs<input type="number" min="15" max="300" bind:value={c.auctionDuration} disabled={locked} /></label>
                        </div>
                      </div>
                    </div>

                    {#if hasVehicleReward(c.rewards) && containerChoices.some((m) => m.vehicleSafe) && !containerChoices.some((m) => m.vehicleSafe && m.id === c.model)}
                      <p class="hint warn">
                        This lot holds a car, but its container model is too small for one. Change it to a bigger model
                        (otherwise it is switched automatically when the event starts).
                        <button type="button" class="btn btn-xs btn-steel" disabled={locked} on:click={() => (c.model = containerChoices.find((m) => m.vehicleSafe).id)}>Use large container</button>
                      </p>
                    {/if}

                    <div class="rewards">
                      <div class="lbl"><Icon name="gift" size={12} /> Rewards &amp; Loot Contained</div>
                      {#if hasBothVehicleAndLoot(c.rewards)}
                        <div class="reward-collision-alert">
                          <Icon name="warning" size={14} />
                          <span><strong>Collision Warning:</strong> This container has both a Vehicle and Money/Items configured. Vehicles occupy the interior space and will collide with loot crates. Please configure either a Vehicle OR Money/Items for clean container opening.</span>
                        </div>
                      {/if}
                      <RewardListEditor bind:rewards={c.rewards} disabled={locked} allowVehicle={true} />
                    </div>

                    {#if hasVehicleReward(c.rewards)}
                      <div class="veh-safe-box">
                        <div class="veh-safe-info">
                          <div class="veh-safe-title">
                            <Icon name="car" size={14} />
                            <b>Vehicle Staging Area (Lot #{i + 1})</b>
                            <span class="veh-safe-tag">{c.vehicleSafeCoords ? 'CUSTOM LOCATION' : 'DEFAULT LOCATION'}</span>
                          </div>
                          <p class="veh-safe-desc">
                            When this lot is won or opened, the rewarded vehicle spawns here. If claimed, the winner teleports to it, safely clearing the crane drop pad.
                          </p>
                          <div class="veh-safe-coords">
                            {#if c.vehicleSafeCoords}
                              <span class="coord-pill">X: {c.vehicleSafeCoords.x}</span>
                              <span class="coord-pill">Y: {c.vehicleSafeCoords.y}</span>
                              <span class="coord-pill">Z: {c.vehicleSafeCoords.z}</span>
                              <span class="coord-pill">Heading: {c.vehicleSafeCoords.heading}°</span>
                            {:else}
                              <span class="coord-pill muted">Using Config Default: 794.5, -3000.2, 5.9 (90°)</span>
                            {/if}
                          </div>
                        </div>
                        <div class="veh-safe-actions">
                          <button type="button" class="btn btn-sm btn-primary" on:click={() => placeLotVehicleSafe(i, getFirstVehicleModel(c.rewards))} disabled={locked || busy.placeVehSafe}>
                            <Icon name="eye" size={12} /><span>{c.vehicleSafeCoords ? 'Re-Place Vehicle' : 'Place in World'}</span>
                          </button>
                          <button type="button" class="btn btn-sm" on:click={() => setLotVehicleSafeCurrent(i)} disabled={locked} title="Set safe vehicle coordinates to player's current location">
                            <Icon name="mapPin" size={12} /><span>My Position</span>
                          </button>
                          {#if c.vehicleSafeCoords}
                            <button type="button" class="btn btn-sm" on:click={() => teleportToLotVehicleSafe(i)} title="Teleport to vehicle safe spot">
                              <Icon name="teleport" size={12} /><span>Teleport</span>
                            </button>
                            <button type="button" class="btn btn-sm btn-danger" on:click={() => clearLotVehicleSafe(i)} disabled={locked} title="Reset to default staging spot">
                              <Icon name="close" size={12} />
                            </button>
                          {/if}
                        </div>
                      </div>
                    {/if}
                  </div>
                </div>
                {/if}
              {/each}
            </div>
          {/if}
        </section>

      {:else if auctionSub === 'arena'}
        <!-- ═════════ BIDDING PERIMETER & PED POSITIONS ═════════ -->
        <!-- Bidding Perimeter Card -->
        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="map" size={14} /></div>
            <div>
              <h3>Bidding Perimeter (Arena Boundary)</h3>
              <p>Bidders must stand inside this boundary on the dock to place bids. Left-click points on the ground, Backspace to undo, Enter to save.</p>
            </div>
            <span class="state" class:ok={zoneReady}>{zoneReady ? `${zonePoints.length} points` : (usingDefaultZone ? 'Harbour default' : 'Not set')}</span>
          </header>

          <div class="zone-row">
            <div class="zone-stats">
              {#if zoneStats}
                <div><b>{zoneStats.area.toLocaleString()}</b><span>m² area</span></div>
                <div><b>{zoneStats.w} × {zoneStats.h}</b><span>m bounding box</span></div>
                <div><b>{zonePoints.length}</b><span>corner points</span></div>
              {:else}
                <p class="hint" style="margin:0">{usingDefaultZone ? 'Using harbour default perimeter from config.lua. ' : ''}Click Draw Perimeter, aim at ground corners, and left-click to drop points.</p>
              {/if}
            </div>
            <div class="actions">
              <button type="button" class="btn btn-sm btn-preview" on:click={recordZone} disabled={locked || isRecordingZone}>
                <Icon name="flag" size={12} /><span>{isRecordingZone ? 'Drawing…' : (zoneReady ? 'Redraw Perimeter' : 'Draw Perimeter')}</span>
              </button>
              {#if zoneReady || usingDefaultZone}
                <button type="button" class="btn btn-sm btn-refresh" on:click={() => previewZone(false)} disabled={busy.zone}><Icon name="eye" size={12} /><span>Preview Here</span></button>
                <button type="button" class="btn btn-sm" on:click={() => previewZone(true)} disabled={busy.zone}><Icon name="teleport" size={12} /><span>Teleport &amp; Preview</span></button>
                {#if zoneReady}<button type="button" class="btn btn-sm btn-danger" on:click={clearZone} disabled={locked}><Icon name="trash" size={12} /><span>Clear</span></button>{/if}
              {/if}
            </div>
          </div>
        </section>

        <!-- Ped Positions & Registration Card -->
        <section class="card">
          <header class="card-head">
            <div class="step"><Icon name="users" size={14} /></div>
            <div>
              <h3>Ped Positions &amp; Registration</h3>
              <p>Configure dedicated peds for the Container War event, including civilian registration and auction staff.</p>
            </div>
          </header>
          <div class="ped-list">
            <slot name="civilianPed" />
            <slot name="peds" />
          </div>
        </section>
      {/if}
    {/if}
    </div>
  </div>
</div>

<style>
  .cw { display: flex; flex-direction: column; gap: 14px; }
  .cw :global(.btn-sm) { min-height: 32px; padding: 0 12px; font-size: var(--fs-small); }
  .cw :global(.btn-xs) { min-height: 28px; padding: 0 9px; font-size: var(--fs-meta); gap: 5px; }

  .preset-bar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 14px; background: var(--c-panel, #181b1f); border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-panel);
  }
  .preset-info { display: flex; align-items: center; gap: 8px; font-size: var(--fs-body); font-weight: 700; color: var(--text-main); }

  /* Full-width responsive layout */
  .cw-layout { display: block; width: 100%; position: relative; }
  .cw-layout.cw-layout-full { display: block; width: 100%; }
  .cw-main { width: 100%; min-width: 0; display: flex; flex-direction: column; gap: 16px; }
  .cw-main.full-width { width: 100%; max-width: 100%; }
  .ped-list { display: flex; flex-direction: column; gap: 12px; }

  /* Integrated Simulation Box in Card 1 */
  .sim-box {
    display: flex; flex-direction: column; gap: 12px;
    padding: 14px 16px; background: var(--lt-111316, #111316); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); margin-top: 10px;
  }
  .sim-header { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; }
  .sim-title { display: flex; align-items: center; gap: 7px; font-size: var(--fs-small); color: var(--lt-ffffff, #fff); }
  .sim-controls { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .sim-select-wrap { display: flex; align-items: center; gap: 8px; flex: 1; min-width: 240px; }
  .sim-select-wrap label { font-size: var(--fs-meta); font-weight: 600; color: var(--text-dim); white-space: nowrap; }
  .sim-select-wrap select { flex: 1; height: 34px; background: var(--lt-0f1113, #0f1113); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); padding: 0 10px; font-size: var(--fs-small); }
  .audio-sync-badge { display: flex; align-items: center; gap: 5px; font-size: var(--fs-meta); color: #111111; background: rgb(45, 190, 170); border: 1px solid rgb(45, 190, 170); border-radius: var(--r-tag); padding: 4px 10px; }

  /* Main Card Layouts */
  .card {
    display: flex; flex-direction: column; gap: 14px;
    padding: 18px; background: var(--c-panel, #181b1f); border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-panel);
  }
  .card-head {
    display: flex; align-items: flex-start; gap: 14px;
    margin: -18px -18px 4px; padding: 14px 18px;
    background: var(--topbar-bg, #15171b);
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-panel) var(--r-panel) 0 0;
  }
  .card-head > div:nth-child(2) { flex: 1; min-width: 0; }
  .card-head h3 { margin: 0; font-size: var(--fs-body); font-weight: 700; color: var(--text-main); }
  .card-head p { margin: 3px 0 0; font-size: var(--fs-small); line-height: 1.5; color: var(--text-dim); }
  .step {
    flex-shrink: 0; width: 28px; height: 28px; display: grid; place-items: center;
    border-radius: var(--r-ctl); background: var(--c-raised, #1f2328); border: 1px solid var(--c-line, #2a2e35); color: var(--lt-7bb6f2, #7bb6f2); font-weight: 700; font-size: var(--fs-small);
  }
  .count { font-weight: 500; color: var(--text-dim); font-size: var(--fs-small); }
  .state {
    flex-shrink: 0; align-self: center; padding: 3px 10px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 700;
    color: var(--text-dim); background: var(--c-raised, #1f2328); border: 1px solid var(--c-line, #2a2e35);
  }
  .state.ok { color: #111111; background: rgb(45, 190, 170); border-color: rgb(45, 190, 170); }

  .idx-badge { font-weight: 600; font-family: var(--font-mono); color: var(--lt-7bb6f2, #7bb6f2); background: var(--c-raised, #1f2328); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-tag); padding: 1px 6px; font-size: var(--fs-meta); }
  .status-badge { font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0.01em; padding: 2px 7px; border-radius: 999px; border: 1px solid transparent; }
  .status-badge.ok { color: #111111; background: rgb(45, 190, 170); border-color: rgb(45, 190, 170); }
  .status-badge.unassigned-crane, .status-badge.unassigned-drop { color: #111111; background: rgb(239, 68, 68); border-color: rgb(239, 68, 68); }
  .status-badge.unreachable { color: #111111; background: rgb(240, 195, 109); border-color: rgb(240, 195, 109); }

  /* rounds in the lot list */
  .round-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 4px 6px 4px 4px; margin-top: 4px; border-bottom: 1px solid var(--c-line, #2a2e35); }
  .round-head.final { border-bottom-color: rgba(240, 195, 109, 0.5); }
  .round-toggle { flex: 1; min-width: 0; display: flex; align-items: center; gap: 10px; padding: 6px 8px; background: transparent; border: none; border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); text-align: left; cursor: pointer; }
  .round-toggle:hover:not(:disabled) { background: var(--bg-card-raised, #1c1f24); }
  .round-toggle:disabled { cursor: default; }
  .round-toggle b { font-size: var(--fs-body); color: var(--lt-7bb6f2, #7bb6f2); }
  .round-head.final .round-toggle b { color: var(--lt-f0c36d, #f0c36d); }
  .round-toggle span { font-size: var(--fs-meta); color: var(--text-dim); }
  .round-toggle .round-cash { margin-left: auto; color: var(--lt-78d6c8, #78d6c8); font-weight: 600; }
  .banner-card { margin: 6px 0 4px; padding: 10px 12px; background: var(--bg-surface, #15171b); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); display: flex; flex-direction: column; gap: 8px; }
  .banner-head { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; color: var(--text-main); }
  .banner-head b { font-size: var(--fs-small); }
  .banner-head small { flex-basis: 100%; font-size: var(--fs-meta); color: var(--text-dim); line-height: 1.5; }
  .banner-head code { padding: 0 5px; border-radius: var(--r-ctl); background: var(--c-raised, #1f2328); border: 1px solid var(--c-line, #2a2e35); color: var(--lt-7bb6f2, #7bb6f2); font-size: var(--fs-meta); }
  .banner-fields { display: grid; grid-template-columns: minmax(180px, 1fr) minmax(260px, 2fr); gap: 10px; align-items: start; }
  .banner-f { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .banner-f span { font-size: var(--fs-meta); font-weight: 600; color: var(--text-dim); }
  .banner-f input, .banner-f textarea { width: 100%; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); font-size: var(--fs-meta); padding: 7px 9px; font-family: inherit; resize: vertical; }
  .banner-f input { height: 32px; padding-top: 0; padding-bottom: 0; }
  /* the green of the Container Wars announcement banner (web/src/lib/hud/eventThemes.js) */
  .banner-preview { display: flex; flex-direction: column; gap: 3px; padding: 9px 12px; border-radius: var(--r-panel); background: var(--bg-card-raised, #1c1f24); border-left: 3px solid #52d24a; }
  .banner-preview.final { border-left-color: #e5484d; }
  .banner-preview b { font-size: var(--fs-meta); letter-spacing: 0.01em; color: var(--lt-8ae885, #8ae885); }
  .banner-preview.final b { color: var(--lt-ff8a8d, #ff8a8d); }
  .banner-preview span { font-size: var(--fs-meta); color: var(--text-dim); line-height: 1.5; }
  .err-note { border-color: var(--c-line); color: var(--lt-ff8178, #ff8178); background: var(--c-raised);
    border-left: 3px solid rgb(239, 68, 68);}
  .cw :global(input.bad) { border-color: rgba(239, 68, 68, 0.7); }
  .cw :global(small.err) { color: var(--lt-ff8178, #ff8178); }

  /* Spot + drop pad rows — each list scrolls on its own so any number of spots/pads can be added */
  .rows-scroll { max-height: 380px; overflow: auto; border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); background: var(--bg-surface, #15171b); scrollbar-width: thin; scrollbar-color: #3a3d52 transparent; }
  .rows-inner { width: 100%; }
  .rows-inner.spot-rows { min-width: 900px; }
  .rows-inner.drop-rows { min-width: 640px; }
  .row-head, .list-row { display: grid; align-items: center; column-gap: 10px; padding: 0 12px; }
  /* spot | crane | drop | model | position | placement | remove */
  .spot-row-cols { grid-template-columns: 104px minmax(130px, 0.9fr) minmax(112px, 0.7fr) minmax(150px, 1fr) minmax(180px, 1.1fr) 208px 28px; }
  /* pad | delivers | position | placement | remove */
  .drop-row-cols { grid-template-columns: 140px minmax(200px, 1.2fr) minmax(200px, 1fr) 208px 28px; }
  .row-head { position: sticky; top: 0; z-index: 1; height: 32px; background: var(--bg-card-raised, #1c1f24); border-bottom: 1px solid var(--c-line, #2a2e35); font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0.02em; color: var(--text-muted, var(--text-dim)); }
  .list-row { min-height: 52px; padding-top: 8px; padding-bottom: 8px; border-bottom: 1px solid var(--c-raised, #1f2328); }
  .list-row:last-child { border-bottom: none; }
  .list-row:hover { background: var(--c-panel, #181b1f); }
  .list-row.has-warn { box-shadow: none; }
  .list-row .cell { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .list-row .cell.spot-id { flex-direction: column; align-items: flex-start; gap: 4px; }
  .list-row .cell.coords { flex-direction: column; align-items: flex-start; gap: 2px; font-size: var(--fs-small); color: var(--lt-ffffff, #fff); font-variant-numeric: tabular-nums; }
  /* the shared .actions class wraps; inside a row the buttons must stay on one line, equal width */
  .list-row .cell.actions { flex-wrap: nowrap; gap: 8px; }
  .list-row .cell.actions :global(.btn) { flex: 1 1 0; justify-content: center; white-space: nowrap; }
  .list-row .cell.spot-id .idx-badge, .list-row .cell.spot-id .status-badge { white-space: nowrap; }
  .list-row .btn-x { justify-self: end; }
  .list-row .cell .idx-badge { font-size: var(--fs-small); padding: 2px 8px; }
  .list-row .cell .chip { font-size: var(--fs-small); padding: 3px 10px; overflow: hidden; text-overflow: ellipsis; }
  .list-row select { width: 100%; height: 32px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); font-size: var(--fs-small); padding: 0 8px; text-overflow: ellipsis; }

  /* Matrix Table (Tab 2) */
  .matrix-table-wrap { overflow-x: auto; border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); background: var(--bg-surface, #15171b); }
  .matrix-table { width: 100%; border-collapse: collapse; font-size: var(--fs-small); text-align: left; }
  .matrix-table th { padding: 9px 12px; font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0; color: var(--text-muted); background: var(--c-panel); border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }
  .matrix-table td { padding: 10px 12px; border-bottom: 1px solid var(--c-line-soft); color: var(--lt-ffffff, #fff); vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }
  .matrix-row.warn-row td { background: rgba(240, 195, 109, 0.03);
    font-variant-numeric: tabular-nums;
  }
  .matrix-select { height: 32px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); font-size: var(--fs-meta); padding: 0 8px; width: 100%; max-width: 170px; }
  .prop-label { font-size: var(--fs-meta); color: var(--lt-c9ced4, #c9ced4); }
  .path-cell { display: flex; align-items: center; gap: 6px; }
  .field-warn { display: block; font-size: var(--fs-meta); color: var(--lt-f0c36d, #f0c36d); margin-top: 2px; }
  .empty-cell { text-align: center; color: var(--text-dim); padding: 24px !important; }

  /* Restructured Phases in Pacing Tab */
  .phase-card { background: var(--bg-surface, #15171b); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); overflow: hidden; display: flex; flex-direction: column; gap: 0; }
  .phase-head { padding: 10px 14px; background: var(--c-panel, #181b1f); border-bottom: 1px solid var(--c-line, #2a2e35); border-left: 3px solid var(--accent-primary, #4f94e6); }
  .phase-head h4 { margin: 0; font-size: var(--fs-small); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-ffffff, #fff); }
  .phase-head span { font-size: var(--fs-meta); color: var(--text-dim); margin-top: 2px; display: block; }
  .phase-body { padding: 14px; display: flex; flex-direction: column; gap: 14px; }
  .anti-snipe-wrap { flex: 1; min-width: 280px; }
  .apply-btn { align-self: flex-end; }
  .final-round-box, .carry-mode-box { padding: 12px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-raised, #1f2328); border-radius: var(--r-panel); }

  /* Helpers */
  .hint { margin: 0; font-size: var(--fs-small); line-height: 1.55; color: var(--text-dim); }
  .hint.warn { color: var(--lt-f0c36d, #f0c36d); }
  .notice { padding: 8px 12px; border-radius: var(--r-panel); font-size: var(--fs-small); color: var(--lt-f0c36d, #f0c36d); background: var(--c-raised); border: 1px solid var(--c-line);
    border-left: 3px solid rgb(255, 200, 87);}
  .lbl { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-dim); }
  small { font-size: var(--fs-meta); color: var(--text-dim); line-height: 1.4; }
  .seg { display: flex; padding: 3px; gap: 3px; background: var(--bg-surface, #15171b); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); width: fit-content; max-width: 100%; flex-wrap: wrap; }
  .seg button {
    display: inline-flex; align-items: center; gap: 7px; padding: 6px 12px; border: none; border-radius: var(--r-ctl);
    background: transparent; color: var(--text-dim); font-size: var(--fs-meta); font-weight: 600; cursor: pointer;
  }
  .seg button:hover:not(:disabled) { color: var(--lt-ffffff, #fff); background: rgba(var(--ink-rgb, 255, 255, 255), 0.05); }
  .seg button.on { background: var(--accent-primary); color: var(--on-accent, #ffffff);
    text-shadow: none; }
  .seg button:disabled { opacity: 0.5; cursor: not-allowed; }
  .chip {
    padding: 2px 8px; border-radius: 999px; font-family: var(--font-mono); font-size: var(--fs-meta);
    color: #111111; background: rgb(45, 190, 170); border: 1px solid rgb(45, 190, 170); white-space: nowrap;
  }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }

  .zone-row { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
  .zone-stats { display: flex; gap: 22px; flex: 1; min-width: 220px; }
  .zone-stats div { display: flex; flex-direction: column; }
  .zone-stats b { font-size: var(--fs-title); font-weight: 700; color: var(--lt-ffffff, #fff); line-height: 1.1;
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .zone-stats span { font-size: var(--fs-meta); color: var(--text-dim); }

  .plan { border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); overflow: hidden; background: var(--bg-surface, #15171b); }
  .plan-head { display: flex; justify-content: space-between; padding: 9px 14px; font-size: var(--fs-small); color: var(--lt-ffffff, #fff); border-bottom: 1px solid var(--c-line, #2a2e35); }
  .plan-head span { color: var(--text-dim); font-size: var(--fs-meta); }
  .mono { font-family: var(--font-mono); }

  .flow { display: flex; align-items: stretch; gap: 8px; flex-wrap: wrap; }
  .fs { flex: 1 1 150px; display: flex; flex-direction: column; gap: 2px; padding: 10px 12px; background: var(--bg-surface, #15171b); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); }
  .fs small { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-dim); }
  .fs b { font-size: var(--fs-title); color: var(--lt-ffffff, #fff); }
  .fs span { font-size: var(--fs-meta); color: var(--text-dim); }
  .fs.hi { border-color: var(--accent-primary); }
  .fs.hi b { color: var(--lt-7bb6f2, #7bb6f2); }
  .fa { align-self: center; color: var(--text-dim); font-size: var(--fs-emph); }

  .sub { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-dim); display: block; margin-bottom: 4px; }
  .grid2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px 16px; align-items: start; }
  .grid3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 14px 16px; align-items: start; }
  .row-end { display: flex; align-items: flex-end; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
  .info-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 38px; padding: 0 12px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl); }
  .info-label { font-size: var(--fs-small); font-weight: 600; color: var(--text-label, #c9ced4); }
  .info-pill { min-width: 34px; text-align: center; padding: 2px 10px; border-radius: var(--r-tag); background: var(--c-raised, #1f2328); border: 1px solid var(--tablet-border-strong, #363b43); color: var(--lt-ffffff, #fff); font-weight: 600; }
  .unit .cur { min-width: 14px; font-weight: 500; color: var(--text-muted); }
  .field { display: flex; flex-direction: column; gap: 5px; }
  .field > label, .field > .lbl-heading { font-size: var(--fs-meta); font-weight: 600; color: var(--text-label, #c9ced4); }
  .field input[type='number'], .unit input {
    width: 100%; height: 38px; padding: 0 10px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff); font-family: var(--font-mono); font-size: var(--fs-small); outline: none;
  }
  .unit { display: flex; align-items: center; gap: 8px; }
  .unit span { font-size: var(--fs-meta); color: var(--text-dim); min-width: 28px; }

  .rounds { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 8px; }
  .round-chip { display: flex; flex-direction: column; padding: 5px 9px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-tag); font-size: var(--fs-meta); }
  .round-chip b { color: var(--lt-7bb6f2, #7bb6f2); }
  .round-chip span { color: var(--text-dim); }
  .round-chip.final { border-color: rgb(255, 200, 87); background: rgb(255, 200, 87);
    color: #111111;}
  .round-chip.final b { color: var(--lt-ffc857, #ffc857); }

  .route-chip { font-size: var(--fs-meta); color: var(--text-muted); padding: 2px 8px; border-radius: 999px; border: 1px solid var(--c-line, #2a2e35); background: var(--c-raised, #1f2328); white-space: nowrap; }
  .route-chip.ok { color: #111111; border-color: rgb(45, 190, 170); background: rgb(45, 190, 170); }
  .route-chip.warn, .route-chip.stale { color: #111111; border-color: rgb(255, 200, 87); background: rgb(255, 200, 87); }
  .bend-row { display: flex; align-items: center; gap: 10px; margin: 6px 0; }
  .bend-row label { font-size: var(--fs-small); color: var(--text-dim); }
  .bend-row input[type='range'] { flex: 1; accent-color: var(--accent-primary); }
  .bend-row b { min-width: 40px; text-align: right; color: var(--text-main); font-size: var(--fs-small); }

  .empty { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 28px 16px; color: var(--text-dim); border: 1px dashed var(--c-line, #2a2e35); border-radius: var(--r-panel); }
  .empty p { margin: 0; color: var(--lt-ffffff, #fff); font-weight: 600; }
  .stack { display: flex; flex-direction: column; gap: 12px; }
  .ccard { background: var(--bg-surface, #15171b); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); overflow: hidden; }
  .ccard-head { display: flex; align-items: center; gap: 10px; padding: 9px 12px; background: var(--bg-card-raised, #1c1f24); border-bottom: 1px solid var(--c-line, #2a2e35); }
  .idx { font-family: var(--font-mono); font-weight: 700; color: var(--lt-7bb6f2, #7bb6f2); }
  .cname {
    flex: 1; min-width: 0; height: 32px; padding: 0 8px; background: transparent; border: 1px solid transparent; border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff); font-size: var(--fs-body); font-weight: 700; outline: none;
  }
  .cname:focus { background: var(--c-panel, #181b1f); border-color: var(--accent-primary); }
  .btn-x { display: inline-flex; padding: 6px; background: transparent; border: none; border-radius: var(--r-ctl); color: var(--text-dim); cursor: pointer; }
  .btn-x:hover:not(:disabled) { color: var(--lt-ffffff, #fff); background: #d9463e; }
  .ccard-body { display: flex; flex-direction: column; gap: 14px; padding: 14px; }
  .two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
  .rewards { display: flex; flex-direction: column; gap: 8px; padding-top: 12px; border-top: 1px solid var(--c-line, #2a2e35); }
  .rewards .lbl { display: flex; align-items: center; gap: 6px; }
  .reward-collision-alert {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 10px 14px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-panel);
    color: var(--lt-fca5a5, #fca5a5);
    font-size: var(--fs-meta);
    line-height: 1.45;
    border-left: 3px solid rgb(239, 68, 68);}
  .reward-collision-alert strong {
    color: #ef4444;
  }

  .yard-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 9px 14px; border-top: 1px solid var(--c-raised, #1f2328); color: var(--lt-ffffff, #fff); }
  .yard-row .mono.muted { color: var(--text-dim); }
  .dummy-row { align-items: center; }

  .bid-row { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
  .bid-row label { display: flex; flex-direction: column; gap: 3px; font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-dim); }
  .bid-row input {
    width: 100%; height: 32px; padding: 0 8px; background: var(--c-panel, #181b1f); border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff); font-family: var(--font-mono); font-size: var(--fs-small); outline: none;
  }


  .veh-safe-box {
    margin: 14px 0 16px;
    padding: 13px 15px;
    background: rgba(var(--ltc-26-29-39, 26, 29, 39), 0.7);
    border: 1px solid rgba(var(--accent-primary-rgb), 0.25);
    border-radius: var(--r-ctl);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
  }
  .veh-safe-info {
    flex: 1 1 auto;
    min-width: 0;
  }
  .veh-safe-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    color: var(--lt-ffffff, #fff);
    margin-bottom: 4px;
  }
  .veh-safe-tag {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--on-accent);
    background: var(--c-action);
    border: 1px solid var(--c-action);
    padding: 1px 6px;
    border-radius: var(--r-tag);
    letter-spacing: 0.01em;
  }
  .veh-safe-desc {
    font-size: var(--fs-meta);
    color: var(--lt-959ca5, #959ca5);
    line-height: 1.35;
    margin: 0 0 8px;
  }
  .veh-safe-coords {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .coord-pill {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    color: #111111;
    background: rgb(85, 201, 138);
    border: 1px solid rgb(85, 201, 138);
    padding: 2px 7px;
    border-radius: var(--r-tag);
  }
  .coord-pill.muted {
    color: #8d949c;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.1);
  }
  .veh-safe-actions {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 6px;
  }

  @media (max-width: 1180px) {
    .cw-layout { flex-direction: column; }
    .cw-inspector { width: 100%; max-height: none; position: static; }
    .cw-inspector.collapsed { width: 100%; height: 44px; }
    .grid3 { grid-template-columns: 1fr; }
    .grid2 { grid-template-columns: 1fr; }
    .two { grid-template-columns: 1fr; }
  }
</style>
