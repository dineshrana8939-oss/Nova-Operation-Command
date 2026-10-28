import { fetchNui } from './nui.js';

// ── The shared Prop Placer (client/modules/prop_placer.lua) ───────────────────
// Every "Place" button of every event goes through openPropPlacer. The tablet steps aside, the placer window
// takes over, and the promise resolves when the session ends:
//   { ok: true, objects: [ { model, kind, x, y, z, heading, rx?, ry?, stack?, step?, collision?, uid, exact } ] }
//   { ok: false, cancelled: true }  /  { ok: false, error: 'busy' | 'placer_error' }
//
// opts: {
//   context        'convoy' | 'event' | 'hotcargo' | 'tdm' | 'airdrop' | 'rally' | 'container_wars'
//                  | 'container_yard' | 'hotcargo_truck' | 'generic'   (Config.PropPlacer.contexts)
//   title          shown in the window
//   objects        the objects that already exist (the saved list)
//   focus          { x, y, z } where the camera starts (a checkpoint, a spawn zone, ...)
//   startCategory  asset filter to start on
//   selectIndex    1-based index of an object to open on
//   companion      { model, back }  a trailer that follows the (single) object
//   autoCreate     { model }        create one object under the camera when there are none
// }
export const openPropPlacer = (opts) => fetchNui('placer:open', opts || {});

// "Preview In-World": spawns a saved layout locally so it can be seen where it will stand.
export const previewPlacedProps = (objects) => fetchNui('placer:preview', { objects });
export const clearPlacedPreview = () => fetchNui('placer:clearPreview', {});
// how many preview objects are standing right now (the preview outlives the tablet, so the toggle re-syncs on open)
export const placedPreviewStatus = () => fetchNui('placer:previewStatus', {});

// window → client messages
export const placerCmd = (t, data = {}) => fetchNui('placer:cmd', { t, ...data });
export const placerPointer = (data) => fetchNui('placer:pointer', data);
export const placerFly = (data) => fetchNui('placer:fly', data);
export const placerLook = (data) => fetchNui('placer:look', data);
