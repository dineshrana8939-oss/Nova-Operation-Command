-- ─── Nova Convoy — Live Event Runtime (server) ────────────────────────────────
-- Server-authoritative state machine for active convoys and airdrops.

Runtime = {}

local active = {} -- [convoyId] = runtime state table (includes live entity handles)
local hotCargoSentries = {} -- [convoyId] = { convoyId, name, winningGang, winningGangLabel, winningMembers, dropCoords, dropStashId, propEntity, deliveredAt, expiresAt }
local handleHotCargoDelivered -- forward declaration for completeDelivery

local function registerHotCargoSentry(convoyId, sentryData)
    hotCargoSentries[convoyId] = sentryData
    CreateThread(function()
        local waitSec = math.max(0, (sentryData.expiresAt or (os.time() + 3600)) - os.time())
        Wait(waitSec * 1000)
        if hotCargoSentries[convoyId] == sentryData then
            if sentryData.propEntity and DoesEntityExist(sentryData.propEntity) then
                DeleteEntity(sentryData.propEntity)
            end
            if sentryData.dropStashId then
                Inventory.ClearStash(sentryData.dropStashId)
            end
            hotCargoSentries[convoyId] = nil
        end
    end)
end

local GENERIC_REACH_RADIUS = 35.0
Runtime.GENERIC_REACH_RADIUS = GENERIC_REACH_RADIUS   -- read by the route debug (convoy_debug.lua)
local CAPTURE_RADIUS = 8.0
local CAPTURE_SECONDS = 15

-- Friendly names for the floating 3D label above each truck (see monitor()'s
-- vehicleData/updateBlips broadcast) — mirrors TRUCK_ROLES in
-- web/src/lib/constants.js.
local TRUCK_ROLE_LABELS = {
    PRIMARY_CARGO = 'Primary Cargo',
    SECONDARY_CARGO = 'Secondary Cargo',
    ESCORT = 'Escort',
    DECOY = 'Decoy',
}

-- ── helpers ──────────────────────────────────────────────────────────────────────

local function vec(p) return vector3(p.x, p.y, p.z) end

-- GetGroundZFor_3dCoord is a CLIENT-only native — calling it as a bare global
-- on the server throws "attempt to call a nil value" and killed every airdrop
-- right at crate landing (crate never got its loot zone / guards). Guarded so
-- it is used only where it actually exists, and otherwise reports "not found"
-- so callers keep the coordinate they already have.
local function safeGroundZ(x, y, z)
    if type(GetGroundZFor_3dCoord) ~= 'function' then return false, z end
    local ok, found, gz = pcall(GetGroundZFor_3dCoord, x, y, z, false)
    if ok and found then return true, gz end
    return false, z
end

-- Picks whichever of `candidates` (a list of player sources, falling back to
-- every online player when empty/nil) is physically closest to `coords` —
-- the client most likely to already have that spot's collision streamed in.
-- Shared by anything that needs a real client to do something only client
-- natives can do (ground-snapping a server-created prop, flying the airdrop
-- plane) since the server has no collision/physics of its own to fall back on.
local function nearestPlayerSource(coords, candidates)
    local pool = (candidates and #candidates > 0) and candidates or Bridge.GetPlayers()
    if not pool or #pool == 0 then return nil end
    local best, bestDist
    for _, src in ipairs(pool) do
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local d = #(GetEntityCoords(ped) - coords)
            if not bestDist or d < bestDist then bestDist = d; best = src end
        end
    end
    return best or pool[math.random(1, #pool)]
end

-- ── Lockpick durability ────────────────────────────────────────────────────────
-- One lockpick survives Config.Lockpick.maxFailures FAILED minigame attempts
-- before it snaps and is removed from the inventory. The wear counter lives on
-- the server (never the client). An attempt is "opened" when the minigame
-- starts and "settled" when the client reports its result; an attempt that is
-- opened but never reported (client cancelled / cheated) counts as a failure
-- the next time that player tries anything, so skipping the report is no
-- longer a way to use a lockpick for free. Every attempt is written to the
-- event log (Discord timeline + PDF) and the convoy event history.
local lockpickWear = {}    -- [identifier:item] = failed attempts on the pick in use
local pendingLockpick = {} -- [src] = { item, convoyId, target, at }

-- Failed attempts one lockpick survives. Depends on the EVENT's difficulty
-- (Config.Lockpick.maxFailuresByDifficulty) — easy events are forgiving, hard
-- ones snap the pick quickly — with Config.Lockpick.maxFailures as the fallback.
local function lockpickMaxFailures(rt)
    local cfg = Config.Lockpick or {}
    local difficulty = rt and rt.def and rt.def.difficulty and tostring(rt.def.difficulty):upper()
    local byDifficulty = difficulty and cfg.maxFailuresByDifficulty and tonumber(cfg.maxFailuresByDifficulty[difficulty])
    return math.max(1, math.floor(byDifficulty or tonumber(cfg.maxFailures) or 4))
end

local function lockpickWearKey(src, item)
    return (Bridge.GetIdentifier(src) or tostring(src)) .. ':' .. tostring(item)
end

-- Records one minigame attempt (pass/fail + lockpick wear) in the event log,
-- the event history table and the after-action report.
local function logLockpickAttempt(rt, src, target, success, info)
    if not rt then return end
    local name = Bridge.GetPlayerName(src) or 'Unknown'
    local identifier = Bridge.GetIdentifier(src) or 'N/A'
    local gangName = rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier]
    if not gangName then
        local g = GangService and GangService.GetPlayerGang(src)
        if g and g.name then gangName = g.name end
    end
    local wearText = 'lockpick'
    if info then
        if info.broke then
            wearText = ('lockpick SNAPPED after %d failed attempts'):format(info.max)
        else
            wearText = ('lockpick wear %d/%d'):format(info.used or 0, info.max or lockpickMaxFailures(rt))
        end
    end
    rt.lootAttempts = rt.lootAttempts or {}
    rt.lootAttempts[#rt.lootAttempts + 1] = {
        playerName = name, playerIdentifier = identifier, gang = gangName,
        target = target, success = success == true, broke = info and info.broke or false,
        wear = info and info.used or 0, maxWear = info and info.max or lockpickMaxFailures(rt),
        timestamp = os.time(), timeStr = os.date('!%H:%M:%S', os.time()),
    }
    DiscordLog.appendEvent(rt.id, ('%s Minigame %s — %s (%s) on %s [%s]'):format(
        success and '✅' or '❌', success and 'PASSED' or 'FAILED', name, identifier, target, wearText))
    DB.insertConvoyEvent(rt.id, 'LOCKPICK_ATTEMPT', {
        gangName = gangName, playerIdentifier = identifier, playerName = name,
        detail = ('%s — %s (%s)'):format(target, success and 'passed' or 'failed', wearText),
    })
end

-- Settles the player's open attempt. Returns (info, pending) or nil when the
-- player had no open attempt (an unsolicited report is ignored by callers).
local function settleLockpickAttempt(src, success)
    local p = pendingLockpick[src]
    if not p then return nil end
    pendingLockpick[src] = nil
    local key = lockpickWearKey(src, p.item)
    local max = lockpickMaxFailures(active[p.convoyId])
    local info = { max = max, broke = false, used = lockpickWear[key] or 0, item = p.item }
    if not success then
        local wear = (lockpickWear[key] or 0) + 1
        if wear >= max then
            Inventory.RemoveItem(src, p.item, 1)
            lockpickWear[key] = nil
            info.broke, info.used = true, max
        else
            lockpickWear[key] = wear
            info.used = wear
        end
    end
    return info, p
end

-- Opens an attempt: the player must be carrying a lockpick (it is NOT consumed
-- here). Returns false (after telling the player) when they have none.
local function beginLockpickAttempt(src, item, convoyId, target)
    local prev = pendingLockpick[src]
    if prev then
        -- A rapid double-click/re-select on the target prompt (or the client
        -- re-sending onSelect before ox_target's own menu has closed) used to
        -- auto-fail the first attempt and immediately open a SECOND one —
        -- sending the client two overlapping 'beginXLootMinigame' events a
        -- few ms apart. The NUI overlay only guards against a game already
        -- open by resolving the OLD one false and starting fresh, which is a
        -- real window for the second SendNUIMessage to land before the first
        -- has actually rendered anything — leaving SetNuiFocus stuck true
        -- with nothing ever drawn: "screen froze, no minigame appeared."
        -- Within a few seconds of the first attempt, just ignore the repeat
        -- entirely instead of restarting it.
        if (os.time() - (prev.at or 0)) < 3 then
            return false
        end
        local info = settleLockpickAttempt(src, false)
        local prt = active and active[prev.convoyId]
        if info and prt then logLockpickAttempt(prt, src, prev.target, false, info) end
    end
    if Inventory.GetItemCount(src, item) < 1 then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'You need a lockpick to get into this.', 'error')
        return false
    end
    pendingLockpick[src] = { item = item, convoyId = convoyId, target = target, at = os.time() }
    return true
end

local function tellLockpickResult(src, success, info)
    if not info then return end
    if success then
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Lock gave way. Lockpick wear %d/%d.'):format(info.used, info.max), 'success')
    elseif info.broke then
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Your lockpick snapped after %d failed attempts — use another one to keep going.'):format(info.max), 'error')
    else
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('The pick slipped. Lockpick wear %d/%d — try again.'):format(info.used, info.max), 'error')
    end
end

AddEventHandler('playerDropped', function() pendingLockpick[source] = nil end)

local function sortedRoute(def)
    local route = {}
    for i, p in ipairs(def.route) do route[i] = p end
    table.sort(route, function(a, b) return (a.order or 0) < (b.order or 0) end)
    return route
end

-- AIRDROP points are NOT part of the convoy's route. They're side events
-- for gangs, triggered by the convoy passing near them (see
-- checkAirdropTriggers) — the trucks never target, stop at, slow for, or
-- wait on them. Keeping them in rt.route used to mean the route index had
-- to land on each one and "reach" it (within ~105m) before the convoy
-- could progress; an airdrop placed further off the road than that held
-- the route index there forever, so the next checkpoint / destination was
-- never checked at all and the convoy could never be delivered or end.
local function splitRoute(route)
    local driving, drops = {}, {}
    for _, p in ipairs(route) do
        if p.type == 'AIRDROP' then drops[#drops + 1] = p else driving[#driving + 1] = p end
    end
    return driving, drops
end

local function findPoint(route, ptype)
    for _, p in ipairs(route) do if p.type == ptype then return p end end
    return nil
end

local function checkpointConfigFor(def, routePointId)
    -- tostring() comparison, not == : route point ids are client-generated
    -- strings (RouteBuilder's own point.id), but depending on exactly how a
    -- checkpoint's own routePointId got set/round-tripped through the
    -- tablet's JSON save, a stray number-vs-string mismatch here silently
    -- fell through to the hardcoded fallback below every single time — whose
    -- npcPolice/army are BOTH enabled=false. That's a checkpoint quietly
    -- running on total defaults (no NPCs, generic name/radius) regardless of
    -- whatever the admin actually configured, with nothing in the UI to
    -- suggest the lookup itself was the thing that failed.
    for _, cp in ipairs((def and def.checkpoints) or {}) do
        if tostring(cp.routePointId) == tostring(routePointId) or tostring(cp.id) == tostring(routePointId) then return cp end
    end
    -- No settings carry this point's id (route points re-saved with new ids leave the checkpoint settings orphaned, so
    -- the props / police car / guards the admin configured silently vanished). When the event has exactly as many
    -- checkpoint settings as CHECKPOINT route points, pair them in route order instead of dropping to the defaults.
    if def and type(def.route) == 'table' and type(def.checkpoints) == 'table' and #def.checkpoints > 0 then
        local cpPoints, at = {}, nil
        for _, p in ipairs(def.route) do
            if p.type == 'CHECKPOINT' then
                cpPoints[#cpPoints + 1] = p
                if tostring(p.id) == tostring(routePointId) then at = #cpPoints end
            end
        end
        if at and #cpPoints == #def.checkpoints and def.checkpoints[at] then
            return def.checkpoints[at]
        end
    end
    return {
        name = 'Checkpoint', radius = Config.DefaultCheckpointRadius, holdDuration = Config.DefaultCheckpointWaitTime,
        npcPolice = { enabled = false, count = 4 }, army = { enabled = false, count = 4 },
        gangAttackEnabled = true, announce = true, barricades = true,
    }
end

-- Every checkpoint + the destination, for the police-only "full tactical
-- overview" map markers (Config.PoliceAlwaysSeeRouteZones) — sent once, up
-- front, unlike gang's own progressive per-point reveal (checkpointStart/
-- dropzone) as the convoy actually reaches each one.
-- Race-style: only the points the convoy has NOT passed yet are listed (the client redraws the whole set whenever the
-- route advances), numbered checkpoints keep their original number, and the first guidable point at or after the
-- convoy's current route index is flagged `current` — that is the one the client puts the GPS line on. Hidden
-- gameplay points (AMBUSH, NPC_SPAWN) are never listed.
local GUIDE_TYPES = { ROUTE = true, CHECKPOINT = true, BREAK = true, DESTINATION = true, START = true }
local function buildRouteZones(rt)
    local cfg = Config.PoliceRouteBlips or {}
    local lookahead = tonumber(cfg.waypointLookahead) or 10
    local cur = tonumber(rt.currentRouteIndex) or 1
    local zones, cpNo, dots, currentSet = {}, 0, 0, false
    local cpTotal = 0
    for _, point in ipairs(rt.route or {}) do if point.type == 'CHECKPOINT' then cpTotal = cpTotal + 1 end end
    for i, point in ipairs(rt.route or {}) do
        local t = point.type
        if t == 'CHECKPOINT' then cpNo = cpNo + 1 end
        if i >= cur and GUIDE_TYPES[t] then
            local z = { type = t, idx = i, x = point.x, y = point.y, z = point.z }
            local keep = true
            if t == 'CHECKPOINT' then
                local cp = checkpointConfigFor(rt.def, point.id)
                z.name, z.no, z.total = cp.name, cpNo, cpTotal
                z.radius = tonumber(cp.radius) or Config.DefaultCheckpointRadius
            elseif t == 'BREAK' then
                z.name = point.name
            elseif t == 'ROUTE' then
                keep = cfg.waypoints ~= false and dots < lookahead
                if keep then dots = dots + 1 end
            end
            -- the GPS target is the next point of any guidable type, even a plain waypoint, so the line follows the
            -- convoy's own path rather than the fastest road to the next checkpoint
            if not currentSet then z.current = true; currentSet = true; keep = true end
            if keep then zones[#zones + 1] = z end
        end
    end
    return zones
end

-- Every checkpoint of the route, for the sky beacon (client/modules/checkpoint_beacon.lua).
local function buildCheckpointBeacons(rt)
    local list = {}
    for _, point in ipairs(rt.route or {}) do
        if point.type == 'CHECKPOINT' then
            local cp = checkpointConfigFor(rt.def, point.id)
            list[#list + 1] = { id = tostring(point.id), x = point.x, y = point.y, z = point.z, radius = tonumber(cp.radius) or Config.DefaultCheckpointRadius }
        end
    end
    return list
end

-- police / admins always see every beacon once the convoy has departed; gangs only when the config says so
local function sendCheckpointBeacons(rt, source)
    local bc = Config.CheckpointBeacon or {}
    if bc.enabled == false or rt.releaseHeld then return end
    TriggerClientEvent('nova_convoytruck:runtime:checkpointBeacons', source, buildCheckpointBeacons(rt))
end

-- All three below share checkpointConfigFor's exact same tostring()
-- reasoning (see its own comment) — a bare == here silently falls back to
-- generic defaults on any string/number id mismatch, with nothing visible
-- to suggest the lookup itself was the actual failure.
local function airdropConfigFor(def, routePointId)
    for _, a in ipairs(def.airdrops or {}) do
        if tostring(a.routePointId) == tostring(routePointId) then
            if (not a.rewards or #a.rewards == 0) and Config.Airdrop and Config.Airdrop.defaultRewards then
                a.rewards = Config.Airdrop.defaultRewards
            end
            return a
        end
    end
    return {
        enabled = true,
        name = 'Airdrop',
        activationDelay = 0,
        guardCount = (Config.Airdrop and Config.Airdrop.guardCount) or 3,
        duration = (Config.Airdrop and Config.Airdrop.duration) or 300,
        rewards = (Config.Airdrop and Config.Airdrop.defaultRewards) or nil,
    }
end

local function breakConfigFor(def, routePointId)
    for _, b in ipairs(def.breaks or {}) do
        if tostring(b.routePointId) == tostring(routePointId) then return b end
    end
    return { name = 'Break', duration = 15, freezeTruck = true, announce = true }
end

local function ambushConfigFor(def, routePointId)
    for _, a in ipairs(def.ambushes or {}) do
        if tostring(a.routePointId) == tostring(routePointId) then return a end
    end
    return { name = 'Ambush', npcCount = 4, duration = 90, announce = true }
end

-- Who currently sees this convoy's tactical info: online police + joined gang members.
local function policeSources()
    local sources = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Bridge.IsPolice(src) then sources[#sources + 1] = src end
    end
    return sources
end

-- optedOutGang/optedOutPolice (set by Runtime.leaveGang/leavePolice below,
-- cleared again on rejoin): once someone has explicitly left THIS convoy,
-- they stay excluded from its tactical audiences for the rest of the run —
-- even if they'd otherwise still qualify (still an active member of a
-- participating gang, still on duty as police) — so "leave convoy" actually
-- means no more banners/blips/timers/health bars for them, not just a
-- roster-count change.
-- HOT_CARGO/GANG_AIRDROP's settings.allowedGangs (see sanitizeDefinition in
-- convoy_manager.lua) — 'ALL' (default) means every gang gets the event's
-- banners/blips/notifications same as before this existed; 'SELECTED'
-- narrows that audience to only the specific admin-picked gang names in
-- .gangs. Deliberately audience-only, not an access gate — a non-selected
-- gang that stumbles onto the truck/crate without ever having been told
-- about it can still interact with it; this only controls who gets told.
local function isGangAllowed(rt, gangName)
    local ag = rt and rt.def and rt.def.settings and rt.def.settings.allowedGangs
    if not ag or ag.mode ~= 'SELECTED' then return true end
    if not gangName then return false end
    for _, name in ipairs(ag.gangs or {}) do
        if name == gangName then return true end
    end
    return false
end

local function gangParticipantSources(rt)
    local sources = {}
    local seen = {}
    local optedOut = rt and rt.participants and rt.participants.optedOutGang
    for _, src in ipairs(Bridge.GetPlayers()) do
        local identifier = Bridge.GetIdentifier(src)
        if identifier and not (optedOut and optedOut[identifier]) then
            if rt and rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier] then
                seen[src] = true
                sources[#sources + 1] = src
            elseif not Bridge.IsPolice(src) then
                local g = GangService and GangService.GetPlayerGang(src)
                if g and g.name and isGangAllowed(rt, g.name) then
                    seen[src] = true
                    sources[#sources + 1] = src
                elseif UserPermissions.canAny(src, 'convoys.view', 'dashboard.view', 'participants.view') then
                    seen[src] = true
                    sources[#sources + 1] = src
                end
            end
        end
    end
    return sources
end

-- Same membership as gangParticipantSources, minus its admin/creator-access
-- fallback branch — used ONLY by announceGang. An admin with no gang of
-- their own still needs to count as "a participant" for blips/drive-by/etc
-- (that's what gangParticipantSources itself is for, unchanged), but a
-- banner specifically meant for a gang's own audience ("your crew captured
-- the truck," a capture/loot notice) has no reason to also land on every
-- admin watching — that's what announcePolice/the sprite broadcasts above
-- are already for.
local function gangOnlyParticipantSources(rt)
    local sources = {}
    local seen = {}
    local optedOut = rt and rt.participants and rt.participants.optedOutGang
    for _, src in ipairs(Bridge.GetPlayers()) do
        local identifier = Bridge.GetIdentifier(src)
        if identifier and not (optedOut and optedOut[identifier]) then
            if rt and rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier] then
                seen[src] = true
                sources[#sources + 1] = src
            elseif not Bridge.IsPolice(src) then
                local g = GangService and GangService.GetPlayerGang(src)
                if g and g.name and isGangAllowed(rt, g.name) then
                    seen[src] = true
                    sources[#sources + 1] = src
                end
            end
        end
    end
    return sources
end

local function policeParticipantSources(rt)
    if not rt then return {} end
    local sources = {}
    local seen = {}
    local optedOut = rt.participants and rt.participants.optedOutPolice
    for _, src in ipairs(Bridge.GetPlayers()) do
        local identifier = Bridge.GetIdentifier(src)
        if not (identifier and optedOut and optedOut[identifier]) then
            local isPolice = Bridge.IsPolice(src)
            local isRegistered = identifier and rt.participants and rt.participants.policeIdentifiers and rt.participants.policeIdentifiers[identifier]
            local isStarter = rt.startedBySource and rt.startedBySource == src and not (GangService and GangService.GetPlayerGang(src))
            if isPolice or isRegistered or isStarter then
                if not seen[src] then
                    seen[src] = true
                    sources[#sources + 1] = src
                end
            end
        end
    end
    return sources
end

-- Police + anyone with admin/creator access — the "always visible, no
-- waiting" audience shared by the live truck blips and the checkpoint/
-- destination zone overview. Admins get the same standing oversight
-- visibility as police; gang participants have their own separate,
-- earn-it-by-progress reveal (gangVisibilityUnlocked / per-checkpoint
-- reveal) and are deliberately NOT part of this.
local function policeAndAdminSources(rt)
    local sources = policeParticipantSources(rt)
    local seen = {}
    for _, s in ipairs(sources) do seen[s] = true end
    for _, s in ipairs(Bridge.GetPlayers()) do
        -- Same guard policeParticipantSources already applies to a
        -- gang-member starter (see isStarter above): an admin who currently
        -- has a gang is excluded from this exclusive police/tactical
        -- channel — route zones, staging location, ambush/NPC blips, the
        -- prep countdown, etc. all reveal things the convoy's gang side is
        -- never told in advance, so a dual admin+gang connection getting
        -- them here would be a real, exploitable heads-up if they then play
        -- their gang character. Not police, not registered either — a plain
        -- admin with no gang still gets full oversight visibility as before.
        if not seen[s] and UserPermissions.canAny(s, 'convoys.view', 'dashboard.view', 'participants.view') and not (GangService and GangService.GetPlayerGang(s)) then
            sources[#sources + 1] = s
            seen[s] = true
        end
    end
    return sources
end

local function findSourceByIdentifier(identifier)
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Bridge.GetIdentifier(src) == identifier then return src end
    end
    return nil
end

-- One pass over Bridge.GetPlayers() instead of a fresh scan per lookup —
-- findSourceByIdentifier is fine for the odd one-off call (join/leave), but
-- the broadcast functions below used to call it 2x per participant every
-- tick, each a full O(players) scan. Building this once per broadcast call
-- turns that into O(players + participants).
local function buildIdentifierIndex()
    local map = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        local identifier = Bridge.GetIdentifier(src)
        if identifier then map[identifier] = src end
    end
    return map
end

-- Pushes the up-to-date route overview (buildRouteZones) to every police / admin source; called each time the convoy's
-- route index advances so passed points drop off the map and the GPS line moves to the next point.
local function sendPoliceRouteZones(rt)
    if Config.PoliceAlwaysSeeRouteZones == false or rt.releaseHeld then return end
    local zones = buildRouteZones(rt)
    for _, s in ipairs(policeAndAdminSources(rt)) do
        TriggerClientEvent('nova_convoytruck:runtime:policeRouteZones', s, zones)
    end
end

-- Small top-left progress card (client ConvoyProgress.svelte): cargo trucks delivered and checkpoints cleared.
-- Sent to everyone following the run — police, admins and joined gangs — on every change, and refreshed from monitor().
local function sendConvoyProgress(rt)
    if rt.def.kind ~= 'CONVOY' or rt.releaseHeld then return end
    local totalTrucks, delivered, explicit = 0, 0, false
    for _, t in pairs(rt.trucks or {}) do
        if t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO' then explicit = true end
    end
    for _, t in pairs(rt.trucks or {}) do
        local counts = explicit and (t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO') or (not explicit and t.role ~= 'ESCORT' and t.role ~= 'DECOY')
        if counts then
            totalTrucks = totalTrucks + 1
            if t.delivered then delivered = delivered + 1 end
        end
    end
    local cpTotal, cpDone = 0, 0
    for _, point in ipairs(rt.route or {}) do
        if point.type == 'CHECKPOINT' then
            cpTotal = cpTotal + 1
            if rt.checkpointDone and rt.checkpointDone[point.id] then cpDone = cpDone + 1 end
        end
    end
    -- one box per stage: every checkpoint in route order, then the destination. done / current / todo.
    local stages, currentSet = {}, false
    for _, point in ipairs(rt.route or {}) do
        if point.type == 'CHECKPOINT' then
            local state = 'todo'
            if rt.checkpointDone and rt.checkpointDone[point.id] then state = 'done'
            elseif not currentSet then state = 'current'; currentSet = true end
            stages[#stages + 1] = { k = 'cp', s = state }
        end
    end
    if findPoint(rt.route or {}, 'DESTINATION') then
        local state = 'todo'
        if totalTrucks > 0 and delivered >= totalTrucks then state = 'done'
        elseif not currentSet then state = 'current'; currentSet = true end
        stages[#stages + 1] = { k = 'dest', s = state }
    end
    -- route points crossed: every route point the convoy has passed (checkpoints, rest stops, plain route points and the
    -- destination; START and the hidden ambush / NPC-spawn points do not count) out of all of them
    local routeDone, routeTotal = 0, 0
    local curIdx = tonumber(rt.currentRouteIndex) or 1
    for i, point in ipairs(rt.route or {}) do
        local t = point.type
        if t == 'ROUTE' or t == 'CHECKPOINT' or t == 'BREAK' or t == 'DESTINATION' then
            routeTotal = routeTotal + 1
            if i < curIdx then routeDone = routeDone + 1 end
        end
    end
    local payload = {
        delivered = delivered, totalTrucks = totalTrucks, checkpointsDone = cpDone, checkpointsTotal = cpTotal,
        routeDone = routeDone, routeTotal = routeTotal,
        stages = stages, waitingPolice = rt.checkpointWaitingPolice == true,
    }
    local seen = {}
    local function sendTo(list)
        for _, s in ipairs(list or {}) do
            if not seen[s] then
                seen[s] = true
                TriggerClientEvent('nova_convoytruck:runtime:convoyProgress', s, payload)
            end
        end
    end
    sendTo(policeAndAdminSources(rt))
    sendTo(policeParticipantSources(rt))
    sendTo(gangParticipantSources(rt))
end

-- Gang label/logo rarely change mid-convoy — cached per rt per gang name so
-- this doesn't cost a DB lookup on every tick's broadcast (this fires every
-- 3 ticks for the whole runtime's duration).
local function gangIdentity(rt, gangName)
    rt.gangIdentityCache = rt.gangIdentityCache or {}
    local cached = rt.gangIdentityCache[gangName]
    if cached then return cached end
    local g = GangService.GetGangByName(gangName)
    -- accentColor was dropped here even though GetGangByName already
    -- returns it — meant the capture/victory banner's gang badge (see
    -- Announcement.svelte) never showed an admin-set accent color, only
    -- ever the auto-generated fallback.
    cached = { name = gangName, label = (g and g.label) or gangName, logo = g and g.logo, accentColor = g and g.accentColor }
    rt.gangIdentityCache[gangName] = cached
    return cached
end

-- alive, healthPct (0-100), armour (0-100) for one online player.
-- Primary source is the player's own client report (Player(src).state.
-- convoyVitals, written by runtime_client.lua's vitals thread) — exact and
-- current, unlike a server-side ped read under OneSync. On top of that, a
-- framework downed/last-stand flag always counts as dead: qbx_medical sets
-- Player(src).state.isDead for both DEAD and LAST_STAND while keeping the
-- ped itself above 100 HP, which is why downed players used to stay on the
-- squad list at a healthy-looking percentage. Falls back to the old server
-- ped read only if the client hasn't reported yet.
-- GTA peds are "dead" at 100 health, not 0, hence the offset math.
local function readVitals(src)
    local st = Player(src).state
    local downed = st.isDead == true or st.dead == true or st.isDowned == true or st.inLastStand == true
    local v = st.convoyVitals
    if type(v) == 'table' then
        local alive = not v.dead and not downed
        return alive, alive and math.max(0, math.min(100, tonumber(v.health) or 0)) or 0, alive and math.max(0, math.min(100, tonumber(v.armour) or 0)) or 0
    end
    local ped = GetPlayerPed(src --[[@as string]])
    if not ped or ped == 0 then return not downed, downed and 0 or 100, 0 end
    local health = GetEntityHealth(ped)
    local alive = health > 100 and not downed
    -- health - 100, clamped 0-100 — matches qbx_hud's own convention (see
    -- the client vitals thread in runtime_client.lua for why), not a
    -- max-health-aware percentage. Only reached before a client's first
    -- convoyVitals report arrives, so this is a brief fallback, not the
    -- normal path.
    return alive,
        alive and math.max(0, math.min(100, health - 100)) or 0,
        alive and math.max(0, math.min(100, GetPedArmour(ped) or 0)) or 0
end

-- Sends each gang its OWN roster only — one gang never sees another's HP status.
-- Dead/downed members are left out of the roster entirely, so they drop off
-- the squad HUD the moment they go down (and reappear if revived).
local function broadcastGangStatus(rt)
    local byGang = {}        -- gangName -> roster (alive/offline members only)
    local recipients = {}    -- gangName -> online sources (incl. dead ones, so their HUD still updates)
    local srcByIdentifier = buildIdentifierIndex()
    local processedIdents = {}

    local function add(gangName, identifier, src)
        byGang[gangName] = byGang[gangName] or {}
        recipients[gangName] = recipients[gangName] or {}
        if not src then
            table.insert(byGang[gangName], { identifier = identifier, name = identifier, health = 0, armour = 0, alive = false, online = false })
            return
        end
        table.insert(recipients[gangName], src)
        local alive, health, armour = readVitals(src)
        if alive then
            table.insert(byGang[gangName], {
                identifier = identifier,
                name = Bridge.GetPlayerName(src) or identifier,
                health = health, armour = armour, alive = true, online = true,
            })
        end
    end

    -- 1. Pre-registered / tracked gang participants
    if rt.participants and rt.participants.identifiers then
        for identifier, gangName in pairs(rt.participants.identifiers) do
            processedIdents[identifier] = true
            add(gangName, identifier, srcByIdentifier[identifier])
        end
    end

    -- 2. Online gang members who are in active gangs (if gangPvp enabled)
    local optedOutGang = rt.participants and rt.participants.optedOutGang
    if rt.def and rt.def.settings and rt.def.settings.gangPvp ~= false then
        for _, src in ipairs(Bridge.GetPlayers()) do
            if not Bridge.IsPolice(src) then
                local identifier = Bridge.GetIdentifier(src)
                if identifier and not processedIdents[identifier] and not (optedOutGang and optedOutGang[identifier]) then
                    local g = GangService.GetPlayerGang(src)
                    if g and g.name then
                        processedIdents[identifier] = true
                        add(g.name, identifier, src)
                    end
                end
            end
        end
    end

    for gangName, roster in pairs(byGang) do
        local identity = gangIdentity(rt, gangName)
        for _, src in ipairs(recipients[gangName] or {}) do
            TriggerClientEvent('nova_convoytruck:runtime:gangStatus', src, roster, identity)
        end
    end
end

-- Single shared roster (not per-gang-style privacy — every escorting officer
-- sees every other officer, same as radio chatter would work in reality).
-- policeSrcs is precomputed once per tick by the caller (monitor()) rather
-- than each broadcast re-scanning Bridge.GetPlayers() itself. Dead/downed
-- officers are left out (see readVitals) but still receive the update.
local function broadcastPoliceStatus(rt, policeSrcs)
    local roster = {}
    for _, src in ipairs(policeSrcs) do
        local alive, health, armour = readVitals(src)
        if alive then
            roster[#roster + 1] = {
                identifier = Bridge.GetIdentifier(src) or tostring(src),
                name = Bridge.GetPlayerName(src) or 'Officer',
                health = health, armour = armour, alive = true,
            }
        end
    end
    for _, src in ipairs(policeSrcs) do
        TriggerClientEvent('nova_convoytruck:runtime:policeStatus', src, roster)
    end
end

local function notify(sources, event, ...)
    for _, src in ipairs(sources) do TriggerClientEvent(event, src, ...) end
end

-- Resolution order: this convoy's own override (General tab -> settings.
-- startAnnounceDelaySeconds) > the server-wide config default. Same
-- resolution pattern as requiredLockpicksFor further down this file.
local function startAnnounceDelayFor(def)
    local override = def.settings and def.settings.startAnnounceDelaySeconds
    if override ~= nil then return math.max(0, tonumber(override) or 0) end
    return math.max(0, Config.ConvoyStartAnnounceDelaySeconds or 0)
end

local function formatBannerText(template, ...)
    if not template or template == '' then return '' end
    local branding = Config.Branding or {}
    local str = template
    if branding.serverName then
        str = str:gsub('{serverName}', branding.serverName)
    end
    if branding.operationName then
        str = str:gsub('{operationName}', branding.operationName)
    end

    local args = { ... }
    if #args == 0 then return str end

    -- Support named dictionary tokens e.g. { cargo = "Gold" } -> {cargo}
    if type(args[1]) == 'table' then
        for k, v in pairs(args[1]) do
            str = str:gsub('{' .. tostring(k) .. '}', tostring(v))
        end
        return str
    end

    -- Support standard Lua format string %s with error safety
    local ok, formatted = pcall(string.format, str, ...)
    if ok then return formatted end
    -- The text and its arguments do not line up (a % that is not a placeholder, a number where a word was given ...): never show the raw
    -- template with its %s / %d in it. Fill the placeholders one by one with the values that were given, and drop the ones left over.
    local i = 0
    str = str:gsub('%%[sdif]', function()
        i = i + 1
        local v = args[i]
        return v ~= nil and tostring(v) or ''
    end)
    return (str:gsub('%%%%', '%%'))
end

local function resolveBanner(key, defaultTitle, defaultBody, defaultDuration, defaultKind, ...)
    local cfg = Config.AnnouncementBanners and Config.AnnouncementBanners[key]
    if cfg and cfg.enabled == false then
        return nil
    end

    local rawTitle = (cfg and cfg.title) or defaultTitle or ''
    local rawBody = (cfg and cfg.body) or defaultBody or ''
    local duration = (cfg and (cfg.duration or cfg.durationMs)) or defaultDuration or 7000
    local kind = (cfg and cfg.kind) or defaultKind or 'info'

    local title = formatBannerText(rawTitle, ...)
    local body = formatBannerText(rawBody, ...)

    return {
        title = title,
        body = body,
        duration = duration,
        kind = kind,
    }
end

-- Same as resolveBanner, but the title and the body take their OWN arguments (titleArgs / bodyArgs are lists). One shared list made the
-- body read the title's values: a title with a single %s took the first argument, and a body written for the next two numbers then got
-- a name where it needed a number.
local function resolveBannerSplit(key, defaultTitle, defaultBody, defaultDuration, defaultKind, titleArgs, bodyArgs)
    local cfg = Config.AnnouncementBanners and Config.AnnouncementBanners[key]
    if cfg and cfg.enabled == false then return nil end
    local unpack_ = table.unpack or unpack
    return {
        title = formatBannerText((cfg and cfg.title) or defaultTitle or '', unpack_(titleArgs or {})),
        body = formatBannerText((cfg and cfg.body) or defaultBody or '', unpack_(bodyArgs or {})),
        duration = (cfg and (cfg.duration or cfg.durationMs)) or defaultDuration or 7000,
        kind = (cfg and cfg.kind) or defaultKind or 'info',
    }
end

Runtime.resolveBanner = resolveBanner

-- Appends the General tab's admin-typed announceStartTime/announceEndTime/
-- announceMessage (settings) onto a banner body that's otherwise already
-- decided — same text CONVOY's own departure banner, the manual "Announce"
-- button (callbacks.lua's announceUpcomingConvoy), and now the scheduled
-- pre-announce + Hot Cargo/Gang Airdrop start banners below all show, so
-- filling any of those three fields in on ANY event kind actually reaches a
-- banner somewhere instead of just being saved and never shown.
local function appendAnnounceExtras(settings, body)
    settings = settings or {}
    local extraLines = {}
    if settings.announceStartTime and settings.announceStartTime ~= '' then
        extraLines[#extraLines + 1] = ('Starts %s.'):format(settings.announceStartTime)
    end
    if settings.announceEndTime and settings.announceEndTime ~= '' then
        extraLines[#extraLines + 1] = ('Ends %s.'):format(settings.announceEndTime)
    end
    if settings.announceMessage and settings.announceMessage ~= '' then
        extraLines[#extraLines + 1] = settings.announceMessage
    end
    if #extraLines == 0 then return body end
    return (body or '') .. '\n' .. table.concat(extraLines, ' ')
end

-- Called by scheduler.lua's poll loop, once, some configurable lead time
-- before a SCHEDULED event's scheduledAt actually arrives (Config.
-- PreScheduleAnnounceSeconds) — a "heads up, this is starting soon" banner
-- built from the same three General-tab fields as the actual start banner,
-- for whichever kind this is. There's no `rt` yet at this point (the event
-- genuinely hasn't started), so this goes to every connected player rather
-- than trying to guess who'd eventually join — same broad audience the
-- manual "Announce" button already uses for the same reason.
function Runtime.announceScheduled(def)
    if not def or (def.settings and def.settings.announcements == false) then return end
    local kindLabel = ({ GANG_AIRDROP = 'Gang Airdrop', HOT_CARGO = 'Hot Cargo', GANG_RACE = 'Gang Rally', TDM = 'TDM Match', CONTAINER_WARS = 'Container Wars', CRACKDOWN = 'Operation Crackdown' })[def.kind] or 'Convoy'
    local bannerKey = def.kind == 'GANG_AIRDROP' and 'airdropScheduledSoon' or (def.kind == 'HOT_CARGO' and 'hotCargoScheduledSoon' or (def.kind == 'GANG_RACE' and 'rallyScheduledSoon' or 'convoyScheduledSoon'))
    local b = resolveBanner(bannerKey, ('UPCOMING %s: %s'):format(kindLabel:upper(), def.name), 'This event is scheduled to start soon — get ready.', 9000, 'info', def.name)
    if not b then return end
    -- a race goes to the race audience (gangs, or everyone when it is open to everyone — never on-duty police);
    -- every other kind keeps its own broad audience
    local audience = def.kind == 'GANG_RACE' and Runtime.raceAudience(def) or Bridge.GetPlayers()
    notify(audience, 'nova_convoytruck:runtime:announce', b.title, appendAnnounceExtras(def.settings, b.body), b.duration, b.kind)
end

-- kind: 'start' | 'success' | 'checkpoint' | 'warn' | 'danger' | 'info' (default) — drives
-- the NUI banner's icon/accent colour, see web/src/lib/hud/Announcement.svelte.
-- gang (optional): { name, label, logo } — when set, the banner shows that
-- gang's own logo instead of the generic kind icon (e.g. a capture banner).
local function announcePolice(rt, title, body, duration, kind, gang)
    if rt and rt.def and rt.def.settings and rt.def.settings.announcements == false then return end
    if not title or title == '' then return end
    -- policeAndAdminSources, not the bare police-participant list — an admin
    -- watching a run has no more reason to miss a tactical banner than a
    -- joined officer does. announceAll/announceGang already reach admins
    -- for free (their gang-side audience has its own admin fallback); this
    -- was the one banner path that didn't.
    notify(policeAndAdminSources(rt), 'nova_convoytruck:runtime:announce', title, body, duration, kind or 'info', gang)
end

local function announceGang(rt, title, body, duration, kind, gang)
    if rt and rt.def and rt.def.settings and rt.def.settings.announcements == false then return end
    if not title or title == '' then return end
    -- gangOnlyParticipantSources, not gangParticipantSources — a banner
    -- meant for a gang's own audience shouldn't also land on every admin
    -- watching just because that's a harmless fallback in the general
    -- participant-list helper (which admin still needs for blips/sync).
    notify(gangOnlyParticipantSources(rt), 'nova_convoytruck:runtime:announce', title, body, duration, kind or 'info', gang)
end

local function announceAll(rt, title, body, duration, kind, gang)
    if rt and rt.def and rt.def.settings and rt.def.settings.announcements == false then return end
    if not title or title == '' then return end
    local sources = policeParticipantSources(rt)
    for _, s in ipairs(gangParticipantSources(rt)) do sources[#sources + 1] = s end
    notify(sources, 'nova_convoytruck:runtime:announce', title, body, duration, kind or 'info', gang)
end

-- Server-wide: EVERY connected player, not just police/joined participants —
-- reserved for exactly two moments (convoy started, convoy ended) so the
-- whole server knows an event is live/over even if they never joined it.
-- Every other banner (checkpoints, a truck lost, an airdrop, etc.) stays on
-- announceAll/announcePolice — those are tactical info for people already
-- in the fight, not something the whole server needs pushed to them.
local function announceServerWide(rt, title, body, duration, kind, gang)
    if rt and rt.def and rt.def.settings and rt.def.settings.announcements == false then return end
    if not title or title == '' then return end
    notify(Bridge.GetPlayers(), 'nova_convoytruck:runtime:announce', title, body, duration, kind or 'info', gang)
end

local function allParticipantSources(rt)
    local police = policeParticipantSources(rt)
    local gangs = gangParticipantSources(rt)
    local list = {}
    local seen = {}
    for _, s in ipairs(police) do
        if not seen[s] then seen[s] = true list[#list + 1] = s end
    end
    for _, s in ipairs(gangs) do
        if not seen[s] then seen[s] = true list[#list + 1] = s end
    end
    if rt.startedBySource and not seen[rt.startedBySource] then
        seen[rt.startedBySource] = true
        list[#list + 1] = rt.startedBySource
    end
    return list
end

-- Joined police escorts + joined gang participants + anyone with tablet
-- creator access (which may include admins who aren't police at all) — used
-- specifically for "a gang crime just happened" banners like a lost truck or
-- airdrop crate actually getting cracked open, which admins want visibility
-- into for moderation even if they're not on duty as police right now.
-- A GANG_AIRDROP-kind event is completely off-limits to police — no
-- exceptions for the usual "admin/creator-access moderation visibility"
-- either, since police get creator access via job grade too and this event
-- kind needs to be watertight against that, not just against non-admin
-- Audience for airdrop events and airdrop capture announcements:
-- includes all pre-registered / joined gang members, all online gang members in active gangs,
-- and all administrators (for moderation and tracking). Police are only included if NOT a GANG_AIRDROP.
local function airdropCaptureAudience(rt)
    local seen = {}
    local sources = {}
    local function add(src)
        if src and not seen[src] then
            seen[src] = true
            sources[#sources + 1] = src
        end
    end

    -- 1. All pre-registered/joined gang participants
    for _, s in ipairs(gangParticipantSources(rt)) do add(s) end

    -- 2. All active online gang members (if gangPvp or GANG_AIRDROP)
    local optedOutGang = rt.participants and rt.participants.optedOutGang
    for _, s in ipairs(Bridge.GetPlayers()) do
        if not Bridge.IsPolice(s) then
            local identifier = Bridge.GetIdentifier(s)
            if not (identifier and optedOutGang and optedOutGang[identifier]) then
                local g = GangService.GetPlayerGang(s)
                if g and g.name then add(s) end
            end
        end
    end

    -- 3. All admins (always see airdrop capture events for moderation/tracking)
    -- — EXCEPT for a GANG_AIRDROP event, which must stay watertight against
    -- police even via this exception: Bridge.HasCreatorAccess grants access
    -- through the same Config.CreatorAccess.jobs police-grade map
    -- Bridge.IsPolice reads, so an on-duty officer with enough grade to count
    -- as "creator access" was still slipping in here and seeing every
    -- GANG_AIRDROP banner — exactly what step 4 below exists to prevent.
    for _, s in ipairs(Bridge.GetPlayers()) do
        if UserPermissions.canAny(s, 'convoys.view', 'dashboard.view', 'participants.view')
            and not (rt.def.kind == 'GANG_AIRDROP' and Bridge.IsPolice(s)) then
            add(s)
        end
    end

    -- 4. Police participants only if this is NOT a gang-only airdrop
    if rt.def.kind ~= 'GANG_AIRDROP' then
        for _, s in ipairs(policeParticipantSources(rt)) do add(s) end
    end

    return sources
end

local function tacticalPlusAdminSources(rt)
    if rt.def.kind == 'GANG_AIRDROP' then return airdropCaptureAudience(rt) end
    local seen = {}
    local sources = {}
    local function add(src)
        if not seen[src] then
            seen[src] = true
            sources[#sources + 1] = src
        end
    end
    for _, s in ipairs(policeParticipantSources(rt)) do add(s) end
    for _, s in ipairs(gangParticipantSources(rt)) do add(s) end
    for _, s in ipairs(Bridge.GetPlayers()) do
        if UserPermissions.canAny(s, 'convoys.view', 'dashboard.view', 'participants.view') then add(s) end
    end
    return sources
end

local function announceLootToTacticalAudience(rt, title, body, duration, gang)
    if not rt or not rt.def or not rt.def.settings or not rt.def.settings.announcements then return end
    if not title or title == '' then return end
    notify(tacticalPlusAdminSources(rt), 'nova_convoytruck:runtime:announce', title, body, duration, 'success', gang)
end

local function truckLootItemsLine(t)
    local parts = {}
    if t and t.reward and #t.reward > 0 then
        for _, r in ipairs(t.reward) do
            local rType = string.upper(tostring(r.type or ''))
            if rType == 'MONEY' or rType == 'CASH' then
                parts[#parts + 1] = ('$%s'):format(r.amount or 0)
            else
                parts[#parts + 1] = ('%sx %s'):format(r.amount or 1, r.pool or r.model or 'item')
            end
        end
    end
    for _, item in ipairs((t and t.lootItems) or {}) do
        parts[#parts + 1] = ('%sx %s'):format(item.count or 1, item.item)
    end
    return #parts > 0 and table.concat(parts, ', ') or 'High-Value Cargo'
end

local function registerLootCarrier(rt, src, lootType, targetName, rewardsStr)
    if not rt or not src then return end
    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end
    local playerName = Bridge.GetPlayerName(src) or 'Unknown'
    local isPolice = Bridge.IsPolice(src) or false
    local gangName = identifier and rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier]
    if not gangName and not isPolice then
        local g = GangService.GetPlayerGang(src)
        if g and g.name then gangName = g.name end
    end
    local identity = gangName and gangIdentity(rt, gangName) or nil
    local gangLabel = identity and identity.label or gangName or (isPolice and 'Police Department' or 'Independent')

    rt.carriers = rt.carriers or {}
    rt.carriers[identifier] = {
        source = src,
        identifier = identifier,
        name = playerName,
        gang = gangName,
        gangLabel = gangLabel,
        isPolice = isPolice,
        lootType = lootType,
        target = targetName,
        rewards = rewardsStr,
        timestamp = os.time(),
        timeStr = os.date('!%H:%M:%S', os.time()),
    }
end

local function handleParticipantDeath(victimSrc, killerSrc, weaponHash)
    if not victimSrc then return end
    local victimIdentifier = Bridge.GetIdentifier(victimSrc)
    if not victimIdentifier then return end

    for convoyId, rt in pairs(active) do
        if rt and rt.carriers and rt.carriers[victimIdentifier] then
            local carrier = rt.carriers[victimIdentifier]
            rt.carriers[victimIdentifier] = nil

            if killerSrc and killerSrc ~= 0 and killerSrc ~= victimSrc then
                local killerIdentifier = Bridge.GetIdentifier(killerSrc) or 'N/A'
                local killerName = Bridge.GetPlayerName(killerSrc) or 'Unknown Player'
                local killerIsPolice = Bridge.IsPolice(killerSrc) or false
                local killerJobGrade = Bridge.GetJobGrade(killerSrc) or nil
                local killerJobName = killerJobGrade and killerJobGrade.name or (killerIsPolice and 'police' or 'civilian')
                local killerGang = killerIdentifier and rt.participants and rt.participants.identifiers and rt.participants.identifiers[killerIdentifier]
                if not killerGang and not killerIsPolice then
                    local g = GangService.GetPlayerGang(killerSrc)
                    if g and g.name then killerGang = g.name end
                end
                local killerIdentity = killerGang and gangIdentity(rt, killerGang) or nil
                local killerLabel = killerIdentity and killerIdentity.label or killerGang or (killerIsPolice and 'Police Department' or 'Independent')

                rt.pvpHijacks = rt.pvpHijacks or {}
                local hijackEntry = {
                    victim = {
                        name = carrier.name,
                        identifier = victimIdentifier,
                        gang = carrier.gang,
                        gangLabel = carrier.gangLabel,
                        isPolice = carrier.isPolice,
                    },
                    killer = {
                        name = killerName,
                        identifier = killerIdentifier,
                        gang = killerGang,
                        gangLabel = killerLabel,
                        isPolice = killerIsPolice,
                        job = killerJobName,
                        jobGrade = killerJobGrade and killerJobGrade.grade or 0,
                    },
                    lootType = carrier.lootType,
                    target = carrier.target,
                    rewards = carrier.rewards,
                    timestamp = os.time(),
                    timeStr = os.date('!%H:%M:%S', os.time()),
                }
                rt.pvpHijacks[#rt.pvpHijacks + 1] = hijackEntry

                if killerGang then
                    rt.gangHijackCounts = rt.gangHijackCounts or {}
                    rt.gangHijackCounts[killerGang] = (rt.gangHijackCounts[killerGang] or 0) + 1
                end

                if killerIsPolice then
                    rt.policeAudit = rt.policeAudit or {}
                    rt.policeAudit[#rt.policeAudit + 1] = {
                        type = 'CARGO_SEIZED',
                        target = carrier.target or carrier.lootType,
                        officerName = killerName,
                        officerIdentifier = killerIdentifier,
                        job = killerJobName,
                        jobGrade = killerJobGrade and killerJobGrade.grade or 0,
                        items = carrier.rewards or 'Cargo',
                        timestamp = os.time(),
                        timeStr = os.date('!%H:%M:%S', os.time()),
                        alert = ('OFFICER ELIMINATED LOOT CARRIER %s AND SEIZED CARGO'):format(carrier.name),
                    }
                end

                rt.carriers[killerIdentifier] = {
                    source = killerSrc,
                    identifier = killerIdentifier,
                    name = killerName,
                    gang = killerGang,
                    gangLabel = killerLabel,
                    isPolice = killerIsPolice,
                    lootType = carrier.lootType,
                    target = carrier.target,
                    rewards = carrier.rewards,
                    timestamp = os.time(),
                    timeStr = os.date('!%H:%M:%S', os.time()),
                }

                if rt.def and rt.def.settings and rt.def.settings.announcements then
                    local b = resolveBanner('lootHijacked', 'Loot Intercepted!', '%s was eliminated by %s (%s) — convoy cargo hijacked!', 7000, 'danger', carrier.name, killerName, killerLabel)
                    if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
                end

                DiscordLog.appendEvent(rt.id, ('⚔️ [LOOT HIJACK] %s (%s) killed %s (%s) and hijacked %s [%s]'):format(
                    killerName, killerLabel, carrier.name, carrier.gangLabel, carrier.target or carrier.lootType, carrier.rewards or 'Cargo'
                ))

                DB.insertConvoyEvent(rt.id, 'LOOT_HIJACKED', {
                    gangName = killerGang, gangLabel = killerLabel,
                    playerIdentifier = killerIdentifier, playerName = killerName,
                    detail = ('Killed %s (%s) and hijacked %s [%s]'):format(carrier.name, carrier.gangLabel, carrier.target or carrier.lootType, carrier.rewards or 'Cargo'),
                })
            end
        end
    end

    -- ── Post-Event Anti-Griefing Sentry Watchdog (60-minute window for HOT_CARGO) ──
    for sentryConvoyId, sentry in pairs(hotCargoSentries) do
        if os.time() <= (sentry.expiresAt or 0) then
            local isWinningMember = sentry.winningMembers and sentry.winningMembers[victimIdentifier]
            if not isWinningMember and sentry.winningGang then
                local g = GangService and GangService.GetPlayerGang(victimSrc)
                if g and g.name == sentry.winningGang then
                    isWinningMember = true
                end
            end
            if isWinningMember and killerSrc and killerSrc ~= 0 and killerSrc ~= victimSrc then
                local killerIdentifier = Bridge.GetIdentifier(killerSrc) or 'N/A'
                local killerName = Bridge.GetPlayerName(killerSrc) or 'Unknown Player'
                local killerIsPolice = Bridge.IsPolice(killerSrc) or false
                local killerGang = nil
                local g = GangService and GangService.GetPlayerGang(killerSrc)
                if g and g.name then killerGang = g.name end
                local killerLabel = (g and g.label) or killerGang or (killerIsPolice and 'Police Department' or 'Civilian')
                local victimName = Bridge.GetPlayerName(victimSrc) or 'Winning Gang Member'
                local victimGang = sentry.winningGangLabel or sentry.winningGang or 'Winning Gang'

                local dist = 0
                pcall(function()
                    local victimPed = GetPlayerPed(victimSrc)
                    if victimPed and DoesEntityExist(victimPed) and sentry.dropCoords then
                        dist = math.floor(#(GetEntityCoords(victimPed) - sentry.dropCoords))
                    end
                end)

                local elapsed = os.time() - (sentry.deliveredAt or os.time())
                local fields = {
                    { name = '🚨 VIOLATION', value = 'Player killed a member of the winning faction during the 60-minute post-event protection window!', inline = false },
                    { name = 'Operation', value = sentry.name or ('Hot Cargo #' .. tostring(sentryConvoyId)), inline = true },
                    { name = 'Winning Faction', value = tostring(victimGang), inline = true },
                    { name = 'Victim', value = ('%s (%s)\n`%s`'):format(victimName, victimGang, victimIdentifier), inline = true },
                    { name = 'Attacker / Killer', value = ('%s (%s)\n`%s`'):format(killerName, killerLabel, killerIdentifier), inline = true },
                    { name = 'Weapon Hash', value = tostring(weaponHash or 'Unknown'), inline = true },
                    { name = 'Distance to Dropoff', value = ('%d meters'):format(dist), inline = true },
                    { name = 'Time Since Delivery', value = ('%dm %02ds (Protection: 60m)'):format(math.floor(elapsed / 60), elapsed % 60), inline = true },
                }
                DiscordLog.postEventGriefingAlert(
                    ('🚨 [POST-EVENT SENTRY AUDIT — SUSPECTED GRIEFING] %s'):format(sentry.name or 'Hot Cargo'),
                    'Anti-Griefing Watchdog triggered: Lethal attack detected on winning faction within 60 minutes of Hot Cargo delivery.',
                    fields
                )
            end
        end
    end
end

RegisterNetEvent('nova_convoytruck:runtime:playerDied', function(killerServerId, weaponHash)
    local victimSrc = source
    handleParticipantDeath(victimSrc, killerServerId, weaponHash)
end)

AddEventHandler('baseevents:onPlayerKilled', function(killerId, data)
    local victimSrc = source
    handleParticipantDeath(victimSrc, killerId, data and data.weaponhash)
end)

-- ── extra report tables (PDF + Event History): who took part, race standings, Hot Cargo deliveries ──

local function clockText(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return ('%d:%02d'):format(math.floor(sec / 60), sec % 60)
end

-- Everyone who joined the run: police escorts, gang members, civilians.
local function participantsTable(rt)
    local p = rt.participants
    if type(p) ~= 'table' then return nil end
    local rows = {}
    for ident, gName in pairs(p.identifiers or {}) do
        local isCiv = gName == 'civilian' or (p.types and p.types[ident] == 'civilian')
        local identity = (not isCiv) and gangIdentity(rt, gName) or nil
        rows[#rows + 1] = { (p.names and p.names[ident]) or ident, isCiv and 'Civilian' or ((identity and identity.label) or gName or 'Gang') }
    end
    for ident in pairs(p.policeIdentifiers or {}) do
        rows[#rows + 1] = { (p.names and p.names[ident]) or ident, 'Police' }
    end
    if #rows == 0 then return nil end
    table.sort(rows, function(a, b)
        if a[2] ~= b[2] then return tostring(a[2]) < tostring(b[2]) end
        return tostring(a[1]) < tostring(b[1])
    end)
    local total = #rows
    for i = total, 101, -1 do rows[i] = nil end
    if total > 100 then rows[#rows + 1] = { ('... and %d more'):format(total - 100), '' } end
    return {
        title = ('PARTICIPANTS (%d)'):format(total),
        cols = { { label = 'PLAYER', x = 44, chars = 34 }, { label = 'SIDE / GANG', x = 260, chars = 34 } },
        rows = rows,
    }
end

-- Rally race: the finishing order with each racer's time, plus everybody who started and did not finish.
local function raceStandingsTable(rt)
    if rt.def.kind ~= 'GANG_RACE' then return nil end
    local pr = rt.def.positionRewards or {}
    local tokensBy = {}
    for _, tl in ipairs(rt.tokenLog or {}) do if tl.playerIdentifier then tokensBy[tl.playerIdentifier] = tl.amount end end
    local goAt = rt.raceGoAt or rt.startedAt or os.time()
    local rows, finishedIds = {}, {}
    for _, fr in ipairs(rt.finishedRacers or {}) do
        local r = fr.racer or {}
        finishedIds[r.identifier or ''] = true
        local list = (fr.rank == 1 and pr.first) or (fr.rank == 2 and pr.second) or (fr.rank == 3 and pr.third) or pr.participation
        local prize = {}
        if list and #list > 0 then prize[#prize + 1] = RewardService.describeRewards(list) end
        if tokensBy[r.identifier or ''] then prize[#prize + 1] = ('%d race tokens'):format(tokensBy[r.identifier]) end
        rows[#rows + 1] = {
            tostring(fr.rank), r.name or 'Racer', r.gangLabel or r.gang or 'Independent',
            clockText((fr.finishTime or goAt) - goAt), #prize > 0 and table.concat(prize, ' + ') or '-',
        }
    end
    local stages = #(rt.stages or {})
    for _, r in pairs(rt.racers or {}) do
        if not finishedIds[r.identifier or ''] then
            local reached = math.max(0, (r.currentStage or 1) - 1)
            rows[#rows + 1] = { 'DNF', r.name or 'Racer', r.gangLabel or r.gang or 'Independent', '-', ('Did not finish (checkpoint %d/%d)'):format(reached, stages) }
        end
    end
    if #rows == 0 then return nil end
    return {
        title = 'FINAL STANDINGS',
        cols = {
            { label = 'POS', x = 44, chars = 5 }, { label = 'RACER', x = 80, chars = 22 }, { label = 'GANG', x = 214, chars = 17 },
            { label = 'TIME', x = 312, chars = 9 }, { label = 'PRIZE', x = 370, chars = 36, wrap = true },
        },
        rows = rows,
    }
end

-- Hot Cargo: one row per delivered truck — the condition it arrived in decides how much of the reward the crate held.
local function deliveriesTable(rt)
    if rt.def.kind ~= 'HOT_CARGO' or #(rt.deliveryLog or {}) == 0 then return nil end
    local rows = {}
    for _, d in ipairs(rt.deliveryLog) do
        rows[#rows + 1] = { ('#%d'):format(d.truckNum or 1), d.gangLabel or d.gang or 'Gang', d.driver or 'Operative', ('%d%%'):format(d.conditionPct or 0), d.rewards or 'None' }
    end
    return {
        title = 'TRUCK DELIVERIES (REWARD SCALES WITH TRUCK CONDITION)',
        cols = {
            { label = 'TRUCK', x = 44, chars = 7 }, { label = 'GANG', x = 100, chars = 17 }, { label = 'DRIVER', x = 206, chars = 19 },
            { label = 'CONDITION', x = 316, chars = 10 }, { label = 'CRATE CONTENTS', x = 380, chars = 34, wrap = true },
        },
        rows = rows,
    }
end

local function buildConvoyReportData(rt, outcome, forcedByName)
    local now = os.time()
    local durSec = now - (rt.startedAt or now)
    local durText = ('%dm %02ds'):format(math.floor(durSec / 60), durSec % 60)

    local winnerText = 'None'
    local winningGangName = nil
    if rt.def.kind == 'GANG_AIRDROP' then
        local maxCaptures = 0
        for gName, count in pairs(rt.gangAirdropCounts or {}) do
            if count > maxCaptures then
                maxCaptures = count
                winningGangName = gName
            end
        end
        local winningIdentity = winningGangName and gangIdentity(rt, winningGangName)
        if outcome == 'COMPLETED' then
            winnerText = winningIdentity and ('%s (%d drops)'):format(winningIdentity.label, maxCaptures) or 'Participating Gangs'
        elseif outcome == 'CANCELLED' then
            winnerText = 'Cancelled by Administrator'
        elseif outcome == 'FAILED' then
            winnerText = 'None (No Drops Claimed)'
        end
    elseif rt.def.kind == 'HOT_CARGO' then
        winningGangName = rt.winningGang
        local winningIdentity = winningGangName and gangIdentity(rt, winningGangName)
        if outcome == 'COMPLETED' then
            winnerText = rt.winningGangLabel and ('🏴 %s'):format(rt.winningGangLabel) or (winningIdentity and winningIdentity.label or 'Winning Gang')
        elseif outcome == 'CANCELLED' then
            winnerText = 'Cancelled by Administrator'
        elseif outcome == 'FAILED' then
            winnerText = 'None (Contraband Lost / Destroyed)'
        end
    elseif rt.def.kind == 'GANG_RACE' then
        if rt.raceWinner then
            winningGangName = rt.raceWinner.gang
            local winningIdentity = winningGangName and gangIdentity(rt, winningGangName)
            local gangLabel = winningIdentity and winningIdentity.label or rt.raceWinner.gangLabel or rt.raceWinner.gang or 'Independent'
            winnerText = ('🏆 %s (%s)'):format(rt.raceWinner.name, gangLabel)
        elseif outcome == 'CANCELLED' then
            winnerText = 'Cancelled by Administrator'
        elseif outcome == 'FAILED' then
            winnerText = 'None (Time Expired / Incomplete)'
        end
    else
        local delivered, destroyed, captured = 0, 0, 0
        for _, t in pairs(rt.trucks or {}) do
            if t.delivered then delivered = delivered + 1 end
            if t.destroyed then destroyed = destroyed + 1 end
            if t.captured then captured = captured + 1 end
        end
        local maxCaptures = 0
        for gName, count in pairs(rt.gangCaptureCounts or {}) do
            if count > maxCaptures then
                maxCaptures = count
                winningGangName = gName
            end
        end
        local capturingIdentity = winningGangName and gangIdentity(rt, winningGangName)
        if outcome == 'COMPLETED' then
            winnerText = 'Law Enforcement (Police Escort Secured Cargo)'
        elseif outcome == 'CAPTURED' then
            winnerText = capturingIdentity and capturingIdentity.label or winningGangName or 'Hostile Gang'
        elseif outcome == 'CANCELLED' then
            winnerText = 'Cancelled by Administrator'
        elseif outcome == 'FAILED' then
            winnerText = 'None (Cargo Destroyed / Undelivered)'
        end
    end

    local truckList = {}
    local deliveredCount, capturedCount, destroyedCount, disabledCount, hijackedCount = 0, 0, 0, 0, 0
    if rt.def.kind ~= 'GANG_AIRDROP' and rt.def.kind ~= 'GANG_RACE' then
        for _, t in pairs(rt.trucks or {}) do
            if t.delivered then deliveredCount = deliveredCount + 1 end
            if t.captured then capturedCount = capturedCount + 1 end
            if t.destroyed then destroyedCount = destroyedCount + 1 end
            if t.brokenDown and not t.delivered then disabledCount = disabledCount + 1 end
            if t.hijacked then hijackedCount = hijackedCount + 1 end
            truckList[#truckList + 1] = {
                id = t.id,
                role = t.role,
                label = t.role == 'HOT_CARGO' and ('Cargo Truck #%d'):format(tonumber(tostring(t.id):match('(%d+)$')) or 1) or (TRUCK_ROLE_LABELS[t.role] or t.id),
                status = t.delivered and 'DELIVERED' or (t.captured and 'CAPTURED' or (t.destroyed and 'DESTROYED' or (t.brokenDown and (t.lootedBy and 'DISABLED — LOOTED' or 'DISABLED — LOOTABLE') or (t.hijacked and 'HIJACKED' or t.state or 'ACTIVE')))),
                delivered = t.delivered,
                captured = t.captured,
                destroyed = t.destroyed,
                capturedBy = t.capturedBy,
                lootedBy = t.lootedBy,
            }
        end
    end

    local interceptions = {}

    for _, t in pairs(rt.trucks or {}) do
        if t.capturedBy then
            interceptions[#interceptions + 1] = {
                time = t.capturedBy.timeStr or os.date('!%H:%M:%S', t.capturedBy.timestamp or now),
                timestamp = t.capturedBy.timestamp or now,
                target = TRUCK_ROLE_LABELS[t.role] or ('Truck ' .. tostring(t.id)),
                method = 'Disabled & Captured',
                actorName = t.capturedBy.name or 'Unknown',
                actorIdentifier = t.capturedBy.identifier or 'N/A',
                faction = t.capturedBy.gangLabel or (t.capturedBy.isPolice and 'Police' or 'Gang'),
                isPolice = t.capturedBy.isPolice == true,
                evidence = 'Vehicle disabled & secured',
                isAlert = t.capturedBy.isPolice == true,
                alertReason = t.capturedBy.isPolice and 'POLICE INTERCEPTED TRUCK' or nil,
            }
        end
        if t.lootedBy then
            local methodStr = t.lootedBy.viaBypass and 'Police Bypass' or (t.lootedBy.viaHack and 'Electronic Hack' or 'Lockpicked')
            interceptions[#interceptions + 1] = {
                time = t.lootedBy.timeStr or os.date('!%H:%M:%S', t.lootedBy.timestamp or now),
                timestamp = t.lootedBy.timestamp or now,
                target = TRUCK_ROLE_LABELS[t.role] or ('Truck ' .. tostring(t.id)),
                method = methodStr,
                actorName = t.lootedBy.name or 'Unknown',
                actorIdentifier = t.lootedBy.identifier or 'N/A',
                faction = t.lootedBy.gangLabel or (t.lootedBy.isPolice and 'Police' or 'Independent'),
                isPolice = t.lootedBy.isPolice == true,
                evidence = truckLootItemsLine(t),
                isAlert = t.lootedBy.isPolice == true,
                alertReason = t.lootedBy.isPolice and 'POLICE OFFICER LOOTED TRUCK CARGO' or nil,
            }
        end
    end

    for _, c in ipairs(rt.airdropCaptures or {}) do
        local methodStr = c.usedHack and 'Electronic Hack' or (c.usedLockpick and 'Lockpicked' or 'Cracked Open')
        interceptions[#interceptions + 1] = {
            time = c.timeStr or os.date('!%H:%M:%S', c.timestamp or now),
            timestamp = c.timestamp or now,
            target = c.dropName or 'Airdrop Crate',
            method = methodStr,
            actorName = c.playerName or 'Unknown',
            actorIdentifier = c.playerIdentifier or 'N/A',
            faction = c.gangLabel or (c.isPolice and 'Police' or 'Independent'),
            isPolice = c.isPolice == true,
            evidence = c.rewardSummary or (c.hit and 'Loot Secured' or 'Empty Crate'),
            isAlert = c.isPolice == true,
            alertReason = c.isPolice and 'POLICE OFFICER LOOTED AIRDROP' or nil,
        }
    end

    -- Hot Cargo's own timeline already shows these two moments (driver
    -- entered the seat, police GPS alert fired) as plain text lines, but
    -- neither ever made it into this structured capture-summary table the
    -- way a truck capture/loot or an airdrop crack-open does — a hijacked
    -- vehicle that got destroyed or recovered before delivery had NOTHING
    -- of its own in here at all. t.acquiredAt/t.policeAlertedAt are set
    -- right alongside the existing timeline log lines in monitorHotCargo.
    if rt.def.kind == 'HOT_CARGO' then
        -- One row per hijack (including a second gang taking a truck over).
        for _, h in ipairs(rt.hijackLog or {}) do
            interceptions[#interceptions + 1] = {
                time = h.timeStr,
                timestamp = h.timestamp,
                target = ('Cargo Truck #%d'):format(h.truckNum or 1),
                method = h.tookFrom and 'Hijack (taken over)' or 'Hijacked (lockpicked)',
                actorName = h.name or 'Unknown',
                actorIdentifier = h.identifier or 'N/A',
                faction = h.gangLabel or h.gang or 'Independent',
                isPolice = false,
                evidence = h.tookFrom and ('Took the truck from %s'):format(h.tookFrom) or 'Unlocked and took control of the truck',
                isAlert = false,
            }
        end
        for _, t in pairs(rt.trucks or {}) do
            if t.policeAlertedAt then
                interceptions[#interceptions + 1] = {
                    time = os.date('!%H:%M:%S', t.policeAlertedAt),
                    timestamp = t.policeAlertedAt,
                    target = ('Cargo Truck #%d'):format(tonumber(tostring(t.id):match('(%d+)$')) or 1),
                    method = 'Police Alert / GPS',
                    actorName = 'Police Dispatch',
                    actorIdentifier = 'N/A',
                    faction = 'Police',
                    isPolice = true,
                    evidence = ('Hijack alert sent, truck blip live (driver: %s)'):format(t.driverName or 'Unknown'),
                    isAlert = true,
                    alertReason = 'HOT CARGO TRUCK GPS TRACKED',
                }
            end
        end
    end

    -- Trucks that hit zero health: Hot Cargo and Convoy both keep the truck in
    -- the world, stopped, with its cargo lootable (not destroyed).
    for _, t in pairs(rt.trucks or {}) do
        if t.brokenDownAt then
            local label = t.role == 'HOT_CARGO' and ('Cargo Truck #%d'):format(tonumber(tostring(t.id):match('(%d+)$')) or 1)
                or TRUCK_ROLE_LABELS[t.role] or ('Truck ' .. tostring(t.id))
            interceptions[#interceptions + 1] = {
                time = os.date('!%H:%M:%S', t.brokenDownAt),
                timestamp = t.brokenDownAt,
                target = label,
                method = 'Truck Disabled',
                actorName = t.driverName or 'No driver',
                actorIdentifier = t.driverIdentifier or 'N/A',
                faction = t.driverGangLabel or t.driverGang or 'Independent',
                isPolice = false,
                evidence = 'Health depleted — stopped in place, cargo lootable',
                isAlert = false,
            }
        end
    end

    -- Non-police players who tried to drive a convoy truck and were moved out.
    for _, d in ipairs(rt.driverEjections or {}) do
        interceptions[#interceptions + 1] = {
            time = d.timeStr,
            timestamp = d.timestamp,
            target = d.target,
            method = 'Driver Seat Denied',
            actorName = d.name,
            actorIdentifier = d.identifier,
            faction = d.gangLabel or 'Independent',
            isPolice = false,
            evidence = 'Only police/admins may drive convoy vehicles — moved out',
            isAlert = true,
            alertReason = 'UNAUTHORISED DRIVER REMOVED',
        }
    end

    -- Every lockpick minigame attempt (pass / fail / lockpick snapped), so the
    -- after-action report shows exactly who tried what and how it went.
    for _, a in ipairs(rt.lootAttempts or {}) do
        interceptions[#interceptions + 1] = {
            time = a.timeStr or os.date('!%H:%M:%S', a.timestamp or now),
            timestamp = a.timestamp or now,
            target = a.target or 'Locked cargo',
            method = a.success and 'Lockpick Minigame — PASSED' or (a.broke and 'Lockpick Minigame — FAILED (pick snapped)' or 'Lockpick Minigame — FAILED'),
            actorName = a.playerName or 'Unknown',
            actorIdentifier = a.playerIdentifier or 'N/A',
            faction = a.gang or 'Independent',
            isPolice = false,
            evidence = ('Lockpick wear %d/%d'):format(a.wear or 0, a.maxWear or 4),
            isAlert = false,
        }
    end

    -- Rally race tokens awarded by finishing position.
    for _, p in ipairs(rt.tokenLog or {}) do
        interceptions[#interceptions + 1] = {
            time = p.timeStr or os.date('!%H:%M:%S', p.timestamp or now),
            timestamp = p.timestamp or now,
            target = ('Race finish — position %d'):format(p.rank or 0),
            method = 'Race Tokens Awarded',
            actorName = p.playerName or 'Unknown',
            actorIdentifier = p.playerIdentifier or 'N/A',
            faction = p.gangLabel or 'Street Racer',
            isPolice = false,
            evidence = ('%d race token%s'):format(p.amount or 0, (p.amount or 0) == 1 and '' or 's'),
            isAlert = false,
        }
    end

    for _, h in ipairs(rt.pvpHijacks or {}) do
        interceptions[#interceptions + 1] = {
            time = h.timeStr or os.date('!%H:%M:%S', h.timestamp or now),
            timestamp = h.timestamp or now,
            target = h.target or h.lootType or 'Convoy Cargo',
            method = 'PvP Loot Hijack',
            actorName = ('%s (stole from %s)'):format(h.killer.name or 'Killer', h.victim.name or 'Victim'),
            actorIdentifier = h.killer.identifier or 'N/A',
            faction = h.killer.gangLabel or (h.killer.isPolice and 'Police' or 'Gang'),
            isPolice = h.killer.isPolice == true,
            evidence = h.rewards or 'Cargo',
            isAlert = true,
            alertReason = ('KILLED %s (%s) & HIJACKED LOOT'):format(h.victim.name or 'Carrier', h.victim.gangLabel or 'Gang'),
        }
    end

    table.sort(interceptions, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)

    local gangScorecard = {}
    local gangIdentifiersCount = 0
    local gMap = {}
    for ident, gName in pairs(rt.participants and rt.participants.identifiers or {}) do
        gangIdentifiersCount = gangIdentifiersCount + 1
        if not gMap[gName] then
            local identy = gangIdentity(rt, gName)
            gMap[gName] = {
                name = gName,
                label = identy and identy.label or (gName == 'civilian' and 'Civilian' or gName),
                units = 0,
                trucksCaptured = 0,
                airdropsCaptured = 0,
                hijacks = 0,
                rewards = {},
            }
        end
        gMap[gName].units = gMap[gName].units + 1
    end

    for _, t in pairs(rt.trucks or {}) do
        if t.capturedBy and t.capturedBy.gang and gMap[t.capturedBy.gang] then
            gMap[t.capturedBy.gang].trucksCaptured = gMap[t.capturedBy.gang].trucksCaptured + 1
        end
        if t.lootedBy and t.lootedBy.gang and gMap[t.lootedBy.gang] then
            table.insert(gMap[t.lootedBy.gang].rewards, truckLootItemsLine(t))
        end
    end

    for _, c in ipairs(rt.airdropCaptures or {}) do
        if c.gang and gMap[c.gang] then
            gMap[c.gang].airdropsCaptured = gMap[c.gang].airdropsCaptured + 1
            if c.rewardSummary and c.rewardSummary ~= 'Empty / No rewards' then
                table.insert(gMap[c.gang].rewards, c.rewardSummary)
            end
        end
    end

    -- Hot Cargo truck hijacks count toward the hijacking gang's tally.
    for _, h in ipairs(rt.hijackLog or {}) do
        if h.gang and gMap[h.gang] then gMap[h.gang].hijacks = gMap[h.gang].hijacks + 1 end
    end

    for _, h in ipairs(rt.pvpHijacks or {}) do
        if h.killer.gang and gMap[h.killer.gang] then
            gMap[h.killer.gang].hijacks = gMap[h.killer.gang].hijacks + 1
            if h.rewards then
                table.insert(gMap[h.killer.gang].rewards, ('Hijacked: %s'):format(h.rewards))
            end
        end
    end

    -- Every gang is credited for the trucks IT delivered, with the condition each arrived in and what its crate really held.
    if rt.def.kind == 'HOT_CARGO' then
        for _, d in ipairs(rt.deliveryLog or {}) do
            local gName = d.gang
            if gName and gName ~= 'independent' and gName ~= 'none' then
                if not gMap[gName] then
                    gMap[gName] = { name = gName, label = d.gangLabel or gName, units = 1, trucksCaptured = 0, airdropsCaptured = 0, hijacks = 0, rewards = {} }
                end
                gMap[gName].trucksCaptured = gMap[gName].trucksCaptured + 1
                table.insert(gMap[gName].rewards, ('Truck #%d @ %d%%: %s'):format(d.truckNum or 1, d.conditionPct or 0, d.rewards or 'None'))
            end
        end
    end

    if rt.def.kind == 'HOT_CARGO' and rt.hotCargoDelivered and rt.winningGang and #(rt.deliveryLog or {}) == 0 then
        if not gMap[rt.winningGang] then
            local count = 0
            for _ in pairs(rt.winningMembers or {}) do count = count + 1 end
            gMap[rt.winningGang] = {
                name = rt.winningGang,
                label = rt.winningGangLabel or rt.winningGang,
                units = math.max(1, count),
                trucksCaptured = 0,
                airdropsCaptured = 0,
                hijacks = 0,
                rewards = {},
            }
        end
        gMap[rt.winningGang].trucksCaptured = (gMap[rt.winningGang].trucksCaptured or 0) + (rt.hotCargoDeliveredCount or 1)
        table.insert(gMap[rt.winningGang].rewards, RewardService.describeRewards(rt.def.reward))
    end

    if rt.def.kind == 'HOT_CARGO' and #(rt.deliveryLog or {}) > 0 then
        -- one row per delivered truck: who, in what condition, and what the crate really held
        for _, d in ipairs(rt.deliveryLog) do
            interceptions[#interceptions + 1] = {
                time = d.timeStr, timestamp = d.timestamp,
                target = ('Cargo Truck #%d'):format(d.truckNum or 1),
                method = 'Safe Dropoff Delivery',
                actorName = d.driver or 'Operative', actorIdentifier = d.identifier or 'N/A',
                faction = d.gangLabel or d.gang or 'Gang', isPolice = false,
                evidence = ('Delivered at %d%% condition - crate: %s'):format(d.conditionPct or 0, d.rewards or 'None'),
                isAlert = false,
            }
        end
    elseif rt.def.kind == 'HOT_CARGO' and rt.hotCargoDelivered then
        local driverName = rt.winningMembers and next(rt.winningMembers) and rt.winningMembers[next(rt.winningMembers)].name or 'Operative'
        local driverIdent = rt.winningMembers and next(rt.winningMembers) and rt.winningMembers[next(rt.winningMembers)].identifier or 'N/A'
        interceptions[#interceptions + 1] = {
            time = os.date('!%H:%M:%S', rt.endedAt or now),
            timestamp = rt.endedAt or now,
            target = 'Contraband Cargo Truck',
            method = 'Safe Dropoff Delivery',
            actorName = driverName,
            actorIdentifier = driverIdent,
            faction = rt.winningGangLabel or rt.winningGang or 'Gang',
            isPolice = false,
            evidence = 'Contraband delivered; unlocked reward crate secured',
            isAlert = false,
        }
    end

    for _, g in pairs(gMap) do
        gangScorecard[#gangScorecard + 1] = {
            name = g.name,
            label = g.label,
            units = g.units,
            trucksCaptured = g.trucksCaptured,
            airdropsCaptured = g.airdropsCaptured,
            hijacks = g.hijacks,
            rewardSummary = #g.rewards > 0 and table.concat(g.rewards, '; ') or 'None',
        }
    end

    local branding = Config.Branding or {}
    local operationName = branding.operationName or 'Nova Convoy'
    local pTitle = branding.pdfTitle or ('%s -- AFTER-ACTION REPORT'):format(operationName:upper())
    if rt.def.kind == 'HOT_CARGO' then
        pTitle = ('%s -- HOT CARGO OPERATION REPORT'):format(operationName:upper())
    elseif rt.def.kind == 'GANG_RACE' then
        pTitle = ('%s -- GANG RALLY / STREET RACE REPORT'):format(operationName:upper())
    end
    if pTitle:find('%%s') then pTitle = pTitle:format(operationName:upper()) end
    local pFooter = branding.pdfFooter or ('%s SYSTEM  |  CONFIDENTIAL AUTOMATED AUDIT & AFTER-ACTION REPORT'):format(operationName:upper())
    if pFooter:find('%%s') then pFooter = pFooter:format(operationName:upper()) end

    local report = {
        id = rt.id,
        kind = rt.def.kind or 'CONVOY',
        name = rt.def.name,
        cargoDescription = (rt.def.cargo and rt.def.cargo.description and rt.def.cargo.description ~= '' and rt.def.cargo.description) or (rt.def.cargo and rt.def.cargo.type) or 'High-Value Cargo',
        startedByName = rt.startedByName or 'System / Dispatch',
        startedAt = rt.startedAt or now,
        endedAt = now,
        startTimeStr = os.date('!%a, %d %b %Y %H:%M:%S UTC', rt.startedAt or now),
        endTimeStr = os.date('!%a, %d %b %Y %H:%M:%S UTC', now),
        durationSeconds = durSec,
        durationText = durText,
        outcome = outcome,
        winner = winnerText,
        winningGang = winningGangName,
        forcedByName = forcedByName,
        branding = {
            serverName = branding.serverName or 'Nova',
            operationName = operationName,
            tabletTitle = branding.tabletTitle or 'Operations Hub',
            pdfTitle = pTitle,
            pdfFooter = pFooter,
        },
        fleet = {
            total = rt.def.kind == 'GANG_AIRDROP' and #(rt.def.airdropZones or {}) or (rt.def.kind == 'HOT_CARGO' and (rt.hotCargo and rt.hotCargo.vehiclesToSpawn or 1) or #(rt.def.trucks or {})),
            delivered = rt.def.kind == 'HOT_CARGO' and (rt.hotCargoDeliveredCount or (rt.hotCargoDelivered and 1 or 0)) or deliveredCount,
            captured = capturedCount,
            destroyed = destroyedCount,
            disabled = disabledCount,
            hijacked = hijackedCount,
            trucks = truckList,
        },
        roster = {
            policeCount = rt.def.kind == 'GANG_AIRDROP' and 0 or #policeSources(),
            gangCount = gangIdentifiersCount,
            gangs = gMap,
        },
        interceptions = interceptions,
        gangScorecard = gangScorecard,
        policeAudit = rt.policeAudit or {},
        pvpHijacks = rt.pvpHijacks or {},
        airdropCaptures = rt.airdropCaptures or {},
        rewards = RewardService.describeRewards(rt.def.reward),
        timeline = DiscordLog.getTimeline(rt.id),
    }

    -- What was REALLY paid (the configured reward is only the maximum): the one-line summary and a per-player table.
    report.rewards = ReportBuilder.payoutSummary(rt.id, report.rewards)

    -- One line for the Event History list: the result of THIS kind of event, in its own terms.
    do
        local kind = rt.def.kind or 'CONVOY'
        local f = report.fleet or {}
        if kind == 'GANG_AIRDROP' then
            report.summaryLine = ('%d of %d drop zones claimed'):format(#(rt.airdropCaptures or {}), #(rt.def.airdropZones or {}))
        elseif kind == 'HOT_CARGO' then
            report.summaryLine = ('%d of %d trucks delivered · %d disabled · %d destroyed'):format(f.delivered or 0, f.total or 0, f.disabled or 0, f.destroyed or 0)
        elseif kind == 'GANG_RACE' then
            local racers = 0
            for _ in pairs(rt.racers or {}) do racers = racers + 1 end
            report.summaryLine = ('%d of %d racers finished · %d checkpoints'):format(#(rt.finishedRacers or {}), racers, #(rt.stages or {}))
        else
            report.summaryLine = ('%d of %d trucks delivered · %d captured · %d destroyed · %d/%d checkpoints'):format(
                f.delivered or 0, f.total or 0, f.captured or 0, f.destroyed or 0, math.max(0, (rt.currentRouteIndex or 1) - 1), #(rt.route or {}))
        end
    end

    local extra = {}
    local function addTable(tbl) if tbl then extra[#extra + 1] = tbl end end   -- (a nil in a list literal would end ipairs early)
    addTable(raceStandingsTable(rt))
    addTable(deliveriesTable(rt))
    addTable(ReportBuilder.payoutTable(rt.id))
    addTable(participantsTable(rt))
    if #extra > 0 then report.extraTables = extra end
    return report
end

-- ── police-only NPC map blips ────────────────────────────────────────────────────
-- Checkpoint/ambush/airdrop-guard NPCs are server-spawned peds — a client can
-- only AddBlipForEntity on one once it's actually streamed in nearby, which
-- police watching the map from across the city never get. So instead of an
-- entity-attached blip, the server just broadcasts the static spawn coords
-- (these NPC waves guard/hold a position, they don't patrol far) and the
-- client renders/removes a plain coord blip keyed by `id`. Joined police
-- escorts only — gang participants finding hostile NPCs on the map ahead of
-- time would defeat the entire point of an ambush/guarded checkpoint, and an
-- on-duty officer who never joined this convoy has no more business seeing
-- it than they do the truck blips.
local function addNpcBlip(rt, id, coords, kind, label)
    notify(policeAndAdminSources(rt), 'nova_convoytruck:runtime:npcBlipAdd', { id = id, coords = { x = coords.x, y = coords.y, z = coords.z }, kind = kind, label = label })
end

local function removeNpcBlip(rt, id)
    notify(policeAndAdminSources(rt), 'nova_convoytruck:runtime:npcBlipRemove', id)
end

-- ── persistence ──────────────────────────────────────────────────────────────────

local function serialize(rt)
    local trucks = {}
    for id, t in pairs(rt.trucks) do
        trucks[id] = {
            id = id, role = t.role, model = t.model, state = t.state,
            delivered = t.delivered, destroyed = t.destroyed, captured = t.captured,
            lastCoords = t.entity and DoesEntityExist(t.entity) and (function() local c = GetEntityCoords(t.entity) return { x = c.x, y = c.y, z = c.z } end)() or t.lastCoords,
        }
    end
    return {
        status = rt.status,
        currentRouteIndex = rt.currentRouteIndex,
        airdropsTriggered = rt.airdropsTriggered,
        lastReachedOrder = rt.lastReachedOrder,
        checkpointTimeRemaining = rt.checkpointTimeRemaining,
        deliveryTimeRemaining = rt.deliveryTimeRemaining,
        trucks = trucks,
        participantIdentifiers = rt.participants.identifiers,
        gangCounts = rt.participants.gangCounts,
        policeIdentifiers = rt.participants.policeIdentifiers,
        participantNames = rt.participants.names,
        startedAt = rt.startedAt,
    }
end

-- The saved copy of a running event is only for recovering after a restart, so it never needs to be newer than a few seconds: a burst of
-- changes (a squad joining, several trucks delivered at once, the checkpoint timer) costs ONE write, flushed a moment after the first.
-- The flush checks the event is still the live one, so it can never bring back the row of an event that has already ended.
local PERSIST_GAP_MS = 4000
local function persist(rt)
    local now = GetGameTimer()
    if rt._savedAt and now - rt._savedAt < PERSIST_GAP_MS then
        if not rt._saveQueued then
            rt._saveQueued = true
            SetTimeout(PERSIST_GAP_MS - (now - rt._savedAt) + 50, function()
                rt._saveQueued = nil
                if active[rt.id] == rt then rt._savedAt = GetGameTimer(); DB.saveRuntime(rt.id, rt.status, serialize(rt)) end
            end)
        end
        return
    end
    rt._savedAt = now
    DB.saveRuntime(rt.id, rt.status, serialize(rt))
end

local driveColumn
local resolveDriveTarget

-- ── truck spawning ───────────────────────────────────────────────────────────────

-- Reverted the side-by-side (perpendicular) spawn formation: a fixed lateral
-- offset has no way of knowing how wide the actual road is at any given
-- START point, so a 2nd/3rd truck routinely landed half in the dirt
-- shoulder instead of the next lane over — visibly off-road, and very
-- likely the real reason those same trucks then looked lost/confused
-- fighting their way back onto the road network before they could make any
-- real progress. Nose-to-tail behind the point (along the road's own
-- heading) doesn't have this problem — it was reliable before, so it's
-- back to that.
local function spawnTruck(startPoint, truckDef, index, totalTrucks, rtId)
    index = index or 1
    local heading = startPoint.heading or 0.0
    local rad = math.rad(heading)

    -- Backward vector: In GTA V 0°=North(+Y), 90°=West(-X), 180°=South(-Y), 270°=East(+X)
    -- Vehicles spawn behind the START point in convoy column order.
    local backX = math.sin(rad)
    local backY = -math.cos(rad)

    -- Dynamic gap: scales with fleet size so 2-truck and 10-truck convoys both look right.
    -- Per-truck override (formationOffset) from the tablet definition always wins if set.
    local cfg = Config.ConvoySpacing or {}
    local base  = tonumber(cfg.baseSpacing)   or 18.0
    local scale = tonumber(cfg.scalePerTruck) or 1.1
    local cap   = tonumber(cfg.maxSpacing)    or 30.0
    local n = math.max(1, math.min(totalTrucks or 1, 10))
    local dynamicSpacing = math.min(cap, base + math.max(0, n - 1) * scale)
    local safeSpacing    = (index - 1) * dynamicSpacing
    local configuredOff  = tonumber(truckDef.formationOffset) or 0
    local distance = configuredOff > 0 and math.max(safeSpacing, configuredOff) or safeSpacing

    local x = startPoint.x + backX * distance
    local y = startPoint.y + backY * distance
    local z = startPoint.z or 0.0

    -- An admin-placed spawn spot for this exact truck (Route tab → START →
    -- Truck Spawn Positions) always wins over the automatic spacing above.
    local placed = type(startPoint.truckSpawns) == 'table' and startPoint.truckSpawns[truckDef.id]
    if type(placed) == 'table' and tonumber(placed.x) and tonumber(placed.y) then
        x, y = tonumber(placed.x), tonumber(placed.y)
        z = tonumber(placed.z) or z
        heading = tonumber(placed.heading) or heading
    end

    local model = joaat(truckDef.model)
    local veh
    if CreateVehicleServerSetter then
        veh = CreateVehicleServerSetter(model, 'automobile', x, y, z, heading)
    else
        veh = CreateVehicle(model, x, y, z, heading, true, true)
    end
    if veh and veh ~= 0 then
        local deadline = GetGameTimer() + 3000
        while not DoesEntityExist(veh) and GetGameTimer() < deadline do Wait(25) end
    end
    if not veh or not DoesEntityExist(veh) then return nil end

    -- Let the entity settle for one frame before touching it
    Wait(50)

    -- Never let OneSync quietly despawn/reset this truck just because no
    -- client stayed within streaming range of it (an admin spectating from
    -- far away in noclip, or a straggler truck lagging well behind the
    -- lead, both do this) — without this a truck out of everyone's
    -- relevance range could lose its AI task/driver entirely and just sit
    -- there looking "given up" until someone gets close again.
    pcall(SetEntityAsMissionEntity, veh, true, true)
    -- Mission-entity status does not make a client simulate the truck. A truck outside every player's streaming range has
    -- NO owner and its AI does not run at all (it just stands there). A big culling radius keeps it streamed to - and
    -- owned by - any player within that distance, so a straggler left behind by the column still drives on.
    pcall(SetEntityDistanceCullingRadius, veh, tonumber(Config.TruckCullingRadius) or 1500.0)

    local vehNetId = NetworkGetNetworkIdFromEntity(veh)
    local health = math.floor(truckDef.health or Config.DefaultTruckHealth)
    Entity(veh).state:set('convoy_truck', true, true)
    -- qbx_vehiclekeys rolls a random lock (75% by default) on any NPC-driven vehicle the first time a player tries to
    -- get in, but only when the vehicle has no 'doorslockstate' yet. Setting it here (1 = unlocked) skips that roll and
    -- every client applies it, so police can always board. Gang access is still gated by enforceDriverSeat.
    Entity(veh).state:set('doorslockstate', 1, true)
    pcall(SetVehicleDoorsLocked, veh, 1)
    if rtId then Entity(veh).state:set('convoy_id', rtId, true) end
    Entity(veh).state:set('truck_id', truckDef.id, true)
    Entity(veh).state:set('convoy_truck_label', TRUCK_ROLE_LABELS[truckDef.role] or 'Convoy Truck', true)
    Entity(veh).state:set('maxHealth', health, true)
    Entity(veh).state:set('releaseHeld', true, true)
    TriggerClientEvent('nova_convoytruck:runtime:snapTruckToGround', -1, vehNetId)

    -- Freeze immediately so trucks don't roll or slide into each other during the buffer window
    FreezeEntityPosition(veh, true)
    pcall(SetEntityHeading, veh, heading)

    -- Always set max health to match, not just when raising it above the
    -- vanilla 1000 default — an admin who deliberately configures a LOW body
    -- health (e.g. 100, to make a truck genuinely fragile) previously had
    -- that only lower CURRENT health while max health silently stayed at
    -- 1000, so the truck spawned already sitting at a misleadingly low
    -- percentage instead of actually being as fragile as configured.
    pcall(SetEntityMaxHealth, veh, health)
    pcall(SetEntityHealth, veh, health)
    pcall(SetVehicleEngineHealth, veh, truckDef.engineHealth or Config.DefaultEngineHealth)
    pcall(SetVehicleTyresCanBurst, veh, false)
    pcall(SetVehiclePetrolTankHealth, veh, 5000.0)
    pcall(SetVehicleCanLeakPetrol, veh, false)
    pcall(SetVehicleExplodesOnHighExplosionDamage, veh, false)
    pcall(SetVehicleStrong, veh, true)
    pcall(SetVehicleHasStrongAxles, veh, true)
    pcall(SetVehicleDamageModifier, veh, (tonumber(Config.TruckDamageModifier) or 1.0) + 0.0)

    -- ── Driver NPC spawn (3-stage robust attempt) ─────────────────────────────
    -- Stage 1: CreatePedInsideVehicle (preferred — seats the ped instantly)
    -- Stage 2: CreatePed at ground level + SetPedIntoVehicle loop (fallback)
    -- Stage 3: 300ms settle + second SetPedIntoVehicle retry (handles slow entity streaming)
    local driverPed = nil
    if truckDef.npcDriver and truckDef.role ~= 'ESCORT' then
        local modelName = truckDef.npcModel
        if not modelName or modelName == '' or modelName == 'a_m_m_business_01' then
            modelName = 's_m_m_marine_01'
        end
        local pedModel = joaat(modelName)

        -- Stage 1: Create directly inside vehicle
        driverPed = CreatePedInsideVehicle(veh, 4, pedModel, -1, true, false)
        -- A freshly created entity handle can briefly fail DoesEntityExist
        -- on the very same tick it was created on (a real FiveM registration-
        -- timing quirk, not a genuine spawn failure) — checking immediately,
        -- with no yield at all, made Stage 1 look like it had failed even
        -- when it had actually succeeded, so Stage 2 fired ON TOP OF it: a
        -- second driver ped, standing at the vehicle's own spawn coords
        -- (its SetPedIntoVehicle below can't succeed either, since the real
        -- Stage 1 ped is already sitting in the only driver seat) — exactly
        -- where the truck itself materializes, getting crushed by its own
        -- spawn. That's what "an NPC that looks like the driver, but isn't,
        -- dies right as the truck spawns" was.
        Wait(0)

        -- Stage 2: fallback — CreatePed + SetPedIntoVehicle. Re-checks who's
        -- actually in the seat first (not just whether Stage 1's own handle
        -- reads back as valid yet) so it can never double-spawn a driver
        -- that's already there.
        if GetPedInVehicleSeat(veh, -1) ~= 0 and DoesEntityExist(GetPedInVehicleSeat(veh, -1)) then
            driverPed = GetPedInVehicleSeat(veh, -1)
        elseif not driverPed or driverPed == 0 or not DoesEntityExist(driverPed) then
            driverPed = CreatePed(4, pedModel, x, y, z, heading, true, false)
            if driverPed and driverPed ~= 0 and DoesEntityExist(driverPed) then
                SetPedIntoVehicle(driverPed, veh, -1)
                Wait(100)
                -- not seated = it would stand beside the truck as an extra NPC: remove it (the truck is then undriven and recovery retries)
                if GetPedInVehicleSeat(veh, -1) ~= driverPed then
                    DeleteEntity(driverPed)
                    driverPed = nil
                end
            end
        end

        if not driverPed or driverPed == 0 or not DoesEntityExist(driverPed) then
            lib.print.warn(('[NovaConvoy] Failed to spawn NPC driver (model "%s") for truck %s — check it\'s a valid ped model. Truck will be undriven.'):format(modelName, tostring(truckDef.id)))
            driverPed = nil
        else
            local pedNetId = NetworkGetNetworkIdFromEntity(driverPed)
            -- Own non-combat group, never a combat ped — see nova_convoy_driver in
            -- npc_relationships.lua for why (combat tasks were replacing the drive task).
            TriggerClientEvent('nova_convoytruck:client:setDriverGroup', -1, pedNetId)
            pcall(SetPedCombatAttributes, driverPed, 3, false)  -- BF_CanLeaveVehicle = FALSE
            pcall(SetPedCombatAttributes, driverPed, 1, false)  -- BF_CanFightArmedPedsWhenNotArmed = FALSE
            pcall(SetPedCombatAttributes, driverPed, 46, false) -- BF_AlwaysFight = FALSE
            pcall(SetPedFleeAttributes, driverPed, 0, false)
            pcall(SetBlockingOfNonTemporaryEvents, driverPed, true)
            pcall(SetPedKeepTask, driverPed, true)
            pcall(SetPedCanBeDraggedOut, driverPed, false)
            pcall(SetEntityInvincible, driverPed, true)
            pcall(SetEntityAsMissionEntity, driverPed, true, true) -- same OneSync-culling protection as the vehicle above
            pcall(SetEntityDistanceCullingRadius, driverPed, tonumber(Config.TruckCullingRadius) or 1500.0)
        end
    end

    return {
        id = truckDef.id, entity = veh, netId = vehNetId,
        role = truckDef.role, model = truckDef.model, npcDriver = truckDef.npcDriver, driverPed = driverPed,
        npcModel = truckDef.npcModel,
        speed = truckDef.speed or Config.DefaultTruckSpeed or 1.0, state = 'HEALTHY', delivered = false, destroyed = false, captured = false,
        maxHealth = health,
        healthSynced = false, spawnedAt = os.time(), -- see pollTrucks' own re-assert, right below its "engineHealth" read
        captureProgress = 0, lockpicksRequired = tonumber(truckDef.lockpicksRequired),
        lockProgress = 0, lockUnlocked = false,
        columnIndex = index, -- nose-to-tail formation slot, see columnOrder/driveColumn
        formationOffset = tonumber(truckDef.formationOffset) or 0, -- per-truck spacing override, same field spawnTruck itself already honors
        reward = truckDef.reward or truckDef.rewards or {},
        routeIdx = 1,
        completedCheckpoints = {},
        lastCoords = { x = x, y = y, z = z },
        lastHeading = heading,
    }
end

-- Robust NPC Driver Recovery: re-seats or respawns an NPC driver if culled, killed, or missing.
-- It must never leave a SECOND ped standing beside the truck, so:
--   * one recovery per truck at a time (it yields, and driveColumn / pollTrucks / the client watchdog all call it —
--     without the lock two callers each saw "no driver" and each created one);
--   * a recovery ped that cannot be seated is deleted, never left on the road next to the truck;
--   * a real player in the driver seat (the police driver) is not a "missing driver";
--   * a retry is not allowed more often than every 5 seconds.
local function isPlayerPed(ped)
    for _, s in ipairs(Bridge.GetPlayers()) do
        if GetPlayerPed(s) == ped then return true end
    end
    return false
end

local function ensureTruckDriver(truck)
    if not truck or truck.delivered or truck.destroyed or truck.captured or truck.state == 'DISABLED' or truck.disabled then return nil end
    if truck.npcDriver == false or truck.role == 'ESCORT' then return nil end
    if not truck.entity or not DoesEntityExist(truck.entity) then return nil end

    local cur = truck.driverPed
    local valid = cur and DoesEntityExist(cur) and (not GetEntityHealth or GetEntityHealth(cur) > 0)
    if valid then return cur end

    if truck.driverRecovering then return nil end
    local nowMs = GetGameTimer()
    if truck.driverRecoverAt and nowMs < truck.driverRecoverAt then return nil end

    local inSeat = GetPedInVehicleSeat(truck.entity, -1)
    if inSeat ~= 0 and DoesEntityExist(inSeat) then
        if isPlayerPed(inSeat) then return nil end
        if not GetEntityHealth or GetEntityHealth(inSeat) > 0 then
            truck.driverPed = inSeat
            return inSeat
        end
    end

    truck.driverRecovering = true
    truck.driverRecoverAt = nowMs + 5000
    local result = nil
    local ok, err = pcall(function()
        local modelName = truck.npcModel
        if not modelName or modelName == '' or modelName == 'a_m_m_business_01' then
            modelName = 's_m_m_marine_01'
        end
        local pedModel = joaat(modelName)
        local c = GetEntityCoords(truck.entity)
        local heading = GetEntityHeading(truck.entity)

        local driverPed = CreatePedInsideVehicle(truck.entity, 4, pedModel, -1, true, false)
        Wait(0)
        -- the seat is the source of truth for who is driving now
        local seated = GetPedInVehicleSeat(truck.entity, -1)
        if seated ~= 0 and DoesEntityExist(seated) then
            if driverPed and driverPed ~= 0 and driverPed ~= seated and DoesEntityExist(driverPed) then DeleteEntity(driverPed) end
            if isPlayerPed(seated) then return end
            driverPed = seated
        elseif not driverPed or driverPed == 0 or not DoesEntityExist(driverPed) then
            driverPed = CreatePed(4, pedModel, c.x, c.y, c.z, heading, true, false)
            if driverPed and driverPed ~= 0 and DoesEntityExist(driverPed) then
                SetPedIntoVehicle(driverPed, truck.entity, -1)
                Wait(100)
                if GetPedInVehicleSeat(truck.entity, -1) ~= driverPed then
                    -- could not be seated: remove it rather than leave an extra NPC standing by the truck
                    DeleteEntity(driverPed)
                    driverPed = nil
                end
            else
                driverPed = nil
            end
        end

        if driverPed and driverPed ~= 0 and DoesEntityExist(driverPed) then
            local pedNetId = NetworkGetNetworkIdFromEntity(driverPed)
            TriggerClientEvent('nova_convoytruck:client:setDriverGroup', -1, pedNetId)
            pcall(SetPedCombatAttributes, driverPed, 3, false)  -- BF_CanLeaveVehicle = FALSE
            pcall(SetPedCombatAttributes, driverPed, 1, false)  -- BF_CanFightArmedPedsWhenNotArmed = FALSE
            pcall(SetPedCombatAttributes, driverPed, 46, false) -- BF_AlwaysFight = FALSE
            pcall(SetPedFleeAttributes, driverPed, 0, false)
            pcall(SetBlockingOfNonTemporaryEvents, driverPed, true)
            pcall(SetPedKeepTask, driverPed, true)
            pcall(SetPedCanBeDraggedOut, driverPed, false)
            pcall(SetEntityInvincible, driverPed, true)
            pcall(SetEntityAsMissionEntity, driverPed, true, true)
            pcall(SetEntityDistanceCullingRadius, driverPed, tonumber(Config.TruckCullingRadius) or 1500.0)
            truck.driverPed = driverPed
            print(('[NovaConvoy] Successfully restored/recovered NPC driver for convoy truck %s'):format(tostring(truck.id)))
            result = driverPed
        end
    end)
    truck.driverRecovering = false
    if not ok then print(('[NovaConvoy] Driver recovery for truck %s errored: %s'):format(tostring(truck.id), tostring(err))) end
    return result
end

local function stopTruck(truck)
    if not truck then return end
    if truck.driverPed and DoesEntityExist(truck.driverPed) then
        pcall(ClearPedTasks, truck.driverPed)
    end
    if truck.entity and DoesEntityExist(truck.entity) then
        Entity(truck.entity).state:set('convoy_target', nil, true)
        -- A player-driven truck (no NPC driver) is never braked/tasked remotely —
        -- the client fallback would grab whoever sits in the seat, i.e. the
        -- officer, and clear their tasks. Holds still freeze it separately.
        if truck.driverPed then
            TriggerClientEvent('nova_convoytruck:runtime:stopTruck', -1, truck.netId, NetworkGetNetworkIdFromEntity(truck.driverPed))
        end
    end
end

-- Every truck drives to its OWN point independently — see driveColumn's own
-- comment for why "followers escort the truck directly ahead of them" was
-- dropped (a captured/disabled/gang-driven truck used to drag its followers'
-- behavior down with it — and even while nothing was wrong, a follower
-- mirrored every swerve/brake the truck ahead of it made). First attempt at
-- this used the wrong sign order in its heading formula (atan2(dx,-dy)
-- instead of atan2(-dx,dy) — see regroupTrucksAtCheckpoint's own comment on
-- that exact mistake) and offset every follower roughly 180° from where it
-- needed to be, which is what actually caused the "mental"/spinning
-- regression, not the independent-target concept itself.
local function driveTruckTo(truck, point, cruiseSpeed, fromPoint, nextPoint)
    if not truck.driverPed or not DoesEntityExist(truck.driverPed) then
        ensureTruckDriver(truck)
    end
    if not truck.driverPed or not DoesEntityExist(truck.driverPed) then return end
    if not truck.entity or not DoesEntityExist(truck.entity) then return end
    local speed = (cruiseSpeed or 15.0) * (truck.speed or 1.0) * (truck.speedFactor or 1.0)

    -- Safe Checkpoint Approach & Gradual Deceleration:
    -- Avoid abrupt full-speed ramming into checkpoints by gently slowing down as the truck nears the zone
    if point.type == 'CHECKPOINT' and truck.entity and DoesEntityExist(truck.entity) then
        local c = GetEntityCoords(truck.entity)
        local d = #(vec2(c.x, c.y) - vec2(point.x, point.y))
        if d <= 12.0 then
            speed = math.min(speed, 2.5)
        elseif d <= 25.0 then
            speed = math.min(speed, 4.0)
        elseif d <= 50.0 then
            speed = math.min(speed, 7.0)
        elseif d <= 85.0 then
            speed = math.min(speed, 10.5)
        end
    end

    local pedNetId = NetworkGetNetworkIdFromEntity(truck.driverPed)
    local targetData = {
        x = point.x,
        y = point.y,
        z = point.z,
        speed = speed,
        pedNetId = pedNetId,
        isCheckpoint = (point.type == 'CHECKPOINT'),
        -- the route point before this one: the drawn leg the truck should follow (the client drives it in hops along that line)
        fx = fromPoint and tonumber(fromPoint.x) or nil,
        fy = fromPoint and tonumber(fromPoint.y) or nil,
        fz = fromPoint and tonumber(fromPoint.z) or nil,
        -- the route point AFTER this one: the client slows the truck down on the approach to a sharp corner (see issueTruckDriveTask)
        nx = nextPoint and tonumber(nextPoint.x) or nil,
        ny = nextPoint and tonumber(nextPoint.y) or nil,
    }
    truck.lastDriveTaskTime = os.time()
    Entity(truck.entity).state:set('convoy_target', targetData, true)
    FreezeEntityPosition(truck.entity, false)
    TriggerClientEvent('nova_convoytruck:runtime:taskDrive', -1, truck.netId, pedNetId, targetData, speed)
end

-- (registered here, after driveTruckTo exists: up where ensureTruckDriver is defined it was a nil call every time a driver was recovered)
RegisterNetEvent('nova_convoytruck:runtime:recoverDriver', function(vehNetId)
    if not vehNetId then return end
    for _, rt in pairs(active) do
        for _, t in pairs(rt.trucks or {}) do
            if t.netId == vehNetId then
                local ped = ensureTruckDriver(t)
                if ped and t.entity and DoesEntityExist(t.entity) then
                    local p = (rt.route and rt.route[t.routeIdx or 1]) or findPoint(rt.route, 'DESTINATION')
                    if p then driveTruckTo(t, p) end
                end
                return
            end
        end
    end
end)

-- AIRDROP points are split out of rt.route entirely (see splitRoute), so
-- this skip is just a safety net — the trucks never steer toward one.
resolveDriveTarget = function(rt, index)
    local point = rt.route[index]
    if not point or point.type ~= 'AIRDROP' then return point end
    for i = index + 1, #rt.route do
        if rt.route[i].type ~= 'AIRDROP' then return rt.route[i] end
    end
    return point
end

-- ── truck health / capture polling ────────────────────────────────────────────────

-- Truck condition 0-100 as the players see it: the LOWER of the body health and the engine health. Bullets mostly drain the engine
-- (at 0 the truck is disabled), so a bar that only followed the body health sat near 100% while the truck was being shot to death.
-- The engine's full value is the highest reading seen for this truck (never below a stock 1000).
local function combinedHealthPct(entity, maxH, rec)
    local health = GetEntityHealth(entity) or 0
    local body = (maxH and maxH > 0) and (health / maxH) or 1.0
    local engPct = 1.0
    local okE, eng = pcall(GetVehicleEngineHealth, entity)
    if okE and type(eng) == 'number' then
        rec = rec or {}
        local seen = math.max(rec.engineSeen or 0.0, eng)
        rec.engineSeen = seen
        engPct = math.max(0.0, math.min(1.0, eng / math.max(seen, 1000.0)))
    end
    -- ceil, not floor: a brand-new truck reads 99.9% (a point of body damage from settling on its wheels) and floor made it start at 99.
    -- Rounded up it starts at 100 and counts down 99, 98 ... as it really takes damage; a truck at 0 health still reads 0.
    local raw = math.min(body, engPct) * 100
    return math.max(0, math.min(100, health > 0 and math.ceil(raw - 0.001) or 0))
end

local function activeCargoTrucks(rt)
    local list = {}
    local totalCargoConfigured = 0
    for _, t in pairs(rt.trucks or {}) do
        if t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO' then
            totalCargoConfigured = totalCargoConfigured + 1
            if not t.delivered and not t.destroyed and not t.captured then
                list[#list + 1] = t
            end
        end
    end
    -- Fallback if convoy had no explicit PRIMARY_CARGO / SECONDARY_CARGO: check non-escort trucks
    if totalCargoConfigured == 0 then
        for _, t in pairs(rt.trucks or {}) do
            if t.role ~= 'ESCORT' then
                totalCargoConfigured = totalCargoConfigured + 1
                if not t.delivered and not t.destroyed and not t.captured then
                    list[#list + 1] = t
                end
            end
        end
    end
    return list, totalCargoConfigured
end

-- "Surviving" means not yet resolved into one of the three REAL terminal
-- states — delivered, destroyed, or captured. DISABLED (engine dead, or
-- overturned) used to also count as "not surviving" here, even though none
-- of those three things had actually happened to it yet — it's just an
-- intact truck that can't currently move, still fully in play (a gang could
-- still walk up and capture it, or it could get towed/repaired). The one
-- caller of this (the DELIVERY-status finish check below) treats an empty
-- list as "everything's resolved, end the event" — so a truck that reached
-- the destination, then got its engine disabled by gunfire before anyone
-- actually delivered it, would silently finish the whole convoy (deleting
-- the truck, no reward, no real delivery) the moment it went DISABLED. That
-- matches "truck disappeared, banner fired, but nothing was really
-- delivered" exactly.
local function survivingCargoTrucks(rt)
    local list = {}
    for _, t in pairs(rt.trucks or {}) do
        if (t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO') and not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED' then
            list[#list + 1] = t
        end
    end
    return list
end

-- Forward-declared: columnOrder's real definition sits much further down
-- this file (with driveColumn/updateColumnCohesion, which need it too), but
-- leadTruck needs to call it here first. Without this, the `local function
-- columnOrder` below created its own new local invisible to leadTruck's
-- already-compiled body — Lua resolved the call as an undefined GLOBAL,
-- throwing "attempt to call a nil value" every time leadTruck ran (silently
-- swallowed by checkEscortProximity's pcall, which is its only caller — so
-- "Require Police Escort Proximity" halting/resuming never actually worked).
local columnOrder

local function leadTruck(rt)
    local col = columnOrder(rt)
    if col and #col > 0 then return col[1] end
    for _, t in pairs(rt.trucks or {}) do
        if t.role == 'PRIMARY_CARGO' and not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED' then return t end
    end
    for _, t in pairs(rt.trucks or {}) do
        if not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED' then return t end
    end
    return nil
end

-- Route-point arrival used to check ONLY leadTruck (PRIMARY_CARGO, or any
-- survivor if that's gone) — fine with one truck, but with several it meant
-- the whole convoy's progress (checkpoints, destination banner) hostage to
-- whichever one happened to be tagged PRIMARY_CARGO: if THAT one got stuck
-- on bad AI pathing while a SECONDARY_CARGO truck had already reached the
-- point/destination, nothing ever advanced. Progress now follows whichever
-- surviving cargo truck is actually closest to the point, so one truck
-- lagging behind doesn't stall a convoy the rest of which has arrived.
local function closestCargoTruck(rt, x, y)
    local best, bestDist = nil, nil
    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED' and t.entity and DoesEntityExist(t.entity) then
            local c = GetEntityCoords(t.entity)
            local d = #(vector2(c.x, c.y) - vector2(x, y))
            if not bestDist or d < bestDist then
                best, bestDist = t, d
            end
        end
    end
    return best, bestDist
end

-- Finds which online player, if any, is physically sitting in a vehicle's
-- driver seat right now — used both to warn a real police driver their truck
-- is about to blow, and to safely move them out before the wreck is deleted.
-- Distinct from t.driverPed (the NPC ped THIS script spawned): with
-- npcDriver off, or if a player simply climbed into the driver's seat, the
-- one actually sitting there is a real player, not that ped at all.
local function findDrivingPlayerSource(entity)
    if not entity or not DoesEntityExist(entity) then return nil end
    local ped = GetPedInVehicleSeat(entity, -1)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    for _, s in ipairs(Bridge.GetPlayers()) do
        if GetPlayerPed(s) == ped then return s end
    end
    return nil
end

-- Driver seat of a convoy truck is police/admin only (Config.ConvoyDriverPoliceOnly).
-- A gang member who climbs behind the wheel is moved out at the next check; the
-- NPC driver (or the officer we assigned) is never affected. Captured/disabled
-- trucks are exempt — gangs may handle those.
local function enforceDriverSeat(t, rt)
    if Config.ConvoyDriverPoliceOnly == false then return end
    if not t or t.captured or t.destroyed or t.delivered or t.state == 'DISABLED' then return end
    local src = findDrivingPlayerSource(t.entity)
    if not src then return end
    if Bridge.IsPolice(src) or Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission) then
        -- Without keys qbx_vehiclekeys kills the engine for whoever sits at the wheel; hand them over once per officer.
        t.keysGiven = t.keysGiven or {}
        if not t.keysGiven[src] and Bridge.GiveVehicleKeys then
            t.keysGiven[src] = true
            pcall(Bridge.GiveVehicleKeys, src, t.entity)
        end
        return
    end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(t.entity)
    local rad = math.rad(GetEntityHeading(t.entity))
    SetEntityCoords(ped, c.x + math.cos(rad) * 3.0, c.y + math.sin(rad) * 3.0, c.z + 0.2, false, false, false, true)
    TriggerClientEvent('nova_convoytruck:client:notify', src, 'Only police and administrators may drive convoy vehicles.', 'error')
    if rt then
        local g = GangService.GetPlayerGang(src)
        local rec = { timestamp = os.time(), timeStr = os.date('!%H:%M:%S'), name = Bridge.GetPlayerName(src) or 'Unknown', identifier = Bridge.GetIdentifier(src) or 'N/A', gangLabel = g and (g.label or g.name) or nil, target = TRUCK_ROLE_LABELS[t.role] or ('Truck ' .. tostring(t.id)) }
        rt.driverEjections = rt.driverEjections or {}
        rt.driverEjections[#rt.driverEjections + 1] = rec
        DiscordLog.appendEvent(rt.id, ('🚫 %s (%s) tried to drive %s — moved out (police/admin only)'):format(rec.name, rec.gangLabel or 'no gang', rec.target))
        DB.insertConvoyEvent(rt.id, 'DRIVER_SEAT_DENIED', { gangName = g and g.name or nil, gangLabel = rec.gangLabel, playerIdentifier = rec.identifier, playerName = rec.name, detail = ('Tried to drive %s (police/admin only)'):format(rec.target) })
    end
end

-- Moves any real player still sitting in the truck (driver or passenger)
-- onto solid ground a few metres clear of it, BEFORE the vehicle entity gets
-- deleted below. Deleting an occupied networked vehicle doesn't cleanly
-- eject whoever's inside — the game just loses track of their seat, which
-- for a player (as opposed to the NPC driverPed, which is a separate ped we
-- delete outright) would otherwise mean the vehicle vanishing out from under
-- them with no warning. Relocating them first makes the engine properly
-- un-seat them while the vehicle still exists to un-seat them FROM.
local function ejectLivePlayersFrom(entity)
    if not entity or not DoesEntityExist(entity) then return false end
    local movedAny = false
    local coords = GetEntityCoords(entity)
    local heading = GetEntityHeading(entity)
    local rad = math.rad(heading)
    local sideX, sideY = math.cos(rad), math.sin(rad)
    local exitX, exitY = coords.x + sideX * 3.0, coords.y + sideY * 3.0
    -- GetVehicleMaxNumberOfPassengers is client-only (same class of bug as
    -- NetworkIsPlayerActive/GetVehicleMaxNumberOfPassengers's siblings this
    -- project has hit before) — doesn't exist server-side at all. A truck's
    -- real seat count never comes anywhere near this fixed upper bound;
    -- GetPedInVehicleSeat just returns 0 for a seat that doesn't exist, so
    -- overshooting it is harmless.
    for seat = -1, 8 do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            for _, s in ipairs(Bridge.GetPlayers()) do
                if GetPlayerPed(s) == ped then
                    SetEntityCoords(ped, exitX, exitY, coords.z + 0.2, false, false, false, true)
                    movedAny = true
                    break
                end
            end
        end
    end
    return movedAny
end

-- Health hit zero with someone still inside (usually a police officer driving
-- the truck while gangs shot it down): TELL them to get out. No teleporting —
-- the old behaviour of yanking them out of the seat is gone; the truck simply
-- shuts down (engine dead, frozen) and they exit on their own.
local function warnOccupantsToExit(entity, eventLabel)
    if not entity or not DoesEntityExist(entity) then return end
    for seat = -1, 8 do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            for _, s in ipairs(Bridge.GetPlayers()) do
                if GetPlayerPed(s) == ped then
                    TriggerClientEvent('nova_convoytruck:runtime:announce', s, (eventLabel or 'CONVOY') .. ' — TRUCK DISABLED: GET OUT', 'The truck has no health left and is shutting down. Get out of the truck now!', 6000, 'danger')
                    TriggerClientEvent('nova_convoytruck:client:notify', s, 'Truck disabled — get out of the truck now!', 'error')
                    break
                end
            end
        end
    end
end

-- Turns a truck into a lootable stash instead of deleting it — used for both
-- DISABLED (vehicle kept in world) and CAPTURED outcomes, per the design
-- decision that gang participants should be able to loot a lost cargo truck's cargo.
-- Event-specific truck name: Hot Cargo trucks are 'Cargo Truck #N', never a Convoy role label.
local function truckDisplayName(t)
    if t.role == 'HOT_CARGO' then return ('Cargo Truck #%d'):format(tonumber(tostring(t.id):match('(%d+)$')) or 1) end
    return TRUCK_ROLE_LABELS[t.role] or t.id
end

-- Registers the truck's cargo stash and fills it ONCE (t.stashSeeded). Used both when a truck
-- is lost (makeTruckLootable) and when police/admin inspect a still-running truck, so the
-- cargo is never added twice.
local function seedTruckStash(rt, t, coords)
    local stashId = ('convoy_truck_%d_%s'):format(rt.id, t.id)
    t.stashId = stashId -- Runtime.finish uses this to wipe the stash once the event ends
    if t.stashSeeded then return stashId end
    t.stashSeeded = true
    Inventory.RegisterStash(stashId, t.role == 'HOT_CARGO' and 'Hot Cargo Truck Cargo' or 'Convoy Truck Cargo', Config.CapturedTruckLoot.slots, Config.CapturedTruckLoot.weight, coords)
    local hasCustomItems = false
    if t.reward and #t.reward > 0 then
        for _, r in ipairs(t.reward) do
            local rType = string.upper(tostring(r.type or ''))
            if rType == 'ITEM' or rType == 'ITEMS' or rType == 'WEAPON' then
                local itemName = tostring(r.item or r.pool or r.model or '')
                if itemName ~= '' then
                    Inventory.AddItem(stashId, itemName, tonumber(r.amount) or 1)
                    hasCustomItems = true
                end
            end
        end
    end
    if not hasCustomItems then
        for _, item in ipairs(Config.CapturedTruckLoot.items or {}) do
            Inventory.AddItem(stashId, item.item, item.count or 1)
        end
        t.lootItems = Config.CapturedTruckLoot.items or {}
    end
    return stashId
end

local function makeTruckLootable(rt, t, gangSrcs)
    if not Config.CapturedTruckLoot or not Config.CapturedTruckLoot.enabled then return end
    local liveEntity = t.entity or t.propEntity
    local coords = (liveEntity and DoesEntityExist(liveEntity)) and GetEntityCoords(liveEntity) or t.lastCoords
    if not coords then return end
    local stashId = seedTruckStash(rt, t, coords)
    if liveEntity and DoesEntityExist(liveEntity) then
        Entity(liveEntity).state:set('convoy_truck_broken', true, true)
        Entity(liveEntity).state:set('convoy_stash_id', stashId, true)
        Entity(liveEntity).state:set('convoy_id', rt.id, true)
    end
    -- Broadcast to ALL clients (-1) so any gang member or nearby player can immediately see the prompt
    TriggerClientEvent('nova_convoytruck:runtime:truckLootable', -1, t.netId, stashId, rt.id, false, t.role == 'HOT_CARGO' and 'Loot Cargo Truck' or 'Hijack / Loot Truck')
end

-- Replaces zero-health destruction:
-- Keeps the truck entity in the world, unmoving and disabled, stops AI tasks,
-- removes it from the active convoy following chain, and makes its inventory available for looting.
local function disableTruckAndKeepEntity(t, rt, gangSrcs)
    if t.disabled or t.brokenDown then return end
    local driverNetId = nil

    if t.driverPed and DoesEntityExist(t.driverPed) then
        driverNetId = NetworkGetNetworkIdFromEntity(t.driverPed)
        ClearPedTasksImmediately(t.driverPed)
        DeleteEntity(t.driverPed)
        t.driverPed = nil
    end

    local stashId = ('convoy_truck_%d_%s'):format(rt.id, t.id)
    t.stashId = stashId

    if t.entity and DoesEntityExist(t.entity) then
        t.lastCoords = GetEntityCoords(t.entity)
        t.lastHeading = GetEntityHeading(t.entity)
        warnOccupantsToExit(t.entity, 'CONVOY')
        FreezeEntityPosition(t.entity, true)
        pcall(SetVehicleEngineHealth, t.entity, -4000.0)
        pcall(SetVehicleUndriveable, t.entity, true)
        pcall(SetEntityInvincible, t.entity, true)
        pcall(SetVehicleDoorsLocked, t.entity, 2)
        Entity(t.entity).state:set('convoy_truck_broken', true, true)
        Entity(t.entity).state:set('convoy_stash_id', stashId, true)
        Entity(t.entity).state:set('convoy_id', rt.id, true)
        Entity(t.entity).state:set('convoy_truck_label', (TRUCK_ROLE_LABELS[t.role] or 'Convoy Truck') .. ' — DISABLED', true)
    end

    if driverNetId and t.netId then
        TriggerClientEvent('nova_convoytruck:runtime:cleanupTruckDriver', -1, t.netId, driverNetId)
    end

    t.brokenDown = true
    t.brokenDownAt = os.time() -- feeds the "Truck Disabled" row in the report/PDF
    t.disabled = true
    t.state = 'DISABLED'

    -- Broadcast to ALL clients that this truck is disabled so blips update green
    if t.netId then
        TriggerClientEvent('nova_convoytruck:runtime:truckDisabled', -1, t.netId)
    end

    -- Make the existing vehicle entity lootable using existing inventory/lockpick system
    makeTruckLootable(rt, t, gangSrcs)

    -- Dynamic lead re-election & column re-tasking: remaining active trucks continue moving normally
    if rt and not rt.releaseHeld and driveColumn and resolveDriveTarget then
        driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), nil, true)
    end
end

local function replaceDestroyedTruckWithProp(t, rt, gangSrcs)
    disableTruckAndKeepEntity(t, rt, gangSrcs)
end

-- gangSrcs is precomputed once per tick by monitor() — avoids rescanning
-- Bridge.GetPlayers() here on top of the scan monitor() already did.
local function pollTrucks(rt, gangSrcs, tick)
    -- Runs even during the releaseHeld staging buffer/grace period (unlike
    -- everything below) — SetEntityMaxHealth/SetEntityHealth in spawnTruck
    -- run the instant the vehicle is created, before OneSync has necessarily
    -- handed a real client ownership of it, and a value set with nobody
    -- owning the entity yet doesn't reliably stick. Same field-confirmed bug
    -- already fixed for Hot Cargo trucks (see HC.tick's hcHealthSeen/
    -- hcSyncedAt) — the vehicle silently reverts to its model's native
    -- default health the moment a client actually takes ownership, which for
    -- a custom LOW configured health (e.g. an admin testing "Body Health:
    -- 100") reads as "shooting it barely does anything," since the real
    -- health is actually whatever the model's default is, not the tiny value
    -- that was configured. Re-asserted once, the first time a real owner is
    -- confirmed — bounded to the first 20s after spawn (not gated behind
    -- releaseHeld ending, which can itself run well past 20s on a long
    -- police-head-start buffer) so it can never clobber genuine damage a
    -- gang got in early by camping a truck during that same buffer.
    for _, t in pairs(rt.trucks) do
        if t.entity and DoesEntityExist(t.entity) and not t.healthSynced then
            if os.time() - (t.spawnedAt or os.time()) > 20 then
                t.healthSynced = true -- window's closed — stop checking, whatever it reads now is real
            elseif NetworkGetEntityOwner(t.entity) ~= -1 then
                t.healthSynced = true
                pcall(SetEntityMaxHealth, t.entity, t.maxHealth or 1000)
                pcall(SetEntityHealth, t.entity, t.maxHealth or 1000)
            end
        end
    end

    -- Grace period: Never flag truck destroyed or overturned during pre-start buffer or first few seconds!
    if rt.releaseHeld or (tick and tick <= 3) then return end

    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled then
            if t.entity and DoesEntityExist(t.entity) then
                local okC, coords = pcall(GetEntityCoords, t.entity)
                if okC and coords then
                    t.lastCoords = coords
                    local okHead, head = pcall(GetEntityHeading, t.entity)
                    if okHead and head then t.lastHeading = head end
                end
            end

            if not t.entity or not DoesEntityExist(t.entity) then
                -- Only declare disabled if it was confirmed in the world previously (prevents spawn false-positives)
                if t.lastCoords then
                    disableTruckAndKeepEntity(t, rt, gangSrcs)
                    local truckLabel = TRUCK_ROLE_LABELS[t.role] or ('Cargo Truck #' .. tostring(t.columnIndex or 1))
                    local b = resolveBanner('truckDisabledLootable', 'CONVOY — TRUCK DISABLED', '%s has broken down and is no longer moving. Participating gangs can attempt to loot the truck.', 8000, 'danger', truckLabel)
                    if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
                    DiscordLog.appendEvent(rt.id, ('🛠️ [TRUCK DISABLED] %s has broken down and is available to loot.'):format(truckLabel))
                end
            else
                ensureTruckDriver(t)
                enforceDriverSeat(t, rt)

                local okH, health = pcall(GetEntityHealth, t.entity)
                local okE, engineHealth = pcall(GetVehicleEngineHealth, t.entity)
                local okM, maxHealth = pcall(GetEntityMaxHealth, t.entity)

                -- Only assess damage if health is a valid numeric value from the engine
                if okH and health and type(health) == 'number' then
                    maxHealth = (okM and maxHealth and maxHealth > 0) and maxHealth or 1000
                    local pct = health / math.max(maxHealth, 1)

                    -- Check if vehicle is overturned or turned upside down (> 60 deg roll or pitch)
                    local roll = 0.0
                    local pitch = 0.0
                    if GetEntityRotation then
                        local ok, rot = pcall(GetEntityRotation, t.entity)
                        if ok and rot then
                            pitch = math.abs(rot.x or 0.0)
                            roll = math.abs(rot.y or 0.0)
                        end
                    end
                    if (roll > 60.0 or pitch > 60.0) and not rt.releaseHeld then
                        t.overturnedTicks = (t.overturnedTicks or 0) + 1
                    else
                        t.overturnedTicks = 0
                    end

                    local isEngineDead = okE and engineHealth and type(engineHealth) == 'number' and engineHealth <= 0
                    local isBodyDead = health <= 0
                    local isFlipped = (t.overturnedTicks and t.overturnedTicks >= 5)

                    local newState = t.state
                    if isBodyDead or isEngineDead or isFlipped then
                        newState = 'DISABLED'
                    elseif pct <= 0.25 then
                        newState = 'CRITICAL'
                    elseif pct <= 0.7 then
                        newState = 'DAMAGED'
                    else
                        newState = 'HEALTHY'
                    end

                    if newState ~= t.state then
                        t.state = newState
                        if newState == 'DISABLED' then
                            disableTruckAndKeepEntity(t, rt, gangSrcs)
                            local truckLabel = TRUCK_ROLE_LABELS[t.role] or ('Cargo Truck #' .. tostring(t.columnIndex or 1))
                            local b = resolveBanner('truckDisabledLootable', 'CONVOY — TRUCK DISABLED', '%s has broken down and is no longer moving. Participating gangs can attempt to loot the truck.', 8000, 'danger', truckLabel)
                            if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
                            DiscordLog.appendEvent(rt.id, ('🛠️ [TRUCK DISABLED] %s has broken down and is available to loot.'):format(truckLabel))
                        elseif newState == 'CRITICAL' then
                            local b = resolveBanner('truckStatusUpdate', 'Convoy Update', 'A convoy truck is %s.', 5000, 'warn', newState:lower())
                            if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
                            local driverSrc = findDrivingPlayerSource(t.entity)
                            if driverSrc then
                                local vb = resolveBanner('vehicleCritical', 'VEHICLE CRITICAL', 'Your truck is about to explode — bail out now!', 6000, 'danger')
                                if vb then notify({ driverSrc }, 'nova_convoytruck:runtime:announce', vb.title, vb.body, vb.duration, vb.kind) end
                            end
                        end
                    end
                end

                -- capture: disabled/no driver + a joined gang participant nearby
                if newState == 'DISABLED' and rt.def.settings.gangPvp and t.entity and DoesEntityExist(t.entity) then
                    local okCoords, coords = pcall(GetEntityCoords, t.entity)
                    local nearby = false
                    local capturerSrc = nil
                    if okCoords and coords then
                        for _, src in ipairs(gangSrcs) do
                            local ped = GetPlayerPed(src --[[@as string]])
                            if ped and ped ~= 0 and DoesEntityExist(ped) then
                                local okPedCoords, pc = pcall(GetEntityCoords, ped)
                                if okPedCoords and pc and #(pc - coords) <= CAPTURE_RADIUS then
                                    nearby = true
                                    capturerSrc = src
                                    break
                                end
                            end
                        end
                    end
                    if nearby then
                        t.captureProgress = (t.captureProgress or 0) + 1
                        if t.captureProgress >= CAPTURE_SECONDS then
                            t.captured = true
                            local capturerName = capturerSrc and Bridge.GetPlayerName(capturerSrc) or 'Unknown'
                            local capturerIdentifier = capturerSrc and Bridge.GetIdentifier(capturerSrc) or 'N/A'
                            local isPolice = capturerSrc and Bridge.IsPolice(capturerSrc) or false
                            local jobGrade = capturerSrc and Bridge.GetJobGrade(capturerSrc) or nil
                            local jobName = jobGrade and jobGrade.name or (isPolice and 'police' or 'civilian')
                            local gangName = capturerIdentifier and rt.participants.identifiers[capturerIdentifier]
                            local identity = gangName and gangIdentity(rt, gangName)
                            t.capturedBy = {
                                source = capturerSrc,
                                name = capturerName,
                                identifier = capturerIdentifier,
                                gang = gangName,
                                gangLabel = identity and identity.label or gangName or (isPolice and 'Police Department' or 'Gang'),
                                isPolice = isPolice,
                                job = jobName,
                                jobGrade = jobGrade and jobGrade.grade or 0,
                                timestamp = os.time(),
                                timeStr = os.date('!%H:%M:%S', os.time()),
                            }
                            rt.captures = rt.captures or {}
                            rt.gangCaptureCounts = rt.gangCaptureCounts or {}
                            if gangName then
                                rt.gangCaptureCounts[gangName] = (rt.gangCaptureCounts[gangName] or 0) + 1
                            end
                            rt.captures[#rt.captures + 1] = {
                                type = 'TRUCK',
                                truckId = t.id,
                                truckRole = t.role,
                                truckLabel = TRUCK_ROLE_LABELS[t.role] or t.id,
                                capturer = t.capturedBy,
                                timestamp = os.time(),
                            }
                            makeTruckLootable(rt, t, gangSrcs)
                            local b = resolveBanner('truckLost', 'Convoy Truck Lost', 'A convoy truck has been intercepted by %s and is lost. Police: leave it and continue escorting the rest of the convoy.', 8000, 'danger', identity and identity.label or gangName or 'a gang')
                            if b then announceAll(rt, b.title, b.body, b.duration, b.kind, identity) end
                            DiscordLog.appendEvent(rt.id, ('🏴 Truck captured: %s by %s (%s) [%s]'):format(
                                TRUCK_ROLE_LABELS[t.role] or t.id,
                                capturerName,
                                capturerIdentifier,
                                identity and identity.label or gangName or 'Gang'
                            ))
                        end
                    else
                        t.captureProgress = 0
                    end
                end
            end
        end
    end

    local activeCargo, totalCargo = activeCargoTrucks(rt)
    if totalCargo > 0 and #activeCargo == 0 and rt.status ~= 'DELIVERY' and rt.status ~= 'COMPLETED' and not rt.cargoLost then
        rt.cargoLost = true
        local policy = rt.def.settings.failurePolicy or 'FAIL'
        if policy == 'CONTINUE' then
            local b = resolveBanner('allCargoLost', 'Convoy Update', 'All cargo trucks have been lost, but the escort presses on to the destination.', 6000, 'warn')
            if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
        else
            -- Option 1: End the event immediately as Failed
            local b = resolveBanner('convoyFailed', 'Convoy Failed', 'All cargo trucks have been destroyed or captured. Police have failed to deliver the shipment.', 8000, 'danger')
            if b then announceServerWide(rt, b.title, b.body, b.duration, b.kind) end
            Runtime.finish(rt.id, 'FAILED')
        end
    end
end

-- ── checkpoint / point handling ───────────────────────────────────────────────────

local function nearestSpawnPoint(route, coords, wantType)
    local best, bestDist = nil, 150.0
    for _, p in ipairs(route) do
        if p.type == wantType then
            local d = #(vec(p) - coords)
            if d < bestDist then best, bestDist = p, d end
        end
    end
    return best
end

-- Purely cosmetic — a ring of static, frozen barrier props around the
-- checkpoint's own hold radius, giving police something physical to
-- actually take cover behind instead of just an invisible circle on the
-- minimap. Server-created networked objects (same CreateObject pattern as
-- replaceDestroyedTruckWithProp above), not a client-rendered coord blip
-- like addNpcBlip — these need to be physically solid/visible up close, not
-- spotted from across the map. Returns the list of spawned entity handles
-- for the caller to tear down once the checkpoint clears/ends.
-- Barricade props are created here with a server-authoritative Z (the route
-- point's saved height, or a per-prop manual Z from the tablet) and no
-- ground alignment at all — server-side collision usually isn't loaded at
-- an arbitrary map location, so there's no reliable way to raycast the true
-- ground height from here. That's why they'd float/sink: point.z is "close
-- enough" for the checkpoint marker itself, but the ring-perimeter props sit
-- at different X/Y (offset by ringRadius) where the terrain height is often
-- different, and even manually-placed ones drift slightly. Ground-snapping
-- is instead done client-side once nearby (see the netId broadcast right
-- before this function returns), the same way trucks get SetVehicleOnGroundProperly
-- via snapTruckToGround since server-side collision can't be trusted here.
local function broadcastBarricadeGroundSnap(objects)
    if #objects == 0 then return end
    local netIds = {}
    for _, obj in ipairs(objects) do
        if DoesEntityExist(obj) then netIds[#netIds + 1] = NetworkGetNetworkIdFromEntity(obj) end
    end
    if #netIds > 0 then
        TriggerClientEvent('nova_convoytruck:runtime:snapBarricadesToGround', -1, netIds)
    end
end

-- Automatic/random barricade placement removed per request (the ring-of-
-- props-around-the-checkpoint-radius mode) — manual placement (admin
-- pre-positions each prop in the tablet, via the in-game placer or "Drop at
-- My Position") is kept, since that's the one actually wanted.
-- Marks every guard ped and guard vehicle an event spawns with the event id. The lists NpcManager hands back are what the end-of-event
-- cleanup deletes, but a list can be lost (two threads building the same checkpoint, a spawn still running when the event is
-- force-ended); the world sweep at the end of an event (purgeRuntimeEntities) deletes anything wearing the tag, found or not.
local function tagSpawned(rt, list)
    if not list or not EventProps or not EventProps.tag then return list end
    for _, e in ipairs(list) do
        if e.ped then EventProps.tag({ e.ped }, rt.id) end
        if e.vehicle then EventProps.tag({ e.vehicle }, rt.id) end
    end
    return list
end

-- Everything the Prop Placer saved for a checkpoint, split into props and vehicles. An entry of decorVehicles is a
-- vehicle; an entry of barricadeProps is one too when it says so (kind) or is a known vehicle model - a misfiled
-- police car would otherwise be built as an object and silently never appear.
local function checkpointObjectLists(cp)
    local props, vehicles = {}, {}
    for _, p in ipairs(cp.barricadeProps or {}) do
        if type(p) == 'table' then
            if p.kind == 'vehicle' or (EventProps and EventProps.isVehicleModel and EventProps.isVehicleModel(p.model)) then
                vehicles[#vehicles + 1] = p
            else
                props[#props + 1] = p
            end
        end
    end
    for _, v in ipairs(cp.decorVehicles or {}) do
        if type(v) == 'table' then vehicles[#vehicles + 1] = v end
    end
    -- the same car stored twice (same model, within half a metre) is ONE car
    local unique = {}
    for _, v in ipairs(vehicles) do
        local dup = false
        for _, u in ipairs(unique) do
            if tostring(u.model) == tostring(v.model)
                and math.abs((tonumber(u.x) or 0.0) - (tonumber(v.x) or 0.0)) < 0.5
                and math.abs((tonumber(u.y) or 0.0) - (tonumber(v.y) or 0.0)) < 0.5
                and math.abs((tonumber(u.z) or 0.0) - (tonumber(v.z) or 0.0)) < 1.0 then
                dup = true
                break
            end
        end
        if not dup then unique[#unique + 1] = v end
    end
    return props, unique
end

-- The old per-checkpoint "Spawn barricades" / "Spawn decoration vehicles" switches are gone: whatever the Prop
-- Placer stored for the checkpoint is spawned (a legacy `false` in an old save no longer hides placed objects).
local function spawnCheckpointBarricades(point, cp)
    local cfg = Config.CheckpointBarricades or {}
    if cfg.enabled == false then return {} end
    local propList = checkpointObjectLists(cp)
    if #propList == 0 then return {} end

    local objects = {}
    local function createProp(m, px, py, pz, pHeading, prx, pry)
        local obj = nil
        local ok, res = pcall(function()
            if CreateObjectNoOffset then
                return CreateObjectNoOffset(m, px + 0.0, py + 0.0, pz + 0.0, true, true, false)
            else
                return CreateObject(m, px + 0.0, py + 0.0, pz + 0.0, true, true, false)
            end
        end)
        if ok and res and res ~= 0 and DoesEntityExist(res) then
            obj = res
        else
            local ok2, res2 = pcall(CreateObject, m, px + 0.0, py + 0.0, pz + 0.0, true, true, false)
            if ok2 and res2 and res2 ~= 0 and DoesEntityExist(res2) then obj = res2 end
        end
        if obj and DoesEntityExist(obj) then
            -- a prop tilted with the shared Prop Placer carries pitch / roll as well as heading
            if (prx or 0.0) ~= 0.0 or (pry or 0.0) ~= 0.0 then
                pcall(SetEntityRotation, obj, (prx or 0.0) + 0.0, (pry or 0.0) + 0.0, (pHeading or 0.0) + 0.0, 2, true)
            else
                SetEntityHeading(obj, (pHeading or 0.0) + 0.0)
            end
            FreezeEntityPosition(obj, true)
            return obj
        end
        return nil
    end

    -- Manual placement: spawn each prop precisely where placed by admin in tablet
    local snapObjects = {}
    for _, p in ipairs(propList) do
        local model = joaat(p.model or cfg.defaultModel or 'prop_barrier_work05')
        local obj = createProp(model, tonumber(p.x) or point.x, tonumber(p.y) or point.y, tonumber(p.z) or point.z, tonumber(p.heading) or 0.0, tonumber(p.rx), tonumber(p.ry))
        if obj then
            objects[#objects + 1] = obj
            -- tagged for every prop (1 = solid, 0 = not): clients switch collision off for 0, and the Prop Placer
            -- hides tagged props while it edits the same layout
            Entity(obj).state:set('nova_prop_solid', p.collision == false and 0 or 1, true)
            -- a prop saved by the shared Prop Placer sits exactly where it was placed (it may be up on another
            -- object, or tilted); only a hand-entered one is settled onto the terrain
            if p.exact ~= true then snapObjects[#snapObjects + 1] = obj end
        end
    end
    if #snapObjects > 0 then
        broadcastBarricadeGroundSnap(snapObjects)
    end
    return objects
end

-- Checkpoint decor vehicles (police/army cars manually placed in the tablet's
-- interactive vehicle placer, see route_editor.lua) — spawned the same
-- manual-placement way as the barricades above, just as real vehicles
-- instead of static props. Locked/frozen/invincible so nobody can actually
-- take one: this is set dressing for the checkpoint, not a usable vehicle.
local function spawnCheckpointVehicles(point, cp)
    local _, vehicleList = checkpointObjectLists(cp)
    if #vehicleList == 0 then return {} end

    local vehicles = {}
    for _, v in ipairs(vehicleList) do
        local model = joaat(v.model or 'police')
        local px = tonumber(v.x) or point.x
        local py = tonumber(v.y) or point.y
        local pz = tonumber(v.z) or point.z
        local pHeading = tonumber(v.heading) or 0.0
        local ok, veh = pcall(CreateVehicle, model, px + 0.0, py + 0.0, pz + 0.0, pHeading + 0.0, true, false)
        -- A server-created vehicle only "exists" a moment after the native returns. Checking right away dropped the handle of a car
        -- that WAS created ("cars placed 1 -> spawned 0" in the log): it stood in the world, untracked and untagged, and nothing
        -- at the end of the event could find it to delete it.
        if ok and veh and veh ~= 0 then
            local deadline = GetGameTimer() + 3000
            while not DoesEntityExist(veh) and GetGameTimer() < deadline do Wait(25) end
        end
        if ok and veh and veh ~= 0 and DoesEntityExist(veh) then
            if (tonumber(v.rx) or 0.0) ~= 0.0 or (tonumber(v.ry) or 0.0) ~= 0.0 then
                pcall(SetEntityRotation, veh, (tonumber(v.rx) or 0.0) + 0.0, (tonumber(v.ry) or 0.0) + 0.0, pHeading + 0.0, 2, true)
            end
            -- Registered FIRST: whatever happens to the natives below, the car is tracked and gets deleted when the event ends.
            vehicles[#vehicles + 1] = veh
            Entity(veh).state:set('nova_prop_solid', 1, true)   -- tag: the Prop Placer hides these while it edits the same layout
            -- Several of these natives are client-only on a server build (SetVehicleEngineOn does not exist here): a missing one threw,
            -- aborted the whole checkpoint set-up and was retried every tick, spawning another car each time. Each is optional.
            pcall(SetVehicleDoorsLocked, veh, 10) -- CANNOT_ENTER — nobody can get in, not just a smash-and-hotwire lock
            if SetVehicleEngineOn then pcall(SetVehicleEngineOn, veh, false, true, true) end
            if SetVehicleUndriveable then pcall(SetVehicleUndriveable, veh, true) end
            pcall(FreezeEntityPosition, veh, true)
            pcall(SetEntityInvincible, veh, true)
            -- Same ground-snap event trucks themselves use (server-side collision
            -- can't be trusted at an arbitrary map location — see
            -- broadcastBarricadeGroundSnap's own comment above for why).
            local netId = NetworkGetNetworkIdFromEntity(veh)
            if netId and v.exact ~= true then   -- a placer-saved vehicle already sits exactly where it was placed
                TriggerClientEvent('nova_convoytruck:runtime:snapTruckToGround', -1, netId)
            end
        end
    end
    return vehicles
end

-- Trucks are NEVER teleported at a checkpoint any more. Each one drives to the
-- marker on its own route, stops where it stops inside the zone and is frozen
-- right there (see parkIfArrived in runCheckpoint). The old "regroup" step
-- snapped every truck into side-by-side slots around the marker, facing the
-- straight line to the next point instead of the road — off-road, sideways, and
-- on release the AI had to multi-point-turn out of it (spinning, shuffling
-- sideways, reversing). Released from exactly where it stopped, a truck is
-- already pointing along the road and just drives on.
--
-- Releases every truck parked at the checkpoint ONE AT A TIME (column order),
-- each straight onto its own route — not all at the same instant, which made
-- the cluster pull out into each other. Trucks still on their way to the
-- checkpoint are untouched: they keep following their own route.
local function releaseFromCheckpoint(rt)
    local stagger = tonumber((Config.CheckpointRelease or {}).staggerSeconds) or 1.0
    local released = 0
    for _, t in ipairs(columnOrder(rt)) do
        if not active[rt.id] then return end
        if t.checkpointParked then
            if released > 0 and stagger > 0 then Wait(math.floor(stagger * 1000)) end
            if not active[rt.id] then return end
            released = released + 1
            t.checkpointParked = nil
            t.cpBraking = nil
            t.lastDriveTaskTime = nil
            t.drivingToIndex = nil
            t.routeIdx = rt.currentRouteIndex
            if t.entity and DoesEntityExist(t.entity) then
                FreezeEntityPosition(t.entity, false)
                Entity(t.entity).state:set('cp_hold_brake', nil, true)
                driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), nil, true, t)
            end
        end
    end
    -- a truck that was disabled/captured while parked just gets unfrozen
    for _, t in pairs(rt.trucks) do
        -- a "braking for this checkpoint" flag left on a truck that never parked would stop parkIfArrived from
        -- braking it at the NEXT checkpoint at all
        t.cpBraking = nil
        if t.entity and DoesEntityExist(t.entity) and Entity(t.entity).state.cp_hold_brake then
            Entity(t.entity).state:set('cp_hold_brake', nil, true)
        end
        if t.checkpointParked then
            t.checkpointParked = nil
            t.cpBraking = nil
            t.routeIdx = rt.currentRouteIndex
            if t.entity and DoesEntityExist(t.entity) and not t.disabled and t.state ~= 'DISABLED' then
                FreezeEntityPosition(t.entity, false)
            end
        end
    end
end

-- Checkpoint dressing (barricades, decor vehicles, NPC police/army guards +
-- their blips) used to spawn from inside runCheckpoint itself, i.e. only the
-- instant the convoy actually arrived — which meant every checkpoint's set
-- dressing visibly popped into existence right as the trucks rolled up.
-- Pulled out into its own idempotent function so the lookahead pre-spawn in
-- monitor() (see CHECKPOINT_PRESPAWN_LOOKAHEAD below) can spawn it a couple
-- of route points early instead, and runCheckpoint just reuses whatever's
-- already there (or spawns it itself, same as before, if the convoy somehow
-- reaches a checkpoint the lookahead never got to — e.g. very first
-- checkpoint right after a short START-to-CHECKPOINT gap).
-- The dressing of the START and DESTINATION points (def.pointSupport): the same fields a checkpoint carries (placed props / vehicles,
-- NPC police / army guards), nothing when the admin set none. They are never timed or held like a checkpoint.
local function pointSupportFor(def, routePointId)
    for _, ps in ipairs((def and def.pointSupport) or {}) do
        if tostring(ps.routePointId) == tostring(routePointId) then return ps end
    end
    return { npcPolice = { enabled = false, count = 4 }, army = { enabled = false, count = 4 }, gangAttackEnabled = false, barricadeProps = {}, decorVehicles = {} }
end

local function buildCheckpointDressing(rt, point)
    rt.checkpointDressing = rt.checkpointDressing or {}
    local existing = rt.checkpointDressing[point.id]
    if existing then return existing end

    local cp = (point.type == 'START' or point.type == 'DESTINATION') and pointSupportFor(rt.def, point.id) or checkpointConfigFor(rt.def, point.id)

    -- With no NPC zone and no NPC_SPAWN point configured, guards used to form up ON the checkpoint marker — the very
    -- lane the trucks stop in. The trucks' driving style stops for peds (flag 2) and steers around them, so the column
    -- halted short of the marker or weaved through the guards (they are pre-spawned 2 points early, so they are
    -- already standing there as the convoy arrives). Fallback now: the roadside, 14 m to the right of the direction of
    -- travel (previous route point → checkpoint), facing the road. An admin-chosen zone / NPC_SPAWN point is untouched.
    local function roadsideOf(p)
        local prev
        for i, rp in ipairs(rt.route) do
            if rp == p or tostring(rp.id) == tostring(p.id) then prev = rt.route[i - 1] break end
        end
        local dx, dy = 0.0, 1.0
        if prev and prev.x and prev.y then
            local ddx, ddy = p.x - prev.x, p.y - prev.y
            local len = math.sqrt(ddx * ddx + ddy * ddy)
            if len > 1.0 then dx, dy = ddx / len, ddy / len end
        end
        local side = 14.0
        local sx, sy = p.x + dy * side, p.y - dx * side          -- right-hand perpendicular of the travel direction
        local fx, fy = p.x - sx, p.y - sy                        -- face back toward the road
        local heading = math.deg(math.atan(-fx, fy)) % 360      -- GTA heading convention (see nudgeUnobservedTrucks)
        return { x = sx, y = sy, z = p.z, heading = heading }
    end

    local function resolveSpawn(zoneId)
        if zoneId then
            local zone = NpcManager.getZone(zoneId)
            if zone then return NpcManager.randomPointInZone(zone) end
        end
        return nearestSpawnPoint(rt.route, vec(point), 'NPC_SPAWN') or roadsideOf(point)
    end

    local spawnedNpcs = {}
    local barricades = spawnCheckpointBarricades(point, cp)
    local vehicles = spawnCheckpointVehicles(point, cp)
    local cpBlipIds = {}
    -- "Shoot non-police here" is tied to the circle: the guards stand neutral and the client that controls them turns them hostile
    -- while a non-police player is INSIDE the zone (cp_zone, see npc_relationships.lua), then back to neutral once it has left.
    local zoneRadius = tonumber(cp.radius) or tonumber(point.radius) or 40.0
    local passive = true
    local function gateToZone(list)
        if not cp.gangAttackEnabled then return list end
        for _, e in ipairs(list or {}) do
            if e.ped and DoesEntityExist(e.ped) then
                pcall(function() Entity(e.ped).state:set('cp_zone', { x = point.x + 0.0, y = point.y + 0.0, r = zoneRadius + 0.0 }, true) end)
            end
        end
        return list
    end

    if cp.npcPolice and cp.npcPolice.enabled then
        local spawn = resolveSpawn(cp.npcPolice.zoneId)
        local baseCfg = rt.def.settings and rt.def.settings.npcPoliceConfig or {}
        -- A vehicle only when the checkpoint asks for one ('Arrive in a vehicle'). It used to spawn whenever the event's
        -- settings carried a default model (always 'police3'), so every checkpoint with guards got a police car nobody placed.
        local policeWantsVehicle = cp.npcPolice.spawnVehicle == true
        local policeVehicle = policeWantsVehicle and (cp.npcPolice.vehicleModel or baseCfg.vehicleModel or 'police3') or nil
        local policeCfg = {
            model = cp.npcPolice.model or baseCfg.model or 's_m_y_cop_01',
            weapon = cp.npcPolice.weapon or baseCfg.weapon or 'WEAPON_CARBINERIFLE',
            aggressiveness = cp.npcPolice.aggressiveness or baseCfg.aggressiveness or 'medium',
            behavior = cp.npcPolice.behavior or baseCfg.behavior or 'GUARD_CHECKPOINT',
            vehicleModel = policeVehicle,
            spawnVehicle = policeWantsVehicle and policeVehicle ~= nil and policeVehicle ~= '',
        }
        local list = gateToZone(tagSpawned(rt, NpcManager.spawnCheckpointSupport('police', policeCfg, spawn, cp.npcPolice.count, passive)))
        for _, e in ipairs(list) do spawnedNpcs[#spawnedNpcs + 1] = e end
        local id = rt.id .. ':cp:' .. point.id .. ':police'
        cpBlipIds[#cpBlipIds + 1] = id
        addNpcBlip(rt, id, spawn, 'police', 'NPC Police Support')
    end
    if cp.army and cp.army.enabled then
        local spawn = resolveSpawn(cp.army.zoneId)
        local baseCfg = rt.def.settings and rt.def.settings.armyConfig or {}
        -- same rule as the police squad above: no vehicle unless the checkpoint asks for one (it used to be a Barracks truck)
        local armyWantsVehicle = cp.army.spawnVehicle == true
        local armyVehicle = armyWantsVehicle and (cp.army.vehicleModel or baseCfg.vehicleModel or 'crusader') or nil
        local armyCfg = {
            model = cp.army.model or baseCfg.model or 's_m_y_marine_03',
            weapon = cp.army.weapon or baseCfg.weapon or 'WEAPON_CARBINERIFLE',
            aggressiveness = cp.army.aggressiveness or baseCfg.aggressiveness or 'high',
            behavior = cp.army.behavior or baseCfg.behavior or 'GUARD_CHECKPOINT',
            vehicleModel = armyVehicle,
            spawnVehicle = armyWantsVehicle and armyVehicle ~= nil and armyVehicle ~= '',
        }
        local list = gateToZone(tagSpawned(rt, NpcManager.spawnCheckpointSupport('army', armyCfg, spawn, cp.army.count, passive)))
        for _, e in ipairs(list) do spawnedNpcs[#spawnedNpcs + 1] = e end
        local id = rt.id .. ':cp:' .. point.id .. ':army'
        cpBlipIds[#cpBlipIds + 1] = id
        addNpcBlip(rt, id, spawn, 'army', 'NPC Army Support')
    end

    do
        local props, cars = checkpointObjectLists(cp)
        print(('[NovaConvoy] #%s checkpoint %s dressing: settings=%s | props placed %d -> spawned %d | cars placed %d -> spawned %d | police=%s army=%s'):format(
            tostring(rt.id), tostring(point.id), cp.routePointId ~= nil and 'matched' or 'NOT FOUND (defaults)',
            #props, #barricades, #cars, #vehicles,
            tostring(cp.npcPolice and cp.npcPolice.enabled), tostring(cp.army and cp.army.enabled)))
    end
    -- tag every prop / decoration vehicle with the event id, so the end-of-event sweep finds them even if a handle went stale
    if EventProps and EventProps.tag then
        EventProps.tag(barricades, rt.id)
        EventProps.tag(vehicles, rt.id)
    end
    local dressing = { cp = cp, npcs = spawnedNpcs, barricades = barricades, vehicles = vehicles, blipIds = cpBlipIds }
    -- rt.checkpointDressing is nil once Runtime.finish has swept the convoy (ensureCheckpointDressing tears
    -- this set down in that case) — never index it blindly or the freshly spawned guards are orphaned.
    if rt.checkpointDressing then rt.checkpointDressing[point.id] = dressing end
    return dressing
end

-- ONE spawn per checkpoint, however many threads ask. Spawning the guards waits between peds, so the build above takes
-- seconds - and the lookahead pre-spawn in monitor() and runCheckpoint (a second thread, when the trucks roll up) can both
-- ask for the same checkpoint inside that time. The second caller used to find nothing registered yet and built the whole
-- set AGAIN (a second police car on the spot, a second set of props and guards), then overwrote the first set's record so
-- it was never cleaned up. Now the second caller waits for the first build and reuses its result.
local function ensureCheckpointDressing(rt, point)
    rt.checkpointDressing = rt.checkpointDressing or {}
    local existing = rt.checkpointDressing[point.id]
    if existing then return existing end
    rt.checkpointDressingBusy = rt.checkpointDressingBusy or {}
    if rt.checkpointDressingBusy[point.id] then
        local waited = 0
        while rt.checkpointDressingBusy[point.id] and waited < 60000 do
            Wait(100)
            waited = waited + 100
        end
        return rt.checkpointDressing[point.id] or buildCheckpointDressing(rt, point)
    end
    rt.checkpointDressingBusy[point.id] = true
    local ok, res = pcall(buildCheckpointDressing, rt, point)
    rt.checkpointDressingBusy[point.id] = nil
    if not ok then error(res, 0) end
    -- Built while the event was ending: Runtime.finish already swept this convoy, so tear the
    -- fresh props/NPCs down here instead of leaving them standing in the world.
    if type(res) == 'table' and not active[rt.id] then
        pcall(NpcManager.cleanup, res.npcs)
        for _, obj in ipairs(res.barricades or {}) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
        for _, veh in ipairs(res.vehicles or {}) do if DoesEntityExist(veh) then DeleteEntity(veh) end end
        for _, id in ipairs(res.blipIds or {}) do pcall(removeNpcBlip, rt, id) end
        if rt.checkpointDressing then rt.checkpointDressing[point.id] = nil end
    end
    return res
end

-- How many route points ahead of the convoy's current position a checkpoint's
-- dressing gets pre-spawned (see the lookahead check in monitor()) — early
-- enough that it's already sitting there by the time trucks arrive instead of
-- visibly popping in, but not so early (e.g. the whole route at once) that a
-- long convoy route means every checkpoint's NPCs/vehicles all exist
-- simultaneously for the entire event.
local CHECKPOINT_PRESPAWN_LOOKAHEAD = 2

local function runCheckpoint(rt, point)
    local dressing = ensureCheckpointDressing(rt, point)
    local cp = dressing.cp

    local spawnedNpcs = dressing.npcs
    rt.activeCheckpointNpcs = spawnedNpcs
    local barricades = dressing.barricades
    rt.activeCheckpointBarricades = barricades
    local vehicles = dressing.vehicles
    rt.activeCheckpointVehicles = vehicles
    local cpBlipIds = dressing.blipIds

    -- ── Wait for ALL trucks to enter the checkpoint zone and stop ──────────────
    local function getActiveCargoTrucks()
        local list = {}
        local hasExplicitCargo = false
        for _, t in pairs(rt.trucks) do
            if (t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO') then
                hasExplicitCargo = true
                if not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED'
                    and t.entity and DoesEntityExist(t.entity) then
                    list[#list + 1] = t
                end
            end
        end
        if not hasExplicitCargo then
            for _, t in pairs(rt.trucks) do
                if t.role ~= 'ESCORT' and not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED'
                    and t.entity and DoesEntityExist(t.entity) then
                    list[#list + 1] = t
                end
            end
        end
        table.sort(list, function(a, b) return (a.columnIndex or 1) < (b.columnIndex or 1) end)
        return list
    end

    local cpRadius = tonumber(cp.radius) or 35.0
    local targetDist = math.max(14.0, math.min(cpRadius - 5.0, 30.0))

    -- Every truck parks itself: it drives to the marker along its OWN route and, once it is on the marker (or
    -- stopped in the queue behind a truck that is), it is held exactly where it stands. Nobody is moved by script
    -- and no truck waits on another to decide where it stops or when it moves on again.
    -- The checkpoint STARTS when the first truck is inside its circle (cp.radius, the yellow zone on the map - see the
    -- reach test in monitor()). From there every truck is slowed and settles onto the marker: it is frozen once it is
    -- within parkRadius of it and has (almost) stopped. Config.CheckpointRelease.parkInCircle = true freezes it at the
    -- circle's edge instead.
    local PARK_ON_MARKER = tonumber((Config.CheckpointRelease or {}).parkRadius) or 15.0
    if (Config.CheckpointRelease or {}).parkInCircle == true then
        PARK_ON_MARKER = math.max(PARK_ON_MARKER, cpRadius)
    end
    local function parkIfArrived(t)
        if t.checkpointParked then return true end
        if not t.entity or not DoesEntityExist(t.entity) then return false end
        local c = GetEntityCoords(t.entity)
        local d = #(vec2(c.x, c.y) - vec2(point.x, point.y))
        local spd = GetEntitySpeed(t.entity)
        -- A truck with a real player at the wheel cannot be braked by script. Inside the circle we hand the slowing to
        -- that player's client ('cp_hold_brake' carries the marker and the settle radius, see runtime_client.lua): it caps
        -- the truck's speed by distance to the marker, so it settles onto it even with the throttle held, and the truck
        -- is frozen here once it is on the marker and nearly stopped.
        local human = findDrivingPlayerSource(t.entity) ~= nil
        local onMarker = d <= PARK_ON_MARKER
        local stopped = spd < 0.8
        -- stopped in the zone behind another truck
        local queued = d <= targetDist and stopped
        -- Long columns: the 3rd+ truck queues 40–60 m back, outside targetDist. It never counted as parked, so the
        -- client's anti-stuck watchdog saw an unfrozen truck standing still and REVERSED it after ~7 s. A truck
        -- stopped nose-to-tail (≤ 30 m) behind one that is already parked here is part of the queue too.
        if not queued and stopped and d <= math.max(cpRadius, targetDist) + 60.0 then
            for _, o in pairs(rt.trucks) do
                if o ~= t and o.checkpointParked and o.entity and DoesEntityExist(o.entity) then
                    if #(GetEntityCoords(o.entity) - c) <= 30.0 then queued = true break end
                end
            end
        end
        -- A truck we already braked for this checkpoint that came to rest a little short of / past the marker parks
        -- where it is. Before, if it stopped outside targetDist it was never parked and nothing re-tasked it forward;
        -- the hold loop's stall check later sent it BACK to the marker — a U-turn in the middle of the checkpoint.
        if not queued and stopped and t.cpBraking and d <= math.max(cpRadius, 40.0) then queued = true end
        if human then
            if d <= math.max(cpRadius, PARK_ON_MARKER) then
                if type(Entity(t.entity).state.cp_hold_brake) ~= 'table' then
                    Entity(t.entity).state:set('cp_hold_brake', { x = point.x + 0.0, y = point.y + 0.0, r = PARK_ON_MARKER + 0.0 }, true)
                end
                if (onMarker or queued) and spd <= 1.5 then
                    FreezeEntityPosition(t.entity, true)
                    t.checkpointParked = true
                    return true
                end
            end
            return false
        end
        if not (onMarker or queued) then return false end
        if not t.cpBraking then
            t.cpBraking = true
            stopTruck(t)   -- drops its drive task and brakes
        end
        if spd <= 1.5 then
            FreezeEntityPosition(t.entity, true)
            t.checkpointParked = true
            t.cpBraking = nil
            return true
        end
        return false
    end

    -- Wait for EVERY cargo truck to roll onto the checkpoint before it triggers. A truck that gets there first is parked
    -- (held) where it stands and waits for the others; a truck still on its way is NOT stopped or moved: it keeps
    -- following its own route and parks itself when it arrives. Destroyed / captured / disabled trucks no longer count.
    -- Only the safety limit below (Config.CheckpointRelease.arrivalWaitSeconds, 0 = none) lets the checkpoint start
    -- without a truck that never turns up.
    local waitStart = os.time()
    local maxWaitSeconds = tonumber((Config.CheckpointRelease or {}).arrivalWaitSeconds) or 600
    if maxWaitSeconds <= 0 then maxWaitSeconds = math.huge end
    local lastWaitNotice = 0
    while active[rt.id] and (os.time() - waitStart < maxWaitSeconds) do
        local pending, total = 0, 0
        for _, t in ipairs(getActiveCargoTrucks()) do
            total = total + 1
            if not parkIfArrived(t) then pending = pending + 1 end
        end
        if pending == 0 then break end
        rt.checkpointWaitingFor = pending
        if total - pending > 0 and os.time() - lastWaitNotice >= 30 then
            lastWaitNotice = os.time()
            local msg = ('%d of %d convoy trucks are on %s. The checkpoint starts when the rest arrive.'):format(total - pending, total, tostring(cp.name or 'the checkpoint'))
            pcall(announcePolice, rt, 'WAITING FOR THE CONVOY', msg, 6000, 'warn')
        end
        driveColumn(rt, point, nil, false)   -- trucks not parked yet continue along their own route
        Wait(700)
    end
    rt.checkpointWaitingFor = nil
    -- ── Announcements and the checkpoint timer start once the convoy is on the marker ──
    local holdDuration = math.max(5, tonumber(cp.holdDuration) or 60)
    if cp.announce then
        local bPolice = resolveBanner('checkpointPoliceArrived', 'CHECKPOINT REACHED', '%s reached. All convoy trucks secured side by side! Start protecting the convoy from incoming hostiles.', 8000, 'checkpoint', cp.name)
        if bPolice then announcePolice(rt, bPolice.title, bPolice.body, bPolice.duration, bPolice.kind) end

        local holdMin = math.floor(holdDuration / 60)
        local holdSec = holdDuration % 60
        local durText = holdMin > 0 and (holdSec > 0 and ('%d min %d sec'):format(holdMin, holdSec) or ('%d minutes'):format(holdMin)) or ('%d seconds'):format(holdSec)
        local bGang = resolveBanner('checkpointGangAlert', 'CONVOY HELD AT CHECKPOINT', 'The convoy has stopped at %s and will hold here for %s. Intercept the trucks now!', 8000, 'danger', cp.name, durText)
        if bGang then announceGang(rt, bGang.title, bGang.body, bGang.duration, bGang.kind) end
    end

    local cpAudience = allParticipantSources(rt)
    rt.checkpointTimeRemaining = holdDuration
    local ptOrder = (tonumber(point.order) or 0) + 1
    notify(cpAudience, 'nova_convoytruck:runtime:checkpointStart', rt.checkpointTimeRemaining, ptOrder, #rt.route, { x = point.x, y = point.y, z = point.z }, cp.radius)

    -- Every stage has to be gone through by the escort: the hold timer only runs while at least one living, on-duty
    -- officer is inside the checkpoint circle. With no officer online at all the convoy runs on its own (as before).
    -- Config.CheckpointRelease.requirePoliceInCircle = false switches the rule off.
    local function escortAtCheckpoint()
        if (Config.CheckpointRelease or {}).requirePoliceInCircle == false then return true end
        local any = false
        for _, src in ipairs(policeParticipantSources(rt)) do
            if Bridge.IsPolice(src) and readVitals(src) then
                any = true
                local ped = GetPlayerPed(src)
                if ped and ped ~= 0 then
                    local pc = GetEntityCoords(ped)
                    if #(vec2(pc.x, pc.y) - vec2(point.x, point.y)) <= math.max(cpRadius, 30.0) then return true end
                end
            end
        end
        return not any
    end

    local holdTick = 0
    local waitingForEscort = false
    while rt.checkpointTimeRemaining > 0 and active[rt.id] do
        Wait(1000)
        if not active[rt.id] then break end
        holdTick = holdTick + 1
        -- latecomers: park each truck as it arrives; any still driving keeps to its own route (re-tasked only if
        -- its task ended — driveColumn skips trucks that are parked or already heading to the right point)
        local stragglers = false
        for _, t in ipairs(getActiveCargoTrucks()) do
            if not parkIfArrived(t) then stragglers = true end
        end
        if stragglers and holdTick % 3 == 0 then driveColumn(rt, point, holdTick) end
        if escortAtCheckpoint() then
            if waitingForEscort then
                waitingForEscort = false
                rt.checkpointWaitingPolice = nil
                notify(cpAudience, 'nova_convoytruck:runtime:checkpointResume', rt.checkpointTimeRemaining)
                pcall(sendConvoyProgress, rt)
            end
            rt.checkpointTimeRemaining = rt.checkpointTimeRemaining - 1
            notify(cpAudience, 'nova_convoytruck:runtime:checkpointUpdate', rt.checkpointTimeRemaining)
            if rt.checkpointTimeRemaining % 5 == 0 then persist(rt) end
        elseif not waitingForEscort then
            waitingForEscort = true
            rt.checkpointWaitingPolice = true
            notify(cpAudience, 'nova_convoytruck:runtime:checkpointPause')
            local nb = resolveBanner('checkpointNeedEscort', 'CHECKPOINT TIMER PAUSED', 'No officer is inside %s. Get into the checkpoint zone — the timer only runs while an escort is there.', 7000, 'warn', cp.name or 'the checkpoint')
            if nb then announcePolice(rt, nb.title, nb.body, nb.duration, nb.kind) end
            pcall(sendConvoyProgress, rt)
        end
    end
    rt.checkpointWaitingPolice = nil

    if not active[rt.id] then
        pcall(NpcManager.cleanup, spawnedNpcs)
        for _, obj in ipairs(barricades) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
        for _, veh in ipairs(vehicles) do if DoesEntityExist(veh) then DeleteEntity(veh) end end
        for _, id in ipairs(cpBlipIds) do removeNpcBlip(rt, id) end
        if rt.checkpointDressing then rt.checkpointDressing[point.id] = nil end   -- nil once the end-of-event sweep has run
        notify(cpAudience, 'nova_convoytruck:runtime:checkpointEnd')
        return
    end

    pcall(NpcManager.cleanup, spawnedNpcs)
    for _, obj in ipairs(barricades) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
    for _, veh in ipairs(vehicles) do if DoesEntityExist(veh) then DeleteEntity(veh) end end
    for _, id in ipairs(cpBlipIds) do removeNpcBlip(rt, id) end
    rt.activeCheckpointNpcs = nil
    rt.activeCheckpointBarricades = nil
    rt.activeCheckpointVehicles = nil
    if rt.checkpointDressing then rt.checkpointDressing[point.id] = nil end
    rt.checkpointDone = rt.checkpointDone or {}
    rt.checkpointDone[point.id] = true   -- the pre-spawn lookahead must never rebuild a checkpoint that has already been played

    -- Trucks stay parked (frozen where they stopped) until handlePointReached releases them one by one with
    -- releaseFromCheckpoint — rt.currentRouteIndex still points at THIS checkpoint here, and releasing with it
    -- would send every truck back to the marker it is standing on.
    if cp.announce then
        pcall(function()
            local b = resolveBanner('checkpointCleared', 'Checkpoint Cleared', '%s survived — police and the convoy truck are proceeding to the next checkpoint.', 6000, 'success', cp.name)
            if b then announcePolice(rt, b.title, b.body, b.duration, b.kind) end
            local gb = resolveBanner('checkpointGangResumed', 'Convoy Moving Again', '%s survived — the convoy is rolling again. Catch it before the next checkpoint!', 6000, 'warn', cp.name)
            if gb then announceGang(rt, gb.title, gb.body, gb.duration, gb.kind) end
        end)
    end
    notify(cpAudience, 'nova_convoytruck:runtime:checkpointEnd')
    pcall(function()
        DiscordLog.appendEvent(rt.id, ('✅ Checkpoint cleared — %s (%d/%d)'):format(cp.name or ('Point %d'):format(ptOrder), ptOrder, #rt.route))
    end)
end

-- Deletes an airdrop's crate prop and cleans up its guard NPCs — shared by
-- a successful loot, natural expiry, the convoy ending, and a resource stop,
-- so none of those paths can forget to tear it down. Also tells clients to
-- stop the red landing-smoke fx (see spawnParachutingCrate) — harmless no-op
-- client-side if none was ever started for this point.
--
-- keepProp (optional): skips deleting the crate prop itself — used only by
-- claimAirdrop below for a SUCCESSFUL loot. A looted crate should stay
-- sitting there, visibly claimed, not vanish the instant it's opened; it
-- still gets deleted like any other crate once the event actually ends or
-- force-ends, since every OTHER call site here (expiry, convoy finish,
-- resource stop) calls this without keepProp.
local function cleanupAirdrop(rt, entry, keepProp)
    if not entry then return end
    if not keepProp and entry.propEntity and DoesEntityExist(entry.propEntity) then DeleteEntity(entry.propEntity) end
    if entry.guards then NpcManager.cleanup(entry.guards) end
    if entry.blipId then removeNpcBlip(rt, entry.blipId) end
    if rt and entry.coords and entry.coords.id then
        local audience
        if rt.def.kind == 'GANG_AIRDROP' then
            audience = gangParticipantSources(rt)
        else
            audience = policeParticipantSources(rt)
            for _, s in ipairs(gangParticipantSources(rt)) do audience[#audience + 1] = s end
        end
        notify(audience, 'nova_convoytruck:runtime:airdropSmokeStop', entry.coords.id)
        -- Every sprite/blip this drop put on the map (zone circle, crate,
        -- guard peds) comes down here — the one shared teardown path every
        -- ending (looted, expired, or the convoy itself force-ending) already
        -- routes through, so "closed by timer" and "closed manually" behave
        -- identically instead of the timer path being a second, easily
        -- forgotten copy of the same cleanup.
        notify(audience, 'nova_convoytruck:runtime:airdropGuardZoneRemove', entry.coords.id)
    end
end

-- The supply plane's flyover: a straight pass over the drop point on a FIXED TIMELINE, so the release is always exactly over the zone.
--
-- The server owns only the clock and the map blip. Every game client near the drop draws its own local, non-networked copy of the
-- plane and places it each frame along the line (see 'airdropPlaneFlight' in runtime_client.lua) — the same way the crate's parachute
-- descent is already drawn. This replaced a plane that one player's game created and flew with a flight task: far from that
-- player the engine freezes / lags a vehicle that has no collision loaded around it, so the plane drifted off its line, never
-- got over the zone, and the crate fell on a timeout with no flyover ("the plane flies somewhere else").
--
-- onOverhead(releasePos): called once, at the moment the plane is directly above dropCoords. releasePos is that exact point in the
-- sky; the crate starts its fall from there. Blocks until the plane has left, so callers run it in its own thread.
-- audience (optional): sources that get the plane's moving map blip.
local airdropPlaneSeq = 0

local function flyAirdropPlane(dropCoords, cfg, audience, onOverhead)
    local heading = math.random(0, 359)
    local rad = math.rad(heading)
    -- GTA heading: 0 = North (+Y), 90 = West (-X)
    local dir = vector3(-math.sin(rad), math.cos(rad), 0.0)
    local flightZ = dropCoords.z + (cfg.flightHeight or 90.0)
    local approach = cfg.approachDistance or 300.0
    local speed = math.max(10.0, cfg.speed or 55.0)
    -- the plane keeps flying for postDropSeconds after letting go of the crate, so the far end of the line is pushed out far enough
    local postDropMs = math.floor((tonumber(cfg.postDropSeconds) or 10) * 1000)
    local endApproach = math.max(approach, speed * (postDropMs / 1000 + 3))
    local startPos = vector3(dropCoords.x - dir.x * approach, dropCoords.y - dir.y * approach, flightZ)
    local endPos = vector3(dropCoords.x + dir.x * endApproach, dropCoords.y + dir.y * endApproach, flightZ)
    local releasePos = vector3(dropCoords.x, dropCoords.y, flightZ)

    local flightMs = math.max(1000, math.floor((#(endPos - startPos) / speed) * 1000))
    local dropMs = math.floor((approach / speed) * 1000)   -- when the plane is over the zone

    airdropPlaneSeq = airdropPlaneSeq + 1
    local planeId = 700000 + airdropPlaneSeq

    -- every client draws the plane for itself if it is within sight of the drop; the ones that are not ignore this
    TriggerClientEvent('nova_convoytruck:runtime:airdropPlaneFlight', -1, {
        id = planeId,
        model = cfg.model or 'dodo',
        pilotModel = (cfg.pilotModel and cfg.pilotModel ~= '') and cfg.pilotModel or 's_m_m_pilot_01',
        startX = startPos.x, startY = startPos.y, startZ = startPos.z,
        endX = endPos.x, endY = endPos.y, endZ = endPos.z,
        dropX = dropCoords.x, dropY = dropCoords.y,
        heading = heading + 0.0,
        flightMs = flightMs,
    })
    print(('[NovaConvoy][Airdrop] flyover: %.0f m pass at %d m/s over %.0f, %.0f - crate released after %.1f s'):format(
        #(endPos - startPos), math.floor(speed), dropCoords.x, dropCoords.y, dropMs / 1000))

    local blipTo = (audience and #audience > 0) and audience or Bridge.GetPlayers()
    if blipTo and #blipTo > 0 then
        notify(blipTo, 'nova_convoytruck:runtime:airdropPlaneSpawn', planeId, cfg.blipSprite or 423, cfg.blipColour or 5, cfg.blipScale or 1.1, cfg.label or 'Supply Plane', heading, startPos.x, startPos.y, startPos.z)
    end

    local t0 = GetGameTimer()
    local released = false
    while true do
        local el = GetGameTimer() - t0
        if el >= flightMs then break end
        if not released and el >= dropMs then
            released = true
            if onOverhead then pcall(onOverhead, releasePos) end
        end
        if blipTo and #blipTo > 0 then
            local pos = startPos + (endPos - startPos) * (el / flightMs)
            notify(blipTo, 'nova_convoytruck:runtime:airdropPlaneMove', planeId, pos.x, pos.y, pos.z, heading)
        end
        Wait(300)
    end
    if not released and onOverhead then pcall(onOverhead, releasePos) end
    if blipTo and #blipTo > 0 then notify(blipTo, 'nova_convoytruck:runtime:airdropPlaneDespawn', planeId) end
end

-- Eases the crate down from high in the sky to the ground at a fixed
-- descent speed, with a parachute prop attached, instead of it just
-- appearing already sitting on the ground — the drop-point half of the
-- flyover above. Blocks (server-side Wait loop) until the crate actually
-- lands, so callers only spawn guards / open the loot target zone once it's
-- reachable — a crate still 100m up makes no sense to lockpick.
-- Asks real clients (nearest first, up to 3) to find the true ground under a
-- server-created prop and moves the prop onto it. The server has no map
-- collision of its own, and a client far from the drop point may not have
-- that ground loaded yet, so a single "nearest player" attempt that quietly
-- answered "ground not found" left every crate after the first one floating
-- at the height the zone was placed at. Each client now loads collision at
-- the spot and reports failure honestly, and the next-nearest is tried.
local function snapPropToGroundViaClients(propEntity, dropCoords, candidates)
    local propNetId = NetworkGetNetworkIdFromEntity(propEntity)
    if not propNetId or propNetId <= 0 then return false end
    local pool = (candidates and #candidates > 0) and candidates or Bridge.GetPlayers()
    local ranked = {}
    for _, src in ipairs(pool or {}) do
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            ranked[#ranked + 1] = { src = src, d = #(GetEntityCoords(ped) - dropCoords) }
        end
    end
    table.sort(ranked, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#ranked, 3) do
        local ok, result = pcall(lib.callback.await, 'nova_convoytruck:runtime:snapPropToGround', ranked[i].src, { netId = propNetId, z = dropCoords.z })
        if ok and type(result) == 'table' and result.ok and tonumber(result.z) then
            SetEntityCoords(propEntity, dropCoords.x, dropCoords.y, tonumber(result.z), false, false, false, false)
            return true
        end
    end
    print(('[NovaConvoy] Airdrop crate at %.1f, %.1f: no client could find the ground — it stays at the configured height.'):format(dropCoords.x, dropCoords.y))
    return false
end

local function spawnParachutingCrate(dropCoords, model, cfg, candidates, releasePos)
    local descendSpeed = math.max(0.5, cfg.descendSpeed or 4.0)
    local height = cfg.parachuteHeight or 120.0
    -- The crate leaves the plane from where the plane actually is when it
    -- releases it, and falls from that height down to the zone.
    local startPos
    if releasePos then
        startPos = { x = releasePos.x, y = releasePos.y, z = releasePos.z }
        height = math.max(30.0, releasePos.z - dropCoords.z)
    else
        startPos = { x = dropCoords.x, y = dropCoords.y, z = dropCoords.z + height }
    end
    local durationMs = math.floor(height / descendSpeed * 1000)

    -- The visible descent is rendered by each nearby client (local crate +
    -- attached cargo chute, moved every frame — see airdropDescent in
    -- runtime_client.lua). Doing it here meant SetEntityCoords on a
    -- networked crate every 100ms (visibly stepping as each update landed)
    -- and a server-side AttachEntityToEntity for the chute, which isn't a
    -- server native: the pcall swallowed the error and the parachute just
    -- hung in the sky at its spawn height while the crate fell beneath it.
    local crateName = (Config.Airdrop and Config.Airdrop.prop) or 'xm_prop_x17_case_01'
    print(('[NovaConvoy][Airdrop] crate falling from %.0f m onto %.0f, %.0f (%d s)'):format(height, dropCoords.x, dropCoords.y, math.floor(durationMs / 1000)))
    TriggerClientEvent('nova_convoytruck:runtime:airdropDescent', -1,
        { x = dropCoords.x, y = dropCoords.y, z = dropCoords.z },
        crateName, cfg.parachuteProp, height, durationMs, startPos)
    Wait(durationMs)

    -- The real, networked, lootable crate — only once it has "landed".
    local propEntity = CreateObject(model, dropCoords.x, dropCoords.y, dropCoords.z, true, true, false)
    if not propEntity or propEntity == 0 then
        print('[NovaConvoy][Airdrop] the crate object could not be created')
        return nil
    end
    -- A freshly created entity's handle can come back non-zero a frame or
    -- two before the game has actually finished registering it — calling
    -- another native (FreezeEntityPosition) on it immediately can then
    -- throw "Tried to access invalid entity" even though propEntity ~= 0.
    -- DoesEntityExist (not just the ~= 0 check above) is what actually
    -- confirms it's usable; the brief Wait(0) gives it a moment to settle
    -- before that check runs.
    local settleBy = GetGameTimer() + 1500
    repeat Wait(0) until DoesEntityExist(propEntity) or GetGameTimer() > settleBy
    if not DoesEntityExist(propEntity) then return nil end
    -- Ground snap via the game's own placement native, not a guessed
    -- model-dimensions offset (unreliable for some archetypes — see
    -- airdropDescent's own comment on this same switch) — same technique,
    -- now on both the cosmetic copy and this real crate, so they land at
    -- the same visual height as each other with no visible pop when this
    -- one streams in over the cosmetic copy.
    --
    -- This is also what stops the "crate is floating" report: the crate is
    -- created at the DROP COORD's Z, which for a route point or zone is the
    -- z the admin was floating at when they placed it (very often a metre or
    -- two above the street). Nothing here moved it down, so it hovered.
    --
    -- PlaceObjectOnGroundProperly/GetGroundZFor_3dCoord need map collision
    -- data the SERVER never loads — calling them here either throws (see
    -- safeGroundZ) or silently does nothing, which is why this "fallback"
    -- never actually fixed anything before: it was inert every single time.
    -- A real client (already networked to this exact prop) does the actual
    -- ground query and reports back the real answer — same pattern as the
    -- plane above needing a real client to actually fly it.
    snapPropToGroundViaClients(propEntity, dropCoords, candidates)
    FreezeEntityPosition(propEntity, true)
    print(('[NovaConvoy][Airdrop] crate landed at %.0f, %.0f'):format(dropCoords.x, dropCoords.y))
    return propEntity
end

-- Airdrop-in-Convoy support was removed entirely by request — a convoy's
-- route/checkpoint flow must never be touched by an airdrop; that concept
-- now only exists as the standalone Gang Airdrop event kind below
-- (spawnAirdropZone), which shares the crate/plane/guard machinery above but
-- is never triggered by, or able to interfere with, a moving convoy.

-- Standalone drop for a GANG_AIRDROP-kind convoy — same plane-flyover +
-- parachute + smoke presentation as spawnAirdrop above, just triggered from
-- a fixed zone's own raw coordinates instead of a route point being
-- reached, and gang-only end to end: no police audience anywhere (not even
-- addNpcBlip's police-only guard blips, or the "tactical" admin-visibility
-- banner a regular convoy's airdrop loot gets — see tacticalPlusAdminSources),
-- matching this event kind's "completely restricted from police" design.
-- The actual loot flow once this populates rt.airdrops[zone.id] is 100%
-- shared with a regular convoy's airdrop — tryLootAirdrop/claimAirdrop/etc.
-- all key off rt.airdrops[pointId] generically and don't care where that
-- entry came from.
local function spawnAirdropZone(rt, zone)
    if not zone.enabled then return end
    CreateThread(function()
        Wait((zone.activationDelay or 0) * 1000)
        -- `== rt`, not just "some run of this event id is active": a re-run of the same event (recurring / restarted) must not
        -- be spawned into by a timer left over from the previous run, which would drop that run's old zones into the new one.
        if active[rt.id] ~= rt then return end

        local cfg = Config.Airdrop or {}
        if (not zone.rewards or #zone.rewards == 0) and cfg.defaultRewards then
            zone.rewards = cfg.defaultRewards
        end
        -- Must be a real vector3, not a plain {x,y,z} table — flyAirdropPlane
        -- does vector subtraction against it (GetEntityCoords(ped) - dropCoords)
        -- to pick the nearest pilot, and a plain table there throws "attempt to
        -- perform unsupported operation on a vector value" (confirmed in
        -- fxserver.log: "flyAirdropPlane error on convoy #4 zone zone_...").
        -- That crash happened before any plane/pilot logic ran, so the pcall
        -- in the caller immediately forced overheadSignaled = true and the
        -- crate fell right away with no real flyover ever happening — exactly
        -- "no plane, banner fires and the drop just concludes."
        local coords = vector3(zone.x, zone.y, zone.z)
        local planeCfg = cfg.plane
        local zoneLabel = zone.name or zone.label or ('Drop Zone #%s'):format(tostring(zone.id))
        local audience = airdropCaptureAudience(rt)

        local function gangAnnounce(title, body, duration, kind)
            if not rt or not rt.def or not rt.def.settings or not rt.def.settings.announcements then return end
            if not title or title == '' then return end
            notify(audience, 'nova_convoytruck:runtime:announce', title, body, duration, kind or 'info')
        end

        local propEntity
        if planeCfg and planeCfg.enabled then
            local b = resolveBanner('airdropInbound', 'AIRDROP INCOMING: ' .. zoneLabel, 'A cargo plane has dropped a high-value supply crate at %s. Move to intercept!', 7000, 'start', zoneLabel)
            if b then gangAnnounce(b.title, b.body, b.duration, b.kind) end
            -- Zone circle only, matching spawnAirdrop's own early ping — no
            -- crate sprite until it actually lands.
            notify(audience, 'nova_convoytruck:runtime:airdropZonePing', { id = zone.id, x = coords.x, y = coords.y, z = coords.z, radius = cfg.zoneRadius })
            -- Lead time: the banner and the zone circle are out, but the plane only takes off after this many seconds, so gangs
            -- have time to get to the zone and actually watch the drop come in (otherwise the crate is already on the ground by the
            -- time anyone arrives, which is what made every drop after the first look like it just appeared).
            local lead = tonumber(planeCfg.leadSeconds) or 0
            if lead > 0 then
                local leadEnd = os.time() + lead
                while active[rt.id] == rt and os.time() < leadEnd do Wait(500) end
                if active[rt.id] ~= rt then return end
            end
            -- Same overhead-sync as spawnAirdrop above — the crate only
            -- starts falling once the plane is actually above it, not on
            -- its own independent timer.
            local overheadSignaled = false
            local releasePos = nil -- the plane's actual position when it let go of the crate
            local broadcastAudience = (audience and #audience > 0) and audience or Bridge.GetPlayers()
            local approachDist = math.max(100.0, planeCfg.approachDistance or 450.0)
            local planeSpeed = math.max(10.0, planeCfg.speed or 55.0)
            local expectedFlightSec = math.ceil(approachDist / planeSpeed)
            local waitUntil = os.time() + expectedFlightSec + 15
            CreateThread(function()
                local flyOk, flyErr = pcall(flyAirdropPlane, coords, planeCfg, broadcastAudience, function(pos)
                    releasePos = pos
                    overheadSignaled = true
                end)
                if not flyOk then
                    print(('[NovaConvoy] flyAirdropPlane error on convoy #%s zone %s: %s'):format(tostring(rt.id), tostring(zone.id), tostring(flyErr)))
                end
                overheadSignaled = true
            end)
            while not overheadSignaled and active[rt.id] == rt and os.time() < waitUntil do
                Wait(100)
            end
            if active[rt.id] ~= rt then return end
            local model = joaat(cfg.prop or 'xm_prop_x17_case_01')
            print(('[NovaConvoy][Airdrop] zone %s: %s - spawning the crate'):format(tostring(zone.id), overheadSignaled and 'plane signalled overhead' or 'the plane never signalled (time ran out)'))
            local okCrate, crateRes = pcall(spawnParachutingCrate, coords, model, planeCfg, audience, releasePos)
            if okCrate then
                propEntity = crateRes
            else
                print(('[NovaConvoy][Airdrop] spawning the crate failed: %s'):format(tostring(crateRes)))
            end
            if not propEntity then
                -- last resort: the crate still has to exist so the zone can be played
                local okC, o = pcall(CreateObject, model, coords.x, coords.y, coords.z, true, true, false)
                if okC and o and o ~= 0 then
                    local settleBy = GetGameTimer() + 1500
                    repeat Wait(0) until DoesEntityExist(o) or GetGameTimer() > settleBy
                    if DoesEntityExist(o) then
                        pcall(snapPropToGroundViaClients, o, coords, audience)
                        FreezeEntityPosition(o, true)
                        propEntity = o
                        print('[NovaConvoy][Airdrop] the crate was placed on the ground directly')
                    end
                end
            end
        else
            local b = resolveBanner('airdropActive', 'AIRDROP ACTIVE: ' .. zoneLabel, 'An emergency supply drop crate has appeared at %s — hostiles are guarding it!', 7000, 'info', zoneLabel)
            if b then gangAnnounce(b.title, b.body, b.duration, b.kind) end
            local model = joaat(cfg.prop or 'xm_prop_x17_case_01')
            propEntity = CreateObject(model, coords.x, coords.y, coords.z, true, true, false)
            if propEntity and propEntity ~= 0 then
                Wait(0) -- see spawnParachutingCrate's own comment on this same pattern
                if DoesEntityExist(propEntity) then
                    -- See spawnParachutingCrate's own comment: ask a real
                    -- client to ground-snap it, since the natives that would
                    -- do this server-side either don't exist there or never
                    -- actually work.
                    snapPropToGroundViaClients(propEntity, coords, audience)
                    FreezeEntityPosition(propEntity, true)
                else
                    propEntity = nil
                end
            end
        end

        if active[rt.id] ~= rt then
            if propEntity and DoesEntityExist(propEntity) then DeleteEntity(propEntity) end
            return
        end

        if planeCfg and planeCfg.enabled and propEntity and propEntity ~= 0 then
            local b = resolveBanner('airdropLanded', 'AIRDROP TOUCHDOWN: ' .. zoneLabel, 'Supply crate has touched down at %s! Red smoke is active — eliminate guards to claim the loot.', 8000, 'danger', zoneLabel)
            if b then gangAnnounce(b.title, b.body, b.duration, b.kind) end
            DiscordLog.appendEvent(rt.id, ('🪂 Airdrop "%s" has landed at drop zone!'):format(zoneLabel))
            local smoke = planeCfg.smoke
            if smoke and smoke.enabled then
                notify(audience, 'nova_convoytruck:runtime:airdropSmoke', zone.id, coords, smoke)
            end
        else
            DiscordLog.appendEvent(rt.id, ('🪂 Airdrop "%s" is active at drop zone!'):format(zoneLabel))
        end

        local guardCount = zone.guardCount
        if guardCount == nil then guardCount = cfg.guardCount or 3 end
        local guards = guardCount > 0 and NpcManager.spawnAmbushers(coords, guardCount, {
            model = zone.guardModel or cfg.guardModel,
            models = zone.guardModels or cfg.guardModels,
            weapon = zone.guardWeapon or cfg.guardWeapon,
            aggressiveness = zone.guardAggressiveness or cfg.guardAggressiveness or 'medium',
            -- Its own relationship group, not the shared 'nova_convoy_ambush'
            -- one — see npc_relationships.lua's "4b" section for why: a
            -- standalone Gang Airdrop has no escort of its own to speak of,
            -- so its guards should never be able to end up fighting an
            -- unrelated convoy's own police/army escort (or a regular
            -- ambush wave) that happens to wander into combat range.
            groupName = 'nova_convoy_airdrop_guard',
        }) or {}
        tagSpawned(rt, guards)

        -- Spawning the guards yields; if the event was force-ended meanwhile nothing else owns them yet.
        if active[rt.id] ~= rt then
            pcall(NpcManager.cleanup, guards)
            if propEntity and DoesEntityExist(propEntity) then DeleteEntity(propEntity) end
            return
        end

        local endTime = os.time() + (zone.duration or cfg.duration or 300)
        local netId = propEntity and propEntity ~= 0 and NetworkGetNetworkIdFromEntity(propEntity) or nil
        if propEntity and DoesEntityExist(propEntity) then
            Entity(propEntity).state:set('convoy_airdrop', true, true)
            Entity(propEntity).state:set('convoy_point_id', zone.id, true)
            Entity(propEntity).state:set('convoy_id', rt.id, true)
        end
        local blipId = rt.id .. ':airdrop:' .. tostring(zone.id)
        rt.airdrops = rt.airdrops or {}
        rt.airdrops[zone.id] = {
            coords = { id = zone.id, x = zone.x, y = zone.y, z = zone.z }, expires = endTime, looted = false, config = zone,
            propEntity = propEntity, netId = netId,
            guards = guards, lockProgress = 0, lockUnlocked = false, blipId = blipId,
        }
        addNpcBlip(rt, blipId, coords, 'airdrop_guard', ('%s Guards'):format(zoneLabel))
        local activeAudience = (audience and #audience > 0) and audience or Bridge.GetPlayers()
        notify(activeAudience, 'nova_convoytruck:runtime:airdropActive', { id = zone.id, x = zone.x, y = zone.y, z = zone.z, label = zoneLabel, radius = cfg.zoneRadius }, zone.duration or cfg.duration or 300)
        if rt.airdrops[zone.id].netId then
            -- Last arg: seconds until the crate expires, for the floating
            -- timer UI (the same duration the Wait() below sleeps for, which
            -- starts right after this notify).
            notify(activeAudience, 'nova_convoytruck:runtime:airdropLootable', rt.airdrops[zone.id].netId, zone.id, rt.id, zoneLabel, zone.duration or cfg.duration or 300)
        end
        -- GTA-style ped blips for the guards, shown once a player enters the
        -- zone (client-side) — see the matching block in spawnAirdrop above.
        local guardNetIds = {}
        for _, g in ipairs(guards) do
            if g.netId and g.netId > 0 then guardNetIds[#guardNetIds + 1] = g.netId end
        end
        if #guardNetIds > 0 then
            notify(activeAudience, 'nova_convoytruck:runtime:airdropGuardZone', zone.id, coords, cfg.zoneRadius or 35.0, guardNetIds)
        end

        Wait((zone.duration or cfg.duration or 300) * 1000)
        local entry = rt.airdrops[zone.id]
        if entry and not entry.looted then
            notify(audience, 'nova_convoytruck:runtime:airdropExpired', zone.id)
        end
        cleanupAirdrop(rt, entry)
        rt.airdrops[zone.id] = nil
    end)
end

local function airdropRequiredLockpicks(drop)
    if drop and drop.lockpicksRequired then return drop.lockpicksRequired end
    return (Config.Airdrop and Config.Airdrop.lockpicksRequired) or 1
end

-- Server-validates an airdrop loot attempt the same way tryLootTruck does:
-- gang participant only (police can walk up too, but the guards are hostile
-- to them same as anyone — no bypass here, this is opportunistic gang loot,
-- not something for police/admins to casually collect). Cracking it open
-- only gets you a SHOT at the reward — see the percentage roll in
-- reportAirdropLootAttempt — not a guarantee, so the guard fight can still
-- end in nothing.
local function doTryLootAirdrop(src, convoyId, pointId)
    local rt = active[convoyId]
    if not rt then return end

    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end

    if rt.def and rt.def.kind == 'GANG_AIRDROP' then
        if Bridge.IsPolice(src) then
            TriggerClientEvent('nova_convoytruck:client:notify', src, 'Police cannot loot gang airdrops.', 'error')
            return
        end
        local gang = GangService and GangService.GetPlayerGang(src)
        if not gang or not gang.name then
            TriggerClientEvent('nova_convoytruck:client:notify', src, 'Only gang members can loot airdrop crates.', 'error')
            return
        end
        if not isGangAllowed(rt, gang.name) then
            TriggerClientEvent('nova_convoytruck:client:notify', src, "You can't access this — your gang isn't part of this event.", 'error')
            return
        end

        if not rt.participants.identifiers[identifier] then
            local inGang = rt.participants.gangCounts[gang.name] or 0
            rt.participants.identifiers[identifier] = gang.name
            rt.participants.gangCounts[gang.name] = inGang + 1
            rt.participants.names[identifier] = Bridge.GetPlayerName(src)
            NpcManager.setPlayerHostile(src, true)
            persist(rt)
        end
    else
        local isParticipant = Runtime.isParticipant(convoyId, src)
        local gang = GangService and GangService.GetPlayerGang(src)
        local isPolice = Bridge.IsPolice(src)
        local isAdmin = UserPermissions.can(src, 'convoys.manage')
        if not isParticipant and not gang and not isPolice and not isAdmin then return end
        if not isParticipant and gang and not rt.participants.identifiers[identifier] then
            local inGang = rt.participants.gangCounts[gang.name] or 0
            rt.participants.identifiers[identifier] = gang.name
            rt.participants.gangCounts[gang.name] = inGang + 1
            rt.participants.names[identifier] = Bridge.GetPlayerName(src)
            NpcManager.setPlayerHostile(src, true)
            persist(rt)
        end
    end

    local entry = rt and rt.airdrops and rt.airdrops[pointId]
    if not entry or entry.looted then return end

    local cfg = Config.Airdrop or {}
    local drop = entry.config
    local requireLockpick = drop.requireLockpick
    if requireLockpick == nil then requireLockpick = cfg.requireLockpick end

    if entry.lockUnlocked then
        TriggerClientEvent('nova_convoytruck:runtime:openAirdropLoot', src, convoyId, pointId)
        return
    end

    if requireLockpick == false then
        TriggerClientEvent('nova_convoytruck:runtime:beginAirdropHackMinigame', src, convoyId, pointId)
        return
    end

    local lockpickItem = drop.lockpickItem or cfg.lockpickItem or 'lockpick'
    local dropLabel = (drop.name or drop.label) and ('Airdrop "%s"'):format(drop.name or drop.label) or ('Airdrop #%s'):format(tostring(pointId))
    if not beginLockpickAttempt(src, lockpickItem, convoyId, dropLabel) then
        return
    end

    local difficulty = drop.skillCheckDifficulty or cfg.skillCheckDifficulty or { 'easy', 'easy', 'medium' }
    TriggerClientEvent('nova_convoytruck:runtime:beginAirdropLootMinigame', src, convoyId, pointId, difficulty)
end

RegisterNetEvent('nova_convoytruck:runtime:server:tryLootAirdrop', function(convoyId, pointId)
    local src = source
    doTryLootAirdrop(src, convoyId, pointId)
end)

RegisterNetEvent('nova_convoytruck:runtime:server:tryLootAirdropGlobal', function(convoyId, pointId, netId)
    local src = source
    if (not convoyId or not pointId) and netId then
        local ent = NetworkGetEntityFromNetworkId(netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local st = Entity(ent).state
            convoyId = convoyId or st.convoy_id
            pointId = pointId or st.convoy_point_id
        end
    end
    if not convoyId or not pointId then
        for cid, r in pairs(active) do
            if r.airdrops then
                for pid, ad in pairs(r.airdrops) do
                    if ad.netId == netId then
                        convoyId = cid
                        pointId = pid
                        break
                    end
                end
            end
            if convoyId then break end
        end
    end
    if convoyId and pointId then
        doTryLootAirdrop(src, convoyId, pointId)
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:server:reportAirdropLootAttempt', function(convoyId, pointId, success)
    local src = source
    local rt = active[convoyId]
    local entry = rt and rt.airdrops and rt.airdrops[pointId]
    if not entry or entry.looted then pendingLockpick[src] = nil return end

    local lpInfo = settleLockpickAttempt(src, success)
    if not lpInfo then return end -- no open attempt: ignore an unsolicited report
    logLockpickAttempt(rt, src, ('Airdrop "%s"'):format(tostring((entry.config and (entry.config.name or entry.config.label)) or pointId)), success, lpInfo)
    tellLockpickResult(src, success, lpInfo)
    if not success then return end

    local required = airdropRequiredLockpicks(entry.config)
    entry.lockProgress = (entry.lockProgress or 0) + 1
    if entry.lockProgress < required then
        TriggerClientEvent('nova_convoytruck:runtime:lootProgress', src, entry.lockProgress, required)
        return
    end

    entry.lockUnlocked = true
    TriggerClientEvent('nova_convoytruck:runtime:openAirdropLoot', src, convoyId, pointId)
end)

-- The "Require a lockpick" OFF path — a single, harder skill check instead
-- of a consumable-lockpick multi-attempt grind. Success guarantees the
-- reward outright (see claimAirdrop's openedViaHack check bypassing the
-- percentage chance roll) — the trade-off for skipping the lockpick item
-- and the multi-attempt grind is a harder single check, not a free pass.
RegisterNetEvent('nova_convoytruck:runtime:server:reportAirdropHackAttempt', function(convoyId, pointId, success)
    local src = source
    local rt = active[convoyId]
    local entry = rt and rt.airdrops and rt.airdrops[pointId]
    if not entry or entry.lockUnlocked then return end

    if not success then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'Hack failed — the lock reset, try again.', 'error')
        return
    end

    entry.lockUnlocked = true
    entry.openedViaHack = true
    TriggerClientEvent('nova_convoytruck:runtime:openAirdropLoot', src, convoyId, pointId)
end)

-- The crate is open — this is where the actual "might get nothing" payoff
-- roll happens, once per crate (first one through the open animation gets
-- the shot; the crate is consumed either way). Never trust the client to
-- report its own roll — it only tells the server the lock is open, the
-- server decides what (if anything) that's worth. Also where the
-- "cracked open" banner + event-log entry fire, since by now the reward
-- outcome (hit/miss) is known too and worth recording alongside who did it.
RegisterNetEvent('nova_convoytruck:runtime:server:claimAirdrop', function(convoyId, pointId)
    local src = source
    local rt = active[convoyId]
    local entry = rt and rt.airdrops and rt.airdrops[pointId]
    if not entry or entry.looted then return end
    -- The crate must actually have been opened (lockpick progress complete, or the
    -- hack minigame passed) — never trust a bare "claim" from the client.
    if not entry.lockUnlocked then return end
    entry.looted = true
    local rewards = (entry.config and entry.config.rewards) or {}
    if (#rewards == 0) and Config.Airdrop and Config.Airdrop.defaultRewards then
        rewards = Config.Airdrop.defaultRewards
    end
    -- Hacked open = guaranteed reward, no roll — that's the whole trade-off
    -- of the harder single-check path versus the lockpick grind, which is
    -- still subject to the configured chance.
    local hit = entry.openedViaHack or (math.random(1, 100) <= (entry.config.chance or 100))

    local identifier = Bridge.GetIdentifier(src)
    local gangName = identifier and rt.participants.identifiers[identifier]
    if not gangName and src then
        local g = GangService.GetPlayerGang(src)
        if g and g.name then gangName = g.name end
    end
    local identity = gangName and gangIdentity(rt, gangName) or nil
    local playerName = Bridge.GetPlayerName(src) or 'Unknown Player'
    local dropName = entry.config and (entry.config.name or entry.config.label) or ('Airdrop #%s'):format(tostring(pointId))
    local capturer = identity and identity.label or playerName
    local verb = entry.openedViaHack and 'hacked' or 'cracked'

    if hit and #rewards > 0 then
        RewardService.GiveAirdropReward(rewards, { src }, {
            convoyId = rt.id, convoyName = rt.def.name,
            gangName = gangName, gangLabel = identity and identity.label,
            lootedBy = identifier, lootedByName = playerName,
            -- Gang XP duplicate protection: one payout per crate per run (a player may loot several crates in a run)
            runId = rt.startedAt, xpPhase = 'airdrop:' .. tostring(pointId),
        })
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'Jackpot — the crate had something good.', 'success')
        -- Only read by Runtime.finish's GANG_AIRDROP outcome check (was ANY
        -- zone actually looted, since rt.airdrops entries self-delete on
        -- their own timers and can't be inspected after the fact) — a no-op
        -- extra field for an ordinary convoy's route-point airdrop.
        rt.anyZoneLooted = true
        -- Per-kind gang leaderboard tracking — credited right here, per
        -- successful loot, rather than reconstructed later in
        -- finishGangAirdropEvent: each rt.airdrops entry self-deletes on its
        -- own timer, so which gang(s) actually won isn't recoverable by the
        -- time the event as a whole concludes. A loot-race event can have
        -- more than one gang win (different zones), so every successful hit
        -- earns its gang a credit, not just a single overall "winner." Used
        -- to be GANG_AIRDROP-only — an ordinary Convoy's own in-route
        -- airdrop point looted this exact same way earned NO leaderboard
        -- credit at all. Passing rt.def.kind through lets
        -- GangService.RecordOutcome route it to the right column on its
        -- own (convoys_captured for CONVOY, airdrop_completed for
        -- GANG_AIRDROP) — same combined "Captured" score a truck
        -- capture/loot already feeds for a Convoy.
        if gangName then
            GangService.RecordOutcome(gangName, 'captured', rt.def and rt.def.kind)
        end
    else
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'The crate is empty. Bad luck.', 'error')
    end

    local isPolice = Bridge.IsPolice(src) or false
    local jobGrade = Bridge.GetJobGrade(src) or nil
    local jobName = jobGrade and jobGrade.name or (isPolice and 'police' or 'civilian')

    local rewardParts = {}
    for _, r in ipairs(rewards or {}) do
        if r.type == 'money' or r.type == 'black_money' then
            rewardParts[#rewardParts + 1] = ('$%s cash'):format(tostring(r.amount or 0))
        elseif r.type == 'item' then
            rewardParts[#rewardParts + 1] = ('%sx %s'):format(tostring(r.amount or 1), tostring(r.item or 'item'))
        elseif r.type == 'weapon' then
            rewardParts[#rewardParts + 1] = tostring(r.weapon or 'weapon')
        end
    end
    local rewardSummaryStr = (hit and #rewardParts > 0) and table.concat(rewardParts, ', ') or (hit and 'Crate Reward' or 'Empty / No rewards')

    rt.airdropCaptures = rt.airdropCaptures or {}
    rt.gangAirdropCounts = rt.gangAirdropCounts or {}
    if gangName then
        rt.gangAirdropCounts[gangName] = (rt.gangAirdropCounts[gangName] or 0) + 1
    end
    rt.airdropCaptures[#rt.airdropCaptures + 1] = {
        dropName = dropName,
        pointId = pointId,
        playerName = playerName,
        playerIdentifier = identifier,
        gang = gangName,
        gangLabel = identity and identity.label or gangName or (isPolice and 'Police Department' or 'Independent'),
        isPolice = isPolice,
        job = jobName,
        jobGrade = jobGrade and jobGrade.grade or 0,
        usedLockpick = not entry.openedViaHack,
        usedHack = entry.openedViaHack == true,
        hit = hit,
        rewards = rewards,
        rewardSummary = rewardSummaryStr,
        verb = verb,
        timestamp = os.time(),
        timeStr = os.date('!%H:%M:%S', os.time()),
    }

    if isPolice then
        rt.policeAudit = rt.policeAudit or {}
        rt.policeAudit[#rt.policeAudit + 1] = {
            type = 'AIRDROP_LOOT',
            target = dropName,
            officerName = playerName,
            officerIdentifier = identifier,
            job = jobName,
            jobGrade = jobGrade and jobGrade.grade or 0,
            items = rewardSummaryStr,
            usedLockpick = not entry.openedViaHack,
            usedHack = entry.openedViaHack == true,
            timestamp = os.time(),
            timeStr = os.date('!%H:%M:%S', os.time()),
            alert = 'POLICE OFFICER LOOTED AIRDROP CRATE',
        }
        DiscordLog.appendEvent(rt.id, ('🚨 [POLICE AUDIT / FAIL-RP] Officer %s (%s) [%s] LOOTED airdrop crate "%s"! Rewards: %s'):format(
            playerName, identifier or 'N/A', jobName, dropName, rewardSummaryStr
        ))
    end

    if hit and #rewards > 0 and registerLootCarrier then
        registerLootCarrier(rt, src, 'AIRDROP', dropName, rewardSummaryStr)
    end

    if rt.def.settings.announcements then
        local b = resolveBanner('airdropCaptured', 'Airdrop Captured', '%s has successfully captured %s (%s open).', 7000, 'success', capturer, dropName, verb)
        if b then
            notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind, identity)
        end
    end
    DB.insertConvoyEvent(rt.id, 'AIRDROP_LOOTED', {
        gangName = gangName, gangLabel = identity and identity.label or capturer,
        playerIdentifier = identifier, playerName = playerName,
        detail = ('%s (%s)'):format(dropName, hit and #rewards > 0 and 'Reward hit' or 'Empty — no reward'),
    })
    DiscordLog.appendEvent(rt.id, ('📦 Airdrop "%s" %s open by %s (%s) [%s] — %s'):format(
        dropName, verb, playerName, identifier or 'N/A', identity and identity.label or 'Independent',
        (hit and #rewards > 0) and 'reward secured' or 'empty crate'
    ))

    -- airdropCaptureAudience already includes police for a regular convoy's
    -- in-route airdrop (which now sees the zone sprite too — needs this
    -- cleanup signal or the blip outlives the crate) while staying gang-only
    -- for GANG_AIRDROP, matching that kind's "invisible to police" design.
    -- 3rd arg: who took it, for the floating "AIRDROP STOLEN" marker.
    notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:airdropLooted', pointId, capturer)
    cleanupAirdrop(rt, entry, true) -- keepProp: leave the claimed crate sitting there until the event ends
end)

local function runBreak(rt, point)
    local bc = breakConfigFor(rt.def, point.id)
    local truckNetIds = {}
    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.captured then truckNetIds[#truckNetIds + 1] = t.netId end
    end

    if bc.freezeTruck then notify(policeParticipantSources(rt), 'nova_convoytruck:runtime:freezeTruck', truckNetIds) end
    if bc.announce then
        local b = resolveBanner('checkpointBreak', '%s', 'Convoy is taking a short break. Hold position.', 5000, 'warn', bc.name)
        if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
    end

    Wait((bc.duration or 15) * 1000)

    if not active[rt.id] then return end
    if bc.freezeTruck then notify(policeParticipantSources(rt), 'nova_convoytruck:runtime:unfreezeTruck', truckNetIds) end
end

-- Ambushes have been removed from the resource.
local function runAmbush(rt, point)
    -- No-op: ambush mechanic removed
end

local checkDeliveries -- forward declaration

local function unlockDelivery(rt, destPoint)
    rt.status = 'DELIVERY'
    ConvoyManager.setStatus(rt.id, 'DELIVERY')
    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.captured then
            local sources = policeParticipantSources(rt)
            for _, s in ipairs(gangParticipantSources(rt)) do sources[#sources + 1] = s end
            notify(sources, 'nova_convoytruck:runtime:dropzone', rt.id, t.netId, destPoint)
        end
    end
    local b = resolveBanner('destinationReached', 'Convoy Update', 'Convoy destination reached. Delivery zone is active.', 7000, 'info')
    if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
    if checkDeliveries then pcall(checkDeliveries, rt) end
    persist(rt)
end

local function runNpcSpawnPoint(rt, point)
    local cfg = point.npcConfig or {}
    local triggerMode = cfg.triggerMode or 'WHEN_REACHED'
    if triggerMode == 'CHECKPOINT_SUPPORT' then
        return
    end

    local faction = cfg.faction or 'POLICE'
    local count = math.min(10, math.max(1, tonumber(cfg.count) or 4))
    local aggressiveness = cfg.aggressiveness or 'medium'
    local model = (cfg.model and cfg.model ~= '') and cfg.model or (faction == 'ARMY' and 's_m_y_marine_03' or (faction == 'CARTEL' and 'g_m_y_salvagoon_01' or (faction == 'SECURITY' and 's_m_m_security_01' or 's_m_y_cop_01')))
    local weapon = (cfg.weapon and cfg.weapon ~= '') and cfg.weapon or 'WEAPON_CARBINERIFLE'
    local behavior = cfg.behavior or 'GUARD_AREA'

    rt.activeRouteNpcs = rt.activeRouteNpcs or {}
    local spawned = {}

    if faction == 'CARTEL' then
        spawned = NpcManager.spawnAmbushers(point, count, {
            model = model,
            weapon = weapon,
            aggressiveness = aggressiveness,
        })
        tagSpawned(rt, spawned)
        local blipId = rt.id .. ':point:' .. point.id .. ':cartel'
        addNpcBlip(rt, blipId, point, 'ambush', 'Cartel Ambush')
        if cfg.announce then
            local b = resolveBanner('hostileAmbush', 'AMBUSH DETECTED', 'Hostile cartel fighters have ambushed the route!', 7000, 'danger')
            if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
        end
    else
        local kind = (faction == 'ARMY' and 'army') or 'police'
        local supportCfg = {
            model = model,
            weapon = weapon,
            behavior = behavior,
            aggressiveness = aggressiveness,
            vehicleModel = cfg.vehicleModel,
            spawnVehicle = cfg.vehicleModel and cfg.vehicleModel ~= '',
        }
        spawned = NpcManager.spawnCheckpointSupport(kind, supportCfg, point, count, false)
        tagSpawned(rt, spawned)
        local blipId = rt.id .. ':point:' .. point.id .. ':' .. kind
        local label = (faction == 'ARMY' and 'NPC Army Support') or (faction == 'SECURITY' and 'Private Security Escort') or 'NPC Police Support'
        addNpcBlip(rt, blipId, point, kind, label)
        if cfg.announce then
            local b = resolveBanner('supportDeployed', 'DEFENSIVE REINFORCEMENTS', '%s deployed along transport route.', 7000, 'info', label)
            if b then announcePolice(rt, b.title, b.body, b.duration, b.kind) end
        end
    end

    if not active[rt.id] then
        pcall(NpcManager.cleanup, spawned) -- the event ended while these were spawning
        return
    end
    for _, e in ipairs(spawned) do
        rt.activeRouteNpcs[#rt.activeRouteNpcs + 1] = e
    end
end

-- ── driving column ────────────────────────────────────────────────────────────────
-- The convoy drives as one column in spawn order (columnIndex, 1 = front).
-- Every truck drives independently to its own nose-to-tail offset point —
-- see driveColumn's own comment below for the two designs this replaced and
-- why.
columnOrder = function(rt)
    local list = {}
    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.captured and not t.brokenDown and not t.disabled and t.state ~= 'DISABLED' and t.entity and DoesEntityExist(t.entity) then
            list[#list + 1] = t
        end
    end
    table.sort(list, function(a, b) return (a.columnIndex or 99) < (b.columnIndex or 99) end)
    return list
end

-- force = re-task every truck now (after a checkpoint/break hold released
-- them); otherwise only trucks whose role in the column changed, or that
-- have genuinely stalled, get a new task — re-tasking a moving truck means
-- ClearPedTasks + a fresh path, which is a visible brake-and-go.
-- Grace period before a slow-speed reading is allowed to count as "stalled".
-- A big rig doing a multi-point turn right after being released/re-tasked
-- can legitimately sit under 0.2 speed for several real seconds mid-turn.
-- Without this, the very next 10s stall check below saw that, ClearPedTasks
-- + re-issued the SAME drive task, wiping out whatever progress the AI had
-- made on the turn and restarting its reorientation from zero — repeating
-- every 10s until the truck happened to complete its turn inside one whole
-- window. That is exactly "every truck rotates in place for a couple of
-- minutes, then suddenly drives off" — a self-inflicted loop, not the truck
-- actually struggling to find the route.
local STALL_GRACE_SECONDS = 20
-- Every truck drives to the real route point it is up to — no invented
-- "formation" coordinates (those were straight-line offsets from the route
-- point that could land off-road and sent followers on their own paths).
-- Spacing between trucks comes from where they spawn at START and from
-- regroupTrucksAtCheckpoint; on the road they simply queue behind each other.
-- columnOrder() already drops captured/disabled/destroyed trucks from the
-- list, so a truck being taken has no effect on anyone else's task.
--
-- `only` (optional) limits the call to that one truck — used to release the
-- trucks parked at a checkpoint one at a time. A truck parked on a checkpoint
-- (t.checkpointParked) is never re-tasked by anyone else's call: it stays put
-- until its own release.
driveColumn = function(rt, target, tick, force, only)
    if not target then return end
    local column = columnOrder(rt)
    local checkStall = tick and tick % 10 == 0
    local nowS = os.time()

    for _, t in ipairs(column) do
        if not t.driverPed or not DoesEntityExist(t.driverPed) then
            ensureTruckDriver(t)
        end
        if (not only or t == only) and not t.checkpointParked and t.driverPed and DoesEntityExist(t.driverPed) then
            -- Independent route progress per truck:
            -- Each truck maintains its own progress along the route. When the lead truck reaches or clears
            -- a checkpoint, trailing trucks maintain their own route progress, allowing them to follow
            -- the exact configured road path through all intervening checkpoints and waypoints.
            local idx = t.routeIdx or 1
            local okC, c = pcall(GetEntityCoords, t.entity)
            if okC and c then
                -- A plain ROUTE point the truck cannot reach (the game finds no road path to it, so the truck stops a few dozen
                -- metres short and its drive order dies) must not freeze the whole convoy: after 12 s standing still within
                -- 90 m of one, move on to the next point. Checkpoints, the start and the destination are never skipped.
                -- "standing still" = moved less than 4 m since the timer started (a truck rocking back and forth keeps
                -- its speed bouncing, so a speed test alone never saw it as stuck)
                if t.stillSeen and nowS - t.stillSeen > 4 then t.stillSince = nil end
                t.stillSeen = nowS
                if t.stillPos and t.stillSince and (c.x - t.stillPos.x) ^ 2 + (c.y - t.stillPos.y) ^ 2 < 16.0 then
                    -- still inside the 4 m circle: keep counting
                else
                    t.stillPos = { x = c.x, y = c.y }
                    t.stillSince = nowS
                end                local cur = rt.route[idx]
                if t.stillSince and nowS - t.stillSince >= 12 and cur and cur.type == 'ROUTE' and idx < #rt.route then
                    local sdx, sdy = c.x - cur.x, c.y - cur.y
                    if sdx * sdx + sdy * sdy <= 90.0 * 90.0 then
                        print(('^3[Convoy] #%s truck %s could not reach route point %d (%.0f m away, no road path) - skipping to point %d^0'):format(
                            tostring(rt.id), tostring(t.id), idx, math.sqrt(sdx * sdx + sdy * sdy), idx + 1))
                        idx = idx + 1
                        t.stillSince = nil
                        t.drivingToIndex = nil
                    end
                end
                while idx < #rt.route do
                    local p = rt.route[idx]
                    if not p then break end
                    local dx, dy = c.x - p.x, c.y - p.y
                    local reachDist = (p.type == 'CHECKPOINT') and math.max(GENERIC_REACH_RADIUS, 45.0) or GENERIC_REACH_RADIUS
                    -- A plain ROUTE point the truck has DRIVEN PAST (its position is beyond the point along the drawn leg) within 80 m counts as
                    -- passed: a point it missed by more than the reach radius used to turn the truck round to go back for it.
                    local passed = false
                    local prevP = rt.route[idx - 1]
                    if p.type == 'ROUTE' and prevP and dx * dx + dy * dy <= 80.0 * 80.0 then
                        passed = ((c.x - p.x) * (p.x - prevP.x) + (c.y - p.y) * (p.y - prevP.y)) > 0.0
                    end
                    if passed or dx * dx + dy * dy <= reachDist * reachDist then
                        -- If this is an active checkpoint hold and the truck has parked, stay here until released
                        if p.type == 'CHECKPOINT' and rt.status == 'CHECKPOINT' and t.checkpointParked then
                            break
                        end
                        idx = idx + 1
                    else
                        break
                    end
                end
            end
            t.routeIdx = idx

            -- Point target for this individual truck
            local pointFor = (idx <= #rt.route) and (resolveDriveTarget(rt, idx) or rt.route[idx]) or target
            if not pointFor then pointFor = target end

            -- A truck that has wandered far off the drawn route (a straight-line drive over rough ground, a detour the roads
            -- forced, a slide gone wrong) is put back ON the route: the nearest point of the legs it should be on (the
            -- few before its current point up to it). Only after 8 consecutive checks more than Config.RouteRecoveryDistance
            -- away; 0 turns it off. Never for a parked / disabled truck.
            local recoverDist = tonumber(Config.RouteRecoveryDistance)
            if recoverDist == nil then recoverDist = 120.0 end
            -- (Teleporting a truck is a script move: only when Config.TruckScriptMoves is switched on, which it is not by default)
            if Config.TruckScriptMoves == true and recoverDist > 0 and not t.checkpointParked and t.entity and DoesEntityExist(t.entity) and idx > 1 then
                local okR, rc = pcall(GetEntityCoords, t.entity)
                if okR and rc then
                    local bestD, bx, by, bz, bh = math.huge, nil, nil, nil, 0.0
                    for k = math.max(1, idx - 4), math.min(idx - 1, #rt.route - 1) do
                        local a, b = rt.route[k], rt.route[k + 1]
                        if a and b then
                            local abx, aby = b.x - a.x, b.y - a.y
                            local l2 = abx * abx + aby * aby
                            local u = 0.0
                            if l2 > 0.0 then u = math.max(0.0, math.min(1.0, ((rc.x - a.x) * abx + (rc.y - a.y) * aby) / l2)) end
                            local px, py = a.x + u * abx, a.y + u * aby
                            local d = math.sqrt((rc.x - px) ^ 2 + (rc.y - py) ^ 2)
                            if d < bestD then
                                bestD, bx, by, bz = d, px, py, (a.z or rc.z) + u * ((b.z or a.z or rc.z) - (a.z or rc.z))
                                bh = math.deg(math.atan(-abx, aby)) % 360
                            end
                        end
                    end
                    if bx and bestD > recoverDist then
                        t.offRouteTicks = (t.offRouteTicks or 0) + 1
                        if t.offRouteTicks >= 8 then
                            t.offRouteTicks = 0
                            print(('^3[Convoy] #%s truck %s had wandered %.0f m off the route - putting it back on the route^0'):format(tostring(rt.id), tostring(t.id), bestD))
                            FreezeEntityPosition(t.entity, false)
                            pcall(SetEntityCoords, t.entity, bx, by, bz + 0.5, false, false, false, false)
                            pcall(SetEntityHeading, t.entity, bh)
                            t.drivingToIndex = nil
                            t.stillSince = nil
                        end
                    else
                        t.offRouteTicks = 0
                    end
                end
            end

            -- RESCUE (works even with Config.TruckScriptMoves = false, and only for a truck that is clearly LOST): one that fell off a bridge /
            -- into a ditch, or ended up far from the drawn route, and has been standing or crawling for Config.TruckRescue.seconds cannot find
            -- its own way back, so it is put back on the nearest point of the drawn route. A truck that is merely driving a corner badly
            -- is not touched. Switch off with Config.TruckRescue.enabled = false.
            local rescue = Config.TruckRescue or {}
            if rescue.enabled ~= false and Config.TruckScriptMoves ~= true and not t.checkpointParked and not t.disabled and t.entity and DoesEntityExist(t.entity) and idx > 1 then
                local okR, rc = pcall(GetEntityCoords, t.entity)
                if okR and rc then
                    local bestD, bestDz, bx, by, bz, bh = math.huge, 0.0, nil, nil, nil, 0.0
                    for k = math.max(1, idx - 4), math.min(idx - 1, #rt.route - 1) do
                        local a, b = rt.route[k], rt.route[k + 1]
                        if a and b then
                            local abx, aby = b.x - a.x, b.y - a.y
                            local l2 = abx * abx + aby * aby
                            local u = 0.0
                            if l2 > 0.0 then u = math.max(0.0, math.min(1.0, ((rc.x - a.x) * abx + (rc.y - a.y) * aby) / l2)) end
                            local px, py = a.x + u * abx, a.y + u * aby
                            local pz = (a.z or rc.z) + u * ((b.z or a.z or rc.z) - (a.z or rc.z))
                            local d = math.sqrt((rc.x - px) ^ 2 + (rc.y - py) ^ 2)
                            if d + math.abs(rc.z - pz) < bestD + bestDz then
                                bestD, bestDz, bx, by, bz = d, math.abs(rc.z - pz), px, py, pz
                                bh = math.deg(math.atan(-abx, aby)) % 360
                            end
                        end
                    end
                    local lost = bx and (bestD > (tonumber(rescue.offRouteMeters) or 40.0) or bestDz > (tonumber(rescue.belowMeters) or 6.0))
                    if lost and GetEntitySpeed(t.entity) < 2.0 then
                        t.lostSince = t.lostSince or nowS
                        if nowS - t.lostSince >= (tonumber(rescue.seconds) or 20) then
                            t.lostSince = nil
                            print(('^3[Convoy] #%s truck %s was lost %.0f m off / %.0f m below the route and could not get back - put back on the route^0'):format(tostring(rt.id), tostring(t.id), bestD, bestDz))
                            FreezeEntityPosition(t.entity, false)
                            pcall(SetEntityCoords, t.entity, bx, by, bz + 0.5, false, false, false, false)
                            pcall(SetEntityHeading, t.entity, bh)
                            pcall(SetEntityVelocity, t.entity, 0.0, 0.0, 0.0)
                            t.drivingToIndex = nil
                            t.stillSince = nil
                        end
                    else
                        t.lostSince = nil
                    end
                end
            end

            -- LAST RESORT: a truck whose AI cannot get it moving (a crossing the road network does not allow, a median,
            -- a blocked lane) is slid along the drawn route by the server for a few seconds, then handed back to its
            -- driver. 20 s still the first time, 8 s after that. Never for a parked / disabled truck or one already at
            -- its point. Switch off with Config.StuckSlide = false.
            if Config.TruckScriptMoves == true and Config.StuckSlide ~= false and not t.checkpointParked and t.entity and DoesEntityExist(t.entity) then
                local okS2, sc = pcall(GetEntityCoords, t.entity)
                if okS2 and sc then
                    local sdx, sdy = pointFor.x - sc.x, pointFor.y - sc.y
                    local sdist = math.sqrt(sdx * sdx + sdy * sdy)
                    local limit = t.everSlid and 8 or 20
                    if not (t.slideUntil and nowS < t.slideUntil) and t.stillSince and nowS - t.stillSince >= limit and sdist > 12.0 then
                        t.slideUntil = nowS + 6
                        t.everSlid = true
                        print(('^3[Convoy] #%s truck %s could not drive on by itself (%.0f m from route point %d) - sliding it along the route for a few seconds^0'):format(
                            tostring(rt.id), tostring(t.id), sdist, idx))
                    end
                    if t.slideUntil and nowS < t.slideUntil and sdist > 6.0 then
                        local step = math.min(sdist, 9.0)
                        local nz = sc.z + ((pointFor.z or sc.z) - sc.z) * (step / sdist)
                        local heading = math.deg(math.atan(-sdx, sdy)) % 360
                        FreezeEntityPosition(t.entity, false)
                        pcall(SetEntityCoords, t.entity, sc.x + (sdx / sdist) * step, sc.y + (sdy / sdist) * step, nz, false, false, false, false)
                        pcall(SetEntityHeading, t.entity, heading)
                        t.slidEnded = false
                    elseif t.slideUntil and nowS >= t.slideUntil and not t.slidEnded then
                        t.slidEnded = true
                        t.drivingToIndex = nil   -- give the driver a fresh order from where the slide left it
                        t.stillSince = nil
                    end
                end
            end

            local pastGrace = (nowS - (t.lastDriveTaskTime or 0)) >= STALL_GRACE_SECONDS
            local stalled = checkStall and pastGrace and GetEntitySpeed(t.entity) < 0.2
            if force or t.drivingToIndex ~= idx or stalled then
                t.drivingToIndex = idx
                driveTruckTo(t, pointFor, nil, idx > 1 and rt.route[idx - 1] or nil, rt.route[idx + 1])
            end
        end
    end
end

-- Keeps the column together: if any follower has dropped too far behind the
-- truck ahead of it, the front truck eases off until the gap closes again.
-- Changes the running drive task's cruise speed in place (no re-task).
local COLUMN_GAP_SLOW = 60.0
local COLUMN_GAP_OK = 35.0
local COLUMN_SLOW_FACTOR = 0.55
-- How long the lead is allowed to ease off waiting for a lagging follower
-- before it just gives up and resumes full speed regardless. Without this,
-- a follower that's genuinely stuck (not just lagging — wedged on terrain,
-- fighting off an ambush, anything its OWN anti-stall watchdog hasn't
-- managed to recover from yet) never lets the gap close, so the lead would
-- stay throttled at COLUMN_SLOW_FACTOR forever — reported as "because the
-- last truck got stuck, the primary truck stopped too." Waiting a
-- reasonable amount for a truck that's actually catching up is the whole
-- point of cohesion; waiting FOREVER for one that isn't is not.
local COLUMN_WAIT_TIMEOUT_MS = 20000
local function updateColumnCohesion(rt)
    local column = columnOrder(rt)
    local lead = column[1]
    if not lead or not lead.driverPed or not DoesEntityExist(lead.driverPed) then return end
    local maxGap = 0.0
    for i = 2, #column do
        local g = #(GetEntityCoords(column[i].entity) - GetEntityCoords(column[i - 1].entity))
        if g > maxGap then maxGap = g end
    end
    local factor = lead.speedFactor or 1.0
    if maxGap > COLUMN_GAP_SLOW then
        local nowMs = os.time() * 1000
        if not lead.cohesionSlowSince then
            lead.cohesionSlowSince = nowMs
        elseif nowMs - lead.cohesionSlowSince > COLUMN_WAIT_TIMEOUT_MS then
            factor = 1.0 -- waited long enough — stop holding the convoy for it
        else
            factor = COLUMN_SLOW_FACTOR
        end
    elseif maxGap < COLUMN_GAP_OK then
        factor = 1.0
        lead.cohesionSlowSince = nil
    end
    if factor ~= (lead.speedFactor or 1.0) then
        lead.speedFactor = factor
        TriggerClientEvent('nova_convoytruck:runtime:setCruise', -1, lead.netId, 15.0 * (lead.speed or 1.0) * factor)
    end
end

-- ── delivery ──────────────────────────────────────────────────────────────────────
-- Delivery is automatic now: a truck that drives into the destination
-- marker is delivered (removed, banner, counted) on the spot. It used to
-- need a police officer standing within 8m of the truck pressing E — and on
-- top of that, arriving at the destination stopped EVERY truck (stopTruck)
-- and nothing ever re-tasked them in DELIVERY status, so stragglers sat
-- wherever they were forever. With no delivery, survivingCargoTrucks never
-- emptied, Runtime.finish never ran, and no end banner ever fired.
-- "as close as the road gets" allowance, see checkDeliveries (a truck this close that has slowed down is delivered)
local DELIVERY_NEAR_RADIUS = tonumber(Config.DeliveryNearRadius) or 0.0   -- 0 = off: a truck is only delivered ON the destination mark
-- A truck that has not moved for DELIVERY_STALL_SECONDS anywhere inside this radius of the destination is delivered too:
-- it got as close as it ever will (road pathing, a barrier, a blocked lane) and must not sit there for the rest of the event.
local DELIVERY_STALL_RADIUS = tonumber(Config.DeliveryStallRadius) or 0.0   -- 0 = off
local DELIVERY_STALL_SECONDS = tonumber(Config.DeliveryStallSeconds) or 10
-- An NPC-driven truck is delivered only once it has DRIVEN ONTO the destination mark and STANDS there: inside the ring and almost
-- still for this many seconds (a truck rolling through the ring is not delivered).
local DELIVERY_STAND_SECONDS = tonumber(Config.DeliveryStandSeconds) or 2.0
local DELIVERY_STAND_SPEED = tonumber(Config.DeliveryStandSpeed) or 1.5

local function deliverTruck(rt, t)
    if t.delivered or t.destroyed or t.captured then return end
    t.delivered = true
    t.state = 'DELIVERED'
    local netId = t.netId
    if t.driverPed and DoesEntityExist(t.driverPed) then DeleteEntity(t.driverPed) end
    if t.entity and DoesEntityExist(t.entity) then
        ejectLivePlayersFrom(t.entity)
        DeleteEntity(t.entity)
    end
    TriggerClientEvent('nova_convoytruck:runtime:truckDelivered', -1, netId)

    if t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO' then
        -- Counts every PRIMARY/SECONDARY_CARGO truck (not escorts/decoys), so
        -- with several cargo trucks everyone can see how many are done.
        local totalCargo, deliveredCount = 0, 0
        for _, other in pairs(rt.trucks) do
            if other.role == 'PRIMARY_CARGO' or other.role == 'SECONDARY_CARGO' then
                totalCargo = totalCargo + 1
                if other.delivered then deliveredCount = deliveredCount + 1 end
            end
        end
        local remaining = #survivingCargoTrucks(rt)
        local b = resolveBanner(
            'truckDelivered',
            ('Truck Delivered %d/%d'):format(deliveredCount, totalCargo),
            'Truck delivered (%d/%d) — %d truck%s remaining.',
            5000,
            'success',
            deliveredCount, totalCargo, remaining, remaining == 1 and '' or 's'
        )
        if b and not (rt.def and rt.def.settings and rt.def.settings.announcements == false) then
            -- Everyone following the run: joined police, joined gangs AND on-duty police / admins who are watching
            -- without having pressed Join (announceAll skipped those, so a watching officer never saw the count).
            local seen, audience = {}, {}
            local function add(list)
                for _, s in ipairs(list or {}) do
                    if not seen[s] then seen[s] = true; audience[#audience + 1] = s end
                end
            end
            add(policeAndAdminSources(rt))
            add(policeParticipantSources(rt))
            add(gangParticipantSources(rt))
            notify(audience, 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind)
        end
        DiscordLog.appendEvent(rt.id, ('📦 Truck delivered — %s (%d/%d)'):format(TRUCK_ROLE_LABELS[t.role] or t.id, deliveredCount, totalCargo))
    end
    pcall(sendConvoyProgress, rt)
    persist(rt)
end

-- Delivered when inside the delivery radius, OR when it's within
-- DELIVERY_NEAR_RADIUS and has been sitting still for 3s — GTA's road-node
-- pathing often can't put a truck right on a marker placed off the road
-- (a lot, a driveway), and the drive task just parks as close as it can.
-- A DISABLED truck (engine shot out) doesn't get the "near" allowance, so a
-- gang can still fight over a truck that died just short of the gate.
checkDeliveries = function(rt)
    local dest = findPoint(rt.route, 'DESTINATION')
    if not dest then return end
    -- The delivery circle is the RED RING the players see at the destination (Config.DeliveryRadius + 5, drawn by the client), or the
    -- destination point's own radius when that is larger: an NPC driver that has rolled onto the ring counts as arrived. It used to be the
    -- bare DeliveryRadius, so a truck standing inside the visible ring was not delivered until it had also crept closer or stopped.
    local radius = math.max((tonumber(Config.DeliveryRadius) or 20.0) + 5.0, 17.0, tonumber(dest.radius) or 0.0)
    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.captured then
            local c = nil
            local speed = 0.0
            if t.entity and DoesEntityExist(t.entity) then
                c = GetEntityCoords(t.entity)
                speed = GetEntitySpeed(t.entity)
            elseif t.lastCoords then
                c = t.lastCoords
                speed = 0.0
            end
            -- A truck with a real player at the wheel is delivered by that player pressing [E] at the drop zone, never
            -- by the automatic rules below (those exist for NPC-driven trucks that stop short of the marker).
            local human = t.entity and DoesEntityExist(t.entity) and findDrivingPlayerSource(t.entity) ~= nil
            if human then
                t.nearDestTicks = 0
                t.destStillPos, t.destStillTicks = nil, 0
            elseif c then
                local d = #(vector2(c.x, c.y) - vector2(dest.x, dest.y))
                if DELIVERY_NEAR_RADIUS > 0 and d <= DELIVERY_NEAR_RADIUS and speed < 3.0 and t.state ~= 'DISABLED' then
                    t.nearDestTicks = (t.nearDestTicks or 0) + 1
                else
                    t.nearDestTicks = 0
                end
                -- standing still (moved under 4 m) inside the stall radius: count seconds
                if DELIVERY_STALL_RADIUS > 0 and d <= DELIVERY_STALL_RADIUS and t.state ~= 'DISABLED' then
                    if t.destStillPos and (c.x - t.destStillPos.x) ^ 2 + (c.y - t.destStillPos.y) ^ 2 < 16.0 then
                        t.destStillTicks = (t.destStillTicks or 0) + 1
                    else
                        t.destStillPos = { x = c.x, y = c.y }
                        t.destStillTicks = 0
                    end
                else
                    t.destStillPos, t.destStillTicks = nil, 0
                end
                -- on the mark and standing: the truck has arrived (a truck still rolling inside the ring has not)
                local standing = false
                if d <= radius and speed <= DELIVERY_STAND_SPEED then
                    t.onMarkSince = t.onMarkSince or os.time()
                    standing = (os.time() - t.onMarkSince) >= DELIVERY_STAND_SECONDS
                else
                    t.onMarkSince = nil
                end
                if standing or (DELIVERY_NEAR_RADIUS > 0 and t.nearDestTicks >= 3) or (DELIVERY_STALL_RADIUS > 0 and (t.destStillTicks or 0) >= DELIVERY_STALL_SECONDS) then
                    if d > radius then
                        print(('[NovaConvoy] #%s truck %s delivered %.0f m from the destination (%s)'):format(tostring(rt.id), tostring(t.id), d,
                            t.nearDestTicks >= 3 and 'as close as it could get' or ('stood still ' .. tostring(t.destStillTicks) .. ' s')))
                    end
                    deliverTruck(rt, t)
                end
            end
        end
    end
end

-- ── escort proximity (Config toggle: "Require Police Escort Proximity") ────────────
-- ON (default): the convoy only makes progress while a joined police
-- officer is actually within range of it — this is what makes "you have to
-- stay near the convoy" a real, visible rule (paused timer, an explaining
-- banner). If no human police have joined the event, it runs autonomously.
local ESCORT_PROXIMITY_RADIUS = 150.0

local function checkEscortProximity(rt, policeSrcs)
    if not rt or not rt.def or not rt.def.settings then return end
    if rt.def.settings.requireEscortProximity == false then
        if rt.escortHalted then
            rt.escortHalted = false
            driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), nil, true)
        end
        return
    end

    -- Escort proximity only applies if officers actually registered/joined this convoy escort:
    local registeredEscorts = {}
    if rt.participants and rt.participants.policeIdentifiers then
        for identifier, _ in pairs(rt.participants.policeIdentifiers) do
            for _, src in ipairs(Bridge.GetPlayers()) do
                if Bridge.GetIdentifier(src) == identifier then
                    registeredEscorts[#registeredEscorts + 1] = src
                    break
                end
            end
        end
    end

    if #registeredEscorts == 0 then
        if rt.escortHalted then
            rt.escortHalted = false
            driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), nil, true)
        end
        return
    end

    local lead = leadTruck(rt)
    if not lead or not lead.entity or not DoesEntityExist(lead.entity) then return end
    local okC, truckCoords = pcall(GetEntityCoords, lead.entity)
    if not okC or not truckCoords then return end

    local nearby = false
    for _, src in ipairs(registeredEscorts) do
        local ped = GetPlayerPed(src --[[@as string]])
        if ped and ped ~= 0 then
            local okP, pc = pcall(GetEntityCoords, ped)
            if okP and pc and #(pc - truckCoords) <= ESCORT_PROXIMITY_RADIUS then
                nearby = true
                break
            end
        end
    end

    if not nearby and not rt.escortHalted then
        rt.escortHalted = true
        for _, t in pairs(rt.trucks) do
            if not t.delivered and not t.destroyed and not t.captured and not t.disabled and t.state ~= 'DISABLED' then stopTruck(t) end
        end
        local b = resolveBanner('escortHalted', 'Convoy Halted', 'No police escort is nearby — the convoy has stopped moving. Get close to the trucks to resume.', 6500, 'warn')
        if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
        DiscordLog.appendEvent(rt.id, '⏸️ Convoy halted — no police escort within range')
    elseif nearby and rt.escortHalted then
        rt.escortHalted = false
        local b = resolveBanner('escortResumed', 'Convoy Resuming', 'Police escort detected nearby — the convoy is moving again.', 5000, 'success')
        if b then announceAll(rt, b.title, b.body, b.duration, b.kind) end
        DiscordLog.appendEvent(rt.id, '▶️ Convoy resumed — police escort back in range')
        driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), nil, true)
    end
end

-- OFF case for the same toggle above: instead of leaving an unowned truck
-- (nobody's client close enough to stream/drive it) sitting frozen until
-- someone wanders by, the server itself nudges it in a straight line toward
-- its current target at roughly its configured speed. This can't follow the
-- actual road (the server has no pathfinding of its own) — but that's fine,
-- since by definition nobody is close enough to see it happen; the moment a
-- real client streams it back in and takes over (NetworkGetEntityOwner
-- stops being -1), this stops immediately and the normal road-following AI
-- driving task corrects it back onto the real road within a few seconds.
local function nudgeUnobservedTrucks(rt, tick)
    -- A truck no player is within Config.TruckCullingRadius of has no owner: nothing can drive it (the AI needs a client). It is only advanced
    -- here when TruckScriptMoves or TruckAdvanceUnobserved is on - nobody can see it, and a client taking it over stops this at once.
    if Config.TruckScriptMoves ~= true and Config.TruckAdvanceUnobserved ~= true then return end
    if rt.def.settings.requireEscortProximity ~= false then return end
    if tick % 2 ~= 0 then return end -- nobody can see it either way; every ~2s is plenty
    local column = columnOrder(rt)
    for _, t in ipairs(column) do
        -- A truck parked on a checkpoint is frozen on purpose - it must stay exactly where it stands.
        if t.checkpointParked then goto continue end
        -- NetworkIsPlayerActive is client-only (doesn't exist as a server
        -- native — same class of bug this project has hit before with
        -- IsEntityDead/SetEntityCoordsNoOffset). NetworkGetEntityOwner
        -- already reliably returns -1 server-side the moment no client is
        -- actively simulating the entity, which is exactly the signal
        -- needed here — no extra "is that owner still active" check
        -- required on top of it.
        local owner = NetworkGetEntityOwner(t.entity)
        if owner == -1 then
            -- Every truck (not just the lead) carries its own independent
            -- convoy_target now — see driveColumn — so there's no more
            -- "followers nudge toward the truck ahead" special case needed.
            local target
            local cur = Entity(t.entity).state.convoy_target
            if cur and cur.x then target = cur end
            if target then
                local okC, c = pcall(GetEntityCoords, t.entity)
                if okC then
                    local dx, dy = target.x - c.x, target.y - c.y
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist > 1.0 then
                        -- the truck's own cruise speed (what its drive order would have used), a little under it
                        local speed = math.min(tonumber(target.speed) or (12.0 * (t.speed or 1.0)), 25.0) * 0.85
                        local step = math.min(dist, speed * 2.0) -- ~2s worth of travel this tick
                        local nx = c.x + (dx / dist) * step
                        local ny = c.y + (dy / dist) * step
                        -- height eases from where the truck is to the target's height; jumping straight to the target's
                        -- height dropped a truck 280 m away underground or into the air on hilly road
                        local nz = c.z + ((target.z or c.z) - c.z) * (step / dist)
                        -- atan2(-dx, dy) — see regroupTrucksAtCheckpoint's own
                        -- comment on this exact formula; the previous sign
                        -- order here faced an unobserved nudged truck 180°
                        -- away from the direction it was actually being
                        -- slid in.
                        local heading = math.deg(math.atan(-dx, dy)) % 360
                        pcall(SetEntityCoords, t.entity, nx, ny, nz, false, false, false, false)
                        pcall(SetEntityHeading, t.entity, heading)
                    end
                end
            end
        end
        ::continue::
    end
end

-- Only these point types actually hold the convoy for anything (checkpoint
-- defense, a timed break, an ambush) — everything else (plain ROUTE,
-- NPC_SPAWN) just shapes the path or triggers a spawn and should never
-- interrupt movement. See the "reached" handler above, right before this
-- function gets called on its own thread.
local STOPPING_POINT_TYPES = { CHECKPOINT = true, BREAK = true, AMBUSH = true }

local function handlePointReached(rt, point)
    rt.lastReachedOrder = point.order or rt.lastReachedOrder
    if point.type == 'START' then
        -- Nothing to do here any more — the police head-start buffer
        -- (release/announce/gang-visibility) is now owned entirely by
        -- releaseConvoy/doStart, which holds trucks parked at this exact
        -- point (via rt.releaseHeld) until it fires, so monitor() never even
        -- reaches this point-reached check until the buffer has already
        -- elapsed. Falls through to the shared currentRouteIndex advance below.
    elseif point.type == 'CHECKPOINT' then
        rt.status = 'CHECKPOINT'
        ConvoyManager.setStatus(rt.id, 'CHECKPOINT')
        local cpOk, cpErr = pcall(runCheckpoint, rt, point)
        if not cpOk then
            lib.print.error(('[NovaConvoy] Error in runCheckpoint on convoy #%s: %s'):format(tostring(rt.id), tostring(cpErr)))
        end
        if not active[rt.id] then return end
        rt.checkpointTimeRemaining = 0
        rt.status = 'ACTIVE'
        ConvoyManager.setStatus(rt.id, 'ACTIVE')
    elseif point.type == 'BREAK' then
        runBreak(rt, point)
        if not active[rt.id] then return end
    elseif point.type == 'AMBUSH' then
        runAmbush(rt, point)
    elseif point.type == 'NPC_SPAWN' then
        runNpcSpawnPoint(rt, point)
    elseif point.type == 'DESTINATION' then
        unlockDelivery(rt, point)
        return -- do not advance past the destination
    end

    rt.currentRouteIndex = rt.currentRouteIndex + 1
    persist(rt)
    pcall(sendPoliceRouteZones, rt)
    pcall(sendConvoyProgress, rt)
    local nextPoint = rt.route[rt.currentRouteIndex]
    if point.type == 'CHECKPOINT' and active[rt.id] then
        -- parked trucks leave one at a time, each onto its own route; any truck still on its way keeps its task
        releaseFromCheckpoint(rt)
        if nextPoint and active[rt.id] then
            driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex))
        end
    elseif nextPoint and active[rt.id] then
        driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), nil, true)
    end
end


-- ── main monitor loop ─────────────────────────────────────────────────────────────

-- Police take part in a Convoy automatically: nobody has to press "Join as Escort" any more (the Event Status panel is
-- gang-only). Every online on-duty officer is joined as an escort, an officer who comes on duty mid-run is picked up on
-- the next pass, and the escort cap still applies. Same call the old Join button made, so the relationship group,
-- drive-by, route blips and beacons are all set up exactly as before.
local function autoJoinPolice(rt)
    if rt.def.kind ~= 'CONVOY' then return end
    if tonumber(rt.def.maxPoliceParticipants) == 0 then return end
    local joined = rt.participants and rt.participants.policeIdentifiers
    if not joined then return end
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Bridge.IsPolice(src) then
            local identifier = Bridge.GetIdentifier(src)
            if identifier and not joined[identifier] then
                Runtime.joinPolice(src, rt.id)
            end
        end
    end
end

local function monitor(rt)
    local tick = 0
    CreateThread(function()
        while active[rt.id] do
            Wait(1000)
            if not active[rt.id] then break end
            tick = tick + 1

            if tick % 3 == 1 then
                local jpOk, jpErr = pcall(autoJoinPolice, rt)
                if not jpOk then lib.print.error(('[NovaConvoy] Error auto-joining police: %s'):format(tostring(jpErr))) end
            end
            -- keeps the top-left progress card current for anyone who joined or reconnected since the last change
            if tick % 5 == 0 then pcall(sendConvoyProgress, rt) end

            -- Computed once per tick and reused below — this used to be a
            -- fresh Bridge.GetPlayers() scan inside pollTrucks (capture check),
            -- the blip audience build, and again inside each broadcast*Status
            -- call, i.e. up to 5-6 full player scans a second for one convoy.
            -- Joined escorts only, not every online officer — convoy info/
            -- blips/banners are participant-only on both sides now, same as
            -- gangSrcs below. policeAndAdminSources on top of that so an
            -- admin watching a run (without having formally joined as
            -- escort) still sees the truck blips/checkpoint banners this
            -- feeds, same standing oversight visibility they already get
            -- elsewhere (policeAndAdminSources's own original doc comment).
            local policeSrcs = policeAndAdminSources(rt)
            local gangSrcs = gangParticipantSources(rt)

            local ok, err = pcall(pollTrucks, rt, gangSrcs, tick)
            if not ok then
                lib.print.error(('[NovaConvoy] Error in pollTrucks: %s'):format(tostring(err)))
            end
            if not active[rt.id] then break end

            -- With "Require Police Escort Proximity" OFF the convoy never waits for anyone: a truck no player is close enough to
            -- simulate is slid along by the server (also while heading for a checkpoint or the destination).
            if not rt.releaseHeld and (rt.status == 'CHECKPOINT' or rt.status == 'DELIVERY') then
                local nuOk2, nuErr2 = pcall(nudgeUnobservedTrucks, rt, tick)
                if not nuOk2 then
                    lib.print.error(('[NovaConvoy] Error in nudgeUnobservedTrucks: %s'):format(tostring(nuErr2)))
                end
            end
            if not rt.releaseHeld and rt.status == 'ACTIVE' then
                local epOk, epErr = pcall(checkEscortProximity, rt, policeSrcs)
                if not epOk then
                    lib.print.error(('[NovaConvoy] Error in checkEscortProximity: %s'):format(tostring(epErr)))
                end
                local nuOk, nuErr = pcall(nudgeUnobservedTrucks, rt, tick)
                if not nuOk then
                    lib.print.error(('[NovaConvoy] Error in nudgeUnobservedTrucks: %s'):format(tostring(nuErr)))
                end
            end

            -- Squad health-bar panels (client's Gang/Police Squad UI) only make
            -- sense once trucks are actually moving — showing them while
            -- everyone's still standing around at the staging area (releaseHeld)
            -- is what "the health bar showed up too early" meant. releaseConvoy
            -- sends the first update itself the instant it flips this false, so
            -- this loop just keeps it current from then on.
            -- Was tick % 2 (a 2s-stale window) — halved to every tick since a
            -- health-bar report of "showed 50% right as I died" is exactly
            -- what a couple of seconds of broadcast lag looks like.
            -- pcall matters here every bit as much as it does for pollTrucks
            -- above: these two calls used to run bare, so ANY uncaught error
            -- inside either one (a bad ped handle, a native throwing under
            -- some edge-case state) would silently kill this ENTIRE monitor
            -- thread right here — not just the health bar, but every single
            -- thing after it in this loop (blips, route progression,
            -- checkpoint/destination detection, delivery) for the rest of
            -- this convoy's life, with nothing but a missing health bar to
            -- suggest anything had gone wrong at all.
            if not rt.releaseHeld then
                local hpOk, hpErr = pcall(function()
                    broadcastGangStatus(rt)
                    broadcastPoliceStatus(rt, policeSrcs)
                end)
                if not hpOk then
                    lib.print.error(('[NovaConvoy] Error in broadcastGangStatus/broadcastPoliceStatus: %s'):format(tostring(hpErr)))
                end
            end

            -- broadcast moving blips + floating name/health label to police + gang audience
            local vehicleData = {}
            for _, t in pairs(rt.trucks) do
                if not t.delivered and not t.destroyed and not t.captured and t.entity and DoesEntityExist(t.entity) then
                    local c = GetEntityCoords(t.entity)
                    local maxHealth = math.max(t.maxHealth or Entity(t.entity).state.maxHealth or GetEntityMaxHealth(t.entity), 1)
                    local isBroken = (t.state == 'DISABLED' or t.disabled == true or t.brokenDown == true or GetEntityHealth(t.entity) <= 0)
                    vehicleData[#vehicleData + 1] = {
                        netId = t.netId, coords = { x = c.x, y = c.y, z = c.z },
                        label = TRUCK_ROLE_LABELS[t.role] or Entity(t.entity).state.convoy_truck_label or 'Convoy Truck',
                        healthPct = isBroken and 0 or combinedHealthPct(t.entity, maxHealth, t),
                        state = t.state,
                        disabled = isBroken,
                    }
                end
            end
            -- Joined police escorts get truck blips as soon as they join;
            -- gang participants only once gangVisibilityUnlocked flips true
            -- (see handlePointReached's START delay) — the same grace period
            -- as the public "Convoy Started" banner, so gangs can't get a
            -- live truck fix before police have even had a chance to get
            -- into position. Either way, an officer/gang member who never
            -- actually joined this convoy gets nothing.
            -- Admins/creator-access get the same always-on visibility as
            -- police (policeAndAdminSources) — previously the only way an
            -- admin got truck blips at all was via the gang audience below,
            -- gated behind gangVisibilityUnlocked (only once the convoy has
            -- actually been released and is moving), so an admin watching/
            -- moderating the event saw nothing during the whole pre-release
            -- staging window. Oversight access shouldn't be held to the same
            -- "wait for it" gate gang participants are.
            local audience = {}
            local seenAudience = {}
            for _, s in ipairs(policeAndAdminSources(rt)) do
                audience[#audience + 1] = s
                seenAudience[s] = true
            end
            if rt.gangVisibilityUnlocked then
                for _, s in ipairs(gangSrcs) do
                    if not seenAudience[s] then
                        audience[#audience + 1] = s
                        seenAudience[s] = true
                    end
                end
                -- Also ensure any online player belonging to any registered gang sees the trucks once live
                if rt.def.settings.gangPvp ~= false then
                    for _, s in ipairs(Bridge.GetPlayers()) do
                        if not seenAudience[s] and not Bridge.IsPolice(s) then
                            local g = GangService.GetPlayerGang(s)
                            if g and g.name then
                                audience[#audience + 1] = s
                                seenAudience[s] = true
                            end
                        end
                    end
                end
            end
            notify(audience, 'nova_convoytruck:runtime:updateBlips', vehicleData)

            -- The overall convoy clock — set from the convoy's own Event
            -- Duration field, this is the whole window police have to
            -- escort the trucks all the way to the destination AND finish
            -- delivering, not just a post-arrival grace period. Ticks the
            -- entire time the convoy is actually moving (ACTIVE/CHECKPOINT/
            -- DELIVERY), starting the moment the police head-start buffer
            -- releases it — never while parked/held or already finished.
            -- Paused while escort-halted (see checkEscortProximity) — the
            -- convoy isn't going anywhere, so it shouldn't burn through its
            -- own clock either; that would make "wander off" doubly
            -- punishing (no progress AND the deadline still creeping down).
            if not rt.releaseHeld and not rt.escortHalted and (rt.status == 'ACTIVE' or rt.status == 'CHECKPOINT' or rt.status == 'DELIVERY') then
                rt.deliveryTimeRemaining = rt.deliveryTimeRemaining - 1
                notify(allParticipantSources(rt), 'nova_convoytruck:runtime:deliveryTimer', rt.deliveryTimeRemaining)
                if rt.deliveryTimeRemaining <= 0 then
                    Runtime.finish(rt.id, 'FAILED')
                end
            end
            if not active[rt.id] then break end

            -- Gang's own destination reveal: unlike police (who can already
            -- see it from the moment the convoy departs — see
            -- Config.PoliceAlwaysSeeRouteZones above), gang only learns
            -- where the destination is once a truck is genuinely close to
            -- it, not the instant the convoy starts. Fires once per convoy;
            -- the actual arrival (unlockDelivery, further below) is a
            -- separate, later moment with its own banner.
            if not rt.destinationProximityWarned and not rt.releaseHeld
                and (rt.status == 'ACTIVE' or rt.status == 'CHECKPOINT') then
                local destPoint = findPoint(rt.route, 'DESTINATION')
                if destPoint then
                    local lead, dist2d = closestCargoTruck(rt, destPoint.x, destPoint.y)
                    if lead and dist2d and dist2d <= (Config.DestinationProximityWarningDistance or 250.0) then
                        rt.destinationProximityWarned = true

                        local gb = resolveBanner('destinationProximityGang', 'Almost There', 'Be quick — the trucks will be delivered soon!', 7000, 'warn')
                        if gb then announceGang(rt, gb.title, gb.body, gb.duration, gb.kind) end

                        local pb = resolveBanner('destinationProximityPolice', 'Nice Work', "You've almost got it — safely escort the trucks the rest of the way!", 7000, 'success')
                        if pb then announcePolice(rt, pb.title, pb.body, pb.duration, pb.kind) end

                        -- Destination zone notification: notify police, gang, and admin sources
                        local allDropSources = policeParticipantSources(rt)
                        for _, s in ipairs(gangParticipantSources(rt)) do allDropSources[#allDropSources + 1] = s end
                        notify(allDropSources, 'nova_convoytruck:runtime:dropzone', rt.id, lead.netId, destPoint)
                    end
                end
            end

            -- Airdrop-in-convoy support was removed entirely — see
            -- spawnAirdrop's own removal note above. Airdrops only exist as
            -- the standalone Gang Airdrop event kind now.

            if rt.status == 'ACTIVE' and not rt.releaseHeld and not rt.escortHalted then
                -- Proactive destination check: if any cargo truck has reached the destination area,
                -- activate delivery mode immediately so trucks are delivered without delay.
                local destPoint = findPoint(rt.route, 'DESTINATION')
                if destPoint and not rt.pointInProgress then
                    local destTruck, destDist = closestCargoTruck(rt, destPoint.x, destPoint.y)
                    if destTruck and destTruck.entity and DoesEntityExist(destTruck.entity) then
                        local atDest = destDist <= 35.0 or (destDist <= DELIVERY_NEAR_RADIUS and GetEntitySpeed(destTruck.entity) < 2.0)
                        if atDest then
                            rt.pointInProgress = true
                            CreateThread(function()
                                local ok, err = pcall(handlePointReached, rt, destPoint)
                                if not ok then
                                    print(('[NovaConvoy] handlePointReached destination error on convoy #%s: %s'):format(tostring(rt.id), tostring(err)))
                                end
                                rt.pointInProgress = false
                            end)
                        end
                    end
                end

                local point = rt.route[rt.currentRouteIndex]
                if point and point.type == 'START' then
                    rt.currentRouteIndex = rt.currentRouteIndex + 1
                    point = rt.route[rt.currentRouteIndex]
                end
                if point then
                    -- Pre-spawn an upcoming checkpoint's barricades/decor
                    -- vehicles/police&army guards a couple of route points
                    -- before the trucks actually get there, instead of it all
                    -- popping into existence right as they arrive (see
                    -- ensureCheckpointDressing's own comment above). Only a
                    -- cheap index scan + table lookup, so it's fine to run
                    -- every tick, but throttled anyway since there's no need
                    -- to re-check it every single second.
                    if tick % 5 == 0 then
                        local psOk, psErr = pcall(function()
                            -- the START point's own dressing (guards / props / vehicles around the staging area) is built once, right away:
                            -- the scan below starts AFTER the start point, which the convoy has already left
                            local startPt = findPoint(rt.route, 'START')
                            if startPt then
                                rt.checkpointDressing = rt.checkpointDressing or {}
                                if not rt.checkpointDressing[startPt.id] and not (rt.checkpointDone and rt.checkpointDone[startPt.id]) then
                                    ensureCheckpointDressing(rt, startPt)
                                end
                            end
                            for i = rt.currentRouteIndex, rt.currentRouteIndex + CHECKPOINT_PRESPAWN_LOOKAHEAD do
                                local upcoming = rt.route[i]
                                if upcoming and (upcoming.type == 'CHECKPOINT' or upcoming.type == 'START' or upcoming.type == 'DESTINATION') then
                                    rt.checkpointDressing = rt.checkpointDressing or {}
                                    if not rt.checkpointDressing[upcoming.id] and not (rt.checkpointDone and rt.checkpointDone[upcoming.id]) then
                                        ensureCheckpointDressing(rt, upcoming)
                                    end
                                end
                            end
                        end)
                        if not psOk then
                            lib.print.error(('[NovaConvoy] Error pre-spawning checkpoint dressing on convoy #%s: %s'):format(tostring(rt.id), tostring(psErr)))
                        end
                    end

                    -- Arrival follows whichever truck is actually closest to
                    -- the point, so one truck lagging behind (or stuck) doesn't
                    -- stall a convoy the rest of which has arrived.
                    local truck, dist2d = closestCargoTruck(rt, point.x, point.y)
                    if truck and truck.entity and DoesEntityExist(truck.entity) and not rt.pointInProgress then
                        local reached
                        if point.type == 'DESTINATION' then
                            -- Wider than a checkpoint: road-node pathing often can't
                            -- get a truck right onto a marker placed just off the road,
                            -- and a truck parked as close as it can get counts too.
                            reached = dist2d <= 35.0 or (dist2d <= DELIVERY_NEAR_RADIUS and GetEntitySpeed(truck.entity) < 2.0)
                        else
                            -- cpConfig.radius is the checkpoint's DEFENSE zone size (often
                            -- large, e.g. 80m) — it must not double as the arrival
                            -- threshold, or the convoy stops at the outer ring instead
                            -- of at the marker. Only ever tighter than the generic radius.
                            local cpConfig = point.type == 'CHECKPOINT' and checkpointConfigFor(rt.def, point.id) or nil
                            -- A checkpoint now starts (trucks brake, stop and freeze, then the timer runs) the moment the
                            -- closest truck is inside the checkpoint's own circle, not only within 35 m of the marker.
                            local effRadius = GENERIC_REACH_RADIUS
                            if cpConfig and cpConfig.radius then
                                local cr = tonumber(cpConfig.radius) or GENERIC_REACH_RADIUS
                                if (Config.CheckpointRelease or {}).startInCircle ~= false then
                                    effRadius = math.max(cr, GENERIC_REACH_RADIUS)
                                else
                                    effRadius = math.min(cr, GENERIC_REACH_RADIUS)
                                end
                            end
                            reached = dist2d <= effRadius
                        end
                        if reached then
                            -- handlePointReached can block for a while (checkpoint hold,
                            -- break pause) — run it on its own thread so this monitor loop
                            -- keeps polling truck health/blips the whole time. pointInProgress
                            -- stops it from being kicked off twice for the same point.
                            rt.pointInProgress = true
                            -- Only point types with an actual scripted hold (checkpoint
                            -- defense, a timed break, an ambush) stop the trucks. This used
                            -- to fire for EVERY non-DESTINATION point, including plain ROUTE
                            -- waypoints and NPC_SPAWN markers that exist purely to shape the
                            -- path/trigger a spawn — those have no hold logic at all in
                            -- handlePointReached below, so stopping here just braked the
                            -- whole convoy to a halt and immediately re-tasked it a moment
                            -- later, at literally every waypoint along the route. That's
                            -- exactly the "stopping and moving at each route point"
                            -- stutter — a route with a dozen shaping points meant a dozen
                            -- unnecessary full stops.
                            if STOPPING_POINT_TYPES[point.type] then
                                if point.type ~= 'CHECKPOINT' then
                                    for _, t in pairs(rt.trucks) do stopTruck(t) end
                                end
                                -- Checkpoints: nobody is stopped here. Every truck keeps driving its
                                -- own route onto the marker and parks itself there (runCheckpoint) —
                                -- stopping the first truck 35m short of the marker is what used to
                                -- leave it off the marker and need a teleport.
                            end
                            CreateThread(function()
                                -- pcall: an uncaught error inside handlePointReached used to
                                -- leave rt.pointInProgress stuck true forever, and the whole
                                -- convoy permanently stopped.
                                local ok, err = pcall(handlePointReached, rt, point)
                                if not ok then
                                    print(('[NovaConvoy] handlePointReached error on convoy #%s point %s (%s): %s'):format(tostring(rt.id), tostring(point.id), tostring(point.type), tostring(err)))
                                end
                                rt.pointInProgress = false
                            end)
                        end
                    end
                    if not rt.pointInProgress then
                        driveColumn(rt, resolveDriveTarget(rt, rt.currentRouteIndex), tick)
                        -- Was written but never actually called anywhere — the
                        -- lead truck never eased off for a lagging follower at
                        -- all, no matter how far back the column stretched.
                        -- Reported as "the last truck struggles to catch up,"
                        -- which is exactly what a multi-truck column with no
                        -- cohesion check looks like: each truck only tracks
                        -- the one directly ahead of it, so a gap opened up
                        -- anywhere near the front just keeps compounding all
                        -- the way to the back with nothing ever pulling it
                        -- back in.
                        local ccOk, ccErr = pcall(updateColumnCohesion, rt)
                        if not ccOk then
                            lib.print.error(('[NovaConvoy] Error in updateColumnCohesion: %s'):format(tostring(ccErr)))
                        end
                    end
                end
            elseif rt.status == 'DELIVERY' then
                local dOk, dErr = pcall(checkDeliveries, rt)
                if not dOk then
                    lib.print.error(('[NovaConvoy] Error in checkDeliveries: %s'):format(tostring(dErr)))
                end
                if active[rt.id] then
                    if #survivingCargoTrucks(rt) == 0 then
                        Runtime.finish(rt.id)
                    else
                        -- Keep everyone still out there driving in to the destination.
                        driveColumn(rt, findPoint(rt.route, 'DESTINATION'), tick)
                        local ccOk, ccErr = pcall(updateColumnCohesion, rt)
                        if not ccOk then
                            lib.print.error(('[NovaConvoy] Error in updateColumnCohesion: %s'):format(tostring(ccErr)))
                        end
                    end
                end
            end

            if active[rt.id] and not rt.releaseHeld and not rt.pointInProgress then
                pcall(updateColumnCohesion, rt)
            end
        end
    end)
end

-- ── public API ────────────────────────────────────────────────────────────────────

-- Shared by Runtime.start (player-triggered, access-checked) and
-- Runtime.startScheduled (scheduler-triggered, no player behind it) — every
-- validation and spawn step is identical either way.
-- Lightweight lifecycle for a GANG_AIRDROP-kind event — no trucks/route/
-- checkpoints, so the truck-driving/blip/checkpoint-detection monitor()
-- loop above doesn't apply at all. Just counts down the event's overall
-- duration and ends it once time's up; individual zones run and end
-- themselves independently on their own per-zone timers (spawnAirdropZone)
-- regardless of this overall clock.
local function monitorGangAirdropEvent(rt)
    CreateThread(function()
        local remaining = rt.deliveryTimeRemaining or 1200
        while active[rt.id] == rt and remaining > 0 do
            Wait(1000)
            remaining = remaining - 1
            rt.deliveryTimeRemaining = remaining
            -- Own event, not deliveryTimer — a Gang Airdrop has no
            -- delivery phase at all, and reusing that event fed the same
            -- "MISSION CLOCK // DELIVERY" truck-icon HUD widget into an
            -- event where nothing is ever delivered, which just read as
            -- a mislabeled UI glitch to anyone running one.
            -- Pushed every tick (not just every 5th second) — the HUD has no
            -- local ticking of its own, it just renders whatever the server
            -- last sent, so throttling this produced 5-second jumps
            -- (01:00 -> 00:55 -> 00:50) instead of a real countdown.
            notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:eventTimer', remaining)
        end
        if active[rt.id] == rt then
            -- Every individual zone banners its own landing/expiry, but
            -- nothing ever announced the OVERALL event wrapping up — gangs
            -- had no way to tell "this airdrop op is over" from "there's
            -- just no zone active on my map right now."
            local b = resolveBanner('airdropEventEnded', 'Airdrop Operation Concluded', 'The gang airdrop event has ended — no more supply crates will drop.', 7000, 'info')
            if b then notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind) end
            Runtime.finish(rt.id)
        end
    end)
end

local function calculateStaggeredDelays(zones, totalDuration)
    local n = #zones
    if n == 0 then return end
    local totalSec = math.max(120, tonumber(totalDuration) or 1200)
    if n == 1 then
        zones[1].activationDelay = 60
        zones[1].duration = math.max(120, math.min(600, totalSec - 90))
        return
    end

    local bufferStart = 60 -- 1 min warm-up buffer for gangs to assemble
    local bufferEnd = math.min(600, math.max(120, math.floor(totalSec * 0.15)))
    local usableSec = math.max(60, totalSec - bufferStart - bufferEnd)
    local step = math.floor(usableSec / (n - 1))

    -- The crate lifetime must fit INSIDE the gap between one drop and the
    -- next, otherwise drop #2 lands while drop #1 is still in the air and the
    -- event reads as everything happening at once — which is exactly the
    -- "all zones drop together" report. Capped at 75% of the step so there's
    -- always a real gap, with a floor so a very short step doesn't produce an
    -- absurdly brief drop, and a hard ceiling for sanity.
    local crateDuration = math.max(60, math.min(480, math.floor(step * 0.75)))
    -- If the per-drop lifetime would still outrun the step (many zones crammed
    -- into a short event), stretch the step so drops queue up one-after-another
    -- instead of overlapping. Better to space them out than to run them
    -- simultaneously; the last drop may then finish slightly after the
    -- nominal end, which the expiry sweep already tolerates.
    if crateDuration > step then
        step = crateDuration
    end

    for i, zone in ipairs(zones) do
        zone.activationDelay = bufferStart + (i - 1) * step
        if not zone.duration or zone.duration <= 0 or zone.duration == 300 then
            zone.duration = crateDuration
        end
        -- Guard the case where an admin set an explicit duration that is
        -- itself longer than the gap to the next drop — clamp it to what
        -- actually fits, so an explicitly-tuned event still stays sequential.
        if zone.duration > step and i < n then
            zone.duration = step
        end
    end
end

-- The opposite of the above: every zone opens at the same instant and runs
-- for the same lifetime. This is the deliberate "simultaneous drops" mode —
-- several crates on the map at once, so gangs have to split up and choose
-- which to contest, rather than racing a single queue.
local function calculateSimultaneousDelays(zones, totalDuration)
    local n = #zones
    if n == 0 then return end
    local totalSec = math.max(120, tonumber(totalDuration) or 1200)
    -- One shared warm-up, then everything opens together. Lifetime is most of
    -- the event so a simultaneous drop isn't already expiring while gangs are
    -- still mustering, but still leaves a close-out window at the end.
    local delay = 60
    local crateDuration = math.max(120, math.min(600, totalSec - 150))
    for _, zone in ipairs(zones) do
        zone.activationDelay = delay
        if not zone.duration or zone.duration <= 0 or zone.duration == 300 then
            zone.duration = crateDuration
        end
    end
end

-- Placement mode for an event's drop zones.
--   'SEQUENTIAL' (default) — one drop at a time, queued across the event.
--   'SIMULTANEOUS'          — every zone opens at once.
-- An admin can also set explicit per-zone timings to opt out of either and
-- drive the schedule entirely by hand (see zonesHaveManualTimes).
local function airdropPlacementMode(zones, def)
    local mode = def and def.settings and def.settings.airdropPlacement
    if mode == 'SIMULTANEOUS' or mode == 'SEQUENTIAL' or mode == 'MANUAL' then return mode end
    -- Back-compat: a zone explicitly marked simultaneous wins when no event
    -- level mode has been chosen yet.
    for _, z in ipairs(zones) do
        if z.simultaneous == true then return 'SIMULTANEOUS' end
    end
    return 'SEQUENTIAL'
end

-- True when the zones carry no MEANINGFUL hand-tuned timing — i.e. every
-- activationDelay is equal (typically all sitting on the default) AND at
-- most one zone has an explicitly non-default duration. Compared to the old
-- "all delays identical" test, this keeps auto-staggering active after an
-- admin tweaks a single zone's duration, instead of silently dropping back
-- to "every drop at the same time".
local function zonesNeedAutoStagger(zones)
    local first = zones[1]
    if not first then return false end
    local firstDelay = first.activationDelay or 0
    local customDurations = 0
    for i, z in ipairs(zones) do
        if (z.activationDelay or 0) ~= firstDelay then return false end
        if i > 1 and z.duration and z.duration > 0 and z.duration ~= 300 then
            customDurations = customDurations + 1
        end
    end
    return customDurations == 0
end

-- GANG_AIRDROP kind: skips every truck/route/checkpoint requirement and
-- system entirely — just needs at least one configured drop zone. See
-- doStart's branch below for where this is dispatched from.
local function doStartGangAirdrop(savedDef, convoyId, starterSource)
    -- The run works on its OWN copy of the event. `savedDef` is the live saved definition (ConvoyManager's cache), and
    -- ConvoyManager.setStatus below writes that object back to the database: randomising or re-timing the zones in place
    -- used to overwrite the zones the admin had placed with the random ones, so every later run (and the editor) kept the
    -- random spots and the airdropCount, however the toggle was set.
    local def = {}
    for k, v in pairs(savedDef) do def[k] = v end
    def.settings = {}
    for k, v in pairs(savedDef.settings or {}) do def.settings[k] = v end
    def.airdropZones = {}
    for i, z in ipairs(savedDef.airdropZones or {}) do
        local copy = {}
        for k, v in pairs(z) do copy[k] = v end
        def.airdropZones[i] = copy
    end

    local shouldRandomize = def.settings.randomizeLocations == true
    print(('[NovaConvoy][Airdrop] start #%s: randomizeLocations=%s, %d saved zone(s), airdropCount=%s'):format(
        tostring(convoyId), tostring(shouldRandomize), #def.airdropZones, tostring(def.settings.airdropCount)))
    -- RANDOM RUN: the zones are picked from the ones the admin placed (airdropCount of them, never more than exist), in a random
    -- order — the zones' own spots, guards, rewards and props are all kept. The preset San Andreas list is NOT used for this any more;
    -- it only feeds the editor's Generate / Auto-Add buttons. (Only an event with no zone of its own falls back to the preset list below,
    -- so a run is never empty.) The saved event is never touched: this works on the run's own copy.
    local pickedOwn = false
    savedDef._activeZoneIds = nil
    if shouldRandomize then
        local own = {}
        for _, z in ipairs(def.airdropZones) do
            if z.enabled ~= false and tonumber(z.x) and tonumber(z.y) then own[#own + 1] = z end
        end
        if #own > 0 then
            for i = #own, 2, -1 do
                local j = math.random(i)
                own[i], own[j] = own[j], own[i]
            end
            local count = math.max(1, math.min(math.floor(tonumber(def.settings.airdropCount) or #own), #own))
            local picked, ids, names = {}, {}, {}
            for i = 1, count do
                picked[i] = own[i]
                ids[own[i].id] = true
                names[#names + 1] = tostring(own[i].name or own[i].id)
            end
            def.airdropZones = picked
            pickedOwn = true
            -- the props of the zones that were not picked must not stand around an empty spot (read by EventProps.start)
            savedDef._activeZoneIds = ids
            print(('[NovaConvoy][Airdrop] random run #%s: %d of %d zone(s), in this order: %s'):format(tostring(convoyId), count, #own, table.concat(names, ' > ')))
        end
    end
    if shouldRandomize and not pickedOwn and AirdropLocations then
        local count = tonumber(def.settings.airdropCount) or (def.airdropZones and #def.airdropZones > 0 and #def.airdropZones) or 10
        local sampledLocs = AirdropLocations.Sample(count)
        if sampledLocs and #sampledLocs > 0 then
            local baseZone = (def.airdropZones and def.airdropZones[1]) or {}
            -- the editor's Main settings (guards + rewards) win over any single zone: the spots are random, so no zone is "the" zone
            local main = def.settings and type(def.settings.airdropMain) == 'table' and def.settings.airdropMain or nil
            local randomizedZones = {}
            for i, loc in ipairs(sampledLocs) do
                local timing = (def.airdropZones and def.airdropZones[i]) or baseZone
                local base = main or timing
                randomizedZones[#randomizedZones + 1] = {
                    id = ('rand_drop_%s_%d'):format(tostring(convoyId), i),
                    name = loc.name or ('Drop Zone ' .. i),
                    label = loc.label or ('Drop Zone ' .. i),
                    x = loc.x,
                    y = loc.y,
                    z = loc.z,
                    enabled = true,
                    announce = timing.announce ~= false,
                    activationDelay = timing.activationDelay or 60,
                    duration = timing.duration or 300,
                    guardCount = base.guardCount or 3,
                    guardModel = base.guardModel or 'g_m_y_lost_01',
                    guardWeapon = base.guardWeapon or 'WEAPON_MICROSMG',
                    guardAggressiveness = base.guardAggressiveness or 'medium',
                    requireLockpick = base.requireLockpick ~= false,
                    lockpicksRequired = base.lockpicksRequired,
                    chance = base.chance or 60,
                    rewards = base.rewards or (Config.Airdrop and Config.Airdrop.defaultRewards) or { { type = 'MONEY', amount = 500 } },
                }
            end
            def.airdropZones = randomizedZones
        end
    end

    if not def.airdropZones or #def.airdropZones == 0 then
        return false, 'Add at least one airdrop zone before starting.'
    end

    -- Never enable vehicle drive-by for airdrop events
    if def.settings then
        def.settings.forceDriveBy = false
    end

    -- Decide how the drops are spaced. SEQUENTIAL (default) queues them one
    -- after another across the event; SIMULTANEOUS opens every zone at once so
    -- gangs have to split up; MANUAL uses the admin's explicit per-zone
    -- timings verbatim. Previously this was an implicit "all delays identical"
    -- check that silently disabled staggering the moment one zone was edited.
    local placement = airdropPlacementMode(def.airdropZones, def)
    if placement == 'SIMULTANEOUS' then
        calculateSimultaneousDelays(def.airdropZones, def.eventDuration)
    elseif placement == 'MANUAL' then
        -- leave the admin's own activationDelay/duration exactly as configured
    elseif zonesNeedAutoStagger(def.airdropZones) or pickedOwn then
        -- a random run re-times the picked zones in their new order (the saved delays belonged to the full list in its own order)
        calculateStaggeredDelays(def.airdropZones, def.eventDuration)
    end

    local startedByName = 'Automated Schedule'
    if starterSource and starterSource > 0 then
        local pName = Bridge.GetPlayerName(starterSource)
        local pIdent = Bridge.GetIdentifier(starterSource)
        startedByName = ('%s (%s)'):format(pName or 'Admin', pIdent or 'N/A')
    end

    local rt = {
        id = convoyId, def = def, route = {}, status = 'ACTIVE',
        currentRouteIndex = 1, checkpointTimeRemaining = 0, pointInProgress = false,
        deliveryTimeRemaining = def.eventDuration or 1200,
        trucks = {}, airdrops = {}, startedAt = os.time(),
        startedByName = startedByName,
        participants = { identifiers = {}, gangCounts = {}, policeIdentifiers = {}, names = {} },
        gangVisibilityUnlocked = true,
    }

    active[convoyId] = rt
    ConvoyManager.setStatus(convoyId, 'ACTIVE')
    persist(rt)

    for _, zone in ipairs(def.airdropZones) do
        spawnAirdropZone(rt, zone)
    end
    monitorGangAirdropEvent(rt)

    local audience = airdropCaptureAudience(rt)
    -- 'AIRDROP': without it the clock opened as the Convoy "MISSION CLOCK // DELIVERY" for a second, until the first airdrop tick named it
    notify(audience, 'nova_convoytruck:runtime:startDeliveryTimer', rt.deliveryTimeRemaining, 'AIRDROP')

    for _, s in ipairs(Bridge.GetPlayers()) do
        if Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) or Bridge.HasCreatorAccess(s) then
            TriggerClientEvent('nova_convoytruck:gang:toast', s, '📦', 'Airdrop Event Active', ('"%s" is now live across %d zone(s).'):format(def.name, #def.airdropZones), false)
        end
    end

    local b = resolveBanner('airdropEventStarted', 'GANG AIRDROP: ' .. def.name, 'A gang airdrop event is now live across %d drop zone(s) — get out there and start looting!', 8000, 'start', #def.airdropZones)
    if b then announceServerWide(rt, b.title, appendAnnounceExtras(def.settings, b.body), b.duration, b.kind) end

    local startFields = {
        { name = 'Operation', value = def.name, inline = true },
        { name = 'Type', value = 'Gang Supply Airdrop', inline = true },
        { name = 'Started By', value = startedByName, inline = true },
        { name = 'Drop Zones', value = tostring(#def.airdropZones), inline = true },
        { name = 'Duration', value = ('%dm'):format(math.floor((def.eventDuration or 1200) / 60)), inline = true },
        { name = 'Eligibility', value = 'All Active Gangs (Open World)', inline = true },
    }
    DiscordLog.startEvent(convoyId, ('📦 Gang Airdrop Event — %s'):format(def.name), 0x8b5cf6, def.shortDescription or 'Supply drops are arriving across the state. Defeat guards and secure crates!', startFields)
    DiscordLog.appendEvent(convoyId, ('📦 Gang Airdrop Event "%s" active across %d zones (Started by: %s)'):format(def.name, #def.airdropZones, startedByName))

    return true, def
end

-- ── Hot Cargo Run (HOT_CARGO kind) ───────────────────────────────────────────────

local function getAliveGuardsCount(guardsList)
    local alive = 0
    for _, g in ipairs(guardsList or {}) do
        if g.ped and DoesEntityExist(g.ped) and GetEntityHealth(g.ped) > 0 then
            alive = alive + 1
        end
    end
    return alive
end

-- Standing spots for a Hot Cargo guard detail around a point. The old code dropped each guard at a random angle and distance from the
-- point at the SAME height: on a slope or a kerb that left guards floating or buried, several could land on one spot, and around a
-- truck they could land INSIDE the trailer behind it (the trailer is coupled 9 m behind the cab and is ~14 m long). Here the guards
-- are spread evenly on a ring, never closer than 1.8 m to each other, never inside the truck + trailer strip (when a truck heading is
-- given), and each one faces outward, away from what it guards. Every guard gets the same height as the point; the client puts it on
-- the real ground when it takes the guard in hand (see the 'guard' task in npc_relationships.lua).
local function hotCargoGuardSpots(center, count, rMin, rMax, truckHeading, trailerLen)
    local spots = {}
    local fx, fy
    if truckHeading then
        local rad = math.rad(truckHeading)
        fx, fy = -math.sin(rad), math.cos(rad)   -- the truck's forward vector (GTA heading convention)
    end
    local function free(x, y)
        for _, s in ipairs(spots) do
            if (s.x - x) ^ 2 + (s.y - y) ^ 2 < 1.8 * 1.8 then return false end
        end
        if fx then
            local dx, dy = x - center.x, y - center.y
            local along = dx * fx + dy * fy            -- + in front of the cab, - back along the trailer
            local side = math.abs(dx * fy - dy * fx)   -- distance from the truck's centre line
            if along > -(trailerLen or 16.5) and along < 4.5 and side < 2.8 then return false end
        end
        return true
    end
    for i = 1, count do
        local placed
        for try = 1, 16 do
            -- the first tries keep to the even ring; later ones wander further round and out
            local angle = ((i - 1) / count) * 2 * math.pi + (math.random() - 0.5) * (try <= 4 and 0.6 or 3.0)
            local dist = rMin + math.random() * (rMax - rMin) + (try > 8 and 3.0 or 0.0)
            local x, y = center.x + math.cos(angle) * dist, center.y + math.sin(angle) * dist
            if free(x, y) then
                placed = { x = x, y = y, z = center.z, heading = math.deg(math.atan(-(x - center.x), (y - center.y))) % 360.0 }
                break
            end
        end
        if not placed then   -- very crowded: take the ring spot anyway, a little further out
            local angle = ((i - 1) / count) * 2 * math.pi
            local dist = rMax + 4.0
            local x, y = center.x + math.cos(angle) * dist, center.y + math.sin(angle) * dist
            placed = { x = x, y = y, z = center.z, heading = math.deg(math.atan(-(x - center.x), (y - center.y))) % 360.0 }
        end
        spots[#spots + 1] = placed
    end
    return spots
end

-- Both guard details (the dropoff's and the truck's) are spawned by the SAME routine the airdrop guards use (NpcManager.spawnAmbushers):
-- full health and armour, mission-entity (not auto-deleted), tagged so the start-up sweep can find leftovers, a retry if a spot is
-- blocked, weapon check, relationship group, guard + combat tasks. The hand-written copies lacked most of that.
local function spawnHotCargoGuardDetail(zone, coords, spots, groupName, shootAnyone)
    return NpcManager.spawnAmbushers(coords, #spots, {
        model = zone.guardModel or 'g_m_y_salvagoon_01',
        weapon = zone.guardWeapon or 'WEAPON_CARBINERIFLE',
        aggressiveness = zone.guardAggressiveness or 'high',
        groupName = groupName,
        hostile = shootAnyone,
        positions = spots,
    })
end

local function spawnHotCargoDropoffGuards(rt, dropZone)
    if not dropZone or not dropZone.guardCount or tonumber(dropZone.guardCount) <= 0 then return end
    rt.dropoffGuards = rt.dropoffGuards or {}
    if rt.dropoffGuards[dropZone.id] then return end

    local count = math.min(10, math.max(1, tonumber(dropZone.guardCount) or 0))
    local coords = vector3(dropZone.x, dropZone.y, dropZone.z)
    local shootAnyone = dropZone.shootAnyone ~= false
    -- Dedicated groups, not the shared nova_convoy_ambush/nova_convoy_npc: those hate other NPC factions by design (see
    -- npc_relationships.lua "4c"), so unrelated NPCs wandering into range used to fight Hot Cargo's own guards.
    local groupName = shootAnyone and 'nova_convoy_hotcargo_hostile' or 'nova_convoy_hotcargo_selective'

    -- marked first so a second tick can never start a second batch while this one is still being created
    rt.dropoffGuards[dropZone.id] = {}
    local spots = hotCargoGuardSpots(coords, count, 6.0, 14.0)
    local spawned = spawnHotCargoGuardDetail(dropZone, coords, spots, groupName, shootAnyone) or {}
    rt.dropoffGuards[dropZone.id] = spawned
    do
        local guardNetIds = {}
        for _, g in ipairs(spawned) do
            if g.netId and g.netId > 0 then guardNetIds[#guardNetIds + 1] = g.netId end
        end
        if #guardNetIds > 0 then
            local revealRadius = tonumber((Config.HotCargoTheft or {}).guardBlipRevealRadius) or 60.0
            notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:hotCargoGuardZone', 'drop_' .. tostring(dropZone.id), coords, revealRadius, guardNetIds)
        end
    end
    DiscordLog.appendEvent(rt.id, ('🛡️ [DROPOFF DEFENSE] %d hostile guards spawned at dropoff destination "%s" (Perimeter: Shoot Anyone)'):format(#spawned, dropZone.name or 'Dropoff'))
end

-- Guards posted directly on the truck at its spawn/search location — the
-- GTA Online "guarded vehicle" pattern (Sightseer/cargo-style contact
-- missions): a knot of hostile NPCs standing right by the vehicle that have
-- to be cleared before it's safe to walk up and lockpick it, rather than the
-- truck just sitting there undefended. Same shape/behavior as
-- spawnHotCargoDropoffGuards just above (guardCount/guardWeapon/guardModel/
-- guardAggressiveness/shootAnyone on the spawn zone itself), just a tighter
-- ring since they're clustered on a vehicle, not covering an open drop point.
-- Cleared the moment the truck is actually hijacked (see HC.setOwner) — once
-- someone's cracked it open and driven off, standing guards at the empty
-- spawn point would make no sense.
local function spawnHotCargoVehicleGuards(rt, truckId, zone, coords, truckHeading)
    if not zone or not zone.guardCount or tonumber(zone.guardCount) <= 0 then return end
    rt.spawnGuards = rt.spawnGuards or {}
    if rt.spawnGuards[truckId] then return end

    local count = math.min(10, math.max(1, tonumber(zone.guardCount) or 0))
    local shootAnyone = zone.shootAnyone ~= false
    -- Same dedicated-group fix as spawnHotCargoDropoffGuards above.
    local groupName = shootAnyone and 'nova_convoy_hotcargo_hostile' or 'nova_convoy_hotcargo_selective'

    rt.spawnGuards[truckId] = {}
    -- a ring around the cab, kept OUT of the strip the truck and its trailer occupy (the trailer sits 9 m behind the cab)
    local spots = hotCargoGuardSpots(coords, count, 6.0, 10.0, truckHeading, 16.5)
    local spawned = spawnHotCargoGuardDetail(zone, coords, spots, groupName, shootAnyone) or {}
    rt.spawnGuards[truckId] = spawned
    do
        local guardNetIds = {}
        for _, g in ipairs(spawned) do
            if g.netId and g.netId > 0 then guardNetIds[#guardNetIds + 1] = g.netId end
        end
        if #guardNetIds > 0 then
            local revealRadius = tonumber((Config.HotCargoTheft or {}).guardBlipRevealRadius) or 60.0
            notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:hotCargoGuardZone', 'truck_' .. tostring(truckId), coords, revealRadius, guardNetIds)
        end
    end
    DiscordLog.appendEvent(rt.id, ('🛡️ [CARGO GUARD] %d hostile guards posted on Cargo Truck at "%s"'):format(#spawned, zone.name or 'Spawn Zone'))
end

-- Shared teardown for a truck's own spawn-point guards — called once it's no
-- longer defended-by-guards territory (hijacked, disabled, or the run ends).
local function clearHotCargoVehicleGuards(rt, truckId)
    if rt.spawnGuards and rt.spawnGuards[truckId] then
        NpcManager.cleanup(rt.spawnGuards[truckId])
        rt.spawnGuards[truckId] = nil
        notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:hotCargoGuardZoneRemove', 'truck_' .. tostring(truckId))
    end
end

-- Truck condition 0–100. This is the SAME computation the on-screen truck health
-- card does (client: GetEntityHealth / the maxHealth state bag, floored), so the
-- percentage a player saw is the percentage their reward is based on — there is
-- no separate or "fake" value. Only the truck counts; its towed trailer has no
-- health. Falls back to the last healthy reading if the entity can't be read
-- at this exact moment.
function Runtime.hotCargoHealthPct(t)
    if t and t.entity and DoesEntityExist(t.entity) then
        local health = GetEntityHealth(t.entity)
        local maxH = tonumber(Entity(t.entity).state.maxHealth) or t.maxHealth
        if not maxH or maxH <= 0 then
            local okM, m = pcall(GetEntityMaxHealth, t.entity)
            maxH = (okM and m and m > 0) and m or 1000
        end
        if health and health > 0 then
            local pct = combinedHealthPct(t.entity, maxH, t)
            t.lastHealthPct = pct
            return pct
        end
    end
    return (t and t.lastHealthPct) or 100
end

handleHotCargoDelivered = function(rt, t, dropZone, coords)
    if not t or t.delivered then return end
    t.delivered = true
    rt.hotCargoDelivered = true
    rt.hotCargoDeliveredCount = (rt.hotCargoDeliveredCount or 0) + 1

    -- Truck condition AT THE MOMENT OF DELIVERY — must be read now, before the
    -- truck entity is deleted a few lines down. The reward below is based on it.
    local conditionPct = Runtime.hotCargoHealthPct(t)

    -- Clean up any dropoff guards defending this dropoff zone
    if rt.dropoffGuards and rt.dropoffGuards[dropZone.id] then
        NpcManager.cleanup(rt.dropoffGuards[dropZone.id])
        rt.dropoffGuards[dropZone.id] = nil
        notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:hotCargoGuardZoneRemove', 'drop_' .. tostring(dropZone.id))
    end

    -- Delivering operative (whoever's physically behind the wheel right now,
    -- purely for the "delivered by" narrative) resolved separately from
    -- delivery CREDIT, which always belongs to the truck's original hijacking
    -- gang (t.ownerGang) — never to whoever happens to be driving at the
    -- exact moment it crosses the dropoff line. Without this split, a rival
    -- gang that jumped into an already-unlocked truck near the end (see
    -- HC.setOwner) and coincidentally drove it into the zone would steal the
    -- delivery credit from the gang that actually did the hijacking and
    -- doesn't even have the destination.
    local driverSrc = t.driverSource
    if t.entity and DoesEntityExist(t.entity) then
        local p = GetPedInVehicleSeat(t.entity, -1)
        if p and p ~= 0 then
            for _, s in ipairs(Bridge.GetPlayers()) do
                if GetPlayerPed(s) == p then driverSrc = s break end
            end
        end
    end

    local gangName = t.ownerGang or (driverSrc and GangService.GetPlayerGang(driverSrc) and GangService.GetPlayerGang(driverSrc).name) or 'independent'
    local gangLabel = t.ownerGangLabel or (driverSrc and Bridge.GetPlayerName(driverSrc)) or 'Independent Operatives'
    local driverName = (driverSrc and Bridge.GetPlayerName(driverSrc)) or (t.driverName or 'Operative')
    local driverIdent = (driverSrc and Bridge.GetIdentifier(driverSrc)) or (t.driverIdentifier or 'N/A')

    local winningMembers = {}
    if gangName and gangName ~= 'none' and gangName ~= 'independent' then
        for _, s in ipairs(Bridge.GetPlayers()) do
            local pGang = GangService.GetPlayerGang(s)
            if pGang and pGang.name == gangName then
                local ident = Bridge.GetIdentifier(s)
                local pName = Bridge.GetPlayerName(s)
                winningMembers[ident] = { source = s, name = pName, identifier = ident, gang = gangName, gangLabel = gangLabel }
            end
        end
    end
    if driverIdent and driverIdent ~= 'N/A' then
        winningMembers[driverIdent] = winningMembers[driverIdent] or { source = driverSrc, name = driverName, identifier = driverIdent, gang = gangName, gangLabel = gangLabel }
    end

    rt.winningGang = gangName
    rt.winningGangLabel = gangLabel
    rt.winningMembers = winningMembers

    -- Per-gang delivery tally — rt.winningGang above gets OVERWRITTEN by
    -- each new delivery (only remembers the last one), which is fine for
    -- the PDF's "who delivered" narrative but silently lost every earlier
    -- gang's delivery when more than one truck was spawned and different
    -- gangs each delivered one. This accumulates instead, so every gang
    -- that actually delivered a truck keeps its own credit — mirrors
    -- rt.gangCaptureCounts (Convoy) and the per-zone credit Gang Airdrop
    -- already does.
    if gangName and gangName ~= 'none' and gangName ~= 'independent' then
        rt.gangDeliveryCounts = rt.gangDeliveryCounts or {}
        rt.gangDeliveryCounts[gangName] = (rt.gangDeliveryCounts[gangName] or 0) + 1
    end

    -- Despawn contraband truck (and its towed trailer, if any)
    local vehNet = t.netId
    if t.entity and DoesEntityExist(t.entity) then
        DeleteEntity(t.entity)
    end
    if t.trailerEntity and DoesEntityExist(t.trailerEntity) then
        DeleteEntity(t.trailerEntity)
    end
    TriggerClientEvent('nova_convoytruck:runtime:cleanupTruck', -1, vehNet)

    -- Spawn unlocked physical reward crate prop (xm_prop_x17_case_01)
    local propModel = joaat('xm_prop_x17_case_01')
    local prop = nil
    if CreateObjectNoOffset then
        prop = CreateObjectNoOffset(propModel, coords.x, coords.y, coords.z, true, true, false)
    else
        prop = CreateObject(propModel, coords.x, coords.y, coords.z, true, true, false)
    end
    -- PlaceObjectOnGroundProperly is a CLIENT-only native — calling it here
    -- unguarded threw "attempt to call a nil value" every single delivery
    -- (confirmed in fxserver.log), which is why the reward crate never
    -- actually settled onto the ground properly. Same fix shape as
    -- spawnParachutingCrate/spawnAirdropZone elsewhere in this file: ask a
    -- real client (already streamed in near the drop) to do the ground
    -- query and report back, since the server has no collision data to do
    -- it itself.
    local propNetId = 0
    if prop and prop ~= 0 and DoesEntityExist(prop) then
        propNetId = NetworkGetNetworkIdFromEntity(prop)
        local snapSrc = nearestPlayerSource(coords, driverSrc and { driverSrc } or nil)
        if snapSrc and propNetId and propNetId > 0 then
            local ok, result = pcall(lib.callback.await, 'nova_convoytruck:runtime:snapPropToGround', snapSrc, { netId = propNetId })
            if ok and type(result) == 'table' and result.ok and tonumber(result.z) then
                SetEntityCoords(prop, coords.x, coords.y, tonumber(result.z), false, false, false, false)
            end
        end
        FreezeEntityPosition(prop, true)
    end

    local stashId = ('convoy_hotcargo_%d_%s'):format(rt.id, t.id)
    t.stashId = stashId
    -- Tag the reward crate so the global "Search Loot Crate" ox_target prompt (matched
    -- on state bags, not prop model — see runtime_client.lua) shows on it.
    if prop and prop ~= 0 and DoesEntityExist(prop) then
        Entity(prop).state:set('convoy_stash_id', stashId, true)
        Entity(prop).state:set('convoy_id', rt.id, true)
        -- Survives the end-of-event entity sweep (purgeRuntimeEntities) — the sentry thread removes it after 60 min.
        Entity(prop).state:set('convoy_keep', true, true)
    end
    t.lockUnlocked = true -- Unlocked! No lockpick/hack minigame required.
    t.propEntity = prop
    t.netId = propNetId
    rt.dropStashId = stashId
    rt.dropCoords = coords

    -- Register stash and grant rewards
    Inventory.RegisterStash(stashId, ('Hot Cargo — %s'):format(gangLabel), tonumber(Config.HotCargoStashSlots) or 100, tonumber(Config.HotCargoStashWeight) or 300000, coords)
    local rewardsGiven = 0

    -- The reward configured in the form is the MAXIMUM, paid at 100% truck
    -- condition. What actually goes in the crate is that amount scaled by the
    -- truck's real health on arrival (e.g. $50,000 at 20% → $10,000). The truck's
    -- own "Truck Delivery Reward" wins when set; otherwise the event-level reward.
    local hcCfg = Config.HotCargoTheft or {}
    local scale = (hcCfg.rewardScalesWithHealth ~= false) and (conditionPct / 100) or 1.0
    local baseRewards = (t.deliveryReward and #t.deliveryReward > 0) and t.deliveryReward or (rt.def.reward or {})
    local moneyItem = Config.DefaultMoneyItem or 'black_money'
    if not Inventory.ItemExists(moneyItem) then
        if Inventory.ItemExists('cash') then moneyItem = 'cash'
        elseif Inventory.ItemExists('money') then moneyItem = 'money' end
    end
    local paidRewards = {} -- what really went into the crate, for the player's reward card
    for _, r in ipairs(baseRewards) do
        if r.type == 'ITEMS' and r.pool and r.pool ~= '' then
            local count = tonumber(r.amount) or 1
            if scale < 1.0 and hcCfg.scaleItemRewards ~= false then
                count = scale > 0 and math.max(1, math.floor(count * scale + 0.5)) or 0
            end
            if count > 0 then
                Inventory.AddItem(stashId, r.pool, count, {
                    description = ('Hot Cargo Contraband — Secured by %s'):format(gangLabel),
                    novaConvoyOrigin = { convoyId = rt.id, kind = 'HOT_CARGO', gang = gangName },
                })
                rewardsGiven = rewardsGiven + 1
                paidRewards[#paidRewards + 1] = { type = 'ITEMS', pool = r.pool, amount = count }
            end
        elseif r.type == 'MONEY' and (r.amount or 0) > 0 then
            local amount = math.floor((tonumber(r.amount) or 0) * scale + 0.5)
            if amount > 0 and Inventory.ItemExists(moneyItem) then
                Inventory.AddItem(stashId, moneyItem, amount)
                rewardsGiven = rewardsGiven + 1
                paidRewards[#paidRewards + 1] = { type = 'MONEY', amount = amount }
            end
        end
    end

    -- Gang XP is not something that can sit in a crate: it goes straight to the securing gang's XP ledger (and each
    -- member's own history), scaled by the truck's condition exactly like the money and items above. Civilians who
    -- happened to be in the crew earn nothing — GangXP resolves membership server-side.
    do
        local xpTotal = 0
        for _, r in ipairs(baseRewards) do
            if string.upper(tostring(r.type or '')) == 'GANG_XP' then
                xpTotal = xpTotal + math.floor((tonumber(r.amount) or 0) * scale + 0.5)
            end
        end
        if xpTotal > 0 then
            local xpRecipients = {}
            for _, m in pairs(winningMembers) do
                if m.source and GetPlayerName(m.source) then xpRecipients[#xpRecipients + 1] = m.source end
            end
            RewardService.PayGangXp(xpRecipients, xpTotal, 'HotCargoDelivered', {
                convoyId = rt.id, convoyName = rt.def.name, runId = rt.startedAt, xpPhase = ('delivery:%s'):format(tostring(t.id)),
            }, {
                event = 'hotcargo', title = 'HOT CARGO COMPLETED', name = rt.def.name, group = ('delivery:%s:%s'):format(rt.id, t.id),
            })
        end
    end

    if rewardsGiven == 0 and Config.CapturedTruckLoot and Config.CapturedTruckLoot.items then
        for _, item in ipairs(Config.CapturedTruckLoot.items) do
            Inventory.AddItem(stashId, item.item, item.count or 1)
        end
    end

    -- Tell clients loot crate is accessible (unlocked)
    if propNetId ~= 0 then
        TriggerClientEvent('nova_convoytruck:runtime:truckLootable', -1, propNetId, stashId, rt.id, true)
    end

    -- Reward card for the gang that secured it — shown only to those members.
    do
        local recipients = {}
        for _, m in pairs(winningMembers) do
            if m.source and GetPlayerName(m.source) then recipients[#recipients + 1] = m.source end
        end
        local lines = RewardService.CardLines(paidRewards, moneyItem == 'black_money' and 'black_money' or 'cash')
        if #recipients > 0 and #lines > 0 then
            RewardService.Announce(recipients, {
                event = 'hotcargo', title = 'HOT CARGO COMPLETED', name = rt.def.name,
                group = ('delivery:%s:%s'):format(rt.id, t.id),
                stats = { { label = 'Truck Condition', value = conditionPct .. '%', tone = conditionPct <= 30 and 'danger' or conditionPct <= 60 and 'warn' or 'ok' } },
                rewards = lines,
                note = (scale < 1.0) and 'Reward is based on the truck\'s condition on arrival. Collect it from the reward crate at the drop site.' or 'Collect it from the reward crate at the drop site.',
            })
        end
    end

    -- Delivery record for the Discord summary and the PDF: which truck, who, in what condition, what the crate really held
    do
        local truckNum = tonumber(tostring(t.id):match('(%d+)$')) or 1
        local paidText = RewardService.describeRewards(paidRewards)
        rt.deliveryLog = rt.deliveryLog or {}
        rt.deliveryLog[#rt.deliveryLog + 1] = {
            truckNum = truckNum, gang = gangName, gangLabel = gangLabel, driver = driverName, identifier = driverIdent,
            conditionPct = conditionPct, rewards = paidText, scaled = scale < 1.0,
            timestamp = os.time(), timeStr = os.date('!%H:%M:%S', os.time()),
        }
        -- the crate's contents are not paid to a player, so they get their own ledger line (the members' Gang XP is logged by PayGangXp)
        RewardService.RecordPayout(rt.id, {
            kind = ('Hot Cargo crate (%d%% condition)'):format(conditionPct), player = ('Reward crate - Truck #%d'):format(truckNum),
            identifier = 'crate:' .. tostring(t.id), gang = gangLabel, text = paidText,
        })
    end

    DiscordLog.appendEvent(rt.id, ('🏆 [CARGO DELIVERED] %s (%s) safely delivered the contraband vehicle at %d%% condition! Unlocked reward crate dropped (%s).'):format(driverName, gangLabel, conditionPct, RewardService.describeRewards(paidRewards)))
    DB.insertConvoyEvent(rt.id, 'HOT_CARGO_DELIVERED', {
        gangName = gangName,
        gangLabel = gangLabel,
        playerIdentifier = driverIdent,
        playerName = driverName,
        detail = ('Delivered contraband truck to %s. Unlocked reward crate dropped.'):format(dropZone.name or 'Dropoff Zone'),
    })

    local b = resolveBanner('hotCargoSecured', 'HOT CARGO SECURED', '%s delivered the contraband shipment! Loot crate dropped at the delivery site. Protected by server rules for 60 minutes.', 9000, 'success', gangLabel)
    if b then
        announceServerWide(rt, b.title, b.body, b.duration, b.kind)
    end

    -- Register 60-minute anti-griefing watchdog
    registerHotCargoSentry(rt.id, {
        convoyId = rt.id,
        name = rt.def.name,
        winningGang = gangName,
        winningGangLabel = gangLabel,
        winningMembers = winningMembers,
        dropCoords = coords,
        dropStashId = stashId,
        propEntity = prop,
        deliveredAt = os.time(),
        expiresAt = os.time() + 3600,
    })

    -- Check if all spawned trucks are concluded
    local allDone = true
    for _, trk in pairs(rt.trucks) do
        if not trk.delivered and not trk.destroyed and not trk.brokenDown then
            allDone = false
            break
        end
    end
    if allDone then
        Runtime.finish(rt.id, 'COMPLETED')
    end
end

-- ── Hot Cargo tracking helpers ───────────────────────────────────────────────────
-- Kept in one table (HC) rather than a dozen file-level locals — this chunk is
-- already close to Lua's 200-locals-per-function ceiling.
local HC = {}

function HC.num(t)
    return tonumber(tostring(t.id or ''):match('(%d+)$')) or 1
end

function HC.policeAlertEnabled(rt)
    return not (rt.def.hotCargo and rt.def.hotCargo.policeAlert == false)
end

function HC.searchRadius()
    return tonumber((Config.HotCargoTheft or {}).searchRadius) or 150.0
end

function HC.maxSpeed()
    return tonumber((Config.HotCargoTheft or {}).maxSpeed) or 16.0 -- m/s (~58 km/h), same order as the convoy's 15 m/s cruise
end

-- Everyone who should hear about this event: gang members/admins, plus police
-- only when the event's Police Alert setting is on.
function HC.audience(rt)
    local list, seen = {}, {}
    for _, s in ipairs(airdropCaptureAudience(rt)) do
        if not seen[s] then seen[s] = true list[#list + 1] = s end
    end
    if HC.policeAlertEnabled(rt) then
        for _, s in ipairs(policeSources()) do
            if not seen[s] then seen[s] = true list[#list + 1] = s end
        end
    end
    return list
end

-- Search circles for trucks nobody has hijacked yet. Deliberately a big, offset
-- circle — never the truck's own position and never a truck sprite. Re-sent
-- periodically: each send replaces the client's whole set, so a hijacked truck's
-- circle disappears and a late joiner picks the rest up.
--
-- Shows EVERY configured spawn zone, not just the ones that actually got a
-- truck this run (e.g. 2 trucks picked at random out of 4 configured zones —
-- see doStartHotCargo's chosenZones). Only broadcasting the occupied zones
-- would itself tell every gang exactly which 2 of the 4 are real the moment
-- the run starts, with nothing left to search for. Zones that got no truck
-- this run show an identical-looking "decoy" circle at their own coordinate
-- for the whole event, so all four have to actually be checked.
--
-- Gang-only. Police must not be notified Hot Cargo has even started, let
-- alone shown where the search zones are — the client handler for this event
-- draws whatever it's given with no role check of its own, so this used to go
-- out via TriggerClientEvent(..., -1, ...) to literally everyone including
-- police, the moment the run began.
function HC.sendZones(rt)
    local zones = {}
    local occupiedByZoneId = {}
    for _, t in pairs(rt.trucks) do
        if t.zone and t.zone.id then occupiedByZoneId[t.zone.id] = t end
    end
    for _, z in ipairs((rt.def.hotCargo and rt.def.hotCargo.spawnZones) or {}) do
        if tonumber(z.x) and tonumber(z.y) and tonumber(z.z) then
            local t = occupiedByZoneId[z.id]
            if t then
                -- Real spawn: keep the existing off-centre truck circle, and it
                -- still disappears once that truck is no longer up for grabs.
                if not t.hijacked and not t.delivered and not t.destroyed and not t.brokenDown and t.searchCenter then
                    zones[#zones + 1] = {
                        id = t.id,
                        x = t.searchCenter.x, y = t.searchCenter.y, z = t.searchCenter.z,
                        radius = HC.searchRadius(),
                        label = ('Cargo Truck #%d — Search Area'):format(HC.num(t)),
                    }
                end
            else
                -- Decoy: this configured zone never got a truck this run, but
                -- shows the same circle so it can't be told apart from a real
                -- one without actually driving out to it.
                zones[#zones + 1] = {
                    id = 'decoy_' .. tostring(z.id),
                    x = z.x, y = z.y, z = z.z,
                    radius = HC.searchRadius(),
                    label = 'Cargo Truck — Search Area',
                }
            end
        end
    end
    -- Manual-mode trucks aren't tied to any spawnZones entry at all (the loop
    -- above only walks the zone pool), so without this they'd never get a
    -- search circle of their own.
    for _, t in pairs(rt.trucks) do
        if not t.zone and not t.hijacked and not t.delivered and not t.destroyed and not t.brokenDown and t.searchCenter then
            zones[#zones + 1] = {
                id = t.id,
                x = t.searchCenter.x, y = t.searchCenter.y, z = t.searchCenter.z,
                radius = HC.searchRadius(),
                label = ('Cargo Truck #%d — Search Area'):format(HC.num(t)),
            }
        end
    end
    notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:hotCargoZones', zones)
end

-- Destination/base blip: only the OWNING gang (whoever completed the original
-- hijack — not just whoever happens to be driving right now) ever receives
-- it; anyone who had it and no longer qualifies gets it removed. Gated on
-- t.ownerGang/t.ownerSource, deliberately NOT t.driverGang/t.driverSource —
-- a rival gang climbing into an already-unlocked truck to joyride/deny it
-- must never be handed the destination just by sitting in the seat.
function HC.syncDestination(rt, t)
    t.destSources = t.destSources or {}
    local wanted = {}
    local live = (t.hijacked and t.dropZone and not t.brokenDown and not t.delivered and not t.destroyed)
    local online = {}
    for _, s in ipairs(Bridge.GetPlayers()) do
        online[s] = true
        if live and not Bridge.IsPolice(s) then
            local g = GangService.GetPlayerGang(s)
            if s == t.ownerSource or (g and g.name and t.ownerGang and t.ownerGang ~= 'independent' and g.name == t.ownerGang) then
                wanted[s] = true
            end
        end
    end
    for s in pairs(wanted) do
        if not t.destSources[s] then
            t.destSources[s] = true
            TriggerClientEvent('nova_convoytruck:runtime:hotCargoDestination', s, t.truckNetId or t.netId, {
                x = t.dropZone.x, y = t.dropZone.y, z = t.dropZone.z,
                radius = t.dropZone.radius or 15.0,
                name = t.dropZone.name,
            }, HC.num(t))
        end
    end
    for s in pairs(t.destSources) do
        if not wanted[s] then
            t.destSources[s] = nil
            if online[s] then TriggerClientEvent('nova_convoytruck:runtime:hotCargoDestinationRemove', s, t.truckNetId or t.netId) end
        end
    end
end

-- Moving-truck blips, filtered per player: every gang member sees every
-- hijacked truck; police only see the ones the police alert has activated (and
-- only when the alert is enabled). Sent every couple of seconds as each
-- player's complete list, so trucks that were delivered/broke down drop off.
function HC.syncBlips(rt)
    local all, pol = {}, {}
    for _, t in pairs(rt.trucks) do
        if t.hijacked and not t.delivered and not t.destroyed and not t.brokenDown and t.entity and DoesEntityExist(t.entity) then
            local okM, maxH = pcall(GetEntityMaxHealth, t.entity)
            maxH = (okM and maxH and maxH > 0) and maxH or (t.maxHealth or 1000)
            local pct = combinedHealthPct(t.entity, maxH, t)
            local entry = {
                netId = t.truckNetId or t.netId,
                coords = GetEntityCoords(t.entity),
                label = ('Hot Cargo Truck #%d [%s]'):format(HC.num(t), t.driverGangLabel or 'Contraband'),
                healthPct = pct,
            }
            all[#all + 1] = entry
            if t.radarActive then pol[#pol + 1] = entry end
        end
    end
    rt.hcBlipCount = rt.hcBlipCount or {}
    local seen = {}
    for _, s in ipairs(Bridge.GetPlayers()) do
        seen[s] = true
        local list = {}
        if Bridge.IsPolice(s) then
            list = HC.policeAlertEnabled(rt) and pol or {}
        else
            local g = GangService.GetPlayerGang(s)
            if g and g.name then
                if isGangAllowed(rt, g.name) then list = all end
            elseif Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) then
                list = all
            end
        end
        if #list > 0 or (rt.hcBlipCount[s] or 0) > 0 then
            TriggerClientEvent('nova_convoytruck:runtime:updateBlips', s, list)
            rt.hcBlipCount[s] = #list
        end
    end
    for s in pairs(rt.hcBlipCount) do if not seen[s] then rt.hcBlipCount[s] = nil end end
end

-- A gang (or lone player) takes the wheel. First time is the actual hijack —
-- that gang (or lone player) becomes the truck's permanent OWNER for the rest
-- of the run: destination/GPS visibility and delivery credit stay with them
-- no matter who physically drives it afterward. A rival gang can still climb
-- into an already-unlocked hijacked truck and drive it (that's the
-- interception gameplay — no re-lockpick exists to "re-steal" it), which
-- updates who the CURRENT DRIVER is (for police/blip display) but must NOT
-- silently hand them ownership, the destination, or delivery credit — this
-- system has no separate takeover mechanic, so ownership only ever moves on
-- the very first hijack. Police driving it never takes ownership either.
function HC.setOwner(rt, t, src)
    if not src or Bridge.IsPolice(src) then return end
    local g = GangService.GetPlayerGang(src)
    local gangName = g and g.name or 'independent'
    local gangLabel = (g and (g.label or g.name)) or Bridge.GetPlayerName(src) or 'Independent Operatives'

    -- Current driver info updates on every seat change, hijack or not.
    t.driverSource = src
    t.driverGang = gangName
    t.driverGangLabel = gangLabel
    t.driverIdentifier = Bridge.GetIdentifier(src)
    t.driverName = Bridge.GetPlayerName(src)
    t.acquiredAt = os.time()
    if t.driverIdentifier then rt.participants.identifiers[t.driverIdentifier] = gangName end

    if t.hijacked then
        -- Already someone's truck — just a driver change (could even be a
        -- rival gang joyriding it to deny the delivery). Ownership, and
        -- therefore destination visibility, does not move.
        HC.syncBlips(rt)
        return
    end

    -- First hijack — this becomes the permanent owner.
    t.hijacked = true
    t.hijackedAt = os.time()
    t.ownerSource = src
    t.ownerGang = gangName
    t.ownerGangLabel = gangLabel
    t.ownerIdentifier = t.driverIdentifier
    t.ownerName = t.driverName
    local num = HC.num(t)

    -- Guards posted on the truck (if configured) are done once it's actually
    -- been hijacked — nothing left to defend at an empty search zone.
    clearHotCargoVehicleGuards(rt, t.id)

    -- Structured record for the after-action report / PDF (buildConvoyReportData).
    rt.hijackLog = rt.hijackLog or {}
    rt.hijackLog[#rt.hijackLog + 1] = {
        timestamp = os.time(), timeStr = os.date('!%H:%M:%S'),
        truckNum = num, name = t.driverName or 'Unknown', identifier = t.driverIdentifier or 'N/A',
        gang = gangName, gangLabel = gangLabel,
    }

    local b = resolveBanner('hotCargoHijacked', 'HOT CARGO — TRUCK HIJACKED', 'Driver: %s\nGang: %s\nCargo Truck #%s is now being transported.', 8000, 'danger', t.driverName or 'Unknown', gangLabel, num)
    if b then announceServerWide(rt, b.title, b.body, b.duration, b.kind) end
    DiscordLog.appendEvent(rt.id, ('🚗 [HIJACK] %s (%s) hijacked Cargo Truck #%d'):format(t.driverName or 'Unknown', gangLabel, num))
    DB.insertConvoyEvent(rt.id, 'HOT_CARGO_HIJACKED', {
        gangName = gangName, gangLabel = gangLabel,
        playerIdentifier = t.driverIdentifier, playerName = t.driverName,
        detail = ('Hijacked Cargo Truck #%d'):format(num),
    })

    -- Police Alert: only when enabled for this event. The stealth buffer (0 =
    -- immediate) is the existing head-start setting, kept as configured.
    if HC.policeAlertEnabled(rt) and not t.bufferStarted then
        t.bufferStarted = true
        local sec = tonumber(rt.def.hotCargo.policeAlertBufferSeconds) or 0
        t.bufferExpiresAt = os.time() + sec
        if sec > 0 then
            TriggerClientEvent('nova_convoytruck:client:notify', src, ('Contraband in motion! Police tracking activates in %d seconds!'):format(sec), 'warn')
        end
    end

    HC.syncDestination(rt, t)
    HC.sendZones(rt)
    HC.syncBlips(rt)
end

-- Health hit zero: the truck is NOT destroyed or turned into a crate — it stops
-- where it is, stays in the world, and its cargo can be lockpicked and looted
-- through the same makeTruckLootable / tryLootTruck flow the Convoy uses.
function HC.breakDown(rt, t)
    if t.brokenDown then return end
    t.brokenDown = true
    t.disabled = true
    t.state = 'DISABLED'
    t.brokenDownAt = os.time()
    local num = HC.num(t)
    -- Safety net: a truck can in theory break down before ever being
    -- hijacked (guards defending it fought someone off and it took stray
    -- damage) — HC.setOwner's own cleanup never runs in that case, so this
    -- would otherwise leave the guard squad standing around an abandoned,
    -- undriveable truck forever.
    clearHotCargoVehicleGuards(rt, t.id)

    if t.entity and DoesEntityExist(t.entity) then
        t.lastCoords = GetEntityCoords(t.entity)
        warnOccupantsToExit(t.entity, 'HOT CARGO')
        FreezeEntityPosition(t.entity, true)
        pcall(SetEntityInvincible, t.entity, true)
        pcall(SetEntityHealth, t.entity, math.max(200, math.floor((t.maxHealth or 1000) * 0.05)))
        pcall(SetVehicleEngineHealth, t.entity, -4000.0)
        pcall(SetVehicleUndriveable, t.entity, true)
        pcall(SetVehicleDoorsLocked, t.entity, 2)
        Entity(t.entity).state:set('hot_cargo_broken', true, true)
        Entity(t.entity).state:set('convoy_truck_broken', true, true)
        Entity(t.entity).state:set('hot_cargo_locked', false, true)
        Entity(t.entity).state:set('convoy_truck_label', ('Hot Cargo Truck #%d — DISABLED'):format(num), true)
    end

    DB.insertConvoyEvent(rt.id, 'TRUCK_BREAKDOWN', { gangName = t.driverGang, gangLabel = t.driverGangLabel, playerIdentifier = t.driverIdentifier, playerName = t.driverName, detail = ('Cargo Truck #%d broke down (health depleted)'):format(num) })
    DiscordLog.appendEvent(rt.id, ('🛠️ [TRUCK DISABLED] Cargo Truck #%d broke down — %s'):format(num, t.driverGangLabel or 'no driver'))
    -- Console-visible too, not just Discord — a truck breaking down within
    -- seconds of the run starting (before anyone could plausibly have
    -- reached and damaged it) is the signature of a bad spawn zone (spawned
    -- in water/void/on top of something), and this is what makes that
    -- diagnosable from server console instead of just "it ended instantly."
    local finalHealth = (t.entity and DoesEntityExist(t.entity)) and GetEntityHealth(t.entity) or -1
    print(('[NovaConvoy] Hot Cargo: truck %d broke down at (%.1f, %.1f, %.1f), %ds after start. health=%d, firstSyncedAt=%s (%ds after start), invincibilityReleased=%s.'):format(
        num, t.lastCoords and t.lastCoords.x or 0, t.lastCoords and t.lastCoords.y or 0, t.lastCoords and t.lastCoords.z or 0, os.time() - (rt.startedAt or os.time()),
        finalHealth, tostring(t.hcSyncedAt), t.hcSyncedAt and (t.hcSyncedAt - (rt.startedAt or t.hcSyncedAt)) or -1, tostring(t.hcInvincibleReleased == true)
    ))

    local audience = HC.audience(rt)
    makeTruckLootable(rt, t, airdropCaptureAudience(rt))
    local b = resolveBanner('hotCargoTruckDisabled', 'HOT CARGO — TRUCK DISABLED', 'Cargo Truck #%s has broken down and is no longer moving. Participating gangs can attempt to loot the truck.', 8000, 'danger', num)
    if b and not (rt.def.settings and rt.def.settings.announcements == false) then
        notify(audience, 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind)
    end

    HC.syncDestination(rt, t)
    HC.syncBlips(rt)
    HC.sendZones(rt)
end

-- One second of Hot Cargo. Returns true once every truck has been delivered,
-- disabled or destroyed.
function HC.tick(rt, tick)
    local allDone = true
    local hcCfg = Config.HotCargoTheft or {}
    local breakdownAt = (tonumber(hcCfg.breakdownHealthPct) or 8) / 100.0
    -- A just-spawned vehicle can read back 0 health for a moment before its
    -- owner syncs it (the Convoy has the same grace in pollTrucks). A fixed
    -- 10-tick grace is enough for a Convoy truck — it spawns with an escort
    -- standing right next to it, so a client owns/syncs it almost instantly.
    -- A Hot Cargo truck spawns ALONE at a remote search zone with nobody
    -- anywhere near it (that's the point — it has to be searched for), so in
    -- OneSync nothing ever takes ownership of the entity and the server's own
    -- GetEntityHealth read can keep coming back 0 indefinitely, well past any
    -- fixed grace window — confirmed in the field: it broke down at exactly
    -- tick 11 (the instant grace ended) even with a 12s spawn-invincibility
    -- window that should have blocked any real damage entirely. That means
    -- there was never any real damage — health was simply never observed as
    -- synced. hcHealthSeen below fixes this at the root: a truck is only
    -- ever eligible to break down AFTER its health has been read back as
    -- genuinely positive at least once, so an unsynced/unowned truck just
    -- sits there correctly instead of "breaking down" from a phantom reading.
    local graceOver = tick > 10

    for _, t in pairs(rt.trucks) do
        if not t.delivered and not t.destroyed and not t.brokenDown then
            allDone = false
            if t.entity and DoesEntityExist(t.entity) then
                local coords = GetEntityCoords(t.entity)
                t.lastCoords = coords
                local health = GetEntityHealth(t.entity)
                local okM, maxH = pcall(GetEntityMaxHealth, t.entity)
                maxH = (okM and maxH and maxH > 0) and maxH or (t.maxHealth or 1000)
                if health > 0 then
                    if not t.hcHealthSeen then
                        t.hcHealthSeen = true
                        t.hcSyncedAt = os.time()
                        -- Field-confirmed root cause of the "instant breakdown,
                        -- nobody touched it" reports: doStartHotCargo's
                        -- SetEntityMaxHealth/SetEntityHealth calls run before any
                        -- client has ever owned the entity (it was created via
                        -- CreateVehicleServerSetter with nobody nearby to stream
                        -- it in). Two trucks in the field both read back a full,
                        -- undamaged health at this exact first-sync moment, then
                        -- BOTH independently collapsed to ~1000/948 (right around
                        -- a stock vehicle's un-upgraded default body health) a
                        -- few seconds later, at two unrelated locations, with
                        -- nobody anywhere near either one — not combat, not
                        -- terrain. That is the signature of the health value
                        -- silently reverting to the model's real default the
                        -- moment a client actually takes ownership and starts
                        -- simulating it for real, because the original calls
                        -- never had an owning client to actually stick to.
                        -- Re-asserting both here, now that hcHealthSeen proves a
                        -- real client is finally in the loop, is what makes the
                        -- 15000 actually take.
                        pcall(SetEntityMaxHealth, t.entity, t.maxHealth or 15000)
                        pcall(SetEntityHealth, t.entity, t.maxHealth or 15000)
                        -- Also correct the values THIS tick will use below —
                        -- otherwise a first sync that happens to land after the
                        -- grace period (tick > 10) would still judge breakdown
                        -- against the stale pre-correction reading taken at the
                        -- top of this same tick, one tick too early to benefit.
                        health = t.maxHealth or 15000
                        maxH = t.maxHealth or 15000
                    end
                end

                -- Release the spawn invincibility (set in doStartHotCargo) only
                -- once we've actually confirmed it's safe: a client rendered it
                -- for the first time (hcHealthSeen — while still invincible, so
                -- that first reading is guaranteed undamaged) AND it's been
                -- settled/stationary for a few seconds since. A truck spawned
                -- overlapping uneven terrain/geometry keeps getting physically
                -- shoved by the engine for a bit after it's first rendered —
                -- releasing invincibility on a blind timer let that shove land
                -- as real damage the instant protection dropped, however long
                -- after spawn that happened to be (confirmed in the field: a
                -- fixed 12s release still broke a truck at 16s, because nobody
                -- rendered it until ~16s).
                if t.hcHealthSeen and not t.hcInvincibleReleased and os.time() - (t.hcSyncedAt or 0) >= 4 then
                    local okS, speed = pcall(GetEntitySpeed, t.entity)
                    if not okS or not speed or speed < 0.5 then
                        t.hcInvincibleReleased = true
                        pcall(SetEntityInvincible, t.entity, false)
                    end
                end

                -- Keep the last healthy reading — handleHotCargoDelivered's reward
                -- scaling falls back to it if the entity can't be read right then.
                if t.hcHealthSeen and health > 0 then Runtime.hotCargoHealthPct(t) end

                if graceOver and not t.hcHealthSeen and tick % 15 == 0 then
                    print(('[NovaConvoy] Hot Cargo: truck %s health still unsynced (reads %d/%d) at tick %d — nobody has been near it yet.'):format(tostring(t.id), health, maxH, tick))
                end

                if graceOver and t.hcHealthSeen and health <= maxH * breakdownAt then
                    HC.breakDown(rt, t)
                else
                    -- Whoever's in the driver seat now is the owner.
                    local driverPed = GetPedInVehicleSeat(t.entity, -1)
                    if driverPed and driverPed ~= 0 then
                        local currentDriverSrc
                        for _, s in ipairs(Bridge.GetPlayers()) do
                            if GetPlayerPed(s) == driverPed then currentDriverSrc = s break end
                        end
                        -- Re-check on an identifier change too, not just a source change —
                        -- a player who switches character (e.g. gang -> EMS) without ever
                        -- leaving the driver's seat keeps the same numeric source, so a
                        -- source-only comparison would keep crediting the OLD character
                        -- forever. Bridge.GetIdentifier(source) always reflects whichever
                        -- character is currently loaded on that source.
                        local currentIdentifier = currentDriverSrc and Bridge.GetIdentifier(currentDriverSrc)
                        if currentDriverSrc and (t.driverSource ~= currentDriverSrc or (currentIdentifier and t.driverIdentifier ~= currentIdentifier)) then
                            local g = GangService.GetPlayerGang(currentDriverSrc)
                            -- SELECTED-mode allowedGangs is a hard gate here — a gang the
                            -- admin left out can't drive the truck at all.
                            if not isGangAllowed(rt, g and g.name) then
                                TriggerClientEvent('nova_convoytruck:client:notify', currentDriverSrc, "You can't access this — your gang isn't part of this event.", 'error')
                                ejectLivePlayersFrom(t.entity)
                            else
                                HC.setOwner(rt, t, currentDriverSrc)
                            end
                        end
                    end

                    -- Low health: name whoever's driving, same as the Convoy does for police.
                    if t.hijacked and not t.criticalAnnounced and health <= maxH * 0.25 then
                        t.criticalAnnounced = true
                        local drvSrc = findDrivingPlayerSource(t.entity)
                        local drvName = (drvSrc and Bridge.GetPlayerName(drvSrc)) or t.driverName or 'Unknown'
                        local gLabel = t.driverGangLabel or 'Unknown'
                        local num = HC.num(t)
                        if not (rt.def.settings and rt.def.settings.announcements == false) then
                            if HC.policeAlertEnabled(rt) then
                                local pb = resolveBanner('hotCargoTruckCritical', '🔥 HOT CARGO: TRUCK CRITICAL', 'Cargo Truck #%s driven by %s (%s) is taking heavy damage and about to break down!', 7000, 'danger', num, drvName, gLabel)
                                if pb then notify(policeSources(), 'nova_convoytruck:runtime:announce', pb.title, pb.body, pb.duration, pb.kind) end
                            end
                            local gb = resolveBanner('hotCargoTruckCriticalGang', '🔥 HOT CARGO: TRUCK CRITICAL', 'Cargo Truck #%s held by %s is taking heavy damage and about to break down!', 7000, 'danger', num, gLabel)
                            if gb then notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:announce', gb.title, gb.body, gb.duration, gb.kind) end
                        end
                        if drvSrc then
                            local vb = resolveBanner('hotCargoVehicleCritical', 'HOT CARGO — VEHICLE CRITICAL', 'Your cargo truck is about to break down — get ready to bail out!', 6000, 'danger')
                            if vb then notify({ drvSrc }, 'nova_convoytruck:runtime:announce', vb.title, vb.body, vb.duration, vb.kind) end
                        end
                    end

                    -- Police alert after the stealth buffer.
                    if HC.policeAlertEnabled(rt) and t.hijacked and t.bufferExpiresAt and not t.policeAlerted and os.time() >= t.bufferExpiresAt then
                        t.policeAlerted = true
                        t.policeAlertedAt = os.time()
                        t.radarActive = true
                        local pSources = policeSources()
                        local b = resolveBanner('policeHotCargoAlert', 'HOT CARGO ALERT', 'Cargo Truck #%s has been hijacked by %s! GPS tracking enabled.', 8000, 'danger', HC.num(t), t.driverGangLabel or 'Unknown')
                        for _, pSrc in ipairs(pSources) do
                            TriggerClientEvent('nova_convoytruck:client:playChime', pSrc)
                            if b and not (rt.def.settings and rt.def.settings.announcements == false) then
                                TriggerClientEvent('nova_convoytruck:runtime:announce', pSrc, b.title, b.body, b.duration, b.kind)
                            end
                        end
                        if t.driverSource then
                            TriggerClientEvent('nova_convoytruck:client:notify', t.driverSource, 'Police have tracked the vehicle GPS! Incoming interceptors!', 'error')
                        end
                        DiscordLog.appendEvent(rt.id, ('📡 [POLICE ALERT] Cargo Truck #%d GPS tracking active. Driver: %s (%s)'):format(HC.num(t), t.driverName or 'Unknown', t.driverGangLabel or 'Gang'))
                        HC.syncBlips(rt)
                    end

                    -- Delivery: the truck's own destination only, and only once hijacked.
                    local dropZone = t.dropZone
                    if t.hijacked and dropZone then
                        local dropPos = vector3(dropZone.x, dropZone.y, dropZone.z)
                        if #(coords - dropPos) <= (tonumber(dropZone.radius) or 15.0) then
                            local aliveGuards = getAliveGuardsCount(rt.dropoffGuards and rt.dropoffGuards[dropZone.id])
                            if aliveGuards > 0 then
                                if tick % 4 == 0 and t.driverSource then
                                    TriggerClientEvent('nova_convoytruck:client:notify', t.driverSource, ('Dropoff under hostile guard! Neutralize the %d guard(s) before delivering!'):format(aliveGuards), 'error')
                                end
                            else
                                handleHotCargoDelivered(rt, t, dropZone, coords)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Hostile dropoff guards spawn when a truck or any player nears a dropoff.
    if tick % 2 == 0 and rt.def.hotCargo and rt.def.hotCargo.dropoffZones then
        for _, dropZone in ipairs(rt.def.hotCargo.dropoffZones) do
            if dropZone.guardCount and tonumber(dropZone.guardCount) > 0 and not (rt.dropoffGuards and rt.dropoffGuards[dropZone.id]) then
                local dropPos = vector3(dropZone.x, dropZone.y, dropZone.z)
                local shouldSpawn = false
                for _, trk in pairs(rt.trucks) do
                    if not trk.delivered and not trk.destroyed and not trk.brokenDown and trk.lastCoords and #(trk.lastCoords - dropPos) <= 250.0 then
                        shouldSpawn = true
                        break
                    end
                end
                if not shouldSpawn then
                    for _, s in ipairs(Bridge.GetPlayers()) do
                        local ped = GetPlayerPed(s)
                        if ped and ped ~= 0 and DoesEntityExist(ped) and #(GetEntityCoords(ped) - dropPos) <= 250.0 then
                            shouldSpawn = true
                            break
                        end
                    end
                end
                if shouldSpawn then spawnHotCargoDropoffGuards(rt, dropZone) end
            end
        end
    end

    if active[rt.id] ~= rt then return true end
    if tick % 2 == 0 then HC.syncBlips(rt) end
    if tick % 3 == 0 then
        for _, t in pairs(rt.trucks) do HC.syncDestination(rt, t) end
    end
    if tick % 5 == 0 then HC.sendZones(rt) end

    -- Every truck resolved (delivered/disabled/destroyed) doesn't necessarily
    -- mean the RUN is over. If at least one was delivered, it's done either
    -- way. If NONE were, failurePolicy (the same FAIL/CONTINUE setting the
    -- Convoy kind already has for "all cargo lost") decides: FAIL (default)
    -- ends immediately, CONTINUE just lets the run idle out to its own timer
    -- or an admin Force End, per the Hot Cargo config's own toggle for this.
    if allDone and (rt.def.settings and rt.def.settings.failurePolicy) == 'CONTINUE' then
        local anyDelivered = false
        for _, t in pairs(rt.trucks) do if t.delivered then anyDelivered = true break end end
        if not anyDelivered then return false end
    end

    return allDone
end

local function monitorHotCargo(rt)
    CreateThread(function()
        local tick = 0
        local outcome
        while active[rt.id] == rt and rt.deliveryTimeRemaining > 0 do
            Wait(1000)
            if active[rt.id] ~= rt then return end
            tick = tick + 1
            rt.deliveryTimeRemaining = rt.deliveryTimeRemaining - 1

            -- Pushed EVERY second. It used to go out only on every 5th second, and the HUD just shows what the server last sent, so the
            -- Hot Cargo clock jumped in 5-second steps (the Airdrop clock had the same bug and was fixed the same way).
            -- `notify` takes a list of sources; the old `notify(-1, ...)` here threw on ipairs(-1) and killed this whole thread.
            notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:deliveryTimer', rt.deliveryTimeRemaining, 'HOT_CARGO')

            -- pcall so one bad tick logs and carries on instead of silently
            -- ending the monitor (and with it the whole event).
            local ok, res = pcall(HC.tick, rt, tick)
            if not ok then
                print(('[NovaConvoy] Hot Cargo tick error: %s'):format(tostring(res)))
            elseif res then
                outcome = true
                break
            end
        end

        if active[rt.id] ~= rt then return end
        if outcome or rt.deliveryTimeRemaining <= 0 then
            local anyDelivered = false
            for _, t in pairs(rt.trucks) do if t.delivered then anyDelivered = true break end end
            Runtime.finish(rt.id, anyDelivered and 'COMPLETED' or 'FAILED')
        end
    end)
end

local function doStartHotCargo(def, convoyId, starterSource)
    local truckEntries = def.hotCargo and def.hotCargo.trucks or {}
    print(('[NovaConvoy] doStartHotCargo(%s): hotCargo=%s truckEntries=%d dropoffZones=%d spawnZones=%d'):format(
        tostring(convoyId), tostring(def.hotCargo ~= nil), #truckEntries,
        #(def.hotCargo and def.hotCargo.dropoffZones or {}), #(def.hotCargo and def.hotCargo.spawnZones or {})
    ))
    if #truckEntries == 0 then
        print('[NovaConvoy] doStartHotCargo: FAILED — no truck entries.')
        return false, 'Add at least one cargo truck (Trucks section) before starting Hot Cargo.'
    end
    if not def.hotCargo.dropoffZones or #def.hotCargo.dropoffZones == 0 then
        print('[NovaConvoy] doStartHotCargo: FAILED — no dropoff zones.')
        return false, 'Add at least one dropoff zone before starting Hot Cargo.'
    end

    -- (0,0) is the tablet's own "never placed" sentinel (Add Manual defaults
    -- a blank zone to x=0,y=0,z=70 — the HotCargoConfig.svelte placed-dot
    -- indicator even shows it as "placed" since 0 is not null) — it is never
    -- a real in-world zone (that coordinate sits far out in the ocean), so a
    -- zone left at that default must be excluded here the same way an
    -- unplaced MANUAL truck already is above, or Random mode can silently
    -- draw it and spawn a truck (and its guards) invisibly in open water.
    -- This confirmed exactly that symptom: "truck 2 spawned at (0.0, 0.0, 70.0)".
    local function isRealZonePos(v)
        return tonumber(v.x) and tonumber(v.y) and tonumber(v.z) and not (tonumber(v.x) == 0 and tonumber(v.y) == 0)
    end
    local validZones = {}
    for _, z in ipairs(def.hotCargo.spawnZones or {}) do
        if isRealZonePos(z) then validZones[#validZones + 1] = z end
    end
    local validDrops = {}
    for _, d in ipairs(def.hotCargo.dropoffZones) do
        if isRealZonePos(d) then validDrops[#validDrops + 1] = d end
    end
    if #validDrops == 0 then
        print('[NovaConvoy] doStartHotCargo: FAILED — no dropoff zone has a valid x/y/z.')
        return false, 'None of the dropoff zones have a position set.'
    end

    print(('[NovaConvoy] doStartHotCargo: trucks=%d validZones=%d validDrops=%d'):format(#truckEntries, #validZones, #validDrops))
    if #validZones == 0 then
        print('[NovaConvoy] doStartHotCargo: FAILED — no spawn zone has a valid x/y/z.')
        return false, 'No spawn zone has a position set. Add at least one spawn zone and set its position.'
    end

    -- Every truck always draws from the shuffled spawn-zone pool — trucks
    -- no longer carry their own individual spawn vector at all (removed the
    -- old per-truck Manual mode entirely: positioning only ever happens on
    -- a zone, in the Spawn Zones list, never on a truck). Zones nobody draws
    -- stay in the pool and become decoys (see HC.sendZones).
    local zonePool = {}
    for i, z in ipairs(validZones) do zonePool[i] = z end
    for i = #zonePool, 2, -1 do
        local j = math.random(i)
        zonePool[i], zonePool[j] = zonePool[j], zonePool[i]
    end

    -- Same shuffle for dropoff zones — was previously assigned by a fixed
    -- `(truck index - 1) % #validDrops` wrap, which is completely
    -- deterministic: with more dropoffs configured than trucks, truck #1
    -- ALWAYS got dropoff #1, truck #2 ALWAYS got dropoff #2, every single
    -- run, and any dropoff beyond the truck count was never used at all.
    -- That's exactly a fixed, learnable "spawn zone A -> dropoff A" route
    -- rather than a genuinely random pairing. Shuffling first means which
    -- physical dropoffs actually get used, and which truck lands on which
    -- one, both change every run — same randomization spawn zones already
    -- had.
    local dropPool = {}
    for i, d in ipairs(validDrops) do dropPool[i] = d end
    for i = #dropPool, 2, -1 do
        local j = math.random(i)
        dropPool[i], dropPool[j] = dropPool[j], dropPool[i]
    end

    local resolved = {}
    for i, t in ipairs(truckEntries) do
        local z = zonePool[i]
        if z then
            -- z.x/y/z is just the zone's general-area marker (the dot on the
            -- tactical map). truckX/Y/Z is the separate, precise vector an
            -- admin can additionally set for exactly where the truck itself
            -- spawns within that area — falls back to the zone's own
            -- position when that finer vector was never set.
            local hasTruckVector = tonumber(z.truckX) and tonumber(z.truckY) and tonumber(z.truckZ)
            local sx = hasTruckVector and tonumber(z.truckX) or z.x
            local sy = hasTruckVector and tonumber(z.truckY) or z.y
            local sz = hasTruckVector and tonumber(z.truckZ) or z.z
            local sh = hasTruckVector and (tonumber(z.truckHeading) or 0.0) or (tonumber(z.heading) or 0.0)
            resolved[#resolved + 1] = { entry = t, x = sx, y = sy, z = sz, heading = sh, zone = z }
        else
            print(('[NovaConvoy] Hot Cargo: truck "%s" ran out of spawn zones (more trucks than configured zones) — skipped.'):format(tostring(t.name)))
        end
    end
    print(('[NovaConvoy] doStartHotCargo: resolved=%d of %d truck entries.'):format(#resolved, #truckEntries))
    if #resolved == 0 then
        print('[NovaConvoy] doStartHotCargo: FAILED — zero trucks resolved to a spawn position.')
        return false, 'No truck could be resolved to a spawn position — check the Trucks section.'
    end

    local startedByName = 'Automated Schedule'
    if starterSource and starterSource > 0 then
        local pName = Bridge.GetPlayerName(starterSource)
        local pIdent = Bridge.GetIdentifier(starterSource)
        startedByName = ('%s (%s)'):format(pName or 'Admin', pIdent or 'N/A')
    end

    local rt = {
        id = convoyId,
        def = def,
        route = {},
        status = 'ACTIVE',
        -- math.max(300, ...) guards against event_duration being 0 (saved as zero from
        -- the admin UI when the duration fields weren't interacted with). 0 would make the
        -- monitor loop exit on the very first iteration → event starts then immediately ends.
        -- Minimum 5 minutes; real default is 1200 (20 min). db.lua also converts 0→nil.
        deliveryTimeRemaining = math.max(300, def.eventDuration or 1200),
        trucks = {},
        startedAt = os.time(),
        startedByName = startedByName,
        startedBySource = starterSource,
        participants = { identifiers = {}, gangCounts = {}, policeIdentifiers = {}, names = {} },
        gangVisibilityUnlocked = true,
        hotCargo = {
            vehiclesToSpawn = #resolved,
            bufferSeconds = def.hotCargo.policeAlertBufferSeconds or 45,
        },
        carriers = {},
        pvpHijacks = {},
        policeAudit = {},
        hotCargoDelivered = false,
        hotCargoDeliveredCount = 0,
    }

    local defaultHealth = math.floor(tonumber((Config.HotCargoTheft or {}).truckHealth) or Config.DefaultTruckHealth or 2500)
    local searchRadius = HC.searchRadius()

    for i, r in ipairs(resolved) do
        local entry = r.entry
        -- Per-truck "Truck Health (HP)" field from the tablet — previously
        -- never read at all, every truck used the same global config value
        -- regardless of what was configured per-truck (and the sanitizer
        -- was also dropping the field on save, so it never even persisted).
        local health = math.floor(tonumber(entry.health) or defaultHealth)
        if health <= 0 then health = defaultHealth end
        local modelName = entry.model or 'hauler'
        local modelHash = joaat(modelName)
        local heading = r.heading
        local veh
        if CreateVehicleServerSetter then
            veh = CreateVehicleServerSetter(modelHash, 'automobile', r.x + 0.0, r.y + 0.0, r.z + 0.0, heading)
        else
            veh = CreateVehicle(modelHash, r.x + 0.0, r.y + 0.0, r.z + 0.0, heading, true, true)
        end
        -- The handle can take a few frames to register — retry before giving up on this one.
        local tries = 0
        while (not veh or veh == 0 or not DoesEntityExist(veh)) and tries < 20 do
            Wait(50)
            tries = tries + 1
        end

        if veh and veh ~= 0 and DoesEntityExist(veh) then
            Wait(50)
            -- Confirmed in the field: NetworkGetNetworkIdFromEntity (unguarded)
            -- threw "Tried to access invalid entity" here and aborted the
            -- ENTIRE start — not just this one truck — because nothing below
            -- this point was wrapped in pcall, so the error propagated all the
            -- way up through the ox_lib callback and the tablet just saw
            -- "failed to start" with zero indication why. A freshly-created
            -- vehicle passing DoesEntityExist a moment ago is apparently not
            -- a hard guarantee it's still valid by the very next native call.
            -- Wrapping this truck's whole setup means one bad truck just gets
            -- skipped (and logged) instead of taking the other truck(s) and
            -- the whole event down with it.
            local setupOk, setupErr = pcall(function()
            -- Confirmed live: even after the DoesEntityExist check + Wait(50)
            -- just above, this specific native still occasionally threw
            -- "Tried to access invalid entity" on the very first call,
            -- which used to abort this truck's ENTIRE setup right here —
            -- guards, state bags, health, trailer, and the hijack ox_target
            -- registration at the very end all skipped at once, with the
            -- truck then deleted, which is exactly "the truck spawned but
            -- has no Hijack option and I can't even get to the minigame."
            -- A few more short retries absorbs that timing hiccup instead
            -- of losing the whole truck over one bad frame.
            local vehNetId
            for netTry = 1, 10 do
                local ok, id = pcall(NetworkGetNetworkIdFromEntity, veh)
                if ok and id and id > 0 then vehNetId = id break end
                Wait(50)
            end
            if not vehNetId then
                error('NetworkGetNetworkIdFromEntity never returned a valid id after retrying')
            end
            local truckId = 'hot_cargo_' .. i

            -- Never let OneSync quietly despawn/reset this truck just because
            -- no client stayed within streaming range of it — a Hot Cargo
            -- truck spawns alone at a remote zone BY DESIGN, with nobody
            -- anywhere near it until someone finds it. Without this, the
            -- truck a player eventually walks up to can already be a
            -- population-culled/reset entity that never carries this
            -- server's state bags or matches its tracked netId — exactly
            -- "health reads 0 forever" and "no Hijack option ever appears"
            -- even standing right next to it. The trailer already had this
            -- (below); the truck itself never did. Mirrors the Convoy truck
            -- spawn path above.
            pcall(SetEntityAsMissionEntity, veh, true, true)

            Entity(veh).state:set('convoy_truck', true, true)
            Entity(veh).state:set('convoy_truck_label', entry.name or ('Hot Cargo Truck #%d'):format(i), true)
            Entity(veh).state:set('maxHealth', health, true)
            Entity(veh).state:set('hot_cargo_truck', true, true)
            Entity(veh).state:set('hot_cargo_truck_id', truckId, true)
            Entity(veh).state:set('hot_cargo_locked', true, true)
            Entity(veh).state:set('hot_cargo_max_speed', HC.maxSpeed(), true)
            Entity(veh).state:set('convoy_id', convoyId, true)
            -- Hot Cargo has no staged "police head-start" departure like a
            -- regular Convoy — it's live and hijackable the instant it spawns.
            -- Without this explicit false, the client's own
            -- snapTruckToGround/convoy_truck statebag handlers (shared with
            -- Convoy trucks) read releaseHeld as nil, treat that as "still
            -- held", and re-FREEZE the truck right after un-freezing it —
            -- permanently. It would sit there un-driveable forever even after
            -- a successful hijack, with nothing anywhere telling you why.
            Entity(veh).state:set('releaseHeld', false, true)
            -- Locked until a gang lockpicks it — that's what makes a hijack a hijack.
            -- (This used to be 1 = unlocked, so anyone could just climb in.)
            SetVehicleDoorsLocked(veh, 2)
            -- Same statebag qbx_vehiclekeys uses: without it, it re-rolls the lock the moment someone tries the door
            -- (so the truck could open without a lockpick, or stay shut after one).
            Entity(veh).state:set('doorslockstate', 2, true)
            FreezeEntityPosition(veh, false)
            pcall(SetEntityHeading, veh, heading)
            TriggerClientEvent('nova_convoytruck:runtime:snapTruckToGround', -1, vehNetId)

            if health > 1000 then pcall(SetEntityMaxHealth, veh, health) end
            pcall(SetEntityHealth, veh, health)
            pcall(SetVehicleEngineHealth, veh, tonumber((Config.HotCargoTheft or {}).engineHealth) or Config.DefaultEngineHealth or 1000.0)
            pcall(SetVehicleTyresCanBurst, veh, false)
            pcall(SetVehiclePetrolTankHealth, veh, 5000.0)
            pcall(SetVehicleCanLeakPetrol, veh, false)
            pcall(SetVehicleExplodesOnHighExplosionDamage, veh, false)
            pcall(SetVehicleStrong, veh, true)
            pcall(SetVehicleHasStrongAxles, veh, true)
            pcall(SetVehicleDamageModifier, veh, 0.25)

            -- Spawn-settle invincibility. A Hot Cargo truck spawns alone at a
            -- remote zone with nobody near it by design — no client streams it
            -- in or takes ownership until someone actually walks up, which can
            -- happen well after any fixed timer. Confirmed in the field: a
            -- FIXED 12s release still let a truck break down at 16s, because
            -- nobody got close enough to render it until ~16s — the moment a
            -- client FIRST streams in a vehicle that's been sitting overlapped
            -- with uneven terrain/geometry, the game resolves that overlap as
            -- a single instant "unstuck" impact, and invincibility had already
            -- been switched back off 4 seconds before that happened. Left
            -- invincible indefinitely here; HC.tick below switches it back off
            -- itself a few seconds after the FIRST real health sync (the
            -- actual signal that a client has finally rendered it and taken
            -- that impact), instead of guessing at a timer.
            pcall(SetEntityInvincible, veh, true)

            -- Tractor-unit models (Hauler/Packer) tow a trailer in vanilla GTA —
            -- spawned alone they look like a bare cab. Spawned a short distance
            -- behind and coupled with the real trailer-hitch native (the same
            -- one the game itself uses), not just visually placed there.
            local trailerEntity = nil
            local trailerModelName = (Config.HotCargoTheft.trailerModels or {})[tostring(modelName):lower()]
            if trailerModelName then
                local trailerHash = joaat(trailerModelName)
                local rad = math.rad(heading)
                local backDist = 9.0
                local trX = r.x - (-math.sin(rad)) * backDist
                local trY = r.y - math.cos(rad) * backDist
                local trailer
                if CreateVehicleServerSetter then
                    trailer = CreateVehicleServerSetter(trailerHash, 'trailer', trX, trY, r.z + 0.0, heading)
                else
                    trailer = CreateVehicle(trailerHash, trX, trY, r.z + 0.0, heading, true, true)
                end
                local trTries = 0
                while (not trailer or trailer == 0 or not DoesEntityExist(trailer)) and trTries < 20 do
                    Wait(50)
                    trTries = trTries + 1
                end
                if trailer and trailer ~= 0 and DoesEntityExist(trailer) then
                    pcall(SetEntityAsMissionEntity, trailer, true, true)
                    pcall(SetVehicleDoorsLocked, trailer, 2)
                    pcall(AttachVehicleToTrailer, veh, trailer, 3.5)
                    trailerEntity = trailer
                else
                    print(('[NovaConvoy] Hot Cargo: trailer "%s" failed to spawn for truck %d — continuing without one.'):format(tostring(trailerModelName), i))
                end
            end

            -- Off-centre so the circle marks "somewhere around here", not the truck.
            local ang = math.random() * 2 * math.pi
            local off = math.random() * searchRadius * 0.5
            rt.trucks[truckId] = {
                id = truckId,
                entity = veh,
                netId = vehNetId,
                truckNetId = vehNetId,
                trailerEntity = trailerEntity,
                role = 'HOT_CARGO',
                label = entry.name,
                maxHealth = health,
                -- The Truck Delivery Reward from the form: the MAXIMUM paid at 100% truck
                -- condition (empty = fall back to the event-level reward).
                deliveryReward = entry.deliveryReward,
                hijackReward = entry.hijackReward,
                zone = r.zone, -- nil for a Manual truck — it never occupies/removes a spawnZones pool entry
                searchCenter = vector3(r.x + math.cos(ang) * off, r.y + math.sin(ang) * off, r.z + 0.0),
                dropZone = dropPool[((i - 1) % #dropPool) + 1],
                lastCoords = vector3(r.x + 0.0, r.y + 0.0, r.z + 0.0),
                bufferStarted = false,
                policeAlerted = false,
                radarActive = false,
                hijacked = false,
                delivered = false,
                destroyed = false,
                unlocked = false,
            }

            -- Success path used to print nothing at all — the only console
            -- feedback was the failure branch below, so "truck never appeared"
            -- reports were undebuggable after the fact (no way to tell if it
            -- spawned in the wrong spot, e.g. a manual zone left at its 0,0,70
            -- default, versus not spawning at all). Always print where it
            -- actually landed.
            print(('[NovaConvoy] Hot Cargo: truck %d ("%s", %s mode) spawned at (%.1f, %.1f, %.1f) -> dropoff "%s".'):format(
                i, tostring(entry.name), tostring(entry.mode), r.x, r.y, r.z, tostring((dropPool[((i - 1) % #dropPool) + 1] or {}).name)
            ))

            -- Random trucks are guarded by whatever the ZONE they landed on
            -- configures (a decoy zone that never gets a truck just never
            -- spawns anyone) — Manual trucks have no zone, so they carry
            -- their own guard fields directly.
            spawnHotCargoVehicleGuards(rt, truckId, r.zone or entry, vector3(r.x + 0.0, r.y + 0.0, r.z + 0.0), heading)

            TriggerClientEvent('nova_convoytruck:runtime:hotCargoLockable', -1, vehNetId, convoyId, truckId)
            end) -- setupOk, setupErr = pcall(...)
            if not setupOk then
                print(('[NovaConvoy] Hot Cargo: truck "%s" errored mid-setup after spawning (%s) — cleaning up and skipping just this truck.'):format(tostring(entry.name), tostring(setupErr)))
                if DoesEntityExist(veh) then pcall(DeleteEntity, veh) end
            end
        else
            print(('[NovaConvoy] Hot Cargo: truck "%s" (model "%s") failed to spawn at (%.1f, %.1f, %.1f) — check the model name.'):format(tostring(entry.name), tostring(modelName), r.x, r.y, r.z))
        end
    end

    local spawned = 0
    for _ in pairs(rt.trucks) do spawned = spawned + 1 end
    if spawned == 0 then
        return false, 'No cargo truck could be spawned. Check each truck\'s model name and position.'
    end
    rt.hotCargo.vehiclesToSpawn = spawned

    active[convoyId] = rt
    ConvoyManager.setStatus(convoyId, 'ACTIVE')
    persist(rt)

    monitorHotCargo(rt)
    HC.sendZones(rt)

    notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:startDeliveryTimer', rt.deliveryTimeRemaining, 'HOT_CARGO')

    for _, s in ipairs(Bridge.GetPlayers()) do
        if Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) or Bridge.HasCreatorAccess(s) then
            TriggerClientEvent('nova_convoytruck:gang:toast', s, '🔥', 'Hot Cargo Active', ('"%s" is now live — %d truck(s) spawned.'):format(def.name, spawned), false)
        end
    end

    -- Gang-only, deliberately not announceServerWide — police must not be
    -- notified when Hot Cargo starts or trucks spawn, only after a truck is
    -- actually hijacked and moving (see HC.setOwner's police alert buffer).
    local b = resolveBanner('hotCargoEventStarted', 'HOT CARGO: ' .. def.name, 'A contraband run is now live — hijack the vehicle before someone else does!', 8000, 'start', def.name)
    if b and not (def.settings and def.settings.announcements == false) then
        notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:announce', b.title, appendAnnounceExtras(def.settings, b.body), b.duration, b.kind)
    end

    local startFields = {
        { name = 'Operation', value = def.name, inline = true },
        { name = 'Type', value = 'Hot Cargo Run', inline = true },
        { name = 'Started By', value = startedByName, inline = true },
        { name = 'Trucks Spawned', value = ('%d of %d configured'):format(spawned, #truckEntries), inline = true },
        { name = 'Police Alert', value = HC.policeAlertEnabled(rt) and ('%ds stealth window'):format(def.hotCargo.policeAlertBufferSeconds or 0) or 'Disabled', inline = true },
        { name = 'Dropoff Destinations', value = tostring(#validDrops), inline = true },
        { name = 'Duration', value = ('%dm'):format(math.floor((def.eventDuration or 1200) / 60)), inline = true },
        { name = 'Eligibility', value = 'Open World (Gangs vs Police)', inline = true },
    }
    DiscordLog.startEvent(convoyId, ('🔥 Hot Cargo Run — %s'):format(def.name), 0xf97316, def.shortDescription or 'Contraband cargo vehicles spawned across the state. Secure the vehicles and deliver them to claim the unlocked reward crate!', startFields)
    DiscordLog.appendEvent(convoyId, ('🔥 Hot Cargo Run "%s" active (%d of %d configured trucks spawned, started by: %s)'):format(def.name, spawned, #truckEntries, startedByName))

    return true, def
end

-- ── Gang Rally / Street Race (GANG_RACE kind) ──────────────────────────────────

local function registerRallyRacer(rt, src, gangNameOverride, isCivilian)
    if not src or src <= 0 then return end
    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end

    local gName, gLabel, gColor, pType
    if isCivilian or gangNameOverride == 'civilian' then
        gName = 'civilian'
        gLabel = 'Civilian'
        gColor = '#38bdf8'
        pType = 'civilian'
    else
        local g = gangNameOverride and { name = gangNameOverride } or GangService.GetPlayerGang(src)
        gName = g and g.name or 'street_racers'
        local gIdent = gangIdentity(rt, gName)
        gLabel = gIdent and gIdent.label or (g and g.label or (gName == 'street_racers' and 'Street Racer' or gName))
        gColor = (gIdent and gIdent.color) or (Config.Gangs and Config.Gangs[gName] and Config.Gangs[gName].color) or '#f59e0b'
        pType = 'gang'
    end

    local pName = Bridge.GetPlayerName(src) or 'Racer'
    local tag = pName:sub(1, 4):upper()

    rt.participants = rt.participants or { identifiers = {}, gangCounts = {}, policeIdentifiers = {}, names = {}, types = {} }
    rt.participants.identifiers[identifier] = gName
    rt.participants.gangCounts[gName] = (rt.participants.gangCounts[gName] or 0) + 1
    rt.participants.names[identifier] = pName
    rt.participants.types = rt.participants.types or {}
    rt.participants.types[identifier] = pType

    rt.racers = rt.racers or {}
    rt.racers[src] = {
        source = src,
        identifier = identifier,
        name = pName,
        tag = tag,
        gang = gName,
        gangLabel = gLabel,
        gangColor = gColor,
        participantType = pType,
        isCivilian = (pType == 'civilian'),
        currentStage = 1,
        finished = false,
        finishTime = nil,
        lastCheckpointTime = os.time(),
        vehicleType = 'car',
        isOut = false,
    }

    TriggerClientEvent('nova_convoytruck:client:startRallyRace', src, {
        id = rt.id,
        name = rt.def.name,
        stages = rt.stages,
        difficulty = rt.def.difficulty or 'MEDIUM',
        staging = rt.phase == 'GRID',
    })
end

-- ── End-of-event entity purge ─────────────────────────────────────────────────
-- Every event kind (Convoy, Hot Cargo, Gang Airdrop, Race) calls this the moment it ends or
-- is force-ended. It deletes everything the event created that it still knows about (trucks,
-- trailers, drivers, loot crates, escort/checkpoint/ambush/guard peds and props, airdrop
-- crates) and then sweeps the world for anything tagged with this convoy_id that was spawned
-- by a thread that was still mid-flight when the event ended — those never made it into the
-- runtime tables, which is how entities used to be left behind after a force-end. Each step is
-- pcall'd so one bad handle can never abort the rest of the cleanup.
-- keepRewardCrates: leave a delivered Hot Cargo reward crate (60 min post-event protection).
local function purgeRuntimeEntities(rt, keepRewardCrates)
    if not rt then return end
    local function del(e)
        if e and e ~= 0 and DoesEntityExist(e) then pcall(DeleteEntity, e) end
    end
    local function npcs(list)
        if list then pcall(NpcManager.cleanup, list) end
    end
    -- Deleting a vehicle out from under a player can crash that player's game, so anyone still inside (a gang member
    -- driving a hijacked truck, an officer in an escort car) is moved out first and given a moment to leave.
    local function delVeh(e)
        if not e or e == 0 or not DoesEntityExist(e) then return end
        local okE, moved = pcall(ejectLivePlayersFrom, e)
        if okE and moved then Wait(250) end
        if DoesEntityExist(e) then pcall(DeleteEntity, e) end
    end

    for _, t in pairs(rt.trucks or {}) do
        local keepCrate = keepRewardCrates and t.delivered and t.stashId and tostring(t.stashId):find('^convoy_hotcargo_') ~= nil
        del(t.driverPed)
        local hadEntity = t.entity and DoesEntityExist(t.entity)
        delVeh(t.entity)
        delVeh(t.trailerEntity)
        if not keepCrate then
            -- Net ids are recycled: only trust one if the entity it points at is still tagged as THIS convoy's.
            if t.netId and t.netId ~= 0 and not hadEntity then
                pcall(function()
                    local ent = NetworkGetEntityFromNetworkId(t.netId)
                    if ent and ent ~= 0 and DoesEntityExist(ent) and tostring(Entity(ent).state.convoy_id) == tostring(rt.id) then
                        if GetEntityType(ent) == 2 then delVeh(ent) else del(ent) end
                    end
                end)
            end
            del(t.propEntity)
            if t.stashId then pcall(Inventory.ClearStash, t.stashId) end
        end
        if t.netId and not keepCrate then
            TriggerClientEvent('nova_convoytruck:runtime:cleanupTruck', -1, t.netId)
        end
    end

    npcs(rt.activeCheckpointNpcs); rt.activeCheckpointNpcs = nil
    npcs(rt.activeRouteNpcs); rt.activeRouteNpcs = nil
    npcs(rt.activeAmbushNpcs); rt.activeAmbushNpcs = nil
    for _, obj in ipairs(rt.activeCheckpointBarricades or {}) do del(obj) end
    rt.activeCheckpointBarricades = nil
    for _, veh in ipairs(rt.activeCheckpointVehicles or {}) do delVeh(veh) end
    rt.activeCheckpointVehicles = nil

    for _, dressing in pairs(rt.checkpointDressing or {}) do
        npcs(dressing.npcs)
        for _, obj in ipairs(dressing.barricades or {}) do del(obj) end
        for _, veh in ipairs(dressing.vehicles or {}) do delVeh(veh) end
        for _, id in ipairs(dressing.blipIds or {}) do pcall(removeNpcBlip, rt, id) end
    end
    rt.checkpointDressing = nil

    for _, guardList in pairs(rt.dropoffGuards or {}) do npcs(guardList) end
    rt.dropoffGuards = {}
    for _, guardList in pairs(rt.spawnGuards or {}) do npcs(guardList) end
    rt.spawnGuards = {}

    for _, entry in pairs(rt.airdrops or {}) do pcall(cleanupAirdrop, rt, entry) end

    for _, entry in pairs(rt.escortVehicles or {}) do delVeh(entry.vehicle) end

    -- World sweep: anything still carrying this convoy's id (and not marked to keep).
    local idStr = tostring(rt.id)
    for _, getter in ipairs({ GetAllVehicles, GetAllObjects, GetAllPeds }) do
        local ok, list = pcall(getter)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                if DoesEntityExist(e) then
                    local okS, st = pcall(function() return Entity(e).state end)
                    local tagged = st and ((st.convoy_id ~= nil and tostring(st.convoy_id) == idStr) or (st.nova_event_obj ~= nil and tostring(st.nova_event_obj) == idStr))
                    if okS and st and tagged and st.convoy_keep ~= true
                        and not (IsPedAPlayer and GetEntityType(e) == 1 and IsPedAPlayer(e)) then
                        if GetEntityType(e) == 2 then delVeh(e) else pcall(DeleteEntity, e) end
                    end
                end
            end
        end
    end
end

-- Runs purgeRuntimeEntities now and again a few times afterwards, so entities created by
-- threads that were mid-spawn when the event ended (late truck/guard/crate spawns) are removed
-- as soon as they appear instead of lingering until a resource restart.
local function purgeRuntimeEntitiesNow(rt, keepRewardCrates)
    local ok, err = pcall(purgeRuntimeEntities, rt, keepRewardCrates)
    if not ok then print(('[NovaConvoy] event cleanup error for convoy #%s: %s'):format(tostring(rt and rt.id), tostring(err))) end
    CreateThread(function()
        for _, delay in ipairs({ 3000, 12000, 40000 }) do
            Wait(delay)
            if active[rt.id] then return end -- the same convoy was started again; its own cleanup owns its entities now
            pcall(purgeRuntimeEntities, rt, keepRewardCrates)
        end
    end)
end

local function finishGangRaceEvent(rt, convoyId, forcedOutcome, forcedByName)
    purgeRuntimeEntitiesNow(rt)
    rt.raceFinished = true
    rt.def.raceGrid = false
    active[convoyId] = nil

    TriggerClientEvent('nova_convoytruck:client:endRallyRace', -1)
    TriggerClientEvent('nova_convoytruck:client:raceStartZoneClear', -1, convoyId)

    local outcome = forcedOutcome or (rt.raceWinner and 'COMPLETED' or 'FAILED')
    ConvoyManager.setStatus(convoyId, outcome)
    DB.deleteRuntime(convoyId)
    Scheduler.rearm(convoyId, rt.def)

    -- Gang leaderboard tracking for GANG_RACE: every real gang that entered gets a
    -- "joined"; a gang with at least one finisher gets "completed", otherwise
    -- "failed"; the gang of the 1st-place racer also gets a "won".
    do
        local isRealGang = function(n) return n and n ~= 'independent' and n ~= 'street_racers' and n ~= 'civilian' end
        local finishedGangs = {}
        for _, fr in ipairs(rt.finishedRacers or {}) do
            if fr.racer and isRealGang(fr.racer.gang) then finishedGangs[fr.racer.gang] = true end
        end
        local participatingGangs = {}
        for gangName in pairs(rt.participants.gangCounts or {}) do
            if isRealGang(gangName) then participatingGangs[gangName] = true end
        end
        for _, racer in pairs(rt.racers or {}) do
            if racer.gang and isRealGang(racer.gang) then
                participatingGangs[racer.gang] = true
            end
        end
        for gangName in pairs(participatingGangs) do
            if outcome ~= 'CANCELLED' then
                GangService.RecordOutcome(gangName, 'joined', 'GANG_RACE')
                GangService.RecordOutcome(gangName, finishedGangs[gangName] and 'completed' or 'failed', 'GANG_RACE')
            end
        end
        if outcome == 'COMPLETED' and rt.raceWinner and isRealGang(rt.raceWinner.gang) then
            GangService.RecordOutcome(rt.raceWinner.gang, 'won', 'GANG_RACE')
        end
    end

    -- Civilian leaderboard tracking for GANG_RACE
    if CivilianService and CivilianService.RecordResult and outcome ~= 'CANCELLED' then
        local recordedCivilians = {}
        for _, fr in ipairs(rt.finishedRacers or {}) do
            local racer = fr.racer
            if racer and (racer.isCivilian or racer.participantType == 'civilian' or racer.gang == 'civilian') then
                recordedCivilians[racer.identifier] = true
                local isWin = (fr.rank == 1)
                local isPodium = (fr.rank <= 3)
                local points = fr.rank == 1 and 25 or (fr.rank == 2 and 18 or (fr.rank == 3 and 15 or math.max(1, 10 - fr.rank)))
                local elapsed = fr.time or (fr.finishTime and rt.raceStartTime and (fr.finishTime - rt.raceStartTime)) or nil
                local playerRole = (racer.source and Bridge.GetPlayerJob and Bridge.GetPlayerJob(racer.source)) or 'Civilian'
                local rewardAmount = 0
                if rt.def.positionRewards then
                    local pList = (fr.rank == 1 and rt.def.positionRewards.first) or (fr.rank == 2 and rt.def.positionRewards.second) or (fr.rank == 3 and rt.def.positionRewards.third) or rt.def.positionRewards.participation
                    if pList then
                        for _, rw in ipairs(pList) do
                            rewardAmount = rewardAmount + (tonumber(rw.amount or rw.count or rw.cash) or 0)
                        end
                    end
                end
                CivilianService.RecordResult(racer.identifier, racer.name, playerRole, 'race', rt.def.name, {
                    wins = isWin and 1 or 0,
                    podiums = isPodium and 1 or 0,
                    participations = 1,
                    points = points,
                    rewards = rewardAmount,
                    bestTime = elapsed,
                })
            end
        end
        for _, racer in pairs(rt.racers or {}) do
            if (racer.isCivilian or racer.participantType == 'civilian' or racer.gang == 'civilian') and not recordedCivilians[racer.identifier] then
                recordedCivilians[racer.identifier] = true
                local playerRole = (racer.source and Bridge.GetPlayerJob and Bridge.GetPlayerJob(racer.source)) or 'Civilian'
                CivilianService.RecordResult(racer.identifier, racer.name, playerRole, 'race', rt.def.name, {
                    wins = 0,
                    podiums = 0,
                    participations = 1,
                    points = 1,
                    rewards = 0,
                })
            end
        end
    end

    -- Payout: per-finishing-position rewards (def.positionRewards.first/second/
    -- third/participation) take priority; any position left empty in the
    -- tablet pays nothing — there is no single-Reward fallback for races.
    if outcome == 'COMPLETED' then
        local pr = rt.def.positionRewards or {}
        local posLabel = { [1] = '1st Place', [2] = '2nd Place', [3] = '3rd Place' }
        for _, fr in ipairs(rt.finishedRacers or {}) do
            local racer = fr.racer
            if racer and racer.source then
                local list = (fr.rank == 1 and pr.first) or (fr.rank == 2 and pr.second) or (fr.rank == 3 and pr.third) or pr.participation
                -- No fallback: a position left empty in the tablet pays nothing.
                if list and #list > 0 then
                    RewardService.GiveRaceReward(rt.def, list, racer.source, posLabel[fr.rank] or ('Position %d'):format(fr.rank), rt.startedAt)
                end
            end
        end
    end

    -- Race tokens by finishing position (Config.RallyRace): 1st, 2nd, 3rd… get
    -- their own amount, any other finisher gets finishTokens. Added straight to
    -- the racer's inventory, logged, and included in the after-action report.
    rt.tokenLog = {}
    local raceCfg = Config.RallyRace or {}
    local tokenItem = raceCfg.tokenItem
    if tokenItem and tokenItem ~= '' and Inventory.ItemExists(tokenItem) then
        for _, fr in ipairs(rt.finishedRacers or {}) do
            local amount = math.floor(tonumber(raceCfg.tokensByPosition and raceCfg.tokensByPosition[fr.rank]) or tonumber(raceCfg.finishTokens) or 0)
            local racer = fr.racer
            if amount > 0 and racer and racer.source then
                local given = Inventory.AddItem(racer.source, tokenItem, amount, { event = rt.def.name, position = fr.rank }) and true or false
                if given then
                    -- Same reward card as the race cash (merged into one if they land together).
                    RewardService.Announce({ racer.source }, {
                        event = 'rally', title = 'RALLY RACE COMPLETED', name = rt.def.name, group = RewardService.RaceGroup(rt.def.id),
                        stats = { { label = 'Finish', value = ({ '1st Place', '2nd Place', '3rd Place' })[fr.rank] or ('Position %d'):format(fr.rank) } },
                        rewards = { { kind = 'token', label = 'Race tokens', value = ('×%d'):format(amount) } },
                    })
                else
                    -- Could not be added to the inventory: keep the old warning toast.
                    TriggerClientEvent('nova_convoytruck:client:rallyTokensAwarded', racer.source, amount, fr.rank, false)
                end
                if racer.gang and racer.gang ~= 'independent' and racer.gang ~= 'street_racers' and racer.gang ~= 'civilian' then
                    pcall(GangService.RecordTokens, racer.gang, amount)
                end
                rt.tokenLog[#rt.tokenLog + 1] = {
                    playerName = racer.name, playerIdentifier = racer.identifier, gangLabel = racer.gangLabel,
                    rank = fr.rank, amount = amount, given = given,
                    timestamp = os.time(), timeStr = os.date('!%H:%M:%S', os.time()),
                }
                DiscordLog.appendEvent(convoyId, ('🎟️ %s finished in position %d — %d race token%s%s'):format(
                    racer.name, fr.rank, amount, amount == 1 and '' or 's', given and '' or ' (could not be added to inventory)'))
                DB.insertConvoyEvent(convoyId, 'RACE_TOKENS', {
                    gangName = racer.gang, gangLabel = racer.gangLabel, playerIdentifier = racer.identifier, playerName = racer.name,
                    detail = ('Position %d — %d race token%s'):format(fr.rank, amount, amount == 1 and '' or 's'),
                })
            end
        end
    end

    -- Announcements to racers / public
    local rallyOutcomes = {
        COMPLETED = { key = 'rallyCompleted', title = '🏁 Gang Rally Concluded: ' .. rt.def.name, body = ('%s took 1st place on the podium! Race is finished.'):format(rt.raceWinner and rt.raceWinner.name or 'Champion'), kind = 'rally' },
        FAILED = { key = 'rallyFailed', title = 'Gang Rally Ended', body = 'Race duration expired before any driver crossed the finish line.', kind = 'warn' },
        CANCELLED = { key = 'rallyCancelled', title = 'Gang Rally Cancelled', body = 'The race was terminated by an administrator.', kind = 'danger' },
    }
    local rob = rallyOutcomes[outcome] or rallyOutcomes.FAILED
    local b = resolveBanner(rob.key, rob.title, rob.body, 8000, rob.kind)
    if b and (not rt.def.settings or rt.def.settings.announcements ~= false) then
        for _, s in ipairs(Bridge.GetPlayers()) do
            if not Bridge.IsPolice(s) or Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) or (rt.racers and rt.racers[s]) then
                notify({ s }, 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind)
            end
        end
    end

    -- ── POLICE HIGH-PRIORITY NFS PURSUIT DISPATCH & BLINKING DESTINATION BLIP ──
    -- Police receive NO alerts during prep/running; ONLY after race concludes!
    local finishStage = rt.stages and rt.stages[#rt.stages]
    if finishStage and finishStage.x then
        for _, s in ipairs(Bridge.GetPlayers()) do
            -- an officer who raced is a racer, not a pursuer: no pursuit alert for them
            if Bridge.IsPolice(s) and not (rt.racers and rt.racers[s]) then
                -- Send blinking red finish GPS blip to police
                TriggerClientEvent('nova_convoytruck:client:rallyPolicePursuit', s, {
                    x = finishStage.x,
                    y = finishStage.y,
                    z = finishStage.z,
                    name = rt.def.name,
                })
                -- High priority pursuit announcement banner
                local pb = resolveBanner('rallyPolicePursuitEnd',
                    '🚨 10-99 HIGH SPEED PURSUIT: ILLEGAL STREET RACE FINISH',
                    'An illegal street race ("%s") just concluded at %s! Racers and modified vehicles are fleeing the scene. Converge and initiate high-speed pursuit!',
                    10000, 'danger', rt.def.name, finishStage.name or 'the finish line')
                if pb then notify({ s }, 'nova_convoytruck:runtime:announce', pb.title, pb.body, pb.duration, pb.kind) end
            end
        end
    end

    -- "Event ended" banner the moment the race is over (winner, or nobody finished /
    -- cancelled), for gangs, racers and admins — not just a delayed stand-down.
    if not rt.def.settings or rt.def.settings.announcements ~= false then
        local eb
        if outcome == 'CANCELLED' then
            eb = resolveBanner('rallyEndedCancelled', '🏁 GANG RALLY CANCELLED', 'The race "%s" was cancelled by an administrator.', 8000, 'danger', rt.def.name)
        elseif rt.raceWinner then
            eb = resolveBanner('rallyEnded', '🏁 GANG RALLY ENDED', '"%s" is over. Winner: %s (%s).', 9000, 'success',
                rt.def.name, rt.raceWinner.name or 'Unknown', rt.raceWinner.gangLabel or rt.raceWinner.gang or 'Independent')
        else
            eb = resolveBanner('rallyEndedNoWinner', '🏁 GANG RALLY ENDED', '"%s" is over. Nobody finished in time.', 8000, 'warn', rt.def.name)
        end
        if eb then
            local audience, seen = {}, {}
            for _, s in ipairs(Runtime.raceAudience(rt.def)) do if not seen[s] then seen[s] = true audience[#audience + 1] = s end end
            for src in pairs(rt.racers or {}) do if not seen[src] then seen[src] = true audience[#audience + 1] = src end end
            notify(audience, 'nova_convoytruck:runtime:announce', eb.title, eb.body, eb.duration, 'rally')
        end
    end

    -- Stand-down banner after cooldown
    local standDown = (Config.AnnouncementBanners and (Config.AnnouncementBanners.rallyStandDown or Config.AnnouncementBanners.standDown)) or Config.ConvoyEndStandDown
    if standDown and standDown.enabled ~= false then
        CreateThread(function()
            Wait((standDown.delaySeconds or 6) * 1000)
            local sdb = resolveBanner(
                'rallyStandDown',
                'Gang Rally Concluded',
                'All units stand down. Scene cleared and race operation terminated.',
                standDown.duration or standDown.durationMs or 9000,
                standDown.kind or 'info'
            )
            if sdb then
                announceServerWide(rt, sdb.title, sdb.body, sdb.duration, sdb.kind)
            end
        end)
    end

    local gangIdentifiers = {}
    for identifier in pairs(rt.participants.identifiers or {}) do gangIdentifiers[#gangIdentifiers + 1] = identifier end

    local winnerText = 'None'
    if outcome == 'COMPLETED' and rt.raceWinner then
        winnerText = ('🏆 %s (%s)'):format(rt.raceWinner.name, rt.raceWinner.gangLabel or rt.raceWinner.gang or 'Independent')
    elseif outcome == 'CANCELLED' then
        winnerText = 'Cancelled by Administrator'
    elseif outcome == 'FAILED' then
        winnerText = 'None (Time Expired / Incomplete)'
    end

    local reportData = buildConvoyReportData(rt, outcome, forcedByName)

    DB.insertConvoyHistory({
        convoyDefinitionId = convoyId,
        name = rt.def.name,
        createdBy = rt.def.createdBy,
        startedAt = rt.startedAt,
        endedAt = os.time(),
        duration = os.time() - rt.startedAt,
        truckCount = 0,
        policeParticipants = 0,
        gangParticipants = #gangIdentifiers,
        winningGang = rt.raceWinner and rt.raceWinner.gang,
        outcome = outcome,
        rewardSummary = RewardService.describeRewards(rt.def.reward),
        destroyedTrucks = 0,
        checkpointsCompleted = #(rt.stages or {}),
        kind = 'GANG_RACE',
        reportData = reportData,
    })

    local durSec = os.time() - rt.startedAt
    local durText = ('%dm %02ds'):format(math.floor(durSec / 60), durSec % 60)

    local endFields = {
        { name = 'Event Tag', value = '[GANG RALLY] 🏁', inline = true },
        { name = 'Operation / Circuit', value = rt.def.name, inline = true },
        { name = 'Outcome', value = outcome, inline = true },
        { name = 'Winner', value = winnerText, inline = true },
        { name = 'Start Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', rt.startedAt), rt.startedAt), inline = true },
        { name = 'End Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', os.time()), os.time()), inline = true },
        { name = 'Duration', value = durText, inline = true },
        { name = 'Checkpoints / Stages', value = tostring(#(rt.stages or {})), inline = true },
        { name = 'Racers Participated', value = tostring(#gangIdentifiers), inline = true },
    }

    -- final standings: finishing order with each time, then how many did not finish
    do
        local goAt = rt.raceGoAt or rt.startedAt or os.time()
        local medals = { '🥇', '🥈', '🥉' }
        local lines, finishedIds = {}, {}
        for _, fr in ipairs(rt.finishedRacers or {}) do
            local r = fr.racer or {}
            finishedIds[r.identifier or ''] = true
            if #lines < 10 then
                local secs = math.max(0, math.floor((fr.finishTime or goAt) - goAt))
                lines[#lines + 1] = ('%s **%d.** %s (%s) — %d:%02d'):format(medals[fr.rank] or '🏁', fr.rank, r.name or 'Racer', r.gangLabel or r.gang or 'Independent', math.floor(secs / 60), secs % 60)
            end
        end
        local dnf = 0
        for _, r in pairs(rt.racers or {}) do
            if not finishedIds[r.identifier or ''] then dnf = dnf + 1 end
        end
        if #(rt.finishedRacers or {}) > #lines then lines[#lines + 1] = ('... and %d more finishers (see the report)'):format(#(rt.finishedRacers or {}) - #lines) end
        if dnf > 0 then lines[#lines + 1] = ('❌ %d did not finish'):format(dnf) end
        if #lines > 0 then
            endFields[#endFields + 1] = { name = ('🏁 Final Standings (%d finished)'):format(#(rt.finishedRacers or {})), value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
        end
        for _, f in ipairs(ReportBuilder.payoutFields(convoyId)) do endFields[#endFields + 1] = f end
    end

    if outcome == 'CANCELLED' and forcedByName then
        endFields[#endFields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true }
    end

    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(reportData)
    end

    if pdfString then
        endFields[#endFields + 1] = {
            name = '📄 After-Action Report (PDF)',
            value = 'Full tactical race report generated and attached to this message.',
            inline = false,
        }
    end

    local embedColor = outcome == 'COMPLETED' and 0xeab308 or (outcome == 'CANCELLED' and 0x6b7280 or 0xef4444)
    DiscordLog.finishEvent(convoyId, ('🏁 [GANG RALLY] Concluded — %s'):format(rt.def.name),
        embedColor, endFields, ('🏆 Winner: %s | Time: %s'):format(winnerText, durText), pdfString, 'GANG_RACE')
    RewardService.ClearPayouts(convoyId)
end

local function monitorGangRace(rt)
    CreateThread(function()
        local convoyId = rt.id
        while active[convoyId] == rt and not rt.raceFinished do
            Wait(1000)
            if active[convoyId] ~= rt or rt.raceFinished then break end

            -- The clock only runs once the green flag has dropped.
            if rt.phase ~= 'GRID' then
                rt.deliveryTimeRemaining = math.max(0, (rt.deliveryTimeRemaining or 1200) - 1)
            end

            -- Finish window after the winner crossed the line has run out
            if rt.finishDeadline and os.time() >= rt.finishDeadline then
                finishGangRaceEvent(rt, convoyId, 'COMPLETED')
                break
            end

            -- Check for race timeout
            if rt.deliveryTimeRemaining <= 0 then
                finishGangRaceEvent(rt, convoyId, rt.raceWinner and 'COMPLETED' or 'FAILED')
                break
            end

            -- Build leaderboard standings
            local racerList = {}
            for _, r in pairs(rt.racers or {}) do
                racerList[#racerList + 1] = r
            end

            table.sort(racerList, function(a, b)
                if (a.finished or false) ~= (b.finished or false) then
                    return a.finished == true
                end
                if a.finished and b.finished then
                    return (a.finishTime or 0) < (b.finishTime or 0)
                end
                if (a.currentStage or 1) ~= (b.currentStage or 1) then
                    return (a.currentStage or 1) > (b.currentStage or 1)
                end
                return (a.lastCheckpointTime or 0) < (b.lastCheckpointTime or 0)
            end)

            local drivers = {}
            local leader = racerList[1]
            local leaderCp = leader and leader.currentStage or 1

            for pos, r in ipairs(racerList) do
                local gapStr = 'LEADER'
                if pos > 1 and leader then
                    if r.finished and leader.finished then
                        local diff = (r.finishTime or 0) - (leader.finishTime or 0)
                        gapStr = ('+%.2fs'):format(math.max(0.01, diff))
                    else
                        local stageDiff = (leader.currentStage or 1) - (r.currentStage or 1)
                        if stageDiff > 0 then
                            gapStr = ('+%d CP'):format(stageDiff)
                        else
                            local timeDiff = (r.lastCheckpointTime or os.time()) - (leader.lastCheckpointTime or os.time())
                            gapStr = ('+%.1fs'):format(math.max(0.1, timeDiff))
                        end
                    end
                end

                local isCiv = (r.isCivilian == true or r.participantType == 'civilian' or r.gang == 'civilian')
                drivers[#drivers + 1] = {
                    position = pos,
                    identifier = r.identifier,
                    -- In-game character name only — Bridge.GetPlayerName appends the cfx account name in brackets.
                    name = tostring(r.name or 'Racer'):gsub('%s*%b()%s*$', ''),
                    tag = r.tag or (r.name and r.name:sub(1, 4):upper() or ('P' .. pos)),
                    gangLabel = isCiv and nil or r.gangLabel,
                    gangColor = isCiv and '#64748b' or (r.gangColor or (pos == 1 and '#f97316' or '#64748b')),
                    gap = gapStr,
                    vehicleType = r.vehicleType or 'car',
                    isOut = r.isOut == true,
                    finished = r.finished == true,
                    -- Checkpoints cleared after the start line (stage 1 = start, last = finish).
                    cp = r.finished and math.max(1, #rt.stages - 1) or math.min(math.max(0, (r.currentStage or 1) - 2), math.max(1, #rt.stages - 1)),
                }
            end

            local racerSources = {}
            for _, rr in pairs(rt.racers or {}) do
                if rr.source and rr.source > 0 then racerSources[#racerSources + 1] = rr.source end
            end

            local towerPayload = {
                title = rt.def.name,
                currentCheckpoint = math.min(math.max(1, #rt.stages - 1), math.max(0, leaderCp - 2)),
                totalCheckpoints = math.max(1, #rt.stages - 1), -- everything after the start line, finish included
                currentLap = 1,
                totalLaps = 1,
                racers = drivers,
                -- Race clock starts at GO, not while the grid is filling / counting down.
                elapsedSeconds = (rt.raceGoAt and rt.phase ~= 'GRID') and math.max(0, os.time() - rt.raceGoAt) or 0,
            }

            -- Each racer gets the same standings with their own row flagged.
            for _, r in pairs(rt.racers or {}) do
                if r.source and r.source > 0 then
                    towerPayload.myIdentifier = r.identifier
                    towerPayload.collision = not (rt.def.settings and rt.def.settings.raceCollision == 'OFF')
                    towerPayload.racerSources = racerSources
                    towerPayload.maxRows = tonumber(Config.RallyRace and Config.RallyRace.scoreboardRows) or 8
                    TriggerClientEvent('nova_convoytruck:client:updateRallyTower', r.source, towerPayload)
                end
            end
        end
    end)
end

-- Start grid: racers gather at the START stage; once all of them are within its
-- radius (or the wait runs out) everybody gets the 3-2-1-GO countdown together.
local function startRaceGridThread(rt)
    CreateThread(function()
        local convoyId = rt.id
        local startStage = rt.stages[1]
        local cfg = Config.RallyRace or {}
        local reach = math.max(tonumber(startStage.radius) or 15.0, tonumber(cfg.gridRadius) or 40.0)
        while active[convoyId] == rt and not rt.raceFinished and rt.phase == 'GRID' do
            local total, ready = 0, 0
            for src, racer in pairs(rt.racers or {}) do
                if racer.source and not racer.isOut then
                    total = total + 1
                    local ped = GetPlayerPed(src)
                    if ped and ped ~= 0 then
                        local pc = GetEntityCoords(ped)
                        if #(vector3(pc.x, pc.y, pc.z) - vector3(startStage.x, startStage.y, startStage.z or pc.z)) <= reach then ready = ready + 1 end
                    end
                end
            end
            local left = math.max(0, rt.gridDeadline - os.time())
            for _, racer in pairs(rt.racers or {}) do
                if racer.source then TriggerClientEvent('nova_convoytruck:client:rallyGridStatus', racer.source, ready, total, left) end
            end
            if rt.forceGo or left <= 0 then break end
            -- Everyone is on the grid: start the 3-2-1-GO after a short settle
            -- (Config.RallyRace.autoCountdown = false leaves it to an organiser).
            if cfg.autoCountdown ~= false and total > 0 and ready >= total then
                rt.allReadyTicks = (rt.allReadyTicks or 0) + 1
                if rt.allReadyTicks >= (tonumber(cfg.autoCountdownSettleSeconds) or 3) then break end
            else
                rt.allReadyTicks = 0
            end
            Wait(1000)
        end
        if active[convoyId] ~= rt or rt.raceFinished then return end
        rt.phase = 'RACING'
        rt.def.raceGrid = false
        TriggerClientEvent('nova_convoytruck:client:raceStartZoneClear', -1, convoyId)
        rt.raceGoAt = os.time() + 15 -- matches the client's 15-second on-screen countdown (runRaceCountdown)
        rt.startedAt = rt.raceGoAt
        for _, racer in pairs(rt.racers or {}) do
            if racer.source then TriggerClientEvent('nova_convoytruck:client:rallyCountdown', racer.source) end
        end
        do
            local why = rt.forceGo and ('started manually by ' .. tostring(rt.countdownBy or 'an organiser')) or ((rt.gridDeadline - os.time()) <= 0 and 'grid wait time ran out' or 'all racers in position')
            local nReady = 0
            for _ in pairs(rt.racers or {}) do nReady = nReady + 1 end
            DiscordLog.appendEvent(convoyId, ('🚦 Countdown started (%s) — %d racer%s on the grid'):format(why, nReady, nReady == 1 and '' or 's'))
        end
    end)
end

-- Races in their "starts in N minutes" lead-in (before the grid opens).
local racePending = {}
local raceLeadSkip = {}

function Runtime.isRacePending(convoyId)
    return racePending[tonumber(convoyId)] == true
end

-- Organiser's "Start Countdown": ends the grid wait and runs 3-2-1-GO now.
-- During the lead-in it skips the remaining wait and opens the grid straight away.
function Runtime.startRaceCountdown(source, convoyId)
    if source and source > 0 and not UserPermissions.can(source, 'convoys.manage') then return false, 'Not authorized.' end
    if racePending[tonumber(convoyId)] then
        raceLeadSkip[tonumber(convoyId)] = true
        return true
    end
    local rt = active[tonumber(convoyId)]
    if not rt or rt.def.kind ~= 'GANG_RACE' then return false, 'That race is not running.' end
    if rt.phase ~= 'GRID' then return false, 'The countdown has already started.' end
    rt.forceGo = true
    rt.countdownBy = (source and source > 0) and (Bridge.GetPlayerName(source) or 'Organiser') or 'Console'
    return true
end

-- The GRID (waiting-for-racers) race, if exactly one exists — for the command.
function Runtime.findGridRace()
    local found
    for id, rt in pairs(active) do
        if rt.def and rt.def.kind == 'GANG_RACE' and rt.phase == 'GRID' then
            if found then return nil end
            found = id
        end
    end
    return found
end

local function doStartGangRaceNow(def, convoyId, starterSource)
    if not def.rallyStages or #def.rallyStages == 0 then
        return false, 'Add at least one checkpoint or stage before starting Gang Rally.'
    end

    if def.settings then
        def.settings.forceDriveBy = false
    end

    local stages = {}
    for i, s in ipairs(def.rallyStages) do
        if not (tonumber(s.x) and tonumber(s.y)) then
            return false, ('Stage %d ("%s") has no position yet — place it on the map or remove it before starting.'):format(i, tostring(s.name or i))
        end
        stages[i] = {
            id = s.id or ('stage_' .. i),
            order = i,
            name = s.name or ('Stage ' .. i),
            x = tonumber(s.x),
            y = tonumber(s.y),
            z = tonumber(s.z),
            heading = tonumber(s.heading) or 0.0,
            radius = tonumber(s.radius) or 15.0,
        }
    end

    local startedByName = 'Automated Schedule'
    if starterSource and starterSource > 0 then
        local pName = Bridge.GetPlayerName(starterSource)
        local pIdent = Bridge.GetIdentifier(starterSource)
        startedByName = ('%s (%s)'):format(pName or 'Admin', pIdent or 'N/A')
    end

    local rt = {
        id = convoyId,
        def = def,
        route = {},
        status = 'ACTIVE',
        deliveryTimeRemaining = def.eventDuration or 1200,
        trucks = {},
        startedAt = os.time(),
        startedByName = startedByName,
        startedBySource = starterSource,
        participants = { identifiers = {}, gangCounts = {}, policeIdentifiers = {}, names = {} },
        gangVisibilityUnlocked = true,
        stages = stages,
        racers = {},
        finishedRacers = {},
        raceWinner = nil,
        raceFinished = false,
        totalStages = #stages,
        phase = 'GRID',
        gridDeadline = os.time() + math.max(15, math.floor(tonumber(def.settings and def.settings.raceGridWaitSeconds) or tonumber(Config.RallyRace and Config.RallyRace.gridWaitSeconds) or 180)),
    }

    active[convoyId] = rt
    ConvoyManager.setStatus(convoyId, 'ACTIVE')
    persist(rt)

    -- Auto-join pre-registered gang members from def.roster
    for gangName, identList in pairs(def.roster or {}) do
        for _, ident in ipairs(identList or {}) do
            local src = findSourceByIdentifier(ident)
            if src then
                registerRallyRacer(rt, src, gangName)
            end
        end
    end

    -- Auto-join pre-registered civilians from def.civilianRoster
    for _, ident in ipairs(def.civilianRoster or {}) do
        local src = findSourceByIdentifier(ident)
        if src then
            registerRallyRacer(rt, src, 'civilian', true)
        end
    end

    -- Auto-join starter player if not police
    if starterSource and starterSource > 0 and not Bridge.IsPolice(starterSource) then
        registerRallyRacer(rt, starterSource)
    end

    def.raceGrid = true
    monitorGangRace(rt)
    startRaceGridThread(rt)

    -- Every gang member, registered civilian (and admin) gets the start-zone blip while the grid fills.
    do
        local s1 = stages[1]
        notify(Runtime.raceAudience(def), 'nova_convoytruck:client:raceStartZone', {
            id = convoyId, name = def.name, x = s1.x, y = s1.y, z = s1.z, radius = s1.radius,
        })
    end

    -- Announce start to racers / gangs (POLICE DO NOT RECEIVE THIS)
    for _, s in ipairs(Bridge.GetPlayers()) do
        if not Bridge.IsPolice(s) or Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) then
            if Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) or Bridge.HasCreatorAccess(s) then
                TriggerClientEvent('nova_convoytruck:gang:toast', s, '🏁', 'Gang Rally Active', ('"%s" street race circuit is live across %d stages.'):format(def.name, #stages), false)
            end
        end
    end

    local b = resolveBanner('rallyRaceStarted', '🏁 GANG RALLY: ' .. def.name, 'Street race circuit is live! Racers floor it across ' .. #stages .. ' checkpoints!', 8000, 'rally')
    if b and (not def.settings or def.settings.announcements ~= false) then
        for _, s in ipairs(Bridge.GetPlayers()) do
            if not Bridge.IsPolice(s) or Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) or (rt.racers and rt.racers[s]) then
                notify({ s }, 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, 'rally')
            end
        end
    end

    local startFields = {
        { name = 'Event Tag', value = '[GANG RALLY] 🏁', inline = true },
        { name = 'Circuit Name', value = def.name, inline = true },
        { name = 'Checkpoints / Stages', value = tostring(#stages), inline = true },
        { name = 'Duration Limit', value = ('%dm'):format(math.floor((def.eventDuration or 1200) / 60)), inline = true },
        { name = 'Started By', value = startedByName, inline = true },
        { name = 'Max Racers', value = tostring(def.maxGangParticipants or 20), inline = true },
        { name = 'Eligibility', value = 'Street Racers / Active Gangs', inline = true },
        { name = 'Entry Format', value = (def.settings and def.settings.raceEntryMode == 'OPEN') and 'Open race' or ('Team race (%d per gang)'):format((def.settings and def.settings.maxMembersPerGang) or 2), inline = true },
        { name = 'Vehicles', value = (def.settings and def.settings.raceVehicleMode == 'PROVIDED') and 'Provided by race vehicle ped' or 'Racers bring their own', inline = true },
        { name = 'Collision', value = (def.settings and def.settings.raceCollision == 'OFF') and 'OFF (ghost race)' or 'ON', inline = true },
        { name = 'Start Grid', value = (Config.RallyRace and Config.RallyRace.autoCountdown == false) and 'Manual countdown' or 'Auto when all in position', inline = true },
    }
    local rewardDesc = RewardService.describeRewards(def.reward)
    if rewardDesc and rewardDesc ~= '' and rewardDesc ~= 'None' then
        startFields[#startFields + 1] = { name = 'Prize Stakes', value = rewardDesc, inline = false }
    end

    DiscordLog.startEvent(convoyId, ('🏁 [GANG RALLY] Street Race — %s'):format(def.name), 0xeab308, def.shortDescription or 'High stakes street rally underway! Racers competing for 1st place podium victory.', startFields)
    DiscordLog.appendEvent(convoyId, ('🏁 Green flag dropped! Racers departed grid across %d stages (Started by: %s)'):format(#stages, startedByName))

    return true, def
end

-- Manual "Start" of a race gives everyone a heads-up first: "starts in N minutes"
-- banners (server-wide, police excluded) with reminders, then the green flag.
-- Lead time = the event's own start delay (General tab) or Config.RallyRace.
-- startLeadSeconds. Scheduled starts skip this — they already got the
-- pre-schedule announcement (Config.PreScheduleAnnounceSeconds).
-- HH:MM:SS, so a long wait ("01:30:00") reads the same as a short one ("00:00:45")
local function fmtLead(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return ('%02d:%02d:%02d'):format(math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60)
end

-- Race announcements go to gang members (and admins) only — and civilians if open to everyone
local function raceAudience(def)
    local out = {}
    local isEveryone = def and def.settings and (def.settings.eventAccess == 'EVERYONE' or def.settings.eventAccess == 'everyone' or def.eventAccess == 'EVERYONE')
    for _, s in ipairs(Bridge.GetPlayers()) do
        if Bridge.IsAdmin(s, Config.CreatorAccess.adminPermission) then
            out[#out + 1] = s
        elseif not Bridge.IsPolice(s) then
            if isEveryone or GangService.GetPlayerGang(s) then
                out[#out + 1] = s
            end
        end
    end
    return out
end
Runtime.raceAudience = raceAudience

local function announceRaceLead(def, remaining)
    if def.settings and def.settings.announcements == false then return end
    local b = resolveBanner('rallyStartingSoon', '🏁 GANG RALLY STARTING SOON',
        'The street race "%s" starts in %s. Participants, be ready! Head to the flashing start zone.', 9000, 'rally', def.name, fmtLead(remaining))
    if not b then return end
    notify(raceAudience(def), 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, 'rally')
end

local function doStartGangRace(def, convoyId, starterSource)
    if racePending[convoyId] then return false, 'This race is already counting down to its start.' end

    local lead = 0
    if starterSource and starterSource > 0 then
        local own = def.settings and tonumber(def.settings.startAnnounceDelaySeconds)
        lead = math.max(0, math.floor(own or tonumber(Config.RallyRace and Config.RallyRace.startLeadSeconds) or 0))
    end
    if lead <= 0 then return doStartGangRaceNow(def, convoyId, starterSource) end

    -- Validate now so an invalid race fails immediately, not after the wait.
    if not def.rallyStages or #def.rallyStages == 0 then
        return false, 'Add at least one checkpoint or stage before starting Gang Rally.'
    end
    for i, s in ipairs(def.rallyStages) do
        if not (tonumber(s.x) and tonumber(s.y)) then
            return false, ('Stage %d ("%s") has no position yet — place it on the map or remove it before starting.'):format(i, tostring(s.name or i))
        end
    end

    racePending[convoyId] = true
    CreateThread(function()
        local endsAt = os.time() + lead
        local marks = {}
        local reminders = (Config.RallyRace and Config.RallyRace.leadReminders) or { 600, 300, 180, 120, 60, 30, 10 }
        table.sort(reminders, function(a, b) return a > b end)
        for _, m in ipairs(reminders) do
            if m < lead then marks[#marks + 1] = m end
        end
        announceRaceLead(def, lead)
        local zoned = {}
        while true do
            local remaining = endsAt - os.time()
            if remaining <= 0 or raceLeadSkip[convoyId] then break end
            if #marks > 0 and remaining <= marks[1] then
                announceRaceLead(def, remaining)
                table.remove(marks, 1)
                while #marks > 0 and remaining <= marks[1] do table.remove(marks, 1) end
            end
            local cur = ConvoyManager.get(convoyId)
            if not racePending[convoyId] or not cur or cur.status == 'CANCELLED' then
                racePending[convoyId] = nil
                raceLeadSkip[convoyId] = nil
                TriggerClientEvent('nova_convoytruck:client:raceLeadClear', -1)
                TriggerClientEvent('nova_convoytruck:client:raceStartZoneClear', -1, convoyId)
                -- Cancelled before the green flag: tell every gang (and admins) it's off.
                if not def.settings or def.settings.announcements ~= false then
                    local cb = resolveBanner('rallyEndedCancelled', '🏁 GANG RALLY CANCELLED', 'The race "%s" was cancelled by an administrator.', 8000, 'danger', def.name)
                    if cb then notify(raceAudience(def), 'nova_convoytruck:runtime:announce', cb.title, cb.body, cb.duration, 'rally') end
                end
                return
            end
            -- Live "starts in" timer for gang members / registered racers.
            local seen, audience = {}, {}
            for _, s in ipairs(raceAudience(def)) do seen[s] = true audience[#audience + 1] = s end
            -- registered racers too, but never on-duty police (a common race is not their business)
            for _, idents in pairs(def.roster or {}) do
                for _, ident in ipairs(idents or {}) do
                    local s = findSourceByIdentifier(ident)
                    if s and not seen[s] and not Bridge.IsPolice(s) then seen[s] = true audience[#audience + 1] = s end
                end
            end
            for _, ident in ipairs(def.civilianRoster or {}) do
                local s = findSourceByIdentifier(ident)
                if s and not seen[s] and not Bridge.IsPolice(s) then seen[s] = true audience[#audience + 1] = s end
            end
            notify(audience, 'nova_convoytruck:client:raceLeadStatus', def.name, remaining)
            -- Mark the start zone on the map for everyone the moment the race is announced
            -- (once per player, including anyone who comes online during the lead-in).
            local s1 = def.rallyStages[1]
            for _, s in ipairs(audience) do
                if not zoned[s] then
                    zoned[s] = true
                    TriggerClientEvent('nova_convoytruck:client:raceStartZone', s, {
                        id = convoyId, name = def.name, x = tonumber(s1.x), y = tonumber(s1.y), z = tonumber(s1.z), radius = tonumber(s1.radius) or 15.0,
                    })
                end
            end
            Wait(1000)
        end
        racePending[convoyId] = nil
        raceLeadSkip[convoyId] = nil
        TriggerClientEvent('nova_convoytruck:client:raceLeadClear', -1)
        local cur = ConvoyManager.get(convoyId)
        if cur and cur.status ~= 'CANCELLED' and not active[convoyId] then
            local ok, err = doStartGangRaceNow(cur, convoyId, starterSource)
            if not ok then lib.print.warn(('[NovaConvoy] Race #%d failed to start after its countdown: %s'):format(convoyId, tostring(err))) end
        end
    end)
    return true, def
end

-- True when the player is close enough to a stage for a checkpoint report:
-- within its radius (+ padding) of the trigger vector.
local function racerNearStage(src, stage)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return true end
    local pc = GetEntityCoords(ped)
    local pad = tonumber(Config.RallyRace and Config.RallyRace.reportPadding) or 45.0
    local reach = (tonumber(stage.radius) or 15.0) + pad
    return stage.x and stage.y and #(vector3(pc.x, pc.y, pc.z) - vector3(stage.x, stage.y, stage.z or pc.z)) <= reach or false
end

RegisterNetEvent('nova_convoytruck:rally:server:checkpointHit', function(convoyId, stageIndex)
    local src = source
    local rt = active[convoyId]
    if not rt or rt.def.kind ~= 'GANG_RACE' then return end

    if rt.raceFinished then return end
    local racer = rt.racers and rt.racers[src]
    if not racer then return end

    stageIndex = tonumber(stageIndex)
    if not stageIndex then return end
    -- Server-side validation: a report is only accepted for the racer's own
    -- next stage, and only while their ped is actually at it. Without this a
    -- modified client could report the finish line from the start grid.
    -- A rejected report tells the client which stage the server is actually
    -- waiting for, so one dropped hit can never leave the racer permanently
    -- out of step (and unable to ever register the finish).
    local function resync()
        TriggerClientEvent('nova_convoytruck:client:rallyStageSync', src, racer.currentStage or 1)
    end
    if stageIndex ~= (racer.currentStage or 1) then return resync() end
    -- Nothing past the start line counts until the countdown has finished.
    if stageIndex > 1 and (rt.phase == 'GRID' or (rt.raceGoAt and os.time() < rt.raceGoAt)) then return resync() end
    local vStage = rt.stages[stageIndex]
    if not vStage then return end
    if not racerNearStage(src, vStage) then return resync() end

    racer.currentStage = stageIndex + 1
    racer.lastCheckpointTime = os.time()

    local currentStage = rt.stages[stageIndex]

    DiscordLog.appendEvent(convoyId, ('📍 %s reached Checkpoint %d/%d (%s)'):format(
        racer.name,
        stageIndex,
        #rt.stages,
        currentStage and currentStage.name or ('Stage ' .. stageIndex)
    ))

    -- Check if crossed finish line
    if stageIndex >= #rt.stages and not racer.finished then
        racer.finished = true
        racer.finishTime = os.time()
        rt.finishedRacers = rt.finishedRacers or {}
        local rank = #rt.finishedRacers + 1
        rt.finishedRacers[rank] = {
            racer = racer,
            rank = rank,
            finishTime = racer.finishTime,
            duration = racer.finishTime - (rt.startedAt or os.time()),
        }

        -- Instant on-screen finish banner for this racer (position + tokens + time).
        if racer.source then
            local rc = Config.RallyRace or {}
            local prize = math.floor(tonumber(rc.tokensByPosition and rc.tokensByPosition[rank]) or tonumber(rc.finishTokens) or 0)
            -- The Gang XP this finishing position will pay (the event's reward list for the position, paid when the race
            -- concludes). Only a gang member earns it (on-duty police and civilians get 0), so only then is it shown.
            local xp = 0
            local pr = rt.def.positionRewards or {}
            local posList = (rank == 1 and pr.first) or (rank == 2 and pr.second) or (rank == 3 and pr.third) or pr.participation
            if posList and GangXP and GangXP.GangOf(racer.source, false, true) then
                local cap = tonumber(((Config.Territory or {}).gangXp or {}).maxPerAward) or 1000000
                for _, rw in ipairs(posList) do
                    if string.upper(tostring(rw.type or rw.rewardType or rw.kind or '')) == 'GANG_XP' then
                        xp = xp + math.min(cap, math.max(0, math.floor(tonumber(rw.amount or rw.count or rw.quantity or rw.value) or 0)))
                    end
                end
            end
            TriggerClientEvent('nova_convoytruck:client:rallyFinishBanner', racer.source, rank, prize, racer.finishTime - (rt.startedAt or racer.finishTime), xp)
        end

        local window = tonumber(Config.RallyRace and Config.RallyRace.finishWindowSeconds) or 60
        if rank == 1 then
            rt.raceWinner = racer
            DiscordLog.appendEvent(convoyId, ('🏆 WINNER: %s (%s) crossed the finish line in 1st place!'):format(
                racer.name,
                racer.gangLabel or racer.gang or 'Independent'
            ))
            -- Everyone else gets a short window to cross the line so 2nd, 3rd…
            -- positions (and their race tokens) count.
            rt.finishDeadline = os.time() + math.max(0, window)
        else
            DiscordLog.appendEvent(convoyId, ('🏁 %s (%s) finished in position %d'):format(
                racer.name, racer.gangLabel or racer.gang or 'Independent', rank))
        end

        -- Conclude once nobody is still racing (or there is no finish window).
        local stillRacing = 0
        for _, r in pairs(rt.racers or {}) do
            if not r.finished and not r.isOut then stillRacing = stillRacing + 1 end
        end
        if stillRacing == 0 or window <= 0 then
            -- Give the finisher a few seconds with their own finish banner / position
            -- before the "race ended" announcements go out over the top of it.
            local delay = math.max(0, tonumber(Config.RallyRace and Config.RallyRace.concludeDelaySeconds) or 8)
            if rt.concluding then return end
            rt.concluding = true
            SetTimeout(delay * 1000, function()
                if active[convoyId] == rt and not rt.raceFinished then
                    finishGangRaceEvent(rt, convoyId, 'COMPLETED')
                end
            end)
        end
    end
end)

-- Flips a held convoy loose: trucks start actually driving, gangs unlock
-- truck-blip visibility, and the public "Convoy Started" banner fires — all
-- at the same instant, so "the buffer ends" reads as one clean moment
-- instead of three separate things happening at different times. Called
-- either immediately (no buffer configured) or after the police head-start
-- delay elapses (see doStart below).
-- Unfreezes + tasks a single batch of trucks and broadcasts the release to
-- clients — pulled out of releaseConvoy so it can be called twice (an
-- immediate batch, then a deferred one) for the hierarchy stagger below,
-- without duplicating the per-truck logic.
-- Unfreezes every truck and tells clients to unfreeze/engine-on their own
-- copy — the actual DRIVE TASKING (who drives to the point directly, who
-- escorts the truck ahead of it) is handled entirely separately by
-- driveColumn, called BEFORE this in releaseConvoy below, so every truck's
-- convoy_target statebag is already column-aware by the time this fires.
-- No targetPoint override passed to the client event on purpose — it used
-- to hand every single truck the SAME literal target regardless of column
-- position, which is exactly what made every truck (lead AND followers)
-- independently long-range-pathfind to the same distant point right at
-- departure instead of the column following itself, reported as "trucks
-- struggling to find the route" starting from the very first moment.
local function releaseTrucksBatch(rt, trucks)
    local truckList = {}
    for _, t in ipairs(trucks) do
        if t.entity and DoesEntityExist(t.entity) then
            FreezeEntityPosition(t.entity, false)
            Entity(t.entity).state:set('releaseHeld', false, true)
            truckList[#truckList + 1] = {
                vehNetId = t.netId,
                pedNetId = t.driverPed and DoesEntityExist(t.driverPed) and NetworkGetNetworkIdFromEntity(t.driverPed) or nil,
            }
        end
    end
    if #truckList > 0 then
        TriggerClientEvent('nova_convoytruck:runtime:releaseTrucks', -1, truckList)
    end
end

local function releaseConvoy(rt)
    rt.releaseHeld = false
    rt.gangVisibilityUnlocked = true

    -- Advance past START point immediately so trucks don't wait or stall
    if rt.route[rt.currentRouteIndex] and rt.route[rt.currentRouteIndex].type == 'START' then
        rt.currentRouteIndex = rt.currentRouteIndex + 1
    end
    local targetPoint = rt.route[rt.currentRouteIndex]
    local driveTarget = resolveDriveTarget(rt, rt.currentRouteIndex)

    -- Reverted the hierarchy-staggered departure (SECONDARY_CARGO released
    -- ~2.5s after everyone else): a truck released late but still commanded
    -- to drive straight to wherever rt.currentRouteIndex currently points
    -- (which may already be further along the route than that truck's own
    -- position) could get sent cutting cross-country to "catch up" instead
    -- of following the real road route the others took — reported as
    -- trucks suddenly climbing hills/reversing, working fine before this
    -- was added. Back to releasing every truck together, all commanded to
    -- the same driveTarget at the same instant.
    --
    -- driveColumn FIRST, unconditionally forced — this is what sets each
    -- truck's convoy_target correctly for its actual column role (the lead
    -- drives to driveTarget, everyone else escorts the truck directly ahead
    -- of it via TaskVehicleEscort). releaseTrucksBatch below only unfreezes
    -- and tells clients to start driving off whatever's already in that
    -- statebag — it must run AFTER this, never before, or the client-side
    -- unfreeze races the statebag write and can read a stale/empty target.
    driveColumn(rt, driveTarget, nil, true)
    local allTrucks = {}
    for _, t in pairs(rt.trucks or {}) do allTrucks[#allTrucks + 1] = t end
    releaseTrucksBatch(rt, allTrucks)

    -- Remove the staging zone circle now that trucks are actually moving
    TriggerClientEvent('nova_convoytruck:runtime:stagingZoneRemove', -1)

    local cargoLabel = (rt.def.cargo and rt.def.cargo.description and rt.def.cargo.description ~= '' and rt.def.cargo.description)
        or (rt.def.cargo and rt.def.cargo.type and rt.def.cargo.type ~= '' and rt.def.cargo.type)
        or 'Secure Cargo'

    local b = resolveBanner(
        'convoyStart',
        'HIGH-VALUE CONVOY DEPARTED',
        'A transport convoy carrying %s has departed under armed escort. Intercept the convoy or protect the shipment!',
        8000,
        'start',
        cargoLabel
    )
    if b then
        announceServerWide(rt, b.title, appendAnnounceExtras(rt.def.settings, b.body), b.duration, b.kind)
    end

    local allSources = allParticipantSources(rt)
    notify(allSources, 'nova_convoytruck:runtime:startDeliveryTimer', rt.deliveryTimeRemaining)
    broadcastPoliceStatus(rt, policeAndAdminSources(rt))
    broadcastGangStatus(rt)

    if Config.PoliceAlwaysSeeRouteZones ~= false then
        notify(policeAndAdminSources(rt), 'nova_convoytruck:runtime:policeRouteZones', buildRouteZones(rt))
    end

    pcall(sendConvoyProgress, rt)

    -- the sky beacons on every checkpoint: police / admins now, gangs only if Config.CheckpointBeacon says so
    for _, s in ipairs(policeAndAdminSources(rt)) do sendCheckpointBeacons(rt, s) end
    if (Config.CheckpointBeacon or {}).showToGangsFromStart then
        for _, s in ipairs(gangParticipantSources(rt)) do sendCheckpointBeacons(rt, s) end
    end
end

local function doStart(convoyId, starterSource)
    -- Temporary diagnostic — pin down exactly which gate a "failed to start"
    -- report is hitting instead of guessing. Safe/cheap to leave in; remove
    -- once Hot Cargo start is confirmed reliable again.
    print(('[NovaConvoy] doStart(%s) called. active[id]=%s'):format(tostring(convoyId), tostring(active[convoyId] ~= nil)))
    if active[convoyId] then return false, 'This event is already running.' end

    local def = ConvoyManager.get(convoyId)
    if not def then
        print(('[NovaConvoy] doStart(%s): ConvoyManager.get returned nil — definition not found.'):format(tostring(convoyId)))
        return false, 'Event not found.'
    end
    print(('[NovaConvoy] doStart(%s): kind=%s status=%s'):format(tostring(convoyId), tostring(def.kind), tostring(def.status)))
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then
        return false, 'Only draft or scheduled events can be started.'
    end
    if def.kind == 'GANG_AIRDROP' then return doStartGangAirdrop(def, convoyId, starterSource) end
    if def.kind == 'HOT_CARGO' then return doStartHotCargo(def, convoyId, starterSource) end
    if def.kind == 'GANG_RACE' then return doStartGangRace(def, convoyId, starterSource) end
    -- TDM lives entirely in tdm_runtime.lua's own module — without this
    -- branch a TDM def would fall straight through into the plain-CONVOY
    -- start path below (no trucks, no route), both from a manual start AND
    -- an unattended scheduled auto-start (Runtime.startScheduled also funnels
    -- through here). Tournament format isn't runnable until Phase 3 —
    -- Tdm.start itself rejects that case with a clear message.
    if def.kind == 'TDM' then return Tdm.start(starterSource, convoyId) end
    if def.kind == 'CONTAINER_WARS' then return ContainerWars.start(starterSource, convoyId) end
    -- Gang Territory Auction lives in territory_auction.lua (it shares AuctionCore with Container Wars)
    if def.kind == 'GANG_TERRITORY' then return TerritoryAuction.start(starterSource, convoyId) end
    -- Operation Crackdown (Gang vs Police) lives in crackdown_runtime.lua
    if def.kind == 'CRACKDOWN' then return Crackdown.start(starterSource, convoyId) end
    if #def.trucks == 0 then return false, 'Add at least one truck before starting.' end

    local hasCargoTruck = false
    for _, t in ipairs(def.trucks) do
        if t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO' then hasCargoTruck = true break end
    end
    if not hasCargoTruck then return false, 'Add at least one cargo truck (Primary or Secondary Cargo role) before starting.' end

    local route, airdropPoints = splitRoute(sortedRoute(def))
    local startPoint = findPoint(route, 'START')
    local destPoint = findPoint(route, 'DESTINATION')
    if not startPoint or not destPoint then return false, 'Route needs a START and a DESTINATION point.' end

    local startedByName = 'Automated Schedule'
    if starterSource and starterSource > 0 then
        local pName = Bridge.GetPlayerName(starterSource)
        local pIdent = Bridge.GetIdentifier(starterSource)
        startedByName = ('%s (%s)'):format(pName or 'Admin', pIdent or 'N/A')
    end

    local rt = {
        id = convoyId, def = def, route = route, status = 'ACTIVE',
        airdropPoints = airdropPoints, airdropsTriggered = {},
        currentRouteIndex = 1, checkpointTimeRemaining = 0, pointInProgress = false,
        deliveryTimeRemaining = def.eventDuration or 1200,
        trucks = {}, startedAt = os.time(),
        startedByName = startedByName,
        participants = { identifiers = {}, gangCounts = {}, policeIdentifiers = {}, names = {} },
        gangVisibilityUnlocked = false,
        releaseHeld = true,
        startedBySource = starterSource,
    }

    -- Reserved here, BEFORE any of the yielding truck-spawn work below (each
    -- spawnTruck call, plus the Wait(500) between them, hands control back to
    -- the scheduler) — the active[convoyId] guard at the top of this function
    -- only protects against a second doStart landing AFTER this point once
    -- assigned late. A double-click (or a scheduled auto-start racing an
    -- admin's manual one) landing inside that multi-second spawn window used
    -- to read active[convoyId] as still nil, sail straight past the guard,
    -- and spawn a SECOND full set of trucks with its own monitor thread —
    -- then overwrite active[convoyId] with ITS OWN rt at the end, orphaning
    -- the first rt (and its trucks, and the CreateThread waiting to call
    -- releaseConvoy on it, whose own `active[convoyId] == rt` check would
    -- now fail forever). That first batch of trucks would sit frozen at
    -- spawn permanently — exactly "trucks not moving after the police
    -- buffer," confirmed in the field by two back-to-back doStart(2) log
    -- lines both reading active[id]=false.
    active[convoyId] = rt

    -- Count convoy (non-ESCORT) trucks first so spawnTruck can calculate spacing dynamically
    local totalConvoyTrucks = 0
    for _, truckDef in ipairs(def.trucks) do
        if truckDef.role ~= 'ESCORT' then totalConvoyTrucks = totalConvoyTrucks + 1 end
    end

    local convoyIndex = 0
    for _, truckDef in ipairs(def.trucks) do
        if truckDef.role ~= 'ESCORT' then
            convoyIndex = convoyIndex + 1
            local truck = spawnTruck(startPoint, truckDef, convoyIndex, totalConvoyTrucks, rt.id)
            if truck then rt.trucks[truckDef.id] = truck end
            -- The event was cancelled / force-ended while this truck was still spawning: Runtime.finish
            -- has already run, so this truck (and the rest of the loop) would be orphaned. Delete it and stop.
            if active[convoyId] ~= rt then
                if truck then
                    if truck.driverPed and DoesEntityExist(truck.driverPed) then DeleteEntity(truck.driverPed) end
                    if truck.entity and DoesEntityExist(truck.entity) then DeleteEntity(truck.entity) end
                    if truck.trailerEntity and DoesEntityExist(truck.trailerEntity) then DeleteEntity(truck.trailerEntity) end
                end
                return
            end
            -- Wait between trucks: gives each vehicle + driver ped time to fully settle,
            -- preventing seat-stealing, entity overlap, and NPC spawn failures on the next truck.
            Wait(500)
            if active[convoyId] ~= rt then return end
        end
    end

    ConvoyManager.setStatus(convoyId, 'ACTIVE')
    persist(rt)
    monitor(rt)

    -- Auto-joins whoever pre-registered (ConvoyManager.registerPolice, the
    -- Convoy Status panel's "upcoming events" list) and is still online
    for _, entry in ipairs(def.policeRoster or {}) do
        local src = findSourceByIdentifier(entry.identifier)
        if src then Runtime.joinPolice(src, convoyId) end
    end

    -- Auto-joins pre-registered gang members from def.roster
    for _, gangList in pairs(def.roster or {}) do
        for _, ident in ipairs(gangList) do
            local src = findSourceByIdentifier(ident)
            if src then Runtime.joinGang(src, convoyId) end
        end
    end

    local truckBreakdown = {}
    for _, t in ipairs(def.trucks or {}) do
        truckBreakdown[t.role] = (truckBreakdown[t.role] or 0) + 1
    end
    local fleetParts = {}
    for role, count in pairs(truckBreakdown) do
        fleetParts[#fleetParts + 1] = ('%dx %s'):format(count, TRUCK_ROLE_LABELS[role] or role)
    end

    local startFields = {
        { name = 'Operation', value = def.name, inline = true },
        { name = 'Start Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', rt.startedAt or os.time()), rt.startedAt or os.time()), inline = true },
        { name = 'Cargo', value = (def.cargo and def.cargo.description and def.cargo.description ~= '' and def.cargo.description) or (def.cargo and def.cargo.type) or 'High-Value Cargo', inline = true },
        { name = 'Started By', value = startedByName, inline = true },
        { name = 'Fleet Composition', value = #fleetParts > 0 and table.concat(fleetParts, ', ') or ('%d Trucks'):format(#def.trucks), inline = false },
        { name = 'Route Details', value = ('%d Waypoints (%d Checkpoints, %d Airdrops)'):format(
            #def.route,
            #(def.checkpoints or {}),
            #(def.airdrops or {})
        ), inline = false },
        { name = 'Difficulty', value = def.difficulty or 'MEDIUM', inline = true },
        { name = 'Max Forces', value = ('Gang: %s | Police: %s'):format(def.maxGangParticipants or 0, def.maxPoliceParticipants or 0), inline = true },
    }
    local rewardDesc = RewardService.describeRewards(def.reward)
    if rewardDesc and rewardDesc ~= '' and rewardDesc ~= 'None' then
        startFields[#startFields + 1] = { name = 'Potential Rewards', value = rewardDesc, inline = false }
    end

    DiscordLog.startEvent(convoyId, ('Convoy Event — %s'):format(def.name), 0x3b82f6, def.shortDescription, startFields)
    DiscordLog.appendEvent(convoyId, ('🚀 Convoy "%s" departed staging area under armed escort (Started by: %s)'):format(def.name, startedByName))

    -- Broadcast the staging zone blip (START point) so police see a green zone circle
    -- on the map as soon as trucks are spawned, before the convoy departs.
    -- Cleared in releaseConvoy() once trucks actually start moving.
    local stagingAudience = policeAndAdminSources(rt)
    if #stagingAudience == 0 then stagingAudience = { -1 } end -- broadcast to all if no escort yet
    for _, s in ipairs(stagingAudience) do
        TriggerClientEvent('nova_convoytruck:runtime:stagingZone', s, {
            x = startPoint.x, y = startPoint.y, z = startPoint.z,
            label = ('%s — Staging Area'):format(def.name),
            radius = 80.0,
        })
    end
    rt.stagingZoneSources = stagingAudience

    local prepDelay = startAnnounceDelayFor(def)
    if prepDelay > 0 then
        notify(policeAndAdminSources(rt), 'nova_convoytruck:runtime:startPrepCountdown', prepDelay)
        CreateThread(function()
            Wait(prepDelay * 1000)
            if active[convoyId] == rt then releaseConvoy(rt) end
        end)
    else
        releaseConvoy(rt)
    end

    return true, def
end

function Runtime.start(source, convoyId)
    -- while a test run is on, every message of this resource goes to the tester only: no other event may start meanwhile
    if TestRun and TestRun.admin and TestRun.convoyId ~= convoyId then return false, 'A test run is in progress. End it first.' end
    if not UserPermissions.can(source, 'convoys.manage') then
        print(('[NovaConvoy] Runtime.start(%s, %s): no convoys.manage permission — rejected.'):format(tostring(source), tostring(convoyId)))
        return false, 'Not authorized.'
    end
    local def = ConvoyManager.get(convoyId)
    -- TDM included here (unlike GANG_RACE, which any creator-access holder —
    -- including on-duty police — may start) since TDM is police-invisible
    -- everywhere else; a police-job tablet user must never be able to start
    -- one either.
    if def and (def.kind == 'GANG_AIRDROP' or def.kind == 'HOT_CARGO' or def.kind == 'TDM' or def.kind == 'GANG_TERRITORY' or def.kind == 'CRACKDOWN') and not UserPermissions.can(source, 'create.manage') then
        print(('[NovaConvoy] Runtime.start(%s, %s): no create.manage permission — rejected for kind %s.'):format(tostring(source), tostring(convoyId), tostring(def.kind)))
        return false, ('Only staff with Create Event → Manage can start %s events.'):format(def.kind == 'HOT_CARGO' and 'Hot Cargo' or (def.kind == 'TDM' and 'TDM Match' or (def.kind == 'GANG_TERRITORY' and 'Gang Territory Auction' or (def.kind == 'CRACKDOWN' and 'Operation Crackdown' or 'Gang Airdrop'))))
    end
    return doStart(convoyId, source)
end

-- System-triggered start (the scheduler) — there is no player "source" behind
-- an automatic, time-based launch, so this skips the creator-access check but
-- keeps every other validation (status/trucks/route) identical to a manual start.
function Runtime.startScheduled(convoyId)
    if TestRun and TestRun.admin then return false, 'A test run is in progress.' end
    return doStart(convoyId)
end

-- A rehearsal started by an admin (see test_run.lua): the same start, with every notification going to that admin only, no
-- payouts, no Discord post, no history or leaderboard entry. Territory auctions are left out (they change real land).
function Runtime.testRun(source, convoyId)
    if not UserPermissions.can(source, 'convoys.manage') then return false, 'Not authorized.' end
    local def = ConvoyManager.get(convoyId)
    if not def then return false, 'Event not found.' end
    if def.kind == 'GANG_TERRITORY' then return false, 'A territory auction changes real land and cannot be test-run.' end
    if def.kind == 'CRACKDOWN' then return false, 'Operation Crackdown is fought between real players and cannot be test-run.' end
    if TestRun.admin then return false, 'A test run is already in progress.' end
    if #Runtime.getActive() > 0 then return false, 'Another event is running. A test run needs the server free of live events.' end
    TestRun.begin(source, convoyId)
    local ok, err = Runtime.start(source, convoyId)
    if not ok then TestRun.clear() return false, err end
    TriggerClientEvent('nova_convoytruck:client:hudNotify', source, { type = 'inform', duration = 9000, title = 'TEST RUN', description = 'Only you get notifications. Nothing is paid, posted to Discord or saved to history.' })
    return true
end

-- Admin-triggered termination — reuses Runtime.finish's existing cleanup
-- (entity teardown, DB deletion, history insert, notifications), just forces
-- the CANCELLED outcome instead of letting it auto-detect one.
function Runtime.forceEnd(source, convoyId)
    if not UserPermissions.can(source, 'convoys.manage') then return false, 'Not authorized.' end
    local def = ConvoyManager.get(convoyId)
    if not def then return false, 'Event not found.' end
    -- the specialised kinds (anything but a plain Convoy) also need Create Event → Manage
    if def.kind ~= 'CONVOY' and not UserPermissions.can(source, 'create.manage') then return false, 'Not authorized.' end

    -- TDM matches live entirely in tdm_runtime.lua's own runtime table — its
    -- own cleanup (invincibility, HUD, vendor, history) needs to run instead
    -- of this file's convoy-shaped cancellation path below.
    if def.kind == 'TDM' then
        if Tdm and Tdm.isActive(convoyId) then
            return Tdm.forceEnd(source, convoyId)
        end
        ConvoyManager.setStatus(convoyId, 'CANCELLED')
        return true
    end

    if def.kind == 'CONTAINER_WARS' then
        if ContainerWars and ContainerWars.isActive(convoyId) then
            return ContainerWars.forceEnd(source, convoyId)
        end
        ConvoyManager.setStatus(convoyId, 'CANCELLED')
        return true
    end

    if def.kind == 'GANG_TERRITORY' then
        if TerritoryAuction and TerritoryAuction.isActive(convoyId) then
            return TerritoryAuction.forceEnd(source, convoyId)
        end
        ConvoyManager.setStatus(convoyId, 'CANCELLED')
        return true
    end

    if def.kind == 'CRACKDOWN' then
        if Crackdown and Crackdown.isActive(convoyId) then
            return Crackdown.forceEnd(source, convoyId)
        end
        ConvoyManager.setStatus(convoyId, 'CANCELLED')
        return true
    end

    if active[convoyId] then
        Runtime.finish(convoyId, 'CANCELLED', Bridge.GetPlayerName(source))
    else
        -- If not in active memory table (e.g. server restart, unrecovered state, or orphaned active status),
        -- cleanly force-cancel the definition and clear any runtime table entry so it's not stuck forever.
        ConvoyManager.setStatus(convoyId, 'CANCELLED')
        DB.deleteRuntime(convoyId)

        local gangIdentifiers = {}
        for gangName, ids in pairs(def.roster or {}) do
            for _, id in ipairs(ids or {}) do gangIdentifiers[#gangIdentifiers + 1] = id end
        end

        DB.insertConvoyHistory({
            convoyDefinitionId = convoyId,
            name = def.name,
            createdBy = def.createdBy,
            startedAt = os.time(),
            endedAt = os.time(),
            duration = 0,
            truckCount = #(def.trucks or {}),
            policeParticipants = #(def.policeRoster or {}),
            gangParticipants = #gangIdentifiers,
            winningGang = nil,
            outcome = 'CANCELLED',
            rewardSummary = 'N/A (Force-ended from inactive state)',
            destroyedTrucks = 0,
            checkpointsCompleted = 0,
            kind = def.kind or 'CONVOY',
        })

        TriggerClientEvent('nova_convoytruck:runtime:cleanupTruck', -1)
        TriggerClientEvent('nova_convoytruck:runtime:hideAll', -1)

        local inactiveKindLabel = ({ GANG_AIRDROP = 'Gang Airdrop', HOT_CARGO = 'Hot Cargo', GANG_RACE = 'Gang Rally', TDM = 'TDM Match', CONTAINER_WARS = 'Container Wars', CRACKDOWN = 'Operation Crackdown' })[def.kind] or 'Convoy'
        DiscordLog.finishEvent(convoyId, ('%s Cancelled — %s'):format(inactiveKindLabel, def.name), 0x6b7280, {
            { name = 'Outcome', value = 'CANCELLED', inline = true },
            { name = 'Force-Ended By', value = Bridge.GetPlayerName(source) or 'Admin', inline = true },
            { name = 'Status', value = 'Force-ended while inactive/recovered', inline = false },
        }, nil, nil, def.kind)
    end

    -- Clear participant rosters so if reused, players must join again
    def.roster = {}
    def.policeRoster = {}
    DB.updateConvoyDefinition(convoyId, def)
    ConvoyManager.broadcastStartPeds()

    -- Reset hostile groups and driveby state across online players
    for _, src in ipairs(Bridge.GetPlayers()) do
        NpcManager.setPlayerHostile(src, false)
        TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', src, false)
    end

    return true
end

-- GANG_AIRDROP kind: no trucks/route/capture concept, so this branches off
-- BEFORE any of the truck/capture-specific logic below runs (delivered/
-- destroyed/captured counts, capturingGang, RewardService.GiveConvoyReward
-- for a police escort — none of it applies; each zone's own reward was
-- already paid directly to whoever looted it, see claimAirdrop).
-- rt.anyZoneLooted (set in claimAirdrop) is the only outcome signal —
-- COMPLETED if at least one zone was actually looted, FAILED otherwise.
local function finishGangAirdropEvent(rt, convoyId, forcedOutcome, forcedByName)
    purgeRuntimeEntitiesNow(rt)

    local outcome = forcedOutcome or (rt.anyZoneLooted and 'COMPLETED' or 'FAILED')
    ConvoyManager.setStatus(convoyId, outcome)
    DB.deleteRuntime(convoyId)
    Scheduler.rearm(convoyId, rt.def)

    -- Per-kind gang leaderboard tracking (Gang Airdrop), FAILED side only —
    -- a COMPLETED event already credited every gang that actually looted
    -- successfully back in claimAirdrop, as it happened (see there for why).
    -- FAILED here means nobody landed a single successful loot the whole
    -- event, so every gang that engaged at all gets a failed credit instead.
    if outcome == 'FAILED' then
        local seenGangs = {}
        for _, gangName in pairs(rt.participants.identifiers or {}) do
            if gangName and gangName ~= 'independent' and not seenGangs[gangName] then
                seenGangs[gangName] = true
                GangService.RecordOutcome(gangName, 'failed', 'GANG_AIRDROP')
            end
        end
    end

    for _, src in ipairs(gangParticipantSources(rt)) do
        NpcManager.setPlayerHostile(src, false)
        TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', src, false)
    end
    TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', -1, false)

    -- Tell all clients to clear the HUD timer, squad panels, blips and airdrop
    -- world objects. This was missing from the Gang Airdrop finish path, which
    -- caused the event timer UI to remain on screen after force-end or natural end.
    TriggerClientEvent('nova_convoytruck:runtime:cleanupTruck', -1)
    TriggerClientEvent('nova_convoytruck:runtime:hideAll', -1)

    local airdropOutcomes = {
        COMPLETED = { key = 'gangAirdropCompleted', title = 'Airdrop Event Ended', body = "At least one gang made off with a drop's contents.", kind = 'success' },
        FAILED = { key = 'gangAirdropFailed', title = 'Airdrop Event Ended', body = 'Nobody claimed any of the drops in time.', kind = 'warn' },
        CANCELLED = { key = 'gangAirdropCancelled', title = 'Airdrop Event Cancelled', body = 'The event was terminated by an administrator.', kind = 'danger' },
    }
    local aob = airdropOutcomes[outcome] or airdropOutcomes.FAILED
    local b = resolveBanner(aob.key, aob.title, aob.body, 8000, aob.kind)
    if b and (not rt.def.settings or rt.def.settings.announcements ~= false) then
        notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind)
    end

    -- Congratulations: one banner for each gang that looted drops (a crate it opened with something in it), naming the gang and the
    -- drops it took — no reward details. Most drops first. They follow the "event ended" banner one after another so none is missed,
    -- and the stand-down notice below waits until they are all through.
    local congratsMs = 0
    if not rt.def.settings or rt.def.settings.announcements ~= false then
        local winners, byGang = {}, {}
        for _, c in ipairs(rt.airdropCaptures or {}) do
            if c.hit and c.gang and not c.isPolice then
                local g = byGang[c.gang]
                if not g then
                    g = { label = c.gangLabel or c.gang, drops = {} }
                    byGang[c.gang] = g
                    winners[#winners + 1] = g
                end
                g.drops[#g.drops + 1] = c.dropName or 'Airdrop'
            end
        end
        table.sort(winners, function(a, b) return #a.drops > #b.drops end)
        local congratsTo = airdropCaptureAudience(rt)
        local firstMs, gapMs = 3000, 9000
        for i, g in ipairs(winners) do
            local shown = {}
            for k = 1, math.min(#g.drops, 4) do shown[k] = g.drops[k] end
            local list = table.concat(shown, ', ')
            if #g.drops > #shown then list = list .. (' and %d more'):format(#g.drops - #shown) end
            local cb = resolveBannerSplit('airdropCongrats', '🏆 Congratulations, %s!', 'Drops secured: %d — %s', 8000, 'airdrop', { g.label }, { #g.drops, list })
            if cb then
                local at = firstMs + (i - 1) * gapMs
                congratsMs = at + gapMs
                CreateThread(function()
                    Wait(at)
                    notify(congratsTo, 'nova_convoytruck:runtime:announce', cb.title, cb.body, cb.duration, cb.kind)
                end)
            end
        end
    end

    local standDown = (Config.AnnouncementBanners and (Config.AnnouncementBanners.airdropStandDown or Config.AnnouncementBanners.standDown)) or Config.ConvoyEndStandDown
    if standDown and standDown.enabled ~= false then
        CreateThread(function()
            Wait(math.max((standDown.delaySeconds or 6) * 1000, congratsMs))
            local sdb = resolveBanner(
                'airdropStandDown',
                'Airdrop Operation Concluded',
                'All participants are requested to clear the drop zones immediately. Airdrop operation terminated.',
                standDown.duration or standDown.durationMs or 9000,
                standDown.kind or 'info'
            )
            if sdb then
                notify(airdropCaptureAudience(rt), 'nova_convoytruck:runtime:announce', sdb.title, sdb.body, sdb.duration, sdb.kind)
            end
        end)
    end

    local gangIdentifiers = {}
    for identifier in pairs(rt.participants.identifiers) do gangIdentifiers[#gangIdentifiers + 1] = identifier end

    -- Determine top winning gang based on actual airdrop captures
    local winningGang = nil
    local maxCaptures = 0
    for gangName, count in pairs(rt.gangAirdropCounts or {}) do
        if count > maxCaptures then
            maxCaptures = count
            winningGang = gangName
        end
    end
    local winningIdentity = winningGang and gangIdentity(rt, winningGang) or nil

    local winnerText = 'None'
    if outcome == 'COMPLETED' then
        winnerText = winningIdentity and ('🏴 %s (%d drops)'):format(winningIdentity.label, maxCaptures) or 'Participating Gangs'
    elseif outcome == 'CANCELLED' then
        winnerText = 'Cancelled by Administrator'
    elseif outcome == 'FAILED' then
        winnerText = 'None (No Drops Claimed)'
    end

    local reportData = buildConvoyReportData(rt, outcome, forcedByName)

    DB.insertConvoyHistory({
        convoyDefinitionId = convoyId,
        name = rt.def.name,
        createdBy = rt.def.createdBy,
        startedAt = rt.startedAt,
        endedAt = os.time(),
        duration = os.time() - rt.startedAt,
        truckCount = 0,
        policeParticipants = 0,
        gangParticipants = #gangIdentifiers,
        winningGang = winningGang,
        outcome = outcome,
        rewardSummary = 'Per-zone airdrop rewards',
        destroyedTrucks = 0,
        checkpointsCompleted = 0,
        kind = 'GANG_AIRDROP',
        reportData = reportData,
    })

    local durSec = os.time() - rt.startedAt
    local durText = ('%dm %02ds'):format(math.floor(durSec / 60), durSec % 60)

    local endFields = {
        { name = 'Operation', value = rt.def.name, inline = true },
        { name = 'Outcome', value = outcome, inline = true },
        { name = 'Winner', value = winnerText, inline = true },
        { name = 'Start Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', rt.startedAt), rt.startedAt), inline = true },
        { name = 'End Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', os.time()), os.time()), inline = true },
        { name = 'Duration', value = durText, inline = true },
        { name = 'Airdrop Zones', value = ('%d claimed / %d total'):format(#(rt.airdropCaptures or {}), #(rt.def.airdropZones or {})), inline = true },
        { name = 'Gang Participants', value = tostring(#gangIdentifiers), inline = true },
    }

    -- who claimed which drop (and how), then what was really paid
    if #(rt.airdropCaptures or {}) > 0 then
        local lines = {}
        for _, c in ipairs(rt.airdropCaptures) do
            if #lines >= 10 then lines[#lines + 1] = ('... and %d more (see the report)'):format(#rt.airdropCaptures - 10) break end
            local how = c.usedHack and 'hacked' or (c.usedLockpick and 'lockpicked' or 'cracked open')
            lines[#lines + 1] = ('`%s` **%s** — %s (%s), %s → %s'):format(c.timeStr or '--:--:--', c.dropName or 'Drop', c.playerName or 'Unknown', c.gangLabel or (c.isPolice and 'Police' or 'Independent'), how, c.rewardSummary or (c.hit and 'Loot secured' or 'Empty crate'))
        end
        endFields[#endFields + 1] = { name = ('📦 Drops Claimed (%d)'):format(#rt.airdropCaptures), value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
    end
    if next(rt.gangAirdropCounts or {}) then
        local lines = {}
        for gName, count in pairs(rt.gangAirdropCounts) do
            local identity = gangIdentity(rt, gName)
            lines[#lines + 1] = ('**%s** — %d drop%s'):format(identity and identity.label or gName, count, count == 1 and '' or 's')
        end
        table.sort(lines)
        endFields[#endFields + 1] = { name = '🏴 Drops by gang', value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
    end
    for _, f in ipairs(ReportBuilder.payoutFields(convoyId)) do endFields[#endFields + 1] = f end

    if outcome == 'CANCELLED' and forcedByName then
        endFields[#endFields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true }
    end

    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(reportData)
    end

    if pdfString then
        endFields[#endFields + 1] = {
            name = '📄 After-Action Report (PDF)',
            value = 'Full tactical audit report generated and attached to this message.',
            inline = false,
        }
    end

    DiscordLog.finishEvent(convoyId, ('Gang Airdrop Event Ended — %s'):format(rt.def.name),
        outcome == 'COMPLETED' and 0x22c55e or 0x6b7280, endFields, nil, pdfString, 'GANG_AIRDROP')
    RewardService.ClearPayouts(convoyId)
end

local function finishHotCargoEvent(rt, convoyId, forcedOutcome, forcedByName)
    -- Clean up every truck / trailer / driver / loot crate / guard this run created (and anything
    -- still tagged with this convoy id). A delivered run's reward crate is the one exception: it is
    -- preserved for the 60-minute sentry window — unless an admin force-ended (CANCELLED) the event.
    purgeRuntimeEntitiesNow(rt, forcedOutcome ~= 'CANCELLED')

    TriggerClientEvent('nova_convoytruck:runtime:cleanupTruck', -1)
    TriggerClientEvent('nova_convoytruck:runtime:hideAll', -1)
    TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', -1, false)

    for _, src in ipairs(gangParticipantSources(rt)) do
        NpcManager.setPlayerHostile(src, false)
    end

    local outcome = forcedOutcome or (rt.hotCargoDelivered and 'COMPLETED' or 'FAILED')
    ConvoyManager.setStatus(convoyId, outcome)
    DB.deleteRuntime(convoyId)
    Scheduler.rearm(convoyId, rt.def)

    -- Per-kind gang leaderboard tracking (Hot Cargo). Open-participation
    -- event — no roster/join step — so "who engaged" is read back from
    -- rt.participants.identifiers (populated as gangs actually drive/hijack
    -- a contraband vehicle, see the driver-tracking above) rather than an
    -- explicit join list like a regular convoy has.
    --
    -- Every gang that actually delivered a truck gets credited for each one
    -- of THEIR OWN deliveries (rt.gangDeliveryCounts, set in
    -- handleHotCargoDelivered) — not just whichever gang happened to be
    -- remembered as rt.winningGang (the LAST delivery only). If two
    -- different gangs each deliver a different truck in the same run, both
    -- now get their own credit instead of one of them being silently
    -- dropped.
    if outcome == 'COMPLETED' then
        for gangName, count in pairs(rt.gangDeliveryCounts or {}) do
            for _ = 1, count do
                GangService.RecordOutcome(gangName, 'captured', 'HOT_CARGO')
            end
        end
    elseif outcome == 'FAILED' then
        local seenGangs = {}
        for _, gangName in pairs(rt.participants.identifiers or {}) do
            if gangName and gangName ~= 'independent' and not seenGangs[gangName] then
                seenGangs[gangName] = true
                GangService.RecordOutcome(gangName, 'failed', 'HOT_CARGO')
            end
        end
    end

    local hotCargoOutcomes = {
        COMPLETED = { key = 'hotCargoCompleted', title = 'Hot Cargo Run Concluded', body = 'Contraband shipment was successfully delivered to the dropoff zone! Unlocked reward crate is secured.', kind = 'success' },
        FAILED = { key = 'hotCargoFailed', title = 'Hot Cargo Run Failed', body = 'Time expired or all contraband vehicles were destroyed before delivery.', kind = 'warn' },
        CANCELLED = { key = 'hotCargoCancelled', title = 'Hot Cargo Run Cancelled', body = 'The operation was terminated by an administrator.', kind = 'danger' },
    }
    local cob = hotCargoOutcomes[outcome] or hotCargoOutcomes.FAILED
    local b = resolveBanner(cob.key, cob.title, cob.body, 8000, cob.kind)
    if b and (not rt.def.settings or rt.def.settings.announcements ~= false) then
        announceServerWide(rt, b.title, b.body, b.duration, b.kind)
    end

    -- Hot Cargo's own stand-down only — never the generic/Convoy "Convoy Event Concluded".
    local standDown = (Config.AnnouncementBanners and Config.AnnouncementBanners.hotCargoStandDown) or { delaySeconds = 6 }
    if standDown and standDown.enabled ~= false then
        CreateThread(function()
            Wait((standDown.delaySeconds or 6) * 1000)
            local sdb = resolveBanner(
                'hotCargoStandDown',
                'Hot Cargo Run Concluded',
                'All units and operatives stand down. Clear the area immediately — the operation is complete.',
                standDown.duration or standDown.durationMs or 9000,
                standDown.kind or 'info'
            )
            if sdb then
                announceServerWide(rt, sdb.title, sdb.body, sdb.duration, sdb.kind)
            end
        end)
    end

    local gangIdentifiers = {}
    for identifier in pairs(rt.participants.identifiers or {}) do gangIdentifiers[#gangIdentifiers + 1] = identifier end

    local winnerText = 'None'
    if outcome == 'COMPLETED' then
        winnerText = rt.winningGangLabel and ('🏴 %s'):format(rt.winningGangLabel) or (rt.winningGang and ('🏴 %s'):format(rt.winningGang) or 'Delivering Gang')
    elseif outcome == 'CANCELLED' then
        winnerText = 'Cancelled by Administrator'
    elseif outcome == 'FAILED' then
        winnerText = 'None (Destroyed / Intercepted / Expired)'
    end

    local deliveredCount = rt.hotCargoDeliveredCount or 0
    local destroyedCount = 0
    local disabledCount = 0
    local totalSpawned = 0
    for _, t in pairs(rt.trucks or {}) do
        totalSpawned = totalSpawned + 1
        if t.destroyed then destroyedCount = destroyedCount + 1 end
        if t.brokenDown and not t.delivered then disabledCount = disabledCount + 1 end
    end

    local reportData = buildConvoyReportData(rt, outcome, forcedByName)

    DB.insertConvoyHistory({
        convoyDefinitionId = convoyId,
        name = rt.def.name,
        createdBy = rt.def.createdBy,
        startedAt = rt.startedAt,
        endedAt = os.time(),
        duration = os.time() - rt.startedAt,
        truckCount = totalSpawned,
        policeParticipants = 0,
        gangParticipants = #gangIdentifiers,
        winningGang = rt.winningGang,
        outcome = outcome,
        rewardSummary = 'Contraband vehicle payload & unlocked crate',
        destroyedTrucks = destroyedCount,
        checkpointsCompleted = deliveredCount,
        kind = 'HOT_CARGO',
        reportData = reportData,
    })

    local durSec = os.time() - rt.startedAt
    local durText = ('%dm %02ds'):format(math.floor(durSec / 60), durSec % 60)

    local endFields = {
        { name = 'Operation', value = rt.def.name, inline = true },
        { name = 'Outcome', value = outcome, inline = true },
        { name = 'Winner', value = winnerText, inline = true },
        { name = 'Start Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', rt.startedAt), rt.startedAt), inline = true },
        { name = 'End Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', os.time()), os.time()), inline = true },
        { name = 'Duration', value = durText, inline = true },
        { name = 'Vehicles Status', value = ('%d delivered | %d disabled | %d destroyed (Total: %d)'):format(deliveredCount, disabledCount, destroyedCount, totalSpawned), inline = true },
        { name = 'Gang Participants', value = tostring(#gangIdentifiers), inline = true },
    }
    if #(rt.hijackLog or {}) > 0 then
        local lines = {}
        for _, h in ipairs(rt.hijackLog) do
            lines[#lines + 1] = ('`%s` Cargo Truck #%d — %s (%s)%s'):format(h.timeStr or '--:--:--', h.truckNum or 1, h.gangLabel or h.gang or 'Independent', h.name or 'Unknown', h.tookFrom and (' — taken from ' .. tostring(h.tookFrom)) or '')
        end
        endFields[#endFields + 1] = { name = ('🚗 Hijacks (%d)'):format(#lines), value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
    end
    local disabledLines = {}
    for _, t in pairs(rt.trucks or {}) do
        if t.brokenDownAt then
            disabledLines[#disabledLines + 1] = ('`%s` Cargo Truck #%s broke down%s'):format(os.date('!%H:%M:%S', t.brokenDownAt), tostring(tonumber(tostring(t.id):match('(%d+)$')) or 1), t.lootedBy and (' — looted by ' .. tostring(t.lootedBy.gangLabel or t.lootedBy.name or 'unknown')) or ' — cargo left lootable')
        end
    end
    if #disabledLines > 0 then
        endFields[#endFields + 1] = { name = ('🛠️ Trucks Disabled (%d)'):format(#disabledLines), value = table.concat(disabledLines, '\n'):sub(1, 1000), inline = false }
    end
    if #(rt.deliveryLog or {}) > 0 then
        local lines = {}
        for _, d in ipairs(rt.deliveryLog) do
            lines[#lines + 1] = ('`%s` Truck #%d — %s (%s) at **%d%%** condition → crate: %s'):format(d.timeStr or '--:--:--', d.truckNum or 1, d.gangLabel or d.gang or 'Gang', d.driver or 'Operative', d.conditionPct or 0, d.rewards or 'None')
        end
        endFields[#endFields + 1] = { name = ('📦 Deliveries (%d)'):format(#lines), value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
    end
    for _, f in ipairs(ReportBuilder.payoutFields(convoyId)) do endFields[#endFields + 1] = f end

    if outcome == 'CANCELLED' and forcedByName then
        endFields[#endFields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true }
    end

    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(reportData)
    end

    if pdfString then
        endFields[#endFields + 1] = {
            name = '📄 After-Action Report (PDF)',
            value = 'Full tactical audit report generated and attached to this message.',
            inline = false,
        }
    end

    local embedColor = outcome == 'COMPLETED' and 0x22c55e or (outcome == 'CANCELLED' and 0x6b7280 or 0xef4444)
    DiscordLog.finishEvent(convoyId, ('Hot Cargo Run Ended — %s'):format(rt.def.name),
        embedColor, endFields, nil, pdfString, 'HOT_CARGO')
    RewardService.ClearPayouts(convoyId)
end

-- convoyId -> outcome defaults to COMPLETED if any cargo truck delivered.
-- forcedByName: only set for an admin Force End (see Runtime.forceEnd) — the
-- name of whoever cut it short, surfaced in the final Discord log so a
-- CANCELLED outcome isn't anonymous.
function Runtime.finish(convoyId, forcedOutcome, forcedByName)
    local rt = active[convoyId]
    if not rt then return end
    active[convoyId] = nil

    if rt.def.kind == 'GANG_AIRDROP' then
        finishGangAirdropEvent(rt, convoyId, forcedOutcome, forcedByName)
        return
    end
    if rt.def.kind == 'HOT_CARGO' then
        finishHotCargoEvent(rt, convoyId, forcedOutcome, forcedByName)
        return
    end
    if rt.def.kind == 'GANG_RACE' then
        finishGangRaceEvent(rt, convoyId, forcedOutcome, forcedByName)
        return
    end

    -- Delete everything first (and keep sweeping for late spawns) so nothing later in this
    -- function — DB writes, reward payouts, Discord — can stop the world being cleaned up.
    purgeRuntimeEntitiesNow(rt)

    local delivered, destroyed, captured = 0, 0, 0
    for _, t in pairs(rt.trucks or {}) do
        if t.delivered then delivered = delivered + 1 end
        if t.destroyed then destroyed = destroyed + 1 end
        if t.captured then captured = captured + 1 end

        -- 1. Always delete the driver ped if it exists
        if t.driverPed and DoesEntityExist(t.driverPed) then
            DeleteEntity(t.driverPed)
        end

        -- 2. Delete the vehicle entity itself (whether delivered, overturned, destroyed, captured, or cancelled)
        local liveTruck = nil
        if t.entity and DoesEntityExist(t.entity) then
            liveTruck = t.entity
        elseif t.netId and t.netId ~= 0 then
            pcall(function()
                local ent = NetworkGetEntityFromNetworkId(t.netId)
                if ent and ent ~= 0 and DoesEntityExist(ent) then
                    liveTruck = ent
                end
            end)
        end
        if liveTruck and DoesEntityExist(liveTruck) then
            DeleteEntity(liveTruck)
        end

        -- 3. Delete any destroyed loot crate prop
        if t.propEntity and DoesEntityExist(t.propEntity) then
            DeleteEntity(t.propEntity)
        end

        -- 4. Tell all clients to force delete locally if streamed
        if t.netId then
            TriggerClientEvent('nova_convoytruck:runtime:cleanupTruck', -1, t.netId)
        end

        if t.stashId then Inventory.ClearStash(t.stashId) end
    end

    -- Clean up active checkpoints, barricades, ambushes, airdrops
    if rt.activeCheckpointNpcs then
        NpcManager.cleanup(rt.activeCheckpointNpcs)
        rt.activeCheckpointNpcs = nil
    end
    if rt.activeRouteNpcs then
        NpcManager.cleanup(rt.activeRouteNpcs)
        rt.activeRouteNpcs = nil
    end
    if rt.activeAmbushNpcs then
        NpcManager.cleanup(rt.activeAmbushNpcs)
        rt.activeAmbushNpcs = nil
    end
    for _, obj in ipairs(rt.activeCheckpointBarricades or {}) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    rt.activeCheckpointBarricades = nil
    for _, veh in ipairs(rt.activeCheckpointVehicles or {}) do
        if DoesEntityExist(veh) then DeleteEntity(veh) end
    end
    rt.activeCheckpointVehicles = nil

    -- Sweep every checkpoint's dressing, not just whichever one the convoy
    -- was physically standing at — the lookahead pre-spawn (monitor(), see
    -- ensureCheckpointDressing) can have up to CHECKPOINT_PRESPAWN_LOOKAHEAD
    -- upcoming checkpoints already spawned in and waiting when the event
    -- ends/force-ends, and those were never "activated" (never went through
    -- runCheckpoint's own cleanup above) so nothing else deletes them.
    for _, dressing in pairs(rt.checkpointDressing or {}) do
        pcall(NpcManager.cleanup, dressing.npcs)
        for _, obj in ipairs(dressing.barricades or {}) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
        for _, veh in ipairs(dressing.vehicles or {}) do if DoesEntityExist(veh) then DeleteEntity(veh) end end
        for _, id in ipairs(dressing.blipIds or {}) do removeNpcBlip(rt, id) end
    end
    rt.checkpointDressing = nil

    for _, entry in pairs(rt.airdrops or {}) do cleanupAirdrop(rt, entry) end

    -- Tell all players to hide all HUD elements and remove all map blips
    TriggerClientEvent('nova_convoytruck:runtime:hideAll', -1)

    -- Reclaim escort vehicles
    for identifier, entry in pairs(rt.escortVehicles or {}) do
        if entry.vehicle and DoesEntityExist(entry.vehicle) then DeleteEntity(entry.vehicle) end
        local src = findSourceByIdentifier(identifier)
        if src then TriggerClientEvent('nova_convoytruck:client:notify', src, 'Your escort vehicle was reclaimed — the convoy has ended.', 'info') end
    end
    rt.escortVehicles = nil

    local outcome = forcedOutcome
    if not outcome then
        if delivered > 0 then outcome = 'COMPLETED'
        elseif captured > 0 then outcome = 'CAPTURED'
        else outcome = 'FAILED' end
    end

    ConvoyManager.setStatus(convoyId, outcome)
    DB.deleteRuntime(convoyId)
    -- Same recurrence rearm as finishGangAirdropEvent — not restricted to
    -- that kind at the data-model level, so an ordinary convoy could use it
    -- too even though the creator UI currently only exposes the field for a
    -- GANG_AIRDROP event.
    Scheduler.rearm(convoyId, rt.def)

    for _, src in ipairs(gangParticipantSources(rt)) do
        NpcManager.setPlayerHostile(src, false)
        TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', src, false)
    end
    for _, src in ipairs(policeParticipantSources(rt)) do
        TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', src, false)
    end
    TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', -1, false)

    -- Determine winning gang based on actual truck/cargo captures
    local capturingGang = nil
    local maxCaptures = 0
    for gangName, count in pairs(rt.gangCaptureCounts or {}) do
        if count > maxCaptures then
            maxCaptures = count
            capturingGang = gangName
        end
    end
    if not capturingGang and outcome == 'CAPTURED' then
        for _, name in pairs(rt.participants.identifiers) do capturingGang = name break end
    end
    local capturingIdentity = capturingGang and gangIdentity(rt, capturingGang) or nil
    if capturingIdentity then
        local capturedByNames = {}
        for identifier, gangName in pairs(rt.participants.identifiers) do
            if gangName == capturingGang then
                capturedByNames[#capturedByNames + 1] = rt.participants.names[identifier] or identifier
            end
        end
        DB.insertConvoyEvent(rt.id, 'CONVOY_CAPTURED', {
            gangName = capturingGang, gangLabel = capturingIdentity.label,
            detail = 'Captured the whole convoy',
        })
        DiscordLog.appendEvent(rt.id, ('🏴 Convoy captured by %s — %s — reward: %s'):format(
            capturingIdentity.label,
            #capturedByNames > 0 and table.concat(capturedByNames, ', ') or 'Unknown',
            RewardService.describeRewards(rt.def.reward)))
    end

    local outcomeBanners = {
        COMPLETED = { key = 'convoyDelivered', title = 'Convoy Delivered', body = 'The convoy was successfully delivered.', kind = 'success' },
        CAPTURED = {
            key = 'convoyCaptured',
            title = 'Convoy Captured',
            body = '%s successfully captured the convoy.',
            kind = 'danger',
            param = capturingIdentity and capturingIdentity.label or nil,
        },
        FAILED = { key = 'convoyFailed', title = 'Convoy Failed', body = 'The convoy did not reach its destination in time.', kind = 'danger' },
        CANCELLED = { key = 'convoyCancelled', title = 'Convoy Cancelled', body = 'The convoy was terminated by an administrator.', kind = 'danger' },
    }
    local ob = outcomeBanners[outcome] or outcomeBanners.FAILED
    local b = nil
    if outcome == 'CAPTURED' and not capturingIdentity then
        local cfg = Config.AnnouncementBanners and Config.AnnouncementBanners.convoyCaptured
        local fallbackBody = (cfg and cfg.fallbackBody) or 'The convoy has been intercepted.'
        b = resolveBanner(ob.key, ob.title, fallbackBody, 8000, ob.kind)
    elseif ob.param then
        b = resolveBanner(ob.key, ob.title, ob.body, 8000, ob.kind, ob.param)
    else
        b = resolveBanner(ob.key, ob.title, ob.body, 8000, ob.kind)
    end

    if b then
        announceServerWide(rt, b.title, b.body, b.duration, b.kind, capturingIdentity)
    end
    notify(policeAndAdminSources(rt), 'nova_convoytruck:runtime:hideAll')

    -- ── Result summary + gang congratulations ───────────────────────────────────────────────────────
    -- With several cargo trucks and some lost along the way, the outcome banner alone ("Convoy Delivered") hides what
    -- happened. Two more banners follow it, one after the other, and only then does "Convoy Event Concluded" go out:
    --   1. how many of the trucks the police actually got through,
    --   2. a congratulation for the gang(s) that took the rest and the rewards in them.
    local BANNER_GAP_SECONDS = 9
    local followUps = 0
    if outcome ~= 'CANCELLED' then
        local explicitCargo = false
        for _, t in pairs(rt.trucks or {}) do
            if t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO' then explicitCargo = true break end
        end
        local totalTrucks, deliveredTrucks = 0, 0
        for _, t in pairs(rt.trucks or {}) do
            local isCargo = explicitCargo and (t.role == 'PRIMARY_CARGO' or t.role == 'SECONDARY_CARGO')
                or (not explicitCargo and t.role ~= 'ESCORT' and t.role ~= 'DECOY')
            if isCargo then
                totalTrucks = totalTrucks + 1
                if t.delivered then deliveredTrucks = deliveredTrucks + 1 end
            end
        end
        local lostTrucks = totalTrucks - deliveredTrucks
        if totalTrucks > 0 and lostTrucks == 0 then
            -- Every cargo truck made it. The last "Truck Delivered n/m" banner is replaced the same instant by the
            -- outcome banner above, so the count was never seen: say it here, after the outcome banner.
            local ab = resolveBanner('convoyResultAll', 'Convoy Result: %d of %d Trucks Delivered',
                'Every cargo truck reached the destination.', 8000, 'success', deliveredTrucks, totalTrucks)
            followUps = followUps + 1
            local delayAll = followUps * BANNER_GAP_SECONDS
            if ab then
                CreateThread(function()
                    Wait(delayAll * 1000)
                    announceServerWide(rt, ab.title, ab.body, ab.duration, ab.kind)
                end)
            end
        end
        if totalTrucks > 1 and lostTrucks > 0 then
            local plural = function(n, word) return n == 1 and word or (word .. 's') end

            -- 1. the result
            local sTitle, sBody
            if deliveredTrucks > 0 then
                sTitle = 'Convoy Result: %d of %d Trucks Delivered'
                sBody = 'Police could only deliver %d of the %d trucks. The other %d were lost to the gangs.'
            else
                sTitle = 'Convoy Result: No Trucks Delivered'
                sBody = 'Police could not get any of the %d trucks to the destination. All %d were lost to the gangs.'
            end
            local sb
            if deliveredTrucks > 0 then
                sb = resolveBanner('convoyResultSummary', sTitle, sBody, 8000, 'warn', deliveredTrucks, totalTrucks, lostTrucks)
            else
                sb = resolveBanner('convoyResultSummary', sTitle, sBody, 8000, 'danger', totalTrucks, totalTrucks)
            end
            followUps = followUps + 1
            local delay1 = followUps * BANNER_GAP_SECONDS
            if sb then
                CreateThread(function()
                    Wait(delay1 * 1000)
                    announceServerWide(rt, sb.title, sb.body, sb.duration, sb.kind)
                end)
            end

            -- 2. the gangs that took trucks (and so the rewards in them)
            local winners = {}
            for gangName, count in pairs(rt.gangCaptureCounts or {}) do
                if count and count > 0 and gangName and gangName ~= 'independent' and gangName ~= 'street_racers' then
                    local ident = gangIdentity(rt, gangName)
                    winners[#winners + 1] = { name = gangName, label = (ident and ident.label) or gangName, identity = ident, taken = math.min(count, lostTrucks) }
                end
            end
            table.sort(winners, function(a, b) if a.taken ~= b.taken then return a.taken > b.taken end return tostring(a.label) < tostring(b.label) end)
            if #winners > 0 then
                local cb
                if #winners == 1 then
                    local w = winners[1]
                    cb = resolveBannerSplit('convoyGangCongrats', 'Congratulations, %s!',
                        'You took %d of the %d convoy trucks and the rewards that came with them.', 9000, 'success', { w.label }, { w.taken, totalTrucks })
                    followUps = followUps + 1
                    local delay2, identity = followUps * BANNER_GAP_SECONDS, w.identity
                    if cb then
                        CreateThread(function()
                            Wait(delay2 * 1000)
                            announceServerWide(rt, cb.title, cb.body, cb.duration, cb.kind, identity)
                        end)
                    end
                else
                    local parts = {}
                    for _, w in ipairs(winners) do
                        parts[#parts + 1] = ('%s (%d %s)'):format(w.label, w.taken, plural(w.taken, 'truck'))
                    end
                    cb = resolveBanner('convoyGangCongratsMulti', 'Congratulations to the gangs that struck!',
                        '%s took the rest of the convoy and the rewards in it.', 9000, 'success', table.concat(parts, ', '))
                    followUps = followUps + 1
                    local delay2 = followUps * BANNER_GAP_SECONDS
                    if cb then
                        CreateThread(function()
                            Wait(delay2 * 1000)
                            announceServerWide(rt, cb.title, cb.body, cb.duration, cb.kind)
                        end)
                    end
                end
            end
        end
    end

    local standDown = (Config.AnnouncementBanners and (Config.AnnouncementBanners.convoyStandDown or Config.AnnouncementBanners.standDown)) or Config.ConvoyEndStandDown
    if standDown and standDown.enabled ~= false then
        CreateThread(function()
            -- after the follow-up banners above, so "Convoy Event Concluded" is always the last thing shown
            Wait(((standDown.delaySeconds or 6) + followUps * BANNER_GAP_SECONDS) * 1000)
            local sdb = resolveBanner(
                'convoyStandDown',
                standDown.title or 'Convoy Event Concluded',
                standDown.body or 'All participants and police are requested to clear the area immediately. Do not engage in further shootouts or hostilities — the event has ended.',
                standDown.duration or standDown.durationMs or 9000,
                standDown.kind or 'info'
            )
            if sdb then
                announceServerWide(rt, sdb.title, sdb.body, sdb.duration, sdb.kind)
            end
        end)
    end

    local gangIdentifiers = {}
    for identifier in pairs(rt.participants.identifiers) do gangIdentifiers[#gangIdentifiers + 1] = identifier end

    if outcome == 'COMPLETED' then
        local deliveredRewards = {}
        local hasPerTruckReward = false
        if rt.trucks then
            for _, t in pairs(rt.trucks) do
                if t.reward and #t.reward > 0 then
                    hasPerTruckReward = true
                    if t.delivered then
                        for _, r in ipairs(t.reward) do
                            deliveredRewards[#deliveredRewards + 1] = r
                        end
                    end
                end
            end
        end
        if hasPerTruckReward and #deliveredRewards > 0 then
            RewardService.GiveConvoyReward(rt.def, policeSources(), deliveredRewards, rt.startedAt)
        else
            RewardService.GiveConvoyReward(rt.def, policeSources(), nil, rt.startedAt)
        end
    elseif outcome == 'CAPTURED' then
        -- Leaderboard credit: every gang that captured at least one truck
        -- gets credited for each truck THEY captured (rt.gangCaptureCounts,
        -- already tracked per-gang) — not just capturingGang (the single
        -- top capturer), which used to be the ONLY gang credited at all,
        -- leaving every other gang that also captured a truck with no
        -- record whatsoever. The in-game REWARD payout below stays exactly
        -- as before (capturingGang only) — splitting the actual loot across
        -- multiple gangs is a separate, bigger design question than fixing
        -- the stat.
        local isRealGang = function(n) return n and n ~= 'independent' and n ~= 'street_racers' and n ~= 'civilian' end
        if next(rt.gangCaptureCounts or {}) then
            for gangName, count in pairs(rt.gangCaptureCounts) do
                if isRealGang(gangName) then
                    for _ = 1, count do
                        GangService.RecordOutcome(gangName, 'captured')
                    end
                end
            end
        elseif capturingGang and isRealGang(capturingGang) then
            GangService.RecordOutcome(capturingGang, 'captured')
        end
        if capturingGang and isRealGang(capturingGang) then
            local recipients = {}
            for identifier, gangName in pairs(rt.participants.identifiers) do
                if gangName == capturingGang then
                    local src = findSourceByIdentifier(identifier)
                    if src then recipients[#recipients + 1] = src end
                end
            end
            local capturedRewards = {}
            local hasPerTruckReward = false
            if rt.trucks then
                for _, t in pairs(rt.trucks) do
                    if t.reward and #t.reward > 0 then
                        hasPerTruckReward = true
                        if t.captured or t.disabled or (t.lootedBy and t.lootedBy.gang == capturingGang) then
                            for _, r in ipairs(t.reward) do
                                capturedRewards[#capturedRewards + 1] = r
                            end
                        end
                    end
                end
            end
            if hasPerTruckReward and #capturedRewards > 0 then
                RewardService.GrantGangReward(capturingGang, rt.def, recipients, capturingIdentity and capturingIdentity.label, { runId = rt.startedAt }, capturedRewards)
            else
                RewardService.GrantGangReward(capturingGang, rt.def, recipients, capturingIdentity and capturingIdentity.label, { runId = rt.startedAt })
            end
        end
    elseif outcome ~= 'CANCELLED' then
        local isRealGang = function(n) return n and n ~= 'independent' and n ~= 'street_racers' and n ~= 'civilian' end
        for gangName in pairs(rt.participants.gangCounts) do
            if isRealGang(gangName) then
                GangService.RecordOutcome(gangName, 'failed')
            end
        end
    end

    -- Civilian leaderboard tracking for CONVOY
    if CivilianService and CivilianService.RecordResult and outcome ~= 'CANCELLED' then
        local seenCivs = {}
        for _, t in pairs(rt.trucks or {}) do
            if t.capturedBy and (t.capturedBy.isCivilian or t.capturedBy.gang == 'civilian') then
                local ident = t.capturedBy.identifier
                if ident and not seenCivs[ident] then
                    seenCivs[ident] = true
                    CivilianService.RecordResult(ident, t.capturedBy.name or 'Civilian', 'convoy', rt.def.name, {
                        wins = (outcome == 'CAPTURED') and 1 or 0,
                        podiums = 1,
                        participations = 1,
                        points = 25,
                        rewards = 0,
                    })
                end
            end
        end
        for ident, pType in pairs(rt.participants.types or {}) do
            if pType == 'civilian' and not seenCivs[ident] then
                seenCivs[ident] = true
                CivilianService.RecordResult(ident, rt.participants.names[ident] or 'Civilian', 'convoy', rt.def.name, {
                    wins = 0,
                    podiums = 0,
                    participations = 1,
                    points = 5,
                    rewards = 0,
                })
            end
        end
    end

    local reportData = buildConvoyReportData(rt, outcome, forcedByName)

    DB.insertConvoyHistory({
        convoyDefinitionId = convoyId,
        name = rt.def.name,
        createdBy = rt.def.createdBy,
        startedAt = rt.startedAt,
        endedAt = os.time(),
        duration = os.time() - rt.startedAt,
        truckCount = #rt.def.trucks,
        policeParticipants = #policeSources(),
        gangParticipants = #gangIdentifiers,
        winningGang = capturingGang,
        outcome = outcome,
        rewardSummary = (function()
            local parts = {}
            for _, r in ipairs(rt.def.reward or {}) do parts[#parts + 1] = r.type end
            return #parts > 0 and table.concat(parts, ', ') or nil
        end)(),
        destroyedTrucks = destroyed,
        checkpointsCompleted = rt.currentRouteIndex - 1,
        kind = rt.def.kind or 'CONVOY',
        reportData = reportData,
    })

    local winnerLabel = 'None'
    if outcome == 'COMPLETED' then
        winnerLabel = '🛡️ Law Enforcement (Police Escort Secured Cargo)'
    elseif outcome == 'CAPTURED' then
        winnerLabel = ('🏴 %s'):format(capturingIdentity and capturingIdentity.label or capturingGang or 'Gang')
    elseif outcome == 'CANCELLED' then
        winnerLabel = 'Cancelled by Administrator'
    elseif outcome == 'FAILED' then
        winnerLabel = 'None (Cargo Destroyed / Failed to Deliver)'
    end

    local durSec = os.time() - rt.startedAt
    local durText = ('%dm %02ds'):format(math.floor(durSec / 60), durSec % 60)

    local endFields = {
        { name = 'Operation', value = rt.def.name, inline = true },
        { name = 'Outcome', value = outcome, inline = true },
        { name = 'Winner', value = winnerLabel, inline = true },
        { name = 'Start Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', rt.startedAt), rt.startedAt), inline = true },
        { name = 'End Time', value = ('%s (<t:%d:T>)'):format(os.date('!%H:%M:%S UTC', os.time()), os.time()), inline = true },
        { name = 'Duration', value = durText, inline = true },
        { name = 'Fleet Status', value = ('Delivered: %d | Captured: %d | Destroyed: %d (Total: %d)'):format(delivered, captured, destroyed, #rt.def.trucks), inline = false },
    }

    -- route progress and who took part
    do
        local total = #(rt.route or {})
        local reached = math.max(0, math.min(total, (rt.currentRouteIndex or 1) - 1))
        local policeN, gangLines = 0, {}
        for _ in pairs(rt.participants.policeIdentifiers or {}) do policeN = policeN + 1 end
        for gName, count in pairs(rt.participants.gangCounts or {}) do
            local identity = gangIdentity(rt, gName)
            gangLines[#gangLines + 1] = ('%s ×%d'):format(identity and identity.label or gName, count)
        end
        table.sort(gangLines)
        endFields[#endFields + 1] = { name = 'Route Progress', value = ('%d / %d checkpoints cleared'):format(reached, total), inline = true }
        endFields[#endFields + 1] = { name = 'Police Escorts', value = tostring(policeN), inline = true }
        endFields[#endFields + 1] = { name = 'Gangs Engaged', value = #gangLines > 0 and table.concat(gangLines, ', '):sub(1, 900) or 'None', inline = true }
    end

    local keyCapturers = {}
    for _, t in pairs(rt.trucks or {}) do
        if t.capturedBy then
            keyCapturers[#keyCapturers + 1] = ('• **%s** (%s) [%s] — Captured %s'):format(
                t.capturedBy.name or 'Unknown',
                t.capturedBy.identifier or 'N/A',
                t.capturedBy.gangLabel or t.capturedBy.gang or 'Gang',
                TRUCK_ROLE_LABELS[t.role] or t.id
            )
        elseif t.lootedBy and not t.lootedBy.viaBypass then
            keyCapturers[#keyCapturers + 1] = ('• **%s** (%s) [%s] — Looted %s (%s)'):format(
                t.lootedBy.name or 'Unknown',
                t.lootedBy.identifier or 'N/A',
                t.lootedBy.gangLabel or t.lootedBy.gang or 'Independent',
                TRUCK_ROLE_LABELS[t.role] or t.id,
                t.lootedBy.viaHack and 'Hacked' or 'Cracked'
            )
        end
    end
    for _, c in ipairs(rt.airdropCaptures or {}) do
        keyCapturers[#keyCapturers + 1] = ('• **%s** (%s) [%s] — Claimed Airdrop "%s"'):format(
            c.playerName or 'Unknown',
            c.playerIdentifier or 'N/A',
            c.gangLabel or c.gang or 'Independent',
            c.dropName or 'Drop'
        )
    end
    for _, h in ipairs(rt.pvpHijacks or {}) do
        keyCapturers[#keyCapturers + 1] = ('• ⚔️ **%s** (%s) killed **%s** (%s) — Stole %s'):format(
            h.killer.name or 'Killer',
            h.killer.gangLabel or 'Gang',
            h.victim.name or 'Carrier',
            h.victim.gangLabel or 'Gang',
            h.rewards or 'Cargo'
        )
    end
    if #keyCapturers > 0 then
        endFields[#endFields + 1] = {
            name = 'Key Interceptions & Stolen Cargo',
            value = table.concat(keyCapturers, '\n'),
            inline = false,
        }
    end
    for _, f in ipairs(ReportBuilder.payoutFields(convoyId)) do endFields[#endFields + 1] = f end
    if outcome == 'CANCELLED' and forcedByName then
        endFields[#endFields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true }
    end

    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(reportData)
    end

    if pdfString then
        endFields[#endFields + 1] = {
            name = '📄 After-Action Report (PDF)',
            value = 'Full tactical audit report generated and attached to this message.',
            inline = false,
        }
    end

    DiscordLog.finishEvent(convoyId, ('Convoy Ended — %s'):format(rt.def.name),
        ({ COMPLETED = 0x22c55e, CAPTURED = 0xef4444, FAILED = 0xef4444, CANCELLED = 0x6b7280 })[outcome] or 0x6b7280,
        endFields, nil, pdfString)
    RewardService.ClearPayouts(convoyId)
end

-- Pulls the {truckId} back out of a stashId built as
-- ('convoy_truck_%d_%s'):format(rt.id, t.id) — lets the loot handlers below
-- find the specific truck (for its lockpicksRequired/lockProgress) without
-- having to pass it separately through every client event.
local function truckFromStash(rt, stashId)
    if not rt or not stashId then return nil end
    local truckId = stashId:match('^convoy_truck_%d+_(.+)$') or stashId:match('^convoy_hotcargo_%d+_(.+)$')
    return truckId and rt.trucks[truckId] or nil
end

-- Resolution order: this specific truck's own override (Trucks tab) > this
-- convoy's own default (General tab) > the server-wide config default.
local function requiredLockpicksFor(rt, t)
    if t and t.lockpicksRequired then return t.lockpicksRequired end
    if rt and rt.def.settings.lockpicksRequired then return rt.def.settings.lockpicksRequired end
    return (Config.CapturedTruckLoot and Config.CapturedTruckLoot.lockpicksRequired) or 1
end

-- Forward-declared: tryLootTruck below calls this from its police/admin
-- bypass branch, but the actual definition (shared with the lockpick/hack
-- success paths further down) needs rt/gangIdentity/etc. already in scope,
-- so it's defined after this point in the file — declaring the local here
-- first is what lets tryLootTruck reference it before that happens.
local finishTruckLoot

-- Server-validates a loot attempt on a lost truck's stash: the requester must
-- either be a joined gang participant on this convoy, or police/an admin
-- (both bypass the lockpick+minigame entirely, see Config.CapturedTruckLoot.
-- policeBypass — never trust the client's target interaction alone either
-- way). Otherwise, if configured, they must carry a lockpick, consumed on
-- every attempt regardless of the skill check outcome that follows
-- client-side (same convention most lockpick minigames use — the tool gets
-- used up whether or not you succeed). Reaching Config.CapturedTruckLoot's
-- lockpicksRequired count of SUCCESSFUL attempts (default 1, overridable per
-- truck or per convoy) is what actually opens the stash.
function Runtime.tryLootTruck(src, convoyId, stashId, netId)

    if (not convoyId or not stashId) and netId then
        local ent = NetworkGetEntityFromNetworkId(netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local st = Entity(ent).state
            convoyId = convoyId or st.convoy_id
            stashId = stashId or st.convoy_stash_id
        end
    end

    if not convoyId and stashId then
        for cid, r in pairs(active) do
            local tr = truckFromStash(r, stashId)
            if tr then convoyId = cid; break end
        end
    end

    -- Hot Cargo reward crate: completely unlocked with 60-minute post-event anti-theft sentry
    if stashId and stashId:find('^convoy_hotcargo_') then
        local sentry = hotCargoSentries[convoyId]
        local identifier = Bridge.GetIdentifier(src)
        local playerName = Bridge.GetPlayerName(src) or 'Unknown Player'
        local isPolice = Bridge.IsPolice(src)
        local isAdmin = UserPermissions.can(src, 'convoys.manage')

        if sentry and os.time() <= (sentry.expiresAt or 0) then
            local isAuthorized = isAdmin
            if not isAuthorized and sentry.winningMembers and identifier and sentry.winningMembers[identifier] then
                isAuthorized = true
            end
            if not isAuthorized and sentry.winningGang then
                local g = GangService and GangService.GetPlayerGang(src)
                if g and g.name == sentry.winningGang then
                    isAuthorized = true
                end
            end

            if not isAuthorized then
                local looterGang = nil
                local g = GangService and GangService.GetPlayerGang(src)
                if g and g.name then looterGang = g.name end
                local looterLabel = (g and g.label) or looterGang or (isPolice and 'Police Department' or 'Civilian / Rival')
                local elapsed = os.time() - (sentry.deliveredAt or os.time())
                local fields = {
                    { name = '🚨 VIOLATION', value = 'Unauthorized player opened / looted the reward crate belonging to the winning faction during the 60-minute protection window!', inline = false },
                    { name = 'Operation', value = sentry.name or ('Hot Cargo #' .. tostring(convoyId)), inline = true },
                    { name = 'Winning Faction', value = tostring(sentry.winningGangLabel or sentry.winningGang or 'Unknown'), inline = true },
                    { name = 'Perpetrator / Thief', value = ('%s (%s)\n`%s`'):format(playerName, looterLabel, identifier or 'N/A'), inline = true },
                    { name = 'Time Since Delivery', value = ('%dm %02ds (Protection: 60m)'):format(math.floor(elapsed / 60), elapsed % 60), inline = true },
                    { name = 'Stash ID', value = stashId, inline = true },
                }
                DiscordLog.postEventGriefingAlert(
                    ('🚨 [POST-EVENT SENTRY AUDIT — SUSPECTED CRATE THEFT] %s'):format(sentry.name or 'Hot Cargo'),
                    'Anti-Griefing Watchdog triggered: Unauthorized individual accessed the winning faction\'s secured reward crate.',
                    fields
                )
            end
        end

        TriggerClientEvent('nova_convoytruck:runtime:openTruckLoot', src, stashId)
        return
    end

    local loot = Config.CapturedTruckLoot
    if not loot or not loot.enabled then return end

    local rt = active[convoyId]
    local t = truckFromStash(rt, stashId)
    if not t and netId and rt and rt.trucks then
        for _, trk in pairs(rt.trucks) do
            if trk.netId == netId then
                t = trk
                stashId = stashId or trk.stashId
                break
            end
        end
    end

    local isPolice = Bridge.IsPolice(src)
    local isAdmin = UserPermissions.can(src, 'convoys.manage')
    local isParticipant = convoyId and Runtime.isParticipant(convoyId, src)
    local playerGang = (GangService and GangService.GetPlayerGang(src))
    if not isPolice and not isAdmin and not isParticipant and not playerGang then return end

    if not isParticipant and playerGang and rt then
        local identifier = Bridge.GetIdentifier(src)
        if identifier then
            rt.participants = rt.participants or { identifiers = {}, gangCounts = {}, names = {} }
            rt.participants.identifiers = rt.participants.identifiers or {}
            rt.participants.gangCounts = rt.participants.gangCounts or {}
            rt.participants.names = rt.participants.names or {}
            rt.participants.identifiers[identifier] = playerGang.name
            rt.participants.gangCounts[playerGang.name] = (rt.participants.gangCounts[playerGang.name] or 0) + 1
            rt.participants.names[identifier] = Bridge.GetPlayerName(src) or 'Unknown'
        end
    end

    -- An admin who is also a member of a gang plays as that gang member: no bypass, the lockpick / hack minigame applies. An admin
    -- without a gang (and on-duty police) keep the direct access.
    local adminBypass = isAdmin and not playerGang
    if (isPolice or adminBypass) and loot.policeBypass ~= false then
        -- Logged once (first access) via finishTruckLoot, not on every
        -- re-open — see its own comment for why this is logged at all now.
        if t and not t.lockUnlocked then
            finishTruckLoot(rt, t, src, false, true)
        end
        TriggerClientEvent('nova_convoytruck:runtime:openTruckLoot', src, stashId)
        return
    end

    if t and t.lockUnlocked then
        TriggerClientEvent('nova_convoytruck:runtime:openTruckLoot', src, stashId)
        return
    end

    -- "Require a lockpick" OFF doesn't mean "just open it for free" — it
    -- means a different, harder minigame (hacking, not picking) gates it
    -- instead, with a guaranteed opening on success. No item consumed, no
    -- multi-attempt progress (that concept is specific to lockpicking).
    if not loot.requireLockpick then
        TriggerClientEvent('nova_convoytruck:runtime:beginTruckHackMinigame', src, convoyId, stashId)
        return
    end

    if not beginLockpickAttempt(src, loot.lockpickItem, convoyId, ('%s cargo'):format(t and (TRUCK_ROLE_LABELS[t.role] or t.id) or 'Truck')) then
        return
    end

    local required = requiredLockpicksFor(rt, t)
    TriggerClientEvent('nova_convoytruck:runtime:beginTruckLootMinigame', src, convoyId, stashId, (t and t.lockProgress) or 0, required)
end

RegisterNetEvent('nova_convoytruck:runtime:server:tryLootTruck', function(convoyId, stashId, netId)
    Runtime.tryLootTruck(source, convoyId, stashId, netId)
end)

-- Police / admins can look inside a convoy truck that is still running (no lockpick, no
-- minigame, no need for the truck to be disabled first). Validated server-side: the caller
-- must be on-duty police or hold convoys.manage, and the truck must belong to a live event.
function Runtime.inspectTruckCargo(src, netId)
    local loot = Config.CapturedTruckLoot
    if not loot or not loot.enabled or loot.inspectLiveTrucks == false then return end
    if not (Bridge.IsPolice(src) or UserPermissions.can(src, 'convoys.manage')) then return end
    local ent = netId and NetworkGetEntityFromNetworkId(netId) or 0
    if not ent or ent == 0 or not DoesEntityExist(ent) then return end
    local rt = active[Entity(ent).state.convoy_id]
    if not rt or not rt.trucks then return end
    for _, t in pairs(rt.trucks) do
        if t.entity == ent then
            if t.delivered or t.destroyed then return end
            local stashId = seedTruckStash(rt, t, GetEntityCoords(ent))
            TriggerClientEvent('nova_convoytruck:runtime:openTruckLoot', src, stashId)
            return
        end
    end
end

RegisterNetEvent('nova_convoytruck:runtime:server:inspectTruckCargo', function(netId)
    Runtime.inspectTruckCargo(source, netId)
end)

-- ── Hot Cargo vehicle theft (initial entry, not the post-delivery reward
-- crate — that one's handled above in tryLootTruck's 'convoy_hotcargo_'
-- branch, and is deliberately unlocked). Open participation: any non-police
-- player may attempt it, first to succeed gets the vehicle — mirrors
-- tryLootTruck's item-consume / minigame-trigger shape exactly.
-- Shared by the "Hijack Cargo Truck" target prompt AND by using the lockpick item
-- next to the truck (Runtime.useLockpickItem below).
function Runtime.tryUnlockHotCargo(src, convoyId, truckId)
    local theft = Config.HotCargoTheft
    if not theft or not theft.enabled then return end

    local rt = active[convoyId]
    if not rt or rt.def.kind ~= 'HOT_CARGO' then return end
    local t = rt.trucks and rt.trucks[truckId]
    if not t or not t.entity or not DoesEntityExist(t.entity) then return end
    if t.unlocked or t.delivered or t.destroyed then return end
    if Bridge.IsPolice(src) then return end

    if not theft.requireLockpick then
        TriggerClientEvent('nova_convoytruck:runtime:beginHotCargoUnlockMinigame', src, convoyId, truckId, false, theft.skillCheckDifficulty)
        return
    end

    if not beginLockpickAttempt(src, theft.lockpickItem, convoyId, ('Cargo Truck #' .. tostring(tonumber(tostring(truckId):match('(%d+)$')) or 1))) then
        return
    end

    TriggerClientEvent('nova_convoytruck:runtime:beginHotCargoUnlockMinigame', src, convoyId, truckId, true, theft.skillCheckDifficulty)
end

RegisterNetEvent('nova_convoytruck:runtime:server:tryUnlockHotCargo', function(convoyId, truckId)
    Runtime.tryUnlockHotCargo(source, convoyId, truckId)
end)

-- Using the lockpick ITEM. On a framework like QBX the lockpick item belongs to the
-- vehicle-keys script, which runs ox_lib's generic skill check on any locked vehicle
-- — that is the "default" minigame players saw on Hot Cargo trucks. This resource
-- takes the item over (see server/main.lua) and asks here first: standing at a
-- locked Hot Cargo truck, or at a broken-down truck / loot crate, the lockpick runs
-- THIS resource's own minigame; anywhere else it returns false and the item behaves
-- exactly as before. Returns true when it handled the use.
function Runtime.useLockpickItem(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pc = GetEntityCoords(ped)
    local REACH = 6.0 -- metres from the truck's centre; a rig is long, doors are not at the middle
    local hijack, loot, bestD = nil, nil, REACH + 1.0

    for convoyId, rt in pairs(active) do
        for truckId, t in pairs(rt.trucks or {}) do
            local live = t.entity and DoesEntityExist(t.entity)
            local pos = live and GetEntityCoords(t.entity) or (t.propEntity and DoesEntityExist(t.propEntity) and GetEntityCoords(t.propEntity)) or nil
            if pos then
                local d = #(pc - pos)
                if d <= REACH and d < bestD then
                    if rt.def.kind == 'HOT_CARGO' and live and not t.unlocked and not t.delivered and not t.destroyed and not t.brokenDown then
                        if not Bridge.IsPolice(src) then bestD, hijack, loot = d, { convoyId, truckId }, nil end
                    elseif t.stashId and (t.brokenDown or t.disabled or t.destroyed) and not t.delivered then
                        bestD, loot, hijack = d, { convoyId, t.stashId, t.netId }, nil
                    end
                end
            end
        end
    end

    if hijack then
        Runtime.tryUnlockHotCargo(src, hijack[1], hijack[2])
        return true
    end
    if loot then
        Runtime.tryLootTruck(src, loot[1], loot[2], loot[3])
        return true
    end
    return false
end

-- Keys for the officer/admin who just took the wheel of a convoy truck (see the seat watcher in runtime_client.lua).
-- Everyone else is ignored; gang members in the seat are removed by enforceDriverSeat.
RegisterNetEvent('nova_convoytruck:runtime:server:requestTruckKeys', function(netId)
    local src = source
    local veh = netId and NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if not Entity(veh).state.convoy_truck or GetPedInVehicleSeat(veh, -1) ~= GetPlayerPed(src) then return end
    -- police/admin may drive any convoy truck; a lockpicked (hijacked) Hot Cargo truck is open to whoever sits in it
    local hijacked = Entity(veh).state.hot_cargo_truck and Entity(veh).state.hot_cargo_locked == false
    if not (hijacked or Bridge.IsPolice(src) or Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission)) then return end
    pcall(Bridge.GiveVehicleKeys, src, veh)
end)

RegisterNetEvent('nova_convoytruck:runtime:server:reportHotCargoUnlockAttempt', function(convoyId, truckId, success)
    local src = source
    local rt = active[convoyId]
    if not rt or rt.def.kind ~= 'HOT_CARGO' then return end
    local t = rt.trucks and rt.trucks[truckId]
    if not t or t.unlocked or t.delivered or t.destroyed then pendingLockpick[src] = nil return end

    local lpInfo = settleLockpickAttempt(src, success)
    if lpInfo then
        logLockpickAttempt(rt, src, ('Cargo Truck #' .. tostring(tonumber(tostring(truckId):match('(%d+)$')) or 1)), success, lpInfo)
        tellLockpickResult(src, success, lpInfo)
    end
    if not success then return end

    t.unlocked = true
    if t.entity and DoesEntityExist(t.entity) then
        SetVehicleDoorsLocked(t.entity, 1)
        Entity(t.entity).state:set('doorslockstate', 1, true)
        Entity(t.entity).state:set('hot_cargo_locked', false, true)
    end
    notify(Bridge.GetPlayers(), 'nova_convoytruck:runtime:hotCargoUnlocked', t.netId)
    DiscordLog.appendEvent(rt.id, ('🔓 [HOT CARGO] %s unlocked a contraband vehicle (%s)'):format(Bridge.GetPlayerName(src) or 'Unknown', truckId))
    -- The unlock IS the hijack: ownership, server-wide banner, destination for
    -- the hijacking gang only, police alert (if enabled) all start here.
    HC.setOwner(rt, t, src)
end)

-- Shared by both the lockpick path (reportLootAttempt) and the hacking path
-- (reportTruckHackAttempt) once either one actually opens the stash —
-- same "gang crime, visible to police/admins" banner and event-log entry
-- either way, only the wording differs.
-- viaBypass: reached through the police/admin bypass in tryLootTruck
-- (skips the lockpick/hack minigame entirely) rather than a tracked gang
-- participant actually cracking it open. This ALWAYS logs now, regardless
-- of who did it — an on-duty officer (or admin) looting convoy cargo
-- through their own bypass access is exactly the "trusted role, no
-- oversight" scenario that most needs a paper trail, since a corrupt or
-- gang-complicit officer could otherwise raid every truck on the server
-- with zero record of it. Previously this whole function was a no-op
-- unless the looter was a tracked gang participant, which silently
-- skipped logging for every bypass loot.
function finishTruckLoot(rt, t, src, viaHack, viaBypass)
    t.lockUnlocked = true
    local identifier = Bridge.GetIdentifier(src)
    local playerName = Bridge.GetPlayerName(src) or 'Unknown'
    local isPolice = Bridge.IsPolice(src) or false
    local jobGrade = Bridge.GetJobGrade(src) or nil
    local jobName = jobGrade and jobGrade.name or (isPolice and 'police' or 'civilian')
    local gangName = identifier and rt.participants.identifiers[identifier]
    if not gangName and not isPolice then
        local g = GangService.GetPlayerGang(src)
        if g and g.name then gangName = g.name end
    end
    local identity = gangName and gangIdentity(rt, gangName) or nil
    local gangLabel = identity and identity.label or gangName or (isPolice and 'Police Department' or 'Independent')
    local itemsStr = truckLootItemsLine(t)

    -- Disabled/broken-down Hot Cargo truck salvage reward — a distinct,
    -- deliberately smaller reward list from the main delivery reward,
    -- configured per Hot Cargo event (HotCargoConfig's "Disabled Truck /
    -- Salvage Reward" section) and paid directly to whoever actually cracked
    -- it open, same pattern as RewardService.GiveAirdropReward already uses
    -- for an airdrop crate. Purely additive — the generic
    -- Config.CapturedTruckLoot stash items (already sitting in the stash via
    -- makeTruckLootable) are untouched, this is on top of them, and it's a
    -- no-op for a police/admin bypass loot or when nothing is configured.
    if not viaBypass and rt.def.kind == 'HOT_CARGO' and rt.def.hotCargo and rt.def.hotCargo.salvageReward and #rt.def.hotCargo.salvageReward > 0 then
        RewardService.GiveAirdropReward(rt.def.hotCargo.salvageReward, { src }, {
            convoyId = rt.id, convoyName = rt.def.name,
            gangName = gangName, gangLabel = identity and identity.label,
            lootedBy = identifier, lootedByName = playerName,
            runId = rt.startedAt, xpPhase = 'salvage:' .. tostring(t.id),
        }, {
            event = 'hotcargo', title = 'TRUCK SALVAGED', name = rt.def.name, group = 'salvage:' .. tostring(rt.id),
        })
    elseif not viaBypass and rt.def.kind == 'CONVOY' and t.reward and #t.reward > 0 then
        local directRewards = {}
        for _, r in ipairs(t.reward) do
            local rType = string.upper(tostring(r.type or ''))
            if rType == 'MONEY' or rType == 'CASH' or rType == 'BANK' or rType == 'BLACK_MONEY' or rType == 'TOKENS' or rType == 'TOKEN' or rType == 'VEHICLE' or rType == 'GANG_XP' then
                directRewards[#directRewards + 1] = r
            end
        end
        if #directRewards > 0 then
            RewardService.GiveAirdropReward(directRewards, { src }, {
                convoyId = rt.id, convoyName = rt.def.name,
                gangName = gangName, gangLabel = identity and identity.label,
                lootedBy = identifier, lootedByName = playerName,
                runId = rt.startedAt, xpPhase = 'truck:' .. tostring(t.id),
            }, {
                event = 'convoy', title = 'TRUCK CARGO SECURED', name = truckDisplayName(t), group = 'truck:' .. tostring(t.id),
            })
        end
    end

    t.lootedBy = {
        source = src,
        name = playerName,
        identifier = identifier or 'N/A',
        gang = gangName,
        gangLabel = gangLabel,
        isPolice = isPolice,
        job = jobName,
        jobGrade = jobGrade and jobGrade.grade or 0,
        viaHack = viaHack,
        viaBypass = viaBypass,
        usedLockpick = not viaHack and not viaBypass,
        usedHack = viaHack == true,
        timestamp = os.time(),
        timeStr = os.date('!%H:%M:%S', os.time()),
    }
    -- Leaderboard credit for actually looting the stash — a separate
    -- action from capturing the truck in the first place (gangCaptureCounts
    -- above): one gang can disable/secure a truck, a different one can be
    -- the one that actually cracks it open later, and a truck that was
    -- simply destroyed (never "captured" at all) still has a lootable
    -- stash once someone opens it. Reuses the exact same accumulator/credit
    -- path as a capture — both count toward the same overall Convoy score,
    -- not two separate leaderboard columns. Police loots (fail-RP/bypass)
    -- never have a gangName and are correctly excluded.
    if gangName then
        rt.gangCaptureCounts = rt.gangCaptureCounts or {}
        rt.gangCaptureCounts[gangName] = (rt.gangCaptureCounts[gangName] or 0) + 1
    end
    rt.lootedTrucks = rt.lootedTrucks or {}
    rt.lootedTrucks[#rt.lootedTrucks + 1] = {
        truckId = t.id,
        role = t.role,
        label = truckDisplayName(t),
        looter = t.lootedBy,
        items = itemsStr,
        timestamp = os.time(),
        timeStr = os.date('!%H:%M:%S', os.time()),
    }

    if isPolice then
        rt.policeAudit = rt.policeAudit or {}
        rt.policeAudit[#rt.policeAudit + 1] = {
            type = 'TRUCK_LOOT',
            target = truckDisplayName(t),
            officerName = playerName,
            officerIdentifier = identifier,
            job = jobName,
            jobGrade = jobGrade and jobGrade.grade or 0,
            items = itemsStr,
            usedBypass = viaBypass == true,
            usedLockpick = not viaHack and not viaBypass,
            usedHack = viaHack == true,
            timestamp = os.time(),
            timeStr = os.date('!%H:%M:%S', os.time()),
            alert = rt.def.kind == 'HOT_CARGO' and 'POLICE OFFICER LOOTED HOT CARGO TRUCK' or 'POLICE OFFICER LOOTED CONVOY TRUCK CARGO',
        }
        DiscordLog.appendEvent(rt.id, ('🚨 [POLICE AUDIT / FAIL-RP] Officer %s (%s) [%s] LOOTED %s truck %s! Cargo: %s'):format(
            playerName, identifier or 'N/A', jobName, rt.def.kind == 'HOT_CARGO' and 'hot cargo' or 'convoy', truckDisplayName(t), itemsStr
        ))
    end

    registerLootCarrier(rt, src, 'TRUCK', truckDisplayName(t), itemsStr)

    if gangName then
        rt.gangCaptureCounts = rt.gangCaptureCounts or {}
        rt.gangCaptureCounts[gangName] = (rt.gangCaptureCounts[gangName] or 0) + 1

        local verb = viaHack and 'hacked' or 'cracked'
        local b
        if rt.def.kind == 'HOT_CARGO' then
            b = resolveBanner('hotCargoTruckLooted', 'HOT CARGO — TRUCK LOOTED', '%s has %s the cargo of %s.', 7000, 'success', identity and identity.label or gangName, verb, truckDisplayName(t))
            if b and not (rt.def.settings and rt.def.settings.announcements == false) then
                notify(HC.audience(rt), 'nova_convoytruck:runtime:announce', b.title, b.body, b.duration, b.kind, identity)
            end
        else
            b = resolveBanner('truckCaptured', 'Convoy Truck Captured', "%s has successfully captured the convoy truck's cargo (%s open).", 7000, 'success', identity and identity.label or gangName, verb)
            if b then announceLootToTacticalAudience(rt, b.title, b.body, b.duration, identity) end
        end
        DB.insertConvoyEvent(rt.id, 'TRUCK_LOOTED', {
            gangName = gangName, gangLabel = identity and identity.label or gangName,
            playerIdentifier = identifier, playerName = playerName,
            detail = viaHack and ('Truck %s cargo (hacked)'):format(t.id) or ('Truck %s cargo'):format(t.id),
        })
        DiscordLog.appendEvent(rt.id, ('🎒 Truck %s looted by %s (%s) [%s] — %s'):format(
            truckDisplayName(t),
            playerName,
            identifier or 'N/A',
            identity and identity.label or gangName,
            itemsStr
        ))
    elseif viaBypass then
        DB.insertConvoyEvent(rt.id, 'TRUCK_LOOTED', {
            playerIdentifier = identifier, playerName = playerName,
            detail = ('Truck %s cargo (police/admin bypass — no gang)'):format(t.id),
        })
        DiscordLog.appendEvent(rt.id, ('⚠️ Truck %s looted via POLICE/ADMIN BYPASS by %s (%s) — %s'):format(
            TRUCK_ROLE_LABELS[t.role] or t.id,
            playerName,
            identifier or 'N/A',
            itemsStr
        ))
    end
end

-- Client reports its ox_lib skill-check result back here — this is the
-- authoritative progress tracker (never trust the client to remember/report
-- its own attempt count), and the only place that actually flips a truck's
-- stash open once enough SUCCESSFUL attempts land.
RegisterNetEvent('nova_convoytruck:runtime:server:reportLootAttempt', function(convoyId, stashId, success)
    local src = source
    local rt = active[convoyId]
    local t = truckFromStash(rt, stashId)
    if not t or t.lockUnlocked then pendingLockpick[src] = nil return end

    local lpInfo = settleLockpickAttempt(src, success)
    if not lpInfo then return end -- no open attempt: ignore an unsolicited report
    logLockpickAttempt(rt, src, ('%s cargo'):format(TRUCK_ROLE_LABELS[t.role] or t.id), success, lpInfo)
    tellLockpickResult(src, success, lpInfo)
    if not success then return end

    local required = requiredLockpicksFor(rt, t)
    t.lockProgress = (t.lockProgress or 0) + 1
    if t.lockProgress >= required then
        TriggerClientEvent('nova_convoytruck:runtime:openTruckLoot', src, stashId)
        finishTruckLoot(rt, t, src, false)
    else
        TriggerClientEvent('nova_convoytruck:runtime:lootProgress', src, t.lockProgress, required)
    end
end)

-- The "Require a lockpick" OFF path — a single, harder skill check instead
-- of a consumable-lockpick multi-attempt grind. Success opens it outright,
-- no percentage roll involved (trucks pay out fixed stash contents either
-- way, so there was never a "might get nothing" roll here to begin with —
-- that concept only applies to airdrops, see reportAirdropHackAttempt).
RegisterNetEvent('nova_convoytruck:runtime:server:reportTruckHackAttempt', function(convoyId, stashId, success)
    local src = source
    local rt = active[convoyId]
    local t = truckFromStash(rt, stashId)
    if not t or t.lockUnlocked then return end

    if not success then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'Hack failed — the lock reset, try again.', 'error')
        return
    end

    TriggerClientEvent('nova_convoytruck:runtime:openTruckLoot', src, stashId)
    finishTruckLoot(rt, t, src, true)
end)

-- Police (or an admin/creator-access user, who can already start any convoy
-- from the tablet and shouldn't need to go find a computer just to use the
-- field trigger too) interacting with a convoy's physical start-trigger ped
-- (placed via the tablet, see ConvoyManager.broadcastStartPeds) AND by the
-- convoy's own scheduled time having actually arrived; trying early gets
-- told when to come back instead of silently doing nothing.
RegisterNetEvent('nova_convoytruck:runtime:server:triggerStartPed', function(convoyId)
    local src = source
    local def = ConvoyManager.get(convoyId)
    if not def then return end

    if def.kind == 'GANG_RACE' then
        if Bridge.IsPolice(src) and not UserPermissions.can(src, 'convoys.manage') then
            TriggerClientEvent('nova_convoytruck:client:notify', src, 'Police cannot organize or start illegal street races.', 'error')
            return
        end

        local rt = active[convoyId]
        if rt and rt.def.kind == 'GANG_RACE' and rt.phase == 'GRID' then
            local ok, err = Runtime.startRaceCountdown(src, convoyId)
            if ok then
                TriggerClientEvent('nova_convoytruck:client:notify', src, '🏁 Race countdown initiated!', 'success')
            else
                TriggerClientEvent('nova_convoytruck:client:notify', src, err or 'Failed to start countdown.', 'error')
            end
            return
        end
    else
        if not Bridge.IsPolice(src) and not UserPermissions.can(src, 'convoys.manage') then return end
    end

    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'This event is not currently available to start.', 'error')
        return
    end

    -- A SCHEDULED event still has to wait for its due time; a DRAFT one
    -- (never scheduled) has no due time at all, so the ped just triggers it
    -- instantly — same as the tablet's own "Start" button, just from
    -- the field instead of the admin tablet.
    if def.status == 'SCHEDULED' and (not def.scheduledAt or Scheduler.nowUtc() < def.scheduledAt) then
        local timeMsg = (def.recurrence and def.recurrence.enabled and def.recurrence.mode == 'WINDOW')
            and ('Operation scheduled %s. Be on standby.'):format(Scheduler.formatScheduleSummary(def))
            or ('This event is scheduled to start at %s. Come back then.'):format(Scheduler.formatLocal(def.scheduledAt))
        TriggerClientEvent('nova_convoytruck:client:notify', src, timeMsg, 'warn')
        return
    end

    local ok, err = Runtime.startScheduled(convoyId)
    if not ok then
        TriggerClientEvent('nova_convoytruck:client:notify', src, err or 'Failed to start event.', 'error')
    end
end)

-- Manual delivery (pressing [E] at the drop zone) — works for police players
-- driving the truck or standing near it at destination. Also serves as fallback
-- for automated arrival (checkDeliveries); uses the same deliverTruck path.
RegisterNetEvent('nova_convoytruck:runtime:server:completeDelivery', function(convoyId, netId)
    local src = source
    local rt = convoyId and active[convoyId]
    if not rt and netId then
        for cid, candRt in pairs(active) do
            for _, t in pairs(candRt.trucks or {}) do
                if t.netId == netId then
                    rt = candRt
                    convoyId = cid
                    break
                end
            end
            if rt then break end
        end
    end
    if not rt then
        for cid, candRt in pairs(active) do
            if candRt.participants and candRt.participants.policeIdentifiers and candRt.participants.policeIdentifiers[Bridge.GetIdentifier(src)] then
                rt = candRt
                convoyId = cid
                break
            end
        end
    end
    if not rt or (rt.status ~= 'DELIVERY' and rt.status ~= 'ACTIVE') then return end

    local identifier = Bridge.GetIdentifier(src)
    local isPolice = Bridge.IsPolice(src)
        or (rt.participants and rt.participants.policeIdentifiers and rt.participants.policeIdentifiers[identifier])
        or UserPermissions.can(src, 'convoys.manage')
    if not isPolice then return end

    local dest = findPoint(rt.route, 'DESTINATION')
    if not dest then return end

    local targetTruck = nil
    if netId then
        for _, t in pairs(rt.trucks) do
            if t.netId == netId then
                targetTruck = t
                break
            end
        end
    end

    local ped = GetPlayerPed(src)
    local pedCoords = (ped and DoesEntityExist(ped)) and GetEntityCoords(ped) or nil

    if not targetTruck and ped and pedCoords then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 then
            local vehNet = NetworkGetNetworkIdFromEntity(veh)
            for _, t in pairs(rt.trucks) do
                if t.netId == vehNet or (t.entity and t.entity == veh) then
                    targetTruck = t
                    break
                end
            end
        end
        if not targetTruck then
            for _, t in pairs(rt.trucks) do
                if not t.delivered and not t.destroyed and not t.captured and t.entity and DoesEntityExist(t.entity) then
                    if #(pedCoords - GetEntityCoords(t.entity)) < 15.0 then
                        targetTruck = t
                        break
                    end
                end
            end
        end
    end

    if not targetTruck or targetTruck.delivered or targetTruck.destroyed or targetTruck.captured then return end

    local truckCoords = (targetTruck.entity and DoesEntityExist(targetTruck.entity)) and GetEntityCoords(targetTruck.entity) or (targetTruck.lastCoords or pedCoords)
    local dist = truckCoords and #(vector2(truckCoords.x, truckCoords.y) - vector2(dest.x, dest.y)) or 999.0
    local distPed = pedCoords and #(vector2(pedCoords.x, pedCoords.y) - vector2(dest.x, dest.y)) or 999.0
    -- the [E] prompt only shows within the delivery circle (client), plus a little latency margin
    local maxDist = math.max(tonumber(Config.DeliveryRadius) or 20.0, 20.0) + 15.0

    if dist <= maxDist or distPed <= maxDist then
        if rt.status == 'ACTIVE' then
            unlockDelivery(rt, dest)
        end
        deliverTruck(rt, targetTruck)
        if active[rt.id] and #survivingCargoTrucks(rt) == 0 then
            Runtime.finish(rt.id)
        end
    else
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Truck is too far from the delivery dropzone (%d m, needs %d m or less).'):format(math.floor(math.min(dist, distPed)), math.floor(maxDist)), 'error')
    end
end)

function Runtime.get(convoyId)
    return active[convoyId]
end

function Runtime.registerCivilianRacer(source, convoyId)
    local rt = active[convoyId]
    if not rt then return false, 'Event is not active.' end
    if rt.def.kind ~= 'GANG_RACE' then return false, 'Event is not a street race.' end
    if rt.raceFinished then return false, 'Race has already concluded.' end
    -- police may race too: the registration ped is where an officer joins (the Event Status panel is gang-only)
    local totalRacers = 0
    for _ in pairs(rt.participants.identifiers) do totalRacers = totalRacers + 1 end
    if totalRacers >= (rt.def.maxGangParticipants or Config.MaxGangParticipants or 20) then
        return false, 'Street race lineup is full.'
    end
    registerRallyRacer(rt, source, 'civilian', true)
    return true
end

function Runtime.joinGang(source, convoyId)
    local rt = active[convoyId]
    if not rt then return false, 'Event is not active.' end
    if rt.def.kind == 'HOT_CARGO' then return false, 'Hot Cargo operates with open participation; no roster registration is required.' end
    if rt.def.kind == 'GANG_RACE' then
        if Bridge.IsPolice(source) then return false, 'On-duty police cannot join an illegal street race.' end
        local totalRacers = 0
        for _ in pairs(rt.participants.identifiers) do totalRacers = totalRacers + 1 end
        if totalRacers >= (rt.def.maxGangParticipants or Config.MaxGangParticipants or 20) then
            return false, 'Street race lineup is full.'
        end
        registerRallyRacer(rt, source)
        return true
    end
    if not rt.def.settings.gangPvp then return false, 'Gang participation is disabled for this event.' end

    -- Joining tags the player's ped into the hostile-to-NPC relationship
    -- group (NpcManager.setPlayerHostile) — an on-duty officer must never be
    -- able to end up in that group, since checkpoint police/army NPCs treat
    -- everyone outside it as a companion and would otherwise be safe to
    -- fire on. This is on top of them staying safe by default; it closes the
    -- one edge case where a player is both police AND in a participating gang.
    if Bridge.IsPolice(source) then return false, 'On-duty police cannot join an event as a gang participant.' end

    local gang = GangService.GetPlayerGang(source)
    if not gang then return false, 'You are not in a gang.' end

    for _, g in ipairs(GangService.GetGangs()) do
        if g.name == gang.name and g.canParticipate == false then
            return false, 'Your gang is not permitted to participate in events.'
        end
    end

    local identifier = Bridge.GetIdentifier(source)
    -- Re-syncing an already-joined participant (typically after they died
    -- and respawned) instead of hard-erroring: GTA gives a fresh ped on
    -- respawn, so the hostile relationship group and drive-by capability
    -- applied on the original join don't carry over to it, and clicking
    -- Join again used to be the only way back in — except it just failed
    -- with "already joined," leaving them stuck with none of that for the
    -- rest of the convoy. Re-apply the per-ped state and succeed instead.
    if rt.participants.identifiers[identifier] then
        NpcManager.setPlayerHostile(source, true)
        if rt.def.kind ~= 'GANG_AIRDROP' and rt.def.settings.forceDriveBy ~= false then
            TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, true)
        end
        if rt.participants.optedOutGang then rt.participants.optedOutGang[identifier] = nil end
        return true
    end

    -- Only identifiers the gang leader pre-approved (before the convoy
    -- departed, via ConvoyManager.setGangRoster) may become a tracked
    -- participant — this is what stops a leader padding the roster with
    -- people who never actually show up: they still have to be listed AND
    -- self-join here, and capture/airdrop/reward eligibility all key off
    -- rt.participants.identifiers, not roster size. Only enforced for the
    -- 'internal' gang provider — 'framework'/'custom' gangs have no leader
    -- concept ConvoyManager.setGangRoster can authenticate against, so
    -- rostering is unreachable there and self-join stays open as before.
    if Config.GangProvider == 'internal' then
        local roster = rt.def.roster and rt.def.roster[gang.name]
        -- If the gang leader specifically configured a whitelist roster for this gang, enforce it.
        -- Otherwise (no leader roster restriction configured), allow all active members of this gang to join.
        if roster and #roster > 0 then
            local whitelisted = false
            for _, ident in ipairs(roster) do
                if ident == identifier then whitelisted = true break end
            end
            if not whitelisted then
                return false, 'Your gang leader did not add you to this event roster before it started.'
            end
        end
    end

    local totalGang = 0
    for _ in pairs(rt.participants.identifiers) do totalGang = totalGang + 1 end
    if totalGang >= (rt.def.maxGangParticipants or Config.MaxGangParticipants) then
        return false, 'Event participation is full.'
    end

    -- maxGangs (separate from the headcount cap above): how many DIFFERENT
    -- gangs may be involved at all. For the 'internal' provider this is
    -- already fully enforced earlier (ConvoyManager.setGangRoster refuses a
    -- new gang's roster entry once at the cap, and a gang can't reach here
    -- without one) — this check is what actually matters for
    -- 'framework'/'custom' providers, which skip rostering entirely and
    -- self-join straight through.
    local maxGangs = rt.def.settings and rt.def.settings.maxGangs
    if maxGangs and maxGangs > 0 and not rt.participants.gangCounts[gang.name] then
        local gangCount = 0
        for _ in pairs(rt.participants.gangCounts) do gangCount = gangCount + 1 end
        if gangCount >= maxGangs then
            return false, ('This convoy already has the maximum of %d gangs involved.'):format(maxGangs)
        end
    end

    rt.participants.identifiers[identifier] = gang.name
    rt.participants.gangCounts[gang.name] = (rt.participants.gangCounts[gang.name] or 0) + 1
    rt.participants.names[identifier] = Bridge.GetPlayerName(source)
    NpcManager.setPlayerHostile(source, true)
    GangService.RecordOutcome(gang.name, 'joined')
    if rt.def.kind ~= 'GANG_AIRDROP' and rt.def.settings.forceDriveBy ~= false then
        TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, true)
    end
    if (Config.CheckpointBeacon or {}).showToGangsFromStart then sendCheckpointBeacons(rt, source) end
    if rt.participants.optedOutGang then rt.participants.optedOutGang[identifier] = nil end
    persist(rt)
    return true
end

-- Leaving mid-convoy (the live panel's "Leave Convoy") must actually make
-- this convoy disappear for them — HUD, blips, timer, squad panel — and
-- stop feeding them any further announcements/status updates for the rest
-- of the run, not just drop them from the roster count. optedOutGang is
-- what makes that stick even if they're still an active member of a
-- gangPvp-participating gang: gangParticipantSources/broadcastGangStatus
-- would otherwise silently re-add them via that "any online gang member"
-- fallback the instant this identifier is cleared from rt.participants.
function Runtime.leaveGang(source, convoyId)
    local rt = active[convoyId]
    if not rt then return false, 'Event is not active.' end
    local identifier = Bridge.GetIdentifier(source)
    if not rt.participants.identifiers[identifier] then return false, 'You are not part of this event.' end
    rt.participants.identifiers[identifier] = nil
    rt.participants.optedOutGang = rt.participants.optedOutGang or {}
    rt.participants.optedOutGang[identifier] = true
    NpcManager.setPlayerHostile(source, false)
    TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, false)
    TriggerClientEvent('nova_convoytruck:runtime:hideAll', source)
    persist(rt)
    return true
end

-- ── police escort participation (server-validated join/leave) ────────────────────
-- Mirrors the gang join flow: an explicit opt-in action is what
-- maxPoliceParticipants actually caps AND what policeParticipantSources(rt)
-- reads from — an on-duty officer who never pre-registers or joins gets no
-- convoy-specific blips/timers/banners at all, same restriction the gang
-- side has always had. policeSources() (every online officer, unrestricted)
-- still exists and is used for a couple of deliberate exceptions (e.g. the
-- convoy's actual delivery reward payout on success), just not for any of
-- the "who currently sees this convoy's tactical info" audiences any more.

function Runtime.joinPolice(source, convoyId)
    local rt = active[convoyId]
    if not rt then return false, 'Event is not active.' end
    if rt.def.kind == 'GANG_AIRDROP' or rt.def.kind == 'HOT_CARGO' then return false, 'This event has no police escort role.' end
    if not Bridge.IsPolice(source) then return false, 'Only police may join as an escort.' end

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Player identifier unavailable.' end
    -- Same re-sync as Runtime.joinGang above: an officer who died and
    -- respawned gets a fresh ped with none of the original join's relationship
    -- group/drive-by state, and clicking Join again used to just fail with
    -- "already joined" instead of giving them a way to restore it.
    if rt.participants.policeIdentifiers[identifier] then
        TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, source, 'nova_convoy_police')
        if rt.def.settings.forceDriveBy ~= false then
            TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, true)
        end
        if Config.PoliceAlwaysSeeRouteZones ~= false and not rt.releaseHeld then
            TriggerClientEvent('nova_convoytruck:runtime:policeRouteZones', source, buildRouteZones(rt))
        end
        sendCheckpointBeacons(rt, source)
        if rt.participants.optedOutPolice then rt.participants.optedOutPolice[identifier] = nil end
        return true
    end

    local totalPolice = 0
    for _ in pairs(rt.participants.policeIdentifiers) do totalPolice = totalPolice + 1 end
    local maxCap = (rt.def.maxPoliceParticipants and tonumber(rt.def.maxPoliceParticipants) > 0) and tonumber(rt.def.maxPoliceParticipants) or (Config.MaxPoliceParticipants or 20)
    if totalPolice >= maxCap then
        return false, 'Convoy escort roster is full.'
    end

    rt.participants.policeIdentifiers[identifier] = true
    rt.participants.names[identifier] = Bridge.GetPlayerName(source)
    TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, source, 'nova_convoy_police')
    if rt.def.settings.forceDriveBy ~= false then
        TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, true)
    end
    if Config.PoliceAlwaysSeeRouteZones ~= false and not rt.releaseHeld then
        TriggerClientEvent('nova_convoytruck:runtime:policeRouteZones', source, buildRouteZones(rt))
    end
    sendCheckpointBeacons(rt, source)
    if rt.participants.optedOutPolice then rt.participants.optedOutPolice[identifier] = nil end
    persist(rt)
    return true
end

-- Same reasoning as leaveGang above: an officer leaving escort duty mid-
-- convoy needs their HUD/blips/timer actually cleared, and optedOutPolice
-- is what stops policeParticipantSources' unconditional "every on-duty
-- officer" branch from silently re-including them on the very next tick.
function Runtime.leavePolice(source, convoyId)
    local rt = active[convoyId]
    if not rt then return false, 'Event is not active.' end
    local identifier = Bridge.GetIdentifier(source)
    if not identifier or not rt.participants.policeIdentifiers[identifier] then return false, 'You are not an escort on this convoy.' end
    rt.participants.policeIdentifiers[identifier] = nil
    rt.participants.optedOutPolice = rt.participants.optedOutPolice or {}
    rt.participants.optedOutPolice[identifier] = true
    TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, source, 'PLAYER')
    TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, false)
    TriggerClientEvent('nova_convoytruck:runtime:hideAll', source)
    persist(rt)
    return true
end

-- ── Unregistered Hostile Attacker Auto-Flagging ──────────────────────────────
-- When an unjoined player shoots at a convoy truck or convoy NPC, and they are NOT
-- police, immediately tag them as hostile gang so military & police NPCs engage.
RegisterNetEvent('nova_convoytruck:runtime:reportHostileAttacker', function(convoyId)
    local src = source
    if Bridge.IsPolice(src) then return end

    local rt = active[convoyId]
    if not rt then
        for _, running in pairs(active) do
            rt = running
            break
        end
    end
    if not rt then return end

    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return end

    -- Already registered as hostile: no-op (fires every bullet, so guard carefully)
    if rt.participants.identifiers[identifier] then return end

    local gang = GangService.GetPlayerGang(src)
    local gangName = gang and gang.name or 'hostile_unregistered'
    rt.participants.identifiers[identifier] = gangName
    rt.participants.gangCounts[gangName] = (rt.participants.gangCounts[gangName] or 0) + 1
    rt.participants.names[identifier] = Bridge.GetPlayerName(src)
    NpcManager.setPlayerHostile(src, true)
    persist(rt)
end)

-- ── escort vehicle shop (client/modules/escort_shop.lua ped) ────────────────────
-- On-demand loaner vehicles for police, separate from joining as an escort
-- participant (Runtime.joinPolice above) — an officer can take a vehicle
-- without formally joining, or join without ever taking one. Not player-
-- owned/garage-persisted: tracked only in rt.escortVehicles for as long as
-- the convoy that issued it stays active, and reclaimed (deleted) the moment
-- that convoy ends or the officer returns it to the same ped. Only one
-- convoy is expected to be genuinely live at a time in normal use, so this
-- always resolves to whichever active convoy is found first.
local function firstActiveConvoy()
    for _, rt in pairs(active) do return rt end
    return nil
end

function Runtime.getEscortShopVehicles(source)
    local rt = firstActiveConvoy()
    local list = {}
    if rt and rt.def and rt.def.trucks then
        for _, t in ipairs(rt.def.trucks) do
            if t.role == 'ESCORT' then
                local catEntry = DB.getVehicleCatalogEntryByModel(t.model)
                list[#list + 1] = {
                    id = t.id,
                    model = t.model,
                    label = (catEntry and catEntry.label) or t.label or t.model,
                    price = tonumber(t.price) or 0,
                    source = 'convoy',
                }
            end
        end
    end
    -- If active convoy had no escort vehicles configured, fall back to default config vehicles
    if #list == 0 then
        for i, v in ipairs((Config.EscortVehicleShop and Config.EscortVehicleShop.vehicles) or {}) do
            list[#list + 1] = {
                id = i,
                model = v.model,
                label = v.label,
                price = v.price or 0,
                source = 'config',
            }
        end
    end
    return list
end

-- spot (optional): { x, y, z, heading } — the clear spot the showroom picked near the shop. The server only checks that it is a
-- real position close to the player (so a client cannot send the vehicle across the map); otherwise the old "beside the
-- player" spot is used.
function Runtime.requestEscortVehicle(source, vehicleData, account, spot)
    -- Player-chosen payment method (client presents a Cash/Bank submenu) —
    -- previously hardcoded to Config.EscortVehicleShop.moneyAccount, which
    -- meant an officer with the money in the other account simply couldn't
    -- buy at all. Falls back to the old config default if the client ever
    -- sends something unrecognized.
    account = (account == 'bank' or account == 'cash') and account or (Config.EscortVehicleShop.moneyAccount or 'cash')
    if not Bridge.IsPolice(source) then return false, 'Only police may request an escort vehicle.' end
    local rt = firstActiveConvoy()
    if not rt then return false, 'No convoy is currently active.' end

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Player identifier unavailable.' end

    rt.escortVehicles = rt.escortVehicles or {}
    if rt.escortVehicles[identifier] then
        return false, 'You already have an escort vehicle checked out — return it to the ped first.'
    end

    local cap = rt.def.maxEscortVehicles or 0
    if cap > 0 then
        local count = 0
        for _ in pairs(rt.escortVehicles) do count = count + 1 end
        if count >= cap then
            return false, 'This convoy has no more escort vehicles available right now.'
        end
    end

    -- The model, label, price and type always come from Config.EscortVehicleShop.vehicles — the client only says WHICH
    -- entry (by model name or list position), so a modified client cannot ask for an unlisted vehicle or set its own price.
    local model, label, price, vtype = nil, nil, 0, 'automobile'
    local list = (Config.EscortVehicleShop and Config.EscortVehicleShop.vehicles) or {}
    local vDef
    if type(vehicleData) == 'table' and type(vehicleData.model) == 'string' then
        for _, v in ipairs(list) do
            if v.model == vehicleData.model then vDef = v break end
        end
    elseif type(vehicleData) == 'number' then
        vDef = list[vehicleData]
    end
    if vDef then
        model = vDef.model
        label = vDef.label or vDef.model
        price = tonumber(vDef.price) or 0
        vtype = vDef.type or 'automobile'      -- automobile | bike | boat | heli | plane | trailer (an addon bike / helicopter must say so)
    end

    if not model or model == '' then return false, 'That vehicle is not available.' end

    if price > 0 then
        local ok = Bridge.RemoveMoney(source, price, account)
        if not ok then return false, ('Insufficient %s funds ($%d required).'):format(account, price) end
    end

    local ped = GetPlayerPed(source --[[@as string]])
    if not ped or ped == 0 then return false, 'Could not locate you in the world.' end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local spawnX = coords.x + math.cos(rad + math.pi / 2) * 4.0
    local spawnY = coords.y + math.sin(rad + math.pi / 2) * 4.0
    local spawnZ = coords.z

    if type(spot) == 'table' and tonumber(spot.x) and tonumber(spot.y) and tonumber(spot.z) then
        local sx, sy, sz = tonumber(spot.x) + 0.0, tonumber(spot.y) + 0.0, tonumber(spot.z) + 0.0
        local dx, dy = sx - coords.x, sy - coords.y
        if math.sqrt(dx * dx + dy * dy) <= 80.0 and math.abs(sz - coords.z) <= 40.0 then
            spawnX, spawnY, spawnZ, heading = sx, sy, sz, (tonumber(spot.heading) or heading) + 0.0
            -- the player goes to the clear spot with the vehicle (they are seated in it just below)
            SetEntityCoords(ped, sx, sy, sz + 1.0, false, false, false, false)
        end
    end

    local modelHash = type(model) == 'string' and joaat(model) or model
    local veh
    if CreateVehicleServerSetter then
        veh = CreateVehicleServerSetter(modelHash, vtype, spawnX, spawnY, spawnZ, heading)
    end
    -- the typed spawn can be refused (wrong type for an addon model): fall back to the generic one
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        veh = CreateVehicle(modelHash, spawnX, spawnY, spawnZ, heading, true, true)
    end

    if not veh or veh == 0 or not DoesEntityExist(veh) then
        if price > 0 then Bridge.AddMoney(source, price, account) end      -- nothing delivered: give the money back
        return false, 'Failed to spawn escort vehicle in world.'
    end

    local vehNetId = NetworkGetNetworkIdFromEntity(veh)
    TriggerClientEvent('nova_convoytruck:runtime:snapTruckToGround', -1, vehNetId)
    -- Escort vehicles are hardened the way the convoy trucks are: the health the convoy asks for, unpuncturable tyres, a strong body
    -- and an armoured fuel tank (clients re-apply it while they control the vehicle, see 'escort_hardened'). No health bar is shown.
    do
        local hp = tonumber(rt.def.escortVehicleHealth) or tonumber((Config.EscortVehicleShop or {}).health) or 5000.0
        hp = math.max(500.0, hp)
        pcall(SetEntityMaxHealth, veh, math.floor(hp))
        pcall(SetEntityHealth, veh, math.floor(hp))
        pcall(SetVehicleEngineHealth, veh, math.max(1000.0, hp) + 0.0)
        pcall(SetVehiclePetrolTankHealth, veh, math.max(1000.0, hp) + 0.0)
        pcall(SetVehicleTyresCanBurst, veh, false)
        pcall(SetVehicleCanLeakPetrol, veh, false)
        pcall(SetVehicleStrong, veh, true)
        pcall(SetVehicleHasStrongAxles, veh, true)
        pcall(SetVehicleExplodesOnHighExplosionDamage, veh, false)
        pcall(function() Entity(veh).state:set('escort_hardened', math.floor(hp), true) end)
    end
    SetPedIntoVehicle(ped, veh, -1)
    if Bridge.GiveVehicleKeys then
        pcall(Bridge.GiveVehicleKeys, source, veh)
    end

    rt.escortVehicles[identifier] = { vehicle = veh, model = model, label = label, price = price, account = account }
    return true, { label = label }
end

function Runtime.returnEscortVehicle(source)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Player identifier unavailable.' end

    for _, rt in pairs(active) do
        local entry = rt.escortVehicles and rt.escortVehicles[identifier]
        if entry then
            if entry.vehicle and DoesEntityExist(entry.vehicle) then DeleteEntity(entry.vehicle) end
            local refundAmt = entry.price or 0
            if refundAmt > 0 then
                -- Refund to whichever account they actually paid with, not
                -- just whatever the config default happens to be — a bank
                -- purchase refunded to cash (or vice versa) would be a silent
                -- money-moving exploit/bug.
                Bridge.AddMoney(source, refundAmt, entry.account or Config.EscortVehicleShop.moneyAccount or 'cash')
            end
            rt.escortVehicles[identifier] = nil
            return true, refundAmt
        end
    end
    return false, 'You do not have an escort vehicle checked out.'
end

function Runtime.hasEscortVehicle(source)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false end
    for _, rt in pairs(active) do
        if rt.escortVehicles and rt.escortVehicles[identifier] then return true end
    end
    return false
end

function Runtime.isPoliceParticipant(convoyId, source)
    local rt = active[convoyId]
    if not rt then return false end
    local identifier = Bridge.GetIdentifier(source)
    return identifier ~= nil and rt.participants.policeIdentifiers[identifier] ~= nil
end

function Runtime.isParticipant(convoyId, source)
    local rt = active[convoyId]
    if not rt then
        if Tdm and Tdm.isParticipant(convoyId, source) then return true end
        if ContainerWars and ContainerWars.isParticipant(convoyId, source) then return true end
        if TerritoryAuction and TerritoryAuction.isActive(convoyId) then return GangXP.GangOf(source) ~= nil end
        if Crackdown and Crackdown.isActive(convoyId) then return Crackdown.isParticipant(convoyId, source) end
        return false
    end
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false end
    if rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier] ~= nil then return true end
    if rt.def and (rt.def.kind == 'GANG_AIRDROP' or rt.def.kind == 'HOT_CARGO' or rt.def.kind == 'CONTAINER_WARS') and not Bridge.IsPolice(source) then
        local g = GangService and GangService.GetPlayerGang(source)
        if g and g.name then return true end
    end
    return false
end

-- includeGangBreakdown: which gangs (by name/label) are actually registered
-- as participants, and how many members each has joined — deliberately NOT
-- part of the normal payload every player gets (that only ever exposes an
-- anonymous total count, gangParticipants). Gangs seeing who else is running
-- the same convoy would let them quietly coordinate/split territory instead
-- of competing, so only admin/creator-access callers (see getActiveConvoys)
-- ever get this passed as true.
function Runtime.getPublicState(convoyId, includeGangBreakdown)
    local rt = active[convoyId]
    if not rt then
        -- A TDM match or Container Wars event is tracked in its own module
        if Tdm and Tdm.isActive(convoyId) then return Tdm.getPublicState(convoyId) end
        if ContainerWars and ContainerWars.isActive(convoyId) then return ContainerWars.getPublicState(convoyId) end
        if TerritoryAuction and TerritoryAuction.isActive(convoyId) then return TerritoryAuction.getPublicState(convoyId) end
        if Crackdown and Crackdown.isActive(convoyId) then return Crackdown.getPublicState(convoyId) end
        return nil
    end
    local gangCount = 0
    for _ in pairs(rt.participants.identifiers) do gangCount = gangCount + 1 end
    local distinctGangCount = 0
    for _ in pairs(rt.participants.gangCounts) do distinctGangCount = distinctGangCount + 1 end
    local policeEscortCount = 0
    for _ in pairs(rt.participants.policeIdentifiers) do policeEscortCount = policeEscortCount + 1 end
    local isRace = rt.def.kind == 'GANG_RACE'
    local totalPoints = isRace and #(rt.stages or {}) or #rt.route
    local currentPt = isRace and 1 or rt.currentRouteIndex
    if isRace and rt.racers then
        local maxCp = 1
        for _, r in pairs(rt.racers) do
            if (r.currentStage or 1) > maxCp then maxCp = r.currentStage end
        end
        currentPt = math.min(totalPoints, maxCp)
    end

    local state = {
        id = rt.id, name = rt.def.name, status = rt.status, kind = rt.def.kind,
        cargo = rt.def.cargo, reward = rt.def.reward,
        currentRouteIndex = currentPt, totalRoutePoints = totalPoints,
        checkpointTimeRemaining = rt.checkpointTimeRemaining or 0, deliveryTimeRemaining = rt.deliveryTimeRemaining,
        policeParticipants = isRace and 0 or #policeSources(), gangParticipants = gangCount,
        maxGangParticipants = rt.def.maxGangParticipants, gangPvp = rt.def.settings and rt.def.settings.gangPvp,
        distinctGangs = distinctGangCount, maxGangs = rt.def.settings and rt.def.settings.maxGangs,
        joinedPoliceEscorts = policeEscortCount, maxPoliceParticipants = rt.def.maxPoliceParticipants,
    }
    if includeGangBreakdown then
        local labelByName = {}
        for _, g in ipairs(GangService.GetGangs()) do labelByName[g.name] = g.label end
        local membersByGang = {}
        for identifier, gangName in pairs(rt.participants.identifiers) do
            membersByGang[gangName] = membersByGang[gangName] or {}
            table.insert(membersByGang[gangName], { identifier = identifier, name = rt.participants.names[identifier] or identifier })
        end
        local breakdown = {}
        for name, count in pairs(rt.participants.gangCounts) do
            breakdown[#breakdown + 1] = { name = name, label = labelByName[name] or name, count = count, members = membersByGang[name] or {} }
        end
        state.gangBreakdown = breakdown

        -- Same admin-only visibility rule as the gang breakdown above —
        -- individual officer names, not just the count everyone else gets.
        local escorts = {}
        for identifier in pairs(rt.participants.policeIdentifiers) do
            escorts[#escorts + 1] = { identifier = identifier, name = rt.participants.names[identifier] or identifier }
        end
        state.policeEscorts = escorts
    end
    return state
end

-- TDM matches live in their own runtime module (tdm_runtime.lua), entirely
-- separate from this file's own `active` table — checked here too so
-- deleteConvoy's safety gate and the live-panel's active list both still see
-- a running TDM match instead of treating it as not-active.
function Runtime.isActive(convoyId)
    return active[convoyId] ~= nil or (Tdm and Tdm.isActive(convoyId)) or (ContainerWars and ContainerWars.isActive(convoyId))
        or (TerritoryAuction and TerritoryAuction.isActive(convoyId)) or (Crackdown and Crackdown.isActive(convoyId)) or false
end

-- Same "is anything live right now" check firstActiveConvoy() (above) uses
-- internally for the escort vehicle shop — exported so other modules (the
-- police equipment vendor) can gate on it too without duplicating the loop.
function Runtime.hasActiveConvoy()
    return firstActiveConvoy() ~= nil
end

function Runtime.getActive()
    local list = {}
    for id in pairs(active) do list[#list + 1] = id end
    if Tdm then
        for _, id in ipairs(Tdm.getActiveIds()) do list[#list + 1] = id end
    end
    if ContainerWars then
        for _, id in ipairs(ContainerWars.getActiveIds()) do list[#list + 1] = id end
    end
    if TerritoryAuction then
        for _, id in ipairs(TerritoryAuction.getActiveIds()) do list[#list + 1] = id end
    end
    if Crackdown then
        for _, id in ipairs(Crackdown.getActiveIds()) do list[#list + 1] = id end
    end
    return list
end

-- ── recovery on resource start ────────────────────────────────────────────────────
-- Vehicle entities don't survive a resource restart, so recovery respawns
-- surviving trucks at the START point and resumes from the same route index —
-- not a pixel-perfect resume, but the event and its participants persist
-- instead of silently vanishing.

function Runtime.recoverAll()
    for _, saved in ipairs(DB.getActiveRuntimes()) do
        local def = ConvoyManager.get(saved.convoyId)
        local recovered = false
        if def and saved.status ~= 'COMPLETED' and saved.status ~= 'CAPTURED' and saved.status ~= 'FAILED' and saved.status ~= 'CANCELLED' then
            local route, airdropPoints = splitRoute(sortedRoute(def))
            local startPoint = findPoint(route, 'START')
            local destPoint = findPoint(route, 'DESTINATION')
            if startPoint and destPoint then
                local rt = {
                    id = saved.convoyId, def = def, route = route, status = 'ACTIVE',
                    airdropPoints = airdropPoints, airdropsTriggered = saved.state.airdropsTriggered or {},
                    lastReachedOrder = saved.state.lastReachedOrder,
                    currentRouteIndex = math.min(saved.state.currentRouteIndex or 1, #route),
                    checkpointTimeRemaining = 0, pointInProgress = false,
                    deliveryTimeRemaining = saved.state.deliveryTimeRemaining or def.eventDuration or 1200,
                    trucks = {}, startedAt = saved.state.startedAt or os.time(),
                    participants = {
                        identifiers = saved.state.participantIdentifiers or {},
                        gangCounts = saved.state.gangCounts or {},
                        policeIdentifiers = saved.state.policeIdentifiers or {},
                        names = saved.state.participantNames or {},
                    },
                    -- A recovered convoy is by definition already past its
                    -- start grace period (it was already running before the
                    -- restart) — never re-hide truck blips from gangs who
                    -- could already see them, and never re-park trucks that
                    -- were already released and moving.
                    gangVisibilityUnlocked = true,
                    releaseHeld = false,
                }
                -- Same convoyIndex/totalConvoyTrucks counting doStart does (see its
                -- own truck-spawn loop above) — this was missing here entirely, so
                -- spawnTruck always got called with index defaulting to 1, meaning
                -- EVERY recovered truck spawned at the exact same spot (distance 0)
                -- right on top of each other at the START point. That pile-up is
                -- almost certainly what "trucks all messed up / overlapping / spinning
                -- stuck / shoved off-road" after a mid-convoy resource restart was —
                -- several 12m rigs materializing in the identical spot shove each
                -- other around on spawn, before they've even started driving.
                local totalConvoyTrucks = 0
                for _, truckDef in ipairs(def.trucks) do
                    if truckDef.role ~= 'ESCORT' then totalConvoyTrucks = totalConvoyTrucks + 1 end
                end

                local convoyIndex = 0
                for _, truckDef in ipairs(def.trucks) do
                    if truckDef.role ~= 'ESCORT' then
                        local savedTruck = saved.state.trucks and saved.state.trucks[truckDef.id]
                        if not savedTruck or (not savedTruck.delivered and not savedTruck.destroyed and not savedTruck.captured) then
                            convoyIndex = convoyIndex + 1
                            local truck = spawnTruck(startPoint, truckDef, convoyIndex, totalConvoyTrucks, rt.id)
                            if truck then
                                rt.trucks[truckDef.id] = truck
                                truck.drivingToIndex = rt.currentRouteIndex
                                driveTruckTo(truck, resolveDriveTarget(rt, rt.currentRouteIndex) or destPoint)
                            end
                            Wait(500) -- match doStart's spacing so entities/drivers fully settle before the next spawn
                        elseif savedTruck then
                            rt.trucks[truckDef.id] = { id = truckDef.id, role = truckDef.role, state = savedTruck.state, delivered = savedTruck.delivered, destroyed = savedTruck.destroyed, captured = savedTruck.captured }
                        end
                    end
                end
                active[saved.convoyId] = rt
                persist(rt)
                monitor(rt)
                recovered = true
                print(('[NovaConvoy] Recovered convoy #%d after restart (resuming at route point %d).'):format(saved.convoyId, rt.currentRouteIndex))
            end
        end
        if not recovered then
            DB.deleteRuntime(saved.convoyId)
            if def and (def.status == 'ACTIVE' or def.status == 'CHECKPOINT' or def.status == 'UNDER_ATTACK' or def.status == 'DELIVERY') then
                ConvoyManager.setStatus(saved.convoyId, 'CANCELLED')
            end
        end
    end

    -- Reconcile any orphaned definitions stuck in active status without a live in-memory runtime
    for _, def in ipairs(ConvoyManager.getAll()) do
        if (def.status == 'ACTIVE' or def.status == 'CHECKPOINT' or def.status == 'UNDER_ATTACK' or def.status == 'DELIVERY') and not active[def.id] then
            print(('[NovaConvoy] Reconciling orphaned active convoy #%d ("%s") -> CANCELLED'):format(def.id, def.name))
            ConvoyManager.setStatus(def.id, 'CANCELLED')
            DB.deleteRuntime(def.id)
        end
    end
end

-- Reconnecting players are matched back into any convoy they were part of by
-- identifier, not by session — a crash/relog/server restart doesn't drop
-- their participation. Re-applies BOTH the NPC-hostile tag (gang side) and
-- the force-drive-by flag (gang or police side) — this used to only restore
-- the hostile tag, so a reconnecting participant would keep their
-- participant-list membership but silently lose drive-by until they left and
-- rejoined the convoy again.
-- A player logging out of a character (multichar: gang character -> EMS / police character) keeps the same server id, so the
-- per-ped state of the OLD character must not follow them: the hostile-to-NPC-police group, the forced drive-by and any
-- open panel. Membership of the old character stays in the event (it is stored by citizen id and comes back with them).
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if not src then return end
    pcall(NpcManager.setPlayerHostile, src, false)
    TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, src, 'PLAYER')
    TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', src, false)
    TriggerClientEvent('nova_convoytruck:runtime:hideAll', src)
    TriggerClientEvent('nova_convoytruck:client:characterUnloaded', src)
end)

Bridge.OnPlayerLoaded(function(source)
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return end
    for convoyId, rt in pairs(active) do
        local driveByOn = rt.def.kind ~= 'GANG_AIRDROP' and rt.def.settings.forceDriveBy ~= false
        if rt.participants.identifiers[identifier] then
            NpcManager.setPlayerHostile(source, true)
            if driveByOn then TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, true) end
        end
        if rt.participants.policeIdentifiers[identifier] and driveByOn then
            TriggerClientEvent('nova_convoytruck:runtime:setDriveBy', source, true)
        end
    end
end)

-- Entities aren't auto-deleted when a resource stops — clean up everything we
-- spawned so a restart doesn't leave orphaned trucks/NPCs behind. The DB
-- runtime row is left intact on purpose: Runtime.recoverAll() reads it back
-- on the next start to resume the convoy instead of losing it.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for convoyId, rt in pairs(active) do
        -- pcall per-convoy: entities aren't auto-cleaned on resource stop
        -- (see comment above), so THIS loop is the only thing standing
        -- between a restart and orphaned trucks/driver corpses left
        -- littering the map. An error partway through any one convoy's
        -- cleanup (e.g. a stale/invalid entity reference) used to abort the
        -- whole handler — every convoy after the broken one in iteration
        -- order, and every cleanup step after the one that threw, never ran
        -- at all. That's almost certainly the exact mechanism behind past
        -- reports of a dead NPC left lying under a convoy truck after a
        -- restart — it wasn't a live spawn bug, it was leftover residue
        -- from a prior restart's cleanup dying halfway through.
        local ok, err = pcall(function()
            for _, t in pairs(rt.trucks) do
                if t.entity and DoesEntityExist(t.entity) then DeleteEntity(t.entity) end
                if t.driverPed and DoesEntityExist(t.driverPed) then DeleteEntity(t.driverPed) end
                if t.propEntity and DoesEntityExist(t.propEntity) then DeleteEntity(t.propEntity) end
            end
            if rt.activeCheckpointNpcs then NpcManager.cleanup(rt.activeCheckpointNpcs) end
            if rt.activeRouteNpcs then NpcManager.cleanup(rt.activeRouteNpcs) end
            if rt.activeAmbushNpcs then NpcManager.cleanup(rt.activeAmbushNpcs) end
            for _, obj in ipairs(rt.activeCheckpointBarricades or {}) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
            for _, veh in ipairs(rt.activeCheckpointVehicles or {}) do if DoesEntityExist(veh) then DeleteEntity(veh) end end
            -- Same lookahead-pre-spawn sweep as Runtime.finish above — entities
            -- aren't auto-deleted on resource stop, and a pre-spawned-but-not-
            -- yet-reached checkpoint's props/vehicles/NPCs only live in here.
            for _, dressing in pairs(rt.checkpointDressing or {}) do
                NpcManager.cleanup(dressing.npcs)
                for _, obj in ipairs(dressing.barricades or {}) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
                for _, veh in ipairs(dressing.vehicles or {}) do if DoesEntityExist(veh) then DeleteEntity(veh) end end
            end
            for _, entry in pairs(rt.airdrops or {}) do cleanupAirdrop(rt, entry) end
            for _, entry in pairs(rt.escortVehicles or {}) do
                if entry.vehicle and DoesEntityExist(entry.vehicle) then DeleteEntity(entry.vehicle) end
            end
            if rt.dropoffGuards then
                for _, guardList in pairs(rt.dropoffGuards) do
                    NpcManager.cleanup(guardList)
                end
            end
        end)
        if not ok then
            print(('[NovaConvoy] onResourceStop cleanup error for convoy #%s: %s'):format(tostring(convoyId), tostring(err)))
        end
    end
    active = {}
    -- Entities outlive a resource restart, so everything the resource placed goes now, tracked or not (placed props and
    -- decoration cars carry nova_prop_solid / nova_event_obj; a spawn still in flight is caught by the startup sweep).
    for _, getter in ipairs({ GetAllVehicles, GetAllObjects }) do
        local okL, list = pcall(getter)
        if okL and type(list) == 'table' then
            for _, e in ipairs(list) do
                if DoesEntityExist(e) then
                    local okS, st = pcall(function() return Entity(e).state end)
                    if okS and st and (st.nova_event_obj ~= nil or st.nova_prop_solid ~= nil) and st.convoy_keep ~= true then
                        pcall(DeleteEntity, e)
                    end
                end
            end
        end
    end
end)

-- Belt-and-braces sweep, independent of any in-memory/DB bookkeeping.
-- Crate props (spawnParachutingCrate/spawnAirdropZone) and guard peds
-- (NpcManager.spawnAmbushers) are both explicitly marked as mission
-- entities via SetEntityAsMissionEntity(..., true, true) — that's exactly
-- what stops FiveM auto-deleting them as ordinary script entities when the
-- resource restarts, since other clients need to keep seeing them
-- reliably. The onResourceStop handler above is the primary cleanup path
-- for a normal restart, but a hard crash (no graceful stop firing at all)
-- or an error partway through that handler's own per-convoy pcall can
-- still leave one behind with nothing left anywhere in Lua state pointing
-- back to it — a crate or a guard corpse that no amount of normal gameplay
-- will ever remove. This runs on every start and deletes anything still
-- carrying this resource's own airdrop/ambush state bag tags (set at spawn
-- time in spawnAirdropZone and NpcManager.spawnAmbushers), purely from
-- what's physically still in the world — it doesn't depend on any convoy
-- or runtime record surviving to "remember" the entity at all.
-- Called from main.lua's startup sequence right BEFORE Runtime.recoverAll(), so the trucks that
-- recovery respawns are never mistaken for leftovers.
function Runtime.sweepOrphans()
    do
        -- GetGamePool is a CLIENT native — the server enumerates with GetAllObjects / GetAllPeds / GetAllVehicles
        -- (the old GetGamePool calls here threw on the server, so this sweep never actually ran).
        -- Everything the resource tagged with a convoy id (trucks, trailers, loot crates incl. a Hot Cargo
        -- reward crate whose 60-minute timer died with the restart, guards) goes too.
        local removed = 0
        local function sweep(getter, isPed)
            local okList, list = pcall(getter)
            if not okList or type(list) ~= 'table' then return end
            for _, e in ipairs(list) do
                if DoesEntityExist(e) and not (isPed and IsPedAPlayer and IsPedAPlayer(e)) then
                    local ok, st = pcall(function() return Entity(e).state end)
                    if ok and st and (st.convoy_airdrop or st.convoy_ambush_ped or st.convoy_id ~= nil or st.convoy_truck
                        -- placed props / decoration cars: tagged nova_event_obj when tracked, and every one of them carries
                        -- nova_prop_solid, so a car an older run created and lost track of is found too
                        or st.nova_event_obj ~= nil or st.nova_prop_solid ~= nil) then
                        DeleteEntity(e)
                        removed = removed + 1
                    end
                end
            end
        end
        sweep(GetAllObjects, false)
        sweep(GetAllVehicles, false)
        sweep(GetAllPeds, true)
        if removed > 0 then
            print(('[NovaConvoy] Startup sweep: removed %d orphaned convoy entity(ies) (trucks, crates, guards) left over from a prior crash or interrupted restart.'):format(removed))
        end
    end
end

return Runtime
