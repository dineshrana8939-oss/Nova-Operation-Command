<script>
  import { onDestroy } from 'svelte';
  import { getPlayerPosition, getGroundZ, teleportToPosition, getZoneName, previewRoute, clearRoutePreview, startZoneRecording } from '../../api/route.js';
  import { openPropPlacer } from '../../api/placer.js';
  import { bootstrap, zoneRecordingResult } from '../../stores.js';
  import { getVehicleCatalog } from '../../api/vehicles.js';
  import { onMount } from 'svelte';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import { revealLast } from '../ui/reveal.js';
  import { renumberAuto } from '../../util/autoName.js';
  import RoutePreviewMap from '../ui/RoutePreviewMap.svelte';
  import { applyMove, applyLive, liveThrottle } from '../../util/mapMove.js';
  // a pin may be a spawn zone, a manual truck or a dropoff: the one with that id changes, wherever it is listed
  const moveInHotCargo = (hc, d, fn) => ({
    ...hc,
    spawnZones: fn(hc.spawnZones || [], d),
    trucks: fn(hc.trucks || [], d),
    dropoffZones: fn(hc.dropoffZones || [], d),
  });
  const liveMove = liveThrottle((d) => { hotCargo = moveInHotCargo(hotCargo, d, applyLive); });
  import SavedTemplatePicker from '../ui/SavedTemplatePicker.svelte';
  import RewardListEditor from '../ui/RewardListEditor.svelte';
  import '../tablet-theme.css';

  // On-all-trucks-resolved-without-delivery (failurePolicy) and the Disabled
  // Truck / Salvage Reward editor live in CreateConvoy's General tab now,
  // next to the main event Reward field — both moved out of here so they're
  // not buried below the zone lists.
  export let hotCargo = {
    policeAlertBufferSeconds: 45,
    trucks: [],
    spawnZones: [],
    dropoffZones: [],
  };
  export let locked = false;
  // 'trucks' renders the Cargo Trucks tab, 'zones' renders the Route
  // Builder tab (Spawn Zones + Truck Spawn Positions + Dropoff
  // Destinations) — CreateConvoy mounts this component twice, once per tab,
  // same hotCargo object bound both times.
  export let section = 'trucks';

  // Only real tractor-trailer rigs — see config.lua's Config.HotCargoTheft
  // for why the box-truck/van models (Brickade, Benson, Pounder, Mule) were
  // dropped. This list is a fallback layer under the config/catalog ones in
  // truckOptions below (dedup by model), so trimming the config list alone
  // wasn't enough — those models would still show up from here.
  const COMMON_TRUCKS = [
    { model: 'packer', label: 'Packer (Heavy Semi + Flatbed Trailer)' },
    { model: 'hauler', label: 'Hauler (Heavy Rig + Box Trailer)' },
  ];

  // Mirrors config.lua's Config.HotCargoTheft.trailerModels. Used for two
  // things: (1) picking which trailer ghost to show during placement mode
  // below — the real spawn (doStartHotCargo) always reads its own
  // authoritative copy of this server-side regardless, so a mismatch there
  // could only ever look wrong, never spawn wrong; (2) filtering the
  // Vehicle Catalog merge in truckOptions just below — that catalog is
  // shared with the regular Convoy Trucks tab, which allows ANY vehicle
  // (sedans, small vans, whatever an admin registered there), and without
  // this filter every one of them leaked straight into the Hot Cargo picker
  // too regardless of trimming Config.HotCargoTheft.vehicles/COMMON_TRUCKS
  // above — a real cargo truck belongs on a real trailer, not the other
  // way around, so only a catalog entry that ALSO has a trailer mapping
  // here is allowed through.
  const TRAILER_MODELS = { hauler: 'trailers2', packer: 'trailers3' };

  // Picker list = config.lua vehicles (Config.HotCargoTheft.vehicles) + trucks registered
  // in the Trucks tab's Vehicle Catalog + the built-in defaults. Deduped by model.
  // Shared across every truck row (not per-model like before, since there's no
  // longer a single global model) — each row's <select> just reads from this.
  let catalogTrucks = [];
  onMount(async () => {
    const res = await getVehicleCatalog().catch(() => null);
    // Also requires a known trailerModels entry — the catalog is shared
    // with regular Convoy (which allows any vehicle at all), so without
    // this a small car/van/utility truck registered there for Convoy would
    // otherwise leak straight into the Hot Cargo picker too.
    catalogTrucks = res && res.ok
      ? (res.vehicles || []).filter((v) => v.category !== 'ESCORT' && TRAILER_MODELS[String(v.model || '').toLowerCase()])
      : [];
  });
  $: truckOptions = (() => {
    const seen = new Set();
    const list = [];
    const add = (model, label, note, source) => {
      const m = String(model || '').trim().toLowerCase();
      if (!m || seen.has(m)) return;
      seen.add(m);
      list.push({ model: m, label: label || m, note: note || '', source });
    };
    for (const v of $bootstrap?.hotCargoVehicles || []) add(v.model, v.label, v.note, 'config');
    for (const v of catalogTrucks) add(v.model, v.label, 'From vehicle catalog', 'catalog');
    for (const v of COMMON_TRUCKS) add(v.model, v.label.replace(/ \(.*\)$/, ''), (v.label.match(/\((.*)\)/) || [])[1], 'default');
    // A model typed in by hand (or saved earlier) that isn't in any list still shows as selected.
    for (const t of hotCargo.trucks || []) {
      if (t.model) add(t.model, t.model, 'Custom model code', 'custom');
    }
    return list;
  })();
  function modelLabel(model) {
    return truckOptions.find((t) => t.model === model)?.label || model || '—';
  }

  // Which truck's edit row is expanded — same click-to-expand pattern as
  // Convoy's own Trucks tab (TruckConfig.svelte), one truck's form open at a
  // time instead of every truck's form sitting expanded at once.
  let editingTruckId = null;


  const GUARD_WEAPONS = [
    { value: 'WEAPON_CARBINERIFLE', label: 'Carbine Rifle (M4)' },
    { value: 'WEAPON_ASSAULTRIFLE', label: 'Assault Rifle (AK-47)' },
    { value: 'WEAPON_SMG', label: 'SMG (MP5)' },
    { value: 'WEAPON_COMBATPISTOL', label: 'Combat Pistol' },
    { value: 'WEAPON_PUMPSHOTGUN', label: 'Pump Shotgun' },
  ];

  const GUARD_MODELS = [
    { value: 'g_m_y_salvagoon_01', label: 'Salvadorian Cartel Goon' },
    { value: 'g_m_y_mexgoon_01', label: 'Mexican Cartel Goon' },
    { value: 'g_m_y_ballas_01', label: 'Street Thug' },
    { value: 's_m_y_blackops_01', label: 'Black Ops Mercenary' },
    { value: 's_m_m_security_01', label: 'Armed Security Guard' },
  ];

  const AGGRESSIVENESS_OPTIONS = [
    { value: 'low', label: 'Low (Recruit — Low accuracy)' },
    { value: 'medium', label: 'Medium (Tactical — Balanced)' },
    { value: 'high', label: 'High (Aggressive — Dynamic advance)' },
    { value: 'extreme', label: 'Extreme (Lethal — Pinpoint aim)' },
  ];

  let pickingTarget = null; // { type: 'spawn' | 'dropoff' | 'truck', id: string, name: string }

  // A spawn / dropoff pin clicked on the map selects its card and brings it into view, same as the Convoy route builder.
  let selectedPointId = null;
  function handleMapZoneSelect(e) {
    const id = e.detail?.id || null;
    selectedPointId = id;
    if (!id) return;
    const card = document.querySelector(`.zone-card[data-id="${id}"]`);
    if (card) card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  // Defensive defaults for reactive fields
  $: if (!hotCargo.spawnZones) hotCargo.spawnZones = [];
  $: if (!hotCargo.dropoffZones) hotCargo.dropoffZones = [];
  $: if (!hotCargo.trucks) hotCargo.trucks = [];
  $: if (!hotCargo.salvageReward) hotCargo.salvageReward = [];
  $: if (hotCargo.policeAlertBufferSeconds == null) hotCargo.policeAlertBufferSeconds = 45;
  $: if (hotCargo.dropoffZones) {
    hotCargo.dropoffZones.forEach((d) => {
      if (d.guardCount == null) d.guardCount = 0;
      if (!d.guardWeapon) d.guardWeapon = 'WEAPON_CARBINERIFLE';
      if (!d.guardModel) d.guardModel = 'g_m_y_salvagoon_01';
      if (!d.guardAggressiveness) d.guardAggressiveness = 'high';
      if (d.shootAnyone == null) d.shootAnyone = true;
    });
  }
  $: if (hotCargo.spawnZones) {
    hotCargo.spawnZones.forEach((z) => {
      if (z.guardCount == null) z.guardCount = 3;
      if (!z.guardWeapon) z.guardWeapon = 'WEAPON_CARBINERIFLE';
      if (!z.guardModel) z.guardModel = 'g_m_y_salvagoon_01';
      if (!z.guardAggressiveness) z.guardAggressiveness = 'high';
      if (z.shootAnyone == null) z.shootAnyone = true;
    });
  }
  $: if (hotCargo.trucks) {
    hotCargo.trucks.forEach((t) => {
      if (!t.model) t.model = 'hauler';
      if (t.health == null) t.health = 2500;
      if (t.heading == null) t.heading = 0;
      if (t.guardCount == null) t.guardCount = 3;
      if (!t.guardWeapon) t.guardWeapon = 'WEAPON_CARBINERIFLE';
      if (!t.guardModel) t.guardModel = 'g_m_y_salvagoon_01';
      if (!t.guardAggressiveness) t.guardAggressiveness = 'high';
      if (t.shootAnyone == null) t.shootAnyone = true;
      if (!Array.isArray(t.deliveryReward)) t.deliveryReward = [{ type: 'MONEY', amount: 50000, pool: '' }];
      if (!Array.isArray(t.hijackReward)) t.hijackReward = [{ type: 'MONEY', amount: 15000, pool: '' }];
    });
  }

  function startPicking(type, id, name) {
    if (pickingTarget && pickingTarget.id === id) {
      pickingTarget = null;
      return;
    }
    pickingTarget = { type, id, name };
    const mapEl = document.querySelector('.map-preview');
    if (mapEl) mapEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  async function handleMapClick(e) {
    if (!e || !e.detail || !pickingTarget) return;
    const { x, y } = e.detail;
    // the height of the spot clicked on the map (not the admin's own height wherever they happen to stand)
    const ground = await getGroundZ(x, y, undefined).catch(() => null);
    let zVal;
    if (ground && ground.found) zVal = Number(Number(ground.z).toFixed(2));
    else {
      const pos = await getPlayerPosition();
      zVal = (pos && pos.z != null) ? Number(pos.z.toFixed(2)) : 70;
    }

    if (pickingTarget.type === 'spawn') {
      hotCargo.spawnZones = hotCargo.spawnZones.map((z) =>
        z.id === pickingTarget.id ? { ...z, x, y, z: zVal } : z
      );
    } else if (pickingTarget.type === 'truckSpawn') {
      hotCargo.spawnZones = hotCargo.spawnZones.map((z) =>
        z.id === pickingTarget.id ? { ...z, truckX: x, truckY: y, truckZ: zVal } : z
      );
    } else if (pickingTarget.type === 'dropoff') {
      hotCargo.dropoffZones = hotCargo.dropoffZones.map((d) =>
        d.id === pickingTarget.id ? { ...d, x, y, z: zVal } : d
      );
    }
    pickingTarget = null;
  }

  function nextId(prefix) {
    return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  }

  // Same helper/behavior as Convoy's RouteBuilder.svelte truck-spawn rows.
  function fmt(n) {
    return Number(n || 0).toFixed(1);
  }

  // --- Cargo Trucks ---
  // One unified add — same "add blank, jump straight into editing it" flow
  // as Convoy's own addTruck. Trucks never carry their own spawn vector any
  // more (see Spawn Zones below) — the script always randomly assigns a
  // truck to one of the configured zones at event start.
  function addTruck() {
    const count = hotCargo.trucks.length + 1;
    const truck = {
      id: nextId('truck'),
      name: `Cargo Truck ${String(count).padStart(2, '0')}`,
      model: truckOptions[0]?.model || 'hauler',
      health: 2500,
      guardCount: 3, guardWeapon: 'WEAPON_CARBINERIFLE', guardModel: 'g_m_y_salvagoon_01',
      guardAggressiveness: 'high', shootAnyone: true,
      deliveryReward: [{ type: 'MONEY', amount: 50000, pool: '' }],
      hijackReward: [{ type: 'MONEY', amount: 15000, pool: '' }],
    };
    hotCargo.trucks = [...hotCargo.trucks, truck];
    editingTruckId = truck.id;
  }

  async function removeTruck(id) {
    const ok = await confirmAction('Remove this cargo truck?', { title: 'Remove Truck', danger: true });
    if (!ok) return;
    hotCargo.trucks = hotCargo.trucks.filter((t) => t.id !== id);
    if (editingTruckId === id) editingTruckId = null;
  }

  // --- Spawn Zones ---
  // One unified add (matching addTruck's "add blank, position it with a
  // dedicated button afterward" flow, and Convoy's own Truck Spawn
  // Positions panel) — replaces the old two-button Add Here / Add Manual
  // split. A zone starts unset; "Set to My Position" on its row is the only
  // way to place it, same button/wording as Convoy uses for trucks.
  function addZone() {
    const count = hotCargo.spawnZones.length + 1;
    hotCargo.spawnZones = [
      ...hotCargo.spawnZones,
      {
        id: nextId('spawn'),
        name: `Spawn Zone ${String(count).padStart(2, '0')}`,
        x: null,
        y: null,
        z: null,
        heading: 0.0,
        truckX: null,
        truckY: null,
        truckZ: null,
        truckHeading: 0.0,
        guardCount: 3,
        guardWeapon: 'WEAPON_CARBINERIFLE',
        guardModel: 'g_m_y_salvagoon_01',
        guardAggressiveness: 'high',
        shootAnyone: true,
      },
    ];
    revealLast('.spawn-row');
  }

  async function addSpawnHere() {
    const pos = await getPlayerPosition();
    const count = hotCargo.spawnZones.length + 1;
    hotCargo.spawnZones = [
      ...hotCargo.spawnZones,
      {
        id: nextId('spawn'),
        name: `Spawn Zone ${String(count).padStart(2, '0')}`,
        x: pos && pos.x != null ? Number(pos.x.toFixed(2)) : null,
        y: pos && pos.y != null ? Number(pos.y.toFixed(2)) : null,
        z: pos && pos.z != null ? Number(pos.z.toFixed(2)) : null,
        heading: pos && pos.heading != null ? Number(pos.heading.toFixed(1)) : 0.0,
        truckX: null,
        truckY: null,
        truckZ: null,
        truckHeading: 0.0,
        guardCount: 3,
        guardWeapon: 'WEAPON_CARBINERIFLE',
        guardModel: 'g_m_y_salvagoon_01',
        guardAggressiveness: 'high',
        shootAnyone: true,
      },
    ];
    revealLast('.spawn-row');
  }

  async function removeAllSpawnZones() {
    const ok = await confirmAction('Delete every spawn zone in this operation? This cannot be undone.', { title: 'Delete All Spawn Zones', danger: true });
    if (!ok) return;
    hotCargo.spawnZones = [];
    checkedSpawnIds = [];
  }

  let checkedSpawnIds = [];
  $: checkedSpawnCount = (hotCargo.spawnZones || []).filter((z) => checkedSpawnIds.includes(z.id)).length;
  function toggleSpawnChecked(id) {
    if (checkedSpawnIds.includes(id)) checkedSpawnIds = checkedSpawnIds.filter((x) => x !== id);
    else checkedSpawnIds = [...checkedSpawnIds, id];
  }
  function toggleAllSpawnChecked() {
    if (checkedSpawnCount === (hotCargo.spawnZones || []).length) checkedSpawnIds = [];
    else checkedSpawnIds = (hotCargo.spawnZones || []).map((z) => z.id);
  }
  async function removeCheckedSpawnZones() {
    if (!checkedSpawnCount) return;
    const ok = await confirmAction(`Delete ${checkedSpawnCount} selected spawn zone(s)?`, { title: 'Delete Selected Zones', danger: true });
    if (!ok) return;
    hotCargo.spawnZones = (hotCargo.spawnZones || []).filter((z) => !checkedSpawnIds.includes(z.id));
    checkedSpawnIds = [];
  }

  function moveSpawnZone(index, delta) {
    const target = index + delta;
    if (target < 0 || target >= (hotCargo.spawnZones || []).length) return;
    const copy = [...hotCargo.spawnZones];
    const [moved] = copy.splice(index, 1);
    copy.splice(target, 0, moved);
    hotCargo.spawnZones = copy;
  }

  async function removeSpawnZone(id) {
    const ok = await confirmAction('Remove this spawn zone?', { title: 'Remove Zone', danger: true });
    if (!ok) return;
    hotCargo.spawnZones = hotCargo.spawnZones.filter((z) => z.id !== id);
    checkedSpawnIds = checkedSpawnIds.filter((x) => x !== id);
  }

  async function pinSpawnToMyPos(id) {
    const pos = await getPlayerPosition();
    hotCargo.spawnZones = hotCargo.spawnZones.map((z) =>
      z.id === id
        ? {
            ...z,
            x: pos.x != null ? Number(pos.x.toFixed(2)) : z.x,
            y: pos.y != null ? Number(pos.y.toFixed(2)) : z.y,
            z: pos.z != null ? Number(pos.z.toFixed(2)) : z.z,
            heading: pos.heading != null ? Number(pos.heading.toFixed(1)) : z.heading,
          }
        : z
    );
  }

  // Sets the PRECISE truck spawn vector within a zone — separate from the
  // zone's own general-area position above.
  async function pinTruckSpawnToMyPos(id) {
    const pos = await getPlayerPosition();
    hotCargo.spawnZones = hotCargo.spawnZones.map((z) =>
      z.id === id
        ? {
            ...z,
            truckX: pos.x != null ? Number(pos.x.toFixed(2)) : z.truckX,
            truckY: pos.y != null ? Number(pos.y.toFixed(2)) : z.truckY,
            truckZ: pos.z != null ? Number(pos.z.toFixed(2)) : z.truckZ,
            truckHeading: pos.heading != null ? Number(pos.heading.toFixed(1)) : z.truckHeading,
          }
        : z
    );
  }

  function clearTruckSpawnVector(id) {
    hotCargo.spawnZones = hotCargo.spawnZones.map((z) =>
      z.id === id ? { ...z, truckX: null, truckY: null, truckZ: null, truckHeading: 0.0 } : z
    );
  }

  // Full in-world truck+trailer placement mode (route_editor.lua's
  // startHotCargoTruckPlacer) — same idea as pinTruckSpawnToMyPos above
  // (sets the same truckX/Y/Z/truckHeading fields) but lets the admin walk
  // through positioning it with a live ghost instead of only being able to
  // stand exactly where they want the truck's cab to end up. Defaults to
  // the zone's first assigned/first-configured truck's model so the ghost
  // matches what will actually spawn there; falls back to 'hauler'.
  async function enterTruckPlacer(id) {
    const zone = hotCargo.spawnZones.find((z) => z.id === id);
    if (!zone) return;
    const model = (hotCargo.trucks && hotCargo.trucks[0] && hotCargo.trucks[0].model) || 'hauler';
    const trailerModel = TRAILER_MODELS[String(model).toLowerCase()] || '';
    const hasVector = zone.truckX != null;
    // The shared Prop Placer, one truck: the trailer ghost follows it exactly where the real one will be
    // spawned (9 m behind), and only the truck's own spot is saved.
    const res = await openPropPlacer({
      context: 'hotcargo_truck',
      title: `Truck spot — ${zone.name || 'spawn zone'}`,
      objects: hasVector ? [{ model, x: zone.truckX, y: zone.truckY, z: zone.truckZ, heading: zone.truckHeading || 0 }] : [],
      autoCreate: hasVector ? undefined : { model },
      companion: trailerModel ? { model: trailerModel, back: 9.0 } : undefined,
      // no truck spot saved yet: no anchor, the camera (and the new truck) start where the player stands
      focus: hasVector ? { x: zone.truckX, y: zone.truckY, z: zone.truckZ } : undefined,
    });
    const truck = res && res.ok && Array.isArray(res.objects) ? res.objects[0] : null;
    if (!truck) return;
    hotCargo.spawnZones = hotCargo.spawnZones.map((z) =>
      z.id === id
        ? { ...z, truckX: truck.x, truckY: truck.y, truckZ: truck.z, truckHeading: truck.heading }
        : z
    );
  }

  // --- Dropoff Zones ---
  async function addDropoffHere() {
    const pos = await getPlayerPosition();
    const count = hotCargo.dropoffZones.length + 1;
    hotCargo.dropoffZones = [
      ...hotCargo.dropoffZones,
      {
        id: nextId('dropoff'),
        name: `Dropoff Destination ${count}`,
        x: pos.x != null ? Number(pos.x.toFixed(2)) : 0,
        y: pos.y != null ? Number(pos.y.toFixed(2)) : 0,
        z: pos.z != null ? Number(pos.z.toFixed(2)) : 70,
        radius: 15,
        guardCount: 0,
        guardWeapon: 'WEAPON_CARBINERIFLE',
        guardModel: 'g_m_y_salvagoon_01',
        guardAggressiveness: 'high',
        shootAnyone: true,
      },
    ];
  }

  function addDropoffManual() {
    const count = hotCargo.dropoffZones.length + 1;
    hotCargo.dropoffZones = [
      ...hotCargo.dropoffZones,
      {
        id: nextId('dropoff'),
        name: `Dropoff Destination ${count}`,
        // null, not 0/0/70 — see addSpawnManual()'s comment just above.
        x: null,
        y: null,
        z: null,
        radius: 15,
        guardCount: 0,
        guardWeapon: 'WEAPON_CARBINERIFLE',
        guardModel: 'g_m_y_salvagoon_01',
        guardAggressiveness: 'high',
        shootAnyone: true,
      },
    ];
  }

  async function removeAllDropoffZones() {
    const ok = await confirmAction('Delete every dropoff destination in this operation? This cannot be undone.', { title: 'Delete All Dropoffs', danger: true });
    if (!ok) return;
    hotCargo.dropoffZones = [];
    checkedDropoffIds = [];
  }

  let checkedDropoffIds = [];
  $: checkedDropoffCount = (hotCargo.dropoffZones || []).filter((d) => checkedDropoffIds.includes(d.id)).length;
  function toggleDropoffChecked(id) {
    if (checkedDropoffIds.includes(id)) checkedDropoffIds = checkedDropoffIds.filter((x) => x !== id);
    else checkedDropoffIds = [...checkedDropoffIds, id];
  }
  function toggleAllDropoffChecked() {
    if (checkedDropoffCount === (hotCargo.dropoffZones || []).length) checkedDropoffIds = [];
    else checkedDropoffIds = (hotCargo.dropoffZones || []).map((d) => d.id);
  }
  async function removeCheckedDropoffZones() {
    if (!checkedDropoffCount) return;
    const ok = await confirmAction(`Delete ${checkedDropoffCount} selected dropoff(s)?`, { title: 'Delete Selected Dropoffs', danger: true });
    if (!ok) return;
    hotCargo.dropoffZones = (hotCargo.dropoffZones || []).filter((d) => !checkedDropoffIds.includes(d.id));
    checkedDropoffIds = [];
  }

  function moveDropoffZone(index, delta) {
    const target = index + delta;
    if (target < 0 || target >= (hotCargo.dropoffZones || []).length) return;
    const copy = [...hotCargo.dropoffZones];
    const [moved] = copy.splice(index, 1);
    copy.splice(target, 0, moved);
    hotCargo.dropoffZones = copy;
  }

  async function removeDropoffZone(id) {
    const ok = await confirmAction('Remove this dropoff destination?', { title: 'Remove Dropoff', danger: true });
    if (!ok) return;
    hotCargo.dropoffZones = hotCargo.dropoffZones.filter((d) => d.id !== id);
    checkedDropoffIds = checkedDropoffIds.filter((x) => x !== id);
  }

  async function pinDropoffToMyPos(id) {
    const pos = await getPlayerPosition();
    hotCargo.dropoffZones = hotCargo.dropoffZones.map((d) =>
      d.id === id
        ? {
            ...d,
            x: pos.x != null ? Number(pos.x.toFixed(2)) : d.x,
            y: pos.y != null ? Number(pos.y.toFixed(2)) : d.y,
            z: pos.z != null ? Number(pos.z.toFixed(2)) : d.z,
          }
        : d
    );
  }

  function teleportTo(x, y, z, heading) {
    if (x == null || y == null) return;
    teleportToPosition(x, y, z || 70, heading || 0);
  }

  // Zone area reverse-lookup
  let locationNames = {};
  async function resolveLocName(item) {
    if (item.x == null || item.y == null) return;
    const key = `${Math.round(item.x)},${Math.round(item.y)}`;
    if (locationNames[item.id] !== undefined) return;
    const res = await getZoneName(item.x, item.y, item.z || 0);
    locationNames = { ...locationNames, [item.id]: (res && res.name) || null };
  }
  $: (hotCargo.spawnZones || []).forEach(resolveLocName);
  $: (hotCargo.dropoffZones || []).forEach(resolveLocName);

  onDestroy(() => clearRoutePreview());

  function applyImportedTemplate(e) {
    const res = e.detail;
    if (res.kind && res.kind !== 'HOT_CARGO') return;
    hotCargo.spawnZones = res.spawnZones || [];
    hotCargo.dropoffZones = res.dropoffZones || [];
    hotCargo.trucks = res.trucks || [];
  }

  // Zone Recorder (zone_recorder.lua) — walk to each spot, [E] drops a spawn
  // zone, [K] drops a dropoff zone, instead of "Add Manually" + "Set
  // Position" one at a time from inside the tablet for every single zone.
  let zoneRecording = false;
  const unsubZoneRecording = zoneRecordingResult.subscribe((msg) => {
    if (!msg) return;
    // Only consume a session this builder started — another event kind's zone
    // recording must never land on this Hot Cargo's spawn/dropoff lists.
    if (msg.target && msg.target !== 'HOT_CARGO') return;
    const points = msg.points || [];
    if (points.length > 0) {
      const newSpawns = [];
      const newDropoffs = [];
      const spawnBase = hotCargo.spawnZones.length;
      const dropoffBase = hotCargo.dropoffZones.length;
      points.forEach((p) => {
        if (p.type === 'B') {
          newDropoffs.push({
            id: nextId('dropoff'),
            name: `Dropoff Destination ${dropoffBase + newDropoffs.length + 1}`,
            x: p.x, y: p.y, z: p.z,
            radius: 15,
            guardCount: 0,
            guardWeapon: 'WEAPON_CARBINERIFLE',
            guardModel: 'g_m_y_salvagoon_01',
            guardAggressiveness: 'high',
            shootAnyone: true,
          });
        } else {
          newSpawns.push({
            id: nextId('spawn'),
            name: `Spawn Zone ${spawnBase + newSpawns.length + 1}`,
            x: p.x, y: p.y, z: p.z,
            heading: p.heading || 0,
          });
        }
      });
      hotCargo.spawnZones = [...hotCargo.spawnZones, ...newSpawns];
      hotCargo.dropoffZones = [...hotCargo.dropoffZones, ...newDropoffs];
      revealLast(newDropoffs.length > 0 ? '.dropoff-card' : '.spawn-row');
    }
    zoneRecording = false;
    zoneRecordingResult.set(null);
  });

  async function beginZoneRecording() {
    zoneRecording = true;
    await startZoneRecording({ primaryLabel: 'Spawn Zone', secondaryLabel: 'Dropoff Zone', target: 'HOT_CARGO' });
  }

  // "Cargo Truck 01", "Spawn Zone 02", "Dropoff Destination 3"… always match each entry's current position, so deleting
  // or adding one never leaves a gap or a duplicate name. Anything you renamed keeps its own name.
  $: if (hotCargo && !locked) {
    const trucks = renumberAuto(hotCargo.trucks, 'Cargo Truck ', { pad: 2 });
    if (trucks !== hotCargo.trucks) hotCargo.trucks = trucks;
    const spawns = renumberAuto(hotCargo.spawnZones, 'Spawn Zone ', { pad: 2 });
    if (spawns !== hotCargo.spawnZones) hotCargo.spawnZones = spawns;
    const dropoffs = renumberAuto(hotCargo.dropoffZones, 'Dropoff Destination ');
    if (dropoffs !== hotCargo.dropoffZones) hotCargo.dropoffZones = dropoffs;
  }

  onDestroy(() => unsubZoneRecording());
</script>

<div class="hot-cargo-config">
{#if section === 'trucks'}
  <!-- Concept & Rules Banner -->
  <div class="banner-card">
    <div class="banner-head">
      <Icon name="flame" size={16} />
      <span class="banner-title">Hot Cargo Contraband Operation</span>
    </div>
    <p class="banner-text">
      Each Cargo Truck below either spawns at a fixed, admin-pinned position (Manual) or gets assigned a random unused Spawn Zone when the event starts (Random) — competing gangs have to locate and hijack every truck the same way either way.
      <strong>Police remain completely unaware</strong> until a gang enters the driver's seat and the stealth buffer timer expires.
      Once driven to a designated dropoff, the truck despawns and leaves an <strong>unlocked reward crate</strong> (no lockpicking minigame required) for the delivering crew.
    </p>
  </div>

  <!-- 1. Cargo Trucks Roster -->
  <div class="header-row">
    <div class="section-title">
      Cargo Trucks <span class="count">{(hotCargo.trucks || []).length} total</span>
    </div>
    <div class="header-actions">
      {#if !locked}
        <button class="btn btn-primary" on:click={addTruck}><Icon name="plus" size={13} /> Add Truck</button>
      {/if}
    </div>
  </div>

  {#if (hotCargo.trucks || []).length === 0}
    <div class="empty-state">No cargo trucks configured yet. Click "Add Truck" to build the roster.</div>
  {:else}
    <table class="data-table truck-table">
      <thead>
        <tr>
          <th>#</th>
          <th>Name</th>
          <th>Model</th>
          <th>Health</th>
          <th style="text-align:right">Actions</th>
        </tr>
      </thead>
      <tbody>
        {#each hotCargo.trucks || [] as truck, i (truck.id)}
          <tr class:editing-row={editingTruckId === truck.id} on:click={() => (editingTruckId = editingTruckId === truck.id ? null : truck.id)}>
            <td>{i + 1}</td>
            <td>{truck.name || 'Cargo Truck'}</td>
            <td>{modelLabel(truck.model)}</td>
            <td>{truck.health || 2500} HP</td>
            <td><div class="row-actions">
              <button class="btn btn-sm btn-edit" on:click|stopPropagation={() => (editingTruckId = editingTruckId === truck.id ? null : truck.id)}>
                <Icon name="edit" size={12} /> {editingTruckId === truck.id ? 'Close' : 'Edit'}
              </button>
              {#if !locked}
                <button class="btn btn-danger btn-sm" on:click|stopPropagation={() => removeTruck(truck.id)}>
                  <Icon name="trash" size={12} /> Remove
                </button>
              {/if}
            </div></td>
          </tr>
          {#if editingTruckId === truck.id}
            <tr class="edit-row">
              <td colspan="5">
                <div class="truck-edit-form">
                  <div class="field-row">
                    <div class="field">
                      <label>Truck Name</label>
                      <input type="text" bind:value={truck.name} placeholder="Cargo Truck" disabled={locked} maxlength="100" />
                    </div>
                    <div class="field">
                      <label>Vehicle Model</label>
                      <select bind:value={truck.model} disabled={locked}>
                        {#each truckOptions as t (t.model)}
                          <option value={t.model}>{t.label}{t.note ? ` — ${t.note}` : ''}</option>
                        {/each}
                      </select>
                    </div>
                    <div class="field">
                      <label>Truck Health (HP)</label>
                      <input type="number" min="1000" max="50000" step="100" bind:value={truck.health} disabled={locked} />
                    </div>
                  </div>

                  <div class="field" style="margin-top: 14px;">
                    <label style="font-weight: 700; color: #ffffff; display: flex; align-items: center; gap: 6px;">
                      <Icon name="flag" size={13} /> Truck Delivery Reward
                      <span class="optional" style="color: var(--text-dim); font-weight: 400;">— Main payout granted when this truck is safely delivered to the dropoff</span>
                    </label>
                    <RewardListEditor bind:rewards={truck.deliveryReward} disabled={locked} />
                  </div>

                  <div class="field" style="margin-top: 14px;">
                    <label style="font-weight: 700; color: #38bdf8; display: flex; align-items: center; gap: 6px;">
                      <Icon name="box" size={13} /> Hijack Truck Reward
                      <span class="optional" style="color: var(--text-dim); font-weight: 400;">— Instant bonus granted to the player who completes the lockpick/hijack minigame</span>
                    </label>
                    <RewardListEditor bind:rewards={truck.hijackReward} disabled={locked} />
                  </div>

                  <div class="truck-edit-actions" style="margin-top: 16px;">
                    {#if !locked}
                      <button class="btn btn-danger" type="button" on:click={() => removeTruck(truck.id)}>
                        <Icon name="trash" size={13} /> Remove Truck
                      </button>
                    {/if}
                    <button class="btn btn-primary" type="button" on:click={() => (editingTruckId = null)}>Done</button>
                  </div>
                </div>
              </td>
            </tr>
          {/if}
        {/each}
      </tbody>
    </table>
  {/if}
{/if}

{#if section === 'zones' || section === 'drops'}
  <SavedTemplatePicker
    kind="HOT_CARGO"
    payload={{ trucks: hotCargo.trucks, spawnZones: hotCargo.spawnZones, dropoffZones: hotCargo.dropoffZones }}
    {locked}
    on:import={applyImportedTemplate}
  />

  {#if !locked}
    <button class="btn btn-steel record-zones-btn" disabled={zoneRecording} on:click={beginZoneRecording} title="Walk to each spot — [E] drops a spawn zone, [K] drops a dropoff zone, [Enter] finishes and returns you here">
      <Icon name="pin" size={13} /> {zoneRecording ? 'Recording... (tablet minimized)' : 'Add Zones (Walk & Drop)'}
    </button>
  {/if}

  <!-- Interactive Atlas Map Preview (Moved to Top) -->
  <div class="map-preview">
    <div class="map-preview-title">
      <Icon name="activity" size={13} /> Operation Tactical Map
      <span class="map-preview-sub">— magenta = vehicle spawn locations, green = dropoff zones</span>
    </div>
    {#if pickingTarget}
      <div class="map-picking-banner">
        <Icon name="pin" size={13} />
        <span>Click anywhere on the map to set coordinates for <strong>{pickingTarget.name}</strong></span>
        <button class="btn btn-sm" on:click={() => (pickingTarget = null)}>Cancel</button>
      </div>
    {/if}
    {#if (hotCargo.spawnZones || []).some((z) => z.x != null) || (hotCargo.dropoffZones || []).some((d) => d.x != null) || pickingTarget}
      <RoutePreviewMap
        {hotCargo}
        eventKind="HOT_CARGO"
        legend={false}
        height={360}
        interactive={pickingTarget !== null}
        editable={!locked}
        bind:selectedPointId
        on:selectPoint={handleMapZoneSelect}
        on:mapClick={handleMapClick}
        on:pointDrag={(e) => liveMove(e.detail)}
        on:pointMove={(e) => { liveMove.cancel(); hotCargo = moveInHotCargo(hotCargo, e.detail, applyMove); }}
      />
      <div class="map-legend">
        <span class="legend-item"><span class="legend-dot" style="background:#e0489f"></span>Contraband Vehicle Spawn Zone</span>
        <span class="legend-item"><span class="legend-dot" style="background:#70b982"></span>Delivery Dropoff Zone</span>
        {#if pickingTarget}
          <span class="legend-item" style="color:var(--accent-primary); font-weight:600;">🎯 Interactive Map Mode Active — Click map to place pointer</span>
        {/if}
      </div>
    {:else}
      <div class="map-empty">Add at least one spawn zone or dropoff point to view tactical placement on the map.</div>
    {/if}
  </div>

  <!-- 1. Spawn Zones Section -->
  <div class="section-card">
    <div class="header-row">
      <div class="section-title">
        <Icon name="activity" size={14} /> Spawn Zones <span class="optional">— candidate truck spawn locations</span>
        <span class="count">({(hotCargo.spawnZones || []).length} configured)</span>
      </div>
      <div class="header-actions">
        {#if !locked}
          <div class="add-point-row">
            <button type="button" class="btn btn-steel" on:click={addZone} title="Add a blank spawn zone">
              <Icon name="waypointPlus" size={13} /> Add Manually
            </button>
            <button type="button" class="btn btn-steel" on:click={addSpawnHere} title="Add a spawn zone at your current location and heading">
              <Icon name="pin" size={13} /> Add Pin Here
            </button>
            <button type="button" class="btn btn-steel" disabled={zoneRecording} on:click={beginZoneRecording} title="Walk to each spot — [E] drops a spawn zone, [K] drops a dropoff zone, [Enter] finishes and returns you here">
              <Icon name="pin" size={13} /> {zoneRecording ? 'Recording...' : 'Add Zones (Walk & Drop)'}
            </button>
            <button type="button" class="btn btn-danger" disabled={(hotCargo.spawnZones || []).length === 0} on:click={removeAllSpawnZones} title="Delete every spawn zone">
              <Icon name="routeClear" size={13} /> Delete All
            </button>
          </div>
        {/if}
      </div>
    </div>
    <p class="field-hint">
      Stand where you want each zone and press <strong>Set Position</strong> or <strong>Add Pin Here</strong> — unplaced zones are never used.
    </p>

    {#if !locked && (hotCargo.spawnZones || []).length > 0}
      <div class="select-bar">
        <label class="select-all" title="Tick the box on any zone card to pick which ones to delete">
          <input type="checkbox" checked={checkedSpawnCount === (hotCargo.spawnZones || []).length} indeterminate={checkedSpawnCount > 0 && checkedSpawnCount < (hotCargo.spawnZones || []).length} on:change={toggleAllSpawnChecked} />
          <span>{checkedSpawnCount > 0 ? `${checkedSpawnCount} selected` : 'Select spawn zones to delete'}</span>
        </label>
        {#if checkedSpawnCount > 0}
          <button type="button" class="btn btn-steel" on:click={() => (checkedSpawnIds = [])}>Clear</button>
          <button type="button" class="btn btn-danger" on:click={removeCheckedSpawnZones}><Icon name="trash" size={13} /> Delete Selected ({checkedSpawnCount})</button>
        {/if}
      </div>
    {/if}

    {#if (hotCargo.spawnZones || []).length === 0}
      <div class="empty">No spawn zones configured. Add at least one spawn point.</div>
    {:else}
      <div class="spawn-list point-list">
        {#each hotCargo.spawnZones || [] as zone, i (zone.id)}
          <div class="point-card zone-card spawn-row" data-id={zone.id} class:placed={zone.x != null} class:selected={zone.id === selectedPointId} style="--point-accent:#e0489f" on:click={() => (selectedPointId = zone.id)}>
            <div class="point-top">
              <div class="point-left">
                {#if !locked}
                  <input
                    type="checkbox"
                    class="point-check"
                    title="Select this spawn zone for bulk delete"
                    checked={checkedSpawnIds.includes(zone.id)}
                    on:click|stopPropagation
                    on:change={() => toggleSpawnChecked(zone.id)}
                  />
                {/if}

                <!-- Number badge -->
                <span class="point-order-btn" title="Spawn zone #{i + 1}">
                  <span class="order-hash">#</span><span class="order-num">{i + 1}</span>
                </span>

                <!-- Type badge pill -->
                <div class="type-badge-pill" style="border-left-color: #e0489f">
                  <Icon name="truck" size={14} />
                  <span class="type-pill-label">SPAWN ZONE</span>
                </div>

                <!-- Zone Name Input & Area Tag -->
                <div class="point-info-group">
                  <input
                    type="text"
                    class="stage-name-input-modern"
                    bind:value={zone.name}
                    placeholder="Zone Name"
                    disabled={locked}
                    maxlength="100"
                  />
                </div>
                {#if locationNames[zone.id]}
                  <span class="point-zone-pill"><Icon name="pin" size={11} /> {locationNames[zone.id]}</span>
                {/if}

                <!-- Coordinates preview pill -->
                <div class="point-coords-preview mono" title="Coordinates: X={fmt(zone.x)}, Y={fmt(zone.y)}, Z={fmt(zone.z)}, H={fmt(zone.heading)}°">
                  <span
                    class="placed-dot"
                    class:placed={zone.x != null}
                    title={zone.x != null ? 'Position set' : 'Position not set'}
                  ></span>
                  <span>{fmt(zone.x)}, {fmt(zone.y)}</span>
                </div>
              </div>

              <div class="point-actions">
                {#if zone.x != null && $bootstrap?.isAdmin}
                  <button class="icon-btn info icon-btn-text" title="Teleport to this zone" on:click={() => teleportTo(zone.x, zone.y, zone.z, zone.heading)}>
                    <Icon name="teleport" size={13} /> Teleport
                  </button>
                {/if}
                {#if !locked}
                  <button class="icon-btn success icon-btn-text" title="Set this zone's position to my current position and heading" on:click={() => pinSpawnToMyPos(zone.id)}>
                    <Icon name="pin" size={13} /> Set Position
                  </button>
                  <button
                    type="button"
                    class="icon-btn icon-btn-text"
                    class:active-pick={pickingTarget && pickingTarget.id === zone.id && pickingTarget.type === 'spawn'}
                    on:click={() => startPicking('spawn', zone.id, zone.name)}
                    title="Click on the map to set coords"
                  >
                    <Icon name="crosshair" size={13} /> Pick on Map
                  </button>
                  <button class="icon-btn btn-move icon-btn-text" disabled={locked || i === 0} on:click={() => moveSpawnZone(i, -1)} title="Move Up">
                    <Icon name="chevronUp" size={14} /> Up
                  </button>
                  <button class="icon-btn btn-move icon-btn-text" disabled={locked || i === (hotCargo.spawnZones || []).length - 1} on:click={() => moveSpawnZone(i, 1)} title="Move Down">
                    <Icon name="chevronDown" size={14} /> Down
                  </button>
                  <button class="icon-btn danger icon-btn-text" disabled={locked} on:click={() => removeSpawnZone(zone.id)} title="Remove this spawn zone">
                    <Icon name="trash" size={14} /> Delete
                  </button>
                {/if}
              </div>
            </div>

            <!-- 4-Column Vector Fields (X, Y, Z, Heading) -->
            <fieldset class="point-fieldset" disabled={locked}>
              <div class="point-coords">
                <div class="coord-field">
                  <label>X</label>
                  <input type="number" step="0.01" bind:value={zone.x} />
                </div>
                <div class="coord-field">
                  <label>Y</label>
                  <input type="number" step="0.01" bind:value={zone.y} />
                </div>
                <div class="coord-field">
                  <label>Z</label>
                  <input type="number" step="0.01" bind:value={zone.z} />
                </div>
                <div class="coord-field">
                  <label>Heading</label>
                  <input type="number" step="0.1" bind:value={zone.heading} />
                </div>
              </div>
            </fieldset>

            <!-- Truck Spawn Position Section -->
            <div class="sub-section">
              <div class="spawn-title-row">
                <div class="inline-title spawn-title">
                  <span><Icon name="pin" size={13} /> Truck Spawn Position</span>
                  <span class="spawn-count">{zone.truckX != null ? '1 / 1 placed' : '0 / 1 placed'}</span>
                </div>
                <div class="spawn-actions">
                  {#if !locked}
                    <button class="icon-btn success icon-btn-text" title="Set the truck's exact spawn spot to my current position and heading" on:click={() => pinTruckSpawnToMyPos(zone.id)}>
                      <Icon name="pin" size={13} /> {zone.truckX != null ? 'Re-set' : 'Set Position'}
                    </button>
                    <button class="icon-btn info icon-btn-text" title="Walk the truck+trailer into place with a live in-world preview" on:click={() => enterTruckPlacer(zone.id)}>
                      <Icon name="truck" size={13} /> Placement Mode
                    </button>
                  {/if}
                  {#if zone.truckX != null && $bootstrap?.isAdmin}
                    <button class="icon-btn info icon-btn-text" title="Teleport to the truck spawn spot" on:click={() => teleportTo(zone.truckX, zone.truckY, zone.truckZ, zone.truckHeading)}>
                      <Icon name="teleport" size={13} /> Teleport
                    </button>
                  {/if}
                  {#if !locked}
                    <button
                      type="button"
                      class="icon-btn icon-btn-text"
                      class:active-pick={pickingTarget && pickingTarget.id === zone.id && pickingTarget.type === 'truckSpawn'}
                      on:click={() => startPicking('truckSpawn', zone.id, zone.name)}
                      title="Click on the map to set the truck's exact spawn spot"
                    >
                      <Icon name="crosshair" size={13} /> Pick on Map
                    </button>
                    {#if zone.truckX != null}
                      <button class="icon-btn danger icon-btn-text" title="Clear (falls back to the zone's own position)" on:click={() => clearTruckSpawnVector(zone.id)}>
                        <Icon name="trash" size={13} /> Clear
                      </button>
                    {/if}
                  {/if}
                </div>
              </div>

              <!-- 4-Column Vector Fields for Truck Spawn -->
              <fieldset class="point-fieldset" disabled={locked}>
                <div class="point-coords" style="margin-top: 10px;">
                  <div class="coord-field">
                    <label>Truck X</label>
                    <input type="number" step="0.01" bind:value={zone.truckX} />
                  </div>
                  <div class="coord-field">
                    <label>Truck Y</label>
                    <input type="number" step="0.01" bind:value={zone.truckY} />
                  </div>
                  <div class="coord-field">
                    <label>Truck Z</label>
                    <input type="number" step="0.01" bind:value={zone.truckZ} />
                  </div>
                  <div class="coord-field">
                    <label>Truck Heading</label>
                    <input type="number" step="0.1" bind:value={zone.truckHeading} />
                  </div>
                </div>
              </fieldset>
            </div>

            <!-- Guards defending whichever truck lands on this zone -->
            <div class="sub-section">
              <div class="inline-subtitle">Guards &amp; Security</div>
              <p class="hint">Hostile-to-EVERYONE thugs spawn to guard whichever truck lands in this zone.</p>
              <div class="field-row">
                <div class="field">
                  <label>Guard Count <span class="optional">0 = unguarded</span></label>
                  <input type="number" min="0" max="10" bind:value={zone.guardCount} disabled={locked} />
                </div>
                <div class="field">
                  <label>Shooting Aggressiveness</label>
                  <select bind:value={zone.guardAggressiveness} disabled={locked || !zone.guardCount}>
                    {#each AGGRESSIVENESS_OPTIONS as a}
                      <option value={a.value}>{a.label}</option>
                    {/each}
                  </select>
                </div>
              </div>
              <div class="field-row">
                <div class="field">
                  <label>Guard Ped Model</label>
                  <select bind:value={zone.guardModel} disabled={locked || !zone.guardCount}>
                    {#each GUARD_MODELS as m}
                      <option value={m.value}>{m.label}</option>
                    {/each}
                  </select>
                </div>
                <div class="field">
                  <label>Guard Weapon</label>
                  <select bind:value={zone.guardWeapon} disabled={locked || !zone.guardCount}>
                    {#each GUARD_WEAPONS as w}
                      <option value={w.value}>{w.label}</option>
                    {/each}
                  </select>
                </div>
              </div>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- 2. Delivery Dropoff Destinations -->
  <div class="section-card">
    <div class="header-row">
      <div class="section-title">
        <Icon name="flag" size={14} /> Delivery Dropoff Destinations
        <span class="count">({(hotCargo.dropoffZones || []).length} configured)</span>
      </div>
      <div class="header-actions">
        {#if !locked}
          <div class="add-point-row">
            <button type="button" class="btn btn-steel" on:click={addDropoffManual} title="Add a blank dropoff destination">
              <Icon name="waypointPlus" size={13} /> Add Manually
            </button>
            <button type="button" class="btn btn-steel" on:click={addDropoffHere} title="Set a dropoff destination at your current location and heading">
              <Icon name="pin" size={13} /> Add Pin Here
            </button>
            <button type="button" class="btn btn-danger" disabled={(hotCargo.dropoffZones || []).length === 0} on:click={removeAllDropoffZones} title="Delete every dropoff destination">
              <Icon name="routeClear" size={13} /> Delete All
            </button>
          </div>
        {/if}
      </div>
    </div>

    {#if !locked && (hotCargo.dropoffZones || []).length > 0}
      <div class="select-bar">
        <label class="select-all" title="Tick the box on any dropoff card to pick which ones to delete">
          <input type="checkbox" checked={checkedDropoffCount === (hotCargo.dropoffZones || []).length} indeterminate={checkedDropoffCount > 0 && checkedDropoffCount < (hotCargo.dropoffZones || []).length} on:change={toggleAllDropoffChecked} />
          <span>{checkedDropoffCount > 0 ? `${checkedDropoffCount} selected` : 'Select dropoffs to delete'}</span>
        </label>
        {#if checkedDropoffCount > 0}
          <button type="button" class="btn btn-steel" on:click={() => (checkedDropoffIds = [])}>Clear</button>
          <button type="button" class="btn btn-danger" on:click={removeCheckedDropoffZones}><Icon name="trash" size={13} /> Delete Selected ({checkedDropoffCount})</button>
        {/if}
      </div>
    {/if}

    {#if (hotCargo.dropoffZones || []).length === 0}
      <div class="empty">No dropoff destinations configured. Add at least one dropoff location.</div>
    {:else}
      <div class="point-list">
        {#each hotCargo.dropoffZones || [] as dropoff, i (dropoff.id)}
          <div class="point-card zone-card dropoff-card" data-id={dropoff.id} class:selected={dropoff.id === selectedPointId} style="--point-accent:#70b982" on:click={() => (selectedPointId = dropoff.id)}>
            <div class="point-top">
              <div class="point-left">
                {#if !locked}
                  <input
                    type="checkbox"
                    class="point-check"
                    title="Select this dropoff for bulk delete"
                    checked={checkedDropoffIds.includes(dropoff.id)}
                    on:click|stopPropagation
                    on:change={() => toggleDropoffChecked(dropoff.id)}
                  />
                {/if}

                <!-- Number badge -->
                <span class="point-order-btn" title="Dropoff #{i + 1}">
                  <span class="order-hash">#</span><span class="order-num">{i + 1}</span>
                </span>

                <!-- Type badge pill -->
                <div class="type-badge-pill" style="border-left-color: #70b982">
                  <Icon name="destination" size={14} />
                  <span class="type-pill-label">DROPOFF</span>
                </div>

                <!-- Dropoff Name Input & Area Tag -->
                <div class="point-info-group">
                  <input
                    type="text"
                    class="stage-name-input-modern"
                    bind:value={dropoff.name}
                    placeholder="Dropoff Name"
                    disabled={locked}
                    maxlength="100"
                  />
                </div>
                {#if locationNames[dropoff.id]}
                  <span class="point-zone-pill"><Icon name="pin" size={11} /> {locationNames[dropoff.id]}</span>
                {/if}

                <!-- Coordinates preview pill -->
                <div class="point-coords-preview mono" title="Coordinates: X={fmt(dropoff.x)}, Y={fmt(dropoff.y)}, Z={fmt(dropoff.z)}">
                  <span
                    class="placed-dot"
                    class:placed={dropoff.x != null}
                    title={dropoff.x != null ? 'Position set' : 'Position not set'}
                  ></span>
                  <span>{fmt(dropoff.x)}, {fmt(dropoff.y)}</span>
                </div>
              </div>

              <div class="point-actions">
                {#if dropoff.x != null && $bootstrap?.isAdmin}
                  <button class="icon-btn info icon-btn-text" on:click={() => teleportTo(dropoff.x, dropoff.y, dropoff.z, 0)} title="Teleport to dropoff point">
                    <Icon name="teleport" size={13} /> Teleport
                  </button>
                {/if}
                {#if !locked}
                  <button class="icon-btn success icon-btn-text" on:click={() => pinDropoffToMyPos(dropoff.id)} title="Update to your current coords">
                    <Icon name="pin" size={13} /> Set Position
                  </button>
                  <button
                    type="button"
                    class="icon-btn icon-btn-text"
                    class:active-pick={pickingTarget && pickingTarget.id === dropoff.id && pickingTarget.type === 'dropoff'}
                    on:click={() => startPicking('dropoff', dropoff.id, dropoff.name)}
                    title="Click on the Leaflet map to set coords"
                  >
                    <Icon name="crosshair" size={13} /> Pick on Map
                  </button>
                  <button class="icon-btn btn-move icon-btn-text" disabled={locked || i === 0} on:click={() => moveDropoffZone(i, -1)} title="Move Up">
                    <Icon name="chevronUp" size={14} /> Up
                  </button>
                  <button class="icon-btn btn-move icon-btn-text" disabled={locked || i === (hotCargo.dropoffZones || []).length - 1} on:click={() => moveDropoffZone(i, 1)} title="Move Down">
                    <Icon name="chevronDown" size={14} /> Down
                  </button>
                  <button class="icon-btn danger icon-btn-text" on:click={() => removeDropoffZone(dropoff.id)} title="Remove this dropoff">
                    <Icon name="trash" size={14} /> Delete
                  </button>
                {/if}
              </div>
            </div>

            <!-- 4-Column Vector Fields -->
            <fieldset class="point-fieldset" disabled={locked}>
              <div class="point-coords">
                <div class="coord-field">
                  <label>X</label>
                  <input type="number" step="0.01" bind:value={dropoff.x} />
                </div>
                <div class="coord-field">
                  <label>Y</label>
                  <input type="number" step="0.01" bind:value={dropoff.y} />
                </div>
                <div class="coord-field">
                  <label>Z</label>
                  <input type="number" step="0.01" bind:value={dropoff.z} />
                </div>
                <div class="coord-field">
                  <label>Delivery Radius (m)</label>
                  <input type="number" min="5" max="100" bind:value={dropoff.radius} />
                </div>
              </div>
            </fieldset>

            <!-- Guards & Security -->
            <div class="sub-section">
              <div class="inline-subtitle">Guards &amp; Security</div>
              <p class="hint">Hostile-to-EVERYONE thugs spawn to defend the delivered truck at this dropoff.</p>
              <div class="field-row">
                <div class="field">
                  <label>Guard Count <span class="optional">0 = unguarded</span></label>
                  <input type="number" min="0" max="10" bind:value={dropoff.guardCount} disabled={locked} />
                </div>
                <div class="field">
                  <label>Shooting Aggressiveness</label>
                  <select bind:value={dropoff.guardAggressiveness} disabled={locked || !dropoff.guardCount}>
                    {#each AGGRESSIVENESS_OPTIONS as a}
                      <option value={a.value}>{a.label}</option>
                    {/each}
                  </select>
                </div>
              </div>
              <div class="field-row">
                <div class="field">
                  <label>Guard Ped Model</label>
                  <select bind:value={dropoff.guardModel} disabled={locked || !dropoff.guardCount}>
                    {#each GUARD_MODELS as m}
                      <option value={m.value}>{m.label}</option>
                    {/each}
                  </select>
                </div>
                <div class="field">
                  <label>Guard Weapon</label>
                  <select bind:value={dropoff.guardWeapon} disabled={locked || !dropoff.guardCount}>
                    {#each GUARD_WEAPONS as w}
                      <option value={w.value}>{w.label}</option>
                    {/each}
                  </select>
                </div>
              </div>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- Disabled Truck / Salvage Reward now lives in CreateConvoy's General
       tab, next to the main event Reward field. -->

  <!-- 4. Security & Anti-Griefing Sentry Info -->
  <div class="sentry-info-card">
    <div class="sentry-head">
      <Icon name="shield" size={15} />
      <span>60-Minute Post-Event Anti-Griefing Sentry</span>
    </div>
    <p class="sentry-text">
      Server rules strictly prohibit griefing or camping the delivering gang after the dropoff. The server automatically runs an authoritative 60-minute post-event watchdog that records any attacks, kills, or attempts to steal the delivered reward crate, dispatching instant high-priority alerts with player identifiers directly to your Discord webhook.
    </p>
  </div>
{/if}
</div>

<style>
  .hot-cargo-config {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .mode-toggle-row {
    display: flex;
    gap: 8px;
    margin-top: 10px;
  }
  .mode-toggle-row .chip-btn {
    flex: 1;
    text-align: center;
    padding: 8px 12px;
  }
  .mode-hint {
    margin: 10px 0 0;
    padding: 10px 12px;
    font-size: var(--fs-small);
    color: var(--text-dim);
    background: var(--tablet-panel);
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
  }

  .banner-card {
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    border-radius: var(--radius-sm);
    padding: 14px 16px;
  }
  .banner-head {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--lt-ffffff, #ffffff);
    font-weight: 700;
    font-size: var(--fs-body);
    margin-bottom: 6px;
  }
  .banner-text {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 0;
  }
  .banner-text strong {
    color: var(--text-main);
  }

  .section-card {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 14px 16px;
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
  .section-title { margin-bottom: 10px; }
  .count {
    color: var(--text-dim);
    font-weight: 500;
    font-size: var(--fs-small);
  }

  .header-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 4px;
  }
  .header-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .truck-picker-bar { display: flex; gap: 8px; margin-bottom: 4px; }
  .truck-search { flex: 1; }
  .truck-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 10px; margin-top: 10px; max-height: 300px; overflow-y: auto; padding: 2px; }
  .truck-card { position: relative; display: flex; flex-direction: column; align-items: flex-start; gap: 3px; padding: 12px 14px; text-align: left; border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1); border-radius: var(--r-panel); background: rgba(var(--ink-rgb, 255, 255, 255), 0.03); color: var(--lt-ffffff, #fff); cursor: pointer; transition: border-color 0.15s, background 0.15s; }
  .truck-card:hover:not(:disabled) { border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.3); background: rgba(var(--ink-rgb, 255, 255, 255), 0.06); }
  .truck-card.active { border-color: var(--accent-primary); background: var(--c-hover); }
  .truck-card:disabled { cursor: default; opacity: 0.7; }
  .truck-name { font-size: var(--fs-body); font-weight: 700; }
  .truck-code { font-family: var(--font-mono); font-size: var(--fs-small); color: var(--lt-aeb5bd, #aeb5bd); }
  .truck-note { font-size: var(--fs-small); color: var(--lt-c9ced4, #c9ced4); }
  .truck-tag { position: absolute; top: 8px; right: 8px; padding: 2px 6px; border-radius: var(--r-tag); background: rgba(var(--ink-rgb, 255, 255, 255), 0.12); font-size: var(--fs-meta); font-weight: 600; }
  .truck-empty { grid-column: 1 / -1; padding: 16px; text-align: center; font-size: var(--fs-body); color: var(--lt-aeb5bd, #aeb5bd); }
  .chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 8px;
  }
  .chip-btn {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    padding: 4px 10px;
    border-radius: 999px;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
  }
  .chip-btn:hover:not(:disabled) {
    border-color: var(--accent-primary);
    color: var(--accent-primary);
  }
  .chip-btn.active {
    background: var(--c-action);
    border-color: var(--accent-primary);
    color: var(--on-accent);
    font-weight: 600;
  }

  .zones-grid {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 12px;
  }
  .zone-card {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 12px;
    transition: border-color 0.15s ease;
  }
  .zone-card:hover {
    border-color: var(--tablet-border-strong);
  }
  .dropoff-card {
    border-left: 3px solid #70b982;
  }

  .zone-head {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
  }
  .zone-label {
    flex: 1;
    font-size: var(--fs-body);
    font-weight: 600;
    color: var(--text-main);
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    padding: 3px 6px;
  }
  .zone-label:focus {
    border-color: var(--accent-primary);
    background: var(--tablet-bg);
  }
  .zone-coords {
    font-size: var(--fs-small);
    color: var(--text-dim);
    font-family: var(--font-mono);
  }
  .zone-actions {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .coord-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(110px, 1fr));
    gap: 8px;
  }
  .coord-field label {
    display: block;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    margin-bottom: 2px;
    font-weight: 600;
  }
  .coord-field input {
    width: 100%;
    font-size: var(--fs-small);
    font-family: var(--font-mono);
    padding: 5px 8px;
  }

  .map-preview {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 12px;
  }
  .map-preview-title {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
    margin: -12px -12px 12px;
    padding: 9px 12px;
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
    font-size: var(--fs-small);
    font-weight: 400;
    color: var(--text-dim);
  }
  .map-empty {
    padding: 32px;
    text-align: center;
    color: var(--text-dim);
    font-size: var(--fs-small);
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
  }
  .map-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--tablet-border);
  }
  .legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .legend-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .sentry-info-card {
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    border-radius: var(--radius-sm);
    padding: 12px 14px;
  }
  .sentry-head {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-small);
    font-weight: 700;
    margin-bottom: 4px;
  }
  .sentry-text {
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin: 0;
    line-height: 1.45;
  }

  .empty {
    text-align: center;
    padding: 24px;
    color: var(--text-dim);
    font-size: var(--fs-small);
    border: 1px dashed var(--tablet-border);
    border-radius: var(--radius-sm);
    margin-top: 8px;
  }

  .btn-active {
    background: var(--accent-primary) !important;
    border-color: var(--accent-primary) !important;
    color: var(--on-accent, #ffffff) !important;
    font-weight: 700;
  }

  .map-picking-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    background: var(--c-hover);
    border: 1px solid var(--accent-primary);
    border-radius: var(--radius-sm);
    padding: 8px 12px;
    margin-bottom: 8px;
    font-size: var(--fs-small);
    color: var(--accent-primary);
  }
  .map-picking-banner strong {
    color: var(--lt-ffffff, #ffffff);
  }

  .guard-settings-section {
    margin-top: 12px;
    padding-top: 12px;
    border-top: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.07);
  }
  .guard-head {
    display: flex;
    align-items: center;
    gap: 6px;
    color: #d9736f;
    font-size: var(--fs-small);
    font-weight: 700;
    margin-bottom: 8px;
  }
  .guard-title {
    letter-spacing: 0.01em;
    font-size: var(--fs-small);
  }
  .guard-fields-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 8px;
    align-items: start;
  }
  .guard-field label {
    display: block;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    margin-bottom: 2px;
    font-weight: 600;
  }
  .guard-field input,
  .guard-field select {
    width: 100%;
    font-size: var(--fs-small);
    padding: 5px 8px;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--r-ctl);
    color: var(--text-main);
  }
  .guard-checkbox-field {
    grid-column: 1 / -1;
    margin-top: 4px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    padding: 8px 10px;
    border-left: 3px solid rgb(217, 115, 111);}
  .checkbox-container {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--lt-ff8a80, #ff8a80);
    cursor: pointer;
  }
  .checkbox-container input[type="checkbox"] {
    accent-color: #d9736f;
    cursor: pointer;
  }

  /* Coordinate ("vector") text: larger + bold so it reads at a glance. */
  .coord-field label { font-size: var(--fs-small); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-c9ced4, #c9ced4); }
  .coord-field input { font-size: var(--fs-body); font-weight: 700; letter-spacing: 0.01em; }
  .zone-coords { font-size: var(--fs-body); font-weight: 700; color: var(--lt-eceef0, #eceef0); }
  .zone-coords { font-family: var(--font-ui); font-variant-numeric: tabular-nums; }
  .coord-field input { font-family: var(--font-ui); font-variant-numeric: tabular-nums; }

  /* Dropoff hostile-guard settings: roomy, aligned, readable. */
  .guard-settings-section { margin-top: 16px; padding-top: 16px; border-top: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08); }
  .guard-head { gap: 8px; margin-bottom: 14px; font-size: var(--fs-body); }
  .guard-master { margin-left: auto; min-width: 84px; }
  .guard-title { font-size: var(--fs-small); letter-spacing: 0.01em; }
  .guard-fields-grid { grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px 16px; align-items: end; }
  .guard-field { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
  .guard-field label { display: flex; flex-direction: column; gap: 2px; margin: 0; font-size: var(--fs-small); font-weight: 700; text-transform: none; letter-spacing: 0.01em; color: var(--lt-eceef0, #eceef0); }
  .guard-field label .optional { display: block; font-size: var(--fs-small); font-weight: 500; color: var(--lt-aeb5bd, #aeb5bd); text-transform: none; }
  .guard-field input, .guard-field select { height: 40px; min-height: 40px; padding: 0 12px; font-size: var(--fs-body); font-weight: 600; border-radius: var(--r-ctl); box-sizing: border-box; }
  .guard-checkbox-field { margin-top: 2px; padding: 14px 16px; background: rgba(var(--ink-rgb, 255, 255, 255), 0.03); border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1); border-left: 3px solid #d9736f; border-radius: var(--r-ctl); }
  .checkbox-container { gap: 10px; font-size: var(--fs-body); font-weight: 700; color: var(--lt-ffffff, #ffffff); }
  .checkbox-container input[type="checkbox"] { width: 16px; height: 16px; }
  /* Base hint-text style — same values as Convoy's RouteBuilder.svelte
     .field-hint, which this file never actually defined at the base level
     (only a scoped override existed), so the new "Stand where you want each
     zone..." hint was falling back to unstyled browser defaults. */
  .field-hint { font-size: var(--fs-small); color: var(--text-dim); line-height: 1.5; margin: 4px 0 8px; }
  /* Exact values from Convoy's RouteBuilder.svelte .inline-title/.spawn-title
     /.spawn-count — the "Truck Spawn Position" header (icon + bold orange
     title + placed counter on the right) now matches pixel-for-pixel. */
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
    border-radius: var(--r-tag);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .spawn-title { justify-content: space-between; }
  .spawn-title > span:first-child { display: inline-flex; align-items: center; gap: 7px; }
  .spawn-count { font-size: var(--fs-small); font-weight: 500; color: var(--text-dim); }
  /* Same values as AirdropZones.svelte's own .inline-subtitle/.hint — the
     Guards & Security section in Spawn Zones/Dropoff Destinations now
     matches the Gang Airdrop builder's guard UI exactly. */
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
  .hint { font-size: var(--fs-small); color: var(--text-dim); line-height: 1.5; margin: 0 0 8px; }
  .hint strong { color: var(--text-main); }
  .guard-checkbox-field .field-hint { margin: 6px 0 0 26px !important; font-size: var(--fs-small); line-height: 1.5; color: var(--lt-aeb5bd, #aeb5bd); }

  /* ── Card look shared with the Convoy route builder ─────────────────────── */
  .zones-grid { gap: 14px; }
  .zone-card { padding: 18px 20px; border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1); border-left: 3px solid var(--accent-primary); border-radius: var(--radius-md); background: var(--doctrine-card-bg, var(--tablet-panel)); }
  .zone-card.dropoff-card { border-left-color: #70b982; }
  .zone-head { justify-content: space-between; gap: 12px; margin-bottom: 14px; }
  .zone-title-group { display: flex; align-items: center; gap: 12px; min-width: 0; flex: 1; }
  .point-order { width: 26px; height: 26px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; background: var(--tablet-bg); border: 1px solid var(--tablet-border); border-radius: var(--radius-sm); font-size: var(--fs-small); font-weight: 700; color: var(--text-dim); }
  .placed-dot { flex-shrink: 0; width: 8px; height: 8px; border-radius: 50%; background: var(--tablet-danger, #d9736f); }
  .placed-dot.placed { background: var(--green, #70b982); }
  .zone-label { flex: 0 1 260px; min-width: 140px; padding: 8px 10px; font-size: var(--fs-body); font-weight: 700; background: var(--tablet-bg); border: 1px solid var(--tablet-border); border-radius: var(--radius-sm); color: var(--text-main); }
  .zone-label:focus { outline: none; border-color: var(--accent-primary); }
  .zone-area-tag { display: inline-flex; align-items: center; gap: 5px; font-size: var(--fs-meta); font-weight: 600; color: var(--text-dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .zone-actions { display: flex; gap: 6px; flex-shrink: 0; }

  /* ── Spawn Zones: same compact row pattern as Convoy's Truck Spawn
     Positions panel (RouteBuilder.svelte) — a single "Set to My Position"
     driven row instead of always-editable X/Y/Z/Heading number fields. ── */
  .spawn-list { display: flex; flex-direction: column; gap: 18px; margin-top: 14px; }
  .spawn-row { padding: 18px 20px; border: 1px solid var(--tablet-border); border-radius: var(--radius-md); background: var(--tablet-panel-alt); transition: border-color 0.15s ease; }
  .spawn-row.placed { border-left: 3px solid var(--accent-primary); }
  .zone-card.selected { border-color: var(--point-accent, var(--accent-primary)); box-shadow: 0 0 0 1.5px var(--point-accent, var(--accent-primary)), 0 4px 18px rgba(0, 0, 0, 0.35); }
  .spawn-row-top { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
  .spawn-index { width: 22px; height: 22px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; background: var(--tablet-bg); border: 1px solid var(--tablet-border); border-radius: 50%; font-size: var(--fs-small); font-weight: 600; color: var(--text-main); }
  .spawn-info { flex: 1; min-width: 220px; }
  .spawn-name-row { display: flex; align-items: center; gap: 10px; }
  /* Ghost input — looks like Convoy's plain-text truck name until you
     actually click into it, since (unlike Convoy trucks, renamed in their
     own Trucks tab) a zone's name has nowhere else to be edited. */
  .spawn-name-input { flex: 0 1 auto; min-width: 80px; padding: 2px 4px; font-size: var(--fs-body); font-weight: 700; background: transparent; border: 1px solid transparent; border-radius: var(--radius-sm); color: var(--text-main); }
  .spawn-name-input:hover:not(:disabled) { background: var(--tablet-bg); }
  .spawn-name-input:focus { outline: none; background: var(--tablet-bg); border-color: var(--accent-primary); }
  /* Bold/bright, same override Convoy's RouteBuilder.svelte applies to its
     own .spawn-coords ("Coordinate text: larger + bold so it reads at a
     glance") — matches the big X/Y/Z/Heading vector boxes above it. */
  .spawn-coords { font-size: var(--fs-body); font-weight: 700; font-family: var(--font-ui); font-variant-numeric: tabular-nums; color: var(--lt-eceef0, #eceef0); margin-top: 8px; }
  .spawn-actions { display: flex; gap: 6px; flex-shrink: 0; flex-wrap: wrap; }
  /* Exact values from Convoy's RouteBuilder.svelte .icon-btn-mini — was
     bigger/bordered here before, which didn't match Convoy's genuinely
     minimal Teleport-button size. */
  .spawn-row .guard-settings-section { margin-top: 18px; padding-top: 18px; border-top: 1px dashed var(--tablet-border); }
  /* Sub-section divider inside a spawn row (Truck Spawn Location, Guards &
     Security) — same idea as Convoy's own .sub-block: a plain top border,
     not another nested card, so stacking several doesn't read as "boxes
     inside boxes inside boxes". */
  .sub-section { margin-top: 18px; padding-top: 18px; border-top: 1px dashed var(--tablet-border); }
  .sub-row { display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
  .sub-coords { margin-top: 0; flex: 1; min-width: 200px; }
  .coord-row { grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
  .coord-field { display: flex; flex-direction: column; gap: 5px; }
  .coord-field input { padding: 8px 9px; border-radius: var(--radius-sm); background: var(--input-bg, #131518); border: 1px solid var(--input-border, #30353c); color: var(--text-main); }
  .coord-field input:focus { outline: none; border-color: var(--accent-primary); background: var(--input-bg-focus, #181b1f); }

  /* Vehicle picker: small individual pills (full name, model code in the tooltip). */
  .truck-chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  .truck-chip { padding: 6px 14px; border: 1px solid var(--tablet-border, rgba(255,255,255,0.12)); border-radius: 999px; background: var(--tablet-panel, #111316); color: var(--lt-c9ced4, #c9ced4); font-size: var(--fs-meta); font-weight: 600; white-space: nowrap; cursor: pointer; transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease; }
  .truck-chip:hover:not(:disabled) { border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.35); color: var(--lt-ffffff, #ffffff); }
  .truck-chip.active { border-color: var(--accent-primary); background: var(--c-action); color: var(--on-accent); }
  .truck-chip:disabled { cursor: default; opacity: 0.7; }

  /* Brighter/bigger — this section's text (zone/guard headers, hint copy)
     was reading too small and dim next to the rest of the app. Matches
     Convoy's own RouteBuilder polish pass: orange section headers use
     --accent-primary-light, the same accent as everywhere
     else in the tablet. */
  .guard-head { color: var(--accent-primary-light); font-size: var(--fs-body); font-weight: 700; }
  .guard-title { font-size: var(--fs-body); letter-spacing: 0.01em; }
  .guard-field label { color: var(--lt-c9ced4, #c9ced4); font-size: var(--fs-small); }
  .guard-field label .optional { color: var(--lt-aeb5bd, #aeb5bd); font-size: var(--fs-small); }
  .guard-checkbox-field { border-left-color: var(--accent-primary); }
  .checkbox-container { color: var(--accent-primary-light); }
  .count { font-size: var(--fs-small); color: var(--lt-c9ced4, #c9ced4); }
  .mode-hint { font-size: var(--fs-body); color: var(--lt-c9ced4, #c9ced4); line-height: 1.5; }
  .mode-hint strong { color: var(--accent-primary-light); }
  .chip-btn { font-size: var(--fs-meta); }
  .banner-text { font-size: var(--fs-small); }

  /* ── Convoy RouteBuilder Modern Vector Layout & Controls ── */
  .add-point-row {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
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
  .point-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 14px;
    gap: 12px;
    flex-wrap: wrap;
  }
  .point-left {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
    flex-wrap: wrap;
  }
  .point-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
    flex-wrap: wrap;
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
  }
  .point-order-btn .order-hash {
    opacity: 0.6;
    font-size: var(--fs-meta);
  }

  .type-badge-pill {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 4px 8px;
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    border-left-width: 3px;
    border-radius: var(--radius-sm);
  }
  .type-pill-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--text-main);
  }

  .stage-name-input-modern {
    background: var(--input-bg, #131518);
    border: 1px solid var(--input-border, #30353c);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 6px 10px;
    font-size: var(--fs-small);
    font-weight: 600;
    min-width: 140px;
  }
  .stage-name-input-modern:focus {
    outline: none;
    border-color: var(--accent-primary);
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

  .point-fieldset {
    border: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 14px;
    min-width: 0;
  }
  .point-fieldset:disabled {
    opacity: 0.6;
  }

  .point-coords {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
  }
  @media (max-width: 900px) {
    .point-coords {
      grid-template-columns: repeat(2, 1fr);
    }
  }

  .coord-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }
  .coord-field label {
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-c9ced4, #c9ced4);
  }
  .coord-field input {
    background: var(--input-bg, #131518);
    border: 1px solid var(--input-border, #30353c);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 8px 9px;
    font-size: var(--fs-body);
    font-family: var(--font-mono, monospace);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
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

  .spawn-title-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
    margin-bottom: 8px;
  }
  .spawn-title-row .inline-title {
    margin-bottom: 0;
    flex: 1;
    min-width: 220px;
  }
</style>
