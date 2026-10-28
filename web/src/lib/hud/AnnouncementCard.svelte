<script>
  // The announcement banner card itself - the ONE piece of markup the in-game HUD (Announcement.svelte) and the
  // tablet's "In-Game Banner Preview" both render, so what an admin previews is exactly what players get.
  // Pure presentation: everything (event colour, eyebrow line, status badge, image framing) comes in as props.
  import { themeFor, themeVars, hexToRgb } from './eventThemes.js';
  import { hudIcon } from './hudIcons.js';
  import GangLogo from '../tablet/ui/GangLogo.svelte';
  import './hud-shared.css';

  export let eventKey = 'server';
  export let subtitle = 'SERVER ANNOUNCEMENT // ADMIN BROADCAST';
  export let title = '';
  export let message = '';
  export let status = 'BROADCAST';
  export let gang = null;              // { logo, label, accentColor } - shown instead of the event icon
  export let bannerImg = null;
  export let bannerPos = '50% 50%';
  export let bannerFit = 'cover';
  export let bannerZoom = 1.0;
  export let bannerColor = null;       // custom accent (admin broadcast), overrides the event colour
  export let durationMs = 7000;
  export let preview = false;          // tablet preview: settled (no entrance animation), full width of its box

  $: theme = themeFor(eventKey);
  $: accentStyle = bannerColor ? `--accent:${bannerColor};--accent2:${bannerColor};--accentRGB:${hexToRgb(bannerColor)};` : '';
</script>

<div class="ann-root" class:preview style="{themeVars(eventKey)};{accentStyle}">
  <div class="hx-card ann-frame" class:has-custom-photo={!!bannerImg}>
    <div class="hx-texture"></div>
    <div class="hx-slice"></div>
    <div class="hx-rail"><span></span></div>

    {#if bannerImg}
      <div
        class="ann-bg-image"
        style="background-image: url('{bannerImg}'); background-position: {bannerPos}; background-size: {bannerFit === 'contain' ? 'contain' : 'cover'}; transform: scale({bannerZoom}); transform-origin: {bannerPos};"
      ></div>
      <div class="ann-bg-overlay"></div>
    {/if}

    <div class="ann-body">
      {#if gang}
        <div class="ann-logo">
          <GangLogo logo={gang.logo} label={gang.label} accentColor={gang.accentColor} size={50} />
        </div>
      {:else}
        <div class="hx-iconbox ann-icon">{@html hudIcon(theme.icon)}</div>
      {/if}

      <div class="ann-content">
        <div class="ann-eyebrow"><span class="hx-live-dot"></span>{subtitle}</div>
        <div class="ann-title">{title}</div>
        {#if message}<div class="ann-message">{message}</div>{/if}
      </div>

      <div class="ann-meta">
        <div class="ann-status">{status}</div>
        <div class="ann-kind">{theme.label}</div>
        <div class="ann-foot">{theme.footer}</div>
      </div>
    </div>

    <div class="ann-timeline"><i style="animation-duration:{durationMs || 7000}ms"></i></div>
  </div>
</div>

<style>
  /* Compact, rectangular banner: same information as before (eyebrow, title, message, status badge, event name and the
     footer line, now under the badge) in a shorter, wider card. */
  .ann-root { display: flex; justify-content: center; }
  .ann-frame {
    width: min(650px, 92vw);
    animation: hxEnter 0.62s cubic-bezier(0.16, 1, 0.3, 1) both;
    position: relative;
    overflow: hidden;
  }
  .ann-bg-image {
    position: absolute;
    right: 0;
    top: 0;
    bottom: 0;
    width: 40%;
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
    opacity: 0.72;
    mask-image: linear-gradient(90deg, transparent 0%, rgba(0, 0, 0, 1) 35%);
    -webkit-mask-image: linear-gradient(90deg, transparent 0%, rgba(0, 0, 0, 1) 35%);
    pointer-events: none;
    z-index: 1;
  }
  .ann-bg-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(90deg, rgba(8, 10, 15, 0.95) 0%, rgba(8, 10, 15, 0.6) 60%, rgba(8, 10, 15, 0.2) 100%);
    pointer-events: none;
    z-index: 1;
  }

  .ann-body { position: relative; z-index: 2; display: flex; align-items: center; gap: 15px; padding: 17px 22px 19px 17px; }
  .ann-icon { width: 50px; height: 50px; border-radius: var(--r-tag); }
  .ann-icon :global(svg) { width: 25px; height: 25px; }
  .ann-logo { flex: none; }

  .ann-content { flex: 1; min-width: 0; }
  .ann-eyebrow {
    display: flex; align-items: center; gap: 6px;
    color: var(--accent2); font-size: 13.5px; font-weight: 800; letter-spacing: 0.07em; text-transform: uppercase;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    opacity: 0; animation: annUp 0.45s 0.12s ease-out forwards;
  }
  .ann-title {
    margin-top: 3px; color: #fff; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 26px; line-height: 1.1; font-weight: 700; letter-spacing: 0.025em;
    text-transform: uppercase; text-shadow: 0 1px 3px rgba(0, 0, 0, 0.6); overflow-wrap: anywhere;
    opacity: 0; animation: annIn 0.5s 0.2s cubic-bezier(0.16, 1, 0.3, 1) forwards;
  }
  .ann-message {
    margin-top: 5px; color: #d6d8da; font-size: 16.5px; line-height: 1.35; font-weight: 500; letter-spacing: 0.01em;
    white-space: pre-line;
    opacity: 0; animation: annUp 0.45s 0.32s ease-out forwards;
  }

  .ann-meta { flex: none; min-width: 104px; max-width: 156px; text-align: center; opacity: 0; animation: annIn 0.45s 0.28s ease-out forwards; }
  .ann-status {
    padding: 6px 10px; border: 1px solid rgba(var(--accentRGB), 0.45); border-radius: var(--r-tag); background: rgba(0, 0, 0, 0.34);
    color: #fff; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 16px; font-weight: 700; letter-spacing: 0.05em; white-space: nowrap;
  }
  .ann-kind { margin-top: 5px; color: var(--accent2); font-size: 12.5px; font-weight: 800; letter-spacing: 0.06em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ann-foot { margin-top: 2px; color: #9a9ea0; font-size: 11.5px; font-weight: 800; letter-spacing: 0.06em; text-transform: uppercase; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .ann-timeline { position: absolute; left: 0; right: 0; bottom: 0; height: 2px; background: rgba(255, 255, 255, 0.05); }
  .ann-timeline i { display: block; height: 100%; background: var(--accent); transform-origin: left; animation: annShrink 7s linear forwards; }

  /* tablet preview: the card as it looks once it has settled, at its real size */
  .preview .ann-frame { animation: none; }
  .preview .ann-eyebrow, .preview .ann-title, .preview .ann-message, .preview .ann-meta { opacity: 1; animation: none; transform: none; }
  .preview .ann-timeline i { animation: none; transform: scaleX(0.7); }

  @keyframes annUp { to { opacity: 1; transform: translateY(0); } }
  @keyframes annIn { from { opacity: 0; transform: translateX(14px); } to { opacity: 1; transform: translateX(0); } }
  @keyframes annShrink { from { transform: scaleX(1); } to { transform: scaleX(0); } }
</style>
