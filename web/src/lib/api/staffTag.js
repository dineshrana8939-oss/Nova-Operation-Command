import { fetchNui } from './nui.js';

// The "ADMIN" / "EVENT STAFF" tag over the player's own head (client/modules/staff_tag.lua).
// get -> { ok, available: 'ADMIN' | 'EVENT STAFF' | null, enabled }   set -> the server decides whether the player may wear it
export const getStaffTag = () => fetchNui('staffTag:get', {});
export const setStaffTag = (enabled) => fetchNui('staffTag:set', { enabled: !!enabled });
