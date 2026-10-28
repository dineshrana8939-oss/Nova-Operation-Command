-- ─── Checkpoint beacon (client) ───────────────────────────────────────────────────
-- A tall pillar of light from the sky down onto each convoy checkpoint, with a burst ring on the ground where it lands
-- and energy rings rippling out from the base — so the spot the convoy will stop on can be seen in the world, from
-- far away, not only on the map. Purely visual; the server decides who gets which beacon (Config.CheckpointBeacon).
--
--   checkpointBeacons  list of every checkpoint {id,x,y,z,radius}   — sent to police/admins at departure
--   checkpointStart    the checkpoint the convoy is holding at        — that one lights up red for everyone taking part
--   checkpointEnd / hideAll                                            — beacon removed / everything cleared

local beacons = {}   -- id -> { x, y, z, radius, active = bool, gz = ground z or nil, gzAt = ms }

local function cfg() return Config.CheckpointBeacon or {} end
local function enabled() return cfg().enabled ~= false end

local function colour(c, fallback)
    c = type(c) == 'table' and c or fallback
    return c.r or fallback.r, c.g or fallback.g, c.b or fallback.b
end

local IDLE = { r = 255, g = 215, b = 0 }   -- Radiant Dragon Ball Gold
local HOT  = { r = 255, g = 180, b = 20 }  -- Super Saiyan Vibrant Gold Aura

local function addBeacon(id, x, y, z, radius, active)
    beacons[id] = { x = x + 0.0, y = y + 0.0, z = z + 0.0, radius = tonumber(radius) or 40.0, active = active == true }
end

-- the beacon already standing within a few metres of these coordinates (the active checkpoint is also in the
-- full list the police got at departure — it must light up, not double up)
local function beaconAt(x, y)
    for id, b in pairs(beacons) do
        local dx, dy = b.x - x, b.y - y
        if dx * dx + dy * dy <= 100.0 then return id, b end
    end
    return nil
end

RegisterNetEvent('nova_convoytruck:runtime:checkpointBeacons', function(list)
    if not enabled() then return end
    beacons = {}
    for _, z in ipairs(list or {}) do
        if z.x and z.y and z.z then addBeacon('cp:' .. tostring(z.id or (#beacons + 1)), z.x, z.y, z.z, z.radius, false) end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:checkpointStart', function(_, _, _, coords, radius)
    if not enabled() or not coords then return end
    local id, b = beaconAt(coords.x, coords.y)
    if b then
        b.active = true
        b.radius = tonumber(radius) or b.radius
    else
        addBeacon('live', coords.x, coords.y, coords.z, radius, true)
    end
end)

-- the checkpoint is cleared: its beacon goes out (the next one stays as it was)
RegisterNetEvent('nova_convoytruck:runtime:checkpointEnd', function()
    for id, b in pairs(beacons) do
        if b.active then beacons[id] = nil end
    end
end)

RegisterNetEvent('nova_convoytruck:runtime:hideAll', function()
    beacons = {}
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then beacons = {} end
end)

-- the real ground under the beacon (route points are saved at about player height, not at the road)
local function groundZ(b, playerPos)
    local now = GetGameTimer()
    if b.gz and now - (b.gzAt or 0) < 15000 then return b.gz end
    if #(vector3(b.x, b.y, b.z) - playerPos) > 350.0 then return b.gz or (b.z - 1.0) end   -- collision is not loaded out there
    local ok, gz = GetGroundZFor_3dCoord(b.x, b.y, b.z + 20.0, false)
    b.gzAt = now
    if ok and gz then b.gz = gz else b.gz = b.gz or (b.z - 1.0) end
    return b.gz
end

local function drawBeacon(b, t, playerPos)
    local c = cfg()
    local cr, cg, cb
    if b.active then cr, cg, cb = colour(c.activeColor, HOT) else cr, cg, cb = colour(c.color, IDLE) end
    local H = tonumber(c.beamHeight) or 600.0
    -- Refined, slimmer beam width (default 2.4m instead of heavy 7.0m) for sleek golden beam descent
    local W = math.min(tonumber(c.beamWidth) or 2.4, 4.0)
    local z = groundZ(b, playerPos)
    local pulse = 0.5 + 0.5 * math.sin(t * (b.active and 3.5 or 2.0))   -- 0..1 smooth golden aura pulse

    -- ── 1. Vertical golden energy pillar descending from the sky ──
    local base = z - 2.0
    -- Soft outer golden glow aura
    DrawMarker(1, b.x, b.y, base, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, W * 1.6, W * 1.6, H, cr, cg, cb, math.floor(25 + 12 * pulse), false, false, 2, false, nil, nil, false)
    -- Sleek golden core pillar
    DrawMarker(1, b.x, b.y, base, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, W * 0.85, W * 0.85, H, cr, cg, cb, math.floor(55 + 25 * pulse), false, false, 2, false, nil, nil, false)
    -- Refined bright gold-amber center filament
    DrawMarker(1, b.x, b.y, base, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, W * 0.28, W * 0.28, H, 255, 245, 180, math.floor(130 + 40 * pulse), false, false, 2, false, nil, nil, false)

    -- ── 2. Checkpoint Ground Zone (Golden Ring & Aura Ripples) ──
    local r = b.radius
    -- Perimeter boundary ring (slender, crisp golden line)
    DrawMarker(25, b.x, b.y, z + 0.08, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 0.6, cr, cg, cb, math.floor(95 + 30 * pulse), false, false, 2, false, nil, nil, false)
    -- Inner parking focal spot
    local stop = (tonumber((Config.CheckpointRelease or {}).parkRadius) or 12.0) * 2.0
    DrawMarker(1, b.x, b.y, z - 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, stop, stop, 0.35, cr, cg, cb, math.floor(35 + 20 * pulse), false, false, 2, false, nil, nil, false)
    -- Expanding golden Dragon Ball energy wave ripples
    for k = 0, 1 do
        local ph = (t * 0.45 + k * 0.5) % 1.0
        local s = W + ph * math.min(r * 1.3, 60.0)
        -- Ripple in warm gold rather than stark white, with delicate opacity fade
        DrawMarker(25, b.x, b.y, z + 0.12, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, s, s, 0.5, 255, 220, 60, math.floor(110 * (1.0 - ph)), false, false, 2, false, nil, nil, false)
    end
    -- Warm golden ambient spotlight illumination
    DrawLightWithRange(b.x, b.y, z + 2.5, cr, cg, cb, 22.0, 1.8 + 1.2 * pulse)
end

CreateThread(function()
    while true do
        if next(beacons) and enabled() then
            local playerPos = GetEntityCoords(PlayerPedId())
            local maxD = tonumber(cfg().drawDistance) or 1500.0
            local t = GetGameTimer() / 1000.0
            local sleep = 500
            for _, b in pairs(beacons) do
                local dx, dy = b.x - playerPos.x, b.y - playerPos.y
                if dx * dx + dy * dy <= maxD * maxD then
                    sleep = 0
                    drawBeacon(b, t, playerPos)
                end
            end
            Wait(sleep)
        else
            Wait(1000)
        end
    end
end)
