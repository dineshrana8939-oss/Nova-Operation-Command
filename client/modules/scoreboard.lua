-- TAB toggles the in-match scoreboard (TDM and Practice Range): press once to
-- open, press again to close. Display only — no NUI focus, so the player keeps
-- full control of the game while it is up. The server decides which mode the
-- player is in and answers with nothing when they are in neither, so pressing
-- TAB elsewhere does nothing (and an open board closes itself when the match ends).

local open = false
local EVENT_REQUEST = 'nova_convoytruck:scoreboard:request'
local EVENT_DATA = 'nova_convoytruck:scoreboard:data'

local function closeBoard()
    open = false
    SendNUIMessage({ action = 'scoreboardHide' })
end

local function openBoard()
    open = true
    CreateThread(function()
        local nextPoll = 0
        while open do
            -- TAB is also the weapon wheel; keep it from popping up while the board is open
            DisableControlAction(0, 37, true)
            local now = GetGameTimer()
            if now >= nextPoll then
                nextPoll = now + 1000
                TriggerServerEvent(EVENT_REQUEST)
            end
            Wait(0)
        end
    end)
end

RegisterCommand('nova_scoreboard', function()
    if open then closeBoard() else openBoard() end
end, false)

RegisterKeyMapping('nova_scoreboard', 'Event Scoreboard (toggle)', 'keyboard', 'TAB')

RegisterNetEvent(EVENT_DATA, function(payload)
    if not open then return end
    if payload then
        SendNUIMessage({ action = 'scoreboardShow', payload = payload })
    else
        -- not in a match (or it just ended): nothing to show, so drop the toggle
        closeBoard()
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then closeBoard() end
end)
