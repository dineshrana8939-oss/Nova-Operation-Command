// The small Container Wars timer shown to everyone standing in the bidding zone.
//   cwTimer:frame { visible, title, label, seconds, sub, tone }   (sent a few times a second while visible)
import { writable } from 'svelte/store';

export const containerTimer = writable({ visible: false });

export function setContainerTimer(frame) {
  containerTimer.set(frame && frame.visible ? frame : { visible: false });
}
