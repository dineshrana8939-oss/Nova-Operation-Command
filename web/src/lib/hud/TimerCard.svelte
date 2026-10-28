<script>
  import { themeFor, themeVars } from './eventThemes.js';
  import { hudIcon } from './hudIcons.js';
  import './hud-shared.css';

  // The mission-clock card (event_timer_hud design): icon plate, kicker,
  // event name, status + live dot, big digits, segmented progress. Used by
  // the delivery/airdrop clock, the checkpoint timer and the police prep
  // countdown — only the props differ, so all of them share one look and each
  // takes its colour from its event (see eventThemes.js).
  export let eventKey = 'convoy';
  export let icon = null; // defaults to the event's own icon
  export let kicker = 'MISSION CLOCK //';
  export let name = '';
  export let state = 'ACTIVE';
  export let live = 'LIVE';
  export let seconds = 0;
  export let maxSeconds = 1;
  export let paused = false;
  export let wide = false; // centred banner variant (checkpoint / prep)
  export let title = ''; // wide variant: headline under the kicker
  export let urgentAt = 30;

  const SEGMENTS = 22;

  $: theme = themeFor(eventKey);
  $: pct = maxSeconds > 0 ? Math.max(0, Math.min(1, seconds / maxSeconds)) : 0;
  $: activeSegments = Math.ceil(pct * SEGMENTS);
  $: h = Math.floor(seconds / 3600);
  $: m = Math.floor((seconds % 3600) / 60);
  $: s = Math.max(0, Math.floor(seconds % 60));
  $: two = (n) => String(n).padStart(2, '0');
  $: timeLabel = h > 0 ? `${two(h)}:${two(m)}:${two(s)}` : `${two(m)}:${two(s)}`;
  $: urgent = !paused && seconds > 0 && seconds <= urgentAt;
</script>

<div class="timer-card-wrap" class:wide style="{themeVars(eventKey)}">
  <div class="hx-card timer-card" class:wide class:paused>
    <div class="hx-texture"></div>
    <div class="hx-slice"></div>
    <div class="hx-rail"><span></span></div>

    <div class="row">
      <div class="hx-iconbox">{@html hudIcon(icon || theme.icon)}</div>

      <div class="copy">
        {#if wide}
          <div class="kicker">{kicker}</div>
          <div class="headline" class:paused>{title}</div>
        {:else}
          <div class="event-name">{name || theme.label}</div>
          <div class="subline"><span class="hx-live-dot"></span>{paused ? 'PAUSED' : state}</div>
        {/if}
      </div>

      {#if wide}
        <div class="wide-time" class:urgent>{timeLabel}</div>
      {:else}
        <div class="time" class:urgent>{timeLabel}</div>
      {/if}
    </div>

    <div class="hx-segments bar">
      {#each Array(SEGMENTS) as _, i}<i class:on={i < activeSegments}></i>{/each}
    </div>
  </div>
</div>

<style>
  /* Compact mission-clock card: the same information as before (icon, kicker, event name, the clock, status, live
     marker, progress) laid out on one row instead of three stacked ones. */
  .timer-card-wrap {
    position: fixed;
    left: 24px;
    top: 104px;
    width: 268px;
    pointer-events: none;
    z-index: 9990;
  }
  .timer-card-wrap.wide {
    left: 0;
    right: 0;
    top: 24px;
    width: auto;
    display: flex;
    justify-content: center;
    z-index: 9995;
  }
  .timer-card {
    width: 100%;
    padding: 8px 10px 9px;
    animation: hxEnterLeft 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .timer-card.wide {
    width: min(430px, 92vw);
    padding: 8px 12px 9px;
    animation: hxEnter 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .timer-card :global(.hx-iconbox) { width: 28px; height: 28px; }
  .timer-card :global(.hx-iconbox svg) { width: 15px; height: 15px; }
  .row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 9px;
  }
  .copy {
    flex: 1;
    min-width: 0;
  }
  .kicker {
    color: var(--accent2);
    font-size: 10px;
    font-weight: 900;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .event-name,
  .headline {
    margin-top: 1px;
    color: #fff;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 14px;
    line-height: 1.1;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .headline {
    font-size: 14px;
  }
  .headline.paused {
    color: #f2d12e;
  }
  .subline {
    display: flex;
    align-items: center;
    gap: 5px;
    margin-top: 3px;
    color: #9a9ea0;
    font-size: 10px;
    font-weight: 800;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .time {
    flex: none;
    white-space: nowrap;
    color: #fff;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 30px;
    line-height: 1;
    font-weight: 700;
    letter-spacing: 0.01em;
    font-variant-numeric: tabular-nums;
    text-shadow: 0 1px 3px rgba(0, 0, 0, 0.7);
  }
  .wide-time {
    flex: none;
    white-space: nowrap;
    padding: 3px 9px;
    border: 1px solid rgba(var(--accentRGB), 0.42);
    border-radius: var(--r-ctl);
    background: rgba(0, 0, 0, 0.34);
    color: #fff;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 22px;
    line-height: 1;
    font-weight: 700;
    letter-spacing: 0.01em;
    font-variant-numeric: tabular-nums;
  }
  .time.urgent,
  .wide-time.urgent {
    color: #ffc05b;
    animation: hxUrgent 1.2s ease-in-out infinite alternate;
  }
  .wide-time.urgent {
    border-color: rgba(255, 182, 79, 0.72);
  }
  .bar {
    position: relative;
    margin-top: 7px;
    height: 3px;
  }
  .timer-card.paused .bar i.on {
    background: #f2d12e;
  }
</style>
