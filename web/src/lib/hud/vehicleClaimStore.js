// The car-only lot claim bar at the top of the screen (see client/modules/container_wars.lua, "cwVehicleClaim:state").
//   { active, remaining (s), total (s), winner, winnerGang, container, lot, vehicle, price, plate, mine }
// The server owns the clock; the client only counts down between its updates.
import { writable } from 'svelte/store';

export const vehicleClaimBar = writable(null);

export function setVehicleClaim(frame) {
  vehicleClaimBar.set(frame && frame.active ? frame : null);
}
