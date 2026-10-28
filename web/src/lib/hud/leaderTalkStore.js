import { writable } from 'svelte/store';

// The gang-leader conversation opened by client/modules/leader_talk.lua:
// { speaker: { label, sub, color, logo, gang, staff }, line, facts: [{ k, v }], options: [{ id, label }], node } or null
export const leaderTalk = writable(null);
