-- ─── Nova Convoy — Zone Recorder (client) ──────────────────────────────────────
-- Same idea as route_recorder.lua, but for the two zone-based event kinds
-- (Hot Cargo's spawn/dropoff zones, Gang Airdrop's drop zones) instead of a
-- connected path — there's no "route" to drive here, just a set of
-- independent points, so walk to each spot and drop one with a key press
-- instead of reopening the tablet's "Add Manually" + "Set Position" flow for
-- every single zone.
--
-- Generic over what's being recorded: the NUI side tells us via
-- startZoneRecording's payload whether there's one zone type (Gang Airdrop —
-- [E] only) or two (Hot Cargo — [E] Spawn, [K] Dropoff), and the label to use
-- for each. Recorded points come back tagged 'A' (primary/[E]) or
-- 'B' (secondary/[K]) — the calling screen decides what an 'A'/'B' point
-- actually becomes (a spawn zone, a dropoff zone, a drop zone).

local recording = false
local recordedPoints = {}
local recordBlips = {}
local sessionCfg = { primaryLabel = 'Zone', secondaryLabel = nil }

local function clearRecordBlips()
    for _, b in ipairs(recordBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    recordBlips = {}
end

local function hudLine()
    local drop = { { 'E', 'drop a ' .. sessionCfg.primaryLabel } }
    if sessionCfg.secondaryLabel then drop[#drop + 1] = { 'K', 'drop a ' .. sessionCfg.secondaryLabel } end
    drop[#drop + 1] = { 'Backspace', 'undo the last one' }
    return NovaConvoy.KeyHelp('RECORDING ZONES', {
        drop,
        { { 'Enter', 'FINISH & return to the tablet' } },
    }, { status = ('%d point%s'):format(#recordedPoints, #recordedPoints == 1 and '' or 's'), info = 'Walk to each spot.' })
end

RegisterNUICallback('startZoneRecording', function(data, cb)
    cb('ok')
    if recording then return end
    recording = true
    recordedPoints = {}
    clearRecordBlips()
    data = data or {}
    sessionCfg = {
        primaryLabel = data.primaryLabel or 'Zone',
        secondaryLabel = data.secondaryLabel or nil,
        -- Which builder owns this session — echoed back on completion so only
        -- that screen consumes the points (see App.svelte).
        target = data.target or 'HOT_CARGO',
    }
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    lib.notify({
        title = 'Zone Recorder',
        description = sessionCfg.secondaryLabel
            and ('Walk to each spot. [E] drops a %s, [K] drops a %s. [Enter] finishes and returns you to the tablet.'):format(sessionCfg.primaryLabel, sessionCfg.secondaryLabel)
            or ('Walk to each spot and press [E] to drop a %s. [Enter] finishes and returns you to the tablet.'):format(sessionCfg.primaryLabel),
        type = 'info',
        duration = 8000,
    })
    lib.showTextUI(hudLine(), { position = 'right-center', icon = 'map-pin' })
end)

local function dropPoint(pointType)
    if not recording then return end
    if pointType == 'B' and not sessionCfg.secondaryLabel then return end
    local ped = cache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    recordedPoints[#recordedPoints + 1] = { x = coords.x, y = coords.y, z = coords.z, heading = heading, type = pointType }

    local label = pointType == 'B' and sessionCfg.secondaryLabel or sessionCfg.primaryLabel
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, pointType == 'B' and 27 or 3)
    SetBlipScale(blip, 0.7)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('%s %d'):format(label, #recordedPoints))
    EndTextCommandSetBlipName(blip)
    recordBlips[#recordBlips + 1] = blip

    lib.hideTextUI()
    lib.showTextUI(hudLine(), { position = 'right-center', icon = 'map-pin' })
    PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', true)
end

local function undoLastPoint()
    if not recording or #recordedPoints == 0 then return end
    recordedPoints[#recordedPoints] = nil
    local lastBlip = recordBlips[#recordBlips]
    if lastBlip and DoesBlipExist(lastBlip) then RemoveBlip(lastBlip) end
    recordBlips[#recordBlips] = nil
    lib.hideTextUI()
    lib.showTextUI(hudLine(), { position = 'right-center', icon = 'map-pin' })
    lib.notify({ title = 'Zone Recorder', description = 'Last zone undone.', type = 'warn', duration = 2000 })
end

local function finishRecording()
    if not recording then return end
    recording = false
    lib.hideTextUI()
    clearRecordBlips()

    local points = recordedPoints
    recordedPoints = {}

    TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
    SendNUIMessage({ action = 'zoneRecording:complete', target = sessionCfg.target or 'HOT_CARGO', points = points })

    if #points > 0 then
        lib.notify({
            title = 'Zone Recorder',
            description = ('%d zone%s added.'):format(#points, #points == 1 and '' or 's'),
            type = 'success',
            duration = 5000,
        })
    else
        lib.notify({ title = 'Zone Recorder', description = 'No zones were dropped — nothing added.', type = 'warn', duration = 4000 })
    end
end

-- Same keys as route_recorder.lua (E/K/Backspace/Enter) on purpose — only one
-- recorder is ever active at a time, and each command's own `recording` guard
-- means the inactive recorder's handler is a harmless no-op if both happen to
-- be bound to the same physical key.
RegisterCommand('convoy_zonerecord_drop', function()
    dropPoint('A')
end, false)
RegisterKeyMapping('convoy_zonerecord_drop', 'Zone Recorder: Drop Zone (Primary)', 'keyboard', 'E')

RegisterCommand('convoy_zonerecord_drop_secondary', function()
    dropPoint('B')
end, false)
RegisterKeyMapping('convoy_zonerecord_drop_secondary', 'Zone Recorder: Drop Zone (Secondary)', 'keyboard', 'K')

RegisterCommand('convoy_zonerecord_undo', function()
    undoLastPoint()
end, false)
RegisterKeyMapping('convoy_zonerecord_undo', 'Zone Recorder: Undo Last Zone', 'keyboard', 'BACK')

RegisterCommand('convoy_zonerecord_finish', function()
    finishRecording()
end, false)
RegisterKeyMapping('convoy_zonerecord_finish', 'Zone Recorder: Finish and Return to Tablet', 'keyboard', 'RETURN')

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if recording then lib.hideTextUI() end
    clearRecordBlips()
end)
