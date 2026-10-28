<script>
  import { sameData } from '../../util/stable.js';
  import { onMount, onDestroy } from 'svelte';
  import { getGangLeaderboard } from '../../api/gang.js';
  import Icon from '../../tablet/ui/Icon.svelte';
  import GangLogo from '../../tablet/ui/GangLogo.svelte';
  import StatStrip from './StatStrip.svelte';
  import TablePager from '../../tablet/ui/TablePager.svelte';
  import '../../tablet/ui/leaderboard.css';

  export let myGangName = null;

  // Every sub-tab is described by one column list: the table, the podium, the
  // "Your Gang Standing" tiles and the sort options all read it, so a stat can't
  // show in one place and be missing from another. Keys match statsFor() below.
  //   fmt: 'win' (green) | 'loss' (dim) | 'money' | undefined (plain number)
  //   podium: stats shown on the top-3 cards besides the win count and win rate
  const KINDS = [
    { id: 'CONVOY', label: 'Convoy', winLabel: 'Captured', icon: 'truck', podium: ['joined'],
      cols: [
        { key: 'failed', label: 'Failed', fmt: 'loss', icon: 'close' },
        { key: 'joined', label: 'Joined', icon: 'users' },
      ] },
    { id: 'HOT_CARGO', label: 'Hot Cargo', winLabel: 'Completed', icon: 'flame', podium: ['failed'],
      cols: [{ key: 'failed', label: 'Failed', fmt: 'loss', icon: 'close' }] },
    { id: 'GANG_AIRDROP', label: 'Gang Airdrop', winLabel: 'Completed', icon: 'parachute', podium: ['failed'],
      cols: [{ key: 'failed', label: 'Failed', fmt: 'loss', icon: 'close' }] },
    { id: 'GANG_RACE', label: 'Gang Rally', winLabel: 'Wins', icon: 'flag', podium: ['tokens'],
      cols: [
        { key: 'completed', label: 'Completed', icon: 'flag' },
        { key: 'failed', label: 'Failed', fmt: 'loss', icon: 'close' },
        { key: 'tokens', label: 'Tokens Won', fmt: 'win', icon: 'zap' },
        { key: 'joined', label: 'Joined', icon: 'users' },
      ] },
    { id: 'TDM', label: 'TDM', winLabel: 'Wins', icon: 'flag', podium: ['kills'],
      cols: [
        { key: 'failed', label: 'Losses', fmt: 'loss', icon: 'close' },
        { key: 'kills', label: 'Kills', icon: 'crosshair' },
        { key: 'deaths', label: 'Deaths', icon: 'warning' },
        { key: 'kd', label: 'K/D', icon: 'shield' },
        { key: 'tournamentWins', label: 'Tourn. Wins', fmt: 'win', icon: 'crown' },
        { key: 'tournamentPlayed', label: 'Tourn. Played', icon: 'list', noTile: true },
        { key: 'joined', label: 'Matches', icon: 'users' },
      ] },
    { id: 'CONTAINER_WARS', label: 'Container Wars', winLabel: 'Containers Won', icon: 'box', podium: ['totalSpend'],
      cols: [
        { key: 'eventsWon', label: 'Events Won', fmt: 'win', icon: 'crown' },
        { key: 'failed', label: 'Failed', fmt: 'loss', icon: 'close' },
        { key: 'totalSpend', label: 'Total Spend', fmt: 'money', icon: 'box' },
        { key: 'joined', label: 'Joined', icon: 'users' },
      ] },
  ];
  let activeKindId = 'CONVOY';
  $: activeKind = KINDS.find((k) => k.id === activeKindId) || KINDS[0];
  $: colCount = 7 + activeKind.cols.length; // #, gang, leader, members, gang xp, wins, win rate + extras

  let sortMode = 'CAPTURES'; // 'CAPTURES' | 'WINRATE' | 'XP' | 'SPEND' (Container Wars only)
  $: if (sortMode === 'SPEND' && activeKindId !== 'CONTAINER_WARS') sortMode = 'CAPTURES';
  let searchQuery = '';
  let gangs = [];
  let loading = true;
  let pollInterval;

  // Pagination for 100+ gangs
  let currentPage = 1;
  let pageSize = 15;

  const fmtMoney = (n) => `$${(Number(n) || 0).toLocaleString()}`;
  const fmtCell = (c, v) => (c.fmt === 'money' ? fmtMoney(v) : v);
  // Gang XP is one balance per gang (not per event kind), so every sub-tab shows the same figure.
  const fmtXp = (n) => (Number(n) || 0).toLocaleString();

  function statsFor(gang, kindId) {
    const s = gang.stats || {};
    if (kindId === 'HOT_CARGO') return { wins: s.HOT_CARGO?.completed || 0, failed: s.HOT_CARGO?.failed || 0 };
    if (kindId === 'GANG_AIRDROP') return { wins: s.GANG_AIRDROP?.completed || 0, failed: s.GANG_AIRDROP?.failed || 0 };
    if (kindId === 'GANG_RACE') {
      const r = s.GANG_RACE || {};
      return { joined: r.joined || 0, completed: r.completed || 0, wins: r.wins || 0, tokens: r.tokens || 0, failed: r.failed || 0 };
    }
    if (kindId === 'TDM') {
      const t = s.TDM || {};
      const kills = t.kills || 0;
      const deaths = t.deaths || 0;
      return {
        joined: t.matches || 0, wins: t.wins || 0, failed: t.losses || 0, kills, deaths,
        kd: deaths === 0 ? kills.toFixed(2) : (kills / deaths).toFixed(2),
        tournamentWins: t.tournamentWins || 0, tournamentPlayed: t.tournamentPlayed || 0,
      };
    }
    if (kindId === 'CONTAINER_WARS') {
      const c = s.CONTAINER_WARS || {};
      // wins = containers won; the win rate is events won out of events the
      // gang actually bid in, not containers over events.
      return {
        joined: c.joined || 0, wins: c.wins || 0, eventsWon: c.completed || 0, failed: c.failed || 0,
        totalSpend: c.totalSpend || 0, decidedCount: c.joined || 0, rateWins: c.completed || 0,
      };
    }
    return { joined: s.convoysJoined || 0, wins: s.convoysCaptured || 0, failed: s.convoysFailed || 0 };
  }

  // Events that count towards the win rate: finished races, bid-in auctions,
  // otherwise wins + losses.
  function decided(stats) {
    if (stats.decidedCount != null) return stats.decidedCount;
    if (stats.completed != null) return stats.completed || 0;
    return (stats.wins || 0) + (stats.failed || 0);
  }

  function winRatePct(stats) {
    const d = decided(stats);
    return d === 0 ? 0 : Math.min(100, Math.round(((stats.rateWins ?? stats.wins) / d) * 100));
  }

  // Rank and sort gangs
  $: rankedGangs = gangs
    .map((g) => ({ ...g, kindStats: statsFor(g, activeKindId) }))
    .sort((a, b) => {
      if (sortMode === 'SPEND') {
        const d = (b.kindStats.totalSpend || 0) - (a.kindStats.totalSpend || 0);
        if (d !== 0) return d;
      }
      if (sortMode === 'XP') {
        const d = (b.xp || 0) - (a.xp || 0);
        if (d !== 0) return d;
      }
      if (sortMode === 'WINRATE') {
        const wrA = winRatePct(a.kindStats);
        const wrB = winRatePct(b.kindStats);
        if (wrA !== wrB) return wrB - wrA;
      }
      return b.kindStats.wins - a.kindStats.wins;
    });

  $: myGangIndex = myGangName ? rankedGangs.findIndex((g) => g.name === myGangName) : -1;
  $: myGangData = myGangIndex >= 0 ? rankedGangs[myGangIndex] : null;

  // "Your Gang Standing" tiles: rank, wins, every column of this sub-tab, win rate.
  $: myGangStats = (() => {
    const ks = myGangData ? myGangData.kindStats : statsFor({}, activeKindId);
    return [
      { label: 'Gang Rank', value: myGangData ? `#${myGangIndex + 1}` : '—', icon: 'trophy' },
      { label: 'Gang XP', value: fmtXp(myGangData ? myGangData.xp : 0), icon: 'zap' },
      { label: activeKind.winLabel, value: ks.wins || 0, icon: 'check' },
      ...activeKind.cols.filter((c) => !c.noTile).map((c) => ({ label: c.label, value: fmtCell(c, ks[c.key] ?? 0), icon: c.icon })),
      { label: 'Win Rate', value: decided(ks) === 0 ? '—' : `${winRatePct(ks)}%`, icon: 'activity' },
    ];
  })();

  // Search filter
  $: filteredGangs = rankedGangs.filter((g) => {
    if (!searchQuery.trim()) return true;
    const q = searchQuery.toLowerCase().trim();
    return (g.label || g.name || '').toLowerCase().includes(q) || (g.leaderName || '').toLowerCase().includes(q);
  });

  // Pagination slice
  $: totalCount = filteredGangs.length;
  $: totalPages = Math.max(1, Math.ceil(totalCount / pageSize));
  $: if (currentPage > totalPages) currentPage = totalPages;
  $: paginatedGangs = filteredGangs.slice((currentPage - 1) * pageSize, currentPage * pageSize);

  async function refresh() {
    const res = await getGangLeaderboard();
    const nextGangs = res && res.ok ? res.gangs : [];
    if (!sameData(nextGangs, gangs)) gangs = nextGangs;
    loading = false;
  }

  onMount(() => {
    refresh();
    pollInterval = setInterval(refresh, 8000);
  });
  onDestroy(() => clearInterval(pollInterval));
</script>

<div class="lb leaderboard-view">
  <div class="lb-head">
    <div class="lb-head-text">
      <h2 class="lb-title"><Icon name="trophy" size={18} /> <span>Gang Leaderboard</span></h2>
      <p class="lb-sub">Track gang performance and battle records across convoy activities.</p>
    </div>
    <div class="lb-seg" role="tablist" aria-label="Event kind">
      {#each KINDS as k}
        <button type="button" class:on={activeKindId === k.id} on:click={() => { activeKindId = k.id; currentPage = 1; }}>
          <Icon name={k.icon} size={13} /> {k.label}
        </button>
      {/each}
    </div>
  </div>

  <div class="lb-standing">
    <span class="lb-bar-label">Your gang standing ({myGangName || 'Independent'})</span>
    <StatStrip stats={myGangStats} />
  </div>

  <div class="lb-podium">
    {#each [0, 1, 2] as i}
      {@const g = rankedGangs[i]}
      {#if g}
        <div class="lb-pod r{i + 1}">
          <div class="lb-pod-head">
            <GangLogo logo={g.logo} label={g.label || g.name} accentColor={g.accentColor} size={36} />
            <div class="lb-pod-who">
              <span class="lb-pod-rank">{['1st', '2nd', '3rd'][i]} place</span>
              <span class="lb-pod-name" title={g.label || g.name}>{g.label || g.name || 'Unnamed gang'}</span>
              <span class="lb-pod-sub">Led by {g.leaderName || '—'}</span>
            </div>
          </div>
          <div class="lb-pod-stats">
            <div class="lb-pstat"><b>{g.kindStats.wins}</b><span>{activeKind.winLabel}</span></div>
            <div class="lb-pstat"><b>{fmtXp(g.xp)}</b><span>Gang XP</span></div>
            {#each activeKind.cols.filter((c) => activeKind.podium.includes(c.key)) as c}
              <div class="lb-pstat"><b>{fmtCell(c, g.kindStats[c.key] ?? 0)}</b><span>{c.label}</span></div>
            {/each}
            <div class="lb-pstat"><b>{decided(g.kindStats) === 0 ? '—' : `${winRatePct(g.kindStats)}%`}</b><span>Win rate</span></div>
          </div>
        </div>
      {:else}
        <div class="lb-pod none r{i + 1}">
          <div class="lb-pod-head">
            <div class="lb-pod-empty-ic"><Icon name="shield" size={16} /></div>
            <div class="lb-pod-who">
              <span class="lb-pod-rank">{['1st', '2nd', '3rd'][i]} place</span>
              <span class="lb-pod-name dim">Unclaimed</span>
              <span class="lb-pod-sub">No gang has earned this spot yet</span>
            </div>
          </div>
          <div class="lb-pod-stats">
            <div class="lb-pstat"><b>—</b><span>{activeKind.winLabel}</span></div>
            <div class="lb-pstat"><b>—</b><span>Gang XP</span></div>
            {#each activeKind.cols.filter((c) => activeKind.podium.includes(c.key)) as c}
              <div class="lb-pstat"><b>—</b><span>{c.label}</span></div>
            {/each}
            <div class="lb-pstat"><b>—</b><span>Win rate</span></div>
          </div>
        </div>
      {/if}
    {/each}
  </div>

  <div class="lb-bar">
    <div class="lb-search">
      <Icon name="search" size={13} />
      <input type="text" placeholder="Search gang or leader" bind:value={searchQuery} on:input={() => (currentPage = 1)} />
      {#if searchQuery}
        <button type="button" class="lb-x" on:click={() => (searchQuery = '')} aria-label="Clear search"><Icon name="close" size={12} /></button>
      {/if}
    </div>
    <div class="lb-bar-group">
      <label class="lb-select">
        <span>Rank by</span>
        <select bind:value={sortMode}>
          <option value="CAPTURES">Most {activeKind.winLabel}</option>
          <option value="WINRATE">Best win rate</option>
          <option value="XP">Most Gang XP</option>
          {#if activeKindId === 'CONTAINER_WARS'}<option value="SPEND">Total spend</option>{/if}
        </select>
      </label>
      <button type="button" class="lb-icon-btn" on:click={refresh} title="Refresh rankings" aria-label="Refresh rankings"><Icon name="refresh" size={13} /></button>
    </div>
  </div>

  <div class="lb-card">
    <TablePager top bind:page={currentPage} bind:pageSize total={totalCount} noun="gangs" sizes={[10, 15, 25, 50]} />
    <div class="lb-scroll">
      <table class="lb-table">
        <thead>
          <tr>
            <th class="c-rank">#</th>
            <th class="c-main">Gang</th>
            <th class="c-side">Leader</th>
            <th class="c-num">Members</th>
            <th class="c-num" class:sorted={sortMode === 'XP'} title="Gang XP: earned from events, spent on territory expansion">Gang XP</th>
            <th class="c-num" class:sorted={sortMode === 'CAPTURES'}>{activeKind.winLabel}</th>
            {#each activeKind.cols as c}<th class="c-num" class:sorted={sortMode === 'SPEND' && c.key === 'totalSpend'}>{c.label}</th>{/each}
            <th class="c-num c-wr" class:sorted={sortMode === 'WINRATE'}>Win rate</th>
          </tr>
        </thead>
        <tbody>
          {#if loading}
            <tr><td colspan={colCount} class="lb-cell-empty"><div class="lb-empty"><p>Loading the leaderboard…</p></div></td></tr>
          {:else if paginatedGangs.length === 0}
            <tr>
              <td colspan={colCount} class="lb-cell-empty">
                <div class="lb-empty">
                  <Icon name="trophy" size={26} />
                  {#if searchQuery}
                    <h4>No gang matches “{searchQuery}”</h4>
                    <p>Check the spelling, or search by a leader's name instead.</p>
                    <button type="button" class="lb-btn" on:click={() => (searchQuery = '')}>Clear search</button>
                  {:else}
                    <h4>No activity in this category yet</h4>
                    <p>Gang results show up here after the first event of this kind finishes. Try another category above.</p>
                  {/if}
                </div>
              </td>
            </tr>
          {:else}
            {#each paginatedGangs as g, i (g.name)}
              {@const actualIndex = (currentPage - 1) * pageSize + i}
              {@const isMine = g.name === myGangName}
              <tr class:mine={isMine}>
                <td class="c-rank"><span class="lb-rank" class:r1={actualIndex === 0} class:r2={actualIndex === 1} class:r3={actualIndex === 2}>{actualIndex + 1}</span></td>
                <td>
                  <div class="lb-gang">
                    <GangLogo logo={g.logo} label={g.label || g.name} accentColor={g.accentColor} size={26} />
                    <span class="lb-name">{g.label || g.name || 'Unnamed gang'}</span>
                    {#if isMine}<span class="lb-you">You</span>{/if}
                  </div>
                </td>
                <td><span class="lb-leader" title={g.leaderName || ''}>{g.leaderName || '—'}</span></td>
                <td class="c-num">{g.memberCount || 0}</td>
                <td class="c-num" class:sorted={sortMode === 'XP'}>{fmtXp(g.xp)}</td>
                <td class="c-num win" class:sorted={sortMode === 'CAPTURES'}>{g.kindStats.wins}</td>
                {#each activeKind.cols as c}
                  <td class="c-num" class:win={c.fmt === 'win'} class:loss={c.fmt === 'loss'} class:sorted={sortMode === 'SPEND' && c.key === 'totalSpend'}>{fmtCell(c, g.kindStats[c.key] ?? 0)}</td>
                {/each}
                <td class="c-num" class:sorted={sortMode === 'WINRATE'}>
                  <div class="lb-wr">
                    <div class="lb-wr-track"><div class="lb-wr-fill" style="width:{winRatePct(g.kindStats)}%"></div></div>
                    <span class="lb-wr-pct">{decided(g.kindStats) === 0 ? '—' : `${winRatePct(g.kindStats)}%`}</span>
                  </div>
                </td>
              </tr>
            {/each}
          {/if}
        </tbody>
      </table>
    </div>
  </div>
</div>

<style>
  /* the table, tiles, podium and controls are the shared leaderboard look (tablet/ui/leaderboard.css) */
  .lb-head { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px 16px; }
  .lb-head-text { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .lb-title { display: flex; align-items: center; gap: 9px; margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 700; line-height: 1.2; color: var(--text-main); }
  .lb-title :global(svg) { color: var(--accent-primary); }
  .lb-sub { margin: 0; font-size: var(--fs-small); color: var(--text-muted); }
  .lb-standing { display: flex; flex-direction: column; gap: 6px; }
</style>
