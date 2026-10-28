// One colour per event type and per status for every admin table (Manage Events, Participants, Saved Routes, Event History),
// so a type or status reads the same everywhere. Solid fill, lettering black or white by contrast: no tint, no glow.
import { inkOn } from '../../util/avatar.js';

export const KIND_META = {
  CONVOY: { label: 'Convoy', color: '#ee8a2b' },
  HOT_CARGO: { label: 'Hot Cargo', color: '#e0489f' },
  GANG_AIRDROP: { label: 'Airdrop', color: '#9b7bff' },
  GANG_RACE: { label: 'Rally Race', color: '#22c7d6' },
  TDM: { label: 'TDM', color: '#e5484d' },
  CONTAINER_WARS: { label: 'Container Wars', color: '#52d24a' },
  GANG_TERRITORY: { label: 'Territory', color: '#c45ee0' },
  CRACKDOWN: { label: 'Crackdown', color: '#3b82f6' },
};
const ALIASES = { AIRDROP: 'GANG_AIRDROP', 'RALLY RACE': 'GANG_RACE', RALLY_RACE: 'GANG_RACE', 'HOT CARGO': 'HOT_CARGO', 'CONTAINER WARS': 'CONTAINER_WARS', TERRITORY: 'GANG_TERRITORY' };
export const kindMeta = (kind) => {
  const raw = String(kind || 'CONVOY').toUpperCase().trim();
  return KIND_META[ALIASES[raw] || raw] || KIND_META.CONVOY;
};

export const STATUS_COLOR = {
  DRAFT: '#c9b68a', SCHEDULED: '#5aa0ff', LIVE: '#2fd27a', UNDER_ATTACK: '#f2a93b',
  COMPLETED: '#3cc7e8', CAPTURED: '#b58cff', FAILED: '#ff8a3d', CANCELLED: '#ef4444',
};
const LIVE = ['STARTING', 'ACTIVE', 'CHECKPOINT', 'DELIVERY'];
export const statusColor = (status) => {
  const s = String(status || '').toUpperCase();
  return STATUS_COLOR[LIVE.includes(s) ? 'LIVE' : s] || '#7b8497';
};

export const solid = (c) => `background:${c}; border-color:${c}; color:${inkOn(c)};`;
export const kindTag = (kind, color) => solid(color || kindMeta(kind).color);
export const statusTag = (status) => solid(statusColor(status));
