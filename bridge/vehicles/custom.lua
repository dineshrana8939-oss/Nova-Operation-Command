-- ─── Custom Vehicle Provider Template (keys + garage) ──────────────────────────────
-- Only loaded when Config.VehicleRewards.keys = 'custom' and/or Config.VehicleRewards.garageProvider = 'custom'.
-- Point these two functions at any key script / garage script; delete the one you do not use.
--
-- A vehicle reward is paid in one of two modes (set per reward in the Container Wars setup):
--   GARAGE -> the winner OWNS the car: AddToGarage below stores it in your garage script / table
--   SPAWN  -> the car appears in the world beside the container: GiveKeys below hands over the keys
-- A GARAGE car that cannot be stored (AddToGarage returns false) is spawned instead, so it is never lost.
--
-- source = the player's server id; Bridge.GetIdentifier(source) = their character identifier (citizenid / identifier).

local M = {}

-- Gives `source` the keys of a spawned vehicle. entity = the vehicle, plate = its plate (trimmed), model = its hash.
-- Return true on success.
function M.GiveKeys(source, entity, plate, model)
    -- Examples (use the one for your key script):
    -- exports['qs-vehiclekeys']:GiveKeys(source, plate, model)
    -- exports.wasabi_carlock:GiveKey(source, plate)
    -- exports['Renewed-Vehiclekeys']:addKey(source, plate)
    return false
end

-- Stores a car for the player in your garage script. plate = an unused plate made by this resource, garage = the garage
-- name from Config.VehicleRewards.garage. Return true on success (optionally with the plate it ended up with).
-- out = true when the car is standing in the WORLD right now (an admin gave a spawned reward car to its winner with
-- /carowner): record it as "out" / not stored, so the player cannot also pull a second copy of it from the garage.
function M.AddToGarage(source, model, plate, garage, out)
    -- Example for a script that has a "give vehicle" export or a table of its own:
    -- local ok = exports['your-garage']:AddVehicle(Bridge.GetIdentifier(source), model, plate, garage)
    -- return ok and true or false, plate
    return false, 'bridge/vehicles/custom.lua AddToGarage is not filled in'
end

return M
