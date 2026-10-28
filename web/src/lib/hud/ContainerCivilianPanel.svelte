<script>
  import { containerCivilianInfo } from './containerCivilianStore.js';
  import { fade } from 'svelte/transition';
  import { onMount } from 'svelte';
  import { fetchNui } from '../api/nui.js';
  import './cwTheme.css';

  let wrapEl = null;
  let posX = null;
  let posY = null;
  let isMoveMode = false;
  let isDragging = false;
  let dragOffset = { x: 0, y: 0 };
  let isClosed = false;

  const money = (val) => {
    if (val == null || val === '') return '—';
    if (typeof val === 'string' && val.startsWith('$')) return val;
    const num = Number(val);
    if (isNaN(num)) return String(val);
    return '$' + num.toLocaleString('en-US');
  };

  function formatTime(seconds) {
    if (seconds == null) return '00:00';
    seconds = Math.max(0, Math.floor(Number(seconds) || 0));
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
  }

  onMount(() => {
    try {
      const savedClosed = localStorage.getItem('cw_civilian_closed');
      if (savedClosed === 'true') isClosed = true;

      const savedPos = localStorage.getItem('cw_civilian_pos');
      if (savedPos) {
        const parsed = JSON.parse(savedPos);
        if (parsed && typeof parsed.x === 'number' && typeof parsed.y === 'number') {
          posX = Math.max(8, Math.min(window.innerWidth - 415, parsed.x));
          posY = Math.max(8, Math.min(window.innerHeight - 250, parsed.y));
        }
      }
    } catch (e) {}

    const onMessage = (e) => {
      if (!e.data) return;
      if (e.data.action === 'cwCivilianInfo:toggle') {
        if (typeof e.data.forced === 'boolean') {
          isClosed = !e.data.forced;
        } else {
          isClosed = !isClosed;
        }
        try { localStorage.setItem('cw_civilian_closed', String(isClosed)); } catch (err) {}
      } else if (e.data.action === 'cwCivilianInfo:moveMode') {
        isClosed = false;
        enterMoveMode();
      }
    };
    window.addEventListener('message', onMessage);

    const onMouseMove = (e) => {
      if (!isDragging) return;
      const w = wrapEl ? wrapEl.offsetWidth : 410;
      const h = wrapEl ? wrapEl.offsetHeight : 220;
      let newX = e.clientX - dragOffset.x;
      let newY = e.clientY - dragOffset.y;
      newX = Math.max(8, Math.min(window.innerWidth - w - 8, newX));
      newY = Math.max(8, Math.min(window.innerHeight - h - 8, newY));
      posX = Math.round(newX);
      posY = Math.round(newY);
    };

    const onMouseUp = () => {
      if (isDragging) {
        isDragging = false;
      }
    };

    const onKeyDown = (e) => {
      if (e.key === 'Escape' && isMoveMode) {
        savePosition();
      }
    };

    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    window.addEventListener('keydown', onKeyDown);

    return () => {
      window.removeEventListener('message', onMessage);
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onMouseUp);
      window.removeEventListener('keydown', onKeyDown);
    };
  });

  function startDrag(e) {
    if (!isMoveMode) return;
    if (e.button !== 0) return;
    const target = e.target;
    if (target && (target.tagName === 'BUTTON' || target.closest('button'))) return;

    const rect = wrapEl ? wrapEl.getBoundingClientRect() : null;
    if (!rect) return;
    dragOffset = {
      x: e.clientX - rect.left,
      y: e.clientY - rect.top,
    };
    posX = Math.round(rect.left);
    posY = Math.round(rect.top);
    isDragging = true;
  }

  function enterMoveMode() {
    isClosed = false;
    isMoveMode = true;
    if (posX == null || posY == null) {
      if (wrapEl) {
        const rect = wrapEl.getBoundingClientRect();
        posX = Math.round(rect.left);
        posY = Math.round(rect.top);
      }
    }
    try { fetchNui('cwCivilianInfo:startMove', {}); } catch (e) {}
  }

  function savePosition() {
    if (posX != null && posY != null) {
      try {
        localStorage.setItem('cw_civilian_pos', JSON.stringify({ x: posX, y: posY }));
      } catch (e) {}
    }
    isMoveMode = false;
    isDragging = false;
    try { fetchNui('cwCivilianInfo:savePos', { x: posX, y: posY }); } catch (e) {}
  }

  function resetPosition() {
    posX = null;
    posY = null;
    try {
      localStorage.removeItem('cw_civilian_pos');
    } catch (e) {}
    isMoveMode = false;
    isDragging = false;
    try { fetchNui('cwCivilianInfo:savePos', {}); } catch (e) {}
  }

  function handleClose() {
    isClosed = true;
    if (isMoveMode) {
      isMoveMode = false;
      try { fetchNui('cwCivilianInfo:cancelMove', {}); } catch (e) {}
    }
    try { localStorage.setItem('cw_civilian_closed', 'true'); } catch (e) {}
    try { fetchNui('cwCivilianInfo:close', {}); } catch (e) {}
  }

  function handleReopen() {
    isClosed = false;
    try { localStorage.setItem('cw_civilian_closed', 'false'); } catch (e) {}
  }

  $: wrapStyle = (posX != null && posY != null)
    ? `left: ${posX}px; top: ${posY}px; right: auto;`
    : `top: 140px; left: 32px; right: auto;`;

  $: cleanHeader = ($containerCivilianInfo?.containerHeader || 'CONTAINER #1')
    .replace(/\s*·\s*/g, ' — ')
    .replace(/\s*-\s*/g, ' — ');

  $: cleanSubtitle = ($containerCivilianInfo?.containerSubtitle || 'Current Container').toUpperCase();

  $: isTextVal = !!($containerCivilianInfo?.timeText && isNaN(Number($containerCivilianInfo.timeText)));

  $: bidderDisplay = (() => {
    const raw = $containerCivilianInfo?.bidderName;
    if (!raw || raw === '' || raw.toLowerCase() === 'no bids yet' || raw.toLowerCase() === 'no bids') {
      return 'No Bids';
    }
    return raw;
  })();
</script>

{#if $containerCivilianInfo && $containerCivilianInfo.visible}
  {#if isClosed}
    <!-- Floating reopen pill on screen left edge -->
    <div
      class="cw-reopen-pill"
      on:click={handleReopen}
      transition:fade={{ duration: 150 }}
      title="Click to show Container War Info (or /cwinfo)"
    >
      <span class="pill-icon">📦</span>
      <span class="pill-text">CW INFO</span>
    </div>
  {:else}
    <div
      bind:this={wrapEl}
      class="cw-root"
      class:in-move-mode={isMoveMode}
      style={wrapStyle}
      transition:fade={{ duration: 150 }}
    >
      {#if isMoveMode}
        <div class="move-banner" on:mousedown={startDrag}>
          <div class="move-banner-title">
            <span class="move-icon">✥</span>
            <span>MOVE UI — DRAG TO POSITION</span>
          </div>
          <div class="move-banner-actions">
            <button class="move-action-btn reset" on:click|stopPropagation={resetPosition} type="button">RESET</button>
            <button class="move-action-btn save" on:click|stopPropagation={savePosition} type="button">SAVE</button>
          </div>
        </div>
      {/if}

      <div class="demo" on:mousedown={isMoveMode ? startDrag : null}>
        <!-- Main Container War UI -->
        <div class="container-ui cw-plate">
          <div class="cw-strip"></div>
          <div class="header">
            <div class="icon">CW</div>
            <div class="title" title={$containerCivilianInfo.title || 'CONTAINER WAR'}>
              {$containerCivilianInfo.title || 'CONTAINER WAR'}
            </div>
            <div
              class="status"
              class:tone-wait={$containerCivilianInfo.statusTone === 'wait'}
              class:tone-sold={$containerCivilianInfo.statusTone === 'sold'}
              class:tone-closed={$containerCivilianInfo.statusTone === 'closed'}
            >
              {$containerCivilianInfo.status || 'AUCTION ACTIVE'}
            </div>
            <div class="header-actions">
              <button
                class="move-toggle-btn"
                on:click|stopPropagation={enterMoveMode}
                title="Move UI position (or /cwmove)"
                type="button"
              >✥</button>
              <button
                class="close-btn"
                on:click|stopPropagation={handleClose}
                title="Close HUD (or /cwinfo)"
                type="button"
              >×</button>
            </div>
          </div>

          <div class="body">
            <div class="section-label">{cleanSubtitle}</div>
            <div class="container-name" title={cleanHeader}>{cleanHeader}</div>

            <div class="grid">
              <div class="stat">
                <div class="label">Current Bid</div>
                <div class="value current-bid">{money($containerCivilianInfo.currentBid)}</div>
              </div>
              <div class="stat">
                <div class="label">Next Bid</div>
                <div class="value next-bid">
                  {#if $containerCivilianInfo.nextBidText}
                    {$containerCivilianInfo.nextBidText}
                  {:else if $containerCivilianInfo.nextBid != null}
                    {money($containerCivilianInfo.nextBid)}
                  {:else}
                    —
                  {/if}
                </div>
              </div>
            </div>

            <div class="bidder">
              <div class="label" style="margin:0">{$containerCivilianInfo.bidderLabel || 'Current Bidder'}</div>
              <div
                class="bidder-name"
                class:dim={bidderDisplay === 'No Bids'}
                title={bidderDisplay}
              >
                {bidderDisplay}
              </div>
            </div>
          </div>

          <div class="footer" class:can-bid={$containerCivilianInfo.canBid}>
            {#if $containerCivilianInfo.canBid}
              <span class="cw-key">E</span>
              <span class="key-label">PRESS [E] TO PLACE BID</span>
            {:else}
              {$containerCivilianInfo.footer || 'Enter Auction Area To Bid'}
            {/if}
          </div>
        </div>

        <!-- Separate timer box, outside and immediately to the right -->
        <div class="timer cw-plate">
          <div class="cw-strip"></div>
          <div class="timer-label">{$containerCivilianInfo.timerLabel || 'Time Left'}</div>
          <div class="time" class:text-val={isTextVal}>
            {#if $containerCivilianInfo.timeText}
              {$containerCivilianInfo.timeText}
            {:else if $containerCivilianInfo.timeLeft != null}
              {formatTime($containerCivilianInfo.timeLeft)}
            {:else}
              00:00
            {/if}
          </div>
        </div>
      </div>
    </div>
  {/if}
{/if}

<style>
  .cw-root {
    position: fixed;
    z-index: 38;
    pointer-events: auto;
    user-select: none;
    font-family: var(--font-ui);
    color: var(--cw-text);
  }
  .cw-root.in-move-mode { cursor: move; }

  /* ── move mode ── */
  .move-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 7px 12px;
    margin-bottom: 6px;
    background: var(--cw-hull);
    border: 1px solid var(--cw-yellow);
    border-radius: 3px;
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.1em;
    color: var(--cw-text);
    cursor: move;
  }
  .move-banner-title { display: flex; align-items: center; gap: 7px; color: var(--cw-yellow); }
  .move-icon { font-size: 13px; }
  .move-banner-actions { display: flex; align-items: center; gap: 6px; }
  .move-action-btn {
    background: var(--cw-hull-2);
    border: 1px solid var(--cw-line);
    color: var(--cw-text);
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.1em;
    padding: 4px 10px;
    border-radius: 2px;
    cursor: pointer;
  }
  .move-action-btn:hover { border-color: var(--cw-text); }
  .move-action-btn.save { background: var(--cw-green); border-color: var(--cw-green); color: #0b140a; }
  .move-action-btn.save:hover { background: #6fe063; }
  .move-action-btn.reset { color: var(--cw-dim); }
  .move-action-btn.reset:hover { color: var(--cw-red); border-color: var(--cw-red); }

  /* main panel on the left, the clock in its own plate on the right */
  .demo { display: flex; align-items: flex-start; gap: 6px; }
  .in-move-mode .demo { outline: 2px dashed rgba(242, 194, 48, 0.6); outline-offset: 4px; border-radius: 3px; }

  .container-ui { width: 330px; overflow: hidden; box-shadow: 0 8px 22px rgba(0, 0, 0, 0.5); }

  .header { display: flex; align-items: center; gap: 10px; min-height: 44px; padding: 7px 12px 7px 14px; border-bottom: 1px solid var(--cw-line-soft); }
  .icon {
    flex: 0 0 auto;
    width: 30px;
    height: 24px;
    display: grid;
    place-items: center;
    border: 1px solid var(--cw-line);
    border-radius: 2px;
    background: var(--cw-hull-2);
    color: var(--cw-green);
    font-family: var(--cw-display);
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 0.06em;
  }
  /* the event's title: wraps, never cut off */
  .title {
    flex: 1 1 auto;
    min-width: 0;
    font-family: var(--cw-display);
    font-size: 15px;
    font-weight: 700;
    line-height: 1.15;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    white-space: normal;
    overflow-wrap: anywhere;
  }
  .status {
    flex: 0 0 auto;
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--cw-green);
    text-align: right;
  }
  .status.tone-wait { color: var(--cw-yellow); }
  .status.tone-sold { color: var(--cw-green); }
  .status.tone-closed { color: var(--cw-dim); }

  .header-actions { display: flex; align-items: center; gap: 2px; flex: 0 0 auto; }
  .move-toggle-btn, .close-btn {
    background: transparent;
    border: 0;
    color: var(--cw-dim);
    cursor: pointer;
    padding: 2px 5px;
    border-radius: 2px;
    line-height: 1;
  }
  .move-toggle-btn { font-size: 13px; }
  .close-btn { font-size: 19px; font-weight: 700; }
  .move-toggle-btn:hover { color: var(--cw-yellow); }
  .close-btn:hover { color: var(--cw-red); }

  .body { padding: 11px 14px 13px; }
  .section-label { margin-bottom: 4px; font-family: var(--cw-display); font-size: 11px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; color: var(--cw-dim); }
  /* the container's own name, in full */
  .container-name {
    font-family: var(--cw-display);
    font-size: 19px;
    font-weight: 700;
    line-height: 1.18;
    letter-spacing: 0.03em;
    white-space: normal;
    overflow-wrap: anywhere;
  }

  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 12px; }
  .stat { padding: 8px 11px 9px; border: 1px solid var(--cw-line-soft); border-radius: 2px; background: var(--cw-hull-2); }
  .label { margin-bottom: 3px; font-family: var(--cw-display); font-size: 11px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; color: var(--cw-dim); }
  .value { font-family: var(--cw-display); font-size: 21px; font-weight: 700; line-height: 1.1; font-variant-numeric: tabular-nums; }
  .current-bid { color: var(--cw-text); }
  .next-bid { color: var(--cw-yellow); }

  .bidder {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
    margin-top: 8px;
    padding: 9px 11px;
    border-left: 3px solid var(--cw-blue);
    background: var(--cw-hull-2);
  }
  .bidder-name {
    min-width: 0;
    font-family: var(--cw-display);
    font-size: 16px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    text-align: right;
    color: var(--cw-blue);
    white-space: normal;
    overflow-wrap: anywhere;
  }
  .bidder-name.dim { color: var(--cw-dim); }

  .footer {
    padding: 9px 14px;
    border-top: 1px solid var(--cw-line-soft);
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--cw-dim);
  }
  .footer.can-bid { display: flex; align-items: center; gap: 9px; color: var(--cw-text); background: var(--cw-hull-2); }
  .key-label { font-weight: 700; letter-spacing: 0.12em; }

  /* the clock: its own plate, directly to the right */
  .timer {
    width: 104px;
    min-height: 72px;
    padding: 0 8px 8px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-start;
    text-align: center;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.5);
  }
  .timer .cw-strip { align-self: stretch; margin: 0 -8px 8px; }
  .timer-label { font-family: var(--cw-display); font-size: 11px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; color: var(--cw-dim); }
  .time {
    margin-top: 3px;
    max-width: 100%;
    font-family: var(--cw-display);
    font-size: 28px;
    font-weight: 700;
    line-height: 1.05;
    letter-spacing: 0.03em;
    font-variant-numeric: tabular-nums;
    color: var(--cw-orange);
    text-align: center;
    overflow-wrap: anywhere;
  }
  .time.text-val { font-size: 15px; line-height: 1.15; letter-spacing: 0.06em; }

  /* reopen tab when the panel is hidden */
  .cw-reopen-pill {
    position: fixed;
    left: 12px;
    top: 50%;
    transform: translateY(-50%);
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 8px 13px;
    background: var(--cw-hull);
    border: 1px solid var(--cw-line);
    border-left: 4px solid var(--cw-yellow);
    border-radius: 3px;
    color: var(--cw-text);
    font-family: var(--cw-display);
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 0.12em;
    cursor: pointer;
    z-index: 38;
    pointer-events: auto;
  }
  .cw-reopen-pill:hover { border-color: var(--cw-yellow); }
  .pill-icon { font-size: 14px; }
  .pill-text { color: var(--cw-text); }
</style>
