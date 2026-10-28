import { invoke } from './nui.js';

// Everything the territory screens ask of the server. The server decides who the caller is and what they may do;
// these only carry keys (territory id, rival id, a price the player confirmed) — never a gang name or an owner.

// Gang tablet + admin
// `known` = { territoryId: shape revision } the tablet already holds: those territories come back without their painted shapes.
export const getTerritoryState = (known) => invoke('nova_convoytruck:territory:getState', known || {});
export const getTerritoryRivals = () => invoke('nova_convoytruck:territory:getRivals');
export const getTerritoryHistory = (territoryId) => invoke('nova_convoytruck:territory:getTerritoryHistory', territoryId || null);
export const getAuctionHistory = (eventId) => invoke('nova_convoytruck:territory:getAuctionHistory', eventId || null);
export const getXpBoard = () => invoke('nova_convoytruck:territory:getXpBoard');
export const getXpHistory = (filters) => invoke('nova_convoytruck:territory:getXpHistory', filters || {});

// Rival challenges
export const sendChallenge = (mineId, theirsId) => invoke('nova_convoytruck:territory:sendChallenge', mineId, theirsId);
// comment: what the answering gang tells the admins (shown under that challenge on the admin Rival Wars tab)
export const respondChallenge = (rivalId, accept, comment) => invoke('nova_convoytruck:territory:respondChallenge', rivalId, !!accept, comment || '');

// Admin only
export const adminScheduleWar = (rivalId, dateTimeLocal, minutes, penaltyXp) =>
  invoke('nova_convoytruck:territory:adminScheduleWar', rivalId, dateTimeLocal, minutes, penaltyXp === '' ? null : penaltyXp);
// Accept / decline a PENDING challenge on behalf of the challenged gang
export const adminRespondRival = (rivalId, accept) => invoke('nova_convoytruck:territory:adminRespondRival', rivalId, !!accept);
// The war zone an admin draws for a challenge: { shape: 'circle' | 'square', x, y, z, size } (size = radius, or half the side). null clears it.
// It only appears in the world once that war starts.
export const adminSetWarZone = (rivalId, zone) => invoke('nova_convoytruck:territory:adminSetWarZone', rivalId, zone || null);
// One announcement for ONE challenge: previewOnly = only the admin sees it, otherwise the members of the two gangs only
export const adminAnnounceRival = (rivalId, title, body, previewOnly) => invoke('nova_convoytruck:territory:adminAnnounceRival', rivalId, title, body, !!previewOnly);
export const adminStartWar = (rivalId) => invoke('nova_convoytruck:territory:adminStartWar', rivalId);
export const adminCancelRival = (rivalId, note) => invoke('nova_convoytruck:territory:adminCancelRival', rivalId, note || '');
// The live price of painting land. Empty / null for a field = back to the value in config.lua.
export const adminSetPaintRate = (xpPerCell, maxNewCells) => invoke('nova_convoytruck:territory:adminSetPaintRate', xpPerCell === '' ? null : xpPerCell, maxNewCells === '' ? null : maxNewCells);
// Staff -> a gang: a warning or a notice every member sees; and disbanding a gang together with its territories.
export const adminNotifyGang = (gang, kind, message) => invoke('nova_convoytruck:territory:adminNotifyGang', gang, kind, message);
export const adminDisbandGang = (gang, mode, reason) => invoke('nova_convoytruck:territory:adminDisbandGang', gang, mode, reason || '');
export const adminAdjustXp = (gang, delta, reason) => invoke('nova_convoytruck:territory:adminAdjustXp', gang, delta, reason || '');
export const adminRemoveTerritory = (territoryId) => invoke('nova_convoytruck:territory:adminRemoveTerritory', territoryId);
// Wipes the land of a territory (staff never paint; this only takes stale land away)
export const adminClearLand = (territoryId) => invoke('nova_convoytruck:territory:adminClearLand', territoryId);
export const adminCreateTerritory = (data) => invoke('nova_convoytruck:territory:adminCreateTerritory', data || {});
export const adminSetOwner = (territoryId, gang, reason) => invoke('nova_convoytruck:territory:adminSetOwner', territoryId, gang || '', reason || '');

// Map editor (gangs only — staff never paint): `spans` = the territory's whole gang-painted layer, `cost` = the XP price the player SAW and confirmed.
export const paintTerritory = (territoryId, spans, cost) => invoke('nova_convoytruck:territory:paint', territoryId, spans, cost);
