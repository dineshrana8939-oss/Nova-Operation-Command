import { fetchNui } from './nui.js';

// Practice Range Armory screen — see client/modules/practice_range.lua's
// RegisterNUICallback handlers for the Lua side of each of these.
export const closePracticeArmory = () => fetchNui('practiceArmory:close');
export const invitePracticeSquad = (name) => fetchNui('practiceArmory:invite', { name });
export const kickPracticeSquad = (memberSource) => fetchNui('practiceArmory:kick', { source: memberSource });
export const deployPractice = (locationId, weapon) => fetchNui('practiceArmory:deploy', { locationId, weapon });
// Pushed whenever a squad member changes their own weapon pick — the host's
// Deploy call only carries ITS OWN location/weapon choice, so every member
// (host included) needs to keep the server's per-source weapon record
// current or their squadmate's loadout would silently fall back to default.
export const selectPracticeWeapon = (weapon) => fetchNui('practiceArmory:selectWeapon', { weapon });
