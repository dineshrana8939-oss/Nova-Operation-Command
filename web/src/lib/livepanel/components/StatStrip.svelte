<script>
  import Icon from '../../tablet/ui/Icon.svelte';

  // Array of { label, value, icon, sub, note }
  //   sub  — small text beside the value ("/ 5")
  //   note — caption under the label
  // Same look as the tablet's .kpi-card (tablet-theme.css): neutral card,
  // blue icon chip, value over label. Tiles are told apart by their icon.
  export let stats = [];
</script>

<div class="stat-strip">
  {#each stats as s}
    <div class="stat-card">
      {#if s.icon}
        <div class="stat-icon">
          <Icon name={s.icon} size={18} />
        </div>
      {/if}
      <div class="stat-info">
        <div class="stat-value-row">
          <span class="stat-value" title={String(s.value)}>{s.value}</span>
          {#if s.sub}
            <span class="stat-sub">{s.sub}</span>
          {/if}
        </div>
        <span class="stat-label" title={s.label}>{s.label}</span>
        {#if s.note}
          <span class="stat-note" title={s.note}>{s.note}</span>
        {/if}
      </div>
    </div>
  {/each}
</div>

<style>
  .stat-strip {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 10px;
    width: 100%;
    flex-shrink: 0;
  }

  .stat-card {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    padding: 10px 14px;
    background: var(--es-card, rgba(11, 21, 36, 0.6));
    border: 1px solid var(--es-line, rgba(110, 160, 215, 0.22));
    border-radius: var(--r-panel, 12px);
    box-shadow: var(--es-edge, none);
    transition: border-color 0.15s ease, background 0.15s ease;
  }

  .stat-card:hover {
    background: var(--es-card-hover, rgba(24, 32, 46, 0.75));
    border-color: var(--es-line-strong, rgba(110, 160, 215, 0.38));
  }

  /* the icon sits in a blue well, the one coloured accent on each tile */
  .stat-icon {
    width: 36px;
    height: 36px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--btn-soft, var(--c-hover));
    border: 1px solid var(--btn-soft-line, var(--c-line));
    border-radius: var(--r-ctl, 8px);
    color: var(--text-main);
  }

  .stat-info {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
  }

  .stat-value-row {
    display: flex;
    align-items: baseline;
    gap: 7px;
    min-width: 0;
  }

  .stat-value {
    font-size: 28px;
    line-height: 1.1;
    font-weight: 600;
    color: var(--lt-ffffff, #ffffff);
    font-feature-settings: 'tnum';
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-variant-numeric: tabular-nums;
  }

  .stat-sub {
    font-size: var(--fs-meta);
    color: var(--c-text-3);
    white-space: nowrap;
    font-weight: 500;
  }

  .stat-label {
    margin-top: 3px;
    font-size: var(--fs-meta);
    font-weight: 600;
    color: var(--text-muted);
    line-height: 1.25;
    letter-spacing: 0;
  }

  .stat-note {
    margin-top: 2px;
    font-size: var(--fs-meta);
    color: var(--text-muted, #aeb5bd);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
</style>
