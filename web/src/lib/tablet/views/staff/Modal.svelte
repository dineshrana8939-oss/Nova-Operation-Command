<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../../ui/Icon.svelte';

  export let title = '';
  export let sub = '';
  export let icon = 'shield';
  export let width = 560;
  export let busy = false;

  const dispatch = createEventDispatcher();
  let downOnBackdrop = false;
  const close = () => { if (!busy) dispatch('close'); };
</script>

<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
<div class="sm-backdrop" on:mousedown|self={() => (downOnBackdrop = true)} on:click|self={() => { if (downOnBackdrop) close(); downOnBackdrop = false; }}>
  <div class="sm-dialog" style="width: {width}px" role="dialog" aria-label={title}>
    <div class="sm-head">
      <div class="sm-heading">
        <div class="sm-title"><Icon name={icon} size={16} /> {title}</div>
        {#if sub}<div class="sm-sub">{sub}</div>{/if}
      </div>
      <button class="icon-btn" type="button" on:click={close} title="Close" disabled={busy}><Icon name="close" size={14} /></button>
    </div>
    <div class="sm-body"><slot /></div>
    {#if $$slots.footer}<div class="sm-foot"><slot name="footer" /></div>{/if}
  </div>
</div>

<style>
  .sm-backdrop {
    position: fixed; inset: 0; z-index: 4000;
    display: flex; align-items: center; justify-content: center;
    background: rgba(0, 0, 0, 0.66);
  }
  .sm-dialog {
    max-width: 94vw; max-height: 92vh;
    display: flex; flex-direction: column;
    background: var(--c-panel); border: 1px solid var(--tablet-border-strong); border-radius: var(--r-panel);
    box-shadow: var(--shadow-overlay);
  }
  .sm-head {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    padding: 14px 18px; border-bottom: 1px solid var(--c-line); background: var(--c-base);
    border-radius: var(--r-panel) var(--r-panel) 0 0;
  }
  .sm-title { display: flex; align-items: center; gap: 8px; font-size: var(--fs-emph); font-weight: 700; color: var(--text-main); }
  .sm-title :global(svg) { color: var(--accent-primary); }
  .sm-sub { margin-top: 2px; font-size: var(--fs-meta); color: var(--text-muted); }
  .sm-body { padding: 16px 18px; min-height: 0; }
  .sm-foot {
    display: flex; justify-content: flex-end; align-items: center; gap: 10px;
    padding: 12px 18px; border-top: 1px solid var(--c-line); background: var(--c-base);
    border-radius: 0 0 var(--r-panel) var(--r-panel);
  }
</style>
