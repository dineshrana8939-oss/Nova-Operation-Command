<script>
  import { tdmHud } from './hudStore.js';

  $: minutes = Math.floor($tdmHud.seconds / 60);
  $: seconds = $tdmHud.seconds % 60;
  $: timeLabel = `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
  $: hasMvp = $tdmHud.mvp && $tdmHud.mvp.kills > 0;
</script>

{#if $tdmHud.visible}
  <div class="scoreboard">
    <div class="team left">
      <span class="team-name">{$tdmHud.teamA.label}</span>
      <span class="team-score">{$tdmHud.teamA.score}</span>
    </div>
    <div class="center">
      <span class="timer">{timeLabel}</span>
      <span class="timer-label">TDM MATCH</span>
    </div>
    <div class="team right">
      <span class="team-score">{$tdmHud.teamB.score}</span>
      <span class="team-name">{$tdmHud.teamB.label}</span>
    </div>
  </div>

  {#if hasMvp}
    <div class="mvp">
      <span class="mvp-label">MVP</span>
      <span class="mvp-name">{$tdmHud.mvp.name}</span>
      <span class="mvp-stats">{$tdmHud.mvp.kills} K / {$tdmHud.mvp.deaths} D</span>
    </div>
  {/if}

  <div class="self-stats">
    <span class="self-stat"><span class="self-val">{$tdmHud.myKills}</span><span class="self-lbl">Kills</span></span>
    <span class="self-stat"><span class="self-val">{$tdmHud.myDeaths}</span><span class="self-lbl">Deaths</span></span>
  </div>
{/if}

<style>
  .scoreboard {
    position: fixed;
    top: 18px;
    left: 50%;
    transform: translateX(-50%);
    width: 440px;
    height: 56px;
    display: grid;
    grid-template-columns: minmax(0, 1fr) 100px minmax(0, 1fr);
    align-items: center;
    background: rgba(20, 22, 32, 0.94);
    backdrop-filter: blur(8px);
    border: 1px solid #2a2e35;
    border-radius: var(--r-ctl);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.6);
    pointer-events: none;
    z-index: 9990;
    font-family: var(--font-ui);
    overflow: hidden;
  }
  .team {
    height: 100%;
    display: flex;
    flex-direction: column;
    justify-content: center;
    padding: 0 16px;
    min-width: 0;
  }
  .team.left {
    text-align: left;
    border-left: 3px solid #4f94e6;
  }
  .team.right {
    text-align: right;
    border-right: 3px solid #ff5d50;
  }
  .team-name {
    font-size: 11px;
    line-height: 1;
    font-weight: 700;
    letter-spacing: 0.5px;
    color: #b2b4c1;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .team-score {
    margin-top: 4px;
    font-size: 22px;
    line-height: 1;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
  .team.left .team-score { color: #4f94e6; }
  .team.right .team-score { color: #ff5d50; }

  .center {
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    border-left: 1px solid #2a2e35;
    border-right: 1px solid #2a2e35;
    background: rgba(13, 14, 20, 0.5);
  }
  .timer {
    font-size: 19px;
    line-height: 1;
    font-weight: 800;
    letter-spacing: 0.5px;
    color: #ffffff;
    font-variant-numeric: tabular-nums;
  }
  .timer-label {
    margin-top: 3px;
    font-size: 10px;
    font-weight: 800;
    letter-spacing: 0.8px;
    color: #ffc857;
    text-transform: uppercase;
  }

  .mvp {
    position: fixed;
    top: 80px;
    left: 50%;
    transform: translateX(-50%);
    min-width: 220px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 4px 14px;
    background: rgba(23, 24, 33, 0.94);
    backdrop-filter: blur(8px);
    border: 1px solid #2a2e35;
    border-radius: var(--r-ctl);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
    pointer-events: none;
    z-index: 9989;
    font-family: var(--font-ui);
  }
  .mvp-label {
    font-size: 10px;
    font-weight: 800;
    letter-spacing: 0.8px;
    color: #ffc857;
    background: rgba(255, 200, 87, 0.12);
    padding: 1px 5px;
    border-radius: var(--r-ctl);
  }
  .mvp-name {
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.3px;
    color: #f0f0f5;
  }
  .mvp-stats {
    font-size: 11px;
    font-weight: 600;
    color: #b2b4c1;
    font-variant-numeric: tabular-nums;
  }

  .self-stats {
    position: fixed;
    top: 114px;
    left: 50%;
    transform: translateX(-50%);
    display: flex;
    gap: 8px;
    z-index: 9989;
    pointer-events: none;
    font-family: var(--font-ui);
  }
  .self-stat {
    display: flex;
    align-items: baseline;
    gap: 5px;
    background: rgba(23, 24, 33, 0.94);
    backdrop-filter: blur(8px);
    border: 1px solid #2a2e35;
    border-radius: var(--r-ctl);
    padding: 3px 10px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }
  .self-val {
    font-size: 13.5px;
    font-weight: 700;
    color: #ffffff;
    font-variant-numeric: tabular-nums;
  }
  .self-lbl {
    font-size: 10.5px;
    color: #b2b4c1;
    text-transform: uppercase;
    letter-spacing: 0.4px;
    font-weight: 600;
  }
</style>
