import { invoke } from './nui.js';

export const getSavedRoutes = () => invoke('nova_convoytruck:getSavedRoutes');
export const getSavedRouteDetail = (id) => invoke('nova_convoytruck:getSavedRouteDetail', id);
// kind: 'CONVOY' | 'HOT_CARGO' | 'GANG_AIRDROP'; payload shape depends on it —
// { route, checkpoints, airdrops } / { spawnZones, dropoffZones } / { airdropZones }
export const saveRouteTemplate = (name, kind, payload) =>
  invoke('nova_convoytruck:saveRouteTemplate', name, kind, payload);
export const updateRouteTemplate = (id, payload) =>
  invoke('nova_convoytruck:updateRouteTemplate', id, payload);
export const importRouteTemplate = (id) => invoke('nova_convoytruck:importRouteTemplate', id);
export const deleteRouteTemplate = (id) => invoke('nova_convoytruck:deleteRouteTemplate', id);
export const deleteAllRouteTemplates = () => invoke('nova_convoytruck:deleteAllRouteTemplates');
