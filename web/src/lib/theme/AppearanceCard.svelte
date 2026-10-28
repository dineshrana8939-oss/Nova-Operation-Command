<script>
  import { createEventDispatcher } from 'svelte';
  import Icon from '../tablet/ui/Icon.svelte';
  import { THEMES, THEME_IDS, DEFAULT_THEME, themeIdOf, ACCENTS, BACKGROUNDS } from './appearance.js';

  // The picker both tablets share: the three themes, each shown as a miniature of the real interface in its own colours.
  // It only DRAFTS a choice; nothing on the real interface changes until Apply Theme (the parent saves it into its own prefs
  // and wears it on its own root). `applied` and the 'apply' / 'reset' events keep the { accent, bgTheme } shape of the saved prefs.
  export let applied = { accent: THEMES[DEFAULT_THEME].accent, bgTheme: THEMES[DEFAULT_THEME].bgTheme };

  const dispatch = createEventDispatcher();

  let draft = themeIdOf(applied.accent, applied.bgTheme);
  let lastApplied = '';
  // follow the saved look when it changes from outside (Reset, or opening the tab)
  $: {
    const key = themeIdOf(applied.accent, applied.bgTheme);
    if (key !== lastApplied) {
      lastApplied = key;
      draft = key;
    }
  }
  $: current = themeIdOf(applied.accent, applied.bgTheme);
  $: dirty = draft !== current;
  $: isDefault = current === DEFAULT_THEME;

  // the miniature's colours, from the same tokens the real interface is built from
  function pv(id) {
    const t = THEMES[id];
    const a = ACCENTS[t.accent];
    const b = BACKGROUNDS[t.bgTheme];
    const light = !!b.light;
    return `--pv-base:${b.admin.base};--pv-panel:${b.admin.panel};--pv-raised:${b.admin.raised};--pv-line:${b.admin.line};` +
      `--pv-text:${light ? '#111111' : '#f5f5f5'};--pv-text2:${light ? '#555555' : '#b0b0b0'};--pv-btn:${a.base};--pv-btn-ink:${a.ink};`;
  }

  const apply = () => dispatch('apply', { accent: THEMES[draft].accent, bgTheme: THEMES[draft].bgTheme });
  function reset() {
    draft = DEFAULT_THEME;
    dispatch('reset');
  }
</script>

<div class="ap">
  <div class="ap-themes" role="radiogroup" aria-label="Theme">
    {#each THEME_IDS as id}
      <button type="button" class="ap-theme" class:on={draft === id} role="radio" aria-checked={draft === id} on:click={() => (draft = id)}>
        <span class="pv" style={pv(id)} aria-hidden="true">
          <span class="pv-bar"><i class="pv-dot"></i><b>Preview</b></span>
          <span class="pv-body">
            <span class="pv-side"><i class="on">Dashboard</i><i>Events</i><i>Gangs</i></span>
            <span class="pv-main">
              <span class="pv-card">
                <span class="pv-line"></span>
                <span class="pv-line short"></span>
                <span class="pv-row">
                  <span class="pv-btn">Primary</span>
                  <span class="pv-act g">Add</span><span class="pv-act b">Edit</span><span class="pv-act r">Delete</span>
                  <span class="pv-tg"><i></i></span>
                </span>
              </span>
            </span>
          </span>
        </span>
        <span class="ap-name">{#if draft === id}<Icon name="check" size={13} />{/if}{THEMES[id].label}</span>
      </button>
    {/each}
  </div>

  <div class="ap-actions">
    <button type="button" class="ap-btn primary" disabled={!dirty} on:click={apply}><Icon name="check" size={13} /> Apply Theme</button>
    <button type="button" class="ap-btn" disabled={isDefault && !dirty} on:click={reset}>Reset to Default</button>
    <span class="ap-state">{dirty ? 'Previewing — not applied yet' : 'Current theme applied'}</span>
  </div>
</div>

<style>
  .ap { display: flex; flex-direction: column; gap: 16px; }
  .ap-themes { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 12px; }
  .ap-theme {
    display: flex; flex-direction: column; gap: 10px; padding: 10px; text-align: left;
    background: var(--c-raised); border: 1px solid var(--c-line); border-radius: var(--r-panel);
    color: var(--text-main); font: inherit; cursor: pointer;
  }
  .ap-theme:hover { border-color: var(--tablet-border-hover, var(--c-line)); }
  .ap-theme.on { border-color: var(--accent-primary); outline: 1px solid var(--accent-primary); }
  .ap-name { display: inline-flex; align-items: center; gap: 6px; font-size: 14px; font-weight: 600; }

  /* the miniature: flat, rectangular, in the theme's own colours */
  .pv { display: flex; flex-direction: column; background: var(--pv-base); border: 1px solid var(--pv-line); border-radius: 4px; overflow: hidden; color: var(--pv-text); font-size: 11px; }
  .pv-bar { display: flex; align-items: center; gap: 6px; height: 24px; padding: 0 9px; background: var(--pv-panel); border-bottom: 1px solid var(--pv-line); }
  .pv-bar b { font-weight: 600; font-size: 11px; }
  .pv-dot { width: 7px; height: 7px; background: var(--pv-btn); border: 1px solid var(--pv-line); }
  .pv-body { display: grid; grid-template-columns: 84px 1fr; min-height: 96px; }
  .pv-side { display: flex; flex-direction: column; gap: 2px; padding: 6px; background: var(--pv-panel); border-right: 1px solid var(--pv-line); }
  .pv-side i { font-style: normal; padding: 3px 6px; border-radius: 3px; color: var(--pv-text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pv-side i.on { background: var(--pv-btn); color: var(--pv-btn-ink); font-weight: 600; }
  .pv-main { padding: 7px; }
  .pv-card { display: flex; flex-direction: column; gap: 5px; padding: 7px; background: var(--pv-panel); border: 1px solid var(--pv-line); border-radius: 3px; }
  .pv-line { height: 5px; border-radius: 2px; background: var(--pv-text2); opacity: 0.45; }
  .pv-line.short { width: 58%; }
  .pv-row { display: flex; align-items: center; gap: 4px; margin-top: 3px; flex-wrap: wrap; }
  .pv-btn { padding: 2px 7px; border-radius: 3px; background: var(--pv-btn); color: var(--pv-btn-ink); font-weight: 600; }
  .pv-act { padding: 2px 5px; border-radius: 3px; color: #0a0a0a; font-weight: 600; }
  .pv-act.g { background: #22c55e; } .pv-act.b { background: #3b82f6; } .pv-act.r { background: #ef4444; }
  .pv-tg { margin-left: auto; width: 22px; height: 11px; border-radius: 3px; background: var(--pv-btn); position: relative; }
  .pv-tg i { position: absolute; top: 2px; right: 2px; width: 7px; height: 7px; border-radius: 2px; background: var(--pv-btn-ink); }

  .ap-actions { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
  .ap-btn {
    height: 36px; padding: 0 14px; display: inline-flex; align-items: center; gap: 7px;
    border-radius: 4px; background: var(--c-raised); border: 1px solid var(--c-line); color: var(--text-main);
    font: inherit; font-size: 13.5px; font-weight: 600; cursor: pointer;
  }
  .ap-btn:hover:not(:disabled) { background: var(--c-hover); }
  .ap-btn.primary { background: var(--es-accent, var(--accent-primary)); border-color: var(--es-accent, var(--accent-primary)); color: var(--on-es-accent, #fff); }
  .ap-btn.primary:hover:not(:disabled) { background: var(--es-accent-hover, var(--accent-primary-light)); }
  .ap-btn:disabled { opacity: 0.45; cursor: not-allowed; }
  .ap-state { font-size: 12.5px; color: var(--text-muted); }
</style>
