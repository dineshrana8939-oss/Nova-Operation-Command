<script>
  import { onMount } from 'svelte';
  import { hudCursorMode } from './hudStore.js';
  import { themeVars } from './eventThemes.js';
  import { fetchNui } from '../api/nui.js';
  import './hud-shared.css';

  // Squad roster (GangSquad / PoliceSquad decide WHO is listed), on the same card as the convoy clock and progress boxes:
  // an accent rail on top, a header with the squad name and how many are alive, then one line per player.
  // It is built for a crowd: with up to 10 players each gets a roomy row (HP and armour both labelled); 11-24 get a compact one-line
  // row; 25-50 are laid out in TWO columns so fifty names still fit on screen, and the list scrolls when the cursor is on.
  // Controls stay ABOVE the card: ; = cursor (drag by the header, scroll the list), L = show, X = hide.
  //
  // members: [{ id, name, hp, armour, status: 'active' | 'down' | 'offline' }]
  export let title = 'Crew Status';
  export let members = [];
  export let ariaLabel = 'Crew health and armour';
  export let visibleRows = 10;      // kept for the callers; the list is sized to the screen instead
  export let sub = '';
  export let footerRight = '';
  export let accent = '';
  export let accent2 = '';
  export let accentRGB = '';
  export let activeCount = 0;
  export let kind = 'gang';

  let posX = 24;
  // default spot: top left, under the convoy clock and progress card (a saved position still wins)
  const DEFAULT_Y = () => Math.max(10, Math.min(350, (typeof window !== 'undefined' ? window.innerHeight : 720) - 200));
  let posY = DEFAULT_Y();
  let isDragging = false;
  let dragOffsetX = 0;
  let dragOffsetY = 0;

  $: n = members.length;
  $: density = n <= 10 ? 'roomy' : n <= 24 ? 'compact' : 'dense';
  $: width = density === 'dense' ? 548 : 318;

  // Same saved spot the old squad HUDs used, so nobody loses their layout.
  onMount(() => {
    try {
      const saved = localStorage.getItem('nova_health_hud_pos');
      if (saved) {
        const parsed = JSON.parse(saved);
        if (typeof parsed.x === 'number' && typeof parsed.y === 'number') {
          posX = Math.max(10, Math.min(window.innerWidth - width - 10, parsed.x));
          posY = Math.max(10, Math.min(window.innerHeight - 100, parsed.y));
        }
      } else {
        posY = DEFAULT_Y();
      }
    } catch (e) {}
  });

  function startDrag(e) {
    if (!$hudCursorMode) return;
    isDragging = true;
    dragOffsetX = e.clientX - posX;
    dragOffsetY = e.clientY - posY;
    window.addEventListener('mousemove', onDrag);
    window.addEventListener('mouseup', stopDrag);
  }
  function onDrag(e) {
    if (!isDragging) return;
    posX = Math.max(10, Math.min(window.innerWidth - width - 10, e.clientX - dragOffsetX));
    posY = Math.max(10, Math.min(window.innerHeight - 100, e.clientY - dragOffsetY));
  }
  function stopDrag() {
    if (!isDragging) return;
    isDragging = false;
    window.removeEventListener('mousemove', onDrag);
    window.removeEventListener('mouseup', stopDrag);
    try {
      localStorage.setItem('nova_health_hud_pos', JSON.stringify({ x: posX, y: posY }));
    } catch (e) {}
  }
  function closeCursor() {
    hudCursorMode.set(false);
    fetchNui('hud:closeCursor', {});
  }

  const clamp = (v) => Math.max(0, Math.min(100, Number(v) || 0));
  const RANK = { active: 0, down: 1, offline: 2 };

  // active first, then downed, then offline; by name inside each group so rows do not jump around as health changes
  $: sorted = [...members].sort((a, b) => (RANK[a.status] ?? 3) - (RANK[b.status] ?? 3) || String(a.name).localeCompare(String(b.name)));
  $: alive = members.filter((m) => m.status === 'active').length;
  $: downCount = members.filter((m) => m.status === 'down').length;
  $: avgHp = alive ? members.filter((m) => m.status === 'active').reduce((s, m) => s + clamp(m.hp), 0) / alive : 0;
  $: overflow = density === 'dense' ? n > 50 : n > 14;

  // low health is flagged by the colour of the bar and the pip
  const tone = (m) => (m.status !== 'active' ? 'off' : clamp(m.hp) <= 25 ? 'crit' : clamp(m.hp) <= 50 ? 'warn' : 'ok');
  const SEGMENTS = 24;
  $: litSegments = Math.round((avgHp / 100) * SEGMENTS);
  $: themeStyle = accent ? `--accent:${accent};--accent2:${accent2 || accent};--accentRGB:${accentRGB || '238,138,43'}` : themeVars('convoy');
</script>

<div
  class="team-hud"
  class:cursor-active={$hudCursorMode}
  class:is-dragging={isDragging}
  style="{themeStyle}; width:{width}px; left:{posX}px; top:{posY}px;"
  on:mousedown={startDrag}
  role="region"
  aria-label={ariaLabel}
>
  <!-- control bindings stay on top -->
  <div class="hint" class:cursor-hint={$hudCursorMode}>
    <span class="key">;</span> Cursor <i class="sep"></i> <span class="key">L</span> Show <i class="sep"></i> <span class="key">X</span> Hide
    {#if overflow}<i class="sep"></i> {$hudCursorMode ? 'Wheel to scroll' : 'Cursor to scroll'}{/if}
  </div>

  {#if $hudCursorMode}
    <div class="drag-bar">
      <span class="drag-title">✥ DRAG TO REPOSITION</span>
      <button class="lock-btn" on:click|stopPropagation={closeCursor} title="Lock Position (or press [;] / [Esc])">✓ LOCK</button>
    </div>
  {/if}

  <section class="hx-card card" class:cursor-active={$hudCursorMode} on:mousedown|stopPropagation={() => {}}>
    <div class="hx-texture"></div>
    <div class="hx-rail"><span></span></div>

    <!-- svelte-ignore a11y-no-static-element-interactions -->
    <header class="head" on:mousedown|stopPropagation={startDrag}>
      <div class="hx-iconbox mark"><slot name="mark"><span class="mark-dot"></span></slot></div>
      <div class="copy">
        <div class="name" title={title}>{title}</div>
        <div class="subline"><span class="hx-live-dot"></span>{sub || 'Squad status'}{#if downCount > 0}<em>· {downCount} down</em>{/if}</div>
      </div>
      <div class="count" title="alive / on the roster">
        <b>{alive}</b><span>/{n}</span>
      </div>
    </header>

    <div class="hx-segments avg" aria-hidden="true" title="Average health of the living">
      {#each Array(SEGMENTS) as _, i}<i class:on={i < litSegments}></i>{/each}
    </div>

    <div class="members {density}" class:cursor-active={$hudCursorMode}>
      {#each sorted as m (m.id)}
        <div class="member {tone(m)}" class:inactive={m.status !== 'active'}>
          <span class="pip"></span>
          <span class="mname" title={m.name}>{m.name}</span>
          {#if density === 'roomy'}
            <span class="bars">
              <span class="line"><i class="lab">HP</i><span class="track"><span class="fill hp" style="width:{m.status === 'active' ? clamp(m.hp) : 0}%"></span></span><i class="pctv">{m.status === 'active' ? `${Math.round(clamp(m.hp))}` : m.status === 'offline' ? 'OFF' : 'DOWN'}</i></span>
              <span class="line"><i class="lab ar">AR</i><span class="track thin"><span class="fill ar" style="width:{m.status === 'active' ? clamp(m.armour) : 0}%"></span></span><i class="pctv dim">{m.status === 'active' ? `${Math.round(clamp(m.armour))}` : '--'}</i></span>
            </span>
          {:else}
            <span class="bars one">
              <span class="stack"><span class="track"><span class="fill hp" style="width:{m.status === 'active' ? clamp(m.hp) : 0}%"></span></span><span class="ar-track"><span class="ar-fill" style="width:{m.status === 'active' ? clamp(m.armour) : 0}%"></span></span></span>
              <i class="pctv">{m.status === 'active' ? `${Math.round(clamp(m.hp))}` : m.status === 'offline' ? 'OFF' : 'DOWN'}</i>
            </span>
          {/if}
        </div>
      {/each}
    </div>
  </section>
</div>

<style>
  .team-hud {
    position: fixed;
    z-index: 9980;
    pointer-events: none;
    user-select: none;
    box-sizing: border-box;
    color: #eceef0;
    font-family: var(--font-ui);
  }
  .team-hud *, .team-hud *::before, .team-hud *::after { box-sizing: border-box; }
  .team-hud.cursor-active { pointer-events: auto; }
  .team-hud.is-dragging { opacity: 0.92; }
  .team-hud.is-dragging .head, .team-hud.is-dragging .drag-bar { cursor: grabbing; }

  /* controls on top: key hint, then the drag/lock bar while the cursor is on */
  .hint {
    margin-bottom: 6px;
    padding: 5px 10px;
    text-align: center;
    background: rgba(15, 17, 19, 0.88);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--r-ctl);
    color: #9aa3ad;
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.03em;
  }
  .hint.cursor-hint { color: var(--accent2); border-color: rgba(var(--accentRGB), 0.5); }
  .sep { display: inline-block; width: 1px; height: 10px; margin: 0 7px; vertical-align: middle; background: rgba(255, 255, 255, 0.18); }
  .key {
    display: inline-block;
    min-width: 17px;
    padding: 0 5px;
    margin-right: 3px;
    border: 1px solid rgba(var(--accentRGB), 0.5);
    border-radius: 5px;
    background: rgba(var(--accentRGB), 0.12);
    color: #fff;
    font-size: 11.5px;
    font-weight: 800;
    text-align: center;
  }

  .drag-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 6px;
    padding: 6px 12px;
    background: rgba(15, 17, 19, 0.96);
    border: 1px dashed var(--accent);
    border-radius: var(--r-ctl);
    font-size: 11.5px;
    font-weight: 800;
    color: #fff;
    cursor: grab;
  }
  .drag-title { letter-spacing: 0.05em; color: var(--accent2); }
  .lock-btn {
    padding: 4px 11px;
    border: none;
    border-radius: 6px;
    background: var(--accent);
    color: #1b1005;
    font-size: 11.5px;
    font-weight: 800;
    cursor: pointer;
  }

  /* ── the card ── */
  .card { padding: 10px 11px 8px; animation: hxEnterLeft 0.6s cubic-bezier(0.16, 1, 0.3, 1) both; }
  .card.cursor-active { border-color: rgba(var(--accentRGB), 0.55); }

  .head { position: relative; display: flex; align-items: center; gap: 9px; padding-bottom: 2px; }
  .cursor-active .head { cursor: grab; }
  .mark { width: 30px; height: 30px; }
  .mark :global(svg) { width: 16px; height: 16px; }
  .mark-dot { width: 9px; height: 9px; background: var(--accent); transform: rotate(45deg); }
  .copy { flex: 1; min-width: 0; }
  .name {
    color: #fff;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: 14px;
    line-height: 1.1;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .subline {
    display: flex;
    align-items: center;
    gap: 5px;
    margin-top: 3px;
    color: #9aa3ad;
    font-size: 10px;
    font-weight: 800;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .subline em { color: #ff8a80; font-style: normal; }
  .count { flex: none; color: #fff; font-family: var(--font-display); font-stretch: var(--stretch-display); line-height: 1; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .count b { font-size: 26px; font-weight: 700; }
  .count span { color: var(--accent2); font-size: 14px; font-weight: 700; }

  .avg { position: relative; margin: 9px 0 8px; height: 3px; }

  /* ── the list ── */
  .members {
    position: relative;
    max-height: min(calc(100vh - 250px), 620px);
    overflow-y: auto;
    overflow-x: hidden;
    overscroll-behavior: contain;
    scrollbar-width: thin;
    scrollbar-color: rgba(var(--accentRGB), 0.5) transparent;
  }
  .members.dense { display: grid; grid-template-columns: 1fr 1fr; column-gap: 12px; align-content: start; }

  .member {
    display: grid;
    align-items: center;
    column-gap: 8px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
  }
  .members.roomy .member { grid-template-columns: 8px minmax(0, 1fr) 128px; min-height: 36px; padding: 5px 2px; }
  .members.compact .member { grid-template-columns: 8px minmax(0, 1fr) 104px; min-height: 26px; padding: 3px 2px; }
  .members.dense .member { grid-template-columns: 8px minmax(0, 1fr) 84px; min-height: 24px; padding: 2px 2px; }
  .members.compact .member:first-child, .members.roomy .member:first-child { border-top: 0; }
  .members.dense .member:nth-child(-n + 2) { border-top: 0; }

  .pip { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); }
  .member.warn .pip { background: #ffc857; }
  .member.crit .pip { background: #ff5d50; }
  .member.off .pip { background: #596270; }

  .mname {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: #f2f4f6;
    font-size: 13px;
    font-weight: 650;
    letter-spacing: -0.005em;
  }
  .members.dense .mname, .members.compact .mname { font-size: 12.5px; }
  .member.inactive .mname { color: #7d8793; }

  .bars { display: grid; gap: 4px; min-width: 0; }
  .bars.one { grid-template-columns: minmax(0, 1fr) 30px; align-items: center; gap: 6px; }
  .line { display: grid; grid-template-columns: 17px minmax(0, 1fr) 28px; align-items: center; gap: 5px; }
  .lab { color: var(--accent2); font-size: 9.5px; font-style: normal; font-weight: 900; letter-spacing: 0.05em; }
  .lab.ar { color: #b9c5d3; }
  .track { position: relative; display: block; height: 6px; border-radius: 99px; background: rgba(255, 255, 255, 0.1); overflow: hidden; }
  .track.thin { height: 3px; }
  .fill { display: block; height: 100%; border-radius: inherit; transition: width 0.25s ease; }
  .fill.hp { background: var(--accent); }
  .member.warn .fill.hp { background: #ffc857; }
  .member.crit .fill.hp { background: #ff5d50; }
  .fill.ar { background: #b9c5d3; }
  /* compact rows: armour is a thin pale line under the health bar */
  .stack { display: grid; gap: 2px; min-width: 0; }
  .ar-track { display: block; height: 2px; border-radius: 99px; background: rgba(255, 255, 255, 0.07); overflow: hidden; }
  .ar-fill { display: block; height: 100%; background: #cfd8e3; }
  .pctv { color: #dfe5ec; font-size: 11px; font-style: normal; font-weight: 800; text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .pctv.dim { color: #8d97a3; font-weight: 700; }
  .member.inactive .pctv { color: #7d8793; font-size: 10px; }
</style>
