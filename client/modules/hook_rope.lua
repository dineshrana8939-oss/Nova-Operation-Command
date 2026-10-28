-- ─── Nova Convoy — crane hook rope (client) ────────────────────────────────────
-- The crane's cable is a prop that cannot be shortened, so a rope built from props either hangs below the hook when
-- it is raised or has to vanish. This draws the rope instead: thick vertical lines from the underside of the crane
-- cabin straight down to the top of the spreader, so it is exactly as long as the hook is far from the cabin at
-- every height.
--
-- The server marks the spreader prop with the state bag 'cwRope' = { armTop = z of the cabin's underside };
-- every client that has that prop streamed in draws the rope. The tablet's crane test and /cwhooktest call
-- HookRope.set / HookRope.remove directly.
--
-- Tuning (Config.ContainerWars.hook.rope): width, color, anchors = { {x=,y=}, ... } offsets from the spreader's
-- origin in its own heading, bottomZ = height above the spreader's origin where the cables start.

HookRope = {}

local ropes = {}        -- [key] = { ent, armTop, anchors, bottom }
local running = false

local function ropeCfg()
    return (Config.ContainerWars and Config.ContainerWars.hook and Config.ContainerWars.hook.rope) or {}
end

-- Four corner anchors taken from the spreader's own size unless the config lists them.
local function buildAnchors(ent)
    local cfg = ropeCfg()
    local mn, mx = GetModelDimensions(GetEntityModel(ent))
    -- the cables end a little inside the roller blocks so there is no visible gap where they meet
    local bottom = tonumber(cfg.bottomZ) or ((mx and mx.z or 0.8) - (tonumber(cfg.sink) or 0.35))
    if type(cfg.anchors) == 'table' and #cfg.anchors > 0 then
        return cfg.anchors, bottom
    end
    local sx, sy = (mx.x - mn.x) / 2.0, (mx.y - mn.y) / 2.0
    local cx, cy = (mx.x + mn.x) / 2.0, (mx.y + mn.y) / 2.0
    local long, short = math.max(sx, sy), math.min(sx, sy)
    -- the yellow roller blocks the cables hang from sit about a third of the way out along the spreader's long axis
    local a, b = long * (tonumber(cfg.lengthFactor) or 0.43), math.max(short * 0.4, 0.25)
    if sx >= sy then
        return { { x = cx - a, y = cy - b }, { x = cx - a, y = cy + b }, { x = cx + a, y = cy - b }, { x = cx + a, y = cy + b } }, bottom
    end
    return { { x = cx - b, y = cy - a }, { x = cx + b, y = cy - a }, { x = cx - b, y = cy + a }, { x = cx + b, y = cy + a } }, bottom
end

local function ensureThread()
    if running then return end
    running = true
    CreateThread(function()
        while next(ropes) do
            local cfg = ropeCfg()
            local w = (tonumber(cfg.width) or 0.07) / 2.0
            local col = cfg.color or { 14, 14, 14 }
            local maxDist = tonumber(cfg.drawDistance) or 220.0
            local me = GetEntityCoords(PlayerPedId())
            local drew = false
            for key, r in pairs(ropes) do
                if not DoesEntityExist(r.ent) then
                    ropes[key] = nil
                else
                    local p = GetEntityCoords(r.ent)
                    if #(vector3(p.x, p.y, p.z) - me) < maxDist then
                        if not r.anchors then r.anchors, r.bottom = buildAnchors(r.ent) end
                        local h = math.rad(GetEntityHeading(r.ent))
                        local c, s = math.cos(h), math.sin(h)
                        local z0, z1 = p.z + r.bottom, r.armTop
                        if z1 > z0 + 0.05 then
                            for _, an in ipairs(r.anchors) do
                                local wx = p.x + an.x * c - an.y * s
                                local wy = p.y + an.x * s + an.y * c
                                DrawBox(wx - w, wy - w, z0, wx + w, wy + w, z1, col[1] or 14, col[2] or 14, col[3] or 14, 255)
                            end
                            drew = true
                        end
                    end
                end
            end
            Wait(drew and 0 or 250)
        end
        running = false
    end)
end

-- ent: the spreader prop (rope hangs from armTop down to its top). Safe to call again to update armTop.
function HookRope.set(key, ent, armTop)
    if not ent or ent == 0 or not armTop then return end
    local r = ropes[key]
    if r and r.ent == ent then
        r.armTop = armTop
    else
        ropes[key] = { ent = ent, armTop = armTop }
    end
    ensureThread()
end

function HookRope.remove(key)
    ropes[key] = nil
end

AddStateBagChangeHandler('cwRope', nil, function(bagName, _, value)
    if type(value) ~= 'table' or not value.armTop then
        HookRope.remove(bagName)
        return
    end
    CreateThread(function()
        local ent = 0
        local t0 = GetGameTimer()
        while GetGameTimer() - t0 < 8000 do
            ent = GetEntityFromStateBagName(bagName)
            if ent ~= 0 and DoesEntityExist(ent) then break end
            Wait(100)
        end
        if ent ~= 0 and DoesEntityExist(ent) then HookRope.set(bagName, ent, value.armTop) end
    end)
end)
