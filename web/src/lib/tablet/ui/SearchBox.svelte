<script>
  import Icon from './Icon.svelte';

  export let value = '';
  export let placeholder = 'Search...';
  export let width = 280;
</script>

<div class="tb-search" style="min-width:{width}px">
  <Icon name="search" size={13} />
  <input type="text" {placeholder} bind:value />
  {#if value}
    <button type="button" class="tb-clear" on:click={() => (value = '')} aria-label="Clear search">
      <Icon name="close" size={12} />
    </button>
  {/if}
</div>

<style>
  .tb-search {
    display: flex;
    align-items: center;
    gap: 10px;
    height: 36px;
    padding: 0 12px;
    background: var(--es-inset, #181b1f);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-dim);
  }
  .tb-search:focus-within { border-color: var(--accent-primary); }
  input {
    flex: 1;
    min-width: 0;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-main, #fff);
    font-size: var(--fs-body);
  }
  input::placeholder { color: var(--text-placeholder); opacity: 1; }
  .tb-clear {
    display: flex;
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
  }
  .tb-clear:hover { color: var(--lt-ffffff, #fff); }
</style>
