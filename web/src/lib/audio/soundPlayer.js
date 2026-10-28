// ─── Nova Convoy — notification sounds ────────────────────────────────────────────────────────────
// The client script (client/modules/sound.lua) sends { action: 'playSound', file, volume }.
// `file` is a file name from the resource's sounds/ folder (picked by Config.Sounds); volume is 0..1.

const cache = new Map();

function resourceName() {
  return typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'nova_convoytruck';
}

export function handlePlaySound(data) {
  const file = data && data.file;
  if (typeof file !== 'string' || /[\\/]/.test(file)) return;
  try {
    let base = cache.get(file);
    if (!base) {
      base = new Audio(`nui://${resourceName()}/sounds/${encodeURIComponent(file)}`);
      base.preload = 'auto';
      cache.set(file, base);
    }
    // a clone so two quick notifications overlap instead of cutting each other off
    const a = base.cloneNode();
    a.volume = Math.max(0, Math.min(1, Number(data.volume) || 0));
    a.play().catch(() => {});
  } catch (e) {
    /* audio is never worth breaking the UI over */
  }
}
