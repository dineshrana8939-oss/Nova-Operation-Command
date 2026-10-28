// Pure helpers for the Staff permission matrix. The server enforces the same rules; these keep the UI honest.
//
// A permission map is { 'section.action': true } (absent = false). A section is { id, label, group, hint, actions[] }
// and lists ONLY the actions that apply to it.
//
// Rules:
//  - turning ANY action on also turns Visible and View on (for the actions that exist on that section);
//  - turning Visible or View off turns EVERY action of that section off.

export const ACTIONS = ['visible', 'view', 'create', 'edit', 'delete', 'manage'];
export const ACTION_LABELS = { visible: 'Visible', view: 'View', create: 'Create', edit: 'Edit', delete: 'Delete', manage: 'Manage' };

const VV = ['visible', 'view'];
export const permKey = (section, action) => `${section.id}.${action}`;
const has = (section, action) => section.actions.includes(action);

// Sections grouped by their `group` heading, in the order the server sent them.
export function groupSections(sections) {
  const groups = [];
  const byName = new Map();
  for (const s of sections || []) {
    const name = s.group || '';
    if (!byName.has(name)) { const g = { group: name, items: [] }; byName.set(name, g); groups.push(g); }
    byName.get(name).items.push(s);
  }
  return groups;
}

// Up-closure: any action on => visible + view on. Used for role maps and for what gets saved.
export function normaliseMap(map, sections) {
  const out = {};
  for (const s of sections || []) {
    const acts = s.actions.filter((a) => !!map[permKey(s, a)]);
    const anyAction = acts.some((a) => !VV.includes(a));
    for (const a of s.actions) {
      if (map[permKey(s, a)] || (anyAction && VV.includes(a))) out[permKey(s, a)] = true;
    }
  }
  return out;
}

// ── Role mode ────────────────────────────────────────────────────────────────────────────────────────────────────
export function toggleRoleCell(map, section, action) {
  const next = { ...map };
  const k = permKey(section, action);
  if (!next[k]) {
    next[k] = true;
    for (const v of VV) if (has(section, v)) next[permKey(section, v)] = true;
  } else if (VV.includes(action)) {
    for (const a of section.actions) delete next[permKey(section, a)];
  } else {
    delete next[k];
  }
  return next;
}

export function sectionAllOn(map, section) {
  return section.actions.length > 0 && section.actions.every((a) => !!map[permKey(section, a)]);
}

export function toggleRoleRow(map, section) {
  const next = { ...map };
  const on = !sectionAllOn(map, section);
  for (const a of section.actions) {
    if (on) next[permKey(section, a)] = true;
    else delete next[permKey(section, a)];
  }
  return next;
}

// ── Override mode ────────────────────────────────────────────────────────────────────────────────────────────────
// overrides: { 'gangs.edit': true | false } — absent = inherit from the role.
export function cellState(overrides, key) {
  const v = overrides[key];
  return v === undefined ? 'inherit' : v ? 'on' : 'off';
}

// effective = (override ?? role), then normalised: an explicit OFF on Visible/View wins and clears the section; otherwise any
// action on pulls Visible + View on.
export function effectiveMap(base, overrides, sections) {
  const out = {};
  for (const s of sections || []) {
    const raw = {};
    for (const a of s.actions) {
      const k = permKey(s, a);
      raw[a] = overrides[k] !== undefined ? !!overrides[k] : !!base[k];
    }
    const vvOff = VV.some((v) => has(s, v) && overrides[permKey(s, v)] === false);
    if (vvOff) continue;
    const anyAction = s.actions.some((a) => !VV.includes(a) && raw[a]);
    for (const a of s.actions) {
      if (raw[a] || (anyAction && VV.includes(a))) out[permKey(s, a)] = true;
    }
  }
  return out;
}

// One click on a cell: inherit -> on -> off -> inherit, cascading like the role rules.
export function cycleOverride(base, overrides, sections, section, action) {
  const k = permKey(section, action);
  const eff = effectiveMap(base, overrides, sections);
  const next = { ...overrides };
  const merged = (key) => (next[key] !== undefined ? !!next[key] : !!base[key]);
  const state = cellState(overrides, k);

  if (state === 'inherit') {
    next[k] = true;
    const partners = VV.includes(action) ? VV.filter((v) => v !== action) : VV;
    for (const v of partners) {
      if (!has(section, v)) continue;
      const pk = permKey(section, v);
      if (merged(pk) !== true) next[pk] = true;
    }
  } else if (state === 'on') {
    next[k] = false;
    if (VV.includes(action)) {
      for (const a of section.actions) {
        const ak = permKey(section, a);
        if (ak === k) continue;
        if (VV.includes(a) || eff[ak]) next[ak] = false;
      }
    }
  } else {
    delete next[k];
  }
  return next;
}

// The row "all": if every applicable action is effectively on, force them all off, otherwise force them all on.
// Cells whose forced value equals the role's own value drop back to "inherit" so the override map stays minimal.
export function toggleOverrideRow(base, overrides, sections, section) {
  const eff = effectiveMap(base, overrides, sections);
  const target = !section.actions.every((a) => !!eff[permKey(section, a)]);
  const next = { ...overrides };
  for (const a of section.actions) {
    const k = permKey(section, a);
    if (!!base[k] === target) delete next[k];
    else next[k] = target;
  }
  return next;
}

export const sameMap = (a, b) => {
  const ka = Object.keys(a || {}).sort();
  const kb = Object.keys(b || {}).sort();
  return ka.length === kb.length && ka.every((k, i) => k === kb[i] && !!a[k] === !!b[k]);
};
