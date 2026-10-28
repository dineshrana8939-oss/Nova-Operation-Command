<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../tablet/ui/Icon.svelte';
  import { avatarColor, initials } from '../util/avatar.js';

  export let c; // convoy (from getUpcomingConvoys) — name/shortDescription/cargo/difficulty/scheduledAt/kind/gangPvp/policeRegistered*
  export let isPolice;
  export let rosterEntry = null; // this leader's roster.convoys entry for c.id, or null if not gang-eligible
  export let members = []; // roster.members — the leader's own gang roster to pick from
  export let draftSet = new Set(); // currently-picked identifiers (parent-owned draft state for c.id)
  export let saving = false;
  export let registeringPolice = false;
  export let unregistering = false; // non-leader member backing out of their own registration
  export let isRegisteredTab = false; // true if rendering in the "Registered" tab
  export let alwaysShowPicker = false; // fallback for backwards-compatibility
  export let formatScheduled = (ts) => ts;

  const dispatch = createEventDispatcher();

  let showPicker = false;
  let isEditing = false;

  $: inRegisteredTab = isRegisteredTab || alwaysShowPicker;

  $: registered = !!(rosterEntry && rosterEntry.roster && rosterEntry.roster.length > 0);
  $: atCap = rosterEntry ? draftSet.size >= rosterEntry.maxGangParticipants : false;
  $: maxPoliceLimit = (c.maxPoliceParticipants != null && Number(c.maxPoliceParticipants) > 0) ? Number(c.maxPoliceParticipants) : 20;

  function handleSave() {
    dispatch('save');
    isEditing = false;
    showPicker = false;
  }

  function handleCancel() {
    isEditing = false;
    showPicker = false;
    dispatch('cancel');
  }
</script>

<div class="card upcoming-card">
  <div class="upcoming-eyebrow">Upcoming Event</div>
  <div class="card-header">
    <span class="name">{c.name}</span>
    {#if !isPolice && registered}
      <span class="badge badge-completed"><Icon name="check" size={11} /> Registered</span>
    {:else}
      <span class="badge badge-draft">{c.status === 'SCHEDULED' ? 'Scheduled' : 'Not Started'}</span>
    {/if}
  </div>
  {#if c.shortDescription}<div class="desc">{c.shortDescription}</div>{/if}
  {#if c.kind === 'TDM'}
    <div class="row"><span class="k">Format</span><span class="v">{c.tdm?.matchFormat === 'TOURNAMENT' ? 'Tournament' : 'Standard'}</span></div>
  {:else}
    <div class="row"><span class="k">Cargo</span><span class="v">{c.cargo.type}</span></div>
    <div class="row"><span class="k">Difficulty</span><span class="v">{c.difficulty}</span></div>
  {/if}
  {#if c.scheduledAt}
    <div class="row"><span class="k">Departs</span><span class="v">{formatScheduled(c.scheduledAt)}</span></div>
  {/if}

  {#if isPolice && c.kind === 'HOT_CARGO'}
    <div class="row"><span class="k">Police Response</span><span class="v" style="color: #eceff1; font-weight:600;">Active Interception / Radar Pursuit</span></div>
    <p class="hint" style="color: #eceff1;">Open response event. Dispatch alerts all on-duty officers with live GPS radar tracking when the contraband truck is hijacked.</p>
  {:else if !isPolice && c.kind === 'HOT_CARGO'}
    <div class="row"><span class="k">Event Mode</span><span class="v" style="color: #cfd4d9; font-weight:600;">Open Gang Hijack</span></div>
    <p class="hint">Open Hijack Event. Compete to hijack the vehicle, evade police, and deliver to the dropoff.</p>
  {:else if isPolice && c.kind === 'CONVOY'}
    {#if c.maxPoliceParticipants === 0}
      <div class="row"><span class="k">Police Escorts</span><span class="v" style="color: var(--text-muted);">Disabled (0 spots)</span></div>
      <p class="hint">This convoy was configured with 0 police escort spots.</p>
    {:else}
      <div class="row"><span class="k">Police Escorts</span><span class="v">Up to {maxPoliceLimit}</span></div>
      <p class="hint">On-duty officers are on escort duty automatically when the convoy starts — there is nothing to sign up for.</p>
    {/if}
  {:else if !isPolice && rosterEntry}
    {#if inRegisteredTab}
      <!-- SECOND TAB: REGISTERED TAB -->
      {#if !isEditing}
        <div class="row">
          <span class="k">Gang Signed Up</span>
          <span class="signup-count">{rosterEntry.roster.length}/{rosterEntry.maxGangParticipants}</span>
        </div>
        {#if rosterEntry.roster.length > 0}
          <div class="roster-chips-wrap">
            {#each rosterEntry.roster as id (id)}
              {@const m = members.find((x) => x.identifier === id)}
              <span class="roster-chip">
                <span class="member-avatar-mini" style="background:{avatarColor(m?.name || id)}">{initials(m?.name || id)}</span>
                <span class="roster-chip-name">{m?.name || id}</span>
              </span>
            {/each}
          </div>
        {/if}
        <div class="btn-row" style="margin-top: 10px;">
          <button class="btn btn-primary" on:click={() => (isEditing = true)}>
            <Icon name="edit" size={12} /> Edit Roster
          </button>
          <button class="btn btn-danger" disabled={saving} on:click={() => dispatch('unregisterAll')}>
            Unregister Gang
          </button>
        </div>
      {:else}
        <!-- EDITING FUNCTION IN REGISTERED TAB -->
        <div class="row">
          <span class="k">Editing Gang Roster</span>
          <span class="signup-count" class:full={atCap}>{draftSet.size}/{rosterEntry.maxGangParticipants}</span>
        </div>
        {#if atCap}<p class="hint">Roster is full — remove someone before adding another.</p>{/if}
        <div class="member-list">
          {#each members as m (m.identifier)}
            {@const picked = draftSet.has(m.identifier)}
            <button
              type="button" class="member-pick" class:picked={picked}
              disabled={!picked && atCap}
              on:click={() => dispatch('toggleMember', { identifier: m.identifier })}
            >
              <span class="member-avatar" style="background:{avatarColor(m.name || m.identifier)}">{initials(m.name || m.identifier)}</span>
              <span class="member-pick-name">{m.name}</span>
              <span class="member-pick-check"><Icon name="check" size={13} /></span>
            </button>
          {/each}
        </div>
        <div class="btn-row">
          <button class="btn btn-primary" disabled={saving} on:click={handleSave}>
            {saving ? 'Saving...' : 'Save Roster'}
          </button>
          <button class="btn" disabled={saving} on:click={handleCancel}>
            Cancel
          </button>
          <button class="btn btn-danger" disabled={saving} on:click={() => dispatch('unregisterAll')}>
            Unregister Gang
          </button>
        </div>
        <p class="hint">You can keep adding, removing, or swapping members here right up until this event actually starts.</p>
      {/if}
    {:else}
      <!-- FIRST TAB: UPCOMING EVENTS (CONVOYS TAB) -->
      {#if registered}
        <!-- Already registered: clean status display WITHOUT "Edit Here" button -->
        <div class="row">
          <span class="k">Gang Signed Up</span>
          <span class="signup-count">{rosterEntry.roster.length}/{rosterEntry.maxGangParticipants}</span>
        </div>
        <p class="hint">Manage who's on the roster from the Registered tab.</p>
      {:else if !showPicker}
        <!-- Plain "Register" action to open initial registration -->
        <button class="btn btn-primary" on:click={() => (showPicker = true)}>
          <Icon name="plus" size={12} /> Register
        </button>
      {:else}
        <!-- Initial registration picker -->
        <div class="row">
          <span class="k">Gang Signed Up</span>
          <span class="signup-count" class:full={atCap}>{draftSet.size}/{rosterEntry.maxGangParticipants}</span>
        </div>
        {#if atCap}<p class="hint">Roster is full — remove someone before adding another.</p>{/if}
        <div class="member-list">
          {#each members as m (m.identifier)}
            {@const picked = draftSet.has(m.identifier)}
            <button
              type="button" class="member-pick" class:picked={picked}
              disabled={!picked && atCap}
              on:click={() => dispatch('toggleMember', { identifier: m.identifier })}
            >
              <span class="member-avatar" style="background:{avatarColor(m.name || m.identifier)}">{initials(m.name || m.identifier)}</span>
              <span class="member-pick-name">{m.name}</span>
              <span class="member-pick-check"><Icon name="check" size={13} /></span>
            </button>
          {/each}
        </div>
        <div class="btn-row">
          <button class="btn btn-primary" disabled={saving} on:click={handleSave}>
            {saving ? 'Saving...' : 'Save Roster'}
          </button>
          <button class="btn" on:click={handleCancel}>
            Cancel
          </button>
        </div>
        <p class="hint">Pick your crew and save the roster to register your gang for this event.</p>
      {/if}
    {/if}
  {:else if !isPolice && c.gangPvp && c.gangRegistered}
    <!-- Not the leader — no picker access — but this IS someone the leader
         already added, so let them back themselves out directly instead of
         having to go ask the leader to do it. -->
    <div class="row"><span class="k">Status</span><span class="v">Registered</span></div>
    <button class="btn btn-danger" disabled={unregistering} on:click={() => dispatch('unregisterSelf')}>
      {unregistering ? 'Working...' : 'Unregister'}
    </button>
  {:else if !isPolice && c.gangPvp}
    <p class="hint">Ask your gang leader to sign you up on the roster once this departs.</p>
  {/if}
</div>

<style>
  .card {
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-md);
    padding: 12px;
    background: var(--tablet-panel-alt);
  }
  .btn-row {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .upcoming-card {
    position: relative;
  }
  .upcoming-eyebrow {
    display: inline-block;
    font-size: var(--fs-meta);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--tablet-text-faint);
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: 999px;
    padding: 2px 9px;
    margin-bottom: 8px;
  }
  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
  }
  .name {
    font-size: var(--fs-emph);
    font-weight: var(--fw-heading);
    color: var(--text-main);
  }
  .desc {
    font-size: var(--fs-body);
    color: var(--text-dim);
    margin-bottom: 8px;
  }
  .row {
    display: flex;
    justify-content: space-between;
    padding: 5px 0;
    font-size: var(--fs-body);
  }
  .k { color: var(--text-dim); font-weight: var(--fw-nav); }
  .v { color: var(--text-main); font-family: var(--font-mono); font-weight: var(--fw-value); }
  .hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
    line-height: 1.5;
    margin: 6px 0 0;
  }
  .signup-count {
    font-size: var(--fs-small);
    font-weight: var(--fw-value);
    font-family: var(--font-mono);
    color: var(--tablet-success);
  }
  .signup-count.full {
    color: var(--tablet-warn);
  }
  .police-reg-alert {
    display: flex;
    align-items: center;
    gap: 8px;
    background: var(--c-raised);
    border: 1px solid var(--c-line);
    border-radius: var(--radius-sm);
    padding: 7px 10px;
    margin: 8px 0;
    color: var(--lt-70b982, #70b982);
    font-size: var(--fs-small);
    font-weight: 500;
    border-left: 3px solid rgb(112, 185, 130);}
  .roster-chips-wrap {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin: 8px 0;
  }
  .roster-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    font-size: var(--fs-meta);
    color: var(--text-main);
  }
  .member-avatar-mini {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .member-list {
    display: flex;
    flex-direction: column;
    gap: 7px;
    margin: 10px 0;
  }
  .member-pick {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    background: var(--tablet-bg);
    border: 1px solid var(--tablet-border);
    border-radius: var(--radius-sm);
    padding: 8px 12px;
    font-family: var(--font-ui);
    text-align: left;
    transition: border-color 0.12s ease, background 0.12s ease, transform 0.12s ease;
  }
  .member-pick:not(:disabled):hover {
    transform: translateX(2px);
  }
  .member-pick:hover {
    border-color: var(--tablet-border-strong);
  }
  .member-pick.picked {
    background: rgba(var(--ink-rgb, 255, 255, 255), 0.06);
    border-color: var(--view-accent, var(--accent-primary));
  }
  .member-pick:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .member-avatar {
    width: 28px;
    height: 28px;
    border-radius: 999px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: var(--fs-meta);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .member-pick-name {
    flex: 1;
    font-size: var(--fs-body);
    font-weight: 500;
    color: var(--text-main);
  }
  .member-pick-check {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    border: 1px solid var(--tablet-border-strong);
    color: transparent;
    flex-shrink: 0;
    transition: border-color 0.12s ease, background 0.12s ease, color 0.12s ease;
  }
  .member-pick.picked .member-pick-check {
    background: var(--view-accent, var(--accent-primary));
    border-color: var(--view-accent, var(--accent-primary));
    color: var(--lt-ffffff, #fff);
  }
</style>
