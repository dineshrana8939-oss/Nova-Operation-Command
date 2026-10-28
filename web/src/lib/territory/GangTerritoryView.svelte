<script>
  import { defaultPageSize } from '../adminPrefs.js';
  // The gang's live territory map (Event Status tablet → Territory). The SAME map component and the SAME data the admin sees.
  //   · every territory with its owner's colour and gang image, expansion areas, the running auction, rival challenges, wars
  //   · the gang's Gang XP, live (it changes the moment an event pays it or an expansion spends it)
  //   · expansion is ONLY by painting land (there are no expansion levels): the bigger the area painted, the more Gang XP it costs
  //   · rival territories (any gang's; "Adjacent" marks the touching ones) → SEND RIVAL CHALLENGE; incoming challenges → ACCEPT / DECLINE
  //   · Gang XP leaderboard, XP history, territory history
  //   · MAP EDITOR (Windows-Paint style: brush, eraser, undo / redo, save / cancel): a gang leader paints extra land onto a
  //     territory their gang owns, in the gang's colour, paying Gang XP per cell (live cost + confirmation, server-validated).
  //     Staff never paint: they create territories and hand them out (by hand or through an auction)
  import { onMount, onDestroy, tick } from 'svelte';
  import { bootstrap, viewSub } from '../stores.js';
  import { territoryState, territoryHud, xpBoard, refreshTerritoryState, refreshRivals } from './territoryStore.js';
  import { newDots } from '../tablet/ui/newDots.js';
  import { rivalsVersion } from './territoryStore.js';
  import { sendChallenge, respondChallenge, getXpBoard, getXpHistory, getTerritoryHistory, paintTerritory, adminCreateTerritory, adminClearLand } from '../api/territory.js';
  import { cellsFromSpans, countSpans } from './territoryGeometry.js';
  import { confirmAction } from '../tablet/ui/confirm.js';
  import GangLogo from '../tablet/ui/GangLogo.svelte';
  import Icon from '../tablet/ui/Icon.svelte';
  import TablePager from '../tablet/ui/TablePager.svelte';
  import TerritoryMap from './TerritoryMap.svelte';
  import PedRow from '../tablet/ui/PedRow.svelte';
  import ExpansionXpSettings from './ExpansionXpSettings.svelte';
  import { getPlayerPosition } from '../api/route.js';
  import { viewToRender, money } from './territoryRender.js';
  import '../tablet/tablet-theme.css';

  export let allowCreateTerritory = true;
  export let isGangPanel = false;

  let mapRef;
  let tab = 'map';              // map | xp | board | history
  let selectedId = null;
  let sideOpen = false;         // the floating details panel on the map (opens when a territory is picked)
  let busy = false;
  let error = '';
  let notice = '';
  let insufficient = null;      // { required, available }
  let boardMode = 'gangs';
  // every table here is paged
  let xpPage = 1, xpSize = defaultPageSize([10, 15, 25, 50]);
  let gbPage = 1, gbSize = defaultPageSize([10, 15, 25, 50]);
  let pbPage = 1, pbSize = defaultPageSize([10, 15, 25, 50]);
  let hsPage = 1, hsSize = defaultPageSize([10, 15, 25, 50]);
  $: pagedXp = xpRows.slice((xpPage - 1) * xpSize, xpPage * xpSize);
  $: pagedGangBoard = (board?.gangs || []).slice((gbPage - 1) * gbSize, gbPage * gbSize);
  $: pagedPlayerBoard = (board?.players || []).slice((pbPage - 1) * pbSize, pbPage * pbSize);
  // The Ownership Log lists who owned a territory and how it changed hands. Painting land with Gang XP (PAINT / EXPANSION) never changes
  // the owner, so those rows are XP history, not ownership history, and are left out here.
  $: ownRows = histRows.filter((h) => h.reason !== 'EXPANSION' && h.reason !== 'PAINT');
  $: pagedHist = ownRows.slice((hsPage - 1) * hsSize, hsPage * hsSize);
  let board = null;
  let xpRows = [];
  let xpBalance = null;
  let histRows = [];
  let loadedTab = {};
  let now = Math.floor(Date.now() / 1000);
  let timer;
  let warPoll;

  onMount(() => {
    refreshTerritoryState();
    // the Gang XP table is asked for at the same time as the territories (it used to wait for them: two round trips one after the other)
    rankLoaded = true;
    if (!$xpBoard.loaded) loadRank();
    timer = setInterval(() => { now = Math.floor(Date.now() / 1000); }, 1000);
    // a war's remaining time is part of the rivals list: keep it fresh while one is being fought
    warPoll = setInterval(() => { if (rivals.some((r) => r.status === 'ACTIVE')) refreshRivals(); }, 10000);
  });
  onDestroy(() => { clearInterval(timer); clearInterval(warPoll); });

  $: st = $territoryState;
  // the admin tablet (Map Zone) is the ADMIN view: no gang KPIs there, even if this admin belongs to a gang (that is Event Status)
  $: me = isGangPanel ? st.me : null;
  $: gangs = st.gangs || [];
  $: territories = st.territories || [];
  $: auction = $territoryHud.auction;
  $: mine = territories.filter((t) => me && t.owner === me.name);
  $: if (territories.length && !selectedId) selectedId = (mine[0] || territories[0]).id;
  $: sel = territories.find((t) => t.id === selectedId) || null;
  $: isMine = !!(sel && me && sel.owner === me.name);
  $: balance = me ? me.xp : 0;
  // while a gang is painting: what the change costs and what the balance would be
  $: previewCost = edit && edit.mode === 'gang' && netCost > 0 ? netCost : 0;
  $: afterXp = balance - previewCost;

  // ── find a gang / territory: free-text search + a gang picklist (both narrow the map and the list) ──
  let searchQ = '';
  let gangFilter = 'ALL';        // ALL | UNCLAIMED | MINE | <gang name>
  $: ownerCounts = territories.reduce((m, t) => { const k = t.owner || ''; m[k] = (m[k] || 0) + 1; return m; }, {});
  $: allSortedGangs = [...gangs].sort((a, b) => (a.label || a.name).localeCompare(b.label || b.name));
  $: filterGangs = gangs.filter((g) => ownerCounts[g.name]).sort((a, b) => (a.label || a.name).localeCompare(b.label || b.name));
  $: selectableGangs = isAdmin ? allSortedGangs : filterGangs;
  $: filtering = searchQ.trim() !== '' || gangFilter !== 'ALL';
  $: visibleTerritories = territories.filter((t) => {
    if (edit && t.id === edit.id) return true;      // the territory being edited never disappears under a filter
    if (gangFilter === 'UNCLAIMED' && t.owner) return false;
    if (gangFilter === 'MINE' && !(me && t.owner === me.name)) return false;
    if (gangFilter !== 'ALL' && gangFilter !== 'UNCLAIMED' && gangFilter !== 'MINE' && t.owner !== gangFilter) return false;
    const q = searchQ.toLowerCase().trim();
    if (!q) return true;
    return (t.name || '').toLowerCase().includes(q) || (t.ownerLabel || '').toLowerCase().includes(q) || (t.owner || '').toLowerCase().includes(q);
  });
  // when the filter changes, fly the map to what is left (the filter itself never touches the data)
  const refit = () => { if (mapRef && visibleTerritories.length) setTimeout(() => mapRef && mapRef.fitAll && mapRef.fitAll(), 60); };
  $: refit(gangFilter, searchQ);
  function clearFilters() { searchQ = ''; gangFilter = 'ALL'; }

  $: renderList = visibleTerritories.map((t) => {
    const r = viewToRender(t, gangs, { auctionTerritoryId: auction?.state?.lot?.territoryId, edit: edit ? { id: edit.id, mode: edit.mode, spans: edit.spans } : null });
    return r;
  });

  // ── Map editor ───────────────────────────────────────────────────────────────
  let edit = null;                 // { id, mode: 'gang' | 'admin', original, spans }
  let tool = 'brush';
  let brush = 90;
  let hist = { undo: 0, redo: 0, cells: 0 };
  let paintPlan = null;            // the gang's "spend XP on new land" confirmation
  $: paintCfg = st.config?.paint || { enabled: true, xpPerCell: 20, maxNewCells: 2500 };
  $: brushCfg = st.config?.brush || { min: 20, max: 400, default: 90 };
  const GANG_LEADER_PEDS = [
    'g_m_y_mexgoon_01', 'g_m_y_mexgoon_02', 'g_m_y_mexgoon_03',
    'g_m_y_ballaorig_01', 'g_m_y_ballaeast_01', 'g_m_y_famca_01',
    'g_m_y_famdnf_01', 'g_m_y_salvagoon_01', 'g_m_y_salvagoon_02',
    'g_m_y_korlieut_01', 'g_m_y_strpunk_01', 'csb_vagosfun',
    'g_m_m_chigoon_01', 'g_m_m_chigoon_02', 'g_m_y_azteca_01',
    'ig_claypain', 'ig_ortega', 'g_m_y_lost_01', 'g_m_y_lost_02',
  ];
  function getRandomGangPed() {
    return GANG_LEADER_PEDS[Math.floor(Math.random() * GANG_LEADER_PEDS.length)];
  }

  $: isAdmin = st.isAdmin || !!$bootstrap?.isAdmin;
  $: canCreateTerritory = isAdmin && allowCreateTerritory && !isGangPanel;
  // A gang leader paints with Gang XP. An admin who does not lead the owning gang edits the shape for free instead
  // (the server refuses XP painting on land another gang or nobody owns).
  // Painting is a GANG action, taken only in the gang tablet and paid in Gang XP. The admin tablet only looks (which gangs hold how much land).
  $: editMode = 'gang';
  // Only a gang leader (or a Manage Gang role) of the owning gang paints, with Gang XP, in the gang tablet.
  $: canEditMap = isGangPanel && !!sel && !sel.busy && isMine && !!me?.canManage && paintCfg.enabled !== false;
  // the territory's current shape, as cells
  $: activeSet = sel ? cellsFromSpans(sel.geo?.active || []) : new Set();
  $: editSet = edit ? cellsFromSpans(edit.spans) : null;
  $: originalSet = edit ? cellsFromSpans(edit.original) : null;
  $: addedCells = editSet ? [...editSet].filter((k) => !activeSet.has(k)).length : 0;
  $: removedCells = editSet && edit.mode === 'admin' ? [...activeSet].filter((k) => !editSet.has(k)).length : 0;
  $: erasedSaved = editSet && edit.mode === 'gang' ? [...originalSet].filter((k) => !editSet.has(k)).length : 0;
  $: paintCost = addedCells * (Number(paintCfg.xpPerCell) || 20);
  // Land the gang painted earlier can be rubbed out again: its XP comes back (at today's price per cell).
  $: refundXp = erasedSaved * (Number(paintCfg.xpPerCell) || 20);
  $: netCost = paintCost - refundXp;            // negative = the gang gets XP back
  $: paintAfter = balance - netCost;
  $: addedAreaKm2 = (addedCells * 0.000625).toFixed(3);
  $: pctXpUsed = balance > 0 ? Math.min(100, Math.round((Math.max(0, netCost) / balance) * 100)) : 0;
  $: tooMany = edit && edit.mode === 'gang' && addedCells > (Number(paintCfg.maxNewCells) || 2500);
  $: canSave = !!edit && !busy && (edit.mode === 'admin'
    ? addedCells > 0 || removedCells > 0
    : (addedCells > 0 || erasedSaved > 0) && !tooMany && paintAfter >= 0);
  $: if (edit && brush === 90 && brushCfg.default) brush = Number(brushCfg.default) || 90;

  // ── Admin: create new territory directly from Map Zone with Leader Ped Vector ──
  let newTerritoryModal = false;
  let newTName = '';
  let newTOwner = '';
  let newTColor = '#c45ee0';
  let newTXp = 500;
  let newTStartingBid = 100000;
  let newTMinIncrement = 10000;
  let newTPos = { x: null, y: null, z: null, heading: 0 };
  let newTPedModel = 'g_m_y_mexgoon_01';
  let newTSpriteType = 'GTA_SPRITE';
  let newTSprite = 310;
  let newTCustomLogo = '';
  let creatingTerritory = false;

  function openNewTerritory() {
    if (!canCreateTerritory) return;
    newTName = '';
    newTOwner = (gangFilter !== 'ALL' && gangFilter !== 'UNCLAIMED' && gangFilter !== 'MINE') ? gangFilter : '';
    const initialGang = gangs.find((g) => g.name === newTOwner);
    newTColor = initialGang?.color || '#c45ee0';
    newTXp = 500;
    newTStartingBid = 100000;
    newTMinIncrement = 10000;
    newTPos = { x: null, y: null, z: null, heading: 0 };
    newTPedModel = getRandomGangPed();
    newTSpriteType = 'GTA_SPRITE';
    newTSprite = 310;
    newTCustomLogo = '';
    newTerritoryModal = true;
    error = '';
  }

  function onNewOwnerChange(e) {
    newTOwner = e.target.value;
    const g = gangs.find((x) => x.name === newTOwner);
    if (g && g.color) newTColor = g.color;
  }

  async function useMyPosForNewTerritory() {
    const pos = await getPlayerPosition();
    if (pos && pos.x != null) {
      newTPos = {
        x: Number(Number(pos.x).toFixed(2)),
        y: Number(Number(pos.y).toFixed(2)),
        z: Number(Number(pos.z).toFixed(2)),
        heading: Number(Number(pos.heading || 0).toFixed(1)),
      };
    }
  }

  // The leader ped is placed the same way as every other ped in the tablet (PedRow): "Place with Hologram" returns the spot
  // the admin chose in the world (e.detail), "Use My Position" returns nothing and we read where the admin is standing.
  const round = (n, d) => Number(Number(n || 0).toFixed(d));
  function onNewPedSet(e) {
    const p = e?.detail;
    if (p && p.x != null) {
      newTPos = { x: round(p.x, 2), y: round(p.y, 2), z: round(p.z, 2), heading: round(p.heading, 1) };
    } else {
      useMyPosForNewTerritory();
    }
  }
  function clearNewPed() { newTPos = { x: null, y: null, z: null, heading: 0 }; }

  function randomizeNewPed() {
    newTPedModel = getRandomGangPed();
  }

  async function confirmCreateTerritory() {
    if (!newTName.trim()) { error = 'Please enter a name for the territory.'; return; }
    creatingTerritory = true;
    error = '';
    const res = await adminCreateTerritory({
      name: newTName.trim(),
      owner: newTOwner || null,
      color: newTColor || '#c45ee0',
      xpValue: Number(newTXp) || 500,
      startingBid: Number(newTStartingBid) || 100000,
      minBidIncrement: Number(newTMinIncrement) || 10000,
      location: newTPos.x != null ? { x: Number(newTPos.x), y: Number(newTPos.y), z: Number(newTPos.z) } : null,
      ped: {
        x: newTPos.x != null ? Number(newTPos.x) : null,
        y: newTPos.y != null ? Number(newTPos.y) : null,
        z: newTPos.z != null ? Number(newTPos.z) : null,
        heading: Number(newTPos.heading) || 0,
        model: newTPedModel || 'g_m_y_mexgoon_01',
      },
      pedModel: newTPedModel || 'g_m_y_mexgoon_01',
      sprite: Number(newTSprite) || 310,
      spriteType: newTSpriteType || 'GTA_SPRITE',
      customLogo: newTCustomLogo || '',
    });
    creatingTerritory = false;
    if (!res || !res.ok) {
      error = (res && res.error) || 'Failed to create territory.';
      return;
    }
    newTerritoryModal = false;
    notice = `Created territory "${newTName}". Synchronized live on the Map Zone.`;
    await refreshTerritoryState();
    const createdId = res.territory?.id;
    if (createdId) {
      selectedId = createdId;
      await tick();
      mapRef && mapRef.focusTerritory(createdId);
    }
  }

  // Staff never paint, but they can take stale land away (an old starting area, wrong paint): the owning gang paints it again from the leader ped.
  async function clearLandNow() {
    if (!sel || !canCreateTerritory) return;
    const ok = await confirmAction(`Clear ALL the painted land of ${sel.name}?

The starting land and everything the gangs painted is removed from every map. ${sel.ownerLabel || 'The owner'} keeps the territory and paints it again from the leader ped. This cannot be undone.`, { title: 'Clear painted land', danger: true, confirmLabel: 'Clear land' });
    if (!ok) return;
    busy = true; error = ''; notice = '';
    const res = await adminClearLand(sel.id);
    busy = false;
    if (!res || !res.ok) { error = (res && res.error) || 'The land could not be cleared.'; return; }
    notice = `${sel.name}: ${Number(res.cells || 0).toLocaleString()} cells of land cleared.`;
    refreshTerritoryState();
  }

  function gangKm2(gangName) {
    if (!gangName) return '0.000';
    const owned = (territories || []).filter((t) => t.owner === gangName);
    let totalCells = 0;
    for (const t of owned) {
      totalCells += countSpans(t.geo?.active || []) || countSpans(t.geo?.base || []);
    }
    return (totalCells * 0.000625).toFixed(3);
  }

  function startEdit() {
    if (!canEditMap || !sel) return;
    error = ''; notice = ''; insufficient = null;
    const spans = JSON.parse(JSON.stringify(sel.geo?.custom || []));
    edit = { id: sel.id, mode: editMode, original: JSON.parse(JSON.stringify(spans)), spans };
    tool = 'brush';
    mapRef && mapRef.focusTerritory(sel.id);
  }
  function cancelEdit() { edit = null; tool = 'brush'; paintPlan = null; }
  async function resetEdit() { const keep = edit; edit = null; await tick(); if (keep) startEdit(); }
  function onPaintChange(e) {
    if (edit && e.detail.territoryId === edit.id && e.detail.layerKey === 'edit') edit = { ...edit, spans: e.detail.spans };
  }
  function editError(res, fallback) {
    if (res && res.code === 'INSUFFICIENT') insufficient = res.extra || { required: paintCost, available: balance };
    else error = (res && res.error) || fallback;
  }
  async function saveEdit() {
    if (!canSave) return;
    error = ''; insufficient = null;
    if (!me?.canManage) { error = 'Only your gang leader (or a role with the Manage Gang permission) can spend Gang XP.'; return; }
    paintPlan = { territory: sel, cells: addedCells, erased: erasedSaved, cost: netCost, refund: refundXp, gross: paintCost, before: balance, after: paintAfter };
  }
  async function confirmPaint() {
    if (!paintPlan || !edit || busy) return;
    busy = true; error = ''; insufficient = null;
    const res = await paintTerritory(edit.id, edit.spans, paintPlan.cost);
    busy = false;
    const name = paintPlan.territory.name, cells = paintPlan.cells, erased = paintPlan.erased, net = paintPlan.cost;
    paintPlan = null;
    if (!res || !res.ok) { editError(res, 'The land could not be saved.'); refreshTerritoryState(); return; }
    if (cells > 0 && erased > 0) notice = `${name}: +${cells} / −${erased} cells (${net > 0 ? `−${net.toLocaleString()}` : `+${(-net).toLocaleString()}`} Gang XP).`;
    else if (erased > 0) notice = `${name}: ${erased} painted cells erased — ${(-net).toLocaleString()} Gang XP refunded.`;
    else notice = `${name} grew by ${cells} cells.`;
    edit = null; tool = 'brush';
    refreshTerritoryState();
  }
  $: markers = auction?.state?.location ? [{ x: auction.state.location.x, y: auction.state.location.y, label: 'Auction house', color: '#ffc857' }] : [];

  function pick(id) {
    if (edit) { error = 'Save or cancel your map edit first.'; return; }
    selectedId = id; sideOpen = true; error = ''; notice = ''; insufficient = null;
    mapRef && mapRef.focusTerritory(id);
  }
  function onMapSelect(e) { if (edit) return; if (e.detail.id) { selectedId = e.detail.id; sideOpen = true; error = ''; insufficient = null; } }

  // ── rivals ───────────────────────────────────────────────────────────────────
  $: rivals = st.rivals || [];
  $: candidates = st.candidates || [];
  $: incoming = rivals.filter((r) => r.status === 'PENDING' && me && r.defender === me.name);
  $: myRivals = rivals.filter((r) => me && (r.attacker === me.name || r.defender === me.name) && ['PENDING', 'ACCEPTED', 'SCHEDULED', 'ACTIVE'].includes(r.status));
  $: otherWars = rivals.filter((r) => r.status === 'ACTIVE' && !(me && (r.attacker === me.name || r.defender === me.name)));
  async function challenge(c) {
    busy = true; error = ''; notice = '';
    const res = await sendChallenge(c.mineId, c.theirsId);
    busy = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not send the challenge.'; return; }
    notice = `Challenge sent to ${c.rivalLabel} for ${c.theirsName}.`;
    refreshRivals();
  }
  // answering a challenge opens a small box first: the gang can leave the admins a comment (shown under that challenge on the admin Rival Wars tab)
  let answerFor = null;
  let answerAccept = true;
  let answerComment = '';
  function askAnswer(r, accept) { answerFor = r; answerAccept = accept; answerComment = ''; error = ''; }
  // the sections of the Map Zone, each with a line saying what it is for
  $: subTabs = [
    { id: 'map', icon: 'pin', title: 'Map', desc: 'Your territories on the live map. Paint more land with Gang XP.' },
    ...(me ? [{ id: 'rivals', icon: 'crosshair', title: 'Rival Wars', desc: 'Invitations from other gangs and the wars you are in.' }] : []),
    ...(canCreateTerritory ? [{ id: 'expansion', icon: 'zap', title: 'Expansion XP', desc: 'The price of painting land.' }] : []),
    { id: 'xp', icon: 'activity', title: 'XP History', desc: 'Where your Gang XP came from and where it went.' },
    { id: 'board', icon: 'trophy', title: 'Gang XP Ranking', desc: 'Every gang ranked by Gang XP.' },
    { id: 'history', icon: 'history', title: 'Ownership History', desc: 'Who held each territory and when it changed hands.' },
  ];
  // a dot on a section when something new arrived there since it was last opened
  const subDots = newDots('nova_gang_territory_dots');
  $: subDots.update({
    rivals: me ? `${$rivalsVersion}|${incoming.length}` : null,
    xp: me ? String(me.xp) : null,
    history: territories.length ? territories.map((t) => `${t.id}:${t.owner || ''}`).join(',') : null,
  }, tab);
  async function answer() {
    const r = answerFor;
    if (!r) return;
    busy = true; error = '';
    const res = await respondChallenge(r.id, answerAccept, answerComment.trim());
    busy = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not answer.'; return; }
    notice = answerAccept ? `You accepted the challenge for ${r.territoryName}. An admin will schedule the war.` : `You declined the challenge for ${r.territoryName}.`;
    answerFor = null;
    refreshRivals();
  }
  $: recentRivals = rivals.filter((r) => me && (r.attacker === me.name || r.defender === me.name) && !['PENDING', 'ACCEPTED', 'SCHEDULED', 'ACTIVE'].includes(r.status)).slice(0, 12);
  const fmtClock = (s) => `${String(Math.floor(Math.max(0, s) / 60)).padStart(2, '0')}:${String(Math.max(0, s) % 60).padStart(2, '0')}`;
  const when = (ts) => (ts ? new Date(ts * 1000).toLocaleString([], { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');
  const STATUS_CLASS = { PENDING: 'badge-draft', ACCEPTED: 'badge-scheduled', SCHEDULED: 'badge-starting', ACTIVE: 'badge-under-attack' };

  // ── XP / board / history tabs ────────────────────────────────────────────────
  async function loadTab(t) {
    if (t === 'xp') { const r = await getXpHistory({ limit: 300 }); if (r && r.ok) { xpRows = r.history || []; xpBalance = r.balance; } }
    else if (t === 'board') { const r = await getXpBoard(); if (r && r.ok) board = r; }
    else if (t === 'history') { const r = await getTerritoryHistory(null); if (r && r.ok) histRows = r.history || []; }
  }
  function setTab(t) { tab = t; loadTab(t); }
  // Admin tablet: the tabs are the floating row under the main menu (sub pages of Map Zone). The gang tablet keeps its own row.
  const ADMIN_SUBS = ['map', 'expansion', 'xp', 'board', 'history'];
  $: if (!isGangPanel && ADMIN_SUBS.includes($viewSub) && tab !== $viewSub) setTab($viewSub);
  // live: a changed balance refreshes whichever list is showing
  let lastXp = null;
  $: if (me && lastXp !== me.xp) { const first = lastXp === null; lastXp = me.xp; if (!first && (tab === 'xp' || tab === 'board')) loadTab(tab); }

  // ── "Your zone" summary: own territories, earned XP, rank ──────────────────────────────────────
  let myRank = null;
  let rankTotal = 0;
  let topGang = null;
  let rankLoaded = false;
  // First fetch only; after that the server pushes the whole XP table to every open Map Zone (gangs AND admins) whenever
  // any gang's XP or territory count moves, so ranks, the ranking tab and the XP history stay live without a refresh.
  async function loadRank() {
    const r = await getXpBoard();
    if (r && r.ok) xpBoard.set({ loaded: true, gangs: r.gangs || [] });
  }
  function applyBoard(rows, mine) {
    rankTotal = rows.length;
    topGang = rows[0] || null;
    const i = mine ? rows.findIndex((g) => g.gang === mine.name) : -1;
    myRank = i >= 0 ? i + 1 : null;
    if (board) board = { ...board, gangs: rows };
    if (tab === 'xp') loadTab('xp');
  }
  $: if ($xpBoard.loaded) applyBoard($xpBoard.gangs, me);
  $: if (st.loaded && !rankLoaded) { rankLoaded = true; if (!$xpBoard.loaded) loadRank(); }
  $: landKm2 = me ? gangKm2(me.name) : '0.000';
  $: spentXp = me ? Math.max(0, (me.lifetimeXp || 0) - (me.xp || 0)) : 0;
  $: claimed = territories.filter((t) => t.owner).length;
  $: warsOn = territories.filter((t) => t.busy).length;
  $: landByGang = Object.values(territories.filter((t) => t.owner).reduce((m, t) => { const g = m[t.owner] || (m[t.owner] = { name: t.owner, label: t.ownerLabel || t.owner, count: 0, cells: 0 }); g.count += 1; g.cells += countSpans(t.geo?.active || t.geo?.base || []); return m; }, {})).map((g) => ({ ...g, km2: (g.cells * 0.000625).toFixed(3) })).sort((a, b) => b.cells - a.cells);
  const areaKm2 = (t) => (countSpans(t.geo?.active || t.geo?.base || []) * 0.000625).toFixed(3);
  const num = (n) => Number(n || 0).toLocaleString();

  const reasonText = { AUCTION: 'Auction', WAR: 'War', EXPANSION: 'Expansion', ADMIN: 'Admin', INITIAL: 'Starting owner', PAINT: 'Map edit' };
</script>

<div class="gt">
  <!-- XP + tabs bar -->
  <div class="gt-top">
    {#if me}
      <div class="xp-card">
        <GangLogo logo={me.logo} label={me.label} size={44} accentColor={me.color} />
        <div class="xp-info">
          <div class="xp-gang">{me.label}</div>
          <div class="xp-sub">{mine.length} territor{mine.length === 1 ? 'y' : 'ies'} · lifetime {Number(me.lifetimeXp || 0).toLocaleString()} XP</div>
        </div>
        <div class="xp-balance" class:preview={previewCost > 0}>
          <span class="xp-label">GANG XP</span>
          <span class="xp-value">{Number(balance).toLocaleString()}</span>
          {#if previewCost > 0}
            <span class="xp-arrow">→</span>
            <span class="xp-after" class:bad={afterXp < 0}>{Number(afterXp).toLocaleString()}</span>
            <span class="xp-cost">−{Number(previewCost).toLocaleString()} XP</span>
          {/if}
        </div>
      </div>
    {:else}
      {#if isGangPanel}<div class="xp-card"><div class="xp-info"><div class="xp-gang">Territory overview</div><div class="xp-sub">You are viewing the map as an administrator.</div></div></div>{/if}
    {/if}
    {#if isGangPanel}
    <div class="gt-tabs" role="tablist" aria-label="Map Zone sections">
      {#each subTabs as t (t.id)}
        <button type="button" role="tab" aria-selected={tab === t.id} class="gt-tab" class:active={tab === t.id} on:click={() => setTab(t.id)}>
          <span class="gt-tab-ico"><Icon name={t.icon} size={20} /></span>
          <span class="gt-tab-txt"><b>{t.title}{#if t.id === 'rivals' && incoming.length}<em class="tab-n">{incoming.length}</em>{/if}</b><span>{t.desc}</span></span>
          {#if $subDots[t.id] && tab !== t.id}<i class="new-dot" title="Something new" aria-label="Something new"></i>{/if}
        </button>
      {/each}
    </div>
    {/if}
  </div>

  {#if error}<div class="gt-error">{error}</div>{/if}
  {#if notice}<div class="gt-notice">{notice}</div>{/if}

  {#if tab === 'map'}
    {#if !edit}
    <div class="zone-strip">
      {#if me}
        <div class="zs"><span>Your territories</span><b>{mine.length}</b></div>
        <div class="zs"><span>Land held</span><b>{landKm2} km²</b></div>
        <div class="zs xp"><span>Gang XP (spendable)</span><b>{num(balance)}</b></div>
        <div class="zs"><span>XP earned (lifetime)</span><b>{num(me.lifetimeXp)}</b></div>
        <div class="zs"><span>XP spent / lost</span><b>{num(spentXp)}</b></div>
        <div class="zs"><span>Gang XP rank</span><b>{myRank ? `#${myRank} / ${rankTotal}` : '—'}</b></div>
      {:else}
        <div class="zs"><span>Territories</span><b>{territories.length}</b></div>
        <div class="zs"><span>Claimed</span><b>{claimed}</b></div>
        <div class="zs"><span>Unclaimed</span><b>{territories.length - claimed}</b></div>
        <div class="zs"><span>Wars in progress</span><b>{warsOn}</b></div>
        <div class="zs xp"><span>Top Gang XP</span><b>{topGang ? `${topGang.label} · ${num(topGang.totalXp)}` : '—'}</b></div>
      {/if}
    </div>
    {#if !me}
      <div class="zone-list">
        <span class="zl-title">Land by gang</span>
        {#each landByGang as g (g.name)}
          <span class="zl-chip" style="cursor:default"><span class="zl-name">{g.label}</span><span class="zl-meta">{g.count} territor{g.count === 1 ? 'y' : 'ies'} · {g.km2} km²</span></span>
        {:else}<span class="muted">No gang holds a territory yet.</span>{/each}
      </div>
    {/if}
    {#if me}
      <div class="zone-list">
        <span class="zl-title">Your zones</span>
        {#each mine as t (t.id)}
          <button type="button" class="zl-chip" class:active={t.id === selectedId} on:click={() => pick(t.id)}>
            <span class="zl-name">{t.name}</span>
            <span class="zl-meta">{areaKm2(t)} km² · worth {num(t.xpValue)} XP{t.busy ? ' · AT WAR' : ''}</span>
          </button>
        {:else}
          <span class="muted">Your gang does not own a territory yet — win one at a Gang Territory Auction, or take one in a war.</span>
        {/each}
      </div>
    {/if}
    <div class="gt-filter">
      <div class="gf-search">
        <Icon name="search" size={13} />
        <input type="text" placeholder="Search a gang or a territory…" bind:value={searchQ} />
        {#if searchQ}<button type="button" class="gf-clear" on:click={() => (searchQ = '')} aria-label="Clear search"><Icon name="close" size={12} /></button>{/if}
      </div>
      <label class="gf-select"><span>Gang</span>
        <select bind:value={gangFilter}>
          <option value="ALL">All gangs</option>
          {#if me}<option value="MINE">My gang only</option>{/if}
          <option value="UNCLAIMED">Unclaimed ({territories.filter((t) => !t.owner).length})</option>
          {#each selectableGangs as g (g.name)}<option value={g.name}>{g.label || g.name} ({ownerCounts[g.name] || 0})</option>{/each}
        </select>
      </label>
      {#if filtering}<button type="button" class="gf-reset" on:click={clearFilters}>Clear filters</button>{/if}
      <span class="gf-count">{visibleTerritories.length} of {territories.length} territories</span>
      {#if canCreateTerritory}
        <button type="button" class="create-btn" on:click={openNewTerritory} title="Add a territory: name, auction, leader ped and map badge"><span class="create-plus"><Icon name="plus" size={14} /></span>Create Territory</button>
      {/if}
    </div>
    {/if}
    <div class="gt-main">
      <div class="gt-map">
        {#if !st.loaded}<div class="gt-loading">Loading the territory map…</div>{/if}

        <!-- Map editor toolbar (Paint-style) -->
        {#if edit}
            <section class="planner" class:bad={edit.mode === 'gang' && (paintAfter < 0 || tooMany)}>
              <header class="pl-head">
                <div class="pl-who">
                  <span class="pl-swatch" style="background:{sel?.color || me?.color || '#4f94e6'};"></span>
                  <div class="pl-titles">
                    <span class="pl-kicker">{edit.mode === 'gang' ? (me?.label || sel?.ownerLabel || 'Your gang') : 'Admin edit — free'}</span>
                    <span class="pl-title"><span class="pl-verb">{edit.mode === 'gang' ? 'Expanding' : 'Editing'}</span> {sel?.name}</span>
                  </div>
                  {#if edit.mode === 'gang'}
                    <span class="pl-rate" title="Cost per 25m x 25m grid cell"><Icon name="zap" size={13} /> {paintCfg.xpPerCell} XP / cell <small>({(paintCfg.xpPerCell * 1600).toLocaleString()} XP/km²)</small></span>
                  {/if}
                </div>
                <div class="pl-actions">
                  {#if edit.mode === 'gang'}
                    <button type="button" class="tool" on:click={resetEdit} title="Throw away what you painted since you opened the editor"><Icon name="refresh" size={14} /> Reset</button>
                  {/if}
                  <button type="button" class="tool" disabled={busy} on:click={cancelEdit}><Icon name="close" size={14} /> Cancel</button>
                  <button type="button" class="tool save" disabled={!canSave} on:click={saveEdit}>
                    <Icon name="check" size={14} />
                    {edit.mode === 'admin' ? 'Save shape' : (!canSave ? 'Save changes' : netCost > 0 ? `Save · spend ${Number(netCost).toLocaleString()} XP` : netCost < 0 ? `Save · get back ${Number(-netCost).toLocaleString()} XP` : 'Save changes')}
                  </button>
                </div>
              </header>

              {#if edit.mode === 'gang'}
                <div class="pl-metrics four">
                  <div class="pl-m">
                    <span class="pl-lbl">New area</span>
                    <span class="pl-val area">{addedAreaKm2}<small>km²</small></span>
                    <span class="pl-sub">+{addedCells.toLocaleString()} cells{#if erasedSaved > 0} · −{erasedSaved.toLocaleString()} erased{/if}</span>
                  </div>
                  <div class="pl-m">
                    <span class="pl-lbl">{netCost < 0 ? 'XP refund' : 'XP cost'}</span>
                    <span class="pl-val cost" class:ok={netCost < 0}>{netCost < 0 ? '+' : '−'}{Number(Math.abs(netCost)).toLocaleString()}<small>XP</small></span>
                    <span class="pl-sub">{#if erasedSaved > 0 && addedCells > 0}{Number(paintCost).toLocaleString()} new land − {Number(refundXp).toLocaleString()} back{:else if erasedSaved > 0}{Number(refundXp).toLocaleString()} XP for {erasedSaved.toLocaleString()} erased cells{:else}{paintCfg.xpPerCell} XP for each cell{/if}</span>
                  </div>
                  <div class="pl-m">
                    <span class="pl-lbl">Your Gang XP</span>
                    <span class="pl-val">{Number(balance).toLocaleString()}</span>
                    <span class="pl-sub">{pctXpUsed}% of it is used by this change</span>
                  </div>
                  <div class="pl-m">
                    <span class="pl-lbl">After saving</span>
                    <span class="pl-val" class:ok={paintAfter >= 0} class:bad={paintAfter < 0}>{Number(paintAfter).toLocaleString()}</span>
                    <div class="pl-gauge" title="Share of your Gang XP this change uses"><i class:danger={paintAfter < 0} style="width: {netCost > 0 ? Math.min(100, Math.max(2, pctXpUsed)) : 0}%;"></i></div>
                  </div>
                </div>

                {#if paintAfter < 0}
                  <div class="pl-status danger"><Icon name="warning" size={15} /><span><b>Not enough Gang XP.</b> This change costs {Number(netCost).toLocaleString()} XP but your gang has {Number(balance).toLocaleString()}. Undo some cells to continue.</span></div>
                {:else if tooMany}
                  <div class="pl-status warning"><Icon name="warning" size={15} /><span><b>Too many cells.</b> At most {Number(paintCfg.maxNewCells).toLocaleString()} new cells can be saved at once.</span></div>
                {:else if addedCells > 0 || erasedSaved > 0}
                  <div class="pl-status success"><Icon name="check" size={15} /><span><b>Ready to save.</b> {#if netCost > 0}Saving spends {Number(netCost).toLocaleString()} Gang XP{:else if netCost < 0}Saving gives {Number(-netCost).toLocaleString()} Gang XP back to your gang{:else}Saving costs nothing{/if}{#if addedCells > 0 && erasedSaved === 0} and claims this land{/if}.</span></div>
                {:else}
                  <div class="pl-status info"><Icon name="brush" size={15} /><span>Paint outwards from the edges of <b>{sel?.name}</b>. Rubbing out land your gang painted gives its XP back.</span></div>
                {/if}
              {:else}
                <div class="pl-metrics three">
                  <div class="pl-m"><span class="pl-lbl">Total cells</span><span class="pl-val">{editSet.size.toLocaleString()}</span></div>
                  <div class="pl-m"><span class="pl-lbl">Added</span><span class="pl-val area">+{addedCells.toLocaleString()}</span></div>
                  <div class="pl-m"><span class="pl-lbl">Removed</span><span class="pl-val bad">−{removedCells.toLocaleString()}</span></div>
                </div>
                <div class="pl-status info"><Icon name="brush" size={15} /><span>Paint to add land and erase to remove any part of it (base or painted land). It can't overlap another territory.</span></div>
              {/if}
            </section>
        {:else if canCreateTerritory}
          <div class="map-tools overview">
            <span class="live-dot" aria-hidden="true"></span>
            <span class="tool-hint"><b>Live overview.</b> Gangs grow their territories by painting land with Gang XP. Land is painted by the gangs themselves in their own tablet (Event Status). Here you see who holds how much; hand a territory over or delete it in <b>Community → Gang Management → Territory Control</b>, and change the price in <b>Painting Price</b>.</span>
          </div>
        {:else if canEditMap}
          <div class="map-tools">
            <button type="button" class="tool save" on:click={startEdit}><Icon name="edit" size={14} /> Paint land (uses Gang XP)</button>
            <span class="tool-hint">Grow <b>{sel.name}</b>: {paintCfg.xpPerCell} Gang XP per cell, in your gang's colour — you have {Number(balance).toLocaleString()} XP.{#if !(sel.geo?.active || []).length} It has no land yet: paint outwards from its leader ped.{/if}</span>
          </div>
        {:else if sel && isMine && !me?.canManage}
          <div class="map-tools"><span class="tool-hint">Only your gang leader (or a role with the Manage Gang permission) can paint land.</span></div>
        {/if}

        <div class="map-stage">
        <TerritoryMap bind:this={mapRef} territories={renderList} mode={edit ? 'edit' : 'view'} selectedId={edit ? edit.id : selectedId} activeLayerKey="edit" editing={!!edit} bind:tool brushRadius={brush} {markers} height="100%" isAdmin={edit ? edit.mode === 'admin' : isAdmin} gangLabel={me?.label || sel?.ownerLabel || sel?.name || ''}
          on:select={onMapSelect} on:change={onPaintChange} on:history={(e) => (hist = e.detail)}
          on:colorChange={(e) => { if (sel && edit && edit.mode === 'admin') { sel.color = e.detail.color; } }} />
          <button type="button" class="side-toggle" class:on={sideOpen} on:click={() => (sideOpen = !sideOpen)} aria-expanded={sideOpen} title="Territory details">
            <Icon name="list" size={14} /> Details{#if incoming.length || auction?.state}<em>{incoming.length + (auction?.state ? 1 : 0)}</em>{/if}
          </button>
          {#if sideOpen}
          <aside class="gt-side" aria-label="Territory details">
          <!-- selected territory -->
          {#if sel}
            <div class="card">
              <div class="card-title"><span class="dot" style="background:{sel.owner ? (sel.ownerAccent || gangs.find((g) => g.name === sel.owner)?.color || sel.color) : sel.color}"></span>{sel.name}</div>
              <div class="kv"><span>Owner</span><b>{sel.ownerLabel || 'Unclaimed'}{isMine ? ' (your gang)' : ''}</b></div>
              <div class="kv"><span>Land</span><b>{areaKm2(sel)} km²</b></div>
              <div class="kv"><span>XP value</span><b>{Number(sel.xpValue || 0).toLocaleString()}</b></div>
              {#if sel.busy}<div class="war-flag">⚔ A war is being fought here</div>{/if}
              {#if sel.description}<div class="desc">{sel.description}</div>{/if}

              {#if canCreateTerritory}
                <div class="sub-title">Land</div>
                <div class="muted small">Staff do not paint. If this territory still carries old or wrong land, clear it: the owner keeps the territory and paints it again from the leader ped.</div>
                <button type="button" class="btn btn-danger full" disabled={busy || sel.busy} on:click={clearLandNow}><Icon name="trash" size={13} /> Clear painted land</button>
              {/if}
              {#if isMine}
                <div class="sub-title">Expansion</div>
                <div class="muted small">Grow {sel.name} by painting land onto it: <b>{paintCfg.xpPerCell} Gang XP per cell</b> ({(paintCfg.xpPerCell * 1600).toLocaleString()} XP per km²). The bigger the area you paint, the more XP is taken from your gang — and rubbing painted land out gives the XP back.</div>
                {#if !me?.canManage}<div class="muted small">Only your gang leader (or the Manage Gang role) can spend Gang XP.</div>{/if}
              {/if}
            </div>
          {:else if territories.length === 0}
            <div class="card">
              <div class="card-title"><Icon name="pin" size={14} /> Territory Management</div>
              <div class="desc">No territories currently exist on the map.</div>
              {#if canCreateTerritory}
                <p class="muted small" style="margin: 8px 0 0;">Use <b>Create Territory</b> above the map to add the first one (leader ped position and blip).</p>
              {:else}
                <p class="muted small">Territories appear once an administrator creates them or publishes a Gang Territory Auction.</p>
              {/if}
            </div>
          {:else}
            <div class="card">
              <div class="card-title"><Icon name="pin" size={14} /> Select a Territory</div>
              <div class="desc">Click any territory on the map or pick one from the list below to view its details.</div>
            </div>
          {/if}


          <!-- running auction -->
          {#if auction?.state}
            <div class="card auction">
              <div class="card-title"><Icon name="megaphone" size={14} /> Territory Auction — live</div>
              {#if auction.state.lot}
                {@const lot = auction.state.lot}
                {@const tick = auction.tick}
                <div class="kv"><span>Territory</span><b>{lot.name} ({lot.lotIndex}/{auction.state.totalLots})</b></div>
                <div class="kv"><span>Current bid</span><b>{money(tick?.currentBid ?? lot.currentBid)}</b></div>
                <div class="kv"><span>Leading</span><b>{tick?.leadingGangLabel || lot.leadingGangLabel || 'No bids'}</b></div>
                <div class="kv"><span>Time left</span><b>{fmtClock(tick?.timeRemaining ?? lot.timeRemaining)}</b></div>
                <div class="muted small">Eligible gang members bid at the auction house.</div>
              {:else}
                <div class="muted">{auction.state.phase === 'INTRO' ? 'Bidding opens shortly.' : 'Next territory coming up…'}</div>
              {/if}
            </div>
          {/if}

          <!-- challenges for my gang -->
          {#each incoming as r (r.id)}
            <div class="card challenge">
              <div class="card-title">TERRITORY RIVAL CHALLENGE</div>
              <div class="desc">{r.attackerLabel} has challenged your gang to a war. Nobody loses a territory: the winner loots the Leader Ped, taking Gang XP and shrinking the loser's painted land.</div>
              <div class="kv"><span>Challenger</span><b>{r.attackerLabel}</b></div>
              <div class="kv"><span>Fought at</span><b>{r.territoryName}</b></div>
              <div class="muted small">The war is fought on the smaller gang's own territory, so you may be the side that attacks.</div>
              {#if me?.canManage}
                <div class="btn-pair"><button type="button" class="btn btn-primary" disabled={busy} on:click={() => askAnswer(r, true)}>ACCEPT</button><button type="button" class="btn btn-danger" disabled={busy} on:click={() => askAnswer(r, false)}>DECLINE</button></div>
              {:else}<div class="muted small">Your gang leader answers challenges.</div>{/if}
            </div>
          {/each}

          <!-- rival territories -->
          {#each candidates as c (c.mineId + c.theirsId)}
            <div class="card rival">
              <div class="card-title">RIVAL TERRITORY</div>
              <div class="desc">
                Challenge <b>{c.rivalLabel}</b> ({c.theirsName})
                {#if c.touching}<span class="badge" style="margin-left: 6px; font-size: var(--fs-meta); background: rgba(255, 200, 87, 0.15); color: #ffc857;">Adjacent</span>{/if}
              </div>
              <div class="kv"><span>Rival Zone Size</span><b>{c.theirsKm2 || 0} km² ({c.theirsCells || 0} cells)</b></div>
              <div class="kv"><span>Rival Gang XP</span><b style="color: #ffc857;">{(c.theirsXp || 0).toLocaleString()} XP</b></div>
              <div class="kv"><span>From Territory</span><b>{c.mineName} ({c.mineKm2 || 0} km²)</b></div>
              <button type="button" class="btn btn-primary full" disabled={busy || !!c.blocked || !me?.canManage} title={c.blocked || ''} on:click={() => challenge(c)}>SEND RIVAL CHALLENGE</button>
              {#if c.blocked}<div class="muted small">{c.blocked}</div>{:else if !me?.canManage}<div class="muted small">Only your gang leader can send challenges.</div>{/if}
            </div>
          {/each}

          <!-- my gang's open challenges / wars -->
          {#if myRivals.length}
            <div class="card">
              <div class="card-title">Rivals</div>
              {#each myRivals as r (r.id)}
                <div class="riv">
                  <div><b>{r.attackerLabel}</b> vs <b>{r.defenderLabel}</b> — {r.territoryName}</div>
                  <div><span class="badge {STATUS_CLASS[r.status] || ''}">{r.status}</span>
                    {#if r.status === 'SCHEDULED'} <span class="muted">{r.warAtText || when(r.warAt)} · {Math.round((r.durationSec || 0) / 60)} min</span>{/if}
                    {#if r.status === 'ACTIVE' && r.live} <span class="muted">{fmtClock(r.live.secondsLeft)} left · {r.live.state}</span>{/if}
                    {#if r.status === 'PENDING' && r.attacker === me?.name}<span class="muted"> waiting for {r.defenderLabel}</span>{/if}
                    {#if r.status === 'ACCEPTED'}<span class="muted"> waiting for an admin to set the date</span>{/if}</div>
                  {#if r.status === 'SCHEDULED' || r.status === 'ACTIVE'}<div class="muted small">Both gangs are responsible for being present before the battle begins.</div>{/if}
                </div>
              {/each}
            </div>
          {/if}
          {#if otherWars.length}
            <div class="card"><div class="card-title">Wars in progress</div>{#each otherWars as r (r.id)}<div class="riv"><b>{r.attackerLabel}</b> vs <b>{r.defenderLabel}</b> — {r.territoryName}{#if r.live} <span class="muted">· {fmtClock(r.live.secondsLeft)}</span>{/if}</div>{/each}</div>
          {/if}

          <!-- territory list -->
          <div class="card">
            <div class="card-title">{filtering ? `Matching territories (${visibleTerritories.length} of ${territories.length})` : `All territories (${territories.length})`}</div>
            {#each visibleTerritories as t (t.id)}
              <button type="button" class="t-row" class:active={t.id === selectedId} on:click={() => pick(t.id)}>
                <span class="dot" style="background:{t.owner ? (t.ownerAccent || gangs.find((g) => g.name === t.owner)?.color || t.color) : t.color}"></span>
                <span class="t-name">{t.name}</span>
                <span class="t-owner">{t.ownerLabel || 'Unclaimed'}{me && t.owner === me.name ? ' ★' : ''}</span>
                {#if t.busy}<span class="war-pill">WAR</span>{/if}
              </button>
            {/each}
            {#if !territories.length && st.loaded}<div class="muted">No territories yet — they appear once a Gang Territory Auction is published.</div>{/if}
            {#if territories.length && !visibleTerritories.length}<div class="muted">Nothing matches. <button type="button" class="linkish" on:click={clearFilters}>Clear the search</button></div>{/if}
          </div>
        </aside>
          {/if}
        </div>
        <div class="gt-legend">
          <span><i style="background:#c45ee0"></i>Owned territory (owner's colour)</span><span>Click a territory to select — it blinks on the map</span>
        </div>
      </div>


    </div>

  {:else if tab === 'expansion' && canCreateTerritory}
    <ExpansionXpSettings />

  {:else if tab === 'rivals'}
    <div class="rv-tab">
      <div class="gt-table">
        <div class="tbl-head">Invitations</div>
        {#if incoming.length === 0}
          <div class="rv-empty">No gang is challenging yours right now. When one does, the invitation appears here.</div>
        {/if}
        {#each incoming as r (r.id)}
          <div class="rv-card">
            <div class="rv-main">
              <div class="rv-vs"><b>{r.attackerLabel}</b> has challenged <b>{r.defenderLabel}</b></div>
              <div class="muted small">Fought at <b>{r.territoryName}</b>{#if r.attackerTerritoryName} · from {r.attackerTerritoryName}{/if}. The winner loots the Leader Ped (Gang XP, and the loser's painted land shrinks); nobody loses the territory itself.</div>
            </div>
            {#if me?.canManage}
              <div class="btn-pair"><button type="button" class="btn btn-primary" disabled={busy} on:click={() => askAnswer(r, true)}>Accept</button><button type="button" class="btn btn-danger" disabled={busy} on:click={() => askAnswer(r, false)}>Decline</button></div>
            {:else}<div class="muted small">Your gang leader (or a role with Manage Gang) answers challenges.</div>{/if}
          </div>
        {/each}
      </div>

      <div class="gt-table">
        <div class="tbl-head">My gang's challenges and wars</div>
        {#if myRivals.length === 0}<div class="rv-empty">Nothing open. Challenges you send or receive are tracked here until the war is over.</div>{/if}
        {#each myRivals as r (r.id)}
          <div class="rv-card">
            <div class="rv-main">
              <div class="rv-vs"><b>{r.attackerLabel}</b> vs <b>{r.defenderLabel}</b> — {r.territoryName}</div>
              <div><span class="badge {STATUS_CLASS[r.status] || ''}">{r.status}</span>
                {#if r.status === 'SCHEDULED'} <span class="muted">{r.warAtText || when(r.warAt)} · {Math.round((r.durationSec || 0) / 60)} min</span>{/if}
                {#if r.status === 'ACTIVE' && r.live} <span class="muted">{fmtClock(r.live.secondsLeft)} left · {r.live.state}</span>{/if}
                {#if r.status === 'PENDING' && r.attacker === me?.name}<span class="muted"> waiting for {r.defenderLabel}</span>{/if}
                {#if r.status === 'PENDING' && r.defender === me?.name}<span class="muted"> waiting for your answer</span>{/if}
                {#if r.status === 'ACCEPTED'}<span class="muted"> waiting for an admin to set the date</span>{/if}</div>
              {#if r.comment}<div class="rv-comment"><span>{r.defenderLabel} told the admins</span>{r.comment}</div>{/if}
              {#if r.status === 'SCHEDULED' || r.status === 'ACTIVE'}<div class="muted small">Both gangs are responsible for being present before the battle begins.</div>{/if}
            </div>
          </div>
        {/each}
      </div>

      {#if recentRivals.length}
        <div class="gt-table">
          <div class="tbl-head">Recent results</div>
          {#each recentRivals as r (r.id)}
            <div class="rv-card">
              <div class="rv-main">
                <div class="rv-vs"><b>{r.attackerLabel}</b> vs <b>{r.defenderLabel}</b> — {r.territoryName}</div>
                <div class="muted small">{r.status}{#if r.winnerLabel} · won by {r.winnerLabel}{/if}{#if r.endedAt} · {when(r.endedAt)}{/if}</div>
              </div>
            </div>
          {/each}
        </div>
      {/if}
    </div>

  {:else if tab === 'xp'}
    <div class="gt-table">
      <div class="tbl-head">Gang XP history{#if xpBalance != null} <span class="muted">· balance {Number(xpBalance).toLocaleString()} XP</span>{/if}</div>
      <TablePager top bind:page={xpPage} bind:pageSize={xpSize} total={xpRows.length} noun="transactions" />
      <table>
        <thead><tr><th>Date</th><th>XP</th><th>Source</th><th>Reason</th><th>Player</th><th>Gang</th><th>Balance</th></tr></thead>
        <tbody>
          {#each pagedXp as r (r.id)}
            <tr>
              <td>{when(r.at)}</td>
              <td class={r.xp_amount >= 0 ? 'pos' : 'neg'}>{r.xp_amount >= 0 ? '+' : ''}{Number(r.xp_amount).toLocaleString()} XP</td>
              <td>{r.source_name || r.source_type}</td>
              <td class="reason">{r.reason || '—'}</td>
              <td>{r.player_name || '—'}</td>
              <td>{r.gang_label || r.gang_name}</td>
              <td>{r.balance_after != null ? Number(r.balance_after).toLocaleString() : '—'}</td>
            </tr>
          {/each}
          {#if !xpRows.length}<tr><td colspan="7" class="muted">No Gang XP recorded yet. Win events (Convoy, Airdrop, Hot Cargo, Rally, TDM, Container Wars) to earn it.</td></tr>{/if}
        </tbody>
      </table>
    </div>

  {:else if tab === 'board'}
    <div class="gt-table">
      <div class="seg"><button type="button" class:active={boardMode === 'gangs'} on:click={() => (boardMode = 'gangs')}>Gangs</button><button type="button" class:active={boardMode === 'players'} on:click={() => (boardMode = 'players')}>Players</button></div>
      {#if board}
        {#if boardMode === 'gangs'}
          <TablePager top bind:page={gbPage} bind:pageSize={gbSize} total={board.gangs.length} noun="gangs" />
          <table>
            <thead><tr><th>Rank</th><th>Gang</th><th>Total XP</th><th>Territory Area (km²)</th><th>Controlled Territories</th></tr></thead>
            <tbody>
              {#each pagedGangBoard as g (g.gang)}
                <tr class:me={me && g.gang === me.name}>
                  <td>#{g.rank}</td><td><span class="gl"><GangLogo logo={g.logo} label={g.label} size={22} accentColor={g.color} /> {g.label}</span></td>
                  <td><b>{Number(g.totalXp).toLocaleString()} XP</b></td>
                  <td><span class="km2-badge">{g.areaKm2 != null && g.areaKm2 > 0 ? Number(g.areaKm2).toFixed(3) : gangKm2(g.gang)} km²</span></td>
                  <td>{g.territories}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        {:else}
          <TablePager top bind:page={pbPage} bind:pageSize={pbSize} total={board.players.length} noun="players" />
          <table>
            <thead><tr><th>Rank</th><th>Player</th><th>Gang</th><th>XP earned</th></tr></thead>
            <tbody>
              {#each pagedPlayerBoard as p (p.player_identifier + p.gang_name)}
                <tr class:me={me && p.gang_name === me.name}><td>#{p.rank}</td><td>{p.player_name || '—'}</td><td>{p.gangLabel}</td><td><b>{Number(p.xp).toLocaleString()}</b></td></tr>
              {/each}
              {#if !board.players.length}<tr><td colspan="4" class="muted">Nobody has earned Gang XP yet.</td></tr>{/if}
            </tbody>
          </table>
        {/if}
      {:else}<div class="muted">Loading…</div>{/if}
    </div>

  {:else if tab === 'history'}
    <div class="gt-table">
      <TablePager top bind:page={hsPage} bind:pageSize={hsSize} total={ownRows.length} noun="changes" />
      <table>
        <thead><tr><th>Date</th><th>Territory</th><th>Previous owner</th><th>New owner</th><th>Reason</th><th>Winner</th><th>Amount</th></tr></thead>
        <tbody>
          {#each pagedHist as h (h.id)}
            <tr><td>{when(h.at)}</td><td>{h.territory_name || h.territory_id}</td><td>{h.previousLabel || '—'}</td><td>{h.newLabel || '—'}</td><td>{reasonText[h.reason] || h.reason}{h.ref_id ? ` #${h.ref_id}` : ''}</td><td>{h.winner_name || '—'}</td><td>{h.amount ? money(h.amount) : '—'}</td></tr>
          {/each}
          {#if !ownRows.length}<tr><td colspan="7" class="muted">No ownership changes recorded yet.</td></tr>{/if}
        </tbody>
      </table>
    </div>
  {/if}
</div>

{#if paintPlan}
  <div class="overlay" on:click|self={() => (paintPlan = null)} role="presentation">
    <div class="modal">
      <div class="m-title">{paintPlan.cost < 0 ? 'Confirm land refund' : 'Confirm territory expansion'}</div>
      <div class="m-sub">{paintPlan.territory.name}</div>
      {#if paintPlan.cells > 0}<div class="kv"><span>New area expanded</span><b>{(paintPlan.cells * 0.000625).toFixed(3)} km² ({paintPlan.cells.toLocaleString()} cells)</b></div>{/if}
      {#if paintPlan.erased > 0}<div class="kv"><span>Painted land erased</span><b>{(paintPlan.erased * 0.000625).toFixed(3)} km² ({paintPlan.erased.toLocaleString()} cells)</b></div>{/if}
      <div class="kv"><span>Expansion rate</span><b>{paintCfg.xpPerCell} XP per cell ({(paintCfg.xpPerCell * 1600).toLocaleString()} XP/km²)</b></div>
      <div class="m-xp">
        <div><span>Gang XP now</span><b>{Number(paintPlan.before).toLocaleString()}</b></div>
        <div><span>{paintPlan.cost < 0 ? 'Refund' : 'Cost'}</span><b class={paintPlan.cost < 0 ? 'pos' : 'neg'}>{paintPlan.cost < 0 ? '+' : '−'}{Number(Math.abs(paintPlan.cost)).toLocaleString()}</b></div>
        <div><span>Gang XP after</span><b>{Number(paintPlan.after).toLocaleString()}</b></div>
      </div>
      <p class="muted small">{paintPlan.cost < 0 ? "The XP for the erased land goes back to your whole gang's balance." : "The XP is taken from your whole gang's balance and the land becomes part of the territory. You can rub it out later to get the XP back."}</p>
      <div class="m-actions">
        <button type="button" class="btn" disabled={busy} on:click={() => (paintPlan = null)}>Cancel</button>
        <button type="button" class="btn btn-primary" disabled={busy} on:click={confirmPaint}>{busy ? 'Saving…' : paintPlan.cost < 0 ? `Take back ${Number(-paintPlan.cost).toLocaleString()} XP` : paintPlan.cost === 0 ? 'Save' : `Spend ${Number(paintPlan.cost).toLocaleString()} XP`}</button>
      </div>
    </div>
  </div>
{/if}

{#if canCreateTerritory && newTerritoryModal}
  <div class="overlay" on:click|self={() => (newTerritoryModal = false)} role="presentation">
    <div class="modal ct-modal" role="dialog" aria-modal="true" aria-label="Create territory">
      <header class="ct-head">
        <span class="ct-icon"><Icon name="plus" size={16} /></span>
        <div class="ct-heads">
          <div class="m-title">Create territory</div>
          <div class="m-sub">Name it, set the auction, place the leader ped and choose its map badge.</div>
        </div>
        <button type="button" class="ct-x" on:click={() => (newTerritoryModal = false)} disabled={creatingTerritory} aria-label="Close"><Icon name="close" size={14} /></button>
      </header>

      <div class="ct-body">
        {#if error}<div class="gt-error">{error}</div>{/if}

        <section class="ct-sec">
          <h4>Territory</h4>
          <div class="field">
            <label for="ct-name">Name</label>
            <input id="ct-name" type="text" placeholder="e.g. Davis, Vinewood Hills, Rancho" bind:value={newTName} />
          </div>
          <div class="ct-grid">
            <div class="field">
              <label for="ct-bid">Starting bid</label>
              <div class="affix"><span>$</span><input id="ct-bid" type="number" min="0" step="5000" bind:value={newTStartingBid} /></div>
            </div>
            <div class="field">
              <label for="ct-inc">Minimum raise</label>
              <div class="affix"><span>$</span><input id="ct-inc" type="number" min="1000" step="1000" bind:value={newTMinIncrement} /></div>
            </div>
            <div class="field">
              <label for="ct-owner">Initial owner</label>
              <select id="ct-owner" bind:value={newTOwner} on:change={onNewOwnerChange}>
                <option value="">Unclaimed (for auction)</option>
                {#each allSortedGangs as g (g.name)}
                  <option value={g.name}>{g.label || g.name}</option>
                {/each}
              </select>
            </div>
            <div class="field">
              <label for="ct-xp">XP value <span class="muted">(reward for holding it)</span></label>
              <div class="affix"><input id="ct-xp" type="number" min="50" max="100000" step="50" bind:value={newTXp} /><span class="end">XP</span></div>
            </div>
          </div>
          <div class="field">
            <label for="ct-color">Territory colour</label>
            <div class="color-row">
              <input id="ct-color" type="color" bind:value={newTColor} />
              <input type="text" class="hex" bind:value={newTColor} aria-label="Colour code" />
            </div>
          </div>
        </section>

        <div class="ct-col">
        <section class="ct-sec">
          <h4>Leader ped</h4>
          <PedRow
            title="Gang leader ped"
            description="Stands in the territory and opens its leader menu. Also used as the map anchor."
            pos={newTPos.x != null ? newTPos : null}
            model={newTPedModel}
            busy={creatingTerritory}
            on:set={onNewPedSet}
            on:clear={clearNewPed}
          />
          <div class="field">
            <label for="ct-ped">Ped model</label>
            <div class="ct-inline">
              <input id="ct-ped" type="text" list="ct-ped-models" placeholder="e.g. g_m_y_mexgoon_01" bind:value={newTPedModel} />
              <datalist id="ct-ped-models">{#each GANG_LEADER_PEDS as m}<option value={m}></option>{/each}</datalist>
              <button type="button" class="btn btn-secondary" on:click={randomizeNewPed} title="Pick a random gang ped"><Icon name="refresh" size={13} /> Randomise</button>
            </div>
          </div>
        </section>

        <section class="ct-sec">
          <h4>Map badge</h4>
          <div class="ct-seg" role="tablist">
            <button type="button" role="tab" aria-selected={newTSpriteType === 'GTA_SPRITE'} class:active={newTSpriteType === 'GTA_SPRITE'} on:click={() => (newTSpriteType = 'GTA_SPRITE')}>GTA blip</button>
            <button type="button" role="tab" aria-selected={newTSpriteType === 'CUSTOM_LOGO'} class:active={newTSpriteType === 'CUSTOM_LOGO'} on:click={() => (newTSpriteType = 'CUSTOM_LOGO')}>Custom logo</button>
          </div>
          {#if newTSpriteType === 'GTA_SPRITE'}
            <div class="field">
              <label for="ct-sprite">Sprite ID</label>
              <div class="ct-inline">
                <input id="ct-sprite" class="narrow" type="number" min="1" max="900" bind:value={newTSprite} placeholder="310" />
                <div class="quick-sprites">
                  {#each [310, 437, 84, 106, 374] as sp}
                    <button type="button" class="sp-pill" class:active={newTSprite === sp} on:click={() => (newTSprite = sp)}>#{sp}</button>
                  {/each}
                </div>
              </div>
            </div>
          {:else}
            <div class="field">
              <label for="ct-logo">Logo image URL</label>
              <div class="ct-inline">
                <input id="ct-logo" type="text" placeholder="https://example.com/logo.png" bind:value={newTCustomLogo} />
                {#if newTCustomLogo}
                  <img src={newTCustomLogo} alt="Logo preview" class="logo-preview" on:error={(e) => { e.currentTarget.style.display = 'none'; }} />
                {/if}
              </div>
            </div>
          {/if}
        </section>
        </div>
      </div>

      <footer class="ct-foot">
        <span class="ct-hint">{newTPos.x == null ? 'No leader ped position yet — you can add it later.' : 'Leader ped placed.'}</span>
        <button type="button" class="btn" on:click={() => (newTerritoryModal = false)} disabled={creatingTerritory}>Cancel</button>
        <button type="button" class="btn btn-primary" on:click={confirmCreateTerritory} disabled={creatingTerritory || !newTName.trim()}>
          <Icon name="check" size={14} />
          <span>{creatingTerritory ? 'Creating…' : 'Create territory'}</span>
        </button>
      </footer>
    </div>
  </div>
{/if}

{#if answerFor}
  <div class="ans-overlay" role="presentation" on:click|self={() => (answerFor = null)}>
    <div class="ans-box" role="dialog" aria-label={answerAccept ? 'Accept the challenge' : 'Decline the challenge'}>
      <div class="ans-title">{answerAccept ? 'Accept the challenge' : 'Decline the challenge'}</div>
      <div class="ans-sub"><b>{answerFor.attackerLabel}</b> vs <b>{answerFor.defenderLabel}</b> — {answerFor.territoryName}</div>
      <label for="ans-comment">Comment for the admins <span class="muted">(optional)</span></label>
      <textarea id="ans-comment" rows="4" maxlength="300" bind:value={answerComment} placeholder={answerAccept ? 'For example: we can all be there on Saturday evening, not before 8 pm.' : 'Why are you declining?'}></textarea>
      <div class="ans-count muted small">{answerComment.length} / 300. The admins read this under the challenge and use it to set the war.</div>
      {#if error}<div class="gt-error" style="position: static;">{error}</div>{/if}
      <div class="btn-pair">
        <button type="button" class="btn" on:click={() => (answerFor = null)}>Back</button>
        <button type="button" class="btn {answerAccept ? 'btn-primary' : 'btn-danger'}" disabled={busy} on:click={answer}>{answerAccept ? 'Accept challenge' : 'Decline challenge'}</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .tab-n { font-style: normal; margin-left: 6px; min-width: 18px; height: 18px; padding: 0 5px; display: inline-grid; place-items: center; border-radius: 9px; background: var(--c-action); color: var(--on-accent); font-size: var(--fs-meta); font-weight: 700; }
  .gt-tab.active .tab-n { background: var(--on-accent); color: var(--c-action); }
  .rv-tab { display: flex; flex-direction: column; gap: 14px; }
  .rv-empty { padding: 18px 16px; color: var(--text-muted, #aeb5bd); font-size: var(--fs-small); }
  .rv-card { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 12px 16px; border-top: 1px solid var(--es-line-soft, #1f2328); }
  .rv-main { min-width: 0; display: flex; flex-direction: column; gap: 5px; }
  .rv-vs { font-size: var(--fs-body); }
  .rv-card .btn-pair { flex: none; margin-top: 0; }
  .rv-comment { margin-top: 2px; padding: 7px 10px; background: var(--es-inset, #111316); border: 1px solid var(--es-line, #2a2e35); border-left: 3px solid var(--c-action); border-radius: var(--r-ctl); font-size: var(--fs-small); }
  .rv-comment span { display: block; color: var(--text-muted, #aeb5bd); font-size: var(--fs-meta); font-weight: 700; margin-bottom: 2px; }
  .ans-overlay { position: fixed; inset: 0; z-index: 6000; display: flex; align-items: center; justify-content: center; background: var(--scrim, rgba(0, 0, 0, 0.62)); }
  .ans-box { width: 480px; max-width: 92vw; display: flex; flex-direction: column; gap: 8px; padding: 20px 22px; background: var(--surface-dialog, var(--es-solid)); border: 1px solid var(--border-dialog, var(--es-line)); border-radius: var(--r-panel); }
  .ans-title { font-size: var(--fs-title); font-weight: 700; }
  .ans-sub { color: var(--text-muted, #aeb5bd); font-size: var(--fs-body); margin-bottom: 4px; }
  .ans-box label { font-weight: 700; font-size: var(--fs-small); }
  .ans-box textarea { width: 100%; resize: vertical; min-height: 84px; }
  .ans-box .btn-pair { margin-top: 6px; }
  /* Create Territory: the page's one main action, in the accent colour of the chosen theme (flat, no glow) */
  .create-btn { display: inline-flex; align-items: center; gap: 9px; height: 38px; margin-left: 10px; padding: 0 16px 0 7px; border-radius: var(--r-ctl);
    background: var(--accent-primary); border: 1px solid var(--accent-primary-light, var(--accent-primary)); color: var(--on-accent, #ffffff);
    font-family: var(--font-ui); font-size: var(--fs-body); font-weight: 700; letter-spacing: 0.01em; white-space: nowrap; cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, transform 0.1s ease; }
  .create-btn:hover { background: var(--accent-primary-light, var(--accent-primary)); }
  .create-btn:active { transform: translateY(1px); }
  .create-btn:focus-visible { outline: 2px solid var(--accent-primary-light, var(--accent-primary)); outline-offset: 2px; }
  .create-plus { display: grid; place-items: center; width: 26px; height: 26px; border-radius: 7px; background: color-mix(in srgb, currentColor 16%, transparent); border: 1px solid color-mix(in srgb, currentColor 30%, transparent); }
  .tool.primary { background: var(--c-hover); border-color: var(--accent-primary); color: var(--lt-7bb6f2, #7bb6f2); }
  .tool.primary:hover:not(:disabled) { background: var(--es-accent, #4f94e6); color: var(--on-es-accent, #ffffff);
    text-shadow: none; }
  .modal .field { margin-bottom: 12px; display: flex; flex-direction: column; gap: 4px; }
  .modal .field label { font-size: var(--fs-meta); font-weight: 700; color: var(--lt-aeb5bd, #aeb5bd); }
  .modal .field input, .modal .field select { height: 36px; background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); font-size: var(--fs-small); padding: 0 10px; }
  .modal .field input:focus, .modal .field select:focus { border-color: var(--accent-primary); outline: none; }
  .modal .color-row { display: flex; align-items: center; gap: 10px; }
  .modal .color-row input[type="color"] { width: 44px; height: 36px; padding: 2px; cursor: pointer; border-radius: var(--r-ctl); }
  .gt { display: flex; flex-direction: column; gap: 12px; min-height: 0; }
  .gt-top { display: flex; gap: 14px; flex-wrap: wrap; align-items: center; justify-content: space-between; }
  .xp-card { display: flex; align-items: center; gap: 14px; background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-panel); box-shadow: var(--es-edge, none); padding: 10px 16px; flex-wrap: wrap; }
  .xp-gang { font-weight: 700; font-size: var(--fs-emph); }
  .xp-sub { color: var(--text-muted, #aeb5bd); font-size: var(--fs-meta); }
  .xp-balance { display: flex; align-items: baseline; gap: 8px; margin-left: 12px; padding-left: 16px; border-left: 1px solid var(--es-line, #2a2e35); }
  .xp-label { font-size: var(--fs-meta); letter-spacing: 0.01em; color: var(--text-muted, #aeb5bd); font-weight: 700; }
  .xp-value { font-size: var(--fs-section); font-weight: 700; color: var(--lt-ffc857, #ffc857); font-variant-numeric: tabular-nums;
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .xp-balance.preview .xp-value { color: #8d949c; text-decoration: line-through; font-size: var(--fs-title); }
  .xp-arrow { color: #8d949c; }
  .xp-after { font-size: var(--fs-section); font-weight: 700; color: var(--lt-46c98b, #46c98b);
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .xp-after.bad { color: #ff5d50; }
  .xp-cost { font-size: var(--fs-small); color: var(--lt-ff8a80, #ff8a80); font-weight: 700; }
  /* the sections of the Map Zone: big cards, each with an icon, a name and one line about what it is for */
  .gt-tabs { flex: 1 1 100%; width: 100%; display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 10px; }
  .gt-tab { position: relative; display: flex; align-items: center; gap: 12px; padding: 12px 14px; text-align: left; border-radius: var(--r-panel); background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); color: var(--text-main); }
  .gt-tab:hover { background: var(--c-hover); }
  .gt-tab-ico { flex: none; width: 42px; height: 42px; display: grid; place-items: center; border-radius: var(--r-ctl); background: var(--btn-soft, var(--c-raised)); border: 1px solid var(--btn-soft-line, var(--c-line)); }
  .gt-tab-txt { min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .gt-tab-txt b { font-size: var(--fs-emph); font-weight: 700; display: flex; align-items: center; gap: 8px; }
  .gt-tab-txt span { font-size: var(--fs-meta); line-height: 1.35; color: var(--text-dim); font-weight: 500; }
  .gt-tab.active { background: var(--c-action); border-color: var(--c-action); color: var(--on-accent); }
  .gt-tab.active .gt-tab-ico { background: rgba(0, 0, 0, 0.14); border-color: transparent; }
  .gt-tab.active .gt-tab-txt span { color: var(--on-accent); opacity: 0.8; }
  .gt-error { position: sticky; top: 0; z-index: 40; padding: 10px 14px; border: 1px solid #ff5d50; background: var(--es-solid, #2a1414); color: var(--lt-ffb4ad, #ffb4ad); border-radius: var(--r-ctl); font-size: var(--fs-body); font-weight: 600; }
  .gt-notice { position: sticky; top: 0; z-index: 40; padding: 10px 14px; border: 1px solid #46c98b; background: var(--es-solid, #10261c); color: var(--lt-7ee2b2, #7ee2b2); border-radius: var(--r-ctl); font-size: var(--fs-body); font-weight: 600; }
  .gt-main { display: block; min-height: 0; }
  .gt-map { position: relative; min-width: 0; }
  .gt-loading { position: absolute; z-index: 20; top: 12px; left: 12px; background: var(--es-solid, var(--c-panel, #181b1f)); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); padding: 6px 12px; font-size: var(--fs-small); }
  .gt-legend { display: flex; gap: 18px; flex-wrap: wrap; margin-top: 8px; font-size: var(--fs-meta); color: var(--text-muted, #aeb5bd); }
  .gt-legend i { display: inline-block; width: 11px; height: 11px; border-radius: 3px; margin-right: 6px; vertical-align: -1px; }
  .gt-legend i.ghost { background: rgba(var(--ink-rgb, 255, 255, 255), 0.12); border: 1px dashed #aeb5bd; }
  /* the map fills the whole section and grows with the window; the details float over it and can be hidden */
  .map-stage { position: relative; height: clamp(560px, calc(94vh - 400px), 940px); }
  .side-toggle { position: absolute; z-index: 1101; top: 12px; right: 12px; display: inline-flex; align-items: center; gap: 7px; height: 34px; padding: 0 13px; border-radius: var(--r-ctl); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.3)); background: var(--glass-bar, rgba(var(--ltc-10-12-16, 10, 12, 16), 0.9)); color: var(--text-main, #fff); font-size: var(--fs-small); font-weight: 600; cursor: pointer; }
  .side-toggle.on, .side-toggle:hover { border-color: var(--accent-primary); }
  .side-toggle em { font-style: normal; min-width: 18px; height: 18px; padding: 0 5px; display: inline-grid; place-items: center; border-radius: 9px; background: var(--accent-primary); color: var(--on-accent, #fff); font-size: var(--fs-meta); font-weight: 700; }
  .gt-side { position: absolute; z-index: 1100; top: 54px; right: 12px; bottom: 12px; width: min(340px, 44%); display: flex; flex-direction: column; gap: 10px; overflow-y: auto; padding: 10px; background: var(--glass-bar, rgba(var(--ltc-10-12-16, 10, 12, 16), 0.9)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.28)); border-radius: var(--r-panel); }
  .card { background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-panel); box-shadow: var(--es-edge, none); padding: 14px 16px; }
  .card.challenge { border-color: #c45ee0; }
  .card.rival { border-color: #ffc857; }
  .card.auction { border-color: var(--accent-primary); }
  .card-title { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: var(--fs-body); letter-spacing: 0.02em; margin-bottom: 8px; }
  .sub-title { margin: 12px 0 6px; font-weight: 700; font-size: var(--fs-meta); letter-spacing: 0.01em; color: var(--lt-aeb5bd, #aeb5bd); }
  .dot { width: 11px; height: 11px; border-radius: 50%; flex-shrink: 0; display: inline-block; }
  .kv { display: flex; justify-content: space-between; gap: 10px; padding: 4px 0; font-size: var(--fs-small); }
  .kv span { color: var(--text-muted, #aeb5bd); }
  .desc { font-size: var(--fs-small); color: var(--lt-c9ced4, #c9ced4); margin: 6px 0; line-height: 1.5; }
  .muted { color: var(--text-muted, #aeb5bd); font-size: var(--fs-small); }
  .small { font-size: var(--fs-meta); margin-top: 6px; }
  .war-flag { margin: 6px 0; padding: 6px 10px; background: var(--c-raised); border: 1px solid var(--c-line); border-radius: var(--r-tag); font-size: var(--fs-small); color: var(--lt-ff8a80, #ff8a80);
    border-left: 3px solid rgb(255, 93, 80);}
  .exp-row { display: flex; justify-content: space-between; align-items: center; width: 100%; text-align: left; padding: 8px 10px; margin: 4px 0; border-radius: var(--r-ctl); border: 1px solid var(--es-line, #2a2e35); background: var(--es-inset, #15171b); color: var(--lt-c9ced4, #c9ced4); font-size: var(--fs-small); }
  .exp-row:hover:not(:disabled) { border-color: var(--es-line-strong, #434951); }
  .exp-row.unlocked { opacity: 0.55; }
  .exp-row.next { border-color: var(--es-line-strong, #5a5d73); }
  .exp-row.picked { border-color: var(--accent-primary); background: var(--c-hover); }
  .exp-row:disabled { cursor: default; }
  .exp-cost { font-weight: 700; color: var(--lt-ffc857, #ffc857); }
  .cost-box { margin: 8px 0; padding: 9px 12px; background: var(--es-inset, #15171b); border: 1px solid var(--accent-primary); border-radius: var(--r-ctl); font-size: var(--fs-small); line-height: 1.6; }
  .cost-box.bad { border-color: #ff5d50; }
  .insuff { margin: 8px 0; padding: 9px 12px; background: rgba(255, 93, 80, 0.1); border: 1px solid #ff5d50; border-radius: var(--r-ctl); font-size: var(--fs-small); color: var(--lt-ff8a80, #ff8a80); }
  .full { width: 100%; justify-content: center; margin-top: 4px; }
  .btn-pair { display: flex; gap: 8px; margin-top: 8px; }
  .btn-pair .btn { flex: 1; justify-content: center; }
  .riv { padding: 7px 0; border-top: 1px solid var(--es-line-soft, #1f2328); font-size: var(--fs-small); }
  .riv:first-of-type { border-top: 0; }
  .t-row { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; padding: 7px 8px; border-radius: var(--r-ctl); border: 1px solid transparent; color: var(--lt-c9ced4, #c9ced4); font-size: var(--fs-small); }
  .t-row:hover { background: var(--es-raised, #1c1f24); }
  .t-row.active { border-color: rgba(160, 208, 255, 0.55); background: var(--c-hover); }
  .t-owner { margin-left: auto; color: var(--text-muted, #aeb5bd); font-size: var(--fs-meta); }
  .war-pill { background: #ff5d50; color: var(--lt-ffffff, #fff); font-size: var(--fs-meta); font-weight: 600; padding: 1px 6px; border-radius: var(--r-tag); }
  .gt-table { background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-panel); box-shadow: var(--es-edge, none); padding: 12px 14px; overflow-x: auto; }
  .gt-table :global(.tp) { margin-bottom: 10px; border-radius: var(--r-ctl); border: 1px solid var(--es-line, #2a2e35); }
  .tbl-head { font-weight: 700; margin-bottom: 8px; }
  .seg { display: inline-flex; border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); overflow: hidden; margin-bottom: 10px; }
  .seg button { padding: 7px 16px; background: var(--es-inset, #15171b); color: var(--lt-aeb5bd, #aeb5bd); font-weight: 600; font-size: var(--fs-small); }
  .seg button.active { background: var(--c-action); color: var(--on-accent); }
  table { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  th { text-align: left; padding: var(--tbl-th-y) var(--tbl-x); color: var(--text-muted); font-weight: 600; border-bottom: 1px solid var(--c-line); white-space: nowrap;
    font-size: var(--fs-meta);
    letter-spacing: 0;
  }
  td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft);
    font-variant-numeric: tabular-nums;
  }
  td.pos { color: var(--lt-46c98b, #46c98b); font-weight: 500;
    font-variant-numeric: tabular-nums;
  } td.neg { color: #ff6a6a; font-weight: 500;
    font-variant-numeric: tabular-nums;
  }
  td.reason { max-width: 340px; color: var(--lt-aeb5bd, #aeb5bd);
    font-variant-numeric: tabular-nums;
  }
  tr.me td { background: var(--c-hover);
    font-variant-numeric: tabular-nums;
  }
  .gl { display: inline-flex; align-items: center; gap: 8px; }
  .overlay { position: fixed; inset: 0; z-index: 6000; background: var(--scrim, rgba(0, 0, 0, 0.66)); display: flex; align-items: center; justify-content: center; }
  .modal { width: 460px; max-width: 94vw; background: var(--surface-dialog); border: 1px solid var(--border-dialog); border-radius: var(--r-panel); padding: 22px 24px; }
  .modal.lg { width: 560px; max-height: 88vh; overflow-y: auto; }
  .modal-grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .m-section-hdr { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--accent-primary); margin: 12px 0 6px; display: flex; align-items: center; gap: 6px; }
  .coords-row { display: grid; grid-template-columns: repeat(4, 1fr) auto; gap: 8px; align-items: flex-end; margin-bottom: 12px; }
  .coords-row .field { margin-bottom: 0; }
  .btn-pos { height: 36px; padding: 0 12px; white-space: nowrap; }
  .ped-model-row { display: flex; gap: 8px; }
  .ped-model-row input { flex: 1; }
  .ped-model-row button { height: 36px; padding: 0 12px; white-space: nowrap; }
  .sprite-input-row { display: flex; gap: 10px; align-items: center; }
  .sprite-input-row input { width: 140px; }
  .quick-sprites { display: flex; gap: 4px; flex-wrap: wrap; }
  .sp-pill { background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); padding: 5px 9px; border-radius: var(--r-tag); color: var(--lt-aeb5bd, #aeb5bd); font-size: var(--fs-meta); font-weight: 600; cursor: pointer; }
  .sp-pill.active { border-color: var(--accent-primary); background: var(--c-action); color: var(--on-accent); }
  .logo-input-row { display: flex; gap: 8px; align-items: center; }
  .logo-input-row input { flex: 1; }
  .logo-preview { width: 36px; height: 36px; object-fit: contain; border-radius: var(--r-ctl); background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); }
  .km2-badge { display: inline-block; background: var(--c-action); border: 1px solid var(--c-action); border-radius: var(--r-tag); padding: 2px 8px; font-weight: 600; color: var(--on-accent); font-variant-numeric: tabular-nums; }
  .m-title { font-size: var(--fs-title); font-weight: 700;
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .m-sub { color: var(--text-muted, #aeb5bd); margin: 2px 0 12px; }
  .m-xp { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin: 14px 0 6px; }
  .m-xp div { background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); padding: 8px 10px; display: flex; flex-direction: column; font-size: var(--fs-meta); color: var(--text-muted, #aeb5bd); }
  .m-xp b { font-size: var(--fs-title); color: var(--lt-ffffff, #fff); margin-top: 2px; }
  .m-xp b.neg { color: var(--lt-ff8a80, #ff8a80); }
  .m-xp b.pos { color: var(--lt-7ee2b2, #7ee2b2); }
  .m-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 14px; }
  @media (max-width: 1150px) { .gt-side { width: min(320px, 60%); } }

  /* "Your zone" summary above the map */
  .zone-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 12px; }
  .zs { background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-panel); box-shadow: var(--es-edge, none); padding: 12px 16px; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .zs span { font-size: var(--fs-small); font-weight: 600; letter-spacing: 0; color: var(--text-muted, #b4c6dc); }
  .zs b { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-section); font-weight: 700; color: var(--lt-ffffff, #fff); font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .zs.xp b { color: var(--lt-ffd77a, #ffd77a); }
  .zone-list { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 12px; }
  .zl-title { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-959ca5, #959ca5); margin-right: 4px; }
  .zl-chip { display: flex; flex-direction: column; gap: 2px; text-align: left; padding: 8px 12px; background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-tag); color: var(--lt-ffffff, #fff); cursor: pointer; }
  .zl-chip:hover { border-color: var(--es-line-strong, #3a3c4d); }
  .zl-chip.active { border-color: var(--accent-primary); }
  .zl-name { font-weight: 700; font-size: var(--fs-body); }
  .zl-meta { font-size: var(--fs-meta); color: var(--lt-aeb5bd, #aeb5bd); }
  .map-tools { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-bottom: 8px; padding: 9px 12px; background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-panel); }
  .map-tools.editing { border-color: var(--accent-primary); }
  .map-tools.overview { flex-wrap: nowrap; align-items: flex-start; padding: 8px 12px; gap: 10px; background: var(--c-base, var(--es-inset, #15171b)); }
  .live-dot { width: 8px; height: 8px; margin-top: 7px; border-radius: 50%; flex-shrink: 0; background: #46c98b; }
  .tool-group { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
  .tool-group.right { margin-left: auto; }
  .tool-group label { font-size: var(--fs-meta); color: var(--lt-aeb5bd, #aeb5bd); letter-spacing: 0.01em; }
  .tool-group input[type='range'] { width: 150px; accent-color: var(--accent-primary); }
  .brush-val { min-width: 48px; font-family: var(--font-mono); font-weight: 700; color: var(--lt-ffffff, #fff); font-size: var(--fs-small); }
  .tool { display: inline-flex; align-items: center; gap: 6px; background: var(--es-raised, #1f2328); border: 1px solid var(--es-line, #2a2e35); color: var(--lt-c9ced4, #c9ced4); border-radius: var(--r-ctl); padding: 0 12px; height: 34px; font-weight: 600; font-size: var(--fs-small); cursor: pointer; }
  .tool:hover:not(:disabled) { background: var(--es-card-hover, #272b31); }
  .tool.active { border-color: rgba(160, 208, 255, 0.6); background: var(--c-action); color: var(--on-accent); }
  .tool.save { background: var(--es-accent, #4f94e6); border-color: var(--accent-primary); color: var(--on-es-accent, #ffffff);
    text-shadow: none; }
  .tool.save:hover:not(:disabled) { background: var(--es-accent-hover, #66a3eb); }
  .tool.danger:hover:not(:disabled) { border-color: #ff5d50; color: #ff5d50; }
  .tool:disabled { opacity: 0.4; cursor: not-allowed; }
  .tool-hint { flex: 1 1 260px; min-width: 0; font-size: var(--fs-small); color: var(--lt-aeb5bd, #aeb5bd); }
  .tool-hint b { color: var(--lt-ffffff, #fff); }
  .edit-info { display: flex; flex-wrap: wrap; gap: 6px 16px; align-items: center; margin-bottom: 8px; padding: 8px 12px; background: var(--c-hover); border: 1px solid var(--accent-primary); border-radius: var(--r-ctl); font-size: var(--fs-small); color: var(--lt-c9ced4, #c9ced4); }
  .edit-info.bad { background: var(--c-raised); border-color: var(--c-line);
    border-left: 3px solid rgb(229, 72, 77);}
  .ei-num { font-weight: 700; color: var(--lt-ffffff, #fff); font-variant-numeric: tabular-nums; }
  .ei-num small { font-weight: 500; color: var(--lt-959ca5, #959ca5); }
  .ei-warn { flex-basis: 100%; color: var(--lt-ff8a8d, #ff8a8d); font-weight: 700; }
  .gt-filter { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-bottom: 10px; }
  .gf-search { display: flex; align-items: center; gap: 9px; height: 36px; flex: 1; min-width: 240px; max-width: 420px; padding: 0 12px; background: var(--es-inset, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-aeb5bd, #aeb5bd); }
  .gf-search:focus-within { border-color: var(--accent-primary); }
  .gf-search input { flex: 1; min-width: 0; background: transparent; border: none; outline: none; color: var(--lt-ffffff, #fff); font-size: var(--fs-body); }
  .gf-clear { display: flex; background: transparent; border: none; color: var(--lt-aeb5bd, #aeb5bd); cursor: pointer; }
  .gf-select { display: flex; align-items: center; gap: 8px; font-size: var(--fs-small); font-weight: 700; color: var(--lt-aeb5bd, #aeb5bd); }
  .gf-select select { height: 36px; min-width: 190px; padding: 0 10px; background: var(--es-inset, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); color: var(--lt-ffffff, #fff); font-size: var(--fs-body); font-weight: 600; cursor: pointer; outline: none; }
  .gf-reset { height: 36px; padding: 0 14px; background: var(--c-raised); border: 1px solid var(--c-line); border-radius: var(--r-ctl); color: var(--lt-ff8a8d, #ff8a8d); font-weight: 700; font-size: var(--fs-small); cursor: pointer;
    border-left: 3px solid rgb(229, 72, 77);}
  .gf-count { margin-left: auto; font-size: var(--fs-small); color: var(--lt-959ca5, #959ca5); }
  .linkish { background: none; border: none; color: var(--accent-primary-light); cursor: pointer; padding: 0; text-decoration: underline; }

  /* ── Expansion planner: the territory, its cost and the Save button in one card ───────────────────────── */
  .planner { display: flex; flex-direction: column; margin-bottom: 10px; background: var(--c-panel, var(--es-inset, #15171b)); border: 1px solid var(--tablet-border-strong, var(--es-line, #2a2e35)); border-radius: var(--r-panel); overflow: hidden; }
  .planner.bad { border-color: rgba(255, 93, 80, 0.55); }
  .pl-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 10px 14px; }
  .pl-who { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .pl-swatch { width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0; border: 2px solid rgba(var(--ink-rgb, 255, 255, 255), 0.45); }
  .pl-titles { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .pl-kicker { font-size: var(--fs-meta); font-weight: 600; color: var(--text-muted, #aeb5bd); }
  .pl-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; line-height: 1.15; color: var(--lt-ffffff, #fff); }
  .pl-title .pl-verb { color: var(--text-muted, #aeb5bd); font-weight: 500; }
  .pl-rate { display: inline-flex; align-items: center; gap: 6px; padding: 3px 9px; border-radius: var(--r-tag); font-size: var(--fs-meta); font-weight: 600; color: var(--lt-fbbf24, #fbbf24); background: var(--c-raised); border: 1px solid var(--c-line); white-space: nowrap; font-variant-numeric: tabular-nums;
    border-left: 3px solid rgb(245, 158, 11);}
  .pl-rate small { color: var(--lt-d9a441, #d9a441); font-weight: 600; }
  .pl-actions { display: flex; align-items: center; gap: 8px; margin-left: auto; }
  .pl-actions .tool { height: 36px; }
  .pl-actions .tool.save { padding: 0 16px; }
  .pl-metrics { display: grid; grid-template-columns: 1fr 1fr 1.5fr; border-top: 1px solid var(--c-line, var(--es-line, #2a2e35)); }
  .pl-metrics.three { grid-template-columns: repeat(3, 1fr); }
  .pl-metrics.four { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .planner { background: var(--glass-panel, var(--c-panel, var(--es-inset, #15171b))); }
  .pl-status { margin: 0 12px 12px; border: 1px solid var(--c-line, var(--es-line, #2a2e35)); border-left-width: 3px; border-radius: var(--r-ctl); }
  .pl-head { padding: 12px 16px; }
  .pl-m { padding: 12px 16px; }
  .pl-val { font-size: var(--fs-section); }
  .pl-m { display: flex; flex-direction: column; gap: 2px; min-width: 0; padding: 10px 16px; }
  .pl-m + .pl-m { border-left: 1px solid var(--c-line, var(--es-line, #2a2e35)); }
  .pl-lbl { font-size: var(--fs-meta); font-weight: 600; color: var(--text-muted, #aeb5bd); }
  .pl-val { white-space: nowrap; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-section); font-weight: 600; line-height: 1.1; font-variant-numeric: tabular-nums; color: var(--lt-ffffff, #fff); }
  .pl-val small { margin-left: 3px; font-family: var(--font-ui); font-size: var(--fs-meta); font-weight: 600; opacity: 0.85; }
  .pl-val.area { color: var(--lt-7bb6f2, #7bb6f2); }
  .pl-val.cost { color: var(--lt-fbbf24, #fbbf24); }
  .pl-val.ok { color: var(--lt-34d399, #34d399); }
  .pl-val.bad { color: #f87171; }
  .pl-sub { font-size: var(--fs-meta); font-weight: 500; color: var(--c-text-3, #959ca5); }
  .pl-flow { display: flex; align-items: baseline; flex-wrap: wrap; gap: 8px; }
  .pl-flow .cur { font-size: var(--fs-body); font-weight: 600; color: var(--c-text-2, #c9ced4); font-variant-numeric: tabular-nums; }
  .pl-flow .arr { color: var(--c-text-3, #7c848d); }
  .pl-gauge { height: 5px; margin-top: 5px; border-radius: 3px; background: rgba(var(--ink-rgb, 255, 255, 255), 0.08); overflow: hidden; }
  .pl-gauge i { display: block; height: 100%; border-radius: 3px; background: var(--es-accent, #4f94e6); transition: width 0.2s ease;
    color: var(--on-es-accent, inherit);
}
  .pl-gauge i.danger { background: #ff5d50; }
  .pl-status { display: flex; align-items: center; gap: 10px; padding: 9px 14px; border-top: 1px solid var(--c-line, var(--es-line, #2a2e35)); border-left: 3px solid var(--st, #38bdf8); font-size: var(--fs-small); line-height: 1.4; color: var(--c-text-2, #c9ced4); }
  .pl-status b { color: var(--lt-ffffff, #fff); }
  .pl-status :global(svg) { flex-shrink: 0; color: var(--st, #38bdf8); }
  .pl-status.info { --st: #38bdf8; }
  .pl-status.success { --st: #10b981; }
  .pl-status.warning { --st: #f59e0b; }
  .pl-status.danger { --st: #ff5d50; background: rgba(255, 93, 80, 0.08); }
  @media (max-width: 900px) { .pl-metrics, .pl-metrics.three, .pl-metrics.four { grid-template-columns: 1fr; } .pl-m + .pl-m { border-left: none; border-top: 1px solid var(--c-line, var(--es-line, #2a2e35)); } }

  /* ── Create territory dialog: fixed header + footer, three sections, nothing wider than the box ─────────── */
  .modal.ct-modal { width: 1040px; max-width: 94vw; max-height: 90vh; padding: 0; display: flex; flex-direction: column; overflow: hidden; }
  .ct-head { display: flex; align-items: flex-start; gap: 12px; padding: 18px 26px 14px; border-bottom: 1px solid var(--border-dialog, var(--es-line, #2a2e35)); background: var(--surface-dialog-bar, transparent); }
  .ct-icon { width: 34px; height: 34px; flex-shrink: 0; display: grid; place-items: center; border-radius: var(--r-tag); color: var(--lt-7bb6f2, #7bb6f2); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .ct-heads { flex: 1; min-width: 0; }
  .ct-heads .m-sub { margin: 2px 0 0; }
  .ct-x { width: 32px; height: 32px; flex-shrink: 0; display: grid; place-items: center; border-radius: var(--r-ctl); color: var(--c-text-2, #c9ced4); background: transparent; border: 1px solid var(--c-line, var(--es-line, #2a2e35)); cursor: pointer; }
  .ct-x:hover:not(:disabled) { color: var(--lt-ffffff, #fff); border-color: var(--accent-primary); }
  .ct-body { flex: 1; min-height: 0; overflow-y: auto; overflow-x: hidden; padding: 16px 26px 10px; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 18px 32px; align-items: start; }
  .ct-body > .gt-error { grid-column: 1 / -1; }
  .ct-col { display: flex; flex-direction: column; gap: 18px; min-width: 0; }
  @media (max-width: 900px) { .ct-body { grid-template-columns: 1fr; } }
  .ct-sec { display: flex; flex-direction: column; gap: 10px; }
  .ct-sec h4 { margin: 0; padding-bottom: 6px; border-bottom: 1px solid var(--c-line, var(--es-line, #2a2e35)); font-size: var(--fs-small); font-weight: 700; color: var(--lt-7bb6f2, #7bb6f2); }
  .ct-modal .field { margin: 0; min-width: 0; }
  .ct-modal .field input, .ct-modal .field select { width: 100%; min-width: 0; box-sizing: border-box; }
  .ct-modal .field input.narrow { width: 110px; flex: none; }
  .ct-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .affix { display: flex; align-items: center; height: 36px; background: var(--c-base, var(--es-inset, #15171b)); border: 1px solid var(--c-line, var(--es-line, #2a2e35)); border-radius: var(--r-ctl); overflow: hidden; }
  .affix:focus-within { border-color: var(--accent-primary); }
  .affix span { padding: 0 10px; color: var(--c-text-3, #959ca5); font-weight: 600; font-size: var(--fs-small); }
  .affix span.end { padding: 0 12px; border-left: 1px solid var(--c-line, var(--es-line, #2a2e35)); }
  .ct-modal .field .affix input { height: 34px; border: none; background: transparent; padding: 0 8px 0 0; }
  .ct-modal .field .affix span + input { padding-left: 0; }
  .ct-modal .field .affix input:first-child { padding-left: 10px; }
  .ct-modal .color-row input.hex { width: 140px; flex: none; font-family: var(--font-mono); }
  .ct-inline { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .ct-inline > input { flex: 1; min-width: 0; }
  .ct-inline .btn { height: 36px; padding: 0 12px; white-space: nowrap; flex: none; }
  .ct-seg { display: grid; grid-template-columns: 1fr 1fr; padding: 3px; gap: 3px; background: var(--c-base, var(--es-inset, #15171b)); border: 1px solid var(--c-line, var(--es-line, #2a2e35)); border-radius: var(--r-ctl); }
  .ct-seg button { height: 32px; border-radius: 6px; background: transparent; color: var(--c-text-2, #aeb5bd); font-weight: 600; font-size: var(--fs-small); cursor: pointer; border: none; }
  .ct-seg button.active { background: var(--c-action); color: var(--on-accent); }
  .ct-foot { display: flex; align-items: center; justify-content: flex-end; gap: 10px; padding: 12px 26px; border-top: 1px solid var(--border-dialog, var(--es-line, #2a2e35)); background: var(--surface-dialog-bar, transparent); }
  .ct-hint { margin-right: auto; font-size: var(--fs-meta); color: var(--c-text-3, #959ca5); }
  .ct-modal :global(.ped-row) { margin-bottom: 0; }

  /* ── Create territory, roomy and in the tablet's own look ─────────────────────────────────────────────────
     The dialog wears the same layered background as the tablet frame (the chosen Appearance theme: veil, gradient, picture); the header
     and footer are glass bars, each section is a glass card, fields are tall and spaced, the one main button is the accent colour. */
  .modal.ct-modal {
    width: min(1320px, 96vw); max-height: 93vh;
    background-color: var(--lt-07090d, #07090d);
    background-image:
      var(--frame-shade-img, linear-gradient(var(--frame-shade, transparent), var(--frame-shade, transparent)));
    background-size: cover; background-position: center;
    border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.3)); border-radius: var(--r-frame, 16px);
    box-shadow: 0 30px 80px rgba(0, 0, 0, 0.7);
  }
  .ct-head { align-items: center; gap: 16px; padding: 22px 32px; background: var(--glass-bar, rgba(var(--ltc-14-19-27, 14, 19, 27), 0.92)); border-bottom: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.26)); }
  .ct-icon { width: 46px; height: 46px; border-radius: 12px; color: var(--accent-primary-light, #7bb6f2); }
  .ct-heads .m-title { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-section); font-weight: 600; line-height: 1.1; }
  .ct-heads .m-sub { margin-top: 4px; font-size: var(--fs-body); color: var(--text-muted, #8d949c); }
  .ct-x { width: 38px; height: 38px; }
  .ct-body { padding: 26px 32px 30px; gap: 24px 28px; grid-template-columns: minmax(0, 1fr) minmax(0, 1.1fr); }
  .ct-col { gap: 24px; }
  .ct-sec { gap: 20px; padding: 24px 26px 28px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); border-radius: var(--r-panel, 12px); }
  .ct-sec h4 { padding-bottom: 14px; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; color: var(--text-main, #fff); border-bottom: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.18)); }
  .ct-sec h4::before { content: ''; display: inline-block; width: 4px; height: 16px; margin-right: 10px; vertical-align: -2px; border-radius: 2px; background: var(--accent-primary); }
  .ct-modal .field { display: flex; flex-direction: column; gap: 9px; }
  .ct-modal .field label { font-size: var(--fs-body); font-weight: 600; color: var(--text-dim, #c9ced4); }
  .ct-modal .field input, .ct-modal .field select { min-height: 48px; padding: 0 16px; font-size: var(--fs-emph); border-radius: var(--r-ctl, 8px); }
  .ct-modal .field input[type='color'] { width: 56px; min-height: 48px; padding: 4px; flex: none; }
  .ct-modal .color-row { display: flex; align-items: center; gap: 12px; }
  .ct-modal .color-row input.hex { width: 190px; }
  .ct-modal .field input.narrow { width: 130px; }
  .ct-grid { gap: 22px 22px; }
  .affix { height: 48px; background: var(--input-bg, var(--c-base, #15171b)); border-color: var(--input-border, var(--c-line, #2a2e35)); }
  .affix span { padding: 0 14px; font-size: var(--fs-body); }
  .ct-modal .field .affix input { height: 46px; min-height: 0; padding: 0 12px 0 0; }
  .ct-modal .field .affix input:first-child { padding-left: 14px; }
  .ct-inline { gap: 12px; }
  .ct-inline .btn { height: 48px; padding: 0 18px; font-size: var(--fs-body); }
  .ct-seg { padding: 4px; gap: 4px; background: var(--glass-head, var(--c-base, #15171b)); border-color: var(--tablet-border, var(--c-line, #2a2e35)); }
  .ct-seg button { height: 42px; font-size: var(--fs-body); }
  .ct-seg button.active { background: var(--accent-primary); color: var(--on-accent, #fff); }
  .ct-modal .quick-sprites { display: flex; flex-wrap: wrap; gap: 8px; }
  .ct-modal .sp-pill { height: 38px; padding: 0 14px; font-size: var(--fs-body); }
  .ct-foot { gap: 12px; padding: 18px 32px; background: var(--glass-bar, rgba(var(--ltc-14-19-27, 14, 19, 27), 0.92)); border-top: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.26)); }
  .ct-hint { font-size: var(--fs-small); }
  .ct-foot .btn { min-height: 46px; padding: 0 24px; font-size: var(--fs-body); }
  .ct-foot .btn-primary { min-width: 200px; }
  @media (max-width: 1100px) { .ct-body { grid-template-columns: 1fr; } }
</style>
