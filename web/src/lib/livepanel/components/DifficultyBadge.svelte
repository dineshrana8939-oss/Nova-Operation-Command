<script>
  // Solid fill, black or white lettering by contrast (same look as the status and event-type tags); graded by level.
  import { solid } from '../../tablet/ui/badges.js';

  export let difficulty = 'MEDIUM';

  const DIFF_CONFIG = {
    EASY: { label: 'Easy', color: '#34c98b' },
    MEDIUM: { label: 'Medium', color: '#e8b33a' },
    HARD: { label: 'Hard', color: '#f0883e' },
    EXTREME: { label: 'Extreme', color: '#d9534f' },
  };

  $: key = String(difficulty || 'MEDIUM').toUpperCase();
  $: cfg = DIFF_CONFIG[key] || DIFF_CONFIG.MEDIUM;
</script>

<span class="diff-badge" style={solid(cfg.color)}>{cfg.label}</span>

<style>
  .diff-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 66px;
    height: 22px;
    padding: 0 9px;
    border: 1px solid transparent;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    white-space: nowrap;
  }
</style>
