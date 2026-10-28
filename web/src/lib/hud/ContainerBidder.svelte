<script>
  // The Container Wars bidding window, styled as a steel plate (cwTheme.css). The logic is fed by bidderStore; the window sits on
  // the left of the screen.
  // Updates only change fields — the window is never re-mounted while open.
  import { onDestroy } from 'svelte';
  import { bidder } from './bidderStore.js';
  import { fetchNui } from '../api/nui.js';
  import './cwTheme.css';

  const formatMoney = (value) => '$' + Number(value || 0).toLocaleString('en-US');

  let amount = '';
  let error = '';
  let processing = false;
  let guard = null;
  let seen = { open: 0, update: 0, reject: 0, accept: 0 };

  function parseAmount() {
    const value = Number(String(amount).replace(/[^\d]/g, ''));
    return Number.isFinite(value) ? value : 0;
  }
  function setAmount(value) { amount = String(Math.max(0, Math.floor(value))); }

  function endProcessing() {
    processing = false;
    clearTimeout(guard);
  }

  // One reactive entry point; every assignment happens inside the function.
  function sync(s) {
    if (s.openSeq !== seen.open) {
      seen.open = s.openSeq;
      endProcessing();
      error = '';
      setAmount(Math.max(Number(s.minimumBid || 0), Number(s.currentBid || 0) + Number(s.increment || 0)));
    }
    if (s.updateSeq !== seen.update) {
      seen.update = s.updateSeq;
      // keep what the player already typed unless the minimum has overtaken it
      if (parseAmount() < Number(s.minimumBid || 0)) setAmount(Number(s.minimumBid || 0));
    }
    if (s.rejectSeq !== seen.reject) {
      seen.reject = s.rejectSeq;
      endProcessing();
      error = s.message;
      if (parseAmount() < Number(s.minimumBid || 0)) setAmount(Number(s.minimumBid || 0));
    }
    if (s.acceptSeq !== seen.accept) {
      seen.accept = s.acceptSeq;
      endProcessing();
      error = '';
    }
  }
  $: sync($bidder);

  function validate(showError = true) {
    if (parseAmount() < $bidder.minimumBid) {
      if (showError) error = 'Bid must be at least ' + formatMoney($bidder.minimumBid);
      return false;
    }
    error = '';
    return true;
  }

  const minus = () => { setAmount(Math.max($bidder.minimumBid, parseAmount() - $bidder.increment)); validate(false); };
  const plus = () => { setAmount(Math.max($bidder.minimumBid, parseAmount() + $bidder.increment)); validate(false); };
  const add = (n) => { setAmount(Math.max(parseAmount(), $bidder.minimumBid) + n); validate(false); };
  const onInput = () => { amount = amount.replace(/[^\d]/g, ''); validate(false); };

  function cancel() {
    endProcessing();
    fetchNui($bidder.closeEvent || 'closeBidder');
  }

  async function confirm() {
    if (processing || $bidder.canBid === false) return;   // one request at a time
    if (!validate(true)) return;
    processing = true;
    // never stay on "Processing..." — the client script times the request out too
    clearTimeout(guard);
    guard = setTimeout(() => {
      if (processing) { processing = false; error = 'Bid request timed out'; }
    }, 8000);
    try {
      const res = await fetchNui($bidder.submitEvent || 'submitBid', { containerId: $bidder.containerId, amount: parseAmount() });
      if (res && res.ok === false) { endProcessing(); error = res.message || 'Bid rejected.'; }
    } catch (e) {
      endProcessing();
      error = 'Bid request failed';
    }
  }

  function onKey(e) {
    if (!$bidder.open) return;
    if (e.key === 'Escape') { e.preventDefault(); cancel(); }
    else if (e.key === 'Enter') { e.preventDefault(); confirm(); }
  }

  onDestroy(() => clearTimeout(guard));
</script>

<svelte:window on:keydown={onKey} />

{#if $bidder.open}
  <div class="wrap">
    <div class="bidder cw-plate" class:processing>
      <div class="cw-strip"></div>

      <div class="top">
        <div class="kick-row">
          <span class="cw-kicker">{$bidder.eyebrow || 'Container Wars auction'}</span>
          <span class="live" class:off={$bidder.canBid === false}><span class="dot"></span>{$bidder.canBid === false ? 'Closed' : 'Live'}</span>
        </div>
        <div class="title-row">
          <div class="title">Place bid</div>
          <div class="lot"><span class="cw-kicker">Lot</span><span class="lot-n">{String($bidder.containerNumber ?? 1).padStart(2, '0')}</span></div>
        </div>
        {#if $bidder.lotName}<div class="lot-name">{$bidder.lotName}</div>{/if}
      </div>

      <div class="figures">
        <div class="figure">
          <div class="cw-kicker">Current bid</div>
          <div class="current">{formatMoney($bidder.currentBid)}</div>
        </div>
        <div class="figure">
          <div class="cw-kicker">Minimum next</div>
          <div class="minimum">{formatMoney($bidder.minimumBid)}</div>
        </div>
      </div>

      <div class="stepper">
        <div class="stepper-head">
          <span class="cw-kicker">Your bid</span>
          <span class="increment">+ {formatMoney($bidder.increment)} per bid</span>
        </div>

        <div class="amount-box">
          <button class="control" type="button" on:click={minus} aria-label="Lower bid">−</button>
          <input
            class="amount"
            type="text"
            inputmode="numeric"
            bind:value={amount}
            on:input={onInput}
            aria-label="Bid amount"
          />
          <button class="control" type="button" on:click={plus} aria-label="Raise bid">+</button>
        </div>

        <div class="quick">
          <button type="button" on:click={() => add(5000)}>+$5K</button>
          <button type="button" on:click={() => add(10000)}>+$10K</button>
          <button type="button" on:click={() => add(25000)}>+$25K</button>
          <button type="button" on:click={() => add(50000)}>+$50K</button>
        </div>
      </div>

      <div class="your-gang">
        <span class="cw-kicker">Bidding as</span>
        <span class="gang">{String($bidder.gang || '—').toUpperCase()}</span>
      </div>

      <div class="error">{error}</div>

      <div class="actions">
        <button class="btn cancel" type="button" on:click={cancel}>Cancel <span class="cw-key">Esc</span></button>
        <button class="btn confirm" type="button" disabled={$bidder.canBid === false} on:click={confirm}>
          {processing ? 'Processing…' : 'Confirm bid'} <span class="cw-key">Enter</span>
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .wrap, .wrap * { font-family: var(--font-ui); }

  /* left side of the screen, vertically centred */
  .wrap {
    position: fixed;
    left: 36px;
    top: 50%;
    transform: translateY(-50%);
    z-index: 60;
    pointer-events: none;
  }

  .bidder {
    width: 380px;
    overflow: hidden;
    pointer-events: auto;
    box-shadow: 0 18px 44px rgba(0, 0, 0, 0.6);
  }

  .top { padding: 12px 18px 12px; border-bottom: 1px solid var(--cw-line-soft); }
  .kick-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
  .live {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--cw-green);
  }
  .live.off { color: var(--cw-dim); }
  .live .dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; }

  .title-row { display: flex; align-items: flex-end; justify-content: space-between; gap: 12px; margin-top: 6px; }
  .title {
    font-family: var(--cw-display);
    font-size: 30px;
    font-weight: 700;
    line-height: 1;
    letter-spacing: 0.03em;
    text-transform: uppercase;
  }
  .lot { display: flex; align-items: baseline; gap: 7px; padding: 3px 10px 4px; border: 1px solid var(--cw-line); border-radius: 2px; background: var(--cw-hull-2); }
  .lot-n {
    font-family: var(--cw-display);
    font-size: 24px;
    font-weight: 700;
    line-height: 1;
    letter-spacing: 0.04em;
    color: var(--cw-yellow);
    font-variant-numeric: tabular-nums;
  }
  /* the lot's own name, in full */
  .lot-name {
    margin-top: 8px;
    font-family: var(--cw-display);
    font-size: 15px;
    font-weight: 600;
    line-height: 1.2;
    letter-spacing: 0.03em;
    color: var(--cw-text);
    white-space: normal;
    overflow-wrap: anywhere;
  }

  .figures { display: grid; grid-template-columns: 1fr 1fr; border-bottom: 1px solid var(--cw-line-soft); }
  .figure { padding: 12px 18px 13px; min-width: 0; }
  .figure + .figure { border-left: 1px solid var(--cw-line-soft); }
  .current, .minimum {
    margin-top: 4px;
    font-family: var(--cw-display);
    font-size: 26px;
    font-weight: 700;
    line-height: 1.05;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .current { color: var(--cw-text); }
  .minimum { color: var(--cw-yellow); }

  .stepper { padding: 14px 18px 8px; }
  .stepper-head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 8px; }
  .increment { font-size: 12.5px; font-weight: 500; color: var(--cw-dim); }

  .amount-box {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 58px;
    padding: 6px;
    border: 1px solid var(--cw-line);
    border-radius: 2px;
    background: rgba(0, 0, 0, 0.28);
  }
  .control {
    width: 46px;
    height: 44px;
    border: 1px solid var(--cw-line);
    border-radius: 2px;
    background: var(--cw-hull-2);
    color: var(--cw-text);
    font-family: var(--cw-display);
    font-size: 24px;
    font-weight: 700;
    cursor: pointer;
  }
  .control:hover { border-color: var(--cw-yellow); color: var(--cw-yellow); }
  .amount {
    flex: 1;
    min-width: 0;
    border: 0;
    outline: 0;
    background: transparent;
    text-align: center;
    color: var(--cw-yellow);
    font-family: var(--cw-display);
    font-size: 30px;
    font-weight: 700;
    letter-spacing: 0.03em;
    font-variant-numeric: tabular-nums;
  }

  .quick { display: grid; grid-template-columns: repeat(4, 1fr); gap: 7px; margin-top: 9px; }
  .quick button {
    height: 33px;
    border: 1px solid var(--cw-line);
    border-radius: 2px;
    background: transparent;
    color: var(--cw-text);
    font-family: var(--cw-display);
    font-size: 14px;
    font-weight: 600;
    letter-spacing: 0.06em;
    cursor: pointer;
  }
  .quick button:hover { border-color: var(--cw-yellow); color: var(--cw-yellow); }

  .your-gang {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 10px;
    margin: 6px 18px 12px;
    padding: 9px 12px;
    border-left: 3px solid var(--cw-blue);
    background: var(--cw-hull-2);
  }
  .gang {
    font-family: var(--cw-display);
    font-size: 16px;
    font-weight: 700;
    letter-spacing: 0.08em;
    color: var(--cw-blue);
    overflow-wrap: anywhere;
    text-align: right;
  }

  .error { min-height: 18px; margin: 0 18px 8px; text-align: center; font-size: 13px; font-weight: 600; color: var(--cw-red); }

  .actions { display: grid; grid-template-columns: 1fr 1.5fr; gap: 9px; padding: 0 18px 18px; }
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 9px;
    height: 44px;
    border: 1px solid var(--cw-line);
    border-radius: 2px;
    background: transparent;
    color: var(--cw-text);
    font-family: var(--cw-display);
    font-size: 15px;
    font-weight: 700;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    cursor: pointer;
  }
  .btn .cw-key { height: 18px; min-width: 18px; font-size: 10px; letter-spacing: 0.04em; border-color: currentColor; background: transparent; color: inherit; opacity: 0.7; }
  .btn.cancel:hover { border-color: var(--cw-text); }
  .btn.confirm { border-color: var(--cw-green); background: var(--cw-green); color: #0b140a; }
  .btn.confirm:hover { background: #6fe063; border-color: #6fe063; }
  .btn.confirm:disabled { opacity: 0.45; cursor: not-allowed; }

  .processing { opacity: 0.8; pointer-events: none; }
</style>
