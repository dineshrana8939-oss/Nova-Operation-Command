<script>
  import { crosshairPanelOpen, crosshairCfg, DEFAULT_CROSSHAIR } from './hudStore.js';
  import { fetchNui } from '../api/nui.js';
  import CrosshairShape from './CrosshairShape.svelte';
  import Icon from '../tablet/ui/Icon.svelte';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import '../tablet/tablet-theme.css';
  import '../../styles/flat.css';   // this window wears the same theme as the Event Status panel

  const SHAPES = [
    { id: 'cross', label: 'Cross' },
    { id: 'tshape', label: 'T-shape' },
    { id: 'dot', label: 'Dot' },
    { id: 'circle', label: 'Circle' },
    { id: 'diamond', label: 'Diamond' },
    { id: 'chevron', label: 'Chevron' },
  ];
  const COLORS = ['#368fe9', '#ffffff', '#ff5d50', '#46d69a', '#38c7ff', '#ffc857', '#e070ff'];
  const SLIDERS = [
    { key: 'size', label: 'Size', min: 2, max: 40, unit: '' },
    { key: 'thickness', label: 'Thickness', min: 1, max: 10, unit: '' },
    { key: 'gap', label: 'Gap', min: 0, max: 30, unit: '' },
    { key: 'opacity', label: 'Opacity', min: 10, max: 100, unit: '%' },
    { key: 'dotSize', label: 'Centre dot size', min: 1, max: 8, unit: '' },
  ];
  const TOGGLES = [
    { key: 'enabled', label: 'Crosshair on' },
    { key: 'outline', label: 'Outline' },
    { key: 'centerDot', label: 'Centre dot' },
    { key: 'pulse', label: 'Recoil pulse' },
  ];

  let draft = { ...DEFAULT_CROSSHAIR };
  let wasOpen = false;
  let saveTimer = null;
  let kick = 0;

  // Copy the saved design in each time the panel opens.
  $: if ($crosshairPanelOpen && !wasOpen) {
    wasOpen = true;
    draft = { ...DEFAULT_CROSSHAIR, ...$crosshairCfg };
  } else if (!$crosshairPanelOpen) {
    wasOpen = false;
  }

  // Every change is applied live (debounced) — there is no separate save step to forget.
  function change() {
    draft = draft;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => fetchNui('crosshair:save', draft), 150);
  }
  function pick(key, value) { draft[key] = value; change(); }
  function reset() { draft = { ...DEFAULT_CROSSHAIR }; change(); }
  const fill = (v, s) => `${Math.max(0, Math.min(100, ((v - s.min) / (s.max - s.min)) * 100))}%`;

  function close() {
    clearTimeout(saveTimer);
    fetchNui('crosshair:save', draft);
    crosshairPanelOpen.set(false);
    fetchNui('crosshair:close');
  }
  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); close(); }
  }

  // preview "fire" button so the recoil pulse can be judged
  function fire() {
    kick = Math.max(3, draft.gap * 0.5 + 2);
    setTimeout(() => (kick = 0), 120);
  }
</script>

<svelte:window on:keydown={$crosshairPanelOpen ? onKey : undefined} />

{#if $crosshairPanelOpen}
  <div class="overlay" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} style={$gangThemeStyle}>
    <!-- the shape icons, one per crosshair shape -->
    <svg width="0" height="0" style="position:absolute" aria-hidden="true">
      <defs>
        <symbol id="xh-cross" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 3v6M12 15v6M3 12h6M15 12h6"/></symbol>
        <symbol id="xh-tshape" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 15v6M3 12h6M15 12h6"/></symbol>
        <symbol id="xh-dot" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="3.2"/></symbol>
        <symbol id="xh-circle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="12" cy="12" r="7.5"/></symbol>
        <symbol id="xh-diamond" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"><path d="M12 3.5l8.5 8.5-8.5 8.5L3.5 12z"/></symbol>
        <symbol id="xh-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 15l7-7 7 7"/></symbol>
      </defs>
    </svg>

    <div class="panel" role="dialog" aria-label="Crosshair settings">
      <header class="head">
        <span class="mark"><Icon name="crosshair" size={20} /></span>
        <div class="heading">
          <h1>Crosshair</h1>
          <p>Combat settings · changes save automatically</p>
        </div>
        <button type="button" class="btn btn-primary done" on:click={close}><kbd>Esc</kbd> Done</button>
      </header>

      <div class="body">
        <div class="preview-col">
          <div class="preview">
            <div class="bg"></div>
            <CrosshairShape cfg={draft} {kick} />
          </div>
          <button type="button" class="btn btn-secondary" on:click={fire}>Test recoil pulse</button>
          <p class="note">Shown in TDM matches and the Practice Range while you hold a weapon.</p>
        </div>

        <div class="controls">
          <section>
            <h2>Shape</h2>
            <div class="shapes">
              {#each SHAPES as sh}
                <button type="button" class="shape" class:on={draft.shape === sh.id} aria-pressed={draft.shape === sh.id} on:click={() => pick('shape', sh.id)}>
                  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><use href={`#xh-${sh.id}`} /></svg>
                  {sh.label}
                </button>
              {/each}
            </div>
          </section>

          <section>
            <h2>Colour</h2>
            <div class="swatches">
              {#each COLORS as c}
                <button type="button" class="sw" class:on={draft.color.toLowerCase() === c} style="--c:{c}" aria-label={`Colour ${c}`} aria-pressed={draft.color.toLowerCase() === c} on:click={() => pick('color', c)}></button>
              {/each}
              <label class="picker-wrap" title="Custom colour">
                <input class="picker" type="color" bind:value={draft.color} on:input={change} aria-label="Custom colour" />
                <span class="picker-hex">{draft.color}</span>
              </label>
            </div>
          </section>

          <section class="sliders">
            {#each SLIDERS as s}
              <label class="slider">
                <span class="s-name">{s.label}</span>
                <input type="range" min={s.min} max={s.max} bind:value={draft[s.key]} on:input={change} style="--p:{fill(draft[s.key], s)}" />
                <span class="s-val">{draft[s.key]}{s.unit}</span>
              </label>
            {/each}
          </section>

          <section class="toggles">
            {#each TOGGLES as t}
              <label class="tg">
                <input type="checkbox" bind:checked={draft[t.key]} on:change={change} />
                <span class="switch" aria-hidden="true"></span>
                {t.label}
              </label>
            {/each}
          </section>

          <div class="actions"><button type="button" class="btn btn-secondary" on:click={reset}>Reset to default</button></div>
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: absolute;
    inset: 0;
    z-index: 6200;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.62);
    pointer-events: all;
    font-family: var(--font-ui);
  }
  h1, h2, p { margin: 0; }
  button { font-family: inherit; cursor: pointer; }
  button:focus-visible, input:focus-visible + .switch { outline: 2px solid var(--c-action); outline-offset: 2px; }

  .panel {
    width: 860px;
    max-width: 95vw;
    max-height: 92vh;
    overflow-y: auto;
    padding: 22px 26px 24px;
    color: var(--c-text, #eceef0);
    background-color: #07090d;
    background-image: radial-gradient(ellipse 95% 65% at 50% 12%, rgba(65, 86, 111, 0.42) 0%, rgba(18, 25, 36, 0.76) 52%, rgba(6, 8, 12, 0.96) 100%);
    border: 1px solid var(--tablet-border-strong);
    border-radius: 16px;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.65);
  }

  .head { display: flex; align-items: center; gap: 14px; padding-bottom: 16px; border-bottom: 1px solid var(--c-line); }
  .mark { flex: none; width: 46px; height: 46px; display: grid; place-items: center; border-radius: 11px; color: var(--c-action); background: var(--c-line); border: 1px solid var(--c-line); }
  .heading h1 { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 30px; font-weight: 700; line-height: 1.05; }
  .heading p { margin-top: 4px; font-size: 14.5px; color: var(--c-text-3, #8d949c); }
  .done { margin-left: auto; display: inline-flex; align-items: center; gap: 10px; min-height: 42px; padding: 0 20px; font-size: 15px; }
  kbd { font: 600 12px var(--font-ui); padding: 2px 7px; border-radius: 5px; color: #fff; border: 1px solid rgba(255, 255, 255, 0.5); background: rgba(255, 255, 255, 0.12); }

  .body { display: grid; grid-template-columns: 290px 1fr; gap: 28px; margin-top: 20px; }
  .preview-col { display: flex; flex-direction: column; gap: 12px; }
  .preview {
    position: relative;
    width: 290px;
    height: 290px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    border: 1px solid var(--tablet-border-strong);
    border-radius: 14px;
  }
  /* a busy mid-grey "game" backdrop so low-contrast colours are judged honestly */
  .preview .bg {
    position: absolute;
    inset: 0;
    background:
      linear-gradient(135deg, rgba(120, 130, 120, 0.9), rgba(70, 76, 82, 0.9)),
      repeating-linear-gradient(45deg, rgba(255, 255, 255, 0.06) 0 12px, transparent 12px 24px);
  }
  .preview :global(svg) { position: relative; }
  .note { font-size: 13.5px; line-height: 1.45; color: var(--c-text-3, #8d949c); }
  .preview-col .btn { min-height: 42px; }

  .controls { display: flex; flex-direction: column; gap: 20px; min-width: 0; }
  h2 { margin-bottom: 10px; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 18px; font-weight: 600; }

  .shapes { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
  .shape {
    display: flex; align-items: center; gap: 10px; height: 46px; padding: 0 14px;
    font-size: 15px; font-weight: 600; color: var(--c-text-2, #c9ced4);
    background: var(--c-raised); border: 1px solid var(--c-line); border-radius: 10px;
    transition: border-color 0.15s, background 0.15s, color 0.15s;
  }
  .shape:hover { border-color: var(--tablet-border-strong); color: #fff; }
  .shape.on { color: #fff; border-color: var(--c-action); background: linear-gradient(90deg, var(--c-line), var(--c-raised)); }
  .shape.on svg { color: var(--c-action); }

  .swatches { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .sw {
    width: 32px; height: 32px; border-radius: 50%; background: var(--c);
    border: 2px solid rgba(255, 255, 255, 0.22);
    transition: transform 0.12s, border-color 0.12s;
  }
  .sw:hover { border-color: rgba(255, 255, 255, 0.6); }
  .sw.on { border-color: #fff; box-shadow: 0 0 0 3px var(--c-line); }
  .picker-wrap { display: inline-flex; align-items: center; gap: 8px; height: 34px; padding: 0 10px 0 4px; border-radius: 17px; background: var(--c-raised); border: 1px solid var(--c-line); cursor: pointer; }
  .picker { width: 26px; height: 26px; padding: 0; border: 0; border-radius: 50%; background: none; cursor: pointer; }
  .picker-hex { font-size: 13.5px; color: var(--c-text-2, #c9ced4); font-variant-numeric: tabular-nums; }

  /* sliders: the filled part of the track shows the value */
  .sliders { display: flex; flex-direction: column; gap: 12px; }
  .slider { display: grid; grid-template-columns: 140px 1fr 50px; align-items: center; gap: 14px; }
  .s-name { font-size: 15px; font-weight: 600; }
  .s-val { text-align: right; font-size: 15px; font-weight: 600; color: var(--c-action); font-variant-numeric: tabular-nums; }
  input[type='range'] { -webkit-appearance: none; appearance: none; width: 100%; height: 6px; border-radius: 3px; outline: none; cursor: pointer;
    background: linear-gradient(90deg, var(--c-action) var(--p), rgba(255, 255, 255, 0.12) var(--p)); }
  input[type='range']::-webkit-slider-thumb { -webkit-appearance: none; width: 18px; height: 18px; border-radius: 50%; background: #fff; border: 3px solid var(--c-action); }
  input[type='range']:focus-visible { outline: 2px solid var(--c-action); outline-offset: 4px; }

  .toggles { display: grid; grid-template-columns: 1fr 1fr; gap: 12px 18px; }
  .tg { display: flex; align-items: center; gap: 12px; cursor: pointer; font-size: 15px; font-weight: 600; }
  .tg input { position: absolute; opacity: 0; width: 0; height: 0; }
  .switch { position: relative; flex: none; width: 38px; height: 22px; border-radius: 11px; background: rgba(255, 255, 255, 0.14); transition: background 0.15s; }
  .switch::after { content: ''; position: absolute; top: 3px; left: 3px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform 0.15s; }
  .tg input:checked + .switch { background: var(--c-action); }
  .tg input:checked + .switch::after { transform: translateX(16px); }

  .actions { display: flex; justify-content: flex-end; padding-top: 4px; }
  .actions .btn { min-height: 40px; }

  @media (prefers-reduced-motion: reduce) { .switch, .switch::after, .shape, .sw { transition: none; } }

  /* ── flat, theme-driven (Black + White / Black + Blue / Black + Gold) ── */
  .panel { background: var(--c-panel); background-image: none; border: 1px solid var(--tablet-border-strong); border-radius: var(--r-panel); box-shadow: none; }
  .head { border-bottom-color: var(--c-line); }
  .mark { border-radius: var(--r-ctl); color: var(--on-accent); background: var(--c-action); border-color: transparent; }
  kbd { border-radius: 4px; color: inherit; border-color: currentColor; background: transparent; }
  .preview { border-radius: var(--r-ctl); }
  .preview .bg { background: #6b7280; }
  .shape { border-radius: var(--r-ctl); background: var(--c-raised); }
  .shape:hover { border-color: var(--tablet-border-hover); }
  .shape.on { color: var(--on-accent); background: var(--c-action); border-color: var(--c-action); }
  .shape.on svg { color: inherit; }
  .sw { border-radius: var(--r-ctl); }
  .sw.on { box-shadow: none; outline: 2px solid var(--c-action); outline-offset: 2px; border-color: #fff; }
  .picker-wrap { border-radius: var(--r-ctl); background: var(--c-raised); }
  .picker { border-radius: 4px; }
  .s-val { color: var(--text-main); }
  input[type='range'] { border-radius: 2px; background: linear-gradient(90deg, var(--c-action) var(--p), var(--c-line) var(--p)); }
  input[type='range']::-webkit-slider-thumb { border-radius: 2px; background: var(--text-main); border: 3px solid var(--c-action); }
  .switch { border-radius: 4px; background: var(--c-raised); border: 1px solid var(--tablet-border-strong); }
  .switch::after { border-radius: 2px; background: var(--text-dim); }
  .tg input:checked + .switch { background: var(--c-action); border-color: var(--c-action); }
  .tg input:checked + .switch::after { background: var(--on-accent); }

</style>
