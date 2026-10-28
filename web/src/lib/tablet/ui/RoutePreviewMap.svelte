<script>
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import {
    ATLAS_TILE_URL, ATLAS_MIN_ZOOM, ATLAS_MAX_ZOOM, ATLAS_VIEW_MAX_ZOOM, ATLAS_TILE_SIZE,
    createAtlasCRS, TYPE_COLOR_JS, EVENT_LEGENDS,
  } from '../../util/mapGeometry.js';
  import Icon from './Icon.svelte';
  import { getGroundZ } from '../../api/route.js';

  const dispatch = createEventDispatcher();

  // A drop on the map only gives x/y. The height used to stay whatever the point had before (a point dragged onto a
  // hill or a bridge kept its old z), so the vector in the saved event did not match the spot on the map. After every
  // drop the game is asked for the ground height at the new x/y and the point gets it. `zTokens` drops a late answer
  // when the same point has been dragged again in the meantime.
  const zTokens = {};
  async function settleTruckZ(zone) {
    const key = `${zone.id}:truck`;
    const token = (zTokens[key] = (zTokens[key] || 0) + 1);
    const tx = zone.truckX, ty = zone.truckY;
    try {
      const res = await getGroundZ(tx, ty, zone.truckZ);
      if (!res || !res.found || !Number.isFinite(Number(res.z)) || zTokens[key] !== token) return;
      zone.truckZ = Number(Number(res.z).toFixed(2));
      dispatch('pointMove', { id: zone.id, x: zone.x, y: zone.y, point: zone });
    } catch (e) { /* no game behind the page */ }
  }
  async function settleZ(obj, id, index, x, y) {
    const token = (zTokens[id] = (zTokens[id] || 0) + 1);
    try {
      const res = await getGroundZ(x, y, obj.z);
      if (!res || !res.found || !Number.isFinite(Number(res.z)) || zTokens[id] !== token) return;
      const z = Number(Number(res.z).toFixed(2));
      obj.z = z;
      dispatch('pointMove', { id, index, x, y, z, point: obj });
    } catch (e) { /* no game behind the page (browser preview): keep the old height */ }
  }

  export let route = [];
  export let checkpoints = [];
  export let airdrops = [];
  export let zones = [];
  // Operation Crackdown: the one combat zone drawn as a circle ({ shape: 'circle', radius }) or a square ({ shape: 'square', size = half side })
  export let zoneShape = null;
  // extra drawn areas shown under the airdrop-style zones (Crackdown start boxes): [{ label, color, points: [{ x, y }] }]
  export let overlays = [];
  export let hotCargo = null;
  export let rallyStages = [];
  export let height = 480;
  export let interactive = false;
  export let editable = true;
  export let selectedPointId = null;
  export let eventKind = '';
  export let legend = true;

  $: resolvedKind = eventKind || ((rallyStages && rallyStages.length) ? 'GANG_RACE'
    : ((zones && zones.length) ? 'GANG_AIRDROP'
    : ((hotCargo && (((hotCargo.spawnZones || []).length) || ((hotCargo.dropoffZones || []).length))) ? 'HOT_CARGO'
    : 'CONVOY')));

  $: activeLegend = EVENT_LEGENDS[resolvedKind] || EVENT_LEGENDS.CONVOY;

  let L;
  let container;
  let map;
  let layerGroup;
  let ready = false;

  let resizeObs;
  let atlasBounds;
  let renderPending = false;
  let didFit = false;
  let initialFitDone = false;
  let isDraggingMarker = false;
  let activePointInfo = null;

  const isVisible = () => !!container && container.clientWidth > 0 && container.clientHeight > 0;
  function fitTo(bounds, opts) { didFit = true; if (map) map.fitBounds(bounds, opts); }
  function viewTo(latlng, zoom) { didFit = true; if (map) map.setView(latlng, zoom); }
  function fitWholeMap() { if (map && atlasBounds) map.fitBounds(atlasBounds); }

  function updateMinZoom() {
    if (!map || !atlasBounds || !isVisible()) return;
    map.setMinZoom(Math.max(ATLAS_MIN_ZOOM, map.getBoundsZoom(atlasBounds, false)));
  }

  function onContainerResize() {
    if (!isVisible()) return;
    if (!map) { initMap(); return; }
    map.invalidateSize(false);
    updateMinZoom();
    if (renderPending) render();
  }

  function worldToLatLng(x, y) {
    return L.latLng(y || 0, x || 0);
  }

  function pointNameFor(point, index) {
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

  // A re-render rebuilds EVERY pin. It used to run whenever the route changed - including the moment the game answered with the ground
  // height of a point that had just been dropped - so a pin grabbed right then was deleted under the cursor and "did not move".
  // Renders are now held back while a mouse button is down on the map or a pin is being dragged, and run once on release.
  let renderScheduled = false;
  let pointerDown = false;
  let renderDeferred = false;
  const busy = () => isDraggingMarker || pointerDown;
  function scheduleRender() {
    if (busy()) { renderDeferred = true; return; }
    if (renderScheduled) return;
    renderScheduled = true;
    requestAnimationFrame(() => {
      renderScheduled = false;
      if (busy()) { renderDeferred = true; return; }
      render();
    });
  }
  // ── Grabbing a pin by proximity ──
  // A pin is about 26 px wide. A press that lands a few pixels beside it (easy with the in-game cursor) hit the MAP instead and panned
  // it, so "only the map moves, not the pin". Now the nearest draggable pin within GRAB_RADIUS of the cursor is the one that is grabbed:
  // the press is handed to that pin (and the map does not pan). Hovering near a pin lights it up and shows its tooltip, so it is clear
  // which pin a press will pick up.
  const GRAB_RADIUS = 28;
  let hotPin = null;
  function nearestPin(clientX, clientY) {
    if (!map || !layerGroup || !editable) return null;
    const rect = container.getBoundingClientRect();
    const kx = container.offsetWidth ? rect.width / container.offsetWidth : 1;
    const ky = container.offsetHeight ? rect.height / container.offsetHeight : 1;
    const px = (clientX - rect.left) / (kx || 1), py = (clientY - rect.top) / (ky || 1);
    let best = null, bestD = GRAB_RADIUS;
    layerGroup.eachLayer((l) => {
      if (!(l instanceof L.Marker) || !l._icon || !l.dragging || !l.dragging.enabled()) return;
      const c = map.latLngToContainerPoint(l.getLatLng());
      const d = Math.hypot(c.x - px, c.y - py);
      if (d <= bestD) { bestD = d; best = l; }
    });
    return best;
  }
  function setHot(pin) {
    if (pin === hotPin) return;
    if (hotPin && hotPin._icon) {
      const el = hotPin._icon.querySelector('.custom-route-pin');
      if (el) el.classList.remove('hot');
      if (hotPin.closeTooltip) hotPin.closeTooltip();
    }
    hotPin = pin;
    if (pin && pin._icon) {
      const el = pin._icon.querySelector('.custom-route-pin');
      if (el) el.classList.add('hot');
      if (pin.openTooltip) pin.openTooltip();
    }
  }
  function onMapMouseMove(e) {
    if (busy() || !e.target || (e.target.closest && e.target.closest('.leaflet-control, .map-selected-hud'))) { if (!busy()) setHot(null); return; }
    setHot(nearestPin(e.clientX, e.clientY));
  }
  function onMapMouseDown(e) {
    if (e.button !== 0 || e.shiftKey || !map) return;
    if (e.target && e.target.closest && e.target.closest('.leaflet-control, .map-selected-hud')) return;
    const pin = nearestPin(e.clientX, e.clientY);
    if (!pin) return;
    if (pin._icon.contains(e.target)) return;          // pressed right on it: Leaflet does the rest
    e.stopPropagation();
    e.preventDefault();
    const ev = new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window, button: 0, buttons: 1,
      clientX: e.clientX, clientY: e.clientY, screenX: e.screenX, screenY: e.screenY });
    pin._icon.dispatchEvent(ev);
    // a press that did not turn into a drag is a click on that pin: select it, and swallow the click the browser would send to the map
    const onUp = () => {
      window.removeEventListener('mouseup', onUp, true);
      const dr = pin.dragging && pin.dragging._draggable;
      const moved = dr && dr._moved;
      const swallow = (c) => { c.stopPropagation(); c.preventDefault(); };
      container.addEventListener('click', swallow, { capture: true, once: true });
      setTimeout(() => container.removeEventListener('click', swallow, true), 60);
      if (!moved) pin.fire('click', { latlng: pin.getLatLng(), originalEvent: {} });
    };
    window.addEventListener('mouseup', onUp, true);
  }
  // Every draggable marker kind (spawn, truck, dropoff, airdrop zone) gets the same drag behaviour as the convoy / rally pins: the map is
  // told a drag is on (it must not redraw and delete the pin under the cursor), the pin's zone circle follows it, and the position is sent
  // live (pointDrag) so the vector fields move with the pin instead of jumping when it is released.
  function armDrag(marker, { id, index, point, label, circle }) {
    if (!editable) return;
    marker.on('dragstart', () => {
      isDraggingMarker = true;
      marker.openTooltip();
      dispatch('pointDragStart', { id, index, point });
    });
    marker.on('drag', (e) => {
      const ll = e.target.getLatLng();
      if (circle && circle.setLatLng) circle.setLatLng(ll);
      const x = Number(ll.lng.toFixed(1)), y = Number(ll.lat.toFixed(1));
      marker.setTooltipContent('<b>' + label + '</b><br><span style="color:#60a5fa;font-size:11px;">Moving to: X: ' + x + ', Y: ' + y + '</span>');
      dispatch('pointDrag', { id, index, x, y, point });
    });
    marker.on('dragend', () => { isDraggingMarker = false; });
  }

  function onPointerDown() { pointerDown = true; }
  function onPointerUp() {
    pointerDown = false;
    if (renderDeferred && !isDraggingMarker) { renderDeferred = false; setTimeout(scheduleRender, 0); }
  }

  function render() {
    if (!map || !layerGroup) return;
    if (!isVisible()) { renderPending = true; return; }
    renderPending = false;
    didFit = false;
    drawLayers();
    if (!didFit && !initialFitDone) fitWholeMap();
  }

  export function fitAllLayers() {
    if (!map || !L) return;
    let allPoints = [];
    if (resolvedKind === 'CONVOY' && route) {
      allPoints = route.filter((p) => p && p.x != null).map((p) => worldToLatLng(p.x, p.y));
    } else if (resolvedKind === 'GANG_RACE' && rallyStages) {
      allPoints = rallyStages.filter((s) => s && s.x != null).map((s) => worldToLatLng(s.x, s.y));
    } else if (resolvedKind === 'HOT_CARGO' && hotCargo) {
      const z = [...(hotCargo.spawnZones || []), ...(hotCargo.trucks || []).filter((t) => t.mode === 'MANUAL'), ...(hotCargo.dropoffZones || [])];
      allPoints = z.filter((o) => o && o.x != null).map((o) => worldToLatLng(o.x, o.y));
    } else if (resolvedKind === 'GANG_AIRDROP' && zones) {
      allPoints = zones.filter((z) => z && z.x != null).map((z) => worldToLatLng(z.x, z.y));
    }

    if (allPoints.length === 1) {
      viewTo(allPoints[0], ATLAS_MAX_ZOOM - 2);
    } else if (allPoints.length > 1) {
      fitTo(L.latLngBounds(allPoints), { padding: [40, 40], maxZoom: ATLAS_MAX_ZOOM });
    } else if (atlasBounds) {
      map.fitBounds(atlasBounds);
    }
  }

  function clearSelection() {
    selectedPointId = null;
    activePointInfo = null;
    scheduleRender();
  }

  function drawLayers() {
    hotPin = null;
    layerGroup.clearLayers();

    // ──────────────── Rally Race Mode ────────────────
    if (resolvedKind === 'GANG_RACE' && rallyStages && rallyStages.length > 0) {
      const validStages = rallyStages.filter((s) => s && s.x != null && s.y != null);
      if (validStages.length > 0) {
        const sorted = [...validStages].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        const latlngs = sorted.map((s) => worldToLatLng(s.x, s.y));

        const rallyPolyline = L.polyline(latlngs, {
          color: TYPE_COLOR_JS.ROUTE,
          weight: 2.5,
          dashArray: '6 4',
          opacity: 0.85,
        }).addTo(layerGroup);

        sorted.forEach((s, i) => {
          const ll = latlngs[i];
          const isStart = s.kind ? s.kind === 'START' : i === 0;
          const isFinish = s.kind ? s.kind === 'DESTINATION' : i === sorted.length - 1;
          const color = isFinish ? TYPE_COLOR_JS.DESTINATION : (isStart ? TYPE_COLOR_JS.START : TYPE_COLOR_JS.CHECKPOINT);
          const rad = Number(s.radius) || 12;
          const isSelected = selectedPointId && s.id === selectedPointId;

          const stageCircle = L.circle(ll, {
            radius: rad,
            color,
            weight: isFinish ? 3 : 1.5,
            fillColor: color,
            fillOpacity: 0.15,
          }).addTo(layerGroup);

          const iconLabel = isFinish ? 'Finish' : (isStart ? 'Start' : `CP #${i + 1}`);

          const pinHtml = `
            <div class="custom-route-pin ${isSelected ? 'selected' : ''} ${isFinish ? 'finish' : ''}" style="--pin-color: ${color};">
              <span class="pin-number">${isFinish ? '🏁' : (isStart ? '★' : i + 1)}</span>
            </div>
          `;

          const markerIcon = L.divIcon({
            className: 'custom-route-marker-wrap',
            html: pinHtml,
            iconSize: [26, 26],
            iconAnchor: [13, 13],
          });

          const marker = L.marker(ll, {
            draggable: editable, autoPan: true, autoPanPadding: [80, 80], autoPanSpeed: 14,
            icon: markerIcon,
            zIndexOffset: isSelected ? 1000 : 100 + i,
          });

          marker.bindTooltip(`<b>${iconLabel}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${Number(s.x).toFixed(1)}, Y: ${Number(s.y).toFixed(1)}</span>`, {
            direction: 'top',
            offset: [0, -12],
          });

          marker.on('click', (e) => {
            L.DomEvent.stopPropagation(e);
            selectedPointId = s.id;
            activePointInfo = {
              id: s.id,
              index: i,
              label: iconLabel,
              type: s.kind || 'CHECKPOINT',
              color,
              x: Number(Number(s.x).toFixed(1)),
              y: Number(Number(s.y).toFixed(1)),
            };
            dispatch('selectPoint', { id: s.id, index: i, point: s });
          });

          if (editable) {
            marker.on('dragstart', (e) => {
              isDraggingMarker = true;
              selectedPointId = s.id;
              activePointInfo = {
                id: s.id,
                index: i,
                label: iconLabel,
                type: s.kind || 'CHECKPOINT',
                color,
                x: Number(Number(s.x).toFixed(1)),
                y: Number(Number(s.y).toFixed(1)),
              };
              marker.openTooltip();
              dispatch('pointDragStart', { id: s.id, index: i, point: s });
            });

            marker.on('drag', (e) => {
              const curLL = e.target.getLatLng();
              const curX = Number(curLL.lng.toFixed(1));
              const curY = Number(curLL.lat.toFixed(1));

              latlngs[i] = curLL;
              rallyPolyline.setLatLngs(latlngs);
              stageCircle.setLatLng(curLL);

              marker.setTooltipContent(`<b>${iconLabel}</b><br><span style="color:#60a5fa;font-size:11px;">Moving to: X: ${curX}, Y: ${curY}</span>`);
              if (activePointInfo) {
                activePointInfo.x = curX;
                activePointInfo.y = curY;
              }

              dispatch('pointDrag', { id: s.id, index: i, x: curX, y: curY, stage: s });
            });

            marker.on('dragend', (e) => {
              isDraggingMarker = false;
              const endLL = e.target.getLatLng();
              const endX = Number(endLL.lng.toFixed(1));
              const endY = Number(endLL.lat.toFixed(1));

              s.x = endX;
              s.y = endY;

              if (activePointInfo) {
                activePointInfo.x = endX;
                activePointInfo.y = endY;
              }

              marker.setTooltipContent(`<b>${iconLabel}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${endX}, Y: ${endY}</span>`);
              dispatch('stageMove', { id: s.id, index: i, x: endX, y: endY, stage: s });
              dispatch('pointMove', { id: s.id, index: i, x: endX, y: endY, point: s });
              settleZ(s, s.id, i, endX, endY);
            });
          }

          marker.addTo(layerGroup);
        });

        if (!initialFitDone) {
          initialFitDone = true;
          if (latlngs.length === 1) {
            viewTo(latlngs[0], ATLAS_MAX_ZOOM - 2);
          } else if (latlngs.length > 1) {
            fitTo(L.latLngBounds(latlngs), { padding: [40, 40], maxZoom: ATLAS_MAX_ZOOM });
          }
        }
        return;
      }
    }

    // ──────────────── Hot Cargo Mode ────────────────
    if (resolvedKind === 'HOT_CARGO' && hotCargo && ((hotCargo.spawnZones && hotCargo.spawnZones.length > 0) || (hotCargo.trucks && hotCargo.trucks.length > 0) || (hotCargo.dropoffZones && hotCargo.dropoffZones.length > 0))) {
      const validSpawns = (hotCargo.spawnZones || []).filter((z) => z && z.x != null && z.y != null);
      const validManualTrucks = (hotCargo.trucks || []).filter((t) => t && t.mode === 'MANUAL' && t.x != null && t.y != null);
      const validDropoffs = (hotCargo.dropoffZones || []).filter((d) => d && d.x != null && d.y != null);
      if (validSpawns.length === 0 && validManualTrucks.length === 0 && validDropoffs.length === 0) return;
      const latlngs = [];

      validSpawns.forEach((z, i) => {
        const ll = worldToLatLng(z.x, z.y);
        latlngs.push(ll);
        const color = '#e0489f';
        const label = `Spawn: ${z.name || 'Truck Spawn'}`;

        const markerIcon = L.divIcon({
          className: 'custom-route-marker-wrap',
          html: `<div class="custom-route-pin" style="--pin-color: ${color};"><span class="pin-number">🚚</span></div>`,
          iconSize: [26, 26],
          iconAnchor: [13, 13],
        });

        const marker = L.marker(ll, { draggable: editable, autoPan: true, autoPanPadding: [80, 80], autoPanSpeed: 14, icon: markerIcon });
        marker.bindTooltip(`<b>${label}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${Number(z.x).toFixed(1)}, Y: ${Number(z.y).toFixed(1)}</span>`, { direction: 'top', offset: [0, -12] });

        marker.on('click', (e) => {
          L.DomEvent.stopPropagation(e);
          activePointInfo = { id: z.id || i, index: i, label, type: 'SPAWN', color, x: Number(z.x.toFixed(1)), y: Number(z.y.toFixed(1)) };
          dispatch('selectPoint', { id: z.id || i, index: i, point: z });
        });

        armDrag(marker, { id: z.id, index: i, point: z, label });
        if (editable) {
          marker.on('dragend', (e) => {
            const endLL = e.target.getLatLng();
            const endX = Number(endLL.lng.toFixed(1));
            const endY = Number(endLL.lat.toFixed(1));
            const shiftX = endX - Number(z.x), shiftY = endY - Number(z.y);
            z.x = endX; z.y = endY;
            // the zone's precise truck vector moves with it (same offset inside the area), otherwise the truck would still spawn
            // at the old spot after the zone was dragged somewhere else on the map
            if (z.truckX != null && z.truckY != null) {
              z.truckX = Number((Number(z.truckX) + shiftX).toFixed(1));
              z.truckY = Number((Number(z.truckY) + shiftY).toFixed(1));
              settleTruckZ(z);
            }
            if (activePointInfo) { activePointInfo.x = endX; activePointInfo.y = endY; }
            dispatch('zoneMove', { id: z.id, x: endX, y: endY, kind: 'spawn' });
            dispatch('pointMove', { id: z.id, index: i, x: endX, y: endY, point: z });
            settleZ(z, z.id, i, endX, endY);
          });
        }
        marker.addTo(layerGroup);
      });

      validManualTrucks.forEach((t, i) => {
        const ll = worldToLatLng(t.x, t.y);
        latlngs.push(ll);
        const color = '#ff86c8';
        const label = `Manual: ${t.name || 'Truck'} (${t.model || ''})`;

        const markerIcon = L.divIcon({
          className: 'custom-route-marker-wrap',
          html: `<div class="custom-route-pin" style="--pin-color: ${color};"><span class="pin-number">📍</span></div>`,
          iconSize: [26, 26],
          iconAnchor: [13, 13],
        });

        const marker = L.marker(ll, { draggable: editable, autoPan: true, autoPanPadding: [80, 80], autoPanSpeed: 14, icon: markerIcon });
        marker.bindTooltip(`<b>${label}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${Number(t.x).toFixed(1)}, Y: ${Number(t.y).toFixed(1)}</span>`, { direction: 'top', offset: [0, -12] });

        armDrag(marker, { id: t.id, index: i, point: t, label });
        if (editable) {
          marker.on('dragend', (e) => {
            const endLL = e.target.getLatLng();
            const endX = Number(endLL.lng.toFixed(1));
            const endY = Number(endLL.lat.toFixed(1));
            t.x = endX; t.y = endY;
            dispatch('truckMove', { id: t.id, x: endX, y: endY });
            dispatch('pointMove', { id: t.id, index: i, x: endX, y: endY, point: t });
            settleZ(t, t.id, i, endX, endY);
          });
        }
        marker.addTo(layerGroup);
      });

      validDropoffs.forEach((d, i) => {
        const ll = worldToLatLng(d.x, d.y);
        latlngs.push(ll);
        const color = '#70b982';
        const rad = Number(d.radius) || 15;
        const label = `Dropoff #${i + 1}: ${d.name || 'Dropoff'}`;

        const dropCircle = L.circle(ll, {
          radius: rad,
          color,
          weight: 2,
          fillColor: color,
          fillOpacity: 0.18,
          dashArray: '4 4',
        }).addTo(layerGroup);

        const markerIcon = L.divIcon({
          className: 'custom-route-marker-wrap',
          html: `<div class="custom-route-pin finish" style="--pin-color: ${color};"><span class="pin-number">🏁</span></div>`,
          iconSize: [26, 26],
          iconAnchor: [13, 13],
        });

        const marker = L.marker(ll, { draggable: editable, autoPan: true, autoPanPadding: [80, 80], autoPanSpeed: 14, icon: markerIcon });
        marker.bindTooltip(`<b>${label}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${Number(d.x).toFixed(1)}, Y: ${Number(d.y).toFixed(1)}</span>`, { direction: 'top', offset: [0, -12] });

        marker.on('click', (e) => {
          L.DomEvent.stopPropagation(e);
          activePointInfo = { id: d.id || i, index: i, label, type: 'DROPOFF', color, x: Number(d.x.toFixed(1)), y: Number(d.y.toFixed(1)) };
          dispatch('selectPoint', { id: d.id || i, index: i, point: d });
        });

        if (editable) {
          armDrag(marker, { id: d.id, index: i, point: d, label, circle: dropCircle });
          marker.on('dragend', (e) => {
            const endLL = e.target.getLatLng();
            const endX = Number(endLL.lng.toFixed(1));
            const endY = Number(endLL.lat.toFixed(1));
            d.x = endX; d.y = endY;
            if (activePointInfo) { activePointInfo.x = endX; activePointInfo.y = endY; }
            dispatch('dropoffMove', { id: d.id, x: endX, y: endY });
            dispatch('pointMove', { id: d.id, index: i, x: endX, y: endY, point: d });
            settleZ(d, d.id, i, endX, endY);
          });
        }
        marker.addTo(layerGroup);
      });

      if (!initialFitDone) {
        initialFitDone = true;
        if (latlngs.length === 1) {
          viewTo(latlngs[0], ATLAS_MAX_ZOOM - 2);
        } else if (latlngs.length > 1) {
          fitTo(L.latLngBounds(latlngs), { padding: [40, 40], maxZoom: ATLAS_MAX_ZOOM });
        }
      }
      return;
    }

    // ──────────────── Airdrop Zones Mode ────────────────
    if (resolvedKind === 'GANG_AIRDROP') {
      for (const o of overlays || []) {
        const pts = (o.points || []).filter((p) => p && p.x != null && p.y != null).map((p) => worldToLatLng(p.x, p.y));
        if (pts.length < 3) continue;
        L.polygon(pts, { color: o.color, weight: 2, fillColor: o.color, fillOpacity: 0.22, interactive: false })
          .bindTooltip(o.label, { permanent: true, direction: 'center', className: 'overlay-tip' }).addTo(layerGroup);
      }
    }
    if (resolvedKind === 'GANG_AIRDROP' && zones && zones.length > 0) {
      const validZones = zones.filter((z) => z && z.x != null && z.y != null);
      if (validZones.length === 0) return;
      const latlngs = [];
      validZones.forEach((z, i) => {
        const ll = worldToLatLng(z.x, z.y);
        latlngs.push(ll);
        const color = '#9b7bff';
        const label = `Drop Zone ${i + 1}: ${z.label || z.name || 'Drop Zone'}`;

        const shaped = zoneShape && (zoneShape.shape === 'square' || zoneShape.shape === 'circle');
        const zoneColor = shaped ? '#d6336c' : color;
        const zoneStyle = { color: zoneColor, weight: 1.5, fillColor: zoneColor, fillOpacity: 0.15, dashArray: '5 5' };
        const half = Number(zoneShape && zoneShape.size) || 100;
        const zoneCircle = (shaped && zoneShape.shape === 'square')
          ? L.rectangle([[z.y - half, z.x - half], [z.y + half, z.x + half]], zoneStyle).addTo(layerGroup)
          : L.circle(ll, { ...zoneStyle, radius: shaped ? (Number(zoneShape.radius) || 100) : 35 }).addTo(layerGroup);

        const markerIcon = L.divIcon({
          className: 'custom-route-marker-wrap',
          html: `<div class="custom-route-pin" style="--pin-color: ${color};"><span class="pin-number">${i + 1}</span></div>`,
          iconSize: [26, 26],
          iconAnchor: [13, 13],
        });

        const marker = L.marker(ll, { draggable: editable, autoPan: true, autoPanPadding: [80, 80], autoPanSpeed: 14, icon: markerIcon });
        marker.bindTooltip(`<b>${label}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${Number(z.x).toFixed(1)}, Y: ${Number(z.y).toFixed(1)}</span>`, { direction: 'top', offset: [0, -12] });

        marker.on('click', (e) => {
          L.DomEvent.stopPropagation(e);
          activePointInfo = { id: z.id || i, index: i, label, type: 'AIRDROP', color, x: Number(z.x.toFixed(1)), y: Number(z.y.toFixed(1)) };
          dispatch('selectPoint', { id: z.id || i, index: i, point: z });
        });

        if (editable) {
          armDrag(marker, { id: z.id, index: i, point: z, label, circle: zoneCircle });
          marker.on('dragend', (e) => {
            const endLL = e.target.getLatLng();
            const endX = Number(endLL.lng.toFixed(1));
            const endY = Number(endLL.lat.toFixed(1));
            z.x = endX; z.y = endY;
            if (activePointInfo) { activePointInfo.x = endX; activePointInfo.y = endY; }
            dispatch('zoneMove', { id: z.id, x: endX, y: endY });
            dispatch('pointMove', { id: z.id, index: i, x: endX, y: endY, point: z });
            settleZ(z, z.id, i, endX, endY);
          });
        }
        marker.addTo(layerGroup);
      });

      if (!initialFitDone) {
        initialFitDone = true;
        if (latlngs.length === 1) {
          viewTo(latlngs[0], ATLAS_MAX_ZOOM - 2);
        } else if (latlngs.length > 1) {
          fitTo(L.latLngBounds(latlngs), { padding: [40, 40], maxZoom: ATLAS_MAX_ZOOM });
        }
      }
      return;
    }

    // ──────────────── Convoy Mode ────────────────
    if (resolvedKind !== 'CONVOY') return;
    if (!route || route.length === 0) return;

    const cpRadiusById = {};
    for (const cp of checkpoints || []) cpRadiusById[cp.routePointId] = cp.radius;
    const airdropIds = new Set((airdrops || []).map((a) => a.routePointId));

    const sorted = [...route].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
    const latlngs = sorted.map((p) => worldToLatLng(p.x, p.y));

    const routePolyline = L.polyline(latlngs, {
      color: '#3b82f6',
      weight: 2.5,
      dashArray: '6 5',
      opacity: 0.85,
    }).addTo(layerGroup);

    sorted.forEach((p, i) => {
      const ll = latlngs[i];
      const color = TYPE_COLOR_JS[p.type] || '#9ca3af';
      const isSelected = selectedPointId && p.id === selectedPointId;
      const isDest = p.type === 'DESTINATION';
      const isStart = p.type === 'START';

      let cpCircle = null;
      if (p.type === 'CHECKPOINT' && cpRadiusById[p.id]) {
        cpCircle = L.circle(ll, {
          radius: cpRadiusById[p.id],
          color,
          weight: 1.5,
          fillColor: color,
          fillOpacity: 0.12,
        }).addTo(layerGroup);
      } else if (p.type === 'DESTINATION') {
        // the delivery circle, with a red border so the destination stands out on the map
        cpCircle = L.circle(ll, {
          radius: 25,
          color: '#ff3b30',
          weight: 3,
          fillColor: '#ff3b30',
          fillOpacity: 0.08,
        }).addTo(layerGroup);
      } else if (p.type === 'AIRDROP' && airdropIds.has(p.id)) {
        cpCircle = L.circle(ll, {
          radius: 20,
          color: TYPE_COLOR_JS.AIRDROP,
          weight: 1.5,
          fillColor: TYPE_COLOR_JS.AIRDROP,
          fillOpacity: 0.12,
        }).addTo(layerGroup);
      }

      const pinHtml = `
        <div class="custom-route-pin ${isSelected ? 'selected' : ''} ${isDest ? 'finish' : ''}" style="--pin-color: ${color};">
          <span class="pin-number">${isDest ? '🏁' : (isStart ? '★' : i + 1)}</span>
        </div>
      `;

      const markerIcon = L.divIcon({
        className: 'custom-route-marker-wrap',
        html: pinHtml,
        iconSize: [26, 26],
        iconAnchor: [13, 13],
      });

      const ptName = pointNameFor(p, i);
      const marker = L.marker(ll, {
        draggable: editable, autoPan: true, autoPanPadding: [80, 80], autoPanSpeed: 14,
        icon: markerIcon,
        zIndexOffset: isSelected ? 1000 : 100 + i,
      });

      marker.bindTooltip(`<b>#${i + 1} ${ptName}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${Number(p.x).toFixed(1)}, Y: ${Number(p.y).toFixed(1)}</span>`, {
        direction: 'top',
        offset: [0, -12],
      });

      marker.on('click', (e) => {
        L.DomEvent.stopPropagation(e);
        selectedPointId = p.id;
        activePointInfo = {
          id: p.id,
          index: i,
          label: ptName,
          type: p.type,
          color,
          x: Number(Number(p.x).toFixed(1)),
          y: Number(Number(p.y).toFixed(1)),
        };
        dispatch('selectPoint', { id: p.id, index: i, point: p });
      });

      if (editable) {
        marker.on('dragstart', (e) => {
          isDraggingMarker = true;
          selectedPointId = p.id;
          activePointInfo = {
            id: p.id,
            index: i,
            label: ptName,
            type: p.type,
            color,
            x: Number(Number(p.x).toFixed(1)),
            y: Number(Number(p.y).toFixed(1)),
          };
          marker.openTooltip();
          dispatch('pointDragStart', { id: p.id, index: i, point: p });
        });

        marker.on('drag', (e) => {
          const curLL = e.target.getLatLng();
          const curX = Number(curLL.lng.toFixed(1));
          const curY = Number(curLL.lat.toFixed(1));

          latlngs[i] = curLL;
          routePolyline.setLatLngs(latlngs);

          if (cpCircle) {
            cpCircle.setLatLng(curLL);
          }

          marker.setTooltipContent(`<b>#${i + 1} ${ptName}</b><br><span style="color:#60a5fa;font-size:11px;">Moving to: X: ${curX}, Y: ${curY}</span>`);
          if (activePointInfo) {
            activePointInfo.x = curX;
            activePointInfo.y = curY;
          }

          dispatch('pointDrag', { id: p.id, index: i, x: curX, y: curY, point: p });
        });

        marker.on('dragend', (e) => {
          isDraggingMarker = false;
          const endLL = e.target.getLatLng();
          const endX = Number(endLL.lng.toFixed(1));
          const endY = Number(endLL.lat.toFixed(1));

          p.x = endX;
          p.y = endY;

          if (activePointInfo) {
            activePointInfo.x = endX;
            activePointInfo.y = endY;
          }

          marker.setTooltipContent(`<b>#${i + 1} ${ptName}</b><br><span style="color:#9ca3af;font-size:11px;">X: ${endX}, Y: ${endY}</span>`);

          dispatch('pointMove', { id: p.id, index: i, x: endX, y: endY, point: p });
          settleZ(p, p.id, i, endX, endY);
          if (renderDeferred && !pointerDown) { renderDeferred = false; setTimeout(scheduleRender, 0); }
        });
      }

      marker.addTo(layerGroup);
    });

    if (!initialFitDone) {
      initialFitDone = true;
      if (latlngs.length === 1) {
        viewTo(latlngs[0], ATLAS_MAX_ZOOM - 2);
      } else if (latlngs.length > 1) {
        fitTo(L.latLngBounds(latlngs), { padding: [40, 40], maxZoom: ATLAS_MAX_ZOOM });
      }
    }
  }

  onMount(async () => {
    const leaflet = await import('leaflet');
    await import('leaflet/dist/leaflet.css');
    L = leaflet.default || leaflet;
    resizeObs = new ResizeObserver(onContainerResize);
    resizeObs.observe(container);
    if (isVisible()) initMap();
  });

  function initMap() {
    if (map || !L || !isVisible()) return;
    const AtlasCRS = createAtlasCRS(L);

    map = L.map(container, {
      crs: AtlasCRS,
      minZoom: ATLAS_MIN_ZOOM,
      maxZoom: ATLAS_VIEW_MAX_ZOOM,
      zoomSnap: 0,
      zoomDelta: 0.5,
      wheelPxPerZoomLevel: 100,
      attributionControl: false,
      scrollWheelZoom: false, // Prevents scroll hijacking when moving through tablet view
    });

    const bounds = L.latLngBounds(
      map.unproject([0, ATLAS_TILE_SIZE], ATLAS_MAX_ZOOM),
      map.unproject([ATLAS_TILE_SIZE, 0], ATLAS_MAX_ZOOM)
    );
    L.tileLayer(ATLAS_TILE_URL, {
      bounds,
      minZoom: ATLAS_MIN_ZOOM,
      maxZoom: ATLAS_VIEW_MAX_ZOOM,
      maxNativeZoom: ATLAS_MAX_ZOOM,     // beyond the last real tile level the tiles are simply enlarged
      noWrap: true,
    }).addTo(map);
    map.setMaxBounds(bounds.pad(0.25));
    atlasBounds = bounds;
    map.fitBounds(bounds);
    updateMinZoom();

    // Enable wheel zoom on click/focus, disable on mouse leave to prevent page scroll trap
    container.addEventListener('click', () => {
      if (map) map.scrollWheelZoom.enable();
    });
    container.addEventListener('pointerdown', () => { if (map) map.scrollWheelZoom.enable(); }, true);
    container.addEventListener('pointerdown', onPointerDown, true);
    container.addEventListener('mousedown', onMapMouseDown, true);
    container.addEventListener('mousemove', onMapMouseMove);
    container.addEventListener('mouseleave', () => setHot(null));
    window.addEventListener('pointerup', onPointerUp, true);
    window.addEventListener('pointercancel', onPointerUp, true);
    container.addEventListener('mouseleave', () => {
      if (map) map.scrollWheelZoom.disable();
    });

    map.on('click', (e) => {
      if (!e || !e.latlng) return;
      const worldX = Number(e.latlng.lng.toFixed(2));
      const worldY = Number(e.latlng.lat.toFixed(2));
      dispatch('mapClick', { x: worldX, y: worldY });
    });

    layerGroup = L.layerGroup().addTo(map);
    ready = true;
    render();
  }

  onDestroy(() => {
    window.removeEventListener('pointerup', onPointerUp, true);
    window.removeEventListener('pointercancel', onPointerUp, true);
    if (resizeObs) resizeObs.disconnect();
    if (map) map.remove();
  });

  $: if (ready && !isDraggingMarker) {
    route; checkpoints; airdrops; zones; zoneShape; overlays; hotCargo; rallyStages; selectedPointId; scheduleRender();
  }
</script>

<div class="map-wrapper" style="height:{height}px;">
  <div class="map-container" class:interactive bind:this={container}></div>

  {#if activePointInfo}
    <div class="map-selected-hud">
      <div class="hud-left">
        <span class="hud-badge" style="background: {activePointInfo.color || 'var(--accent-primary)'};">
          #{activePointInfo.index + 1}
        </span>
        <div class="hud-meta">
          <span class="hud-title">{activePointInfo.label}</span>
          <span class="hud-coords mono">X: {activePointInfo.x} · Y: {activePointInfo.y}</span>
        </div>
      </div>
      <div class="hud-center">
        <span class="hud-hint">
          <Icon name="move" size={13} />
          {isDraggingMarker ? 'Moving on map… release to save' : 'Click & drag pin on map to reposition'}
        </span>
      </div>
      <button type="button" class="hud-close" on:click={clearSelection} title="Dismiss selection">
        <Icon name="close" size={12} />
      </button>
    </div>
  {/if}

  <div class="map-quick-controls">
    <button type="button" class="map-ctrl-btn" on:click={fitAllLayers} title="Fit entire route into view">
      <Icon name="expand" size={12} />
      <span>Fit View</span>
    </button>
  </div>
</div>

{#if legend && activeLegend && activeLegend.length > 0}
  <div class="map-legend">
    {#each activeLegend as item}
      <span class="legend-item">
        <span class="legend-dot" style="background:{TYPE_COLOR_JS[item.type] || '#9ca3af'}"></span>{item.label}
      </span>
    {/each}
  </div>
{/if}

<style>
  .map-wrapper {
    position: relative;
    width: 100%;
    border-radius: var(--radius-sm);
    border: 1px solid var(--tablet-border);
    overflow: hidden;
  }
  .map-container {
    width: 100%;
    height: 100%;
    background: var(--lt-0f1113, #0f1113);
    transition: border-color 0.2s ease;
  }
  .map-selected-hud {
    position: absolute;
    top: 10px;
    left: 12px;
    right: 12px;
    z-index: 1000;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 8px 14px;
    border-radius: var(--radius-sm);
    background: rgba(var(--ltc-14-19-28, 14, 19, 28), 0.94);
    border: 1px solid rgba(96, 165, 250, 0.4);
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.6), 0 0 12px rgba(96, 165, 250, 0.15);
    pointer-events: auto;
    animation: fadeInHud 0.15s ease-out;
  }
  @keyframes fadeInHud {
    from { opacity: 0; transform: translateY(-4px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .hud-left {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .hud-badge {
    padding: 3px 8px;
    border-radius: 4px;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.4);
  }
  .hud-meta {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .hud-title {
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main);
  }
  .hud-coords {
    font-size: var(--fs-meta);
    color: var(--accent-primary, #60a5fa);
  }
  .hud-center {
    display: flex;
    align-items: center;
  }
  .hud-hint {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    padding: 4px 10px;
    border-radius: 12px;
  }
  .hud-close {
    width: 26px;
    height: 26px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.12);
    color: var(--text-dim);
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .hud-close:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.16);
    color: var(--text-main);
  }
  .map-quick-controls {
    position: absolute;
    bottom: 12px;
    right: 12px;
    z-index: 1000;
    display: flex;
    gap: 6px;
  }
  .map-ctrl-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 6px 10px;
    background: rgba(var(--ltc-14-19-28, 14, 19, 28), 0.9);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.18);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .map-ctrl-btn:hover {
    background: rgba(var(--ltc-26-35-50, 26, 35, 50), 0.95);
    border-color: var(--accent-primary);
    color: var(--accent-primary);
    transform: translateY(-1px);
  }
  .map-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
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
  .map-container.interactive {
    cursor: crosshair !important;
    border-color: var(--accent-primary) !important;
    box-shadow: 0 0 0 1px var(--accent-primary);
  }
  .map-container.interactive :global(.leaflet-grab) {
    cursor: crosshair !important;
  }
  :global(.leaflet-container) {
    background: var(--tablet-bg, #131518);
    font-family: var(--font-ui);
    border-radius: var(--radius-sm);
  }
  :global(.leaflet-tooltip.overlay-tip) { background: #0d0e14; border: 1px solid #262a33; color: #f4f4f7; font-weight: 700; font-size: 11px; padding: 2px 7px; box-shadow: none; }
  :global(.leaflet-tooltip.overlay-tip::before) { display: none; }
  :global(.custom-route-marker-wrap) {
    background: transparent !important;
    border: none !important;
  }
  :global(.custom-route-pin) {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: var(--pin-color, #3b82f6);
    border: 2px solid var(--lt-000000, #000);
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-meta);
    font-weight: 700;
    cursor: grab;
    user-select: none;
    transition: transform 0.15s ease, box-shadow 0.15s ease;
  }
  /* an invisible ring around the pin makes it easy to grab, even at low zoom where pins crowd */
  :global(.custom-route-marker-wrap::after) {
    content: '';
    position: absolute;
    inset: -10px;
    border-radius: 50%;
  }
  :global(.custom-route-pin.hot) {
    transform: scale(1.3);
    box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.6), 0 0 14px var(--pin-color, #3b82f6);
  }
  :global(.custom-route-marker-wrap) { outline: none !important; }
  :global(.custom-route-pin:hover) {
    transform: scale(1.18);
    box-shadow: 0 0 10px var(--pin-color, #3b82f6);
  }
  :global(.custom-route-pin.selected) {
    width: 28px;
    height: 28px;
    transform: scale(1.22);
    border: 2.5px solid #fff;
    box-shadow: 0 0 0 3px var(--pin-color, #3b82f6), 0 0 14px rgba(255, 255, 255, 0.8);
    z-index: 1000 !important;
  }
  :global(.custom-route-pin.finish) {
    border-style: double;
    border-width: 3px;
  }
  :global(.leaflet-marker-dragging .custom-route-pin) {
    cursor: grabbing !important;
    transform: scale(1.35);
    box-shadow: 0 0 16px var(--pin-color, #3b82f6), 0 0 24px rgba(255, 255, 255, 0.8);
  }
  :global(.leaflet-tooltip) {
    background: var(--tablet-panel, rgba(20, 26, 36, 0.95));
    border: 1px solid var(--tablet-border-strong, #3b424e);
    color: var(--text-main, #ffffff);
    font-size: var(--fs-meta);
    font-family: var(--font-ui);
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.5);
  }
  .map-container :global(.leaflet-bar) {
    border: 1px solid var(--tablet-border-strong);
    border-radius: var(--r-ctl);
    box-shadow: none;
  }
  .map-container :global(.leaflet-bar a),
  .map-container :global(.leaflet-bar a:hover),
  .map-container :global(.leaflet-bar a:focus) {
    width: 30px;
    height: 30px;
    line-height: 28px;
    background: var(--c-raised, #1f2328);
    border-bottom: 1px solid var(--tablet-border-strong);
    color: var(--text-main);
    font: 600 18px/28px var(--font-ui);
    text-align: center;
  }
  .map-container :global(.leaflet-bar a:last-child) {
    border-bottom: 0;
  }
  .map-container :global(.leaflet-bar a:hover) {
    background: var(--c-hover, #272b31);
    color: var(--lt-ffffff, #ffffff);
  }
  .map-container :global(.leaflet-bar a.leaflet-disabled) {
    background: var(--c-panel, #181b1f);
    color: var(--text-faint);
    cursor: default;
  }
</style>
