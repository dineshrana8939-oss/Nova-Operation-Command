-- ─── Event props (server) ──────────────────────────────────────────────────────
-- Every event can carry a list of props / vehicles placed with the shared Prop Placer (the "Props" tab
-- of the event editor, def.props). This module
--   · sanitizes that list whenever an event is saved (EventProps.sanitize), and
--   · spawns the objects when the event goes ACTIVE and removes them when it ends (EventProps.start / stop).
-- Convoy CHECKPOINT props (cp.barricadeProps / cp.decorVehicles) are spawned by the convoy runtime itself,
-- and the harbour's permanent dummy containers by harbour_store.lua; the data all three read is written by
-- the same placer, with the same shape:
--   { model, x, y, z, heading, rx?, ry?, kind = 'object'|'vehicle', stack?, step?, collision?, uid? }
-- Every entry has its own transform — duplicates are independent objects.

EventProps = {}

local spawned = {}      -- convoyId -> { token, entities = {} }
local tokenCounter = 0

local function cfg()
    return Config.PropPlacer or {}
end

local function round(n, places)
    local m = 10 ^ (places or 3)
    return math.floor(n * m + 0.5) / m
end

local function clean(s, len)
    return (tostring(s or ''):gsub('[^%w_:%-]', ''):sub(1, len or 60))
end

-- Models that are vehicles, from the placer's own asset list. Used when a saved entry has no `kind` (an older save)
-- so a police car stored as a plain prop is still built as a vehicle instead of silently failing as an object.
local vehicleSet
function EventProps.vehicleModels()
    if vehicleSet then return vehicleSet end
    vehicleSet = {}
    for _, a in ipairs(cfg().assets or {}) do
        if type(a) == 'table' and a.model and (a.vehicle == true or a.category == 'vehicles' or a.category == 'convoy') then
            vehicleSet[tostring(a.model):lower()] = true
        end
    end
    vehicleSet['event_vehicle_dummy'] = nil   -- a prop stand-in, not a real vehicle model
    return vehicleSet
end

function EventProps.isVehicleModel(model)
    return EventProps.vehicleModels()[tostring(model or ''):lower()] == true
end

-- Keeps only what the placer can have produced; anything else is dropped.
function EventProps.sanitize(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    local cap = tonumber(cfg().maxObjects) or 150
    for _, p in ipairs(list) do
        if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) and #out < cap then
            local model = clean(p.model)
            if model ~= '' then
                local o = {
                    model = model,
                    kind = (p.kind == 'vehicle' or EventProps.isVehicleModel(model)) and 'vehicle' or 'object',
                    x = round(tonumber(p.x)), y = round(tonumber(p.y)), z = round(tonumber(p.z)),
                    heading = round(tonumber(p.heading) or tonumber(p.rz) or 0.0, 2),
                }
                local rx, ry = tonumber(p.rx) or 0.0, tonumber(p.ry) or 0.0
                if rx ~= 0.0 then o.rx = round(rx, 2) end
                if ry ~= 0.0 then o.ry = round(ry, 2) end
                if tonumber(p.stack) and tonumber(p.stack) > 1 then
                    o.stack = math.max(1, math.min(10, math.floor(tonumber(p.stack))))
                    o.step = round(math.max(0.3, math.min(12.0, tonumber(p.step) or 2.6)))
                end
                if p.collision == false then o.collision = false end
                local uid = clean(p.uid, 24)
                if uid ~= '' then o.uid = uid end
                -- a Gang Airdrop prop placed from one drop zone's own "Prop Placer" button carries that zone's id (the tablet files it there)
                local zoneId = clean(p.zoneId, 64)
                if zoneId ~= '' then o.zoneId = zoneId end
                out[#out + 1] = o
            end
        end
    end
    return out
end

-- ── spawning ────────────────────────────────────────────────────────────────
local function waitExists(ent, ms)
    local deadline = GetGameTimer() + (ms or 3000)
    while not DoesEntityExist(ent) and GetGameTimer() < deadline do Wait(25) end
    return DoesEntityExist(ent)
end

local function applyRotation(ent, rx, ry, rz)
    if rx ~= 0.0 or ry ~= 0.0 then
        pcall(SetEntityRotation, ent, rx + 0.0, ry + 0.0, rz + 0.0, 2, true)
    else
        SetEntityHeading(ent, rz + 0.0)
    end
end

local function spawnObject(model, x, y, z, rx, ry, rz, solid)
    local ok, obj = pcall(CreateObjectNoOffset, joaat(model), x + 0.0, y + 0.0, z + 0.0, true, true, false)
    if not ok or not obj or obj == 0 or not waitExists(obj) then return nil end
    applyRotation(obj, rx, ry, rz)
    FreezeEntityPosition(obj, true)
    Entity(obj).state:set('nova_prop_solid', solid and 1 or 0, true)   -- clients switch collision off for 0
    return obj
end

local function spawnVehicle(model, x, y, z, rx, ry, rz)
    local ok, veh = pcall(CreateVehicle, joaat(model), x + 0.0, y + 0.0, z + 0.0, rz + 0.0, true, false)
    if not ok or not veh or veh == 0 or not waitExists(veh) then return nil end
    applyRotation(veh, rx, ry, rz)
    -- set dressing, not a usable vehicle: nobody can enter, drive, move or destroy it
    Entity(veh).state:set('nova_prop_solid', 1, true)   -- tag: the Prop Placer hides these while it edits the same layout
    -- some of these natives are client-only on a server build; each one is optional so a missing one cannot abort the spawn
    pcall(SetVehicleDoorsLocked, veh, 10)
    if SetVehicleEngineOn then pcall(SetVehicleEngineOn, veh, false, true, true) end
    if SetVehicleUndriveable then pcall(SetVehicleUndriveable, veh, true) end
    pcall(FreezeEntityPosition, veh, true)
    pcall(SetEntityInvincible, veh, true)
    return veh
end

-- Builds one saved entry (a stack is several pieces on top of each other). Returns the entities created.
function EventProps.spawnEntry(p)
    local made = {}
    local rx, ry, rz = tonumber(p.rx) or 0.0, tonumber(p.ry) or 0.0, tonumber(p.heading) or 0.0
    if p.kind == 'vehicle' or EventProps.isVehicleModel(p.model) then
        local v = spawnVehicle(p.model, p.x, p.y, p.z, rx, ry, rz)
        if v then made[#made + 1] = v end
        return made
    end
    local pieces = math.max(1, math.min(10, math.floor(tonumber(p.stack) or 1)))
    local step = tonumber(p.step) or 2.6
    for k = 0, pieces - 1 do
        local o = spawnObject(p.model, p.x, p.y, p.z + k * step, rx, ry, rz, p.collision ~= false)
        if not o then break end
        made[#made + 1] = o
    end
    return made
end

local function deleteAll(entry)
    for _, e in ipairs(entry.entities) do
        if DoesEntityExist(e) then DeleteEntity(e) end
    end
    entry.entities = {}
end

-- Every object / vehicle an event builds carries this tag (the event id). The list of remembered handles can go stale (an entity that
-- changed owner, a spawn that was still in flight when the event ended), and a vehicle left standing is very visible, so ending
-- an event also sweeps the whole world for anything still wearing the tag. Convoy checkpoint props use the same tag (convoy_runtime).
local TAG = 'nova_event_obj'
EventProps.TAG = TAG

function EventProps.tag(entities, convoyId)
    for _, e in ipairs(entities or {}) do
        if e and e ~= 0 and DoesEntityExist(e) then pcall(function() Entity(e).state:set(TAG, convoyId, true) end) end
    end
end

-- Deletes every vehicle / object in the world tagged for this event. Returns how many it removed.
function EventProps.sweep(convoyId)
    local idStr = tostring(convoyId)
    local removed = 0
    for _, getter in ipairs({ GetAllVehicles, GetAllObjects }) do
        local ok, list = pcall(getter)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                if DoesEntityExist(e) then
                    local okS, st = pcall(function() return Entity(e).state end)
                    if okS and st and st[TAG] ~= nil and tostring(st[TAG]) == idStr then
                        pcall(DeleteEntity, e)
                        removed = removed + 1
                    end
                end
            end
        end
    end
    return removed
end

function EventProps.stop(convoyId, quiet)
    -- the admins' own preview copies (local, client-side props and vehicles) go too: an ended or force-ended event must not leave any
    -- placed vehicle standing. quiet = a status change back to Draft (a reuse), where an admin may be previewing the layout on purpose.
    if not quiet then TriggerClientEvent('nova_convoytruck:client:clearPropPreviews', -1) end
    local entry = spawned[convoyId]
    if entry then
        entry.token = -1          -- a spawn loop still running notices and stops
        deleteAll(entry)
        spawned[convoyId] = nil
    end
    local removed = EventProps.sweep(convoyId)
    if removed > 0 then print(('[NovaConvoy] Event %s: swept %d leftover placed object(s) that were no longer tracked.'):format(tostring(convoyId), removed)) end
    -- a spawn that was still mid-flight when the event ended finishes a moment later: sweep again, unless the event has been started anew
    CreateThread(function()
        for _, delay in ipairs({ 2500, 10000 }) do
            Wait(delay)
            if spawned[convoyId] then return end
            EventProps.sweep(convoyId)
        end
    end)
end

-- Stable identity of one saved object inside one event: Event ID + the placer's object uid (position fallback for
-- very old saves that never had one).
local function objectKey(convoyId, p)
    local id = p.uid
    if not id or id == '' then id = ('%s@%.2f,%.2f,%.2f'):format(tostring(p.model), tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0) end
    return ('%s:%s'):format(tostring(convoyId), id)
end

local function entriesAlive(ents)
    if not ents or #ents == 0 then return false end
    for _, e in ipairs(ents) do
        if not DoesEntityExist(e) then return false end
    end
    return true
end

-- Spawns the event's saved objects. Safe to call again: an object that is already standing (tracked by its stable
-- key and still existing) is REUSED, only missing ones are built. The saved configuration is never modified.
function EventProps.start(convoyId)
    local def = ConvoyManager and ConvoyManager.get(convoyId)
    -- Container Wars has no event props: its yard is the permanent harbour layout (HarbourStore). A list left on an
    -- older Container Wars event (from when the editor offered one) is ignored rather than spawned unseen.
    if def and def.kind == 'CONTAINER_WARS' then return end

    -- Wipe every client's editor / admin preview copies (Prop Spawn Mode) so they never stand next to the live
    -- event entities. Done for every event, even one with only checkpoint props (those spawn from the convoy runtime).
    TriggerClientEvent('nova_convoytruck:client:clearPropPreviews', -1)

    local list = def and def.props
    -- A Gang Airdrop random run uses only some of its zones: a zone's props stand only if that zone was picked for this run
    local activeZones = def and def._activeZoneIds
    if type(list) == 'table' and type(activeZones) == 'table' then
        local keep = {}
        for _, p in ipairs(list) do
            if not p.zoneId or activeZones[p.zoneId] then keep[#keep + 1] = p end
        end
        list = keep
    end
    if type(list) ~= 'table' or #list == 0 then return end

    local entry = spawned[convoyId]
    if not entry then
        tokenCounter = tokenCounter + 1
        entry = { token = tokenCounter, entities = {}, byKey = {} }
        spawned[convoyId] = entry
    end
    local mine = entry.token
    CreateThread(function()
        local built, reused, failed = 0, 0, {}
        for _, p in ipairs(list) do
            if entry.token ~= mine then return end
            local key = objectKey(convoyId, p)
            local have = entry.byKey[key]
            if have and entriesAlive(have) then
                reused = reused + 1
            elseif not failed[p.model] then
                local made = EventProps.spawnEntry(p)
                if #made == 0 then
                    failed[p.model] = true
                    print(('[NovaConvoy] Event %s: prop %s (model "%s" @ %s, %s, %s) could not be created — skipped.'):format(tostring(convoyId), key, tostring(p.model), tostring(p.x), tostring(p.y), tostring(p.z)))
                else
                    entry.byKey[key] = made
                    for _, e in ipairs(made) do
                        if entry.token ~= mine then
                            if DoesEntityExist(e) then DeleteEntity(e) end
                        else
                            entry.entities[#entry.entities + 1] = e
                            built = built + 1
                            EventProps.tag({ e }, convoyId)
                        end
                    end
                end
            end
        end
        if entry.token == mine and (built > 0 or reused > 0) then
            print(('[NovaConvoy] Event %s: %d prop(s) placed, %d already standing (reused)'):format(tostring(convoyId), built, reused))
        end
    end)
end

-- called by ConvoyManager.setStatus
function EventProps.onStatus(convoyId, status)
    if status == 'ACTIVE' then
        EventProps.start(convoyId)
    elseif status == 'COMPLETED' or status == 'CAPTURED' or status == 'FAILED' or status == 'CANCELLED' then
        EventProps.stop(convoyId)
    elseif status == 'DRAFT' then
        EventProps.stop(convoyId, true)
    end
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(spawned) do EventProps.stop(id) end
end)

-- /propplacer (client/modules/prop_placer.lua) is for people who may use the tablet
lib.callback.register('nova_convoytruck:propPlacer:access', function(source)
    return UserPermissions.canAny(source, 'create.edit', 'worldpeds.edit', 'worldpeds.create') == true
end)
