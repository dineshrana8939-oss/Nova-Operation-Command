<script>
  // The territory map: the real GTA V world (the same atlas tiles as the route previews) with the painted territories on
  // top. ONE component for everything — the admin's Territory Map editor (paint / erase / undo / redo / clear), the Review
  // tab, the admin Territory Control view and the gang tablet's live map. A territory is a set of grid cells
  // (territoryGeometry.js); every layer (the base area and each predefined expansion) is drawn from its own cell set.
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import { adminPrefs } from '../adminPrefs.js';
  import { ATLAS_TILE_URL, ATLAS_MIN_ZOOM, ATLAS_MAX_ZOOM, ATLAS_TILE_SIZE, createAtlasCRS } from '../util/mapGeometry.js';
  import {
    cellKey,
    cellsFromSpans,
    spansFromCells,
    strokeSegment,
    fillRectangle,
    fillCircle,
    fillPolygon,
    hexToRgb,
    rgba,
    centroid,
  } from './territoryGeometry.js';
  import Icon from '../tablet/ui/Icon.svelte';

  const dispatch = createEventDispatcher();

  // territories: [{ id, name, color, ownerLabel, logo, image, imagePos, showName, cs, status,
  //                 layers: [{ key, label, spans, unlocked, xpCost, level }] }]
  export let territories = [];
  export let mode = 'view';              // 'view' | 'edit'
  export let selectedId = null;
  export let blinkSelected = true;
  export let activeLayerKey = 'base';    // edit: the layer of the selected territory being painted
  export let editing = false;            // a paint session is open: the paint tools are live
  export let tool = 'brush';             // 'brush' | 'line' | 'rect' | 'square' | 'circle' | 'poly4' | 'eraser' | 'pan' | 'logo'
  export let brushRadius = 25;           // metres (legacy or derived)
  export let brushMetres = 25;           // Constant GTA world metres brush radius
  export let brushPx = 14;               // Brush size in pixels for freehand brush
  const MIN_EXPANSION_ZOOM = 4.0;        // Minimum zoom required for gang territory painting
  let currentZoom = 5.0;
  export let height = 560;       // px (a number) or a CSS length such as '100%': then the map fills its parent
  $: fill = typeof height !== 'number';
  export let showLabels = true;
  export let showLocked = true;          // locked expansions as ghosts
  export let dim = true;                 // darken the basemap so painted colours read clearly
  export let markers = [];               // [{ x, y, label, color }] extra points (auction house, capture point ...)
  export let pickMode = false;           // the next click returns a world point ('pick')
  export let maxCells = 80000;
  export let isAdmin = true;             // true: full HEX color picker; false: gang assigned color badge
  export let gangLabel = '';             // name of gang when viewed in gang tablet
  export let showToolbar = true;         // whether to show the unified drawing toolbar during edit session

  let container;
  let canvas;
  let ctx;
  let L;
  let map;
  let ready = false;
  let resizeObs;
  let dpr = 1;
  let raf = 0;
  let blinkRaf = 0;

  // ── masks (one offscreen 1px-per-cell canvas per layer) ───────────────────────
  const masks = new Map();       // `${tid}|${layerKey}` -> mask
  const arrIds = new WeakMap();
  let arrCounter = 0;
  const arrId = (a) => { if (!a) return 0; let id = arrIds.get(a); if (!id) { id = ++arrCounter; arrIds.set(a, id); } return id; };

  function makeMask(spans, color, cs, withSet = true) {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, n = 0;
    for (const s of spans || []) {
      n += s[2] - s[1] + 1;
      if (s[1] < minX) minX = s[1];
      if (s[2] > maxX) maxX = s[2];
      if (s[0] < minY) minY = s[0];
      if (s[0] > maxY) maxY = s[0];
    }
    const mask = { cs, color, count: n, set: withSet ? cellsFromSpans(spans) : null, canvas: null, ix0: 0, iy0: 0, w: 0, h: 0 };
    if (!n) return mask;
    mask.ix0 = minX; mask.iy0 = minY; mask.w = maxX - minX + 1; mask.h = maxY - minY + 1;
    const cv = document.createElement('canvas');
    cv.width = mask.w; cv.height = mask.h;
    const c = cv.getContext('2d');
    const img = c.createImageData(mask.w, mask.h);
    const [r, g, b] = hexToRgb(color);
    for (const s of spans) {
      const row = mask.h - 1 - (s[0] - minY);        // world y grows up, canvas y grows down
      for (let ix = s[1]; ix <= s[2]; ix++) {
        const p = (row * mask.w + (ix - minX)) * 4;
        img.data[p] = r; img.data[p + 1] = g; img.data[p + 2] = b; img.data[p + 3] = 255;
      }
    }
    c.putImageData(img, 0, 0);
    mask.canvas = cv;
    return mask;
  }

  // Cheap in-place update of a mask while painting
  function paintCell(mask, ix, iy, add, rgb) {
    if (add) {
      if (!mask.canvas) { mask.ix0 = ix; mask.iy0 = iy; mask.w = 1; mask.h = 1; mask.canvas = document.createElement('canvas'); mask.canvas.width = 1; mask.canvas.height = 1; }
      if (ix < mask.ix0 || iy < mask.iy0 || ix >= mask.ix0 + mask.w || iy >= mask.iy0 + mask.h) growMask(mask, ix, iy);
      const c = mask.canvas.getContext('2d');
      c.fillStyle = `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
      c.fillRect(ix - mask.ix0, mask.h - 1 - (iy - mask.iy0), 1, 1);
    } else if (mask.canvas) {
      if (ix < mask.ix0 || iy < mask.iy0 || ix >= mask.ix0 + mask.w || iy >= mask.iy0 + mask.h) return;
      mask.canvas.getContext('2d').clearRect(ix - mask.ix0, mask.h - 1 - (iy - mask.iy0), 1, 1);
    }
  }
  function growMask(mask, ix, iy) {
    const pad = 24;
    const nx0 = Math.min(mask.ix0, ix - pad), ny0 = Math.min(mask.iy0, iy - pad);
    const nx1 = Math.max(mask.ix0 + mask.w, ix + pad + 1), ny1 = Math.max(mask.iy0 + mask.h, iy + pad + 1);
    const nw = nx1 - nx0, nh = ny1 - ny0;
    const cv = document.createElement('canvas');
    cv.width = nw; cv.height = nh;
    cv.getContext('2d').drawImage(mask.canvas, mask.ix0 - nx0, (ny0 + nh) - (mask.iy0 + mask.h));
    mask.canvas = cv; mask.ix0 = nx0; mask.iy0 = ny0; mask.w = nw; mask.h = nh;
  }

  function maskFor(t, layer) {
    const k = `${t.id}|${layer.key}`;
    // painted in the OWNING gang's colour (so a territory handed to another gang changes colour with it); an unowned
    // territory keeps its own colour
    const col = t.ownerAccent || t.color;
    const sig = `${arrId(layer.spans)}|${col}|${t.cs}`;
    let m = masks.get(k);
    if (!m || m.sig !== sig) {
      m = makeMask(layer.spans, col, t.cs || 25);
      m.sig = sig;
      masks.set(k, m);
    }
    return m;
  }

  // ── the paint session (working copy of ONE layer) ─────────────────────────────
  let work = null;          // { tid, key, color, cs, set, mask, undo: [], redo: [] }
  let stroke = null;        // { type, startX, startY, curX, curY, add, lastX, lastY, changed }
  let hover = null;         // pointer in container px
  let quadPoints = [];      // [{x, y}] clicked points for 4-point shape tool before 4th point
  let activeShape = null;   // { type: 'quad'|'line'|'circle', points?: [{x, y}], center?: {x, y}, radius?: number, baseSet: Set }
  let shapeUndo = [];       // vector shape history stack
  let shapeRedo = [];
  let dragHandle = null;    // active dragged control point { type, index }
  let hoveredHandle = null; // currently hovered control point { type, index }
  let activeColor = '#b65ce4';
  let historyState = { undo: 0, redo: 0, cells: 0 };
  let spaceDown = false;

  const area = () => territories.find((t) => t.id === selectedId) || null;
  const layerOf = (t) => (t && (t.layers || []).find((l) => l.key === activeLayerKey)) || null;

  function startSession() {
    const t = area(), layer = layerOf(t);
    if (!t || !layer) { work = null; return; }
    const cs = t.cs || 25;
    activeColor = t.color || '#b65ce4';
    work = { tid: t.id, key: layer.key, color: activeColor, cs, set: cellsFromSpans(layer.spans), mask: null, undo: [], redo: [] };
    work.mask = makeMask(layer.spans, activeColor, cs, false);
    work.spans = layer.spans;
    shapeUndo = [];
    shapeRedo = [];
    activeShape = null;
    quadPoints = [];
    dragHandle = null;
    hoveredHandle = null;
    emitHistory();
  }
  function emitHistory() {
    historyState = { undo: work ? work.undo.length : 0, redo: work ? work.redo.length : 0, cells: work ? work.set.size : 0 };
    dispatch('history', historyState);
  }
  function commit() {
    if (!work) return;
    const spans = spansFromCells(work.set);
    work.spans = spans;
    dispatch('change', { territoryId: work.tid, layerKey: work.key, spans, cells: work.set.size });
    emitHistory();
  }
  function pushUndo() {
    if (!work) return;
    work.undo.push(JSON.stringify(spansFromCells(work.set)));
    if (work.undo.length > 40) work.undo.shift();
    work.redo = [];

    // Also push active shape snapshot
    shapeUndo.push(activeShape ? serializeShape(activeShape) : null);
    if (shapeUndo.length > 40) shapeUndo.shift();
    shapeRedo = [];
  }
  function serializeShape(s) {
    if (!s) return null;
    return {
      type: s.type,
      points: s.points ? s.points.map((p) => ({ x: p.x, y: p.y })) : null,
      center: s.center ? { x: s.center.x, y: s.center.y } : null,
      radius: s.radius,
      radiusMetres: s.radiusMetres,
      baseSetKeys: Array.from(s.baseSet || []),
    };
  }
  function deserializeShape(s) {
    if (!s) return null;
    return {
      type: s.type,
      points: s.points ? s.points.map((p) => ({ x: p.x, y: p.y })) : null,
      center: s.center ? { x: s.center.x, y: s.center.y } : null,
      radius: s.radius,
      radiusMetres: s.radiusMetres,
      baseSet: new Set(s.baseSetKeys || []),
    };
  }

  function restore(json) {
    const spans = JSON.parse(json);
    work.set = cellsFromSpans(spans);
    work.mask = makeMask(spans, work.color, work.cs, false);
  }
  export function undo() {
    if (!work || !work.undo.length) return;
    work.redo.push(JSON.stringify(spansFromCells(work.set)));
    restore(work.undo.pop());

    if (shapeUndo.length) {
      shapeRedo.push(activeShape ? serializeShape(activeShape) : null);
      activeShape = deserializeShape(shapeUndo.pop());
    }

    quadPoints = [];
    dragHandle = null;
    hoveredHandle = null;
    commit(); draw();
  }
  export function redo() {
    if (!work || !work.redo.length) return;
    work.undo.push(JSON.stringify(spansFromCells(work.set)));
    restore(work.redo.pop());

    if (shapeRedo.length) {
      shapeUndo.push(activeShape ? serializeShape(activeShape) : null);
      activeShape = deserializeShape(shapeRedo.pop());
    }

    quadPoints = [];
    dragHandle = null;
    hoveredHandle = null;
    commit(); draw();
  }
  export function clearLayer() {
    if (!work || !work.set.size) return;
    pushUndo();
    work.set = new Set();
    work.mask = makeMask([], work.color, work.cs, false);
    activeShape = null;
    quadPoints = [];
    dragHandle = null;
    hoveredHandle = null;
    commit(); draw();
  }

  // (Re)start the session whenever the paint target changes
  let sessionKey = '';
  $: {
    const key = editing ? `${selectedId}|${activeLayerKey}` : '';
    if (key !== sessionKey) {
      sessionKey = key;
      quadPoints = [];
      activeShape = null;
      dragHandle = null;
      hoveredHandle = null;
      if (editing) startSession(); else work = null;
      if (ready) { applyInteractionMode(); scheduleDraw(); }
    }
  }

  // Synchronize color when territory color changes from props
  $: if (work && selectedId) {
    const a = area();
    if (a && a.color && a.color !== work.color) {
      work.color = a.color;
      activeColor = a.color;
      work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
      if (ready) scheduleDraw();
    }
  }

  // ── Leaflet plumbing ──────────────────────────────────────────────────────────
  const project = (x, y) => map.latLngToContainerPoint(L.latLng(y, x));
  const toWorld = (px, py) => { const ll = map.containerPointToLatLng(L.point(px, py)); return { x: ll.lng, y: ll.lat }; };
  const pxPerMeter = () => {
    const a = project(0, 0), b = project(100, 0);
    return Math.abs(b.x - a.x) / 100;
  };

  export function zoomIn() { if (map) map.zoomIn(); }
  export function zoomOut() { if (map) map.zoomOut(); }
  export function zoomInToMin() { if (map) map.setZoom(MIN_EXPANSION_ZOOM); }

  export function selectTool(t) {
    tool = t;
    quadPoints = [];
    stroke = null;
    dragHandle = null;
    hoveredHandle = null;
    applyInteractionMode();
    scheduleDraw();
    dispatch('toolChange', { tool: t });
  }

  function onColorChange(e) {
    let val = (e?.target?.value || activeColor || '').trim();
    if (!val.startsWith('#') && val.length === 6) val = '#' + val;
    if (/^#[0-9a-fA-F]{6}$/i.test(val)) {
      activeColor = val;
      if (work) {
        work.color = activeColor;
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
      }
      const a = area();
      if (a) a.color = activeColor;
      dispatch('colorChange', { territoryId: work?.tid || selectedId, color: activeColor });
      scheduleDraw();
    }
  }

  function applyInteractionMode() {
    if (!map || !canvas) return;
    const isDrawingTool = editing && ['brush', 'line', 'rect', 'square', 'circle', 'poly4', 'eraser', 'logo'].includes(tool) && !spaceDown;
    canvas.style.pointerEvents = isDrawingTool ? 'auto' : 'none';
    if (!isDrawingTool) {
      canvas.style.cursor = '';
      map.dragging.enable();
      return;
    }
    map.dragging.disable();
    if (hoveredHandle) {
      canvas.style.cursor = dragHandle ? 'grabbing' : 'grab';
    } else if (tool === 'brush' || tool === 'eraser') {
      canvas.style.cursor = 'none'; // custom circular cursor drawn in draw()
    } else if (tool === 'logo') {
      canvas.style.cursor = 'move';
    } else {
      canvas.style.cursor = 'crosshair';
    }
  }
  $: if (ready) { tool; editing; applyInteractionMode(); scheduleDraw(); }

  // A map mounted while hidden (sub-tab, collapsed panel) starts at 0×0, so
  // its first fit lands on nothing; re-fit the first time it gets a real size.
  let atlasBounds = null;
  let hadSize = false;
  function resizeCanvas() {
    if (!canvas || !container) return;
    dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = container.clientWidth, h = container.clientHeight;
    canvas.width = Math.max(1, Math.round(w * dpr));
    canvas.height = Math.max(1, Math.round(h * dpr));
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';
    ctx = canvas.getContext('2d');
    if (map) map.invalidateSize(false);
    // zoom-out stops at "whole map fills the box", not a thumbnail at atlas zoom 0
    if (map && atlasBounds && w > 0 && h > 0) map.setMinZoom(Math.max(ATLAS_MIN_ZOOM, map.getBoundsZoom(atlasBounds, true)));
    if (map && w > 0 && h > 0 && !hadSize) { hadSize = true; fitAll(); }
    scheduleDraw();
  }

  // Leaflet caches its size at creation and ignores invalidateSize() until it
  // has a view, so a map created inside a hidden panel stayed blank. The map
  // is now only created once its box has a real size.
  let waitObs = null;
  onMount(async () => {
    const leaflet = await import('leaflet');
    await import('leaflet/dist/leaflet.css');
    L = leaflet.default || leaflet;
    if (container.clientWidth > 0 && container.clientHeight > 0) { initMap(); return; }
    waitObs = new ResizeObserver(() => {
      if (container.clientWidth > 0 && container.clientHeight > 0) {
        waitObs.disconnect();
        waitObs = null;
        initMap();
      }
    });
    waitObs.observe(container);
  });

  function initMap() {
    if (map) return;
    const AtlasCRS = createAtlasCRS(L);
    map = L.map(container, {
      crs: AtlasCRS, minZoom: ATLAS_MIN_ZOOM, maxZoom: ATLAS_MAX_ZOOM, zoomSnap: 0, zoomDelta: 0.5, wheelPxPerZoomLevel: 90,
      attributionControl: false, doubleClickZoom: false, boxZoom: false,
    });
    const bounds = L.latLngBounds(map.unproject([0, ATLAS_TILE_SIZE], ATLAS_MAX_ZOOM), map.unproject([ATLAS_TILE_SIZE, 0], ATLAS_MAX_ZOOM));
    L.tileLayer(ATLAS_TILE_URL, { bounds, minZoom: ATLAS_MIN_ZOOM, maxZoom: ATLAS_MAX_ZOOM, noWrap: true }).addTo(map);
    map.setMaxBounds(bounds.pad(0.25));
    atlasBounds = bounds;
    map.fitBounds(bounds); // box is visible by the time initMap runs

    canvas = document.createElement('canvas');
    canvas.className = 'territory-paint';
    canvas.style.cssText = 'position:absolute;left:0;top:0;z-index:450;pointer-events:none;touch-action:none;';
    container.appendChild(canvas);

    const onMapMove = () => {
      if (map) currentZoom = map.getZoom();
      scheduleDraw();
    };
    map.on('move zoom zoomanim zoomend moveend viewreset resize', onMapMove);
    map.on('click', onMapClick);
    canvas.addEventListener('pointerdown', onPointerDown);
    canvas.addEventListener('pointermove', onPointerMove);
    canvas.addEventListener('pointerup', onPointerUp);
    canvas.addEventListener('pointerleave', () => { hover = null; hoveredHandle = null; scheduleDraw(); });
    canvas.addEventListener('pointercancel', onPointerUp);

    resizeObs = new ResizeObserver(resizeCanvas);
    resizeObs.observe(container);
    resizeCanvas();
    ready = true;
    applyInteractionMode();
    fitAll();
    dispatch('ready');
  }

  onDestroy(() => {
    cancelAnimationFrame(raf); clearTimeout(blinkRaf);
    if (waitObs) waitObs.disconnect();
    if (resizeObs) resizeObs.disconnect();
    if (map) map.remove();
  });

  export function fitAll() {
    if (!map) return;
    const pts = [];
    for (const t of territories) {
      let found = false;
      for (const l of t.layers || []) {
        const c = centroid(t.cs || 25, l.spans);
        if (c) { pts.push(L.latLng(c.y, c.x)); found = true; }
      }
      if (!found) {
        if (t.ped?.x != null) pts.push(L.latLng(t.ped.y, t.ped.x));
        else if (t.location?.x != null) pts.push(L.latLng(t.location.y, t.location.x));
        else if (t.center?.x != null) pts.push(L.latLng(t.center.y, t.center.x));
      }
    }
    for (const m of markers) if (m.x != null) pts.push(L.latLng(m.y, m.x));
    if (pts.length === 1) map.setView(pts[0], ATLAS_MAX_ZOOM - 1.5);
    else if (pts.length > 1) map.fitBounds(L.latLngBounds(pts), { padding: [80, 80], maxZoom: ATLAS_MAX_ZOOM - 1 });
    else if (atlasBounds) map.fitBounds(atlasBounds); // nothing placed yet → whole map
  }
  export function focusTerritory(id) {
    if (!map) return;
    const t = territories.find((x) => x.id === id);
    if (!t) return;
    const c = centroid(t.cs || 25, ...(t.layers || []).filter((l) => l.unlocked || mode === 'edit').map((l) => l.spans));
    const pos = c || t.ped || t.location || t.center;
    if (pos && pos.x != null) map.setView(L.latLng(pos.y, pos.x), Math.max(map.getZoom(), ATLAS_MAX_ZOOM - 2.2), { animate: true });
  }
  export function focusPoint(x, y, zoom) {
    if (map && x != null) map.setView(L.latLng(y, x), zoom ?? ATLAS_MAX_ZOOM - 1.5, { animate: true });
  }

  // ── hit testing / selection ───────────────────────────────────────────────────
  function hitTest(wx, wy) {
    for (let i = territories.length - 1; i >= 0; i--) {
      const t = territories[i];
      const cs = t.cs || 25;
      const ix = Math.floor(wx / cs), iy = Math.floor(wy / cs);
      const k = cellKey(ix, iy);
      for (const l of t.layers || []) {
        if (!l.unlocked && mode !== 'edit' && !showLocked) continue;
        if (work && work.tid === t.id && work.key === l.key) { if (work.set.has(k)) return t.id; continue; }
        const m = maskFor(t, l);
        if (m.set && m.set.has(k) && (l.unlocked || mode === 'edit' || showLocked)) return t.id;
      }
    }
    return null;
  }

  function onMapClick(e) {
    if (!e || !e.latlng) return;
    const wx = e.latlng.lng, wy = e.latlng.lat;
    if (pickMode) { dispatch('pick', { x: Number(wx.toFixed(2)), y: Number(wy.toFixed(2)) }); return; }
    if (editing && (tool === 'brush' || tool === 'eraser' || tool === 'poly4' || tool === 'line' || tool === 'rect' || tool === 'square' || tool === 'circle')) return;
    const id = hitTest(wx, wy);
    dispatch('select', { id });
    dispatch('mapClick', { x: Number(wx.toFixed(2)), y: Number(wy.toFixed(2)) });
  }

  // ── hit testing control points ────────────────────────────────────────────────
  function findControlPointHit(screenX, screenY) {
    if (!activeShape || !map) return null;
    const threshold = 15; // px hit area
    if (activeShape.type === 'quad' && activeShape.points) {
      for (let i = 0; i < activeShape.points.length; i++) {
        const pt = activeShape.points[i];
        const sp = project(pt.x, pt.y);
        if (Math.hypot(sp.x - screenX, sp.y - screenY) <= threshold) {
          return { type: 'quad', index: i, point: pt };
        }
      }
    } else if (activeShape.type === 'line' && activeShape.points) {
      for (let i = 0; i < activeShape.points.length; i++) {
        const pt = activeShape.points[i];
        const sp = project(pt.x, pt.y);
        if (Math.hypot(sp.x - screenX, sp.y - screenY) <= threshold) {
          return { type: 'line', index: i, point: pt };
        }
      }
    } else if (activeShape.type === 'circle' && activeShape.center) {
      const sc = project(activeShape.center.x, activeShape.center.y);
      if (Math.hypot(sc.x - screenX, sc.y - screenY) <= threshold) {
        return { type: 'circle-center' };
      }
      const sr = project(activeShape.center.x + activeShape.radius, activeShape.center.y);
      if (Math.hypot(sr.x - screenX, sr.y - screenY) <= threshold) {
        return { type: 'circle-radius' };
      }
    }
    return null;
  }

  // Radially sorts 4 points around their centroid to prevent self-intersecting bowties
  function orientQuad(pts) {
    if (pts.length !== 4) return pts;
    const cx = (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4;
    const cy = (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4;
    return [...pts].sort((a, b) => Math.atan2(a.y - cy, a.x - cx) - Math.atan2(b.y - cy, b.x - cx));
  }

  // ── pointer handlers ──────────────────────────────────────────────────────────
  function pointerWorld(e) {
    const r = canvas.getBoundingClientRect();
    return { px: e.clientX - r.left, py: e.clientY - r.top, ...toWorld(e.clientX - r.left, e.clientY - r.top) };
  }

  function onPointerDown(e) {
    if (!editing || !work || e.button !== 0) return;
    if (!isAdmin && map && map.getZoom() < MIN_EXPANSION_ZOOM) {
      dispatch('note', { text: `Zoom in closer to expand territory! You are at zoom ${map.getZoom().toFixed(1)} (minimum required: ${MIN_EXPANSION_ZOOM}).` });
      scheduleDraw();
      return;
    }
    const p = pointerWorld(e);

    // 1. Check if user clicked an existing control handle
    const handleHit = findControlPointHit(p.px, p.py);
    if (handleHit) {
      pushUndo();
      dragHandle = handleHit;
      canvas.setPointerCapture(e.pointerId);
      applyInteractionMode();
      scheduleDraw();
      return;
    }

    canvas.setPointerCapture(e.pointerId);

    if (tool === 'logo') {
      stroke = { logo: true };
      dispatch('imageMove', { territoryId: work.tid, x: Math.round(p.x), y: Math.round(p.y) });
      return;
    }

    // 2. Four-Point Territory tool
    if (tool === 'poly4') {
      quadPoints = [...quadPoints, { x: p.x, y: p.y }];
      if (quadPoints.length >= 4) {
        const pts = orientQuad(quadPoints);
        quadPoints = [];
        pushUndo();
        activeShape = {
          type: 'quad',
          points: pts,
          baseSet: new Set(work.set),
        };
        const rgb = hexToRgb(work.color);
        const changed = fillPolygon(work.set, pts, work.cs, true, (ix, iy, added) => paintCell(work.mask, ix, iy, added, rgb));
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
        commit();
        emitHistory();
        dispatch('note', { text: `Created 4-point territory (${changed.toLocaleString()} cells) — drag any corner point to modify` });
      }
      scheduleDraw();
      return;
    }

    // 3. Rectangle tool
    if (tool === 'rect') {
      stroke = { type: 'rect', startX: p.x, startY: p.y, curX: p.x, curY: p.y };
      scheduleDraw();
      return;
    }

    // 4. Square tool
    if (tool === 'square') {
      stroke = { type: 'square', startX: p.x, startY: p.y, curX: p.x, curY: p.y };
      scheduleDraw();
      return;
    }

    // 5. Circle tool
    if (tool === 'circle') {
      stroke = { type: 'circle', startX: p.x, startY: p.y, curX: p.x, curY: p.y };
      scheduleDraw();
      return;
    }

    // 6. Straight Line tool
    if (tool === 'line') {
      stroke = { type: 'line', startX: p.x, startY: p.y, curX: p.x, curY: p.y };
      scheduleDraw();
      return;
    }

    // 7. Freehand Brush / Eraser
    const add = tool !== 'eraser';
    pushUndo();
    stroke = { type: tool, add, lastX: p.x, lastY: p.y, changed: 0 };
    stampTo(p.x, p.y, p.x, p.y);
    scheduleDraw();
  }

  function onPointerMove(e) {
    if (!canvas) return;
    const p = pointerWorld(e);
    hover = { px: p.px, py: p.py, x: p.x, y: p.y };

    // Dragging an existing control handle
    if (dragHandle && activeShape && work) {
      if (dragHandle.type === 'quad') {
        activeShape.points[dragHandle.index] = { x: p.x, y: p.y };
        work.set = new Set(activeShape.baseSet);
        fillPolygon(work.set, activeShape.points, work.cs, true);
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
      } else if (dragHandle.type === 'line') {
        activeShape.points[dragHandle.index] = { x: p.x, y: p.y };
        work.set = new Set(activeShape.baseSet);
        strokeSegment(work.set, activeShape.points[0].x, activeShape.points[0].y, activeShape.points[1].x, activeShape.points[1].y, activeShape.radiusMetres, work.cs, true);
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
      } else if (dragHandle.type === 'circle-center') {
        activeShape.center = { x: p.x, y: p.y };
        work.set = new Set(activeShape.baseSet);
        fillCircle(work.set, activeShape.center.x, activeShape.center.y, activeShape.radius, work.cs, true);
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
      } else if (dragHandle.type === 'circle-radius') {
        activeShape.radius = Math.max(work.cs, Math.hypot(p.x - activeShape.center.x, p.y - activeShape.center.y));
        work.set = new Set(activeShape.baseSet);
        fillCircle(work.set, activeShape.center.x, activeShape.center.y, activeShape.radius, work.cs, true);
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
      }
      scheduleDraw();
      return;
    }

    // Checking hover state over control points
    if (!stroke) {
      const hit = findControlPointHit(p.px, p.py);
      if (hit !== hoveredHandle) {
        hoveredHandle = hit;
        applyInteractionMode();
      }
    }

    // Live preview during tool drag
    if (stroke && work) {
      if (stroke.logo) {
        dispatch('imageMove', { territoryId: work.tid, x: Math.round(p.x), y: Math.round(p.y) });
      } else if (stroke.type === 'rect' || stroke.type === 'square' || stroke.type === 'circle' || stroke.type === 'line') {
        stroke.curX = p.x;
        stroke.curY = p.y;
      } else {
        stampTo(stroke.lastX, stroke.lastY, p.x, p.y);
        stroke.lastX = p.x; stroke.lastY = p.y;
        commit();
      }
    }
    scheduleDraw();
  }

  function onPointerUp(e) {
    if (dragHandle) {
      try { canvas.releasePointerCapture(e.pointerId); } catch (err) {}
      dragHandle = null;
      commit();
      emitHistory();
      applyInteractionMode();
      scheduleDraw();
      return;
    }

    if (!stroke) return;
    try { canvas.releasePointerCapture(e.pointerId); } catch (err) {}

    // Complete Rectangle drag creation -> converts to editable 4-point quadrilateral
    if (stroke.type === 'rect' && work) {
      const x0 = stroke.startX, y0 = stroke.startY, x1 = stroke.curX, y1 = stroke.curY;
      stroke = null;
      if (Math.hypot(x1 - x0, y1 - y0) > (work.cs * 0.4)) {
        pushUndo();
        const minX = Math.min(x0, x1), maxX = Math.max(x0, x1);
        const minY = Math.min(y0, y1), maxY = Math.max(y0, y1);
        const pts = [
          { x: minX, y: minY },
          { x: maxX, y: minY },
          { x: maxX, y: maxY },
          { x: minX, y: maxY },
        ];
        activeShape = {
          type: 'quad',
          points: pts,
          baseSet: new Set(work.set),
        };
        const rgb = hexToRgb(work.color);
        const changed = fillPolygon(work.set, pts, work.cs, true, (ix, iy, added) => paintCell(work.mask, ix, iy, added, rgb));
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
        commit();
        emitHistory();
        dispatch('note', { text: `Rectangle created (${changed.toLocaleString()} cells) — all 4 corners are editable` });
      }
      scheduleDraw();
      return;
    }

    // Complete Square drag creation -> converts to editable 4-point quadrilateral
    if (stroke.type === 'square' && work) {
      const x0 = stroke.startX, y0 = stroke.startY;
      const side = Math.max(Math.abs(stroke.curX - x0), Math.abs(stroke.curY - y0));
      const sx = stroke.curX >= x0 ? 1 : -1;
      const sy = stroke.curY >= y0 ? 1 : -1;
      const x1 = x0 + sx * side, y1 = y0 + sy * side;
      stroke = null;
      if (side > (work.cs * 0.4)) {
        pushUndo();
        const minX = Math.min(x0, x1), maxX = Math.max(x0, x1);
        const minY = Math.min(y0, y1), maxY = Math.max(y0, y1);
        const pts = [
          { x: minX, y: minY },
          { x: maxX, y: minY },
          { x: maxX, y: maxY },
          { x: minX, y: maxY },
        ];
        activeShape = {
          type: 'quad',
          points: pts,
          baseSet: new Set(work.set),
        };
        const rgb = hexToRgb(work.color);
        const changed = fillPolygon(work.set, pts, work.cs, true, (ix, iy, added) => paintCell(work.mask, ix, iy, added, rgb));
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
        commit();
        emitHistory();
        dispatch('note', { text: `Square created (${changed.toLocaleString()} cells) — all 4 corners are editable` });
      }
      scheduleDraw();
      return;
    }

    // Complete Circle drag creation -> remains editable with center & radius handles
    if (stroke.type === 'circle' && work) {
      const cx = stroke.startX, cy = stroke.startY;
      const r = Math.hypot(stroke.curX - cx, stroke.curY - cy);
      stroke = null;
      if (r > (work.cs * 0.4)) {
        pushUndo();
        activeShape = {
          type: 'circle',
          center: { x: cx, y: cy },
          radius: r,
          baseSet: new Set(work.set),
        };
        const rgb = hexToRgb(work.color);
        const changed = fillCircle(work.set, cx, cy, r, work.cs, true, (ix, iy, added) => paintCell(work.mask, ix, iy, added, rgb));
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
        commit();
        emitHistory();
        dispatch('note', { text: `Circle created (${changed.toLocaleString()} cells) — center & radius handles editable` });
      }
      scheduleDraw();
      return;
    }

    // Complete Line drag creation -> remains editable straight line with 2 draggable endpoints
    if (stroke.type === 'line' && work) {
      const x0 = stroke.startX, y0 = stroke.startY, x1 = stroke.curX, y1 = stroke.curY;
      stroke = null;
      const dist = Math.hypot(x1 - x0, y1 - y0);
      if (dist > (work.cs * 0.4)) {
        pushUndo();
        const radMetres = Math.max(work.cs * 0.5, Number(brushMetres) || Number(brushRadius) || 25);
        activeShape = {
          type: 'line',
          points: [{ x: x0, y: y0 }, { x: x1, y: y1 }],
          radiusMetres: radMetres,
          baseSet: new Set(work.set),
        };
        const rgb = hexToRgb(work.color);
        const changed = strokeSegment(work.set, x0, y0, x1, y1, radMetres, work.cs, true, (ix, iy, added) => paintCell(work.mask, ix, iy, added, rgb));
        work.mask = makeMask(spansFromCells(work.set), work.color, work.cs, false);
        commit();
        emitHistory();
        dispatch('note', { text: `Straight line created (${changed.toLocaleString()} cells) — endpoints are editable` });
      }
      scheduleDraw();
      return;
    }

    const wasPaint = !stroke.logo;
    const changed = stroke.changed || 0;
    stroke = null;
    if (wasPaint) {
      if (!changed) { work.undo.pop(); shapeUndo.pop(); }
      else commit();
      emitHistory();
    }
  }

  // Freehand Brush stamp
  function stampTo(x0, y0, x1, y1) {
    const rgb = hexToRgb(work.color);
    const add = stroke.add;
    if (add && work.set.size >= maxCells) { dispatch('limit', { max: maxCells }); return; }
    const radMetres = Math.max(work.cs * 0.5, Number(brushMetres) || Number(brushRadius) || 25);
    stroke.changed += strokeSegment(work.set, x0, y0, x1, y1, radMetres, work.cs, add, (ix, iy, added) => paintCell(work.mask, ix, iy, added, rgb));
  }

  function onKey(e) {
    if (!editing) return;
    const tag = (e.target && e.target.tagName) || '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (e.target && e.target.isContentEditable)) return;

    if (tool === 'poly4') {
      if (e.key === 'Backspace' && quadPoints.length > 0) {
        quadPoints.pop();
        quadPoints = [...quadPoints];
        scheduleDraw();
        e.preventDefault();
        return;
      }
      if (e.key === 'Escape') {
        quadPoints = [];
        scheduleDraw();
        e.preventDefault();
        return;
      }
    }

    if (e.code === 'Space') { if (!spaceDown) { spaceDown = true; applyInteractionMode(); } e.preventDefault(); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') { e.preventDefault(); if (e.shiftKey) redo(); else undo(); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'y') { e.preventDefault(); redo(); }
    else if (e.key === '[') { brushPx = Math.max(4, brushPx - 2); scheduleDraw(); }
    else if (e.key === ']') { brushPx = Math.min(80, brushPx + 2); scheduleDraw(); }
  }
  function onKeyUp(e) {
    if (e.code === 'Space' && spaceDown) { spaceDown = false; applyInteractionMode(); }
  }

  // ── drawing ───────────────────────────────────────────────────────────────────
  const images = new Map();
  function imageFor(url) {
    if (!url) return null;
    let im = images.get(url);
    if (!im) {
      im = new Image();
      im.onload = scheduleDraw;
      im.src = url;
      images.set(url, im);
    }
    return im.complete && im.naturalWidth ? im : null;
  }

  let scratch;
  function scratchCanvas(w, h) {
    if (!scratch) scratch = document.createElement('canvas');
    if (scratch.width < w) scratch.width = w;
    if (scratch.height < h) scratch.height = h;
    return scratch;
  }

  function drawLayer(c, mask, style, W, H) {
    if (!mask.canvas) return;
    const cs = mask.cs;
    const tl = project(mask.ix0 * cs, (mask.iy0 + mask.h) * cs);
    const br = project((mask.ix0 + mask.w) * cs, mask.iy0 * cs);
    const dx = tl.x, dy = tl.y, dw = br.x - tl.x, dh = br.y - tl.y;
    if (dw < 0.5 || dh < 0.5 || dx > W || dy > H || dx + dw < 0 || dy + dh < 0) return;
    const cellPx = dw / mask.w;
    c.imageSmoothingEnabled = cellPx < 10;
    const vx0 = Math.max(0, dx), vy0 = Math.max(0, dy), vx1 = Math.min(W, dx + dw), vy1 = Math.min(H, dy + dh);
    const sx = ((vx0 - dx) / dw) * mask.w, sy = ((vy0 - dy) / dh) * mask.h;
    const sw = ((vx1 - vx0) / dw) * mask.w, sh = ((vy1 - vy0) / dh) * mask.h;
    const vw = vx1 - vx0, vh = vy1 - vy0;
    if (vw < 1 || vh < 1 || sw <= 0 || sh <= 0) return;

    const e = style.edge;
    if (e > 0 && style.edgeAlpha > 0) {
      const m = Math.ceil(e) + 1;
      const sc = scratchCanvas(Math.ceil(vw) + m * 2, Math.ceil(vh) + m * 2);
      const s = sc.getContext('2d');
      s.setTransform(1, 0, 0, 1, 0, 0);
      s.clearRect(0, 0, Math.ceil(vw) + m * 2, Math.ceil(vh) + m * 2);
      s.imageSmoothingEnabled = c.imageSmoothingEnabled;
      s.globalCompositeOperation = 'source-over';
      s.globalAlpha = 1;
      for (let a = 0; a < 8; a++) {
        const ox = Math.cos((a * Math.PI) / 4) * e, oy = Math.sin((a * Math.PI) / 4) * e;
        s.drawImage(mask.canvas, sx, sy, sw, sh, m + ox, m + oy, vw, vh);
      }
      s.globalCompositeOperation = 'destination-out';
      s.drawImage(mask.canvas, sx, sy, sw, sh, m, m, vw, vh);
      s.globalCompositeOperation = 'source-over';
      c.globalAlpha = style.edgeAlpha;
      c.drawImage(sc, 0, 0, vw + m * 2, vh + m * 2, vx0 - m, vy0 - m, vw + m * 2, vh + m * 2);
    }
    c.globalAlpha = style.fillAlpha;
    c.drawImage(mask.canvas, sx, sy, sw, sh, vx0, vy0, vw, vh);
    c.globalAlpha = 1;
  }

  function drawText(c, text, x, y, size, color, bold = true) {
    c.font = `${bold ? '700' : '500'} ${size}px Inter, "Segoe UI", sans-serif`;
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    c.lineWidth = Math.max(3, size * 0.28);
    c.strokeStyle = 'rgba(8,9,13,0.92)';
    c.strokeText(text, x, y);
    c.fillStyle = color;
    c.fillText(text, x, y);
  }

  function draw() {
    raf = 0;
    if (!ready || !ctx || !map) return;
    const W = container.clientWidth, H = container.clientHeight;
    if (!W || !H) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    const ppm = pxPerMeter();
    const now = performance.now();
    const pulse = 0.55 + 0.45 * Math.sin(now / 260);
    let animating = false;

    // Draw all territories
    for (const t of territories) {
      const isSel = t.id === selectedId;
      const dimOthers = mode === 'edit' && editing && selectedId && !isSel;
      let labelAt = null;
      for (const l of t.layers || []) {
        const isWork = work && work.tid === t.id && work.key === l.key;
        if (!l.unlocked && mode !== 'edit' && !showLocked) continue;
        const mask = isWork ? work.mask : maskFor(t, l);
        const ghost = !l.unlocked && mode !== 'edit';
        const isActive = mode === 'edit' && isSel && l.key === activeLayerKey;
        const style = ghost
          ? { fillAlpha: 0.14, edgeAlpha: 0.55, edge: 1.2 }
          : { fillAlpha: dimOthers ? 0.18 : (isActive ? 0.52 : (l.key === 'base' ? 0.44 : 0.36)), edgeAlpha: dimOthers ? 0.45 : 0.95, edge: isSel ? 2.4 : 1.7 };
        drawLayer(ctx, mask, style, W, H);
        if (isSel && blinkSelected && mode === 'view' && l.unlocked) {
          drawLayer(ctx, mask, { fillAlpha: 0.18 * pulse, edgeAlpha: pulse, edge: 4.2 }, W, H);
          animating = true;
        }
      }
      const lists = (t.layers || []).filter((l) => l.unlocked || mode === 'edit').map((l) => (work && work.tid === t.id && work.key === l.key ? (work.spans || l.spans) : l.spans));
      const c = centroid(t.cs || 25, ...lists);
      const pedPos = (t.ped && t.ped.x != null) ? t.ped : ((t.location && t.location.x != null) ? t.location : ((t.center && t.center.x != null) ? t.center : null));
      const anchor = (c && c.cells > 0) ? c : pedPos;
      if (anchor) {
        const p0 = project(anchor.x, anchor.y);
        labelAt = p0;
        const imgUrl = t.customLogo || t.image || t.logo;
        const useLogo = (t.spriteType === 'CUSTOM_LOGO' || (!t.spriteType && imgUrl)) && imgUrl;
        // The logo / badge sits on its own saved spot only when that is a small nudge from the territory (its land or leader ped).
        // A spot saved long ago far away (it showed a lone badge at the dam, with the name label back at the real place) is ignored.
        const ip = t.imagePos && t.imagePos.x != null ? t.imagePos : null;
        const ipNear = ip && Math.hypot(ip.x - anchor.x, ip.y - anchor.y) < 600;
        const pos = ipNear ? { x: ip.x, y: ip.y, size: ip.size || 200 } : { x: anchor.x, y: anchor.y, size: (ip && ip.size) || Math.max(120, Math.sqrt(anchor.cells || 4) * (t.cs || 25) * 0.45) };
        const lp = project(pos.x, pos.y);
        const lpx = Math.max(26, pos.size * ppm);
        if (useLogo && lpx >= 14 && lp.x > -lpx && lp.x < W + lpx && lp.y > -lpx && lp.y < H + lpx) {
          const im = imageFor(imgUrl);
          if (im) {
            ctx.save();
            ctx.globalAlpha = dimOthers ? 0.35 : 0.95;
            ctx.beginPath(); ctx.arc(lp.x, lp.y, lpx / 2, 0, Math.PI * 2); ctx.clip();
            ctx.drawImage(im, lp.x - lpx / 2, lp.y - lpx / 2, lpx, lpx);
            ctx.restore();
            ctx.beginPath(); ctx.arc(lp.x, lp.y, lpx / 2, 0, Math.PI * 2);
            ctx.lineWidth = isSel ? 3.5 : 2; ctx.strokeStyle = t.color; ctx.globalAlpha = 0.95; ctx.stroke(); ctx.globalAlpha = 1;
          }
          if (mode === 'edit' && isSel && tool === 'logo') { ctx.beginPath(); ctx.arc(lp.x, lp.y, lpx / 2 + 4, 0, Math.PI * 2); ctx.setLineDash([6, 5]); ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.stroke(); ctx.setLineDash([]); }
        } else if (!useLogo && lp.x > -30 && lp.x < W + 30 && lp.y > -30 && lp.y < H + 30) {
          // GTA Sprite Blip Badge based on Leader Ped anchor
          ctx.save();
          ctx.globalAlpha = dimOthers ? 0.4 : 1;
          const badgeR = isSel ? 13 : 10;
          ctx.beginPath(); ctx.arc(lp.x, lp.y, badgeR, 0, Math.PI * 2);
          ctx.fillStyle = '#141622'; ctx.fill();
          ctx.lineWidth = isSel ? 3 : 2; ctx.strokeStyle = t.color; ctx.stroke();
          ctx.beginPath(); ctx.arc(lp.x, lp.y, badgeR * 0.55, 0, Math.PI * 2);
          ctx.fillStyle = t.color; ctx.fill();
          ctx.restore();
        }
      }
      if (showLabels && labelAt && t.showName !== false && !dimOthers) {
        const sizePx = Math.sqrt((anchor ? anchor.cells || 10 : 0)) * (t.cs || 25) * ppm;
        if (sizePx > 30 || isSel || !c) {
          const base = Math.max(12, Math.min(20, Math.max(13, sizePx / 8)));
          const dy = (t.customLogo || t.image || t.logo) ? Math.max(22, (t.imagePos?.size || 200) * ppm * 0.5 + 14) : 20;
          const primaryLabel = t.ownerLabel ? t.ownerLabel : t.name;
          const subLabel = t.ownerLabel ? `${t.name}${t.status ? ' · ' + t.status : ''}` : (t.status || 'Unclaimed');
          drawText(ctx, primaryLabel, labelAt.x, labelAt.y + dy, base, t.ownerLabel ? t.color : '#ffffff', true);
          if (sizePx > 50 || isSel || !c) {
            drawText(ctx, subLabel, labelAt.x, labelAt.y + dy + base + 3, Math.max(10, base * 0.72), '#cbd0de', false);
          }
        }
      }
      if (mode === 'view' && showLocked) {
        for (const l of t.layers || []) {
          if (l.unlocked || l.key === 'base') continue;
          const lc = centroid(t.cs || 25, l.spans);
          if (!lc) continue;
          const p1 = project(lc.x, lc.y);
          const displayLabel = t.ownerLabel ? `${t.ownerLabel} Expansion` : l.label;
          if (Math.sqrt(lc.cells) * (t.cs || 25) * ppm > 36) drawText(ctx, displayLabel + (l.xpCost ? ` · ${Number(l.xpCost).toLocaleString()} XP` : ''), p1.x, p1.y, 11, '#e2e6f0', false);
        }
      }

      // Draw gang symbol and gang name on the newly drawn territory
      if (editing && isSel && work && work.set && work.set.size > 0) {
        const drawC = centroid(work.cs, spansFromCells(work.set));
        if (drawC && drawC.cells > 0) {
          const dp = project(drawC.x, drawC.y);
          const drawLogoUrl = t.customLogo || t.image || t.logo;
          const logoImg = imageFor(drawLogoUrl);
          const badgeSize = Math.max(26, Math.min(52, Math.sqrt(drawC.cells) * (t.cs || 25) * ppm * 0.35));
          
          ctx.save();
          if (logoImg) {
            ctx.beginPath();
            ctx.arc(dp.x, dp.y - 12, badgeSize / 2, 0, Math.PI * 2);
            ctx.clip();
            ctx.drawImage(logoImg, dp.x - badgeSize / 2, dp.y - 12 - badgeSize / 2, badgeSize, badgeSize);
            ctx.restore();
            ctx.save();
            ctx.beginPath();
            ctx.arc(dp.x, dp.y - 12, badgeSize / 2, 0, Math.PI * 2);
            ctx.lineWidth = 2.5;
            ctx.strokeStyle = work.color;
            ctx.stroke();
          } else {
            // Stylized Gang Crest Badge
            ctx.beginPath();
            ctx.arc(dp.x, dp.y - 12, badgeSize / 2, 0, Math.PI * 2);
            ctx.fillStyle = '#141622';
            ctx.fill();
            ctx.lineWidth = 2.5;
            ctx.strokeStyle = work.color;
            ctx.stroke();
            ctx.beginPath();
            ctx.arc(dp.x, dp.y - 12, badgeSize * 0.35, 0, Math.PI * 2);
            ctx.fillStyle = work.color;
            ctx.fill();
          }
          
          // Display actual Gang Name visually on the newly drawn territory
          const gangDisplayName = gangLabel || t.ownerLabel || 'YOUR GANG';
          drawText(ctx, gangDisplayName, dp.x, dp.y + badgeSize / 2 + 5, 13, work.color, true);
          ctx.restore();
        }
      }
    }

    // Markers
    for (const m of markers) {
      if (m.x == null) continue;
      const p = project(m.x, m.y);
      if (p.x < -20 || p.y < -20 || p.x > W + 20 || p.y > H + 20) continue;
      ctx.beginPath(); ctx.arc(p.x, p.y, 7, 0, Math.PI * 2);
      ctx.fillStyle = m.color || '#ffc857'; ctx.fill(); ctx.lineWidth = 2; ctx.strokeStyle = '#0b0b0b'; ctx.stroke();
      if (m.label) drawText(ctx, m.label, p.x, p.y - 16, 11, '#ffffff', true);
    }

    // ── Vector Shape: Active Quadrilateral (4 Points, Rectangle, Square) ───────
    if (editing && activeShape && work) {
      if (activeShape.type === 'quad' && activeShape.points) {
        ctx.save();
        ctx.beginPath();
        const p0 = project(activeShape.points[0].x, activeShape.points[0].y);
        ctx.moveTo(p0.x, p0.y);
        for (let i = 1; i < activeShape.points.length; i++) {
          const pi = project(activeShape.points[i].x, activeShape.points[i].y);
          ctx.lineTo(pi.x, pi.y);
        }
        ctx.closePath();

        // 1. Semi-transparent fill
        ctx.fillStyle = rgba(work.color, 0.35);
        ctx.fill();

        // 2. Strong solid boundary
        ctx.strokeStyle = work.color;
        ctx.lineWidth = 3;
        ctx.stroke();

        // 3. Subtle white dashed outline
        ctx.strokeStyle = '#ffffff';
        ctx.lineWidth = 1;
        ctx.setLineDash([4, 4]);
        ctx.stroke();
        ctx.setLineDash([]);

        // 4. Draggable control points
        for (let i = 0; i < activeShape.points.length; i++) {
          const pt = activeShape.points[i];
          const sp = project(pt.x, pt.y);
          const isHov = hoveredHandle && hoveredHandle.type === 'quad' && hoveredHandle.index === i;
          const isDrg = dragHandle && dragHandle.type === 'quad' && dragHandle.index === i;
          const r = isDrg ? 12 : (isHov ? 10.5 : 8);

          ctx.shadowColor = 'rgba(0, 0, 0, 0.85)';
          ctx.shadowBlur = isHov || isDrg ? 9 : 4;

          ctx.beginPath();
          ctx.arc(sp.x, sp.y, r, 0, Math.PI * 2);
          ctx.fillStyle = work.color;
          ctx.fill();

          ctx.lineWidth = isHov || isDrg ? 2.5 : 2;
          ctx.strokeStyle = '#ffffff';
          ctx.stroke();

          ctx.shadowBlur = 0;
          drawText(ctx, `#${i + 1}`, sp.x, sp.y - (r + 8), 10, '#ffffff', true);
        }
        ctx.restore();
      } else if (activeShape.type === 'line' && activeShape.points) {
        ctx.save();
        const p0 = project(activeShape.points[0].x, activeShape.points[0].y);
        const p1 = project(activeShape.points[1].x, activeShape.points[1].y);
        ctx.beginPath();
        ctx.moveTo(p0.x, p0.y);
        ctx.lineTo(p1.x, p1.y);
        ctx.strokeStyle = work.color;
        ctx.lineWidth = Math.max(3, activeShape.radiusMetres * 2 * ppm);
        ctx.lineCap = 'round';
        ctx.stroke();

        for (let i = 0; i < 2; i++) {
          const sp = i === 0 ? p0 : p1;
          const isHov = hoveredHandle && hoveredHandle.type === 'line' && hoveredHandle.index === i;
          const isDrg = dragHandle && dragHandle.type === 'line' && dragHandle.index === i;
          const r = isDrg ? 11 : (isHov ? 10 : 8);
          ctx.beginPath();
          ctx.arc(sp.x, sp.y, r, 0, Math.PI * 2);
          ctx.fillStyle = work.color;
          ctx.fill();
          ctx.lineWidth = 2;
          ctx.strokeStyle = '#ffffff';
          ctx.stroke();
        }
        ctx.restore();
      } else if (activeShape.type === 'circle' && activeShape.center) {
        ctx.save();
        const sc = project(activeShape.center.x, activeShape.center.y);
        const rPx = activeShape.radius * ppm;
        ctx.beginPath();
        ctx.arc(sc.x, sc.y, Math.max(1, rPx), 0, Math.PI * 2);
        ctx.fillStyle = rgba(work.color, 0.35);
        ctx.fill();
        ctx.strokeStyle = work.color;
        ctx.lineWidth = 3;
        ctx.stroke();

        // Center handle
        const isHovC = hoveredHandle && hoveredHandle.type === 'circle-center';
        const isDrgC = dragHandle && dragHandle.type === 'circle-center';
        ctx.beginPath();
        ctx.arc(sc.x, sc.y, isDrgC ? 11 : (isHovC ? 10 : 8), 0, Math.PI * 2);
        ctx.fillStyle = work.color;
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = '#ffffff';
        ctx.stroke();
        drawText(ctx, 'Center', sc.x, sc.y - 14, 10, '#ffffff', true);

        // Radius handle at 3 o'clock edge
        const sr = project(activeShape.center.x + activeShape.radius, activeShape.center.y);
        const isHovR = hoveredHandle && hoveredHandle.type === 'circle-radius';
        const isDrgR = dragHandle && dragHandle.type === 'circle-radius';
        ctx.beginPath();
        ctx.arc(sr.x, sr.y, isDrgR ? 11 : (isHovR ? 10 : 8), 0, Math.PI * 2);
        ctx.fillStyle = '#ffffff';
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = work.color;
        ctx.stroke();
        drawText(ctx, `${Math.round(activeShape.radius)}m`, sr.x + 16, sr.y, 10, '#ffffff', true);
        ctx.restore();
      }
    }

    // ── Previews while dragging to create shapes ─────────────────────────────────
    if (editing && stroke && work) {
      if (stroke.type === 'rect' || stroke.type === 'square') {
        const p0 = project(stroke.startX, stroke.startY);
        let p1;
        if (stroke.type === 'square') {
          const side = Math.max(Math.abs(stroke.curX - stroke.startX), Math.abs(stroke.curY - stroke.startY));
          const sx = stroke.curX >= stroke.startX ? 1 : -1;
          const sy = stroke.curY >= stroke.startY ? 1 : -1;
          p1 = project(stroke.startX + sx * side, stroke.startY + sy * side);
        } else {
          p1 = project(stroke.curX, stroke.curY);
        }
        const rx = Math.min(p0.x, p1.x), ry = Math.min(p0.y, p1.y);
        const rw = Math.abs(p1.x - p0.x), rh = Math.abs(p1.y - p0.y);
        ctx.save();
        ctx.fillStyle = rgba(work.color, 0.28);
        ctx.fillRect(rx, ry, rw, rh);
        ctx.strokeStyle = work.color;
        ctx.lineWidth = 2.5;
        ctx.strokeRect(rx, ry, rw, rh);
        ctx.setLineDash([5, 4]);
        ctx.strokeStyle = '#ffffff';
        ctx.strokeRect(rx, ry, rw, rh);
        ctx.setLineDash([]);
        const wm = Math.round(Math.abs(stroke.curX - stroke.startX));
        const hm = stroke.type === 'square' ? wm : Math.round(Math.abs(stroke.curY - stroke.startY));
        if (rw > 20 && rh > 14) {
          drawText(ctx, `${wm}m × ${hm}m`, rx + rw / 2, ry + rh / 2, 12, '#ffffff', true);
        }
        ctx.restore();
      } else if (stroke.type === 'circle') {
        const sc = project(stroke.startX, stroke.startY);
        const rWorld = Math.hypot(stroke.curX - stroke.startX, stroke.curY - stroke.startY);
        const rPx = rWorld * ppm;
        ctx.save();
        ctx.beginPath();
        ctx.arc(sc.x, sc.y, Math.max(1, rPx), 0, Math.PI * 2);
        ctx.fillStyle = rgba(work.color, 0.28);
        ctx.fill();
        ctx.strokeStyle = work.color;
        ctx.lineWidth = 2.5;
        ctx.stroke();
        ctx.setLineDash([5, 4]);
        ctx.strokeStyle = '#ffffff';
        ctx.stroke();
        ctx.setLineDash([]);
        if (rPx > 18) {
          drawText(ctx, `Radius: ${Math.round(rWorld)}m`, sc.x, sc.y, 12, '#ffffff', true);
        }
        ctx.restore();
      } else if (stroke.type === 'line') {
        const p0 = project(stroke.startX, stroke.startY);
        const p1 = project(stroke.curX, stroke.curY);
        ctx.save();
        ctx.beginPath();
        ctx.moveTo(p0.x, p0.y);
        ctx.lineTo(p1.x, p1.y);
        ctx.strokeStyle = work.color;
        ctx.lineWidth = 3;
        ctx.stroke();
        ctx.beginPath();
        ctx.arc(p0.x, p0.y, 6, 0, Math.PI * 2);
        ctx.arc(p1.x, p1.y, 6, 0, Math.PI * 2);
        ctx.fillStyle = work.color;
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 1.5;
        ctx.stroke();
        ctx.restore();
      }
    }

    // ── 4-Point shape tool point placement guides ────────────────────────────────
    if (editing && tool === 'poly4' && work) {
      if (quadPoints.length > 0) {
        ctx.save();
        ctx.beginPath();
        const start = project(quadPoints[0].x, quadPoints[0].y);
        ctx.moveTo(start.x, start.y);
        for (let i = 1; i < quadPoints.length; i++) {
          const pt = project(quadPoints[i].x, quadPoints[i].y);
          ctx.lineTo(pt.x, pt.y);
        }
        if (hover) {
          ctx.lineTo(hover.px, hover.py);
          if (quadPoints.length >= 2) {
            ctx.setLineDash([4, 4]);
            ctx.lineTo(start.x, start.y);
          }
        }
        ctx.strokeStyle = work.color;
        ctx.lineWidth = 2.5;
        ctx.stroke();
        ctx.setLineDash([]);

        for (let i = 0; i < quadPoints.length; i++) {
          const pt = project(quadPoints[i].x, quadPoints[i].y);
          ctx.beginPath();
          ctx.arc(pt.x, pt.y, 9, 0, Math.PI * 2);
          ctx.fillStyle = work.color;
          ctx.fill();
          ctx.strokeStyle = '#ffffff';
          ctx.lineWidth = 2;
          ctx.stroke();
          drawText(ctx, `#${i + 1}`, pt.x, pt.y, 10, '#ffffff', true);
        }
        ctx.restore();
      }
      if (hover && !spaceDown && !hoveredHandle) {
        const nextNum = quadPoints.length + 1;
        drawText(ctx, `Click point ${nextNum} of 4`, hover.px + 14, hover.py - 14, 11, '#ffffff', true);
      }
    }

    // ── Brush / Eraser circular cursor ──────────────────────────────────────────
    if (editing && hover && (tool === 'brush' || tool === 'eraser') && !spaceDown && !hoveredHandle) {
      const radMetres = Math.max(work ? work.cs * 0.5 : 12.5, Number(brushMetres) || Number(brushRadius) || 25);
      const curRadiusPx = Math.max(4, radMetres * ppm);
      ctx.save();
      ctx.beginPath();
      ctx.arc(hover.px, hover.py, curRadiusPx, 0, Math.PI * 2);
      ctx.lineWidth = 1.8;
      ctx.strokeStyle = tool === 'eraser' ? '#ff5d50' : (work?.color || '#ffffff');
      if (tool === 'eraser') ctx.setLineDash([4, 3]);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = tool === 'eraser' ? 'rgba(255,93,80,0.14)' : rgba(work?.color || '#ffffff', 0.22);
      ctx.fill();
      drawText(ctx, `${Math.round(radMetres)}m`, hover.px + curRadiusPx + 14, hover.py, 10, '#ffffff', true);
      ctx.restore();
    }

    // the selected territory pulses: about 12 redraws a second is plenty (it used to redraw every frame, for ever)
    if (animating && blinkSelected) blinkRaf = setTimeout(() => { blinkRaf = 0; scheduleDraw(); }, 80);
  }

  function scheduleDraw() {
    if (raf || !ready) return;
    raf = requestAnimationFrame(draw);
  }

  $: if (ready) { territories; selectedId; markers; showLabels; showLocked; mode; blinkSelected; scheduleDraw(); }
</script>

<svelte:window on:keydown={onKey} on:keyup={onKeyUp} />

<div class="territory-map-container" style={fill ? `height:${height};display:flex;flex-direction:column;` : ''}>
  {#if editing && showToolbar}
    <div class="map-toolbar">
      <!-- Drawing Tools -->
      <div class="tb-group tools">
        <button type="button" class="tb-btn" class:active={tool === 'brush'} on:click={() => selectTool('brush')} title="Freehand Brush">
          <Icon name="brush" size={16} />
          <span>Brush</span>
        </button>
        <button type="button" class="tb-btn" class:active={tool === 'line'} on:click={() => selectTool('line')} title="Straight Line">
          <Icon name="line" size={16} />
          <span>Line</span>
        </button>
        <button type="button" class="tb-btn" class:active={tool === 'rect'} on:click={() => selectTool('rect')} title="Rectangle (editable corners)">
          <Icon name="rect" size={16} />
          <span>Rectangle</span>
        </button>
        <button type="button" class="tb-btn" class:active={tool === 'square'} on:click={() => selectTool('square')} title="Square (editable corners)">
          <Icon name="square" size={16} />
          <span>Square</span>
        </button>
        <button type="button" class="tb-btn" class:active={tool === 'circle'} on:click={() => selectTool('circle')} title="Circle (editable size handle)">
          <Icon name="circle" size={16} />
          <span>Circle</span>
        </button>
        <button type="button" class="tb-btn" class:active={tool === 'poly4'} on:click={() => selectTool('poly4')} title="4-Point Territory (click 4 corners)">
          <Icon name="quad" size={16} />
          <span>4 Points</span>
        </button>
        <button type="button" class="tb-btn" class:active={tool === 'eraser'} on:click={() => selectTool('eraser')} title="Eraser">
          <Icon name="close" size={15} />
          <span>Eraser</span>
        </button>
      </div>

      <span class="tb-sep"></span>

      <!-- Color & Brush Size -->
      <div class="tb-group params">
        {#if isAdmin}
          <div class="tb-color" title="Select Territory Color">
            <span class="tb-lbl">Color</span>
            <label class="color-picker-label">
              <input type="color" bind:value={activeColor} on:input={onColorChange} />
              <span class="color-swatch-box" style="background:{activeColor}"></span>
            </label>
            <input type="text" class="hex-input" bind:value={activeColor} on:change={onColorChange} maxlength="7" spellcheck="false" />
          </div>
        {:else}
          <div class="tb-gang-badge" title="Assigned Gang Color">
            <span class="gang-swatch" style="background:{work?.color || activeColor}"></span>
            <span class="gang-tag">{gangLabel || area()?.name || 'Gang Color'}</span>
          </div>
        {/if}

        <div class="tb-brush" title="Brush Radius in Metres (affects freehand Brush & Line)">
          <span class="tb-lbl">RADIUS</span>
          <span class="bs-badge">{brushMetres}m</span>
          <input type="range" min="15" max="60" step="5" bind:value={brushMetres} />
        </div>
      </div>

      <span class="tb-sep"></span>

      <!-- History & Actions -->
      <div class="tb-group actions">
        <button type="button" class="tb-btn" disabled={!historyState.undo} on:click={undo} title="Undo (Ctrl+Z)" aria-label="Undo">
          <Icon name="undo" size={15} />
          <span>Undo</span>
        </button>
        <button type="button" class="tb-btn disabled-btn" disabled={!historyState.redo} on:click={redo} title="Redo (Ctrl+Y)" aria-label="Redo">
          <Icon name="redo" size={15} />
          <span>Redo</span>
        </button>
        <button type="button" class="tb-btn danger" disabled={!historyState.cells} on:click={clearLayer} title="Clear Area" aria-label="Clear the painted area">
          <Icon name="trash" size={15} />
          <span>Clear</span>
        </button>
      </div>

      <span class="tb-sep"></span>

      <!-- Zoom Controls -->
      <div class="tb-group zoom">
        <button type="button" class="tb-btn" on:click={zoomIn} title="Zoom In" aria-label="Zoom in">
          <Icon name="zoomIn" size={15} />
          <span>Zoom +</span>
        </button>
        <button type="button" class="tb-btn" on:click={zoomOut} title="Zoom Out" aria-label="Zoom out">
          <Icon name="zoomOut" size={15} />
          <span>Zoom -</span>
        </button>
      </div>
    </div>
  {/if}

  <div class="map-wrap" class:dim class:has-toolbar={editing && showToolbar} style="{fill ? 'flex:1 1 0;min-height:0;' : `height:${height}px;`} --map-b:{($adminPrefs.mapBrightness || 110) / 100};">
    <div class="map" bind:this={container}></div>
    {#if editing && !isAdmin && currentZoom < MIN_EXPANSION_ZOOM}
      <div class="zoom-lock-overlay">
        <div class="zlo-card">
          <div class="zlo-icon">🔍</div>
          <div class="zlo-title">Zoom In Required to Expand Territory</div>
          <div class="zlo-sub">
            To ensure fair expansion, gang territories must be painted at close zoom. Current: <b>{currentZoom.toFixed(1)}x</b> (Minimum: <b>{MIN_EXPANSION_ZOOM.toFixed(1)}x</b>).
          </div>
          <button type="button" class="zlo-btn" on:click={zoomInToMin}>
            Zoom In Now
          </button>
        </div>
      </div>
    {/if}
    {#if pickMode}<div class="pick-hint">Click the map to choose the location</div>{/if}
  </div>
</div>

<style>
  .territory-map-container {
    display: flex;
    flex-direction: column;
    width: 100%;
  }

  /* ── Map Editor Toolbar ────────────────────────────────────────────────────────
     One tidy palette: the drawing tools are a joined segmented control, colour and radius share one pill, undo / redo / clear and
     zoom are icon buttons (their tooltips name them). Surfaces use the theme's glass tokens. */
  .territory-map-container .map-toolbar { gap: 10px 12px; padding: 10px 14px; background: var(--glass-bar, var(--es-inset, #15171b)); }
  .tb-group.tools { display: inline-flex; gap: 0; flex-wrap: nowrap; border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); overflow: hidden; background: var(--es-raised, #1c1f24); }
  .tb-group.tools .tb-btn { border: 0; border-radius: 0; height: 36px; background: transparent; padding: 0 12px; }
  .tb-group.tools .tb-btn + .tb-btn { border-left: 1px solid var(--es-line, #2a2e35); }
  .tb-group.tools .tb-btn.active { background: var(--accent-primary); color: var(--on-accent, #fff); }
  .tb-group.actions, .tb-group.zoom { gap: 4px; }
  .tb-group.actions .tb-btn, .tb-group.zoom .tb-btn { width: 36px; height: 36px; padding: 0; justify-content: center; }
  .tb-group.actions .tb-btn span, .tb-group.zoom .tb-btn span { display: none; }
  .tb-group.params { gap: 0; border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); background: var(--es-raised, #1c1f24); height: 36px; align-items: stretch; }
  .tb-group.params > * { border: 0 !important; border-radius: 0 !important; background: transparent !important; height: 34px; }
  .tb-group.params > * + * { border-left: 1px solid var(--es-line, #2a2e35) !important; }
  .map-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    background: var(--es-inset, #15171b);
    border: 1px solid var(--tablet-border, var(--es-line, #2a2e35));
    border-bottom: none;
    border-radius: var(--r-panel) var(--r-panel) 0 0;
    padding: 8px 12px;
    user-select: none;
  }

  .tb-group {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }

  .tb-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 35px;
    padding: 0 11px;
    background: var(--es-raised, #1c1f24);
    border: 1px solid var(--es-line, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-c9ced4, #c9ced4);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }
  .tb-btn:hover:not(:disabled) {
    background: var(--es-card-hover, #272b31);
    border-color: var(--es-line-strong, #41455e);
    color: var(--lt-ffffff, #ffffff);
  }
  .tb-btn.active {
    background: var(--c-action);
    border-color: var(--accent-primary);
    color: var(--on-accent);
  }
  .tb-btn.danger:hover:not(:disabled) {
    background: rgba(255, 93, 80, 0.15);
    border-color: #ff5d50;
    color: #ff5d50;
  }
  .tb-btn:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  .tb-sep {
    width: 1px;
    height: 22px;
    background: var(--es-line, #2a2e35);
    margin: 0 3px;
  }

  .tb-lbl {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: #8d949c;
  }

  /* Color picker */
  .tb-color {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 35px;
    padding: 0 9px;
    background: var(--es-raised, #1c1f24);
    border: 1px solid var(--es-line, #2a2e35);
    border-radius: var(--r-ctl);
  }
  .color-picker-label {
    position: relative;
    width: 22px;
    height: 22px;
    cursor: pointer;
    display: inline-block;
  }
  .color-picker-label input[type='color'] {
    position: absolute;
    inset: 0;
    opacity: 0;
    cursor: pointer;
    width: 100%;
    height: 100%;
  }
  .color-swatch-box {
    display: block;
    width: 100%;
    height: 100%;
    border-radius: var(--r-tag);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.4);
    box-shadow: none;
  }
  .hex-input {
    width: 72px;
    height: 25px;
    background: var(--es-inset, #111316);
    border: 1px solid var(--es-line, #2a2e35);
    border-radius: var(--r-tag);
    color: var(--lt-ffffff, #ffffff);
    font-size: var(--fs-meta);
    font-family: var(--font-mono);
    font-weight: 600;
    text-align: center;
    outline: none;
    padding: 0 4px;
  }
  .hex-input:focus {
    border-color: var(--accent-primary);
  }

  /* Gang color badge (read-only for gang view) */
  .tb-gang-badge {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 35px;
    padding: 0 12px;
    background: var(--es-raised, #1c1f24);
    border: 1px solid var(--es-line, #2a2e35);
    border-radius: var(--r-tag);
  }
  .gang-swatch {
    width: 15px;
    height: 15px;
    border-radius: 50%;
    border: 1.5px solid rgba(var(--ink-rgb, 255, 255, 255), 0.4);
  }
  .gang-tag {
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--lt-c9ced4, #c9ced4);
  }

  /* Brush size control */
  .tb-brush {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    height: 35px;
    padding: 0 11px;
    background: var(--es-raised, #1c1f24);
    border: 1px solid var(--es-line, #2a2e35);
    border-radius: var(--r-ctl);
  }
  .bs-badge {
    min-width: 38px;
    font-size: var(--fs-meta);
    font-weight: 600;
    font-family: var(--font-mono);
    color: var(--lt-58a6ff, #58a6ff);
    text-align: center;
  }
  .tb-brush input[type='range'] {
    width: 95px;
    accent-color: var(--accent-primary);
    cursor: pointer;
  }

  /* ── Map Container ──────────────────────────────────────────────────────────── */
  .map-wrap {
    position: relative;
    width: 100%;
    border: 1px solid var(--tablet-border, var(--es-line, #2a2e35));
    border-radius: var(--r-panel);
    overflow: hidden;
    background: var(--es-inset, #0f1113);
  }
  .map-wrap.has-toolbar {
    border-radius: 0 0 var(--r-panel) var(--r-panel);
  }
  .map {
    position: absolute;
    inset: 0;
    background: var(--es-inset, #131518);
  }
  .dim :global(.leaflet-tile-pane) {
    filter: brightness(var(--map-b, 1.1)) saturate(1.1) contrast(1.05);
  }
  .map :global(.leaflet-container) { background: var(--es-inset, #131518); }
  .pick-hint {
    position: absolute;
    left: 50%;
    top: 12px;
    transform: translateX(-50%);
    z-index: 900;
    background: var(--es-solid, #181b1f);
    border: 1px solid var(--accent-primary);
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-small);
    font-weight: 600;
    padding: 7px 14px;
    border-radius: var(--r-ctl);
    pointer-events: none;
  }
  .map :global(.leaflet-control-zoom a) {
    background: var(--es-solid, #181b1f);
    border-color: var(--es-line-strong, #363b43) !important;
    color: var(--lt-ffffff, #fff) !important;
  }

  /* Zoom lock overlay when zoomed out during paint */
  .zoom-lock-overlay {
    position: absolute;
    inset: 0;
    z-index: 500;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--ltc-4-26-56, 4, 26, 56), 0.7);
    pointer-events: auto;
    padding: 20px;
  }
  .zlo-card {
    background: var(--es-solid, #181b1f);
    border: 1px solid #f59e0b;
    box-shadow: none;
    border-radius: var(--r-panel);
    padding: 22px 28px;
    max-width: 420px;
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
  }
  .zlo-icon {
    font-size: 32px;
    line-height: 1;
  }
  .zlo-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-fbbf24, #fbbf24);
    letter-spacing: 0.01em;
  }
  .zlo-sub {
    font-size: var(--fs-small);
    line-height: 1.5;
    color: var(--lt-c9ced4, #c9ced4);
  }
  .zlo-sub b {
    color: var(--lt-ffffff, #fff);
  }
  .zlo-btn {
    margin-top: 6px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    background: #f2a93b;
    color: #000;
    font-size: var(--fs-small);
    font-weight: 700;
    padding: 9px 20px;
    border: none;
    border-radius: var(--r-ctl);
    cursor: pointer;
    box-shadow: none;
    transition: transform 0.15s ease, filter 0.15s ease;
  }
  .zlo-btn:hover {
    filter: brightness(1.1);
    transform: translateY(-1px);
  }
</style>

