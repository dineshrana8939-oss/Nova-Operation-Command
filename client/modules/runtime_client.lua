-- ─── Nova Convoy — Live Runtime (client) ──────────────────────────────────────
-- Mirrors the visual/interaction patterns already proven in client/main.lua for
-- the legacy convoy, but under new event names (nova_convoytruck:runtime:*) so
-- this system never collides with the legacy one. Purely presentational —
-- every action that matters (delivery, join/leave) round-trips to the server.

local movingBlips = {}
local checkpointBlip, checkpointRadiusBlip = nil, nil
local dropZones = {}
local dropBlips = {}
local dropTrucks = {}
local cachedDestCoords = nil
local ensureDeliveryDropZone
local airdropBlips = {}
local airdropRadiusBlips = {} -- pointId -> "hunting circle" radius blip, paired with airdropBlips
local airdropPlaneBlips = {} -- netId -> blip handle (the moving supply plane, see airdropPlaneSpawn)
local airdropSmokeFx = {}
local airdropLandedFlareFx = {} -- pointId -> list of looped particle-fx handles (see stopAirdropLandedFlares)
local airdropMarkers = {} -- pointId -> { entity, label, endAt } — the floating AIRDROP UI over a landed crate (see registerAirdropMarker)
local npcBlips = {}
local policeZoneBlips = {} -- police-only "full route overview" markers (Config.PoliceAlwaysSeeRouteZones)
local policeZoneRadiusBlips = {} -- paired checkpoint radius circles for the overview above
local policeCheckpointBlips = {} -- { x, y, blip } of each checkpoint in that overview, so the active-checkpoint blip can reuse it
local stagingBlip, stagingRadiusBlip = nil, nil    -- convoy spawn zone circle
local hcZoneBlips = {}   -- Hot Cargo search circles: truckId -> { radius = blip, centre = blip }
local hcDestBlips = {}   -- Hot Cargo destination (hijacking gang only): truckNetId -> { blip, radius }
local hotCargoTargets = {} -- netId -> true, so a second broadcast doesn't double-add the hijack option
local TGT = exports.ox_target

-- Safe replacements for the engine's own NetToVeh/NetToPed convenience
-- globals — a netId for an entity that no longer resolves on this client
-- (already despawned, or from a convoy that ended across a resource
-- restart before it got pruned) makes those throw "bad argument #2 to
-- 'tonumber' (base out of range)" instead of just returning 0, which used
-- to kill whole handlers partway through a loop over several trucks. Every
-- call site below goes through these instead of the raw globals.
local function safeNetToVeh(netId)
    if not netId then return 0 end
    local ok, veh = pcall(NetToVeh, netId)
    return (ok and veh) or 0
end
local function safeNetToPed(netId)
    if not netId then return 0 end
    local ok, ped = pcall(NetToPed, netId)
    return (ok and ped) or 0
end

-- netId -> { label, healthPct } — floating name + health bar drawn above
-- each convoy truck (see drawTruckLabels below), fed by the same
-- updateBlips broadcast that already drives the map blips, so it inherits
-- that event's exact audience rule for free: police always, gang
-- participants only once gangVisibilityUnlocked flips true server-side
-- (i.e. once the police head-start buffer ends and the trucks actually
-- start moving) — never shown to anyone before that, and never to anyone
-- outside the convoy's own audience.
local truckLabels = {}
local truckLabelThreadRunning = false

-- Set by the server (server/modules/activity.lua) while ANY event is running. The watchers below read it so that, with nothing
-- running, they sleep for seconds and never scan the vehicle pool (the server idle cost of this resource stays at 0.00 ms).
local function eventsActive() return GlobalState.novaEventsActive == true end

-- Overhead truck health is drawn by the NUI (TruckOverheadHealth.svelte), not
-- with DrawRect/DrawText: this thread only projects each truck to a normalised
-- 0..1 screen point and ships the whole batch in one message. A message is
-- only sent when something visibly changed (or to clear the list once), so
-- idle/standing trucks cost nothing per frame.
local lastOverheadSig = ''

-- Truck condition 0-100: the LOWER of the body health and the engine health (bullets mostly drain the engine, and at 0 it is
-- disabled), read live from the entity so every hit shows (99, 98, 97 ...). The engine's full value is the highest reading seen for
-- this vehicle, never below a stock 1000.
local engineSeen = {}
local function truckHealthPct(veh, fallback)
    local liveH = GetEntityHealth(veh)
    local maxH = Entity(veh).state.maxHealth or GetEntityMaxHealth(veh) or 1000
    local body = 1.0
    if maxH > 100 and liveH then
        body = math.max(0.0, math.min(1.0, liveH / maxH))
    elseif fallback then
        body = fallback / 100.0
    end
    local eng = GetVehicleEngineHealth(veh)
    local seen = math.max(engineSeen[veh] or 0.0, eng)
    engineSeen[veh] = seen
    local engPct = math.max(0.0, math.min(1.0, eng / math.max(seen, 1000.0)))
    return math.min(body, engPct) * 100.0
end

-- The number shown follows the real health at a fixed speed instead of jumping to it, so a truck being shot counts down 99, 98, 97 ...
-- (and a disabled truck runs down to 0) rather than dropping in lumps.
local shownPct = {}
local function smoothPct(veh, target)
    local speed = tonumber(Config.TruckHealthBarSpeed) or 30.0
    local now = GetGameTimer()
    local s = shownPct[veh]
    if not s or speed <= 0.0 then
        s = { v = target, t = now }
        shownPct[veh] = s
        return target
    end
    local dt = math.min(1.0, (now - s.t) / 1000.0)
    s.t = now
    local step = speed * dt
    local diff = target - s.v
    if diff > step then diff = step elseif diff < -step then diff = -step end
    s.v = s.v + diff
    return s.v
end

local function pushOverhead(list)
    local parts = {}
    for i = 1, #list do
        local t = list[i]
        parts[i] = string.format('%d:%.4f:%.4f:%d:%.2f:%d', t.id, t.x, t.y, t.pct, t.s, t.broken and 1 or 0)
    end
    local sig = table.concat(parts, '|')
    if sig == lastOverheadSig then return end
    lastOverheadSig = sig
    SendNUIMessage({ action = 'truckOverheadHealth', trucks = list })
end

-- Persistent low-tick proximity thread that auto-adapts sleep:
-- 1000ms when away from convoy trucks, 0ms when within 45m of any truck.
local function ensureTruckLabelThread()
    if truckLabelThreadRunning then return end
    truckLabelThreadRunning = true
    CreateThread(function()
        while true do
            local sleep = 1000
            local ped = cache.ped or PlayerPedId()
            if not next(truckLabels) and not eventsActive() then
                -- no event running and no truck tracked: nothing to draw and no vehicle-pool scan
                pushOverhead({})
                sleep = 3000
            elseif ped and ped ~= 0 and DoesEntityExist(ped) then
                local playerCoords = GetEntityCoords(ped)
                local trucksToRender = {}

                -- 1. Explicitly tracked trucks from updateBlips
                for netId, data in pairs(truckLabels) do
                    local veh = safeNetToVeh(netId)
                    -- Network ids are recycled: the id of a truck that is gone can belong to an airdrop guard ped by now, and a stale
                    -- label then drew a truck health bar over that ped's head. Only a real convoy / Hot Cargo vehicle gets one.
                    if veh ~= 0 and DoesEntityExist(veh) and IsEntityAVehicle(veh)
                        and (Entity(veh).state.convoy_truck or Entity(veh).state.hot_cargo_truck) then
                        trucksToRender[veh] = data
                    end
                end

                -- 2. Any nearby convoy trucks discovered via statebag
                local labelRange = tonumber(Config.TruckLabelRange) or 90.0   -- the health bar shows from this far, so shooting a truck from a distance still moves it
                local pool = GetGamePool('CVehicle')
                for _, veh in ipairs(pool) do
                    -- distance first: reading a state bag for every vehicle on the map is the expensive part
                    if DoesEntityExist(veh) and #(playerCoords - GetEntityCoords(veh)) <= labelRange + 15.0 and Entity(veh).state.convoy_truck then
                        if not trucksToRender[veh] then
                            trucksToRender[veh] = {
                                label = Entity(veh).state.convoy_truck_label or 'Convoy Truck',
                                healthPct = nil,
                            }
                        end
                    end
                end

                local overhead = {}
                for veh, data in pairs(trucksToRender) do
                    local coords = GetEntityCoords(veh)
                    local dist = #(playerCoords - coords)
                    if dist <= labelRange then
                        sleep = 0
                        local stNow = Entity(veh).state
                        local isBroken = stNow.hot_cargo_broken == true or stNow.convoy_truck_broken == true
                        local hPct = smoothPct(veh, isBroken and 0.0 or truckHealthPct(veh, data.healthPct))

                        local maxDim = nil
                        if DoesEntityExist(veh) then
                            local _, md = GetModelDimensions(NovaConvoy.SafeEntityModel(veh))
                            maxDim = md
                        end
                        local zOffset = (maxDim and maxDim.z or 1.5) + 0.65
                        local onScreen, sx, sy = World3dToScreen2d(coords.x, coords.y, coords.z + zOffset)
                        if onScreen then
                            local st = Entity(veh).state
                            overhead[#overhead + 1] = {
                                id = veh,
                                x = sx, y = sy,
                                label = data.label or 'Convoy Truck',
                                pct = math.ceil(hPct - 0.01),   -- full health shows 100 (not 99 from a point of settling damage) and counts down from there
                                -- Hot Cargo rigs carry their own event colour; everything else here is a convoy truck.
                                kind = st.hot_cargo_truck and 'hotcargo' or 'convoy',
                                broken = st.hot_cargo_broken == true or st.convoy_truck_broken == true,
                                -- shrink gently with distance (1.0 up close -> 0.7 at the 45m cut-off)
                                s = math.max(0.7, math.min(1.0, 1.0 - ((dist - 15.0) / math.max(labelRange - 15.0, 1.0)) * 0.3)),
                            }
                        end
                    end
                end
                table.sort(overhead, function(l, r) return l.id < r.id end)
                pushOverhead(overhead)
            else
                pushOverhead({})
            end
            Wait(sleep)
        end
    end)
end

-- Kick off the proximity thread at resource start
CreateThread(function()
    ensureTruckLabelThread()
end)

-- PUBG-style red smoke marking exactly where an airdrop crate landed — a
-- looped particle effect tinted via SetParticleFxLoopedColour (GTA's stock
-- smoke assets aren't red by default). Purely visual; always safe to call
-- even if nothing was ever started for this pointId. Declared up here (not
-- inline in the "airdrop" section below) since hideAll/onResourceStop, both
-- defined earlier in this file, also need to reach it.
local function stopAirdropSmoke(pointId)
    local fx = airdropSmokeFx[pointId]
    if fx then
        StopParticleFxLooped(fx, false)
        airdropSmokeFx[pointId] = nil
    end
end

-- The four colour-coded ground flares ringing a LANDED crate (see
-- runLootCrateFlareBeacon below) — same "always safe to call" contract as
-- stopAirdropSmoke above, and swept from the same cleanup call sites.
local function stopAirdropLandedFlares(pointId)
    local list = airdropLandedFlareFx[pointId]
    if list then
        for _, fx in ipairs(list) do
            pcall(StopParticleFxLooped, fx, false)
        end
        airdropLandedFlareFx[pointId] = nil
    end
end

-- ── Teardown helpers used by hideAll (force-end / natural end / stop) ──────────
-- These are declared here, above hideAll, on purpose: hideAll is defined
-- earlier in the file than the airdrop/crate sections that own the tables
-- these sweep, and a `local function` further down would not be in scope at
-- the point hideAll actually runs.

-- Purely-local cosmetic descent copies (crate + chute) spawned by
-- airdropDescent. The server has no handle on these at all — they're local
-- objects each client animates itself — so if the event is force-ended
-- mid-descent, nothing server-side can delete them and they'd keep falling
-- (or hang) until their own timer eventually expired. Registering them lets
-- hideAll delete them immediately.
airdropDescentCopies = airdropDescentCopies or {}
local function cleanupAirdropDescentCopies()
    for _, ent in ipairs(airdropDescentCopies) do
        if ent and ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    airdropDescentCopies = {}
end

-- ox_target options registered on airdrop crates. Removing the crate entity
-- does NOT remove its ox_target entry in every case (the option can outlive a
-- force-ended event as a prompt floating over nothing), so hideAll clears
-- them explicitly. Guarded: TGT is an export, and this must never be the
-- reason a cleanup fails.
local function cleanupAirdropTargets()
    for entity, key in pairs(airdropTargetEntities or {}) do
        pcall(NovaConvoy.RemoveEntityTarget, entity, type(key) == 'number' and key or nil)
    end
    airdropTargetEntities = {}
end

local function cleanupTruckLootTargets()
    for entity, key in pairs(truckLootTargetEntities or {}) do
        pcall(NovaConvoy.RemoveEntityTarget, entity, type(key) == 'number' and key or nil)
    end
    truckLootTargetEntities = {}
end

-- Registry tables for the two cleanup helpers above. Declared here (not at
-- their use sites) so hideAll can reach them regardless of definition order;
-- the handlers that populate them assign into these same tables.
airdropTargetEntities = airdropTargetEntities or {}
truckLootTargetEntities = truckLootTargetEntities or {}

-- Forward declaration for the client-flown supply plane's teardown. The real
-- implementation lives with the plane-hosting callback further down this file
-- (that's where its local entity handles are declared), but hideAll needs to
-- call it and hideAll is defined first. Assigned where the plane code is;
-- calling it before that point is a no-op, which is correct (there is no
-- plane to tear down before the plane code has even loaded).
cleanupFlightPlane = function() end

-- ── Blip sprite + colour definitions ─────────────────────────────────────────
-- All values are read from Config.MapBlips (config/config.lua) so server admins
-- can tune every sprite, colour, scale and flash setting without touching this file.
-- Fallback literals below only fire if Config.MapBlips is missing a key entirely
-- (e.g. upgrading from an old config that doesn't have the block yet).
--
-- Colour quick-reference (SetBlipColour):
--   0=White  1=Red  2=Green  3=Blue  5=Yellow  25=DarkBlue  27=Orange  38=Purple
-- Sprite quick-reference: https://docs.fivem.net/docs/game-references/blips/

local MB = Config.MapBlips or {}   -- shorthand; safe if whole block is absent

-- NPC blip style lookup: kind string → { sprite, colour, label, flash }
-- Built at load time from config so the event handlers don't need to
-- repeatedly index Config.MapBlips themselves.
local NPC_BLIP_SPRITE = {
    police = {
        sprite = (MB.npcPolice and MB.npcPolice.sprite) or 272,
        colour = (MB.npcPolice and MB.npcPolice.colour) or 3,
        scale  = (MB.npcPolice and MB.npcPolice.scale)  or 0.85,
        label  = (MB.npcPolice and MB.npcPolice.label)  or 'NPC Police Support',
        flash  = (MB.npcPolice and MB.npcPolice.flash)  or false,
    },
    army = {
        sprite = (MB.npcArmy and MB.npcArmy.sprite) or 421,
        colour = (MB.npcArmy and MB.npcArmy.colour) or 25,
        scale  = (MB.npcArmy and MB.npcArmy.scale)  or 0.85,
        label  = (MB.npcArmy and MB.npcArmy.label)  or 'NPC Army Escort',
        flash  = (MB.npcArmy and MB.npcArmy.flash)  or false,
    },
    ambush = {
        sprite = (MB.npcAmbush and MB.npcAmbush.sprite) or 84,
        colour = (MB.npcAmbush and MB.npcAmbush.colour) or 1,
        scale  = (MB.npcAmbush and MB.npcAmbush.scale)  or 0.85,
        label  = (MB.npcAmbush and MB.npcAmbush.label)  or 'Ambush — Hostiles',
        flash  = (MB.npcAmbush and MB.npcAmbush.flash)  or true,
    },
    airdrop_guard = {
        sprite = (MB.npcAirdropGuard and MB.npcAirdropGuard.sprite) or 84,
        colour = (MB.npcAirdropGuard and MB.npcAirdropGuard.colour) or 1,
        scale  = (MB.npcAirdropGuard and MB.npcAirdropGuard.scale)  or 0.7,
        label  = (MB.npcAirdropGuard and MB.npcAirdropGuard.label)  or 'Airdrop Guard',
        flash  = (MB.npcAirdropGuard and MB.npcAirdropGuard.flash)  or false,
    },
    hotcargo_guard = {
        sprite = (MB.npcHotCargoGuard and MB.npcHotCargoGuard.sprite) or 1,
        colour = (MB.npcHotCargoGuard and MB.npcHotCargoGuard.colour) or 27,
        scale  = (MB.npcHotCargoGuard and MB.npcHotCargoGuard.scale)  or 0.85,
        label  = (MB.npcHotCargoGuard and MB.npcHotCargoGuard.label)  or 'Hot Cargo Guards',
        flash  = (MB.npcHotCargoGuard and MB.npcHotCargoGuard.flash)  or true,
    },
}

local function notify(message, type)
    lib.notify({ title = (Config.Branding and Config.Branding.tabletTitle) or 'Operations Hub', description = message, type = type or 'info' })
end

-- ── pre-start countdown (police-facing "get ready") ───────────────────────────────

RegisterNetEvent('nova_convoytruck:runtime:startPrepCountdown', function(seconds)
    ConvoyUI.startPrepCountdown(seconds)
end)

-- ── relationship group tagging ────────────────────────────────────────────────────

RegisterNetEvent('nova_convoytruck:runtime:setRelationshipGroup', function(groupName)
    SetPedRelationshipGroupHash(cache.ped, groupName and joaat(groupName) or joaat('PLAYER'))
    if not groupName then
        SendNUIMessage({ action = 'gangSquadHide' })
    end
end)

-- ── gang member live HP status ───────────────────────────────────────────────────

RegisterNetEvent('nova_convoytruck:runtime:gangStatus', function(roster, identity)
    SendNUIMessage({ action = 'gangSquadUpdate', roster = roster, gang = identity })
end)

-- ── police squad live HP status ──────────────────────────────────────────────────

-- ── convoy progress card (trucks delivered / checkpoints cleared, top-left) ──────────

RegisterNetEvent('nova_convoytruck:runtime:convoyProgress', function(p)
    if type(p) ~= 'table' then return end
    SendNUIMessage({ action = 'convoyProgress', delivered = p.delivered, totalTrucks = p.totalTrucks, checkpointsDone = p.checkpointsDone, checkpointsTotal = p.checkpointsTotal, routeDone = p.routeDone, routeTotal = p.routeTotal, stages = p.stages, waitingPolice = p.waitingPolice })
end)

RegisterNetEvent('nova_convoytruck:runtime:policeStatus', function(roster)
    SendNUIMessage({ action = 'policeSquadUpdate', roster = roster })
end)

-- ── moving truck blips ── read from Config.MapBlips.convoyTruck ──────────────
-- Every appearance detail (sprite, colour, flash, scale) comes from config so
-- server admins can tune it without touching this file. Fallbacks ensure the
-- blip still works on old configs that predate the MapBlips block.

RegisterNetEvent('nova_convoytruck:runtime:updateBlips', function(vehicleData)
    local cfg = MB.convoyTruck or {}
    local activeIds = {}
    for _, data in ipairs(vehicleData or {}) do
        activeIds[data.netId] = true
        local isBroken = data.disabled or (data.state == 'DISABLED') or (data.healthPct and data.healthPct <= 0)
        local blipName = isBroken and ((data.label or 'Convoy Truck') .. ' (Disabled)') or (data.label or cfg.label or 'Convoy Truck')
        local blipColor = isBroken and 2 or (cfg.colour or 1) -- 2 = Green in GTA blip palette
        if movingBlips[data.netId] then
            local blip = movingBlips[data.netId]
            SetBlipCoords(blip, data.coords.x, data.coords.y, data.coords.z)
            SetBlipColour(blip, blipColor)
            if isBroken then
                SetBlipFlashes(blip, false)
            elseif cfg.flash ~= false then
                SetBlipFlashes(blip, true)
            end
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(blipName)
            EndTextCommandSetBlipName(blip)
        else
            local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
            SetBlipSprite(blip, cfg.sprite or 477)
            SetBlipColour(blip, blipColor)
            SetBlipScale(blip, cfg.scale or 1.3)
            SetBlipDisplay(blip, 2)
            SetBlipPriority(blip, cfg.priority or 11)
            SetBlipAsShortRange(blip, false)
            if not isBroken and cfg.flash ~= false then
                SetBlipFlashes(blip, true)
                SetBlipFlashTimer(blip, cfg.flashTimer or 500)
                SetBlipSecondaryColour(blip, cfg.flashColour or 38)
            else
                SetBlipFlashes(blip, false)
            end
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(blipName)
            EndTextCommandSetBlipName(blip)
            movingBlips[data.netId] = blip
        end
    end
    for netId, blip in pairs(movingBlips) do
        if not activeIds[netId] then
            RemoveBlip(blip)
            movingBlips[netId] = nil
        end
    end

    truckLabels = {}
    for _, data in ipairs(vehicleData or {}) do
        if data.label then truckLabels[data.netId] = { label = data.label, healthPct = data.healthPct } end
        local veh = safeNetToVeh(data.netId)
        if veh ~= 0 and DoesEntityExist(veh) then
            SetVehicleDamageModifier(veh, (tonumber(Config.TruckDamageModifier) or 1.0) + 0.0)
            -- SetVehicleExplosiveDamageModifier isn't a real native on this
            -- build ("attempt to call a nil value") — that error used to
            -- abort this whole handler right here, every single tick, before
            -- it ever reached ensureTruckLabelThread() below. That's why the
            -- floating name/health bar never appeared for anyone (police or
            -- gang) even though the blip logic above it ran fine. Guarded so
            -- it still applies on any build where the native *does* exist.
            if SetVehicleExplosiveDamageModifier then SetVehicleExplosiveDamageModifier(veh, 0.15) end
            SetVehicleStrong(veh, true)
            SetVehicleHasStrongAxles(veh, true)
            SetVehicleTyresCanBurst(veh, false)
        end
    end
    if next(truckLabels) then ensureTruckLabelThread() end
end)


-- ── police-only NPC hostile/support blips (checkpoint NPCs, ambush waves,
-- airdrop guards) — static coord blips, not entity-attached, since the
-- server broadcasts these to police who may be nowhere near the ped and
-- would never get it to stream in. Never sent to gang clients (see
-- addNpcBlip/removeNpcBlip in convoy_runtime.lua — audience is always
-- policeSources()).

RegisterNetEvent('nova_convoytruck:runtime:npcBlipAdd', function(data)
    if npcBlips[data.id] and DoesBlipExist(npcBlips[data.id]) then RemoveBlip(npcBlips[data.id]) end
    local style = NPC_BLIP_SPRITE[data.kind] or NPC_BLIP_SPRITE.ambush
    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, style.sprite)
    SetBlipColour(blip, style.colour)
    SetBlipScale(blip, style.scale or 0.85)   -- scale from config (falls back to 0.85)
    SetBlipAsShortRange(blip, true)
    -- Flash hostile NPC blips (ambush/airdrop_guard) so they stand out from static blips
    if style.flash then
        SetBlipFlashes(blip, true)
        SetBlipFlashTimer(blip, 800)
    end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(data.label or style.label)
    EndTextCommandSetBlipName(blip)
    npcBlips[data.id] = blip
end)

RegisterNetEvent('nova_convoytruck:runtime:npcBlipRemove', function(id)
    if npcBlips[id] then
        if DoesBlipExist(npcBlips[id]) then RemoveBlip(npcBlips[id]) end
        npcBlips[id] = nil
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:hideAll', function()
    for _, blip in pairs(movingBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    movingBlips = {}
    truckLabels = {}
    if checkpointBlip then RemoveBlip(checkpointBlip) checkpointBlip = nil end
    if checkpointRadiusBlip then RemoveBlip(checkpointRadiusBlip) checkpointRadiusBlip = nil end
    if stagingBlip then RemoveBlip(stagingBlip) stagingBlip = nil end
    if stagingRadiusBlip then RemoveBlip(stagingRadiusBlip) stagingRadiusBlip = nil end
    dropTrucks = {}
    cachedDestCoords = nil
    for netId, zone in pairs(dropZones) do if zone and zone.remove then zone:remove() end end
    dropZones = {}
    for netId, blip in pairs(dropBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    dropBlips = {}
    pcall(function() lib.hideTextUI() end)
    for id, blip in pairs(airdropBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    airdropBlips = {}
    for id, blip in pairs(airdropRadiusBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    airdropRadiusBlips = {}
    for netId, blip in pairs(airdropPlaneBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    airdropPlaneBlips = {}
    for pointId in pairs(airdropSmokeFx) do stopAirdropSmoke(pointId) end
    for pointId in pairs(airdropLandedFlareFx) do stopAirdropLandedFlares(pointId) end
    for pointId in pairs(airdropMarkers) do airdropMarkers[pointId] = nil end
    for id, blip in pairs(npcBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    npcBlips = {}
    for id, z in pairs(airdropGuardZones) do
        for _, blip in pairs(z.blips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    end
    airdropGuardZones = {}
    for id, z in pairs(hcGuardZones or {}) do
        for _, blip in pairs(z.blips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    end
    hcGuardZones = {}
    for _, blip in ipairs(policeZoneBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    policeZoneBlips = {}
    for _, blip in ipairs(policeZoneRadiusBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    policeZoneRadiusBlips = {}
    -- Hot Cargo: search circles, destination blips, hijack prompts, speed cap
    for _, z in pairs(hcZoneBlips) do
        if z.radius and DoesBlipExist(z.radius) then RemoveBlip(z.radius) end
        if z.centre and DoesBlipExist(z.centre) then RemoveBlip(z.centre) end
    end
    hcZoneBlips = {}
    for _, d in pairs(hcDestBlips) do
        if d.blip and DoesBlipExist(d.blip) then SetBlipRoute(d.blip, false) RemoveBlip(d.blip) end
        if d.radius and DoesBlipExist(d.radius) then RemoveBlip(d.radius) end
    end
    hcDestBlips = {}
    hotCargoTargets = {} -- (the Hijack prompt is a global vehicle option now — nothing per-entity to clear)

    -- ── World-object cleanup (force-end / natural end / resource stop) ──────
    -- Everything below was MISSING from this handler: an admin force-ending an
    -- airdrop event cleared the map sprites and the HUD clock, but left the
    -- crate prop, the guard NPCs, the flare and the landing smoke sitting in
    -- the world indefinitely — the "force closed it and stuff is still there"
    -- report. This now tears all of it down in one place.
    --
    -- Wanted-level suppression must also be released, or a player who was near
    -- a drop keeps being pinned at 0 stars forever (the suppression thread
    -- only exits when this table is empty).
    airdropWantedSuppression = {}

    -- The crate props are networked entities the SERVER also deletes (see
    -- cleanupAirdrop), so this is a belt-and-braces client sweep for any that
    -- are still streamed in locally — including the cosmetic descent copy,
    -- which is a purely local object the server has no handle on at all and
    -- which would otherwise keep falling/floating after a forced end.
    for pointId in pairs(airdropSmokeFx) do stopAirdropSmoke(pointId) end
    for pointId in pairs(airdropLandedFlareFx) do stopAirdropLandedFlares(pointId) end
    for pointId in pairs(airdropMarkers) do airdropMarkers[pointId] = nil end
    -- Looted flags are per run: a reused event re-issues the same point ids.
    if airdropLootedPoints then for pointId in pairs(airdropLootedPoints) do airdropLootedPoints[pointId] = nil end end
    cleanupAirdropDescentCopies()
    -- Clears ox_target options off every crate we registered, so a stale
    -- "Search Airdrop Crate" prompt can't survive into the next event.
    cleanupAirdropTargets()
    -- Same for the truck-loot prompts and their crate blips.
    cleanupTruckLootTargets()

    -- Sweep remaining vehicles, NPC peds, and crate props
    local vehPool = GetGamePool('CVehicle')
    for _, ent in ipairs(vehPool) do
        if DoesEntityExist(ent) then
            local st = Entity(ent).state
            if st.convoy_truck or st.hot_cargo_truck then
                local driver = GetPedInVehicleSeat(ent, -1)
                if driver and driver ~= 0 and DoesEntityExist(driver) and not IsPedAPlayer(driver) then
                    SetEntityAsMissionEntity(driver, true, true)
                    DeleteEntity(driver)
                end
                SetEntityAsMissionEntity(ent, true, true)
                DeleteVehicle(ent)
                DeleteEntity(ent)
            end
        end
    end

    local pedPool = GetGamePool('CPed')
    for _, ped in ipairs(pedPool) do
        if DoesEntityExist(ped) and not IsPedAPlayer(ped) then
            local rel = GetPedRelationshipGroupHash(ped)
            if rel == joaat('nova_convoy_driver') or rel == joaat('nova_convoy_npc') then
                SetEntityAsMissionEntity(ped, true, true)
                DeleteEntity(ped)
            end
        end
    end

    local objPool = GetGamePool('CObject')
    for _, obj in ipairs(objPool) do
        if DoesEntityExist(obj) then
            local st = Entity(obj).state
            if st.convoy_airdrop or st.convoy_prop then
                SetEntityAsMissionEntity(obj, true, true)
                DeleteEntity(obj)
            end
        end
    end

    -- A client-flown supply plane belongs to exactly one client; the server's
    -- own despawn broadcast handles it on the normal path, but a force-end can
    -- land mid-flight, so the hosting client tears its own plane down here too.
    cleanupFlightPlane()

    ConvoyUI.hideTimer()
    ConvoyUI.hideDeliveryTimer()
    ConvoyUI.hidePrepCountdown()
    lib.hideTextUI()
    SendNUIMessage({ action = 'gangSquadHide' })
    SendNUIMessage({ action = 'policeSquadHide' })
    SendNUIMessage({ action = 'convoyProgressHide' })
end)

-- The event of this kind has ended (or was force-ended): wipe every timer / panel it puts on screen. Sent by ConvoyManager.setStatus
-- for every end path, so a HUD that one of the per-event cleanups forgot cannot stay up. Only that kind's panels are touched (events
-- of different kinds can run side by side).
RegisterNetEvent('nova_convoytruck:runtime:endHud', function(kind)
    kind = kind or 'CONVOY'
    if kind == 'TDM' then
        SendNUIMessage({ action = 'hideTdmMatch' })
        SendNUIMessage({ action = 'tdmRespawnHide' })
        SendNUIMessage({ action = 'scoreboardHide' })
    elseif kind == 'CRACKDOWN' then
        SendNUIMessage({ action = 'crackdown:hide' })
        SendNUIMessage({ action = 'territory:outOfBounds', active = false })
    elseif kind == 'CONTAINER_WARS' then
        SendNUIMessage({ action = 'cwTimer:frame', visible = false })
        SendNUIMessage({ action = 'containerInfo:frame', items = {} })
        SendNUIMessage({ action = 'cwVehicleReward:frame', items = {} })
    elseif kind == 'GANG_RACE' then
        SendNUIMessage({ action = 'raceTowerHide' })
        SendNUIMessage({ action = 'raceGridHide' })
        SendNUIMessage({ action = 'endRace' })
    end
    if kind == 'CONVOY' or kind == 'HOT_CARGO' or kind == 'GANG_AIRDROP' or kind == 'GANG_RACE' then
        -- the truck map sprites and floating truck labels go with the event (another running convoy re-adds its own on the next
        -- update, which the server sends every few seconds)
        if kind == 'CONVOY' or kind == 'HOT_CARGO' then
            for _, blip in pairs(movingBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
            movingBlips = {}
            truckLabels = {}
        end
        ConvoyUI.hideTimer()
        ConvoyUI.hideDeliveryTimer()
        ConvoyUI.hidePrepCountdown()
        SendNUIMessage({ action = 'gangSquadHide' })
        SendNUIMessage({ action = 'policeSquadHide' })
        SendNUIMessage({ action = 'convoyProgressHide' })
        pcall(function() lib.hideTextUI() end)
    end
end)

-- The convoy's DESTINATION is outlined with a red ring (the delivery circle's edge, drawn twice for a bolder line), visible from a
-- distance, so it is clear where the trucks have to be taken. The ring goes away with the event (hideAll clears cachedDestCoords).
CreateThread(function()
    while true do
        local c = cachedDestCoords
        if c then
            local me = GetEntityCoords(cache.ped or PlayerPedId())
            if #(me - c) < 350.0 then
                local R = (tonumber(Config.DeliveryRadius) or 20.0) + 5.0
                for _, r in ipairs({ R, R - 0.35 }) do
                    DrawMarker(25, c.x, c.y, c.z - 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 1.0, 255, 45, 45, 235, false, false, 2, false, nil, nil, false)
                end
                Wait(0)
            else
                Wait(500)
            end
        else
            Wait(1000)
        end
    end
end)

-- ── Convoy staging zone blip ─────────────────────────────────────────────────
-- Shown from the moment trucks spawn (doStart) until the convoy is released
-- (releaseConvoy). Draws a green radius circle so police can see where trucks
-- are staged on the map before the convoy moves. Appearance from Config.MapBlips.

RegisterNetEvent('nova_convoytruck:runtime:stagingZone', function(data)
    -- data = { x, y, z, label, radius } sent by server doStart
    if stagingBlip and DoesBlipExist(stagingBlip) then RemoveBlip(stagingBlip) end
    if stagingRadiusBlip and DoesBlipExist(stagingRadiusBlip) then RemoveBlip(stagingRadiusBlip) end

    local cfg = MB.stagingZone or {}
    -- Centre point blip
    local b = AddBlipForCoord(data.x, data.y, data.z)
    SetBlipSprite(b, cfg.sprite or 1)
    SetBlipColour(b, cfg.colour or 2)
    SetBlipScale(b, cfg.scale or 0.9)
    SetBlipDisplay(b, 2)
    SetBlipAsShortRange(b, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(data.label or cfg.label or 'Convoy Staging Area')
    EndTextCommandSetBlipName(b)
    stagingBlip = b

    -- Radius circle overlay
    local rb = AddBlipForRadius(data.x, data.y, data.z, data.radius or 80.0)
    SetBlipColour(rb, cfg.radiusColour or 2)
    SetBlipAlpha(rb, cfg.radiusAlpha or 70)
    stagingRadiusBlip = rb
end)

RegisterNetEvent('nova_convoytruck:runtime:stagingZoneRemove', function()
    if stagingBlip and DoesBlipExist(stagingBlip) then RemoveBlip(stagingBlip) end
    stagingBlip = nil
    if stagingRadiusBlip and DoesBlipExist(stagingRadiusBlip) then RemoveBlip(stagingRadiusBlip) end
    stagingRadiusBlip = nil
end)


-- ── police / admin route guidance (Config.PoliceAlwaysSeeRouteZones, Config.PoliceRouteBlips) ──────────
-- Race-style: the server resends the not-yet-passed points every time the convoy's route advances (see
-- sendPoliceRouteZones), so this redraws the whole set each time. Each point type has its own sprite
-- (Config.MapBlips.policeRoute), checkpoints are numbered and get their hold circle, and the first guidable point
-- (`current`) is flashing with a GPS line — a plain waypoint counts too, so the line follows the convoy's own path
-- instead of the fastest road to the next checkpoint.
local function policeBlipName(text)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(policeZoneBlips[#policeZoneBlips])
end

RegisterNetEvent('nova_convoytruck:runtime:policeRouteZones', function(zones)
    for _, blip in ipairs(policeZoneBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    policeZoneBlips = {}
    for _, blip in ipairs(policeZoneRadiusBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    policeZoneRadiusBlips = {}
    policeCheckpointBlips = {}
    local PR = MB.policeRoute or {}
    local gps = (Config.PoliceRouteBlips or {}).gps ~= false
    for _, z in ipairs(zones or {}) do
        local t = z.type
        local blip = AddBlipForCoord(z.x + 0.0, z.y + 0.0, (z.z or 0.0) + 0.0)
        policeZoneBlips[#policeZoneBlips + 1] = blip
        local label

        if t == 'CHECKPOINT' then
            local cfg = MB.checkpoint or {}
            local pr = PR.checkpoint or {}
            local radiusBlip = AddBlipForRadius(z.x + 0.0, z.y + 0.0, (z.z or 0.0) + 0.0, (z.radius or 80.0) + 0.0)
            SetBlipColour(radiusBlip, cfg.radiusColour or 5)
            SetBlipAlpha(radiusBlip, math.floor((cfg.radiusAlpha or 180) * 0.85))
            SetBlipDisplay(radiusBlip, 2)
            SetBlipAsShortRange(radiusBlip, false)
            policeZoneRadiusBlips[#policeZoneRadiusBlips + 1] = radiusBlip
            SetBlipSprite(blip, pr.sprite or 38)
            SetBlipColour(blip, pr.colour or 5)
            SetBlipScale(blip, pr.scale or 0.95)
            label = ('%s %d/%d%s'):format(pr.label or 'Convoy Checkpoint', z.no or 0, z.total or 0, (z.name and z.name ~= '') and (' — ' .. tostring(z.name)) or '')
            policeCheckpointBlips[#policeCheckpointBlips + 1] = { x = z.x, y = z.y, blip = blip }
        elseif t == 'DESTINATION' then
            local pr = PR.destination or {}
            SetBlipSprite(blip, pr.sprite or 478)
            SetBlipColour(blip, pr.colour or 2)
            SetBlipScale(blip, pr.scale or 1.0)
            label = pr.label or 'Convoy Destination'
            if ensureDeliveryDropZone then ensureDeliveryDropZone(nil, vec3(z.x, z.y, z.z), nil) end
        elseif t == 'START' then
            local pr = PR.start or {}
            SetBlipSprite(blip, pr.sprite or 1)
            SetBlipColour(blip, pr.colour or 2)
            SetBlipScale(blip, pr.scale or 0.9)
            label = pr.label or 'Convoy Start'
        elseif t == 'BREAK' then
            local pr = PR.rest or {}
            SetBlipSprite(blip, pr.sprite or 1)
            SetBlipColour(blip, pr.colour or 3)
            SetBlipScale(blip, pr.scale or 0.9)
            label = (z.name and z.name ~= '') and tostring(z.name) or (pr.label or 'Convoy Rest Stop')
        else
            local pr = PR.waypoint or {}
            SetBlipSprite(blip, pr.sprite or 1)
            SetBlipColour(blip, pr.colour or 0)
            SetBlipScale(blip, pr.scale or 0.4)
            label = pr.label or 'Convoy Route'
        end

        SetBlipDisplay(blip, 2)
        SetBlipAsShortRange(blip, t == 'ROUTE')
        SetBlipPriority(blip, t == 'CHECKPOINT' and 12 or (t == 'DESTINATION' and 11 or 5))
        if z.current then
            SetBlipScale(blip, (t == 'DESTINATION' and 1.1) or ((PR.checkpoint or {}).scale or 0.8) * 1.35)   -- the next stage, bigger, like the next race checkpoint
            SetBlipFlashes(blip, true)
            if gps then
                SetBlipRoute(blip, true)
                SetBlipRouteColour(blip, PR.gpsColour or 5)
            end
        end
        policeBlipName(label)
    end
end)

-- ── checkpoint freeze / timer / announcements (police-facing) ────────────────────

RegisterNetEvent('nova_convoytruck:runtime:freezeTruck', function(netIds)
    for _, netId in ipairs(netIds) do
        local veh = safeNetToVeh(netId)
        if DoesEntityExist(veh) then
            FreezeEntityPosition(veh, true)
            SetVehicleEngineOn(veh, true, true, true)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:unfreezeTruck', function(netIds)
    for _, netId in ipairs(netIds) do
        local veh = safeNetToVeh(netId)
        if DoesEntityExist(veh) then
            FreezeEntityPosition(veh, false)
            SetVehicleEngineOn(veh, true, true, true)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:checkpointStart', function(seconds, index, total, coords, radius)
    ConvoyUI.showTimer(seconds, index, total)

    if checkpointBlip and DoesBlipExist(checkpointBlip) then RemoveBlip(checkpointBlip) checkpointBlip = nil end
    if checkpointRadiusBlip and DoesBlipExist(checkpointRadiusBlip) then RemoveBlip(checkpointRadiusBlip) checkpointRadiusBlip = nil end
    if coords then
        local cfg = MB.checkpoint or {}
        -- Police / admins already have this checkpoint on the map (the route overview): highlight that blip instead of
        -- stacking a second icon and a second circle on top of it.
        local existing = nil
        for _, e in ipairs(policeCheckpointBlips) do
            if DoesBlipExist(e.blip) and math.abs(e.x - coords.x) < 3.0 and math.abs(e.y - coords.y) < 3.0 then existing = e break end
        end
        if existing then
            SetBlipFlashes(existing.blip, true)
            SetBlipScale(existing.blip, ((MB.policeRoute or {}).checkpoint or {}).scale and (MB.policeRoute.checkpoint.scale * 1.35) or ((cfg.scale or 0.95) * 1.2))
        else
            local ptBlip = AddBlipForCoord(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
            SetBlipSprite(ptBlip, cfg.sprite or 38)
            SetBlipColour(ptBlip, cfg.colour or 5)
            SetBlipScale(ptBlip, (cfg.scale or 0.95) * 1.2)
            SetBlipDisplay(ptBlip, 2)
            SetBlipPriority(ptBlip, 12)
            SetBlipAsShortRange(ptBlip, false)
            SetBlipFlashes(ptBlip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(('%s %d/%d'):format(cfg.label or 'Convoy Checkpoint', tonumber(index) or 0, tonumber(total) or 0))
            EndTextCommandSetBlipName(ptBlip)
            checkpointBlip = ptBlip

            local rad = (tonumber(radius) or 80.0) + 0.0
            local radiusBlip = AddBlipForRadius(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, rad)
            SetBlipColour(radiusBlip, cfg.radiusColour or 5)
            SetBlipAlpha(radiusBlip, cfg.radiusAlpha or 90)
            SetBlipDisplay(radiusBlip, 2)
            SetBlipAsShortRange(radiusBlip, false)
            if SetRadiusBlipEdge then
                SetRadiusBlipEdge(radiusBlip, true)
            end
            checkpointRadiusBlip = radiusBlip
            SetNewWaypoint(coords.x, coords.y)   -- police already have the GPS line of the route guidance
        end
    end
end)

-- Barricade props are created server-side at a raw saved Z with no ground
-- alignment (server-side collision can't be trusted for a raycast) — this is
-- the client-side snap pass that actually settles them onto real terrain
-- once collision is loaded nearby, same idea as snapVehicleToGround above.
RegisterNetEvent('nova_convoytruck:runtime:snapBarricadesToGround', function(netIds)
    for _, netId in ipairs(netIds or {}) do
        if NetworkDoesNetworkIdExist(netId) then
            CreateThread(function()
                local obj = NetworkGetEntityFromNetworkId(netId)
                if not obj or obj == 0 or not DoesEntityExist(obj) then return end
                local coords = GetEntityCoords(obj)
                RequestCollisionAtCoord(coords.x, coords.y, coords.z)
                local timeout = 0
                while not HasCollisionLoadedAroundEntity(obj) and timeout < 25 do
                    Wait(50)
                    timeout = timeout + 1
                end
                if not DoesEntityExist(obj) then return end
                FreezeEntityPosition(obj, false)
                PlaceObjectOnGroundProperly(obj)
                FreezeEntityPosition(obj, true)
            end)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:checkpointUpdate', function(seconds)
    ConvoyUI.syncTimer(seconds)
end)

RegisterNetEvent('nova_convoytruck:runtime:checkpointPause', function()
    ConvoyUI.pauseTimer(true)
end)

RegisterNetEvent('nova_convoytruck:runtime:checkpointResume', function(seconds)
    ConvoyUI.syncTimer(seconds)
    ConvoyUI.pauseTimer(false)
end)

RegisterNetEvent('nova_convoytruck:runtime:checkpointEnd', function()
    ConvoyUI.hideTimer()
    if checkpointBlip then RemoveBlip(checkpointBlip) checkpointBlip = nil end
    if checkpointRadiusBlip then RemoveBlip(checkpointRadiusBlip) checkpointRadiusBlip = nil end
end)

RegisterNetEvent('nova_convoytruck:runtime:announce', function(title, body, duration, kind, gang, status, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom)
    NovaSound.banner(title, kind, status)
    ConvoyUI.announce(title, body, duration, kind, gang, status, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom)
end)

RegisterNetEvent('nova_convoytruck:client:updateEventBanners', function(banners)
    SendNUIMessage({
        action = 'updateEventBanners',
        banners = banners
    })
end)

RegisterNetEvent('nova_convoytruck:client:playChime', function()
    PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', true)
end)

-- Gang roster changes (add/remove member) — deliberately a small corner toast,
-- not the big banner: it's a routine roster update, not a convoy event.
RegisterNetEvent('nova_convoytruck:gang:toast', function(icon, title, message, warn)
    ConvoyUI.toast(icon, title, message, warn)
end)

RegisterNetEvent('nova_convoytruck:runtime:startDeliveryTimer', function(seconds, kind)
    ConvoyUI.startDeliveryTimer(seconds, kind)
end)

RegisterNetEvent('nova_convoytruck:runtime:deliveryTimer', function(seconds, kind)
    ConvoyUI.updateDeliveryTimer(seconds, kind)
end)

-- Gang Airdrop's own overall event clock (monitorGangAirdropEvent) — same
-- widget, different label/icon (see DeliveryTimer.svelte), since there's no
-- delivery to speak of in this event kind.
RegisterNetEvent('nova_convoytruck:runtime:eventTimer', function(seconds)
    ConvoyUI.updateDeliveryTimer(seconds, 'AIRDROP')
end)

-- ── delivery zone ────────────────────────────────────────────────────────────────

function ensureDeliveryDropZone(convoyId, destCoords, netId)
    if destCoords then
        cachedDestCoords = vec3(destCoords.x, destCoords.y, destCoords.z)
    end
    if netId then
        dropTrucks[netId] = { convoyId = convoyId, netId = netId }
    end
    if not cachedDestCoords then return end

    -- The zone was built around the destination of whichever event came first. When a later event (or a re-saved route)
    -- has a different destination, the old zone kept showing "[E] Deliver" there while the server checked the new
    -- destination: "too far from the dropzone". Rebuild it at the current destination.
    local old = dropZones['main']
    if old and old.coords and #(vec3(old.coords.x, old.coords.y, old.coords.z) - cachedDestCoords) > 1.0 then
        if old.remove then old:remove() end
        for k, z in pairs(dropZones) do if z == old then dropZones[k] = nil end end
    end

    if not dropZones['main'] then
        local point = lib.points.new({ coords = cachedDestCoords, distance = 60 })
        function point:nearby()
            -- The "[E] Deliver" prompt only appears inside the delivery circle (Config.DeliveryRadius, plus 5 m of margin) -
            -- it used to show from 50 m away, long before the destination. The marker draws that circle.
            local R = (tonumber(Config.DeliveryRadius) or 20.0) + 5.0
            DrawMarker(1, self.coords.x, self.coords.y, self.coords.z - 1.0, 0, 0, 0, 0, 0, 0, R * 2.0, R * 2.0, 2.0, 0, 255, 100, 90, false, true, 2, false, nil, nil, false)
            local ped = cache.ped or PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local targetTruck = nil

            -- 1. Check all registered dropTrucks
            for tNetId, tData in pairs(dropTrucks) do
                local veh = safeNetToVeh(tNetId)
                if veh ~= 0 and DoesEntityExist(veh) then
                    local inSeat = GetPedInVehicleSeat(veh, -1) == ped
                    local vehCoords = GetEntityCoords(veh)
                    local distToTruck = #(pedCoords - vehCoords)
                    local distToDest = #(vehCoords - self.coords)
                    if (inSeat or distToTruck < 12.0) and (distToDest < R or #(pedCoords - self.coords) < R) then
                        targetTruck = { convoyId = tData.convoyId, netId = tNetId, isDriver = inSeat }
                        break
                    end
                end
            end

            -- 2. Check if player is driving any active convoy truck inside dropzone
            if not targetTruck and IsPedInAnyVehicle(ped, false) then
                local currentVeh = GetVehiclePedIsIn(ped, false)
                if currentVeh ~= 0 and GetPedInVehicleSeat(currentVeh, -1) == ped then
                    local currentNetId = VehToNet(currentVeh)
                    local isConvoyVeh = (currentNetId and (movingBlips[currentNetId] or dropTrucks[currentNetId]))
                        or Entity(currentVeh).state.convoy_truck
                    if isConvoyVeh then
                        if #(GetEntityCoords(currentVeh) - self.coords) < R then
                            local cId = (currentNetId and dropTrucks[currentNetId] and dropTrucks[currentNetId].convoyId)
                                or Entity(currentVeh).state.convoy_id or convoyId
                            targetTruck = { convoyId = cId, netId = currentNetId, isDriver = true }
                        end
                    end
                end
            end

            -- 3. Check if player is on foot near any convoy truck inside dropzone
            if not targetTruck and not IsPedInAnyVehicle(ped, false) then
                for bNetId, _ in pairs(movingBlips) do
                    local veh = safeNetToVeh(bNetId)
                    if veh ~= 0 and DoesEntityExist(veh) then
                        local vehCoords = GetEntityCoords(veh)
                        if #(pedCoords - vehCoords) < 12.0 and #(vehCoords - self.coords) < R then
                            local cId = Entity(veh).state.convoy_id or convoyId
                            targetTruck = { convoyId = cId, netId = bNetId, isDriver = false }
                            break
                        end
                    end
                end
            end

            if targetTruck then
                lib.showTextUI('[E] Deliver Convoy Truck')
                if IsControlJustReleased(0, 38) or IsControlJustReleased(2, 38) or IsControlJustReleased(0, 51) or IsControlJustReleased(2, 51) or (targetTruck.isDriver and (IsControlJustReleased(0, 86) or IsControlJustReleased(2, 86))) then
                    TriggerServerEvent('nova_convoytruck:runtime:server:completeDelivery', targetTruck.convoyId, targetTruck.netId)
                    lib.hideTextUI()
                end
            else
                lib.hideTextUI()
            end
        end
        function point:onExit() lib.hideTextUI() end
        dropZones['main'] = point
    end
    if netId then
        dropZones[netId] = dropZones['main']
    end
end

RegisterNetEvent('nova_convoytruck:runtime:dropzone', function(convoyId, netId, destPoint)
    if not destPoint then return end
    local dest = vec3(destPoint.x, destPoint.y, destPoint.z)
    local cfg = MB.deliveryZone or {}

    if not dropBlips['main'] or not DoesBlipExist(dropBlips['main']) then
        local blip = AddBlipForCoord(dest.x, dest.y, dest.z)
        SetBlipSprite(blip, cfg.sprite or 478)
        SetBlipColour(blip, cfg.colour or 2)   -- Green = safe destination
        SetBlipScale(blip, cfg.scale or 1.0)
        if cfg.flash ~= false then SetBlipFlashes(blip, true) end
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(cfg.label or 'Convoy Drop Location')
        EndTextCommandSetBlipName(blip)
        SetBlipRoute(blip, true)
        dropBlips['main'] = blip
    end
    if netId then
        dropBlips[netId] = dropBlips['main']
    end

    ensureDeliveryDropZone(convoyId, dest, netId)
end)

-- ── airdrop ──────────────────────────────────────────────────────────────────────

-- The supply plane's moving map blip — a plain coordinate blip the server
-- repositions every ~300ms (see airdropPlaneMove), NOT AddBlipForEntity.
-- Entity-attached blips need the plane to actually be streamed in on this
-- specific client first, and a player standing at ground level near the
-- drop point is exactly the case where a vehicle 250m up and up to 600m
-- away often never streams in for them at all — that silently produced no
-- blip and no visible plane. Coordinates work regardless of streaming.
RegisterNetEvent('nova_convoytruck:runtime:airdropPlaneSpawn', function(netId, blipSprite, blipColour, blipScale, label, heading, startX, startY, startZ)
    if airdropPlaneBlips[netId] and DoesBlipExist(airdropPlaneBlips[netId]) then RemoveBlip(airdropPlaneBlips[netId]) end
    local x = tonumber(startX) or 0.0
    local y = tonumber(startY) or 0.0
    local z = tonumber(startZ) or 0.0
    local blip = AddBlipForCoord(x, y, z)
    SetBlipSprite(blip, blipSprite or 423) -- radar_plane
    SetBlipColour(blip, blipColour or 5)
    SetBlipScale(blip, blipScale or 1.1)
    SetBlipAsShortRange(blip, false)
    SetBlipRotation(blip, math.floor(heading or 0))
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label or 'Supply Plane')
    EndTextCommandSetBlipName(blip)
    airdropPlaneBlips[netId] = blip
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropPlaneMove', function(netId, x, y, z, heading)
    local blip = airdropPlaneBlips[netId]
    if not blip or not DoesBlipExist(blip) then
        blip = AddBlipForCoord(x, y, z)
        SetBlipSprite(blip, 423)
        SetBlipColour(blip, 5)
        SetBlipScale(blip, 1.1)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('Supply Plane')
        EndTextCommandSetBlipName(blip)
        airdropPlaneBlips[netId] = blip
    else
        SetBlipCoords(blip, x, y, z)
    end
    SetBlipRotation(blip, math.floor(heading or 0))
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropPlaneDespawn', function(netId)
    if airdropPlaneBlips[netId] then
        if DoesBlipExist(airdropPlaneBlips[netId]) then RemoveBlip(airdropPlaneBlips[netId]) end
        airdropPlaneBlips[netId] = nil
    end
end)

-- Draws the supply plane's flyover on THIS client. The server sends the line to fly (start, end, heading, how long it takes) and keeps the
-- clock; every client within sight of the drop makes its own local, non-networked copy of the plane and puts it on the line each frame.
-- Nothing about the plane is networked or flown by anyone, so it cannot lag, freeze or drift off the line, it looks the same to everyone
-- who can see it, and the server releases the crate at exactly the moment the plane passes over the zone (flyAirdropPlane in
-- convoy_runtime.lua). Same idea as the crate's own descent (airdropDescent), which was already drawn this way.
--
-- Each flight's own state lives in activeAirdropFlights, keyed by its id, so flights for different zones never touch each other.
activeAirdropFlights = activeAirdropFlights or {}

local function cleanupOneFlight(id)
    local f = activeAirdropFlights[id]
    if not f then return end
    activeAirdropFlights[id] = nil
    if f.pilot and DoesEntityExist(f.pilot) then DeleteEntity(f.pilot) end
    if f.plane and DoesEntityExist(f.plane) then DeleteEntity(f.plane) end
end

-- Force-end / natural end / resource stop — removes EVERY plane this client is drawing. Overrides the forward declaration made near
-- hideAll, so hideAll's own call tears all of them down.
local function cleanupFlightPlaneImpl()
    for id in pairs(activeAirdropFlights) do
        cleanupOneFlight(id)
    end
end
cleanupFlightPlane = cleanupFlightPlaneImpl
local function cleanupFlightPlane()
    return cleanupFlightPlaneImpl()
end

RegisterNetEvent('nova_convoytruck:runtime:airdropPlaneFlight', function(d)
    if type(d) ~= 'table' or not d.id or activeAirdropFlights[d.id] then return end

    -- only players who could actually see the plane bother making one
    local planeCfg = (Config.Airdrop and Config.Airdrop.plane) or {}
    local viewDist = tonumber(planeCfg.viewDistance) or 2500.0
    local me = GetEntityCoords(cache.ped or PlayerPedId())
    local ox, oy = me.x - d.dropX, me.y - d.dropY
    if ox * ox + oy * oy > viewDist * viewDist then return end

    -- the clock starts now, even if the model needs a moment to load: the plane then simply appears already part-way along the line
    local t0 = GetGameTimer()
    activeAirdropFlights[d.id] = {}   -- claimed, so a repeated event for the same flight is ignored

    CreateThread(function()
        local model = joaat(d.model or 'dodo')
        if not pcall(lib.requestModel, model, 8000) then
            activeAirdropFlights[d.id] = nil
            return
        end
        local plane = CreateVehicle(model, d.startX, d.startY, d.startZ, d.heading or 0.0, false, false)
        if not plane or plane == 0 then
            SetModelAsNoLongerNeeded(model)
            activeAirdropFlights[d.id] = nil
            return
        end
        SetModelAsNoLongerNeeded(model)

        SetEntityInvincible(plane, true)
        SetEntityCollision(plane, false, false)
        FreezeEntityPosition(plane, true)
        SetVehicleEngineOn(plane, true, true, false)   -- engine running: the propeller turns
        SetVehicleLights(plane, 2)
        pcall(ControlLandingGear, plane, 3)             -- gear up
        pcall(SetEntityDistanceCullingRadius, plane, 3000.0)
        SetEntityLodDist(plane, 3000)

        -- a pilot in the seat, so it reads as an aircraft rather than an empty shell
        local pilot
        local pilotModel = joaat(d.pilotModel or 's_m_m_pilot_01')
        if pcall(lib.requestModel, pilotModel, 3000) then
            pilot = CreatePedInsideVehicle(plane, 4, pilotModel, -1, false, false)
            if pilot and pilot ~= 0 then
                SetEntityInvincible(pilot, true)
                SetBlockingOfNonTemporaryEvents(pilot, true)
            else
                pilot = nil
            end
            SetModelAsNoLongerNeeded(pilotModel)
        end

        activeAirdropFlights[d.id] = { plane = plane, pilot = pilot }

        local flightMs = math.max(1000, tonumber(d.flightMs) or 20000)
        local vx, vy, vz = d.endX - d.startX, d.endY - d.startY, d.endZ - d.startZ
        while activeAirdropFlights[d.id] and DoesEntityExist(plane) do
            local el = GetGameTimer() - t0
            if el >= flightMs then break end
            local f = el / flightMs
            SetEntityCoordsNoOffset(plane, d.startX + vx * f, d.startY + vy * f, d.startZ + vz * f, false, false, false)
            -- nose along the line, with a gentle bank
            SetEntityRotation(plane, 0.0, math.sin(el / 1500.0) * 4.0, d.heading or 0.0, 2, true)
            Wait(0)
        end
        cleanupOneFlight(d.id)
    end)
end)

-- Server marks the flyover finished — the hosting client tears its own
-- entity down so nothing is left hanging in the sky. Targeted by netId now:
-- this used to be a blanket broadcast with no way to say WHICH flight to
-- stop, so one drop's own teardown could kill an unrelated, still-active
-- drop's plane on whichever client happened to be hosting both.
RegisterNetEvent('nova_convoytruck:runtime:airdropPlaneStopHosting', function(netId)
    cleanupOneFlight(netId)
end)

-- Ground-snaps the REAL, server-created, networked airdrop crate (and the
-- destroyed-truck / Hot Cargo reward crates that reuse the same server-side
-- spawn path) on behalf of the server. GetGroundZFor_3dCoord (and very
-- likely PlaceObjectOnGroundProperly too) are natives that need the map's
-- collision data, which only clients ever load — the server has none, so
-- calling them there either throws (guarded away, silently) or simply does
-- nothing. That is why a crate created server-side at its configured
-- "admin was floating a metre up when they placed this" height could never
-- actually correct itself: the whole verify-and-fix step was a no-op every
-- single time it ran. Same fix shape as the plane above — ask a real client
-- to do the thing that needs real client natives, report back the answer.
lib.callback.register('nova_convoytruck:runtime:snapPropToGround', function(data)
    if not data or not data.netId then return { ok = false, error = 'no netId' } end
    local timeout = GetGameTimer() + 4000
    local entity = 0
    while GetGameTimer() < timeout do
        if NetworkDoesNetworkIdExist(data.netId) then
            entity = NetworkGetEntityFromNetworkId(data.netId)
            if entity ~= 0 and DoesEntityExist(entity) then break end
        end
        Wait(100)
    end
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return { ok = false, error = 'entity never streamed in' }
    end
    -- Ground under the crate. The map collision there must be LOADED for any
    -- ground query to answer, and for a drop that isn't right next to this
    -- player it usually isn't until it has been asked for — which is why the
    -- first airdrop (player standing nearby) landed fine and later ones, in
    -- zones further away, silently "found nothing" and were left floating at
    -- the height the zone was placed at. So: request collision at the spot
    -- and keep probing (from a few heights, lowest first) until it answers,
    -- and report a miss as a miss so the server can ask someone else instead
    -- of trusting the crate's own height.
    local c = GetEntityCoords(entity)
    local baseZ = tonumber(data.z) or c.z
    local deadline = GetGameTimer() + 5000
    local gz
    while GetGameTimer() < deadline do
        RequestCollisionAtCoord(c.x, c.y, baseZ)
        for _, probe in ipairs({ 10.0, 40.0, 120.0 }) do
            local found, z = GetGroundZFor_3dCoord(c.x, c.y, baseZ + probe, false)
            if found and z then gz = z break end
        end
        if gz then break end
        Wait(150)
    end
    if not gz then
        return { ok = false, error = 'ground not found (collision not loaded)' }
    end
    -- If this client owns the prop, let the game place it exactly (accounts
    -- for the model's own origin); otherwise the raw ground height is used.
    local placedZ
    pcall(function()
        local ctrlDeadline = GetGameTimer() + 800
        while not NetworkHasControlOfEntity(entity) and GetGameTimer() < ctrlDeadline do
            NetworkRequestControlOfEntity(entity)
            Wait(50)
        end
        if NetworkHasControlOfEntity(entity) then
            SetEntityCoordsNoOffset(entity, c.x, c.y, gz + 0.5, false, false, false)
            PlaceObjectOnGroundProperly(entity)
            local pc = GetEntityCoords(entity)
            if math.abs(pc.z - gz) < 3.0 then placedZ = pc.z end
        end
    end)
    return { ok = true, z = placedZ or gz }
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropSmoke', function(pointId, coords, smoke)
    stopAirdropSmoke(pointId)
    local dict = smoke.particleDict or 'core'
    local name = smoke.particleName or 'exp_grd_bzgas_smoke'
    RequestNamedPtfxAsset(dict)
    local timeout = GetGameTimer() + 3000
    while not HasNamedPtfxAssetLoaded(dict) and GetGameTimer() < timeout do Wait(0) end
    if not HasNamedPtfxAssetLoaded(dict) then return end

    UseParticleFxAssetNextCall(dict)
    local fx = StartParticleFxLoopedAtCoord(name, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, smoke.scale or 3.0, false, false, false, false)
    if fx and fx ~= -1 then
        local color = smoke.color or { r = 1.0, g = 0.1, b = 0.1 }
        SetParticleFxLoopedColour(fx, color.r or 1.0, color.g or 0.1, color.b or 0.1, false)
        airdropSmokeFx[pointId] = fx
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropSmokeStop', function(pointId)
    stopAirdropSmoke(pointId)
end)

-- Only THUG guards are ever spawned for an airdrop (NpcManager.spawnAmbushers,
-- server-side) — but the resulting firefight still raises the local player's
-- own GTA wanted level like any other gunfight, which pulls in vanilla
-- ambient police that were never part of this event's design ("police
-- glitching in" when only thug NPCs were configured). Pinning the wanted
-- level at 0 for the drop's duration is the standard fix (same idiom most
-- heist-style resources use) — purely local/client-side, so it only ever
-- affects the gang client actually receiving this event, never police.
local airdropWantedSuppression = {}
local wantedSuppressionThreadRunning = false
local function ensureWantedSuppressionThread()
    if wantedSuppressionThreadRunning then return end
    wantedSuppressionThreadRunning = true
    CreateThread(function()
        while next(airdropWantedSuppression) do
            SetPlayerWantedLevel(PlayerId(), 0, false)
            SetPlayerWantedLevelNow(PlayerId(), false)
            Wait(1000)
        end
        wantedSuppressionThreadRunning = false
    end)
end

-- Incoming-drop phase (plane inbound / crate still falling) — zone circle
-- only, no crate sprite yet, since there's nothing on the ground to mark.
-- The full airdropActive notify below replaces this with the real crate
-- blip + radius once it actually lands.
RegisterNetEvent('nova_convoytruck:runtime:airdropZonePing', function(point)
    if airdropRadiusBlips[point.id] and DoesBlipExist(airdropRadiusBlips[point.id]) then
        RemoveBlip(airdropRadiusBlips[point.id])
        airdropRadiusBlips[point.id] = nil
    end
    if airdropBlips[point.id] and DoesBlipExist(airdropBlips[point.id]) then
        RemoveBlip(airdropBlips[point.id])
        airdropBlips[point.id] = nil
    end
    local cfg = MB.airdrop or {}
    local radiusBlip = AddBlipForRadius(point.x, point.y, point.z, point.radius or 35.0)
    SetBlipColour(radiusBlip, cfg.radiusColour or 5)
    SetBlipAlpha(radiusBlip, cfg.radiusAlpha or 130)
    SetBlipAsShortRange(radiusBlip, false)
    airdropRadiusBlips[point.id] = radiusBlip

    -- Also show early blinking crate icon so gangs immediately spot the drop zone
    local blip = AddBlipForCoord(point.x, point.y, point.z)
    SetBlipSprite(blip, cfg.sprite or 501)
    SetBlipColour(blip, cfg.colour or 5)
    SetBlipScale(blip, cfg.scale or 1.0)
    SetBlipAsShortRange(blip, false)
    SetBlipFlashes(blip, true)
    SetBlipFlashInterval(blip, 450)
    SetBlipSecondaryColour(blip, 1) -- Flashes between Yellow (5) and Red (1) for maximum gang visibility
    local label = point.label or point.name or 'Airdrop Inbound'
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    airdropBlips[point.id] = blip
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropActive', function(point, duration)
    -- Fires twice for a plane-delivered drop now (an early "incoming zone"
    -- ping the moment coords are known, then again once it actually lands)
    -- — remove any earlier blip for this point first so that isn't a leaked
    -- duplicate marker sitting on the map.
    if airdropBlips[point.id] and DoesBlipExist(airdropBlips[point.id]) then
        RemoveBlip(airdropBlips[point.id])
        airdropBlips[point.id] = nil
    end
    if airdropRadiusBlips[point.id] and DoesBlipExist(airdropRadiusBlips[point.id]) then
        RemoveBlip(airdropRadiusBlips[point.id])
        airdropRadiusBlips[point.id] = nil
    end
    local cfg = MB.airdrop or {}
    local blip = AddBlipForCoord(point.x, point.y, point.z)
    SetBlipSprite(blip, cfg.sprite or 501)
    SetBlipColour(blip, cfg.colour or 5)
    SetBlipScale(blip, cfg.scale or 1.0)
    SetBlipAsShortRange(blip, false)
    SetBlipFlashes(blip, true)
    SetBlipFlashInterval(blip, 450)
    SetBlipSecondaryColour(blip, 1) -- Flashes between Yellow and Red
    local label = point.label or point.name or 'Airdrop'
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    airdropBlips[point.id] = blip

    -- "Hunting circle" zone radius, same treatment as a checkpoint's — was
    -- missing before, so an active drop only ever showed as a single point.
    local radiusBlip = AddBlipForRadius(point.x, point.y, point.z, point.radius or 35.0)
    SetBlipColour(radiusBlip, cfg.radiusColour or 5)
    SetBlipAlpha(radiusBlip, cfg.radiusAlpha or 130)
    SetBlipAsShortRange(radiusBlip, false)
    airdropRadiusBlips[point.id] = radiusBlip

    notify(('An airdrop (%s) is active — check your map.'):format(label), 'inform')

    airdropWantedSuppression[point.id] = true
    ensureWantedSuppressionThread()
    if duration and duration > 0 then
        CreateThread(function()
            Wait(duration * 1000)
            airdropWantedSuppression[point.id] = nil
        end)
    end
end)

-- GTA-style per-ped blips for airdrop guards — only drawn once a player has
-- actually walked into the drop zone (not the instant guards spawn, which
-- would show them on the map from anywhere), and taken down by the single
-- server-side cleanupAirdrop path regardless of whether the drop ended by
-- being looted, by its own timer expiring, or the whole convoy force-ending.
-- [id] = { x, y, z, radius, guardNetIds, blips = { [netId] = blipHandle }, entered }
airdropGuardZones = airdropGuardZones or {}
local guardZoneWatcherRunning = false
local function ensureGuardZoneWatcher()
    if guardZoneWatcherRunning then return end
    guardZoneWatcherRunning = true
    CreateThread(function()
        while next(airdropGuardZones) do
            local myCoords = GetEntityCoords(cache.ped or PlayerPedId())
            for id, z in pairs(airdropGuardZones) do
                if not z.entered then
                    local d = #(myCoords - vector3(z.x, z.y, z.z))
                    if d <= (z.radius or 35.0) then
                        z.entered = true
                    end
                end
                if z.entered then
                    for _, netId in ipairs(z.guardNetIds) do
                        local existingBlip = z.blips[netId]
                        if existingBlip then
                            -- A dead guard still exists as an entity (a
                            -- corpse) — AddBlipForEntity doesn't remove
                            -- itself just because the ped died, so the
                            -- "Hostile Guard" marker was sitting on the map
                            -- over a body that could never fight again.
                            -- Drop the blip once the ped is gone or dead.
                            local ped = NetworkDoesNetworkIdExist(netId) and NetworkGetEntityFromNetworkId(netId) or 0
                            if ped == 0 or not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then
                                if DoesBlipExist(existingBlip) then RemoveBlip(existingBlip) end
                                z.blips[netId] = nil
                            end
                        elseif NetworkDoesNetworkIdExist(netId) then
                            local ped = NetworkGetEntityFromNetworkId(netId)
                            if ped ~= 0 and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                                local style = NPC_BLIP_SPRITE.airdrop_guard
                                local blip = AddBlipForEntity(ped)
                                SetBlipSprite(blip, style.sprite)
                                SetBlipColour(blip, style.colour)
                                SetBlipScale(blip, 0.7)
                                SetBlipAsShortRange(blip, true)
                                BeginTextCommandSetBlipName('STRING')
                                AddTextComponentSubstringPlayerName('Hostile Guard')
                                EndTextCommandSetBlipName(blip)
                                z.blips[netId] = blip
                            end
                        end
                    end
                end
            end
            Wait(1000)
        end
        guardZoneWatcherRunning = false
    end)
end

RegisterNetEvent('nova_convoytruck:runtime:airdropGuardZone', function(id, coords, radius, guardNetIds)
    airdropGuardZones[id] = { x = coords.x, y = coords.y, z = coords.z, radius = radius, guardNetIds = guardNetIds or {}, blips = {}, entered = false }
    ensureGuardZoneWatcher()
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropGuardZoneRemove', function(id)
    local z = airdropGuardZones[id]
    if z then
        for _, blip in pairs(z.blips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    end
    airdropGuardZones[id] = nil
end)

-- Same reveal-on-proximity per-ped blip pattern as the airdrop guard zones
-- just above, for Hot Cargo's own guards (both a truck's spawn-point detail
-- and a dropoff zone's) — this didn't exist for Hot Cargo at all before, so
-- its guards never got any map marker regardless of distance.
-- [id] = { x, y, z, radius, guardNetIds, blips = { [netId] = blipHandle }, entered }
hcGuardZones = hcGuardZones or {}
local hcGuardZoneWatcherRunning = false
local function ensureHcGuardZoneWatcher()
    if hcGuardZoneWatcherRunning then return end
    hcGuardZoneWatcherRunning = true
    CreateThread(function()
        while next(hcGuardZones) do
            local myCoords = GetEntityCoords(cache.ped or PlayerPedId())
            for id, z in pairs(hcGuardZones) do
                if not z.entered then
                    local d = #(myCoords - vector3(z.x, z.y, z.z))
                    if d <= (z.radius or 60.0) then
                        z.entered = true
                    end
                end
                if z.entered then
                    for _, netId in ipairs(z.guardNetIds) do
                        local existingBlip = z.blips[netId]
                        if existingBlip then
                            local ped = NetworkDoesNetworkIdExist(netId) and NetworkGetEntityFromNetworkId(netId) or 0
                            if ped == 0 or not DoesEntityExist(ped) or IsPedDeadOrDying(ped, true) then
                                if DoesBlipExist(existingBlip) then RemoveBlip(existingBlip) end
                                z.blips[netId] = nil
                            end
                        elseif NetworkDoesNetworkIdExist(netId) then
                            local ped = NetworkGetEntityFromNetworkId(netId)
                            if ped ~= 0 and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                                local style = NPC_BLIP_SPRITE.hotcargo_guard
                                local blip = AddBlipForEntity(ped)
                                SetBlipSprite(blip, style.sprite)
                                SetBlipColour(blip, style.colour)
                                SetBlipScale(blip, 0.7)
                                SetBlipAsShortRange(blip, true)
                                BeginTextCommandSetBlipName('STRING')
                                AddTextComponentSubstringPlayerName('Hostile Guard')
                                EndTextCommandSetBlipName(blip)
                                z.blips[netId] = blip
                            end
                        end
                    end
                end
            end
            Wait(1000)
        end
        hcGuardZoneWatcherRunning = false
    end)
end

RegisterNetEvent('nova_convoytruck:runtime:hotCargoGuardZone', function(id, coords, radius, guardNetIds)
    hcGuardZones[id] = { x = coords.x, y = coords.y, z = coords.z, radius = radius, guardNetIds = guardNetIds or {}, blips = {}, entered = false }
    ensureHcGuardZoneWatcher()
end)

RegisterNetEvent('nova_convoytruck:runtime:hotCargoGuardZoneRemove', function(id)
    local z = hcGuardZones[id]
    if z then
        for _, blip in pairs(z.blips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    end
    hcGuardZones[id] = nil
end)

RegisterNetEvent('nova_convoytruck:runtime:airdropExpired', function(pointId)
    if airdropBlips[pointId] then
        RemoveBlip(airdropBlips[pointId])
        airdropBlips[pointId] = nil
    end
    if airdropRadiusBlips[pointId] then
        RemoveBlip(airdropRadiusBlips[pointId])
        airdropRadiusBlips[pointId] = nil
    end
    airdropWantedSuppression[pointId] = nil
    stopAirdropSmoke(pointId)
    stopAirdropLandedFlares(pointId)
    airdropMarkers[pointId] = nil -- crate expired: the floating UI goes with it
end)

airdropLootedPoints = airdropLootedPoints or {}

RegisterNetEvent('nova_convoytruck:runtime:airdropLooted', function(pointId, stolenBy)
    if airdropBlips[pointId] then
        RemoveBlip(airdropBlips[pointId])
        airdropBlips[pointId] = nil
    end
    if airdropRadiusBlips[pointId] then
        RemoveBlip(airdropRadiusBlips[pointId])
        airdropRadiusBlips[pointId] = nil
    end
    airdropWantedSuppression[pointId] = nil
    stopAirdropSmoke(pointId)
    stopAirdropLandedFlares(pointId)
    -- The crate itself now stays in the world (see cleanupAirdrop's
    -- keepProp) instead of despawning on loot — stops the floating label
    -- (via runLootCrateLabel's stopCheck) and the now-pointless "Search
    -- Airdrop Crate" prompt (the server already no-ops a re-select on an
    -- already-looted entry, but leaving the prompt up invites clicking it
    -- for nothing). Matched by its convoy_point_id state bag rather than a
    -- separate tracked table, since the entity is already looked up this
    -- way elsewhere (see the statebag handlers above).
    airdropLootedPoints[pointId] = true
    -- The floating UI flips from "AIRDROP" to "AIRDROP STOLEN" (no countdown,
    -- shows who took it) and rides out the crate's remaining lifetime; it still
    -- goes away with the crate/event via hideAll, airdropExpired or its endAt.
    if airdropMarkers[pointId] then
        airdropMarkers[pointId].stolen = true
        airdropMarkers[pointId].stolenBy = type(stolenBy) == 'string' and stolenBy or nil
    end
    for entity in pairs(airdropTargetEntities or {}) do
        if DoesEntityExist(entity) then
            local ok, entPointId = pcall(function() return Entity(entity).state.convoy_point_id end)
            if ok and entPointId == pointId then
                pcall(NovaConvoy.RemoveEntityTarget, entity, type(airdropTargetEntities[entity]) == 'number' and airdropTargetEntities[entity] or nil)
                airdropTargetEntities[entity] = nil
            end
        end
    end
end)

-- Single flare beacon beside a landed, lootable crate — the one in
-- airdropDescent above is a red flare attached to the crate while it's still
-- falling, which stops the instant it lands (see its own comment) and is no
-- help finding the crate once it's down. This reads as a marker FOR the
-- crate rather than part of the model itself.
--
-- BOUNDED ON PURPOSE, and only ONE instance, not a ring of several — a
-- four-flare ring was tried and reported as a visible client-side frame hit
-- (looped particle effects from the 'core'/exp_grd_* family are not cheap,
-- and this runs once per nearby client for the crate's whole time on the
-- ground). One looped, colour-tinted flare is enough to mark the position
-- without that cost. An even earlier version fired a real flare PROJECTILE
-- (a live weapon entity) every 4 seconds instead, which was worse still —
-- see Config.Airdrop.flareDurationSeconds (default 120s) for how long this
-- burns before stopping; the crate BLIP and floating label remain for the
-- crate's full lifetime regardless.
local function runLootCrateFlareBeacon(entity, pointId)
    CreateThread(function()
        if not DoesEntityExist(entity) then return end
        local durationSec = tonumber(Config.Airdrop and Config.Airdrop.flareDurationSeconds) or 120
        if durationSec <= 0 then return end -- disabled entirely

        RequestNamedPtfxAsset('core')
        local timeout = GetGameTimer() + 3000
        while not HasNamedPtfxAssetLoaded('core') and GetGameTimer() < timeout do Wait(0) end
        if not HasNamedPtfxAssetLoaded('core') then return end
        if not DoesEntityExist(entity) then return end

        -- Wait for the crate to actually be sitting on the ground before the flare is lit. This event can arrive before the server's
        -- ground snap has replicated, and a flare started at world coordinates then stayed at the old (floating / sunk) height.
        local lastZ, stable = nil, 0
        local settleBy = GetGameTimer() + 4000
        while DoesEntityExist(entity) and stable < 3 and GetGameTimer() < settleBy do
            local z = GetEntityCoords(entity).z
            if lastZ and math.abs(z - lastZ) < 0.05 then stable = stable + 1 else stable = 0 end
            lastZ = z
            Wait(150)
        end
        if not DoesEntityExist(entity) then return end

        -- Attached to the crate (a little to one side), so it stays right beside it however the crate settles.
        UseParticleFxAssetNextCall('core')
        local fx = StartParticleFxLoopedOnEntity('exp_grd_flare', entity, 1.2, 1.2, 0.05, 0.0, 0.0, 0.0, 1.0, false, false, false)
        if not fx or fx == -1 then return end
        SetParticleFxLoopedColour(fx, 1.0, 0.05, 0.05, false) -- red

        -- Registered so airdropExpired/airdropLooted/hideAll (a drop ending
        -- any of those three ways) can stop this immediately rather than
        -- leaking the fx handle until this thread's own timeout below.
        airdropLandedFlareFx[pointId] = { fx }

        local stopsAt = GetGameTimer() + (durationSec * 1000)
        while DoesEntityExist(entity) and GetGameTimer() < stopsAt and airdropLandedFlareFx[pointId] do
            Wait(1000)
        end
        stopAirdropLandedFlares(pointId)
    end)
end

-- Fortnite-style floating label over a lootable crate. Used for every crate
-- across every event kind that drops one (destroyed-truck crate, Hot Cargo's
-- reward crate — both via truckLootable below — and both airdrop flavours
-- via airdropLootable), just never over the vehicle-loot case (there's
-- already a whole truck sitting there; a label over it would be noise).
-- Only actually drawn while reasonably close, so it's cheap when nobody's
-- nearby.
-- stopCheck (optional): called each tick, stop the label early if it
-- returns true — used by airdrop crates, which now stay in the world after
-- being looted (see cleanupAirdrop's keepProp) instead of despawning, so
-- this can't just rely on DoesEntityExist(entity) turning false anymore.
local function runLootCrateLabel(entity, text, stopCheck)
    CreateThread(function()
        while DoesEntityExist(entity) and not (stopCheck and stopCheck()) do
            local coords = GetEntityCoords(entity)
            local myCoords = GetEntityCoords(cache.ped or PlayerPedId())
            if #(myCoords - coords) < 15.0 then
                local labelCoords = coords + vector3(0.0, 0.0, 0.55)
                local onScreen, sx, sy = GetScreenCoordFromWorldCoord(labelCoords.x, labelCoords.y, labelCoords.z)
                if onScreen then
                    -- No black backing box — a single bold white pass
                    -- instead. A two-pass fake-glow (a larger faint layer
                    -- behind a crisp one) was tried here and reported as a
                    -- jittering double image rather than a glow — GTA's
                    -- DrawText is top-anchored per call, so two different
                    -- scales drawn every frame don't sit still relative to
                    -- each other the way a real blur would. SetTextOutline
                    -- gives it a thin dark edge for legibility against a
                    -- bright sky without needing a backing rect at all.
                    local label = text or 'LOOT CRATE'
                    SetTextScale(0.56, 0.56)
                    SetTextFont(4)
                    SetTextProportional(true)
                    SetTextCentre(true)
                    SetTextColour(255, 255, 255, 255)
                    SetTextOutline()
                    SetTextEntry('STRING')
                    AddTextComponentString(label)
                    DrawText(sx, sy)
                end
            end
            Wait(0)
        end
    end)
end

-- Floating AIRDROP UI over a landed crate — the NUI marker (web/src/lib/hud/
-- AirdropMarker.svelte), replacing the plain text label for airdrop crates.
-- ONE thread projects every active crate's position to screen coordinates each
-- frame and sends the visible ones to the NUI, which draws them (with the
-- crate's own expiry countdown) and so keeps each one pinned above its crate
-- as the player moves around. Removed by airdropExpired / airdropLooted /
-- hideAll (they clear airdropMarkers[pointId]), when the crate entity is gone,
-- or when its own countdown reaches zero.
local AIRDROP_MARKER_MAX_DIST = 60.0
local airdropMarkerThread = false
local airdropMarkerShown = false

local function ensureAirdropMarkerThread()
    if airdropMarkerThread then return end
    airdropMarkerThread = true
    CreateThread(function()
        local lastSig = ''
        while next(airdropMarkers) do
            local list = {}
            local sig = {}
            local me = GetEntityCoords(cache.ped or PlayerPedId())
            local now = GetGameTimer()
            local anyNearby = false
            for pointId, m in pairs(airdropMarkers) do
                if not DoesEntityExist(m.entity) or m.endAt - now <= 0 then
                    airdropMarkers[pointId] = nil
                else
                    local c = GetEntityCoords(m.entity)
                    local dist = #(me - c)
                    if dist <= AIRDROP_MARKER_MAX_DIST then
                        anyNearby = true
                        local onScreen, sx, sy = GetScreenCoordFromWorldCoord(c.x, c.y, c.z + 1.2)
                        if onScreen then
                            local seconds = math.ceil((m.endAt - now) / 1000)
                            local metres = math.floor(dist + 0.5)
                            list[#list + 1] = {
                                id = tostring(pointId),
                                x = math.floor(sx * 2000 + 0.5) / 2000,
                                y = math.floor(sy * 2000 + 0.5) / 2000,
                                scale = math.floor(math.max(0.7, math.min(1.0, 1.15 - dist / 60.0)) * 50 + 0.5) / 50,
                                seconds = seconds,
                                total = m.total,
                                dist = metres,
                                label = m.label,
                                stolen = m.stolen == true,
                                stolenBy = m.stolenBy,
                            }
                            local e = list[#list]
                            sig[#sig + 1] = ('%s:%.4f:%.4f:%.2f:%d:%d:%s'):format(e.id, e.x, e.y, e.scale, seconds, metres, tostring(e.stolen))
                        end
                    end
                end
            end
            -- Only talk to the browser when something on screen actually changed. This used to send the whole list every 16 ms
            -- even with the player standing still, which is a constant stream of messages (and a Svelte re-render each time)
            -- for as long as anyone is near a crate.
            local sigStr = table.concat(sig, ';')
            if sigStr ~= lastSig then
                lastSig = sigStr
                if #list > 0 or airdropMarkerShown then
                    SendNUIMessage({ action = 'airdropMarker:update', markers = list })
                    airdropMarkerShown = #list > 0
                end
            end
            -- ~30 updates a second while one is in range (the card glides between them, see AirdropMarker.svelte), idle otherwise
            Wait(anyNearby and 33 or 250)
        end
        SendNUIMessage({ action = 'airdropMarker:update', markers = {} })
        airdropMarkerShown = false
        airdropMarkerThread = false
    end)
end

local function registerAirdropMarker(pointId, entity, label, expiresInSeconds)
    local secs = tonumber(expiresInSeconds) or tonumber(Config.Airdrop and Config.Airdrop.duration) or 300
    airdropMarkers[pointId] = {
        entity = entity,
        label = label,
        endAt = GetGameTimer() + math.floor(secs * 1000),
        total = secs,
    }
    ensureAirdropMarkerThread()
end

-- The crate itself — guarded by hostile-to-everyone NPCs server-side
-- (NpcManager.spawnAmbushers), so this target prompt existing at all doesn't
-- mean it's safe to walk up to. Same lockpick+skill-check flow as a lost
-- truck's loot, just against convoyId+pointId instead of a stashId, and a
-- percentage roll on top once it's actually open (see claimAirdrop). This
-- one event covers both a regular convoy's in-route AIRDROP point AND a
-- standalone GANG_AIRDROP zone (see convoy_runtime.lua's spawnAirdrop /
-- spawnAirdropZone) — both get the floating label from here.
RegisterNetEvent('nova_convoytruck:runtime:airdropLootable', function(netId, pointId, convoyId, label, expiresIn)
    CreateThread(function()
        local timeout = GetGameTimer() + 15000
        local entity = 0
        while GetGameTimer() < timeout do
            if NetworkDoesNetworkIdExist(netId) then
                entity = NetworkGetEntityFromNetworkId(netId)
                if entity ~= 0 and DoesEntityExist(entity) then break end
            end
            Wait(100)
        end
        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        local ec = GetEntityCoords(entity)
        local gFound, gZ = GetGroundZFor_3dCoord(ec.x, ec.y, ec.z + 10.0, false)
        if gFound and math.abs(ec.z - gZ) > 1.5 and not IsEntityPositionFrozen(entity) then
            SetEntityCoordsNoOffset(entity, ec.x, ec.y, gZ, false, false, false)
        end

        -- The "Search Airdrop Crate" prompt is a global ox_target option decided from the
        -- crate's state bags (bottom of this file) — nothing is registered per entity here.
        airdropTargetEntities[entity] = true
        -- The crate now stays in the world once looted (cleanupAirdrop's
        -- keepProp — server/modules/convoy_runtime.lua's claimAirdrop), so
        -- the label can't rely on the entity disappearing to know when to
        -- stop; airdropLootedPoints below is set the moment this specific
        -- point is actually claimed.
        -- The floating AIRDROP UI (with the crate's expiry timer) instead of
        -- the old plain text label.
        registerAirdropMarker(pointId, entity, label, expiresIn)
        runLootCrateFlareBeacon(entity, pointId)
    end)
end)

RegisterNetEvent('nova_convoytruck:runtime:beginAirdropLootMinigame', function(convoyId, pointId, difficulty)
    local cfg = Config.Airdrop or {}
    local success = NovaConvoy.PlayMinigame(cfg.minigame or 'random', {
        title = 'CRACKING AIRDROP CRATE',
        difficulty = difficulty or cfg.skillCheckDifficulty or { 'easy', 'easy', 'medium' },
        pool = cfg.minigamePool or 'lockpick',
    })
    TriggerServerEvent('nova_convoytruck:runtime:server:reportAirdropLootAttempt', convoyId, pointId, success)
    if not success then
        lib.notify({ title = '📦 AIRDROP OPERATION', description = 'You failed to get the lock open — the lockpick snapped.', type = 'error', icon = 'parachute-box', iconColor = '#ffffff' })
    end
end)

-- Lock's open — this is the moment the server rolls whether there's
-- actually anything inside (see claimAirdrop server-side); this client just
-- asks for that roll, it never decides it.
RegisterNetEvent('nova_convoytruck:runtime:openAirdropLoot', function(convoyId, pointId)
    TriggerServerEvent('nova_convoytruck:runtime:server:claimAirdrop', convoyId, pointId)
end)

-- "Require a lockpick" OFF path — a single harder skill check (hacking the
-- crate's electronics) instead of a consumable-lockpick grind. Success
-- guarantees the reward server-side (see claimAirdrop's openedViaHack check).
RegisterNetEvent('nova_convoytruck:runtime:beginAirdropHackMinigame', function(convoyId, pointId)
    local cfg = Config.Airdrop or {}
    local success = NovaConvoy.PlayMinigame(cfg.hackMinigame or 'random', {
        title = 'BYPASSING AIRDROP ENCRYPTION',
        difficulty = cfg.hackDifficulty or 3,
        pool = cfg.hackPool or 'hack',
    })
    TriggerServerEvent('nova_convoytruck:runtime:server:reportAirdropHackAttempt', convoyId, pointId, success)
    if not success then
        lib.notify({ title = '📦 AIRDROP OPERATION', description = 'Hack failed — the lock reset, try again.', type = 'error', icon = 'parachute-box', iconColor = '#ffffff' })
    end
end)

-- ── looting a lost (captured/destroyed) truck ─────────────────────────────────────
-- Sent to joined gang participants AND police (see makeTruckLootable in
-- convoy_runtime.lua) — police/admins get a bypass straight to the stash, no
-- lockpick or minigame (Config.CapturedTruckLoot.policeBypass), gang
-- participants go through the real lockpick+skill-check flow below. Opening
-- it goes through the server first either way (participation/access and
-- lockpick consumption are server-validated, never trust the client's target
-- interaction alone) — the server only tells THIS client what to do next
-- (open directly, or run the minigame) after that passes.

RegisterNetEvent('nova_convoytruck:runtime:truckLootable', function(netId, stashId, convoyId, isProp, promptLabel)
    CreateThread(function()
        local timeout = GetGameTimer() + 15000
        local entity = 0
        while GetGameTimer() < timeout do
            if NetworkDoesNetworkIdExist(netId) then
                entity = NetworkGetEntityFromNetworkId(netId)
                if entity ~= 0 and DoesEntityExist(entity) then break end
            end
            Wait(100)
        end
        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        -- The "Hijack / Loot Truck" / "Search Loot Crate" prompt is a global ox_target
        -- option decided from the entity's state bags (bottom of this file), so nothing
        -- is registered per entity here — a second registration would show it twice.
        truckLootTargetEntities[entity] = true

        -- Add crate blip so players can find it easily
        if isProp then
            local blip = AddBlipForEntity(entity)
            SetBlipSprite(blip, 586)
            SetBlipColour(blip, 46) -- Gold
            SetBlipScale(blip, 0.85)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName('Convoy Loot Crate')
            EndTextCommandSetBlipName(blip)
            dropBlips[#dropBlips + 1] = blip
            runLootCrateLabel(entity)
        end
    end)
end)

-- Config.CapturedTruckLoot.requireLockpick = false path (or the police/admin
-- bypass, or a fully-cracked stash) — no item, no minigame, straight to the
-- stash once the server's confirmed access.
RegisterNetEvent('nova_convoytruck:runtime:openTruckLoot', function(stashId)
    InventoryClient.OpenStash(stashId)
end)

-- Fired once the server has confirmed participation and consumed a lockpick
-- — runs this resource's own native skill-check minigame client-side (never
-- ox_lib's lib.skillCheck), then reports the result back to the server,
-- which is the one that actually decides whether enough successful attempts
-- have landed to open the stash (see reportLootAttempt server-side — never
-- trust this client to track its own progress count).
RegisterNetEvent('nova_convoytruck:runtime:beginTruckLootMinigame', function(convoyId, stashId, progress, required)
    local difficulty = (Config.CapturedTruckLoot and Config.CapturedTruckLoot.skillCheckDifficulty) or { 'easy', 'easy', 'medium' }
    local title = (required and required > 1)
        and ('LOCKPICKING CARGO TRUCK (%d/%d)'):format(progress or 0, required)
        or 'LOCKPICKING CARGO TRUCK'
    local success = NovaConvoy.PlayMinigame('random', {
        title = title,
        difficulty = difficulty,
        pool = 'lockpick',
    })
    TriggerServerEvent('nova_convoytruck:runtime:server:reportLootAttempt', convoyId, stashId, success)
    if not success then
        lib.notify({ title = 'Truck Loot', description = 'You failed to get the lock open — the lockpick snapped.', type = 'error' })
    end
end)

-- "Require a lockpick" OFF path — a single harder skill check (hacking the
-- lock) instead of a consumable-lockpick grind. No percentage roll to worry
-- about here either way — a truck's stash is fixed contents, not a chance.
RegisterNetEvent('nova_convoytruck:runtime:beginTruckHackMinigame', function(convoyId, stashId)
    local success = NovaConvoy.PlayMinigame('random', {
        title = 'HACKING CARGO TRUCK SECURITY',
        difficulty = 3,
        pool = 'hack',
    })
    TriggerServerEvent('nova_convoytruck:runtime:server:reportTruckHackAttempt', convoyId, stashId, success)
    if not success then
        lib.notify({ title = 'Truck Loot', description = 'Hack failed — the lock reset, try again.', type = 'error' })
    end
end)

-- ── Hot Cargo vehicle theft (initial locked-doors entry) ──────────────────────────
-- Fired once per spawned Hot Cargo vehicle (see doStartHotCargo server-side).
-- The "Hijack Cargo Truck" prompt itself is a GLOBAL vehicle option registered
-- at the bottom of this file and decided purely from the truck's state bags, so
-- it appears for anyone who walks up to the truck whenever they stream it in —
-- no one-shot registration to miss. (The per-entity registration this event used
-- to do passed an entity handle to ox_target's network-id API and never worked.)
RegisterNetEvent('nova_convoytruck:runtime:hotCargoLockable', function() end)

RegisterNetEvent('nova_convoytruck:runtime:beginHotCargoUnlockMinigame', function(convoyId, truckId, requireLockpick, skillDifficulty)
    -- Same skill check the Convoy truck loot uses; every failed check wears the
    -- lockpick down server-side (Config.Lockpick), so the hijack is skill-based
    -- with real lockpick durability. The hack path (no lockpick required) stays a
    -- single harder check.
    local success = NovaConvoy.PlayMinigame('random', {
        title = 'HIJACKING CARGO TRUCK',
        difficulty = requireLockpick and (skillDifficulty or { 'easy', 'medium', 'medium' }) or 3,
        pool = requireLockpick and 'lockpick' or 'hack',
    })
    TriggerServerEvent('nova_convoytruck:runtime:server:reportHotCargoUnlockAttempt', convoyId, truckId, success)
end)

-- Server confirms the doors are unlocked (see reportHotCargoUnlockAttempt) —
-- drop the target option everywhere so other players stop trying a vehicle
-- that's already someone's.
RegisterNetEvent('nova_convoytruck:runtime:hotCargoUnlocked', function(netId)
    -- The global Hijack prompt stops showing by itself once hot_cargo_locked flips to false.
    lib.notify({ title = '🚚 HOT CARGO', description = 'Contraband vehicle unlocked — get moving!', type = 'success', icon = 'truck-fast', iconColor = '#ff6a00' })
end)

-- Hot Cargo search circles — one per truck nobody has hijacked yet. The server
-- sends the complete current set each time, so a hijacked truck's circle drops
-- out of the list and disappears here. Radius circle only: no truck sprite, and
-- the circle is offset server-side so it marks an area, not the truck.
RegisterNetEvent('nova_convoytruck:runtime:hotCargoZones', function(zones)
    local keep = {}
    for _, z in ipairs(zones or {}) do
        keep[z.id] = true
        local cur = hcZoneBlips[z.id]
        if not (cur and cur.radius and DoesBlipExist(cur.radius) and cur.x == z.x and cur.y == z.y) then
            if cur and cur.radius and DoesBlipExist(cur.radius) then RemoveBlip(cur.radius) end
            local rb = AddBlipForRadius(z.x, z.y, z.z, z.radius or 150.0)
            SetBlipColour(rb, 47) -- orange
            SetBlipAlpha(rb, 110)
            SetBlipDisplay(rb, 2)
            SetBlipAsShortRange(rb, false)
            hcZoneBlips[z.id] = { radius = rb, x = z.x, y = z.y }
        end
    end
    for id, z in pairs(hcZoneBlips) do
        if not keep[id] then
            if z.radius and DoesBlipExist(z.radius) then RemoveBlip(z.radius) end
            if z.centre and DoesBlipExist(z.centre) then RemoveBlip(z.centre) end
            hcZoneBlips[id] = nil
        end
    end
end)

-- Destination/base for a hijacked truck. Only ever sent to the hijacking gang,
-- so other gangs see the moving truck but never where it's headed.
RegisterNetEvent('nova_convoytruck:runtime:hotCargoDestination', function(netId, dest, truckNum)
    if hcDestBlips[netId] then return end
    local cfg = MB.deliveryZone or {}
    local blip = AddBlipForCoord(dest.x, dest.y, dest.z)
    SetBlipSprite(blip, cfg.sprite or 478)
    SetBlipColour(blip, cfg.colour or 2)
    SetBlipScale(blip, cfg.scale or 1.0)
    SetBlipAsShortRange(blip, false)
    if cfg.flash ~= false then SetBlipFlashes(blip, true) end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('Cargo Truck #%s — Destination'):format(tostring(truckNum or '?')))
    EndTextCommandSetBlipName(blip)
    SetBlipRoute(blip, true)
    local rb = AddBlipForRadius(dest.x, dest.y, dest.z, (dest.radius or 15.0) + 0.0)
    SetBlipColour(rb, cfg.colour or 2)
    SetBlipAlpha(rb, 90)
    hcDestBlips[netId] = { blip = blip, radius = rb }
end)

RegisterNetEvent('nova_convoytruck:runtime:hotCargoDestinationRemove', function(netId)
    local d = hcDestBlips[netId]
    if not d then return end
    if d.blip and DoesBlipExist(d.blip) then SetBlipRoute(d.blip, false) RemoveBlip(d.blip) end
    if d.radius and DoesBlipExist(d.radius) then RemoveBlip(d.radius) end
    hcDestBlips[netId] = nil
end)


-- Occupant safety + Hot Cargo speed cap. While a convoy / hot cargo truck still
-- has health: the occupants can't be shot through the windows. The moment
-- it's disabled (zero health) the protection drops and the server has
-- already told anyone inside to get out. A hijacked Hot Cargo truck is also
-- held to Config.HotCargoTheft.maxSpeed, whoever is driving it.
CreateThread(function()
    local protectedVeh, cappedVeh = nil, nil
    while true do
        local sleep = (protectedVeh or cappedVeh or eventsActive()) and 1000 or 3000
        local ped = cache.ped or PlayerPedId()
        local veh = (ped and ped ~= 0) and GetVehiclePedIsIn(ped, false) or 0
        local st = (veh ~= 0 and DoesEntityExist(veh)) and Entity(veh).state or nil
        if st and st.convoy_truck and not st.convoy_truck_broken and not st.hot_cargo_broken then
            sleep = 250
            -- SetVehicleWindowsCanBreak isn't a real native — confirmed live
            -- ("attempt to call a nil value") — removed rather than guessed
            -- at a replacement; SetPedCanBeShotInVehicle just below already
            -- provides the actual protection this thread exists for
            -- (shattered-looking windows with no way to shoot through them
            -- is purely cosmetic on top of that).
            if protectedVeh ~= veh then
                protectedVeh = veh
            end
            -- Reinforced windows: only while SEATED in the truck. The restore in the else
            -- branch below runs within one tick of leaving it, so a gang member who steps
            -- out to loot or interact is fully shootable again — vehicle protection never
            -- follows the player out of the vehicle.
            local hcProt = (Config.HotCargoTheft or {}).protection or {}
            if not (st.hot_cargo_truck and hcProt.reinforcedWindows == false) then
                SetPedCanBeShotInVehicle(ped, false)
            end
            local cap = st.hot_cargo_truck and tonumber(st.hot_cargo_max_speed) or nil
            if cap and cap > 0 then
                SetVehicleMaxSpeed(veh, cap + 0.0)
                cappedVeh = veh
            end
        else
            if protectedVeh then
                if ped and ped ~= 0 then SetPedCanBeShotInVehicle(ped, true) end
                protectedVeh = nil
            end
            if cappedVeh then
                if DoesEntityExist(cappedVeh) then SetVehicleMaxSpeed(cappedVeh, 0.0) end -- 0 = back to the model's own limit
                cappedVeh = nil
            end
        end
        Wait(sleep)
    end
end)

-- Hot Cargo vehicle protection. Vehicle damage modifiers / tyre flags are held by
-- whichever client currently OWNS the entity (they don't survive an ownership
-- change, and the server can't set them reliably), so every nearby client
-- applies them while it has control and re-applies after a hand-over. The truck
-- stays fully damageable — this only makes it tough: tyres can't be shot out
-- (truck and trailer) and body damage is reduced; HC.tick on the server still
-- breaks it down at Config.HotCargoTheft.breakdownHealthPct. Nothing here
-- touches any ped, so a player outside the truck is never protected.
CreateThread(function()
    local applied = {}
    while true do
        local sleep = (eventsActive() or next(applied)) and 2000 or 4000
        local cfg = (Config.HotCargoTheft or {}).protection or {}
        local ped = cache.ped or PlayerPedId()
        if ped and ped ~= 0 and sleep == 2000 then
            local pc = GetEntityCoords(ped)
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(veh) then
                    local st = Entity(veh).state
                    if st.hot_cargo_truck and not st.hot_cargo_broken and #(pc - GetEntityCoords(veh)) < 250.0 then
                        sleep = 750
                        if NetworkHasControlOfEntity(veh) then
                            if not applied[veh] then
                                applied[veh] = true
                                SetVehicleStrong(veh, true)
                                SetVehicleHasStrongAxles(veh, true)
                                SetVehicleDamageModifier(veh, (tonumber(cfg.damageModifier) or 0.25) + 0.0)
                                SetVehicleCanLeakPetrol(veh, false)
                                if cfg.bulletproofTyres ~= false then
                                    SetVehicleTyresCanBurst(veh, false)
                                    local hasTrailer, trailer = GetVehicleTrailerVehicle(veh)
                                    if hasTrailer and trailer and trailer ~= 0 and DoesEntityExist(trailer) then
                                        SetVehicleTyresCanBurst(trailer, false)
                                    end
                                end
                            end
                        else
                            applied[veh] = nil -- someone else owns it now; re-apply if it comes back to us
                        end
                    end
                else
                    applied[veh] = nil
                end
            end
        end
        Wait(sleep)
    end
end)

-- The server's authoritative progress count, sent after a successful attempt
-- that still wasn't enough on its own to open the stash (multi-lockpick
-- trucks only — a required count of 1 opens straight to openTruckLoot instead).
RegisterNetEvent('nova_convoytruck:runtime:lootProgress', function(progress, required)
    lib.notify({ title = 'Truck Loot', description = ('Lock progress: %d/%d — grab another lockpick.'):format(progress, required), type = 'inform' })
end)

-- ── NPC truck driving task execution ──────────────────────────────────────────────

-- ── NPC truck driving task execution ──────────────────────────────────────────────

local activeTruckWatchdogs = {}

-- The heavy-truck handling below is saved first, so it can be switched off again while a convoy is running
-- (/convoydebug physics off): that is how to tell whether the added mass / gravity is what keeps a truck from moving.
local physicsOriginals = {}   -- [vehicle] = the handling values it had before this script changed them
local physicsOff = false      -- set by /convoydebug physics off

local function rememberPhysics(veh)
    if physicsOriginals[veh] then return end
    physicsOriginals[veh] = {
        mass = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass'),
        com = GetVehicleHandlingVector(veh, 'CHandlingData', 'vecCentreOfMassOffset'),
        downforce = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fDownforceModifier'),
        tmin = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin'),
        tmax = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax'),
    }
end

local function restorePhysics(veh)
    local o = physicsOriginals[veh]
    if not o or not DoesEntityExist(veh) then physicsOriginals[veh] = nil return end
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass', o.mass)
    SetVehicleHandlingVector(veh, 'CHandlingData', 'vecCentreOfMassOffset', o.com)
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fDownforceModifier', o.downforce)
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin', o.tmin)
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax', o.tmax)
    SetVehicleGravityAmount(veh, 9.8)
end

local function applyTruckHeavyPhysics(veh)
    if not veh or not DoesEntityExist(veh) then return end
    local cfg = Config.TruckPhysics
    if not cfg or cfg.enabled == false or physicsOff then return end
    rememberPhysics(veh)

    if cfg.strongVehicle ~= false then
        SetVehicleStrong(veh, true)
        SetVehicleHasStrongAxles(veh, true)
        SetVehicleExplodesOnHighExplosionDamage(veh, false)
        SetVehicleCanDeformWheels(veh, false)
    end

    -- Armored fuel tank & bullet damage reduction:
    -- In GTA V, the stock fuel tank health is 1000 and causes instant explosion in 3-5 bullets.
    SetVehiclePetrolTankHealth(veh, 5000.0)
    SetVehicleCanLeakPetrol(veh, false)
    SetVehicleDamageModifier(veh, (tonumber(Config.TruckDamageModifier) or 1.0) + 0.0)
    SetVehicleEngineCanDegrade(veh, false)
    SetVehicleTyresCanBurst(veh, false)

    if cfg.gravityAmount then
        SetVehicleGravityAmount(veh, cfg.gravityAmount)
    end

    if cfg.mass then
        SetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass', cfg.mass)
    end
    if cfg.centerOfMassZ then
        SetVehicleHandlingVector(veh, 'CHandlingData', 'vecCentreOfMassOffset', vector3(0.0, 0.0, cfg.centerOfMassZ))
    end
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fDownforceModifier', 10.0)
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMin', 2.8)
    SetVehicleHandlingFloat(veh, 'CHandlingData', 'fTractionCurveMax', 3.0)
end

-- Combat/flee/ragdoll flags are LOCAL, per-client ped simulation state — GTA
-- never networks them. They used to only ever get applied once, by whichever
-- client happened to be "responsible" (nearest) at the exact moment the
-- original taskDrive fired. If control later migrates to a different client
-- (the first one wanders off/noclips away, or the truck simply drives far
-- enough that someone else becomes nearest), that new controlling client's
-- simulation of the ped has NONE of this applied — a stock GTA ped panics
-- and bails out of a vehicle that's taking heavy damage/burning regardless
-- of any drive task, which is exactly what "driver getting out of the
-- truck" was. Pulled into its own function so both executeTruckDrive AND
-- the ambient per-vehicle watchdog below (ensureDriverProtectionWatchdog)
-- can re-assert it on ANY client that ends up in control, not just the one
-- that issued the original drive command.
local function applyDriverProtections(ped)
    if not ped or not DoesEntityExist(ped) then return end
    -- NEVER apply any of this to a real player. It's all AI-ped-only
    -- suppression (can't leave the vehicle, can't fight, no alertness,
    -- invincible, blocked from "non-temporary events") — fine for the NPC
    -- driver this was designed for, but a real officer ends up in the
    -- driver's seat too: ESCORT-role trucks never get an NPC driver at all
    -- (they're meant to be player-driven), and any truck whose NPC driver
    -- died/got removed leaves the seat open for whoever climbs in. The
    -- ambient watchdog below re-checks whatever's in the driver's seat every
    -- 2s with no regard for who that is, so a player sitting there got hit
    -- with this over and over — SetBlockingOfNonTemporaryEvents combined
    -- with the AI combat-suppression flags is what was silently holstering
    -- their weapon after a couple of cycles ("only works for a few minutes
    -- then gets holstered").
    if IsPedAPlayer(ped) then return end
    if GetPedRelationshipGroupHash(ped) ~= `nova_convoy_driver` then
        SetPedRelationshipGroupHash(ped, `nova_convoy_driver`)
    end
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCombatAttributes(ped, 3, false)  -- BF_CanLeaveVehicle = FALSE (MUST STAY IN VEHICLE)
    SetPedCombatAttributes(ped, 1, false)  -- BF_CanFightArmedPedsWhenNotArmed = FALSE (DO NOT PUNCH)
    SetPedCombatAttributes(ped, 46, false) -- BF_AlwaysFight = FALSE
    SetPedCombatAttributes(ped, 0, false)  -- BF_CanUseCover = FALSE
    SetPedCombatAttributes(ped, 2, false)  -- BF_AlwaysFight = FALSE
    SetPedFleeAttributes(ped, 0, false)    -- DO NOT FLEE
    SetPedCombatAbility(ped, 0)
    SetPedCombatRange(ped, 0)
    SetPedCombatMovement(ped, 0)
    SetPedSeeingRange(ped, 0.0)
    SetPedHearingRange(ped, 0.0)
    SetPedAlertness(ped, 0)
    SetPedCanBeDraggedOut(ped, false)
    SetPedCanRagdoll(ped, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    SetPedCanBeKnockedOffVehicle(ped, 1)
    SetPedConfigFlag(ped, 281, true)
    SetPedConfigFlag(ped, 32, false)
    SetPedSuffersCriticalHits(ped, false)
    SetEntityInvincible(ped, true) -- The truck itself takes damage; driver stays focused on driving
end

-- Ambient, per-vehicle self-healing watchdog — started by ANY client the
-- moment it becomes aware of a convoy truck (see the convoy_truck statebag
-- handler below), independent of whichever client actually issued the last
-- drive task. Only the branch that finds itself in control does anything;
-- everyone else just waits and checks again, so this is cheap to run
-- broadly and is exactly what closes the ownership-migration gap above.
local driverProtectionWatchdogs = {}
local function ensureDriverProtectionWatchdog(netId)
    if driverProtectionWatchdogs[netId] then return end
    driverProtectionWatchdogs[netId] = true
    CreateThread(function()
        while NetworkDoesNetworkIdExist(netId) do
            local veh = safeNetToVeh(netId)
            if not veh or veh == 0 or not DoesEntityExist(veh) then break end
            if NetworkHasControlOfEntity(veh) then
                local ped = GetPedInVehicleSeat(veh, -1)
                if ped and ped ~= 0 and DoesEntityExist(ped) then
                    applyDriverProtections(ped)
                end
            end
            Wait(2000)
        end
        driverProtectionWatchdogs[netId] = nil
    end)
end

local function snapVehicleToGround(veh)
    if not veh or not DoesEntityExist(veh) then return end
    CreateThread(function()
        local coords = GetEntityCoords(veh)
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        local timeout = 0
        while not HasCollisionLoadedAroundEntity(veh) and timeout < 25 do
            Wait(50)
            timeout = timeout + 1
        end

        -- Temporarily unfreeze entity so suspension and tires can settle on the ground
        FreezeEntityPosition(veh, false)
        SetVehicleOnGroundProperly(veh)
        SetVehicleOnGroundProperly(veh)
        applyTruckHeavyPhysics(veh)

        -- If the truck is held during the police head-start buffer, freeze it securely on the road
        if Entity(veh).state.releaseHeld ~= false then
            FreezeEntityPosition(veh, true)
        end
    end)
end

-- /convoydebug physics on|off — switch the heavy-truck handling off (and put the original values back) or on again for every
-- convoy truck this client can see.
RegisterNetEvent('nova_convoytruck:debug:physics', function(enabled)
    physicsOff = enabled == false
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) and Entity(veh).state.convoy_truck then
            if physicsOff then restorePhysics(veh) else applyTruckHeavyPhysics(veh) end
        end
    end
    lib.notify({ title = 'Convoy debug', description = physicsOff and 'Heavy truck physics OFF (original handling restored).' or 'Heavy truck physics ON.', type = 'inform' })
end)
RegisterNetEvent('nova_convoytruck:runtime:snapTruckToGround', function(vehNetId)
    if not vehNetId or not NetworkDoesNetworkIdExist(vehNetId) then return end
    local veh = safeNetToVeh(vehNetId)
    if veh and DoesEntityExist(veh) then
        snapVehicleToGround(veh)
    end
end)

-- Checkpoint hold for a truck a real player is driving: the server cannot brake a player, so while the truck carries
-- 'cp_hold_brake' ({ x, y, r }: the marker and the settle radius, set once the truck is inside the checkpoint circle) its
-- speed is limited by the distance to the marker; the server freezes it on the marker once it has nearly stopped and
-- unfreezes it when the checkpoint releases.
CreateThread(function()
    local braked = nil
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local hb = (veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped) and Entity(veh).state.cp_hold_brake or nil
        if type(hb) == 'table' then
            braked = veh
            if not IsEntityPositionFrozen(veh) then
                -- speed limit that shrinks with the distance to the marker (3 m/s per 10 m, 1-12 m/s): the truck settles
                -- onto the marker whether or not the driver keeps W held; on the marker it is held to a crawl and the
                -- throttle is cut so the server can freeze it
                local c = GetEntityCoords(veh)
                local d = #(vector2(c.x, c.y) - vector2(hb.x, hb.y))
                local cap = math.max(1.0, math.min(12.0, d * 0.3))
                if d <= (hb.r or 15.0) then
                    cap = math.min(cap, 1.2)
                    DisableControlAction(0, 71, true) -- accelerate
                end
                local sp = GetEntitySpeed(veh)
                if sp > cap then SetVehicleForwardSpeed(veh, math.max(cap, sp * 0.985)) end
            end
            Wait(0)
        else
            if braked then
                if DoesEntityExist(braked) then SetVehicleHandbrake(braked, false) end
                braked = nil
            end
            Wait(250)
        end
    end
end)

-- A player at the wheel of a convoy truck (the escort rigs have no NPC driver) gets keys from the server the moment they
-- sit down, then the engine is switched back on: qbx_vehiclekeys kills the engine of any keyless driver on entry and
-- does not restart it once keys arrive, so the truck would sit there "not moving".
CreateThread(function()
    local asked = {}
    while true do
        Wait(500)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and Entity(veh).state.convoy_truck and not Entity(veh).state.convoy_truck_broken then
            if not asked[veh] then
                asked[veh] = true
                TriggerServerEvent('nova_convoytruck:runtime:server:requestTruckKeys', NetworkGetNetworkIdFromEntity(veh))
                -- keysList replicates a moment later; qbx keeps forcing the engine off every frame until it sees the keys,
                -- so switch it on only after qbx reports them (or after 5 s, whichever comes first)
                local untilMs = GetGameTimer() + 5000
                while GetGameTimer() < untilMs do
                    Wait(150)
                    local okK, has = pcall(function() return exports.qbx_vehiclekeys:HasKeys(veh) end)
                    if not okK or has then Wait(250); break end
                end
                if GetVehiclePedIsIn(ped, false) == veh then SetVehicleEngineOn(veh, true, true, false) end
            end
        elseif veh == 0 then
            asked = {}
        end
    end
end)

AddStateBagChangeHandler('convoy_truck', nil, function(bagName, key, value, _unused, replicated)
    if not value then return end
    -- string.gsub returns TWO values (the result, and how many substitutions
    -- were made) — as the lone argument to tonumber(...), Lua splices both
    -- in, so this was actually calling tonumber(idString, 0-or-1) every
    -- single time. 0 and 1 are both invalid bases (must be 2-36), so this
    -- threw "bad argument #2 to 'tonumber' (base out of range)" on every
    -- truck spawn, on every client — the real source of that recurring
    -- crash, nothing to do with stale entities. The extra parens force Lua
    -- to truncate gsub's return to just the string.
    local netId = tonumber((bagName:gsub('entity:', '')))
    if not netId or not NetworkDoesNetworkIdExist(netId) then return end
    local veh = safeNetToVeh(netId)
    if veh and DoesEntityExist(veh) then
        snapVehicleToGround(veh)
        ensureDriverProtectionWatchdog(netId)
        -- Covers clients that joined after the truck spawned (and so missed
        -- the one-shot setDriverGroup broadcast).
        local driver = GetPedInVehicleSeat(veh, -1)
        if driver and driver ~= 0 and not IsPedAPlayer(driver) then
            SetPedRelationshipGroupHash(driver, `nova_convoy_driver`)
        end
    end
end)

-- Decoded driving-style flags:
--   4   SwerveAroundAllCars           — weave around moving/stopped traffic
--   8   SteerAroundStationaryCars     — slow and steer around stationary blockers
--   16  SteerAroundPeds               — navigate around pedestrians
--   32  SteerAroundObjects            — navigate around world props
--   512 DriveIntoOncomingTraffic      — overtakes into the oncoming lane like a human driver
--
-- Deliberately NOT set (each one pulled the truck off the route the admin drew):
--   4194304 PreferNavmeshRoute        — pathfinds over the walkable navmesh instead of the
--                                       road network, so trucks cut across land between
--                                       route points instead of following the roads.
--   256     GoOffRoadWhenAvoiding     — leaves the road to get around any blocker.
--   262144  TargetPositionOverridesEntityPosition — not a routing flag at all.
-- Also never use 1073741824 (ForceJoinInRoadDirection): it made trucks spin looking for a
-- road node instead of driving to the waypoint.
-- Decoded driving-style flags:
--   1   StopForCars                   — vehicle stops for other traffic and obstacles
--   2   StopForPeds                   — vehicle stops for pedestrians
--   4   SwerveAroundAllCars           — weave around moving/stopped traffic
--   8   SteerAroundStationaryCars     — slow and steer around stationary blockers
--   16  SteerAroundPeds               — navigate around pedestrians
--   32  SteerAroundObjects            — navigate around world props
--   512 DriveIntoOncomingTraffic      — overtakes into the oncoming lane like a human driver
--
-- LANE DISCIPLINE (Config.TruckLaneDiscipline, default on): the road-following order drives with
-- 1 | 2 | 8 | 16 | 32 = 59 — it holds its lane, brakes for traffic and steers around a stationary blocker,
-- but never weaves (4) or pulls into the oncoming lane (512). With 4 + 512 set the AI drifted into the
-- opposite lane to pass anything, then slid back, which reads as the driver changing its mind.
-- Missions that are MEANT to cross over / cut across (opposite-side points, EXACT mode, the keeper's
-- straight drive) keep 512 because there the route itself asks for the other lane.
local TRUCK_ROAD_STYLE = 1 | 2 | 8 | 16 | 32
local TRUCK_MISSION_STYLE = 1 | 2 | 4 | 8 | 16 | 32 | 512
local TRUCK_DRIVING_STYLE = (Config.TruckLaneDiscipline == false) and TRUCK_MISSION_STYLE or TRUCK_ROAD_STYLE

-- Every truck (lead or otherwise) drives independently to its own point —
-- the server computes a nose-to-tail formation target for each one (see
-- driveColumn in convoy_runtime.lua) instead of tasking followers to
-- TaskVehicleEscort the truck directly ahead of them. Escorting a live
-- vehicle meant a captured/disabled/gang-driven truck dragged everyone
-- behind it down with it, and even a healthy lead's ordinary swerves/braking
-- visibly propagated to every follower — an independent coordinate target
-- has nothing left to depend on.
-- A route point drawn on the shoulder / beside the lane (the road check measured one 15 m from any road) gives the
-- long-range order a goal it cannot finish at: the order ends by itself a few dozen metres short and the truck idles.
-- So the order is aimed at the road node nearest the point that runs the SAME WAY the truck is going.
--
-- OPPOSITE SIDE: when the point sits on the other side of the road (its nearest road node runs against the truck's
-- direction and no same-way node is as close), the admin wants the truck to cross over and drive on that side to reach
-- it, not to obey same-side driving. The long-range order only follows lane directions and would never go there, so that
-- point is driven with a go-to mission that allows oncoming traffic and driving against the flow.
ConvoySnap = ConvoySnap or {}      -- [veh] = text shown by /convoydebug
ConvoyMission = ConvoyMission or {} -- [veh] = true while the truck runs a go-to mission instead of the long-range order

local function headingFromVector(dx, dy)
    local h = math.deg(math.atan2(-dx, dy))
    if h < 0.0 then h = h + 360.0 end
    return h
end

local function laneTargetFor(veh, target)
    local vp = GetEntityCoords(veh)
    local dx, dy = target.x - vp.x, target.y - vp.y
    local want = (dx * dx + dy * dy > 400.0) and headingFromVector(dx, dy) or GetEntityHeading(veh)
    local tv = vector3(target.x, target.y, target.z)

    -- Ask the game whether the roads actually join the truck to this point. If they do not (another carriageway, a median,
    -- a one-way ramp, no road at all) or only the long way round, a road-following order can never get there: drive the
    -- drawn route straight across instead, in whatever lane the route is in.
    -- Cutting straight across is only for a SHORT gap (a median, a carriageway split). A point that is far away in a
    -- straight line but joined only by a long road detour is a point drawn off the road network: driving straight at it
    -- takes the truck across fields and off the road, so past Config.TruckStraightAcrossMax the truck stays on the roads.
    local straight = #(vp - tv)
    if straight > 25.0 and straight < 600.0 then
        local travel = CalculateTravelDistanceBetweenPoints(vp.x, vp.y, vp.z, target.x, target.y, target.z)
        local noRoad = travel >= 99999.0
        local longWay = travel > straight * 2.0 and travel - straight > 80.0
        local maxCut = tonumber(Config.TruckStraightAcrossMax) or 80.0
        if noRoad or (longWay and straight <= maxCut) then
            ConvoySnap[veh] = noRoad
                and ('no road leads to the route point (%d m away) - driving the drawn route straight across'):format(math.floor(straight))
                or ('roads reach the route point only the long way (%d m by road, %d m straight) - driving the drawn route straight across'):format(math.floor(travel), math.floor(straight))
            return { x = target.x, y = target.y, z = target.z, speed = target.speed, exact = true }
        elseif longWay then
            ConvoySnap[veh] = ('route point is %d m away but %d m by road - staying on the roads instead of cutting across (move the point onto the road)'):format(math.floor(straight), math.floor(travel))
        end
    end
    local first, same
    for n = 1, 10 do
        local ok, pos, head = GetNthClosestVehicleNodeWithHeading(target.x, target.y, target.z, n, 1, 3.0, 0)
        if not ok then break end
        local off = #(tv - pos)
        if off > 30.0 then break end
        local diff = math.abs(head - want) % 360.0
        if diff > 180.0 then diff = 360.0 - diff end
        if not first then first = { pos = pos, off = off, diff = diff } end
        if diff <= 70.0 and not same then same = { pos = pos, off = off } end
    end
    if first and first.diff > 110.0 and (not same or same.off - first.off >= 4.0) then
        ConvoySnap[veh] = ('point is on the OPPOSITE side of the road (%d m from its lane) - driving across against the flow'):format(math.floor(first.off))
        return { x = first.pos.x, y = first.pos.y, z = first.pos.z, speed = target.speed, opposite = true, exact = true }
    end
    if same and same.off >= 1.2 and same.off <= (tonumber(Config.TruckDrawnLaneMax) or 7.0) and Config.TruckFollowDrawnLane ~= false then
        -- the drawn point lies IN a lane (not on the shoulder): keep it where the admin drew it
        ConvoySnap[veh] = ('following the lane the route was drawn in (%d m from the road line)'):format(math.floor(same.off))
        return { x = target.x, y = target.y, z = target.z, speed = target.speed, drawn = true, fx = target.fx, fy = target.fy }
    end
    if same and same.off > 4.0 then
        ConvoySnap[veh] = ('aimed at the lane %d m from the route point'):format(math.floor(same.off))
        return { x = same.pos.x, y = same.pos.y, z = same.pos.z, speed = target.speed }
    end
    ConvoySnap[veh] = 'aimed at the route point itself'
    return target
end

-- Road-following orders go out in short hops along the drawn leg (route point before -> route point being driven to): an order to a
-- point hundreds of metres away lets the game pick its own road, and at a junction that can be a side street.
ConvoyHop = ConvoyHop or {}        -- [veh] = { x, y } the hop the truck is currently driving to
local HOP_LENGTH = tonumber(Config.TruckRouteHop) or 110.0

-- slack: how many hop lengths from the point still count as "one order" (default 1.5); maxOff: how far from the drawn leg the
-- truck may be and still be walked back onto it (default 60 m)
local function hopTargetFor(veh, target, lengthOverride, slack, maxOff)
    local HOP_LENGTH = lengthOverride or HOP_LENGTH
    if HOP_LENGTH <= 0.0 then return nil end
    local vp = GetEntityCoords(veh)
    local dx, dy = target.x - vp.x, target.y - vp.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist <= HOP_LENGTH * (slack or 1.5) then return nil end   -- close enough for one order
    local hx, hy
    local fx, fy = tonumber(target.fx), tonumber(target.fy)
    if fx and fy then
        local lx, ly = target.x - fx, target.y - fy
        local len = math.sqrt(lx * lx + ly * ly)
        if len > 1.0 then
            local ux, uy = lx / len, ly / len
            local along = (vp.x - fx) * ux + (vp.y - fy) * uy
            local off = math.abs((vp.x - fx) * uy - (vp.y - fy) * ux)
            if off <= (maxOff or 60.0) then          -- the truck is on its leg: the hop is further down THE LEG, not down the line from the truck
                local at = math.max(0.0, math.min(len, along + HOP_LENGTH))
                hx, hy = fx + ux * at, fy + uy * at
            end
        end
    end
    if not hx then hx, hy = vp.x + dx / dist * HOP_LENGTH, vp.y + dy / dist * HOP_LENGTH end
    local frac = math.min(1.0, math.sqrt((hx - vp.x) ^ 2 + (hy - vp.y) ^ 2) / dist)
    return { x = hx, y = hy, z = vp.z + (target.z - vp.z) * frac, speed = target.speed, hopOf = target }
end

local function issueTruckDriveTask(ped, veh, target, soft)
    local followMode = tostring(Config.TruckRouteFollowing or 'AUTO'):upper()
    if followMode == 'EXACT' then
        -- the route as drawn: straight to the point (16777216 = ForceStraightLine), any lane, against traffic if need be
        ConvoySnap[veh] = 'following the drawn route exactly (any lane, no road rules)'
        ConvoyMission[veh] = true
        ClearPedTasks(ped)
        TaskVehicleMissionCoorsTarget(ped, veh, target.x, target.y, target.z, 4, target.speed or 15.0, TRUCK_MISSION_STYLE | 16777216, 5.0, 5.0, true)
        return
    end
    if followMode == 'ROUTE' then
        -- THE ROUTE AS BUILT: the truck is never handed to the road network (which, at a ramp, a split or a slip lane, picks the road IT
        -- prefers, not the one that was drawn). It is driven to a point a short way down the drawn leg, and on to the next one just
        -- before it gets there, so it stays on the line you built — through a ramp, a left or right lane, a divert. The hop is longer the
        -- faster the truck goes (a 90 km/h truck needs a point further ahead to steer smoothly); it keeps to its lane rules (stops for
        -- traffic, steers round blockers) but the path is the drawn one.
        local speedNow = GetEntitySpeed(veh)
        local hopLen = math.max(tonumber(Config.TruckRouteLockHopMin) or 35.0, math.min(tonumber(Config.TruckRouteLockHopMax) or 85.0, 15.0 + speedNow * 2.5))
        local hop = hopTargetFor(veh, target, hopLen, 1.05, 400.0)
        local aim = hop or target
        -- A hard left / right at the next route point: a truck driven straight at it at cruising speed cannot make the turn (it overshoots,
        -- stops across the road or reverses). The approach is slowed with the distance to the corner; the turn itself is then taken at a
        -- crawl-to-walking pace. A gentle bend (under ~50 degrees) is left alone.
        local cruise = target.speed or 15.0
        local fx, fy, nx, ny = tonumber(target.fx), tonumber(target.fy), tonumber(target.nx), tonumber(target.ny)
        if fx and fy and nx and ny then
            local ax, ay, bx, by = target.x - fx, target.y - fy, nx - target.x, ny - target.y
            local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
            if la > 1.0 and lb > 1.0 and (ax * bx + ay * by) / (la * lb) < 0.64 then
                local vp = GetEntityCoords(veh)
                local toCorner = math.sqrt((target.x - vp.x) ^ 2 + (target.y - vp.y) ^ 2)
                if toCorner < 110.0 then cruise = math.max(4.5, math.min(cruise, toCorner * 0.2)) end
            end
        end
        ConvoySnap[veh] = hop
            and ('following the route you built, hop by hop (%d m ahead on the drawn line)'):format(math.floor(hopLen))
            or 'following the route you built (last stretch to the route point)'
        ConvoyMission[veh] = true
        ConvoyHop[veh] = hop and { x = hop.x, y = hop.y, mission = true, trigger = math.max(18.0, hopLen * 0.55) } or nil
        if not soft then ClearPedTasks(ped) end
        TaskVehicleMissionCoorsTarget(ped, veh, aim.x, aim.y, aim.z, 4, cruise, TRUCK_ROAD_STYLE | 16777216, 4.0, 4.0, false)
        return
    end
    local hopped = false
    if followMode ~= 'EXACT' then
        local hop = hopTargetFor(veh, target)
        if hop then
            local lane = (followMode == 'ROADS') and hop or laneTargetFor(veh, hop)
            if lane.drawn then
                -- the route is drawn in a lane: short straight hops along the drawn line, in that lane
                local short = hopTargetFor(veh, target, tonumber(Config.TruckDrawnLaneHop) or 40.0)
                if short then
                    ConvoySnap[veh] = ('following the lane the route was drawn in, in hops of ~%d m'):format(math.floor(tonumber(Config.TruckDrawnLaneHop) or 40.0))
                    ConvoyMission[veh] = true
                    ConvoyHop[veh] = { x = short.x, y = short.y, mission = true, trigger = 22.0 }
                    if not soft then ClearPedTasks(ped) end
                    TaskVehicleMissionCoorsTarget(ped, veh, short.x, short.y, short.z, 4, target.speed or 15.0, TRUCK_ROAD_STYLE | 16777216, 4.0, 4.0, false)
                    return
                end
            end
            -- a hop that needs a crossing / straight drive is not a hop: the old single order to the real point decides that
            if not (lane.opposite or lane.exact) then
                local left = math.floor(#(GetEntityCoords(veh) - vector3(target.x, target.y, target.z)))
                ConvoySnap[veh] = ('following the drawn route in hops of ~%d m (%d m to the route point)'):format(math.floor(HOP_LENGTH), left)
                target = lane
                hopped = true
                ConvoyHop[veh] = { x = lane.x, y = lane.y }
            end
        end
    end
    if not hopped then ConvoyHop[veh] = nil end
    if hopped then
        -- already aimed at the lane next to the hop
    elseif followMode == 'ROADS' then
        ConvoySnap[veh] = 'roads only (same side)'
    else
        target = laneTargetFor(veh, target)
    end
    if target.opposite or target.exact then
        ConvoyMission[veh] = true
        ClearPedTasks(ped)
        TaskVehicleMissionCoorsTarget(ped, veh, target.x, target.y, target.z, 4, target.speed or 15.0, TRUCK_MISSION_STYLE | 16777216, 5.0, 5.0, true)
        return
    end
    if target.drawn and #(GetEntityCoords(veh) - vector3(target.x, target.y, target.z)) <= 100.0 then
        -- the last stretch to a route point that sits in a drawn lane: straight to the point, in that lane
        ConvoyMission[veh] = true
        ConvoyHop[veh] = nil
        if not soft then ClearPedTasks(ped) end
        TaskVehicleMissionCoorsTarget(ped, veh, target.x, target.y, target.z, 4, target.speed or 15.0, TRUCK_ROAD_STYLE | 16777216, 4.0, 4.0, false)
        return
    end
    ConvoyMission[veh] = false
    local speed = target.speed or 15.0
    if not soft then ClearPedTasks(ped) end   -- a hop handed on while rolling just replaces the order: no brake-and-go
    -- TaskVehicleDriveToCoordLongrange follows the road network over long
    -- distances (plain DriveToCoord loses the path once the target streams
    -- out). The stopRange (6.0) is the radius within which the task considers
    -- the destination reached.
    TaskVehicleDriveToCoordLongrange(ped, veh, target.x, target.y, target.z, speed, TRUCK_DRIVING_STYLE, 6.0)
end

-- The server tasks a truck through THREE paths at once (the convoy_target statebag handler, the taskDrive event and,
-- at a release, releaseTrucks). Each used to ClearPedTasks and re-issue the same drive task within a few
-- milliseconds of the others, which makes a truck that is pulling away from a standstill twitch and re-plan its first
-- turn — the same target arriving again inside this window is dropped.
local lastDriveIssued = {}
local DRIVE_DEDUP_MS = 1500

-- Hands a rolling truck its next hop before it reaches the current one, so it never slows down for a hop's end.
CreateThread(function()
    while true do
        Wait(500)
        for veh, hop in pairs(ConvoyHop) do
            if not DoesEntityExist(veh) then
                ConvoyHop[veh] = nil
            else
                local st = Entity(veh).state
                local target = st.convoy_truck and st.releaseHeld == false and st.convoy_target or nil
                local ped = GetPedInVehicleSeat(veh, -1)
                if not target or (ConvoyMission[veh] == true and not hop.mission) or ped == 0 or IsPedAPlayer(ped) then
                    ConvoyHop[veh] = nil
                elseif NetworkHasControlOfEntity(veh) and NetworkHasControlOfEntity(ped) and not IsEntityPositionFrozen(veh)
                    and not (ConvoyKeeperState and ConvoyKeeperState[veh] and ConvoyKeeperState[veh].direct) then
                    local pos = GetEntityCoords(veh)
                    -- (a go-to hop is handed on whatever the speed: the order ends at the hop, so a truck slowing for a bend would
                    -- otherwise stand at the end of it until the keeper noticed)
                    if (GetEntitySpeed(veh) > 2.0 or hop.mission) and #(vector2(pos.x, pos.y) - vector2(hop.x, hop.y)) < (hop.trigger or 55.0) then
                        issueTruckDriveTask(ped, veh, target, true)
                    end
                else
                    ConvoyHop[veh] = nil
                end
            end
        end
    end
end)

-- ── Closed-gate scanner ─────────────────────────────────────────────────────────────────────────────────────────
-- One scanner per NPC-driven truck, on the client that controls it, five times a second. Three probes (centre, left and right of the
-- truck's width) look ahead - further when the truck is faster - and a hit only counts when it is a real gate: a large, fixed object
-- that is not event set dressing. The truck then slows down in proportion to the distance, stops a few metres short, waits (hooting
-- now and then) and drives on again as soon as the way is clear for two scans in a row (so a gate still swinging does not flicker).
-- Waiting is capped (Config.TruckGateWaitSeconds), after which the scanner is ignored for a while. The shape test is asynchronous: its
-- result is waited for, where the old single test read it in the same frame it was started and so often saw "nothing".
ConvoyGate = ConvoyGate or {}   -- [veh] = { waiting, note } (the stuck watchdog does not count a truck waiting at a gate as stuck)
local gateScanners = {}
local gateModelCache = {}

local function isGateLike(ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) or not IsEntityAnObject(ent) then return false end
    local st = Entity(ent).state
    if st.nova_event_obj ~= nil or st.nova_prop_solid ~= nil or st.convoy_airdrop or st.convoy_stash_id ~= nil or st.convoy_id ~= nil then return false end
    local model = GetEntityModel(ent)
    local c = gateModelCache[model]
    if c == nil then
        local mn, mx = GetModelDimensions(model)
        local w = math.max(mx.x - mn.x, mx.y - mn.y)
        c = (w >= 1.8 and (mx.z - mn.z) >= 1.1)   -- cones, bins and small debris are the AI driver's own business
        gateModelCache[model] = c
    end
    return c
end

local function startGateScanner(veh, ped, netId)
    if Config.TruckGateDetection == false or gateScanners[netId] then return end
    gateScanners[netId] = true
    CreateThread(function()
        local waiting, since, ignoreUntil, clearScans, lastHorn, limited = false, nil, nil, 0, 0, false
        local function release()
            if waiting then
                waiting = false
                SetVehicleHandbrake(veh, false)
                local tgt = Entity(veh).state.convoy_target
                if tgt then issueTruckDriveTask(ped, veh, tgt) end
            elseif limited then
                local tgt = Entity(veh).state.convoy_target
                if tgt and not tgt.isCheckpoint then SetDriveTaskCruiseSpeed(ped, tgt.speed or 15.0) end
            end
            limited, since, clearScans = false, nil, 0
            ConvoyGate[veh] = nil
        end
        Wait(8000)   -- the truck is still pulling away from its start
        while DoesEntityExist(veh) and DoesEntityExist(ped) do
            Wait(200)
            local st = Entity(veh).state
            local tgt = st.convoy_target
            if not tgt then break end
            if not NetworkHasControlOfEntity(veh) or IsEntityPositionFrozen(veh) or st.cp_hold_brake or st.releaseHeld ~= false
                or GetPedInVehicleSeat(veh, -1) ~= ped then
                release()
            else
                local now = GetGameTimer()
                local speed = GetEntitySpeed(veh)
                local mn, mx = GetModelDimensions(GetEntityModel(veh))
                local half = math.max(1.2, (mx.x - mn.x) / 2.0)
                local reach = math.min(40.0, 8.0 + speed * 1.8)
                local fwd = GetEntityForwardVector(veh)
                local right = vector3(fwd.y, -fwd.x, 0.0)
                local front = GetEntityCoords(veh) + fwd * ((mx.y or 4.5) + 0.6) + vector3(0.0, 0.0, 0.7)
                local handles = {}
                for _, lat in ipairs({ 0.0, -half * 0.8, half * 0.8 }) do
                    local a = front + right * lat
                    local b = a + fwd * reach
                    handles[#handles + 1] = StartShapeTestCapsule(a.x, a.y, a.z, b.x, b.y, b.z, 0.45, 16, veh, 7)
                end
                local nearest, found = 999.0, false
                for _, h in ipairs(handles) do
                    local ret, hit, hc, ent
                    local tries = 0
                    repeat
                        local _n, _s
                        ret, hit, hc, _n, ent = GetShapeTestResult(h)
                        if ret == 1 then Wait(0) end
                        tries = tries + 1
                    until ret ~= 1 or tries > 8
                    if ret == 2 and hit == 1 and isGateLike(ent) then
                        local d = #(front - hc)
                        if d < nearest then nearest = d end
                        found = true
                    end
                end
                if found and ignoreUntil and now < ignoreUntil then found = false end

                if found then
                    clearScans = 0
                    since = since or now
                    local patience = (tonumber(Config.TruckGateWaitSeconds) or 12.0) * 1000
                    if now - since > patience then
                        ignoreUntil = now + 25000
                        release()
                        ConvoyGate[veh] = { waiting = false, note = 'waited for the gate too long - driving on' }
                    elseif nearest <= 5.5 or (nearest <= 9.0 and speed < 1.5) then
                        -- stop short of it and wait
                        if not waiting then
                            waiting = true
                            TaskVehicleTempAction(ped, veh, 6, 1500)
                        end
                        if speed < 0.6 then SetVehicleHandbrake(veh, true) end
                        if now - since > 3000 and now - lastHorn > 4000 then
                            lastHorn = now
                            StartVehicleHorn(veh, 700, GetHashKey('HELDDOWN'), false)
                        end
                        ConvoyGate[veh] = { waiting = true, note = ('waiting for a closed gate, %.0f m ahead'):format(nearest) }
                    else
                        -- slow down in proportion to the distance
                        local cruise = math.max(1.5, math.min(tgt.speed or 15.0, (nearest - 4.5) * 0.9))
                        SetDriveTaskCruiseSpeed(ped, cruise)
                        limited = true
                        ConvoyGate[veh] = { waiting = false, note = ('slowing for a gate, %.0f m ahead'):format(nearest) }
                    end
                else
                    since = nil
                    if waiting or limited then
                        clearScans = clearScans + 1
                        if clearScans >= 2 then release() end
                    end
                end
            end
        end
        ConvoyGate[veh] = nil
        gateScanners[netId] = nil
    end)
end

local function executeTruckDrive(veh, ped, point, speed)
    if not DoesEntityExist(veh) or not DoesEntityExist(ped) then return end
    local nowMs = GetGameTimer()
    local last = lastDriveIssued[veh]
    if last and nowMs - last.t < DRIVE_DEDUP_MS and last.x == point.x and last.y == point.y then return end
    lastDriveIssued[veh] = { t = nowMs, x = point.x, y = point.y }

    -- Make sure physics is unfrozen, engine is ON, and handbrake is OFF
    FreezeEntityPosition(veh, false)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleHandbrake(veh, false)
    applyTruckHeavyPhysics(veh)

    -- Enforce that the ped is securely seated in the driver's seat (-1)
    if GetVehiclePedIsIn(ped, false) ~= veh or GetPedInVehicleSeat(veh, -1) ~= ped then
        SetPedIntoVehicle(ped, veh, -1)
    end

    applyDriverProtections(ped)

    SetDriverAbility(ped, 1.0)
    -- Cautious driving profile: 0.05 aggressiveness ensures the truck yields to obstacles, stops
    -- before closed gates, avoids ramming event props and vehicles, and maintains safe following distance.
    SetDriverAggressiveness(ped, 0.05)

    -- Tactical convoy mode: avoids collisions, steers around obstacles/roadblocks,
    -- swerves into oncoming lane or shoulder to bypass blocked traffic, takes alternative routes,
    -- ignores red traffic lights, and overtakes stopped vehicles.
    local target = {
        x = point.x, y = point.y, z = point.z,
        speed = speed or point.speed or 15.0,
        isCheckpoint = point.isCheckpoint,
    }
    ClearPedTasks(ped)
    issueTruckDriveTask(ped, veh, target)

    -- Anti-stuck, gate-detection, and obstacle-avoidance watchdog thread on the controlling client
    local netId = VehToNet(veh)
    if netId then startGateScanner(veh, ped, netId) end
    if netId and not activeTruckWatchdogs[netId] then
        activeTruckWatchdogs[netId] = true
        CreateThread(function()
            local graceDeadline = GetGameTimer() + 8000
            while GetGameTimer() < graceDeadline do
                Wait(500)
                if not DoesEntityExist(veh) or not DoesEntityExist(ped) then
                    activeTruckWatchdogs[netId] = nil
                    return
                end
            end
            local stuckCounter = 0
            while DoesEntityExist(veh) and DoesEntityExist(ped) do
                Wait(1000)
                if not DoesEntityExist(veh) or not DoesEntityExist(ped) then break end

                local owner = NetworkGetEntityOwner(veh)
                if owner == cache.playerId or NetworkHasControlOfEntity(veh) then
                    local target = Entity(veh).state.convoy_target
                    if not target then break end

                    -- Re-apply heavy physics to ensure stability under collision
                    applyTruckHeavyPhysics(veh)

                    -- Anti-roll watchdog: if forced onto its side or tipped, safely upright it
                    local cfg = Config.TruckPhysics
                    if not cfg or cfg.antiRollWatchdog ~= false then
                        local roll = math.abs(GetEntityRoll(veh))
                        local pitch = math.abs(GetEntityPitch(veh))
                        if roll > 45.0 or pitch > 55.0 then
                            local h = GetEntityHeading(veh)
                            SetEntityRotation(veh, 0.0, 0.0, h, 2, true)
                            SetVehicleOnGroundProperly(veh)
                        end
                    end

                    -- Check if driver is still in vehicle seat -1
                    if GetPedInVehicleSeat(veh, -1) ~= ped then
                        if GetPedInVehicleSeat(veh, -1) == 0 then
                            -- Empty seat: request server driver recovery
                            TriggerServerEvent('nova_convoytruck:runtime:recoverDriver', netId)
                        else
                            SetPedIntoVehicle(ped, veh, -1)
                        end
                    end

                    local isFrozen = IsEntityPositionFrozen(veh)
                    local vehCoords = GetEntityCoords(veh)

                    -- Closed gates are handled by the dedicated scanner (startGateScanner above); a truck waiting at one is not "stuck".
                    local waitingAtGate = ConvoyGate[veh] ~= nil and ConvoyGate[veh].waiting == true

                    -- ── Checkpoint Smooth Approach Deceleration ──
                    local distToTarget = #(vehCoords - vector3(target.x, target.y, target.z))
                    if target.isCheckpoint then
                        if distToTarget < 80.0 and distToTarget > 12.0 then
                            local desiredCruise = distToTarget > 45.0 and 8.0 or (distToTarget > 22.0 and 4.5 or 2.8)
                            SetDriveTaskCruiseSpeed(ped, desiredCruise)
                        elseif distToTarget <= 12.0 then
                            TaskVehicleTempAction(ped, veh, 6, 2000)
                        end
                    end

                    -- ── Stuck Watchdog (Only fires if NOT patiently waiting at a closed gate) ──
                    local stuck = not isFrozen and not waitingAtGate and distToTarget > 10.0 and GetEntitySpeed(veh) < 0.6 and not (ConvoyKeeperState and ConvoyKeeperState[veh] and ConvoyKeeperState[veh].direct)

                    if stuck then
                        stuckCounter = stuckCounter + 1
                        if stuckCounter == 4 then
                            -- ~4s in: try a plain repath first without reversing
                            issueTruckDriveTask(ped, veh, Entity(veh).state.convoy_target or target)
                        elseif stuckCounter >= 7 then
                            -- ~7s in: genuine obstruction (not a gate). Low-speed controlled reverse & repath
                            TaskVehicleTempAction(ped, veh, 28, 1500) -- gentle reverse & steer
                            Wait(1600)
                            if DoesEntityExist(veh) and DoesEntityExist(ped) then
                                SetVehicleForwardSpeed(veh, 3.5)
                                issueTruckDriveTask(ped, veh, Entity(veh).state.convoy_target or target)
                            end
                            stuckCounter = 0
                        end
                    else
                        stuckCounter = 0
                    end
                else
                    Wait(2000)
                end
            end
            activeTruckWatchdogs[netId] = nil
        end)
    end
end

-- ── Driver keeper ─────────────────────────────────────────────────────────────────
-- Trucks were seen standing on the road with the engine idling, 100% health, a driver in the seat and nobody holding
-- them: the AI go-to order had ended (or never found a path) and nothing re-issued it. Every second the client that
-- controls a convoy truck checks it: still, far from its target, and no longer performing the long-range drive order
-- -> give the order again; performing it but still not moving for a long time -> re-issue it, then fall back to a
-- direct (off-road-network) drive, then a short reverse. `ConvoyKeeper[veh].note` is shown in /convoydebug.
local DRIVE_ORDER_HASH = GetHashKey('SCRIPT_TASK_VEHICLE_DRIVE_TO_COORD_LONGRANGE')
ConvoyKeeper = ConvoyKeeper or {}
ConvoyKeeperState = ConvoyKeeperState or {}   -- also read by the stuck watchdog above so the two do not undo each other

-- Straight-at-the-target drive (vehicle mission 4, "go to"): used when the road-network order keeps ending by itself,
-- i.e. the game cannot find a road path from where the truck stands to the point.
local function keeperDriveDirect(ped, veh, target)
    ConvoyMission[veh] = true
    ClearPedTasks(ped)
    TaskVehicleMissionCoorsTarget(ped, veh, target.x, target.y, target.z, 4, target.speed or 15.0, TRUCK_MISSION_STYLE, 5.0, 5.0, true)
end

CreateThread(function()
    while true do
        Wait(eventsActive() and 1000 or 3000)
        for _, veh in ipairs(eventsActive() and GetGamePool('CVehicle') or {}) do
            local st = Entity(veh).state
            local target = st.convoy_truck and st.releaseHeld == false and st.convoy_target or nil
            -- a truck waiting at a closed gate is standing on purpose (the gate scanner releases it)
            if target and NetworkHasControlOfEntity(veh) and not IsEntityPositionFrozen(veh) and not (ConvoyGate and ConvoyGate[veh] and ConvoyGate[veh].waiting) then
                local ped = GetPedInVehicleSeat(veh, -1)
                if ped ~= 0 and DoesEntityExist(ped) and not IsPedAPlayer(ped) and NetworkHasControlOfEntity(ped) then
                    local k = ConvoyKeeperState[veh]
                    if not k then k = { still = 0, last = 0, direct = false, fails = 0 }; ConvoyKeeperState[veh] = k end
                    local pos = GetEntityCoords(veh)
                    local dist = #(pos - vector3(target.x, target.y, target.z))
                    -- "still" = gone less than 4 m in the last 6 s. A truck that rocks back and forth or creeps (speed bouncing
                    -- above and below a threshold) is just as stuck as one that is dead still.
                    k.hist = k.hist or {}
                    k.hist[#k.hist + 1] = pos
                    if #k.hist > 7 then table.remove(k.hist, 1) end
                    local still = #k.hist >= 7 and #(pos - k.hist[1]) < 4.0 and dist > 12.0
                    k.still = still and (k.still + 1) or 0
                    local status = GetScriptTaskStatus(ped, DRIVE_ORDER_HASH)
                    local performing = status == 0 or status == 1 or ConvoyMission[veh] == true
                    local now = GetGameTimer()
                    if k.still == 0 then
                        k.direct, k.fails = false, 0
                        ConvoyKeeper[veh] = { note = 'idle (truck is rolling)' }
                    elseif not performing and not k.direct and k.still >= 1 and now - k.last > 3000 then
                        k.last = now
                        FreezeEntityPosition(veh, false); SetVehicleEngineOn(veh, true, true, false); SetVehicleHandbrake(veh, false)
                        if k.fails >= 1 then
                            keeperDriveDirect(ped, veh, target)
                            k.direct = true
                            ConvoyKeeper[veh] = { note = 'the road order ended again right after re-issuing (no road path) - driving straight at the target' }
                        else
                            issueTruckDriveTask(ped, veh, target)
                            k.fails = k.fails + 1
                            ConvoyKeeper[veh] = { note = ('drive order was gone after %ds still - re-issued it'):format(k.still) }
                        end
                    elseif k.still >= 5 and now - k.last > 6000 then
                        k.last = now
                        SetVehicleHandbrake(veh, false)
                        if k.direct then
                            -- driving straight is not moving it either: reverse out, then straight at the target again
                            ConvoyKeeper[veh] = { note = ('still for %ds even driving straight - reversing, then straight again'):format(k.still) }
                            CreateThread(function()
                                TaskVehicleTempAction(ped, veh, 28, 1500)
                                Wait(1600)
                                if DoesEntityExist(veh) and DoesEntityExist(ped) then keeperDriveDirect(ped, veh, target) end
                            end)
                        else
                            keeperDriveDirect(ped, veh, target)
                            k.direct = true
                            ConvoyKeeper[veh] = { note = ('still for %ds with a drive order but no movement - driving straight at the target'):format(k.still) }
                        end
                    else
                        ConvoyKeeper[veh] = ConvoyKeeper[veh] or { note = 'watching' }
                    end
                end
            elseif ConvoyKeeperState[veh] and not DoesEntityExist(veh) then
                ConvoyKeeperState[veh] = nil
                ConvoyKeeper[veh] = nil
            end
        end
    end
end)
RegisterNetEvent('nova_convoytruck:runtime:releaseTrucks', function(truckDataList)
    if truckDataList and #truckDataList > 0 then
        for _, tData in ipairs(truckDataList) do
            local ok, veh = tData.vehNetId and pcall(NetToVeh, tData.vehNetId)
            if ok and veh and tData.vehNetId and NetworkDoesNetworkIdExist(tData.vehNetId) then
                if DoesEntityExist(veh) then
                    FreezeEntityPosition(veh, false)
                    SetVehicleEngineOn(veh, true, true, false)
                    SetVehicleHandbrake(veh, false)
                    applyTruckHeavyPhysics(veh)
                    local ped = (tData.pedNetId and NetworkDoesNetworkIdExist(tData.pedNetId)) and safeNetToPed(tData.pedNetId) or GetPedInVehicleSeat(veh, -1)
                    -- ALWAYS the statebag, never a blanket argument — the
                    -- server sets this correctly per-truck (lead drives to
                    -- the point, followers escort the truck ahead of them)
                    -- via driveColumn before this event ever fires. A
                    -- single shared target here used to override that for
                    -- every truck at once, which is why every truck
                    -- independently pathfound to the same distant point
                    -- right at departure instead of the column following
                    -- itself — exactly "trucks struggling to find the
                    -- route" from the very first moment.
                    local target = Entity(veh).state.convoy_target
                    if target and ped and DoesEntityExist(ped) then
                        executeTruckDrive(veh, ped, target, target.speed or 15.0)
                    end
                end
            end
        end
    end

    for netId, _ in pairs(movingBlips) do
        -- A stale/leftover netId here (e.g. from a convoy that ended across a
        -- resource restart, before updateBlips got a chance to prune it) can
        -- make the engine's own NetToVeh conversion throw ("bad argument #2
        -- to 'tonumber' (base out of range)") instead of just returning 0 —
        -- pcall so one bad entry can't kill this whole handler for every
        -- other truck being released at the same time.
        local ok, veh = pcall(NetToVeh, netId)
        if ok and veh and NetworkDoesNetworkIdExist(netId) then
            if DoesEntityExist(veh) then
                FreezeEntityPosition(veh, false)
                SetVehicleEngineOn(veh, true, true, false)
                SetVehicleHandbrake(veh, false)
                applyTruckHeavyPhysics(veh)
                local ped = GetPedInVehicleSeat(veh, -1)
                local target = targetPoint or Entity(veh).state.convoy_target
                if target and ped and DoesEntityExist(ped) then
                    executeTruckDrive(veh, ped, target, target.speed or 15.0)
                end
            end
        end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:taskDrive', function(vehNetId, pedNetId, point, speed)
    CreateThread(function()
        local timeout = GetGameTimer() + 3000
        while not NetworkDoesNetworkIdExist(vehNetId) and GetGameTimer() < timeout do
            Wait(100)
        end
        if not NetworkDoesNetworkIdExist(vehNetId) then return end
        local veh = safeNetToVeh(vehNetId)
        if not veh or veh == 0 or not DoesEntityExist(veh) then return end

        local ped = nil
        if pedNetId and NetworkDoesNetworkIdExist(pedNetId) then
            ped = safeNetToPed(pedNetId)
        end
        if not ped or not DoesEntityExist(ped) then
            ped = GetPedInVehicleSeat(veh, -1)
        end

        local myCoords = GetEntityCoords(cache.ped or PlayerPedId())
        local vehCoords = GetEntityCoords(veh)
        local dist = #(myCoords - vehCoords)

        local owner = NetworkGetEntityOwner(veh)
        local isResponsible = (owner == cache.playerId)
        if not isResponsible and dist < 300.0 then
            local ownerPed = (owner ~= -1 and NetworkIsPlayerActive(owner)) and GetPlayerPed(owner) or 0
            local ownerDist = (ownerPed ~= 0 and DoesEntityExist(ownerPed)) and #(GetEntityCoords(ownerPed) - vehCoords) or 9999.0
            if ownerDist > 300.0 or ownerDist >= dist then
                isResponsible = true
            end
        end

        if isResponsible then
            local ctrlTimeout = GetGameTimer() + 2500
            while not NetworkHasControlOfEntity(veh) and GetGameTimer() < ctrlTimeout do
                NetworkRequestControlOfEntity(veh)
                Wait(50)
            end
            if ped and DoesEntityExist(ped) then
                local pedTimeout = GetGameTimer() + 2500
                while not NetworkHasControlOfEntity(ped) and GetGameTimer() < pedTimeout do
                    NetworkRequestControlOfEntity(ped)
                    Wait(50)
                end
            end
            if DoesEntityExist(veh) then
                ped = GetPedInVehicleSeat(veh, -1)
                if ped and DoesEntityExist(ped) then
                    executeTruckDrive(veh, ped, point, speed)
                end
            end
        end
    end)
end)

-- Column cohesion: the server slows the lead truck while a follower has
-- fallen too far behind, and restores it once the column closes up again.
-- SetDriveTaskCruiseSpeed adjusts the running drive task in place — no
-- ClearPedTasks/re-task, so no stop-start stutter.
RegisterNetEvent('nova_convoytruck:runtime:setCruise', function(vehNetId, speed)
    if not vehNetId or not NetworkDoesNetworkIdExist(vehNetId) then return end
    local veh = safeNetToVeh(vehNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) or not NetworkHasControlOfEntity(veh) then return end
    local ped = GetPedInVehicleSeat(veh, -1)
    if ped and ped ~= 0 and DoesEntityExist(ped) and not IsPedAPlayer(ped) then
        SetDriveTaskCruiseSpeed(ped, speed + 0.0)
    end
end)

-- A truck that just rolled into the destination and was delivered: drop its
-- per-truck delivery blip + marker point (the truck entity itself is
-- deleted server-side).
RegisterNetEvent('nova_convoytruck:runtime:truckDelivered', function(netId)
    if netId then
        dropTrucks[netId] = nil
        dropBlips[netId] = nil
        dropZones[netId] = nil
    end

    -- If no more trucks waiting for delivery, remove the main drop blip & interaction point
    if not next(dropTrucks) then
        if dropBlips['main'] and DoesBlipExist(dropBlips['main']) then RemoveBlip(dropBlips['main']) end
        dropBlips['main'] = nil
        if dropZones['main'] and dropZones['main'].remove then dropZones['main']:remove() end
        dropZones['main'] = nil
        pcall(function() lib.hideTextUI() end)
    end

    if netId and movingBlips[netId] then
        if DoesBlipExist(movingBlips[netId]) then RemoveBlip(movingBlips[netId]) end
        movingBlips[netId] = nil
    end
end)

-- ── own vitals → server (squad health bars) ──────────────────────────────────────
-- The squad HUD used to be built from the SERVER's read of every player's
-- ped health, which under OneSync is only as fresh as the last ped sync and
-- — more importantly — can't see a framework "downed" state at all:
-- qbx_medical (and qb/esx ambulance jobs) keep a downed/last-stand player's
-- ped alive above 100 HP, so they never registered as dead and never left
-- the list. Each client now reports its own numbers (exact, local) plus a
-- dead flag that includes the framework's own death/last-stand state.
-- Only written when something actually changed, so an idle player costs
-- nothing on the network.
CreateThread(function()
    local lastKey
    while true do
        Wait(eventsActive() and 500 or 3000)   -- only reported for the squad health bars, i.e. while an event runs
        local ped = cache.ped or PlayerPedId()
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local st = LocalPlayer.state
            local health = GetEntityHealth(ped)
            local dead = IsEntityDead(ped) or IsPedFatallyInjured(ped) or health <= 100
                or st.isDead == true or st.dead == true or st.isDowned == true or st.inLastStand == true
            -- health - 100, clamped 0-100 — NOT divided by (maxHealth - 100).
            -- Was doing that division to be "more correct" for a boosted max
            -- health, but qbx_hud's own health widget (qbx_hud/client/main.lua)
            -- just shows GetEntityHealth(ped) - 100 directly, with no max-health
            -- awareness at all. Whatever this server's actual configured max
            -- health is, qbx_hud's number is the one the player is reading and
            -- comparing against — dividing by a different max here just makes
            -- our number disagree with theirs (reported as "I have 20 health
            -- but the squad UI shows 60-70%"). Matching qbx_hud's own
            -- convention exactly is what makes the two agree.
            local hp = dead and 0 or math.max(0, math.min(100, health - 100))
            local armour = dead and 0 or math.max(0, math.min(100, GetPedArmour(ped)))
            local key = ('%d:%d:%s'):format(hp, armour, dead and 1 or 0)
            if key ~= lastKey then
                lastKey = key
                st:set('convoyVitals', { health = hp, armour = armour, dead = dead }, true)
            end
        end
    end
end)

-- ── airdrop parachute descent (client-rendered) ──────────────────────────────────
-- The descent used to be done server-side: SetEntityCoords on a networked
-- crate every 100ms (visibly stepping/jittering as each position update
-- arrived) plus a server-side AttachEntityToEntity for the chute — which
-- isn't a server native, so the pcall swallowed it and the parachute just
-- hung in the sky at its spawn height while the crate fell away beneath it.
-- Now each nearby client animates its own local (non-networked) crate +
-- chute every frame for the same duration; the server only creates the
-- real, lootable crate once the descent is over, at the same spot.
RegisterNetEvent('nova_convoytruck:runtime:airdropDescent', function(coords, crateModel, chuteModel, height, durationMs, startPos)
    local myCoords = GetEntityCoords(cache.ped or PlayerPedId())
    if #(myCoords - vec3(coords.x, coords.y, coords.z)) > 1500.0 then return end
    CreateThread(function()
        local crateHash = joaat(crateModel)
        if not pcall(lib.requestModel, crateHash, 5000) then return end
        -- startPos = where the plane actually was when it let go; the crate
        -- visibly leaves the plane from there and drifts onto the zone centre
        -- (coords) over the fall.
        local startX = startPos and startPos.x or coords.x
        local startY = startPos and startPos.y or coords.y
        local startZ = startPos and startPos.z or (coords.z + height)
        local driftVX = (coords.x - startX) / math.max(1.0, durationMs / 1000.0)
        local driftVY = (coords.y - startY) / math.max(1.0, durationMs / 1000.0)
        local crate = CreateObjectNoOffset(crateHash, startX, startY, startZ, false, false, false)
        if not crate or crate == 0 then return end
        -- Registered so a force-end mid-descent can delete this local copy
        -- immediately (see cleanupAirdropDescentCopies) instead of leaving it
        -- falling over an event that no longer exists.
        airdropDescentCopies[#airdropDescentCopies + 1] = crate
        SetEntityLodDist(crate, 1500)
        -- No one-shot flare here anymore — it fired once, right at the
        -- crate's SPAWN height, but the crate then spends several real
        -- seconds falling ~100+m away from that point. By the time it
        -- lands, the flare (and the burnt-out prop it leaves behind) is
        -- sitting wherever it happened to land near the crate's START
        -- position, nowhere near its actual final resting spot — reading
        -- as "detached from the crate," not attached to it. The persistent
        -- flare beacon in runtime_client.lua's airdropLootable handler
        -- fires repeatedly at the crate's real, current (landed) position
        -- instead, which is the one that's actually useful for finding it.

        local chute
        if chuteModel and chuteModel ~= '' then
            local chuteHash = joaat(chuteModel)
            if pcall(lib.requestModel, chuteHash, 5000) then
                chute = CreateObjectNoOffset(chuteHash, startX, startY, startZ, false, false, false)
                if chute and chute ~= 0 then
                    -- Kept collision OFF on the chute specifically (unlike the
                    -- crate below) — it's rigidly attached to the crate for
                    -- looks only, and two independently-colliding compound
                    -- physics bodies bolted together is a classic source of
                    -- jitter/flying-off-at-a-weird-angle in GTA's physics.
                    SetEntityCollision(chute, false, false)
                    SetEntityLodDist(chute, 1500)
                    AttachEntityToEntity(chute, crate, 0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
                    -- Canopy deploy animation baked into the cargo-chute model.
                    RequestAnimDict('p_cargo_chute_s')
                    local t = GetGameTimer() + 1000
                    while not HasAnimDictLoaded('p_cargo_chute_s') and GetGameTimer() < t do Wait(0) end
                    if HasAnimDictLoaded('p_cargo_chute_s') then
                        PlayEntityAnim(chute, 'p_cargo_chute_s_deploy', 'p_cargo_chute_s', 1000.0, false, false, false, 0.0, 0)
                    end
                end
            end
        end

        -- Real gravity + collision fall — concept mirrored from a reference
        -- airdrop script (cad-gundrop): ActivatePhysics + a held downward
        -- velocity, landing decided by the game's own collision detection
        -- checked every tick, instead of the previous approach (teleporting
        -- to a scripted position every frame, then ONE single ground-query
        -- at the very end). That single end-of-fall query could come back
        -- "not found" if collision at the landing spot hadn't finished
        -- streaming in yet right after the crate's big teleport-to-coords.z
        -- moment (a known FiveM timing gotcha) — with no retry after that,
        -- the crate was left sitting exactly there, floating, for good.
        -- Checking every tick as it actually falls means a momentary
        -- streaming hiccup just delays the landing detection by a tick
        -- instead of silently failing it once and for all.
        SetEntityDynamic(crate, true)
        ActivatePhysics(crate)
        SetDamping(crate, 2, 0.15) -- caps terminal fall speed so it doesn't rocket down at raw gravity accel
        local heading = math.random(0, 359) + 0.0
        SetEntityHeading(crate, heading)
        -- Flare burning on the crate for the whole descent, so the falling drop
        -- is easy to spot: a looped flare particle attached to the crate plus a
        -- red light drawn at its position each frame (both purely local/cosmetic).
        local flareFx
        pcall(function()
            RequestNamedPtfxAsset('core')
            local ft = GetGameTimer() + 1500
            while not HasNamedPtfxAssetLoaded('core') and GetGameTimer() < ft do Wait(0) end
            if HasNamedPtfxAssetLoaded('core') then
                UseParticleFxAssetNextCall('core')
                flareFx = StartParticleFxLoopedOnEntity('exp_grd_flare', crate, 0.0, 0.0, 0.4, 0.0, 0.0, 0.0, 1.6, false, false, false)
            end
        end)
        -- Descent SPEED still honours the admin's configured
        -- parachuteHeight/descendSpeed pacing (re-applied every tick, same
        -- idea as a real parachute's terminal velocity) — real collision
        -- response is what zeroes it out the instant it actually lands, so
        -- controlling the pacing and landing for real aren't mutually
        -- exclusive. "Landed" = the crate's own height stopped changing for
        -- several consecutive ticks, i.e. something solid is actually
        -- holding it up, not a guessed duration.
        -- The descent is SCRIPTED, not physics: the crate is placed every frame on the line from where the plane let go to the zone, at
        -- the pace the server announced (durationMs = height / descendSpeed). The previous version let physics do the falling and called
        -- the crate "landed" once its height had not changed for 4 checks - but a crate that never started to fall (collision under it
        -- not loaded, physics not woken up) also has an unchanging height, so it "landed" in half a second, was put on the ground at
        -- once, and the drop looked like it had appeared out of nowhere.
        FreezeEntityPosition(crate, true)
        SetEntityCollision(crate, false, false)
        local landZ = coords.z
        local nextProbe = 0
        local t0 = GetGameTimer()
        local fallMs = math.max(1500, durationMs)
        while DoesEntityExist(crate) do
            local now = GetGameTimer()
            local el = now - t0
            if el >= fallMs then break end
            -- the ground under the landing spot (its collision is requested for the whole fall; the answer sharpens the landing height)
            if now >= nextProbe then
                nextProbe = now + 400
                RequestCollisionAtCoord(coords.x, coords.y, coords.z)
                local found, gz = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 60.0, false)
                if found and gz then landZ = gz + 0.3 end
            end
            local fr = el / fallMs
            local x = startX + (coords.x - startX) * fr
            local y = startY + (coords.y - startY) * fr
            local z = startZ + (landZ - startZ) * fr
            SetEntityCoordsNoOffset(crate, x, y, z, false, false, false)
            -- a gentle swing under the canopy
            local tt = el / 1000.0
            SetEntityRotation(crate, math.sin(tt * 1.3) * 3.0, math.cos(tt * 1.1) * 3.0, heading, 2, true)
            DrawLightWithRange(x, y, z + 1.0, 255, 40, 20, 18.0, 6.0)
            Wait(0)
        end
        if DoesEntityExist(crate) then
            SetEntityCoordsNoOffset(crate, coords.x, coords.y, landZ, false, false, false)
            SetEntityCollision(crate, true, true)
            FreezeEntityPosition(crate, false)
        end
        if flareFx then pcall(StopParticleFxLooped, flareFx, false) end
        -- Belt-and-braces: real collision already settled it above in the
        -- overwhelming majority of cases (open road/field under the drop
        -- point). PlaceObjectOnGroundProperly here is just a final tidy-up
        -- for edge cases (safetyDeadline hit, or resting at a slight tilt),
        -- not the sole thing standing between "landed" and "floating" like
        -- it was before.
        pcall(PlaceObjectOnGroundProperly, crate)
        FreezeEntityPosition(crate, true)
        SetEntityRotation(crate, 0.0, 0.0, heading, 2, true)
        if chute and DoesEntityExist(chute) then
            DetachEntity(chute, false, false)
            if HasAnimDictLoaded('p_cargo_chute_s') then
                PlayEntityAnim(chute, 'p_cargo_chute_s_crumple', 'p_cargo_chute_s', 1000.0, false, false, false, 0.0, 0)
            end
        end
        -- Hold the local copy a moment so there's no visible gap while the
        -- server's real crate streams in at the same spot.
        Wait(2500)
        if chute and DoesEntityExist(chute) then DeleteEntity(chute) end
        if DoesEntityExist(crate) then DeleteEntity(crate) end
        SetModelAsNoLongerNeeded(crateHash)
    end)
end)
RegisterNetEvent('nova_convoytruck:runtime:stopTruck', function(vehNetId, pedNetId)
    if not NetworkDoesNetworkIdExist(vehNetId) then return end
    local veh = safeNetToVeh(vehNetId)
    if not DoesEntityExist(veh) then return end

    local ped = nil
    if pedNetId and NetworkDoesNetworkIdExist(pedNetId) then
        ped = safeNetToPed(pedNetId)
    end
    if not ped or not DoesEntityExist(ped) then
        ped = GetPedInVehicleSeat(veh, -1)
    end
    if ped and DoesEntityExist(ped) then
        ClearPedTasks(ped)
        TaskVehicleTempAction(ped, veh, 6, 2500) -- smooth footbrake to stop without aggressive handbrake skid
    end
end)

AddStateBagChangeHandler('convoy_target', nil, function(bagName, key, value, _unused, replicated)
    -- Same gsub multi-return gotcha as the convoy_truck handler above —
    -- string.gsub returns (result, count), and as the sole argument to
    -- tonumber(...) both were being spliced in as tonumber(id, 0-or-1),
    -- an invalid base every time. This handler fires on every truck's
    -- drive-task update (very frequent), so left alone it was one of the
    -- more consistent sources of that recurring crash.
    local netId = tonumber((bagName:gsub('entity:', '')))
    if not netId or not NetworkDoesNetworkIdExist(netId) then return end
    local veh = safeNetToVeh(netId)
    if not DoesEntityExist(veh) then return end

    local ped = nil
    if value and value.pedNetId and NetworkDoesNetworkIdExist(value.pedNetId) then
        ped = safeNetToPed(value.pedNetId)
    end
    if not ped or not DoesEntityExist(ped) then
        ped = GetPedInVehicleSeat(veh, -1)
    end

    if ped and DoesEntityExist(ped) then
        if GetPedInVehicleSeat(veh, -1) ~= ped then
            SetPedIntoVehicle(ped, veh, -1)
        end
    end

    if not NetworkHasControlOfEntity(veh) then
        NetworkRequestControlOfEntity(veh)
    end
    if ped and DoesEntityExist(ped) and not NetworkHasControlOfEntity(ped) then
        NetworkRequestControlOfEntity(ped)
    end

    local owner = NetworkGetEntityOwner(veh)
    if owner ~= cache.playerId and owner ~= -1 and NetworkIsPlayerActive(owner) and NetworkHasControlOfEntity(veh) == false then
        return
    end

    if not value then
        if ped and DoesEntityExist(ped) then
            ClearPedTasks(ped)
            TaskVehicleTempAction(ped, veh, 6, 2500)
        end
        return
    end

    -- If the truck is held during the police head-start buffer, do not drive yet
    if Entity(veh).state.releaseHeld ~= false then return end

    if not ped or not DoesEntityExist(ped) then return end
    executeTruckDrive(veh, ped, value, value.speed)
end)

AddStateBagChangeHandler('releaseHeld', nil, function(bagName, key, value)
    if value == false then
        local netId = tonumber((bagName:gsub('entity:', '')))
        if not netId or not NetworkDoesNetworkIdExist(netId) then return end
        local veh = safeNetToVeh(netId)
        if not veh or veh == 0 or not DoesEntityExist(veh) then return end
        local target = Entity(veh).state.convoy_target
        local ped = GetPedInVehicleSeat(veh, -1)
        if target and ped and DoesEntityExist(ped) then
            FreezeEntityPosition(veh, false)
            SetVehicleEngineOn(veh, true, true, false)
            SetVehicleHandbrake(veh, false)
            executeTruckDrive(veh, ped, target, target.speed or 15.0)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:truckDisabled', function(truckId, vehNetId, label)
    if vehNetId then
        local blip = movingBlips[vehNetId]
        if blip and DoesBlipExist(blip) then
            SetBlipColour(blip, 2) -- Green (GTA colour 2)
            SetBlipFlashes(blip, false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName((label or 'Convoy Truck') .. ' (Disabled)')
            EndTextCommandSetBlipName(blip)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:cleanupTruck', function(vehNetId)
    if vehNetId and NetworkDoesNetworkIdExist(vehNetId) then
        local ent = safeNetToVeh(vehNetId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local driver = GetPedInVehicleSeat(ent, -1)
            if driver and driver ~= 0 and DoesEntityExist(driver) then
                SetEntityAsMissionEntity(driver, true, true)
                DeleteEntity(driver)
            end
            SetEntityAsMissionEntity(ent, true, true)
            DeleteVehicle(ent)
            DeleteEntity(ent)
        end
    else
        local pool = GetGamePool('CVehicle')
        for _, ent in ipairs(pool) do
            if DoesEntityExist(ent) then
                local st = Entity(ent).state
                if st.convoy_truck or st.hot_cargo_truck then
                    local driver = GetPedInVehicleSeat(ent, -1)
                    if driver and driver ~= 0 and DoesEntityExist(driver) and not IsPedAPlayer(driver) then
                        SetEntityAsMissionEntity(driver, true, true)
                        DeleteEntity(driver)
                    end
                    SetEntityAsMissionEntity(ent, true, true)
                    DeleteVehicle(ent)
                    DeleteEntity(ent)
                end
            end
        end
    end
end)

AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkEntityDamage' then
        -- Fast O(1) bail out if no convoy or airdrop event is active
        if not next(movingBlips) and not next(dropBlips) and not next(airdropBlips) then return end
        local victim = args[1]
        local attacker = args[2]
        local isFatal = args[6] == 1
        local weaponHash = args[7]
        -- 1. Player casualty tracking for PvP Hijack audit
        if isFatal and victim == PlayerPedId() then
            local killerServerId = nil
            if attacker and DoesEntityExist(attacker) and IsEntityAPed(attacker) and IsPedAPlayer(attacker) then
                killerServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(attacker))
            end
            TriggerServerEvent('nova_convoytruck:runtime:playerDied', killerServerId, weaponHash)
        end

        -- 2. Hostile attacker detection (gang members shooting at convoy trucks or guards)
        if attacker == PlayerPedId() and victim and DoesEntityExist(victim) then
            local isConvoyTarget = false
            if IsEntityAVehicle(victim) then
                local netId = VehToNet(victim)
                if netId and movingBlips[netId] then isConvoyTarget = true end
            elseif IsEntityAPed(victim) then
                local group = GetPedRelationshipGroupHash(victim)
                if group == joaat('nova_convoy_npc') or group == joaat('nova_convoy_driver') then isConvoyTarget = true end
            end

            if isConvoyTarget then
                TriggerServerEvent('nova_convoytruck:runtime:reportHostileAttacker')
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for _, blip in pairs(movingBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    for _, zone in pairs(dropZones) do if zone.remove then zone:remove() end end
    for _, blip in pairs(dropBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    for _, blip in pairs(airdropBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    for _, blip in pairs(npcBlips) do if DoesBlipExist(blip) then RemoveBlip(blip) end end
    for pointId in pairs(airdropSmokeFx) do stopAirdropSmoke(pointId) end
    if checkpointBlip and DoesBlipExist(checkpointBlip) then RemoveBlip(checkpointBlip) end
    if checkpointRadiusBlip and DoesBlipExist(checkpointRadiusBlip) then RemoveBlip(checkpointRadiusBlip) end
    if stagingBlip and DoesBlipExist(stagingBlip) then RemoveBlip(stagingBlip) end
    if stagingRadiusBlip and DoesBlipExist(stagingRadiusBlip) then RemoveBlip(stagingRadiusBlip) end
    pcall(function() lib.hideTextUI() end)
    ConvoyUI.hideTimer()
    ConvoyUI.hideDeliveryTimer()
    ConvoyUI.hidePrepCountdown()
    SendNUIMessage({ action = 'gangSquadHide' })
    SendNUIMessage({ action = 'policeSquadHide' })
    SendNUIMessage({ action = 'convoyProgressHide' })
    SetPedRelationshipGroupHash(PlayerPedId(), joaat('PLAYER'))
    truckLabels = {}
    SetNuiFocus(false, false)
end)

-- ── Destroyed Truck Driver NPC Cleanup ──────────────────────────────────────────
RegisterNetEvent('nova_convoytruck:runtime:cleanupTruckDriver', function(vehNetId, pedNetId)
    if pedNetId then
        local ped = safeNetToPed(pedNetId)
        if ped ~= 0 and DoesEntityExist(ped) then
            SetEntityInvincible(ped, false)
            ClearPedTasksImmediately(ped)
            DeleteEntity(ped)
        end
    end
    if vehNetId then
        local veh = safeNetToVeh(vehNetId)
        if veh ~= 0 and DoesEntityExist(veh) then
            local driver = GetPedInVehicleSeat(veh, -1)
            if driver ~= 0 and DoesEntityExist(driver) and not IsPedAPlayer(driver) then
                SetEntityInvincible(driver, false)
                ClearPedTasksImmediately(driver)
                DeleteEntity(driver)
            end
        end
    end
end)

-- ── HUD Interaction Keybinds (X to hide, L to show, ; to toggle cursor) ─────────
local hudCursorActive = false

local hudCursorSince = 0
local function setHudCursor(state)
    hudCursorActive = state
    hudCursorSince = GetGameTimer()
    SetNuiFocus(state, state)
    SetNuiFocusKeepInput(state)
    SendNUIMessage({ action = 'hud:setCursor', enabled = state })
end

RegisterNUICallback('hud:closeCursor', function(_, cb)
    setHudCursor(false)
    cb({ ok = true })
end)

RegisterCommand('convoy_hud_cursor', function()
    setHudCursor(not hudCursorActive)
end, false)
RegisterKeyMapping('convoy_hud_cursor', 'Convoy HUD: Move / Reposition', 'keyboard', 'SEMICOLON')

-- While the HUD cursor is on, the NUI keeps the game's input (SetNuiFocusKeepInput), so without this every mouse move
-- turned the camera, every click fired the weapon and the wheel switched weapons: dragging / locking the health
-- bar looked broken. Look, attack, aim, weapon wheel and the pause menu are blocked while it is on; Esc locks the position.
CreateThread(function()
    while true do
        if hudCursorActive then
            -- A forgotten ';' must not leave the weapon dead: the mode switches itself off after 45 seconds
            if GetGameTimer() - hudCursorSince > 45000 then
                setHudCursor(false)
                pcall(function() lib.notify({ title = 'HUD cursor', description = 'The HUD cursor mode switched itself off.', type = 'inform', duration = 4000 }) end)
            end
            DisablePlayerFiring(PlayerId(), true)
            for _, ctl in ipairs({ 1, 2, 24, 25, 14, 15, 16, 17, 37, 99, 100, 140, 141, 142, 257, 263, 264, 199, 200 }) do
                DisableControlAction(0, ctl, true)
            end
            if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 199) then
                setHudCursor(false)
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- /fixcontrols - "I cannot shoot / reload": clears everything this resource can leave on the player's controls and says WHICH one was
-- stuck (also printed to the F8 console), so the cause is known if it comes back.
RegisterCommand('fixcontrols', function()
    local st = LocalPlayer.state
    local found = {}
    if hudCursorActive then found[#found + 1] = 'HUD cursor mode (the ; key)' end
    if st.invBusy == true and not NovaInPractice then found[#found + 1] = 'inventory busy lock' end
    if st.invHotkeys == false and not NovaInPractice then found[#found + 1] = 'inventory hotkeys off' end
    if st.inv_busy == true and not NovaInPractice then found[#found + 1] = 'inventory busy lock (qb)' end
    if NovaInPractice then found[#found + 1] = 'you are inside a Practice Range session (leave it with its exit)' end
    if st.isRacing == true then found[#found + 1] = 'race flag still on' end
    if not hudCursorActive and IsNuiFocused and IsNuiFocused() then found[#found + 1] = 'a window still had the mouse (NUI focus)' end
    local ped = PlayerPedId()
    local selected = GetSelectedPedWeapon(ped)
    local ammo = GetAmmoInPedWeapon(ped, selected)
    -- ox_inventory refuses to equip / reload when 'canUseWeapons' is off; qbx_core switches it off while the character is marked
    -- dead or in last stand and only switches it back on when that metadata is cleared again (a revive that skipped it leaves it off)
    local dead = IsPedDeadOrDying(ped, true)
    if st.canUseWeapons == false and not dead then
        found[#found + 1] = "ox_inventory had weapons switched off for you ('canUseWeapons' - the character is still marked dead / last stand)"
        st:set('canUseWeapons', true, true)
    end
    local oxWeapon, oxWeaponInfo
    if GetResourceState('ox_inventory') == 'started' then
        local okW, w = pcall(function() return exports.ox_inventory:getCurrentWeapon() end)
        if okW and type(w) == 'table' then
            oxWeapon = w.name or w.label or 'weapon'
            -- what the reload key needs: the weapon's own ammo item in the inventory, and a weapon that is not worn out (0 durability = it
            -- cannot fire or reload, and ox_inventory only shows a small notification for it)
            local md = type(w.metadata) == 'table' and w.metadata or {}
            local need = w.ammo
            local have
            if need then
                local okC, cnt = pcall(function() return exports.ox_inventory:Search('count', need) end)
                have = okC and cnt or '?'
            end
            oxWeaponInfo = ('ammo item the reload key needs=%s | you carry=%s | ammo stored on the weapon=%s | durability=%s | special ammo=%s'):format(
                tostring(need or 'none (melee/throwable)'), tostring(have or '-'), tostring(md.ammo), tostring(md.durability), tostring(md.specialAmmo))
        end
    end
    local inVeh = GetVehiclePedIsIn(ped, false)
    local okVW, vehWeapon = pcall(GetCurrentPedVehicleWeapon, ped)
    local detail = ('weapon in hand=%s | ox_inventory current weapon=%s | ammo in hand=%s | clip=%s | in vehicle=%s (vehicle weapon=%s) | ragdoll=%s | dead/dying=%s | canUseWeapons=%s invBusy=%s invOpen=%s | nui focused=%s | pause menu=%s'):format(
        selected == `WEAPON_UNARMED` and 'NONE (unarmed)' or tostring(selected), tostring(oxWeapon or 'NONE'), tostring(ammo),
        tostring(select(2, GetAmmoInClip(ped, selected)) or '?'), tostring(inVeh ~= 0), tostring(okVW and vehWeapon or false),
        tostring(IsPedRagdoll(ped)), tostring(dead), tostring(st.canUseWeapons), tostring(st.invBusy), tostring(st.invOpen),
        tostring(IsNuiFocused and IsNuiFocused() or false), tostring(IsPauseMenuActive()))
    print('[NovaConvoy] /fixcontrols state: ' .. detail)
    if oxWeaponInfo then print('[NovaConvoy] /fixcontrols weapon: ' .. oxWeaponInfo) end
    setHudCursor(false)
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    if not NovaInPractice then
        st:set('invBusy', false, true)
        st:set('invHotkeys', true, false)
        st:set('inv_busy', false, true)
        if GetResourceState('ox_inventory') == 'started' then pcall(function() exports.ox_inventory:weaponWheel(false) end) end
    end
    if st.isRacing == true then st:set('isRacing', false, false) end
    SetPlayerCanDoDriveBy(PlayerId(), true)
    local text = #found > 0 and ('Cleared: ' .. table.concat(found, ', ') .. '.') or 'Nothing from this script was blocking your controls.'
    if selected == `WEAPON_UNARMED` then text = text .. ' You have no weapon in hand - equip the gun from your inventory first, then run this again.'
    elseif not oxWeapon then text = text .. ' The gun in your hand is not one ox_inventory knows about.' end
    print(('[NovaConvoy] /fixcontrols: %s (ammo in the current weapon as the game sees it: %s)'):format(text, tostring(ammo)))
    pcall(function() lib.notify({ title = 'Controls', description = text .. ' Ammo in hand: ' .. tostring(ammo), type = #found > 0 and 'success' or 'inform', duration = 8000 }) end)
end, false)

-- Police escort vehicles (bought from the shop ped) are hardened by the server; the client that controls one keeps the flags that are
-- not synced between clients applied: tyres that cannot be shot flat, a strong body and axles, a fuel tank that does not leak.
CreateThread(function()
    while true do
        Wait(eventsActive() and 1500 or 4000)
        if eventsActive() then
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(veh) and Entity(veh).state.escort_hardened and NetworkHasControlOfEntity(veh) then
                    SetVehicleTyresCanBurst(veh, false)
                    SetVehicleStrong(veh, true)
                    SetVehicleHasStrongAxles(veh, true)
                    SetVehicleCanLeakPetrol(veh, false)
                    SetVehicleCanDeformWheels(veh, false)
                end
            end
        end
    end
end)

-- A Practice Range session that ended badly (crash, script restart) leaves ox_inventory locked: statebags outlive the script. Nothing
-- else in this resource sets those flags, so when the script starts and no session is running they are cleared.
CreateThread(function()
    Wait(4000)
    if NovaInPractice then return end
    local st = LocalPlayer.state
    if st.invBusy == true or st.inv_busy == true or st.invHotkeys == false then
        st:set('invBusy', false, true)
        st:set('inv_busy', false, true)
        st:set('invHotkeys', true, false)
        if GetResourceState('ox_inventory') == 'started' then pcall(function() exports.ox_inventory:weaponWheel(false) end) end
        print('[NovaConvoy] Cleared an inventory lock left over from an earlier Practice Range session.')
    end
end)

-- Chat-command fallbacks for the same three actions (a key another script already uses can swallow X / L / ;).
RegisterCommand('hudmove', function() setHudCursor(not hudCursorActive) end, false)
RegisterCommand('hudhide', function() SendNUIMessage({ action = 'hud:hideHealth' }) end, false)
RegisterCommand('hudshow', function() SendNUIMessage({ action = 'hud:showHealth' }) end, false)

RegisterCommand('convoy_hud_hide', function()
    SendNUIMessage({ action = 'hud:hideHealth' })
end, false)
RegisterKeyMapping('convoy_hud_hide', 'Convoy HUD: Hide Health Bar', 'keyboard', 'X')

RegisterCommand('convoy_hud_show', function()
    SendNUIMessage({ action = 'hud:showHealth' })
end, false)
RegisterKeyMapping('convoy_hud_show', 'Convoy HUD: Show Health Bar', 'keyboard', 'L')


-- Hot cargo truck broke down (health depleted): engine off, undriveable, no
-- explosion. The server marks it invincible/locked; this is the local side.
AddStateBagChangeHandler('hot_cargo_broken', nil, function(bagName, _, value)
    if not value then return end
    local netId = tonumber((bagName:gsub('entity:', '')))
    if not netId then return end
    CreateThread(function()
        local timeout = GetGameTimer() + 5000
        while not NetworkDoesNetworkIdExist(netId) and GetGameTimer() < timeout do Wait(100) end
        local veh = safeNetToVeh(netId)
        if veh == 0 or not DoesEntityExist(veh) then return end
        SetVehicleEngineOn(veh, false, true, true)
        SetVehicleUndriveable(veh, true)
        SetVehicleEngineHealth(veh, -4000.0)
    end)
end)

-- ── Loot / hijack prompts (ox_target) ─────────────────────────────────────────
-- Every interaction below is a GLOBAL option whose canInteract reads the
-- entity's state bags, so it works for any truck / crate whenever it is
-- streamed in — no one-shot per-entity registration that can be missed (or,
-- as it used to, silently ignored by ox_target). The server tags what is
-- lootable (convoy_stash_id / convoy_airdrop / hot_cargo_*) and re-validates
-- everything when the option is used.
local function localIsPolice()
    local r = NovaConvoy.Roles and NovaConvoy.Roles.isPolice
    if type(r) == 'function' then
        local ok, v = pcall(r)
        return ok and v == true
    end
    return r == true
end

CreateThread(function()
    Wait(1000)
    if not exports.ox_target then return end

    exports.ox_target:addGlobalVehicle({
        -- Locked Hot Cargo truck: break in (our own minigame) to hijack it.
        {
            name = 'nova_hotcargo_hijack',
            icon = 'fa-solid fa-truck-ramp-box',
            label = 'Hijack Cargo Truck',
            distance = 3.5,
            canInteract = function(entity)
                local st = Entity(entity).state
                return st.hot_cargo_truck == true and st.hot_cargo_locked == true and st.hot_cargo_broken ~= true
                    and not localIsPolice()
            end,
            onSelect = function(data)
                local st = Entity(data.entity).state
                TriggerServerEvent('nova_convoytruck:runtime:server:tryUnlockHotCargo', st.convoy_id, st.hot_cargo_truck_id)
            end,
        },
        -- Police / admins: look inside a convoy truck that is still running — no lockpick,
        -- no minigame (the server re-checks the role and Config.CapturedTruckLoot.inspectLiveTrucks).
        {
            name = 'convoy_inspect_cargo',
            icon = 'fa-solid fa-magnifying-glass',
            label = 'Inspect Truck Cargo',
            distance = 4.5,
            canInteract = function(entity)
                if not (Config.CapturedTruckLoot and Config.CapturedTruckLoot.inspectLiveTrucks ~= false) then return false end
                local st = Entity(entity).state
                if st.convoy_truck ~= true or st.convoy_stash_id ~= nil or st.convoy_truck_broken == true then return false end
                local roles = NovaConvoy.Roles
                return localIsPolice() or (roles and roles.isAdmin == true)
            end,
            onSelect = function(data)
                TriggerServerEvent('nova_convoytruck:runtime:server:inspectTruckCargo', NetworkGetNetworkIdFromEntity(data.entity))
            end,
        },
        -- Broken / disabled / lost truck (Convoy and Hot Cargo): loot its cargo.
        {
            name = 'convoy_global_hijack_loot',
            icon = 'fa-solid fa-truck-front',
            label = 'Hijack / Loot Truck',
            distance = 4.5,
            canInteract = function(entity)
                local st = Entity(entity).state
                return st.convoy_truck_broken == true or st.hot_cargo_broken == true or st.convoy_stash_id ~= nil
            end,
            onSelect = function(data)
                local st = Entity(data.entity).state
                TriggerServerEvent('nova_convoytruck:runtime:server:tryLootTruck', st.convoy_id, st.convoy_stash_id, NetworkGetNetworkIdFromEntity(data.entity))
            end,
        },
    })

    -- Crates are matched by what the server tagged them as, NOT by prop model, so
    -- a crate works whichever prop the config uses.
    exports.ox_target:addGlobalObject({
        {
            name = 'convoy_global_airdrop_crate',
            icon = 'fa-solid fa-parachute-box',
            label = 'Search Airdrop Crate',
            distance = 4.5,
            canInteract = function(entity)
                local st = Entity(entity).state
                if airdropLootedPoints and st.convoy_point_id ~= nil and airdropLootedPoints[st.convoy_point_id] then return false end
                return st.convoy_airdrop == true or st.convoy_point_id ~= nil
            end,
            onSelect = function(data)
                local st = Entity(data.entity).state
                TriggerServerEvent('nova_convoytruck:runtime:server:tryLootAirdropGlobal', st.convoy_id, st.convoy_point_id, NetworkGetNetworkIdFromEntity(data.entity))
            end,
        },
        -- Loot crates: the Hot Cargo reward crate and a destroyed truck's cargo crate.
        {
            name = 'convoy_global_loot_crate',
            icon = 'fa-solid fa-box-open',
            label = 'Search Loot Crate',
            distance = 4.5,
            canInteract = function(entity)
                local st = Entity(entity).state
                return st.convoy_stash_id ~= nil and st.convoy_airdrop ~= true
            end,
            onSelect = function(data)
                local st = Entity(data.entity).state
                TriggerServerEvent('nova_convoytruck:runtime:server:tryLootTruck', st.convoy_id, st.convoy_stash_id, NetworkGetNetworkIdFromEntity(data.entity))
            end,
        },
    })
end)
