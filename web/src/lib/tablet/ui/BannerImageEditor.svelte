<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from './Icon.svelte';
  import { THEMES } from '../../hud/eventThemes.js';
  import AnnouncementCard from '../../hud/AnnouncementCard.svelte';
  import '../tablet-theme.css';

  export let title = 'Edit Banner Image';
  export let eventKey = 'convoy';
  export let eventName = 'Convoy';
  export let bannerColor = '';
  export let initialImageUrl = '';
  export let defaultImageUrl = '';
  export let initialPosX = 50;
  export let initialPosY = 50;
  export let initialZoom = 1.0;
  export let initialFit = 'cover';
  export let saving = false;

  const dispatch = createEventDispatcher();

  let imageUrl = initialImageUrl || defaultImageUrl || '';
  let inputUrl = initialImageUrl || defaultImageUrl || '';
  let posX = Math.round(initialPosX != null ? initialPosX : 50);
  let posY = Math.round(initialPosY != null ? initialPosY : 50);
  let zoom = +(initialZoom != null ? initialZoom : 1.0).toFixed(2);
  let fit = initialFit || 'cover';

  let imageLoading = false;
  let imageError = '';
  let isDragging = false;
  let dragStartX = 0;
  let dragStartY = 0;
  let startPosX = 50;
  let startPosY = 50;

  $: theme = THEMES[eventKey] || THEMES.server;
  $: activeAccent = bannerColor || theme.accent || '#368fe9';

  function loadImage() {
    imageError = '';
    const trimmed = inputUrl.trim();
    if (!trimmed) {
      imageUrl = '';
      return;
    }
    imageLoading = true;
    const img = new Image();
    img.onload = () => {
      imageLoading = false;
      imageUrl = trimmed;
      imageError = '';
    };
    img.onerror = () => {
      imageLoading = false;
      // In CEF / NUI, JS Image() preloads can trigger CORS for some CDNs while CSS backgrounds display fine.
      imageUrl = trimmed;
      imageError = '';
    };
    img.src = trimmed;
  }

  function useDefaultImage() {
    if (defaultImageUrl) {
      inputUrl = defaultImageUrl;
      imageUrl = defaultImageUrl;
      imageError = '';
    }
  }

  function removeImage() {
    inputUrl = '';
    imageUrl = '';
    imageError = '';
  }

  function resetComposition() {
    posX = 50;
    posY = 50;
    zoom = 1.0;
    fit = 'cover';
    if (!imageUrl && defaultImageUrl) {
      imageUrl = defaultImageUrl;
      inputUrl = defaultImageUrl;
    }
  }

  function handleSave() {
    dispatch('save', {
      imageUrl: imageUrl.trim() || null,
      posX: Math.max(0, Math.min(100, Math.round(posX))),
      posY: Math.max(0, Math.min(100, Math.round(posY))),
      zoom: Math.max(0.5, Math.min(3.0, +zoom.toFixed(2))),
      fit: fit || 'cover',
    });
  }

  function handleCancel() {
    dispatch('cancel');
  }

  // Interactive mouse dragging & panning
  function onMouseDown(e) {
    if (e.button !== 0 || !imageUrl) return;
    isDragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    startPosX = posX;
    startPosY = posY;

    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
  }

  function onMouseMove(e) {
    if (!isDragging) return;
    const dx = e.clientX - dragStartX;
    const dy = e.clientY - dragStartY;
    const sensitivity = 0.35 / Math.max(0.5, zoom);
    posX = Math.max(0, Math.min(100, Math.round(startPosX - dx * sensitivity)));
    posY = Math.max(0, Math.min(100, Math.round(startPosY - dy * sensitivity)));
  }

  function onMouseUp() {
    isDragging = false;
    window.removeEventListener('mousemove', onMouseMove);
    window.removeEventListener('mouseup', onMouseUp);
  }

  function onWheel(e) {
    if (!imageUrl) return;
    e.preventDefault();
    const delta = e.deltaY < 0 ? 0.05 : -0.05;
    zoom = Math.max(0.5, Math.min(3.0, +(zoom + delta).toFixed(2)));
  }
</script>

<div class="overlay" on:click|self={handleCancel}>
  <div class="banner-editor-dialog">
    <!-- HEADER -->
    <div class="editor-header">
      <div class="header-title-row">
        <div class="editor-badge" style="background: {activeAccent}22; border-color: {activeAccent}66; color: {activeAccent};">
          <Icon name="image" size={14} />
        </div>
        <div>
          <h3 class="editor-title">{title}</h3>
          <span class="editor-subtitle">Adjust banner framing, zoom, and focus for in-game announcements.</span>
        </div>
      </div>
      <button type="button" class="btn-close" on:click={handleCancel} title="Close" aria-label="Close">
        <Icon name="close" size={14} />
      </button>
    </div>

    <div class="editor-body">
      <!-- 1. LIVE BANNER COMPOSITION -->
      <section class="sec">
        <div class="sec-head">
          <span class="sec-title">Live Banner Composition</span>
          {#if imageUrl}
            <span class="hint-active"><Icon name="check" size={11} /> Draggable Viewport Active</span>
          {:else}
            <span class="hint-empty">No image configured</span>
          {/if}
        </div>

        <!-- the REAL in-game banner card; the dashed zone over its image side catches drag (pan) and wheel (zoom) -->
        <div class="interactive-banner-frame" class:is-dragging={isDragging}>
          <AnnouncementCard
            preview
            {eventKey}
            subtitle="{(theme.label || 'EVENT')} // ANNOUNCEMENT BANNER"
            title={eventName || 'Upcoming Event'}
            message="Banner position X: {posX}%, Y: {posY}%, scale {zoom}x"
            status="PREVIEW"
            bannerImg={imageUrl || null}
            bannerPos="{posX}% {posY}%"
            bannerFit={fit}
            bannerZoom={zoom}
            bannerColor={bannerColor || null}
          />
          {#if imageUrl}
            <div
              class="drag-zone"
              class:is-dragging={isDragging}
              on:mousedown={onMouseDown}
              on:wheel|preventDefault={onWheel}
              role="application"
              aria-label="Image viewport: click and drag to pan, scroll to zoom"
            >
              <div class="drag-badge" class:dragging={isDragging}>
                <Icon name="expand" size={10} />
                <span>{isDragging ? 'Panning…' : 'Drag to Pan • Scroll to Zoom'}</span>
              </div>
            </div>
          {/if}
        </div>
      </section>

      <!-- 2. IMAGE SOURCE -->
      <section class="sec">
        <div class="sec-head">
          <span class="sec-title">Image Source</span>
          <div class="sec-actions">
            {#if defaultImageUrl && imageUrl !== defaultImageUrl}
              <button type="button" class="link-btn" on:click={useDefaultImage} title="Reset to default artwork">
                <Icon name="refresh" size={11} /> Use default
              </button>
            {/if}
            {#if imageUrl}
              <button type="button" class="link-btn danger" on:click={removeImage} title="Remove image">
                <Icon name="trash" size={11} /> Remove
              </button>
            {/if}
          </div>
        </div>
        <div class="url-row">
          <input
            type="text"
            class="url-input"
            placeholder="Paste direct image URL (PNG, JPG, WebP) or resource banner path…"
            bind:value={inputUrl}
            on:keydown={(e) => { if (e.key === 'Enter') loadImage(); }}
          />
          <button type="button" class="btn btn-primary load-btn" on:click={loadImage} disabled={imageLoading}>
            {imageLoading ? 'Loading…' : 'Load'}
          </button>
        </div>
        {#if imageError}
          <div class="alert-error"><Icon name="alertCircle" size={13} /><span>{imageError}</span></div>
        {/if}
      </section>

      <!-- 3. FRAMING & COMPOSITION -->
      <section class="sec">
        <div class="sec-head">
          <span class="sec-title">Framing &amp; Composition</span>
          <div class="fit-mode-toggle">
            <button type="button" class="fit-btn" class:active={fit === 'cover'} on:click={() => (fit = 'cover')} title="Cover: fills photo zone">Cover</button>
            <button type="button" class="fit-btn" class:active={fit === 'contain'} on:click={() => (fit = 'contain')} title="Contain: shows entire image">Contain</button>
          </div>
        </div>

        <div class="controls-grid">
          <!-- Zoom / Scale -->
          <div class="ctl">
            <div class="ctl-meta">
              <div class="ctl-name"><span class="ctl-lbl">Zoom / Scale</span><span class="ctl-sub">Size</span></div>
              <span class="ctl-val">{zoom}x</span>
            </div>
            <input type="range" min="0.5" max="3.0" step="0.05" bind:value={zoom} class="custom-slider" />
            <div class="presets-row">
              <button type="button" class="chip-preset" class:active={zoom === 1.0} on:click={() => (zoom = 1.0)}>1x</button>
              <button type="button" class="chip-preset" class:active={zoom === 1.25} on:click={() => (zoom = 1.25)}>1.25x</button>
              <button type="button" class="chip-preset" class:active={zoom === 1.5} on:click={() => (zoom = 1.5)}>1.5x</button>
              <button type="button" class="chip-preset" class:active={zoom === 2.0} on:click={() => (zoom = 2.0)}>2x</button>
            </div>
          </div>

          <!-- Position X -->
          <div class="ctl">
            <div class="ctl-meta">
              <div class="ctl-name"><span class="ctl-lbl">Position X</span><span class="ctl-sub">Horizontal</span></div>
              <span class="ctl-val">{posX}%</span>
            </div>
            <input type="range" min="0" max="100" step="1" bind:value={posX} class="custom-slider" />
            <div class="presets-row">
              <button type="button" class="chip-preset" class:active={posX === 0} on:click={() => (posX = 0)}>Left</button>
              <button type="button" class="chip-preset" class:active={posX === 50} on:click={() => (posX = 50)}>Center</button>
              <button type="button" class="chip-preset" class:active={posX === 100} on:click={() => (posX = 100)}>Right</button>
            </div>
          </div>

          <!-- Position Y -->
          <div class="ctl">
            <div class="ctl-meta">
              <div class="ctl-name"><span class="ctl-lbl">Position Y</span><span class="ctl-sub">Vertical</span></div>
              <span class="ctl-val">{posY}%</span>
            </div>
            <input type="range" min="0" max="100" step="1" bind:value={posY} class="custom-slider" />
            <div class="presets-row">
              <button type="button" class="chip-preset" class:active={posY === 0} on:click={() => (posY = 0)}>Top</button>
              <button type="button" class="chip-preset" class:active={posY === 50} on:click={() => (posY = 50)}>Center</button>
              <button type="button" class="chip-preset" class:active={posY === 100} on:click={() => (posY = 100)}>Bottom</button>
            </div>
          </div>
        </div>
      </section>
    </div>

    <!-- FOOTER ACTIONS -->
    <div class="editor-footer">
      <button type="button" class="btn btn-secondary btn-reset" on:click={resetComposition}>
        <Icon name="refresh" size={13} /> Reset Composition
      </button>
      <div class="footer-primary-group">
        <button type="button" class="btn btn-secondary" on:click={handleCancel} disabled={saving}>Cancel</button>
        <button type="button" class="btn btn-primary btn-save" on:click={handleSave} disabled={saving}>
          <Icon name="check" size={14} /> {saving ? 'Saving...' : 'Save Changes'}
        </button>
      </div>
    </div>
  </div>
</div>

<style>
  /* full-screen popup layer */
  .overlay {
    position: fixed;
    inset: 0;
    z-index: 10000;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px;
    background: rgba(0, 0, 0, 0.74);
  }
  .banner-editor-dialog {
    width: 700px;
    max-width: 96vw;
    max-height: 94vh;
    background: var(--surface-dialog);
    border: 1px solid var(--border-dialog);
    border-radius: var(--r-panel);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    box-shadow: none;
    animation: hxEnter 0.2s cubic-bezier(0.16, 1, 0.3, 1) both;
  }

  /* header: compact */
  .editor-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 11px 16px;
    background: var(--lt-15171b, #15171b);
    border-bottom: 1px solid var(--lt-2a2e35, #2a2e35);
  }
  .header-title-row { display: flex; align-items: center; gap: 11px; min-width: 0; }
  .editor-badge {
    width: 30px;
    height: 30px;
    border-radius: var(--r-tag);
    border: 1px solid;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .editor-title { margin: 0; font-size: var(--fs-body); font-weight: 700; color: var(--lt-ffffff, #fff); letter-spacing: 0.01em; }
  .editor-subtitle { display: block; margin-top: 1px; font-size: var(--fs-meta); color: var(--text-dim, #aeb5bd); }
  .btn-close {
    background: transparent;
    border: none;
    color: var(--text-dim, #aeb5bd);
    cursor: pointer;
    padding: 6px;
    border-radius: var(--r-ctl);
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .btn-close:hover { color: var(--lt-ffffff, #fff); background: rgba(var(--ink-rgb, 255, 255, 255), 0.08); }

  /* body: sections stay close together */
  .editor-body {
    padding: 12px 16px 6px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .sec { display: flex; flex-direction: column; gap: 7px; }
  .sec + .sec { padding-top: 11px; border-top: 1px solid var(--lt-1f2328, #1f2328); }
  .sec-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; min-height: 22px; }
  .sec-title { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-e3e6e9, #e3e6e9); }
  .sec-actions { display: flex; align-items: center; gap: 12px; }
  .hint-active { display: inline-flex; align-items: center; gap: 4px; font-size: var(--fs-meta); font-weight: 600; color: var(--lt-46c98b, #46c98b); }
  .hint-empty { font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .link-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 0;
    background: none;
    border: none;
    color: var(--accent-primary-light);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
  }
  .link-btn:hover { text-decoration: underline; }
  .link-btn.danger { color: var(--lt-ff7f84, #ff7f84); }

  /* the banner: centred at its real size, drag layer over its image side */
  .interactive-banner-frame {
    position: relative;
    display: flex;
    justify-content: center;
    user-select: none;
  }
  .drag-zone {
    position: absolute;
    top: 0;
    bottom: 0;
    right: calc(50% - min(325px, 46vw));
    width: calc(min(650px, 92vw) * 0.44);
    z-index: 6;
    cursor: grab;
    border: 1px dashed rgba(var(--ink-rgb, 255, 255, 255), 0.42);
    border-radius: var(--r-ctl);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.02);
  }
  .drag-zone:hover { border-color: var(--accent-primary-light); background: rgba(91, 164, 238, 0.06); }
  .drag-zone.is-dragging { cursor: grabbing; border-color: var(--accent-primary-light); }
  /* top-right corner: the one spot of the card with no text, so the hint never covers the announcement */
  .drag-badge {
    position: absolute;
    top: 7px;
    right: 7px;
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 2px 7px;
    background: rgba(0, 0, 0, 0.84);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.2);
    border-radius: var(--r-tag);
    color: var(--lt-e3e6e9, #e3e6e9);
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    pointer-events: none;
  }
  .drag-badge.dragging { border-color: var(--accent-primary); color: var(--accent-primary-light); }

  /* image source: one compact row */
  .url-row { display: flex; align-items: center; gap: 8px; }
  .url-input {
    flex: 1;
    min-width: 0;
    height: 38px;
    padding: 0 12px;
    background: var(--lt-1c1f24, #1c1f24);
    border: 1px solid #3d4260;
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-small);
    outline: none;
  }
  .url-input::placeholder { color: #7c848d; }
  .url-input:focus { border-color: var(--accent-primary); }
  .load-btn { height: 38px; min-height: 38px; min-width: 76px; padding: 0 16px; font-size: var(--fs-small); font-weight: 700; }
  .alert-error {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    border-radius: var(--r-ctl);
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    color: var(--tablet-danger, #ff5d50);
    font-size: var(--fs-meta);
    border-left: 3px solid rgb(255, 93, 80);}

  /* framing */
  .fit-mode-toggle { display: inline-flex; gap: 3px; }
  .fit-btn {
    padding: 3px 12px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-dim, #aeb5bd);
    font-size: var(--fs-meta);
    font-weight: 600;
    cursor: pointer;
  }
  .fit-btn:hover { color: var(--lt-ffffff, #fff); border-color: #3a4048; }
  .fit-btn.active { background: var(--accent-primary); border-color: var(--accent-primary); color: var(--on-accent, #ffffff);
    text-shadow: none; font-weight: 700; }

  .controls-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
  .ctl {
    display: flex;
    flex-direction: column;
    gap: 7px;
    padding: 9px 11px 10px;
    background: var(--lt-131518, #131518);
    border: 1px solid var(--lt-22262c, #22262c);
    border-radius: var(--r-ctl);
    min-width: 0;
  }
  .ctl-meta { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; }
  .ctl-name { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
  .ctl-lbl { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--lt-e3e6e9, #e3e6e9); white-space: nowrap; }
  .ctl-sub { font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0.01em; color: var(--text-muted, #7c848d); }
  .ctl-val { flex: none; font-size: var(--fs-meta); font-weight: 700; font-family: var(--font-mono); color: var(--accent-primary-light); line-height: 1.2; }

  .custom-slider {
    -webkit-appearance: none;
    appearance: none;
    width: 100%;
    height: 6px;
    border-radius: 3px;
    background: var(--lt-1f2328, #1f2328);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    outline: none;
    cursor: pointer;
  }
  .custom-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: var(--accent-primary-light);
    border: 2px solid #fff;
    cursor: pointer;
    color: var(--on-accent, inherit);
}
  .custom-slider::-webkit-slider-thumb:hover { transform: scale(1.15); }

  .presets-row { display: flex; gap: 4px; }
  .chip-preset {
    flex: 1;
    min-width: 0;
    padding: 3px 0;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-tag);
    color: var(--text-dim, #aeb5bd);
    font-size: var(--fs-meta);
    font-weight: 600;
    text-align: center;
    cursor: pointer;
  }
  .chip-preset:hover { color: var(--lt-ffffff, #fff); border-color: #3a4048; }
  .chip-preset.active { background: var(--lt-272b31, #272b31); border-color: var(--accent-primary-light); color: var(--accent-primary-light); font-weight: 600; }

  /* footer */
  .editor-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 16px;
    background: var(--lt-15171b, #15171b);
    border-top: 1px solid var(--lt-2a2e35, #2a2e35);
  }
  .btn-reset { gap: 6px !important; }
  .footer-primary-group { display: flex; align-items: center; gap: 8px; }
  .btn-save { gap: 6px !important; font-weight: 700 !important; }
</style>
