-- ─── Nova Convoy — character switch guard (client) ────────────────────────────
-- Some players keep several characters (a gang member, an EMS medic, a police officer ...). When the player logs out of one
-- character and into another, nothing of the old one may stay on screen or in the ped: the Event Status (gang) panel and the
-- tablet close, the forced drive-by and the squad HUDs reset. Opening them again is decided by the server for the CURRENT
-- character only (gang member / police / admin), so an EMS character cannot get the gang panel.
local function resetForCharacterChange()
    TriggerEvent('nova_convoytruck:client:livePanelForceClose')
    SendNUIMessage({ action = 'livepanel:close' })
    SendNUIMessage({ action = 'tablet:close' })
    if closeTablet then pcall(closeTablet) end
    TriggerEvent('nova_convoytruck:runtime:setDriveBy', false)
    SendNUIMessage({ action = 'gangSquadHide' })
    SendNUIMessage({ action = 'policeSquadHide' })
    SendNUIMessage({ action = 'convoyProgressHide' })
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
end

RegisterNetEvent('nova_convoytruck:client:characterUnloaded', resetForCharacterChange)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', resetForCharacterChange)