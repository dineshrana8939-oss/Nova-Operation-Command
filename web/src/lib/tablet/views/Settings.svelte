<script>
  import { onMount } from 'svelte';
  import {
    getScheduleSettings,
    setScheduleSettings,
  } from '../../api/convoy.js';
  import { adminPrefs, resetAdminPrefs, PAGE_SIZE_CHOICES } from '../../adminPrefs.js';
  import Icon from '../ui/Icon.svelte';
  import WorldPeds from './WorldPeds.svelte';
  import { viewSub } from '../../stores.js';
  import Toggle from '../ui/Toggle.svelte';
  import { getStaffTag, setStaffTag } from '../../api/staffTag.js';
  import AppearanceCard from '../../theme/AppearanceCard.svelte';
  import { DEFAULT_ACCENT, DEFAULT_BG, applyThemeQuietly } from '../../theme/appearance.js';
  import '../tablet-theme.css';

  // ── Admin-panel preferences (this browser only; they apply to EVERY tab of the Operations Hub right away) ─────────────
  const set = (key, value) => adminPrefs.update((p) => ({ ...p, [key]: value }));

  // Appearance: the card drafts and previews; only Apply writes into the saved prefs the whole panel wears.
  $: appliedLook = { accent: $adminPrefs.accent, bgTheme: $adminPrefs.bgTheme };
  const applyTheme = (e) => applyThemeQuietly(() => adminPrefs.update((p) => ({ ...p, accent: e.detail.accent, bgTheme: e.detail.bgTheme })));
  const resetTheme = () => applyThemeQuietly(() => adminPrefs.update((p) => ({ ...p, accent: DEFAULT_ACCENT, bgTheme: DEFAULT_BG })));

  // ── Scheduling (admin only, server-wide) ─────────────────────────────────────────────────────────────────────────────
  // The whole Settings tab is admin-only (Config.CreatorAccess.adminOnlyTabs) and the server-side callbacks re-check
  // Bridge.IsAdmin independently, since this governs how EVERY schedule date/time on the server is interpreted.
  let utcOffsetHours = 0;
  let pollIntervalSeconds = 15;
  let savingSchedule = false;
  let scheduleSaved = false;
  let scheduleError = '';

  async function loadScheduleSettings() {
    const res = await getScheduleSettings();
    if (res && res.ok) {
      utcOffsetHours = res.settings.utcOffsetHours;
      pollIntervalSeconds = res.settings.pollIntervalSeconds;
    }
  }

  async function saveScheduleSettings() {
    scheduleError = '';
    savingSchedule = true;
    const res = await setScheduleSettings(Number(utcOffsetHours), Number(pollIntervalSeconds));
    savingSchedule = false;
    if (!res || !res.ok) { scheduleError = (res && res.error) || 'Failed to save scheduling settings.'; return; }
    utcOffsetHours = res.settings.utcOffsetHours;
    pollIntervalSeconds = res.settings.pollIntervalSeconds;
    scheduleSaved = true;
    setTimeout(() => (scheduleSaved = false), 3000);
  }

  // ── Staff tag over my head (shown to the players near me while it is on; the server decides ADMIN vs EVENT STAFF) ──
  let tagAvailable = null;   // 'ADMIN' | 'EVENT STAFF' | null (this player may not wear one)
  let tagOn = false;
  let tagBusy = false;
  async function loadStaffTag() {
    const res = await getStaffTag();
    if (res && res.ok) { tagAvailable = res.available || null; tagOn = res.enabled === true; }
  }
  async function toggleStaffTag() {
    if (!tagAvailable || tagBusy) return;
    tagBusy = true;
    const next = !tagOn;
    await setStaffTag(next);
    tagOn = next;
    tagBusy = false;
  }

  onMount(() => {
    loadStaffTag();
    loadScheduleSettings();
  });
</script>

{#if $viewSub === 'worldpeds'}
  <WorldPeds />
{:else}
<div class="panel view-enter">
  <div class="panel-header">
    <span class="panel-title"><Icon name="gear" size={14} /> Settings</span>
    <button class="btn" on:click={resetAdminPrefs} title="Put every preference below back to its default"><Icon name="refresh" size={13} /> Reset preferences</button>
  </div>
  <div class="panel-body">
    <p class="staff-hint">Staff and permissions now live in the <b>Staff Management</b> section.</p>

    <!-- ── 2a. Appearance & Sound (Admin Panel only — the Gang Tablet keeps its own) ───────── -->
    <div class="section-title">Appearance &amp; Sound <span class="section-sub">this browser only · Admin Panel only · the Gang Tablet has its own</span></div>

    <div class="appearance-box">
      <AppearanceCard applied={appliedLook} on:apply={applyTheme} on:reset={resetTheme} />
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">UI Click Sounds</div>
        <div class="live-action-desc">The click sound on every tab, button and toggle of this Admin Panel. Off = silent clicks here. Nothing else changes: gameplay audio, announcements and the Gang Tablet's own switch are untouched.</div>
      </div>
      <Toggle label={$adminPrefs.clickSounds ? 'On' : 'Off'} checked={$adminPrefs.clickSounds} on:change={() => set('clickSounds', !$adminPrefs.clickSounds)} />
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Staff tag over my head</div>
        <div class="live-action-desc">
          {#if tagAvailable}
            While this is on, players near you see <b>{tagAvailable}</b> floating over your head. It is remembered on this computer and switched back on when you join. Only you can switch it, and it only exists while you are online.
          {:else}
            Not available: only admins and members of the event staff can wear a tag.
          {/if}
        </div>
      </div>
      <Toggle label={tagOn ? 'On' : 'Off'} checked={tagOn} disabled={!tagAvailable || tagBusy} on:change={toggleStaffTag} />
    </div>

    <!-- ── 2b. Admin Panel Preferences ───────────────────────────────────────── -->
    <div class="section-title">Admin Panel Preferences <span class="section-sub">this browser only · applies to every tab immediately</span></div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Rows per page</div>
        <div class="live-action-desc">How many rows every table starts with (Manage Events, Event History, leaderboards, participants, tournaments, territory tables…). Each table still has its own Rows selector.</div>
      </div>
      <div class="seg">
        {#each PAGE_SIZE_CHOICES as n}
          <button type="button" class:active={$adminPrefs.pageSize === n} on:click={() => set('pageSize', n)}>{n}</button>
        {/each}
      </div>
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Clock format</div>
        <div class="live-action-desc">12-hour (08:50 PM) or 24-hour (20:50) clock in the top bar.</div>
      </div>
      <div class="seg">
        <button type="button" class:active={!$adminPrefs.clock24} on:click={() => set('clock24', false)}>12-hour</button>
        <button type="button" class:active={$adminPrefs.clock24} on:click={() => set('clock24', true)}>24-hour</button>
      </div>
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Menu layout</div>
        <div class="live-action-desc">Floating tabs across the top (the pages of the open group appear under them), or the classic side rail.</div>
      </div>
      <div class="seg">
        <button type="button" class:active={$adminPrefs.navLayout !== 'side'} on:click={() => set('navLayout', 'top')}>Top tabs</button>
        <button type="button" class:active={$adminPrefs.navLayout === 'side'} on:click={() => set('navLayout', 'side')}>Side rail</button>
      </div>
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Sidebar density</div>
        <div class="live-action-desc">Side rail only: comfortable spreads the menu down the whole panel; compact packs it tight for small screens.</div>
      </div>
      <div class="seg">
        <button type="button" class:active={$adminPrefs.sidebar === 'comfortable'} on:click={() => set('sidebar', 'comfortable')}>Comfortable</button>
        <button type="button" class:active={$adminPrefs.sidebar === 'compact'} on:click={() => set('sidebar', 'compact')}>Compact</button>
      </div>
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Map brightness</div>
        <div class="live-action-desc">How bright the GTA basemap is on the Map Zone and every territory map. Raise it if the map looks dull.</div>
      </div>
      <div class="slider-wrap">
        <input type="range" min="70" max="170" step="5" value={$adminPrefs.mapBrightness} on:input={(e) => set('mapBrightness', Number(e.currentTarget.value))} />
        <span class="slider-val">{$adminPrefs.mapBrightness}%</span>
      </div>
    </div>

    <div class="live-action">
      <div>
        <div class="live-action-title">Ask before routine actions</div>
        <div class="live-action-desc">Confirmation pop-ups for ordinary actions (Start, Reuse, Clone, move a ped…). Off = they just happen. Destructive actions — Delete, Cancel, Force End, removing Gang XP — always ask, whatever this says.</div>
      </div>
      <Toggle label={$adminPrefs.confirmRoutine ? 'On' : 'Off'} checked={$adminPrefs.confirmRoutine} on:change={() => set('confirmRoutine', !$adminPrefs.confirmRoutine)} />
    </div>

    <!-- ── 3. Scheduling ─────────────────────────────────────────────────────── -->
    <div class="section-title">Scheduling <span class="section-sub">admin only · server-wide</span></div>
    <div class="live-action schedule-action">
      <div>
        <div class="live-action-title">Server UTC Offset (hours)</div>
        <div class="live-action-desc">What timezone an admin-entered schedule date/time (Create Event → Review → Auto-Start Schedule) is interpreted in, e.g. -5 for EST, 5.5 for IST. Independent of the host machine's own clock.</div>
      </div>
      <input class="schedule-input" type="number" step="0.25" min="-14" max="14" bind:value={utcOffsetHours} />
    </div>
    <div class="live-action schedule-action">
      <div>
        <div class="live-action-title">Scheduler Poll Interval (seconds)</div>
        <div class="live-action-desc">How often the server checks for scheduled events that came due. Lower = more responsive auto-start, at the cost of an extra DB scan that often.</div>
      </div>
      <input class="schedule-input" type="number" step="1" min="5" max="3600" bind:value={pollIntervalSeconds} />
    </div>
    <div class="launch-row" style="margin-top:10px">
      <button class="btn btn-primary" on:click={saveScheduleSettings} disabled={savingSchedule}>
        <Icon name="check" size={13} /> {savingSchedule ? 'Saving...' : 'Save Scheduling Settings'}
      </button>
      {#if scheduleSaved}<span class="success-flash"><Icon name="check" size={13} /> Saved — takes effect immediately, no restart needed</span>{/if}
    </div>
    {#if scheduleError}<div class="error">{scheduleError}</div>{/if}

    <p class="moved-note">The police equipment vendor and escort vehicle shop peds now live under <b>Events → Convoy Peds</b>.</p>
  </div>
</div>
{/if}

<style>
  .section-title {
    margin: 18px 0 8px;
    font-size: var(--fs-small);
    font-weight: var(--fw-nav);
    letter-spacing: 0.01em;
    color: var(--text-main);
  }
  .section-title:first-child { margin-top: 4px; }
  .section-sub { margin-left: 8px; font-size: var(--fs-meta); letter-spacing: 0; text-transform: none; font-weight: 500; color: var(--text-dim); }
  .live-action {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 14px 16px;
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
  }
  .live-action + .live-action { margin-top: 10px; }
  .appearance-box {
    padding: 14px 16px;
    margin-bottom: 10px;
    border-radius: var(--radius-md);
    background: var(--tablet-panel-alt);
    border: 1px solid var(--tablet-border);
  }
  .live-action > div:first-child { flex: 1; min-width: 0; }
  .live-action-title { font-size: var(--fs-body); font-weight: 600; color: var(--text-main); }
  .live-action-desc { font-size: var(--fs-small); color: var(--text-dim); margin-top: 3px; max-width: 900px; line-height: 1.5; }
  .success-flash { display: flex; align-items: center; gap: 6px; color: var(--tablet-success); font-size: var(--fs-body); font-weight: 600; }
  .schedule-action { align-items: center; }
  .schedule-input {
    width: 100px;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--tablet-border-strong);
    background: var(--tablet-panel);
    color: var(--text-main);
    font-family: var(--font-mono);
    font-size: var(--fs-body);
    text-align: right;
  }
  .launch-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .seg { display: inline-flex; border: 1px solid var(--lt-2a2e35, #2a2e35); border-radius: var(--r-ctl); overflow: hidden; flex-shrink: 0; }
  .seg button { padding: 8px 16px; background: var(--lt-181b1f, #181b1f); color: var(--lt-aeb5bd, #aeb5bd); font-weight: 600; font-size: var(--fs-small); }
  .seg button.active { background: var(--c-action); color: var(--on-accent); }
  .slider-wrap { display: flex; align-items: center; gap: 12px; flex-shrink: 0; }
  .slider-wrap input[type='range'] { width: 220px; accent-color: var(--accent-primary); }
  .slider-val { min-width: 48px; text-align: right; font-family: var(--font-mono); font-weight: 700; color: var(--lt-ffffff, #fff); }
  .moved-note { margin-top: 22px; font-size: var(--fs-small); color: var(--text-dim); }
  .moved-note b { color: var(--lt-ffffff, #fff); }
  .staff-hint { margin: 4px 0 6px; font-size: var(--fs-small); color: var(--text-dim); }
  .staff-hint b { color: var(--lt-ffffff, #fff); }
</style>
