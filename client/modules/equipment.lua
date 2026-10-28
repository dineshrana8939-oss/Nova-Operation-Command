-- ─── Nova Convoy — Police Equipment Vendor (client) ───────────────────────────
-- Presentational vendor ped and tactical equipment purchase menu.

RegisterNetEvent('nova_convoytruck:client:notify', function(message, type)
    lib.notify({ title = 'Convoy System', description = message, type = type or 'info' })
end)

local TGT = exports.ox_target
local ped = nil
local blip = nil
local lastLocation = nil
--   110 = radar_weapon_ammo  (ammo/weapon vendor - tactical equipment shop)
local VENDOR_BLIP = { sprite = 110, colour = 3, scale = 0.8, label = 'Tactical Equipment Shop' }

local function removeVendorBlip()
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    blip = nil
end
local function despawnVendor()
    if ped and DoesEntityExist(ped) then
        TGT:removeLocalEntity(ped)
        DeleteEntity(ped)
    end
    ped = nil
    removeVendorBlip()
end
-- Staff-only map blip: only police and admins ever see the shop marked on the
-- map, even though the ped itself stays usable by anyone standing next to it.
local function drawVendorBlip()
    removeVendorBlip()
    if not (lastLocation and NovaConvoy.Roles.canSeeStaffBlips()) then return end
    blip = AddBlipForCoord(lastLocation.x, lastLocation.y, lastLocation.z)
    SetBlipSprite(blip, VENDOR_BLIP.sprite)
    SetBlipColour(blip, VENDOR_BLIP.colour)
    SetBlipScale(blip, VENDOR_BLIP.scale)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(VENDOR_BLIP.label)
    EndTextCommandSetBlipName(blip)
end
local function spawnVendor(coords)
    despawnVendor()
    lastLocation = coords
    lib.requestModel(Config.PoliceEquipment.pedModel)
    ped = CreatePed(4, Config.PoliceEquipment.pedModel, coords.x, coords.y, coords.z - 1.0, coords.heading or 0.0, false, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(Config.PoliceEquipment.pedModel)

    drawVendorBlip()

    TGT:addLocalEntity(ped, { {
        label = 'Buy Tactical Equipment',
        icon = 'fa-solid fa-bag-shopping',
        onSelect = function()
            -- the themed shop window (ped_menu.lua); the server still validates and charges every purchase (cash or bank)
            local items = {}
            for i, item in ipairs(Config.PoliceEquipment.items) do
                items[#items + 1] = { id = i, label = item.label, price = item.price }
            end
            PedMenu.open({
                title = 'Tactical Equipment', subtitle = 'Pay with cash or bank',
                items = items,
                onPick = function(id, account) TriggerServerEvent('nova_convoytruck:equipment:server:purchase', id, account) end,
            })
        end,
    } })
end

CreateThread(function()
    Wait(1000)
    local location = lib.callback.await('nova_convoytruck:getEquipmentVendorLocation', false)
    local enabled = Config.PoliceEquipment.enabled
    if location then
        enabled = location.enabled
    else
        local c = Config.PoliceEquipment.pedCoords
        location = { x = c.x, y = c.y, z = c.z, heading = c.w }
    end
    if enabled then spawnVendor(location) end
end)

-- Fired to every client the moment an admin sets a new location from the
-- tablet — the ped moves immediately, no restart needed. No-ops while
-- disabled (still records the location for when it's turned back on).
RegisterNetEvent('nova_convoytruck:equipment:moveVendor', function(location)
    lastLocation = location
    if ped then spawnVendor(location) end
end)

-- Roles resolve a beat after spawn (server round-trip) — redraw so a police/
-- admin who was still "civilian" at spawn time gets the blip the moment their
-- real role lands.
RegisterNetEvent('nova_convoytruck:client:rolesResolved', function()
    if ped then drawVendorBlip() end
end)

-- Fired the moment an admin flips the Settings tab toggle — spawns/despawns
-- for every connected client immediately, no restart needed.
-- lastLocation only ever gets set by a moveVendor broadcast or this client's
-- own startup fetch — a client that joined while disabled and was never
-- online for a location change since has no lastLocation cached at all, so
-- silently doing nothing here (the previous behavior) meant enabling it back
-- on could spawn nothing for them until they reconnected. Falling back to a
-- fresh server fetch closes that gap instead of just hoping lastLocation is set.
RegisterNetEvent('nova_convoytruck:equipment:setEnabled', function(enabled)
    if not enabled then
        despawnVendor()
        return
    end
    if lastLocation then
        spawnVendor(lastLocation)
        return
    end
    local location = lib.callback.await('nova_convoytruck:getEquipmentVendorLocation', false)
    if location then spawnVendor(location) end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    despawnVendor()
end)
