-- ─── Harbour layout store (server) ─────────────────────────────────────────────
-- The harbour yard (Config.ContainerWars.harbour) can be edited from the tablet with hologram placers:
-- the gantry crane's position, the container spots and the drop spots. Those edits are saved here, in
-- data/harbour.json, and laid over the values in config.lua every time the resource starts — so config.lua
-- holds the defaults and this file holds what was placed in game. Delete the file to go back to config.lua.
--
-- Clients keep their own copy of the layout (they draw it, and the Test Crane Run uses it), so every save
-- is pushed to everyone, and a joining client asks for it once.

HarbourStore = {}

local FILE = 'data/harbour.json'
local MAX_SPOTS = 10

local stored = {}   -- { crane = {x,y,z,heading,auto}, pickups = {...}, drops = {...} }

local function yard()
    Config.ContainerWars = Config.ContainerWars or {}
    Config.ContainerWars.harbour = Config.ContainerWars.harbour or {}
    return Config.ContainerWars.harbour
end

local function round4(n) return tonumber(('%.4f'):format(n)) end

local function point(t, keepModel)
    if type(t) ~= 'table' or not tonumber(t.x) or not tonumber(t.y) or not tonumber(t.z) then return nil end
    local out = { x = round4(t.x), y = round4(t.y), z = round4(t.z), heading = round4(tonumber(t.heading) or 0.0) }
    if keepModel then
        if type(t.mapModel) == 'string' and t.mapModel ~= '' then
            out.mapModel = t.mapModel:gsub('[^%w_:]', ''):sub(1, 60)
        end
        if type(t.model) == 'string' and t.model ~= '' then
            out.model = t.model:gsub('[^%w_:]', ''):sub(1, 60)
        end
        if t.assignedDrop ~= nil and tonumber(t.assignedDrop) then
            out.assignedDrop = math.floor(tonumber(t.assignedDrop))
        end
    end
    if t.assignedCrane ~= nil and tonumber(t.assignedCrane) then
        out.assignedCrane = math.floor(tonumber(t.assignedCrane))
    end
    return out
end

local function pointList(list, keepModel)
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, p in ipairs(list) do
        local q = point(p, keepModel)
        if q and #out < MAX_SPOTS then out[#out + 1] = q end
    end
    return out
end

-- The cranes: { x, y, z, heading, uid }. One per aisle of the yard; each container is carried by the one that can
-- reach both its spot and its drop (CWGantry.craneFor).
local MAX_CRANES = 6
local function craneList(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, c in ipairs(list) do
        local p = point(c, false)
        if p and #out < MAX_CRANES then
            local uid = type(c.uid) == 'string' and c.uid:gsub('[^%w_]', ''):sub(1, 24) or ''
            if uid == '' then uid = ('c%05d%04d'):format(os.time() % 100000, math.random(0, 9999)) end
            p.uid = uid
            out[#out + 1] = p
        end
    end
    return out
end

-- Planned crane routes: { ["1"] = { points = {{x,y}...}, pick = {x,y}, drop = {x,y}, violations = n }, ... } keyed by the
-- container's number. A route is only used while its pickup and drop still match (see CWGantry.chooseCarry).
local function carryList(t)
    local out = {}
    if type(t) ~= 'table' then return out end
    local function xy(q)
        if type(q) == 'table' and tonumber(q.x) and tonumber(q.y) then return { x = round4(q.x), y = round4(q.y) } end
        return nil
    end
    for k, v in pairs(t) do
        local idx = math.floor(tonumber(k) or 0)
        if idx >= 1 and idx <= MAX_SPOTS and type(v) == 'table' and type(v.points) == 'table' then
            local pts = {}
            for _, p in ipairs(v.points) do
                local q = xy(p)
                if q and #pts < 24 then pts[#pts + 1] = q end
            end
            out[tostring(idx)] = { points = pts, pick = xy(v.pick), drop = xy(v.drop), violations = math.max(0, math.floor(tonumber(v.violations) or 0)) }
        end
    end
    return out
end

-- Dummy container stacks: { x, y, z, heading, model, stack (1-6 pods), step (metres between pods), collision }
local function defaultDummyModel()
    local H = yard()
    return H.dummyModel or (H.dummyModels and H.dummyModels[1] and H.dummyModels[1].model) or 'port_xr_contpod_01'
end
local function dummyList(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    local cap = tonumber((yard().maxDummies)) or 150
    local defaultStep = tonumber(yard().dummyStep) or 2.6
    for _, d in ipairs(list) do
        local p = point(d, false)
        if p and #out < cap then
            p.stack = math.max(1, math.min(6, math.floor(tonumber(d.stack) or 1)))
            p.step = round4(math.max(0.5, math.min(10.0, tonumber(d.step) or defaultStep)))
            local model = type(d.model) == 'string' and d.model:gsub('[^%w_:]', ''):sub(1, 60) or ''
            p.model = (model ~= '') and model or defaultDummyModel()
            p.collision = d.collision ~= false
            -- tilt (pitch / roll) set with the shared Prop Placer; a plain dummy is upright and has none
            local rx, ry = tonumber(d.rx) or 0.0, tonumber(d.ry) or 0.0
            if rx ~= 0.0 then p.rx = round4(rx) end
            if ry ~= 0.0 then p.ry = round4(ry) end
            local uid = type(d.uid) == 'string' and d.uid:gsub('[^%w_]', ''):sub(1, 24) or ''
            if uid ~= '' then p.uid = uid end
            out[#out + 1] = p
        end
    end
    return out
end

-- ── the dummies in the world ─────────────────────────────────────────────────
-- They are built when a Container Wars event starts, removed when it ends, and while it runs checked every 30 s
-- (a pod removed by some cleanup script is put back).
local dummyEntities = {}
local rebuildToken = 0
local building = false

local function clearDummies()
    for _, e in ipairs(dummyEntities) do
        if DoesEntityExist(e) then DeleteEntity(e) end
    end
    dummyEntities = {}
end

local function spawnPod(model, x, y, z, heading, solid, rx, ry)
    local obj = CreateObjectNoOffset(joaat(model), x + 0.0, y + 0.0, z + 0.0, true, true, false)
    if not obj or obj == 0 then return nil end
    local deadline = GetGameTimer() + 3000
    while not DoesEntityExist(obj) and GetGameTimer() < deadline do Wait(25) end
    if not DoesEntityExist(obj) then return nil end
    if (rx or 0.0) ~= 0.0 or (ry or 0.0) ~= 0.0 then
        pcall(SetEntityRotation, obj, (rx or 0.0) + 0.0, (ry or 0.0) + 0.0, (heading or 0.0) + 0.0, 2, true)
    else
        SetEntityHeading(obj, (heading or 0.0) + 0.0)
    end
    FreezeEntityPosition(obj, true)
    Entity(obj).state:set('cw_dummy', solid and 1 or 0, true)   -- the clients switch collision off for 0
    return obj
end

function HarbourStore.rebuildDummies()
    rebuildToken = rebuildToken + 1
    local mine = rebuildToken
    clearDummies()
    building = true
    local H = yard()
    local cap = tonumber(H.maxDummyPods) or 500
    local built, failedModels = 0, {}
    for _, d in ipairs(H.dummies or {}) do
        local model = d.model or defaultDummyModel()
        local step = tonumber(d.step) or tonumber(H.dummyStep) or 2.6
        if not failedModels[model] then
            for k = 0, math.max(1, math.min(6, tonumber(d.stack) or 1)) - 1 do
                if mine ~= rebuildToken then building = false return end     -- a newer rebuild took over
                if built >= cap then break end
                local obj = spawnPod(model, d.x, d.y, d.z + k * step, d.heading, d.collision ~= false, d.rx, d.ry)
                if obj then
                    dummyEntities[#dummyEntities + 1] = obj
                    built = built + 1
                else
                    -- the model is not in this game build: skip every dummy that uses it
                    failedModels[model] = true
                    print(('[NovaConvoy] Dummy container model "%s" could not be created — those dummies are skipped.'):format(model))
                    break
                end
            end
        end
    end
    if mine == rebuildToken then building = false end
    if built > 0 then print(('[NovaConvoy] %d dummy container pod(s) built'):format(built)) end
end

-- The stacks are not permanent: they stand only while a Container Wars event is running (one holder per running event).
-- Outside an event an admin previews them with Prop Spawn Mode in the tablet (local copies, never these entities).
local dummyUsers = {}
function HarbourStore.holdDummies(id, on)
    local was = next(dummyUsers) ~= nil
    dummyUsers[id] = on and true or nil
    local now = next(dummyUsers) ~= nil
    if now and not was then
        CreateThread(function()
            HarbourStore.rebuildDummies()
            -- the real stacks stand now: every admin's preview copies go, so nothing is doubled
            TriggerClientEvent('nova_convoytruck:client:clearPropPreviews', -1)
        end)
    elseif was and not now then
        rebuildToken = rebuildToken + 1   -- stops a build that is still running
        clearDummies()
        -- a pod that was mid-spawn when the build stopped is added a moment later
        CreateThread(function() Wait(4000) if next(dummyUsers) == nil then clearDummies() end end)
    end
end

-- ── the gantry cranes ─────────────────────────────────────────────────────────
-- Like the dummy stacks, the cranes exist in the world only while a Container Wars event runs: the event builds and
-- drives its own gantries (container_wars_runtime). This is the parked look of every crane (frame, cabin and wheels),
-- used by the tablet's Prop Spawn Mode to preview where they will stand.
function HarbourStore.craneParts()
    local H = yard()
    local out = {}
    for ci, c in ipairs(CWGantry.resolveCranes(H, #(H.pickups or {}))) do
        local g = CWGantry.get(c.model)
        if g and tonumber(c.x) then
            -- parked: the cabin in the middle of the span, the frame where it was placed
            local lay = CWGantry.layout(g, c, c.x, c.y)
            local parts = { { c.model, lay.frame } }
            if g.cabin and g.cabin.model then parts[#parts + 1] = { g.cabin.model, lay.cabin } end
            for _, w in ipairs(lay.wheels) do
                if g.wheels and g.wheels.model then parts[#parts + 1] = { g.wheels.model, w } end
            end
            for pi, part in ipairs(parts) do
                out[#out + 1] = { key = ('harbour-crane:%d:%d'):format(ci, pi), model = part[1], x = part[2].x, y = part[2].y, z = part[2].z, heading = part[2].heading or 0.0 }
            end
        end
    end
    return out
end

CreateThread(function()
    while true do
        Wait(30000)
        if not building and next(dummyUsers) then
            local missing = false
            for _, e in ipairs(dummyEntities) do
                if not DoesEntityExist(e) then missing = true break end
            end
            if missing then HarbourStore.rebuildDummies() end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearDummies() end
end)

-- Lays a saved layout over the live config (also used by clients — see CWGantry.applyLayout).
local function apply()
    CWGantry.applyLayout(yard(), stored)
end

function HarbourStore.load()
    local raw = LoadResourceFile(GetCurrentResourceName(), FILE)
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then
            stored = {
                crane = type(data.crane) == 'table' and data.crane or nil,
                cranes = type(data.cranes) == 'table' and craneList(data.cranes) or nil,
                pickups = type(data.pickups) == 'table' and pointList(data.pickups, true) or nil,
                drops = type(data.drops) == 'table' and pointList(data.drops, false) or nil,
                dummies = type(data.dummies) == 'table' and dummyList(data.dummies) or nil,
                carry = type(data.carry) == 'table' and carryList(data.carry) or nil,
            }
            -- a layout saved when there was only one crane: that crane becomes the first of the list
            if stored.cranes == nil and stored.crane and tonumber(stored.crane.x) then
                stored.cranes = craneList({ stored.crane })
            end
            apply()
            print('[NovaConvoy] Harbour layout loaded from ' .. FILE)
        end
    end
end

function HarbourStore.snapshot()
    return { crane = stored.crane, cranes = stored.cranes, pickups = stored.pickups, drops = stored.drops, dummies = stored.dummies, carry = stored.carry }
end

-- Everything the tablet needs after a change.
local function view()
    local H = yard()
    local n = #(H.pickups or {})
    local cranes = CWGantry.resolveCranes(H, n)
    return {
        ok = true,
        harbour = H,
        dummiesLive = next(dummyUsers) ~= nil,
        craneResolved = cranes[1] or CWGantry.resolveCrane(H, n),
        cranesResolved = cranes,
        craneAssign = CWGantry.assignCranes(H, cranes, math.max(n, #(H.drops or {}))),
    }
end

local function persist()
    SaveResourceFile(GetCurrentResourceName(), FILE, json.encode(stored), -1)
end

-- the parked cranes, for Prop Spawn Mode (local preview copies in the tablet)
lib.callback.register('nova_convoytruck:harbour:craneParts', function(source)
    if not UserPermissions.can(source, 'create.view') then return { ok = false, error = 'No access.' } end
    return { ok = true, parts = HarbourStore.craneParts() }
end)

lib.callback.register('nova_convoytruck:harbour:get', function(source)
    if not UserPermissions.can(source, 'create.view') then return { ok = false, error = 'No access.' } end
    return view()
end)

-- payload: { crane = {x,y,z,heading,auto}, pickups = {...}, drops = {...} } — any part may be left out.
lib.callback.register('nova_convoytruck:harbour:save', function(source, payload)
    if not UserPermissions.can(source, 'create.edit') then return { ok = false, error = 'No access.' } end
    if type(payload) ~= 'table' then return { ok = false, error = 'Malformed request.' } end

    -- NOT written as `(c.auto ~= nil) and (c.auto == true) or cur.auto`: that drops an explicit false and
    -- keeps the old true, so a crane placed by hologram stayed "auto" and was moved off its spot at runtime.
    local auto = (stored.crane and stored.crane.auto == true) or false
    if type(payload.crane) == 'table' then
        local c = payload.crane
        if c.auto ~= nil then auto = (c.auto == true) end
        -- a single crane placed the old way (also what a saved yard layout carries): it is the first of the list
        if type(payload.cranes) ~= 'table' and tonumber(c.x) and tonumber(c.y) then
            local cur = (stored.cranes and stored.cranes[1]) or stored.crane or {}
            local first = craneList({ {
                x = c.x, y = c.y, z = tonumber(c.z) or cur.z or 0.0, heading = tonumber(c.heading) or cur.heading or 0.0, uid = cur.uid,
            } })[1]
            if first then
                stored.cranes = stored.cranes or {}
                stored.cranes[1] = first
            end
        end
    end
    if type(payload.cranes) == 'table' then
        stored.cranes = craneList(payload.cranes)
    end
    -- H.crane mirrors the first crane (and keeps the "auto" flag, which only means something for a single crane)
    local first = stored.cranes and stored.cranes[1]
    if first then
        stored.crane = { x = first.x, y = first.y, z = first.z, heading = first.heading, auto = (#stored.cranes <= 1) and auto or false }
    elseif stored.crane or type(payload.crane) == 'table' then
        stored.crane = stored.crane or {}
        stored.crane.auto = auto
    end
    if type(payload.pickups) == 'table' then stored.pickups = pointList(payload.pickups, true) end
    if type(payload.drops) == 'table' then stored.drops = pointList(payload.drops, false) end
    if type(payload.carry) == 'table' then stored.carry = carryList(payload.carry) end
    local dummiesChanged = false
    if type(payload.dummies) == 'table' then stored.dummies = dummyList(payload.dummies) dummiesChanged = true end

    apply()
    persist()
    TriggerClientEvent('nova_convoytruck:harbour:sync', -1, HarbourStore.snapshot())
    if dummiesChanged and next(dummyUsers) then CreateThread(HarbourStore.rebuildDummies) end   -- only while an event shows them
    print(('[NovaConvoy] Harbour layout saved by %s'):format(Bridge.GetPlayerName(source)))
    return view()
end)

RegisterNetEvent('nova_convoytruck:harbour:request', function()
    TriggerClientEvent('nova_convoytruck:harbour:sync', source, HarbourStore.snapshot())
end)

HarbourStore.load()
