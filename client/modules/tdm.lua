-- ─── Nova Convoy — TDM (client) ────────────────────────────────────────────────
-- Combat runtime for the TDM event kind: invincible-ped EMS isolation, hit
-- reporting, zone boundary enforcement, respawn, weapon vendor ped. See
-- server/modules/tdm_runtime.lua for the authoritative half of all of this —
-- this file only ever REPORTS observations (who shot whom, with what) and
-- renders whatever the server already decided; it never itself decides a
-- kill, a death, or a score, and never trusts a damage AMOUNT from the client.

local inMatch = false
local currentConvoyId = nil
local zoneHandle = nil -- CZone from lib.zones.poly
local lastGoodZonePos = nil

local TGT = exports.ox_target
local vendorPeds = {}
local vendorBlips = {}

local function despawnVendorPeds()
    for _, ped in ipairs(vendorPeds) do
        if ped and DoesEntityExist(ped) then
            TGT:removeLocalEntity(ped)
            DeleteEntity(ped)
        end
    end
    vendorPeds = {}
    for _, blip in ipairs(vendorBlips) do
        if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    vendorBlips = {}
end

local function spawnSingleVendorPed(location, teamKey, catalog, playerTeam)
    if not location or not location.x or location.enabled == false then return end
    local cfg = Config.TDM.weaponVendor or {}
    local pedModel = location.pedModel or cfg.pedModel or Config.Peds.thug
    lib.requestModel(pedModel)
    -- Ask for the ground at the spot and give it a moment, so the ped is not created over a hole in the map (frozen at
    -- z - 1 with no collision under it, it ended up below the floor / "somewhere else"), same as the World Peds do.
    RequestCollisionAtCoord(location.x + 0.0, location.y + 0.0, location.z + 0.0)
    local collisionDeadline = GetGameTimer() + 1500
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and GetGameTimer() < collisionDeadline do Wait(50) end
    Wait(150)
    local ped = CreatePed(4, pedModel, location.x + 0.0, location.y + 0.0, location.z - 1.0, (location.heading or 0.0) + 0.0, false, true)
    if not ped or ped == 0 then return end
    SetEntityAsMissionEntity(ped, true, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(pedModel)
    vendorPeds[#vendorPeds + 1] = ped

    -- Blip
    local isRed = (teamKey == 'A' or teamKey == 'RED')
    local isMyTeam = (playerTeam == teamKey)
    local blipColor = isRed and 1 or 38
    local teamLabel = isRed and 'Red Base Vendor (Team A)' or 'Blue Base Vendor (Team B)'
    local blip = AddBlipForCoord(location.x, location.y, location.z)
    SetBlipSprite(blip, 110)
    SetBlipColour(blip, blipColor)
    SetBlipScale(blip, isMyTeam and 0.9 or 0.7)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(teamLabel)
    EndTextCommandSetBlipName(blip)
    vendorBlips[#vendorBlips + 1] = blip

    local items = (catalog and #catalog > 0) and catalog or (cfg.items or {})
    local activeItems = {}
    for idx, item in ipairs(items) do
        if item.enabled ~= false then
            activeItems[#activeItems + 1] = { item = item, originalIndex = idx }
        end
    end

    TGT:addLocalEntity(ped, { {
        label = ('Buy Weapons (%s)'):format(isRed and 'Red Team' or 'Blue Team'),
        icon = 'fa-solid fa-gun',
        onSelect = function()
            -- the themed shop window (ped_menu.lua); the server still validates and charges every purchase (cash or bank)
            local list = {}
            for _, entry in ipairs(activeItems) do
                local it = entry.item
                list[#list + 1] = { id = entry.originalIndex, label = it.label or it.weapon, desc = ('%d rounds'):format(it.ammo or 60), tag = it.type, price = it.price or 0 }
            end
            PedMenu.open({
                title = teamLabel, subtitle = 'Weapons for this match',
                items = list,
                onPick = function(id, account) TriggerServerEvent('nova_convoytruck:tdm:server:purchase', id, account) end,
            })
        end,
    } })
end

local function spawnVendors(vendorRed, vendorBlue, catalog, playerTeam)
    despawnVendorPeds()
    if vendorRed and vendorRed.x then
        spawnSingleVendorPed(vendorRed, 'A', catalog, playerTeam)
    end
    if vendorBlue and vendorBlue.x then
        spawnSingleVendorPed(vendorBlue, 'B', catalog, playerTeam)
    end
end

-- Participant strays outside the configured combat zone polygon — warned and
-- snapped back to their last known position INSIDE the zone (tracked every
-- tick via `inside`), rather than teleported to some computed center point,
-- which reads much better on an irregular hand-placed polygon than a circle.
local function clearZoneHandle()
    if zoneHandle then
        zoneHandle:remove()
        zoneHandle = nil
    end
    lastGoodZonePos = nil
end

local function startZonePoly(zone)
    clearZoneHandle()
    if not zone or not zone.points or #zone.points < 3 then return end
    local points = {}
    for i, p in ipairs(zone.points) do
        points[i] = vector3(p.x, p.y, p.z)
    end
    zoneHandle = lib.zones.poly({
        points = points,
        -- Generous vertical extent (±100m) so uneven terrain across a large
        -- hand-walked polygon is never mistaken for "outside" the zone.
        thickness = 200.0,
        inside = function()
            lastGoodZonePos = GetEntityCoords(PlayerPedId())
        end,
        onExit = function()
            SendNUIMessage({ action = 'showToast', icon = '⚠', title = 'Combat Zone', message = 'Return to the TDM zone!', type = 'warn', duration = 2500 })
            if lastGoodZonePos then
                SetEntityCoords(PlayerPedId(), lastGoodZonePos.x, lastGoodZonePos.y, lastGoodZonePos.z, false, false, false, true)
            end
        end,
    })
end

local stagingZoneHandle = nil
local stagingBlip = nil
local inStagingZone = false
local stagingConvoyId = nil

local function clearStagingZone()
    if stagingZoneHandle then
        stagingZoneHandle:remove()
        stagingZoneHandle = nil
    end
    if stagingBlip and DoesBlipExist(stagingBlip) then
        RemoveBlip(stagingBlip)
        stagingBlip = nil
    end
    inStagingZone = false
    stagingConvoyId = nil
end

RegisterNetEvent('nova_convoytruck:tdm:client:enterStaging', function(convoyId, stagingZone, requiredPerTeam, myTeam, gangLabelA, gangLabelB)
    clearStagingZone()
    if not stagingZone or not stagingZone.points or #stagingZone.points < 3 then return end
    stagingConvoyId = convoyId

    local points = {}
    local center = vector3(0.0, 0.0, 0.0)
    for i, p in ipairs(stagingZone.points) do
        points[i] = vector3(p.x, p.y, p.z)
        center = center + points[i]
    end
    center = center / #points

    stagingBlip = AddBlipForCoord(center.x, center.y, center.z)
    SetBlipSprite(stagingBlip, 304)
    SetBlipColour(stagingBlip, 2)
    SetBlipScale(stagingBlip, 0.9)
    SetBlipAsShortRange(stagingBlip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('TDM Staging Zone')
    EndTextCommandSetBlipName(stagingBlip)

    stagingZoneHandle = lib.zones.poly({
        points = points,
        thickness = 100.0,
        onEnter = function()
            inStagingZone = true
            TriggerServerEvent('nova_convoytruck:tdm:server:updateStagingPresence', convoyId, true)
            SendNUIMessage({
                action = 'showToast',
                icon = '✔',
                title = 'Staging Zone',
                message = 'You are ready! Awaiting other fighters...',
                type = 'success',
                duration = 3500
            })
        end,
        onExit = function()
            inStagingZone = false
            TriggerServerEvent('nova_convoytruck:tdm:server:updateStagingPresence', convoyId, false)
            SendNUIMessage({
                action = 'showToast',
                icon = '⚠',
                title = 'Staging Zone',
                message = 'You left the staging zone!',
                type = 'warn',
                duration = 3000
            })
        end,
    })

    SendNUIMessage({
        action = 'showToast',
        icon = '📍',
        title = 'TDM Staging Active',
        message = ('Proceed to the green Staging Zone (%d needed per team)'):format(requiredPerTeam or 10),
        type = 'info',
        duration = 6000
    })
end)

RegisterNetEvent('nova_convoytruck:tdm:client:stagingUpdate', function(data)
    if not data then return end
    if data.countdown and data.countdown > 0 then
        SendNUIMessage({
            action = 'showToast',
            icon = '⏳',
            title = 'MATCH COUNTDOWN',
            message = ('Starting in %d seconds! Stand by for deployment...'):format(data.countdown),
            type = 'warn',
            duration = 1000
        })
    else
        SendNUIMessage({
            action = 'showToast',
            icon = '👥',
            title = 'Staging Ready-Up',
            message = ('%s: %d/%d  |  %s: %d/%d'):format(
                data.gangLabelA or 'Team Red', data.readyA or 0, data.required or 10,
                data.gangLabelB or 'Team Blue', data.readyB or 0, data.required or 10
            ),
            type = 'info',
            duration = 3000
        })
    end
end)

RegisterNetEvent('nova_convoytruck:tdm:client:endStaging', function()
    clearStagingZone()
end)

RegisterNetEvent('nova_convoytruck:tdm:client:beginCombat', function(convoyId, zone)
    clearStagingZone()
    inMatch = true
    NovaInTdm = true
    currentConvoyId = convoyId
    SetEntityInvincible(PlayerPedId(), true)
    startZonePoly(zone)
end)

RegisterNetEvent('nova_convoytruck:tdm:client:hp', function(hp, maxHp)
    SendNUIMessage({ action = 'playerHealth', hp = hp, max = maxHp })
end)

local function endMatchLocal()
    clearStagingZone()
    SendNUIMessage({ action = 'playerHealthHide' })
    inMatch = false
    NovaInTdm = false
    currentConvoyId = nil
    clearZoneHandle()
    SetEntityInvincible(PlayerPedId(), false)
    SetCurrentPedWeapon(PlayerPedId(), `WEAPON_UNARMED`, true)
    ConvoyUI.hideTdmMatch()
    despawnVendorPeds()
end
RegisterNetEvent('nova_convoytruck:tdm:client:endMatch', endMatchLocal)
-- logging out of / switching character mid-match: the new character must not stay invincible and zone-locked
RegisterNetEvent('nova_convoytruck:client:characterUnloaded', endMatchLocal)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', endMatchLocal)

-- Declared BEFORE the respawn handler below reads it: it used to be declared further down, so the handler read a nil global
-- and threw on every respawn (the Respawned toast never showed).
local eliminatedUntil = 0

RegisterNetEvent('nova_convoytruck:tdm:client:respawn', function(spawnPoint)
    local ped = PlayerPedId()
    if spawnPoint and spawnPoint.x then
        -- a base outside the combat polygon must not be undone by the zone's exit handler (it would teleport the player back)
        lastGoodZonePos = vector3(spawnPoint.x, spawnPoint.y, spawnPoint.z)
        SetEntityCoords(ped, spawnPoint.x, spawnPoint.y, spawnPoint.z, false, false, false, true)
        SetEntityHeading(ped, spawnPoint.heading or 0.0)
    end
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
    ResetPedVisibleDamage(ped)
    pcall(function()
        if exports.qbx_medical then exports.qbx_medical:revive() end
    end)
    TriggerEvent('qbx_medical:client:playerRevived')
    TriggerEvent('hospital:client:Revive')
    TriggerEvent('esx_ambulancejob:revive')
    if eliminatedUntil > 0 then
        eliminatedUntil = 0
        ClearPedTasksImmediately(ped)
    end
    SendNUIMessage({ action = 'tdmRespawnHide' })
    SendNUIMessage({ action = 'showToast', icon = '↺', title = 'Respawned', message = 'Back in the fight.', type = 'success', duration = 2000 })
end)

RegisterNetEvent('nova_convoytruck:tdm:client:hudUpdate', function(payload)
    if payload.action == 'start' then
        ConvoyUI.startTdmMatch(payload.seconds, payload.teamA, payload.teamB, payload.myKills, payload.myDeaths, payload.mvp)
    elseif payload.action == 'update' then
        ConvoyUI.updateTdmMatch(payload.seconds, payload.teamA, payload.teamB, payload.myKills, payload.myDeaths, payload.mvp)
    end
end)

-- Broadcast to every match participant, including the killer/victim
-- themselves — the kill feed card itself (showing killer/victim by name)
-- IS their personal feedback for a plain kill; the flash/streak below is
-- reserved for something more notable than an ordinary kill.
RegisterNetEvent('nova_convoytruck:tdm:client:killFeed', function(payload)
    ConvoyUI.tdmKillFeedEntry(payload)
end)

-- Personal-only (sent ONLY to the attacker who earned it) — headshot/
-- multi-kill/streak feedback, never broadcast.
RegisterNetEvent('nova_convoytruck:tdm:client:eventFlash', function(flashType, streak, victim, killer)
    ConvoyUI.tdmEventFlash(flashType, streak, victim)
    ConvoyUI.tdmKillConfirm(killer, victim)
end)

-- This player's virtual HP hit zero (they stay invincible in the match; the
-- server respawns them ~1.5s later). (eliminatedUntil itself is declared above the respawn handler.)

RegisterNetEvent('nova_convoytruck:tdm:client:eliminated', function(killerName, seconds)
    seconds = tonumber(seconds) or 3
    eliminatedUntil = GetGameTimer() + seconds * 1000
    -- They stay invincible (the server tracks HP), so the "death" is visual: drop
    -- the ped, lock firing, and show the respawn countdown.
    SetPedToRagdoll(PlayerPedId(), seconds * 1000, seconds * 1000, 0, false, false, false)
    SendNUIMessage({ action = 'tdmRespawnStart', seconds = seconds, killer = killerName or '' })
end)

CreateThread(function()
    while true do
        if GetGameTimer() < eliminatedUntil then
            DisablePlayerFiring(PlayerId(), true)
            DisableControlAction(0, 24, true)  -- attack
            DisableControlAction(0, 25, true)  -- aim
            DisableControlAction(0, 37, true)  -- weapon wheel
            DisableControlAction(0, 45, true)  -- reload
            Wait(0)
        else
            Wait(500)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:tdm:client:spawnVendors', function(vendorRed, vendorBlue, catalog, playerTeam)
    spawnVendors(vendorRed, vendorBlue, catalog, playerTeam)
end)

RegisterNetEvent('nova_convoytruck:tdm:client:spawnVendor', function(location)
    spawnVendors(location, nil, nil, 'A')
end)

RegisterNetEvent('nova_convoytruck:tdm:client:despawnVendor', function()
    despawnVendorPeds()
end)

-- Post-match results screen — shared with Practice Range (see
-- client/modules/practice_range.lua's own :client:matchResults handler and
-- web/src/lib/hud/MatchResults.svelte, which renders both modes).
-- First the WINS / DEFEATED banner and the overhead player cards of the player's own team (web/src/lib/hud/TdmOutcome.svelte) for a few seconds,
-- then the results window. The server sent the outcome and every number; this side only works out where each player's head is on the screen.
local outcomeShowing = false
local function showOutcomeBanner(banner, whenDone)
    outcomeShowing = true
    SendNUIMessage({ action = 'tdmOutcome:show', banner = banner })
    local untilAt = GetGameTimer() + math.floor((tonumber(banner.seconds) or 10) * 1000)
    CreateThread(function()
        while GetGameTimer() < untilAt do
            local pos = {}
            for _, c in ipairs(banner.cards or {}) do
                local pid = GetPlayerFromServerId(c.sid)
                if pid ~= -1 then
                    local ped = GetPlayerPed(pid)
                    if ped ~= 0 and DoesEntityExist(ped) then
                        local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
                        local on, sx, sy = World3dToScreen2d(head.x, head.y, head.z + 0.45)
                        local dist = #(GetGameplayCamCoord() - head)
                        pos[tostring(c.sid)] = { x = sx, y = sy, on = on and dist < 90.0 }
                    end
                end
            end
            SendNUIMessage({ action = 'tdmOutcome:pos', pos = pos })
            Wait(33)
        end
        SendNUIMessage({ action = 'tdmOutcome:hide' })
        outcomeShowing = false
        whenDone()
    end)
end

RegisterNetEvent('nova_convoytruck:tdm:client:matchResults', function(payload)
    local function openResults()
        NovaResultsOpen = true
        SetNuiFocus(true, true)
        if payload.outcome and payload.banner then payload.outcome.noSplash = true end
        ConvoyUI.showMatchResults(payload.mode, payload.eventName, payload.duration, payload.players, payload.scoreA, payload.scoreB, payload.outcome)
    end
    if payload.banner and not outcomeShowing then showOutcomeBanner(payload.banner, openResults) else openResults() end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and outcomeShowing then SendNUIMessage({ action = 'tdmOutcome:hide' }) end
end)

-- The standard community-known bone TAG for the head (SKEL_Head), used
-- throughout FiveM combat/headshot-detection scripts to compare against
-- GetPedLastDamageBone's output. Best-effort like the rest of this check —
-- purely cosmetic (kill-feed HEAD tag + personal flash banner), and NEVER
-- affects the actual damage/HP calculation below, so a wrong read here is
-- a missed/extra tag, never a balance exploit.
local HEAD_BONE_TAG = 31086

-- Hit reporting — only ever reports WHO shot WHOM with WHAT, plus a
-- best-effort cosmetic headshot flag (see reportHit in tdm_runtime.lua for
-- the actual damage-table lookup and kill decision, both fully server-side,
-- and unaffected by the headshot flag). Same event/arg indices already used
-- elsewhere in this resource for convoy PvP casualty tracking (runtime_client.lua).
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    if not inMatch then return end
    local victim, attacker = args[1], args[2]
    local weaponHash = args[7]
    if attacker ~= PlayerPedId() then return end
    if not victim or not DoesEntityExist(victim) or not IsEntityAPed(victim) or not IsPedAPlayer(victim) then return end
    local victimServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(victim))
    if not victimServerId or victimServerId <= 0 or victimServerId == GetPlayerServerId(PlayerId()) then return end
    local hasBone, boneId = GetPedLastDamageBone(victim)
    local wasHeadshot = hasBone and boneId == HEAD_BONE_TAG or false
    TriggerServerEvent('nova_convoytruck:tdm:server:reportHit', currentConvoyId, victimServerId, weaponHash, wasHeadshot)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    -- The one invariant that must never break: a player must never be left
    -- permanently invincible just because this resource restarted mid-match.
    if inMatch then SetEntityInvincible(PlayerPedId(), false) end
    clearZoneHandle()
    clearStagingZone()
    despawnVendorPeds()
end)
