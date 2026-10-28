<script>
  // Vehicle showroom: the list on the left, the shop ped (the game's own camera) on the right. Used by the Race Token
  // Exchange (price in race tokens) and the Police Escort Vehicle Shop (free loaners / paid with cash or bank, returnable).
  // The game owns the camera and every purchase; this only shows the list and sends the player's choice back
  // (client/modules/showroom.lua answers showroom:buy / showroom:return / showroom:close).
  import { onDestroy } from 'svelte';
  import { fade } from 'svelte/transition';
  import { showroom, showroomPed } from './showroomStore.js';
  import { fetchNui } from '../api/nui.js';
  import Icon from '../tablet/ui/Icon.svelte';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import '../tablet/tablet-theme.css';
  import '../../styles/flat.css';   // this window wears the same theme as the Event Status panel

  const STAT_NAMES = ['Top speed', 'Acceleration', 'Braking', 'Handling'];

  let selected = 0;
  let filter = 'All';
  let busy = false;
  let toast = null;            // { text, ok }
  let toastTimer;
  let amount = 0;              // race tokens in hand (kept live after a trade)
  let checkedOut = false;
  let lastOpen = null;

  // a fresh opening resets the view
  $: if ($showroom && $showroom !== lastOpen) {
    lastOpen = $showroom;
    selected = 0;
    filter = 'All';
    busy = false;
    toast = null;
    amount = $showroom.wallet?.kind === 'tokens' ? ($showroom.wallet.amount || 0) : 0;
    checkedOut = !!$showroom.checkedOut;
  }
  $: if (!$showroom) lastOpen = null;

  $: isTokens = $showroom?.shop === 'tokens';
  $: vehicles = $showroom?.vehicles || [];
  $: categories = [...new Set(vehicles.map((v) => v.category).filter(Boolean))];
  $: visible = vehicles.filter((v) => filter === 'All' || v.category === filter);
  $: if (visible.length && !visible.some((v) => v.index === selected)) selected = visible[0].index;
  $: current = vehicles.find((v) => v.index === selected) || null;

  const cost = (v) => (isTokens ? (v.tokens || 0) : (v.price || 0));
  const money = (n) => '$' + Number(n || 0).toLocaleString();
  const short = (v) => isTokens && v.tokens > amount;
  const nameOf = (v) => (v.label || '').split(' — ')[0].split(' (')[0];

  $: canBuy = !!current && !current.missing && !busy && (!isTokens || current.tokens <= amount);

  function say(v) {
    if (!v) return '';
    if (v.missing) return `I can't get hold of that one — it isn't on this server.`;
    if (isTokens) {
      return v.tokens <= amount
        ? `${nameOf(v)}? Good pick — ${v.tokens} token${v.tokens === 1 ? '' : 's'}, and she's yours.`
        : `That one's ${v.tokens} tokens. Come back when you've won a few more races.`;
    }
    return v.price > 0
      ? `The ${nameOf(v)} is ${money(v.price)} — I'll refund it when you bring it back.`
      : `Take the ${nameOf(v)} — it's a loaner, bring it back when you're done.`;
  }

  function showToast(text, ok) {
    clearTimeout(toastTimer);
    toast = { text, ok };
    toastTimer = setTimeout(() => (toast = null), 2600);
  }
  onDestroy(() => clearTimeout(toastTimer));

  async function buy(account) {
    if (!canBuy) return;
    busy = true;
    const res = await fetchNui('showroom:buy', { index: current.index, account });
    busy = false;
    if (res && res.ok) {
      if (res.tokens != null) amount = res.tokens;
      if (!isTokens) checkedOut = true;
      showToast(res.message || 'Done.', true);
    } else {
      showToast((res && res.error) || 'That did not work — try again.', false);
    }
  }

  async function giveBack() {
    if (busy) return;
    busy = true;
    const res = await fetchNui('showroom:return', {});
    busy = false;
    if (res && res.ok) { checkedOut = false; showToast(res.message || 'Returned.', true); }
    else showToast((res && res.error) || 'Could not return it.', false);
  }

  function close() { fetchNui('showroom:close', {}); }

  function onKey(e) {
    if (!$showroom) return;
    if (e.key === 'Escape') { e.preventDefault(); close(); return; }
    if (checkedOut && !isTokens) return;
    const list = visible;
    const at = list.findIndex((v) => v.index === selected);
    if (e.key === 'ArrowDown' && list.length) { e.preventDefault(); selected = list[Math.min(list.length - 1, at + 1)].index; }
    else if (e.key === 'ArrowUp' && list.length) { e.preventDefault(); selected = list[Math.max(0, at - 1)].index; }
    else if (e.key === 'Enter' && current && (isTokens || !(current.price > 0))) { e.preventDefault(); buy('cash'); }
  }
</script>

<svelte:window on:keydown={onKey} />

{#if $showroom}
  <div class="sr-root" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} transition:fade={{ duration: 160 }} style={$gangThemeStyle}>
    <!-- shaded left edge so the panel reads against whatever the game shows -->
    <div class="sr-shade"></div>

    <!-- vehicle silhouettes (side view) -->
    <svg width="0" height="0" style="position:absolute" aria-hidden="true">
      <defs>
        <symbol id="sr-car" viewBox="0 0 120 48" fill="currentColor"><path d="M6 33c0-3 1-5 4-6l13-3 14-12c2-2 4-3 7-3h24c4 0 7 2 9 5l7 9 14 3c3 1 5 3 5 7v3c0 1-1 2-2 2h-6a11 11 0 0 0-22 0H42a11 11 0 0 0-22 0h-9c-3 0-5-2-5-5z"/><circle cx="31" cy="38" r="7" fill="#0a0d12"/><circle cx="31" cy="38" r="3.2"/><circle cx="91" cy="38" r="7" fill="#0a0d12"/><circle cx="91" cy="38" r="3.2"/></symbol>
        <symbol id="sr-suv" viewBox="0 0 120 48" fill="currentColor"><path d="M5 34V24c0-2 1-4 4-5l12-3 11-9c2-2 4-3 7-3h42c3 0 5 1 7 3l8 9h8c4 0 6 2 6 5v13c0 1-1 2-2 2h-7a11 11 0 0 0-22 0H40a11 11 0 0 0-22 0h-9c-2 0-4-1-4-3z"/><circle cx="29" cy="38" r="7" fill="#0a0d12"/><circle cx="29" cy="38" r="3.2"/><circle cx="91" cy="38" r="7" fill="#0a0d12"/><circle cx="91" cy="38" r="3.2"/></symbol>
        <symbol id="sr-truck" viewBox="0 0 120 48" fill="currentColor"><path d="M4 8h66v26H4z"/><path d="M74 14h22l12 12v8H74z"/><circle cx="22" cy="38" r="7" fill="#0a0d12"/><circle cx="22" cy="38" r="3.2"/><circle cx="52" cy="38" r="7" fill="#0a0d12"/><circle cx="52" cy="38" r="3.2"/><circle cx="96" cy="38" r="7" fill="#0a0d12"/><circle cx="96" cy="38" r="3.2"/></symbol>
        <symbol id="sr-bike" viewBox="0 0 120 48" fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><circle cx="24" cy="34" r="10"/><circle cx="96" cy="34" r="10"/><path d="M24 34 44 18h20l12 16M64 18 56 8h-8M76 34l14-22h8"/><path d="M44 18l8 16h24"/></symbol>
      </defs>
    </svg>

    <!-- the ped's speech, above its head on the right -->
    {#if $showroomPed && current}
      <div class="sr-say" style="left:calc({$showroomPed.x * 100}% + 170px); top:{$showroomPed.y * 100}%;">{say(current)}</div>
    {/if}

    <div class="sr-dock">
    <aside class="sr-panel" role="dialog" aria-label={$showroom.title}>
      <header class="sr-head">
        <span class="sr-ico" class:tok={isTokens}><Icon name={isTokens ? 'ticket' : 'shield'} size={20} /></span>
        <div class="sr-titles">
          <h1>{$showroom.title}</h1>
          <p>{$showroom.subtitle}</p>
        </div>
        <button type="button" class="sr-x" on:click={close} aria-label="Leave the shop"><Icon name="close" size={14} /></button>
      </header>

      <!-- what you have -->
      {#if isTokens}
        <div class="sr-wallet">
          <span class="sr-ico tok"><Icon name="ticket" size={20} /></span>
          <div>
            <div class="sr-lbl">Your race tokens</div>
            <div class="sr-big gold">{amount}</div>
          </div>
          <div class="sr-hint">{$showroom.wallet?.hint}</div>
        </div>
      {:else}
        <div class="sr-wallet">
          <span class="sr-ico"><Icon name="shield" size={20} /></span>
          <div>
            <div class="sr-lbl">{$showroom.wallet?.label || 'Escort vehicles'}</div>
            <div class="sr-note">{$showroom.wallet?.note}</div>
          </div>
        </div>
      {/if}

      {#if !isTokens && checkedOut}
        <!-- the escort shop, with a vehicle already out: give it back -->
        <div class="sr-return">
          <div class="sr-return-art"><svg viewBox="0 0 120 48"><use href="#sr-car" /></svg></div>
          <h2>You have a vehicle checked out</h2>
          <p>Hand it back here. Anything you paid for is refunded to the account you used.</p>
          <button type="button" class="btn btn-primary sr-cta" disabled={busy} on:click={giveBack}>
            <Icon name="check" size={15} /> Return vehicle
          </button>
        </div>
      {:else}
        {#if categories.length > 1}
          <div class="sr-filters">
            <button type="button" class="sr-chip" aria-pressed={filter === 'All'} class:on={filter === 'All'} on:click={() => (filter = 'All')}>All</button>
            {#each categories as c}
              <button type="button" class="sr-chip" aria-pressed={filter === c} class:on={filter === c} on:click={() => (filter = c)}>{c}</button>
            {/each}
            <span class="sr-count">{visible.length} vehicle{visible.length === 1 ? '' : 's'}</span>
          </div>
        {:else}
          <div class="sr-filters"><span class="sr-count solo">{visible.length} vehicle{visible.length === 1 ? '' : 's'}</span></div>
        {/if}

        <div class="sr-list">
          {#if vehicles.length === 0}
            <div class="sr-empty">No vehicles are available right now.</div>
          {/if}
          {#each visible as v (v.index)}
            <button type="button" class="sr-car" aria-pressed={v.index === selected} class:sel={v.index === selected} class:locked={short(v) || v.missing} on:click={() => (selected = v.index)}>
              <span class="sr-thumb"><svg viewBox="0 0 120 48"><use href={`#sr-${v.type || 'car'}`} /></svg></span>
              <span class="sr-name">
                <span class="n">{v.label}</span>
                <span class="m">{v.missing ? 'Not installed on this server' : v.model}</span>
              </span>
              {#if isTokens}
                <span class="sr-price tok" class:short={short(v)}><Icon name="ticket" size={13} />{v.tokens}</span>
              {:else if v.price > 0}
                <span class="sr-price money">{money(v.price)}</span>
              {:else}
                <span class="sr-price free">Free</span>
              {/if}
            </button>
          {/each}
        </div>

        {#if current}
          <div class="sr-detail">
            <div class="sr-detail-row">
              <span class="sr-art"><svg viewBox="0 0 120 48"><use href={`#sr-${current.type || 'car'}`} /></svg></span>
              <div>
                <h2>{current.label}</h2>
                <div class="sr-model">{current.model}{current.category ? ` · ${current.category}` : ''}</div>
              </div>
            </div>
            {#if !current.missing}
              <div class="sr-stats">
                {#each STAT_NAMES as n, k}
                  <div class="sr-st"><span>{n}</span><span class="sr-bar"><i style="width:{current.stats?.[k] ?? 0}%"></i></span></div>
                {/each}
              </div>
              <div class="sr-src">Read from the game's own handling data for this model.</div>
            {/if}
          </div>

          <footer class="sr-foot">
            {#if isTokens}
              <div class="sr-after">
                {#if current.tokens <= amount}Tokens after the trade<br><b>{amount} → {amount - current.tokens}</b>
                {:else}You need <b>{current.tokens - amount} more token{current.tokens - amount === 1 ? '' : 's'}</b>{/if}
              </div>
              <button type="button" class="btn btn-primary sr-cta" disabled={!canBuy} on:click={() => buy('cash')}>
                <Icon name="ticket" size={16} /> Trade {current.tokens} token{current.tokens === 1 ? '' : 's'}
              </button>
            {:else if current.price > 0}
              <div class="sr-after">Pay <b>{money(current.price)}</b><br>Refunded when you return it.</div>
              <div class="sr-pay">
                <button type="button" class="btn btn-primary sr-cta" disabled={!canBuy} on:click={() => buy('cash')}>Pay cash</button>
                <button type="button" class="btn btn-secondary sr-cta" disabled={!canBuy} on:click={() => buy('bank')}>Pay bank</button>
              </div>
            {:else}
              <div class="sr-after">Return it to me when<br>the convoy ends.</div>
              <button type="button" class="btn btn-primary sr-cta" disabled={!canBuy} on:click={() => buy('cash')}>
                <Icon name="check" size={16} /> Check out
              </button>
            {/if}
          </footer>
        {/if}
      {/if}
    </aside>
    </div>

    {#if toast}
      <div class="sr-toast" class:bad={!toast.ok} transition:fade={{ duration: 140 }}>{toast.text}</div>
    {/if}

    <div class="sr-keys">
      <span><kbd>↑</kbd><kbd>↓</kbd>browse</span>
      <span><kbd>Enter</kbd>select</span>
      <span><kbd>Esc</kbd>leave the shop</span>
    </div>
  </div>
{/if}

<style>
  .sr-root { position: fixed; inset: 0; z-index: 400; pointer-events: none; font-family: var(--font-ui); color: var(--c-text, #eceef0); }
  .sr-shade { position: absolute; inset: 0; background: linear-gradient(90deg, rgba(5, 6, 8, 0.82) 0%, rgba(5, 6, 8, 0.4) 30%, rgba(5, 6, 8, 0) 50%); }

  /* ── panel: the tablet's own look ── */
  /* the dock keeps the panel centred on the left edge; the panel is only as tall as its content (a long list scrolls) */
  .sr-dock { position: absolute; left: 36px; top: 36px; bottom: 36px; display: flex; align-items: center; pointer-events: none; }
  .sr-panel {
    position: relative; width: 500px; max-height: 100%; zoom: 0.78;
    display: flex; flex-direction: column; overflow: hidden; pointer-events: auto;
    border-radius: 14px; border: 1px solid var(--tablet-border-strong);
    background-color: #07090d;
    background-image: radial-gradient(ellipse 95% 65% at 50% 22%, rgba(65, 86, 111, 0.42) 0%, rgba(18, 25, 36, 0.72) 52%, rgba(6, 8, 12, 0.94) 100%), var(--sr-bg);
    background-size: cover; background-position: center;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.6);
  }
  .sr-head { display: flex; align-items: center; gap: 12px; padding: 18px 20px 14px; border-bottom: 1px solid var(--c-line); background: var(--c-panel); }
  .sr-ico { width: 42px; height: 42px; flex: none; display: grid; place-items: center; border-radius: 9px; color: var(--c-action);
    background: var(--c-line); border: 1px solid var(--c-line); }
  .sr-ico.tok { color: #f2c35b; background: rgba(242, 195, 91, 0.14); border-color: rgba(242, 195, 91, 0.4); }
  .sr-titles { min-width: 0; }
  .sr-head h1 { margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 26px; font-weight: 700; line-height: 1.05; }
  .sr-head p { margin: 3px 0 0; font-size: 13.5px; color: var(--c-text-3, #8d949c); }
  .sr-x { margin-left: auto; width: 32px; height: 32px; flex: none; display: grid; place-items: center; border-radius: 8px; color: var(--c-text-2, #c9ced4);
    background: var(--c-raised); border: 1px solid var(--c-line); cursor: pointer; }
  .sr-x:hover { color: #fff; border-color: var(--c-action); }
  .sr-x:focus-visible, .sr-chip:focus-visible, .sr-car:focus-visible { outline: 2px solid var(--c-action); outline-offset: 2px; }
  .sr-chip, .sr-car, .sr-x { transition: border-color 0.15s, background 0.15s, color 0.15s; }

  .sr-wallet { display: flex; align-items: center; gap: 14px; margin: 16px 20px 0; padding: 14px 16px; border-radius: 12px;
    background: var(--c-raised); border: 1px solid var(--c-line); }
  .sr-lbl { font-size: 13.5px; color: var(--c-text-3, #8d949c); }
  .sr-big { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 40px; font-weight: 600; line-height: 1; font-variant-numeric: tabular-nums; }
  .sr-big.gold { color: #f2c35b; }
  .sr-hint { margin-left: auto; max-width: 190px; font-size: 13.5px; line-height: 1.4; color: var(--c-text-2, #c9ced4); }
  .sr-note { margin-top: 2px; font-size: 14px; line-height: 1.4; color: var(--c-text-2, #c9ced4); max-width: 330px; }

  .sr-filters { display: flex; align-items: center; gap: 8px; padding: 16px 20px 10px; flex-wrap: wrap; }
  .sr-chip { height: 32px; padding: 0 14px; border-radius: 8px; font-family: var(--font-ui); font-size: 14px; font-weight: 600; cursor: pointer;
    color: var(--c-text-2, #c9ced4); background: var(--c-raised); border: 1px solid var(--c-line); }
  .sr-chip.on { color: #fff; background: var(--c-line); border-color: var(--c-line); }
  .sr-count { margin-left: auto; font-size: 13px; color: var(--c-text-3, #8d949c); }
  .sr-count.solo { margin-left: 0; }

  .sr-list { flex: 0 1 auto; min-height: 0; overflow-y: auto; padding: 4px 20px 22px; display: flex; flex-direction: column; gap: 8px;
    scrollbar-width: thin; scrollbar-color: var(--tablet-border-strong) transparent;
    -webkit-mask-image: linear-gradient(180deg, #000 calc(100% - 18px), transparent); mask-image: linear-gradient(180deg, #000 calc(100% - 18px), transparent); }
  .sr-empty { padding: 20px; text-align: center; color: var(--c-text-3, #8d949c); }
  .sr-car { display: grid; grid-template-columns: 74px minmax(0, 1fr) auto; align-items: center; gap: 14px; padding: 10px 14px 10px 10px; border-radius: 12px; text-align: left; cursor: pointer;
    font-family: var(--font-ui); color: inherit; background: var(--c-raised); border: 1px solid var(--c-line); }
  .sr-car:hover { border-color: var(--tablet-border-strong); background: var(--c-raised); }
  .sr-car.sel { border-color: var(--c-action); background: linear-gradient(90deg, var(--c-line), var(--c-raised)); }
  .sr-car.locked { opacity: 0.55; }
  .sr-thumb { width: 74px; height: 50px; display: grid; place-items: center; border-radius: 8px; color: var(--c-text-2, #c9ced4);
    background: var(--c-base); border: 1px solid var(--c-line); }
  .sr-thumb svg { width: 56px; height: 30px; }
  .sr-name { min-width: 0; display: flex; flex-direction: column; }
  .sr-name .n { font-size: 16px; font-weight: 600; line-height: 1.2; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sr-name .m { margin-top: 2px; font-size: 13px; color: var(--c-text-3, #8d949c); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sr-price { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 11px; border-radius: 7px; font-size: 15px; font-weight: 700; white-space: nowrap; font-variant-numeric: tabular-nums; }
  .sr-price.tok { padding-left: 9px; border-radius: 7px 15px 15px 7px; color: #f2c35b; background: rgba(242, 195, 91, 0.12); border: 1px solid rgba(242, 195, 91, 0.4); }
  .sr-price.tok.short { color: #ff5d50; background: rgba(255, 93, 80, 0.1); border-color: rgba(255, 93, 80, 0.4); }
  .sr-price.free { color: #46c98b; background: rgba(70, 201, 139, 0.12); border: 1px solid rgba(70, 201, 139, 0.4); }
  .sr-price.money { color: var(--c-action); background: var(--c-line); border: 1px solid var(--c-line); }

  .sr-detail { margin: 0 20px; padding: 14px 16px; border-radius: 12px; background: var(--c-raised); border: 1px solid var(--tablet-border-strong); }
  .sr-detail-row { display: flex; align-items: center; gap: 14px; }
  .sr-art { width: 132px; height: 62px; flex: none; display: grid; place-items: center; border-radius: 9px; color: var(--c-action); background: var(--c-base); border: 1px solid var(--c-line); }
  .sr-art svg { width: 108px; height: 44px; }
  .sr-detail h2 { margin: 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 24px; font-weight: 600; line-height: 1.1; }
  .sr-model { font-size: 13px; color: var(--c-text-3, #8d949c); }
  .sr-stats { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 20px; margin-top: 12px; }
  .sr-st { display: grid; grid-template-columns: 82px 1fr; align-items: center; gap: 8px; font-size: 13px; color: var(--c-text-3, #8d949c); }
  .sr-bar { height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.09); overflow: hidden; }
  .sr-bar i { display: block; height: 100%; border-radius: 3px; background: var(--c-action); }
  .sr-src { margin-top: 8px; font-size: 12px; color: var(--c-text-3, #8d949c); }

  .sr-foot { display: flex; align-items: center; gap: 12px; padding: 14px 20px 18px; }
  .sr-after { font-size: 13.5px; line-height: 1.4; color: var(--c-text-3, #8d949c); }
  .sr-after b { color: var(--c-text, #eceef0); }
  .sr-foot .sr-cta, .sr-pay { margin-left: auto; }
  .sr-pay { display: flex; gap: 8px; }
  .sr-cta { min-height: 46px; padding: 0 22px; font-size: 16px; }
  .sr-pay .sr-cta { margin-left: 0; padding: 0 16px; }

  .sr-return { margin: 18px 20px 0; padding: 22px; border-radius: 12px; display: flex; flex-direction: column; align-items: flex-start; gap: 10px;
    background: var(--c-raised); border: 1px solid var(--tablet-border-strong); }
  .sr-return-art { width: 132px; height: 62px; display: grid; place-items: center; border-radius: 9px; color: var(--c-action); background: var(--c-base); border: 1px solid var(--c-line); }
  .sr-return-art svg { width: 108px; height: 44px; }
  .sr-return h2 { margin: 4px 0 0; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 24px; font-weight: 600; }
  .sr-return p { margin: 0 0 6px; font-size: 14px; line-height: 1.5; color: var(--c-text-2, #c9ced4); }

  /* ped speech + toast + key hints */
  .sr-say { position: absolute; transform: translate(0, -50%); width: max-content; max-width: 300px; font-size: 15px; padding: 14px 18px; border-radius: 14px; font-size: 16px; line-height: 1.45;
    background: var(--c-raised); border: 1px solid var(--tablet-border-strong); }
  .sr-toast { position: absolute; left: 460px; top: 40px; padding: 12px 18px; border-radius: 12px; font-size: 15px; font-weight: 600;
    background: var(--c-raised); border: 1px solid rgba(70, 201, 139, 0.5); color: #46c98b; }
  .sr-toast.bad { border-color: rgba(255, 93, 80, 0.5); color: #ff8076; }
  .sr-keys { position: absolute; right: 26px; bottom: 22px; display: flex; gap: 18px; padding: 8px 14px; border-radius: 9px; font-size: 13px; color: var(--c-text-2, #c9ced4);
    background: var(--c-panel); border: 1px solid var(--c-line); }
  .sr-keys kbd { font: 600 12px var(--font-ui); padding: 2px 7px; margin-right: 6px; border-radius: 5px; color: var(--c-text-2, #c9ced4);
    border: 1px solid var(--tablet-border-strong); background: var(--c-raised); }

  /* ── flat, theme-driven ── */
  .sr-shade { right: auto; width: 600px; background: rgba(0, 0, 0, 0.6); }
  .sr-panel { border-radius: var(--r-panel); border-color: var(--tablet-border-strong); background: var(--c-panel); background-image: none; box-shadow: none; }
  .sr-head { background: var(--c-base); border-bottom-color: var(--c-line); }
  .sr-ico, .sr-ico.tok { border-radius: var(--r-ctl); color: var(--on-accent); background: var(--c-action); border-color: transparent; }
  .sr-x, .sr-chip { border-radius: var(--r-ctl); background: var(--c-raised); }
  .sr-x:hover { color: var(--text-main); border-color: var(--tablet-border-hover); }
  .sr-chip.on { color: var(--on-accent); background: var(--c-action); border-color: var(--c-action); }
  .sr-wallet, .sr-detail, .sr-return { border-radius: var(--r-ctl); background: var(--c-raised); border-color: var(--tablet-border-strong); }
  .sr-list { -webkit-mask-image: none; mask-image: none; }
  .sr-car { border-radius: var(--r-ctl); background: var(--c-raised); }
  .sr-car:hover { border-color: var(--tablet-border-hover); background: var(--c-hover); }
  .sr-car.sel { background: var(--c-action); border-color: var(--c-action); color: var(--on-accent); }
  .sr-car.sel .m { color: var(--on-accent); opacity: 0.75; }
  .sr-thumb, .sr-art, .sr-return-art { border-radius: var(--r-ctl); background: var(--c-base); }
  .sr-car.sel .sr-thumb { color: var(--text-main); }
  .sr-art, .sr-return-art { color: var(--text-main); }
  .sr-price { border-radius: 4px; border: 0; }
  .sr-price.tok { border-radius: 4px; color: #0a0a0a; background: #f2c35b; }
  .sr-price.tok.short { color: #fff; background: #ef4444; }
  .sr-price.free { color: #0a0a0a; background: #22c55e; }
  .sr-price.money { color: #fff; background: #3b82f6; }
  .sr-big.gold { color: #f2c35b; }
  .sr-bar, .sr-bar i { border-radius: 2px; }
  .sr-say, .sr-toast, .sr-keys { border-radius: var(--r-ctl); background: var(--c-panel); }
  .sr-keys kbd { border-radius: 4px; }

</style>
