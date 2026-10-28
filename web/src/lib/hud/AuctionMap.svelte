<script>
  // The auction board's map: the same GTA atlas the Map Zone tab uses, framed so every zone being auctioned (and the
  // auction house) is in view. The zone that is up for bidding is painted and its pin BLINKS, so players see at a glance
  // where on the map it actually is; the other zones carry a quiet pin. Click a pin for its territory name.
  import { onMount, onDestroy } from 'svelte';
  import { ATLAS_TILE_URL } from '../util/mapGeometry.js';
  import { hexToRgb } from '../territory/territoryGeometry.js';

  export let lots = [];          // [{ territoryId, name, x, y, color, status, startingBid, xpValue }]
  export let liveId = null;      // territoryId that is being bid on right now
  export let preview = null;     // { cs, spans, color, x, y } - the live zone's painted base
  export let location = null;    // { x, y } the auction house

  // the atlas calibration (same numbers as util/mapGeometry.js createAtlasCRS): pixel = 2^zoom * (a*x + b)
  const A = 0.02072, B = 117.3, C = -0.0205, D = 172.8;
  const W = 640, H = 440;        // drawing size; the element scales to its container
  const MIN_ZOOM = 1, MAX_ZOOM = 5;

  let tiles;                     // <canvas> the atlas tiles are drawn on
  let shape;                     // <canvas> the live zone's painted cells
  let selected = null;           // territoryId whose callout is open
  let arriving = null;           // the zone that has just come up (faster blink for a few seconds)
  let lastLive = null;
  let arriveTimer = null;
  let drawToken = 0;
  let destroyed = false;

  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : null);

  // ── framing ──
  function frame(list, loc, prev) {
    const xs = [], ys = [];
    for (const l of list) { if (num(l.x) != null && num(l.y) != null) { xs.push(Number(l.x)); ys.push(Number(l.y)); } }
    if (loc && num(loc.x) != null && num(loc.y) != null) { xs.push(Number(loc.x)); ys.push(Number(loc.y)); }
    if (prev && prev.spans && prev.spans.length) {
      const cs = prev.cs || 25;
      for (const s of prev.spans) { xs.push(s[1] * cs, (s[2] + 1) * cs); ys.push(s[0] * cs, (s[0] + 1) * cs); }
    }
    if (!xs.length) return null;
    const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
    const pad = Math.max(160, Math.max(maxX - minX, maxY - minY) * 0.22);
    const wM = (maxX - minX) + pad * 2, hM = (maxY - minY) + pad * 2;
    let z = MIN_ZOOM;
    for (let t = MAX_ZOOM; t >= MIN_ZOOM; t--) {
      if (wM * A * 2 ** t <= W && hM * -C * 2 ** t <= H) { z = t; break; }
    }
    const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    const s = 2 ** z;
    return { z, ox: s * (A * cx + B) - W / 2, oy: s * (C * cy + D) - H / 2 };
  }

  // The framing only changes when the zones / the auction house move. The board gets a fresh state object on every bid and every
  // 'can bid' change, so keep the old view object while its numbers are the same - otherwise the tiles reload and the map blinks.
  let view = null;
  $: { const next = frame(lots, location, preview); if (!next) view = null; else if (!view || view.z !== next.z || Math.abs(view.ox - next.ox) > 0.5 || Math.abs(view.oy - next.oy) > 0.5) view = next; }
  const toPx = (v, x, y) => [(2 ** v.z) * (A * x + B) - v.ox, (2 ** v.z) * (C * y + D) - v.oy];

  // ── drawing ──
  // Tiles are kept once loaded and painted straight from the cache, so a redraw never shows a blank map first.
  const tileCache = new Map();
  let drawnKey = '';
  function drawTiles(v) {
    if (!tiles || !v) return;
    const key = v.z + ':' + Math.round(v.ox) + ':' + Math.round(v.oy);
    if (key === drawnKey) return;                              // same picture already on the canvas
    drawnKey = key;
    const token = ++drawToken;
    const ctx = tiles.getContext('2d');
    const limit = 2 ** v.z;                                   // tiles per side at this zoom
    const tx0 = Math.max(0, Math.floor(v.ox / 256)), tx1 = Math.min(limit - 1, Math.floor((v.ox + W) / 256));
    const ty0 = Math.max(0, Math.floor(v.oy / 256)), ty1 = Math.min(limit - 1, Math.floor((v.oy + H) / 256));
    const paint = (tx, ty, img) => {
      ctx.drawImage(img, tx * 256 - v.ox, ty * 256 - v.oy, 256, 256);
      // keep the map calm: a dark wash over the tile, so the pins read first
      ctx.fillStyle = 'rgba(8, 10, 14, 0.38)';
      ctx.fillRect(tx * 256 - v.ox, ty * 256 - v.oy, 256, 256);
    };
    const need = [];
    for (let ty = ty0; ty <= ty1; ty++) {
      for (let tx = tx0; tx <= tx1; tx++) {
        const k = v.z + '/' + tx + '/' + ty;
        const img = tileCache.get(k);
        if (img && img.complete && img.naturalWidth) need.push([tx, ty, img, true]);
        else need.push([tx, ty, null, false, k]);
      }
    }
    // the first draw (nothing cached yet) shows the dark base; later draws never clear first
    if (need.some((n) => !n[3]) && !tileCache.size) { ctx.fillStyle = '#10141b'; ctx.fillRect(0, 0, W, H); }
    for (const [tx, ty, img, ready, k] of need) {
      if (ready) { paint(tx, ty, img); continue; }
      const im = new Image();
      im.onload = () => {
        tileCache.set(k, im);
        if (destroyed || token !== drawToken) return;
        paint(tx, ty, im);
      };
      im.src = ATLAS_TILE_URL.replace('{z}', v.z).replace('{x}', tx).replace('{y}', ty);
    }
  }

  function drawShape(v, prev) {
    if (!shape) return;
    const ctx = shape.getContext('2d');
    ctx.clearRect(0, 0, W, H);
    if (!v || !prev || !prev.spans || !prev.spans.length) return;
    const cs = prev.cs || 25;
    const [r, g, b] = hexToRgb(prev.color);
    ctx.fillStyle = `rgba(${r},${g},${b},0.62)`;
    for (const s of prev.spans) {
      const [x0, y0] = toPx(v, s[1] * cs, (s[0] + 1) * cs);
      const [x1, y1] = toPx(v, (s[2] + 1) * cs, s[0] * cs);
      ctx.fillRect(x0, y0, Math.max(1, x1 - x0) + 0.6, Math.max(1, y1 - y0) + 0.6);
    }
  }

  $: if (tiles && view) drawTiles(view);
  $: if (shape) drawShape(view, preview);

  // ── pins ──
  $: pins = view
    ? lots.filter((l) => num(l.x) != null && num(l.y) != null).map((l) => {
        const [px, py] = toPx(view, Number(l.x), Number(l.y));
        const st = l.territoryId === liveId ? 'live' : l.status === 'WON' ? 'sold' : l.status === 'UNSOLD' ? 'unsold' : 'next';
        return { ...l, left: (px / W) * 100, top: (py / H) * 100, st };
      }).filter((p) => p.left > -4 && p.left < 104 && p.top > -4 && p.top < 104)
    : [];
  $: house = view && location && num(location.x) != null ? (() => { const [px, py] = toPx(view, Number(location.x), Number(location.y)); return { left: (px / W) * 100, top: (py / H) * 100 }; })() : null;
  $: openPin = pins.find((p) => p.territoryId === selected) || null;

  // a zone that has just come up blinks faster for a few seconds
  $: if (liveId !== lastLive) {
    lastLive = liveId;
    if (liveId) {
      arriving = liveId;
      clearTimeout(arriveTimer);
      arriveTimer = setTimeout(() => { arriving = null; }, 5000);
    }
  }

  const statusText = (st) => (st === 'live' ? 'Bidding now' : st === 'sold' ? 'Sold' : st === 'unsold' ? 'No winning bid' : 'Up next');
  const money = (n) => '$' + Number(n || 0).toLocaleString('en-US');
  const pick = (id) => { selected = selected === id ? null : id; };

  onMount(() => { destroyed = false; });
  onDestroy(() => { destroyed = true; clearTimeout(arriveTimer); });
</script>

<div class="amap" role="group" aria-label="Where the territories are">
  <canvas bind:this={tiles} width={W} height={H} class="layer"></canvas>
  <canvas bind:this={shape} width={W} height={H} class="layer"></canvas>

  {#if house}
    <div class="house" style="left:{house.left}%;top:{house.top}%"><i></i><span>Auction house</span></div>
  {/if}

  {#each pins as p (p.territoryId)}
    <button type="button" class="pin {p.st}" class:arrive={arriving === p.territoryId} class:open={selected === p.territoryId}
      style="left:{p.left}%;top:{p.top}%;--c:{p.color || '#c45ee0'}" on:click={() => pick(p.territoryId)} title={p.name}>
      <span class="ring"></span>
      <span class="dot"></span>
      <span class="name">{p.name}</span>
    </button>
  {/each}

  {#if openPin}
    <div class="callout" style="left:{Math.min(78, Math.max(22, openPin.left))}%;top:{Math.max(18, openPin.top)}%">
      <b>{openPin.name}</b>
      <span>{statusText(openPin.st)}{openPin.startingBid ? ' · from ' + money(openPin.startingBid) : ''}{openPin.xpValue ? ' · ' + Number(openPin.xpValue).toLocaleString() + ' XP' : ''}</span>
    </div>
  {/if}

  {#if !view}<div class="empty">Map unavailable</div>{/if}
</div>

<style>
  .amap { position: relative; width: 100%; aspect-ratio: 640 / 440; overflow: hidden; background: #10141b; border: 1px solid #2a2e35; border-radius: var(--r-ctl); }
  .layer { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
  .empty { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: #8d92a5; font-size: 0.9em; }

  .house { position: absolute; width: 0; height: 0; pointer-events: none; z-index: 2; }
  .house i { position: absolute; left: -0.4em; top: -0.4em; width: 0.8em; height: 0.8em; background: #ffc857; border: 2px solid #0a0b10; transform: rotate(45deg); box-sizing: border-box; }
  .house span { position: absolute; right: 0.75em; top: -0.6em; margin-top: 0; font-size: 0.62em; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; color: #ffc857; background: rgba(10, 11, 16, 0.85); padding: 0.15em 0.5em; border-radius: var(--r-tag); white-space: nowrap; }

  /* the pin: a dot with a ring. Only the zone being bid on blinks. */
  .pin { position: absolute; width: 0; height: 0; padding: 0; border: 0; background: none; cursor: pointer; z-index: 3; font: inherit; }
  .pin .dot { position: absolute; left: -0.45em; top: -0.45em; width: 0.9em; height: 0.9em; border-radius: 50%; background: var(--c); border: 2px solid #f4f4f7; box-sizing: border-box; }
  .pin .ring { position: absolute; left: -1.1em; top: -1.1em; width: 2.2em; height: 2.2em; border-radius: 50%; border: 2px solid var(--c); opacity: 0; box-sizing: border-box; }
  .pin .name { position: absolute; left: 0.9em; top: -0.7em; font-size: 0.66em; font-weight: 800; letter-spacing: 0.04em; color: #f4f4f7; background: rgba(10, 11, 16, 0.88); padding: 0.2em 0.55em; border-radius: var(--r-tag); white-space: nowrap; }
  .pin.next .dot { opacity: 0.8; }
  .pin.sold .dot, .pin.unsold .dot { opacity: 0.45; }
  .pin.sold .name, .pin.unsold .name { opacity: 0.6; }
  .pin.live { z-index: 4; }
  .pin.live .dot { width: 1.1em; height: 1.1em; left: -0.55em; top: -0.55em; animation: dot-blink 0.9s ease-in-out infinite; }
  .pin.live .ring { animation: ring-ping 1.4s ease-out infinite; }
  .pin.live .name { background: var(--c); color: #0a0b10; font-size: 0.78em; }
  .pin.live.arrive .dot { animation-duration: 0.35s; }
  .pin.live.arrive .ring { animation-duration: 0.7s; }

  .callout { position: absolute; transform: translate(-50%, -135%); z-index: 6; display: flex; flex-direction: column; gap: 0.15em; background: #14151d; border: 1px solid var(--accent, #c45ee0); border-radius: var(--r-ctl); padding: 0.45em 0.8em; pointer-events: none; white-space: nowrap; }
  .callout b { font-size: 0.95em; }
  .callout span { font-size: 0.7em; color: #9aa0b4; }

  @keyframes dot-blink { 0%, 100% { opacity: 1; } 50% { opacity: 0.2; } }
  @keyframes ring-ping { 0% { transform: scale(0.4); opacity: 0.95; } 100% { transform: scale(1.9); opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .pin.live .dot, .pin.live .ring { animation: none; } .pin.live .ring { opacity: 0.6; } }
</style>
