import { writable } from 'svelte/store';

// The WINS / DEFEATED banner and the overhead player cards shown right after a TDM match (client/modules/tdm.lua feeds it):
// { banner: { result: 'win' | 'loss' | 'draw', gangName, logo, accent, eventName, cards: [{ sid, name, rank, xp, kills, deaths, place }] }, pos: { [sid]: { x, y, on } } } or null
export const tdmOutcome = writable(null);
