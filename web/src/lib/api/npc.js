import { invoke } from './nui.js';

export const getSpawnZones = () => invoke('nova_convoytruck:getSpawnZones');
export const createSpawnZone = (label, kind, radius) => invoke('nova_convoytruck:createSpawnZone', label, kind, radius);
export const deleteSpawnZone = (id) => invoke('nova_convoytruck:deleteSpawnZone', id);
