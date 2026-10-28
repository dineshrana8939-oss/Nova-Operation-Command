<script>
  // The shared Prop Placer window. Layout: top bar (tools, snapping, save), the game world in the middle
  // (this window only captures the mouse over it), the transform inspector on the right and the asset
  // library with the batch panel at the bottom. The client script (prop_placer.lua) owns the layout; this
  // component draws what it is sent and sends commands back.
  import { onDestroy } from 'svelte';
  import { fade } from 'svelte/transition';
  import { placer } from './placerStore.js';
  import { placerCmd, placerPointer, placerFly, placerLook } from '../api/placer.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import '../tablet/tablet-theme.css';

  $: open = $placer.open;
  $: session = $placer.session;
  $: st = $placer.state;
  $: objects = st?.objects || [];
  $: selected = new Set(st?.selected || []);
  $: active = objects.find((o) => o.id === st?.active) || null;
  $: tool = st?.tool || 'select';
  $: armed = st?.armed || null;
  $: flags = st?.flags || {};
  $: compact = !!session?.compact;
  $: maxStack = session?.limits?.maxStack || 6;
  $: maxObjects = session?.limits?.maxObjects || 150;
  $: features = session?.features || {};
  $: selObjects = objects.filter((o) => selected.has(o.id));
  $: selCount = selObjects.length;
  $: stackableSel = selObjects.filter((o) => o.stackable);

  // ── names: "Barrier 1, Barrier 2 …" per model ───────────────────────────────
  $: assetByModel = Object.fromEntries((session?.assets || []).map((a) => [a.model.toLowerCase(), a]));
  const labelOf = (model) => assetByModel[(model || '').toLowerCase()]?.label || model;
  $: names = (() => {
    const counts = {};
    const out = {};
    for (const o of objects) {
      const k = o.model.toLowerCase();
      counts[k] = (counts[k] || 0) + 1;
      const label = labelOf(o.model);
      out[o.id] = /d$/.test(label) ? `${label} #${counts[k]}` : `${label} ${counts[k]}`;
    }
    return out;
  })();

  // ── asset library ───────────────────────────────────────────────────────────
  let savedCategory = 'all';
  try { savedCategory = localStorage.getItem('nova_pp_category') || 'all'; } catch (e) {}
  let category = savedCategory;
  let query = '';
  let lastSession = null;
  let chipsEl;
  let isDraggingChips = false;
  let chipsStartX = 0;
  let chipsStartScrollLeft = 0;
  let hasDraggedChips = false;

  $: if (session && session !== lastSession) {
    lastSession = session;
    if (session.startCategory && (session.categories || []).some((c) => c.id === session.startCategory)) {
      category = session.startCategory;
    } else {
      let remembered = 'all';
      try { remembered = localStorage.getItem('nova_pp_category') || 'all'; } catch (e) {}
      category = (remembered === 'all' || (session.categories || []).some((c) => c.id === remembered)) ? remembered : 'all';
    }
    query = '';
    tab = 'object';
    setTimeout(() => {
      if (chipsEl) {
        const activeChip = chipsEl.querySelector('.chip.on');
        if (activeChip) activeChip.scrollIntoView({ behavior: 'smooth', inline: 'nearest', block: 'nearest' });
      }
    }, 120);
  }

  function selectCategory(catId, btnEl) {
    category = catId;
    try { localStorage.setItem('nova_pp_category', catId); } catch (e) {}
    if (btnEl && typeof btnEl.scrollIntoView === 'function') {
      btnEl.scrollIntoView({ behavior: 'smooth', inline: 'nearest', block: 'nearest' });
    }
  }

  function onChipsMouseDown(e) {
    if (e.button !== 0 || !chipsEl) return;
    isDraggingChips = true;
    hasDraggedChips = false;
    chipsStartX = e.clientX;
    chipsStartScrollLeft = chipsEl.scrollLeft;
  }

  function onChipsMouseMove(e) {
    if (!isDraggingChips || !chipsEl) return;
    const dx = e.clientX - chipsStartX;
    if (Math.abs(dx) > 4) {
      hasDraggedChips = true;
    }
    chipsEl.scrollLeft = chipsStartScrollLeft - dx;
  }

  function onChipsMouseUp() {
    isDraggingChips = false;
  }

  function onChipsWheel(e) {
    if (!chipsEl) return;
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
      chipsEl.scrollLeft += e.deltaY;
      e.preventDefault();
    }
  }

  function scrollChips(dir) {
    if (!chipsEl) return;
    chipsEl.scrollBy({ left: dir * 220, behavior: 'smooth' });
  }

  function handleChipClick(catId, e) {
    if (hasDraggedChips) {
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    selectCategory(catId, e.currentTarget);
  }
  $: filtered = (session?.assets || []).filter((a) => {
    if (category !== 'all' && a.category !== category) return false;
    if (!query) return true;
    const q = query.toLowerCase();
    return a.model.toLowerCase().includes(q) || (a.label || '').toLowerCase().includes(q);
  });
  let pageLimit = 80;
  $: if (category !== undefined || query !== undefined) {
    pageLimit = 80;
  }
  $: visibleFiltered = filtered.slice(0, pageLimit);

  function onAssetBodyScroll(e) {
    const el = e.target;
    if (el && el.scrollTop + el.clientHeight >= el.scrollHeight - 160) {
      if (pageLimit < filtered.length) {
        pageLimit = Math.min(filtered.length, pageLimit + 80);
      }
    }
  }

  // how many assets each type has (for the picklist)
  $: typeCounts = (() => {
    const n = {};
    for (const a of session?.assets || []) n[a.category] = (n[a.category] || 0) + 1;
    return n;
  })();
  $: totalAssets = (session?.assets || []).length;
  $: customCandidate = query && /^[a-z0-9_:-]{3,}$/i.test(query) && !(session?.assets || []).some((a) => a.model.toLowerCase() === query.toLowerCase()) ? query : '';
  const ICONS = { barricades: 'shield', containers: 'box', construction: 'tool', electrical: 'zap', equipment: 'tool', garage: 'gear', industrial: 'gear', interior: 'grid', road: 'route', military: 'shield', event: 'flag', vehicles: 'truck', convoy: 'truck', misc: 'dot' };
  const iconFor = (a) => (a.vehicle ? 'truck' : ICONS[a.category] || 'box');

  // ── commands ────────────────────────────────────────────────────────────────
  const cmd = (t, data) => placerCmd(t, data);
  const setTool = (t) => cmd('setTool', { tool: t });
  const setFlag = (key, value) => cmd('setFlag', { key, value });
  function armAsset(a) {
    if (armed && armed.model === a.model) cmd('disarm');
    else cmd('arm', { model: a.model });
  }
  function selectRow(o, e) {
    cmd('select', { ids: [o.id], mode: e.shiftKey ? 'toggle' : 'set' });
    cmd('focus', { id: o.id });
  }
  const setField = (k, v) => {
    if (!active) return;
    const n = Number(v);
    if (!Number.isFinite(n)) return;
    cmd('update', { id: active.id, patch: { [k]: n } });
  };
  function blurOnEnter(e) {
    if (e.key === 'Enter') e.target.blur();
  }
  const fmt = (v) => (v === undefined || v === null ? '' : String(Math.round(Number(v) * 1000) / 1000));

  // copy / paste of a position or rotation (kept in this window)
  let clip = { pos: null, rot: null };
  function copyPos() { if (active) { clip.pos = { x: active.x, y: active.y, z: active.z }; flash('Position copied'); } }
  function pastePos() { if (active && clip.pos) { cmd('update', { id: active.id, patch: clip.pos }); flash('Position pasted'); } }
  function copyRot() { if (active) { clip.rot = { rx: active.rx, ry: active.ry, rz: active.rz }; flash('Rotation copied'); } }
  function pasteRot() { if (active && clip.rot) { cmd('update', { id: active.id, patch: clip.rot }); flash('Rotation pasted'); } }
  function resetRot() { if (active) { cmd('update', { id: active.id, patch: { rx: 0, ry: 0, rz: 0 } }); } }

  // ── layout: inspector tabs + a collapsible library ──────────────────────────
  // Object = the selected object, Batch = actions on the selection / the "Placing" card, Layout = options + object list.
  let tab = 'object';
  let wasArmed = false;
  $: { const now = !!armed; if (now && !wasArmed && !compact) tab = 'batch'; wasArmed = now; }   // picking an asset opens its Placing card
  let libOpen = true;
  try { libOpen = localStorage.getItem('nova_pp_lib_open') !== '0'; } catch (e) { /* storage blocked: stays open */ }
  function toggleLib() {
    libOpen = !libOpen;
    try { localStorage.setItem('nova_pp_lib_open', libOpen ? '1' : '0'); } catch (e) { /* ignore */ }
  }

  let dupCount = 1;
  let batchMove = { dx: 0, dy: 0, dz: 0 };
  let confirmClear = false;
  let confirmClearTimer;
  function clearAll() {
    if (!confirmClear) {
      confirmClear = true;
      clearTimeout(confirmClearTimer);
      confirmClearTimer = setTimeout(() => (confirmClear = false), 3500);
      return;
    }
    confirmClear = false;
    cmd('clear');
  }
  function applyBatchMove() {
    cmd('batch', { dx: Number(batchMove.dx) || 0, dy: Number(batchMove.dy) || 0, dz: Number(batchMove.dz) || 0 });
    batchMove = { dx: 0, dy: 0, dz: 0 };
  }
  function addSameModel() {
    if (!active) return;
    cmd('select', { ids: objects.filter((o) => o.model === active.model).map((o) => o.id), mode: 'set' });
  }

  async function copyVectors() {
    const list = selCount ? selObjects : objects;
    const text = list.map((o) => `vector4(${fmt(o.x)}, ${fmt(o.y)}, ${fmt(o.z)}, ${fmt(o.rz)})`).join('\n');
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch (e) { /* fall through */ }
    if (!ok) {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      ta.remove();
    }
    flash(ok ? `${list.length} vector${list.length === 1 ? '' : 's'} copied` : 'Could not copy');
  }

  // ── toast ───────────────────────────────────────────────────────────────────
  let toast = null;
  let toastTimer;
  function flash(text, kind = 'info') {
    toast = { text, kind };
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast = null), 2400);
  }
  $: if ($placer.notice) flash($placer.notice.text, $placer.notice.kind);

  // ── leaving ─────────────────────────────────────────────────────────────────
  let askLeave = false;
  function requestClose() {
    if (st?.dirty) askLeave = true;
    else cmd('cancel');
  }
  const saveAndClose = () => { askLeave = false; cmd('save'); };
  const discardAndClose = () => { askLeave = false; cmd('cancel'); };

  // ── mouse over the world ────────────────────────────────────────────────────
  let looking = false;
  let rmbMoved = false;
  let worldDown = false;   // a left press that started over the world (a press on a panel is not the world's)
  let moveEvent = null;
  let raf = 0;

  const base = (e, ev, extra = {}) => ({
    ev,
    nx: (e.clientX / window.innerWidth) * 2 - 1,
    ny: 1 - (e.clientY / window.innerHeight) * 2,
    px: e.clientX,
    py: e.clientY,
    ctrl: e.ctrlKey || e.metaKey,
    aspect: window.innerWidth / window.innerHeight,
    inside: true,
    shift: e.shiftKey,
    alt: e.altKey,
    ...extra,
  });

  function sendMove() {
    raf = 0;
    if (moveEvent) { placerPointer(base(moveEvent, 'move')); moveEvent = null; }
  }
  function onWorldDown(e) {
    if (e.button === 2) {
      looking = true;
      rmbMoved = false;
      e.preventDefault();
      return;
    }
    if (e.button === 0) {
      worldDown = true;
      placerPointer(base(e, 'down', { btn: 0 }));
    }
  }
  function onWindowMove(e) {
    if (!open) return;
    if (looking) {
      const dx = e.movementX || 0;
      const dy = e.movementY || 0;
      if (dx || dy) { rmbMoved = true; placerLook({ dx, dy }); }
      return;
    }
    if (e.target && e.target.classList && e.target.classList.contains('capture')) {
      moveEvent = e;
      if (!raf) raf = requestAnimationFrame(sendMove);
    }
  }
  function onWindowUp(e) {
    if (!open) return;
    if (e.button === 2 && looking) {
      looking = false;
      keys = {};
      sendFly();
      if (!rmbMoved && armed) cmd('disarm');
      return;
    }
    if (e.button === 0 && worldDown) {
      worldDown = false;
      placerPointer(base(e, 'up', { btn: 0 }));
    }
  }
  function onWheel(e) {
    e.preventDefault();
    placerPointer(base(e, 'wheel', { dy: e.deltaY }));
  }
  const leaveWorld = () => placerPointer({ ev: 'leave', nx: 0, ny: 0, inside: false });

  // ── keyboard ────────────────────────────────────────────────────────────────
  let keys = {};
  let lastFly = '';
  function sendFly() {
    const f = (keys.w ? 1 : 0) - (keys.s ? 1 : 0);
    const r = (keys.d ? 1 : 0) - (keys.a ? 1 : 0);
    const u = (keys.e ? 1 : 0) - (keys.q ? 1 : 0);
    const fast = !!keys.shift;
    const sig = `${f}|${r}|${u}|${fast}`;
    if (sig === lastFly) return;
    lastFly = sig;
    placerFly({ f, r, u, fast });
  }
  const typing = (e) => {
    const t = e.target;
    return t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA');
  };
  function onKeyDown(e) {
    if (!open) return;
    const k = e.key.toLowerCase();
    if (k === 'escape') e.preventDefault();
    if (looking) {
      if (['w', 'a', 's', 'd', 'q', 'e'].includes(k) || k === 'shift') {
        keys[k === 'shift' ? 'shift' : k] = true;
        sendFly();
        e.preventDefault();
      }
      return;
    }
    if (typing(e)) {
      if (k === 'escape') e.target.blur();
      return;
    }
    const ctrl = e.ctrlKey || e.metaKey;
    if (ctrl && k === 'a') { cmd('selectAll'); e.preventDefault(); return; }
    if (ctrl && k === 'z') { cmd(e.shiftKey ? 'redo' : 'undo'); e.preventDefault(); return; }
    if (ctrl && k === 'y') { cmd('redo'); e.preventDefault(); return; }
    if (ctrl && k === 'd') { cmd('duplicate', { count: 1 }); e.preventDefault(); return; }
    if (k === 'escape') {
      if (askLeave) askLeave = false;
      else if (armed) cmd('disarm');
      else if (selCount) cmd('clearSelection');
      else requestClose();
      return;
    }
    if (k === 'v') setTool('select');
    else if (k === 'w') setTool('move');
    else if (k === 'r') setTool('rotate');
    else if (k === 'g') cmd('ground');
    else if (k === 'f') cmd('lock');
    else if (k === 'd') cmd('duplicate', { count: 1 });
    else if (k === 'delete' || k === 'backspace') { if (selCount) cmd('delete', { ids: [...selected] }); e.preventDefault(); }
    else if (k === '[' || k === ']') {
      const step = (session?.rotateStep || 5) * (e.shiftKey ? 0.2 : 1) * (k === '[' ? 1 : -1);
      if (armed) cmd('armRotate', { delta: step });
      else if (selCount) cmd('batch', { drz: step });
    } else if (/^[1-9]$/.test(k)) {
      const n = Math.min(Number(k), maxStack);
      if (armed && armed.stackable) cmd('armStack', { n });
      else if (stackableSel.length) cmd('batch', { stack: n });
    } else {
      const dirs = { arrowleft: 'left', arrowright: 'right', arrowup: 'forward', arrowdown: 'back', pageup: 'up', pagedown: 'down' };
      const dir = tool === 'rotate' ? ({ arrowleft: 'yawL', arrowright: 'yawR' })[k] || dirs[k] : dirs[k];
      if (dir) {
        cmd('nudge', { dir, big: ctrl, fine: e.shiftKey });
        e.preventDefault();
      }
    }
  }
  function onKeyUp(e) {
    if (!open) return;
    const k = e.key.toLowerCase();
    if (k === 'shift') keys.shift = false;
    else if (keys[k]) keys[k] = false;
    else return;
    sendFly();
  }
  function onBlur() {
    looking = false;
    keys = {};
    sendFly();
  }

  onDestroy(() => {
    clearTimeout(toastTimer);
    clearTimeout(confirmClearTimer);
    if (raf) cancelAnimationFrame(raf);
  });
</script>

<svelte:window on:mousemove={onWindowMove} on:mouseup={onWindowUp} on:keydown={onKeyDown} on:keyup={onKeyUp} on:blur={onBlur} />

{#if open && session && st}
  <div class="pp" class:compact class:looking class:lib-closed={!libOpen}>
    <!-- the game world: transparent, only here to catch the mouse -->
    <div class="capture" role="presentation" on:mousedown={onWorldDown} on:wheel={onWheel} on:contextmenu|preventDefault on:mouseleave={leaveWorld}></div>

    <!-- ─── top bar ─── -->
    <header class="top" role="presentation" on:mouseenter={leaveWorld}>
      <div class="brand">
        <span class="brand-mark"><Icon name="box" size={16} /></span>
        <div class="brand-text">
          <b>Prop Placer</b>
          <small>{session.title}</small>
        </div>
      </div>

      <div class="seg" role="group" aria-label="Tool">
        <button type="button" class:on={tool === 'select'} on:click={() => setTool('select')} title="Select (V)"><Icon name="crosshair" size={14} /><span>Select</span></button>
        <button type="button" class:on={tool === 'move'} on:click={() => setTool('move')} title="Move — drag an object (W)"><Icon name="move" size={14} /><span>Move</span></button>
        <button type="button" class:on={tool === 'rotate'} on:click={() => setTool('rotate')} title="Rotate — drag an object (R)"><Icon name="refresh" size={14} /><span>Rotate</span></button>
      </div>

      <label class="switch-row">
        <span>Snap to ground</span>
        <button type="button" class="switch" class:on={flags.snapGround} role="switch" aria-checked={flags.snapGround} aria-label="Snap to ground" on:click={() => setFlag('snapGround', !flags.snapGround)}><i></i></button>
      </label>
      <label class="switch-row">
        <span>Grid</span>
        <button type="button" class="switch" class:on={flags.grid} role="switch" aria-checked={flags.grid} aria-label="Grid" on:click={() => setFlag('grid', !flags.grid)}><i></i></button>
      </label>
      {#if flags.grid}
        <select class="mini" value={flags.gridSize} on:change={(e) => setFlag('gridSize', Number(e.target.value))} aria-label="Grid size">
          {#each session.gridSizes as g}<option value={g}>{g} m</option>{/each}
        </select>
      {/if}

      <div class="spacer"></div>

      <span class="pill"><i class="dot" class:on={selCount > 0}></i>{selCount === 1 ? '1 object selected' : `${selCount} objects selected`}</span>
      <button type="button" class="icon" on:click={() => cmd('undo')} disabled={!st.canUndo} title="Undo (Ctrl+Z)" aria-label="Undo"><Icon name="chevronLeft" size={15} /></button>
      <button type="button" class="icon" on:click={() => cmd('redo')} disabled={!st.canRedo} title="Redo (Ctrl+Y)" aria-label="Redo"><Icon name="chevronRight" size={15} /></button>
      <button type="button" class="btn" on:click={requestClose}>Close</button>
      <button type="button" class="btn btn-primary" on:click={() => cmd('save')}><Icon name="save" size={14} /><span>Save Layout</span></button>
    </header>

    <!-- ─── over the world ─── -->
    <div class="world-info" aria-hidden="true">
      {#if $placer.cursor}<span class="mono">X {$placer.cursor.x}  Y {$placer.cursor.y}  Z {$placer.cursor.z}</span>{/if}
    </div>
    <div class="help" role="presentation" on:mouseenter={leaveWorld}>
      <span><kbd>Right mouse</kbd> hold: look · <kbd>W A S D</kbd> fly · <kbd>Q E</kbd> down / up · <kbd>Shift</kbd> fast</span>
      <span><kbd>Click</kbd> place / select · <kbd>Shift+Click</kbd> multi-select · <kbd>Alt+Wheel</kbd> rotate · <kbd>G</kbd> ground · <kbd>F</kbd> freeze · <kbd>D</kbd> duplicate · <kbd>Del</kbd> delete</span>
    </div>
    {#if armed}
      <div class="armed-tag">Placing <b>{armed.label}</b>{armed.stackable ? ` · ${armed.stack} high` : ''} — click in the world · <kbd>Esc</kbd> stop</div>
    {/if}

    <!-- ─── inspector ─── -->
    <aside class="inspector" role="presentation" on:mouseenter={leaveWorld}>
      <div class="ins-head">
        {#if active}
          <div class="obj-name">{names[active.id] || active.model}</div>
          <div class="obj-sub">{active.model} · {active.vehicle ? 'Vehicle' : 'Prop'}{active.missing ? ' · model missing in this game build' : ''}</div>
        {:else}
          <div class="obj-name muted">Nothing selected</div>
          <div class="obj-sub">{compact ? 'The object is created where the camera looks.' : 'Pick an asset below and click in the world, or click an object to select it.'}</div>
        {/if}
      </div>

      {#if !compact}
        <nav class="tabs" role="tablist" aria-label="Inspector">
          <button type="button" role="tab" aria-selected={tab === 'object'} class:on={tab === 'object'} on:click={() => (tab = 'object')}>Object</button>
          <button type="button" role="tab" aria-selected={tab === 'batch'} class:on={tab === 'batch'} on:click={() => (tab = 'batch')}>Batch{#if selCount}<em>{selCount}</em>{/if}</button>
          <button type="button" role="tab" aria-selected={tab === 'layout'} class:on={tab === 'layout'} on:click={() => (tab = 'layout')}>Layout<em>{objects.length}</em></button>
        </nav>
      {/if}

      <div class="ins-scroll">
        {#if compact || tab === 'object'}
        {#if active}
          <section class="sec">
            <h4>Position</h4>
            <div class="fields">
              {#each ['x', 'y', 'z'] as k}
                <label class="f"><span>{k.toUpperCase()}</span><input type="number" step="0.05" value={fmt(active[k])} on:change={(e) => setField(k, e.target.value)} on:keydown={blurOnEnter} /></label>
              {/each}
            </div>
            <div class="row">
              <button type="button" class="btn" on:click={copyPos}>Copy Position</button>
              <button type="button" class="btn" on:click={pastePos} disabled={!clip.pos}>Paste</button>
            </div>
          </section>

          <section class="sec">
            <h4>Rotation</h4>
            <div class="fields">
              {#each [['rx', 'X'], ['ry', 'Y'], ['rz', 'Z']] as [k, label]}
                <label class="f"><span>{label}</span><input type="number" step="1" value={fmt(active[k])} disabled={active.stackable && k !== 'rz'} on:change={(e) => setField(k, e.target.value)} on:keydown={blurOnEnter} /></label>
              {/each}
            </div>
            <div class="row">
              <button type="button" class="btn" on:click={resetRot}>Reset Rotation</button>
              <button type="button" class="btn" on:click={copyRot}>Copy Rotation</button>
              <button type="button" class="btn" on:click={pasteRot} disabled={!clip.rot}>Paste</button>
            </div>
          </section>

          {#if active.stackable && features.stack}
            <section class="sec">
              <h4>Stack height <small>(pieces on top of each other)</small></h4>
              <div class="seg stack-seg" role="group" aria-label="Stack height">
                {#each Array.from({ length: maxStack }, (_, i) => i + 1) as n}
                  <button type="button" class:on={active.stack === n} on:click={() => cmd('update', { id: active.id, patch: { stack: n } })}>{n}</button>
                {/each}
              </div>
            </section>
          {/if}
          {#if features.collision}
            <section class="sec">
              <label class="check"><input type="checkbox" checked={active.collision} on:change={(e) => cmd('update', { id: active.id, patch: { collision: e.target.checked } })} /> Solid (players cannot walk through it)</label>
            </section>
          {/if}

          <section class="sec">
            <h4>Placement</h4>
            <div class="row">
              {#if !compact}<button type="button" class="btn btn-primary" on:click={() => cmd('duplicate', { count: 1 })}><Icon name="copy" size={14} /><span>Duplicate</span></button>{/if}
              <button type="button" class="btn" on:click={() => cmd('ground')} disabled={active.locked}>Put on Ground</button>
            </div>
            <div class="row">
              <button type="button" class="btn" class:locked={active.locked} on:click={() => cmd('lock')} title="Freeze the selected objects in place (F)">{active.locked ? 'Unfreeze (F)' : 'Freeze in place (F)'}</button>
            </div>
            {#if !compact}<div class="row">
              <button type="button" class="btn" on:click={addSameModel} title="Add every object of this model to the batch (selection)">Select Same Model</button>
              <button type="button" class="btn danger" on:click={() => cmd('delete', { ids: [...selected] })}><Icon name="trash" size={14} /><span>Delete</span></button>
            </div>{/if}
          </section>
        {:else if !compact}
          <div class="empty tall">
            <b>No object selected</b>
            <span>Click an object in the world to select it, or pick an asset from the library below and click to place it.</span>
          </div>
        {/if}
        {/if}

        <!-- ─── Batch: actions on the selection, or the "Placing" card while an asset is armed ─── -->
        {#if !compact && tab === 'batch'}
          {#if armed}
            <section class="sec">
              <h4>Placing</h4>
              <div class="batch-name">{armed.label}</div>
              {#if armed.stackable && features.stack}
                <div class="batch-sub">Stack height — preview shown in the world</div>
                <div class="seg stack-seg" role="group" aria-label="Stack height to place">
                  {#each Array.from({ length: maxStack }, (_, i) => i + 1) as n}
                    <button type="button" class:on={armed.stack === n} on:click={() => cmd('armStack', { n })}>{n}</button>
                  {/each}
                </div>
              {/if}
              <div class="row"><button type="button" class="btn" on:click={() => cmd('disarm')}>Stop placing</button></div>
            </section>
          {:else}
            <section class="sec">
              <div class="batch-head">
                <div class="batch-count">{selCount}</div>
                <div class="batch-meta"><b>{selCount === 1 ? 'object selected' : 'objects selected'}</b><span>{objects.length} in layout</span></div>
              </div>
              <div class="row">
                <button type="button" class="btn" on:click={() => cmd('selectAll')} disabled={!objects.length} title="Ctrl+A">Select All</button>
                <button type="button" class="btn" on:click={addSameModel} disabled={!active} title="Select every object of the same model as the active one — e.g. all the containers">Select Same Model</button>
              </div>
              <p class="hint">Shift+Click adds or removes one object. Drag, arrow keys or Alt+Wheel move and turn the whole selection as one piece.</p>
            </section>

            <section class="sec">
              <h4>Spawn</h4>
              <div class="row">
                <button type="button" class="btn btn-primary" on:click={() => cmd('spawn', { scope: 'all' })} disabled={!objects.length}>Spawn All</button>
                <button type="button" class="btn" on:click={() => cmd('spawn', { scope: 'selected' })} disabled={!selCount}>Spawn Selected</button>
              </div>
            </section>

            <section class="sec">
              <h4>Duplicate</h4>
              <div class="row">
                <button type="button" class="btn" on:click={() => cmd('duplicate', { count: dupCount })} disabled={!selCount}><Icon name="copy" size={14} /><span>Duplicate selection</span></button>
                <label class="copies"><span>Copies</span><input class="num" type="number" min="1" max="50" bind:value={dupCount} aria-label="Copies" /></label>
              </div>
            </section>

            {#if stackableSel.length}
              <section class="sec">
                <h4>Height of the selected stacks</h4>
                <div class="seg stack-seg" role="group" aria-label="Height of the selection">
                  {#each Array.from({ length: maxStack }, (_, i) => i + 1) as n}
                    <button type="button" on:click={() => cmd('batch', { stack: n })}>{n}</button>
                  {/each}
                </div>
              </section>
            {/if}

            {#if selCount > 1}
              <section class="sec">
                <h4>Move the whole selection <small>(metres)</small></h4>
                <div class="fields">
                  {#each [['dx', 'X'], ['dy', 'Y'], ['dz', 'Z']] as [k, label]}
                    <label class="f"><span>{label}</span><input type="number" step="0.5" bind:value={batchMove[k]} /></label>
                  {/each}
                </div>
                <div class="row"><button type="button" class="btn" on:click={applyBatchMove}>Apply move</button></div>
              </section>
            {/if}

            <section class="sec">
              <h4>Layout</h4>
              <div class="row">
                <button type="button" class="btn" on:click={copyVectors} disabled={!objects.length}>Copy {selCount ? 'Selected' : 'All'} Vectors</button>
                <button type="button" class="btn danger" on:click={clearAll} disabled={!objects.length}>{confirmClear ? 'Sure?' : 'Clear All'}</button>
              </div>
            </section>
          {/if}
        {/if}

        {#if !compact && tab === 'layout'}
          <section class="sec">
            <h4>Options</h4>
            <label class="check"><input type="checkbox" checked={flags.keepTool} on:change={(e) => setFlag('keepTool', e.target.checked)} /> Keep placing (off = one click places one, then the tool is put away)</label>
            <label class="check"><input type="checkbox" checked={flags.spawnOnPlace} on:change={(e) => setFlag('spawnOnPlace', e.target.checked)} /> Spawn on place (off = hologram until you press Spawn)</label>
          </section>

          <section class="sec">
            <h4>Objects in layout · {objects.length}<small> / {maxObjects}</small></h4>
            <div class="list">
              {#each objects as o (o.id)}
                <div class="sel" class:active={o.id === st.active} class:in={selected.has(o.id)} role="button" tabindex="0" on:click={(e) => selectRow(o, e)} on:keydown={(e) => e.key === 'Enter' && selectRow(o, e)}>
                  <div class="sel-main">
                    <span class="sel-name">{names[o.id]}{o.locked ? ' · frozen' : ''}{o.spawned ? '' : ' · hologram'}{o.missing ? ' · missing' : ''}</span>
                    <span class="sel-coord">{fmt(o.x)} · {fmt(o.y)} · {fmt(o.z)}{o.stack > 1 ? ` · ${o.stack} high` : ''}</span>
                  </div>
                  <button type="button" class="x" title="Focus the camera" on:click|stopPropagation={() => cmd('focus', { id: o.id })} aria-label="Focus"><Icon name="eye" size={13} /></button>
                  <button type="button" class="x del" title="Delete" on:click|stopPropagation={() => cmd('delete', { ids: [o.id] })} aria-label="Delete"><Icon name="close" size={13} /></button>
                </div>
              {:else}
                <div class="empty">No objects yet.</div>
              {/each}
            </div>
          </section>
        {/if}
      </div>

      <div class="ins-foot">
        <button type="button" class="btn" on:click={requestClose}>Cancel</button>
        <button type="button" class="btn btn-primary" on:click={() => cmd('save')}><Icon name="save" size={14} /><span>Save Layout</span></button>
      </div>
    </aside>

    <!-- ─── asset library + batch ─── -->
    {#if !compact}
      <section class="assets" class:closed={!libOpen} role="presentation" on:mouseenter={leaveWorld}>
        {#if !libOpen}
          <!-- collapsed: a slim bar, so the world gets the whole height -->
          <div class="lib-bar">
            <b>Asset library</b>
            <span>{armed ? `Placing ${armed.label}` : `${totalAssets} props`}</span>
            <button type="button" class="btn" on:click={toggleLib}><Icon name="chevronUp" size={13} /><span>Show library</span></button>
          </div>
        {:else}
        <div class="filters">
          <button type="button" class="lib-toggle" on:click={toggleLib} title="Hide the library to give the world more room" aria-label="Hide library"><Icon name="chevronDown" size={14} /></button>
          <label class="type-pick" title="Filter the library by type">
            <span>Type</span>
            <select bind:value={category} aria-label="Prop type">
              <option value="all">All types ({totalAssets})</option>
              {#each session.categories as c}<option value={c.id}>{c.label} ({typeCounts[c.id] || 0})</option>{/each}
            </select>
          </label>
          <div class="chips-container">
            <button
              type="button"
              class="chips-arrow prev"
              on:click={() => scrollChips(-1)}
              title="Scroll categories left"
              aria-label="Scroll left"
            >
              <Icon name="chevronLeft" size={12} />
            </button>
            <div
              class="chips"
              bind:this={chipsEl}
              class:is-dragging={isDraggingChips}
              on:mousedown={onChipsMouseDown}
              on:mousemove={onChipsMouseMove}
              on:mouseup={onChipsMouseUp}
              on:mouseleave={onChipsMouseUp}
              on:wheel={onChipsWheel}
            >
              <button
                type="button"
                class="chip"
                class:on={category === 'all'}
                on:click={(e) => handleChipClick('all', e)}
              >
                Everything
              </button>
              {#each session.categories as c}
                <button
                  type="button"
                  class="chip"
                  class:on={category === c.id}
                  on:click={(e) => handleChipClick(c.id, e)}
                >
                  {c.label}
                </button>
              {/each}
            </div>
            <button
              type="button"
              class="chips-arrow next"
              on:click={() => scrollChips(1)}
              title="Scroll categories right"
              aria-label="Scroll right"
            >
              <Icon name="chevronRight" size={12} />
            </button>
          </div>
          <span class="shown">{filtered.length} shown</span>
          <input class="search" type="text" placeholder="Search props or type a model name…" bind:value={query} spellcheck="false" />
        </div>
        <div class="asset-body" on:scroll={onAssetBodyScroll}>
          <div class="grid">
            {#each visibleFiltered as a (a.model)}
              <button type="button" class="asset" class:armed={armed && armed.model === a.model} on:click={() => armAsset(a)} title={a.model}>
                <span class="thumb"><Icon name={iconFor(a)} size={22} />{#if a.stackable && features.stack}<em>stack</em>{/if}</span>
                <span class="aname">{a.label}</span>
                <span class="amodel">{a.model}</span>
              </button>
            {/each}
            {#if customCandidate}
              <button type="button" class="asset custom" on:click={() => cmd('custom', { model: customCandidate })} title="Use this model name">
                <span class="thumb"><Icon name="plus" size={22} /></span>
                <span class="aname">Add model</span>
                <span class="amodel">{customCandidate}</span>
              </button>
            {/if}
            {#if filtered.length === 0 && !customCandidate}
              <div class="empty wide">No assets match. Type a GTA model name to use any other model.</div>
            {/if}
          </div>
          {#if filtered.length > pageLimit}
            <div class="asset-load-more-bar">
              <button type="button" class="btn btn-load-more" on:click={() => (pageLimit = Math.min(filtered.length, pageLimit + 80))}>
                <Icon name="chevronDown" size={13} />
                <span>Load More Assets ({filtered.length - pageLimit} remaining)</span>
              </button>
            </div>
          {/if}
        </div>
        {/if}
      </section>
    {/if}

    {#if toast}
      <div class="toast" class:warn={toast.kind === 'warn'} class:error={toast.kind === 'error'} class:ok={toast.kind === 'ok'} transition:fade={{ duration: 120 }}>{toast.text}</div>
    {/if}

    {#if askLeave}
      <div class="modal" role="dialog" aria-modal="true" aria-label="Unsaved changes">
        <div class="modal-card">
          <h3>Leave the Prop Placer?</h3>
          <p>You changed this layout and have not saved it.</p>
          <div class="modal-actions">
            <button type="button" class="btn" on:click={() => (askLeave = false)}>Keep editing</button>
            <button type="button" class="btn danger" on:click={discardAndClose}>Discard</button>
            <button type="button" class="btn btn-primary" on:click={saveAndClose}>Save &amp; close</button>
          </div>
        </div>
      </div>
    {/if}
  </div>
{/if}

<style>
  .pp {
    --top-h: 56px;
    --assets-h: 236px;
    --ins-w: 400px;
    position: fixed; inset: 0; z-index: 900;
    pointer-events: none;
    font-family: var(--font-ui);
    color: var(--text-label);
    font-size: var(--fs-small);
  }
  .pp.compact { --assets-h: 0px; }
  .pp.lib-closed:not(.compact) { --assets-h: 52px; }
  .pp * { box-sizing: border-box; }
  .pp.looking .capture { cursor: none; }

  .capture { position: fixed; inset: 0; pointer-events: auto; background: transparent; z-index: 1; cursor: crosshair; }

  /* panels sit above the capture layer and take the mouse themselves */
  .top, .inspector, .assets, .help, .modal { pointer-events: auto; z-index: 2; }

  /* ── top bar ── */
  .top {
    position: fixed; left: 0; right: 0; top: 0; height: var(--top-h);
    display: flex; align-items: center; gap: 14px; padding: 0 14px;
    background: var(--topbar-bg, #15171b); border-bottom: 1px solid var(--tablet-border, #2a2e35);
  }
  .brand { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .brand-mark { width: 30px; height: 30px; display: grid; place-items: center; border-radius: var(--r-ctl); background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); color: var(--accent-primary); flex-shrink: 0; }
  .brand-text { display: flex; flex-direction: column; line-height: 1.2; min-width: 0; }
  .brand-text b { font-size: var(--fs-body); letter-spacing: 0.01em; color: var(--text-main); }
  .brand-text small { font-size: var(--fs-meta); color: var(--text-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 230px; }
  .spacer { flex: 1; }

  .seg { display: inline-flex; border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-ctl); overflow: hidden; background: #1f2328; }
  .seg button { display: inline-flex; align-items: center; gap: 6px; height: 32px; padding: 0 12px; color: var(--text-muted); font-size: var(--fs-small); font-weight: 600; border-right: 1px solid var(--tablet-border, #2a2e35); }
  .seg button:last-child { border-right: none; }
  .seg button:hover { background: #272b31; color: #fff; }
  .seg button.on { background: var(--accent-primary); color: #ffffff;
    text-shadow: none; }
  .stack-seg button { min-width: 36px; justify-content: center; padding: 0 8px; }

  .switch-row { display: inline-flex; align-items: center; gap: 8px; color: var(--text-muted); font-size: var(--fs-small); font-weight: 500; cursor: pointer; }
  .switch { width: 36px; height: 20px; border-radius: var(--r-tag); background: #30353c; border: 1px solid #414352; position: relative; flex-shrink: 0; transition: background 0.15s; }
  .switch i { position: absolute; top: 2px; left: 2px; width: 14px; height: 14px; border-radius: 50%; background: #8d949c; transition: transform 0.15s, background 0.15s; }
  .switch.on { background: #315d8e; border-color: var(--accent-primary); }
  .switch.on i { transform: translateX(16px); background: #fff; }

  .mini, .search, .num, .f input {
    height: 32px; padding: 0 10px; background: var(--input-bg, #15171b); border: 1px solid var(--input-border, #2a2e35);
    border-radius: var(--r-ctl); color: var(--text-main); font-size: var(--fs-small); outline: none; user-select: text;
  }
  .mini:focus, .search:focus, .num:focus, .f input:focus { border-color: var(--input-focus-border, #4f94e6); }
  .f input:disabled { opacity: 0.45; }

  .pill { display: inline-flex; align-items: center; gap: 8px; height: 32px; padding: 0 12px; border-radius: var(--r-tag); background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); color: var(--text-dim); font-weight: 600; font-size: var(--fs-meta); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #4a4c58; }
  .dot.on { background: var(--green, #46c98b); }
  .icon { width: 32px; height: 32px; display: grid; place-items: center; border-radius: var(--r-ctl); background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); color: #aeb5bd; }
  .icon:hover:not(:disabled) { background: #272b31; color: #fff; }
  .icon:disabled { opacity: 0.4; cursor: not-allowed; }
  .pp :global(.btn) { min-height: 32px; padding: 0 12px; font-size: var(--fs-small); }
  .pp :global(.btn.locked) { border-color: rgba(255, 200, 87, 0.55); color: #ffc857; }
  .pp :global(.btn.danger) { color: #ff8178; border-color: #60332f; }
  .pp :global(.btn.danger:hover:not(:disabled)) { background: #d9463e; border-color: #d9463e; color: #fff; }

  /* ── over the world ── */
  .world-info { position: fixed; left: 14px; top: calc(var(--top-h) + 12px); z-index: 2; pointer-events: none; }
  .mono { display: inline-block; padding: 5px 10px; border-radius: var(--r-ctl); background: rgba(13, 14, 20, 0.82); border: 1px solid var(--tablet-border, #2a2e35); color: var(--text-label); font-size: var(--fs-meta); }
  .help {
    position: fixed; left: 14px; bottom: calc(var(--assets-h) + 12px);
    display: flex; flex-direction: column; gap: 4px; padding: 8px 12px; max-width: calc(100vw - var(--ins-w) - 40px);
    background: rgba(13, 14, 20, 0.82); border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-ctl); color: var(--text-muted); font-size: var(--fs-meta); line-height: 1.5;
  }
  kbd { padding: 0 6px; border-radius: var(--r-tag); background: #1f2328; border: 1px solid #363b43; font-family: var(--font-mono); font-size: var(--fs-meta); color: #fff; }
  .armed-tag {
    position: fixed; left: 50%; top: calc(var(--top-h) + 12px); transform: translateX(-50%); z-index: 2; pointer-events: none;
    padding: 8px 16px; border-radius: var(--r-tag); background: rgba(23, 24, 33, 0.92); border: 1px solid var(--accent-border, rgba(79, 148, 230, 0.5)); color: var(--text-label); font-size: var(--fs-meta);
  }
  .armed-tag b { color: #fff; }

  /* ── inspector ── */
  .inspector {
    position: fixed; right: 0; top: var(--top-h); bottom: var(--assets-h); width: var(--ins-w);
    display: flex; flex-direction: column; background: var(--panel-bg, #181b1f); border-left: 1px solid var(--tablet-border, #2a2e35);
  }
  .ins-head { padding: 12px 14px; border-bottom: 1px solid var(--tablet-border, #2a2e35); min-height: 62px; }
  .obj-name { font-size: var(--fs-body); font-weight: 700; color: var(--text-main); overflow-wrap: anywhere; }
  .obj-name.muted { color: var(--text-muted); font-weight: 600; }
  .obj-sub { margin-top: 3px; font-size: var(--fs-meta); color: var(--text-muted); line-height: 1.4; }
  .ins-scroll { flex: 1; min-height: 0; overflow-y: auto; }
  .ins-foot { display: flex; gap: 8px; padding: 10px 14px; border-top: 1px solid var(--tablet-border, #2a2e35); }
  .ins-foot :global(.btn) { flex: 1; }
  .sec { padding: 12px 14px; border-bottom: 1px solid #1f2328; }
  .sec h4 { margin: 0 0 8px; font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-muted); }
  .sec h4 small { text-transform: none; letter-spacing: 0; font-weight: 500; color: var(--text-faint); }
  .fields { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
  .f { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .f span { font-size: var(--fs-meta); font-weight: 600; color: var(--text-muted); padding-left: 2px; }
  .f input { width: 100%; }
  .row { display: flex; gap: 8px; margin-top: 8px; align-items: center; flex-wrap: wrap; }
  .row :global(.btn) { flex: 1; min-width: 0; white-space: nowrap; }
  .check { display: flex; align-items: flex-start; gap: 8px; margin-top: 6px; font-size: var(--fs-small); color: var(--text-dim); line-height: 1.4; cursor: pointer; }
  .check input { accent-color: var(--accent-primary); margin-top: 2px; }

  .list { display: flex; flex-direction: column; gap: 5px; }
  .sel { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border: 1px solid var(--tablet-border, #2a2e35); background: #1c1f24; border-radius: var(--r-ctl); cursor: pointer; }
  .sel:hover { background: #1f2328; }
  .sel.in { border-color: rgba(79, 148, 230, 0.6); }
  .sel.active { border-color: var(--accent-primary); background: #1f2328; }
  .sel-main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .sel-name { font-size: var(--fs-small); color: var(--text-main); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sel-coord { font-size: var(--fs-meta); color: var(--text-faint); }
  .x { width: 26px; height: 26px; display: grid; place-items: center; border-radius: var(--r-tag); color: var(--text-muted); flex-shrink: 0; }
  .x:hover { background: #272b31; color: #fff; }
  .x.del:hover { background: rgba(255, 93, 80, 0.15); color: #ff5d50; }
  .empty { padding: 14px; text-align: center; color: var(--text-faint); font-size: var(--fs-small); }
  .empty.wide { grid-column: 1 / -1; }

  /* ── assets ── */
  .assets {
    position: fixed; left: 0; right: 0; bottom: 0; height: var(--assets-h); display: flex; flex-direction: column;
    background: var(--panel-bg, #181b1f); border-top: 1px solid var(--tablet-border, #2a2e35);
  }
  .filters { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--tablet-border, #2a2e35); }
  .type-pick { display: inline-flex; align-items: center; gap: 8px; flex-shrink: 0; color: var(--text-muted); font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; }
  .type-pick select { height: 30px; min-width: 170px; padding: 0 10px; background: var(--input-bg, #15171b); border: 1px solid var(--input-border, #2a2e35); border-radius: var(--r-ctl); color: var(--text-main); font-size: var(--fs-small); font-weight: 600; text-transform: none; letter-spacing: 0; outline: none; }
  .type-pick select:focus { border-color: var(--input-focus-border, #4f94e6); }
  .chips-container {
    display: flex;
    align-items: center;
    gap: 4px;
    flex: 1;
    min-width: 0;
  }
  .chips-arrow {
    width: 24px;
    height: 30px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: #1c1f24;
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-tag);
    color: var(--text-muted);
    cursor: pointer;
    flex-shrink: 0;
    transition: all 0.15s ease;
    user-select: none;
  }
  .chips-arrow:hover {
    background: #2a2e35;
    color: #fff;
    border-color: #3a4048;
  }
  .chips {
    display: flex;
    gap: 6px;
    flex: 1;
    min-width: 0;
    overflow-x: auto;
    scrollbar-width: none;
    -ms-overflow-style: none;
    padding-bottom: 2px;
    cursor: grab;
    user-select: none;
  }
  .chips::-webkit-scrollbar {
    display: none;
  }
  .chips.is-dragging {
    cursor: grabbing;
    user-select: none;
  }
  .chips .chip {
    flex-shrink: 0;
    user-select: none;
  }
  .shown { flex-shrink: 0; font-size: var(--fs-meta); color: var(--text-faint); }
  .chip { height: 30px; padding: 0 12px; border-radius: var(--r-tag); background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); color: var(--text-muted); font-size: var(--fs-meta); font-weight: 600; white-space: nowrap; }
  .chip:hover { background: #272b31; color: #fff; }
  .chip.on { background: var(--accent-primary); border-color: var(--accent-primary); color: #ffffff;
    text-shadow: none; }
  .search { margin-left: auto; width: 270px; flex-shrink: 0; }
  .asset-body { flex: 1; min-height: 0; display: flex; flex-direction: column; overflow-y: auto; }
  .grid {
    flex: 1; min-width: 0; padding: 10px 12px;
    display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); grid-auto-rows: 92px; gap: 8px; align-content: start;
  }
  .asset-load-more-bar { display: flex; justify-content: center; padding: 10px 14px 16px; }
  .btn-load-more {
    display: inline-flex; align-items: center; gap: 8px; height: 34px; padding: 0 18px; border-radius: var(--r-ctl);
    background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); color: var(--text-label); font-size: var(--fs-small); font-weight: 600; cursor: pointer; transition: all 0.15s ease;
  }
  .btn-load-more:hover { background: #272b31; border-color: var(--accent-primary, #4f94e6); color: #fff; }
  .asset { display: flex; flex-direction: column; align-items: stretch; text-align: left; padding: 0; overflow: hidden; border: 1px solid var(--tablet-border, #2a2e35); border-radius: var(--r-ctl); background: #1c1f24; }
  .asset:hover { background: #272b31; border-color: #363b43; }
  .asset.armed { border-color: var(--accent-primary); box-shadow: inset 0 0 0 1px var(--accent-primary); background: #1f2328; }
  .asset.custom { border-style: dashed; }
  .thumb { position: relative; height: 40px; display: grid; place-items: center; background: #1f2328; color: #8d949c; }
  .thumb em { position: absolute; right: 5px; top: 4px; font-style: normal; font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: #7bb6f2; }
  .aname { padding: 4px 8px 0; font-size: var(--fs-meta); font-weight: 600; color: var(--text-main); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .amodel { padding: 0 8px; font-size: var(--fs-meta); color: var(--text-faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  /* ── inspector tabs ── */
  .tabs { display: flex; gap: 4px; padding: 8px 10px 0; border-bottom: 1px solid var(--tablet-border, #2a2e35); background: var(--panel-bg, #181b1f); }
  .tabs button {
    flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: 7px; height: 36px; padding: 0 10px;
    border: 1px solid transparent; border-bottom: none; border-radius: var(--r-ctl) var(--r-ctl) 0 0; color: var(--text-muted); font-size: var(--fs-small); font-weight: 600;
  }
  .tabs button:hover { background: #1f2328; color: #fff; }
  .tabs button.on { background: #1f2328; border-color: var(--tablet-border, #2a2e35); color: #fff; box-shadow: none; }
  .tabs em { min-width: 20px; padding: 1px 6px; border-radius: var(--r-ctl); background: #2a2e35; color: #c9ced4; font-style: normal; font-size: var(--fs-meta); font-weight: 700; text-align: center; }
  .tabs button.on em { background: var(--accent-primary); color: #ffffff;
    text-shadow: none; }

  /* ── batch tab ── */
  .batch-head { display: flex; align-items: center; gap: 14px; }
  .batch-count { min-width: 56px; height: 56px; display: grid; place-items: center; border-radius: var(--r-tag); background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); font-size: var(--fs-section); font-weight: 700; color: var(--text-main);
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .batch-meta { display: flex; flex-direction: column; gap: 2px; }
  .batch-meta b { font-size: var(--fs-body); color: var(--text-main); }
  .batch-meta span { font-size: var(--fs-meta); color: var(--text-muted); }
  .batch-name { font-size: var(--fs-body); font-weight: 700; color: var(--text-main); overflow-wrap: anywhere; }
  .batch-sub { margin: 4px 0 8px; font-size: var(--fs-meta); color: var(--text-muted); }
  .hint { margin: 10px 0 0; font-size: var(--fs-meta); line-height: 1.5; color: var(--text-faint); }
  .copies { display: inline-flex; align-items: center; gap: 8px; flex: none; color: var(--text-muted); font-size: var(--fs-meta); font-weight: 600; }
  .copies .num { width: 64px; }
  .empty.tall { display: flex; flex-direction: column; gap: 6px; padding: 28px 22px; line-height: 1.5; }
  .empty.tall b { color: var(--text-dim); font-size: var(--fs-body); }

  /* ── the library, collapsed ── */
  .lib-toggle { width: 30px; height: 30px; flex-shrink: 0; display: grid; place-items: center; border-radius: var(--r-ctl); background: #1f2328; border: 1px solid var(--tablet-border, #2a2e35); color: #aeb5bd; }
  .lib-toggle:hover { background: #272b31; color: #fff; }
  .lib-bar { height: 100%; display: flex; align-items: center; gap: 14px; padding: 0 14px; }
  .lib-bar b { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-muted); }
  .lib-bar span { flex: 1; font-size: var(--fs-small); color: var(--text-faint); }

  /* ── toast / modal ── */
  .toast {
    position: fixed; left: 50%; bottom: calc(var(--assets-h) + 70px); transform: translateX(-50%); z-index: 3; pointer-events: none;
    padding: 9px 16px; border-radius: var(--r-ctl); background: var(--panel-bg, #181b1f); border: 1px solid var(--tablet-border-strong, #363b43); color: var(--text-label); font-size: var(--fs-small); box-shadow: var(--shadow-soft);
  }
  .toast.warn { border-color: rgba(255, 200, 87, 0.5); color: #f0c36d; }
  .toast.error { border-color: rgba(255, 93, 80, 0.5); color: #ff8178; }
  .toast.ok { border-color: rgba(70, 201, 139, 0.5); color: #78d6a8; }
  .modal { position: fixed; inset: 0; z-index: 5; display: grid; place-items: center; background: rgba(0, 0, 0, 0.55); }
  .modal-card { width: 420px; padding: 20px; border-radius: var(--r-ctl); background: var(--surface-dialog); border: 1px solid var(--border-dialog); box-shadow: var(--shadow-soft); }
  .modal-card h3 { margin: 0 0 6px; font-size: var(--fs-emph); color: var(--text-main); }
  .modal-card p { margin: 0 0 16px; color: var(--text-dim); font-size: var(--fs-small); }
  .modal-actions { display: flex; gap: 8px; justify-content: flex-end; }

  @media (max-width: 1280px) {
    .pp { --ins-w: 350px; --assets-h: 224px; }
    .brand-text small { max-width: 140px; }
    .search { width: 200px; }
    .switch-row span { display: none; }
  }
</style>
