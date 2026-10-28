import { invoke } from './nui.js';

// World Peds: permanent peds that belong to no event (the race Token Vendor, the TDM Practice Range instructor).
// listWorldPeds  → { ok, peds: [{ id, label, model, enabled, x, y, z, heading }] }
// setWorldPed    → `placed` (optional): { x, y, z, heading } from the ped placement hologram; without it the server uses where
//                  the admin stands. The ped moves for everyone online at once.
export const listWorldPeds = () => invoke('nova_convoytruck:worldPeds:list');
export const setWorldPed = (id, placed) => invoke('nova_convoytruck:worldPeds:set', id, placed || null);
export const setWorldPedEnabled = (id, enabled) => invoke('nova_convoytruck:worldPeds:setEnabled', id, enabled);
