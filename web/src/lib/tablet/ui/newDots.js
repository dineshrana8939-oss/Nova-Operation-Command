import { writable } from 'svelte/store';

// "Something new here" dots on tabs. Each page reports a SIGNATURE of what it holds (a count, a version, a list of ids); the signature the
// player last SAW is kept in this browser. A page whose signature differs from the one seen, and that is not the open page, gets a dot;
// opening the page marks it seen. The first time a page is ever reported nothing counts as new (no dots on a fresh install).
//   const dots = newDots('some_storage_key');
//   $: dots.update({ pageId: 'signature', other: null }, openPageId);   // null = not known yet
//   {#if $dots[pageId]}<i class="new-dot"></i>{/if}
export function newDots(storageKey) {
  const dots = writable({});
  let seen = {};
  try { seen = JSON.parse(localStorage.getItem(storageKey) || '{}') || {}; } catch (e) { seen = {}; }
  const save = () => { try { localStorage.setItem(storageKey, JSON.stringify(seen)); } catch (e) { /* storage blocked: dots last for this session */ } };
  function update(signals, current) {
    const out = {};
    let dirty = false;
    for (const [id, sig] of Object.entries(signals || {})) {
      if (sig == null) continue;
      const s = String(sig);
      if (seen[id] === undefined || id === current) { if (seen[id] !== s) { seen[id] = s; dirty = true; } continue; }
      if (seen[id] !== s) out[id] = true;
    }
    if (dirty) save();
    dots.set(out);
  }
  return { subscribe: dots.subscribe, update };
}
