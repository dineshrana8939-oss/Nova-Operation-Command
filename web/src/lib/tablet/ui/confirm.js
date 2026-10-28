import { writable, get } from 'svelte/store';
import { adminPrefs } from '../../adminPrefs.js';

export const confirmState = writable(null); // { title, message, danger, resolve }

export function confirmAction(message, { title = 'Confirm', danger = false, confirmLabel = 'Confirm', cancelLabel = 'Cancel' } = {}) {
  // Settings → "Ask before routine actions": off = non-destructive confirmations resolve straight away. Anything marked
  // danger (delete, force end, cancel, XP removal...) is never skipped.
  if (!danger && get(adminPrefs).confirmRoutine === false) return Promise.resolve(true);
  return new Promise((resolve) => {
    confirmState.set({ title, message, danger, resolve, confirmLabel, cancelLabel });
  });
}
