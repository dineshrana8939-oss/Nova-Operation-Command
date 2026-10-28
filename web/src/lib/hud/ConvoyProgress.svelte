<script>
  import { convoyProgress, deliveryHud } from './hudStore.js';
  import { themeVars } from './eventThemes.js';
  import './hud-shared.css';

  // The convoy progress card, under the delivery clock (TimerCard: top 104px) and built from the same card (hx-card, convoy orange).
  // Header: what it is + how far along the route the convoy is. Three tiles: trucks delivered, checkpoints cleared, route points
  // crossed. A segmented bar for the route, and one chip per stage underneath (checkpoints in route order, then the destination
  // flag): filled = done, blinking outline = the stage the convoy is on, dim = still to come. Without a clock it moves up.
  $: p = $convoyProgress;
  $: top = $deliveryHud.visible ? 172 : 104;
  $: stages = p.stages || [];
  $: numbered = (() => { let n = 0; return stages.map((s) => (s.k === 'cp' ? { ...s, n: ++n } : { ...s, n: 0 })); })();

  const SEGMENTS = 26;
  $: routePct = p.routeTotal > 0 ? Math.max(0, Math.min(1, p.routeDone / p.routeTotal)) : 0;
  $: litSegments = Math.round(routePct * SEGMENTS);
  $: tiles = [
    { key: 'trucks', label: 'Delivered', done: p.delivered, total: p.totalTrucks, show: true },
    { key: 'cps', label: 'Checkpoints', done: p.checkpointsDone, total: p.checkpointsTotal, show: p.checkpointsTotal > 0 },
    { key: 'route', label: 'Route', done: p.routeDone, total: p.routeTotal, show: p.routeTotal > 0 },
  ].filter((t) => t.show);
</script>

{#if p.visible}
  <div class="wrap" style="top:{top}px; {themeVars('convoy')}" role="status" aria-label="Convoy progress">
    <div class="hx-card box">
      <div class="hx-texture"></div>
      <div class="hx-rail"><span></span></div>

      <div class="head">
        <span class="kicker">CONVOY PROGRESS</span>
        {#if p.routeTotal > 0}<span class="pct">{Math.round(routePct * 100)}<small>%</small></span>{/if}
      </div>

      <div class="tiles" style="--cols:{tiles.length}">
        {#each tiles as t (t.key)}
          <div class="tile" class:complete={t.total > 0 && t.done >= t.total}>
            <div class="val"><b>{t.done}</b><span>/{t.total}</span></div>
            <div class="lab">{t.label}</div>
          </div>
        {/each}
      </div>

      {#if p.routeTotal > 0}
        <div class="hx-segments route-bar" aria-hidden="true">
          {#each Array(SEGMENTS) as _, i}<i class:on={i < litSegments}></i>{/each}
        </div>
      {/if}

      {#if numbered.length > 0}
        <div class="stages">
          {#each numbered as s, i (i)}
            <div class="stage {s.s}" class:wait={p.waitingPolice && s.s === 'current'} title={s.k === 'dest' ? 'Destination' : `Checkpoint ${s.n}`}>
              {#if s.k === 'dest'}
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 21V4M6 5h11l-2 4 2 4H6"/></svg>
              {:else}
                {s.n}
              {/if}
            </div>
          {/each}
        </div>
      {/if}
      {#if p.waitingPolice}<div class="warn">Escort needed in the checkpoint zone</div>{/if}
    </div>
  </div>
{/if}

<style>
  .wrap {
    position: fixed;
    left: 24px;
    width: 268px;
    pointer-events: none;
    user-select: none;
    z-index: 9990;
    transition: top 0.25s ease;
  }
  .box { position: relative; padding: 10px 12px 11px; animation: hxEnterLeft 0.6s cubic-bezier(0.16, 1, 0.3, 1) both; }

  .head { position: relative; display: flex; align-items: baseline; justify-content: space-between; gap: 10px; margin-bottom: 8px; }
  .kicker {
    color: var(--accent2);
    font-size: 10.5px;
    font-weight: 900;
    letter-spacing: 0.1em;
    white-space: nowrap;
  }
  .pct {
    color: #fff;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 16px;
    font-weight: 700;
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }
  .pct small { margin-left: 1px; color: var(--accent2); font-size: 11px; font-weight: 700; }

  /* three equal tiles: the number big and white, the total small in the event colour, the label under it */
  .tiles { position: relative; display: grid; grid-template-columns: repeat(var(--cols, 3), minmax(0, 1fr)); gap: 6px; }
  .tile {
    padding: 6px 7px 6px;
    border-radius: var(--r-ctl);
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.035);
    min-width: 0;
  }
  .tile.complete { border-color: rgba(var(--accentRGB), 0.55); background: rgba(var(--accentRGB), 0.1); }
  .val {
    display: flex;
    align-items: baseline;
    gap: 1px;
    color: #fff;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    line-height: 1;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .val b { font-size: 24px; font-weight: 700; }
  .val span { color: var(--accent2); font-size: 13px; font-weight: 700; }
  /* title case, not caps: "Checkpoints" has to fit a third of the card */
  .lab {
    margin-top: 4px;
    color: #9aa3ad;
    font-size: 10.5px;
    font-weight: 700;
    letter-spacing: 0.01em;
    white-space: nowrap;
  }

  .route-bar { position: relative; margin-top: 9px; height: 4px; }

  .stages {
    position: relative;
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
    margin-top: 9px;
    padding-top: 9px;
    border-top: 1px solid rgba(255, 255, 255, 0.07);
  }
  .stage {
    display: grid;
    place-items: center;
    min-width: 28px;
    height: 22px;
    padding: 0 6px;
    box-sizing: border-box;
    border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.04);
    color: #6f7684;
    font-size: 12px;
    font-weight: 900;
    font-variant-numeric: tabular-nums;
  }
  .stage svg { width: 13px; height: 13px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
  .stage.done { background: var(--accent); border-color: var(--accent); color: #1b1005; }
  .stage.current { border-color: var(--accent); color: var(--accent2); background: rgba(var(--accentRGB), 0.14); animation: stageBlink 1.3s ease-in-out infinite alternate; }
  .stage.current.wait { border-color: #ffc857; color: #ffc857; background: rgba(255, 200, 87, 0.12); }
  .warn { position: relative; margin-top: 8px; color: #ffc857; font-size: 10px; font-weight: 800; letter-spacing: 0.06em; text-transform: uppercase; }
  @keyframes stageBlink { from { opacity: 1; } to { opacity: 0.55; } }
</style>
