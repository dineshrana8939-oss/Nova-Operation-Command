import { writable } from 'svelte/store';

// The vendor window opened by client/modules/ped_menu.lua: { title, subtitle, items: [{ id, label, desc, price, tag }], accounts } or null
export const pedMenu = writable(null);
