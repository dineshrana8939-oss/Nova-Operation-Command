-- ─── Nova Convoy — Operation Crackdown (client) ────────────────────────────────
-- The fighter's side of a Crackdown: the combat zone on the map and in the world, the live HUD (web/src/lib/hud/CrackdownHud.svelte),
-- the out-of-zone warning (the same overlay Rival Wars uses) and the report of "I went down" (who killed me) for the kill feed.
-- Everything shown comes from the server (nova_convoytruck:crackdown:client:*): eliminations are decided there, never here.
-- Nobody is teleported or frozen; normal damage, death and revive apply. The one rule enforced on this side: a fighter who was
-- ELIMINATED cannot fire inside the zone any more (they respawn / get revived like anyone, but they are out of the operation).

local cd = nil            -- { id, name, gang, gangLabel, side, zone, outsideSeconds, warning }
local zoneBlip, centerBlip = nil, nil
local startBlips = {}      -- the gang / police start areas on the map (only while the countdown runs)
local lastTick = nil
local eliminated = false
local session = 0         -- bumped on every start/stop so the loops of an old fight end themselves

local function clearBlips()
    if zoneBlip and DoesBlipExist(zoneBlip) then RemoveBlip(zoneBlip) end
    if centerBlip and DoesBlipExist(centerBlip) then RemoveBlip(centerBlip) end
    zoneBlip, centerBlip = nil, nil
    for _, b in ipairs(startBlips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    startBlips = {}
end

local function hideOverlays()
    SendNUIMessage({ action = 'territory:outOfBounds', active = false })
    SendNUIMessage({ action = 'crackdown:hide' })
end

local function stop()
    session = session + 1
    cd, lastTick, eliminated = nil, nil, false
    clearBlips()
    hideOverlays()
end

local function buildBlips(zone)
    clearBlips()
    local c = zone.center
    if zone.shape == 'square' then
        local s = (tonumber(zone.size) or 100.0) * 2.0
        zoneBlip = AddBlipForArea(c.x + 0.0, c.y + 0.0, (c.z or 0.0) + 0.0, s, s)
        SetBlipRotation(zoneBlip, 0)
    else
        zoneBlip = AddBlipForRadius(c.x + 0.0, c.y + 0.0, (c.z or 0.0) + 0.0, (tonumber(zone.radius) or 100.0) + 0.0)
    end
    SetBlipColour(zoneBlip, 5)
    SetBlipAlpha(zoneBlip, 90)
    SetBlipAsShortRange(zoneBlip, false)

    centerBlip = AddBlipForCoord(c.x + 0.0, c.y + 0.0, (c.z or 0.0) + 0.0)
    SetBlipSprite(centerBlip, 310)
    SetBlipColour(centerBlip, 5)
    SetBlipScale(centerBlip, 0.9)
    SetBlipAsShortRange(centerBlip, false)
    SetBlipFlashes(centerBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Operation Crackdown')
    EndTextCommandSetBlipName(centerBlip)
end

-- the zone's edge in the world: a tall translucent cylinder (circle) or four thin walls (square), drawn only when you are near it
local function drawZoneLoop(mySession)
    CreateThread(function()
        local zone = cd and cd.zone
        if not zone or not zone.center then return end
        local c = zone.center
        local reach = zone.shape == 'square' and ((tonumber(zone.size) or 100.0) * 1.5 + 60.0) or ((tonumber(zone.radius) or 100.0) + 70.0)
        while session == mySession do
            local p = GetEntityCoords(PlayerPedId())
            local d = #(vec3(p.x, p.y, 0.0) - vec3(c.x, c.y, 0.0))
            if d < reach then
                local z = (c.z or p.z) - 8.0
                if zone.shape == 'square' then
                    local h, t = tonumber(zone.size) or 100.0, 0.7
                    local top = z + 40.0
                    DrawBox(c.x - h, c.y - h, z, c.x + h, c.y - h + t, top, 255, 190, 40, 70)
                    DrawBox(c.x - h, c.y + h - t, z, c.x + h, c.y + h, top, 255, 190, 40, 70)
                    DrawBox(c.x - h, c.y - h, z, c.x - h + t, c.y + h, top, 255, 190, 40, 70)
                    DrawBox(c.x + h - t, c.y - h, z, c.x + h, c.y + h, top, 255, 190, 40, 70)
                else
                    local r = tonumber(zone.radius) or 100.0
                    DrawMarker(1, c.x + 0.0, c.y + 0.0, z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 40.0, 255, 190, 40, 60, false, false, 2, false, nil, nil, false)
                end
                Wait(0)
            else
                Wait(600)
            end
        end
    end)
end

-- ── start areas: a gang box (orange) and a police box (blue), drawn in the world and on the map during the countdown ──────────────
local AREA_STYLE = {
    gang   = { r = 255, g = 120, b = 20,  blip = 47, label = 'GANG START AREA' },
    police = { r = 50,  g = 130, b = 255, blip = 3,  label = 'POLICE START AREA' },
}

local function areaBounds(pts)
    local x1, y1, x2, y2, cx, cy = 1e9, 1e9, -1e9, -1e9, 0.0, 0.0
    for _, p in ipairs(pts) do
        x1, y1, x2, y2 = math.min(x1, p.x), math.min(y1, p.y), math.max(x2, p.x), math.max(y2, p.y)
        cx, cy = cx + p.x, cy + p.y
    end
    return x1, y1, x2, y2, cx / #pts, cy / #pts
end

local function buildStartBlips(zones)
    for _, key in ipairs({ 'gang', 'police' }) do
        local pts, st = zones[key], AREA_STYLE[key]
        if pts and #pts >= 3 then
            local x1, y1, x2, y2, cx, cy = areaBounds(pts)
            local cz = pts[1].z or 0.0
            local area = AddBlipForArea(((x1 + x2) / 2) + 0.0, ((y1 + y2) / 2) + 0.0, cz + 0.0, (x2 - x1) + 0.0, (y2 - y1) + 0.0)
            SetBlipRotation(area, 0)
            SetBlipColour(area, st.blip)
            SetBlipAlpha(area, 110)
            startBlips[#startBlips + 1] = area
            local pin = AddBlipForCoord(cx + 0.0, cy + 0.0, cz + 0.0)
            SetBlipSprite(pin, 1)
            SetBlipColour(pin, st.blip)
            SetBlipScale(pin, 0.9)
            SetBlipAsShortRange(pin, false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(st.label)
            EndTextCommandSetBlipName(pin)
            startBlips[#startBlips + 1] = pin
        end
    end
end

local function drawText3d(x, y, z, text, r, g, b)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.4, 0.4); SetTextFont(4); SetTextProportional(true)
    SetTextColour(r, g, b, 230); SetTextCentre(true); SetTextOutline()
    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(text); EndTextCommandDisplayText(sx, sy)
end

local function drawStartAreas(mySession)
    CreateThread(function()
        local zones = cd and cd.startZones
        if not zones then return end
        while session == mySession and lastTick and lastTick.phase == 'PREP' do
            local pc = GetEntityCoords(PlayerPedId())
            local anyNear = false
            for _, key in ipairs({ 'gang', 'police' }) do
                local pts, st = zones[key], AREA_STYLE[key]
                if pts and #pts >= 3 then
                    local _, _, _, _, cx, cy = areaBounds(pts)
                    local near = #(vec3(pc.x, pc.y, 0.0) - vec3(cx, cy, 0.0)) < 400.0
                    if near then
                        anyNear = true
                        local n, drawn = #pts, 0
                        for i = 1, n do
                            local a, c = pts[i], pts[i % n + 1]
                            drawn = drawn + 1
                            if drawn > 24 then break end
                            local z0, z1 = (a.z or pc.z) - 0.5, (a.z or pc.z) + 6.0
                            local cz0, cz1 = (c.z or pc.z) - 0.5, (c.z or pc.z) + 6.0
                            DrawPoly(a.x, a.y, z0, c.x, c.y, cz0, a.x, a.y, z1, st.r, st.g, st.b, 55)
                            DrawPoly(c.x, c.y, cz0, c.x, c.y, cz1, a.x, a.y, z1, st.r, st.g, st.b, 55)
                            DrawPoly(a.x, a.y, z1, c.x, c.y, cz0, a.x, a.y, z0, st.r, st.g, st.b, 55)
                            DrawPoly(a.x, a.y, z1, c.x, c.y, cz1, c.x, c.y, cz0, st.r, st.g, st.b, 55)
                            DrawLine(a.x, a.y, z1, c.x, c.y, cz1, st.r, st.g, st.b, 235)
                            DrawLine(a.x, a.y, z0, c.x, c.y, cz0, st.r, st.g, st.b, 235)
                        end
                        drawText3d(cx, cy, (pts[1].z or pc.z) + 8.0, st.label, st.r, st.g, st.b)
                    end
                end
            end
            Wait(anyNear and 0 or 500)
        end
    end)
end

-- an eliminated fighter cannot shoot while inside (or at the edge of) the zone — nothing else is done to them
local function disarmLoop(mySession)
    CreateThread(function()
        local zone = cd and cd.zone
        if not zone or not zone.center then return end
        local c = zone.center
        local reach = (zone.shape == 'square' and ((tonumber(zone.size) or 100.0) * 1.5) or (tonumber(zone.radius) or 100.0)) + 5.0
        while session == mySession do
            if eliminated then
                local p = GetEntityCoords(PlayerPedId())
                if #(vec3(p.x, p.y, 0.0) - vec3(c.x, c.y, 0.0)) <= reach then
                    DisablePlayerFiring(PlayerId(), true)
                    DisableControlAction(0, 24, true)  -- attack
                    DisableControlAction(0, 25, true)  -- aim
                    DisableControlAction(0, 140, true) -- melee
                    DisableControlAction(0, 141, true)
                    DisableControlAction(0, 142, true)
                    Wait(0)
                else
                    Wait(500)
                end
            else
                Wait(500)
            end
        end
    end)
end

-- "I went down": tell the server once per death and who the game says killed me (a player, or the driver of the vehicle that hit me)
local function deathLoop(mySession)
    CreateThread(function()
        local reported = false
        while session == mySession do
            local ped = PlayerPedId()
            if IsEntityDead(ped) then
                if not reported then
                    reported = true
                    local killer = nil
                    local ent = GetPedSourceOfDeath(ped)
                    if ent and ent ~= 0 then
                        if IsEntityAVehicle(ent) then ent = GetPedInVehicleSeat(ent, -1) end
                        if ent and ent ~= 0 and IsEntityAPed(ent) and IsPedAPlayer(ent) then
                            local idx = NetworkGetPlayerIndexFromPed(ent)
                            if idx and idx ~= -1 then killer = GetPlayerServerId(idx) end
                        end
                    end
                    if cd then TriggerServerEvent('nova_convoytruck:crackdown:server:died', cd.id, killer) end
                end
            else
                reported = false
            end
            Wait(250)
        end
    end)
end

RegisterNetEvent('nova_convoytruck:crackdown:client:state', function(payload)
    if type(payload) ~= 'table' or not payload.zone then return end
    stop()
    cd = payload
    local my = session
    buildBlips(cd.zone)
    drawZoneLoop(my)
    if payload.startZones then buildStartBlips(payload.startZones) end
    deathLoop(my)
    disarmLoop(my)
    SendNUIMessage({ action = 'crackdown:state', data = payload })
end)

RegisterNetEvent('nova_convoytruck:crackdown:client:tick', function(data)
    if not cd or type(data) ~= 'table' or data.id ~= cd.id then return end
    local firstTick = lastTick == nil
    lastTick = data
    eliminated = data.eliminated == true
    if firstTick and data.phase == 'PREP' then drawStartAreas(session) end
    -- the fight is on: the start areas have done their job
    if data.phase ~= 'PREP' and #startBlips > 0 then
        for _, b in ipairs(startBlips) do if DoesBlipExist(b) then RemoveBlip(b) end end
        startBlips = {}
    end
    SendNUIMessage({ action = 'crackdown:tick', data = data })
    -- outside the zone while the fight is on: the same warning overlay Rival Wars uses (the countdown comes from the server)
    if data.outsideLeft ~= nil then
        SendNUIMessage({
            action = 'territory:outOfBounds', active = true, secondsLeft = data.outsideLeft, maxSeconds = cd.outsideSeconds,
            title = 'WARNING: OUT OF THE COMBAT ZONE!', subtitle = 'Get back inside or you are eliminated from the operation',
        })
        PlaySoundFrontend(-1, 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS', true)
    else
        SendNUIMessage({ action = 'territory:outOfBounds', active = false })
    end
end)

RegisterNetEvent('nova_convoytruck:crackdown:client:end', function(data)
    data = data or {}
    if cd and data.id and data.id ~= cd.id then return end
    local silent = data.silent
    stop()
    if not silent then
        SendNUIMessage({ action = 'crackdown:end', data = data })
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then stop() end
end)
