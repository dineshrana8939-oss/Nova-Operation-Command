-- ─── Nova Convoy — Container Wars: crane, doors, loot crate (client) ────────────────────────────
-- Everything in the harbour that MOVES or OPENS is drawn here, locally, on every client:
--
--  · The gantry crane (frame, cabin, wheels), the hook (spreader + rope) and the container while it is carried are LOCAL
--    props. The server sends the crane's setup once and ONE move plan per container (a list of timed segments, see
--    CWGantry.evalSegment); every client plays the plan back on its own frame loop. The server no longer moves a dozen
--    networked props ten times a second, so there is no stutter and almost no network traffic.
--    The real (networked) container stays put while it is carried: it is hidden (state bag 'cwCarry') and a local copy rides
--    the hook; when the server has put the real one on its pad the copy goes away.
--
--  · Doors. Only the "mb" container models have a doorless end. A container with the state 'cwDoors' gets the two door props
--    fitted CLOSED, attached to it, from the moment it streams in; 'cwOpen' swings them open (or shows them open to someone
--    who arrives later).
--
--  · The loot crate. A container with the state 'cwCrate' gets a crate inside it (a local prop) with an ox_target that asks
--    the server to open its stash.
--
-- Server side: server/modules/container_wars_runtime.lua. Tuning: Config.ContainerWars.defaults.smoothCrane, .openContainer
-- (doors), .lootCrate, .hook.

CWFx = {}

local function cwCfg() return Config.ContainerWars or {} end

local fx = {
    convoyId = nil,
    cranes = {},        -- [index] = { cfg, ref, armTop, frame, cabin, wheels = {} }
    parts = {},         -- the spreader(s): { ent, def }
    active = nil,       -- index of the crane that carries the hook
    hook = nil,         -- { x, y, z, h } where the hook is parked
    ghosts = {},        -- [containerId] = { ent, pos }
    revealed = {},      -- [containerId] = true once the real container is back on its pad
    playing = false,
}
local doorSets = {}     -- [entity] = { ent, left, right, p, open, born }
local crates = {}       -- [entity] = { crate }
local dummyCrates = {}  -- [entity] = crate prop: the stand-in inside a car-only lot's container until its auction has a winner
local hiddenReal = {}   -- [entity] = true while the real container is hidden for a carry
local carryDrop = {}    -- [entity] = { x, y, z }

-- ── helpers ────────────────────────────────────────────────────────────────────────────────────

local function modelHash(model)
    if type(model) == 'string' then
        local n = tonumber(model:match('^hash:(%-?%d+)$'))
        if n then return n end
        return joaat(model)
    end
    return joaat('tr_prop_tr_container_01a')
end

-- A prop that exists only on this client.
local function spawnLocal(model, x, y, z, heading, collision)
    local hash = modelHash(model)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 8000) then return nil end
    local obj = CreateObjectNoOffset(hash, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    SetEntityHeading(obj, (heading or 0.0) + 0.0)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, collision == true, collision == true)
    return obj
end

local function killEntity(e)
    if not (e and e ~= 0 and DoesEntityExist(e)) then return end
    SetEntityAsMissionEntity(e, true, true)   -- an entity that is not marked this way can refuse to be deleted
    DeleteEntity(e)
    if DoesEntityExist(e) then DeleteObject(e) end
end

-- The entity a state bag belongs to (it may still be streaming in).
local function waitEntity(bagName, timeout)
    local deadline = GetGameTimer() + (timeout or 6000)
    while GetGameTimer() < deadline do
        local ent = GetEntityFromStateBagName(bagName)
        if ent and ent ~= 0 and DoesEntityExist(ent) then return ent end
        Wait(100)
    end
    return nil
end

-- ── doors ────────────────────────────────────────────────────────────────────────────────────

local function doorCfg()
    return (cwCfg().openContainer and cwCfg().openContainer.doors) or {}
end

local function modelHasDoors(model)
    local d = doorCfg()
    return type(model) == 'string' and type(d.models) == 'table' and d.models[model] == true
end

local function doorParams(ent)
    local d = doorCfg()
    local mn, mx = GetModelDimensions(GetEntityModel(ent))
    local atFront = d.atFront == true
    return {
        atFront = atFront,
        hingeY = tonumber(d.backOffset) or (atFront and mx.y or mn.y),   -- the end the doors are on
        zOff = (tonumber(d.zOffset) or 0.0) + mn.z,
        halfW = (mx.x - mn.x) / 2.0,
        minZ = mn.z,
        sign = atFront and 1.0 or -1.0,
        base = atFront and 0.0 or 180.0,
        openAngle = tonumber(d.openAngle) or 110.0,
        swing = tonumber(d.swingSeconds) or 2.4,
        lDir = (d.left and d.left.flip) and -1.0 or 1.0,
        rDir = (d.right and d.right.flip) and -1.0 or 1.0,
    }
end

local function attachDoor(door, ent, x, y, z, rotZ)
    AttachEntityToEntity(door, ent, 0, x, y, z, 0.0, 0.0, rotZ, false, false, false, false, 2, true)
end

-- e: 0 = shut … 1 = fully open
local function setDoorAngle(set, e)
    local p = set.p
    if set.left and DoesEntityExist(set.left) then attachDoor(set.left, set.ent, -p.halfW, p.hingeY, p.zOff, p.base + p.lDir * p.sign * p.openAngle * e) end
    if set.right and DoesEntityExist(set.right) then attachDoor(set.right, set.ent, p.halfW, p.hingeY, p.zOff, p.base - p.rDir * p.sign * p.openAngle * e) end
end

-- Fits the two door props, closed, to a container (or its carried copy). Returns the set, or nil when this build has no door props.
local function ensureDoors(ent)
    local have = doorSets[ent]
    if have and DoesEntityExist(have.ent) then return have end
    local d = doorCfg()
    if not (d.left and d.left.model and d.right and d.right.model) then return nil end
    local pos = GetEntityCoords(ent)
    local left = spawnLocal(d.left.model, pos.x, pos.y, pos.z, 0.0, false)
    local right = spawnLocal(d.right.model, pos.x, pos.y, pos.z, 0.0, false)
    if not left or not right then
        killEntity(left); killEntity(right)
        return nil
    end
    local set = { ent = ent, left = left, right = right, p = doorParams(ent), open = false, born = GetGameTimer() }
    doorSets[ent] = set
    setDoorAngle(set, 0.0)
    if hiddenReal[ent] then
        SetEntityVisible(left, false, false); SetEntityVisible(right, false, false)
    end
    return set
end

local function removeDoors(ent)
    local set = doorSets[ent]
    if not set then return end
    doorSets[ent] = nil
    killEntity(set.left); killEntity(set.right)
end

local function animateDoors(set, from, to)
    set.moving = (set.moving or 0) + 1
    local token = set.moving
    CreateThread(function()
        local steps = math.max(1, math.floor(set.p.swing * 30))
        PlaySoundFromCoord(-1, 'Door_Open_Limit', GetEntityCoords(set.ent).x, GetEntityCoords(set.ent).y, GetEntityCoords(set.ent).z, 'DOCKS_HEIST_SOUNDS', false, 40, false)
        for i = 1, steps do
            if set.moving ~= token or not DoesEntityExist(set.ent) then return end
            local k = i / steps
            local e = 1.0 - (1.0 - k) * (1.0 - k)    -- ease-out: the doors slow down as they reach the end
            setDoorAngle(set, from + (to - from) * e)
            Wait(33)
        end
        setDoorAngle(set, to)
        set.open = to >= 0.5
    end)
end

AddStateBagChangeHandler('cwDoors', nil, function(bagName, _, value)
    if not value then return end
    CreateThread(function()
        local ent = waitEntity(bagName)
        if ent then ensureDoors(ent) end
    end)
end)

-- ── an opened container with its own hinged doors (the tr_prop_tr_container_* models) ──────────────
-- The opening is the 'action_container' clip. When the clip ends the container goes back to its closed pose, which is why an opened
-- container used to shut again as soon as the animation had played. The opened pose is therefore HELD: a scene frozen on the last
-- frame (rate 0, hold-last-frame on) that is re-made whenever it is lost, for as long as the container's state says it is open.
-- (CreateSynchronizedScene takes only a position and a rotation; the extra arguments the old code passed were ignored, so the scene never
-- held anything.)
local OPEN_DICT = 'anim@scripted@player@mission@tunf_train_ig1_container_p1@male@'
local OPEN_CLIP = 'action_container'
local heldOpen = {}   -- [entity] = scene

local function loadOpenDict()
    if HasAnimDictLoaded(OPEN_DICT) then return true end
    RequestAnimDict(OPEN_DICT)
    local t = GetGameTimer() + 3000
    while not HasAnimDictLoaded(OPEN_DICT) and GetGameTimer() < t do Wait(50) end
    return HasAnimDictLoaded(OPEN_DICT)
end

-- Only a model with doors of its own has the clip. A doorless one (openEnd in Config.ContainerWars.containerModels, e.g. the big
-- prop_container_ld the car lots use) is already open: playing the door clip on it does nothing useful.
local function hasOwnDoors(ent)
    local hash = GetEntityModel(ent)
    for _, m in ipairs(cwCfg().containerModels or {}) do
        if joaat(m.model) == hash then return m.openEnd == nil and m.opens ~= false end
    end
    return true
end

-- The held pose: the clip played on the container itself, parked on its last frame (PlayEntityAnim with stayInAnim). This is how
-- animated props are held in the game's own scripts. The synchronised scene below is the fallback if the container refuses the clip.
local function playHeldPose(ent)
    if not loadOpenDict() then return false end
    PlayEntityAnim(ent, OPEN_CLIP, OPEN_DICT, 1000.0, false, true, false, 0.99, 0)
    ForceEntityAiAndAnimationUpdate(ent)
    SetEntityAnimCurrentTime(ent, OPEN_DICT, OPEN_CLIP, 0.999)
    SetEntityAnimSpeed(ent, OPEN_DICT, OPEN_CLIP, 0.0)
    return true
end

local function playHeldOpen(ent)
    if not loadOpenDict() then return nil end
    if playHeldPose(ent) then
        Wait(200)
        if IsEntityPlayingAnim(ent, OPEN_DICT, OPEN_CLIP, 3) then return 'pose' end
    end
    local pos, rot = GetEntityCoords(ent), GetEntityRotation(ent, 2)
    local scene = CreateSynchronizedScene(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, 2)
    SetSynchronizedSceneHoldLastFrame(scene, true)
    SetSynchronizedSceneLooped(scene, false)
    PlaySynchronizedEntityAnim(ent, scene, OPEN_CLIP, OPEN_DICT, 1.0, -1.0, 0, 1148846080)
    SetSynchronizedScenePhase(scene, 0.99)
    SetSynchronizedSceneRate(scene, 0.0)   -- frozen on the open pose
    ForceEntityAiAndAnimationUpdate(ent)
    return scene
end

-- Holds the container open until its 'cwOpen' state is cleared (or it is gone).
local localOpen = {}   -- [entity] = true: a local test container (/cwlootest) that has no state bag but must stay open

local function isOpenFlagged(ent)
    if localOpen[ent] then return true end
    local ok, v = pcall(function() return Entity(ent).state.cwOpen end)
    return ok and v and true or false
end

local function holdOpen(ent)
    if heldOpen[ent] ~= nil or not hasOwnDoors(ent) then return end
    heldOpen[ent] = false   -- claimed before the first (waiting) attempt, so a second state change cannot start a second hold
    CreateThread(function()
        heldOpen[ent] = playHeldOpen(ent) or false
        -- the model's collision does not follow its doors: it stays shut, and an invisible wall blocks the entrance of a container that
        -- LOOKS open. Collision off while it is held open lets players walk in (and through its walls); it comes back when it closes.
        local walkIn = (cwCfg().openContainer or {}).walkInWhenOpen ~= false
        if walkIn then SetEntityCollision(ent, false, false) end
        while heldOpen[ent] ~= nil do
            Wait(700)
            if not DoesEntityExist(ent) or not isOpenFlagged(ent) then break end
            local held = heldOpen[ent]
            local alive
            if held == 'pose' then
                alive = IsEntityPlayingAnim(ent, OPEN_DICT, OPEN_CLIP, 3)
            else
                alive = held and IsSynchronizedSceneRunning(held)
            end
            if not alive then heldOpen[ent] = playHeldOpen(ent) or false end
        end
        heldOpen[ent] = nil
        if walkIn and DoesEntityExist(ent) then SetEntityCollision(ent, true, true) end
    end)
end

local function releaseOpen(ent)
    heldOpen[ent] = nil
end

CWFx.HoldOpen = function(ent)
    if ent and ent ~= 0 and DoesEntityExist(ent) and Entity(ent).state.cwDoors ~= true then holdOpen(ent) end
end
CWFx.ReleaseOpen = releaseOpen

AddStateBagChangeHandler('cwOpen', nil, function(bagName, _, value)
    CreateThread(function()
        local ent = waitEntity(bagName)
        if not ent or not DoesEntityExist(ent) then return end
        -- its own doors: hold the opened pose (also for someone who streams in later and finds it already open)
        if Entity(ent).state.cwDoors ~= true then
            if value then holdOpen(ent) else releaseOpen(ent) end
        end
        if Entity(ent).state.cwDoors == true then
            local set = ensureDoors(ent)
            if set then
                if value then
                    if GetGameTimer() - set.born < 1500 then          -- it streamed in already open
                        setDoorAngle(set, 1.0)
                        set.open = true
                    else
                        animateDoors(set, 0.0, 1.0)
                    end
                elseif set.open then
                    animateDoors(set, 1.0, 0.0)
                end
            end
        end
    end)
end)

-- ── loot crate ────────────────────────────────────────────────────────────────────────────────

-- Where a crate stands inside a container (shared by the loot crate, the dummy crate and /cwlootest): metres in from the open end,
-- and how far above the floor its origin sits. Config.ContainerWars.lootCrate.depth / .floorLift
local function crateDepth() return tonumber((cwCfg().lootCrate or {}).depth) or 3.8 end
-- the crate is turned so its long side runs ALONG the container: a player can walk in past it (across, it filled the whole width)
local function crateTurn() return tonumber((cwCfg().lootCrate or {}).turn) or 90.0 end
local function crateLift() return tonumber((cwCfg().lootCrate or {}).floorLift) or 0.32 end

local function removeCrate(ent)
    local c = crates[ent]
    if not c then return end
    crates[ent] = nil
    if c.crate and DoesEntityExist(c.crate) then
        pcall(function() exports.ox_target:removeLocalEntity(c.crate) end)
        DeleteEntity(c.crate)
    end
end

local function placeCrate(ent, info)
    removeCrate(ent)
    local cfg = cwCfg().lootCrate or {}
    if cfg.enabled == false then return end
    local p = doorParams(ent)
    local hasDoors = Entity(ent).state.cwDoors == true
    local off = (info and info.offset) or cfg.offset or {}
    -- Crate positioned cleanly on container floor inside interior
    local toMiddle = p.atFront and -1.0 or 1.0
    local y = (off.y ~= nil) and tonumber(off.y) or (p.hingeY + toMiddle * crateDepth())
    local pos = GetOffsetFromEntityInWorldCoords(ent, tonumber(off.x) or 0.0, y, p.minZ + crateLift() + (tonumber(off.z) or 0.0))
    local crate = spawnLocal(cfg.model or 'prop_box_wood05a', pos.x, pos.y, pos.z, GetEntityHeading(ent) + crateTurn(), true)
    if not crate then return end
    crates[ent] = { crate = crate }
    exports.ox_target:addLocalEntity(crate, { {
        name = 'cw_crate_' .. tostring(info.stash),
        label = info.label or cfg.targetLabel or 'Search Loot Crate',
        icon = cfg.targetIcon or 'fa-solid fa-box-open',
        distance = tonumber(cfg.targetDistance) or 2.5,
        onSelect = function()
            TriggerServerEvent('nova_convoytruck:containerWars:server:openCrate', info.convoyId, info.containerId)
        end,
    } })
end

-- A car-only lot shows a plain crate inside its container while it is auctioned (state 'cwDummyCrate'). It is only a prop: no target,
-- no loot. The car replaces it once the winner is confirmed (the server clears the state).
local function removeDummyCrate(ent)
    local crate = dummyCrates[ent]
    if not crate then return end
    dummyCrates[ent] = nil
    killEntity(crate)
end

local function placeDummyCrate(ent)
    removeDummyCrate(ent)
    local cfg = cwCfg().lootCrate or {}
    local p = doorParams(ent)
    local toMiddle = p.atFront and -1.0 or 1.0
    local pos = GetOffsetFromEntityInWorldCoords(ent, 0.0, p.hingeY + toMiddle * crateDepth(), p.minZ + crateLift())
    local crate = spawnLocal(cfg.model or 'prop_box_wood05a', pos.x, pos.y, pos.z, GetEntityHeading(ent) + crateTurn(), true)
    if crate then dummyCrates[ent] = crate end
end

AddStateBagChangeHandler('cwDummyCrate', nil, function(bagName, _, value)
    CreateThread(function()
        local ent = waitEntity(bagName)
        if not ent then return end
        if value then placeDummyCrate(ent) else removeDummyCrate(ent) end
    end)
end)

AddStateBagChangeHandler('cwCrate', nil, function(bagName, _, value)
    CreateThread(function()
        local ent = waitEntity(bagName)
        if not ent then return end
        if type(value) ~= 'table' then removeCrate(ent) return end
        placeCrate(ent, value)
    end)
end)

-- ── the crane ──────────────────────────────────────────────────────────────────────────────────

local function clearCrane()
    HookRope.remove('cw_event')
    for _, c in pairs(fx.cranes) do
        killEntity(c.frame); killEntity(c.cabin)
        for _, w in ipairs(c.wheels) do killEntity(w) end
    end
    for _, p in ipairs(fx.parts) do killEntity(p.ent) end
    for cid, g in pairs(fx.ghosts) do removeDoors(g.ent); killEntity(g.ent); fx.ghosts[cid] = nil end
    fx.cranes, fx.parts, fx.active, fx.hook = {}, {}, nil, nil
    fx.playing = false
end

local function clearAll()
    clearCrane()
    for ent in pairs(doorSets) do removeDoors(ent) end
    for ent in pairs(crates) do removeCrate(ent) end
    for ent in pairs(dummyCrates) do removeDummyCrate(ent) end
    for ent in pairs(heldOpen) do heldOpen[ent] = nil end
    hiddenReal, carryDrop = {}, {}
    fx.revealed = {}
    fx.convoyId = nil
end

-- Puts the active gantry, its hook and the spreader at a hook position. Returns where the hook really is.
local function poseHook(x, y, z, heading)
    local hx, hy = x, y
    local crane = fx.active and fx.cranes[fx.active]
    if crane then
        local lay = CWGantry.layout(crane.cfg, crane.ref, x, y)
        SetEntityCoordsNoOffset(crane.frame, lay.frame.x, lay.frame.y, lay.frame.z, false, false, false)
        if crane.cabin then SetEntityCoordsNoOffset(crane.cabin, lay.cabin.x, lay.cabin.y, lay.cabin.z, false, false, false) end
        for i, w in ipairs(crane.wheels) do
            local p = lay.wheels[i]
            if p then SetEntityCoordsNoOffset(w, p.x, p.y, p.z, false, false, false) end
        end
        hx, hy = lay.hook.x, lay.hook.y
    end
    for _, p in ipairs(fx.parts) do
        SetEntityCoordsNoOffset(p.ent, hx + p.def.x, hy + p.def.y, z + p.def.z, false, false, false)
        SetEntityHeading(p.ent, heading + p.def.heading)
    end
    return hx, hy
end

local function setActive(index)
    if not index or not fx.cranes[index] or fx.active == index then return end
    fx.active = index
    local holder = fx.parts[1] and fx.parts[1].ent
    if holder then HookRope.set('cw_event', holder, fx.cranes[index].armTop) end
end

-- Builds the crane: one local gantry per aisle, the spreader, the rope. Called when an event starts (and for a late joiner).
RegisterNetEvent('nova_convoytruck:containerWars:client:craneSetup', function(setup)
    clearCrane()
    if type(setup) ~= 'table' or type(setup.cranes) ~= 'table' then return end
    fx.convoyId = setup.convoyId
    for _, c in ipairs(setup.cranes) do
        local cfg = CWGantry.get(c.model)
        if cfg then
            local ref = { x = c.ref.x, y = c.ref.y, z = c.ref.z, heading = c.ref.heading, railMin = c.ref.railMin, railMax = c.ref.railMax }
            local parkAt = (setup.active == c.index and setup.hook) or ref
            local lay = CWGantry.layout(cfg, ref, parkAt.x, parkAt.y)
            local crane = { cfg = cfg, ref = ref, armTop = c.armTop, wheels = {} }
            crane.frame = spawnLocal(c.model, lay.frame.x, lay.frame.y, lay.frame.z, lay.frame.heading, true)
            if crane.frame then
                crane.cabin = cfg.cabin and spawnLocal(cfg.cabin.model, lay.cabin.x, lay.cabin.y, lay.cabin.z, lay.cabin.heading, false) or nil
                local wheelModel = cfg.wheels and cfg.wheels.model
                for _, p in ipairs(wheelModel and lay.wheels or {}) do
                    local w = spawnLocal(wheelModel, p.x, p.y, p.z, p.heading, true)
                    if w then crane.wheels[#crane.wheels + 1] = w end
                end
                fx.cranes[c.index] = crane
            end
        end
    end
    -- the spreader (the hook part that catches the container); the cable is drawn as a rope by hook_rope.lua
    local hookCfg = cwCfg().hook
    local hook = setup.hook
    if hookCfg and hookCfg.enabled ~= false and next(fx.cranes) and hook then
        for _, def in ipairs(hookCfg.parts or {}) do
            if not def.cable then
                local d = { x = tonumber(def.x) or 0.0, y = tonumber(def.y) or 0.0, z = tonumber(def.z) or 0.0, heading = tonumber(def.heading) or 0.0 }
                local ent = spawnLocal(def.model, hook.x + d.x, hook.y + d.y, hook.z + d.z, d.heading, false)
                if ent then fx.parts[#fx.parts + 1] = { ent = ent, def = d } end
            end
        end
    end
    setActive(setup.active or next(fx.cranes))
    if hook then fx.hook = { x = hook.x, y = hook.y, z = hook.z, h = 0.0 } end
    if hook then poseHook(hook.x, hook.y, hook.z, 0.0) end
end)

-- The container's local copy: rides the hook while the real one is hidden.
local function spawnGhost(plan)
    local old = fx.ghosts[plan.containerId]
    if old then removeDoors(old.ent); killEntity(old.ent) end
    local g = spawnLocal(plan.model, plan.pick.x, plan.pick.y, plan.pick.z, plan.pick.h, false)
    if not g then return nil end
    if modelHasDoors(plan.model) then ensureDoors(g) end
    fx.ghosts[plan.containerId] = { ent = g }
    return g
end

local function playPlan(plan)
    while fx.playing do Wait(100) end
    fx.playing = true
    fx.revealed[plan.containerId] = nil

    if plan.crane and fx.cranes[plan.crane] then
        local crane = fx.cranes[plan.crane]
        if plan.rail then crane.ref.railMin, crane.ref.railMax = plan.rail.lo, plan.rail.hi end
        setActive(plan.crane)
    end
    local ghost = spawnGhost(plan)
    local gx, gy, gz, gh = plan.pick.x, plan.pick.y, plan.pick.z, plan.pick.h
    local segs = plan.segs or {}
    local last = segs[#segs]
    local far = #(GetEntityCoords(PlayerPedId()) - vector3(plan.pick.x, plan.pick.y, plan.pick.z)) > (tonumber(cwCfg().animDistance) or 400.0)

    local t0, i, segStart = GetGameTimer(), 1, 0
    while segs[i] do
        local now = GetGameTimer() - t0
        while segs[i] and now >= segStart + segs[i].ms do segStart = segStart + segs[i].ms; i = i + 1 end
        local s = segs[i]
        if not s then break end
        if far then
            Wait(250)                                -- too far to see it: only the end state matters
        else
            local x, y, z, h = CWGantry.evalSegment(s, now - segStart)
            local hx, hy = poseHook(x, y, z, h)
            if s.carry then
                gx, gy, gz, gh = hx, hy, z, h
                if ghost and DoesEntityExist(ghost) then
                    SetEntityCoordsNoOffset(ghost, gx, gy, gz, false, false, false)
                    SetEntityHeading(ghost, gh)
                end
            end
            Wait(0)
        end
    end
    if last then
        local hx, hy = poseHook(last.bx, last.by, last.bz, last.bh)
        fx.hook = { x = last.bx, y = last.by, z = last.bz, h = last.bh }
        if ghost and DoesEntityExist(ghost) then
            SetEntityCoordsNoOffset(ghost, plan.drop.x, plan.drop.y, plan.drop.z, false, false, false)
            SetEntityHeading(ghost, plan.drop.h)
        end
    end

    -- the copy stays until the real container is visible on its pad again
    local real = (plan.netId and NetworkDoesNetworkIdExist(plan.netId)) and NetworkGetEntityFromNetworkId(plan.netId) or 0
    local needReveal = real ~= 0 and DoesEntityExist(real) and hiddenReal[real]
    local deadline = GetGameTimer() + 6000
    while needReveal and not fx.revealed[plan.containerId] and GetGameTimer() < deadline do Wait(100) end
    local g = fx.ghosts[plan.containerId]
    if g then removeDoors(g.ent); killEntity(g.ent); fx.ghosts[plan.containerId] = nil end
    fx.playing = false
end

RegisterNetEvent('nova_convoytruck:containerWars:client:craneMotion', function(plan)
    if type(plan) ~= 'table' or not plan.segs then return end
    CreateThread(function() playPlan(plan) end)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:craneClear', function()
    clearAll()
end)

-- The real container is hidden while its copy is carried, and shown again once the server has put it on its pad.
AddStateBagChangeHandler('cwCarry', nil, function(bagName, _, value)
    CreateThread(function()
        local ent = waitEntity(bagName, 4000)
        if not ent then return end
        local cid = Entity(ent).state.container_id
        if type(value) == 'table' then
            hiddenReal[ent] = true
            carryDrop[ent] = value.drop
            SetEntityVisible(ent, false, false)
            SetEntityCollision(ent, false, false)
            local set = doorSets[ent]
            if set then SetEntityVisible(set.left, false, false); SetEntityVisible(set.right, false, false) end
        else
            local drop = carryDrop[ent]
            if drop then
                local deadline = GetGameTimer() + 3000   -- wait until the position update has landed, or it would flash at the pickup
                while GetGameTimer() < deadline and #(GetEntityCoords(ent) - vector3(drop.x, drop.y, drop.z)) > 2.5 do Wait(50) end
            end
            hiddenReal[ent] = nil
            carryDrop[ent] = nil
            SetEntityVisible(ent, true, false)
            SetEntityCollision(ent, true, true)
            local set = doorSets[ent]
            if set then SetEntityVisible(set.left, true, false); SetEntityVisible(set.right, true, false) end
            if cid then fx.revealed[cid] = true end
        end
    end)
end)

-- ── housekeeping ───────────────────────────────────────────────────────────────────────────────

-- Doors and crates belong to a container; when it goes (event cleanup) so do they.
CreateThread(function()
    while true do
        Wait(2000)
        for ent, set in pairs(doorSets) do
            if not DoesEntityExist(ent) then removeDoors(ent) hiddenReal[ent] = nil end
        end
        for ent in pairs(crates) do
            if not DoesEntityExist(ent) then removeCrate(ent) end
        end
        for ent in pairs(dummyCrates) do
            if not DoesEntityExist(ent) then removeDummyCrate(ent) end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearAll()
end)

-- A client that joins (or restarts) while an event runs asks the server for the picture it missed.
CreateThread(function()
    Wait(4000)
    TriggerServerEvent('nova_convoytruck:containerWars:server:requestSync')
end)
RegisterNetEvent('qbx_core:client:playerLoaded', function()
    Wait(3000)
    TriggerServerEvent('nova_convoytruck:containerWars:server:requestSync')
end)

-- /cwopentest   a closed container with its doors fitted in front of you; it opens after 2 s, shuts again, and goes.
-- Use it to check the hinge position (Config.ContainerWars.openContainer.doors: zOffset, backOffset, atFront, openAngle, flip).
RegisterCommand('cwopentest', function(_, args)
    local d = doorCfg()
    local model = args[1] or 'prop_container_05mb'
    local ped = PlayerPedId()
    local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 9.0, 0.0)
    local obj = spawnLocal(model, pos.x, pos.y, pos.z, GetEntityHeading(ped) + 90.0, true)
    if not obj then
        lib.notify({ title = 'Door test', description = ('Model %s could not be created.'):format(model), type = 'error' })
        return
    end
    PlaceObjectOnGroundProperly(obj)
    local set = ensureDoors(obj)
    if not set then
        lib.notify({ title = 'Door test', description = ('The door props (%s / %s) are not in this game build.'):format(tostring(d.left and d.left.model), tostring(d.right and d.right.model)), type = 'error', duration = 8000 })
    else
        lib.notify({ title = 'Door test', description = modelHasDoors(model) and 'Doors fitted closed — opening in 2 s.' or ('%s is not listed in doors.models; the doors are fitted anyway so you can see where they sit.'):format(model), type = 'inform', duration = 6000 })
        Wait(2000)
        animateDoors(set, 0.0, 1.0)
        Wait((set.p.swing + 2.0) * 1000)
        animateDoors(set, 1.0, 0.0)
        Wait((set.p.swing + 1.5) * 1000)
    end
    removeDoors(obj)
    killEntity(obj)
end, false)

-- /cwopenanim [model]   tests the opened pose on each auctionable container model in turn (6 s each, name on screen) and prints one result
-- line per model to the F8 console AND the server console: does the model exist, does it have bones, does the opening clip play on it.
-- "OPENS" = the clip plays on it (check by eye that the doors really move); "NO OPEN CLIP" = add  opens = false  to that entry in
-- Config.ContainerWars.containerModels.
RegisterCommand('cwopenanim', function(_, args)
    local list = args[1] and { { model = args[1] } } or cwCfg().containerModels or {}
    local ped = PlayerPedId()
    local lines = {}
    for _, m in ipairs(list) do
        local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 9.0, 0.0)
        local obj = spawnLocal(m.model, pos.x, pos.y, pos.z, GetEntityHeading(ped) + 90.0, true)
        local line
        if obj then
            PlaceObjectOnGroundProperly(obj)
            lib.notify({ title = 'Open test', description = m.model, type = 'inform', duration = 5500 })
            local bones = GetEntityBoneCount(obj)
            local scene = playHeldOpen(obj)
            Wait(1500)
            local playing = scene and IsEntityPlayingAnim(obj, OPEN_DICT, OPEN_CLIP, 3) or false
            local phase = type(scene) == 'number' and GetSynchronizedScenePhase(scene) or -1.0   -- 'pose' = held with PlayEntityAnim, no scene
            Wait(4500)
            if type(scene) == 'number' then pcall(NetworkStopSynchronisedScene, scene) end
            killEntity(obj)
            line = ('%s: %s (bones=%d, clip playing=%s, scene phase=%.2f)'):format(m.model, playing and 'OPENS' or 'NO OPEN CLIP', bones, tostring(playing), phase)
        else
            line = ('%s: NOT CREATED (model missing in this game build)'):format(m.model)
        end
        lines[#lines + 1] = line
        print('[cwopenanim] ' .. line)
    end
    TriggerServerEvent('nova_convoytruck:containerWars:server:logOpenTest', lines)
    lib.notify({ title = 'Open test', description = 'Done - results are in the F8 console and the server console.', type = 'success', duration = 8000 })
end, false)

-- /cwlootest [model]   a LOCAL test of an item container, nobody else sees it: the container stands 9 m ahead, you play the real opening
-- scene (lock cut) on it, the opened pose is held the way a won container's is, and the loot crate appears inside with a target so you
-- can check you can reach it. Pressing the target only shows a message (no server, no loot) and the test clears 3 s later; otherwise it
-- clears after 60 s. /cwlootest clear removes it at once. What it reports (also in F8): how the open pose is held, and whether the clip is playing.
local lootTest = {}
local lootAll = {}   -- EVERY entity a test run made, so a clear removes them even if a run got interrupted half way
local lootRun = 0    -- a newer run (or a clear) makes an older, still waiting run stop and clean up after itself

local function lootMade(e)
    if e and e ~= 0 then lootAll[#lootAll + 1] = e end
    return e
end

local function clearLootTest()
    lootRun = lootRun + 1
    local t = lootTest
    lootTest = {}
    if t.crate and DoesEntityExist(t.crate) then pcall(function() exports.ox_target:removeLocalEntity(t.crate) end) end
    if t.obj then
        localOpen[t.obj] = nil
        releaseOpen(t.obj)
    end
    local n = 0
    for _, e in ipairs(lootAll) do
        if DoesEntityExist(e) then n = n + 1 killEntity(e) end
    end
    lootAll = {}
    return n
end

RegisterCommand('cwlootest', function(_, args)
    if args[1] == 'clear' then
        local n = clearLootTest()
        lib.notify({ title = 'Loot test', description = ('Removed %d object(s).'):format(n), type = 'inform' })
        return
    end
    clearLootTest()
    local run = lootRun
    local model = args[1] or 'tr_prop_tr_container_01a'
    local ped = PlayerPedId()
    local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 9.0, 0.0)
    local obj = lootMade(spawnLocal(model, pos.x, pos.y, pos.z, GetEntityHeading(ped), true))   -- open (back) end toward you
    if not obj then
        lib.notify({ title = 'Loot test', description = ('Model %s could not be created.'):format(model), type = 'error' })
        return
    end
    PlaceObjectOnGroundProperly(obj)
    lootTest = { obj = obj }
    if not loadOpenDict() then
        lib.notify({ title = 'Loot test', description = 'The opening animation could not be loaded.', type = 'error' })
        clearLootTest()
        return
    end
    lib.notify({ title = 'Loot test', description = ('%s: cutting the lock...'):format(model), type = 'inform', duration = 6000 })

    local cpos, crot = GetEntityCoords(obj), GetEntityRotation(obj, 2)
    local scene = CreateSynchronizedScene(cpos.x, cpos.y, cpos.z, crot.x, crot.y, crot.z, 2)
    SetSynchronizedSceneHoldLastFrame(scene, true)
    SetSynchronizedSceneLooped(scene, false)
    -- the same props the real opening uses: lock, angle grinder, bag (each has its own clip in the scene)
    local propDefs = {
        { 'tr_prop_tr_lock_01a', 'action_lock' },
        { 'tr_prop_tr_grinder_01a', 'action_angle_grinder' },
        { 'ch_p_m_bag_var02_arm_s', 'action_bag' },
    }
    local props, propReport = {}, {}
    local pedPos = GetEntityCoords(ped)
    for _, d in ipairs(propDefs) do
        local hash = joaat(d[1])
        local prop
        if IsModelInCdimage(hash) and pcall(lib.requestModel, hash, 8000) then
            prop = lootMade(CreateObject(hash, pedPos.x, pedPos.y, pedPos.z, false, false, false))
            SetModelAsNoLongerNeeded(hash)
        end
        if prop and prop ~= 0 and DoesEntityExist(prop) then
            props[#props + 1] = prop
            PlaySynchronizedEntityAnim(prop, scene, d[2], OPEN_DICT, 1.0, -1.0, 0, 1148846080)
            propReport[#propReport + 1] = d[1] .. ' ok'
        else
            propReport[#propReport + 1] = d[1] .. (IsModelInCdimage(hash) and ' NOT CREATED' or ' MISSING in this game build')
        end
    end
    lootTest.props = props
    TaskSynchronizedScene(ped, scene, OPEN_DICT, 'action', 4.0, -4.0, 1033, 0, 1000.0, 0)
    PlaySynchronizedEntityAnim(obj, scene, OPEN_CLIP, OPEN_DICT, 1.0, -1.0, 0, 1148846080)
    print('[cwlootest] props: ' .. table.concat(propReport, ', '))
    local giveUp = GetGameTimer() + 20000
    Wait(500)
    while GetGameTimer() < giveUp and IsSynchronizedSceneRunning(scene) and GetSynchronizedScenePhase(scene) < 0.98 do Wait(100) end
    for _, prop in ipairs(props) do killEntity(prop) end
    lootTest.props = nil
    if run ~= lootRun then return end   -- cleared while the scene was playing: everything is already gone

    -- is the doorway really blocked? A ray from outside the open end to the middle of the container, before collision is lifted
    local dp = doorParams(obj)
    local a = GetOffsetFromEntityInWorldCoords(obj, 0.0, dp.hingeY + (dp.atFront and 3.0 or -3.0), dp.minZ + 1.0)
    local b = GetOffsetFromEntityInWorldCoords(obj, 0.0, dp.hingeY + (dp.atFront and -2.0 or 2.0), dp.minZ + 1.0)
    local rh, hit, _, _, hitEnt = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 17, ped, 4))
    local doorway = (hit == 1 and hitEnt == obj) and 'BLOCKED by the container model (invisible wall at the entrance)' or 'clear'
    print('[cwlootest] doorway before collision off: ' .. doorway)

    -- same order as a won container: hold the pose first, then release the player
    localOpen[obj] = true
    holdOpen(obj)
    ClearPedTasks(ped)
    Wait(1500)
    if run ~= lootRun then return end
    local held = heldOpen[obj]
    local how = held == 'pose' and 'PlayEntityAnim (stay in anim)' or (type(held) == 'number' and 'synchronised scene (fallback)' or 'NOT HELD (the model refused the clip, or it has no doors)')
    local playing = IsEntityPlayingAnim(obj, OPEN_DICT, OPEN_CLIP, 3)

    -- the crate, at the spot a real loot crate takes (placeCrate)
    local cfg = cwCfg().lootCrate or {}
    local p = doorParams(obj)
    local y = p.hingeY + (p.atFront and -1.0 or 1.0) * crateDepth()
    local cp = GetOffsetFromEntityInWorldCoords(obj, 0.0, y, p.minZ + crateLift())
    local crate = lootMade(spawnLocal(cfg.model or 'prop_box_wood05a', cp.x, cp.y, cp.z, GetEntityHeading(obj) + crateTurn(), true))
    if crate then
        lootTest.crate = crate
        exports.ox_target:addLocalEntity(crate, { {
            name = 'cw_loottest_crate',
            label = 'Search Loot Crate (test)',
            icon = cfg.targetIcon or 'fa-solid fa-box-open',
            distance = tonumber(cfg.targetDistance) or 2.5,
            onSelect = function()
                lib.notify({ title = 'Loot test', description = 'You can reach the crate. (Test only: nothing was given.) Clearing in 3 s.', type = 'success', duration = 6000 })
                SetTimeout(3000, function() if lootTest.obj == obj then clearLootTest() end end)
            end,
        } })
    end
    local line = ('%s: pose held by %s, clip playing=%s, crate %s; props: %s; doorway %s'):format(model, how, tostring(playing), crate and 'placed' or 'NOT created', table.concat(propReport, ', '), doorway)
    print('[cwlootest] ' .. line)
    lib.notify({ title = 'Loot test', description = line .. '. Walk in and target the crate: it clears itself 3 s after, or after 60 s.', type = (held and crate) and 'success' or 'error', duration = 12000 })
    SetTimeout(60000, function() if lootTest.obj == obj then clearLootTest() end end)
end, false)

-- /cwprobe [model ...]   measures container models and prints one line each to the F8 console AND the server console: size, whether a car
-- fits, and whether either END of the container is open (a ray from outside reaches the inside = door props can be fitted there).
-- With no model it tests the auction list plus the game's own container props. Each model takes about a second.
RegisterCommand('cwprobe', function(_, args)
    local models = {}
    if args[1] == 'covers' then
        -- props that might close the 2.6 x 2.7 m open end of prop_container_ld (looking for one about that size, thin)
        models = { 'prop_container_door_mb_l', 'prop_container_door_mb_r', 'prop_barn_door_l', 'prop_barn_door_r', 'p_gar_door_01_s', 'p_gar_door_02_s',
            'p_gar_door_03_s', 'prop_facgate_01', 'prop_facgate_01b', 'prop_conslift_door', 'prop_arm_gate_l', 'prop_armenian_gate',
            'prop_car_door_01', 'prop_byard_ramp', 'prop_drywallpile_01', 'prop_container_ld_d' }
    elseif #args > 0 then
        for _, a in ipairs(args) do models[#models + 1] = a end
    else
        for _, m in ipairs(cwCfg().containerModels or {}) do models[#models + 1] = m.model end
        for _, n in ipairs({ 'prop_container_01a', 'prop_container_01b', 'prop_container_01c', 'prop_container_01d', 'prop_container_01e',
            'prop_container_01f', 'prop_container_01g', 'prop_container_01h', 'prop_container_01mb', 'prop_container_02a', 'prop_container_03a',
            'prop_container_03b', 'prop_container_03mb', 'prop_container_04a', 'prop_container_04mb', 'prop_container_05a', 'prop_container_05mb',
            'prop_container_ld', 'prop_container_ld2', 'prop_contr_03_ld' }) do
            local dup = false
            for _, e in ipairs(models) do if e == n then dup = true end end
            if not dup then models[#models + 1] = n end
        end
    end
    local ped = PlayerPedId()
    local lines = {}
    lib.notify({ title = 'Container probe', description = ('Testing %d models, stand still...'):format(#models), type = 'inform', duration = 6000 })
    for _, model in ipairs(models) do
        local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 14.0, 0.0)
        local obj = spawnLocal(model, pos.x, pos.y, pos.z, GetEntityHeading(ped) + 90.0, true)
        local line
        if obj then
            PlaceObjectOnGroundProperly(obj)
            Wait(400)
            local mn, mx = GetModelDimensions(GetEntityModel(obj))
            local len, wid, hgt = mx.y - mn.y, mx.x - mn.x, mx.z - mn.z
            local midY, z = (mn.y + mx.y) / 2.0, mn.z + 1.2
            -- from 8 m outside one end, along the container, at car height: a closed end is hit about 8 m away, an open end lets the ray in
            local function endState(fromY)
                local a = GetOffsetFromEntityInWorldCoords(obj, 0.0, fromY, z)
                local b = GetOffsetFromEntityInWorldCoords(obj, 0.0, midY, z)
                local ray = StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 16, ped, 4)
                local _, hit, hitPos = GetShapeTestResult(ray)
                if hit ~= 1 then return 'OPEN (no hit)' end
                local d = #(hitPos - a)
                return d < 9.2 and ('closed (hit at %.1f m)'):format(d) or ('OPEN (hit at %.1f m)'):format(d)
            end
            local front, back = endState(mx.y + 8.0), endState(mn.y - 8.0)
            local fits = len >= 7.0 and wid >= 2.2
            line = ('%s: %.1f x %.1f x %.1f m (length x width x height), bones=%d, front end %s, back end %s, %s'):format(
                model, len, wid, hgt, GetEntityBoneCount(obj), front, back, fits and 'FITS A CAR' or 'TOO SMALL FOR A CAR')
            killEntity(obj)
        else
            line = ('%s: NOT CREATED (not in this game build)'):format(model)
        end
        lines[#lines + 1] = line
        print('[cwprobe] ' .. line)
    end
    TriggerServerEvent('nova_convoytruck:containerWars:server:logOpenTest', lines)
    lib.notify({ title = 'Container probe', description = 'Done - results are in the F8 console and the server console.', type = 'success', duration = 8000 })
end, false)

-- /cwcartest [car model] [container model] [flip]   puts a dummy car inside a container in front of you for 25 s, at the SAME spot the server
-- uses when a winner opens a car lot (origin + 0.35 up, container heading), so you can see how it sits. "flip" turns the car round.
-- Prints the container's size and origin height to the F8 console. Everything is local to you and removed afterwards.
RegisterCommand('cwcartest', function(_, args)
    local carName = args[1] or 'sultan'
    local boxName = args[2] or 'prop_container_ld'
    lib.notify({ title = 'Car test', description = ('Starting: %s inside %s...'):format(carName, boxName), type = 'inform', duration = 3000 })
    local ped = PlayerPedId()
    local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 16.0, 0.0)
    local box = spawnLocal(boxName, pos.x, pos.y, pos.z, GetEntityHeading(ped) + 90.0, true)
    if not box then
        lib.notify({ title = 'Car test', description = ('Container %s could not be created.'):format(boxName), type = 'error' })
        return
    end
    PlaceObjectOnGroundProperly(box)
    local carHash = joaat(carName)
    if not IsModelInCdimage(carHash) or not pcall(lib.requestModel, carHash, 8000) then
        killEntity(box)
        lib.notify({ title = 'Car test', description = ('Vehicle %s does not exist.'):format(carName), type = 'error' })
        return
    end
    local at = GetOffsetFromEntityInWorldCoords(box, 0.0, 0.0, 0.35)
    local heading = GetEntityHeading(box) + ((args[3] == 'flip') and 180.0 or 0.0)
    local car = CreateVehicle(carHash, at.x, at.y, at.z, heading, false, false)
    SetModelAsNoLongerNeeded(carHash)
    if not car or car == 0 then
        killEntity(box)
        lib.notify({ title = 'Car test', description = 'The car could not be created.', type = 'error' })
        return
    end
    FreezeEntityPosition(car, true)
    local mn, mx = GetModelDimensions(GetEntityModel(box))
    local cmn, cmx = GetModelDimensions(carHash)
    print(('[cwcartest] container %s: origin height range %.2f..%.2f, length %.1f; car %s: length %.1f, width %.1f'):format(
        boxName, mn.z, mx.z, mx.y - mn.y, carName, cmx.y - cmn.y, cmx.x - cmn.x))
    lib.notify({ title = 'Car test', description = ('%s inside %s for 25 s. Walk round it.'):format(carName, boxName), type = 'inform', duration = 8000 })
    Wait(25000)
    DeleteEntity(car)
    killEntity(box)
end, false)

-- /cwcarlot [car model] [container model]   a LOCAL run of a car lot, only you see it: the container stands 16 m ahead with its dummy crate
-- (the auction), 5 s later the crate goes and the car appears inside at the spot the server uses (origin + 0.35 up, turned to face the open
-- end), with a "Claim" target. Using the target only shows a message and the test clears 3 s later; otherwise it clears after 60 s.
-- /cwcarlot clear removes it at once. The size report goes to F8.
local carLotTest = {}

local function clearCarLotTest()
    local t = carLotTest
    carLotTest = {}
    if t.car and DoesEntityExist(t.car) then
        pcall(function() exports.ox_target:removeLocalEntity(t.car) end)
        DeleteEntity(t.car)
    end
    if t.box then
        removeDummyCrate(t.box)
        killEntity(t.box)
    end
end

RegisterCommand('cwcarlot', function(_, args)
    if args[1] == 'clear' then
        clearCarLotTest()
        lib.notify({ title = 'Car lot test', description = 'Removed.', type = 'inform' })
        return
    end
    clearCarLotTest()
    local carName = args[1] or 'sultan'
    local boxName = args[2] or 'prop_container_ld'
    local carHash = joaat(carName)
    if not IsModelInCdimage(carHash) then
        lib.notify({ title = 'Car lot test', description = ('Vehicle %s does not exist.'):format(carName), type = 'error' })
        return
    end
    local ped = PlayerPedId()
    local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 16.0, 0.0)
    local box = spawnLocal(boxName, pos.x, pos.y, pos.z, GetEntityHeading(ped), true)
    if not box then
        lib.notify({ title = 'Car lot test', description = ('Container %s could not be created.'):format(boxName), type = 'error' })
        return
    end
    PlaceObjectOnGroundProperly(box)
    carLotTest = { box = box }
    placeDummyCrate(box)
    lib.notify({ title = 'Car lot test', description = ('%s with its dummy crate: "bidding" for 5 s, then the car appears.'):format(boxName), type = 'inform', duration = 5000 })
    Wait(5000)
    if carLotTest.box ~= box then return end   -- cleared meanwhile

    removeDummyCrate(box)
    if not pcall(lib.requestModel, carHash, 8000) then
        lib.notify({ title = 'Car lot test', description = 'The car model could not be loaded.', type = 'error' })
        clearCarLotTest()
        return
    end
    local at = GetOffsetFromEntityInWorldCoords(box, 0.0, 0.0, 0.35)
    local heading = GetEntityHeading(box)
    for _, m in ipairs(cwCfg().containerModels or {}) do
        if joaat(m.model) == GetEntityModel(box) and m.openEnd == 'back' then heading = (heading + 180.0) % 360.0 end
    end
    local car = CreateVehicle(carHash, at.x, at.y, at.z, heading, false, false)
    SetModelAsNoLongerNeeded(carHash)
    if not car or car == 0 then
        lib.notify({ title = 'Car lot test', description = 'The car could not be created.', type = 'error' })
        clearCarLotTest()
        return
    end
    FreezeEntityPosition(car, true)
    SetVehicleEngineOn(car, false, true, true)
    carLotTest.car = car

    local mn, mx = GetModelDimensions(GetEntityModel(box))
    local cmn, cmx = GetModelDimensions(carHash)
    local floorZ = GetEntityCoords(box).z + mn.z
    local roofZ = GetEntityCoords(box).z + mx.z
    local carBottom = GetEntityCoords(car).z + cmn.z
    local carTop = GetEntityCoords(car).z + cmx.z
    local line = ('%s in %s: container %.1f x %.1f x %.1f m, car %.1f x %.1f x %.1f m; car bottom %+.2f m from the floor, top %+.2f m from the roof (negative = inside)'):format(
        carName, boxName, mx.y - mn.y, mx.x - mn.x, mx.z - mn.z, cmx.y - cmn.y, cmx.x - cmn.x, cmx.z - cmn.z, carBottom - floorZ, carTop - roofZ)
    print('[cwcarlot] ' .. line)

    exports.ox_target:addLocalEntity(car, { {
        name = 'cw_carlot_claim',
        label = ('Claim Won %s (test)'):format(carName),
        icon = 'fa-solid fa-car-side',
        distance = 3.5,
        onSelect = function()
            lib.notify({ title = 'Car lot test', description = 'You can claim the car. (Test only: nothing was given.) Clearing in 3 s.', type = 'success', duration = 6000 })
            SetTimeout(3000, function() if carLotTest.box == box then clearCarLotTest() end end)
        end,
    } })
    lib.notify({ title = 'Car lot test', description = 'Dummy crate gone, car is in. Walk up and target it. It clears itself 3 s after, or after 60 s. Sizes are in F8.', type = 'success', duration = 12000 })
    SetTimeout(60000, function() if carLotTest.box == box then clearCarLotTest() end end)
end, false)

CWFx.clearAll = clearAll
CWFx.modelHasDoors = modelHasDoors
