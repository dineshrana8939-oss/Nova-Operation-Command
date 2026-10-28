import { invoke } from './nui.js';

// Same callbacks feed the admin Tournaments tab and the gang Event Status
// panel — the server decides what each caller may see (see tournament.lua).
export const listTournaments = () => invoke('nova_convoytruck:tournament:list');
export const getTournament = (id) => invoke('nova_convoytruck:tournament:get', id);

// Admin only.
export const getTournamentTemplates = () => invoke('nova_convoytruck:tournament:templates');
export const saveTournament = (payload) => invoke('nova_convoytruck:tournament:save', payload);
export const shuffleTournament = (id) => invoke('nova_convoytruck:tournament:shuffle', id);
export const lockTournament = (id) => invoke('nova_convoytruck:tournament:lock', id);
export const tournamentAction = (id, action, payload) => invoke('nova_convoytruck:tournament:action', id, action, payload || {});
export const saveTournamentExport = (id, fileName, base64) => invoke('nova_convoytruck:tournament:saveExport', id, fileName, base64);
