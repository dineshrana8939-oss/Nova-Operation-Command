<script>
  // Staff Management: who can use this admin panel, which role they hold, and what each role / person may do.
  // The server enforces everything; this view only hides or disables what the signed-in admin cannot do.
  import { onMount, onDestroy } from 'svelte';
  import { getStaffOverview } from '../../api/staff.js';
  import { staffVersion, viewSub } from '../../stores.js';
  import Icon from '../ui/Icon.svelte';
  import StaffTab from './staff/StaffTab.svelte';
  import RolesTab from './staff/RolesTab.svelte';
  import ActivityTab from './staff/ActivityTab.svelte';
  import '../tablet-theme.css';

  // Staffs / Roles / Activity are the floating row under the main menu (sub pages of Staff), so the open one comes from the shared viewSub
  $: tab = ['staff', 'roles', 'activity'].includes($viewSub) ? $viewSub : 'staff';
  let ov = null;
  let loading = true;
  let loadError = '';
  let tick = 0; // bumps on every successful overview load (the Activity tab follows it)
  let notice = ''; // success message
  let problem = ''; // error message
  let noticeTimer;
  let unsub;
  let ready = false;
  let inflight = null;

  async function load() {
    // collapse overlapping loads (own action + the staffVersion bump the server sends)
    if (inflight) return inflight;
    inflight = (async () => {
      const res = await getStaffOverview();
      loading = false;
      if (res && res.ok) {
        ov = res;
        loadError = '';
        tick += 1;
      } else {
        loadError = (res && res.error) || 'Could not load staff data.';
      }
      inflight = null;
    })();
    return inflight;
  }

  function ok(msg) {
    problem = '';
    notice = msg;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => (notice = ''), 4000);
  }
  // shows the server's reason; a live permission change ("not authorized") also refreshes what the UI offers
  function fail(res, fallback) {
    notice = '';
    problem = (res && res.error) || fallback || 'Something went wrong.';
    if (/not authorized/i.test(problem)) load();
  }

  onMount(() => {
    load();
    unsub = staffVersion.subscribe(() => {
      if (!ready) { ready = true; return; } // the immediate first callback is not a change
      load();
    });
  });
  onDestroy(() => { if (unsub) unsub(); clearTimeout(noticeTimer); });
</script>

<div class="panel view-enter">
  <div class="panel-header">
    <span class="panel-title"><Icon name="shield" size={14} /> Staff Management</span>
    <button class="btn" type="button" on:click={load} disabled={loading}><Icon name="refresh" size={13} /> Refresh</button>
  </div>
  <div class="panel-body">
    {#if loading && !ov}
      <div class="empty-state">Loading staff...</div>
    {:else if !ov}
      <div class="empty-state">
        <div class="error" role="alert">{loadError}</div>
        <button class="btn" type="button" style="margin-top: 12px" on:click={load}><Icon name="refresh" size={13} /> Try again</button>
      </div>
    {:else}
      {#if notice}
        <div class="sm-banner ok" role="status"><Icon name="check" size={14} /> {notice}</div>
      {/if}
      {#if problem}
        <div class="sm-banner bad" role="alert">
          <Icon name="warning" size={14} /> <span class="sm-msg">{problem}</span>
          <button class="sm-x" type="button" title="Dismiss" on:click={() => (problem = '')}><Icon name="close" size={12} /></button>
        </div>
      {/if}
      {#if loadError}
        <div class="sm-banner bad" role="alert"><Icon name="warning" size={14} /> <span class="sm-msg">{loadError} Showing the last data that loaded.</span></div>
      {/if}

      {#if tab === 'staff'}
        <StaffTab {ov} {ok} {fail} reload={load} />
      {:else if tab === 'roles'}
        <RolesTab {ov} {ok} {fail} reload={load} />
      {:else}
        <ActivityTab {tick} />
      {/if}
    {/if}
  </div>
</div>

<style>
  .sm-banner {
    display: flex; align-items: center; gap: 9px; margin-bottom: 12px; padding: 9px 12px;
    font-size: var(--fs-small); border-radius: var(--r-ctl); border: 1px solid var(--c-line);
  }
  .sm-banner.ok { color: var(--green); background: var(--green-dim); border-color: rgba(70, 201, 139, 0.4); }
  .sm-banner.bad { color: var(--lt-ff8076, #ff8076); background: var(--c-raised); border-color: var(--c-line);
    border-left: 3px solid #ef4444;}
  .sm-msg { flex: 1; min-width: 0; }
  .sm-x { display: flex; margin-left: auto; padding: 4px; background: transparent; border: 0; color: inherit; cursor: pointer; border-radius: var(--r-ctl); }
  .sm-x:hover { background: rgba(var(--ink-rgb, 255, 255, 255), 0.08); }
</style>
