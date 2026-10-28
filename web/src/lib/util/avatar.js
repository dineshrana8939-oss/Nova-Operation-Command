// Deterministic avatar color/initials — shared by GangLogo (gang identity
// fallback) and any per-player avatar (member rows). Same string always
// hashes to the same color, so a gang/player keeps a stable "identity" color
// without needing to store one explicitly.
const AVATAR_COLORS = ['#0a84ff', '#8b5cf6', '#30d158', '#14b8a6', '#64d2ff', '#ff375f', '#9aa7b8'];

export function avatarColor(name) {
  let hash = 0;
  for (let i = 0; i < (name || '').length; i++) hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
  return AVATAR_COLORS[hash % AVATAR_COLORS.length];
}

// black or white lettering, whichever reads on this background colour (a yellow gang badge with white letters was 1.7:1)
export function inkOn(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim());
  if (!m) return '#ffffff';
  const n = parseInt(m[1], 16);
  const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
  const L = 0.2126 * f((n >> 16) & 255) + 0.7152 * f((n >> 8) & 255) + 0.0722 * f(n & 255);
  // whichever of white / near-black has the higher contrast ratio on this colour
  return (L + 0.05) / (0.0056 + 0.05) > 1.05 / (L + 0.05) ? '#111111' : '#ffffff';
}

export function initials(name) {
  if (!name) return '?';
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] || '') + (parts[1]?.[0] || '')).toUpperCase() || name[0].toUpperCase();
}
