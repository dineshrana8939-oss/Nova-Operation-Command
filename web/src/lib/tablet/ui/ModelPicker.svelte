<script>
  // Preset dropdown plus a "Custom model…" entry for any other GTA model name.
  //   <ModelPicker bind:value={c.model} presets={CONTAINER_MODELS} />
  export let value = '';
  export let presets = []; // [{ id, label }]
  export let disabled = false;
  export let placeholder = 'model_name';

  const CUSTOM = '__custom';
  let forceCustom = false;
  $: isPreset = presets.some((p) => p.id === value);
  $: customMode = forceCustom || (!isPreset && !!value);

  function onSelect(e) {
    const v = e.target.value;
    if (v === CUSTOM) {
      forceCustom = true;
    } else {
      forceCustom = false;
      value = v;
    }
  }
</script>

<div class="mp">
  <select value={customMode ? CUSTOM : value} on:change={onSelect} {disabled}>
    {#each presets as p}<option value={p.id}>{p.label}</option>{/each}
    <option value={CUSTOM}>Custom model…</option>
  </select>
  {#if customMode}
    <input type="text" {placeholder} bind:value {disabled} spellcheck="false" />
  {/if}
</div>

<style>
  .mp { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
  select, input {
    width: 100%;
    height: 36px;
    padding: 0 10px;
    background: var(--lt-15171b, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-main, #fff);
    font-size: var(--fs-small);
    outline: none;
  }
  input { font-family: var(--font-mono); }
  select:focus, input:focus { border-color: var(--accent-primary); }
  select:disabled, input:disabled { opacity: 0.55; cursor: not-allowed; }
</style>
