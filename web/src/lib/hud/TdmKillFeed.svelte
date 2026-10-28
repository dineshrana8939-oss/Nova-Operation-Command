<script>
  import { fly, fade } from 'svelte/transition';
  import { flip } from 'svelte/animate';
  import { cubicOut, backOut } from 'svelte/easing';
  import { tdmKillFeed } from './hudStore.js';

  const ACCENT = {
    headshot: '#ff5d50',
    double: '#ffc857',
    triple: '#ff9f2f',
    streak: '#4f94e6',
  };

  // The server sends the tag in capitals (HEAD, DOUBLE, 5X); show it in plain words.
  function tagText(tag) {
    const t = String(tag || '').trim();
    if (/^head/i.test(t)) return 'Headshot';
    if (/^\d+x$/i.test(t)) return `${t.slice(0, -1)}× streak`;
    return t ? t.charAt(0).toUpperCase() + t.slice(1).toLowerCase() : '';
  }
</script>

{#if $tdmKillFeed.length > 0}
  <div class="kill-feed">
    {#each $tdmKillFeed as entry (entry.id)}
      <div
        class="kill-row"
        class:special={!!entry.type}
        style="--accent:{ACCENT[entry.type] || '#ff5d50'}"
        in:fly={{ x: 100, duration: 340, easing: backOut }}
        out:fade={{ duration: 250 }}
        animate:flip={{ duration: 240, easing: cubicOut }}
      >
        {#if entry.tag}<span class="tag">{tagText(entry.tag)}</span>{/if}

        <div class="who killer">
          <span class="n killer-main">{entry.killer}</span>
          {#if entry.killerTeam}<span class="sub">{entry.killerTeam}</span>{/if}
        </div>

        <div class="weapon">
          <span class="skull-wrap">
            <svg class="skull" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 2a8 8 0 0 0-8 8c0 2.6 1.2 4.6 3 5.9V19a1 1 0 0 0 1 1h1v-2h2v2h2v-2h2v2h1a1 1 0 0 0 1-1v-3.1c1.8-1.3 3-3.3 3-5.9a8 8 0 0 0-8-8zM9 13a2 2 0 1 1 0-4 2 2 0 0 1 0 4zm6 0a2 2 0 1 1 0-4 2 2 0 0 1 0 4z" fill="currentColor" />
            </svg>
          </span>
          {#if entry.weapon}<span class="weapon-name">{entry.weapon}</span>{/if}
        </div>

        <div class="who victim">
          <span class="n victim-main">{entry.victim}</span>
          {#if entry.victimTeam}<span class="sub">{entry.victimTeam}</span>{/if}
        </div>
      </div>
    {/each}
  </div>
{/if}

<style>
  /* No backdrop-filter anywhere on these cards: on an element that slides / fades in it paints a black rectangle round it
     in the game's browser. */
  .kill-feed {
    position: fixed;
    top: 24px;
    right: 28px;
    width: 470px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    z-index: 9988;
    pointer-events: none;
    font-family: var(--font-ui);
  }
  .kill-row {
    position: relative;
    min-height: 52px;
    padding: 9px 16px 9px 20px;
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr);
    align-items: center;
    gap: 14px;
    overflow: hidden;
    background:
      linear-gradient(90deg, color-mix(in srgb, var(--accent) 20%, transparent), transparent 42%),
      rgba(12, 16, 23, 0.95);
    border: 1px solid rgba(130, 165, 210, 0.3);
    border-radius: 14px;
    box-shadow: inset 3px 0 0 var(--accent), 0 6px 18px rgba(0, 0, 0, 0.5);
  }
  .kill-row.special { border-color: color-mix(in srgb, var(--accent) 55%, transparent); }

  /* one soft light sweep as the row arrives */
  .kill-row::after {
    content: '';
    position: absolute;
    top: 0;
    left: -40%;
    width: 28%;
    height: 100%;
    background: linear-gradient(100deg, transparent, rgba(255, 255, 255, 0.1), transparent);
    transform: skewX(-18deg);
    animation: sweep 0.75s ease-out 0.1s both;
  }
  @keyframes sweep { from { left: -40%; } to { left: 130%; } }
  @keyframes skullPop {
    0% { transform: scale(0.5); opacity: 0; }
    60% { transform: scale(1.15); opacity: 1; }
    100% { transform: scale(1); }
  }
  @keyframes nameIn {
    from { opacity: 0; transform: translateY(4px); }
    to { opacity: 1; transform: translateY(0); }
  }

  /* Headshot / Double / Triple / streak: a small pill sitting on the top edge */
  .tag {
    position: absolute;
    left: 14px;
    top: 0;
    height: 16px;
    padding: 0 8px;
    display: inline-flex;
    align-items: center;
    font-size: 11.5px;
    font-weight: 700;
    color: #101318;
    background: var(--accent);
    border-radius: 0 0 8px 8px;
    z-index: 2;
  }

  .who { min-width: 0; display: flex; flex-direction: column; animation: nameIn 0.3s ease-out 0.08s both; }
  .killer { align-items: flex-end; text-align: right; }
  .victim { align-items: flex-start; text-align: left; }
  .n {
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 16px;
    line-height: 1.2;
    font-weight: 600;
  }
  .killer-main { color: #fff; }
  .victim-main { color: #ff9d94; }
  .sub { margin-top: 1px; font-size: 12.5px; color: #8d949c; }

  /* the weapon: the skull in a tinted disc, the weapon's name under it */
  .weapon {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 3px;
    min-width: 96px;
    padding: 0 12px;
    border-left: 1px solid rgba(110, 140, 180, 0.2);
    border-right: 1px solid rgba(110, 140, 180, 0.2);
  }
  .skull-wrap {
    width: 26px;
    height: 26px;
    display: grid;
    place-items: center;
    border-radius: 50%;
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 16%, transparent);
    border: 1px solid color-mix(in srgb, var(--accent) 42%, transparent);
  }
  .skull { width: 15px; height: 15px; animation: skullPop 0.4s cubic-bezier(0.2, 1.4, 0.4, 1) 0.08s both; }
  .weapon-name {
    max-width: 130px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 12.5px;
    font-weight: 600;
    color: #c9ced4;
  }

  @media (prefers-reduced-motion: reduce) {
    .kill-row::after, .skull, .who { animation: none; }
  }
</style>
