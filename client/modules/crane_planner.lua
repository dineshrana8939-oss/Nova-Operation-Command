-- ─── Crane route planner (client) ──────────────────────────────────────────────────
-- "Plan route" in the Container Wars tablet: the game scans the REAL yard around one container's pickup and drop
-- spots (the map's own container stacks, other cranes, walls — everything the server cannot see), finds a clear lane
-- for the container, and hands the waypoints back. The tablet saves them with the harbour (data/harbour.json) and the
-- server then carries that container along them, leaving the way it is facing, bending like a car, and arriving along
-- the drop heading (see CWGantry.splinePath / CWGantry.findRoute in shared/gantry.lua).
--
-- How: from above, a ray in every cell of a grid reports the height of the tallest thing there; the container is
-- carried at the crane's carrying height, so every cell with something taller is blocked. Parts of the gantry itself
-- (frame, cabin, wheels, hook) are ignored by the scan. The player must be near the spot so its collision is loaded —
-- the tablet teleports them there first.

local planning = false

local function cfg()
    return (Config.ContainerWars and Config.ContainerWars.defaults) or {}
end

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

-- the models that belong to the gantry (the scan looks straight through them)
local function gantryModels(H)
    local set = {}
    local function add(name) if type(name) == 'string' and name ~= '' then set[joaat(name)] = true end end
    add(H.crane and H.crane.model)
    local g = H.crane and CWGantry.get(H.crane.model)
    if g then
        add(g.cabin and g.cabin.model)
        add(g.wheels and g.wheels.model)
    end
    for _, part in ipairs(((Config.ContainerWars or {}).hook or {}).parts or {}) do add(part.model) end
    return set
end

-- height of the tallest thing at x, y (not counting the gantry), looking down from `top`
local function surfaceHeight(x, y, top, bottom, ignore)
    local sx, sy, sz = x, y, top
    for _ = 1, 5 do
        local h = StartExpensiveSynchronousShapeTestLosProbe(sx, sy, sz, x, y, bottom, 1 + 16 + 256, 0, 4)
        local _, hit, pos, _, ent = GetShapeTestResult(h)
        if hit ~= 1 then return nil end
        local isGantry = false
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local ok, model = pcall(GetEntityModel, ent)
            isGantry = ok and ignore[model] == true
        end
        if not isGantry then return pos.z end
        sz = pos.z - 0.1
    end
    return nil
end

RegisterNUICallback('planCraneCarry', function(data, cb)
    if planning then cb({ ok = false, error = 'busy' }) return end
    data = data or {}
    local H = (Config.ContainerWars and Config.ContainerWars.harbour) or {}
    local idx = math.max(1, math.floor(tonumber(data.index) or 1))
    local pick = H.pickups and H.pickups[idx]
    local drop = (H.drops and H.drops[idx]) or H.drop
    if not (pick and drop and tonumber(pick.x) and tonumber(drop.x)) then
        cb({ ok = false, error = 'missing_positions' })
        return
    end

    planning = true
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    CreateThread(function()
        local result
        local okRun, err = pcall(function()
            local d = cfg()
            local lift = tonumber(data.liftHeight) or tonumber(d.craneLiftHeight) or 12.0
            -- planned for the crane that will actually carry this container (one per aisle)
            local cranes = CWGantry.resolveCranes(H, #(H.pickups or {}))
            local crane = cranes[CWGantry.craneFor(cranes, pick, drop) or 1]
            local g = crane and CWGantry.get(crane.model)
            local dropZ = tonumber(drop.z) + (tonumber(H.dropZOffset) or 0.0)
            local carryZ = CWGantry.carryHeight(g, crane, tonumber(pick.z), dropZ, lift)

            -- the area: both spots and a margin round them
            local pad = 35.0
            local minX, maxX = math.min(pick.x, drop.x) - pad, math.max(pick.x, drop.x) + pad
            local minY, maxY = math.min(pick.y, drop.y) - pad, math.max(pick.y, drop.y) + pad
            local cell = 2.0
            while ((maxX - minX) / cell) * ((maxY - minY) / cell) > 7500.0 do cell = cell + 0.5 end
            local nx, ny = math.max(1, math.ceil((maxX - minX) / cell)), math.max(1, math.ceil((maxY - minY) / cell))
            local top = math.max(pick.z, drop.z) + 70.0
            local bottom = math.min(pick.z, drop.z) - 40.0

            -- let the area's collision stream in before scanning it
            local cx, cy = (minX + maxX) / 2.0, (minY + maxY) / 2.0
            SetFocusPosAndVel(cx, cy, carryZ, 0.0, 0.0, 0.0)
            local ignore = gantryModels(H)
            local t0 = GetGameTimer()
            while GetGameTimer() - t0 < 2500 do
                RequestCollisionAtCoord(cx, cy, carryZ)
                RequestCollisionAtCoord(pick.x, pick.y, pick.z)
                RequestCollisionAtCoord(drop.x, drop.y, drop.z)
                Wait(100)
            end

            local heights, misses, total = {}, 0, 0
            local scanned = 0
            for j = 0, ny - 1 do
                local y = minY + (j + 0.5) * cell
                for i = 0, nx - 1 do
                    local x = minX + (i + 0.5) * cell
                    if (i % 8) == 0 then RequestCollisionAtCoord(x, y, carryZ) end
                    local z = surfaceHeight(x, y, top, bottom, ignore)
                    heights[j * nx + i + 1] = z
                    total = total + 1
                    if not z then misses = misses + 1 end
                    scanned = scanned + 1
                    if scanned % 120 == 0 then
                        lib.showTextUI(('**PLANNING CRANE ROUTE**  \nScanning the yard… %d%%'):format(math.floor(scanned * 100 / (nx * ny))), { position = 'right-center' })
                        Wait(0)
                    end
                end
            end
            if misses > total * 0.6 then
                result = { ok = false, error = 'collision_not_loaded' }
                return
            end

            local function heightAt(x, y)
                local i, j = math.floor((x - minX) / cell), math.floor((y - minY) / cell)
                if i < 0 or j < 0 or i >= nx or j >= ny then return nil end
                return heights[j * nx + i + 1]
            end

            lib.showTextUI('**PLANNING CRANE ROUTE**  \nFinding a clear lane…', { position = 'right-center' })
            Wait(0)
            local route = CWGantry.findRoute({
                heightAt = heightAt, minX = minX, minY = minY, maxX = maxX, maxY = maxY, cell = cell,
                carryZ = carryZ, margin = 1.0,
                pick = { x = pick.x, y = pick.y, h = tonumber(pick.heading) or 0.0 },
                drop = { x = drop.x, y = drop.y, h = tonumber(drop.heading) or 0.0 },
                size = d.containerSize or { length = 12.2, width = 2.6 },
                gantry = g, crane = crane,
            })
            if not route then
                result = { ok = false, error = 'no_route' }
                return
            end
            local pts = {}
            for _, p in ipairs(route.points) do pts[#pts + 1] = { x = round2(p.x), y = round2(p.y) } end
            result = {
                ok = true, index = idx, points = pts, violations = route.violations, inflation = route.inflation,
                carryZ = carryZ, pick = { x = round2(pick.x), y = round2(pick.y) }, drop = { x = round2(drop.x), y = round2(drop.y) },
            }
        end)
        lib.hideTextUI()
        ClearFocus()
        planning = false
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
        if not okRun then
            print(('[nova_convoytruck] crane route planner error: %s'):format(tostring(err)))
            cb({ ok = false, error = 'plan_failed' })
        else
            cb(result or { ok = false, error = 'plan_failed' })
        end
    end)
end)
