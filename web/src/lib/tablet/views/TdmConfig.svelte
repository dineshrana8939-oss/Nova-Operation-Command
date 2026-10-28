<script>
  import { onDestroy } from 'svelte';
  import {
    getPlayerPosition,
    teleportToPosition,
    startZoneRecording,
    drawContainerWarsPerimeter,
    previewContainerWarsZone,
    previewSpawnSpots,
  } from '../../api/route.js';
  import { zoneRecordingResult, currentView, bootstrap } from '../../stores.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import { revealLast } from '../ui/reveal.js';
  import RewardListEditor from '../ui/RewardListEditor.svelte';
  import SubTabs from '../ui/SubTabs.svelte';
  import PedRow from '../ui/PedRow.svelte';
  import FormSectionHead from '../ui/FormSectionHead.svelte';
  import GangSelector from '../ui/GangSelector.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import '../tablet-theme.css';

  export let tdm = {
    matchFormat: 'STANDARD',
    duration: 600,
    killLimit: 0,
    zone: {},
    weaponVendor: {},
    weaponVendorRed: {},
    weaponVendorBlue: {},
    spawnPoints: [],
    spawnPointsRed: [],
    spawnPointsBlue: [],
    weapons: [],
  };
  export let reward = [];
  export let settings = {};

  // How the reward is shared by kills (paid per player on the server: server/modules/tdm_rewards.lua). A new event starts from these defaults.
  const DEF_RS = { enabled: true, winnerMinPercent: 40, loserPercent: 25, loserMinPercent: 40 };
  $: rs = { ...DEF_RS, ...(tdm.rewardScaling || {}) };
  function setRs(key, value) {
    if (locked) return;
    const v = typeof value === 'boolean' ? value : Math.max(0, Math.min(100, Math.floor(Number(value) || 0)));
    tdm.rewardScaling = { ...rs, [key]: v };
    tdm = tdm;
  }
  // a worked example for the three kinds of player: the best killer, one with half their kills, one with none
  const share = (min, f) => Math.round(min + (100 - min) * f);
  $: example = [1, 0.5, 0].map((f) => ({
    win: share(rs.winnerMinPercent, f),
    lose: Math.round((rs.loserPercent * share(rs.loserMinPercent, f)) / 100),
  }));
  export let locked = false;
  export let availableGangs = [];

  // ── 3 Main Sub-Tabs ────────────────────────────────────────────────────────
  const MAIN_SUBTABS = [
    { id: 'rules', label: '1. Rules & Rewards', icon: 'shield' },
    { id: 'zone', label: '2. TDM Zone & Spawns', icon: 'map' },
    { id: 'peds', label: '3. Ped Positions & Weapon Shop', icon: 'users' },
  ];
  let activeSub = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_tdm_main_sub')) || 'rules';
  $: if (typeof localStorage !== 'undefined' && activeSub) {
    localStorage.setItem('nova_convoy_last_tdm_main_sub', activeSub);
  }

  // ── Default Weapons Catalog ────────────────────────────────────────────────
  const DEFAULT_WEAPON_CATALOG = [
    // Pistols
    { id: 'w_combatpistol', label: 'Combat Pistol', weapon: 'WEAPON_COMBATPISTOL', type: 'Pistol', ammo: 60, price: 400, enabled: true },
    { id: 'w_heavypistol', label: 'Heavy Pistol', weapon: 'WEAPON_HEAVYPISTOL', type: 'Pistol', ammo: 60, price: 500, enabled: true },
    { id: 'w_appistol', label: 'AP Pistol', weapon: 'WEAPON_APPISTOL', type: 'Pistol', ammo: 90, price: 750, enabled: false },
    // SMGs
    { id: 'w_microsmg', label: 'Micro SMG', weapon: 'WEAPON_MICROSMG', type: 'SMG', ammo: 120, price: 900, enabled: true },
    { id: 'w_smg', label: 'SMG', weapon: 'WEAPON_SMG', type: 'SMG', ammo: 120, price: 1200, enabled: true },
    { id: 'w_assaultsmg', label: 'Assault SMG', weapon: 'WEAPON_ASSAULTSMG', type: 'SMG', ammo: 120, price: 1400, enabled: false },
    // Rifles
    { id: 'w_carbinerifle', label: 'Carbine Rifle', weapon: 'WEAPON_CARBINERIFLE', type: 'Rifle', ammo: 120, price: 2200, enabled: true },
    { id: 'w_assaultrifle', label: 'Assault Rifle', weapon: 'WEAPON_ASSAULTRIFLE', type: 'Rifle', ammo: 120, price: 2400, enabled: true },
    { id: 'w_specialcarbine', label: 'Special Carbine', weapon: 'WEAPON_SPECIALCARBINE', type: 'Rifle', ammo: 120, price: 2500, enabled: false },
    // Shotguns
    { id: 'w_pumpshotgun', label: 'Pump Shotgun', weapon: 'WEAPON_PUMPSHOTGUN', type: 'Shotgun', ammo: 32, price: 1500, enabled: true },
    { id: 'w_sawnoffshotgun', label: 'Sawed-Off Shotgun', weapon: 'WEAPON_SAWNOFFSHOTGUN', type: 'Shotgun', ammo: 32, price: 1300, enabled: false },
    // Snipers
    { id: 'w_sniperrifle', label: 'Sniper Rifle', weapon: 'WEAPON_SNIPERRIFLE', type: 'Sniper', ammo: 20, price: 3500, enabled: false },
    { id: 'w_marksmanrifle', label: 'Marksman Rifle', weapon: 'WEAPON_MARKSMANRIFLE', type: 'Sniper', ammo: 30, price: 3200, enabled: false },
  ];

  // Initialize and migrate data
  $: {
    if (!Array.isArray(tdm.spawnPointsRed)) tdm.spawnPointsRed = [];
    if (!Array.isArray(tdm.spawnPointsBlue)) tdm.spawnPointsBlue = [];
    if (tdm.spawnPoints && tdm.spawnPoints.length > 0 && tdm.spawnPointsRed.length === 0 && tdm.spawnPointsBlue.length === 0) {
      const half = Math.ceil(tdm.spawnPoints.length / 2);
      tdm.spawnPointsRed = tdm.spawnPoints.slice(0, half).map((p) => ({ ...p }));
      tdm.spawnPointsBlue = tdm.spawnPoints.slice(half).map((p) => ({ ...p }));
    }
    if (!tdm.weaponVendorRed || tdm.weaponVendorRed.x == null) {
      if (tdm.weaponVendor && tdm.weaponVendor.x != null) {
        tdm.weaponVendorRed = { ...tdm.weaponVendor };
      } else {
        tdm.weaponVendorRed = {};
      }
    }
    if (!tdm.weaponVendorBlue) tdm.weaponVendorBlue = {};
    if (!Array.isArray(tdm.weapons) || tdm.weapons.length === 0) {
      tdm.weapons = JSON.parse(JSON.stringify(DEFAULT_WEAPON_CATALOG));
    }
    if (!tdm.stagingZone || typeof tdm.stagingZone !== 'object') {
      tdm.stagingZone = { enabled: false, requiredPerTeam: 10, points: [] };
    }
    if (tdm.stagingZone.requiredPerTeam == null) tdm.stagingZone.requiredPerTeam = 10;
    if (!Array.isArray(tdm.stagingZone.points)) tdm.stagingZone.points = [];

    if (!tdm.respawnZoneRed || typeof tdm.respawnZoneRed !== 'object') tdm.respawnZoneRed = { points: [] };
    if (!Array.isArray(tdm.respawnZoneRed.points)) tdm.respawnZoneRed.points = [];

    if (!tdm.respawnZoneBlue || typeof tdm.respawnZoneBlue !== 'object') tdm.respawnZoneBlue = { points: [] };
    if (!Array.isArray(tdm.respawnZoneBlue.points)) tdm.respawnZoneBlue.points = [];
  }

  // Synchronize unified spawnPoints for backward compatibility
  function syncCombinedSpawns() {
    tdm.spawnPoints = [...(tdm.spawnPointsRed || []), ...(tdm.spawnPointsBlue || [])];
  }

  // ── Team Assignment & Gang Selection Modal ────────────────────────────────
  let gangPickerTeam = null; // 'red' | 'blue' | null
  let gangSearch = '';

  $: filteredGangs = (availableGangs || []).filter((g) => {
    if (!gangSearch.trim()) return true;
    const term = gangSearch.toLowerCase();
    return (g.name || '').toLowerCase().includes(term) || (g.label || '').toLowerCase().includes(term);
  });

  function openGangPicker(team) {
    if (locked) return;
    gangPickerTeam = team;
    gangSearch = '';
  }

  function closeGangPicker() {
    gangPickerTeam = null;
    gangSearch = '';
  }

  function selectGang(gangName) {
    if (locked || !gangPickerTeam) return;
    if (gangPickerTeam === 'red') {
      tdm.teamRedGang = gangName;
    } else {
      tdm.teamBlueGang = gangName;
    }
    syncAllowedGangs();
    closeGangPicker();
  }

  $: {
    if ((!tdm.teamRedGang || !tdm.teamBlueGang) && settings?.allowedGangs?.mode === 'SELECTED' && Array.isArray(settings?.allowedGangs?.gangs) && settings.allowedGangs.gangs.length >= 2) {
      if (!tdm.teamRedGang) tdm.teamRedGang = settings.allowedGangs.gangs[0];
      if (!tdm.teamBlueGang) tdm.teamBlueGang = settings.allowedGangs.gangs[1];
    }
  }

  function swapTeams() {
    const temp = tdm.teamRedGang;
    tdm.teamRedGang = tdm.teamBlueGang;
    tdm.teamBlueGang = temp;
    syncAllowedGangs();
  }

  function onTeamGangChange() {
    syncAllowedGangs();
  }

  function syncAllowedGangs() {
    if (!settings) settings = {};
    const selected = [];
    if (tdm.teamRedGang) selected.push(tdm.teamRedGang);
    if (tdm.teamBlueGang && tdm.teamBlueGang !== tdm.teamRedGang) selected.push(tdm.teamBlueGang);
    if (selected.length > 0) {
      settings.allowedGangs = {
        mode: 'SELECTED',
        gangs: selected,
      };
    }
  }

  const MAX_ZONE_POINTS = 24;
  const MIN_ZONE_POINTS = 3;
  const MAX_SPAWN_POINTS_PER_TEAM = 16;

  // ── PolyZone Geometry Helpers ─────────────────────────────────────────────
  function computePolyStats(points) {
    if (!points || points.length < MIN_ZONE_POINTS) return null;
    let a = 0;
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const q = points[(i + 1) % points.length];
      a += p.x * q.y - q.x * p.y;
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    return {
      area: Math.round(Math.abs(a) / 2),
      w: Math.round(maxX - minX),
      h: Math.round(maxY - minY),
    };
  }

  // ── Combat Zone (Container Wars Polygon Setup) ────────────────────────────
  let isRecordingZone = false;
  let busyZone = false;

  $: zonePoints = tdm.zone?.points || [];
  $: zoneReady = zonePoints.length >= MIN_ZONE_POINTS;
  $: zoneStats = computePolyStats(zonePoints);

  $: zoneCentroid = (() => {
    if (zonePoints.length === 0) return null;
    const sum = zonePoints.reduce((a, p) => ({ x: a.x + p.x, y: a.y + p.y, z: a.z + p.z }), { x: 0, y: 0, z: 0 });
    return { x: sum.x / zonePoints.length, y: sum.y / zonePoints.length, z: sum.z / zonePoints.length };
  })();

  async function recordZone() {
    if (locked || isRecordingZone) return;
    isRecordingZone = true;
    try {
      await drawContainerWarsPerimeter({ target: 'TDM_ZONE' });
    } finally {
      isRecordingZone = false;
    }
  }

  function removeZonePoint(index) {
    if (locked) return;
    const points = [...(tdm.zone?.points || [])];
    points.splice(index, 1);
    tdm.zone = points.length > 0 ? { points } : {};
  }

  function clearZone() {
    if (locked) return;
    tdm.zone = {};
  }

  async function previewZone(teleport = false) {
    if (zonePoints.length < 3 || busyZone) return;
    busyZone = true;
    try {
      if (teleport) {
        const p = zonePoints[0];
        await teleportToPosition(p.x, p.y, p.z || 6.0);
      }
      await previewContainerWarsZone(zonePoints, zonePoints[0]?.z || 6.0);
    } finally {
      busyZone = false;
    }
  }

  // ── Pre-Match Staging / Ready-Up Zone ──────────────────────────────────────
  $: stagingZonePoints = tdm.stagingZone?.points || [];
  $: stagingZoneReady = stagingZonePoints.length >= MIN_ZONE_POINTS;
  $: stagingZoneStats = computePolyStats(stagingZonePoints);

  async function recordStagingZone() {
    if (locked || isRecordingZone) return;
    isRecordingZone = true;
    try {
      await drawContainerWarsPerimeter({ target: 'TDM_STAGING_ZONE' });
    } finally {
      isRecordingZone = false;
    }
  }

  function removeStagingZonePoint(index) {
    if (locked) return;
    const points = [...(tdm.stagingZone?.points || [])];
    points.splice(index, 1);
    tdm.stagingZone = { ...(tdm.stagingZone || {}), points };
  }

  function clearStagingZone() {
    if (locked) return;
    tdm.stagingZone = { ...(tdm.stagingZone || {}), points: [] };
  }

  async function previewStagingZone(teleport = false) {
    if (stagingZonePoints.length < 3 || busyZone) return;
    busyZone = true;
    try {
      if (teleport) {
        const p = stagingZonePoints[0];
        await teleportToPosition(p.x, p.y, p.z || 6.0);
      }
      await previewContainerWarsZone(stagingZonePoints, stagingZonePoints[0]?.z || 6.0);
    } finally {
      busyZone = false;
    }
  }

  // ── PolyZone Team Respawns (Red Base vs Blue Base) ────────────────────────
  $: respawnZoneRedPoints = tdm.respawnZoneRed?.points || [];
  $: respawnZoneRedReady = respawnZoneRedPoints.length >= MIN_ZONE_POINTS;
  $: respawnZoneRedStats = computePolyStats(respawnZoneRedPoints);

  $: respawnZoneBluePoints = tdm.respawnZoneBlue?.points || [];
  $: respawnZoneBlueReady = respawnZoneBluePoints.length >= MIN_ZONE_POINTS;
  $: respawnZoneBlueStats = computePolyStats(respawnZoneBluePoints);

  async function recordRespawnZone(team) {
    if (locked || isRecordingZone) return;
    isRecordingZone = true;
    const target = team === 'red' ? 'TDM_RESPAWN_ZONE_RED' : 'TDM_RESPAWN_ZONE_BLUE';
    try {
      await drawContainerWarsPerimeter({ target });
    } finally {
      isRecordingZone = false;
    }
  }

  function removeRespawnZonePoint(team, index) {
    if (locked) return;
    if (team === 'red') {
      const points = [...(tdm.respawnZoneRed?.points || [])];
      points.splice(index, 1);
      tdm.respawnZoneRed = { points };
    } else {
      const points = [...(tdm.respawnZoneBlue?.points || [])];
      points.splice(index, 1);
      tdm.respawnZoneBlue = { points };
    }
  }

  function clearRespawnZone(team) {
    if (locked) return;
    if (team === 'red') {
      tdm.respawnZoneRed = { points: [] };
    } else {
      tdm.respawnZoneBlue = { points: [] };
    }
  }

  async function previewRespawnZone(team, teleport = false) {
    const points = team === 'red' ? respawnZoneRedPoints : respawnZoneBluePoints;
    if (points.length < 3 || busyZone) return;
    busyZone = true;
    try {
      if (teleport) {
        const p = points[0];
        await teleportToPosition(p.x, p.y, p.z || 6.0);
      }
      // the gold dots are the spots where a team of that size spawns inside this perimeter (the server uses the same ones)
      await previewContainerWarsZone(points, points[0]?.z || 6.0, Math.max(2, Number(tdm.stagingZone?.requiredPerTeam) || 10));
    } finally {
      busyZone = false;
    }
  }

  // the recorded spawn dots of a team, numbered in the world
  async function previewSpawns(team) {
    const list = team === 'red' ? tdm.spawnPointsRed : tdm.spawnPointsBlue;
    if (!list || list.length === 0 || busyZone) return;
    busyZone = true;
    try { await previewSpawnSpots(list.map((p) => ({ x: p.x, y: p.y, z: p.z }))); } finally { busyZone = false; }
  }

  // ── Segregated Spawn Points (Red Team vs Blue Team) ────────────────────────
  let spawnRecordingTeam = null; // 'red' | 'blue' | null

  async function recordSpawnPoints(team) {
    if (locked || spawnRecordingTeam) return;
    spawnRecordingTeam = team;
    const primaryLabel = team === 'red' ? 'Red Spawn (Team A)' : 'Blue Spawn (Team B)';
    const target = team === 'red' ? 'TDM_SPAWNS_RED' : 'TDM_SPAWNS_BLUE';
    await startZoneRecording({ primaryLabel, target });
  }

  function removeSpawnPoint(team, id) {
    if (locked) return;
    if (team === 'red') {
      tdm.spawnPointsRed = (tdm.spawnPointsRed || []).filter((p) => p.id !== id);
    } else {
      tdm.spawnPointsBlue = (tdm.spawnPointsBlue || []).filter((p) => p.id !== id);
    }
    syncCombinedSpawns();
  }

  function clearSpawnPoints(team) {
    if (locked) return;
    if (team === 'red') {
      tdm.spawnPointsRed = [];
    } else {
      tdm.spawnPointsBlue = [];
    }
    syncCombinedSpawns();
  }

  // Recording subscription listener
  const unsubZoneRecording = zoneRecordingResult.subscribe((msg) => {
    if (!msg) return;
    if (msg.target === 'TDM_ZONE') {
      const points = (msg.points || []).slice(0, MAX_ZONE_POINTS).map((p) => ({ x: p.x, y: p.y, z: p.z }));
      tdm.zone = points.length > 0 ? { points } : {};
      isRecordingZone = false;
      revealLast('.tdm-zone-pt');
      zoneRecordingResult.set(null);
    } else if (msg.target === 'TDM_STAGING_ZONE') {
      const points = (msg.points || []).slice(0, MAX_ZONE_POINTS).map((p) => ({ x: p.x, y: p.y, z: p.z }));
      tdm.stagingZone = { ...(tdm.stagingZone || {}), points };
      isRecordingZone = false;
      revealLast('.tdm-staging-pt');
      zoneRecordingResult.set(null);
    } else if (msg.target === 'TDM_RESPAWN_ZONE_RED') {
      const points = (msg.points || []).slice(0, MAX_ZONE_POINTS).map((p) => ({ x: p.x, y: p.y, z: p.z }));
      tdm.respawnZoneRed = { points };
      isRecordingZone = false;
      zoneRecordingResult.set(null);
    } else if (msg.target === 'TDM_RESPAWN_ZONE_BLUE') {
      const points = (msg.points || []).slice(0, MAX_ZONE_POINTS).map((p) => ({ x: p.x, y: p.y, z: p.z }));
      tdm.respawnZoneBlue = { points };
      isRecordingZone = false;
      zoneRecordingResult.set(null);
    } else if (msg.target === 'TDM_SPAWNS_RED') {
      const points = msg.points || [];
      if (points.length > 0) {
        const existing = tdm.spawnPointsRed || [];
        const remaining = Math.max(0, MAX_SPAWN_POINTS_PER_TEAM - existing.length);
        const added = points.slice(0, remaining).map((p, i) => ({
          id: `spawn_red_${Date.now()}_${i}`, x: p.x, y: p.y, z: p.z, heading: p.heading || 0,
        }));
        tdm.spawnPointsRed = [...existing, ...added];
        syncCombinedSpawns();
        revealLast('.tdm-spawn-red');
      }
      spawnRecordingTeam = null;
      zoneRecordingResult.set(null);
    } else if (msg.target === 'TDM_SPAWNS_BLUE') {
      const points = msg.points || [];
      if (points.length > 0) {
        const existing = tdm.spawnPointsBlue || [];
        const remaining = Math.max(0, MAX_SPAWN_POINTS_PER_TEAM - existing.length);
        const added = points.slice(0, remaining).map((p, i) => ({
          id: `spawn_blue_${Date.now()}_${i}`, x: p.x, y: p.y, z: p.z, heading: p.heading || 0,
        }));
        tdm.spawnPointsBlue = [...existing, ...added];
        syncCombinedSpawns();
        revealLast('.tdm-spawn-blue');
      }
      spawnRecordingTeam = null;
      zoneRecordingResult.set(null);
    } else if (msg.target === 'TDM_SPAWNS') {
      // Legacy fallback
      const points = msg.points || [];
      if (points.length > 0) {
        const added = points.map((p, i) => ({
          id: `spawn_${Date.now()}_${i}`, x: p.x, y: p.y, z: p.z, heading: p.heading || 0,
        }));
        tdm.spawnPoints = [...(tdm.spawnPoints || []), ...added];
        revealLast('.tdm-spawn-pt');
      }
      spawnRecordingTeam = null;
      zoneRecordingResult.set(null);
    }
  });
  onDestroy(() => unsubZoneRecording());

  // ── Opposing Weapon Vendors (Red Base vs Blue Base) ────────────────────────
  async function setVendorHere(team, e) {
    const pos = e?.detail?.x != null ? e.detail : await getPlayerPosition();
    if (!pos || pos.x == null) return;
    // "Use my position" carries the player's own heading — turn it round so the vendor faces the player, not away from them
    // (a hologram placement already carries the heading it was confirmed with).
    const heading = e?.detail?.x != null ? Number(pos.heading || 0) : (Number(pos.heading || 0) + 180) % 360;
    const vendorData = { x: pos.x, y: pos.y, z: pos.z, heading, enabled: true };
    if (team === 'red') {
      tdm.weaponVendorRed = vendorData;
      tdm.weaponVendor = { ...vendorData }; // Keep legacy updated
    } else {
      tdm.weaponVendorBlue = vendorData;
    }
  }

  function toggleVendorEnabled(team) {
    if (team === 'red') {
      if (!tdm.weaponVendorRed || tdm.weaponVendorRed.x == null) return;
      tdm.weaponVendorRed = { ...tdm.weaponVendorRed, enabled: tdm.weaponVendorRed.enabled === false };
      tdm.weaponVendor = { ...tdm.weaponVendorRed };
    } else {
      if (!tdm.weaponVendorBlue || tdm.weaponVendorBlue.x == null) return;
      tdm.weaponVendorBlue = { ...tdm.weaponVendorBlue, enabled: tdm.weaponVendorBlue.enabled === false };
    }
  }

  function clearVendor(team) {
    if (team === 'red') {
      tdm.weaponVendorRed = {};
      tdm.weaponVendor = {};
    } else {
      tdm.weaponVendorBlue = {};
    }
  }

  // ── Weapons Catalog & Shop Controls ────────────────────────────────────────
  let weaponFilter = 'ALL'; // 'ALL' | 'Pistol' | 'SMG' | 'Rifle' | 'Shotgun' | 'Sniper'
  let newWeapon = { type: 'Rifle', label: '', weapon: '', ammo: 120, price: 2000 };
  let showAddWeapon = false;

  $: filteredWeapons = (tdm.weapons || []).filter((w) => {
    if (weaponFilter === 'ALL') return true;
    return (w.type || '').toLowerCase() === weaponFilter.toLowerCase();
  });

  function applyPreset(preset) {
    if (locked) return;
    if (preset === 'ALL') {
      tdm.weapons = (tdm.weapons || []).map((w) => ({ ...w, enabled: true }));
    } else if (preset === 'PISTOLS') {
      tdm.weapons = (tdm.weapons || []).map((w) => ({ ...w, enabled: (w.type || '').toLowerCase() === 'pistol' }));
    } else if (preset === 'PISTOLS_RIFLES') {
      tdm.weapons = (tdm.weapons || []).map((w) => {
        const t = (w.type || '').toLowerCase();
        return { ...w, enabled: t === 'pistol' || t === 'rifle' };
      });
    } else if (preset === 'RESET') {
      tdm.weapons = JSON.parse(JSON.stringify(DEFAULT_WEAPON_CATALOG));
    }
  }

  function addCustomWeapon() {
    if (!newWeapon.label.trim() || !newWeapon.weapon.trim() || locked) return;
    const item = {
      id: `w_custom_${Date.now()}`,
      label: newWeapon.label.trim(),
      weapon: newWeapon.weapon.trim().toUpperCase(),
      type: newWeapon.type,
      ammo: Math.max(1, Math.min(999, Number(newWeapon.ammo) || 60)),
      price: Math.max(0, Number(newWeapon.price) || 0),
      enabled: true,
      custom: true,
    };
    tdm.weapons = [...(tdm.weapons || []), item];
    newWeapon = { type: 'Rifle', label: '', weapon: '', ammo: 120, price: 2000 };
    showAddWeapon = false;
  }

  function removeCustomWeapon(id) {
    if (locked) return;
    tdm.weapons = (tdm.weapons || []).filter((w) => w.id !== id);
  }

  // ── Rules & Participants ───────────────────────────────────────────────────
  $: minutes = Math.floor((tdm.duration || 0) / 60);
  $: seconds = (tdm.duration || 0) % 60;
  function setDurationMinutes(v) {
    const m = Math.max(1, Math.min(60, Number(v) || 0));
    tdm.duration = m * 60 + seconds;
  }

  function ensureAllowedGangs() {
    if (!settings.allowedGangs || typeof settings.allowedGangs !== 'object') {
      settings.allowedGangs = { mode: 'SELECTED', gangs: [] };
    }
    if (settings.allowedGangs.mode !== 'SELECTED') settings.allowedGangs.mode = 'SELECTED';
    if (!Array.isArray(settings.allowedGangs.gangs)) settings.allowedGangs.gangs = [];
  }
  $: if (settings) ensureAllowedGangs();

  $: isTournament = tdm.matchFormat === 'TOURNAMENT';

  async function chooseTournament() {
    if (tdm.matchFormat === 'TOURNAMENT') return;
    const ok = await confirmAction(
      'This event becomes a tournament ARENA template that supplies the combat zone, team spawn points, opposing vendors, match duration and weapons catalog. It cannot be started on its own.\n\nNext: set up the zone and vendors here, then save. You will be taken to the Tournaments tab to configure participating gangs, draw groups, and run the bracket tree.',
      { title: 'Switch to Tournament TDM?', confirmLabel: 'Yes, make it an arena' }
    );
    if (ok) tdm.matchFormat = 'TOURNAMENT';
  }
</script>

<div class="tdm-config">
  <!-- Top Main Sub-Tabs -->
  <SubTabs tabs={MAIN_SUBTABS} bind:active={activeSub} />

  <!-- ═════════ SUB-TAB 1: RULES & REWARDS ═════════ -->
  {#if activeSub === 'rules'}
    <div class="subtab-pane">
      <FormSectionHead title="Match Format & Timing" />
      <div class="field">
        <label>Match Format</label>
        <div class="chip-row">
          <button type="button" class="chip-btn" class:active={tdm.matchFormat !== 'TOURNAMENT'} disabled={locked} on:click={() => (tdm.matchFormat = 'STANDARD')}>Standard TDM</button>
          <button type="button" class="chip-btn" class:active={tdm.matchFormat === 'TOURNAMENT'} disabled={locked} on:click={chooseTournament}>Tournament TDM</button>
        </div>
        <span class="optional">{isTournament ? 'Arena Template: Supplies perimeter zone, spawns, and weapons catalog for multi-stage tournaments.' : 'Standard Match: Exactly 2 rival gangs face off in a head-to-head match.'}</span>
        {#if isTournament}
          <ol class="t-guide">
            <li class="on"><b>1</b><span>Build Arena Here <em>zone, red/blue spawns, vendors</em></span></li>
            <li><b>2</b><span>Save Event <em>creates reusable tournament template</em></span></li>
            <li><b>3</b><span>Create Tournament <em>Tournaments tab: gangs, groups, schedule</em></span></li>
            <li><b>4</b><span>Live Bracket <em>auto-draw and live knockout matches</em></span></li>
          </ol>
          <button type="button" class="btn btn-steel btn-mini-guide" on:click={() => currentView.set('tournaments')}>
            <Icon name="trophy" size={13} /> Open Tournaments Tab
          </button>
        {/if}
      </div>

      <div class="field-row">
        <div class="field">
          <label>Match Duration <span class="optional">minutes</span></label>
          <input type="number" min="1" max="60" value={minutes} disabled={locked} on:input={(e) => setDurationMinutes(e.target.value)} />
        </div>
        <div class="field">
          <label>Kill Limit <span class="optional">0 = no kill limit (timer only)</span></label>
          <input type="number" min="0" max="500" bind:value={tdm.killLimit} disabled={locked} />
        </div>
      </div>

      <FormSectionHead title="Match Reward" />
      <div class="field">
        <label>Rewards <span class="optional">{isTournament ? "the reward of the tournament: champion gang first, the other gangs a lower share (Reward by Kills below)" : "the reward of the match: shared by kills (Reward by Kills below); the losing team gets a lower share"}</span></label>
        <RewardListEditor bind:rewards={reward} disabled={locked} />
      </div>

      <FormSectionHead title="Reward by Kills" hint={isTournament ? 'applies to the tournament: kills are counted over all its matches' : 'who earns how much of the reward'} />
      <div class="rs-box">
        <label class="rs-toggle">
          <Toggle label={rs.enabled ? 'On' : 'Off'} checked={rs.enabled} disabled={locked} on:change={() => setRs('enabled', !rs.enabled)} />
          <span><b>Share the reward by kills</b> — the best killer of a team earns the most, a player with fewer kills earns less. Off: every winner gets the whole reward and the losers nothing.</span>
        </label>
        {#if rs.enabled}
          <div class="rs-grid">
            <div class="field">
              <label>Winning team: lowest share <span class="optional">% of the best killer's reward</span></label>
              <input type="number" min="0" max="100" value={rs.winnerMinPercent} on:change={(e) => setRs('winnerMinPercent', e.target.value)} disabled={locked} />
            </div>
            <div class="field">
              <label>Losing team gets <span class="optional">% of the reward · 0 = nothing</span></label>
              <input type="number" min="0" max="100" value={rs.loserPercent} on:change={(e) => setRs('loserPercent', e.target.value)} disabled={locked} />
            </div>
            <div class="field">
              <label>Losing team: lowest share <span class="optional">% of the losing team's best killer</span></label>
              <input type="number" min="0" max="100" value={rs.loserMinPercent} on:change={(e) => setRs('loserMinPercent', e.target.value)} disabled={locked} />
            </div>
          </div>
          <table class="rs-example">
            <thead><tr><th>Player</th><th>Winning team gets</th><th>Losing team gets</th></tr></thead>
            <tbody>
              <tr><td>Best killer</td><td>{example[0].win}%</td><td>{example[0].lose}%</td></tr>
              <tr><td>Half their kills</td><td>{example[1].win}%</td><td>{example[1].lose}%</td></tr>
              <tr><td>No kills</td><td>{example[2].win}%</td><td>{example[2].lose}%</td></tr>
            </tbody>
          </table>
          <p class="rs-note">Money, items and Gang XP are shared this way (rounded; a winner always gets at least 1). A vehicle goes to the best killer of the winning team only. Every online member of both teams is paid.</p>
        {/if}
      </div>

      <FormSectionHead title="Participating Gangs" hint={isTournament ? 'managed in Tournaments tab' : 'invite-only (exactly 2 gangs)'} />
      {#if isTournament}
        <div class="tdm-tournament-note">
          <Icon name="flag" size={14} />
          <span>This event is an <b>Arena Template</b>. Gang rosters, group stages, and bracket trees are managed in the dedicated <b>Tournaments</b> tab.</span>
        </div>
      {:else}
        <div style="margin-top: 10px;">
          <GangSelector
            {availableGangs}
            title="Participating Gangs (2 Required)"
            hint="Select the 2 rival gangs that will duel in this match"
            showModeSwitch={false}
            requiredCount={2}
            {locked}
            bind:allowedGangs={settings.allowedGangs}
          />
        </div>
      {/if}
    </div>

  <!-- ═════════ SUB-TAB 2: TDM ZONE & SPAWNS ═════════ -->
  {:else if activeSub === 'zone'}
    <div class="subtab-pane">
      <!-- 1. Combat Zone (Exact Container Wars Perimeter Setup) -->
      <section class="card-box">
        <header class="card-head">
          <div class="step-badge"><Icon name="map" size={14} /></div>
          <div>
            <h3>Combat Zone Perimeter (Arena Boundary)</h3>
            <p>Walk the combat perimeter. Left-click to place boundary corners, Backspace to undo, Enter to save.</p>
          </div>
          <span class="state-pill" class:ok={zoneReady}>{zoneReady ? `${zonePoints.length} points` : 'Not set'}</span>
        </header>

        <div class="zone-row">
          <div class="zone-stats">
            {#if zoneStats}
              <div><b>{zoneStats.area.toLocaleString()}</b><span>m² arena area</span></div>
              <div><b>{zoneStats.w} × {zoneStats.h}</b><span>m bounding box</span></div>
              <div><b>{zonePoints.length}</b><span>perimeter vertices</span></div>
            {:else}
              <p class="hint" style="margin:0">Click <b>Draw Perimeter</b>, aim at ground corners, and left-click to drop boundary points.</p>
            {/if}
          </div>
          <div class="actions">
            <button type="button" class="btn btn-sm btn-preview" on:click={recordZone} disabled={locked || isRecordingZone}>
              <Icon name="flag" size={12} /><span>{isRecordingZone ? 'Drawing…' : (zoneReady ? 'Redraw Perimeter' : 'Draw Perimeter')}</span>
            </button>
            {#if zoneReady}
              <button type="button" class="btn btn-sm btn-refresh" on:click={() => previewZone(false)} disabled={busyZone}>
                <Icon name="eye" size={12} /><span>Preview Here</span>
              </button>
              <button type="button" class="btn btn-sm" on:click={() => previewZone(true)} disabled={busyZone}>
                <Icon name="teleport" size={12} /><span>Teleport &amp; Preview</span>
              </button>
              {#if zoneCentroid}
                <button type="button" class="btn btn-sm" on:click={() => teleportToPosition(zoneCentroid.x, zoneCentroid.y, zoneCentroid.z, 0)} disabled={locked}>
                  <Icon name="teleport" size={12} /><span>Center</span>
                </button>
              {/if}
              <button type="button" class="btn btn-sm btn-danger" on:click={clearZone} disabled={locked}>
                <Icon name="trash" size={12} /><span>Clear</span>
              </button>
            {/if}
          </div>
        </div>

        {#if zonePoints.length > 0}
          <div class="zone-points-list">
            {#each zonePoints as p, i}
              <div class="zone-point-pill tdm-zone-pt">
                <span class="pt-idx">#{i + 1}</span>
                <span class="pt-coord">{p.x.toFixed(1)}, {p.y.toFixed(1)}, {p.z.toFixed(1)}</span>
                <button type="button" class="btn-icon" title="Teleport" disabled={locked} on:click={() => teleportToPosition(p.x, p.y, p.z, 0)}>
                  <Icon name="teleport" size={11} />
                </button>
                <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeZonePoint(i)}>
                  <Icon name="close" size={11} />
                </button>
              </div>
            {/each}
          </div>
        {/if}
      </section>

      <!-- 2. Pre-Match Staging / Ready-Up Zone (PolyZone) -->
      <section class="card-box staging-card">
        <header class="card-head">
          <div class="step-badge staging-badge"><Icon name="users" size={14} /></div>
          <div>
            <h3>Pre-Match Staging &amp; Ready-Up Zone (PolyZone)</h3>
            <p>Players from both gangs step into this zone to ready-up. Once both teams reach the required count, a 10s countdown triggers and players are deployed in tactical non-overlapping formations.</p>
          </div>
          <div class="staging-head-right">
            <Toggle
              label="Enable Staging Zone"
              bind:checked={tdm.stagingZone.enabled}
              disabled={locked}
            />
            <span class="state-pill" class:ok={tdm.stagingZone?.enabled && stagingZoneReady}>
              {tdm.stagingZone?.enabled ? (stagingZoneReady ? `${stagingZonePoints.length} points` : 'Perimeter Needed') : 'Disabled'}
            </span>
          </div>
        </header>

        {#if tdm.stagingZone?.enabled}
          <div class="staging-settings-row">
            <div class="field staging-req-field">
              <label for="tdm-req-team">Required Players per Team <span class="optional">(e.g. 10 Red + 10 Blue = 20 total)</span></label>
              <div class="input-unit staging-input-unit">
                <input
                  id="tdm-req-team"
                  type="number"
                  min="1"
                  max="50"
                  bind:value={tdm.stagingZone.requiredPerTeam}
                  disabled={locked}
                />
                <span class="unit-tag">players / team</span>
              </div>
            </div>
            <div class="staging-rule-tip">
              <Icon name="info" size={13} />
              <span>Match cannot start until <b>{tdm.stagingZone.requiredPerTeam || 10}</b> players from Team Red AND <b>{tdm.stagingZone.requiredPerTeam || 10}</b> players from Team Blue have stepped into the zone.</span>
            </div>
          </div>

          <div class="zone-row">
            <div class="zone-stats">
              {#if stagingZoneStats}
                <div><b>{stagingZoneStats.area.toLocaleString()}</b><span>m² staging area</span></div>
                <div><b>{stagingZoneStats.w} × {stagingZoneStats.h}</b><span>m bounding box</span></div>
                <div><b>{stagingZonePoints.length}</b><span>perimeter vertices</span></div>
              {:else}
                <p class="hint" style="margin:0">Click <b>Draw Staging Perimeter</b>, aim at ground corners, and left-click to drop boundary points.</p>
              {/if}
            </div>
            <div class="actions">
              <button type="button" class="btn btn-sm btn-preview" on:click={recordStagingZone} disabled={locked || isRecordingZone}>
                <Icon name="flag" size={12} /><span>{isRecordingZone ? 'Drawing…' : (stagingZoneReady ? 'Redraw Perimeter' : 'Draw Staging Perimeter')}</span>
              </button>
              {#if stagingZoneReady}
                <button type="button" class="btn btn-sm btn-refresh" on:click={() => previewStagingZone(false)} disabled={busyZone}>
                  <Icon name="eye" size={12} /><span>Preview Here</span>
                </button>
                <button type="button" class="btn btn-sm" on:click={() => previewStagingZone(true)} disabled={busyZone}>
                  <Icon name="teleport" size={12} /><span>Teleport &amp; Preview</span>
                </button>
                <button type="button" class="btn btn-sm btn-danger" on:click={clearStagingZone} disabled={locked}>
                  <Icon name="trash" size={12} /><span>Clear</span>
                </button>
              {/if}
            </div>
          </div>

          {#if stagingZonePoints.length > 0}
            <div class="zone-points-list">
              {#each stagingZonePoints as p, i}
                <div class="zone-point-pill tdm-staging-pt">
                  <span class="pt-idx">#{i + 1}</span>
                  <span class="pt-coord">{p.x.toFixed(1)}, {p.y.toFixed(1)}, {p.z.toFixed(1)}</span>
                  <button type="button" class="btn-icon" title="Teleport" disabled={locked} on:click={() => teleportToPosition(p.x, p.y, p.z, 0)}>
                    <Icon name="teleport" size={11} />
                  </button>
                  <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeStagingZonePoint(i)}>
                    <Icon name="close" size={11} />
                  </button>
                </div>
              {/each}
            </div>
          {/if}
        {/if}
      </section>

      <!-- 3. Team Assignment: Red Team vs Blue Team -->
      <FormSectionHead title="Team Assignment & Base Allocation" hint="Assign rival gangs to Red Team (Base A) and Blue Team (Base B) using the interactive gang selector" />
      <div class="team-assign-cards">
        <!-- Team Red Card -->
        <div class="team-picker-card red-picker-card">
          <div class="tp-head">
            <span class="team-dot red"></span>
            <div>
              <span class="tp-sub">Team A Allocation</span>
              <h4 class="tp-title">Team Red</h4>
            </div>
          </div>
          <div class="tp-body">
            {#if tdm.teamRedGang}
              {@const gangObj = availableGangs.find((g) => g.name === tdm.teamRedGang)}
              <div class="tp-assigned-box red-box">
                <div class="tp-gang-avatar red-avatar">
                  <Icon name="shield" size={18} />
                </div>
                <div class="tp-gang-details">
                  <span class="tp-gang-name">{gangObj?.label || tdm.teamRedGang}</span>
                  <span class="tp-gang-code">{tdm.teamRedGang}</span>
                </div>
                <button type="button" class="btn btn-xs btn-outline-red" disabled={locked} on:click={() => openGangPicker('red')}>
                  Change
                </button>
              </div>
            {:else}
              <div class="tp-unassigned-box">
                <span>No gang assigned yet</span>
                <button type="button" class="btn btn-sm btn-red-action" disabled={locked} on:click={() => openGangPicker('red')}>
                  <Icon name="plus" size={12} /><span>Choose Red Gang</span>
                </button>
              </div>
            {/if}
          </div>
        </div>

        <!-- Swap Button -->
        <div class="tp-swap-col">
          <button type="button" class="btn btn-swap-teams-round" title="Swap Red and Blue Team assignments" on:click={swapTeams} disabled={locked}>
            <Icon name="swap" size={16} />
          </button>
          <span class="tp-swap-hint">Swap</span>
        </div>

        <!-- Team Blue Card -->
        <div class="team-picker-card blue-picker-card">
          <div class="tp-head">
            <span class="team-dot blue"></span>
            <div>
              <span class="tp-sub">Team B Allocation</span>
              <h4 class="tp-title">Team Blue</h4>
            </div>
          </div>
          <div class="tp-body">
            {#if tdm.teamBlueGang}
              {@const gangObj = availableGangs.find((g) => g.name === tdm.teamBlueGang)}
              <div class="tp-assigned-box blue-box">
                <div class="tp-gang-avatar blue-avatar">
                  <Icon name="shield" size={18} />
                </div>
                <div class="tp-gang-details">
                  <span class="tp-gang-name">{gangObj?.label || tdm.teamBlueGang}</span>
                  <span class="tp-gang-code">{tdm.teamBlueGang}</span>
                </div>
                <button type="button" class="btn btn-xs btn-outline-blue" disabled={locked} on:click={() => openGangPicker('blue')}>
                  Change
                </button>
              </div>
            {:else}
              <div class="tp-unassigned-box">
                <span>No gang assigned yet</span>
                <button type="button" class="btn btn-sm btn-blue-action" disabled={locked} on:click={() => openGangPicker('blue')}>
                  <Icon name="plus" size={12} /><span>Choose Blue Gang</span>
                </button>
              </div>
            {/if}
          </div>
        </div>
      </div>

      <!-- 4. Segregated Respawn Points: Red Base vs Blue Base -->
      <FormSectionHead title="Team Respawn Points & Base Perimeter" hint="Configure PolyZone base perimeters and tactical spawn points for both teams" />
      <div class="teams-grid">
        <!-- RED TEAM RESPAWNS -->
        <div class="team-card red-card">
          <div class="team-card-head">
            <div class="team-title-row">
              <span class="team-indicator red"></span>
              <h4>Red Team Base (Team A)</h4>
              {#if tdm.teamRedGang}
                <span class="assigned-gang-pill red">{availableGangs.find(g => g.name === tdm.teamRedGang)?.label || tdm.teamRedGang}</span>
              {/if}
            </div>
            <span class="count-badge red">{(tdm.spawnPointsRed || []).length} / {MAX_SPAWN_POINTS_PER_TEAM} pts</span>
          </div>
          <p class="team-desc">Where Red Team members spawn after staging and respawn during combat. With a base perimeter drawn the team spawns spread inside it, one spot each a few metres apart (Preview shows the spots); the dots below are used only when no perimeter is drawn.</p>

          <!-- PolyZone Base Perimeter for Red Team -->
          <div class="sub-perimeter-box">
            <div class="sub-perim-head">
              <span class="sub-perim-title"><Icon name="map" size={12} /> Red Base PolyZone Perimeter</span>
              <span class="state-pill" class:ok={respawnZoneRedReady}>{respawnZoneRedReady ? `${respawnZoneRedPoints.length} vertices` : 'Optional'}</span>
            </div>
            <div class="sub-perim-actions">
              <button type="button" class="btn btn-xs btn-preview" on:click={() => recordRespawnZone('red')} disabled={locked || isRecordingZone}>
                <Icon name="flag" size={11} /><span>{respawnZoneRedReady ? 'Redraw Red Base Zone' : 'Draw Red Base PolyZone'}</span>
              </button>
              {#if respawnZoneRedReady}
                <button type="button" class="btn btn-xs btn-refresh" on:click={() => previewRespawnZone('red', false)} disabled={busyZone}>
                  <Icon name="eye" size={11} /><span>Preview</span>
                </button>
                <button type="button" class="btn btn-xs" on:click={() => previewRespawnZone('red', true)} disabled={busyZone}>
                  <Icon name="teleport" size={11} /><span>Teleport</span>
                </button>
                <button type="button" class="btn btn-xs btn-danger" on:click={() => clearRespawnZone('red')} disabled={locked}>
                  <Icon name="trash" size={11} />
                </button>
              {/if}
            </div>
            {#if respawnZoneRedPoints.length > 0}
              <div class="zone-points-list compact-list">
                {#each respawnZoneRedPoints as p, i}
                  <div class="zone-point-pill tdm-zone-pt">
                    <span class="pt-idx">#{i + 1}</span>
                    <span class="pt-coord">{p.x.toFixed(1)}, {p.y.toFixed(1)}</span>
                    <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeRespawnZonePoint('red', i)}>
                      <Icon name="close" size={10} />
                    </button>
                  </div>
                {/each}
              </div>
            {/if}
          </div>

          <!-- Discrete Spawn Points for Red Team -->
          <div class="sub-discrete-title">Discrete Spawn Points (Fallback / Formation Anchors)</div>
          {#if (tdm.spawnPointsRed || []).length === 0}
            <div class="empty-spawns">No Red spawn points set. Add at least 1 point or use Base PolyZone.</div>
          {:else}
            <div class="spawns-wrap">
              {#each tdm.spawnPointsRed as p, i (p.id)}
                <div class="spawn-pill red-pill tdm-spawn-red">
                  <span class="sp-num">#{i + 1}</span>
                  <span class="sp-coord">{p.x.toFixed(1)}, {p.y.toFixed(1)}</span>
                  <button type="button" class="btn-icon" title="Teleport" disabled={locked} on:click={() => teleportToPosition(p.x, p.y, p.z, p.heading || 0)}>
                    <Icon name="teleport" size={11} />
                  </button>
                  <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeSpawnPoint('red', p.id)}>
                    <Icon name="close" size={11} />
                  </button>
                </div>
              {/each}
            </div>
          {/if}

          <div class="team-card-actions">
            <button type="button" class="btn btn-sm btn-red-action" disabled={locked || spawnRecordingTeam === 'red'} on:click={() => recordSpawnPoints('red')}>
              <Icon name="pin" size={12} />
              <span>{spawnRecordingTeam === 'red' ? 'Recording… [E] drops spawn, [Enter] finish' : 'Record Red Spawns'}</span>
            </button>
            {#if (tdm.spawnPointsRed || []).length > 0}
              <button type="button" class="btn btn-sm btn-refresh" disabled={busyZone} on:click={() => previewSpawns('red')}>
                <Icon name="eye" size={12} /><span>Preview Spawns</span>
              </button>
              <button type="button" class="btn btn-sm btn-outline-danger" disabled={locked} on:click={() => clearSpawnPoints('red')}>
                Clear Red Spawns
              </button>
            {/if}
          </div>
        </div>

        <!-- BLUE TEAM RESPAWNS -->
        <div class="team-card blue-card">
          <div class="team-card-head">
            <div class="team-title-row">
              <span class="team-indicator blue"></span>
              <h4>Blue Team Base (Team B)</h4>
              {#if tdm.teamBlueGang}
                <span class="assigned-gang-pill blue">{availableGangs.find(g => g.name === tdm.teamBlueGang)?.label || tdm.teamBlueGang}</span>
              {/if}
            </div>
            <span class="count-badge blue">{(tdm.spawnPointsBlue || []).length} / {MAX_SPAWN_POINTS_PER_TEAM} pts</span>
          </div>
          <p class="team-desc">Where Blue Team members spawn after staging and respawn during combat. With a base perimeter drawn the team spawns spread inside it, one spot each a few metres apart (Preview shows the spots); the dots below are used only when no perimeter is drawn.</p>

          <!-- PolyZone Base Perimeter for Blue Team -->
          <div class="sub-perimeter-box">
            <div class="sub-perim-head">
              <span class="sub-perim-title"><Icon name="map" size={12} /> Blue Base PolyZone Perimeter</span>
              <span class="state-pill" class:ok={respawnZoneBlueReady}>{respawnZoneBlueReady ? `${respawnZoneBluePoints.length} vertices` : 'Optional'}</span>
            </div>
            <div class="sub-perim-actions">
              <button type="button" class="btn btn-xs btn-preview" on:click={() => recordRespawnZone('blue')} disabled={locked || isRecordingZone}>
                <Icon name="flag" size={11} /><span>{respawnZoneBlueReady ? 'Redraw Blue Base Zone' : 'Draw Blue Base PolyZone'}</span>
              </button>
              {#if respawnZoneBlueReady}
                <button type="button" class="btn btn-xs btn-refresh" on:click={() => previewRespawnZone('blue', false)} disabled={busyZone}>
                  <Icon name="eye" size={11} /><span>Preview</span>
                </button>
                <button type="button" class="btn btn-xs" on:click={() => previewRespawnZone('blue', true)} disabled={busyZone}>
                  <Icon name="teleport" size={11} /><span>Teleport</span>
                </button>
                <button type="button" class="btn btn-xs btn-danger" on:click={() => clearRespawnZone('blue')} disabled={locked}>
                  <Icon name="trash" size={11} />
                </button>
              {/if}
            </div>
            {#if respawnZoneBluePoints.length > 0}
              <div class="zone-points-list compact-list">
                {#each respawnZoneBluePoints as p, i}
                  <div class="zone-point-pill tdm-zone-pt">
                    <span class="pt-idx">#{i + 1}</span>
                    <span class="pt-coord">{p.x.toFixed(1)}, {p.y.toFixed(1)}</span>
                    <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeRespawnZonePoint('blue', i)}>
                      <Icon name="close" size={10} />
                    </button>
                  </div>
                {/each}
              </div>
            {/if}
          </div>

          <!-- Discrete Spawn Points for Blue Team -->
          <div class="sub-discrete-title">Discrete Spawn Points (Fallback / Formation Anchors)</div>
          {#if (tdm.spawnPointsBlue || []).length === 0}
            <div class="empty-spawns">No Blue spawn points set. Add at least 1 point or use Base PolyZone.</div>
          {:else}
            <div class="spawns-wrap">
              {#each tdm.spawnPointsBlue as p, i (p.id)}
                <div class="spawn-pill blue-pill tdm-spawn-blue">
                  <span class="sp-num">#{i + 1}</span>
                  <span class="sp-coord">{p.x.toFixed(1)}, {p.y.toFixed(1)}</span>
                  <button type="button" class="btn-icon" title="Teleport" disabled={locked} on:click={() => teleportToPosition(p.x, p.y, p.z, p.heading || 0)}>
                    <Icon name="teleport" size={11} />
                  </button>
                  <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeSpawnPoint('blue', p.id)}>
                    <Icon name="close" size={11} />
                  </button>
                </div>
              {/each}
            </div>
          {/if}

          <div class="team-card-actions">
            <button type="button" class="btn btn-sm btn-blue-action" disabled={locked || spawnRecordingTeam === 'blue'} on:click={() => recordSpawnPoints('blue')}>
              <Icon name="pin" size={12} />
              <span>{spawnRecordingTeam === 'blue' ? 'Recording… [E] drops spawn, [Enter] finish' : 'Record Blue Spawns'}</span>
            </button>
            {#if (tdm.spawnPointsBlue || []).length > 0}
              <button type="button" class="btn btn-sm btn-refresh" disabled={busyZone} on:click={() => previewSpawns('blue')}>
                <Icon name="eye" size={12} /><span>Preview Spawns</span>
              </button>
              <button type="button" class="btn btn-sm btn-outline-danger" disabled={locked} on:click={() => clearSpawnPoints('blue')}>
                Clear Blue Spawns
              </button>
            {/if}
          </div>
        </div>
      </div>
    </div>

  <!-- ═════════ SUB-TAB 3: PED POSITIONS & WEAPON SHOP ═════════ -->
  {:else if activeSub === 'peds'}
    <div class="subtab-pane">
      <!-- 1. Opposing Weapon Vendors -->
      <FormSectionHead title="Opposing Team Weapon Vendors" hint="Standing on opposite sides at Red and Blue bases" />
      <div class="vendors-grid">
        <div class="vendor-box red-vendor">
          <div class="vendor-head">
            <span class="team-dot red"></span>
            <div>
              <h4>Red Base Weapon Ped (Team A)</h4>
              <small>Located at Red Team spawn base with Red Gun Shop blip</small>
            </div>
          </div>
          <PedRow
            title=""
            description="Interacting allows Team A players to buy weapons from the configured catalog."
            pos={tdm.weaponVendorRed}
            model={$bootstrap?.pedModels?.tdmVendor || 'g_m_y_mexgoon_01'}
            toggleable
            enabled={tdm.weaponVendorRed?.enabled !== false}
            {locked}
            on:set={(e) => setVendorHere('red', e)}
            on:toggle={() => toggleVendorEnabled('red')}
            on:clear={() => clearVendor('red')}
          />
        </div>

        <div class="vendor-box blue-vendor">
          <div class="vendor-head">
            <span class="team-dot blue"></span>
            <div>
              <h4>Blue Base Weapon Ped (Team B)</h4>
              <small>Located at Blue Team spawn base with Blue Gun Shop blip</small>
            </div>
          </div>
          <PedRow
            title=""
            description="Interacting allows Team B players to buy weapons from the configured catalog."
            pos={tdm.weaponVendorBlue}
            model={$bootstrap?.pedModels?.tdmVendor || 'g_m_y_mexgoon_01'}
            toggleable
            enabled={tdm.weaponVendorBlue?.enabled !== false}
            {locked}
            on:set={(e) => setVendorHere('blue', e)}
            on:toggle={() => toggleVendorEnabled('blue')}
            on:clear={() => clearVendor('blue')}
          />
        </div>
      </div>

      <!-- 2. Weapon & Ammo Catalog -->
      <FormSectionHead title="Ped Weapon & Ammo Catalog" hint="Configure which guns and ammo quantities the vendor peds sell to both teams" />
      <div class="catalog-card">
        <!-- Catalog Header Toolbar -->
        <div class="catalog-toolbar">
          <div class="category-chips">
            {#each ['ALL', 'Pistol', 'SMG', 'Rifle', 'Shotgun', 'Sniper'] as cat}
              <button
                type="button"
                class="cat-chip"
                class:active={weaponFilter === cat}
                on:click={() => (weaponFilter = cat)}
              >
                <span>{cat === 'ALL' ? 'All Weapons' : `${cat}s`}</span>
                <span class="chip-cnt">
                  {cat === 'ALL'
                    ? (tdm.weapons || []).length
                    : (tdm.weapons || []).filter((w) => w.type?.toLowerCase() === cat.toLowerCase()).length}
                </span>
              </button>
            {/each}
          </div>

          <div class="preset-actions">
            <button type="button" class="btn btn-sm btn-steel" disabled={locked} on:click={() => applyPreset('ALL')}>
              <Icon name="check" size={12} /><span>Enable All</span>
            </button>
            <button type="button" class="btn btn-sm btn-steel" disabled={locked} on:click={() => applyPreset('PISTOLS')}>
              <Icon name="crosshair" size={12} /><span>Pistols Only</span>
            </button>
            <button type="button" class="btn btn-sm btn-steel" disabled={locked} on:click={() => applyPreset('PISTOLS_RIFLES')}>
              <Icon name="crosshair" size={12} /><span>Pistols &amp; Rifles</span>
            </button>
            <button type="button" class="btn btn-sm btn-steel" disabled={locked} on:click={() => applyPreset('RESET')}>
              <Icon name="refresh" size={12} /><span>Reset Defaults</span>
            </button>
            <button type="button" class="btn btn-sm btn-primary btn-add-custom" disabled={locked} on:click={() => (showAddWeapon = !showAddWeapon)}>
              <Icon name={showAddWeapon ? 'close' : 'plus'} size={12} />
              <span>{showAddWeapon ? 'Cancel' : 'Add Custom Weapon'}</span>
            </button>
          </div>
        </div>

        {#if showAddWeapon}
          <div class="add-weapon-panel">
            <div class="add-weapon-head">
              <h4><Icon name="plus" size={13} /> Add Custom Weapon to Catalog</h4>
              <p>Configure a custom weapon hash or item ID to be sold at both opposing team vendors.</p>
            </div>
            <div class="add-weapon-grid">
              <div class="field">
                <label for="w-type">Weapon Type</label>
                <select id="w-type" bind:value={newWeapon.type} disabled={locked}>
                  <option value="Pistol">Pistol</option>
                  <option value="SMG">SMG</option>
                  <option value="Rifle">Rifle</option>
                  <option value="Shotgun">Shotgun</option>
                  <option value="Sniper">Sniper</option>
                </select>
              </div>
              <div class="field">
                <label for="w-label">Display Label</label>
                <input id="w-label" type="text" bind:value={newWeapon.label} placeholder="e.g. Special Carbine MK2" disabled={locked} />
              </div>
              <div class="field">
                <label for="w-hash">Weapon Hash / Item ID</label>
                <input id="w-hash" type="text" bind:value={newWeapon.weapon} placeholder="WEAPON_SPECIALCARBINE_MK2" disabled={locked} />
              </div>
              <div class="field">
                <label for="w-ammo">Ammo Given</label>
                <input id="w-ammo" type="number" min="1" max="999" bind:value={newWeapon.ammo} disabled={locked} />
              </div>
              <div class="field">
                <label for="w-price">Price ($)</label>
                <input id="w-price" type="number" min="0" step="50" bind:value={newWeapon.price} disabled={locked} />
              </div>
            </div>
            <div class="add-weapon-actions">
              <button type="button" class="btn btn-sm btn-primary" on:click={addCustomWeapon} disabled={locked || !newWeapon.label || !newWeapon.weapon}>
                <Icon name="plus" size={12} /><span>Add Weapon to Shop</span>
              </button>
              <button type="button" class="btn btn-sm btn-steel" on:click={() => (showAddWeapon = false)}>
                Cancel
              </button>
            </div>
          </div>
        {/if}

        <!-- Polished Weapons Table matching other tablet tables -->
        <div class="weapons-table-wrap">
          <table class="data-table catalog-data-table">
            <thead>
              <tr>
                <th style="width: 54px; text-align: center;">Status</th>
                <th style="width: 120px;">Category</th>
                <th>Weapon Label</th>
                <th style="width: 240px;">Weapon Item Hash</th>
                <th style="width: 150px;">Ammo Count</th>
                <th style="width: 150px;">Price ($)</th>
                <th style="width: 80px; text-align: center;">Action</th>
              </tr>
            </thead>
            <tbody>
              {#each filteredWeapons as item (item.id || item.weapon)}
                <tr class:disabled-row={!item.enabled}>
                  <td style="text-align: center;">
                    <input type="checkbox" bind:checked={item.enabled} disabled={locked} class="chk" title={item.enabled ? 'Available in shop' : 'Disabled in shop'} />
                  </td>
                  <td>
                    <span class="type-badge type-{item.type?.toLowerCase()}">{item.type}</span>
                  </td>
                  <td>
                    <input type="text" class="table-input weapon-name-input" bind:value={item.label} disabled={locked} />
                  </td>
                  <td>
                    <code class="hash-pill">{item.weapon}</code>
                  </td>
                  <td>
                    <div class="input-unit ammo-unit">
                      <input type="number" min="1" max="999" bind:value={item.ammo} disabled={locked} />
                      <span class="unit-tag">rds</span>
                    </div>
                  </td>
                  <td>
                    <div class="input-unit price-unit">
                      <span class="unit-tag">$</span>
                      <input type="number" min="0" step="50" bind:value={item.price} disabled={locked} />
                    </div>
                  </td>
                  <td style="text-align: center;">
                    {#if item.custom}
                      <button type="button" class="btn-icon danger" title="Remove custom weapon" disabled={locked} on:click={() => removeCustomWeapon(item.id)}>
                        <Icon name="trash" size={13} />
                      </button>
                    {:else}
                      <button
                        type="button"
                        class="btn btn-xs {item.enabled ? 'btn-outline-danger' : 'btn-outline-success'}"
                        title={item.enabled ? 'Disable weapon' : 'Enable weapon'}
                        disabled={locked}
                        on:click={() => (item.enabled = !item.enabled)}
                      >
                        {item.enabled ? 'Disable' : 'Enable'}
                      </button>
                    {/if}
                  </td>
                </tr>
              {/each}
              {#if filteredWeapons.length === 0}
                <tr>
                  <td colspan="7" class="empty-table-cell">No weapons found in this category.</td>
                </tr>
              {/if}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  {/if}

  <!-- ═════════ GANG SELECTION MODAL (100+ Gangs Searchable List) ═════════ -->
  {#if gangPickerTeam}
    <div
      class="modal-backdrop"
      role="dialog"
      aria-modal="true"
      tabindex="-1"
      on:click={closeGangPicker}
      on:keydown={(e) => e.key === 'Escape' && closeGangPicker()}
    >
      <div class="gang-picker-modal" on:click|stopPropagation role="document">
        <div class="gp-head">
          <div class="gp-title-box">
            <span class="team-dot {gangPickerTeam}"></span>
            <div>
              <h3>Assign Gang to {gangPickerTeam === 'red' ? 'Team Red (Team A)' : 'Team Blue (Team B)'}</h3>
              <p>Select a registered gang from the server roster ({availableGangs.length} available)</p>
            </div>
          </div>
          <button type="button" class="btn-icon" on:click={closeGangPicker} title="Close">
            <Icon name="close" size={16} />
          </button>
        </div>

        <div class="gp-search-bar">
          <Icon name="search" size={14} />
          <input
            type="text"
            placeholder="Search by gang name or label (e.g. Ballas, Vagos)..."
            bind:value={gangSearch}
          />
          {#if gangSearch}
            <button type="button" class="btn-clear" on:click={() => (gangSearch = '')}>
              <Icon name="close" size={12} />
            </button>
          {/if}
        </div>

        <div class="gp-list">
          {#each filteredGangs as g (g.name)}
            {@const isSelectedCurrent = (gangPickerTeam === 'red' ? tdm.teamRedGang : tdm.teamBlueGang) === g.name}
            {@const isAssignedOther = (gangPickerTeam === 'red' ? tdm.teamBlueGang : tdm.teamRedGang) === g.name}
            <div
              class="gp-item"
              class:active={isSelectedCurrent}
              class:disabled={isAssignedOther}
              on:click={() => !isAssignedOther && selectGang(g.name)}
              on:keydown={(e) => e.key === 'Enter' && !isAssignedOther && selectGang(g.name)}
              role="button"
              tabindex="0"
            >
              <div class="gp-gang-avatar">
                <Icon name="shield" size={16} />
              </div>
              <div class="gp-gang-info">
                <span class="gp-gang-name">{g.label || g.name}</span>
                <span class="gp-gang-id">{g.name}</span>
              </div>
              <div class="gp-action-wrap">
                {#if isSelectedCurrent}
                  <span class="gp-badge current">Current {gangPickerTeam === 'red' ? 'Red' : 'Blue'}</span>
                {:else if isAssignedOther}
                  <span class="gp-badge other">Assigned to {gangPickerTeam === 'red' ? 'Blue' : 'Red'}</span>
                {:else}
                  <button type="button" class="btn btn-xs btn-primary">Select Gang</button>
                {/if}
              </div>
            </div>
          {/each}
          {#if filteredGangs.length === 0}
            <div class="gp-empty">
              <Icon name="search" size={24} />
              <p>No gangs match "<b>{gangSearch}</b>"</p>
            </div>
          {/if}
        </div>

        <div class="gp-foot">
          <span class="gp-count-hint">Showing {filteredGangs.length} of {availableGangs.length} gangs</span>
          <button type="button" class="btn btn-sm btn-steel" on:click={closeGangPicker}>Cancel</button>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  .rs-box { border: 1px solid var(--c-line); border-radius: var(--r-panel); background: var(--c-panel); padding: 14px 16px; margin-bottom: 8px; }
  .rs-toggle { display: flex; align-items: flex-start; gap: 12px; font-size: var(--fs-small); color: var(--text-dim); }
  .rs-toggle b { color: var(--text-main); }
  .rs-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; margin-top: 12px; }
  .rs-example { width: 100%; margin-top: 8px; border-collapse: collapse; font-size: var(--fs-small); }
  .rs-example th, .rs-example td { padding: 7px 10px; text-align: left; border-bottom: 1px solid var(--c-line-soft); }
  .rs-example th { font-weight: 700; color: var(--text-main); }
  .rs-note { margin: 10px 0 0; font-size: var(--fs-meta); color: var(--text-dim); line-height: 1.5; }
  @media (max-width: 900px) { .rs-grid { grid-template-columns: 1fr; } }
  .tdm-config {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .subtab-pane {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .card-box {
    background: var(--lt-15171b, #15171b);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-panel);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .card-head {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 4px;
  }
  .step-badge {
    width: 32px;
    height: 32px;
    border-radius: var(--r-tag);
    background: rgb(56, 189, 248);
    border: 1px solid rgb(56, 189, 248);
    color: #111111;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .card-head h3 {
    margin: 0;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .card-head p {
    margin: 2px 0 0;
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .state-pill {
    margin-left: auto;
    font-size: var(--fs-meta);
    padding: 3px 9px;
    border-radius: 999px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    color: var(--text-dim);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.12);
  }
  .state-pill.ok {
    background: rgb(72, 199, 142);
    border-color: rgb(72, 199, 142);
    color: #111111;
    font-weight: 600;
  }
  .zone-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-1f2328, #1f2328);
    border-radius: var(--r-panel);
    padding: 12px 14px;
  }
  .zone-stats {
    display: flex;
    gap: 22px;
    flex: 1;
    min-width: 220px;
  }
  .zone-stats div {
    display: flex;
    flex-direction: column;
  }
  .zone-stats b {
    font-size: var(--fs-title);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
    line-height: 1.1;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
  }
  .zone-stats span {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
  }
  .zone-points-list {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 4px;
  }
  .zone-point-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 8px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    color: var(--lt-e3e6e9, #e3e6e9);
  }
  .pt-idx {
    font-weight: 700;
    color: #4f94e6;
  }
  .pt-coord {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .btn-icon {
    background: transparent;
    border: none;
    padding: 2px 4px;
    color: var(--text-dim);
    cursor: pointer;
    border-radius: var(--r-tag);
    display: inline-flex;
    align-items: center;
  }
  .btn-icon:hover {
    color: var(--lt-ffffff, #fff);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.1);
  }
  .btn-icon.danger:hover {
    color: var(--tablet-danger);
    background: rgba(239, 68, 68, 0.15);
  }

  /* Pre-Match Staging Card */
  .staging-card {
    border-top: 3px solid #10b981;
  }
  .staging-badge {
    background: rgb(16, 185, 129);
    border-color: rgb(16, 185, 129);
    color: #111111;
  }
  .staging-head-right {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .staging-settings-row {
    display: flex;
    align-items: center;
    gap: 18px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-22262c, #22262c);
    border-radius: var(--r-panel);
    padding: 12px 14px;
    flex-wrap: wrap;
  }
  .staging-req-field {
    margin: 0;
    min-width: 220px;
  }
  .staging-input-unit {
    margin-top: 4px;
    border-color: #33364c;
  }
  .staging-input-unit input {
    width: 80px;
    font-weight: 700;
    color: #4f94e6;
  }
  .staging-rule-tip {
    flex: 1;
    min-width: 260px;
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-meta);
    color: #111111;
    background: rgb(16, 185, 129);
    border: 1px solid rgb(16, 185, 129);
    border-radius: var(--r-ctl);
    padding: 8px 12px;
  }
  .staging-rule-tip b {
    color: var(--lt-34d399, #34d399);
  }

  /* Team Assignment Cards */
  .team-assign-cards {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: 14px;
    margin-bottom: 4px;
  }
  .team-picker-card {
    background: var(--lt-15171b, #15171b);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .red-picker-card {
    border-left: 3px solid #ef4444;
  }
  .blue-picker-card {
    border-left: 3px solid #4f94e6;
  }
  .tp-head {
    display: flex;
    align-items: center;
    gap: 9px;
  }
  .tp-sub {
    display: block;
    font-size: var(--fs-meta);
    letter-spacing: 0.01em;
    color: var(--text-dim);
    font-weight: 700;
  }
  .tp-title {
    margin: 0;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .tp-assigned-box {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border-radius: var(--r-ctl);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    background: var(--lt-181b1f, #181b1f);
  }
  .red-box {
    border-color: var(--c-line);
    background: var(--c-raised);
    border-left: 3px solid rgb(239, 68, 68);}
  .blue-box {
    border-color: var(--c-line);
    background: var(--c-raised);
    border-left: 3px solid rgb(59, 130, 246);}
  .tp-gang-avatar {
    width: 34px;
    height: 34px;
    border-radius: var(--r-tag);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .red-avatar {
    background: var(--c-raised);
    color: #f87171;
    border: 1px solid var(--c-line);
    border-left: 3px solid rgb(239, 68, 68);}
  .blue-avatar {
    background: var(--c-raised);
    color: var(--lt-60a5fa, #60a5fa);
    border: 1px solid var(--c-line);
    border-left: 3px solid rgb(59, 130, 246);}
  .tp-gang-details {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .tp-gang-name {
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .tp-gang-code {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .tp-unassigned-box {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 10px 12px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px dashed var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
    font-size: var(--fs-meta);
  }
  .tp-swap-col {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 4px;
  }
  .btn-swap-teams-round {
    width: 38px;
    height: 38px;
    border-radius: 50%;
    background: var(--lt-1c1f24, #1c1f24);
    border: 1px solid #30353c;
    color: var(--lt-c9ced4, #c9ced4);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .btn-swap-teams-round:hover:not(:disabled) {
    background: #4f94e6;
    border-color: #4f94e6;
    color: var(--lt-ffffff, #ffffff);
    text-shadow: none;
    transform: rotate(180deg);
  }
  .tp-swap-hint {
    font-size: var(--fs-meta);
    color: var(--text-dim);
    font-weight: 600;
  }
  .btn-outline-red {
    background: transparent;
    border: 1px solid rgba(239, 68, 68, 0.4);
    color: #f87171;
  }
  .btn-outline-red:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.2);
    color: var(--lt-ffffff, #fff);
  }
  .btn-outline-blue {
    background: transparent;
    border: 1px solid rgba(59, 130, 246, 0.4);
    color: var(--lt-60a5fa, #60a5fa);
  }
  .btn-outline-blue:hover:not(:disabled) {
    background: rgba(59, 130, 246, 0.2);
    color: var(--lt-ffffff, #fff);
  }

  /* Sub Perimeter Box (Base PolyZone) */
  .sub-perimeter-box {
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-1f2328, #1f2328);
    border-radius: var(--r-ctl);
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .sub-perim-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .sub-perim-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--lt-c9ced4, #c9ced4);
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .sub-perim-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .sub-discrete-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim);
    margin-top: 4px;
  }
  .compact-list {
    margin-top: 2px;
  }

  /* Segregated Team Grids */
  .teams-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
  }
  .team-card {
    background: var(--lt-15171b, #15171b);
    border-radius: var(--r-panel);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .red-card {
    border-top: 3px solid #ef4444;
  }
  .blue-card {
    border-top: 3px solid #4f94e6;
  }
  .team-card-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .team-title-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .team-title-row h4 {
    margin: 0;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .team-indicator {
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }
  .team-indicator.red { background: #ef4444; box-shadow: none; }
  .team-indicator.blue { background: #4f94e6; box-shadow: none; }
  .count-badge {
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 999px;
  }
  .count-badge.red { background: rgb(239, 68, 68); color: #111111; border: 1px solid rgb(239, 68, 68); }
  .count-badge.blue { background: rgb(59, 130, 246); color: #111111; border: 1px solid rgb(59, 130, 246); }
  .team-desc {
    margin: 0;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    line-height: 1.4;
  }
  .empty-spawns {
    padding: 14px;
    text-align: center;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    background: var(--lt-181b1f, #181b1f);
    border: 1px dashed var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
  }
  .spawns-wrap {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    max-height: 140px;
    overflow-y: auto;
  }
  .spawn-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 7px;
    background: var(--lt-181b1f, #181b1f);
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
  }
  .red-pill { border: 1px solid rgba(239, 68, 68, 0.3); color: var(--lt-fca5a5, #fca5a5); }
  .blue-pill { border: 1px solid rgba(59, 130, 246, 0.3); color: var(--lt-93c5fd, #93c5fd); }
  .sp-num { font-weight: 700; }
  .sp-coord { font-family: var(--font-mono); font-size: var(--fs-meta); opacity: 0.85; }
  .team-card-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 4px;
  }
  .btn-red-action {
    background: rgba(239, 68, 68, 0.2);
    border: 1px solid rgba(239, 68, 68, 0.45);
    color: #f87171;
  }
  .btn-red-action:hover:not(:disabled) {
    background: #ef4444;
    color: var(--lt-ffffff, #fff);
  }
  .btn-blue-action {
    background: rgba(59, 130, 246, 0.2);
    border: 1px solid rgba(59, 130, 246, 0.45);
    color: var(--lt-60a5fa, #60a5fa);
  }
  .btn-blue-action:hover:not(:disabled) {
    background: #4f94e6;
    color: var(--lt-ffffff, #ffffff);
    text-shadow: none;
  }
  .btn-outline-danger {
    background: transparent;
    border: 1px solid rgba(239, 68, 68, 0.35);
    color: #f87171;
  }
  .btn-outline-danger:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.15);
  }

  /* Vendors Layout */
  .vendors-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
  }
  .vendor-box {
    background: var(--lt-15171b, #15171b);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-panel);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .red-vendor { border-left: 3px solid #ef4444; }
  .blue-vendor { border-left: 3px solid #4f94e6; }
  .vendor-head {
    display: flex;
    align-items: center;
    gap: 9px;
  }
  .vendor-head h4 {
    margin: 0;
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .vendor-head small {
    display: block;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    margin-top: 1px;
  }
  .team-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .team-dot.red { background: #ef4444; }
  .team-dot.blue { background: #4f94e6; }

  /* Weapons Catalog Table & Toolbar */
  .catalog-card {
    background: var(--lt-15171b, #15171b);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-panel);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .catalog-toolbar {
    padding: 12px 16px;
    background: var(--lt-181b1f, #181b1f);
    border-bottom: 1px solid var(--lt-22262c, #22262c);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
  }
  .category-chips {
    display: flex;
    gap: 5px;
    flex-wrap: wrap;
  }
  .cat-chip {
    padding: 5px 12px;
    border-radius: var(--r-tag);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    transition: all 0.15s ease;
  }
  .cat-chip:hover {
    color: var(--lt-ffffff, #fff);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
  }
  .cat-chip.active {
    background: #4f94e6;
    border-color: #4f94e6;
    color: var(--lt-ffffff, #ffffff);
    text-shadow: none;
    box-shadow: none;
  }
  .chip-cnt {
    font-size: var(--fs-meta);
    padding: 1px 6px;
    border-radius: 999px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.18);
  }
  .preset-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }
  .btn-add-custom {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
  .add-weapon-panel {
    padding: 16px;
    background: var(--lt-181b1f, #181b1f);
    border-bottom: 1px solid var(--lt-2a2e35, #2a2e35);
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .add-weapon-head h4 {
    margin: 0;
    font-size: var(--fs-small);
    font-weight: 700;
    color: #4f94e6;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .add-weapon-head p {
    margin: 2px 0 0;
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .add-weapon-grid {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 10px;
  }
  .add-weapon-grid .field {
    margin-bottom: 0;
  }
  .add-weapon-grid label {
    font-size: var(--fs-meta);
  }
  .add-weapon-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* Catalog Data Table */
  .weapons-table-wrap {
    overflow-x: auto;
    padding: 8px 12px 14px;
    background: var(--lt-15171b, #15171b);
  }
  table.catalog-data-table {
    width: 100%;
    border-spacing: 0 4px !important;
    border-collapse: separate !important;
  }
  table.catalog-data-table th {
    padding: 9px 12px !important;
    font-size: var(--fs-meta);
    letter-spacing: 0;
    font-weight: 600;
    color: var(--text-muted);
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    vertical-align: middle !important;
    box-sizing: border-box !important;
    white-space: nowrap;
  }
  table.catalog-data-table td {
    padding: 8px 12px !important;
    font-size: var(--fs-body);
    border-bottom: 1px solid var(--c-line-soft);
    background: var(--lt-181b1f, #181b1f) !important;
    vertical-align: middle !important;
    box-sizing: border-box !important;
    font-variant-numeric: tabular-nums;
  }
  table.catalog-data-table td:first-child {
    border-top-left-radius: var(--r-ctl) !important;
    border-bottom-left-radius: var(--r-ctl) !important;
    font-variant-numeric: tabular-nums;
  }
  table.catalog-data-table td:last-child {
    border-top-right-radius: var(--r-ctl) !important;
    border-bottom-right-radius: var(--r-ctl) !important;
    font-variant-numeric: tabular-nums;
  }
  table.catalog-data-table tbody tr:hover td {
    background: var(--lt-1f2328, #1f2328) !important;
    font-variant-numeric: tabular-nums;
  }
  table.catalog-data-table tr.disabled-row td {
    opacity: 0.45;
    font-variant-numeric: tabular-nums;
  }
  .weapon-name-input {
    background: var(--lt-111316, #111316);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    padding: 5px 9px;
    font-size: var(--fs-small);
    font-weight: 600;
    width: 100%;
    max-width: 240px;
  }
  .hash-pill {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    padding: 3px 8px;
    background: var(--lt-0f1113, #0f1113);
    border: 1px solid var(--lt-272b31, #272b31);
    border-radius: var(--r-tag);
    color: var(--lt-93c5fd, #93c5fd);
  }
  .ammo-unit, .price-unit {
    background: var(--lt-111316, #111316);
    border-color: var(--lt-2a2e35, #2a2e35);
  }
  .btn-outline-success {
    background: transparent;
    border: 1px solid rgba(72, 199, 142, 0.4);
    color: var(--lt-48c78e, #48c78e);
  }
  .btn-outline-success:hover:not(:disabled) {
    background: rgba(72, 199, 142, 0.15);
  }

  /* Gang Picker Modal */
  .modal-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.76);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10000;
    padding: 20px;
  }
  .gang-picker-modal {
    width: 580px;
    max-width: 95vw;
    max-height: 84vh;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-ctl);
    display: flex;
    flex-direction: column;
    box-shadow: none;
    overflow: hidden;
  }
  .gp-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px;
    background: var(--lt-15171b, #15171b);
    border-bottom: 1px solid var(--lt-272b31, #272b31);
  }
  .gp-title-box {
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .gp-title-box h3 {
    margin: 0;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .gp-title-box p {
    margin: 2px 0 0;
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .gp-search-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 20px;
    background: var(--lt-111316, #111316);
    border-bottom: 1px solid var(--lt-1f2328, #1f2328);
    color: var(--text-dim);
  }
  .gp-search-bar input {
    flex: 1;
    background: transparent;
    border: none;
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-small);
    outline: none;
  }
  .btn-clear {
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
    display: flex;
    align-items: center;
  }
  .gp-list {
    flex: 1;
    overflow-y: auto;
    padding: 10px 14px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-height: 240px;
  }
  .gp-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 14px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-22262c, #22262c);
    border-radius: var(--r-ctl);
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .gp-item:hover:not(.disabled) {
    background: var(--lt-1f2328, #1f2328);
    border-color: #4f94e6;
  }
  .gp-item.active {
    border-color: #4f94e6;
    background: rgba(56, 189, 248, 0.08);
  }
  .gp-item.disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
  .gp-gang-avatar {
    width: 32px;
    height: 32px;
    border-radius: var(--r-tag);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    color: var(--lt-c9ced4, #c9ced4);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .gp-gang-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .gp-gang-name {
    font-size: var(--fs-small);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .gp-gang-id {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .gp-action-wrap {
    margin-left: auto;
  }
  .gp-badge {
    font-size: var(--fs-meta);
    font-weight: 600;
    padding: 3px 8px;
    border-radius: var(--r-tag);
    letter-spacing: 0.01em;
  }
  .gp-badge.current {
    background: rgb(56, 189, 248);
    border: 1px solid rgb(56, 189, 248);
    color: #111111;
  }
  .gp-badge.other {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.15);
    color: var(--text-dim);
  }
  .gp-empty {
    padding: 36px 20px;
    text-align: center;
    color: var(--text-dim);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }
  .gp-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 20px;
    background: var(--lt-15171b, #15171b);
    border-top: 1px solid var(--lt-272b31, #272b31);
  }
  .gp-count-hint {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .weapons-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--fs-small);
    text-align: left;
  }
  .weapons-table th {
    padding: 9px 12px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0;
    color: var(--text-muted);
    background: var(--c-panel);
    border-bottom: 1px solid var(--c-line);
    white-space: nowrap;
  }
  .weapons-table td {
    padding: 8px 12px;
    border-bottom: 1px solid var(--c-line-soft);
    color: var(--lt-ffffff, #fff);
    vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }
  .weapons-table tr.disabled-row td {
    opacity: 0.45;
    font-variant-numeric: tabular-nums;
  }
  .weapons-table tr:hover:not(.disabled-row) td {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
    font-variant-numeric: tabular-nums;
  }
  .chk {
    accent-color: #4f94e6;
    width: 16px;
    height: 16px;
    cursor: pointer;
  }
  .type-badge {
    display: inline-block;
    padding: 2px 7px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .type-pistol { background: rgb(168, 85, 247); color: #111111; border: 1px solid rgb(168, 85, 247); }
  .type-smg { background: rgb(56, 189, 248); color: #111111; border: 1px solid rgb(56, 189, 248); }
  .type-rifle { background: rgb(234, 179, 8); color: #111111; border: 1px solid rgb(234, 179, 8); }
  .type-shotgun { background: rgb(249, 115, 22); color: #111111; border: 1px solid rgb(249, 115, 22); }
  .type-sniper { background: rgb(239, 68, 68); color: #111111; border: 1px solid rgb(239, 68, 68); }
  .code-pill {
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    padding: 2px 6px;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--lt-272b31, #272b31);
    border-radius: var(--r-tag);
    color: var(--lt-959ca5, #959ca5);
  }
  .table-input {
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-272b31, #272b31);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    padding: 4px 8px;
    font-size: var(--fs-meta);
    width: 100%;
    max-width: 220px;
  }
  .input-unit {
    display: inline-flex;
    align-items: center;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-272b31, #272b31);
    border-radius: var(--r-ctl);
    overflow: hidden;
  }
  .input-unit input {
    background: transparent;
    border: none;
    color: var(--lt-ffffff, #fff);
    padding: 4px 8px;
    font-size: var(--fs-meta);
    width: 70px;
  }
  .unit-tag {
    padding: 0 7px;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    height: 100%;
    display: inline-flex;
    align-items: center;
  }
  .empty-table-cell {
    text-align: center;
    padding: 20px;
    color: var(--text-dim);
  }

  /* Chip selectors and guide */
  .chip-row {
    display: flex;
    gap: 8px;
    margin-top: 6px;
    flex-wrap: wrap;
  }
  .chip-btn {
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border-strong);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .chip-btn:hover:not(:disabled) {
    border-color: var(--accent-primary);
    color: var(--text-main);
  }
  .chip-btn.active {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .tdm-tournament-note {
    display: flex;
    gap: 10px;
    align-items: center;
    margin-top: 10px;
    padding: 12px 14px;
    border: 1px solid var(--c-line);
    background: var(--c-raised);
    border-radius: var(--radius-sm);
    font-size: var(--fs-small);
    color: var(--lt-93c5fd, #93c5fd);
    border-left: 3px solid rgb(34, 211, 238);}
  .t-guide {
    list-style: none;
    margin: 10px 0 0;
    padding: 0;
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 8px;
  }
  .t-guide li {
    display: flex;
    gap: 8px;
    align-items: flex-start;
    padding: 9px 11px;
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    font-size: var(--fs-small);
    line-height: 1.4;
  }
  .t-guide li.on {
    border-color: rgba(var(--accent-primary-rgb), 0.55);
    color: var(--text-main);
  }
  .t-guide b {
    flex-shrink: 0;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--tablet-border-strong);
    font-size: var(--fs-meta);
  }
  .t-guide li.on b {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .t-guide em {
    display: block;
    font-style: normal;
    font-size: var(--fs-meta);
    color: var(--text-muted);
    margin-top: 2px;
  }
  .btn-mini-guide {
    margin-top: 10px;
    align-self: flex-start;
  }

  @media (max-width: 900px) {
    .teams-grid, .vendors-grid {
      grid-template-columns: 1fr;
    }
    .add-weapon-grid {
      grid-template-columns: repeat(2, 1fr);
    }
  }
</style>
