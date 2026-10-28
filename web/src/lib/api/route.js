import { fetchNui } from './nui.js';

export const getPlayerPosition = () => fetchNui('getPlayerPosition', {});
export const previewRoute = (points, checkpoints, airdrops) => fetchNui('previewRoute', { points, checkpoints, airdrops });
export const clearRoutePreview = () => fetchNui('clearRoutePreview', {});
// Territory auction: draw the board at the chosen size where the projector stands (tablet steps aside for ~25 s)
export const previewProjectorScreen = (x, y, z, scale) => fetchNui('territory:previewScreen', { x, y, z, scale });
// Rival wars: draw the admin's war zone in the world for ~30 s (the tablet steps aside)
export const previewWarZone = (x, y, z, shape, size) => fetchNui('territory:previewWarZone', { x, y, z, shape, size });
export const teleportToPosition = (x, y, z, heading) => fetchNui('teleportToPosition', { x, y, z, heading });
export const getZoneName = (x, y, z) => fetchNui('getZoneName', { x, y, z });
export const getGroundZ = (x, y, z) => fetchNui('getGroundZ', { x, y, z });
// opts: { supportsAirdrop, target } — supportsAirdrop=false hides the [K]
// Airdrop Point hint and makes K behave like a plain checkpoint instead, for
// event kinds (Rally) that have no such thing as an airdrop point. `target`
// tags the session so only the builder that started it can consume the
// points (see App.svelte) — it is what keeps a Rally recording from being
// appended to a Convoy route, or a Hot Cargo zone recording from landing on
// a Rally stage list.
export const startRouteRecording = (opts) => fetchNui('startRouteRecording', opts || {});
// config: { primaryLabel, secondaryLabel? } — see zone_recorder.lua
// PolyZone-creator style perimeter drawing (left click = point, Enter = save). Resolves when it ends.
export const drawContainerWarsPerimeter = (opts) => fetchNui('drawContainerWarsPerimeter', opts || {});
// Hologram placer for the harbour yard's crane / container spots / drop spots. payload { kind: 'crane' | 'pickup' | 'drop', index, model, x, y, z, heading }.
// (The dummy container stacks use the shared Prop Placer, api/placer.js.)
// Resolves with { ok, x, y, z, heading } on confirm, { ok:false } on cancel.
export const startHarbourPlacer = (payload) => fetchNui('startHarbourPlacer', payload || {});
// "Plan route": the game scans the real yard round one container's spots and finds a clear lane for it.
// payload { index, liftHeight } -> { ok, points, violations, inflation, pick, drop } | { ok:false, error }
export const planCraneCarry = (payload) => fetchNui('planCraneCarry', payload || {});
export const checkModels = (models) => fetchNui('checkModels', { models });
export const startZoneRecording = (config) => fetchNui('startZoneRecording', config || {});

// Placing barricades / vehicles / dummy stacks / truck spots is done by the shared Prop Placer (api/placer.js).
// What stays here is only the in-world PREVIEW of a checkpoint's saved lists.
export const previewCheckpointBarricades = (props, cpKey) => fetchNui('previewCheckpointBarricades', { props, cpKey });
export const clearCheckpointBarricadesPreview = () => fetchNui('clearCheckpointBarricadesPreview', {});

// Decor vehicles (police/army cars placed for ambience) are a separate stashed list per checkpoint
// (cp.decorVehicles); their preview, like the barricades', is spawned by route_editor.lua.
export const previewCheckpointDecorVehicles = (vehicles, cpKey) => fetchNui('previewCheckpointDecorVehicles', { vehicles, cpKey });
export const clearCheckpointDecorVehiclesPreview = () => fetchNui('clearCheckpointDecorVehiclesPreview', {});

// Plays the hoist / carry / lower path locally (nothing saved or networked) to check a layout.
// payload: { model, pickup, drop, travelSeconds, liftHeight, stackCount, stackHeight, props, yard }
export const testContainerWarsCrane = (payload) => fetchNui('testContainerWarsCrane', payload);

// Plays the race track checkpoints and spawned props locally to check a layout.
// payload: { stages, props }
export const testRaceRoute = (payload) => fetchNui('testRaceRoute', payload);

// Draws the bidding perimeter in the world until the admin presses Enter / Backspace.
// spotCount (optional): also shows the spots where that many players would spawn inside the area.
export const previewContainerWarsZone = (points, fallbackZ, spotCount) =>
  fetchNui('previewContainerWarsZone', { points, fallbackZ, spotCount });

// Shows recorded spawn dots in the world, numbered, until the admin presses Enter / Backspace.
export const previewSpawnSpots = (spots) => fetchNui('previewSpawnSpots', { spots });

// Announcement preview: the tablet steps aside while the banner plays at the top of the screen, then returns.
export const tabletPreviewHide = () => fetchNui('tablet:previewHide', {});
export const tabletPreviewRestore = () => fetchNui('tablet:previewRestore', {});
