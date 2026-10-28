<script>
  // Shared upload widget for both the admin Gang Management branding section
  // and a gang leader's own self-service panel — the encode/downscale/preview
  // logic lives here once; callers just handle the resulting data URL.
  import { createEventDispatcher } from 'svelte';
  import GangLogo from './GangLogo.svelte';

  export let logo = null;
  export let label = '';
  export let disabled = false;
  export let busy = false;
  export let accentColor = null;

  const dispatch = createEventDispatcher();
  let fileInput;
  let pending = null; // data URL staged for upload, before the user confirms
  let error = '';

  const MAX_DIMENSION = 256; // no server-side image processing exists — downscale client-side

  function pickFile() {
    if (disabled) return;
    fileInput?.click();
  }

  function onFileSelected(e) {
    error = '';
    const file = e.target.files && e.target.files[0];
    e.target.value = ''; // allow re-selecting the same file later
    if (!file) return;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) {
      error = 'Use a PNG, JPG, or WEBP image.';
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, MAX_DIMENSION / Math.max(img.width, img.height));
        const w = Math.round(img.width * scale);
        const h = Math.round(img.height * scale);
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        canvas.getContext('2d').drawImage(img, 0, 0, w, h);
        pending = canvas.toDataURL('image/webp', 0.85);
      };
      img.onerror = () => { error = 'Could not read that image.'; };
      img.src = reader.result;
    };
    reader.onerror = () => { error = 'Could not read that file.'; };
    reader.readAsDataURL(file);
  }

  function confirmUpload() {
    if (!pending) return;
    dispatch('upload', pending);
    pending = null;
  }

  function cancelPending() {
    pending = null;
  }

  function remove() {
    dispatch('remove');
  }
</script>

<div class="logo-upload">
  <GangLogo logo={pending || logo} {label} {accentColor} size={72} />
  <div class="controls">
    <input type="file" accept="image/png,image/jpeg,image/webp" bind:this={fileInput} on:change={onFileSelected} hidden />
    {#if pending}
      <div class="pending-row">
        <button class="btn btn-primary" on:click={confirmUpload} disabled={busy}>{busy ? 'Uploading...' : 'Upload Logo'}</button>
        <button class="btn" on:click={cancelPending} disabled={busy}>Cancel</button>
      </div>
    {:else}
      <div class="pending-row">
        <button class="btn" on:click={pickFile} disabled={disabled || busy}>Upload New Logo</button>
        {#if logo}<button class="btn btn-danger" on:click={remove} disabled={disabled || busy}>Remove Logo</button>{/if}
      </div>
    {/if}
    {#if error}<div class="upload-error">{error}</div>{/if}
    <div class="hint">PNG, JPG, or WEBP — resized automatically</div>
  </div>
</div>

<style>
  .logo-upload {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .controls {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .pending-row {
    display: flex;
    gap: 8px;
  }
  .hint {
    font-size: var(--fs-small);
    color: var(--text-dim);
  }
  .upload-error {
    font-size: var(--fs-small);
    color: var(--tablet-danger);
  }
</style>
