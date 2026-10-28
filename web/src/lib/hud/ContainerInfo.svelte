<script>
  // The Container Wars in-world panel: one tag above each visible container (data from containerInfoStore), placed at
  // the screen position the client script projects above it. Styled as a steel plate on the container (cwTheme.css).
  //   mode 'active'  the container whose auction is running (only ever one): bid, next bid, time, leader, [E] hint
  //   mode 'won'     SOLD: who won it (gang + player) and for how much (OPENED once its doors have been opened)
  //   mode 'unsold'  AUCTION CLOSED: no winner
  // A finished container also shows the time until the crane brings the next one (nextDropIn, seconds).
  // The container's name is shown IN FULL, exactly as it was typed in the tablet: it wraps onto a second line when it is long,
  // it is never cut off with an ellipsis.
  import { containerInfos } from './containerInfoStore.js';
  import './cwTheme.css';

  const money = (value) => '$' + Number(value || 0).toLocaleString('en-US');
  const lotNo = (n) => String(n ?? 1).padStart(2, '0');
  const fullName = (name) => String(name || '').trim() || 'Cargo container';

  function formatTime(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0));
    const minutes = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return String(minutes).padStart(2, '0') + ':' + String(secs).padStart(2, '0');
  }
</script>

{#each $containerInfos as m (m.id)}
  {@const won = m.mode === 'won'}
  {@const unsold = m.mode === 'unsold'}
  <!-- Anchored by its bottom-centre (the little notch) so the tag sits ABOVE the container. -->
  <div
    class="container-ui"
    style="left:{m.x * 100}%; top:{m.y * 100}%; transform:translate(-50%,-100%) scale({m.scale ?? 1});"
  >
    <div class="panel cw-plate" class:sold={won} class:closed={unsold}>
      <div class="cw-strip"></div>

      <div class="head">
        <div class="lot"><span class="cw-kicker">Lot</span><span class="lot-n">{lotNo(m.containerNumber)}</span></div>
        <div class="state" class:live={!won && !unsold} class:sold={won} class:none={unsold}>
          {#if won}{m.opened ? 'Opened' : 'Sold'}{:else if unsold}No winner{:else}<span class="dot"></span>Live{/if}
        </div>
      </div>

      <div class="name">{fullName(m.containerName)}</div>

      {#if !won && !unsold}
        <div class="grid">
          <div class="cell">
            <div class="cw-kicker">Highest</div>
            <div class="value highest">{money(m.highestBid)}</div>
          </div>
          <div class="cell">
            <div class="cw-kicker">Next bid</div>
            <div class="value minimum">{money(m.minNextBid)}</div>
          </div>
          <div class="cell">
            <div class="cw-kicker">Time</div>
            <div class="value time">{formatTime(m.timeLeft)}</div>
          </div>
        </div>
        <div class="foot">
          <div class="who">
            {#if m.highestGang}
              <span class="gang">{m.highestGang}</span>{#if m.highestPlayer}<span class="player">{m.highestPlayer}</span>{/if}
            {:else}
              <span class="gang dim">No bids yet</span>
            {/if}
          </div>
          <div class="hint" class:hidden={m.canBid === false}>
            <span class="cw-key">E</span>
            <span>{m.bidState === 'processing' ? 'Processing' : m.bidState === 'rejected' ? 'Rejected' : 'Bid'}</span>
          </div>
        </div>
      {:else if won}
        <div class="result">
          <div class="who">
            <span class="gang win">{m.winningGang || 'Winner'}</span>{#if m.winningPlayer}<span class="player">{m.winningPlayer}</span>{/if}
          </div>
          <div class="final">{money(m.finalBid)}</div>
        </div>
      {:else}
        <div class="result"><div class="who"><span class="gang dim">Auction closed, nobody bid</span></div></div>
      {/if}

      {#if (won || unsold) && m.nextDropIn != null}
        <div class="next">Next container in <b>{formatTime(m.nextDropIn)}</b></div>
      {/if}
    </div>

    <div class="notch"></div>
  </div>
{/each}

<style>
  .container-ui {
    position: absolute;
    transform-origin: 50% 100%;
    width: 304px;
    font-family: var(--font-ui);
    filter: drop-shadow(0 4px 8px rgba(0, 0, 0, 0.55));
    pointer-events: none;
  }

  .panel { overflow: hidden; }
  .panel.sold { border-color: rgba(82, 210, 74, 0.65); }
  .panel.closed { border-color: var(--cw-line-soft); }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 8px 14px 0;
  }
  .lot { display: flex; align-items: baseline; gap: 7px; }
  .lot-n {
    font-family: var(--cw-display);
    font-size: 24px;
    font-weight: 700;
    line-height: 1;
    letter-spacing: 0.04em;
    color: var(--cw-yellow);
    font-variant-numeric: tabular-nums;
  }

  .state {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-family: var(--cw-display);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--cw-dim);
  }
  .state.live, .state.sold { color: var(--cw-green); }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--cw-green); }

  /* the container's own name, in full: it wraps, it is never truncated */
  .name {
    padding: 4px 14px 9px;
    font-family: var(--cw-display);
    font-size: 17px;
    font-weight: 600;
    line-height: 1.18;
    letter-spacing: 0.02em;
    white-space: normal;
    overflow-wrap: anywhere;
    word-break: normal;
    color: var(--cw-text);
  }

  .grid {
    display: grid;
    grid-template-columns: 1.2fr 1.1fr 0.9fr;
    border-top: 1px solid var(--cw-line-soft);
  }
  .cell { padding: 7px 10px 8px 14px; min-width: 0; }
  .cell + .cell { border-left: 1px solid var(--cw-line-soft); padding-left: 10px; }
  .value {
    margin-top: 2px;
    font-family: var(--cw-display);
    font-size: 18px;
    font-weight: 700;
    line-height: 1.1;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .highest { color: var(--cw-text); }
  .minimum { color: var(--cw-yellow); }
  .time { color: var(--cw-orange); }

  .foot, .result {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 8px 14px 10px;
    border-top: 1px solid var(--cw-line-soft);
  }
  .who { min-width: 0; font-size: 13px; font-weight: 600; line-height: 1.25; }
  .gang {
    font-family: var(--cw-display);
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--cw-blue);
    overflow-wrap: anywhere;
  }
  .gang.win { color: var(--cw-green); }
  .gang.dim { color: var(--cw-dim); text-transform: none; letter-spacing: 0; font-weight: 600; font-family: var(--font-ui); }
  .player { display: block; color: var(--cw-text); font-size: 12.5px; font-weight: 500; overflow-wrap: anywhere; }
  .final {
    flex: 0 0 auto;
    font-family: var(--cw-display);
    font-size: 20px;
    font-weight: 700;
    color: var(--cw-yellow);
    font-variant-numeric: tabular-nums;
  }

  .hint {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-family: var(--cw-display);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--cw-text);
  }

  .next {
    padding: 7px 14px 9px;
    border-top: 1px solid var(--cw-line-soft);
    text-align: center;
    font-size: 12.5px;
    font-weight: 500;
    color: var(--cw-dim);
  }
  .next b { color: var(--cw-yellow); font-family: var(--cw-display); font-variant-numeric: tabular-nums; }

  .notch {
    width: 10px;
    height: 10px;
    margin: -6px auto 0;
    transform: rotate(45deg);
    background: var(--cw-hull);
    border-right: 1px solid var(--cw-line);
    border-bottom: 1px solid var(--cw-line);
  }
  .hidden { display: none !important; }
</style>
