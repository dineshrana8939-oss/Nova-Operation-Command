<script>
  import { defaultPageSize } from '../../adminPrefs.js';
  // EventHub → Tournaments. The admin's place to create, draw, schedule,
  // monitor and export TDM tournaments. Reorganized into a clean, modern
  // roadmap workflow matching the event creator tabs.
  import { onMount, onDestroy } from 'svelte';
  import { bootstrap, currentView, tournamentIntent, tournamentOpenId } from '../../stores.js';
  import {
    listTournaments, getTournament, getTournamentTemplates, saveTournament, shuffleTournament,
    lockTournament, tournamentAction, saveTournamentExport,
  } from '../../api/tournament.js';
  import { getGangs } from '../../api/gang.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import SubTabs from '../ui/SubTabs.svelte';
  import DateTimePicker from '../ui/DateTimePicker.svelte';
  import GangSelector from '../ui/GangSelector.svelte';
  import TournamentTree from '../../tournament/TournamentTree.svelte';
  import TournamentTreePreview from '../../tournament/TournamentTreePreview.svelte';
  import { gangLabel } from '../../tournament/tournamentUtil.js';
  import {
    buildPng, buildPdf, buildCsv, bytesToBase64, tryDownload, safeFileName, MIME,
  } from '../../tournament/tournamentExport.js';
  import '../tablet-theme.css';

  export let historyOnly = false;

  // ── state ─────────────────────────────────────────────────────────────────
  let screen = 'list'; // 'list' | 'form' | 'detail'
  let filter = historyOnly ? 'COMPLETED' : 'UPCOMING';
  let list = [];
  let loading = true;
  let error = '';
  let info = '';
  let t = null; // open tournament view
  let openId = null;
  let busy = false;
  let poll;
  let destroyed = false;

  // form
  let templates = [];
  let allGangs = [];
  let form = null;
  let saving = false;

  // Form roadmap tabs
  const FORM_ROADMAP_TABS = [
    { id: 'arena', label: '1. Arena & Template', icon: 'shield' },
    { id: 'roster', label: '2. Gang Roster', icon: 'users' },
    { id: 'schedule', label: '3. Schedule & Pacing', icon: 'clock' },
    { id: 'format', label: '4. Bracket Format', icon: 'route' },
    { id: 'rules', label: '5. Scoring & Tree Preview', icon: 'award' },
  ];
  let activeFormTab = 'arena';

  // Detail roadmap tabs
  const DETAIL_TABS = [
    { id: 'bracket', label: '1. Knockout Bracket Tree', icon: 'trophy' },
    { id: 'groups', label: '2. Groups & Draw', icon: 'users' },
    { id: 'overview', label: '3. Tournament Overview & Rules', icon: 'activity' },
    { id: 'log', label: '4. Activity Log', icon: 'clock' },
  ];
  let activeDetailTab = 'bracket';

  // result modal
  let resultMatch = null;
  let resultMode = 'PLAY';
  let resA = 0;
  let resB = 0;

  const TB_LABELS = { diff: 'Kill difference', kills: 'Total kills', wins: 'Wins' };

  // ── time helpers ──────────────────────────────────────────────────────────
  $: offsetHours = $bootstrap?.scheduleUtcOffsetHours ?? 0;
  function toLocalStr(ts) {
    if (!ts) return '';
    return new Date((ts + offsetHours * 3600) * 1000).toISOString().slice(0, 16);
  }
  function defaultStart() {
    const ts = Math.floor(Date.now() / 1000) + 3600;
    return toLocalStr(ts - (ts % 900));
  }

  // ── list ──────────────────────────────────────────────────────────────────
  async function loadList() {
    const res = await listTournaments();
    if (destroyed) return;
    if (res && res.ok) list = res.tournaments || [];
    else if (res) error = res.error || '';
    loading = false;
  }

  $: filtered = list.filter((x) => {
    if (filter === 'LIVE') return x.status === 'LIVE';
    if (filter === 'COMPLETED') return x.status === 'COMPLETED' || x.status === 'CANCELLED';
    return x.status === 'DRAFT' || x.status === 'SCHEDULED';
  });

  let tPage = 1;
  let tSize = defaultPageSize([5, 10, 15, 25, 50]);
  $: pagedTournaments = filtered.slice((tPage - 1) * tSize, tPage * tSize);
  const resetTPage = () => { tPage = 1; };
  $: resetTPage(filter);

  $: counts = {
    UPCOMING: list.filter((x) => x.status === 'DRAFT' || x.status === 'SCHEDULED').length,
    LIVE: list.filter((x) => x.status === 'LIVE').length,
    COMPLETED: list.filter((x) => x.status === 'COMPLETED' || x.status === 'CANCELLED').length,
  };

  // ── detail ────────────────────────────────────────────────────────────────
  async function openDetail(id) {
    openId = id;
    screen = 'detail';
    activeDetailTab = 'bracket';
    error = '';
    info = '';
    t = null;
    await refreshDetail();
  }

  async function refreshDetail() {
    if (!openId || busy) return;
    const res = await getTournament(openId);
    if (destroyed || screen !== 'detail') return;
    if (res && res.ok) t = res.tournament;
    else if (res) { error = res.error || 'Could not load the tournament.'; }
  }

  function backToList() {
    screen = 'list';
    openId = null;
    t = null;
    error = '';
    info = '';
    loadList();
  }

  async function run(fn, okMsg) {
    if (busy) return null;
    busy = true;
    error = '';
    info = '';
    let res;
    try {
      res = await fn();
    } finally {
      busy = false;
    }
    if (!res || res.ok === false) {
      error = (res && res.error) || 'Something went wrong.';
      return null;
    }
    if (res.deleted) { backToList(); return res; }
    if (res.tournament) t = res.tournament;
    if (okMsg) info = okMsg;
    return res;
  }

  const doShuffle = () => run(() => shuffleTournament(openId), 'Draw shuffled — reshuffle until you are happy, then lock it.');
  const doLock = () => run(() => lockTournament(openId), 'Draw locked. The tournament will start at its scheduled time.');
  const act = (action, payload, msg) => run(() => tournamentAction(openId, action, payload), msg);

  async function doCancel() {
    if (await confirmAction('Cancel this tournament? Any match in progress is stopped and the bracket is frozen.', { title: 'Cancel tournament', danger: true })) act('cancel');
  }
  async function doDelete() {
    if (await confirmAction('Permanently delete this tournament and all of its results?', { title: 'Delete tournament', danger: true })) act('delete');
  }
  async function doEndMatch() {
    if (await confirmAction('End the running match without a result? It goes back to the schedule and is replayed.', { title: 'End match', danger: true })) act('endMatch', {}, 'Match ended and returned to the schedule.');
  }
  async function doUnlock() {
    if (await confirmAction('Unlock and reshuffle the draw? The current groups and fixtures are discarded.', { title: 'Reshuffle draw' })) doShuffle();
  }

  // ── manual result ─────────────────────────────────────────────────────────
  function openResult(e) {
    const m = e.detail;
    if (!m || m.status !== 'READY' || t?.status !== 'LIVE') return;
    resultMatch = m;
    resultMode = 'PLAY';
    resA = 0;
    resB = 0;
  }
  async function submitResult() {
    const noShow = resultMode === 'PLAY' ? null : resultMode;
    const res = await act('setResult', { matchId: resultMatch.id, scoreA: resA, scoreB: resB, noShow }, 'Result recorded.');
    if (res) resultMatch = null;
  }

  // ── export ────────────────────────────────────────────────────────────────
  let exporting = false;
  async function doExport(kind) {
    if (!t || exporting) return;
    exporting = true;
    error = '';
    info = '';
    try {
      const fileName = safeFileName(t, kind);
      const bytes = kind === 'png' ? buildPng(t) : kind === 'pdf' ? buildPdf(t) : new TextEncoder().encode(buildCsv(t));
      tryDownload(bytes, fileName, MIME[kind]);
      const res = await saveTournamentExport(t.id, fileName, bytesToBase64(bytes));
      info = res && res.ok ? `Saved on the server as ${res.path}` : `Export built, but saving on the server failed: ${res?.error || 'unknown error'}`;
    } catch (e) {
      error = `Export failed: ${e?.message || e}`;
    } finally {
      exporting = false;
    }
  }

  // ── create / edit form ────────────────────────────────────────────────────
  async function openForm(existing) {
    error = '';
    info = '';
    const [tRes, gRes] = await Promise.all([getTournamentTemplates(), getGangs()]);
    templates = tRes && tRes.ok ? tRes.templates : [];
    allGangs = gRes && gRes.ok ? gRes.gangs : [];
    if (existing) {
      form = {
        id: existing.id, name: existing.name, templateId: existing.templateId,
        scheduleType: existing.schedule.type, startLocal: toLocalStr(existing.schedule.startAt),
        regOpenLocal: toLocalStr(existing.schedule.regOpenAt), durationMinutes: existing.schedule.durationMinutes || 0,
        gangs: [...existing.cfg.gangs], groupCount: existing.cfg.groupCount, advance: existing.cfg.advance, legs: existing.cfg.legs,
        scoring: { ...existing.cfg.scoring }, tieBreak: [...existing.cfg.tieBreak],
        autoAdvance: existing.autoAdvance, matchGapSeconds: existing.matchGapSeconds,
      };
    } else {
      form = {
        id: null, name: '', templateId: templates[0]?.id ?? null,
        scheduleType: 'ONE_TIME', startLocal: defaultStart(), regOpenLocal: '', durationMinutes: 90,
        gangs: [], groupCount: 2, advance: 2, legs: 1,
        scoring: { win: 3, draw: 1, loss: 0 }, tieBreak: ['diff', 'kills', 'wins'],
        autoAdvance: true, matchGapSeconds: 45,
      };
    }
    formatTouched = !!existing;
    activeFormTab = 'arena';
    screen = 'form';
  }

  function moveTb(i, d) {
    const j = i + d;
    if (j < 0 || j >= form.tieBreak.length) return;
    const next = [...form.tieBreak];
    [next[i], next[j]] = [next[j], next[i]];
    form.tieBreak = next;
  }

  let formatTouched = false;
  const clampInt = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.floor(Number(v)) || lo));
  function applySuggestion(force = false) {
    if (!form) return;
    const n = form.gangs.length;
    if (n < 2) return;
    if (force) formatTouched = false;
    if (!formatTouched) {
      const groups = Math.max(1, Math.min(n <= 4 ? 1 : n <= 8 ? 2 : n <= 16 ? 4 : 8, Math.floor(n / 2)));
      form.groupCount = groups;
      const per = Math.floor(n / groups);
      form.advance = per <= 2 ? per : 2;
    } else {
      form.groupCount = clampInt(form.groupCount, 1, Math.max(1, Math.floor(n / 2)));
      form.advance = clampInt(form.advance, 1, Math.max(1, Math.floor(n / form.groupCount)));
    }
  }

  $: nGangs = form?.gangs?.length || 0;
  $: maxGroups = Math.max(1, Math.floor(nGangs / 2));
  $: perGroup = form && form.groupCount > 0 ? Math.floor(nGangs / form.groupCount) : 0;
  $: extra = form && form.groupCount > 0 ? nGangs % form.groupCount : 0;
  $: qualifiers = form ? form.groupCount * form.advance : 0;
  $: koSize = (() => { let s = 2; while (s < qualifiers) s *= 2; return s; })();
  $: formIssue = !form ? '' :
    nGangs < 2 ? 'Pick at least 2 gangs in stage 2 (Gang Roster) to continue.' :
    form.groupCount < 1 || form.groupCount > maxGroups
      ? `${nGangs} gangs can fill at most ${maxGroups} group${maxGroups === 1 ? '' : 's'} (every group needs at least 2 gangs). Set “Number of groups” to ${maxGroups}${maxGroups > 1 ? ' or less' : ''}.`
    : form.advance < 1 || form.advance > perGroup
      ? `Each group has ${perGroup} gang${perGroup === 1 ? '' : 's'}, so between 1 and ${perGroup} can advance from it. Set “Teams advancing per group” in that range.`
    : qualifiers < 2 ? 'At least 2 teams must qualify for the knockout — raise “Teams advancing per group”.' : '';
  $: selectedTemplate = form ? templates.find((x) => x.id === form.templateId) : null;

  async function submitForm() {
    if (saving) return;
    error = '';
    if (formIssue) { error = formIssue; return; }
    saving = true;
    const res = await saveTournament({
      id: form.id, name: form.name, templateId: form.templateId, scheduleType: form.scheduleType,
      startLocal: form.startLocal, regOpenLocal: form.regOpenLocal || null, durationMinutes: form.durationMinutes,
      gangs: form.gangs, groupCount: form.groupCount, advance: form.advance, legs: form.legs,
      scoring: form.scoring, tieBreak: form.tieBreak, autoAdvance: form.autoAdvance, matchGapSeconds: form.matchGapSeconds,
    });
    saving = false;
    if (!res || res.ok === false) { error = (res && res.error) || 'Could not save.'; return; }
    await openDetail(res.tournament.id);
    info = form.id ? 'Tournament updated.' : 'Tournament created — shuffle the draw next.';
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────
  onMount(async () => {
    await loadList();
    if (!historyOnly) {
      if ($tournamentIntent === 'create') {
        tournamentIntent.set(null);
        await openForm(null);
      } else if ($tournamentOpenId && list.some((x) => x.id === $tournamentOpenId)) {
        const id = $tournamentOpenId;
        tournamentOpenId.set(null);
        openDetail(id);
      } else {
        const target = list.find((x) => x.status === 'LIVE')
          || list.find((x) => x.status === 'DRAFT' || x.status === 'SCHEDULED');
        if (target) openDetail(target.id);
      }
    }
    poll = setInterval(() => {
      if (screen === 'list') loadList();
      else if (screen === 'detail') refreshDetail();
    }, 2000);
  });

  // ── tournament switcher (detail header) ───────────────────────────────────
  let switcherOpen = false;
  const STATUS_ORDER = { LIVE: 0, SCHEDULED: 1, DRAFT: 2, COMPLETED: 3, CANCELLED: 4 };
  $: switchList = list
    .filter((x) => (historyOnly ? (x.status === 'COMPLETED' || x.status === 'CANCELLED') : true))
    .sort((a, b) => (STATUS_ORDER[a.status] ?? 9) - (STATUS_ORDER[b.status] ?? 9));
  async function switchTo(id) {
    switcherOpen = false;
    if (id !== openId) await openDetail(id);
  }

  // ── Roadmap guide progression ─────────────────────────────────────────────
  const GUIDE_STEPS = ['Arena Ready', 'Shuffle Draw', 'Lock Draw', 'Live Matches', 'Champion'];
  $: guideIdx = !t ? 0
    : t.status === 'DRAFT' ? (drawn ? 2 : 1)
    : t.status === 'SCHEDULED' ? 2
    : t.status === 'LIVE' ? 3
    : 4;
  $: guideText = !t ? ''
    : t.status === 'DRAFT' && !drawn ? 'Next: Go to “Groups & Draw” below and click “Shuffle Draw” to place the gangs into groups.'
    : t.status === 'DRAFT' ? 'Next: Review groups in “Groups & Draw”. When happy, click “Lock Draw” to generate fixtures and the knockout tree.'
    : t.status === 'SCHEDULED' ? `Draw locked. The tournament starts at its scheduled time${t.schedule?.startLabel ? ` (${t.schedule.startLabel})` : ''} — or click “Start Now”.`
    : t.status === 'LIVE' ? (t.autoAdvance ? 'Matches are starting automatically. Click waiting matches on the bracket tree to report scores manually.' : 'Auto-advance is paused — press “Start Next Match” when teams are ready.')
    : 'Tournament completed. Full records and match histories are preserved in history.';
  onDestroy(() => { destroyed = true; clearInterval(poll); });

  function fmtCompleted(ts) {
    return ts ? new Date(ts * 1000).toLocaleDateString([], { day: '2-digit', month: 'short' }) : '';
  }
  function statusTone(s) {
    return s === 'LIVE' ? 'live' : s === 'COMPLETED' ? 'done' : s === 'CANCELLED' ? 'cancel' : 'up';
  }

  $: drawn = !!t && (t.groups || []).length > 0;
  $: locked = !!t && t.drawLocked;
  $: editable = !!t && (t.status === 'DRAFT' || t.status === 'SCHEDULED') && !t.hasActivity;
  $: hasLiveMatch = !!t?.currentMatch;

  function nextFormTab() {
    const idx = FORM_ROADMAP_TABS.findIndex((x) => x.id === activeFormTab);
    if (idx >= 0 && idx < FORM_ROADMAP_TABS.length - 1) {
      activeFormTab = FORM_ROADMAP_TABS[idx + 1].id;
    }
  }
  function prevFormTab() {
    const idx = FORM_ROADMAP_TABS.findIndex((x) => x.id === activeFormTab);
    if (idx > 0) {
      activeFormTab = FORM_ROADMAP_TABS[idx - 1].id;
    }
  }
</script>

<div class="tv view-enter">
  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  <!-- SCREEN 1: TOURNAMENTS LIST & OVERVIEW ROADMAP                           -->
  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  {#if screen === 'list'}
    <div class="panel">
      <div class="panel-header">
        <div class="panel-heading">
          <div class="panel-title">
            <Icon name={historyOnly ? 'history' : 'trophy'} size={15} />
            <span>{historyOnly ? 'Tournament History' : 'Tournaments & Cups'}</span>
          </div>
          <div class="panel-subtitle">
            {historyOnly ? 'Completed tournament records, bracket archives, and champion after-action reports.' : 'Multi-stage knockout and group championships for rival gangs.'}
          </div>
        </div>
        {#if !historyOnly}
          <button class="btn btn-primary" on:click={() => openForm(null)}>
            <Icon name="plus" size={13} />
            <span>Create Tournament</span>
          </button>
        {/if}
      </div>

      <div class="panel-body">
        <!-- Tournament Event Workflow Roadmap Banner -->
        {#if !historyOnly}
          <div class="tournament-roadmap-banner">
            <div class="roadmap-head">
              <Icon name="route" size={14} />
              <b>TOURNAMENT EVENT ROADMAP</b>
              <small>Standard 5-stage tournament progression</small>
            </div>
            <div class="roadmap-steps-flow">
              <div class="rm-node">
                <span class="rm-idx">1</span>
                <div class="rm-text">
                  <strong>Build Arena Template</strong>
                  <small>Create Event → TDM → Tournament format</small>
                </div>
              </div>
              <span class="rm-arrow">→</span>
              <div class="rm-node">
                <span class="rm-idx">2</span>
                <div class="rm-text">
                  <strong>Configure Roster</strong>
                  <small>Pick gangs &amp; set start schedule</small>
                </div>
              </div>
              <span class="rm-arrow">→</span>
              <div class="rm-node">
                <span class="rm-idx">3</span>
                <div class="rm-text">
                  <strong>Shuffle &amp; Lock Draw</strong>
                  <small>Generate groups &amp; bracket tree</small>
                </div>
              </div>
              <span class="rm-arrow">→</span>
              <div class="rm-node">
                <span class="rm-idx">4</span>
                <div class="rm-text">
                  <strong>Run Live Matches</strong>
                  <small>Automated matches on arena</small>
                </div>
              </div>
              <span class="rm-arrow">→</span>
              <div class="rm-node">
                <span class="rm-idx">5</span>
                <div class="rm-text">
                  <strong>Crown Champion</strong>
                  <small>Pay rewards &amp; export PDF reports</small>
                </div>
              </div>
            </div>
          </div>
        {/if}

        <!-- Filter Chips -->
        {#if !historyOnly}
          <div class="filters">
            {#each [['UPCOMING', 'Upcoming'], ['LIVE', 'Live'], ['COMPLETED', 'Completed']] as [id, label]}
              <button class:active={filter === id} on:click={() => (filter = id)}>
                <span>{label}</span>
                <span class="cnt">{counts[id]}</span>
              </button>
            {/each}
          </div>
        {/if}

        {#if error}<div class="error" style="margin-bottom:10px">{error}</div>{/if}

        {#if loading}
          <div class="empty-state">Loading tournaments…</div>
        {:else if filtered.length === 0}
          <div class="empty-state">
            {#if filter === 'LIVE'}No tournament is live right now.
            {:else if filter === 'COMPLETED'}No completed tournaments yet.
            {:else}Nothing scheduled.{#if !historyOnly}{' '}Click <b>Create Tournament</b> above to start.{/if}{/if}
          </div>
        {:else}
          <div class="tt-card">
            <TablePager top bind:page={tPage} bind:pageSize={tSize} total={filtered.length} noun="tournaments" sizes={[5, 10, 15, 25, 50]} />
            <div class="t-scroll">
              <table class="tt">
                <thead>
                  <tr>
                    <th class="num">#</th>
                    <th>Tournament</th>
                    <th>Status</th>
                    <th>Stage and matches</th>
                    <th class="num">Gangs</th>
                    <th class="num">Groups</th>
                    <th>{historyOnly || filter === 'COMPLETED' ? 'Completed' : 'Starts'}</th>
                    <th class="act"></th>
                  </tr>
                </thead>
                <tbody>
                  {#each pagedTournaments as x, i (x.id)}
                    <tr class="tt-row" on:click={() => openDetail(x.id)}>
                      <td class="num dim">{(tPage - 1) * tSize + i + 1}</td>
                      <td>
                        <div class="nm"><b>{x.name}</b>{#if x.edition > 1 || x.seriesId}<span class="edition-pill">Edition {String(x.edition).padStart(2, '0')}</span>{/if}</div>
                      </td>
                      <td>
                        <span class="status-pill tone-{statusTone(x.status)}">
                          {#if x.status === 'LIVE'}Live{:else if x.status === 'SCHEDULED' && !x.drawLocked}Draft{:else if x.status === 'SCHEDULED'}Scheduled{:else if x.status === 'DRAFT'}Draft{:else if x.status === 'COMPLETED'}Completed{:else if x.status === 'CANCELLED'}Cancelled{:else}{x.status}{/if}
                        </span>
                      </td>
                      <td class="dim">
                        {#if x.status === 'COMPLETED'}
                          Champion: <b class="champ">{x.championLabel || '—'}</b>
                        {:else if x.status === 'LIVE'}
                          <b class="stage">{x.stage}</b> — {x.playedMatches}/{x.totalMatches} matches played{#if x.liveMatchLabel} — {x.liveMatchLabel} is on{/if}
                        {:else}
                          {x.scheduleType !== 'ONE_TIME' ? x.scheduleType : 'One-time'}{#if x.registrationOpen} — <span class="reg">registration open</span>{/if}
                        {/if}
                      </td>
                      <td class="num">{x.gangCount}</td>
                      <td class="num">{x.groupCount}</td>
                      <td class="dim nowrap">{x.status === 'COMPLETED' ? fmtCompleted(x.completedAt) : (x.startLabel || 'No start time')}</td>
                      <td class="act"><button type="button" class="btn btn-sm btn-steel" on:click|stopPropagation={() => openDetail(x.id)}>Open</button></td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          </div>
        {/if}
      </div>
    </div>

    <p class="tree-hint">The live tournament tree has its own page: Tournaments → <b>Tournament Tree</b>.</p>

  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  <!-- SCREEN 2: CREATE / EDIT TOURNAMENT FORM (5-STAGE ROADMAP STEPPER)       -->
  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  {:else if screen === 'form' && form}
    <div class="panel">
      <div class="panel-header">
        <div class="panel-heading">
          <div class="panel-title">
            <Icon name="trophy" size={15} />
            <span>{form.id ? 'Edit Tournament' : 'Create Tournament (5-Stage Setup)'}</span>
          </div>
          <div class="panel-subtitle">
            Configure the 5 roadmap stages below. When created, you shuffle and lock the draw to generate live bracket fixtures.
          </div>
        </div>
        <button class="btn btn-back" on:click={() => (form.id ? openDetail(form.id) : backToList())}>
          <span>Cancel</span>
        </button>
      </div>

      <div class="panel-body">
        <!-- 5-Stage Form Roadmap SubTabs -->
        <SubTabs tabs={FORM_ROADMAP_TABS} bind:active={activeFormTab} />

        <!-- STAGE 1: ARENA & TEMPLATE -->
        {#if activeFormTab === 'arena'}
          <div class="stage-pane">
            <div class="field">
              <label for="tourney-name">Tournament Name</label>
              <input id="tourney-name" type="text" bind:value={form.name} maxlength="100" placeholder="e.g. Los Santos Gang Championship" />
              <small>The official title shown on banners, gang notifications, scoreboard overlays, and PDF reports.</small>
            </div>

            <div class="field">
              <label for="tourney-tpl">TDM Arena Template</label>
              {#if templates.length === 0}
                <div class="warn-box">
                  <b>No tournament arena template exists yet.</b> An arena is a TDM event with format set to <b>Tournament TDM</b>.
                  <ol class="mini-steps">
                    <li>Open <b>Create Event</b> and choose <b>TDM Match</b>.</li>
                    <li>In <b>Match Setup</b>, set format to <b>Tournament TDM</b>.</li>
                    <li>Walk the perimeter zone, place red/blue spawns and vendors, then save.</li>
                  </ol>
                  <button type="button" class="btn btn-secondary btn-mini" on:click={() => currentView.set('create')}>
                    <Icon name="plus" size={12} /><span>Go to Create Event</span>
                  </button>
                </div>
              {:else}
                <select id="tourney-tpl" bind:value={form.templateId}>
                  {#each templates as x}
                    <option value={x.id}>{x.name}</option>
                  {/each}
                </select>

                {#if selectedTemplate}
                  <div class="arena-card">
                    <div class="arena-card-head">
                      <Icon name="map" size={14} />
                      <b>{selectedTemplate.name}</b>
                    </div>
                    <div class="arena-stats-grid">
                      <div class="stat-pill" class:ok={selectedTemplate.zoneOk} class:bad={!selectedTemplate.zoneOk}>
                        <span>Combat Zone:</span>
                        <strong>{selectedTemplate.zoneOk ? '✓ Configured' : '✕ Missing'}</strong>
                      </div>
                      <div class="stat-pill" class:ok={selectedTemplate.spawnOk} class:bad={!selectedTemplate.spawnOk}>
                        <span>Respawn Points:</span>
                        <strong>{selectedTemplate.spawnOk ? '✓ Configured' : '✕ Missing'}</strong>
                      </div>
                      <div class="stat-pill neutral">
                        <span>Duration:</span>
                        <strong>{Math.round((selectedTemplate.duration || 0) / 60)} min / match</strong>
                      </div>
                      <div class="stat-pill neutral">
                        <span>Kill Limit:</span>
                        <strong>{selectedTemplate.killLimit ? `${selectedTemplate.killLimit} kills` : 'None'}</strong>
                      </div>
                    </div>
                  </div>
                {/if}
              {/if}
            </div>
          </div>

        <!-- STAGE 2: GANG ROSTER -->
        {:else if activeFormTab === 'roster'}
          <div class="stage-pane">
            <div class="stage-intro">
              <Icon name="users" size={14} />
              <span>Select participating gangs (minimum 2 gangs). Groups and knockout brackets are calculated automatically.</span>
              <span class="roster-count">{nGangs} gangs selected</span>
            </div>
            <GangSelector
              availableGangs={allGangs}
              showModeSwitch={false}
              title="Participating Gangs"
              bind:selected={form.gangs}
              on:change={applySuggestion}
            />
          </div>

        <!-- STAGE 3: SCHEDULE & PACING -->
        {:else if activeFormTab === 'schedule'}
          <div class="stage-pane">
            <div class="field">
              <label>Recurrence Schedule</label>
              <div class="seg">
                {#each [['ONE_TIME', 'One-Time Match'], ['DAILY', 'Daily Cup'], ['WEEKLY', 'Weekly Championship']] as [id, lb]}
                  <button type="button" class:active={form.scheduleType === id} on:click={() => (form.scheduleType = id)}>{lb}</button>
                {/each}
              </div>
              {#if form.scheduleType !== 'ONE_TIME'}
                <small>A fresh tournament edition is generated automatically every {form.scheduleType === 'DAILY' ? 'day' : 'week'} at this time.</small>
              {/if}
            </div>

            <div class="field-row">
              <div class="field">
                <label>Tournament Start Time</label>
                <DateTimePicker bind:value={form.startLocal} />
              </div>
              <div class="field">
                <label>Registration Window Opens <span class="optional">optional</span></label>
                <DateTimePicker bind:value={form.regOpenLocal} />
                {#if form.regOpenLocal}
                  <button type="button" class="btn btn-steel btn-mini clear-reg" on:click={() => (form.regOpenLocal = '')}>
                    <Icon name="close" size={11} /><span>Clear</span>
                  </button>
                {/if}
              </div>
            </div>

            <div class="field-row">
              <div class="field">
                <label>Estimated Total Duration <span class="optional">minutes</span></label>
                <input type="number" min="0" max="1440" bind:value={form.durationMinutes} />
              </div>
              <div class="field">
                <label>Pause Gap Between Matches <span class="optional">seconds</span></label>
                <input type="number" min="10" max="600" bind:value={form.matchGapSeconds} />
              </div>
            </div>

            <div class="field">
              <Toggle bind:checked={form.autoAdvance} label="Auto-advance matches (matches start automatically when teams are ready; if off, an admin triggers each match)" />
            </div>
          </div>

        <!-- STAGE 4: BRACKET FORMAT -->
        {:else if activeFormTab === 'format'}
          <div class="stage-pane">
            <div class="field-row">
              <div class="field">
                <label for="group-count">Number of Groups</label>
                <input id="group-count" type="number" min="1" max="16" bind:value={form.groupCount} on:input={() => (formatTouched = true)} on:change={() => applySuggestion()} />
              </div>
              <div class="field">
                <label for="adv-count">Teams Advancing Per Group</label>
                <input id="adv-count" type="number" min="1" max="16" bind:value={form.advance} on:input={() => (formatTouched = true)} on:change={() => applySuggestion()} />
              </div>
            </div>

            <div class="field">
              <label>Group Stage Format</label>
              <div class="seg">
                <button type="button" class:active={form.legs === 1} on:click={() => (form.legs = 1)}>Single Round-Robin (1 match)</button>
                <button type="button" class:active={form.legs === 2} on:click={() => (form.legs = 2)}>Double Round-Robin (Home &amp; Away)</button>
              </div>
              <small>Round-robin: every gang battles every other gang in their group. The top teams advance to single-elimination knockout.</small>
            </div>

            <div class="preview-box" class:bad={!!formIssue}>
              {#if formIssue}
                <div class="issue-flex">
                  <span>{formIssue}</span>
                  {#if nGangs >= 2}
                    <button type="button" class="btn btn-secondary btn-mini" on:click={() => applySuggestion(true)}>
                      <Icon name="check" size={12} /><span>Auto-Fix Parameters</span>
                    </button>
                  {/if}
                </div>
              {:else}
                <div class="summary-flow">
                  <b>{nGangs} Gangs</b> → <b>{form.groupCount} Groups</b> (of {extra ? `${perGroup}–${perGroup + 1}` : perGroup}) → <b>Top {form.advance} Advance</b> → <b>{qualifiers}-Team Knockout</b> → <b>Champion</b>
                </div>
              {/if}
            </div>
          </div>

        <!-- STAGE 5: RULES & PREVIEW -->
        {:else if activeFormTab === 'rules'}
          <div class="stage-pane">
            <div class="field-row" style="grid-template-columns: repeat(3, minmax(0, 1fr));">
              <div class="field">
                <label for="score-win">Win Points</label>
                <input id="score-win" type="number" bind:value={form.scoring.win} />
              </div>
              <div class="field">
                <label for="score-draw">Draw Points</label>
                <input id="score-draw" type="number" bind:value={form.scoring.draw} />
              </div>
              <div class="field">
                <label for="score-loss">Loss Points</label>
                <input id="score-loss" type="number" bind:value={form.scoring.loss} />
              </div>
            </div>

            <div class="field">
              <label>Tie-Break Priority Order</label>
              <div class="tb-list">
                {#each form.tieBreak as k, i}
                  <div class="tb-row">
                    <span class="tb-n">{i + 1}</span>
                    <span class="tb-name">{TB_LABELS[k]}</span>
                    <div class="tb-btns">
                      <button type="button" class="btn btn-steel btn-mini tb-move" disabled={i === 0} title="Move up" on:click={() => moveTb(i, -1)}>
                        <Icon name="chevronUp" size={12} />
                      </button>
                      <button type="button" class="btn btn-steel btn-mini tb-move" disabled={i === form.tieBreak.length - 1} title="Move down" on:click={() => moveTb(i, 1)}>
                        <Icon name="chevronDown" size={12} />
                      </button>
                    </div>
                  </div>
                {/each}
              </div>
            </div>

            <!-- Live Bracket Preview -->
            <div style="margin-top: 14px;">
              <TournamentTreePreview
                qualifiers={qualifiers >= 2 ? qualifiers : 8}
                title="Knockout Tree Preview"
                message="Visual preview of the knockout tree that will be generated for this tournament."
              />
            </div>
          </div>
        {/if}

        <!-- Stepper Navigation & Save Bar -->
        <div class="stepper-footer">
          <div class="stepper-nav">
            {#if activeFormTab !== 'arena'}
              <button type="button" class="btn btn-steel" on:click={prevFormTab}>
                <Icon name="chevronLeft" size={13} /><span>Previous Stage</span>
              </button>
            {/if}
            {#if activeFormTab !== 'rules'}
              <button type="button" class="btn btn-steel" on:click={nextFormTab}>
                <span>Next Stage</span><Icon name="chevronRight" size={13} />
              </button>
            {/if}
          </div>

          <div class="save-wrap">
            {#if formIssue}
              <span class="status-warn">{formIssue}</span>
            {:else if !form.name.trim()}
              <span class="status-warn">Enter a tournament name to continue.</span>
            {:else if !form.templateId}
              <span class="status-warn">Select an arena template to continue.</span>
            {/if}
            <button class="btn btn-primary btn-save" disabled={saving || !!formIssue || !form.name.trim() || !form.templateId} on:click={submitForm}>
              <Icon name="check" size={13} />
              <span>{saving ? 'Saving…' : (form.id ? 'Save Changes' : 'Create Tournament')}</span>
            </button>
          </div>
        </div>
      </div>
    </div>

  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  <!-- SCREEN 3: TOURNAMENT DETAIL VIEW (ROADMAP DETAIL TABS)                  -->
  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  {:else if screen === 'detail'}
    <!-- Title Bar with Status and Quick Switcher -->
    <div class="t-head">
      <div class="t-head-main">
        <div class="kicker">{historyOnly ? 'TOURNAMENT HISTORY ARCHIVE' : 'LIVE TOURNAMENT ROADMAP'}</div>
        <div class="heading">{t ? t.name : 'Loading…'}</div>
        {#if t}
          <div class="sub">
            {t.cfg.gangs.length} gangs · {t.cfg.groupCount} group{t.cfg.groupCount === 1 ? '' : 's'} · top {t.cfg.advance} advance to single-elimination knockout
            {#if t.schedule?.startLabel} · {t.schedule.startLabel}{/if}
            {#if t.edition > 1 || t.seriesId} · Edition {String(t.edition).padStart(2, '0')}{/if}
          </div>
        {/if}
      </div>

      <div class="switcher">
        <div class="t-select-wrap">
          <button type="button" class="t-select" on:click={() => (switcherOpen = !switcherOpen)} aria-haspopup="listbox" aria-expanded={switcherOpen}>
            <span class="sel-label">{historyOnly ? 'TOURNAMENT' : 'ACTIVE TOURNAMENT'}</span>
            <span class="sel-value">{t ? t.name : '—'}</span>
            <span class="sel-meta">{t ? `${t.cfg.gangs.length} gangs · ${t.schedule?.startLabel || 'No start time'}` : ''}</span>
            <span class="sel-caret"><Icon name="chevronDown" size={14} /></span>
          </button>
          {#if switcherOpen}
            <div class="t-menu" role="listbox">
              {#each switchList as x (x.id)}
                <button type="button" class="t-opt" class:current={x.id === openId} on:click={() => switchTo(x.id)}>
                  <span class="t-opt-ic">{x.status === 'LIVE' ? '●' : 'T'}</span>
                  <span class="t-opt-info">
                    <b>{x.name}</b>
                    <small>{x.gangCount} gangs · {x.groupCount} group{x.groupCount === 1 ? '' : 's'}{x.startLabel ? ` · ${x.startLabel}` : ''}</small>
                  </span>
                  <span class="t-opt-state tone-{statusTone(x.status)}">{x.status === 'SCHEDULED' && !x.drawLocked ? 'DRAFT' : x.status}</span>
                </button>
              {/each}
              {#if switchList.length === 0}<div class="t-opt-empty">No other tournaments.</div>{/if}
            </div>
          {/if}
        </div>
        {#if t}
          <div class="status-box">
            <small>STATUS</small>
            <strong class="tone-{statusTone(t.status)}">{t.status === 'LIVE' ? '● LIVE' : (t.status === 'SCHEDULED' && !t.drawLocked ? 'DRAFT' : t.status)}</strong>
          </div>
        {/if}
      </div>
    </div>

    <!-- Actions Bar -->
    <div class="topbar">
      <div class="actions">
        <button class="btn btn-back" on:click={backToList}><Icon name="list" size={13} /><span>All Tournaments</span></button>
        {#if !historyOnly}
          <button class="btn btn-secondary" on:click={() => openForm(null)}><Icon name="plus" size={13} /><span>New Tournament</span></button>
        {/if}
      </div>

      {#if t}
        <div class="actions">
          {#if editable}
            <button class="btn btn-edit" disabled={busy} on:click={() => openForm(t)}><Icon name="edit" size={13} /><span>Edit</span></button>
          {/if}
          {#if t.status === 'SCHEDULED'}
            <button class="btn btn-primary" disabled={busy} on:click={() => act('startNow', {}, 'Tournament started.')}><Icon name="play" size={13} /><span>Start Now</span></button>
          {/if}
          {#if t.status === 'LIVE'}
            {#if hasLiveMatch}
              <button class="btn btn-danger" disabled={busy} on:click={doEndMatch}>End Match</button>
            {:else}
              <button class="btn btn-primary" disabled={busy || !t.nextMatchId} on:click={() => act('startNext', {}, 'Match starting.')}><Icon name="play" size={13} /><span>Start Next Match</span></button>
            {/if}
            {#if t.autoAdvance}
              <button class="btn" disabled={busy} on:click={() => act('pause', {}, 'Auto-start paused.')}>Pause Auto-start</button>
            {:else}
              <button class="btn" disabled={busy} on:click={() => act('resume', {}, 'Auto-start resumed.')}>Resume Auto-start</button>
            {/if}
          {/if}
          {#if t.status === 'SCHEDULED' && !t.hasActivity}
            <button class="btn" disabled={busy} on:click={doUnlock}>Reshuffle</button>
          {/if}
          {#if t.status === 'DRAFT' || t.status === 'SCHEDULED' || t.status === 'LIVE'}
            <button class="btn btn-danger" disabled={busy} on:click={doCancel}>Cancel Tournament</button>
          {/if}
          {#if t.status !== 'LIVE'}
            <button class="btn btn-danger" disabled={busy} on:click={doDelete}><Icon name="trash" size={13} /><span>Delete</span></button>
          {/if}
        </div>
      {/if}
    </div>

    <!-- Visual Roadmap Stage Indicator -->
    {#if t && !historyOnly && t.status !== 'COMPLETED' && t.status !== 'CANCELLED'}
      <div class="roadmap-indicator-bar">
        {#each GUIDE_STEPS as s, i}
          <div class="rm-badge" class:done={i < guideIdx} class:cur={i === guideIdx}>
            <span class="rm-num">{#if i < guideIdx}✓{:else}{i + 1}{/if}</span>
            <span>{s}</span>
          </div>
          {#if i < GUIDE_STEPS.length - 1}<span class="rm-line"></span>{/if}
        {/each}
      </div>
      <div class="guide-text"><Icon name="info" size={13} /> {guideText}</div>
    {/if}

    {#if error}<div class="banner error">{error}</div>{/if}
    {#if info}<div class="banner info">{info}</div>{/if}

    {#if !t}
      <div class="empty-state">Loading tournament…</div>
    {:else}
      <!-- Detail Roadmap SubTabs -->
      <SubTabs tabs={DETAIL_TABS} bind:active={activeDetailTab} />

      <!-- DETAIL TAB 1: KNOCKOUT BRACKET & MATCHES -->
      {#if activeDetailTab === 'bracket'}
        {#if !drawn}
          <TournamentTreePreview
            qualifiers={(t.cfg?.groupCount || 1) * (t.cfg?.advance || 2)}
            title="Knockout Bracket"
            message="Shuffle and lock the draw in the 'Groups & Draw' tab to generate fixtures and the knockout tree."
          />
        {:else}
          <TournamentTree {t} showTitle={false} selectable={t.status === 'LIVE'} on:matchClick={openResult}>
            <div slot="tools" class="export-btns">
              <span class="lbl">Export</span>
              <button class="btn btn-steel btn-mini" disabled={exporting} on:click={() => doExport('png')}><Icon name="download" size={12} /> PNG</button>
              <button class="btn btn-steel btn-mini" disabled={exporting} on:click={() => doExport('pdf')}><Icon name="download" size={12} /> PDF</button>
              <button class="btn btn-steel btn-mini" disabled={exporting} on:click={() => doExport('csv')}><Icon name="download" size={12} /> CSV</button>
            </div>
          </TournamentTree>
          {#if t.status === 'LIVE'}
            <div class="hint tip">Tip: click a waiting match card on the tree to report a score or walkover manually.</div>
          {/if}
        {/if}

      <!-- DETAIL TAB 2: GROUPS & DRAW -->
      {:else if activeDetailTab === 'groups'}
        <div class="panel draw">
          <div class="panel-header">
            <div class="panel-heading">
              <div class="panel-title"><Icon name="users" size={14} /> {drawn ? 'Tournament Groups' : 'Group Draw'}</div>
              <div class="panel-subtitle">
                {drawn
                  ? `${t.groups.length} groups with ${t.cfg.advance} gangs advancing per group into single-elimination knockout.`
                  : `${t.cfg.gangs.length} gangs will be randomized into ${t.cfg.groupCount} group${t.cfg.groupCount === 1 ? '' : 's'}.`}
              </div>
            </div>
            {#if t.status === 'DRAFT'}
              <div class="draw-actions">
                <button class="btn btn-steel" disabled={busy} on:click={doShuffle}>
                  <Icon name="refresh" size={13} /><span>{drawn ? 'Reshuffle Groups' : 'Shuffle Draw'}</span>
                </button>
                {#if drawn}
                  <button class="btn btn-primary" disabled={busy || !t.templateOk} on:click={doLock}>
                    <Icon name="check" size={13} /><span>Lock Draw</span>
                  </button>
                {/if}
              </div>
            {/if}
          </div>

          {#if drawn}
            <div class="panel-body draw-body">
              {#each t.groups as g}
                <div class="draw-group">
                  <div class="dg-title">GROUP {g.name}</div>
                  {#each g.gangs as name}
                    <div class="dg-gang">{gangLabel(t, name)}</div>
                  {/each}
                </div>
              {/each}
            </div>
            {#if !t.templateOk}
              <div class="warn-box" style="margin: 0 20px 16px;">
                The chosen TDM arena template still needs a combat zone (3+ points) and spawn points before the draw can be locked.
              </div>
            {/if}
          {:else}
            <div class="empty-state">
              Draw has not been generated yet. Click <b>Shuffle Draw</b> above to place gangs into groups.
            </div>
          {/if}
        </div>

      <!-- DETAIL TAB 3: OVERVIEW & RULES -->
      {:else if activeDetailTab === 'overview'}
        <div class="overview-grid">
          <div class="card-box">
            <h4>Tournament Format</h4>
            <div class="info-row"><span>Tournament Format:</span><b>Single-Elimination Knockout</b></div>
            <div class="info-row"><span>Group Match Format:</span><b>{t.cfg.legs === 2 ? 'Double Round-Robin (Home/Away)' : 'Single Round-Robin'}</b></div>
            <div class="info-row"><span>Groups Count:</span><b>{t.cfg.groupCount} Groups</b></div>
            <div class="info-row"><span>Qualifiers Per Group:</span><b>Top {t.cfg.advance} Advance</b></div>
            <div class="info-row"><span>Auto-Advance Matches:</span><b>{t.autoAdvance ? 'Enabled (Automatic)' : 'Manual Admin Trigger'}</b></div>
          </div>

          <div class="card-box">
            <h4>Scoring &amp; Tie-Breaks</h4>
            <div class="info-row"><span>Points for Win:</span><b>{t.cfg.scoring?.win ?? 3}</b></div>
            <div class="info-row"><span>Points for Draw:</span><b>{t.cfg.scoring?.draw ?? 1}</b></div>
            <div class="info-row"><span>Points for Loss:</span><b>{t.cfg.scoring?.loss ?? 0}</b></div>
            <div class="info-row"><span>Tie-Break Order:</span><b>{(t.cfg.tieBreak || []).map((k) => TB_LABELS[k] || k).join(' → ')}</b></div>
          </div>
        </div>

      <!-- DETAIL TAB 4: ACTIVITY LOG -->
      {:else if activeDetailTab === 'log'}
        <div class="panel">
          <div class="panel-header">
            <div class="panel-title"><Icon name="activity" size={14} /><span>Activity Log</span></div>
          </div>
          <div class="log">
            {#each (t.log || []).slice(0, 30) as l}
              <div class="log-row">
                <span class="log-t">{new Date(l.t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
                <span>{l.text}</span>
              </div>
            {/each}
            {#if (t.log || []).length === 0}
              <div class="empty-state">No tournament activity logged yet.</div>
            {/if}
          </div>
        </div>
      {/if}
    {/if}
  {/if}

  <!-- Manual Score / Result Modal -->
  {#if resultMatch}
    <div class="modal-backdrop" on:click|self={() => (resultMatch = null)}>
      <div class="modal">
        <div class="m-title">Record Result — {resultMatch.label}</div>
        <div class="m-teams">{gangLabel(t, resultMatch.a.gang)} <span>vs</span> {gangLabel(t, resultMatch.b.gang)}</div>
        <div class="seg wrap">
          <button type="button" class:active={resultMode === 'PLAY'} on:click={() => (resultMode = 'PLAY')}>Enter score</button>
          <button type="button" class:active={resultMode === 'A'} on:click={() => (resultMode = 'A')}>{gangLabel(t, resultMatch.a.gang)} no-show</button>
          <button type="button" class:active={resultMode === 'B'} on:click={() => (resultMode = 'B')}>{gangLabel(t, resultMatch.b.gang)} no-show</button>
          <button type="button" class:active={resultMode === 'BOTH'} on:click={() => (resultMode = 'BOTH')}>Both no-show</button>
        </div>
        {#if resultMode === 'PLAY'}
          <div class="score-row">
            <div class="field"><label>{gangLabel(t, resultMatch.a.gang)}</label><input type="number" min="0" bind:value={resA} /></div>
            <div class="field"><label>{gangLabel(t, resultMatch.b.gang)}</label><input type="number" min="0" bind:value={resB} /></div>
          </div>
        {/if}
        <div class="form-actions">
          <button class="btn btn-steel" on:click={() => (resultMatch = null)}>Cancel</button>
          <button class="btn btn-primary" on:click={submitResult}>Save Result</button>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  .tv {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .panel {
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-panel);
    overflow: hidden;
  }
  .panel-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    background: var(--c-panel, #181b1f);
    border-bottom: 1px solid var(--c-raised, #1f2328);
  }
  .panel-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .panel-subtitle {
    margin-top: 2px;
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .panel-body {
    padding: 18px;
  }

  /* Roadmap Flow Banner */
  .tournament-roadmap-banner {
    background: var(--lt-111316, #111316);
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-panel);
    padding: 14px 16px;
    margin-bottom: 16px;
  }
  .roadmap-head {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--accent-primary);
    margin-bottom: 12px;
  }
  .roadmap-head small {
    margin-left: auto;
    font-size: var(--fs-meta);
    color: var(--text-dim);
    font-weight: 400;
  }
  .roadmap-steps-flow {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    overflow-x: auto;
  }
  .rm-node {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-ctl);
    flex: 1;
    min-width: 150px;
  }
  .rm-idx {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--accent-primary);
    font-size: var(--fs-meta);
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    border-left: 3px solid rgb(56, 189, 248);}
  .rm-text strong {
    display: block;
    font-size: var(--fs-meta);
    color: var(--lt-ffffff, #fff);
  }
  .rm-text small {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .rm-arrow {
    color: var(--text-dim);
    font-size: var(--fs-body);
    opacity: 0.5;
  }

  /* Filters */
  .filters {
    display: flex;
    gap: 6px;
    margin-bottom: 14px;
  }
  .filters button {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
  }
  .filters button.active {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .filters .cnt {
    font-size: var(--fs-meta);
    padding: 1px 6px;
    border-radius: 999px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.15);
  }

  /* The tournaments table: same surface, header and rows as the other admin tables. */
  .tt-card { background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, var(--c-line)); border-radius: var(--r-panel); overflow: hidden; }
  .t-scroll { overflow-x: auto; }
  .tt { width: 100%; border-collapse: collapse; font-size: var(--fs-small); text-align: left; }
  .tt th { padding: var(--tbl-th-y) var(--tbl-x); background: var(--c-panel); border-bottom: 1px solid var(--c-line); font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0; color: var(--text-muted); white-space: nowrap; }
  .tt td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft); vertical-align: middle; font-variant-numeric: tabular-nums; }
  .tt tbody tr:last-child td { border-bottom: 0; }
  .tt .num { text-align: right; }
  .tt .act { text-align: right; width: 1%; white-space: nowrap; }
  .tt .dim { color: var(--text-dim); }
  .tt .nowrap { white-space: nowrap; }
  .tt-row { cursor: pointer; transition: background 0.12s ease; }
  .tt-row:hover td { background: var(--glass-head, rgba(var(--ink-rgb, 255, 255, 255), 0.04)); }
  .nm { display: flex; align-items: center; gap: 8px; }
  .nm b { font-weight: 600; }
  .edition-pill { font-size: var(--fs-meta); padding: 2px 8px; border-radius: var(--r-tag); background: rgb(168, 85, 247); border: 1px solid rgb(168, 85, 247); color: #111111; font-weight: 600; white-space: nowrap; }
  .status-pill { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; white-space: nowrap; }
  .status-pill.tone-live { background: rgb(72, 199, 142); color: #111111; border: 1px solid rgb(72, 199, 142); }
  .status-pill.tone-up { background: rgb(56, 189, 248); color: #111111; border: 1px solid rgb(56, 189, 248); }
  .status-pill.tone-done { background: rgb(168, 85, 247); color: #111111; border: 1px solid rgb(168, 85, 247); }
  .status-pill.tone-cancel { background: rgb(239, 68, 68); color: #111111; border: 1px solid rgb(239, 68, 68); }
  .champ { color: #48c78e; }
  .stage { color: var(--accent-primary-light, #60a5fa); }
  .reg { color: #fbbf24; }
  .tree-hint { margin: 12px 4px 0; font-size: var(--fs-small); color: var(--text-muted, #8d949c); }
  .empty-state {
    padding: 36px;
    text-align: center;
    color: var(--text-dim);
    font-size: var(--fs-small);
  }

  /* Form Stage Panes */
  .stage-pane {
    display: flex;
    flex-direction: column;
    gap: 14px;
    margin-top: 4px;
  }
  .stage-intro {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    color: var(--lt-c9ced4, #c9ced4);
  }
  .roster-count {
    margin-left: auto;
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--accent-primary);
  }
  .arena-card {
    margin-top: 10px;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-panel);
    padding: 12px 14px;
  }
  .arena-card-head {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: var(--fs-small);
    color: var(--lt-ffffff, #fff);
    margin-bottom: 8px;
  }
  .arena-stats-grid {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .stat-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
  }
  .stat-pill.ok { background: rgb(72, 199, 142); color: #111111; border: 1px solid rgb(72, 199, 142); }
  .stat-pill.bad { background: rgb(239, 68, 68); color: #111111; border: 1px solid rgb(239, 68, 68); }
  .stat-pill.neutral { background: var(--c-panel, #181b1f); color: var(--text-dim); border: 1px solid var(--c-raised, #1f2328); }
  .preview-box {
    padding: 12px 14px;
    background: var(--lt-111316, #111316);
    border: 1px solid rgba(56, 189, 248, 0.3);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
  }
  .preview-box.bad {
    border-color: var(--c-line);
    background: var(--c-raised);
    color: #f87171;
    border-left: 3px solid rgb(239, 68, 68);}
  .issue-flex {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
  }
  .summary-flow b {
    color: var(--accent-primary);
  }
  .tb-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .tb-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-ctl);
  }
  .tb-n {
    width: 20px;
    height: 20px;
    border-radius: 50%;
    background: var(--c-raised, #1f2328);
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--text-dim);
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .tb-name {
    flex: 1;
    font-size: var(--fs-small);
    color: var(--lt-ffffff, #fff);
    font-weight: 600;
  }
  .tb-btns {
    display: flex;
    gap: 4px;
  }

  /* Stepper Footer */
  .stepper-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    margin-top: 18px;
    padding-top: 16px;
    border-top: 1px solid var(--c-raised, #1f2328);
    flex-wrap: wrap;
  }
  .stepper-nav {
    display: flex;
    gap: 8px;
  }
  .save-wrap {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-left: auto;
  }
  .status-warn {
    font-size: var(--fs-meta);
    color: #f87171;
  }

  /* Detail Header & Switcher */
  .t-head {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 16px;
    flex-wrap: wrap;
  }
  .kicker {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--accent-primary);
  }
  .heading {
    margin-top: 2px;
    font-size: var(--fs-section);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
    font-family: var(--font-display); font-stretch: var(--stretch-display);
  }
  .sub {
    margin-top: 4px;
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .switcher {
    display: flex;
    align-items: stretch;
    gap: 8px;
  }
  .t-select-wrap {
    position: relative;
  }
  .t-select {
    position: relative;
    min-width: 300px;
    min-height: 64px;
    padding: 8px 36px 8px 12px;
    text-align: left;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 2px;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    cursor: pointer;
  }
  .sel-label {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim);
  }
  .sel-value {
    font-size: var(--fs-body);
    font-weight: 700;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .sel-meta {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .sel-caret {
    position: absolute;
    right: 12px;
    top: 50%;
    transform: translateY(-50%);
    color: var(--accent-primary);
  }
  .t-menu {
    position: absolute;
    z-index: 50;
    right: 0;
    top: 68px;
    width: 360px;
    max-height: 360px;
    overflow-y: auto;
    padding: 6px;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-panel);
    box-shadow: none;
  }
  .t-opt {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    text-align: left;
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    cursor: pointer;
  }
  .t-opt:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.05);
  }
  .t-opt.current {
    background: var(--c-raised);
    border-color: var(--c-line);
    border-left: 3px solid rgb(56, 189, 248);}
  .t-opt-ic {
    width: 28px;
    height: 28px;
    border-radius: var(--r-ctl);
    background: var(--c-panel, #181b1f);
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    color: var(--accent-primary);
    font-size: var(--fs-meta);
    flex-shrink: 0;
  }
  .t-opt-info {
    flex: 1;
    min-width: 0;
  }
  .t-opt-info b {
    display: block;
    font-size: var(--fs-small);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .t-opt-info small {
    font-size: var(--fs-meta);
    color: var(--text-dim);
  }
  .t-opt-state {
    font-size: var(--fs-meta);
    font-weight: 700;
  }
  .status-box {
    padding: 8px 14px;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-tag);
    display: flex;
    flex-direction: column;
    justify-content: center;
  }
  .status-box small {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim);
  }
  .status-box strong {
    font-size: var(--fs-body);
    margin-top: 2px;
  }

  /* Actions & Topbar */
  .topbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    align-items: center;
  }
  .roadmap-indicator-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    background: var(--lt-111316, #111316);
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-panel);
    padding: 8px 14px;
  }
  .rm-badge {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 5px 12px;
    border-radius: var(--r-tag);
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--c-raised, #1f2328);
    color: var(--text-dim);
    font-size: var(--fs-meta);
    font-weight: 600;
  }
  .rm-badge.done {
    color: var(--lt-48c78e, #48c78e);
    border-color: rgba(72, 199, 142, 0.35);
  }
  .rm-badge.cur {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .rm-num {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--fs-meta);
    border: 1px solid currentColor;
  }
  .rm-line {
    width: 16px;
    height: 1px;
    background: var(--c-raised, #1f2328);
  }
  .guide-text {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 14px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    color: var(--lt-c9ced4, #c9ced4);
    border-left: 3px solid rgb(56, 189, 248);}

  /* Draw cards */
  .draw-actions {
    display: flex;
    gap: 8px;
    align-items: center;
  }
  .draw-body {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 12px;
  }
  .draw-group {
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-panel);
    background: var(--lt-111316, #111316);
    overflow: hidden;
  }
  .dg-title {
    padding: 8px 12px;
    font-size: var(--fs-meta);
    font-weight: 700;
    background: var(--c-panel, #181b1f);
    border-bottom: 1px solid var(--c-raised, #1f2328);
    color: var(--accent-primary);
  }
  .dg-gang {
    padding: 8px 12px;
    font-size: var(--fs-small);
    font-weight: 700;
    border-top: 1px solid var(--c-panel, #181b1f);
    color: var(--lt-ffffff, #fff);
  }
  .dg-gang:first-of-type {
    border-top: 0;
  }

  /* Overview cards */
  .overview-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
  }
  .card-box {
    background: var(--bg-surface, #15171b);
    border: 1px solid var(--c-raised, #1f2328);
    border-radius: var(--r-panel);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .card-box h4 {
    margin: 0 0 4px;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--accent-primary);
  }
  .info-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 0;
    border-bottom: 1px solid var(--c-panel, #181b1f);
    font-size: var(--fs-small);
  }
  .info-row span {
    color: var(--text-dim);
  }
  .info-row b {
    color: var(--lt-ffffff, #fff);
  }

  /* Activity Log */
  .log {
    padding: 4px 0;
  }
  .log-row {
    display: flex;
    gap: 14px;
    padding: 8px 18px;
    font-size: var(--fs-small);
    border-top: 1px solid var(--c-panel, #181b1f);
    color: var(--text-dim);
  }
  .log-row:first-child {
    border-top: 0;
  }
  .log-t {
    font-family: var(--font-mono);
    color: var(--accent-primary);
  }

  /* Export buttons */
  .export-btns {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .export-btns .lbl {
    font-size: var(--fs-meta);
    letter-spacing: 0.01em;
    color: var(--text-dim);
    margin-right: 4px;
  }

  /* Modal */
  .modal-backdrop {
    position: fixed;
    inset: 0;
    z-index: 900;
    background: rgba(var(--ltc-8-12-20, 8, 12, 20), 0.85);
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .modal {
    width: min(500px, 92%);
    padding: 22px;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-panel);
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .m-title {
    font-weight: 700;
    font-size: var(--fs-small);
    color: var(--accent-primary);
  }
  .m-teams {
    font-size: var(--fs-emph);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .m-teams span {
    color: var(--text-dim);
    font-size: var(--fs-meta);
    margin: 0 6px;
  }
  .score-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }

  /* Helpers */
  .seg {
    display: inline-flex;
    border: 1px solid var(--c-hover, #272b31);
    border-radius: var(--r-ctl);
    overflow: hidden;
    width: 100%;
  }
  .seg button {
    flex: 1;
    padding: 8px 12px;
    background: var(--c-panel, #181b1f);
    color: var(--text-dim);
    border: 0;
    font-size: var(--fs-meta);
    font-weight: 700;
    cursor: pointer;
  }
  .seg button + button {
    border-left: 1px solid var(--c-hover, #272b31);
  }
  .seg button.active {
    background: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
  }
  .warn-box {
    padding: 12px 14px;
    border: 1px dashed var(--c-line);
    background: var(--c-raised);
    border-radius: var(--r-ctl);
    color: var(--lt-fbbf24, #fbbf24);
    font-size: var(--fs-small);
    line-height: 1.5;
    border-left: 3px solid rgb(251, 191, 36);}
  .mini-steps {
    margin: 8px 0 10px 18px;
    padding: 0;
    line-height: 1.6;
    color: var(--text-dim);
  }
  .banner {
    padding: 10px 14px;
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    border: 1px solid;
  }
  .banner.error {
    border-color: var(--c-line);
    background: var(--c-raised);
    color: #f87171;
    border-left: 3px solid rgb(239, 68, 68);}
  .banner.info {
    border-color: var(--c-line);
    background: var(--c-raised);
    color: var(--lt-48c78e, #48c78e);
    border-left: 3px solid rgb(72, 199, 142);}
  .btn-mini {
    min-height: 30px;
    padding: 0 12px;
    font-size: var(--fs-meta);
  }
  .tb-move {
    min-height: 26px;
    width: 28px;
    padding: 0;
  }
  .clear-reg {
    margin-top: 6px;
  }

  @media (max-width: 900px) {
    .overview-grid {
      grid-template-columns: 1fr;
    }
  }
</style>

