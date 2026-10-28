<script>
  import { sameData } from '../../util/stable.js';
  // Event Status → Tournaments. Read-only view of the very same tournament
  // instances the admin manages (one shared source of truth, see
  // tournament.lua) with the viewer's own gang highlighted throughout.
  import { onMount, onDestroy } from 'svelte';
  import { listTournaments, getTournament } from '../../api/tournament.js';
  import TournamentTree from '../../tournament/TournamentTree.svelte';
  import TablePager from '../../tablet/ui/TablePager.svelte';

  export let myGangName = null;

  let list = [];
  let loading = true;
  let selectedId = null;
  let userPicked = false;
  let t = null;
  let myGang = null;
  let poll;
  let destroyed = false;
  let inFlight = false;

  // Live first, then what's coming up, then the most recent finished one.
  function pickDefault(items) {
    return items.find((x) => x.status === 'LIVE')
      || items.filter((x) => x.status === 'SCHEDULED').sort((a, b) => (a.startAt || 0) - (b.startAt || 0))[0]
      || items.filter((x) => x.status === 'COMPLETED').sort((a, b) => (b.completedAt || 0) - (a.completedAt || 0))[0]
      || null;
  }

  async function refresh() {
    if (inFlight) return;
    inFlight = true;
    try {
      const res = await listTournaments();
      if (destroyed) return;
      if (res && res.ok) {
        const nextList = (res.tournaments || []).filter((x) => x.status !== 'DRAFT' && x.status !== 'CANCELLED');
        if (!sameData(nextList, list)) list = nextList;
        if (!userPicked || !list.some((x) => x.id === selectedId)) {
          const def = pickDefault(list);
          selectedId = def ? def.id : null;
        }
      }
      loading = false;
      if (selectedId != null) {
        const tr = await getTournament(selectedId);
        if (destroyed) return;
        if (tr && tr.ok) { t = tr.tournament; myGang = tr.myGang; }
      } else {
        t = null;
      }
    } finally {
      inFlight = false;
    }
  }

  function pick(id) {
    userPicked = true;
    selectedId = id;
    t = null;
    refresh();
  }

  $: mine = myGangName || myGang;
  $: upcoming = list.filter((x) => x.status === 'SCHEDULED');
  $: live = list.filter((x) => x.status === 'LIVE');
  $: done = list.filter((x) => x.status === 'COMPLETED').sort((a, b) => (b.completedAt || 0) - (a.completedAt || 0));
  // one paged table: live first, then upcoming, then finished (newest first)
  $: tableRows = [...live, ...upcoming, ...done];
  let tPage = 1;
  let tSize = 5;
  $: pagedRows = tableRows.slice((tPage - 1) * tSize, tPage * tSize);
  const STATUS_TEXT = { LIVE: 'Live', SCHEDULED: 'Upcoming', COMPLETED: 'Completed' };
  const fmtDone = (ts) => (ts ? new Date(ts * 1000).toLocaleString([], { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—');

  onMount(() => {
    refresh();
    poll = setInterval(refresh, 2500);
  });
  onDestroy(() => { destroyed = true; clearInterval(poll); });
</script>

<div class="tv">
  <div class="view-header">
    <div class="view-title-col">
      <h2 class="view-title">Tournaments</h2>
      <p class="view-subtitle">Your group, matches, results and road to the final</p>
    </div>
  </div>

  {#if loading}
    <div class="empty">Loading tournaments…</div>
  {:else if list.length === 0}
    <div class="empty">No tournament has been announced yet.</div>
  {:else}
    <div class="tcard">
      <TablePager top bind:page={tPage} bind:pageSize={tSize} total={tableRows.length} noun="tournaments" sizes={[5, 10, 15]} />
      <div class="tscroll">
        <table class="ttable">
          <thead><tr><th>Tournament</th><th>Status</th><th>Details</th><th>Gangs</th><th>Start / completed</th></tr></thead>
          <tbody>
            {#each pagedRows as x (x.id)}
              <tr class:active={x.id === selectedId} on:click={() => pick(x.id)}>
                <td class="tname">{x.name}{#if x.edition > 1 || x.seriesId}<span class="ted">#{x.edition}</span>{/if}</td>
                <td><span class="tpill {x.status.toLowerCase()}">{STATUS_TEXT[x.status] || x.status}</span></td>
                <td class="tdim">{x.status === 'COMPLETED' ? `🏆 ${x.championLabel || '—'}` : (x.status === 'LIVE' ? (x.stage || 'In progress') : 'Registration & draw')}</td>
                <td>{x.gangCount ?? '—'}</td>
                <td class="nowrap">{x.status === 'COMPLETED' ? fmtDone(x.completedAt) : (x.startLabel || '—')}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </div>
    {#if t}
      <TournamentTree {t} myGang={mine} />
    {:else}
      <div class="empty">Loading…</div>
    {/if}
  {/if}
</div>

<style>
  .tv { display: flex; flex-direction: column; gap: 14px; }
  .empty {
    padding: 40px 16px; text-align: center; color: var(--text-dim); font-size: var(--fs-body);
    border: 1px dashed var(--tablet-border-strong); border-radius: var(--radius-md);
  }
  .tcard { background: var(--tablet-panel, #181b1f); border: 1px solid var(--tablet-border-strong, #2a2e35); border-radius: var(--r-panel); overflow: hidden; }
  .tcard :global(.tp) {
    border-left: none;
    border-right: none;
    border-top: none;
    border-radius: 0;
    border-bottom: 1px solid var(--tablet-border-strong, var(--c-line));
  }
  .tscroll { overflow: auto; max-height: 300px; }
  .ttable { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  .ttable th { position: sticky; top: 0; padding: var(--tbl-th-y) var(--tbl-x); background: var(--c-panel); border-bottom: 1px solid var(--c-line); font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0; text-align: left; white-space: nowrap; color: var(--text-muted); }
  .ttable td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft); color: var(--lt-eceef0, #eceef0);
    font-variant-numeric: tabular-nums;
  }
  .ttable tbody tr { cursor: pointer; transition: background 0.12s ease; }
  .ttable tbody tr:hover { background: rgba(var(--ink-rgb, 255, 255, 255), 0.055); }
  .ttable tbody tr.active { background: var(--c-hover); box-shadow: none; }
  .tname { font-weight: 600; letter-spacing: 0.01em; }
  .ted { margin-left: 8px; font-size: var(--fs-meta); color: var(--text-muted); font-family: var(--font-mono); }
  .tdim { color: var(--text-dim) !important; }
  .nowrap { white-space: nowrap; }
  .tpill { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; border: 1px solid var(--tablet-border-strong); color: var(--text-dim); }
  .tpill.live { color: #111111; border-color: rgb(255, 93, 80); background: rgb(255, 93, 80); }
  .tpill.scheduled { color: var(--lt-ffc857, #ffc857); border-color: rgba(255, 200, 87, 0.45); }
  .tpill.completed { color: var(--lt-46c98b, #46c98b); border-color: rgba(70, 201, 139, 0.45); }</style>
