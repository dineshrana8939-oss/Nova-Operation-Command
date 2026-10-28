-- ─── Nova Convoy — Live Operations Panel (client) ─────────────────────────────
-- Live operational status HUD/NUI view. Access is decided entirely server-side
-- (see nova_convoytruck:getStatusPanelAccess in server/modules/callbacks.lua) —
-- this file only opens the panel once the server has said yes.
--
-- Who may open it:
--   • administrators (ACE permission in Config.CreatorAccess)
--   • any member of a gang registered in the admin panel (a gang leader adding
--     a member via My Gang, or an admin adding one, both count — membership is
--     the single source of truth, not who added them)
-- No gang and no admin ACE → refused.

local isOpen = false
local closePanel -- forward-declared for the access guard below

local function closePanel()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    exports[GetCurrentResourceName()]:StopTabletProp()
end

local function openPanel()
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    exports[GetCurrentResourceName()]:StartTabletProp()
    local b = Config.Branding or {}
    SendNUIMessage({ action = 'livepanel:open', title = b.statusPanelTitle or 'Event Status', badge = b.statusPanelBadge or '' })
end

-- Round-trips to the server before opening. The panel renders gang-management
-- and roster tooling, so letting the client self-authorize would be trivially
-- bypassable — the server is the only place this decision is made.
local lastAllowedAt = 0   -- when the server last said this player may open the panel

local function tryOpenPanel()
    if isOpen then
        closePanel()
        return
    end

    -- Approved a moment ago: open at once and let the server confirm again in the background (it closes the panel if the answer
    -- changed, e.g. a character switch). The first open, or one after a minute, still waits for the server.
    if lastAllowedAt > 0 and GetGameTimer() - lastAllowedAt < 60000 then
        openPanel()
        CreateThread(function()
            local again = lib.callback.await('nova_convoytruck:getStatusPanelAccess', false)
            if again and again.allowed then lastAllowedAt = GetGameTimer()
            elseif again then lastAllowedAt = 0; if isOpen then closePanel() end end
        end)
        return
    end

    local access = lib.callback.await('nova_convoytruck:getStatusPanelAccess', false)
    if not access or not access.allowed then
        if not access then
            lib.notify({
                title = (Config.Branding and Config.Branding.statusPanelTitle) or 'Event Status',
                description = 'Unable to verify your access. Try again in a moment.',
                type = 'error',
                duration = 5000,
            })
        elseif access.denyReason == 'police_on_duty' then
            lib.notify({
                title = (Config.Branding and Config.Branding.statusPanelTitle) or 'Event Status',
                description = 'You have the police role (on duty), so you cannot open the gang Event Status panel. Go off duty or switch character.',
                type = 'error',
                duration = 7000,
            })
        else
            lib.notify({
                title = (Config.Branding and Config.Branding.statusPanelTitle) or 'Event Status',
                description = 'Access denied — this panel is limited to administrators and registered gang members.',
                type = 'error',
                duration = 6000,
            })
        end
        return
    end

    lastAllowedAt = GetGameTimer()
    openPanel()
end

RegisterCommand(Config.StatusPanel.command, function()
    tryOpenPanel()
end, false)

RegisterKeyMapping(Config.StatusPanel.command, (Config.Branding and Config.Branding.statusPanelKeyLabel) or 'Open Event Status Panel', 'keyboard', Config.StatusPanel.keybind)

-- Going on duty while the gang panel is open closes it (re-checked by the server, same rule as opening).
local function recheckAfterDutyChange()
    if not isOpen then return end
    Wait(300)   -- let the framework finish applying the new duty state server-side
    if not isOpen then return end
    local access = lib.callback.await('nova_convoytruck:getStatusPanelAccess', false)
    if access and not access.allowed then
        SendNUIMessage({ action = 'livepanel:close' })
        closePanel()
        lib.notify({
            title = (Config.Branding and Config.Branding.statusPanelTitle) or 'Event Status',
            description = 'You have the police role (on duty), so the gang Event Status panel was closed.',
            type = 'error',
            duration = 6000,
        })
    end
end
RegisterNetEvent('QBCore:Client:SetDuty', function() CreateThread(recheckAfterDutyChange) end)
RegisterNetEvent('QBCore:Client:OnJobUpdate', function() CreateThread(recheckAfterDutyChange) end)
RegisterNetEvent('QBCore:Client:OnGangUpdate', function() CreateThread(recheckAfterDutyChange) end)

RegisterNetEvent('nova_convoytruck:client:livePanelForceClose', function()
    if isOpen then SendNUIMessage({ action = 'livepanel:close' }) end
    closePanel()
end)

RegisterNUICallback('livepanel:close', function(_, cb)
    closePanel()
    cb('ok')
end)

-- Fired when player uses the status panel item
RegisterNetEvent('nova_convoytruck:client:openStatusPanelFromItem', function()
    tryOpenPanel()
end)
