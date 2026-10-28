<script>
  import { createEventDispatcher } from 'svelte';

  // Typed X / Y / Z / Heading for a saved position. Bind it:
  //   <CoordFields bind:value={container.dropCoords} />
  // Unset coordinates are null; the object is only "set" once x, y and z are numbers.
  export let value = null;
  export let disabled = false;

  const dispatch = createEventDispatcher();
  const FIELDS = [
    { key: 'x', label: 'X', step: '0.1' },
    { key: 'y', label: 'Y', step: '0.1' },
    { key: 'z', label: 'Z', step: '0.1' },
    { key: 'heading', label: 'Heading°', step: '1' },
  ];

  const num = (v) => {
    const n = parseFloat(v);
    return Number.isFinite(n) ? n : null;
  };

  // Paste "886.75, -2912.96, 5.90, 269.7" (or vec4(...), x = ..., one per line) into any box and all
  // four fields are filled. A single number still pastes normally.
  function paste(e) {
    const text = (e.clipboardData && e.clipboardData.getData('text')) || '';
    const nums = text.match(/-?\d+(?:\.\d+)?/g);
    if (!nums || nums.length < 3) return;
    e.preventDefault();
    const next = { x: null, y: null, z: null, heading: 0, ...(value || {}) };
    next.x = num(nums[0]); next.y = num(nums[1]); next.z = num(nums[2]);
    if (nums.length >= 4) next.heading = num(nums[3]) ?? 0;
    value = next;
    dispatch('change', next);
  }

  function edit(key, e) {
    const next = { x: null, y: null, z: null, heading: 0, ...(value || {}) };
    next[key] = num(e.target.value);
    if (key === 'heading' && next.heading == null) next.heading = 0;
    value = next;
    dispatch('change', next);
  }
</script>

<div class="cf" class:disabled>
  {#each FIELDS as f}
    <label>
      <span>{f.label}</span>
      <input
        type="number"
        step={f.step}
        value={value && value[f.key] != null ? value[f.key] : ''}
        on:change={(e) => edit(f.key, e)}
        on:paste={paste}
        {disabled}
      />
    </label>
  {/each}
</div>

<style>
  .cf {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 8px;
  }
  label {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }
  span {
    font-size: var(--fs-meta);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-dim);
  }
  input {
    width: 100%;
    height: 32px;
    padding: 0 8px;
    background: var(--lt-15171b, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-radius: var(--r-ctl);
    color: var(--text-main, #fff);
    font-family: var(--font-mono);
    font-size: var(--fs-small);
    outline: none;
  }
  input:focus { border-color: var(--accent-primary); }
  input:disabled { opacity: 0.55; cursor: not-allowed; }
</style>
