-- ─── Nova Convoy — Convoy Definition Registry ─────────────────────────────────
-- Server-only. Phase 1 scope: persisted convoy DEFINITIONS (drafts built in the
-- tablet) with server-side validation. Live event runtime (spawning trucks,
-- checkpoints, NPCs) is a later phase and does not touch this file's data.

ConvoyManager = {}

local cache = {} -- [id] = definition, refreshed from DB on boot and on every write

local function countActiveDefinitions()
    local count = 0
    for _, def in pairs(cache) do
        if def.status ~= 'COMPLETED' and def.status ~= 'CANCELLED' then
            count = count + 1
        end
    end
    return count
end

-- The START and DESTINATION points can carry the same dressing a checkpoint does (placed props and vehicles, NPC police / army guards).
-- While the tablet edits it, it rides in the checkpoints list flagged supportOnly; it is STORED in its own list (pointSupport), so it can
-- never be counted, timed or numbered as a checkpoint. Returns the real checkpoints and the support entries.
local function splitCheckpointList(input)
    local cps, support, seen = {}, {}, {}
    local function addSupport(entry)
        if type(entry) ~= 'table' or entry.routePointId == nil then return end
        local key = tostring(entry.routePointId)
        if seen[key] then return end
        seen[key] = true
        local copy = {}
        for k, v in pairs(entry) do if k ~= 'supportOnly' then copy[k] = v end end
        support[#support + 1] = copy
    end
    for _, cp in ipairs(type(input.checkpoints) == 'table' and input.checkpoints or {}) do
        if type(cp) == 'table' then
            if cp.supportOnly == true then addSupport(cp) else cps[#cps + 1] = cp end
        end
    end
    for _, ps in ipairs(type(input.pointSupport) == 'table' and input.pointSupport or {}) do addSupport(ps) end
    return cps, support
end

local function clamp(value, min, max)
    value = tonumber(value) or min
    if value < min then return min end
    if value > max then return max end
    return value
end

local function findSourceByIdentifier(identifier)
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Bridge.GetIdentifier(src) == identifier then return src end
    end
    return nil
end

-- One-time heads-up when a gang-enabled convoy is created — every online
-- member of an eligible gang gets notified (not just the leader), so rank
-- and file know to bug their leader about roster sign-up before it departs.
local function notifyGangMembers(def)
    if not def or def.kind == 'HOT_CARGO' or def.kind == 'GANG_AIRDROP' or def.kind == 'TDM' or def.kind == 'GANG_TERRITORY' or def.kind == 'CRACKDOWN' then return end
    local isRace = def.kind == 'GANG_RACE'
    local icon = isRace and '🏁' or '🚚'
    local title = isRace and 'Gang Rally Open' or 'Convoy Open'
    local body = isRace and ('"%s" is open for race sign-ups — get your crew ready.'):format(def.name)
        or ('"%s" is open for roster sign-ups — talk to your gang leader before it departs.'):format(def.name)
    for _, g in ipairs(GangService.GetGangs()) do
        if g.canParticipate ~= false then
            for _, member in ipairs(g.members or {}) do
                local memberSource = findSourceByIdentifier(member.identifier)
                if memberSource then
                    TriggerClientEvent('nova_convoytruck:gang:toast', memberSource, '🚚', 'Convoy Open',
                        ('"%s" is open for roster sign-ups — talk to your gang leader before it departs.'):format(def.name), false)
                    TriggerClientEvent('nova_convoytruck:gang:toast', memberSource, icon, title, body, false)
                end
            end
        end
    end
end

-- Physical start-trigger peds (see Runtime's triggerStartPed handler) stay
-- placed for a convoy's whole in-progress lifetime — DRAFT/SCHEDULED (not
-- started yet, ped actually triggers it — due-time gate enforced in the
-- handler itself) all the way through its active run (ACTIVE/STARTING/
-- CHECKPOINT/UNDER_ATTACK/DELIVERY — ped is just a landmark by then, the
-- handler already rejects "already started" cleanly), only despawning once
-- the convoy actually reaches a terminal outcome. Computed fresh from the
-- cache and pushed to every online police officer whenever a convoy's
-- status/schedule/startPed could have changed, so their client-side ped
-- list never goes stale without needing to poll.
local FINISHED_STATUSES = { COMPLETED = true, CAPTURED = true, FAILED = true, CANCELLED = true }

-- A Gang Territory event becomes visible on the maps the moment it is PUBLISHED (scheduled) or started: its territories
-- are created / refreshed in the persistent state (owners and expansion levels already there are never touched).
local function publishTerritory(def)
    if def and def.kind == 'GANG_TERRITORY' and Territory then
        local ok, err = pcall(Territory.syncFromEvent, def)
        if not ok then print(('^1[NovaConvoy] Territory sync for event #%s failed: %s^0'):format(tostring(def.id), tostring(err))) end
    end
end

local function computeStartPeds(source)
    local isPolice = source and Bridge.IsPolice(source)
    local isAdmin = source and Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission)
    local peds = {}
    for _, def in pairs(cache) do
        if not FINISHED_STATUSES[def.status] and def.startPed and def.startPed.enabled and def.startPed.x then
            local allowed = false
            if def.kind == 'GANG_RACE' then
                -- Street race organizer ped: visible to any gang member (their
                -- own gang does NOT need to be registered for this specific
                -- race — being in ANY gang is enough) and always to admins.
                -- Hidden from plain civilians with no gang at all, and from
                -- on-duty police unless they're also an admin.
                if isAdmin then
                    allowed = true
                elseif not isPolice then
                    local g = GangService and GangService.GetPlayerGang(source)
                    if g and g.name and g.name ~= 'none' then allowed = true end
                end
            else
                -- Armored convoy start ped: visible to police and admins
                if isPolice or isAdmin then
                    allowed = true
                end
            end

            if allowed then
                peds[#peds + 1] = {
                    convoyId = def.id, name = def.name,
                    x = def.startPed.x, y = def.startPed.y, z = def.startPed.z,
                    heading = def.startPed.heading, model = def.startPed.model,
                    scheduledAt = def.scheduledAt,
                    kind = def.kind,
                }
            end
        end
    end
    return peds
end

-- Gang Rally with PROVIDED vehicles: the vehicle ped(s) a player may use. Shown
-- only to racers REGISTERED for that race (and admins, for testing), from the
-- moment it is created until the race is finished. Polled by the client (see
-- client/modules/race_vehicle_peds.lua), so roster changes show up on their own.
function ConvoyManager.getRaceVehiclePeds(source)
    local identifier = source and Bridge.GetIdentifier(source)
    local isAdmin = source and Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission)
    local out = {}
    for _, def in pairs(cache) do
        local s = def.settings or {}
        if def.kind == 'GANG_RACE' and not FINISHED_STATUSES[def.status]
            and s.raceVehicleMode == 'PROVIDED' and s.raceVehiclePed and s.raceVehicles and #s.raceVehicles > 0 then
            local registered = false
            if identifier then
                for _, list in pairs(def.roster or {}) do
                    for _, ident in ipairs(list) do
                        if ident == identifier then registered = true end
                    end
                end
            end
            if registered or isAdmin then
                out[#out + 1] = {
                    convoyId = def.id, name = def.name,
                    x = s.raceVehiclePed.x, y = s.raceVehiclePed.y, z = s.raceVehiclePed.z, heading = s.raceVehiclePed.heading,
                    vehicles = s.raceVehicles,
                }
            end
        end
    end
    return out
end

-- Police (who actually interact with it in-game) AND admins (so placing/
-- testing one doesn't require the admin to also be on-duty as police —
-- without this, an admin who set/moved a start ped while off-duty would
-- never see it spawn at all, even though the position saved correctly).
local function shouldSeeStartPeds(source)
    return Bridge.IsPolice(source) or Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission)
end
-- This player's own police/admin status, for the client's cosmetic role cache
-- (staff-only map blips). Never a security boundary — every write/gameplay
-- path still re-checks server-side.
function ConvoyManager.rolesFor(source)
    return {
        isPolice = Bridge.IsPolice(source),
        isAdmin = Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission),
    }
end

-- Every mutation (create/update/setStatus/delete) already calls this, so
-- it doubles as the one choke point for telling every OTHER open tablet
-- something changed — without it, Manage Convoys/Airdrops only ever
-- re-read the list on mount or a manual Refresh click, so a convoy someone
-- else just created (or scheduled, started, deleted...) silently never
-- appeared for anyone already sitting on that screen until they backed out
-- and back in. Creator-access only; nobody else has a tablet list to
-- refresh in the first place.
function ConvoyManager.broadcastStartPeds()
    TriggerClientEvent('nova_convoytruck:raceVehicle:sync', -1)
    if CivilianService and CivilianService.SyncPeds then
        CivilianService.SyncPeds(-1)
    end
    for _, src in ipairs(Bridge.GetPlayers()) do
        local peds = computeStartPeds(src)
        TriggerClientEvent('nova_convoytruck:client:syncStartPeds', src, peds)
        if Bridge.HasCreatorAccess(src) then
            TriggerClientEvent('nova_convoytruck:client:convoyListChanged', src)
        end
    end
end

function ConvoyManager.sendStartPedsTo(source)
    if CivilianService and CivilianService.SyncPeds then
        CivilianService.SyncPeds(source)
    end
    TriggerClientEvent('nova_convoytruck:client:syncStartPeds', source, computeStartPeds(source))
end

local FAILURE_POLICIES = { FAIL = true, CONTINUE = true, CAPTURE = true }
local VALID_KINDS = { CONVOY = true, GANG_AIRDROP = true, HOT_CARGO = true, GANG_RACE = true, TDM = true, CONTAINER_WARS = true, GANG_TERRITORY = true, CRACKDOWN = true }
-- Every kind but plain CONVOY is admin-only to create/edit/clone, even though
-- ordinary CONVOY creation is open to anyone with tablet access (which police
-- get via job grade) — each of these is meant to be curated/invisible to
-- police in one way or another (see callbacks.lua's getConvoys/getConvoy/
-- getActiveConvoys/getConvoyHistory filtering), so a police-job tablet user
-- must never even be able to spin one up in the first place.
local ADMIN_ONLY_KINDS = { GANG_AIRDROP = true, HOT_CARGO = true, GANG_RACE = true, TDM = true, CONTAINER_WARS = true, GANG_TERRITORY = true, CRACKDOWN = true }
local KIND_LABELS = { CONVOY = 'Convoy', GANG_AIRDROP = 'Gang Airdrop', HOT_CARGO = 'Hot Cargo', GANG_RACE = 'Gang Rally', TDM = 'TDM Match', CONTAINER_WARS = 'Container Wars', GANG_TERRITORY = 'Gang Territory Auction', CRACKDOWN = 'Operation Crackdown' }
function ConvoyManager.isAdminOnlyKind(kind) return ADMIN_ONLY_KINDS[kind] == true end

-- Shared by def.reward and each airdrop zone's own rewards list below —
-- accepts either the new list shape or an old single-object reward (pre-
-- migration data still floating around in memory/tests).
local function sanitizeRewardList(raw)
    if raw and raw.type and not raw[1] then raw = { raw } end
    local list = {}
    for _, r in ipairs(raw or {}) do
        local rtype = tostring(r and r.type or ''):upper()
        if rtype == 'GANG_XP' then
            -- Gang XP: a whole, non-negative number, never more than the configured per-award cap
            local cap = tonumber(Config.Territory and Config.Territory.gangXp and Config.Territory.gangXp.maxPerAward) or 1000000
            list[#list + 1] = { type = 'GANG_XP', amount = math.max(0, math.min(cap, math.floor(tonumber(r.amount) or 0))), pool = '' }
        elseif rtype == 'MONEY' or rtype == 'ITEMS' or rtype == 'TOKENS' then
            list[#list + 1] = {
                type = rtype,
                amount = tonumber(r.amount) or 0,
                pool = tostring(r.pool or r.model or ''):sub(1, 255),
                model = r.model and tostring(r.model):sub(1, 50) or nil,
            }
        elseif rtype == 'VEHICLE' then
            -- a car: model = its spawn name (GTA or addon), pool = the name shown to the player, amount = how many,
            -- mode = GARAGE (the winner owns it) or SPAWN (it appears beside the container with keys)
            local model = tostring(r.model or ''):gsub('[^%w_%-]', ''):sub(1, 50)
            if model ~= '' then
                local label = tostring(r.pool or ''):gsub('[%c<>]', ''):sub(1, 60)
                local mode = tostring(r.mode or ''):upper()
                list[#list + 1] = {
                    type = 'VEHICLE',
                    model = model,
                    pool = label ~= '' and label or model,
                    amount = math.max(1, math.min(5, math.floor(tonumber(r.amount) or 1))),
                    mode = (mode == 'SPAWN') and 'SPAWN' or 'GARAGE',
                }
            end
        end
    end
    return list
end

-- A standalone drop zone for a GANG_AIRDROP-kind convoy — same shape as the
-- per-route-point airdrop config an ordinary convoy uses (see RouteBuilder's
-- defaultAirdrop), just carrying its own raw x/y/z instead of a routePointId
-- since this event kind has no route at all.
local function sanitizeAirdropZone(z, index)
    local name = tostring(z.name or z.label or ('Drop Zone ' .. index)):sub(1, 100)
    return {
        id = tostring(z.id or ('zone_' .. index)),
        name = name,
        label = name,
        x = tonumber(z.x), y = tonumber(z.y), z = tonumber(z.z),
        enabled = z.enabled ~= false,
        announce = z.announce ~= false,
        activationDelay = clamp(z.activationDelay, 0, 3600),
        duration = clamp(z.duration, 10, 3600),
        guardCount = clamp(z.guardCount, 0, 10),
        guardModel = tostring(z.guardModel or 'g_m_y_lost_01'),
        guardWeapon = tostring(z.guardWeapon or 'WEAPON_MICROSMG'),
        guardAggressiveness = tostring(z.guardAggressiveness or 'medium'),
        requireLockpick = z.requireLockpick ~= false,
        lockpicksRequired = tonumber(z.lockpicksRequired) or nil,
        chance = clamp(z.chance, 0, 100),
        rewards = sanitizeRewardList(z.rewards),
    }
end

local RECURRENCE_TYPES = { DAILY = true, WEEKLY = true, MONTHLY = true, YEARLY = true }
local RECURRENCE_MODES = { EXACT = true, WINDOW = true }

-- {enabled, type: DAILY/WEEKLY/MONTHLY/YEARLY, month (1-12, YEARLY only),
-- dayOfWeek (0=Sun..6=Sat, WEEKLY only),
-- dayOfMonth (1-28 for MONTHLY so it exists in every month; 1-31 for YEARLY),
-- mode: EXACT/WINDOW (fixed time vs random time window),
-- hour, minute, windowStartHour, windowStartMinute, windowEndHour, windowEndMinute}.
-- Scheduler.rearm (scheduler.lua) reads this once a convoy/airdrop/hotcargo
-- finishes to auto-advance scheduledAt to the next occurrence.
local function sanitizeRecurrence(r)
    local rtype = tostring(r and r.type or 'WEEKLY'):upper()
    if not RECURRENCE_TYPES[rtype] then rtype = 'WEEKLY' end
    local rmode = tostring(r and r.mode or 'EXACT'):upper()
    if not RECURRENCE_MODES[rmode] then rmode = 'EXACT' end
    return {
        enabled = r and r.enabled and true or false,
        type = rtype,
        mode = rmode,
        month = clamp(r and r.month, 1, 12),
        dayOfWeek = clamp(r and r.dayOfWeek, 0, 6),
        dayOfMonth = clamp(r and r.dayOfMonth, 1, rtype == 'YEARLY' and 31 or 28),
        hour = clamp(r and r.hour, 0, 23),
        minute = clamp(r and r.minute, 0, 59),
        windowStartHour = clamp(r and r.windowStartHour, 0, 23),
        windowStartMinute = clamp(r and r.windowStartMinute, 0, 59),
        windowEndHour = clamp(r and r.windowEndHour, 0, 23),
        windowEndMinute = clamp(r and r.windowEndMinute, 0, 59),
    }
end

-- Configuration for HOT_CARGO event kind
local function sanitizeHotCargoConfig(raw)
    raw = raw or {}
    -- Where a RANDOM-mode truck (see `trucks` below) CAN land. Guards live
    -- here on the ZONE, not the truck entry — a Random truck's location is
    -- picked at start, so the guard detail has to belong to whichever spot
    -- it lands on (a decoy zone that never gets a truck just never spawns
    -- anyone). A Manual-mode truck has no zone, so it carries its own guard
    -- fields directly on its truck entry instead.
    local spawnZones = {}
    for i, z in ipairs(raw.spawnZones or {}) do
        spawnZones[#spawnZones + 1] = {
            id = tostring(z.id or ('spawn_' .. i)),
            name = tostring(z.name or ('Spawn Zone ' .. i)):sub(1, 100),
            x = tonumber(z.x), y = tonumber(z.y), z = tonumber(z.z),
            heading = tonumber(z.heading) or 0.0,
            -- The precise truck/trailer placement vector (HotCargoConfig.
            -- svelte's "Truck Spawn Position" — Set to My Position /
            -- teleport / map-pick, and the new in-world placement mode)
            -- was being silently dropped here on every save: doStartHotCargo
            -- reads z.truckX/Y/Z/truckHeading (convoy_runtime.lua) and falls
            -- back to the zone's own x/y/z/heading when it's nil — which is
            -- exactly what always happened, since this table never actually
            -- carried the field through to the DB in the first place.
            truckX = tonumber(z.truckX), truckY = tonumber(z.truckY), truckZ = tonumber(z.truckZ),
            truckHeading = tonumber(z.truckHeading) or 0.0,
            guardCount = clamp(z.guardCount, 0, 10),
            guardWeapon = tostring(z.guardWeapon or 'WEAPON_CARBINERIFLE'):sub(1, 50),
            guardModel = tostring(z.guardModel or 'g_m_y_salvagoon_01'):sub(1, 50),
            guardAggressiveness = tostring(z.guardAggressiveness or 'high'):sub(1, 20),
            shootAnyone = (z.shootAnyone ~= false),
        }
    end
    local dropoffZones = {}
    for i, d in ipairs(raw.dropoffZones or {}) do
        dropoffZones[#dropoffZones + 1] = {
            id = tostring(d.id or ('dropoff_' .. i)),
            name = tostring(d.name or ('Dropoff ' .. i)):sub(1, 100),
            x = tonumber(d.x), y = tonumber(d.y), z = tonumber(d.z),
            radius = clamp(d.radius, 5, 100),
            guardCount = clamp(d.guardCount, 0, 10),
            guardWeapon = tostring(d.guardWeapon or 'WEAPON_CARBINERIFLE'):sub(1, 50),
            guardModel = tostring(d.guardModel or 'g_m_y_salvagoon_01'):sub(1, 50),
            -- Was never actually saved despite the tablet exposing it and
            -- spawnHotCargoDropoffGuards reading it — every dropoff silently
            -- reverted to 'high' on every save, no matter what was picked.
            guardAggressiveness = tostring(d.guardAggressiveness or 'high'):sub(1, 20),
            shootAnyone = (d.shootAnyone ~= false),
        }
    end
    -- The Trucks section: each entry is one cargo truck. mode = 'MANUAL'
    -- (admin pins it at its own x/y/z/heading, always spawns there) or
    -- 'RANDOM' (no fixed position — doStartHotCargo picks one unused zone
    -- from spawnZones for it at start, same shuffle-and-pick as before, just
    -- per-entry instead of a flat vehiclesToSpawn count). Replaces the old
    -- single global truckModel + vehiclesToSpawn count — different trucks in
    -- the same run can now be different vehicles.
    local trucks = {}
    for i, t in ipairs(raw.trucks or {}) do
        local mode = tostring(t.mode or 'RANDOM'):upper()
        if mode ~= 'MANUAL' and mode ~= 'RANDOM' then mode = 'RANDOM' end
        trucks[#trucks + 1] = {
            id = tostring(t.id or ('truck_' .. i)),
            name = tostring(t.name or ('Cargo Truck ' .. i)):sub(1, 100),
            model = tostring(t.model or 'hauler'):sub(1, 50),
            mode = mode,
            x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z),
            heading = tonumber(t.heading) or 0.0,
            -- Per-truck "Truck Health (HP)" field — was being silently
            -- dropped here (every truck fell back to the one global
            -- Config.HotCargoTheft.truckHealth value regardless of what was
            -- configured per-truck) AND doStartHotCargo never actually read
            -- it even when present — both are now fixed (see doStartHotCargo).
            health = tonumber(t.health),
            -- Same silent-drop bug for the per-truck reward lists — not yet
            -- wired into actual reward-granting (that still runs off the
            -- event-level reward config), kept here so the data at least
            -- survives a save instead of resetting every time the tablet is
            -- reopened.
            deliveryReward = sanitizeRewardList(t.deliveryReward),
            hijackReward = sanitizeRewardList(t.hijackReward),
            -- Guards posted on THIS truck, GTA heist-truck style — has to be
            -- cleared before it's safe to lockpick (see
            -- spawnHotCargoVehicleGuards in convoy_runtime.lua).
            guardCount = clamp(t.guardCount, 0, 10),
            guardWeapon = tostring(t.guardWeapon or 'WEAPON_CARBINERIFLE'):sub(1, 50),
            guardModel = tostring(t.guardModel or 'g_m_y_salvagoon_01'):sub(1, 50),
            guardAggressiveness = tostring(t.guardAggressiveness or 'high'):sub(1, 20),
            shootAnyone = (t.shootAnyone ~= false),
        }
    end
    return {
        policeAlertBufferSeconds = clamp(raw.policeAlertBufferSeconds, 0, 600),
        policeAlert = (raw.policeAlert ~= false),
        trucks = trucks,
        spawnZones = spawnZones,
        dropoffZones = dropoffZones,
        -- Disabled/broken-down truck salvage loot — separate pool from the
        -- main delivery `reward` above, meant to be configured lower-value.
        -- Falls back to the generic Config.CapturedTruckLoot.items when empty
        -- (see makeTruckLootable) so existing saved runs keep working as-is.
        salvageReward = sanitizeRewardList(raw.salvageReward),
    }
end

-- Configuration for GANG_RACE event kind: a plain race — Start, Checkpoints,
-- Finish. Anything else a stage carried (older saved data) is
-- dropped here on the next save.
local function sanitizeRallyStages(raw)
    local list = {}
    for i, s in ipairs(raw or {}) do
        -- Unplaced stages (no x/y yet) are KEPT so a half-built race doesn't
        -- silently lose the checkpoints an admin added but hasn't positioned;
        -- starting the race is blocked until every stage is placed.
        if type(s) == 'table' then
            local name = tostring(s.name or s.label or ('Stage ' .. i)):sub(1, 100)
            local kind = tostring(s.kind or ''):upper()
            if kind ~= 'START' and kind ~= 'DESTINATION' then kind = 'CHECKPOINT' end
            list[#list + 1] = {
                id = tostring(s.id or ('stage_' .. i)),
                order = #list,
                kind = kind,
                name = name,
                label = name,
                x = tonumber(s.x),
                y = tonumber(s.y),
                z = tonumber(s.z),
                heading = tonumber(s.heading) or 0.0,
                radius = clamp(s.radius, 5, 100),
            }
        end
    end
    return list
end

local TDM_MATCH_FORMATS = { STANDARD = true, TOURNAMENT = true }

-- Configuration for TDM event kind. Eligibility (which gangs may even see/
-- register for this event) is NOT duplicated here — it reuses
-- settings.allowedGangs (mode SELECTED) below, the exact same mechanism
-- HOT_CARGO/GANG_AIRDROP already use to restrict participation to admin-
-- picked gangs. This blob only carries what's genuinely TDM-specific: match
-- format, timing, the combat zone, weapon vendor, spawn points, and (Tournament
-- only) the live bracket tree.
local MAX_TDM_ZONE_POINTS = 24

local function sanitizeTdmConfig(raw, existingBracket)
    raw = raw or {}
    local format = tostring(raw.matchFormat or 'STANDARD'):upper()
    if not TDM_MATCH_FORMATS[format] then format = 'STANDARD' end
    local zone = raw.zone or {}
    local vendor = raw.weaponVendor or {}
    local vendorRed = raw.weaponVendorRed or vendor
    local vendorBlue = raw.weaponVendorBlue or vendor

    local function sanitizePoints(list, maxCount)
        local pts = {}
        for i, p in ipairs(list or {}) do
            if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and (#pts < (maxCount or 48)) then
                pts[#pts + 1] = {
                    id = tostring(p.id or ('spawn_' .. i)),
                    x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0,
                    heading = tonumber(p.heading) or 0.0,
                }
            end
        end
        return pts
    end

    local spawnPointsRed = sanitizePoints(raw.spawnPointsRed, 24)
    local spawnPointsBlue = sanitizePoints(raw.spawnPointsBlue, 24)
    local spawnPoints = sanitizePoints(raw.spawnPoints, 48)

    -- If Red/Blue spawns exist, merge into spawnPoints for backwards compatibility
    if #spawnPointsRed > 0 or #spawnPointsBlue > 0 then
        local merged = {}
        for _, p in ipairs(spawnPointsRed) do merged[#merged + 1] = p end
        for _, p in ipairs(spawnPointsBlue) do merged[#merged + 1] = p end
        spawnPoints = merged
    elseif #spawnPoints > 0 then
        -- Legacy fallback: distribute across red and blue
        local half = math.ceil(#spawnPoints / 2)
        for i, p in ipairs(spawnPoints) do
            if i <= half then spawnPointsRed[#spawnPointsRed + 1] = p
            else spawnPointsBlue[#spawnPointsBlue + 1] = p end
        end
    end

    local zonePoints = {}
    for i, p in ipairs(zone.points or {}) do
        if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and #zonePoints < MAX_TDM_ZONE_POINTS then
            zonePoints[#zonePoints + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
        end
    end

    -- A drawn polygon (combat zone, staging zone, a team's base zone): x / y / z points only
    local function sanitizePoly(src)
        local pts = {}
        for _, p in ipairs(type(src) == 'table' and src.points or {}) do
            if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and #pts < MAX_TDM_ZONE_POINTS then
                pts[#pts + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
            end
        end
        return pts
    end
    local respawnZoneRed = sanitizePoly(raw.respawnZoneRed)
    local respawnZoneBlue = sanitizePoly(raw.respawnZoneBlue)
    local stagingRaw = type(raw.stagingZone) == 'table' and raw.stagingZone or {}
    local stagingZone = {
        enabled = stagingRaw.enabled == true,
        requiredPerTeam = clamp(stagingRaw.requiredPerTeam or 10, 1, 50),
        points = sanitizePoly(stagingRaw),
    }

    local function sanitizeVendor(v)
        if v and tonumber(v.x) and tonumber(v.y) then
            return {
                x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z) or 0.0,
                heading = tonumber(v.heading) or 0.0,
                pedModel = v.pedModel,
                enabled = v.enabled ~= false,
            }
        end
        return {}
    end

    local weapons = {}
    for _, w in ipairs(raw.weapons or {}) do
        if type(w) == 'table' and w.weapon and tostring(w.weapon) ~= '' then
            weapons[#weapons + 1] = {
                id = tostring(w.id or w.weapon),
                label = tostring(w.label or w.weapon),
                weapon = tostring(w.weapon):upper(),
                type = tostring(w.type or 'Rifle'),
                ammo = math.max(1, math.min(999, math.floor(tonumber(w.ammo) or 60))),
                price = math.max(0, math.floor(tonumber(w.price) or 1000)),
                enabled = w.enabled ~= false,
            }
        end
    end

    -- how the reward is shared by kills (see server/modules/tdm_rewards.lua); an event that never set it uses Config.TDM.rewardScaling
    local scDef = (Config.TDM and Config.TDM.rewardScaling) or {}
    local scRaw = type(raw.rewardScaling) == 'table' and raw.rewardScaling or {}
    local rewardScaling = {
        enabled = (scRaw.enabled == nil) and (scDef.enabled ~= false) or (scRaw.enabled ~= false),
        winnerMinPercent = clamp(scRaw.winnerMinPercent ~= nil and scRaw.winnerMinPercent or scDef.winnerMinPercent or 40, 0, 100),
        loserPercent = clamp(scRaw.loserPercent ~= nil and scRaw.loserPercent or scDef.loserPercent or 25, 0, 100),
        loserMinPercent = clamp(scRaw.loserMinPercent ~= nil and scRaw.loserMinPercent or scDef.loserMinPercent or 40, 0, 100),
    }

    return {
        matchFormat = format,
        rewardScaling = rewardScaling,
        duration = clamp(raw.duration or 600, 60, 3600),
        killLimit = clamp(raw.killLimit or 0, 0, 500),
        zone = (#zonePoints >= 1) and { points = zonePoints } or {},
        stagingZone = stagingZone,
        respawnZoneRed = { points = respawnZoneRed },
        respawnZoneBlue = { points = respawnZoneBlue },
        weaponVendor = sanitizeVendor(vendor),
        weaponVendorRed = sanitizeVendor(vendorRed),
        weaponVendorBlue = sanitizeVendor(vendorBlue),
        spawnPoints = spawnPoints,
        spawnPointsRed = spawnPointsRed,
        spawnPointsBlue = spawnPointsBlue,
        teamRedGang = (raw.teamRedGang and tostring(raw.teamRedGang) ~= '') and tostring(raw.teamRedGang) or nil,
        teamBlueGang = (raw.teamBlueGang and tostring(raw.teamBlueGang) ~= '') and tostring(raw.teamBlueGang) or nil,
        weapons = #weapons > 0 and weapons or nil,
        bracket = existingBracket or raw.bracket or {},
    }
end

local CW_DEFAULTS = (Config.ContainerWars and Config.ContainerWars.defaults) or {}
local function cwd(key, fallback)
    local v = tonumber(CW_DEFAULTS[key])
    if v == nil then return fallback end
    return v
end
local MAX_CONTAINER_WARS_CONTAINERS = math.max(1, math.floor(cwd('maxContainers', 10)))
-- most auction lots in one event: lots reuse the yard's spots round after round (see spotOfLot), so this is NOT limited by
-- how many spots the yard has
local MAX_CW_LOTS = math.max(MAX_CONTAINER_WARS_CONTAINERS, math.floor(tonumber(Config.ContainerWars and Config.ContainerWars.maxLots) or 40))
local MAX_CW_ZONE_POINTS = 24

-- The harbour yard (Config.ContainerWars.harbour). Container Wars only runs here: the crane, the drop
-- spot and the container spots come from config, never from the tablet.
local function harbourYard()
    return (Config.ContainerWars and Config.ContainerWars.harbour) or {}
end

local function cwPoint(t)
    if type(t) ~= 'table' or not tonumber(t.x) or not tonumber(t.y) then return nil end
    return { x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z) or 0.0, heading = tonumber(t.heading) or 0.0 }
end

-- Puts the harbour layout onto an event: every container gets its drop spot and its waiting spot, and the
-- crane is the harbour's. It runs when an event is saved AND again when it is started — so moving a spot
-- in the tablet applies to events that were saved earlier too.
-- Which of the yard's spots lot number `i` stands on. Lots take the spots in turn and start over when they run out,
-- so a yard of 4 spots serves 4 rounds of 4 lots (the previous round's containers are cleared first). With as many
-- spots as lots this is just spot = lot, as it always was.
local function spotOfLot(i, yard)
    local n = #(yard.pickups or {})
    if n == 0 then n = #(yard.drops or {}) end   -- no pickup spots: the lots hang over the drop pads
    if n == 0 then return i end
    return ((i - 1) % n) + 1
end

-- Gives every lot the spot, drop pad and crane of its place in the sequence. Runs when an event is saved, when it
-- starts, and again after a randomised order (the lots move around, the spots stay put).
local function stampLots(containers)
    local yard = harbourYard()
    local alias = (Config.ContainerWars and Config.ContainerWars.containerModelAlias) or {}
    local allowed, fallback, bigModels, bigFallback = {}, 'tr_prop_tr_container_01a', {}, nil
    for n, m in ipairs((Config.ContainerWars and Config.ContainerWars.containerModels) or {}) do
        allowed[m.model] = true
        if n == 1 then fallback = m.model end
        if m.vehicleSafe then bigModels[m.model] = true; bigFallback = bigFallback or m.model end
    end
    for i, c in ipairs(containers or {}) do
        local spot = spotOfLot(i, yard)
        c.spotIndex = spot
        local hp = yard.pickups and yard.pickups[spot]

        -- Reward section (c.model) is the authoritative source of truth.
        -- If c.model is missing or empty, reflect the spot's configured model or default to door-equipped container.
        if not c.model or c.model == '' then
            c.model = (hp and hp.model and hp.model ~= '') and hp.model or 'tr_prop_tr_container_01a'
        end
        if alias[c.model] then c.model = alias[c.model] end
        -- only models that really open are auctioned (see Config.ContainerWars.containerModels)
        if next(allowed) and not allowed[c.model] then c.model = fallback end
        -- a reward car only fits in a big container
        if bigFallback and not bigModels[c.model] then
            for _, r in ipairs(c.rewards or {}) do
                if string.upper(tostring(r.type or '')) == 'VEHICLE' then
                    print(('[NovaConvoy] Container Wars lot #%d holds a car but its model is too small: changed to %s'):format(i, bigFallback))
                    c.model = bigFallback
                    break
                end
            end
        end

        -- the spot's own "Target Delivery Drop" (defaults to the drop pad with its number)
        local dropIdx = (hp and tonumber(hp.assignedDrop)) or spot
        local drop = cwPoint(yard.drops and yard.drops[dropIdx]) or cwPoint(yard.drops and yard.drops[spot]) or cwPoint(yard.drop)
        c.dropCoords = drop and { x = drop.x, y = drop.y, z = drop.z + (tonumber(yard.dropZOffset) or 0.0), heading = drop.heading } or nil
        local p = cwPoint(hp)
        -- cwPoint keeps only the position; the crane and drop pad chosen for the spot ride along, or the event ignored them
        if p and hp then
            p.assignedCrane = tonumber(hp.assignedCrane)
            p.assignedDrop = tonumber(hp.assignedDrop)
        end
        c.pickupCoords = p
        local mapModel = hp and hp.mapModel
        c.hideWorldObject = p ~= nil and type(mapModel) == 'string' and mapModel ~= ''
        c.hideModel = c.hideWorldObject and mapModel or nil
    end
end
function ConvoyManager.stampLots(containers) stampLots(containers) end

local function stampHarbour(cw)
    local yard = harbourYard()
    local containers = cw.containers or {}
    stampLots(containers)
    cw.layout = { mode = 'STACK', dropMode = 'SAME_SPOT' }   -- a round's containers are cleared before the next round's land
    -- lots per round: at most one per spot of the yard (they all stand there at once); spots removed since the event was
    -- saved shrink it rather than leaving a round that cannot fit
    cw.containersPerRound = math.floor(clamp(cw.containersPerRound or 1, 1, math.max(1, math.min(#(yard.pickups or {}), 10))))

    -- every crane of the yard (one per aisle); cw.crane stays the first for what only knows one
    local function stampCrane(rc)
        return {
            x = rc.x, y = rc.y, z = rc.z, heading = rc.heading,
            model = tostring(rc.model or 'prop_dock_rtg_ld'):gsub('[^%w_:]', ''):sub(1, 50),
            auto = rc.auto == true,
            reachable = rc.reachable ~= false,
        }
    end
    local rcs = CWGantry.resolveCranes(yard, #containers)
    cw.cranes = {}
    for _, rc in ipairs(rcs) do cw.cranes[#cw.cranes + 1] = stampCrane(rc) end
    cw.crane = rcs[1] and stampCrane(rcs[1]) or {}
    return cw
end
function ConvoyManager.stampHarbour(cw) return stampHarbour(cw) end

local function sanitizeContainerWarsConfig(raw)
    raw = raw or {}
    local yard = harbourYard()
    -- lots are not limited by the spots of the yard: they take the spots in turn, round after round
    local maxContainers = clamp(raw.maxContainers or cwd('containersPerRound', 4), 1, MAX_CW_LOTS)
    -- lots per round: they all stand in the yard together, so no more than the yard has spots (the tablet refuses a
    -- larger number before it gets here; this keeps a stale or hand-made request from breaking the event)
    local containersPerRound = math.floor(clamp(raw.containersPerRound or 1, 1, math.max(1, math.min(#(yard.pickups or {}), 10))))
    local zone = raw.zone or {}

    local zonePoints = {}
    for _, p in ipairs(zone.points or {}) do
        if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and #zonePoints < MAX_CW_ZONE_POINTS then
            zonePoints[#zonePoints + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
        end
    end

    if #zonePoints < 3 and yard.zone then
        zonePoints = {}
        for _, p in ipairs(yard.zone.points or {}) do
            if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and #zonePoints < MAX_CW_ZONE_POINTS then
                zonePoints[#zonePoints + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
            end
        end
    end

    local containers = {}
    for i, c in ipairs(raw.containers or {}) do
        if type(c) == 'table' and #containers < MAX_CW_LOTS then
            -- Enforce strictly MAX 1 VEHICLE per container lot, with amount = 1 to prevent collisions
            local cleanRewards = sanitizeRewardList(c.rewards)
            local finalRewards = {}
            local hasVehicle = false
            for _, r in ipairs(cleanRewards) do
                if r.type == 'VEHICLE' then
                    if not hasVehicle then
                        r.amount = 1
                        finalRewards[#finalRewards + 1] = r
                        hasVehicle = true
                    else
                        print(('[NovaConvoy] Warning: Container #%d ("%s") had multiple vehicle rewards configured; clamped to 1 vehicle to prevent physics collision.'):format(i, tostring(c.name or '')))
                    end
                else
                    finalRewards[#finalRewards + 1] = r
                end
            end

            containers[#containers + 1] = {
                id = tostring(c.id or ('container_' .. i)),
                name = tostring(c.name or ('Container #' .. i)):sub(1, 100),
                model = tostring(c.model or 'prop_container_05a'):gsub('[^%w_:%-]', ''):sub(1, 50),
                startingBid = math.max(0, math.floor(tonumber(c.startingBid) or cwd('startingBid', 5000))),
                -- The tablet sends minBidIncrement and the runtime reads it; only bidIncrement was kept before,
                -- so every container silently fell back to $1,000.
                minBidIncrement = math.max(100, math.floor(tonumber(c.minBidIncrement or c.bidIncrement) or cwd('minBidIncrement', 1000))),
                bidIncrement = math.max(100, math.floor(tonumber(c.minBidIncrement or c.bidIncrement) or cwd('minBidIncrement', 1000))),
                auctionDuration = clamp(c.auctionDuration or cwd('auctionDuration', 45), 15, 300),
                rewards = finalRewards,
            }
        end
    end

    -- Each round's own announcement banner: { title, message } per round number (empty = the default text). Plain
    -- text only; {round} {rounds} {lots} {names} are filled in when the round starts.
    local rounds = {}
    if type(raw.rounds) == 'table' then
        for i = 1, math.min(#raw.rounds, MAX_CW_LOTS) do
            local r = raw.rounds[i]
            local title, message = '', ''
            if type(r) == 'table' then
                title = tostring(r.title or ''):gsub('[%c]', ' '):sub(1, 60)
                message = tostring(r.message or ''):gsub('[%c]', ' '):sub(1, 300)
            end
            rounds[i] = { title = title, message = message }
        end
    end

    local order = tostring(raw.auctionOrder or 'IN_ORDER'):upper()
    if order ~= 'RANDOM' then order = 'IN_ORDER' end

    local out = {
        maxContainers = maxContainers,
        containersPerRound = containersPerRound,
        -- Round / timing / rules (seconds). Defaults match the old hard-coded values.
        craneTravelSeconds = clamp(raw.craneTravelSeconds or cwd('craneTravelSeconds', 8), 3, 30),         -- crane lowers a container to its drop
        lotGapSeconds = clamp(raw.lotGapSeconds or cwd('lotGapSeconds', 15), 5, 120),                 -- pause / reward claim window between two auctions in a round
        roundBreakSeconds = clamp(raw.roundBreakSeconds or cwd('roundBreakSeconds', 10), 3, 120),         -- pause after a round's last container
        -- a bid this close to the end (or closer) adds time; defaults come from Config.ContainerWars.antiSnipe
        antiSnipeWindowSeconds = clamp(raw.antiSnipeWindowSeconds or ((Config.ContainerWars and Config.ContainerWars.antiSnipe and Config.ContainerWars.antiSnipe.triggerSeconds) or 10), 0, 30),
        antiSnipeExtendSeconds = clamp(raw.antiSnipeExtendSeconds or ((Config.ContainerWars and Config.ContainerWars.antiSnipe and Config.ContainerWars.antiSnipe.extendSeconds) or 15), 0, 60),
        auctionOrder = order,
        -- Gang XP for the winning gang of each lot (paid when the bid is settled, see container_wars_runtime.lua)
        gangXpOnWin = raw.gangXpOnWin == true,
        gangXpAmount = math.floor(clamp(raw.gangXpAmount or 100, 0, tonumber(Config.Territory and Config.Territory.gangXp and Config.Territory.gangXp.maxPerAward) or 1000000)),
        settleSeconds = clamp(raw.settleSeconds or cwd('settleSeconds', 2), 0, 15),                     -- pause after the container lands
        openSeconds = clamp(raw.openSeconds or cwd('openSeconds', 3), 0, 15),                         -- pause after a container lands (closed) before its bidding opens
        startCountdownSeconds = clamp(raw.startCountdownSeconds or cwd('startCountdownSeconds', 30), 0, 300),   -- "Starting in N seconds" before the crane first moves
        craneLiftHeight = clamp(raw.craneLiftHeight or cwd('craneLiftHeight', 12), 3, 60),               -- how high a container is hoisted before it travels
        hookReturnSeconds = clamp(raw.hookReturnSeconds or cwd('hookReturnSeconds', 0), 0, 20),          -- empty hook climbing back after the drop (0 = same pace as the lowering)
        hookDescendSeconds = clamp(raw.hookDescendSeconds or cwd('hookDescendSeconds', 0.5), 0.3, 20),   -- empty hook coming down onto the container
        -- the carry: 'CURVE' (planned route that turns like a car, default) or 'STRAIGHT'; carryCurve = the straight run-out / run-in at each end (fraction of the distance)
        carryPath = (tostring(raw.carryPath or cwd('carryPath', 'CURVE')):upper() == 'STRAIGHT') and 'STRAIGHT' or 'CURVE',
        carryCurve = math.max(0.1, math.min(1.0, tonumber(raw.carryCurve) or tonumber(cwd('carryCurve', 0.4)) or 0.4)),
        -- the last container is announced as the FINAL ROUND, with a longer break before it
        finalRoundEnabled = (function()
            local v = raw.finalRoundEnabled
            if v == nil then v = cwd('finalRoundEnabled', true) end
            return v ~= false
        end)(),
        finalRoundBreakSeconds = clamp(raw.finalRoundBreakSeconds or cwd('finalRoundBreakSeconds', 30), 3, 300),
        finalRoundAuctionSeconds = clamp(raw.finalRoundAuctionSeconds or cwd('finalRoundAuctionSeconds', 0), 0, 300),   -- 0 = the container's own auction time
        vehicleSafeCoords = (function()
            if type(raw.vehicleSafeCoords) == 'table' and tonumber(raw.vehicleSafeCoords.x) and tonumber(raw.vehicleSafeCoords.y) then
                return {
                    x = tonumber(raw.vehicleSafeCoords.x),
                    y = tonumber(raw.vehicleSafeCoords.y),
                    z = tonumber(raw.vehicleSafeCoords.z) or 0.0,
                    heading = tonumber(raw.vehicleSafeCoords.heading) or 0.0,
                }
            end
            return nil
        end)(),
        zone = (#zonePoints >= 1) and { points = zonePoints } or {},
        rounds = rounds,
        containers = containers,
    }
    return stampHarbour(out)
end

-- ── GANG_TERRITORY (Gang Territory Auction) ─────────────────────────────────────
-- Everything an admin configures in the four tabs (Auction Setup / Gang Areas / Territory Map / Review). This is the
-- EVENT's configuration only: who owns each territory afterwards, and its expansion level, live in nova_territories
-- (territory.lua) and survive the event. Nothing here is hardcoded — territory count, names, colours, costs, timings
-- all come from what the admin saved; Config.Territory only supplies the defaults / limits.

local function terrPoint(t, withHeading)
    if type(t) ~= 'table' or not tonumber(t.x) or not tonumber(t.y) then return nil end
    local p = { x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z) or 0.0 }
    if withHeading then p.heading = tonumber(t.heading) or 0.0 end
    return p
end

local function terrColor(c, fallback)
    c = tostring(c or '')
    if c:match('^#%x%x%x%x%x%x$') or c:match('^#%x%x%x$') then return c:lower() end
    return fallback
end

local function terrSafeText(s, n)
    return (tostring(s or ''):gsub('[%c<>]', ' '):sub(1, n))
end

local function terrId(raw, fallback)
    local id = tostring(raw or ''):lower():gsub('[^%w_%-]', '_'):gsub('_+', '_'):sub(1, 64)
    id = id:gsub('^_+', ''):gsub('_+$', '')
    if id == '' then id = fallback end
    return id
end

-- Area ids ('territory_1', 'territory_2' ...) are the keys of the persistent territory table, and the tablet names the areas of EVERY
-- new event the same way, so a second Territory event used to overwrite the first one's territories (definition, geometry, owner).
-- Returns the set of ids that already belong to another event.
local function foreignTerritoryIds(existingDef)
    local set = {}
    pcall(function()
        local mine = existingDef and existingDef.id or nil
        for _, d in ipairs(ConvoyManager.getAll()) do
            if d.kind == 'GANG_TERRITORY' and d.id ~= mine then
                for _, ar in ipairs((d.territory and d.territory.areas) or {}) do
                    local st = ar.id and Territory and Territory.get(ar.id)
                    -- an id this event already owns in the persistent table stays its own
                    if ar.id and not (st and mine and st.eventId == mine) then set[ar.id] = true end
                end
            end
        end
        if Territory and Territory.all then
            for _, tt in ipairs(Territory.all()) do
                if tt.eventId and tt.eventId ~= mine then set[tt.id] = true end
            end
        end
    end)
    return set
end

local function sanitizeTerritoryConfig(raw, existingDef)
    raw = type(raw) == 'table' and raw or {}
    local tcfg = Config.Territory or {}
    local acfg = tcfg.auction or {}
    local dflt = acfg.defaults or {}
    local snipe = acfg.antiSnipe or {}
    local a = type(raw.auction) == 'table' and raw.auction or {}
    local maxCells = math.floor(tonumber(tcfg.maxCellsPerTerritory) or 80000)
    local defaultCs = tonumber(tcfg.cellSize) or 25.0

    local auction = {
        date = tostring(a.date or ''):match('^%d%d%d%d%-%d%d%-%d%d$') or '',
        startTime = tostring(a.startTime or ''):match('^%d%d:%d%d$') or '',
        lotSeconds = clamp(a.lotSeconds or dflt.lotSeconds or 90, 15, 900),
        lotGapSeconds = clamp(a.lotGapSeconds or dflt.lotGapSeconds or 20, 3, 300),
        introSeconds = clamp(a.introSeconds or dflt.introSeconds or 30, 0, 600),
        startingBid = math.max(0, math.floor(tonumber(a.startingBid) or tonumber(dflt.startingBid) or 100000)),
        minBidIncrement = math.max(100, math.floor(tonumber(a.minBidIncrement) or tonumber(dflt.minBidIncrement) or 10000)),
        antiSnipeEnabled = a.antiSnipeEnabled ~= false and snipe.enabled ~= false,
        antiSnipeWindowSeconds = clamp(a.antiSnipeWindowSeconds or snipe.triggerSeconds or 10, 0, 60),
        antiSnipeExtendSeconds = clamp(a.antiSnipeExtendSeconds or snipe.extendSeconds or 15, 0, 120),
        zoneRadius = clamp(a.zoneRadius or acfg.zoneRadius or 12.0, 3, 100),
        bannerUrl = terrSafeText(a.bannerUrl, 2048),
        -- which banners this event sends (all on by default; the shared announcement system sends them)
        announce = {
            preEvent = not (type(a.announce) == 'table' and a.announce.preEvent == false),
            start = not (type(a.announce) == 'table' and a.announce.start == false),
            lots = not (type(a.announce) == 'table' and a.announce.lots == false),
            result = not (type(a.announce) == 'table' and a.announce.result == false),
            ended = not (type(a.announce) == 'table' and a.announce.ended == false),
        },
        -- the physical auction house: gang members walk into this zone and open the bidding window
        location = terrPoint(a.location, true),
        -- Bidding perimeter polygon: where gang members stand to bid
        zone = (function()
            local z = type(a.zone) == 'table' and a.zone or {}
            local pts = (type(z.points) == 'table' and z.points) or (type(a.zonePoints) == 'table' and a.zonePoints) or {}
            local out = {}
            for _, p in ipairs(pts) do
                if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and #out < 64 then
                    out[#out + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
                end
            end
            return (#out >= 1) and { points = out } or { points = {} }
        end)(),
        zonePoints = (function()
            local z = type(a.zone) == 'table' and a.zone or {}
            local pts = (type(z.points) == 'table' and z.points) or (type(a.zonePoints) == 'table' and a.zonePoints) or {}
            local out = {}
            for _, p in ipairs(pts) do
                if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and #out < 64 then
                    out[#out + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
                end
            end
            return out
        end)(),
        -- Projector placement (Prop Placer, context 'territory_projector'): CONFIGURATION ONLY. The prop is spawned when the
        -- auction really starts and removed when the event ends; this entry is never deleted by either.
        projector = (function()
            local p = EventProps and type(a.projector) == 'table' and EventProps.sanitize({ a.projector })[1] or nil
            if not p then return nil end
            p.model = tostring(acfg.projectorModel or 'prop_runlight_g')   -- it is always the projector model
            p.kind, p.stack, p.step = 'object', nil, nil
            p.uid = (p.uid and p.uid ~= '') and p.uid or ('projector_' .. tostring(existingDef and existingDef.id or 'new'))
            p.eventId = existingDef and existingDef.id or tonumber(a.projector.eventId) or nil
            local tid = terrSafeText(a.projector.territoryId, 64)
            p.territoryId = tid ~= '' and tid or nil
            -- how big the auction board is drawn over the projector (1.0 = Config.Territory.auction.screen); the admin picks it on the Projectors tab
            local scr = acfg.screen or {}
            p.screenScale = clamp(a.projector.screenScale or 1.0, tonumber(scr.minScale) or 0.4, tonumber(scr.maxScale) or 3.0)
            return p
        end)(),
    }

    local validGangs = {}
    for _, g in ipairs((GangService and GangService.GetGangs()) or {}) do validGangs[g.name] = true end

    local areas, seenIds = {}, {}
    local foreign, renamed = foreignTerritoryIds(existingDef), {}
    local maxAreas = math.floor(tonumber(tcfg.maxAreas) or 100)
    for i, ar in ipairs(type(raw.areas) == 'table' and raw.areas or {}) do
        if type(ar) == 'table' and #areas < maxAreas then
            local id = terrId(ar.id, 'territory_' .. i)
            if seenIds[id] then id = id .. '_' .. i end
            if foreign[id] then
                -- taken by another event: this area gets its own id (the event's id, or the time for a brand-new event)
                local suffix = existingDef and existingDef.id or (os.time() % 100000)
                local newId, n = id .. '_' .. tostring(suffix), 1
                while foreign[newId] or seenIds[newId] do n = n + 1; newId = id .. '_' .. tostring(suffix) .. '_' .. n end
                renamed[id] = newId
                id = newId
            end
            seenIds[id] = true

            local cs = clamp(ar.base and ar.base.cs or ar.cs or defaultCs, 5, 200)
            -- A territory has NO starting land: admins create the territory (its marker and capture spot) and gangs paint the land.
            -- A shape an older event kept in 'base' is dropped here, so it never shows up on the map again (it used to stay behind,
            -- wherever it had been drawn, even far from the territory's own location).
            local baseSpans = {}
            -- There are no predefined expansion levels any more: a gang grows its territory by PAINTING land and pays Gang XP
            -- per cell painted (Config.Territory.paint). Anything an older event stored under 'expansions' is dropped here.
            local expansions, used = {}, TerritoryGeo.count(baseSpans)

            local cap = type(ar.capture) == 'table' and ar.capture or {}
            local capPed = type(cap.ped) == 'table' and cap.ped or {}
            local capAnim = type(cap.anim) == 'table' and cap.anim or {}
            local wcap = ((tcfg.war or {}).capture) or {}
            local rule = tostring(cap.contestRule or wcap.contestRule or 'PAUSE'):upper()
            if rule ~= 'PAUSE' and rule ~= 'RESET' and rule ~= 'DECAY' then rule = 'PAUSE' end

            local blip = type(ar.blip) == 'table' and ar.blip or {}
            local tb = tcfg.blip or {}
            local owner = tostring(ar.startingOwner or '')
            if not validGangs[owner] then owner = '' end

            areas[#areas + 1] = {
                id = id,
                name = terrSafeText(ar.name ~= nil and ar.name or ('Territory ' .. i), 100),
                description = terrSafeText(ar.description, 400),
                startingOwner = owner,
                auctioned = ar.auctioned ~= false,
                startingBid = math.max(0, math.floor(tonumber(ar.startingBid) or auction.startingBid)),
                minBidIncrement = math.max(100, math.floor(tonumber(ar.minBidIncrement) or auction.minBidIncrement)),
                order = math.floor(tonumber(ar.order) or i),
                xpValue = math.max(0, math.floor(tonumber(ar.xpValue) or 0)),
                color = terrColor(ar.color, tcfg.defaultColor or '#e5484d'),
                image = terrSafeText(ar.image, 2048),
                imagePos = (type(ar.imagePos) == 'table' and tonumber(ar.imagePos.x) and tonumber(ar.imagePos.y))
                    and { x = tonumber(ar.imagePos.x), y = tonumber(ar.imagePos.y), size = clamp(ar.imagePos.size or 200, 20, 3000) } or nil,
                showName = ar.showName ~= false,
                location = terrPoint(ar.location, false),
                blip = {
                    enabled = blip.enabled ~= false,
                    sprite = math.floor(clamp(blip.sprite or tb.sprite or 310, 1, 900)),
                    colour = (blip.colour ~= nil and blip.colour ~= '' and blip.colour ~= 'auto') and math.floor(clamp(blip.colour, 0, 85)) or nil,   -- nil = follow the owner's colour
                    scale = clamp(blip.scale or tb.scale or 0.85, 0.3, 2.0),
                    shortRange = blip.shortRange ~= false,
                    label = terrSafeText(blip.label, 60),
                },
                base = { cs = cs, spans = baseSpans },
                expansions = expansions,
                capture = {
                    enabled = cap.enabled ~= false,
                    ped = {
                        model = terrSafeText(capPed.model ~= nil and capPed.model or wcap.pedModel or 'g_m_y_mexgoon_01', 50):gsub('[^%w_]', ''),
                        x = tonumber(capPed.x), y = tonumber(capPed.y), z = tonumber(capPed.z), heading = tonumber(capPed.heading) or 0.0,
                    },
                    anim = {
                        dict = terrSafeText(capAnim.dict ~= nil and capAnim.dict or (wcap.anim and wcap.anim.dict) or '', 80):gsub('[^%w_@%-%.]', ''),
                        clip = terrSafeText(capAnim.clip ~= nil and capAnim.clip or (wcap.anim and wcap.anim.clip) or '', 80):gsub('[^%w_@%-%.]', ''),
                    },
                    seconds = clamp(cap.seconds or wcap.seconds or 60, 5, 900),
                    radius = clamp(cap.radius or wcap.radius or 6.0, 1.5, 60),
                    interactDistance = clamp(cap.interactDistance or wcap.interactDistance or 2.5, 1.0, 10.0),
                    contestRule = rule,
                },
                -- visual props for the capture point, placed with the shared Prop Placer (spawned only while a war runs)
                props = EventProps and EventProps.sanitize(ar.props) or {},
            }
            local capPedOut = areas[#areas].capture.ped
            if not (capPedOut.x and capPedOut.y) then capPedOut.x, capPedOut.y, capPedOut.z = nil, nil, nil end
        end
    end
    table.sort(areas, function(x, y)
        if x.order ~= y.order then return x.order < y.order end
        return x.id < y.id
    end)
    -- the projector may name the territory it belongs to by its old id
    if auction.projector and auction.projector.territoryId and renamed[auction.projector.territoryId] then
        auction.projector.territoryId = renamed[auction.projector.territoryId]
    end
    return { auction = auction, areas = areas }
end

-- Rejects what sanitizing would otherwise quietly change, so the admin is told instead of finding out later.
local function validateTerritoryInput(input)
    local t = type(input.territory) == 'table' and input.territory or {}
    local tcfg = Config.Territory or {}
    if #(type(t.areas) == 'table' and t.areas or {}) > (tonumber(tcfg.maxAreas) or 100) then
        return ('A Gang Territory event supports at most %d territories.'):format(tonumber(tcfg.maxAreas) or 100)
    end
    local maxCells = math.floor(tonumber(tcfg.maxCellsPerTerritory) or 80000)
    for i, ar in ipairs(type(t.areas) == 'table' and t.areas or {}) do
        if type(ar) == 'table' then
            local used = 0
            local _, n, trunc = TerritoryGeo.normalizeSpans(ar.base and ar.base.spans, maxCells)
            used = used + n
            local over = trunc
            if over then
                return ('Territory "%s" is painted too large (more than %d map cells). Erase some of it.'):format(terrSafeText(ar.name or ('#' .. i), 40), maxCells)
            end
        end
    end
    return nil
end

-- ── CRACKDOWN (Gang vs Police) ──────────────────────────────────────────────────
-- def.crackdown: the target gang, the combat zone (a circle or a square: centre + radius / half-side; `points` is the same shape as
-- a polygon so the zone preview and any polygon check can read it), prep time, win conditions, the police reward and the announcement
-- texts. The gang's reward is the event's ordinary def.reward list. Nothing about the police team is stored: who counts as police is
-- decided live (police job + on duty).
local CD_MESSAGE_KEYS = { 'prepTitle', 'prepBody', 'startTitle', 'startBody', 'warning', 'winGang', 'winPolice', 'draw', 'cancelled' }

-- a start area is a drawn perimeter (the same editor Container Wars / TDM zones use): 3..24 points, or nothing
local function sanitizeStartArea(raw)
    local src = type(raw) == 'table' and (raw.points or raw) or {}
    local pts = {}
    for _, p in ipairs(src) do
        if #pts >= 24 then break end
        if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) then
            pts[#pts + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 }
        end
    end
    return #pts >= 3 and { points = pts } or nil
end

local function sanitizeCrackdownConfig(raw)
    raw = type(raw) == 'table' and raw or {}
    local d = (Config.Crackdown and Config.Crackdown.defaults) or {}
    local lim = (Config.Crackdown and Config.Crackdown.limits) or {}
    local z = type(raw.zone) == 'table' and raw.zone or {}
    local shape = tostring(z.shape or 'circle'):lower() == 'square' and 'square' or 'circle'
    local c = type(z.center) == 'table' and z.center or {}
    local zone = {}
    if tonumber(c.x) and tonumber(c.y) then
        local radius = clamp(z.radius or d.zoneRadius or 120.0, 15.0, lim.radiusMax or 600.0)
        local size = clamp(z.size or d.zoneSize or 120.0, 15.0, lim.radiusMax or 600.0)
        local cx, cy, cz = tonumber(c.x), tonumber(c.y), tonumber(c.z) or 0.0
        local points = {}
        if shape == 'circle' then
            for i = 0, 23 do
                local a = (i / 24) * math.pi * 2
                points[#points + 1] = { x = cx + math.cos(a) * radius, y = cy + math.sin(a) * radius, z = cz }
            end
        else
            points = { { x = cx - size, y = cy - size, z = cz }, { x = cx + size, y = cy - size, z = cz }, { x = cx + size, y = cy + size, z = cz }, { x = cx - size, y = cy + size, z = cz } }
        end
        zone = { shape = shape, center = { x = cx, y = cy, z = cz }, radius = radius, size = size, points = points }
    end
    local msgs = {}
    local rawMsgs = type(raw.messages) == 'table' and raw.messages or {}
    for _, k in ipairs(CD_MESSAGE_KEYS) do
        local t = terrSafeText(rawMsgs[k], 240)
        if t ~= '' then msgs[k] = t end
    end
    return {
        targetGang = terrSafeText(raw.targetGang, 64),
        zone = zone,
        startZones = { gang = sanitizeStartArea(type(raw.startZones) == 'table' and raw.startZones.gang), police = sanitizeStartArea(type(raw.startZones) == 'table' and raw.startZones.police) },
        prepSeconds = math.floor(clamp(raw.prepSeconds or d.prepSeconds or 120, 10, lim.prepMax or 1800)),
        outsideSeconds = math.floor(clamp(raw.outsideSeconds or d.outsideSeconds or 30, 5, lim.outsideMax or 300)),
        minGang = math.floor(clamp(raw.minGang or d.minGang or 1, 0, 50)),
        minPolice = math.floor(clamp(raw.minPolice or d.minPolice or 1, 0, 50)),
        gangLoseXpPenalty = math.floor(clamp(raw.gangLoseXpPenalty or d.gangLoseXpPenalty or 0, 0, 1000000)),
        policeReward = sanitizeRewardList(raw.policeReward),
        messages = msgs,
    }
end

-- Rejects what would make the event unplayable, so the admin is told when saving instead of finding out when it starts.
local function validateCrackdownInput(input)
    local cd = type(input.crackdown) == 'table' and input.crackdown or {}
    local gang = terrSafeText(cd.targetGang, 64)
    if gang == '' then return 'Pick the target gang for Operation Crackdown (Operation Setup tab).' end
    if not DB.getGangByName(gang) then return ('The gang "%s" does not exist (any more). Pick another target gang.'):format(gang) end
    local z = type(cd.zone) == 'table' and cd.zone or {}
    local c = type(z.center) == 'table' and z.center or {}
    if not (tonumber(c.x) and tonumber(c.y)) then return 'Place the combat zone first (Combat Zone tab).' end
    return nil
end

local function sanitizeDefinition(input, existingDef)
    local kind = (function()
        local k = tostring(input.kind or 'CONVOY'):upper()
        return VALID_KINDS[k] and k or 'CONVOY'
    end)()
    return {
        name = tostring(input.name or ''):sub(1, 100),
        shortDescription = tostring(input.shortDescription or ''):sub(1, 255),
        detailedDescription = tostring(input.detailedDescription or ''):sub(1, 4000),
        cargo = {
            type = tostring(input.cargo and input.cargo.type or 'CUSTOM'),
            description = tostring(input.cargo and input.cargo.description or ''):sub(1, 255),
        },
        -- A LIST of reward entries now, not one — lets a convoy pay out
        -- money AND items (or several different items) at once instead of
        -- being limited to a single type.
        reward = sanitizeRewardList(input.reward),
        -- 'CONVOY' (default): the full truck/route/checkpoint event. 'GANG_AIRDROP':
        -- a standalone, gang-only airdrop op with no trucks/route at all —
        -- see airdropZones below. Admin-only to create/edit (enforced in
        -- ConvoyManager.create/update, not here — this function just clamps
        -- whatever kind was requested to a valid value).
        kind = kind,
        difficulty = tostring(input.difficulty or 'MEDIUM'),
        -- a Territory Auction left at 0 minutes gets the default length (Config.Territory.auction.defaults.eventMinutes), not the 60 s minimum
        eventDuration = (kind == 'GANG_TERRITORY' and (tonumber(input.eventDuration) or 0) <= 0)
            and clamp(((Config.Territory and Config.Territory.auction and Config.Territory.auction.defaults and Config.Territory.auction.defaults.eventMinutes) or 30) * 60, 60, 7200)
            or clamp(input.eventDuration, 60, 7200),
        -- 0 is a deliberate, valid choice for either — a convoy with no
        -- police escort role at all, or no gang participation at all (e.g.
        -- a pure NPC/PvE run), not just an oversight to floor at 1.
        maxGangParticipants = clamp(input.maxGangParticipants or Config.MaxGangParticipants or 20, 1, Config.MaxGangParticipants or 20),
        maxPoliceParticipants = clamp(input.maxPoliceParticipants or Config.MaxPoliceParticipants or 20, 1, Config.MaxPoliceParticipants or 20),
        -- Caps how many on-demand escort vehicles (see EscortShop) can be
        -- checked out from the escort vehicle ped AT ONCE for this specific
        -- convoy — 0 disables the ped's "request vehicle" option entirely for
        -- this convoy (return-only). Independent of maxPoliceParticipants;
        -- an officer can join as an escort participant without ever taking a
        -- vehicle, or take a vehicle without formally joining.
        maxEscortVehicles = clamp(input.maxEscortVehicles, 0, Config.MaxPoliceParticipants),
        escortVehicleHealth = input.escortVehicleHealth ~= nil and clamp(input.escortVehicleHealth, 500, 100000) or nil,
        status = input.status or 'DRAFT',
        settings = {
            gangPvp = input.settings and input.settings.gangPvp and true or false,
            announcements = (input.settings == nil or input.settings.announcements ~= false),
            -- NPC police/army are enabled per-checkpoint now (Route tab,
            -- cp.npcPolice.enabled/cp.army.enabled) — there's no separate
            -- convoy-wide on/off switch to sanitize here any more. Appearance
            -- (ped/vehicle/weapon/behavior) is still convoy-wide, shared by
            -- every checkpoint's NPCs, and IS sanitized below — this used to
            -- be missing entirely, which silently discarded any admin
            -- customization on every save (NPCs always used the hardcoded
            -- default model/weapon regardless of what the old NPC Support
            -- tab showed).
            npcPoliceConfig = {
                model = tostring(input.settings and input.settings.npcPoliceConfig and input.settings.npcPoliceConfig.model or 's_m_y_cop_01'),
                vehicleModel = tostring(input.settings and input.settings.npcPoliceConfig and input.settings.npcPoliceConfig.vehicleModel or 'police3'),
                weapon = tostring(input.settings and input.settings.npcPoliceConfig and input.settings.npcPoliceConfig.weapon or 'WEAPON_CARBINERIFLE'),
                behavior = tostring(input.settings and input.settings.npcPoliceConfig and input.settings.npcPoliceConfig.behavior or 'GUARD_CHECKPOINT'),
            },
            armyConfig = {
                model = tostring(input.settings and input.settings.armyConfig and input.settings.armyConfig.model or 's_m_y_marine_03'),
                vehicleModel = tostring(input.settings and input.settings.armyConfig and input.settings.armyConfig.vehicleModel or 'barracks'),
                weapon = tostring(input.settings and input.settings.armyConfig and input.settings.armyConfig.weapon or 'WEAPON_CARBINERIFLE'),
                behavior = tostring(input.settings and input.settings.armyConfig and input.settings.armyConfig.behavior or 'GUARD_CHECKPOINT'),
            },
            -- FAIL (default) = zero surviving cargo trucks ends the convoy immediately.
            -- CONTINUE = the convoy keeps running with no cargo left (ends only via
            --   the delivery/event timer or an admin cancel — no cargo-transfer yet).
            -- CAPTURE = don't pre-empt a real capture in progress; let Runtime.finish's
            --   own outcome detection decide (CAPTURED if any truck was actually
            --   captured, FAILED otherwise).
            failurePolicy = (function()
                local v = tostring(input.settings and input.settings.failurePolicy or 'FAIL'):upper()
                return FAILURE_POLICIES[v] and v or 'FAIL'
            end)(),
            -- This convoy's own default for how many successful lockpick
            -- attempts it takes to crack open ANY of its lost trucks' loot —
            -- nil/blank means "fall back to Config.CapturedTruckLoot.lockpicksRequired".
            -- A specific truck (Trucks tab) can still override this per-truck.
            lockpicksRequired = tonumber(input.settings and input.settings.lockpicksRequired) or nil,
            -- This convoy's own police head-start before the public "Convoy
            -- Started" banner goes out server-wide (see
            -- Config.ConvoyStartAnnounceDelaySeconds) — nil/blank falls back
            -- to that config default. A harder/higher-stakes convoy might
            -- want police to get more (or less) time to get into position
            -- before gangs are alerted than the server's usual default.
            startAnnounceDelaySeconds = tonumber(input.settings and input.settings.startAnnounceDelaySeconds) or nil,
            -- Purely informational text (General tab) fed into the manual
            -- "Announce" button's banner (announceUpcomingConvoy in
            -- callbacks.lua) and CONVOY's own auto departure banner
            -- (releaseConvoy) — this function rebuilds `settings` field by
            -- field from whatever the admin saved, so these three were
            -- silently dropped on every single save (never even reaching
            -- the DB) until now: no matter what an admin typed here, the
            -- banner that's supposed to show it always saw blank fields.
            announceStartTime = tostring(input.settings and input.settings.announceStartTime or ''):sub(1, 60),
            announceEndTime = tostring(input.settings and input.settings.announceEndTime or ''):sub(1, 60),
            announceMessage = tostring(input.settings and input.settings.announceMessage or ''):sub(1, 255),
            -- A SEPARATE cap from maxGangParticipants above — that one limits
            -- total headcount across every gang combined, this one limits how
            -- many DIFFERENT gangs can be involved at all (e.g. "only 2 rival
            -- gangs fighting over this one, no more piling on" even if the
            -- headcount cap would technically allow a 3rd). 0/blank =
            -- unlimited (bounded only by maxGangParticipants itself).
            -- Enforced in ConvoyManager.setGangRoster (pre-registration) and
            -- Runtime.joinGang (live join).
            maxGangs = clamp(input.settings and input.settings.maxGangs, 0, 20),
            maxMembersPerGang = clamp(input.settings and input.settings.maxMembersPerGang, 0, Config.MaxGangParticipants),
            -- Whether joining this convoy as a gang participant or police
            -- escort force-enables drive-by shooting (see
            -- client/modules/driveby.lua) — on by default, but some convoys
            -- (e.g. a slower/more tactical one) may want it left off.
            forceDriveBy = (input.settings == nil or input.settings.forceDriveBy ~= false),
            -- true (default): the convoy only makes progress while a
            -- joined police officer is actually near it — halts in place
            -- (timer paused, a clear banner) otherwise. false: the convoy
            -- always keeps moving toward its destination regardless of
            -- who's nearby (server-side fallback drives it when no client
            -- is close enough to). See runtime's checkEscortProximity /
            -- nudgeUnobservedTrucks.
            requireEscortProximity = (input.settings == nil or input.settings.requireEscortProximity ~= false),
            -- HOT_CARGO/GANG_AIRDROP are both "open" events — any gang can
            -- normally steal the truck / loot the crate. This restricts that
            -- to specific admin-added gangs instead, same underlying gang
            -- roster GangService already manages (Gangs & Permissions tab).
            -- Ignored for CONVOY, which already has its own explicit
            -- roster/canParticipate gating (setGangRoster/joinGang).
            -- ── Gang Rally entry + vehicle rules (ignored by every other kind) ──
            -- TEAM: each gang registers up to maxMembersPerGang racers.
            -- OPEN: any number of a gang's members may register (bounded only by
            --   the total maxGangParticipants across all gangs).
            raceEntryMode = (function()
                return tostring(input.settings and input.settings.raceEntryMode or 'TEAM'):upper() == 'OPEN' and 'OPEN' or 'TEAM'
            end)(),
            -- ON: racers' vehicles collide normally. OFF: racers pass through each other
            -- (ghost mode) — clean racing, no ramming.
            raceCollision = tostring(input.settings and input.settings.raceCollision or 'ON'):upper() == 'OFF' and 'OFF' or 'ON',
            -- Seconds racers get to reach the start line before the GTA countdown
            -- runs. nil = Config.RallyRace.gridWaitSeconds.
            raceGridWaitSeconds = tonumber(input.settings and input.settings.raceGridWaitSeconds) or nil,
            -- OWN: racers bring their own vehicles. PROVIDED: registered racers
            -- take one of raceVehicles from the race vehicle ped (raceVehiclePed).
            raceVehicleMode = (function()
                return tostring(input.settings and input.settings.raceVehicleMode or 'OWN'):upper() == 'PROVIDED' and 'PROVIDED' or 'OWN'
            end)(),
            raceVehicles = (function()
                local list = {}
                local raw = input.settings and input.settings.raceVehicles
                if type(raw) == 'table' then
                    for _, v in ipairs(raw) do
                        if type(v) == 'table' and #list < 20 then
                            local model = tostring(v.model or ''):gsub('[^%w_]', ''):sub(1, 50)
                            if model ~= '' then
                                list[#list + 1] = { model = model, label = tostring(v.label or model):sub(1, 60) }
                            end
                        end
                    end
                end
                return list
            end)(),
            raceVehiclePed = (function()
                local p = input.settings and input.settings.raceVehiclePed
                if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) then
                    return { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0, heading = tonumber(p.heading) or 0.0 }
                end
                return nil
            end)(),
            allowedGangs = (function()
                local mode = tostring(input.settings and input.settings.allowedGangs and input.settings.allowedGangs.mode or 'ALL'):upper()
                if mode ~= 'SELECTED' then mode = 'ALL' end
                local validNames = {}
                for _, g in ipairs(GangService.GetGangs()) do validNames[g.name] = true end
                local seen, gangs = {}, {}
                for _, name in ipairs((input.settings and input.settings.allowedGangs and input.settings.allowedGangs.gangs) or {}) do
                    name = tostring(name)
                    if validNames[name] and not seen[name] then
                        seen[name] = true
                        gangs[#gangs + 1] = name
                    end
                end
                -- An empty selection under SELECTED mode would silently lock
                -- every gang out with no obvious reason why — most likely an
                -- admin who flipped the mode but hasn't picked anyone yet,
                -- not an intent to block the whole server. Falls back to ALL
                -- rather than saving a de-facto "nobody allowed" event.
                if mode == 'SELECTED' and #gangs == 0 then mode = 'ALL' end
                return { mode = mode, gangs = gangs }
            end)(),
            eventAccess = (function()
                local ea = tostring(input.settings and input.settings.eventAccess or 'GANGS'):upper()
                return ea == 'EVERYONE' and 'EVERYONE' or 'GANGS'
            end)(),
            civilianPed = (function()
                local p = input.settings and input.settings.civilianPed
                if type(p) == 'table' then
                    return {
                        enabled = p.enabled ~= false,
                        x = tonumber(p.x) or nil,
                        y = tonumber(p.y) or nil,
                        z = tonumber(p.z) or nil,
                        heading = tonumber(p.heading) or 0.0,
                        model = tostring(p.model or (kind == 'CONTAINER_WARS' and 's_m_m_dockwork_01' or 'a_m_y_runner_01')),
                    }
                end
                return nil
            end)(),
            airdropPlacement = (function()
                local m = input.settings and input.settings.airdropPlacement
                if m == 'SIMULTANEOUS' or m == 'MANUAL' or m == 'SEQUENTIAL' then return m end
                return 'SEQUENTIAL'
            end)(),
            airdropCount = math.max(1, math.min(50, math.floor(tonumber(input.settings and input.settings.airdropCount) or 10))),
            randomizeLocations = (input.settings and input.settings.randomizeLocations == true) or false,
            syncNpcSettings = (input.settings and input.settings.syncNpcSettings == true) or false,
            syncRewardSettings = (input.settings and input.settings.syncRewardSettings == true) or false,
            -- the Airdrop editor's MAIN settings: a template of guard + reward settings that is not a zone. New zones start from it, the
            -- runtime randomisation uses it, and the editor can apply it to any ticked zones. nil = not set yet.
            airdropMain = (function()
                local m = input.settings and input.settings.airdropMain
                if type(m) ~= 'table' then return nil end
                local rewards = {}
                for _, r in ipairs(type(m.rewards) == 'table' and m.rewards or {}) do
                    if type(r) == 'table' and #rewards < 20 then
                        local copy = {}
                        for k, v in pairs(r) do
                            local tv = type(v)
                            if (tv == 'string' or tv == 'number' or tv == 'boolean') and type(k) == 'string' then
                                copy[k] = tv == 'string' and v:sub(1, 120) or v
                            end
                        end
                        rewards[#rewards + 1] = copy
                    end
                end
                return {
                    guardCount = math.max(0, math.min(10, math.floor(tonumber(m.guardCount) or 3))),
                    guardModel = tostring(m.guardModel or 'g_m_y_lost_01'):sub(1, 60),
                    guardWeapon = tostring(m.guardWeapon or 'WEAPON_MICROSMG'):sub(1, 60),
                    guardAggressiveness = tostring(m.guardAggressiveness or 'medium'):sub(1, 20),
                    requireLockpick = m.requireLockpick ~= false,
                    lockpicksRequired = m.lockpicksRequired,
                    chance = math.max(0, math.min(100, math.floor(tonumber(m.chance) or 60))),
                    rewards = rewards,
                }
            end)(),
            bulkTargets = (function()
                local t = input.settings and input.settings.bulkTargets
                if type(t) ~= 'table' then return nil end
                local out = {}
                for _, id in ipairs(t) do
                    if type(id) == 'string' and id ~= '' and #out < 80 then out[#out + 1] = id:sub(1, 80) end
                end
                return out
            end)(),
        },
        trucks = (function()
            local list = {}
            for i, t in ipairs(input.trucks or {}) do
                if type(t) == 'table' then
                    local cleanRewards = sanitizeRewardList(t.reward or t.rewards)
                    list[#list + 1] = {
                        id = tostring(t.id or ('truck_' .. i)),
                        role = tostring(t.role or 'PRIMARY_CARGO'),
                        model = tostring(t.model or 'barracks'):sub(1, 50),
                        label = tostring(t.label or t.model or 'Truck'):sub(1, 60),
                        price = tonumber(t.price) or 0,
                        npcDriver = t.npcDriver ~= false,
                        npcModel = tostring(t.npcModel or 's_m_m_marine_01'):sub(1, 50),
                        health = tonumber(t.health) or 1500,
                        engineHealth = tonumber(t.engineHealth) or 1000,
                        speed = math.max(0.2, math.min(2.0, tonumber(t.speed) or 0.6)),
                        formationOffset = tonumber(t.formationOffset) or 0,
                        lockpicksRequired = (t.lockpicksRequired ~= '' and tonumber(t.lockpicksRequired)) or nil,
                        reward = cleanRewards,
                        rewards = cleanRewards,
                    }
                end
            end
            return list
        end)(),
        route = input.route or {},
        checkpoints = (select(1, splitCheckpointList(input))),
        pointSupport = (select(2, splitCheckpointList(input))),
        airdrops = (function()
            local list = {}
            for i, a in ipairs(input.airdrops or {}) do
                local name = tostring(a.name or a.label or ('Airdrop ' .. i)):sub(1, 100)
                list[#list + 1] = {
                    routePointId = a.routePointId,
                    name = name,
                    label = name,
                    enabled = a.enabled ~= false,
                    activationDelay = clamp(a.activationDelay, 0, 3600),
                    duration = clamp(a.duration, 10, 3600),
                    announce = a.announce ~= false,
                    guardCount = clamp(a.guardCount, 0, 10),
                    requireLockpick = a.requireLockpick ~= false,
                    lockpicksRequired = tonumber(a.lockpicksRequired) or nil,
                    chance = clamp(a.chance, 0, 100),
                    rewards = sanitizeRewardList(a.rewards),
                }
            end
            return list
        end)(),
        breaks = input.breaks or {},
        ambushes = input.ambushes or {},
        -- Standalone drop zones for a GANG_AIRDROP-kind convoy — see
        -- sanitizeAirdropZone. Ignored/unused for an ordinary CONVOY.
        airdropZones = (function()
            local list = {}
            for i, z in ipairs(input.airdropZones or {}) do
                list[#list + 1] = sanitizeAirdropZone(z, i)
            end
            return list
        end)(),
        hotCargo = sanitizeHotCargoConfig(input.hotCargo),
        rallyStages = sanitizeRallyStages(input.rallyStages or input.stages),
        tdm = sanitizeTdmConfig(input.tdm, existingDef and existingDef.tdm and existingDef.tdm.bracket),
        containerWars = sanitizeContainerWarsConfig(input.containerWars),
        -- GANG_TERRITORY only; empty for every other kind
        territory = (kind == 'GANG_TERRITORY') and sanitizeTerritoryConfig(input.territory, existingDef) or {},
        -- CRACKDOWN only; empty for every other kind
        crackdown = (kind == 'CRACKDOWN') and sanitizeCrackdownConfig(input.crackdown) or {},
        -- Props / vehicles placed with the shared Prop Placer for the whole event (every kind) — they are
        -- spawned when the event goes ACTIVE and removed when it ends (server/modules/event_props.lua).
        -- CONTAINER_WARS exclusively uses the harbour yard / containers, so event props are cleared to prevent fake drops.
        props = (input.kind == 'CONTAINER_WARS') and {} or (EventProps and EventProps.sanitize(input.props) or {}),
        -- GANG_RACE only: per-finishing-position reward lists, alongside (not
        -- replacing) the single `reward` list above — first/second/third pay
        -- out to whichever racer finished in that exact spot, participation
        -- pays out to every other finisher outside the top 3. Each is its own
        -- reward list (money/items/tokens), same shape as `reward`. Harmless
        -- on any other kind — just never read there.
        positionRewards = (function()
            local pr = input.positionRewards or {}
            return {
                first = sanitizeRewardList(pr.first),
                second = sanitizeRewardList(pr.second),
                third = sanitizeRewardList(pr.third),
                participation = sanitizeRewardList(pr.participation),
            }
        end)(),
        -- Recurring auto-start rule — see sanitizeRecurrence above. Not
        -- restricted to any one kind at the data-model level, but the
        -- creator UI currently only exposes it for GANG_AIRDROP and HOT_CARGO.
        recurrence = sanitizeRecurrence(input.recurrence),
        -- Physical in-world ped players / police can interact with to trigger THIS
        -- convoy/race once its scheduled time arrives (see Runtime's
        -- triggerStartPed handler) — a location, not a schedule, so unlike
        -- scheduledAt it survives a normal edit/save. GANG_AIRDROP and HOT_CARGO events
        -- have no start ped, so this is force-disabled below.
        startPed = {
            -- TDM and CONTAINER_WARS have no physical start-trigger ped — same as GANG_AIRDROP/
            -- HOT_CARGO, the admin starts it directly from the tablet once
            -- ready, or it starts via schedule.
            enabled = (kind ~= 'GANG_AIRDROP' and kind ~= 'HOT_CARGO' and kind ~= 'TDM' and kind ~= 'CONTAINER_WARS' and kind ~= 'GANG_TERRITORY' and kind ~= 'CRACKDOWN') and input.startPed and input.startPed.enabled and true or false,
            x = input.startPed and tonumber(input.startPed.x) or nil,
            y = input.startPed and tonumber(input.startPed.y) or nil,
            z = input.startPed and tonumber(input.startPed.z) or nil,
            model = (kind == 'GANG_RACE' and (not input.startPed or not input.startPed.model or input.startPed.model == Config.Peds.convoyStart or input.startPed.model == '')) and Config.Peds.raceStart or tostring(input.startPed and input.startPed.model or Config.Peds.convoyStart),
        },
    }
end

function ConvoyManager.loadAll()
    -- A failed query must not be mistaken for "no events": keep retrying a few
    -- times rather than caching an empty list (see the DB-wait in main.lua).
    local defs
    for attempt = 1, 5 do
        local ok, res = pcall(DB.getAllConvoyDefinitions)
        if ok and res then defs = res break end
        print(('^1[NovaConvoy] Loading events failed (attempt %d/5): %s^0'):format(attempt, tostring(res)))
        Wait(2000)
    end
    cache = {}
    for _, def in ipairs(defs or {}) do
        cache[def.id] = def
    end
    print(('[NovaConvoy] Loaded %d event(s).'):format(#(defs or {})))
end

function ConvoyManager.getAll()
    local list = {}
    for _, def in pairs(cache) do
        list[#list + 1] = def
    end
    table.sort(list, function(a, b) return (a.updatedAt or '') > (b.updatedAt or '') end)
    return list
end

function ConvoyManager.get(id)
    return cache[id]
end

local function requestedKind(input)
    local k = tostring(input.kind or 'CONVOY'):upper()
    return VALID_KINDS[k] and k or 'CONVOY'
end

function ConvoyManager.create(source, input)
    local k = requestedKind(input)
    if #input.name < 3 then
        return false, (KIND_LABELS[k] or 'Convoy') .. ' name must be at least 3 characters.'
    end
    if ADMIN_ONLY_KINDS[k] and not UserPermissions.can(source, 'create.manage') then
        return false, ('Only staff with Create Event → Manage can create a %s event.'):format(KIND_LABELS[k] or k)
    end
    if k == 'TDM' then
        local format = tostring(input.tdm and input.tdm.matchFormat or 'STANDARD'):upper()
        local allowed = input.settings and input.settings.allowedGangs
        local gangCount = (allowed and allowed.mode == 'SELECTED') and #(allowed.gangs or {}) or 0
        if format ~= 'TOURNAMENT' and gangCount ~= 2 then
            return false, 'Standard TDM requires exactly 2 participating gangs.'
        end
    end
    if k == 'GANG_TERRITORY' then
        local terr = validateTerritoryInput(input)
        if terr then return false, terr end
    end
    if k == 'CRACKDOWN' then
        local cdErr = validateCrackdownInput(input)
        if cdErr then return false, cdErr end
    end
    if countActiveDefinitions() >= Config.MaxConvoys then
        return false, ('Maximum of %d events already exist. Complete or cancel one first.'):format(Config.MaxConvoys)
    end

    local def = sanitizeDefinition(input)
    def.createdBy = Bridge.GetIdentifier(source)
    def.createdByName = Bridge.GetCharacterName(source)
    def.roster = {}
    def.policeRoster = {}

    local id = DB.createConvoyDefinition(def)
    def.id = id
    -- the projector remembers which event it belongs to (known only now that the event has an id)
    if def.territory and def.territory.auction and def.territory.auction.projector then
        local pr = def.territory.auction.projector
        pr.eventId = id
        if pr.uid == 'projector_new' then pr.uid = 'projector_' .. tostring(id) end
        DB.updateConvoyDefinition(id, def)
    end
    cache[id] = DB.getConvoyDefinition(id)

    if def.settings.gangPvp then notifyGangMembers(cache[id]) end
    ConvoyManager.broadcastStartPeds()

    return true, cache[id]
end

function ConvoyManager.update(source, id, input)
    local existing = cache[id]
    if not existing then return false, 'Event not found.' end
    if existing.status ~= 'DRAFT' and existing.status ~= 'SCHEDULED' then
        return false, 'Only draft or scheduled events can be edited.'
    end
    if (ADMIN_ONLY_KINDS[existing.kind] or ADMIN_ONLY_KINDS[requestedKind(input)])
        and not UserPermissions.can(source, 'create.manage') then
        return false, 'Only staff with Create Event → Manage can edit specialized events.'
    end
    if requestedKind(input) == 'TDM' then
        local format = tostring(input.tdm and input.tdm.matchFormat or 'STANDARD'):upper()
        local allowed = input.settings and input.settings.allowedGangs
        local gangCount = (allowed and allowed.mode == 'SELECTED') and #(allowed.gangs or {}) or 0
        if format ~= 'TOURNAMENT' and gangCount ~= 2 then
            return false, 'Standard TDM requires exactly 2 participating gangs.'
        end
    end

    if requestedKind(input) == 'GANG_TERRITORY' then
        local terr = validateTerritoryInput(input)
        if terr then return false, terr end
    end
    if requestedKind(input) == 'CRACKDOWN' then
        local cdErr = validateCrackdownInput(input)
        if cdErr then return false, cdErr end
    end

    local def = sanitizeDefinition(input, existing)
    def.roster = existing.roster -- gang-leader-managed, not part of the creator's edit form
    def.policeRoster = existing.policeRoster -- individual officer self-registration, same deal
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    -- a published (scheduled) territory event: its territories on the map follow the edit
    if existing.status == 'SCHEDULED' then publishTerritory(cache[id]) end

    return true, cache[id]
end

-- Gang-leader-only: replaces THEIR gang's slice of the roster (other gangs'
-- entries are untouched). Only identifiers that are actually members of the
-- caller's gang are kept. Locked once the convoy has departed (ACTIVE+) so a
-- leader can't pad it mid-run to sneak late joiners into the reward pool —
-- Runtime.joinGang checks this same roster before a player becomes a tracked
-- participant, so padding names nobody ever plays does not grant them anything.
-- How many racers/participants `gangName` may register for this event. For every
-- kind but Gang Rally that is simply the event's participant cap. For a rally:
-- TEAM entry caps each gang at settings.maxMembersPerGang; OPEN entry has no
-- per-gang limit; in both, the TOTAL across all gangs never exceeds
-- maxGangParticipants (other gangs' registrations use up part of it).
function ConvoyManager.rosterCapFor(def, gangName)
    local total = tonumber(def.maxGangParticipants) or Config.MaxGangParticipants or 20
    if def.kind ~= 'GANG_RACE' then return total end
    local s = def.settings or {}
    local cap = total
    -- an Open to Everyone race has no per-gang limit (the setting is hidden in the form then, so it must not apply here either)
    local everyone = tostring(s.eventAccess or def.eventAccess or ''):upper() == 'EVERYONE'
    if (s.raceEntryMode or 'TEAM') == 'TEAM' and not everyone then
        local per = tonumber(s.maxMembersPerGang) or 0
        if per > 0 then cap = math.min(cap, per) end
    end
    local others = 0
    for gName, list in pairs(def.roster or {}) do
        if gName ~= gangName then others = others + #list end
    end
    return math.max(0, math.min(cap, total - others))
end

function ConvoyManager.setGangRoster(source, id, identifiers)
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then
        return false, 'Rosters can only be set before the event starts.'
    end
    if not def.settings.gangPvp then return false, 'Gang participation is disabled for this event.' end
    -- Same rule as Runtime.joinGang — an on-duty officer must never be able
    -- to act on behalf of a gang, even one they're nominally a leader/member
    -- of from earlier testing/other characters.
    if Bridge.IsPolice(source) then return false, 'On-duty police cannot manage a gang roster.' end

    local gang = GangService.GetPlayerGang(source)
    if not gang then return false, 'You are not in a gang.' end

    local myGang
    for _, g in ipairs(GangService.GetGangs()) do
        if g.name == gang.name then myGang = g break end
    end
    if not myGang then return false, 'Gang not found.' end
    if myGang.canParticipate == false then return false, 'Your gang is not permitted to participate in events.' end

    -- TDM is invite-only by design (spec: "the admin must be able to decide
    -- exactly which gangs can participate — TDM should NOT automatically
    -- allow every gang on the server"). Unlike HOT_CARGO/GANG_AIRDROP's
    -- allowedGangs (audience-only, everyone can still physically loot the
    -- truck), this is a hard registration gate — a non-selected gang simply
    -- cannot sign up at all, matching a curated 2-gang or bracket roster.
    if def.kind == 'TDM' then
        local ag = def.settings and def.settings.allowedGangs
        local isSelected = ag and ag.mode == 'SELECTED'
        local eligible = not isSelected
        if isSelected then
            for _, name in ipairs(ag.gangs or {}) do
                if name == gang.name then eligible = true break end
            end
        end
        if not eligible then return false, 'Your gang was not selected to participate in this TDM event.' end
    end

    -- Authoritative gate for roster writes. Uses the central resolver rather
    -- than a raw leaderIdentifier comparison so a role the leader granted
    -- 'registerRoster' can sign the gang up on their behalf — the UI hiding
    -- the button is not the control, this is.
    if not GangService.HasPermission(source, 'registerRoster') then
        return false, 'You do not have permission to set the event roster.'
    end

    local memberSet = {}
    for _, m in ipairs(myGang.members or {}) do memberSet[m.identifier] = true end

    local clean, seen = {}, {}
    for _, ident in ipairs(identifiers or {}) do
        if type(ident) == 'string' and memberSet[ident] and not seen[ident] then
            seen[ident] = true
            clean[#clean + 1] = ident
        end
    end

    local cap = ConvoyManager.rosterCapFor(def, gang.name)
    if #clean > cap then
        if def.kind == 'GANG_RACE' then
            return false, ('Your gang can register at most %d racer%s for this race.'):format(cap, cap == 1 and '' or 's')
        end
        return false, ('Roster exceeds the event limit of %d participants.'):format(cap)
    end

    -- maxGangs (separate from the headcount cap above) — how many DIFFERENT
    -- gangs may be involved at all. Only blocks a gang that isn't ALREADY
    -- one of the registered ones and is trying to add its first member(s);
    -- clearing your own roster back to empty, or adjusting an already-
    -- counted gang's picks, never trips this.
    local maxGangs = def.settings and def.settings.maxGangs
    if maxGangs and maxGangs > 0 and #clean > 0 then
        local alreadyRegistered = def.roster and def.roster[gang.name] and #def.roster[gang.name] > 0
        if not alreadyRegistered then
            local gangCount = 0
            for _, list in pairs(def.roster or {}) do
                if #list > 0 then gangCount = gangCount + 1 end
            end
            if gangCount >= maxGangs then
                return false, ('This event already has the maximum of %d gangs registered.'):format(maxGangs)
            end
        end
    end

    -- Diffed against the PRE-save roster so the caller (setConvoyRoster in
    -- callbacks.lua) can toast exactly who's newly signed up / dropped —
    -- this function stays free of TriggerClientEvent/toast concerns, same
    -- separation the rest of this module already keeps from callbacks.lua.
    local previous = (def.roster and def.roster[gang.name]) or {}
    local previousSet, cleanSet = {}, {}
    for _, ident in ipairs(previous) do previousSet[ident] = true end
    for _, ident in ipairs(clean) do cleanSet[ident] = true end
    local added, removed = {}, {}
    for _, ident in ipairs(clean) do if not previousSet[ident] then added[#added + 1] = ident end end
    for _, ident in ipairs(previous) do if not cleanSet[ident] then removed[#removed + 1] = ident end end

    def.roster = def.roster or {}
    def.roster[gang.name] = clean
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)

    return true, cache[id], added, removed
end

-- Gang-level sign-up for the auction events (Container Wars, Gang Territory Auction): the whole gang registers or unregisters with one
-- click, no member list. It is stored as the gang's roster slice (every member's identifier at the time), so the counts and reports that
-- read def.roster keep working; what counts is whether the gang has an entry. A registered gang's members may all bid.
function ConvoyManager.setGangRegistered(source, id, on)
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.kind ~= 'CONTAINER_WARS' and def.kind ~= 'GANG_TERRITORY' then return false, 'This event is registered with a member roster.' end
    if def.kind == 'CONTAINER_WARS' and tostring((def.settings and def.settings.eventAccess) or def.eventAccess or ''):upper() == 'EVERYONE' then return false, 'This event is open to everyone: no gang registration is needed.' end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then return false, 'A gang can only register or unregister before the event starts.' end
    if Bridge.IsPolice(source) then return false, 'On-duty police cannot manage a gang registration.' end
    local gang = GangService.GetPlayerGang(source)
    if not gang then return false, 'You are not in a gang.' end
    local myGang
    for _, g in ipairs(GangService.GetGangs()) do
        if g.name == gang.name then myGang = g break end
    end
    if not myGang then return false, 'Gang not found.' end
    if myGang.canParticipate == false then return false, 'Your gang is not permitted to participate in events.' end
    if not GangService.HasPermission(source, 'registerRoster') then return false, 'You do not have permission to register the gang.' end

    local ag = def.settings and def.settings.allowedGangs
    if on and ag and ag.mode == 'SELECTED' and (def.settings.eventAccess or def.eventAccess) ~= 'EVERYONE' then
        local ok = false
        for _, name in ipairs(ag.gangs or {}) do if name == gang.name then ok = true break end end
        if not ok then return false, 'Your gang was not invited to this event.' end
    end

    def.roster = def.roster or {}
    local already = def.roster[gang.name] and #def.roster[gang.name] > 0
    if on then
        local maxGangs = def.settings and tonumber(def.settings.maxGangs)
        if maxGangs and maxGangs > 0 and not already then
            local n = 0
            for _, list in pairs(def.roster) do if #list > 0 then n = n + 1 end end
            if n >= maxGangs then return false, ('This event already has the maximum of %d gangs registered.'):format(maxGangs) end
        end
        local ids = {}
        for _, m in ipairs(myGang.members or {}) do ids[#ids + 1] = m.identifier end
        if #ids == 0 then return false, 'Your gang has no members.' end
        def.roster[gang.name] = ids
    else
        def.roster[gang.name] = {}
    end
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    return true, cache[id]
end

-- Does this gang hold a gang-level registration for the event? (Config.AuctionRegistration.required turns the check off.)
function ConvoyManager.isGangRegistered(def, gangName)
    if (Config.AuctionRegistration or {}).required == false then return true end
    local list = def and def.roster and def.roster[gangName]
    return list ~= nil and #list > 0
end

-- A regular gang member backing THEMSELVES out of a convoy their leader
-- signed them up for — unlike setGangRoster above (leader-only, replaces
-- the WHOLE roster list at once), this only ever removes the calling
-- player's own identifier, so someone who's changed their mind doesn't have
-- to go find their leader and ask to be taken off. Same DRAFT/SCHEDULED-only
-- lock as setGangRoster — once the convoy departs, nobody (leader, member,
-- or admin) can touch the roster at all any more.
function ConvoyManager.selfUnregisterGang(source, id)
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then
        return false, 'Rosters can only be changed before the event starts.'
    end
    if Bridge.IsPolice(source) then return false, 'On-duty police cannot manage a gang roster.' end

    local gang = GangService.GetPlayerGang(source)
    if not gang then return false, 'You are not in a gang.' end
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Player identifier unavailable.' end

    local current = (def.roster and def.roster[gang.name]) or {}
    local found, clean = false, {}
    for _, ident in ipairs(current) do
        if ident == identifier then found = true else clean[#clean + 1] = ident end
    end
    if not found then return false, 'You are not registered for this event.' end

    def.roster = def.roster or {}
    def.roster[gang.name] = clean
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    return true, cache[id]
end

-- Individual police pre-registration for an UPCOMING (draft/scheduled)
-- convoy — the escort-side equivalent of a gang leader's roster sign-up
-- above, just without a leader concept: police have no gang-style
-- hierarchy, so any officer registers/unregisters themselves directly
-- instead of a leader curating a list on their behalf. Runtime.start
-- auto-joins whoever's still online and registered when the convoy departs
-- (see doStart in convoy_runtime.lua) — this list is a heads-up/reservation,
-- not itself a live join.
function ConvoyManager.registerPolice(source, id)
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then
        return false, 'You can only pre-register before the convoy departs.'
    end
    if def.kind == 'GANG_AIRDROP' or def.kind == 'HOT_CARGO' or def.kind == 'TDM' or def.kind == 'GANG_TERRITORY' or def.kind == 'CRACKDOWN' then return false, 'This event does not use police escort pre-registration.' end
    if not Bridge.IsPolice(source) then return false, 'Only police may pre-register as an escort.' end
    if def.maxPoliceParticipants and tonumber(def.maxPoliceParticipants) == 0 then
        return false, 'This convoy has 0 police escort spots configured.'
    end

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Player identifier unavailable.' end
    def.policeRoster = def.policeRoster or {}
    for _, entry in ipairs(def.policeRoster) do
        if entry.identifier == identifier then return true, def end -- already registered
    end
    local maxCap = (def.maxPoliceParticipants and tonumber(def.maxPoliceParticipants) > 0) and tonumber(def.maxPoliceParticipants) or (Config.MaxPoliceParticipants or 20)
    if #def.policeRoster >= maxCap then
        return false, 'Escort roster is full.'
    end
    -- Name captured at registration time (not resolved later from
    -- identifier) so the admin tablet's roster view still shows a real name
    -- even if the officer isn't online when an admin looks — same reasoning
    -- as rt.participants.names in convoy_runtime.lua.
    def.policeRoster[#def.policeRoster + 1] = { identifier = identifier, name = Bridge.GetPlayerName(source) }
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    return true, cache[id]
end

function ConvoyManager.unregisterPolice(source, id)
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Player identifier unavailable.' end

    local next = {}
    for _, entry in ipairs(def.policeRoster or {}) do
        if entry.identifier ~= identifier then next[#next + 1] = entry end
    end
    def.policeRoster = next
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    return true, cache[id]
end

-- Moves a DRAFT convoy to SCHEDULED with a true-UTC auto-start timestamp (see
-- server/modules/scheduler.lua for how that timestamp should be produced).
-- The scheduler thread picks it up and calls Runtime.startScheduled once due.
function ConvoyManager.schedule(source, id, timestamp)
    if not UserPermissions.can(source, 'convoys.manage') then return false, 'Not authorized.' end
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.status ~= 'DRAFT' then return false, 'Only draft events can be scheduled.' end

    timestamp = tonumber(timestamp)
    if not timestamp then return false, 'A schedule date/time is required.' end
    if timestamp <= Scheduler.nowUtc() then return false, 'Scheduled time must be in the future.' end

    def.status = 'SCHEDULED'
    def.scheduledAt = timestamp
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    publishTerritory(cache[id])
    return true, cache[id]
end

-- Moves a DRAFT convoy to SCHEDULED using its OWN recurrence rule to compute
-- the first fire time, instead of an admin picking one manually — this is
-- what unifies "Recurring Schedule" into the single Schedule card the admin
-- sees: turning the toggle on and hitting Activate is enough, the exact same
-- way a repeating convoy automatically re-arms itself (Scheduler.rearm) for
-- every occurrence AFTER this first one. Every occurrence past the first was
-- already 100% automatic before this existed; this just closes the one gap
-- where the admin still had to separately use the one-off scheduler once to
-- kick a recurring convoy off in the first place.
function ConvoyManager.scheduleRecurring(source, id)
    if not UserPermissions.can(source, 'convoys.manage') then return false, 'Not authorized.' end
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.status ~= 'DRAFT' then return false, 'Only draft events can be scheduled.' end
    if not def.recurrence or not def.recurrence.enabled then
        return false, 'Turn on "Repeat this event automatically" first.'
    end

    local nextAt = Scheduler.nextOccurrence(def.recurrence, Scheduler.nowUtc(), false)
    if not nextAt then return false, 'Could not compute the next occurrence for this cadence.' end

    def.status = 'SCHEDULED'
    def.scheduledAt = nextAt
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    publishTerritory(cache[id])
    return true, cache[id]
end

-- Internal, access-check-free variant of ConvoyManager.schedule above — used
-- only by Scheduler.rearm to advance a recurring convoy/airdrop straight
-- from its just-finished terminal status (COMPLETED/CAPTURED/FAILED/
-- CANCELLED) back to SCHEDULED with its next computed occurrence. No player
-- source behind this call (the scheduler fires it on a timer, not a
-- player), and unlike the player-facing version it doesn't require DRAFT
-- first — a recurring event is always coming from a terminal status here,
-- never DRAFT.
function ConvoyManager.scheduleInternal(id, timestamp)
    local def = cache[id]
    if not def then return false end
    def.status = 'SCHEDULED'
    def.scheduledAt = timestamp
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    return true
end

-- Reverts a SCHEDULED convoy back to DRAFT and clears its auto-start time.
function ConvoyManager.unschedule(source, id)
    if not UserPermissions.can(source, 'convoys.manage') then return false, 'Not authorized.' end
    local def = cache[id]
    if not def then return false, 'Event not found.' end
    if def.status ~= 'SCHEDULED' then return false, 'Event is not scheduled.' end

    def.status = 'DRAFT'
    def.scheduledAt = nil
    -- Also turns off the recurrence rule itself, not just this occurrence —
    -- "Unschedule" is the one button that stops all automation for this
    -- convoy, one-off or recurring alike. Without this, reopening the Schedule
    -- card afterward would still show "Recurring, ON" even though nothing
    -- is actually scheduled, which is exactly the confusing half-armed state
    -- this whole merge was meant to get rid of. The cadence fields (day/hour/
    -- window/etc.) are left untouched so re-enabling later doesn't need
    -- re-entering them.
    if def.recurrence then def.recurrence.enabled = false end
    DB.updateConvoyDefinition(id, def)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    return true, cache[id]
end

local REUSABLE_STATUSES = { CANCELLED = true, COMPLETED = true, CAPTURED = true, FAILED = true }

-- Resets a finished convoy (cancelled/completed/captured/failed) back to a
-- fresh Draft, keeping every other field (trucks/route/settings/reward)
-- exactly as it was — an admin can then Start/Schedule it again through the
-- normal flow instead of rebuilding an identical convoy from scratch.
-- Deliberately its own narrow operation, not routed through
-- ConvoyManager.update, which intentionally refuses to touch anything that
-- isn't already Draft/Scheduled.
function ConvoyManager.reuse(id)
    local existing = cache[id]
    if not existing then return false, 'Event not found.' end
    if not REUSABLE_STATUSES[existing.status] then
        return false, 'Only a finished (cancelled/completed/captured/failed) event can be reused.'
    end
    existing.status = 'DRAFT'
    existing.scheduledAt = nil
    if RaceVehicles then RaceVehicles.reset(id) end
    if EventProps then EventProps.stop(id) end
    -- Clear previous participants so they must sign up / join again
    existing.roster = {}
    existing.policeRoster = {}
    -- A reused Tournament TDM starts a brand new tournament — last time's
    -- bracket (byes/results/champion) must not bleed into this run.
    if existing.tdm and existing.tdm.bracket then existing.tdm.bracket = {} end
    DB.updateConvoyDefinition(id, existing)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    return true, cache[id]
end

function ConvoyManager.clone(source, id, newName)
    local existing = cache[id]
    if not existing then return false, 'Event not found.' end

    if not newName or #newName < 3 then
        return false, 'Clone event name must be at least 3 characters.'
    end

    local k = existing.kind or 'CONVOY'
    if ADMIN_ONLY_KINDS[k] and not UserPermissions.can(source, 'create.manage') then
        return false, ('Only staff with Create Event → Manage can clone a %s event.'):format(KIND_LABELS[k] or k)
    end

    if countActiveDefinitions() >= Config.MaxConvoys then
        return false, ('Maximum of %d events already exist. Complete or cancel one first.'):format(Config.MaxConvoys)
    end

    local copy = json.decode(json.encode(existing))
    copy.id = nil
    copy.name = newName:gsub('^%s*(.-)%s*$', '%1')
    copy.status = 'DRAFT'
    copy.scheduledAt = nil
    copy.recurrence = copy.recurrence or { enabled = false, mode = 'HOURLY', intervalHours = 4 }
    copy.recurrence.enabled = false
    copy.createdBy = Bridge.GetIdentifier(source)
    copy.createdByName = Bridge.GetCharacterName(source)
    copy.roster = {}
    copy.policeRoster = {}
    -- A clone is a brand new event — never inherit the source's tournament
    -- bracket state (byes/results/champion already decided for a run this
    -- copy never played).
    if copy.tdm then copy.tdm.bracket = {} end

    local def = sanitizeDefinition(copy)
    def.createdBy = copy.createdBy
    def.createdByName = copy.createdByName
    def.roster = {}
    def.policeRoster = {}

    local newId = DB.createConvoyDefinition(def)
    def.id = newId
    cache[newId] = DB.getConvoyDefinition(newId)

    ConvoyManager.broadcastStartPeds()

    return true, cache[newId]
end

function ConvoyManager.setStatus(id, status)
    local existing = cache[id]
    if not existing then return false, 'Event not found.' end
    if FINISHED_STATUSES[status] and RaceVehicles then RaceVehicles.reset(id) end
    -- An event that ends (finished, failed or FORCE-ended: every path goes through here) takes its on-screen timers and panels with it
    -- on every client. The per-event cleanups each hid some of them; the ones they missed stayed on screen.
    if FINISHED_STATUSES[status] then TriggerClientEvent('nova_convoytruck:runtime:endHud', -1, existing.kind or 'CONVOY') end
    if EventProps then EventProps.onStatus(id, status) end   -- the event's placed props appear / disappear with it
    existing.status = status
    DB.updateConvoyDefinition(id, existing)
    cache[id] = DB.getConvoyDefinition(id)
    ConvoyManager.broadcastStartPeds()
    if status == 'ACTIVE' then publishTerritory(cache[id]) end
    return true, cache[id]
end

function ConvoyManager.delete(id)
    if not cache[id] then return false, 'Event not found.' end
    if EventProps then EventProps.stop(id) end
    DB.deleteConvoyDefinition(id)
    cache[id] = nil
    ConvoyManager.broadcastStartPeds()
    return true
end

function ConvoyManager.getDashboardStats()
    local stats = { draft = 0, scheduled = 0, active = 0, completed = 0, captured = 0, cancelled = 0, total = 0 }
    for _, def in pairs(cache) do
        stats.total = stats.total + 1
        if def.status == 'DRAFT' then stats.draft = stats.draft + 1
        elseif def.status == 'SCHEDULED' then stats.scheduled = stats.scheduled + 1
        elseif def.status == 'COMPLETED' then stats.completed = stats.completed + 1
        elseif def.status == 'CAPTURED' then stats.captured = stats.captured + 1
        elseif def.status == 'CANCELLED' then stats.cancelled = stats.cancelled + 1
        elseif def.status == 'ACTIVE' or def.status == 'CHECKPOINT' or def.status == 'UNDER_ATTACK' or def.status == 'DELIVERY' then
            stats.active = stats.active + 1
        end
    end
    return stats
end

-- A freshly-connecting officer needs the current start-ped list too, not
-- just future broadcasts — otherwise a scheduled convoy's ped stays
-- invisible to them until the next unrelated convoy change.
Bridge.OnPlayerLoaded(function(source)
    if shouldSeeStartPeds(source) then
        ConvoyManager.sendStartPedsTo(source)
    end
end)

return ConvoyManager
