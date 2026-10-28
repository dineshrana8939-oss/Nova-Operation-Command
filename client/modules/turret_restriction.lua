-- ─── Nova Convoy — Restricted Turret Vehicles (client) ────────────────────────
-- Police must never be able to fire from a militarized/turreted vehicle
-- (models listed in Config.RestrictedTurretVehicles) — gang/civilians seated
-- in the same vehicle are unaffected, this is a police-only restriction.
-- NovaConvoy.Roles.isPolice (client/modules/roles.lua) is the same
-- server-synced role cache the staff-blip visibility already relies on, so
-- this stays correct across job changes without its own round-trip.

local restrictedModels = {}
for _, model in ipairs((Config.RestrictedTurretVehicles and Config.RestrictedTurretVehicles.models) or {}) do
    restrictedModels[joaat(model)] = true
end

local FIRE_CONTROLS = { 24, 25, 331 }

CreateThread(function()
    local cfg = Config.RestrictedTurretVehicles
    if not cfg or not cfg.enabled or not next(restrictedModels) then return end

    while true do
        local ped = PlayerPedId()
        if NovaConvoy.Roles.isPolice and IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and DoesEntityExist(veh) and restrictedModels[NovaConvoy.SafeEntityModel(veh)] then
                for _, control in ipairs(FIRE_CONTROLS) do
                    DisableControlAction(0, control, true)
                end
                Wait(0) -- must reapply every frame while seated in a restricted vehicle
            else
                Wait(1000)
            end
        else
            Wait(NovaConvoy.Roles.isPolice and 1000 or 3000)
        end
    end
end)
