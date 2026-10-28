<script>
  import { saveStaffRole, deleteStaffRole } from '../../../api/staff.js';
  import { confirmAction } from '../../ui/confirm.js';
  import Icon from '../../ui/Icon.svelte';
  import FilterSelect from '../../ui/FilterSelect.svelte';
  import Modal from './Modal.svelte';
  import PermMatrix from './PermMatrix.svelte';
  import { normaliseMap, sameMap } from './permLogic.js';

  export let ov;
  export let ok = (msg) => {};
  export let fail = (res, fallback) => {};
  export let reload = async () => {};

  let selectedId = null; // role id, 'new' or null
  let draft = null; // { name, description, permissions }
  let busy = false;
  let formError = '';
  let reassign = null; // { role, staffCount, target, error }

  const fromRole = (r) => ({ name: r.name, description: r.description || '', permissions: { ...(r.permissions || {}) } });

  $: roles = ov.roles || [];
  $: sections = ov.sections || [];
  $: me = ov.me || {};
  $: current = typeof selectedId === 'number' ? roles.find((r) => r.id === selectedId) || null : null;
  $: isNew = selectedId === 'new';
  $: isOwnerRole = !!current && current.systemKey === 'owner';
  $: lockReason = current
    ? (isOwnerRole ? 'The Owner role always holds every permission and cannot be edited.' : current.locked ? (current.lockedReason || 'You cannot edit this role.') : !me.canManage ? 'You do not have permission to manage roles.' : '')
    : !me.canManage ? 'You do not have permission to manage roles.' : '';
  $: readOnly = !!lockReason;
  $: nameLocked = readOnly || (!!current && current.isSystem);

  // keep an untouched draft in step with live changes from other admins; a role that vanished clears the editor
  $: syncWithOverview(ov);
  function syncWithOverview(_ov) {
    if (typeof selectedId !== 'number') return;
    const r = (_ov.roles || []).find((x) => x.id === selectedId);
    if (!r) { selectedId = null; draft = null; return; }
    if (!isDirty(r)) draft = fromRole(r);
  }
  // `source` = the saved role the draft is compared against (defaults to the currently selected one)
  function isDirty(source) {
    if (!draft) return false;
    if (selectedId === 'new') return !!(draft.name || draft.description || Object.keys(draft.permissions).length);
    const r = source || roles.find((x) => x.id === selectedId);
    if (!r) return false;
    return draft.name !== r.name || draft.description !== (r.description || '') || !sameMap(normaliseMap(draft.permissions, sections), normaliseMap(r.permissions || {}, sections));
  }
  $: dirty = (draft, selectedId, roles, sections, isDirty());

  async function select(id) {
    if (id === selectedId) return;
    if (isDirty() && !(await confirmAction('You have unsaved changes to this role. Discard them?', { title: 'Discard changes', confirmLabel: 'Discard' }))) return;
    formError = '';
    selectedId = id;
    const r = roles.find((x) => x.id === id);
    draft = r ? fromRole(r) : null;
  }
  async function startNew() {
    if (isDirty() && !(await confirmAction('You have unsaved changes to this role. Discard them?', { title: 'Discard changes', confirmLabel: 'Discard' }))) return;
    formError = '';
    selectedId = 'new';
    draft = { name: '', description: '', permissions: {} };
  }
  function cancelEdit() {
    formError = '';
    if (isNew) { selectedId = null; draft = null; return; }
    const r = roles.find((x) => x.id === selectedId);
    draft = r ? fromRole(r) : null;
  }

  async function save() {
    formError = '';
    const name = (draft.name || '').trim();
    if (!name) { formError = 'Give the role a name.'; return; }
    busy = true;
    const payload = { name, description: (draft.description || '').trim(), permissions: normaliseMap(draft.permissions, sections) };
    if (current) payload.id = current.id;
    const res = await saveStaffRole(payload);
    busy = false;
    if (!res || !res.ok) { formError = (res && res.error) || 'Could not save the role.'; if (/not authorized/i.test(formError)) reload(); return; }
    ok(`Role "${(res.role && res.role.name) || name}" saved.`);
    await reload();
    if (res.role && typeof res.role.id === 'number') { selectedId = res.role.id; const r = (ov.roles || []).find((x) => x.id === res.role.id); draft = r ? fromRole(r) : fromRole(res.role); }
  }

  async function remove(target) {
    const role = target || current;
    if (!role) return;
    if (role.staffCount > 0) { reassign = { role, staffCount: role.staffCount, target: null, error: '' }; return; }
    const yes = await confirmAction(`Delete the role "${role.name}"? This cannot be undone.`, { title: `Delete role - ${role.name}`, danger: true, confirmLabel: 'Delete role' });
    if (!yes) return;
    await doDelete(role, null);
  }
  async function doDelete(role, reassignTo) {
    busy = true;
    const res = await deleteStaffRole(role.id, reassignTo);
    busy = false;
    if (res && res.ok) {
      reassign = null;
      ok(reassignTo != null ? `Role "${role.name}" deleted. Its staff were moved.` : `Role "${role.name}" deleted.`);
      if (selectedId === role.id) { selectedId = null; draft = null; }
      await reload();
      return;
    }
    if (res && res.code === 'NEEDS_REASSIGN') {
      reassign = { role, staffCount: res.staffCount ?? role.staffCount ?? 0, target: null, error: '' };
      return;
    }
    const msg = (res && res.error) || 'Could not delete the role.';
    if (reassign) reassign = { ...reassign, error: msg }; else fail(res, msg);
  }

  $: reassignChoices = reassign ? roles.filter((r) => r.id !== reassign.role.id && r.assignable !== false) : [];
  $: reassignOptions = [{ value: null, label: 'Select a role...' }, ...reassignChoices.map((r) => ({ value: r.id, label: r.name }))];
  async function confirmReassign() {
    if (reassign.target == null) { reassign = { ...reassign, error: 'Choose the role to move them to.' }; return; }
    await doDelete(reassign.role, reassign.target);
  }
  function setTarget(e) { reassign = { ...reassign, target: e.detail, error: '' }; }
</script>

<div class="rt">
  <aside class="rt-list">
    <div class="rt-list-head">
      <span class="rt-list-title">Roles</span>
      <button class="btn btn-sm btn-primary" type="button" disabled={!me.canManage} title={me.canManage ? '' : 'You do not have permission to manage roles.'} on:click={startNew}>
        <Icon name="plus" size={12} /> New role
      </button>
    </div>
    <div class="rt-items" data-testid="role-list">
      {#each roles as r (r.id)}
        <div class="rt-item" class:sel={selectedId === r.id} data-role={r.id}>
          <button type="button" class="rt-main" on:click={() => select(r.id)}>
            <span class="rt-name">
              {r.name}
              {#if r.isSystem}<span class="rt-sys">System</span>{/if}
              {#if r.locked}<Icon name="shield" size={11} />{/if}
            </span>
            <span class="rt-desc">{r.description || 'No description'}</span>
            <span class="rt-count">{r.staffCount} staff</span>
          </button>
          <div class="rt-acts">
            <button type="button" class="icon-btn-mini" title={r.locked ? (r.lockedReason || 'Read-only') : 'Edit role'} on:click={() => select(r.id)}><Icon name={r.locked || r.systemKey === 'owner' ? 'eye' : 'edit'} size={12} /></button>
            {#if !r.isSystem && me.canManage}
              <button type="button" class="icon-btn-mini danger" title={r.locked ? (r.lockedReason || 'Protected') : 'Delete role'} disabled={r.locked} data-del={r.id}
                on:click={() => remove(r)}>
                <Icon name="trash" size={12} />
              </button>
            {/if}
          </div>
        </div>
      {/each}
      {#if roles.length === 0}<div class="rt-empty">No roles yet.</div>{/if}
    </div>
  </aside>

  <section class="rt-editor">
    {#if !draft}
      <div class="empty-state">Select a role to see its permissions, or create a new one.</div>
    {:else}
      <div class="rt-ed-head">
        <div class="rt-ed-title">
          <Icon name="shield" size={15} />
          {isNew ? 'New role' : current ? current.name : 'Role'}
          {#if current && current.isSystem}<span class="rt-sys">System</span>{/if}
        </div>
        {#if dirty}<span class="rt-dirty"><span class="rt-dot"></span>Unsaved changes</span>{/if}
      </div>

      {#if readOnly}
        <div class="rt-notice"><Icon name="warning" size={14} /> {lockReason} The permissions below are read-only.</div>
      {:else if current && current.isSystem}
        <div class="rt-notice"><Icon name="info" size={14} /> {current.name} is a system role: you can change its permissions and description, but it cannot be renamed or deleted.</div>
      {/if}

      <div class="rt-fields">
        <div class="field">
          <label for="rt-name">Name</label>
          <input id="rt-name" type="text" maxlength="40" placeholder="e.g. Event Host" bind:value={draft.name} disabled={nameLocked || busy} />
        </div>
        <div class="field">
          <label for="rt-desc">Description <span class="optional">optional</span></label>
          <textarea id="rt-desc" rows="2" maxlength="140" placeholder="What is this role for?" bind:value={draft.description} disabled={readOnly || busy}></textarea>
          <span class="rt-counter">{(draft.description || '').length}/140</span>
        </div>
      </div>

      <PermMatrix {sections} mode="role" bind:value={draft.permissions} {me} {readOnly} maxHeight="none" />

      {#if formError}<div class="error rt-error" role="alert">{formError}</div>{/if}

      <div class="rt-foot">
        <div>
          {#if current && !current.isSystem && me.canManage}
            <button class="btn btn-danger" type="button" disabled={busy || current.locked} title={current.locked ? (current.lockedReason || '') : ''} on:click={() => remove()}><Icon name="trash" size={13} /> Delete role</button>
          {/if}
        </div>
        <div class="rt-foot-r">
          <button class="btn" type="button" disabled={busy} on:click={cancelEdit}>Cancel</button>
          <button class="btn btn-primary" type="button" disabled={busy || readOnly || (!isNew && !dirty)} on:click={save}>
            <Icon name="check" size={13} /> {busy ? 'Saving...' : isNew ? 'Create role' : 'Save role'}
          </button>
        </div>
      </div>
    {/if}
  </section>
</div>

{#if reassign}
  <Modal title="Move staff before deleting" sub={`Role: ${reassign.role.name}`} icon="users" width={460} {busy} on:close={() => (reassign = null)}>
    <p class="rs-text"><b>{reassign.staffCount}</b> staff {reassign.staffCount === 1 ? 'uses' : 'use'} this role &mdash; move {reassign.staffCount === 1 ? 'them' : 'them'} to:</p>
    <div class="field">
      <!-- svelte-ignore a11y-label-has-associated-control -->
      <label>New role</label>
      {#if reassignChoices.length}
        <FilterSelect value={reassign.target} options={reassignOptions} minWidth={260} title="Move staff to" on:change={setTarget} />
      {:else}
        <div class="error">There is no other role you can move them to. Create one first.</div>
      {/if}
    </div>
    <p class="rs-help">Their individual overrides are kept. The role is deleted once they have moved.</p>
    {#if reassign.error}<div class="error" role="alert">{reassign.error}</div>{/if}
    <svelte:fragment slot="footer">
      <button class="btn" type="button" disabled={busy} on:click={() => (reassign = null)}>Cancel</button>
      <button class="btn btn-danger" type="button" disabled={busy || reassignChoices.length === 0} on:click={confirmReassign}>
        <Icon name="trash" size={13} /> {busy ? 'Working...' : 'Move staff and delete role'}
      </button>
    </svelte:fragment>
  </Modal>
{/if}

<style>
  /* two panes that fill the window: the role list and the editor share one height, only the matrix (and a long list) scroll */
  .rt { display: grid; grid-template-columns: 320px minmax(0, 1fr); gap: 16px; align-items: stretch; height: clamp(520px, calc(94vh - 330px), 760px); }
  .rt-list { display: flex; flex-direction: column; min-width: 0; border: 1px solid var(--c-line); border-radius: var(--r-panel); background: var(--c-base); overflow: hidden; }
  .rt-list-head { display: flex; align-items: center; justify-content: space-between; padding: 10px 12px; border-bottom: 1px solid var(--c-line); background: var(--c-panel); }
  .rt-list-title { font-weight: 700; color: var(--text-main); }
  .rt-items { flex: 1; min-height: 0; overflow-x: hidden; overflow-y: auto; }
  .rt-item { position: relative; display: flex; align-items: stretch; border-bottom: 1px solid var(--c-line-soft); }
  .rt-item:last-child { border-bottom: 0; }
  .rt-item:hover { background: var(--c-raised); }
  .rt-item.sel { background: var(--c-hover); box-shadow: inset 2px 0 0 var(--accent-primary); }
  .rt-main {
    flex: 1; min-width: 0; overflow: hidden; display: flex; flex-direction: column; align-items: stretch; gap: 3px; text-align: left; white-space: normal;
    padding: 10px 4px 10px 12px; background: transparent; border: 0; border-radius: 0; cursor: pointer;
    font-family: var(--font-ui); color: var(--text-main);
  }
  .rt-name { display: flex; align-items: center; gap: 7px; font-weight: 700; font-size: var(--fs-body); }
  .rt-name :global(svg) { color: var(--text-muted); }
  /* two lines at most, kept inside the card so it never runs under the action buttons */
  .rt-desc {
    display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; line-clamp: 2;
    max-width: 100%; overflow: hidden; word-break: break-word;
    font-size: var(--fs-meta); line-height: 1.35; color: var(--text-muted);
  }
  .rt-count { font-size: var(--fs-meta); color: var(--text-dim); }
  .rt-sys {
    height: 18px; padding: 0 6px; display: inline-flex; align-items: center;
    font-size: var(--fs-meta); font-weight: 700; color: var(--text-dim);
    border: 1px solid var(--c-line); border-radius: var(--r-tag); background: var(--c-raised);
  }
  .rt-acts { display: flex; flex-direction: column; justify-content: center; gap: 4px; padding: 6px 8px 6px 2px; }
  .rt-empty { padding: 20px; text-align: center; color: var(--text-muted); font-size: var(--fs-small); }

  .rt-editor { border: 1px solid var(--c-line); border-radius: var(--r-panel); background: var(--c-panel); padding: 14px 16px; min-width: 0; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }
  /* nothing selected yet: a centred prompt that fills the pane instead of a small box */
  .rt-editor > :global(.empty-state) { flex: 1; display: grid; place-items: center; min-height: 320px; border: 0; background: transparent; text-align: center; }
  .rt-ed-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }
  .rt-ed-title { display: flex; align-items: center; gap: 9px; font-size: var(--fs-emph); font-weight: 700; color: var(--text-main); }
  .rt-ed-title :global(svg) { color: var(--accent-primary); }
  .rt-dirty { display: inline-flex; align-items: center; gap: 7px; font-size: var(--fs-small); font-weight: 600; color: var(--yellow); }
  .rt-dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
  .rt-notice {
    display: flex; align-items: flex-start; gap: 9px; margin-bottom: 12px; padding: 9px 12px;
    font-size: var(--fs-small); line-height: 1.45; color: var(--text-dim);
    background: var(--c-base); border: 1px solid var(--c-line); border-radius: var(--r-ctl);
  }
  .rt-notice :global(svg) { flex-shrink: 0; margin-top: 2px; color: var(--accent-primary-light); }
  .rt-fields { display: grid; grid-template-columns: minmax(180px, 1fr) minmax(0, 2fr); gap: 14px; align-items: start; }
  .rt-fields .field { margin-bottom: 12px; position: relative; }
  .rt-fields textarea {
    width: 100%; min-height: 56px; resize: none; box-sizing: border-box; padding: 9px 12px;
    font-family: var(--font-ui); font-size: var(--fs-body); line-height: 1.45; color: var(--text-main);
    background: var(--input-bg); border: 1px solid var(--input-border); border-radius: var(--r-ctl);
  }
  .rt-fields textarea:hover:not(:disabled) { border-color: var(--input-border-hover); }
  .rt-fields textarea:focus { outline: none; border-color: var(--input-focus-border, var(--accent-primary)); background: var(--input-bg-focus, var(--input-bg)); }
  .rt-fields textarea:disabled { opacity: 0.6; cursor: not-allowed; }
  .rt-counter { position: absolute; right: 10px; bottom: 6px; font-size: var(--fs-meta); color: var(--text-muted); pointer-events: none; }
  .rt-error { margin-top: 10px; }
  /* Save / Cancel stay at the bottom of the visible area while the matrix scrolls */
  .rt-foot { flex: none; z-index: 4; display: flex; align-items: center; justify-content: space-between; gap: 10px; margin: 14px -16px -14px; padding: 12px 16px; border-top: 1px solid var(--c-line); background: var(--c-panel); border-radius: 0 0 var(--r-panel) var(--r-panel); }
  .rt-foot-r { display: flex; gap: 10px; }
  .rs-text { margin: 0 0 12px; color: var(--text-dim); font-size: var(--fs-body); line-height: 1.5; }
  .rs-text b { color: var(--text-main); }
  .rs-help { margin: 0 0 10px; font-size: var(--fs-meta); color: var(--text-muted); }
</style>
