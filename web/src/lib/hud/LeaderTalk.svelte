<script>
  // The gang leader's conversation: a panel on the LEFT of the screen so the ped stays in view. It only shows what the game side sends
  // (client/modules/leader_talk.lua builds every line from live territory / war / XP data) and reports which answer was picked.
  // 1-9 pick an answer, Esc leaves. Same flat theme as the other in-game windows (Event Status / vendor menu).
  import { onDestroy } from 'svelte';
  import { leaderTalk } from './leaderTalkStore.js';
  import { fetchNui } from '../api/nui.js';
  import GangLogo from '../tablet/ui/GangLogo.svelte';
  import { gangPrefs, gangThemeStyle } from '../gangPrefs.js';
  import '../../styles/flat.css';

  // the leader's line types out quickly (a click on it finishes it); with reduced motion it is simply there
  let shown = '';
  let timer = null;
  let lastKey = '';
  const reduce = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

  function type(text) {
    clearInterval(timer);
    if (reduce || !text) { shown = text || ''; return; }
    shown = '';
    let i = 0;
    const step = Math.max(1, Math.ceil(text.length / 45));   // never longer than ~0.9 s
    timer = setInterval(() => {
      i += step;
      shown = text.slice(0, i);
      if (i >= text.length) clearInterval(timer);
    }, 20);
  }
  $: key = $leaderTalk ? `${$leaderTalk.node}|${$leaderTalk.line}` : '';
  $: if (key !== lastKey) { lastKey = key; type($leaderTalk?.line || ''); }
  onDestroy(() => clearInterval(timer));

  function finish() { clearInterval(timer); shown = $leaderTalk?.line || ''; }
  function pick(id) { fetchNui('leaderTalk:pick', { id }); }
  function leave() { leaderTalk.set(null); fetchNui('leaderTalk:close'); }
  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); leave(); return; }
    const n = Number(e.key);
    const opts = $leaderTalk?.options || [];
    if (n >= 1 && n <= opts.length) { e.preventDefault(); pick(opts[n - 1].id); }
  }
</script>

<svelte:window on:keydown={$leaderTalk ? onKey : undefined} />

{#if $leaderTalk}
  <div class="lt-root" data-ui-scope="gang" data-bg={$gangPrefs.bgTheme} style="{$gangThemeStyle}; --lt-accent: {$leaderTalk.speaker?.color || 'var(--c-action)'};">
    <section class="lt" role="dialog" aria-label="Conversation with the gang leader">
      <header class="lt-head">
        {#if $leaderTalk.speaker?.gang}
          <GangLogo logo={$leaderTalk.speaker.logo} label={$leaderTalk.speaker.gang} accentColor={$leaderTalk.speaker.color} size={40} />
        {:else}
          <span class="lt-blank" aria-hidden="true"></span>
        {/if}
        <div class="lt-who">
          <h1>{$leaderTalk.speaker?.label}</h1>
          <p>{$leaderTalk.speaker?.sub}{#if $leaderTalk.speaker?.staff} · staff view{/if}</p>
        </div>
      </header>

      <div class="lt-body">
        <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions a11y-no-noninteractive-element-interactions -->
        <p class="lt-line" on:click={finish}>{shown}</p>
        {#if $leaderTalk.facts?.length}
          <dl class="lt-facts">
            {#each $leaderTalk.facts as f}
              <div><dt>{f.k}</dt><dd>{f.v}</dd></div>
            {/each}
          </dl>
        {/if}
      </div>

      <ul class="lt-opts">
        {#each $leaderTalk.options || [] as o, i (o.id)}
          <li>
            <button type="button" class="lt-opt" class:quiet={o.id === 'leave'} on:click={() => (o.id === 'leave' ? leave() : pick(o.id))}>
              <kbd>{i + 1}</kbd><span>{o.label}</span>
            </button>
          </li>
        {/each}
      </ul>

      <footer class="lt-foot"><kbd>Esc</kbd> Walk away</footer>
    </section>
  </div>
{/if}

<style>
  /* no backdrop: the ped must stay in view. Only the panel takes the mouse. */
  .lt-root { position: fixed; inset: 0; z-index: 6200; pointer-events: none; font-family: var(--font-ui); }
  .lt {
    pointer-events: all; position: absolute; left: clamp(16px, 2.4vw, 44px); bottom: clamp(96px, 21vh, 260px);
    width: min(400px, 92vw); max-height: min(78vh, 640px); display: flex; flex-direction: column; overflow: hidden;
    color: var(--text-main); background: var(--c-panel); border: 1px solid var(--tablet-border-strong); border-left: 4px solid var(--lt-accent);
    border-radius: var(--r-panel); animation: lt-in 160ms ease-out;
  }
  @keyframes lt-in { from { opacity: 0; transform: translateX(-14px); } to { opacity: 1; transform: none; } }
  @media (prefers-reduced-motion: reduce) { .lt { animation: none; } }

  .lt-head { display: flex; align-items: center; gap: 12px; padding: 14px 16px; background: var(--c-base); border-bottom: 1px solid var(--c-line); }
  .lt-blank { flex: none; width: 40px; height: 40px; border-radius: var(--r-ctl); background: var(--c-raised); border: 1px solid var(--c-line); }
  .lt-who { min-width: 0; }
  h1 { margin: 0; font-size: var(--fs-emph); font-weight: 700; line-height: 1.15; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .lt-who p { margin: 3px 0 0; font-size: var(--fs-small); color: var(--text-dim); }

  .lt-body { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 16px; }
  .lt-line { margin: 0; min-height: 3.2em; font-size: var(--fs-emph); line-height: 1.4; font-weight: 500; cursor: default; }
  .lt-facts { margin: 14px 0 0; padding: 0; border-top: 1px solid var(--c-line); }
  .lt-facts div { display: flex; gap: 12px; justify-content: space-between; align-items: baseline; padding: 7px 0; border-bottom: 1px solid var(--c-line-soft); }
  dt { flex: none; font-size: var(--fs-meta); font-weight: 700; color: var(--text-dim); }
  dd { margin: 0; min-width: 0; text-align: right; font-size: var(--fs-small); font-weight: 600; font-variant-numeric: tabular-nums; }

  .lt-opts { list-style: none; margin: 0; padding: 0 16px 14px; display: flex; flex-direction: column; gap: 6px; }
  .lt-opt {
    width: 100%; display: flex; align-items: center; gap: 12px; padding: 9px 12px; text-align: left; font: inherit; font-size: var(--fs-body); font-weight: 600;
    color: var(--text-main); background: var(--c-raised); border: 1px solid var(--c-line); border-radius: var(--r-ctl); cursor: pointer;
  }
  .lt-opt:hover { background: var(--c-action); border-color: var(--c-action); color: var(--on-accent); }
  .lt-opt.quiet { color: var(--text-dim); font-weight: 500; }
  .lt-opt.quiet:hover { color: var(--on-accent); }
  kbd { flex: none; min-width: 22px; padding: 1px 6px; text-align: center; font: 700 11.5px var(--font-ui); border-radius: 4px; border: 1px solid currentColor; opacity: 0.85; }
  .lt-foot { padding: 9px 16px; font-size: var(--fs-meta); color: var(--text-dim); border-top: 1px solid var(--c-line); display: flex; align-items: center; gap: 8px; }

  @media (max-height: 620px) { .lt { bottom: 64px; max-height: 88vh; } .lt-line { font-size: var(--fs-body); } }
</style>
