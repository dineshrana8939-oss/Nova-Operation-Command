import { derived } from 'svelte/store';
import { bootstrap } from './stores.js';

// What the signed-in tablet user may do, as decided by the SERVER (getBootstrap → `perms`): an object of
// 'section.action' keys that are true, e.g. { 'gangs.view': true, 'gangs.edit': true }. Real server admins get every key.
// This only drives what the UI shows — every action is checked again on the server, so hiding a button is never the
// security boundary.
export const perms = derived(bootstrap, (b) => (b && b.perms) || {});

// can($perms, 'gangs.edit')  → boolean
export const can = (p, key) => !!(p && p[key]);

// the sections a user may see in the sidebar (visible AND view — a hidden section is not reachable either)
export const canSeeSection = (p, id) => !!(p && p[`${id}.visible`] && p[`${id}.view`]);
