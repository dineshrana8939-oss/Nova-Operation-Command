// Store for the Container Wars civilian information panel
import { writable } from 'svelte/store';

export const containerCivilianInfo = writable({ visible: false });

export function setCivilianInfo(frame) {
  containerCivilianInfo.set(frame && frame.visible ? frame : { visible: false });
}
