<script>
  import { onMount, onDestroy } from 'svelte';
  import {
    getPlayerPosition,
    previewRoute,
    clearRoutePreview,
    teleportToPosition,
    getZoneName,
    previewCheckpointBarricades,
    clearCheckpointBarricadesPreview,
    previewCheckpointDecorVehicles,
    clearCheckpointDecorVehiclesPreview,
    startRouteRecording,
    startHarbourPlacer,
  } from '../../api/route.js';
  import { openPropPlacer } from '../../api/placer.js';
  import { getSpawnZones, createSpawnZone } from '../../api/npc.js';
  import { ROUTE_POINT_TYPES } from '../../constants.js';
  import { bootstrap, barricadePropRemoved, decorVehicleRemoved, propEditRequest, routeRecordingResult } from '../../stores.js';
  import { confirmAction } from '../ui/confirm.js';
  import { vehicleSetFrom, cpSplit, isVehicleEntry, centroidOf } from '../ui/propData.js';
  import { TYPE_COLOR_JS, LEGEND } from '../../util/mapGeometry.js';
  import { renumberAuto } from '../../util/autoName.js';
  import Icon from '../ui/Icon.svelte';
  import { revealLast } from '../ui/reveal.js';
  import Toggle from '../ui/Toggle.svelte';
  import RoutePreviewMap from '../ui/RoutePreviewMap.svelte';
  import SavedTemplatePicker from '../ui/SavedTemplatePicker.svelte';

  export let route = [];
  export let checkpoints = [];
  export let airdrops = [];
  export let props = [];
  export let settings;
  export let locked = false;
  export let trucks = [];

  // ── per-truck spawn positions (START point) ──
  // Stored on the START point itself as truckSpawns[truckId] = {x,y,z,heading}.
  // A truck with a saved spot spawns exactly there, facing that heading; one
  // without falls back to the automatic nose-to-tail spacing behind START.
  // Keyed by truck id (not list position) so reordering/removing trucks in
  // the Trucks tab can never shift a spot onto the wrong truck. Escorts are
  // police-requisitioned at the shop, never spawned here, so they're skipped.
  const ROLE_LABELS = { PRIMARY_CARGO: 'Primary Cargo', SECONDARY_CARGO: 'Secondary Cargo', DECOY: 'Decoy', ESCORT: 'Escort' };
  $: spawnTrucks = (trucks || []).filter((t) => t.role !== 'ESCORT');

  function spawnFor(point, truckId) {
    return point.truckSpawns ? point.truckSpawns[truckId] : null;
  }

  async function setTruckSpawn(pointIndex, truckId) {
    const pos = await getPlayerPosition();
    if (!pos || pos.x == null) return;
    route = route.map((p, i) => i === pointIndex
      ? { ...p, truckSpawns: { ...(p.truckSpawns || {}), [truckId]: { x: pos.x, y: pos.y, z: pos.z, heading: pos.heading ?? 0 } } }
      : p);
  }

  let placingTruckId = null;
  async function placeTruckSpawnHologram(pointIndex, truck) {
    if (locked || placingTruckId) return;
    const pt = route[pointIndex];
    if (!pt) return;
    const cur = spawnFor(pt, truck.id);
    placingTruckId = truck.id;
    let res = null;
    try {
      res = await startHarbourPlacer({
        kind: 'vehicle',
        model: truck.model || 'barracks',
        x: cur?.x ?? pt.x,
        y: cur?.y ?? pt.y,
        z: cur?.z ?? pt.z,
        heading: cur?.heading ?? pt.heading ?? 0,
        label: `Truck: ${truck.label || truck.model || 'Truck'}`,
      });
    } catch (e) {
      res = null;
    }
    placingTruckId = null;
    if (!res || !res.ok) return;
    route = route.map((p, i) => i === pointIndex
      ? { ...p, truckSpawns: { ...(p.truckSpawns || {}), [truck.id]: { x: res.x, y: res.y, z: res.z, heading: res.heading ?? 0 } } }
      : p);
  }

  function clearTruckSpawn(pointIndex, truckId) {
    route = route.map((p, i) => {
      if (i !== pointIndex || !p.truckSpawns) return p;
      const copy = { ...p.truckSpawns };
      delete copy[truckId];
      return { ...p, truckSpawns: copy };
    });
  }

  async function clearAllTruckSpawns(pointIndex) {
    const ok = await confirmAction('Clear every saved truck spawn position? Trucks will go back to automatic spacing behind the START point.', { title: 'Clear Spawn Positions', danger: true });
    if (!ok) return;
    route = route.map((p, i) => (i === pointIndex ? { ...p, truckSpawns: {} } : p));
  }

  function fmt(n) {
    return Number(n || 0).toFixed(1);
  }

  if (!settings.npcPoliceConfig) {
    settings.npcPoliceConfig = { model: 's_m_y_cop_01', vehicleModel: 'police3', weapon: 'WEAPON_CARBINERIFLE', behavior: 'GUARD_CHECKPOINT' };
  }
  if (!settings.armyConfig) {
    settings.armyConfig = { model: 's_m_y_marine_03', vehicleModel: 'barracks', weapon: 'WEAPON_CARBINERIFLE', behavior: 'GUARD_CHECKPOINT' };
  }
  const BEHAVIORS = ['GUARD_CHECKPOINT', 'FOLLOW_CONVOY', 'PATROL_AREA'];

  const AGGRESSIVENESS_OPTIONS = [
    { value: 'low', label: 'Low (Recruit — Low accuracy)' },
    { value: 'medium', label: 'Medium (Tactical — Balanced)' },
    { value: 'high', label: 'High (Aggressive — High accuracy)' },
    { value: 'extreme', label: 'Extreme (Lethal — Pinpoint aim)' },
  ];

  const COMMON_WEAPONS = [
    { value: 'WEAPON_CARBINERIFLE', label: 'Carbine Rifle (M4)' },
    { value: 'WEAPON_ASSAULTRIFLE', label: 'Assault Rifle (AK-47)' },
    { value: 'WEAPON_SPECIALCARBINE', label: 'Special Carbine (G36)' },
    { value: 'WEAPON_SMG', label: 'SMG (MP5)' },
    { value: 'WEAPON_MICROSMG', label: 'Micro SMG (Uzi)' },
    { value: 'WEAPON_COMBATPISTOL', label: 'Combat Pistol' },
    { value: 'WEAPON_PISTOL', label: 'Standard Pistol' },
    { value: 'WEAPON_PUMPSHOTGUN', label: 'Pump Shotgun' },
  ];

  const POLICE_MODELS = [
    { value: 's_m_y_cop_01', label: 'LSPD Police Officer' },
    { value: 's_m_y_sheriff_01', label: 'Sheriff Deputy' },
    { value: 's_m_y_hwaycop_01', label: 'Highway Patrol Officer' },
    { value: 's_m_m_ciagoon_01', label: 'Tactical / FIB Agent' },
  ];

  const ARMY_MODELS = [
    { value: 's_m_y_marine_03', label: 'Military Marine' },
    { value: 's_m_y_armymech_01', label: 'Army Infantry' },
    { value: 's_m_y_blackops_01', label: 'Black Ops Commando' },
  ];

  // The vehicle a checkpoint's NPC support squad arrives in (only when 'Arrive in a vehicle' is on).
  const POLICE_SUPPORT_VEHICLES = [
    { value: 'police3', label: 'Police Cruiser' },
    { value: 'police', label: 'Police Buffalo' },
    { value: 'police2', label: 'Police Interceptor' },
    { value: 'sheriff', label: 'Sheriff Cruiser' },
    { value: 'riot', label: 'Police Riot Van' },
  ];
  const ARMY_SUPPORT_VEHICLES = [
    { value: 'crusader', label: 'Army Patrol Truck (Crusader)' },
    { value: 'barracks', label: 'Army Transport Truck (Barracks)' },
    { value: 'insurgent2', label: 'Insurgent' },
  ];

  const SECURITY_MODELS = [
    { value: 's_m_m_security_01', label: 'Gruppe Sechs Guard' },
    { value: 's_m_m_armoured_01', label: 'Armored Transport Guard' },
    { value: 's_m_m_highsec_01', label: 'High Security Operative' },
  ];

  const CARTEL_MODELS = [
    { value: 'g_m_y_salvagoon_01', label: 'Salvadorian Cartel' },
    { value: 'g_m_y_mexgoon_01', label: 'Mexican Cartel' },
    { value: 'g_m_y_ballas_01', label: 'Street Gang' },
    { value: 'g_m_y_lost_01', label: 'Lost MC Biker' },
  ];

  $: maxPoints = $bootstrap?.limits?.maxCheckpoints ? $bootstrap.limits.maxCheckpoints * 3 : 30;
  $: features = $bootstrap?.features || {};

  let zones = [];
  onMount(async () => {
    const res = await getSpawnZones();
    if (res && res.ok) zones = res.zones;
  });
  $: policeZones = zones.filter((z) => z.type === 'POLICE');
  $: armyZones = zones.filter((z) => z.type === 'ARMY');

  // ── Saved Route Templates ──
  // Reusable route layouts (route points + their checkpoint/airdrop configs)
  // that live independently of any one convoy — build/record a route once,
  // save it under a name, then import that same layout into a different
  // convoy later instead of rebuilding it. This is a snapshot: importing a
  // template never links back to it, so later edits here don't touch what's
  // saved, and re-saving under the same name just creates another entry
  // (kept simple on purpose — no "update existing template" step to get
  // wrong and overwrite something by accident).
  // Saved-route templates are handled by the shared SavedTemplatePicker (import
  // box filtered to Convoy Route templates); this just applies what it imports.
  function applyImportedTemplate(e) {
    const res = e.detail;
    // Guard against a mismatched payload — a Rally/Hot Cargo template here would
    // otherwise blank this convoy's route.
    if (!res || (res.kind && res.kind !== 'CONVOY')) return;
    // sorted by the template's own order, then numbered 0..n-1 so the imported route's sequence is clean
    route = [...(res.route || [])].sort((a, b) => (a.order ?? 0) - (b.order ?? 0)).map((p, i) => ({ ...p, order: i }));
    checkpoints = res.checkpoints || [];
    airdrops = res.airdrops || [];
    if (res.props || res.eventProps) {
      props = res.props || res.eventProps || [];
    }
  }

  let newZone = null;
  function startAddZone(type) {
    newZone = { type, label: '', radius: 25, saving: false, error: '' };
  }
  async function saveNewZone() {
    if (!newZone) return;
    if (newZone.label.trim().length < 2) { newZone.error = 'Zone name is too short.'; return; }
    newZone.saving = true;
    const res = await createSpawnZone(newZone.label.trim(), newZone.type, Number(newZone.radius) || 25);
    newZone.saving = false;
    if (!res || !res.ok) { newZone.error = (res && res.error) || 'Failed to add zone.'; return; }
    const zonesRes = await getSpawnZones();
    if (zonesRes && zonesRes.ok) zones = zonesRes.zones;
    newZone = null;
  }

  function nextId() {
    return `pt_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  }

  $: availableBarricadeProps = ($bootstrap?.barricadeProps && $bootstrap.barricadeProps.length > 0)
    ? $bootstrap.barricadeProps
    : [
        { id: 'barrier_work', label: 'Road Work Barrier', model: 'prop_barrier_work05', category: 'barricade' },
        { id: 'barrier_wood', label: 'Wooden Barrier', model: 'prop_barrier_work06a', category: 'barricade' },
        { id: 'barrier_jersey', label: 'Concrete Jersey Barrier', model: 'prop_barier_conc_05c', category: 'barricade' },
        { id: 'traffic_cone', label: 'Standard Traffic Cone', model: 'prop_roadcone02a', category: 'cone' },
        { id: 'traffic_cone_tall', label: 'Tall Traffic Cone', model: 'prop_roadcone01a', category: 'cone' },
        { id: 'military_block', label: 'Military Concrete Block', model: 'prop_barrier_conc_01a', category: 'military' },
        { id: 'military_sandbags', label: 'Military Sandbag Wall', model: 'prop_sandbag_02', category: 'military' },
        { id: 'military_fence', label: 'Security Perimeter Fence', model: 'prop_fncsec_04crnr1', category: 'military' },
      ];

  $: availableDecorVehicles = ($bootstrap?.decorVehicles && $bootstrap.decorVehicles.length > 0)
    ? $bootstrap.decorVehicles
    : [
        { id: 'police', label: 'Police Cruiser', model: 'police', category: 'police' },
        { id: 'police2', label: 'Police Cruiser (Alt)', model: 'police2', category: 'police' },
        { id: 'police3', label: 'Police Interceptor', model: 'police3', category: 'police' },
        { id: 'police4', label: 'Unmarked Police Cruiser', model: 'police4', category: 'police' },
        { id: 'sheriff', label: 'Sheriff Cruiser', model: 'sheriff', category: 'police' },
        { id: 'sheriff2', label: 'Sheriff SUV', model: 'sheriff2', category: 'police' },
        { id: 'fbi', label: 'FIB Sedan', model: 'fbi', category: 'police' },
        { id: 'fbi2', label: 'FIB SUV', model: 'fbi2', category: 'police' },
        { id: 'riot', label: 'Police Riot Van', model: 'riot', category: 'police' },
        { id: 'barracks', label: 'Army Transport Truck', model: 'barracks', category: 'army' },
        { id: 'barracks2', label: 'Army Cargo Truck', model: 'barracks2', category: 'army' },
        { id: 'crusader', label: 'Army Patrol Truck', model: 'crusader', category: 'army' },
      ];

  function propLabelFor(model) {
    const found = availableBarricadeProps.find((p) => p.model === model);
    return found ? found.label : model;
  }

  let previewingPropsCpId = null;

  // Reopens the checkpoint panel after a placement session so the admin lands
  // back on the section they were editing instead of the top of the route.
  // A tiny delay lets the tablet finish restoring (the client only re-shows it
  // once it has actually closed its own placement loop).
  let focusedCpId = null;
  async function scrollToCheckpoint(cpId) {
    focusedCpId = cpId;
    await new Promise((r) => setTimeout(r, 60));
    const el = document.querySelector(`[data-cp-key="${cpId}"]`);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    setTimeout(() => { focusedCpId = null; }, 1600);
  }

  // ONE placer for the checkpoint's barricades AND decoration vehicles (the shared Prop Placer): both lists go in
  // as one layout, and come back split into props and vehicles. There are no per-checkpoint spawn switches any
  // more - whatever the placer stored for the checkpoint is what spawns.
  $: vset = vehicleSetFrom($bootstrap);
  // what a checkpoint has stored, counted from the SAVED data (a police car filed as a plain prop is a vehicle)
  const split = (cp, vs) => cpSplit(cp, vs);
  const cpPoint = (cp) => route.find((p) => p.id === cp.routePointId) || null;
  async function openCheckpointPlacer(cp, startCategory, selectIndex, focusOverride) {
    const stored = split(cp, vset);
    const objects = [
      ...stored.props.map((p) => ({ ...p, kind: 'object' })),
      ...stored.vehicles.map((v) => ({ ...v, kind: 'vehicle' })),
    ];
    const pt = cpPoint(cp);

    // Build guides for checkpoint zones, other checkpoints' props and general event props
    const guides = [];
    for (let i = 0; i < checkpoints.length; i++) {
      const otherCp = checkpoints[i];
      const oPt = cpPoint(otherCp);
      const isCurrent = otherCp.routePointId === cp.routePointId;
      const targetPt = isCurrent ? pt : oPt;
      if (targetPt && targetPt.x != null) {
        guides.push({
          kind: 'checkpoint',
          x: targetPt.x, y: targetPt.y, z: targetPt.z,
          h: targetPt.heading || 0,
          L: (otherCp.radius || 15) * 2,
          W: (otherCp.radius || 15) * 2,
          H: 4.0,
          label: otherCp.label || `Checkpoint #${i + 1}`,
        });
      }
      if (!isCurrent) {
        for (const bp of (otherCp.barricadeProps || [])) {
          if (bp.x != null) {
            guides.push({
              kind: 'checkpoint_prop',
              model: bp.model,
              x: bp.x, y: bp.y, z: bp.z,
              h: bp.heading || 0,
              rx: bp.rx, ry: bp.ry,
              L: 2.0, W: 2.0, H: 2.0,
              label: otherCp.label || `Checkpoint #${i + 1}`,
            });
          }
        }
        for (const dv of (otherCp.decorVehicles || [])) {
          if (dv.x != null) {
            guides.push({
              kind: 'checkpoint_vehicle',
              model: dv.model,
              x: dv.x, y: dv.y, z: dv.z,
              h: dv.heading || 0,
              rx: dv.rx, ry: dv.ry,
              L: 4.5, W: 2.2, H: 2.2,
              label: otherCp.label || `Checkpoint #${i + 1}`,
            });
          }
        }
      }
    }
    // Include general event props as reference guides too
    for (const gp of (props || [])) {
      if (gp.x != null) {
        guides.push({
          kind: gp.kind === 'vehicle' ? 'checkpoint_vehicle' : 'checkpoint_prop',
          model: gp.model,
          x: gp.x, y: gp.y, z: gp.z,
          h: gp.heading || 0,
          rx: gp.rx, ry: gp.ry,
          L: 2.0, W: 2.0, H: 2.0,
          label: 'Event Prop',
        });
      }
    }

    const res = await openPropPlacer({
      context: 'convoy',
      title: `Checkpoint: ${cp.label || 'Zone'} props & vehicles`,
      objects,
      // this checkpoint's own props if it has any; none left (all removed) -> start on the checkpoint itself
      focus: focusOverride || centroidOf(objects) || (pt && pt.x != null ? { x: pt.x, y: pt.y, z: pt.z } : undefined),
      startCategory,
      selectIndex,
      guides,
    });
    if (res && res.ok && Array.isArray(res.objects)) {
      // `kind` stays on every stored entry so a vehicle can never be mistaken for a prop again
      const asVehicle = (o) => isVehicleEntry(o, vset);
      cp.barricadeProps = res.objects.filter((o) => !asVehicle(o)).map((o) => ({ ...o, kind: 'object' }));
      cp.decorVehicles = res.objects.filter(asVehicle).map((o) => ({ ...o, kind: 'vehicle' }));
      cp.barricades = true;
      cp.decorVehiclesEnabled = true;
      checkpoints = [...checkpoints];
      if (previewingPropsCpId === cp.routePointId) previewCheckpointBarricades(cp.barricadeProps, cp.routePointId);
      if (previewingVehiclesCpId === cp.routePointId) previewCheckpointDecorVehicles(cp.decorVehicles, cp.routePointId);
    }
    // Whatever the outcome, bring the admin back to THIS checkpoint's panel.
    scrollToCheckpoint(cp.routePointId);
  }

  // "Edit in Prop Placer" chosen in the world on a previewed prop / vehicle
  const unsubEditRequest = propEditRequest.subscribe((msg) => {
    if (!msg || !msg.cpKey) return;
    const cp = checkpoints.find((c) => c.routePointId === msg.cpKey);
    propEditRequest.set(null);
    if (!cp || locked) return;
    const idx = typeof msg.index === 'number' ? msg.index : 1;
    const at = msg.kind === 'vehicle' ? split(cp, vset).props.length + idx : idx;
    openCheckpointPlacer(cp, msg.kind === 'vehicle' ? 'vehicles' : 'barricades', at);
  });

  // Stored objects of one checkpoint: removed by identity, so the prop / vehicle split can never delete the wrong one.
  function removeStored(cp, obj) {
    cp.barricadeProps = (cp.barricadeProps || []).filter((o) => o !== obj);
    cp.decorVehicles = (cp.decorVehicles || []).filter((o) => o !== obj);
    checkpoints = [...checkpoints];
  }
  function clearStored(cp) {
    cp.barricadeProps = [];
    cp.decorVehicles = [];
    checkpoints = [...checkpoints];
    clearCheckpointBarricadesPreview();
    clearCheckpointDecorVehiclesPreview();
    previewingPropsCpId = null;
    previewingVehiclesCpId = null;
  }
  // Preview: the same Prop Placer, opened on this checkpoint's stored objects and starting over their area.
  // It loads the stored list (nothing is created twice) - leaving it with Save keeps the layout as it is.
  function previewStored(cp) {
    const s = split(cp, vset);
    const at = centroidOf([...s.props, ...s.vehicles]);
    openCheckpointPlacer(cp, undefined, undefined, at || undefined);
  }

  function removePlacedProp(cp, index) {
    if (!cp.barricadeProps) return;
    cp.barricadeProps = cp.barricadeProps.filter((_, i) => i !== index);
    checkpoints = [...checkpoints];
    if (previewingPropsCpId === cp.routePointId) {
      // Re-spawn so the in-world view matches the list, keeping the cpKey so
      // ox_target options on the remaining props still resolve to this set.
      previewCheckpointBarricades(cp.barricadeProps, cp.routePointId);
    }
  }

  function clearPlacedProps(cp) {
    cp.barricadeProps = [];
    checkpoints = [...checkpoints];
    clearCheckpointBarricadesPreview();
    previewingPropsCpId = null;
  }

  function togglePropPreview(cp) {
    if (previewingPropsCpId === cp.routePointId) {
      clearCheckpointBarricadesPreview();
      previewingPropsCpId = null;
    } else {
      // cpKey tags every spawned preview entity so a prop deleted in-world via
      // ox_target can be traced back to THIS checkpoint's list.
      previewCheckpointBarricades(cp.barricadeProps || [], cp.routePointId);
      previewingPropsCpId = cp.routePointId;
    }
  }

  // Consumes the client's "prop deleted in-world via ox_target" message:
  // drops exactly that entry (by index) from the matching checkpoint's stashed
  // list. The index is the one assigned at preview time, which matches the
  // stored order — so removal stays in sync without a full client round-trip.
  const unsubPropRemoved = barricadePropRemoved.subscribe((msg) => {
    if (!msg || !msg.cpKey) return;
    const cp = checkpoints.find((c) => c.routePointId === msg.cpKey);
    if (!cp || !cp.barricadeProps) return;
    const idx = typeof msg.index === 'number' ? msg.index - 1 : -1;
    if (idx < 0 || idx >= cp.barricadeProps.length) return;
    cp.barricadeProps = cp.barricadeProps.filter((_, i) => i !== idx);
    checkpoints = [...checkpoints];
    barricadePropRemoved.set(null);
  });

  // Checkpoint decor vehicles (police/army cars for ambience) — same flow as
  // the barricade props above, just its own stashed list (cp.decorVehicles)
  // and its own placer/preview NUI calls (route_editor.lua).
  function decorVehicleLabelFor(model) {
    const found = availableDecorVehicles.find((v) => v.model === model);
    return found ? found.label : model;
  }

  let previewingVehiclesCpId = null;

  function removePlacedVehicle(cp, index) {
    if (!cp.decorVehicles) return;
    cp.decorVehicles = cp.decorVehicles.filter((_, i) => i !== index);
    checkpoints = [...checkpoints];
    if (previewingVehiclesCpId === cp.routePointId) {
      previewCheckpointDecorVehicles(cp.decorVehicles, cp.routePointId);
    }
  }

  function clearPlacedVehicles(cp) {
    cp.decorVehicles = [];
    checkpoints = [...checkpoints];
    clearCheckpointDecorVehiclesPreview();
    previewingVehiclesCpId = null;
  }

  function toggleVehiclePreview(cp) {
    if (previewingVehiclesCpId === cp.routePointId) {
      clearCheckpointDecorVehiclesPreview();
      previewingVehiclesCpId = null;
    } else {
      previewCheckpointDecorVehicles(cp.decorVehicles || [], cp.routePointId);
      previewingVehiclesCpId = cp.routePointId;
    }
  }

  const unsubVehicleRemoved = decorVehicleRemoved.subscribe((msg) => {
    if (!msg || !msg.cpKey) return;
    const cp = checkpoints.find((c) => c.routePointId === msg.cpKey);
    if (!cp || !cp.decorVehicles) return;
    const idx = typeof msg.index === 'number' ? msg.index - 1 : -1;
    if (idx < 0 || idx >= cp.decorVehicles.length) return;
    cp.decorVehicles = cp.decorVehicles.filter((_, i) => i !== idx);
    checkpoints = [...checkpoints];
    decorVehicleRemoved.set(null);
  });

  // Route Recorder result (route_recorder.lua) — an admin drove/walked the
  // path and dropped points with a key press instead of doing "Set to My
  // Position" one at a time from inside the tablet. Comes back as plain
  // {x,y,z,heading} objects; appended here as ordinary ROUTE-type points,
  // continuing the route's existing numbering. Converting any of them to a
  // CHECKPOINT afterward is just the normal type dropdown below — recording
  // only fills the list in fast, it doesn't decide what anything becomes.
  let recording = false;
  const unsubRecording = routeRecordingResult.subscribe((msg) => {
    if (!msg) return;
    // Only a Convoy session — a Rally (or Hot Cargo) recording must never be
    // appended to this convoy's route. See RallyRaceConfig's matching filter
    // and route_recorder.lua's `recordTarget`.
    if (msg.target && msg.target !== 'CONVOY') return;
    const points = msg.points || [];
    if (points.length > 0) {
      const base = route.length;
      const added = points.map((p, i) => ({
        id: nextId(),
        order: base + i,
        x: p.x, y: p.y, z: p.z, heading: p.heading || 0,
        type: 'ROUTE',
      }));
      // The last point you drop while recording is naturally where the
      // convoy should end up — auto-mark it DESTINATION so a straightforward
      // "drive the whole path, hit Enter at the end" recording needs no
      // manual follow-up step at all. Never overrides an existing
      // DESTINATION already in the route (recording can also be used to
      // extend an existing route, and two DESTINATION points would be
      // ambiguous — findPoint/checkpointConfigFor etc. all assume exactly
      // one).
      const alreadyHasDestination = route.some((p) => p.type === 'DESTINATION');
      if (!alreadyHasDestination) {
        for (let i = added.length - 1; i >= 0; i--) {
          if (added[i].type === 'ROUTE') {
            added[i].type = 'DESTINATION';
            break;
          }
        }
      }
      route = [...route, ...added];
      revealLast('.point-card');
    }
    recording = false;
    routeRecordingResult.set(null);
  });

  async function beginRouteRecording() {
    recording = true;
    await startRouteRecording({ target: 'CONVOY' });
    // Tablet minimizes itself immediately (route_recorder.lua); `recording`
    // just drives this button's own label/disabled state until the result
    // comes back through the subscription above, which also clears it.
  }

  onDestroy(() => {
    unsubPropRemoved(); unsubVehicleRemoved(); unsubEditRequest(); unsubRecording();
    window.removeEventListener('mousemove', onDragMove);
    window.removeEventListener('mouseup', onDragRelease);
  });

  function defaultCheckpoint(routePointId, index) {
    return {
      routePointId,
      name: `Checkpoint ${index + 1}`,
      radius: 80,
      holdDuration: 60,
      barricades: true,
      barricadeMode: 'random',
      barricadeModel: 'prop_barrier_work05',
      barricadeCount: 6,
      barricadeProps: [],
      selectedPropModel: 'prop_barrier_work05',
      decorVehiclesEnabled: true,
      decorVehicles: [],
      selectedDecorVehicleModel: 'police',
      npcPolice: { enabled: false, count: 4, zoneId: null, model: 's_m_y_cop_01', weapon: 'WEAPON_CARBINERIFLE', aggressiveness: 'medium', spawnVehicle: false, vehicleModel: 'police3' },
      army: { enabled: false, count: 4, zoneId: null, model: 's_m_y_marine_03', weapon: 'WEAPON_CARBINERIFLE', aggressiveness: 'high', spawnVehicle: false, vehicleModel: 'crusader' },
      gangAttackEnabled: true,
      announce: true,
    };
  }
  function syncByType(type, list, makeDefault) {
    const points = route.filter((p) => p.type === type);
    const validIds = new Set(points.map((p) => p.id));
    const existingIds = new Set(list.map((item) => item.routePointId));
    let changed = false;
    let next = list.filter((item) => validIds.has(item.routePointId));
    if (next.length !== list.length) changed = true;
    points.forEach((p, i) => {
      if (!existingIds.has(p.id)) {
        next = [...next, makeDefault(p.id, i)];
        changed = true;
      }
    });
    return changed ? next : null;
  }
  // The START and DESTINATION points carry the same dressing a checkpoint does (props, decoration vehicles, NPC police / army guards).
  // Their settings live in the same list, flagged supportOnly (the server stores them separately, so they never count as checkpoints):
  // no name, radius, hold time or announcement, just the placed objects and the guards.
  function defaultSupport(routePointId, type) {
    return {
      ...defaultCheckpoint(routePointId, 0),
      name: type === 'START' ? 'Start' : 'Destination',
      label: type === 'START' ? 'Start' : 'Destination',
      supportOnly: true,
      supportType: type,
      announce: false,
      gangAttackEnabled: false,   // guards around the staging / delivery area only stand there; they do not attack anyone
    };
  }
  function syncPointConfigs(list) {
    const points = route.filter((p) => p.type === 'CHECKPOINT' || p.type === 'START' || p.type === 'DESTINATION');
    const byId = new Map(points.map((p) => [p.id, p]));
    let changed = false;
    let next = list.filter((item) => byId.has(item.routePointId));
    if (next.length !== list.length) changed = true;
    // an entry follows its point's type (a point switched between Checkpoint / Start / Destination keeps its settings)
    next = next.map((item) => {
      const p = byId.get(item.routePointId);
      const sup = p.type !== 'CHECKPOINT';
      if (!!item.supportOnly === sup && (!sup || item.supportType === p.type)) return item;
      changed = true;
      return { ...item, supportOnly: sup, supportType: sup ? p.type : undefined, ...(sup ? { label: p.type === 'START' ? 'Start' : 'Destination' } : {}) };
    });
    const have = new Set(next.map((i) => i.routePointId));
    let cpPos = 0;
    points.forEach((p) => {
      const isCp = p.type === 'CHECKPOINT';
      const idx = isCp ? cpPos++ : 0;
      if (have.has(p.id)) return;
      next = [...next, isCp ? defaultCheckpoint(p.id, idx) : defaultSupport(p.id, p.type)];
      changed = true;
    });
    return changed ? next : null;
  }
  $: {
    const nextCp = syncPointConfigs(checkpoints);
    if (nextCp) checkpoints = nextCp;
  }
  // "Checkpoint 1, 2, 3…" always follows the ROUTE order of the checkpoint points (not the order they were created in),
  // so deleting, inserting or dragging a point never leaves gaps or duplicates. A checkpoint you renamed keeps its name.
  // Written after the sync block above so a checkpoint it just created is numbered in the same pass.
  $: if (!locked) {
    const rank = new Map();
    route.forEach((p) => { if (p.type === 'CHECKPOINT') rank.set(p.id, rank.size + 1); });
    const renamed = renumberAuto(checkpoints, 'Checkpoint ', { rankOf: (cp) => rank.get(cp.routePointId) ?? null });
    if (renamed !== checkpoints) checkpoints = renamed;
  }
  // Zone name per point (e.g. "Sandy Shores", "Downtown Vinewood") — purely
  // cosmetic, so it's easy to tell points apart in the list by area instead
  // of having to mentally parse raw x/y. zoneKeys tracks which coordinates a
  // cached name was fetched for, so moving a point re-fetches its name but
  // Zone name per point (e.g. "Sandy Shores", "Downtown Vinewood") — purely
  // cosmetic, so it's easy to tell points apart in the list by area instead
  // of having to mentally parse raw x/y. Batched via requestAnimationFrame
  // to avoid triggering 20+ synchronous Svelte re-renders during route loads.
  let zoneNames = {};
  let zoneKeys = {};
  let zoneUpdateQueue = {};
  let zoneRafPending = false;
  async function ensureZoneName(point) {
    if (!point || point.x == null || point.y == null) return;
    const key = `${Math.round(point.x)},${Math.round(point.y)}`;
    if (zoneKeys[point.id] === key) return;
    zoneKeys[point.id] = key;
    const res = await getZoneName(point.x, point.y, point.z);
    zoneUpdateQueue[point.id] = (res && res.name) || null;
    if (!zoneRafPending) {
      zoneRafPending = true;
      requestAnimationFrame(() => {
        zoneRafPending = false;
        zoneNames = { ...zoneNames, ...zoneUpdateQueue };
        zoneUpdateQueue = {};
      });
    }
  }
  $: if (route) {
    for (let i = 0; i < route.length; i++) {
      ensureZoneName(route[i]);
    }
  }

  let selectedPointId = null;

  // While a pin is being dragged its vector (X / Y in the point list) follows live, about ten times a second, and is written for good
  // on release (pointMove). The map holds its own redraws back during a drag, so this never interrupts it.
  let dragTimer = null;
  let dragLatest = null;
  function handleMapPointDrag(e) {
    dragLatest = e.detail;
    if (dragTimer) return;
    dragTimer = setTimeout(() => {
      dragTimer = null;
      const d = dragLatest;
      if (!d) return;
      route = route.map((p) => (p.id === d.id ? { ...p, x: d.x, y: d.y } : p));
    }, 100);
  }

  function handleMapPointMove(e) {
    if (dragTimer) { clearTimeout(dragTimer); dragTimer = null; }
    const { id, x, y, z } = e.detail;
    route = route.map((p) => (p.id === id ? { ...p, x, y, ...(z != null ? { z } : {}) } : p));
  }

  function handleMapPointSelect(e) {
    selectedPointId = e.detail.id;
    const card = document.querySelector(`.point-card[data-id="${e.detail.id}"]`);
    if (card) {
      card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  }

  // Backfills fields onto airdrops saved before the guard/lockpick/reward
  // rework — without this, an old convoy's airdrop config would bind
  // inputs against undefined (drop.reward.chance) and error.
  $: for (const [i, d] of airdrops.entries()) {
    if (!d.name && !d.label) {
      d.name = `Airdrop ${i + 1}`;
      d.label = d.name;
    } else if (!d.name) {
      d.name = d.label;
    } else if (!d.label) {
      d.label = d.name;
    }
    if (d.guardCount == null) d.guardCount = 3;
    if (d.requireLockpick == null) d.requireLockpick = true;
    if (d.lockpicksRequired == null) d.lockpicksRequired = '';
    if (d.chance == null) d.chance = d.reward?.chance ?? 60;
    if (!d.rewards) {
      // Migrates an airdrop saved before rewards became a list — old shape
      // was a single { chance, type, amount, pool } object.
      d.rewards = d.reward && d.reward.type ? [{ type: d.reward.type, amount: d.reward.amount, pool: d.reward.pool }] : [{ type: 'MONEY', amount: 500, pool: '' }];
    }
  }
  function addManual() {
    if (route.length >= maxPoints) return;
    route = [...route, { id: nextId(), order: route.length, x: 0, y: 0, z: 0, heading: 0, type: 'ROUTE' }];
  }

  // ── Manual Route Point Insertion (Before / After specific existing point) ──
  let showInsertModal = false;
  let insertRefIndex = 0;
  let insertPosition = 'after'; // 'before' | 'after'
  let insertType = 'ROUTE';
  let insertPlacementMode = 'position'; // 'position' | 'manual'
  let insertManualCoords = { x: 0, y: 0, z: 0, heading: 0 };
  let insertingBusy = false;

  function openInsertModal(refIdx = 0, pos = 'after') {
    if (locked || route.length >= maxPoints) return;
    insertRefIndex = Math.max(0, Math.min(refIdx, route.length > 0 ? route.length - 1 : 0));
    insertPosition = pos;
    insertType = 'ROUTE';
    insertPlacementMode = 'position';
    const refPt = route[insertRefIndex];
    if (refPt) {
      insertManualCoords = { x: refPt.x ?? 0, y: refPt.y ?? 0, z: refPt.z ?? 0, heading: refPt.heading ?? 0 };
    } else {
      insertManualCoords = { x: 0, y: 0, z: 0, heading: 0 };
    }
    showInsertModal = true;
  }

  function closeInsertModal() {
    showInsertModal = false;
  }

  async function confirmInsertPoint() {
    if (locked || route.length >= maxPoints) return;
    insertingBusy = true;
    let coords = { x: 0, y: 0, z: 0, heading: 0 };
    if (insertPlacementMode === 'position') {
      const pos = await getPlayerPosition();
      if (pos && pos.x != null) {
        coords = { x: pos.x, y: pos.y, z: pos.z, heading: pos.heading ?? 0 };
      }
    } else {
      coords = {
        x: parseFloat(insertManualCoords.x) || 0,
        y: parseFloat(insertManualCoords.y) || 0,
        z: parseFloat(insertManualCoords.z) || 0,
        heading: parseFloat(insertManualCoords.heading) || 0,
      };
    }

    const newPoint = {
      id: nextId(),
      order: 0,
      x: coords.x,
      y: coords.y,
      z: coords.z,
      heading: coords.heading,
      type: insertType,
    };

    const targetIdx = insertPosition === 'before' ? insertRefIndex : insertRefIndex + 1;
    const copy = [...route];
    copy.splice(targetIdx, 0, newPoint);
    route = copy.map((p, i) => ({ ...p, order: i }));

    insertingBusy = false;
    showInsertModal = false;
  }

  async function addFromPosition() {
    if (route.length >= maxPoints) return;
    const pos = await getPlayerPosition();
    route = [
      ...route,
      {
        id: nextId(),
        order: route.length,
        x: pos.x ?? 0,
        y: pos.y ?? 0,
        z: pos.z ?? 0,
        heading: pos.heading ?? 0,
        type: route.length === 0 ? 'START' : 'ROUTE',
      },
    ];
  }


  // Re-pins an EXISTING point to wherever the admin is standing right now —
  // not just at creation time.
  async function pinToMyPosition(index) {
    const pos = await getPlayerPosition();
    route = route.map((p, i) => (i === index ? { ...p, x: pos.x ?? p.x, y: pos.y ?? p.y, z: pos.z ?? p.z, heading: pos.heading ?? p.heading } : p));
  }

  // Jumps the admin straight to a point in-game — lets you actually see
  // where a route goes (or spot one that's badly placed) without leaving
  // the tablet to look, and makes fixing/removing a mistaken point trivial
  // since you're standing right on top of it.
  function teleportToPoint(point) {
    teleportToPosition(point.x, point.y, point.z, point.heading);
  }

  function moveUp(index) {
    if (index === 0) return;
    const copy = [...route];
    [copy[index - 1], copy[index]] = [copy[index], copy[index - 1]];
    route = copy.map((p, i) => ({ ...p, order: i }));
  }

  function moveDown(index) {
    if (index === route.length - 1) return;
    const copy = [...route];
    [copy[index + 1], copy[index]] = [copy[index], copy[index + 1]];
    route = copy.map((p, i) => ({ ...p, order: i }));
  }

  // Drag-and-drop reordering — an alternative to the up/down buttons above,
  // which get tedious moving a point several places in a long route. Drag
  // is initiated only from the dedicated grip handle (not the whole card),
  // so grabbing a dropdown/input inside the card to edit it never
  // accidentally starts a drag.
  //
  // Deliberately NOT native HTML5 drag-and-drop (draggable="true" +
  // dragstart/dragover/drop + dataTransfer) — that relies on the browser's
  // own OS-level drag gesture support, which FiveM's embedded CEF browser
  // handles unreliably; it's a common source of "drag just doesn't do
  // anything" reports in NUI apps. This instead tracks a plain mousedown ->
  // mousemove -> mouseup sequence by hand and figures out which card the
  // cursor is over via elementFromPoint — plain DOM APIs, nothing that
  // depends on native drag support at all.
  // Tracked by the point's own id, not a fixed starting index — the list
  // itself reorders LIVE as you drag over a different spot (see onDragMove
  // below), so "the index this point started at" would go stale after the
  // very first live move.
  const POINT_TYPE_ICONS = {
    START: 'flag',
    ROUTE: 'route',
    CHECKPOINT: 'shield',
    BREAK: 'clock',
    AMBUSH: 'crosshair',
    NPC_SPAWN: 'users',
    DESTINATION: 'destination',
  };

  function pointLabelFor(point, index) {
    if (point.type === 'CHECKPOINT') {
      const cp = (checkpoints || []).find((c) => c.routePointId === point.id);
      return cp && cp.name ? cp.name : `Checkpoint ${index + 1}`;
    }
    if (point.type === 'START') return 'Start Staging';
    if (point.type === 'DESTINATION') return 'Final Destination';
    if (point.type === 'BREAK') return 'Rest Break';
    if (point.type === 'AMBUSH') return 'Ambush Zone';
    if (point.type === 'NPC_SPAWN') return 'NPC Squad Deployment';
    return `Waypoint ${index + 1}`;
  }

  // ── Drag & Drop Route Tab Reordering Engine ──
  // Robust bounding-box collision detection prevents DOM mutation thrashing,
  // snapping back, or card freezing during drag.
  let draggedId = null;
  let draggedIndex = null;
  let dragOverIndex = null;
  let dragLabel = '';
  let dragAccent = '';
  let ghostX = 0, ghostY = 0;
  $: displayRoute = route;

  function startDrag(index, point, e) {
    if (locked) return;
    e.preventDefault();
    e.stopPropagation();
    draggedId = point.id;
    draggedIndex = index;
    dragOverIndex = index;
    dragLabel = `#${index + 1} ${point.type.replace('_', ' ')} — ${pointLabelFor(point, index)}`;
    dragAccent = TYPE_COLOR_JS[point.type] || 'var(--accent-primary)';
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
      if (targetIdx !== draggedIndex && targetIdx >= 0 && targetIdx < route.length) {
        const copy = [...route];
        const [moved] = copy.splice(draggedIndex, 1);
        copy.splice(targetIdx, 0, moved);
        route = copy.map((p, idx) => ({ ...p, order: idx }));
      }
    }

    draggedId = null;
    draggedIndex = null;
    dragOverIndex = null;
  }

  // ── Manual Route Point Number Changes ──
  let showNumberModal = false;
  let numberEditIndex = null;
  let targetPointNumber = 1;

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

  function openNumberModal(index) {
    if (locked) return;
    numberEditIndex = index;
    targetPointNumber = index + 1;
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
    const cur = parseInt(targetPointNumber, 10) || 1;
    targetPointNumber = Math.max(1, Math.min(cur + delta, route.length));
  }

  function applyNumberChange() {
    if (numberEditIndex === null || locked) return;
    const num = parseInt(targetPointNumber, 10);
    if (isNaN(num)) return;
    const targetIdx = Math.max(0, Math.min(num - 1, route.length - 1));
    const movedPointId = route[numberEditIndex]?.id;
    if (targetIdx !== numberEditIndex) {
      const copy = [...route];
      const [moved] = copy.splice(numberEditIndex, 1);
      copy.splice(targetIdx, 0, moved);
      route = copy.map((p, idx) => ({ ...p, order: idx }));
    }
    closeNumberModal();
    if (movedPointId) {
      selectedPointId = movedPointId;
      setTimeout(() => {
        const card = document.querySelector(`.point-card[data-id="${movedPointId}"]`);
        if (card) {
          card.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }, 100);
    }
  }

  // Placement status dot — green once this point has a real, set position;
  // red while it's still sitting at the (0,0,0) default a manually-added
  // point starts at (addManual below) before "Set to My Position" is used.
  function isPlaced(point) {
    return !(point.x === 0 && point.y === 0 && point.z === 0);
  }

  async function removeAllPoints() {
    if (route.length === 0) return;
    const ok = await confirmAction(`Delete all ${route.length} route points? Every checkpoint and airdrop configured on them goes too. This can't be undone.`, { title: 'Delete All Route Points', danger: true, confirmLabel: 'Yes, Delete All' });
    if (!ok) return;
    route = [];
    // checkpoints/airdrops clear themselves via the syncByType reactive
    // block further down, same as removing one point at a time already did.
  }

  async function removePoint(id) {
    const ok = await confirmAction('Remove this route point? Any checkpoint or airdrop configured on it goes with it.', { title: 'Remove Point', danger: true });
    if (!ok) return;
    route = route.filter((p) => p.id !== id).map((p, i) => ({ ...p, order: i }));
  }

  // Multi-select delete: ticked point ids. Always reassigned (never mutated) so the template re-renders.
  let checkedIds = [];
  $: checkedCount = route.filter((p) => checkedIds.includes(p.id)).length;

  function toggleChecked(id) {
    checkedIds = checkedIds.includes(id) ? checkedIds.filter((x) => x !== id) : [...checkedIds, id];
  }

  function toggleAllChecked() {
    checkedIds = checkedCount === route.length ? [] : route.map((p) => p.id);
  }

  async function removeChecked() {
    const ids = route.filter((p) => checkedIds.includes(p.id)).map((p) => p.id);
    if (ids.length === 0) return;
    const ok = await confirmAction(`Delete the ${ids.length} selected route point${ids.length === 1 ? '' : 's'}? Any checkpoint or airdrop configured on them goes too. This can't be undone.`, { title: 'Delete Selected Points', danger: true, confirmLabel: 'Yes, Delete Selected' });
    if (!ok) return;
    route = route.filter((p) => !ids.includes(p.id)).map((p, i) => ({ ...p, order: i }));
    checkedIds = [];
  }

  function preview() {
    previewRoute(route, checkpoints, airdrops);
  }

  onDestroy(() => clearRoutePreview());

  // the game wiped the in-world preview props / vehicles (an event started or ended): switch the preview toggles off with them
  function onGameMessage(e) {
    if (e && e.data && e.data.action === 'routePreview:reset') {
      previewingPropsCpId = null;
      previewingVehiclesCpId = null;
    }
  }
  onMount(() => window.addEventListener('message', onGameMessage));
  onDestroy(() => window.removeEventListener('message', onGameMessage));

  // "Preview on Map" drops native blips for every route point on the real
  // GTA map (auto-opened a second later, see route_editor.lua) — good for
  // seeing them in the actual game world, but its GPS line can only ever
  // trace from wherever the player currently is (a hard native limitation,
  // not a bug), never a fixed line through every point regardless of
  // position. Route Layout below (RoutePreviewMap.svelte) is what actually
  // draws that connected shape, straight from this route's own x/y data —
  // using a bundled, pre-georeferenced tile atlas (see mapGeometry.js) that
  // needs no in-tablet calibration at all, unlike an earlier version of this
  // that used a single hand-calibrated screenshot.
</script>

<SavedTemplatePicker
  kind="CONVOY"
  {locked}
  payload={{ route, checkpoints, airdrops, props }}
  replaceWarning="This REPLACES the current route, checkpoints, airdrops and event props on this convoy — anything not saved elsewhere is lost."
  on:import={applyImportedTemplate}
/>

<div class="header-row">
  <div class="section-title">Route <span class="count">{route.length} / {maxPoints}</span></div>
  <div class="header-actions">
    {#if !locked}
      <button class="btn btn-steel" disabled={recording} on:click={beginRouteRecording} title="Drive or walk the path — [E] drops a route point, [K] drops an airdrop point, [Backspace] undoes, [Enter] finishes">
        <Icon name="pin" size={13} /> {recording ? 'Recording...' : 'Add Route by Driving'}
      </button>
    {/if}
    <button class="btn btn-preview" on:click={preview}><Icon name="activity" size={13} /> Preview on Map</button>
  </div>
</div>

<div class="hint hint-compact">
  <strong>Add Route by Driving</strong> hides the tablet — drive or walk the actual path, press <strong>E</strong> to drop a route point wherever you want one, <strong>Backspace</strong> to undo the last one, <strong>Enter</strong> when done, and you're back here with the whole route filled in already. Nothing about the manual way below changes — add points one at a time and drag/reorder them exactly as before if you'd rather. To make a recorded point a checkpoint, just change its type below like any other point.
</div>

<div class="hint hint-compact">
  Only <strong>START</strong> and <strong>DESTINATION</strong> are required — trucks drive themselves between points using the
  same road-network pathfinding real traffic uses, so you don't have to plot every street. Add a plain <strong>ROUTE</strong>
  point only if you want to force the path through a specific area. Set a point to <strong>CHECKPOINT</strong>
  and its settings appear right below it — no other tab to hunt through.
  <strong>Preview on Map</strong> hides the tablet and opens your real map with every point plotted as a numbered blip —
  stand at the route's <strong>START</strong> point first if you also want the GPS line to trace the convoy's actual path.
</div>

<div class="map-preview">
  <div class="map-preview-title">
    <Icon name="activity" size={13} /> Route Layout
    <span class="map-preview-sub">— drag to pan, scroll to zoom</span>
  </div>
  {#if route.length > 0}
    <RoutePreviewMap
      {route}
      {checkpoints}
      {airdrops}
      eventKind="CONVOY"
      legend={false}
      height={680}
      editable={!locked}
      bind:selectedPointId
      on:pointDrag={handleMapPointDrag}
      on:pointMove={handleMapPointMove}
      on:selectPoint={handleMapPointSelect}
    />
    <div class="map-legend">
      {#each LEGEND as item}
        <span class="legend-item"><span class="legend-dot" style="background:{TYPE_COLOR_JS[item.type]}"></span>{item.label}</span>
      {/each}
    </div>
  {:else}
    <div class="map-empty">Add at least one route point below to see it plotted here.</div>
  {/if}
</div>

{#if !locked}
  <div class="add-point-row">
    <button class="btn btn-steel" on:click={addManual}><Icon name="waypointPlus" size={13} /> Add Manually</button>
    <button class="btn btn-steel btn-insert" on:click={() => openInsertModal(route.length > 0 ? route.length - 1 : 0, 'after')} disabled={route.length === 0} title="Insert a route point before or after a specific point">
      <Icon name="waypointPlus" size={13} /> Insert Point…
    </button>
    <button class="btn btn-steel" on:click={addFromPosition}><Icon name="pin" size={13} /> Add Pin Here</button>
    <button class="btn btn-danger" disabled={route.length === 0} on:click={removeAllPoints} title="Delete every route point"><Icon name="routeClear" size={13} /> Delete All</button>
  </div>

  {#if route.length > 0}
    <div class="select-bar">
      <label class="select-all" title="Tick the box on any point card to pick which ones to delete">
        <input type="checkbox" checked={checkedCount === route.length} indeterminate={checkedCount > 0 && checkedCount < route.length} on:change={toggleAllChecked} />
        <span>{checkedCount > 0 ? `${checkedCount} selected` : 'Select points to delete'}</span>
      </label>
      {#if checkedCount > 0}
        <button class="btn btn-steel" on:click={() => (checkedIds = [])}>Clear</button>
        <button class="btn btn-danger" on:click={removeChecked}><Icon name="trash" size={13} /> Delete Selected ({checkedCount})</button>
      {/if}
    </div>
  {/if}
{/if}

{#if draggedId !== null}
  <div class="drag-ghost" style="left:{ghostX}px; top:{ghostY}px; --point-accent:{dragAccent}">
    <div class="drag-ghost-badge">
      <Icon name="grip" size={14} />
      <span>#{draggedIndex + 1}</span>
    </div>
    <div class="drag-ghost-info">
      <span class="drag-ghost-label">{dragLabel}</span>
      <span class="drag-ghost-slot">
        {#if dragOverIndex !== null}
          Target: Position #{dragOverIndex >= displayRoute.length ? displayRoute.length : dragOverIndex + 1}
        {:else}
          Dragging...
        {/if}
      </span>
    </div>
  </div>
{/if}

<div class="point-list">
  {#each displayRoute as point, i (point.id)}
    {#if draggedId !== null && dragOverIndex === i}
      <div class="drop-indicator-line">
        <div class="drop-indicator-pill">
          <Icon name="chevronDown" size={12} />
          <span>Insert as Point #{i + 1}</span>
          <Icon name="chevronDown" size={12} />
        </div>
      </div>
    {/if}

    <div
      class="point-card"
      data-id={point.id}
      data-index={i}
      class:selected={point.id === selectedPointId}
      class:dragging={point.id === draggedId}
      style="--point-accent:{TYPE_COLOR_JS[point.type] || 'var(--tablet-border)'}"
      on:click={() => (selectedPointId = point.id)}
    >
      <div class="point-top">
        <div class="point-left">
          {#if !locked}
            <input
              type="checkbox"
              class="point-check"
              title="Select this point for bulk delete"
              checked={checkedIds.includes(point.id)}
              on:click|stopPropagation
              on:change={() => toggleChecked(point.id)}
            />
            <div
              class="drag-handle"
              title="Click and drag to reorder this route tab"
              on:mousedown={(e) => startDrag(i, point, e)}
              role="button"
              tabindex="0"
            >
              <Icon name="grip" size={16} />
              <span class="drag-handle-hint">DRAG</span>
            </div>
          {/if}

          <!-- Clickable Number Badge to manually change point number -->
          <button
            type="button"
            class="point-order-btn"
            title="Click to manually change point number (#{i + 1})"
            disabled={locked}
            on:click={() => openNumberModal(i)}
          >
            <span class="order-hash">#</span><span class="order-num">{i + 1}</span>
            <span class="order-edit-icon"><Icon name="edit" size={10} /></span>
          </button>

          <!-- Type badge with icon & select -->
          <div class="type-badge-pill" style="border-left-color: {TYPE_COLOR_JS[point.type] || 'var(--accent-primary)'}">
            <Icon name={POINT_TYPE_ICONS[point.type] || 'route'} size={14} />
            <select bind:value={point.type} class="type-select" disabled={locked}>
              {#each ROUTE_POINT_TYPES as t}<option value={t}>{t.replace('_', ' ')}</option>{/each}
            </select>
          </div>

          <!-- Point Label / Checkpoint Name & Zone -->
          <div class="point-info-group">
            <span class="point-label-title" title={pointLabelFor(point, i)}>
              {pointLabelFor(point, i)}
            </span>
            {#if zoneNames[point.id]}
              <span class="point-zone-pill"><Icon name="pin" size={11} /> {zoneNames[point.id]}</span>
            {/if}
          </div>

          <!-- Coordinates preview pill -->
          <div class="point-coords-preview mono" title="Coordinates: X={fmt(point.x)}, Y={fmt(point.y)}, Z={fmt(point.z)}, H={fmt(point.heading)}°">
            <span
              class="placed-dot"
              class:placed={isPlaced(point)}
              title={isPlaced(point) ? 'Position set' : 'Position not set'}
            ></span>
            <span>{fmt(point.x)}, {fmt(point.y)}</span>
          </div>
        </div>

        <div class="point-actions">
          {#if $bootstrap?.isAdmin}
            <button class="icon-btn info icon-btn-text" title="Teleport to this point" on:click={() => teleportToPoint(point)}><Icon name="teleport" size={13} /> Teleport</button>
          {/if}
          {#if !locked}
            <button class="icon-btn info icon-btn-text" title="Change sequence number" on:click={() => openNumberModal(i)}><Icon name="edit" size={12} /> Change #</button>
            <button class="icon-btn info icon-btn-text" title="Insert a route point before this point" on:click={() => openInsertModal(i, 'before')}><Icon name="waypointPlus" size={12} /> + Before</button>
            <button class="icon-btn info icon-btn-text" title="Insert a route point after this point" on:click={() => openInsertModal(i, 'after')}><Icon name="waypointPlus" size={12} /> + After</button>
            <button class="icon-btn success icon-btn-text" title="Set to my current position" on:click={() => pinToMyPosition(i)}><Icon name="pin" size={13} /> Set Position</button>
            <button class="icon-btn btn-move icon-btn-text" title="Move up" on:click={() => moveUp(i)} disabled={i === 0}><Icon name="chevronUp" size={14} /> Up</button>
            <button class="icon-btn btn-move icon-btn-text" title="Move down" on:click={() => moveDown(i)} disabled={i === route.length - 1}><Icon name="chevronDown" size={14} /> Down</button>
            <button class="icon-btn danger icon-btn-text" title="Remove point" on:click={() => removePoint(point.id)}><Icon name="trash" size={14} /> Delete</button>
          {/if}
        </div>
      </div>

      <fieldset class="point-fieldset" disabled={locked}>
      <div class="point-coords">
        <div class="coord-field">
          <label>X</label>
          <input type="number" step="0.01" bind:value={point.x} />
        </div>
        <div class="coord-field">
          <label>Y</label>
          <input type="number" step="0.01" bind:value={point.y} />
        </div>
        <div class="coord-field">
          <label>Z</label>
          <input type="number" step="0.01" bind:value={point.z} />
        </div>
        <div class="coord-field">
          <label>Heading</label>
          <input type="number" step="0.1" bind:value={point.heading} />
        </div>
      </div>

      {#if point.type === 'START'}
        <div class="inline-config">
          <div class="inline-title spawn-title">
            <span><Icon name="pin" size={13} /> Truck Spawn Positions</span>
            <span class="spawn-count">{spawnTrucks.filter((t) => spawnFor(point, t.id)).length} / {spawnTrucks.length} placed</span>
          </div>
          <p class="field-hint">
            Visually place where each truck should spawn with <strong>Place with Hologram</strong>, or walk there and press <strong>Set to My Position</strong>. Unset spots use automatic spacing.
          </p>
          {#if spawnTrucks.length === 0}
            <div class="spawn-empty">Add trucks in the Trucks tab first — they'll show up here.</div>
          {:else}
            <div class="spawn-list">
              {#each spawnTrucks as truck, ti (truck.id)}
                {@const sp = spawnFor(point, truck.id)}
                <div class="spawn-row" class:placed={sp}>
                  <span class="spawn-index">{ti + 1}</span>
                  <div class="spawn-info">
                    <div class="spawn-name">{truck.label || truck.model || 'Truck'} <span class="spawn-role">{ROLE_LABELS[truck.role] || truck.role}</span></div>
                    <div class="spawn-coords">
                      {#if sp}
                        X {fmt(sp.x)} · Y {fmt(sp.y)} · Z {fmt(sp.z)} · H {fmt(sp.heading)}°
                      {:else}
                        Automatic spacing
                      {/if}
                    </div>
                  </div>
                  <div class="spawn-actions">
                    {#if sp && $bootstrap?.isAdmin}
                      <button class="icon-btn-mini info icon-btn-text" title="Teleport to this spawn" on:click={() => teleportToPosition(sp.x, sp.y, sp.z, sp.heading)}><Icon name="teleport" size={11} /> Teleport</button>
                    {/if}
                    {#if !locked}
                      <button class="icon-btn success icon-btn-text" title="Place visually in world using 3D vehicle hologram" disabled={placingTruckId === truck.id} on:click={() => placeTruckSpawnHologram(i, truck)}>
                        <Icon name="eye" size={13} /> {placingTruckId === truck.id ? 'Placing...' : (sp ? 'Re-Place (Hologram)' : 'Place with Hologram')}
                      </button>
                      <button class="icon-btn success icon-btn-text" title="Set this truck's spawn to my current position and heading" on:click={() => setTruckSpawn(i, truck.id)}><Icon name="spawn" size={13} /> {sp ? 'Re-set' : 'Set to My Position'}</button>
                      {#if sp}
                        <button class="icon-btn danger icon-btn-text" title="Clear (use automatic spacing)" on:click={() => clearTruckSpawn(i, truck.id)}><Icon name="trash" size={13} /> Clear</button>
                      {/if}
                    {/if}
                  </div>
                </div>
              {/each}
            </div>
            {#if !locked && spawnTrucks.some((t) => spawnFor(point, t.id))}
              <button class="btn btn-danger spawn-clear-all" on:click={() => clearAllTruckSpawns(i)}>Clear all positions</button>
            {/if}
          {/if}
        </div>
      {/if}

      {#if point.type === 'CHECKPOINT' || point.type === 'START' || point.type === 'DESTINATION'}
        {#each checkpoints as cp (cp.routePointId)}
          {#if cp.routePointId === point.id}
            <div class="inline-config" class:focused={focusedCpId === cp.routePointId} data-cp-key={cp.routePointId}>
              <div class="inline-title"><Icon name="shield" size={13} /> {cp.supportOnly ? (point.type === 'START' ? 'Start Point Support — props, vehicles & NPC guards' : 'Destination Support — props, vehicles & NPC guards') : 'Checkpoint Settings'}</div>
              {#if !cp.supportOnly}
              <div class="field">
                <label>Name</label>
                <input type="text" bind:value={cp.name} maxlength="100" />
              </div>
              <div class="field-row">
                <div class="field">
                  <label>Radius (m)</label>
                  <input type="number" min="10" max="300" bind:value={cp.radius} />
                </div>
                <div class="field">
                  <label>Truck Wait / Hold Duration <span class="optional">({Math.floor((cp.holdDuration || 0) / 60)}m {(cp.holdDuration || 0) % 60}s)</span></label>
                  <div class="hms-grid" style="display:flex; gap:8px;">
                    <div style="flex:1;">
                      <span style="font-size: var(--fs-small); color:var(--text-dim);">Minutes</span>
                      <input
                        type="number"
                        min="0"
                        max="10"
                        value={Math.floor((cp.holdDuration || 0) / 60)}
                        on:input={(e) => {
                          const m = Math.max(0, parseInt(e.target.value, 10) || 0);
                          const s = (cp.holdDuration || 0) % 60;
                          cp.holdDuration = m * 60 + s;
                          checkpoints = [...checkpoints];
                        }}
                        disabled={locked}
                      />
                    </div>
                    <div style="flex:1;">
                      <span style="font-size: var(--fs-small); color:var(--text-dim);">Seconds</span>
                      <input
                        type="number"
                        min="0"
                        max="59"
                        value={(cp.holdDuration || 0) % 60}
                        on:input={(e) => {
                          const s = Math.max(0, Math.min(59, parseInt(e.target.value, 10) || 0));
                          const m = Math.floor((cp.holdDuration || 0) / 60);
                          cp.holdDuration = m * 60 + s;
                          checkpoints = [...checkpoints];
                        }}
                        disabled={locked}
                      />
                    </div>
                  </div>
                </div>
              </div>
              {/if}
              <!-- ONE section for everything the Prop Placer stored for this checkpoint (props and vehicles).
                   There are no separate spawn switches: what is placed is what spawns. -->
              {#each [split(cp, vset)] as stored}
                <div class="placed-props-box cp-objects" style="margin-top: 14px; margin-bottom: 12px;">
                  <div class="cp-props-header">
                    <div class="cp-props-info-block">
                      <p class="cp-info"><Icon name="info" size={13} /> <span>Using the Prop Placer, you can add props and vehicles directly inside the checkpoint zones. All placed objects will be saved with the checkpoint and used automatically.</span></p>
                    </div>
                    <div class="placement-actions cp-actions">
                      <button
                        class="btn btn-sm btn-primary"
                        type="button"
                        disabled={locked}
                        on:click={() => openCheckpointPlacer(cp)}
                      >
                        <Icon name="move" size={12} />
                        <span>{stored.props.length + stored.vehicles.length > 0 ? 'Open in Prop Placer' : 'Place with Prop Placer'}</span>
                      </button>
                      <button
                        class="btn btn-sm btn-steel"
                        type="button"
                        disabled={locked || (stored.props.length + stored.vehicles.length) === 0}
                        title="Open the Prop Placer on the stored objects, starting over their area"
                        on:click={() => previewStored(cp)}
                      >
                        <Icon name="eye" size={12} />
                        <span>Preview</span>
                      </button>
                    </div>
                  </div>

                  {#if stored.props.length + stored.vehicles.length === 0}
                    <div class="empty-hint">Nothing stored yet. Open the <strong>Prop Placer</strong>, pick a barricade or a vehicle, click in the world, <strong>Duplicate</strong> as often as you need — then <strong>Save Layout</strong> brings you straight back here. Placed vehicles are locked, frozen and can't be entered, driven, or destroyed — pure ambience, removed automatically once the event ends.</div>
                  {:else}
                    <!-- Stats Toolbar -->
                    <div class="dummy-toolbar cp-props-toolbar">
                      <div class="dummy-stats">
                        <div class="stat-chip">
                          <Icon name="box" size={12} />
                          <span>Props: <strong>{stored.props.length}</strong></span>
                        </div>
                        <div class="stat-chip">
                          <Icon name="truck" size={12} />
                          <span>Vehicles: <strong>{stored.vehicles.length}</strong></span>
                        </div>
                        <div class="stat-chip">
                          <span class="dot-solid"></span>
                          <span>Solid: <strong>{[...stored.props, ...stored.vehicles].filter((o) => o.collision !== false).length}</strong></span>
                          <span class="dot-ghost" style="margin-left: 6px;"></span>
                          <span>Ghost: <strong>{[...stored.props, ...stored.vehicles].filter((o) => o.collision === false).length}</strong></span>
                        </div>
                      </div>
                      <div class="dummy-bulk-actions">
                        <button class="btn btn-xs btn-danger" type="button" disabled={locked} on:click={() => clearStored(cp)}>
                          Remove All
                        </button>
                      </div>
                    </div>

                    <!-- Clean Structured Table -->
                    <div class="dummy-table-wrap cp-table-wrap">
                      <table class="dummy-table">
                        <thead>
                          <tr>
                            <th style="width: 50px;">#</th>
                            <th>Prop / Vehicle Model</th>
                            <th>World Position (X, Y, Z)</th>
                            <th style="width: 80px;">Heading</th>
                            <th style="width: 95px;">Physics</th>
                            <th style="width: 140px; text-align: right;">Actions</th>
                          </tr>
                        </thead>
                        <tbody>
                          {#each [...stored.props.map((o, i) => ({ o, veh: false, idx: i })), ...stored.vehicles.map((o, i) => ({ o, veh: true, idx: stored.props.length + i }))] as item, n}
                            <tr>
                              <td>
                                <span class="idx-badge">#{n + 1}</span>
                              </td>
                              <td>
                                <div class="model-cell">
                                  <span class="dummy-model-text" title={item.o.model}>{item.o.model}</span>
                                  {#if item.veh}
                                    <span class="type-pill veh">Vehicle</span>
                                  {:else}
                                    <span class="type-pill prop">Prop</span>
                                  {/if}
                                </div>
                              </td>
                              <td class="mono coords-cell">
                                {Number(item.o.x).toFixed(1)}, {Number(item.o.y).toFixed(1)}, {Number(item.o.z).toFixed(1)}
                              </td>
                              <td class="mono heading-cell">
                                {Number(item.o.heading || 0).toFixed(1)}°
                              </td>
                              <td>
                                <span class="phys-badge {item.o.collision === false ? 'ghost' : 'solid'}">
                                  {item.o.collision === false ? 'Non-solid' : 'Solid'}
                                </span>
                              </td>
                              <td style="text-align: right;">
                                <div class="table-actions">
                                  <button type="button" class="btn btn-xs btn-edit" on:click={() => openCheckpointPlacer(cp, item.veh ? 'vehicles' : 'barricades', item.idx + 1)} disabled={locked} title="Edit in Prop Placer">
                                    <Icon name="eye" size={11} /><span>Edit</span>
                                  </button>
                                  <button type="button" class="btn btn-xs" on:click={() => teleportToPosition(item.o.x, item.o.y, item.o.z, item.o.heading)} title="Teleport to object">
                                    <Icon name="teleport" size={11} />
                                  </button>
                                  <button type="button" class="btn btn-xs btn-danger" on:click={() => removeStored(cp, item.o)} disabled={locked} title="Delete object">
                                    <Icon name="close" size={11} />
                                  </button>
                                </div>
                              </td>
                            </tr>
                          {/each}
                        </tbody>
                      </table>
                    </div>
                  {/if}
                </div>
              {/each}
              {#if !cp.supportOnly}
              <div class="cp-group-top"><Toggle label="Announce this checkpoint" bind:checked={cp.announce} disabled={locked} /></div>
              {/if}
              <Toggle label="NPC guards shoot non-police here" bind:checked={cp.gangAttackEnabled} disabled={locked} />
              <div class="hint" style="margin:-2px 0 8px;font-size:var(--fs-meta);opacity:.7;">On (default for checkpoints): the NPC police / army guards here shoot anyone who is not on-duty police the moment they enter this point's circle (its radius). Off: they only stand guard and never shoot.</div>
              {#if features.NpcPolice}
                <div class="sub-block">
                  <Toggle label="NPC Police Defensive Guards" bind:checked={cp.npcPolice.enabled} disabled={locked} />
                  {#if cp.npcPolice.enabled}
                    <div class="field-row">
                      <div class="field">
                        <label>Guard Count</label>
                        <input type="number" min="1" max="10" bind:value={cp.npcPolice.count} />
                      </div>
                      <div class="field">
                        <label>Guard Staging Location</label>
                        <select bind:value={cp.npcPolice.zoneId}>
                          <option value={null}>Checkpoint Barricades / Nearest NPC Spawn</option>
                          {#each policeZones as z (z.id)}<option value={z.id}>{z.label} ({z.radius}m)</option>{/each}
                        </select>
                      </div>
                    </div>
                    <div class="field-row">
                      <div class="field">
                        <label>Guard Ped Model</label>
                        <select bind:value={cp.npcPolice.model}>
                          {#each POLICE_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
                        </select>
                      </div>
                      <div class="field">
                        <label>Custom Ped Model <span class="optional">override</span></label>
                        <input type="text" bind:value={cp.npcPolice.model} placeholder="e.g. s_m_y_cop_01" />
                      </div>
                    </div>
                    <div class="field-row">
                      <div class="field">
                        <label>Armed Weapon</label>
                        <select bind:value={cp.npcPolice.weapon}>
                          {#each COMMON_WEAPONS as w}<option value={w.value}>{w.label}</option>{/each}
                        </select>
                      </div>
                      <div class="field">
                        <label>Shooting Aggressiveness</label>
                        <select bind:value={cp.npcPolice.aggressiveness}>
                          {#each AGGRESSIVENESS_OPTIONS as a}<option value={a.value}>{a.label}</option>{/each}
                        </select>
                      </div>
                    </div>
                    <div class="field-row">
                      <div class="field">
                        <Toggle label="Arrive in a vehicle (off = on foot, no vehicle spawns)" bind:checked={cp.npcPolice.spawnVehicle} disabled={locked}
                          on:change={(e) => { if (e.detail && !cp.npcPolice.vehicleModel) cp.npcPolice.vehicleModel = 'police3'; checkpoints = [...checkpoints]; }} />
                      </div>
                      {#if cp.npcPolice.spawnVehicle}
                        <div class="field">
                          <label>Support vehicle <span class="optional">spawns beside the guards</span></label>
                          <select bind:value={cp.npcPolice.vehicleModel}>
                            {#each POLICE_SUPPORT_VEHICLES as v}<option value={v.value}>{v.label}</option>{/each}
                          </select>
                        </div>
                      {/if}
                    </div>
                    {#if newZone?.type === 'POLICE'}
                      <div class="zone-add-row">
                        <input type="text" placeholder="Zone name" bind:value={newZone.label} maxlength="100" />
                        <input type="number" min="5" max="200" title="Radius (m)" bind:value={newZone.radius} />
                        <button class="btn btn-primary" disabled={newZone.saving} on:click={saveNewZone}>{newZone.saving ? 'Saving...' : 'Save'}</button>
                        <button class="btn" on:click={() => (newZone = null)}>Cancel</button>
                      </div>
                      {#if newZone.error}<div class="error">{newZone.error}</div>{/if}
                    {:else}
                      <button class="link-btn" on:click={() => startAddZone('POLICE')}><Icon name="plus" size={11} /> Add custom zone at my position</button>
                    {/if}
                  {/if}
                </div>
              {/if}
              {#if features.ArmySupport}
                <div class="sub-block">
                  <Toggle label="Army Defensive Support" bind:checked={cp.army.enabled} disabled={locked} />
                  {#if cp.army.enabled}
                    <div class="field-row">
                      <div class="field">
                        <label>Army Unit Count</label>
                        <input type="number" min="1" max="10" bind:value={cp.army.count} />
                      </div>
                      <div class="field">
                        <label>Guard Staging Location</label>
                        <select bind:value={cp.army.zoneId}>
                          <option value={null}>Checkpoint Barricades / Nearest NPC Spawn</option>
                          {#each armyZones as z (z.id)}<option value={z.id}>{z.label} ({z.radius}m)</option>{/each}
                        </select>
                      </div>
                    </div>
                    <div class="field-row">
                      <div class="field">
                        <label>Unit Ped Model</label>
                        <select bind:value={cp.army.model}>
                          {#each ARMY_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
                        </select>
                      </div>
                      <div class="field">
                        <label>Custom Ped Model <span class="optional">override</span></label>
                        <input type="text" bind:value={cp.army.model} placeholder="e.g. s_m_y_marine_03" />
                      </div>
                    </div>
                    <div class="field-row">
                      <div class="field">
                        <label>Armed Weapon</label>
                        <select bind:value={cp.army.weapon}>
                          {#each COMMON_WEAPONS as w}<option value={w.value}>{w.label}</option>{/each}
                        </select>
                      </div>
                      <div class="field">
                        <label>Shooting Aggressiveness</label>
                        <select bind:value={cp.army.aggressiveness}>
                          {#each AGGRESSIVENESS_OPTIONS as a}<option value={a.value}>{a.label}</option>{/each}
                        </select>
                      </div>
                    </div>
                    <div class="field-row">
                      <div class="field">
                        <Toggle label="Arrive in a vehicle (off = on foot, no truck spawns)" bind:checked={cp.army.spawnVehicle} disabled={locked}
                          on:change={(e) => { if (e.detail && !cp.army.vehicleModel) cp.army.vehicleModel = 'crusader'; checkpoints = [...checkpoints]; }} />
                      </div>
                      {#if cp.army.spawnVehicle}
                        <div class="field">
                          <label>Support vehicle <span class="optional">spawns beside the unit</span></label>
                          <select bind:value={cp.army.vehicleModel}>
                            {#each ARMY_SUPPORT_VEHICLES as v}<option value={v.value}>{v.label}</option>{/each}
                          </select>
                        </div>
                      {/if}
                    </div>
                    {#if newZone?.type === 'ARMY'}
                      <div class="zone-add-row">
                        <input type="text" placeholder="Zone name" bind:value={newZone.label} maxlength="100" />
                        <input type="number" min="5" max="200" title="Radius (m)" bind:value={newZone.radius} />
                        <button class="btn btn-primary" disabled={newZone.saving} on:click={saveNewZone}>{newZone.saving ? 'Saving...' : 'Save'}</button>
                        <button class="btn" on:click={() => (newZone = null)}>Cancel</button>
                      </div>
                      {#if newZone.error}<div class="error">{newZone.error}</div>{/if}
                    {:else}
                      <button class="link-btn" on:click={() => startAddZone('ARMY')}><Icon name="plus" size={11} /> Add custom zone at my position</button>
                    {/if}
                  {/if}
                </div>
              {/if}
            </div>
          {/if}
        {/each}
      {:else if point.type === 'NPC_SPAWN'}
        <div class="inline-config">
          <div class="inline-title"><Icon name="users" size={13} /> NPC Spawn Waypoint Settings</div>
          {#if !point.npcConfig}
            <span style="display:none">{point.npcConfig = { faction: 'POLICE', count: 4, model: 's_m_y_cop_01', weapon: 'WEAPON_CARBINERIFLE', aggressiveness: 'medium', behavior: 'GUARD_AREA', triggerMode: 'WHEN_REACHED', announce: false }}</span>
          {/if}
          <div class="field-row">
            <div class="field">
              <label>Spawn Faction / List</label>
              <select bind:value={point.npcConfig.faction} on:change={() => {
                if (point.npcConfig.faction === 'POLICE') point.npcConfig.model = 's_m_y_cop_01';
                else if (point.npcConfig.faction === 'ARMY') point.npcConfig.model = 's_m_y_marine_03';
                else if (point.npcConfig.faction === 'SECURITY') point.npcConfig.model = 's_m_m_security_01';
                else if (point.npcConfig.faction === 'CARTEL') point.npcConfig.model = 'g_m_y_salvagoon_01';
              }} disabled={locked}>
                <option value="POLICE">Police Support / Escort</option>
                <option value="ARMY">Military Army Support</option>
                <option value="SECURITY">Private Security Forces</option>
                <option value="CARTEL">Cartel Hostiles (Ambush Attackers)</option>
              </select>
            </div>
            <div class="field">
              <label>Ped Count</label>
              <input type="number" min="1" max="10" bind:value={point.npcConfig.count} disabled={locked} />
            </div>
          </div>

          <div class="field-row">
            <div class="field">
              <label>Ped Model Preset</label>
              <select bind:value={point.npcConfig.model} disabled={locked}>
                {#if point.npcConfig.faction === 'POLICE'}
                  {#each POLICE_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
                {:else if point.npcConfig.faction === 'ARMY'}
                  {#each ARMY_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
                {:else if point.npcConfig.faction === 'SECURITY'}
                  {#each SECURITY_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
                {:else}
                  {#each CARTEL_MODELS as m}<option value={m.value}>{m.label}</option>{/each}
                {/if}
              </select>
            </div>
            <div class="field">
              <label>Custom Ped Model <span class="optional">override</span></label>
              <input type="text" bind:value={point.npcConfig.model} placeholder="e.g. s_m_y_cop_01" disabled={locked} />
            </div>
          </div>

          <div class="field-row">
            <div class="field">
              <label>Armed Weapon</label>
              <select bind:value={point.npcConfig.weapon} disabled={locked}>
                {#each COMMON_WEAPONS as w}<option value={w.value}>{w.label}</option>{/each}
              </select>
            </div>
            <div class="field">
              <label>Shooting Aggressiveness</label>
              <select bind:value={point.npcConfig.aggressiveness} disabled={locked}>
                {#each AGGRESSIVENESS_OPTIONS as a}<option value={a.value}>{a.label}</option>{/each}
              </select>
            </div>
          </div>

          <div class="field-row">
            <div class="field">
              <label>Trigger Mode</label>
              <select bind:value={point.npcConfig.triggerMode} disabled={locked}>
                <option value="WHEN_REACHED">Spawn When Convoy Reaches This Point</option>
                <option value="CHECKPOINT_SUPPORT">Reserved Staging For Nearby Checkpoint</option>
              </select>
            </div>
            <div class="field">
              <label>NPC Combat Behavior</label>
              <select bind:value={point.npcConfig.behavior} disabled={locked}>
                <option value="GUARD_AREA">Guard / Defend Area</option>
                <option value="PATROL_AREA">Patrol / Wander Vicinity</option>
                <option value="FOLLOW_CONVOY">Follow Convoy Path</option>
              </select>
            </div>
          </div>

          <Toggle label="Announce deployment banner when spawned" bind:checked={point.npcConfig.announce} disabled={locked} />
        </div>
      {/if}
      </fieldset>
    </div>
  {:else}
    <div class="empty-state">
      No route points yet.<br />
      Stand where you want a point and click "Drop Pin Here" — or add one manually and fill in the coordinates.
    </div>
  {/each}

  {#if draggedId !== null && dragOverIndex === displayRoute.length}
    <div class="drop-indicator-line bottom">
      <div class="drop-indicator-pill">
        <Icon name="chevronDown" size={12} />
        <span>Insert at end as Point #{displayRoute.length}</span>
        <Icon name="chevronDown" size={12} />
      </div>
    </div>
  {/if}
</div>

{#if showInsertModal}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div
    class="insert-backdrop"
    use:portal
    on:click|self={closeInsertModal}
    on:keydown={(e) => { if (e.key === 'Escape') closeInsertModal(); }}
  >
    <div class="insert-box" role="dialog" aria-modal="true" aria-label="Insert Route Point">
      <div class="insert-head">
        <div class="insert-title">
          <Icon name="waypointPlus" size={15} />
          Insert Route Point
        </div>
        <button class="icon-btn" title="Close" on:click={closeInsertModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="insert-body">
        <div class="insert-field">
          <label>Reference Point</label>
          <select bind:value={insertRefIndex} class="insert-select">
            {#each route as pt, idx}
              <option value={idx}>
                Point #{idx + 1} — {pt.type.replace('_', ' ')} {zoneNames[pt.id] ? `(${zoneNames[pt.id]})` : `(X: ${fmt(pt.x)}, Y: ${fmt(pt.y)})`}
              </option>
            {/each}
          </select>
        </div>

        <div class="insert-field">
          <label>Position Relative to Point #{insertRefIndex + 1}</label>
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
            The new point will become #{insertPosition === 'before' ? insertRefIndex + 1 : insertRefIndex + 2} in the sequence. All subsequent points will automatically shift down.
          </div>
        </div>

        <div class="insert-field">
          <label>Point Type</label>
          <select bind:value={insertType} class="insert-select">
            {#each ROUTE_POINT_TYPES as t}
              <option value={t}>{t.replace('_', ' ')}</option>
            {/each}
          </select>
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
              <input type="number" step="0.01" bind:value={insertManualCoords.z} placeholder="0.0" />
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
        <button class="btn btn-primary" on:click={confirmInsertPoint} disabled={insertingBusy}>
          {insertingBusy ? 'Inserting…' : 'Insert Route Point'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showNumberModal && numberEditIndex !== null && displayRoute[numberEditIndex]}
  {@const curPt = displayRoute[numberEditIndex]}
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
    <div class="insert-box number-modal-box" role="dialog" aria-modal="true" aria-label="Change Route Point Number">
      <div class="insert-head">
        <div class="insert-title">
          <Icon name="edit" size={15} />
          Change Route Point Number
        </div>
        <button class="icon-btn" title="Close" on:click={closeNumberModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="insert-body">
        <div class="num-modal-summary">
          <div class="num-modal-badge" style="border-left-color: {TYPE_COLOR_JS[curPt.type] || 'var(--accent-primary)'}">
            <span class="num-modal-curr">Current Position: <strong>#{numberEditIndex + 1}</strong></span>
            <span class="num-modal-type">{curPt.type.replace('_', ' ')}</span>
            <span class="num-modal-name">{pointLabelFor(curPt, numberEditIndex)}</span>
          </div>
          {#if zoneNames[curPt.id]}
            <div class="num-modal-zone"><Icon name="pin" size={12} /> {zoneNames[curPt.id]} (X: {fmt(curPt.x)}, Y: {fmt(curPt.y)})</div>
          {/if}
        </div>

        <div class="insert-field">
          <label>Target Route Point Number (1 to {displayRoute.length})</label>
          <div class="num-stepper-row">
            <button
              type="button"
              class="stepper-btn"
              disabled={targetPointNumber <= 1}
              on:click={() => stepTargetNumber(-1)}
              title="Decrease number"
            >
              <Icon name="chevronDown" size={16} />
            </button>
            <input
              type="number"
              class="num-stepper-input"
              min="1"
              max={displayRoute.length}
              bind:value={targetPointNumber}
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
              disabled={targetPointNumber >= displayRoute.length}
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
            Changing this point from #{numberEditIndex + 1} to <strong>#{targetPointNumber}</strong> will smoothly reposition it in the route sequence. Other points will adjust so the sequence remains strictly continuous (1 to {displayRoute.length}) without gaps or duplicates.
          </p>
          <p class="conflict-note">
            ✓ Coordinates, checkpoint settings, barricades, vehicles, and guards are 100% preserved.
          </p>
        </div>
      </div>

      <div class="insert-foot">
        <button class="btn" on:click={closeNumberModal}>Cancel</button>
        <span class="insert-spacer"></span>
        <button
          class="btn btn-primary"
          on:click={applyNumberChange}
          disabled={targetPointNumber === numberEditIndex + 1}
        >
          Apply New Number (#{targetPointNumber})
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  /* Stacked rows (not everything crammed onto one flex line) — the picker
     is its own row, and the "Save Current Route As..." trigger/expanded
     name-input row is a full-width row underneath, same layout language as
     the rest of the tablet (Route point cards, checkpoint config blocks all
     stack top-to-bottom too) instead of a single overflowing line. */
  .template-bar {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-bottom: 14px;
    padding: 12px;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
  }
  .template-title {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--text-dim);
  }
  .template-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
  }
  .template-count {
    color: var(--text-dim);
    font-weight: 500;
    text-transform: none;
    letter-spacing: normal;
  }
  .template-manage-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .template-manage-hint strong {
    color: var(--text-main);
  }
  .template-picker {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 240px;
  }
  .template-picker select {
    flex: 1;
    min-width: 0;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 10px;
    font-size: var(--fs-body);
    font-weight: 500;
  }
  /* A disabled <select> (no saved templates yet) gets its own resistant
     UA-forced styling in Chromium/CEF — plain `color` alone loses to it,
     hence -webkit-text-fill-color + opacity:1 on top of it. The dropdown's
     own <option> list is a separate rendering context too (this is what
     was showing black text on a black background); styling it directly is
     the only way to actually reach it. */
  .template-picker select:disabled {
    color: var(--text-dim);
    -webkit-text-fill-color: var(--text-dim);
    opacity: 1;
    background: var(--tablet-bg);
  }
  .template-picker select option {
    background: var(--tablet-panel-alt);
    color: var(--text-main);
  }
  .template-picker select option:disabled {
    color: var(--text-dim);
    -webkit-text-fill-color: var(--text-dim);
  }
  .template-save-row {
    padding-top: 8px;
    border-top: 1px dashed var(--tablet-border);
  }
  .template-save-row input {
    flex: 1;
    min-width: 0;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 10px;
    font-size: var(--fs-body);
  }
  .template-save-row input:focus {
    outline: none;
    border-color: var(--accent-primary);
  }
  .template-save-row input::placeholder {
    color: var(--text-placeholder);
  }
  .header-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 14px;
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
  .count {
    color: var(--tablet-text-faint);
    font-weight: 400;
    margin-left: 4px;
  }
  .header-actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .hint {
    font-size: var(--fs-body);
    color: var(--text-dim);
    line-height: 1.5;
    margin-bottom: 18px;
    padding: 10px 14px;
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
  }
  .hint strong {
    color: var(--text-main);
  }
  /* the two how-to boxes above the map: smaller so the map gets the room */
  .hint-compact {
    font-size: var(--fs-meta);
    line-height: 1.4;
    margin-bottom: 8px;
    padding: 6px 12px;
  }

  .map-preview {
    margin-bottom: 18px;
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
  .map-preview-sub {
    font-weight: var(--fw-body);
    color: var(--tablet-text-faint);
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
    gap: 12px;
    margin-top: 10px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .legend-item {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .legend-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .add-point-row {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-bottom: 14px;
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
  }
  .select-all input,
  .point-check {
    width: 17px;
    height: 17px;
    flex: none;
    margin: 0;
    cursor: pointer;
    accent-color: var(--accent-primary, #c9a24a);
  }

  .point-list {
    display: flex;
    flex-direction: column;
    gap: 14px;
    contain: layout;
  }
  .point-card {
    contain: layout style;
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-left: 3px solid var(--point-accent, var(--tablet-border));
    border-radius: var(--radius-md);
    padding: 18px 20px;
    background: var(--doctrine-card-bg);
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
  }
  .point-card.selected {
    border-color: rgba(96, 165, 250, 0.6);
    box-shadow: 0 0 0 1.5px var(--accent-primary, #60a5fa), 0 4px 18px rgba(0, 0, 0, 0.35);
  }
  /* A dimmed card alone is easy to lose track of in a route with a lot of
     points — scroll away and back and you have to re-scan the whole list to
     find which one you're holding. This pulses the card's own border/fill
     (not the floating cursor badge) so it stays easy to spot at a glance,
     wherever it is in a long list. Pulses between two solid intensities —
     no blur/bloom, still the "no glow" rule. */
  @keyframes dragPointPulse {
    0%, 100% {
      background: color-mix(in srgb, var(--point-accent, var(--tablet-border)) 14%, var(--doctrine-card-bg));
      border-color: color-mix(in srgb, var(--point-accent, var(--tablet-border)) 55%, rgba(var(--ink-rgb, 255, 255, 255), 0.1));
    }
    50% {
      background: color-mix(in srgb, var(--point-accent, var(--tablet-border)) 32%, var(--doctrine-card-bg));
      border-color: color-mix(in srgb, var(--point-accent, var(--tablet-border)) 95%, rgba(var(--ink-rgb, 255, 255, 255), 0.1));
    }
  }
  .point-card.dragging {
    opacity: 0.92;
    border-width: 2px;
    animation: dragPointPulse 0.8s ease-in-out infinite;
  }
  /* Floating badge that follows the cursor while dragging — the actual
     card underneath already live-reorders as you move (see onDragMove),
     this is just the "you're holding something" feedback so it visibly
     comes along with the mouse instead of everything only jumping once
     you release. */
  /* Floating badge that follows the cursor while dragging */
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
    border: 1.5px solid var(--point-accent, var(--accent-primary));
    background: rgba(var(--ltc-18-24-38, 18, 24, 38), 0.95);
    box-shadow: 0 10px 25px rgba(0, 0, 0, 0.6), 0 0 15px rgba(96, 165, 250, 0.2);
    color: var(--text-main);
    white-space: nowrap;
  }
  .drag-ghost-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
    background: var(--point-accent, var(--accent-primary));
    color: var(--lt-ffffff, #fff);
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
    color: var(--accent-primary, #60a5fa);
    font-weight: 500;
  }

  .drop-indicator-line {
    position: relative;
    height: 4px;
    margin: -5px 0;
    border-radius: 2px;
    background: var(--accent-primary, #60a5fa);
    box-shadow: 0 0 10px rgba(96, 165, 250, 0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
    pointer-events: none;
    animation: dropLinePulse 0.6s ease-in-out infinite alternate;
    color: var(--on-accent, inherit);
}
  .drop-indicator-line.bottom {
    margin: 8px 0 0 0;
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
    background: var(--accent-primary, #3b82f6);
    color: var(--on-accent, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    border-radius: 12px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.4);
    white-space: nowrap;
  }

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
    border-color: var(--accent-primary, #60a5fa);
    color: var(--accent-primary, #60a5fa);
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
    padding: 2px 8px;
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-left-width: 3px;
    border-radius: var(--radius-sm);
  }
  .type-badge-pill .type-select {
    border: none;
    background: transparent;
    padding: 5px 4px;
    min-width: 120px;
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main);
  }
  .type-badge-pill .type-select:focus {
    outline: none;
  }

  .point-info-group {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .point-label-title {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 220px;
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

  /* Manual Renumbering Modal */
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
    border-left: 3px solid var(--accent-primary);
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
    border-color: var(--accent-primary);
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
    border-color: var(--accent-primary);
    color: var(--accent-primary);
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
    border-left: 3px solid rgb(59, 130, 246);}
  .conflict-title {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--accent-primary, #60a5fa);
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
    gap: 12px;
    min-width: 0;
    flex-wrap: wrap;
  }
  .point-fieldset {
    border: none;
    padding: 0;
    margin: 0;
  }
  .point-fieldset:disabled {
    opacity: 0.6;
  }
  .point-actions {
    display: flex;
    gap: 6px;
    flex-shrink: 0;
  }
  /* Purpose colour AT REST, not just on hover — destructive/utility/confirm
     actions each get a quiet tint of their own so the section reads at a
     glance, same idea as Drop Pin Here's own coloured box, just mixed
     mostly INTO the panel colour instead of a solid fill, so it stays calm
     rather than flashy. color-mix keeps this to one line per state instead
     of needing a dedicated -rgb variable for every accent colour used here.
     Bare icon-only buttons (no text label, e.g. Remove point / Move Up-Down)
     get a plain white border instead — the icon's OWN colour still says
     what it does, but with no label at all a white border reads as
     "clickable" more clearly than a subtle colour-on-colour one does. A
     text-labeled button (icon-btn-text, e.g. "Delete All") is unambiguous
     either way, so those keep the coloured border. */
  /* Text label instead of a bare icon — an icon-only button relies entirely
     on a hover tooltip to say what it does, which doesn't work at all for
     touch/controller-style tablet navigation and isn't obvious even with a
     mouse until you've already guessed right and hovered it. */

  .point-coords {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
  }
  .coord-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }
  .coord-field label {
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--tablet-text-faint);
  }
  .coord-field input {
    background: var(--input-bg, #131518);
    border: 1px solid var(--input-border, #30353c);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 9px;
    font-size: var(--fs-body);
    font-family: var(--font-mono);
  }
  .coord-field input:hover:not(:disabled) {
    background: var(--input-bg-hover, #15171b);
    border-color: var(--input-border-hover, #3a4048);
  }
  .coord-field input:focus {
    outline: none;
    border-color: var(--accent-primary);
    background: var(--input-bg-focus, #181b1f);
  }

  .inline-config {
    margin-top: 16px;
    padding-top: 16px;
    border-top: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
    transition: box-shadow 0.4s ease;
  }
  /* Brief highlight on the checkpoint panel the admin is dropped back onto
     after finishing in-game placement — makes it obvious the tablet returned
     to the RIGHT section instead of them wondering if it reset. */
  .spawn-title {
    justify-content: space-between;
  }
  .spawn-title > span:first-child {
    display: inline-flex;
    align-items: center;
    gap: 7px;
  }
  .spawn-count {
    font-size: var(--fs-small);
    font-weight: 500;
    color: var(--text-dim);
  }
  .spawn-empty {
    font-size: var(--fs-small);
    color: var(--text-dim);
    padding: 10px 0;
  }
  .spawn-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-top: 10px;
  }
  .spawn-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
  }
  .spawn-row.placed {
    border-left: 3px solid var(--accent-primary);
  }
  .spawn-index {
    width: 22px;
    height: 22px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main);
    border: 1px solid var(--tablet-border);
  }
  .spawn-info {
    flex: 1;
    min-width: 0;
  }
  .spawn-name {
    font-size: var(--fs-small);
    color: var(--text-main);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .spawn-role {
    margin-left: 6px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .spawn-coords {
    font-size: var(--fs-small);
    font-family: var(--font-mono);
    color: var(--text-dim);
    margin-top: 2px;
  }
  .spawn-actions {
    display: flex;
    gap: 6px;
    flex-shrink: 0;
  }
  .spawn-clear-all {
    margin-top: 10px;
  }

  .inline-config.focused {
    box-shadow: 0 0 0 2px var(--accent-primary);
  }
  .cp-placer-quick-card {
    margin-top: 14px;
    padding: 14px 16px;
    background: var(--bg-surface, #15171b);
    border: 1px solid rgba(var(--accent-primary-rgb), 0.3);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-panel);
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .cp-placer-quick-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
  }
  .cp-placer-quick-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-main, #ffffff);
  }
  .cp-placer-quick-badges {
    display: flex;
    gap: 6px;
  }
  .cp-badge {
    padding: 2px 8px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    color: var(--text-muted, #7c848d);
  }
  .cp-badge.has-items {
    background: var(--c-hover);
    border-color: var(--accent-primary);
    color: var(--lt-93c5fd, #93c5fd);
  }
  .cp-placer-quick-desc {
    margin: 0;
    font-size: var(--fs-meta);
    line-height: 1.45;
    color: var(--text-dim, #959ca5);
  }
  .cp-placer-quick-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .btn-cp-open-placer {
    min-height: 32px;
    padding: 0 12px;
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .cp-group-top {
    margin-top: 14px;
    padding-top: 6px;
    border-top: 1px solid var(--tablet-border);
  }
  .inline-title {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 34px;
    margin-bottom: 14px;
    padding: 6px 12px;
    background: var(--topbar-bg, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .inline-subtitle {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 20px 0 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
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
  .field label .optional {
    text-transform: none;
    font-weight: 400;
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-left: 4px;
  }
  .field-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 4px 0 8px;
  }
  .sub-block {
    border-top: 1px solid rgba(var(--accent-primary-rgb), 0.1);
    padding-top: 10px;
    margin-top: 10px;
  }
  .link-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    background: transparent;
    border: none;
    color: var(--accent-primary-light);
    font-size: var(--fs-small);
    font-weight: 600;
    padding: 6px 0;
    margin-top: 4px;
  }
  .link-btn:hover {
    color: var(--text-main);
  }
  .zone-add-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 8px;
    flex-wrap: wrap;
  }
  .zone-add-row input[type='text'] {
    flex: 1;
    min-width: 140px;
  }
  .zone-add-row input[type='number'] {
    width: 80px;
  }
  .zone-add-row input {
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 10px;
    font-size: var(--fs-body);
  }

  .btn-group-row {
    display: flex;
    gap: 6px;
    margin-top: 4px;
  }
  .segment-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 7px 12px;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
  }
  .segment-btn:hover {
    color: var(--text-main);
    border-color: var(--tablet-border-hover);
  }
  .segment-btn.active {
    background: var(--c-action);
    border-color: var(--accent-primary);
    color: var(--on-accent);
  }
  /* Full-width action row under the prop dropdown — the two placement buttons
     sit side by side with room to breathe instead of being squeezed into a
     shared grid column next to the select (which made the long primary button
     collide with it). Wraps to stacked full-width buttons on narrow panels. */
  .placement-actions {
    display: flex;
    gap: 10px;
    margin-top: 4px;
    margin-bottom: 14px;
    flex-wrap: wrap;
  }
  .placement-actions .btn {
    flex: 1 1 auto;
    justify-content: center;
    min-width: 200px;
  }
  /* the combined checkpoint section: info note, [Prop Placer][Preview], then the two stored counts */
  .cp-info {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    margin: 0 0 10px;
    font-size: var(--fs-meta);
    line-height: 1.5;
    color: var(--text-dim);
  }
  .cp-info :global(svg) { flex: none; margin-top: 2px; color: var(--lt-7bb6f2, #7bb6f2); }
  .placement-actions.cp-actions { margin-top: 0; margin-bottom: 12px; }
  .placement-actions.cp-actions .btn { min-width: 140px; height: 38px; font-size: var(--fs-small); font-weight: 700; }
  .stored-counts {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
  }
  .stored-lines { display: flex; flex-direction: column; gap: 6px; }   /* the small gap between the two counts */
  .stored-line { font-size: var(--fs-small); font-weight: 600; color: var(--text-main); }
  .stored-line strong { color: var(--lt-7bb6f2, #7bb6f2); }
  .placed-props-box {
    margin-top: 10px;
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .cp-props-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    flex-wrap: wrap;
  }
  .cp-props-info-block {
    flex: 1;
    min-width: 240px;
  }
  .cp-props-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
    padding: 10px 14px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-line, #2a2e35);
    border-bottom: none;
    border-radius: var(--r-panel) var(--r-panel) 0 0;
  }
  .dummy-stats {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .stat-chip {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 6px 12px;
    background: var(--bg-card-raised, #1c1f24);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-e3e6e9, #e3e6e9);
  }
  .stat-chip strong {
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-body);
  }
  .dot-solid {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #22c55e;
    box-shadow: none;
  }
  .dot-ghost {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #eab308;
    box-shadow: none;
  }
  .dummy-bulk-actions {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .cp-table-wrap {
    overflow-x: auto;
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: 0 0 var(--r-panel) var(--r-panel);
    max-height: 280px;
    overflow-y: auto;
  }
  .dummy-table {
    width: 100%;
    min-width: 740px;
    border-collapse: collapse;
    font-size: var(--fs-small);
    text-align: left;
  }
  .dummy-table th {
    position: sticky;
    top: 0;
    z-index: 2;
    padding: 10px 14px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }
  .dummy-table td {
    padding: 10px 14px;
    font-size: var(--fs-body);
    border-bottom: 1px solid var(--c-line-soft);
    color: var(--lt-ffffff, #fff);
    vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }
  .dummy-table tbody tr:hover td {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
    font-variant-numeric: tabular-nums;
  }
  .idx-badge {
    font-weight: 600;
    color: var(--text-muted, #8d949c);
    font-size: var(--fs-meta);
    white-space: nowrap;
  }
  .model-cell {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .dummy-model-text {
    font-family: var(--font-mono);
    color: var(--lt-93c5fd, #93c5fd);
    font-size: var(--fs-small);
    font-weight: 600;
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .type-pill {
    padding: 2px 7px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .type-pill.veh {
    background: rgb(155, 123, 255);
    color: #111111;
    border: 1px solid rgb(155, 123, 255);
  }
  .type-pill.prop {
    background: rgb(59, 130, 246);
    color: #111111;
    border: 1px solid rgb(59, 130, 246);
  }
  .coords-cell {
    font-size: var(--fs-small);
    color: var(--lt-c9ced4, #c9ced4);
    white-space: nowrap;
  }
  .heading-cell {
    font-size: var(--fs-small);
    color: var(--lt-959ca5, #959ca5);
    white-space: nowrap;
  }
  .phys-badge {
    display: inline-block;
    padding: 2px 7px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    white-space: nowrap;
  }
  .phys-badge.solid {
    background: rgb(34, 197, 94);
    border: 1px solid rgb(34, 197, 94);
    color: #111111;
  }
  .phys-badge.ghost {
    background: rgb(234, 179, 8);
    border: 1px solid rgb(234, 179, 8);
    color: #111111;
  }
  .table-actions {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    justify-content: flex-end;
    white-space: nowrap;
  }
  .table-actions :global(.btn) {
    min-height: 28px;
    height: 28px;
  }
  .btn-edit {
    background: rgba(59, 130, 246, 0.15) !important;
    border: 1px solid rgba(59, 130, 246, 0.4) !important;
    color: var(--lt-93c5fd, #93c5fd) !important;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 0 8px !important;
    font-size: var(--fs-meta) !important;
  }
  .btn-edit:hover:not(:disabled) {
    background: rgba(59, 130, 246, 0.28) !important;
    color: var(--lt-ffffff, #fff) !important;
  }
  .empty-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    font-style: italic;
    padding: 4px 0;
  }

  @media (max-width: 900px) {
    .point-coords {
      grid-template-columns: repeat(2, 1fr);
    }
  }

  /* Coordinate ("vector") text: larger + bold so it reads at a glance. */
  .coord-field label { font-size: var(--fs-small); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-c9ced4, #c9ced4); }
  .coord-field input { font-size: var(--fs-body); font-weight: 700; letter-spacing: 0.01em; }
  .spawn-coords { font-size: var(--fs-body); font-weight: 700; color: var(--lt-eceef0, #eceef0); }
  .prop-chip-coords { font-size: var(--fs-meta); font-weight: 600; color: var(--lt-eceef0, #eceef0); }
  .spawn-coords, .prop-chip-coords { font-family: var(--font-ui); font-variant-numeric: tabular-nums; }
  .coord-field input { font-family: var(--font-ui); font-variant-numeric: tabular-nums; }

  /* ── Insert Point Modal Styling ── */
  .btn-insert {
    background: var(--c-action) !important;
    border: 1px solid var(--c-action) !important;
    color: var(--on-accent);
  }
  .btn-insert:hover:not(:disabled) {
    background: var(--c-hover) !important;
    color: var(--lt-ffffff, #fff) !important;
  }
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
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
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
    border-color: rgba(var(--accent-primary-rgb, 59, 130, 246), 0.7);
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
    background: var(--c-action);
    border-color: var(--c-action);
    color: var(--on-accent);
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
</style>
