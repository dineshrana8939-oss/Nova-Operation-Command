<script>
  // The admin tablet's floating top navigation: one tab per GROUP (Events, Tournaments, Territory ...) in a floating bar, and
  // under it the pages of the open group as chips. It replaces the long scrolling side rail, so the menu never scrolls and the
  // content gets the whole width. A group with a single page (Dashboard, Help) opens that page straight away. Coming back to a
  // group lands on the page you last used in it.
  import { createEventDispatcher } from 'svelte';
  import Icon from './Icon.svelte';

  export let groups = [];      // visible groups: [{ title, short, icon, color, items: [{ id, label, icon }] }]
  export let current = '';     // the open view id
  export let sub = null;       // the open sub page of that view (an item may name one)
  export let badges = {};      // { pageId: number } small counters on a page chip
  export let dots = {};        // { pageId: true } a small dot: something new on that page since it was last opened

  const dispatch = createEventDispatcher();
  const lastIn = {};           // group title -> the item last opened in it

  // an item opens a view (its own id, or 'view') and maybe one sub page of it.
  // Reactive ($:) on purpose: a plain const is never re-evaluated by the template when only `sub` changes, so the chips
  // (Announcements, World Peds) kept the highlight of the page that was open before.
  $: isOn = (i) => (i.view || i.id) === current && (!i.sub || i.sub === sub);
  $: active = groups.find((g) => g.items.some(isOn)) || groups.find((g) => g.items.some((i) => (i.view || i.id) === current)) || groups[0] || null;
  $: onItem = active ? active.items.find(isOn) : null;
  $: if (active && onItem) lastIn[active.title] = onItem.id;

  function pick(g) {
    if (active && g.title === active.title) return;
    const back = g.items.find((i) => i.id === lastIn[g.title]);
    dispatch('select', back || g.items[0]);
  }
  const groupDot = (g) => g.items.some((i) => dots[i.id]);
  const groupBadge = (g) => g.items.reduce((n, i) => n + (Number(badges[i.id]) || 0), 0);
</script>

<header class="topnav" aria-label="Operations Hub menu">
  <div class="dock" role="tablist">
    {#each groups as g (g.title)}
      {@const isActive = active && g.title === active.title}
      {@const n = groupBadge(g)}
      <button type="button" role="tab" aria-selected={isActive} class="gtab" class:on={isActive} style="--g: {g.color}" on:click={() => pick(g)} title={g.title}>
        <Icon name={g.icon} size={15} />
        <span>{g.short || g.title}</span>
        {#if n > 0}<em class="badge">{n}</em>{/if}
        {#if !isActive && groupDot(g)}<i class="new-dot" title="Something new" aria-label="Something new"></i>{/if}
      </button>
    {/each}
  </div>

  <!-- always drawn, even for a group with one page: the row appearing and vanishing moved the whole page up and down on every switch -->
  {#if active && active.items.length > 0}
    <nav class="pages" style="--g: {active.color}" aria-label={active.title}>
      {#each active.items as item (item.id)}
        <button type="button" class="chip" class:on={isOn(item)} on:click={() => dispatch('select', item)}>
          <Icon name={item.icon} size={14} />
          <span>{item.label}</span>
          {#if badges[item.id] > 0}<em class="badge">{badges[item.id]}</em>{/if}
          {#if dots[item.id]}<i class="new-dot" title="Something new" aria-label="Something new"></i>{/if}
        </button>
      {/each}
    </nav>
  {/if}
</header>

<style>
  .topnav { flex: none; display: flex; flex-direction: column; gap: 8px; padding: 12px 22px 0; }

  /* the floating bar: a rounded slab that sits above the page, flat colour, a hairline edge */
  .dock {
    display: flex; align-items: center; gap: 4px; padding: 5px;
    overflow-x: auto; scrollbar-width: none;   /* never clips a tab on a narrow screen: it scrolls instead */
    background: var(--glass-bar, rgba(var(--ltc-14-19-27, 14, 19, 27), 0.92));
    border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.26));
    border-radius: 14px;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.42);
  }
  .dock::-webkit-scrollbar { display: none; }
  /* the side padding follows the screen width, so all ten group tabs fit side by side at 1366-1920 px */
  .gtab {
    flex: none; display: inline-flex; align-items: center; gap: 9px; height: 46px; padding: 0 clamp(10px, 1.05vw, 22px);
    border: 0; border-radius: 12px; background: transparent; cursor: pointer;
    color: var(--c-text-2, #aeb5bd); font-family: var(--font-ui); font-size: var(--fs-emph); font-weight: 600; white-space: nowrap;
    transition: background 0.14s ease, color 0.14s ease;
  }
  .gtab :global(svg) { color: color-mix(in srgb, var(--g) 100%, #fff 0%); flex: none; width: 19px; height: 19px; }
  .gtab:hover { background: color-mix(in srgb, var(--g) 14%, transparent); color: var(--c-text, #fff); }
  /* the open group: a solid tab in the group's colour with a dark label */
  .gtab.on { background: var(--g); color: #0b0f16; }
  .gtab.on :global(svg) { color: #0b0f16; }

  /* the pages of the open group */
  .pages { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 2px; }
  .chip {
    display: inline-flex; align-items: center; gap: 10px; height: 46px; padding: 0 22px;
    border: 1px solid color-mix(in srgb, var(--g) 35%, var(--tablet-border, rgba(110, 140, 180, 0.3))); border-radius: 12px; background: var(--glass-bar, rgba(var(--ltc-14-19-27, 14, 19, 27), 0.85));
    color: var(--c-text, #e3e6e9); font-family: var(--font-ui); font-size: var(--fs-emph); font-weight: 600; white-space: nowrap; cursor: pointer;
    transition: background 0.14s ease, border-color 0.14s ease, color 0.14s ease;
  }
  .chip :global(svg) { color: var(--g); flex: none; width: 19px; height: 19px; }
  .chip:hover { border-color: var(--g); background: color-mix(in srgb, var(--g) 12%, var(--glass-bar, transparent)); }
  /* the open page: a solid chip in the group's colour, like the open group tab above it */
  .chip.on { background: var(--g); border-color: var(--g); color: #0b0f16; font-weight: 700; }
  .chip.on :global(svg) { color: #0b0f16; }

  .badge { font-style: normal; font-size: var(--fs-meta); font-weight: 700; min-width: 18px; height: 18px; padding: 0 5px; display: inline-grid; place-items: center; border-radius: 9px; background: var(--c-action, #4f94e6); color: #fff; }
  .gtab.on .badge { background: #0b0f16; color: #fff; }

  @media (max-width: 1450px) {
    .gtab { font-size: var(--fs-body); gap: 7px; }
    .gtab :global(svg) { width: 17px; height: 17px; }
  }
  @media (max-width: 1400px) {
    .gtab { padding: 0 9px; gap: 6px; }
  }
  @media (max-width: 1150px) {
    .topnav { padding: 10px 16px 0; }
    .gtab { padding: 0 11px; }
  }
</style>
