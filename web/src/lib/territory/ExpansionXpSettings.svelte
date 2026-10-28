<script>
  // Territory (Map Zone) → Expansion XP: how much Gang XP a gang pays to grow a territory by painting land.
  // There are no expansion levels: the more land painted, the more XP is taken. The price lives here (not in the auction form)
  // because it applies to every gang and every territory, and an admin changes it live.
  //   · Config.Territory.paint (config.lua) is only the DEFAULT; the number below overrides it until "Use config.lua"
  //   · applying it re-prices every open Map Zone at once (the server pushes it to every admin and gang member)
  import { territoryState } from './territoryStore.js';
  import { adminSetPaintRate } from '../api/territory.js';
  import { confirmAction } from '../tablet/ui/confirm.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import '../tablet/tablet-theme.css';

  // GTA V: playable land ~ 48 km² (the whole map box is ~ 96 km²). One cell = 25 m x 25 m = 625 m², so 1 km² = 1,600 cells.
  const CELLS_PER_KM2 = 1600;
  const PLAYABLE_KM2 = 48.0;

  let rateXp = '';
  let rateMax = '';
  let dirty = false;
  let busy = false;
  let msg = '';
  let err = '';
  let sampleKm2 = 0.5;

  $: paint = ($territoryState.config || {}).paint || {};
  // the boxes follow the live value until the admin starts typing
  $: if (!dirty) { rateXp = paint.xpPerCell ?? ''; rateMax = paint.maxNewCells ?? ''; }
  $: changed = Number(rateXp) !== Number(paint.xpPerCell) || Number(rateMax) !== Number(paint.maxNewCells);
  $: xpPerKm2 = Math.max(0, Math.floor(Number(rateXp) || 0)) * CELLS_PER_KM2;

  // calculator, at the price that is in force right now
  $: live = Number(paint.xpPerCell) || 0;
  $: cells = Math.round(Number(sampleKm2 || 0) * CELLS_PER_KM2);
  $: cost = cells * live;
  $: landShare = ((Number(sampleKm2 || 0) / PLAYABLE_KM2) * 100).toFixed(2);

  async function save(reset = false) {
    msg = err = '';
    if (!reset && (rateXp === '' || Number(rateXp) < 0)) { err = 'Enter the XP one painted cell costs (0 or more).'; return; }
    if (!reset && (rateMax === '' || Number(rateMax) < 1)) { err = 'Enter how many cells one save may add (1 or more).'; return; }
    const ok = await confirmAction(reset
      ? `Go back to the values in config.lua (${paint.configXpPerCell ?? '?'} XP per cell)?\n\nEvery gang that can paint is re-priced at once.`
      : `Set the price of painting land to ${Number(rateXp).toLocaleString()} XP per cell (${xpPerKm2.toLocaleString()} XP per km²), up to ${Number(rateMax).toLocaleString()} new cells per save?\n\nThis applies to every gang that can paint, straight away. A gang that is painting right now sees the new price at once.`,
      { title: 'Expansion XP', confirmLabel: reset ? 'Use config.lua' : 'Apply to all gangs' });
    if (!ok) return;
    busy = true;
    const r = reset ? await adminSetPaintRate(null, null) : await adminSetPaintRate(Number(rateXp), Number(rateMax));
    busy = false;
    if (!r || !r.ok) { err = (r && r.error) || 'Failed.'; return; }
    dirty = false;
    msg = reset ? 'Back to the config.lua value.' : `Painting now costs ${r.paint.xpPerCell} XP per cell for every gang.`;
  }
</script>

<div class="xp">
  <header class="head">
    <span class="ico"><Icon name="zap" size={18} /></span>
    <div>
      <h3>Expansion XP</h3>
      <p>A gang grows a territory by painting land onto it. Every painted cell costs Gang XP, so the bigger the area, the more XP is taken. Erasing painted land refunds it at the current price.</p>
    </div>
    <span class="state" class:live={!paint.fromConfig}>{paint.fromConfig ? 'Using config.lua' : 'Live setting in force'}</span>
  </header>

  {#if err}<div class="note bad">{err}</div>{/if}
  {#if msg}<div class="note ok">{msg}</div>{/if}

  <section class="card">
    <div class="card-title">Price of painting land <em>for every gang, applied live</em></div>
    <div class="two">
      <label class="fld"><span>XP per painted cell</span><input type="number" min="0" max="100000" bind:value={rateXp} on:input={() => (dirty = true)} /></label>
      <label class="fld"><span>Most cells one save may add</span><input type="number" min="1" max="80000" bind:value={rateMax} on:input={() => (dirty = true)} /></label>
    </div>
    <div class="preview">{Number(rateXp || 0).toLocaleString()} XP per cell · {xpPerKm2.toLocaleString()} XP per km² · a cell is 25 m × 25 m ({(CELLS_PER_KM2).toLocaleString()} cells = 1 km²)</div>
    <div class="row">
      <button type="button" class="btn btn-primary" disabled={busy || !changed} on:click={() => save(false)}>Apply to all gangs</button>
      <button type="button" class="btn btn-steel" disabled={busy || paint.fromConfig} on:click={() => save(true)} title="Forget the live setting and use config.lua">Use config.lua</button>
    </div>
    <div class="hint">Default in config.lua (<code>Config.Territory.paint</code>): <b>{paint.configXpPerCell ?? '?'} XP</b> per cell, <b>{paint.configMaxNewCells ?? '?'}</b> cells per save.</div>
  </section>

  <div class="grid">
    <div class="metric"><span class="lbl">GTA playable land</span><span class="val">{PLAYABLE_KM2.toFixed(2)} km²</span><span class="sub">map box: 96 km²</span></div>
    <div class="metric"><span class="lbl">Cell</span><span class="val">625 m²</span><span class="sub">25 m × 25 m</span></div>
    <div class="metric"><span class="lbl">Conversion</span><span class="val">{CELLS_PER_KM2.toLocaleString()} cells</span><span class="sub">equal 1 km²</span></div>
    <div class="metric"><span class="lbl">Rate in force</span><span class="val">{live.toLocaleString()} XP / cell</span><span class="sub">{(live * CELLS_PER_KM2).toLocaleString()} XP per km²</span></div>
  </div>

  <section class="card">
    <div class="card-title"><Icon name="activity" size={13} /> What an expansion costs <em>at the rate in force</em></div>
    <div class="calc">
      <label class="fld grow"><span>Size of the new area (km²)</span><input type="number" step="0.05" min="0.05" max="10" bind:value={sampleKm2} /></label>
      <div class="chips">
        {#each [0.05, 0.1, 0.25, 0.5, 1] as k}<button type="button" class="chip" class:on={Number(sampleKm2) === k} on:click={() => (sampleKm2 = k)}>{k} km²</button>{/each}
      </div>
      <div class="out">
        <div><span class="lbl">Cells</span><span class="val">{cells.toLocaleString()}</span></div>
        <div><span class="lbl">XP taken from the gang</span><span class="val cost">−{cost.toLocaleString()} XP</span></div>
        <div><span class="lbl">Share of the playable map</span><span class="val">{landShare}%</span></div>
      </div>
    </div>
  </section>
</div>

<style>
  /* Fills use the theme tokens (glass panel / head, themed lines), so the page follows the chosen background and accent. */
  .xp { display: flex; flex-direction: column; gap: 14px; }
  .head { display: flex; align-items: center; gap: 12px; padding: 14px 16px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); border-radius: var(--r-panel, 10px); }
  .head h3 { margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; line-height: 1.1; }
  .head p { margin: 3px 0 0; font-size: var(--fs-small); color: var(--text-muted, #aeb5bd); max-width: 72ch; }
  .ico { flex: none; width: 40px; height: 40px; display: grid; place-items: center; border-radius: 10px; color: var(--accent-primary-light, #7bb6f2); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .state { margin-left: auto; flex: none; padding: 4px 11px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; color: var(--text-muted, #aeb5bd); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.3)); }
  .state.live { color: #111111; border-color: rgb(255, 200, 87); background: rgb(255, 200, 87); }

  .card { display: flex; flex-direction: column; gap: 12px; padding: 14px 16px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); border-radius: var(--r-panel, 10px); }
  .card-title { display: flex; align-items: center; gap: 7px; font-size: var(--fs-body); font-weight: 600; }
  .card-title em, .fld span em { font-style: normal; font-weight: 400; color: var(--text-muted, #8d949c); font-size: var(--fs-meta); }
  .two { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .fld { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
  .fld.grow { flex: 1 1 220px; }
  /* Fields: theme input tokens, comfortable height, a clear focus state. */
  .fld input, .fld select, .fld textarea {
    width: 100%; box-sizing: border-box; min-height: 40px; padding: 0 12px;
    background: var(--input-bg, rgba(11, 15, 22, 0.75)); border: 1px solid var(--input-border, rgba(110, 140, 180, 0.28)); border-radius: var(--r-ctl, 8px);
    color: var(--text-main, #fff); font-family: inherit; font-size: var(--fs-body);
    transition: border-color 0.12s ease, background 0.12s ease;
  }
  .fld textarea { padding: 10px 12px; line-height: 1.45; }
  .fld input::placeholder, .fld textarea::placeholder { color: var(--text-placeholder, #6f7986); }
  .fld input:hover, .fld select:hover, .fld textarea:hover { border-color: var(--input-border-hover, rgba(140, 175, 220, 0.45)); }
  .fld input:focus, .fld select:focus, .fld textarea:focus { outline: none; border-color: var(--input-focus-border, var(--accent-primary)); background: var(--input-bg-focus, var(--input-bg)); }
  .fld input:disabled, .fld select:disabled { opacity: 0.5; cursor: not-allowed; }
  .fld > span { font-size: var(--fs-small); font-weight: 600; color: var(--text-dim, #c9ced4); }

  .row { display: flex; gap: 8px; flex-wrap: wrap; }
  .preview { padding: 9px 12px; border-radius: var(--r-ctl, 6px); font-size: var(--fs-small); background: var(--glass-head, rgba(var(--ltc-8-11-16, 8, 11, 16), 0.5)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.2)); }
  .hint { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .hint code { padding: 1px 6px; border-radius: 5px; background: var(--glass-head, rgba(var(--ltc-8-11-16, 8, 11, 16), 0.5)); }
  .note { padding: 9px 12px; border-radius: var(--r-ctl, 6px); font-size: var(--fs-small); border: 1px solid; }
  .note.ok { color: #46c98b; border-color: rgba(70, 201, 139, 0.5); }
  .note.bad { color: #ff8a8d; border-color: rgba(229, 72, 77, 0.5); }

  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 10px; }
  .metric { display: flex; flex-direction: column; gap: 3px; padding: 11px 14px; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.2)); border-radius: var(--r-ctl, 8px); }
  .lbl { font-size: var(--fs-meta); color: var(--text-muted, #aeb5bd); }
  .val { font-family: var(--font-display); font-size: var(--fs-title); font-weight: 600; font-variant-numeric: tabular-nums; }
  .val.cost { color: #f87171; }
  .sub { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }

  .chip, .btn { cursor: pointer; }
  .calc { display: flex; align-items: flex-end; gap: 14px; flex-wrap: wrap; }
  .chips { display: flex; gap: 6px; flex-wrap: wrap; align-self: flex-end; padding-bottom: 3px; }
  .chip { height: 28px; padding: 0 12px; border-radius: 14px; font-size: var(--fs-small); font-weight: 600; color: var(--text-dim, #c9ced4); background: var(--glass-head, rgba(255, 255, 255, 0.05)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); }
  .chip:hover, .chip.on { border-color: var(--accent-primary); color: var(--text-main, #fff); }
  .out { display: flex; gap: 22px; flex-wrap: wrap; flex: 2 1 320px; padding: 10px 14px; border-radius: var(--r-ctl, 6px); background: var(--glass-head, rgba(var(--ltc-8-11-16, 8, 11, 16), 0.5)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.2)); }
  .out div { display: flex; flex-direction: column; }
</style>
