import { writable, get, derived } from 'svelte/store';
import { DEFAULT_APPEARANCE, cleanAppearance, themeStyle, blueDefaultOnce } from './theme/appearance.js';

// Admin-panel preferences: kept in THIS browser (the game's NUI) and applied to every tab of the Operations Hub —
// table page size, clock format, sidebar density, map brightness, and whether routine actions ask for confirmation.
// Anything here is a personal view setting; server-wide settings live in the Settings tab's other sections.
const KEY = 'nova_admin_prefs';

export const PAGE_SIZE_CHOICES = [5, 10, 15, 25, 50];

export const DEFAULT_PREFS = {
  pageSize: 10,           // default rows per page for every table
  clock24: false,         // 24-hour clock in the header
  navLayout: 'top',       // 'top' = floating tabs across the top | 'side' = the classic side rail
  sidebar: 'comfortable', // side rail only: 'comfortable' | 'compact'
  mapBrightness: 110,     // % — basemap brightness on every territory / event map (100 = the raw atlas)
  confirmRoutine: true,   // ask before routine actions (Start, Reuse...). Destructive actions ALWAYS ask.
  ...DEFAULT_APPEARANCE,  // accent colour, dark background and UI click sounds — see lib/theme/appearance.js
};

function load() {
  try {
    const raw = typeof localStorage !== 'undefined' ? localStorage.getItem(KEY) : null;
    const saved = raw ? JSON.parse(raw) : {};
    const merged = { ...DEFAULT_PREFS, ...(saved && typeof saved === 'object' ? saved : {}) };
    return blueDefaultOnce({ ...merged, ...cleanAppearance(merged) }, 'admin');
  } catch (e) {
    return { ...DEFAULT_PREFS };
  }
}

export const adminPrefs = writable(load());

adminPrefs.subscribe((v) => {
  try { if (typeof localStorage !== 'undefined') localStorage.setItem(KEY, JSON.stringify(v)); } catch (e) { /* storage blocked: the prefs just last for this session */ }
});

export function resetAdminPrefs() { adminPrefs.set({ ...DEFAULT_PREFS }); }

// the CSS variables the Operations Hub root wears (empty for the default look)
export const adminThemeStyle = derived(adminPrefs, (p) => themeStyle('admin', p.accent, p.bgTheme));

// Initial page size for a table: the admin's preference, snapped to a size that table actually offers.
export function defaultPageSize(sizes) {
  const want = get(adminPrefs).pageSize;
  const list = (sizes && sizes.length ? sizes : PAGE_SIZE_CHOICES).slice().sort((a, b) => a - b);
  return list.reduce((best, n) => (Math.abs(n - want) < Math.abs(best - want) ? n : best), list[0]);
}
