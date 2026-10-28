<script>
  // One status look for every table: a solid fill in the status's colour (tablet/ui/badges.js) with black or white lettering.
  // No tint, no border glow, no pulsing dot.
  import { statusColor, solid } from '../../tablet/ui/badges.js';

  export let status = 'SCHEDULED';
  export let label = '';

  const TEXT = {
    DRAFT: 'Draft', SCHEDULED: 'Scheduled', REGISTRATION_OPEN: 'Registration Open', OPEN: 'Open', FULL: 'Full', STARTING: 'Starting', ACTIVE: 'Active',
    CHECKPOINT: 'At Checkpoint', UNDER_ATTACK: 'Under Attack', DELIVERY: 'Delivery', COMPLETED: 'Completed', CAPTURED: 'Captured', FAILED: 'Failed',
    CANCELLED: 'Cancelled', NOT_STARTED: 'Not Started', REGISTERED: 'Registered',
  };
  // the statuses of this panel that share another status's colour
  const SAME_AS = { REGISTRATION_OPEN: 'SCHEDULED', OPEN: 'SCHEDULED', FULL: 'UNDER_ATTACK', NOT_STARTED: 'DRAFT', REGISTERED: 'ACTIVE' };

  $: key = String(status || '').toUpperCase().replace(/\s+/g, '_');
  $: style = solid(statusColor(SAME_AS[key] || key));
  $: displayLabel = label || TEXT[key] || status || 'Unknown';
</script>

<span class="status-pill" {style}>{displayLabel}</span>

<style>
  .status-pill {
    display: inline-flex;
    align-items: center;
    height: 22px;
    padding: 0 9px;
    border: 1px solid transparent;
    border-radius: var(--r-tag);
    font-size: var(--fs-meta);
    font-weight: 600;
    white-space: nowrap;
  }
</style>
