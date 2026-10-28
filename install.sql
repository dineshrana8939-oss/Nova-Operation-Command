-- ─── Nova Convoy — Standalone Schema ───────────────────────────────────────────
-- Mirrors what server/modules/db.lua's DB.init() creates programmatically on
-- resource start. Safe to run manually in HeidiSQL (or any MySQL client)
-- against the qbox database before first boot, or to inspect/recreate the
-- schema without starting the resource. Uses CREATE TABLE IF NOT EXISTS, so
-- re-running this file against an already-initialized database is a no-op.
-- NOTE: this file only covers a FRESH install (every column already included
-- in its CREATE TABLE). DB.init() itself also idempotently ALTERs an older,
-- already-running database forward (see its ensureColumn/ensureGangColumn
-- helpers) — that migration path only runs from the resource booting, not
-- from this file, so an existing database missing a newer column still needs
-- the resource to start at least once against it.

CREATE TABLE IF NOT EXISTS `nova_convoy_definitions` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(100) NOT NULL,
    `short_description` VARCHAR(255) DEFAULT NULL,
    `detailed_description` TEXT DEFAULT NULL,
    `cargo_type` VARCHAR(50) DEFAULT NULL,
    `cargo_description` VARCHAR(255) DEFAULT NULL,
    `reward_type` VARCHAR(50) DEFAULT NULL,
    `reward_amount` INT DEFAULT 0,
    `reward_pool` VARCHAR(255) DEFAULT NULL,
    `reward_extra` JSON DEFAULT NULL,
    `difficulty` VARCHAR(20) DEFAULT 'MEDIUM',
    `event_duration` INT DEFAULT 1200,
    `max_gang_participants` INT DEFAULT 20,
    `max_police_participants` INT DEFAULT 20,
    `status` VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    -- 'CONVOY' (default) or 'GANG_AIRDROP' — a standalone, gang-only airdrop
    -- event with no trucks/route/checkpoints at all. Admin-only to create,
    -- and hidden from anyone with the police job everywhere the tablet/live
    -- panel/history surface convoys.
    `kind` VARCHAR(20) NOT NULL DEFAULT 'CONVOY',
    `settings` JSON DEFAULT NULL,
    `trucks` JSON DEFAULT NULL,
    `route` JSON DEFAULT NULL,
    `checkpoints` JSON DEFAULT NULL,
    `airdrops` JSON DEFAULT NULL,
    -- Standalone drop zones for a GANG_AIRDROP-kind convoy — meaningless/
    -- unused for an ordinary CONVOY, which uses `airdrops` above instead.
    `airdrop_zones` JSON DEFAULT NULL,
    `roster` JSON DEFAULT NULL,
    -- Individual police pre-registration for an upcoming (draft/scheduled)
    -- convoy — a flat list of identifiers, the police-side equivalent of the
    -- gang leader's `roster` above (police have no leader hierarchy, so any
    -- officer registers themselves directly).
    `police_roster` JSON DEFAULT NULL,
    -- Recurring auto-start rule ({enabled, type: WEEKLY/MONTHLY, dayOfWeek,
    -- dayOfMonth, hour, minute}) — see Scheduler.rearm in scheduler.lua.
    `recurrence` JSON DEFAULT NULL,
    `breaks` JSON DEFAULT NULL,
    `ambushes` JSON DEFAULT NULL,
    `scheduled_at` BIGINT DEFAULT NULL,
    `start_ped` JSON DEFAULT NULL,
    `created_by` VARCHAR(64) DEFAULT NULL,
    `created_by_name` VARCHAR(100) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `nova_convoy_history` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `convoy_definition_id` INT DEFAULT NULL,
    `name` VARCHAR(100) DEFAULT NULL,
    `created_by` VARCHAR(64) DEFAULT NULL,
    `started_at` DATETIME DEFAULT NULL,
    `ended_at` DATETIME DEFAULT NULL,
    `duration` INT DEFAULT 0,
    `truck_count` INT DEFAULT 0,
    `police_participants` INT DEFAULT 0,
    `gang_participants` INT DEFAULT 0,
    `winning_gang` VARCHAR(100) DEFAULT NULL,
    `outcome` VARCHAR(20) DEFAULT NULL,
    `reward_summary` VARCHAR(255) DEFAULT NULL,
    `destroyed_trucks` INT DEFAULT 0,
    `checkpoints_completed` INT DEFAULT 0,
    `kind` VARCHAR(20) NOT NULL DEFAULT 'CONVOY',
    PRIMARY KEY (`id`)
);

-- Per-event audit log for a convoy run — specifically for "who actually
-- earned this" moments (a truck/airdrop genuinely cracked open with a
-- lockpick, a convoy captured) that a reward-fairness dispute needs a real
-- record of, not just the summary row above.
CREATE TABLE IF NOT EXISTS `nova_convoy_events` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `convoy_definition_id` INT DEFAULT NULL,
    `event_type` VARCHAR(30) NOT NULL,
    `gang_name` VARCHAR(50) DEFAULT NULL,
    `gang_label` VARCHAR(100) DEFAULT NULL,
    `player_identifier` VARCHAR(64) DEFAULT NULL,
    `player_name` VARCHAR(100) DEFAULT NULL,
    `detail` VARCHAR(255) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `nova_convoy_events_definition` (`convoy_definition_id`)
);

CREATE TABLE IF NOT EXISTS `nova_gangs` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(50) NOT NULL,
    `label` VARCHAR(100) NOT NULL,
    `leader_identifier` VARCHAR(64) DEFAULT NULL,
    `max_members` INT DEFAULT 20,
    `can_participate` TINYINT(1) DEFAULT 1,
    `convoys_joined` INT DEFAULT 0,
    `convoys_captured` INT DEFAULT 0,
    `convoys_failed` INT DEFAULT 0,
    `logo` MEDIUMTEXT DEFAULT NULL,
    `accent_color` VARCHAR(20) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `nova_gangs_name` (`name`)
);

CREATE TABLE IF NOT EXISTS `nova_gang_members` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `gang_id` INT NOT NULL,
    `identifier` VARCHAR(64) NOT NULL,
    `name` VARCHAR(100) DEFAULT NULL,
    `rank` VARCHAR(50) DEFAULT 'Member',
    `joined_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `nova_gang_members_unique` (`gang_id`, `identifier`),
    CONSTRAINT `nova_gang_members_gang_fk` FOREIGN KEY (`gang_id`) REFERENCES `nova_gangs` (`id`) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS `nova_vehicle_catalog` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `model` VARCHAR(50) NOT NULL,
    `label` VARCHAR(100) NOT NULL,
    `category` VARCHAR(30) NOT NULL DEFAULT 'CARGO',
    `image_url` VARCHAR(500) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `nova_vehicle_catalog_model` (`model`)
);

CREATE TABLE IF NOT EXISTS `nova_npc_spawn_zones` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `label` VARCHAR(100) NOT NULL,
    `type` VARCHAR(20) NOT NULL DEFAULT 'POLICE',
    `x` FLOAT NOT NULL,
    `y` FLOAT NOT NULL,
    `z` FLOAT NOT NULL,
    `radius` FLOAT NOT NULL DEFAULT 25.0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

CREATE TABLE IF NOT EXISTS `nova_convoy_runtime` (
    `convoy_id` INT NOT NULL,
    `status` VARCHAR(20) NOT NULL,
    `state` JSON NOT NULL,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`convoy_id`)
);

-- Single-row table: where the police equipment vendor ped (the tactical
-- throwables shop, NOT a convoy checkpoint NPC) currently stands.
-- Admin-settable live from the tablet instead of a fixed config.lua spot.
CREATE TABLE IF NOT EXISTS `nova_equipment_vendor` (
    `id` INT NOT NULL DEFAULT 1,
    `x` FLOAT NOT NULL,
    `y` FLOAT NOT NULL,
    `z` FLOAT NOT NULL,
    `heading` FLOAT NOT NULL DEFAULT 0,
    `enabled` TINYINT(1) NOT NULL DEFAULT 1,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

-- Single-row table: where the escort vehicle shop ped currently stands —
-- same admin-movable/toggleable-live pattern as the equipment vendor above.
CREATE TABLE IF NOT EXISTS `nova_escort_shop` (
    `id` INT NOT NULL DEFAULT 1,
    `x` FLOAT NOT NULL,
    `y` FLOAT NOT NULL,
    `z` FLOAT NOT NULL,
    `heading` FLOAT NOT NULL DEFAULT 0,
    `enabled` TINYINT(1) NOT NULL DEFAULT 1,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

-- Single-row table: the scheduler's UTC offset / poll interval, admin-
-- settable live from the tablet (Settings tab) instead of fixed config.lua
-- values requiring a restart. Config.ScheduleUtcOffsetHours /
-- Config.SchedulePollIntervalSeconds only seed this row on first boot.
CREATE TABLE IF NOT EXISTS `nova_schedule_settings` (
    `id` INT NOT NULL DEFAULT 1,
    `utc_offset_hours` FLOAT NOT NULL DEFAULT 0,
    `poll_interval_seconds` INT NOT NULL DEFAULT 15,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);
INSERT INTO `nova_schedule_settings` (`id`, `utc_offset_hours`, `poll_interval_seconds`)
SELECT 1, 0, 15
WHERE NOT EXISTS (SELECT 1 FROM `nova_schedule_settings`);

-- Reusable saved templates (Saved Routes tab / each event's own "Saved
-- Templates" picker) — a layout built once (CONVOY's route/checkpoints/
-- airdrops, HOT_CARGO's spawn+dropoff zones, or GANG_AIRDROP's drop zones)
-- can be saved here under a unique name and imported into any other event
-- of the SAME kind afterward. `kind` decides which columns actually mean
-- anything for a given row.
CREATE TABLE IF NOT EXISTS `nova_saved_routes` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(100) NOT NULL,
    `kind` VARCHAR(20) NOT NULL DEFAULT 'CONVOY',
    `route` JSON DEFAULT NULL,
    `checkpoints` JSON DEFAULT NULL,
    `airdrops` JSON DEFAULT NULL,
    `spawn_zones` JSON DEFAULT NULL,
    `dropoff_zones` JSON DEFAULT NULL,
    `airdrop_zones` JSON DEFAULT NULL,
    `created_by` VARCHAR(100) DEFAULT NULL,
    `created_by_name` VARCHAR(100) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

-- Seed vehicle catalog (DB.init() only inserts these when the table is empty).
INSERT INTO `nova_vehicle_catalog` (`model`, `label`, `category`)
SELECT * FROM (SELECT
    'packer' AS model, 'Packer (Cargo Truck)' AS label, 'CARGO' AS category UNION ALL SELECT
    'benson', 'Benson (Cargo Truck)', 'CARGO' UNION ALL SELECT
    'hauler', 'Hauler (Semi Truck)', 'CARGO' UNION ALL SELECT
    'pounder', 'Pounder (Box Truck)', 'CARGO' UNION ALL SELECT
    'riot2', 'Riot Van (Police Escort)', 'ESCORT' UNION ALL SELECT
    'police3', 'Police Cruiser (Escort)', 'ESCORT' UNION ALL SELECT
    'barracks', 'Barracks (Army Transport)', 'ARMY' UNION ALL SELECT
    'insurgent', 'Insurgent (Army Escort)', 'ARMY'
) AS seed
WHERE NOT EXISTS (SELECT 1 FROM `nova_vehicle_catalog`);

-- nova_equipment_vendor / nova_escort_shop are NOT seeded here (unlike
-- DB.init(), which inserts their single row from Config.PoliceEquipment.
-- pedCoords / Config.EscortVehicleShop.pedCoords on first boot) — this file
-- has no access to config.lua's values. Their row is created automatically
-- the first time the resource actually starts against this database.

-- TDM tournaments. One row per tournament INSTANCE (each daily/weekly occurrence
-- is its own row); the whole tournament — config, draw, fixtures, results — is one
-- JSON document in `data`. The other columns exist only so list/history queries
-- and the recurring-series link don't have to parse every document. DB.init()
-- creates this automatically on resource start, so this block is only needed if
-- you import the schema by hand first.
CREATE TABLE IF NOT EXISTS `nova_tdm_tournaments` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(100) NOT NULL,
    `status` VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    `start_at` BIGINT DEFAULT NULL,
    `series_id` INT DEFAULT NULL,
    `data` LONGTEXT DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_status` (`status`)
);

-- ── Gang Territory / Gang XP (persistent; outlives the events that created it) ──────────────────────────
-- Keyed by gang NAME so it works for every Config.GangProvider. DB.init() creates these on boot too.

CREATE TABLE IF NOT EXISTS `nova_gang_xp` (
    `gang_name` VARCHAR(50) NOT NULL,
    `gang_id` INT DEFAULT NULL,
    `total_xp` BIGINT NOT NULL DEFAULT 0,
    `lifetime_xp` BIGINT NOT NULL DEFAULT 0,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`gang_name`),
    KEY `idx_gang_xp_total` (`total_xp`)
);

CREATE TABLE IF NOT EXISTS `nova_gang_xp_transactions` (
    `id` BIGINT NOT NULL AUTO_INCREMENT,
    `gang_name` VARCHAR(50) NOT NULL,
    `gang_id` INT DEFAULT NULL,
    `player_identifier` VARCHAR(64) DEFAULT NULL,
    `player_name` VARCHAR(100) DEFAULT NULL,
    `source_type` VARCHAR(30) NOT NULL,
    `source_id` VARCHAR(64) DEFAULT NULL,
    `source_name` VARCHAR(120) DEFAULT NULL,
    `xp_amount` INT NOT NULL,
    `transaction_type` VARCHAR(20) NOT NULL DEFAULT 'AWARD',
    `reason` VARCHAR(255) DEFAULT NULL,
    `metadata` JSON DEFAULT NULL,
    `balance_after` BIGINT DEFAULT NULL,
    `dedupe_key` VARCHAR(190) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_gang_xp_dedupe` (`dedupe_key`),
    KEY `idx_gang_xp_tx_gang` (`gang_name`, `created_at`),
    KEY `idx_gang_xp_tx_player` (`player_identifier`, `created_at`),
    KEY `idx_gang_xp_tx_source` (`source_type`, `source_id`)
);

CREATE TABLE IF NOT EXISTS `nova_territories` (
    `territory_id` VARCHAR(64) NOT NULL,
    `event_id` INT DEFAULT NULL,
    `name` VARCHAR(100) NOT NULL,
    `owner_gang` VARCHAR(50) DEFAULT NULL,
    `expansion_level` INT NOT NULL DEFAULT 0,
    `xp_value` INT NOT NULL DEFAULT 0,
    `color` VARCHAR(20) DEFAULT NULL,
    `definition` LONGTEXT DEFAULT NULL,
    `geo_rev` INT NOT NULL DEFAULT 1,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`territory_id`),
    KEY `idx_territory_owner` (`owner_gang`),
    KEY `idx_territory_event` (`event_id`)
);

CREATE TABLE IF NOT EXISTS `nova_territory_history` (
    `id` BIGINT NOT NULL AUTO_INCREMENT,
    `territory_id` VARCHAR(64) NOT NULL,
    `territory_name` VARCHAR(100) DEFAULT NULL,
    `previous_owner` VARCHAR(50) DEFAULT NULL,
    `new_owner` VARCHAR(50) DEFAULT NULL,
    `reason` VARCHAR(20) NOT NULL,
    `ref_type` VARCHAR(20) DEFAULT NULL,
    `ref_id` INT DEFAULT NULL,
    `winner_identifier` VARCHAR(64) DEFAULT NULL,
    `winner_name` VARCHAR(100) DEFAULT NULL,
    `amount` BIGINT DEFAULT NULL,
    `meta` JSON DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_territory_history_territory` (`territory_id`, `created_at`),
    KEY `idx_territory_history_new_owner` (`new_owner`)
);

CREATE TABLE IF NOT EXISTS `nova_territory_auctions` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `event_id` INT NOT NULL,
    `run_id` BIGINT NOT NULL DEFAULT 0,
    `territory_id` VARCHAR(64) NOT NULL,
    `territory_name` VARCHAR(100) DEFAULT NULL,
    `lot_index` INT NOT NULL DEFAULT 1,
    `starting_bid` BIGINT NOT NULL DEFAULT 0,
    `winning_gang` VARCHAR(50) DEFAULT NULL,
    `winning_identifier` VARCHAR(64) DEFAULT NULL,
    `winning_player` VARCHAR(100) DEFAULT NULL,
    `final_bid` BIGINT NOT NULL DEFAULT 0,
    `bid_count` INT NOT NULL DEFAULT 0,
    `status` VARCHAR(20) NOT NULL DEFAULT 'OPEN',
    `started_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `ended_at` DATETIME DEFAULT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_territory_auction_lot` (`event_id`, `run_id`, `territory_id`),
    KEY `idx_territory_auction_territory` (`territory_id`)
);

CREATE TABLE IF NOT EXISTS `nova_territory_bids` (
    `id` BIGINT NOT NULL AUTO_INCREMENT,
    `auction_id` INT NOT NULL,
    `bidder_identifier` VARCHAR(64) DEFAULT NULL,
    `bidder_name` VARCHAR(100) DEFAULT NULL,
    `gang_name` VARCHAR(50) DEFAULT NULL,
    `amount` BIGINT NOT NULL,
    `version` INT DEFAULT NULL,
    `req_id` VARCHAR(40) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_territory_bid_amount` (`auction_id`, `amount`),
    KEY `idx_territory_bid_auction` (`auction_id`)
);

CREATE TABLE IF NOT EXISTS `nova_territory_rivals` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `attacker_gang` VARCHAR(50) NOT NULL,
    `defender_gang` VARCHAR(50) NOT NULL,
    `attacker_territory_id` VARCHAR(64) DEFAULT NULL,
    `territory_id` VARCHAR(64) NOT NULL,
    `status` VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    `created_by` VARCHAR(64) DEFAULT NULL,
    `created_by_name` VARCHAR(100) DEFAULT NULL,
    `responded_by` VARCHAR(64) DEFAULT NULL,
    `responded_by_name` VARCHAR(100) DEFAULT NULL,
    `responded_at` BIGINT DEFAULT NULL,
    `war_at` BIGINT DEFAULT NULL,
    `war_duration` INT DEFAULT NULL,
    `penalty_xp` INT DEFAULT NULL,
    `scheduled_by` VARCHAR(100) DEFAULT NULL,
    `started_at` BIGINT DEFAULT NULL,
    `ended_at` BIGINT DEFAULT NULL,
    `winner_gang` VARCHAR(50) DEFAULT NULL,
    `result` VARCHAR(20) DEFAULT NULL,
    `result_note` VARCHAR(255) DEFAULT NULL,
    `created_at` BIGINT NOT NULL DEFAULT 0,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_territory_rival_status` (`status`),
    KEY `idx_territory_rival_attacker` (`attacker_gang`),
    KEY `idx_territory_rival_defender` (`defender_gang`),
    KEY `idx_territory_rival_war` (`war_at`),
    KEY `idx_territory_rival_territory` (`territory_id`)
);

-- User Management & Granular Staff Permissions
CREATE TABLE IF NOT EXISTS `nova_user_permissions` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(64) NOT NULL,
    `server_id` INT DEFAULT NULL,
    `player_name` VARCHAR(100) NOT NULL,
    `permissions` JSON NOT NULL,
    `granted_by` VARCHAR(64) DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    -- Staff Management (added by the resource itself on an existing install; listed here for fresh installs):
    `role_id` INT NULL DEFAULT NULL,                       -- nova_staff_roles.id
    `status` VARCHAR(12) NOT NULL DEFAULT 'active',        -- active | disabled | revoked
    `overrides` LONGTEXT NULL DEFAULT NULL,                -- JSON { "section.action": true | false }
    `granted_by_name` VARCHAR(100) NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_user_perm_ident` (`identifier`)
);

-- Staff roles (the three default roles are created automatically on first start)
CREATE TABLE IF NOT EXISTS `nova_staff_roles` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(64) NOT NULL,
    `description` VARCHAR(255) NOT NULL DEFAULT '',
    `permissions` LONGTEXT NOT NULL,                       -- JSON { "section.action": true }
    `is_system` TINYINT(1) NOT NULL DEFAULT 0,
    `system_key` VARCHAR(24) NULL DEFAULT NULL,            -- owner | administrator | moderator
    `created_by` VARCHAR(100) NULL DEFAULT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_staff_role_name` (`name`)
);

-- Staff activity log (who changed what, when)
CREATE TABLE IF NOT EXISTS `nova_staff_log` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `actor_identifier` VARCHAR(64) NULL DEFAULT NULL,
    `actor_name` VARCHAR(100) NULL DEFAULT NULL,
    `action` VARCHAR(32) NOT NULL,
    `target_identifier` VARCHAR(64) NULL DEFAULT NULL,
    `target_name` VARCHAR(100) NULL DEFAULT NULL,
    `details` VARCHAR(500) NOT NULL DEFAULT '',
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
);

