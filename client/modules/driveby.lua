-- ─── Nova Convoy — Drive-By Capability (client) ──────────────────────────────
-- Manages vehicle drive-by capability for participants during active operations.

local enabled = false

RegisterNetEvent('nova_convoytruck:runtime:setDriveBy', function(on)
    enabled = on
    SetPlayerCanDoDriveBy(PlayerId(), on)
end)

-- Whether driveby should be forced on right now: either the server has
-- explicitly confirmed this player as a joined participant (enabled), OR
-- they're simply seated in an actual convoy truck (convoy_truck statebag —
-- the same one the truck label/blip code already keys off). The statebag
-- check matters because of a real race: a player who hops into a convoy
-- truck BEFORE formally clicking "Join" would otherwise sit there for
-- however long with driveby not yet applied — GTA holsters two-handed
-- weapons like rifles on vehicle entry until the CanDoDriveBy ped flag is
-- set, and ox_inventory's own weapon-sync watchdog (200ms) sees the
-- resulting mismatch and force-DISARMS the weapon entirely ("forcibly
-- unequipped (caused by game behaviour or another resource)" in console) —
-- by the time "Join" is clicked afterwards, the weapon is already gone and
-- simply turning driveby on doesn't bring it back. Applying the flag the
-- moment they're seated in a convoy truck, regardless of join timing,
-- closes that race instead of just reacting to it.
local function isRacing()
    return LocalPlayer.state.isRacing == true
end

local function shouldForceDriveBy(veh)
    if isRacing() then return false end
    if enabled then return true end
    if LocalPlayer.state.convoy_participant or LocalPlayer.state.inEvent then return true end
    -- While any event is running, drive-by is switched on for everyone in a vehicle. It used to depend on pressing Join in the
    -- Event Status panel (the only thing that sent the flag), so a gang member or officer who had not joined yet - or whose join
    -- flag was cleared by a respawn / character change - could not use a weapon from the driver seat at all.
    -- (Config.DriveBy.everyoneDuringEvents = false brings the old join-only rule back.)
    if (Config.DriveBy or {}).everyoneDuringEvents ~= false and GlobalState.novaEventsActive == true then return true end
    return veh and DoesEntityExist(veh) and (Entity(veh).state.convoy_truck == true or Entity(veh).state.convoy_escort == true)
end

local function applyDriveByFlags(ped)
    if isRacing() then
        SetPlayerCanDoDriveBy(PlayerId(), false)
        SetPedConfigFlag(ped, 104, false)
        SetPedConfigFlag(ped, 161, false)
        SetPedConfigFlag(ped, 437, false)
        SetPedConfigFlag(ped, 313, false)
        return
    end
    SetPlayerCanDoDriveBy(PlayerId(), true)
    SetPedCanSwitchWeapon(ped, true)
    SetPedConfigFlag(ped, 104, true) -- CPED_CONFIG_FLAG_CanDoDriveBy
    SetPedConfigFlag(ped, 161, true) -- CPED_CONFIG_FLAG_CanShootWhileInVehicle (all vehicle seats)
    SetPedConfigFlag(ped, 437, true) -- CPED_CONFIG_FLAG_AllowDriveByUseUpperBodyFacingRef (carbine & two-handed rifle aiming)
    SetPedConfigFlag(ped, 313, true) -- CPED_CONFIG_FLAG_CanDriveBy
end

-- The polling thread below (Wait(50) while seated) still has up to a 50ms
-- gap between actually sitting down and the flag being applied — usually
-- fine, but ox_inventory's OWN weapon-equip verification (client.lua:
-- GiveWeaponToPed + SetCurrentPedWeapon, then checks GetSelectedPedWeapon)
-- runs synchronously the instant you use a weapon from your inventory, with
-- no polling delay of its own. If a player grabs their rifle in that exact
-- window — e.g. the same moment they sit down — GTA still refuses to equip
-- a two-handed weapon because the flag isn't set YET, ox_inventory sees the
-- equip didn't take, and shows "Unable to use <weapon>" — a real, narrower
-- version of the same race the statebag check above already closes for
-- ox_inventory's separate disarm watchdog. Hooking the actual vehicle-entry
-- game event applies the flag the same frame you sit down, not up to 50ms
-- later, closing this last gap.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' then return end
    local ped = PlayerPedId()
    if args[1] ~= ped then return end
    local veh = args[2]
    if shouldForceDriveBy(veh) then
        applyDriveByFlags(ped)
    end
end)

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        if isRacing() then
            if IsPedInAnyVehicle(ped, false) then
                SetPlayerCanDoDriveBy(PlayerId(), false)
                SetPedConfigFlag(ped, 104, false)
                DisableControlAction(0, 25, true) -- INPUT_AIM
                DisableControlAction(0, 68, true) -- INPUT_VEH_AIM
                DisableControlAction(0, 69, true) -- INPUT_VEH_ATTACK
                DisableControlAction(0, 70, true) -- INPUT_VEH_ATTACK2
                DisableControlAction(0, 91, true) -- INPUT_VEH_PASSENGER_AIM
                DisableControlAction(0, 92, true) -- INPUT_VEH_PASSENGER_ATTACK
                DisablePlayerFiring(PlayerId(), true)
            end
            Wait(0)
        elseif IsPedInAnyVehicle(ped, false) then
            local veh = GetVehiclePedIsIn(ped, false)
            if shouldForceDriveBy(veh) then
                applyDriveByFlags(ped)

                -- When aiming or firing in any seat, ensure window is rolled down so rifles have a clear angle
                if IsControlPressed(0, 25) or IsControlPressed(0, 68) or IsControlPressed(0, 91) or IsPlayerFreeAiming(PlayerId()) then
                    for seat = -1, 4 do
                        if GetPedInVehicleSeat(veh, seat) == ped then
                            local windowIndex = seat == -1 and 0 or (seat == 0 and 1 or (seat == 1 and 2 or 3))
                            RollDownWindow(veh, windowIndex)
                            break
                        end
                    end
                end
                Wait(50)
            else
                Wait(1000)
            end
        else
            Wait(1000)   -- the vehicle-enter game event above applies the flags the moment a seat is taken
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if enabled then SetPlayerCanDoDriveBy(PlayerId(), false) end
    enabled = false
end)

-- /drivebycheck — prints what the drive-by code sees right now (sit in a vehicle with a weapon out first), for diagnosing
-- "drive-by does not work" without guessing: is the server's participant flag set, is this vehicle covered, which seat,
-- which weapon, are the ped flags actually set, and is the ped drive-by-ing.
RegisterCommand('drivebycheck', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local seat = 'none'
    if veh ~= 0 then
        for s = -1, 8 do if GetPedInVehicleSeat(veh, s) == ped then seat = tostring(s) break end end
    end
    local _, weapon = GetCurrentPedWeapon(ped, true)
    local lines = {
        ('participant flag from server (enabled): %s'):format(tostring(enabled)),
        ('statebags: convoy_participant=%s inEvent=%s isRacing=%s'):format(tostring(LocalPlayer.state.convoy_participant), tostring(LocalPlayer.state.inEvent), tostring(LocalPlayer.state.isRacing)),
        ('in vehicle: %s  seat: %s  convoy truck/escort state: %s/%s'):format(tostring(veh ~= 0), seat, tostring(veh ~= 0 and Entity(veh).state.convoy_truck), tostring(veh ~= 0 and Entity(veh).state.convoy_escort)),
        ('drive-by forced for this vehicle: %s'):format(tostring(shouldForceDriveBy(veh ~= 0 and veh or nil))),
        ('weapon hash: %s  group: %s  (a DRIVER can only fire pistols / SMGs from a vehicle; rifles fire from the passenger seats)'):format(tostring(weapon), tostring(GetWeapontypeGroup(weapon))),
        ('ped flags 104/161/313/437: %s/%s/%s/%s'):format(tostring(GetPedConfigFlag(ped, 104, true)), tostring(GetPedConfigFlag(ped, 161, true)), tostring(GetPedConfigFlag(ped, 313, true)), tostring(GetPedConfigFlag(ped, 437, true))),
        ('IsPedDoingDriveby: %s'):format(tostring(IsPedDoingDriveby(ped))),
    }
    for _, l in ipairs(lines) do print('[NovaConvoy][drivebycheck] ' .. l) end
    lib.notify({ title = 'Drive-by check', description = table.concat(lines, '\n'), type = 'inform', duration = 12000 })
end, false)
