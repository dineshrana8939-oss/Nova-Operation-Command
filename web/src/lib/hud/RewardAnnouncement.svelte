<script>
  import { rewardCard } from './hudStore.js';
  import { themeFor, themeVars } from './eventThemes.js';
  import { hudIcon } from './hudIcons.js';
  import './hud-shared.css';

  // THE reward card — one component for every event. The server
  // (RewardService.Announce) sends { event, title, name, stats, rewards, note }
  // to the single player who was paid; the event key only picks the colour and
  // icon (same event colours as every other HUD card). Cards that arrive close
  // together are queued by hudStore.js and shown one after another.
  $: card = $rewardCard.card;
  $: eventKey = card?.event || 'success';
  $: theme = themeFor(eventKey);
</script>

{#if $rewardCard.visible && card}
  {#key $rewardCard.key}
    <div class="ra-wrap" style={themeVars(eventKey)}>
      <div class="hx-card ra-card">
        <div class="hx-rail"><span></span></div>

        <div class="ra-head">
          <div class="hx-iconbox">{@html hudIcon(theme.icon)}</div>
          <div class="ra-titles">
            <div class="ra-eyebrow">{card.name || theme.label}</div>
            <div class="ra-title">{card.title || 'EVENT COMPLETED'}</div>
          </div>
        </div>

        {#if (card.stats || []).length}
          <div class="ra-stats">
            {#each card.stats as s}
              <div class="ra-stat {s.tone || ''}">
                <span class="k">{s.label}</span>
                <span class="v">{s.value}</span>
              </div>
            {/each}
          </div>
        {/if}

        <div class="ra-rewards">
          <div class="ra-section">{(card.rewards || []).length > 1 ? 'REWARDS' : 'REWARD'}</div>
          {#each card.rewards || [] as r}
            <div class="ra-row {r.kind || ''}">
              <span class="k">{r.label}</span>
              <span class="v">{r.value}</span>
            </div>
          {/each}
        </div>

        {#if card.note}<div class="ra-note">{card.note}</div>{/if}

        <div class="ra-timeline"><i style="animation-duration:{$rewardCard.durationMs}ms"></i></div>
      </div>
    </div>
  {/key}
{/if}

<style>
  /* Neat boxed reward card: a compact header, the stats as equal boxes, and every reward as its own boxed row with the
     amount in gold. Right-hand side, vertically centred: clear of the top announcement banner, the corner timers and
     the bottom-right toast. */
  .ra-wrap {
    position: fixed;
    right: 28px;
    top: 50%;
    transform: translateY(-50%);
    width: 320px;
    pointer-events: none;
    z-index: 9998;
  }
  .ra-card {
    padding: 12px 14px 13px;
    animation: raIn 0.55s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .ra-card :global(.hx-iconbox) { width: 32px; height: 32px; }
  .ra-card :global(.hx-iconbox svg) { width: 17px; height: 17px; }
  .ra-head {
    display: flex;
    align-items: center;
    gap: 10px;
    padding-bottom: 10px;
    margin-bottom: 10px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  }
  .ra-titles {
    min-width: 0;
  }
  .ra-eyebrow {
    color: var(--accent2);
    font-size: 10.5px;
    font-weight: 800;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ra-title {
    margin-top: 1px;
    color: #fff;
    font-size: 16px;
    font-weight: 900;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    line-height: 1.15;
  }

  .ra-stats {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
    margin-bottom: 10px;
  }
  .ra-stat {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
    padding: 6px 9px;
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.035);
    border-radius: 8px;
  }
  .ra-stat .k {
    color: #9c9ea0;
    font-size: 9.5px;
    font-weight: 800;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ra-stat .v {
    color: #f4f4f1;
    font-size: 14px;
    font-weight: 900;
    font-variant-numeric: tabular-nums;
  }
  .ra-stat.ok .v { color: #31d47a; }
  .ra-stat.warn .v { color: #e5b84b; }
  .ra-stat.danger .v { color: #e85d5d; }

  .ra-section {
    margin-bottom: 6px;
    color: #9c9ea0;
    font-size: 9.5px;
    font-weight: 800;
    letter-spacing: 0.12em;
  }
  .ra-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 7px 10px;
    border: 1px solid rgba(242, 193, 78, 0.28);
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.04);
  }
  .ra-row + .ra-row { margin-top: 5px; }
  .ra-row .k {
    min-width: 0;
    color: #d8d9d6;
    font-size: 12.5px;
    font-weight: 700;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ra-row .v {
    flex: none;
    color: #f2c14e;
    font-size: 16px;
    font-weight: 900;
    font-variant-numeric: tabular-nums;
  }
  .ra-row.xp .v { color: #f2c14e; }
  .ra-row.money .v { color: #f2c14e; font-size: 20px; }

  .ra-note {
    margin-top: 8px;
    color: #9c9ea0;
    font-size: 11.5px;
    line-height: 1.4;
  }
  .ra-timeline {
    height: 2px;
    margin: 11px -14px -13px;
    background: rgba(255, 255, 255, 0.06);
  }
  .ra-timeline i {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left;
    animation: raTimeline linear both;
  }

  @keyframes raIn {
    from { opacity: 0; transform: translateX(26px); }
    to { opacity: 1; transform: translateX(0); }
  }
  @keyframes raTimeline {
    from { transform: scaleX(1); }
    to { transform: scaleX(0); }
  }
</style>
