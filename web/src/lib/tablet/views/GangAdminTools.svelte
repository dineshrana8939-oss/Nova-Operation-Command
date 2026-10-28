<script>
  // One gang's staff tools, shown inside Community → Gang Management → (a gang). Which tool is on screen is the `section` prop:
  //   territory  — Territory Control: the gang's own territory (hand it over, jump to it, delete it) or assign it a free one
  //   xp         — Gang XP: an XP Overview page (rank, totals, top earners, ledger) and an Add / Remove XP page
  //   messages   — Notices & Warnings in one page: a message to every member, the admin picks Notice or Warning
  //   notices    — Gang Notices: an informational message to every member
  //   warnings   — Gang Warnings: a warning to every member
  // The gang is fixed by the `gang` prop, so an action can never land on a different gang than the one named in the header.
  // Everything is server-checked exactly as before; this only decides where the admin finds it. (Disbanding a gang lives in the
  // Administration tab of Gang Management, once.)
  import { onMount } from 'svelte';
  import { territoryState, xpBoard, refreshTerritoryState } from '../../territory/territoryStore.js';
  import { getXpBoard, getXpHistory, adminAdjustXp, adminSetOwner, adminRemoveTerritory, adminNotifyGang } from '../../api/territory.js';
  import { countSpans } from '../../territory/territoryGeometry.js';
  import { teleportToPosition } from '../../api/route.js';
  import { confirmAction } from '../ui/confirm.js';
  import Icon from '../ui/Icon.svelte';
  import TablePager from '../ui/TablePager.svelte';
  import SubTabs from '../ui/SubTabs.svelte';
  import { defaultPageSize } from '../../adminPrefs.js';
  import '../tablet-theme.css';

  export let gang = '';              // the gang being managed (its internal name)
  export let section = 'territory';  // 'territory' | 'xp' | 'notices' | 'warnings'

  let msg = '';
  let err = '';
  const say = (m) => { msg = m; err = ''; };
  const fail = (e) => { err = e; msg = ''; };

  // ── territory ───────────────────────────────────────────────────────────────
  let selTid = null;
  let ownGang = '';
  let ownReason = '';
  let lastTid = null;
  let assignTid = '';
  let assignNote = '';

  // ── xp ──────────────────────────────────────────────────────────────────────
  let xpPage = 'overview';           // 'overview' | 'history' | 'adjust'
  const XP_PAGES = [
    { id: 'overview', label: 'XP Overview',    icon: 'activity' },
    { id: 'history',  label: 'XP History',     icon: 'fileText' },
    { id: 'adjust',   label: 'Add / Remove XP', icon: 'zap' },
  ];
  let xpMode = 'ADD';                // ADD | REDUCE — the amount is always typed as a positive number
  let xpAmount = '';
  let xpReason = '';
  let earners = [];                  // this gang's players, from the XP ranking
  let ledger = [];                   // this gang's latest XP transactions
  let xpLoading = false;
  // both lists are paged: rows per page + page switches above each table
  let ledPage = 1, ledSize = defaultPageSize([10, 15, 25, 50]);
  let earnPage = 1, earnSize = defaultPageSize([10, 15, 25, 50]);
  $: pagedLedger = ledger.slice((ledPage - 1) * ledSize, ledPage * ledSize);
  $: pagedEarners = earners.slice((earnPage - 1) * earnSize, earnPage * earnSize);
  // another gang starts on page 1
  const firstPages = () => { ledPage = 1; earnPage = 1; };
  $: firstPages(gang);

  // ── notices / warnings ──────────────────────────────────────────────────────
  let msgText = '';
  let actBusy = false;

  onMount(async () => {
    refreshTerritoryState();
    if (!$xpBoard.loaded) { const r = await getXpBoard(); if (r && r.ok) xpBoard.set({ loaded: true, gangs: r.gangs || [] }); }
  });

  $: gangs = $territoryState.gangs || [];
  $: territories = $territoryState.territories || [];
  $: gRow = ($xpBoard.gangs || []).find((g) => g.gang === gang) || null;
  $: gangLabel = (n) => (gangs.find((g) => g.name === n) || {}).label || n;
  $: owned = territories.filter((t) => t.owner === gang);
  $: free = territories.filter((t) => !t.owner);
  // the open territory: the picked one while the gang still holds it, else its first
  $: if (!owned.some((t) => t.id === selTid)) selTid = owned.length ? owned[0].id : null;
  $: terr = owned.find((t) => t.id === selTid) || null;
  // picking another territory resets the owner box to who owns it now
  $: if (terr && terr.id !== lastTid) { lastTid = terr.id; ownGang = terr.owner || ''; ownReason = ''; }
  $: ownerChanged = !!terr && (ownGang || '') !== (terr.owner || '');
  $: xpBlocked = !!$territoryState.adminXpBlocked;   // an admin who also leads a gang may not add / remove Gang XP
  $: xpNow = Number((gRow && gRow.totalXp) || 0);
  $: xpChange = Math.max(0, Math.floor(Number(xpAmount) || 0));
  $: xpAfter = xpMode === 'ADD' ? xpNow + xpChange : Math.max(0, xpNow - xpChange);
  // The Messages page lets the admin pick the type; the old 'notices' / 'warnings' sections stay fixed to theirs
  let msgKind = 'NOTICE';
  $: kindKey = section === 'warnings' ? 'WARNING' : (section === 'notices' ? 'NOTICE' : msgKind);
  const km2 = (t) => (countSpans(t.geo?.active || t.geo?.base || []) * 0.000625).toFixed(3);
  const num = (n) => Number(n || 0).toLocaleString();
  const when = (ts) => (ts ? new Date(ts * 1000).toLocaleString([], { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');

  // The overview's two lists use the same server data the XP Ranking / XP Log did; refreshed on opening and whenever the gang's XP moves.
  async function loadXp() {
    if (!gang) return;
    xpLoading = true;
    const [b, h] = await Promise.all([getXpBoard(), getXpHistory({ gang, limit: 300 })]);
    xpLoading = false;
    if (b && b.ok) earners = (b.players || []).filter((p) => p.gang_name === gang);
    if (h && h.ok) ledger = h.history || [];
  }
  $: if (section === 'xp' && (xpPage === 'overview' || xpPage === 'history')) loadXp(xpNow);

  async function setOwner() {
    if (!terr) return;
    const ok = await confirmAction(`Make ${ownGang ? gangLabel(ownGang) : 'nobody'} the owner of ${terr.name}?\n\nThis changes the persistent owner immediately on every map and is recorded in the territory history.`, { title: 'Set territory owner', confirmLabel: 'Change owner' });
    if (!ok) return;
    const r = await adminSetOwner(terr.id, ownGang, ownReason);
    if (!r || !r.ok) { fail((r && r.error) || 'Failed.'); return; }
    say('Owner changed.'); ownReason = '';
  }

  async function assign() {
    const t = free.find((x) => x.id === assignTid);
    if (!t) return;
    const ok = await confirmAction(`Make ${gangLabel(gang)} the owner of ${t.name}?\n\nThis changes the persistent owner immediately on every map and is recorded in the territory history.`, { title: 'Assign territory', confirmLabel: 'Assign' });
    if (!ok) return;
    const r = await adminSetOwner(t.id, gang, assignNote);
    if (!r || !r.ok) { fail((r && r.error) || 'Failed.'); return; }
    say(`${t.name} now belongs to ${gangLabel(gang)}.`); assignTid = ''; assignNote = '';
  }

  async function removeT() {
    if (!terr) return;
    const ok = await confirmAction(`Delete the territory "${terr.name}" for good?\n\nIts owner and painted area are removed from the map (its history stays). Use this only for territories you no longer want.`, { title: 'Delete territory', danger: true, confirmLabel: 'Delete' });
    if (!ok) return;
    const r = await adminRemoveTerritory(terr.id);
    if (!r || !r.ok) { fail((r && r.error) || 'Failed.'); return; }
    say('Territory deleted.');
    refreshTerritoryState();
  }

  function goThere() {
    const p = terr && (terr.location && terr.location.x != null ? terr.location : terr.center);
    if (p && p.x != null) teleportToPosition(p.x, p.y, p.z || 40.0, 0);
  }

  async function sendMessage() {
    if (!gang) return;
    if (msgText.trim().length < 3) { fail('Write the message the gang will see.'); return; }
    const label = gangLabel(gang);
    const warn = kindKey === 'WARNING';
    const ok = await confirmAction(`Send this ${warn ? 'warning' : 'notice'} to every member of ${label}?\n\n"${msgText.trim()}"\n\nMembers online see it at once; anyone offline sees it when they next log in. It is posted to Discord under your name.`, { title: warn ? 'Warn gang' : 'Message gang', confirmLabel: 'Send', danger: warn });
    if (!ok) return;
    actBusy = true;
    const r = await adminNotifyGang(gang, kindKey, msgText);
    actBusy = false;
    if (!r || !r.ok) { fail((r && r.error) || 'Failed.'); return; }
    say(`Sent to ${label}.`); msgText = '';
  }

  async function adjust() {
    if (xpBlocked) { fail('You lead a gang, so you cannot add or remove Gang XP.'); return; }
    if (!gang || !xpChange) { fail('Enter an amount above 0.'); return; }
    const label = gangLabel(gang);
    const terrText = owned.length ? `\nTerritories: ${owned.map((t) => t.name).join(', ')}` : '';
    const add = xpMode === 'ADD';
    if (!add && xpReason.trim().length < 3) { fail('Give a reason for removing XP — it is shown to the gang.'); return; }
    const ok = await confirmAction(`${add ? 'Add' : 'Remove'} ${xpChange.toLocaleString()} Gang XP ${add ? 'to' : 'from'} ${label}?\n\n${label}: ${xpNow.toLocaleString()} → ${xpAfter.toLocaleString()} XP${terrText}\n${xpReason.trim() ? `Reason shown to the gang: "${xpReason.trim()}"\n` : ''}Only ${label} members online get the announcement. It is recorded in the XP ledger under your name.`, { title: add ? 'Add Gang XP' : 'Reduce Gang XP', confirmLabel: add ? 'Add XP' : 'Remove XP', danger: !add });
    if (!ok) return;
    const r = await adminAdjustXp(gang, add ? xpChange : -xpChange, xpReason);
    if (!r || !r.ok) { fail((r && r.error) || 'Failed.'); return; }
    say(`Done — ${label} now has ${Number(r.total).toLocaleString()} XP.`);
    xpAmount = ''; xpReason = '';
  }
</script>

<div class="adm">
  {#if err}<div class="note bad" role="alert">{err}</div>{/if}
  {#if msg}<div class="note ok" role="status">{msg}</div>{/if}

  <!-- ═════════════ Territory Control ═════════════ -->
  {#if section === 'territory'}
    {#if owned.length > 1}
      <div class="picker" role="tablist" aria-label="Territories of this gang">
        {#each owned as t (t.id)}
          <button type="button" role="tab" aria-selected={t.id === selTid} class="pick" class:on={t.id === selTid} on:click={() => (selTid = t.id)}>
            <i class="dot" style="background:{t.color || '#c45ee0'}"></i>{t.name}
          </button>
        {/each}
      </div>
    {/if}

    <div class="cols even" class:single={!free.length}>
    {#if terr}
      <section class="card">
        <header class="card-head">
          <span class="ico gold"><Icon name="flag" size={18} /></span>
          <div><h3>Manage Territory</h3><p>{terr.name} — hand it to a gang, jump to it, or delete it.</p></div>
          {#if terr.busy}<span class="st war">War</span>{:else}<span class="st owned">Owned</span>{/if}
        </header>

        <div class="kpi-row gx-kpis">
          <div class="kpi-card"><div class="kpi-icon"><Icon name="flag" size={16} /></div><div class="gx-kcell"><div class="kpi-value gx-kv"><i class="dot" style="background:{terr.color || '#c45ee0'}"></i>{terr.name}</div><div class="kpi-label">Territory</div></div></div>
          <div class="kpi-card"><div class="kpi-icon"><Icon name="expand" size={16} /></div><div class="gx-kcell"><div class="kpi-value gx-kv">{km2(terr)} km²</div><div class="kpi-label">Land</div></div></div>
          <div class="kpi-card"><div class="kpi-icon"><Icon name="zap" size={16} /></div><div class="gx-kcell"><div class="kpi-value gx-kv">{num(terr.xpValue)}</div><div class="kpi-label">XP value</div></div></div>
        </div>

        <div class="form">
          <label class="fld"><span>Owner</span>
            <select bind:value={ownGang}>
              <option value="">— nobody (unclaimed) —</option>
              {#each gangs as g (g.name)}<option value={g.name}>{g.label || g.name}</option>{/each}
            </select>
          </label>
          <label class="fld"><span>Note <em>kept in the territory history</em></span>
            <input type="text" bind:value={ownReason} maxlength="160" placeholder="Why the owner changes" />
          </label>
          <div class="row">
            <button type="button" class="btn btn-primary" disabled={!ownerChanged} on:click={setOwner}>Change owner</button>
            <button type="button" class="btn btn-steel" on:click={goThere} title="Teleport to this territory"><Icon name="teleport" size={13} /> Go there</button>
            <button type="button" class="btn btn-danger" on:click={removeT}><Icon name="trash" size={13} /> Delete</button>
          </div>
        </div>
      </section>
    {:else}
      <section class="card">
        <header class="card-head">
          <span class="ico gold"><Icon name="flag" size={18} /></span>
          <div><h3>Manage Territory</h3><p>{gangLabel(gang)} does not own a territory yet.</p></div>
        </header>
        <div class="hint">Assign one below, or let the gang win one at a Territory Auction.</div>
      </section>
    {/if}

    {#if free.length}
      <section class="card">
        <header class="card-head">
          <span class="ico"><Icon name="pin" size={18} /></span>
          <div><h3>Assign a free territory</h3><p>Give {gangLabel(gang)} a territory nobody owns.</p></div>
        </header>
        <div class="form">
          <label class="fld"><span>Territory</span>
            <select bind:value={assignTid}>
              <option value="">— pick a free territory —</option>
              {#each free as t (t.id)}<option value={t.id}>{t.name} · {km2(t)} km²</option>{/each}
            </select>
          </label>
          <label class="fld"><span>Note <em>kept in the territory history</em></span>
            <input type="text" bind:value={assignNote} maxlength="160" placeholder="Why it is assigned" />
          </label>
          <div class="row"><button type="button" class="btn btn-primary" disabled={!assignTid} on:click={assign}>Assign to {gangLabel(gang)}</button></div>
        </div>
      </section>
    {/if}
    </div>

  <!-- ═════════════ Gang XP ═════════════ -->
  {:else if section === 'xp'}
    <SubTabs tabs={XP_PAGES} bind:active={xpPage} />

    {#if xpPage === 'overview'}
      <div class="kpi-row gx-kpis">
        <div class="kpi-card"><div class="kpi-icon"><Icon name="trophy" size={16} /></div><div class="gx-kcell"><div class="kpi-value gx-kv">{gRow ? `#${gRow.rank}` : '—'}</div><div class="kpi-label">XP rank</div></div></div>
        <div class="kpi-card"><div class="kpi-icon"><Icon name="activity" size={16} /></div><div class="gx-kcell"><div class="kpi-value gx-kv">{num(gRow && gRow.lifetimeXp)}</div><div class="kpi-label">Lifetime XP</div></div></div>
        <div class="kpi-card"><div class="kpi-icon"><Icon name="expand" size={16} /></div><div class="gx-kcell"><div class="kpi-value gx-kv">{gRow && gRow.areaKm2 != null ? Number(gRow.areaKm2).toFixed(3) : '0.000'} km²</div><div class="kpi-label">Territory area</div></div></div>
      </div>

      <div class="cols one">
        <section class="card">
          <header class="card-head">
            <span class="ico gold"><Icon name="trophy" size={18} /></span>
            <div><h3>Top earners</h3><p>Players of {gangLabel(gang)} by XP earned.</p></div>
          </header>
          <div class="tbl-wrap">
            <TablePager flush top bind:page={earnPage} bind:pageSize={earnSize} total={earners.length} noun="players" />
            <table class="tbl">
              <thead><tr><th>Rank</th><th>Player</th><th class="num">XP earned</th></tr></thead>
              <tbody>
                {#each pagedEarners as p, i (p.player_identifier + p.gang_name)}
                  <tr><td>#{(earnPage - 1) * earnSize + i + 1}</td><td class="strong">{p.player_name || '—'}</td><td class="num"><b>{num(p.xp)}</b></td></tr>
                {:else}
                  <tr><td colspan="3" class="muted">{xpLoading ? 'Loading…' : 'Nobody in this gang has earned Gang XP yet.'}</td></tr>
                {/each}
              </tbody>
            </table>
          </div>
        </section>

      </div>

    {:else if xpPage === 'history'}
      <div class="cols one">
        <section class="card">
          <header class="card-head">
            <span class="ico"><Icon name="activity" size={18} /></span>
            <div><h3>XP history</h3><p>Every entry of {gangLabel(gang)}'s ledger, newest first.</p></div>
          </header>
          <div class="tbl-wrap">
            <TablePager flush top bind:page={ledPage} bind:pageSize={ledSize} total={ledger.length} noun="transactions" />
            <table class="tbl">
              <thead><tr><th>Date</th><th class="num">XP</th><th>Source</th><th>Reason</th><th>Player</th><th class="num">Balance</th></tr></thead>
              <tbody>
                {#each pagedLedger as r (r.id)}
                  <tr>
                    <td>{when(r.at)}</td>
                    <td class="num {r.xp_amount >= 0 ? 'pos' : 'neg'}">{r.xp_amount >= 0 ? '+' : ''}{num(r.xp_amount)}</td>
                    <td>{r.source_name || r.source_type}</td>
                    <td class="muted">{r.reason || '—'}</td>
                    <td>{r.player_name || '—'}</td>
                    <td class="num">{r.balance_after != null ? num(r.balance_after) : '—'}</td>
                  </tr>
                {:else}
                  <tr><td colspan="6" class="muted">{xpLoading ? 'Loading…' : 'No Gang XP recorded for this gang yet.'}</td></tr>
                {/each}
              </tbody>
            </table>
          </div>
        </section>
      </div>

    {:else}
      <div class="adjust">
        <section class="card">
          <header class="card-head">
            <span class="ico"><Icon name="zap" size={18} /></span>
            <div><h3>Add or remove Gang XP</h3><p>{gangLabel(gang)} is told why.</p></div>
          </header>

          {#if xpBlocked}<div class="note warn"><b>Locked for you.</b> You lead a gang, so you cannot add or reduce Gang XP for any gang.</div>{/if}

          <div class="form">
            <div class="fld">
              <span>Action</span>
              <div class="seg" role="group" aria-label="Add or reduce XP">
                <button type="button" class:on={xpMode === 'ADD'} disabled={xpBlocked} on:click={() => (xpMode = 'ADD')}>+ Add XP</button>
                <button type="button" class="neg" class:on={xpMode === 'REDUCE'} disabled={xpBlocked} on:click={() => (xpMode = 'REDUCE')}>− Remove XP</button>
              </div>
            </div>

            <div class="fld">
              <label for="xp-amount">Amount</label>
              <input id="xp-amount" type="number" min="1" bind:value={xpAmount} disabled={xpBlocked} placeholder="A positive number" />
              <div class="chips">
                {#each [100, 500, 1000, 5000, 10000] as q}<button type="button" class="chip" disabled={xpBlocked} on:click={() => (xpAmount = q)}>{q.toLocaleString()}</button>{/each}
              </div>
            </div>

            <div class="fld">
              <label for="xp-reason">{xpMode === 'REDUCE' ? 'Reason (required — shown to the gang)' : 'Reason (shown to the gang)'}</label>
              <input id="xp-reason" type="text" bind:value={xpReason} maxlength="160" disabled={xpBlocked} placeholder={xpMode === 'REDUCE' ? 'e.g. Broke the no-KOS rule' : 'e.g. Event prize'} />
            </div>

            <button type="button" class="btn full {xpMode === 'ADD' ? 'btn-primary' : 'btn-danger'}" disabled={xpBlocked} on:click={adjust}>{xpMode === 'ADD' ? 'Add XP' : 'Remove XP'}</button>
            <div class="hint">Every change is written to the Gang XP ledger with your name and the reason, and shows live on every Map Zone.</div>
          </div>
        </section>

        <aside class="card summary">
          <header class="card-head">
            <span class="ico gold"><Icon name="activity" size={18} /></span>
            <div><h3>Summary</h3><p>What this change does.</p></div>
          </header>
          <div class="kv"><span>Gang</span><b>{gangLabel(gang)}</b></div>
          <div class="kv"><span>Gang XP now</span><b>{num(xpNow)}</b></div>
          <div class="kv"><span>Change</span><b class={xpMode === 'ADD' ? 'pos' : 'neg'}>{xpChange > 0 ? `${xpMode === 'ADD' ? '+' : '−'}${num(xpChange)}` : '—'}</b></div>
          <div class="kv total"><span>Gang XP after</span><b>{xpChange > 0 ? num(xpAfter) : num(xpNow)}</b></div>
          <div class="owns">
            <span>{gangLabel(gang)} holds</span>
            {#each owned as t (t.id)}<i class="chip-t"><b style="background:{t.color || '#c45ee0'}"></b>{t.name}</i>{:else}<em>no territory yet</em>{/each}
          </div>
        </aside>
      </div>
    {/if}

  <!-- ═════════════ Gang Messages: notice or warning (picked in the form) ═════════════ -->
  {:else}
    <div class="compose">
      <section class="card">
        <header class="card-head">
          <span class="ico {kindKey === 'WARNING' ? 'warn' : ''}"><Icon name={kindKey === 'WARNING' ? 'warning' : 'megaphone'} size={18} /></span>
          <div>
            <h3>{kindKey === 'WARNING' ? 'Gang Warning' : 'Gang Notice'}</h3>
            <p>{kindKey === 'WARNING' ? `A warning every member of ${gangLabel(gang)} must see.` : `Information for every member of ${gangLabel(gang)}.`}</p>
          </div>
        </header>
        <div class="form">
          {#if section === 'messages'}
            <div class="fld">
              <label for="gm-kind">Type of message</label>
              <select id="gm-kind" bind:value={msgKind}>
                <option value="NOTICE">Notice: information for the gang</option>
                <option value="WARNING">Warning: a warning the gang must see</option>
              </select>
            </div>
          {/if}
          <div class="fld">
            <label for="gm-msg">Message <em>every member sees this</em></label>
            <textarea id="gm-msg" rows="7" maxlength="400" bind:value={msgText} placeholder={kindKey === 'WARNING' ? 'e.g. Stop camping the auction house. Next time costs your gang 5,000 XP.' : 'e.g. Your territory war is scheduled for Friday 8 PM.'}></textarea>
            <small class="count">{msgText.length} / 400</small>
          </div>
          <div class="send-row">
            <button type="button" class="btn send {kindKey === 'WARNING' ? 'btn-danger' : 'btn-primary'}" disabled={actBusy || msgText.trim().length < 3} on:click={sendMessage}>Send {kindKey === 'WARNING' ? 'warning' : 'notice'} to {gangLabel(gang)}</button>
          </div>
        </div>
      </section>

      <aside class="card side">
        <header class="card-head">
          <span class="ico"><Icon name="info" size={18} /></span>
          <div><h3>How it is delivered</h3><p>What {gangLabel(gang)} sees.</p></div>
        </header>
        <ul class="how">
          <li><Icon name="eye" size={15} /><span><b>Online members</b> see a banner at once.</span></li>
          <li><Icon name="clock" size={15} /><span><b>Offline members</b> see it when they next log in.</span></li>
          <li><Icon name="fileText" size={15} /><span>It is posted to <b>Discord</b> under your name.</span></li>
        </ul>
        {#if kindKey === 'WARNING'}<div class="hint">To punish with XP use Gang XP → Add / Remove XP: it tells the gang why.</div>{/if}
      </aside>
    </div>
  {/if}
</div>

<style>
  /* Fills use the theme tokens (glass panel / head, themed lines) so the page follows the chosen background and accent. */
  .adm { display: flex; flex-direction: column; gap: 18px; }
  .cols { display: grid; gap: 16px; align-items: start; }
  .cols.two { grid-template-columns: minmax(300px, 1fr) minmax(420px, 2fr); }
  .cols.one { grid-template-columns: minmax(0, 1fr); }
  .cols.even { grid-template-columns: 1fr 1fr; }
  .cols.even.single { grid-template-columns: 1fr; }
  .compose { display: grid; grid-template-columns: minmax(0, 2fr) minmax(260px, 1fr); gap: 18px; align-items: start; }
  .send-row { display: flex; justify-content: flex-end; }
  .send { min-width: 260px; min-height: 46px; justify-content: center; }
  .how { display: flex; flex-direction: column; gap: 14px; margin: 0; padding: 0; list-style: none; }
  .how li { display: flex; align-items: flex-start; gap: 12px; font-size: var(--fs-body); line-height: 1.45; color: var(--text-dim, #c9ced4); }
  .how li :global(svg) { flex: none; margin-top: 2px; color: var(--accent-primary-light, #7bb6f2); }
  .how li b { color: var(--text-main, #fff); }
  .adjust { display: grid; grid-template-columns: minmax(0, 2fr) minmax(280px, 1fr); gap: 16px; align-items: start; }
  .card { display: flex; flex-direction: column; gap: 16px; padding: 22px 24px; min-width: 0; background: var(--glass-panel, rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); border-radius: var(--r-panel, 12px); }
  .card-head { display: flex; align-items: center; gap: 12px; padding-bottom: 12px; border-bottom: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.18)); }
  .card-head > div { flex: 1; min-width: 0; }
  .card-head h3 { margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; line-height: 1.1; }
  .card-head p { margin: 3px 0 0; font-size: var(--fs-small); color: var(--text-muted, #8d949c); }
  .ico { flex: none; width: 40px; height: 40px; display: grid; place-items: center; border-radius: 10px; color: var(--accent-primary-light, #7bb6f2); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .ico.gold { color: #111111; background: rgb(242, 195, 91); border-color: rgb(242, 195, 91); }
  .ico.warn { color: #111111; background: rgb(255, 176, 32); border-color: rgb(255, 176, 32); }

  /* the gang's own territories, when it has more than one */
  .picker { display: flex; flex-wrap: wrap; gap: 8px; }
  .pick { display: inline-flex; align-items: center; gap: 8px; height: 38px; padding: 0 16px; border-radius: var(--r-ctl, 8px); font-weight: 600; font-size: var(--fs-body); color: var(--text-dim, #c9ced4); background: var(--glass-panel, rgba(255, 255, 255, 0.04)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); cursor: pointer; }
  .pick:hover { border-color: var(--accent-primary); color: var(--text-main, #fff); }
  .pick.on { color: var(--on-accent); background: var(--c-action); border-color: var(--accent-primary); }
  .dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 8px; flex: none; }
  .pick .dot { margin-right: 0; }


  /* vertical forms: one field per row, full width of the card */
  .form { display: flex; flex-direction: column; gap: 18px; }
  .fld { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  .fld > span, .fld > label { font-size: var(--fs-small); font-weight: 600; color: var(--text-dim, #c9ced4); }
  .fld em { font-style: normal; font-weight: 400; color: var(--text-muted, #8d949c); font-size: var(--fs-meta); }
  .fld input, .fld select, .fld textarea {
    width: 100%; box-sizing: border-box; min-height: 46px; padding: 0 14px;
    background: var(--input-bg, rgba(11, 15, 22, 0.75)); border: 1px solid var(--input-border, rgba(110, 140, 180, 0.28)); border-radius: var(--r-ctl, 8px);
    color: var(--text-main, #fff); font-family: inherit; font-size: var(--fs-body);
    transition: border-color 0.12s ease, background 0.12s ease;
  }
  .fld textarea { padding: 12px 14px; line-height: 1.5; resize: vertical; min-height: 140px; }
  .fld input::placeholder, .fld textarea::placeholder { color: var(--text-placeholder, #6f7986); }
  .fld input:hover, .fld select:hover, .fld textarea:hover { border-color: var(--input-border-hover, rgba(140, 175, 220, 0.45)); }
  .fld input:focus, .fld select:focus, .fld textarea:focus { outline: none; border-color: var(--input-focus-border, var(--accent-primary)); background: var(--input-bg-focus, var(--input-bg)); }
  .fld input:disabled, .fld select:disabled { opacity: 0.5; cursor: not-allowed; }
  .count { align-self: flex-end; font-size: var(--fs-meta); color: var(--text-muted, #8d949c); }
  .row { display: flex; gap: 10px; flex-wrap: wrap; }
  .row .btn { flex: 1 1 auto; justify-content: center; min-height: 44px; }
  .full { width: 100%; min-height: 48px; justify-content: center; font-size: var(--fs-emph); }

  .note { padding: 9px 12px; border-radius: var(--r-ctl, 6px); font-size: var(--fs-small); border: 1px solid; }
  .note.ok { color: #46c98b; border-color: rgba(70, 201, 139, 0.5); }
  .note.bad { color: #ff8a8d; border-color: rgba(229, 72, 77, 0.5); }
  .note.warn { color: #ffc857; border-color: var(--c-line); background: var(--c-raised);
    border-left: 3px solid rgb(255, 200, 87);}
  .seg { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; padding: 4px; background: var(--glass-head, rgba(var(--ltc-8-11-16, 8, 11, 16), 0.5)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); border-radius: var(--r-ctl, 8px); }
  .seg button { height: 40px; border-radius: 6px; font-weight: 600; font-size: var(--fs-body); color: var(--text-dim, #aeb5bd); }
  .seg button.on { color: #46c98b; background: rgba(70, 201, 139, 0.18); }
  .seg button.neg.on { color: #ff8a8d; background: rgba(229, 72, 77, 0.2); }
  .seg button:disabled { opacity: 0.45; cursor: not-allowed; }
  .chips { display: flex; gap: 8px; flex-wrap: wrap; }
  .chip { height: 30px; padding: 0 14px; border-radius: 15px; font-size: var(--fs-small); font-weight: 600; color: var(--text-dim, #c9ced4); background: var(--glass-head, rgba(255, 255, 255, 0.05)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); }
  .chip:hover:not(:disabled) { border-color: var(--accent-primary); color: var(--text-main, #fff); }

  /* the summary beside the XP form */
  .summary { position: sticky; top: 0; }
  .kv { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; padding: 9px 0; border-bottom: 1px solid var(--c-line-soft, rgba(110, 140, 180, 0.12)); font-size: var(--fs-body); }
  .kv span { color: var(--text-muted, #8d949c); }
  .kv b { font-variant-numeric: tabular-nums; }
  .kv b.pos { color: #46c98b; }
  .kv b.neg { color: #ff8a8d; }
  .kv.total { border-bottom: 0; font-size: var(--fs-emph); }
  .kv.total b { font-family: var(--font-display); font-size: var(--fs-title); }
  .owns { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; padding: 9px 12px; border-radius: var(--r-ctl, 8px); background: var(--glass-head, rgba(var(--ltc-8-11-16, 8, 11, 16), 0.4)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.22)); font-size: var(--fs-small); color: var(--text-dim, #c9ced4); }
  .owns em { font-style: normal; color: var(--text-muted, #8d949c); }
  .chip-t { display: inline-flex; align-items: center; gap: 6px; font-style: normal; padding: 3px 10px; border-radius: 999px; font-weight: 600; color: var(--text-main, #fff); background: var(--glass-panel, rgba(255, 255, 255, 0.06)); border: 1px solid var(--tablet-border, rgba(110, 140, 180, 0.3)); }
  .chip-t b { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }

  .tbl-wrap { overflow-x: auto; border: 1px solid var(--tablet-border, var(--c-line, #2a2e35)); border-radius: var(--r-panel); background: rgba(var(--ink-rgb, 255, 255, 255), 0.035); }
  .tbl { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  .tbl th { text-align: left; padding: var(--tbl-th-y) var(--tbl-x); background: var(--glass-head, var(--c-panel)); color: var(--text-muted); border-bottom: 1px solid var(--tablet-border, var(--c-line)); white-space: nowrap; font-size: var(--fs-meta); font-weight: 600; }
  .tbl td { padding: var(--tbl-td-y) var(--tbl-x); border-bottom: 1px solid var(--c-line-soft); font-variant-numeric: tabular-nums; vertical-align: middle; }
  .tbl tr:last-child td { border-bottom: 0; }
  .tbl .num { text-align: right; }
  .cols.one .tbl { font-size: var(--fs-body-lg, 15px); }
  .cols.one .tbl th { padding: 14px 20px; font-size: var(--fs-small); }
  .cols.one .tbl td { padding: 14px 20px; }
  .tbl .strong { font-weight: 600; }
  .tbl .muted { color: var(--text-muted, #8d949c); }
  .tbl .pos { color: #46c98b; font-weight: 600; }
  .tbl .neg { color: #ff8a8d; font-weight: 600; }
  .st { padding: 3px 11px; border-radius: 999px; font-size: var(--fs-meta); font-weight: 600; background: rgba(255, 255, 255, 0.07); }
  .st.owned { color: #46c98b; background: rgba(70, 201, 139, 0.14); }
  .st.war { color: #ff8a8d; background: rgba(229, 72, 77, 0.16); }
  .hint { font-size: var(--fs-small); color: var(--text-muted, #8d949c); line-height: 1.5; }

  @media (max-width: 1150px) {
    .cols.two, .cols.even, .adjust, .compose { grid-template-columns: 1fr; }
    .summary { position: static; }
  }

  /* ── Tablet look: the tablet's own KPI tiles and sub-tabs, and FLAT sections — a ruled title and the content, no icon chips, no card
     inside the panel. ── */
  .gx-kpis { grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; }
  .gx-kpis .kpi-card, .gx-kcell { min-width: 0; }
  .gx-kv { font-size: 24px; display: flex; align-items: center; gap: 8px; }
  .card { gap: 14px; padding: 0; background: transparent; border: 0; border-radius: 0; }
  .card-head { gap: 12px; padding-bottom: 10px; border-bottom: 1px solid var(--c-line, rgba(110, 140, 180, 0.22)); }
  .card-head h3 { font-size: var(--fs-emph); font-weight: 700; }
  .ico { display: none; }
</style>
