-- ─── Convoy route debug (client) ───────────────────────────────────────────────────
-- Drawn only for an admin who ran /convoydebug (see server/modules/convoy_debug.lua, which sends the route and a
-- snapshot of every truck once a second). This file only DRAWS; it never touches a truck.
--
--   route lines     between consecutive route points: grey = passed by every truck, yellow = being driven now,
--                   cyan = still ahead. Every point has a post and a "#number TYPE" tag.
--   target ring     the arrival radius of the point a truck is heading for (a point counts as reached inside it)
--   trucks          a white line to the route point it is driving to, a coloured line to the nearest point of the drawn
--                   route (green = on the line, yellow = a bit off, red = off it), a blue trail of where it really drove,
--                   and two tags: what it is and how far it is from the route, then why it is / is not moving
--   screen list     the same, as text, with an "on the line X% of the time" score per truck

local route = nil          -- { id, name, points = { {i,id,type,x,y,z,name}... }, reach, onRoute }
local state = nil          -- the latest snapshot
local on = false
local drawing = false
local trails = {}          -- [truckId] = { {x, y, z}, ... }
local TRAIL_MAX = 150

local TYPE_COLOR = {
    START = { 60, 220, 120 }, ROUTE = { 235, 235, 240 }, CHECKPOINT = { 255, 150, 40 }, DESTINATION = { 255, 70, 70 },
    NPC_SPAWN = { 190, 110, 255 }, BREAK = { 90, 160, 255 }, AMBUSH = { 255, 80, 200 },
}
local TONE_COLOR = { ok = { 90, 230, 140 }, warn = { 255, 205, 70 }, bad = { 255, 90, 80 } }

-- ── geometry ─────────────────────────────────────────────────────────────────────

local function distToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = 0.0
    if l2 > 0.0 then t = math.max(0.0, math.min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2)) end
    local cx, cy = ax + t * dx, ay + t * dy
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2), cx, cy
end

local function distToRoute(px, py)
    local pts = route.points
    local best, bx, by = math.huge, px, py
    for i = 1, #pts - 1 do
        local d, cx, cy = distToSegment(px, py, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
        if d < best then best, bx, by = d, cx, cy end
    end
    return best, bx, by
end

-- a truck's position: the real entity when this client has it streamed in (smooth), else the server's last snapshot
local function truckPos(s)
    if s.netId and NetworkDoesNetworkIdExist(s.netId) then
        local ent = NetToVeh(s.netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local c = GetEntityCoords(ent)
            return c.x, c.y, c.z, ent
        end
    end
    return s.x, s.y, s.z, nil
end

-- ── what the truck itself is doing (only for a truck this client has streamed in) ──
-- engine / revs / gear / wheel speed tell "wheels spinning but not moving" (stuck or dragged down) from "engine off" or "no throttle"
-- (nobody is driving it); the driver task says whether the AI still has a go-to order at all.
local vitals = {}   -- [truckId] = { ... }

local TASK_TEXT = { [0] = 'performing', [1] = 'waiting to start', [2] = 'dormant', [7] = 'NONE (no drive order)' }

local function readVitals(s)
    local _, _, _, ent = truckPos(s)
    if not ent then return nil end
    local driver = GetPedInVehicleSeat(ent, -1)
    local hasDriver = driver ~= 0 and DoesEntityExist(driver)
    local task = hasDriver and GetScriptTaskStatus(driver, joaat('SCRIPT_TASK_VEHICLE_DRIVE_TO_COORD_LONGRANGE')) or nil
    return {
        engine = GetIsVehicleEngineRunning(ent), eh = math.floor(GetVehicleEngineHealth(ent)),
        rpm = GetVehicleCurrentRpm(ent), gear = GetVehicleCurrentGear(ent), wheel = GetVehicleWheelSpeed(ent, 0),
        wheels = IsVehicleOnAllWheels(ent), ctrl = NetworkHasControlOfEntity(ent),
        pedCtrl = hasDriver and NetworkHasControlOfEntity(driver) or false, driver = hasDriver,
        task = task, light = IsVehicleStoppedAtTrafficLights(ent), air = GetEntityHeightAboveGround(ent),
        keeper = ConvoyKeeper and ConvoyKeeper[ent] and ConvoyKeeper[ent].note or nil,
        aim = ConvoySnap and ConvoySnap[ent] or nil,
        brake = GetVehicleHandbrake(ent),
        tgt = (function() local t = Entity(ent).state.convoy_target; if not t then return nil end; local p = GetEntityCoords(ent); return #(p - vector3(t.x, t.y, t.z)) end)(),
    }
end

local function vitalsText(v)
    if not v then return 'not streamed to this client (too far away to read)' end
    return ('engine %s %d  rpm %.2f  gear %d  wheel %.1f m/s  all-wheels %s  at-light %s  handbrake %s  | driver %s  drive order: %s  control: vehicle %s / driver %s  | %s to its target  | aim: %s  | keeper: %s'):format(
        v.engine and 'ON' or 'OFF', v.eh or 0, v.rpm or 0, v.gear or 0, v.wheel or 0, v.wheels and 'yes' or 'NO', v.light and 'YES' or 'no', v.brake and 'ON' or 'off',
        v.driver and 'yes' or 'NO', TASK_TEXT[v.task] or tostring(v.task), v.ctrl and 'mine' or 'other', v.pedCtrl and 'mine' or 'other',
        v.tgt and (math.floor(v.tgt) .. ' m') or 'no target', v.aim or 'n/a', v.keeper or 'idle')
end

-- ── does the game's road network reach the route? ──────────────────────────────────
-- A truck's drive order only works along the road node network. For every route point this finds the nearest road node
-- (how far the point is from a drivable road), and for every pair of neighbouring points asks the game for the road
-- travel distance between them (the game answers 100000 when no road path exists, and a long detour when the roads only
-- connect the long way round - another carriageway, a one-way ramp, a gap in the nodes). Only checked within 700 m of
-- the admin: the node data is not loaded further away, and an unloaded area would look like "no road".
local roadInfo = {}          -- [i] = { node = vector3|nil, nodeDist, travel, straight, checked }
local roadLines = {}         -- text findings, also sent to the server console
local lastRoadCheck, lastRoadSent = 0, ''
local ROAD_RANGE = 700.0

local function checkRoad()
    if not route then return end
    local pts = route.points
    local me = GetEntityCoords(PlayerPedId())
    local lines = {}
    for i, p in ipairs(pts) do
        local info = { checked = false }
        roadInfo[i] = info
        local pv = vector3(p.x, p.y, p.z)
        if #(pv - me) <= ROAD_RANGE then
            info.checked = true
            local found, npos = GetClosestVehicleNodeWithHeading(p.x, p.y, p.z, 1, 3.0, 0)
            if found then
                info.node = npos
                info.nodeDist = #(pv - npos)
                if info.nodeDist > 15.0 then
                    lines[#lines + 1] = ('#%d %s: nearest road is %d m away - the point is OFF the road'):format(i, tostring(p.type), math.floor(info.nodeDist))
                end
            else
                lines[#lines + 1] = ('#%d %s: no road node found near it at all'):format(i, tostring(p.type))
            end
            local q = pts[i + 1]
            if q and #(vector3(q.x, q.y, q.z) - me) <= ROAD_RANGE then
                local travel = CalculateTravelDistanceBetweenPoints(p.x, p.y, p.z, q.x, q.y, q.z)
                local straight = #(pv - vector3(q.x, q.y, q.z))
                info.travel, info.straight = travel, straight
                if travel >= 99999.0 then
                    lines[#lines + 1] = ('#%d -> #%d: NO road path between them (%d m apart)'):format(i, i + 1, math.floor(straight))
                elseif travel > straight * 2.5 and travel - straight > 100.0 then
                    lines[#lines + 1] = ('#%d -> #%d: roads only join them the long way (%d m by road for %d m straight)'):format(i, i + 1, math.floor(travel), math.floor(straight))
                end
            end
        end
    end
    roadLines = lines
    local joined = table.concat(lines, '\n')
    if joined ~= lastRoadSent then
        lastRoadSent = joined
        TriggerServerEvent('nova_convoytruck:debug:roadcheck', lines)
    end
end

-- ── screen text ──────────────────────────────────────────────────────────────────

local function hudText(x, y, text, r, g, b, scale)
    SetTextFont(4)
    SetTextScale(scale or 0.32, scale or 0.32)
    SetTextColour(r or 255, g or 255, b or 255, 255)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

-- Compact panel: a narrow card in the top-left corner. One header, one summary line, then ONE line per truck (+ one line saying
-- why when it is not simply driving). The long engine / rpm / drive-order readout only shows for a truck with a problem, or for all
-- trucks after /convoydebugmore (it is the same text that goes to the server console).
local showMore = false
local HUD_W, HUD_TOP = 0.215, 0.12
local HUD_X = 0.992 - HUD_W          -- right edge of the screen
local LINE_H, TEXT_SCALE = 0.0158, 0.24
local MAX_CHARS = 50

local function clip(text, n)
    text = tostring(text or '')
    n = n or MAX_CHARS
    if #text <= n then return text end
    return text:sub(1, n - 1) .. '…'
end

local function drawHud()
    local lines = {}
    local function add(text, r, g, b, tail)
        lines[#lines + 1] = { text = clip(text), r = r or 235, g = g or 238, b = b or 245, tail = tail }
    end
    local dim = { 150, 162, 182 }

    add(('CONVOY DEBUG  #%s  %s'):format(tostring(route.id), tostring(route.name)), 255, 255, 255)
    if state then
        local flags = {}
        if state.held then flags[#flags + 1] = 'HELD' end
        if state.halted then flags[#flags + 1] = 'ESCORT HALT' end
        if state.busy then flags[#flags + 1] = 'at a stop' end
        local onLine, drivingN = 0, 0
        for _, s in ipairs(state.trucks or {}) do
            local off = distToRoute(s.x, s.y)
            if s.diag == 'DRIVING' or tostring(s.diag):find('STOPPED') then
                drivingN = drivingN + 1
                if off <= route.onRoute then onLine = onLine + 1 end
            end
        end
        add(('%s · pt %s/%s · %d/%d on line%s'):format(tostring(state.status), tostring(state.current), tostring(state.total), onLine, drivingN,
            #flags > 0 and (' · ' .. table.concat(flags, ',')) or ''), (state.held or state.halted) and 255 or 200, (state.held or state.halted) and 205 or 210, (state.held or state.halted) and 70 or 225)

        for _, s in ipairs(state.trucks or {}) do
            local col = TONE_COLOR[s.tone] or TONE_COLOR.ok
            local off = math.floor((distToRoute(s.x, s.y)))
            add(('%s  %d  %dkm/h  off %dm'):format(tostring(s.label), s.idx or 0, math.floor((s.speed or 0) * 3.6), off), 255, 255, 255)
            if s.tone ~= 'ok' or (s.diag ~= 'DRIVING') then
                add('  ' .. tostring(s.diag), col[1], col[2], col[3])
            end
            local v = vitals[s.id]
            if v and (showMore or s.tone ~= 'ok') then
                -- one short line: the things that tell "nobody is driving" from "stuck"
                add(('  eng %s  rpm %.1f  g%d  wheel %.0f  ord %s  tgt %s'):format(
                    v.engine and 'on' or 'OFF', v.rpm or 0, v.gear or 0, v.wheel or 0,
                    (v.task == 0 or v.task == 1) and 'yes' or 'NONE', v.tgt and (math.floor(v.tgt) .. 'm') or '-'), dim[1], dim[2], dim[3])
                if showMore then
                    for part in (vitalsText(v) .. ' | '):gmatch('(.-)%s*|%s') do add('  ' .. part, 120, 132, 150) end
                end
            end
        end
    else
        add('waiting for the first update ...', 200, 210, 220)
    end

    if #roadLines == 0 then
        add('roads OK', 120, 220, 150)
    else
        add(('roads: %d problem%s (see labels / console)'):format(#roadLines, #roadLines == 1 and '' or 's'), 255, 120, 100)
        if showMore then for i = 1, math.min(#roadLines, 4) do add('  ' .. roadLines[i], 255, 150, 120) end end
    end

    local h = #lines * LINE_H + 0.012
    DrawRect(HUD_X + HUD_W * 0.5, HUD_TOP + h * 0.5 - 0.004, HUD_W, h, 8, 10, 16, 140)
    DrawRect(HUD_X + 0.0018, HUD_TOP + h * 0.5 - 0.004, 0.0035, h, 80, 160, 255, 230)   -- thin accent edge
    for i, l in ipairs(lines) do
        hudText(HUD_X + 0.008, HUD_TOP + (i - 1) * LINE_H, l.text, l.r, l.g, l.b, TEXT_SCALE)
    end
end

RegisterCommand('convoydebugmore', function()
    showMore = not showMore
    print(('[NovaConvoy] convoy debug detail: %s'):format(showMore and 'FULL' or 'compact'))
end, false)

-- ── world drawing ────────────────────────────────────────────────────────────────

local function drawRing(x, y, z, radius, r, g, b)
    local steps = 28
    local px, py = x + radius, y
    for k = 1, steps do
        local a = (k / steps) * math.pi * 2.0
        local nx, ny = x + math.cos(a) * radius, y + math.sin(a) * radius
        DrawLine(px, py, z + 0.6, nx, ny, z + 0.6, r, g, b, 200)
        px, py = nx, ny
    end
end

local function drawRoute()
    local pts = route.points
    local lag, lead = math.huge, 0
    local targets = {}
    if state then
        for _, s in ipairs(state.trucks or {}) do
            if s.idx then
                lag = math.min(lag, s.idx)
                lead = math.max(lead, s.idx)
                targets[s.idx] = true
            end
        end
    end
    if lag == math.huge then lag, lead = 1, 1 end

    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local toIdx = i + 1
        local r, g, bl, al
        if toIdx < lag then r, g, bl, al = 125, 130, 145, 200
        elseif toIdx <= lead then r, g, bl, al = 255, 210, 0, 255
        else r, g, bl, al = 60, 200, 255, 235 end
        NovaDraw.line(a.x, a.y, a.z + 0.8, b.x, b.y, b.z + 0.8, r, g, bl, al, 1.4)
    end

    for i, p in ipairs(pts) do
        local c = TYPE_COLOR[p.type] or TYPE_COLOR.ROUTE
        NovaDraw.line(p.x, p.y, p.z, p.x, p.y, p.z + 5.0, c[1], c[2], c[3], 255, 1.0)
        local tag = ('#%d %s'):format(i, tostring(p.type))
        if p.name and p.name ~= '' and p.type ~= 'ROUTE' then tag = tag .. ' - ' .. tostring(p.name) end
        NovaDraw.label(p.x, p.y, p.z + 6.0, tag, c[1], c[2], c[3], { maxDist = 260.0, scale = 0.27 })
        local ri = roadInfo[i]
        if ri and ri.checked then
            local bad = (not ri.node) or ri.nodeDist > 15.0
            if ri.node and ri.nodeDist > 5.0 then
                NovaDraw.line(p.x, p.y, p.z + 0.5, ri.node.x, ri.node.y, ri.node.z + 0.5, 255, bad and 60 or 200, bad and 200 or 60, 255, 0.8)
            end
            local txt = ri.node and ('road %d m away'):format(math.floor(ri.nodeDist)) or 'NO ROAD NODE'
            NovaDraw.label(p.x, p.y, p.z + 7.6, txt, bad and 255 or 120, bad and 90 or 220, bad and 80 or 150, { maxDist = 200.0, scale = 0.22 })
            local q = pts[i + 1]
            if q and ri.travel and ri.travel >= 99999.0 then
                NovaDraw.label((p.x + q.x) / 2, (p.y + q.y) / 2, (p.z + q.z) / 2 + 3.0, 'NO ROAD PATH', 255, 70, 60, { maxDist = 300.0, scale = 0.3 })
            end
        end
        if targets[i] then
            local radius = (p.type == 'CHECKPOINT') and math.max(route.reach, 45.0) or route.reach
            drawRing(p.x, p.y, p.z, radius, c[1], c[2], c[3])
        end
    end
end

local function drawTrucks()
    if not state then return end
    local pts = route.points
    for _, s in ipairs(state.trucks or {}) do
        local x, y, z = truckPos(s)
        local tone = TONE_COLOR[s.tone] or TONE_COLOR.ok

        -- where it really drove
        local trail = trails[s.id]
        if trail then
            for k = 2, #trail do
                local p, q = trail[k - 1], trail[k]
                DrawLine(p[1], p[2], p[3] + 0.5, q[1], q[2], q[3] + 0.5, 90, 140, 255, 230)
            end
        end

        -- the route point it is driving to
        local target = pts[s.idx or 1]
        if target then NovaDraw.line(x, y, z + 1.6, target.x, target.y, target.z + 0.8, 255, 255, 255, 170, 0.5) end

        -- how far it is from the drawn route
        local off, nx, ny = distToRoute(x, y)
        local lr, lg, lb = 90, 230, 140
        if off > route.onRoute * 2.0 then lr, lg, lb = 255, 80, 70
        elseif off > route.onRoute then lr, lg, lb = 255, 205, 70 end
        if off > 1.0 then NovaDraw.line(x, y, z + 1.2, nx, ny, z + 1.2, lr, lg, lb, 255, 1.1) end

        NovaDraw.line(x, y, z + 2.5, x, y, z + 9.0, tone[1], tone[2], tone[3], 255, 1.0)
        NovaDraw.label(x, y, z + 11.0, ('%s  pt %d/%d  %d km/h  off %d m'):format(
            tostring(s.label), s.idx or 0, #pts, math.floor((s.speed or 0) * 3.6), math.floor(off)), lr, lg, lb, { maxDist = 450.0, scale = 0.27 })
        NovaDraw.label(x, y, z + 9.6, tostring(s.diag), tone[1], tone[2], tone[3], { maxDist = 450.0, scale = 0.23 })
    end
end

local function startDrawing()
    if drawing then return end
    drawing = true
    CreateThread(function()
        while on do
            Wait(0)
            if route and GetGameTimer() - lastRoadCheck > 4000 then
                lastRoadCheck = GetGameTimer()
                checkRoad()
            end
            if route then
                drawRoute()
                drawTrucks()
            end
            if route then drawHud() end
        end
        drawing = false
    end)
end

-- ── events from the server ───────────────────────────────────────────────────────

RegisterNetEvent('nova_convoytruck:debug:route', function(data)
    if type(data) ~= 'table' or type(data.points) ~= 'table' then return end
    route, state, trails = data, nil, {}
    roadInfo, roadLines, lastRoadCheck, lastRoadSent = {}, {}, 0, ''
    on = true
    startDrawing()
end)

RegisterNetEvent('nova_convoytruck:debug:state', function(data)
    if type(data) ~= 'table' then return end
    state = data
    on = true
    local report = {}
    for _, s in ipairs(data.trucks or {}) do
        local v = readVitals(s)
        vitals[s.id] = v
        if v then report[tostring(s.id)] = vitalsText(v) end
    end
    if next(report) then TriggerServerEvent('nova_convoytruck:debug:vitals', report) end
    for _, s in ipairs(data.trucks or {}) do
        local x, y, z = truckPos(s)
        local trail = trails[s.id]
        if not trail then trail = {}; trails[s.id] = trail end
        local last = trail[#trail]
        if not last or (x - last[1]) ^ 2 + (y - last[2]) ^ 2 > 4.0 then
            trail[#trail + 1] = { x, y, z }
            if #trail > TRAIL_MAX then table.remove(trail, 1) end
        end
    end
    startDrawing()
end)

-- no convoy is running (any more): drop the drawing, but stay switched on for the next one
RegisterNetEvent('nova_convoytruck:debug:none', function()
    route, state, trails = nil, nil, {}
end)

RegisterNetEvent('nova_convoytruck:debug:off', function()
    on = false
    route, state, trails = nil, nil, {}
end)
