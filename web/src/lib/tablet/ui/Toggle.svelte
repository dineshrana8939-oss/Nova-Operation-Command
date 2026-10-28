<script>
  import { createEventDispatcher } from 'svelte';

  export let checked = false;
  export let label = '';
  export let disabled = false;

  const dispatch = createEventDispatcher();

  function toggle() {
    if (disabled) return;
    checked = !checked;
    dispatch('change', checked);
  }
</script>

<label class="toggle" class:disabled>
  <span class="text">{label}</span>
  <span class="switch" class:on={checked} on:click={toggle} role="switch" aria-checked={checked} tabindex="0"
    on:keydown={(e) => (e.key === 'Enter' || e.key === ' ') && toggle()}>
    <span class="knob"></span>
  </span>
</label>

<style>
  .toggle {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 0;
    border-bottom: 1px solid var(--lt-1f2328, #1f2328);
  }
  .text {
    font-size: var(--fs-body);
    color: var(--text-main, #c9ced4);
  }
  .toggle.disabled .switch {
    opacity: 0.5;
    cursor: not-allowed;
  }
  .switch {
    width: 44px;
    height: 25px;
    background: #4a4c58;
    border: none;
    border-radius: var(--r-tag);
    position: relative;
    flex-shrink: 0;
    cursor: pointer;
    transition: background 0.15s ease;
  }
  .switch.on {
    background: var(--toggle-on, #398fe7);
  }
  .knob {
    position: absolute;
    top: 3px;
    left: 3px;
    width: 19px;
    height: 19px;
    border-radius: 50%;
    background: #c9ced4;
    box-shadow: none;
    transition: transform 0.15s ease, background 0.15s ease;
  }
  .switch.on .knob {
    transform: translateX(19px);
    background: var(--on-accent, #ffffff);
  }
</style>
