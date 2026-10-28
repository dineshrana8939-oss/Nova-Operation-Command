-- ─── In-world drawing helpers (client) ─────────────────────────────────────────────
-- The placers (Prop Placer, the harbour crane / container holograms) and the Test Crane Run all draw guide lines and
-- names in the world. The game's DrawLine is one pixel wide and its plain text is small and hard to read against the
-- harbour, so everything goes through here instead:
--   NovaDraw.line   a line that stays about the same thickness on screen at any distance
--   NovaDraw.box    the twelve edges of a box, thick
--   NovaDraw.rect   a footprint on the ground: soft fill + thick outline (+ optional corner posts)
--   NovaDraw.label  a name on a dark plate with a coloured edge — readable on any background

NovaDraw = {}

-- Natives that only some game builds have are called through here: a build without them just gets no outline (the white / blue boxes the
-- placers draw still show the selection), instead of a script error every frame. The first failure switches the call off for the session.
local outlineOk = true
function NovaDraw.outline(ent, on)
    if not outlineOk then return end
    local ok = pcall(SetEntityDrawOutline, ent, on and true or false)
    if not ok then outlineOk = false end
end
function NovaDraw.outlineColor(r, g, b, a)
    if not outlineOk then return end
    local ok = pcall(SetEntityDrawOutlineColor, r, g, b, a)
    if not ok then outlineOk = false end
end

local function camPos()
    return GetFinalRenderedCamCoord()
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- width: 1.0 = normal, larger = bolder; 0 = a plain one pixel line (use it when there are very many lines)
function NovaDraw.line(x1, y1, z1, x2, y2, z2, r, g, b, a, width)
    DrawLine(x1, y1, z1, x2, y2, z2, r, g, b, a or 255)
    width = width or 1.0
    if width <= 0.0 then return end
    local c = camPos()
    local mx, my, mz = (x1 + x2) * 0.5, (y1 + y2) * 0.5, (z1 + z2) * 0.5
    local dx, dy, dz = mx - c.x, my - c.y, mz - c.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    -- the offset grows with distance so the line keeps its thickness on screen
    local w = width * clamp(dist * 0.0032, 0.012, 0.16)
    a = a or 255
    DrawLine(x1 + w, y1, z1, x2 + w, y2, z2, r, g, b, a)
    DrawLine(x1 - w, y1, z1, x2 - w, y2, z2, r, g, b, a)
    DrawLine(x1, y1 + w, z1, x2, y2 + w, z2, r, g, b, a)
    DrawLine(x1, y1 - w, z1, x2, y2 - w, z2, r, g, b, a)
    DrawLine(x1, y1, z1 + w, x2, y2, z2 + w, r, g, b, a)
    DrawLine(x1, y1, z1 - w, x2, y2, z2 - w, r, g, b, a)
end

local BOX_EDGES = { { 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 }, { 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 } }

-- corners: table indexed 0..7 of anything with x, y, z (bit 0 = x side, bit 1 = y side, bit 2 = z side)
function NovaDraw.box(corners, r, g, b, a, width)
    for _, e in ipairs(BOX_EDGES) do
        local p, q = corners[e[1]], corners[e[2]]
        NovaDraw.line(p.x, p.y, p.z, q.x, q.y, q.z, r, g, b, a, width)
    end
end

-- A rectangle lying on the ground (pts = four { x, y } corners in order), z0 = its floor, height = corner posts (0 = none).
function NovaDraw.rect(pts, z0, height, r, g, b, fillAlpha, lineAlpha, width)
    local p1, p2, p3, p4 = pts[1], pts[2], pts[3], pts[4]
    local z = z0 + 0.04
    if (fillAlpha or 0) > 0 then
        -- both windings, so it is visible from above and from below
        DrawPoly(p1[1], p1[2], z, p2[1], p2[2], z, p3[1], p3[2], z, r, g, b, fillAlpha)
        DrawPoly(p3[1], p3[2], z, p2[1], p2[2], z, p1[1], p1[2], z, r, g, b, fillAlpha)
        DrawPoly(p1[1], p1[2], z, p3[1], p3[2], z, p4[1], p4[2], z, r, g, b, fillAlpha)
        DrawPoly(p4[1], p4[2], z, p3[1], p3[2], z, p1[1], p1[2], z, r, g, b, fillAlpha)
    end
    for i = 1, 4 do
        local a, c = pts[i], pts[i % 4 + 1]
        NovaDraw.line(a[1], a[2], z, c[1], c[2], z, r, g, b, lineAlpha or 255, width)
        if (height or 0) > 0 then
            NovaDraw.line(a[1], a[2], z0 + height, c[1], c[2], z0 + height, r, g, b, lineAlpha or 255, width)
            NovaDraw.line(a[1], a[2], z, a[1], a[2], z0 + height, r, g, b, lineAlpha or 255, width)
        end
    end
end

-- A name floating at a world position: bold text on a dark plate with an edge in the given colour.
-- opts.scale (default 0.38), opts.maxDist (default 350): further than that nothing is drawn
function NovaDraw.label(x, y, z, text, r, g, b, opts)
    opts = opts or {}
    local c = camPos()
    local dx, dy, dz = x - c.x, y - c.y, z - c.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > (opts.maxDist or 350.0) then return end
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    r, g, b = r or 255, g or 255, b or 255
    local scale = opts.scale or 0.38
    text = tostring(text)

    SetTextFont(4)
    SetTextScale(scale, scale)
    BeginTextCommandGetWidth('STRING')
    AddTextComponentSubstringPlayerName(text)
    local w = EndTextCommandGetWidth(true)
    local h = GetRenderedCharacterHeight(scale, 4)
    local padX, padY = 0.007, 0.004
    -- plate, then the coloured edge on its left, then the text
    DrawRect(sx, sy + h * 0.55, w + padX * 2.0, h + padY * 2.0, 10, 12, 18, 215)
    DrawRect(sx - (w + padX * 2.0) * 0.5, sy + h * 0.55, 0.0024, h + padY * 2.0, r, g, b, 255)

    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextCentre(true)
    SetTextColour(255, 255, 255, 255)
    SetTextProportional(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(sx, sy)
end
