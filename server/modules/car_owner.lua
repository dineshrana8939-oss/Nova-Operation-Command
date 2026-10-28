-- ─── /carowner (server) ──────────────────────────────────────────────────────────────────────────
-- Container Wars reward cars set to "Spawn at container" are not owned by anyone: the car stands beside the container
-- and whoever opened it gets the keys. This lets an admin give such a car to the player who really won it:
--   /carowner  →  an ox_lib menu of the cars of the container events  →  pick one  →  type the player's server ID
-- The player is told the car belongs to them, and can lock / unlock it with their keys and store it in a garage.
-- Cars set to "Add to garage" are already owned by their winner and never appear here.
-- The work itself is RewardService.TransferSpawnedCar (reward_service.lua).

local function isAdmin(source)
    return Bridge.IsAdmin(source, Config.CreatorAccess and Config.CreatorAccess.adminPermission)
end

RegisterCommand('carowner', function(source)
    if source == 0 then
        print('[NovaConvoy] /carowner is used in game (it opens a menu).')
        return
    end
    if not isAdmin(source) then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', source, { type = 'error', title = 'Car ownership', description = 'Only administrators can use this.' })
        return
    end
    TriggerClientEvent('nova_convoytruck:carowner:open', source, RewardService.ListSpawnedCars())
end, false)

-- The admin picked a car and typed a server ID. The check is repeated here: the client is never trusted.
RegisterNetEvent('nova_convoytruck:carowner:transfer', function(carId, targetId)
    local src = source
    if not isAdmin(src) then return end
    local ok, message = RewardService.TransferSpawnedCar(src, carId, targetId)
    TriggerClientEvent('nova_convoytruck:client:hudNotify', src, {
        type = ok and 'success' or 'error', title = 'Car ownership', description = message, duration = 8000,
    })
    -- the menu comes back with the car now marked as handed over, ready for the next one
    TriggerClientEvent('nova_convoytruck:carowner:open', src, RewardService.ListSpawnedCars())
end)
