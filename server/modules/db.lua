-- ─── Nova Convoy — Persistence Layer ──────────────────────────────────────────
-- Server-only. Wraps oxmysql (MySQL global from @oxmysql/lib/MySQL.lua).
-- All JSON-shaped columns (settings/trucks/route/checkpoints/airdrops) are
-- stored as JSON text and encoded/decoded here so callers work with plain
-- Lua tables.

DB = {}

local function jsonEncode(value)
    return json.encode(value or {})
end

local function jsonDecode(value)
    if not value or value == '' then return {} end
    local ok, decoded = pcall(json.decode, value)
    if ok and decoded ~= nil then return decoded end
    return {}
end

local isDbInitialized = false

function DB.init()
    if isDbInitialized then return end

    -- Fast check: if the main table exists, we can skip redundant CREATE TABLE queries
    local ok, tableExists = pcall(function()
        return MySQL.scalar.await('SELECT 1 FROM `nova_convoy_definitions` LIMIT 1')
    end)

    if not ok or tableExists == nil then
        MySQL.query.await([[
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
                `difficulty` VARCHAR(20) DEFAULT 'MEDIUM',
                `event_duration` INT DEFAULT 1200,
                `max_gang_participants` INT DEFAULT 20,
                `max_police_participants` INT DEFAULT 20,
                `status` VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
                `kind` VARCHAR(20) NOT NULL DEFAULT 'CONVOY',
                `airdrop_zones` JSON DEFAULT NULL,
                `settings` JSON DEFAULT NULL,
                `trucks` JSON DEFAULT NULL,
                `route` JSON DEFAULT NULL,
                `checkpoints` JSON DEFAULT NULL,
                `airdrops` JSON DEFAULT NULL,
                `roster` JSON DEFAULT NULL,
                `police_roster` JSON DEFAULT NULL,
                `recurrence` JSON DEFAULT NULL,
                `breaks` JSON DEFAULT NULL,
                `ambushes` JSON DEFAULT NULL,
                `scheduled_at` BIGINT DEFAULT NULL,
                `start_ped` JSON DEFAULT NULL,
                `reward_extra` JSON DEFAULT NULL,
                `created_by` VARCHAR(64) DEFAULT NULL,
                `created_by_name` VARCHAR(100) DEFAULT NULL,
                `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
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
                `report_data` JSON DEFAULT NULL,
                PRIMARY KEY (`id`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
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
            )
        ]])
        Wait(20)

        MySQL.query.await([[
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
                `hotcargo_completed` INT DEFAULT 0,
                `hotcargo_failed` INT DEFAULT 0,
                `airdrop_completed` INT DEFAULT 0,
                `airdrop_failed` INT DEFAULT 0,
                `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `nova_gangs_name` (`name`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
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
            )
        ]])
        Wait(20)

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `nova_vehicle_catalog` (
                `id` INT NOT NULL AUTO_INCREMENT,
                `model` VARCHAR(50) NOT NULL,
                `label` VARCHAR(100) NOT NULL,
                `category` VARCHAR(30) NOT NULL DEFAULT 'CARGO',
                `image_url` VARCHAR(500) DEFAULT NULL,
                `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `nova_vehicle_catalog_model` (`model`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
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
            )
        ]])
        Wait(20)

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `nova_convoy_runtime` (
                `convoy_id` INT NOT NULL,
                `status` VARCHAR(20) NOT NULL,
                `state` JSON NOT NULL,
                `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`convoy_id`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `nova_equipment_vendor` (
                `id` INT NOT NULL DEFAULT 1,
                `x` FLOAT NOT NULL,
                `y` FLOAT NOT NULL,
                `z` FLOAT NOT NULL,
                `heading` FLOAT NOT NULL DEFAULT 0,
                `enabled` TINYINT(1) NOT NULL DEFAULT 1,
                `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `nova_escort_shop` (
                `id` INT NOT NULL DEFAULT 1,
                `x` FLOAT NOT NULL,
                `y` FLOAT NOT NULL,
                `z` FLOAT NOT NULL,
                `heading` FLOAT NOT NULL DEFAULT 0,
                `enabled` TINYINT(1) NOT NULL DEFAULT 1,
                `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            )
        ]])
        Wait(20)

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `nova_schedule_settings` (
                `id` INT NOT NULL DEFAULT 1,
                `utc_offset_hours` FLOAT NOT NULL DEFAULT 0,
                `poll_interval_seconds` INT NOT NULL DEFAULT 15,
                `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`)
            )
        ]])
        Wait(20)

    end

    -- Reusable route templates — build a route once (manually, or by
    -- driving it with the Route Recorder), save it here under a name, then
    -- import that same layout into any other convoy later instead of
    -- rebuilding it from scratch every time. route/checkpoints/airdrops are
    -- stored exactly as RouteBuilder produces them; point ids get freshly
    -- regenerated on import (see SavedRoutes.import) rather than reused, so
    -- importing the same template twice into two different convoys can
    -- never let them collide.
    --
    -- Deliberately OUTSIDE the "fast check" block above: that block only
    -- runs its whole CREATE TABLE batch if `nova_convoy_definitions` does
    -- NOT already exist (a genuinely fresh install) — on any server that's
    -- already been running (which is every real server past its first
    -- boot), that check short-circuits and skips the entire batch, so a
    -- table added here later would NEVER get created on restart, ever, no
    -- matter how many times the resource restarts. That's exactly what
    -- happened here: "Table 'nova_saved_routes' doesn't exist" even after
    -- restarting, because this table is new and the database was already
    -- initialized long before it existed. CREATE TABLE IF NOT EXISTS is
    -- idempotent/cheap, so running it unconditionally on every boot (same
    -- as ensureCol's column migrations below, which have this identical
    -- problem in mind already) is the correct fix, not just a workaround —
    -- any genuinely NEW table from here on should be added here, never
    -- inside the fast-check block above.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_saved_routes` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(100) NOT NULL,
            -- Which event kind this template was saved from — CONVOY (route/
            -- checkpoints/airdrops, RouteBuilder's own shape), HOT_CARGO
            -- (spawn_zones/dropoff_zones), or GANG_AIRDROP (airdrop_zones).
            -- Only the columns matching this kind are ever populated for a
            -- given row; the rest stay NULL. Lets one shared table/list/
            -- search/delete-all UI (the Saved Routes tab) serve all three
            -- kinds instead of only ever being reachable from Convoy's Route
            -- tab, which is all it originally supported.
            `kind` VARCHAR(20) NOT NULL DEFAULT 'CONVOY',
            `route` JSON DEFAULT NULL,
            `checkpoints` JSON DEFAULT NULL,
            `airdrops` JSON DEFAULT NULL,
            `spawn_zones` JSON DEFAULT NULL,
            `dropoff_zones` JSON DEFAULT NULL,
            `airdrop_zones` JSON DEFAULT NULL,
            `rally_stages` JSON DEFAULT NULL,
            `container_wars` JSON DEFAULT NULL,
            `event_props` JSON DEFAULT NULL,
            `created_by` VARCHAR(100) DEFAULT NULL,
            `created_by_name` VARCHAR(100) DEFAULT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        )
    ]])

    -- One row per tournament INSTANCE (each daily/weekly occurrence is its
    -- own row). The whole tournament — config, draw, fixtures, results — is
    -- one JSON document in `data`; the columns beside it exist only so the
    -- list/history queries and the recurring-series link don't need to parse
    -- every document.
    MySQL.query.await([[
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
        )
    ]])

    -- ── Gang Territory / Gang XP ────────────────────────────────────────────────
    -- Persistent state: it outlives the "Gang Territory Auction" event that created it. All keyed by the gang's
    -- NAME (not nova_gangs.id) so it works for every Config.GangProvider (internal / framework / custom).

    -- One row per gang: the XP it can spend right now + everything it ever earned.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_gang_xp` (
            `gang_name` VARCHAR(50) NOT NULL,
            `gang_id` INT DEFAULT NULL,
            `total_xp` BIGINT NOT NULL DEFAULT 0,
            `lifetime_xp` BIGINT NOT NULL DEFAULT 0,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`gang_name`),
            KEY `idx_gang_xp_total` (`total_xp`)
        )
    ]])

    -- The ledger: EVERY XP change (award, expansion spend, war penalty, admin fix) is one row, and the gang's total in
    -- nova_gang_xp is always the sum of these. dedupe_key is UNIQUE, so a result submitted twice (a retried callback, a
    -- reconnect, a restart, a hostile client) can only ever pay once.
    MySQL.query.await([[
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
        )
    ]])

    -- Persistent territory state (owner + expansion level) and the geometry/config copied from the event that defined it.
    MySQL.query.await([[
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
        )
    ]])

    -- Live admin settings of the Map Zone painting (XP per painted cell, most cells per save). NULL = use Config.Territory.paint.
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_territory_settings` (
            `id` TINYINT NOT NULL,
            `xp_per_cell` INT DEFAULT NULL,
            `max_new_cells` INT DEFAULT NULL,
            `updated_by` VARCHAR(100) DEFAULT NULL,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        )
    ]])

    MySQL.query.await([[
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
        )
    ]])

    -- One row per territory lot of one auction run (the result), plus every accepted bid for the bid history.
    MySQL.query.await([[
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
        )
    ]])

    MySQL.query.await([[
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
        )
    ]])

    -- Rival challenges and the wars they become. status: PENDING → ACCEPTED → SCHEDULED → ACTIVE → COMPLETED
    -- (or DECLINED / CANCELLED). The war schedule and result live on the same row.
    MySQL.query.await([[
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
        )
    ]])

    -- Dedicated Civilian Leaderboard table for non-gang participant standings
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_civilian_leaderboard` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `player_identifier` VARCHAR(64) NOT NULL,
            `player_name` VARCHAR(100) NOT NULL,
            `player_role` VARCHAR(50) DEFAULT 'Civilian',
            `event_type` VARCHAR(30) NOT NULL,
            `wins` INT NOT NULL DEFAULT 0,
            `podiums` INT NOT NULL DEFAULT 0,
            `total_participations` INT NOT NULL DEFAULT 0,
            `points` INT NOT NULL DEFAULT 0,
            `total_rewards` INT NOT NULL DEFAULT 0,
            `best_time` INT DEFAULT NULL,
            `last_event_name` VARCHAR(100) DEFAULT NULL,
            `last_participated` DATETIME DEFAULT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_civ_player_event` (`player_identifier`, `event_type`),
            KEY `idx_civ_event_type` (`event_type`),
            KEY `idx_civ_points` (`points`)
        )
    ]])

    -- Dedicated Event Banner configurations for announcement banners
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_event_banner_configs` (
            `event_key` VARCHAR(50) NOT NULL,
            `image_url` VARCHAR(2048) DEFAULT NULL,
            `pos_x` FLOAT NOT NULL DEFAULT 50.0,
            `pos_y` FLOAT NOT NULL DEFAULT 50.0,
            `zoom` FLOAT NOT NULL DEFAULT 1.0,
            `fit` VARCHAR(20) NOT NULL DEFAULT 'cover',
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`event_key`)
        )
    ]])

    -- Dedicated User Management & Staff Permissions
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_user_permissions` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `identifier` VARCHAR(64) NOT NULL,
            `server_id` INT DEFAULT NULL,
            `player_name` VARCHAR(100) NOT NULL,
            `permissions` JSON NOT NULL,
            `granted_by` VARCHAR(64) DEFAULT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_user_perm_ident` (`identifier`)
        )
    ]])

    -- Seed initial default banner configs if empty
    local bannerCount = MySQL.scalar.await('SELECT COUNT(*) FROM `nova_event_banner_configs`')
    if (tonumber(bannerCount) or 0) == 0 then
        MySQL.query.await([[
            INSERT INTO `nova_event_banner_configs` (`event_key`, `image_url`, `pos_x`, `pos_y`, `zoom`, `fit`)
            VALUES
            ('convoy', '../images/event_announcement_banner_images/convoy.jpg', 50.0, 50.0, 1.0, 'cover'),
            ('airdrop', '../images/event_announcement_banner_images/gang_airdrop.jpg', 50.0, 50.0, 1.0, 'cover'),
            ('hotcargo', '../images/event_announcement_banner_images/hot_cargo.jpg', 50.0, 50.0, 1.0, 'cover'),
            ('rally', '../images/event_announcement_banner_images/gang_race.jpg', 50.0, 50.0, 1.0, 'cover'),
            ('containerwars', '../images/event_announcement_banner_images/container_wars.jpg', 50.0, 50.0, 1.0, 'cover'),
            ('tdm', '../images/event_announcement_banner_images/tdm.jpg', 50.0, 50.0, 1.0, 'cover'),
            ('territory', '../images/event_announcement_banner_images/territory.jpg', 50.0, 10.0, 1.0, 'cover')
        ]])
    end
    -- the Gang Territory banner started life as a placeholder SVG: point an existing row at the real artwork (an admin's own
    -- image, or a position they already adjusted, is left alone — only the untouched placeholder row is migrated)
    MySQL.query.await([[
        UPDATE `nova_event_banner_configs` SET `image_url` = '../images/event_announcement_banner_images/territory.jpg', `pos_y` = 10.0
        WHERE `event_key` = 'territory' AND `image_url` LIKE '%territory.svg%'
    ]])

    -- Fast, direct column checking with SHOW COLUMNS (takes < 1ms without scanning entire database)
    local function getColumns(tbl)
        local cols = {}
        local okCols, rows = pcall(MySQL.query.await, ('SHOW COLUMNS FROM `%s`'):format(tbl))
        if okCols and rows then
            for _, r in ipairs(rows) do
                if r.Field then cols[r.Field] = true end
            end
        end
        return cols
    end

    local function ensureCol(existingCols, tbl, column, afterColumn, columnType)
        if not existingCols[column] then
            pcall(MySQL.query.await, ('ALTER TABLE `%s` ADD COLUMN `%s` %s AFTER `%s`'):format(tbl, column, columnType or 'JSON DEFAULT NULL', afterColumn))
            existingCols[column] = true
        end
    end

    -- Indexes for lookups that used to scan the whole table: a player's gang membership is looked up by identifier alone (the unique key
    -- starts with gang_id, so it cannot serve that), and the History tab sorts the history by end time.
    local function ensureIndex(tbl, name, columns)
        local ok, n = pcall(MySQL.scalar.await, 'SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ?', { tbl, name })
        if ok and (tonumber(n) or 0) == 0 then
            pcall(MySQL.query.await, ('ALTER TABLE `%s` ADD INDEX `%s` (%s)'):format(tbl, name, columns))
        end
    end
    ensureIndex('nova_gang_members', 'idx_gang_member_identifier', '`identifier`')
    ensureIndex('nova_convoy_history', 'idx_history_ended', '`ended_at`')
    ensureIndex('nova_convoy_history', 'idx_history_kind_ended', '`kind`, `ended_at`')

    -- land painted onto a territory in the Map Zone editor (extra cells + cells an admin cut away); survives event republishes
    ensureCol(getColumns('nova_territories'), 'nova_territories', 'custom_geo', 'definition', 'LONGTEXT DEFAULT NULL')
    -- the challenged gang's own territory (the battleground can be the challenger's instead): the loser's land that shrinks after a war
    ensureCol(getColumns('nova_territory_rivals'), 'nova_territory_rivals', 'defender_territory_id', 'attacker_territory_id', 'VARCHAR(64) DEFAULT NULL')
    -- what the challenged gang wrote when it answered (shown to the admins under that challenge) and the war zone an admin drew for it
    ensureCol(getColumns('nova_territory_rivals'), 'nova_territory_rivals', 'response_comment', 'result_note', 'VARCHAR(400) DEFAULT NULL')
    ensureCol(getColumns('nova_territory_rivals'), 'nova_territory_rivals', 'war_zone', 'response_comment', 'TEXT DEFAULT NULL')

    local defCols = getColumns('nova_convoy_definitions')
    ensureCol(defCols, 'nova_convoy_definitions', 'max_gang_participants', 'event_duration', 'INT DEFAULT 20')
    ensureCol(defCols, 'nova_convoy_definitions', 'max_police_participants', 'max_gang_participants', 'INT DEFAULT 20')
    ensureCol(defCols, 'nova_convoy_definitions', 'roster', 'airdrops')
    ensureCol(defCols, 'nova_convoy_definitions', 'breaks', 'roster')
    ensureCol(defCols, 'nova_convoy_definitions', 'ambushes', 'breaks')
    ensureCol(defCols, 'nova_convoy_definitions', 'scheduled_at', 'ambushes', 'BIGINT DEFAULT NULL')
    ensureCol(defCols, 'nova_convoy_definitions', 'start_ped', 'scheduled_at')
    ensureCol(defCols, 'nova_convoy_definitions', 'reward_extra', 'reward_pool')
    ensureCol(defCols, 'nova_convoy_definitions', 'kind', 'status', "VARCHAR(20) NOT NULL DEFAULT 'CONVOY'")
    ensureCol(defCols, 'nova_convoy_definitions', 'airdrop_zones', 'kind')
    ensureCol(defCols, 'nova_convoy_definitions', 'hot_cargo', 'airdrop_zones')
    ensureCol(defCols, 'nova_convoy_definitions', 'rally_stages', 'hot_cargo')
    -- GANG_RACE per-position rewards: { first, second, third, participation },
    -- each its own reward list — see sanitizePositionRewards in convoy_manager.lua.
    ensureCol(defCols, 'nova_convoy_definitions', 'position_rewards', 'rally_stages')
    ensureCol(defCols, 'nova_convoy_definitions', 'police_roster', 'roster')
    ensureCol(defCols, 'nova_convoy_definitions', 'recurrence', 'police_roster')
    -- TDM-kind config, one JSON blob covering the whole event the same way
    -- hot_cargo/rally_stages do: matchFormat (STANDARD/TOURNAMENT), duration,
    -- killLimit, participatingGangs, combat zone, weapon vendor, spawn points,
    -- and (Tournament only) the live bracket tree. See sanitizeTdmConfig in
    -- convoy_manager.lua. Deliberately one column, not several — matches the
    -- existing per-kind-blob convention rather than inventing new tables.
    ensureCol(defCols, 'nova_convoy_definitions', 'tdm', 'position_rewards')
    ensureCol(defCols, 'nova_convoy_definitions', 'container_wars', 'tdm')
    -- Props / vehicles placed with the shared Prop Placer for the whole event (def.props) — see event_props.lua.
    ensureCol(defCols, 'nova_convoy_definitions', 'event_props', 'container_wars')
    -- GANG_TERRITORY config (auction setup + every territory area with its painted shapes / expansions / capture point).
    -- The territories' OWNERS live in nova_territories, never here: this is only the event's configuration.
    ensureCol(defCols, 'nova_convoy_definitions', 'territory', 'event_props')
    -- CRACKDOWN config (Gang vs Police event): target gang, combat zone, prep/duration, win conditions, rewards, messages.
    ensureCol(defCols, 'nova_convoy_definitions', 'crackdown', 'territory')

    -- Per-gang role permissions, stored on the gang row as JSON: a map of
    -- rank name -> { manageGang = bool, registerRoster = bool }. Kept as JSON
    -- rather than a new table because a gang's role list is small, always read
    -- whole (never queried by permission), and lives and dies with the gang —
    -- a join table here would buy nothing but an extra round-trip on every
    -- access check. See GangService.GetRolePermissions / SetRolePermission.
    local gangCols = getColumns('nova_gangs')
    ensureCol(gangCols, 'nova_gangs', 'role_permissions', 'accent_color')

    -- Migrate any historical convoys where participant caps were NULL or 0
    pcall(MySQL.query.await, 'UPDATE nova_convoy_definitions SET max_police_participants = 20 WHERE max_police_participants IS NULL OR max_police_participants <= 0')
    pcall(MySQL.query.await, 'UPDATE nova_convoy_definitions SET max_gang_participants = 20 WHERE max_gang_participants IS NULL OR max_gang_participants <= 0')

    local histCols = getColumns('nova_convoy_history')
    ensureCol(histCols, 'nova_convoy_history', 'kind', 'checkpoints_completed', "VARCHAR(20) NOT NULL DEFAULT 'CONVOY'")
    ensureCol(histCols, 'nova_convoy_history', 'report_data', 'kind', 'JSON DEFAULT NULL')

    -- Saved route templates originally only ever covered CONVOY's own
    -- route/checkpoints/airdrops shape — these add the equivalent columns
    -- for HOT_CARGO (spawn_zones/dropoff_zones) and GANG_AIRDROP
    -- (airdrop_zones), so a template saved from either of those screens has
    -- somewhere to live too, on a server that already created this table
    -- before that existed.
    local savedRouteCols = getColumns('nova_saved_routes')
    ensureCol(savedRouteCols, 'nova_saved_routes', 'kind', 'name', "VARCHAR(20) NOT NULL DEFAULT 'CONVOY'")
    ensureCol(savedRouteCols, 'nova_saved_routes', 'spawn_zones', 'airdrops', 'JSON DEFAULT NULL')
    ensureCol(savedRouteCols, 'nova_saved_routes', 'dropoff_zones', 'spawn_zones', 'JSON DEFAULT NULL')
    ensureCol(savedRouteCols, 'nova_saved_routes', 'airdrop_zones', 'dropoff_zones', 'JSON DEFAULT NULL')
    ensureCol(savedRouteCols, 'nova_saved_routes', 'rally_stages', 'airdrop_zones', 'JSON DEFAULT NULL')
    -- CONTAINER_WARS yard layouts: { yard = { crane, pickups, drops, dummies, carry }, zone = { points } }
    ensureCol(savedRouteCols, 'nova_saved_routes', 'container_wars', 'rally_stages', 'JSON DEFAULT NULL')
    ensureCol(savedRouteCols, 'nova_saved_routes', 'event_props', 'container_wars', 'JSON DEFAULT NULL')

    local gangCols = getColumns('nova_gangs')
    ensureCol(gangCols, 'nova_gangs', 'logo', 'convoys_failed', 'MEDIUMTEXT DEFAULT NULL')
    ensureCol(gangCols, 'nova_gangs', 'accent_color', 'logo', 'VARCHAR(20) DEFAULT NULL')
    -- Per-event-kind leaderboard stats — convoys_joined/captured/failed above
    -- have only ever been written for CONVOY-kind events (HOT_CARGO/
    -- GANG_AIRDROP never called RecordOutcome before), so those columns
    -- already represent "CONVOY only" with no migration needed. These add
    -- the same captured/failed tracking for the other two event kinds so
    -- the leaderboard can be broken out per event type instead of one
    -- combined (and, for two of the three kinds, actually empty) total.
    ensureCol(gangCols, 'nova_gangs', 'hotcargo_completed', 'accent_color', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'hotcargo_failed', 'hotcargo_completed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'airdrop_completed', 'hotcargo_failed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'airdrop_failed', 'airdrop_completed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'rally_completed', 'airdrop_failed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'rally_failed', 'rally_completed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'rally_joined', 'rally_failed', 'INT DEFAULT 0')
    -- Gang Rally leaderboard: races WON (rally_completed now counts races the
    -- gang FINISHED) and the race tokens the gang has earned by finishing position.
    ensureCol(gangCols, 'nova_gangs', 'rally_wins', 'rally_joined', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'rally_tokens', 'rally_wins', 'INT DEFAULT 0')
    -- TDM leaderboard stats — wins/losses/matches at the Standard-match level,
    -- kills/deaths aggregated from every match a gang's members played in,
    -- tournament_wins/tournament_played tracked separately since a gang can
    -- lose a Standard match without ever entering a tournament (and vice versa).
    ensureCol(gangCols, 'nova_gangs', 'tdm_wins', 'rally_tokens', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'tdm_losses', 'tdm_wins', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'tdm_matches', 'tdm_losses', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'tdm_kills', 'tdm_matches', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'tdm_deaths', 'tdm_kills', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'tdm_tournament_wins', 'tdm_deaths', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'tdm_tournament_played', 'tdm_tournament_wins', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'containerwars_completed', 'tdm_tournament_played', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'containerwars_failed', 'containerwars_completed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'containerwars_won', 'containerwars_failed', 'INT DEFAULT 0')
    ensureCol(gangCols, 'nova_gangs', 'containerwars_spend', 'containerwars_won', 'BIGINT DEFAULT 0')
    -- Events a gang actually bid in (completed = events it finished as top winner,
    -- failed = events it bid in but won no container).
    ensureCol(gangCols, 'nova_gangs', 'containerwars_joined', 'containerwars_spend', 'INT DEFAULT 0')

    local civCols = getColumns('nova_civilian_leaderboard')
    ensureCol(civCols, 'nova_civilian_leaderboard', 'player_role', 'player_name', "VARCHAR(50) DEFAULT 'Civilian'")

    local eqCols = getColumns('nova_equipment_vendor')
    ensureCol(eqCols, 'nova_equipment_vendor', 'enabled', 'heading', 'TINYINT(1) NOT NULL DEFAULT 1')

    -- Default single-row table seedings if empty
    local vendorCount = MySQL.scalar.await('SELECT COUNT(*) FROM nova_equipment_vendor')
    if vendorCount == 0 then
        local c = Config.PoliceEquipment.pedCoords
        MySQL.insert.await('INSERT INTO nova_equipment_vendor (id, x, y, z, heading, enabled) VALUES (1, ?, ?, ?, ?, ?)', { c.x, c.y, c.z, c.w, Config.PoliceEquipment.enabled and 1 or 0 })
    end

    local escortShopCount = MySQL.scalar.await('SELECT COUNT(*) FROM nova_escort_shop')
    if escortShopCount == 0 then
        local c = Config.EscortVehicleShop.pedCoords
        MySQL.insert.await('INSERT INTO nova_escort_shop (id, x, y, z, heading, enabled) VALUES (1, ?, ?, ?, ?, ?)', { c.x, c.y, c.z, c.w, Config.EscortVehicleShop.enabled and 1 or 0 })
    end

    local scheduleSettingsCount = MySQL.scalar.await('SELECT COUNT(*) FROM nova_schedule_settings')
    if scheduleSettingsCount == 0 then
        MySQL.insert.await('INSERT INTO nova_schedule_settings (id, utc_offset_hours, poll_interval_seconds) VALUES (1, ?, ?)',
            { Config.ScheduleUtcOffsetHours or 0, Config.SchedulePollIntervalSeconds or 15 })
    end

    local count = MySQL.scalar.await('SELECT COUNT(*) FROM nova_vehicle_catalog')
    if count == 0 then
        for _, v in ipairs({
            { model = 'packer', label = 'Packer (Cargo Truck)', category = 'CARGO' },
            { model = 'benson', label = 'Benson (Cargo Truck)', category = 'CARGO' },
            { model = 'hauler', label = 'Hauler (Semi Truck)', category = 'CARGO' },
            { model = 'pounder', label = 'Pounder (Box Truck)', category = 'CARGO' },
            { model = 'riot2', label = 'Riot Van (Police Escort)', category = 'ESCORT' },
            { model = 'police3', label = 'Police Cruiser (Escort)', category = 'ESCORT' },
            { model = 'barracks', label = 'Barracks (Army Transport)', category = 'ARMY' },
            { model = 'insurgent', label = 'Insurgent (Army Escort)', category = 'ARMY' },
        }) do
            MySQL.insert.await('INSERT INTO nova_vehicle_catalog (model, label, category) VALUES (?, ?, ?)', { v.model, v.label, v.category })
        end
    end

    if UserPermissions and UserPermissions.init then
        UserPermissions.init()
    end

    isDbInitialized = true
end

-- ── Convoy Definitions ─────────────────────────────────────────────────────────

-- reward_extra (if present/non-empty) is the canonical, full reward list —
-- reward_type/amount/pool are just entry #1 mirrored into flat columns for
-- old simple-read call sites. A convoy saved before this multi-reward
-- change has no reward_extra at all, so it falls back to a single-entry
-- list built from those three legacy columns.
local function decodeReward(row)
    local extra = jsonDecode(row.reward_extra)
    if extra and extra[1] then return extra end
    if row.reward_type then return { { type = row.reward_type, amount = row.reward_amount, pool = row.reward_pool } } end
    return {}
end

local function rowToDefinition(row)
    if not row then return nil end
    return {
        id = row.id,
        name = row.name,
        shortDescription = row.short_description,
        detailedDescription = row.detailed_description,
        cargo = { type = row.cargo_type, description = row.cargo_description },
        reward = decodeReward(row),
        difficulty = row.difficulty,
        eventDuration = (row.event_duration and tonumber(row.event_duration) and tonumber(row.event_duration) > 0) and tonumber(row.event_duration) or nil,
        maxGangParticipants = (row.max_gang_participants and tonumber(row.max_gang_participants) > 0) and tonumber(row.max_gang_participants) or (Config.MaxGangParticipants or 20),
        maxPoliceParticipants = (row.max_police_participants and tonumber(row.max_police_participants) > 0) and tonumber(row.max_police_participants) or (Config.MaxPoliceParticipants or 20),
        status = row.status,
        kind = row.kind or 'CONVOY',
        settings = jsonDecode(row.settings),
        trucks = jsonDecode(row.trucks),
        route = jsonDecode(row.route),
        checkpoints = jsonDecode(row.checkpoints),
        airdrops = jsonDecode(row.airdrops),
        airdropZones = jsonDecode(row.airdrop_zones),
        hotCargo = jsonDecode(row.hot_cargo) or { policeAlertBufferSeconds = 45, trucks = {}, spawnZones = {}, dropoffZones = {}, salvageReward = {} },
        rallyStages = jsonDecode(row.rally_stages),
        positionRewards = jsonDecode(row.position_rewards) or { first = {}, second = {}, third = {}, participation = {} },
        tdm = jsonDecode(row.tdm) or { matchFormat = 'STANDARD', participatingGangs = {}, duration = 600, killLimit = 0, zone = {}, spawnPoints = {}, weaponVendor = {}, bracket = {} },
        containerWars = jsonDecode(row.container_wars) or { maxContainers = 4, containersPerRound = 4, crane = {}, zone = {}, containers = {} },
        props = jsonDecode(row.event_props) or {},
        territory = jsonDecode(row.territory),
        crackdown = jsonDecode(row.crackdown) or {},
        roster = jsonDecode(row.roster),
        policeRoster = jsonDecode(row.police_roster),
        recurrence = jsonDecode(row.recurrence),
        breaks = jsonDecode(row.breaks),
        ambushes = jsonDecode(row.ambushes),
        scheduledAt = row.scheduled_at,
        startPed = jsonDecode(row.start_ped),
        createdBy = row.created_by,
        createdByName = Bridge.StripAccountName(row.created_by_name),
        createdAt = row.created_at,
        updatedAt = row.updated_at,
    }
end

function DB.getAllConvoyDefinitions()
    local rows = MySQL.query.await('SELECT * FROM nova_convoy_definitions ORDER BY updated_at DESC')
    local result = {}
    for i, row in ipairs(rows or {}) do
        result[i] = rowToDefinition(row)
    end
    return result
end

function DB.getConvoyDefinition(id)
    local row = MySQL.single.await('SELECT * FROM nova_convoy_definitions WHERE id = ?', { id })
    return rowToDefinition(row)
end

local function firstReward(def)
    return def.reward and def.reward[1] or nil
end

function DB.createConvoyDefinition(def)
    local first = firstReward(def)
    local id = MySQL.insert.await([[
        INSERT INTO nova_convoy_definitions
            (name, short_description, detailed_description, cargo_type, cargo_description,
             reward_type, reward_amount, reward_pool, reward_extra, difficulty, event_duration,
             max_gang_participants, max_police_participants, status, kind, settings, trucks,
             route, checkpoints, airdrops, airdrop_zones, hot_cargo, rally_stages, position_rewards, tdm, container_wars, event_props, territory, crackdown, roster, police_roster, recurrence, breaks, ambushes, scheduled_at, start_ped, created_by, created_by_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        def.name, def.shortDescription, def.detailedDescription,
        def.cargo and def.cargo.type, def.cargo and def.cargo.description,
        first and first.type, first and first.amount, first and first.pool, jsonEncode(def.reward),
        def.difficulty, def.eventDuration, def.maxGangParticipants, def.maxPoliceParticipants,
        def.status or 'DRAFT', def.kind or 'CONVOY', jsonEncode(def.settings), jsonEncode(def.trucks),
        jsonEncode(def.route), jsonEncode(def.checkpoints), jsonEncode(def.airdrops), jsonEncode(def.airdropZones), jsonEncode(def.hotCargo), jsonEncode(def.rallyStages), jsonEncode(def.positionRewards), jsonEncode(def.tdm), jsonEncode(def.containerWars), jsonEncode(def.props or {}), jsonEncode(def.territory or {}), jsonEncode(def.crackdown or {}), jsonEncode(def.roster), jsonEncode(def.policeRoster),
        jsonEncode(def.recurrence), jsonEncode(def.breaks), jsonEncode(def.ambushes), def.scheduledAt, jsonEncode(def.startPed),
        def.createdBy, def.createdByName,
    })
    return id
end

function DB.updateConvoyDefinition(id, def)
    local first = firstReward(def)
    MySQL.update.await([[
        UPDATE nova_convoy_definitions SET
            name = ?, short_description = ?, detailed_description = ?, cargo_type = ?,
            cargo_description = ?, reward_type = ?, reward_amount = ?, reward_pool = ?, reward_extra = ?,
            difficulty = ?, event_duration = ?, max_gang_participants = ?,
            max_police_participants = ?, status = ?, kind = ?, settings = ?, trucks = ?,
            route = ?, checkpoints = ?, airdrops = ?, airdrop_zones = ?, hot_cargo = ?, rally_stages = ?, position_rewards = ?, tdm = ?, container_wars = ?, event_props = ?, territory = ?, crackdown = ?, roster = ?, police_roster = ?, recurrence = ?, breaks = ?, ambushes = ?,
            scheduled_at = ?, start_ped = ?
        WHERE id = ?
    ]], {
        def.name, def.shortDescription, def.detailedDescription,
        def.cargo and def.cargo.type, def.cargo and def.cargo.description,
        first and first.type, first and first.amount, first and first.pool, jsonEncode(def.reward),
        def.difficulty, def.eventDuration, def.maxGangParticipants, def.maxPoliceParticipants,
        def.status, def.kind or 'CONVOY', jsonEncode(def.settings), jsonEncode(def.trucks),
        jsonEncode(def.route), jsonEncode(def.checkpoints), jsonEncode(def.airdrops), jsonEncode(def.airdropZones), jsonEncode(def.hotCargo), jsonEncode(def.rallyStages), jsonEncode(def.positionRewards), jsonEncode(def.tdm), jsonEncode(def.containerWars), jsonEncode(def.props or {}), jsonEncode(def.territory or {}), jsonEncode(def.crackdown or {}), jsonEncode(def.roster), jsonEncode(def.policeRoster),
        jsonEncode(def.recurrence), jsonEncode(def.breaks), jsonEncode(def.ambushes), def.scheduledAt, jsonEncode(def.startPed),
        id,
    })
end

function DB.deleteConvoyDefinition(id)
    MySQL.update.await('DELETE FROM nova_convoy_definitions WHERE id = ?', { id })
end

-- ── Convoy History ──────────────────────────────────────────────────────────────

function DB.insertConvoyHistory(entry)
    if TestRun and TestRun.admin then return nil end   -- a test run is not an event of record
    -- The reward column shows what the run REALLY paid (the report's own summary), not the configured maximum / a placeholder.
    local rd = entry.reportData
    if type(rd) == 'table' and type(rd.rewards) == 'string' and rd.rewards ~= '' then
        entry.rewardSummary = rd.rewards:sub(1, 250)
    end
    return MySQL.insert.await([[
        INSERT INTO nova_convoy_history
            (convoy_definition_id, name, created_by, started_at, ended_at, duration,
             truck_count, police_participants, gang_participants, winning_gang, outcome,
             reward_summary, destroyed_trucks, checkpoints_completed, kind, report_data)
        VALUES (?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        entry.convoyDefinitionId, entry.name, entry.createdBy, entry.startedAt, entry.endedAt,
        entry.duration, entry.truckCount, entry.policeParticipants, entry.gangParticipants,
        entry.winningGang, entry.outcome, entry.rewardSummary, entry.destroyedTrucks,
        entry.checkpointsCompleted, entry.kind or 'CONVOY', jsonEncode(entry.reportData),
    })
end

-- forPolice: when true, excludes GANG_AIRDROP-kind rows entirely
-- Reports saved earlier hold "Name (account)" for who started / ended the run: show the character name only.
local function cleanHistoryRow(row)
    if not row then return row end
    row.created_by = Bridge.StripAccountName(row.created_by)
    local rd = row.reportData
    if type(rd) == 'table' then
        rd.startedByName = Bridge.StripAccountName(rd.startedByName)
        rd.forcedByName = Bridge.StripAccountName(rd.forcedByName)
    end
    return row
end

-- The Event History LIST. The full report (report_data) of a run can be tens of KB (timelines, rosters, tables), and the list used to
-- load and decode it for up to 300 rows on every visit just to show three things. Now only those three are pulled out of the JSON inside
-- MySQL; the full report is fetched on its own (getConvoyHistoryById) when someone opens it. The answer is also kept for 10 s and
-- dropped whenever a history row is added or removed.
local HISTORY_COLUMNS = [[
    id, convoy_definition_id, name, created_by, started_at, ended_at, duration, truck_count, police_participants, gang_participants,
    winning_gang, outcome, reward_summary, destroyed_trucks, checkpoints_completed, kind,
    JSON_UNQUOTE(JSON_EXTRACT(report_data, '$.summaryLine')) AS summary_line,
    JSON_UNQUOTE(JSON_EXTRACT(report_data, '$.winner')) AS report_winner,
    JSON_UNQUOTE(JSON_EXTRACT(report_data, '$.rewards')) AS report_rewards
]]
local historyCache = {}
local function bustHistory() historyCache = {} end
function DB.getConvoyHistory(limit, forPolice)
    limit = math.max(1, math.min(500, math.floor(tonumber(limit) or 50)))
    local key = (forPolice and 'p' or 'a') .. limit
    local hit = historyCache[key]
    if hit and GetGameTimer() - hit.at < 10000 then return hit.rows end
    local query = ('SELECT %s FROM nova_convoy_history %s ORDER BY ended_at DESC LIMIT ?'):format(HISTORY_COLUMNS, forPolice and "WHERE kind = 'CONVOY'" or '')
    local rows = MySQL.query.await(query, { limit }) or {}
    for _, row in ipairs(rows) do
        -- JSON null / missing comes back as nil or the string 'null'
        for _, f in ipairs({ 'summary_line', 'report_winner', 'report_rewards' }) do
            if row[f] == 'null' or row[f] == '' then row[f] = nil end
        end
        row.created_by = Bridge.StripAccountName(row.created_by)
    end
    historyCache[key] = { rows = rows, at = GetGameTimer() }
    return rows
end

function DB.getConvoyHistoryById(id)
    local row = MySQL.single.await('SELECT * FROM nova_convoy_history WHERE id = ?', { id })
    if row then
        row.reportData = jsonDecode(row.report_data)
        cleanHistoryRow(row)
    end
    return row
end

-- Only removes this ONE history row (a single past run) — deliberately does
-- NOT touch nova_convoy_events, since those are keyed by convoy_definition_id
-- rather than this row's own id, and a convoy replayed multiple times (Edit
-- & Reuse) shares that same definition id across several separate history
-- rows, any of which could still want to expand its own event log.
function DB.deleteConvoyHistory(id)
    local result = MySQL.query.await('DELETE FROM nova_convoy_history WHERE id = ?', { id })
    return result ~= nil and result ~= false
end

-- Wipes every past-run record at once (the History tab's "Clear All").
-- Same scope as the single-row delete above — only nova_convoy_history rows,
-- nova_convoy_events is untouched since it's keyed by convoy_definition_id
-- and still needed for any definition that gets reused/run again later.
function DB.clearConvoyHistory()
    local result = MySQL.query.await('DELETE FROM nova_convoy_history', {})
    return result ~= nil and result ~= false
end

-- ── Convoy Event Log (loot/capture attribution) ─────────────────────────────────

function DB.insertConvoyEvent(convoyDefinitionId, eventType, fields)
    if TestRun and TestRun.admin then return nil end
    fields = fields or {}
    return MySQL.insert.await([[
        INSERT INTO nova_convoy_events
            (convoy_definition_id, event_type, gang_name, gang_label, player_identifier, player_name, detail)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], {
        convoyDefinitionId, eventType, fields.gangName, fields.gangLabel,
        fields.playerIdentifier, fields.playerName, fields.detail,
    })
end

function DB.getConvoyEvents(convoyDefinitionId)
    return MySQL.query.await('SELECT * FROM nova_convoy_events WHERE convoy_definition_id = ? ORDER BY created_at ASC', { convoyDefinitionId })
end

-- ── Gangs ────────────────────────────────────────────────────────────────────────

function DB.getAllGangs()
    -- two reads for all gangs (it used to be one more read PER gang, every time anything asked for the gang list)
    local gangs = MySQL.query.await('SELECT * FROM nova_gangs ORDER BY name ASC') or {}
    local byGang = {}
    for _, gang in ipairs(gangs) do gang.members = {}; byGang[gang.id] = gang.members end
    if #gangs > 0 then
        for _, m in ipairs(MySQL.query.await('SELECT * FROM nova_gang_members ORDER BY id ASC') or {}) do
            local list = byGang[m.gang_id]
            if list then
                -- rows saved earlier hold "Name (account)": show the character name only
                m.name = Bridge.StripAccountName(m.name)
                list[#list + 1] = m
            end
        end
    end
    return gangs
end

function DB.getGangByName(name)
    return MySQL.single.await('SELECT * FROM nova_gangs WHERE name = ?', { name })
end

function DB.createGang(name, label, maxMembers)
    return MySQL.insert.await('INSERT INTO nova_gangs (name, label, max_members) VALUES (?, ?, ?)', { name, label, maxMembers or 20 })
end

function DB.updateGang(id, fields)
    local ok, err = pcall(function()
        MySQL.update.await(
            'UPDATE nova_gangs SET label = ?, leader_identifier = ?, max_members = ?, can_participate = ?, logo = ?, accent_color = ? WHERE id = ?',
            { fields.label, fields.leaderIdentifier, fields.maxMembers, fields.canParticipate and 1 or 0, fields.logo, fields.accentColor, id }
        )
    end)
    if not ok then
        lib.print.warn(('[NovaConvoy] DB.updateGang(%s) failed: %s'):format(tostring(id), tostring(err)))
    end
    return ok, not ok and tostring(err) or nil
end

-- Rank name -> { manageGang = bool, registerRoster = bool }. Always returns a
-- table (never nil) so callers can index straight into it; unknown ranks
-- simply have no entry, which callers treat as "no permissions".
function DB.getGangRolePermissions(gangId)
    local row = MySQL.single.await('SELECT role_permissions FROM nova_gangs WHERE id = ?', { gangId })
    return jsonDecode(row and row.role_permissions)
end

function DB.setGangRolePermissions(gangId, permissions)
    MySQL.update.await('UPDATE nova_gangs SET role_permissions = ? WHERE id = ?', { jsonEncode(permissions or {}), gangId })
    return true
end

function DB.setGangLogo(id, logo)
    MySQL.update.await('UPDATE nova_gangs SET logo = ? WHERE id = ?', { logo, id })
end

function DB.setGangLeader(id, identifier)
    MySQL.update.await('UPDATE nova_gangs SET leader_identifier = ? WHERE id = ?', { identifier, id })
end

function DB.setGangAccentColor(id, color)
    MySQL.update.await('UPDATE nova_gangs SET accent_color = ? WHERE id = ?', { color, id })
end

function DB.deleteGang(id)
    MySQL.update.await('DELETE FROM nova_gangs WHERE id = ?', { id })
end

function DB.addGangMember(gangId, identifier, name, rank)
    return MySQL.insert.await(
        'INSERT INTO nova_gang_members (gang_id, identifier, name, `rank`) VALUES (?, ?, ?, ?)',
        { gangId, identifier, name, rank or 'Member' }
    )
end

function DB.removeGangMember(gangId, identifier)
    MySQL.update.await('DELETE FROM nova_gang_members WHERE gang_id = ? AND identifier = ?', { gangId, identifier })
end

function DB.setGangMemberRank(gangId, identifier, rank)
    MySQL.update.await('UPDATE nova_gang_members SET `rank` = ? WHERE gang_id = ? AND identifier = ?', { rank, gangId, identifier })
end

function DB.getGangMember(identifier)
    local member = DB._getGangMemberRow(identifier)
    if member then member.name = Bridge.StripAccountName(member.name) end
    return member
end

function DB._getGangMemberRow(identifier)
    return MySQL.single.await([[
        SELECT nova_gang_members.*, nova_gangs.name AS gang_name, nova_gangs.label AS gang_label,
               nova_gangs.logo AS gang_logo, nova_gangs.accent_color AS gang_accent_color
        FROM nova_gang_members
        JOIN nova_gangs ON nova_gangs.id = nova_gang_members.gang_id
        WHERE nova_gang_members.identifier = ?
    ]], { identifier })
end

-- ── Vehicle Catalog ─────────────────────────────────────────────────────────────

function DB.getVehicleCatalog()
    return MySQL.query.await('SELECT * FROM nova_vehicle_catalog ORDER BY category ASC, label ASC')
end

function DB.addVehicleCatalogEntry(model, label, category, imageUrl)
    return MySQL.insert.await(
        'INSERT INTO nova_vehicle_catalog (model, label, category, image_url) VALUES (?, ?, ?, ?)',
        { model, label, category, imageUrl }
    )
end

function DB.deleteVehicleCatalogEntry(id)
    MySQL.update.await('DELETE FROM nova_vehicle_catalog WHERE id = ?', { id })
end

function DB.getVehicleCatalogEntryByModel(model)
    return MySQL.single.await('SELECT * FROM nova_vehicle_catalog WHERE model = ?', { model })
end

-- ── NPC Spawn Zones ──────────────────────────────────────────────────────────────

function DB.getAllSpawnZones()
    return MySQL.query.await('SELECT * FROM nova_npc_spawn_zones ORDER BY label ASC')
end

function DB.createSpawnZone(label, kind, x, y, z, radius)
    return MySQL.insert.await(
        'INSERT INTO nova_npc_spawn_zones (label, type, x, y, z, radius) VALUES (?, ?, ?, ?, ?, ?)',
        { label, kind, x, y, z, radius }
    )
end

function DB.deleteSpawnZone(id)
    MySQL.update.await('DELETE FROM nova_npc_spawn_zones WHERE id = ?', { id })
end

-- ── Equipment Vendor Location ───────────────────────────────────────────────────

function DB.getEquipmentVendorLocation()
    local row = MySQL.single.await('SELECT * FROM nova_equipment_vendor WHERE id = 1')
    if not row then return nil end
    return { x = row.x, y = row.y, z = row.z, heading = row.heading, enabled = row.enabled == 1 or row.enabled == true }
end

function DB.setEquipmentVendorLocation(x, y, z, heading)
    local result = MySQL.query.await([[
        INSERT INTO nova_equipment_vendor (id, x, y, z, heading) VALUES (1, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading)
    ]], { x, y, z, heading })
    return result ~= nil and result ~= false
end

function DB.setEquipmentVendorEnabled(enabled)
    local result = MySQL.query.await('UPDATE nova_equipment_vendor SET enabled = ? WHERE id = 1', { enabled and 1 or 0 })
    return result ~= nil and result ~= false
end

-- ── Escort Vehicle Shop Location ─────────────────────────────────────────────────

function DB.getEscortShopLocation()
    local row = MySQL.single.await('SELECT * FROM nova_escort_shop WHERE id = 1')
    if not row then return nil end
    return { x = row.x, y = row.y, z = row.z, heading = row.heading, enabled = row.enabled == 1 or row.enabled == true }
end

function DB.setEscortShopLocation(x, y, z, heading)
    local result = MySQL.query.await([[
        INSERT INTO nova_escort_shop (id, x, y, z, heading) VALUES (1, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading)
    ]], { x, y, z, heading })
    return result ~= nil and result ~= false
end

function DB.setEscortShopEnabled(enabled)
    local result = MySQL.query.await('UPDATE nova_escort_shop SET enabled = ? WHERE id = 1', { enabled and 1 or 0 })
    return result ~= nil and result ~= false
end

-- ── Scheduling Settings (scheduler.lua's UTC offset / poll interval) ─────────────

function DB.getScheduleSettings()
    local row = MySQL.single.await('SELECT * FROM nova_schedule_settings WHERE id = 1')
    if not row then return nil end
    return { utcOffsetHours = row.utc_offset_hours, pollIntervalSeconds = row.poll_interval_seconds }
end

function DB.setScheduleSettings(utcOffsetHours, pollIntervalSeconds)
    local result = MySQL.query.await([[
        INSERT INTO nova_schedule_settings (id, utc_offset_hours, poll_interval_seconds) VALUES (1, ?, ?)
        ON DUPLICATE KEY UPDATE utc_offset_hours = VALUES(utc_offset_hours), poll_interval_seconds = VALUES(poll_interval_seconds)
    ]], { utcOffsetHours, pollIntervalSeconds })
    return result ~= nil and result ~= false
end

-- ── TDM Tournaments ─────────────────────────────────────────────────────────────
-- `inst` is the full tournament instance table (see tournament.lua); the id
-- is stored in the row's own column, not inside the JSON document.

function DB.getTournaments()
    local rows = MySQL.query.await('SELECT * FROM nova_tdm_tournaments ORDER BY id ASC') or {}
    local list = {}
    for _, row in ipairs(rows) do
        local inst = jsonDecode(row.data)
        if type(inst) == 'table' and next(inst) ~= nil then
            inst.id = row.id
            list[#list + 1] = inst
        end
    end
    return list
end

function DB.insertTournament(inst)
    return MySQL.insert.await(
        'INSERT INTO nova_tdm_tournaments (name, status, start_at, series_id, data) VALUES (?, ?, ?, ?, ?)',
        { inst.name, inst.status, inst.schedule and inst.schedule.startAt, inst.seriesId, jsonEncode(inst) }
    )
end

-- Async on purpose: the tournament tick persists after every state change and
-- must never stall the server thread on a slow query.
function DB.saveTournament(inst)
    MySQL.update('UPDATE nova_tdm_tournaments SET name = ?, status = ?, start_at = ?, series_id = ?, data = ? WHERE id = ?', {
        inst.name, inst.status, inst.schedule and inst.schedule.startAt, inst.seriesId, jsonEncode(inst), inst.id,
    })
end

function DB.deleteTournament(id)
    MySQL.update.await('DELETE FROM nova_tdm_tournaments WHERE id = ?', { id })
end

-- ── Convoy Runtime (live event persistence) ─────────────────────────────────────
-- `state` is the full in-memory runtime snapshot (minus non-serializable
-- entity handles) so a resource restart can rebuild an in-progress convoy.

function DB.saveRuntime(convoyId, status, state)
    MySQL.query.await([[
        INSERT INTO nova_convoy_runtime (convoy_id, status, state)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE status = VALUES(status), state = VALUES(state)
    ]], { convoyId, status, jsonEncode(state) })
end

function DB.getActiveRuntimes()
    local rows = MySQL.query.await('SELECT * FROM nova_convoy_runtime')
    local result = {}
    for _, row in ipairs(rows or {}) do
        result[#result + 1] = { convoyId = row.convoy_id, status = row.status, state = jsonDecode(row.state) }
    end
    return result
end

function DB.deleteRuntime(convoyId)
    MySQL.update.await('DELETE FROM nova_convoy_runtime WHERE convoy_id = ?', { convoyId })
end

-- ── Saved Route Templates ─────────────────────────────────────────────────────────

-- Lightweight list for the tablet's picker — full route/checkpoints/airdrops
-- JSON is only fetched on actual import (DB.getSavedRoute), not for every
-- row just to populate a dropdown.
-- point_count means something different per kind — CONVOY counts its route
-- points, HOT_CARGO counts spawn+dropoff zones combined, GANG_AIRDROP counts
-- its drop zones — computed here in Lua after JSON_LENGTH per column rather
-- than one SQL expression, since NULL columns (every row only ever
-- populates the columns matching its own kind) make a single COALESCE/CASE
-- less readable than just picking the right number per kind directly.
-- answered from memory for 15 s and dropped the moment a route is created / changed / deleted
local routesListCache, routesListAt = nil, 0
local function bustRoutesList() routesListCache = nil end
function DB.getSavedRoutesList()
    if routesListCache and GetGameTimer() - routesListAt < 15000 then return routesListCache end
    local list = DB._getSavedRoutesList()
    routesListCache, routesListAt = list, GetGameTimer()
    return list
end
function DB._getSavedRoutesList()
    local rows = MySQL.query.await([[
        SELECT id, name, kind, created_by, created_by_name, created_at,
               JSON_LENGTH(route) AS route_count,
               JSON_LENGTH(spawn_zones) AS spawn_count,
               JSON_LENGTH(dropoff_zones) AS dropoff_count,
               JSON_LENGTH(airdrop_zones) AS airdrop_zone_count,
               JSON_LENGTH(rally_stages) AS rally_stage_count,
               COALESCE(JSON_LENGTH(container_wars, '$.yard.pickups'), 0) AS cw_pickups,
               COALESCE(JSON_LENGTH(container_wars, '$.yard.drops'), 0) AS cw_drops,
               COALESCE(JSON_LENGTH(container_wars, '$.yard.dummies'), 0) AS cw_dummies
        FROM nova_saved_routes ORDER BY name ASC
    ]])
    local result = {}
    for _, row in ipairs(rows or {}) do
        local kind = row.kind or 'CONVOY'
        local pointCount
        if kind == 'HOT_CARGO' then
            pointCount = (tonumber(row.spawn_count) or 0) + (tonumber(row.dropoff_count) or 0)
        elseif kind == 'GANG_AIRDROP' then
            pointCount = tonumber(row.airdrop_zone_count) or 0
        elseif kind == 'CONTAINER_WARS' then
            pointCount = (tonumber(row.cw_pickups) or 0) + (tonumber(row.cw_drops) or 0) + (tonumber(row.cw_dummies) or 0)
        elseif kind == 'GANG_RACE' then
            pointCount = tonumber(row.rally_stage_count) or (tonumber(row.route_count) or 0)
        else
            pointCount = tonumber(row.route_count) or 0
        end
        result[#result + 1] = {
            id = row.id, name = row.name, kind = kind, createdByName = Bridge.StripAccountName(row.created_by_name),
            createdAt = row.created_at, pointCount = pointCount,
            -- Built-in tracks (see SavedRoutes.seedPrebuiltTracks): not deletable.
            prebuilt = row.created_by == 'prebuilt',
        }
    end
    return result
end

function DB.getSavedRoute(id)
    local row = MySQL.single.await('SELECT * FROM nova_saved_routes WHERE id = ?', { id })
    if not row then return nil end
    return {
        id = row.id, name = row.name, kind = row.kind or 'CONVOY',
        route = jsonDecode(row.route), checkpoints = jsonDecode(row.checkpoints), airdrops = jsonDecode(row.airdrops),
        spawnZones = jsonDecode(row.spawn_zones), dropoffZones = jsonDecode(row.dropoff_zones),
        airdropZones = jsonDecode(row.airdrop_zones),
        rallyStages = jsonDecode(row.rally_stages),
        containerWars = jsonDecode(row.container_wars),
        eventProps = jsonDecode(row.event_props),
        createdBy = row.created_by, prebuilt = row.created_by == 'prebuilt',
        createdByName = Bridge.StripAccountName(row.created_by_name), createdAt = row.created_at,
    }
end

-- payload: { route, checkpoints, airdrops } for CONVOY, { spawnZones,
-- dropoffZones } for HOT_CARGO, { airdropZones } for GANG_AIRDROP,
-- { rallyStages, route, checkpoints } for GANG_RACE, { containerWars } for CONTAINER_WARS,
-- plus eventProps / props for all event kinds
function DB.createSavedRoute(name, kind, payload, createdBy, createdByName)
    payload = payload or {}
    return MySQL.insert.await(
        [[INSERT INTO nova_saved_routes
            (name, kind, route, checkpoints, airdrops, spawn_zones, dropoff_zones, airdrop_zones, rally_stages, container_wars, event_props, created_by, created_by_name)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            name, kind,
            jsonEncode(payload.route), jsonEncode(payload.checkpoints), jsonEncode(payload.airdrops),
            jsonEncode(payload.spawnZones), jsonEncode(payload.dropoffZones), jsonEncode(payload.airdropZones),
            jsonEncode(payload.rallyStages), jsonEncode(payload.containerWars),
            jsonEncode(payload.eventProps or payload.props),
            createdBy, createdByName,
        }
    )
end

function DB.updateSavedRoute(id, payload, updatedByName)
    payload = payload or {}
    return MySQL.update.await(
        [[UPDATE nova_saved_routes
          SET name = COALESCE(?, name),
              route = ?, checkpoints = ?, airdrops = ?, spawn_zones = ?, dropoff_zones = ?,
              airdrop_zones = ?, rally_stages = ?, container_wars = ?, event_props = ?,
              created_by_name = COALESCE(?, created_by_name)
          WHERE id = ? AND (created_by IS NULL OR created_by <> 'prebuilt')]],
        {
            payload.name,
            jsonEncode(payload.route), jsonEncode(payload.checkpoints), jsonEncode(payload.airdrops),
            jsonEncode(payload.spawnZones), jsonEncode(payload.dropoffZones), jsonEncode(payload.airdropZones),
            jsonEncode(payload.rallyStages), jsonEncode(payload.containerWars),
            jsonEncode(payload.eventProps or payload.props),
            updatedByName,
            id
        }
    )
end

function DB.deleteSavedRoute(id)
    -- Prebuilt tracks are protected at the SQL level too, whatever calls this.
    MySQL.update.await("DELETE FROM nova_saved_routes WHERE id = ? AND (created_by IS NULL OR created_by <> 'prebuilt')", { id })
end

function DB.deleteAllSavedRoutes()
    MySQL.update.await("DELETE FROM nova_saved_routes WHERE created_by IS NULL OR created_by <> 'prebuilt'")
end

-- ── Civilian Leaderboard Persistence ─────────────────────────────────────────

function DB.recordCivilianResult(playerIdentifier, playerName, playerRole, eventType, eventName, stats)
    if TestRun and TestRun.admin then return false end
    if not playerIdentifier then return false end
    -- Support both (playerIdentifier, playerName, eventType, eventName, stats)
    -- and (playerIdentifier, playerName, playerRole, eventType, eventName, stats)
    if type(eventType) == "table" or (type(playerRole) == "string" and (playerRole == "race" or playerRole == "convoy" or playerRole == "container_wars")) then
        stats = eventName
        eventName = eventType
        eventType = playerRole
        playerRole = "Civilian"
    end
    if not eventType then return false end
    stats = stats or {}
    local wins = tonumber(stats.wins) or 0
    local podiums = tonumber(stats.podiums) or 0
    local participations = tonumber(stats.participations) or 1
    local points = tonumber(stats.points) or 0
    local totalRewards = tonumber(stats.rewards or stats.totalRewards) or 0
    local bestTime = stats.bestTime and tonumber(stats.bestTime) or nil
    playerName = (playerName and playerName ~= '') and playerName or 'Civilian'
    playerRole = (playerRole and playerRole ~= '') and playerRole or 'Civilian'
    eventName = (eventName and eventName ~= '') and eventName or 'Event'

    -- Atomic upsert using ON DUPLICATE KEY UPDATE
    local query = [[
        INSERT INTO `nova_civilian_leaderboard`
            (`player_identifier`, `player_name`, `player_role`, `event_type`, `wins`, `podiums`, `total_participations`, `points`, `total_rewards`, `best_time`, `last_event_name`, `last_participated`)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
        ON DUPLICATE KEY UPDATE
            `player_name` = VALUES(`player_name`),
            `player_role` = VALUES(`player_role`),
            `wins` = `wins` + VALUES(`wins`),
            `podiums` = `podiums` + VALUES(`podiums`),
            `total_participations` = `total_participations` + VALUES(`total_participations`),
            `points` = `points` + VALUES(`points`),
            `total_rewards` = `total_rewards` + VALUES(`total_rewards`),
            `best_time` = CASE
                WHEN VALUES(`best_time`) IS NOT NULL AND (`best_time` IS NULL OR VALUES(`best_time`) < `best_time`) THEN VALUES(`best_time`)
                ELSE `best_time`
            END,
            `last_event_name` = VALUES(`last_event_name`),
            `last_participated` = NOW()
    ]]

    local ok, err = pcall(function()
        MySQL.query.await(query, {
            playerIdentifier, playerName, playerRole, eventType, wins, podiums, participations, points, totalRewards, bestTime, eventName
        })
    end)
    if not ok then
        print(('[NovaConvoy] Error recording civilian result: %s'):format(tostring(err)))
        return false, err
    end
    return true
end

function DB.getCivilianLeaderboard(eventType)
    local query
    local params = {}
    if eventType and eventType ~= 'all' and eventType ~= 'ALL' then
        query = [[
            SELECT
                `id`,
                `player_identifier`,
                `player_name`,
                `player_role`,
                `event_type`,
                `wins`,
                `podiums`,
                `total_participations`,
                `points`,
                `total_rewards`,
                `best_time`,
                `last_event_name`,
                `last_participated`
            FROM `nova_civilian_leaderboard`
            WHERE `event_type` = ?
            ORDER BY `points` DESC, `wins` DESC, `total_participations` DESC
            LIMIT 100
        ]]
        params = { eventType }
    else
        query = [[
            SELECT
                MIN(`id`) as `id`,
                `player_identifier`,
                MAX(`player_name`) as `player_name`,
                MAX(`player_role`) as `player_role`,
                'all' as `event_type`,
                SUM(`wins`) as `wins`,
                SUM(`podiums`) as `podiums`,
                SUM(`total_participations`) as `total_participations`,
                SUM(`points`) as `points`,
                SUM(`total_rewards`) as `total_rewards`,
                MIN(CASE WHEN `best_time` IS NOT NULL AND `best_time` > 0 THEN `best_time` ELSE NULL END) as `best_time`,
                MAX(`last_event_name`) as `last_event_name`,
                MAX(`last_participated`) as `last_participated`
            FROM `nova_civilian_leaderboard`
            GROUP BY `player_identifier`
            ORDER BY `points` DESC, `wins` DESC, `total_participations` DESC
            LIMIT 100
        ]]
    end

    local rows = MySQL.query.await(query, params) or {}
    local results = {}
    for i, r in ipairs(rows) do
        results[i] = {
            id = r.id,
            playerIdentifier = r.player_identifier,
            playerName = Bridge.StripAccountName(r.player_name),
            playerRole = r.player_role or 'Civilian',
            eventType = r.event_type,
            wins = r.wins or 0,
            podiums = r.podiums or 0,
            totalParticipations = r.total_participations or 0,
            points = r.points or 0,
            totalRewards = r.total_rewards or 0,
            bestTime = r.best_time,
            lastEventName = r.last_event_name,
            lastParticipated = r.last_participated,
        }
    end
    return results
end

-- ── Event Banner Configurations ─────────────────────────────────────────────

-- Event banner images live in images/event_announcement_banner_images/ and are served straight from that folder by
-- file name, so dropping a new image with the SAME name over one of them (then restarting the resource) changes the
-- banner everywhere. Rows saved before the folder move still say `banners/x.jpg` - mapped on read, row untouched.
-- A ?v=<resource start time> is appended to local images so the browser re-fetches a replaced file.
local BANNER_DIR = '../images/event_announcement_banner_images/'
local BANNER_VER = tostring(os.time())

local function stripBannerVersion(url)
    if type(url) ~= 'string' then return url end
    return (url:gsub('[?&]v=%d+', ''))
end

local function normalizeBannerUrl(url)
    if type(url) ~= 'string' then return url end
    url = stripBannerVersion(url)
    if url:sub(1, 8) == 'banners/' then url = BANNER_DIR .. url:sub(9) end
    if url:sub(1, #BANNER_DIR) == BANNER_DIR then url = url .. '?v=' .. BANNER_VER end
    return url
end

function DB.getEventBanners()
    local rows = MySQL.query.await('SELECT `event_key`, `image_url`, `pos_x`, `pos_y`, `zoom`, `fit` FROM `nova_event_banner_configs`') or {}
    local map = {}
    for _, r in ipairs(rows) do
        map[r.event_key] = {
            eventKey = r.event_key,
            imageUrl = normalizeBannerUrl(r.image_url),
            posX = tonumber(r.pos_x) or 50.0,
            posY = tonumber(r.pos_y) or 50.0,
            zoom = tonumber(r.zoom) or 1.0,
            fit = r.fit or 'cover',
        }
    end
    local defaults = {
        convoy = { eventKey = 'convoy', imageUrl = '../images/event_announcement_banner_images/convoy.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
        airdrop = { eventKey = 'airdrop', imageUrl = '../images/event_announcement_banner_images/gang_airdrop.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
        hotcargo = { eventKey = 'hotcargo', imageUrl = '../images/event_announcement_banner_images/hot_cargo.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
        rally = { eventKey = 'rally', imageUrl = '../images/event_announcement_banner_images/gang_race.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
        containerwars = { eventKey = 'containerwars', imageUrl = '../images/event_announcement_banner_images/container_wars.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
        tdm = { eventKey = 'tdm', imageUrl = '../images/event_announcement_banner_images/tdm.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
        territory = { eventKey = 'territory', imageUrl = '../images/event_announcement_banner_images/territory.jpg', posX = 50.0, posY = 10.0, zoom = 1.0, fit = 'cover' },
        crackdown = { eventKey = 'crackdown', imageUrl = '../images/event_announcement_banner_images/crackdown.jpg', posX = 50.0, posY = 50.0, zoom = 1.0, fit = 'cover' },
    }
    for k, def in pairs(defaults) do
        if not map[k] then
            def.imageUrl = normalizeBannerUrl(def.imageUrl)
            map[k] = def
        end
    end
    return map
end

function DB.saveEventBanner(eventKey, imageUrl, posX, posY, zoom, fit)
    if not eventKey or type(eventKey) ~= 'string' then return false end
    local cleanKey = eventKey:lower():gsub('%s+', ''):sub(1, 50)
    local img = (imageUrl and type(imageUrl) == 'string' and imageUrl:match('%S')) and stripBannerVersion(imageUrl):sub(1, 2048) or nil
    local px = tonumber(posX) or 50.0
    local py = tonumber(posY) or 50.0
    local zm = tonumber(zoom) or 1.0
    local ft = (fit and type(fit) == 'string') and fit:sub(1, 20) or 'cover'

    MySQL.query.await([[
        INSERT INTO `nova_event_banner_configs` (`event_key`, `image_url`, `pos_x`, `pos_y`, `zoom`, `fit`)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            `image_url` = VALUES(`image_url`),
            `pos_x` = VALUES(`pos_x`),
            `pos_y` = VALUES(`pos_y`),
            `zoom` = VALUES(`zoom`),
            `fit` = VALUES(`fit`)
    ]], { cleanKey, img, px, py, zm, ft })

    return true
end

-- ── Gang XP ledger ──────────────────────────────────────────────────────────────
-- Every function here is the ONLY place the XP tables are written. nova_gang_xp.total_xp is moved and the ledger row
-- written together, so the total can never drift from the ledger.

-- The parameters are never nil: a nil in the middle of a parameter list breaks the query (the list's length becomes
-- ambiguous, so values land in the wrong columns or the call is rejected). Missing values go in as '' / 0 and the INSERT turns
-- them back into NULL with NULLIF. (This is what made every admin XP change — which has no gang id, source id or dedupe key —
-- fail with a bare "ERROR".) The 13th parameter, the gang name for the balance lookup, is added by the caller at index 13.
local function ledgerRow(tx, amount, txType)
    return {
        tx.gangName, tonumber(tx.gangId) or 0, tx.identifier and tostring(tx.identifier) or '',
        tx.playerName and tostring(tx.playerName):sub(1, 100) or '',
        tostring(tx.sourceType or 'OTHER'):sub(1, 30), tx.sourceId and tostring(tx.sourceId):sub(1, 64) or '',
        tx.sourceName and tostring(tx.sourceName):sub(1, 120) or '',
        amount, txType, tx.reason and tostring(tx.reason):sub(1, 255) or '',
        jsonEncode(tx.metadata) or '', tx.dedupeKey and tostring(tx.dedupeKey):sub(1, 190) or '',
    }
end

local LEDGER_INSERT = [[
    INSERT INTO nova_gang_xp_transactions
        (gang_name, gang_id, player_identifier, player_name, source_type, source_id, source_name, xp_amount,
         transaction_type, reason, metadata, dedupe_key, balance_after)
    VALUES (?, NULLIF(?, 0), NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''),
            (SELECT total_xp FROM nova_gang_xp WHERE gang_name = ?))
]]

function DB.gangXpGet(gangName)
    return MySQL.single.await('SELECT gang_name, total_xp, lifetime_xp, updated_at FROM nova_gang_xp WHERE gang_name = ?', { gangName })
end

-- the XP table is read by every leaderboard poll (each open tablet asks every 8-10 s): answered from memory for 3 s, and dropped the
-- instant any XP is written (GangXP calls DB.bustGangXp)
local xpAllCache, xpAllAt = nil, 0
function DB.bustGangXp() xpAllCache = nil end
function DB.gangXpAll()
    local now = GetGameTimer()
    if xpAllCache and now - xpAllAt < 3000 then return xpAllCache end
    xpAllCache, xpAllAt = MySQL.query.await('SELECT gang_name, total_xp, lifetime_xp, updated_at FROM nova_gang_xp') or {}, now
    return xpAllCache
end

-- Positive award. Returns true, newTotal | false, 'DUPLICATE' | false, 'ERROR'.
function DB.gangXpAward(tx)
    local amount = math.floor(tonumber(tx.amount) or 0)
    if amount <= 0 or not tx.gangName then return false, 'INVALID' end
    local values = ledgerRow(tx, amount, tx.txType or 'AWARD')
    values[13] = tx.gangName
    local okCall, ok = pcall(MySQL.transaction.await, {
        { query = [[
            INSERT INTO nova_gang_xp (gang_name, gang_id, total_xp, lifetime_xp) VALUES (?, NULLIF(?, 0), ?, ?)
            ON DUPLICATE KEY UPDATE total_xp = total_xp + VALUES(total_xp), lifetime_xp = lifetime_xp + VALUES(lifetime_xp),
                                    gang_id = COALESCE(VALUES(gang_id), gang_id)
        ]], values = { tx.gangName, tonumber(tx.gangId) or 0, amount, (tx.txType == 'REFUND') and 0 or amount } },
        { query = LEDGER_INSERT, values = values },
    })
    if okCall and ok then
        local row = DB.gangXpGet(tx.gangName)
        return true, row and tonumber(row.total_xp) or amount
    end
    -- the transaction rolled back: either the unique dedupe key already exists (a repeat) or something really failed
    if tx.dedupeKey then
        local existing = MySQL.scalar.await('SELECT id FROM nova_gang_xp_transactions WHERE dedupe_key = ?', { tostring(tx.dedupeKey):sub(1, 190) })
        if existing then return false, 'DUPLICATE' end
    end
    return false, 'ERROR'
end

-- Takes `amount` XP off if (and only if) the gang can pay it AND keeps `minRemaining` afterwards — one guarded UPDATE, so two
-- simultaneous spends can never both succeed on the same XP. Returns true, newTotal | false, 'INSUFFICIENT' | false, 'ERROR'.
function DB.gangXpSpend(tx, minRemaining)
    local amount = math.floor(tonumber(tx.amount) or 0)
    if amount <= 0 or not tx.gangName then return false, 'INVALID' end
    minRemaining = math.max(0, math.floor(tonumber(minRemaining) or 0))
    local affected = MySQL.update.await(
        'UPDATE nova_gang_xp SET total_xp = total_xp - ? WHERE gang_name = ? AND total_xp >= ?',
        { amount, tx.gangName, amount + minRemaining })
    if not affected or affected < 1 then return false, 'INSUFFICIENT' end
    local values = ledgerRow(tx, -amount, tx.txType or 'SPEND')
    values[13] = tx.gangName
    local okCall, res = pcall(MySQL.insert.await, LEDGER_INSERT, values)
    if not okCall or not res then
        -- could not record it: give the XP back rather than lose it silently
        MySQL.update.await('UPDATE nova_gang_xp SET total_xp = total_xp + ? WHERE gang_name = ?', { amount, tx.gangName })
        if tx.dedupeKey then
            local existing = MySQL.scalar.await('SELECT id FROM nova_gang_xp_transactions WHERE dedupe_key = ?', { tostring(tx.dedupeKey):sub(1, 190) })
            if existing then return false, 'DUPLICATE' end
        end
        return false, 'ERROR'
    end
    local row = DB.gangXpGet(tx.gangName)
    return true, row and tonumber(row.total_xp) or 0
end

-- Penalty: like a spend, but never below zero (it takes what the gang has, up to `amount`). Returns true, taken, newTotal.
function DB.gangXpPenalty(tx)
    local amount = math.floor(tonumber(tx.amount) or 0)
    if amount <= 0 or not tx.gangName then return false, 'INVALID' end
    local row = DB.gangXpGet(tx.gangName)
    local have = row and tonumber(row.total_xp) or 0
    local take = math.min(amount, have)
    if take <= 0 then return true, 0, have end
    local copy = {}
    for k, v in pairs(tx) do copy[k] = v end
    copy.amount = take
    copy.txType = copy.txType or 'PENALTY'
    local ok, newTotal = DB.gangXpSpend(copy, 0)
    if not ok then return false, newTotal end
    return true, take, newTotal
end

function DB.gangXpHistory(filters, limit)
    filters = filters or {}
    local where, params = {}, {}
    if filters.gangName then where[#where + 1] = 'gang_name = ?'; params[#params + 1] = filters.gangName end
    if filters.identifier then where[#where + 1] = 'player_identifier = ?'; params[#params + 1] = filters.identifier end
    if filters.sourceType then where[#where + 1] = 'source_type = ?'; params[#params + 1] = filters.sourceType end
    params[#params + 1] = math.max(1, math.min(1000, math.floor(tonumber(limit) or 200)))
    local rows = MySQL.query.await(
        ('SELECT id, gang_name, player_identifier, player_name, source_type, source_id, source_name, xp_amount, transaction_type, reason, balance_after, UNIX_TIMESTAMP(created_at) AS at FROM nova_gang_xp_transactions %s ORDER BY id DESC LIMIT ?')
            :format(#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or ''), params) or {}
    -- in-game character names only: older rows may carry the account (Steam) name in brackets after the character name
    for _, r in ipairs(rows) do r.player_name = Bridge.StripAccountName(r.player_name) end
    return rows
end

-- Individual XP: what each member EARNED (positive rows only — spending XP on an expansion is the gang's, not a "loss" of theirs).
function DB.gangXpPlayerBoard(limit)
    local rows = MySQL.query.await([[
        SELECT player_identifier, MAX(player_name) AS player_name, gang_name, SUM(xp_amount) AS xp, COUNT(*) AS awards
        FROM nova_gang_xp_transactions
        WHERE xp_amount > 0 AND player_identifier IS NOT NULL
        GROUP BY player_identifier, gang_name
        ORDER BY xp DESC LIMIT ?
    ]], { math.max(1, math.min(500, math.floor(tonumber(limit) or 100))) }) or {}
    for _, r in ipairs(rows) do r.player_name = Bridge.StripAccountName(r.player_name) end
    return rows
end

-- ── Territories (persistent state) ──────────────────────────────────────────────

function DB.getTerritorySettings()
    return MySQL.single.await('SELECT xp_per_cell, max_new_cells FROM nova_territory_settings WHERE id = 1')
end

-- xpPerCell / maxNewCells: a number, or -1 = "use the value in config.lua"
function DB.setTerritorySettings(xpPerCell, maxNewCells, by)
    MySQL.query.await([[
        INSERT INTO nova_territory_settings (id, xp_per_cell, max_new_cells, updated_by) VALUES (1, NULLIF(?, -1), NULLIF(?, -1), ?)
        ON DUPLICATE KEY UPDATE xp_per_cell = VALUES(xp_per_cell), max_new_cells = VALUES(max_new_cells), updated_by = VALUES(updated_by)
    ]], { xpPerCell, maxNewCells, by })
end

function DB.territoriesAll()
    local rows = MySQL.query.await('SELECT * FROM nova_territories ORDER BY name ASC') or {}
    for _, r in ipairs(rows) do r.definition = jsonDecode(r.definition); r.custom_geo = jsonDecode(r.custom_geo) end
    return rows
end

-- Saves the painted land of a territory ({ custom = spans, cut = spans }).
function DB.territorySetCustom(territoryId, geo, expectRev)
    local affected = MySQL.update.await(
        'UPDATE nova_territories SET custom_geo = ?, geo_rev = COALESCE(geo_rev, 0) + 1 WHERE territory_id = ?',
        { jsonEncode(geo), territoryId })
    return (affected or 0) > 0
end

-- New territory: starts with `ownerGang` (the event's "starting owner") at level 0. Existing territory: configuration only —
-- owner and expansion level are NEVER touched here. `bumpRev` marks the painted shapes as changed for the live map caches.
function DB.territoryInsert(row)
    MySQL.insert.await([[
        INSERT INTO nova_territories (territory_id, event_id, name, owner_gang, expansion_level, xp_value, color, definition, geo_rev)
        VALUES (?, ?, ?, ?, 0, ?, ?, ?, 1)
    ]], { row.id, row.eventId, row.name, row.ownerGang, row.xpValue or 0, row.color, jsonEncode(row.definition) })
end

function DB.territoryUpdateDefinition(row, bumpRev)
    MySQL.update.await(([[
        UPDATE nova_territories SET event_id = ?, name = ?, xp_value = ?, color = ?, definition = ?%s WHERE territory_id = ?
    ]]):format(bumpRev and ', geo_rev = COALESCE(geo_rev, 0) + 1' or ''),
        { row.eventId, row.name, row.xpValue or 0, row.color, jsonEncode(row.definition), row.id })
end

-- Optimistic owner change: only succeeds if the owner is still `expectedOwner`. Returns true when it applied.
function DB.territorySetOwner(territoryId, newOwner, expectedOwner, newLevel)
    local affected = MySQL.update.await(
        -- '' stands for 'nobody' in both owner parameters: a nil in the parameter list (an unowned territory, the normal first auction)
        -- shortens it and the query fails, which used to leave the winner charged without receiving the territory
        'UPDATE nova_territories SET owner_gang = NULLIF(?, \'\'), expansion_level = ?, geo_rev = COALESCE(geo_rev, 0) + 1 WHERE territory_id = ? AND (owner_gang <=> NULLIF(?, \'\') OR owner_gang IS NULL)',
        { newOwner or '', newLevel or 0, territoryId, expectedOwner or '' })
    return (affected or 0) > 0
end

-- Unlocks the next expansion level for a territory.
function DB.territorySetLevel(territoryId, owner, fromLevel, toLevel)
    local affected = MySQL.update.await(
        -- the level must still be the one the expansion was bought from, so two quick requests cannot both succeed (and be charged)
        'UPDATE nova_territories SET expansion_level = ?, geo_rev = COALESCE(geo_rev, 0) + 1 WHERE territory_id = ? AND (LOWER(owner_gang) = LOWER(?) OR owner_gang IS NULL) AND COALESCE(expansion_level, 0) = ?',
        { toLevel, territoryId, owner or '', fromLevel or 0 })
    return (affected or 0) > 0
end

function DB.territoryDelete(territoryId)
    MySQL.update.await('DELETE FROM nova_territories WHERE territory_id = ?', { territoryId })
end

function DB.territoryHistoryInsert(h)
    return MySQL.insert.await([[
        INSERT INTO nova_territory_history
            (territory_id, territory_name, previous_owner, new_owner, reason, ref_type, ref_id, winner_identifier, winner_name, amount, meta)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], { h.territoryId, h.territoryName, h.previousOwner, h.newOwner, h.reason, h.refType, h.refId,
          h.winnerIdentifier, h.winnerName and tostring(h.winnerName):sub(1, 100) or nil, h.amount, jsonEncode(h.meta) })
end

-- XP the CURRENT owner has net-spent painting this territory since it last changed hands: the most a gang can get back by erasing.
-- (Land painted by an admin, or by a previous owner, was never paid for by this gang.)
function DB.territoryPaintBudget(territoryId, gangName)
    local row = MySQL.single.await([[
        SELECT COALESCE(SUM(amount), 0) AS total FROM nova_territory_history
        WHERE territory_id = ? AND reason = 'PAINT' AND ref_type = 'PAINT' AND new_owner = ?
          AND id > COALESCE((SELECT MAX(id) FROM nova_territory_history WHERE territory_id = ? AND reason NOT IN ('PAINT', 'EXPANSION')), 0)
    ]], { territoryId, gangName or '', territoryId })
    return math.max(0, tonumber(row and row.total) or 0)
end

function DB.territoryHistory(territoryId, limit)
    local sql = 'SELECT id, territory_id, territory_name, previous_owner, new_owner, reason, ref_type, ref_id, winner_identifier, winner_name, amount, UNIX_TIMESTAMP(created_at) AS at FROM nova_territory_history %s ORDER BY id DESC LIMIT ?'
    local params = {}
    local where = ''
    if territoryId then where = 'WHERE territory_id = ?'; params[1] = territoryId end
    params[#params + 1] = math.max(1, math.min(500, math.floor(tonumber(limit) or 100)))
    return MySQL.query.await(sql:format(where), params) or {}
end

-- ── Territory auctions ──────────────────────────────────────────────────────────

-- Opens (or re-finds, after a restart) the result row of one lot. Returns id, status.
function DB.territoryAuctionOpen(row)
    local existing = MySQL.single.await(
        'SELECT id, status FROM nova_territory_auctions WHERE event_id = ? AND run_id = ? AND territory_id = ?',
        { row.eventId, row.runId or 0, row.territoryId })
    if existing then return existing.id, existing.status end
    local id = MySQL.insert.await([[
        INSERT INTO nova_territory_auctions (event_id, run_id, territory_id, territory_name, lot_index, starting_bid, status)
        VALUES (?, ?, ?, ?, ?, ?, 'OPEN')
    ]], { row.eventId, row.runId or 0, row.territoryId, row.territoryName, row.lotIndex or 1, row.startingBid or 0 })
    return id, 'OPEN'
end

function DB.territoryAuctionClose(id, r)
    MySQL.update.await([[
        UPDATE nova_territory_auctions SET status = ?, winning_gang = ?, winning_identifier = ?, winning_player = ?,
            final_bid = ?, bid_count = ?, ended_at = NOW() WHERE id = ?
    ]], { r.status, r.winningGang, r.winningIdentifier, r.winningPlayer and tostring(r.winningPlayer):sub(1, 100) or nil, r.finalBid or 0, r.bidCount or 0, id })
end

-- Async on purpose: a bid must never wait for the database.
function DB.territoryBidInsert(b)
    MySQL.insert('INSERT IGNORE INTO nova_territory_bids (auction_id, bidder_identifier, bidder_name, gang_name, amount, version, req_id) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { b.auctionId, b.identifier, b.name and tostring(b.name):sub(1, 100) or nil, b.gangName, b.amount, b.version, b.reqId and tostring(b.reqId):sub(1, 40) or nil })
end

function DB.territoryAuctionsList(eventId, limit)
    local where, params = '', {}
    if eventId then where = 'WHERE a.event_id = ?'; params[1] = eventId end
    params[#params + 1] = math.max(1, math.min(500, math.floor(tonumber(limit) or 100)))
    -- event_name: the auction's own name (the event it belongs to), so the admin tablet can list "one row per auction"
    return MySQL.query.await(('SELECT a.id, a.event_id, d.name AS event_name, a.run_id, a.territory_id, a.territory_name, a.lot_index, a.starting_bid, a.winning_gang, a.winning_player, a.final_bid, a.bid_count, a.status, UNIX_TIMESTAMP(a.started_at) AS started_at, UNIX_TIMESTAMP(a.ended_at) AS ended_at FROM nova_territory_auctions a LEFT JOIN nova_convoy_definitions d ON d.id = a.event_id %s ORDER BY a.id DESC LIMIT ?'):format(where), params) or {}
end

-- ── Rival challenges / wars ─────────────────────────────────────────────────────

function DB.rivalInsert(r)
    return MySQL.insert.await([[
        INSERT INTO nova_territory_rivals
            (attacker_gang, defender_gang, attacker_territory_id, defender_territory_id, territory_id, status, created_by, created_by_name, created_at)
        VALUES (?, ?, ?, ?, ?, 'PENDING', ?, ?, ?)
    ]], { r.attackerGang, r.defenderGang, r.attackerTerritoryId, r.defenderTerritoryId, r.territoryId, r.createdBy, r.createdByName and tostring(r.createdByName):sub(1, 100) or nil, r.createdAt })
end

function DB.rivalGet(id)
    return MySQL.single.await('SELECT * FROM nova_territory_rivals WHERE id = ?', { id })
end

function DB.rivalList(onlyOpen, limit)
    local sql = 'SELECT * FROM nova_territory_rivals %s ORDER BY id DESC LIMIT ?'
    local where = onlyOpen and "WHERE status IN ('PENDING','ACCEPTED','SCHEDULED','ACTIVE')" or ''
    return MySQL.query.await(sql:format(where), { math.max(1, math.min(500, math.floor(tonumber(limit) or 200))) }) or {}
end

local RIVAL_COLUMNS = {
    status = true, responded_by = true, responded_by_name = true, responded_at = true, war_at = true, war_duration = true,
    penalty_xp = true, scheduled_by = true, started_at = true, ended_at = true, winner_gang = true, result = true, result_note = true,
    territory_id = true, attacker_territory_id = true, response_comment = true, war_zone = true,
}

-- Updates only whitelisted columns. `expectStatus` (optional) makes it a compare-and-set: it only applies while the row
-- still has that status, so two admins / a timer and a click can never both move the same challenge. Returns true if applied.
function DB.rivalUpdate(id, fields, expectStatus)
    local sets, params = {}, {}
    for col, val in pairs(fields or {}) do
        if RIVAL_COLUMNS[col] then
            if val == false then
                sets[#sets + 1] = ('`%s` = NULL'):format(col)   -- false clears the column (a nil is skipped by pairs)
            else
                sets[#sets + 1] = ('`%s` = ?'):format(col)
                params[#params + 1] = val
            end
        end
    end
    if #sets == 0 then return false end
    params[#params + 1] = id
    local sql = 'UPDATE nova_territory_rivals SET ' .. table.concat(sets, ', ') .. ' WHERE id = ?'
    if expectStatus then
        sql = sql .. ' AND status = ?'
        params[#params + 1] = expectStatus
    end
    local affected = MySQL.update.await(sql, params)
    return (affected or 0) > 0
end

-- every way a saved route changes drops the cached list (after the write, so nothing can re-cache the old list in between)
for _, name in ipairs({ 'createSavedRoute', 'updateSavedRoute', 'deleteSavedRoute', 'deleteAllSavedRoutes' }) do
    local orig = DB[name]
    DB[name] = function(...)
        local a, b, c = orig(...)
        bustRoutesList()
        return a, b, c
    end
end

-- a history row added / deleted drops the cached list (after the write)
for _, name in ipairs({ 'insertConvoyHistory', 'deleteConvoyHistory', 'clearConvoyHistory' }) do
    local orig = DB[name]
    DB[name] = function(...)
        local a, b, c = orig(...)
        bustHistory()
        return a, b, c
    end
end

return DB
