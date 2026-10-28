<script>
  import Icon from './Icon.svelte';

  // tabs: [{ id, label, icon?, count? }] — `active` is the selected tab id.
  export let tabs = [];
  export let active = '';
</script>

<div class="subtabs" role="tablist">
  {#each tabs as t (t.id)}
    <button
      type="button"
      role="tab"
      aria-selected={active === t.id}
      class="subtab"
      class:active={active === t.id}
      on:click={() => (active = t.id)}
    >
      {#if t.icon}<Icon name={t.icon} size={15} />{/if}
      <span>{t.label}</span>
      {#if t.count != null}<span class="subtab-count">{t.count}</span>{/if}
    </button>
  {/each}
</div>

<style>
  /* Segmented sub-tab bar: one ruled strip, the open tab is raised with a
     blue underline. Flat — no gradients, no glow. */
  .subtabs {
    display: flex;
    gap: 0;
    margin-bottom: 16px;
    border: 1px solid var(--c-line);
    border-radius: var(--r-panel);
    background: var(--c-panel);
    overflow: hidden;
  }
  .subtab {
    position: relative;
    flex: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    min-height: 52px;
    padding: 0 24px;
    background: transparent;
    border: 0;
    border-left: 1px solid var(--c-line);
    border-radius: 0;
    color: var(--c-text-2);
    font-family: var(--font-ui);
    font-size: var(--fs-emph);
    font-weight: 600;
    white-space: nowrap;
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }
  .subtab:first-child {
    border-left: 0;
  }
  .subtab :global(svg) {
    width: 20px;
    height: 20px;
    color: var(--c-text-3);
    transition: color 0.15s ease;
  }
  .subtab:hover {
    background: var(--c-raised);
    color: var(--c-text);
  }
  .subtab:hover :global(svg) {
    color: var(--c-text-2);
  }
  .subtab.active {
    background: var(--c-raised);
    color: var(--c-text);
    font-weight: 700;
  }
  .subtab.active :global(svg) {
    color: var(--c-action);
  }
  .subtab.active::after {
    content: '';
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 3px;
    background: var(--c-action);
    color: var(--on-accent, inherit);
}
  .subtab-count {
    min-width: 20px;
    padding: 0 6px;
    border-radius: var(--r-xs);
    background: var(--c-base);
    border: 1px solid var(--c-line);
    color: var(--c-text-2);
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    line-height: 18px;
    text-align: center;
  }
  .subtab.active .subtab-count {
    border-color: rgba(var(--accent-primary-rgb), 0.5);
    color: var(--c-text);
  }
</style>
