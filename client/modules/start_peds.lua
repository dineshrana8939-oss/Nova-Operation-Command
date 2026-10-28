-- ─── Nova Convoy — Convoy Start Trigger Peds (client) ─────────────────────────
-- Target interaction peds for starting scheduled convoys.

local TGT = exports.ox_target
local spawned = {} -- convoyId -> ped handle
local startBlips = {} -- convoyId -> blip handle
--   280 = radar_staging  (truck park / staging point - convoy start trigger)
local START_PED_BLIP = { sprite = 280, colour = 2, scale = 0.9 }

-- Blip label has to name the specific convoy being started — two start peds
-- side by side with a generic "Start Convoy" label would be indistinguishable
-- on the map, so the convoy's own name is the label.
local function blipLabel(p)
    if p.kind == 'GANG_RACE' then
        return ('Street Race Grid: %s'):format(p.name or 'Rally')
    end
    return ('Start Convoy: %s'):format(p.name or 'Convoy')
end
local function despawnAll()
    for _, ped in pairs(spawned) do
        if ped and DoesEntityExist(ped) then
            TGT:removeLocalEntity(ped)
            DeleteEntity(ped)
        end
    end
    spawned = {}
    for _, blip in pairs(startBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    startBlips = {}
end

RegisterNetEvent('nova_convoytruck:client:syncStartPeds', function(peds)
    despawnAll()
    -- This `for` loop was missing entirely — every line below referenced `p`
    -- as if it were bound by one, which meant the very first statement in
    -- this handler ("local modelName = p.model") threw "attempt to index a
    -- nil value" immediately, every single time this event fired. No start
    -- ped — Convoy OR Gang Rally — ever actually spawned as a result: you
    -- could place one in the tablet and save it, but it would never appear
    -- in the world at all.
    for _, p in ipairs(peds or {}) do
        local modelName = p.model
        if p.kind == 'GANG_RACE' then
            if not modelName or modelName == Config.Peds.convoyStart then
                modelName = Config.Peds.raceStart
            end
        else
            if not modelName then
                modelName = Config.Peds.convoyStart
            end
        end
        local model = joaat(modelName)
        lib.requestModel(model)
        -- -1.0 on z: CreatePed places a ped's root slightly above the coords
        -- you give it (same quirk equipment.lua's vendor ped already
        -- compensates for) — without this it spawns floating just off the
        -- ground at the placed position.
        local ped = CreatePed(4, model, p.x, p.y, p.z - 1.0, p.heading or 0.0, false, true)
        if ped and DoesEntityExist(ped) then
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            FreezeEntityPosition(ped, true)
            SetModelAsNoLongerNeeded(model)

            -- If it's a GANG_RACE ped, racers / gang members can see the checkered flag blip on map!
            -- Standard convoy start peds remain gated on NovaConvoy.Roles.canSeeStaffBlips()
            local shouldDrawBlip = false
            local blipSprite = START_PED_BLIP.sprite
            local blipColour = START_PED_BLIP.colour

            if p.kind == 'GANG_RACE' then
                shouldDrawBlip = true
                -- 38 is the checkered-flag sprite — same one this project already
                -- uses (and has verified renders correctly) for the finish-line
                -- blip in rally_race.lua. 315 was never actually a real flag icon
                -- on this game build; it rendered as the engine's generic
                -- fallback square, same class of bug as sprite 352 elsewhere in
                -- this project (see checkpointStart's own comment on that).
                blipSprite = 38
                blipColour = 5 -- Yellow
            elseif NovaConvoy.Roles.canSeeStaffBlips() then
                shouldDrawBlip = true
            end

            if shouldDrawBlip then
                local blip = AddBlipForCoord(p.x, p.y, p.z)
                SetBlipSprite(blip, blipSprite)
                SetBlipColour(blip, blipColour)
                SetBlipScale(blip, p.kind == 'GANG_RACE' and 1.0 or START_PED_BLIP.scale)
                SetBlipAsShortRange(blip, true)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(blipLabel(p))
                EndTextCommandSetBlipName(blip)
                startBlips[p.convoyId] = blip
            end

            local actionLabel = p.kind == 'GANG_RACE' and ('Enter / Start Race: %s'):format(p.name or 'Street Race') or blipLabel(p)
            local actionIcon = p.kind == 'GANG_RACE' and 'fa-solid fa-flag-checkered' or 'fa-solid fa-truck-front'

            TGT:addLocalEntity(ped, { {
                label = actionLabel,
                icon = actionIcon,
                onSelect = function()
                    TriggerServerEvent('nova_convoytruck:runtime:server:triggerStartPed', p.convoyId)
                end,
            } })
            spawned[p.convoyId] = ped
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    despawnAll()
end)

-- Roles resolve a beat after the peds sync (server round-trip) — if a start
-- ped arrived before we knew our role, draw its blip now that we do.
RegisterNetEvent('nova_convoytruck:client:rolesResolved', function()
    if not NovaConvoy.Roles.canSeeStaffBlips() then return end
    TriggerServerEvent('nova_convoytruck:server:requestStartPedsSync')
end)
