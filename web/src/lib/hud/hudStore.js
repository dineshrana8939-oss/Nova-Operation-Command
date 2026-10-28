import { writable } from 'svelte/store';
import { THEMES, inferEventKey } from './eventThemes.js';

// Mirrors the exact NUI message contract shared/html.lua has always sent
// (action strings unchanged) so the legacy convoy gameplay needs zero Lua
// changes — only the rendering moved from html/index.html to Svelte.

export const checkpointHud = writable({ visible: false, index: 1, total: 1, seconds: 0, maxSeconds: 1, paused: false });
export const deliveryHud = writable({ visible: false, seconds: 0, maxSeconds: 1, kind: 'DELIVERY' });
export const announcement = writable({ visible: false, title: '', message: '', type: 'info', gang: null, status: null, bannerColor: null, imageUrl: null, imagePosition: null, imageFit: null, durationMs: 7000, key: 0 });
export const toast = writable({ visible: false, icon: '✔', title: '', message: '', type: 'success', key: 0 });
// Player notifications (Toast.svelte): a short stack of cards, newest last. `position` and `maxVisible` come from
// Config.Notify on every message, so a server edit takes effect without touching the UI.
export const notifications = writable({ items: [], position: 'top-right' });
// Personal reward card (RewardAnnouncement.svelte). Cards queue so a second payout
// never overwrites the first; each is shown for a few seconds in turn.
export const rewardCard = writable({ visible: false, card: null, key: 0, durationMs: 7000 });
export const gangSquad = writable({ visible: false, roster: [], gang: null });
export const policeSquad = writable({ visible: false, roster: [] });
// Convoy progress card (ConvoyProgress.svelte): cargo trucks delivered and checkpoints cleared, top-left.
export const convoyProgress = writable({ visible: false, delivered: 0, totalTrucks: 0, checkpointsDone: 0, checkpointsTotal: 0, routeDone: 0, routeTotal: 0, stages: [], waitingPolice: false });
export const prepCountdown = writable({ visible: false, seconds: 0, maxSeconds: 1 });
export const raceTowerHud = writable({
  visible: false,
  title: 'GANG RALLY',
  currentCheckpoint: 1,
  totalCheckpoints: 1,
  currentLap: 1,
  totalLaps: 1,
  racers: [],
});
// Pre-race "reach the start line" timer for registered racers (client/modules/rally_race.lua).
export const raceGridHud = writable({ visible: false, ready: 0, total: 0, seconds: 0 });
export const hudCursorMode = writable(false);
export const hudHealthHidden = writable(false);
// Hot Cargo cargo-truck-only health bar (client/modules/runtime_client.lua's
// hot cargo truck-health thread) — visible only while the local player is
// actually in a hot_cargo_truck vehicle, and represents ONLY that vehicle's
// own health, never a towed trailer's (the trailer has no health at all).
export const hotCargoTruckHud = writable({ visible: false, pct: 100, disabled: false });

// Overhead health bars floating above nearby convoy / hot cargo trucks
// (TruckOverheadHealth.svelte). client/modules/runtime_client.lua projects each
// truck to a normalised 0..1 screen point and sends the whole batch only when
// something visibly changed: [{ id, x, y, label, pct, kind, broken, s }].
export const truckOverhead = writable([]);

// TDM match HUD — its own store rather than reusing deliveryHud, so its
// smoother local-tick clock (see startTdmMatch below) can't affect the
// already-live Convoy/Airdrop/Hot Cargo delivery timer behaviour.
export const tdmHud = writable({
  visible: false,
  teamA: { label: 'TEAM A', score: 0 },
  teamB: { label: 'TEAM B', score: 0 },
  seconds: 0,
  maxSeconds: 1,
  myKills: 0,
  myDeaths: 0,
  mvp: null, // { name, kills, deaths } | null — server-computed, shared by everyone
});
// Newest-first; each entry auto-removes itself after a few seconds (see
// tdmKillFeedEntry below) rather than the server having to track a TTL.
export const tdmKillFeed = writable([]);
// Personal-only feedback (headshot/double/triple/streak) — sent by the
// server ONLY to the attacker who earned it, never broadcast, so nobody
// else's screen reacts to a kill that wasn't theirs. Deliberately two
// separate pieces of state (a short "flash" banner, a longer-lived streak
// badge) exactly like the reference HUD kept them, just repositioned to a
// side of the screen instead of dead center — this must never sit over the
// crosshair mid-fight.
export const tdmFlash = writable({ visible: false, type: '', title: '', sub: '' });
export const tdmStreakBadge = writable({ visible: false, count: 0 });
// Bottom-centre "Kill Confirmed" emblem for the killer on EVERY TDM kill; `key` is bumped per kill to replay the pop-in.
export const tdmKillConfirm = writable({ visible: false, killer: '', victim: '', key: 0 });
// "Eliminated — respawning in N" overlay for the player who just went down.
// Virtual health bar (left side) — practice range + TDM both feed it.
// TAB scoreboard (hold) — payload comes straight from the server, see scoreboard.lua.
export const scoreboard = writable({ visible: false, data: null });
// Custom crosshair (client/modules/crosshair.lua): the saved design, whether it
// should be drawn right now, a counter bumped per shot (recoil pulse), and the
// designer panel's open flag.
export const DEFAULT_CROSSHAIR = {
  enabled: true, shape: 'cross', color: '#368fe9', size: 10, thickness: 2, gap: 5,
  opacity: 100, outline: true, centerDot: false, dotSize: 2, pulse: true,
};
export const crosshairCfg = writable({ ...DEFAULT_CROSSHAIR });
export const crosshairActive = writable(false);
export const crosshairPulse = writable(0);
export const crosshairPanelOpen = writable(false);
export const playerHealth = writable({ visible: false, hp: 100, max: 100 });
export const tdmRespawn = writable({ visible: false, seconds: 0, total: 0, killer: '' });
let tdmRespawnInterval = null;

// Practice Range's own small persistent readout (kills this session) — no
// team score, no timer, since practice is solo/unscored. Everything else
// (kill feed, flash, streak) is the exact same shared state as TDM above.
export const practiceHud = writable({ visible: false, kills: 0, location: '' });

const TDM_FLASH_META = {
  kill: { title: 'ELIMINATED', sub: '+100 POINTS' },
  head: { title: 'HEADSHOT', sub: 'PRECISION ELIMINATION' },
  double: { title: 'DOUBLE KILL', sub: '2 ELIMINATIONS' },
  triple: { title: 'TRIPLE KILL', sub: '3 ELIMINATIONS' },
  streak: { title: 'KILLING STREAK', sub: 'KEEP THE PRESSURE' },
};

let announcementTimer = null;
let notifySeq = 0;
const notifyTimers = {};

function normalizeNotifyType(t) {
  const v = String(t || 'info').toLowerCase();
  if (v === 'error' || v === 'danger') return 'danger';
  if (v === 'warn' || v === 'warning') return 'warn';
  if (v === 'success') return 'success';
  return 'info';
}

function removeNotification(id) {
  clearTimeout(notifyTimers[id]);
  delete notifyTimers[id];
  notifications.update((s) => ({ ...s, items: s.items.filter((n) => n.id !== id) }));
}

// data: { title?, message?, type?, duration?, category?, tag?, event?, position?, maxVisible? }
// The accent follows the event the text is about (convoy orange, airdrop violet ...); errors and warnings always keep the
// red / amber status colours. With no title the message becomes the headline.
function pushNotification(data) {
  const type = normalizeNotifyType(data.type);
  let title = data.title ? String(data.title) : '';
  let message = data.message ? String(data.message) : '';
  if (!title) { title = message; message = ''; }
  if (!title) return;
  const eventKey = data.event && THEMES[data.event] ? data.event
    : type === 'danger' ? 'danger'
    : type === 'warn' ? 'warn'
    : inferEventKey(type === 'info' ? undefined : type, title, message);
  const tags = { success: 'Confirmed', warn: 'Warning', danger: 'Alert', info: 'Notice' };
  const duration = Math.min(30000, Math.max(1500, Number(data.duration) || 5000));
  const id = ++notifySeq;
  const maxVisible = Math.min(8, Math.max(1, Number(data.maxVisible) || 4));
  notifications.update((s) => {
    // the same text arriving again while it is still on screen just restarts that card instead of stacking a copy
    const dupe = s.items.find((n) => n.title === title && n.message === message);
    let items = s.items;
    if (dupe) { removeNotificationTimerOnly(dupe.id); items = items.filter((n) => n.id !== dupe.id); }
    items = [...items, { id, title, message, type, eventKey, category: data.category || '', tag: data.tag || tags[type], duration }];
    while (items.length > maxVisible) { removeNotificationTimerOnly(items[0].id); items = items.slice(1); }
    return { items, position: data.position || s.position };
  });
  notifyTimers[id] = setTimeout(() => removeNotification(id), duration);
}

function removeNotificationTimerOnly(id) {
  clearTimeout(notifyTimers[id]);
  delete notifyTimers[id];
}
let toastTimer = null;
const rewardQueue = [];
let rewardShowing = false;

function showNextReward() {
  const next = rewardQueue.shift();
  if (!next) {
    rewardShowing = false;
    rewardCard.update((s) => ({ ...s, visible: false }));
    return;
  }
  rewardShowing = true;
  const dur = Math.max(6500, Math.min(11000, 5200 + (next.rewards || []).length * 1000));
  rewardCard.update((s) => ({ visible: true, card: next, key: s.key + 1, durationMs: dur }));
  setTimeout(() => {
    rewardCard.update((s) => ({ ...s, visible: false }));
    setTimeout(showNextReward, 350);
  }, dur);
}
let prepCountdownInterval = null;
// A timer update that was already on its way when the event ended (the server sends one more tick) must not bring the timer back:
// for a moment after a hide, updates are ignored (a new event's own 'start' message always goes through).
let lateTimerUpdatesBlockedUntil = 0;
const blockLateTimerUpdates = () => { lateTimerUpdatesBlockedUntil = Date.now() + 2500; };
let tdmMatchInterval = null;
let tdmFlashTimer = null;
let tdmStreakTimer = null;
let tdmKillConfirmTimer = null;

export function handleHudMessage(data) {
  switch (data.action) {
    case 'startCheckpointTimer':
      checkpointHud.set({ visible: true, index: data.index, total: data.total, seconds: data.time, maxSeconds: data.time, paused: false });
      break;
    case 'updateCheckpointTimer':
      checkpointHud.update((s) => ({ ...s, seconds: data.time }));
      break;
    case 'pauseCheckpointTimer':
      checkpointHud.update((s) => ({ ...s, paused: true }));
      break;
    case 'resumeCheckpointTimer':
      checkpointHud.update((s) => ({ ...s, paused: false }));
      break;
    case 'hideCheckpointTimer':
      blockLateTimerUpdates();
      checkpointHud.update((s) => ({ ...s, visible: false }));
      break;

    case 'startDeliveryTimer':
      deliveryHud.set({ visible: true, seconds: data.time, maxSeconds: data.time, kind: data.kind || 'DELIVERY' });
      break;
    case 'updateDeliveryTimer':
      if (Date.now() < lateTimerUpdatesBlockedUntil) break;
      deliveryHud.update((s) => {
        // The clock belongs to the event that started it. A tick from a different kind of event (a convoy still counting down while
        // an airdrop or Hot Cargo has taken the widget) is ignored, instead of overwriting it for a moment.
        const incoming = data.kind || 'DELIVERY';
        if (s.visible && s.kind && incoming !== s.kind) return s;
        return {
          ...s,
          visible: true,
          seconds: data.time,
          maxSeconds: (!s.maxSeconds || s.maxSeconds <= 1 || data.time > s.maxSeconds) ? data.time : s.maxSeconds,
          kind: incoming,
        };
      });
      break;
    case 'hideDeliveryTimer':
      blockLateTimerUpdates();
      deliveryHud.update((s) => ({ ...s, visible: false }));
      break;

    case 'announce':
      clearTimeout(announcementTimer);
      announcement.update((s) => ({
        visible: true,
        title: data.title,
        message: data.message,
        type: data.type || 'info',
        gang: data.gang || null,
        status: data.status || null,   // optional badge text from the server (e.g. "ROUND 2 / 4")
        durationMs: data.duration || 7000,
        bannerColor: data.bannerColor || null,
        imageUrl: data.imageUrl || null,
        // null (not 'center' / 'cover') when the sender gave none: announcementModel then falls back to the position, fit and zoom
        // saved for this event in Event Banner Images, instead of a default that always overrode them
        imagePosition: data.imagePosition || null,
        imageFit: data.imageFit || null,
        posX: data.posX != null ? data.posX : null,
        posY: data.posY != null ? data.posY : null,
        zoom: data.zoom != null ? data.zoom : null,
        key: s.key + 1,
      }));
      announcementTimer = setTimeout(() => {
        announcement.update((s) => ({ ...s, visible: false }));
      }, data.duration || 7000);
      break;

    case 'gangSquadUpdate':
      gangSquad.set({ visible: true, roster: data.roster, gang: data.gang || null });
      break;
    case 'gangSquadHide':
      gangSquad.set({ visible: false, roster: [], gang: null });
      break;

    case 'policeSquadUpdate':
      policeSquad.set({ visible: true, roster: data.roster });
      break;
    case 'policeSquadHide':
      policeSquad.set({ visible: false, roster: [] });
      break;

    case 'convoyProgress':
      convoyProgress.set({
        visible: true,
        delivered: Number(data.delivered) || 0,
        totalTrucks: Number(data.totalTrucks) || 0,
        checkpointsDone: Number(data.checkpointsDone) || 0,
        checkpointsTotal: Number(data.checkpointsTotal) || 0,
        routeDone: Number(data.routeDone) || 0,
        routeTotal: Number(data.routeTotal) || 0,
        stages: Array.isArray(data.stages) ? data.stages : [],
        waitingPolice: !!data.waitingPolice,
      });
      break;
    case 'convoyProgressHide':
      convoyProgress.update((s) => ({ ...s, visible: false }));
      break;

    case 'startPrepCountdown':
      clearInterval(prepCountdownInterval);
      prepCountdown.set({ visible: true, seconds: data.time, maxSeconds: data.time });
      prepCountdownInterval = setInterval(() => {
        prepCountdown.update((s) => {
          const next = s.seconds - 1;
          if (next <= 0) {
            clearInterval(prepCountdownInterval);
            return { ...s, visible: false, seconds: 0 };
          }
          return { ...s, seconds: next };
        });
      }, 1000);
      break;
    case 'hidePrepCountdown':
      clearInterval(prepCountdownInterval);
      prepCountdown.update((s) => ({ ...s, visible: false }));
      break;

    case 'notify':
      pushNotification(data);
      break;

    case 'showToast':
      pushNotification({ title: data.title, message: data.message, type: data.type === 'warn' ? 'warn' : 'success', duration: data.duration });
      break;

    case 'raceTowerUpdate':
    case 'raceUpdate':
    case 'updateRace':
      raceTowerHud.set({
        visible: true,
        title: data.title || 'Gang Rally',
        trackName: data.trackName || data.circuitName || 'STREET CIRCUIT',
        currentCheckpoint: data.currentCheckpoint || data.checkpoint || 1,
        totalCheckpoints: data.totalCheckpoints || data.totalStages || 1,
        currentLap: data.currentLap || data.lap || 1,
        totalLaps: data.totalLaps || 1,
        racers: data.racers || data.participants || data.drivers || [],
        myIdentifier: data.myIdentifier || data.localPlayerId || null,
        localPlayerId: data.localPlayerId || data.myIdentifier || null,
        elapsedSeconds: data.elapsedSeconds ?? data.time ?? null,
        status: data.status || 'FLAG GREEN · ALL SECTORS CLEAR',
        maxRows: data.maxRows || 10,
      });
      break;

    case 'raceGridStatus':
      raceGridHud.set({
        visible: true,
        label: data.label || 'Reach the start zone',
        sub: data.sub || (data.total != null ? `${data.ready || 0}/${data.total || 0} in position` : ''),
        seconds: data.seconds || 0,
      });
      break;

    case 'raceGridHide':
      raceGridHud.update((s) => ({ ...s, visible: false }));
      break;

    case 'raceTowerHide':
    case 'hideRaceTower':
    case 'endRace':
      raceTowerHud.update((s) => ({ ...s, visible: false }));
      break;

    case 'hud:toggleCursor':
      hudCursorMode.update((v) => !v);
      break;
    case 'hud:setCursor':
      hudCursorMode.set(!!data.enabled);
      break;
    case 'hud:hideHealth':
      hudHealthHidden.set(true);
      break;
    case 'hud:showHealth':
      hudHealthHidden.set(false);
      break;
    case 'hud:toggleHealth':
      hudHealthHidden.update((v) => !v);
      break;

    case 'truckOverheadHealth':
      truckOverhead.set(Array.isArray(data.trucks) ? data.trucks : []);
      break;

    case 'rewardAnnouncement':
      if (data.card && (data.card.rewards || []).length > 0) {
        rewardQueue.push(data.card);
        if (!rewardShowing) showNextReward();
      }
      break;

    case 'hotCargoTruckHealth':
      hotCargoTruckHud.set({ visible: !!data.visible, pct: data.pct != null ? data.pct : 100, disabled: !!data.disabled });
      break;

    // TDM match clock — hybrid like prepCountdown (local 1s ticks between
    // server pushes) rather than deliveryHud's push-only updates, so it
    // reads as a smooth running clock instead of jumping on each server tick.
    case 'startTdmMatch':
      clearInterval(tdmMatchInterval);
      tdmHud.set({
        visible: true,
        teamA: data.teamA || { label: 'TEAM A', score: 0 },
        teamB: data.teamB || { label: 'TEAM B', score: 0 },
        seconds: data.time,
        maxSeconds: data.time,
        myKills: data.myKills || 0,
        myDeaths: data.myDeaths || 0,
        mvp: data.mvp || null,
      });
      tdmMatchInterval = setInterval(() => {
        tdmHud.update((s) => {
          if (!s.visible || s.seconds <= 0) return s;
          return { ...s, seconds: s.seconds - 1 };
        });
      }, 1000);
      break;
    case 'updateTdmMatch':
      tdmHud.update((s) => ({
        ...s,
        visible: true,
        seconds: data.time != null ? data.time : s.seconds,
        teamA: data.teamA || s.teamA,
        teamB: data.teamB || s.teamB,
        myKills: data.myKills != null ? data.myKills : s.myKills,
        myDeaths: data.myDeaths != null ? data.myDeaths : s.myDeaths,
        mvp: data.mvp !== undefined ? data.mvp : s.mvp,
      }));
      break;
    case 'tdmRespawnStart': {
      clearInterval(tdmRespawnInterval);
      const total = Math.max(1, Number(data.seconds) || 3);
      tdmRespawn.set({ visible: true, seconds: total, total, killer: data.killer || '' });
      tdmRespawnInterval = setInterval(() => {
        tdmRespawn.update((s) => {
          const left = s.seconds - 1;
          if (left <= 0) { clearInterval(tdmRespawnInterval); return { ...s, seconds: 0, visible: false }; }
          return { ...s, seconds: left };
        });
      }, 1000);
      break;
    }
    case 'crosshairConfig':
      crosshairCfg.set({ ...DEFAULT_CROSSHAIR, ...(data.cfg || {}) });
      break;
    case 'crosshairShow':
      crosshairActive.set(!!data.show);
      break;
    case 'crosshairShot':
      crosshairPulse.update((n) => n + 1);
      break;
    case 'crosshairPanel':
      if (data.cfg) crosshairCfg.set({ ...DEFAULT_CROSSHAIR, ...data.cfg });
      crosshairPanelOpen.set(!!data.open);
      break;
    case 'scoreboardShow':
      scoreboard.set({ visible: true, data: data.payload || null });
      break;
    case 'scoreboardHide':
      scoreboard.update((s) => ({ ...s, visible: false }));
      break;
    case 'playerHealth':
      playerHealth.set({ visible: true, hp: Number(data.hp) || 0, max: Number(data.max) || 100 });
      break;
    case 'playerHealthHide':
      playerHealth.update((s) => ({ ...s, visible: false }));
      break;
    case 'tdmRespawnHide':
      clearInterval(tdmRespawnInterval);
      tdmRespawn.update((s) => ({ ...s, visible: false }));
      break;
    case 'hideTdmMatch':
      clearInterval(tdmRespawnInterval);
      tdmRespawn.update((s) => ({ ...s, visible: false }));
      clearInterval(tdmMatchInterval);
      tdmHud.update((s) => ({ ...s, visible: false }));
      tdmKillFeed.set([]);
      tdmFlash.set({ visible: false, type: '', title: '', sub: '' });
      tdmStreakBadge.set({ visible: false, count: 0 });
      clearTimeout(tdmKillConfirmTimer);
      tdmKillConfirm.update((s) => ({ ...s, visible: false }));
      break;

    // Generic kill-feed card — used by BOTH TDM (real player-vs-player kills,
    // broadcast to every match participant) and the solo Practice Range
    // (player-vs-bot kills, entirely local to that one client). Neither Lua
    // side needs its own copy of this store/UI.
    case 'tdmKillFeedEntry': {
      const id = data.id || `${Date.now()}_${Math.random()}`;
      const entry = {
        id,
        killer: data.killer || 'PLAYER', killerTeam: data.killerTeam || '',
        victim: data.victim || 'ENEMY', victimTeam: data.victimTeam || '',
        weapon: data.weapon || '', tag: data.tag || '', type: data.type || '',
      };
      tdmKillFeed.update((list) => [entry, ...list].slice(0, 6));
      setTimeout(() => {
        tdmKillFeed.update((list) => list.filter((e) => e.id !== id));
      }, data.duration || 4000);
      break;
    }

    // Personal-only "you just did something notable" feedback — same
    // reuse across TDM and Practice Range as the kill feed above.
    case 'tdmEventFlash': {
      const meta = TDM_FLASH_META[data.flashType] || TDM_FLASH_META.streak;
      clearTimeout(tdmFlashTimer);
      // Practice Range passes the bot's name ("Bot 2") so the banner says who went down.
      const sub = data.victim ? `${meta.sub} · ${data.victim}` : meta.sub;
      tdmFlash.set({ visible: true, type: data.flashType, title: meta.title, sub });
      tdmFlashTimer = setTimeout(() => {
        tdmFlash.update((s) => ({ ...s, visible: false }));
      }, 1900);

      if (data.streak >= 4) {
        clearTimeout(tdmStreakTimer);
        tdmStreakBadge.set({ visible: true, count: data.streak });
        tdmStreakTimer = setTimeout(() => {
          tdmStreakBadge.update((s) => ({ ...s, visible: false }));
        }, 2800);
      }
      break;
    }

    // TDM only (the Practice Range never sends this) — sent to the killer on every kill.
    case 'tdmKillConfirm':
      clearTimeout(tdmKillConfirmTimer);
      tdmKillConfirm.update((s) => ({ visible: true, killer: data.killer || '', victim: data.victim || '', key: s.key + 1 }));
      tdmKillConfirmTimer = setTimeout(() => {
        tdmKillConfirm.update((s) => ({ ...s, visible: false }));
      }, 3000);
      break;

    case 'practiceHudUpdate':
      practiceHud.set({ visible: true, kills: data.kills || 0, location: data.location || '' });
      break;
    case 'practiceHudHide':
      practiceHud.set({ visible: false, kills: 0, location: '' });
      tdmFlash.set({ visible: false, type: '', title: '', sub: '' });
      tdmStreakBadge.set({ visible: false, count: 0 });
      break;
  }
}
