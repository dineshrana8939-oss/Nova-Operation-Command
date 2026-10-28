-- ─── Nova Convoy — Vehicle Showroom (client) ──────────────────────────────────────
-- One showroom for the shops that hand out vehicles: the Race Token Exchange and the Police Escort Vehicle Shop.
-- It opens a list panel on the left of the screen (web/src/lib/showroom/Showroom.svelte) and swings the camera round
-- to face the shop ped from the front, offset so the ped stands in the open right-hand part of the screen.
-- The shops only say WHAT is for sale and what buying / returning does; this file owns the camera, the player and the NUI.
--
--   Showroom.open({
--     shop      = 'tokens' | 'escort',
--     title, subtitle, pedName,
--     loc       = { x, y, z, heading }        where the ped stands (z = the ped's middle, as saved)
--     wallet    = { kind = 'tokens', amount = n, hint = '…' } | { kind = 'convoy', label = '…', note = '…' }
--     vehicles  = { { label, model, tokens | price }, … }
--     checkedOut = bool                       (escort shop: the player already holds a vehicle → shows "Return")
--     onBuy     = function(index, account) -> { ok, message | error, tokens? }
--     onReturn  = function() -> { ok, message | error }
--   })

Showroom = {}

local active = nil   -- { cam, hidden state, onBuy, onReturn, vehicles }

-- ── what a vehicle looks like in the list: its type and four stat bars from the game's own handling data ──────────────
local function clamp01(v) return math.max(0.0, math.min(1.0, v)) end
local function pct(v, lo, hi) return math.floor(8 + 92 * clamp01((v - lo) / (hi - lo))) end

local TYPE_CATEGORY = { bike = 'Bikes', car = 'Cars', suv = 'SUVs', truck = 'Heavy' }

local function vehicleInfo(model)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then return { missing = true, type = 'car', category = 'Cars', stats = { 0, 0, 0, 0 } } end
    local class = GetVehicleClassFromName(hash)
    local mn, mx = GetModelDimensions(hash)
    local length, height = (mx.y - mn.y), (mx.z - mn.z)
    local t = 'car'
    if class == 8 or class == 13 then t = 'bike'
    elseif length >= 6.2 or class == 10 or class == 11 or class == 17 or class == 19 or class == 20 then t = 'truck'
    elseif height >= 2.0 or class == 2 or class == 9 or class == 12 then t = 'suv' end
    return {
        type = t, category = TYPE_CATEGORY[t],
        stats = {
            pct(GetVehicleModelEstimatedMaxSpeed(hash), 18.0, 62.0),   -- top speed
            pct(GetVehicleModelAcceleration(hash), 0.10, 0.45),        -- acceleration
            pct(GetVehicleModelMaxBraking(hash), 0.30, 1.40),          -- braking
            pct(GetVehicleModelMaxTraction(hash), 1.40, 2.90),         -- handling
        },
    }
end

local function buildList(vehicles)
    local out = {}
    for i, v in ipairs(vehicles or {}) do
        local info = vehicleInfo(v.model)
        out[#out + 1] = {
            index = i, label = v.label or v.model, model = v.model,
            tokens = tonumber(v.tokens), price = tonumber(v.price) or 0,
            type = info.type, category = info.category, stats = info.stats, missing = info.missing == true,
        }
    end
    return out
end

-- ── the camera: in front of the ped, looking at it, shifted so it stands in the free part of the screen ──────────────
local DIST, FOV = 2.4, 40.0                            -- close: frames the ped from the hips up to the top of the head
local PED_SCREEN_X = 0.60                               -- where across the screen the ped stands (0 = left edge, 1 = right edge)
local function setupCamera(loc)
    local h = math.rad(loc.heading or 0.0)
    local fx, fy = -math.sin(h), math.cos(h)            -- the way the ped faces
    local cx, cy, cz = loc.x + fx * DIST, loc.y + fy * DIST, loc.z + 0.25
    -- aim to the left of the ped (from the camera's point of view) so the ped lands in the free right-hand part of the screen.
    -- The camera looks along (-fx, -fy), so its right-hand side is (-fy, fx).
    local rx, ry = -fy, fx
    local width = 2.0 * DIST * math.tan(math.rad(FOV) / 2.0) * GetAspectRatio(false)   -- metres across the screen at the ped
    local shift = (PED_SCREEN_X - 0.5) * width
    local ax, ay, az = loc.x - rx * shift, loc.y - ry * shift, loc.z + 0.2     -- aim at the chest: hips at the bottom edge, face in the upper third
    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', cx, cy, cz, 0.0, 0.0, 0.0, FOV, false, 2)
    PointCamAtCoord(cam, ax, ay, az)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 900, true, false)       -- eases from where the player is looking to the ped
    return cam
end

function Showroom.isOpen() return active ~= nil end

-- instant = true: cut straight back to the game view (used while the screen is faded out for a claim)
function Showroom.close(instant)
    if not active then return end
    local a = active
    active = nil
    SendNUIMessage({ action = 'showroom:close' })
    SetNuiFocus(false, false)
    RenderScriptCams(false, not instant, instant and 0 or 600, true, false)
    if a.cam then
        local cam = a.cam
        SetTimeout(instant and 100 or 700, function() if DoesCamExist(cam) then DestroyCam(cam, false) end end)
    end
    local me = PlayerPedId()
    FreezeEntityPosition(me, false)
    SetEntityVisible(me, true, false)
    SetEntityInvincible(me, a.wasInvincible == true)
    DisplayRadar(a.hadRadar ~= false)
    DisplayHud(true)
end

function Showroom.open(opts)
    if active or not opts or not opts.loc then return end
    local me = PlayerPedId()
    active = {
        cam = nil, shop = opts.shop, vehicles = opts.vehicles or {}, onBuy = opts.onBuy, onReturn = opts.onReturn, loc = opts.loc,
        wasInvincible = GetPlayerInvincible(PlayerId()), hadRadar = not IsRadarHidden(),
    }
    -- the player stays where they are, safe and out of the shot, while the camera moves
    FreezeEntityPosition(me, true)
    SetEntityInvincible(me, true)
    SetEntityVisible(me, false, false)
    DisplayRadar(false)
    DisplayHud(false)
    active.cam = setupCamera(opts.loc)

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'showroom:open',
        shop = opts.shop, title = opts.title, subtitle = opts.subtitle, pedName = opts.pedName,
        wallet = opts.wallet, checkedOut = opts.checkedOut == true,
        vehicles = buildList(opts.vehicles),
    })

    CreateThread(function()
        -- once the camera has settled, tell the UI where the ped's head is on screen so the speech bubble sits above it
        Wait(950)
        if active then
            local ok, sx, sy = GetScreenCoordFromWorldCoord(opts.loc.x, opts.loc.y, opts.loc.z + 0.7)
            if ok and sx >= 0.0 then SendNUIMessage({ action = 'showroom:pedScreen', x = sx, y = sy }) end
        end
        -- no walking, shooting or menus while it is open; closes if the player is hurt / dies / the shop goes away
        while active do
            Wait(0)
            DisableAllControlActions(0)
            DisableAllControlActions(1)
            if IsEntityDead(PlayerPedId()) then Showroom.close() end
        end
    end)
end

-- ── claiming: a clear, safe spot close to the shop, and the player moved there together with the vehicle ────────────
local MAX_SPOT_DISTANCE = 40.0      -- never further than this from the shop ("not too far")

local function occupied(x, y, z, r)
    return IsPositionOccupied(x, y, z, r, false, true, true, false, false, 0, false)
end

local function inWater(x, y, z)
    local isWater, h = GetWaterHeight(x, y, z)
    return isWater and h > z - 0.5
end

-- A spot the vehicle can stand on and drive away from: a nearby road lane if there is a clear one (facing along the road),
-- otherwise open ground on a ring round the shop (facing away from it). Always within MAX_SPOT_DISTANCE of the shop.
function Showroom.safeSpot(loc)
    local origin = vector3(loc.x, loc.y, loc.z)
    local function clear(x, y, z)
        return #(vector3(x, y, z) - origin) <= MAX_SPOT_DISTANCE and not occupied(x, y, z + 0.6, 3.4) and not inWater(x, y, z)
    end
    -- 1) the nearest clear road lanes
    for n = 1, 12 do
        local ok, pos, heading = GetNthClosestVehicleNodeWithHeading(loc.x, loc.y, loc.z, n, 1, 3.0, 0)
        if ok and pos then
            if #(pos - origin) > MAX_SPOT_DISTANCE then break end        -- they only get further from here
            if clear(pos.x, pos.y, pos.z) then return { x = pos.x, y = pos.y, z = pos.z, heading = heading or 0.0 } end
        end
    end
    -- 2) open ground on rings round the shop
    for _, r in ipairs({ 7.0, 10.0, 14.0, 19.0, 25.0 }) do
        for k = 0, 11 do
            local a = (k / 12.0) * math.pi * 2.0
            local x, y = loc.x + math.cos(a) * r, loc.y + math.sin(a) * r
            RequestCollisionAtCoord(x, y, loc.z)
            local found, gz = GetGroundZFor_3dCoord(x, y, loc.z + 3.0, false)
            if found and math.abs(gz - (loc.z - 1.0)) < 4.0 and clear(x, y, gz) then
                return { x = x, y = y, z = gz, heading = (math.deg(a) - 90.0) % 360.0 }   -- pointing away from the shop
            end
        end
    end
    -- 3) nothing clear found: just in front of the ped
    local h = math.rad(loc.heading or 0.0)
    return { x = loc.x - math.sin(h) * 6.0, y = loc.y + math.cos(h) * 6.0, z = loc.z - 1.0, heading = loc.heading or 0.0 }
end

-- Fades out, cuts back to the game view, puts the player at `spot`, lets `makeVehicle(spot)` create the vehicle there (it
-- returns the vehicle entity) and seats the player in it, then fades back in. `makeVehicle` may be nil when the SERVER has
-- already created the vehicle and moved the player (escort vehicles) — then this only does the fade and the cut.
function Showroom.claim(spot, makeVehicle)
    DoScreenFadeOut(250)
    local t = GetGameTimer() + 600
    while not IsScreenFadedOut() and GetGameTimer() < t do Wait(0) end
    Showroom.close(true)
    local me = PlayerPedId()
    if makeVehicle then
        SetEntityCoordsNoOffset(me, spot.x + 0.0, spot.y + 0.0, spot.z + 1.0, false, false, false)
        RequestCollisionAtCoord(spot.x + 0.0, spot.y + 0.0, spot.z + 0.0)
        local c = GetGameTimer() + 1500
        while not HasCollisionLoadedAroundEntity(me) and GetGameTimer() < c do Wait(50) end
        local veh = makeVehicle(spot)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            SetPedIntoVehicle(me, veh, -1)
        end
    else
        Wait(350)       -- the server is placing the player in the vehicle it just created
    end
    DoScreenFadeIn(400)
end

-- The player is held still while the showroom is open. A claim that the SERVER completes (it moves the player) needs the
-- player free for that moment: release before asking, hold again if the server said no.
function Showroom.releasePlayer() if active then FreezeEntityPosition(PlayerPedId(), false) end end
function Showroom.holdPlayer() if active then FreezeEntityPosition(PlayerPedId(), true) end end

-- ── NUI → game ───────────────────────────────────────────────────────────────────────────────────────────────────
RegisterNUICallback('showroom:close', function(_, cb)
    Showroom.close()
    cb('ok')
end)

RegisterNUICallback('showroom:buy', function(data, cb)
    if not active or not active.onBuy then cb({ ok = false, error = 'The shop is closed.' }) return end
    local ok, res = pcall(active.onBuy, tonumber(data and data.index), data and data.account)
    cb(ok and res or { ok = false, error = 'Something went wrong — try again.' })
end)

RegisterNUICallback('showroom:return', function(_, cb)
    if not active or not active.onReturn then cb({ ok = false, error = 'Nothing to return.' }) return end
    local ok, res = pcall(active.onReturn)
    cb(ok and res or { ok = false, error = 'Something went wrong — try again.' })
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    Showroom.close()
end)
