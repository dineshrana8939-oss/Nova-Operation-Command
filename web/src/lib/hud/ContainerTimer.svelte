<script>
  // The yard board at the top of the screen for anyone inside the Container Wars bidding zone: what the auction is doing now
  // and how long until the next step (the next container drops, bidding opens, or the running auction ends).
  // Styled as a steel plate (cwTheme.css); every line wraps, nothing is cut off.
  import { containerTimer } from './containerTimerStore.js';
  import './cwTheme.css';

  function formatTime(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0));
    return String(Math.floor(seconds / 60)).padStart(2, '0') + ':' + String(seconds % 60).padStart(2, '0');
  }
</script>

{#if $containerTimer.visible}
  <div class="cw-timer cw-plate" class:live={$containerTimer.tone === 'live'}>
    <div class="cw-strip"></div>
    <div class="row">
      <div class="text">
        <div class="cw-kicker">{$containerTimer.title}</div>
        <div class="label">{$containerTimer.label}</div>
      </div>
      {#if $containerTimer.seconds != null}
        <div class="time">{formatTime($containerTimer.seconds)}</div>
      {/if}
    </div>
    {#if $containerTimer.bid}
      <div class="bidline">
        <span class="bid">{$containerTimer.bid}</span>
        <span class="leader">{$containerTimer.leader}</span>
      </div>
    {/if}
    {#if $containerTimer.sub}<div class="sub">{$containerTimer.sub}</div>{/if}
  </div>
{/if}

<style>
  .cw-timer {
    position: fixed;
    top: 14px;
    left: 50%;
    transform: translateX(-50%);
    width: 340px;
    overflow: hidden;
    font-family: var(--font-ui);
    pointer-events: none;
    z-index: 40;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.5);
  }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 9px 16px 9px; }
  .text { min-width: 0; }
  .label {
    margin-top: 3px;
    font-family: var(--cw-display);
    font-size: 16px;
    font-weight: 600;
    line-height: 1.2;
    letter-spacing: 0.03em;
    white-space: normal;
    overflow-wrap: anywhere;
  }
  .time {
    flex: 0 0 auto;
    font-family: var(--cw-display);
    font-size: 32px;
    font-weight: 700;
    line-height: 1;
    letter-spacing: 0.03em;
    font-variant-numeric: tabular-nums;
    color: var(--cw-yellow);
  }
  .live .time { color: var(--cw-orange); }

  .bidline {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
    padding: 7px 16px 9px;
    border-top: 1px solid var(--cw-line-soft);
  }
  .bid { font-family: var(--cw-display); font-size: 22px; font-weight: 700; color: var(--cw-text); font-variant-numeric: tabular-nums; }
  .leader {
    min-width: 0;
    font-family: var(--cw-display);
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    text-align: right;
    color: var(--cw-blue);
    overflow-wrap: anywhere;
  }
  .sub { padding: 0 16px 9px; font-size: 13px; font-weight: 500; color: var(--cw-dim); overflow-wrap: anywhere; }
</style>
