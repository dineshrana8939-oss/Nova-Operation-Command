<script>
  import { createEventDispatcher } from 'svelte';
  import { updateStaff, setStaffStatus } from '../../../api/staff.js';
  import Icon from '../../ui/Icon.svelte';
  import FilterSelect from '../../ui/FilterSelect.svelte';
  import Modal from './Modal.svelte';
  import PermMatrix from './PermMatrix.svelte';
  import { sameMap } from './permLogic.js';

  export let member;
  export let roles = [];
  export let sections = [];
  export let me = {};

  const dispatch = createEventDispatcher();

  // Local draft — the overview can reload underneath without clobbering what the admin is typing.
  const original = { roleId: member.roleId ?? null, status: member.status, overrides: { ...(member.overrides || {}) } };
  let roleId = original.roleId;
  let status = original.status;
  let overrides = { ...original.overrides };
  let busy = false;
  let error = '';

  $: readOnly = !!member.locked || !me.canEdit;
  $: readOnlyReason = member.locked ? (member.lockedReason || 'This staff member is protected.') : !me.canEdit ? 'You do not have permission to edit staff.' : '';
  // a role the caller cannot edit is not one they can hand out either, but the member's current role always stays listed
  $: roleChoices = roles.filter((r) => r.assignable !== false || r.id === original.roleId);
  $: roleOptions = roleChoices.map((r) => ({ value: r.id, label: r.name }));
  $: role = roles.find((r) => r.id === roleId) || null;
  $: base = (role && role.permissions) || {};
  $: baseCount = Object.keys(base).length;
  $: statusOptions = [
    { value: 'active', label: 'Active' },
    { value: 'disabled', label: 'Disabled' },
    ...(me.canManage || original.status === 'revoked' ? [{ value: 'revoked', label: 'Revoked' }] : []),
  ];
  $: statusLocked = readOnly || (original.status === 'revoked' && !me.canManage);
  $: changed = roleId !== original.roleId || status !== original.status || !sameMap(overrides, original.overrides);
  $: statusBadge = { active: 'badge-completed', disabled: 'badge-cancelled', revoked: 'badge-failed' }[member.status] || 'badge-draft';

  async function save() {
    error = '';
    if (readOnly) return;
    if (roleId == null) { error = 'Choose a role.'; return; }
    busy = true;
    const patch = {};
    if (roleId !== original.roleId) patch.roleId = roleId;
    if (!sameMap(overrides, original.overrides)) patch.overrides = { ...overrides };
    if (Object.keys(patch).length) {
      const res = await updateStaff(member.identifier, patch);
      if (!res || !res.ok) { busy = false; error = (res && res.error) || 'Could not save the changes.'; if (/not authorized/i.test(error)) dispatch('stale'); return; }
    }
    if (status !== original.status) {
      const res = await setStaffStatus(member.identifier, status);
      if (!res || !res.ok) { busy = false; error = (res && res.error) || 'The permissions were saved, but the status could not be changed.'; dispatch('stale'); return; }
    }
    busy = false;
    dispatch('saved', { name: member.playerName });
  }
</script>

<Modal title="Edit staff" sub="Role, status and per-person permission overrides" icon="shield" width={900} {busy} on:close>
  <div class="es-head">
    <div class="es-who">
      <span class="es-name">{member.playerName}</span>
      {#if member.isSelf}<span class="es-tag">You</span>{/if}
      <span class="badge {statusBadge}">{member.status}</span>
    </div>
    <div class="es-ident" title={member.identifier}>{member.identifier}</div>
  </div>

  {#if readOnly}
    <div class="es-notice warn"><Icon name="warning" size={14} /> {readOnlyReason} Everything below is read-only.</div>
  {/if}
  {#if member.gang || member.job}
    <div class="es-notice">
      <Icon name="info" size={14} />
      <span>
        This player is {#if member.gang}in the gang <b>{member.gang}</b>{/if}{#if member.gang && member.job}{' and '}{/if}{#if member.job}works as <b>{member.job}</b>{/if}.
        Staff permissions are separate from gang permissions, and neither changes the other.
      </span>
    </div>
  {/if}

  <div class="es-grid">
    <div class="field">
      <!-- svelte-ignore a11y-label-has-associated-control -->
      <label>Role</label>
      {#if readOnly}
        <div class="es-static">{role ? role.name : 'No role'}</div>
      {:else}
        <FilterSelect bind:value={roleId} options={roleOptions} minWidth={220} title="Role" />
      {/if}
      <span class="es-help">{role ? `${role.name} gives ${baseCount} permission${baseCount === 1 ? '' : 's'}${role.description ? ' - ' + role.description : ''}` : 'This staff member has no role.'}</span>
    </div>
    <div class="field">
      <!-- svelte-ignore a11y-label-has-associated-control -->
      <label>Status</label>
      {#if statusLocked}
        <div class="es-static">{status}</div>
      {:else}
        <FilterSelect bind:value={status} options={statusOptions} minWidth={180} title="Status" />
      {/if}
      <span class="es-help">Disabled keeps the record but blocks access. Revoked removes access until it is granted again.</span>
    </div>
  </div>

  <PermMatrix {sections} mode="override" bind:value={overrides} {base} {me} {readOnly} maxHeight="40vh" />

  {#if error}<div class="error es-error" role="alert">{error}</div>{/if}

  <svelte:fragment slot="footer">
    <button class="btn" type="button" on:click={() => dispatch('close')} disabled={busy}>Cancel</button>
    <button class="btn btn-primary" type="button" on:click={save} disabled={busy || readOnly || !changed}>
      <Icon name="check" size={13} /> {busy ? 'Saving...' : 'Save changes'}
    </button>
  </svelte:fragment>
</Modal>

<style>
  .es-head { display: flex; align-items: baseline; justify-content: space-between; gap: 14px; margin-bottom: 12px; flex-wrap: wrap; }
  .es-who { display: flex; align-items: center; gap: 10px; }
  .es-name { font-size: var(--fs-title); font-weight: 700; color: var(--text-main); }
  .es-tag {
    height: 20px; padding: 0 7px; display: inline-flex; align-items: center;
    font-size: var(--fs-meta); font-weight: 700; color: var(--accent-primary-light);
    border: 1px solid rgba(var(--accent-primary-rgb), 0.45); border-radius: var(--r-tag);
  }
  .es-ident { font-family: var(--font-mono); font-size: var(--fs-small); color: var(--text-muted); max-width: 440px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .es-notice {
    display: flex; align-items: flex-start; gap: 9px; margin-bottom: 12px; padding: 9px 12px;
    font-size: var(--fs-small); line-height: 1.45; color: var(--text-dim);
    background: var(--c-base); border: 1px solid var(--c-line); border-radius: var(--r-ctl);
  }
  .es-notice :global(svg) { flex-shrink: 0; margin-top: 2px; color: var(--accent-primary-light); }
  .es-notice b { color: var(--text-main); }
  .es-notice.warn { border-color: rgba(var(--yellow-rgb), 0.45); }
  .es-notice.warn :global(svg) { color: var(--yellow); }
  .es-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: start; }
  .es-grid .field { margin-bottom: 12px; }
  .es-static {
    min-height: 38px; display: flex; align-items: center; padding: 0 12px; text-transform: capitalize;
    background: var(--c-base); border: 1px solid var(--c-line); border-radius: var(--r-ctl); color: var(--text-main); font-weight: 600;
  }
  .es-help { font-size: var(--fs-meta); color: var(--text-muted); line-height: 1.4; }
  .es-error { margin-top: 10px; }
</style>
