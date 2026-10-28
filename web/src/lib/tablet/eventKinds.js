// The event types an admin can create (Create Event). One entry per kind; the description is the tooltip. Shared by the Create
// Event form and the User Guide, so a new event type shows up in both.
// Ordered by how deep the setup is and how wide the event reaches: the core Convoy first, then the lighter truck / loot variants, then the
// player-versus-player events (race, deathmatch), then the systems that reach the whole server (police crackdown, the harbour auction, territory
// ownership). Create Event, the User Guide and the pickers all follow this order.
export const KIND_TABS = [
  { id: 'CONVOY', title: 'Escort Convoy', full: 'Police Escort Convoy', desc: 'Cargo trucks, route & police escort vs gangs', icon: 'truck', accent: '#ee8a2b', adminOnly: false },
  { id: 'HOT_CARGO', title: 'Hot Cargo Run', full: 'Hot Cargo Run', desc: 'Stealth contraband runs, police pursuit & dropoff', icon: 'flame', accent: '#e0489f', adminOnly: true },
  { id: 'GANG_AIRDROP', title: 'Gang Airdrop', full: 'Gang Airdrop Event', desc: 'Supply drop zones, plane flyover, loot crates', icon: 'parachute', accent: '#9b7bff', adminOnly: true },
  { id: 'GANG_RACE', title: 'Rally Race', full: 'Gang Rally Race', desc: 'Street race, checkpoints, position tokens', icon: 'flag', accent: '#22c7d6', adminOnly: true },
  { id: 'TDM', title: 'TDM Match', full: 'TDM Match', desc: '2-gang deathmatch, or a tournament arena', icon: 'crosshair', accent: '#e5484d', adminOnly: true },
  { id: 'CRACKDOWN', title: 'Operation Crackdown', full: 'Operation Crackdown', desc: 'One gang vs the police on duty in a combat zone', icon: 'shield', accent: '#d6336c', adminOnly: true },
  { id: 'CONTAINER_WARS', title: 'Container Wars', full: 'Container Wars', desc: 'Harbour dock container yard auction', icon: 'box', accent: '#38bdf8', adminOnly: true },
  { id: 'GANG_TERRITORY', title: 'Territory Auction', full: 'Gang Territory Auction', desc: 'Auction map territories, XP expansion, rival wars', icon: 'pin', accent: '#c45ee0', adminOnly: true },
];
