<script>
  // Operation Crackdown (Gang vs Police) — the admin form. Three sections, picked by the Create Event tabs:
  //   setup   : name, briefing, target gang, preparation time, duration
  //   zone    : the combat zone (circle or square) on a big map, and the two start areas (a box for the gang, a box for the police)
  //   rewards : the rules (outside-the-zone timer, minimum fighters) and the rewards: the gang's reward, the police reward, the gang's penalty
  //             for losing. The announcement texts are built by the script (Config.Crackdown.messages), not typed here.
  // There is NO police team to pick and NO points: the police are whoever is on duty when the fight opens (decided by the server), and a
  // fighter who goes down or stays outside the zone is eliminated; the side with fighters left wins.
  import { onDestroy } from 'svelte';
  import { getPlayerPosition, getGroundZ, teleportToPosition, previewContainerWarsZone, drawContainerWarsPerimeter } from '../../api/route.js';
  import { zoneRecordingResult } from '../../stores.js';
  import FormSectionHead from '../ui/FormSectionHead.svelte';
  import RewardListEditor from '../ui/RewardListEditor.svelte';
  import RoutePreviewMap from '../ui/RoutePreviewMap.svelte';
  import Icon from '../ui/Icon.svelte';
  import '../tablet-theme.css';

  // the zone map is as big as the Map Zone's: most of the window's height
  const mapHeight = typeof window !== 'undefined' ? Math.max(520, Math.min(880, Math.round(window.innerHeight * 0.62))) : 600;

  export let section = 'setup';
  export let form;
  export let locked = false;
  export let availableGangs = [];

  const D = { prepSeconds: 120, outsideSeconds: 30, minGang: 1, minPolice: 1, gangLoseXpPenalty: 0 };

  // an event saved before this kind existed (or a fresh form) has no crackdown block, or only part of it
  function shape0() {
    const c = form.crackdown && typeof form.crackdown === 'object' ? form.crackdown : {};
    for (const k of Object.keys(D)) if (c[k] == null) c[k] = D[k];
    if (!c.zone || typeof c.zone !== 'object') c.zone = {};
    if (!c.messages || typeof c.messages !== 'object') c.messages = {};
    if (!Array.isArray(c.policeReward)) c.policeReward = [];
    if (!c.startZones || typeof c.startZones !== 'object') c.startZones = {};
    if (typeof c.targetGang !== 'string') c.targetGang = '';
    return c;
  }
  form.crackdown = shape0();
  $: cd = form.crackdown;
  $: zone = cd.zone;
  // every edit goes through here so the parent form (draft copy, checklist) hears about it
  function set(key, value) { form.crackdown[key] = value; form = form; }
  function commitZone() { form.crackdown.zone = { ...form.crackdown.zone }; form = form; }
  $: shape = zone.shape === 'square' ? 'square' : 'circle';
  $: placed = !!(zone.center && Number.isFinite(Number(zone.center.x)));
  $: mapZones = placed ? [{ id: 'cd-zone', x: Number(zone.center.x), y: Number(zone.center.y), z: Number(zone.center.z) || 0, label: 'Combat zone' }] : [];
  $: mapShape = { shape, radius: Number(zone.radius) || 120, size: Number(zone.size) || 120 };

  // ── start areas: only fighters standing inside their own box when the countdown ends take part (drawn with the same in-game perimeter tool as the other zones)
  const AREAS = [
    { key: 'gang', target: 'CRACKDOWN_GANG_BOX', color: '#f97316' },
    { key: 'police', target: 'CRACKDOWN_POLICE_BOX', color: '#3b82f6' },
  ];
  const pointsOf = (key) => (cd.startZones && cd.startZones[key] && cd.startZones[key].points) || [];
  function statsOf(pts) {
    if (pts.length < 3) return null;
    let a = 0, x1 = Infinity, x2 = -Infinity, y1 = Infinity, y2 = -Infinity;
    pts.forEach((p, i) => {
      const q = pts[(i + 1) % pts.length];
      a += p.x * q.y - q.x * p.y;
      x1 = Math.min(x1, p.x); x2 = Math.max(x2, p.x); y1 = Math.min(y1, p.y); y2 = Math.max(y2, p.y);
    });
    return { area: Math.round(Math.abs(a) / 2), w: Math.round(x2 - x1), h: Math.round(y2 - y1) };
  }
  $: areaRows = AREAS.map((a) => {
    const pts = (cd.startZones && cd.startZones[a.key] && cd.startZones[a.key].points) || [];
    return { ...a, pts, ready: pts.length >= 3, stats: statsOf(pts), title: a.key === 'gang' ? `${gangLabel || 'Gang'} start area` : 'Police start area' };
  });
  $: overlays = areaRows.filter((a) => a.ready).map((a) => ({ label: a.title, color: a.color, points: a.pts }));
  let drawing = null;
  let busyArea = false;
  async function drawArea(a) {
    if (locked || drawing) return;
    drawing = a.key;
    // the game answers when the drawing ends (saved, cancelled with Esc, or the editor was busy): the button must always come back
    try { await drawContainerWarsPerimeter({ target: a.target }); } catch (e) { /* no game behind the page */ } finally { drawing = null; }
  }
  function clearArea(a) { if (locked) return; form.crackdown.startZones = { ...form.crackdown.startZones, [a.key]: undefined }; form = form; }
  async function previewArea(a, tp) {
    if (!a.ready || busyArea) return;
    busyArea = true;
    try {
      const p = a.pts[0];
      if (tp) await teleportToPosition(p.x, p.y, p.z || 6.0);
      await previewContainerWarsZone(a.pts, p.z || 6.0);
    } finally { busyArea = false; }
  }
  function removeAreaPoint(a, i) {
    if (locked) return;
    const pts = a.pts.filter((_, k) => k !== i);
    form.crackdown.startZones = { ...form.crackdown.startZones, [a.key]: pts.length ? { points: pts } : undefined };
    form = form;
  }
  const unsubRec = zoneRecordingResult.subscribe((msg) => {
    if (!msg) return;
    const a = AREAS.find((x) => x.target === msg.target);
    if (!a) return;
    const points = (msg.points || []).slice(0, 24).map((p) => ({ x: p.x, y: p.y, z: p.z }));
    form.crackdown.startZones = { ...form.crackdown.startZones, [a.key]: points.length >= 3 ? { points } : undefined };
    form = form;
    drawing = null;
    zoneRecordingResult.set(null);
  });
  onDestroy(unsubRec);

  // minutes <-> the event's duration (seconds)
  $: minutes = Math.max(1, Math.round((Number(form.eventDuration) || 1200) / 60));
  function setMinutes(e) { form.eventDuration = Math.max(1, Math.min(120, Math.floor(Number(e.target.value) || 20))) * 60; }

  const num = (v, min, max, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.max(min, Math.min(max, n));
  };

  function setShape(next) {
    if (locked) return;
    const z = form.crackdown.zone;
    z.shape = next;
    if (z.radius == null) z.radius = 120;
    if (z.size == null) z.size = 120;
    commitZone();
  }
  function setCenter(x, y, z) {
    const zn = form.crackdown.zone;
    zn.shape = zn.shape === 'square' ? 'square' : 'circle';
    if (zn.radius == null) zn.radius = 120;
    if (zn.size == null) zn.size = 120;
    zn.center = { x: Number(Number(x).toFixed(2)), y: Number(Number(y).toFixed(2)), z: Number.isFinite(Number(z)) ? Number(Number(z).toFixed(2)) : (zn.center?.z || 0) };
    commitZone();
  }
  async function useMyPosition() {
    if (locked) return;
    const pos = await getPlayerPosition();
    if (pos && pos.x != null) setCenter(pos.x, pos.y, pos.z);
  }
  // a click on the map only knows x/y: the centre is saved at once, then the game gives the real ground height (a late answer for an older click is dropped)
  let clickToken = 0;
  async function onMapClick(e) {
    if (locked || !e.detail) return;
    const { x, y } = e.detail;
    const token = ++clickToken;
    setCenter(x, y, zone.center?.z);
    try {
      const g = await getGroundZ(x, y, undefined);
      if (g && g.found && Number.isFinite(Number(g.z)) && token === clickToken) setCenter(x, y, g.z);
    } catch (err) { /* no game behind the page */ }
  }
  function onMapMove(e) { if (!locked && e.detail && e.detail.x != null) setCenter(e.detail.x, e.detail.y, e.detail.z ?? zone.center?.z); }
  function setField(key, v) { const zn = form.crackdown.zone; zn.center = { ...(zn.center || { x: 0, y: 0, z: 0 }), [key]: Number(v) || 0 }; commitZone(); }
  async function teleport() { if (placed) await teleportToPosition(zone.center.x, zone.center.y, zone.center.z, 0); }
  // draws the zone in the game world (the same preview the other zones use: the polygon is rebuilt from the shape)
  async function preview() {
    if (!placed) return;
    const c = zone.center;
    let pts = [];
    if (shape === 'square') {
      const h = Number(zone.size) || 120;
      pts = [{ x: c.x - h, y: c.y - h, z: c.z }, { x: c.x + h, y: c.y - h, z: c.z }, { x: c.x + h, y: c.y + h, z: c.z }, { x: c.x - h, y: c.y + h, z: c.z }];
    } else {
      const r = Number(zone.radius) || 120;
      for (let i = 0; i < 24; i++) { const a = (i / 24) * Math.PI * 2; pts.push({ x: c.x + Math.cos(a) * r, y: c.y + Math.sin(a) * r, z: c.z }); }
    }
    await previewContainerWarsZone(pts, c.z || 6.0);
  }

  $: gangLabel = (availableGangs.find((g) => g.name === cd.targetGang) || {}).label || cd.targetGang;

</script>

{#if section === 'setup'}
  <FormSectionHead title="Operation" hint="Gang vs Police — no team to assign: the police on duty are recognised automatically" />
  <div class="field">
    <label>Operation Name</label>
    <input type="text" bind:value={form.name} maxlength="100" placeholder="Operation Crackdown" disabled={locked} />
  </div>
  <div class="field">
    <label>Short Description <span class="optional">one line shown in event lists</span></label>
    <input type="text" bind:value={form.shortDescription} maxlength="255" placeholder="e.g. The police move on the Ballas" disabled={locked} />
  </div>
  <div class="field">
    <label>Briefing <span class="optional">rules and what is at stake</span></label>
    <textarea bind:value={form.detailedDescription} maxlength="4000" placeholder="Full briefing for both sides" disabled={locked}></textarea>
  </div>

  <FormSectionHead title="Target Gang" hint="the gang the police move against" />
  <div class="field">
    <label>Gang</label>
    <select bind:value={form.crackdown.targetGang} disabled={locked}>
      <option value="">— pick the target gang —</option>
      {#each availableGangs as g (g.id ?? g.name)}<option value={g.name}>{g.label || g.name}</option>{/each}
    </select>
    <p class="field-hint" style="margin-top:4px;">Every online member of this gang fights. Anyone on a police job who is on duty fights for the police (also a police officer who is in this gang).</p>
  </div>

  <FormSectionHead title="Timing" />
  <div class="field-row">
    <div class="field">
      <label>Preparation Time <span class="optional">seconds before the fight opens</span></label>
      <input type="number" min="10" max="1800" value={cd.prepSeconds} on:change={(e) => set('prepSeconds', num(e.target.value, 10, 1800, 120))} disabled={locked} />
    </div>
    <div class="field">
      <label>Fight Duration <span class="optional">minutes</span></label>
      <input type="number" min="1" max="120" value={minutes} on:change={setMinutes} disabled={locked} />
    </div>
  </div>

{:else if section === 'zone'}
  <FormSectionHead title="Combat Zone" hint="circle or square — click the map, drag the pin, or stand there and use your position" />
  <div class="field">
    <label>Shape</label>
    <div class="cd-actions">
      <button type="button" class="btn" class:btn-primary={shape === 'circle'} disabled={locked} on:click={() => setShape('circle')}>Circle</button>
      <button type="button" class="btn" class:btn-primary={shape === 'square'} disabled={locked} on:click={() => setShape('square')}>Square</button>
    </div>
  </div>
  <div class="field-row">
    {#if shape === 'circle'}
      <div class="field">
        <label>Radius <span class="optional">metres</span></label>
        <input type="number" min="15" max="600" value={zone.radius ?? 120} on:change={(e) => { form.crackdown.zone.radius = num(e.target.value, 15, 600, 120); commitZone(); }} disabled={locked} />
      </div>
    {:else}
      <div class="field">
        <label>Half-side <span class="optional">metres (the square is twice this wide)</span></label>
        <input type="number" min="15" max="600" value={zone.size ?? 120} on:change={(e) => { form.crackdown.zone.size = num(e.target.value, 15, 600, 120); commitZone(); }} disabled={locked} />
      </div>
    {/if}
    <div class="field">
      <label>Centre</label>
      <div class="cd-actions">
        <button type="button" class="btn btn-steel" on:click={useMyPosition} disabled={locked}><Icon name="pin" size={13} /> Use my position</button>
        <button type="button" class="btn btn-steel" on:click={teleport} disabled={!placed}><Icon name="teleport" size={13} /> Teleport</button>
        <button type="button" class="btn btn-steel" on:click={preview} disabled={!placed}><Icon name="eye" size={13} /> Preview in game</button>
      </div>
    </div>
  </div>
  <div class="cd-xyz">
    <div class="field"><label>X</label><input type="number" step="0.1" value={zone.center?.x ?? ''} on:change={(e) => setField('x', e.target.value)} disabled={locked} /></div>
    <div class="field"><label>Y</label><input type="number" step="0.1" value={zone.center?.y ?? ''} on:change={(e) => setField('y', e.target.value)} disabled={locked} /></div>
    <div class="field"><label>Z</label><input type="number" step="0.1" value={zone.center?.z ?? ''} on:change={(e) => setField('z', e.target.value)} disabled={locked} /></div>
  </div>
  <div class="cd-map">
    <RoutePreviewMap
      zones={mapZones}
      zoneShape={mapShape}
      {overlays}
      eventKind="GANG_AIRDROP"
      legend={false}
      height={mapHeight}
      editable={!locked}
      on:mapClick={onMapClick}
      on:pointMove={onMapMove}
    />
  </div>
  {#if !placed}<p class="field-hint">Click the map to place the zone's centre.</p>{/if}

  <FormSectionHead title="Start Areas" hint="a box for the gang and a box for the police — only fighters standing inside their own box when the countdown ends take part and are paid" />
  <div class="cd-areas">
    {#each areaRows as a (a.key)}
      <div class="cd-area" style="--ac: {a.color};">
        <div class="cd-area-head"><span class="cd-chip"></span><b>{a.title}</b><em>{a.ready ? 'drawn' : 'not drawn'}</em></div>
        <div class="zone-row">
          <div class="zone-stats">
            {#if a.stats}
              <div><b>{a.stats.area.toLocaleString()}</b><span>m² area</span></div>
              <div><b>{a.stats.w} × {a.stats.h}</b><span>m bounding box</span></div>
              <div><b>{a.pts.length}</b><span>perimeter vertices</span></div>
            {:else}
              <p class="field-hint" style="margin:0">Click <b>Draw Perimeter</b>, aim at ground corners and left-click to drop the corners of the box.</p>
            {/if}
          </div>
          <div class="cd-actions">
            <button type="button" class="btn btn-sm btn-preview" on:click={() => drawArea(a)} disabled={locked || !!drawing}>
              <Icon name="flag" size={12} /><span>{drawing === a.key ? 'Drawing…' : (a.ready ? 'Redraw Perimeter' : 'Draw Perimeter')}</span>
            </button>
            {#if a.ready}
              <button type="button" class="btn btn-sm btn-refresh" on:click={() => previewArea(a, false)} disabled={busyArea}><Icon name="eye" size={12} /><span>Preview Here</span></button>
              <button type="button" class="btn btn-sm" on:click={() => previewArea(a, true)} disabled={busyArea}><Icon name="teleport" size={12} /><span>Teleport &amp; Preview</span></button>
              <button type="button" class="btn btn-sm btn-danger" on:click={() => clearArea(a)} disabled={locked}><Icon name="trash" size={12} /><span>Clear</span></button>
            {/if}
          </div>
        </div>
        {#if a.pts.length > 0}
          <div class="zone-points-list">
            {#each a.pts as p, i}
              <div class="zone-point-pill">
                <span class="pt-idx">#{i + 1}</span>
                <span class="pt-coord">{Number(p.x).toFixed(1)}, {Number(p.y).toFixed(1)}, {Number(p.z || 0).toFixed(1)}</span>
                <button type="button" class="btn-icon" title="Teleport" on:click={() => teleportToPosition(p.x, p.y, p.z || 6.0, 0)}><Icon name="teleport" size={11} /></button>
                <button type="button" class="btn-icon danger" title="Remove" disabled={locked} on:click={() => removeAreaPoint(a, i)}><Icon name="close" size={11} /></button>
              </div>
            {/each}
          </div>
        {/if}
      </div>
    {/each}
  </div>
  <p class="field-hint">Draw each box with the same in-game tool as the other zones: left-click to drop the corners, Enter to save. When the preparation countdown ends, a gang member or officer who is not standing inside their own box is left out of the operation (and is not paid). A side with no box drawn is not restricted. The boxes are shown in the world and on the map during the countdown (the gang's in orange, the police's in blue).</p>


{:else if section === 'rewards'}
  <FormSectionHead title="Rules" hint="a hard push from both sides: no points, anyone who goes down is eliminated" />
  <div class="field-row">
    <div class="field">
      <label>Time Outside The Zone <span class="optional">seconds before a fighter is eliminated</span></label>
      <input type="number" min="5" max="300" value={cd.outsideSeconds} on:change={(e) => set('outsideSeconds', num(e.target.value, 5, 300, 30))} disabled={locked} />
    </div>
  </div>
  <div class="field-row">
    <div class="field">
      <label>Minimum Gang Members <span class="optional">there when the fight opens</span></label>
      <input type="number" min="0" max="50" value={cd.minGang} on:change={(e) => set('minGang', num(e.target.value, 0, 50, 1))} disabled={locked} />
    </div>
    <div class="field">
      <label>Minimum Police On Duty <span class="optional">there when the fight opens</span></label>
      <input type="number" min="0" max="50" value={cd.minPolice} on:change={(e) => set('minPolice', num(e.target.value, 0, 50, 1))} disabled={locked} />
    </div>
  </div>
  <p class="field-hint">Who fights is decided during the preparation countdown and locked when the fight opens: gang members present and officers on duty. Anyone who dies (or is downed) or stays outside the zone too long is eliminated — they respawn or get revived by EMS as usual, but they are out and cannot shoot inside the zone. The side with fighters left when the other has none wins. At the time limit the side with more fighters standing wins; equal numbers are a draw (nobody is paid). If either side is below its minimum when the countdown ends, the operation ends as "no contest".</p>

  <FormSectionHead title="If {gangLabel || 'the gang'} wins" hint="paid to every member of the gang who fought" />
  <div class="field">
    <label>Gang Reward <span class="optional">money, items, vehicle or Gang XP</span></label>
    <RewardListEditor bind:rewards={form.reward} disabled={locked} allowVehicle={true} />
  </div>

  <FormSectionHead title="If the Police win" hint="paid to every officer who fought" />
  <div class="field">
    <label>Police Reward <span class="optional">money or items (police never earn Gang XP)</span></label>
    <RewardListEditor bind:rewards={form.crackdown.policeReward} disabled={locked} />
  </div>
  <div class="field">
    <label>Gang XP Lost By The Gang <span class="optional">taken from the target gang when the police win · 0 = none</span></label>
    <input type="number" min="0" max="1000000" value={cd.gangLoseXpPenalty} on:change={(e) => set('gangLoseXpPenalty', num(e.target.value, 0, 1000000, 0))} disabled={locked} />
  </div>
{/if}

<style>
  .cd-xyz { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
  .cd-actions { display: flex; flex-wrap: wrap; gap: 8px; }
  .cd-areas + .field-hint { margin-top: 12px; }
  .cd-areas { display: grid; grid-template-columns: 1fr; gap: 12px; }
  .cd-area { border: 1px solid var(--c-line); border-left: 4px solid var(--ac); border-radius: var(--r-panel); padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; }
  .cd-area-head { display: flex; align-items: center; gap: 10px; }
  .cd-area-head b { font-size: 13px; }
  .cd-area-head em { margin-left: auto; font-style: normal; font-size: 11.5px; opacity: 0.7; }
  .cd-area .zone-row { display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
  .zone-stats { display: flex; gap: 22px; flex: 1; min-width: 200px; }
  .zone-stats div { display: flex; flex-direction: column; }
  .zone-stats div b { font-size: var(--fs-title); font-weight: 700; line-height: 1.1; font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .zone-stats span { font-size: var(--fs-meta); color: var(--text-dim); }
  .zone-points-list { display: flex; flex-wrap: wrap; gap: 6px; }
  .zone-point-pill { display: inline-flex; align-items: center; gap: 6px; padding: 4px 8px; border: 1px solid var(--c-line); border-radius: var(--r-tag); font-size: var(--fs-meta); }
  .pt-idx { font-weight: 700; color: var(--ac); }
  .pt-coord { font-family: var(--font-mono); color: var(--text-dim); }
  .btn-icon { background: transparent; border: none; padding: 2px 4px; color: var(--text-dim); cursor: pointer; border-radius: var(--r-tag); display: inline-flex; align-items: center; }
  .btn-icon:hover { background: rgba(255, 255, 255, 0.1); }
  .btn-icon.danger:hover { color: var(--tablet-danger); background: rgba(239, 68, 68, 0.15); }
  .cd-chip { width: 12px; height: 12px; border-radius: 3px; background: var(--ac); flex: none; }
  .cd-map { margin: 10px 0 6px; border: 1px solid var(--c-line); border-radius: var(--r-panel); overflow: hidden; }
  .field-hint { font-size: var(--fs-small); color: var(--text-dim); }
</style>
