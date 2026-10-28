<script>
  import { flip } from 'svelte/animate';
  import { notifications } from './hudStore.js';
  import { themeFor, themeVars } from './eventThemes.js';
  import { hudIcon } from './hudIcons.js';
  import './hud-shared.css';

  // Player notifications. One card per message, in the same look as the other HUD cards (graphite plate, event
  // colour on the left edge + icon plate + timeout line). The event colour comes from the text of the message
  // (convoy orange, airdrop violet, ...); errors and warnings keep red and amber. Layout of a card:
  //   [icon]  • CATEGORY | TAG                  01
  //           Title
  //           Message with **bold** parts
  // Only opacity / transform are animated, so showing and hiding cards never relayouts the page.

  $: position = $notifications.position || 'top-right';
  $: items = $notifications.items;

  const pad = (n) => String(n).padStart(2, '0');

  // "**bold**" in a message -> bold segment (rendered as text nodes, never as HTML)
  function segments(text) {
    const out = [];
    String(text || '').split(/(\*\*[^*]+\*\*)/g).forEach((part) => {
      if (!part) return;
      if (part.startsWith('**') && part.endsWith('**')) out.push({ b: true, t: part.slice(2, -2) });
      else out.push({ b: false, t: part });
    });
    return out;
  }
</script>

{#if items.length}
  <div class="nt-stack {position}" role="status" aria-live="polite">
    {#each items as n, i (n.id)}
      {@const theme = themeFor(n.eventKey)}
      <section class="nt-card" style="{themeVars(n.eventKey)}" animate:flip={{ duration: 180 }}>
        <div class="nt-icon" aria-hidden="true">{@html hudIcon(theme.icon)}</div>
        <div class="nt-body">
          <div class="nt-eyebrow">
            <span class="nt-dot"></span>
            <span class="nt-category">{n.category || theme.label}</span>
            {#if n.tag}<span class="nt-sep"></span><span class="nt-tag">{n.tag}</span>{/if}
          </div>
          <h2 class="nt-title">{n.title}</h2>
          {#if n.message}
            <p class="nt-message">{#each segments(n.message) as s}{#if s.b}<strong>{s.t}</strong>{:else}{s.t}{/if}{/each}</p>
          {/if}
        </div>
        <div class="nt-count">{pad(i + 1)}</div>
        <div class="nt-timeout"><span style="animation-duration:{n.duration}ms"></span></div>
      </section>
    {/each}
  </div>
{/if}

<style>
  .nt-stack {
    position: fixed;
    z-index: 9999;
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: min(470px, calc(100vw - 48px));
    pointer-events: none;
  }
  .nt-stack.top-right { top: 24px; right: 24px; }
  .nt-stack.top-left { top: 24px; left: 24px; }
  .nt-stack.bottom-right { bottom: 24px; right: 24px; flex-direction: column-reverse; }
  .nt-stack.bottom-left { bottom: 24px; left: 24px; flex-direction: column-reverse; }

  .nt-card {
    position: relative;
    display: grid;
    grid-template-columns: 44px 1fr auto;
    align-items: center;
    gap: 14px;
    padding: 15px 17px 17px 15px;
    overflow: hidden;
    color: #f2f5f7;
    background: rgba(17, 19, 22, 0.97);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-left: 3px solid var(--accent);
    border-radius: var(--r-panel, 12px);
    box-shadow: 0 10px 26px rgba(0, 0, 0, 0.4);
    font-family: var(--font-ui);
    animation: ntIn 0.3s cubic-bezier(0.2, 0.8, 0.2, 1) both;
  }
  .top-left .nt-card, .bottom-left .nt-card { animation-name: ntInLeft; }

  .nt-icon {
    display: grid;
    place-items: center;
    width: 44px;
    height: 44px;
    border-radius: var(--r-ctl, 8px);
    background: rgba(var(--accentRGB), 0.14);
    border: 1px solid rgba(var(--accentRGB), 0.55);
  }
  .nt-icon :global(svg) {
    width: 23px;
    height: 23px;
    stroke: var(--accent2);
    fill: none;
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .nt-body { min-width: 0; }
  .nt-eyebrow {
    display: flex;
    align-items: center;
    gap: 7px;
    margin-bottom: 6px;
  }
  .nt-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); flex: none; }
  .nt-category {
    color: var(--accent2);
    font-size: 11px;
    line-height: 1;
    font-weight: 800;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .nt-sep { width: 1px; height: 11px; background: rgba(255, 255, 255, 0.17); flex: none; }
  .nt-tag {
    color: #98a3ae;
    font-size: 10.5px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .nt-title {
    margin: 0;
    color: #fff;
    font-size: 17px;
    line-height: 1.2;
    font-weight: 800;
    letter-spacing: -0.01em;
    overflow-wrap: anywhere;
  }
  .nt-message {
    margin: 5px 0 0;
    color: #bcc4cd;
    font-size: 13.5px;
    line-height: 1.45;
    font-weight: 500;
    white-space: pre-line;
    overflow-wrap: anywhere;
  }
  .nt-message strong { color: #f5f7f9; font-weight: 700; }
  .nt-count {
    align-self: start;
    margin-top: 2px;
    color: #8b96a2;
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 0.05em;
    font-variant-numeric: tabular-nums;
  }

  .nt-timeout {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 2px;
    background: rgba(255, 255, 255, 0.06);
  }
  .nt-timeout span {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left;
    animation: ntTimeout linear forwards;
  }

  @keyframes ntIn {
    from { opacity: 0; transform: translateX(16px); }
    to { opacity: 1; transform: translateX(0); }
  }
  @keyframes ntInLeft {
    from { opacity: 0; transform: translateX(-16px); }
    to { opacity: 1; transform: translateX(0); }
  }
  @keyframes ntTimeout {
    from { transform: scaleX(1); }
    to { transform: scaleX(0); }
  }
  @media (prefers-reduced-motion: reduce) {
    .nt-card, .nt-timeout span { animation: none; }
  }
</style>
