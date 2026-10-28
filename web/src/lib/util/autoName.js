// Auto-numbered names ("Spawn Zone 03", "Checkpoint 4", "Container #2") follow the item's CURRENT position, so
// deleting, adding, inserting or reordering never leaves gaps or duplicates. Only names that still look auto-generated
// ("<prefix><number>") are touched — a name someone typed ("North Gate") is never renamed.
//
//   list    the array to renumber
//   prefix  the fixed text before the number, exactly as generated ('Spawn Zone ', 'Container #')
//   opts.pad     zero-pad the number to this many digits (0 = none)
//   opts.fields  name fields to keep in step (the first one decides whether the item counts as auto-named)
//   opts.rankOf  (item, index, list) => the 1-based number, or null to leave this item alone
//                (default: index + 1) — for lists whose numbering follows another order than the array's
//
// Returns the SAME array when nothing changed, so `$: { const n = renumberAuto(...); if (n !== list) list = n; }` settles
// after one pass instead of looping.
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function renumberAuto(list, prefix, opts = {}) {
  if (!Array.isArray(list) || list.length === 0) return list;
  const { pad = 0, fields = ['name'], rankOf = null } = opts;
  const auto = new RegExp(`^${escapeRe(prefix)}\\d+$`, 'i');
  let changed = false;
  const next = list.map((item, i) => {
    if (!item || typeof item !== 'object') return item;
    if (!auto.test(String(item[fields[0]] ?? '').trim())) return item;
    const rank = rankOf ? rankOf(item, i, list) : i + 1;
    if (rank == null) return item;
    const wanted = `${prefix}${String(rank).padStart(pad, '0')}`;
    const patch = {};
    for (const f of fields) {
      if (item[f] !== undefined && item[f] !== wanted) patch[f] = wanted;
    }
    if (Object.keys(patch).length === 0) return item;
    changed = true;
    return { ...item, ...patch };
  });
  return changed ? next : list;
}

// Re-points 1-based index references (e.g. a container spot's "assigned drop #3") after the entry at `removed`
// (1-based) is deleted: a reference to the deleted entry is cleared (back to automatic), later ones shift down by one.
export function reindexAfterRemoval(list, key, removed) {
  return (list || []).map((item) => {
    const ref = Number(item?.[key]);
    if (!ref) return { ...item };
    if (ref === removed) {
      const { [key]: _cleared, ...rest } = item;
      return rest;
    }
    return ref > removed ? { ...item, [key]: ref - 1 } : { ...item };
  });
}
