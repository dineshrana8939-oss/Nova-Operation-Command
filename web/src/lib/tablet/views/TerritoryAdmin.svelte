<script>
  // Admin tablet → Territory → Auction Results.
  // The LIST has one row per auction (one run of a Gang Territory Auction event). "View result" opens that auction: which gang
  // bought which territory, for how much, and every lot with its bids. (The server stores one row per lot; they are grouped here.)
  import { onMount } from 'svelte';
  import { defaultPageSize } from '../../adminPrefs.js';
  import { getAuctionHistory } from '../../api/territory.js';
  import { territoryState, refreshTerritoryState } from '../../territory/territoryStore.js';
  import Icon from '../ui/Icon.svelte';
  import GangLogo from '../ui/GangLogo.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import { money } from '../../territory/territoryRender.js';
  import '../tablet-theme.css';

  let lots = [];
  let loaded = false;
  let page = 1;
  let size = defaultPageSize([10, 15, 25, 50]);
  let openKey = null;                       // the auction being looked at (null = the list)

  onMount(() => { refreshTerritoryState(); load(); });
  async function load() {
    const r = await getAuctionHistory(null);
    if (r && r.ok) lots = r.auctions || [];
    loaded = true;
  }

  $: gangByName = new Map(($territoryState.gangs || []).map((g) => [g.name, g]));
  const gangOf = (l) => {
    const g = gangByName.get(l.winning_gang) || {};
    return { name: l.winning_gang, label: l.winningLabel || g.label || l.winning_gang, logo: g.logo || null, color: g.color || null };
  };

  // one auction = one run of one event
  $: auctions = (() => {
    const by = new Map();
    for (const l of lots) {
      const key = `${l.event_id}:${l.run_id || 0}`;
      let a = by.get(key);
      if (!a) { a = { key, eventId: l.event_id, name: l.event_name || `Auction #${l.event_id}`, startedAt: l.started_at, endedAt: l.ended_at, lots: [] }; by.set(key, a); }
      a.lots.push(l);
      if (l.started_at && (!a.startedAt || l.started_at < a.startedAt)) a.startedAt = l.started_at;
      if (l.ended_at && (!a.endedAt || l.ended_at > a.endedAt)) a.endedAt = l.ended_at;
    }
    const out = [...by.values()];
    for (const a of out) {
      a.lots.sort((x, y) => (x.lot_index || 0) - (y.lot_index || 0));
      const sold = a.lots.filter((l) => l.status === 'WON');
      a.sold = sold.length;
      a.total = sold.reduce((n, l) => n + (Number(l.final_bid) || 0), 0);
      const win = new Map();
      for (const l of sold) {
        const g = gangOf(l);
        const w = win.get(g.name) || { ...g, territories: [], paid: 0 };
        w.territories.push(l.territory_name || l.territory_id);
        w.paid += Number(l.final_bid) || 0;
        win.set(g.name, w);
      }
      a.winners = [...win.values()].sort((x, y) => y.paid - x.paid);
      a.unsold = a.lots.filter((l) => l.status === 'UNSOLD').map((l) => l.territory_name || l.territory_id);
      a.state = a.sold === a.lots.length ? 'Completed' : a.sold > 0 ? 'Partly sold' : 'Nothing sold';
    }
    return out.sort((x, y) => (y.endedAt || 0) - (x.endedAt || 0));
  })();

  $: paged = auctions.slice((page - 1) * size, page * size);
  $: open = openKey ? auctions.find((a) => a.key === openKey) || null : null;
  $: totals = { auctions: auctions.length, sold: auctions.reduce((n, a) => n + a.sold, 0), paid: auctions.reduce((n, a) => n + a.total, 0) };
  const when = (ts) => (ts ? new Date(ts * 1000).toLocaleString([], { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—');
  const stateClass = (s) => (s === 'Completed' ? 'won' : s === 'Partly sold' ? 'part' : 'unsold');
</script>

<div class="panel view-enter">
  <div class="panel-header">
    <span class="panel-title">
      {#if open}
        <button type="button" class="back" on:click={() => (openKey = null)}><Icon name="chevronDown" size={13} /> All auctions</button>
        <span class="crumb">{open.name}</span>
      {:else}
        <Icon name="fileText" size={14} /> Auction Results
      {/if}
    </span>
    <button type="button" class="btn btn-sm btn-steel" on:click={load}><Icon name="refresh" size={13} /> Refresh</button>
  </div>

  <div class="panel-body">
    {#if open}
      <!-- ── one auction: who bought what ── -->
      <div class="sum">
        <div><span>Held</span><b class="small">{when(open.endedAt || open.startedAt)}</b></div>
        <div><span>Territories</span><b>{open.lots.length}</b></div>
        <div><span>Sold</span><b class="ok">{open.sold}</b></div>
        <div><span>Total paid</span><b>{money(open.total)}</b></div>
      </div>

      <h4 class="sec">Who bought what</h4>
      {#if open.winners.length}
        <div class="winners">
          {#each open.winners as w (w.name)}
            <article class="win" style={w.color ? `--c:${w.color}` : ''}>
              <header>
                <GangLogo logo={w.logo} label={w.label} size={34} accentColor={w.color} />
                <div><b>{w.label}</b><small>{w.territories.length} territor{w.territories.length === 1 ? 'y' : 'ies'} · {money(w.paid)}</small></div>
              </header>
              <ul>{#each w.territories as t}<li>{t}</li>{/each}</ul>
            </article>
          {/each}
        </div>
      {:else}
        <p class="muted pad">Nobody bought a territory in this auction.</p>
      {/if}
      {#if open.unsold.length}<p class="muted pad">Not sold: {open.unsold.join(', ')}.</p>{/if}

      <h4 class="sec">Every lot</h4>
      <div class="tbl-wrap">
        <table class="tbl">
          <thead><tr><th class="num">Lot</th><th>Territory</th><th>Winning gang</th><th>Winning player</th><th class="num">Starting bid</th><th class="num">Final bid</th><th class="num">Bids</th><th>Result</th></tr></thead>
          <tbody>
            {#each open.lots as l (l.id)}
              {@const g = gangOf(l)}
              <tr>
                <td class="num">{l.lot_index ?? '—'}</td>
                <td class="strong">{l.territory_name || l.territory_id}</td>
                <td>{#if l.status === 'WON'}<span class="gang">{#if g.color}<i style="background:{g.color}"></i>{/if}{g.label}</span>{:else}—{/if}</td>
                <td>{l.winning_player || '—'}</td>
                <td class="num">{money(l.starting_bid)}</td>
                <td class="num">{l.status === 'WON' ? money(l.final_bid) : '—'}</td>
                <td class="num">{l.bid_count}</td>
                <td><span class="st {String(l.status || '').toLowerCase()}">{l.status === 'WON' ? 'Sold' : l.status === 'UNSOLD' ? 'Unsold' : l.status}</span></td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else}
      <!-- ── the list: one row per auction ── -->
      <div class="sum">
        <div><span>Auctions held</span><b>{totals.auctions}</b></div>
        <div><span>Territories sold</span><b class="ok">{totals.sold}</b></div>
        <div><span>Total paid</span><b>{money(totals.paid)}</b></div>
      </div>

      <TablePager top bind:page bind:pageSize={size} total={auctions.length} noun="auctions" />
      <div class="tbl-wrap">
        <table class="tbl">
          <thead><tr><th>Auction</th><th>Held</th><th class="num">Territories</th><th class="num">Sold</th><th class="num">Total paid</th><th>Bought by</th><th>Result</th><th class="act"></th></tr></thead>
          <tbody>
            {#each paged as a (a.key)}
              <tr class="clickable" on:click={() => (openKey = a.key)}>
                <td class="strong">{a.name}<small>#{a.eventId}</small></td>
                <td>{when(a.endedAt || a.startedAt)}</td>
                <td class="num">{a.lots.length}</td>
                <td class="num">{a.sold}</td>
                <td class="num">{a.total ? money(a.total) : '—'}</td>
                <td>
                  {#if a.winners.length}
                    <span class="chips">{#each a.winners as w (w.name)}<span class="chip" style={w.color ? `--c:${w.color}` : ''}>{w.label}</span>{/each}</span>
                  {:else}—{/if}
                </td>
                <td><span class="st {stateClass(a.state)}">{a.state}</span></td>
                <td class="act"><button type="button" class="btn btn-sm btn-steel" on:click|stopPropagation={() => (openKey = a.key)}>View result</button></td>
              </tr>
            {/each}
            {#if loaded && !auctions.length}<tr><td colspan="8" class="muted">No territory auctions yet. Publish a Gang Territory Auction event and its results appear here.</td></tr>{/if}
            {#if !loaded}<tr><td colspan="8" class="muted">Loading…</td></tr>{/if}
          </tbody>
        </table>
      </div>
    {/if}
  </div>
</div>

<style>
  /* Fills use the theme tokens so the page follows the chosen background and accent. */
  .back { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px; margin-right: 10px; border-radius: var(--r-ctl, 8px); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.3)); background: var(--glass-head, transparent); color: var(--text-dim, #c9ced4); font-size: var(--fs-small); font-weight: 600; cursor: pointer; }
  .back :global(svg) { transform: rotate(90deg); }
  .back:hover { border-color: var(--accent-primary); color: var(--text-main, #fff); }
  .crumb { font-weight: 600; }

  .sum { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px; margin-bottom: 14px; }
  .sum > div { display: flex; flex-direction: column; gap: 3px; padding: 11px 14px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.2)); border-radius: var(--r-ctl, 8px); }
  .sum span { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .sum b { font-family: var(--font-display); font-size: var(--fs-section); font-weight: 600; font-variant-numeric: tabular-nums; }
  .sum b.small { font-size: var(--fs-emph); line-height: 1.4; }
  .sum b.ok { color: #46c98b; }

  .sec { margin: 18px 2px 10px; font-size: var(--fs-body); font-weight: 600; }
  .muted { color: var(--text-muted, #aeb5bd); }
  .pad { margin: 4px 2px 10px; font-size: var(--fs-small); }

  .winners { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 10px; }
  .win { padding: 12px 14px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); border-left: 4px solid var(--c, var(--accent-primary)); border-radius: var(--r-ctl, 8px); }
  .win header { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
  .win header b { display: block; font-size: var(--fs-body); }
  .win header small { color: var(--text-muted, #8d949c); font-size: var(--fs-meta); }
  .win ul { margin: 0; padding: 0; list-style: none; display: flex; flex-wrap: wrap; gap: 6px; }
  .win li { padding: 3px 10px; border-radius: 999px; font-size: var(--fs-small); font-weight: 600; background: var(--glass-head, rgba(255, 255, 255, 0.06)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); }

  .tbl-wrap { overflow-x: auto; border: 1px solid var(--c-line, #2a2e35); border-radius: var(--r-panel); }
  .tbl { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  .tbl th { text-align: left; padding: var(--tbl-th-y) var(--tbl-x); background: var(--c-panel); color: var(--text-muted); border-bottom: 1px solid var(--c-line); white-space: nowrap; font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0; }
  .tbl td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft); font-variant-numeric: tabular-nums; vertical-align: middle; }
  .tbl tr:last-child td { border-bottom: 0; }
  .tbl .num { text-align: right; }
  .tbl .act { text-align: right; width: 1%; white-space: nowrap; }
  .tbl .strong { font-weight: 600; }
  .tbl .strong small { margin-left: 8px; font-weight: 400; color: var(--text-muted, #8d949c); }
  .tbl tr.clickable { cursor: pointer; }
  .tbl tr.clickable:hover td { background: var(--glass-head, rgba(255, 255, 255, 0.04)); }
  .gang { display: inline-flex; align-items: center; gap: 7px; font-weight: 600; }
  .gang i { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
  .chips { display: inline-flex; flex-wrap: wrap; gap: 5px; }
  .chip { padding: 2px 9px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; background: var(--glass-head, rgba(255, 255, 255, 0.06)); border: 1px solid var(--c, var(--tablet-border, rgba(110, 140, 180, 0.3))); }
  .st { padding: 2px 9px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; background: rgba(255, 255, 255, 0.07); white-space: nowrap; }
  .st.won { color: #46c98b; background: rgba(70, 201, 139, 0.14); }
  .st.part { color: #7bb6f2; background: rgba(123, 182, 242, 0.14); }
  .st.unsold { color: #ffc857; background: rgba(255, 200, 87, 0.12); }
</style>
