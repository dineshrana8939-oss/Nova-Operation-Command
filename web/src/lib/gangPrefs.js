import { writable, derived } from 'svelte/store';
import { DEFAULT_APPEARANCE, cleanAppearance, themeStyle, blueDefaultOnce } from './theme/appearance.js';

// Gang Tablet (Event Status panel) preferences: kept in THIS player's own game browser, separate from the Admin Panel's
// (adminPrefs.js), so the two windows can look and sound different. Holds the accent colour, the dark background and
// the UI click-sound switch. The custom-crosshair switch is NOT here: that preference lives with the crosshair system
// itself (client KVP, see client/modules/crosshair.lua).
const KEY = 'nova_gang_prefs';

export const DEFAULT_GANG_PREFS = { ...DEFAULT_APPEARANCE };

function load() {
  try {
    const raw = typeof localStorage !== 'undefined' ? localStorage.getItem(KEY) : null;
    return blueDefaultOnce(cleanAppearance(raw ? JSON.parse(raw) : {}), 'gang');
  } catch (e) {
    return { ...DEFAULT_GANG_PREFS };
  }
}

export const gangPrefs = writable(load());

gangPrefs.subscribe((v) => {
  try { if (typeof localStorage !== 'undefined') localStorage.setItem(KEY, JSON.stringify(v)); } catch (e) { /* storage blocked: it lasts for this session */ }
});

export function resetGangPrefs() { gangPrefs.set({ ...DEFAULT_GANG_PREFS }); }

// the CSS variables the panel root wears
export const gangThemeStyle = derived(gangPrefs, (p) => themeStyle('gang', p.accent, p.bgTheme));
