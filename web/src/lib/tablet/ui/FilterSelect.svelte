<script>
  // A dark, tablet-styled dropdown for filter bars (the browser's own <select> popup is white and tiny inside the
  // game). Same use as a select:   <FilterSelect bind:value options={[{ value, label }]} title="…" on:change />
  import { createEventDispatcher, onDestroy } from 'svelte';
  import Icon from './Icon.svelte';

  export let value;
  export let options = [];
  export let title = '';
  export let minWidth = 150;
  export let up = false;      // open upwards (near the bottom of a panel)

  const dispatch = createEventDispatcher();
  let open = false;
  let root;

  $: current = options.find((o) => o.value === value) || options[0] || { label: '' };

  function pick(o) {
    value = o.value;
    open = false;
    dispatch('change', o.value);
  }

  function onWindowClick(e) {
    if (open && root && !root.contains(e.target)) open = false;
  }
  function onKey(e) {
    if (e.key === 'Escape') open = false;
  }

  if (typeof window !== 'undefined') window.addEventListener('mousedown', onWindowClick, true);
  onDestroy(() => { if (typeof window !== 'undefined') window.removeEventListener('mousedown', onWindowClick, true); });
</script>

<div class="fs" role="presentation" bind:this={root} style="min-width: {minWidth}px" on:keydown={onKey}>
  <button type="button" class="fs-btn" class:open aria-haspopup="listbox" aria-expanded={open} {title} on:click={() => (open = !open)}>
    <span class="fs-label">{current.label}</span>
    <Icon name="chevronDown" size={15} />
  </button>
  {#if open}
    <ul class="fs-menu" class:up role="listbox">
      {#each options as o (o.value)}
        <li role="option" aria-selected={o.value === value}>
          <button type="button" class="fs-opt" class:sel={o.value === value} on:click={() => pick(o)}>
            <span>{o.label}</span>
            {#if o.value === value}<Icon name="check" size={14} />{/if}
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .fs { position: relative; display: inline-block; }
  .fs-btn {
    width: 100%;
    height: 42px;
    display: inline-flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 0 14px;
    background: var(--es-raised, #1c1f24);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-eceef0, #eceef0);
    font-family: var(--font-ui);
    font-size: var(--fs-body);
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
  }
  .fs-btn:hover { background: var(--es-card-hover, #22262c); border-color: var(--es-line-strong, #3a3d52); }
  .fs-btn.open { border-color: var(--accent-primary, #4f94e6); background: var(--es-card-hover, #22262c); }
  .fs-btn :global(svg) { flex: none; color: #8d949c; transition: transform 0.15s ease; }
  .fs-btn.open :global(svg) { transform: rotate(180deg); color: var(--accent-primary, #4f94e6); }
  .fs-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .fs-menu {
    position: absolute;
    z-index: 60;
    top: calc(100% + 6px);
    left: 0;
    min-width: 100%;
    max-height: 280px;
    overflow-y: auto;
    margin: 0;
    padding: 6px;
    list-style: none;
    background: var(--es-solid, #181b1f);
    border: 1px solid #363b43;
    border-radius: var(--r-panel);
    box-shadow: none;
  }
  .fs-menu.up { top: auto; bottom: calc(100% + 6px); }
  .fs-opt {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    padding: 10px 12px;
    background: transparent;
    border: none;
    border-radius: var(--r-ctl);
    color: var(--lt-c9ced4, #c9ced4);
    font-family: var(--font-ui);
    font-size: var(--fs-body);
    font-weight: 500;
    white-space: nowrap;
    text-align: left;
    cursor: pointer;
  }
  .fs-opt:hover { background: var(--lt-272b31, #272b31); color: var(--lt-ffffff, #fff); }
  .fs-opt.sel { color: var(--on-accent); font-weight: 700; background: var(--c-action); }
</style>
