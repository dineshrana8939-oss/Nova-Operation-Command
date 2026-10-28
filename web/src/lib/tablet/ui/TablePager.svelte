<script>
  // Footer for a paged table. The parent slices its own rows:
  //   rows.slice((page - 1) * pageSize, page * pageSize)
  // Page resets to 1 when pageSize changes or the total shrinks below the page.
  export let page = 1;
  export let pageSize = 15;
  export let total = 0;
  export let noun = 'rows';
  export let sizes = [10, 15, 25, 50];
  // top: the pager sits ABOVE its table (rounded on top, border underneath) so page switching never needs a scroll to the bottom
  export let top = true;
  // flush: sits INSIDE a card that already has its own border: no box of its own, only a hairline under it
  export let flush = false;

  $: totalPages = Math.max(1, Math.ceil(total / pageSize));
  $: if (page > totalPages) page = totalPages;
  $: from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  $: to = Math.min(page * pageSize, total);

  function changeSize() { page = 1; }
</script>

<div class="tp" class:top class:flush>
  <span class="tp-text">
    Showing <strong>{from}–{to}</strong> of <strong>{total}</strong> {noun}
  </span>
  <div class="tp-right">
    <label class="tp-size">
      <span>Rows</span>
      <select bind:value={pageSize} on:change={changeSize}>
        {#each sizes as n}<option value={n}>{n}</option>{/each}
      </select>
    </label>
    <div class="tp-btns">
      <button type="button" class="tp-btn" disabled={page <= 1} on:click={() => (page = 1)} aria-label="First page">«</button>
      <button type="button" class="tp-btn" disabled={page <= 1} on:click={() => (page -= 1)} aria-label="Previous page">‹</button>
      <span class="tp-current">{page} / {totalPages}</span>
      <button type="button" class="tp-btn" disabled={page >= totalPages} on:click={() => (page += 1)} aria-label="Next page">›</button>
      <button type="button" class="tp-btn" disabled={page >= totalPages} on:click={() => (page = totalPages)} aria-label="Last page">»</button>
    </div>
  </div>
</div>

<style>
  .tp {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
    padding: 10px 16px;
    background: var(--c-base, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-top: none;
    border-radius: 0 0 var(--r-panel) var(--r-panel);
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .tp.top { border: 1px solid var(--tablet-border, #2a2e35); border-bottom: none; border-radius: var(--r-panel) var(--r-panel) 0 0; }
  .tp.flush { background: transparent; border: 0; border-bottom: 1px solid var(--tablet-border, #2a2e35); border-radius: 0; }
  .tp-text strong { color: var(--lt-ffffff, #fff); }
  .tp-right { display: flex; align-items: center; gap: 16px; }
  .tp-size { display: flex; align-items: center; gap: 8px; font-weight: 700; }
  .tp-size select {
    height: 30px;
    padding: 0 8px;
    background: var(--c-panel, #181b1f);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-small);
    cursor: pointer;
    outline: none;
  }
  .tp-btns { display: flex; align-items: center; gap: 6px; }
  .tp-btn {
    min-width: 30px;
    height: 30px;
    padding: 0 8px;
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #fff);
    font-size: var(--fs-emph);
    line-height: 1;
    cursor: pointer;
  }
  .tp-btn:hover:not(:disabled) { background: var(--c-hover, #272b31); border-color: var(--tablet-border-strong, #363b43); }
  .tp-btn:disabled { opacity: 0.35; cursor: not-allowed; }
  .tp-current { min-width: 56px; text-align: center; font-weight: 700; color: var(--lt-ffffff, #fff); }
</style>
