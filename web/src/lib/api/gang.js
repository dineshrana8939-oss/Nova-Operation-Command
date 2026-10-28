import { invoke } from './nui.js';

export const getGangs = () => invoke('nova_convoytruck:getGangs');
export const createGang = (name, label, maxMembers) => invoke('nova_convoytruck:createGang', name, label, maxMembers);
export const updateGang = (gangId, fields) => invoke('nova_convoytruck:updateGang', gangId, fields);
export const deleteGang = (gangId) => invoke('nova_convoytruck:deleteGang', gangId);
export const addGangMember = (gangId, targetServerId, rank) => invoke('nova_convoytruck:addGangMember', gangId, targetServerId, rank);
// Online players who can be added to a gang right now: [{ serverId, name }]
export const getGangRecruitsAdmin = () => invoke('nova_convoytruck:getGangRecruitsAdmin');
export const removeGangMember = (gangId, identifier) => invoke('nova_convoytruck:removeGangMember', gangId, identifier);
export const setGangLeader = (gangId, identifier) => invoke('nova_convoytruck:setGangLeader', gangId, identifier);
export const setGangMemberRank = (gangId, identifier, rank) => invoke('nova_convoytruck:setGangMemberRank', gangId, identifier, rank);
export const setGangLogo = (gangId, logo) => invoke('nova_convoytruck:setGangLogo', gangId, logo);
export const setGangAccentColor = (gangId, color) => invoke('nova_convoytruck:setGangAccentColor', gangId, color);

// Gang-leader self-service (not admin-gated — see server/modules/callbacks.lua's myLedGang).
export const addOwnGangMember = (targetServerId, rank) => invoke('nova_convoytruck:addOwnGangMember', targetServerId, rank);
export const getAvailableGangRecruits = () => invoke('nova_convoytruck:getAvailableGangRecruits');
export const removeOwnGangMember = (identifier) => invoke('nova_convoytruck:removeOwnGangMember', identifier);
export const setOwnGangMemberRank = (identifier, rank) => invoke('nova_convoytruck:setOwnGangMemberRank', identifier, rank);
export const setOwnGangLeader = (identifier) => invoke('nova_convoytruck:setOwnGangLeader', identifier);
export const setOwnGangLogo = (logo) => invoke('nova_convoytruck:setOwnGangLogo', logo);

// Open to any player.
export const getGangLeaderboard = () => invoke('nova_convoytruck:getGangLeaderboard');
// ── Gang role permissions ────────────────────────────────────────────────────
// A gang leader grants these per RANK (ranks are the same rank strings the
// member list already assigns — there is no separate role list). The leader
// always holds both implicitly.
//   manageGang     — add/remove/promote members, edit gang settings
//   registerRoster — register the gang for events on the leader's behalf
// Both are enforced server-side (GangService.HasPermission); these only drive
// whether the UI shows the corresponding controls.
export const getGangRolePermissions = () => invoke('nova_convoytruck:getGangRolePermissions');
export const setGangRolePermission = (rank, permission, enabled) =>
  invoke('nova_convoytruck:setGangRolePermission', rank, permission, enabled);
export const saveGangRole = (rank, permissions) => invoke('nova_convoytruck:saveGangRole', rank, permissions);
export const renameGangRole = (oldRank, newRank) => invoke('nova_convoytruck:renameGangRole', oldRank, newRank);
export const deleteGangRole = (rank) => invoke('nova_convoytruck:deleteGangRole', rank);
// ── Gang roles, admin side ───────────────────────────────────────────────────
// The SAME roles the gang's leader edits in Event Status (one stored list, one set of server rules); an admin only names the
// gang. Every change pushes both panels to redraw.
export const getAdminGangRoles = (gangId) => invoke('nova_convoytruck:getAdminGangRoles', gangId);
export const setAdminGangRolePermission = (gangId, rank, permission, enabled) =>
  invoke('nova_convoytruck:setAdminGangRolePermission', gangId, rank, permission, enabled);
export const saveAdminGangRole = (gangId, rank, permissions) => invoke('nova_convoytruck:saveAdminGangRole', gangId, rank, permissions);
export const renameAdminGangRole = (gangId, oldRank, newRank) => invoke('nova_convoytruck:renameAdminGangRole', gangId, oldRank, newRank);
export const deleteAdminGangRole = (gangId, rank) => invoke('nova_convoytruck:deleteAdminGangRole', gangId, rank);
