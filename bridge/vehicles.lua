-- ─── Nova Convoy — Vehicle Bridge ─────────────────────────────────────────────
-- Server-side. Everything a vehicle REWARD needs from the framework, in one place:
--   Bridge.GiveVehicleKeys(source, entity)           keys for a spawned car
--   Bridge.AddOwnedVehicle(source, model, opts)      puts a car in the player's garage (they own it)
--   Bridge.NewPlate()                                an unused plate
-- Written against the installed qbx_vehicles / qbx_vehiclekeys APIs; the QB-Core and ESX paths follow those
-- frameworks' standard tables and are untested on this server (the same caveat as the other adapters).

local function cfg() return Config.VehicleRewards or {} end

-- bridge/vehicles/custom.lua: the place to wire in any other keys / garage script (see that file). Loaded only when
-- Config.VehicleRewards.keys / .garageProvider is 'custom'.
local customModule, customTried = nil, false
local function custom()
    if customTried then return customModule end
    customTried = true
    local ok, mod = pcall(require, 'bridge.vehicles.custom')
    if ok and type(mod) == 'table' then
        customModule = mod
    else
        lib.print.warn(('[nova_convoytruck][Vehicles] could not load bridge/vehicles/custom.lua: %s'):format(tostring(mod)))
    end
    return customModule
end

-- ── plates ─────────────────────────────────────────────────────────────────────
local function randomPlate()
    local prefix = tostring(cfg().platePrefix or 'CW'):upper():gsub('[^%w]', ''):sub(1, 4)
    local digits = 8 - #prefix
    local out = prefix
    for _ = 1, digits do out = out .. tostring(math.random(0, 9)) end
    return out
end

local function plateExists(plate)
    if GetResourceState('qbx_vehicles') == 'started' then
        local ok, exists = pcall(function() return exports.qbx_vehicles:DoesPlayerVehiclePlateExist(plate) end)
        if ok then return exists == true end
    end
    local framework = Bridge.Framework
    local ok, row = pcall(function()
        if framework == 'esx' then return MySQL.scalar.await('SELECT 1 FROM owned_vehicles WHERE plate = ? LIMIT 1', { plate }) end
        return MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    end)
    return ok and row ~= nil
end

-- true when a vehicle with this plate is already in the ownership tables (used to never register a car twice)
function Bridge.PlateOwned(plate)
    return plate ~= nil and plate ~= '' and plateExists(plate) or false
end

function Bridge.NewPlate()
    for _ = 1, 25 do
        local plate = randomPlate()
        if not plateExists(plate) then return plate end
    end
    return randomPlate()
end

-- ── keys ───────────────────────────────────────────────────────────────────────
-- entity: the spawned vehicle. Returns true when a keys script took it.
function Bridge.GiveVehicleKeys(source, entity)
    local mode = tostring(cfg().keys or 'auto')
    if mode == 'none' or not entity or not DoesEntityExist(entity) then return false end

    if mode == 'custom' then
        local mod = custom()
        if mod and mod.GiveKeys then
            local plate = GetVehicleNumberPlateText(entity)
            local ok, res = pcall(mod.GiveKeys, source, entity, plate and (plate:gsub('^%s+', ''):gsub('%s+$', '')) or nil, GetEntityModel(entity))
            if not ok then lib.print.warn(('[nova_convoytruck][Vehicles] custom GiveKeys failed: %s'):format(tostring(res))) end
            return ok and res ~= false
        end
        return false
    end

    if (mode == 'auto' or mode == 'qbx_vehiclekeys') and GetResourceState('qbx_vehiclekeys') == 'started' then
        local ok = pcall(function() exports.qbx_vehiclekeys:GiveKeys(source, entity, true) end)
        if ok then return true end
    end
    if mode == 'auto' or mode == 'qb-vehiclekeys' then
        -- QB-Core's key script is driven by the plate (client event); harmless where it does not exist
        local plate = GetVehicleNumberPlateText(entity)
        if plate and plate ~= '' then
            TriggerClientEvent('vehiclekeys:client:SetOwner', source, (plate:gsub('^%s+', ''):gsub('%s+$', '')))
            return true
        end
    end
    return false
end

-- Takes the keys of a spawned car back from a player (used when ownership moves to somebody else). Quiet, and a no-op
-- when no key script that can do it is running.
function Bridge.RemoveVehicleKeys(source, entity)
    if not source or not entity or not DoesEntityExist(entity) then return false end
    if GetResourceState('qbx_vehiclekeys') == 'started' then
        local ok, res = pcall(function() return exports.qbx_vehiclekeys:RemoveKeys(source, entity, true) end)
        return ok and res == true
    end
    local plate = GetVehicleNumberPlateText(entity)
    if plate and plate ~= '' then
        TriggerClientEvent('qb-vehiclekeys:client:RemoveKeys', source, (plate:gsub('^%s+', ''):gsub('%s+$', '')))
        return true
    end
    return false
end

-- ── garage ownership ───────────────────────────────────────────────────────────
-- opts: { plate, garage, out }. `out = true` records a car that is standing in the WORLD right now (not stored in a
-- garage): its record says "out", so the owner cannot also pull a second copy of it from the garage.
-- Returns ok, plateOrError, vehicleId (the framework's id for the new record, when it has one — qbx_vehicles).
function Bridge.AddOwnedVehicle(source, model, opts)
    opts = opts or {}
    local plate = opts.plate or Bridge.NewPlate()
    local garage = opts.garage or cfg().garage or 'motelgarage'
    local out = opts.out == true
    -- opts.citizenid: record the car for a player who is not at hand (offline, or not the one who took it); then no source is needed
    local citizenid = opts.citizenid or (source and Bridge.GetIdentifier(source))
    if not citizenid then return false, 'Could not identify the player.' end
    local hash = joaat(model)
    local framework = Bridge.Framework

    local provider = tostring(cfg().garageProvider or 'auto')
    if provider == 'none' then return false, 'Garage rewards are switched off (Config.VehicleRewards.garageProvider).' end
    if provider == 'custom' then
        local mod = custom()
        if not (mod and mod.AddToGarage) then return false, 'bridge/vehicles/custom.lua has no AddToGarage.' end
        local ok, res, info = pcall(mod.AddToGarage, source, model, plate, garage, out)   -- `out`: the car is in the world, not stored
        if not ok then return false, tostring(res) end
        if res then return true, (type(info) == 'string' and info ~= '') and info or plate end
        return false, tostring(info or 'the custom garage refused the vehicle')
    end

    if framework == 'qbx' and GetResourceState('qbx_vehicles') == 'started' then
        local ok, id, err = pcall(function()
            -- no garage = state OUT (qbx_vehicles stores a car that has a garage as "in the garage")
            return exports.qbx_vehicles:CreatePlayerVehicle({
                model = model, citizenid = citizenid, garage = (not out) and garage or nil, props = { plate = plate },
            })
        end)
        -- pcall returns (true, vehicleId, errorResult)
        if ok and id then return true, plate, id end
        return false, (type(err) == 'table' and err.message) or tostring(id or 'qbx_vehicles refused the vehicle')
    end

    if framework == 'qbx' or framework == 'qbcore' then
        local license = nil
        local player = source and Bridge.GetPlayer(source)
        local pd = player and (player.PlayerData or player.playerData)
        license = pd and pd.license or nil
        if not license then
            local okq, lic = pcall(MySQL.scalar.await, 'SELECT license FROM players WHERE citizenid = ?', { citizenid })
            license = okq and lic or nil
        end
        local ok, err = pcall(function()
            MySQL.insert.await(
                'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                { license, citizenid, model, tostring(hash), '{}', plate, garage, out and 0 or 1 })
        end)
        if ok then return true, plate end
        return false, tostring(err)
    end

    if framework == 'esx' then
        local ok, err = pcall(function()
            MySQL.insert.await(
                'INSERT INTO owned_vehicles (owner, plate, vehicle, type, stored) VALUES (?, ?, ?, ?, ?)',
                { citizenid, plate, json.encode({ model = hash, plate = plate }), 'car', out and 0 or 1 })
        end)
        if ok then return true, plate end
        return false, tostring(err)
    end

    return false, 'No supported framework for garage ownership.'
end
