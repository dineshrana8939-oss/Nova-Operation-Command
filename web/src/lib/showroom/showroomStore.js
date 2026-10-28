import { writable } from 'svelte/store';

// The vehicle showroom (client/modules/showroom.lua): the Race Token Exchange and the Police Escort Vehicle Shop.
// null = closed; otherwise the payload the game sent when it opened:
//   { shop: 'tokens' | 'escort', title, subtitle, pedName, wallet, checkedOut,
//     vehicles: [{ index, label, model, tokens, price, type, category, stats: [speed, accel, braking, handling], missing }] }
export const showroom = writable(null);

// where the ped's head is on screen (0..1 fractions), so the speech bubble can sit above it
export const showroomPed = writable(null);

export function handleShowroomMessage(data) {
  switch (data.action) {
    case 'showroom:open':
      showroomPed.set(null);
      showroom.set(data);
      break;
    case 'showroom:pedScreen':
      showroomPed.set({ x: data.x, y: data.y });
      break;
    case 'showroom:close':
      showroom.set(null);
      showroomPed.set(null);
      break;
    default:
      break;
  }
}
