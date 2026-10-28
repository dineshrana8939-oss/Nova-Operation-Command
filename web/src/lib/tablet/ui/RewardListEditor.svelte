<script>
  import { REWARD_TYPES } from '../../constants.js';
  import { bootstrap } from '../../stores.js';
  import { checkModels } from '../../api/route.js';
  import Icon from './Icon.svelte';

  // A LIST of {type, amount, pool} entries, not one — lets whatever this is
  // attached to (a convoy's main reward, or one airdrop's reward) pay out
  // money AND items (or several different items) at once. Shared between
  // CreateConvoy's General tab and RouteBuilder's airdrop config so both
  // don't reimplement the same repeatable-row editor.
  export let rewards = [];
  export let disabled = false;
  // Offers a VEHICLE reward (a GTA or custom car: model = its spawn name). Only where the event pays it out.
  export let allowVehicle = false;
  // Maximum number of vehicle rewards allowed in this list (defaults to 1 to prevent collisions)
  export let maxVehicles = 1;
  // Offers TOKENS reward (Race Tokens). Only where explicitly enabled (Gang Rally race events).
  export let allowTokens = false;

  // GANG_XP is on the picklist of every event: a gang member earns the configured Gang XP, a civilian always 0 (server-checked)
  $: baseTypes = allowTokens ? ['MONEY', 'ITEMS', 'TOKENS', 'GANG_XP'] : ['MONEY', 'ITEMS', 'GANG_XP'];
  $: types = allowVehicle ? [...baseTypes, 'VEHICLE'] : baseTypes;

  // Track how many vehicle rewards exist in this list
  $: vehicleCount = (rewards || []).filter((r) => r && r.type === 'VEHICLE').length;

  const getTypesForRow = (rowType) => {
    // If vehicle count reaches or exceeds maxVehicles, do NOT offer VEHICLE on non-vehicle rows
    const allowed = types.filter((t) => {
      if (t === 'VEHICLE') {
        if (rowType === 'VEHICLE') return true;
        return maxVehicles == null || vehicleCount < maxVehicles;
      }
      return true;
    });
    if (rowType && !allowed.includes(rowType)) {
      return [...allowed, rowType];
    }
    return allowed;
  };

  function pruneExtraVehicles() {
    let count = 0;
    rewards = (rewards || []).filter((r) => {
      if (r && r.type === 'VEHICLE') {
        count++;
        return count <= (maxVehicles || 1);
      }
      return true;
    });
  }

  $: vr = $bootstrap?.vehicleRewards || {};
  $: suggestions = Array.isArray(vr.suggestions) ? vr.suggestions : [];
  $: garageName = vr.garage || 'the garage';

  function addReward() {
    rewards = [...rewards, { type: 'MONEY', amount: 0, pool: '' }];
  }
  function removeReward(i) {
    rewards = rewards.filter((_, idx) => idx !== i);
  }

  // Switching a row to VEHICLE gives it the fields a car needs; switching away drops them again.
  function onType(r) {
    if (r.type === 'VEHICLE') {
      r.amount = 1;
      r.model = r.model || '';
      r.pool = r.pool || '';
      r.mode = r.mode || (vr.defaultMode === 'SPAWN' ? 'SPAWN' : 'GARAGE');
    } else {
      delete r.model;
      delete r.mode;
    }
    rewards = rewards;
  }

  // Picking a suggestion by its model fills in the display name; whatever model is typed is checked against the game.
  let modelState = {};   // model -> true / false (known to this game build or not)
  let checkTimer;
  function onModel(r) {
    const model = String(r.model || '').trim();
    r.model = model;
    const hit = suggestions.find((s) => s.model.toLowerCase() === model.toLowerCase());
    if (hit && !r.pool) r.pool = hit.label;
    rewards = rewards;
    clearTimeout(checkTimer);
    if (!model) return;
    checkTimer = setTimeout(async () => {
      try {
        const res = await checkModels([model]);
        if (res && res.ok && res.results && model in res.results) modelState = { ...modelState, [model]: res.results[model] !== false };
      } catch (e) { /* the warning just does not show */ }
    }, 400);
  }
</script>

<div class="reward-list">
  {#if allowVehicle && maxVehicles != null && vehicleCount > maxVehicles}
    <div class="reward-limit-alert">
      <span class="alert-icon">⚠️</span>
      <span><b>Vehicle Limit ({vehicleCount}/{maxVehicles}):</b> Maximum {maxVehicles} vehicle allowed per container. Multiple vehicles would collide inside the container!</span>
      <button type="button" class="btn-prune-veh" on:click={pruneExtraVehicles}>Keep Only 1 Vehicle</button>
    </div>
  {/if}

  {#if rewards.length === 0}
    <div class="reward-empty">No rewards configured — this pays out nothing.</div>
  {/if}
  {#each rewards as r, i}
    <div class="reward-row">
      <select bind:value={r.type} on:change={() => onType(r)} {disabled}>
        {#each getTypesForRow(r.type) as t}
          <option value={t}>{t === 'TOKENS' ? 'TOKENS (Race Tokens)' : (t === 'GANG_XP' ? 'GANG XP' : t)}</option>
        {/each}
      </select>
      {#if r.type === 'VEHICLE'}
        <input
          type="text"
          value="1 Vehicle (Max)"
          readonly
          disabled
          class="veh-amount-locked"
          title="Maximum 1 vehicle permitted per container to prevent collision errors and physical explosions."
        />
      {:else}
        <input
          type="number"
          min={0}
          placeholder={r.type === 'ITEMS' ? 'Count' : (r.type === 'TOKENS' ? 'Race Tokens' : (r.type === 'GANG_XP' ? 'Gang XP' : 'Amount ($)'))}
          bind:value={r.amount}
          {disabled}
        />
      {/if}
      {#if r.type === 'ITEMS'}
        <input type="text" placeholder="Item name" bind:value={r.pool} {disabled} />
      {/if}
      {#if r.type === 'VEHICLE'}
        <input type="text" list="reward-vehicle-models" placeholder="Model (e.g. sultanrs)" bind:value={r.model} on:input={() => onModel(r)} {disabled} />
        <input type="text" placeholder="Name shown to the winner" bind:value={r.pool} {disabled} />
        <select class="mode" bind:value={r.mode} {disabled} title="Garage: the winner owns it and finds it in {garageName}. Spawn: it appears beside the container with keys, not owned.">
          <option value="GARAGE">Into garage (owned)</option>
          <option value="SPAWN">Spawn at container</option>
        </select>
      {/if}
      <button class="icon-btn danger icon-btn-text" title="Remove this reward" on:click={() => removeReward(i)} {disabled}><Icon name="trash" size={12} /> Remove</button>
    </div>
    {#if r.type === 'GANG_XP'}
      <div class="reward-note">Paid as Gang XP to every gang member who earns this reward (recorded in the XP ledger). Civilians still get the normal reward, but always 0 Gang XP.</div>
    {/if}
    {#if r.type === 'VEHICLE'}
      <div class="reward-note" class:warn={r.model && modelState[r.model] === false}>
        {#if !r.model}
          Type the car's spawn name — a GTA car (sultanrs, jester…) or a custom/addon car streamed by another resource.
        {:else if modelState[r.model] === false}
          "{r.model}" is not in this game build. For a custom car, its resource must be started; check the spelling.
        {:else if r.mode === 'SPAWN'}
          The car appears beside the container and the winner gets its keys (it is not owned).
        {:else}
          The car is added to the winner's garage ({garageName}) and they own it.
        {/if}
      </div>
    {/if}
  {/each}
  <button class="link-btn" on:click={addReward} {disabled}><Icon name="plus" size={11} /> Add Reward</button>
  {#if allowVehicle}
    <datalist id="reward-vehicle-models">
      {#each suggestions as s}<option value={s.model}>{s.label}</option>{/each}
    </datalist>
  {/if}
</div>

<style>
  .reward-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .reward-empty {
    font-size: var(--fs-small);
    color: var(--tablet-text-faint);
    padding: 4px 0 2px;
  }
  .reward-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
  }
  .reward-note {
    margin: -2px 0 2px;
    font-size: var(--fs-meta);
    color: var(--tablet-text-faint);
  }
  .reward-note.warn { color: var(--lt-f0c36d, #f0c36d); }
  .reward-row select.mode { flex: 0 0 190px; }
  .reward-row select,
  .reward-row input {
    background: var(--lt-0f1113, #0f1113);
    border: 1px solid var(--lt-272b31, #272b31);
    border-radius: var(--r-ctl);
    color: var(--lt-ffffff, #ffffff);
    padding: 10px 14px;
    font-size: var(--fs-body);
    font-weight: 600;
    height: 42px;
    box-sizing: border-box;
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease, opacity 0.15s ease;
  }
  .reward-row select:focus,
  .reward-row input:focus {
    border-color: var(--accent-primary, #4f94e6);
    outline: none;
    box-shadow: 0 0 0 2px rgba(var(--accent-primary-rgb), 0.25);
  }
  .reward-row select option {
    background: var(--lt-0f1113, #0f1113);
    color: var(--lt-ffffff, #ffffff);
    padding: 8px 12px;
  }
  .reward-row select {
    flex: 0 0 140px;
    cursor: pointer;
  }
  .reward-row input[type='number'] {
    flex: 0 0 130px;
  }
  .reward-row input[type='text'] {
    flex: 1;
    min-width: 140px;
  }
  .icon-btn {
    width: 42px;
    height: 42px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--lt-181b1f, #181b1f);
    border: 1px solid var(--lt-272b31, #272b31);
    border-radius: var(--r-ctl);
    color: var(--lt-eceef0, #eceef0);
    transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease;
    cursor: pointer;
  }
  .icon-btn-text {
    width: auto;
    padding: 0 14px;
    gap: 6px;
    font-size: var(--fs-small);
    font-weight: 600;
    white-space: nowrap;
  }
  .icon-btn.danger:hover {
    color: var(--tablet-danger);
    border-color: var(--tablet-danger);
    background: var(--c-hover);
  }
  /* "Add Reward" is a real button: outlined, with a visible hover and focus state */
  .link-btn {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    height: 34px;
    padding: 0 16px;
    margin-top: 4px;
    align-self: flex-start;
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--text-main, #fff);
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.04);
    border: 1px dashed var(--tablet-border-strong, #363b43);
    border-radius: var(--r-ctl, 8px);
    cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease;
  }
  .link-btn:hover:not(:disabled) {
    background: var(--c-hover);
    border-color: var(--accent-primary, #4f94e6);
    border-style: solid;
  }
  .link-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .veh-amount-locked {
    flex: 0 0 145px !important;
    background: var(--c-hover) !important;
    border-color: var(--accent-primary) !important;
    color: var(--lt-70b4ff, #70b4ff) !important;
    font-size: var(--fs-small) !important;
    font-weight: 700 !important;
    cursor: not-allowed;
    user-select: none;
    text-align: center;
  }
  .reward-limit-alert {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--r-ctl);
    color: var(--lt-fca5a5, #fca5a5);
    font-size: var(--fs-meta);
    margin-bottom: 4px;
    border-left: 3px solid rgb(239, 68, 68);}
  .btn-prune-veh {
    margin-left: auto;
    background: #ef4444;
    color: var(--lt-ffffff, #fff);
    border: none;
    border-radius: var(--r-ctl);
    padding: 4px 10px;
    font-size: var(--fs-meta);
    font-weight: 700;
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.15s ease;
  }
  .btn-prune-veh:hover {
    background: #dc2626;
  }
</style>
