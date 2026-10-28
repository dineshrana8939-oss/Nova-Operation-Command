-- ─── Nova Convoy — Race Token Vendor (server) ─────────────────────────────────
-- Gang members collect Config.RallyRace.tokenItem by finishing gang rallies in a good
-- position, then trade them at a vendor ped for a special vehicle. Everything
-- that matters is decided here: who may redeem, how many tokens it costs, and
-- which vehicle they get (the client only ever sends a list INDEX, never a
-- model name or a price).

local lastRedeem = {} -- [source] = os.time() of the last redemption (anti double-click)

local function vendorCfg()
    return Config.TokenVendor or {}
end

local function tokenItem()
    return (Config.RallyRace and Config.RallyRace.tokenItem) or 'race_token'
end

-- The vendor is a permanent "world ped" (server/modules/world_peds.lua): its position and on/off switch are saved there,
-- independent of any race event. The admin-placed spot wins over the Config.TokenVendor default.
local function vendorLocation()
    local p = WorldPeds.get('token_vendor')
    if p and p.x then return { x = p.x, y = p.y, z = p.z, heading = p.heading } end
    return nil
end

local function vendorEnabled()
    local p = WorldPeds.get('token_vendor')
    return p and p.enabled == true or false
end

lib.callback.register('nova_convoytruck:tokenVendor:getLocation', function()
    return { ok = true, enabled = vendorEnabled(), location = vendorLocation() }
end)

-- Tablet (Race Setup tab): an admin stands where the vendor should be and
-- presses "Set to My Position".
lib.callback.register('nova_convoytruck:setTokenVendorLocation', function(source, placed)
    if not UserPermissions.can(source, 'worldpeds.edit') then return { ok = false, error = 'Not authorized.' } end
    local x, y, z, heading = PedSpot(source, placed)   -- the hologram's position, else where the admin stands (callbacks.lua)
    if not x then return { ok = false, error = 'Could not locate you in the world.' } end
    local location = { x = x, y = y, z = z, heading = heading }
    WorldPeds.setLocation('token_vendor', location)     -- saves it and moves the ped for everyone online
    return { ok = true, location = location }
end)

lib.callback.register('nova_convoytruck:setTokenVendorEnabled', function(source, enabled)
    if not UserPermissions.can(source, 'worldpeds.edit') then return { ok = false, error = 'Not authorized.' } end
    enabled = enabled == true
    WorldPeds.setEnabled('token_vendor', enabled)
    return { ok = true, enabled = enabled }
end)

-- What the menu shows: the caller's token count and the vehicle list.
lib.callback.register('nova_convoytruck:tokenVendor:getInfo', function(source)
    if not vendorEnabled() then return { ok = false, error = 'The token vendor is closed.' } end
    local gang = GangService and GangService.GetPlayerGang(source)
    return {
        ok = true,
        gangOnly = vendorCfg().gangOnly ~= false,
        isGangMember = gang ~= nil and gang.name ~= nil,
        tokens = Inventory.GetItemCount(source, tokenItem()),
        vehicles = vendorCfg().vehicles or {},
    }
end)

-- The clear spot the car is created at. A bay set in Config.TokenVendor.spawnCoords always wins; otherwise the client's
-- pick (showroom.lua: a road lane / open ground close to the vendor) is used, but only if it really is close to the vendor.
local function claimSpot(cfg, vendor, spot)
    if cfg.spawnCoords then
        local c = cfg.spawnCoords
        return { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, heading = (c.w or 0.0) + 0.0 }
    end
    if type(spot) == 'table' and tonumber(spot.x) and tonumber(spot.y) and tonumber(spot.z) and vendor then
        local sx, sy, sz = tonumber(spot.x) + 0.0, tonumber(spot.y) + 0.0, tonumber(spot.z) + 0.0
        local dx, dy = sx - vendor.x, sy - vendor.y
        if math.sqrt(dx * dx + dy * dy) <= 60.0 and math.abs(sz - vendor.z) <= 30.0 then
            return { x = sx, y = sy, z = sz, heading = (tonumber(spot.heading) or 0.0) + 0.0 }
        end
    end
    return nil
end

-- Creates the vehicle in the world, records it as the buyer's own car (player_vehicles / qbx_vehicles, same as a garage
-- purchase), hands over the keys and seats them in it. Returns the plate, or nil + a reason (nothing is left behind then).
local function grantVehicle(source, model, spot)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil, 'Could not locate you in the world.' end
    local hash = joaat(model)
    local plate = Bridge.NewPlate()

    -- the player goes to the clear spot together with the car
    SetEntityCoords(ped, spot.x, spot.y, spot.z + 1.0, false, false, false, false)
    local veh = CreateVehicle(hash, spot.x, spot.y, spot.z, spot.heading, true, true)
    local deadline = GetGameTimer() + 3000
    while (not veh or veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < deadline do Wait(50) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return nil, 'That vehicle model could not be created on this server.'
    end
    SetVehicleNumberPlateText(veh, plate)

    -- the DB record: "out" (the car stands in the world), so it can also be parked in any garage and taken out again
    local ok, plateOrErr, vehicleId = Bridge.AddOwnedVehicle(source, model, { plate = plate, out = true })
    if not ok then
        DeleteEntity(veh)
        return nil, ('Could not register the vehicle to you: %s'):format(tostring(plateOrErr))
    end
    if vehicleId then Entity(veh).state:set('vehicleid', vehicleId, true) end

    TriggerClientEvent('nova_convoytruck:runtime:snapTruckToGround', -1, NetworkGetNetworkIdFromEntity(veh))
    Bridge.GiveVehicleKeys(source, veh)
    SetPedIntoVehicle(ped, veh, -1)
    return tostring(plateOrErr or plate)
end

lib.callback.register('nova_convoytruck:tokenVendor:redeem', function(source, index, spot)
    local cfg = vendorCfg()
    if not vendorEnabled() then return { ok = false, error = 'The token vendor is closed.' } end

    local vehicle = cfg.vehicles and cfg.vehicles[tonumber(index) or 0]
    if not vehicle or not vehicle.model then return { ok = false, error = 'That vehicle is not available.' } end

    local gang = GangService and GangService.GetPlayerGang(source)
    if cfg.gangOnly ~= false and not (gang and gang.name) then
        return { ok = false, error = 'Only gang members can trade race tokens.' }
    end

    if lastRedeem[source] and os.time() - lastRedeem[source] < 5 then
        return { ok = false, error = 'Slow down — the mechanic is still handling your last request.' }
    end

    -- the buyer must actually be at the vendor
    local vendor = vendorLocation()
    local pped = GetPlayerPed(source)
    if vendor and pped and pped ~= 0 then
        local pc = GetEntityCoords(pped)
        if #(vector3(pc.x, pc.y, pc.z) - vector3(vendor.x, vendor.y, vendor.z)) > 25.0 then
            return { ok = false, error = 'You are too far from the vendor.' }
        end
    end
    local where = claimSpot(cfg, vendor, spot)
    if not where then return { ok = false, error = 'No clear spot was found near the vendor — try again.' } end

    local cost = math.max(1, math.floor(tonumber(vehicle.tokens) or 1))
    local item = tokenItem()
    if Inventory.GetItemCount(source, item) < cost then
        return { ok = false, error = ('You need %d race token%s for this vehicle.'):format(cost, cost == 1 and '' or 's') }
    end
    if not Inventory.RemoveItem(source, item, cost) then
        return { ok = false, error = 'Could not take the tokens from your inventory.' }
    end

    lastRedeem[source] = os.time()
    local plate, why = grantVehicle(source, vehicle.model, where)
    if not plate then
        -- nothing was delivered: give the tokens back
        Inventory.AddItem(source, item, cost)
        lastRedeem[source] = nil
        print(('[NovaConvoy] Token vendor: %s could not receive %s (%s) — %d token(s) refunded.'):format(Bridge.GetPlayerName(source) or 'Unknown', vehicle.model, tostring(why), cost))
        return { ok = false, error = why or 'The vehicle could not be delivered — your tokens were returned.' }
    end

    print(('[NovaConvoy] Token vendor: %s (%s) [%s] redeemed %d token(s) for %s (%s), plate %s — recorded as their own vehicle'):format(
        Bridge.GetPlayerName(source) or 'Unknown', Bridge.GetIdentifier(source) or 'N/A',
        gang and (gang.label or gang.name) or 'no gang', cost, vehicle.label or vehicle.model, vehicle.model, plate))

    return { ok = true, model = vehicle.model, label = vehicle.label or vehicle.model, cost = cost, plate = plate }
end)

AddEventHandler('playerDropped', function() lastRedeem[source] = nil end)

-- /settokenvendor — an admin stands where the vendor should be and runs it.
RegisterCommand('settokenvendor', function(source)
    if source == 0 then print('[NovaConvoy] Run /settokenvendor in-game, standing where the vendor should be.') return end
    if not UserPermissions.can(source, 'worldpeds.edit') then
        TriggerClientEvent('nova_convoytruck:client:notify', source, 'You are not allowed to move the token vendor.', 'error')
        return
    end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)
    WorldPeds.setLocation('token_vendor', { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) })
    TriggerClientEvent('nova_convoytruck:client:notify', source, 'Token vendor moved to your position.', 'success')
end, false)
