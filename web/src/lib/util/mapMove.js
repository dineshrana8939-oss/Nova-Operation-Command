// How a pin moved on a map reaches the vectors of an event, the SAME way for every event kind (convoy route, rally stages, airdrop
// zones, hot cargo spawns / trucks / dropoffs). The map used to edit the object it had drawn IN PLACE and the screen only
// refreshed on release; an object that had been replaced meanwhile never received the move, and nothing updated while dragging.
//   · during a drag the map sends  pointDrag { id, x, y }   -> applyLive()   (x / y follow the pin, about ten times a second)
//   · on release it sends          pointMove { id, x, y, point } -> applyMove()  (final x / y, a spawn zone's truck vector)
//   · a moment later the game's ground height arrives as pointMove { id, x, y, z } -> applyMove() sets z
// Every function works on a copy and matches by id, so it cannot miss because the object it was handed was a stale one.

const TRUCK_KEYS = ['truckX', 'truckY', 'truckZ'];

export function applyMove(list, d) {
  if (!Array.isArray(list) || !d || d.id == null) return list;
  let hit = false;
  const out = list.map((o) => {
    if (!o || o.id !== d.id) return o;
    hit = true;
    const next = { ...o };
    if (d.x != null) next.x = d.x;
    if (d.y != null) next.y = d.y;
    if (d.z != null) next.z = d.z;
    const p = d.point || {};
    for (const k of TRUCK_KEYS) if (p[k] != null) next[k] = p[k];   // a spawn zone's precise truck vector moves with it
    return next;
  });
  return hit ? out : list;
}

export function applyLive(list, d) {
  if (!Array.isArray(list) || !d || d.id == null) return list;
  let hit = false;
  const out = list.map((o) => {
    if (!o || o.id !== d.id) return o;
    hit = true;
    return { ...o, x: d.x, y: d.y };
  });
  return hit ? out : list;
}

// Throttles the live updates: only the newest position is applied, at most once per `ms`.
export function liveThrottle(apply, ms = 100) {
  let timer = null;
  let latest = null;
  const run = () => { timer = null; const d = latest; latest = null; if (d) apply(d); };
  const push = (d) => { latest = d; if (!timer) timer = setTimeout(run, ms); };
  push.cancel = () => { if (timer) { clearTimeout(timer); timer = null; } latest = null; };
  return push;
}
