// Mirrors shared/convoy_types.lua — kept as plain arrays for <select> options.

export const CARGO_TYPES = ['WEAPONS', 'DRUGS', 'CASH', 'CONTRABAND', 'MILITARY', 'HIGH_VALUE', 'CUSTOM'];
// GANG_SCORE/CONVOY_POINTS/CUSTOM were removed from this picker — only
// MONEY and ITEMS are actually wired to a payout in reward_service.lua, the
// others silently paid out nothing (a console warning was all that happened).
// Base reward types for general events: MONEY and ITEMS.
// TOKENS (Race Tokens) is exclusively offered for Gang Rally race events.
export const REWARD_TYPES = ['MONEY', 'ITEMS', 'GANG_XP'];
export const RACE_REWARD_TYPES = ['MONEY', 'ITEMS', 'TOKENS', 'GANG_XP'];
export const DIFFICULTIES = ['EASY', 'MEDIUM', 'HARD', 'EXTREME'];

export const TRUCK_ROLES = ['PRIMARY_CARGO', 'SECONDARY_CARGO', 'ESCORT', 'DECOY'];
// Trimmed to the core set an admin actually needs when building a route.
// BREAK/AMBUSH/CUSTOM point types were dropped from the picker (their
// backend support is untouched) to cut down on how many point types an
// admin has to understand at once. POLICE_SPAWN and ARMY_SPAWN were merged
// into one NPC_SPAWN type — a checkpoint's police/army toggles decide what
// actually spawns there, so there was never a need for two separate point
// types just to mark "NPCs can appear around here."
// AIRDROP was removed entirely (not just trimmed from the picker, unlike
// BREAK/AMBUSH above) — the convoy's own route/checkpoint flow should never
// be touched by an airdrop; that concept now lives only in the standalone
// Gang Airdrop event kind (see AirdropZones.svelte).
export const ROUTE_POINT_TYPES = ['START', 'ROUTE', 'CHECKPOINT', 'NPC_SPAWN', 'DESTINATION'];
export const VEHICLE_CATEGORIES = ['CARGO', 'ESCORT', 'ARMY', 'CUSTOM'];

export const STATUS_LABELS = {
  DRAFT: 'Draft',
  SCHEDULED: 'Scheduled',
  STARTING: 'Starting',
  ACTIVE: 'Active',
  CHECKPOINT: 'At Checkpoint',
  UNDER_ATTACK: 'Under Attack',
  DELIVERY: 'Delivery',
  COMPLETED: 'Completed',
  CAPTURED: 'Captured',
  FAILED: 'Failed',
  CANCELLED: 'Cancelled',
};
