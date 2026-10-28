import { writable } from 'svelte/store';

// What the placer window shows. The client (prop_placer.lua) owns the layout and sends it down; the window
// only draws it and sends commands back.
export const placer = writable({ open: false, session: null, state: null, cursor: null, notice: null });

export function handlePlacerMessage(d) {
  switch (d.action) {
    case 'placer:open':
      placer.set({ open: true, session: d.session, state: d.state, cursor: null, notice: null });
      break;
    case 'placer:state':
      placer.update((p) => (p.open ? { ...p, state: d } : p));
      break;
    case 'placer:patch':
      placer.update((p) => {
        if (!p.open || !p.state) return p;
        const byId = new Map((d.objects || []).map((o) => [o.id, o]));
        return { ...p, state: { ...p.state, objects: p.state.objects.map((o) => byId.get(o.id) || o) } };
      });
      break;
    case 'placer:cursor':
      placer.update((p) => (p.open ? { ...p, cursor: { x: d.x, y: d.y, z: d.z } } : p));
      break;
    case 'placer:notice':
      placer.update((p) => (p.open ? { ...p, notice: { text: d.text, kind: d.kind || 'info', t: Date.now() } } : p));
      break;
    case 'placer:asset':
      placer.update((p) => (p.open && p.session ? { ...p, session: { ...p.session, assets: [...p.session.assets, d.asset] } } : p));
      break;
    case 'placer:close':
      placer.set({ open: false, session: null, state: null, cursor: null, notice: null });
      break;
  }
}
