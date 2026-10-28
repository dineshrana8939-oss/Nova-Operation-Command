import { countSpans } from './territoryGeometry.js';

// Turns territory data into what TerritoryMap draws. Two sources:
//   · server views (persistent state: owner, expansion level, painted shapes)  → viewToRender
//   · the event form's areas (what the admin is configuring)                    → areaToRender
// A territory is drawn in its OWNER's colour and with the owner's gang image once someone owns it (so the picture changes the
// moment ownership does), and in its own colour / image before that.

export function gangIndex(gangs) {
  const map = {};
  for (const g of gangs || []) map[g.name] = g;
  return map;
}

export function viewToRender(v, gangs, opts = {}) {
  const g = gangIndex(gangs)[v.owner] || {};
  const gangName = v.ownerLabel || g.label || '';
  const layers = [{ key: 'base', label: 'Base', spans: v.geo?.base || [], unlocked: true, level: 0, xpCost: 0 }];
  for (const ex of v.geo?.expansions || []) {
    layers.push({ key: `exp${ex.level}`, label: gangName ? `${gangName} Area` : (ex.name || 'Territory Area'), spans: ex.spans || [], unlocked: !!ex.unlocked, level: ex.level, xpCost: ex.xpCost || 0 });
  }
  // land painted in the Map Zone editor (drawn like the base: it is part of the territory now)
  if ((v.geo?.custom || []).length) layers.push({ key: 'custom', label: gangName ? `${gangName} Territory` : 'Territory Land', spans: v.geo.custom, unlocked: true, level: 0, xpCost: 0 });
  // while the editor is open on this territory, `opts.edit` swaps in the working layer (gang: the painted layer, admin: the whole shape)
  if (opts.edit && opts.edit.id === v.id) {
    if (opts.edit.mode === 'admin') {
      layers.length = 0;
      layers.push({ key: 'edit', label: 'Territory shape', spans: opts.edit.spans, unlocked: true, level: 0, xpCost: 0 });
    } else {
      const keep = layers.filter((l) => l.key !== 'custom');
      layers.length = 0;
      layers.push(...keep, { key: 'edit', label: gangName ? `${gangName} Expansion` : 'New territory land', spans: opts.edit.spans, unlocked: true, level: 0, xpCost: 0 });
    }
  }
  const status = v.busy ? 'AT WAR' : (opts.auctionTerritoryId === v.id ? 'AUCTION' : '');
  return {
    id: v.id, name: v.name, color: (v.owner && (v.ownerAccent || g.color)) || v.color || '#e5484d',   // ownerAccent comes with every live update; the gang list was fetched once
    ownerLabel: gangName, logo: v.ownerLogo || g.logo || null, image: v.image || '',
    imagePos: v.imagePos || null, showName: v.showName !== false, cs: v.geo?.cs || 25, status, layers,
    location: v.location || null, center: v.center || null, ped: v.capture?.ped || v.ped || null,
    blip: v.blip || null, spriteType: v.spriteType || 'GTA_SPRITE', customLogo: v.customLogo || '',
  };
}

export function areaToRender(a, gangs) {
  const g = gangIndex(gangs)[a.startingOwner] || {};
  const gangName = a.ownerLabel || g.label || '';
  const layers = [{ key: 'base', label: 'Base', spans: a.base?.spans || [], unlocked: true, level: 0, xpCost: 0 }];
  (a.expansions || []).forEach((ex, i) => {
    layers.push({ key: `exp${i + 1}`, label: gangName ? `${gangName} Area` : (ex.name || 'Territory Area'), spans: ex.spans || [], unlocked: true, level: i + 1, xpCost: ex.xpCost || 0 });
  });
  return {
    id: a.id, name: a.name || a.id, color: a.color || '#e5484d', ownerLabel: g.label || '', logo: g.logo || null,
    image: a.image || '', imagePos: a.imagePos || null, showName: a.showName !== false, cs: a.base?.cs || 25, status: '', layers,
    location: a.location || null, center: a.center || null, ped: a.capture?.ped || a.ped || null,
    blip: a.blip || null, spriteType: a.spriteType || 'GTA_SPRITE', customLogo: a.customLogo || '',
  };
}

export const layerKeyOf = (level) => (level ? `exp${level}` : 'base');
export const money = (n) => `$${Number(n || 0).toLocaleString('en-US')}`;
export const fmtXp = (n) => `${Number(n || 0).toLocaleString('en-US')} XP`;

// "Ready to publish?" for a Gang Territory Auction form — used by the Review tab and the Start button's gate.
export function territoryReadiness(form) {
  const t = form.territory || {};
  const a = t.auction || {};
  const areas = t.areas || [];
  const auctioned = areas.filter((x) => x.auctioned !== false);
  const ids = areas.map((x) => x.id);
  const hasLocation = !!((a.location && a.location.x != null) || (a.zone?.points && a.zone.points.length >= 3) || (a.zonePoints && a.zonePoints.length >= 3));
  const hasSchedule = !!((form.recurrence && form.recurrence.enabled) || form.scheduledStartTime || (a.date && a.startTime) || form.scheduledAt);

  const missingPed = areas.filter((x) => !(x.capture?.ped?.x != null || (x.location && x.location.x != null))).map((x) => x.name || x.id);

  return [
    { label: 'Event name is at least 3 characters', ok: (form.name || '').trim().length >= 3 },
    { label: `At least one territory defined (${areas.length})`, ok: areas.length > 0 },
    { label: 'Every territory has a unique ID and a name', ok: areas.every((x) => x.id && x.name) && new Set(ids).size === ids.length },
    {
      label: missingPed.length > 0
        ? `Leader Ped vector position configured (missing: ${missingPed.slice(0, 2).join(', ')}${missingPed.length > 2 ? '…' : ''})`
        : 'Every territory has a Leader Ped vector position configured',
      ok: areas.length > 0 && missingPed.length === 0,
    },
    {
      label: 'Every territory has a Leader Ped NPC model assigned',
      ok: areas.every((x) => !!(x.capture?.ped?.model)),
    },
    { label: `At least one territory is put up for auction (${auctioned.length})`, ok: auctioned.length > 0 },
    { label: 'Every starting bid is above $0', ok: auctioned.every((x) => Number(x.startingBid) > 0) },
    { label: 'Auction perimeter or location set (where gang members stand to bid)', ok: hasLocation },
    { label: 'Auction schedule or recurrence rule configured', ok: hasSchedule },
    { label: 'Projector placed (optional — visual anchor in the world)', ok: true },
  ];
}