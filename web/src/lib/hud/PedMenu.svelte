<script>
  // A vendor ped's shop window (TDM weapon vendor, tactical equipment): pick an item, then pay with cash or bank.
  // It only asks; the game side (client/modules/ped_menu.lua) fires the purchase and the server validates and charges it.
  import { pedMenu } from './pedMenuStore.js';
  import { fetchNui } from '../api/nui.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import '../../styles/flat.css';   // this window wears the same theme as the Event Status panel

  let selected = null;
  let lastOpen = null;
  $: if ($pedMenu && $pedMenu !== lastOpen) { lastOpen = $pedMenu; selected = null; }
  $: if (!$pedMenu) lastOpen = null;
  $: items = $pedMenu?.items || [];
  $: current = items.find((i) => i.id === selected) || null;

  const money = (n) => '$' + Number(n || 0).toLocaleString();
  function close() { pedMenu.set(null); fetchNui('pedMenu:close'); }
  function pay(account) { if (current) fetchNui('pedMenu:pick', { id: current.id, account }); }
  function onKey(e) { if (e.key === 'Escape') { e.preventDefault(); close(); } }
</script>

<svelte:window on:keydown={$pedMenu ? onKey : undefined} />

{#if $pedMenu}
  <div class="pm-overlay" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} style={$gangThemeStyle} on:click|self={close}>
    <div class="pm" role="dialog" aria-label={$pedMenu.title}>
      <header class="pm-head">
        <span class="pm-ico"><Icon name="shield" size={18} /></span>
        <div class="pm-titles">
          <h1>{$pedMenu.title}</h1>
          {#if $pedMenu.subtitle}<p>{$pedMenu.subtitle}</p>{/if}
        </div>
        <button type="button" class="btn pm-x" on:click={close}><kbd>Esc</kbd> Close</button>
      </header>

      <div class="pm-list">
        {#if items.length === 0}<div class="pm-empty">Nothing is for sale right now.</div>{/if}
        {#each items as it (it.id)}
          <button type="button" class="pm-item" class:sel={it.id === selected} aria-pressed={it.id === selected} on:click={() => (selected = it.id)}>
            <span class="pm-name">
              <span class="n">{it.label}</span>
              {#if it.desc}<span class="m">{it.desc}</span>{/if}
            </span>
            {#if it.tag}<span class="pm-tag">{it.tag}</span>{/if}
            <span class="pm-price">{money(it.price)}</span>
          </button>
        {/each}
      </div>

      <footer class="pm-foot">
        {#if current}
          <div class="pm-after">Buy <b>{current.label}</b> for <b>{money(current.price)}</b></div>
          {#if $pedMenu.accounts}
            <button type="button" class="btn btn-create" on:click={() => pay('cash')}>Pay cash</button>
            <button type="button" class="btn btn-info" on:click={() => pay('bank')}>Pay bank</button>
          {:else}
            <button type="button" class="btn btn-create" on:click={() => pay('cash')}>Buy</button>
          {/if}
        {:else}
          <div class="pm-after">Pick an item to buy.</div>
        {/if}
      </footer>
    </div>
  </div>
{/if}

<style>
  .pm-overlay { position: fixed; inset: 0; z-index: 6300; display: flex; align-items: center; justify-content: center; background: rgba(0, 0, 0, 0.62); pointer-events: all; font-family: var(--font-ui); }
  .pm { width: 560px; max-width: 94vw; max-height: 88vh; display: flex; flex-direction: column; overflow: hidden; color: var(--text-main); background: var(--c-panel); border: 1px solid var(--tablet-border-strong); border-radius: var(--r-panel); }
  .pm-head { display: flex; align-items: center; gap: 12px; padding: 16px 18px; background: var(--c-base); border-bottom: 1px solid var(--c-line); }
  .pm-ico { flex: none; width: 38px; height: 38px; display: grid; place-items: center; border-radius: var(--r-ctl); color: var(--on-accent); background: var(--c-action); }
  .pm-titles { min-width: 0; }
  h1 { margin: 0; font-size: var(--fs-title); font-weight: 700; line-height: 1.15; }
  p { margin: 3px 0 0; font-size: var(--fs-small); color: var(--text-dim); }
  .pm-x { margin-left: auto; display: inline-flex; align-items: center; gap: 8px; }
  kbd { font: 600 11px var(--font-ui); padding: 1px 6px; border-radius: 4px; border: 1px solid currentColor; }
  .pm-list { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 12px 18px; display: flex; flex-direction: column; gap: 8px; }
  .pm-empty { padding: 22px; text-align: center; color: var(--text-dim); font-size: var(--fs-body); }
  .pm-item { display: flex; align-items: center; gap: 12px; padding: 10px 14px; text-align: left; font: inherit; color: inherit; cursor: pointer; background: var(--c-raised); border: 1px solid var(--c-line); border-radius: var(--r-ctl); }
  .pm-item:hover { border-color: var(--tablet-border-hover); background: var(--c-hover); }
  .pm-item.sel { background: var(--c-action); border-color: var(--c-action); color: var(--on-accent); }
  .pm-name { min-width: 0; flex: 1; display: flex; flex-direction: column; }
  .pm-name .n { font-size: var(--fs-body); font-weight: 600; }
  .pm-name .m { margin-top: 2px; font-size: var(--fs-meta); color: var(--text-dim); }
  .pm-item.sel .m { color: var(--on-accent); opacity: 0.75; }
  .pm-tag { flex: none; padding: 2px 8px; font-size: var(--fs-meta); font-weight: 700; border-radius: 4px; color: #0a0a0a; background: #f59e0b; }
  .pm-price { flex: none; padding: 3px 10px; font-size: var(--fs-small); font-weight: 700; border-radius: 4px; color: #fff; background: #3b82f6; font-variant-numeric: tabular-nums; }
  .pm-foot { display: flex; align-items: center; gap: 8px; padding: 12px 18px 16px; border-top: 1px solid var(--c-line); }
  .pm-after { margin-right: auto; font-size: var(--fs-small); color: var(--text-dim); }
  .pm-after b { color: var(--text-main); }
</style>
