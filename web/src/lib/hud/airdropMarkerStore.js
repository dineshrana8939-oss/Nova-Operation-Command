import { writable } from 'svelte/store';

// Floating AIRDROP UI markers, one per visible crate. The Lua side
// (runtime_client.lua, ensureAirdropMarkerThread) sends the full visible list
// every frame: [{ id, x, y, scale, seconds, label }] with x/y in 0..1 screen
// space. An empty list hides everything.
export const airdropMarkers = writable([]);

export function setAirdropMarkers(list) {
  airdropMarkers.set(Array.isArray(list) ? list : []);
}
