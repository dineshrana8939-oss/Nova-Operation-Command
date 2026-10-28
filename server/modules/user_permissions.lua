-- ─── Nova Operations Hub — Staff, Roles & Permissions ─────────────────────────────────────────────────────────
-- ONE permission system for the Admin Tablet. Who can do what is decided here and nowhere else:
--
--   * Real server administrators (ACE permission / Config.CreatorAccess.adminIdentifiers, i.e. Bridge.IsAdmin) hold every
--     permission and can never be edited or locked out from the tablet — they are the ultimate fallback.
--   * Everyone else gets permissions only from their STAFF record (table `nova_user_permissions`): an assigned ROLE
--     (`nova_staff_roles`) plus optional per-person overrides. Gang, faction or job membership never grants and never
--     blocks staff access — the two are independent.
--   * On-duty police jobs (Config.CreatorAccess.jobs) keep the small "escort convoy" baseline they always had; it is
--     merged with whatever staff role they also hold.
--
-- Permissions are 'section.action' keys (e.g. 'gangs.edit'). Every privileged server callback calls
-- UserPermissions.can(source, key); the tablet UI only mirrors the result and is never the security boundary.

UserPermissions = {}

-- ── Catalogue: the sections of the Admin Tablet and the actions that apply to each ────────────────────────────

local ACTION_ORDER = { 'visible', 'view', 'create', 'edit', 'delete', 'manage' }

local SECTIONS = {
    { id = 'dashboard', label = 'Dashboard', group = 'Operations', actions = { 'visible', 'view' },
      hint = 'The live overview of events.' },
    { id = 'create', label = 'Create Event', group = 'Event Management', actions = { 'visible', 'view', 'create', 'edit', 'manage' },
      hint = 'Create / edit events, peds and vendors. Manage = the specialised event kinds (everything except Convoy).' },
    { id = 'convoys', label = 'Manage Events', group = 'Event Management', actions = { 'visible', 'view', 'edit', 'delete', 'manage' },
      hint = 'Manage = start, stop, schedule, reuse, clone and announce events (specialised kinds also need Create Event → Manage).' },
    { id = 'savedroutes', label = 'Saved Routes', group = 'Event Management', actions = { 'visible', 'view', 'create', 'edit', 'delete', 'manage' },
      hint = 'Route templates. Manage = delete every custom template at once.' },
    { id = 'completed', label = 'Event History', group = 'Event Management', actions = { 'visible', 'view', 'delete', 'manage' },
      hint = 'Finished events and reports. Manage = send reports to Discord and clear the whole history.' },
    { id = 'tournaments', label = 'Tournaments', group = 'Tournaments', actions = { 'visible', 'view', 'create', 'edit', 'delete', 'manage' },
      hint = 'TDM tournaments. Manage = shuffle, lock and run matches.' },
    { id = 'tournamenthistory', label = 'Tournament History', group = 'Tournaments', actions = { 'visible', 'view', 'delete' },
      hint = 'Finished tournaments.' },
    { id = 'mapzone', label = 'Map Zone', group = 'Territory System', actions = { 'visible', 'view', 'create', 'edit', 'delete' },
      hint = 'Territories on the map: create, paint (edit), remove (delete).' },
    { id = 'territories', label = 'Auction Results', group = 'Territory System', actions = { 'visible', 'view', 'edit', 'manage' },
      hint = 'View = the auction results page. Edit = adjust Gang XP and the price of painting land (Map Zone). Manage = change a territory owner (Map Zone).' },
    { id = 'rivals', label = 'Rival Wars & Challenges', group = 'Territory System', actions = { 'visible', 'view', 'manage' },
      hint = 'View = see challenges and wars, get the live war alerts and watch a war as it is fought. Manage = schedule, start and cancel wars.' },
    { id = 'gangs', label = 'Gangs & Permissions', group = 'Gangs & Community', actions = { 'visible', 'view', 'create', 'edit', 'delete', 'manage' },
      hint = 'Manage = members, ranks and leaders. This is separate from a player\'s own gang permissions.' },
    { id = 'participants', label = 'Active Participants', group = 'Gangs & Community', actions = { 'visible', 'view' },
      hint = 'Who is in the live events.' },
    { id = 'leaderboard', label = 'Gang Leaderboard', group = 'Leaderboards', actions = { 'visible', 'view' },
      hint = 'Gang standings.' },
    { id = 'civilianleaderboard', label = 'Civilian Leaderboard', group = 'Leaderboards', actions = { 'visible', 'view' },
      hint = 'Civilian standings.' },
    { id = 'announcements', label = 'Announcements', group = 'System & Administration', actions = { 'visible', 'view', 'create', 'edit' },
      hint = 'Create = send server announcements. Edit = change the event banners.' },
    { id = 'worldpeds', label = 'World Peds', group = 'System & Administration', actions = { 'visible', 'view', 'create', 'edit' },
      hint = 'Place and enable the permanent peds.' },
    { id = 'settings', label = 'Settings', group = 'System & Administration', actions = { 'visible', 'view', 'manage' },
      hint = 'Manage = the server-wide scheduling settings.' },
    { id = 'staff', label = 'Staff Management', group = 'System & Administration', actions = { 'visible', 'view', 'create', 'edit', 'delete', 'manage' },
      hint = 'Create = add staff. Edit = role, permissions, enable/disable. Delete = remove. Manage = revoke access and manage roles.' },
    { id = 'guide', label = 'User Guide', group = 'Help', actions = { 'visible', 'view' },
      hint = 'The in-game guide.' },
}

local SECTION_BY_ID = {}
local ALL_KEYS = {}      -- key -> true
local KEY_LIST = {}      -- ordered
for _, s in ipairs(SECTIONS) do
    SECTION_BY_ID[s.id] = s
    local have = {}
    for _, a in ipairs(s.actions) do have[a] = true end
    s.actionSet = have
    for _, a in ipairs(ACTION_ORDER) do
        if have[a] then
            local key = s.id .. '.' .. a
            ALL_KEYS[key] = true
            KEY_LIST[#KEY_LIST + 1] = key
        end
    end
end

local function allKeysOf(sectionId)
    local out = {}
    local s = SECTION_BY_ID[sectionId]
    if s then for _, a in ipairs(s.actions) do out[#out + 1] = sectionId .. '.' .. a end end
    return out
end

-- The shape the rules always hold: a hidden section has nothing; without View there is no create / edit / delete /
-- manage. Applied to every stored role, every override result and every effective set (defence in depth).
local function normalize(set)
    local out = {}
    for _, s in ipairs(SECTIONS) do
        local id = s.id
        if set[id .. '.visible'] and s.actionSet.visible then
            out[id .. '.visible'] = true
            if set[id .. '.view'] and s.actionSet.view then
                out[id .. '.view'] = true
                for _, a in ipairs({ 'create', 'edit', 'delete', 'manage' }) do
                    if s.actionSet[a] and set[id .. '.' .. a] then out[id .. '.' .. a] = true end
                end
            end
        end
    end
    return out
end

local function copySet(set)
    local out = {}
    for k, v in pairs(set or {}) do if v then out[k] = true end end
    return out
end

local function subsetOf(a, b)
    for k, v in pairs(a or {}) do
        if v and not (b and b[k]) then return false, k end
    end
    return true
end

local function setOfAll()
    local out = {}
    for k in pairs(ALL_KEYS) do out[k] = true end
    return out
end

local function keysToSet(list)
    local out = {}
    for _, k in ipairs(list) do if ALL_KEYS[k] then out[k] = true end end
    return out
end

-- On-duty police (Config.CreatorAccess.jobs) have always had this much of the tablet — the escort-convoy tools.
local POLICE_BASELINE = normalize(keysToSet({
    'dashboard.visible', 'dashboard.view',
    'create.visible', 'create.view', 'create.create', 'create.edit',
    'convoys.visible', 'convoys.view', 'convoys.manage',
    'savedroutes.visible', 'savedroutes.view', 'savedroutes.create', 'savedroutes.edit',
    'completed.visible', 'completed.view',
    'participants.visible', 'participants.view',
    'guide.visible', 'guide.view',
}))

-- ── The old flat permission flags (kept readable so existing staff keep working) ──────────────────────────────

local function legacyBase()
    return { 'dashboard.visible', 'dashboard.view', 'guide.visible', 'guide.view' }
end

local function concat(...)
    local out = {}
    for _, list in ipairs({ ... }) do for _, v in ipairs(list) do out[#out + 1] = v end end
    return out
end

local LEGACY_EXPANSION = {
    events_manage = concat(legacyBase(), {
        'create.visible', 'create.view', 'create.create', 'create.edit',
        'convoys.visible', 'convoys.view', 'convoys.edit', 'convoys.manage',
        'savedroutes.visible', 'savedroutes.view', 'savedroutes.create', 'savedroutes.edit',
        'completed.visible', 'completed.view', 'participants.visible', 'participants.view',
    }),
    events_delete = concat(legacyBase(), {
        'convoys.visible', 'convoys.view', 'convoys.delete', 'completed.visible', 'completed.view', 'completed.delete',
        'savedroutes.visible', 'savedroutes.view', 'savedroutes.delete',
    }),
    banners_manage = concat(legacyBase(), allKeysOf('announcements')),
    leaderboards_view = concat(legacyBase(), allKeysOf('leaderboard'), allKeysOf('civilianleaderboard')),
    gangs_manage = concat(legacyBase(), allKeysOf('gangs'), { 'participants.visible', 'participants.view' }),
    tournaments_manage = concat(legacyBase(), allKeysOf('tournaments'), allKeysOf('tournamenthistory')),
    territories_manage = concat(legacyBase(), allKeysOf('mapzone'), allKeysOf('territories'), allKeysOf('rivals')),
    audit_view = concat(legacyBase(), { 'completed.visible', 'completed.view' }),
}

-- What `hasPermission(src, '<old flag>')` means now, for any call site still asking with an old flag name.
local LEGACY_REPRESENTATIVE = {
    events_manage = 'convoys.manage', events_delete = 'convoys.delete', banners_manage = 'announcements.edit',
    leaderboards_view = 'leaderboard.view', gangs_manage = 'gangs.manage', tournaments_manage = 'tournaments.manage',
    territories_manage = 'territories.manage', audit_view = 'completed.view',
}

-- ── Default roles ──────────────────────────────────────────────────────────────────────────────────────────

local function defaultRoleSets()
    local owner = setOfAll()

    local admin = setOfAll()
    for k in pairs(ALL_KEYS) do
        if k:sub(1, 6) == 'staff.' then admin[k] = nil end
    end
    admin['settings.manage'] = nil

    local mod = keysToSet({
        'dashboard.visible', 'dashboard.view',
        'convoys.visible', 'convoys.view', 'convoys.manage',
        'completed.visible', 'completed.view',
        'participants.visible', 'participants.view',
        'savedroutes.visible', 'savedroutes.view',
        'announcements.visible', 'announcements.view', 'announcements.create', 'announcements.edit',
        'leaderboard.visible', 'leaderboard.view', 'civilianleaderboard.visible', 'civilianleaderboard.view',
        'guide.visible', 'guide.view',
    })
    return {
        owner = { name = 'Owner', description = 'Full access to everything, including Staff Management. Protected: cannot be edited or deleted, and the last active Owner can never be removed.', set = owner },
        administrator = { name = 'Administrator', description = 'Runs the server day to day: every section except Staff Management and the scheduling settings.', set = normalize(admin) },
        moderator = { name = 'Moderator', description = 'Operational help: runs Convoy events, reads history, posts announcements. Cannot change gangs, territories or settings.', set = normalize(mod) },
    }
end

-- ── State ──────────────────────────────────────────────────────────────────────────────────────────────────

local cacheByIdentifier = {}   -- identifier -> staff record
local effectiveCache = {}      -- source -> { at, set, info }: effective permissions, reused for a moment (see effectiveFor)
local EFFECTIVE_TTL_MS = 1500
local rolesById = {}           -- id -> role
local isInitialized = false

local function jsonDecode(value)
    if type(value) == 'table' then return value end
    if not value or value == '' then return {} end
    local ok, res = pcall(json.decode, value)
    if ok and type(res) == 'table' then return res end
    return {}
end

local function jsonEncode(value) return json.encode(value or {}) end

local function sanitizeKeyMap(map, allowFalse)
    local out = {}
    if type(map) ~= 'table' then return out end
    for k, v in pairs(map) do
        if type(k) == 'string' and ALL_KEYS[k] then
            if v == true then out[k] = true
            elseif allowFalse and v == false then out[k] = false end
        end
    end
    return out
end

local function roleOf(rec) return rec and rec.roleId and rolesById[rec.roleId] or nil end

local function isOwnerRole(role) return role ~= nil and role.systemKey == 'owner' end

-- the effective permission set a staff record grants right now
local function computeEffective(rec, forceActive)
    if not rec then return {} end
    if rec.status ~= 'active' and not forceActive then return {} end
    local set = {}
    local role = roleOf(rec)
    if role then for k in pairs(role.permissions or {}) do set[k] = true end end
    for k, v in pairs(rec.overrides or {}) do
        if ALL_KEYS[k] then
            if v == true then set[k] = true elseif v == false then set[k] = nil end
        end
    end
    return normalize(set)
end

local function refreshEffective(rec)
    rec.effective = computeEffective(rec)
    effectiveCache = {}
end

local function refreshAllEffective()
    for _, rec in pairs(cacheByIdentifier) do refreshEffective(rec) end
    effectiveCache = {}
end

local function isOwnerRec(rec)
    return rec ~= nil and rec.status == 'active' and isOwnerRole(roleOf(rec))
end

local function countActiveOwners()
    local n = 0
    for _, rec in pairs(cacheByIdentifier) do if isOwnerRec(rec) then n = n + 1 end end
    return n
end

-- ── Player lookup ──────────────────────────────────────────────────────────────────────────────────────────

local function findOnlineSource(identifier)
    if not identifier or identifier == '' then return nil end
    local idLower = string.lower(identifier)
    for _, srcStr in ipairs(GetPlayers()) do
        local src = tonumber(srcStr)
        if src then
            local pIdent = Bridge and Bridge.GetIdentifier and Bridge.GetIdentifier(src)
            if pIdent and string.lower(pIdent) == idLower then return src end
            for _, rawId in ipairs(GetPlayerIdentifiers(srcStr)) do
                if string.lower(rawId) == idLower then return src end
            end
        end
    end
    return nil
end

local function recordForSource(src)
    local id = Bridge.GetIdentifier(src)
    if id and cacheByIdentifier[id] then return cacheByIdentifier[id] end
    for _, rawId in ipairs(GetPlayerIdentifiers(tostring(src))) do
        if cacheByIdentifier[rawId] then return cacheByIdentifier[rawId] end
    end
    return nil
end

local function isSuperAdmin(src)
    return Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission) == true
end

-- the job-based tablet access Bridge.HasCreatorAccess has always granted (police etc.)
local function hasJobAccess(src)
    local access = Config.CreatorAccess
    if not access or not access.jobs then return false end
    local jobGrade = Bridge.GetJobGrade(src)
    if not jobGrade then return false end
    local minGrade = access.jobs[jobGrade.name]
    return minGrade ~= nil and jobGrade.grade >= minGrade
end

-- ── Effective permissions for a player ──────────────────────────────────────────────────────────────────────

-- Returns (set, info). info = { super = bool, staff = record|nil, police = bool }
-- The answer is reused for a moment per player: the live-event code asks about EVERY connected player on every update, and\n-- each fresh answer costs ACE checks, a job lookup and identifier scans. Any staff / role change drops the cache at once, so\n-- a revoke or role change still takes effect immediately.
local function computeEffectiveFor(src)
    if isSuperAdmin(src) then return setOfAll(), { super = true } end
    local set = {}
    local info = { super = false }
    if hasJobAccess(src) then
        info.police = true
        for k in pairs(POLICE_BASELINE) do set[k] = true end
    end
    local rec = recordForSource(src)
    if rec then
        info.staff = rec
        for k in pairs(rec.effective or {}) do set[k] = true end
    end
    return set, info
end

local function effectiveFor(src)
    if src == 0 then return setOfAll(), { super = true } end        -- the server console
    if not src then return {}, { super = false } end                -- no player: nothing
    local now = GetGameTimer()
    local hit = effectiveCache[src]
    if hit and (now - hit.at) >= 0 and (now - hit.at) < EFFECTIVE_TTL_MS then return hit.set, hit.info end
    local set, info = computeEffectiveFor(src)
    effectiveCache[src] = { at = now, set = set, info = info }
    return set, info
end

function UserPermissions.getEffective(src)
    if not isInitialized then UserPermissions.init() end
    return effectiveFor(src)
end

-- THE check. `key` = 'section.action'. Unknown keys are always refused (a typo must never open a door).
function UserPermissions.can(src, key)
    if not isInitialized then UserPermissions.init() end
    if not ALL_KEYS[key] then
        print(('^1[NovaConvoy] UserPermissions.can: unknown permission key "%s"^0'):format(tostring(key)))
        return false
    end
    if src == 0 then return true end                                -- the server console
    if not src then return false end
    local set = effectiveFor(src)
    return set[key] == true
end

function UserPermissions.canAny(src, ...)
    if not isInitialized then UserPermissions.init() end
    if src == 0 then return true end
    if not src then return false end
    local set = effectiveFor(src)         -- one evaluation for all the keys
    for _, key in ipairs({ ... }) do
        if not ALL_KEYS[key] then
            print(('^1[NovaConvoy] UserPermissions.canAny: unknown permission key "%s"^0'):format(tostring(key)))
        elseif set[key] == true then
            return true
        end
    end
    return false
end

-- Old call sites asked for one of the 8 flat flags; both spellings keep working.
function UserPermissions.hasPermission(src, key)
    if ALL_KEYS[key] then return UserPermissions.can(src, key) end
    local rep = LEGACY_REPRESENTATIVE[key]
    if rep then return UserPermissions.can(src, rep) end
    return false
end

-- Anything the tablet can show this player (at least one visible+view section besides the guide).
-- Used by Bridge.HasCreatorAccess; deliberately does NOT include the police baseline (that is the job check there).
function UserPermissions.hasAnyPermission(src)
    if not isInitialized then UserPermissions.init() end
    if src == 0 then return true end
    if not src then return false end
    local _, info = effectiveFor(src)
    if info.super then return true end
    local rec = info.staff
    if not rec or rec.status ~= 'active' then return false end
    for _, s in ipairs(SECTIONS) do
        if s.id ~= 'guide' and rec.effective[s.id .. '.visible'] and rec.effective[s.id .. '.view'] then return true end
    end
    return false
end

-- kept for older callers: the effective key set of a player (or of a stored identifier)
function UserPermissions.getPermissions(sourceOrIdentifier)
    if not isInitialized then UserPermissions.init() end
    if type(sourceOrIdentifier) == 'number' then
        local set = effectiveFor(sourceOrIdentifier)
        return set
    elseif type(sourceOrIdentifier) == 'string' then
        local rec = cacheByIdentifier[sourceOrIdentifier]
        if rec then return copySet(rec.effective) end
    end
    return {}
end

-- what getBootstrap sends to the tablet
function UserPermissions.describe(src)
    if not isInitialized then UserPermissions.init() end
    local set, info = effectiveFor(src)
    local role = info.staff and roleOf(info.staff) or nil
    return {
        perms = set,
        isSuperAdmin = info.super == true,
        staffRole = role and role.name or nil,
        staffStatus = info.staff and info.staff.status or nil,
        police = info.police == true,
    }
end

-- ── Persistence ────────────────────────────────────────────────────────────────────────────────────────────

local function columnExists(tbl, col)
    local n = MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?', { tbl, col })
    return (tonumber(n) or 0) > 0
end

local function ensureSchema()
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
    -- the Staff Management columns (added to the existing table; nothing is dropped or rewritten)
    if not columnExists('nova_user_permissions', 'role_id') then
        MySQL.query.await('ALTER TABLE `nova_user_permissions` ADD COLUMN `role_id` INT NULL DEFAULT NULL')
    end
    if not columnExists('nova_user_permissions', 'status') then
        MySQL.query.await("ALTER TABLE `nova_user_permissions` ADD COLUMN `status` VARCHAR(12) NOT NULL DEFAULT 'active'")
    end
    if not columnExists('nova_user_permissions', 'overrides') then
        MySQL.query.await('ALTER TABLE `nova_user_permissions` ADD COLUMN `overrides` LONGTEXT NULL DEFAULT NULL')
    end
    if not columnExists('nova_user_permissions', 'granted_by_name') then
        MySQL.query.await('ALTER TABLE `nova_user_permissions` ADD COLUMN `granted_by_name` VARCHAR(100) NULL DEFAULT NULL')
    end
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_staff_roles` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(64) NOT NULL,
            `description` VARCHAR(255) NOT NULL DEFAULT '',
            `permissions` LONGTEXT NOT NULL,
            `is_system` TINYINT(1) NOT NULL DEFAULT 0,
            `system_key` VARCHAR(24) NULL DEFAULT NULL,
            `created_by` VARCHAR(100) NULL DEFAULT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uniq_staff_role_name` (`name`)
        )
    ]])
    MySQL.query.await([[
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
        )
    ]])
end

local function loadRoles()
    rolesById = {}
    local rows = MySQL.query.await('SELECT * FROM `nova_staff_roles`') or {}
    for _, row in ipairs(rows) do
        rolesById[row.id] = {
            id = row.id, name = row.name, description = row.description or '',
            permissions = normalize(sanitizeKeyMap(jsonDecode(row.permissions), false)),
            isSystem = (row.is_system == 1 or row.is_system == true),
            systemKey = row.system_key,
        }
    end
end

local function seedSystemRoles()
    local defaults = defaultRoleSets()
    for _, key in ipairs({ 'owner', 'administrator', 'moderator' }) do
        local present = false
        for _, role in pairs(rolesById) do if role.systemKey == key then present = true break end end
        if not present then
            local d = defaults[key]
            -- a custom role that already took the name keeps it; the system role gets a suffix instead of failing
            local name = d.name
            local clash = MySQL.scalar.await('SELECT COUNT(*) FROM `nova_staff_roles` WHERE `name` = ?', { name })
            if (tonumber(clash) or 0) > 0 then name = d.name .. ' (system)' end
            MySQL.insert.await('INSERT INTO `nova_staff_roles` (`name`, `description`, `permissions`, `is_system`, `system_key`, `created_by`) VALUES (?, ?, ?, 1, ?, ?)',
                { name, d.description, jsonEncode(d.set), key, 'system' })
        end
    end
    loadRoles()
    -- Owner is protected: its permissions are always the full set, whatever is stored
    for _, role in pairs(rolesById) do
        if role.systemKey == 'owner' then role.permissions = setOfAll() end
    end
end

local function loadStaff()
    cacheByIdentifier = {}
    local rows = MySQL.query.await("SELECT *, DATE_FORMAT(`created_at`, '%Y-%m-%d %H:%i:%s') AS created_text, DATE_FORMAT(`updated_at`, '%Y-%m-%d %H:%i:%s') AS updated_text FROM `nova_user_permissions`") or {}
    local migrated = 0
    for _, row in ipairs(rows) do
        local overrides
        if row.overrides == nil or row.overrides == '' then
            -- a record from before roles existed: its flat flags become explicit overrides, so nothing it could do is lost
            overrides = {}
            local legacy = jsonDecode(row.permissions)
            for flag, on in pairs(legacy) do
                if on == true and LEGACY_EXPANSION[flag] then
                    for _, k in ipairs(LEGACY_EXPANSION[flag]) do overrides[k] = true end
                end
            end
            MySQL.update.await('UPDATE `nova_user_permissions` SET `overrides` = ?, `status` = IFNULL(NULLIF(`status`, \'\'), \'active\') WHERE `id` = ?', { jsonEncode(overrides), row.id })
            migrated = migrated + 1
        else
            overrides = sanitizeKeyMap(jsonDecode(row.overrides), true)
        end
        local status = row.status
        if status ~= 'active' and status ~= 'disabled' and status ~= 'revoked' then status = 'active' end
        local rec = {
            id = row.id, identifier = row.identifier, serverId = row.server_id,
            playerName = Bridge.StripAccountName and Bridge.StripAccountName(row.player_name) or row.player_name,
            roleId = row.role_id, status = status, overrides = overrides,
            grantedBy = row.granted_by, grantedByName = row.granted_by_name,
            createdAt = row.created_text, updatedAt = row.updated_text,
        }
        refreshEffective(rec)
        cacheByIdentifier[row.identifier] = rec
    end
    if migrated > 0 then
        lib.print.info(('[NovaConvoy] Staff: migrated %d existing permission record(s) to the roles system (their access is unchanged).'):format(migrated))
    end
end

function UserPermissions.init()
    if isInitialized then return end
    ensureSchema()
    loadRoles()
    seedSystemRoles()
    loadStaff()
    isInitialized = true
    local n = 0
    for _ in pairs(cacheByIdentifier) do n = n + 1 end
    lib.print.info(('[NovaConvoy] Staff initialized: %d staff record(s), %d role(s).'):format(n, (function() local c = 0 for _ in pairs(rolesById) do c = c + 1 end return c end)()))
end

-- ── Audit log ──────────────────────────────────────────────────────────────────────────────────────────────

local function actorName(src)
    if not src or src == 0 then return 'Console' end
    return Bridge.GetPlayerName(src) or GetPlayerName(tostring(src)) or ('Player ' .. tostring(src))
end

local function actorIdent(src)
    if not src or src == 0 then return 'console' end
    return Bridge.GetIdentifier(src) or tostring(src)
end

local staffLogCount = 0
local function logAction(src, action, targetIdentifier, targetName, details)
    details = tostring(details or ''):sub(1, 480)
    MySQL.insert('INSERT INTO `nova_staff_log` (`actor_identifier`, `actor_name`, `action`, `target_identifier`, `target_name`, `details`) VALUES (?, ?, ?, ?, ?, ?)',
        { actorIdent(src), actorName(src), action, targetIdentifier, targetName, details })
    print(('[NovaConvoy][Staff] %s (%s) %s %s: %s'):format(actorName(src), actorIdent(src), action, tostring(targetName or targetIdentifier or '-'), details))
    -- keep the table bounded: the trim is a sub-query over the whole table, so it runs on every 25th entry, not on every one
    staffLogCount = (staffLogCount or 0) + 1
    if staffLogCount % 25 ~= 1 then return end
    MySQL.query('DELETE FROM `nova_staff_log` WHERE `id` <= (SELECT `id` FROM (SELECT `id` FROM `nova_staff_log` ORDER BY `id` DESC LIMIT 1 OFFSET 2000) t)')
end

-- ── Live updates ───────────────────────────────────────────────────────────────────────────────────────────

-- Tells the affected player (so their tablet re-reads its permissions, or closes if access is gone) and every online
-- staff member who can see the Staff Management lists (so those refresh).
local function notifyChanged(identifier)
    effectiveCache = {}        -- any staff / role change: nobody keeps a stale answer
    local target = identifier and findOnlineSource(identifier) or nil
    if target then TriggerClientEvent('nova_convoytruck:client:staffChanged', target, true) end
    for _, srcStr in ipairs(GetPlayers()) do
        local src = tonumber(srcStr)
        if src and src ~= target and UserPermissions.can(src, 'staff.view') then
            TriggerClientEvent('nova_convoytruck:client:staffChanged', src, false)
        end
    end
end

-- ── Management operations ──────────────────────────────────────────────────────────────────────────────────

local function fail(msg, extra)
    local r = { ok = false, error = msg }
    if extra then for k, v in pairs(extra) do r[k] = v end end
    return r
end

local DENIED = 'You are not authorized to do that.'

-- who is acting, and what they may hand out
local function actorContext(src)
    local set, info = effectiveFor(src)
    local ctx = { src = src, identifier = actorIdent(src), set = set, super = info.super == true, staff = info.staff }
    ctx.owner = isOwnerRec(info.staff)
    ctx.privileged = ctx.super or ctx.owner
    return ctx
end

local function lockInfo(ctx, rec)
    if rec.identifier == ctx.identifier then return true, 'You cannot change your own access.' end
    if isOwnerRec(rec) and not ctx.privileged then return true, 'Only an Owner or server administrator can change an Owner.' end
    if not ctx.privileged then
        local ok = subsetOf(computeEffective(rec, true), ctx.set)
        if not ok then return true, 'This person holds permissions you do not have.' end
    end
    return false, nil
end

local function roleUsable(ctx, role)
    if not role then return false, 'That role no longer exists.' end
    if isOwnerRole(role) and not ctx.privileged then return false, 'Only an Owner or server administrator can assign the Owner role.' end
    if not ctx.privileged then
        local ok, missing = subsetOf(role.permissions, ctx.set)
        if not ok then return false, ('You cannot grant a role with permissions you do not have (%s).'):format(tostring(missing)) end
    end
    return true
end

local function countByRole()
    local counts = {}
    for _, rec in pairs(cacheByIdentifier) do
        if rec.roleId then counts[rec.roleId] = (counts[rec.roleId] or 0) + 1 end
    end
    return counts
end

local function roleView(ctx, role, counts)
    local locked, why = false, nil
    if isOwnerRole(role) then
        locked, why = true, 'The Owner role is protected and always has every permission.'
    elseif not ctx.privileged and not subsetOf(role.permissions, ctx.set) then
        locked, why = true, 'This role holds permissions you do not have.'
    end
    -- `locked` = this caller cannot EDIT / delete the role; `assignable` = this caller may GIVE it to someone
    -- (an Owner or server admin can hand out the Owner role even though nobody can edit it)
    local assignable = roleUsable(ctx, role) == true
    return {
        id = role.id, name = role.name, description = role.description, permissions = copySet(role.permissions),
        isSystem = role.isSystem, systemKey = role.systemKey, staffCount = counts[role.id] or 0,
        locked = locked, lockedReason = why, assignable = assignable,
    }
end

local function playerFacts(onlineSrc)
    if not onlineSrc then return nil, nil end
    local gang, job
    if GangService and GangService.GetPlayerGang then
        local ok, g = pcall(GangService.GetPlayerGang, onlineSrc)
        if ok and type(g) == 'table' then gang = g.label or g.name end
    end
    local okj, jg = pcall(Bridge.GetJobGrade, onlineSrc)
    if okj and type(jg) == 'table' then job = jg.label or jg.name end
    if gang == 'none' then gang = nil end
    return gang, job
end

local function memberView(ctx, rec)
    local onlineSrc = findOnlineSource(rec.identifier)
    local role = roleOf(rec)
    local locked, why = lockInfo(ctx, rec)
    local gang, job = playerFacts(onlineSrc)
    local overridesCopy = {}
    for k, v in pairs(rec.overrides or {}) do overridesCopy[k] = v end
    return {
        identifier = rec.identifier,
        playerName = (onlineSrc and Bridge.GetPlayerName(onlineSrc)) or rec.playerName or 'Unknown Player',
        serverId = onlineSrc or nil, isOnline = onlineSrc ~= nil,
        roleId = rec.roleId, roleName = role and role.name or nil,
        status = rec.status, overrides = overridesCopy,
        effective = copySet(computeEffective(rec, true)),
        grantedByName = rec.grantedByName, createdAt = rec.createdAt, updatedAt = rec.updatedAt,
        isSelf = rec.identifier == ctx.identifier, isOwner = isOwnerRole(role),
        locked = locked, lockedReason = why, gang = gang, job = job,
    }
end

local function sectionList()
    local out = {}
    for _, s in ipairs(SECTIONS) do
        out[#out + 1] = { id = s.id, label = s.label, group = s.group, hint = s.hint, actions = s.actions }
    end
    return out
end

local function persistRecord(rec)
    MySQL.update.await('UPDATE `nova_user_permissions` SET `role_id` = ?, `status` = ?, `overrides` = ?, `player_name` = ?, `server_id` = ?, `granted_by` = ?, `granted_by_name` = ? WHERE `identifier` = ?',
        { rec.roleId, rec.status, jsonEncode(rec.overrides), rec.playerName, rec.serverId, rec.grantedBy, rec.grantedByName, rec.identifier })
    local row = MySQL.single.await("SELECT DATE_FORMAT(`updated_at`, '%Y-%m-%d %H:%i:%s') AS u FROM `nova_user_permissions` WHERE `identifier` = ?", { rec.identifier })
    if row then rec.updatedAt = row.u end
end

local function describeOverrides(overrides)
    local on, off = 0, 0
    for _, v in pairs(overrides or {}) do if v == true then on = on + 1 elseif v == false then off = off + 1 end end
    return on, off
end

-- ── Public operations (each re-checks the permission itself) ────────────────────────────────────────────────

function UserPermissions.getOverview(src)
    if not UserPermissions.can(src, 'staff.view') then return fail(DENIED) end
    local ctx = actorContext(src)
    local counts = countByRole()
    local roles, staff = {}, {}
    for _, role in pairs(rolesById) do roles[#roles + 1] = roleView(ctx, role, counts) end
    table.sort(roles, function(a, b)
        if a.isSystem ~= b.isSystem then return a.isSystem end
        local order = { owner = 1, administrator = 2, moderator = 3 }
        local ao, bo = order[a.systemKey or ''] or 9, order[b.systemKey or ''] or 9
        if ao ~= bo then return ao < bo end
        return a.name:lower() < b.name:lower()
    end)
    local stats = { total = 0, active = 0, disabled = 0, revoked = 0, roles = #roles }
    for _, rec in pairs(cacheByIdentifier) do
        stats.total = stats.total + 1
        stats[rec.status] = (stats[rec.status] or 0) + 1
        staff[#staff + 1] = memberView(ctx, rec)
    end
    table.sort(staff, function(a, b)
        if a.isOnline ~= b.isOnline then return a.isOnline end
        return (a.playerName or ''):lower() < (b.playerName or ''):lower()
    end)
    -- Owners: every staff record holding the Owner role, plus the server administrators (ACE `Config.CreatorAccess.adminPermission`)
    -- who are online right now. Server administrators are not stored as staff (they hold full access by definition), so without
    -- this they never showed up anywhere in the Staff section. They are read-only here.
    local owners, seenOwner = {}, {}
    for _, m in ipairs(staff) do
        if m.isOwner then
            owners[#owners + 1] = { identifier = m.identifier, playerName = m.playerName, serverId = m.serverId, isOnline = m.isOnline,
                kind = 'owner', roleName = m.roleName or 'Owner', status = m.status, isSelf = m.isSelf, gang = m.gang, job = m.job }
            seenOwner[m.identifier] = true
        end
    end
    for _, p in ipairs(Bridge.GetPlayers()) do
        if isSuperAdmin(p) then
            local ident = Bridge.GetIdentifier(p)
            if ident and ident ~= '' and not seenOwner[ident] then
                local gang, job = playerFacts(p)
                owners[#owners + 1] = { identifier = ident, playerName = Bridge.GetPlayerName(p) or ('Player %d'):format(p), serverId = p, isOnline = true,
                    kind = 'serverAdmin', roleName = 'Server administrator', status = 'active', isSelf = ident == ctx.identifier, gang = gang, job = job }
                seenOwner[ident] = true
            end
        end
    end
    table.sort(owners, function(a, b)
        if a.kind ~= b.kind then return a.kind == 'owner' end
        return (a.playerName or ''):lower() < (b.playerName or ''):lower()
    end)
    return {
        ok = true, stats = stats, staff = staff, owners = owners, roles = roles, sections = sectionList(),
        me = {
            identifier = ctx.identifier, isSuperAdmin = ctx.super, isOwner = ctx.owner,
            canCreate = UserPermissions.can(src, 'staff.create'), canEdit = UserPermissions.can(src, 'staff.edit'),
            canDelete = UserPermissions.can(src, 'staff.delete'), canManage = UserPermissions.can(src, 'staff.manage'),
            keys = copySet(ctx.set),
        },
    }
end

function UserPermissions.getOnlinePlayers(src)
    if not UserPermissions.can(src, 'staff.create') then return fail(DENIED) end
    local list = {}
    for _, p in ipairs(Bridge.GetPlayers()) do
        local ident = Bridge.GetIdentifier(p)
        if ident and ident ~= '' then
            local gang, job = playerFacts(p)
            list[#list + 1] = {
                serverId = p, name = Bridge.GetPlayerName(p) or ('Player %d'):format(p), identifier = ident,
                isStaff = cacheByIdentifier[ident] ~= nil, gang = gang, job = job,
            }
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return { ok = true, players = list }
end

function UserPermissions.addStaff(src, serverIdOrIdentifier, roleId)
    if not UserPermissions.can(src, 'staff.create') then return fail(DENIED) end
    local ctx = actorContext(src)

    local target = tonumber(serverIdOrIdentifier)
    if not target or target <= 0 or target ~= math.floor(target) then
        return fail('Choose an online player or enter a valid server ID.')
    end
    local ping = GetPlayerPing(tostring(target))
    if not ping or ping <= 0 then return fail(('Player with server ID %d is not online.'):format(target)) end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier or identifier == '' then
        local raw = GetPlayerIdentifiers(tostring(target))
        identifier = raw and raw[1] or nil
    end
    if not identifier or identifier == '' or #identifier > 64 or not identifier:match('^[%w_:%.%-]+$') then
        return fail('That player has no valid identifier and cannot be added.')
    end
    if cacheByIdentifier[identifier] then
        local existing = cacheByIdentifier[identifier]
        if existing.status == 'revoked' then return fail('This player is already in the staff list with access revoked. Use Grant access instead.') end
        return fail('This player is already staff.')
    end
    if isSuperAdmin(target) then
        return fail('This player is already a server administrator with full access.')
    end

    roleId = tonumber(roleId)
    local role = roleId and rolesById[roleId] or nil
    local okRole, roleErr = roleUsable(ctx, role)
    if not okRole then return fail(roleErr) end

    local name = Bridge.GetPlayerName(target) or GetPlayerName(tostring(target)) or ('Player #%d'):format(target)
    local aName = actorName(src)
    local aIdent = actorIdent(src)
    MySQL.insert.await('INSERT INTO `nova_user_permissions` (`identifier`, `server_id`, `player_name`, `permissions`, `granted_by`, `granted_by_name`, `role_id`, `status`, `overrides`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { identifier, target, name, '{}', aIdent, aName, role.id, 'active', '{}' })
    local rec = {
        identifier = identifier, serverId = target, playerName = name, roleId = role.id, status = 'active', overrides = {},
        grantedBy = aIdent, grantedByName = aName,
    }
    cacheByIdentifier[identifier] = rec
    refreshEffective(rec)
    local row = MySQL.single.await("SELECT `id`, DATE_FORMAT(`created_at`, '%Y-%m-%d %H:%i:%s') AS c, DATE_FORMAT(`updated_at`, '%Y-%m-%d %H:%i:%s') AS u FROM `nova_user_permissions` WHERE `identifier` = ?", { identifier })
    if row then rec.id, rec.createdAt, rec.updatedAt = row.id, row.c, row.u end

    logAction(src, 'staff.add', identifier, name, ('Added as staff with the %s role.'):format(role.name))
    notifyChanged(identifier)
    return { ok = true, member = memberView(ctx, rec) }
end

local function resolveTarget(ctx, identifier)
    if type(identifier) ~= 'string' or identifier == '' then return nil, fail('Invalid staff member.') end
    local rec = cacheByIdentifier[identifier]
    if not rec then return nil, fail('That staff member no longer exists.') end
    local locked, why = lockInfo(ctx, rec)
    if locked then return nil, fail(why) end
    return rec
end

-- would this change leave the server without an active Owner?
local function wouldOrphanOwners(rec, newRoleId, newStatus)
    if not isOwnerRec(rec) then return false end
    local stillOwner = (newStatus or rec.status) == 'active' and isOwnerRole(rolesById[newRoleId or rec.roleId])
    return (not stillOwner) and countActiveOwners() <= 1
end

function UserPermissions.updateStaff(src, identifier, patch)
    if not UserPermissions.can(src, 'staff.edit') then return fail(DENIED) end
    if type(patch) ~= 'table' then return fail('Nothing to change.') end
    local ctx = actorContext(src)
    local rec, err = resolveTarget(ctx, identifier)
    if not rec then return err end

    local newRoleId = rec.roleId
    local newOverrides = rec.overrides
    local notes = {}

    if patch.roleId ~= nil then
        local rid = tonumber(patch.roleId)
        local role = rid and rolesById[rid] or nil
        local okRole, roleErr = roleUsable(ctx, role)
        if not okRole then return fail(roleErr) end
        if wouldOrphanOwners(rec, rid, nil) then return fail('This is the last active Owner. Make someone else an Owner first.') end
        if rid ~= rec.roleId then
            local old = roleOf(rec)
            notes[#notes + 1] = ('role %s → %s'):format(old and old.name or 'none', role.name)
        end
        newRoleId = rid
    end

    if patch.overrides ~= nil then
        newOverrides = sanitizeKeyMap(patch.overrides, true)
        if isOwnerRole(rolesById[newRoleId]) then
            if next(newOverrides) ~= nil then return fail('The Owner role always has every permission and cannot have overrides.') end
        end
        local on, off = describeOverrides(newOverrides)
        notes[#notes + 1] = ('permission overrides: %d granted, %d denied'):format(on, off)
    end

    -- nobody can hand out more than they hold
    local preview = { roleId = newRoleId, overrides = newOverrides, status = rec.status }
    if not ctx.privileged then
        local ok, missing = subsetOf(computeEffective(preview, true), ctx.set)
        if not ok then return fail(('You cannot grant a permission you do not have (%s).'):format(tostring(missing))) end
    end

    local roleChanged = newRoleId ~= rec.roleId
    rec.roleId, rec.overrides = newRoleId, newOverrides
    rec.grantedBy, rec.grantedByName = actorIdent(src), actorName(src)
    refreshEffective(rec)
    persistRecord(rec)
    logAction(src, roleChanged and 'staff.role' or 'staff.permissions', rec.identifier, rec.playerName, #notes > 0 and table.concat(notes, '; ') or 'No change.')
    notifyChanged(rec.identifier)
    return { ok = true, member = memberView(ctx, rec) }
end

function UserPermissions.setStatus(src, identifier, status)
    if status ~= 'active' and status ~= 'disabled' and status ~= 'revoked' then return fail('Invalid status.') end
    local ctx = actorContext(src)
    local rec, err = resolveTarget(ctx, identifier)
    if not rec then return err end
    if rec.status == status then return { ok = true, member = memberView(ctx, rec) } end

    -- turning access fully on/off for the tablet (revoke / grant) is a Manage action; enable/disable is Edit
    local needsManage = (status == 'revoked') or (rec.status == 'revoked')
    if not UserPermissions.can(src, needsManage and 'staff.manage' or 'staff.edit') then return fail(DENIED) end

    if wouldOrphanOwners(rec, nil, status) then return fail('This is the last active Owner. Make someone else an Owner first.') end
    if status == 'active' and not ctx.privileged then
        local ok, missing = subsetOf(computeEffective(rec, true), ctx.set)
        if not ok then return fail(('You cannot re-enable someone who holds a permission you do not have (%s).'):format(tostring(missing))) end
    end

    local before = rec.status
    rec.status = status
    refreshEffective(rec)
    persistRecord(rec)
    local verb = { active = 'Access enabled', disabled = 'Access disabled', revoked = 'Admin Tablet access revoked' }
    logAction(src, 'staff.status', rec.identifier, rec.playerName, ('%s (was %s).'):format(verb[status], before))
    notifyChanged(rec.identifier)
    return { ok = true, member = memberView(ctx, rec) }
end

function UserPermissions.removeStaff(src, identifier)
    if not UserPermissions.can(src, 'staff.delete') then return fail(DENIED) end
    local ctx = actorContext(src)
    local rec, err = resolveTarget(ctx, identifier)
    if not rec then return err end
    if wouldOrphanOwners(rec, nil, 'removed') then return fail('This is the last active Owner. Make someone else an Owner first.') end

    -- only the staff record goes: the player's character, gang, faction and job are not touched
    MySQL.query.await('DELETE FROM `nova_user_permissions` WHERE `identifier` = ?', { rec.identifier })
    cacheByIdentifier[rec.identifier] = nil
    logAction(src, 'staff.remove', rec.identifier, rec.playerName, 'Removed from the staff list.')
    notifyChanged(rec.identifier)
    return { ok = true }
end

local function cleanRoleName(raw)
    local name = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    if #name < 2 or #name > 32 then return nil, 'Role name must be 2–32 characters.' end
    if not name:match('^[%w%s%-%._&\'()]+$') then return nil, 'Role name has characters that are not allowed.' end
    return name
end

function UserPermissions.saveRole(src, input)
    if not UserPermissions.can(src, 'staff.manage') then return fail(DENIED) end
    if type(input) ~= 'table' then return fail('Invalid role.') end
    local ctx = actorContext(src)

    local name, nameErr = cleanRoleName(input.name)
    if not name then return fail(nameErr) end
    local description = tostring(input.description or ''):sub(1, 255)
    local newPerms = normalize(sanitizeKeyMap(input.permissions, false))

    local existing = tonumber(input.id) and rolesById[tonumber(input.id)] or nil
    if input.id ~= nil and not existing then return fail('That role no longer exists.') end

    for _, other in pairs(rolesById) do
        if other.name:lower() == name:lower() and (not existing or other.id ~= existing.id) then
            return fail('A role with that name already exists.')
        end
    end

    if existing then
        if isOwnerRole(existing) then return fail('The Owner role is protected and cannot be changed.') end
        if existing.isSystem and name ~= existing.name then return fail('Default roles cannot be renamed.') end
        if not ctx.privileged then
            -- editing a role means being able to hold everything it holds now and everything you add
            if not subsetOf(existing.permissions, ctx.set) then return fail('This role holds permissions you do not have, so you cannot edit it.') end
        end
    end
    if not ctx.privileged then
        local ok, missing = subsetOf(newPerms, ctx.set)
        if not ok then return fail(('You cannot grant a permission you do not have (%s).'):format(tostring(missing))) end
    end

    local role
    if existing then
        MySQL.update.await('UPDATE `nova_staff_roles` SET `name` = ?, `description` = ?, `permissions` = ? WHERE `id` = ?', { name, description, jsonEncode(newPerms), existing.id })
        existing.name, existing.description, existing.permissions = name, description, newPerms
        role = existing
        refreshAllEffective()
        logAction(src, 'role.update', nil, role.name, 'Role permissions updated.')
        -- every member holding this role gets new permissions: tell the ones who are online
        for _, rec in pairs(cacheByIdentifier) do
            if rec.roleId == role.id then notifyChanged(rec.identifier) end
        end
    else
        local id = MySQL.insert.await('INSERT INTO `nova_staff_roles` (`name`, `description`, `permissions`, `is_system`, `created_by`) VALUES (?, ?, ?, 0, ?)',
            { name, description, jsonEncode(newPerms), actorName(src) })
        role = { id = id, name = name, description = description, permissions = newPerms, isSystem = false, systemKey = nil }
        rolesById[id] = role
        logAction(src, 'role.create', nil, role.name, 'Custom role created.')
        notifyChanged(nil)
    end
    return { ok = true, role = roleView(ctx, role, countByRole()) }
end

function UserPermissions.deleteRole(src, roleId, reassignRoleId)
    if not UserPermissions.can(src, 'staff.manage') then return fail(DENIED) end
    local ctx = actorContext(src)
    local role = rolesById[tonumber(roleId) or -1]
    if not role then return fail('That role no longer exists.') end
    if role.isSystem then return fail('Default roles cannot be deleted.') end
    if not ctx.privileged and not subsetOf(role.permissions, ctx.set) then return fail('This role holds permissions you do not have, so you cannot delete it.') end

    local members = {}
    for _, rec in pairs(cacheByIdentifier) do if rec.roleId == role.id then members[#members + 1] = rec end end

    local target
    if #members > 0 then
        target = tonumber(reassignRoleId) and rolesById[tonumber(reassignRoleId)] or nil
        if not tonumber(reassignRoleId) then
            return fail(('%d staff member(s) use this role. Choose a role to move them to.'):format(#members), { code = 'NEEDS_REASSIGN', staffCount = #members })
        end
        if not target or target.id == role.id then return fail('Choose a different role to move them to.') end
        local okRole, roleErr = roleUsable(ctx, target)
        if not okRole then return fail(roleErr) end
        if isOwnerRole(target) == false then
            for _, rec in ipairs(members) do
                if isOwnerRec(rec) then return fail('An Owner cannot be moved to a lower role this way.') end
            end
        end
    end

    for _, rec in ipairs(members) do
        rec.roleId = target.id
        rec.grantedBy, rec.grantedByName = actorIdent(src), actorName(src)
        refreshEffective(rec)
        persistRecord(rec)
    end
    MySQL.query.await('DELETE FROM `nova_staff_roles` WHERE `id` = ?', { role.id })
    rolesById[role.id] = nil
    logAction(src, 'role.delete', nil, role.name, #members > 0 and ('Role deleted; %d staff moved to %s.'):format(#members, target.name) or 'Role deleted.')
    for _, rec in ipairs(members) do notifyChanged(rec.identifier) end
    if #members == 0 then notifyChanged(nil) end
    return { ok = true }
end

function UserPermissions.getLog(src, limit)
    if not UserPermissions.can(src, 'staff.view') then return fail(DENIED) end
    limit = math.max(1, math.min(tonumber(limit) or 100, 500))
    local rows = MySQL.query.await("SELECT `id`, `actor_identifier`, `actor_name`, `action`, `target_identifier`, `target_name`, `details`, DATE_FORMAT(`created_at`, '%Y-%m-%d %H:%i:%s') AS created_text FROM `nova_staff_log` ORDER BY `id` DESC LIMIT ?", { limit }) or {}
    local entries = {}
    for _, r in ipairs(rows) do
        entries[#entries + 1] = {
            id = r.id, actorName = r.actor_name, actorIdentifier = r.actor_identifier, action = r.action,
            targetName = r.target_name, targetIdentifier = r.target_identifier, details = r.details, createdAt = r.created_text,
        }
    end
    return { ok = true, entries = entries }
end

-- ── NUI callbacks ──────────────────────────────────────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:staff:getOverview', function(source) return UserPermissions.getOverview(source) end)
lib.callback.register('nova_convoytruck:staff:getOnlinePlayers', function(source) return UserPermissions.getOnlinePlayers(source) end)
lib.callback.register('nova_convoytruck:staff:add', function(source, who, roleId) return UserPermissions.addStaff(source, who, roleId) end)
lib.callback.register('nova_convoytruck:staff:update', function(source, identifier, patch) return UserPermissions.updateStaff(source, identifier, patch) end)
lib.callback.register('nova_convoytruck:staff:setStatus', function(source, identifier, status) return UserPermissions.setStatus(source, identifier, status) end)
lib.callback.register('nova_convoytruck:staff:remove', function(source, identifier) return UserPermissions.removeStaff(source, identifier) end)
lib.callback.register('nova_convoytruck:staff:saveRole', function(source, role) return UserPermissions.saveRole(source, role) end)
lib.callback.register('nova_convoytruck:staff:deleteRole', function(source, roleId, reassignRoleId) return UserPermissions.deleteRole(source, roleId, reassignRoleId) end)
lib.callback.register('nova_convoytruck:staff:getLog', function(source, limit) return UserPermissions.getLog(source, limit) end)

AddEventHandler('playerDropped', function() effectiveCache[source] = nil end)

-- A player who connects while staff gets nothing pushed: their tablet reads its permissions on open. A player who
-- leaves just stops being "online" in the lists.

-- exposed for tests / other modules
UserPermissions._catalog = { sections = SECTIONS, keys = KEY_LIST, policeBaseline = POLICE_BASELINE }
UserPermissions._normalize = normalize

return UserPermissions
