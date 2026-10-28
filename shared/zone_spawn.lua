-- ─── Nova Convoy — spawn spots inside a drawn perimeter (shared: server places players, client draws the preview) ───
-- ZoneSpawn.spots(points, count) -> up to `count` { x, y, z } spots that lie INSIDE the polygon and are at least `minGap` metres apart
-- (a fixed grid clipped to the polygon, then picked in a scattered order so the first players are spread over the whole area instead of
-- standing shoulder to shoulder in one corner). The result depends only on the polygon and the count, so the server's spawn and the
-- tablet's "preview" always agree. The height of a spot is taken from the nearest drawn corners (the admin drew them on the ground).

ZoneSpawn = {}

local GOLDEN = 0.6180339887

local function inPoly(pts, x, y)
    local inside, j = false, #pts
    for i = 1, #pts do
        local a, b = pts[i], pts[j]
        if (a.y > y) ~= (b.y > y) and x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x then inside = not inside end
        j = i
    end
    return inside
end

local function heightAt(pts, x, y)
    local sw, sz = 0.0, 0.0
    for _, p in ipairs(pts) do
        local d2 = (p.x - x) ^ 2 + (p.y - y) ^ 2 + 0.01
        local w = 1.0 / d2
        sw, sz = sw + w, sz + w * (p.z or 0.0)
    end
    return sw > 0 and sz / sw or 0.0
end

-- every grid cell centre inside the polygon (row by row); the gap shrinks until there are enough cells for `count`
local function candidates(pts, count, minGap)
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        x1, y1, x2, y2 = math.min(x1, p.x), math.min(y1, p.y), math.max(x2, p.x), math.max(y2, p.y)
    end
    local gap, out = minGap, {}
    while gap >= 1.2 do
        out = {}
        local y = y1 + gap * 0.5
        while y < y2 do
            local x = x1 + gap * 0.5
            while x < x2 do
                if inPoly(pts, x, y) then out[#out + 1] = { x = x, y = y } end
                x = x + gap
            end
            y = y + gap
        end
        if #out >= count then break end
        gap = gap - 0.4
    end
    return out
end

-- pts: { {x,y,z}, ... } (3+ corners)   count: how many spots   minGap: metres between neighbours (default 2.5)
function ZoneSpawn.spots(pts, count, minGap)
    count = math.max(1, math.floor(tonumber(count) or 1))
    if type(pts) ~= 'table' or #pts < 3 then return {} end
    local cand = candidates(pts, count, tonumber(minGap) or 2.5)
    local n = #cand
    if n == 0 then
        -- a sliver too thin for the grid: the corners' average is the only safe place
        local sx, sy = 0.0, 0.0
        for _, p in ipairs(pts) do sx, sy = sx + p.x, sy + p.y end
        return { { x = sx / #pts, y = sy / #pts, z = heightAt(pts, sx / #pts, sy / #pts) } }
    end
    local out, used = {}, {}
    for i = 1, math.min(count, n) do
        -- the golden-ratio step visits the cells in a well scattered order; skip a cell already taken
        local k = (math.floor(i * GOLDEN * n) % n) + 1
        while used[k] do k = k % n + 1 end
        used[k] = true
        local c = cand[k]
        out[#out + 1] = { x = c.x, y = c.y, z = heightAt(pts, c.x, c.y) }
    end
    return out
end
