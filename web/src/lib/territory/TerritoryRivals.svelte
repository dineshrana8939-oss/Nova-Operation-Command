<script>
  import { defaultPageSize } from '../adminPrefs.js';
  // Admin: the Rivals section of the Gang Territory event (and of Territory Control). Every rival challenge, its status,
  // and the admin's actions: Set War Date (date / time / duration / XP penalty), View Map, Manage, Cancel, and a manual
  // Start. It updates live — a gang sending / answering a challenge, a war starting or ending, appears here at once.
  import { onMount, onDestroy } from 'svelte';
  import { territoryState, refreshTerritoryState, refreshRivals } from './territoryStore.js';
  import { adminScheduleWar, adminStartWar, adminCancelRival, adminRespondRival, adminSetWarZone, adminAnnounceRival } from '../api/territory.js';
  import { getPlayerPosition, teleportToPosition, previewWarZone } from '../api/route.js';
  import { bootstrap } from '../stores.js';
  import { confirmAction } from '../tablet/ui/confirm.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import TablePager from '../tablet/ui/TablePager.svelte';
  import DateTimePicker from '../tablet/ui/DateTimePicker.svelte';
  import TerritoryMap from './TerritoryMap.svelte';
  import { viewToRender } from './territoryRender.js';
  import '../tablet/tablet-theme.css';

  export let embedded = false;

  let filter = 'OPEN';          // OPEN | ALL
  let busy = null;
  let error = '';
  let notice = '';
  let openId = null;            // the "Manage" panel
  let mapFor = null;            // rival whose map is shown
  let schedFor = null;          // rival being scheduled
  let schedDate = '';
  let schedMinutes = 15;
  let schedPenalty = '';
  let now = Math.floor(Date.now() / 1000);
  let timer;

  const OPEN = ['PENDING', 'ACCEPTED', 'SCHEDULED', 'ACTIVE'];
  const STATUS_CLASS = { PENDING: 'badge-draft', ACCEPTED: 'badge-scheduled', SCHEDULED: 'badge-starting', ACTIVE: 'badge-under-attack', COMPLETED: 'badge-completed', DECLINED: 'badge-cancelled', CANCELLED: 'badge-cancelled' };
  const STATUS_TEXT = { PENDING: 'Pending', ACCEPTED: 'Accepted', SCHEDULED: 'Scheduled', ACTIVE: 'Active', COMPLETED: 'Completed', DECLINED: 'Declined', CANCELLED: 'Cancelled' };

  onMount(() => {
    refreshTerritoryState();
    timer = setInterval(() => { now = Math.floor(Date.now() / 1000); }, 1000);
  });
  onDestroy(() => clearInterval(timer));
  // (the store already refetches the challenge list whenever the server says it changed)

  $: rivals = ($territoryState.rivals || []).filter((r) => filter === 'ALL' || OPEN.includes(r.status));
  let rPage = 1;
  let rSize = defaultPageSize([5, 10, 15, 25, 50]);
  $: pagedRivals = rivals.slice((rPage - 1) * rSize, rPage * rSize);
  const resetRPage = () => { rPage = 1; };
  $: resetRPage(filter);
  $: cfg = $bootstrap?.territory?.war || {};
  $: if (schedFor && !schedMinutes) schedMinutes = cfg.defaultDurationMinutes || 15;
  $: gangs = $territoryState.gangs || [];

  const fmtClock = (s) => `${String(Math.floor(Math.max(0, s) / 60)).padStart(2, '0')}:${String(Math.max(0, s) % 60).padStart(2, '0')}`;
  const fmtDate = (ts) => (ts ? new Date(ts * 1000).toLocaleString() : 'Not scheduled');

  function openSchedule(r) {
    schedFor = r; error = '';
    schedMinutes = r.durationSec ? Math.round(r.durationSec / 60) : (cfg.defaultDurationMinutes || 15);
    schedPenalty = r.penaltyXp != null ? String(r.penaltyXp) : '';
    const base = new Date(Date.now() + 3600 * 1000);
    const p = (n) => String(n).padStart(2, '0');
    schedDate = `${base.getFullYear()}-${p(base.getMonth() + 1)}-${p(base.getDate())}T${p(base.getHours())}:00`;
  }
  async function saveSchedule() {
    if (!schedFor) return;
    busy = 'sched'; error = '';
    const res = await adminScheduleWar(schedFor.id, schedDate, schedMinutes, schedPenalty === '' ? null : Number(schedPenalty));
    busy = null;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not schedule the war.'; return; }
    notice = `War scheduled — both gangs and the server have been notified.`;
    schedFor = null;
    refreshRivals();
  }
  // answer a PENDING challenge for the challenged gang (an administrator accepts or declines on its behalf)
  async function answer(r, accept) {
    const ok = await confirmAction(accept
      ? `Accept the challenge for ${r.territoryName} on behalf of ${r.defenderLabel}?

${r.attackerLabel} vs ${r.defenderLabel}. Both gangs are told an administrator accepted it; you then set the war date.`
      : `Decline the challenge for ${r.territoryName} on behalf of ${r.defenderLabel}?

Both gangs are told an administrator declined it.`,
      { title: accept ? 'Accept for the gang' : 'Decline for the gang', confirmLabel: accept ? 'Accept' : 'Decline', danger: !accept });
    if (!ok) return;
    busy = r.id; error = '';
    const res = await adminRespondRival(r.id, accept);
    busy = null;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not answer the challenge.'; return; }
    notice = accept ? 'Accepted for ' + r.defenderLabel + ' - set the war date next.' : 'Declined for ' + r.defenderLabel + '.';
    refreshRivals();
  }
  async function startNow(r) {
    const ok = await confirmAction(`Start the war for ${r.territoryName} now?\n\n${r.attackerLabel} vs ${r.defenderLabel}. Both gangs are told it is starting.`, { title: 'Start war now', confirmLabel: 'Start war' });
    if (!ok) return;
    busy = r.id; error = '';
    const res = await adminStartWar(r.id);
    busy = null;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not start the war.'; return; }
    refreshRivals();
  }
  async function cancel(r) {
    const live = r.status === 'ACTIVE';
    const ok = await confirmAction(`Cancel ${r.attackerLabel} vs ${r.defenderLabel} for ${r.territoryName}?${live ? '\n\nThe war is running — it ends now with no winner and no penalty; the owner keeps the territory.' : ''}`, { title: 'Cancel challenge', danger: true, confirmLabel: 'Cancel it' });
    if (!ok) return;
    busy = r.id; error = '';
    const res = await adminCancelRival(r.id, 'Cancelled by an administrator.');
    busy = null;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not cancel.'; return; }
    refreshRivals();
  }

  // ── leader ped, war zone, announcement ───────────────────────────────────────────────────────────────────────────────
  // where the leader ped of the battleground stands (the territory's ped, else its marker, else its centre)
  function leaderPos(r) {
    const t = ($territoryState.territories || []).find((x) => x.id === r.territoryId);
    const p = t && ((t.ped && t.ped.x != null && t.ped) || (t.location && t.location.x != null && t.location) || (t.center && t.center.x != null && t.center));
    return p ? { x: Number(p.x), y: Number(p.y), z: Number(p.z || 0), heading: Number(p.heading || 0) } : null;
  }
  function teleportLeader(r) {
    const p = leaderPos(r);
    if (!p) { error = 'This territory has no leader ped placed yet.'; return; }
    error = '';
    teleportToPosition(p.x, p.y, p.z + 1.0, p.heading);
  }

  let zoneFor = null;            // the challenge whose war zone is being drawn
  let zShape = 'circle';
  let zSize = 120;
  let zX = 0; let zY = 0; let zZ = 0;
  let zoneNote = '';
  const zoneMax = () => (zShape === 'square' ? 450 : 600);
  const num = (v) => (v === '' || v == null || Number.isNaN(Number(v)) ? 0 : Number(v));
  function openZone(r) {
    zoneFor = r; error = ''; zoneNote = '';
    if (r.zone) { zShape = r.zone.shape; zSize = Math.round(r.zone.size); zX = r.zone.x; zY = r.zone.y; zZ = r.zone.z; }
    else {
      const p = leaderPos(r);
      zShape = 'circle'; zSize = 120;
      zX = p ? p.x : 0; zY = p ? p.y : 0; zZ = p ? p.z : 0;
    }
  }
  function zoneCenterLeader() { const p = leaderPos(zoneFor); if (p) { zX = p.x; zY = p.y; zZ = p.z; zoneNote = 'Centre set to the leader ped.'; } else zoneNote = 'This territory has no leader ped placed yet.'; }
  async function zoneCenterMe() {
    const pos = await getPlayerPosition();
    if (!pos || pos.x == null) { zoneNote = 'The game did not answer — is the resource running?'; return; }
    zX = Number(Number(pos.x).toFixed(2)); zY = Number(Number(pos.y).toFixed(2)); zZ = Number((Number(pos.z) - 1.0).toFixed(2));
    zoneNote = 'Centre set to where you stand.';
  }
  // stand at the edge you want, press this: the size becomes the distance from the centre to you
  async function zoneSizeFromMe() {
    const pos = await getPlayerPosition();
    if (!pos || pos.x == null) { zoneNote = 'The game did not answer — is the resource running?'; return; }
    const dx = Math.abs(Number(pos.x) - num(zX)); const dy = Math.abs(Number(pos.y) - num(zY));
    const d = zShape === 'square' ? Math.max(dx, dy) : Math.sqrt(dx * dx + dy * dy);
    zSize = Math.max(20, Math.min(zoneMax(), Math.round(d)));
    zoneNote = `Size set to ${zSize} m (your distance from the centre).`;
  }
  const zoneBody = () => ({ shape: zShape, x: num(zX), y: num(zY), z: num(zZ), size: Math.max(20, Math.min(zoneMax(), num(zSize))) });
  function zonePreview() {
    const z = zoneBody();
    zoneNote = 'The tablet steps aside and the zone is drawn in green for about 30 seconds: go and look at its edge. Press ENTER to come back to the tablet.';
    previewWarZone(z.x, z.y, z.z, z.shape, z.size);
  }
  async function zoneSave() {
    busy = 'zone'; error = '';
    const res = await adminSetWarZone(zoneFor.id, zoneBody());
    busy = null;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not save the zone.'; return; }
    notice = 'War zone saved. It appears in the world only when this war starts.';
    zoneFor = null;
    refreshRivals();
  }
  async function zoneClear() {
    busy = 'zone'; error = '';
    const res = await adminSetWarZone(zoneFor.id, null);
    busy = null;
    if (!res || !res.ok) { error = (res && res.error) || 'Could not clear the zone.'; return; }
    notice = 'War zone removed: this war uses the normal round ring around the leader ped.';
    zoneFor = null;
    refreshRivals();
  }

  let annFor = null;
  let annTitle = '';
  let annBody = '';
  let annNote = '';
  function openAnnounce(r) {
    annFor = r; error = ''; annNote = '';
    annTitle = `RIVAL WAR: ${r.attackerLabel} vs ${r.defenderLabel}`;
    const when = (r.status === 'SCHEDULED' || r.status === 'ACTIVE') ? (r.warAtText || fmtDate(r.warAt)) : 'the date will be announced';
    annBody = `The war for ${r.territoryName} — ${when}. Both gangs are responsible for being present.`;
  }
  async function annPreview() {
    annNote = '';
    const res = await adminAnnounceRival(annFor.id, annTitle, annBody, true);
    if (!res || !res.ok) { annNote = (res && res.error) || 'Could not preview.'; return; }
    annNote = 'Showing the banner to you. The tablet steps aside for a moment.';
  }
  async function annSend() {
    const ok = await confirmAction(`Send this announcement to the members of ${annFor.attackerLabel} and ${annFor.defenderLabel} only?\n\n"${annTitle}"\n${annBody}`, { title: 'Announce to both gangs', confirmLabel: 'Send' });
    if (!ok) return;
    busy = 'ann'; annNote = '';
    const res = await adminAnnounceRival(annFor.id, annTitle, annBody, false);
    busy = null;
    if (!res || !res.ok) { annNote = (res && res.error) || 'Could not send.'; return; }
    notice = `Announcement sent to ${res.result && res.result.sent != null ? res.result.sent : 0} online member(s) of the two gangs.`;
    annFor = null;
  }

  $: mapTerritories = mapFor ? ($territoryState.territories || []).filter((t) => [mapFor.territoryId, mapFor.attackerTerritoryId].includes(t.id)).map((t) => viewToRender(t, gangs)) : [];
</script>

<div class:panel={!embedded} class:view-enter={!embedded}>
  {#if !embedded}
    <div class="panel-header"><span class="panel-title"><Icon name="flag" size={14} /> Challenges and wars</span></div>
  {/if}
  <div class="rv-body">
    <div class="rv-top">
      <div class="seg">
        <button type="button" class:active={filter === 'OPEN'} on:click={() => (filter = 'OPEN')}>Open</button>
        <button type="button" class:active={filter === 'ALL'} on:click={() => (filter = 'ALL')}>All / history</button>
      </div>
      <button type="button" class="btn btn-steel" on:click={refreshRivals}><Icon name="refresh" size={13} /> Refresh</button>
    </div>
    <p class="hint">A gang leader challenges any other gang's territory (it does not have to touch); the challenged gang accepts or declines; an accepted challenge waits here until you set the war date. In Manage you can also accept or decline a pending challenge for the challenged gang, start a war now, or cancel it. Both gangs are told they are responsible for being present. The war is fought on the smaller gang's own territory, so the challenged gang may be the one attacking. Nobody loses a territory: the winner loots the Leader Ped, which takes Gang XP from the loser and shrinks the loser's painted land. A war whose time passed while the server was offline goes back to Accepted so you can schedule it again.</p>
    {#if error}<div class="error">{error}</div>{/if}
    {#if notice}<div class="notice">{notice}</div>{/if}

    <div class="rv-card-wrap">
      <TablePager top bind:page={rPage} bind:pageSize={rSize} total={rivals.length} noun="challenges" sizes={[5, 10, 15, 25, 50]} />
      <div class="rv-scroll">
        <table class="rv-table">
          <thead>
            <tr><th class="c-idx">#</th><th>Rivals</th><th>Territory</th><th>Status</th><th>War date</th><th>Duration</th><th class="c-act">Actions</th></tr>
          </thead>
          <tbody>
            {#each pagedRivals as r, i (r.id)}
              <tr class:live={r.status === 'ACTIVE'}>
                <td class="c-idx">{(rPage - 1) * rSize + i + 1}</td>
                <td class="c-vs"><b>{r.attackerLabel}</b> <span>VS</span> <b>{r.defenderLabel}</b></td>
                <td>{r.territoryName}{#if r.attackerTerritoryName} <span class="muted">· from {r.attackerTerritoryName}</span>{/if}</td>
                <td>
                  <span class="badge {STATUS_CLASS[r.status] || ''}">{STATUS_TEXT[r.status] || r.status}</span>
                  {#if r.result} <span class="muted">{r.result}{r.winnerLabel ? ` — ${r.winnerLabel}` : ''}</span>{/if}
                </td>
                <td class="nowrap">{r.status === 'SCHEDULED' || r.status === 'ACTIVE' || r.status === 'COMPLETED' ? (r.warAtText || fmtDate(r.warAt)) : 'Not scheduled'}</td>
                <td class="nowrap">{r.durationSec ? `${Math.round(r.durationSec / 60)} min` : '—'}{#if r.penaltyXp != null}<span class="muted"> · −{r.penaltyXp} XP</span>{/if}</td>
                <td class="c-act">
                  <div class="rv-actions">
                    {#if r.status === 'PENDING' || r.status === 'ACCEPTED' || r.status === 'SCHEDULED'}
                      <button type="button" class="btn btn-primary btn-sm" on:click={() => openSchedule(r)}><Icon name="calendar" size={13} /> {r.status === 'SCHEDULED' ? 'Change Date' : r.status === 'PENDING' ? 'Accept & Set Date' : 'Set War Date'}</button>
                    {/if}
                    <button type="button" class="btn btn-steel btn-sm" on:click={() => (mapFor = r)}><Icon name="pin" size={13} /> Map</button>
                    <button type="button" class="btn btn-steel btn-sm" on:click={() => (openId = openId === r.id ? null : r.id)}><Icon name="gear" size={13} /> Manage</button>
                    {#if OPEN.includes(r.status)}
                      <button type="button" class="btn btn-danger btn-sm" disabled={busy === r.id} on:click={() => cancel(r)}><Icon name="close" size={12} /> Cancel</button>
                    {/if}
                  </div>
                </td>
              </tr>
              {#if r.live}
                <tr class="rv-sub live"><td></td><td colspan="6">
                  <span class="badge badge-under-attack">LIVE</span> {fmtClock(r.live.secondsLeft)} left · capture <b>{r.live.state}</b> {Math.round(r.live.progress)} / {r.live.captureSeconds}s · present: attackers {r.live.attackersPresent}, defenders {r.live.defendersPresent}
                </td></tr>
              {/if}
              {#if openId === r.id}
                <tr class="rv-sub"><td></td><td colspan="6">
                  <div class="mg-grid">
                    <div><span>Challenge #</span><b>{r.id}</b></div>
                    <div><span>Challenger</span><b>{r.attackerLabel}</b></div>
                    <div><span>Challenged gang</span><b>{r.defenderLabel}</b></div>
                    <div><span>Fought at</span><b>{r.territoryName}</b></div>
                    {#if r.attackerTerritoryName}<div><span>Challenger's territory</span><b>{r.attackerTerritoryName}</b></div>{/if}
                    <div><span>Sent by</span><b>{r.createdByName || '—'}</b></div>
                    <div><span>Answered by</span><b>{r.respondedByName || '—'}</b></div>
                    <div><span>Scheduled by</span><b>{r.scheduledBy || '—'}</b></div>
                    <div><span>Created</span><b>{fmtDate(r.createdAt)}</b></div>
                    <div><span>Ended</span><b>{r.endedAt ? fmtDate(r.endedAt) : '—'}</b></div>
                    <div><span>War zone</span><b>{r.zone ? `${r.zone.shape === 'square' ? 'Square' : 'Circle'} · ${Math.round(r.zone.size)} m${r.zone.shape === 'square' ? ' half-side' : ' radius'}` : 'Not drawn (round ring at the leader ped)'}</b></div>
                  </div>
                  {#if r.comment}<div class="mg-comment"><span>Comment from {r.defenderLabel}{r.respondedByName ? ` (${r.respondedByName})` : ''}</span>{r.comment}</div>{/if}
                  {#if r.note}<div class="mg-note">{r.note}</div>{/if}
                  <div class="mg-actions">
                    <button type="button" class="btn btn-steel btn-sm" on:click={() => teleportLeader(r)} title="Teleport next to the leader ped of {r.territoryName}"><Icon name="teleport" size={13} /> Teleport to leader ped</button>
                    {#if OPEN.includes(r.status)}
                      <button type="button" class="btn btn-steel btn-sm" on:click={() => openZone(r)} title="Draw the zone the war is fought in (shown only once it starts)"><Icon name="pin" size={13} /> {r.zone ? 'Edit war zone' : 'Draw war zone'}</button>
                    {/if}
                    <button type="button" class="btn btn-steel btn-sm" on:click={() => openAnnounce(r)} title="Announce this war to the members of the two gangs only"><Icon name="megaphone" size={13} /> Announce</button>
                    {#if r.status === 'PENDING'}
                      <button type="button" class="btn btn-primary btn-sm" disabled={busy === r.id} on:click={() => answer(r, true)}><Icon name="check" size={13} /> Accept for {r.defenderLabel}</button>
                      <button type="button" class="btn btn-steel btn-sm" disabled={busy === r.id} on:click={() => answer(r, false)}><Icon name="close" size={13} /> Decline for {r.defenderLabel}</button>
                    {/if}
                    {#if r.status === 'PENDING' || r.status === 'ACCEPTED' || r.status === 'SCHEDULED'}
                      <button type="button" class="btn btn-primary btn-sm" disabled={busy === r.id} on:click={() => startNow(r)}><Icon name="play" size={13} /> Start War Now</button>
                    {/if}
                    {#if OPEN.includes(r.status)}
                      <button type="button" class="btn btn-danger btn-sm" disabled={busy === r.id} on:click={() => cancel(r)}><Icon name="close" size={12} /> Cancel challenge</button>
                    {/if}
                  </div>
                </td></tr>
              {/if}
            {:else}
              <tr><td colspan="7" class="empty-row">No {filter === 'OPEN' ? 'open ' : ''}challenges yet. They appear here live as gangs challenge each other.</td></tr>
            {/each}
          </tbody>
        </table>
      </div>
    </div>  </div>
</div>

{#if schedFor}
  <div class="overlay" on:click|self={() => (schedFor = null)} role="presentation">
    <div class="modal">
      <div class="m-title"><Icon name="calendar" size={16} /> Set War Date</div>
      <div class="m-sub">{schedFor.attackerLabel} vs {schedFor.defenderLabel} — {schedFor.territoryName}</div>
      <div class="field"><label>War date &amp; time <span class="optional">server schedule time</span></label><DateTimePicker bind:value={schedDate} /></div>
      <div class="field-row">
        <div class="field"><label>Duration (minutes)</label><input type="number" min={cfg.minDurationMinutes || 3} max={cfg.maxDurationMinutes || 90} bind:value={schedMinutes} /></div>
        <div class="field"><label>No-show XP penalty <span class="optional">blank = the configured rule ({cfg.noShowPenalty?.mode === 'PERCENT' ? `${cfg.noShowPenalty?.percent}%` : `${cfg.noShowPenalty?.xp ?? 0} XP`})</span></label><input type="number" min="0" bind:value={schedPenalty} placeholder="default" /></div>
      </div>
      <p class="hint">If the timer runs out and nobody from either gang is alive in the territory, the owner keeps it and loses this much Gang XP.</p>
      {#if error}<div class="error">{error}</div>{/if}
      <div class="m-actions">
        <button type="button" class="btn" on:click={() => (schedFor = null)}>Close</button>
        <button type="button" class="btn btn-primary" disabled={busy === 'sched'} on:click={saveSchedule}>{busy === 'sched' ? 'Scheduling…' : 'Schedule War'}</button>
      </div>
    </div>
  </div>
{/if}

{#if zoneFor}
  <div class="overlay" on:click|self={() => (zoneFor = null)} role="presentation">
    <div class="modal">
      <div class="m-title"><Icon name="pin" size={16} /> War zone</div>
      <div class="m-sub">{zoneFor.attackerLabel} vs {zoneFor.defenderLabel} — {zoneFor.territoryName}. The zone is drawn in green and enforced only once this war starts; leaving it eliminates a fighter after the usual buffer.</div>
      <div class="seg" style="margin-bottom: 12px;">
        <button type="button" class:active={zShape === 'circle'} on:click={() => (zShape = 'circle')}>Circle</button>
        <button type="button" class:active={zShape === 'square'} on:click={() => (zShape = 'square')}>Square</button>
      </div>
      <div class="field"><label for="z-size">{zShape === 'square' ? 'Half the side' : 'Radius'} <span class="optional">metres</span></label>
        <div class="z-row"><input id="z-size" type="range" min="20" max={zoneMax()} step="5" bind:value={zSize} /><input type="number" class="z-num" min="20" max={zoneMax()} bind:value={zSize} /></div>
        <div class="muted small">{zShape === 'square' ? `A square ${num(zSize) * 2} m on each side.` : `A circle ${num(zSize) * 2} m across.`}</div>
      </div>
      <div class="field-row">
        <div class="field"><label for="z-x">Centre X</label><input id="z-x" type="number" step="0.01" bind:value={zX} /></div>
        <div class="field"><label for="z-y">Centre Y</label><input id="z-y" type="number" step="0.01" bind:value={zY} /></div>
        <div class="field"><label for="z-z">Centre Z</label><input id="z-z" type="number" step="0.01" bind:value={zZ} /></div>
      </div>
      <div class="z-tools">
        <button type="button" class="btn btn-steel btn-sm" on:click={zoneCenterLeader}><Icon name="pin" size={13} /> Centre on leader ped</button>
        <button type="button" class="btn btn-steel btn-sm" on:click={zoneCenterMe}><Icon name="pin" size={13} /> Centre on my position</button>
        <button type="button" class="btn btn-steel btn-sm" on:click={zoneSizeFromMe} title="Stand at the edge you want, then press this"><Icon name="pin" size={13} /> Size = my distance from the centre</button>
        <button type="button" class="btn btn-steel btn-sm" on:click={zonePreview}><Icon name="eye" size={13} /> Preview in the world</button>
      </div>
      {#if zoneNote}<div class="muted small" style="margin-top: 8px;">{zoneNote}</div>{/if}
      {#if error}<div class="error">{error}</div>{/if}
      <div class="m-actions">
        {#if zoneFor.zone}<button type="button" class="btn btn-danger" disabled={busy === 'zone'} on:click={zoneClear}>Remove zone</button>{/if}
        <button type="button" class="btn" on:click={() => (zoneFor = null)}>Close</button>
        <button type="button" class="btn btn-primary" disabled={busy === 'zone'} on:click={zoneSave}>{busy === 'zone' ? 'Saving…' : 'Save zone'}</button>
      </div>
    </div>
  </div>
{/if}

{#if annFor}
  <div class="overlay" on:click|self={() => (annFor = null)} role="presentation">
    <div class="modal">
      <div class="m-title"><Icon name="megaphone" size={16} /> Announce this war</div>
      <div class="m-sub">Goes to the online members of <b>{annFor.attackerLabel}</b> and <b>{annFor.defenderLabel}</b> only, as the same banner the other events use.</div>
      <div class="field"><label for="a-title">Title</label><input id="a-title" type="text" maxlength="100" bind:value={annTitle} /></div>
      <div class="field"><label for="a-body">Message</label><textarea id="a-body" rows="4" maxlength="500" bind:value={annBody}></textarea></div>
      {#if annNote}<div class="muted small">{annNote}</div>{/if}
      <div class="m-actions">
        <button type="button" class="btn" on:click={() => (annFor = null)}>Close</button>
        <button type="button" class="btn btn-steel" on:click={annPreview}><Icon name="eye" size={13} /> Preview myself</button>
        <button type="button" class="btn btn-primary" disabled={busy === 'ann' || !annTitle.trim()} on:click={annSend}>{busy === 'ann' ? 'Sending…' : 'Send to both gangs'}</button>
      </div>
    </div>
  </div>
{/if}

{#if mapFor}
  <div class="overlay" on:click|self={() => (mapFor = null)} role="presentation">
    <div class="modal wide">
      <div class="m-title"><Icon name="pin" size={16} /> {mapFor.territoryName} — {mapFor.attackerLabel} vs {mapFor.defenderLabel}</div>
      <TerritoryMap territories={mapTerritories} mode="view" selectedId={mapFor.territoryId} height={480} showLocked />
      <div class="m-actions"><button type="button" class="btn" on:click={() => (mapFor = null)}>Close</button></div>
    </div>
  </div>
{/if}

<style>
  .rv-body { padding: 4px 2px; }
  .rv-top { display: flex; justify-content: space-between; align-items: center; gap: 10px; margin-bottom: 8px; }
  .seg { display: inline-flex; border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); overflow: hidden; }
  .seg button { padding: 8px 16px; background: var(--es-card, #181b1f); color: var(--lt-aeb5bd, #aeb5bd); font-weight: 600; font-size: var(--fs-small); }
  .seg button.active { background: var(--c-action); color: var(--on-accent); }
  .hint { font-size: var(--fs-small); color: var(--text-muted, #aeb5bd); line-height: 1.55; margin: 6px 0 12px; }
  .muted { color: var(--text-muted, #aeb5bd); }
  .empty { padding: 28px; text-align: center; border: 1px dashed var(--es-line, #2a2e35); border-radius: var(--r-panel); color: var(--text-muted, #aeb5bd); }
  .notice { margin: 8px 0; padding: 9px 12px; border: 1px solid #46c98b; border-radius: var(--r-ctl); color: var(--lt-46c98b, #46c98b); font-size: var(--fs-small); }
  .rv-card-wrap { background: var(--es-card, #181b1f); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-panel); overflow: hidden; margin-top: 8px; }
  .rv-card-wrap :global(.tp) {
    border-left: none;
    border-right: none;
    border-top: none;
    border-radius: 0;
    border-bottom: 1px solid var(--es-line, #2a2e35);
  }
  .rv-scroll { overflow: auto; max-height: clamp(280px, 52vh, 600px); }
  .rv-table { width: 100%; border-collapse: collapse; font-size: var(--fs-body); color: var(--lt-eceef0, #eceef0); }
  .rv-table th { position: sticky; top: 0; z-index: 1; padding: var(--tbl-th-y) var(--tbl-x); background: var(--c-panel); border-bottom: 1px solid var(--c-line); font-size: var(--fs-meta); font-weight: 600; letter-spacing: 0; text-align: left; white-space: nowrap;
    color: var(--text-muted);
  }
  .rv-table td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft); vertical-align: middle;
    font-variant-numeric: tabular-nums;
  }
  .rv-table tbody tr:nth-child(even):not(.rv-sub) { background: rgba(var(--ink-rgb, 255, 255, 255), 0.022); }
  .rv-table tr.live > td { background: rgba(255, 93, 80, 0.06);
    font-variant-numeric: tabular-nums;
  }
  .rv-sub td { background: var(--es-inset, #111316); font-size: var(--fs-body);
    font-variant-numeric: tabular-nums;
  }
  .c-idx {
    width: 44px;
    text-align: center !important;
  }
  td.c-idx {
    color: #8d949c;
  }
  .c-act { text-align: right !important; }
  .c-vs b { font-weight: 700; }
  .c-vs span { color: #c45ee0; font-weight: 700; margin: 0 6px; font-size: var(--fs-meta); }
  .nowrap { white-space: nowrap; }
  .empty-row { text-align: center; padding: 26px 16px !important; color: var(--text-muted, #aeb5bd); }  .rv-actions { display: flex; gap: 6px; justify-content: flex-end; flex-wrap: nowrap; }
  .mg-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 8px 16px; margin-bottom: 10px; }
  .mg-grid div { display: flex; flex-direction: column; font-size: var(--fs-small); }
  .mg-grid span { color: var(--text-muted, #aeb5bd); font-size: var(--fs-meta); }
  .mg-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 4px; }
  .mg-comment { margin: 8px 0; padding: 9px 12px; background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); border-left: 3px solid var(--c-action); border-radius: var(--r-ctl); font-size: var(--fs-body); }
  .mg-comment span { display: block; color: var(--text-muted, #aeb5bd); font-size: var(--fs-meta); font-weight: 700; margin-bottom: 3px; }
  .z-row { display: flex; align-items: center; gap: 12px; }
  .z-row input[type='range'] { flex: 1; accent-color: var(--accent-primary); }
  .z-num { width: 90px; text-align: right; }
  .z-tools { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 4px; }
  .mg-note { margin: 8px 0; padding: 8px 12px; background: var(--es-inset, #15171b); border: 1px solid var(--es-line, #2a2e35); border-radius: var(--r-ctl); font-size: var(--fs-small); }
  .overlay { position: fixed; inset: 0; z-index: 6000; background: var(--scrim, rgba(0, 0, 0, 0.62)); display: flex; align-items: center; justify-content: center; }
  .modal { width: 560px; max-width: 94vw; max-height: 92vh; overflow-y: auto; background: var(--surface-dialog); border: 1px solid var(--border-dialog); border-radius: var(--r-panel); padding: 22px 24px; }
  .modal.wide { width: 980px; }
  .m-title { display: flex; align-items: center; gap: 8px; font-size: var(--fs-title); font-weight: 700;
    font-family: var(--font-display); font-stretch: var(--stretch-display); }
  .m-sub { color: var(--text-muted, #aeb5bd); margin: 4px 0 14px; font-size: var(--fs-body); }
  .m-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 16px; }
  .field-row { display: flex; gap: 14px; flex-wrap: wrap; }
  .field-row > .field { flex: 1 1 200px; }
</style>
