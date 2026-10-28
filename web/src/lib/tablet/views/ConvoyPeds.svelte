<script>
  // Convoy → Peds: the two server-wide peds that only exist for convoys (the police tactical equipment vendor and the
  // escort vehicle shop). They used to sit in Settings; they belong with the convoy tools, so they have their own tab.
  import { onMount } from 'svelte';
  import { bootstrap } from '../../stores.js';
  import {
    getEquipmentVendorLocation, setEquipmentVendorLocation, setEquipmentVendorEnabled,
    getEscortShopLocation, setEscortShopLocation, setEscortShopEnabled,
  } from '../../api/equipment.js';
  import { teleportToPosition, startHarbourPlacer } from '../../api/route.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import '../tablet-theme.css';

  let moving = false;
  let error = '';
  let moved = false;
  let vendorLocation = null;
  let vendorEnabled = true;
  let togglingVendor = false;

  let escortLocation = null;
  let escortEnabled = true;
  let togglingEscort = false;
  let movingEscort = false;
  let escortMoved = false;

  async function loadVendorState() {
    const res = await getEquipmentVendorLocation();
    if (res) { vendorEnabled = res.enabled !== false; vendorLocation = res; }
  }

  function teleportToVendor() {
    if (!vendorLocation) return;
    teleportToPosition(vendorLocation.x, vendorLocation.y, vendorLocation.z, vendorLocation.heading);
  }

  async function loadEscortState() {
    const res = await getEscortShopLocation();
    if (res) { escortEnabled = res.enabled !== false; escortLocation = res; }
  }

  onMount(() => {
    loadVendorState();
    loadEscortState();
  });

  async function moveVendor() {
    error = '';
    const ok = await confirmAction(
      'This moves the tactical equipment vendor ped to your current position — it moves for everyone online immediately, no restart needed.',
      { title: 'Move Equipment Vendor' }
    );
    if (!ok) return;
    moving = true;
    const res = await setEquipmentVendorLocation();
    moving = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to move vendor.'; return; }
    vendorLocation = { ...vendorLocation, ...res.location };
    moved = true;
    setTimeout(() => (moved = false), 3000);
  }

  // Placement hologram for the two peds: a see-through copy of the ped follows the crosshair (F freezes it, G drops it to
  // the ground, E confirms), then the ped moves there for everyone online. Cancelling changes nothing.
  async function placeWithHologram(which) {
    error = '';
    const isVendor = which === 'vendor';
    const loc = isVendor ? vendorLocation : escortLocation;
    if (isVendor) moving = true; else movingEscort = true;
    let spot = null;
    try {
      spot = await startHarbourPlacer({
        kind: 'ped', index: 1,
        model: (isVendor ? $bootstrap?.pedModels?.equipmentVendor : $bootstrap?.pedModels?.escortShop) || '',
        label: isVendor ? 'Equipment Vendor' : 'Escort Vehicle Shop',
        // no saved coordinates on purpose: the hologram appears at the crosshair, in front of the admin
      });
    } catch (e) { spot = null; }
    if (!spot || !spot.ok) {
      if (isVendor) moving = false; else movingEscort = false;
      if (spot && spot.error) error = spot.error === 'busy' ? 'A placer is already open.' : 'The hologram could not start (the ped model may be missing in this game build).';
      return;
    }
    const placed = { x: spot.x, y: spot.y, z: spot.z, heading: spot.heading };
    const res = isVendor ? await setEquipmentVendorLocation(placed) : await setEscortShopLocation(placed);
    if (isVendor) moving = false; else movingEscort = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to move the ped.'; return; }
    if (isVendor) { vendorLocation = { ...vendorLocation, ...res.location }; moved = true; setTimeout(() => (moved = false), 3000); }
    else { escortLocation = { ...escortLocation, ...res.location }; escortMoved = true; setTimeout(() => (escortMoved = false), 3000); }
  }

  async function toggleVendorEnabled() {
    error = '';
    const next = !vendorEnabled;
    togglingVendor = true;
    const res = await setEquipmentVendorEnabled(next);
    togglingVendor = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to update vendor.'; return; }
    vendorEnabled = next;
  }

  async function moveEscortShop() {
    error = '';
    const ok = await confirmAction(
      'This moves the escort vehicle shop ped to your current position — it moves for everyone online immediately, no restart needed.',
      { title: 'Move Escort Vehicle Shop' }
    );
    if (!ok) return;
    movingEscort = true;
    const res = await setEscortShopLocation();
    movingEscort = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to move escort shop.'; return; }
    escortLocation = { ...escortLocation, ...res.location };
    escortMoved = true;
    setTimeout(() => (escortMoved = false), 3000);
  }

  async function toggleEscortEnabled() {
    error = '';
    const next = !escortEnabled;
    togglingEscort = true;
    const res = await setEscortShopEnabled(next);
    togglingEscort = false;
    if (!res || !res.ok) { error = (res && res.error) || 'Failed to update escort shop.'; return; }
    escortEnabled = next;
  }

  function teleportToEscortShop() {
    if (!escortLocation) return;
    teleportToPosition(escortLocation.x, escortLocation.y, escortLocation.z, escortLocation.heading);
  }
</script>

<div class="panel view-enter">
  <div class="panel-header"><span class="panel-title"><Icon name="truck" size={14} /> Convoy Peds</span></div>
  <div class="panel-body">
    <p class="note">Server-wide peds that belong to the Police Escort Convoy. Changes apply to everyone online immediately — no restart needed.</p>

    <div class="section-title">Police Equipment Vendor</div>
    <div class="live-action">
      <div>
        <div class="live-action-title">Vendor ped</div>
        <div class="live-action-desc">The tactical throwables shop ped (not a convoy checkpoint NPC) — server-wide, not tied to any one convoy's truck list. Only purchasable while a convoy is actually active.</div>
      </div>
      <Toggle label={vendorEnabled ? 'Enabled' : 'Disabled'} checked={vendorEnabled} disabled={togglingVendor} on:change={toggleVendorEnabled} />
    </div>
    {#if vendorEnabled}
      <div class="live-action">
        <div>
          <div class="live-action-title">Vendor Location</div>
          <div class="live-action-desc">
            {#if vendorLocation}Currently at {vendorLocation.x.toFixed(1)}, {vendorLocation.y.toFixed(1)}, {vendorLocation.z.toFixed(1)}{:else}No position recorded yet{/if}
          </div>
        </div>
        <div class="btn-group">
          {#if vendorLocation && $bootstrap?.isAdmin}
            <button class="btn btn-teleport" on:click={teleportToVendor}><Icon name="teleport" size={12} /> Teleport There</button>
          {/if}
          <button class="btn btn-primary" on:click={() => placeWithHologram('vendor')} disabled={moving} title="A see-through copy of the ped follows your crosshair. F freezes it, G puts it on the ground, E confirms.">
            <Icon name="eye" size={13} /> {moving ? 'Placing...' : 'Place with Hologram'}
          </button>
          <button class="btn btn-setpos" on:click={moveVendor} disabled={moving}>
            <Icon name="pin" size={13} /> Use My Position
          </button>
        </div>
      </div>
    {/if}
    {#if moved}<div class="success-flash"><Icon name="check" size={13} /> Vendor moved</div>{/if}

    <div class="section-title">Escort Vehicle Shop</div>
    <div class="live-action">
      <div>
        <div class="live-action-title">Shop ped</div>
        <div class="live-action-desc">The ped police can request an on-demand escort vehicle from — not tied to any one convoy's truck list.</div>
      </div>
      <Toggle label={escortEnabled ? 'Enabled' : 'Disabled'} checked={escortEnabled} disabled={togglingEscort} on:change={toggleEscortEnabled} />
    </div>
    {#if escortEnabled}
      <div class="live-action">
        <div>
          <div class="live-action-title">Escort Shop Location</div>
          <div class="live-action-desc">
            {#if escortLocation}Currently at {escortLocation.x.toFixed(1)}, {escortLocation.y.toFixed(1)}, {escortLocation.z.toFixed(1)}{:else}No position recorded yet{/if}
          </div>
        </div>
        <div class="btn-group">
          {#if escortLocation && $bootstrap?.isAdmin}
            <button class="btn btn-teleport" on:click={teleportToEscortShop}><Icon name="teleport" size={12} /> Teleport There</button>
          {/if}
          <button class="btn btn-primary" on:click={() => placeWithHologram('escort')} disabled={movingEscort} title="A see-through copy of the ped follows your crosshair. F freezes it, G puts it on the ground, E confirms.">
            <Icon name="eye" size={13} /> {movingEscort ? 'Placing...' : 'Place with Hologram'}
          </button>
          <button class="btn btn-setpos" on:click={moveEscortShop} disabled={movingEscort}>
            <Icon name="pin" size={13} /> Use My Position
          </button>
        </div>
      </div>
    {/if}
    {#if escortMoved}<div class="success-flash"><Icon name="check" size={13} /> Escort shop moved</div>{/if}
    {#if error}<div class="error">{error}</div>{/if}
  </div>
</div>

<style>
  .note { font-size: var(--fs-body); color: var(--text-dim); line-height: 1.6; margin-bottom: 6px; }
  .section-title { margin: 18px 0 8px; font-size: var(--fs-small); font-weight: var(--fw-nav); letter-spacing: 0.01em; color: var(--text-main); }
  .live-action { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 14px 16px; border-radius: var(--radius-md); background: var(--tablet-panel-alt); border: 1px solid var(--tablet-border); }
  .live-action + .live-action { margin-top: 10px; }
  .live-action > div:first-child { flex: 1; min-width: 0; }
  .live-action-title { font-size: var(--fs-body); font-weight: 600; color: var(--text-main); }
  .live-action-desc { font-size: var(--fs-small); color: var(--text-dim); margin-top: 3px; max-width: 900px; line-height: 1.5; }
  .btn-group { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
  .success-flash { display: flex; align-items: center; gap: 6px; color: var(--tablet-success); font-size: var(--fs-body); font-weight: 600; margin-top: 10px; }
</style>
