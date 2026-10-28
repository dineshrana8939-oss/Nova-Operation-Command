<script>
  import { fly, fade } from 'svelte/transition';
  import { backOut } from 'svelte/easing';
  import { tdmFlash, tdmStreakBadge } from './hudStore.js';
  import Icon from '../tablet/ui/Icon.svelte';

  const ACCENT = {
    kill: '#ffc857',
    head: '#ff5d50',
    double: '#ff9f2f',
    triple: '#ffc857',
    streak: '#4f94e6',
  };

  // Titles arrive in capitals from the server ("HEADSHOT"); show them in plain words.
  const plain = (s) => {
    const t = String(s || '').trim();
    return t ? t.charAt(0).toUpperCase() + t.slice(1).toLowerCase() : '';
  };
</script>

<!-- Personal-only feedback for the KILLER (every kill, plus headshot / multi-kill / streak upgrades) — kept on the right
     side, below the kill feed, never centred over the crosshair in the middle of a gunfight. No backdrop-filter: on a card
     that slides in it paints a black rectangle round it in the game's browser. -->
{#if $tdmFlash.visible}
  {#key $tdmFlash.title + $tdmFlash.sub + $tdmFlash.type}
    <div
      class="flash"
      style="--accent:{ACCENT[$tdmFlash.type] || '#ffc857'}"
      in:fly={{ x: 100, duration: 320, easing: backOut }}
      out:fade={{ duration: 250 }}
    >
      <span class="flash-ico"><Icon name={$tdmFlash.type === 'head' ? 'crosshair' : $tdmFlash.type === 'streak' ? 'flame' : 'zap'} size={20} /></span>
      <div class="flash-text">
        <span class="flash-title">{plain($tdmFlash.title)}</span>
        {#if $tdmFlash.sub}<span class="flash-sub">{plain($tdmFlash.sub)}</span>{/if}
      </div>
    </div>
  {/key}
{/if}

{#if $tdmStreakBadge.visible}
  <div class="streak" in:fly={{ x: 100, duration: 320, easing: backOut }} out:fade={{ duration: 250 }}>
    <span class="streak-ico"><Icon name="flame" size={20} /></span>
    <span class="streak-label">Kill streak</span>
    {#key $tdmStreakBadge.count}<span class="streak-count">{$tdmStreakBadge.count}×</span>{/key}
  </div>
{/if}

<style>
  .flash,
  .streak {
    position: fixed;
    right: 28px;
    width: 340px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 10px 18px 10px 12px;
    background:
      linear-gradient(90deg, color-mix(in srgb, var(--accent) 20%, transparent), transparent 55%),
      rgba(12, 16, 23, 0.95);
    border: 1px solid color-mix(in srgb, var(--accent) 50%, transparent);
    border-radius: 14px;
    box-shadow: inset 3px 0 0 var(--accent), 0 6px 18px rgba(0, 0, 0, 0.5);
    pointer-events: none;
    z-index: 9987;
    font-family: var(--font-ui);
    overflow: hidden;
  }
  .flash { top: 420px; }
  .streak { --accent: #4f94e6; top: 496px; }

  .flash::after {
    content: '';
    position: absolute;
    top: 0;
    left: -40%;
    width: 26%;
    height: 100%;
    background: linear-gradient(100deg, transparent, rgba(255, 255, 255, 0.1), transparent);
    transform: skewX(-18deg);
    animation: sweep 0.75s ease-out 0.08s both;
  }
  @keyframes sweep { from { left: -40%; } to { left: 130%; } }

  .flash-ico,
  .streak-ico {
    flex: none;
    width: 38px;
    height: 38px;
    display: grid;
    place-items: center;
    border-radius: 10px;
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 16%, transparent);
    border: 1px solid color-mix(in srgb, var(--accent) 42%, transparent);
  }

  .flash-text { min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .flash-title {
    font-family: var(--font-display);
    font-stretch: var(--stretch-display);
    font-size: 24px;
    line-height: 1.1;
    font-weight: 700;
    color: var(--accent);
    animation: titlePop 0.35s cubic-bezier(0.2, 1.4, 0.4, 1) both;
    transform-origin: left center;
  }
  @keyframes titlePop {
    0% { transform: scale(0.85); opacity: 0; }
    60% { transform: scale(1.06); opacity: 1; }
    100% { transform: scale(1); }
  }
  .flash-sub { font-size: 14px; color: #c9ced4; }

  .streak-label { font-size: 15px; font-weight: 600; color: #eceef0; }
  .streak-count {
    margin-left: auto;
    font-family: var(--font-display);
    font-stretch: var(--stretch-display);
    font-size: 30px;
    line-height: 1;
    font-weight: 700;
    color: var(--accent);
    font-variant-numeric: tabular-nums;
    animation: titlePop 0.35s cubic-bezier(0.2, 1.4, 0.4, 1) both;
    transform-origin: right center;
  }

  @media (prefers-reduced-motion: reduce) {
    .flash::after, .flash-title, .streak-count { animation: none; }
  }
</style>
