-- ─── Gantry crane layout (shared: server + client) ─────────────────────────────
-- The moving harbour crane is built from separate props: a frame that rolls along its rails, a
-- cabin that slides across the frame, a rope and a lifter under the cabin, and wheels. Nothing is
-- animated by the game — every part is simply placed each step. This file holds the one piece of
-- maths both sides need: given where the hook has to be, where do the frame, cabin and wheels go?
--
-- Axes follow the crane's heading h:  right = (cos h, sin h)   — the rail direction (the frame rolls along it)
--                                      forward = (-sin h, cos h) — the span (the cabin slides along it)
-- Config.ContainerWars.gantries[model] describes one crane model (see config.lua).

CWGantry = {}

-- Lays a saved layout (what the tablet's hologram placers produce: { crane, pickups, drops }) over the
-- harbour table. Used by the server when it loads / saves the layout and by every client when it is synced.
function CWGantry.applyLayout(H, snap)
    if type(H) ~= 'table' or type(snap) ~= 'table' then return end
    if type(snap.carry) == 'table' then H.carry = snap.carry end
    -- every crane placed in the yard (one per aisle); H.crane stays the first of them for the code that only knows one
    if type(snap.cranes) == 'table' then
        H.cranes = snap.cranes
        H.crane = H.crane or {}
        local first = snap.cranes[1]
        for _, k in ipairs({ 'x', 'y', 'z', 'heading' }) do
            -- no crane left means none at all: the config's default spot must not come back
            H.crane[k] = first and first[k] or nil
        end
    end
    if type(snap.crane) == 'table' then
        H.crane = H.crane or {}
        if type(snap.cranes) ~= 'table' then       -- (a layout saved before there were several cranes)
            for _, k in ipairs({ 'x', 'y', 'z', 'heading' }) do
                if snap.crane[k] ~= nil then H.crane[k] = snap.crane[k] end
            end
        end
        if snap.crane.auto ~= nil then H.crane.auto = snap.crane.auto == true end
    end
    if type(snap.pickups) == 'table' then H.pickups = snap.pickups end
    if type(snap.dummies) == 'table' then H.dummies = snap.dummies end
    if type(snap.drops) == 'table' then
        H.drops = snap.drops
        -- the list is authoritative once it has been edited: no entries left means no drop spot (the single
        -- `drop` from config.lua must not come back as a hidden fallback)
        H.drop = snap.drops[1]
    end
end

-- Decides where the gantry stands so that EVERY spot (the container spots and the drop spot) is within its
-- reach, automatically. harbour = Config.ContainerWars.harbour; count = how many container spots are used.
--   · the rails run along the direction the spots are most spread out in;
--   · the frame sits in the middle of that spread, and is shifted sideways so the spots fall inside the
--     cabin's span;
--   · its base is on the ground at the drop spot's height.
-- With harbour.crane.auto = false (or no gantry for the model) the fixed x / y / z / heading of
-- harbour.crane are used as they are. Returns { x, y, z, heading, model, auto, reachable } or nil.
function CWGantry.resolveCrane(harbour, count)
    local c = harbour and harbour.crane
    if not c or not c.model then return nil end
    local g = CWGantry.get(c.model)

    local function fixed()
        if not (tonumber(c.x) and tonumber(c.y)) then return nil end
        return { x = c.x, y = c.y, z = c.z or 0.0, heading = c.heading or 0.0, model = c.model, auto = false, reachable = true }
    end
    -- with several cranes placed each stands exactly where it was put: "auto" only makes sense for a single crane
    if not (c.auto and g) or (type(harbour.cranes) == 'table' and #harbour.cranes > 1) then return fixed() end

    local pts = {}
    local n = count or #((harbour.pickups) or {})
    for i = 1, n do
        local p = harbour.pickups and harbour.pickups[i]
        if p and tonumber(p.x) and tonumber(p.y) then pts[#pts + 1] = p end
    end
    local lowest
    local drops = (harbour.drops and #harbour.drops > 0) and harbour.drops or { harbour.drop }
    for _, d in ipairs(drops) do
        if d and tonumber(d.x) and tonumber(d.y) then
            pts[#pts + 1] = d
            if tonumber(d.z) and (not lowest or d.z < lowest) then lowest = d.z end
        end
    end
    if #pts == 0 then return fixed() end

    -- centre and the direction of greatest spread (principal axis of the points)
    local cx, cy = 0.0, 0.0
    for _, p in ipairs(pts) do cx = cx + p.x; cy = cy + p.y end
    cx, cy = cx / #pts, cy / #pts
    local sxx, syy, sxy = 0.0, 0.0, 0.0
    for _, p in ipairs(pts) do
        local dx, dy = p.x - cx, p.y - cy
        sxx, syy, sxy = sxx + dx * dx, syy + dy * dy, sxy + dx * dy
    end
    local headingDeg
    if sxx + syy < 4.0 then
        headingDeg = (drops[1] and drops[1].heading) or c.heading or 0.0   -- all spots together: keep the drop's heading
    else
        headingDeg = math.deg(0.5 * math.atan(2.0 * sxy, sxx - syy)) % 360.0
    end

    -- centre the spots in the cabin's span (across) and in the rails' travel (along)
    local h = math.rad(headingDeg)
    local rx, ry, fx, fy = math.cos(h), math.sin(h), -math.sin(h), math.cos(h)
    local aMin, aMax, sMin, sMax = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(pts) do
        local dx, dy = p.x - cx, p.y - cy
        local across, along = dx * fx + dy * fy, dx * rx + dy * ry
        aMin, aMax = math.min(aMin, across), math.max(aMax, across)
        sMin, sMax = math.min(sMin, along), math.max(sMax, along)
    end
    local span = g.span or {}
    local spanMid = ((span.min or -7.0) + (span.max or 5.66)) / 2.0
    local t = (aMin + aMax) / 2.0 - spanMid          -- shift the frame sideways by this
    local u = (sMin + sMax) / 2.0                    -- and along the rails to the middle of the spread
    local refX, refY = cx + fx * t + rx * u, cy + fy * t + ry * u
    local z = lowest or pts[1].z or 0.0

    local ref = { x = refX, y = refY, z = z, heading = headingDeg, model = c.model, auto = true }
    -- can it reach everything? (checked with the same maths the movement uses)
    ref.reachable = true
    for _, p in ipairs(pts) do
        if not CWGantry.layout(g, ref, p.x, p.y).reachable then ref.reachable = false break end
    end
    return ref
end

function CWGantry.get(model)
    local all = Config and Config.ContainerWars and Config.ContainerWars.gantries
    return all and model and all[model] or nil
end

-- ─── Several cranes ────────────────────────────────────────────────────────────────
-- One gantry only reaches its own aisle (across its span, along its rails), so a yard with containers in several
-- aisles has several cranes. harbour.cranes holds them ({ x, y, z, heading, uid }); harbour.crane is the first one
-- (and carries the model and the "auto" flag) for everything written for a single crane.

-- Every crane of the yard as { x, y, z, heading, model, auto, reachable, uid } — one entry when only one is placed
-- (that one may still place itself automatically).
function CWGantry.resolveCranes(harbour, count)
    local out = {}
    local base = (harbour and harbour.crane) or {}
    local list = harbour and harbour.cranes
    if type(list) == 'table' and #list > 0 then
        for _, c in ipairs(list) do
            if tonumber(c.x) and tonumber(c.y) then
                out[#out + 1] = {
                    x = c.x, y = c.y, z = c.z or 0.0, heading = c.heading or 0.0,
                    model = c.model or base.model or 'prop_dock_rtg_ld', auto = false, reachable = true, uid = c.uid,
                }
            end
        end
        if #out == 1 and base.auto then
            local r = CWGantry.resolveCrane(harbour, count)
            if r then r.uid = out[1].uid; out[1] = r end
        end
        if #out > 0 then return out end
    end
    local r = CWGantry.resolveCrane(harbour, count)
    if r then out[1] = r end
    return out
end

-- The crane that should carry a container from `pick` to `drop`: if explicitly assigned, uses that crane
-- and checks its reach; otherwise picks one that can reach both, or the closest. Returns index, reachable.
function CWGantry.craneFor(cranes, pick, drop)
    cranes = cranes or {}
    if pick and tonumber(pick.assignedCrane) then
        local ac = math.floor(tonumber(pick.assignedCrane))
        if ac >= 1 and ac <= #cranes then
            local c = cranes[ac]
            local g = CWGantry.get(c.model)
            if g then
                local reach = true
                if pick and tonumber(pick.x) and tonumber(pick.y) then
                    local lay = CWGantry.layout(g, c, pick.x, pick.y)
                    if not lay.reachable then reach = false end
                end
                if drop and tonumber(drop.x) and tonumber(drop.y) then
                    local lay = CWGantry.layout(g, c, drop.x, drop.y)
                    if not lay.reachable then reach = false end
                end
                return ac, reach
            end
        end
    end

    local pts = {}
    if pick and tonumber(pick.x) and tonumber(pick.y) then pts[#pts + 1] = pick end
    if drop and tonumber(drop.x) and tonumber(drop.y) then pts[#pts + 1] = drop end
    local best, bestScore, bestReach
    for ci, c in ipairs(cranes) do
        local g = CWGantry.get(c.model)
        if g then
            local reach, miss, dist = true, 0.0, 0.0
            for _, p in ipairs(pts) do
                local lay = CWGantry.layout(g, c, p.x, p.y)
                if not lay.reachable then reach = false end
                miss = miss + math.sqrt((lay.hook.x - p.x) ^ 2 + (lay.hook.y - p.y) ^ 2)
                dist = dist + math.sqrt((c.x - p.x) ^ 2 + (c.y - p.y) ^ 2)
            end
            local score = (reach and 0.0 or 1e6) + miss * 10.0 + dist * 0.01
            if not bestScore or score < bestScore then best, bestScore, bestReach = ci, score, reach end
        end
    end
    return best, bestReach == true
end

-- The legs of every crane except `skip`, as obstacles for another crane rolling past ({ x, y, h, L, W, top }).
function CWGantry.craneObstacles(cranes, skip)
    local out = {}
    for ci, c in ipairs(cranes or {}) do
        local g = CWGantry.get(c.model)
        if ci ~= skip and g and tonumber(c.x) then
            local tall = (c.z or 0.0) + ((g.cabin and g.cabin.z) or 18.0)
            for _, b in ipairs(CWGantry.legBoxes(g, c, 0.0)) do
                b.top = tall
                out[#out + 1] = b
            end
        end
    end
    return out
end

-- Which crane serves which container: { [i] = { crane = index, drop = dropIdx, reachable = bool, unassignedCrane = bool, unassignedDrop = bool } }
function CWGantry.assignCranes(harbour, cranes, count)
    cranes = cranes or CWGantry.resolveCranes(harbour, count)
    local n = count or math.max(#((harbour and harbour.pickups) or {}), #((harbour and harbour.drops) or {}))
    local out = {}
    for i = 1, n do
        local pick = harbour.pickups and harbour.pickups[i]
        local dropIdx = pick and tonumber(pick.assignedDrop) or i
        local drop = (harbour.drops and harbour.drops[dropIdx]) or (harbour.drops and harbour.drops[i]) or harbour.drop
        local ci, reach = CWGantry.craneFor(cranes, pick, drop)
        local hasCrane = (ci ~= nil and cranes ~= nil and cranes[ci] ~= nil)
        local hasDrop = (drop ~= nil and tonumber(drop.x) ~= nil)
        out[i] = {
            crane = ci,
            drop = dropIdx,
            reachable = (reach == true),
            explicitCrane = (pick and tonumber(pick.assignedCrane) ~= nil),
            explicitDrop = (pick and tonumber(pick.assignedDrop) ~= nil),
            unassignedCrane = not hasCrane,
            unassignedDrop = not hasDrop,
        }
    end
    return out
end

local function axes(heading)
    local h = math.rad(heading or 0.0)
    return math.cos(h), math.sin(h), -math.sin(h), math.cos(h)   -- rx, ry, fx, fy
end

-- g     : the gantry description (Config.ContainerWars.gantries[model])
-- crane : { x, y, z, heading } — the frame's reference position (rail offset 0)
-- hx,hy : where the hook must end up (world)
-- Returns { frame, cabin, wheels = {...}, hook = {x,y}, reachable }.
-- Positions that cannot be reached (beyond the rails or the span) are clamped, and `reachable` is false.
function CWGantry.layout(g, crane, hx, hy)
    local rx, ry, fx, fy = axes(crane.heading)
    local cabX = (g.cabin and g.cabin.x) or 0.0
    local dx, dy = hx - crane.x, hy - crane.y
    local along = dx * rx + dy * ry      -- how far along the rails the hook is
    local across = dx * fx + dy * fy     -- how far across the span the hook is

    local rail = g.rail or {}
    local span = g.span or {}
    local s = along - cabX
    -- crane.railMin / railMax narrow the travel to the stretch where the legs stay clear of the yard
    -- (see CWGantry.railLimits); without them the configured rail limits apply
    local sClamped = math.max(crane.railMin or rail.min or -60.0, math.min(crane.railMax or rail.max or 60.0, s))
    local cClamped = math.max(span.min or -7.0, math.min(span.max or 5.66, across))

    local frameX, frameY = crane.x + rx * sClamped, crane.y + ry * sClamped
    local cabinX = frameX + rx * cabX + fx * cClamped
    local cabinY = frameY + ry * cabX + fy * cClamped
    local heading = crane.heading or 0.0

    local out = {
        reachable = (sClamped == s) and (cClamped == across),
        frame = { x = frameX, y = frameY, z = crane.z, heading = heading },
        cabin = { x = cabinX, y = cabinY, z = crane.z + ((g.cabin and g.cabin.z) or 18.0), heading = heading + ((g.cabin and g.cabin.heading) or 0.0) },
        hook = { x = cabinX, y = cabinY },
        wheels = {},
    }
    for i, w in ipairs((g.wheels and g.wheels.positions) or {}) do
        out.wheels[i] = {
            x = frameX + rx * (w.x or 0.0) + fx * (w.y or 0.0),
            y = frameY + ry * (w.x or 0.0) + fy * (w.y or 0.0),
            z = crane.z + (w.z or 0.0),
            heading = heading + (w.heading or 0.0),
        }
    end
    return out
end

-- ─── The carry: how the container gets from the pickup to the drop ─────────────────
-- A container is long (about 12 m) and narrow (2.6 m), so it travels like a car: it leaves its spot along its OWN
-- length, bends round, and arrives at the drop spot along the drop's heading. Its heading follows the path all the
-- way, so it ends exactly on the drop's heading without a spin at the end. The path is chosen by CWGantry.planCarry,
-- which tries different bends and picks one whose swept footprint stays clear of every other container (and dummy)
-- in the yard and inside what the gantry can reach.
--
-- Headings are GTA headings (degrees, counter-clockwise); a container's length runs along its forward vector
-- (-sin h, cos h).

-- Move plans (smooth crane): the server describes one container's trip as a list of timed segments and sends it once;
-- every client plays it back locally. A segment is { ms, ax, ay, az, bx, by, bz, ah, bh, carry, px, py, ph }: it eases
-- from a to b over `ms` milliseconds (the carry gives px/py/ph instead, a sampled path followed from its first to its
-- last point). Returns the hook's x, y, z and the heading `t` milliseconds into the segment.
function CWGantry.evalSegment(s, t)
    local u = (s.ms and s.ms > 0) and math.min(1.0, math.max(0.0, t / s.ms)) or 1.0
    local e = u * u * (3.0 - 2.0 * u)
    if s.px and #s.px > 1 then
        local f = e * (#s.px - 1)
        local i = math.min(#s.px - 2, math.floor(f))   -- the last pair of samples at most, so u = 1 lands exactly on the end
        local k = f - i
        return s.px[i + 1] + (s.px[i + 2] - s.px[i + 1]) * k,
               s.py[i + 1] + (s.py[i + 2] - s.py[i + 1]) * k,
               s.az,
               s.ph[i + 1] + (s.ph[i + 2] - s.ph[i + 1]) * k
    end
    return s.ax + (s.bx - s.ax) * e, s.ay + (s.by - s.ay) * e, s.az + (s.bz - s.az) * e, s.ah + (s.bh - s.ah) * e
end

local function turnBetween(a, b)           -- shortest signed turn from a to b, degrees
    return ((b - a + 180.0) % 360.0) - 180.0
end

-- Do two rectangles overlap? { x, y, h (degrees), L (length along forward), W (width) } — separating-axis test.
local function boxesOverlap(a, b)
    local function axes(o)
        local r = math.rad(o.h)
        return -math.sin(r), math.cos(r), math.cos(r), math.sin(r)       -- forward x,y and right x,y
    end
    local afx, afy, arx, ary = axes(a)
    local bfx, bfy, brx, bry = axes(b)
    local dx, dy = b.x - a.x, b.y - a.y
    local function separated(ux, uy)
        local ra = (a.L / 2.0) * math.abs(afx * ux + afy * uy) + (a.W / 2.0) * math.abs(arx * ux + ary * uy)
        local rb = (b.L / 2.0) * math.abs(bfx * ux + bfy * uy) + (b.W / 2.0) * math.abs(brx * ux + bry * uy)
        return math.abs(dx * ux + dy * uy) > ra + rb
    end
    return not (separated(afx, afy) or separated(arx, ary) or separated(bfx, bfy) or separated(brx, bry))
end
CWGantry.boxesOverlap = boxesOverlap

-- opts.mode      'CURVE' or 'STRAIGHT'
-- opts.tension   how long the straight run-out / run-in at each end is, as a fraction of the distance (default 0.4)
-- opts.shift     metres the whole bend is pushed sideways (to get round something), default 0
-- opts.sign      +1 / -1: leave along the forward / backward vector of the heading (default: whichever points to the drop)
-- Returns at(t) -> x, y, heading for t in 0..1, and the path's approximate length.
function CWGantry.carryPath(px, py, h0, dx, dy, h1, opts)
    opts = opts or {}
    local vx, vy = dx - px, dy - py
    local dist = math.sqrt(vx * vx + vy * vy)
    local dh = turnBetween(h0, h1)
    if opts.mode ~= 'CURVE' or dist < 1.0 then
        return function(t) return px + vx * t, py + vy * t, h0 + dh * t end, dist
    end

    local r0, r1 = math.rad(h0), math.rad(h1)
    local f0x, f0y = -math.sin(r0), math.cos(r0)
    local f1x, f1y = -math.sin(r1), math.cos(r1)
    local s = opts.sign
    if s ~= 1 and s ~= -1 then
        s = ((f0x * vx + f0y * vy) + (f1x * vx + f1y * vy) >= 0.0) and 1 or -1
    end
    local run = math.max(3.0, dist * (tonumber(opts.tension) or 0.4))
    local nx, ny = -vy / dist, vx / dist
    local shift = tonumber(opts.shift) or 0.0
    local c1x, c1y = px + s * f0x * run + nx * shift, py + s * f0y * run + ny * shift
    local c2x, c2y = dx - s * f1x * run + nx * shift, dy - s * f1y * run + ny * shift

    local function pos(t)
        local u = 1.0 - t
        local a, b, c, d = u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t
        return a * px + b * c1x + c * c2x + d * dx, a * py + b * c1y + c * c2y + d * dy
    end
    local function tangentAngle(t)
        local u = 1.0 - t
        local tx = 3.0 * u * u * (c1x - px) + 6.0 * u * t * (c2x - c1x) + 3.0 * t * t * (dx - c2x)
        local ty = 3.0 * u * u * (c1y - py) + 6.0 * u * t * (c2y - c1y) + 3.0 * t * t * (dy - c2y)
        return math.deg(math.atan(-tx, ty))
    end

    -- the heading follows the direction of travel: the turn is accumulated step by step so it can never flip
    -- the wrong way round, and starts from the pickup's own heading
    local N = 48
    local heads, length = { [0] = h0 }, 0.0
    local prevA, prevX, prevY = tangentAngle(0.0), px, py
    local cum = 0.0
    for i = 1, N do
        local t = i / N
        local a = tangentAngle(t)
        cum = cum + turnBetween(prevA, a)
        prevA = a
        heads[i] = h0 + cum
        local x, y = pos(t)
        length = length + math.sqrt((x - prevX) ^ 2 + (y - prevY) ^ 2)
        prevX, prevY = x, y
    end
    local fix = turnBetween(heads[N], h1)         -- tiny: the ends already point along the two headings
    return function(t)
        local x, y = pos(t)
        local f = t * N
        local i = math.min(N - 1, math.floor(f))
        local hh = heads[i] + (heads[i + 1] - heads[i]) * (f - i)
        return x, y, hh + fix * t
    end, length
end

-- Chooses the carry path.
--   a.pick / a.drop   { x, y, h }
--   a.z               the height the container is carried at (its bottom edge)
--   a.size            { length, width, height } of the carried container
--   a.obstacles       list of { x, y, h, L, W, top } : everything else standing in the yard (top = its top height)
--   a.margin          clearance to keep, metres (default 0.6)
--   a.mode            'CURVE' (default: planned, car-like) or 'STRAIGHT'
--   a.tension         preferred run-out length (fraction of the distance)
--   a.gantry, a.crane the crane's description, to keep the path inside its rails / span
-- Returns at(t) -> x, y, heading and a table { mode, violations, reachable, shift, tension }.
function CWGantry.planCarry(a)
    local p, d = a.pick, a.drop
    local size = a.size or { length = 12.2, width = 2.6, height = 2.7 }
    local margin = a.margin or 0.6
    local obstacles = a.obstacles or {}
    local mode = (a.mode == 'STRAIGHT') and 'STRAIGHT' or 'CURVE'

    local function violations(at)
        local n = 0
        for i = 0, 36 do
            local x, y, h = at(i / 36.0)
            local me = { x = x, y = y, h = h, L = size.length + margin * 2.0, W = size.width + margin * 2.0 }
            for _, o in ipairs(obstacles) do
                -- only what is tall enough to be in the way at the carrying height
                if a.z < (o.top or 0.0) + margin and boxesOverlap(me, o) then n = n + 1 break end
            end
        end
        return n
    end
    local function reachable(at)
        if not (a.gantry and a.crane) then return true end
        for i = 1, 9 do
            local x, y = at(i / 10.0)
            if not CWGantry.layout(a.gantry, a.crane, x, y).reachable then return false end
        end
        return true
    end
    local function score(at)
        local v = violations(at)
        local ok = reachable(at)
        return v + (ok and 0 or 1000), v, ok
    end

    local straightAt = CWGantry.carryPath(p.x, p.y, p.h, d.x, d.y, d.h, { mode = 'STRAIGHT' })
    if mode == 'STRAIGHT' then
        local _, v, ok = score(straightAt)
        return straightAt, { mode = 'STRAIGHT', violations = v, reachable = ok }
    end

    local tension0 = tonumber(a.tension) or 0.4
    local bestAt, bestInfo, bestScore
    local function consider(at, info)
        local sc, v, ok = score(at)
        info.violations, info.reachable = v, ok
        -- among equals the first one tried wins: the least bend, then the least detour
        if not bestScore or sc < bestScore then bestAt, bestInfo, bestScore = at, info, sc end
        return sc == 0
    end
    local taus = { tension0, 0.3, 0.55, 0.75, 1.0 }
    local shifts = { 0.0, 5.0, -5.0, 10.0, -10.0, 18.0, -18.0, 28.0, -28.0 }
    for _, shift in ipairs(shifts) do
        for _, tau in ipairs(taus) do
            for _, sg in ipairs({ 0, 1, -1 }) do
                local at = CWGantry.carryPath(p.x, p.y, p.h, d.x, d.y, d.h, { mode = 'CURVE', tension = tau, shift = shift, sign = (sg ~= 0) and sg or nil })
                if consider(at, { mode = 'CURVE', tension = tau, shift = shift, sign = sg }) then
                    return bestAt, bestInfo
                end
            end
        end
    end
    -- nothing was clear: the straight line may still be better than the least bad bend
    consider(straightAt, { mode = 'STRAIGHT' })
    return bestAt, bestInfo
end

-- Everything in the yard a carried container could run into: the other auction containers (the ones already dropped
-- stand at their drop spots, the rest still wait at their pickup spots) and the dummy container stacks.
--   harbour   Config.ContainerWars.harbour (dummies, dummyStep)
--   containers  the event's containers (each with pickupCoords / dropCoords)
--   current   the container being carried
--   size      { length, width, height } of an auction container
function CWGantry.carryObstacles(harbour, containers, current, size, dummySize)
    local out = {}
    size = size or { length = 12.2, width = 2.6, height = 2.7 }
    local idx = current and current.containerIndex or 0
    for j, o in ipairs(containers or {}) do
        if o ~= current then
            -- `atDrop` is set by a running event that knows where each container really stands; without it the
            -- earlier lots are taken to be on their drop pads and the later ones still at their pickups
            local atDrop = o.atDrop
            if atDrop == nil then atDrop = (j < idx) end
            local spot = atDrop and o.dropCoords or o.pickupCoords
            if spot and tonumber(spot.x) and tonumber(spot.y) then
                out[#out + 1] = { x = spot.x, y = spot.y, h = spot.heading or 0.0, L = size.length, W = size.width, top = (tonumber(spot.z) or 0.0) + size.height }
            end
        end
    end
    -- dummies are normally full-size containers; assuming the short 20 ft size let the crane's legs clip the ends
    dummySize = dummySize or { length = size.length, width = size.width }
    for _, dm in ipairs((harbour and harbour.dummies) or {}) do
        if tonumber(dm.x) and tonumber(dm.y) then
            local step = tonumber(dm.step) or tonumber(harbour and harbour.dummyStep) or 2.6
            out[#out + 1] = { x = dm.x, y = dm.y, h = dm.heading or 0.0, L = dummySize.length, W = dummySize.width, top = (tonumber(dm.z) or 0.0) + (tonumber(dm.stack) or 1) * step }
        end
    end
    return out
end

-- ─── The crane's legs ──────────────────────────────────────────────────────────────
-- The frame rolls along its rails and its two legs (the wheel groups) sweep a lane each, about 9 m either side of
-- the frame's middle, whatever path the hook takes. Anything standing in a lane is run through, however high the
-- container is carried — so the rolling range is limited to the stretch where both lanes are clear.

-- The leg footprints for a frame rolled `s` metres along its rails: { x, y, h, L, W } boxes, L along the rails.
function CWGantry.legBoxes(g, crane, s)
    local wheels = g and g.wheels and g.wheels.positions
    if not wheels or #wheels == 0 then return {} end
    local minY, maxY = math.huge, -math.huge
    for _, w in ipairs(wheels) do minY, maxY = math.min(minY, w.y or 0.0), math.max(maxY, w.y or 0.0) end
    local midY = (minY + maxY) / 2.0
    local groups = { {}, {} }
    for _, w in ipairs(wheels) do
        local gi = ((w.y or 0.0) < midY) and 1 or 2
        local grp = groups[gi]
        grp.minX = math.min(grp.minX or math.huge, w.x or 0.0)
        grp.maxX = math.max(grp.maxX or -math.huge, w.x or 0.0)
        grp.sumY, grp.n = (grp.sumY or 0.0) + (w.y or 0.0), (grp.n or 0) + 1
    end
    local rx, ry, fx, fy = axes(crane.heading)
    local out = {}
    for _, grp in ipairs(groups) do
        if grp.n then
            local cx, cy = (grp.minX + grp.maxX) / 2.0, grp.sumY / grp.n
            out[#out + 1] = {
                x = crane.x + rx * (s + cx) + fx * cy,
                y = crane.y + ry * (s + cx) + fy * cy,
                h = (crane.heading or 0.0) - 90.0,                       -- so the box's length runs along the rails
                L = (grp.maxX - grp.minX) + (tonumber(g.legLength) or 3.0),
                W = tonumber(g.legWidth) or 3.4,
            }
        end
    end
    return out
end

-- How far the crane may roll each way from its reference spot before a leg meets something.
--   obstacles  { x, y, h, L, W, top } as from carryObstacles; only things taller than the legs' feet count
-- Returns lo, hi (metres along the rails, lo <= 0 <= hi), or nil when a leg is already touching something at the
-- reference spot (then there is nothing sensible to limit and the configured rails apply).
function CWGantry.railLimits(g, crane, obstacles, margin)
    margin = tonumber(margin) or 0.5
    local rail = g and g.rail or {}
    local function blocked(s)
        for _, b in ipairs(CWGantry.legBoxes(g, crane, s)) do
            b.L, b.W = b.L + margin * 2.0, b.W + margin * 2.0
            for _, o in ipairs(obstacles or {}) do
                if (o.top or 0.0) > (crane.z or 0.0) + 0.5 and boxesOverlap(b, o) then return true end
            end
        end
        return false
    end
    if blocked(0.0) then return nil end
    local step = 0.5
    local hi, lo = 0.0, 0.0
    for s = step, (rail.max or 60.0), step do
        if blocked(s) then break end
        hi = s
    end
    for s = -step, (rail.min or -60.0), -step do
        if blocked(s) then break end
        lo = s
    end
    return lo, hi
end

-- ─── Height the container is carried at ────────────────────────────────────────────
-- Lifted `lift` metres above the higher of the two spots, but never above what the cabin lets the spreader reach
-- (the pickup may be up on a stack). Server and client use the same number.
function CWGantry.carryHeight(g, crane, pickZ, dropZ, lift)
    local z = math.max(pickZ, dropZ) + (tonumber(lift) or 14.0)
    if g and crane then
        local ceiling = crane.z + ((g.cabin and g.cabin.z) or 18.0) + (tonumber(g.cableTopOffset) or -1.0) - (tonumber(g.hookClearance) or 5.0)
        z = math.max(math.max(pickZ, dropZ) + 0.5, math.min(z, ceiling))
    end
    return z
end

-- ─── A path through waypoints ──────────────────────────────────────────────────────
-- pts = the waypoints between the two spots ({x,y} each). The container leaves along its own length, follows the
-- waypoints on a smooth spline and arrives along the drop heading, so its heading follows the direction of travel.
-- Returns at(t) -> x, y, heading (t in 0..1, by distance) and the length.
function CWGantry.splinePath(px, py, h0, dx, dy, h1, pts, opts)
    opts = opts or {}
    pts = pts or {}
    local r0, r1 = math.rad(h0), math.rad(h1)
    local f0x, f0y = -math.sin(r0), math.cos(r0)
    local f1x, f1y = -math.sin(r1), math.cos(r1)
    local first = pts[1] or { x = dx, y = dy }
    local last = pts[#pts] or { x = px, y = py }
    local s = opts.sign
    if s ~= 1 and s ~= -1 then
        local a = f0x * (first.x - px) + f0y * (first.y - py)
        local b = f1x * (dx - last.x) + f1y * (dy - last.y)
        s = (a + b >= 0.0) and 1 or -1
    end
    -- a container is about 12 m long, so it needs about that much straight run before it starts to bend
    local span = math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2)
    local run = tonumber(opts.run) or math.min(12.0, math.max(4.0, span * 0.35))
    -- the straight run-out / run-in along the container's own length is only used when it points the way the route
    -- goes; if it points away (it would need a hairpin) the container simply turns towards the route instead
    local function unit(ax, ay) local l = math.sqrt(ax * ax + ay * ay); if l < 1e-6 then return 0.0, 0.0 end return ax / l, ay / l end
    local u0x, u0y = unit(first.x - px, first.y - py)
    local uEx, uEy = unit(dx - last.x, dy - last.y)
    local useStart = s * (f0x * u0x + f0y * u0y) > 0.35
    local useEnd = s * (f1x * uEx + f1y * uEy) > 0.35
    local c = { { px, py } }
    if useStart then c[#c + 1] = { px + s * f0x * run, py + s * f0y * run } end
    for _, p in ipairs(pts) do c[#c + 1] = { p.x, p.y } end
    if useEnd then c[#c + 1] = { dx - s * f1x * run, dy - s * f1y * run } end
    c[#c + 1] = { dx, dy }

    -- round the corners (the container is long: it needs wide bends, not tight ones)
    local function chaikin(list)
        local out = { list[1] }
        for i = 1, #list - 1 do
            local a, b = list[i], list[i + 1]
            out[#out + 1] = { 0.75 * a[1] + 0.25 * b[1], 0.75 * a[2] + 0.25 * b[2] }
            out[#out + 1] = { 0.25 * a[1] + 0.75 * b[1], 0.25 * a[2] + 0.75 * b[2] }
        end
        out[#out + 1] = list[#list]
        return out
    end
    -- Four rounds of corner cutting give a smooth quadratic B-spline that never overshoots (a Catmull-Rom spline
    -- loops at uneven spacing) and keeps the first and last segments, so it still leaves and arrives along the headings.
    for _ = 1, 4 do c = chaikin(c) end
    local xs, ys = {}, {}
    for i = 1, #c do xs[i], ys[i] = c[i][1], c[i][2] end
    local n = #xs
    local cum, heads = { [1] = 0.0 }, { [1] = h0 }
    local prevA, acc = math.deg(math.atan(-(xs[2] - xs[1]), ys[2] - ys[1])), 0.0
    for i = 2, n do
        local ddx, ddy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
        local seg = math.sqrt(ddx * ddx + ddy * ddy)
        cum[i] = cum[i - 1] + seg
        if seg > 1e-6 then
            local a = math.deg(math.atan(-ddx, ddy))
            acc = acc + turnBetween(prevA, a)
            prevA = a
        end
        heads[i] = h0 + acc
    end
    local total = math.max(cum[n], 1e-6)
    local fix = turnBetween(heads[n], h1)
    return function(t)
        local d = math.max(0.0, math.min(1.0, t)) * total
        local lo, hi = 1, n
        while hi - lo > 1 do
            local mid = (lo + hi) // 2
            if cum[mid] <= d then lo = mid else hi = mid end
        end
        local span = cum[hi] - cum[lo]
        local f = span > 1e-9 and (d - cum[lo]) / span or 0.0
        local hh = heads[lo] + (heads[hi] - heads[lo]) * f
        return xs[lo] + (xs[hi] - xs[lo]) * f, ys[lo] + (ys[hi] - ys[lo]) * f, hh + fix * (d / total)
    end, total
end

-- ─── Finding a route through the real yard ─────────────────────────────────────────
-- The client scans the yard (the height of the tallest thing in every cell) and calls this. The container is
-- carried at `carryZ`; a cell is blocked when something there is taller than that. A* finds a way through the open
-- lanes, the result is smoothed with splinePath and checked with the container's real footprint (long and narrow,
-- pointing along the direction of travel).
--   a.heightAt(x, y)  -> height of the tallest thing there, or nil if unknown (treated as free)
--   a.minX/minY/maxX/maxY, a.cell (metres, default 2)
--   a.carryZ, a.margin (default 1.0)
--   a.pick / a.drop  { x, y, h }
--   a.size { length, width }, a.gantry / a.crane (keep inside the rails and span), a.freeRadius (default 9)
-- Returns { points = {{x,y}...}, violations, inflation, cells } or nil.
function CWGantry.findRoute(a)
    local cs = a.cell or 2.0
    local x0, y0 = a.minX, a.minY
    local nx, ny = math.max(1, math.ceil((a.maxX - x0) / cs)), math.max(1, math.ceil((a.maxY - y0) / cs))
    local limitZ = a.carryZ - (a.margin or 1.0)
    local freeR = a.freeRadius or 9.0
    local size = a.size or { length = 12.2, width = 2.6 }

    local function cellOf(x, y) return math.floor((x - x0) / cs), math.floor((y - y0) / cs) end
    local function centre(i, j) return x0 + (i + 0.5) * cs, y0 + (j + 0.5) * cs end
    local function idx(i, j) return j * nx + i + 1 end
    local function inside(i, j) return i >= 0 and j >= 0 and i < nx and j < ny end

    local function nearEnd(x, y)
        return (x - a.pick.x) ^ 2 + (y - a.pick.y) ^ 2 < freeR * freeR or (x - a.drop.x) ^ 2 + (y - a.drop.y) ^ 2 < freeR * freeR
    end

    local blocked = {}
    for j = 0, ny - 1 do
        for i = 0, nx - 1 do
            local x, y = centre(i, j)
            local b = false
            if not nearEnd(x, y) then
                local z = a.heightAt(x, y)
                if z and z > limitZ then b = true end
                if not b and a.gantry and a.crane and not CWGantry.layout(a.gantry, a.crane, x, y).reachable then b = true end
            end
            blocked[idx(i, j)] = b
        end
    end

    local function sweptViolations(at)
        local v = 0
        local L, W = size.length, size.width
        for k = 0, 60 do
            local x, y, h = at(k / 60.0)
            if not nearEnd(x, y) then
                local r = math.rad(h)
                local fx, fy, rx, ry = -math.sin(r), math.cos(r), math.cos(r), math.sin(r)
                local hit = false
                for u = -L / 2.0, L / 2.0 + 0.01, math.max(cs * 0.75, 1.0) do
                    for w = -W / 2.0, W / 2.0 + 0.01, W / 2.0 do
                        local px, py = x + fx * u + rx * w, y + fy * u + ry * w
                        local z = a.heightAt(px, py)
                        if z and z > limitZ then hit = true break end
                    end
                    if hit then break end
                end
                if hit then v = v + 1 end
            end
        end
        return v
    end

    local function astar(inflated, si, sj, gi, gj)
        local gScore, came, closed = {}, {}, {}
        local heap, size_ = {}, 0
        local function push(node, f)
            size_ = size_ + 1
            heap[size_] = { node = node, f = f }
            local i = size_
            while i > 1 do
                local p = i // 2
                if heap[p].f <= heap[i].f then break end
                heap[p], heap[i] = heap[i], heap[p]
                i = p
            end
        end
        local function pop()
            local top = heap[1]
            heap[1] = heap[size_]
            heap[size_] = nil
            size_ = size_ - 1
            local i = 1
            while true do
                local l, r, m = i * 2, i * 2 + 1, i
                if l <= size_ and heap[l].f < heap[m].f then m = l end
                if r <= size_ and heap[r].f < heap[m].f then m = r end
                if m == i then break end
                heap[m], heap[i] = heap[i], heap[m]
                i = m
            end
            return top.node
        end
        local function h(i, j)
            local dx, dy = math.abs(i - gi), math.abs(j - gj)
            return (dx + dy) + (1.4142 - 2.0) * math.min(dx, dy)
        end
        local start = idx(si, sj)
        gScore[start] = 0.0
        push({ si, sj }, h(si, sj))
        local dirs = { { 1, 0, 1.0 }, { -1, 0, 1.0 }, { 0, 1, 1.0 }, { 0, -1, 1.0 }, { 1, 1, 1.4142 }, { 1, -1, 1.4142 }, { -1, 1, 1.4142 }, { -1, -1, 1.4142 } }
        while size_ > 0 do
            local cur = pop()
            local ci, cj = cur[1], cur[2]
            local ck = idx(ci, cj)
            if ci == gi and cj == gj then
                local path, k = {}, ck
                while k do
                    path[#path + 1] = k
                    k = came[k]
                end
                local out = {}
                for n = #path, 1, -1 do
                    local kk = path[n] - 1
                    out[#out + 1] = { kk % nx, kk // nx }
                end
                return out
            end
            if not closed[ck] then
                closed[ck] = true
                for _, d in ipairs(dirs) do
                    local ni, nj = ci + d[1], cj + d[2]
                    if inside(ni, nj) and not inflated[idx(ni, nj)] then
                        local ok = true
                        if d[1] ~= 0 and d[2] ~= 0 then      -- no cutting corners
                            ok = not inflated[idx(ci + d[1], cj)] and not inflated[idx(ci, cj + d[2])]
                        end
                        if ok then
                            local nk = idx(ni, nj)
                            local g = gScore[ck] + d[3]
                            if not gScore[nk] or g < gScore[nk] then
                                gScore[nk] = g
                                came[nk] = ck
                                push({ ni, nj }, g + h(ni, nj))
                            end
                        end
                    end
                end
            end
        end
        return nil
    end

    local si, sj = cellOf(a.pick.x, a.pick.y)
    local gi, gj = cellOf(a.drop.x, a.drop.y)
    if not (inside(si, sj) and inside(gi, gj)) then return nil end

    local best
    for _, radiusM in ipairs({ 3.4, 4.4, 5.6, 2.6, 7.0 }) do
        local rc = math.ceil(radiusM / cs)
        local inflated = {}
        for j = 0, ny - 1 do
            for i = 0, nx - 1 do
                local b = false
                local x, y = centre(i, j)
                if not nearEnd(x, y) then
                    for dj = -rc, rc do
                        for di = -rc, rc do
                            if di * di + dj * dj <= rc * rc and inside(i + di, j + dj) and blocked[idx(i + di, j + dj)] then b = true break end
                        end
                        if b then break end
                    end
                end
                inflated[idx(i, j)] = b
            end
        end
        local cells = astar(inflated, si, sj, gi, gj)
        if cells then
            -- string pulling: keep only the corners that the line of sight needs
            local function clear(c1, c2)
                local steps = math.max(math.abs(c2[1] - c1[1]), math.abs(c2[2] - c1[2])) * 2
                for s = 0, steps do
                    local t = steps == 0 and 0 or s / steps
                    local i = math.floor(c1[1] + (c2[1] - c1[1]) * t + 0.5)
                    local j = math.floor(c1[2] + (c2[2] - c1[2]) * t + 0.5)
                    if inflated[idx(i, j)] then return false end
                end
                return true
            end
            local pts, at = {}, 1
            while at < #cells do
                local far = at + 1
                for k = #cells, at + 1, -1 do
                    if clear(cells[at], cells[k]) then far = k break end
                end
                at = far
                if at < #cells then
                    local x, y = centre(cells[at][1], cells[at][2])
                    pts[#pts + 1] = { x = x, y = y }
                end
            end
            local path = CWGantry.splinePath(a.pick.x, a.pick.y, a.pick.h, a.drop.x, a.drop.y, a.drop.h, pts)
            local v = sweptViolations(path)
            local cand = { points = pts, violations = v, inflation = radiusM, cells = #cells }
            if not best or v < best.violations then best = cand end
            if v == 0 then break end
        end
    end
    return best
end

-- ─── Which carry path does container N use? ────────────────────────────────────────
-- A route planned in the tablet ("Plan route": the client scanned the real yard and found a clear way) is used when
-- it is still valid for the current pickup and drop spots; otherwise the path is planned from what the config knows
-- (the other containers and the dummy stacks). Server and client both call this, so the Test Crane Run shows
-- exactly what the event will do.
--   a.harbour, a.index, a.pick {x,y,h}, a.drop {x,y,h}, a.z, a.mode, a.tension, a.containers, a.current, a.size,
--   a.gantry, a.crane
-- Returns at(t) -> x, y, heading and { planned = bool, violations = n }.
function CWGantry.chooseCarry(a)
    local saved = a.harbour and a.harbour.carry and a.harbour.carry[tostring(a.index or 0)]
    local function same(p, q)
        return p and q and tonumber(p.x) and tonumber(q.x) and (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 < 2.25
    end
    if a.mode ~= 'STRAIGHT' and saved and type(saved.points) == 'table' and #saved.points > 0 and same(saved.pick, a.pick) and same(saved.drop, a.drop) then
        local at = CWGantry.splinePath(a.pick.x, a.pick.y, a.pick.h, a.drop.x, a.drop.y, a.drop.h, saved.points)
        return at, { planned = true, violations = tonumber(saved.violations) or 0 }
    end
    local size = a.size or { length = 12.2, width = 2.6, height = 2.7 }
    local at, info = CWGantry.planCarry({
        mode = a.mode, tension = a.tension, z = a.z, pick = a.pick, drop = a.drop, size = size,
        obstacles = CWGantry.carryObstacles(a.harbour, a.containers, a.current, size),
        gantry = a.gantry, crane = a.crane,
    })
    info = info or {}
    info.planned = false
    return at, info
end
