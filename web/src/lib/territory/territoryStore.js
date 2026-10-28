import { writable, get } from 'svelte/store';
import { getTerritoryState, getTerritoryRivals } from '../api/territory.js';
import { handleHudMessage } from '../hud/hudStore.js';

// One live picture of the territory system, shared by the admin tablet (Territory Control, the Rivals tab) and the gang
// tablet (Event Status → Territory). The server pushes every change (ownership, expansion, XP, challenge, war) and
// client/modules/territory.lua forwards it here as a NUI message — so no screen ever needs a refresh, a reopen, or a
// resource restart to be correct.

export const territoryState = writable({
  loaded: false,
  isAdmin: false,
  adminXpBlocked: false, // an admin who also leads a gang may not add / remove Gang XP (server-enforced)
  me: null,            // { name, label, logo, color, xp, lifetimeXp, canManage }
  territories: [],     // full views (painted shapes included)
  gangs: [],           // [{ name, label, logo, color }]
  rivals: [],          // challenges / wars (open + recent)
  candidates: [],      // rival territories my gang could challenge right now
  auction: null,       // the running territory auction, if any
  config: {},
});

// The live Gang XP table (every gang) — pushed by the server whenever any gang's XP or territory count moves
export const xpBoard = writable({ loaded: false, gangs: [] });

// Bumped whenever the challenge list may have changed (the screens refetch it)
export const rivalsVersion = writable(0);
// Bumped for every live update so a map can re-render even when it holds the same array
export const territoryTick = writable(0);

// What the in-game HUD shows
export const territoryHud = writable({
  auction: null,       // { state, tick }
  auctionVisible: false,   // the floating auction panel shows while a gang member is near the projector
  canBid: false,           // standing in the auction zone (key prompt)
  war: null,           // { war, tick }
  warResult: null,
  outOfBounds: { active: false, secondsLeft: 0, maxSeconds: 35, title: '', subtitle: '' },
  eliminatedBlocked: { active: false, message: '' },
});

let loading = null;

// The painted shapes are the heavy part of the territory data. The tablet tells the server which shape revisions it already holds and
// the server leaves those out; they are put back from what is already in the store. If one is missing (an update raced the
// request) the full list is asked for once.
export async function refreshTerritoryState() {
  if (loading) return loading;
  loading = (async () => {
    try {
      const have = new Map(get(territoryState).territories.filter((t) => t.geo && t.rev != null).map((t) => [t.id, t]));
      const known = {};
      for (const [id, t] of have) known[id] = t.rev;
      let res = await getTerritoryState(known);
      let territories = res && res.ok ? res.territories || [] : [];
      let missing = false;
      territories = territories.map((t) => {
        if (t.geo) return t;
        const old = have.get(t.id);
        if (old && old.rev === t.rev) return { ...t, geo: old.geo };
        missing = true;
        return t;
      });
      if (missing) {
        res = await getTerritoryState({});
        territories = res && res.ok ? res.territories || [] : [];
      }
      if (res && res.ok) {
        territoryState.set({
          loaded: true, isAdmin: !!res.isAdmin, adminXpBlocked: !!res.adminXpBlocked, me: res.me || null, territories, gangs: res.gangs || [],
          rivals: res.rivals || [], candidates: res.candidates || [], auction: res.auction || null, config: res.config || {},
        });
      }
      return res;
    } finally {
      loading = null;
    }
  })();
  return loading;
}

export async function refreshRivals() {
  const res = await getTerritoryRivals();
  if (res && res.ok) {
    territoryState.update((s) => ({
      ...s, rivals: res.rivals || [], candidates: res.candidates || [], me: res.me || s.me, auction: res.auction || null,
    }));
  }
  return res;
}

function upsertTerritories(list) {
  let needFull = false;
  territoryState.update((s) => {
    if (!s.loaded) return s;    // not fetched yet: the screen loads the full list when it opens
    const byId = new Map((s.territories || []).map((t) => [t.id, t]));
    for (const t of list || []) {
      // an update without shapes (a new owner, a war flag, a gang colour) keeps the shapes already held
      const old = byId.get(t.id);
      if (t.geo) byId.set(t.id, t);
      else if (old && old.geo) byId.set(t.id, { ...t, geo: old.geo });
      else { byId.set(t.id, t); needFull = true; }   // a territory we have never seen, without its land: ask for it
    }
    return { ...s, territories: [...byId.values()] };
  });
  territoryTick.update((n) => n + 1);
  if (needFull) refreshTerritoryState();
}

function showToast(title, message, type = 'info') {
  handleHudMessage({ action: 'showToast', icon: type === 'success' ? '✔' : (type === 'warn' ? '⚠' : '🗺'), title, message, type, duration: 8000 });
}

// NUI messages from client/modules/territory.lua
export function handleTerritoryMessage(data) {
  switch (data.action) {
    case 'territory:upsert':
      upsertTerritories(data.territories);
      break;
    case 'territory:remove':
      territoryState.update((s) => ({ ...s, territories: (s.territories || []).filter((t) => t.id !== data.id) }));
      territoryTick.update((n) => n + 1);
      break;
    case 'territory:xp':
      territoryState.update((s) => (s.me && s.me.name === data.gang ? { ...s, me: { ...s.me, xp: data.total, lifetimeXp: data.lifetime } } : s));
      break;
    case 'territory:paintConfig':
      // an admin changed the price of painting land: every open Map Zone (admin and gang) re-prices at once
      territoryState.update((s) => ({ ...s, config: { ...(s.config || {}), paint: { ...((s.config || {}).paint || {}), ...(data.paint || {}) } } }));
      break;
    case 'territory:xpBoard':
      xpBoard.set({ loaded: true, gangs: data.gangs || [] });
      break;
    case 'territory:rivalsChanged':
      rivalsVersion.update((n) => n + 1);
      if (get(territoryState).loaded) refreshRivals();
      break;
    case 'territory:toast': {
      const warn = ['rival', 'challenge', 'war-reminder', 'capture', 'war-cancelled', 'challenge-declined'].includes(data.kind);
      showToast(data.title, data.message, warn ? 'warn' : (data.kind === 'expansion' || data.kind === 'challenge-accepted' ? 'success' : 'info'));
      break;
    }
    case 'territory:auctionState':
      territoryState.update((s) => ({ ...s, auction: data.state || null }));
      territoryHud.update((h) => ({ ...h, auction: data.state ? { state: data.state, tick: null } : null }));
      break;
    case 'territory:auctionTick':
      territoryHud.update((h) => (h.auction ? { ...h, auction: { ...h.auction, tick: data.tick } } : h));
      break;
    case 'territory:auctionView':
      territoryHud.update((h) => ({ ...h, auctionVisible: !!data.visible, canBid: !!data.canBid }));
      break;
    case 'territory:auctionEnded':
      territoryState.update((s) => ({ ...s, auction: null }));
      territoryHud.update((h) => ({ ...h, auction: null, auctionVisible: false }));
      break;
    case 'territory:warStart':
      territoryHud.update((h) => ({ ...h, war: { war: data.war, tick: null }, warResult: null }));
      break;
    case 'territory:warTick':
      territoryHud.update((h) => (h.war ? { ...h, war: { ...h.war, tick: data.tick } } : h));
      break;
    case 'territory:warEnd':
      territoryHud.update((h) => ({
        ...h,
        war: null,
        warResult: data.result,
        outOfBounds: { active: false, secondsLeft: 0, maxSeconds: 35 },
        eliminatedBlocked: { active: false, message: '' },
      }));
      setTimeout(() => territoryHud.update((h) => ({ ...h, warResult: null })), 12000);
      break;
    case 'territory:eliminatedState':
      territoryHud.update((h) => {
        if (!h.war) return h;
        const tick = h.war.tick ? { ...h.war.tick, eliminated: !!data.eliminated } : null;
        const war = h.war.war ? { ...h.war.war, eliminated: !!data.eliminated } : null;
        return { ...h, war: { war, tick } };
      });
      break;
    case 'territory:eliminatedBlocked':
      territoryHud.update((h) => ({
        ...h,
        eliminatedBlocked: {
          active: !!data.active,
          message: data.message || '',
        },
      }));
      break;
    case 'territory:outOfBounds':
      territoryHud.update((h) => ({
        ...h,
        outOfBounds: {
          active: !!data.active,
          secondsLeft: data.secondsLeft ?? 0,
          maxSeconds: data.maxSeconds ?? 35,
          title: data.title || '',
          subtitle: data.subtitle || '',
        },
      }));
      break;
    default:
      break;
  }
}
