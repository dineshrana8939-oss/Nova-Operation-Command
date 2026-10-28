-- ─── Nova Convoy — Territory geometry (pure Lua) ───────────────────────────────
-- A painted territory is a set of CELLS on a world grid: cell (ix, iy) covers the world square
--   x in [ix*cs, (ix+1)*cs)   y in [iy*cs, (iy+1)*cs)        (cs = the cell size in metres the shape was painted with)
-- and is stored as ROW SPANS  { iy, ix0, ix1 }  (inclusive run of painted cells in row iy). The tablet paints / erases
-- cells with a brush, so undo / erase / "touching" are exact set operations, and the server can answer "is this point
-- inside the territory?" and "do these two territories touch?" without trusting anything the client says.
--
-- No natives, no globals other than TerritoryGeo: it loads and runs anywhere (the headless tests use it directly).

TerritoryGeo = {}

local OFFSET = 16384          -- cell indices are shifted by this so a key is one positive number
local SPAN = 32768           -- (keys stay below 2^30, so they are exact even in a 32-bit-integer Lua; a 25 m grid still covers +-400 km)
TerritoryGeo.SPAN = SPAN

local function floor(n) return math.floor(n) end

function TerritoryGeo.key(ix, iy)
    return (iy + OFFSET) * SPAN + (ix + OFFSET)
end

function TerritoryGeo.unkey(k)
    local iy = k // SPAN - OFFSET
    local ix = k % SPAN - OFFSET
    return ix, iy
end

-- ── spans <-> cell sets ──────────────────────────────────────────────────────────

-- Validates and normalises untrusted spans (from the tablet). Returns clean, cellCount.
-- Drops malformed rows, clamps indices into the supported grid, merges overlapping / touching runs, and stops (returns
-- what it has + `truncated = true`) once maxCells would be exceeded.
function TerritoryGeo.normalizeSpans(spans, maxCells)
    local rows = {}
    if type(spans) == 'table' then
        for _, s in ipairs(spans) do
            if type(s) == 'table' then
                local iy, x0, x1 = tonumber(s[1]), tonumber(s[2]), tonumber(s[3])
                if iy and x0 and x1 then
                    iy, x0, x1 = floor(iy), floor(x0), floor(x1)
                    if x1 < x0 then x0, x1 = x1, x0 end
                    if iy >= -OFFSET + 1 and iy <= OFFSET - 2 and x0 >= -OFFSET + 1 and x1 <= OFFSET - 2 then
                        local list = rows[iy]
                        if not list then list = {}; rows[iy] = list end
                        list[#list + 1] = { x0, x1 }
                    end
                end
            end
        end
    end
    local iys = {}
    for iy in pairs(rows) do iys[#iys + 1] = iy end
    table.sort(iys)
    local out, count, truncated = {}, 0, false
    maxCells = tonumber(maxCells) or math.huge
    for _, iy in ipairs(iys) do
        local list = rows[iy]
        table.sort(list, function(a, b) return a[1] < b[1] end)
        local cur
        local function flush()
            if not cur then return end
            local n = cur[2] - cur[1] + 1
            if count + n > maxCells then
                n = maxCells - count
                if n > 0 then out[#out + 1] = { iy, cur[1], cur[1] + n - 1 }; count = count + n end
                truncated = true
            else
                out[#out + 1] = { iy, cur[1], cur[2] }
                count = count + n
            end
            cur = nil
        end
        for _, r in ipairs(list) do
            if truncated then break end
            if cur and r[1] <= cur[2] + 1 then
                if r[2] > cur[2] then cur[2] = r[2] end
            else
                flush()
                if truncated then break end
                cur = { r[1], r[2] }
            end
        end
        if not truncated then flush() end
        if truncated then break end
    end
    return out, count, truncated
end

-- Cell set { [key] = true } of one or more span lists (later arguments are added to the same set). Returns set, count.
function TerritoryGeo.cellSet(...)
    local set, count = {}, 0
    for i = 1, select('#', ...) do
        local spans = select(i, ...)
        for _, s in ipairs(spans or {}) do
            local iy = s[1]
            for ix = s[2], s[3] do
                local k = (iy + OFFSET) * SPAN + (ix + OFFSET)
                if not set[k] then set[k] = true; count = count + 1 end
            end
        end
    end
    return set, count
end

function TerritoryGeo.setToSpans(set)
    local byRow = {}
    for k in pairs(set) do
        local ix, iy = TerritoryGeo.unkey(k)
        local list = byRow[iy]
        if not list then list = {}; byRow[iy] = list end
        list[#list + 1] = ix
    end
    local iys = {}
    for iy in pairs(byRow) do iys[#iys + 1] = iy end
    table.sort(iys)
    local out = {}
    for _, iy in ipairs(iys) do
        local list = byRow[iy]
        table.sort(list)
        local x0, prev = list[1], list[1]
        for i = 2, #list do
            if list[i] ~= prev + 1 then
                out[#out + 1] = { iy, x0, prev }
                x0 = list[i]
            end
            prev = list[i]
        end
        out[#out + 1] = { iy, x0, prev }
    end
    return out
end

function TerritoryGeo.count(spans)
    local n = 0
    for _, s in ipairs(spans or {}) do n = n + (s[3] - s[2] + 1) end
    return n
end

-- ── queries ──────────────────────────────────────────────────────────────────────

-- Row index for fast point queries: { [iy] = { x0, x1, x0, x1, ... } } (build once per shape, query many times).
function TerritoryGeo.rowIndex(...)
    local rows = {}
    for i = 1, select('#', ...) do
        for _, s in ipairs(select(i, ...) or {}) do
            local list = rows[s[1]]
            if not list then list = {}; rows[s[1]] = list end
            list[#list + 1] = s[2]
            list[#list + 1] = s[3]
        end
    end
    return rows
end

function TerritoryGeo.rowsContain(rows, cs, x, y)
    local ix, iy = floor(x / cs), floor(y / cs)
    local list = rows[iy]
    if not list then return false end
    for i = 1, #list, 2 do
        if ix >= list[i] and ix <= list[i + 1] then return true end
    end
    return false
end

-- Do two cell sets touch? "Touching" means a cell of one is a side or corner neighbour of a cell of the other (or they overlap).
-- Returns touching, contactCells.
function TerritoryGeo.touching(setA, setB)
    local small, big = setA, setB
    local na, nb = 0, 0
    for _ in pairs(setA) do na = na + 1 end
    for _ in pairs(setB) do nb = nb + 1 end
    if nb < na then small, big = setB, setA end
    local contact = 0
    for k in pairs(small) do
        local hit = false
        for dy = -1, 1 do
            for dx = -1, 1 do
                if big[k + dy * SPAN + dx] then hit = true; break end
            end
            if hit then break end
        end
        if hit then contact = contact + 1 end
    end
    return contact > 0, contact
end

-- World-space centroid and bounding box of span lists. Returns { x, y, minX, minY, maxX, maxY, cells } or nil if empty.
function TerritoryGeo.metrics(cs, ...)
    local sx, sy, n = 0, 0, 0
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, select('#', ...) do
        for _, s in ipairs(select(i, ...) or {}) do
            local len = s[3] - s[2] + 1
            n = n + len
            sx = sx + (s[2] + s[3] + 1) * 0.5 * len
            sy = sy + (s[1] + 0.5) * len
            if s[2] < minX then minX = s[2] end
            if s[3] + 1 > maxX then maxX = s[3] + 1 end
            if s[1] < minY then minY = s[1] end
            if s[1] + 1 > maxY then maxY = s[1] + 1 end
        end
    end
    if n == 0 then return nil end
    return { x = sx / n * cs, y = sy / n * cs, minX = minX * cs, minY = minY * cs, maxX = maxX * cs, maxY = maxY * cs, cells = n }
end

return TerritoryGeo
