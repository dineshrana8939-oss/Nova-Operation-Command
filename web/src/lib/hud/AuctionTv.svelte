<script>
  // The Gang Territory auction board. It is NOT drawn on the player's screen: the game renders this page into a texture (a DUI,
  // see client/modules/territory.lua) and hangs it in the world over the auction projector. Read from across a street, so
  // everything is large: the zone's name, one huge current bid, the countdown, a map with the zone pinned, and a strip with every
  // zone of the event. The zone's own colour is the single accent (rail, countdown bar, pin), nothing else is decorated.
  import { territoryHud } from '../territory/territoryStore.js';
  import AuctionMap from './AuctionMap.svelte';

  const money = (n) => '$' + Number(n || 0).toLocaleString('en-US');
  const clock = (s) => `${String(Math.floor(Math.max(0, s) / 60)).padStart(2, '0')}:${String(Math.max(0, s) % 60).padStart(2, '0')}`;

  $: a = $territoryHud.auction;
  $: lot = a?.state?.lot || null;
  $: tick = a?.tick && lot && a.tick.territoryId === lot.territoryId ? a.tick : null;
  // the board also shows between territories (lot is null then), so gangs always see what is on offer
  $: state = a?.state || null;
  $: lots = state?.lots || [];
  const lotStatus = (l, activeId) => (l.territoryId === activeId ? 'live' : l.status === 'WON' ? 'sold' : l.status === 'UNSOLD' ? 'unsold' : 'next');
  const STATUS_TEXT = { live: 'Bidding now', sold: 'Sold', unsold: 'No bids', next: 'Up next' };
  $: soldCount = lots.filter((l) => l.status === 'WON').length;
  $: current = tick ? tick.currentBid : lot?.currentBid;
  $: leadGang = tick ? (tick.leadingGangLabel || null) : lot?.leadingGangLabel;
  $: leadPlayer = tick ? tick.leadingPlayer : lot?.leadingPlayer;
  $: timeLeft = tick ? tick.timeRemaining : lot?.timeRemaining || 0;
  // the same rule as the server's AuctionCore.minimumNext: current bid + the lot's increment
  $: minNext = (current ?? lot?.startingBid ?? 0) + (lot?.increment || 0);
  $: urgent = timeLeft > 0 && timeLeft <= 10;
  $: accent = lot?.color || '#c45ee0';
  // the countdown bar is measured against the longest time seen for this lot (anti-snipe extensions grow it)
  let peak = 0, peakFor = null;
  $: if (lot && lot.territoryId !== peakFor) { peakFor = lot.territoryId; peak = timeLeft; }
  $: if (timeLeft > peak) peak = timeLeft;
  $: pct = peak > 0 ? Math.max(0, Math.min(100, (timeLeft / peak) * 100)) : 0;
  $: shownLots = lots.slice(0, 6);
  $: moreLots = Math.max(0, lots.length - shownLots.length);
</script>

{#if state}
  <div class="tv" class:urgent style="--accent:{accent}">
    <header class="top">
      <span class="on-air"><i></i>Live</span>
      <span class="what">Gang Territory Auction</span>
      <span class="event">{state.name}</span>
      <span class="meta"><b>{soldCount}</b> of {lots.length} sold <em>Event ends in {clock(state.endsIn || 0)}</em></span>
    </header>

    <main class="main">
      {#if lot}
        <section class="left">
          <div class="lot-head">
            <span class="swatch"></span>
            <h1>{lot.name}</h1>
            <span class="count">Territory {lot.lotIndex} of {state.totalLots}</span>
          </div>
          <div class="map"><AuctionMap {lots} liveId={lot.territoryId} preview={lot.preview} location={state.location} /></div>
        </section>

        <section class="right">
          <div class="bid">
            <span class="lbl">Current bid</span>
            <b class="amount">{money(current)}</b>
          </div>

          <div class="facts">
            <div><span>Starting price</span><b>{money(lot.startingBid)}</b></div>
            <div><span>Next bid from</span><b>{money(minNext)}</b></div>
            <div><span>Worth</span><b class="xp">{Number(lot.xpValue || 0).toLocaleString()} XP</b></div>
            <div><span>Bids</span><b>{tick ? tick.bidCount ?? lot.bidCount : lot.bidCount}</b></div>
          </div>

          <div class="leader">
            <div class="who">
              <span class="lbl">Highest bidder</span>
              <b>{leadPlayer || 'No bids yet'}</b>
              {#if leadGang}<em>{leadGang}</em>{/if}
            </div>
            <div class="time" class:urgent>{clock(timeLeft)}</div>
          </div>
          <div class="bar" aria-hidden="true"><i style="width:{pct}%"></i></div>
        </section>
      {:else}
        <section class="wait">
          <h1>{state.phase === 'INTRO' ? 'Bidding opens shortly' : 'The next territory is coming up'}</h1>
          <p>Every territory in this auction is pinned on the map.</p>
          <div class="map wide"><AuctionMap {lots} liveId={null} preview={null} location={state.location} /></div>
        </section>
      {/if}
    </main>

    <section class="strip" aria-label="Territories in this auction">
      {#each shownLots as l (l.territoryId)}
        {@const st = lotStatus(l, lot?.territoryId)}
        <article class="lt-card {st}" style="--c:{l.color || '#c45ee0'}">
          <span class="bar-c"></span>
          <div class="name">{l.name}</div>
          <div class="sub">
            {#if st === 'sold'}{l.leadingGangLabel || 'Sold'} paid {money(l.finalBid)}
            {:else if st === 'unsold'}Nobody bid
            {:else if st === 'live'}{money(current)} now
            {:else}From {money(l.startingBid)}{/if}
          </div>
          <span class="tag">{STATUS_TEXT[st]}</span>
        </article>
      {/each}
      {#if moreLots}<div class="more">+{moreLots} more</div>{/if}
      {#if !lots.length}<div class="none">No territories are being auctioned.</div>{/if}
    </section>

    <footer class="foot">
      {#if $territoryHud.canBid && lot && lot.status === 'AUCTION_ACTIVE'}
        <span class="press"><kbd>E</kbd> Place a bid</span>
      {:else}
        <span class="hint">{state.inviteOnly ? 'Invited gangs only. ' : ''}Eligible gang members bid from the auction zone in front of this screen.</span>
      {/if}
    </footer>
  </div>
{/if}

<style>
  /* Fills the whole texture. Sizes are in em off one root size, so the board scales with the texture. */
  .tv {
    --bg: #0c0d12; --panel: #14161d; --line: #262935; --text: #f4f5f8; --dim: #a0a6b8; --faint: #6f768a;
    width: 100vw; height: 100vh; box-sizing: border-box; display: flex; flex-direction: column;
    background: var(--bg); color: var(--text); font-family: var(--font-ui, 'Instrument Sans', system-ui, sans-serif);
    font-size: calc(100vw / 68); overflow: hidden; border-top: 0.28em solid var(--accent);
  }
  .tv.urgent { --accent: #ff5d50; }

  .top { display: flex; align-items: center; gap: 1.1em; padding: 0.7em 1.4em; border-bottom: 1px solid var(--line); flex: none; }
  .on-air { display: inline-flex; align-items: center; gap: 0.45em; font-weight: 700; color: #ff6a5e; font-size: 0.9em; }
  .on-air i { width: 0.6em; height: 0.6em; border-radius: 50%; background: #ff5d50; }
  .what { font-weight: 700; font-size: 1em; }
  .event { color: var(--dim); font-size: 0.95em; flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .meta { color: var(--dim); font-size: 0.95em; white-space: nowrap; }
  .meta b { color: var(--text); font-size: 1.1em; }
  .meta em { font-style: normal; margin-left: 1em; color: var(--faint); }

  .main { flex: 1; min-height: 0; display: grid; grid-template-columns: 1.15fr 1fr; grid-template-rows: minmax(0, 1fr); gap: 1.6em; padding: 0.9em 1.4em 0.5em; overflow: hidden; }
  .left { display: flex; flex-direction: column; min-width: 0; min-height: 0; gap: 0.7em; }
  .lot-head { display: flex; align-items: baseline; gap: 0.7em; min-width: 0; }
  .swatch { width: 0.5em; height: 1.6em; border-radius: 0.15em; background: var(--accent); align-self: center; flex: none; }
  .lot-head h1 { margin: 0; font-size: 2.2em; line-height: 1.05; font-weight: 700; letter-spacing: -0.01em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .count { color: var(--faint); font-size: 0.95em; white-space: nowrap; }
  .map { flex: 1; min-height: 0; display: flex; align-items: flex-start; overflow: hidden; }
  .map > :global(.amap) { width: 100%; max-height: 100%; }
  .map.wide { max-width: 70%; margin: 0.6em auto 0; }

  .right { display: flex; flex-direction: column; justify-content: center; gap: 0.7em; min-width: 0; min-height: 0; overflow: hidden; }
  .lbl { color: var(--faint); font-size: 0.85em; font-weight: 600; }
  .bid { display: flex; flex-direction: column; }
  .amount { font-size: 4.6em; line-height: 1; font-weight: 700; color: #4ade9b; font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
  .facts { display: grid; grid-template-columns: 1fr 1fr; gap: 0.4em 1.4em; padding: 0.6em 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
  .facts div { display: flex; flex-direction: column; }
  .facts span { color: var(--faint); font-size: 0.8em; }
  .facts b { font-size: 1.2em; font-weight: 600; font-variant-numeric: tabular-nums; }
  .facts b.xp { color: #ffc857; }
  .leader { display: flex; align-items: center; justify-content: space-between; gap: 1em; }
  .who { display: flex; flex-direction: column; min-width: 0; }
  .who b { font-size: 1.5em; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .who em { font-style: normal; color: var(--accent); font-weight: 600; font-size: 1em; }
  .time { font-size: 2.8em; font-weight: 700; line-height: 1; font-variant-numeric: tabular-nums; }
  .time.urgent { color: #ff5d50; }
  .bar { height: 0.45em; border-radius: 0.25em; background: var(--panel); overflow: hidden; }
  .bar i { display: block; height: 100%; background: var(--accent); border-radius: 0.25em; }

  .wait { grid-column: 1 / -1; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; min-height: 0; }
  .wait h1 { margin: 0; font-size: 2.8em; font-weight: 700; }
  .wait p { margin: 0.3em 0 0; color: var(--dim); font-size: 1.1em; }

  .strip { flex: none; display: flex; gap: 0.7em; padding: 0.5em 1.4em; }
  .lt-card { position: relative; flex: 1 1 0; min-width: 0; padding: 0.5em 0.8em 0.5em 1.1em; background: var(--panel); border: 1px solid var(--line); border-radius: 0.5em; overflow: hidden; }
  .lt-card .bar-c { position: absolute; left: 0; top: 0; bottom: 0; width: 0.28em; background: var(--c); }
  .lt-card .name { font-weight: 700; font-size: 1.05em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .lt-card .sub { color: var(--dim); font-size: 0.8em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin: 0.1em 0 0.35em; }
  .lt-card .tag { font-size: 0.72em; font-weight: 700; color: var(--faint); }
  .lt-card.live { border-color: var(--c); }
  .lt-card.live .tag { color: #ff6a5e; }
  .lt-card.sold .tag { color: #4ade9b; }
  .lt-card.next .tag { color: #ffc857; }
  .lt-card.sold, .lt-card.unsold { opacity: 0.7; }
  .more, .none { align-self: center; color: var(--faint); font-size: 0.9em; padding: 0 0.6em; white-space: nowrap; }

  .foot { flex: none; text-align: center; padding: 0.2em 1.4em 0.6em; }
  .press { display: inline-block; font-weight: 700; font-size: 1.1em; color: #0d130f; background: #4ade9b; border-radius: 0.4em; padding: 0.35em 1.4em; }
  .press kbd { background: rgba(0, 0, 0, 0.2); border-radius: 0.25em; padding: 0.05em 0.55em; margin-right: 0.55em; font-family: inherit; }
  .hint { color: var(--faint); font-size: 0.9em; }
</style>
