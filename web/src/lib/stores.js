import { writable } from 'svelte/store';

export const tabletOpen = writable(false);
export const tabletMinimized = writable(false);
export const livePanelOpen = writable(false);
export const livePanelBrand = writable({ title: 'Event Status', badge: 'LIVE' });
const initialView = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_tab')) || 'dashboard';
export const currentView = writable(initialView);
if (typeof localStorage !== 'undefined') {
  currentView.subscribe((val) => {
    if (val) localStorage.setItem('nova_convoy_last_tab', val);
  });
}
// The open view can have sub pages (Announcements: events / custom / banners, Settings: general / World Peds). They are chosen from the
// floating row under the main menu, so the choice lives here and the view reads it.
const initialSub = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_view_sub')) || null;
export const viewSub = writable(initialSub);
if (typeof localStorage !== 'undefined') {
  viewSub.subscribe((val) => {
    if (val) localStorage.setItem('nova_convoy_last_view_sub', val); else localStorage.removeItem('nova_convoy_last_view_sub');
  });
}
export const bootstrap = writable(null);

// Bumped by App.svelte whenever the server broadcasts that SOME convoy's
// definition changed (created/edited/scheduled/started/deleted by anyone,
// not just this player) — convoy_manager.lua's broadcastStartPeds now
// piggybacks this alongside its own start-ped sync, since every mutation
// already calls it. Manage Convoys/Airdrops previously only re-read its
// list on mount or a manual Refresh click, so an event someone else just
// created/changed silently never appeared for anyone already sitting on
// that screen. Plain incrementing counter (not the data itself) — each
// consumer still fetches its own shape via its own existing API call, this
// just tells it "go do that again."
export const convoyListVersion = writable(0);

// Bumped whenever the server says THIS player's staff access (or the staff / roles list) changed — a role was
// reassigned, permissions edited, access revoked. Tablet.svelte re-fetches its bootstrap on it (so sections appear /
// disappear at once, or the tablet closes if access is gone) and the Staff Management screen reloads its lists.
export const staffVersion = writable(0);

// Bumped when a gang's roles, ranks, members or settings changed — from the admin tablet's Gang Management OR from the gang's own
// Event Status panel (both edit the same stored data). Whichever of the two is open re-reads at once. { n, gangId, gangName }.
export const gangVersion = writable({ n: 0, gangId: null, gangName: null });

// Set once by App.svelte when the client-side Route Recorder (drive/walk the
// path, drop points with a key, see route_recorder.lua) finishes and sends
// its captured points back. RouteBuilder reads this, appends the points to
// whichever convoy is currently open, then clears it back to null.
export const routeRecordingResult = writable(null);

// Same idea as routeRecordingResult but for zone_recorder.lua — Hot Cargo
// (spawn/dropoff zones) and Gang Airdrop (drop zones) walking-and-dropping a
// point at a time instead of a connected route. Points come back tagged 'A'
// (primary/[E]) or 'B' (secondary/[K]); the screen that started the session
// decides what each becomes.
export const zoneRecordingResult = writable(null);
export const toastQueue = writable([]);

// Emitted by the client when an admin deletes a placed barricade prop in-world
// via ox_target (aim at the prop → "Remove Barricade Prop") rather than the
// tablet's own list. RouteBuilder subscribes, then drops that entry from the
// matching checkpoint's stashed prop list so the next save/preview doesn't
// resurrect a prop the admin just deleted.
export const barricadePropRemoved = writable(null);

// Same as barricadePropRemoved above, but for checkpoint decor
// vehicles (police/army cars placed for ambience) — separate stores because
// they're a separate stashed list per checkpoint (cp.decorVehicles, not
// cp.barricadeProps), removed via their own ox_target option.
export const decorVehicleRemoved = writable(null);

// Practice Range squad join-UI (PracticeArmory.svelte) — opened by the
// instructor ped instead of the old lib.registerContext chain once squad
// practice landed. practiceArmoryData holds { locations, weapons, squad, isHost }
// and is fully replaced on every server-pushed roster update while open.
export const practiceArmoryOpen = writable(false);
export const practiceArmoryData = writable({ locations: [], weapons: [], squad: [], isHost: true });

// Post-match results screen (MatchResults.svelte) — shared by TDM ('event')
// and Practice Range ('practice') endings. matchResultsData holds
// { mode, eventName, duration, scoreA, scoreB, players }.
export const matchResultsOpen = writable(false);
export const matchResultsData = writable({ mode: 'practice', players: [] });

let toastId = 0;
export function pushToast(toast) {
  const id = ++toastId;
  toastQueue.update((list) => [...list, { id, ...toast }]);
  setTimeout(() => {
    toastQueue.update((list) => list.filter((t) => t.id !== id));
  }, toast.duration || 4000);
}

// One-shot hand-off between tabs: Create Event sets this to 'create' after a
// Tournament-format TDM arena is saved, and the Tournament tab consumes it on
// mount by opening its create form straight away (then clears it).
export const tournamentIntent = writable(null);
// Manage Events → Announce hands one event id to Announcements → Event Announcements, which opens that event's announcement window
export const announceEventId = writable(null);
// the Tournament Tree page sets this to hand one tournament to the Tournaments page ('Open in Tournaments')
export const tournamentOpenId = writable(null);

// Set when an admin picks "Edit in Prop Placer" on a previewed checkpoint prop / decor vehicle in the world
// (route_editor.lua). RouteBuilder opens the shared Prop Placer on that checkpoint with that object selected.
// { kind: 'object' | 'vehicle', cpKey, index }
export const propEditRequest = writable(null);

export const civilianRegistrationOpen = writable(false);
export const civilianRegistrationData = writable(null);
