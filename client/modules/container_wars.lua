-- ─── Nova Convoy — Container Wars Live Event (client) ─────────────────────────
-- Client-side handler for Container Wars harbour auction event:
-- Bidding zone polyzone, 3D world billboard, winning bid visual effects,
-- sound feedback, [E] bidding input dialog, and crate claim target interaction.

local activeEvent = nil
local biddingZone = nil
local inBiddingZone = false
local containersState = {} -- [containerId] = state
local eventBlip = nil
local rewardBlips = {}        -- [containerId] = flashing blip on an unclaimed reward car (this player won it)
local function clearRewardBlips(id)
    for k, b in pairs(rewardBlips) do
        if id == nil or k == id then
            if DoesBlipExist(b) then RemoveBlip(b) end
            rewardBlips[k] = nil
        end
    end
end
local eventRadiusBlip = nil
local zonePoints = nil        -- resolved {x,y,z} perimeter of the running event
local previewPoints = nil     -- perimeter being previewed from the tablet
local previewBlip = nil
local previewSpots = nil      -- numbered spawn spots shown with it (TDM team bases, the spawn dots): { { x, y, z, heading } }
local hiddenWorldObjects = {} -- map containers hidden for the event: { x, y, z, radius, hash }
-- What the auction is doing right now, for the zone timer and the container tags:
--   NEXT   { endsAt, n, name }  waiting for the crane to bring container n (endsAt = local game timer in ms)
--   DELIVERING { n, name }      the crane is carrying it
--   BIDSOON { endsAt, n, name } it has landed (closed); bidding opens at endsAt
--   BIDDING { id }              an auction is running (its own clock is containersState[id].timeRemaining)
--   IDLE
local cwFlow = { kind = 'IDLE' }
local activeContainerId = nil -- only ONE container has the Container Top UI attached at any time

-- Model strings are names ('prop_container_05a') or 'hash:<number>' for a map
-- container picked in the placer whose name could not be matched.
local function modelHashOf(model)
    local n = type(model) == 'string' and tonumber(model:match('^hash:(%-?%d+)$'))
    return n or joaat(model or 'prop_container_05a')
end

-- Perimeter points always have a usable height: saved z when set, else the
-- fallback (first container's drop, then the crane, then a harbour default).
-- With z = 0 the 3D polygon sat far below the ground and nobody was ever "inside".
local function resolvePerimeter(points, fallbackZ)
    local out = {}
    for _, p in ipairs(points or {}) do
        local z = tonumber(p.z)
        if not z or math.abs(z) < 0.01 then z = fallbackZ end
        out[#out + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = z }
    end
    return out
end

local function fallbackZOf(data)
    local c1 = data and data.containers and data.containers[1]
    return (c1 and c1.dropCoords and tonumber(c1.dropCoords.z))
        or (data and data.crane and tonumber(data.crane.z))
        or 6.0
end

-- Draws the perimeter as a translucent wall with bright top/bottom edges.
-- preview = true (tablet "Preview in game"): the admin is usually far from the zone, so no distance culling and a tall wall.
local function drawPerimeter(pts, r, g, b, preview)
    -- Draw budget: every edge costs ~7 draw calls per frame, and a perimeter recorded by
    -- walking can have a lot of points. Edges far from the player are skipped and the
    -- total is capped, so a big or dense perimeter can never flood the draw buffer.
    local MAX_EDGES, MAX_RANGE = preview and 64 or 40, preview and 1.0e9 or 220.0
    local wallTop = preview and 120.0 or 3.5
    local pc = GetEntityCoords(cache.ped or PlayerPedId())
    local n = #pts
    local drawn = 0
    for i = 1, n do
        local a = pts[i]
        local c = pts[i % n + 1]
        if #(vec3(pc.x, pc.y, 0.0) - vec3(a.x, a.y, 0.0)) < MAX_RANGE or #(vec3(pc.x, pc.y, 0.0) - vec3(c.x, c.y, 0.0)) < MAX_RANGE then
            drawn = drawn + 1
            if drawn > MAX_EDGES then break end
            local az0, az1, cz0, cz1 = a.z - 0.5, a.z + wallTop, c.z - 0.5, c.z + wallTop
            -- both windings so the wall shows from either side
            DrawPoly(a.x, a.y, az0, c.x, c.y, cz0, a.x, a.y, az1, r, g, b, 45)
            DrawPoly(c.x, c.y, cz0, c.x, c.y, cz1, a.x, a.y, az1, r, g, b, 45)
            DrawPoly(a.x, a.y, az1, c.x, c.y, cz0, a.x, a.y, az0, r, g, b, 45)
            DrawPoly(a.x, a.y, az1, c.x, c.y, cz1, c.x, c.y, cz0, r, g, b, 45)
            DrawLine(a.x, a.y, az1, c.x, c.y, cz1, r, g, b, 235)
            DrawLine(a.x, a.y, az0, c.x, c.y, cz0, r, g, b, 235)
            DrawLine(a.x, a.y, az0, a.x, a.y, az1, r, g, b, 235)
        end
    end
end

CreateThread(function()
    while true do
        local pts = previewPoints or (activeEvent and zonePoints)
        if pts and #pts >= 3 then
            local pc = GetEntityCoords(cache.ped or PlayerPedId())
            local visDist = (Config.ContainerWars and Config.ContainerWars.visuals and Config.ContainerWars.visuals.drawDistance) or 75.0
            local drawRange = math.max(120.0, visDist + 50.0)
            if previewPoints or inBiddingZone or #(vec3(pc.x, pc.y, pts[1].z) - vec3(pts[1].x, pts[1].y, pts[1].z)) < drawRange then
                if inBiddingZone and not previewPoints then
                    drawPerimeter(pts, 70, 214, 154)   -- inside: green
                else
                    drawPerimeter(pts, 56, 189, 248, previewPoints ~= nil)   -- outside / preview: sky blue
                end
                Wait(0)
            else
                Wait(500)
            end
        else
            Wait(1000)
        end
    end
end)

-- numbered spawn spots (the spawn dots / the spread of a team inside its base perimeter), drawn only while a preview runs
CreateThread(function()
    while true do
        local spots = previewSpots
        if spots and #spots > 0 then
            for i, p in ipairs(spots) do
                DrawMarker(1, p.x, p.y, p.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.9, 0.9, 0.12, 255, 215, 0, 140, false, false, 2, false, nil, nil, false)
                DrawMarker(2, p.x, p.y, p.z + 0.25, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.3, 0.3, 0.3, 255, 215, 0, 230, false, false, 2, true, nil, nil, false)
                local on, sx, sy = World3dToScreen2d(p.x, p.y, p.z + 0.75)
                if on then
                    SetTextScale(0.28, 0.28); SetTextFont(4); SetTextProportional(true)
                    SetTextColour(255, 255, 255, 235); SetTextCentre(true); SetTextOutline()
                    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName('#' .. i); EndTextCommandDisplayText(sx, sy)
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- Finding the preview: the admin usually stands far from the area, so a tall beam stands on its middle, a map blip marks it, and the
-- screen says how far away it is and in which direction (arrows when it is behind you).
local function previewAids()
    local pts = previewPoints or previewSpots
    if not pts or #pts < 1 then return end
    local cx, cy, cz = 0.0, 0.0, 0.0
    for _, p in ipairs(pts) do cx, cy, cz = cx + p.x, cy + p.y, cz + p.z end
    cx, cy, cz = cx / #pts, cy / #pts, cz / #pts
    previewBlip = AddBlipForCoord(cx + 0.0, cy + 0.0, cz + 0.0)
    SetBlipSprite(previewBlip, 1)
    SetBlipColour(previewBlip, 3)
    SetBlipScale(previewBlip, 1.1)
    SetBlipFlashes(previewBlip, true)
    SetBlipAsShortRange(previewBlip, false)
    BeginTextCommandSetBlipName('STRING'); AddTextComponentSubstringPlayerName('Previewed area'); EndTextCommandSetBlipName(previewBlip)
    CreateThread(function()
        while (previewPoints or previewSpots) == pts do
            for k = -2, 2 do
                DrawLine(cx + k * 0.4, cy, cz, cx + k * 0.4, cy, cz + 600.0, 56, 189, 248, 255)
                DrawLine(cx, cy + k * 0.4, cz, cx, cy + k * 0.4, cz + 600.0, 56, 189, 248, 255)
            end
            local me = GetEntityCoords(PlayerPedId())
            local dist = #(vec3(me.x, me.y, 0.0) - vec3(cx, cy, 0.0))
            local on, sx, sy = World3dToScreen2d(cx, cy, cz + 12.0)
            local label
            if dist < 25.0 then
                label = 'YOU ARE INSIDE THE PREVIEWED AREA'
            else
                local dx, dy = cx - me.x, cy - me.y
                local brg = (math.deg(math.atan2(dx, dy)) + 360.0) % 360.0
                local names = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
                label = ('PREVIEWED AREA: %d m %s'):format(math.floor(dist), names[(math.floor((brg + 22.5) / 45.0) % 8) + 1])
            end
            SetTextScale(0.45, 0.45); SetTextFont(4); SetTextProportional(true)
            SetTextColour(255, 255, 255, 240); SetTextCentre(true); SetTextOutline()
            BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(label)
            if on then EndTextCommandDisplayText(sx, sy) else EndTextCommandDisplayText(0.5, 0.12) end
            Wait(0)
        end
    end)
end

-- Shared by every "Preview" button on a perimeter or on spawn spots: hides the tablet, shows the preview, back on Enter / Backspace.
local function runPreview(cb, title, info)
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    previewAids()
    NovaConvoy.ShowKeyHelp(title, { { { 'Enter / Backspace', 'RETURN to the tablet' } } }, { info = info, icon = 'draw-polygon' })
    CreateThread(function()
        Wait(400)
        while previewPoints or previewSpots do
            Wait(0)
            if IsControlJustPressed(0, 191) or IsControlJustPressed(0, 177) or IsControlJustPressed(0, 200) then break end
        end
        previewPoints, previewSpots = nil, nil
        if previewBlip and DoesBlipExist(previewBlip) then RemoveBlip(previewBlip) end
        previewBlip = nil
        lib.hideTextUI()
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
        cb({ ok = true })
    end)
end

-- Tablet "Preview perimeter": the polygon as a tall wall; with spotCount the spots where that many players would spawn inside it
-- (the same list the server uses, shared/zone_spawn.lua).
RegisterNUICallback('previewContainerWarsZone', function(data, cb)
    local pts = resolvePerimeter(data and data.points, tonumber(data and data.fallbackZ) or 6.0)
    if #pts < 3 then
        cb({ ok = false, error = 'need_points' })
        return
    end
    -- a point picked on the map can carry a stale / underground height: the wall would then be drawn inside the ground, so lift those to the terrain
    for _, p in ipairs(pts) do
        local okH, hm = pcall(GetHeightmapTopZForPosition, p.x, p.y)
        if okH and type(hm) == 'number' and hm > -190.0 and hm < 1500.0 and p.z < hm - 5.0 then p.z = hm end
    end
    previewPoints = pts
    local count = math.floor(tonumber(data and data.spotCount) or 0)
    previewSpots = count > 0 and ZoneSpawn.spots(pts, count) or nil
    runPreview(cb, 'PERIMETER PREVIEW', previewSpots and ('Blue wall = the area. Gold dots = where %d players would spawn inside it.'):format(count) or 'Blue wall = the bidding area.')
end)

-- Tablet "Preview spawns": the recorded spawn dots, numbered, with a ring on the ground (no perimeter)
RegisterNUICallback('previewSpawnSpots', function(data, cb)
    local spots = {}
    for _, p in ipairs(data and data.spots or {}) do
        if tonumber(p.x) and tonumber(p.y) then spots[#spots + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z) or 0.0 } end
    end
    if #spots == 0 then cb({ ok = false, error = 'need_points' }) return end
    previewPoints = nil
    previewSpots = spots
    runPreview(cb, 'SPAWN PREVIEW', ('Gold dots = the %d spawn spots.'):format(#spots))
end)

-- ── Perimeter editor (PolyZone-creator style) ─────────────────────────────────
-- Same controls as the PolyZone creator in dinesh_eventcreator: the cursor is on
-- screen, a red marker follows the crosshair on the ground, LEFT CLICK drops a
-- point, BACKSPACE undoes, ENTER saves, ESC cancels. Points come back to the
-- tablet through the same zoneRecording:complete message the old recorder used.
local PERIMETER_MAX_POINTS = 24     -- matches MAX_CW_ZONE_POINTS on the server
local perimeterEditing = false
local perimeterPoints = {}
local perimeterUndo, perimeterSave = false, false

-- The ground point under the crosshair, or nil when the crosshair is not on anything.
--  · A SYNCHRONOUS probe: the asynchronous StartShapeTestRay this used to call is often not finished in the frame it is read, and the
--    old code then fell back to the ground under the CAMERA — so a click could drop a point beside the player instead of at the
--    crosshair, and the marker jumped about between frames.
--  · No fallback position at all: with nothing under the crosshair the click is refused (see the click handler), never guessed.
--  · The map and objects only (ground, walls, props): a ped or a passing car under the crosshair no longer sets the point's height.
local PERIMETER_RAY_FLAGS = 1 + 16
local PERIMETER_RAY_RANGE = 300.0
local function perimeterGroundHit()
    local camPos = GetGameplayCamCoords()
    local camRot = GetGameplayCamRot(2)
    local rx, rz = math.rad(camRot.x), math.rad(camRot.z)
    local dir = vector3(-math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx))
    local far = camPos + dir * PERIMETER_RAY_RANGE
    local ray = StartExpensiveSynchronousShapeTestLosProbe(camPos.x, camPos.y, camPos.z, far.x, far.y, far.z, PERIMETER_RAY_FLAGS, cache.ped or PlayerPedId(), 4)
    local _, hit, hitPos = GetShapeTestResult(ray)
    if hit == 1 then return hitPos end
    return nil
end

local function perimeterText(x, y, z, text)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.3, 0.3); SetTextFont(4); SetTextProportional(true)
    SetTextColour(255, 255, 255, 210); SetTextCentre(true)
    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(text); EndTextCommandDisplayText(sx, sy)
end

local function perimeterWall(p1, p2, r, g, b, a)
    local minZ, maxZ = math.min(p1.z, p2.z) - 0.5, math.max(p1.z, p2.z) + 2.0
    DrawPoly(p1.x, p1.y, minZ, p1.x, p1.y, maxZ, p2.x, p2.y, minZ, r, g, b, a)
    DrawPoly(p1.x, p1.y, maxZ, p2.x, p2.y, maxZ, p2.x, p2.y, minZ, r, g, b, a)
    DrawPoly(p2.x, p2.y, minZ, p2.x, p2.y, maxZ, p1.x, p1.y, maxZ, r, g, b, a)
    DrawPoly(p2.x, p2.y, minZ, p1.x, p1.y, maxZ, p1.x, p1.y, minZ, r, g, b, a)
end

RegisterCommand('convoy_cwzone_undo', function() if perimeterEditing then perimeterUndo = true end end, false)
RegisterKeyMapping('convoy_cwzone_undo', 'Container Wars Perimeter: Undo Last Point', 'keyboard', 'BACK')
RegisterCommand('convoy_cwzone_save', function() if perimeterEditing then perimeterSave = true end end, false)
RegisterKeyMapping('convoy_cwzone_save', 'Container Wars Perimeter: Save', 'keyboard', 'RETURN')

local function perimeterHint()
    NovaConvoy.ShowKeyHelp('DRAW BIDDING PERIMETER', {
        { { 'Left Click', 'place a point where the red marker is' }, { 'Backspace', 'undo the last point' } },
        { { 'Enter', 'SAVE (needs 3+ points)' }, { 'Esc', 'CANCEL' } },
    }, { status = ('%d / %d points'):format(#perimeterPoints, PERIMETER_MAX_POINTS), icon = 'draw-polygon' })
end

RegisterNUICallback('drawContainerWarsPerimeter', function(data, cb)
    if perimeterEditing then cb({ ok = false, error = 'busy' }) return end
    perimeterEditing = true
    NovaPerimeterEditing = true
    perimeterPoints = {}
    perimeterUndo, perimeterSave = false, false
    local sessionTarget = (data and data.target) or 'CONTAINER_WARS'

    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    Wait(300)
    SetNuiFocus(false, false)           -- no mouse cursor: points are placed at the screen-centre reticle, the keyboard and mouse stay with the game
    perimeterHint()

    CreateThread(function()
        local lastClick = 0
        local cancelled, saved = false, false
        while perimeterEditing do
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 200, true)
            local hit = perimeterGroundHit()
            local now = GetGameTimer()

            if IsDisabledControlJustPressed(0, 24) and (now - lastClick) > 150 then
                lastClick = now
                if not hit then
                    lib.notify({ title = 'Perimeter', description = 'Aim at the ground (or a wall) first - nothing is under the crosshair.', type = 'warning', duration = 2000 })
                elseif #perimeterPoints >= PERIMETER_MAX_POINTS then
                    lib.notify({ title = 'Perimeter', description = ('At most %d points — press Enter to save.'):format(PERIMETER_MAX_POINTS), type = 'warning', duration = 2500 })
                else
                    perimeterPoints[#perimeterPoints + 1] = hit
                    PlaySoundFrontend(-1, 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                    perimeterHint()
                end
            end

            if perimeterUndo then
                perimeterUndo = false
                if #perimeterPoints > 0 then
                    perimeterPoints[#perimeterPoints] = nil
                    PlaySoundFrontend(-1, 'CANCEL', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                    perimeterHint()
                end
            end

            if IsDisabledControlJustPressed(0, 200) then
                cancelled = true
                perimeterEditing = false
            elseif perimeterSave then
                perimeterSave = false
                if #perimeterPoints < 3 then
                    lib.notify({ title = 'Perimeter', description = ('Need at least 3 points (have %d).'):format(#perimeterPoints), type = 'error', duration = 2500 })
                else
                    saved = true
                    perimeterEditing = false
                end
            end

            -- A small reticle at the centre of the screen: the point lands under THIS, and the red marker shows exactly where. (The
            -- mouse cursor that used to be shown here pointed somewhere else, which made the placement look inaccurate.)
            DrawRect(0.5, 0.5, 0.0013, 0.012, 255, 255, 255, 200)
            DrawRect(0.5, 0.5, 0.0075, 0.0022, 255, 255, 255, 200)
            -- crosshair on the ground (only while something is actually under it)
            if hit then
                DrawMarker(28, hit.x, hit.y, hit.z, 0, 0, 0, 0, 0, 0, 0.22, 0.22, 0.22, 255, 50, 50, 230, false, false, 2, false, nil, nil, false)
                DrawMarker(1, hit.x, hit.y, hit.z - 0.02, 0, 0, 0, 0, 0, 0, 0.28, 0.28, 0.04, 255, 50, 50, 100, false, false, 2, false, nil, nil, false)
            end

            local n = #perimeterPoints
            for i = 1, n do
                local p = perimeterPoints[i]
                DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.28, 0.28, 0.28, 255, 215, 0, 230, false, false, 2, false, nil, nil, false)
                perimeterText(p.x, p.y, p.z + 0.65, '#' .. i)
                if i < n then
                    local q = perimeterPoints[i + 1]
                    DrawLine(p.x, p.y, p.z, q.x, q.y, q.z, 0, 180, 160, 200)
                    perimeterWall(p, q, 0, 80, 80, 45)
                end
            end
            if hit then
                if n > 0 then
                    local last = perimeterPoints[n]
                    DrawLine(last.x, last.y, last.z, hit.x, hit.y, hit.z, 255, 215, 0, 60)
                    if n >= 2 then
                        DrawLine(hit.x, hit.y, hit.z, perimeterPoints[1].x, perimeterPoints[1].y, perimeterPoints[1].z, 255, 215, 0, 35)
                    end
                end
                perimeterText(hit.x, hit.y, hit.z + 1.1, ('Pts:%d | Click=Place  Bksp=Undo  Enter=Save'):format(n))
            end
            Wait(0)
        end

        NovaPerimeterEditing = false
        SetNuiFocus(false, false)
        lib.hideTextUI()
        local points = {}
        if saved then
            for _, p in ipairs(perimeterPoints) do
                points[#points + 1] = { x = tonumber(('%.2f'):format(p.x)), y = tonumber(('%.2f'):format(p.y)), z = tonumber(('%.2f'):format(p.z)) }
            end
        end
        perimeterPoints = {}
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
        if saved then
            SendNUIMessage({ action = 'zoneRecording:complete', target = sessionTarget, points = points })
            lib.notify({ title = 'Perimeter', description = ('Saved %d points.'):format(#points), type = 'success', duration = 4000 })
        end
        cb({ ok = saved, cancelled = cancelled })
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if perimeterEditing then
        perimeterEditing = false
        NovaPerimeterEditing = false
        SetNuiFocus(false, false)
        lib.hideTextUI()
    end
end)

local function hideWorldContainers(containers)
    for _, c in ipairs(containers or {}) do
        local p = c.pickupCoords
        if c.hideWorldObject and p and p.x then
            local hash = modelHashOf(c.hideModel or c.model)   -- the real container standing there
            CreateModelHide(p.x, p.y, p.z, 2.5, hash, true)
            hiddenWorldObjects[#hiddenWorldObjects + 1] = { x = p.x, y = p.y, z = p.z, radius = 2.5, hash = hash }
        end
    end
end

local function restoreWorldContainers()
    for _, h in ipairs(hiddenWorldObjects) do
        RemoveModelHide(h.x, h.y, h.z, h.radius, h.hash, false)
    end
    hiddenWorldObjects = {}
end

-- ── Bidding window ────────────────────────────────────────────────────────────
-- E on a container asks the server whether we may bid (it also supplies the numbers
-- and our gang), then opens the bidder window on the left of the screen. Everything
-- here is built so the player can never be stuck:
--   · one window / one request per player at a time, plus a short debounce on E
--   · every request has a timeout (BID_TIMEOUT_MS) that releases the UI
--   · the server answers every bid with client:bidResult (accepted or why not)
-- Key hint on the container panel: PLACE BID → PROCESSING... → BID REJECTED → PLACE BID
local bidCfg = (Config.ContainerWars and Config.ContainerWars.bidding) or {}
local BID_DEBOUNCE_MS = tonumber(bidCfg.debounceMs) or 400
local BID_TIMEOUT_MS = tonumber(bidCfg.requestTimeoutMs) or 5000
local REJECT_SHOW_MS = tonumber(bidCfg.rejectShowMs) or 2000
local BID_DISTANCE = tonumber(bidCfg.bidDistance) or 12.0
local BID_CLOSE_DISTANCE = tonumber(bidCfg.windowCloseDistance) or 16.0
local BID_COOLDOWN_MS = math.max(0, tonumber(bidCfg.bidCooldownSeconds) or 0) * 1000   -- the server enforces it; this only saves the round trip

local bid = {
    opening = false,     -- waiting for the server to say whether we may bid
    open = false,        -- the bidder window is on screen
    containerId = nil,
    reqId = nil,         -- bid request in flight
    seq = 0,
    openToken = 0,
    lastPress = 0,
    lastSubmit = 0,
    cooldownUntil = 0,   -- GetGameTimer() until which our own next bid is refused
    state = 'idle',      -- idle | processing | rejected   (container panel key hint)
    rejectUntil = 0,
}

local showingBidTextUI = false

local function hideBidPrompt()
    if showingBidTextUI then
        showingBidTextUI = false
        pcall(function() lib.hideTextUI() end)
    end
end

local function showBidPrompt()
    if not showingBidTextUI then
        showingBidTextUI = true
        pcall(function()
            lib.showTextUI('[E] - Place Bid', { position = 'left-center', icon = 'gavel' })
        end)
    end
end

local function bidNotify(kind, text)
    TriggerEvent('nova_convoytruck:client:hudNotify', { title = 'CONTAINER WARS', description = text, type = kind, duration = 4500 })
end

local function setRejected()
    bid.state = 'rejected'
    bid.rejectUntil = GetGameTimer() + REJECT_SHOW_MS
end

local function closeBidder()
    hideBidPrompt()
    if bid.open then
        bid.open = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'bidder:close' })
    end
end

local function resetBidding()
    hideBidPrompt()
    closeBidder()
    bid.opening = false
    bid.reqId = nil
    bid.containerId = nil
    bid.state = 'idle'
    bid.cooldownUntil = 0
end

-- the same fields the window shows, from what the client currently knows
local function bidderFields(st)
    return {
        containerId = st.id,
        containerNumber = st.containerIndex or 1,
        currentBid = st.currentBid or 0,
        minimumBid = (st.currentBid or 0) + (st.bidIncrement or 1000),
        increment = st.bidIncrement or 1000,
        canBid = st.status == 'AUCTION_ACTIVE' and (st.timeRemaining or 0) > 0,
    }
end

local function openBidder(c)
    local now = GetGameTimer()
    if bid.open or bid.opening or bid.reqId then return end          -- E again / rapid E / double click: nothing
    if now - bid.lastPress < BID_DEBOUNCE_MS then return end
    bid.lastPress = now
    if now < bid.cooldownUntil then
        bidNotify('warning', ('Wait %d s before bidding again.'):format(math.ceil((bid.cooldownUntil - now) / 1000)))
        return
    end

    bid.opening = true
    bid.containerId = c.id
    bid.state = 'processing'
    bid.openToken = bid.openToken + 1
    local token = bid.openToken

    SetTimeout(BID_TIMEOUT_MS, function()
        if bid.opening and bid.openToken == token then
            bid.opening = false
            setRejected()
            bidNotify('error', 'Bid request timed out')
        end
    end)

    lib.callback('nova_convoytruck:containerWars:bidInfo', false, function(info)
        if not (bid.opening and bid.openToken == token) then return end   -- already timed out
        bid.opening = false
        if not info or not info.ok then
            setRejected()
            bidNotify('error', (info and info.message) or 'You cannot bid on this container.')
            return
        end
        local st = containersState[info.containerId]
        if st then
            st.version = info.version
            st.currentBid = info.currentBid
        end
        bid.state = 'idle'
        bid.open = true
        bid.containerId = info.containerId
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = 'bidder:open',
            containerId = info.containerId,
            containerNumber = info.containerNumber,
            currentBid = info.currentBid,
            minimumBid = info.minimumBid,
            increment = info.increment,
            gang = info.gang,
            canBid = info.canBid,
        })
    end, activeEvent.convoyId, c.id)
end

RegisterNUICallback('closeBidder', function(_, cb)
    closeBidder()
    cb('ok')
end)

RegisterNUICallback('submitBid', function(data, cb)
    if bid.reqId then
        return cb({ ok = false, message = 'Your previous bid is still being processed.' })
    end
    local st = bid.containerId and containersState[bid.containerId]
    if not (bid.open and activeEvent and st) then
        return cb({ ok = false, message = 'Bidding is not available.' })
    end
    if st.status ~= 'AUCTION_ACTIVE' or (st.timeRemaining or 0) <= 0 then
        return cb({ ok = false, message = 'This auction is no longer taking bids.' })
    end
    local amount = math.floor(tonumber(data and data.amount) or 0)
    if amount <= 0 then
        return cb({ ok = false, message = 'Enter a valid bid amount.' })
    end
    local now = GetGameTimer()
    if now - bid.lastSubmit < BID_DEBOUNCE_MS then
        return cb({ ok = false, message = 'Please wait a moment.' })
    end
    bid.lastSubmit = now

    bid.seq = bid.seq + 1
    local reqId = ('%d-%d'):format(GetPlayerServerId(PlayerId()), bid.seq)
    bid.reqId = reqId
    bid.state = 'processing'
    -- the version we last saw: the server rejects the bid if the auction has moved on since
    TriggerServerEvent('nova_convoytruck:containerWars:server:placeBid', activeEvent.convoyId, st.id, amount, st.version, reqId)
    cb({ ok = true })

    SetTimeout(BID_TIMEOUT_MS, function()
        if bid.reqId == reqId then
            bid.reqId = nil
            setRejected()
            if bid.open then
                SendNUIMessage({ action = 'bidder:rejected', message = 'Bid request timed out' })
            else
                bidNotify('error', 'Bid request timed out')
            end
        end
    end)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:bidResult', function(res)
    if not res then return end
    local st = res.containerId and containersState[res.containerId]
    if st and res.version and res.version >= (st.version or 0) then
        st.version = res.version
        if res.currentBid then st.currentBid = res.currentBid end
    end

    if res.reqId ~= bid.reqId then
        -- we already gave up on this request (timed out) but it did go through
        if res.ok then bidNotify('success', res.message or 'Bid placed.') end
        return
    end
    bid.reqId = nil

    if res.ok then
        bid.state = 'idle'
        bid.cooldownUntil = GetGameTimer() + BID_COOLDOWN_MS
        SendNUIMessage({ action = 'bidder:accepted' })
        closeBidder()
        bidNotify('success', res.message or 'Bid placed.')
    else
        setRejected()
        PlaySoundFrontend(-1, 'ERROR', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
        if bid.open then
            SendNUIMessage({
                action = 'bidder:rejected',
                message = res.message,
                currentBid = res.currentBid,
                minimumBid = res.minimumBid,
                increment = res.increment,
                canBid = res.canBid,
            })
        else
            bidNotify('error', res.message or 'Bid rejected.')
        end
    end
end)

-- ── Event Lifecycle Listeners ──────────────────────────────────────────────────

RegisterNetEvent('nova_convoytruck:containerWars:client:eventStarted', function(data)
    activeEvent = data
    containersState = {}
    activeContainerId = nil
    SendNUIMessage({ action = 'containerInfo:frame', items = {} })

    -- Initialize container states
    for i, c in ipairs(data.containers or {}) do
        containersState[c.id] = {
            id = c.id,
            containerIndex = c.containerIndex or i,
            name = c.name or ('Container #%d'):format(i),
            status = 'PENDING',
            coords = c.dropCoords or { x = 805.0, y = -2975.0, z = 6.0 },
            currentBid = c.startingBid or 5000,
            highestBidderGang = nil,
            highestBidderName = nil,
            timeRemaining = 0,
        }
        -- someone who joins (or restarts) while the event runs is told where every lot stands
        local s = data.states and data.states[c.id]
        if s then
            local st = containersState[c.id]
            for k, v in pairs(s) do st[k] = v end
            if s.status == 'AUCTION_ACTIVE' or s.status == 'DELIVERED' or s.status == 'CRANE_STAGING' then
                activeContainerId = c.id
            end
        end
    end
    cwFlow = { kind = 'IDLE' }

    -- Setup Map Blip (reads from Config.MapBlips.containerWars)
    if eventBlip and DoesBlipExist(eventBlip) then RemoveBlip(eventBlip) end
    if eventRadiusBlip and DoesBlipExist(eventRadiusBlip) then RemoveBlip(eventRadiusBlip) end
    -- the blip marks the gantry crane, so people know where to go; before it is known, the first drop spot
    local firstCoords = (data.crane and data.crane.x and data.crane)
        or (data.containers and data.containers[1] and data.containers[1].dropCoords)
        or { x = 805.0, y = -2975.0, z = 6.0 }
    local blipCfg = (Config.MapBlips and Config.MapBlips.containerWars) or { sprite = 473, colour = 3, scale = 1.0, label = 'Container Wars — Gantry Crane' }
    if (blipCfg.radius or 0) > 0 then
        eventRadiusBlip = AddBlipForRadius(firstCoords.x, firstCoords.y, firstCoords.z or 0.0, blipCfg.radius + 0.0)
        SetBlipColour(eventRadiusBlip, blipCfg.radiusColour or blipCfg.colour or 3)
        SetBlipAlpha(eventRadiusBlip, blipCfg.radiusAlpha or 65)
    end
    eventBlip = AddBlipForCoord(firstCoords.x, firstCoords.y, firstCoords.z or 0.0)
    SetBlipSprite(eventBlip, blipCfg.sprite or 473)
    SetBlipColour(eventBlip, blipCfg.colour or 3)
    SetBlipScale(eventBlip, blipCfg.scale or 1.0)
    if blipCfg.flash then SetBlipFlashes(eventBlip, true) end
    SetBlipAsShortRange(eventBlip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(blipCfg.label or (('Container Wars: %s'):format(data.name or 'Auction')))
    EndTextCommandSetBlipName(eventBlip)

    -- Setup Polyzone Bidding Perimeter (3D points — see resolvePerimeter)
    if biddingZone then biddingZone:remove() biddingZone = nil end
    restoreWorldContainers()
    hideWorldContainers(data.containers)
    -- real map cranes near the gantry would overlap it: hidden for the length of the event
    local hm = Config.ContainerWars and Config.ContainerWars.harbour and Config.ContainerWars.harbour.hideMap
    local craneSpots = (type(data.cranes) == 'table' and #data.cranes > 0) and data.cranes or { data.crane }
    for _, hc in ipairs(craneSpots) do
        if hm and hc and hc.x then
            for _, model in ipairs(hm.models or {}) do
                local hash = joaat(model)
                CreateModelHide(hc.x, hc.y, hc.z or 0.0, hm.radius or 60.0, hash, true)
                hiddenWorldObjects[#hiddenWorldObjects + 1] = { x = hc.x, y = hc.y, z = hc.z or 0.0, radius = hm.radius or 60.0, hash = hash }
            end
        end
    end
    local zoneData = data.zone or {}
    zonePoints = resolvePerimeter(zoneData.points, fallbackZOf(data))
    local zoneThickness = (Config.ContainerWars and Config.ContainerWars.biddingZone and Config.ContainerWars.biddingZone.thickness) or 40.0
    if #zonePoints >= 3 then
        local vecPoints = {}
        for _, p in ipairs(zonePoints) do
            vecPoints[#vecPoints + 1] = vec3(p.x, p.y, p.z)
        end
        biddingZone = lib.zones.poly({
            points = vecPoints,
            thickness = zoneThickness,
            debug = false,
            onEnter = function()
                inBiddingZone = true
                TriggerEvent('nova_convoytruck:client:hudNotify', {
                    title = 'CONTAINER WARS',
                    description = 'Entered auction bidding perimeter. You can now place bids.',
                    type = 'info',
                    duration = 5000,
                })
            end,
            onExit = function()
                inBiddingZone = false
                TriggerEvent('nova_convoytruck:client:hudNotify', {
                    title = 'CONTAINER WARS',
                    description = 'Left auction bidding perimeter.',
                    type = 'warning',
                    duration = 4000,
                })
            end,
        })
    else
        inBiddingZone = true -- Fallback if zone not configured
    end

    local sndCfg = (Config.ContainerWars and Config.ContainerWars.sounds) or {}
    local s = sndCfg.roundStartSound or { name = 'Event_Start', bank = 'GTAO_FM_Events_Soundset' }
    PlaySoundFrontend(-1, s.name, s.bank, true)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:startCountdown', function(data)
    activeContainerId = nil
    SendNUIMessage({ action = 'containerInfo:frame', items = {} })
    cwFlow = {
        kind = 'START_COUNTDOWN',
        endsAt = GetGameTimer() + math.floor((tonumber(data.seconds) or 30) * 1000),
        totalContainers = tonumber(data.totalContainers) or 1,
        name = data.name or 'Container Wars',
    }
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:tickStartCountdown', function(data)
    activeContainerId = nil
    SendNUIMessage({ action = 'containerInfo:frame', items = {} })
    local s = math.max(0, math.floor(tonumber(data.seconds) or 0))
    cwFlow = {
        kind = 'START_COUNTDOWN',
        endsAt = GetGameTimer() + math.floor(s * 1000),
        seconds = s,
        totalContainers = tonumber(data.totalContainers) or (cwFlow and cwFlow.totalContainers) or 1,
        name = (cwFlow and cwFlow.name) or 'Container Wars',
    }
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:craneMove', function(data)
    -- If an auction is actively running on current container, do not disrupt it with background upcoming staging
    local activeC = activeContainerId and containersState[activeContainerId]
    if cwFlow and cwFlow.kind == 'BIDDING' and activeC and activeC.status == 'AUCTION_ACTIVE' and (activeC.timeRemaining or 0) > 0 and data.containerId ~= activeContainerId then
        return
    end

    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if not state then
        state = {
            id = data.containerId,
            containerIndex = data.containerIndex or 1,
            name = data.name,
            coords = data.dropCoords,
            status = 'CRANE_STAGING',
        }
        containersState[data.containerId] = state
    else
        state.status = 'CRANE_STAGING'
        state.coords = data.dropCoords
    end

    local travelSec = 8
    cwFlow = {
        kind = 'DELIVERING',
        id = data.containerId,
        n = state.containerIndex,
        name = state.name,
        endsAt = GetGameTimer() + (travelSec * 1000),
        seconds = travelSec,
    }
    PlaySoundFrontend(-1, 'CHECKPOINT_AHEAD', 'HUD_MINI_GAME_SOUNDSET', true)
end)

-- The server says when the crane will bring the next container (or, with kind BIDSOON, when bidding opens on the one that
-- just landed). `seconds` counts down on this client's own clock.
RegisterNetEvent('nova_convoytruck:containerWars:client:nextDrop', function(data)
    if type(data) ~= 'table' then return end
    local activeC = activeContainerId and containersState[activeContainerId]
    if cwFlow and cwFlow.kind == 'BIDDING' and activeC and activeC.status == 'AUCTION_ACTIVE' and (activeC.timeRemaining or 0) > 0 and data.containerId ~= activeContainerId then
        return
    end

    local kind = data.kind == 'BIDSOON' and 'BIDSOON' or (data.kind == 'CLAIM_WINDOW' and 'CLAIM_WINDOW' or 'NEXT')
    local sec = tonumber(data.seconds) or 0
    cwFlow = {
        kind = kind,
        endsAt = GetGameTimer() + math.floor(sec * 1000),
        seconds = sec,
        n = data.containerIndex,
        name = data.name,
        winnerName = data.winnerName,
        winnerGang = data.winnerGang,
    }
end)

-- The container is on its pad and still CLOSED; its bidding follows after a short pause.
RegisterNetEvent('nova_convoytruck:containerWars:client:containerDelivered', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if state then state.status = 'DELIVERED' end
    local bidIn = tonumber(data.bidIn) or 5
    cwFlow = {
        kind = 'BIDSOON',
        id = data.containerId,
        endsAt = GetGameTimer() + math.floor(bidIn * 1000),
        seconds = bidIn,
        n = data.containerIndex,
        name = data.name,
    }
    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:auctionStarted', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if not state then
        state = {
            id = data.containerId,
            containerIndex = data.containerIndex or 1,
            name = data.name,
            coords = data.coords,
        }
        containersState[data.containerId] = state
    end

    state.status = 'AUCTION_ACTIVE'
    cwFlow = { kind = 'BIDDING', id = data.containerId, n = data.containerIndex }
    state.version = data.version
    state.currentBid = data.currentBid
    state.bidIncrement = data.bidIncrement or 1000
    state.timeRemaining = data.timeRemaining or 45
    state.highestBidderGang = nil
    state.highestBidderName = nil

    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:tickTimer', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if state then
        state.timeRemaining = data.timeRemaining
        state.currentBid = data.currentBid
        if data.version then state.version = data.version end
        state.highestBidderGang = data.highestBidderGang
        state.highestBidderName = data.highestBidderName
    end
    if not cwFlow or cwFlow.kind ~= 'BIDDING' or cwFlow.id ~= data.containerId then
        cwFlow = { kind = 'BIDDING', id = data.containerId, n = data.containerIndex }
    end
end)

-- ── Bid Visual Effects (Money Emoji & Subtle Glow) ───────────────────────────
local activeBidFx = {}

local function playBidVisualEffect(sourceId, amount)
    if not sourceId or sourceId <= 0 then return end
    local targetPlayer = GetPlayerFromServerId(sourceId)
    if targetPlayer == -1 then return end
    local ped = GetPlayerPed(targetPlayer)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local myCoords = GetEntityCoords(PlayerPedId())
    local pedCoords = GetEntityCoords(ped)
    if #(myCoords - pedCoords) > 45.0 then return end -- zero overhead for distant players

    activeBidFx[#activeBidFx + 1] = {
        ped = ped,
        startTime = GetGameTimer(),
        duration = 1800,
        amount = amount or 0,
    }
end

CreateThread(function()
    while true do
        if #activeBidFx == 0 then
            Wait(500)
        else
            Wait(0)
            local now = GetGameTimer()
            local i = 1
            while i <= #activeBidFx do
                local fx = activeBidFx[i]
                local elapsed = now - fx.startTime
                local progress = elapsed / fx.duration
                if progress >= 1.0 or not DoesEntityExist(fx.ped) then
                    table.remove(activeBidFx, i)
                else
                    local headCoords = GetPedBoneCoords(fx.ped, 31086, 0.0, 0.0, 0.0)
                    local zFloat = 0.5 + (progress * 0.4)
                    local alpha = math.max(10, math.floor((1.0 - progress) * 255))

                    -- Subtle glowing ring marker below head
                    DrawMarker(25, headCoords.x, headCoords.y, headCoords.z - 0.95,
                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        0.85, 0.85, 0.85,
                        46, 213, 115, math.floor(alpha * 0.35),
                        false, false, 2, false, nil, nil, false)

                    -- Floating money emoji and amount above head
                    local onScreen, screenX, screenY = World3dToScreen2d(headCoords.x, headCoords.y, headCoords.z + zFloat)
                    if onScreen then
                        SetTextScale(0.38, 0.38)
                        SetTextFont(4)
                        SetTextProportional(1)
                        SetTextColour(46, 213, 115, alpha)
                        SetTextEntry('STRING')
                        SetTextCentre(1)
                        SetTextOutline()
                        AddTextComponentString(('💸 $%s'):format(math.floor(fx.amount)))
                        DrawText(screenX, screenY)
                    end
                    i = i + 1
                end
            end
        end
    end
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:bidUpdate', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if state then
        state.currentBid = data.currentBid
        if data.version then state.version = data.version end
        state.highestBidderGang = data.highestBidderGang
        state.highestBidderGangName = data.highestBidderGangName
        state.highestBidderName = data.highestBidderName
        state.timeRemaining = data.timeRemaining
        -- an open bidder window just gets the new numbers
        if bid.open and bid.containerId == data.containerId then
            local fields = bidderFields(state)
            fields.action = 'bidder:update'
            SendNUIMessage(fields)
        end
    end
    -- The bid sound and the effect over the bidder are for people who can see or take part in this auction: standing near the
    -- container, or with its bidder window open. They used to play for EVERY player on the server on every single bid, which is
    -- what made a busy auction sound like constant spam to everyone else.
    local near = bid.open and bid.containerId == data.containerId
    if not near and state and state.coords and state.coords.x then
        local me = GetEntityCoords(cache.ped or PlayerPedId())
        near = #(vec3(me.x, me.y, me.z) - vec3(state.coords.x, state.coords.y, state.coords.z or me.z)) <= (tonumber(bidCfg.feedbackDistance) or 80.0)
    end
    if near then
        PlaySoundFrontend(-1, 'SELECT', 'HUD_MINI_GAME_SOUNDSET', true)
        if data and data.bidderSource then
            playBidVisualEffect(data.bidderSource, data.currentBid)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:containerWon', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if not state then
        state = { id = data.containerId, containerIndex = data.containerIndex or 1, name = data.name, coords = data.coords }
        containersState[data.containerId] = state
    end

    state.status = 'WON'
    state.finalBid = data.finalBid
    state.winnerGang = data.winnerGang
    state.winnerGangName = data.winnerGangName
    state.winnerPlayer = data.winnerPlayer
    cwFlow = { kind = 'AUCTION_CLOSED', n = state.containerIndex, label = 'SOLD', sub = ('%s (%s)'):format(state.winnerGang or 'Winner', state.winnerPlayer or '') }

    local sndCfg = (Config.ContainerWars and Config.ContainerWars.sounds) or {}
    local s = sndCfg.winSound or { name = 'PROPERTY_PURCHASE', bank = 'HUD_AWARDS' }
    PlaySoundFrontend(-1, s.name, s.bank, true)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:containerUnsold', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if state then
        state.status = 'UNSOLD'
        cwFlow = { kind = 'AUCTION_CLOSED', n = state.containerIndex, label = 'AUCTION CLOSED', sub = 'No bids placed' }
    end
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:containerClaimed', function(data)
    activeContainerId = data.containerId
    local state = containersState[data.containerId]
    if state then
        state.status = 'CLAIMED'
    end
    if NovaConvoy.cwRemoveOpenTarget then NovaConvoy.cwRemoveOpenTarget(data.containerId) end
end)

-- ── Opening a won container ───────────────────────────────────────────────────
-- Members of the winning gang get an ox_target "Open Container" on the container
-- itself. Selecting it asks the server, which answers with openSequence to every
-- client: the opener plays an animation + progress bar, everyone nearby sees the
-- doors swing open. Door props are local-only and removed with the container.
local openTargets = {}   -- [containerId] = { entity, netId, zoneId }
local doorProps = {}     -- [containerId] = { left, right }

local function openCfg()
    return (Config.ContainerWars and Config.ContainerWars.openContainer) or {}
end

local function removeOpenTarget(containerId)
    local t = openTargets[containerId]
    if not t then return end
    openTargets[containerId] = nil
    if t.zoneId then
        pcall(function() exports.ox_target:removeZone(t.zoneId) end)
    else
        pcall(NovaConvoy.RemoveEntityTarget, t.entity, t.netId)
    end
end

local function removeDoors(containerId)
    local d = doorProps[containerId]
    if not d then return end
    doorProps[containerId] = nil
    for _, key in ipairs({ 'left', 'right' }) do
        if d[key] and DoesEntityExist(d[key]) then DeleteEntity(d[key]) end
    end
end

NovaConvoy = NovaConvoy or {}
NovaConvoy.cwRemoveOpenTarget = removeOpenTarget

local function clearAllOpenState()
    for id in pairs(openTargets) do removeOpenTarget(id) end
    for id in pairs(doorProps) do removeDoors(id) end
end

-- Spawns a local door prop. Returns nil when the model is not in this build.
local function spawnDoor(modelName, x, y, z, heading)
    if not modelName or modelName == '' then return nil end
    local hash = joaat(modelName)
    if not IsModelInCdimage(hash) then return nil end
    lib.requestModel(hash, 5000)
    local obj = CreateObjectNoOffset(hash, x, y, z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 then return nil end
    SetEntityHeading(obj, heading)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    return obj
end

-- Swings the two doors open on `container` (an entity handle). Falls back to a
-- flash + camera shake when the door models are missing. `key` identifies the
-- door set for cleanup. Blocks for the swing duration.
local function swingDoors(key, container, seconds)
    local doors = openCfg().doors or {}
    local swing = tonumber(doors.swingSeconds) or 2.4
    local openAngle = tonumber(doors.openAngle) or 110.0

    removeDoors(key)
    local left = doors.left or {}
    local right = doors.right or {}
    local hasDoors = false

    if container and container ~= 0 and DoesEntityExist(container) then
        local min, max = GetModelDimensions(NovaConvoy.SafeEntityModel(container))   -- container is checked with DoesEntityExist just above
        local atFront = doors.atFront == true
        local hingeY = tonumber(doors.backOffset) or (atFront and max.y or min.y)
        local zOff = (tonumber(doors.zOffset) or 0.0) + min.z
        local halfW = (max.x - min.x) / 2.0
        local sign = atFront and 1.0 or -1.0

        local lPos = GetOffsetFromEntityInWorldCoords(container, -halfW, hingeY, zOff)
        local rPos = GetOffsetFromEntityInWorldCoords(container, halfW, hingeY, zOff)
        local baseHeading = GetEntityHeading(container) + (atFront and 0.0 or 180.0)
        local lObj = spawnDoor(left.model, lPos.x, lPos.y, lPos.z, baseHeading)
        local rObj = spawnDoor(right.model, rPos.x, rPos.y, rPos.z, baseHeading)

        if lObj and rObj then
            hasDoors = true
            doorProps[key] = { left = lObj, right = rObj }
            local lDir = left.flip and -1.0 or 1.0
            local rDir = right.flip and -1.0 or 1.0
            local steps = math.max(1, math.floor(swing * 30))
            PlaySoundFromCoord(-1, 'Door_Open_Limit', lPos.x, lPos.y, lPos.z, 'DOCKS_HEIST_SOUNDS', false, 40, false)
            for i = 1, steps do
                local k = i / steps
                local e = 1.0 - (1.0 - k) * (1.0 - k) -- ease-out: doors slow down as they reach full open
                if DoesEntityExist(lObj) then SetEntityHeading(lObj, baseHeading + lDir * sign * openAngle * e) end
                if DoesEntityExist(rObj) then SetEntityHeading(rObj, baseHeading - rDir * sign * openAngle * e) end
                Wait(33)
            end
        else
            if lObj and DoesEntityExist(lObj) then DeleteEntity(lObj) end
            if rObj and DoesEntityExist(rObj) then DeleteEntity(rObj) end
        end
    end

    if not hasDoors then
        -- Fallback: no door models in this build → flash + shake so it still reads as "opened".
        PlaySoundFrontend(-1, 'Hack_Success', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true)
        ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.12)
        SetFlash(0, 0, 100, 400, 100)
        Wait(math.floor(swing * 1000))
        StopGameplayCamShaking(true)
    end
end

local function attachOpenTarget(data)
    local cfg = openCfg()
    local containerId = data.containerId
    removeOpenTarget(containerId)

    local function makeOptions(withDistance)
        return {
            {
                name = 'cw_open_' .. tostring(containerId),
                label = cfg.label or 'Open Container',
                icon = cfg.icon or 'fas fa-door-open',
                distance = withDistance and (cfg.targetDistance or 3.5) or nil,
                canInteract = function()
                    local st = containersState[containerId]
                    return st ~= nil and st.status == 'WON'
                end,
                onSelect = function()
                    TriggerServerEvent('nova_convoytruck:containerWars:server:openContainer', data.convoyId, containerId)
                end,
            },
        }
    end

    CreateThread(function()
        -- the container is a server-created entity; wait for it to stream in
        local deadline = GetGameTimer() + 20000
        while data.containerNetId and GetGameTimer() < deadline do
            if activeEvent == nil or not containersState[containerId] then return end
            if NetworkDoesNetworkIdExist(data.containerNetId) then
                local ent = NetworkGetEntityFromNetworkId(data.containerNetId)
                if ent ~= 0 and DoesEntityExist(ent) then
                    local netId = NovaConvoy.AddEntityTarget(ent, makeOptions(true))
                    openTargets[containerId] = { entity = ent, netId = netId }
                    return
                end
            end
            Wait(250)
        end
        -- no entity to target (world container / never streamed in) → a sphere at the drop point
        local c = data.coords
        if c and c.x and activeEvent and containersState[containerId] then
            local zoneId = exports.ox_target:addSphereZone({
                coords = vec3(c.x, c.y, c.z + 1.0),
                radius = (cfg.targetDistance or 3.5) + 2.0,
                debug = false,
                options = makeOptions(false),
            })
            openTargets[containerId] = { zoneId = zoneId }
        end
    end)
end

RegisterNetEvent('nova_convoytruck:containerWars:client:containerUnlocked', function(data)
    local state = containersState[data.containerId]
    if state then state.containerNetId = data.containerNetId end
    attachOpenTarget(data)
    TriggerEvent('nova_convoytruck:client:hudNotify', {
        title = 'CONTAINER WON',
        description = ('Your gang won %s — go to it and use the target to open it.'):format(data.name or 'the container'),
        type = 'success',
        duration = 7000,
    })
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:openSequence', function(data)
    local state = containersState[data.containerId]
    if state then state.status = 'OPENING_DOORS' end

    local seconds = tonumber(data.seconds) or 11.5
    local ped = PlayerPedId()
    local isOpener = data.opener == GetPlayerServerId(PlayerId())

    local animDict = 'anim@scripted@player@mission@tunf_train_ig1_container_p1@male@'
    lib.requestAnimDict(animDict, 5000)
    lib.requestNamedPtfxAsset('scr_tn_tr', 5000)

    local ent = nil
    if data.containerNetId and NetworkDoesNetworkIdExist(data.containerNetId) then
        ent = NetworkGetEntityFromNetworkId(data.containerNetId)
    end

    if isOpener and ent and DoesEntityExist(ent) then
        CreateThread(function()
            local pedCo = GetEntityCoords(ped)
            local contCoords = GetEntityCoords(ent)
            local contRot = GetEntityRotation(ent, 2)

            local grinderModel = joaat('tr_prop_tr_grinder_01a')
            local bagModel = joaat('ch_p_m_bag_var02_arm_s')
            local lockModel = joaat('tr_prop_tr_lock_01a')
            pcall(lib.requestModel, grinderModel, 5000)
            pcall(lib.requestModel, bagModel, 5000)
            pcall(lib.requestModel, lockModel, 5000)

            local function makeProp(hash)
                if not IsModelInCdimage(hash) or not HasModelLoaded(hash) then return nil end
                local o = CreateObject(hash, pedCo.x, pedCo.y, pedCo.z, true, true, false)
                if not o or o == 0 or not DoesEntityExist(o) then return nil end
                return o
            end
            local grinder, bag, lock = makeProp(grinderModel), makeProp(bagModel), makeProp(lockModel)
            if not (grinder and bag and lock) then
                print(('[nova_convoytruck] container opening props missing: grinder=%s bag=%s lock=%s (models loaded: %s/%s/%s)'):format(
                    tostring(grinder ~= nil), tostring(bag ~= nil), tostring(lock ~= nil),
                    tostring(HasModelLoaded(grinderModel)), tostring(HasModelLoaded(bagModel)), tostring(HasModelLoaded(lockModel))))
            end
            local openStartedAt = GetGameTimer()

            local scene = NetworkCreateSynchronisedScene(contCoords.x, contCoords.y, contCoords.z, contRot.x, contRot.y, contRot.z, 2, true, false, 1065353216, 0, 1065353216)
            NetworkAddPedToSynchronisedScene(ped, scene, animDict, 'action', 4.0, -4.0, 1033, 0, 1000.0, 0)
            NetworkAddEntityToSynchronisedScene(ent, scene, animDict, 'action_container', 1.0, -1.0, 1148846080)
            if lock and DoesEntityExist(lock) then NetworkAddEntityToSynchronisedScene(lock, scene, animDict, 'action_lock', 1.0, -1.0, 1148846080) end
            if grinder and DoesEntityExist(grinder) then NetworkAddEntityToSynchronisedScene(grinder, scene, animDict, 'action_angle_grinder', 1.0, -1.0, 1148846080) end
            if bag and DoesEntityExist(bag) then NetworkAddEntityToSynchronisedScene(bag, scene, animDict, 'action_bag', 1.0, -1.0, 1148846080) end

            SetEntityCoords(ped, contCoords.x, contCoords.y, contCoords.z, false, false, false, false)
            NetworkStartSynchronisedScene(scene)

            -- Cutting sparks effect
            Wait(3800)
            local sparks = nil
            if grinder and DoesEntityExist(grinder) then
                UseParticleFxAssetNextCall('scr_tn_tr')
                sparks = StartParticleFxLoopedOnEntity("scr_tn_tr_angle_grinder_sparks", grinder, 0.0, 0.25, 0.0, 0.0, 0.0, 0.0, 1.0, false, false, false, 1065353216, 1065353216, 1065353216, 1)
            end
            Wait(1500)
            if sparks then StopParticleFxLooped(sparks, 1) end

            -- Wait for the clip to REALLY finish (its length is not a fixed number of seconds), then tell the server so it can flag the
            -- container open. A fixed wait either flagged it while the clip still played (the pose was overwritten and the container
            -- snapped shut) or left it to close and reopen.
            local localScene = NetworkConvertSynchronisedSceneToSynchronizedScene(scene)
            local giveUp = GetGameTimer() + math.floor((seconds + 6) * 1000)
            while GetGameTimer() < giveUp and localScene ~= -1 and IsSynchronizedSceneRunning(localScene) and GetSynchronizedScenePhase(localScene) < 0.98 do
                Wait(100)
            end

            -- the props stay for the whole clip even when the scene cannot be read back (the loop above is then skipped)
            while GetGameTimer() < openStartedAt + math.floor(seconds * 1000) do Wait(100) end
            if grinder and DoesEntityExist(grinder) then DeleteEntity(grinder) end
            if bag and DoesEntityExist(bag) then DeleteEntity(bag) end
            if lock and DoesEntityExist(lock) then DeleteEntity(lock) end
            -- the clip's own hold ends with the scene: park the opened pose first so there is no frame of a shut container
            if CWFx and CWFx.HoldOpen then CWFx.HoldOpen(ent) end
            ClearPedTasks(ped)
            TriggerServerEvent('nova_convoytruck:containerWars:server:openDone', data.convoyId, data.containerId)
            -- The container is NOT closed again from here: once the server has confirmed the opening it flags the container 'cwOpen',
            -- and every client holds the opened pose from that flag (container_wars_fx.lua, holdOpen) — including anyone who
            -- arrives or streams the container in later. (The scene this used to make here ended within a moment, and the doors shut.)
        end)
    end
    -- no container to animate on the opener's side: there is nothing to wait for but the configured time
    if isOpener and not (ent and DoesEntityExist(ent)) then
        SetTimeout(math.floor(seconds * 1000), function()
            TriggerServerEvent('nova_convoytruck:containerWars:server:openDone', data.convoyId, data.containerId)
        end)
    end
    -- Everyone else sees the same clip play through the container's own synchronised scene; the opened pose then comes from 'cwOpen'.
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:openCancelled', function(data)
    local state = containersState[data.containerId]
    if state then state.status = 'WON' end
end)

-- (/cwopentest — a test container with its doors — lives in container_wars_fx.lua with the rest of the door code.)

-- ── Crane sound & container handling audio ────────────────────────────────────
-- Two layers, because the game's own crane sounds need audio banks that may not be loaded, and when they are not
-- the game just stays silent (no error):
--   · the game sounds        Config.ContainerWars.craneAudio.native
--   · a synthesised crane    Config.ContainerWars.craneAudio.synth — made by the NUI page (web/src/lib/audio/craneAudio.js),
--                            always audible, louder the closer the player is to the crane
-- /cwcranesound plays every stage at your feet to check it.
local activeCraneSoundId = nil
local activeCraneAudioState = 'IDLE'
local craneAudioCoords = nil
local craneAudioToken = 0
local craneAudioRunning = false
local nativeWarned = false

local function craneAudioCfg()
    local c = (Config.ContainerWars and Config.ContainerWars.craneAudio) or {}
    return {
        native = c.native ~= false,
        synth = c.synth ~= false,
        volume = tonumber(c.volume) or 1.0,
        maxDistance = math.max(10.0, tonumber(c.maxDistance) or 180.0),
        banks = c.banks or { 'DOCKS_HEIST_SOUNDS', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS' },
    }
end

-- Asks the game for the audio banks of the crane sounds once, and says in the log whether they exist. A bank that
-- "is not found" means the game sounds that come from it will never play — the synthesised layer covers for that.
CreateThread(function()
    Wait(4000)
    for _, bank in ipairs(craneAudioCfg().banks) do
        local ok = RequestScriptAudioBank(bank, false, -1)
        local tries = 0
        while not ok and tries < 40 do
            Wait(50)
            tries = tries + 1
            ok = RequestScriptAudioBank(bank, false, -1)
        end
        print(('[nova_convoytruck] crane audio bank "%s": %s'):format(bank, ok and 'loaded' or 'NOT FOUND — game sounds from it stay silent (the synthesised crane sound still plays)'))
    end
end)

-- 0..1: how loud the crane is for this player, from how far away it is
local function craneVolume(coords)
    if not coords then return 0.0 end
    local cfg = craneAudioCfg()
    local p = GetEntityCoords(cache.ped or PlayerPedId())
    local d = #(p - vector3(tonumber(coords.x) or p.x, tonumber(coords.y) or p.y, tonumber(coords.z) or p.z))
    if d >= cfg.maxDistance then return 0.0 end
    return math.min(1.0, ((1.0 - d / cfg.maxDistance) ^ 1.6) * 1.4) * cfg.volume
end

local function stopCraneSound()
    craneAudioToken = craneAudioToken + 1
    craneAudioRunning = false
    if activeCraneSoundId then
        StopSound(activeCraneSoundId)
        ReleaseSoundId(activeCraneSoundId)
        activeCraneSoundId = nil
    end
    activeCraneAudioState = 'IDLE'
    SendNUIMessage({ action = 'craneAudio', state = 'STOP' })
end

local function playCraneAudio(state, coords)
    if state == 'IDLE' or state == 'FINISHED' then
        stopCraneSound()
        return
    end
    if not coords or not coords.x then return end

    -- the same stage again (a new crane spot of the same stage): just keep following the crane
    if state == activeCraneAudioState and craneAudioRunning then
        craneAudioCoords = coords
        return
    end

    stopCraneSound()
    activeCraneAudioState = state
    craneAudioCoords = coords

    local cfg = craneAudioCfg()
    local px, py, pz = tonumber(coords.x) or 0.0, tonumber(coords.y) or 0.0, tonumber(coords.z) or 6.0
    local vol = craneVolume(coords)

    if state == 'IMPACT' then
        -- the container lands: heavy metal thump + clank, then silence
        if cfg.native and vol > 0.02 then
            PlaySoundFromCoord(-1, 'Crane_Drop', px, py, pz, 'DOCKS_HEIST_SOUNDS', false, 95, false)
            PlaySoundFromCoord(-1, 'Door_Open_Limit', px, py, pz, 'DOCKS_HEIST_SOUNDS', false, 70, false)
        end
        if cfg.synth then SendNUIMessage({ action = 'craneAudio', state = 'IMPACT', volume = vol }) end
        activeCraneAudioState = 'IDLE'
        return
    end

    if state ~= 'PICKING_UP' and state ~= 'MOVING' and state ~= 'PLACING' then return end

    -- the looping stage: winch (picking up), gantry roll (moving), lowering (placing)
    if cfg.native then
        activeCraneSoundId = GetSoundId()
        PlaySoundFromCoord(activeCraneSoundId, 'Crane_Move_Loop', px, py, pz, 'DOCKS_HEIST_SOUNDS', false, 85, false)
        if state == 'PICKING_UP' then
            PlaySoundFromCoord(-1, 'Pin_Good', px, py, pz, 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', false, 50, false)
        end
        -- a sound the game could not start is "finished" at once: say so once, so the silence has a reason in the log
        local id, tok = activeCraneSoundId, craneAudioToken
        CreateThread(function()
            Wait(300)
            if tok == craneAudioToken and id and HasSoundFinished(id) and not nativeWarned then
                nativeWarned = true
                print('[nova_convoytruck] the game crane sound "Crane_Move_Loop" (DOCKS_HEIST_SOUNDS) did not start — its audio bank is not loaded or the name does not exist in this build. ' ..
                    (cfg.synth and 'The synthesised crane sound is playing instead.' or 'Set Config.ContainerWars.craneAudio.synth = true to hear one.'))
            end
        end)
    end
    if cfg.synth then SendNUIMessage({ action = 'craneAudio', state = state, volume = vol }) end

    -- the player walks around while the crane works: keep the loudness following the distance
    craneAudioRunning = true
    local token = craneAudioToken
    CreateThread(function()
        while craneAudioToken == token and craneAudioRunning do
            Wait(250)
            if craneAudioToken ~= token then break end
            if cfg.synth then SendNUIMessage({ action = 'craneAudio', state = 'VOLUME', volume = craneVolume(craneAudioCoords) }) end
        end
    end)
end

-- /cwcranesound — plays every stage of the crane at your feet (picking up, moving, placing, then the landing)
RegisterCommand('cwcranesound', function()
    local p = GetEntityCoords(PlayerPedId())
    local at = { x = p.x, y = p.y, z = p.z }
    CreateThread(function()
        for _, st in ipairs({ 'PICKING_UP', 'MOVING', 'PLACING' }) do
            lib.notify({ title = 'Crane sound', description = st, type = 'inform', duration = 2500 })
            playCraneAudio(st, at)
            Wait(2500)
        end
        lib.notify({ title = 'Crane sound', description = 'IMPACT', type = 'inform', duration = 2000 })
        playCraneAudio('IMPACT', at)
        Wait(1500)
        playCraneAudio('FINISHED')
    end)
end, false)

NovaConvoy = NovaConvoy or {}
NovaConvoy.playCraneAudio = playCraneAudio
NovaConvoy.stopCraneAudio = stopCraneSound

RegisterNetEvent('nova_convoytruck:containerWars:client:craneAudioState', function(data)
    if not data or not data.state then return end
    playCraneAudio(data.state, data.coords)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:eventEnded', function(convoyId)
    activeEvent = nil
    activeContainerId = nil
    cwFlow = { kind = 'IDLE' }
    SendNUIMessage({ action = 'cwTimer:frame', visible = false })
    SendNUIMessage({ action = 'cwCivilianInfo:frame', visible = false })
    containersState = {}
    inBiddingZone = false
    stopCraneSound()
    if biddingZone then
        biddingZone:remove()
        biddingZone = nil
    end
    zonePoints = nil
    restoreWorldContainers()
    clearAllOpenState()
    resetBidding()
    SendNUIMessage({ action = 'containerInfo:frame', items = {} })
    SendNUIMessage({ action = 'cwVehicleReward:frame', items = {} })
    if eventRadiusBlip and DoesBlipExist(eventRadiusBlip) then
        RemoveBlip(eventRadiusBlip)
        eventRadiusBlip = nil
    end
    if eventBlip and DoesBlipExist(eventBlip) then
        RemoveBlip(eventBlip)
        eventBlip = nil
    end
    clearRewardBlips()
end)

-- ── In-world container info panel + bid key ───────────────────────────────────
-- The panel is the supplied Container Wars info UI (web/src/lib/hud/ContainerInfo.svelte).
-- Renders ONLY for the single currently active container (activeContainerId) sequentially.
CreateThread(function()
    local sentAny = false
    while true do
        local sleep = 1000
        local items = {}

        if bid.state == 'rejected' and GetGameTimer() >= bid.rejectUntil then bid.state = 'idle' end
        if bid.open then
            local st = containersState[bid.containerId]
            local ok = activeEvent and st and st.status == 'AUCTION_ACTIVE' and (st.timeRemaining or 0) > 0
                and inBiddingZone and not IsPedDeadOrDying(PlayerPedId(), true)
            if ok and st.coords and st.coords.x then
                ok = #(GetEntityCoords(PlayerPedId()) - vector3(st.coords.x, st.coords.y, st.coords.z)) < BID_CLOSE_DISTANCE
            end
            if not ok then
                closeBidder()
                bidNotify('warning', 'Bidding window closed.')
            end
        end

        -- Only render the Container Top UI for the single currently active container
        if activeEvent and activeContainerId and containersState[activeContainerId] then
            local c = containersState[activeContainerId]
            local coords = c.coords
            if coords and coords.x then
                local plyCoords = GetEntityCoords(PlayerPedId())
                local visCfg = (Config.ContainerWars and Config.ContainerWars.visuals) or {}
                local maxDist = visCfg.drawDistance or 75.0
                local infoHeight = visCfg.infoHeight or 3.6   -- metres above container origin
                local markerType = visCfg.winningMarkerType or 2
                local mCol = visCfg.winningColor or { r = 255, g = 215, b = 0, a = 200 }

                local dist = #(plyCoords - vector3(coords.x, coords.y, coords.z))
                if dist < maxDist then
                    sleep = 0
                    local mode = nil
                    if c.status == 'AUCTION_ACTIVE' or c.status == 'DELIVERED' then
                        mode = 'active'
                    elseif c.status == 'WON' or c.status == 'CLAIMED' or c.status == 'OPENING_DOORS' then
                        mode = 'won'
                    elseif c.status == 'UNSOLD' then
                        mode = 'unsold'
                    end

                    -- Inside the perimeter, within bidDistance of the container, and the auction still running.
                    local canBid = c.status == 'AUCTION_ACTIVE' and (c.timeRemaining or 0) > 0 and inBiddingZone and dist < BID_DISTANCE
                    if canBid and not bid.open then
                        showBidPrompt()
                    else
                        hideBidPrompt()
                    end

                    if canBid and IsControlJustPressed(0, 38) then -- Key E
                        hideBidPrompt()
                        openBidder(c)
                    end

                    if mode then
                        local onScreen, sx, sy = World3dToScreen2d(coords.x, coords.y, coords.z + infoHeight)
                        if onScreen then
                            local scale = math.max(0.5, math.min(1.0, 1.0 - ((dist - 10.0) / math.max(1.0, (maxDist - 10.0))) * 0.5))
                            items[#items + 1] = {
                                id = c.id,
                                mode = mode,
                                x = sx, y = sy, scale = scale,
                                containerNumber = c.containerIndex or 1,
                                containerName = c.name or 'Container',
                                highestBid = c.currentBid or 0,
                                minNextBid = (c.currentBid or 0) + (c.bidIncrement or 1000),
                                highestGang = c.highestBidderGang,
                                highestPlayer = c.highestBidderName,
                                timeLeft = c.timeRemaining or 0,
                                canBid = canBid,
                                bidState = (bid.containerId == c.id) and bid.state or 'idle',
                                finalBid = c.finalBid or c.currentBid or 0,
                                winningGang = c.winnerGang or c.winnerGangName,
                                winningPlayer = c.winnerPlayer,
                                opened = c.status == 'CLAIMED', -- ONLY true once claimed, container stays closed until opened
                                nextDropIn = (mode ~= 'active' and cwFlow.kind == 'NEXT' and cwFlow.endsAt)
                                    and math.max(0, math.ceil((cwFlow.endsAt - GetGameTimer()) / 1000)) or nil,
                            }
                        end
                    end

                    -- Gold chevron over won container
                    if c.status == 'WON' and (visCfg.show3DWorldMarker ~= false) then
                        DrawMarker(markerType, coords.x, coords.y, coords.z + infoHeight + 0.4, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.6, 0.6, 0.5, mCol.r or 255, mCol.g or 215, mCol.b or 0, mCol.a or 200, false, true, 2, nil, nil, false)
                    end
                end
            end
        end

        if #items > 0 then
            SendNUIMessage({ action = 'containerInfo:frame', items = items })
            sentAny = true
        elseif sentAny then
            SendNUIMessage({ action = 'containerInfo:frame', items = {} })
            sentAny = false
        end
        Wait(sleep)
    end
end)

-- ── Zone timer ────────────────────────────────────────────────────────────────
-- Reused existing Timer UI for all phases: START_COUNTDOWN, DELIVERING, BIDSOON, BIDDING, AUCTION_CLOSED
local function money(n) return '$' .. tostring(math.floor(tonumber(n) or 0)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '') end

local function zoneTimerFrame()
    local f = cwFlow
    local now = GetGameTimer()
    local function left() return math.max(0, math.ceil(((f.endsAt or now) - now) / 1000)) end
    local num = f.n and (' #' .. tostring(f.n)) or ''

    if f.kind == 'START_COUNTDOWN' then
        local s = f.seconds ~= nil and f.seconds or left()
        return {
            visible = true,
            tone = 'wait',
            title = 'CONTAINER WAR',
            label = s > 0 and 'EVENT STARTING IN' or 'STARTING NOW',
            seconds = s,
            sub = ('%d Containers Staged'):format(f.totalContainers or 1),
        }
    elseif f.kind == 'NEXT' then
        return { visible = true, tone = 'wait', title = 'CONTAINER WARS', label = ('Next container%s drops in'):format(num), seconds = left(), sub = f.name }
    elseif f.kind == 'DELIVERING' then
        return { visible = true, tone = 'wait', title = ('CONTAINER%s'):format(num), label = 'Being delivered by crane', sub = f.name }
    elseif f.kind == 'BIDSOON' then
        return { visible = true, tone = 'wait', title = ('CONTAINER%s'):format(num), label = 'Bidding opens in', seconds = left(), sub = f.name }
    elseif f.kind == 'BIDDING' then
        local c = containersState[f.id]
        if not c or c.status ~= 'AUCTION_ACTIVE' then return nil end
        local leader = c.highestBidderGang
        if leader and c.highestBidderName then leader = leader .. ' · ' .. c.highestBidderName end
        return {
            visible = true,
            tone = 'live',
            title = ('CONTAINER%s AUCTION'):format(num),
            label = tostring(c.name or 'Container'),
            seconds = c.timeRemaining or 0,
            bid = money(c.currentBid),
            leader = leader or 'No bids yet',
        }
    elseif f.kind == 'AUCTION_CLOSED' then
        return {
            visible = true,
            tone = 'wait',
            title = ('CONTAINER%s'):format(num),
            label = f.label or 'AUCTION CLOSED',
            sub = f.sub or '',
        }
    end
    return nil
end

-- ── Civilian Info Panel ───────────────────────────────────────────────────────
-- Civilian-facing informational panel (web/src/lib/hud/ContainerCivilianPanel.svelte).
-- Shown whenever a player is inside the bidding perimeter/radius, tracking sequential active container.
local function formatBidderName(c, isWinner)
    if not c then return 'No Bids' end
    if isWinner then
        local p = c.winnerPlayer
        local g = c.winnerGang or c.winnerGangName
        if p and p ~= '' and g and g ~= '' then return p .. ' (' .. g .. ')' end
        if p and p ~= '' then return p end
        if g and g ~= '' then return g end
        return 'Winner'
    end
    local p = c.highestBidderName
    local g = c.highestBidderGang or c.highestBidderGangName
    if p and p ~= '' and g and g ~= '' then return p .. ' (' .. g .. ')' end
    if p and p ~= '' then return p end
    if g and g ~= '' then return g end
    return 'No Bids'
end

local function formatContainerHeader(idx, name)
    local num = tonumber(idx) or 1
    local numStr = ('CONTAINER #%d'):format(num)
    if not name or name == '' then return numStr end
    local clean = tostring(name):gsub('%s*[%-–—·]%s*', ' — ')
    if clean:lower():find('^container') then
        return clean:upper()
    end
    return ('%s — %s'):format(numStr, clean:upper())
end

local function civilianInfoFrame()
    if not activeEvent then return nil end
    local f = cwFlow
    local now = GetGameTimer()
    local function left() return math.max(0, math.ceil(((f.endsAt or now) - now) / 1000)) end

    local activeC = activeContainerId and containersState[activeContainerId]
    if not activeC and activeEvent.containers and #activeEvent.containers > 0 then
        activeC = containersState[activeEvent.containers[1].id]
    end

    local cIndex = (activeC and activeC.containerIndex) or f.n or 1
    local cName = (activeC and activeC.name) or f.name or ('Container #%d'):format(cIndex)
    local headerTitle = formatContainerHeader(cIndex, cName)
    local curBid = (activeC and (activeC.finalBid or activeC.currentBid)) or 5000
    local nextBid = (activeC and ((activeC.currentBid or 5000) + (activeC.bidIncrement or 1000))) or 6000

    if f.kind == 'START_COUNTDOWN' then
        return nil -- Civilian HUD stays hidden during start countdown; top countdown UI is shown instead
    elseif f.kind == 'CLAIM_WINDOW' then
        local s = left()
        local winName = f.winnerName and (f.winnerName .. (f.winnerGang and (' (' .. f.winnerGang .. ')') or ''))
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = 'REWARD CLAIM',
            statusTone = 'sold',
            containerSubtitle = 'LOT #' .. tostring(cIndex) .. ' AUCTION WON',
            containerHeader = headerTitle,
            currentBid = curBid,
            nextBid = nil,
            nextBidText = 'WON',
            bidderLabel = 'Winner',
            bidderName = winName or formatBidderName(activeC, true),
            timerLabel = 'CLAIM TIME',
            timeLeft = s,
            footer = 'WINNER HAS TIME TO OPEN AND CLAIM REWARDS',
        }
    elseif f.kind == 'DELIVERING' then
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = 'COMING NEXT',
            statusTone = 'wait',
            containerSubtitle = 'UPCOMING CONTAINER',
            containerHeader = headerTitle,
            currentBid = curBid,
            nextBid = nextBid,
            bidderLabel = 'Current Bidder',
            bidderName = 'Crane delivery in progress',
            timerLabel = 'DELIVERING',
            timeLeft = left(),
            footer = 'CONTAINER BEING PLACED BY CRANE',
        }
    elseif f.kind == 'NEXT' then
        local nextNum = f.n or ((cIndex or 1) + 1)
        local nextHeader = formatContainerHeader(nextNum, f.name)
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = 'COMING NEXT',
            statusTone = 'wait',
            containerSubtitle = 'UPCOMING CONTAINER',
            containerHeader = nextHeader,
            currentBid = curBid,
            nextBid = nextBid,
            bidderLabel = 'Current Bidder',
            bidderName = 'Staging next container',
            timerLabel = 'DROPS IN',
            timeLeft = left(),
            footer = 'PREPARE FOR NEXT AUCTION',
        }
    elseif f.kind == 'BIDSOON' then
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = 'BIDDING SOON',
            statusTone = 'wait',
            containerSubtitle = 'CURRENT CONTAINER',
            containerHeader = headerTitle,
            currentBid = curBid,
            nextBid = nextBid,
            bidderLabel = 'Current Bidder',
            bidderName = 'No Bids',
            timerLabel = 'OPENS IN',
            timeLeft = left(),
            footer = 'BIDDING OPENS SHORTLY',
        }
    elseif f.kind == 'BIDDING' then
        local canBidNow = inBiddingZone and activeC and activeC.status == 'AUCTION_ACTIVE' and (activeC.timeRemaining or 0) > 0
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = 'AUCTION ACTIVE',
            statusTone = 'live',
            containerSubtitle = 'CURRENT CONTAINER',
            containerHeader = headerTitle,
            currentBid = curBid,
            nextBid = nextBid,
            bidderLabel = 'Current Bidder',
            bidderName = formatBidderName(activeC, false),
            timerLabel = 'TIME LEFT',
            timeLeft = (activeC and activeC.timeRemaining) or 0,
            canBid = canBidNow,
            footer = canBidNow and 'PRESS [E] TO PLACE BID' or 'ENTER AUCTION AREA TO BID',
        }
    elseif f.kind == 'AUCTION_CLOSED' then
        local isWon = activeC and (activeC.status == 'WON' or activeC.status == 'CLAIMED' or activeC.status == 'OPENING_DOORS' or activeC.status == 'OPENED')
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = isWon and 'SOLD' or 'NO WINNER',
            statusTone = isWon and 'sold' or 'closed',
            containerSubtitle = 'AUCTION RESULT',
            containerHeader = headerTitle,
            currentBid = (activeC and (activeC.finalBid or activeC.currentBid)) or curBid,
            nextBid = nil,
            nextBidText = 'CLOSED',
            bidderLabel = isWon and 'Winning Bidder' or 'Current Bidder',
            bidderName = formatBidderName(activeC, isWon),
            timerLabel = 'STATUS',
            timeText = isWon and 'SOLD' or 'NO WINNER',
            footer = isWon and 'CONTAINER AUCTION CONCLUDED' or 'AUCTION CONCLUDED',
        }
    else
        return {
            visible = true,
            title = 'CONTAINER WAR',
            status = 'AUCTION ACTIVE',
            statusTone = 'wait',
            containerSubtitle = 'CURRENT CONTAINER',
            containerHeader = headerTitle,
            currentBid = curBid,
            nextBid = nextBid,
            bidderLabel = 'Current Bidder',
            bidderName = formatBidderName(activeC, false),
            timerLabel = 'STATUS',
            timeText = 'WAITING',
            footer = 'CONTAINER AUCTION YARD',
        }
    end
end

CreateThread(function()
    local civilianShown = false
    local timerShown = false
    while true do
        Wait(activeEvent and 250 or 1000)
        local civilianFrame = nil
        local isStartCountdown = (cwFlow and cwFlow.kind == 'START_COUNTDOWN')
        if activeEvent then
            local visDist = (Config.ContainerWars and Config.ContainerWars.visuals and Config.ContainerWars.visuals.drawDistance) or 75.0
            local inside = inBiddingZone
            if not inside then
                local plyCoords = GetEntityCoords(PlayerPedId())
                local activeC = activeContainerId and containersState[activeContainerId]
                if activeC and activeC.coords and activeC.coords.x then
                    inside = #(plyCoords - vector3(activeC.coords.x, activeC.coords.y, activeC.coords.z)) < visDist
                elseif zonePoints and #zonePoints >= 3 then
                    inside = #(vec3(plyCoords.x, plyCoords.y, zonePoints[1].z) - vec3(zonePoints[1].x, zonePoints[1].y, zonePoints[1].z)) < visDist
                else
                    local c = (activeEvent.crane and activeEvent.crane.x and activeEvent.crane)
                        or (activeEvent.containers and activeEvent.containers[1] and activeEvent.containers[1].dropCoords)
                    inside = c ~= nil and #(plyCoords - vector3(c.x, c.y, c.z or 0.0)) < visDist
                end
            end
            if inside then
                civilianFrame = civilianInfoFrame()
            end
        end

        -- Start countdown small UI: displays exact time remaining and ticks down cleanly
        if isStartCountdown then
            local now = GetGameTimer()
            local s = cwFlow.seconds ~= nil and cwFlow.seconds or math.max(0, math.ceil(((cwFlow.endsAt or now) - now) / 1000))
            SendNUIMessage({
                action = 'cwTimer:frame',
                visible = true,
                tone = 'wait',
                title = 'CONTAINER WARS',
                label = s > 0 and 'EVENT STARTING IN' or 'STARTING NOW',
                seconds = s,
                sub = ('%d Containers Staged'):format(cwFlow.totalContainers or 1),
            })
            timerShown = true
        elseif timerShown then
            SendNUIMessage({ action = 'cwTimer:frame', visible = false })
            timerShown = false
        end

        if civilianFrame then
            civilianFrame.action = 'cwCivilianInfo:frame'
            SendNUIMessage(civilianFrame)
            civilianShown = true
        elseif civilianShown then
            SendNUIMessage({ action = 'cwCivilianInfo:frame', visible = false })
            civilianShown = false
        end
    end
end)

-- ── Vehicle Claim Target for Won Container ───────────────────────────────────
local activeRewardVehicles = {}

local function waitEntity(bagName, timeout)
    local deadline = GetGameTimer() + (timeout or 6000)
    while GetGameTimer() < deadline do
        local ent = GetEntityFromStateBagName(bagName)
        if ent and ent ~= 0 and DoesEntityExist(ent) then return ent end
        Wait(100)
    end
    return nil
end

AddStateBagChangeHandler('cwRewardVehicle', nil, function(bagName, _, value)
    CreateThread(function()
        local ent = waitEntity(bagName)
        if not ent or not DoesEntityExist(ent) then return end
        if type(value) ~= 'table' then
            if activeRewardVehicles[ent] then
                pcall(function() exports.ox_target:removeLocalEntity(ent) end)
                activeRewardVehicles[ent] = nil
            end
            return
        end
        activeRewardVehicles[ent] = value
        pcall(function() exports.ox_target:removeLocalEntity(ent) end)   -- the state is set again when the car is moved: never two targets
        exports.ox_target:addLocalEntity(ent, { {
            name = 'cw_claim_vehicle_' .. tostring(value.containerId),
            label = ('Claim Won %s'):format(value.label or 'Vehicle'),
            icon = 'fa-solid fa-car-side',
            distance = 3.5,
            onSelect = function()
                TriggerServerEvent('nova_convoytruck:containerWars:server:claimVehicle', value.convoyId, value.containerId)
            end,
        } })
    end)
end)

RegisterNetEvent('nova_convoytruck:containerWars:client:rewardVehicleBlip', function(d)
    if type(d) ~= 'table' or not d.containerId then return end
    clearRewardBlips(d.containerId)
    if d.clear then return end
    local b = AddBlipForCoord((d.x or 0.0) + 0.0, (d.y or 0.0) + 0.0, (d.z or 0.0) + 0.0)
    SetBlipSprite(b, 225)
    SetBlipColour(b, 2)
    SetBlipScale(b, 1.0)
    SetBlipFlashes(b, true)
    SetBlipAsShortRange(b, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(('Reward Vehicle — %s'):format(d.name or 'Container Wars'))
    EndTextCommandSetBlipName(b)
    rewardBlips[d.containerId] = b
end)

-- ── 3D Floating Vehicle Information UI & Claim Hotkey ─────────────────────────
CreateThread(function()
    local vehSentAny = false
    while true do
        local sleep = next(activeRewardVehicles) and 350 or 1500
        local plyPed = PlayerPedId()
        local plyCoords = GetEntityCoords(plyPed)
        local items = {}

        for ent, data in pairs(activeRewardVehicles) do
            if DoesEntityExist(ent) and type(data) == 'table' then
                local vCoords = GetEntityCoords(ent)
                local dist = #(plyCoords - vCoords)
                if dist < 45.0 then
                    sleep = 0
                    local onScreen, sx, sy = World3dToScreen2d(vCoords.x, vCoords.y, vCoords.z + 1.25)
                    if onScreen then
                        local scale = math.max(0.65, math.min(1.0, 1.0 - ((dist - 5.0) / 40.0) * 0.35))
                        items[#items + 1] = {
                            id = tostring(data.containerId or NetworkGetNetworkIdFromEntity(ent)),
                            entityNetId = NetworkGetNetworkIdFromEntity(ent),
                            x = sx,
                            y = sy,
                            scale = scale,
                            dist = dist,
                            model = data.model or 'vehicle',
                            modelLabel = data.label or data.model or 'Vehicle',
                            bidderName = data.winnerPlayer or 'Winner',
                            containerName = data.containerName,
                            lotNumber = data.lotNumber,
                            winnerGang = data.winnerGang,
                            winnerGangLabel = data.winnerGangLabel or (data.winnerGang == 'civilian' and 'Civilian' or data.winnerGang or 'Civilian'),
                            finalPrice = data.finalBid or 0,
                            canClaim = dist < 3.5,
                        }
                    end

                    -- Quick claim hotkey [E] or [F] when standing right beside the vehicle
                    if dist < 3.5 and (IsControlJustPressed(0, 38) or (IsControlJustPressed(0, 23) and not IsPedInAnyVehicle(plyPed, false))) then
                        TriggerServerEvent('nova_convoytruck:containerWars:server:claimVehicle', data.convoyId, data.containerId)
                    end
                end
            else
                activeRewardVehicles[ent] = nil
            end
        end

        if #items > 0 then
            SendNUIMessage({ action = 'cwVehicleReward:frame', items = items })
            vehSentAny = true
        elseif vehSentAny then
            SendNUIMessage({ action = 'cwVehicleReward:frame', items = {} })
            vehSentAny = false
        end

        Wait(sleep)
    end
end)

-- ── Car-only lots: the claim clock ──────────────────────────────────────────────
-- The SERVER owns the 120 s clock (and decides who may claim); it sends the seconds left every few seconds and the client counts
-- down in between, only to draw the bar. /cwvehicle hides or shows the bar.
local claimTimers = {}      -- [containerId] = { left (s), at (ms when it arrived) }
local claimBarHidden = false

RegisterNetEvent('nova_convoytruck:containerWars:client:vehicleClaimTick', function(d)
    if type(d) ~= 'table' or not d.containerId then return end
    if d.done then claimTimers[d.containerId] = nil return end
    claimTimers[d.containerId] = { left = tonumber(d.left) or 0, at = GetGameTimer() }
end)

RegisterCommand('cwvehicle', function()
    claimBarHidden = not claimBarHidden
    if claimBarHidden then SendNUIMessage({ action = 'cwVehicleClaim:state', active = false }) end
end, false)

CreateThread(function()
    local shown = false
    while true do
        local best, bestDist
        local pc = GetEntityCoords(PlayerPedId())
        for ent, data in pairs(activeRewardVehicles) do
            if type(data) == 'table' and data.claimSeconds and claimTimers[data.containerId] and DoesEntityExist(ent) then
                local dist = #(pc - GetEntityCoords(ent))
                if dist < 80.0 and (not bestDist or dist < bestDist) then best, bestDist = data, dist end
            end
        end
        if best and not claimBarHidden then
            local t = claimTimers[best.containerId]
            local left = math.max(0.0, t.left - (GetGameTimer() - t.at) / 1000.0)
            SendNUIMessage({
                action = 'cwVehicleClaim:state', active = true,
                remaining = math.ceil(left), total = best.claimSeconds,
                winner = best.winnerPlayer, winnerGang = best.winnerGangLabel or best.winnerGang,
                container = best.containerName, lot = best.lotNumber, vehicle = best.label or best.model,
                price = best.finalBid, plate = best.plate,
                mine = best.winnerSrc ~= nil and best.winnerSrc == GetPlayerServerId(PlayerId()),
            })
            shown = true
            Wait(250)
        else
            if shown then SendNUIMessage({ action = 'cwVehicleClaim:state', active = false }) shown = false end
            Wait(best and 250 or 1000)
        end
    end
end)

-- Auto-claim if player enters the driver's seat of an active reward vehicle directly
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            if veh and veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local data = activeRewardVehicles[veh] or (DoesEntityExist(veh) and Entity(veh).state.cwRewardVehicle)
                if data and type(data) == 'table' then
                    TriggerServerEvent('nova_convoytruck:containerWars:server:claimVehicle', data.convoyId, data.containerId)
                    Wait(2500)
                end
            end
        end
        Wait(500)
    end
end)

-- ── Command / HUD toggles for Civilian Panel ─────────────────────────────────
local civilianPanelHidden = false

RegisterCommand('cwinfo', function()
    civilianPanelHidden = not civilianPanelHidden
    SendNUIMessage({ action = 'cwCivilianInfo:toggle', forced = not civilianPanelHidden })
end, false)
RegisterCommand('cwhud', function()
    civilianPanelHidden = not civilianPanelHidden
    SendNUIMessage({ action = 'cwCivilianInfo:toggle', forced = not civilianPanelHidden })
end, false)
RegisterCommand('cwmove', function()
    civilianPanelHidden = false
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'cwCivilianInfo:moveMode' })
end, false)

RegisterNUICallback('cwCivilianInfo:startMove', function(_, cb)
    SetNuiFocus(true, true)
    cb({ ok = true })
end)

RegisterNUICallback('cwCivilianInfo:savePos', function(_, cb)
    SetNuiFocus(false, false)
    cb({ ok = true })
end)

RegisterNUICallback('cwCivilianInfo:cancelMove', function(_, cb)
    SetNuiFocus(false, false)
    cb({ ok = true })
end)

RegisterNUICallback('cwCivilianInfo:close', function(_, cb)
    civilianPanelHidden = true
    cb({ ok = true })
end)

-- ── Gantry crane check ────────────────────────────────────────────────────────
-- /cwgantrytest   spawns the harbour gantry (Config.ContainerWars.harbour.crane) locally and sweeps it
--                 across its whole reach: the cabin slides along its span and the frame rolls along its
--                 rails. Use it to check Config.ContainerWars.gantries (cabin height, span, wheels) by eye.
-- /cwgantryclear  removes it.
local gantryTest = { objs = {}, running = false }

local function localProp(name, x, y, z, heading)
    local hash = joaat(name)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 8000) then return nil end
    local obj = CreateObject(hash, x, y, z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if obj == 0 or not DoesEntityExist(obj) then return nil end
    SetEntityHeading(obj, heading)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    return obj
end

local function clearGantryTest()
    gantryTest.running = false
    for _, o in ipairs(gantryTest.objs) do if DoesEntityExist(o) then DeleteEntity(o) end end
    gantryTest.objs = {}
end

RegisterCommand('cwgantrytest', function()
    if gantryTest.running then return end
    local H = (Config.ContainerWars and Config.ContainerWars.harbour) or {}
    local crane = CWGantry.resolveCrane(H, #(H.pickups or {}))
    local g = crane and CWGantry.get(crane.model)
    if not g then
        lib.notify({ title = 'Gantry test', description = 'Config.ContainerWars.harbour.crane has no gantry description.', type = 'error' })
        return
    end
    clearGantryTest()
    gantryTest.running = true
    local ref = { x = crane.x, y = crane.y, z = crane.z, heading = crane.heading or 0.0 }
    local lay = CWGantry.layout(g, ref, ref.x, ref.y)
    local function add(o) if o then gantryTest.objs[#gantryTest.objs + 1] = o end return o end
    local frame = add(localProp(crane.model, lay.frame.x, lay.frame.y, lay.frame.z, lay.frame.heading))
    local cabin = add(localProp(g.cabin.model, lay.cabin.x, lay.cabin.y, lay.cabin.z, lay.cabin.heading))
    local wheels = {}
    for _, p in ipairs(lay.wheels) do
        local w = g.wheels and g.wheels.model and add(localProp(g.wheels.model, p.x, p.y, p.z, p.heading))
        if w then wheels[#wheels + 1] = w end
    end
    lib.notify({ title = 'Gantry test', description = ('frame %s, cabin %s, %d wheel(s). Sweeping for 30 s — /cwgantryclear to stop.'):format(frame and 'ok' or 'MISSING', cabin and 'ok' or 'MISSING', #wheels), type = frame and 'success' or 'error', duration = 9000 })
    if not frame then clearGantryTest() return end
    CreateThread(function()
        local t0 = GetGameTimer()
        local rail, span = g.rail or {}, g.span or {}
        local rx, ry = math.cos(math.rad(ref.heading)), math.sin(math.rad(ref.heading))
        local fx, fy = -math.sin(math.rad(ref.heading)), math.cos(math.rad(ref.heading))
        while gantryTest.running and GetGameTimer() - t0 < 30000 do
            local t = (GetGameTimer() - t0) / 1000.0
            local alongRange = math.min(10.0, (rail.max or 10.0))
            local along = math.sin(t * 0.35) * alongRange
            local mid = ((span.min or -7.0) + (span.max or 5.66)) / 2.0
            local half = ((span.max or 5.66) - (span.min or -7.0)) / 2.0
            local across = mid + math.sin(t * 0.8) * half
            local hx = ref.x + rx * along + fx * across
            local hy = ref.y + ry * along + fy * across
            local l = CWGantry.layout(g, ref, hx, hy)
            SetEntityCoords(frame, l.frame.x, l.frame.y, l.frame.z, false, false, false, false)
            if cabin then SetEntityCoords(cabin, l.cabin.x, l.cabin.y, l.cabin.z, false, false, false, false) end
            for i, w in ipairs(wheels) do
                local p = l.wheels[i]
                if p then SetEntityCoords(w, p.x, p.y, p.z, false, false, false, false) end
            end
            Wait(0)
        end
        clearGantryTest()
    end)
end, false)

RegisterCommand('cwgantryclear', clearGantryTest, false)

-- The server asks the admin who starts a Container Wars event for the real size of the crane's cable model (a
-- server cannot read model dimensions), so the rope is stacked with the true piece length and never pokes out of
-- the cabin. Returns { len, top, bottom } in metres, or nil if the model cannot be loaded.
lib.callback.register('nova_convoytruck:cw:modelDims', function(model)
    local hash = joaat(tostring(model))
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 5000) then return nil end
    local mn, mx = GetModelDimensions(hash)
    SetModelAsNoLongerNeeded(hash)
    if not mn or not mx then return nil end
    return { len = mx.z - mn.z, top = mx.z, bottom = mn.z }
end)

-- /cwhooktest [container_model]  spawns a container 12 m ahead with the grabber + cable parts of
--                                 Config.ContainerWars.hook placed on it, locally.
-- /cwhookset <part> <x> <y> <z> [heading]  moves one part and prints the config line.
local hookTest = { box = nil, parts = {}, at = nil, model = nil, marks = {}, drawing = false, show = false }

local function clearHookTest()
    HookRope.remove('cw_hooktest')
    hookTest.ropeHolder, hookTest.ropeTop = nil, nil
    for _, e in ipairs(hookTest.parts) do if DoesEntityExist(e) then DeleteEntity(e) end end
    hookTest.parts = {}
    hookTest.marks = {}
    if hookTest.box and DoesEntityExist(hookTest.box) then DeleteEntity(hookTest.box) end
    hookTest.box = nil
end

local function buildHookTest(keepAt)
    local cfg = Config.ContainerWars and Config.ContainerWars.hook
    local at, heading
    if keepAt then
        at, heading = keepAt.pos, keepAt.heading
    else
        local ped = PlayerPedId()
        at = GetOffsetFromEntityInWorldCoords(ped, 0.0, 12.0, 0.0)
        heading = GetEntityHeading(ped)
    end
    clearHookTest()
    hookTest.box = localProp(hookTest.model, at.x, at.y, at.z, heading)
    if not hookTest.box then
        lib.notify({ title = 'Hook test', description = ('Container model %s could not be created.'):format(tostring(hookTest.model)), type = 'error' })
        return
    end
    PlaceObjectOnGroundProperly(hookTest.box)
    hookTest.at = { pos = GetEntityCoords(hookTest.box), heading = heading }
    local base = hookTest.at.pos
    for i, part in ipairs(cfg and cfg.parts or {}) do
        local px, py, pz = base.x + (part.x or 0.0), base.y + (part.y or 0.0), base.z + (part.z or 0.0)
        local obj = localProp(part.model, px, py, pz, heading + (part.heading or 0.0))
        local ropeSkipped = false
        if obj and part.cable then
            -- real length of one cable piece, and the stretch up to the arm when a height was given
            local mn, mx = GetModelDimensions(NovaConvoy.SafeEntityModel(obj))
            local len = mx.z - mn.z
            print(('[nova_convoytruck] cable piece "%s": %.2f m long, reaches %.2f m above its origin (hook.cableSegmentLength = %.1f, hook.cableTop = %.1f)'):format(part.model, len, mx.z, len, mx.z))
            lib.notify({ title = 'Cable piece', description = ('%.2f m long, %.2f m above origin — set cableSegmentLength = %.1f and cableTop = %.1f in config.lua'):format(len, mx.z, len, mx.z), type = 'inform', duration = 12000 })
            -- the rope runs up to the underside of the crane cabin, exactly as it does in an event
            -- (/cwhooktest <model> <metres> overrides the height)
            local top = hookTest.arm and (base.z + hookTest.arm)
            if not top then
                local H = (Config.ContainerWars and Config.ContainerWars.harbour) or {}
                local crane = CWGantry.resolveCrane(H, #(H.pickups or {}))
                local g = crane and CWGantry.get(crane.model)
                if g then top = (crane.z or 0.0) + ((g.cabin and g.cabin.z) or 18.0) + (tonumber(g.cableTopOffset) or -1.0) end
            end
            local ropeLines = tostring((cfg and cfg.cableMode) or 'LINES'):upper() ~= 'PROPS'
            if ropeLines then
                -- LINES mode draws the rope from the cabin to the spreader (hook_rope.lua): the cable prop was only
                -- needed for its size, which is printed above
                DeleteEntity(obj)
                obj = nil
                ropeSkipped = true
                hookTest.ropeTop = top
            end
            -- pieces whose origin is not at their foot (this one is in the middle) are lifted so the foot sits on pz
            local lift = len - mx.z
            if obj then SetEntityCoords(obj, px, py, pz + lift, false, false, false, false) end
            if obj and top and len > 0.5 then
                local n = math.max(1, math.min(24, math.ceil((top - pz) / len) + 1))
                for k = 1, n - 1 do
                    local zk = math.min(pz + lift + k * len, top - mx.z)
                    local extra = localProp(part.model, px, py, math.max(pz, zk), heading + (part.heading or 0.0))
                    if extra then hookTest.parts[#hookTest.parts + 1] = extra end
                end
                lib.notify({ title = 'Hook test', description = ('Rope built up to z=%.1f (%d pieces of %.1f m).'):format(top, n, len), type = 'inform', duration = 6000 })
            end
        end
        if obj then
            hookTest.parts[#hookTest.parts + 1] = obj
            if not part.cable and not hookTest.ropeHolder then hookTest.ropeHolder = obj end
        elseif not ropeSkipped then
            lib.notify({ title = 'Hook test', description = ('Part %d (%s) could not be created in this game.'):format(i, tostring(part.model)), type = 'error', duration = 8000 })
        end
        hookTest.marks[#hookTest.marks + 1] = { x = px, y = py, z = pz, text = ('%d  %s  z=%.2f%s'):format(i, part.model, part.z or 0.0, (obj or ropeSkipped) and (ropeSkipped and '  (rope drawn as lines)' or '') or '  (NOT CREATED)'), ok = obj ~= nil or ropeSkipped }
    end
    -- LINES mode: draw the rope from the cabin's underside down to the spreader
    if hookTest.ropeTop and hookTest.ropeHolder and DoesEntityExist(hookTest.ropeHolder) then
        HookRope.set('cw_hooktest', hookTest.ropeHolder, hookTest.ropeTop)
    end

    -- Labels at each part's origin, so a part is easy to find even if it is small, hidden inside
    -- another model, or failed to spawn. Green = created, red = the game could not create it.
    hookTest.show = true
    if not hookTest.drawing then
        hookTest.drawing = true
        CreateThread(function()
            while hookTest.show do
                for _, m in ipairs(hookTest.marks) do
                    local r, g, b = m.ok and 70 or 255, m.ok and 214 or 70, m.ok and 154 or 70
                    DrawMarker(28, m.x, m.y, m.z, 0, 0, 0, 0, 0, 0, 0.18, 0.18, 0.18, r, g, b, 220, false, false, 2, false, nil, nil, false)
                    local on, sx, sy = World3dToScreen2d(m.x, m.y, m.z + 0.35)
                    if on then
                        SetTextScale(0.3, 0.3); SetTextFont(4); SetTextCentre(true); SetTextOutline()
                        SetTextColour(r, g, b, 255)
                        BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(m.text); EndTextCommandDisplayText(sx, sy)
                    end
                end
                Wait(0)
            end
            hookTest.drawing = false
        end)
    end
end

RegisterCommand('cwhooktest', function(_, args)
    hookTest.model = args[1] or 'prop_container_05a'
    hookTest.arm = tonumber(args[2])      -- optional: cable anchor height in metres above the ground
    buildHookTest(nil)
    lib.notify({ title = 'Hook test', description = 'Use /cwhookset <part> <x> <y> <z> [heading], /cwhookclear to remove.', type = 'inform', duration = 9000 })
end, false)

RegisterCommand('cwhookset', function(_, args)
    local cfg = Config.ContainerWars and Config.ContainerWars.hook
    local part = hookTest.model and cfg and cfg.parts and cfg.parts[tonumber(args[1]) or 0]
    if not part then
        lib.notify({ title = 'Hook test', description = 'Run /cwhooktest first, then /cwhookset <part number> <x> <y> <z> [heading].', type = 'error' })
        return
    end
    part.x = tonumber(args[2]) or part.x
    part.y = tonumber(args[3]) or part.y
    part.z = tonumber(args[4]) or part.z
    part.heading = tonumber(args[5]) or part.heading
    buildHookTest(hookTest.at)
    local line = ("{ model = '%s', x = %.2f, y = %.2f, z = %.2f, heading = %.1f },"):format(part.model, part.x, part.y, part.z, part.heading or 0.0)
    print('[nova_convoytruck] hook part ' .. args[1] .. ': ' .. line)
    lib.notify({ title = 'Hook part ' .. args[1], description = line, type = 'success', duration = 10000 })
end, false)

RegisterCommand('cwhookclear', function()
    hookTest.show = false
    clearHookTest()
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearGantryTest()
    hookTest.show = false
    clearHookTest()
    restoreWorldContainers()
    clearAllOpenState()
    stopCraneSound()
    if bid.open then SetNuiFocus(false, false) end
    previewPoints = nil
end)
