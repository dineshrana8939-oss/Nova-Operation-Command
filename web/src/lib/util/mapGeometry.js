// ─── Nova Convoy — Route Layout map constants ──────────────────────────────────
// Tile atlas bundled directly in this resource (web/public/atlas/{z}/{x}/{y}.jpg,
// zoom 0-5) — sourced from charming-byte/simple-livemap (MIT licensed), a
// pre-rendered, already-georeferenced GTA V map, not a single hand-calibrated
// screenshot. The 4 transform constants below are the SAME numbers used by
// simple-livemap's own CustomCRS AND independently by a second, unrelated
// MIT-licensed project (gta-v-map-leaflet's GTA_CRS_CONFIG) against this exact
// tile set — two independent projects landing on identical numbers is why
// these are trusted as-is rather than re-derived via an in-tablet calibration
// tool (which is what caused the accuracy problems the previous, single-image
// version of this file had).
export const ATLAS_TILE_URL = './atlas/{z}/{x}/{y}.jpg';
export const ATLAS_MIN_ZOOM = 0;
export const ATLAS_MAX_ZOOM = 5;
// The tiles stop at zoom 5 (about 1 m per pixel). The map itself may zoom in further, the last tile level just gets enlarged, so a
// point can be placed within a metre or two instead of "wherever the pixel falls".
export const ATLAS_VIEW_MAX_ZOOM = 8;
export const ATLAS_TILE_SIZE = 8192; // pixel width/height of the full atlas at ATLAS_MAX_ZOOM

const CENTER_X = 117.3;
const CENTER_Y = 172.8;
const SCALE_X = 0.02072;
const SCALE_Y = 0.0205;

// Leaflet's L.Transformation does exactly the per-axis scale+offset shape
// this calibration needs (no rotation/shear term, unlike the previous
// version of this file) — pass the already-imported `L` in since this file
// has no direct dependency on the leaflet package itself.
export function createAtlasCRS(L) {
  return L.extend({}, L.CRS.Simple, {
    transformation: new L.Transformation(SCALE_X, CENTER_X, -SCALE_Y, CENTER_Y),
  });
}

// BREAK/AMBUSH deliberately excluded — dropped from ROUTE_POINT_TYPES
// (constants.js) long ago, so no route point can ever actually be typed as
// either any more. POLICE_SPAWN/ARMY_SPAWN stay defined (not in the legend
// below, since they're not selectable either) purely so a convoy saved
// before the NPC_SPAWN merge still renders its old point colors correctly.
export const TYPE_COLOR_JS = {
  START: '#32d74b',
  ROUTE: '#3b82f6',
  // Was '#38bdf8' — a second, near-identical blue sitting right next to the
  // route line's own blue (ROUTE above, and the polyline itself — see
  // RoutePreviewMap.svelte), so a checkpoint marker was nearly invisible
  // against its own path. Yellow reads as its own thing at a glance.
  CHECKPOINT: '#eab308',
  // Was '#ffffff' — plain white, easy to lose against the light basemap tiles.
  AIRDROP: '#ef4444',
  DESTINATION: '#ff4d3d',
  NPC_SPAWN: '#676d75',
  POLICE_SPAWN: '#676d75',
  ARMY_SPAWN: '#676d75',
};

export const LEGEND = [
  { type: 'START', label: 'Start' },
  { type: 'ROUTE', label: 'Route' },
  { type: 'CHECKPOINT', label: 'Checkpoint' },
  { type: 'AIRDROP', label: 'Airdrop' },
  { type: 'DESTINATION', label: 'Destination' },
  { type: 'NPC_SPAWN', label: 'NPC Spawn' },
];

// ── Per-event legends ───────────────────────────────────────────────────────
// Each event kind draws a different set of vectors, so each one gets its own
// legend rather than sharing the convoy one (which would list Airdrops on a
// Rally screen, and Checkpoints on an Airdrop screen). Screens render the
// legend matching the event they're configuring.
export const EVENT_LEGENDS = {
  CONVOY: [
    { type: 'START', label: 'Start' },
    { type: 'ROUTE', label: 'Route' },
    { type: 'CHECKPOINT', label: 'Checkpoint' },
    { type: 'AIRDROP', label: 'Airdrop' },
    { type: 'DESTINATION', label: 'Destination' },
  ],
  GANG_RACE: [
    { type: 'START', label: 'Start' },
    { type: 'CHECKPOINT', label: 'Checkpoint' },
    { type: 'DESTINATION', label: 'Finish' },
  ],
  HOT_CARGO: [
    { type: 'ROUTE', label: 'Spawn Zone' },
    { type: 'START', label: 'Dropoff' },
  ],
  GANG_AIRDROP: [
    { type: 'AIRDROP', label: 'Drop Zone' },
  ],
};

