import { invoke } from './nui.js';

// Staff Management (admin tablet). Every reply is { ok, error?, ... } — the server re-checks every permission.
//
// FiveM's json.encode turns an EMPTY Lua table into [] (an array), so any map can arrive as [] when empty. Every map is
// normalised to a plain object here, once, on receipt — a JS array that gets string keys assigned to it silently loses
// them in JSON.stringify. Anything we send back is always a plain object.
export const asMap = (v) => (Array.isArray(v) || v == null || typeof v !== 'object' ? {} : v);

const normMember = (m) => (m ? { ...m, overrides: asMap(m.overrides), effective: asMap(m.effective) } : m);
const normRole = (r) => (r ? { ...r, permissions: asMap(r.permissions) } : r);

function normalise(res) {
  if (!res || typeof res !== 'object' || res.ok === false) return res;
  const out = { ...res };
  if (Array.isArray(out.staff)) out.staff = out.staff.map(normMember);
  if (Array.isArray(out.roles)) out.roles = out.roles.map(normRole);
  if (out.member) out.member = normMember(out.member);
  if (out.role) out.role = normRole(out.role);
  if (out.me) out.me = { ...out.me, keys: asMap(out.me.keys) };
  return out;
}
const call = async (name, ...args) => normalise(await invoke(name, ...args));

export const getStaffOverview = () => call('nova_convoytruck:staff:getOverview');
// Online players that can be added as staff: [{ serverId, name, identifier, isStaff, gang, job }]
export const getStaffOnlinePlayers = () => call('nova_convoytruck:staff:getOnlinePlayers');
export const addStaff = (serverIdOrIdentifier, roleId) => call('nova_convoytruck:staff:add', serverIdOrIdentifier, roleId);
// patch = { roleId?, overrides? } — `overrides` REPLACES the whole override map.
export const updateStaff = (identifier, patch) => call('nova_convoytruck:staff:update', identifier, patch);
// status: 'active' | 'disabled' | 'revoked'
export const setStaffStatus = (identifier, status) => call('nova_convoytruck:staff:setStatus', identifier, status);
export const removeStaff = (identifier) => call('nova_convoytruck:staff:remove', identifier);
// role = { id?, name, description, permissions: { 'section.action': true } }
export const saveStaffRole = (role) => call('nova_convoytruck:staff:saveRole', role);
// A role that still has staff answers { ok:false, code:'NEEDS_REASSIGN', staffCount } until reassignRoleId is given.
export const deleteStaffRole = (roleId, reassignRoleId = null) => call('nova_convoytruck:staff:deleteRole', roleId, reassignRoleId);
export const getStaffLog = (limit = 200) => call('nova_convoytruck:staff:getLog', limit);
