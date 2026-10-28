<script>
  import { sameData } from '../../util/stable.js';
  import { defaultPageSize } from '../../adminPrefs.js';
  import { onMount, onDestroy } from 'svelte';
  import { getCivilianLeaderboard } from '../../api/convoy.js';
  import Icon from '../ui/Icon.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import '../tablet-theme.css';
  import '../ui/leaderboard.css';
  import { avatarColor, initials } from '../../util/avatar.js';

  const CATEGORIES = [
    { id: 'all', label: 'All Civilian Events', icon: 'grid' },
    { id: 'race', label: 'Street Races', icon: 'flag' },
    { id: 'container_wars', label: 'Container Wars', icon: 'box' },
  ];
  let activeCategory = 'all';

  const SORT_MODES = [
    { id: 'points', label: 'Most Points' },
    { id: 'wins', label: 'Most Wins' },
    { id: 'rewards', label: 'Highest Rewards' },
    { id: 'participations', label: 'Most Active' },
  ];
  let sortMode = 'points';

  let rawEntries = [];
  let loading = true;
  let pollInterval;

  let searchQuery = '';
  let pageSize = defaultPageSize([10, 15, 25, 50]);
  let currentPage = 1;
  const PAGE_SIZES = [10, 15, 25, 50];

  function formatTime(seconds) {
    if (!seconds || seconds <= 0) return '—';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    const ms = Math.floor((seconds % 1) * 100);
    return `${m}:${String(s).padStart(2, '0')}.${String(ms).padStart(2, '0')}`;
  }

  function formatDate(ts) {
    if (!ts) return '—';
    const date = new Date(typeof ts === 'number' ? ts * 1000 : ts);
    if (isNaN(date.getTime())) return '—';
    return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }

  function formatCurrency(amount) {
    if (!amount || amount <= 0) return '$0';
    return `$${Number(amount).toLocaleString()}`;
  }

  $: filteredByCategory = rawEntries.filter((item) => {
    if (activeCategory === 'all') return true;
    return (item.eventType || '').toLowerCase() === activeCategory.toLowerCase();
  });

  $: rankedEntries = filteredByCategory
    .slice()
    .sort((a, b) => {
      if (sortMode === 'wins') {
        const diff = (b.wins || 0) - (a.wins || 0);
        return diff !== 0 ? diff : (b.points || 0) - (a.points || 0);
      }
      if (sortMode === 'rewards') {
        const diff = (b.totalRewards || 0) - (a.totalRewards || 0);
        return diff !== 0 ? diff : (b.points || 0) - (a.points || 0);
      }
      if (sortMode === 'participations') {
        const diff = (b.totalParticipations || 0) - (a.totalParticipations || 0);
        return diff !== 0 ? diff : (b.points || 0) - (a.points || 0);
      }
      const pDiff = (b.points || 0) - (a.points || 0);
      return pDiff !== 0 ? pDiff : (b.wins || 0) - (a.wins || 0);
    });

  $: searchedEntries = rankedEntries.filter((item) => {
    const q = searchQuery.toLowerCase().trim();
    if (!q) return true;
    return (
      (item.playerName || '').toLowerCase().includes(q) ||
      (item.playerRole || '').toLowerCase().includes(q) ||
      (item.playerIdentifier || '').toLowerCase().includes(q) ||
      (item.eventName || '').toLowerCase().includes(q)
    );
  });

  $: totalCount = searchedEntries.length;
  $: totalPages = Math.max(1, Math.ceil(totalCount / pageSize));
  $: pageNo = Math.min(Math.max(1, currentPage), totalPages);
  $: paginatedEntries = searchedEntries.slice((pageNo - 1) * pageSize, pageNo * pageSize);

  const resetPage = () => { currentPage = 1; };
  $: resetPage(searchQuery, activeCategory, sortMode, pageSize);

  // Meaningful Civilian KPIs
  $: totalCivilians = new Set(filteredByCategory.map(i => i.playerIdentifier)).size;
  $: totalWins = filteredByCategory.reduce((acc, curr) => acc + (curr.wins || 0), 0);
  $: totalPodiums = filteredByCategory.reduce((acc, curr) => acc + (curr.podiums || 0), 0);
  $: totalParticipations = filteredByCategory.reduce((acc, curr) => acc + (curr.totalParticipations || 0), 0);
  $: totalRewardsWon = filteredByCategory.reduce((acc, curr) => acc + (curr.totalRewards || 0), 0);
  $: topCivilianObj = rankedEntries[0] || null;
  $: topCivilian = topCivilianObj ? topCivilianObj.playerName : 'None';
  $: topWins = topCivilianObj ? (topCivilianObj.wins || 0) : 0;
  $: winRate = totalParticipations > 0 ? ((totalWins / totalParticipations) * 100).toFixed(1) + '%' : '0.0%';

  async function refresh() {
    try {
      const res = await getCivilianLeaderboard(activeCategory === 'all' ? null : activeCategory);
      if (res && res.ok) {
        const nextEntries = res.entries || [];
        if (!sameData(nextEntries, rawEntries)) rawEntries = nextEntries;
      } else {
        rawEntries = [];
      }
    } catch (e) {
      console.warn('[CivilianLeaderboard] Failed to load data:', e);
    } finally {
      loading = false;
    }
  }

  $: if (activeCategory) {
    refresh();
  }

  onMount(() => {
    refresh();
    pollInterval = setInterval(refresh, 10000);
  });

  onDestroy(() => {
    if (pollInterval) clearInterval(pollInterval);
  });
</script>

<div class="panel view-enter">
  <div class="panel-header">
    <span class="panel-heading">
      <span class="panel-title"><Icon name="medal" size={14} /> Civilian Leaderboard</span>
    </span>
    <button class="btn btn-sm btn-steel" on:click={refresh} disabled={loading} title="Reload the rankings">
      <Icon name="refresh" size={13} /> {loading ? 'Refreshing…' : 'Refresh'}
    </button>
  </div>
  <div class="panel-body lb">
    <p class="lb-intro">How players outside the gangs rank in events that are open to everyone.</p>

    <div class="lb-tiles">
      <div class="lb-tile"><span>Total prize earnings</span><b>{formatCurrency(totalRewardsWon)}</b><small>Won in races and container auctions</small></div>
      <div class="lb-tile"><span>First-place wins</span><b>{totalWins}</b><small>Leader: {topCivilian} ({topWins} {topWins === 1 ? 'win' : 'wins'})</small></div>
      <div class="lb-tile"><span>Podium finishes</span><b>{totalPodiums}</b><small>Confirmed top 3 placements</small></div>
      <div class="lb-tile"><span>Events entered</span><b>{totalParticipations}</b><small>Across {totalCivilians} {totalCivilians === 1 ? 'player' : 'players'}</small></div>
      <div class="lb-tile"><span>Overall win rate</span><b>{winRate}</b><small>{totalWins} wins from {totalParticipations} entries</small></div>
    </div>

    <div class="lb-bar">
      <div class="lb-seg" role="tablist" aria-label="Event discipline">
        {#each CATEGORIES as cat (cat.id)}
          <button type="button" class:on={activeCategory === cat.id} on:click={() => (activeCategory = cat.id)}>
            <Icon name={cat.icon} size={13} /> {cat.label}
          </button>
        {/each}
      </div>
      <div class="lb-bar-group">
        <div class="lb-search">
          <Icon name="search" size={13} />
          <input type="text" placeholder="Search by player or identifier" bind:value={searchQuery} />
          {#if searchQuery}
            <button type="button" class="lb-x" on:click={() => (searchQuery = '')} aria-label="Clear search"><Icon name="close" size={12} /></button>
          {/if}
        </div>
        <label class="lb-select">
          <span>Rank by</span>
          <select bind:value={sortMode}>
            {#each SORT_MODES as sm}<option value={sm.id}>{sm.label}</option>{/each}
          </select>
        </label>
      </div>
    </div>

    <div class="lb-card">
      <TablePager top bind:page={currentPage} bind:pageSize total={totalCount} noun="players" sizes={PAGE_SIZES} />
      <div class="lb-scroll">
        <table class="lb-table">
          <thead>
            <tr>
              <th class="c-rank">#</th>
              <th class="c-main">Player</th>
              <th class="c-side">Event</th>
              <th class="c-num" class:sorted={sortMode === 'wins'}>Wins</th>
              <th class="c-num">Podiums</th>
              <th class="c-num" class:sorted={sortMode === 'participations'}>Events</th>
              <th class="c-num" class:sorted={sortMode === 'points'}>Points</th>
              <th>Best result</th>
              <th class="c-num" class:sorted={sortMode === 'rewards'}>Total rewards</th>
              <th class="c-num">Last active</th>
            </tr>
          </thead>
          <tbody>
            {#if loading && rawEntries.length === 0}
              <tr><td class="lb-cell-empty" colspan="10"><div class="lb-empty"><p>Loading the civilian rankings…</p></div></td></tr>
            {:else if paginatedEntries.length === 0}
              <tr>
                <td class="lb-cell-empty" colspan="10">
                  <div class="lb-empty">
                    <Icon name="medal" size={26} />
                    {#if searchQuery}
                      <h4>No player matches “{searchQuery}”</h4>
                      <p>Check the spelling, or search by the player's identifier instead.</p>
                      <button type="button" class="lb-btn" on:click={() => (searchQuery = '')}>Clear search</button>
                    {:else}
                      <h4>No civilian results yet</h4>
                      <p>Results appear here when a player finishes an event that is set to Open to Everyone. Switch the discipline above to check another event type.</p>
                    {/if}
                  </div>
                </td>
              </tr>
            {:else}
              {#each paginatedEntries as item, i (item.playerIdentifier + '-' + item.eventType)}
                {@const globalRank = (pageNo - 1) * pageSize + i + 1}
                {@const pname = item.playerName || 'Player'}
                <tr>
                  <td class="c-rank"><span class="lb-rank" class:r1={globalRank === 1} class:r2={globalRank === 2} class:r3={globalRank === 3}>{globalRank}</span></td>
                  <td>
                    <div class="lb-who">
                      <span class="lb-av" style="background:{avatarColor(pname)}">{initials(pname)}</span>
                      <div class="lb-who-text">
                        <div class="lb-who-row">
                          <span class="lb-name">{pname}</span>
                          {#if item.playerRole}
                            <span class="lb-tag" class:accent={item.playerRole.toLowerCase() !== 'civilian'} title="Character profession or role">{item.playerRole}</span>
                          {/if}
                        </div>
                        <span class="lb-who-sub" title={item.playerIdentifier}>{item.playerIdentifier || 'N/A'}</span>
                      </div>
                    </div>
                  </td>
                  <td>
                    <div class="lb-ev">
                      <span class="lb-tag">
                        {#if item.eventType === 'race'}
                          <Icon name="flag" size={11} /> Street race
                        {:else if item.eventType === 'container_wars'}
                          <Icon name="box" size={11} /> Container Wars
                        {:else}
                          {item.eventType || 'Event'}
                        {/if}
                      </span>
                      {#if item.eventName}<span class="lb-who-sub" title={item.eventName}>{item.eventName}</span>{/if}
                    </div>
                  </td>
                  <td class="c-num win" class:sorted={sortMode === 'wins'}>{item.wins || 0}</td>
                  <td class="c-num">{item.podiums || 0}</td>
                  <td class="c-num" class:sorted={sortMode === 'participations'}>{item.totalParticipations || 0}</td>
                  <td class="c-num" class:sorted={sortMode === 'points'}>{item.points || 0}</td>
                  <td class="c-fit">
                    {#if item.bestTime && item.bestTime > 0}
                      <span class="lb-time" title="Fastest recorded finish time"><Icon name="clock" size={12} /> {formatTime(item.bestTime)}</span>
                    {:else if item.wins > 0}
                      <span>1st place</span>
                    {:else if item.podiums > 0}
                      <span>Top 3 finish</span>
                    {:else}
                      <span class="muted">Completed</span>
                    {/if}
                  </td>
                  <td class="c-num" class:win={item.totalRewards > 0} class:sorted={sortMode === 'rewards'}>{formatCurrency(item.totalRewards)}</td>
                  <td class="c-num muted">{formatDate(item.lastParticipated || item.updatedAt)}</td>
                </tr>
              {/each}
            {/if}
          </tbody>
        </table>
      </div>
    </div>
  </div>
</div>

<style>
  /* everything visual lives in ../ui/leaderboard.css (shared with the gang leaderboards) */
  .lb-intro { margin: 0; font-size: var(--fs-small); color: var(--text-muted); }
</style>
