<script>
  import { onMount } from 'svelte';
  import Icon from '../../tablet/ui/Icon.svelte';
  import Toggle from '../../tablet/ui/Toggle.svelte';
  import AppearanceCard from '../../theme/AppearanceCard.svelte';
  import { DEFAULT_ACCENT, DEFAULT_BG, applyThemeQuietly } from '../../theme/appearance.js';
  import { gangPrefs } from '../../gangPrefs.js';
  import { crosshairCfg, crosshairPanelOpen } from '../../hud/hudStore.js';
  import { fetchNui } from '../../api/nui.js';

  // ── Appearance: the card drafts + previews; only Apply writes the saved look the whole tablet wears ──
  $: appliedLook = { accent: $gangPrefs.accent, bgTheme: $gangPrefs.bgTheme };
  const applyTheme = (e) => applyThemeQuietly(() => gangPrefs.update((p) => ({ ...p, accent: e.detail.accent, bgTheme: e.detail.bgTheme })));
  const resetTheme = () => applyThemeQuietly(() => gangPrefs.update((p) => ({ ...p, accent: DEFAULT_ACCENT, bgTheme: DEFAULT_BG })));

  // ── UI click sounds: this tablet only (the Admin Panel has its own switch) ──
  const toggleSounds = () => gangPrefs.update((p) => ({ ...p, clickSounds: !p.clickSounds }));

  // ── Custom crosshair: the player's own saved crosshair (client side), so it only ever changes THIS player's HUD ──
  let xhairBusy = false;
  let xhairError = '';
  onMount(() => {
    // show the real saved state (the answer also reaches the shared crosshair store through the normal HUD message)
    fetchNui('crosshair:getConfig').catch(() => {});
  });
  // Opens the same designer as /crosshair, on top of this tablet (the game side keeps the tablet's mouse when it closes).
  async function openCrosshairDesigner() {
    xhairError = '';
    try {
      await fetchNui('crosshair:getConfig');          // make sure the designer starts from the saved design
      crosshairPanelOpen.set(true);
      const res = await fetchNui('crosshair:openPanel');
      if (!res || res.ok === false) throw new Error('failed');
    } catch (err) {
      crosshairPanelOpen.set(false);
      xhairError = 'Could not open the crosshair designer. Try /crosshair.';
    }
  }
  async function toggleCrosshair(e) {
    const next = !!e.detail;
    const before = $crosshairCfg.enabled;
    xhairError = '';
    xhairBusy = true;
    crosshairCfg.update((c) => ({ ...c, enabled: next }));          // immediate, no restart or reopen needed
    try {
      const res = await fetchNui('crosshair:setEnabled', { enabled: next });
      if (!res || res.ok === false) throw new Error('failed');
    } catch (err) {
      crosshairCfg.update((c) => ({ ...c, enabled: before }));
      xhairError = 'Could not save that. Try again.';
    }
    xhairBusy = false;
  }
</script>

<div class="gs">
  <section class="card">
    <header class="card-head"><Icon name="palette" size={15} /> <span>Appearance</span><em>Only this Gang Tablet</em></header>
    <AppearanceCard applied={appliedLook} on:apply={applyTheme} on:reset={resetTheme} />
  </section>

  <div class="two">
    <section class="card">
      <header class="card-head"><Icon name={$gangPrefs.clickSounds ? 'volume' : 'volumeOff'} size={15} /> <span>UI Click Sounds</span></header>
      <div class="row">
        <p class="desc">The click sound when you press a tab, button or switch in this tablet. Turn it off for silent clicks here. Game sounds are not affected.</p>
        <Toggle label={$gangPrefs.clickSounds ? 'On' : 'Off'} checked={$gangPrefs.clickSounds} on:change={toggleSounds} />
      </div>
    </section>

    <section class="card">
      <header class="card-head"><Icon name="crosshair" size={15} /> <span>Gameplay &amp; HUD</span><em>Your own HUD</em></header>
      <div class="row">
        <p class="desc">
          <b>Custom Crosshair</b> — your own crosshair design replaces the game's reticle during TDM matches and in the Practice Range. Off = the normal game reticle.
        </p>
        <Toggle label={$crosshairCfg.enabled ? 'On' : 'Off'} checked={$crosshairCfg.enabled} disabled={xhairBusy} on:change={toggleCrosshair} />
      </div>
      <div class="xh-actions">
        <button type="button" class="btn btn-primary" on:click={openCrosshairDesigner}><Icon name="crosshair" size={14} /> Open Crosshair Designer</button>
      </div>
      <p class="hint">Changes apply at once and are remembered on this computer. It only changes your own screen, never anyone else's. The designer sets its shape, colour and size (you can also type <b>/crosshair</b>).</p>
      {#if xhairError}<p class="err">{xhairError}</p>{/if}
    </section>
  </div>
</div>

<style>
  .gs {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding-right: 4px;
  }
  .two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
  .card {
    padding: 14px 16px 16px;
    border-radius: var(--r-panel);
    background: var(--es-card);
    border: 1px solid var(--es-line);
  }
  .card-head {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 12px;
    font-size: var(--fs-emph, 16px);
    font-weight: 700;
    color: var(--lt-ffffff, #fff);
  }
  .card-head :global(svg) { color: var(--accent-primary-light, #66a3eb); }
  .card-head em { margin-left: auto; font-style: normal; font-size: var(--fs-meta, 12.5px); font-weight: 500; color: var(--text-muted); }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 18px; }
  .row :global(.toggle) { border-bottom: none; padding: 0; flex: none; }
  .desc { margin: 0; font-size: var(--fs-small, 13.5px); line-height: 1.5; color: var(--text-dim); }
  .desc b { color: var(--lt-ffffff, #fff); }
  .xh-actions { margin-top: 12px; }
  .hint { margin: 10px 0 0; font-size: var(--fs-meta, 12.5px); line-height: 1.5; color: var(--text-muted); }
  .hint b { color: var(--text-dim); }
  .err { margin: 8px 0 0; font-size: var(--fs-meta, 12.5px); color: var(--red, #e5524a); }

  @media (max-width: 1100px) { .two { grid-template-columns: 1fr; } }
</style>
