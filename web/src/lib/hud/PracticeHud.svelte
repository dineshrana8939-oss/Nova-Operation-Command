<script>
  import { practiceHud } from './hudStore.js';
  import { themeVars } from './eventThemes.js';
  import { hudIcon } from './hudIcons.js';
  import './hud-shared.css';

  // Every new kill re-runs the pop animation on the number and floats a "+1"
  // up from it — `bump` is the {#key} that restarts both. The count going DOWN
  // (new session) resets silently instead of animating.
  let prevKills = 0;
  let bump = 0;
  let gained = 0;
  $: {
    const k = $practiceHud.kills || 0;
    if (!$practiceHud.visible) {
      prevKills = 0;
    } else if (k > prevKills) {
      gained = k - prevKills;
      bump += 1;
      prevKills = k;
    } else if (k < prevKills) {
      prevKills = k;
    }
  }
</script>

{#if $practiceHud.visible}
  <div class="practice-wrap" style={themeVars('practice')}>
    <div class="hx-card practice-card">
      <div class="hx-texture"></div>
      <div class="hx-slice"></div>
      <div class="hx-rail"><span></span></div>

      <div class="row">
        <div class="hx-iconbox">{@html hudIcon('tdm')}</div>

        <div class="copy">
          <div class="kicker">PRACTICE RANGE //</div>
          <div class="where" title={$practiceHud.location}>{$practiceHud.location || 'Training Area'}</div>
        </div>

        <div class="count">
          {#key bump}
            <div class="num" class:pop={bump > 0}>{$practiceHud.kills}</div>
            {#if bump > 0}<div class="plus">+{gained}</div>{/if}
          {/key}
          <div class="lbl">KILLS</div>
        </div>
      </div>

      <div class="hx-segments pips">
        {#each Array(12) as _, i}<i class:on={i < ($practiceHud.kills % 13)}></i>{/each}
      </div>
    </div>
  </div>
{/if}

<style>
  /* Sits below the top-left corner FiveM uses for its own toasts/FPS counter
     (same 96px the mission-clock cards use), not jammed against the screen edge. */
  .practice-wrap {
    position: fixed;
    top: 96px;
    left: 24px;
    width: 268px;
    pointer-events: none;
    z-index: 9990;
  }
  .practice-card {
    padding: 12px 14px 14px;
    animation: hxEnterLeft 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .copy {
    flex: 1;
    min-width: 0;
  }
  .kicker {
    color: var(--accent2);
    font-size: 12px;
    font-weight: 900;
    letter-spacing: 0.08em;
    white-space: nowrap;
  }
  .where {
    margin-top: 4px;
    color: #fff;
    font-size: 14px;
    font-weight: 800;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    line-height: 1.2;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }

  .count {
    position: relative;
    flex: none;
    min-width: 58px;
    text-align: right;
  }
  .num {
    color: #fff;
    font-family: var(--font-ui);
    font-size: 34px;
    line-height: 0.95;
    font-weight: 900;
    letter-spacing: 0.02em;
    font-variant-numeric: tabular-nums;
    text-shadow: 0 2px 8px rgba(0, 0, 0, 0.65);
    transform-origin: right center;
  }
  .num.pop {
    animation: killPop 0.55s cubic-bezier(0.2, 1.4, 0.3, 1) both;
  }
  .plus {
    position: absolute;
    right: 2px;
    top: -6px;
    color: var(--accent2);
    font-size: 15px;
    font-weight: 900;
    text-shadow: 0 2px 6px rgba(0, 0, 0, 0.8);
    animation: plusFloat 1s ease-out forwards;
  }
  .lbl {
    margin-top: 3px;
    color: #9aa0a6;
    font-size: 12px;
    font-weight: 900;
    letter-spacing: 0.08em;
  }

  .pips {
    position: relative;
    margin-top: 11px;
  }

  @keyframes killPop {
    0% { transform: scale(1.6); color: var(--accent2); }
    55% { transform: scale(0.94); }
    100% { transform: scale(1); color: #fff; }
  }
  @keyframes plusFloat {
    0% { opacity: 0; transform: translateY(6px) scale(0.8); }
    20% { opacity: 1; }
    100% { opacity: 0; transform: translateY(-16px) scale(1.1); }
  }
</style>
