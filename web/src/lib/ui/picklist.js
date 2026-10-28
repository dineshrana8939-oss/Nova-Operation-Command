// ─── Nova Convoy — one dark dropdown for every <select> ──────────────────────────────────────────────────────────────
// The browser draws a <select>'s popup itself (white, tiny, unstyleable inside the game). Instead of rewriting every
// <select> in the UI, this intercepts them all: it swallows the click that would open the native popup, shows a dark,
// tablet-styled list instead (with a search box for long lists, e.g. 100+ gangs), and writes the pick back into the REAL
// <select> — selectedIndex plus 'input' and 'change' events — so Svelte's bind:value and on:change keep working untouched.
//
// Opt out per element with <select data-native>. <select multiple> and <select size="n"> are left alone.

const SEARCH_AFTER = 12;          // options before the search box appears
const MAX_HEIGHT = 320;           // px

let pop = null;                   // { sel, el, list, items, active, host, search, typed, typedAt }

const CSS = `
.nova-pl{position:fixed;z-index:2147483000;box-sizing:border-box;display:flex;flex-direction:column;padding:4px;
  background:#10141b;border:1px solid rgba(130,165,210,.34);border-radius:10px;box-shadow:0 14px 34px rgba(0,0,0,.6);
  font-family:var(--font-ui,inherit);font-size:14px;color:#eceef0;}
.nova-pl *{box-sizing:border-box}
.nova-pl-search{flex:none;height:34px;margin:2px 2px 6px;padding:0 10px;border-radius:7px;border:1px solid rgba(130,165,210,.24);
  background:rgba(255,255,255,.05);color:#eceef0;font:inherit;outline:none}
.nova-pl-search:focus{border-color:#4f94e6}
.nova-pl-search::placeholder{color:#8d949c}
.nova-pl-list{margin:0;padding:0;list-style:none;overflow-y:auto;overscroll-behavior:contain;flex:1;min-height:0;
  scrollbar-width:thin;scrollbar-color:rgba(130,165,210,.35) transparent}
.nova-pl-list::-webkit-scrollbar{width:8px}
.nova-pl-list::-webkit-scrollbar-thumb{background:rgba(130,165,210,.35);border-radius:4px}
.nova-pl-grp{padding:8px 10px 4px;font-size:12px;font-weight:600;color:#8d949c}
.nova-pl-opt{display:flex;align-items:center;justify-content:space-between;gap:10px;min-height:34px;padding:6px 10px;border-radius:7px;
  cursor:pointer;color:#c9ced4;line-height:1.25;user-select:none}
.nova-pl-opt.indent{padding-left:20px}
.nova-pl-opt.active{background:rgba(79,148,230,.18);color:#fff}
.nova-pl-opt.sel{color:#fff;font-weight:600}
.nova-pl-opt.off{opacity:.4;cursor:not-allowed}
.nova-pl-opt svg{flex:none;width:14px;height:14px;color:#4f94e6}
.nova-pl-empty{padding:12px 10px;color:#8d949c;font-size:13.5px}
`;
const CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';

function ensureStyle() {
  if (document.getElementById('nova-pl-style')) return;
  const s = document.createElement('style');
  s.id = 'nova-pl-style';
  s.textContent = CSS;
  document.head.appendChild(s);
}

const eligible = (sel) => sel instanceof HTMLSelectElement && !sel.multiple && !(sel.size > 1) && !sel.hasAttribute('data-native');

// the list's entries: groups (labels) and options, flattened in display order
function readEntries(sel) {
  const out = [];
  const addOpt = (o, indent) => out.push({ type: 'opt', o, label: (o.textContent || '').trim(), indent });
  for (const child of sel.children) {
    if (child.tagName === 'OPTGROUP') {
      out.push({ type: 'grp', label: child.label || '' });
      for (const o of child.children) if (o.tagName === 'OPTION') addOpt(o, true);
    } else if (child.tagName === 'OPTION') addOpt(child, false);
  }
  return out;
}

function close(refocus) {
  if (!pop) return;
  const { sel, el } = pop;
  el.remove();
  pop = null;
  document.removeEventListener('keydown', onKey, true);
  document.removeEventListener('mousedown', onOutside, true);
  window.removeEventListener('resize', onResize, true);
  window.removeEventListener('scroll', onScrollDismiss, true);
  window.removeEventListener('blur', onDismiss);
  if (refocus && sel.isConnected) sel.focus();
}

const onDismiss = () => close(false);
const onResize = () => { if (pop) place(); };          // the window changed size: keep the list under its field
function onScrollDismiss(e) { if (pop && !pop.el.contains(e.target)) close(false); }
function onOutside(e) { if (pop && !pop.el.contains(e.target) && !(pop.sel.contains && pop.sel === e.target)) close(false); }

function pick(entry) {
  if (!pop || entry.type !== 'opt' || entry.o.disabled) return;
  const { sel } = pop;
  const idx = [...sel.options].indexOf(entry.o);
  if (idx >= 0 && sel.selectedIndex !== idx) {
    sel.selectedIndex = idx;
    sel.dispatchEvent(new Event('input', { bubbles: true }));
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  }
  close(true);
}

function setActive(i, scroll = true) {
  if (!pop) return;
  const items = pop.items;
  if (!items.length) { pop.active = -1; return; }
  pop.active = Math.max(0, Math.min(items.length - 1, i));
  items.forEach((it, k) => it.el.classList.toggle('active', k === pop.active));
  if (scroll) items[pop.active].el.scrollIntoView({ block: 'nearest' });
}

// next enabled item from `from` going `dir` (+1 / -1), staying put at the ends
function step(from, dir) {
  const items = pop.items;
  let i = from;
  for (let n = 0; n < items.length; n++) {
    i += dir;
    if (i < 0 || i >= items.length) return from;
    if (!items[i].entry.o.disabled) return i;
  }
  return from;
}

function render(filter) {
  const { sel, list } = pop;
  const q = (filter || '').trim().toLowerCase();
  list.innerHTML = '';
  pop.items = [];
  let pendingGroup = null;
  for (const entry of pop.entries) {
    if (entry.type === 'grp') { pendingGroup = entry; continue; }
    if (q && !entry.label.toLowerCase().includes(q)) continue;
    if (pendingGroup) {
      const g = document.createElement('li');
      g.className = 'nova-pl-grp';
      g.textContent = pendingGroup.label;
      list.appendChild(g);
      pendingGroup = null;
    }
    const li = document.createElement('li');
    li.className = 'nova-pl-opt' + (entry.indent ? ' indent' : '') + (entry.o.disabled ? ' off' : '') + (entry.o.selected ? ' sel' : '');
    li.setAttribute('role', 'option');
    li.innerHTML = '<span></span>' + (entry.o.selected ? CHECK : '');
    li.firstChild.textContent = entry.label === '' ? ' ' : entry.label;
    li.addEventListener('mouseenter', () => { if (!entry.o.disabled) setActive(pop.items.findIndex((x) => x.el === li), false); });
    li.addEventListener('mousedown', (ev) => { ev.preventDefault(); ev.stopPropagation(); pick(entry); });
    list.appendChild(li);
    pop.items.push({ el: li, entry });
  }
  if (!pop.items.length) {
    const e = document.createElement('li');
    e.className = 'nova-pl-empty';
    e.textContent = 'No matches';
    list.appendChild(e);
  }
  const cur = pop.items.findIndex((x) => x.entry.o.selected);
  setActive(cur >= 0 ? cur : pop.items.findIndex((x) => !x.entry.o.disabled), true);
}

function place() {
  const { sel, el } = pop;
  const r = sel.getBoundingClientRect();
  const vh = window.innerHeight, vw = window.innerWidth;
  const hostRect = { left: 0, top: 0 };     // position:fixed is measured from the viewport (the host overlays are not transformed)
  el.style.minWidth = Math.max(r.width, 140) + 'px';
  el.style.maxWidth = Math.min(480, vw - 16) + 'px';
  el.style.maxHeight = MAX_HEIGHT + 'px';
  const below = vh - r.bottom - 10, above = r.top - 10;
  const up = below < 180 && above > below;
  const room = Math.max(120, Math.min(MAX_HEIGHT, up ? above : below));
  el.style.maxHeight = room + 'px';
  let left = Math.min(Math.max(8, r.left), vw - el.offsetWidth - 8);
  el.style.left = (left - hostRect.left) + 'px';
  if (up) { el.style.top = 'auto'; el.style.bottom = (hostRect.top + vh - r.top + 4) + 'px'; }
  else { el.style.bottom = 'auto'; el.style.top = (r.bottom + 4 - hostRect.top) + 'px'; }
}

function open(sel) {
  if (pop) { const same = pop.sel === sel; close(false); if (same) return; }
  if (sel.disabled) return;
  ensureStyle();
  const entries = readEntries(sel);
  if (!entries.some((e) => e.type === 'opt')) return;
  const optCount = entries.filter((e) => e.type === 'opt').length;
  const el = document.createElement('div');
  el.className = 'nova-pl';
  el.setAttribute('role', 'listbox');
  const list = document.createElement('ul');
  list.className = 'nova-pl-list';
  let search = null;
  if (optCount > SEARCH_AFTER) {
    search = document.createElement('input');
    search.type = 'text';
    search.className = 'nova-pl-search';
    search.placeholder = 'Search…';
    search.setAttribute('aria-label', 'Search the list');
    search.addEventListener('input', () => render(search.value));
    el.appendChild(search);
  }
  el.appendChild(list);
  // inside the same overlay root as the field, so it sits above the tablet / panel but outside their transformed frame
  const host = sel.closest('.backdrop') || document.body;
  host.appendChild(el);
  el.style.position = 'fixed';
  pop = { sel, el, list, items: [], entries, active: -1, host, search, typed: '', typedAt: 0 };
  render('');
  place();
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('mousedown', onOutside, true);
  window.addEventListener('resize', onResize, true);
  window.addEventListener('scroll', onScrollDismiss, true);
  window.addEventListener('blur', onDismiss);
  if (search) search.focus();
}

function onKey(e) {
  if (!pop) return;
  const k = e.key;
  const swallow = () => { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); };
  if (k === 'Escape') { swallow(); close(true); return; }                       // never closes the tablet behind it
  if (k === 'ArrowDown') { swallow(); setActive(step(pop.active, 1)); return; }
  if (k === 'ArrowUp') { swallow(); setActive(step(pop.active, -1)); return; }
  if (k === 'Home') { swallow(); setActive(step(-1, 1)); return; }
  if (k === 'End') { swallow(); setActive(step(pop.items.length, -1)); return; }
  if (k === 'Enter' || (k === ' ' && !pop.search)) {
    swallow();
    if (pop.active >= 0 && pop.items[pop.active]) pick(pop.items[pop.active].entry);
    return;
  }
  if (k === 'Tab') { close(false); return; }
  // short lists have no search box: typing jumps to the first label that starts with what was typed
  if (!pop.search && k.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
    swallow();
    const now = Date.now();
    pop.typed = (now - pop.typedAt > 700 ? '' : pop.typed) + k.toLowerCase();
    pop.typedAt = now;
    const i = pop.items.findIndex((x) => !x.entry.o.disabled && x.entry.label.toLowerCase().startsWith(pop.typed));
    if (i >= 0) setActive(i);
  }
}

// a click on a <select> opens ours instead of the browser's
document.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  const sel = e.target && e.target.closest ? e.target.closest('select') : null;
  if (!sel || !eligible(sel)) return;
  e.preventDefault();                 // this is what stops the native popup
  if (sel.disabled) return;
  sel.focus();
  open(sel);
}, true);

// …and so does the keyboard (Space / Enter / Alt+Down on a focused <select>)
document.addEventListener('keydown', (e) => {
  if (pop) return;
  const sel = document.activeElement;
  if (!sel || sel.tagName !== 'SELECT' || !eligible(sel) || sel.disabled) return;
  if (e.key === ' ' || e.key === 'Enter' || (e.altKey && e.key === 'ArrowDown')) {
    e.preventDefault();
    open(sel);
  }
}, true);
