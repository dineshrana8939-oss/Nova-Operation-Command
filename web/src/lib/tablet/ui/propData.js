// Shared helpers for everything the Prop Placer produces. The Prop Placer is the ONE source of truth for props and
// vehicles; these helpers only decide where a saved entry lives (event list or a convoy checkpoint) and whether it is
// a prop or a vehicle - they never invent or drop objects.
//
//   event-level objects   form.props                       (spawn when the event goes ACTIVE)
//   checkpoint objects    cp.barricadeProps / cp.decorVehicles   (spawn with the checkpoint, convoy only)
//
// In the Props tab both are shown (and sent to the placer) as ONE flat list; each checkpoint object carries
// `cpId` (the checkpoint's routePointId) so it can be filed back where it belongs when the placer returns.

// Models that are vehicles even when an old save forgot its `kind` (the placer only started writing it later).
const FALLBACK_VEHICLES = [
  'police', 'police2', 'police3', 'police4', 'policeb', 'policet', 'sheriff', 'sheriff2', 'fbi', 'fbi2', 'riot', 'riot2',
  'pranger', 'barracks', 'barracks2', 'barracks3', 'crusader', 'rhino', 'stockade', 'hauler', 'hauler2', 'packer', 'phantom',
  'trailers', 'trailers2', 'trailers3', 'trailers4', 'docktrailer', 'flatbed', 'ambulance', 'firetruk', 'insurgent', 'insurgent2',
];

export function vehicleSetFrom(bootstrap) {
  const set = new Set(FALLBACK_VEHICLES);
  const add = (m) => { if (m) set.add(String(m).toLowerCase()); };
  for (const m of (bootstrap?.placerVehicleModels || [])) add(m);
  for (const v of (bootstrap?.decorVehicles || [])) add(v.model);
  return set;
}

export const isVehicleEntry = (o, vset) => !!o && (o.kind === 'vehicle' || (vset && vset.has(String(o.model || '').toLowerCase())));

const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);

// A checkpoint's stored objects split into props and vehicles. Entries of `decorVehicles` are vehicles by
// definition; an entry of `barricadeProps` is a vehicle only if it says so or is a known vehicle model (a
// misfiled one, e.g. police3 saved as a plain prop). The same object references are returned (no copies).
export function cpSplit(cp, vset) {
  const props = [];
  const vehicles = [];
  for (const o of (cp?.barricadeProps || [])) (isVehicleEntry(o, vset) ? vehicles : props).push(o);
  for (const o of (cp?.decorVehicles || [])) vehicles.push(o);
  return { props, vehicles };
}

export const routePoint = (route, cp) => (Array.isArray(route) ? route.find((p) => p.id === cp.routePointId) : null) || null;

// The flat list every Props tab shows and the placer edits: checkpoint objects first (checkpoint order), then the
// event's own. `cpId` is added to the checkpoint ones; `kind` is always set.
export function collectObjects({ props, checkpoints }, vset) {
  const out = [];
  for (const cp of (checkpoints || [])) {
    const { props: ps, vehicles } = cpSplit(cp, vset);
    for (const o of ps) out.push({ ...o, kind: 'object', cpId: cp.routePointId });
    for (const o of vehicles) out.push({ ...o, kind: 'vehicle', cpId: cp.routePointId });
  }
  for (const o of (props || [])) out.push({ ...o, kind: isVehicleEntry(o, vset) ? 'vehicle' : (o.kind || 'object') });
  return out;
}

// Files a flat list back into the event: tagged objects go to their checkpoint; an untagged one (just placed) goes
// to the checkpoint whose zone it stands in, otherwise it stays an event-level object.
export function distributeObjects(list, { checkpoints, route }, vset) {
  const cps = checkpoints || [];
  const zones = cps.map((cp) => {
    const pt = routePoint(route, cp);
    return { cp, x: pt ? num(pt.x, NaN) : NaN, y: pt ? num(pt.y, NaN) : NaN, r: Math.max(5, num(cp.radius, 15)) + 6 };
  });
  const byCp = new Map(cps.map((cp) => [cp.routePointId, { props: [], vehicles: [] }]));
  const eventProps = [];
  for (const raw of (list || [])) {
    const { cpId, ...o } = raw;
    o.kind = isVehicleEntry(o, vset) ? 'vehicle' : 'object';
    let target = cpId && byCp.has(cpId) ? cpId : null;
    if (!target) {
      let best = null;
      for (const z of zones) {
        if (!Number.isFinite(z.x)) continue;
        const d = Math.hypot(num(o.x) - z.x, num(o.y) - z.y);
        if (d <= z.r && (!best || d < best.d)) best = { id: z.cp.routePointId, d };
      }
      if (best) target = best.id;
    }
    if (target) byCp.get(target)[o.kind === 'vehicle' ? 'vehicles' : 'props'].push(o);
    else eventProps.push(o);
  }
  for (const cp of cps) {
    const g = byCp.get(cp.routePointId);
    cp.barricadeProps = g.props;
    cp.decorVehicles = g.vehicles;
    // the per-checkpoint "spawn" switches are gone - what is placed is spawned
    cp.barricades = true;
    cp.decorVehiclesEnabled = true;
  }
  return { props: eventProps, checkpoints: cps };
}

// Where the stored objects are: the centre of their bounding box (the placer camera starts there).
export function centroidOf(list) {
  const pts = (list || []).filter((o) => o && Number.isFinite(Number(o.x)) && Number.isFinite(Number(o.y)));
  if (!pts.length) return null;
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity, z = 0;
  for (const o of pts) {
    minX = Math.min(minX, Number(o.x)); maxX = Math.max(maxX, Number(o.x));
    minY = Math.min(minY, Number(o.y)); maxY = Math.max(maxY, Number(o.y));
    z += num(o.z);
  }
  // objects scattered far apart (e.g. several checkpoints): the middle of the box would be empty ground, so open on the first
  if (maxX - minX > 300 || maxY - minY > 300) return { x: Number(pts[0].x), y: Number(pts[0].y), z: num(pts[0].z) };
  return { x: (minX + maxX) / 2, y: (minY + maxY) / 2, z: z / pts.length };
}

// Stable identity of one object inside one event: Event ID + object uid (position fallback for very old saves).
export function objectKey(eventKey, o) {
  const id = o.uid || `${o.model}@${num(o.x).toFixed(2)},${num(o.y).toFixed(2)},${num(o.z).toFixed(2)}`;
  return `${eventKey || 'draft'}:${id}`;
}
