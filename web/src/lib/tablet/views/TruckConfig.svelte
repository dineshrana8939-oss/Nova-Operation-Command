<script>
  import { onMount } from 'svelte';
  import { getVehicleCatalog, addVehicleCatalogEntry, deleteVehicleCatalogEntry, validateModel } from '../../api/vehicles.js';
  import { TRUCK_ROLES, VEHICLE_CATEGORIES } from '../../constants.js';
  import { bootstrap } from '../../stores.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import RewardListEditor from '../ui/RewardListEditor.svelte';

  export let trucks = [];
  export let reward = [];
  export let locked = false;
  // Health of every escort vehicle police take from the shop ped (1000 = a stock car); lives with the convoy as escortVehicleHealth
  export let escortHealth = 5000;

  let catalog = [];
  let showCatalogManager = false;
  let newEntry = { model: '', label: '', category: 'CARGO', imageUrl: '' };
  let validating = false;
  let validateResult = null;
  let error = '';
  let editingId = null;

  function modelLabel(model) {
    return catalog.find((v) => v.model === model)?.label || model || '—';
  }

  $: maxTrucks = $bootstrap?.limits?.maxTrucksPerConvoy || 10;

  async function loadCatalog() {
    const res = await getVehicleCatalog();
    catalog = res && res.ok ? res.vehicles : [];
  }

  const CARGO_ROLES = ['PRIMARY_CARGO', 'SECONDARY_CARGO'];
  // Cargo trucks are the ones the whole event revolves around, so they
  // default (and are allowed) to be tougher than a plain escort/decoy
  // vehicle, which stays at the ordinary vanilla 1000 — makes the convoy
  // itself last longer without also making every vehicle in it a brick.
  function maxHealthFor(role) {
    return CARGO_ROLES.includes(role) ? 2000 : 1000;
  }

  // Convoy (cargo/decoy) vs Escort are different enough in practice — an
  // escort is meant to be police-driven and never the actual objective —
  // that mixing them in one flat list/form was confusing (which row is
  // "the truck" vs "just an escort car", and why does an escort car even
  // have a tunable body/engine health at all). Split into two sub-tabs
  // instead: role selection, model choices (filtered by vehicle catalog
  // category), and the health/armor fields only ever apply to the Convoy side.
  const SUB_TABS = [
    { id: 'convoy', label: 'Convoy Trucks' },
    { id: 'escort', label: 'Escort Vehicles' },
  ];
  let activeSubTab = (typeof localStorage !== 'undefined' && localStorage.getItem('nova_convoy_last_truck_subtab')) || 'convoy';
  $: if (typeof localStorage !== 'undefined' && activeSubTab) {
    localStorage.setItem('nova_convoy_last_truck_subtab', activeSubTab);
  }
  const CONVOY_ROLES = TRUCK_ROLES.filter((r) => r !== 'ESCORT');
  $: convoyTrucks = trucks.filter((t) => t.role !== 'ESCORT');
  $: escortTrucks = trucks.filter((t) => t.role === 'ESCORT');
  $: visibleTrucks = activeSubTab === 'escort' ? escortTrucks : convoyTrucks;

  // Ensure each truck has its own individual reward array
  $: {
    for (const t of trucks) {
      if (!Array.isArray(t.reward)) {
        if (Array.isArray(t.rewards)) {
          t.reward = [...t.rewards];
        } else if (Array.isArray(reward) && reward.length > 0) {
          t.reward = JSON.parse(JSON.stringify(reward));
        } else {
          t.reward = [{ type: 'MONEY', amount: 5000, pool: '' }];
        }
      }
    }
  }
  // Escort vehicles pick from the SAME category the on-demand Escort
  // Vehicle Shop ped uses (Config.EscortVehicleShop) — same idea, one
  // consistent pool of "what an escort vehicle looks like" instead of two
  // unrelated lists. Convoy (cargo/decoy) trucks are everything else.
  $: escortModels = catalog.filter((v) => v.category === 'ESCORT');
  $: convoyModels = catalog.filter((v) => v.category !== 'ESCORT');

  const DRIVER_MODELS = [
    { model: 's_m_m_marine_01', label: 'Army Soldier / Marine' },
    { model: 's_m_y_armymech_01', label: 'Army Mechanic / Driver' },
    { model: 's_m_y_cop_01', label: 'Police Officer' },
    { model: 's_m_m_security_01', label: 'Armed Security' },
    { model: 's_m_m_armoured_01', label: 'Armored Guard' },
  ];

  // The server drives a truck at 15 m/s × its speed multiplier (driveTruckTo), so the admin can
  // work in km/h and the multiplier is derived: 15 m/s × 3.6 = 54 km/h per 1.0×.
  const KMH_PER_MULT = 54;
  const MIN_MULT = 0.2;
  const MAX_MULT = 2;
  function setTruckKmh(truck, kmh) {
    const mult = (Number(kmh) || 0) / KMH_PER_MULT;
    truck.speed = Math.round(Math.max(MIN_MULT, Math.min(MAX_MULT, mult)) * 100) / 100;
    trucks = trucks;
  }

  function blankTruck() {
    const isEscort = activeSubTab === 'escort';
    const chosenModel = (isEscort ? escortModels[0] : convoyModels[0])?.model || catalog[0]?.model || '';
    const chosenLabel = catalog.find(v => v.model === chosenModel)?.label || chosenModel;
    return {
      id: `truck_${Date.now()}_${Math.floor(Math.random() * 1000)}`,
      role: isEscort ? 'ESCORT' : 'PRIMARY_CARGO',
      model: chosenModel,
      label: chosenLabel,
      price: 0,
      npcDriver: !isEscort,
      npcModel: 's_m_m_marine_01',
      // Escort vehicles are police-driven and requisitioned at the shop —
      // no need to tune health or offset for them.
      health: isEscort ? 1000 : 1500,
      engineHealth: 1000,
      speed: 0.6, // matches Config.DefaultTruckSpeed
      // 0 = no manual override, let spawnTruck's own dynamic spacing formula
      // (Config.ConvoySpacing) place it. This used to default to
      // convoyTrucks.length * 25 — a leftover from an abandoned side-by-side
      // spawn experiment where that formula meant something else — which,
      // for nose-to-tail spacing, just fights the real spacing formula: it
      // grows 25m per truck while the dynamic spacing only grows ~1m per
      // truck, so by the 3rd+ truck this hardcoded default was actually
      // LARGER than the sensible spacing and won via math.max(), pushing
      // later trucks noticeably further back than the ones ahead of them —
      // exactly "why is the 3rd truck spawning somewhere [disconnected]".
      formationOffset: 0,
      lockpicksRequired: '',
      reward: [{ type: 'MONEY', amount: 5000, pool: '' }],
    };
  }

  function addTruck() {
    if (trucks.length >= maxTrucks) { error = `Maximum of ${maxTrucks} trucks per convoy.`; return; }
    error = '';
    const truck = blankTruck();
    trucks = [...trucks, truck];
    editingId = truck.id; // jump straight into editing the truck you just added
  }

  async function removeTruck(id) {
    const isEscort = activeSubTab === 'escort';
    const ok = await confirmAction(`Remove this ${isEscort ? 'escort vehicle' : 'truck'} from the convoy?`, { title: isEscort ? 'Remove Escort Vehicle' : 'Remove Truck', danger: true });
    if (!ok) return;
    trucks = trucks.filter((t) => t.id !== id);
    if (editingId === id) editingId = null;
  }

  async function testModel() {
    if (!newEntry.model) return;
    validating = true;
    const res = await validateModel(newEntry.model.trim().toLowerCase());
    validating = false;
    validateResult = res.valid;
  }

  async function addCatalogEntry() {
    error = '';
    if (!newEntry.model.trim()) { error = 'Model name is required.'; return; }
    const res = await addVehicleCatalogEntry(newEntry.model.trim().toLowerCase(), newEntry.label || newEntry.model, newEntry.category, newEntry.imageUrl || null);
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to add catalog entry.'; return; }
    newEntry = { model: '', label: '', category: 'CARGO', imageUrl: '' };
    validateResult = null;
    await loadCatalog();
  }

  async function removeCatalogEntry(id, label) {
    const ok = await confirmAction(`Remove "${label}" from the vehicle catalog? Convoys already using it keep working.`, { title: 'Remove Vehicle', danger: true });
    if (!ok) return;
    await deleteVehicleCatalogEntry(id);
    await loadCatalog();
  }

  onMount(loadCatalog);
</script>

<div class="sub-tabs">
  {#each SUB_TABS as t}
    <button class="sub-tab" class:active={activeSubTab === t.id} on:click={() => (activeSubTab = t.id)}>
      {t.label} <span class="count">{(t.id === 'escort' ? escortTrucks : convoyTrucks).length}</span>
    </button>
  {/each}
</div>

<div class="header-row">
  <div class="section-title">
    {activeSubTab === 'escort' ? 'Escort Vehicles' : 'Convoy Trucks'} <span class="count">{trucks.length} / {maxTrucks} total</span>
  </div>
  <div class="header-actions">
    <button class="btn btn-catalog" on:click={() => (showCatalogManager = !showCatalogManager)}><Icon name="gear" size={13} /> Vehicle Catalog</button>
    <button class="btn btn-primary" on:click={addTruck} disabled={locked || trucks.length >= maxTrucks}><Icon name="plus" size={13} /> Add {activeSubTab === 'escort' ? 'Escort Vehicle' : 'Truck'}</button>
  </div>
</div>
{#if activeSubTab === 'escort'}
  <p class="sub-tab-hint">Escort vehicles do NOT spawn with the convoy trucks. They are made available in the Escort Vehicle Shop for police officers to requisition or purchase during the convoy.</p>
  <div class="escort-health">
    <label for="escort-health-input">Escort Vehicle Health</label>
    <input id="escort-health-input" type="number" min="500" max="100000" step="500" bind:value={escortHealth} disabled={locked} />
    <span class="escort-health-note">1000 = a stock car. Applies to every escort vehicle from the shop ped. Their tyres cannot be shot flat, and they have no health bar.</span>
  </div>
{/if}

{#if showCatalogManager}
  <div class="catalog-manager">
    <div class="catalog-manager-title">Registered Models</div>
    <div class="catalog-list">
      {#each catalog as v (v.id)}
        <div class="catalog-item">
          {#if v.image_url}
            <img src={v.image_url} alt={v.label} />
          {:else}
            <div class="catalog-thumb"><Icon name="truck" size={18} /></div>
          {/if}
          <div class="catalog-info">
            <div class="catalog-label">{v.label}</div>
            <div class="catalog-meta">{v.model} · {v.category}</div>
          </div>
          <button class="icon-btn danger icon-btn-text" on:click={() => removeCatalogEntry(v.id, v.label)}><Icon name="trash" size={13} /> Delete</button>
        </div>
      {:else}
        <div class="catalog-empty">No vehicles registered yet.</div>
      {/each}
    </div>

    <div class="catalog-add-title">Register New Model</div>
    <div class="catalog-add-grid">
      <div class="mini-field">
        <label>Spawn Name</label>
        <input type="text" placeholder="e.g. packer" bind:value={newEntry.model} />
      </div>
      <div class="mini-field">
        <label>Display Label</label>
        <input type="text" placeholder="e.g. Packer (Cargo)" bind:value={newEntry.label} />
      </div>
      <div class="mini-field">
        <label>Category</label>
        <select bind:value={newEntry.category}>
          {#each VEHICLE_CATEGORIES as c}<option value={c}>{c}</option>{/each}
        </select>
      </div>
      <div class="mini-field">
        <label>Image URL <span class="optional">optional</span></label>
        <input type="text" placeholder="https://..." bind:value={newEntry.imageUrl} />
      </div>
    </div>
    <div class="catalog-add-footer">
      {#if validateResult !== null}
        <span class="validate-result" class:ok={validateResult}>
          {validateResult ? '✓ Model exists and streams correctly' : '✕ Model not found — check spelling or its addon pack'}
        </span>
      {:else}
        <span></span>
      {/if}
      <div class="catalog-add-buttons">
        <button class="btn" on:click={testModel} disabled={validating || !newEntry.model}>{validating ? 'Testing...' : 'Test Model'}</button>
        <button class="btn btn-primary" on:click={addCatalogEntry}>Register</button>
      </div>
    </div>
  </div>
{/if}

{#if visibleTrucks.length === 0}
  <div class="empty-state">
    {activeSubTab === 'escort' ? 'No escort vehicles added yet.' : 'No trucks added yet.'} Click "Add {activeSubTab === 'escort' ? 'Escort Vehicle' : 'Truck'}" to build the {activeSubTab === 'escort' ? 'escort lineup' : 'convoy formation'}.
  </div>
{:else}
  <table class="data-table truck-table">
    <thead>
      <tr>
        <th>#</th>
        {#if activeSubTab !== 'escort'}<th>Role</th>{/if}
        <th>Model</th>
        {#if activeSubTab === 'escort'}
          <th>Shop Price</th>
        {:else}
          <th>NPC Driver</th>
          <th>Health</th>
          <th>Speed</th>
        {/if}
        <th style="text-align:right">Actions</th>
      </tr>
    </thead>
    <tbody>
      {#each visibleTrucks as truck, i (truck.id)}
        <tr class:editing-row={editingId === truck.id} on:click={() => (editingId = editingId === truck.id ? null : truck.id)}>
          <td>{i + 1}</td>
          {#if activeSubTab !== 'escort'}<td>{truck.role.replace('_', ' ')}</td>{/if}
          <td>{modelLabel(truck.model)}</td>
          {#if activeSubTab === 'escort'}
            <td>{(Number(truck.price) || 0) > 0 ? `$${truck.price}` : 'Free Loaner'}</td>
          {:else}
            <td>{truck.npcDriver ? 'Yes' : 'No (player-driven)'}</td>
            <td>{truck.health}</td>
            <td>{Math.round((Number(truck.speed) || 0) * KMH_PER_MULT)} km/h <span class="optional">({truck.speed}×)</span></td>
          {/if}
          <td><div class="row-actions">
            <button class="btn btn-sm" on:click|stopPropagation={() => (editingId = editingId === truck.id ? null : truck.id)}>
              <Icon name="edit" size={12} /> {editingId === truck.id ? 'Close' : 'Edit'}
            </button>
            {#if !locked}
              <button class="btn btn-danger btn-sm" on:click|stopPropagation={() => removeTruck(truck.id)}>
                <Icon name="trash" size={12} /> Remove
              </button>
            {/if}
          </div></td>
        </tr>
        {#if editingId === truck.id}
          <tr class="edit-row">
            <td colspan="7">
              <div class="truck-edit-form">
                {#if truck.role === 'ESCORT'}
                  <div class="field-row">
                    <div class="field">
                      <label>Vehicle Model</label>
                      <select bind:value={truck.model} disabled={locked} on:change={() => {
                        const found = escortModels.find(v => v.model === truck.model);
                        if (found) truck.label = found.label;
                      }}>
                        {#each escortModels as v}<option value={v.model}>{v.label}</option>{/each}
                      </select>
                    </div>
                    <div class="field">
                      <label>Requisition / Shop Price ($) <span class="optional">0 = Free Loaner</span></label>
                      <input type="number" min="0" step="500" bind:value={truck.price} placeholder="0" disabled={locked} />
                    </div>
                  </div>
                  <p class="sub-tab-hint" style="margin:8px 0 0">This vehicle will appear in the Escort Vehicle Shop for officers to requisition or buy during the convoy.</p>
                {:else}
                  <div class="field-row">
                    <div class="field">
                      <label>Role</label>
                      <select bind:value={truck.role} disabled={locked}>
                        {#each CONVOY_ROLES as r}<option value={r}>{r.replace('_', ' ')}</option>{/each}
                      </select>
                    </div>
                    <div class="field">
                      <label>Model</label>
                      <select bind:value={truck.model} disabled={locked} on:change={() => {
                        const found = convoyModels.find(v => v.model === truck.model);
                        if (found) truck.label = found.label;
                      }}>
                        {#each convoyModels as v}<option value={v.model}>{v.label}</option>{/each}
                      </select>
                    </div>
                  </div>

                  <div class="field reward-field">
                    <label>Truck Reward <span class="optional">paid to the looter or capturing gang for this specific truck — can mix money and multiple items</span></label>
                    <RewardListEditor bind:rewards={truck.reward} disabled={locked} />
                  </div>

                  <div class="toggle-block">
                    <Toggle label="NPC driver" bind:checked={truck.npcDriver} disabled={locked} />
                  </div>
                  {#if truck.npcDriver}
                    <div class="field-row">
                      <div class="field">
                        <label>NPC Driver Preset</label>
                        <select bind:value={truck.npcModel} disabled={locked}>
                          {#each DRIVER_MODELS as m}
                            <option value={m.model}>{m.label}</option>
                          {/each}
                        </select>
                      </div>
                      <div class="field">
                        <label>Custom Ped Model Code <span class="optional">optional override</span></label>
                        <input type="text" bind:value={truck.npcModel} placeholder="s_m_m_marine_01" disabled={locked} />
                      </div>
                    </div>
                  {/if}

                  <div class="field-row">
                    <div class="field">
                      <label>Body Health {#if CARGO_ROLES.includes(truck.role)}<span class="optional">(cargo — can exceed vanilla 1000)</span>{/if}</label>
                      <input type="number" min="0" max={maxHealthFor(truck.role)} bind:value={truck.health} disabled={locked} />
                    </div>
                    <div class="field">
                      <label>Engine Health</label>
                      <input type="number" min="0" max="1000" bind:value={truck.engineHealth} disabled={locked} />
                    </div>
                  </div>

                  <div class="field-row">
                    <div class="field">
                      <label>Cruise Speed (km/h) <span class="optional">{(Number(truck.speed) || 0).toFixed(2)}× · slows near checkpoints &amp; turns</span></label>
                      <input type="number" min={Math.round(MIN_MULT * KMH_PER_MULT)} max={Math.round(MAX_MULT * KMH_PER_MULT)} step="1"
                        value={Math.round((Number(truck.speed) || 0) * KMH_PER_MULT)} disabled={locked}
                        on:change={(e) => setTruckKmh(truck, e.currentTarget.value)} />
                    </div>
                    <div class="field">
                      <label>Formation Offset (m)</label>
                      <input type="number" bind:value={truck.formationOffset} disabled={locked} />
                    </div>
                  </div>

                  <div class="field">
                    <label>Lockpicks Required to Loot <span class="optional">blank = convoy/server default</span></label>
                    <input type="text" inputmode="numeric" placeholder="e.g. 4" bind:value={truck.lockpicksRequired} disabled={locked} />
                  </div>
                {/if}

                <div class="truck-edit-actions">
                  {#if !locked}
                    <button class="btn btn-danger" type="button" on:click={() => removeTruck(truck.id)}>
                      <Icon name="trash" size={13} /> Remove {truck.role === 'ESCORT' ? 'Escort Vehicle' : 'Truck'}
                    </button>
                  {/if}
                  <button class="btn btn-primary" type="button" on:click={() => (editingId = null)}>
                    Done
                  </button>
                </div>
              </div>
            </td>
          </tr>
        {/if}
      {/each}
    </tbody>
  </table>
{/if}

{#if error}<div class="error" style="margin-top:12px">{error}</div>{/if}

<style>
  .reward-field {
    margin-bottom: 18px;
    padding-bottom: 18px;
    border-bottom: 1px solid var(--tablet-border);
  }
  .sub-tabs {
    display: flex;
    gap: 6px;
    margin-bottom: 16px;
    padding: 5px;
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border-radius: var(--r-ctl);
    background: var(--lt-111316, #111316);
  }
  .sub-tab {
    position: relative;
    flex: 1;
    min-height: 40px;
    padding: 0 16px;
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.035);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.05);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    font-weight: 600;
    color: var(--lt-e3e6e9, #e3e6e9);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    cursor: pointer;
    transition: all 0.18s cubic-bezier(0.16, 1, 0.3, 1);
  }
  .sub-tab:hover {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.08);
    border-color: rgba(var(--ink-rgb, 255, 255, 255), 0.15);
    color: var(--lt-ffffff, #ffffff);
  }
  .sub-tab .count {
    min-width: 22px;
    padding: 1px 7px;
    border-radius: var(--r-tag);
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid rgba(var(--ink-rgb, 255, 255, 255), 0.1);
    color: var(--lt-c9ced4, #c9ced4);
    font-family: var(--font-mono);
    font-size: var(--fs-meta);
    text-align: center;
    margin-left: 0;
  }
  .sub-tab.active {
    background: var(--c-raised, #1f2328);
    border: 1px solid var(--c-line, #2a2e35);
    color: var(--lt-eceef0, #eceef0);
    font-weight: 700;
    box-shadow: none;
  }
  .sub-tab.active::after {
    content: '';
    position: absolute;
    left: 0;
    right: 0;
    bottom: -1px;
    height: 2px;
    background: var(--accent-primary);
    color: var(--on-accent, inherit);
}
  .sub-tab.active .count {
    background: transparent;
    border-color: rgba(var(--accent-primary-rgb), 0.5);
    color: var(--lt-ffffff, #ffffff);
  }
  .sub-tab-hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: -8px 0 16px;
  }
  .header-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 18px;
    flex-wrap: wrap;
    gap: 10px;
  }
  .section-title {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 38px;
    padding: 8px 14px;
    background: var(--topbar-bg, #15171b);
    border: 1px solid var(--tablet-border, #2a2e35);
    border-left: 3px solid var(--accent-primary, #4f94e6);
    border-radius: var(--r-ctl);
    font-size: var(--fs-small);
    font-weight: 700;
    letter-spacing: 0.01em;
    color: var(--text-main, #ffffff);
  }
  .section-title .count {
    margin-left: auto;
    font-size: var(--fs-meta);
    font-weight: 500;
    letter-spacing: 0;
    text-transform: none;
    color: var(--text-muted, #aeb5bd);
  }
  .count {
    color: var(--tablet-text-faint);
    font-weight: 400;
    margin-left: 4px;
  }
  .header-actions {
    display: flex;
    gap: 8px;
  }

  .catalog-manager {
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
    padding: 18px;
    margin-bottom: 20px;
    background: var(--tablet-panel-alt);
  }
  .catalog-manager-title,
  .catalog-add-title {
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--tablet-text-faint);
    margin-bottom: 10px;
  }
  .catalog-add-title {
    margin-top: 18px;
    padding-top: 18px;
    border-top: 1px solid var(--tablet-border);
  }
  .catalog-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    max-height: 200px;
    overflow-y: auto;
  }
  .catalog-empty {
    font-size: var(--fs-small);
    color: var(--tablet-text-faint);
    padding: 8px 0;
  }
  .catalog-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 10px;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
  }
  .catalog-item img,
  .catalog-thumb {
    width: 38px;
    height: 38px;
    object-fit: cover;
    border-radius: var(--radius-sm);
    background: var(--tablet-bg);
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--accent-primary);
    flex-shrink: 0;
  }
  .catalog-info {
    flex: 1;
    min-width: 0;
  }
  .catalog-label {
    font-size: var(--fs-body);
    color: var(--text-main);
  }
  .catalog-meta {
    font-size: var(--fs-small);
    color: var(--text-dim);
    font-family: var(--font-mono);
    margin-top: 2px;
  }

  .catalog-add-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 14px;
  }
  .mini-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .mini-field label {
    font-size: var(--fs-meta);
    font-weight: 600;
    letter-spacing: 0.01em;
    color: var(--tablet-text-faint);
  }
  .mini-field .optional {
    text-transform: none;
    font-weight: 400;
    opacity: 0.7;
  }
  .field label .optional {
    text-transform: none;
    font-weight: 400;
    font-size: var(--fs-small);
    color: var(--text-dim);
    margin-left: 4px;
  }
  .mini-field input,
  .mini-field select {
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-main);
    padding: 9px 10px;
    font-size: var(--fs-body);
  }
  .mini-field input:focus,
  .mini-field select:focus {
    outline: none;
    border-color: var(--accent-primary);
  }

  .catalog-add-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-top: 14px;
    flex-wrap: wrap;
  }
  .catalog-add-buttons {
    display: flex;
    gap: 8px;
    margin-left: auto;
  }
  .validate-result {
    font-size: var(--fs-small);
    color: var(--tablet-danger);
  }
  .validate-result.ok {
    color: var(--tablet-success);
  }

  .truck-table tbody tr:not(.edit-row) {
    cursor: pointer;
  }
  .truck-table tr.editing-row {
    background: var(--c-hover);
  }
  .row-actions {
    display: flex;
    gap: 6px;
    justify-content: flex-end;
  }
  tr.edit-row td {
    padding: 0;
    cursor: default;
    font-variant-numeric: tabular-nums;
  }
  .truck-edit-form {
    padding: 18px;
    background: var(--tablet-bg);
    border-bottom: 1px solid var(--tablet-border);
  }
  .toggle-block {
    margin-bottom: 4px;
  }
  .icon-btn {
    width: 30px;
    height: 30px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    color: var(--text-dim);
    transition: border-color 0.15s ease, color 0.15s ease, background 0.15s ease;
  }
  .icon-btn.danger:hover {
    color: var(--tablet-danger);
    border-color: var(--tablet-danger);
    background: var(--c-hover);
  }
  .truck-edit-actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-top: 18px;
    padding-top: 14px;
    border-top: 1px solid var(--tablet-border);
  }

  .escort-health {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
    margin: 0 0 12px;
    padding: 10px 12px;
    border: 1px solid var(--c-line, #2a2e35);
    border-radius: var(--r-ctl);
    background: var(--c-panel, rgba(255, 255, 255, 0.03));
  }
  .escort-health label { font-weight: 600; font-size: var(--fs-meta); white-space: nowrap; }
  .escort-health input { width: 120px; }
  .escort-health-note { font-size: var(--fs-meta); opacity: 0.7; }
</style>
