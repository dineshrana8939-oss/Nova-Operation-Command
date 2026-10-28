<script>
  // The Prop Spawn Mode switch shared by every Props tab (PropsPanel, Container Wars harbour stacks).
  // It only reports the click: the owner decides what spawning means.
  import { createEventDispatcher } from 'svelte';
  import Icon from './Icon.svelte';
  import '../tablet-theme.css';

  export let active = false;
  export let offText = 'Off: Objects stay stored in configuration until live event starts.';
  export let onText = 'Saved layout is standing in the game world on your client for preview.';

  const dispatch = createEventDispatcher();
</script>

<div class="spawn-mode-strip" class:active>
  <div class="spawn-mode-left">
    <Icon name="layers" size={14} />
    <span class="spawn-mode-title">PROP SPAWN MODE</span>
    <span class="spawn-mode-pill {active ? 'pill-on' : 'pill-off'}">{active ? 'ACTIVE IN WORLD' : 'OFF'}</span>
    <span class="spawn-mode-desc">{active ? onText : offText}</span>
  </div>
  <div class="spawn-mode-toggle-action">
    <button type="button" class="btn-spawn-mode-toggle" class:is-active={active} on:click={() => dispatch('toggle')}
      title={active ? 'Turn Prop Spawn Mode OFF (remove the world copies, keep the saved layout)' : 'Turn Prop Spawn Mode ON (spawn the saved layout)'}>
      <span class="toggle-track"><span class="toggle-thumb" class:toggled={active}></span></span>
      <span class="toggle-label">{active ? 'SPAWN: ON' : 'SPAWN: OFF'}</span>
    </button>
  </div>
</div>

<style>
  /* ── Compact Prop Spawn Mode Strip ── */
  .spawn-mode-strip {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 16px;
    background: var(--lt-15171b, #15171b);
    border: 1px solid rgba(var(--accent-primary-rgb), 0.28);
    border-left: 3px solid var(--accent-primary);
    border-radius: var(--r-panel);
    transition: background 0.2s ease, border-color 0.2s ease;
  }
  .spawn-mode-strip.active {
    background: rgba(var(--ltc-30-46-68, 30, 46, 68), 0.45);
    border-color: rgba(70, 201, 139, 0.45);
    border-left-color: #46c98b;
  }
  .spawn-mode-left {
    display: flex;
    align-items: center;
    gap: 10px;
    flex: 1;
    min-width: 0;
    flex-wrap: wrap;
  }
  .spawn-mode-title {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--lt-ffffff, #ffffff);
  }
  .spawn-mode-pill {
    padding: 2px 8px;
    border-radius: 999px;
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
  }
  .spawn-mode-pill.pill-on {
    background: rgb(70, 201, 139);
    border: 1px solid rgb(70, 201, 139);
    color: #111111;
  }
  .spawn-mode-pill.pill-off {
    background: var(--lt-1f2328, #1f2328);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    color: var(--text-muted, #7c848d);
  }
  .spawn-mode-desc {
    margin: 0;
    font-size: var(--fs-meta);
    color: var(--text-dim, #959ca5);
  }
  .spawn-mode-toggle-action { flex-shrink: 0; }
  .btn-spawn-mode-toggle {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    height: 32px;
    padding: 0 10px;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-2a2e35, #2a2e35);
    border-radius: var(--r-ctl);
    cursor: pointer;
    transition: background 0.2s ease, border-color 0.2s ease;
  }
  .btn-spawn-mode-toggle:hover:not(:disabled) { background: var(--lt-22262c, #22262c); border-color: #3b3d4f; }
  .btn-spawn-mode-toggle.is-active { background: rgba(70, 201, 139, 0.12); border-color: rgba(70, 201, 139, 0.5); }
  .toggle-track { width: 30px; height: 16px; border-radius: var(--r-tag); background: var(--lt-2a2e35, #2a2e35); border: 1px solid #3b3d4f; position: relative; flex-shrink: 0; transition: background 0.2s ease, border-color 0.2s ease; }
  .btn-spawn-mode-toggle.is-active .toggle-track { background: #46c98b; border-color: #46c98b; }
  .toggle-thumb { position: absolute; top: 1px; left: 1px; width: 12px; height: 12px; border-radius: 50%; background: #8d949c; transition: transform 0.2s ease, background 0.2s ease; }
  .toggle-thumb.toggled { transform: translateX(14px); background: var(--lt-0d281e, #0d281e); }
  .toggle-label { font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.01em; color: var(--text-dim, #959ca5); }
  .btn-spawn-mode-toggle.is-active .toggle-label { color: var(--lt-46c98b, #46c98b); }
</style>
