-- ─── Nova Convoy — Route Recorder (client) ────────────────────────────────────
-- The old way to build a route was: open the tablet, add a point, "Set to My
-- Position", close the tablet, drive/walk to the next spot, reopen the
-- tablet, repeat — for every single point, on a route that can easily need
-- a dozen+ of them. This lets an admin drive (or walk) the actual path once,
-- dropping a point with one key press wherever they want one, then return to
-- the tablet with the whole route already filled in.
--
-- Recorded points come in tagged ROUTE or AIRDROP depending on which key
-- dropped them. Converting a ROUTE point to a CHECKPOINT afterward needs no
-- new UI at all — RouteBuilder's own per-point type dropdown already does
-- exactly that; recording just fills the list in fast, the admin still
-- picks which ones matter.

local recording = false
local recordedPoints = {}
local recordBlips = {}
-- False for event kinds that have no such thing as an airdrop point (Rally)
-- — RallyRaceConfig discards the ROUTE/AIRDROP distinction entirely and
-- turns every recorded point into a plain checkpoint anyway, so showing
-- "[K] Airdrop Point" there was actively misleading, not just unused.
local airdropSupported = true
-- Identifies which builder started this recording session ('GANG_RACE',
-- 'CONVOY', ...). Echoed back on completion so ONLY that screen consumes the
-- points — without it, a Rally recording could be appended onto a Convoy's
-- route (or any other builder still listening), which is exactly the
-- cross-event vector bleed that was reported.
local recordTarget = 'CONVOY'

local function clearRecordBlips()
    for _, b in ipairs(recordBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    recordBlips = {}
end

local BLIP_BY_TYPE = {
    ROUTE = { sprite = 1, colour = 3 },
    AIRDROP = { sprite = 1, colour = 27 }, -- purple-ish, matches the tablet's own AIRDROP color
}

local function hudLine()
    local drop = airdropSupported
        and { { 'E', 'drop a route point' }, { 'K', 'drop an airdrop point' }, { 'Backspace', 'undo the last point' } }
        or { { 'E', 'drop a checkpoint' }, { 'Backspace', 'undo the last point' } }
    return NovaConvoy.KeyHelp('RECORDING ROUTE', {
        drop,
        { { 'Enter', 'FINISH & return to the tablet' } },
    }, { status = ('%d point%s'):format(#recordedPoints, #recordedPoints == 1 and '' or 's'), info = 'Drive or walk the path.' })
end

RegisterNUICallback('startRouteRecording', function(data, cb)
    cb('ok')
    if recording then return end
    recording = true
    recordedPoints = {}
    airdropSupported = not (data and data.supportsAirdrop == false)
    recordTarget = (data and data.target) or 'CONVOY'
    clearRecordBlips()
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    lib.notify({
        title = 'Route Recorder',
        description = 'Drive or walk the path. [E] drops a point, [Backspace] undoes the last one, [Enter] finishes and returns you to the Route tab with everything filled in.',
        type = 'info',
        duration = 8000,
    })
    lib.showTextUI(hudLine(), { position = 'right-center', icon = 'route' })
end)

-- pointType: 'ROUTE' (default, [E]) or 'AIRDROP' ([P]) — the recorder was
-- originally meant to only ever drop plain ROUTE points (airdrops added by
-- hand afterward), but the admin asked to be able to drop those while
-- driving too, same as any other point. RouteBuilder's own reactive sync
-- (syncByType) already auto-creates the matching airdrop config entry the
-- moment a point of type AIRDROP shows up in the route — nothing extra
-- needed here beyond tagging the point correctly.
local function dropPoint(pointType)
    if not recording then return end
    pointType = pointType or 'ROUTE'
    if pointType == 'AIRDROP' and not airdropSupported then
        pointType = 'ROUTE'
    end
    local ped = cache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    -- If they're driving, the point is meant to describe the ROAD the
    -- vehicle is on, not wherever inside the cab the ped happens to be —
    -- same coords either way in practice, heading is what actually matters
    -- for a truck's spawn/approach direction, and the vehicle's heading is
    -- the correct one to capture, not the ped's (which can differ slightly
    -- while looking around).
    if IsPedInAnyVehicle(ped, false) then
        heading = GetEntityHeading(GetVehiclePedIsIn(ped, false))
    end

    recordedPoints[#recordedPoints + 1] = { x = coords.x, y = coords.y, z = coords.z, heading = heading, type = pointType }

    local cfg = BLIP_BY_TYPE[pointType] or BLIP_BY_TYPE.ROUTE
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, cfg.sprite)
    SetBlipColour(blip, cfg.colour)
    SetBlipScale(blip, 0.7)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('%s %d'):format(pointType == 'AIRDROP' and 'Airdrop' or 'Route Point', #recordedPoints))
    EndTextCommandSetBlipName(blip)
    recordBlips[#recordBlips + 1] = blip

    lib.hideTextUI()
    lib.showTextUI(hudLine(), { position = 'right-center', icon = 'route' })
    PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', true)
end

local function undoLastPoint()
    if not recording or #recordedPoints == 0 then return end
    recordedPoints[#recordedPoints] = nil
    local lastBlip = recordBlips[#recordBlips]
    if lastBlip and DoesBlipExist(lastBlip) then RemoveBlip(lastBlip) end
    recordBlips[#recordBlips] = nil
    lib.hideTextUI()
    lib.showTextUI(hudLine(), { position = 'right-center', icon = 'route' })
    lib.notify({ title = 'Route Recorder', description = 'Last point undone.', type = 'warn', duration = 2000 })
end

local function finishRecording()
    if not recording then return end
    recording = false
    lib.hideTextUI()
    clearRecordBlips()

    local points = recordedPoints
    recordedPoints = {}
    local target = recordTarget
    recordTarget = 'CONVOY'

    TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
    SendNUIMessage({ action = 'routeRecording:complete', target = target, points = points })

    if #points > 0 then
        lib.notify({
            title = 'Route Recorder',
            description = ('%d point%s added to the route.'):format(#points, #points == 1 and '' or 's'),
            type = 'success',
            duration = 5000,
        })
    else
        lib.notify({ title = 'Route Recorder', description = 'No points were dropped — nothing added.', type = 'warn', duration = 4000 })
    end
end

-- RegisterKeyMapping (not raw control polling) on purpose — this doesn't
-- fight the vehicle's own driving controls (accelerate/brake/handbrake all
-- stay exactly where they are), and the player can freely rebind any of
-- these three from FiveM's own Settings > Key Bindings menu if E/Backspace/
-- Enter ever collides with something else on their end, same as any other
-- FiveM keybind.
RegisterCommand('convoy_routerecord_drop', function()
    dropPoint('ROUTE')
end, false)
RegisterKeyMapping('convoy_routerecord_drop', 'Route Recorder: Drop Route Point Here', 'keyboard', 'E')

RegisterCommand('convoy_routerecord_drop_airdrop', function()
    dropPoint('AIRDROP')
end, false)
-- Was 'P' — collides with the default map-open key in this framework, which
-- is exactly the kind of conflict RegisterKeyMapping (over raw control
-- polling) exists to let someone rebind on their own, but picking a key
-- that's free by default in the first place is one less thing to hit.
RegisterKeyMapping('convoy_routerecord_drop_airdrop', 'Route Recorder: Drop Airdrop Point Here', 'keyboard', 'K')

RegisterCommand('convoy_routerecord_undo', function()
    undoLastPoint()
end, false)
RegisterKeyMapping('convoy_routerecord_undo', 'Route Recorder: Undo Last Point', 'keyboard', 'BACK')

RegisterCommand('convoy_routerecord_finish', function()
    finishRecording()
end, false)
RegisterKeyMapping('convoy_routerecord_finish', 'Route Recorder: Finish and Return to Tablet', 'keyboard', 'RETURN')

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if recording then lib.hideTextUI() end
    clearRecordBlips()
end)
