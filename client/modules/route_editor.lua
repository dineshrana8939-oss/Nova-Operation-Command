-- ─── Nova Convoy — Route & Checkpoint Editor (client) ──────────────────────
-- Route preview blips, point positioning, and the in-world preview of a checkpoint's barricades / decor vehicles.
-- Placing and moving props is done by the shared Prop Placer (prop_placer.lua) — nothing here places anything.

local previewBlips = {}
local previewGeneration = 0
local activeBarricadePreviews = {}

-- lib.requestModel throws (doesn't return false) when the model is invalid —
-- a bad/typo'd model string stored on a checkpoint (or picked from an admin-
-- configured catalog) used to take the ENTIRE placer session down with it
-- (uncaught error = the NUI callback never reaches cb(), which is its own
-- "stuck, can't get back to the tablet" failure mode). This turns that into
-- a clean skip + one-time warning instead.
local function requestModelSafe(model)
    local ok = pcall(lib.requestModel, model)
    if not ok then
        lib.notify({ title = 'Invalid Model', description = ('Model %s could not be loaded — skipped.'):format(tostring(model)), type = 'error', duration = 4000 })
    end
    return ok
end

-- ── Ox_target removal for placed barricade props ───────────────────────────────
-- Manual-placement barricades are real, frozen prop entities only while the
-- admin is viewing them in-world (the stable source of truth is the saved
-- cp.barricadeProps list in the tablet). To let an admin just AIM at a prop and
-- delete it (instead of only hunting it in the tablet list), each preview
-- entity gets an ox_target option wired to a shared removal handler. The
-- handler is a plain function so both the in-world option and any future caller
-- route through the exact same notify + cleanup path.
local TGT = exports.ox_target
local previewPropMeta = {} -- entity handle -> { cpKey = ..., index = ... }
local activeTargetEntities = {} -- entity handles with a live ox_target option

-- Notifies the tablet (which may be minimised/hidden) that a prop was removed
-- in-world, so its stored list stays in sync and doesn't resurrect the prop on
-- the next save. Removing in-world always removes it from the SAVED list too —
-- otherwise the next preview would just respawn everything the admin deleted.
local function notifyPropRemoved(meta)
    SendNUIMessage({
        action = 'barricadePropRemovedInWorld',
        cpKey = meta.cpKey,
        index = meta.index,
    })
end
-- "Edit" in the world hands the very prop over to the shared Prop Placer: the tablet (which owns the checkpoint's
-- lists) opens it on that checkpoint with this prop already selected.
local function requestPlacerEdit(kind, meta)
    if not meta then return end
    SendNUIMessage({ action = 'propEditRequested', kind = kind, cpKey = meta.cpKey, index = meta.index })
end
local function registerPropTarget(ent, meta)
    if not ent or not DoesEntityExist(ent) then return end
    previewPropMeta[ent] = meta
    -- Per-entity prompts go through NovaConvoy.AddEntityTarget (target_util.lua), which
    -- picks the right ox_target API. Both options are admin-facing edits
    -- (remove / reposition) of a saved checkpoint prop.
    NovaConvoy.AddEntityTarget(ent, {
        {
            label = 'Edit in Prop Placer',
            icon = 'fa-solid fa-arrows-up-down-left-right',
            distance = 2.5,
            onSelect = function()
                requestPlacerEdit('object', previewPropMeta[ent])
            end,
        },
        {
            label = 'Remove Barricade Prop',
            icon = 'fa-solid fa-trash',
            distance = 2.5,
            onSelect = function()
                local m = previewPropMeta[ent]
                if DoesEntityExist(ent) then
                    DeleteEntity(ent)
                end
                PlaySoundFrontend(-1, 'CANCEL', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                lib.notify({ title = 'Prop Removed', description = 'Barricade prop deleted.', type = 'inform', duration = 2500 })
                if m then notifyPropRemoved(m) end
            end,
        },
    })
    activeTargetEntities[#activeTargetEntities + 1] = ent
end
local function clearPropTargets()
    for _, ent in ipairs(activeTargetEntities) do
        -- Entity may already be deleted; removeEntity on a dead handle is
        -- harmless in ox_target, but the existence guard avoids any log noise.
        if DoesEntityExist(ent) then NovaConvoy.RemoveEntityTarget(ent) end
    end
    activeTargetEntities = {}
    previewPropMeta = {}
end

-- ── Checkpoint decor vehicles (police/army cars placed for ambience) ───────────
-- Same idea as the barricade props above — an admin walks the interactive
-- placer or drops one at their own position, it's saved onto the checkpoint
-- (cp.decorVehicles), and spawnCheckpointVehicles (convoy_runtime.lua) spawns
-- the real, server-authoritative, locked-down copies once the event runs.
-- Kept as an entirely separate meta/target-entity/preview-list set from the
-- barricade props above so toggling one preview off never touches the other's
-- ox_target options.
local previewVehicleMeta = {}
local activeVehicleTargetEntities = {}
local activeVehiclePreviews = {}

local function notifyVehicleRemoved(meta)
    SendNUIMessage({ action = 'decorVehicleRemovedInWorld', cpKey = meta.cpKey, index = meta.index })
end
-- "Can't be taken by anyone" — locked shut (10 = nobody can even enter, not
-- just a smash-the-window-and-hotwire lock), engine off, undriveable, frozen
-- in place, and invincible so it can't be blown up out from under the
-- checkpoint either. Applied to every preview/ghost copy here AND to the
-- real runtime copies spawned server-side (see spawnCheckpointVehicles).
local function lockDecorVehicle(veh)
    if not DoesEntityExist(veh) then return end
    SetVehicleDoorsLocked(veh, 10)
    SetVehicleEngineOn(veh, false, true, true)
    SetVehicleUndriveable(veh, true)
    FreezeEntityPosition(veh, true)
    SetEntityInvincible(veh, true)
end

local function registerVehicleTarget(ent, meta)
    if not ent or not DoesEntityExist(ent) then return end
    previewVehicleMeta[ent] = meta
    NovaConvoy.AddEntityTarget(ent, {
        {
            label = 'Edit in Prop Placer',
            icon = 'fa-solid fa-arrows-up-down-left-right',
            distance = 2.5,
            onSelect = function()
                requestPlacerEdit('vehicle', previewVehicleMeta[ent])
            end,
        },
        {
            label = 'Remove Decor Vehicle',
            icon = 'fa-solid fa-trash',
            distance = 2.5,
            onSelect = function()
                local m = previewVehicleMeta[ent]
                if DoesEntityExist(ent) then
                    DeleteEntity(ent)
                end
                PlaySoundFrontend(-1, 'CANCEL', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                lib.notify({ title = 'Vehicle Removed', description = 'Decor vehicle deleted.', type = 'inform', duration = 2500 })
                if m then notifyVehicleRemoved(m) end
            end,
        },
    })
    activeVehicleTargetEntities[#activeVehicleTargetEntities + 1] = ent
end
local function clearVehicleTargets()
    for _, ent in ipairs(activeVehicleTargetEntities) do
        if DoesEntityExist(ent) then NovaConvoy.RemoveEntityTarget(ent) end
    end
    activeVehicleTargetEntities = {}
    previewVehicleMeta = {}
end
local function clearVehiclePreviews()
    clearVehicleTargets()
    for _, ent in ipairs(activeVehiclePreviews) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    activeVehiclePreviews = {}
end

local TYPE_SPRITE = {
    AIRDROP = 501,
    NPC_SPAWN = 141,
    POLICE_SPAWN = 141,
    ARMY_SPAWN = 141,
}

local TYPE_COLOR = {
    START = 2,          -- green
    ROUTE = 3,           -- blue
    CHECKPOINT = 5,       -- yellow
    AIRDROP = 27,         -- light blue
    DESTINATION = 1,      -- red
    NPC_SPAWN = 38,       -- dark blue
    POLICE_SPAWN = 38,
    ARMY_SPAWN = 25,
}

local function clearPreview()
    previewGeneration = previewGeneration + 1
    for _, blip in ipairs(previewBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    previewBlips = {}
end

local function clearBarricadePreviews()
    clearPropTargets()
    for _, ent in ipairs(activeBarricadePreviews) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    activeBarricadePreviews = {}
end

-- Resolve localized zone name for coordinates
RegisterNUICallback('getZoneName', function(data, cb)
    if not data or not data.x then cb({ name = nil }) return end
    local zone = GetNameOfZone(data.x, data.y, data.z or 0.0)
    local label = zone and GetLabelText(zone) or nil
    if not label or label == 'NULL' or label == '' then label = zone end
    cb({ name = label })
end)

-- Ground height under a point picked on the tablet map. The map only knows x/y, so a dragged / clicked point used to keep
-- a stale z (the old point's, or the admin's own height wherever they stood) - and when the point was moved to higher ground
-- the vector ended up far UNDER the surface. Now:
--   1. the area around the point is streamed in (focus + a load scene), then the surface is probed;
--   2. an old height is only trusted when it is not below the terrain there (otherwise a point that already sat underground would
--      keep "finding" ground next to its own wrong height);
--   3. when the collision never loads, the game's terrain heightmap (works without collision) is used instead of keeping the
--      old height, so a point never stays in the underworld. Bridges and roofs resolve once their collision is loaded.
-- One lookup at a time.
local groundZBusy = false
local function probeGroundZ(x, y, hint)
    while groundZBusy do Wait(50) end
    groundZBusy = true
    local result = { found = false }
    local ok = pcall(function()
        -- the terrain height here, known without any collision (an approximation of the surface; never the underworld)
        local okH, heightmap = pcall(GetHeightmapTopZForPosition, x, y)
        if not okH or type(heightmap) ~= 'number' or heightmap < -190.0 or heightmap > 1500.0 then heightmap = nil end
        -- an old height far below the terrain is not a hint, it is the very bug being fixed
        if hint and heightmap and hint < heightmap - 15.0 then hint = nil end
        local startZ = hint or (heightmap and heightmap + 5.0) or 100.0

        SetFocusPosAndVel(x, y, startZ + 50.0, 0.0, 0.0, 0.0)
        pcall(NewLoadSceneStartSphere, x, y, startZ, 120.0, 0)
        local deadline = GetGameTimer() + 5000
        while GetGameTimer() < deadline do
            RequestCollisionAtCoord(x, y, startZ)
            -- first the surface just below the old height (keeps a road under a bridge / a floor under a roof when the
            -- old z was close), then from far above (the highest surface: hills and mountains)
            local near, nz = GetGroundZFor_3dCoord(x, y, startZ + 40.0, false)
            local top, tz = GetGroundZFor_3dCoord(x, y, 1100.0, false)
            if near and (not hint or math.abs(nz - hint) <= 60.0) and (not heightmap or nz >= heightmap - 15.0) then
                result = { found = true, z = nz }
                break
            elseif top and (not heightmap or tz >= heightmap - 15.0) then
                result = { found = true, z = tz }
                break
            end
            Wait(100)
        end
        pcall(NewLoadSceneStop)
        if not result.found and heightmap then
            result = { found = true, z = heightmap + 0.3, approx = true }   -- collision did not load in time: the terrain surface
        end
    end)
    ClearFocus()
    groundZBusy = false
    return ok and result or { found = false }
end

RegisterNUICallback('getGroundZ', function(data, cb)
    if not data or data.x == nil or data.y == nil then cb({ found = false }) return end
    cb(probeGroundZ((tonumber(data.x) or 0.0) + 0.0, (tonumber(data.y) or 0.0) + 0.0, tonumber(data.z)))
end)

RegisterNUICallback('getPlayerPosition', function(_, cb)
    local ped = cache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    cb({ x = coords.x, y = coords.y, z = coords.z, heading = heading })
end)

-- Every map builder (convoy, hot cargo, airdrop, rally, TDM, crackdown, container wars, territory) sends a map-picked x/y with whatever
-- z it had - often 0, the old point's, or a guess - so teleporting there dropped the admin under the map. A missing / zero z, or one
-- far below the terrain at that spot, is replaced by the real ground height first; a z that is sensible (roof, bridge, interior) is kept.
-- The ped is held still until the collision around the new spot has loaded, so there is no falling through.
RegisterNUICallback('teleportToPosition', function(data, cb)
    if not data or not data.x then cb('ok') return end
    local x, y, z = data.x + 0.0, data.y + 0.0, tonumber(data.z)
    local okH, hm = pcall(GetHeightmapTopZForPosition, x, y)
    if not okH or type(hm) ~= 'number' or hm < -190.0 or hm > 1500.0 then hm = nil end
    if not z or math.abs(z) < 0.01 or (hm and z < hm - 15.0) then
        local g = probeGroundZ(x, y, z)
        if g.found then z = g.z + 1.0 else z = (hm or 100.0) + 1.0 end
    end
    local ped = cache.ped or PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local entity = veh ~= 0 and veh or ped
    FreezeEntityPosition(entity, true)
    SetEntityCoords(entity, x, y, z + 0.0, false, false, false, true)
    if data.heading then SetEntityHeading(entity, data.heading + 0.0) end
    RequestCollisionAtCoord(x, y, z)
    local timeout = GetGameTimer() + 4000
    while not HasCollisionLoadedAroundEntity(entity) and GetGameTimer() < timeout do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end
    FreezeEntityPosition(entity, false)
    cb('ok')
end)

-- Spawns temporary preview barricades in the game world while editing in tablet.
-- Each prop also gets an ox_target "Remove Barricade Prop" option (admin-only),
-- so a prop placed in the wrong spot can be deleted by aiming at it in-world
-- instead of only through the tablet's own list. cpKey identifies WHICH
-- checkpoint this preview belongs to, so the removal message the UI receives
-- can be routed back to the right stashed prop list.
RegisterNUICallback('previewCheckpointBarricades', function(data, cb)
    clearBarricadePreviews()
    local cpKey = data and data.cpKey
    for idx, p in ipairs(data and data.props or {}) do
        local m = joaat(p.model or 'prop_barrier_work05')
        if requestModelSafe(m) then
            local ent = CreateObject(m, p.x, p.y, p.z, false, false, false)
            if ent and DoesEntityExist(ent) then
                SetEntityHeading(ent, p.heading or 0.0)
                if tonumber(p.rx) or tonumber(p.ry) then SetEntityRotation(ent, (tonumber(p.rx) or 0.0) + 0.0, (tonumber(p.ry) or 0.0) + 0.0, (p.heading or 0.0) + 0.0, 2, true) end
                FreezeEntityPosition(ent, true)
                activeBarricadePreviews[#activeBarricadePreviews + 1] = ent
                registerPropTarget(ent, { cpKey = cpKey, index = idx })
            end
            SetModelAsNoLongerNeeded(m)
        end
    end
    cb('ok')
end)

RegisterNUICallback('clearCheckpointBarricadesPreview', function(_, cb)
    clearBarricadePreviews()
    cb('ok')
end)

-- Spawns temporary preview decor vehicles in the game world while editing in
-- the tablet — same idea as previewCheckpointBarricades above, just vehicles.
RegisterNUICallback('previewCheckpointDecorVehicles', function(data, cb)
    clearVehiclePreviews()
    local cpKey = data and data.cpKey
    for idx, v in ipairs(data and data.vehicles or {}) do
        local m = joaat(v.model or 'police')
        if requestModelSafe(m) then
            local ent = CreateVehicle(m, v.x, v.y, v.z, v.heading or 0.0, false, false)
            if ent and DoesEntityExist(ent) then
                lockDecorVehicle(ent)
                if tonumber(v.rx) or tonumber(v.ry) then SetEntityRotation(ent, (tonumber(v.rx) or 0.0) + 0.0, (tonumber(v.ry) or 0.0) + 0.0, (v.heading or 0.0) + 0.0, 2, true) end
                activeVehiclePreviews[#activeVehiclePreviews + 1] = ent
                registerVehicleTarget(ent, { cpKey = cpKey, index = idx })
            end
            SetModelAsNoLongerNeeded(m)
        end
    end
    cb('ok')
end)

RegisterNUICallback('clearCheckpointDecorVehiclesPreview', function(_, cb)
    clearVehiclePreviews()
    cb('ok')
end)

local START_PROXIMITY = 40.0

RegisterNUICallback('previewRoute', function(data, cb)
    cb('ok')
    clearPreview()
    local generation = previewGeneration
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    lib.notify({
        title = 'Convoy System',
        description = 'Viewing route preview on map. The tablet will automatically restore when you close the map.',
        type = 'info',
        duration = 6000,
    })
    local checkpointRadiusByPoint = {}
    for _, cp in ipairs(data and data.checkpoints or {}) do
        checkpointRadiusByPoint[cp.routePointId] = cp.radius
    end
    local airdropByPoint = {}
    for _, ad in ipairs(data and data.airdrops or {}) do
        airdropByPoint[ad.routePointId] = true
    end

    CreateThread(function()
        Wait(0)
        if previewGeneration ~= generation then return end

        local routeBlip, lastPointBlip, startPoint = nil, nil, nil
        for i, point in ipairs(data and data.points or {}) do
            local blip = AddBlipForCoord(point.x, point.y, point.z)
            SetBlipSprite(blip, TYPE_SPRITE[point.type] or 1)
            SetBlipColour(blip, TYPE_COLOR[point.type] or 0)
            SetBlipScale(blip, 0.85)
            SetBlipAsShortRange(blip, false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(('%d. %s'):format(i, point.type))
            EndTextCommandSetBlipName(blip)
            previewBlips[#previewBlips + 1] = blip
            lastPointBlip = blip

            if point.type == 'START' then
                startPoint = point
            elseif point.type == 'DESTINATION' then
                routeBlip = blip
                SetBlipFlashes(blip, true)
            end

            -- Radius/zone circles are deliberately NOT drawn in this preview.
            -- They only ever belong to a stuck-on-screen map artifact before
            -- the event is even running (an admin opening the route editor saw
            -- a lone zone sprite with nothing to explain it), while the point
            -- markers above already convey the route layout. Live checkpoint/
            -- airdrop radius circles are drawn by runtime_client.lua once the
            -- event is actually active.
        end

        if previewGeneration ~= generation then return end

        routeBlip = routeBlip or lastPointBlip
        if routeBlip then
            Wait(0)
            if previewGeneration ~= generation then return end

            local pedCoords = GetEntityCoords(cache.ped or PlayerPedId())
            local distanceToStart = startPoint and #(pedCoords - vector3(startPoint.x, startPoint.y, startPoint.z)) or nil
            local showRoute = not distanceToStart or distanceToStart <= START_PROXIMITY

            if showRoute then
                SetBlipRoute(routeBlip, true)
            end
        end

        Wait(1000)
        if previewGeneration ~= generation then return end
        for i = 1, 5 do
            SetControlNormal(0, 200, 1.0)
            Wait(0)
        end

        -- Auto-restore tablet on its own when the player closes the pause/map menu
        CreateThread(function()
            Wait(1500)
            while IsPauseMenuActive() do
                Wait(250)
            end
            if previewGeneration == generation then
                TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
            end
        end)
    end)
end)

RegisterNUICallback('clearRoutePreview', function(_, cb)
    clearPreview()
    clearBarricadePreviews()
    clearVehiclePreviews()
    cb('ok')
end)

-- ── Container Wars: harbour tools ─────────────────────────────────────────────
-- (The prop placers, hologram tools and stack builder are gone: the harbour yard lives in
-- Config.ContainerWars.harbour.)

-- Which of these model names does THIS game build actually have? Used by the tablet to list only
-- container models that really exist.
RegisterNUICallback('checkModels', function(data, cb)
    local results = {}
    for _, name in ipairs((data and data.models) or {}) do
        if type(name) == 'string' then
            local hash = joaat(name)
            results[name] = IsModelInCdimage(hash) and IsModelValid(hash) or false
        end
    end
    cb({ ok = true, results = results })
end)

-- ── Finding the harbour's containers ─────────────────────────────────────────
-- Containers that are part of the map are NOT in the game's object list, so they cannot simply be
-- listed. They can only be asked for by model near a point — so these commands do that: /cwspot asks
-- at the spot you aim at, /cwscan asks at a grid of points around you.
local CW_SPOT_MODELS = {
    'prop_container_01a', 'prop_container_01b', 'prop_container_01c', 'prop_container_01d', 'prop_container_01e',
    'prop_container_01f', 'prop_container_01g', 'prop_container_01h', 'prop_container_01mb',
    'prop_container_02a', 'prop_container_03a', 'prop_container_03b', 'prop_container_04a', 'prop_container_04mb',
    'prop_container_05a', 'prop_container_05mb', 'prop_container_ld', 'prop_container_ld2', 'prop_container_old1',
    'prop_contr_03_ld', 'tr_prop_tr_container_01i', 'prop_container_hole', 'prop_container_pile_01',
}
-- The real model name of an entity (not just its hash), or nil. Works for dynamic objects and for
-- entities the game hands back from a ray; wrapped because the native can throw on a stale handle.
local function cwArchetypeName(ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    local ok, name = pcall(GetEntityArchetypeName, ent)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return nil
end
local CW_SPOT_HASH = {}
for _, name in ipairs(CW_SPOT_MODELS) do CW_SPOT_HASH[joaat(name)] = name end

-- Where is the player looking? (a point in the world, and the entity there if the game reports one)
local function cwAimPoint(maxDistance)
    local camPos = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local rx, rz = math.rad(camRot.x), math.rad(camRot.z)
    local dx, dy, dz = -math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx)
    local ray = StartShapeTestRay(camPos.x, camPos.y, camPos.z, camPos.x + dx * maxDistance, camPos.y + dy * maxDistance, camPos.z + dz * maxDistance, -1, PlayerPedId(), 0)
    local _, hit, pos, _, ent = GetShapeTestResult(ray)
    if hit == 1 then return pos, ent end
    return nil, nil
end

-- The closest known container model around a point.
local function cwContainerNear(x, y, z, radius)
    local best, bestDist, bestName
    for hash, name in pairs(CW_SPOT_HASH) do
        local ent = GetClosestObjectOfType(x, y, z, radius, hash, false, false, false)
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local c = GetEntityCoords(ent)
            local d = #(vector3(x, y, z) - c)
            if not bestDist or d < bestDist then best, bestDist, bestName = ent, d, name end
        end
    end
    return best, bestName
end

local function cwSpotLine(c, heading, mapModel)
    if mapModel then
        return ("{ x = %.4f, y = %.4f, z = %.4f, heading = %.4f, mapModel = '%s' },"):format(c.x, c.y, c.z, heading, mapModel)
    end
    return ('{ x = %.4f, y = %.4f, z = %.4f, heading = %.4f },'):format(c.x, c.y, c.z, heading)
end

-- /cwspot — AIM at a harbour container (just look at it) and run it. Prints one line to paste into
-- Config.ContainerWars.harbour.pickups. If nothing you aim at is a known container it falls back to the
-- nearest one within 12 m of you, and failing that to your own position. If the thing you aim at is an
-- object whose model is not in the list, its model hash is printed so it can still be used.
RegisterCommand('cwspot', function()
    local ped = PlayerPedId()
    local me = GetEntityCoords(ped)
    local aim, aimEnt = cwAimPoint(60.0)
    local ent, name
    if aim then ent, name = cwContainerNear(aim.x, aim.y, aim.z, 9.0) end
    if not ent then ent, name = cwContainerNear(me.x, me.y, me.z, 12.0) end

    -- whatever the crosshair is on: print its real name so crane parts (and unknown containers) can be identified
    if aimEnt and aimEnt ~= 0 and DoesEntityExist(aimEnt) then
        if GetEntityType(aimEnt) == 0 then
            -- fixed map geometry (a building, a crane body): the game gives no name, position or model for it
            print('[nova_convoytruck] you are aiming at fixed map geometry (no object name available)')
        else
            local c = GetEntityCoords(aimEnt)
            print(('[nova_convoytruck] you are aiming at: %s (entity type %d) at %.2f, %.2f, %.2f heading %.1f'):format(
                cwArchetypeName(aimEnt) or ('unknown, hash ' .. tostring(NovaConvoy.SafeEntityModel(aimEnt))), GetEntityType(aimEnt), c.x, c.y, c.z, GetEntityHeading(aimEnt)))
        end
    end

    local line, title
    if ent then
        local c = GetEntityCoords(ent)
        line = cwSpotLine(c, GetEntityHeading(ent), name)
        title = 'Container found: ' .. name
    elseif aimEnt and aimEnt ~= 0 and DoesEntityExist(aimEnt) and GetEntityType(aimEnt) == 3 then
        local c = GetEntityCoords(aimEnt)
        local hash = NovaConvoy.SafeEntityModel(aimEnt)
        line = cwSpotLine(c, GetEntityHeading(aimEnt), 'hash:' .. tostring(hash))
        title = 'Object found (model not in the container list)'
    else
        line = cwSpotLine(vector3(me.x, me.y, me.z - 1.0), GetEntityHeading(ped))
        title = 'No container found — this is your own position'
    end
    print('[nova_convoytruck] harbour spot: ' .. line)
    lib.notify({ title = title, description = line .. '  (also in F8)', type = ent and 'success' or 'warning', duration = 14000 })
end, false)

-- /cwscan [radius] — looks for containers all around you (default 70 m) and lists them nearest first as
-- lines ready to paste into harbour.pickups. They are also numbered 1, 2, 3 … in the world for 25 s.
RegisterCommand('cwscan', function(_, args)
    local radius = math.max(10.0, math.min(150.0, tonumber(args[1]) or 70.0))
    local me = GetEntityCoords(PlayerPedId())
    lib.notify({ title = 'Container scan', description = ('Searching %d m around you…'):format(math.floor(radius)), type = 'inform', duration = 3000 })
    CreateThread(function()
        local found, seen = {}, {}
        local step, reach = 8.0, 6.5
        local heights = { -6.0, 0.0, 6.0, 12.0, 18.0, 24.0 }   -- decks and stacks are higher than the quay
        local calls = 0
        local gx = -radius
        while gx <= radius do
            local gy = -radius
            while gy <= radius do
                if gx * gx + gy * gy <= radius * radius then
                    for _, dz in ipairs(heights) do
                        for hash, name in pairs(CW_SPOT_HASH) do
                            local ent = GetClosestObjectOfType(me.x + gx, me.y + gy, me.z + dz, reach, hash, false, false, false)
                            if ent and ent ~= 0 and DoesEntityExist(ent) then
                                local c = GetEntityCoords(ent)
                                local key = ('%s:%d:%d:%d'):format(name, math.floor(c.x * 2), math.floor(c.y * 2), math.floor(c.z * 2))
                                if not seen[key] then
                                    seen[key] = true
                                    found[#found + 1] = { ent = ent, name = name, c = c, h = GetEntityHeading(ent), d = #(me - c) }
                                end
                            end
                            calls = calls + 1
                            if calls % 400 == 0 then Wait(0) end
                        end
                    end
                end
                gy = gy + step
            end
            gx = gx + step
        end

        table.sort(found, function(p, q) return p.d < q.d end)
        if #found == 0 then
            print('[nova_convoytruck] cwscan: nothing found. Try /cwspot while aiming at a container.')
            lib.notify({ title = 'Container scan', description = 'No known container model found. Aim at one and use /cwspot — it also reports unknown object models.', type = 'error', duration = 9000 })
            return
        end
        print(('[nova_convoytruck] %d container(s) within %d m — paste the ones you want into Config.ContainerWars.harbour.pickups:'):format(#found, math.floor(radius)))
        for i, fnd in ipairs(found) do
            print(('    %s  -- #%d, %.0f m away'):format(cwSpotLine(fnd.c, fnd.h, fnd.name), i, fnd.d))
        end
        lib.notify({ title = ('%d container(s) found'):format(#found), description = 'Lines are in F8; the containers are numbered in the world. Paste the ones you want into harbour.pickups.', type = 'success', duration = 12000 })
        local untilT = GetGameTimer() + 25000
        while GetGameTimer() < untilT do
            for i, fnd in ipairs(found) do
                if DoesEntityExist(fnd.ent) then
                    local c = GetEntityCoords(fnd.ent)
                    DrawMarker(2, c.x, c.y, c.z + 4.0, 0, 0, 0, 180.0, 0, 0, 0.6, 0.6, 0.6, 70, 214, 154, 220, false, false, 2, false, nil, nil, false)
                    local on, sx, sy = World3dToScreen2d(c.x, c.y, c.z + 4.8)
                    if on then
                        SetTextScale(0.5, 0.5); SetTextFont(4); SetTextCentre(true); SetTextOutline()
                        SetTextColour(255, 255, 255, 255)
                        BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(tostring(i)); EndTextCommandDisplayText(sx, sy)
                    end
                end
            end
            Wait(0)
        end
    end)
end, false)

-- Test Crane Run: plays what an event does for the first container — the gantry rolls over, the hook
-- comes down, the container is carried to the drop spot and set down — with LOCAL props only (nothing
-- networked, nothing saved). Everything (crane, drop, pickup) comes from Config.ContainerWars.harbour.
local cwTestRunning = false
RegisterNUICallback('testContainerWarsCrane', function(data, cb)
    if cwTestRunning then cb({ ok = false, error = 'busy' }) return end
    data = data or {}
    local H = (Config.ContainerWars and Config.ContainerWars.harbour) or {}
    if type(data.yard) == 'table' then
        -- a SAVED yard layout (Saved Routes tab): its own spots, drops, dummies and planned routes over the live
        -- config, so it can be watched without loading it into the harbour
        local y = data.yard
        local merged = {}
        for k, v in pairs(H) do merged[k] = v end
        merged.pickups, merged.drops, merged.dummies, merged.carry = y.pickups or {}, y.drops or {}, y.dummies or {}, y.carry or {}
        merged.drop = (y.drops and y.drops[1]) or H.drop
        if type(y.crane) == 'table' and y.crane.x ~= nil then
            local c = {}
            for k, v in pairs(H.crane or {}) do c[k] = v end
            for _, k in ipairs({ 'x', 'y', 'z', 'heading', 'auto' }) do if y.crane[k] ~= nil then c[k] = y.crane[k] end end
            merged.crane = c
        end
        -- a layout saved with several cranes brings them all; one saved earlier has just the single crane above
        if type(y.cranes) == 'table' and #y.cranes > 0 then merged.cranes = y.cranes
        elseif type(y.crane) == 'table' and y.crane.x ~= nil then merged.cranes = { merged.crane } end
        H = merged
    end
    -- which container to play (1 = the first); each uses its own pickup spot and its own drop spot
    local idx = math.max(1, math.floor(tonumber(data.index) or 1))
    local pick = (H.pickups and H.pickups[idx])
    local dropIdx = (pick and tonumber(pick.assignedDrop)) or idx
    local drop = (H.drops and H.drops[dropIdx]) or (H.drops and H.drops[idx]) or H.drop
    if not (drop and tonumber(drop.x)) then
        cb({ ok = false, error = 'missing_positions' })
        return
    end
    local name = data.model or (pick and (pick.model or pick.mapModel)) or 'prop_container_05a'
    local hash = tonumber(type(name) == 'string' and name:match('^hash:(%-?%d+)$')) or joaat(name)
    if not requestModelSafe(hash) then
        cb({ ok = false, error = 'invalid_model' })
        return
    end

    cwTestRunning = true
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    local speedMulCfg = (Config.ContainerWars and Config.ContainerWars.defaults and tonumber(Config.ContainerWars.defaults.craneSpeedMultiplier)) or 1.0
    local travel = math.max(3.0, tonumber(data.travelSeconds) or 8.0) / math.max(0.25, math.min(4.0, speedMulCfg))
    local lift = tonumber(data.liftHeight) or 12.0
    pick = pick or { x = drop.x, y = drop.y, z = drop.z + lift, heading = drop.heading }
    local px, py, pz = tonumber(pick.x), tonumber(pick.y), tonumber(pick.z)
    local dx, dy, dz = tonumber(drop.x), tonumber(drop.y), tonumber(drop.z) + (tonumber(H.dropZOffset) or 0.0)
    local h0, h1 = tonumber(pick.heading) or 0.0, tonumber(drop.heading) or 0.0
    local cwDefaults = (Config.ContainerWars and Config.ContainerWars.defaults) or {}
    local apexZ = math.max(pz, dz) + lift
    -- the crane that carries this container: the one explicitly assigned or reaching both spots
    local testCranes = CWGantry.resolveCranes(H, #(H.pickups or {}))
    local testCraneIdx, testReach = CWGantry.craneFor(testCranes, pick, drop)
    local testCrane = testCranes[testCraneIdx or 1]
    do
        -- the same ceiling the server applies: the spreader cannot go above the gantry's cabin
        local gc = testCrane
        local gg = gc and CWGantry.get(gc.model)
        if gg then
            local ceiling = gc.z + ((gg.cabin and gg.cabin.z) or 18.0) + (tonumber(gg.cableTopOffset) or -1.0) - (tonumber(gg.hookClearance) or 5.0)
            apexZ = math.max(math.max(pz, dz) + 0.5, math.min(apexZ, ceiling))
        end
    end

    CreateThread(function()
      local objs = {}
      local stopped = false
      -- the harbour keeps parked crane props where the cranes were placed; the test builds its own at the same spots,
      -- so those are hidden for the run (on this screen only) and shown again afterwards
      local parked = {}
      for _, e in ipairs(GetGamePool('CObject')) do
        local okState, flag = pcall(function() return Entity(e).state.cw_idle_crane end)
        if okState and flag then
          parked[#parked + 1] = e
          SetEntityVisible(e, false, false)
          SetEntityCollision(e, false, false)
        end
      end
      local okRun, errRun = pcall(function()
        local function spawnModel(modelHash, x, y, z, h)
            local o = CreateObject(modelHash, x, y, z, false, false, false)
            if not o or o == 0 or not DoesEntityExist(o) then return nil end
            SetEntityHeading(o, h)
            FreezeEntityPosition(o, true)
            SetEntityCollision(o, false, false)
            objs[#objs + 1] = o
            return o
        end
        local function spawnByName(model, x, y, z, h)
            local mh = joaat(model)
            if not pcall(lib.requestModel, mh, 5000) then return nil end
            return spawnModel(mh, x, y, z, h)
        end
        -- Spawn ALL cranes saved in this yard layout
        local allGantries = {}
        for ci, cRow in ipairs(testCranes) do
            if tonumber(cRow.x) and tonumber(cRow.y) then
                local cg = CWGantry.get(cRow.model)
                if cg then
                    local cRef = { x = tonumber(cRow.x), y = tonumber(cRow.y), z = tonumber(cRow.z) or 0.0, heading = tonumber(cRow.heading) or 0.0 }
                    local cLay = CWGantry.layout(cg, cRef, cRef.x, cRef.y)
                    local gData = { cfg = cg, ref = cRef, wheels = {} }
                    gData.frame = spawnByName(cRow.model, cLay.frame.x, cLay.frame.y, cLay.frame.z, cLay.frame.heading)
                    gData.cabin = spawnByName(cg.cabin.model, cLay.cabin.x, cLay.cabin.y, cLay.cabin.z, cLay.cabin.heading)
                    if cg.wheels and cg.wheels.model then
                        for _, wp in ipairs(cLay.wheels) do
                            local w = spawnByName(cg.wheels.model, wp.x, wp.y, wp.z, wp.heading)
                            if w then gData.wheels[#gData.wheels + 1] = w end
                        end
                    end
                    allGantries[ci] = gData
                end
            end
        end

        -- Spawn all saved dummy containers in the yard
        if type(H.dummies) == 'table' then
            for _, d in ipairs(H.dummies) do
                if tonumber(d.x) and tonumber(d.y) and tonumber(d.z) then
                    local dModel = d.model or 'prop_container_05a'
                    local dCount = math.max(1, math.min(10, math.floor(tonumber(d.stack) or 1)))
                    local dStep = tonumber(d.step) or 2.6
                    local dHead = tonumber(d.heading) or 0.0
                    for s = 0, dCount - 1 do
                        spawnByName(dModel, tonumber(d.x), tonumber(d.y), tonumber(d.z) + s * dStep, dHead)
                    end
                end
            end
        end

        -- Spawn all saved props / vehicles in this route layout
        local propsList = data.props or data.eventProps or (data.yard and data.yard.props) or H.props
        if type(propsList) == 'table' then
            for _, p in ipairs(propsList) do
                if tonumber(p.x) and tonumber(p.y) and tonumber(p.z) and p.model then
                    local pCount = math.max(1, math.min(10, math.floor(tonumber(p.stack) or 1)))
                    local pStep = tonumber(p.step) or 2.6
                    local pHead = tonumber(p.heading) or tonumber(p.rz) or 0.0
                    local rx = tonumber(p.rx) or 0.0
                    local ry = tonumber(p.ry) or 0.0
                    for s = 0, pCount - 1 do
                        local ent = spawnByName(p.model, tonumber(p.x), tonumber(p.y), tonumber(p.z) + s * pStep, pHead)
                        if ent and (rx ~= 0.0 or ry ~= 0.0) then
                            pcall(SetEntityRotation, ent, rx + 0.0, ry + 0.0, pHead + 0.0, 2, true)
                        end
                    end
                end
            end
        end

        -- Spawn container models at all pickup spots in the harbour
        local pickupContainers = {}
        for pi, pSpot in ipairs(H.pickups or {}) do
            if tonumber(pSpot.x) and tonumber(pSpot.y) and tonumber(pSpot.z) then
                local pMod = pSpot.model or pSpot.mapModel or 'prop_container_05a'
                local pEnt = spawnByName(pMod, tonumber(pSpot.x), tonumber(pSpot.y), tonumber(pSpot.z), tonumber(pSpot.heading) or 0.0)
                if pEnt then pickupContainers[pi] = pEnt end
            end
        end

        NovaConvoy.ShowKeyHelp('CRANE TEST RUN', { { { 'Backspace', 'STOP the test' } } }, { info = 'Watch the crane: roll, lower, lift, carry, set down', icon = 'truck-ramp-box' })

        local function ease(t) return t * t * (3.0 - 2.0 * t) end

        -- Execution routine for carrying a specific spot with its assigned crane
        local function carrySpot(sIdx)
            if stopped then return end
            local sPick = (H.pickups and H.pickups[sIdx]) or pick
            local sDropIdx = (sPick and tonumber(sPick.assignedDrop)) or sIdx
            local sDrop = (H.drops and H.drops[sDropIdx]) or (H.drops and H.drops[sIdx]) or drop
            if not (sDrop and tonumber(sDrop.x)) then return end

            local spx, spy, spz = tonumber(sPick.x), tonumber(sPick.y), tonumber(sPick.z)
            local sdx, sdy, sdz = tonumber(sDrop.x), tonumber(sDrop.y), tonumber(sDrop.z) + (tonumber(H.dropZOffset) or 0.0)
            local sh0, sh1 = tonumber(sPick.heading) or 0.0, tonumber(sDrop.heading) or 0.0
            local sApexZ = math.max(spz, sdz) + lift

            local cIdx, cReach = CWGantry.craneFor(testCranes, sPick, sDrop)
            cIdx = cIdx or 1
            local cr = testCranes[cIdx]
            local gantry = allGantries[cIdx]
            if not cr or not gantry then return end

            local gg = CWGantry.get(cr.model)
            if gg then
                local ceiling = cr.z + ((gg.cabin and gg.cabin.z) or 18.0) + (tonumber(gg.cableTopOffset) or -1.0) - (tonumber(gg.hookClearance) or 5.0)
                sApexZ = math.max(math.max(spz, sdz) + 0.5, math.min(sApexZ, ceiling))
            end

            local moving = pickupContainers[sIdx]
            if not moving or not DoesEntityExist(moving) then
                local pMod = sPick.model or sPick.mapModel or 'prop_container_05a'
                moving = spawnByName(pMod, spx, spy, spz, sh0)
            end
            if not moving then return end

            local function gantryApply(hx, hy)
                if not gantry then return hx, hy end
                local lay = CWGantry.layout(gantry.cfg, gantry.ref, hx, hy)
                if gantry.frame then SetEntityCoords(gantry.frame, lay.frame.x, lay.frame.y, lay.frame.z, false, false, false, false) end
                if gantry.cabin then SetEntityCoords(gantry.cabin, lay.cabin.x, lay.cabin.y, lay.cabin.z, false, false, false, false) end
                for i, w in ipairs(gantry.wheels) do
                    local p = lay.wheels[i]
                    if p then SetEntityCoords(w, p.x, p.y, p.z, false, false, false, false) end
                end
                return lay.hook.x, lay.hook.y
            end

            -- Build hook parts for this gantry
            local hookParts = {}
            local cwCfg = Config.ContainerWars or {}
            local hookCfg = cwCfg.hook
            if gantry and hookCfg and hookCfg.enabled ~= false then
                local armTop = gantry.ref.z + ((gantry.cfg.cabin and gantry.cfg.cabin.z) or 18.0) + (tonumber(gantry.cfg.cableTopOffset) or -1.0)
                local segLen = tonumber(hookCfg.cableSegmentLength)
                local lowZ = math.min(spz, sdz)
                local ropeLines = tostring(hookCfg.cableMode or 'LINES'):upper() ~= 'PROPS'
                for _, def in ipairs(hookCfg.parts or {}) do
                  if not (def.cable and ropeLines) then
                    local part = { x = def.x or 0.0, y = def.y or 0.0, z = def.z or 0.0, heading = def.heading or 0.0, entities = {} }
                    local count = 1
                    -- the cable piece's real size, so the rope reaches the cabin and no further
                    local len, top = segLen, segLen
                    if def.cable then
                        local hash = joaat(def.model)
                        if IsModelInCdimage(hash) and pcall(lib.requestModel, hash, 5000) then
                            local mn, mx = GetModelDimensions(hash)
                            SetModelAsNoLongerNeeded(hash)
                            if mn and mx and (mx.z - mn.z) > 0.5 then len, top = mx.z - mn.z, mx.z end
                        end
                    end
                    if def.cable and len and len > 0.5 then
                        part.segLen, part.top, part.armTop = len, top, armTop
                        part.overlap = tonumber(hookCfg.cableOverlap) or 3.0
                        count = math.max(1, math.min(24, math.ceil((armTop - (lowZ + part.z)) / len) + 1))
                    end
                    for k = 1, count do
                        local e = spawnByName(def.model, spx + part.x, spy + part.y, math.min(sApexZ + part.z + (k - 1) * (part.segLen or 0.0), part.armTop and (part.armTop - (part.top or 0.0)) or math.huge), sh0 + part.heading)
                        if e then part.entities[#part.entities + 1] = e end
                    end
                    if #part.entities > 0 then hookParts[#hookParts + 1] = part end
                  end
                end
                -- LINES mode: the rope is drawn from the cabin's underside to the spreader (hook_rope.lua)
                if ropeLines and hookParts[1] and hookParts[1].entities[1] then
                    HookRope.set('cw_test', hookParts[1].entities[1], armTop)
                end
            end

            local function moveHook(x, y, z, heading)
                local hx, hy = gantryApply(x, y)
                for _, part in ipairs(hookParts) do
                    local baseZ = z + part.z
                    -- whole pieces from the hook up, the last tucked against the cabin; pieces that do not fit are hidden
                    -- invisible so no rope hangs when the hook is raised to the cabin (same rule as the live event)
                    local fit, rest, gap = nil, 0.0, 0.0
                    if part.segLen and part.armTop then
                        gap = part.armTop - baseZ
                        fit = math.max(0, math.floor(gap / part.segLen + 0.001))
                        rest = gap - fit * part.segLen
                    end
                    for k, e in ipairs(part.entities) do
                        local zk, hide = baseZ, false
                        if part.segLen then
                            local bottomOff = (part.top or part.segLen) - part.segLen
                            if fit then
                                if k <= fit then zk = baseZ + (k - 1) * part.segLen - bottomOff
                                elseif k == fit + 1 and ((fit >= 1 and rest > 0.3) or (fit == 0 and part.segLen - gap <= (part.overlap or 0.0))) then zk = part.armTop - (part.top or part.segLen)
                                else hide, zk = true, part.armTop - (part.top or part.segLen) end
                            else
                                zk = baseZ + (k - 1) * part.segLen
                            end
                        end
                        SetEntityVisible(e, not hide, false)
                        SetEntityCoords(e, hx + part.x, hy + part.y, zk, false, false, false, false)
                        if heading then SetEntityHeading(e, heading + part.heading) end
                    end
                end
                return hx, hy
            end

            -- Plan carry trajectory
            local carryAt
            do
                local fake = {}
                for j = 1, math.max(#(H.pickups or {}), #(H.drops or {})) do
                    fake[j] = { containerIndex = j, pickupCoords = H.pickups and H.pickups[j], dropCoords = (H.drops and H.drops[j]) or H.drop }
                end
                fake[sIdx] = fake[sIdx] or { containerIndex = sIdx }
                fake[sIdx].containerIndex = sIdx

                local gcfg = CWGantry.get(cr.model)
                if gcfg then
                    local obstacles = CWGantry.carryObstacles(H, fake, fake[sIdx], cwDefaults.containerSize)
                    for _, o in ipairs(CWGantry.craneObstacles(testCranes, cIdx)) do obstacles[#obstacles + 1] = o end
                    local lo, hi = CWGantry.railLimits(gcfg, cr, obstacles)
                    cr.railMin, cr.railMax = lo, hi
                    if gantry and gantry.ref then gantry.ref.railMin, gantry.ref.railMax = lo, hi end
                end
                carryAt = CWGantry.chooseCarry({
                    harbour = H, index = sIdx, pick = { x = spx, y = spy, h = sh0 }, drop = { x = sdx, y = sdy, h = sh1 },
                    z = sApexZ, mode = tostring(data.carryPath or cwDefaults.carryPath or 'CURVE'):upper(),
                    tension = tonumber(data.carryCurve) or tonumber(cwDefaults.carryCurve) or 0.4,
                    containers = fake, current = fake[sIdx], size = cwDefaults.containerSize,
                    gantry = CWGantry.get(cr.model), crane = cr,
                })
            end

            local function overlay()
                NovaDraw.line(spx, spy, spz, spx, spy, sApexZ, 255, 200, 60, 255, 1.3)
                local ax, ay = spx, spy
                for i = 1, 40 do
                    local bx, by = carryAt(i / 40.0)
                    NovaDraw.line(ax, ay, sApexZ, bx, by, sApexZ, 255, 200, 60, 255, 1.3)
                    ax, ay = bx, by
                end
                NovaDraw.line(sdx, sdy, sApexZ, sdx, sdy, sdz, 255, 200, 60, 255, 1.3)
                DrawMarker(1, sdx, sdy, sdz - 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.5, 1.5, 0.4, 70, 214, 154, 150, false, false, 2, false, nil, nil, false)
                NovaDraw.label(spx, spy, spz + 3.5, ('SPOT #%d (CRANE #%d)'):format(sIdx, cIdx), 255, 200, 60)
                NovaDraw.label(sdx, sdy, sdz + 3.5, ('DROP #%d'):format(sDropIdx), 70, 214, 154)
            end

            local function stepPhase(seconds, fn)
                local started = GetGameTimer()
                local total = math.max(1, seconds * 1000.0)
                while not stopped do
                    Wait(0)
                    overlay()
                    if IsControlJustPressed(0, 177) or IsControlJustPressed(0, 200) then stopped = true break end
                    local t = math.min(1.0, (GetGameTimer() - started) / total)
                    fn(ease(t))
                    if t >= 1.0 then break end
                end
            end

            local function hold(seconds)
                local started = GetGameTimer()
                while not stopped and GetGameTimer() - started < seconds * 1000 do
                    Wait(0)
                    overlay()
                    if IsControlJustPressed(0, 177) or IsControlJustPressed(0, 200) then stopped = true end
                end
            end

            moveHook(spx, spy, sApexZ, sh0)
            hold(1.0)
            stepPhase(0.6, function(e) moveHook(spx, spy, sApexZ + (spz - sApexZ) * e, sh0) end)
            if NovaConvoy.playCraneAudio then NovaConvoy.playCraneAudio('PICKING_UP', { x = spx, y = spy, z = spz }) end
            stepPhase(travel * 0.3, function(e)
                local z = spz + (sApexZ - spz) * e
                SetEntityCoords(moving, spx, spy, z, false, false, false, false)
                moveHook(spx, spy, z, sh0)
            end)
            if NovaConvoy.playCraneAudio then NovaConvoy.playCraneAudio('MOVING', { x = spx, y = spy, z = sApexZ }) end
            stepPhase(travel * 0.4, function(e)
                local x, y, hd = carryAt(e)
                local hx, hy = moveHook(x, y, sApexZ, hd)
                SetEntityCoords(moving, hx, hy, sApexZ, false, false, false, false)
                SetEntityHeading(moving, hd)
            end)
            if NovaConvoy.playCraneAudio then NovaConvoy.playCraneAudio('PLACING', { x = sdx, y = sdy, z = sdz }) end
            stepPhase(travel * 0.3, function(e)
                local z = sApexZ + (sdz - sApexZ) * e
                SetEntityCoords(moving, sdx, sdy, z, false, false, false, false)
                moveHook(sdx, sdy, z, sh1)
            end)
            if NovaConvoy.playCraneAudio then NovaConvoy.playCraneAudio('IMPACT', { x = sdx, y = sdy, z = sdz }) end
            stepPhase(0.6, function(e) moveHook(sdx, sdy, sdz + (sApexZ - sdz) * e, sh1) end)
            hold(1.5)
            if NovaConvoy.playCraneAudio then NovaConvoy.playCraneAudio('FINISHED', { x = sdx, y = sdy, z = sdz }) end

            -- Clean up this run's hook entities before moving to the next crane
            HookRope.remove('cw_test')
            for _, part in ipairs(hookParts) do
                for _, he in ipairs(part.entities) do
                    if DoesEntityExist(he) then DeleteEntity(he) end
                end
            end
        end

        -- Execute single container or full sequence of all containers
        local spotCount = math.max(1, #(H.pickups or {}))
        if data.cycleAll and spotCount > 1 then
            for s = 1, spotCount do
                if stopped then break end
                carrySpot(s)
                if s < spotCount and not stopped then
                    local sStarted = GetGameTimer()
                    while not stopped and GetGameTimer() - sStarted < 1000 do
                        Wait(0)
                        if IsControlJustPressed(0, 177) or IsControlJustPressed(0, 200) then stopped = true end
                    end
                end
            end
        else
            carrySpot(idx)
        end
      end)

      -- always clean up and give the tablet back, even if something above failed
      if NovaConvoy.stopCraneAudio then NovaConvoy.stopCraneAudio() end
      lib.hideTextUI()
      for _, o in ipairs(objs) do
        if DoesEntityExist(o) then DeleteEntity(o) end
      end
      for _, e in ipairs(parked) do
        if DoesEntityExist(e) then
          SetEntityVisible(e, true, false)
          SetEntityCollision(e, true, true)
        end
      end
      SetModelAsNoLongerNeeded(hash)
      cwTestRunning = false
      TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
      if not okRun then
        print(('[nova_convoytruck] crane test error: %s'):format(tostring(errRun)))
        lib.notify({ title = 'Crane test failed', description = tostring(errRun), type = 'error', duration = 7000 })
        cb({ ok = false, error = 'test_failed' })
      else
        cb({ ok = true, stopped = stopped })
      end
    end)
end)

-- ── Race Test Run ─────────────────────────────────────────────────────────────
-- Spawns the saved stages / checkpoints and ALL saved props into the world locally
-- so the admin can test-drive the track and inspect placement before running the race.
local raceTestRunning = false
RegisterNUICallback('testRaceRoute', function(data, cb)
    if raceTestRunning then cb({ ok = false, error = 'busy' }) return end
    data = data or {}
    local stages = data.stages or data.rallyStages or {}
    local propsList = data.props or data.eventProps or {}
    if #stages == 0 then
        cb({ ok = false, error = 'missing_stages' })
        return
    end

    raceTestRunning = true
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')

    -- Teleport player near the start stage if available
    local startStage = stages[1]
    for _, s in ipairs(stages) do
        if s.kind == 'START' then startStage = s break end
    end
    if startStage and tonumber(startStage.x) then
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local targetEnt = (veh ~= 0) and veh or ped
        SetEntityCoords(targetEnt, tonumber(startStage.x), tonumber(startStage.y), tonumber(startStage.z) + 1.0, false, false, false, false)
        SetEntityHeading(targetEnt, tonumber(startStage.heading) or 0.0)
    end

    CreateThread(function()
        local objs = {}
        local stopped = false

        local function spawnModel(modelHash, x, y, z, h)
            local o = CreateObject(modelHash, x, y, z, false, false, false)
            if not o or o == 0 or not DoesEntityExist(o) then return nil end
            SetEntityHeading(o, h)
            FreezeEntityPosition(o, true)
            objs[#objs + 1] = o
            return o
        end

        local function spawnByName(model, x, y, z, h)
            local mh = joaat(model)
            if not IsModelInCdimage(mh) or not pcall(lib.requestModel, mh, 5000) then return nil end
            return spawnModel(mh, x, y, z, h)
        end

        -- Spawn all saved race props (Start zone, checkpoint, and finish props)
        if type(propsList) == 'table' then
            for _, p in ipairs(propsList) do
                if tonumber(p.x) and tonumber(p.y) and tonumber(p.z) and p.model then
                    local pCount = math.max(1, math.min(10, math.floor(tonumber(p.stack) or 1)))
                    local pStep = tonumber(p.step) or 2.6
                    local pHead = tonumber(p.heading) or tonumber(p.rz) or 0.0
                    local rx = tonumber(p.rx) or 0.0
                    local ry = tonumber(p.ry) or 0.0
                    for s = 0, pCount - 1 do
                        local ent = spawnByName(p.model, tonumber(p.x), tonumber(p.y), tonumber(p.z) + s * pStep, pHead)
                        if ent and (rx ~= 0.0 or ry ~= 0.0) then
                            pcall(SetEntityRotation, ent, rx + 0.0, ry + 0.0, pHead + 0.0, 2, true)
                        end
                    end
                end
            end
        end

        NovaConvoy.ShowKeyHelp('RACE TRACK TEST RUN', { { { 'Backspace', 'STOP test run' } } }, { info = ('Testing %d checkpoint(s) and %d prop(s)'):format(#stages, #objs), icon = 'flag-checkered' })

        while not stopped do
            Wait(0)
            if IsControlJustPressed(0, 177) or IsControlJustPressed(0, 200) then
                stopped = true
                break
            end

            -- Draw checkpoint markers
            for i, st in ipairs(stages) do
                if tonumber(st.x) and tonumber(st.y) and tonumber(st.z) then
                    local sx, sy, sz = tonumber(st.x), tonumber(st.y), tonumber(st.z)
                    local isStart = st.kind == 'START' or i == 1
                    local isFinish = st.kind == 'DESTINATION' or i == #stages
                    local r, g, b = 234, 179, 8 -- gold, the same as a live race checkpoint
                    if isStart then r, g, b = 70, 214, 154 -- green
                    elseif isFinish then r, g, b = 255, 75, 75 -- red
                    end
                    local rad = tonumber(st.radius) or 15.0
                    DrawMarker(1, sx, sy, sz - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, rad, rad, 2.0, r, g, b, 120, false, false, 2, false, nil, nil, false)
                    NovaDraw.label(sx, sy, sz + 2.0, isStart and 'START' or (isFinish and 'FINISH' or ('CP ' .. i)), r, g, b)
                end
            end
        end

        lib.hideTextUI()
        for _, o in ipairs(objs) do
            if DoesEntityExist(o) then DeleteEntity(o) end
        end
        raceTestRunning = false
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
        cb({ ok = true, stopped = stopped })
    end)
end)

-- the Prop Placer is about to open, or an event has started: previews must not duplicate
local function onClearPropPreviews()
    clearBarricadePreviews()
    clearVehiclePreviews()
end
RegisterNetEvent('nova_convoytruck:client:clearPropPreviews', onClearPropPreviews)
AddEventHandler('nova_convoytruck:client:clearPropPreviews', onClearPropPreviews)

AddEventHandler('nova_convoytruck:client:tabletClosed', function()
    clearPreview()
    clearBarricadePreviews()
    clearVehiclePreviews()
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    clearPreview()
    clearBarricadePreviews()
    clearVehiclePreviews()
end)


-- When an event starts OR ends (server: EventProps), every admin's in-world preview copies of placed props and vehicles are removed:
-- these are local, client-only entities, so ending / force-ending an event could never reach them and they stayed standing.
local function onClearEditorPreviews()
    clearBarricadePreviews()
    clearVehiclePreviews()
    SendNUIMessage({ action = 'routePreview:reset' })   -- the route builder's "previewing" toggles switch off with them
end
RegisterNetEvent('nova_convoytruck:client:clearPropPreviews', onClearEditorPreviews)
AddEventHandler('nova_convoytruck:client:clearPropPreviews', onClearEditorPreviews)
