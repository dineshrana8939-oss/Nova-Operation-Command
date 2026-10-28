import { writable } from 'svelte/store';

// Container Wars 3D floating info tags above won reward vehicles.
// Lua client sends:
// [{ id, entityNetId, x, y, scale, dist, model, modelLabel, bidderName, winnerGang, winnerGangLabel, finalPrice, canClaim }]
export const vehicleRewardInfos = writable([]);

export function setVehicleRewardInfos(list) {
  vehicleRewardInfos.set(Array.isArray(list) ? list : []);
}
