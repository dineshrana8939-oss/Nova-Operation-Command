-- ─── Nova Convoy — NPC Support (server) ───────────────────────────────────────
-- Manages server-side NPC police & army support at checkpoints and ambushes.

NpcManager = {}

-- Tags a server-spawned ped with a relationship group by broadcasting its net
-- ID to every client, each of which resolves its own local copy and applies
-- the group hash — the ped is a networked entity, but the AI/relationship
-- state driving its behavior is simulated per-client.
local function assignPedGroup(ped, groupName, kind)
    if not ped or not DoesEntityExist(ped) then return end
    pcall(SetEntityAsMissionEntity, ped, true, true)
    local netId = 0
    for try = 1, 30 do
        if not DoesEntityExist(ped) then break end
        local okNet, id = pcall(NetworkGetNetworkIdFromEntity, ped)
        if okNet and id and id > 0 then
            netId = id
            break
        end
        Wait(50)
    end
    if netId > 0 then
        TriggerClientEvent('nova_convoytruck:client:setPedRelationshipGroup', -1, netId, groupName, kind)
    end
end

-- Tags/untags a specific player's ped as a hostile convoy participant.
-- Broadcasts to ALL clients so remote NPC owners correctly identify the player as hostile gang.
function NpcManager.setPlayerHostile(source, hostile)
    local group = hostile and 'nova_convoy_gang' or 'PLAYER'
    TriggerClientEvent('nova_convoytruck:runtime:setRelationshipGroup', source, hostile and 'nova_convoy_gang' or nil)
    TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, source, group)
end

-- Puts every on-duty officer in the police relationship group so the NPC police/army (which now shoot every
-- non-police player, see Config.NpcCombat.shootNonPolice) never target them. Officers who never joined the convoy used to be
-- plain "PLAYER" and would have been shot too. Re-sent every pass (a few officers at most) so a respawned ped or
-- an officer who left escort duty is covered; players who stopped being police go back to PLAYER.
local lastPoliceSources = {}
local liveNpcCount = 0   -- checkpoint / roadside NPCs currently spawned; the sync below only works while there are some
function NpcManager.syncPoliceGroups()
    if (Config.NpcCombat or {}).shootNonPolice == false then return end
    local now = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        local okP, isPolice = pcall(Bridge.IsPolice, src)
        if okP and isPolice then
            now[src] = true
            TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, src, 'nova_convoy_police')
        end
    end
    for src in pairs(lastPoliceSources) do
        if not now[src] then
            TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, src, 'PLAYER')
        end
    end
    lastPoliceSources = now
end

CreateThread(function()
    while true do
        -- nothing to protect officers from while no NPC police / army exist: sleep, and release the officers' group once
        if liveNpcCount > 0 then
            Wait(3000)
            pcall(NpcManager.syncPoliceGroups)
        else
            Wait(8000)
            if next(lastPoliceSources) then
                for src in pairs(lastPoliceSources) do TriggerClientEvent('nova_convoytruck:client:updatePlayerRelationship', -1, src, 'PLAYER') end
                lastPoliceSources = {}
            end
        end
    end
end)

-- Spawns NPC police/army for one checkpoint. `kind` is 'police' or 'army'.
-- Returns a list of { ped, vehicle, blip } for later cleanup.
local DEFAULTS = {
    police = { model = 's_m_y_cop_01', vehicleModel = 'police3', weapon = 'WEAPON_CARBINERIFLE', behavior = 'GUARD_CHECKPOINT' },
    army = { model = 's_m_y_marine_03', vehicleModel = 'barracks', weapon = 'WEAPON_CARBINERIFLE', behavior = 'GUARD_CHECKPOINT' },
}

-- SetPedCombatAbility/SetPedCombatRange/SetPedAccuracy/etc. are ped AI/
-- perception natives — like the client's own applyCombatCapabilities
-- (npc_relationships.lua), these only exist client-side, since the AI
-- decision loop that reads them runs on whichever client has network
-- control of the ped. Calling them here used to throw "attempt to call a
-- nil value" — for checkpoint police/army support specifically, that error
-- happened on the very FIRST ped spawned, which aborted spawnCheckpointSupport
-- entirely, which in turn killed the whole runCheckpoint call above it (see
-- handlePointReached's pcall) — so a checkpoint with NPC support enabled
-- got no banner, no map sprite, no timer, nothing, and just sat there
-- retrying forever. Airdrop guards and ambush waves (the other two callers
-- of this function) hit the exact same crash, just silently — no visible
-- symptom beyond their aggressiveness setting never actually applying.
-- Broadcasting instead, same pattern as assignPedGroup just above.
function NpcManager.applyCombatAttributes(ped, aggressiveness, isHostile)
    if not ped or not DoesEntityExist(ped) then return end
    local netId = 0
    local okNet, id = pcall(NetworkGetNetworkIdFromEntity, ped)
    if okNet and id and id > 0 then
        netId = id
    else
        for try = 1, 20 do
            if not DoesEntityExist(ped) then break end
            local okN, tryId = pcall(NetworkGetNetworkIdFromEntity, ped)
            if okN and tryId and tryId > 0 then
                netId = tryId
                break
            end
            Wait(50)
        end
    end
    if netId > 0 then
        TriggerClientEvent('nova_convoytruck:client:applyPedCombatAttributes', -1, netId, aggressiveness, isHostile)
    end
end

-- TaskGuardCurrentPosition/TaskWanderStandard/TaskCombatHatedTargetsAroundPed
-- are exactly the same story as applyCombatAttributes above — ped task/AI
-- natives that only exist client-side, because the task itself is simulated
-- locally by whichever client controls the ped. Same broadcast pattern:
-- server just tells every client "this netId, run this task."
local function assignPedTask(ped, taskName)
    if not ped or not DoesEntityExist(ped) then return end
    local netId = 0
    local okNet, id = pcall(NetworkGetNetworkIdFromEntity, ped)
    if okNet and id and id > 0 then
        netId = id
    else
        for try = 1, 20 do
            if not DoesEntityExist(ped) then break end
            local okN, tryId = pcall(NetworkGetNetworkIdFromEntity, ped)
            if okN and tryId and tryId > 0 then
                netId = tryId
                break
            end
            Wait(50)
        end
    end
    if netId > 0 then
        TriggerClientEvent('nova_convoytruck:client:applyPedTask', -1, netId, taskName)
    end
end
-- Exposed publicly — convoy_runtime.lua's Hot Cargo dropoff-guard spawn
-- needs the exact same client-side task dispatch and shouldn't duplicate it.
NpcManager.assignTask = assignPedTask

-- passive: when true, spawns these NPCs into the neutral group instead of
-- the one hostile to joined gang participants (checkpoint's gangAttackEnabled = false).
function NpcManager.spawnCheckpointSupport(kind, config, coords, count, passive)
    config = config or {}
    pcall(NpcManager.syncPoliceGroups) -- officers are marked police BEFORE these guards can see them
    local fallback = DEFAULTS[kind] or DEFAULTS.police
    local spawned = {}
    local groupName = passive and 'nova_convoy_npc_passive' or 'nova_convoy_npc'
    local pedModel = joaat(config.model or fallback.model)
    local rawVehModel = config.vehicleModel or fallback.vehicleModel
    local vehModel = rawVehModel and joaat(rawVehModel) or nil
    local shouldSpawnVehicle = false
    if config.spawnVehicle ~= nil then
        shouldSpawnVehicle = (config.spawnVehicle == true) and (vehModel ~= nil)
    elseif config.vehicleModel and config.vehicleModel ~= '' then
        shouldSpawnVehicle = true
    end

    config = {
        model = config.model or fallback.model,
        vehicleModel = rawVehModel,
        spawnVehicle = shouldSpawnVehicle,
        weapon = config.weapon or fallback.weapon,
        behavior = config.behavior or fallback.behavior,
        aggressiveness = config.aggressiveness or (kind == 'army' and 'high' or 'medium'),
    }

    local heading = coords.heading or 0.0
    local rad = math.rad(heading)
    local vehicle = nil
    local maxPassengerSeats = 0
    if config.spawnVehicle and vehModel then
        local px = coords.x + math.cos(rad + math.pi / 2) * 3.0
        local py = coords.y + math.sin(rad + math.pi / 2) * 3.0
        vehicle = CreateVehicle(vehModel, px, py, coords.z, heading, true, false)
        -- a server-created vehicle only exists a moment after the native returns; judging it at once loses the handle of a car
        -- that was created, and it then stood in the world untracked after the event
        if vehicle and vehicle ~= 0 then
            local deadline = GetGameTimer() + 3000
            while not DoesEntityExist(vehicle) and GetGameTimer() < deadline do Wait(25) end
        end
        if vehicle and DoesEntityExist(vehicle) then
            -- Both are client-only natives on some builds (a bare call threw
            -- "attempt to call a nil value" and aborted the whole NPC spawn).
            -- Fall back to a standard 4-seat layout when the seat count can't be read.
            if type(SetVehicleOnGroundProperly) == 'function' then pcall(SetVehicleOnGroundProperly, vehicle) end
            local netId = NetworkGetNetworkIdFromEntity(vehicle)
            if netId then
                TriggerClientEvent('nova_convoytruck:runtime:snapTruckToGround', -1, netId)
            end
            maxPassengerSeats = 3
            if type(GetVehicleMaxNumberOfPassengers) == 'function' then
                local okSeats, seats = pcall(GetVehicleMaxNumberOfPassengers, vehicle)
                if okSeats and tonumber(seats) then maxPassengerSeats = tonumber(seats) end
            end
        end
    end

    local totalPeds = count or 4
    local vehicleAssigned = false
    for i = 1, totalPeds do
        local ped = nil
        local seatIndex = i - 2 -- i=1 -> -1 (driver), i=2 -> 0, i=3 -> 1, i=4 -> 2, ...
        if vehicle and DoesEntityExist(vehicle) and seatIndex < maxPassengerSeats then
            ped = CreatePedInsideVehicle(vehicle, 4, pedModel, seatIndex, true, false)
        end
        if not ped or not DoesEntityExist(ped) or ped == 0 then
            local angle = rad + ((i - 1) * (2 * math.pi / math.max(totalPeds, 1)))
            local dist = 3.0 + ((i % 3) * 1.5)
            ped = CreatePed(4, pedModel, coords.x + math.cos(angle) * dist, coords.y + math.sin(angle) * dist, coords.z, heading, true, false)
        end
        if ped and DoesEntityExist(ped) then
            assignPedGroup(ped, groupName, kind)
            NpcManager.applyCombatAttributes(ped, config.aggressiveness, not passive)
            if config.weapon then
                GiveWeaponToPed(ped, joaat(config.weapon), 250, false, true)
            end
            if config.behavior == 'PATROL_AREA' then
                assignPedTask(ped, 'wander')
            elseif config.behavior == 'FOLLOW_CONVOY' then
                -- handled by convoy_runtime re-issuing TaskGoToCoord toward the truck each tick
            else
                assignPedTask(ped, 'guard')
            end
            local vToAssign = nil
            if vehicle and not vehicleAssigned then
                vToAssign = vehicle
                vehicleAssigned = true
            end
            spawned[#spawned + 1] = { ped = ped, vehicle = vToAssign, counted = true }
            liveNpcCount = liveNpcCount + 1
        end
    end

    if vehicle and DoesEntityExist(vehicle) then
        if not vehicleAssigned then
            if #spawned > 0 then
                spawned[1].vehicle = vehicle
            else
                DeleteEntity(vehicle)
            end
        end
    end

    return spawned
end

-- Spawns a wave of hostile-to-everyone NPCs around `coords` for an AMBUSH
-- route point / airdrop guard detail. Returns { ped = ... } entries, same
-- shape as checkpoint support, for NpcManager.cleanup.
--
-- NOTE on why the spawn maths changed: guards used to be scattered 8-20m
-- from the drop in a full 360-degree ring, which could put them INSIDE a
-- building, on the far side of a wall, or spread so wide they never
-- perceived the crate area at all — and a ped whose combat task has nothing
-- it can actually see just stands there. They now ring the crate at a tight,
-- wall-checked radius so they genuinely surround what they're guarding.
function NpcManager.spawnAmbushers(coords, count, config)
    config = config or {}
    local fixedModel = config.model and joaat(config.model) or nil
    -- A pool of ped model NAMES (not hashes yet — hashed per-guard below so
    -- each one can roll independently) to pick from at random when no single
    -- `model` override is set. Gives guards visual variety (a believable mix
    -- of GTA V mercenary/security-styled peds) instead of every guard on a
    -- drop being an identical clone.
    local modelPool = (type(config.models) == 'table' and #config.models > 0) and config.models or nil
    local weapon = joaat(config.weapon or 'WEAPON_MICROSMG')
    local aggressiveness = config.aggressiveness or 'high'
    -- Total guards to place. The tablet sends this straight through (see
    -- spawnAirdrop/spawnAirdropZone), so an admin-configured 0 means "no
    -- guards" and is honoured rather than silently becoming a default wave.
    local total = tonumber(count) or 4
    if total <= 0 then return {} end

    local spawned = {}
    -- Widened from 14.0, then again from 20.0 — relationship groups (and
    -- SetCanAttackFriendly) only control whether a ped VOLUNTARILY shoots
    -- at another ped; they don't make bullets pass through allies
    -- harmlessly. A tight ring all converging fire on one external target
    -- (the player) reliably has far-side guards shooting straight through
    -- where near-side guards are standing, which reads as "guards shooting
    -- each other/themselves" regardless of how correct the relationship
    -- setup and friendly-fire flag are — this was STILL being reported
    -- after both of those were fixed, meaning physical bullet-crossing
    -- (not a relationship/AI-decision bug) is the remaining cause. More
    -- spacing reduces how often a shot aimed at the player's position
    -- crosses another guard's hitbox on the way.
    local ringRadius = tonumber(config.ringRadius) or 28.0

    -- If this guard detail is protecting an airdrop placed directly on a
    -- convoy's driven route (config.avoidHeading = that route point's
    -- heading), center the ring a short distance off to one side of the
    -- road instead of directly on top of it. Guards standing/fighting in
    -- the exact travel lane put GTA's own vehicle AI (the SteerAroundPeds
    -- driving flag every convoy truck uses) into a moving obstacle course
    -- every time a truck rolls through — the likely cause behind "the
    -- convoy freezes/swerves/reverses right as an airdrop triggers." The
    -- crate itself still lands exactly where configured; only the hostile
    -- guard cluster moves aside — they still detect/engage anyone near the
    -- crate via their own seeing range, so nothing about the gameplay
    -- (guarding the drop) changes, only where they physically stand.
    local ringCenter = coords
    if config.avoidHeading then
        local perpRad = math.rad(tonumber(config.avoidHeading) + 90.0)
        local side = math.random() < 0.5 and 1 or -1
        local offset = (tonumber(config.avoidDistance) or 12.0) * side
        ringCenter = { x = coords.x + math.cos(perpRad) * offset, y = coords.y + math.sin(perpRad) * offset, z = coords.z }
    end

    -- Resolves a ground Z for (x,y), starting near z+5 and, if that comes
    -- back implausibly far from the crate's own height (steep/uneven
    -- terrain, or the ring position landed over a dip/ledge), retries pulled
    -- progressively closer to the crate instead of trusting a bad result.
    -- Falls back to the crate's own Z if ground can't be resolved at all —
    -- on flat ground that's correct anyway, and it's still safer than a
    -- wildly wrong height from a failed query.
    local function resolveGuardZ(x, y, fallbackZ)
        if type(GetGroundZFor_3dCoord) ~= 'function' then return fallbackZ end
        local okG, foundGround, groundZ = pcall(GetGroundZFor_3dCoord, x, y, fallbackZ + 20.0, false)
        if okG and foundGround and groundZ and math.abs(groundZ - fallbackZ) < 25.0 then
            return groundZ
        end
        return fallbackZ
    end

    for i = 1, total do
        -- Evenly distributed around the crate with a small jitter so the ring
        -- doesn't look mechanically perfect, rather than one uniform random
        -- angle per ped (which could clump several guards onto the same spot
        -- and leave a whole side of the drop unguarded).
        local angle = ((i - 1) / total) * 2 * math.pi + (math.random() * 0.5)
        local baseDist = ringRadius * (0.7 + math.random() * 0.5)
        local center = ringCenter
        local pedModel = fixedModel or (modelPool and joaat(modelPool[math.random(#modelPool)])) or joaat('g_m_y_lost_01')

        -- On steep/uneven terrain, a ring position 10-14m out from the crate
        -- can land at a wildly different height than the crate itself — the
        -- old single-attempt spawn placed the ped at that bad height anyway,
        -- which either failed CreatePed outright or dropped the ped inside
        -- solid geometry (killed on the spot, no error either way — exactly
        -- "configured 10 guards, only 2 ever showed up, no console error").
        -- This retries progressively closer to the crate (where the terrain
        -- is far more likely to match the crate's own height) until a guard
        -- actually spawns alive, instead of silently giving up on that slot.
        local ped
        -- config.positions = the caller chose every standing spot ({ x, y, z, heading } per guard): used as given, no ring maths
        local fixedPos = config.positions and config.positions[i]
        for attempt, distFactor in ipairs(fixedPos and { 1.0 } or { 1.0, 0.6, 0.3 }) do
            local x, y, z, facing
            if fixedPos then
                x, y, z, facing = fixedPos.x, fixedPos.y, fixedPos.z, fixedPos.heading
            else
                local dist = baseDist * distFactor
                x = center.x + math.cos(angle) * dist
                y = center.y + math.sin(angle) * dist
                z = resolveGuardZ(x, y, center.z)
            end
            local candidate = CreatePed(4, pedModel, x, y, z, (facing or (math.random(0, 359) + 0.0)), true, false)
            if candidate and candidate ~= 0 and DoesEntityExist(candidate) then
                pcall(SetEntityMaxHealth, candidate, 200)
                pcall(SetEntityHealth, candidate, 200)
                pcall(SetPedArmour, candidate, 100)
                ped = candidate
                break
            end
            Wait(20)
        end

        if ped then
            -- Both of these threw "attempt to call a nil value" server-side on
            -- this build (confirmed in fxserver.log: "spawnAirdrop error ...
            -- attempt to call a nil value (global 'SetEntityAsMissionEntity')"),
            -- which aborted this function on the FIRST guard ped every single
            -- time — airdrop/ambush guards were configured but never actually
            -- spawned, with the only symptom being the pcall'd error print in
            -- the caller (spawnAirdrop/spawnAirdropZone).
            pcall(SetEntityAsMissionEntity, ped, true, true)
            pcall(SetPedAsEnemy, ped, true)
            -- Tagged the same way spawnAirdropZone tags its crate prop
            -- (Entity(...).state:set('convoy_airdrop', ...)) — SetEntityAs
            -- MissionEntity(ped, true, true) above is exactly what stops
            -- this ped from being auto-deleted when the resource restarts
            -- (that's the whole reason it's called), so a crash or a
            -- restart landing mid-cleanup can orphan it with nothing left
            -- anywhere in Lua state pointing back to it. The state bag lets
            -- the resource-start sweep below find and remove it purely from
            -- what's physically in the world, independent of whatever
            -- in-memory bookkeeping did or didn't survive.
            pcall(function() Entity(ped).state:set('convoy_ambush_ped', true, true) end)
            assignPedGroup(ped, config.groupName or 'nova_convoy_ambush', 'ambush')
            NpcManager.applyCombatAttributes(ped, aggressiveness, config.hostile ~= false)   -- hostile = shoots anyone (default); false = selective
            if weapon then
                -- Verified + retried once — a weapon asset that hadn't
                -- finished streaming in on the FIRST GiveWeaponToPed call can
                -- silently leave the ped unarmed with no error at all.
                -- HasPedGotWeapon is CLIENT-only (same class of bug as
                -- SetEntityAsMissionEntity above) — a bare call here threw
                -- "attempt to call a nil value" uncaught, which aborted this
                -- entire `for i = 1, total do` loop on guard #1 every time:
                -- "configured 10 guards, only 1 ever spawned" was this
                -- crashing the loop, not the loop actually running 10 times.
                GiveWeaponToPed(ped, weapon, 500, false, true)
                SetCurrentPedWeapon(ped, weapon, true)
                local okHas, hasWeapon = pcall(HasPedGotWeapon, ped, weapon, false)
                if not (okHas and hasWeapon) then
                    Wait(0)
                    GiveWeaponToPed(ped, weapon, 500, false, true)
                    SetCurrentPedWeapon(ped, weapon, true)
                end
            end
            -- Both tasks: 'guard' gives the ped a home position so it stays
            -- defending the crate instead of chasing a target across the
            -- county, and 'combat' is what actually makes it engage. These
            -- are issued by every client (assignPedTask broadcasts) and are
            -- re-issued by the npc_relationships watchdog, which is what
            -- picks the ped up once somebody takes network control of it.
            assignPedTask(ped, 'guard')
            assignPedTask(ped, 'combat')
            -- netId resolved so callers (spawnAirdrop/spawnAirdropZone) can
            -- broadcast a per-guard map blip once a player enters the drop
            -- zone — this list previously only carried `ped` (a local
            -- server-side handle, meaningless to any client).
            local netId = 0
            local okNet, id = pcall(NetworkGetNetworkIdFromEntity, ped)
            if okNet and id and id > 0 then netId = id end
            spawned[#spawned + 1] = { ped = ped, netId = netId }
        end
        Wait(50)
    end

    return spawned
end

-- ── Admin-defined spawn zones ───────────────────────────────────────────────────

function NpcManager.getZones(kind)
    local zones = {}
    for _, row in ipairs(DB.getAllSpawnZones()) do
        if not kind or row.type == kind then
            zones[#zones + 1] = { id = row.id, label = row.label, type = row.type, x = row.x, y = row.y, z = row.z, radius = row.radius }
        end
    end
    return zones
end

function NpcManager.getZone(id)
    -- tostring() comparison, not ==: a zone id picked from a tablet <select>
    -- round-trips through Svelte/JSON as a string, while DB.getAllSpawnZones's
    -- row.id is a real Lua number from the SQL column — "5" == 5 is false in
    -- Lua (no auto-coercion), so a checkpoint's configured npcPolice/army
    -- zoneId silently matched nothing here, falling through to the NPC_SPAWN
    -- route-point fallback (or nothing, if that's also absent) even though
    -- the admin genuinely picked a real zone.
    for _, row in ipairs(DB.getAllSpawnZones()) do
        if tostring(row.id) == tostring(id) then
            return { id = row.id, label = row.label, type = row.type, x = row.x, y = row.y, z = row.z, radius = row.radius }
        end
    end
    return nil
end

function NpcManager.randomPointInZone(zone)
    local angle = math.random() * 2 * math.pi
    local dist = math.sqrt(math.random()) * (zone.radius or 25.0)
    return { x = zone.x + math.cos(angle) * dist, y = zone.y + math.sin(angle) * dist, z = zone.z, heading = math.random(0, 359) + 0.0 }
end

function NpcManager.cleanup(spawnedList)
    for _, entry in ipairs(spawnedList or {}) do
        if entry.counted then entry.counted = false; liveNpcCount = math.max(0, liveNpcCount - 1) end
        if entry.ped and DoesEntityExist(entry.ped) then DeleteEntity(entry.ped) end
        if entry.vehicle and DoesEntityExist(entry.vehicle) then DeleteEntity(entry.vehicle) end
    end
end

return NpcManager
