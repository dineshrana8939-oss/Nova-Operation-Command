-- ─── Nova Convoy — Gang Rally / Street Race (Client) ─────────────────────────
-- Checkpoint markers, F1-style race tower HUD, race-token notifications and the
-- post-race police pursuit dispatch. A race is Start → Checkpoints → Finish.

local currentRally = nil
local activeStageIndex = 0
local totalStages = 0
local currentBlip = nil
local nextBlip = nil
local pursuitBlip = nil
local raceActive = false

local function cleanRallyBlips()
    if currentBlip and DoesBlipExist(currentBlip) then RemoveBlip(currentBlip) end
    if nextBlip and DoesBlipExist(nextBlip) then RemoveBlip(nextBlip) end
    currentBlip = nil
    nextBlip = nil
end

local function cleanPolicePursuitBlip()
    if pursuitBlip and DoesBlipExist(pursuitBlip) then
        RemoveBlip(pursuitBlip)
        pursuitBlip = nil
    end
end

-- Resolves one of Config.RallyNotifications, falling back to the given
-- defaults if the key/table is missing, and formatting %s/%d placeholders
-- against any extra args — mirrors convoy_runtime.lua's resolveBanner so
-- server owners have one consistent pattern for customizing any in-game text.
-- Returns nil (and shows nothing) when the entry is explicitly disabled.
local function rallyNotify(key, defaultTitle, defaultDescription, defaultType, defaultDuration, ...)
    local cfg = Config.RallyNotifications and Config.RallyNotifications[key]
    if cfg and cfg.enabled == false then return end

    local title = (cfg and cfg.title) or defaultTitle
    local description = (cfg and cfg.description) or defaultDescription
    local notifyType = (cfg and cfg.type) or defaultType
    local duration = (cfg and cfg.duration) or defaultDuration

    local args = { ... }
    if #args > 0 then
        local ok, formatted = pcall(string.format, description, ...)
        if ok then description = formatted end
    end

    lib.notify({
        title = title,
        description = description,
        type = notifyType,
        duration = duration,
        icon = 'flag-checkered',
        iconColor = '#ff6a00'
    })
end

local gridStatus = nil -- { ready, total, seconds } while waiting for racers to gather
local raceEpoch = 0 -- bumped whenever a race ends/cancels so in-flight countdowns stop
local holdStages = false -- true from joining the grid until GO: no checkpoint past the start counts

-- Server says which stage it is really waiting for — keeps both sides in step.
RegisterNetEvent('nova_convoytruck:client:rallyStageSync', function(stage)
    stage = tonumber(stage)
    if not stage or not raceActive or stage == activeStageIndex then return end
    activeStageIndex = stage
    cleanRallyBlips()
end)

local function runRaceCountdown()
-- Big on-screen countdown (racing-game style), 15 seconds down to GO. The
-- player's vehicle is held on the grid the whole time so nobody jumps the
-- start. Matches Runtime.startRaceCountdown's rt.raceGoAt server-side.
holdStages = true
local myEpoch = raceEpoch
CreateThread(function()
    local sf = RequestScaleformMovie('COUNTDOWN')
    local timeout = GetGameTimer() + 3000
    while not HasScaleformMovieLoaded(sf) and GetGameTimer() < timeout do Wait(0) end

    -- Freeze whichever vehicle this racer is actually driving for the WHOLE
    -- countdown, re-checked every tick — not just once at the top. A single
    -- check here used to miss two real cases: a racer still walking to their
    -- car when the countdown started (not in a vehicle yet, so `held` was
    -- false and they were never frozen once they did get in), and a racer
    -- who swapped seats/vehicles partway through. DisableControlAction is
    -- belt-and-suspenders on top of the freeze, in case of a brief network
    -- reconciliation window.
    local countdownOver = false
    local frozenVeh = nil
    CreateThread(function()
        while not countdownOver do
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                if veh ~= frozenVeh then
                    if frozenVeh and DoesEntityExist(frozenVeh) then FreezeEntityPosition(frozenVeh, false) end
                    frozenVeh = veh
                end
                FreezeEntityPosition(veh, true)
                DisableControlAction(0, 71, true) -- INPUT_VEH_ACCELERATE
                DisableControlAction(0, 72, true) -- INPUT_VEH_BRAKE
                DisableControlAction(0, 76, true) -- INPUT_VEH_HANDBRAKE
            end
            Wait(0)
        end
        if frozenVeh and DoesEntityExist(frozenVeh) then FreezeEntityPosition(frozenVeh, false) end
    end)

    local function show(text, r, g, b)
        if not HasScaleformMovieLoaded(sf) then return end
        BeginScaleformMovieMethod(sf, 'SET_MESSAGE')
        PushScaleformMovieMethodParameterString(text)
        PushScaleformMovieMethodParameterInt(r)
        PushScaleformMovieMethodParameterInt(g)
        PushScaleformMovieMethodParameterInt(b)
        PushScaleformMovieMethodParameterBool(true)
        EndScaleformMovieMethod()
        BeginScaleformMovieMethod(sf, 'FADE_MP')
        PushScaleformMovieMethodParameterString(text)
        PushScaleformMovieMethodParameterInt(r)
        PushScaleformMovieMethodParameterInt(g)
        PushScaleformMovieMethodParameterInt(b)
        EndScaleformMovieMethod()
    end

    local drawUntil = 0
    CreateThread(function()
        while GetGameTimer() < drawUntil or drawUntil == 0 do
            if HasScaleformMovieLoaded(sf) then DrawScaleformMovieFullscreen(sf, 255, 255, 255, 255, 0) end
            Wait(0)
        end
    end)

    local cancelled = false
    for i = 15, 1, -1 do
        if myEpoch ~= raceEpoch then cancelled = true break end -- race cancelled mid-countdown
        PlaySoundFrontend(-1, '3_2_1', 'HUD_MINI_GAME_SOUNDSET', true)
        show(tostring(i), 240, 200, 80)
        Wait(1000)
    end
    if myEpoch ~= raceEpoch then cancelled = true end
    if not cancelled then
        PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)
        show('GO', 50, 215, 75)
    end
    holdStages = false
    countdownOver = true -- releases the freeze thread above, whatever vehicle they ended up in
    Wait(1000)
    drawUntil = GetGameTimer()
    Wait(50)
    SetScaleformMovieAsNoLongerNeeded(sf)
end)
end

RegisterNetEvent('nova_convoytruck:client:rallyGridStatus', function(ready, total, seconds)
    -- Small NUI timer (in the race scoreboard) for how long racers have to reach
    -- the start zone. The GTA countdown takes over once it ends.
    gridStatus = { ready = ready, total = total, seconds = seconds }
    SendNUIMessage({ action = 'raceGridStatus', ready = ready, total = total, seconds = seconds })
end)

-- "Race starts in m:ss" before the grid opens, so participants can plan their way to the start.
RegisterNetEvent('nova_convoytruck:client:raceLeadStatus', function(name, seconds)
    SendNUIMessage({ action = 'raceGridStatus', label = 'Race starts in', sub = ('%s · Participants, be ready'):format(name or 'Street Race'), seconds = seconds })
end)

RegisterNetEvent('nova_convoytruck:client:raceLeadClear', function()
    if not gridStatus then SendNUIMessage({ action = 'raceGridHide' }) end
end)

RegisterNetEvent('nova_convoytruck:client:rallyCountdown', function()
    gridStatus = nil
    SendNUIMessage({ action = 'raceGridHide' })
    runRaceCountdown()
end)

-- Start-zone blip + radius shown to every gang member while the grid fills.
local startZones = {} -- raceId -> { blip, radius }

local function clearStartZone(id)
    local z = startZones[id]
    if not z then return end
    if z.blip and DoesBlipExist(z.blip) then RemoveBlip(z.blip) end
    if z.area and DoesBlipExist(z.area) then RemoveBlip(z.area) end
    startZones[id] = nil
end

RegisterNetEvent('nova_convoytruck:client:raceStartZone', function(z)
    if not z or not z.id then return end
    clearStartZone(z.id)
    local blip = AddBlipForCoord(z.x, z.y, z.z or 0.0)
    SetBlipSprite(blip, 38) -- checkered flag, same as the finish-line blip
    SetBlipColour(blip, 5)
    SetBlipScale(blip, 1.2)
    SetBlipAsShortRange(blip, false)
    SetBlipFlashes(blip, true)           -- blinks, so everybody can see this is where the race starts
    SetBlipFlashInterval(blip, 600)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('Race Start: %s'):format(z.name or 'Street Race'))
    EndTextCommandSetBlipName(blip)
    local area = AddBlipForRadius(z.x, z.y, z.z or 0.0, (tonumber(z.radius) or 15.0) + 0.0)
    SetBlipColour(area, 5)
    SetBlipAlpha(area, 110)
    SetBlipFlashes(area, true)
    SetBlipFlashInterval(area, 600)
    startZones[z.id] = { blip = blip, area = area, x = z.x + 0.0, y = z.y + 0.0, z = (z.z or 0.0) + 0.0, radius = (tonumber(z.radius) or 15.0) + 0.0 }
end)

-- The start zone is also marked in the world: a pulsing ring on the ground, visible from afar, while the zone exists
-- (the wait before the race, and the grid while racers gather).
CreateThread(function()
    while true do
        local sleep = 800
        if next(startZones) then
            local pos = GetEntityCoords(PlayerPedId())
            for _, zn in pairs(startZones) do
                if zn.x and #(pos - vec3(zn.x, zn.y, pos.z)) < 450.0 then
                    sleep = 0
                    local pulse = 0.5 + 0.5 * math.sin(GetGameTimer() / 260.0)
                    DrawMarker(1, zn.x, zn.y, zn.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, zn.radius * 2.0, zn.radius * 2.0, 8.0,
                        255, 214, 74, math.floor(60 + pulse * 90), false, false, 2, false, nil, nil, false)
                end
            end
        end
        Wait(sleep)
    end
end)

RegisterNetEvent('nova_convoytruck:client:raceStartZoneClear', function(id)
    clearStartZone(id)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(startZones) do clearStartZone(id) end
end)

-- ── Event: Start / Join Rally Race ──────────────────────────────────────────
RegisterNetEvent('nova_convoytruck:client:startRallyRace', function(data)
    currentRally = data
    activeStageIndex = 1
    totalStages = #(data.stages or {})
    raceActive = true
    LocalPlayer.state:set('isRacing', true, false)

    cleanRallyBlips()

    PlaySoundFrontend(-1, "Race_Lap", "Respawn_Online_Soundset", true)

    gridStatus = nil
    SendNUIMessage({ action = 'raceGridHide' })
    if not data.staging then runRaceCountdown() end
    if data.staging then
        holdStages = true
        rallyNotify('raceGrid', '🏁 HEAD TO THE START', 'Drive to the start line. The race begins once every racer is in position.', 'info', 7000)
    end
end)

-- ── Event: Update Leaderboard Tower HUD ─────────────────────────────────────
-- Ghost mode (collision off): while active, my vehicle ignores other racers' vehicles.
local ghostSources = nil
local ghostVeh = nil

local function clearGhost()
    ghostSources = nil
    if ghostVeh and DoesEntityExist(ghostVeh) then ResetEntityAlpha(ghostVeh) end
    ghostVeh = nil
end

CreateThread(function()
    while true do
        if ghostSources and raceActive then
            local myVeh = GetVehiclePedIsIn(PlayerPedId(), false)
            if ghostVeh and ghostVeh ~= myVeh and DoesEntityExist(ghostVeh) then ResetEntityAlpha(ghostVeh) end
            ghostVeh = myVeh ~= 0 and myVeh or nil
            if myVeh ~= 0 then
                local alpha = tonumber(Config.RallyRace and Config.RallyRace.ghostAlpha) or 170
                if alpha < 255 then SetEntityAlpha(myVeh, alpha, false) end
                local me = GetPlayerServerId(PlayerId())
                for _, sid in ipairs(ghostSources) do
                    if sid ~= me then
                        local ply = GetPlayerFromServerId(sid)
                        if ply ~= -1 then
                            local veh = GetVehiclePedIsIn(GetPlayerPed(ply), false)
                            if veh ~= 0 then SetEntityNoCollisionEntity(myVeh, veh, true) end
                        end
                    end
                end
            end
            Wait(0)
        else
            if ghostVeh then clearGhost() end
            Wait(500)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:client:updateRallyTower', function(towerData)
    if not raceActive then return end
    ghostSources = (towerData.collision == false) and towerData.racerSources or nil
    SendNUIMessage({
        action = 'raceTowerUpdate',
        title = towerData.title or (currentRally and currentRally.name) or 'GANG RALLY',
        currentCheckpoint = towerData.currentCheckpoint or activeStageIndex,
        totalCheckpoints = towerData.totalCheckpoints or totalStages,
        currentLap = towerData.currentLap or 1,
        totalLaps = towerData.totalLaps or 1,
        racers = towerData.racers or towerData.drivers or {},
        myIdentifier = towerData.myIdentifier,
        maxRows = towerData.maxRows,
        elapsedSeconds = towerData.elapsedSeconds,
    })
end)

-- ── Event: Rally Concluded / Stop ──────────────────────────────────────────
RegisterNetEvent('nova_convoytruck:client:endRallyRace', function()
    raceActive = false
    LocalPlayer.state:set('isRacing', false, false)
    clearGhost()
    gridStatus = nil
    SendNUIMessage({ action = 'raceGridHide' })
    holdStages = false
    raceEpoch = raceEpoch + 1
    currentRally = nil
    activeStageIndex = 0
    cleanRallyBlips()
    SendNUIMessage({ action = 'raceTowerHide' })
end)

-- ── Event: NFS-style finish banner (shown the moment you cross the line) ────
local function ordinal(n)
    local m100, m10 = n % 100, n % 10
    if m100 >= 11 and m100 <= 13 then return n .. 'TH' end
    if m10 == 1 then return n .. 'ST' elseif m10 == 2 then return n .. 'ND' elseif m10 == 3 then return n .. 'RD' end
    return n .. 'TH'
end

RegisterNetEvent('nova_convoytruck:client:rallyFinishBanner', function(position, tokens, seconds, gangXp)
    local fb = (Config.RallyRace and Config.RallyRace.finishBanner) or {}
    if fb.enabled == false then return end
    position = tonumber(position) or 0
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local title = ordinal(position) .. ' PLACE'
    local sub = ('TIME %02d:%02d'):format(math.floor(seconds / 60), seconds % 60)
    if (tokens or 0) > 0 then
        sub = sub .. ('   |   +%d RACE TOKEN%s'):format(tokens, tokens == 1 and '' or 'S')
    end
    -- gang members also see the Gang XP this position earns for their gang
    if (tonumber(gangXp) or 0) > 0 then
        sub = sub .. ('   |   +%d GANG XP'):format(math.floor(tonumber(gangXp)))
    end

    PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    -- Plain notification as well, so the result is never lost if the scaleform fails to load.
    lib.notify({ title = '🏁 ' .. title, description = sub, type = position == 1 and 'success' or 'inform', duration = 8000 })
    CreateThread(function()
        local sf = RequestScaleformMovie('MP_BIG_MESSAGE_FREEMODE')
        local timeout = GetGameTimer() + 3000
        while not HasScaleformMovieLoaded(sf) and GetGameTimer() < timeout do Wait(0) end
        if not HasScaleformMovieLoaded(sf) then return end
        BeginScaleformMovieMethod(sf, 'SHOW_SHARD_CENTERED_MP_MESSAGE')
        PushScaleformMovieMethodParameterString(title)
        PushScaleformMovieMethodParameterString(sub)
        PushScaleformMovieMethodParameterInt(position == 1 and 5 or 0)
        PushScaleformMovieMethodParameterInt(0)
        EndScaleformMovieMethod()
        local untilAt = GetGameTimer() + math.floor((tonumber(fb.seconds) or 6) * 1000)
        while GetGameTimer() < untilAt do
            DrawScaleformMovieFullscreen(sf, 255, 255, 255, 255, 0)
            Wait(0)
        end
        SetScaleformMovieAsNoLongerNeeded(sf)
    end)
end)

-- ── Event: Race tokens earned for the finishing position ────────────────────
RegisterNetEvent('nova_convoytruck:client:rallyTokensAwarded', function(amount, position, inInventory)
    if inInventory == false then
        lib.notify({ title = '🎟️ RACE TOKENS', description = ('Position %d earned %d race token(s), but they could not be added to your inventory.'):format(position or 0, amount or 0), type = 'warning', duration = 6000 })
        return
    end
    rallyNotify('raceTokens', '🎟️ RACE TOKENS EARNED', 'Position %d — %d race token(s) added to your inventory.', 'success', 5000, position or 0, amount or 0)
end)

-- ── Event: Police NFS-Style Pursuit Alert (Fired after race ends) ───────────
RegisterNetEvent('nova_convoytruck:client:rallyPolicePursuit', function(data)
    if not NovaConvoy.Roles.isPolice() then return end

    cleanPolicePursuitBlip()

    -- Play priority dispatch siren / tone
    PlaySoundFrontend(-1, "Out_Of_Bounds_Timer", "DLC_HEISTS_GENERAL_FRONTEND_SOUNDS", true)

    -- Create flashing destination blip at the race finish line
    local blip = AddBlipForCoord(data.x, data.y, data.z)
    SetBlipSprite(blip, 38) -- Checkered flag — same verified sprite as the in-race finish blip below, not 315
    SetBlipColour(blip, 1) -- Red
    SetBlipScale(blip, 1.3)
    SetBlipFlashes(blip, true)
    SetBlipFlashInterval(blip, 500)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, 1)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('10-99: Illegal Street Race Finish [%s]'):format(data.name or 'Street Race'))
    EndTextCommandSetBlipName(blip)

    pursuitBlip = blip

    rallyNotify('policePursuitAlert', '🚨 10-99: ILLEGAL STREET RACE TERMINATED',
        'Suspects are fleeing from the race finish line! Pursuit blip marked on your GPS.', 'error', 10000)

    -- Auto-clear pursuit blip after 3 minutes (180s)
    SetTimeout(180000, function()
        cleanPolicePursuitBlip()
    end)
end)

-- ── Active Checkpoint & Marker Drawing Thread ───────────────────────────────
CreateThread(function()
    while true do
        if raceActive and currentRally and currentRally.stages and activeStageIndex <= totalStages then
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local currentStage = currentRally.stages[activeStageIndex]
            local nextStage = currentRally.stages[activeStageIndex + 1]

            if currentStage and currentStage.x then
                local stagePos = vector3(currentStage.x, currentStage.y, currentStage.z)
                local dist = #(pCoords - stagePos)
                local isFinish = (activeStageIndex == totalStages)

                -- Update Minimap GPS Blips
                if not currentBlip or not DoesBlipExist(currentBlip) then
                    cleanRallyBlips()
                    currentBlip = AddBlipForCoord(stagePos.x, stagePos.y, stagePos.z)
                    SetBlipSprite(currentBlip, isFinish and 38 or 1)
                    SetBlipColour(currentBlip, isFinish and 2 or 5) -- Green finish / Gold checkpoint
                    SetBlipScale(currentBlip, 1.1)
                    SetBlipRoute(currentBlip, true)
                    SetBlipRouteColour(currentBlip, 5)

                    if nextStage and nextStage.x then
                        nextBlip = AddBlipForCoord(nextStage.x, nextStage.y, nextStage.z)
                        SetBlipSprite(nextBlip, 1)
                        SetBlipColour(nextBlip, 5)
                        SetBlipScale(nextBlip, 0.7)
                    end
                end

                -- Draw 3D in-world markers
                local markerColor = isFinish and { 16, 185, 129 } or { 234, 179, 8 }
                local rad = tonumber(currentStage.radius) or 15.0

                -- Checkpoint cylinder
                DrawMarker(
                    1, stagePos.x, stagePos.y, stagePos.z - 1.0,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    rad * 2.0, rad * 2.0, 4.0,
                    markerColor[1], markerColor[2], markerColor[3], 90,
                    false, false, 2, false, nil, nil, false
                )

                -- The FINISH is outlined with a red ring (double line), like the convoy destination
                if isFinish then
                    for _, r in ipairs({ rad, rad - 0.35 }) do
                        DrawMarker(25, stagePos.x, stagePos.y, stagePos.z - 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 1.0, 255, 45, 45, 235, false, false, 2, false, nil, nil, false)
                    end
                end

                -- Floating arrow or flag icon above cylinder
                DrawMarker(
                    isFinish and 4 or 21,
                    stagePos.x, stagePos.y, stagePos.z + 3.0,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    2.0, 2.0, 2.0,
                    markerColor[1], markerColor[2], markerColor[3], 180,
                    false, true, 2, true, nil, nil, false
                )

                -- Draw next checkpoint faintly if close
                if nextStage and nextStage.x and dist < 250.0 then
                    DrawMarker(
                        1, nextStage.x, nextStage.y, nextStage.z - 1.0,
                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        15.0, 15.0, 2.0,
                        255, 255, 255, 40,
                        false, false, 2, false, nil, nil, false
                    )
                end

                -- Checkpoint hit
                -- Past the start line nothing counts until GO (the server rejects it).
                if dist <= rad and not (activeStageIndex > 1 and holdStages) then
                    PlaySoundFrontend(-1, "CHECKPOINT_NORMAL", "HUD_MINI_GAME_SOUNDSET", true)
                    TriggerServerEvent('nova_convoytruck:rally:server:checkpointHit', currentRally.id, activeStageIndex)
                    activeStageIndex = activeStageIndex + 1
                    cleanRallyBlips()

                    if activeStageIndex > totalStages then
                        -- Finish Line Crossed!
                        PlaySoundFrontend(-1, "First_Place", "DLC_AW_Arena_Soundset", true)
                        rallyNotify('raceFinished', '🏁 FINISHED!', 'You have crossed the finish line! Awaiting final race standings...', 'success', 7000)
                        -- This racer is done: drop the scoreboard now (later updates are ignored
                        -- because raceActive is false) instead of waiting for the whole race to end.
                        raceActive = false
                        LocalPlayer.state:set('isRacing', false, false)
                        clearGhost()
                        SendNUIMessage({ action = 'raceTowerHide' })
                        SendNUIMessage({ action = 'raceGridHide' })
                    end
                end
            end
            Wait(0)
        else
            Wait(1000)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    cleanRallyBlips()
    cleanPolicePursuitBlip()
    SendNUIMessage({ action = 'raceTowerHide' })
end)
