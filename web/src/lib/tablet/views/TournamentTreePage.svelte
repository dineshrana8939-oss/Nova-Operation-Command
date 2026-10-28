<script>
  // Admin tablet → Tournaments → Tournament Tree.
  // Pick any TDM tournament and its live tree is shown (groups, knockout bracket, current / next match, champion). Switching the
  // pick re-draws the tree. The tree is the same component the gang Event Status panel uses, so both always agree.
  // Reporting a score, shuffling the draw and exporting stay in the Tournaments page ("Open in Tournaments").
  import { onMount, onDestroy } from 'svelte';
  import { currentView, tournamentOpenId } from '../../stores.js';
  import { listTournaments, getTournament } from '../../api/tournament.js';
  import Icon from '../ui/Icon.svelte';
  import TournamentTree from '../../tournament/TournamentTree.svelte';
  import TournamentTreePreview from '../../tournament/TournamentTreePreview.svelte';
  import '../tablet-theme.css';

  let list = [];
  let loading = true;
  let selectedId = null;
  let t = null;
  let filter = 'ALL';            // ALL | LIVE | UPCOMING | COMPLETED
  let error = '';
  let poll;
  let destroyed = false;
  let loadingTree = false;

  const ORDER = { LIVE: 0, SCHEDULED: 1, DRAFT: 2, COMPLETED: 3, CANCELLED: 4 };
  const bucket = (s) => (s === 'LIVE' ? 'LIVE' : s === 'COMPLETED' || s === 'CANCELLED' ? 'COMPLETED' : 'UPCOMING');

  $: sorted = [...list].sort((a, b) => (ORDER[a.status] ?? 9) - (ORDER[b.status] ?? 9) || (b.id - a.id));
  $: shown = sorted.filter((x) => filter === 'ALL' || bucket(x.status) === filter);
  $: counts = { ALL: list.length, LIVE: list.filter((x) => x.status === 'LIVE').length, UPCOMING: list.filter((x) => bucket(x.status) === 'UPCOMING').length, COMPLETED: list.filter((x) => bucket(x.status) === 'COMPLETED').length };
  $: current = list.find((x) => x.id === selectedId) || null;
  $: drawn = !!t && (t.matches || []).length > 0;
  $: played = t ? (t.matches || []).filter((m) => m.status === 'COMPLETE').length : 0;
  $: total = t ? (t.matches || []).length : 0;
  $: pct = total ? Math.round((played / total) * 100) : 0;
  $: liveMatch = t?.currentMatch ? (t.matches || []).find((m) => m.id === t.currentMatch.id) : null;

  async function loadList() {
    const res = await listTournaments();
    if (destroyed) return;
    if (res && res.ok) list = res.tournaments || [];
    else if (res) error = res.error || '';
    loading = false;
  }
  async function loadTree() {
    if (!selectedId) { t = null; return; }
    const res = await getTournament(selectedId);
    if (destroyed) return;
    if (res && res.ok) { t = res.tournament; error = ''; }
    else if (res) error = res.error || 'Could not load the tournament.';
    loadingTree = false;
  }
  async function pick(id) {
    if (id === selectedId) return;
    selectedId = id; t = null; loadingTree = true;
    await loadTree();
  }
  function openInTournaments() {
    if (!selectedId) return;
    tournamentOpenId.set(selectedId);
    currentView.set('tournaments');
  }

  onMount(async () => {
    await loadList();
    // start on what matters most: a live tournament, otherwise the next upcoming one, otherwise the latest
    const first = sorted[0];
    if (first) await pick(first.id);
    // refresh quickly while the open tournament is live, slowly otherwise; never while the window is hidden
    poll = setInterval(() => {
      if (typeof document !== 'undefined' && document.hidden) return;
      loadList();
      if (selectedId && (current?.status === 'LIVE' || !t)) loadTree();
    }, 3000);
  });
  onDestroy(() => { destroyed = true; clearInterval(poll); });
</script>

<div class="panel view-enter">
  <div class="panel-header">
    <div class="panel-heading">
      <div class="panel-title"><Icon name="route" size={15} /> <span>Tournament Tree</span></div>
      <div class="panel-subtitle">Pick a tournament to see its groups, bracket and results as they happen.</div>
    </div>
    {#if selectedId}<button type="button" class="btn btn-steel" on:click={openInTournaments}><Icon name="trophy" size={13} /> Open in Tournaments</button>{/if}
  </div>

  <div class="panel-body">
    {#if loading}
      <div class="empty">Loading tournaments…</div>
    {:else if !list.length}
      <div class="empty">No tournament yet. Create one in <b>Tournaments</b>, shuffle and lock the draw, and its tree appears here.</div>
    {:else}
      <div class="pick-head">
        <div class="filters" role="group" aria-label="Filter tournaments">
          {#each [['ALL', 'All'], ['LIVE', 'Live'], ['UPCOMING', 'Upcoming'], ['COMPLETED', 'Completed']] as [id, label]}
            <button type="button" class:active={filter === id} on:click={() => (filter = id)}>{label}<span class="cnt">{counts[id]}</span></button>
          {/each}
        </div>
      </div>

      <div class="picker" role="listbox" aria-label="Tournaments">
        {#each shown as x (x.id)}
          <button type="button" role="option" aria-selected={x.id === selectedId} class="pcard" class:on={x.id === selectedId} class:live={x.status === 'LIVE'} on:click={() => pick(x.id)}>
            <span class="pname">{x.name}</span>
            <span class="pmeta">
              {#if x.status === 'LIVE'}<i class="dot"></i>Live — {x.playedMatches}/{x.totalMatches} matches
              {:else if x.status === 'COMPLETED'}Champion: {x.championLabel || '—'}
              {:else if x.status === 'CANCELLED'}Cancelled
              {:else}{x.drawLocked ? 'Scheduled' : 'Draft'}{#if x.startLabel} — {x.startLabel}{/if}{/if}
            </span>
          </button>
        {:else}
          <div class="empty small">Nothing in this group.</div>
        {/each}
      </div>

      {#if error}<div class="error" style="margin: 10px 0">{error}</div>{/if}

      {#if t}
        <div class="tiles">
          <div><span>Tournament</span><b class="name">{t.name}</b></div>
          <div><span>Status</span><b>{t.status === 'LIVE' ? 'Live' : t.status === 'COMPLETED' ? 'Completed' : t.status === 'CANCELLED' ? 'Cancelled' : drawn && t.drawLocked ? 'Scheduled' : 'Draft'}</b></div>
          <div><span>Stage</span><b>{t.stage || t.currentStage || '—'}</b></div>
          <div class="wide">
            <span>Matches played</span>
            <b>{played} <small>of {total}</small></b>
            <div class="bar" role="progressbar" aria-valuenow={pct} aria-valuemin="0" aria-valuemax="100"><i style="width:{pct}%"></i></div>
          </div>
          <div><span>{t.status === 'COMPLETED' ? 'Champion' : liveMatch ? 'On the arena now' : 'Gangs'}</span><b class="name">{#if t.status === 'COMPLETED'}{t.championLabel || '—'}{:else if liveMatch}Match {liveMatch.order ?? ''}{:else}{(t.gangs || []).length || current?.gangCount || '—'}{/if}</b></div>
        </div>

        <div class="tree-wrap">
          {#if drawn}
            <TournamentTree {t} showTitle={false} selectable={false} />
          {:else}
            <TournamentTreePreview
              qualifiers={(t.cfg?.groupCount || 1) * (t.cfg?.advance || 2)}
              title="Knockout bracket"
              message="The draw is not locked yet. Shuffle and lock it in Tournaments and the real tree fills in here."
            />
          {/if}
        </div>
      {:else if loadingTree}
        <div class="empty">Loading the tree…</div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .empty { padding: 36px; text-align: center; color: var(--text-dim, #aeb5bd); font-size: var(--fs-body); }
  .empty.small { padding: 12px; }
  .pick-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
  .filters { display: flex; gap: 6px; flex-wrap: wrap; }
  .filters button { display: inline-flex; align-items: center; gap: 6px; padding: 6px 14px; border-radius: var(--r-ctl); border: 1px solid var(--tablet-border, var(--c-line)); background: var(--glass-head, transparent); color: var(--text-dim); font-size: var(--fs-small); font-weight: 600; cursor: pointer; }
  .filters button.active { background: var(--accent-primary); border-color: var(--accent-primary); color: var(--on-accent, #fff); }
  .filters .cnt { font-size: var(--fs-meta); padding: 1px 7px; border-radius: 999px; background: rgba(var(--ink-rgb, 255, 255, 255), 0.15); }

  /* one card per tournament; a long list scrolls sideways instead of pushing the tree down */
  .picker { display: flex; gap: 8px; overflow-x: auto; padding-bottom: 6px; margin-bottom: 14px; }
  .pcard { flex: 0 0 auto; width: 250px; display: flex; flex-direction: column; gap: 4px; text-align: left; padding: 11px 14px; border-radius: var(--r-ctl, 8px); border: 1px solid var(--tablet-border, var(--c-line)); background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); color: inherit; cursor: pointer; }
  .pcard:hover { border-color: var(--accent-primary); }
  .pcard.on { border-color: var(--accent-primary); background: var(--c-hover); }
  .pname { font-size: var(--fs-body); font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .pmeta { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pcard.live .pmeta { color: #48c78e; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #48c78e; display: inline-block; }

  .tiles { display: grid; grid-template-columns: 1.4fr 0.8fr 1fr 1.6fr 1fr; gap: 10px; margin-bottom: 14px; }
  .tiles > div { display: flex; flex-direction: column; gap: 4px; padding: 11px 14px; border-radius: var(--r-ctl, 8px); border: 1px solid var(--tablet-border, var(--c-line)); background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); min-width: 0; }
  .tiles span { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .tiles b { font-family: var(--font-display); font-size: var(--fs-title); font-weight: 600; font-variant-numeric: tabular-nums; }
  .tiles b.name { font-size: var(--fs-emph); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tiles b small { font-size: var(--fs-small); font-weight: 500; color: var(--text-muted, #8d949c); }
  .bar { height: 6px; border-radius: 3px; background: var(--glass-head, rgba(255, 255, 255, 0.08)); overflow: hidden; }
  .bar i { display: block; height: 100%; background: var(--accent-primary); border-radius: 3px; }
  .tree-wrap { min-width: 0; }
  @media (max-width: 1150px) { .tiles { grid-template-columns: 1fr 1fr; } }
</style>
