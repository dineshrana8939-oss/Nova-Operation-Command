import { fetchNui } from './nui.js';

// The text of docs/user_guide.md plus the command names this script registers. The server reads the file from disk on every
// call, so an edit shows the next time the Guide tab loads. Resolves to { ok, text, commands } or { ok: false, error }.
export const loadUserGuide = () => fetchNui('guide:load');
