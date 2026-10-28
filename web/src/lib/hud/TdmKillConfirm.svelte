<script>
  import { fade } from 'svelte/transition';
  import { tdmKillConfirm } from './hudStore.js';
</script>

<!-- Personal "Kill Confirmed" emblem for the KILLER, bottom-centre like Valorant's kill confirm. The outer anchor only
     positions it and carries the fade-out; the inner card carries the pop-in, so the two animations never fight over
     the same element's transform. A new kill bumps the key and replays the pop-in. No backdrop-filter anywhere. -->
{#if $tdmKillConfirm.visible}
  <div class="anchor" out:fade={{ duration: 220 }}>
    {#key $tdmKillConfirm.key}
      <div class="kill-confirm" aria-hidden="true">
        <div class="emblem">
          <div class="halo"></div>
          <div class="ring"></div>
          <div class="ring-inner"></div>
          <i class="tick tick-top"></i>
          <i class="tick tick-bottom"></i>
          <i class="tick tick-left"></i>
          <i class="tick tick-right"></i>
          <i class="spark spark-one"></i>
          <i class="spark spark-two"></i>
          <i class="spark spark-three"></i>
          <i class="spark spark-four"></i>
          <div class="fire-glow"></div>
          <svg class="skull" viewBox="0 0 220 190">
            <g class="crossbones">
              <path d="M18 35c-9-8-19 1-12 10-9 7-2 18 9 14l72 51 8-11-72-52c3-10-7-17-15-12Z" />
              <path d="M202 35c9-8 19 1 12 10 9 7 2 18-9 14l-72 51-8-11 72-52c-3-10 7-17 15-12Z" />
              <path d="M18 155c-9 8-19-1-12-10-9-7-2-18 9-14l72-51 8 11-72 52c3 10-7 17-15 12Z" />
              <path d="M202 155c9 8 19-1 12-10 9-7 2-18-9-14l-72-51-8 11 72 52c-3 10 7 17 15 12Z" />
            </g>
            <path class="skull-outline" d="M110 8C72 8 48 34 48 72c0 19 5 34 16 46l4 18c2 11 10 20 20 25l8 14c3 5 8 8 14 8h0c6 0 11-3 14-8l8-14c10-5 18-14 20-25l4-18c11-12 16-27 16-46 0-38-24-64-62-64Z" />
            <path class="skull-detail" d="M60 56c5-20 22-34 50-36 28 2 45 16 50 36M55 91l13 12m97-12-13 12M75 136c9 7 21 11 35 11s26-4 35-11" />
            <path class="skull-shadow" d="M57 74c8-14 25-18 42-10 8 4 10 16 7 29-3 13-12 21-27 21-18 0-29-12-27-27 1-5 2-9 5-13Zm106 0c-8-14-25-18-42-10-8 4-10 16-7 29 3 13 12 21 27 21 18 0 29-12 27-27-1-5-2-9-5-13Z" />
            <path class="skull-shadow" d="m110 99-14 24 14 10 14-10-14-24Z" />
            <path class="skull-jaw" d="M75 132c10 7 22 10 35 10s25-3 35-10l-5 23c-1 6-5 11-11 14l-8 12c-3 4-7 6-11 6s-8-2-11-6l-8-12c-6-3-10-8-11-14l-5-23Z" />
            <path class="tooth-line" d="M82 145v15m12-13v19m11-18v22m11-22v22m11-22v18m11-19v13M75 140c11 5 22 7 35 7s24-2 35-7" />
            <path class="skull-crack" d="m82 19 8 12-5 8 8 8m39-28-8 12 5 8-8 8M54 83l12 5m100-5-12 5" />
          </svg>
        </div>
        <div class="label">Kill Confirmed</div>
        <div class="rule"></div>
        <div class="names">
          <span class="killer">{$tdmKillConfirm.killer || 'YOU'}</span>
          <span class="cross">✕</span>
          <span class="victim">{$tdmKillConfirm.victim || 'ENEMY'}</span>
        </div>
      </div>
    {/key}
  </div>
{/if}

<style>
  .anchor {
    --accent: #24f0a0;
    --white: #f4f6f8;
    --muted: #d4d9df;
    --shadow: #000;
    --s: 1;
    position: fixed;
    left: 50%;
    bottom: 9.5%;
    width: 190px;
    transform: translateX(-50%);
    pointer-events: none;
    z-index: 9987;
    font-family: var(--font-ui, Inter, Arial, sans-serif);
  }

  .kill-confirm {
    display: flex;
    width: 100%;
    flex-direction: column;
    align-items: center;
    gap: 7px;
    color: var(--white);
    text-align: center;
    animation: enter 0.28s cubic-bezier(0.16, 0.8, 0.25, 1) both;
  }

  @keyframes enter {
    from { opacity: 0; transform: translateY(12px) scale(calc(0.88 * var(--s))); }
    to { opacity: 1; transform: translateY(0) scale(var(--s)); }
  }

  .emblem {
    position: relative;
    display: grid;
    width: 82px;
    height: 82px;
    place-items: center;
    isolation: isolate;
  }

  .emblem::before {
    position: absolute;
    z-index: -1;
    inset: 7px;
    border: 1px solid rgb(244 246 248 / 55%);
    border-radius: 50%;
    background: rgb(5 8 10 / 82%);
    box-shadow: 0 0 12px rgb(0 0 0 / 90%);
    content: '';
  }

  .halo {
    position: absolute;
    z-index: -2;
    inset: 15px;
    border-radius: 50%;
    background: var(--accent);
    filter: blur(17px);
    opacity: 0.25;
  }

  .ring,
  .ring-inner {
    position: absolute;
    inset: 5px;
    border: 2px solid rgb(242 247 250 / 90%);
    border-radius: 50%;
    filter: drop-shadow(0 0 4px rgb(255 255 255 / 35%));
  }

  .ring::before,
  .ring::after {
    position: absolute;
    inset: -5px;
    border: 5px solid transparent;
    border-top-color: var(--accent);
    border-bottom-color: var(--accent);
    border-radius: 50%;
    content: '';
    filter: drop-shadow(0 0 5px rgb(36 240 160 / 45%));
    transform: rotate(-35deg);
  }

  .ring::after {
    inset: -9px;
    border-width: 1px;
    border-right-color: var(--white);
    border-left-color: var(--white);
    opacity: 0.8;
    transform: rotate(18deg);
  }

  .ring-inner {
    inset: 15px;
    border-width: 1px;
    border-color: #e9f4ef;
    opacity: 0.75;
  }

  .fire-glow {
    position: absolute;
    z-index: 1;
    width: 58px;
    height: 58px;
    border-radius: 50%;
    background: radial-gradient(circle, rgb(255 191 64 / 38%) 0 20%, rgb(255 88 20 / 35%) 42%, rgb(220 30 8 / 0%) 73%);
    filter: blur(5px);
    animation: fire-pulse 1.1s ease-in-out infinite alternate;
  }

  @keyframes fire-pulse {
    from { opacity: 0.68; transform: scale(0.92); }
    to { opacity: 1; transform: scale(1.12); }
  }

  .skull {
    position: relative;
    z-index: 2;
    display: block;
    width: 54px;
    height: 47px;
    overflow: visible;
    filter: drop-shadow(0 0 2px #ff8a22) drop-shadow(0 0 5px #e6370b);
  }

  .skull-outline { fill: #e5e7e8; stroke: #111416; stroke-width: 4; stroke-linejoin: round; }
  .skull-detail { fill: none; stroke: #70777b; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
  .skull-shadow { fill: #070809; stroke: #171a1c; stroke-width: 3; stroke-linejoin: round; }
  .skull-jaw { fill: #d6d9da; stroke: #111416; stroke-width: 3.5; stroke-linejoin: round; }
  .skull-crack { fill: none; stroke: #969da0; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
  .crossbones { fill: #e1e4e5; stroke: #111416; stroke-width: 5; stroke-linejoin: round; }
  .tooth-line { fill: none; stroke: #555b5e; stroke-width: 1.5; stroke-linecap: round; }

  .tick {
    position: absolute;
    width: 2px;
    height: 9px;
    background: var(--white);
    opacity: 0.95;
  }
  .tick-top { top: -3px; left: 50%; transform: translateX(-50%); }
  .tick-bottom { bottom: -3px; left: 50%; transform: translateX(-50%); }
  .tick-left { top: 50%; left: -3px; transform: translateY(-50%) rotate(90deg); }
  .tick-right { top: 50%; right: -3px; transform: translateY(-50%) rotate(90deg); }

  .spark {
    position: absolute;
    width: 3px;
    height: 3px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 7px 2px rgb(36 240 160 / 45%);
    animation: sparkle 1.2s ease-out infinite;
  }
  .spark-one { top: 28px; left: 0; }
  .spark-two { top: 18px; right: 2px; animation-delay: 0.35s; }
  .spark-three { right: 8px; bottom: 11px; animation-delay: 0.7s; }
  .spark-four { bottom: 15px; left: 7px; animation-delay: 0.2s; }

  @keyframes sparkle {
    0% { opacity: 0; transform: scale(0.3); }
    40% { opacity: 1; transform: scale(1.4); }
    100% { opacity: 0; transform: translateY(-8px) scale(0.3); }
  }

  .label,
  .names {
    -webkit-text-stroke: 0.3px #050607;
    text-shadow: 0 1px 4px var(--shadow), 0 0 8px var(--shadow);
  }

  .label {
    font-size: 10px;
    font-weight: 900;
    letter-spacing: 2.5px;
    line-height: 1;
    text-transform: uppercase;
  }

  .rule {
    width: 74px;
    height: 1px;
    background: linear-gradient(90deg, transparent, var(--accent), transparent);
    box-shadow: 0 0 7px rgb(36 240 160 / 30%);
  }

  .names {
    display: flex;
    max-width: 190px;
    align-items: center;
    justify-content: center;
    gap: 7px;
    font-size: 10px;
    font-weight: 800;
    white-space: nowrap;
  }

  .killer,
  .victim {
    overflow: hidden;
    max-width: 82px;
    text-overflow: ellipsis;
  }
  .killer { color: #fff; }
  .victim { color: var(--muted); }
  .cross { color: var(--accent); font-size: 12px; }

  @media (max-height: 500px) {
    .anchor { --s: 0.8; bottom: 5%; }
  }
  @media (max-width: 480px) {
    .anchor { --s: 0.88; bottom: 11%; }
  }

  @media (prefers-reduced-motion: reduce) {
    .kill-confirm, .fire-glow, .spark { animation: none; }
  }
</style>
