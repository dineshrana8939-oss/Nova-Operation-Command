<script>
  import { onDestroy } from 'svelte';
  import { getPlayerPosition, teleportToPosition, getZoneName, previewRoute, clearRoutePreview, startZoneRecording } from '../../api/route.js';
  import { bootstrap, zoneRecordingResult } from '../../stores.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import { revealLast } from '../ui/reveal.js';
  import { renumberAuto } from '../../util/autoName.js';
  import Toggle from '../ui/Toggle.svelte';
  import RewardListEditor from '../ui/RewardListEditor.svelte';
  import RoutePreviewMap from '../ui/RoutePreviewMap.svelte';
  import SavedTemplatePicker from '../ui/SavedTemplatePicker.svelte';
  import { PREDEFINED_AIRDROP_LOCATIONS, sampleAirdropLocations } from '../../util/airdropLocations.js';
  import { openPropPlacer } from '../../api/placer.js';
  import PropTable from '../ui/PropTable.svelte';
  import '../tablet-theme.css';

  // Standalone drop zones for a GANG_AIRDROP event.
  // Each zone represents a physical supply drop location in San Andreas.
  export let zones = [];
  // a pin dragged on the map: its vector follows live, and is written for good on release (and again when the ground height arrives)
  import { applyMove, applyLive, liveThrottle } from '../../util/mapMove.js';
  const liveMove = liveThrottle((d) => { zones = applyLive(zones, d); });
  export let eventDuration = 1200;
  export let locked = false;
  // The event's placed props (form.props, the same list as the Props tab). A prop placed from a zone's own "Prop Placer" button
  // carries that zone's id as `zoneId`, so each zone's scenery stays with it.
  export let props = [];
  let selectedPointId = null;
  // The event's own settings object — bound so airdropPlacement, airdropCount,
  // randomizeLocations, and bulk settings persist with the event.
  export let settings = {};

  const AGGRESSIVENESS_OPTIONS = [
    { value: 'low', label: 'Low (Recruit — Low accuracy)' },
    { value: 'medium', label: 'Medium (Tactical — Balanced)' },
    { value: 'high', label: 'High (Aggressive — High accuracy)' },
    { value: 'extreme', label: 'Extreme (Lethal — Pinpoint aim)' },
  ];

  const GUARD_WEAPONS = [
    { value: 'WEAPON_MICROSMG', label: 'Micro SMG (Uzi)' },
    { value: 'WEAPON_CARBINERIFLE', label: 'Carbine Rifle (M4)' },
    { value: 'WEAPON_ASSAULTRIFLE', label: 'Assault Rifle (AK-47)' },
    { value: 'WEAPON_SMG', label: 'SMG (MP5)' },
    { value: 'WEAPON_COMBATPISTOL', label: 'Combat Pistol' },
    { value: 'WEAPON_PUMPSHOTGUN', label: 'Pump Shotgun' },
  ];

  const GUARD_MODELS = [
    { value: 'g_m_y_lost_01', label: 'Lost MC Biker' },
    { value: 'g_m_y_salvagoon_01', label: 'Salvadorian Cartel' },
    { value: 'g_m_y_mexgoon_01', label: 'Mexican Cartel' },
    { value: 'g_m_y_ballas_01', label: 'Street Gang' },
    { value: 's_m_y_blackops_01', label: 'Black Ops Mercenary' },
  ];

  const PLACEMENT_MODES = [
    { value: 'SEQUENTIAL', label: 'One After Another', hint: 'Drops arrive one at a time, queued across the event — gangs fight over each crate in turn.' },
    { value: 'SIMULTANEOUS', label: 'All At Once', hint: 'Every zone opens at the same moment — gangs have to split up and choose which drop to contest.' },
    { value: 'MANUAL', label: 'Custom Timings', hint: 'Use the activation delay and duration typed on each zone below, exactly as entered.' },
  ];

  $: placement = settings?.airdropPlacement || 'SEQUENTIAL';

  // Ensure default structure on settings
  $: if (settings) {
    if (settings.airdropCount == null) settings.airdropCount = 10;
    if (settings.randomizeLocations == null) settings.randomizeLocations = false;
    if (settings.syncNpcSettings == null) settings.syncNpcSettings = false;
    if (settings.syncRewardSettings == null) settings.syncRewardSettings = false;
  }

  function setPlacement(mode) {
    if (locked) return;
    settings = { ...settings, airdropPlacement: mode };
    if (mode === 'SEQUENTIAL') autoDistributeTiming();
    else if (mode === 'SIMULTANEOUS') distributeSimultaneous();
  }

  function autoDistributeTiming() {
    if (zones.length === 0) return;
    const totalSec = Math.max(120, Number(eventDuration) || 1200);
    const n = zones.length;
    if (n === 1) {
      zones = zones.map((z) => ({
        ...z,
        activationDelay: 60,
        duration: Math.max(120, Math.min(600, totalSec - 90)),
      }));
      return;
    }
    const bufferStart = 60;
    const bufferEnd = Math.min(600, Math.max(120, Math.floor(totalSec * 0.15)));
    const usableSec = Math.max(60, totalSec - bufferStart - bufferEnd);
    let step = Math.floor(usableSec / (n - 1));
    let crateDuration = Math.max(60, Math.min(480, Math.floor(step * 0.75)));
    if (crateDuration > step) step = crateDuration;

    zones = zones.map((z, idx) => ({
      ...z,
      activationDelay: bufferStart + idx * step,
      duration: idx < n - 1 ? Math.min(crateDuration, step) : crateDuration,
    }));
  }

  function distributeSimultaneous() {
    if (zones.length === 0) return;
    const totalSec = Math.max(120, Number(eventDuration) || 1200);
    const delay = 60;
    const crateDuration = Math.max(120, Math.min(600, totalSec - 150));
    zones = zones.map((z) => ({ ...z, activationDelay: delay, duration: crateDuration }));
  }

  function formatTime(sec) {
    const s = Math.max(0, Number(sec) || 0);
    const m = Math.floor(s / 60);
    const rem = s % 60;
    if (m === 0) return `${rem}s`;
    if (rem === 0) return `${m}m`;
    return `${m}m ${rem}s`;
  }

  function nextId() {
    return `zone_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  }

  function defaultZone() {
    const title = `Drop Zone ${zones.length + 1}`;
    const templateNpc = settings?.airdropMain || zones[0] || {};
    const templateReward = settings?.airdropMain || zones[0] || {};
    return {
      id: nextId(), label: title, name: title,
      x: null, y: null, z: null, heading: 0.0,
      enabled: true, announce: true,
      activationDelay: 30, duration: 300,
      guardCount: templateNpc.guardCount != null ? templateNpc.guardCount : 3,
      guardModel: templateNpc.guardModel || 'g_m_y_lost_01',
      guardWeapon: templateNpc.guardWeapon || 'WEAPON_MICROSMG',
      guardAggressiveness: templateNpc.guardAggressiveness || 'medium',
      requireLockpick: templateReward.requireLockpick != null ? templateReward.requireLockpick : true,
      lockpicksRequired: templateReward.lockpicksRequired || '',
      chance: templateReward.chance != null ? templateReward.chance : 60,
      rewards: templateReward.rewards ? JSON.parse(JSON.stringify(templateReward.rewards)) : [{ type: 'MONEY', amount: 500, pool: '' }],
    };
  }

  async function addZoneHere() {
    const pos = await getPlayerPosition();
    zones = [...zones, {
      ...defaultZone(),
      x: pos.x != null ? Math.round(pos.x * 100) / 100 : 0,
      y: pos.y != null ? Math.round(pos.y * 100) / 100 : 0,
      z: pos.z != null ? Math.round(pos.z * 100) / 100 : 70,
      heading: pos.heading != null ? Math.round(pos.heading * 10) / 10 : 0,
    }];
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
    revealLast('.zone-card');
  }

  function addManualZone() {
    zones = [...zones, { ...defaultZone(), x: 0, y: 0, z: 70, heading: 0.0 }];
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
    revealLast('.zone-card');
  }

  // Auto-Add Zones modal & generator
  let showAutoAddModal = false;
  let autoAddCount = 3;

  function confirmAutoAdd(count) {
    if (locked) return;
    const n = Math.max(1, Math.min(50, Number(count) || 1));
    const sampled = sampleAirdropLocations(n, $bootstrap?.predefinedAirdrops);
    const baseIdx = zones.length;
    const templateNpc = settings?.airdropMain || zones[0] || {};
    const templateReward = settings?.airdropMain || zones[0] || {};

    const added = sampled.map((loc, i) => {
      const title = loc.name || `Drop Zone ${baseIdx + i + 1}`;
      return {
        ...defaultZone(),
        id: nextId(),
        label: title,
        name: title,
        x: loc.x,
        y: loc.y,
        z: loc.z || 70,
        guardCount: templateNpc.guardCount != null ? templateNpc.guardCount : 3,
        guardModel: templateNpc.guardModel || 'g_m_y_lost_01',
        guardWeapon: templateNpc.guardWeapon || 'WEAPON_MICROSMG',
        guardAggressiveness: templateNpc.guardAggressiveness || 'medium',
        requireLockpick: templateReward.requireLockpick != null ? templateReward.requireLockpick : true,
        lockpicksRequired: templateReward.lockpicksRequired || '',
        chance: templateReward.chance != null ? templateReward.chance : 60,
        rewards: templateReward.rewards ? JSON.parse(JSON.stringify(templateReward.rewards)) : [{ type: 'MONEY', amount: 500, pool: '' }],
      };
    });

    zones = [...zones, ...added];
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
    showAutoAddModal = false;
    revealLast('.zone-card');
  }

  async function generateRandomDrops() {
    if (locked) return;
    const count = Math.max(1, Math.min(50, Number(settings?.airdropCount) || 10));
    if (zones.length > 0) {
      const ok = await confirmAction(
        `Replace current ${zones.length} drop zones with ${count} random drops selected from the 25 San Andreas locations?`,
        { title: 'Generate Random Drops', danger: true }
      );
      if (!ok) return;
    }

    const sampled = sampleAirdropLocations(count, $bootstrap?.predefinedAirdrops);
    const templateNpc = settings?.airdropMain || zones[0] || {};
    const templateReward = settings?.airdropMain || zones[0] || {};

    zones = sampled.map((loc, idx) => ({
      ...defaultZone(),
      id: nextId(),
      name: loc.name || `Drop Zone ${idx + 1}`,
      label: loc.label || `Drop Zone ${idx + 1}`,
      x: loc.x,
      y: loc.y,
      z: loc.z || 70,
      guardCount: templateNpc.guardCount != null ? templateNpc.guardCount : 3,
      guardModel: templateNpc.guardModel || 'g_m_y_lost_01',
      guardWeapon: templateNpc.guardWeapon || 'WEAPON_MICROSMG',
      guardAggressiveness: templateNpc.guardAggressiveness || 'medium',
      requireLockpick: templateReward.requireLockpick != null ? templateReward.requireLockpick : true,
      lockpicksRequired: templateReward.lockpicksRequired || '',
      chance: templateReward.chance != null ? templateReward.chance : 60,
      rewards: templateReward.rewards ? JSON.parse(JSON.stringify(templateReward.rewards)) : [{ type: 'MONEY', amount: 500, pool: '' }],
    }));

    if (placement === 'SEQUENTIAL') autoDistributeTiming();
    else if (placement === 'SIMULTANEOUS') distributeSimultaneous();
  }

  // ── Main settings: a TEMPLATE for guards and rewards, not a zone ──────────────────────────────────────────────
  // No zone is "the master". The Main settings are edited here, new zones start from them, the server uses them when the spots are
  // randomised each run, and the buttons below apply them to whichever zones are ticked. Every zone can still be customised on its own
  // card afterwards; applying Main is a one-time copy (nothing keeps overwriting what you changed).
  const MAIN_DEFAULTS = () => ({
    guardCount: 3, guardModel: 'g_m_y_lost_01', guardWeapon: 'WEAPON_MICROSMG', guardAggressiveness: 'medium',
    requireLockpick: true, lockpicksRequired: '', chance: 60, rewards: [{ type: 'MONEY', amount: 500, pool: '' }],
  });
  const GUARD_KEYS = ['guardCount', 'guardModel', 'guardWeapon', 'guardAggressiveness'];
  const REWARD_KEYS = ['chance', 'requireLockpick', 'lockpicksRequired'];
  const clone = (v) => JSON.parse(JSON.stringify(v ?? []));
  function mainFromZone(z) {
    const d = MAIN_DEFAULTS();
    const m = {};
    for (const k of [...GUARD_KEYS, ...REWARD_KEYS]) m[k] = z && z[k] != null ? z[k] : d[k];
    m.rewards = z && Array.isArray(z.rewards) && z.rewards.length ? clone(z.rewards) : d.rewards;
    return m;
  }
  // an older event has no Main settings yet: start from its first zone, so nothing it already had is lost
  $: if (settings && !settings.airdropMain) settings.airdropMain = zones[0] ? mainFromZone(zones[0]) : MAIN_DEFAULTS();

  let loadFromId = '';
  function loadMainFrom() {
    if (locked || !loadFromId) return;
    const z = zones.find((x) => x.id === loadFromId);
    if (z) settings = { ...settings, airdropMain: mainFromZone(z) };
  }

  // which zones receive Main when an Apply button is pressed (no explicit choice yet = all of them)
  $: targetIds = new Set(
    (Array.isArray(settings?.bulkTargets) ? settings.bulkTargets : zones.map((z) => z.id)).filter((id) => zones.some((z) => z.id === id))
  );
  const zoneName = (z, i) => (z && (z.label || z.name)) || `Drop Zone ${i + 1}`;
  function setBulkTargets(ids) { settings = { ...settings, bulkTargets: [...ids] }; }
  function toggleTarget(id) {
    if (locked) return;
    const next = new Set(targetIds);
    if (next.has(id)) next.delete(id); else next.add(id);
    setBulkTargets(next);
  }
  function selectAllTargets() { if (!locked) setBulkTargets(zones.map((z) => z.id)); }
  function clearTargets() { if (!locked) setBulkTargets([]); }
  function invertTargets() { if (!locked) setBulkTargets(zones.filter((z) => !targetIds.has(z.id)).map((z) => z.id)); }

  const optLabel = (list, value) => (list.find((o) => o.value === value) || {}).label || value;
  function copyGuards(to) { const out = { ...to }; for (const k of GUARD_KEYS) out[k] = settings.airdropMain[k]; return out; }
  function copyRewards(to) {
    const out = { ...to };
    for (const k of REWARD_KEYS) out[k] = settings.airdropMain[k];
    out.rewards = clone(settings.airdropMain.rewards);
    return out;
  }
  // part: 'guards' | 'rewards' | 'both', for the ticked zones (ids = null) or for one zone
  const PART_TEXT = {
    guards: ['guard settings', 'guard count, aggressiveness, ped model and weapon', 'rewards'],
    rewards: ['reward settings', 'lockpick requirement, lockpicks needed, reward chance and the whole reward list', 'guards'],
    both: ['guard and reward settings', 'guard count, aggressiveness, ped model, weapon, lockpick requirement, lockpicks needed, reward chance and the whole reward list', null],
  };
  async function applyMain(part, ids = null) {
    if (locked || !settings.airdropMain) return;
    const want = ids || targetIds;
    if (want.size === 0) return;
    // Pressing a bulk button overwrites what those zones have: say exactly which zones and which settings, and ask first.
    // (A single zone's own "Use Main …" button is explicit enough not to ask.)
    if (!ids) {
      const names = zones.map((z, i) => ({ z, i })).filter(({ z }) => want.has(z.id)).map(({ z, i }) => `Zone ${i + 1} — ${zoneName(z, i)}`);
      const shown = names.slice(0, 8).join('\n') + (names.length > 8 ? `
… and ${names.length - 8} more` : '');
      const [what, fields, kept] = PART_TEXT[part];
      const ok = await confirmAction(
        `Replace the ${what} of ${names.length} drop zone${names.length === 1 ? '' : 's'} with the Main settings?

${shown}

This overwrites their current ${fields}.${kept ? ` Their ${kept}, position and timing are not touched.` : ' Their position and timing are not touched.'}
Zones you did not tick stay as they are. This cannot be undone.`,
        { title: 'Apply Main settings', confirmLabel: `Apply to ${names.length} zone${names.length === 1 ? '' : 's'}`, danger: true }
      );
      if (!ok) return;
    }
    zones = zones.map((z) => {
      if (!want.has(z.id)) return z;
      let out = z;
      if (part === 'guards' || part === 'both') out = copyGuards(out);
      if (part === 'rewards' || part === 'both') out = copyRewards(out);
      return out;
    });
  }

  // ── Prop Placer, per zone ─────────────────────────────────────────────────────
  // How many props each zone holds (a map the template reads directly: a helper function called from the template would not re-run
  // when the list changes).
  $: zonePropMap = (props || []).reduce((acc, o) => {
    if (o && o.zoneId) {
      if (!acc[o.zoneId]) acc[o.zoneId] = [];
      acc[o.zoneId].push(o);
    }
    return acc;
  }, {});
  $: zonePropCount = Object.fromEntries(Object.entries(zonePropMap).map(([id, list]) => [id, list.length]));
  let placerBusy = false;

  // The zone's prop list (shown under the zone) is edited through these; each one files the result back into the event's list.
  function setZoneProps(zoneId, list) {
    props = [...(props || []).filter((o) => o.zoneId !== zoneId), ...list.map((o) => ({ ...o, zoneId }))];
  }
  const removeZoneProp = (zoneId, idx) => setZoneProps(zoneId, (zonePropMap[zoneId] || []).filter((_, i) => i !== idx));
  function teleportZoneProp(zoneId, idx) {
    const o = (zonePropMap[zoneId] || [])[idx];
    if (o && o.x != null) teleportToPosition(o.x, o.y, o.z, o.heading || 0);
  }

  // Opens the shared Prop Placer on THIS zone's props only, with the camera over the zone and the crate's landing spot marked so
  // nothing gets built on it. Whatever is saved comes back tagged with the zone. selectIndex (1-based) opens on one prop.
  async function openZonePlacer(zone, selectIndex) {
    if (locked || placerBusy || !zone || !isPlaced(zone)) return;
    placerBusy = true;
    const zoneIdx = zones.findIndex((z) => z.id === zone.id);
    const label = zoneName(zone, zoneIdx < 0 ? 0 : zoneIdx);
    const mine = (props || []).filter((o) => o.zoneId === zone.id);
    const guides = [
      // the landing spot: the placer warns when something stands on it
      { kind: 'drop', label: `${label} - crate landing`, x: zone.x, y: zone.y, z: zone.z ?? 0, h: zone.heading || 0, L: 5, W: 5, H: 2.5 },
    ];
    // props of the other zones and of the rest of the event, for reference
    for (const o of props || []) {
      if (o.zoneId === zone.id || o.x == null) continue;
      guides.push({ kind: o.kind === 'vehicle' ? 'checkpoint_vehicle' : 'checkpoint_prop', model: o.model, x: o.x, y: o.y, z: o.z, h: o.heading || 0, rx: o.rx, ry: o.ry, L: 2.0, W: 2.0, H: 2.0, label: 'Event prop' });
    }
    let res = null;
    try {
      res = await openPropPlacer({
        context: 'airdrop',
        title: `Airdrop zone: ${label} - props`,
        objects: mine,
        focus: { x: zone.x, y: zone.y, z: zone.z ?? 0 },
        selectIndex,
        guides,
      });
    } catch (e) { res = null; }
    placerBusy = false;
    if (res && res.ok && Array.isArray(res.objects)) {
      const tagged = res.objects.map((o) => ({ ...o, zoneId: zone.id }));
      props = [...(props || []).filter((o) => o.zoneId !== zone.id), ...tagged];
    }
    // bring the admin back to this zone's card
    setTimeout(() => {
      const card = document.querySelector(`.zone-card[data-id="${zone.id}"]`);
      if (card) card.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 150);
  }

  // a zone that is removed takes its props with it
  const dropZoneProps = (ids) => { props = (props || []).filter((o) => !ids.includes(o.zoneId)); };

  async function removeZone(id) {
    const ok = await confirmAction('Remove this drop zone?', { title: 'Remove Zone', danger: true });
    if (!ok) return;
    dropZoneProps([id]);
    zones = zones.filter((z) => z.id !== id);
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
  }

  async function pinToMyPosition(id) {
    const pos = await getPlayerPosition();
    zones = zones.map((z) => (z.id === id ? {
      ...z,
      x: pos.x != null ? Math.round(pos.x * 100) / 100 : z.x,
      y: pos.y != null ? Math.round(pos.y * 100) / 100 : z.y,
      z: pos.z != null ? Math.round(pos.z * 100) / 100 : z.z,
      heading: pos.heading != null ? Math.round(pos.heading * 10) / 10 : (z.heading || 0),
    } : z));
  }

  function teleportToZone(zone) {
    if (zone.x == null || zone.y == null) return;
    teleportToPosition(zone.x, zone.y, zone.z || 70, zone.heading || 0);
  }

  function moveUp(index) {
    if (index === 0) return;
    const copy = [...zones];
    [copy[index - 1], copy[index]] = [copy[index], copy[index - 1]];
    zones = copy;
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
  }

  function moveDown(index) {
    if (index === zones.length - 1) return;
    const copy = [...zones];
    [copy[index + 1], copy[index]] = [copy[index], copy[index + 1]];
    zones = copy;
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
  }

  function isPlaced(zone) {
    return zone && zone.x != null && zone.y != null && !(zone.x === 0 && zone.y === 0 && (zone.z === 0 || zone.z == null));
  }

  function fmt(val) {
    if (val == null || isNaN(val)) return '—';
    return Number(val).toFixed(1);
  }

  // ── Multi-select bulk delete ──
  let checkedIds = [];
  $: checkedCount = zones.filter((z) => checkedIds.includes(z.id)).length;

  function toggleChecked(id) {
    checkedIds = checkedIds.includes(id) ? checkedIds.filter((x) => x !== id) : [...checkedIds, id];
  }

  function toggleAllChecked() {
    checkedIds = checkedCount === zones.length ? [] : zones.map((z) => z.id);
  }

  async function removeChecked() {
    const ids = zones.filter((z) => checkedIds.includes(z.id)).map((z) => z.id);
    if (ids.length === 0) return;
    const ok = await confirmAction(`Delete the ${ids.length} selected drop zone${ids.length === 1 ? '' : 's'}? This cannot be undone.`, {
      title: 'Delete Selected Zones',
      danger: true,
      confirmLabel: 'Yes, Delete Selected'
    });
    if (!ok) return;
    dropZoneProps(ids);
    zones = zones.filter((z) => !ids.includes(z.id));
    checkedIds = [];
    if (placement === 'SEQUENTIAL') autoDistributeTiming();
  }

  async function removeAllZones() {
    if (zones.length === 0) return;
    const ok = await confirmAction(`Delete all ${zones.length} drop zones? This cannot be undone.`, {
      title: 'Delete All Drop Zones',
      danger: true,
      confirmLabel: 'Yes, Delete All'
    });
    if (!ok) return;
    dropZoneProps(zones.map((z) => z.id));
    zones = [];
    checkedIds = [];
  }

  // ── Drag & Drop Drop Zone Reordering Engine ──
  let draggedId = null;
  let draggedIndex = null;
  let dragOverIndex = null;
  let dragLabel = '';
  let ghostX = 0, ghostY = 0;

  function startDrag(index, zone, e) {
    if (locked) return;
    e.preventDefault();
    e.stopPropagation();
    draggedId = zone.id;
    draggedIndex = index;
    dragOverIndex = index;
    dragLabel = `#${index + 1} DROP ZONE — ${zone.name || zone.label || `Drop Zone ${index + 1}`}`;
    ghostX = e.clientX;
    ghostY = e.clientY;
    window.addEventListener('mousemove', onDragMove, { passive: false });
    window.addEventListener('mouseup', onDragRelease);
  }

  function onDragMove(e) {
    if (draggedId === null || draggedIndex === null) return;
    ghostX = e.clientX;
    ghostY = e.clientY;

    const cards = document.querySelectorAll('.point-card');
    if (!cards || cards.length === 0) return;
    let target = draggedIndex;
    for (let j = 0; j < cards.length; j++) {
      const rect = cards[j].getBoundingClientRect();
      if (e.clientY >= rect.top && e.clientY <= rect.bottom) {
        const midY = rect.top + rect.height / 2;
        target = e.clientY < midY ? j : j + 1;
        break;
      } else if (e.clientY < rect.top && j === 0) {
        target = 0;
        break;
      } else if (e.clientY > rect.bottom && j === cards.length - 1) {
        target = cards.length;
        break;
      }
    }
    dragOverIndex = target;
  }

  function onDragRelease() {
    window.removeEventListener('mousemove', onDragMove);
    window.removeEventListener('mouseup', onDragRelease);

    if (draggedIndex !== null && dragOverIndex !== null && dragOverIndex !== draggedIndex) {
      let targetIdx = dragOverIndex;
      if (targetIdx > draggedIndex) {
        targetIdx = targetIdx - 1;
      }
      if (targetIdx !== draggedIndex && targetIdx >= 0 && targetIdx < zones.length) {
        const copy = [...zones];
        const [moved] = copy.splice(draggedIndex, 1);
        copy.splice(targetIdx, 0, moved);
        zones = copy;
        if (placement === 'SEQUENTIAL') autoDistributeTiming();
      }
    }

    draggedId = null;
    draggedIndex = null;
    dragOverIndex = null;
  }

  // ── Portal Action for Modals ──
  function portal(node) {
    document.body.appendChild(node);
    return {
      destroy() {
        if (node.parentNode) {
          node.parentNode.removeChild(node);
        }
      }
    };
  }

  // ── Manual Sequence Number Changing ──
  let showNumberModal = false;
  let numberEditIndex = null;
  let targetZoneNumber = 1;

  function openNumberModal(index) {
    if (locked) return;
    numberEditIndex = index;
    targetZoneNumber = index + 1;
    showNumberModal = true;
    setTimeout(() => {
      const el = document.querySelector('.num-stepper-input');
      if (el) {
        el.focus();
        el.select();
      }
    }, 50);
  }

  function closeNumberModal() {
    showNumberModal = false;
    numberEditIndex = null;
  }

  function stepTargetNumber(delta) {
    const cur = parseInt(targetZoneNumber, 10) || 1;
    targetZoneNumber = Math.max(1, Math.min(cur + delta, zones.length));
  }

  // A pin clicked on the map selects its zone card and brings it into view, same as the Convoy route builder does for a point.
  function handleMapZoneSelect(e) {
    const id = e.detail?.id || null;
    selectedPointId = id;
    if (!id) return;
    const card = document.querySelector(`.zone-card[data-id="${id}"]`);
    if (card) card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  function applyNumberChange() {
    if (numberEditIndex === null || locked) return;
    const num = parseInt(targetZoneNumber, 10);
    if (isNaN(num)) return;
    const targetIdx = Math.max(0, Math.min(num - 1, zones.length - 1));
    const movedZoneId = zones[numberEditIndex]?.id;
    if (targetIdx !== numberEditIndex) {
      const copy = [...zones];
      const [moved] = copy.splice(numberEditIndex, 1);
      copy.splice(targetIdx, 0, moved);
      zones = copy;
      if (placement === 'SEQUENTIAL') autoDistributeTiming();
    }
    closeNumberModal();
    if (movedZoneId) {
      selectedPointId = movedZoneId;
      setTimeout(() => {
        const card = document.querySelector(`.zone-card[data-id="${movedZoneId}"]`);
        if (card) {
          card.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }, 100);
    }
  }

  // ── Insert Zone Modal (Before / After) ──
  let showInsertModal = false;
  let insertRefIndex = 0;
  let insertPosition = 'after'; // 'before' | 'after'
  let insertPlacementMode = 'position'; // 'position' | 'manual'
  let insertManualCoords = { x: 0, y: 0, z: 70, heading: 0 };
  let insertingBusy = false;

  function openInsertModal(refIdx = 0, pos = 'after') {
    if (locked) return;
    insertRefIndex = Math.max(0, Math.min(refIdx, zones.length > 0 ? zones.length - 1 : 0));
    insertPosition = pos;
    insertPlacementMode = 'position';
    const refZone = zones[insertRefIndex];
    if (refZone) {
      insertManualCoords = { x: refZone.x ?? 0, y: refZone.y ?? 0, z: refZone.z ?? 70, heading: refZone.heading ?? 0 };
    } else {
      insertManualCoords = { x: 0, y: 0, z: 70, heading: 0 };
    }
    showInsertModal = true;
  }

  function closeInsertModal() {
    showInsertModal = false;
  }

  async function confirmInsertZone() {
    if (locked) return;
    insertingBusy = true;
    let coords = { x: 0, y: 0, z: 70, heading: 0 };
    if (insertPlacementMode === 'position') {
      const pos = await getPlayerPosition();
      if (pos && pos.x != null) {
        coords = {
          x: Math.round(pos.x * 100) / 100,
          y: Math.round(pos.y * 100) / 100,
          z: Math.round(pos.z * 100) / 100,
          heading: pos.heading != null ? Math.round(pos.heading * 10) / 10 : 0
        };
      }
    } else {
      coords = {
        x: parseFloat(insertManualCoords.x) || 0,
        y: parseFloat(insertManualCoords.y) || 0,
        z: parseFloat(insertManualCoords.z) || 70,
        heading: parseFloat(insertManualCoords.heading) || 0
      };
    }

    const targetIdx = insertPosition === 'before' ? insertRefIndex : insertRefIndex + 1;
    const newZone = {
      ...defaultZone(),
      id: nextId(),
      x: coords.x,
      y: coords.y,
      z: coords.z,
      heading: coords.heading,
    };

    const copy = [...zones];
    copy.splice(targetIdx, 0, newZone);
    zones = copy;
    if (placement === 'SEQUENTIAL') autoDistributeTiming();

    insertingBusy = false;
    showInsertModal = false;
    revealLast('.zone-card');
  }

  function previewZonesOnMap() {
    const valid = zones.filter((z) => z.x != null && z.y != null);
    if (valid.length === 0) return;
    const points = valid.map((z, i) => ({
      id: z.id,
      type: 'AIRDROP',
      x: z.x,
      y: z.y,
      z: z.z || 0,
      order: i,
    }));
    previewRoute(points, [], []);
  }

  function applyImportedTemplate(e) {
    const res = e.detail;
    if (res.kind && res.kind !== 'GANG_AIRDROP') return;
    zones = res.airdropZones || [];
  }

  let zoneRecording = false;
  const unsubZoneRecording = zoneRecordingResult.subscribe((msg) => {
    if (!msg) return;
    if (msg.target && msg.target !== 'GANG_AIRDROP') return;
    const points = msg.points || [];
    if (points.length > 0) {
      const base = zones.length;
      const added = points.map((p, i) => {
        const title = `Drop Zone ${base + i + 1}`;
        return { ...defaultZone(), label: title, name: title, x: p.x, y: p.y, z: p.z, heading: p.heading || 0 };
      });
      zones = [...zones, ...added];
      revealLast('.zone-card');
    }
    zoneRecording = false;
    zoneRecordingResult.set(null);
  });

  async function beginZoneRecording() {
    zoneRecording = true;
    await startZoneRecording({ primaryLabel: 'Drop Zone', target: 'GANG_AIRDROP' });
  }

  onDestroy(() => {
    clearRoutePreview();
    unsubZoneRecording();
    window.removeEventListener('mousemove', onDragMove);
    window.removeEventListener('mouseup', onDragRelease);
  });

  let zoneNames = {};
  let zoneKeys = {};
  async function ensureZoneName(zone) {
    if (zone.x == null || zone.y == null) return;
    const key = `${Math.round(zone.x)},${Math.round(zone.y)}`;
    if (zoneKeys[zone.id] === key) return;
    zoneKeys[zone.id] = key;
    const res = await getZoneName(zone.x, zone.y, zone.z || 0);
    zoneNames = { ...zoneNames, [zone.id]: (res && res.name) || null };
  }
  $: zones.forEach(ensureZoneName);

  $: for (const [i, z] of zones.entries()) {
    if (!z.label && !z.name) {
      z.label = `Drop Zone ${i + 1}`;
      z.name = z.label;
    } else if (!z.name) {
      z.name = z.label;
    } else if (!z.label) {
      z.label = z.name;
    }
    if (z.guardCount == null) z.guardCount = 3;
    if (!z.guardModel) z.guardModel = 'g_m_y_lost_01';
    if (!z.guardWeapon) z.guardWeapon = 'WEAPON_MICROSMG';
    if (!z.guardAggressiveness) z.guardAggressiveness = 'medium';
    if (z.requireLockpick == null) z.requireLockpick = true;
    if (z.lockpicksRequired == null) z.lockpicksRequired = '';
    if (z.chance == null) z.chance = 60;
    if (!z.rewards) z.rewards = [{ type: 'MONEY', amount: 500, pool: '' }];
  }

  // "Drop Zone 1, 2, 3…" always matches each zone's current position: deleting, adding or importing never leaves gaps
  // or duplicates. A zone you renamed keeps its own name.
  $: if (!locked) {
    const renamed = renumberAuto(zones, 'Drop Zone ', { fields: ['name', 'label'] });
    if (renamed !== zones) zones = renamed;
  }
</script>

<div class="zones">
  <div class="header-row">
    <div class="section-title">
      Drop Zones
      <span class="count">{zones.length} zone{zones.length === 1 ? '' : 's'} configured</span>
    </div>
    <div class="header-actions">
      {#if zones.some((z) => z.x != null && z.y != null)}
        <button class="btn btn-preview" on:click={previewZonesOnMap} title="Open real GTA pause map with drop zone blips">
          <Icon name="activity" size={13} /> Preview on Map
        </button>
      {/if}
      {#if !locked && zones.length > 0}
        <button class="btn" on:click={autoDistributeTiming} title="Auto-stagger drop times evenly across {Math.round(eventDuration / 60)} minutes">
          <Icon name="clock" size={13} /> Stagger Drops ({Math.round(eventDuration / 60)}m)
        </button>
      {/if}
      {#if !locked}
        <button class="btn btn-primary" on:click={() => (showAutoAddModal = true)} title="Auto-add random drop zones from the 25 predefined San Andreas locations">
          <Icon name="plus" size={13} /> Auto-Add Zones
        </button>
        <button class="btn btn-steel" on:click={addZoneHere}><Icon name="pin" size={13} /> Add Pin Here</button>
        <button class="btn btn-steel" on:click={addManualZone}><Icon name="plus" size={13} /> Add Manually</button>
        <button class="btn btn-steel" disabled={zoneRecording} on:click={beginZoneRecording} title="Walk to each spot and press [E] to drop a zone, [Enter] finishes and returns you here">
          <Icon name="pin" size={13} /> {zoneRecording ? 'Recording...' : 'Add Zones (Walk & Drop)'}
        </button>
      {/if}
    </div>
  </div>

  <p class="hint">
    Each zone is a standalone supply drop point across San Andreas. A cargo plane flies over and parachutes down a secured crate with smoke flares.
    You can add zones manually, walk and drop them in-game, or use the 25-location pool to automatically randomize drops across the map.
  </p>

  <!-- Drop Zones Map UI (Positioned at Top) -->
  <div class="map-preview">
    <div class="map-preview-title">
      <Icon name="activity" size={13} /> Drop Zones Map
      <span class="map-preview-sub">— drag to pan, scroll to zoom, click pin to select</span>
    </div>
    {#if zones.some((z) => z.x != null && z.y != null)}
      <RoutePreviewMap
        {zones}
        eventKind="GANG_AIRDROP"
        legend={false}
        height={440}
        editable={!locked}
        bind:selectedPointId
        on:pointDrag={(e) => liveMove(e.detail)}
        on:pointMove={(e) => { liveMove.cancel(); zones = applyMove(zones, e.detail); }}
        on:selectPoint={handleMapZoneSelect}
      />
      <div class="map-legend">
        <span class="legend-item"><span class="legend-dot" style="background:#9b7bff"></span>Airdrop Supply Drop Zone (35m drop radius)</span>
      </div>
    {:else}
      <div class="map-empty">Add at least one drop zone with coordinates to see it plotted on the GTA map.</div>
    {/if}
  </div>

  <!-- Random Airdrop Locations & Configuration Card -->
  <div class="randomizer-panel">
    <div class="randomizer-head">
      <div class="randomizer-title-wrap">
        <div class="randomizer-title">
          <Icon name="shuffle" size={15} />
          <span>Random Airdrop Locations</span>
        </div>
        <p class="randomizer-desc">
          Each run can drop on a random selection of the zones you set up below, so gangs cannot predict which spots are used. The 25-location preset list only helps you fill the zone list (Generate and Auto-Add).
        </p>
      </div>
      <div class="randomizer-badge">
        <Icon name="pin" size={12} />
        <span>Picks from your {zones.length} zone{zones.length === 1 ? '' : 's'}</span>
      </div>
    </div>

    <div class="randomizer-grid">
      <!-- Left Subcard: Quantity & Instant Population -->
      <div class="randomizer-subcard">
        <div class="subcard-header">
          <div class="subcard-title">
            <Icon name="box" size={14} />
            <span>Drop Crate Quantity</span>
          </div>
          <span class="subcard-tag">Editor Setup</span>
        </div>
        <p class="subcard-desc">
          How many of your zones drop in a random run (never more than the zones you have). <b>Generate</b> replaces the zone list below with this many random spots from the 25-location preset list. With <b>Rotate Spots Every Run</b> off, every zone below drops and this number is not used.
        </p>
        <div class="subcard-action-row">
          <div class="count-input-wrap">
            <span class="count-prefix">COUNT</span>
            <input
              type="number"
              min="1"
              max="50"
              bind:value={settings.airdropCount}
              disabled={locked}
              placeholder="10"
              class="count-input"
            />
            <span class="count-unit">drops</span>
          </div>
          {#if !locked}
            <button
              type="button"
              class="btn btn-primary btn-generate"
              on:click={generateRandomDrops}
              title="Populate {settings.airdropCount || 10} random drop zones from the 25 pool into this editor now"
            >
              <Icon name="shuffle" size={13} />
              <span>Generate {settings.airdropCount || 10} Drops Now</span>
            </button>
          {/if}
        </div>
      </div>

      <!-- Right Subcard: Dynamic Runtime Randomization -->
      <div class="randomizer-subcard" class:is-active={settings.randomizeLocations}>
        <div class="subcard-header">
          <div class="subcard-title">
            <Icon name="refresh" size={14} />
            <span>Runtime Randomization</span>
          </div>
          <span class="subcard-pill" class:pill-active={settings.randomizeLocations}>
            {settings.randomizeLocations ? 'ACTIVE ROTATION' : 'FIXED LOCATIONS'}
          </span>
        </div>
        <p class="subcard-desc">
          Each time this event starts, it picks that many of your own zones at random, in a random order. A zone you did not set up is never used, and your saved zones are not changed.
        </p>
        <div class="subcard-toggle-row">
          <div class="toggle-lead-wrap">
            <span class="toggle-lead-title">Rotate Spots Every Run</span>
            <span class="toggle-lead-hint">
              {settings.randomizeLocations
                ? `Random: ${Math.min(Number(settings.airdropCount) || zones.length, zones.length)} of your ${zones.length} zone${zones.length === 1 ? '' : 's'} each run`
                : 'Fixed: every zone below drops, in order'}
            </span>
          </div>
          <div class="subcard-toggle-control">
            <Toggle
              label=""
              bind:checked={settings.randomizeLocations}
              disabled={locked}
            />
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- Main settings + apply to chosen zones -->
  <div class="bulk-panel">
    <div class="bulk-panel-head">
      <span class="bulk-icon-box"><Icon name="gift" size={14} /></span>
      <div>
        <div class="bulk-title">Main settings — guards &amp; rewards</div>
        <div class="bulk-subtitle">A template that belongs to no zone. New zones start from it, and you apply it to exactly the zones you tick. Each zone can still be customised on its own card.</div>
      </div>
    </div>

    {#if settings.airdropMain}
      <div class="main-grid">
        <div class="bulk-card">
          <div class="bulk-card-head"><div class="bulk-title-wrap"><span class="bulk-icon-box"><Icon name="shield" size={14} /></span><div><div class="bulk-title">Guards</div><div class="bulk-subtitle">Hostile-to-everyone thugs defending each crate</div></div></div></div>
          <div class="field-row">
            <div class="field">
              <label for="main-gcount">Guard Count <span class="optional">0 = unguarded</span></label>
              <input id="main-gcount" type="number" min="0" max="10" bind:value={settings.airdropMain.guardCount} disabled={locked} />
            </div>
            <div class="field">
              <label for="main-gaggr">Shooting Aggressiveness</label>
              <select id="main-gaggr" bind:value={settings.airdropMain.guardAggressiveness} disabled={locked || !settings.airdropMain.guardCount}>
                {#each AGGRESSIVENESS_OPTIONS as a}<option value={a.value}>{a.label}</option>{/each}
              </select>
            </div>
          </div>
          <div class="field-row">
            <div class="field">
              <label for="main-gmodel">Guard Ped Model</label>
              <select id="main-gmodel" bind:value={settings.airdropMain.guardModel} disabled={locked || !settings.airdropMain.guardCount}>
                {#each GUARD_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
              </select>
            </div>
            <div class="field">
              <label for="main-gweapon">Guard Weapon</label>
              <select id="main-gweapon" bind:value={settings.airdropMain.guardWeapon} disabled={locked || !settings.airdropMain.guardCount}>
                {#each GUARD_WEAPONS as w}<option value={w.value}>{w.label}</option>{/each}
              </select>
            </div>
          </div>
        </div>

        <div class="bulk-card">
          <div class="bulk-card-head"><div class="bulk-title-wrap"><span class="bulk-icon-box"><Icon name="gift" size={14} /></span><div><div class="bulk-title">Rewards</div><div class="bulk-subtitle">What a crate pays and how it is opened</div></div></div></div>
          <Toggle label="Require a lockpick to crack open the crate" bind:checked={settings.airdropMain.requireLockpick} disabled={locked} />
          {#if settings.airdropMain.requireLockpick}
            <div class="field-row">
              <div class="field">
                <label for="main-lp">Lockpicks Required <span class="optional">blank = server default</span></label>
                <input id="main-lp" type="text" inputmode="numeric" placeholder="e.g. 2" bind:value={settings.airdropMain.lockpicksRequired} disabled={locked} />
              </div>
              <div class="field">
                <label for="main-chance">Chance of Any Reward (%)</label>
                <input id="main-chance" type="number" min="0" max="100" bind:value={settings.airdropMain.chance} disabled={locked} />
              </div>
            </div>
          {:else}
            <p class="inline-hint">Hacking always guarantees the reward below — there is no chance roll in this mode.</p>
          {/if}
          <RewardListEditor bind:rewards={settings.airdropMain.rewards} disabled={locked} />
        </div>
      </div>

      {#if zones.length > 0}
        <div class="bulk-pick-row top">
          <span class="bulk-pick-label">Apply to</span>
          <div class="bulk-targets">
            <div class="target-chips" role="group" aria-label="Zones that receive the Main settings">
              {#each zones as z, i (z.id)}
                <button type="button" class="tchip" class:on={targetIds.has(z.id)} disabled={locked} title={zoneName(z, i)} on:click={() => toggleTarget(z.id)}>
                  {#if targetIds.has(z.id)}<Icon name="check" size={11} />{/if} Zone {i + 1}
                </button>
              {/each}
            </div>
            <div class="target-tools">
              <div class="seg-group" role="group" aria-label="Select zones">
                <button type="button" class="seg-btn" disabled={locked} on:click={selectAllTargets}>All</button>
                <button type="button" class="seg-btn" disabled={locked} on:click={clearTargets}>None</button>
                <button type="button" class="seg-btn" disabled={locked} on:click={invertTargets}>Invert</button>
              </div>
              <span class="target-count">{targetIds.size} of {zones.length} selected</span>
            </div>
          </div>
        </div>
        {#if !locked}
          <div class="apply-row">
            <span class="apply-label">Apply Main to the ticked zones</span>
            <button type="button" class="btn btn-steel" disabled={targetIds.size === 0} on:click={() => applyMain('guards')} title="Copy the Main guard settings to the ticked zones (their rewards are not touched)">
              <Icon name="shield" size={13} /> <span>Apply guards ({targetIds.size})</span>
            </button>
            <button type="button" class="btn btn-steel" disabled={targetIds.size === 0} on:click={() => applyMain('rewards')} title="Copy the Main reward settings to the ticked zones (their guards are not touched)">
              <Icon name="gift" size={13} /> <span>Apply rewards ({targetIds.size})</span>
            </button>
            <button type="button" class="btn btn-primary" disabled={targetIds.size === 0} on:click={() => applyMain('both')} title="Copy both the Main guard and reward settings to the ticked zones">
              <Icon name="copy" size={13} /> <span>Apply guards + rewards ({targetIds.size})</span>
            </button>
            {#if zones.length > 0}
              <span class="load-main">
                <select bind:value={loadFromId} aria-label="Load the Main settings from a zone">
                  <option value="">Load Main from a zone…</option>
                  {#each zones as z, i (z.id)}<option value={z.id}>Zone {i + 1} — {zoneName(z, i)}</option>{/each}
                </select>
                <button type="button" class="btn btn-steel" disabled={!loadFromId} on:click={loadMainFrom}><Icon name="download" size={13} /> <span>Load</span></button>
              </span>
            {/if}
          </div>
        {/if}
      {:else}
        <div class="bulk-empty">Add drop zones to apply these settings to them.</div>
      {/if}
    {/if}
  </div>

  <!-- Drop scheduling -->
  <div class="placement-bar">
    <div class="placement-label"><Icon name="clock" size={13} /> Drop Schedule</div>
    <div class="chip-row">
      {#each PLACEMENT_MODES as mode}
        <button
          type="button"
          class="chip-btn"
          class:active={placement === mode.value}
          disabled={locked}
          title={mode.hint}
          on:click={() => setPlacement(mode.value)}
        >{mode.label}</button>
      {/each}
    </div>
    <p class="placement-hint">
      {#if placement === 'SIMULTANEOUS'}
        Every zone opens together — <strong>{zones.length}</strong> crate{zones.length === 1 ? '' : 's'} on the map at once, each up for {formatTime(zones[0] ? zones[0].duration : 0)}. Gangs have to split up and choose which drop to contest.
      {:else if placement === 'MANUAL'}
        Each zone opens at its own <strong>Activation Delay</strong> below and stays for its own <strong>Duration</strong> — set them by hand. Zones whose windows overlap will be live simultaneously.
      {:else}
        Drops arrive one at a time, queued across the event — a new crate lands after the previous one closes. Use <strong>Stagger Drops</strong> above to recompute the timetable for the event's current length.
      {/if}
    </p>
  </div>

  <SavedTemplatePicker kind="GANG_AIRDROP" payload={{ airdropZones: zones }} {locked} on:import={applyImportedTemplate} />

  {#if !locked}
    <div class="add-point-row">
      <button class="btn btn-steel" on:click={addManualZone}><Icon name="waypointPlus" size={13} /> Add Manually</button>
      <button class="btn btn-steel btn-insert" on:click={() => openInsertModal(zones.length > 0 ? zones.length - 1 : 0, 'after')} disabled={zones.length === 0} title="Insert a drop zone before or after a specific zone">
        <Icon name="waypointPlus" size={13} /> Insert Zone…
      </button>
      <button class="btn btn-steel" on:click={addZoneHere}><Icon name="pin" size={13} /> Add Pin Here</button>
      <button class="btn btn-steel" disabled={zoneRecording} on:click={beginZoneRecording} title="Walk to each spot and press [E] to drop a zone, [Enter] finishes and returns you here">
        <Icon name="pin" size={13} /> {zoneRecording ? 'Recording...' : 'Add Zones (Walk & Drop)'}
      </button>
      <button class="btn btn-danger" disabled={zones.length === 0} on:click={removeAllZones} title="Delete every drop zone"><Icon name="routeClear" size={13} /> Delete All</button>
    </div>

    {#if zones.length > 0}
      <div class="select-bar">
        <label class="select-all" title="Tick the box on any zone card to pick which ones to delete">
          <input type="checkbox" checked={checkedCount === zones.length} indeterminate={checkedCount > 0 && checkedCount < zones.length} on:change={toggleAllChecked} />
          <span>{checkedCount > 0 ? `${checkedCount} selected` : 'Select zones to delete'}</span>
        </label>
        {#if checkedCount > 0}
          <button class="btn btn-steel" on:click={() => (checkedIds = [])}>Clear</button>
          <button class="btn btn-danger" on:click={removeChecked}><Icon name="trash" size={13} /> Delete Selected ({checkedCount})</button>
        {/if}
      </div>
    {/if}
  {/if}

  {#if draggedId !== null}
    <div class="drag-ghost" style="left:{ghostX}px; top:{ghostY}px; --point-accent:#9b7bff">
      <div class="drag-ghost-badge">
        <Icon name="grip" size={14} />
        <span>#{draggedIndex + 1}</span>
      </div>
      <div class="drag-ghost-info">
        <span class="drag-ghost-label">{dragLabel}</span>
        <span class="drag-ghost-slot">
          {#if dragOverIndex !== null}
            Target: Position #{dragOverIndex >= zones.length ? zones.length : dragOverIndex + 1}
          {:else}
            Dragging...
          {/if}
        </span>
      </div>
    </div>
  {/if}

  {#if zones.length === 0}
    <div class="empty">No drop zones configured yet. Click "Auto-Add Zones", "Add Pin Here" or "Add Manually" above.</div>
  {/if}

  <div class="point-list">
    {#each zones as zone, idx (zone.id)}
      {#if draggedId !== null && dragOverIndex === idx}
        <div class="drop-indicator-line">
          <div class="drop-indicator-pill">
            <Icon name="chevronDown" size={12} />
            <span>Insert as Zone #{idx + 1}</span>
            <Icon name="chevronDown" size={12} />
          </div>
        </div>
      {/if}

      <div
        class="point-card zone-card"
        data-id={zone.id}
        data-index={idx}
        class:selected={selectedPointId === zone.id}
        class:dragging={zone.id === draggedId}
        style="--point-accent:#9b7bff"
        on:click={() => { selectedPointId = zone.id; }}
      >
        <div class="point-top">
          <div class="point-left">
            {#if !locked}
              <input
                type="checkbox"
                class="point-check"
                title="Select this zone for bulk delete"
                checked={checkedIds.includes(zone.id)}
                on:click|stopPropagation
                on:change={() => toggleChecked(zone.id)}
              />
              <div
                class="drag-handle"
                title="Click and drag to reorder this drop zone"
                on:mousedown={(e) => startDrag(idx, zone, e)}
                role="button"
                tabindex="0"
              >
                <Icon name="grip" size={16} />
                <span class="drag-handle-hint">DRAG</span>
              </div>
            {/if}

            <!-- Clickable Number Badge to manually change zone number -->
            <button
              type="button"
              class="point-order-btn"
              title="Click to manually change zone number (#{idx + 1})"
              disabled={locked}
              on:click={() => openNumberModal(idx)}
            >
              <span class="order-hash">#</span><span class="order-num">{idx + 1}</span>
              <span class="order-edit-icon"><Icon name="edit" size={10} /></span>
            </button>

            <!-- Type badge pill: DROP ZONE with box icon -->
            <div class="type-badge-pill" style="border-left-color: #9b7bff">
              <Icon name="box" size={14} />
              <span class="type-pill-label">DROP ZONE</span>
            </div>

            <!-- Zone Name Input & Area Tag -->
            <div class="point-info-group">
              <input
                type="text"
                class="zone-name-inline"
                bind:value={zone.name}
                on:input={() => { zone.label = zone.name; }}
                placeholder="Drop Zone Name"
                maxlength="60"
                disabled={locked}
              />
              {#if idx === 0}
                <span class="zone-master-badge">⭐ Master Zone #1</span>
              {/if}
              {#if zoneNames[zone.id]}
                <span class="point-zone-pill"><Icon name="pin" size={11} /> {zoneNames[zone.id]}</span>
              {/if}
            </div>

            <!-- Coordinates preview pill -->
            <div class="point-coords-preview mono" title="Coordinates: X={fmt(zone.x)}, Y={fmt(zone.y)}, Z={fmt(zone.z)}, H={fmt(zone.heading)}°">
              <span
                class="placed-dot"
                class:placed={isPlaced(zone)}
                title={isPlaced(zone) ? 'Position set' : 'Position not set'}
              ></span>
              <span>{fmt(zone.x)}, {fmt(zone.y)}</span>
            </div>
          </div>

          <div class="point-actions">
            {#if zone.x != null && $bootstrap?.isAdmin}
              <button class="icon-btn info icon-btn-text" title="Teleport to this zone" on:click={() => teleportToZone(zone)}>
                <Icon name="teleport" size={13} /> Teleport
              </button>
            {/if}
            {#if !locked}
              <button class="icon-btn info icon-btn-text" title="Change sequence number" on:click={() => openNumberModal(idx)}>
                <Icon name="edit" size={12} /> Change #
              </button>
              <button class="icon-btn info icon-btn-text" title="Insert a drop zone before this zone" on:click={() => openInsertModal(idx, 'before')}>
                <Icon name="waypointPlus" size={12} /> + Before
              </button>
              <button class="icon-btn info icon-btn-text" title="Insert a drop zone after this zone" on:click={() => openInsertModal(idx, 'after')}>
                <Icon name="waypointPlus" size={12} /> + After
              </button>
              <button class="icon-btn success icon-btn-text" title="Set to my current position" on:click={() => pinToMyPosition(zone.id)}>
                <Icon name="pin" size={13} /> Set Position
              </button>
              <button
                class="icon-btn info icon-btn-text"
                title={isPlaced(zone) ? 'Open the Prop Placer on this zone and add scenery around the crate' : 'Set this zone\'s position first'}
                disabled={placerBusy || !isPlaced(zone)}
                on:click={() => openZonePlacer(zone)}
              >
                <Icon name="box" size={13} /> Prop Placer{zonePropCount[zone.id] ? ` (${zonePropCount[zone.id]})` : ''}
              </button>
              <button class="icon-btn btn-move icon-btn-text" title="Move up" on:click={() => moveUp(idx)} disabled={idx === 0}>
                <Icon name="chevronUp" size={14} /> Up
              </button>
              <button class="icon-btn btn-move icon-btn-text" title="Move down" on:click={() => moveDown(idx)} disabled={idx === zones.length - 1}>
                <Icon name="chevronDown" size={14} /> Down
              </button>
              <button class="icon-btn danger icon-btn-text" title="Remove drop zone" on:click={() => removeZone(zone.id)}>
                <Icon name="trash" size={14} /> Delete
              </button>
            {/if}
          </div>
        </div>

        <!-- 4-Column Vector Row: X, Y, Z, Heading -->
        <fieldset class="point-fieldset" disabled={locked}>
          <div class="point-coords">
            <div class="coord-field">
              <label>X</label>
              <input type="number" step="0.01" bind:value={zone.x} disabled={locked} placeholder="0.00" />
            </div>
            <div class="coord-field">
              <label>Y</label>
              <input type="number" step="0.01" bind:value={zone.y} disabled={locked} placeholder="0.00" />
            </div>
            <div class="coord-field">
              <label>Z</label>
              <input type="number" step="0.01" bind:value={zone.z} disabled={locked} placeholder="70.00" />
            </div>
            <div class="coord-field">
              <label>Heading</label>
              <input type="number" step="0.1" bind:value={zone.heading} disabled={locked} placeholder="0.0" />
            </div>
          </div>
        </fieldset>

      <!-- Every setting of the zone in a compact grid: four fields to a row, a thin heading per group -->
      <div class="zc-grid">
        <div class="field">
          <label>Activation delay (s)</label>
          <input type="number" min="0" bind:value={zone.activationDelay} disabled={locked} />
        </div>
        <div class="field">
          <label>Crate duration (s)</label>
          <input type="number" min="10" bind:value={zone.duration} disabled={locked} />
        </div>
        <div class="field zc-toggle">
          <label>Announce drop</label>
          <Toggle label={zone.announce ? 'On' : 'Off'} bind:checked={zone.announce} disabled={locked} />
        </div>
        <div class="field">
          <label>Timeline</label>
          <div class="zc-readout">Drops at T+{formatTime(zone.activationDelay)}, stays {formatTime(zone.duration)}</div>
        </div>
      </div>

      <div class="zc-sub">
        <span>Guards &amp; security</span>
        {#if !locked && settings.airdropMain}
          <button type="button" class="btn btn-xs btn-steel" on:click={() => applyMain('guards', new Set([zone.id]))} title="Replace this zone's guard settings with the Main guard settings">
            Use Main guards
          </button>
        {/if}
      </div>
      <div class="zc-grid">
        <div class="field">
          <label>Guard count <span class="optional">0 = none</span></label>
          <input type="number" min="0" max="10" bind:value={zone.guardCount} disabled={locked} />
        </div>
        <div class="field">
          <label>Aggressiveness</label>
          <select bind:value={zone.guardAggressiveness} disabled={locked || !zone.guardCount}>
            {#each AGGRESSIVENESS_OPTIONS as a}
              <option value={a.value}>{a.label}</option>
            {/each}
          </select>
        </div>
        <div class="field">
          <label>Ped model</label>
          <select bind:value={zone.guardModel} disabled={locked || !zone.guardCount}>
            {#each GUARD_MODELS as m}
              <option value={m.value}>{m.label}</option>
            {/each}
          </select>
        </div>
        <div class="field">
          <label>Weapon</label>
          <select bind:value={zone.guardWeapon} disabled={locked || !zone.guardCount}>
            {#each GUARD_WEAPONS as w}
              <option value={w.value}>{w.label}</option>
            {/each}
          </select>
        </div>
      </div>

      <div class="zc-sub">
        <span>Crate rewards</span>
        {#if !locked && settings.airdropMain}
          <button type="button" class="btn btn-xs btn-steel" on:click={() => applyMain('rewards', new Set([zone.id]))} title="Replace this zone's reward settings with the Main reward settings">
            Use Main rewards
          </button>
        {/if}
      </div>
      <div class="zc-grid">
        <div class="field zc-toggle">
          <label>Lockpick needed</label>
          <Toggle label={zone.requireLockpick ? 'Yes' : 'No, hack'} bind:checked={zone.requireLockpick} disabled={locked} />
        </div>
        {#if zone.requireLockpick}
          <div class="field">
            <label>Lockpicks required <span class="optional">blank = default</span></label>
            <input type="text" inputmode="numeric" placeholder="e.g. 2" bind:value={zone.lockpicksRequired} disabled={locked} />
          </div>
          <div class="field">
            <label>Chance of reward (%)</label>
            <input type="number" min="0" max="100" bind:value={zone.chance} disabled={locked} />
          </div>
        {:else}
          <p class="zc-note zc-span">Hacking always guarantees the reward below, so there is no chance roll.</p>
        {/if}
      </div>
      <RewardListEditor bind:rewards={zone.rewards} disabled={locked} />

      <!-- This zone's props: the same objects the Prop Placer saved, listed here under the zone they belong to -->
      <div class="zc-sub">
        <span>Props{zonePropCount[zone.id] ? ` (${zonePropCount[zone.id]})` : ''}</span>
        {#if !locked}
          <button type="button" class="btn btn-xs btn-steel" disabled={placerBusy || !isPlaced(zone)} on:click={() => openZonePlacer(zone)} title="Open the Prop Placer on this zone">
            <Icon name="box" size={12} /> {zonePropCount[zone.id] ? 'Open in Prop Placer' : 'Add props'}
          </button>
        {/if}
      </div>
      {#if zonePropCount[zone.id]}
        <PropTable
          items={zonePropMap[zone.id]}
          {locked}
          busy={placerBusy}
          on:edit={(e) => openZonePlacer(zone, e.detail + 1)}
          on:teleport={(e) => teleportZoneProp(zone.id, e.detail)}
          on:remove={(e) => removeZoneProp(zone.id, e.detail)}
          on:removeAll={() => setZoneProps(zone.id, [])}
          on:bulk={(e) => setZoneProps(zone.id, zonePropMap[zone.id].map((o) => ({ ...o, ...e.detail })))}
        />
      {:else}
        <p class="zc-note">No props around this crate yet. Use the Prop Placer to add scenery.</p>
      {/if}
    </div>
  {/each}
  </div>
</div>

<!-- Auto-Add Zones Modal -->
{#if showAutoAddModal}
  <div class="modal-overlay" on:click={() => (showAutoAddModal = false)}>
    <div class="modal-box" on:click|stopPropagation>
      <div class="modal-header">
        <div class="modal-title"><Icon name="plus" size={15} /> Auto-Add Drop Zones</div>
        <button class="modal-close-btn" on:click={() => (showAutoAddModal = false)}><Icon name="close" size={14} /></button>
      </div>
      <div class="modal-body">
        <p class="modal-desc">
          How many drop zones would you like to add?
          The script will randomly generate and append valid drop zones from the 25 San Andreas location pool.
        </p>

        <div class="quick-chip-row">
          <span class="quick-chip-label">Quick presets:</span>
          {#each [1, 2, 3, 5, 10] as n}
            <button
              type="button"
              class="quick-preset-chip"
              class:active={autoAddCount === n}
              on:click={() => (autoAddCount = n)}
            >+{n}</button>
          {/each}
        </div>

        <div class="modal-field">
          <label>Number of Zones to Add</label>
          <input type="number" min="1" max="50" step="1" bind:value={autoAddCount} placeholder="3" />
        </div>

        <p class="modal-tip">
          💡 Existing zones will remain untouched. Newly added zones will automatically inherit Zone 1's NPC &amp; reward configurations.
        </p>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn" on:click={() => (showAutoAddModal = false)}>Cancel</button>
        <button type="button" class="btn btn-primary" on:click={() => confirmAutoAdd(autoAddCount)}>
          Add {autoAddCount || 1} Drop Zone{autoAddCount === 1 ? '' : 's'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showInsertModal}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div
    class="insert-backdrop"
    use:portal
    on:click|self={closeInsertModal}
    on:keydown={(e) => {
      if (e.key === 'Escape') closeInsertModal();
      else if (e.key === 'Enter') confirmInsertZone();
    }}
  >
    <div class="insert-box" role="dialog" aria-modal="true" aria-label="Insert Drop Zone">
      <div class="insert-head">
        <div class="insert-title">
          <Icon name="waypointPlus" size={15} />
          Insert Drop Zone
        </div>
        <button class="icon-btn" title="Close" on:click={closeInsertModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="insert-body">
        <div class="insert-field">
          <label>Target Drop Zone Reference</label>
          <select bind:value={insertRefIndex} class="insert-select">
            {#each zones as z, idx}
              <option value={idx}>#{idx + 1} — {z.name || z.label || `Drop Zone ${idx + 1}`}</option>
            {/each}
          </select>
        </div>

        <div class="insert-field">
          <label>Insert Position</label>
          <div class="insert-toggle-group">
            <button
              type="button"
              class="insert-toggle-btn"
              class:active={insertPosition === 'before'}
              on:click={() => (insertPosition = 'before')}
            >
              Insert Before #{insertRefIndex + 1}
            </button>
            <button
              type="button"
              class="insert-toggle-btn"
              class:active={insertPosition === 'after'}
              on:click={() => (insertPosition = 'after')}
            >
              Insert After #{insertRefIndex + 1}
            </button>
          </div>
          <div class="insert-hint">
            The new drop zone will become #{insertPosition === 'before' ? insertRefIndex + 1 : insertRefIndex + 2} in the sequence. All subsequent zones will automatically shift down.
          </div>
        </div>

        <div class="insert-field">
          <label>Placement Method</label>
          <div class="insert-toggle-group">
            <button
              type="button"
              class="insert-toggle-btn"
              class:active={insertPlacementMode === 'position'}
              on:click={() => (insertPlacementMode = 'position')}
            >
              <Icon name="pin" size={13} /> Current In-Game Position
            </button>
            <button
              type="button"
              class="insert-toggle-btn"
              class:active={insertPlacementMode === 'manual'}
              on:click={() => (insertPlacementMode = 'manual')}
            >
              <Icon name="settings" size={13} /> Set Coordinates Manually
            </button>
          </div>
        </div>

        {#if insertPlacementMode === 'manual'}
          <div class="insert-coords-grid">
            <div class="insert-coord-item">
              <span>X:</span>
              <input type="number" step="0.01" bind:value={insertManualCoords.x} placeholder="0.0" />
            </div>
            <div class="insert-coord-item">
              <span>Y:</span>
              <input type="number" step="0.01" bind:value={insertManualCoords.y} placeholder="0.0" />
            </div>
            <div class="insert-coord-item">
              <span>Z:</span>
              <input type="number" step="0.01" bind:value={insertManualCoords.z} placeholder="70.0" />
            </div>
            <div class="insert-coord-item">
              <span>Heading:</span>
              <input type="number" step="0.1" bind:value={insertManualCoords.heading} placeholder="0.0" />
            </div>
          </div>
        {:else}
          <div class="insert-pos-info">
            <Icon name="pin" size={14} />
            <span>Will automatically capture your in-game character coordinates and heading upon clicking Insert.</span>
          </div>
        {/if}
      </div>

      <div class="insert-foot">
        <button class="btn" on:click={closeInsertModal} disabled={insertingBusy}>Cancel</button>
        <span class="insert-spacer"></span>
        <button class="btn btn-primary" on:click={confirmInsertZone} disabled={insertingBusy}>
          {insertingBusy ? 'Inserting…' : 'Insert Drop Zone'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showNumberModal && numberEditIndex !== null && zones[numberEditIndex]}
  {@const curZone = zones[numberEditIndex]}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div
    class="insert-backdrop"
    use:portal
    on:click|self={closeNumberModal}
    on:keydown={(e) => {
      if (e.key === 'Escape') closeNumberModal();
      else if (e.key === 'Enter') applyNumberChange();
    }}
  >
    <div class="insert-box number-modal-box" role="dialog" aria-modal="true" aria-label="Change Drop Zone Number">
      <div class="insert-head">
        <div class="insert-title">
          <Icon name="edit" size={15} />
          Change Drop Zone Number
        </div>
        <button class="icon-btn" title="Close" on:click={closeNumberModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="insert-body">
        <div class="num-modal-summary">
          <div class="num-modal-badge" style="border-left-color: #9b7bff">
            <span class="num-modal-curr">Current Position: <strong>#{numberEditIndex + 1}</strong></span>
            <span class="num-modal-type">DROP ZONE</span>
            <span class="num-modal-name">{curZone.name || curZone.label || `Drop Zone ${numberEditIndex + 1}`}</span>
          </div>
          {#if zoneNames[curZone.id]}
            <div class="num-modal-zone"><Icon name="pin" size={12} /> {zoneNames[curZone.id]} (X: {fmt(curZone.x)}, Y: {fmt(curZone.y)})</div>
          {/if}
        </div>

        <div class="insert-field">
          <label>Target Drop Zone Number (1 to {zones.length})</label>
          <div class="num-stepper-row">
            <button
              type="button"
              class="stepper-btn"
              disabled={targetZoneNumber <= 1}
              on:click={() => stepTargetNumber(-1)}
              title="Decrease number"
            >
              <Icon name="chevronDown" size={16} />
            </button>
            <input
              type="number"
              class="num-stepper-input"
              min="1"
              max={zones.length}
              bind:value={targetZoneNumber}
              on:keydown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  applyNumberChange();
                } else if (e.key === 'Escape') {
                  e.preventDefault();
                  closeNumberModal();
                }
              }}
            />
            <button
              type="button"
              class="stepper-btn"
              disabled={targetZoneNumber >= zones.length}
              on:click={() => stepTargetNumber(1)}
              title="Increase number"
            >
              <Icon name="chevronUp" size={16} />
            </button>
          </div>
        </div>

        <div class="num-conflict-box">
          <div class="conflict-title">
            <Icon name="info" size={14} />
            <span>Automatic Sequence Reordering</span>
          </div>
          <p class="conflict-text">
            Changing this drop zone from #{numberEditIndex + 1} to <strong>#{targetZoneNumber}</strong> will smoothly reposition it in the drop sequence. Other zones will adjust so the sequence remains strictly continuous (1 to {zones.length}) without gaps or duplicates.
          </p>
          <p class="conflict-note">
            ✓ Coordinates, guards, rewards, and timings are 100% preserved.
          </p>
        </div>
      </div>

      <div class="insert-foot">
        <button class="btn" on:click={closeNumberModal}>Cancel</button>
        <span class="insert-spacer"></span>
        <button
          class="btn btn-primary"
          on:click={applyNumberChange}
          disabled={targetZoneNumber === numberEditIndex + 1}
        >
          Apply New Number (#{targetZoneNumber})
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .zones {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .header-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 4px;
    flex-wrap: wrap;
    gap: 10px;
  }
  .section-title {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 38px;
    padding: 8px 14px;
    background: var(--topbar-bg, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .section-title .count {
    margin-left: auto;
    font-size: var(--fs-meta);
    font-weight: 500;
    letter-spacing: 0;
    text-transform: none;
    color: var(--text-muted, #aeb5bd);
  }
  .header-actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 0 0 8px;
  }
  .hint strong {
    color: var(--text-main);
  }

  /* ── Random Airdrop Locations & Generator ── */
  .randomizer-panel {
    background: var(--tablet-panel-alt, #131518);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--radius-md, 6px);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    margin-bottom: 12px;
  }
  .randomizer-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px;
    padding-bottom: 12px;
    border-bottom: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
  }
  .randomizer-title-wrap {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .randomizer-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #ffffff);
  }
  .randomizer-desc {
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
    margin: 0;
    line-height: 1.4;
  }
  .randomizer-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    background: rgb(155, 123, 255);
    border: 1px solid rgb(155, 123, 255);
    border-radius: var(--r-tag, 4px);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }

  /* 2-Column Grid inside Randomizer */
  .randomizer-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }
  @media (max-width: 980px) {
    .randomizer-grid {
      grid-template-columns: 1fr;
    }
  }

  .randomizer-subcard {
    background: rgba(0, 0, 0, 0.28);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border-radius: var(--radius-sm, 4px);
    padding: 12px 14px;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    transition: border-color 0.15s ease, background 0.15s ease;
  }
  .randomizer-subcard.is-active {
    background: var(--c-raised);
    border-color: var(--c-line);
    border-left: 3px solid rgb(155, 123, 255);}
  .subcard-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .subcard-title {
    display: flex;
    align-items: center;
    gap: 7px;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-f1f3f5, #f1f3f5);
  }
  .subcard-tag {
    font-size: var(--fs-meta);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    padding: 2px 7px;
    border-radius: 3px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    color: var(--text-dim, #959ca5);
  }
  .subcard-pill {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.03em;
    padding: 2px 8px;
    border-radius: 3px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    color: var(--text-dim, #959ca5);
  }
  .subcard-pill.pill-active {
    background: rgb(155, 123, 255);
    border: 1px solid rgb(155, 123, 255);
    color: #111111;
  }
  .subcard-desc {
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
    margin: 0;
    line-height: 1.45;
  }

  .subcard-action-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding-top: 4px;
  }
  .count-input-wrap {
    display: flex;
    align-items: center;
    background: var(--input-bg, #101317);
    border: 1px solid var(--input-border, #2a2e35);
    border-radius: var(--radius-sm, 4px);
    overflow: hidden;
    height: 36px;
    flex-shrink: 0;
  }
  .count-prefix {
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--text-dim, #8b929e);
    padding: 0 8px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border-right: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    line-height: 36px;
    letter-spacing: 0.02em;
  }
  .count-input {
    width: 58px;
    border: none !important;
    background: transparent !important;
    text-align: center;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff) !important;
    padding: 0 4px;
    outline: none;
  }
  .count-unit {
    font-size: var(--fs-meta);
    color: var(--text-dim, #8b929e);
    padding: 0 8px;
  }
  .btn-generate {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    height: 36px;
    font-size: var(--fs-small);
    font-weight: 600;
    white-space: nowrap;
  }

  .subcard-toggle-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    background: rgba(0, 0, 0, 0.18);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    border-radius: var(--radius-sm, 4px);
    padding: 8px 12px;
  }
  .toggle-lead-wrap {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .toggle-lead-title {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--lt-f1f3f5, #f1f3f5);
  }
  .toggle-lead-hint {
    font-size: var(--fs-meta);
    color: var(--text-dim, #8b929e);
  }
  .subcard-toggle-control {
    flex-shrink: 0;
  }

  /* ── Bulk Settings Grid ── */
  .bulk-panel { display: flex; flex-direction: column; gap: 14px; margin-bottom: 12px; padding: 16px 18px; background: var(--glass-panel, var(--tablet-panel-alt, #131518)); border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--radius-md, 8px); }
  .bulk-panel-head { display: flex; align-items: center; gap: 12px; }
  .bulk-empty { padding: 14px; text-align: center; color: var(--text-muted, #8d949c); font-size: var(--fs-body); }
  .bulk-pick-row { display: flex; align-items: center; gap: 14px; }
  .bulk-pick-row.top { align-items: flex-start; }
  .bulk-pick-label { flex: none; width: 90px; font-size: var(--fs-body); font-weight: 600; color: var(--text-dim, #c9ced4); }
  .bulk-src { min-width: 260px; max-width: 100%; }
  .bulk-targets { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  .target-chips { display: flex; flex-wrap: wrap; gap: 8px; }
  .tchip { display: inline-flex; align-items: center; gap: 6px; height: 32px; padding: 0 14px; border-radius: 999px; font-size: var(--fs-small); font-weight: 600; color: var(--text-dim, #c9ced4); background: rgba(var(--ink-rgb, 255, 255, 255), 0.04); border: 1px solid var(--tablet-border, #2a2e35); cursor: pointer; transition: background 0.12s ease, border-color 0.12s ease, color 0.12s ease; }
  .tchip:hover:not(:disabled) { border-color: var(--accent-primary); color: var(--text-main, #fff); }
  .tchip.on { color: var(--on-accent); background: var(--c-action); border-color: var(--accent-primary); }
  .tchip.source { color: #111111; background: rgb(242, 195, 91); border-color: rgb(242, 195, 91); cursor: default; }
  .tchip:disabled { opacity: 0.55; cursor: not-allowed; }
  .target-tools { display: flex; align-items: center; gap: 14px; font-size: var(--fs-small); }
  .bulk-pick-label { padding-top: 6px; }
  .seg-group { display: inline-flex; border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-ctl, 8px); overflow: hidden; background: rgba(var(--ink-rgb, 255, 255, 255), 0.04); }
  .seg-btn { height: 32px; padding: 0 16px; font-size: var(--fs-small); font-weight: 600; color: var(--text-main, #fff); background: transparent; border: 0; border-right: 1px solid var(--tablet-border, #2a2e35); cursor: pointer; transition: background 0.12s ease; }
  .seg-btn:last-child { border-right: 0; }
  .seg-btn:hover:not(:disabled) { background: var(--c-hover); }
  .seg-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .target-count { margin-left: auto; color: var(--text-muted, #8d949c); }
  .bulk-grid, .main-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .main-grid .bulk-card { min-width: 0; }
  .apply-row { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding-top: 14px; border-top: 1px solid var(--tablet-border, #2a2e35); }
  .apply-row .btn { height: 38px; }
  .apply-label { flex-basis: 100%; font-size: var(--fs-small); font-weight: 600; color: var(--text-muted, #8d949c); }
  .load-main { margin-left: auto; display: inline-flex; align-items: center; gap: 8px; }
  .load-main select { min-width: 240px; height: 38px; }
  @media (max-width: 980px) { .bulk-grid, .main-grid { grid-template-columns: 1fr; } }
  .bulk-settings-bar {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin-bottom: 12px;
  }
  @media (max-width: 980px) {
    .bulk-settings-bar {
      grid-template-columns: 1fr;
    }
  }

  .bulk-card {
    background: var(--tablet-panel-alt, #131518);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--radius-md, 6px);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .bulk-card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding-bottom: 10px;
    border-bottom: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
  }
  .bulk-title-wrap {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .bulk-icon-box {
    width: 32px;
    height: 32px;
    border-radius: var(--radius-sm, 4px);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--accent-primary, #4f94e6);
    flex-shrink: 0;
  }
  .bulk-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
    letter-spacing: 0.01em;
  }
  .bulk-subtitle {
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
  }
  .master-badge {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: #111111;
    background: rgb(59, 130, 246);
    border: 1px solid rgb(59, 130, 246);
    padding: 2px 8px;
    border-radius: var(--r-tag, 3px);
    letter-spacing: 0.02em;
    white-space: nowrap;
  }

  .bulk-card-content {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .bulk-sync-control {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    background: rgba(0, 0, 0, 0.22);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    border-radius: var(--radius-sm, 4px);
    padding: 8px 12px;
  }
  .sync-text-group {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .sync-label {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--lt-f1f3f5, #f1f3f5);
  }
  .sync-desc {
    font-size: var(--fs-meta);
    color: var(--text-dim, #8b929e);
    line-height: 1.35;
  }
  .sync-toggle-wrap {
    flex-shrink: 0;
  }
  .btn-bulk-apply {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    height: 34px;
    font-size: var(--fs-meta);
    font-weight: 600;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    color: var(--lt-e2e8f0, #e2e8f0);
    transition: all 0.15s ease;
  }
  .btn-bulk-apply:hover:not(:disabled) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.22);
    color: var(--lt-ffffff, #ffffff);
  }
  .btn-bulk-apply:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* Reset default Toggle component styles inside custom cards */
  :global(.sync-toggle-wrap .toggle),
  :global(.subcard-toggle-control .toggle) {
    border-bottom: none !important;
    padding: 0 !important;
    margin: 0 !important;
    gap: 0 !important;
  }

  /* Placement bar */
  .placement-bar {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 12px 14px;
    margin-bottom: 2px;
  }
  .placement-label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-main);
    margin-bottom: 8px;
  }
  .chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .chip-btn {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    padding: 8px 14px;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }
  .chip-btn:hover:not(:disabled) {
    border-color: var(--accent-primary);
    color: var(--text-main);
  }
  .chip-btn.active {
    background: var(--c-action);
    border-color: var(--accent-primary);
    color: var(--on-accent);
    font-weight: 600;
  }
  .chip-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .placement-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 8px 0 0;
  }
  .placement-hint strong {
    color: var(--text-main);
  }

  /* Map Preview */
  .map-preview {
    margin-bottom: 16px;
    padding: 14px;
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
  }
  .map-preview-title {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    margin: -14px -14px 12px;
    padding: 9px 14px;
    background: var(--topbar-bg, #15171b);
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-panel) var(--r-panel) 0 0;
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .map-preview-title .map-preview-sub {
    text-transform: none;
    letter-spacing: 0;
    font-weight: 500;
    color: var(--text-muted, #aeb5bd);
  }
  .map-empty {
    padding: 40px 14px;
    text-align: center;
    color: var(--tablet-text-faint);
    font-size: var(--fs-body);
    background: var(--tablet-bg);
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
  }
  .map-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
    margin-top: 10px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .legend-item {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .legend-dot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
  }
  .empty {
    padding: 30px;
    text-align: center;
    color: var(--text-dim);
    font-size: var(--fs-body);
    border: 1px dashed var(--tablet-border-strong);
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
  }

  /* ── RouteBuilder Parity Toolbar & Bulk Delete ── */
  .add-point-row {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-bottom: 14px;
    flex-wrap: wrap;
  }
  .select-bar {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    margin: -6px 0 14px;
  }
  .select-all {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    margin-right: auto;
    font-size: var(--fs-small);
    cursor: pointer;
    color: var(--text-main);
  }
  .select-all input,
  .point-check {
    width: 17px;
    height: 17px;
    flex: none;
    margin: 0;
    cursor: pointer;
    accent-color: #9b7bff;
  }

  .point-list {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  /* ── Zone Card with Drag & Selection ── */
  .zone-card.point-card {
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-left: 3px solid var(--point-accent, #9b7bff);
    border-radius: var(--radius-md);
    padding: 16px 18px;
    background: var(--tablet-panel-alt, #131518);
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
  }
  .zone-card.point-card.selected {
    border-color: #9b7bff;
    box-shadow: 0 0 0 1.5px #9b7bff, 0 4px 18px rgba(0, 0, 0, 0.35);
  }

  /* compact zone form: four fields to a row (two on a narrow window) */
  .zc-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px 12px;
    margin-top: 10px;
    align-items: end;
  }
  .zc-grid :global(.field) { margin: 0; min-width: 0; }
  .zc-grid :global(.field label) { font-size: var(--fs-meta); margin-bottom: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .zc-grid :global(.field input),
  .zc-grid :global(.field select) { min-height: 34px; padding-top: 5px; padding-bottom: 5px; }
  /* a switch sits in the same row height as the inputs, with its state next to it */
  .zc-toggle :global(.toggle) { padding: 0; border: 0; min-height: 34px; justify-content: flex-start; gap: 10px; flex-direction: row-reverse; }
  .zc-readout {
    min-height: 34px;
    display: flex;
    align-items: center;
    font-size: var(--fs-small);
    color: var(--text-dim, #9aa3b0);
    font-variant-numeric: tabular-nums;
  }
  .zc-sub {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin-top: 14px;
    padding-top: 10px;
    border-top: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-main, #e6e9ee);
  }
  .zc-note { margin: 8px 0 0; font-size: var(--fs-small); color: var(--text-dim, #9aa3b0); }
  .zc-note.zc-span { grid-column: span 3; margin: 0; padding-bottom: 8px; }
  @media (max-width: 980px) {
    .zc-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .zc-note.zc-span { grid-column: span 1; }
  }
  @keyframes dragZonePulse {
    0%, 100% {
      background: color-mix(in srgb, #9b7bff 14%, var(--tablet-panel-alt, #131518));
      border-color: color-mix(in srgb, #9b7bff 55%, rgba(var(--ink-rgb, 255, 255, 255), 0.1));
    }
    50% {
      background: color-mix(in srgb, #9b7bff 32%, var(--tablet-panel-alt, #131518));
      border-color: color-mix(in srgb, #9b7bff 95%, rgba(var(--ink-rgb, 255, 255, 255), 0.1));
    }
  }
  .zone-card.point-card.dragging {
    opacity: 0.92;
    border-width: 2px;
    animation: dragZonePulse 0.8s ease-in-out infinite;
  }

  /* ── Drag Ghost & Indicator Line ── */
  .drag-ghost {
    position: fixed;
    z-index: 10000;
    transform: translate(-50%, -130%);
    pointer-events: none;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 14px;
    border-radius: var(--radius-md);
    border: 1.5px solid var(--point-accent, #9b7bff);
    background: rgba(18, 24, 38, 0.95);
    box-shadow: 0 10px 25px rgba(0, 0, 0, 0.6), 0 0 15px rgba(155, 123, 255, 0.3);
    color: var(--text-main);
    white-space: nowrap;
  }
  .drag-ghost-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
    background: var(--point-accent, #9b7bff);
    color: #fff;
    font-size: var(--fs-meta);
    font-weight: 700;
  }
  .drag-ghost-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .drag-ghost-label {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main);
  }
  .drag-ghost-slot {
    font-size: var(--fs-meta);
    color: #c4b5fd;
    font-weight: 500;
  }

  .drop-indicator-line {
    position: relative;
    height: 4px;
    margin: -5px 0;
    border-radius: 2px;
    background: #9b7bff;
    box-shadow: 0 0 10px rgba(155, 123, 255, 0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
    pointer-events: none;
    animation: dropLinePulse 0.6s ease-in-out infinite alternate;
    color: #fff;
  }
  @keyframes dropLinePulse {
    from { opacity: 0.8; transform: scaleY(1); }
    to { opacity: 1; transform: scaleY(1.4); }
  }
  .drop-indicator-pill {
    position: absolute;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 12px;
    background: #9b7bff;
    color: #fff;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    border-radius: 12px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.4);
    white-space: nowrap;
  }

  /* ── Drag Handle & Order Badges ── */
  .drag-handle {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 6px 9px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.16);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    color: var(--text-dim);
    cursor: grab;
    user-select: none;
    transition: all 0.15s ease;
  }
  .drag-handle:hover {
    color: var(--text-main);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.3);
    transform: translateY(-1px);
  }
  .drag-handle:active {
    cursor: grabbing;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.18);
  }
  .drag-handle-hint {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.05em;
  }

  .point-order-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 5px 8px;
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.15);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    font-size: var(--fs-small);
    font-weight: 700;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .point-order-btn:hover:not(:disabled) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-color: #9b7bff;
    color: #c4b5fd;
    transform: translateY(-1px);
  }
  .point-order-btn .order-hash {
    opacity: 0.6;
    font-size: var(--fs-meta);
  }
  .point-order-btn .order-edit-icon {
    opacity: 0.45;
    display: flex;
    align-items: center;
  }
  .point-order-btn:hover .order-edit-icon {
    opacity: 1;
  }

  .type-badge-pill {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 4px 9px;
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-left-width: 3px;
    border-radius: var(--radius-sm);
  }
  .type-pill-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.04em;
    color: #c4b5fd;
    white-space: nowrap;
  }

  .point-info-group {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    flex-wrap: wrap;
  }
  .zone-name-inline {
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    color: var(--text-main);
    font-size: var(--fs-small);
    font-weight: 700;
    padding: 4px 6px;
    min-width: 140px;
    max-width: 220px;
    transition: all 0.15s ease;
  }
  .zone-name-inline:hover:not(:disabled) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.15);
  }
  .zone-name-inline:focus {
    background: var(--input-bg, #131518);
    border-color: #9b7bff;
    outline: none;
  }
  .point-zone-pill {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 200px;
  }

  .point-coords-preview {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
    background: rgba(0, 0, 0, 0.2);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .placed-dot {
    flex-shrink: 0;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--tablet-danger, #d9736f);
  }
  .placed-dot.placed {
    background: var(--green, #70b982);
  }

  .point-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 14px;
    gap: 12px;
  }
  .point-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex-wrap: wrap;
  }
  .point-actions {
    display: flex;
    gap: 6px;
    flex-shrink: 0;
    flex-wrap: wrap;
  }
  .point-actions .icon-btn-text {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 5px 9px;
    border-radius: var(--radius-sm);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    color: var(--text-dim);
  }
  .point-actions .icon-btn-text:hover:not(:disabled) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    color: var(--text-main);
  }
  .point-actions .icon-btn-text.info {
    border-color: rgba(59, 130, 246, 0.35);
    background: rgba(59, 130, 246, 0.08);
    color: var(--lt-60a5fa, #60a5fa);
  }
  .point-actions .icon-btn-text.info:hover:not(:disabled) {
    background: rgba(59, 130, 246, 0.2);
    border-color: rgba(59, 130, 246, 0.6);
  }
  .point-actions .icon-btn-text.success {
    border-color: rgba(34, 197, 94, 0.35);
    background: rgba(34, 197, 94, 0.08);
    color: var(--lt-4ade80, #4ade80);
  }
  .point-actions .icon-btn-text.success:hover:not(:disabled) {
    background: rgba(34, 197, 94, 0.2);
    border-color: rgba(34, 197, 94, 0.6);
  }
  .point-actions .icon-btn-text.danger {
    border-color: rgba(239, 68, 68, 0.35);
    background: rgba(239, 68, 68, 0.08);
    color: var(--lt-f87171, #f87171);
  }
  .point-actions .icon-btn-text.danger:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.2);
    border-color: rgba(239, 68, 68, 0.6);
  }
  .point-actions .icon-btn-text.btn-move {
    color: var(--text-dim);
  }
  .point-actions .icon-btn-text.btn-move:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .point-fieldset {
    border: none;
    padding: 0;
    margin: 0;
  }
  .point-fieldset:disabled {
    opacity: 0.6;
  }

  /* ── 4-Column Vector Grid ── */
  .point-coords {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
    margin-bottom: 14px;
  }
  .coord-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }
  .coord-field label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--tablet-text-faint, #959ca5);
  }
  .coord-field input {
    width: 100%;
    background: var(--input-bg, #131518);
    border: 1px solid var(--input-border, #30353c);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 10px;
    font-size: var(--fs-body);
    font-family: var(--font-mono, monospace);
    font-weight: 700;
    letter-spacing: 0.01em;
    font-variant-numeric: tabular-nums;
  }
  .coord-field input:hover:not(:disabled) {
    background: var(--input-bg-hover, #15171b);
    border-color: var(--input-border-hover, #3a4048);
  }
  .coord-field input:focus {
    outline: none;
    border-color: #9b7bff;
    background: var(--input-bg-focus, #181b1f);
  }

  /* ── Modal Dialogs (Insert & Number Change) ── */
  .insert-backdrop {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    width: 100vw;
    height: 100vh;
    z-index: 99999;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.72);
    pointer-events: auto;
  }
  .insert-box {
    width: min(500px, 94vw);
    max-height: min(620px, 90vh);
    display: flex;
    flex-direction: column;
    background: var(--surface-dialog, #1a1e24);
    border: 1px solid var(--border-dialog, #2f3640);
    border-radius: var(--r-panel, 8px);
    overflow: hidden;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.75), 0 0 0 1px rgba(255, 255, 255, 0.08);
    pointer-events: auto;
  }
  .insert-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    background: var(--bg-card-raised, #131518);
    border-bottom: 1px solid var(--tablet-border, #272b31);
  }
  .insert-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .insert-body {
    padding: 16px 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    overflow-y: auto;
  }
  .insert-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .insert-field label {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-dim, #9ca3af);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }
  .insert-select {
    width: 100%;
    background: var(--input-bg, #121417);
    border: 1px solid var(--input-border, #2a2f37);
    border-radius: var(--radius-sm, 4px);
    color: var(--lt-ffffff, #fff);
    padding: 8px 12px;
    font-size: var(--fs-body);
    outline: none;
  }
  .insert-select:focus {
    border-color: #9b7bff;
  }
  .insert-toggle-group {
    display: flex;
    gap: 8px;
  }
  .insert-toggle-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 9px 12px;
    font-size: var(--fs-small);
    font-weight: 600;
    background: var(--input-bg, #14171b);
    border: 1px solid var(--tablet-border, #2a2f37);
    border-radius: var(--radius-sm, 4px);
    color: var(--text-dim, #9ca3af);
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .insert-toggle-btn:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    color: var(--lt-ffffff, #fff);
  }
  .insert-toggle-btn.active {
    background: rgba(155, 123, 255, 0.18);
    border-color: rgba(155, 123, 255, 0.65);
    color: var(--lt-ffffff, #fff);
  }
  .insert-hint {
    font-size: var(--fs-meta);
    color: var(--text-dim, #8b929e);
    margin-top: 2px;
  }
  .insert-pos-info {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--radius-sm, 4px);
    font-size: var(--fs-small);
    color: var(--lt-86efac, #86efac);
    border-left: 3px solid rgb(34, 197, 94);}
  .insert-coords-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
  }
  .insert-coord-item {
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--input-bg, #121417);
    border: 1px solid var(--input-border, #2a2f37);
    border-radius: var(--radius-sm, 4px);
    padding: 4px 10px;
  }
  .insert-coord-item span {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-dim, #9ca3af);
  }
  .insert-coord-item input {
    width: 100%;
    background: transparent;
    border: none;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-body);
    outline: none;
  }
  .insert-foot {
    display: flex;
    align-items: center;
    padding: 14px 18px;
    background: var(--bg-card-raised, #131518);
    border-top: 1px solid var(--tablet-border, #272b31);
    gap: 10px;
  }
  .insert-spacer {
    flex: 1;
  }

  .number-modal-box {
    max-width: 480px;
  }
  .num-modal-summary {
    padding: 12px 14px;
    border-radius: var(--radius-sm);
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-bottom: 14px;
  }
  .num-modal-badge {
    display: flex;
    align-items: center;
    gap: 8px;
    padding-left: 8px;
    border-left: 3px solid #9b7bff;
  }
  .num-modal-curr {
    font-size: var(--fs-small);
    color: var(--text-main);
  }
  .num-modal-type {
    display: inline-block;
    padding: 2px 6px;
    border-radius: 3px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    font-size: var(--fs-meta);
    font-weight: 600;
    text-transform: uppercase;
    color: #c4b5fd;
  }
  .num-modal-name {
    font-size: var(--fs-small);
    color: var(--text-dim);
    font-weight: 500;
  }
  .num-modal-zone {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    padding-left: 11px;
  }
  .num-stepper-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 6px;
  }
  .num-stepper-input {
    flex: 1;
    text-align: center;
    font-size: var(--fs-title);
    font-weight: 700;
    padding: 10px 14px;
    background: rgba(0, 0, 0, 0.35);
    border: 1.5px solid rgba(var(--ink-rgb, 255, 255, 255), 0.16);
    border-radius: var(--radius-sm);
    color: var(--text-main);
  }
  .num-stepper-input:focus {
    border-color: #9b7bff;
    outline: none;
  }
  .stepper-btn {
    width: 44px;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.15);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .stepper-btn:hover:not(:disabled) {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.15);
    border-color: #9b7bff;
    color: #c4b5fd;
  }
  .stepper-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }
  .num-conflict-box {
    margin-top: 14px;
    padding: 12px 14px;
    border-radius: var(--radius-sm);
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    display: flex;
    flex-direction: column;
    gap: 6px;
    border-left: 3px solid rgb(155, 123, 255);}
  .conflict-title {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: #c4b5fd;
  }
  .conflict-text {
    margin: 0;
    font-size: var(--fs-meta);
    line-height: 1.5;
    color: var(--text-main);
  }
  .conflict-note {
    margin: 0;
    font-size: var(--fs-meta);
    line-height: 1.4;
    color: var(--lt-4ade80, #4ade80);
  }
  .inline-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 0 0 10px;
  }
  .toggle-spacer {
    margin: 12px 0;
  }
  .section-subhead-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin: 20px 0 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
  }
  .inline-subtitle {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .synced-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    background: rgb(139, 92, 246);
    border: 1px solid rgb(139, 92, 246);
    border-radius: var(--r-tag);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .btn-xs {
    padding: 3px 8px;
    font-size: var(--fs-meta);
    border-radius: var(--r-ctl);
  }
  .toggle-row {
    display: flex;
    gap: 18px;
    flex-wrap: wrap;
    margin: 8px 0;
  }
  .field label .optional {
    text-transform: none;
    font-weight: 400;
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-left: 4px;
  }
  .timing-badge-row {
    margin: 4px 0 10px;
  }
  .timing-badge {
    display: inline-flex;
    align-items: center;
    padding: 3px 9px;
    background: rgb(139, 92, 246);
    border: 1px solid rgb(139, 92, 246);
    border-radius: var(--radius-sm);
    color: #111111;
    font-size: var(--fs-meta);
    font-weight: 600;
    font-family: var(--font-mono);
    letter-spacing: 0.01em;
  }

  /* Auto-Add Zones Modal */
  .modal-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(var(--ltc-4-7-15, 4, 7, 15), 0.75);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10000;
    padding: 20px;
  }
  .modal-box {
    width: 100%;
    max-width: 480px;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--radius-md, 4px);
    box-shadow: none;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    background: var(--surface-dialog-bar);
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
  }
  .modal-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .modal-close-btn {
    background: transparent;
    border: none;
    color: var(--text-dim, #959ca5);
    cursor: pointer;
    padding: 4px;
    border-radius: var(--r-ctl);
  }
  .modal-close-btn:hover {
    color: var(--text-main, #ffffff);
  }
  .modal-body {
    padding: 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .modal-desc {
    font-size: var(--fs-small);
    color: var(--text-muted, #aeb5bd);
    line-height: 1.5;
    margin: 0;
  }
  .quick-chip-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .quick-chip-label {
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
    font-weight: 500;
  }
  .quick-preset-chip {
    padding: 4px 12px;
    background: var(--tablet-panel-alt, #0f1113);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-tag);
    color: var(--text-main, #ffffff);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .quick-preset-chip:hover {
    border-color: var(--accent-primary, #4f94e6);
    color: var(--accent-primary, #4f94e6);
  }
  .quick-preset-chip.active {
    background: rgba(56, 189, 248, 0.15);
    border-color: var(--accent-primary);
    color: var(--accent-primary);
  }
  .modal-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .modal-field label {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main, #ffffff);
  }
  .modal-field input {
    padding: 10px 14px;
    background: var(--input-bg, #131518);
    border: 1px solid var(--input-border, #30353c);
    border-radius: var(--r-ctl);
    color: var(--text-main, #ffffff);
    font-size: var(--fs-emph);
    font-weight: 700;
  }
  .modal-tip {
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
    line-height: 1.4;
    margin: 0;
    padding: 8px 12px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.03);
    border-radius: var(--r-ctl);
  }
  .modal-footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 10px;
    padding: 14px 18px;
    background: var(--surface-dialog-bar);
    border-top: 1px solid var(--tablet-border, #2a2e35);
  }
</style>
