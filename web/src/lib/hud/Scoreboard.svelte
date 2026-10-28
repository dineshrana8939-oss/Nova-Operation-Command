<script>
  import { fade, fly } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';
  import { scoreboard } from './hudStore.js';

  $: d = $scoreboard.data;
  $: isTdm = d && d.mode === 'tdm';

  function clock(s) {
    s = Math.max(0, Math.floor(Number(s) || 0));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }
  function kd(k, dth) {
    return dth ? (k / dth).toFixed(2) : Number(k).toFixed(2);
  }
  // best fragger on a side gets the gold star
  function topIndex(players) {
    let best = -1, idx = -1;
    players.forEach((p, i) => { if (p.points > best) { best = p.points; idx = i; } });
    return best > 0 ? idx : -1;
  }
</script>

{#if $scoreboard.visible && d}
  <div class="backdrop" transition:fade={{ duration: 140 }}>
    <div class="board" transition:fly={{ y: 18, duration: 220, easing: cubicOut }}>
      <!-- top bar: title · score · clock (Valorant-style) -->
      <div class="topbar">
        <div class="title-block">
          <div class="kicker">{isTdm ? 'Team Deathmatch' : 'Practice Session'}</div>
          <div class="title">{d.title}</div>
        </div>
        {#if isTdm}
          <div class="score">
            <span class="s-team a">{d.teams[0].label}</span>
            <span class="s-num a">{d.teams[0].score}</span>
            <span class="s-dash">—</span>
            <span class="s-num b">{d.teams[1].score}</span>
            <span class="s-team b">{d.teams[1].label}</span>
          </div>
        {:else}
          <div class="score"><span class="s-team">Players</span><span class="s-num">{d.players.length}</span></div>
        {/if}
        <div class="clock-block">
          <div class="clock">{clock(d.seconds)}</div>
          <div class="clock-cap">{isTdm ? (d.killLimit ? `First to ${d.killLimit}` : 'Time left') : 'Elapsed'}</div>
        </div>
      </div>

      {#if isTdm}
        {#each d.teams as team (team.key)}
          {@const star = topIndex(team.players)}
          <section class="team" class:a={team.key === 'A'} class:b={team.key === 'B'}>
            <header class="team-head">
              <span class="team-name">{team.label}</span>
              <span class="team-score">{team.score}</span>
            </header>
            <div class="cols"><span>#</span><span>Player</span><span class="c">Kills</span><span class="c">Deaths</span><span class="c">K/D</span><span class="r">Points</span></div>
            {#each team.players as p, i (p.name + i)}
              <div class="row" class:you={p.you} class:dead={!p.alive} style="animation-delay:{i * 35}ms">
                <span class="pos">{i + 1}</span>
                <span class="pname">
                  {#if i === star}<span class="star">★</span>{/if}{p.name}
                  {#if p.you}<span class="tag">You</span>{/if}
                  {#if !p.alive}<span class="down">Down</span>{/if}
                </span>
                <span class="c k">{p.kills}</span>
                <span class="c d">{p.deaths}</span>
                <span class="c">{kd(p.kills, p.deaths)}</span>
                <span class="r pts">{p.points}</span>
              </div>
            {/each}
          </section>
        {/each}
      {:else}
        {@const star = topIndex(d.players)}
        <section class="team a">
          <header class="team-head"><span class="team-name">Squad</span><span class="team-score">{d.players.reduce((n, p) => n + p.kills, 0)}</span></header>
          <div class="cols"><span>#</span><span>Player</span><span class="c">Kills</span><span class="c">Downs</span><span class="c">K/D</span><span class="r">Points</span></div>
          {#each d.players as p, i (p.name + i)}
            <div class="row" class:you={p.you} style="animation-delay:{i * 35}ms">
              <span class="pos">{i + 1}</span>
              <span class="pname">{#if i === star}<span class="star">★</span>{/if}{p.name}{#if p.you}<span class="tag">You</span>{/if}</span>
              <span class="c k">{p.kills}</span>
              <span class="c d">{p.deaths}</span>
              <span class="c">{kd(p.kills, p.deaths)}</span>
              <span class="r pts">{p.points}</span>
            </div>
          {/each}
        </section>
      {/if}

      <div class="foot"><b>TAB</b> Press again to close</div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: radial-gradient(ellipse at center, rgba(0, 0, 0, 0.35), rgba(0, 0, 0, 0.72));
    pointer-events: none;
    z-index: 9980;
  }
  .board {
    width: 1000px;
    max-width: 94vw;
    max-height: 92vh;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 18px 22px 14px;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-top: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-ctl);
    box-shadow: 0 20px 60px rgba(0, 0, 0, 0.7);
  }

  .topbar {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: 18px;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--tablet-border, rgba(255, 255, 255, 0.08));
  }
  .kicker { font-size: 12px; font-weight: 900; letter-spacing: 1px; text-transform: uppercase; color: var(--accent-primary-light, #5ba5ef); }
  .title { margin-top: 3px; font-size: 22px; font-weight: 900; color: var(--text-main, #fff); }
  .score { display: flex; align-items: center; gap: 14px; }
  .s-team { font-size: 14px; font-weight: 900; letter-spacing: 0.6px; text-transform: uppercase; max-width: 190px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--tablet-text-soft, #b4bac0); }
  .s-team.a { color: var(--accent-primary-light, #5ba5ef); }
  .s-team.b { color: #8fb4d9; }
  .s-num { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 44px; line-height: 1; font-weight: 900; color: var(--text-main, #fff); }
  .s-num.a { color: var(--accent-primary-light, #5ba5ef); }
  .s-num.b { color: #8fb4d9; }
  .s-dash { font-size: 24px; color: var(--tablet-text-soft, #b4bac0); }
  .clock-block { text-align: right; }
  .clock { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 30px; font-weight: 900; color: var(--text-main, #fff); }
  .clock-cap { font-size: 12px; font-weight: 800; letter-spacing: 0.6px; text-transform: uppercase; color: var(--tablet-text-soft, #b4bac0); }

  .team { border: 1px solid var(--tablet-border, rgba(255, 255, 255, 0.08)); border-radius: var(--r-ctl); overflow: hidden; background: var(--tablet-panel-alt, #181b1f); --side: var(--accent-primary, #4f94e6); }
  .team.b { --side: #8fb4d9; }
  .team-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 16px;
    background: linear-gradient(90deg, color-mix(in srgb, var(--side) 22%, #0c0c0c), #0c0c0c 70%);
    border-left: 4px solid var(--side);
  }
  .team-name { font-size: 15px; font-weight: 900; letter-spacing: 0.8px; text-transform: uppercase; color: var(--side); }
  .team-score { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 22px; font-weight: 900; color: var(--text-main, #fff); }

  .cols, .row {
    display: grid;
    grid-template-columns: 40px 1fr 90px 90px 90px 100px;
    align-items: center;
    gap: 8px;
    padding: 0 16px;
  }
  .cols { height: 28px; font-size: 12px; font-weight: 900; letter-spacing: 0.5px; text-transform: uppercase; color: var(--tablet-text-soft, #b4bac0); background: rgba(0, 0, 0, 0.3); }
  .row {
    position: relative;
    height: 42px;
    border-top: 1px solid var(--tablet-border, rgba(255, 255, 255, 0.06));
    animation: rowIn 0.28s ease-out both;
  }
  .row.you { background: rgba(56, 199, 255, 0.08); box-shadow: inset 3px 0 0 var(--tactical-cyan, #38c7ff); }
  .row.dead { opacity: 0.55; }
  @keyframes rowIn {
    from { opacity: 0; transform: translateX(-10px); }
    to { opacity: 1; transform: translateX(0); }
  }
  .pos { font-family: var(--font-mono); font-size: 14px; font-weight: 800; color: var(--tablet-text-soft, #b4bac0); }
  .pname { font-size: 16px; font-weight: 800; color: var(--text-main, #fff); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .star { margin-right: 6px; color: var(--accent-primary-light, #e6c878); }
  .tag { margin-left: 10px; padding: 1px 6px; font-size: 12px; font-weight: 800; letter-spacing: 0.4px; text-transform: uppercase; color: var(--tactical-cyan, #38c7ff); border: 1px solid rgba(56, 199, 255, 0.45); border-radius: var(--r-tag); vertical-align: middle; }
  .down { margin-left: 10px; font-size: 12px; font-weight: 800; letter-spacing: 0.4px; text-transform: uppercase; color: #ff4567; }
  .c { text-align: center; font-family: var(--font-mono); font-size: 16px; font-weight: 800; color: var(--text-main, #fff); }
  .r { text-align: right; }
  .k { color: var(--tablet-success, #70b982); }
  .d { color: var(--tablet-danger, #ff6b6b); }
  .pts { font-family: var(--font-mono); font-size: 17px; font-weight: 900; color: var(--text-main, #fff); }

  .foot { text-align: center; font-size: 12px; font-weight: 800; letter-spacing: 0.5px; text-transform: uppercase; color: var(--tablet-text-soft, #b4bac0); }
  .foot b { margin-right: 6px; padding: 1px 6px; border: 1px solid currentColor; border-radius: var(--r-ctl); }
</style>
