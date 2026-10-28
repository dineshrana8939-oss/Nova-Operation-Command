-- ─── Convoy route debug (admin) ────────────────────────────────────────────────────
-- /convoydebug            show the running convoy's route and where each truck is on it (run it again to hide)
-- /convoydebug off        hide it
-- /convoydebug <id>       watch a specific convoy
--
-- The admin sees, in the world: the route as lines between its points (grey = already passed, yellow = being driven now,
-- cyan = still ahead), each point numbered and typed, every truck with the point it is heading for, how far it is from the
-- route line, the path it actually drove (a trail), and a one-line diagnosis of why it is or is not moving. The server also
-- prints a summary line per truck to the console every 15 s while someone is watching, and a warning when a truck stands
-- still without a good reason — that is the "confirm the trucks follow the lines" check.
--
-- Everything here only READS the running convoy (Runtime.get); it never changes how a truck drives.

ConvoyDebug = {}

local watchers = {}   -- [src] = { convoyId = nil | number }
local stats = {}      -- [convoyId] = { [truckId] = { ticks, onRoute, maxOff, stoppedSince, lastWarn } }
local lastSummary = 0
local vitalsBy = {}  -- [src] = { [truckId] = 'engine ... ' } what the watching client reads off each truck

RegisterNetEvent('nova_convoytruck:debug:vitals', function(report)
    local src = source
    if not watchers[src] or type(report) ~= 'table' then return end
    vitalsBy[src] = report
end)

-- the watching admin's client compared the route with the game's road network: print what it found (only when it changes)
RegisterNetEvent('nova_convoytruck:debug:roadcheck', function(lines)
    local src = source
    if not watchers[src] or type(lines) ~= 'table' then return end
    if #lines == 0 then
        print('^2[ConvoyDebug] road check: every checked route point sits on a road and neighbouring points are joined by road^0')
        return
    end
    print('^1[ConvoyDebug] road check - the game cannot drive these parts of the route:^0')
    for i = 1, math.min(#lines, 30) do print(('^1[ConvoyDebug]   %s^0'):format(tostring(lines[i]))) end
end)

local function vitalsFor(truckId)
    for _, rep in pairs(vitalsBy) do
        if rep[tostring(truckId)] then return rep[tostring(truckId)] end
    end
    return nil
end

local function cfg() return Config.ConvoyDebug or {} end
local function offRouteLimit() return tonumber(cfg().onRouteMeters) or 30.0 end

local function isAdmin(src)
    return Bridge.IsAdmin(src, Config.CreatorAccess and Config.CreatorAccess.adminPermission)
end

local function notify(src, text, kind)
    TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { title = 'Convoy debug', description = text, type = kind or 'inform', duration = 6000 })
end

-- 2D distance from a point to the segment a-b, plus the nearest point on it
local function distToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = 0.0
    if l2 > 0.0 then t = math.max(0.0, math.min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2)) end
    local cx, cy = ax + t * dx, ay + t * dy
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2), cx, cy
end

-- nearest point of the whole drawn route to (px, py): distance, point, and which segment (i -> i+1)
local function distToRoute(route, px, py)
    local best, bx, by, bseg = math.huge, px, py, 1
    for i = 1, #route - 1 do
        local a, b = route[i], route[i + 1]
        local d, cx, cy = distToSegment(px, py, a.x, a.y, b.x, b.y)
        if d < best then best, bx, by, bseg = d, cx, cy, i end
    end
    return best, bx, by, bseg
end

-- The running convoy a watcher means: the one they asked for, else the first running one that has a route and trucks.
local function convoyFor(w)
    if w.convoyId then
        local rt = Runtime.get(w.convoyId)
        if rt and type(rt.route) == 'table' and #rt.route > 0 then return rt end
        return nil
    end
    for _, id in ipairs(Runtime.getActive()) do
        local rt = Runtime.get(id)
        if rt and type(rt.route) == 'table' and #rt.route > 1 and next(rt.trucks or {}) then return rt end
    end
    return nil
end

local function routePayload(rt)
    local pts = {}
    for i, p in ipairs(rt.route) do
        pts[i] = { i = i, id = tostring(p.id), type = p.type, x = p.x + 0.0, y = p.y + 0.0, z = (p.z or 0.0) + 0.0, name = p.name or p.label }
    end
    return {
        id = rt.id, name = rt.def and rt.def.name or ('Convoy ' .. tostring(rt.id)), points = pts,
        reach = Runtime.GENERIC_REACH_RADIUS or 35.0, onRoute = offRouteLimit(),
    }
end

-- Why is this truck (not) moving? One short sentence — the first thing that applies.
local function diagnose(rt, t, exists, speed, owner, frozen, distToTarget)
    if rt.releaseHeld then return 'HELD at the start (release pending)', 'warn' end
    if rt.escortHalted then return 'HALTED: no police escort within range (convoy paused)', 'warn' end
    if t.delivered then return 'DELIVERED', 'ok' end
    if t.destroyed then return 'DESTROYED', 'bad' end
    if t.captured then return 'CAPTURED', 'warn' end
    if not exists then return 'TRUCK ENTITY MISSING (despawned / culled)', 'bad' end
    if t.state == 'DISABLED' or t.disabled or t.brokenDown then return 'DISABLED (engine / health)', 'warn' end
    if t.checkpointParked then return 'PARKED at a checkpoint', 'ok' end
    if rt.status == 'CHECKPOINT' or rt.pointInProgress then return 'checkpoint / stop in progress', 'ok' end
    if not t.driverPed or not DoesEntityExist(t.driverPed) then return 'NO DRIVER (ped missing)', 'bad' end
    if owner == -1 then
        if rt.def and rt.def.settings and rt.def.settings.requireEscortProximity == false and (Config.TruckScriptMoves == true or Config.TruckAdvanceUnobserved == true) then
            return 'no player near it - the server is sliding it along its route (Require Police Escort Proximity is OFF)', 'warn'
        end
        return 'NOBODY SIMULATES THIS TRUCK (no player within ' .. tostring(Config.TruckCullingRadius or 1500) .. ' m, any player, not only police: its AI cannot drive. Turn OFF "Require Police Escort Proximity" on this convoy AND set Config.TruckAdvanceUnobserved = true to let the server advance it)', 'bad'
    end
    if frozen then return 'FROZEN in place', 'bad' end
    if speed < 0.6 and distToTarget and distToTarget > 10.0 then return 'STOPPED but not at its target (blocked / no road path)', 'bad' end
    if speed < 0.6 then return 'standing at its target', 'ok' end
    return 'DRIVING', 'ok'
end

local function truckSnapshot(rt, t, route)
    local ent = t.entity
    local exists = ent and DoesEntityExist(ent) or false
    local c = (exists and GetEntityCoords(ent)) or (t.lastCoords and vec3(t.lastCoords.x, t.lastCoords.y, t.lastCoords.z or 0.0)) or vec3(0.0, 0.0, 0.0)
    local speed = exists and GetEntitySpeed(ent) or 0.0
    local owner = exists and NetworkGetEntityOwner(ent) or -1
    local frozen = false
    if exists and type(IsEntityPositionFrozen) == 'function' then
        local ok, v = pcall(IsEntityPositionFrozen, ent)
        frozen = ok and v == true
    end
    local idx = t.routeIdx or 1
    local target = route[idx]
    local distToTarget = target and math.sqrt((c.x - target.x) ^ 2 + (c.y - target.y) ^ 2) or nil
    local off, nx, ny = distToRoute(route, c.x, c.y)
    local text, tone = diagnose(rt, t, exists, speed, owner, frozen, distToTarget)
    -- near the destination: say how far it is and what stands between the truck and its delivery
    local dest
    for i = #route, 1, -1 do
        if route[i].type == 'DESTINATION' then dest = route[i] break end
    end
    if dest and exists and not t.delivered and not t.destroyed and not t.captured then
        local dd = math.sqrt((c.x - dest.x) ^ 2 + (c.y - dest.y) ^ 2)
        if dd <= 400.0 then
            local why
            if rt.status == 'DELIVERY' then why = 'delivery zone is active'
            elseif rt.escortHalted then why = 'convoy HALTED (no police escort near) - delivery waits'
            elseif rt.status == 'CHECKPOINT' then why = 'event still in CHECKPOINT status (waiting for the other trucks at a checkpoint)'
            elseif rt.pointInProgress then why = 'a stop is in progress'
            else why = 'event status ' .. tostring(rt.status) end
            text = ('%s  | %d m from the destination: %s. Delivered inside %d m, or inside %d m once slow, or after %d s still inside %d m'):format(
                text, math.floor(dd), why, math.floor(math.max(tonumber(Config.DeliveryRadius) or 20.0, 12.0)),
                math.floor(tonumber(Config.DeliveryNearRadius) or 45.0), tonumber(Config.DeliveryStallSeconds) or 8,
                math.floor(tonumber(Config.DeliveryStallRadius) or 70.0))
        end
    end
    return {
        id = t.id, role = t.role, netId = t.netId,
        label = (exists and Entity(ent).state.convoy_truck_label) or tostring(t.role),
        x = c.x, y = c.y, z = c.z, speed = speed, owner = owner,
        idx = idx, driveIdx = t.drivingToIndex, off = off, nx = nx, ny = ny,
        distToTarget = distToTarget, diag = text, tone = tone,
        hasState = exists and (Entity(ent).state.convoy_target ~= nil) or false,
        taskAge = t.lastDriveTaskTime and (os.time() - t.lastDriveTaskTime) or nil,
        parked = t.checkpointParked == true,
    }, off
end

local function record(rt, snap, off)
    local per = stats[rt.id]
    if not per then per = {}; stats[rt.id] = per end
    local s = per[snap.id]
    if not s then s = { ticks = 0, onRoute = 0, maxOff = 0.0 }; per[snap.id] = s end
    -- only a truck that is actually meant to be driving counts toward the on-route score
    local counts = snap.tone == 'ok' and snap.diag == 'DRIVING' or snap.diag:find('STOPPED') ~= nil
    if counts then
        s.ticks = s.ticks + 1
        if off <= offRouteLimit() then s.onRoute = s.onRoute + 1 end
        if off > s.maxOff then s.maxOff = off end
    end
    -- a stand-still without a good reason: say so in the console (not more than once per 20 s per truck)
    if snap.diag:find('STOPPED') or snap.diag:find('NOBODY') or snap.diag:find('NO DRIVER') or snap.diag:find('FROZEN') then
        s.stoppedSince = s.stoppedSince or os.time()
        if os.time() - s.stoppedSince >= 10 and os.time() - (s.lastWarn or 0) >= 20 then
            s.lastWarn = os.time()
            print(('^3[ConvoyDebug] #%s "%s" %s (%s) has not moved for %ds: %s | route point %d/%d, %.0f m to it, %.0f m from the route line, owner=%s | %s^0'):format(
                tostring(rt.id), rt.def and rt.def.name or '?', snap.label, tostring(snap.id), os.time() - s.stoppedSince, snap.diag,
                snap.idx, #rt.route, snap.distToTarget or -1, off, snap.owner == -1 and 'nobody' or tostring(snap.owner), vitalsFor(snap.id) or 'truck readings: not streamed to the watching client'))
        end
    else
        s.stoppedSince = nil
    end
    snap.ticks, snap.onPct = s.ticks, (s.ticks > 0) and math.floor(s.onRoute * 100 / s.ticks) or nil
    snap.maxOff = s.maxOff
end

local function push(src, w)
    local rt = convoyFor(w)
    if not rt then
        if w.sentRoute then TriggerClientEvent('nova_convoytruck:debug:none', src) w.sentRoute = nil end
        return
    end
    if w.sentRoute ~= rt.id then
        TriggerClientEvent('nova_convoytruck:debug:route', src, routePayload(rt))
        w.sentRoute = rt.id
    end
    local trucks = {}
    for _, t in pairs(rt.trucks or {}) do
        local snap, off = truckSnapshot(rt, t, rt.route)
        record(rt, snap, off)
        trucks[#trucks + 1] = snap
    end
    table.sort(trucks, function(a, b) return tostring(a.id) < tostring(b.id) end)
    TriggerClientEvent('nova_convoytruck:debug:state', src, {
        id = rt.id, status = rt.status, current = rt.currentRouteIndex, total = #rt.route,
        held = rt.releaseHeld == true, halted = rt.escortHalted == true, busy = rt.pointInProgress == true, trucks = trucks,
    })
end

CreateThread(function()
    while true do
        Wait(next(watchers) and 1000 or 4000)
        if next(watchers) then
            for src, w in pairs(watchers) do
                if not GetPlayerName(src) then
                    watchers[src] = nil
                else
                    local ok, err = pcall(push, src, w)
                    if not ok then print(('^1[ConvoyDebug] snapshot failed: %s^0'):format(tostring(err))) end
                end
            end
            -- console summary: the on-route score of every truck, every 15 s
            if os.time() - lastSummary >= 15 then
                lastSummary = os.time()
                for convoyId, per in pairs(stats) do
                    local rt = Runtime.get(convoyId)
                    if rt then
                        for truckId, s in pairs(per) do
                            if s.ticks > 0 then
                                print(('[ConvoyDebug] #%s truck %s: on the route line %d%% of the time (limit %dm), furthest off %.0fm, route point %d/%d'):format(
                                    tostring(convoyId), tostring(truckId), math.floor(s.onRoute * 100 / s.ticks), offRouteLimit(), s.maxOff,
                                    (rt.trucks[truckId] and rt.trucks[truckId].routeIdx) or 0, #rt.route))
                            end
                        end
                    else
                        stats[convoyId] = nil
                    end
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function() watchers[source] = nil; vitalsBy[source] = nil end)

local cmd = cfg().command
if cmd == nil then cmd = 'convoydebug' end
if type(cmd) == 'string' and cmd ~= '' then
    RegisterCommand(cmd, function(source, args)
        if source == 0 then print(('[NovaConvoy] /%s is used in game.'):format(cmd)) return end
        if not isAdmin(source) then notify(source, 'Admins only.', 'error') return end
        local a = tostring(args[1] or ''):lower()
        -- /convoydebug physics on|off: the heavy-truck handling (extra mass / gravity) for every convoy truck, live
        if a == 'physics' then
            local mode = tostring(args[2] or ''):lower()
            if mode ~= 'on' and mode ~= 'off' then notify(source, ('Use /%s physics on  or  /%s physics off'):format(cmd, cmd), 'error') return end
            TriggerClientEvent('nova_convoytruck:debug:physics', -1, mode == 'on')
            print(('^3[ConvoyDebug] heavy truck physics switched %s by %s^0'):format(mode:upper(), GetPlayerName(source) or tostring(source)))
            return
        end
        if a == 'off' or (a == '' and watchers[source]) then
            watchers[source] = nil
            TriggerClientEvent('nova_convoytruck:debug:off', source)
            notify(source, 'Route debug is off.')
            return
        end
        local id = tonumber(a)
        watchers[source] = { convoyId = id }
        local rt = convoyFor(watchers[source])
        if rt then
            stats[rt.id] = nil   -- a fresh on-route score from now on
            notify(source, ('Showing the route of "%s" (#%s). Run /%s again to hide it.'):format(rt.def and rt.def.name or '?', tostring(rt.id), cmd), 'success')
        else
            notify(source, 'No convoy with a route is running right now. It will show as soon as one starts.', 'warning')
        end
        pcall(push, source, watchers[source])
    end, false)
end

return ConvoyDebug
