import { writable } from 'svelte/store';

// Container Wars bidder window (the supplied "container_wars_bidder_ui.html").
// The Lua side (client/modules/container_wars.lua) drives it with:
//   bidder:open     { containerId, containerNumber, currentBid, minimumBid, increment, gang, canBid }
//   bidder:update   { currentBid, minimumBid, increment, canBid }   -- fields only, never re-mounts
//   bidder:rejected { message, + the fresh numbers }
//   bidder:accepted {}
//   bidder:close    {}
// Each *Seq counter bumps once per message so the component can react to the
// event itself (not just to a changed value).
export const bidder = writable({
  open: false,
  containerId: null,
  containerNumber: 1,
  currentBid: 0,
  minimumBid: 0,
  increment: 0,
  gang: '',
  lotName: '',
  eyebrow: 'Container Wars Auction',
  submitEvent: 'submitBid',
  closeEvent: 'closeBidder',
  canBid: true,
  message: '',
  openSeq: 0,
  updateSeq: 0,
  rejectSeq: 0,
  acceptSeq: 0,
});

const pick = (data) => {
  const out = {};
  for (const k of ['containerId', 'containerNumber', 'currentBid', 'minimumBid', 'increment', 'gang', 'canBid', 'lotName', 'eyebrow', 'submitEvent', 'closeEvent']) {
    if (data[k] !== undefined) out[k] = data[k];
  }
  return out;
};

export function handleBidderMessage(data) {
  bidder.update((s) => {
    switch (data.action) {
      case 'bidder:open':
        // every open resets the labels / callbacks, so Container Wars and the Territory Auction can share this one window
        return { ...s, lotName: '', eyebrow: 'Container Wars Auction', submitEvent: 'submitBid', closeEvent: 'closeBidder', ...pick(data), open: true, message: '', openSeq: s.openSeq + 1 };
      case 'bidder:update':
        return { ...s, ...pick(data), updateSeq: s.updateSeq + 1 };
      case 'bidder:rejected':
        return { ...s, ...pick(data), message: data.message || 'Bid rejected.', rejectSeq: s.rejectSeq + 1 };
      case 'bidder:accepted':
        return { ...s, acceptSeq: s.acceptSeq + 1 };
      case 'bidder:close':
        return { ...s, open: false };
      default:
        return s;
    }
  });
}
