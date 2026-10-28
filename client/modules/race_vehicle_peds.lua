-- ─── Nova Convoy — Race Vehicle Ped (client) ───────────────────────────────────
-- For Gang Rally events set to "Provided vehicles": a vehicle ped where racers
-- REGISTERED for that race pick one of its allowed vehicles before the start.
-- The server owns the rules (who may, which list, one vehicle each); this side
-- polls which peds should exist, shows the menu and spawns what it is told to.

local TGT = exports.ox_target
local peds = {}        -- [convoyId] = { ped = handle, key = 'x,y,z,h' }
local myVehicles = {}  -- [convoyId] = vehicle handle this player took

local function removeEntry(convoyId)
    local entry = peds[convoyId]
    if not entry then return end
    if entry.ped and DoesEntityExist(entry.ped) then
        pcall(function() TGT:removeLocalEntity(entry.ped) end)
        DeleteEntity(entry.ped)
    end
    if entry.blip and DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
    peds[convoyId] = nil
end

local function spawnVehicleFor(entry, model)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) then
        lib.notify({ title = '🏁 GANG RALLY', description = 'That vehicle model is not installed on this server.', type = 'error', icon = 'flag-checkered', iconColor = '#ff6a00' })
        return nil
    end
    lib.requestModel(hash)
    local dist = (Config.RaceVehicleShop and Config.RaceVehicleShop.spawnDistance) or 6.0
    local rad = math.rad(entry.heading or 0.0)
    local sx = entry.x - math.sin(rad) * dist
    local sy = entry.y + math.cos(rad) * dist
    local veh = CreateVehicle(hash, sx, sy, entry.z, entry.heading or 0.0, true, false)
    SetModelAsNoLongerNeeded(hash)
    if not veh or veh == 0 then return nil end
    SetVehicleOnGroundProperly(veh)
    SetVehicleDoorsLocked(veh, 1)
    SetVehicleEngineOn(veh, true, true, false)
    SetPedIntoVehicle(cache.ped or PlayerPedId(), veh, -1)
    -- Best-effort key hand-off for common key resources (harmless if absent).
    pcall(function() TriggerEvent('vehiclekeys:client:SetOwner', GetVehicleNumberPlateText(veh)) end)
    return veh
end

local function openMenu(entry)
    local options = {}
    local mine = myVehicles[entry.convoyId]
    if mine and DoesEntityExist(mine) then
        options[#options + 1] = {
            title = 'Return My Race Vehicle',
            description = 'Hand your vehicle back to take a different one',
            icon = 'fa-solid fa-arrow-rotate-left',
            onSelect = function()
                lib.callback.await('nova_convoytruck:raceVehicle:return', false, entry.convoyId)
                if DoesEntityExist(mine) then
                    SetEntityAsMissionEntity(mine, true, true)
                    DeleteEntity(mine)
                end
                myVehicles[entry.convoyId] = nil
                lib.notify({ title = '🏁 GANG RALLY', description = 'Vehicle returned.', type = 'success', icon = 'flag-checkered', iconColor = '#ff6a00' })
            end,
        }
    else
        myVehicles[entry.convoyId] = nil
        for i, v in ipairs(entry.vehicles or {}) do
            options[#options + 1] = {
                title = v.label or v.model,
                description = 'Take this vehicle for the race',
                icon = 'fa-solid fa-car-side',
                onSelect = function()
                    local res = lib.callback.await('nova_convoytruck:raceVehicle:request', false, entry.convoyId, i)
                    if res and res.ok then
                        local veh = spawnVehicleFor(entry, res.model)
                        if veh then
                            myVehicles[entry.convoyId] = veh
                            lib.notify({ title = '🏁 GANG RALLY', description = ('%s is ready — good luck!'):format(res.label), type = 'success', icon = 'flag-checkered', iconColor = '#ff6a00' })
                        else
                            lib.callback.await('nova_convoytruck:raceVehicle:return', false, entry.convoyId)
                        end
                    else
                        lib.notify({ title = '🏁 GANG RALLY', description = (res and res.error) or 'Request failed.', type = 'error', icon = 'flag-checkered', iconColor = '#ff6a00' })
                    end
                end,
            }
        end
    end
    lib.registerContext({ id = 'nova_race_vehicles', title = ('%s — Race Vehicles'):format(entry.name or 'Race'), options = options })
    lib.showContext('nova_race_vehicles')
end

local function spawnEntry(entry)
    local model = (Config.RaceVehicleShop and Config.RaceVehicleShop.pedModel) or 's_m_m_autoshop_02'
    lib.requestModel(model)
    local ped = CreatePed(4, model, entry.x, entry.y, entry.z - 1.0, entry.heading or 0.0, false, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(model)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)
    TGT:addLocalEntity(ped, { {
        label = 'Race Vehicles',
        icon = 'fa-solid fa-car-side',
        distance = 2.5,
        onSelect = function() openMenu(entry) end,
    } })
    -- map sprite (Config.RaceVehicleShop.blip): it lives and dies with the ped
    local bCfg = (Config.RaceVehicleShop and Config.RaceVehicleShop.blip) or {}
    local blip = nil
    if bCfg.enabled ~= false then
        blip = AddBlipForCoord(entry.x, entry.y, entry.z)
        SetBlipSprite(blip, bCfg.sprite or 225)
        SetBlipColour(blip, bCfg.colour or 3)
        SetBlipScale(blip, bCfg.scale or 0.85)
        SetBlipAsShortRange(blip, bCfg.shortRange ~= false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(bCfg.label or 'Race Vehicles')
        EndTextCommandSetBlipName(blip)
    end
    peds[entry.convoyId] = { ped = ped, blip = blip, key = ('%.2f,%.2f,%.2f,%.1f,%d'):format(entry.x, entry.y, entry.z, entry.heading or 0.0, #(entry.vehicles or {})) }
end

local function sync()
    local list = lib.callback.await('nova_convoytruck:raceVehicle:getPeds', false) or {}
    local wanted = {}
    for _, entry in ipairs(list) do
        wanted[entry.convoyId] = true
        local key = ('%.2f,%.2f,%.2f,%.1f,%d'):format(entry.x, entry.y, entry.z, entry.heading or 0.0, #(entry.vehicles or {}))
        local existing = peds[entry.convoyId]
        if not existing or existing.key ~= key or not DoesEntityExist(existing.ped) then
            removeEntry(entry.convoyId)
            spawnEntry(entry)
        end
    end
    for convoyId in pairs(peds) do
        if not wanted[convoyId] then removeEntry(convoyId) end
    end
end

RegisterNetEvent('nova_convoytruck:raceVehicle:sync', function()
    pcall(sync)
end)

CreateThread(function()
    Wait(500)
    pcall(sync)
    while true do
        Wait(4000)
        pcall(sync)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for convoyId in pairs(peds) do removeEntry(convoyId) end
end)
