<script>
  // Empty knockout bracket shown whenever there is no drawn tournament to
  // display — before one is created, or while it is still waiting for its
  // draw — so the Tournament tab always has a tree on screen instead of
  // nothing. Purely a skeleton: every slot reads "TBD".
  export let qualifiers = 8; // teams entering the knockout
  export let title = 'Tournament Tree';
  export let message = '';

  $: size = (() => { let s = 2; while (s < Math.max(2, Math.min(32, Number(qualifiers) || 8))) s *= 2; return s; })();
  $: rounds = (() => {
    const out = [];
    for (let n = size / 2, r = 1; n >= 1; n /= 2, r++) {
      out.push({
        name: n === 1 ? 'FINAL' : n === 2 ? 'SEMI-FINALS' : n === 4 ? 'QUARTER-FINALS' : `ROUND ${r}`,
        matches: Array.from({ length: n }, (_, i) => i),
      });
    }
    return out;
  })();
</script>

<div class="pv">
  <div class="pv-head">
    <div class="pv-title">{title}</div>
    {#if message}<div class="pv-msg">{message}</div>{/if}
    <slot name="cta" />
  </div>
  <div class="pv-scroll">
    <div class="pv-bracket">
      {#each rounds as r}
        <div class="pv-col">
          <div class="pv-round">{r.name}</div>
          <div class="pv-matches">
            {#each r.matches as _m}
              <div class="pv-card">
                <div class="pv-slot"><span>TBD</span></div>
                <div class="pv-slot"><span>TBD</span></div>
              </div>
            {/each}
          </div>
        </div>
      {/each}
      <div class="pv-col pv-champ">
        <div class="pv-round">CHAMPION</div>
        <div class="pv-matches"><div class="pv-card pv-trophy"><div class="pv-slot"><span>TBD</span></div></div></div>
      </div>
    </div>
  </div>
</div>

<style>
  .pv { border: 1px solid var(--tablet-border); border-radius: var(--radius-md); background: var(--tablet-panel-alt); overflow: hidden; }
  .pv-head { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; padding: 14px 18px; border-bottom: 1px solid var(--tablet-border); background: var(--bg-card-raised); }
  .pv-title { font-size: var(--fs-body); font-weight: 700; letter-spacing: 0.01em; color: var(--text-main); }
  .pv-msg { flex: 1; min-width: 240px; font-size: var(--fs-small); color: var(--text-muted); }
  .pv-scroll { overflow-x: auto; padding: 18px; }
  .pv-bracket { display: flex; gap: 36px; min-width: max-content; align-items: stretch; }
  .pv-col { display: flex; flex-direction: column; width: 190px; }
  .pv-round { text-align: center; font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-muted); margin-bottom: 10px; }
  .pv-matches { flex: 1; display: flex; flex-direction: column; justify-content: space-around; gap: 14px; }
  .pv-card { border: 1px dashed var(--tablet-border-strong); border-radius: var(--r-panel); background: var(--tablet-panel); opacity: 0.8; }
  .pv-slot { padding: 9px 12px; font-size: var(--fs-small); font-weight: 700; letter-spacing: 0.01em; color: var(--text-muted); }
  .pv-slot + .pv-slot { border-top: 1px solid var(--tablet-border); }
  .pv-trophy { border-color: rgba(var(--accent-primary-rgb), 0.5); }
</style>
