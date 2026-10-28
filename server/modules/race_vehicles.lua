-- ─── Nova Convoy — Race Vehicle Ped (server) ──────────────────────────────────
-- Gang Rally events set to "Provided vehicles": registered racers take ONE of the
-- race's allowed vehicles from a vehicle ped before the start. The server decides
-- who may (registered for THAT race, or an admin), which vehicles exist (the
-- race's own list — the client only ever sends a list INDEX) and that nobody can
-- hold more than one at a time.

RaceVehicles = {}

local taken = {} -- [convoyId] = { [identifier] = true }

-- Called when a race ends or is reused, so the next run starts with a clean slate.
function RaceVehicles.reset(convoyId)
    taken[convoyId] = nil
end

local function findPed(source, convoyId)
    for _, entry in ipairs(ConvoyManager.getRaceVehiclePeds(source)) do
        if entry.convoyId == convoyId then return entry end
    end
    return nil
end

lib.callback.register('nova_convoytruck:raceVehicle:getPeds', function(source)
    return ConvoyManager.getRaceVehiclePeds(source)
end)

lib.callback.register('nova_convoytruck:raceVehicle:request', function(source, convoyId, index)
    convoyId = tonumber(convoyId)
    local entry = convoyId and findPed(source, convoyId)
    if not entry then return { ok = false, error = 'You are not registered for a race that provides vehicles.' } end

    local vehicle = entry.vehicles[tonumber(index) or 0]
    if not vehicle or not vehicle.model then return { ok = false, error = 'That vehicle is not available.' } end

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return { ok = false, error = 'Could not identify you.' } end
    taken[convoyId] = taken[convoyId] or {}
    if taken[convoyId][identifier] then
        return { ok = false, error = 'You already have a race vehicle — return it first to take another.' }
    end

    taken[convoyId][identifier] = true
    print(('[NovaConvoy] Race vehicle: %s (%s) took %s for race #%d'):format(
        Bridge.GetPlayerName(source) or 'Unknown', identifier, vehicle.model, convoyId))
    return { ok = true, model = vehicle.model, label = vehicle.label or vehicle.model }
end)

lib.callback.register('nova_convoytruck:raceVehicle:return', function(source, convoyId)
    convoyId = tonumber(convoyId)
    local identifier = Bridge.GetIdentifier(source)
    if convoyId and identifier and taken[convoyId] then taken[convoyId][identifier] = nil end
    return { ok = true }
end)
