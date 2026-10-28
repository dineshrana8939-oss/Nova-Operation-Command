-- ─── Nova Convoy — Civilian Registration Peds (client) ──────────────────────
-- Spawns civilian registration peds for events configured as "Open to Everyone".
-- Provides ox_target interaction with confirmation modal and join dispatch.

local TGT = exports.ox_target
local spawnedPeds = {}   -- convoyId -> ped handle
local spawnedBlips = {}  -- convoyId -> blip handle

-- Disables attack and melee actions for a short duration to prevent mouse clicks on NUI modals
-- from leaking into the game world and punching the NPC ped.
local function suppressMeleeAttack(ms)
    CreateThread(function()
        local deadline = GetGameTimer() + (ms or 1200)
        while GetGameTimer() < deadline do
            DisablePlayerFiring(PlayerId(), true)
            DisableControlAction(0, 24, true)   -- Attack (LMB / RT)
            DisableControlAction(0, 25, true)   -- Aim (RMB / LT)
            DisableControlAction(0, 140, true)  -- Melee Attack Light (R)
            DisableControlAction(0, 141, true)  -- Melee Attack Heavy (Q)
            DisableControlAction(0, 142, true)  -- Melee Attack Alternate (LMB)
            DisableControlAction(0, 257, true)  -- Attack 2
            DisableControlAction(0, 263, true)  -- Melee Attack 1
            DisableControlAction(0, 264, true)  -- Melee Attack 2
            Wait(0)
        end
    end)
end

-- Opens the registration window (from the ped's target option or /eventregistration).
-- Called straight from an ox_target option, taking the NUI focus there does not stick: ox_target runs the option, then —
-- because the NUI is focused — ends its targeting, and the loop that ends it hands the focus back to the game a moment
-- later. The window was drawn but had lost the mouse and keyboard (it looked frozen). So when ox_target is still busy,
-- wait for it to finish and take the focus after.
local function openRegistrationWindow(preselectedEventId)
    CreateThread(function()
        local waited = 0
        while waited < 2000 and exports.ox_target:isActive() do
            Wait(50)
            waited = waited + 50
        end
        if waited > 0 then Wait(250) end   -- the targeting loop wakes every 50-100 ms; let it finish its teardown first
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(false)
        SendNUIMessage({
            action = 'civilianRegistration:open',
            preselectedEventId = preselectedEventId,
        })
    end)
end

local function despawnAll()
    for id, ped in pairs(spawnedPeds) do
        if ped and DoesEntityExist(ped) then
            pcall(function() TGT:removeLocalEntity(ped) end)
            DeleteEntity(ped)
        end
    end
    spawnedPeds = {}
    for id, blip in pairs(spawnedBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    spawnedBlips = {}
end

RegisterNetEvent('nova_convoytruck:civilian:syncPeds', function(peds)
    despawnAll()
    for _, p in ipairs(peds or {}) do
        local modelName = p.model or (p.kind == 'GANG_RACE' and 'a_m_y_runner_01' or 's_m_m_dockwork_01')
        local model = joaat(modelName)
        lib.requestModel(model)

        local ped = CreatePed(4, model, p.x, p.y, p.z - 1.0, p.heading or 0.0, false, true)
        if ped and DoesEntityExist(ped) then
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            FreezeEntityPosition(ped, true)
            SetPedCanRagdoll(ped, false)
            SetPedCanBeTargetted(ped, false)
            SetModelAsNoLongerNeeded(model)

            -- Optional map blip for registration location
            local bCfg = p.blip or {}
            if bCfg.enabled ~= false then
                local blip = AddBlipForCoord(p.x, p.y, p.z)
                SetBlipSprite(blip, bCfg.sprite or (p.kind == 'GANG_RACE' and 311 or 478))
                SetBlipColour(blip, bCfg.colour or 3)
                SetBlipScale(blip, bCfg.scale or 0.85)
                SetBlipAsShortRange(blip, true)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(bCfg.label or 'Event Registration')
                EndTextCommandSetBlipName(blip)
                spawnedBlips[p.convoyId] = blip
            end

            -- This ped is the registration desk for EVERY event open to civilians — street races and Container Wars alike
            -- (the window it opens lists them all, whichever event's ped you walked up to). So the menu is not named after
            -- one event; only "Quick Join" is, because that one joins the event this ped belongs to.
            TGT:addLocalEntity(ped, {
                {
                    label = 'Event Registration',
                    icon = 'fa-solid fa-clipboard-list',
                    distance = 2.5,
                    onSelect = function()
                        openRegistrationWindow(p.convoyId)
                    end,
                },
                {
                    label = ('Quick Join: %s'):format(p.name or 'Event'),
                    icon = 'fa-solid fa-right-to-bracket',
                    distance = 2.5,
                    onSelect = function()
                        local confirm = lib.alertDialog({
                            header = ('Event Registration: %s'):format(p.name or 'Event'),
                            content = ('Do you want to participate in this event?\n\nEvent: %s\nMode: Open to Everyone'):format(p.name or 'Event'),
                            centered = true,
                            cancel = true,
                            labels = {
                                confirm = 'Join Event',
                                cancel = 'Cancel',
                            }
                        })

                        suppressMeleeAttack(1200)

                        if confirm == 'confirm' then
                            local res = lib.callback.await('nova_convoytruck:civilian:joinEvent', false, p.convoyId)
                            if res and res.ok then
                                lib.notify({
                                    title = p.name or 'Event Registration',
                                    description = res.message or 'Successfully registered for event!',
                                    type = 'success',
                                    duration = 6000,
                                })
                            else
                                lib.notify({
                                    title = p.name or 'Event Registration',
                                    description = (res and res.error) or 'Registration failed.',
                                    type = 'error',
                                    duration = 6000,
                                })
                            end
                        end
                    end,
                }
            })

            spawnedPeds[p.convoyId] = ped
        end
    end
end)

RegisterNUICallback('nova_convoytruck:civilianRegistration:close', function(_, cb)
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    suppressMeleeAttack(1000)
    cb('ok')
end)

RegisterCommand('eventregistration', function()
    openRegistrationWindow(nil)
end, false)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    despawnAll()
end)

CreateThread(function()
    Wait(1000)
    TriggerServerEvent('nova_convoytruck:civilian:requestPedsSync')
end)

