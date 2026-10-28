// Polled screens (every few seconds) used to assign a freshly fetched array on every tick, which makes the screen
// re-render all of its rows even when nothing changed. Compare first, assign only when the data really differs.
export function sameData(a, b) {
  if (a === b) return true;
  try { return JSON.stringify(a) === JSON.stringify(b); } catch (e) { return false; }
}