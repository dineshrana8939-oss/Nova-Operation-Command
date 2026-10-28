// Last result of each list view, kept for the whole session. Every tab used to be destroyed on a switch and then show "Loading"
// while it asked the server again. A view now starts from what it showed last time (so it opens at once) and still refreshes from
// the server straight away: stale-while-revalidate. peek() = what we had (or undefined), keep() = remember a fresh answer.
const store = new Map();
export const peek = (key) => store.get(key);
export const keep = (key, value) => { store.set(key, value); return value; };
