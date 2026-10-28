import { writable } from 'svelte/store';

// Operation Crackdown, as the in-game HUD shows it (messages sent by client/modules/crackdown.lua).
//   state : the fixed part of the fight (name, gang, my side, the zone)        — null when no Crackdown is running for me
//   tick  : the live part, once a second (phase, clock, scores, who is alive, am I inside the zone ...)
//   result: the end card, shown for a few seconds after the fight
export const crackdownHud = writable({ state: null, tick: null, result: null });

let resultTimer = null;

export function handleCrackdownMessage(data) {
  switch (data.action) {
    case 'crackdown:state':
      crackdownHud.update((h) => ({ ...h, state: data.data, tick: null, result: null }));
      break;
    case 'crackdown:tick':
      crackdownHud.update((h) => (h.state ? { ...h, tick: data.data } : h));
      break;
    case 'crackdown:hide':
      crackdownHud.update((h) => ({ ...h, state: null, tick: null }));
      break;
    case 'crackdown:end':
      crackdownHud.update((h) => ({ ...h, state: null, tick: null, result: data.data || null }));
      clearTimeout(resultTimer);
      resultTimer = setTimeout(() => crackdownHud.update((h) => ({ ...h, result: null })), 12000);
      break;
    default:
      break;
  }
}
