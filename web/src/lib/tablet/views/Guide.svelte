<script>
  // Admin tablet → User Guide.
  //   • The words come from docs/user_guide.md, read from disk by the server every time this tab opens — edit that file and
  //     reopen the tab (no restart, no rebuild).
  //   • {{name}} placeholders in the file are filled from config.lua (guideValues.js), so commands, keys and numbers follow the
  //     config.
  //   • The sidebar tabs, the event types and any command nobody has described yet are listed straight from the code (the
  //     @tabs, @eventtypes and @commands lines in the file), so they cannot go out of date.
  import { onMount } from 'svelte';
  import { bootstrap, viewSub } from '../../stores.js';
  import { loadUserGuide } from '../../api/guide.js';
  import { parseGuide, groupOrder } from '../guide/guideParse.js';
  import { buildValues, resolve } from '../guide/guideValues.js';
  import { NAV_GROUPS } from '../navGroups.js';
  import { KIND_TABS } from '../eventKinds.js';
  import Icon from '../ui/Icon.svelte';
  import '../tablet-theme.css';

  const STORE_KEY = 'nova_guide_topic';
  let rawTopics = [];
  let commands = [];
  let docText = '';
  let loading = true;
  let error = '';
  let currentId = '';
  let scroller;

  async function load() {
    loading = true;
    error = '';
    let res = null;
    try { res = await loadUserGuide(); } catch (e) { res = null; }
    loading = false;
    if (!res || !res.ok || !res.text) {
      error = (res && res.error) || 'The guide could not be loaded. Is the resource running?';
      return;
    }
    docText = String(res.text).toLowerCase();
    rawTopics = parseGuide(res.text);
    commands = Array.isArray(res.commands) ? res.commands : [];
    let saved = '';
    try { saved = localStorage.getItem(STORE_KEY) || ''; } catch (e) { /* storage can be unavailable */ }
    if (!rawTopics.some((t) => t.id === currentId)) currentId = rawTopics.some((t) => t.id === saved) ? saved : (rawTopics[0]?.id || '');
    // open in the category chosen in the menu bar: the remembered topic if it belongs to it, else the category's first topic
    const inMenuGroup = rawTopics.filter((t) => slug(t.group) === $viewSub);
    if (inMenuGroup.length && !inMenuGroup.some((t) => t.id === currentId)) currentId = (inMenuGroup.find((t) => t.id === saved) || inMenuGroup[0]).id;
  }
  onMount(load);

  function open(id) {
    currentId = id;
    try { localStorage.setItem(STORE_KEY, id); } catch (e) { /* ignore */ }
    if (scroller) scroller.scrollTo({ top: 0 });      // every topic opens at its top
  }

  // The category is chosen in the menu bar ($viewSub = the category's name as a slug: 'start-here', 'events' ...) and follows the
  // open topic too (a 'Read more' card can lead into another category).
  const slug = (name) => String(name).toLowerCase().trim().replace(/s+/g, '-');
  function followMenu(sub, list) {
    const g = list.find((x) => slug(x.name) === sub);
    if (g && g.topics.length && !(topic && topic.group === g.name)) open(g.topics[0].id);
  }
  function followTopic(group) {
    if (slug(group) !== $viewSub) viewSub.set(slug(group));
  }

  function jump(bi) {
    const el = scroller && scroller.querySelector(`#sec-${bi}`);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  // {{name}} → the live config value
  $: values = buildValues($bootstrap);
  $: topics = rawTopics.map((t) => resolve(t, values));
  $: order = groupOrder(topics);
  $: topic = topics.find((t) => t.id === currentId) || topics[0] || null;
  $: groups = order.map((g) => ({ name: g, topics: topics.filter((t) => t.group === g) })).filter((g) => g.topics.length);
  $: index = topic ? topics.findIndex((t) => t.id === topic.id) : -1;
  $: groupTopics = topic ? topics.filter((t) => t.group === topic.group) : [];
  $: sections = topic ? topic.blocks.map((b, bi) => ({ b, bi })).filter((x) => x.b.t === 'h').map((x) => ({ bi: x.bi, text: x.b.text })) : [];
  $: prev = index > 0 ? topics[index - 1] : null;
  $: next = index >= 0 && index < topics.length - 1 ? topics[index + 1] : null;
  $: followMenu($viewSub, groups);
  $: if (topic) followTopic(topic.group);
  // commands the file does not mention anywhere
  $: undescribed = commands.filter((c) => !docText.includes(c.toLowerCase()));

  // **bold** and `code`, after escaping, for the few places the file uses them
  const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const fmt = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
</script>

<div class="panel view-enter">
  <div class="panel-header">
    <span class="panel-title"><Icon name="fileText" size={14} /> User Guide</span>
    <button type="button" class="reload" on:click={load} disabled={loading} aria-label="Reload the guide" title="Read docs/user_guide.md again"><Icon name="refresh" size={14} /></button>
  </div>
  <div class="panel-body">
    {#if loading && !topic}
      <div class="state">Loading the guide…</div>
    {:else if error}
      <div class="state bad">{error}</div>
    {:else if topic}
      <div class="guide">
        <!-- the categories (Start here / Events / Systems / Reference) are the floating row under the main menu; below, the topics of the open one -->
        <section class="sub">
          <div class="subhead"><span>{topic.group} · Choose a topic</span><span>{groupTopics.length} {groupTopics.length === 1 ? 'topic' : 'topics'}</span></div>
          <nav class="tabs" aria-label="Guide topics">
            {#each groupTopics as t (t.id)}
              <button type="button" class="tab" class:on={t.id === topic.id} aria-current={t.id === topic.id ? 'page' : undefined} on:click={() => open(t.id)}>
                <Icon name={t.icon} size={14} /><span>{t.title}</span>
              </button>
            {/each}
          </nav>
        </section>

        <!-- the page scrolls on its own, under the tabs -->
        <div class="doc-scroll" bind:this={scroller}>
        <div class="doc-grid">
        <article class="doc">
          <header class="doc-head">
            <span class="doc-ico"><Icon name={topic.icon} size={22} /></span>
            <div>
              <div class="doc-group">{topic.group}<span class="sep">/</span>{groupTopics.indexOf(topic) + 1} of {groupTopics.length}</div>
              <h1>{topic.title}</h1>
              <p class="doc-tag">{topic.tag}</p>
            </div>
          </header>

          {#each topic.blocks as b, bi (bi)}
            {#if b.t === 'p'}
              <p class="txt" class:lede={bi === 0}>{@html fmt(b.text)}</p>
            {:else if b.t === 'h'}
              <h2 id={`sec-${bi}`}>{b.text}</h2>
            {:else if b.t === 'facts'}
              <dl class="facts">
                {#each b.rows as r (r[0])}
                  <div class="fact"><dt>{r[0]}</dt><dd>{@html fmt(r[1])}</dd></div>
                {/each}
              </dl>
            {:else if b.t === 'steps'}
              <ol class="steps">
                {#each b.items as s}<li>{@html fmt(s)}</li>{/each}
              </ol>
            {:else if b.t === 'list'}
              <ul class="bul">
                {#each b.items as s}<li>{@html fmt(s)}</li>{/each}
              </ul>
            {:else if b.t === 'table'}
              <div class="tbl-wrap">
                <table>
                  <thead><tr>{#each b.head as h}<th>{h}</th>{/each}</tr></thead>
                  <tbody>
                    {#each b.rows as r}
                      <tr>{#each r as c, ci}<td class:first={ci === 0}>{@html fmt(c)}</td>{/each}</tr>
                    {/each}
                  </tbody>
                </table>
              </div>
            {:else if b.t === 'tip'}
              <div class="callout tip"><Icon name="info" size={16} /><span>{@html fmt(b.text)}</span></div>
            {:else if b.t === 'warn'}
              <div class="callout warn"><Icon name="warning" size={16} /><span>{@html fmt(b.text)}</span></div>
            {:else if b.t === 'cards'}
              <div class="cards">
                {#each b.items as c (c.ref)}
                  <button type="button" class="card" on:click={() => open(c.ref)}>
                    <span class="c-title">{c.title}</span>
                    <span class="c-text">{c.text}</span>
                    <span class="c-go">Read more <Icon name="arrowRight" size={13} /></span>
                  </button>
                {/each}
              </div>
            {:else if b.t === 'tabs'}
              <!-- straight from the tablet's own sidebar -->
              <div class="auto-tabs">
                {#each NAV_GROUPS as g (g.title)}
                  <div class="at-group">
                    <span class="at-title" style="color:{g.color}">{g.title}</span>
                    <div class="at-items">{#each g.items as it (it.id)}<span class="chip"><Icon name={it.icon} size={13} />{it.label}</span>{/each}</div>
                  </div>
                {/each}
              </div>
            {:else if b.t === 'eventtypes'}
              <!-- straight from the Create Event form -->
              <div class="cards">
                {#each KIND_TABS as k (k.id)}
                  <div class="card static" style="--ac:{k.accent}">
                    <span class="c-title"><Icon name={k.icon} size={15} /> {k.title}</span>
                    <span class="c-text">{k.desc}</span>
                    <span class="c-go muted">{k.adminOnly ? 'Admins and staff can create it' : 'Police can create it too'}</span>
                  </div>
                {/each}
              </div>
            {:else if b.t === 'commands'}
              <!-- every command the script registers that the text above does not mention -->
              {#if undescribed.length}
                <div class="at-items">{#each undescribed as c (c)}<span class="chip mono">/{c}</span>{/each}</div>
              {:else}
                <p class="txt">Every command the script registers is described above.</p>
              {/if}
            {/if}
          {/each}

          <footer class="pager">
            {#if prev}<button type="button" class="btn btn-secondary" on:click={() => open(prev.id)}><Icon name="chevronLeft" size={14} /> {prev.title}</button>{:else}<span></span>{/if}
            {#if next}<button type="button" class="btn btn-secondary" on:click={() => open(next.id)}>{next.title} <Icon name="chevronRight" size={14} /></button>{/if}
          </footer>
        </article>

        <!-- "On this page": the headings of the open topic, so the space beside the text is useful -->
        {#if sections.length}
          <aside class="rail" aria-label="On this page">
            <div class="rail-title">On this page</div>
            {#each sections as s (s.bi)}
              <button type="button" class="rail-link" on:click={() => jump(s.bi)}>{s.text}</button>
            {/each}
          </aside>
        {/if}
        </div>
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  .reload { flex: none; width: 26px; height: 26px; display: grid; place-items: center; border-radius: 7px; color: #8d949c;
    background: transparent; border: 1px solid transparent; transition: color 0.15s, background 0.15s; }
  .reload:hover:not(:disabled) { color: var(--lt-ffffff, #fff); background: rgba(var(--ink-rgb, 255, 255, 255), 0.07); }
  .reload:disabled { opacity: 0.5; cursor: progress; }
  .state { padding: 40px 20px; text-align: center; font-size: var(--fs-emph); color: var(--lt-aeb5bd, #aeb5bd); }
  .state.bad { color: var(--lt-ff9d94, #ff9d94); }
  /* A fixed-height reader: categories, then the topic tabs of the open category, then the page (which scrolls by itself). */
  .guide { display: flex; flex-direction: column; height: calc(100vh - 236px); min-height: 440px; border-radius: 14px; overflow: hidden;
    background: rgba(var(--ltc-8-11-16, 8, 11, 16), 0.55); border: 1px solid rgba(110, 140, 180, 0.2); }
  button { font-family: inherit; cursor: pointer; }
  button:focus-visible { outline: 2px solid #7bb6f2; outline-offset: 2px; }
  h1, h2, p, dl, dd { margin: 0; }
  .tab { flex: none; display: inline-flex; align-items: center; gap: 8px; white-space: nowrap; border-radius: 8px; font-weight: 600; line-height: 1;
    color: var(--lt-aeb5bd, #aeb5bd); background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72); border: 1px solid rgba(110, 140, 180, 0.22); transition: background 0.15s, color 0.15s, border-color 0.15s; }
  .tab { height: 36px; padding: 0 13px; font-size: var(--fs-body); }
  .tab:hover { color: var(--lt-ffffff, #fff); border-color: rgba(140, 175, 220, 0.4); }
  .tab.on { color: var(--on-accent); background: var(--c-action); border-color: var(--accent-primary); box-shadow: inset 0 -2px var(--accent-primary); }
  .tab :global(svg) { flex: none; color: var(--lt-7bb6f2, #7bb6f2); }

  /* the topics of the open category: a floating row of tabs */
  .sub { flex: none; padding: 11px 15px 8px; background: rgba(var(--ltc-10-14-20, 10, 14, 20), 0.6); border-bottom: 1px solid rgba(110, 140, 180, 0.2); }
  .subhead { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: var(--fs-meta); font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: #8d949c; }
  .tabs { display: flex; gap: 7px; overflow-x: auto; padding: 1px 1px 6px; scrollbar-width: thin; scrollbar-color: rgba(130, 165, 210, 0.3) transparent; }

  /* the page: its own scroll area */
  .doc-scroll { flex: 1; min-height: 0; overflow-y: auto; padding: 22px 22px 0 26px; scrollbar-width: thin; scrollbar-color: rgba(130, 165, 210, 0.3) transparent; }
  /* the text takes the width it is given; the narrow column beside it lists the headings of the open page */
  .doc-grid { display: grid; grid-template-columns: minmax(0, 1fr) 200px; gap: 32px; align-items: start; }
  .doc { min-width: 0; display: flex; flex-direction: column; gap: 16px; padding-bottom: 24px; }
  .rail { position: sticky; top: 0; display: flex; flex-direction: column; gap: 2px; padding: 4px 0 4px 16px; border-left: 1px solid rgba(110, 140, 180, 0.22); }
  .rail-title { margin-bottom: 6px; font-size: var(--fs-small); font-weight: 600; color: #8d949c; }
  .rail-link { padding: 6px 8px; border-radius: 7px; text-align: left; font-size: var(--fs-body); line-height: 1.3; color: var(--lt-aeb5bd, #aeb5bd); background: transparent; border: 0; transition: color 0.15s, background 0.15s; }
  .rail-link:hover { color: var(--lt-ffffff, #fff); background: rgba(var(--ink-rgb, 255, 255, 255), 0.05); }
  .doc-head { display: flex; align-items: center; gap: 16px; padding-bottom: 16px; border-bottom: 1px solid rgba(110, 140, 180, 0.22); }
  .doc-ico { flex: none; width: 52px; height: 52px; display: grid; place-items: center; border-radius: 13px; color: var(--lt-7bb6f2, #7bb6f2); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .doc-group { font-size: var(--fs-small); color: var(--lt-7bb6f2, #7bb6f2); font-weight: 600; }
  h1 { font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: 32px; font-weight: 700; line-height: 1.08; }
  .doc-tag { margin-top: 4px; font-size: var(--fs-emph); color: #8d949c; }
  h2 { margin-top: 8px; font-family: var(--font-display); font-stretch: var(--stretch-display); font-size: var(--fs-title); font-weight: 600; }
  .doc-group .sep { margin: 0 8px; color: #55606c; }
  .txt { font-size: var(--fs-emph); line-height: 1.7; color: var(--lt-d6dade, #d6dade); max-width: 84ch; }
  .txt.lede { font-size: var(--fs-emph); line-height: 1.65; color: var(--lt-eceef0, #eceef0); }
  h2 { padding-top: 6px; }
  .doc :global(b) { color: var(--lt-ffffff, #fff); font-weight: 600; }
  .doc :global(code) { padding: 1px 6px; border-radius: 5px; font-family: var(--font-mono); font-size: 0.92em; color: var(--lt-bcd9f7, #bcd9f7); background: var(--c-hover); }

  .facts { display: flex; flex-direction: column; border-radius: 12px; overflow: hidden; background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72); border: 1px solid rgba(110, 140, 180, 0.22); }
  .fact { display: grid; grid-template-columns: 170px minmax(0, 1fr); gap: 16px; padding: 11px 16px; border-top: 1px solid rgba(110, 140, 180, 0.16); }
  .fact:first-child { border-top: 0; }
  dt { font-size: var(--fs-body); font-weight: 600; color: #8d949c; }
  dd { font-size: var(--fs-body); line-height: 1.55; color: var(--lt-eceef0, #eceef0); }

  .steps { list-style: none; counter-reset: s; display: flex; flex-direction: column; gap: 9px; margin: 0; padding: 0; }
  .steps li { counter-increment: s; position: relative; padding: 12px 16px 12px 52px; border-radius: 12px; font-size: var(--fs-emph); line-height: 1.55; color: var(--lt-d6dade, #d6dade);
    background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72); border: 1px solid rgba(110, 140, 180, 0.2); }
  .steps li::before { content: counter(s); position: absolute; left: 14px; top: 11px; width: 26px; height: 26px; display: grid; place-items: center; border-radius: 50%;
    font-size: var(--fs-body); font-weight: 700; color: var(--on-accent, #fff); background: var(--accent-primary); }

  .bul { margin: 0; padding: 0 0 0 4px; list-style: none; display: flex; flex-direction: column; gap: 8px; }
  .bul li { position: relative; padding-left: 20px; font-size: var(--fs-emph); line-height: 1.6; color: var(--lt-d6dade, #d6dade); max-width: 82ch; }
  .bul li::before { content: ''; position: absolute; left: 4px; top: 10px; width: 6px; height: 6px; border-radius: 50%; background: var(--accent-primary);
    color: var(--on-accent, inherit);
}

  .tbl-wrap { overflow-x: auto; border-radius: 12px; border: 1px solid rgba(110, 140, 180, 0.22); }
  table { width: 100%; border-collapse: collapse; font-size: var(--fs-body); }
  th { text-align: left; padding: 10px 14px; font-weight: 600; color: #8d949c; background: rgba(0, 0, 0, 0.3); white-space: nowrap; }
  td { padding: 10px 14px; vertical-align: top; line-height: 1.5; color: var(--lt-d6dade, #d6dade); border-top: 1px solid rgba(110, 140, 180, 0.16); background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.6); }
  td.first { font-weight: 600; color: var(--lt-ffffff, #fff); white-space: nowrap; }

  .callout { display: flex; gap: 12px; align-items: flex-start; padding: 12px 16px; border-radius: 12px; font-size: var(--fs-body); line-height: 1.55; }
  .callout :global(svg) { flex: none; margin-top: 2px; }
  .callout.tip { color: var(--lt-bcd9f7, #bcd9f7); background: var(--c-hover); border: 1px solid var(--accent-primary); }
  .callout.warn { color: var(--lt-ffd98a, #ffd98a); background: var(--c-raised); border: 1px solid var(--c-line);
    border-left: 3px solid rgb(255, 200, 87);}

  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 10px; }
  .card { display: flex; flex-direction: column; gap: 6px; padding: 14px 16px; border-radius: 12px; text-align: left; color: inherit;
    background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72); border: 1px solid rgba(110, 140, 180, 0.22); transition: border-color 0.15s, background 0.15s; }
  button.card:hover { border-color: var(--accent-primary); background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.9); }
  .card.static { border-left: 3px solid var(--ac, #4f94e6); }
  .c-title { display: inline-flex; align-items: center; gap: 8px; font-size: var(--fs-emph); font-weight: 600; color: var(--lt-ffffff, #fff); }
  .c-text { font-size: var(--fs-body); line-height: 1.5; color: var(--lt-aeb5bd, #aeb5bd); }
  .c-go { margin-top: auto; display: inline-flex; align-items: center; gap: 5px; font-size: var(--fs-body); font-weight: 600; color: var(--lt-7bb6f2, #7bb6f2); }
  .c-go.muted { color: #8d949c; font-weight: 500; }

  /* the lists built from the code */
  .auto-tabs { display: flex; flex-direction: column; gap: 10px; }
  .at-group { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
  .at-title { flex: none; width: 190px; font-size: var(--fs-body); font-weight: 600; }
  .at-items { display: flex; flex-wrap: wrap; gap: 7px; }
  .chip { display: inline-flex; align-items: center; gap: 7px; height: 30px; padding: 0 12px; border-radius: 15px; font-size: var(--fs-body); color: var(--lt-d6dade, #d6dade);
    background: rgba(var(--ltc-16-21-30, 16, 21, 30), 0.72); border: 1px solid rgba(110, 140, 180, 0.22); }
  .chip :global(svg) { color: var(--lt-7bb6f2, #7bb6f2); }
  .chip.mono { font-family: var(--font-mono); font-size: var(--fs-small); }

  .pager { display: flex; justify-content: space-between; gap: 12px; margin-top: 10px; padding-top: 16px; border-top: 1px solid rgba(110, 140, 180, 0.22); }
  .pager .btn { display: inline-flex; align-items: center; gap: 8px; min-height: 40px; }

  @media (max-width: 1000px) {
    .guide { height: auto; }
    .doc-scroll { flex: none; overflow: visible; padding: 16px; }
    .doc-grid { grid-template-columns: minmax(0, 1fr); }
    .rail { display: none; }
    .fact { grid-template-columns: 1fr; gap: 2px; }
    .at-title { width: auto; }
  }
</style>
