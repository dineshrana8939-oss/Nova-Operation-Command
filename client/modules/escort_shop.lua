-- ─── Nova Convoy — Escort Vehicle Shop (client) ───────────────────────────────
-- Client-side vendor ped and checkout menu for police escort vehicles.

local TGT = exports.ox_target
local ped = nil
local blip = nil
local lastLocation = nil
local hasVehicleCheckedOut = false
--   326 = radar_garage  (garage/vehicle vendor - escort vehicle shop)
local VENDOR_BLIP = { sprite = 326, colour = 3, scale = 0.8, label = 'Escort Vehicle Shop' }

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

-- The showroom (client/modules/showroom.lua): the vehicle list on the left, the shop ped in front of the camera on the right.
-- Cash / bank is picked in the panel for a vehicle that costs money; a free loaner needs no account. The vehicle itself is
-- created by the server, at a clear spot close to the shop that this side picks, with the player moved there and seated.
local function openMenu()
    if not lastLocation then return end
    local serverCheckedOut = lib.callback.await('nova_convoytruck:hasEscortVehicle', false)
    if serverCheckedOut ~= nil then
        hasVehicleCheckedOut = serverCheckedOut
    end

    local vehicles = {}
    if not hasVehicleCheckedOut then
        local res = lib.callback.await('nova_convoytruck:getEscortShopVehicles', false)
        vehicles = (res and res.ok and res.vehicles) or (Config.EscortVehicleShop and Config.EscortVehicleShop.vehicles) or {}
    end

    Showroom.open({
        shop = 'escort',
        title = 'Escort Vehicle Shop',
        subtitle = 'Check out a vehicle for the active convoy',
        pedName = 'Duty Sergeant',
        loc = { x = lastLocation.x, y = lastLocation.y, z = lastLocation.z, heading = lastLocation.heading },
        wallet = { kind = 'convoy', label = 'Escort vehicles', note = 'Loaners are free. Anything you pay for is refunded when you return it.' },
        vehicles = vehicles,
        checkedOut = hasVehicleCheckedOut,
        onBuy = function(index, account)
            local v = vehicles[index]
            if not v then return { ok = false, error = 'That vehicle is not available.' } end
            local spot = Showroom.safeSpot(lastLocation)
            -- the server moves the player to the spot, so they must not be held still for that moment
            Showroom.releasePlayer()
            local buyRes = lib.callback.await('nova_convoytruck:requestEscortVehicle', false, v, account == 'bank' and 'bank' or 'cash', spot)
            if buyRes and buyRes.ok then
                hasVehicleCheckedOut = true
                CreateThread(function() Wait(700); Showroom.claim(spot, nil) end)
                return { ok = true, message = ('%s checked out — return it to this ped when done.'):format(v.label or v.model) }
            end
            Showroom.holdPlayer()
            return { ok = false, error = (buyRes and buyRes.error) or 'Failed to requisition vehicle.' }
        end,
        onReturn = function()
            local res = lib.callback.await('nova_convoytruck:returnEscortVehicle', false)
            if res and res.ok then
                hasVehicleCheckedOut = false
                local msg = 'Escort vehicle returned.'
                if res.refunded and res.refunded > 0 then msg = ('Escort vehicle returned. $%d refunded.'):format(res.refunded) end
                CreateThread(function() Wait(1100); Showroom.close() end)
                return { ok = true, message = msg }
            end
            return { ok = false, error = (res and res.error) or 'Failed to return vehicle.' }
        end,
    })
end

local function spawnVendor(coords)
    despawnVendor()
    lastLocation = coords
    lib.requestModel(Config.EscortVehicleShop.pedModel)
    ped = CreatePed(4, Config.EscortVehicleShop.pedModel, coords.x, coords.y, coords.z - 1.0, coords.heading or 0.0, false, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(Config.EscortVehicleShop.pedModel)

    drawVendorBlip()

    TGT:addLocalEntity(ped, { {
        label = 'Escort Vehicles',
        icon = 'fa-solid fa-car-side',
        onSelect = openMenu,
    } })
end

CreateThread(function()
    Wait(1000)
    local location = lib.callback.await('nova_convoytruck:getEscortShopLocation', false)
    local enabled = Config.EscortVehicleShop.enabled
    if location then
        enabled = location.enabled
    else
        local c = Config.EscortVehicleShop.pedCoords
        location = { x = c.x, y = c.y, z = c.z, heading = c.w }
    end
    if enabled then spawnVendor(location) end
end)

RegisterNetEvent('nova_convoytruck:escortShop:moveVendor', function(location)
    lastLocation = location
    if ped then spawnVendor(location) end
end)

-- Roles resolve a beat after spawn (server round-trip) — redraw so a police/
-- admin who was still "civilian" at spawn time gets the blip the moment their
-- real role lands.
RegisterNetEvent('nova_convoytruck:client:rolesResolved', function()
    if ped then drawVendorBlip() end
end)

-- lastLocation only ever gets set by a moveVendor broadcast or this client's
-- own startup fetch — a client that joined while disabled and was never
-- online for a location change since has no lastLocation cached at all, so
-- silently doing nothing here (the previous behavior) meant enabling it back
-- on could spawn nothing for them until they reconnected. Falling back to a
-- fresh server fetch closes that gap instead of just hoping lastLocation is set.
RegisterNetEvent('nova_convoytruck:escortShop:setEnabled', function(enabled)
    if not enabled then
        despawnVendor()
        return
    end
    if lastLocation then
        spawnVendor(lastLocation)
        return
    end
    local location = lib.callback.await('nova_convoytruck:getEscortShopLocation', false)
    if location then spawnVendor(location) end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    despawnVendor()
end)
