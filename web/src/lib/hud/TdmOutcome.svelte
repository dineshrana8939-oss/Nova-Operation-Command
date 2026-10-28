<script>
  // End of a TDM match: the gang's logo, its name and a big WINS / DEFEATED (green / red) at the top left, and a small card over the head of each of the
  // team's best players (name, rank, XP earned, kills, deaths) that follows the real player in the world. Transparent, no focus: it is drawn over the game
  // for a few seconds and then the results window opens. The server decides the outcome and every number; the game side only reports where each ped
  // is on the screen (tdmOutcome:pos). Visual reference: the TDM win / loss sample.
  import { tdmOutcome } from './tdmOutcomeStore.js';
  import GangLogo from '../tablet/ui/GangLogo.svelte';

  $: b = $tdmOutcome && $tdmOutcome.banner;
  $: pos = ($tdmOutcome && $tdmOutcome.pos) || {};
  $: result = (b && b.result) || 'win';
  $: word = result === 'win' ? 'WINS' : result === 'loss' ? 'DEFEATED' : 'DRAW';
  $: accent = result === 'win' ? '#20ee70' : result === 'loss' ? '#ef4444' : '#9aa3a0';
  const num = (n) => Number(n || 0).toLocaleString();
</script>

{#if b}
  <div class="to" style="--accent: {accent};" aria-hidden="true">
    <header class="banner">
      <div class="logo"><GangLogo logo={b.logo} label={b.gangName} accentColor={b.accent} size={96} /></div>
      <div>
        <div class="eyebrow">{b.eventName || 'TEAM DEATHMATCH'}</div>
        <div class="gang">{b.gangName}</div>
        <div class="result">{word}</div>
      </div>
    </header>

    {#each b.cards || [] as c (c.sid)}
      {#if pos[c.sid] && pos[c.sid].on}
        <section class="overhead" style="left: {pos[c.sid].x * 100}vw; top: {pos[c.sid].y * 100}vh;">
          <div class="card">
            <div class="row"><div class="name">{c.name}</div><div class="rank">#{c.place}{#if c.rank} · {String(c.rank).toUpperCase()}{/if}</div></div>
            <div class="stats">
              <div class="stat"><div class="label">XP Earned</div><div class="value xp">{c.xp != null ? '+' + num(c.xp) : '—'}</div></div>
              <div class="stat"><div class="label">Kills</div><div class="value">{num(c.kills)}</div></div>
              <div class="stat"><div class="label">Deaths</div><div class="value">{num(c.deaths)}</div></div>
            </div>
          </div>
          <div class="stem"></div>
        </section>
      {/if}
    {/each}
  </div>
{/if}

<style>
  .to { position: fixed; inset: 0; z-index: 6100; pointer-events: none; color: #f5f7f6; font-family: Arial, Helvetica, sans-serif; background: transparent; }
  .banner { position: absolute; left: 3%; top: 4%; display: flex; align-items: center; gap: 14px; filter: drop-shadow(0 3px 6px #000b); max-width: 90vw; }
  .logo { flex: none; }
  .eyebrow { font-size: clamp(9px, 1vw, 14px); font-weight: 800; letter-spacing: 0.32em; margin-bottom: 5px; text-transform: uppercase; }
  .gang { font-family: Impact, Haettenschweiler, 'Arial Narrow Bold', sans-serif; font-size: clamp(30px, 4.2vw, 64px); font-weight: 900; line-height: 0.95; color: var(--accent); text-shadow: 2px 3px 0 #000b; white-space: nowrap; text-transform: uppercase; }
  .result { font-family: Impact, Haettenschweiler, 'Arial Narrow Bold', sans-serif; font-size: clamp(26px, 3vw, 44px); font-weight: 900; line-height: 1; color: #fff; text-shadow: 2px 3px 0 #000b; }
  .overhead { position: absolute; width: 230px; transform: translate(-50%, -100%); filter: drop-shadow(0 2px 5px #000b); }
  .card { background: rgba(8, 11, 12, 0.88); border: 1px solid #ffffff30; border-left: 3px solid var(--accent); padding: 8px 10px; }
  .row { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .name { font-size: 14px; font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rank { font-size: 9px; color: var(--accent); font-weight: 800; white-space: nowrap; }
  .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 7px; margin-top: 7px; }
  .stat { border-top: 1px solid #ffffff24; padding-top: 5px; }
  .label { font-size: 9px; color: #aeb7b2; text-transform: uppercase; letter-spacing: 0.1em; }
  .value { font-size: 15px; font-weight: 900; margin-top: 3px; }
  .xp { color: var(--accent); }
  .stem { width: 1px; height: 17px; background: var(--accent); margin: 0 auto; }
</style>
