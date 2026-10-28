<script>
  // One territory of a Gang Territory Auction event, as a compact row that opens into a compact editor.
  //
  //   closed:  [colour] [name] [owner] [start bid]  Leader ● placed  [hologram] [teleport]  [open] [up] [down] [remove]
  //            — enough to add a whole map of territories without opening any of them: type a name, pick the owner and
  //            bid, place the Leader Ped with the hologram, next one.
  //   open:    Identity & bidding · War capture · Leader Ped (position, model, colour, map blip).
  //
  // The host (TerritoryConfig.svelte) owns the list and the save: this edits the `ar` object in place and tells the host with
  // on:change; remove / move / rename go up as events.
  import { createEventDispatcher } from 'svelte';
  import { bootstrap } from '../../stores.js';
  import { getPlayerPosition, teleportToPosition, startHarbourPlacer } from '../../api/route.js';
  import { money, gangIndex } from '../../territory/territoryRender.js';
  import { countSpans } from '../../territory/territoryGeometry.js';
  import Icon from './Icon.svelte';
  import Toggle from './Toggle.svelte';
  import PedRow from './PedRow.svelte';
  import '../tablet-theme.css';

  export let ar;
  export let index = 0;
  export let count = 1;
  export let open = false;
  export let locked = false;
  export let availableGangs = [];
  export let pedPool = [];   // model names the "random ped" button picks from

  const dispatch = createEventDispatcher();
  const changed = () => { ar = ar; dispatch('change'); };

  const BLIP_PRESETS = [
    { sprite: 310, label: 'Flag' }, { sprite: 84, label: 'Skull' }, { sprite: 110, label: 'Gun' },
    { sprite: 437, label: 'Bones' }, { sprite: 543, label: 'Crown' }, { sprite: 374, label: 'Castle' },
  ];

  $: ped = ar.capture && ar.capture.ped ? ar.capture.ped : null;
  $: placed = !!ped && ped.x != null;
  $: gangLogo = ar.startingOwner ? (gangIndex(availableGangs)[ar.startingOwner] || {}).logo : '';

  // ── The land the territory STARTS with, and its image ──────────────────────────────────────────────────────────────────
  // A territory is created from this saved area every time the event is published (deleting a territory in the Map Zone does not touch it), so
  // an old painted shape or an old image keeps coming back until it is changed HERE. Gangs then grow the territory by painting.
  $: baseCells = countSpans((ar.base && ar.base.spans) || []);
  $: baseKm2 = (baseCells * 0.000625).toFixed(3);
  function clearArea() { ar.base = { cs: Number(ar.base && ar.base.cs) || 25, spans: [] }; changed(); }
  function clearImage() { ar.image = ''; ar.imagePos = null; changed(); }

  // ── Leader Ped position (hologram · my position · clear) — also moves the map blip, which follows the ped ────────────
  function setPos(p) {
    if (!p || p.x == null) return;
    ar.location = { x: p.x, y: p.y, z: p.z };
    ar.capture.ped.x = p.x;
    ar.capture.ped.y = p.y;
    ar.capture.ped.z = p.z;
    ar.capture.ped.heading = p.heading ?? 0;
    changed();
  }
  async function useMyPosition() { setPos(await getPlayerPosition()); }
  function clearPosition() {
    ar.location = null;
    ar.capture.ped.x = null; ar.capture.ped.y = null; ar.capture.ped.z = null;
    changed();
  }
  function randomizePed() {
    if (!pedPool.length) return;
    ar.capture.ped.model = pedPool[Math.floor(Math.random() * pedPool.length)];
    changed();
  }

  // the closed row's own hologram button (same placer the open card's Leader Ped row uses)
  let placing = false;
  async function quickPlace() {
    if (placing || locked) return;
    placing = true;
    let res = null;
    try { res = await startHarbourPlacer({ kind: 'ped', index: 1, model: ped?.model || '', label: ar.name || ar.id }); } catch (e) { res = null; }
    placing = false;
    if (res && res.ok) setPos({ x: res.x, y: res.y, z: res.z, heading: res.heading });
  }
  function teleport() { if (placed) teleportToPosition(ped.x, ped.y, ped.z, ped.heading || 0); }

  const toggleOpen = () => dispatch('toggle');
  const stop = (e) => e.stopPropagation();
</script>

<div class="tc" class:open>
  <!-- ── the compact row ── -->
  <div class="tc-row">
    <span class="tc-num">{index + 1}</span>
    <input class="tc-color" type="color" title="Territory colour (map ring and blip)" bind:value={ar.color} on:input={changed} disabled={locked} />
    <input class="tc-name" type="text" placeholder="Territory name" bind:value={ar.name} on:input={changed} maxlength="100" disabled={locked} aria-label="Territory name" />
    <select class="tc-owner" bind:value={ar.startingOwner} on:change={changed} disabled={locked} title="Who owns it when the event is created" aria-label="Starting owner">
      <option value="">Neutral</option>
      {#each availableGangs as g (g.id)}<option value={g.name}>{g.label || g.name}</option>{/each}
    </select>
    {#if ar.auctioned !== false}
      <label class="tc-bid" title="Starting bid">
        <span>$</span>
        <input type="number" min="0" bind:value={ar.startingBid} on:input={changed} disabled={locked} aria-label="Starting bid" />
      </label>
    {:else}
      <span class="tc-held" title="Not auctioned: held by the starting owner">Held</span>
    {/if}

    <span class="tc-ped" class:warn={!placed}>
      <Icon name="user" size={13} />
      {#if placed}<span class="tc-ped-t">Leader placed</span>{:else}<span class="tc-ped-t">Leader not placed</span>{/if}
    </span>
    {#if !locked}
      <button type="button" class="tc-ib" title="Place the Leader Ped with the hologram" disabled={placing} on:click={quickPlace}><Icon name="eye" size={14} /></button>
    {/if}
    {#if placed && $bootstrap?.isAdmin}
      <button type="button" class="tc-ib" title="Teleport to the Leader Ped" on:click={teleport}><Icon name="teleport" size={14} /></button>
    {/if}

    <span class="tc-spacer"></span>
    {#if !locked}
      <button type="button" class="tc-ib" title="Move up" disabled={index === 0} on:click={() => dispatch('move', -1)}><Icon name="chevronUp" size={13} /></button>
      <button type="button" class="tc-ib" title="Move down" disabled={index === count - 1} on:click={() => dispatch('move', 1)}><Icon name="chevronDown" size={13} /></button>
      <button type="button" class="tc-ib danger" title="Remove this territory" on:click={() => dispatch('remove')}><Icon name="trash" size={13} /></button>
    {/if}
    <button type="button" class="tc-open" aria-expanded={open} on:click={toggleOpen}>
      {open ? 'Close' : 'Edit'} <Icon name={open ? 'chevronUp' : 'chevronDown'} size={13} />
    </button>
  </div>

  {#if open}
    <div class="tc-body">
      <div class="tc-cols">
        <!-- Identity & bidding -->
        <section class="tc-sec">
          <h4><Icon name="tag" size={13} /> Identity &amp; bidding</h4>
          <div class="tc-grid g3">
            <div class="field"><label>ID <span class="optional">unique</span></label><input type="text" bind:value={ar.id} on:change={() => dispatch('rename')} maxlength="64" disabled={locked} /></div>
            <div class="field"><label>Auction order</label><input type="number" min="1" bind:value={ar.order} on:input={changed} disabled={locked} /></div>
            <div class="field"><label>XP value <span class="optional">on capture</span></label><input type="number" min="0" bind:value={ar.xpValue} on:input={changed} disabled={locked} /></div>
          </div>
          <div class="field"><label>Description <span class="optional">shown to the gangs</span></label><input type="text" bind:value={ar.description} on:input={changed} maxlength="400" placeholder="e.g. Industrial docks and container unloading area" disabled={locked} /></div>
          <div class="tc-grid g3 tc-bidrow">
            <div class="tc-toggle"><Toggle label="Up for auction" bind:checked={ar.auctioned} on:change={changed} disabled={locked} /></div>
            {#if ar.auctioned !== false}
              <div class="field"><label>Starting bid ($)</label><input type="number" min="0" bind:value={ar.startingBid} on:input={changed} disabled={locked} /></div>
              <div class="field"><label>Min. raise ($)</label><input type="number" min="100" bind:value={ar.minBidIncrement} on:input={changed} disabled={locked} /></div>
            {:else}
              <p class="tc-note">Not auctioned: the starting owner holds it from the start.</p>
            {/if}
          </div>
        </section>

        <!-- War capture -->
        <section class="tc-sec">
          <h4><Icon name="crosshair" size={13} /> War capture <span class="tc-sub">around the Leader Ped</span></h4>
          <div class="tc-grid g2">
            <div class="field"><label>Capture time <span class="optional">sec</span></label><input type="number" min="5" max="900" bind:value={ar.capture.seconds} on:input={changed} disabled={locked} /></div>
            <div class="field"><label>Capture radius <span class="optional">m</span></label><input type="number" step="0.5" min="1.5" max="60" bind:value={ar.capture.radius} on:input={changed} disabled={locked} /></div>
            <div class="field"><label>Talk distance <span class="optional">m</span></label><input type="number" step="0.5" min="1" max="10" bind:value={ar.capture.interactDistance} on:input={changed} disabled={locked} /></div>
            <div class="field">
              <label>When contested</label>
              <select bind:value={ar.capture.contestRule} on:change={changed} disabled={locked}>
                <option value="PAUSE">Pause the capture</option>
                <option value="RESET">Reset to zero</option>
                <option value="DECAY">Lose progress over time</option>
              </select>
            </div>
          </div>
        </section>
      </div>

      <!-- Leader Ped -->
      <section class="tc-sec tc-ped-sec">
        <h4><Icon name="user" size={13} /> Leader Ped
          <span class="tc-uses">
            <span class="use" title="Every player sees this spot on the map: sprite, name and owner gang">Map blip</span>
            <span class="use" title="The war's capture point: attackers talk to the Leader Ped and hold the capture radius around it">War capture point</span>
            <span class="use" title="After a war the winning gang loots Gang XP from the Leader Ped">Loot after war</span>
            <span class="use" title="The coloured ring drawn on the ground when players come near">Ground ring</span>
          </span>
        </h4>
        <p class="tc-hint">The gang boss who stands at this territory. Where you place him is where the territory is: the blip on the map, the war's capture point and the ring on the ground.</p>

        {#if ped}
          <PedRow
            compact
            title="Leader Ped"
            pos={placed ? { x: ped.x, y: ped.y, z: ped.z, heading: ped.heading, model: ped.model } : null}
            model={ped.model || ''}
            {locked}
            on:set={(e) => (e.detail ? setPos(e.detail) : useMyPosition())}
            on:clear={clearPosition}
          />

          <div class="tc-grid g-ped">
            <div class="field">
              <label>NPC model</label>
              <div class="tc-inline">
                <input type="text" bind:value={ar.capture.ped.model} on:input={changed} placeholder="e.g. g_m_y_mexgoon_01" disabled={locked} />
                {#if !locked}<button type="button" class="tc-ib" title="Pick a random gang ped" on:click={randomizePed}><Icon name="refresh" size={14} /></button>{/if}
              </div>
            </div>
            <div class="field">
              <label>Territory colour</label>
              <div class="tc-inline">
                <input class="tc-colorbig" type="color" bind:value={ar.color} on:input={changed} disabled={locked} />
                <input type="text" bind:value={ar.color} on:input={changed} maxlength="7" disabled={locked} />
              </div>
            </div>
            <div class="field">
              <label>Blip</label>
              <div class="tc-seg">
                <button type="button" class:active={ar.spriteType !== 'CUSTOM_LOGO'} disabled={locked} on:click={() => { ar.spriteType = 'GTA_SPRITE'; changed(); }}>GTA sprite</button>
                <button type="button" class:active={ar.spriteType === 'CUSTOM_LOGO'} disabled={locked} on:click={() => { ar.spriteType = 'CUSTOM_LOGO'; changed(); }}>Custom logo</button>
              </div>
            </div>
            {#if ar.spriteType !== 'CUSTOM_LOGO'}
              <div class="field"><label>Sprite ID</label><input type="number" min="1" max="900" bind:value={ar.blip.sprite} on:input={changed} disabled={locked} /></div>
              <div class="field"><label>Blip scale</label><input type="number" step="0.05" min="0.3" max="2" bind:value={ar.blip.scale} on:input={changed} disabled={locked} /></div>
              <div class="field tc-presets-f">
                <label>Presets</label>
                <div class="tc-presets">
                  {#each BLIP_PRESETS as p (p.sprite)}
                    <button type="button" class="tc-preset" class:active={Number(ar.blip.sprite) === p.sprite} disabled={locked} title={`Sprite #${p.sprite}`} on:click={() => { ar.blip.sprite = p.sprite; changed(); }}>{p.label}</button>
                  {/each}
                </div>
              </div>
            {:else}
              <div class="field tc-logo-f">
                <label>Logo URL <span class="optional">image shown as the blip badge</span></label>
                <div class="tc-inline">
                  <input type="text" bind:value={ar.customLogo} on:input={changed} maxlength="2048" placeholder="https://…" disabled={locked} />
                  {#if ar.customLogo && ar.customLogo.trim().startsWith('http')}
                    <span class="tc-logo"><img src={ar.customLogo.trim()} alt="Logo preview" on:error={(e) => { e.currentTarget.style.display = 'none'; }} /></span>
                  {:else if gangLogo}
                    <span class="tc-logo" title="The owner gang's logo is used when this is empty"><img src={gangLogo} alt="Owner gang logo" /></span>
                  {/if}
                </div>
              </div>
            {/if}
          </div>
        {/if}
      </section>

      <section class="tc-sec">
        <h4>Starting land and image</h4>
        <div class="tc-area">
          <div class="tc-area-line">
            <span><b>Starting land:</b> {baseCells ? `${baseCells.toLocaleString()} cells (${baseKm2} km²)` : 'none'}</span>
            <span class="tc-area-btns">
              <button type="button" class="tc-mini" disabled={locked || !baseCells} on:click={clearArea}>Clear</button>
            </span>
          </div>
          <div class="tc-area-line">
            <span><b>Territory image:</b> {ar.image ? 'set' : 'none'}</span>
            <input type="text" bind:value={ar.image} on:input={changed} maxlength="2048" placeholder="https://… (shown on the Map Zone)" disabled={locked} />
            {#if ar.image && String(ar.image).trim().startsWith('http')}<span class="tc-logo"><img src={String(ar.image).trim()} alt="Territory image" on:error={(e) => { e.currentTarget.style.display = 'none'; }} /></span>{/if}
            <button type="button" class="tc-mini" disabled={locked || !ar.image} on:click={clearImage}>Remove image</button>
          </div>
          <p class="tc-area-note">Staff do not paint land. A territory starts with no land (or with what is already saved here) and the owning gang paints it, starting from the leader ped. Territories are rebuilt from these values each time the event is published.</p>
        </div>
      </section>
    </div>
  {/if}
</div>

<style>
  .tc { border: 1px solid var(--tablet-border); border-radius: var(--r-panel); background: var(--tablet-panel); margin: 6px 0; overflow: hidden; }
  .tc.open { border-color: var(--tablet-border-strong, var(--tablet-border)); }

  /* the compact row */
  .tc-row { display: flex; align-items: center; gap: 8px; padding: 7px 10px; flex-wrap: wrap; }
  .tc-num { flex: none; width: 22px; text-align: center; font-size: var(--fs-meta); font-weight: 700; color: var(--text-muted, #aeb5bd); }
  .tc-color { flex: none; width: 28px; height: 28px; padding: 1px; border-radius: 7px; cursor: pointer; background: transparent; }
  .tc-name { flex: 1 1 170px; min-width: 130px; max-width: 260px; }
  .tc-owner { flex: 0 1 150px; min-width: 110px; }
  .tc-name, .tc-owner, .tc-bid input { height: 32px; padding: 0 10px; font-size: var(--fs-body); border-radius: var(--r-ctl); }
  .tc-bid { flex: 0 0 118px; display: flex; align-items: center; gap: 4px; margin: 0; }
  .tc-bid span { color: var(--text-muted, #aeb5bd); font-weight: 600; }
  .tc-bid input { width: 100%; min-width: 0; }
  .tc-held { flex: 0 0 118px; font-size: var(--fs-small); color: var(--text-muted, #aeb5bd); }
  .tc-ped { flex: none; display: inline-flex; align-items: center; gap: 5px; height: 26px; padding: 0 9px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600;
    color: #111111; background: rgb(70, 201, 139); border: 1px solid rgb(70, 201, 139); }
  .tc-ped.warn { color: #111111; background: rgb(255, 200, 87); border-color: rgb(255, 200, 87); }
  .tc-spacer { flex: 1; }
  .tc-ib { flex: none; width: 30px; height: 30px; display: inline-grid; place-items: center; border-radius: var(--r-ctl); cursor: pointer;
    color: var(--text-dim, #c9ced4); background: var(--btn-secondary-bg, rgba(255, 255, 255, 0.06)); border: 1px solid var(--btn-secondary-border, var(--tablet-border)); }
  .tc-ib:hover:not(:disabled) { color: var(--lt-ffffff, #fff); border-color: var(--tablet-border-strong, #4f94e6); }
  .tc-ib:disabled { opacity: 0.4; cursor: not-allowed; }
  .tc-ib.danger:hover:not(:disabled) { color: var(--lt-ff8a80, #ff8a80); border-color: #ff5d50; }
  .tc-open { flex: none; display: inline-flex; align-items: center; gap: 5px; height: 30px; padding: 0 12px; border-radius: var(--r-ctl); cursor: pointer;
    font-size: var(--fs-small); font-weight: 600; color: var(--lt-ffffff, #fff); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .tc-open:hover { background: var(--c-hover); }

  /* the open editor */
  .tc-body { padding: 4px 12px 12px; border-top: 1px solid var(--tablet-border); }
  .tc-cols { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 10px; }
  .tc-sec { margin-top: 10px; padding: 10px 12px 12px; border: 1px solid var(--tablet-border); border-radius: var(--r-panel); background: var(--tablet-panel-alt, transparent); }
  .tc-sec h4 { display: flex; align-items: center; flex-wrap: wrap; gap: 7px; margin: 0 0 8px; font-size: var(--fs-small); font-weight: 700; color: var(--lt-ffffff, #fff); }
  .tc-sub { font-weight: 500; font-size: var(--fs-meta); color: var(--text-muted, #aeb5bd); }
  .tc-hint { margin: 0 0 8px; font-size: var(--fs-small); line-height: 1.5; color: var(--text-dim, #c9ced4); }
  .tc-note { margin: 0; align-self: center; grid-column: span 2; font-size: var(--fs-small); color: var(--text-muted, #aeb5bd); }
  .tc-uses { display: inline-flex; gap: 5px; flex-wrap: wrap; margin-left: auto; }
  .use { padding: 2px 9px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; color: var(--lt-bcd9f7, #bcd9f7); background: var(--c-hover); border: 1px solid var(--accent-primary); cursor: help; }

  .tc-grid { display: grid; gap: 8px 10px; }
  .tc-grid > * { min-width: 0; }
  .tc-grid.g2 { grid-template-columns: 1fr 1fr; }
  .tc-grid.g3 { grid-template-columns: 1fr 1fr 1fr; }
  .tc-grid.g-ped { grid-template-columns: 1.3fr 1fr 1.25fr 0.7fr 0.7fr 1.5fr; margin-top: 8px; align-items: end; }
  .tc-bidrow { align-items: end; margin-top: 2px; }
  .tc-toggle { padding-bottom: 6px; }
  .tc-sec :global(.field) { margin: 0; }
  .tc-sec :global(.field label) { margin-bottom: 3px; font-size: var(--fs-meta); }
  .tc-sec :global(.field input), .tc-sec :global(.field select) { height: 32px; padding: 0 10px; font-size: var(--fs-body); width: 100%; min-width: 0; box-sizing: border-box; }
  .tc-sec :global(.field input[type='color']) { padding: 1px; }
  .tc-inline { display: flex; gap: 6px; align-items: center; }
  .tc-inline input[type='text'] { flex: 1; min-width: 0; }
  .tc-inline :global(input[type='color']), .tc-colorbig { flex: none; width: 40px; height: 32px; padding: 1px; cursor: pointer; border-radius: 7px; }
  .tc-seg { display: flex; border: 1px solid var(--tablet-border); border-radius: var(--r-ctl); overflow: hidden; height: 32px; }
  .tc-seg button { flex: 1; padding: 0 8px; font-size: var(--fs-meta); white-space: nowrap; font-weight: 600; cursor: pointer; color: var(--text-dim, #c9ced4); background: transparent; border: 0; }
  .tc-seg button.active { color: var(--on-accent); background: var(--c-action); }
  .tc-presets { display: flex; gap: 5px; flex-wrap: wrap; min-height: 32px; align-items: center; }
  .tc-preset { padding: 3px 9px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; cursor: pointer; color: var(--text-dim, #c9ced4); background: transparent; border: 1px solid var(--tablet-border); }
  .tc-preset:hover:not(:disabled) { color: var(--lt-ffffff, #fff); border-color: var(--tablet-border-strong, #4f94e6); }
  .tc-preset.active { color: var(--on-accent); background: var(--c-action); border-color: var(--accent-primary); }
  .tc-area { display: flex; flex-direction: column; gap: 10px; }
  .tc-area-line { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; font-size: var(--fs-small); }
  .tc-area-line input { flex: 1 1 260px; min-width: 200px; }
  .tc-area-btns { margin-left: auto; display: inline-flex; gap: 8px; }
  .tc-mini { height: 32px; padding: 0 12px; border-radius: var(--r-ctl); border: 1px solid var(--tablet-border); background: var(--glass-head, transparent); color: var(--text-main, #fff); font-size: var(--fs-small); font-weight: 600; cursor: pointer; }
  .tc-mini:hover:not(:disabled) { border-color: var(--accent-primary); }
  .tc-mini:disabled { opacity: 0.45; cursor: not-allowed; }
  .tc-area-note { margin: 0; font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .tc-logo-f { grid-column: span 5; }
  .tc-logo { flex: none; width: 32px; height: 32px; display: grid; place-items: center; overflow: hidden; border-radius: var(--r-ctl); border: 1px solid var(--tablet-border); }
  .tc-logo img { max-width: 100%; max-height: 100%; object-fit: contain; }

  @media (max-width: 1150px) {
    .tc-cols { grid-template-columns: 1fr; }
    .tc-grid.g-ped { grid-template-columns: 1fr 1fr 1fr; }
    .tc-logo-f { grid-column: span 3; }
  }
</style>
