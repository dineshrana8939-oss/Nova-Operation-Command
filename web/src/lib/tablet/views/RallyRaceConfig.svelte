<script>
  import { onDestroy } from 'svelte';
  import {
    getPlayerPosition, getGroundZ,
    teleportToPosition,
    clearRoutePreview,
    startRouteRecording,
  } from '../../api/route.js';
  import { openPropPlacer, previewPlacedProps, clearPlacedPreview } from '../../api/placer.js';
  import { bootstrap, routeRecordingResult } from '../../stores.js';
  import { confirmAction } from '../ui/confirm.js';
  import { centroidOf } from '../ui/propData.js';
  import { TYPE_COLOR_JS } from '../../util/mapGeometry.js';
  import Icon from '../ui/Icon.svelte';
  import { revealLast } from '../ui/reveal.js';
  import { renumberAuto } from '../../util/autoName.js';
  import RoutePreviewMap from '../ui/RoutePreviewMap.svelte';
  import { applyLive, liveThrottle } from '../../util/mapMove.js';
  // the stage's vector follows the pin live while it is dragged (the final value is written on release by handleStageMove)
  const liveMove = liveThrottle((d) => { rallyStages = applyLive(rallyStages, d); });
  import SavedTemplatePicker from '../ui/SavedTemplatePicker.svelte';
  import PedRow from '../ui/PedRow.svelte';
  import '../tablet-theme.css';

  export let rallyStages = [];
  export let props = [];
  export let locked = false;
  export let settings = {};
  // 'vectors' = route stages / map / templates, 'peds' = every placeable ped
  // (race organizer via the `organizer` slot, vehicle ped, token vendor).
  // Both panes stay mounted so route recording survives switching.
  export let view = 'vectors';

  // A race is Start → Checkpoints → Finish. Every stage has an explicit type.
  const STAGE_TYPES = [
    { value: 'START', label: 'START' },
    { value: 'CHECKPOINT', label: 'CHECKPOINT' },
    { value: 'DESTINATION', label: 'FINISH' },
  ];

  // ── Race vehicles ── who supplies the cars: racers bring their own, or registered
  // racers take one of the allowed vehicles below from a vehicle ped before the start.
  const SUGGESTED_VEHICLES = [
    { model: 'sultan', label: 'Karin Sultan' },
    { model: 'sultanrs', label: 'Karin Sultan RS' },
    { model: 'elegy2', label: 'Annis Elegy RH8' },
    { model: 'jester', label: 'Dinka Jester' },
    { model: 'kuruma', label: 'Karin Kuruma' },
    { model: 'coquette', label: 'Invetero Coquette' },
    { model: 'comet2', label: 'Pfister Comet' },
    { model: 'dominator', label: 'Vapid Dominator' },
    { model: 'futo', label: 'Karin Futo' },
    { model: 'buffalo', label: 'Bravado Buffalo' },
    { model: 'banshee', label: 'Bravado Banshee' },
    { model: 'infernus', label: 'Pegassi Infernus' },
    { model: 'zentorno', label: 'Pegassi Zentorno' },
    { model: 'bati', label: 'Pegassi Bati 801 (bike)' },
    { model: 'sanchez', label: 'Maibatsu Sanchez (bike)' },
    { model: 'akuma', label: 'Dinka Akuma (bike)' },
    { model: 'bmx', label: 'BMX (bicycle)' },
  ];
  let pickedVehicle = 'sultan';
  let customVehicle = '';

  $: vehicleMode = (settings && settings.raceVehicleMode) || 'OWN';
  $: raceVehicles = (settings && settings.raceVehicles) || [];
  $: vehiclePed = settings && settings.raceVehiclePed;

  function setVehicleMode(mode) {
    settings.raceVehicleMode = mode;
    if (!Array.isArray(settings.raceVehicles)) settings.raceVehicles = [];
    settings = settings;
  }

  function addRaceVehicle() {
    const custom = customVehicle.trim().replace(/[^A-Za-z0-9_]/g, '');
    const model = custom || pickedVehicle;
    if (!model) return;
    const list = Array.isArray(settings.raceVehicles) ? [...settings.raceVehicles] : [];
    if (list.some((v) => v.model === model)) return;
    const suggested = SUGGESTED_VEHICLES.find((v) => v.model === model);
    list.push({ model, label: custom ? model : (suggested ? suggested.label : model) });
    settings.raceVehicles = list;
    settings = settings;
    customVehicle = '';
  }

  function removeRaceVehicle(index) {
    settings.raceVehicles = (settings.raceVehicles || []).filter((_, i) => i !== index);
    settings = settings;
  }

  async function setVehiclePedHere(e) {
    const pos = e?.detail?.x != null ? e.detail : await getPlayerPosition();
    if (!pos || pos.x == null) return;
    settings.raceVehiclePed = { x: pos.x, y: pos.y, z: pos.z, heading: Number(pos.heading || 0) };
    settings = settings;
  }

  function clearVehiclePed() {
    settings.raceVehiclePed = null;
    settings = settings;
  }

  // Which stage's trigger is currently armed for map-picking, if any.
  let pickingTargetIndex = null;

  // A stage pin clicked on the map selects its card and brings it into view, same as the Convoy route builder.
  let selectedPointId = null;
  function handleMapStageSelect(e) {
    const id = e.detail?.id || null;
    selectedPointId = id;
    if (!id) return;
    const card = document.querySelector(`.point-card[data-id="${id}"]`);
    if (card) card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
  let recording = false;

  // Defensive defaults. Only reassign when something genuinely changed, and never
  // mutate a stage object in place — keeps this race's stages a private array so
  // one event's vectors can never bleed into another's.
  $: if (!rallyStages) rallyStages = [];
  $: if (rallyStages) {
    let dirty = false;
    const next = rallyStages.map((s, idx) => {
      const fixed = withStageDefaults(s, idx);
      if (fixed !== s) dirty = true;
      return fixed;
    });
    if (dirty) rallyStages = next;
  }

  function withStageDefaults(s, idx) {
    const kind = (s.kind === 'START' || s.kind === 'DESTINATION' || s.kind === 'CHECKPOINT') ? s.kind : (idx === 0 ? 'START' : 'CHECKPOINT');
    const need = {
      id: s.id || `stage_${Date.now()}_${idx}`,
      order: s.order == null ? idx : s.order,
      heading: s.heading == null ? 0 : s.heading,
      radius: s.radius == null ? 20 : s.radius,
      kind,
    };
    let changed = false;
    for (const k in need) { if (s[k] !== need[k]) { changed = true; break; } }
    return changed ? { ...s, ...need } : s;
  }

  function ensureStageDefaults(stages) {
    stages.forEach((s, idx) => { Object.assign(s, withStageDefaults(s, idx)); });
    return stages;
  }

  function nextStageId() {
    return `stage_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  }

  function stageType(stage, i) {
    if (stage.kind === 'START' || stage.kind === 'DESTINATION' || stage.kind === 'CHECKPOINT') return stage.kind;
    if (i === 0) return 'START';
    if (i === rallyStages.length - 1) return 'DESTINATION';
    return 'CHECKPOINT';
  }

  function stageAccent(type) {
    return type === 'START' ? TYPE_COLOR_JS.START
      : type === 'DESTINATION' ? TYPE_COLOR_JS.DESTINATION
      : TYPE_COLOR_JS.CHECKPOINT;
  }

  function defaultNameFor(type) {
    if (type === 'START') return 'Grid Start Line';
    if (type === 'DESTINATION') return 'Finish Line';
    return `Checkpoint ${rallyStages.filter((s) => s.kind === 'CHECKPOINT').length + 1}`;
  }

  // Always builds a brand-new object (never shares references with another stage,
  // template or event) so editing one vector can't show up elsewhere.
  function makeStage(type, pos) {
    const name = defaultNameFor(type);
    return {
      id: nextStageId(),
      order: rallyStages.length,
      name,
      label: name,
      kind: type,
      x: pos ? pos.x : null,
      y: pos ? pos.y : null,
      z: pos ? pos.z : null,
      heading: pos ? Number(pos.heading || 0) : 0,
      radius: 20,
    };
  }

  function addStage(type) {
    const t = typeof type === 'string' ? type : (rallyStages.length === 0 ? 'START' : 'CHECKPOINT');
    rallyStages = [...rallyStages, makeStage(t, null)];
  }

  async function addFromPosition(type) {
    const pos = await getPlayerPosition();
    if (!pos || pos.x == null) return;
    const t = typeof type === 'string' ? type : (rallyStages.length === 0 ? 'START' : 'CHECKPOINT');
    rallyStages = [...rallyStages, makeStage(t, pos)];
  }

  async function removeAllStages() {
    const ok = await confirmAction('Delete every stage in this race? This cannot be undone.', { title: 'Delete All Stages', danger: true });
    if (!ok) return;
    rallyStages = [];
  }

  function setStageType(index, type) {
    rallyStages = rallyStages.map((s, i) => (i === index ? { ...s, kind: type } : s));
  }

  function setCoord(index, field, raw) {
    const n = raw === '' || raw == null ? null : Number(raw);
    rallyStages = rallyStages.map((s, i) => (i === index ? { ...s, [field]: Number.isFinite(n) ? n : null } : s));
  }

  // "Checkpoint 1, 2, 3…" follows the race order of the checkpoint stages, so deleting, inserting or moving a stage never
  // leaves gaps or duplicates. A stage you renamed keeps its own name; Start and Finish are never numbered.
  $: if (!locked) {
    const rank = new Map();
    rallyStages.forEach((s, i) => { if (stageType(s, i) === 'CHECKPOINT') rank.set(s.id, rank.size + 1); });
    const renamed = renumberAuto(rallyStages, 'Checkpoint ', { fields: ['name', 'label'], rankOf: (s) => rank.get(s.id) ?? null });
    if (renamed !== rallyStages) rallyStages = renamed;
  }

  // Route sequence overview: the race as an ordered chain.
  $: sequence = rallyStages.map((s, i) => ({ type: stageType(s, i), name: s.name }));
  $: hasStart = sequence.some((s) => s.type === 'START');
  $: hasDestination = sequence.some((s) => s.type === 'DESTINATION');

  function startPicking(index) {
    if (pickingTargetIndex === index) {
      pickingTargetIndex = null;
      return;
    }
    pickingTargetIndex = index;
    const mapEl = document.querySelector('.map-preview');
    if (mapEl) mapEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  async function handleMapClick(e) {
    if (!e || !e.detail || pickingTargetIndex == null) return;
    const { x, y } = e.detail;
    // the height of the spot clicked on the map (not the admin's own height wherever they happen to stand)
    const ground = await getGroundZ(x, y, undefined).catch(() => null);
    let zVal;
    if (ground && ground.found) zVal = Number(Number(ground.z).toFixed(2));
    else {
      const pos = await getPlayerPosition();
      zVal = (pos && pos.z != null) ? Number(pos.z.toFixed(2)) : 30;
    }
    rallyStages = rallyStages.map((s, i) => (i === pickingTargetIndex ? { ...s, x, y, z: zVal } : s));
    pickingTargetIndex = null;
  }

  function handleStageMove(e) {
    if (!e || !e.detail) return;
    const { id, x, y, z } = e.detail;
    rallyStages = rallyStages.map((s) => (s.id === id ? { ...s, x, y, ...(z != null ? { z } : {}) } : s));
  }

  async function removeStage(index) {
    const ok = await confirmAction('Remove this checkpoint / stage from the race?', { title: 'Remove Stage', danger: true });
    if (!ok) return;
    rallyStages = rallyStages.filter((_, i) => i !== index).map((s, i) => ({ ...s, order: i }));
  }

  function moveStage(index, direction) {
    const target = index + direction;
    if (target < 0 || target >= rallyStages.length) return;
    const copy = [...rallyStages];
    const temp = copy[index];
    copy[index] = copy[target];
    copy[target] = temp;
    rallyStages = copy.map((s, i) => ({ ...s, order: i }));
  }

  async function setVectorHere(index) {
    const pos = await getPlayerPosition();
    if (!pos || pos.x == null) return;
    const h = Number(pos.heading || 0);
    rallyStages = rallyStages.map((s, i) => (i === index ? { ...s, x: pos.x, y: pos.y, z: pos.z, heading: h } : s));
  }

  function vectorSet(stage) {
    return stage.x != null;
  }

  function teleportToStage(stage) {
    if (stage.x != null) teleportToPosition(stage.x, stage.y, stage.z, stage.heading || 0);
  }

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

  function fmt(val) {
    if (val == null || isNaN(val)) return '—';
    return Number(val).toFixed(1);
  }

  // ── Multi-select bulk delete ──
  let checkedIds = [];
  $: checkedCount = rallyStages.filter((s) => checkedIds.includes(s.id)).length;

  function toggleChecked(id) {
    checkedIds = checkedIds.includes(id) ? checkedIds.filter((x) => x !== id) : [...checkedIds, id];
  }

  function toggleAllChecked() {
    checkedIds = checkedCount === rallyStages.length ? [] : rallyStages.map((s) => s.id);
  }

  async function removeChecked() {
    const ids = rallyStages.filter((s) => checkedIds.includes(s.id)).map((s) => s.id);
    if (ids.length === 0) return;
    const ok = await confirmAction(`Delete the ${ids.length} selected race stage${ids.length === 1 ? '' : 's'}? This cannot be undone.`, {
      title: 'Delete Selected Stages',
      danger: true,
      confirmLabel: 'Yes, Delete Selected'
    });
    if (!ok) return;
    rallyStages = rallyStages.filter((s) => !ids.includes(s.id)).map((s, i) => ({ ...s, order: i }));
    checkedIds = [];
  }

  // ── Drag & Drop Stage Reordering Engine ──
  let draggedId = null;
  let draggedIndex = null;
  let dragOverIndex = null;
  let dragLabel = '';
  let dragAccent = '';
  let ghostX = 0, ghostY = 0;

  function startDrag(index, stage, e) {
    if (locked) return;
    e.preventDefault();
    e.stopPropagation();
    draggedId = stage.id;
    draggedIndex = index;
    dragOverIndex = index;
    const type = stageType(stage, index);
    dragLabel = `#${index + 1} ${type} — ${stage.name || `Stage ${index + 1}`}`;
    dragAccent = stageAccent(type);
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
      if (targetIdx !== draggedIndex && targetIdx >= 0 && targetIdx < rallyStages.length) {
        const copy = [...rallyStages];
        const [moved] = copy.splice(draggedIndex, 1);
        copy.splice(targetIdx, 0, moved);
        rallyStages = copy.map((s, idx) => ({ ...s, order: idx }));
      }
    }

    draggedId = null;
    draggedIndex = null;
    dragOverIndex = null;
  }

  // ── Manual Sequence Number Changing ──
  let showNumberModal = false;
  let numberEditIndex = null;
  let targetStageNumber = 1;

  function openNumberModal(index) {
    if (locked) return;
    numberEditIndex = index;
    targetStageNumber = index + 1;
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
    const cur = parseInt(targetStageNumber, 10) || 1;
    targetStageNumber = Math.max(1, Math.min(cur + delta, rallyStages.length));
  }

  function applyNumberChange() {
    if (numberEditIndex === null || locked) return;
    const num = parseInt(targetStageNumber, 10);
    if (isNaN(num)) return;
    const targetIdx = Math.max(0, Math.min(num - 1, rallyStages.length - 1));
    const movedStageId = rallyStages[numberEditIndex]?.id;
    if (targetIdx !== numberEditIndex) {
      const copy = [...rallyStages];
      const [moved] = copy.splice(numberEditIndex, 1);
      copy.splice(targetIdx, 0, moved);
      rallyStages = copy.map((s, idx) => ({ ...s, order: idx }));
    }
    closeNumberModal();
    if (movedStageId) {
      setTimeout(() => {
        const card = document.querySelector(`.point-card[data-id="${movedStageId}"]`);
        if (card) {
          card.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }, 100);
    }
  }

  // ── Insert Stage Modal (Before / After) ──
  let showInsertModal = false;
  let insertRefIndex = 0;
  let insertPosition = 'after'; // 'before' | 'after'
  let insertType = 'CHECKPOINT';
  let insertPlacementMode = 'position'; // 'position' | 'manual'
  let insertManualCoords = { x: 0, y: 0, z: 0, heading: 0 };
  let insertingBusy = false;

  function openInsertModal(refIdx = 0, pos = 'after') {
    if (locked) return;
    insertRefIndex = Math.max(0, Math.min(refIdx, rallyStages.length > 0 ? rallyStages.length - 1 : 0));
    insertPosition = pos;
    insertType = 'CHECKPOINT';
    insertPlacementMode = 'position';
    const refStage = rallyStages[insertRefIndex];
    if (refStage) {
      insertManualCoords = { x: refStage.x ?? 0, y: refStage.y ?? 0, z: refStage.z ?? 0, heading: refStage.heading ?? 0 };
    } else {
      insertManualCoords = { x: 0, y: 0, z: 0, heading: 0 };
    }
    showInsertModal = true;
  }

  function closeInsertModal() {
    showInsertModal = false;
  }

  async function confirmInsertStage() {
    if (locked) return;
    insertingBusy = true;
    let coords = { x: 0, y: 0, z: 0, heading: 0 };
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
        z: parseFloat(insertManualCoords.z) || 0,
        heading: parseFloat(insertManualCoords.heading) || 0
      };
    }

    const targetIdx = insertPosition === 'before' ? insertRefIndex : insertRefIndex + 1;
    const name = defaultNameFor(insertType);
    const newStage = {
      id: nextStageId(),
      order: targetIdx,
      name,
      label: name,
      kind: insertType,
      x: coords.x,
      y: coords.y,
      z: coords.z,
      heading: coords.heading,
      radius: 20,
    };

    const copy = [...rallyStages];
    copy.splice(targetIdx, 0, newStage);
    rallyStages = copy.map((s, i) => ({ ...s, order: i }));

    insertingBusy = false;
    showInsertModal = false;
    revealLast('.point-card');
  }

  // Route recorder: recorded points are appended as brand-new checkpoint objects.
  // The first point of an empty race becomes the START and the last recorded point
  // the FINISH (unless one already exists).
  const unsubRecording = routeRecordingResult.subscribe((msg) => {
    if (!msg) return;
    // Only consume a session this builder started.
    if (msg.target && msg.target !== 'GANG_RACE') return;
    const points = msg.points || [];
    if (points.length > 0) {
      const base = rallyStages.length;
      const hasDest = rallyStages.some((s) => s.kind === 'DESTINATION');
      const added = points.map((p, i) => {
        const isFirst = base === 0 && i === 0;
        const isLast = !hasDest && i === points.length - 1 && !isFirst;
        const kind = isFirst ? 'START' : (isLast ? 'DESTINATION' : 'CHECKPOINT');
        const name = kind === 'START' ? 'Grid Start Line' : (kind === 'DESTINATION' ? 'Finish Line' : `Checkpoint ${base + i + 1}`);
        return {
          id: nextStageId(),
          order: base + i,
          name,
          label: name,
          kind,
          x: p.x,
          y: p.y,
          z: p.z,
          heading: p.heading || 0,
          radius: 20,
        };
      });
      rallyStages = [...rallyStages, ...added];
      revealLast('.point-card');
    }
    recording = false;
    routeRecordingResult.set(null);
  });

  onDestroy(() => {
    unsubRecording();
    clearRoutePreview();
    if (inWorldPreview) clearPlacedPreview();
    window.removeEventListener('mousemove', onDragMove);
    window.removeEventListener('mouseup', onDragRelease);
  });

  // ── Track Props Placement (Start, Checkpoints, Finish) ──
  let previewProps = null;
  let inWorldPreview = false;

  function stagePropCount(stage) {
    if (!stage || stage.x == null) return 0;
    const r = Math.max(30, Number(stage.radius) || 20);
    return (props || []).filter((p) => (p.zone && p.zone === stage.id) || (Math.hypot((Number(p.x) || 0) - stage.x, (Number(p.y) || 0) - stage.y) <= r)).length;
  }

  function checkpointPropsCount() {
    const cps = rallyStages.filter((s) => s.kind !== 'START' && s.kind !== 'DESTINATION');
    let total = 0;
    for (const cp of cps) total += stagePropCount(cp);
    return total;
  }

  async function openStageProps(stage) {
    if (locked) return;
    // props standing at this stage -> open over them; none (or all removed) -> no anchor, so it opens at the player
    const near = (props || []).filter((p) => stage && stage.x != null && p.x != null && Math.hypot(p.x - stage.x, p.y - stage.y) <= 120);
    const focus = centroidOf(near) || undefined;
    const kindLabel = stage.kind === 'START' ? 'Start Grid' : (stage.kind === 'DESTINATION' ? 'Finish Line' : `Checkpoint #${(stage.order || 0) + 1}`);
    const res = await openPropPlacer({
      context: 'rally',
      title: `${kindLabel} Props`,
      objects: props || [],
      focus,
    });
    if (res && res.ok && Array.isArray(res.objects)) {
      props = res.objects;
      if (inWorldPreview) previewPlacedProps(props);
    }
  }

  async function openRaceProps() {
    if (locked) return;
    // starts over the placed props (the first one when they are spread along the track), or at the player when there are none
    const res = await openPropPlacer({
      context: 'rally',
      title: 'Race Track Props',
      objects: props || [],
      focus: centroidOf(props || []) || undefined,
    });
    if (res && res.ok && Array.isArray(res.objects)) {
      props = res.objects;
      if (inWorldPreview) previewPlacedProps(props);
    }
  }

  async function toggleInWorldPreview() {
    if (inWorldPreview) {
      inWorldPreview = false;
      clearPlacedPreview();
      return;
    }
    inWorldPreview = true;
    await previewPlacedProps(props || []);
  }

  async function clearAllRaceProps() {
    const ok = await confirmAction(`Remove all ${(props || []).length} placed props from this race?`, { title: 'Clear Props', danger: true });
    if (!ok) return;
    props = [];
    if (inWorldPreview) clearPlacedPreview();
    inWorldPreview = false;
  }

  // A saved template (e.g. a prebuilt track) can be PREVIEWED on the map before it
  // is imported. While previewing, the map shows the template instead of the
  // stages currently being built; nothing is changed until "Use This Track".
  let previewStages = null;
  let previewName = '';

  function onTemplatePreview(e) {
    const res = e.detail;
    if (!res || !res.rallyStages || res.rallyStages.length === 0) { previewStages = null; previewProps = null; previewName = ''; return; }
    previewStages = res.rallyStages;
    previewProps = res.props || res.eventProps || [];
    previewName = res.name || 'Saved track';
    pickingTargetIndex = null;
  }

  function clearPreview() { previewStages = null; previewProps = null; previewName = ''; }

  async function usePreview() {
    if (!previewStages) return;
    if (rallyStages.length > 0) {
      const ok = await confirmAction(`Use "${previewName}"? This REPLACES the stages and props currently in this race.`, { title: 'Use Track', danger: true, confirmLabel: 'Yes, Replace Track' });
      if (!ok) return;
    }
    const imported = previewStages.map((s, i) => ({
      id: nextStageId(), order: i, name: s.name, label: s.name || s.label,
      kind: s.kind, x: s.x, y: s.y, z: s.z, heading: s.heading, radius: s.radius,
    }));
    ensureStageDefaults(imported);
    rallyStages = imported;
    if (previewProps) props = previewProps;
    clearPreview();
  }

  $: displayStages = previewStages || rallyStages;

  // Map markers for RoutePreviewMap — one entry per placed stage.
  $: mapPoints = displayStages.filter((s) => s.x != null);

  // Imported template: stages get fresh ids/orders and the same defaults pass as a
  // hand-added one, so an imported layout is a fully independent copy.
  function applyImportedTemplate(e) {
    const res = e.detail;
    if (!res || (res.kind && res.kind !== 'GANG_RACE')) return;
    const imported = (res.rallyStages || []).map((s, i) => ({
      id: nextStageId(), order: i, name: s.name, label: s.name || s.label,
      kind: s.kind, x: s.x, y: s.y, z: s.z, heading: s.heading, radius: s.radius,
    }));
    ensureStageDefaults(imported);
    rallyStages = imported;
    if (res.props || res.eventProps) {
      props = res.props || res.eventProps || [];
    }
  }
</script>

<div class="rally-builder view-enter">
  <div class="pane" class:hidden={view !== 'vectors'}>
  <div class="header-row">
    <div class="section-title">Race Route <span class="count">{rallyStages.length} stage{rallyStages.length === 1 ? '' : 's'}</span></div>
    <div class="header-actions">
      {#if !locked}
        <button
          type="button"
          class="btn btn-steel"
          disabled={recording}
          on:click={() => {
            clearRoutePreview();
            recording = true;
            startRouteRecording({ supportsAirdrop: false, target: 'GANG_RACE' });
          }}
          title="Drive in-game and press [E] to drop checkpoints along the road"
        >
          <Icon name="pin" size={13} /> {recording ? 'Recording...' : 'Add Route by Driving'}
        </button>
      {/if}
    </div>
  </div>

  <div class="info-panel">
    <div class="info-head">
      <span class="info-title"><Icon name="flag" size={13} /> Route Sequence</span>
      {#if !locked}
        <div class="info-adds">
          <button type="button" class="btn btn-steel" disabled={hasStart} title={hasStart ? 'This race already has a START' : 'Add the starting grid'} on:click={() => addStage('START')}><Icon name="spawn" size={12} /> Add Start</button>
          <button type="button" class="btn btn-steel" on:click={() => addStage('CHECKPOINT')}><Icon name="waypointPlus" size={12} /> Add Checkpoint</button>
          <button type="button" class="btn btn-steel" disabled={hasDestination} title={hasDestination ? 'This race already has a FINISH' : 'Add the finish line'} on:click={() => addStage('DESTINATION')}><Icon name="destination" size={12} /> Add Finish</button>
        </div>
      {/if}
    </div>
    {#if sequence.length === 0}
      <p class="field-hint">Nothing yet — add a Start, then Checkpoints, then a Finish.</p>
    {:else}
      <div class="seq-row">
        {#each sequence as st, n}
          <span class="seq-chip" style="--seq-accent:{stageAccent(st.type)}">
            <span class="seq-n">{n + 1}</span>
            {st.type === 'DESTINATION' ? 'Finish' : (st.type === 'START' ? 'Start' : 'Checkpoint')}
          </span>
          {#if n < sequence.length - 1}<span class="seq-arrow">›</span>{/if}
        {/each}
      </div>
      {#if !hasStart || !hasDestination}
        <p class="field-hint warn">
          {!hasStart && !hasDestination ? 'Set one stage as START and one as FINISH.' : (!hasStart ? 'Set one stage as START.' : 'Set one stage as FINISH.')}
        </p>
      {/if}
    {/if}
  </div>

  </div>

  <div class="pane" class:hidden={view !== 'peds'}>
  <slot name="organizer" />
  <slot name="civilianPed" />

  <div class="info-panel">
    <div class="info-head">
      <span class="info-title"><Icon name="truck" size={13} /> Race Vehicles</span>
      <div class="info-adds">
        <button type="button" class="chip-btn" class:active={vehicleMode === 'OWN'} disabled={locked} on:click={() => setVehicleMode('OWN')}>Racers Bring Their Own</button>
        <button type="button" class="chip-btn" class:active={vehicleMode === 'PROVIDED'} disabled={locked} on:click={() => setVehicleMode('PROVIDED')}>Provided Vehicles</button>
      </div>
    </div>
    {#if vehicleMode === 'PROVIDED'}
      {#if !locked}
        <div class="vehicle-add-row">
          <select bind:value={pickedVehicle}>
            {#each SUGGESTED_VEHICLES as v}<option value={v.model}>{v.label}</option>{/each}
          </select>
          <input type="text" bind:value={customVehicle} maxlength="50" placeholder="…or a custom model name (e.g. futo2)" />
          <button type="button" class="btn btn-primary" on:click={addRaceVehicle}><Icon name="plus" size={12} /> Add Vehicle</button>
        </div>
      {/if}

      {#if raceVehicles.length === 0}
        <p class="field-hint warn">No vehicles added yet — add at least one.</p>
      {:else}
        <div class="seq-row">
          {#each raceVehicles as v, vi}
            <span class="seq-chip" style="--seq-accent:{TYPE_COLOR_JS.CHECKPOINT}">
              {v.label} <span class="seq-swap">({v.model})</span>
              {#if !locked}<button type="button" class="chip-x" title="Remove" on:click={() => removeRaceVehicle(vi)}>×</button>{/if}
            </span>
          {/each}
        </div>
      {/if}

      <PedRow
        title="Vehicle Ped"
        description="Racers registered for this race take one of the provided vehicles from this ped before the start."
        pos={vehiclePed}
        model={$bootstrap?.pedModels?.raceVehicle || ''}
        {locked}
        on:set={setVehiclePedHere}
        on:clear={clearVehiclePed}
      />
    {/if}
  </div>

  <p class="field-hint">The race Token Vendor (where tokens are traded for a vehicle) is a permanent ped that belongs to no race. Place or move it under <b>World Peds</b> in the sidebar.</p>
  </div>

  <div class="pane" class:hidden={view !== 'vectors'}>

  <!-- Reusable Templates Component -->
  <SavedTemplatePicker
    kind="GANG_RACE"
    {locked}
    payload={{ rallyStages, props }}
    previewable={true}
    on:import={applyImportedTemplate}
    on:preview={onTemplatePreview}
  />

  <!-- Interactive Map Preview -->
  <div class="map-preview">
    <div class="map-preview-title">
      <Icon name="activity" size={13} /> {previewStages ? 'Track Preview' : 'Route Layout'}
      <span class="map-preview-sub">— drag to pan, scroll to zoom</span>
      {#if previewStages}
        <span class="preview-pill">Previewing: {previewName} · {previewStages.length} stages</span>
        {#if !locked}
          <button type="button" class="btn btn-primary preview-btn" on:click={usePreview}>Use This Track</button>
        {/if}
        <button type="button" class="btn preview-btn" on:click={clearPreview}>Clear Preview</button>
      {/if}
      {#if pickingTargetIndex != null}
        <span class="picking-pill">Click map to place stage #{pickingTargetIndex + 1}</span>
      {/if}
    </div>
    {#if mapPoints.length > 0}
      <RoutePreviewMap
        rallyStages={displayStages}
        eventKind="GANG_RACE"
        legend={false}
        interactive={!locked && !previewStages}
        editable={!locked && !previewStages}
        bind:selectedPointId
        on:selectPoint={handleMapStageSelect}
        on:mapClick={handleMapClick}
        on:stageMove={handleStageMove}
        on:pointDrag={(e) => liveMove(e.detail)}
        on:pointMove={(e) => { liveMove.cancel(); handleStageMove(e); }}
        height={380}
      />
      <div class="map-legend">
        <span class="legend-item"><span class="legend-dot" style="background:{TYPE_COLOR_JS.START}"></span>Start</span>
        <span class="legend-item"><span class="legend-dot" style="background:{TYPE_COLOR_JS.CHECKPOINT}"></span>Checkpoint</span>
        <span class="legend-item"><span class="legend-dot" style="background:{TYPE_COLOR_JS.DESTINATION}"></span>Finish</span>
      </div>
    {:else}
      <div class="map-empty">Add at least one placed stage below to see the route plotted here.</div>
    {/if}
  </div>

  <!-- Track Props Controls -->
  <div class="props-toolbar">
    <div class="props-toolbar-left">
      <span class="props-pill">
        <Icon name="box" size={13} />
        <b>{props.length}</b> prop{props.length === 1 ? '' : 's'} placed for this race
      </span>
      {#if props.length > 0}
        <span class="props-breakdown">
          (Start: {stagePropCount(rallyStages.find((s) => s.kind === 'START'))} · CPs: {checkpointPropsCount()} · Finish: {stagePropCount(rallyStages.find((s) => s.kind === 'DESTINATION'))})
        </span>
      {/if}
    </div>
    <div class="props-toolbar-actions">
      <button type="button" class="btn btn-primary" on:click={openRaceProps} disabled={locked}>
        <Icon name="move" size={13} /> <span>{props.length ? 'Edit Track Props' : 'Place Track Props'}</span>
      </button>
      <button type="button" class="btn btn-preview" on:click={toggleInWorldPreview} disabled={!props.length && !inWorldPreview}>
        <Icon name="eye" size={13} /> <span>{inWorldPreview ? 'Hide In-World' : 'Preview In-World'}</span>
      </button>
      {#if props.length > 0 && !locked}
        <button type="button" class="btn btn-danger" on:click={clearAllRaceProps} title="Remove all props placed for this race">
          <Icon name="trash" size={13} />
        </button>
      {/if}
    </div>
  </div>

  {#if !locked}
    <div class="add-point-row">
      <button type="button" class="btn btn-steel" on:click={() => addStage()}><Icon name="waypointPlus" size={13} /> Add Manually</button>
      <button type="button" class="btn btn-steel btn-insert" on:click={() => openInsertModal(rallyStages.length > 0 ? rallyStages.length - 1 : 0, 'after')} disabled={rallyStages.length === 0} title="Insert a race stage before or after a specific stage">
        <Icon name="waypointPlus" size={13} /> Insert Stage…
      </button>
      <button type="button" class="btn btn-steel" on:click={() => addFromPosition()}><Icon name="pin" size={13} /> Add Pin Here</button>
      <button type="button" class="btn btn-danger" disabled={rallyStages.length === 0} on:click={removeAllStages} title="Delete every stage"><Icon name="routeClear" size={13} /> Delete All</button>
    </div>

    {#if rallyStages.length > 0}
      <div class="select-bar">
        <label class="select-all" title="Tick the box on any stage card to pick which ones to delete">
          <input type="checkbox" checked={checkedCount === rallyStages.length} indeterminate={checkedCount > 0 && checkedCount < rallyStages.length} on:change={toggleAllChecked} />
          <span>{checkedCount > 0 ? `${checkedCount} selected` : 'Select stages to delete'}</span>
        </label>
        {#if checkedCount > 0}
          <button type="button" class="btn btn-steel" on:click={() => (checkedIds = [])}>Clear</button>
          <button type="button" class="btn btn-danger" on:click={removeChecked}><Icon name="trash" size={13} /> Delete Selected ({checkedCount})</button>
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
            Target: Position #{dragOverIndex >= rallyStages.length ? rallyStages.length : dragOverIndex + 1}
          {:else}
            Dragging...
          {/if}
        </span>
      </div>
    </div>
  {/if}

  <!-- Stage list -->
  <div class="stages-container point-list">
    {#each rallyStages as stage, i (stage.id)}
      {@const type = stageType(stage, i)}
      {#if draggedId !== null && dragOverIndex === i}
        <div class="drop-indicator-line">
          <div class="drop-indicator-pill">
            <Icon name="chevronDown" size={12} />
            <span>Insert as Stage #{i + 1}</span>
            <Icon name="chevronDown" size={12} />
          </div>
        </div>
      {/if}

      <div
        class="point-card"
        data-id={stage.id}
        data-index={i}
        class:selected={stage.id === selectedPointId}
        class:dragging={stage.id === draggedId}
        style="--point-accent:{stageAccent(type)}"
        on:click={() => (selectedPointId = stage.id)}
      >
        <div class="point-top">
          <div class="point-left">
            {#if !locked}
              <input
                type="checkbox"
                class="point-check"
                title="Select this stage for bulk delete"
                checked={checkedIds.includes(stage.id)}
                on:click|stopPropagation
                on:change={() => toggleChecked(stage.id)}
              />
              <div
                class="drag-handle"
                title="Click and drag to reorder this stage"
                on:mousedown={(e) => startDrag(i, stage, e)}
                role="button"
                tabindex="0"
              >
                <Icon name="grip" size={16} />
                <span class="drag-handle-hint">DRAG</span>
              </div>
            {/if}

            <!-- Clickable Number Badge to manually change stage number -->
            <button
              type="button"
              class="point-order-btn"
              title="Click to manually change stage number (#{i + 1})"
              disabled={locked}
              on:click={() => openNumberModal(i)}
            >
              <span class="order-hash">#</span><span class="order-num">{i + 1}</span>
              <span class="order-edit-icon"><Icon name="edit" size={10} /></span>
            </button>

            <!-- Type badge with icon & select -->
            <div class="type-badge-pill" style="border-left-color: {stageAccent(type)}">
              <Icon name={type === 'START' ? 'flag' : (type === 'DESTINATION' ? 'destination' : 'route')} size={14} />
              <select class="type-select" value={type} disabled={locked} on:change={(e) => setStageType(i, e.target.value)}>
                {#each STAGE_TYPES as t}<option value={t.value}>{t.label}</option>{/each}
              </select>
            </div>

            <!-- Stage Name Input -->
            <div class="point-info-group">
              <input
                type="text"
                class="stage-name-input-modern"
                bind:value={stage.name}
                placeholder="Stage name"
                disabled={locked}
              />
            </div>

            <!-- Coordinates preview pill -->
            <div class="point-coords-preview mono" title="Coordinates: X={fmt(stage.x)}, Y={fmt(stage.y)}, Z={fmt(stage.z)}, H={fmt(stage.heading)}°">
              <span
                class="placed-dot"
                class:placed={vectorSet(stage)}
                title={vectorSet(stage) ? 'Position set' : 'Position not set'}
              ></span>
              <span>{fmt(stage.x)}, {fmt(stage.y)}</span>
            </div>
          </div>

          <div class="point-actions">
            {#if $bootstrap?.isAdmin && vectorSet(stage)}
              <button class="icon-btn info icon-btn-text" title="Teleport to this stage" on:click={() => teleportToStage(stage)}>
                <Icon name="teleport" size={13} /> Teleport
              </button>
            {/if}
            {#if !locked}
              <button class="icon-btn info icon-btn-text" title="Change sequence number" on:click={() => openNumberModal(i)}>
                <Icon name="edit" size={12} /> Change #
              </button>
              <button class="icon-btn info icon-btn-text" title="Insert a stage before this point" on:click={() => openInsertModal(i, 'before')}>
                <Icon name="waypointPlus" size={12} /> + Before
              </button>
              <button class="icon-btn info icon-btn-text" title="Insert a stage after this point" on:click={() => openInsertModal(i, 'after')}>
                <Icon name="waypointPlus" size={12} /> + After
              </button>
              <button class="icon-btn success icon-btn-text" title="Set to my current position" on:click={() => setVectorHere(i)}>
                <Icon name="pin" size={13} /> Set Position
              </button>
              <button
                type="button"
                class="icon-btn icon-btn-text"
                class:active-pick={pickingTargetIndex === i}
                title="Click a spot on the map above"
                on:click={() => startPicking(i)}
              ><Icon name="crosshair" size={13} /> Pick on Map</button>
              {#if vectorSet(stage)}
                <button
                  type="button"
                  class="icon-btn icon-btn-text"
                  disabled={locked}
                  title="Place/edit props around this checkpoint in the Prop Placer"
                  on:click={() => openStageProps(stage)}
                >
                  <Icon name="box" size={13} /> Props ({stagePropCount(stage)})
                </button>
              {/if}
              <button class="icon-btn btn-move icon-btn-text" disabled={locked || i === 0} on:click={() => moveStage(i, -1)} title="Move Up">
                <Icon name="chevronUp" size={14} /> Up
              </button>
              <button class="icon-btn btn-move icon-btn-text" disabled={locked || i === rallyStages.length - 1} on:click={() => moveStage(i, 1)} title="Move Down">
                <Icon name="chevronDown" size={14} /> Down
              </button>
              <button class="icon-btn danger icon-btn-text" disabled={locked} on:click={() => removeStage(i)} title="Delete Stage">
                <Icon name="trash" size={14} /> Delete
              </button>
            {/if}
          </div>
        </div>

        <fieldset class="point-fieldset" disabled={locked}>
          <div class="point-coords">
            <div class="coord-field">
              <label>X</label>
              <input type="number" step="0.01" value={stage.x ?? ''} on:input={(e) => setCoord(i, 'x', e.target.value)} />
            </div>
            <div class="coord-field">
              <label>Y</label>
              <input type="number" step="0.01" value={stage.y ?? ''} on:input={(e) => setCoord(i, 'y', e.target.value)} />
            </div>
            <div class="coord-field">
              <label>Z</label>
              <input type="number" step="0.01" value={stage.z ?? ''} on:input={(e) => setCoord(i, 'z', e.target.value)} />
            </div>
            <div class="coord-field">
              <label>Heading</label>
              <input type="number" step="0.1" value={stage.heading ?? 0} on:input={(e) => setCoord(i, 'heading', e.target.value)} />
            </div>
          </div>

          <div class="field-row">
            <div class="field">
              <label>Trigger Radius</label>
              <div class="radius-slider">
                <input type="range" min="5" max="80" step="5" bind:value={stage.radius} disabled={locked} />
                <span class="slider-val">{stage.radius || 20}m</span>
              </div>
            </div>
          </div>
        </fieldset>
      </div>
    {/each}

    {#if rallyStages.length === 0}
      <div class="placeholder-panel">
        <Icon name="flag" size={28} />
        <h4>No Stages Yet</h4>
        <p>Add a Start, then Checkpoints, then a Finish — or use "Add Route by Driving" to drive the path and drop them live.</p>
        <button type="button" class="btn btn-steel" style="margin-top:12px" disabled={locked} on:click={() => addStage('START')}>
          <Icon name="plus" size={13} />
          <span>Add Start</span>
        </button>
      </div>
    {/if}
  </div>
  </div>
</div>

{#if showInsertModal}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div
    class="insert-backdrop"
    use:portal
    on:click|self={closeInsertModal}
    on:keydown={(e) => { if (e.key === 'Escape') closeInsertModal(); }}
  >
    <div class="insert-box" role="dialog" aria-modal="true" aria-label="Insert Race Stage">
      <div class="insert-head">
        <div class="insert-title">
          <Icon name="waypointPlus" size={15} />
          Insert Race Stage
        </div>
        <button class="icon-btn" title="Close" on:click={closeInsertModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="insert-body">
        <div class="insert-field">
          <label>Reference Stage</label>
          <select bind:value={insertRefIndex} class="insert-select">
            {#each rallyStages as st, idx}
              <option value={idx}>
                Stage #{idx + 1} — {st.name || st.label || `Stage ${idx + 1}`} ({fmt(st.x)}, {fmt(st.y)})
              </option>
            {/each}
          </select>
        </div>

        <div class="insert-field">
          <label>Position Relative to Stage #{insertRefIndex + 1}</label>
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
            The new stage will become #{insertPosition === 'before' ? insertRefIndex + 1 : insertRefIndex + 2} in the sequence. All subsequent stages will automatically shift down.
          </div>
        </div>

        <div class="insert-field">
          <label>Stage Type</label>
          <select bind:value={insertType} class="insert-select">
            {#each STAGE_TYPES as t}
              <option value={t.value}>{t.label}</option>
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
        <button class="btn btn-primary" on:click={confirmInsertStage} disabled={insertingBusy}>
          {insertingBusy ? 'Inserting…' : 'Insert Race Stage'}
        </button>
      </div>
    </div>
  </div>
{/if}

{#if showNumberModal && numberEditIndex !== null && rallyStages[numberEditIndex]}
  {@const curStage = rallyStages[numberEditIndex]}
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
    <div class="insert-box number-modal-box" role="dialog" aria-modal="true" aria-label="Change Stage Number">
      <div class="insert-head">
        <div class="insert-title">
          <Icon name="edit" size={15} />
          Change Stage Number
        </div>
        <button class="icon-btn" title="Close" on:click={closeNumberModal}><Icon name="close" size={14} /></button>
      </div>

      <div class="insert-body">
        <div class="num-modal-summary">
          <div class="num-modal-badge" style="border-left-color: {stageAccent(stageType(curStage, numberEditIndex))}">
            <span class="num-modal-curr">Current Position: <strong>#{numberEditIndex + 1}</strong></span>
            <span class="num-modal-type">{stageType(curStage, numberEditIndex)}</span>
            <span class="num-modal-name">{curStage.name || curStage.label || `Stage ${numberEditIndex + 1}`}</span>
          </div>
        </div>

        <div class="insert-field">
          <label>Target Stage Number (1 to {rallyStages.length})</label>
          <div class="num-stepper-row">
            <button
              type="button"
              class="stepper-btn"
              disabled={targetStageNumber <= 1}
              on:click={() => stepTargetNumber(-1)}
              title="Decrease number"
            >
              <Icon name="chevronDown" size={16} />
            </button>
            <input
              type="number"
              class="num-stepper-input"
              min="1"
              max={rallyStages.length}
              bind:value={targetStageNumber}
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
              disabled={targetStageNumber >= rallyStages.length}
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
            Changing this stage from #{numberEditIndex + 1} to <strong>#{targetStageNumber}</strong> will smoothly reposition it in the race order. Other stages will adjust so the sequence remains strictly continuous (1 to {rallyStages.length}) without gaps or duplicates.
          </p>
          <p class="conflict-note">
            ✓ Coordinates, trigger radius, and props are 100% preserved.
          </p>
        </div>
      </div>

      <div class="insert-foot">
        <button class="btn" on:click={closeNumberModal}>Cancel</button>
        <span class="insert-spacer"></span>
        <button
          class="btn btn-primary"
          on:click={applyNumberChange}
          disabled={targetStageNumber === numberEditIndex + 1}
        >
          Apply New Number (#{targetStageNumber})
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .pane {
    display: contents;
  }
  .rally-builder {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    padding: 10px 14px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
  }
  .hint strong {
    color: var(--text-main);
  }

  .chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .chip-btn {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    padding: 9px 14px;
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
  .picking-pill {
    margin-left: auto;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--on-accent);
    border: 1px solid var(--c-action);
    background: var(--c-action);
    border-radius: var(--radius-sm);
    padding: 2px 8px;
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

  .stages-container {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .point-card {
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-left: 3px solid var(--point-accent, var(--tablet-border-strong));
    border-radius: var(--radius-sm);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    transition: border-color 0.15s ease;
  }
  .point-card:hover {
    border-color: var(--tablet-border-strong);
  }

  .point-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .point-left {
    display: flex;
    align-items: center;
    gap: 10px;
    flex: 1;
    min-width: 0;
  }
  .point-order {
    font-size: var(--fs-small);
    font-weight: var(--fw-value);
    color: var(--text-dim);
    min-width: 18px;
    text-align: center;
  }
  .placed-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    background: var(--tablet-danger);
  }
  .placed-dot.placed {
    background: var(--tablet-success);
  }
  .index-badge {
    flex-shrink: 0;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: var(--text-main);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--radius-sm);
    padding: 3px 8px;
  }
  .stage-name-input {
    flex: 1;
    min-width: 0;
    max-width: 320px;
    background: var(--lt-0f1113, #0f1113);
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-body);
    font-weight: 600;
    padding: 8px 12px;
  }
  .stage-name-input:focus {
    outline: none;
    border-color: var(--accent-primary);
  }

  .point-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
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

  .vector-block {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .vector-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .vector-title {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--text-main);
  }
  .vector-coords {
    font-size: var(--fs-small);
    font-family: var(--font-mono);
    color: var(--text-dim);
  }
  .vector-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }

  .radius-slider {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .radius-slider input[type="range"] {
    flex: 1;
  }
  .slider-val {
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-ffffff, #ffffff);
    min-width: 40px;
  }

  .inline-config {
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 14px;
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
  .inline-title :global(svg) {
    color: var(--view-accent, var(--accent-primary-light));
  }

  .header-row { display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:10px; }
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
  .count { color:var(--tablet-text-faint); font-weight:400; margin-left:4px; }
  .add-point-row { display:flex; justify-content:flex-end; gap:8px; }
  .type-select { background:var(--input-bg, #131518); border:1px solid var(--input-border, #30353c); border-radius:var(--radius-sm); color:var(--text-main); padding:8px 10px; font-size:var(--fs-body); font-weight:500; min-width:140px; }
  .point-coords { display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin-bottom:12px; }
  .coord-field { display:flex; flex-direction:column; gap:5px; }
  .coord-field label { font-size: var(--fs-meta); font-weight:var(--fw-nav); letter-spacing: 0.01em; color:var(--tablet-text-faint); }
  .coord-field input { background:var(--input-bg, #131518); border:1px solid var(--input-border, #30353c); border-radius:var(--radius-sm); color:var(--text-main); padding:8px 9px; font-size:var(--fs-body); font-family:var(--font-mono); }
  .coord-field input:focus { outline:none; border-color:var(--accent-primary); background:var(--input-bg-focus, #181b1f); }
  .info-panel { border:1px solid var(--tablet-border); border-radius:var(--radius-sm); background:var(--tablet-panel-alt, var(--tablet-panel)); padding:14px; display:flex; flex-direction:column; gap:10px; }
  .info-head {
    display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px;
    margin: -14px -14px 4px; padding: 8px 14px;
    background: var(--topbar-bg, #15171b);
    border-bottom: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-panel) var(--r-panel) 0 0;
  }
  .info-title { display:inline-flex; align-items:center; gap:6px; font-size:var(--fs-small); font-weight:700; letter-spacing: 0.01em; color:var(--text-main); }
  .info-adds { display:flex; flex-wrap:wrap; gap:8px; }
  .seq-row { display:flex; flex-wrap:wrap; align-items:center; gap:6px; }
  .seq-chip { display:inline-flex; align-items:center; gap:6px; padding:5px 10px; border-radius:999px; border:1px solid var(--seq-accent); color:var(--text-main); font-size: var(--fs-meta); font-weight:600; }
  .seq-n { display:inline-flex; align-items:center; justify-content:center; width:18px; height:18px; border-radius:50%; background:var(--seq-accent); color:#0f1113; font-size: var(--fs-meta); font-weight:700; }
  .seq-swap { color:var(--text-dim); font-weight:500; }
  .seq-arrow { color:var(--tablet-text-faint); }
  .field-hint { font-size: var(--fs-small); font-weight: 400; line-height: 1.5; color: var(--lt-aeb5bd, #aeb5bd); margin-top: 8px; }
  .preview-pill { padding: 3px 10px; border-radius: 999px; border: 1px solid var(--c-action); background: var(--c-action); color: var(--on-accent); font-size: var(--fs-meta); font-weight: 600; }
  .vehicle-add-row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  .vehicle-add-row select, .vehicle-add-row input { min-height:38px; padding:0 12px; background:var(--input-bg); border:1px solid var(--input-border); border-radius:var(--r-ctl); color:var(--lt-ffffff, #fff); font-size:var(--fs-body); }
  .vehicle-add-row input { flex:1; min-width:180px; }
  .chip-x { margin-left:4px; background:transparent; border:0; color:var(--text-dim); font-size: var(--fs-meta); line-height:1; cursor:pointer; }
  .chip-x:hover { color:var(--tablet-danger); }
  .preview-btn { min-height: 28px; padding: 0 12px; font-size: var(--fs-small); margin-left: 6px; }
  .field-hint.warn { color:var(--tablet-danger,#d9736f); }
  @media (max-width: 900px) { .point-coords { grid-template-columns:repeat(2,1fr); } }

  /* Coordinate ("vector") text: larger + bold so it reads at a glance. */
  .coord-field label { font-size: var(--fs-small); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-c9ced4, #c9ced4); }
  .coord-field input { font-size: var(--fs-body); font-weight: 700; letter-spacing: 0.01em; }
  .vector-coords { font-size: var(--fs-body); font-weight: 700; color: var(--lt-eceef0, #eceef0); }
  .vector-coords { font-family: var(--font-ui); font-variant-numeric: tabular-nums; }
  .coord-field input { font-family: var(--font-ui); font-variant-numeric: tabular-nums; }

  .props-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 10px;
    padding: 10px 14px;
    background: rgba(var(--ltc-18-22-34, 18, 22, 34), 0.85);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    margin-bottom: 10px;
  }
  .props-toolbar-left {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }
  .props-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff);
  }
  .props-pill b {
    color: var(--accent-primary);
  }
  .props-breakdown {
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
  }
  .props-toolbar-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* Bulk Select Bar */
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

  /* Point List & Cards */
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

  /* Drag Ghost & Indicator Line */
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

  /* Drag Handle */
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

  /* Point Order / Renumber Button */
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

  /* Type badge pill & inputs */
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
    gap: 12px;
    min-width: 0;
    flex-wrap: wrap;
  }

  /* Insert Button & Modals */
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
    font-family: var(--font-mono);
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

  /* Renumbering Modal */
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
    font-family: var(--font-mono);
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
</style>
