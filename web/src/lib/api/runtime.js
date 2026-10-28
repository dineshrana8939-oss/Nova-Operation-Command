import { invoke } from './nui.js';

export const startRaceCountdown = (id) => invoke('nova_convoytruck:startRaceCountdown', id);
export const startConvoy = (id) => invoke('nova_convoytruck:startConvoy', id);
export const testRunConvoy = (id) => invoke('nova_convoytruck:testRunConvoy', id);
export const joinConvoyGang = (id) => invoke('nova_convoytruck:joinConvoyGang', id);
export const leaveConvoyGang = (id) => invoke('nova_convoytruck:leaveConvoyGang', id);
export const joinConvoyPolice = (id) => invoke('nova_convoytruck:joinConvoyPolice', id);
export const leaveConvoyPolice = (id) => invoke('nova_convoytruck:leaveConvoyPolice', id);
export const getActiveConvoys = () => invoke('nova_convoytruck:getActiveConvoys');
export const getRosterConvoys = () => invoke('nova_convoytruck:getRosterConvoys');
export const setConvoyRoster = (id, identifiers) => invoke('nova_convoytruck:setConvoyRoster', id, identifiers);
// Container Wars / Territory Auction: the whole gang registers (on = true) or unregisters, no member list
export const setGangRegistered = (id, on) => invoke('nova_convoytruck:setGangRegistered', id, on);
// Upcoming (draft/scheduled, not yet departed) convoys — lets both gangs and
// police see what's coming and pre-register before it starts, instead of
// only finding out once it's already active.
export const getUpcomingConvoys = () => invoke('nova_convoytruck:getUpcomingConvoys');
export const registerPoliceForConvoy = (id) => invoke('nova_convoytruck:registerPoliceForConvoy', id);
export const unregisterPoliceForConvoy = (id) => invoke('nova_convoytruck:unregisterPoliceForConvoy', id);
// A non-leader gang member backing themselves out of a convoy their leader
// signed them up for — the leader can already do this via the roster
// picker (setConvoyRoster), this is the self-service equivalent for anyone
// who isn't the leader.
export const unregisterSelfFromGangConvoy = (id) => invoke('nova_convoytruck:unregisterSelfFromGangConvoy', id);
// Server-decided capabilities for the Convoy Status panel. The panel's command
// is gated server-side (see client/modules/live_panel.lua), so this only tells
// the UI which tabs to render — never act on it as an authorization decision.
// Returns { ok, allowed, isAdmin, canManageGang, canRegisterRoster, isLeader,
//           gangRank, gangName, gangLabel }.
//
// canManageGang / canRegisterRoster reflect the gang's own ROLE permissions, so
// a member a leader granted either one gets the same affordances as a leader.
// This is refreshed with the convoy data on every poll, so a grant/revoke
// lands without reopening the panel.
export const getStatusPanelAccess = () => invoke('nova_convoytruck:getStatusPanelAccess');