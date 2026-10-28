<script>
  import { confirmState } from './confirm.js';
  import Icon from './Icon.svelte';

  function respond(value) {
    const s = $confirmState;
    if (s) s.resolve(value);
    confirmState.set(null);
  }

  function onKeydown(e) {
    if ($confirmState && e.key === 'Escape') {
      e.stopPropagation();
      respond(false);
    }
  }
</script>

<svelte:window on:keydown={onKeydown} />

{#if $confirmState}
  <div class="overlay">
    <div class="box" class:danger={$confirmState.danger}>
      <div class="title" class:danger={$confirmState.danger}>
        {#if $confirmState.danger}
          <span class="warn-icon"><Icon name="warning" size={20} /></span>
        {/if}
        {$confirmState.title}
      </div>
      <div class="message">{$confirmState.message}</div>
      <div class="actions">
        <button class="btn" on:click={() => respond(false)}>{$confirmState.cancelLabel || 'Cancel'}</button>
        <button class="btn {$confirmState.danger ? 'btn-danger-solid' : 'btn-primary'}" on:click={() => respond(true)}>{$confirmState.confirmLabel || 'Confirm'}</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: absolute;
    inset: 0;
    background: rgba(var(--ltc-6-7-9, 6, 7, 9), 0.66);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 5000;
    animation: fade 0.14s ease-out;
  }
  /* Neutral confirms get a blue top edge, destructive ones a red edge plus
     a solid red confirm button, so the risk reads before the text does. */
  .box {
    width: 460px;
    max-width: 92vw;
    /* the dialog surface of whichever theme is applied (Settings → Appearance): the admin themes and the gang panel both set
       --surface-dialog on their own window, so this box follows the chosen background instead of a fixed blue picture */
    background: var(--surface-dialog);
    background-color: var(--c-panel, #181b1f);
    border: 1px solid var(--border-dialog);
    border-top: 3px solid var(--c-action);
    border-radius: var(--r-panel);
    padding: 20px 22px 18px;
    box-shadow: var(--shadow-overlay);
    animation: rise 0.16s ease-out both;
  }
  .box.danger {
    border-top-color: var(--c-live);
  }
  @keyframes fade {
    from { opacity: 0; }
  }
  @keyframes rise {
    from { opacity: 0; transform: translateY(6px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .title {
    display: flex;
    align-items: center;
    gap: 9px;
    font-family: var(--font-display); font-stretch: var(--stretch-display);
    font-size: var(--fs-section);
    line-height: 1.15;
    font-weight: 700;
    color: var(--c-text);
  }
  .warn-icon {
    display: inline-flex;
    color: var(--c-live);
    flex-shrink: 0;
  }
  .message {
    font-size: var(--fs-body);
    color: var(--c-text-2);
    margin-top: 10px;
    line-height: 1.55;
    white-space: pre-line;
  }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 20px;
  }
  @media (prefers-reduced-motion: reduce) {
    .overlay,
    .box { animation: none; }
  }
</style>
