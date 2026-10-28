<script>
  // Floating marker pinned above a supply crate. Card-less on purpose: white lettering with a dark outline reads over any part of the
  // map (sand, road, sky) without a box, a blur or a glow behind it. Active crate = gold ornament, "AIRDROP", the zone and a countdown.
  // Looted crate = the same layout in green, naming the gang that took it.
  import { airdropMarkers } from './airdropMarkerStore.js';

  function fmt(seconds) {
    const safe = Math.max(0, Math.floor(Number(seconds) || 0));
    return String(Math.floor(safe / 60)).padStart(2, '0') + ':' + String(safe % 60).padStart(2, '0');
  }
  const tone = (s) => (s <= 15 ? 'critical' : s <= 45 ? 'warning' : 'normal');
</script>

{#each $airdropMarkers as m (m.id)}
  <!-- Positioned with a transform (compositor only); it glides between the ~30 position updates a second -->
  <div class="anchor" style="--x:{m.x}; --y:{m.y}; --s:{m.scale ?? 1};">
    <div class="marker {m.stolen ? 'looted' : tone(m.seconds)}">
      <div class="rule" aria-hidden="true">✦ ◆ ✦</div>

      {#if m.stolen}
        <div class="title">Airdrop Looted</div>
        <div class="meta">
          <span class="by">Looted by:</span>
          <span class="who">{m.stolenBy || 'Unknown gang'}</span>
        </div>
      {:else}
        <div class="eyebrow">Supply Drop</div>
        <div class="title">Airdrop</div>
        <div class="subtitle">{m.label || 'Secure the crate'}</div>
        <div class="timer">
          <span class="time">{fmt(m.seconds)}</span>
          {#if m.dist != null}<span class="dist">{m.dist} m</span>{/if}
        </div>
      {/if}
    </div>
  </div>
{/each}

<style>
  .anchor {
    position: fixed;
    left: 0;
    top: 0;
    transform: translate3d(calc(var(--x) * 100vw), calc(var(--y) * 100vh), 0) translate(-50%, -100%) scale(var(--s));
    transform-origin: 50% 100%;
    transition: transform 70ms linear;
    pointer-events: none;
    z-index: 40;
    will-change: transform;
  }

  .marker {
    --white: #fffaf0;
    --gold: #e7bd63;
    --ink: #111820;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 5px;
    width: max-content;
    max-width: 300px;
    padding-bottom: 8px;
    text-align: center;
    color: var(--white);
    font-family: Inter, 'Segoe UI', Arial, sans-serif;
    user-select: none;
    pointer-events: none;
    /* a slow bob so the marker reads as hanging in the air; a transform, so it costs nothing to draw */
    animation: bob 3.2s ease-in-out infinite;
  }

  /* Dark outline built from shadows, not -webkit-text-stroke: the stroke is centred on the glyph edge and thins the white fill,
     and paint-order (which would fix that) is not available for HTML text in every build of the game's browser. */
  .rule,
  .eyebrow,
  .title,
  .subtitle,
  .timer,
  .meta {
    text-shadow:
      1px 0 0 var(--ink), -1px 0 0 var(--ink), 0 1px 0 var(--ink), 0 -1px 0 var(--ink),
      1px 1px 0 var(--ink), -1px -1px 0 var(--ink), 1px -1px 0 var(--ink), -1px 1px 0 var(--ink),
      0 3px 5px rgba(0, 0, 0, 0.55);
  }

  .rule {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    width: 100%;
    color: var(--gold);
    font-size: 10px;
    line-height: 1;
  }
  .rule::before,
  .rule::after {
    content: '';
    display: block;
    width: 31px;
    height: 1px;
    background: linear-gradient(90deg, transparent, var(--gold));
  }
  .rule::after { transform: scaleX(-1); }

  .eyebrow {
    font-size: 10px;
    font-weight: 900;
    letter-spacing: 0.28em;
    line-height: 1.2;
    text-transform: uppercase;
    color: #e7edf5;
  }
  .title {
    font-size: 33px;
    font-weight: 900;
    letter-spacing: 0.045em;
    line-height: 0.98;
    text-transform: uppercase;
    color: var(--white);
  }
  .subtitle {
    max-width: 280px;
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 0.12em;
    line-height: 1.25;
    text-transform: uppercase;
    color: #f0f4f9;
  }
  .timer {
    display: flex;
    align-items: baseline;
    justify-content: center;
    gap: 10px;
    margin-top: 2px;
    font-variant-numeric: tabular-nums;
  }
  .time {
    font-size: 19px;
    font-weight: 900;
    letter-spacing: 0.09em;
    color: #fff;
  }
  .dist {
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 0.08em;
    color: #d8c9a7;
  }
  .marker.warning .time { color: #ffc15e; }
  .marker.critical .time { color: #ff7373; }

  /* looted: the same layout, in green */
  .marker.looted .title { color: #72f0a6; }
  .meta {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 5px;
    flex-wrap: wrap;
    font-size: 12px;
    line-height: 1.2;
    text-transform: uppercase;
  }
  .by {
    font-weight: 800;
    letter-spacing: 0.12em;
    color: #e7edf5;
  }
  .who {
    font-weight: 900;
    letter-spacing: 0.06em;
    color: #72f0a6;
    overflow-wrap: anywhere;
  }

  @keyframes bob {
    0%, 100% { transform: translateY(0); }
    50% { transform: translateY(-5px); }
  }
  @media (prefers-reduced-motion: reduce) {
    .marker { animation: none; }
  }
</style>
