<script>
  import { onMount } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';

  export let toasts = []; // Array of { id, type, title, message, timeout }
  export let onDismiss = (id) => {};
</script>

<div class="toast-stack">
  {#each toasts as t (t.id)}
    <div class="toast-item {t.type || 'info'}">
      <div class="toast-icon">
        {#if t.type === 'success'}
          <Icon name="check" size={14} />
        {:else if t.type === 'error'}
          <Icon name="close" size={14} />
        {:else if t.type === 'warning'}
          <Icon name="warning" size={14} />
        {:else}
          <Icon name="info" size={14} />
        {/if}
      </div>
      <div class="toast-content">
        {#if t.title}
          <div class="toast-title">{t.title}</div>
        {/if}
        <div class="toast-message">{t.message}</div>
      </div>
      <button class="toast-close" on:click={() => onDismiss(t.id)}>
        <Icon name="close" size={12} />
      </button>
    </div>
  {/each}
</div>

<style>
  .toast-stack {
    position: fixed;
    bottom: 24px;
    right: 24px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    z-index: 9999;
    max-width: 380px;
    width: 100%;
    pointer-events: none;
  }

  .toast-item {
    pointer-events: auto;
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 11px 14px;
    background: var(--tablet-panel);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm, 5px);
    box-shadow: var(--shadow-soft);
    animation: toastIn 0.2s cubic-bezier(0.16, 1, 0.3, 1) both;
  }

  @keyframes toastIn {
    from { opacity: 0; transform: translateY(12px) scale(0.96); }
    to { opacity: 1; transform: translateY(0) scale(1); }
  }

  .toast-item.success {
    border-left: 3px solid var(--tablet-success);
  }
  .toast-item.success .toast-icon {
    color: var(--tablet-success);
    background: rgba(48, 209, 88, 0.12);
  }

  .toast-item.error {
    border-left: 3px solid var(--tablet-danger);
  }
  .toast-item.error .toast-icon {
    color: var(--tablet-danger);
    background: var(--c-raised);
    border-left: 3px solid #ef4444;}

  .toast-item.warning {
    border-left: 3px solid var(--tablet-warn);
  }
  .toast-item.warning .toast-icon {
    color: var(--tablet-warn);
    background: rgba(255, 200, 87, 0.12);
  }

  .toast-item.info {
    border-left: 3px solid var(--accent-primary);
  }
  .toast-item.info .toast-icon {
    color: var(--accent-primary-light);
    background: var(--c-hover);
  }

  .toast-icon {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .toast-content {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .toast-title {
    font-size: var(--fs-body);
    font-weight: 700;
    color: var(--text-main);
  }

  .toast-message {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.45;
    word-break: break-word;
  }

  .toast-close {
    background: transparent;
    border: none;
    color: var(--text-dim);
    cursor: pointer;
    padding: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm, 5px);
    transition: color 0.12s ease;
  }

  .toast-close:hover {
    color: var(--text-main);
  }
</style>
