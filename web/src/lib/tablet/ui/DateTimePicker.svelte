<script>
  // A theme-matching replacement for <input type="datetime-local"> — the
  // native picker is a browser/OS overlay that can't be restyled with CSS at
  // all (confirmed: it renders as a plain white Chromium calendar no matter
  // what the surrounding page's theme is), so this is a real custom
  // component instead of a styling patch. Same value contract as the native
  // input it replaces: a "YYYY-MM-DDTHH:mm" string, so callers don't need to
  // change how they read/write it.
  import { onMount, onDestroy, tick } from 'svelte';
  import Icon from './Icon.svelte';

  export let value = '';
  export let min = '';
  // hideTime: for a recurrence "which day" picker (monthly day-of-month,
  // yearly month+day) where there's no time-of-day to set — the Timing Mode
  // section elsewhere already owns that. maxDay: caps which day cells are
  // pickable (28 for "day of month", so it's guaranteed to exist every
  // month — same constraint the plain number input it replaces enforced).
  export let hideTime = false;
  export let maxDay = 31;

  let open = false;
  let root;

  // Hour/minute used to be plain <select> elements — Chromium renders a
  // <select>'s OPEN option list as a native OS-level overlay that ignores
  // this component's own container/z-index entirely, so it visually spilled
  // out past the picker's rounded card and over whatever page content was
  // underneath (confirmed live). These are fully custom dropdowns instead,
  // contained the same way the calendar grid already is.
  let hourOpen = false;
  let minuteOpen = false;
  let hourRoot;
  let minuteRoot;

  const DAY_LABELS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];
  const MONTH_LABELS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  // The underlying `value` stays 24-hour ("YYYY-MM-DDTHH:mm", same contract
  // as the native datetime-local input this replaces) — only the hour
  // dropdown/label are shown in 12-hour + AM/PM, converted at the display
  // layer via displayHour/period below and back via pickHour12/setPeriod.
  const HOURS_12 = Array.from({ length: 12 }, (_, i) => i + 1); // 1..12
  const MINUTES = Array.from({ length: 12 }, (_, i) => i * 5);

  function pad(n) { return String(n).padStart(2, '0'); }
  function parse(v) {
    if (!v) return null;
    const [datePart, timePart] = v.split('T');
    const [y, m, d] = (datePart || '').split('-').map(Number);
    const [hh, mm] = (timePart || '00:00').split(':').map(Number);
    if (!y || !m || !d) return null;
    return { y, m, d, hh: hh || 0, mm: mm || 0 };
  }
  function toValue(y, m, d, hh, mm) {
    return `${y}-${pad(m)}-${pad(d)}T${pad(hh)}:${pad(mm)}`;
  }
  function daysInMonth(y, m) {
    return new Date(y, m, 0).getDate();
  }

  const now = new Date();
  let viewY = now.getFullYear();
  let viewM = now.getMonth() + 1; // 1-12
  let hh = now.getHours();
  let mm = Math.round(now.getMinutes() / 5) * 5;

  $: minParsed = parse(min);

  $: {
    const p = parse(value);
    if (p) {
      viewY = p.y;
      viewM = p.m;
      hh = p.hh;
      mm = p.mm;
    } else if (minParsed && !value) {
      viewY = minParsed.y;
      viewM = minParsed.m;
      hh = minParsed.hh;
      mm = Math.round(minParsed.mm / 5) * 5;
    }
  }

  function isBeforeMin(y, m, d) {
    if (!minParsed) return false;
    if (y !== minParsed.y) return y < minParsed.y;
    if (m !== minParsed.m) return m < minParsed.m;
    return d < minParsed.d;
  }

  function prevMonth() {
    viewM -= 1;
    if (viewM < 1) { viewM = 12; viewY -= 1; }
  }
  function nextMonth() {
    viewM += 1;
    if (viewM > 12) { viewM = 1; viewY += 1; }
  }

  function pickDay(d) {
    if (isBeforeMin(viewY, viewM, d)) return;
    value = toValue(viewY, viewM, d, hh, mm);
  }
  function commitTime() {
    const p = parse(value) || { y: viewY, m: viewM, d: now.getDate() };
    value = toValue(p.y, p.m, p.d, hh, mm);
  }
  $: displayHour = (hh % 12) || 12;
  $: period = hh >= 12 ? 'PM' : 'AM';

  function pickHour12(h12) {
    hh = (h12 % 12) + (period === 'PM' ? 12 : 0);
    hourOpen = false;
    commitTime();
  }
  function setPeriod(p) {
    if (p === period) return;
    hh = p === 'PM' ? hh + 12 : hh - 12;
    commitTime();
  }
  function pickMinute(m) {
    mm = m;
    minuteOpen = false;
    commitTime();
  }
  function clear() {
    value = '';
    open = false;
  }
  function today() {
    if (minParsed) {
      viewY = minParsed.y;
      viewM = minParsed.m;
      hh = minParsed.hh;
      mm = Math.round(minParsed.mm / 5) * 5;
      value = toValue(viewY, viewM, minParsed.d, hh, mm);
    } else {
      const t = new Date();
      viewY = t.getFullYear();
      viewM = t.getMonth() + 1;
      hh = t.getHours();
      mm = Math.round(t.getMinutes() / 5) * 5;
      value = toValue(viewY, viewM, t.getDate(), hh, mm);
    }
  }

  $: grid = (() => {
    const firstWeekday = new Date(viewY, viewM - 1, 1).getDay();
    const total = daysInMonth(viewY, viewM);
    const prevTotal = daysInMonth(viewM === 1 ? viewY - 1 : viewY, viewM === 1 ? 12 : viewM - 1);
    const cells = [];
    for (let i = firstWeekday - 1; i >= 0; i--) cells.push({ day: prevTotal - i, outside: true, disabled: true });
    const selected = parse(value);
    for (let d = 1; d <= total; d++) {
      cells.push({
        day: d,
        outside: false,
        disabled: isBeforeMin(viewY, viewM, d) || d > maxDay,
        selected: !!selected && selected.y === viewY && selected.m === viewM && selected.d === d,
        isToday: minParsed
          ? viewY === minParsed.y && viewM === minParsed.m && d === minParsed.d
          : viewY === now.getFullYear() && viewM === now.getMonth() + 1 && d === now.getDate(),
      });
    }
    let next = 1;
    while (cells.length % 7 !== 0) cells.push({ day: next++, outside: true, disabled: true });
    return cells;
  })();

  function displayLabel(v) {
    const p = parse(v);
    if (!p) return hideTime ? 'Pick a day...' : 'Pick a date/time...';
    if (hideTime) return `${MONTH_LABELS[p.m - 1]} ${p.d}`;
    const h12 = (p.hh % 12) || 12;
    const per = p.hh >= 12 ? 'PM' : 'AM';
    return `${p.y}-${pad(p.m)}-${pad(p.d)}  ${pad(h12)}:${pad(p.mm)} ${per}`;
  }

  function handleOutsideClick(e) {
    // the panel lives on <body> (see portal below), so it is no longer inside `root`
    if (open && root && !root.contains(e.target) && !(panelEl && panelEl.contains(e.target))) open = false;
    if (hourOpen && hourRoot && !hourRoot.contains(e.target)) hourOpen = false;
    if (minuteOpen && minuteRoot && !minuteRoot.contains(e.target)) minuteOpen = false;
  }

  // The panel is moved to <body> and positioned against the viewport. Inside the page it was painted UNDER the
  // cards that come after it (every card is its own stacking context), so headings showed through the calendar
  // and the lower part got clipped by the scrolling panel. On <body> nothing can sit above or cut it off.
  let panelEl;
  let panelTop = 0;
  let panelLeft = 0;
  let placed = false;
  function portal(node) {
    document.body.appendChild(node);
    return { destroy() { if (node.parentNode) node.parentNode.removeChild(node); } };
  }
  // below the field when it fits, otherwise above it; always kept inside the window
  function reposition() {
    if (!open || !root || !panelEl) return;
    const r = root.getBoundingClientRect();
    const w = panelEl.offsetWidth;
    const h = panelEl.offsetHeight;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let top = r.bottom + 6;
    if (top + h > vh - 8 && r.top - h - 6 >= 8) top = r.top - h - 6;
    panelTop = Math.max(8, Math.min(top, vh - h - 8));
    panelLeft = Math.max(8, Math.min(r.left, vw - w - 8));
    placed = true;
  }
  onMount(() => {
    document.addEventListener('mousedown', handleOutsideClick);
    window.addEventListener('resize', reposition);
    window.addEventListener('scroll', reposition, true);   // any scrolling tab/panel moves the field
  });
  onDestroy(() => {
    document.removeEventListener('mousedown', handleOutsideClick);
    window.removeEventListener('resize', reposition);
    window.removeEventListener('scroll', reposition, true);
  });

  async function toggleOpen() {
    open = !open;
    placed = false;
    if (open) {
      await tick();
      reposition();
    }
  }
  // the time column appears/disappears with hideTime - measure again whenever the panel's contents change
  $: if (open && panelEl) { hideTime; viewM; viewY; tick().then(reposition); }
</script>

<div class="dtp" bind:this={root}>
  <button type="button" class="dtp-field" class:placeholder={!value} on:click={toggleOpen}>
    <Icon name="history" size={13} />
    <span>{displayLabel(value)}</span>
  </button>

  {#if open}
    <div class="dtp-panel" bind:this={panelEl} use:portal style="top:{panelTop}px;left:{panelLeft}px;visibility:{placed ? 'visible' : 'hidden'}">
      <div class="dtp-cal">
        <div class="dtp-cal-header">
          <button type="button" class="dtp-nav" on:click={prevMonth}><Icon name="chevronDown" size={12} /></button>
          <span>{MONTH_LABELS[viewM - 1]}{hideTime ? '' : ' ' + viewY}</span>
          <button type="button" class="dtp-nav next" on:click={nextMonth}><Icon name="chevronUp" size={12} /></button>
        </div>
        <div class="dtp-weekdays">
          {#each DAY_LABELS as w}<span>{w}</span>{/each}
        </div>
        <div class="dtp-days">
          {#each grid as c}
            <button
              type="button"
              class="dtp-day"
              class:outside={c.outside}
              class:selected={c.selected}
              class:today={c.isToday}
              disabled={c.disabled}
              on:click={() => pickDay(c.day)}
            >{c.day}</button>
          {/each}
        </div>
        <div class="dtp-footer">
          <button type="button" class="dtp-link" on:click={clear}>Clear</button>
          <button type="button" class="dtp-link" on:click={today}>Today</button>
        </div>
      </div>
      {#if !hideTime}
        <div class="dtp-time">
          <label>Time</label>
          <div class="dtp-time-row">
            <div class="dtp-dropdown" bind:this={hourRoot}>
              <button type="button" class="dtp-dropdown-btn" on:click={() => { hourOpen = !hourOpen; minuteOpen = false; }}>{pad(displayHour)}</button>
              {#if hourOpen}
                <div class="dtp-dropdown-list">
                  {#each HOURS_12 as h}
                    <button type="button" class="dtp-dropdown-item" class:selected={h === displayHour} on:click={() => pickHour12(h)}>{pad(h)}</button>
                  {/each}
                </div>
              {/if}
            </div>
            <span>:</span>
            <div class="dtp-dropdown" bind:this={minuteRoot}>
              <button type="button" class="dtp-dropdown-btn" on:click={() => { minuteOpen = !minuteOpen; hourOpen = false; }}>{pad(mm)}</button>
              {#if minuteOpen}
                <div class="dtp-dropdown-list">
                  {#each MINUTES as m}
                    <button type="button" class="dtp-dropdown-item" class:selected={m === mm} on:click={() => pickMinute(m)}>{pad(m)}</button>
                  {/each}
                </div>
              {/if}
            </div>
          </div>
          <div class="dtp-period">
            <button type="button" class="dtp-period-btn" class:selected={period === 'AM'} on:click={() => setPeriod('AM')}>AM</button>
            <button type="button" class="dtp-period-btn" class:selected={period === 'PM'} on:click={() => setPeriod('PM')}>PM</button>
          </div>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .dtp {
    position: relative;
    display: inline-block;
  }
  .dtp-field {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 9px 13px;
    font-size: var(--fs-body);
    font-family: var(--font-mono);
    cursor: pointer;
  }
  .dtp-field:hover {
    border-color: var(--accent-primary);
  }
  .dtp-field.placeholder span {
    color: var(--tablet-text-faint);
    font-family: var(--font-ui);
  }

  /* A pop-up must be SOLID: the tablet's panel tokens are 50-60 % transparent, which let the page behind show
     through the calendar. These are fixed opaque colours for the pop-up and its inner controls. */
  .dtp-panel {
    --dtp-bg: var(--c-panel, #161c27);
    --dtp-inset: var(--c-base, #0d121a);
    --dtp-hover: var(--c-hover, #212b3b);
    --dtp-line: var(--c-line, #2c394d);
    position: fixed;
    z-index: 100000;
    display: flex;
    align-items: stretch;
    gap: 16px;
    background: var(--dtp-bg);
    border: 1px solid var(--dtp-line);
    border-radius: var(--radius-md);
    padding: 16px;
    box-shadow: 0 10px 28px rgba(0, 0, 0, 0.6);
  }

  /* ── calendar ── */
  .dtp-cal {
    width: 252px;
    display: flex;
    flex-direction: column;
  }
  .dtp-cal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
  }
  .dtp-nav {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    background: var(--dtp-inset);
    border: 1px solid var(--dtp-line);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    cursor: pointer;
  }
  .dtp-nav :global(svg) {
    transform: rotate(90deg);   /* the icon set only has up/down chevrons: turned to point left / right */
  }
  .dtp-nav.next :global(svg) {
    transform: rotate(-90deg);
  }
  .dtp-nav:hover {
    border-color: var(--accent-primary);
    color: var(--text-main);
  }
  .dtp-weekdays {
    display: grid;
    grid-template-columns: repeat(7, 1fr);
    margin-bottom: 6px;
    padding-bottom: 6px;
    border-bottom: 1px solid var(--dtp-line);
  }
  .dtp-weekdays span {
    text-align: center;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--tablet-text-faint);
  }
  .dtp-days {
    display: grid;
    grid-template-columns: repeat(7, 1fr);
    gap: 3px;
  }
  .dtp-day {
    height: 32px;
    padding: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    color: var(--text-main);
    font-size: var(--fs-small);
    font-family: var(--font-mono);
    cursor: pointer;
  }
  .dtp-day:hover:not(:disabled) {
    background: var(--dtp-hover);
  }
  .dtp-day.outside {
    visibility: hidden;   /* the greyed days of the neighbouring months only added noise */
  }
  .dtp-day.today {
    border-color: var(--accent-primary);
  }
  .dtp-day.selected {
    background: var(--accent-primary);
    border-color: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    font-weight: 700;
  }
  .dtp-day:disabled {
    color: var(--tablet-text-faint);
    opacity: 0.35;
    cursor: not-allowed;
  }
  .dtp-footer {
    display: flex;
    justify-content: space-between;
    margin-top: 12px;
    padding-top: 12px;
    border-top: 1px solid var(--dtp-line);
  }
  .dtp-link {
    background: transparent;
    border: none;
    padding: 2px 4px;
    color: var(--accent-primary-light);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
  }
  .dtp-link:hover {
    color: var(--text-main);
  }

  /* ── time column ── */
  .dtp-time {
    width: 112px;
    border-left: 1px solid var(--dtp-line);
    padding-left: 16px;
    display: flex;
    flex-direction: column;
  }
  .dtp-time label {
    display: block;
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--tablet-text-faint);
    margin: 4px 0 12px;
  }
  .dtp-time-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 4px;
  }
  .dtp-time-row > span {
    color: var(--text-dim);
    font-weight: 700;
  }
  .dtp-dropdown {
    position: relative;
  }
  .dtp-dropdown-btn {
    background: var(--dtp-inset);
    border: 1px solid var(--dtp-line);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 7px 0;
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    width: 46px;
    text-align: center;
    cursor: pointer;
  }
  .dtp-dropdown-btn:hover {
    border-color: var(--accent-primary);
  }
  .dtp-dropdown-list {
    position: absolute;
    z-index: 2;
    top: calc(100% + 4px);
    left: 0;
    width: 46px;
    max-height: 168px;
    overflow-y: auto;
    background: var(--dtp-inset);
    border: 1px solid var(--dtp-line);
    border-radius: var(--radius-sm);
    box-shadow: 0 8px 20px rgba(0, 0, 0, 0.55);
  }
  .dtp-dropdown-item {
    display: block;
    width: 100%;
    background: transparent;
    border: none;
    color: var(--text-main);
    padding: 7px 4px;
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    text-align: center;
    cursor: pointer;
  }
  .dtp-dropdown-item:hover {
    background: var(--dtp-hover);
  }
  .dtp-dropdown-item.selected {
    background: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    font-weight: 700;
  }
  .dtp-period {
    display: flex;
    margin-top: 12px;
    border: 1px solid var(--dtp-line);
    border-radius: var(--radius-sm);
    overflow: hidden;
  }
  .dtp-period-btn {
    flex: 1;
    background: var(--dtp-inset);
    border: none;
    color: var(--text-dim);
    padding: 7px 0;
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    font-weight: 600;
    cursor: pointer;
  }
  .dtp-period-btn + .dtp-period-btn {
    border-left: 1px solid var(--dtp-line);
  }
  .dtp-period-btn:hover:not(.selected) {
    background: var(--dtp-hover);
  }
  .dtp-period-btn.selected {
    background: var(--accent-primary);
    color: var(--on-accent, #ffffff);
    text-shadow: none;
    font-weight: 700;
  }
</style>
