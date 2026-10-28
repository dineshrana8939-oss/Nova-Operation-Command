<script>
  import { sameData } from '../../util/stable.js';
  import { defaultPageSize } from '../../adminPrefs.js';
  import { onMount, onDestroy } from 'svelte';
  import { getGangLeaderboard } from '../../api/gang.js';
  import Icon from '../ui/Icon.svelte';
  import GangLogo from '../ui/GangLogo.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import '../tablet-theme.css';
  import '../ui/leaderboard.css';

  // Shared between the admin tablet's Leaderboard tab and the gang live
  // panel's Leaderboard section — same data, same table, no admin gate
  // (server/modules/callbacks.lua's getGangLeaderboard is open to everyone).
  export let compact = false;
  // Convoy Status panel passes the viewer's own gang name (roster.gangName)
  // so their gang's standing surfaces as KPI cards above the rest, instead
  // of them having to scroll/scan the full list to find their own row.
  export let myGangName = null;

  // Three genuinely different event kinds (roster-based escort vs. two
  // open-participation formats) used to all feed one combined captured/
  // failed count — which in practice meant Hot Cargo and Gang Airdrop never
  // showed up on the leaderboard at all (nothing ever recorded an outcome
  // for them). Each is now tracked separately server-side; this tab strip
  // picks which one's standings are shown, entirely client-side (one fetch
  // already carries every kind's numbers — see statsFor below).
  const KINDS = [
    { id: 'CONVOY', label: 'Convoy', winLabel: 'Captured', icon: 'truck', tracksJoined: true },
    { id: 'HOT_CARGO', label: 'Hot Cargo', winLabel: 'Completed', icon: 'flame', tracksJoined: false },
    { id: 'GANG_AIRDROP', label: 'Gang Airdrop', winLabel: 'Completed', icon: 'parachute', tracksJoined: false },
    { id: 'GANG_RACE', label: 'Gang Rally', winLabel: 'Wins', icon: 'flag', tracksJoined: true },
    { id: 'TDM', label: 'TDM', winLabel: 'Wins', icon: 'flag', tracksJoined: true },
    { id: 'CONTAINER_WARS', label: 'Container Wars', winLabel: 'Containers Won', icon: 'box', tracksJoined: true },
  ];
  let activeKindId = 'CONVOY';
  $: activeKind = KINDS.find((k) => k.id === activeKindId) || KINDS[0];

  // 'CAPTURES': raw win count — rewards volume/activity, an established
  // gang naturally sits at the top. 'WINRATE': captured/(captured+failed)
  // — rewards actually being GOOD, not just active. 'SPEND': Container Wars
  // auction spend.
  const SORT_MODES = [
    { id: 'CAPTURES', label: 'Most Wins' },
    { id: 'SPEND', label: 'Total Spend' },
    { id: 'WINRATE', label: 'Best Win Rate' },
    { id: 'XP', label: 'Most Gang XP' },
  ];
  let sortMode = 'CAPTURES';
  const MIN_DECIDED_FOR_WINRATE = 3;

  let gangs = [];
  let loading = true;
  let pollInterval;

  // The list can hold many gangs, so the table is searchable and paged. The
  // podium and the rank badges always use the gang's rank in the FULL ranking,
  // never its position in the filtered list.
  let searchQuery = '';
  let pageSize = defaultPageSize([10, 15, 25, 50]);
  let currentPage = 1;
  const PAGE_SIZES = [10, 15, 25, 50];

  // Normalizes whichever kind is selected onto the same {joined, wins,
  // failed} shape so the rest of the template/helpers below don't need to
  // know CONVOY's raw fields differ from HOT_CARGO/GANG_AIRDROP's.
  function statsFor(gang, kindId) {
    const s = gang.stats || {};
    if (kindId === 'HOT_CARGO') return { joined: null, wins: (s.HOT_CARGO && s.HOT_CARGO.completed) || 0, failed: (s.HOT_CARGO && s.HOT_CARGO.failed) || 0 };
    if (kindId === 'GANG_AIRDROP') return { joined: null, wins: (s.GANG_AIRDROP && s.GANG_AIRDROP.completed) || 0, failed: (s.GANG_AIRDROP && s.GANG_AIRDROP.failed) || 0 };
    if (kindId === 'GANG_RACE') return { joined: (s.GANG_RACE && s.GANG_RACE.joined) || 0, completed: (s.GANG_RACE && s.GANG_RACE.completed) || 0, wins: (s.GANG_RACE && s.GANG_RACE.wins) || 0, tokens: (s.GANG_RACE && s.GANG_RACE.tokens) || 0, failed: (s.GANG_RACE && s.GANG_RACE.failed) || 0 };
    if (kindId === 'TDM') return {
      joined: (s.TDM && s.TDM.matches) || 0, wins: (s.TDM && s.TDM.wins) || 0, failed: (s.TDM && s.TDM.losses) || 0,
      kills: (s.TDM && s.TDM.kills) || 0, deaths: (s.TDM && s.TDM.deaths) || 0,
      tournamentWins: (s.TDM && s.TDM.tournamentWins) || 0, tournamentPlayed: (s.TDM && s.TDM.tournamentPlayed) || 0,
    };
    if (kindId === 'CONTAINER_WARS') {
      const c = s.CONTAINER_WARS || {};
      // wins = containers won; win rate = events won out of events the gang bid in.
      return {
        joined: c.joined || 0, wins: c.wins || 0, eventsWon: c.completed || 0, failed: c.failed || 0,
        totalSpend: c.totalSpend || 0, decidedCount: c.joined || 0, rateWins: c.completed || 0,
      };
    }
    return { joined: s.convoysJoined || 0, wins: s.convoysCaptured || 0, failed: s.convoysFailed || 0 };
  }

  // Win rate for a race = wins out of races the gang actually FINISHED.
  function decided(stats) {
    if (stats.decidedCount != null) return stats.decidedCount;
    if (stats.completed != null) return stats.completed || 0;
    return (stats.wins || 0) + (stats.failed || 0);
  }

  function winRatePct(stats) {
    const d = decided(stats);
    return d === 0 ? 0 : Math.min(100, Math.round(((stats.rateWins ?? stats.wins) / d) * 100));
  }

  $: isRace = activeKindId === 'GANG_RACE';
  $: isTdm = activeKindId === 'TDM';
  $: isContainerWars = activeKindId === 'CONTAINER_WARS';
  $: if (sortMode === 'SPEND' && !isContainerWars) sortMode = 'CAPTURES';

  $: rankedGangs = gangs
    .map((g) => ({ ...g, kindStats: statsFor(g, activeKindId) }))
    .sort((a, b) => {
      if (sortMode === 'SPEND') {
        const spendDiff = (b.kindStats.totalSpend || 0) - (a.kindStats.totalSpend || 0);
        return spendDiff !== 0 ? spendDiff : (b.kindStats.wins || 0) - (a.kindStats.wins || 0);
      }
      if (sortMode === 'XP') {
        const xpDiff = (b.xp || 0) - (a.xp || 0);
        return xpDiff !== 0 ? xpDiff : b.kindStats.wins - a.kindStats.wins;
      }
      if (sortMode === 'WINRATE') {
        const aQualifies = decided(a.kindStats) >= MIN_DECIDED_FOR_WINRATE;
        const bQualifies = decided(b.kindStats) >= MIN_DECIDED_FOR_WINRATE;
        if (aQualifies !== bQualifies) return aQualifies ? -1 : 1;
        if (!aQualifies) return decided(b.kindStats) - decided(a.kindStats);
        const rateDiff = winRatePct(b.kindStats) - winRatePct(a.kindStats);
        return rateDiff !== 0 ? rateDiff : b.kindStats.wins - a.kindStats.wins;
      }
      return b.kindStats.wins - a.kindStats.wins;
    });

  // Only drives the "is this my gang's row" highlight in the ranked list
  // below now — a separate "my gang" KPI card row used to duplicate the same
  // numbers already sitting right there in the table (glaringly so with
  // just one gang on the server: the KPI row and the one table row said the
  // exact same thing twice), so it was removed rather than kept in sync.
  $: myGangIndex = myGangName ? rankedGangs.findIndex((g) => g.name === myGangName) : -1;

  $: rankOf = new Map(rankedGangs.map((g, i) => [g.name, i + 1]));
  $: filteredGangs = rankedGangs.filter((g) => {
    const q = searchQuery.toLowerCase().trim();
    if (!q) return true;
    return (g.label || g.name || '').toLowerCase().includes(q) || (g.leaderName || '').toLowerCase().includes(q);
  });
  $: totalCount = filteredGangs.length;
  $: totalPages = Math.max(1, Math.ceil(totalCount / pageSize));
  $: if (currentPage > totalPages) currentPage = totalPages;
  $: paginatedGangs = filteredGangs.slice((currentPage - 1) * pageSize, currentPage * pageSize);
  // Back to page 1 whenever the question changes (only the arguments are tracked).
  const resetPage = () => { currentPage = 1; };
  $: resetPage(searchQuery, activeKindId, sortMode, pageSize);

  async function refresh() {
    const res = await getGangLeaderboard();
    const nextGangs = res && res.ok ? res.gangs : [];
    if (!sameData(nextGangs, gangs)) gangs = nextGangs;
    loading = false;
  }

  onMount(() => {
    refresh();
    pollInterval = setInterval(refresh, 10000);
  });
  onDestroy(() => clearInterval(pollInterval));
</script>

<div class="panel view-enter" class:compact>
  <div class="panel-header">
    <span class="panel-title"><Icon name="trophy" size={14} /> Gang Leaderboard</span>
    <button class="btn btn-sm btn-steel" on:click={refresh}><Icon name="refresh" size={13} /> Refresh</button>
  </div>
  <div class="panel-body lb">
    <div class="lb-seg" role="tablist" aria-label="Event kind">
      {#each KINDS as k}
        <button type="button" class:on={activeKindId === k.id} on:click={() => (activeKindId = k.id)}>
          <Icon name={k.icon} size={13} /> {k.label}
        </button>
      {/each}
    </div>

    <div class="lb-bar">
      <div class="lb-bar-group">
        <span class="lb-bar-label">Rank by</span>
        <div class="lb-seg sm">
          {#each SORT_MODES.filter((m) => m.id !== 'SPEND' || isContainerWars) as s}
            <button type="button" class:on={sortMode === s.id} on:click={() => (sortMode = s.id)}>{s.label}</button>
          {/each}
        </div>
        {#if sortMode === 'WINRATE'}
          <span class="lb-hint">A gang needs {MIN_DECIDED_FOR_WINRATE} or more decided events to qualify.</span>
        {/if}
      </div>
      <div class="lb-search">
        <Icon name="search" size={13} />
        <input type="text" placeholder="Search gang or leader" bind:value={searchQuery} />
        {#if searchQuery}
          <button type="button" class="lb-x" on:click={() => (searchQuery = '')} aria-label="Clear search"><Icon name="close" size={12} /></button>
        {/if}
      </div>
    </div>

    {#if loading}
      <div class="lb-empty"><p>Loading the leaderboard…</p></div>
    {:else if gangs.length === 0}
      <div class="lb-empty">
        <Icon name="trophy" size={26} />
        <h4>No standings yet</h4>
        <p>No gang has taken part in an event yet. Standings appear here as soon as the first event finishes.</p>
      </div>
    {:else}
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
                <div class="lb-pstat"><b>{(g.xp || 0).toLocaleString()}</b><span>Gang XP</span></div>
                <div class="lb-pstat"><b>{decided(g.kindStats) === 0 ? '—' : `${winRatePct(g.kindStats)}%`}</b><span>Win rate</span></div>
              </div>
            </div>
          {:else}
            <div class="lb-pod none r{i + 1}">
              <div class="lb-pod-head">
                <div class="lb-pod-empty-ic"><Icon name={i === 0 ? 'trophy' : 'shield'} size={16} /></div>
                <div class="lb-pod-who">
                  <span class="lb-pod-rank">{['1st', '2nd', '3rd'][i]} place</span>
                  <span class="lb-pod-name dim">Unclaimed</span>
                  <span class="lb-pod-sub">No gang has earned this spot yet</span>
                </div>
              </div>
              <div class="lb-pod-stats">
                <div class="lb-pstat"><b>—</b><span>{activeKind.winLabel}</span></div>
                <div class="lb-pstat"><b>—</b><span>Gang XP</span></div>
                <div class="lb-pstat"><b>—</b><span>Win rate</span></div>
              </div>
            </div>
          {/if}
        {/each}
      </div>

      <div class="lb-card">
        <TablePager top bind:page={currentPage} bind:pageSize total={totalCount} noun="gangs" sizes={PAGE_SIZES} />
        <div class="lb-scroll">
          <table class="lb-table">
            <thead>
              <tr>
                <th class="c-rank">#</th>
                <th class="c-main">Gang</th>
                <th class="c-side">Leader</th>
                <th class="c-num">Members</th>
                <th class="c-num" class:sorted={sortMode === 'XP'} title="Gang XP: earned from events, spent on territory expansion">Gang XP</th>
                {#if sortMode === 'XP'}<th class="c-num" title="Territory area in km²">Territory area</th>{/if}
                <th class="c-num" class:sorted={sortMode === 'CAPTURES'}>{activeKind.winLabel}</th>
                {#if isRace}
                  <th class="c-num">Completed</th>
                  <th class="c-num">Failed</th>
                  <th class="c-num">Tokens won</th>
                {:else if isTdm}
                  <th class="c-num">Losses</th>
                  <th class="c-num">Kills</th>
                  <th class="c-num">Deaths</th>
                  <th class="c-num">K/D</th>
                  <th class="c-num">Tourn. wins</th>
                  <th class="c-num">Tourn. played</th>
                {:else if isContainerWars}
                  <th class="c-num">Events won</th>
                  <th class="c-num">Failed</th>
                  <th class="c-num" class:sorted={sortMode === 'SPEND'}>Total spend</th>
                {:else}
                  <th class="c-num">Failed</th>
                {/if}
                {#if activeKind.tracksJoined}<th class="c-num">Joined</th>{/if}
                <th class="c-num c-wr" class:sorted={sortMode === 'WINRATE'}>Win rate</th>
              </tr>
            </thead>
            <tbody>
              {#each paginatedGangs as g (g.name)}
                {@const rank = rankOf.get(g.name)}
                <tr class:mine={g.name === myGangName}>
                  <td class="c-rank"><span class="lb-rank" class:r1={rank === 1} class:r2={rank === 2} class:r3={rank === 3}>{rank}</span></td>
                  <td>
                    <div class="lb-gang">
                      <GangLogo logo={g.logo} label={g.label || g.name} accentColor={g.accentColor} size={26} />
                      <span class="lb-name">{g.label || g.name || 'Unnamed gang'}</span>
                      {#if g.name === myGangName}<span class="lb-you">You</span>{/if}
                    </div>
                  </td>
                  <td><span class="lb-leader" title={g.leaderName || ''}>{g.leaderName || '—'}</span></td>
                  <td class="c-num">{g.memberCount || 0}</td>
                  <td class="c-num" class:sorted={sortMode === 'XP'}>{(g.xp || 0).toLocaleString()}</td>
                  {#if sortMode === 'XP'}
                    <td class="c-num">{Number(g.areaKm2 || 0).toFixed(3)} km²</td>
                  {/if}
                  <td class="c-num win" class:sorted={sortMode === 'CAPTURES'}>{g.kindStats.wins}</td>
                  {#if isRace}
                    <td class="c-num">{g.kindStats.completed || 0}</td>
                    <td class="c-num loss">{g.kindStats.failed}</td>
                    <td class="c-num win">{g.kindStats.tokens || 0}</td>
                  {:else if isTdm}
                    <td class="c-num loss">{g.kindStats.failed}</td>
                    <td class="c-num">{g.kindStats.kills}</td>
                    <td class="c-num">{g.kindStats.deaths}</td>
                    <td class="c-num">{g.kindStats.deaths === 0 ? g.kindStats.kills.toFixed(2) : (g.kindStats.kills / g.kindStats.deaths).toFixed(2)}</td>
                    <td class="c-num win">{g.kindStats.tournamentWins}</td>
                    <td class="c-num">{g.kindStats.tournamentPlayed}</td>
                  {:else if isContainerWars}
                    <td class="c-num win">{g.kindStats.eventsWon}</td>
                    <td class="c-num loss">{g.kindStats.failed}</td>
                    <td class="c-num" class:sorted={sortMode === 'SPEND'}>${(g.kindStats.totalSpend || 0).toLocaleString()}</td>
                  {:else}
                    <td class="c-num loss">{g.kindStats.failed}</td>
                  {/if}
                  {#if activeKind.tracksJoined}<td class="c-num">{g.kindStats.joined}</td>{/if}
                  <td class="c-num" class:sorted={sortMode === 'WINRATE'}>
                    <div class="lb-wr">
                      <div class="lb-wr-track"><div class="lb-wr-fill" style="width:{winRatePct(g.kindStats)}%"></div></div>
                      <span class="lb-wr-pct">{decided(g.kindStats) === 0 ? '—' : `${winRatePct(g.kindStats)}%`}</span>
                    </div>
                  </td>
                </tr>
              {:else}
                <tr>
                  <td class="lb-cell-empty" colspan="16">
                    <div class="lb-empty">
                      <h4>No gang matches “{searchQuery}”</h4>
                      <p>Check the spelling, or search by a leader's name instead.</p>
                      <button type="button" class="lb-btn" on:click={() => (searchQuery = '')}>Clear search</button>
                    </div>
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  /* everything visual lives in ../ui/leaderboard.css (shared with the civilian board and the gang panel's leaderboard) */
  .panel-body { overflow-x: auto; }
  .panel.compact .panel-body { padding: 14px; }
</style>
