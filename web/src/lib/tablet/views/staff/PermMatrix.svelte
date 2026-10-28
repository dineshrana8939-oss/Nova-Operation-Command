<script>
  // Permission matrix shared by the role editor (mode="role": value = { key: true }) and the staff editor
  // (mode="override": value = overrides { key: true|false }, base = the role's own permissions, tri-state cells).
  import Icon from '../../ui/Icon.svelte';
  import {
    ACTIONS, ACTION_LABELS, permKey, groupSections, normaliseMap, effectiveMap,
    toggleRoleCell, toggleRoleRow, sectionAllOn, cycleOverride, toggleOverrideRow, cellState,
  } from './permLogic.js';

  export let sections = [];
  export let mode = 'role';
  export let value = {};
  export let base = {};
  export let me = {};
  export let readOnly = false;
  export let maxHeight = '46vh';

  $: override = mode === 'override';
  $: groups = groupSections(sections);
  $: eff = override ? effectiveMap(base, value, sections) : normaliseMap(value, sections);
  $: overrideCount = override ? Object.keys(value).length : 0;
  $: holdsAll = !!(me && (me.isSuperAdmin || me.isOwner));
  $: myKeys = (me && me.keys) || {};

  // You cannot hand out a key you do not hold yourself (the server rejects it too).
  const held = (keys, all, key) => all || !!keys[key];

  function cellClick(section, action) {
    if (readOnly) return;
    if (override) value = cycleOverride(base, value, sections, section, action);
    else value = toggleRoleCell(value, section, action);
  }
  function rowClick(section) {
    if (readOnly) return;
    if (override) value = toggleOverrideRow(base, value, sections, section);
    else value = toggleRoleRow(value, section);
  }
  function clearOverrides() { if (!readOnly) value = {}; }

  // Role-mode presets. They only touch the keys the editor may hand out (anything they do not hold stays as it is).
  function preset(kind) {
    if (readOnly || override) return;
    const next = { ...value };
    for (const s of sections) {
      for (const a of s.actions) {
        const k = permKey(s, a);
        if (!held(myKeys, holdsAll, k)) continue;
        const wanted = kind === 'all' || (kind === 'view' && (a === 'visible' || a === 'view'));
        if (wanted) next[k] = true; else delete next[k];
      }
    }
    value = next;
  }
  $: totalKeys = sections.reduce((n, s) => n + s.actions.length, 0);
  $: onKeys = Object.keys(eff).length;

  const cellTitle = (section, action, st, on, canHold) => {
    if (!canHold) return `You do not hold ${ACTION_LABELS[action]} on ${section.label}, so you cannot grant it.`;
    if (!override) return `${ACTION_LABELS[action]} - ${section.label}`;
    const inherited = st === 'inherit' ? ` (inherited from role: ${on ? 'on' : 'off'})` : '';
    const stLabel = st === 'inherit' ? 'inherit' : st === 'on' ? 'forced on' : 'forced off';
    return `${ACTION_LABELS[action]} - ${section.label}: ${stLabel}${inherited}. Click to cycle.`;
  };
</script>

<div class="pm">
  <div class="pm-bar">
    {#if override}
      <span class="pm-legend">
        <span class="lg"><span class="sw inh"></span>Inherited from role</span>
        <span class="lg"><span class="sw on"><Icon name="check" size={11} /></span>Forced on</span>
        <span class="lg"><span class="sw off"><Icon name="close" size={11} /></span>Forced off</span>
        <span class="pm-hint">Click a cell to cycle</span>
      </span>
      <span class="pm-ov">
        <span class="pm-count" class:has={overrideCount > 0}>{overrideCount} override{overrideCount === 1 ? '' : 's'}</span>
        <button type="button" class="btn btn-sm" disabled={readOnly || overrideCount === 0} on:click={clearOverrides}>Clear overrides</button>
      </span>
    {:else}
      <span class="pm-legend">
        <span class="pm-hint">Turning any action on also turns on Visible and View. Turning Visible or View off clears the whole row. A dash (&mdash;) means that action does not exist for that section.</span>
      </span>
      <span class="pm-ov">
        <span class="pm-count" class:has={onKeys > 0}>{onKeys} of {totalKeys} on</span>
        {#if !readOnly}
          <span class="pm-presets" role="group" aria-label="Quick presets">
            <button type="button" class="btn btn-sm" on:click={() => preset('view')} title="Visible and View on for every section, nothing else">View only</button>
            <button type="button" class="btn btn-sm" on:click={() => preset('all')} title="Everything you are allowed to hand out">Grant all</button>
            <button type="button" class="btn btn-sm" on:click={() => preset('none')} title="Turn every permission off">Clear all</button>
          </span>
        {/if}
      </span>
    {/if}
  </div>

  <div class="pm-scroll" style="max-height: {maxHeight}">
    <table class="pm-table">
      <thead>
        <tr>
          <th class="c-label">Section</th>
          {#each ACTIONS as a}<th class="c-act">{ACTION_LABELS[a]}</th>{/each}
          <th class="c-act">All</th>
        </tr>
      </thead>
      <tbody>
        {#each groups as g (g.group)}
          {#if g.group}
            <tr class="pm-group"><td colspan={ACTIONS.length + 2}>{g.group}</td></tr>
          {/if}
          {#each g.items as s (s.id)}
            <tr>
              <td class="c-label" title={s.hint || s.label}>
                <span class="lbl">{s.label}</span>
                {#if s.hint}<span class="hint">{s.hint}</span>{/if}
              </td>
              {#each ACTIONS as a}
                <td class="c-act">
                  {#if s.actions.includes(a)}
                    {@const k = permKey(s, a)}
                    {@const st = override ? cellState(value, k) : value[k] ? 'on' : 'off'}
                    {@const isOn = !!eff[k]}
                    {@const canHold = held(myKeys, holdsAll, k)}
                    <button
                      type="button"
                      class="cell"
                      class:inh={override && st === 'inherit'}
                      class:on={st === 'on' || (!override && isOn)}
                      class:off={override && st === 'off'}
                      class:eff-on={isOn}
                      data-key={k}
                      data-state={override ? st : isOn ? 'on' : 'off'}
                      data-effective={isOn ? 'on' : 'off'}
                      disabled={readOnly || !canHold}
                      title={cellTitle(s, a, st, isOn, canHold)}
                      on:click={() => cellClick(s, a)}
                    >
                      {#if override && st === 'off'}<Icon name="close" size={12} />
                      {:else if isOn}<Icon name="check" size={12} />{/if}
                    </button>
                  {:else}
                    <span class="na" title="This action does not exist for this section, so there is nothing to tick." aria-label="Not applicable">&mdash;</span>
                  {/if}
                </td>
              {/each}
              <td class="c-act">
                {#if true}
                  {@const allOn = override ? s.actions.every((a) => !!eff[permKey(s, a)]) : sectionAllOn(eff, s)}
                  {@const canAll = s.actions.every((a) => held(myKeys, holdsAll, permKey(s, a)))}
                  <button
                    type="button"
                    class="cell all"
                    class:on={allOn && !override}
                    class:eff-on={allOn}
                    data-row={s.id}
                    data-all={allOn ? 'on' : 'off'}
                    disabled={readOnly || !canAll}
                    title={canAll ? (allOn ? 'Turn every action in this section off' : 'Turn every action in this section on') : 'You do not hold every action in this section, so you cannot toggle them all.'}
                    on:click={() => rowClick(s)}
                  >
                    {#if allOn}<Icon name="check" size={12} />{/if}
                  </button>
                {/if}
              </td>
            </tr>
          {/each}
        {/each}
      </tbody>
    </table>
  </div>
</div>

<style>
  .pm { display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; }
  .pm-bar {
    display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
    /* never squeezed by the matrix below: when the hint wraps to two lines the quick-preset buttons used to slide under the table */
    flex: none; min-height: 40px; padding: 0 0 8px;
  }
  .pm-legend { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; font-size: var(--fs-meta); color: var(--text-muted); }
  .lg { display: inline-flex; align-items: center; gap: 6px; }
  .pm-hint { color: var(--text-muted); }
  .sw { width: 16px; height: 16px; border-radius: 4px; border: 1px solid var(--c-line); display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; }
  .sw.inh { border-style: dashed; border-color: var(--tablet-border-strong); }
  .sw.on { background: var(--accent-primary); border-color: var(--accent-primary); color: var(--on-accent, #fff); }
  .sw.off { border-color: var(--red); color: var(--red); }
  .pm-ov { display: inline-flex; align-items: center; gap: 10px; }
  .pm-count { font-size: var(--fs-small); font-weight: 600; color: var(--text-muted); }
  .pm-count.has { color: var(--accent-primary-light); }

  .pm-presets { display: inline-flex; gap: 6px; }

  .pm-scroll { flex: 1 1 auto; min-height: 0; overflow: auto; border: 1px solid var(--c-line); border-radius: var(--r-panel); background: var(--c-base); }
  .pm-table { width: 100%; min-width: 640px; border-collapse: separate; border-spacing: 0; table-layout: fixed; font-size: var(--fs-small); }
  .pm-table th {
    position: sticky; top: 0; z-index: 2;
    height: 38px; padding: 0 8px; text-align: center;
    font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.02em; color: var(--text-dim);
    background: var(--c-panel); border-bottom: 1px solid var(--c-line-strong, var(--c-line)); white-space: nowrap;
  }
  .pm-table th.c-label { text-align: left; padding-left: 14px; }
  .pm-table td { padding: 8px 8px; border-bottom: 1px solid var(--c-line-soft); text-align: center; vertical-align: middle; }
  .pm-table tbody tr:hover td { background: var(--c-raised); }
  .pm-table td.c-label { text-align: left; padding-left: 14px; padding-right: 12px; }
  /* the section label and its explanation stack: nothing is cut off any more (the full text is also the hover title) */
  .lbl { display: block; color: var(--text-main); font-weight: 700; line-height: 1.3; }
  .hint {
    display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; line-clamp: 2; overflow: hidden;
    margin-top: 2px; color: var(--text-muted); font-size: var(--fs-meta); line-height: 1.4;
  }
  .c-act { width: 68px; }
  /* the "All" column reads as a separate summary column */
  .pm-table th:last-child, .pm-table td:last-child { border-left: 1px solid var(--c-line); }
  .pm-group td {
    padding: 0 14px; height: 32px; text-align: left;
    font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase;
    color: var(--accent-primary-light); background: var(--c-panel); border-bottom: 1px solid var(--c-line);
    box-shadow: inset 3px 0 0 var(--accent-primary);
  }
  .pm-table tbody tr.pm-group:hover td { background: var(--c-panel); }
  .pm-table .pm-group td:last-child { border-left: 0; }
  .pm-table tbody tr:last-child td { border-bottom: 0; }
  .na { color: var(--c-text-3); opacity: 0.45; }

  .cell {
    width: 26px; height: 26px; padding: 0; box-sizing: border-box;
    display: inline-flex; align-items: center; justify-content: center;
    background: var(--c-base); border: 1.5px solid var(--text-muted); border-radius: 6px;
    color: var(--lt-ffffff, #fff); cursor: pointer;
    transition: background 0.12s ease, border-color 0.12s ease;
  }
  .cell:hover:not(:disabled) { border-color: var(--accent-primary); }
  .cell:focus-visible { outline: 2px solid var(--accent-primary-light); outline-offset: 2px; }
  .cell:disabled { opacity: 0.4; cursor: not-allowed; border-style: dotted; }
  .cell.on { background: var(--accent-primary); border-color: var(--accent-primary); color: var(--on-accent, inherit); }
  /* inherited: dimmed, dashed — shows what the role gives */
  .cell.inh { border-style: dashed; background: transparent; color: var(--text-muted); }
  .cell.inh.eff-on { opacity: 0.8; }
  .cell.inh:not(.eff-on) { opacity: 0.55; }
  .cell.off { background: transparent; border-color: var(--red); color: var(--red); }
  .cell.all.eff-on:not(.on) { color: var(--text-main); }

  @media (prefers-reduced-motion: reduce) { .cell { transition: none; } }</style>
