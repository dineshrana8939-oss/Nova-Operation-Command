-- ─── Shared Prop Placer (client) ───────────────────────────────────────────────
-- ONE placement tool for every event. The tablet (or /propplacer, or another resource) opens it with a
-- CONTEXT (Config.PropPlacer.contexts) and a list of objects; it returns the edited list.
--
--   exports.nova_convoytruck:OpenPropPlacer({ context = 'convoy', objects = {...}, focus = {x,y,z} }, function(result) end)
--   NUI callback 'placer:open'  (the tablet)   — the answer is the callback's reply, sent when the session ends
--
-- The workspace is the real game world seen through a free camera:
--   hold the RIGHT mouse button   look around, and fly with W A S D (Q down, E up, Shift = fast)
--   mouse wheel                    dolly forward / back            Alt + wheel  rotate the armed asset / selection
--   LEFT click                     place the armed asset, or select (Shift = add / remove from the selection)
--   drag (Move tool)               move the object under the cursor          drag (Rotate tool)  turn it
-- Everything else (assets, numbers, duplicate, batch, save) is the NUI window, web/src/lib/placer.
--
-- This file is the single writer of the layout: the NUI only sends commands and draws the state it is sent.
-- Every object is its own table with its own transform (model, x y z, rx ry rz, stack, collision); a
-- duplicate is a brand new table, so moving one never moves another.

PropPlacer = PropPlacer or {}

local S = nil   -- the running session, nil when closed
local clearPreview   -- (defined with the in-world preview callbacks below)

-- ── small helpers ──────────────────────────────────────────────────────────────
local function cfg() return Config.PropPlacer or {} end
local function round(n, p)
    local m = 10 ^ (p or 3)
    return math.floor(n * m + 0.5) / m
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function wrap360(a) return a % 360.0 end

local KNOWN = { model = true, x = true, y = true, z = true, heading = true, rx = true, ry = true, rz = true,
                stack = true, step = true, collision = true, uid = true, kind = true, id = true }

local function newUid()
    return ('p%x%x'):format(GetGameTimer() % 0xFFFFFF, math.random(0, 0xFFFF))
end

local function context(id)
    local all = cfg().contexts or {}
    return all[id or 'generic'] or all.generic or {}
end

-- camera basis from pitch / yaw (degrees): forward, right, up
local function basis(pitch, yaw)
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp, sp, cy, sy = math.cos(p), math.sin(p), math.cos(y), math.sin(y)
    return vector3(-sy * cp, cy * cp, sp), vector3(cy, sy, 0.0), vector3(sy * sp, -cy * sp, cp)
end

-- the world-space ray under a screen point; nx, ny in [-1, 1] (right / up positive)
local function screenRay(nx, ny)
    local cam = S.cam
    local f, r, u = basis(cam.pitch, cam.yaw)
    local t = math.tan(math.rad(cam.fov) / 2.0)
    local aspect = S.aspect or 1.7778
    local d = f + r * (nx * t * aspect) + u * (ny * t)
    local len = #d
    if len < 0.0001 then return vector3(cam.x, cam.y, cam.z), f end
    return vector3(cam.x, cam.y, cam.z), d / len
end

-- ── ray casting ────────────────────────────────────────────────────────────────
local RAY_FLAGS = 1 + 2 + 16 + 256   -- the map, vehicles, objects, vegetation (not peds)
local function probe(a, b)
    local h = StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, RAY_FLAGS, 0, 4)
    local _, hit, pos, normal, ent = GetShapeTestResult(h)
    return hit == 1, pos, normal, ent
end

-- First hit along from→to; `skip` is a set of entities the ray passes through (the object being dragged,
-- the ghost) so they never block their own placement.
local function castRay(from, to, skip)
    local a = from
    local dir = to - from
    local total = #dir
    if total < 0.001 then return nil end
    dir = dir / total
    for _ = 1, 8 do
        local hit, pos, normal, ent = probe(a, to)
        if not hit then return nil end
        if skip and ent and ent ~= 0 and skip[ent] then
            a = pos + dir * 0.05
        else
            return pos, normal, ent
        end
    end
    return nil
end

-- ── models & entities ──────────────────────────────────────────────────────────
local function loadModel(hash)
    if not IsModelInCdimage(hash) then return false end
    if S and S.loaded[hash] then return true end
    local ok = pcall(lib.requestModel, hash, 6000)
    if ok and S then S.loaded[hash] = true end
    return ok
end

local function modelInfo(name)
    local hash = joaat(name)
    if S and S.info[hash] then return S.info[hash] end
    local info = { hash = hash, valid = false, vehicle = false, mn = vector3(0, 0, 0), mx = vector3(1, 1, 1) }
    if IsModelInCdimage(hash) then
        info.valid = true
        info.vehicle = IsModelAVehicle(hash) == true
        if loadModel(hash) then
            local mn, mx = GetModelDimensions(hash)
            if mn and mx then info.mn, info.mx = mn, mx end
        end
    end
    if S then S.info[hash] = info end
    return info
end

local function deleteEntities(list)
    for _, e in ipairs(list or {}) do
        if e and DoesEntityExist(e) then
            NovaDraw.outline(e, false)
            DeleteEntity(e)
        end
    end
end

local function placeEntity(ent, x, y, z, rx, ry, rz)
    SetEntityCoordsNoOffset(ent, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetEntityRotation(ent, rx + 0.0, ry + 0.0, rz + 0.0, 2, true)
end

local function makeEntity(vehicle, hash, x, y, z, rx, ry, rz, alpha)
    local ent
    if vehicle then
        ent = CreateVehicle(hash, x + 0.0, y + 0.0, z + 0.0, rz + 0.0, false, false)
    else
        ent = CreateObject(hash, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    end
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    FreezeEntityPosition(ent, true)
    placeEntity(ent, x, y, z, rx, ry, rz)
    if vehicle then
        SetVehicleEngineOn(ent, false, true, true)
        SetVehicleDoorsLocked(ent, 10)
        SetEntityInvincible(ent, true)
    end
    SetEntityLodDist(ent, 4000)
    if alpha and alpha < 255 then SetEntityAlpha(ent, alpha, false) end
    return ent
end

-- ── objects ────────────────────────────────────────────────────────────────────
local ALPHA_HOLOGRAM = 150

-- An object = the saved data + the entities that show it in the world.
local function assetOf(model)
    return S.assetByModel[(model or ''):lower()]
end

local function stackable(o)
    local a = assetOf(o.model)
    return a and a.stackable == true and S.features.stack and not o.vehicle
end

local function measureStep(o)
    local a = assetOf(o.model)
    if a and tonumber(a.step) then return tonumber(a.step) end
    local info = modelInfo(o.model)
    local h = info.mx.z - info.mn.z
    if h > 0.5 then return round(h, 3) end
    local H = (Config.ContainerWars or {}).harbour or {}
    return tonumber(H.dummyStep) or 2.6
end

local function destroyEntities(o)
    for _, e in ipairs(o.ents) do S.entToObj[e] = nil end
    deleteEntities(o.ents)
    o.ents = {}
end

local function buildEntities(o)
    destroyEntities(o)
    local info = modelInfo(o.model)
    o.vehicle = info.vehicle
    o.missing = not info.valid
    if not info.valid or not loadModel(info.hash) then o.missing = true return end
    local pieces = stackable(o) and clamp(o.stack or 1, 1, S.features.maxStack) or 1
    o.stack = pieces
    local alpha = o.spawned and 255 or ALPHA_HOLOGRAM
    for k = 0, pieces - 1 do
        local ent = makeEntity(o.vehicle, info.hash, o.x, o.y, o.z + k * (o.step or 0), o.rx, o.ry, o.rz, alpha)
        if not ent then
            if k == 0 then o.missing = true end
            break
        end
        o.ents[#o.ents + 1] = ent
        S.entToObj[ent] = o.id
    end
end

local function applyTransform(o)
    -- a plain prop may be tilted; a stack stays upright so its pieces line up
    if stackable(o) then o.rx, o.ry = 0.0, 0.0 end
    -- the trailer that rides along with a single truck is created the first time that truck is placed
    if S.companion and not S.companion.ownerId then
        S.companion.ownerId = o.id
        S.companion.ent = makeEntity(true, S.companion.hash, o.x, o.y, o.z, 0.0, 0.0, o.rz, ALPHA_HOLOGRAM)
        if S.companion.ent then SetEntityCollision(S.companion.ent, false, false) end
    end
    for k, e in ipairs(o.ents) do
        if DoesEntityExist(e) then placeEntity(e, o.x, o.y, o.z + (k - 1) * (o.step or 0), o.rx, o.ry, o.rz) end
    end
    if S.companion and S.companion.ent and o.id == S.companion.ownerId then
        local rad = math.rad(o.rz)
        local back = S.companion.back
        placeEntity(S.companion.ent, o.x + math.sin(rad) * back, o.y - math.cos(rad) * back, o.z, 0.0, 0.0, o.rz)
    end
end

local function setAlpha(o)
    for _, e in ipairs(o.ents) do
        if DoesEntityExist(e) then
            if o.spawned then ResetEntityAlpha(e) else SetEntityAlpha(e, ALPHA_HOLOGRAM, false) end
        end
    end
end

local function plain(o)
    return {
        id = o.id, uid = o.uid, model = o.model, vehicle = o.vehicle == true, missing = o.missing == true,
        x = round(o.x), y = round(o.y), z = round(o.z), rx = round(o.rx, 2), ry = round(o.ry, 2), rz = round(o.rz, 2),
        stack = o.stack or 1, step = o.step, collision = o.collision ~= false, spawned = o.spawned ~= false,
        stackable = stackable(o) == true, locked = o.locked == true,
    }
end

-- the saved form (what the tablet stores): the legacy {model,x,y,z,heading} shape plus what is non-default
local function exported(o)
    local out = {}
    for k, v in pairs(o.extra or {}) do out[k] = v end
    out.model = o.model
    -- a vehicle model is always saved as one, even if the engine flag was not available when it was added
    local a = assetOf(o.model)
    out.kind = (o.vehicle or (a and a.vehicle == true)) and 'vehicle' or 'object'
    out.x, out.y, out.z = round(o.x), round(o.y), round(o.z)
    out.heading = round(wrap360(o.rz), 2)
    out.exact = true   -- placed exactly: runtime code must not "settle it onto the ground"
    out.uid = o.uid
    if (o.rx or 0.0) ~= 0.0 then out.rx = round(o.rx, 2) end
    if (o.ry or 0.0) ~= 0.0 then out.ry = round(o.ry, 2) end
    if stackable(o) then
        out.stack = o.stack or 1
        out.step = round(o.step or 2.6)
    end
    if o.collision == false then out.collision = false end
    return out
end

local function exportAll()
    local list = {}
    for _, o in ipairs(S.objects) do list[#list + 1] = exported(o) end
    return list
end

local function snapshot()
    local list = {}
    for _, o in ipairs(S.objects) do
        list[#list + 1] = {
            id = o.id, uid = o.uid, model = o.model, x = o.x, y = o.y, z = o.z, rx = o.rx, ry = o.ry, rz = o.rz,
            stack = o.stack, step = o.step, collision = o.collision, spawned = o.spawned, extra = o.extra, locked = o.locked,
        }
    end
    return { list = list, selected = (function() local t = {} for id in pairs(S.selected) do t[id] = true end return t end)(), active = S.active }
end

-- ── NUI state ──────────────────────────────────────────────────────────────────
local function selectedList()
    local ids = {}
    for _, o in ipairs(S.objects) do
        if S.selected[o.id] then ids[#ids + 1] = o.id end
    end
    return ids
end

local function armedView()
    if not S.armed then return nil end
    local a = assetOf(S.armed.model)
    return {
        model = S.armed.model, label = a and a.label or S.armed.model,
        vehicle = S.armed.vehicle == true, stackable = S.armed.stackable == true,
        stack = S.armed.stack, rz = round(S.armed.rz, 1),
    }
end

local function stateMessage()
    local objects = {}
    for _, o in ipairs(S.objects) do objects[#objects + 1] = plain(o) end
    return {
        action = 'placer:state',
        objects = objects, selected = selectedList(), active = S.active,
        tool = S.tool, armed = armedView(),
        flags = { snapGround = S.snapGround, grid = S.grid, gridSize = S.gridSize, keepTool = S.keepTool, spawnOnPlace = S.spawnOnPlace },
        canUndo = #S.undo > 0, canRedo = #S.redo > 0, dirty = S.dirty,
    }
end

local function markFull() S.needFull = true end
local function markPatch(o) S.patch[o.id] = true end

local function notice(text, kind)
    SendNUIMessage({ action = 'placer:notice', text = text, kind = kind or 'info' })
end

local function flush(now)
    if now - S.lastSend < 60 then return end
    if S.needFull then
        S.needFull, S.patch, S.lastSend = false, {}, now
        SendNUIMessage(stateMessage())
    elseif next(S.patch) then
        local list = {}
        for id in pairs(S.patch) do
            local o = S.byId[id]
            if o then list[#list + 1] = plain(o) end
        end
        S.patch, S.lastSend = {}, now
        SendNUIMessage({ action = 'placer:patch', objects = list })
    end
end

-- ── undo / redo ────────────────────────────────────────────────────────────────
local function pushUndo(key)
    local now = GetGameTimer()
    if key and S.undoKey == key and now - S.undoAt < 900 then S.undoAt = now return end   -- one step for a burst of nudges
    S.undoKey, S.undoAt = key, now
    S.undo[#S.undo + 1] = snapshot()
    if #S.undo > 60 then table.remove(S.undo, 1) end
    S.redo = {}
    S.dirty = true
end

local function rebuildFrom(snap)
    for _, o in ipairs(S.objects) do destroyEntities(o) end
    S.objects, S.byId = {}, {}
    for _, d in ipairs(snap.list) do
        local o = {
            id = d.id, uid = d.uid, model = d.model, x = d.x, y = d.y, z = d.z, rx = d.rx, ry = d.ry, rz = d.rz,
            stack = d.stack, step = d.step, collision = d.collision, spawned = d.spawned, extra = d.extra, locked = d.locked, ents = {},
        }
        buildEntities(o)
        S.objects[#S.objects + 1] = o
        S.byId[o.id] = o
    end
    S.selected, S.active = {}, nil
    for id in pairs(snap.selected or {}) do if S.byId[id] then S.selected[id] = true end end
    if snap.active and S.byId[snap.active] then S.active = snap.active end
    for _, o in ipairs(S.objects) do applyTransform(o) end
    markFull()
end

local function undo()
    if #S.undo == 0 then return end
    S.redo[#S.redo + 1] = snapshot()
    rebuildFrom(table.remove(S.undo))
    S.undoKey = nil
end

local function redo()
    if #S.redo == 0 then return end
    S.undo[#S.undo + 1] = snapshot()
    rebuildFrom(table.remove(S.redo))
    S.undoKey = nil
end

-- ── object operations ──────────────────────────────────────────────────────────
local function limit()
    return tonumber(S.ctx.maxObjects) or tonumber(cfg().maxObjects) or 150
end

local function dupDistance(o)
    local a = assetOf(o.model)
    return (a and tonumber(a.dupOffset)) or tonumber(S.ctx.dupOffset) or tonumber(cfg().duplicateOffset) or 1.0
end

local function addObject(d)
    if #S.objects >= limit() then
        notice(('Layout is full (%d objects).'):format(limit()), 'warn')
        return nil
    end
    S.nextId = S.nextId + 1
    local o = {
        id = S.nextId, uid = d.uid or newUid(), model = d.model,
        x = d.x, y = d.y, z = d.z, rx = d.rx or 0.0, ry = d.ry or 0.0, rz = d.rz or 0.0,
        stack = d.stack or 1, step = d.step, collision = d.collision ~= false,
        spawned = d.spawned ~= false, extra = d.extra or {}, ents = {},
    }
    local info = modelInfo(o.model)
    o.vehicle = info.vehicle
    if stackable(o) and not o.step then o.step = measureStep(o) end
    buildEntities(o)
    S.objects[#S.objects + 1] = o
    S.byId[o.id] = o
    applyTransform(o)
    markFull()
    return o
end

local function removeObject(id)
    local o = S.byId[id]
    if not o then return end
    destroyEntities(o)
    S.byId[id] = nil
    S.selected[id] = nil
    if S.active == id then S.active = nil end
    for i, x in ipairs(S.objects) do
        if x.id == id then table.remove(S.objects, i) break end
    end
    markFull()
end

local function selectOnly(id)
    S.selected = {}
    if id then S.selected[id] = true end
    S.active = id
    markFull()
end

local function toggleSelect(id)
    if S.selected[id] then
        S.selected[id] = nil
        if S.active == id then S.active = next(S.selected) end
    else
        S.selected[id] = true
        S.active = id
    end
    markFull()
end

local function selectedObjects()
    local out = {}
    for _, o in ipairs(S.objects) do
        if S.selected[o.id] then out[#out + 1] = o end
    end
    return out
end

local function afterEdit(o)
    -- the entities carry the transform; a changed stack height / model is a rebuild
    applyTransform(o)
    markPatch(o)
end

-- a copy is a NEW, independent object: own id, own uid, own entities; moved a little so it does not overlap
local function duplicateObject(src, dist)
    local rad = math.rad(src.rz)
    local d = dist or dupDistance(src)
    local extra = {}
    for k, v in pairs(src.extra or {}) do extra[k] = v end
    return addObject({
        model = src.model,
        x = src.x + math.cos(rad) * d, y = src.y + math.sin(rad) * d, z = src.z,
        rx = src.rx, ry = src.ry, rz = src.rz,
        stack = src.stack, step = src.step, collision = src.collision,
        spawned = src.spawned, extra = extra, locked = false,
    })
end

local function groundZ(o)
    local info = modelInfo(o.model)
    local skip = {}
    for _, e in ipairs(o.ents) do skip[e] = true end
    RequestCollisionAtCoord(o.x, o.y, o.z)
    local from = vector3(o.x, o.y, o.z + 2.0)
    local pos = castRay(from, vector3(o.x, o.y, o.z - 150.0), skip)
    if not pos then pos = castRay(vector3(o.x, o.y, o.z + 60.0), vector3(o.x, o.y, o.z - 150.0), skip) end
    if not pos then return nil end
    return pos.z - info.mn.z
end

local function snapValue(v)
    if not S.grid then return v end
    local g = S.gridSize
    return math.floor(v / g + 0.5) * g
end

-- ── camera ─────────────────────────────────────────────────────────────────────
local function lookAt(cam, tx, ty, tz)
    local dx, dy, dz = tx - cam.x, ty - cam.y, tz - cam.z
    cam.yaw = wrap360(math.deg(math.atan(-dx, dy)))
    cam.pitch = clamp(math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), -89.0, 89.0)
end

local function startCamera(focus)
    local c = cfg().camera or {}
    local cam = { fov = tonumber(c.fov) or 60.0, pitch = -25.0, yaw = 0.0, x = 0.0, y = 0.0, z = 0.0 }
    local dist, height = tonumber(c.startDistance) or 14.0, tonumber(c.startHeight) or 9.0
    local tx, ty, tz
    if focus and tonumber(focus.x) and tonumber(focus.y) then
        tx, ty, tz = focus.x + 0.0, focus.y + 0.0, (tonumber(focus.z) or 0.0) + 0.0
    elseif #S.objects > 0 then
        tx, ty, tz = 0.0, 0.0, 0.0
        for _, o in ipairs(S.objects) do tx, ty, tz = tx + o.x, ty + o.y, tz + o.z end
        tx, ty, tz = tx / #S.objects, ty / #S.objects, tz / #S.objects
    else
        local p = GetEntityCoords(PlayerPedId())
        tx, ty, tz = p.x, p.y, p.z
    end
    -- stand south-east of the work area, looking at it
    cam.x, cam.y, cam.z = tx + dist * 0.55, ty - dist * 0.85, tz + height
    lookAt(cam, tx, ty, tz)
    S.focusPoint = vector3(tx, ty, tz)
    S.planeZ = tz
    cam.handle = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', cam.x, cam.y, cam.z, cam.pitch, 0.0, cam.yaw, cam.fov, true, 2)
    SetCamActive(cam.handle, true)
    RenderScriptCams(true, true, 500, true, true)
    return cam
end

local function updateCamera(dt)
    local cam = S.cam
    local c = cfg().camera or {}
    -- look
    if S.lookDx ~= 0.0 or S.lookDy ~= 0.0 then
        local sens = tonumber(c.lookSensitivity) or 0.22
        cam.yaw = wrap360(cam.yaw - S.lookDx * sens)
        cam.pitch = clamp(cam.pitch - S.lookDy * sens, -89.0, 89.0)
        S.lookDx, S.lookDy = 0.0, 0.0
    end
    -- fly
    local f, r, u = basis(cam.pitch, cam.yaw)
    local fly = S.fly
    local speed = (tonumber(c.speed) or 14.0) * (fly.fast and (tonumber(c.fastMultiplier) or 4.0) or 1.0)
    local mx = f.x * fly.f + r.x * fly.r
    local my = f.y * fly.f + r.y * fly.r
    local mz = f.z * fly.f + fly.u
    cam.x, cam.y, cam.z = cam.x + mx * speed * dt, cam.y + my * speed * dt, cam.z + mz * speed * dt
    -- wheel dolly
    if S.dolly ~= 0.0 then
        local step = 2.5 * S.dolly
        cam.x, cam.y, cam.z = cam.x + f.x * step, cam.y + f.y * step, cam.z + f.z * step
        S.dolly = 0.0
    end
    SetCamCoord(cam.handle, cam.x, cam.y, cam.z)
    SetCamRot(cam.handle, cam.pitch, 0.0, cam.yaw, 2)
    SetFocusPosAndVel(cam.x, cam.y, cam.z, 0.0, 0.0, 0.0)
end

-- ── pointer → world ────────────────────────────────────────────────────────────
local function skipSet()
    local skip = {}
    if S.ghost then for _, e in ipairs(S.ghost.ents) do skip[e] = true end end
    if S.drag then
        local o = S.byId[S.drag.id]
        if o then for _, e in ipairs(o.ents) do skip[e] = true end end
    end
    return skip
end

-- Where the pointer touches the world: { pos, ent, objId } (pos may come from the ground plane when nothing is hit)
local function pointerHit()
    local p = S.pointer
    if not p.inside then return nil end
    local from, dir = screenRay(p.nx, p.ny)
    local pos, _, ent = castRay(from, from + dir * 700.0, skipSet())
    local objId = ent and S.entToObj[ent] or nil
    if pos then
        S.planeZ = pos.z
        return { pos = pos, ent = ent, objId = objId }
    end
    -- nothing there (sky / unloaded ground): the horizontal plane at the last known height, if looking down
    if dir.z < -0.02 then
        local t = (S.planeZ - from.z) / dir.z
        if t > 0.0 and t < 500.0 then return { pos = from + dir * t, ent = nil, objId = nil, plane = true } end
    end
    return nil
end

-- Where the pointer's ray crosses the horizontal plane at height z (used to drag: it does not depend on what the ray
-- happens to hit, so an object never jumps when it stops being in the way of its own ray).
local function planeHit(nx, ny, z)
    local from, dir = screenRay(nx, ny)
    if math.abs(dir.z) < 0.02 then return nil end
    local t = (z - from.z) / dir.z
    if t <= 0.0 or t > 900.0 then return nil end
    return from + dir * t
end

-- Projected-centre fallback for objects the ray cannot hit (no collision model)
-- The object under the pointer, judged on the SCREEN: the rectangle its box covers (plus a margin, so a small or thin prop such as a floor light
-- is still easy to hit) must contain the pointer; among several the one whose centre is closest wins. The ray that runs first can miss a
-- prop's tiny collision, so this is what makes a click (and the white hover outline, which uses the same test) reliable.
local function screenRectOf(o)
    local e = o.ents and o.ents[1]
    if not (e and DoesEntityExist(e)) then return nil end
    local info = modelInfo(o.model)
    local mn, mx = info.mn, info.mx
    local top = mx.z + ((o.stack or 1) - 1) * (o.step or 0)
    local x1, y1, x2, y2, any = 9.0, 9.0, -9.0, -9.0, false
    for i = 0, 7 do
        local c = GetOffsetFromEntityInWorldCoords(e, (i & 1) == 0 and mn.x or mx.x, (i & 2) == 0 and mn.y or mx.y, (i & 4) == 0 and mn.z or top)
        local on, sx, sy = World3dToScreen2d(c.x, c.y, c.z)
        if on then
            local nx, ny = sx * 2.0 - 1.0, -(sy * 2.0 - 1.0)
            if nx < x1 then x1 = nx end
            if nx > x2 then x2 = nx end
            if ny < y1 then y1 = ny end
            if ny > y2 then y2 = ny end
            any = true
        end
    end
    if not any then return nil end
    return x1, y1, x2, y2
end

local PICK_MARGIN = 0.035   -- normalised screen units (about 33 px on a 1920 px wide screen)
local function nearestOnScreen(nx, ny)
    local best, bestD = nil, 1e9
    for _, o in ipairs(S.objects) do
        local x1, y1, x2, y2 = screenRectOf(o)
        if x1 and nx >= x1 - PICK_MARGIN and nx <= x2 + PICK_MARGIN and ny >= y1 - PICK_MARGIN and ny <= y2 + PICK_MARGIN then
            local d = math.sqrt((nx - (x1 + x2) * 0.5) ^ 2 + (ny - (y1 + y2) * 0.5) ^ 2)
            if d < bestD then best, bestD = o.id, d end
        end
    end
    return best
end

-- ── the armed asset (the hologram that follows the cursor) ─────────────────────
local function clearGhost()
    if S.ghost then deleteEntities(S.ghost.ents) S.ghost = nil end
end

local function ensureGhost()
    local a = S.armed
    if not a then clearGhost() return end
    local info = modelInfo(a.model)
    if not info.valid then clearGhost() return end
    local want = (a.stackable and S.features.stack) and clamp(a.stack, 1, S.features.maxStack) or 1
    if S.ghost and S.ghost.model == a.model and S.ghost.count == want then return end
    clearGhost()
    local ents = {}
    for _ = 1, want do
        local e = makeEntity(info.vehicle, info.hash, 0.0, 0.0, -100.0, 0.0, 0.0, 0.0, 120)
        if e then
            SetEntityCollision(e, false, false)
            ents[#ents + 1] = e
        end
    end
    S.ghost = { model = a.model, count = want, ents = ents, info = info, step = a.step }
end

local function arm(model, stackN)
    local info = modelInfo(model)
    if not info.valid then notice(('Model "%s" is not in this game build.'):format(model), 'error') return end
    local a = assetOf(model)
    local can = a and a.stackable == true and S.features.stack and not info.vehicle
    local pieceStep = (a and tonumber(a.step)) or nil
    if can and not pieceStep then
        local h = info.mx.z - info.mn.z
        pieceStep = (h > 0.5) and round(h, 3) or (tonumber(((Config.ContainerWars or {}).harbour or {}).dummyStep) or 2.6)
    end
    S.armed = {
        model = model, vehicle = info.vehicle, stackable = can == true,
        stack = clamp(tonumber(stackN) or (S.armed and S.armed.stackable and S.armed.stack) or 1, 1, S.features.maxStack),
        rz = (S.armed and S.armed.rz) or wrap360(S.cam.yaw), step = pieceStep,
    }
    if not can then S.armed.stack = 1 end
    ensureGhost()
    markFull()
end

local function disarm()
    if not S.armed then return end
    S.armed = nil
    clearGhost()
    markFull()
end

local function placeArmed(hit)
    local a = S.armed
    if not a or not hit then return end
    local info = modelInfo(a.model)
    local x, y = snapValue(hit.pos.x), snapValue(hit.pos.y)
    local rz = S.grid and (math.floor(a.rz / (cfg().rotateStep or 5.0) + 0.5) * (cfg().rotateStep or 5.0)) or a.rz
    pushUndo()
    local o = addObject({
        model = a.model, x = x, y = y, z = hit.pos.z - info.mn.z, rz = wrap360(rz),
        stack = a.stackable and a.stack or 1, step = a.step, spawned = S.spawnOnPlace,
    })
    if o then
        selectOnly(o.id)
        PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
        if not S.keepTool then disarm() end
    else
        table.remove(S.undo)   -- nothing was added
    end
end

-- ── drawing ────────────────────────────────────────────────────────────────────
-- width: how bold the outline is (NovaDraw.line); a very large selection is drawn with plain one pixel lines so the
-- frame rate does not suffer
local thinLines = false
local function box(o, r, g, b, a, width)
    if #o.ents == 0 or not DoesEntityExist(o.ents[1]) then return end
    local info = modelInfo(o.model)
    local mn, mx = info.mn, info.mx
    local top = mx.z + ((o.stack or 1) - 1) * (o.step or 0)
    local e = o.ents[1]
    local c = {}
    for i = 0, 7 do
        local lx = (i & 1) == 0 and mn.x or mx.x
        local ly = (i & 2) == 0 and mn.y or mx.y
        local lz = (i & 4) == 0 and mn.z or top
        c[i] = GetOffsetFromEntityInWorldCoords(e, lx, ly, lz)
    end
    NovaDraw.box(c, r, g, b, a, thinLines and 0.0 or (width or 1.0))
end

-- a name in the world: text on a dark plate with a coloured edge (see NovaDraw.label)
local function drawLabel(x, y, z, text, r, g, b)
    NovaDraw.label(x, y, z, text, r or 123, g or 182, b or 242)
end

-- ── guides: things that already exist elsewhere in the event ───────────────────────
-- In the harbour yard the auction containers wait at their spots, are carried to their drop spots by a crane whose
-- legs sweep two lanes. None of that is a prop in this list, so it is drawn as outlines — place dummies around it,
-- not on it. A dummy that overlaps one turns red.
--   guide = { kind = 'pickup' | 'drop' | 'crane' | 'lane', label, x, y, z, h, L, W, H [, x2, y2] }
local GUIDE_COLORS = {
    pickup = { 54, 143, 233 },
    drop = { 70, 214, 154 },
    crane = { 240, 180, 60 },
    lane = { 240, 180, 60 },
    checkpoint = { 54, 143, 233 },
    checkpoint_prop = { 240, 180, 60 },
    checkpoint_vehicle = { 155, 123, 255 },
    -- a race or convoy route: its start, checkpoints and finish, and the line that joins them
    race_start = { 70, 214, 154 },
    race_checkpoint = { 54, 143, 233 },
    race_finish = { 255, 214, 74 },
    route = { 205, 220, 240 },
}
local GUIDE_NAMES = {
    pickup = 'container spot',
    drop = 'drop spot',
    crane = 'crane leg',
    checkpoint = 'checkpoint zone',
    checkpoint_prop = 'checkpoint barricade',
    checkpoint_vehicle = 'checkpoint vehicle',
}

local function harbourGuides()
    local cw = Config.ContainerWars or {}
    local H = cw.harbour or {}
    local size = (cw.defaults or {}).containerSize or { length = 12.2, width = 2.6, height = 2.7 }
    local out = {}
    for i, p in ipairs(H.pickups or {}) do
        if tonumber(p.x) and tonumber(p.y) then
            out[#out + 1] = { kind = 'pickup', label = ('Container #%d'):format(i), x = p.x + 0.0, y = p.y + 0.0, z = (tonumber(p.z) or 0.0) + 0.0, h = tonumber(p.heading) or 0.0, L = size.length, W = size.width, H = size.height }
        end
    end
    local drops = (H.drops and #H.drops > 0) and H.drops or { H.drop }
    for i, d in ipairs(drops) do
        if d and tonumber(d.x) and tonumber(d.y) then
            out[#out + 1] = { kind = 'drop', label = ('Drop #%d'):format(i), x = d.x + 0.0, y = d.y + 0.0, z = (tonumber(d.z) or 0.0) + 0.0, h = tonumber(d.heading) or 0.0, L = size.length, W = size.width, H = size.height }
        end
    end

    -- every crane's legs where it stands, and at both ends of the stretch it has to roll to reach the spots it serves
    local cranes = CWGantry.resolveCranes(H, #(H.pickups or {}))
    local assign = CWGantry.assignCranes(H, cranes, math.max(#(H.pickups or {}), #(H.drops or {})))
    local spots = out
    out = {}
    for _, e in ipairs(spots) do out[#out + 1] = e end
    for ci, crane in ipairs(cranes) do
      local g = CWGantry.get(crane.model)
      if g and tonumber(crane.x) then
        local h = math.rad(crane.heading or 0.0)
        local rx, ry = math.cos(h), math.sin(h)
        local cabX = (g.cabin and g.cabin.x) or 0.0
        local sMin, sMax = 0.0, 0.0
        -- only the spots this crane carries decide how far it has to roll
        for i, a in ipairs(assign) do
            if a.crane == ci then
                for _, e in ipairs(spots) do
                    local mine = (e.kind == 'pickup' and e.label == ('Container #%d'):format(i)) or (e.kind == 'drop' and e.label == ('Drop #%d'):format(i))
                    if mine then
                        local s = (e.x - crane.x) * rx + (e.y - crane.y) * ry - cabX
                        sMin, sMax = math.min(sMin, s), math.max(sMax, s)
                    end
                end
            end
        end
        local rail = g.rail or {}
        sMin, sMax = math.max(sMin, rail.min or -60.0), math.min(sMax, rail.max or 60.0)
        local at0 = CWGantry.legBoxes(g, crane, 0.0)
        for _, s in ipairs({ 0.0, sMin, sMax }) do
            if s == 0.0 or math.abs(s) > 1.0 then
                local boxes = (s == 0.0) and at0 or CWGantry.legBoxes(g, crane, s)
                for li, b in ipairs(boxes) do
                    -- only the legs where the crane stands carry its name (the ones at the ends of its travel are just outlines)
                    out[#out + 1] = {
                        kind = 'crane', label = 'Crane leg', x = b.x, y = b.y, z = crane.z, h = b.h, L = b.L, W = b.W, H = 2.5,
                        name = (s == 0.0 and li == 1) and ('Crane #%d'):format(ci) or nil,
                    }
                end
            end
        end
        local lo, hi = CWGantry.legBoxes(g, crane, sMin), CWGantry.legBoxes(g, crane, sMax)
        for i = 1, math.min(#lo, #hi) do
            out[#out + 1] = { kind = 'lane', x = lo[i].x, y = lo[i].y, x2 = hi[i].x, y2 = hi[i].y, z = crane.z }
        end
      end
    end
    return out
end

local function guideCorners(g)
    local r = math.rad(tonumber(g.h or g.heading) or 0.0)
    local fx, fy, rx, ry = -math.sin(r), math.cos(r), math.cos(r), math.sin(r)
    local L = tonumber(g.L) or (tonumber(g.radius) and (tonumber(g.radius) * 2.0)) or 2.0
    local W = tonumber(g.W) or (tonumber(g.radius) and (tonumber(g.radius) * 2.0)) or 2.0
    local hl, hw = L / 2.0, W / 2.0
    local pts = {}
    for _, s in ipairs({ { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 } }) do
        pts[#pts + 1] = { g.x + fx * hl * s[1] + rx * hw * s[2], g.y + fy * hl * s[1] + ry * hw * s[2] }
    end
    return pts
end

local function isRouteGuide(g)
    return g.kind == 'route' or (type(g.kind) == 'string' and g.kind:sub(1, 5) == 'race_')
end

-- a ring on the ground (a race checkpoint's trigger circle) with a pole up its middle
local function drawRing(x, y, z, radius, r, g, b)
    local steps, prevX, prevY = 28, nil, nil
    for i = 0, steps do
        local a = (i / steps) * math.pi * 2.0
        local px, py = x + math.cos(a) * radius, y + math.sin(a) * radius
        if prevX then NovaDraw.line(prevX, prevY, z + 0.2, px, py, z + 0.2, r, g, b, 230, 1.4) end
        prevX, prevY = px, py
    end
    NovaDraw.line(x, y, z, x, y, z + 7.0, r, g, b, 230, 1.2)
end

local function drawGuides()
    for _, g in ipairs(S.guides or {}) do
        local c = GUIDE_COLORS[g.kind] or { 255, 255, 255 }
        if g.kind == 'route' then
            -- the line from one point of the route to the next, with an arrowhead half-way showing the direction of travel
            local z1, z2 = (g.z or 0.0) + 0.25, (g.z2 or g.z or 0.0) + 0.25
            NovaDraw.line(g.x, g.y, z1, g.x2, g.y2, z2, c[1], c[2], c[3], 220, 1.8)
            local dx, dy = g.x2 - g.x, g.y2 - g.y
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 12.0 then
                dx, dy = dx / len, dy / len
                local mx, my, mz = (g.x + g.x2) / 2.0, (g.y + g.y2) / 2.0, (z1 + z2) / 2.0
                local tipX, tipY = mx + dx * 2.0, my + dy * 2.0
                local bx, by = mx - dx * 2.5, my - dy * 2.5
                NovaDraw.line(tipX, tipY, mz, bx - dy * 2.2, by + dx * 2.2, mz, c[1], c[2], c[3], 230, 1.8)
                NovaDraw.line(tipX, tipY, mz, bx + dy * 2.2, by - dx * 2.2, mz, c[1], c[2], c[3], 230, 1.8)
            end
        elseif isRouteGuide(g) then
            -- race start / checkpoint / finish: the trigger circle, a pole, and what it is
            drawRing(g.x, g.y, g.z, tonumber(g.radius) or 15.0, c[1], c[2], c[3])
            local lbl = g.label or ''
            if lbl ~= '' then drawLabel(g.x, g.y, g.z + 7.6, lbl:upper(), c[1], c[2], c[3]) end
        elseif g.kind == 'lane' then
            NovaDraw.line(g.x, g.y, g.z + 0.15, g.x2, g.y2, g.z + 0.15, c[1], c[2], c[3], 190, 0.8)
        else
            local gH = tonumber(g.H) or 2.0
            local z0, z1 = g.z, g.z + gH
            -- a soft fill on the ground, a bold outline round it and up its corners, then its name on a plate
            NovaDraw.rect(guideCorners(g), z0, gH, c[1], c[2], c[3], g.kind == 'crane' and 40 or 55, 255, 1.2)
            local lbl = g.label or g.name or ''
            if g.kind == 'pickup' then
                drawLabel(g.x, g.y, z1 + 0.7, (lbl ~= '' and lbl or 'PICKUP'):upper() .. '  ·  WAITS HERE', c[1], c[2], c[3])
            elseif g.kind == 'drop' then
                drawLabel(g.x, g.y, z1 + 0.7, (lbl ~= '' and lbl or 'DROP'):upper() .. '  ·  SET DOWN HERE', c[1], c[2], c[3])
            elseif g.kind == 'checkpoint' then
                drawLabel(g.x, g.y, z1 + 0.7, (lbl ~= '' and lbl or 'CHECKPOINT'):upper() .. '  ·  ZONE', c[1], c[2], c[3])
            elseif g.kind == 'checkpoint_prop' then
                drawLabel(g.x, g.y, z1 + 0.7, (lbl ~= '' and lbl or g.model or 'PROP'):upper() .. '  ·  CHECKPOINT BARRICADE', c[1], c[2], c[3])
            elseif g.kind == 'checkpoint_vehicle' then
                drawLabel(g.x, g.y, z1 + 0.7, (lbl ~= '' and lbl or g.model or 'VEHICLE'):upper() .. '  ·  CHECKPOINT VEHICLE', c[1], c[2], c[3])
            elseif lbl ~= '' then
                drawLabel(g.x, g.y, z1 + 0.7, lbl:upper(), c[1], c[2], c[3])
            end
        end
    end
end

-- the guide this object is standing on, if any ({ kind, label } or nil)
local function guideOverlap(o)
    if not S.guides or #S.guides == 0 then return nil end
    local info = modelInfo(o.model)
    if not (info and info.valid and info.mn and info.mx) then return nil end
    local me = { x = o.x, y = o.y, h = o.rz or 0.0, L = (info.mx.y - info.mn.y), W = (info.mx.x - info.mn.x) }
    local bottom = o.z + info.mn.z
    local top = o.z + info.mx.z + ((o.stack or 1) - 1) * (o.step or 0.0)
    for _, g in ipairs(S.guides) do
        -- a race route is only something to see and build around: a ramp or barrier may stand right on it
        if g.kind ~= 'lane' and not isRouteGuide(g) then
            -- a container waiting ON a stack is meant to be there: only a real overlap in height counts
            local gH = tonumber(g.H) or 2.0
            local gh = tonumber(g.h or g.heading) or 0.0
            local gL = tonumber(g.L) or (tonumber(g.radius) and (tonumber(g.radius) * 2.0)) or 2.0
            local gW = tonumber(g.W) or (tonumber(g.radius) and (tonumber(g.radius) * 2.0)) or 2.0
            local vertical = (g.kind == 'crane') or (top > g.z + 0.6 and bottom < g.z + gH - 0.6)
            if vertical and CWGantry.boxesOverlap(me, { x = g.x, y = g.y, h = gh, L = gL, W = gW }) then return g end
        end
    end
    return nil
end

local function drawScene(hoverId)
    drawGuides()
    local selectedCount = 0
    for _ in pairs(S.selected) do selectedCount = selectedCount + 1 end
    thinLines = selectedCount > 12
    for _, o in ipairs(S.objects) do
        local sel = S.selected[o.id]
        local onGuide = guideOverlap(o)
        if onGuide then
            box(o, 255, 93, 80, 255, 1.4)
            drawLabel(o.x, o.y, o.z + (modelInfo(o.model).mx.z or 1.0) + 1.2, ('ON THE %s  ·  %s'):format((GUIDE_NAMES[onGuide.kind] or 'reserved area'):upper(), tostring(onGuide.label):upper()), 255, 93, 80)
        end
        if o.missing then
            DrawMarker(28, o.x, o.y, o.z, 0, 0, 0, 0, 0, 0, 0.6, 0.6, 0.6, 255, 93, 80, 200, false, false, 2, false, nil, nil, false)
            drawLabel(o.x, o.y, o.z + 0.9, o.model .. '  ·  MISSING', 255, 93, 80)
        end
        if sel then
            for _, e in ipairs(o.ents) do
                if DoesEntityExist(e) then NovaDraw.outline(e, true) end
            end
            if o.id == S.active then box(o, 54, 143, 233, 255, 1.3) else box(o, 123, 182, 242, 230, 0.9) end
        else
            for _, e in ipairs(o.ents) do
                if DoesEntityExist(e) then NovaDraw.outline(e, false) end
            end
            if hoverId == o.id then
                box(o, 255, 255, 255, 255, 1.6)
                local info = modelInfo(o.model)
                local size = math.max(info.mx.x - info.mn.x, info.mx.y - info.mn.y, 0.3)
                DrawMarker(25, o.x, o.y, o.z + 0.03, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, size + 0.5, size + 0.5, 0.5, 255, 255, 255, 200, false, false, 2, false, nil, nil, false)
                drawLabel(o.x, o.y, o.z + math.max(info.mx.z, 0.4) + 0.5, 'CLICK TO SELECT', 255, 255, 255)
            end
        end
    end
    NovaDraw.outlineColor(54, 143, 233, 255)
    local a = S.active and S.byId[S.active]
    if a then
        local top = (a.stack or 1) > 1 and (a.z + (a.stack - 1) * (a.step or 0)) or a.z
        local name = (assetOf(a.model) and assetOf(a.model).label) or a.model
        if (a.stack or 1) > 1 then name = ('%s  ×%d'):format(name, a.stack) end
        drawLabel(a.x, a.y, top + (modelInfo(a.model).mx.z or 1.0) + 0.6, name, 54, 143, 233)
    end
end

-- ── interaction ────────────────────────────────────────────────────────────────
-- Turns a group of objects as one rigid piece: every position swings round (cx, cy) and every object turns by the
-- same angle, so a row of containers stays a row. `theta` is in degrees, the same direction as heading.
local function rotateGroup(members, cx, cy, theta)
    local r = math.rad(theta)
    local c, s = math.cos(r), math.sin(r)
    for _, m in ipairs(members) do
        local dx, dy = m.x - cx, m.y - cy
        m.o.x, m.o.y = cx + dx * c - dy * s, cy + dx * s + dy * c
        m.o.rz = wrap360(m.rz + theta)
    end
end

local function nudge(dir, big, fine)
    -- everything selected moves together; with nothing selected it is the active object
    local objs = selectedObjects()
    if #objs == 0 then
        local a = S.active and S.byId[S.active]
        if a then objs[1] = a end
    end
    if #objs == 0 then return end
    local free = {}
    for _, o in ipairs(objs) do if not o.locked then free[#free + 1] = o end end
    if #free == 0 then notice('That object is locked (press F to unlock it).', 'warn') return end
    objs = free
    local step = (tonumber(cfg().moveStep) or 0.25) * (fine and 0.1 or 1.0) * (big and 10.0 or 1.0)
    local rstep = (tonumber(cfg().rotateStep) or 5.0) * (fine and 0.2 or 1.0) * (big and 3.0 or 1.0)
    local yaw = math.rad(S.cam.yaw)
    local fx, fy = -math.sin(yaw), math.cos(yaw)
    local rx, ry = math.cos(yaw), math.sin(yaw)
    pushUndo('nudge')
    if dir == 'yawL' or dir == 'yawR' then
        local cx, cy = 0.0, 0.0
        for _, o in ipairs(objs) do cx, cy = cx + o.x, cy + o.y end
        cx, cy = cx / #objs, cy / #objs
        local members = {}
        for _, o in ipairs(objs) do members[#members + 1] = { o = o, x = o.x, y = o.y, rz = o.rz } end
        rotateGroup(members, cx, cy, dir == 'yawL' and rstep or -rstep)
        for _, o in ipairs(objs) do afterEdit(o) end
        return
    end
    for _, o in ipairs(objs) do
        if dir == 'left' then o.x, o.y = o.x - rx * step, o.y - ry * step
        elseif dir == 'right' then o.x, o.y = o.x + rx * step, o.y + ry * step
        elseif dir == 'forward' then o.x, o.y = o.x + fx * step, o.y + fy * step
        elseif dir == 'back' then o.x, o.y = o.x - fx * step, o.y - fy * step
        elseif dir == 'up' then o.z = o.z + step
        elseif dir == 'down' then o.z = o.z - step end
        afterEdit(o)
    end
end

local function onDown(p)
    if p.btn ~= 0 then return end
    local hit = pointerHit()
    local over = hit and hit.objId or nil

    if S.armed then
        -- A click on something that is already placed SELECTS it (the armed asset is put away); to put the new one
        -- on top of it, hold Ctrl. Without this every click on an object placed one more copy.
        if over and not p.ctrl then
            disarm()
            selectOnly(over)
            return
        end
        placeArmed(hit)
        return
    end

    local id = over
    if not id then id = nearestOnScreen(p.nx, p.ny) end
    if id then
        if p.shift then
            toggleSelect(id)
        elseif not S.selected[id] then
            selectOnly(id)
        else
            S.active = id
            markFull()
        end
        local o = S.byId[id]
        if S.tool ~= 'select' and S.selected[id] and o and not o.locked then
            -- Dragging works on a horizontal plane through the point that was grabbed, with the offset kept, so
            -- a plain click never moves anything and the grabbed point stays under the cursor.
            local planeZ = (hit and hit.objId == id and hit.pos.z) or o.z
            local ph = planeHit(p.nx, p.ny, planeZ)
            if S.tool == 'rotate' or ph then
                -- the whole selection travels with the grabbed object, keeping its shape (a row stays a row)
                local group, cx, cy = {}, 0.0, 0.0
                for _, m in ipairs(selectedObjects()) do
                    if not m.locked then
                        group[#group + 1] = { o = m, x = m.x, y = m.y, z = m.z, rz = m.rz }
                        cx, cy = cx + m.x, cy + m.y
                    end
                end
                if #group == 0 then group[1] = { o = o, x = o.x, y = o.y, z = o.z, rz = o.rz }; cx, cy = o.x, o.y end
                S.drag = {
                    id = id, mode = S.tool, snap = snapshot(), moved = false, started = false,
                    planeZ = planeZ, ox = ph and (o.x - ph.x) or 0.0, oy = ph and (o.y - ph.y) or 0.0,
                    startRz = o.rz, startX = o.x, startY = o.y, startPx = p.px or 0.0, startPy = p.py or 0.0,
                    group = group, gcx = cx / #group, gcy = cy / #group,
                }
            end
        end
    elseif not p.shift then
        S.selected, S.active = {}, nil
        markFull()
    end
end

local function onMove(p)
    local d = S.drag
    if not d then return end
    local o = S.byId[d.id]
    if not o then S.drag = nil return end
    -- nothing happens until the mouse has really moved (a few pixels): a click is a click, not a tiny drag
    if not d.started then
        local ddx, ddy = (p.px or 0.0) - d.startPx, (p.py or 0.0) - d.startPy
        if ddx * ddx + ddy * ddy < 36.0 then return end
        d.started = true
    end
    if d.mode == 'move' then
        local ph = planeHit(p.nx, p.ny, d.planeZ)
        if not ph then return end
        -- the grabbed object follows the cursor (snapped to the grid); the rest keep their distance from it
        local nx, ny = snapValue(ph.x + d.ox), snapValue(ph.y + d.oy)
        local mx, my = nx - d.startX, ny - d.startY
        for _, m in ipairs(d.group) do
            local mo = m.o
            mo.x, mo.y = m.x + mx, m.y + my
            if S.snapGround then
                local skip = {}
                for _, e in ipairs(mo.ents) do skip[e] = true end
                local info = modelInfo(mo.model)
                local base = math.max(mo.z, d.planeZ)
                local pos = castRay(vector3(mo.x, mo.y, base + 4.0), vector3(mo.x, mo.y, mo.z - 150.0), skip)
                    or castRay(vector3(mo.x, mo.y, base + 40.0), vector3(mo.x, mo.y, mo.z - 150.0), skip)
                if pos then mo.z = pos.z - info.mn.z end
            end
            if mo ~= o then afterEdit(mo) end
        end
        d.moved = true
    elseif d.mode == 'rotate' then
        local turn = ((p.px or 0.0) - d.startPx) * (p.shift and 0.1 or 0.45)
        local rz = d.startRz - turn
        if S.grid then
            local st = tonumber(cfg().rotateStep) or 5.0
            rz = math.floor(rz / st + 0.5) * st
        end
        -- the whole selection turns round its middle by the same angle
        rotateGroup(d.group, d.gcx, d.gcy, wrap360(rz) - wrap360(d.startRz))
        for _, m in ipairs(d.group) do if m.o ~= o then afterEdit(m.o) end end
        d.moved = true
    end
    afterEdit(o)
end

local function onUp(p)
    local d = S.drag
    if not d then return end
    S.drag = nil
    if d.moved then
        S.undo[#S.undo + 1] = d.snap
        if #S.undo > 60 then table.remove(S.undo, 1) end
        S.redo = {}
        S.dirty = true
        markFull()
    end
end

-- ── commands from the NUI ──────────────────────────────────────────────────────
local COMMANDS = {}

function COMMANDS.select(d)
    local mode = d.mode or 'set'
    if mode == 'set' then
        S.selected, S.active = {}, nil
    end
    for _, id in ipairs(d.ids or {}) do
        if S.byId[id] then
            if mode == 'toggle' then toggleSelect(id)
            else S.selected[id] = true; S.active = id end
        end
    end
    markFull()
end

function COMMANDS.selectAll()
    S.selected = {}
    for _, o in ipairs(S.objects) do S.selected[o.id] = true end
    if not S.active and S.objects[1] then S.active = S.objects[1].id end
    markFull()
end

function COMMANDS.clearSelection()
    S.selected, S.active = {}, nil
    markFull()
end

function COMMANDS.arm(d) arm(tostring(d.model or ''), d.stack) end
function COMMANDS.disarm() disarm() end

function COMMANDS.armStack(d)
    if S.armed and S.armed.stackable then
        S.armed.stack = clamp(math.floor(tonumber(d.n) or 1), 1, S.features.maxStack)
        ensureGhost()
        markFull()
    end
end

function COMMANDS.armRotate(d)
    if S.armed then
        S.armed.rz = wrap360(S.armed.rz + (tonumber(d.delta) or 0.0))
        markFull()
    end
end

function COMMANDS.setTool(d)
    if d.tool == 'select' or d.tool == 'move' or d.tool == 'rotate' then
        S.tool = d.tool
        markFull()
    end
end

function COMMANDS.setFlag(d)
    local k = d.key
    if k == 'snapGround' or k == 'grid' or k == 'keepTool' or k == 'spawnOnPlace' then
        S[k] = d.value == true
    elseif k == 'gridSize' then
        S.gridSize = clamp(tonumber(d.value) or 0.5, 0.05, 10.0)
    end
    markFull()
end

-- patch: any of x y z rx ry rz stack collision
function COMMANDS.update(d)
    local o = S.byId[d.id]
    if not o or type(d.patch) ~= 'table' then return end
    local p = d.patch
    if o.locked then
        for _, k in ipairs({ 'x', 'y', 'z', 'rx', 'ry', 'rz' }) do
            if p[k] ~= nil then notice('That object is locked (press F to unlock it).', 'warn') return end
        end
    end
    -- typing numbers in a burst is one undo step; a stack button or the solid switch is its own
    pushUndo((p.stack == nil and p.collision == nil) and ('update:' .. o.id) or nil)
    for _, k in ipairs({ 'x', 'y', 'z', 'rx', 'ry', 'rz' }) do
        if tonumber(p[k]) then o[k] = tonumber(p[k]) + 0.0 end
    end
    o.rz = wrap360(o.rz)
    if p.collision ~= nil then o.collision = p.collision == true end
    if tonumber(p.stack) and stackable(o) then
        local n = clamp(math.floor(tonumber(p.stack)), 1, S.features.maxStack)
        if n ~= o.stack then
            o.stack = n
            if not o.step then o.step = measureStep(o) end
            buildEntities(o)
        end
    end
    afterEdit(o)
    markFull()
end

-- the same change for every selected object (batch); only used by the explicit batch buttons
function COMMANDS.batch(d)
    local list = selectedObjects()
    if #list == 0 then return end
    pushUndo()
    -- a turn is applied to the selection as one piece (round its middle), not to each object on the spot
    if tonumber(d.drz) then
        local members, cx, cy = {}, 0.0, 0.0
        for _, o in ipairs(list) do
            if not o.locked then
                members[#members + 1] = { o = o, x = o.x, y = o.y, rz = o.rz }
                cx, cy = cx + o.x, cy + o.y
            end
        end
        if #members > 0 then rotateGroup(members, cx / #members, cy / #members, tonumber(d.drz)) end
    end
    for _, o in ipairs(list) do
        if not o.locked then
            if tonumber(d.dx) then o.x = o.x + tonumber(d.dx) end
            if tonumber(d.dy) then o.y = o.y + tonumber(d.dy) end
            if tonumber(d.dz) then o.z = o.z + tonumber(d.dz) end
        end
        if d.collision ~= nil then o.collision = d.collision == true end
        if tonumber(d.stack) and stackable(o) then
            local n = clamp(math.floor(tonumber(d.stack)), 1, S.features.maxStack)
            if n ~= o.stack then
                o.stack = n
                if not o.step then o.step = measureStep(o) end
                buildEntities(o)
            end
        end
        afterEdit(o)
    end
    markFull()
end

function COMMANDS.nudge(d) nudge(d.dir, d.big == true, d.fine == true) end

function COMMANDS.duplicate(d)
    local list = selectedObjects()
    if #list == 0 and S.active and S.byId[S.active] then list = { S.byId[S.active] } end
    if #list == 0 then notice('Select an object to duplicate.', 'warn') return end
    local count = clamp(math.floor(tonumber(d.count) or 1), 1, 50)
    pushUndo()
    local made = {}
    for _, src in ipairs(list) do
        local cur = src
        for _ = 1, count do
            local o = duplicateObject(cur)
            if not o then break end
            made[#made + 1] = o
            cur = o     -- Duplicate x N builds a row: each copy is one step further along
        end
    end
    if #made == 0 then table.remove(S.undo) return end
    S.selected = {}
    for _, o in ipairs(made) do S.selected[o.id] = true end
    S.active = made[#made].id
    markFull()
end

function COMMANDS.delete(d)
    local ids = d.ids
    if not ids then ids = selectedList() end
    if #ids == 0 then return end
    pushUndo()
    for _, id in ipairs(ids) do removeObject(id) end
    markFull()
end

function COMMANDS.ground()
    local list = selectedObjects()
    if #list == 0 then return end
    pushUndo()
    local missed = 0
    for _, o in ipairs(list) do
        if not o.locked then
            local z = groundZ(o)
            if z then o.z = z; afterEdit(o) else missed = missed + 1 end
        end
    end
    if missed > 0 then notice('Could not find the ground under ' .. missed .. ' object(s) (is it loaded there?).', 'warn') end
    markFull()
end

function COMMANDS.spawn(d)
    local list = (d.scope == 'all') and S.objects or selectedObjects()
    if #list == 0 then return end
    pushUndo()
    for _, o in ipairs(list) do
        o.spawned = true
        if #o.ents == 0 or o.missing then buildEntities(o); applyTransform(o) end
        setAlpha(o)
    end
    notice(('%d object(s) spawned.'):format(#list), 'ok')
    markFull()
end

function COMMANDS.clear()
    if #S.objects == 0 then return end
    pushUndo()
    local ids = {}
    for _, o in ipairs(S.objects) do ids[#ids + 1] = o.id end
    for _, id in ipairs(ids) do removeObject(id) end
    markFull()
end

-- F: freeze / unfreeze the selected objects. A locked object cannot be moved, turned, dropped or nudged by
-- anything (drag, arrows, numbers, batch) until it is unlocked; unlocking never moves it.
function COMMANDS.lock()
    local list = selectedObjects()
    if #list == 0 then notice('Select an object first.', 'warn') return end
    local allLocked = true
    for _, o in ipairs(list) do if not o.locked then allLocked = false end end
    for _, o in ipairs(list) do o.locked = not allLocked end
    notice(allLocked and ('%d object(s) unlocked.'):format(#list) or ('%d object(s) locked in place.'):format(#list), 'ok')
    markFull()
end

function COMMANDS.undo() undo() end
function COMMANDS.redo() redo() end

function COMMANDS.focus(d)
    local o = d.id and S.byId[d.id]
    local tx, ty, tz
    if o then
        tx, ty, tz = o.x, o.y, o.z
        S.selected, S.active = { [o.id] = true }, o.id
        markFull()
    elseif tonumber(d.x) and tonumber(d.y) then
        tx, ty, tz = tonumber(d.x), tonumber(d.y), (tonumber(d.z) or 0.0)
    else
        return
    end

    local c = cfg().camera or {}
    local dist = tonumber(c.startDistance) or 12.0
    local height = tonumber(c.startHeight) or 7.0
    S.cam.x = tx + dist * 0.55
    S.cam.y = ty - dist * 0.85
    S.cam.z = tz + height
    lookAt(S.cam, tx, ty, tz)
    S.focusPoint = vector3(tx, ty, tz)
    S.planeZ = tz
    if S.cam.handle and DoesCamExist(S.cam.handle) then
        SetCamCoord(S.cam.handle, S.cam.x, S.cam.y, S.cam.z)
        SetCamRot(S.cam.handle, S.cam.pitch, 0.0, S.cam.yaw, 2)
        SetFocusPosAndVel(S.cam.x, S.cam.y, S.cam.z, 0.0, 0.0, 0.0)
    end
end

-- Add a model by name (any model of this game build). Arms it like an asset card.
function COMMANDS.custom(d)
    local name = tostring(d.model or ''):gsub('[^%w_:%-]', '')
    if name == '' then return end
    if not IsModelInCdimage(joaat(name)) then
        notice(('"%s" is not a model of this game build.'):format(name), 'error')
        return
    end
    local info = modelInfo(name)
    if not S.assetByModel[name:lower()] then
        local a = { model = name, label = name, category = 'misc', vehicle = info.vehicle, custom = true }
        S.assetByModel[name:lower()] = a
        SendNUIMessage({ action = 'placer:asset', asset = a })
    end
    arm(name, 1)
end

function COMMANDS.save()
    if not S then return end
    S.result = { ok = true, objects = exportAll() }
    S.done = true
end

function COMMANDS.cancel()
    if not S then return end
    S.result = { ok = false, cancelled = true }
    S.done = true
end

RegisterNUICallback('placer:cmd', function(data, cb)
    cb('ok')
    if not S or type(data) ~= 'table' then return end
    local fn = COMMANDS[data.t]
    if not fn then return end
    local ok, err = pcall(fn, data)
    if not ok then
        print(('[nova_convoytruck] prop placer command "%s" failed: %s'):format(tostring(data.t), tostring(err)))
        notice('That action failed (details in F8).', 'error')
    end
end)

RegisterNUICallback('placer:pointer', function(data, cb)
    cb('ok')
    if not S or type(data) ~= 'table' then return end
    local p = S.pointer
    p.nx, p.ny = clamp(tonumber(data.nx) or 0.0, -1.0, 1.0), clamp(tonumber(data.ny) or 0.0, -1.0, 1.0)
    p.px = tonumber(data.px) or p.px
    p.py = tonumber(data.py) or p.py
    p.inside = data.inside ~= false
    p.shift = data.shift == true
    if tonumber(data.aspect) and data.aspect > 0.5 then S.aspect = data.aspect end
    local ev = data.ev
    if ev == 'down' then
        S.queue[#S.queue + 1] = { t = 'down', btn = tonumber(data.btn) or 0, shift = data.shift == true, ctrl = data.ctrl == true, nx = p.nx, ny = p.ny, px = p.px, py = p.py }
    elseif ev == 'up' then
        S.queue[#S.queue + 1] = { t = 'up', btn = tonumber(data.btn) or 0 }
    elseif ev == 'wheel' then
        local dy = tonumber(data.dy) or 0.0
        if data.alt then
            local step = tonumber(cfg().rotateStep) or 5.0
            local delta = (dy > 0 and -step or step) * (data.shift and 0.2 or 1.0)
            if S.armed then
                S.armed.rz = wrap360(S.armed.rz + delta); markFull()
            else
                local list = selectedObjects()
                if #list > 0 then
                    pushUndo('wheelrot')
                    -- the selection turns as one piece, round its middle
                    local members, cx, cy = {}, 0.0, 0.0
                    for _, o in ipairs(list) do
                        if not o.locked then
                            members[#members + 1] = { o = o, x = o.x, y = o.y, rz = o.rz }
                            cx, cy = cx + o.x, cy + o.y
                        end
                    end
                    if #members > 0 then
                        rotateGroup(members, cx / #members, cy / #members, delta)
                        for _, m in ipairs(members) do afterEdit(m.o) end
                    end
                end
            end
        else
            S.dolly = S.dolly + (dy > 0 and -1.0 or 1.0) * (data.shift and 3.0 or 1.0)
        end
    elseif ev == 'leave' then
        p.inside = false
    end
end)

RegisterNUICallback('placer:fly', function(data, cb)
    cb('ok')
    if not S or type(data) ~= 'table' then return end
    S.fly = { f = clamp(tonumber(data.f) or 0.0, -1.0, 1.0), r = clamp(tonumber(data.r) or 0.0, -1.0, 1.0), u = clamp(tonumber(data.u) or 0.0, -1.0, 1.0), fast = data.fast == true }
end)

RegisterNUICallback('placer:look', function(data, cb)
    cb('ok')
    if not S or type(data) ~= 'table' then return end
    S.lookDx = S.lookDx + (tonumber(data.dx) or 0.0)
    S.lookDy = S.lookDy + (tonumber(data.dy) or 0.0)
end)

-- ── the catalog (assets + categories) ──────────────────────────────────────────
local validModelCache = {}
local vehModelCache = {}

local function isModelInGame(hash)
    local v = validModelCache[hash]
    if v == nil then
        v = (IsModelInCdimage(hash) == 1 or IsModelInCdimage(hash) == true)
        validModelCache[hash] = v
    end
    return v
end

local function isModelVeh(hash)
    local v = vehModelCache[hash]
    if v == nil then
        v = (IsModelAVehicle(hash) == 1 or IsModelAVehicle(hash) == true)
        vehModelCache[hash] = v
    end
    return v
end

local function formatPropLabel(model)
    local s = model:gsub('^prop_', ''):gsub('^v_', ''):gsub('_', ' ')
    return s:sub(1, 1):upper() .. s:sub(2)
end

local function slugifyCat(name)
    local s = tostring(name or 'misc'):lower():gsub('[&%s/,]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    return s ~= '' and s or 'misc'
end

local cachedAllAssets = nil
local cachedCatLabels = nil
local cachedAllCats = nil

local function getBaseCatalog()
    if cachedAllAssets then return cachedAllAssets, cachedCatLabels, cachedAllCats end
    local C = cfg()
    local alias = C.categoryAlias or {}
    local catLabels = {}
    for _, c in ipairs(C.categories or {}) do catLabels[c.id] = c.label end

    local seen, assets = {}, {}
    local function add(e, defaultCat, defaultCatLabel)
        if type(e) ~= 'table' or type(e.model) ~= 'string' or e.model == '' then return end
        local key = e.model:lower()
        if seen[key] then return end
        seen[key] = true
        local cat = e.category or defaultCat or 'misc'
        cat = alias[cat] or cat
        local label = e.label or formatPropLabel(e.model)
        local catLabel = e.categoryLabel or defaultCatLabel or catLabels[cat] or cat
        catLabels[cat] = catLabels[cat] or catLabel
        assets[#assets + 1] = {
            model = e.model,
            label = label,
            category = cat,
            stackable = e.stackable == true,
            dupOffset = e.dupOffset,
            step = e.step
        }
    end

    for _, e in ipairs(C.assets or {}) do add(e) end
    for _, e in ipairs(Config.CheckpointBarricadeProps or {}) do add(e, 'barricades', 'Barricades') end
    local cw = Config.ContainerWars or {}
    for _, e in ipairs(cw.containerModels or {}) do add({ model = e.model, label = e.label, category = 'containers', stackable = true, dupOffset = 2.6 }) end
    local H = cw.harbour or {}
    for _, e in ipairs(H.dummyModels or {}) do add({ model = e.model, label = e.label, category = 'containers', stackable = true, dupOffset = 3.2 }) end

    -- Load full prop catalog from Config.PropGroups (from config/prop_list.lua)
    if type(Config.PropGroups) == 'table' then
        for _, group in ipairs(Config.PropGroups) do
            local gName = group.category or 'Misc'
            local gSlug = slugifyCat(gName)
            catLabels[gSlug] = gName
            local isStackable = (gSlug:find('container') or gSlug:find('barrel') or gSlug:find('crate') or gSlug:find('box') or gSlug:find('pallet')) ~= nil
            local dOffset = gSlug:find('container') and 2.6 or 1.0
            for _, m in ipairs(group.models or {}) do
                add({
                    model = m,
                    category = gSlug,
                    categoryLabel = gName,
                    stackable = isStackable,
                    dupOffset = dOffset,
                }, gSlug, gName)
            end
        end
    end

    local validAssets = {}
    for _, a in ipairs(assets) do
        local hash = joaat(a.model)
        if isModelInGame(hash) then
            a.vehicle = isModelVeh(hash)
            validAssets[#validAssets + 1] = a
        end
    end

    cachedAllAssets = validAssets
    cachedCatLabels = catLabels
    cachedAllCats = C.categories or {}
    return cachedAllAssets, cachedCatLabels, cachedAllCats
end

local function buildCatalog(ctx)
    local allAssets, catLabels, baseCats = getBaseCatalog()
    local allowCats
    if type(ctx.categories) == 'table' then
        allowCats = {}
        for _, id in ipairs(ctx.categories) do allowCats[id] = true end
    end

    local out, used = {}, {}
    for _, a in ipairs(allAssets) do
        if not allowCats or allowCats[a.category] then
            if not (ctx.vehicles == false and a.vehicle) then
                out[#out + 1] = a
                used[a.category] = catLabels[a.category] or true
            end
        end
    end

    local cats = {}
    for _, c in ipairs(baseCats) do
        if used[c.id] then cats[#cats + 1] = { id = c.id, label = c.label }; used[c.id] = nil end
    end
    local extraCats = {}
    for id, catLabel in pairs(used) do
        local label = type(catLabel) == 'string' and catLabel or (id:sub(1, 1):upper() .. id:sub(2):gsub('_', ' '))
        extraCats[#extraCats + 1] = { id = id, label = label }
    end
    table.sort(extraCats, function(a, b) return a.label < b.label end)
    for _, ec in ipairs(extraCats) do cats[#cats + 1] = ec end
    return out, cats
end

-- ── the world's own copies ─────────────────────────────────────────────────────
-- The world already holds the server's own copies of what is being edited: the harbour dummy containers (built by
-- the server, always there) and the props of a running event. While the placer is open they are hidden for this
-- player, so only the placer's editable copies are seen. Without this, moving a container shows the original still
-- standing behind it, which looks exactly like a duplicate.
local hiddenWorld = {}

-- The harbour dummies are only hidden when it is THEM being edited (context 'container_yard'). Any other placer
-- (an event's Props tab, Hot Cargo ...) leaves them standing and visible as reference — hiding them there made the
-- yard look empty, as if the placed stacks were gone.
local function hideWorldCopies(ctxId)
    hiddenWorld = {}
    local editingYard = (ctxId == 'container_yard')
    for _, pool in ipairs({ 'CObject', 'CVehicle' }) do
        for _, ent in ipairs(GetGamePool(pool)) do
            if DoesEntityExist(ent) and NetworkGetEntityIsNetworked(ent) then
                local st = Entity(ent).state
                local dummy, prop = st.cw_dummy, st.nova_prop_solid
                if (dummy ~= nil and editingYard) or prop ~= nil then
                    hiddenWorld[#hiddenWorld + 1] = { ent = ent, solid = not (dummy == 0 or prop == 0) }
                    SetEntityVisible(ent, false, false)
                    SetEntityCollision(ent, false, false)
                end
            end
        end
    end
end

local function restoreWorldCopies()
    for _, h in ipairs(hiddenWorld) do
        if DoesEntityExist(h.ent) then
            SetEntityVisible(h.ent, true, false)
            SetEntityCollision(h.ent, h.solid, h.solid)
        end
    end
    hiddenWorld = {}
end

-- ── opening / closing ──────────────────────────────────────────────────────────
local function finish()
    local result = S.result or { ok = false, cancelled = true }
    local cb = S.cb
    local previous = S.previous

    for _, o in ipairs(S.objects) do destroyEntities(o) end
    clearGhost()
    if S.companion and S.companion.ent then deleteEntities({ S.companion.ent }) end
    if S.guideEntities then
        for _, ent in ipairs(S.guideEntities) do
            if DoesEntityExist(ent) then DeleteEntity(ent) end
        end
        S.guideEntities = nil
    end
    for hash in pairs(S.loaded) do SetModelAsNoLongerNeeded(hash) end

    ClearFocus()
    if S.cam and S.cam.handle then
        RenderScriptCams(false, true, 400, true, true)
        DestroyCam(S.cam.handle, false)
    end
    local ped = PlayerPedId()
    if previous.entity and DoesEntityExist(previous.entity) then FreezeEntityPosition(previous.entity, false) end
    SetPlayerInvincible(PlayerId(), previous.invincible)

    restoreWorldCopies()
    SendNUIMessage({ action = 'placer:close' })
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    S = nil
    -- brings the tablet back where it was (a no-op when it was not open)
    TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
    if cb then cb(result) end
end

function PropPlacer.isOpen() return S ~= nil end

-- opts: { context, title, objects = {...}, focus = {x,y,z}, companion = { model, back }, autoCreate = { model } }
function PropPlacer.open(opts, cb)
    opts = opts or {}
    if S then
        if cb then cb({ ok = false, error = 'busy' }) end
        return
    end
    clearPreview()
    TriggerEvent('nova_convoytruck:client:clearPropPreviews')   -- the tablet's in-world previews would sit under the placer's copies
    hideWorldCopies(opts.context or 'generic')
    local ctxId = opts.context or 'generic'
    local ctx = context(ctxId)
    local assets, categories = buildCatalog(ctx)

    S = {
        context = ctxId, ctx = ctx, cb = cb, title = opts.title or ctx.label or 'Prop Placer',
        objects = {}, byId = {}, nextId = 0, selected = {}, active = nil,
        tool = 'select', snapGround = true, grid = false, gridSize = tonumber(cfg().gridSize) or 0.5,
        keepTool = false, spawnOnPlace = true,
        features = { stack = ctx.stack ~= false, collision = ctx.collision ~= false, maxStack = clamp(math.floor(tonumber(ctx.maxStack) or 6), 1, 10) },
        info = {}, loaded = {}, entToObj = {}, assetByModel = {},
        undo = {}, redo = {}, patch = {}, needFull = true, lastSend = 0, dirty = false,
        pointer = { nx = 0.0, ny = 0.0, px = 0.0, py = 0.0, inside = false }, fly = { f = 0.0, r = 0.0, u = 0.0, fast = false },
        lookDx = 0.0, lookDy = 0.0, dolly = 0.0, queue = {}, aspect = 1.7778,
    }
    for _, a in ipairs(assets) do S.assetByModel[a.model:lower()] = a end

    -- reference outlines of what the event already has there (the harbour's real containers and crane)
    S.guides = opts.guides
    if S.guides == nil and (ctxId == 'container_yard' or ctxId == 'container_wars') then
        local okG, list = pcall(harbourGuides)
        S.guides = okG and list or {}
    end
    S.guides = S.guides or {}
    local hasSpots = false
    local hasCheckpointGuides = false
    local hasRouteGuides = false
    for _, g in ipairs(S.guides) do
        if g.kind == 'pickup' or g.kind == 'drop' then hasSpots = true end
        if g.kind == 'checkpoint' or g.kind == 'checkpoint_prop' or g.kind == 'checkpoint_vehicle' then hasCheckpointGuides = true end
        if g.kind == 'route' or g.kind == 'race_start' then hasRouteGuides = true end
    end

    -- Spawn visual preview/ghost entities for guides that specify a model (e.g. checkpoint barricades / decor vehicles)
    S.guideEntities = {}
    for _, g in ipairs(S.guides) do
        if g.model and g.model ~= '' and g.x and g.y and g.z then
            local hash = joaat(g.model)
            if isModelInGame(hash) and loadModel(hash) then
                local head = tonumber(g.h or g.heading) or 0.0
                local ent
                if isModelVeh(hash) then
                    ent = CreateVehicle(hash, g.x, g.y, g.z, head, false, false)
                    if ent and DoesEntityExist(ent) then
                        SetEntityAlpha(ent, 215, false)
                        SetVehicleDoorsLocked(ent, 2)
                        FreezeEntityPosition(ent, true)
                        SetEntityCollision(ent, false, false)
                        S.guideEntities[#S.guideEntities + 1] = ent
                    end
                else
                    ent = CreateObject(hash, g.x, g.y, g.z, false, false, false)
                    if ent and DoesEntityExist(ent) then
                        SetEntityHeading(ent, head)
                        if g.rx or g.ry then SetEntityRotation(ent, (tonumber(g.rx) or 0.0) + 0.0, (tonumber(g.ry) or 0.0) + 0.0, head + 0.0, 2, true) end
                        SetEntityAlpha(ent, 215, false)
                        FreezeEntityPosition(ent, true)
                        SetEntityCollision(ent, false, false)
                        S.guideEntities[#S.guideEntities + 1] = ent
                    end
                end
            end
        end
    end

    -- the player stays where they are, safe, while the camera flies
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    S.previous = { entity = (veh ~= 0) and veh or ped, invincible = GetPlayerInvincible(PlayerId()) }
    FreezeEntityPosition(S.previous.entity, true)
    SetPlayerInvincible(PlayerId(), true)

    -- the tablet steps aside (it keeps its draft); the placer window takes over the mouse
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')

    -- the objects that already exist
    for _, d in ipairs(opts.objects or {}) do
        if type(d) == 'table' and d.model and tonumber(d.x) and tonumber(d.y) and tonumber(d.z) then
            local extra = {}
            for k, v in pairs(d) do if not KNOWN[k] then extra[k] = v end end
            local o = addObject({
                model = tostring(d.model), x = tonumber(d.x) + 0.0, y = tonumber(d.y) + 0.0, z = tonumber(d.z) + 0.0,
                rx = tonumber(d.rx) or 0.0, ry = tonumber(d.ry) or 0.0, rz = tonumber(d.rz) or tonumber(d.heading) or 0.0,
                stack = tonumber(d.stack), step = tonumber(d.step), collision = d.collision, uid = d.uid, extra = extra,
            })
            if not o then break end
        end
    end
    S.dirty = false

    -- opened on one particular object (the tablet's "edit this prop" / the in-world "Edit in Prop Placer")
    local pre = tonumber(opts.selectIndex) and S.objects[math.floor(tonumber(opts.selectIndex))]
    if pre then
        S.selected[pre.id], S.active = true, pre.id
        opts.focus = { x = pre.x, y = pre.y, z = pre.z }
    end

    S.cam = startCamera(opts.focus)

    -- a trailer that follows the (single) truck, e.g. Hot Cargo
    if opts.companion and opts.companion.model and opts.companion.model ~= '' then
        local info = modelInfo(opts.companion.model)
        if info.valid and loadModel(info.hash) then
            S.companion = { back = tonumber(opts.companion.back) or 9.0, hash = info.hash }
        end
    end

    local compact = (tonumber(ctx.maxObjects) == 1) or opts.compact == true
    SendNUIMessage({
        action = 'placer:open',
        session = {
            context = ctxId, title = S.title, compact = compact,
            assets = assets, categories = categories, startCategory = opts.startCategory,
            limits = { maxObjects = limit(), maxStack = S.features.maxStack },
            features = S.features,
            moveStep = tonumber(cfg().moveStep) or 0.25, rotateStep = tonumber(cfg().rotateStep) or 5.0,
            gridSizes = { 0.25, 0.5, 1.0, 2.0 },
        },
        state = stateMessage(),
    })
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    if hasSpots then
        SetTimeout(900, function()   -- once the window has drawn
            if S and S.guides then notice('Blue = container spots, green = drop spots, amber = the crane\'s legs. They already exist — no dummy is needed there. A dummy standing on one turns red.', 'info') end
        end)
    elseif hasRouteGuides then
        SetTimeout(900, function()
            if S and S.guides then notice('Green = start, blue = checkpoints, gold = finish. The white line is the route and its arrows show which way racers drive. Props can stand on it.', 'info') end
        end)
    elseif hasCheckpointGuides then
        SetTimeout(900, function()
            if S and S.guides then notice('Cyan = Checkpoint zones, Amber = Checkpoint barricades, Purple = Checkpoint vehicles. Existing convoy elements are shown as reference guides.', 'info') end
        end)
    end

    CreateThread(function()
        local session = S
        local last = GetGameTimer()
        local cursorSentAt, lastCursor = 0, nil
        local autoDone = false
        local collAt = 0
        local focusAt = 0
        local ok, err = pcall(function()
            while S == session and not S.done do
                Wait(0)
                local now = GetGameTimer()
                local dt = math.min((now - last) / 1000.0, 0.1)
                last = now

                DisableAllControlActions(0)
                -- Esc belongs to the placer window: keep the game's pause menu from opening on top of it (it would
                -- steal the mouse and the window would look frozen)
                DisableControlAction(0, 199, true)
                DisableControlAction(0, 200, true)
                DisableControlAction(1, 199, true)
                DisableControlAction(1, 200, true)
                DisableControlAction(2, 199, true)
                DisableControlAction(2, 200, true)
                if IsPauseMenuActive() then SetPauseMenuActive(false) end
                HideHudAndRadarThisFrame()
                updateCamera(dt)

                -- queued mouse buttons
                local q = S.queue
                S.queue = {}
                for _, e in ipairs(q) do
                    if e.t == 'down' then onDown(e) elseif e.t == 'up' then onUp(e) end
                end

                -- pointer: drag, hover, the armed hologram
                local hit = pointerHit()
                if S.drag then onMove(S.pointer) end
                -- the white outline shows exactly the object a click would select (same test as onDown)
                local hoverId = nil
                if not S.drag and S.pointer.inside then hoverId = (hit and hit.objId) or nearestOnScreen(S.pointer.nx, S.pointer.ny) end
                if S.armed then
                    ensureGhost()
                    if S.ghost and hit then
                        local info = S.ghost.info
                        local gx, gy = snapValue(hit.pos.x), snapValue(hit.pos.y)
                        local gz = hit.pos.z - info.mn.z
                        for k, e in ipairs(S.ghost.ents) do
                            if DoesEntityExist(e) then placeEntity(e, gx, gy, gz + (k - 1) * (S.armed.step or 0), 0.0, 0.0, S.armed.rz) end
                        end
                    elseif S.ghost then
                        for _, e in ipairs(S.ghost.ents) do
                            if DoesEntityExist(e) then SetEntityCoordsNoOffset(e, 0.0, 0.0, -200.0, false, false, false) end
                        end
                    end
                end

                -- first frame of a single-object session with nothing in it: put the object where the camera looks
                if not autoDone and opts.autoCreate and opts.autoCreate.model and #S.objects == 0 then
                    local from, dir = screenRay(0.0, 0.0)
                    local pos = castRay(from, from + dir * 200.0, nil) or (S.focusPoint)
                    -- a model this game build does not have: the first fallback that exists is placed instead
                    local autoModel = opts.autoCreate.model
                    if not IsModelInCdimage(joaat(autoModel)) then
                        for _, fb in ipairs(opts.autoCreate.fallbacks or {}) do
                            if IsModelInCdimage(joaat(fb)) then autoModel = fb break end
                        end
                    end
                    local info = modelInfo(autoModel)
                    local o = addObject({ model = autoModel, x = pos.x, y = pos.y, z = pos.z - info.mn.z, rz = wrap360(S.cam.yaw) })
                    if o then selectOnly(o.id) end
                    autoDone = true
                elseif #S.objects > 0 or not opts.autoCreate then
                    autoDone = true
                end

                drawScene(hoverId)

                -- cursor read-out for the window
                if hit and now - cursorSentAt > 100 then
                    local key = ('%.1f%.1f%.1f'):format(hit.pos.x, hit.pos.y, hit.pos.z)
                    if key ~= lastCursor then
                        lastCursor, cursorSentAt = key, now
                        SendNUIMessage({ action = 'placer:cursor', x = round(hit.pos.x, 2), y = round(hit.pos.y, 2), z = round(hit.pos.z, 2) })
                    end
                end
                if now - focusAt > 700 then
                    focusAt = now
                    SetNuiFocus(true, true)
                    SetNuiFocusKeepInput(false)
                end
                if now - collAt > 400 then
                    collAt = now
                    RequestCollisionAtCoord(S.cam.x, S.cam.y, S.planeZ)
                end

                flush(now)
            end
        end)
        if not ok then
            print(('[nova_convoytruck] prop placer error: %s'):format(tostring(err)))
            if S == session then
                S.result = { ok = false, error = 'placer_error' }
            end
        end
        if S == session then finish() end
    end)
end

-- ── in-world preview of a saved layout ─────────────────────────────────────────
-- "Preview In-World" in the tablet: the saved props / vehicles are spawned locally (only for this player) so
-- they can be seen exactly where they will stand when the event runs. Cleared on request, when the tablet
-- closes, when a placer session opens, and when the resource stops.
-- previewEntities[key] = { ents = {...}, sig = '<model|pos|rot|stack|collision>' }. `key` is the tablet's stable
-- "event id : object id", so spawning the same layout twice REUSES what already stands (no duplicates), moves /
-- rebuilds only what changed, and removes what is no longer in the layout. This is runtime only - nothing here
-- ever touches the saved configuration.
local previewEntities = {}

local function previewSig(d)
    return table.concat({
        tostring(d.model), tostring(d.x), tostring(d.y), tostring(d.z), tostring(d.rx or 0), tostring(d.ry or 0),
        tostring(d.heading or d.rz or 0), tostring(d.stack or 1), tostring(d.step or ''), tostring(d.collision),
    }, '|')
end

local function previewAlive(entry)
    if not entry or #entry.ents == 0 then return false end
    for _, e in ipairs(entry.ents) do
        if not DoesEntityExist(e) then return false end
    end
    return true
end

function clearPreview()
    for _, entry in pairs(previewEntities) do deleteEntities(entry.ents) end
    previewEntities = {}
end

-- Builds one object; returns the entities, or nil + the reason (so the tablet can say WHICH object failed and why).
local function buildPreviewObject(d)
    local model = tostring(d.model or '')
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if model == '' then return nil, 'no_model' end
    if not (x and y and z) then return nil, 'bad_position' end
    local hash = joaat(model)
    if not IsModelInCdimage(hash) then return nil, 'model_not_in_game' end
    if not pcall(lib.requestModel, hash, 5000) then return nil, 'model_load_timeout' end
    local vehicle = IsModelAVehicle(hash) == true
    local heading = tonumber(d.heading) or tonumber(d.rz) or 0.0
    local rx, ry = tonumber(d.rx) or 0.0, tonumber(d.ry) or 0.0
    local pieces = vehicle and 1 or math.max(1, math.min(10, math.floor(tonumber(d.stack) or 1)))
    local step = tonumber(d.step) or 2.6
    local ents = {}
    for k = 0, pieces - 1 do
        local pz = z + k * step
        local ent
        if vehicle then
            ent = CreateVehicle(hash, x + 0.0, y + 0.0, pz + 0.0, heading + 0.0, false, false)
        else
            ent = CreateObject(hash, x + 0.0, y + 0.0, pz + 0.0, false, false, false)
        end
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            FreezeEntityPosition(ent, true)
            SetEntityCoordsNoOffset(ent, x + 0.0, y + 0.0, pz + 0.0, false, false, false)
            SetEntityRotation(ent, rx + 0.0, ry + 0.0, heading + 0.0, 2, true)
            if vehicle then
                SetVehicleDoorsLocked(ent, 10)
                SetVehicleEngineOn(ent, false, true, true)
                SetEntityInvincible(ent, true)
            end
            if d.collision == false then SetEntityCollision(ent, false, false) end
            ents[#ents + 1] = ent
        elseif k == 0 then
            SetModelAsNoLongerNeeded(hash)
            return nil, 'create_failed'
        end
    end
    SetModelAsNoLongerNeeded(hash)
    return ents
end

RegisterNUICallback('placer:preview', function(data, cb)
    local list = (type(data) == 'table' and data.objects) or {}
    local wanted = {}
    local made, reused, removed = 0, 0, 0
    local failed = {}
    for i, d in ipairs(list) do
        if type(d) == 'table' then
            local key = tostring(d.key or ('#' .. i))
            wanted[key] = true
            local sig = previewSig(d)
            local have = previewEntities[key]
            if have and have.sig == sig and previewAlive(have) then
                reused = reused + 1                       -- already standing exactly there: keep it
            else
                if have then deleteEntities(have.ents); previewEntities[key] = nil end
                local ents, why = buildPreviewObject(d)
                if ents then
                    previewEntities[key] = { ents = ents, sig = sig, data = d }
                    made = made + 1
                else
                    failed[#failed + 1] = { key = key, model = tostring(d.model), reason = why, x = d.x, y = d.y, z = d.z }
                    print(('[NovaConvoy][PropSpawn] %s (%s) not spawned: %s  @ %s, %s, %s'):format(key, tostring(d.model), why, tostring(d.x), tostring(d.y), tostring(d.z)))
                end
            end
        end
    end
    for key, entry in pairs(previewEntities) do
        if not wanted[key] then
            deleteEntities(entry.ents)
            previewEntities[key] = nil
            removed = removed + 1
        end
    end
    cb({ ok = true, spawned = made, reused = reused, removed = removed, missing = #failed, failed = failed, total = #list })
end)

RegisterNUICallback('placer:clearPreview', function(_, cb)
    clearPreview()
    cb('ok')
end)

-- The preview deliberately SURVIVES the tablet closing: Prop Spawn Mode is for closing the tablet, walking to the
-- spot and looking at the layout. It is removed by turning the mode off, when the event starts
-- (clearPropPreviews), when a placer session opens, or when the resource stops.
RegisterNUICallback('placer:previewStatus', function(_, cb)
    local n = 0
    for _ in pairs(previewEntities) do n = n + 1 end
    cb({ ok = true, count = n })
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearPreview() end
end)

-- Keeps the preview standing: the game may drop a local entity that was created far from the player, or a model that
-- streamed out; anything missing is rebuilt from the layout it was spawned from.
CreateThread(function()
    while true do
        Wait(3000)
        if next(previewEntities) then
            for key, entry in pairs(previewEntities) do
                if entry.data and not previewAlive(entry) then
                    deleteEntities(entry.ents)
                    local ents = buildPreviewObject(entry.data)
                    if ents then entry.ents = ents else previewEntities[key] = nil end
                end
            end
        end
    end
end)

local function onClearPropPreviews()
    clearPreview()
    SendNUIMessage({ action = 'propSpawnMode:reset' })
end
RegisterNetEvent('nova_convoytruck:client:clearPropPreviews', onClearPropPreviews)
AddEventHandler('nova_convoytruck:client:clearPropPreviews', onClearPropPreviews)

-- ── entry points ───────────────────────────────────────────────────────────────
-- The tablet: the reply to the NUI call is the session's result.
RegisterNUICallback('placer:open', function(data, cb)
    PropPlacer.open(data or {}, function(result) cb(result) end)
end)

exports('OpenPropPlacer', function(opts, cb) PropPlacer.open(opts or {}, cb) end)

-- Admin command: place a free layout and get it back as text (printed in F8 and copied).
RegisterCommand('propplacer', function(_, args)
    local ok = lib.callback.await('nova_convoytruck:propPlacer:access', false)
    if not ok then
        lib.notify({ title = 'Prop Placer', description = 'You do not have access.', type = 'error' })
        return
    end
    local ctxId = args[1] or 'generic'
    PropPlacer.open({ context = ctxId }, function(result)
        if not result or not result.ok then return end
        local lines = {}
        for _, p in ipairs(result.objects or {}) do
            lines[#lines + 1] = ('{ model = %q, x = %.3f, y = %.3f, z = %.3f, heading = %.2f%s },'):format(
                p.model, p.x, p.y, p.z, p.heading,
                (p.rx and (', rx = ' .. p.rx) or '') .. (p.ry and (', ry = ' .. p.ry) or '') .. (p.stack and (', stack = ' .. p.stack) or ''))
        end
        local text = table.concat(lines, '\n')
        print('[nova_convoytruck] prop placer layout:\n' .. text)
        if lib.setClipboard then lib.setClipboard(text) end
        lib.notify({ title = 'Prop Placer', description = ('%d object(s) — copied to the clipboard and printed in F8.'):format(#lines), type = 'success' })
    end)
end, false)

-- Props that are not solid (state bag nova_prop_solid = 0) have their collision switched off as they stream in.
AddStateBagChangeHandler('nova_prop_solid', nil, function(bagName, _, value)
    if value ~= 0 then return end
    CreateThread(function()
        local deadline = GetGameTimer() + 8000
        local ent = 0
        while ent == 0 and GetGameTimer() < deadline do
            ent = GetEntityFromStateBagName(bagName)
            if ent == 0 then Wait(100) end
        end
        if ent ~= 0 and DoesEntityExist(ent) then SetEntityCollision(ent, false, false) end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearPreview()
    restoreWorldCopies()
    if not S then return end
    for _, o in ipairs(S.objects) do deleteEntities(o.ents) end
    clearGhost()
    ClearFocus()
    RenderScriptCams(false, false, 0, true, true)
    if S.previous and S.previous.entity and DoesEntityExist(S.previous.entity) then FreezeEntityPosition(S.previous.entity, false) end
    if S.previous then SetPlayerInvincible(PlayerId(), S.previous.invincible) end
    SetNuiFocus(false, false)
    S = nil
end)
