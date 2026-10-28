import { writable } from 'svelte/store';

// Container Wars in-world info panels, one per visible container. The Lua side
// (client/modules/container_wars.lua) sends the full visible list every frame:
//   [{ id, mode: 'active' | 'won', x, y, scale,
//      containerNumber, containerName, highestBid, minNextBid,
//      highestGang, timeLeft, canBid, bidState, finalBid, winningGang }]
//   bidState: 'idle' | 'processing' | 'rejected' — only changes the key hint text
// x / y are 0..1 screen coordinates of the point above the container. An empty
// list hides everything.
export const containerInfos = writable([]);

export function setContainerInfos(list) {
  containerInfos.set(Array.isArray(list) ? list : []);
}
