-- ─── Nova Convoy — Command Tablet (client) ────────────────────────────────────
-- Opens/closes the Svelte NUI tablet and proxies every server-validated action
-- through a single 'invoke' NUI callback, so the front-end only needs one
-- fetchNui() helper for the whole app. Access is re-checked server-side on
-- open AND on every individual action inside server/modules/callbacks.lua —
-- this file never decides who is allowed to do what.

local isOpen = false
local minimized = false
local closeTablet -- forward-declared: the tablet-prop thread below (defined
-- first in this file) needs to call it on death, but its real definition
-- lives further down

-- ── Held tablet prop + animation ────────────────────────────────────────────────
-- Plays while NUI focus is actually held open — NOT while minimized for a
-- route preview, since the player needs to walk/look around freely then and
-- holding a tablet the whole time would look wrong. Dict/clip/prop/bone/
-- offset/rotation verified against a working reference implementation
-- (FrazzIe's FiveM tablet-animation gist) rather than guessed — a wrong bone
-- index or offset here would just silently float the prop in the wrong spot.
local TABLET_ANIM_DICT = 'amb@code_human_in_bus_passenger_idles@female@tablet@base'
local TABLET_ANIM_CLIP = 'base'
local TABLET_PROP = `prop_cs_tablet`
local TABLET_BONE = 60309
local TABLET_OFFSET = vector3(0.03, 0.002, -0.0)
local TABLET_ROTATION = vector3(10.0, 160.0, 0.0)

local holdingTablet = false
local tabletPropGeneration = 0
local currentTabletProp = nil -- module-level (not thread-local) so ANY cleanup
-- path — including onResourceStop — can detach/delete it directly and
-- immediately, without depending on the background thread below noticing.

-- Detaches/deletes the prop RIGHT NOW, synchronously — this is what actually
-- removes it, not just a flag flip. Previously, cleanup only happened inside
-- the startTabletProp thread's own loop, on its NEXT ~150ms iteration after
-- noticing holdingTablet/generation changed — fine for a normal close while
-- the resource keeps running, but FiveM hard-kills every one of a resource's
-- running threads the instant it actually stops/restarts, so that loop would
-- never reach its cleanup code at all, leaving the prop permanently stuck
-- attached to the ped. Calling this directly from both stopTabletProp() and
-- onResourceStop closes that gap.
local function removeTabletPropNow()
    if currentTabletProp and DoesEntityExist(currentTabletProp) then
        DetachEntity(currentTabletProp, true, false)
        DeleteEntity(currentTabletProp)
    end
    currentTabletProp = nil
    ClearPedSecondaryTask(PlayerPedId())
end

local function stopTabletProp()
    holdingTablet = false
    tabletPropGeneration = tabletPropGeneration + 1
    removeTabletPropNow()
end

-- generation guards against rapid open/close/open toggling starting a second
-- thread (and a second prop) while the first is still mid-load — same
-- pattern already used for previewGeneration in route_editor.lua.
local function startTabletProp()
    if holdingTablet then return end
    holdingTablet = true
    tabletPropGeneration = tabletPropGeneration + 1
    local generation = tabletPropGeneration

    CreateThread(function()
        RequestAnimDict(TABLET_ANIM_DICT)
        while not HasAnimDictLoaded(TABLET_ANIM_DICT) do Wait(50) end
        if tabletPropGeneration ~= generation then return end

        RequestModel(TABLET_PROP)
        while not HasModelLoaded(TABLET_PROP) do Wait(50) end
        if tabletPropGeneration ~= generation then
            SetModelAsNoLongerNeeded(TABLET_PROP)
            return
        end

        local ped = PlayerPedId()
        local prop = CreateObject(TABLET_PROP, 0.0, 0.0, 0.0, true, true, false)

        -- Close/reopen can race right here — the prop above is created but
        -- not yet tracked in currentTabletProp, so stopTabletProp's own
        -- synchronous cleanup (which only knows about whatever
        -- currentTabletProp already was) can't reach it. Left unchecked this
        -- prop would get attached below anyway and then never be cleaned up
        -- (the loop below simply never runs when the generation's already
        -- stale, and "no cleanup here on purpose" only holds when stopTabletProp
        -- actually got to delete THIS prop) — a permanently stuck tablet
        -- model glued to the ped's hand, which is exactly what this was
        -- causing intermittently.
        if tabletPropGeneration ~= generation then
            if DoesEntityExist(prop) then DeleteEntity(prop) end
            SetModelAsNoLongerNeeded(TABLET_PROP)
            return
        end

        currentTabletProp = prop
        local boneIndex = GetPedBoneIndex(ped, TABLET_BONE)
        AttachEntityToEntity(
            prop, ped, boneIndex,
            TABLET_OFFSET.x, TABLET_OFFSET.y, TABLET_OFFSET.z,
            TABLET_ROTATION.x, TABLET_ROTATION.y, TABLET_ROTATION.z,
            true, false, false, false, 2, true
        )
        SetModelAsNoLongerNeeded(TABLET_PROP)

        -- Same race, second window: a close/reopen landing between the
        -- create and the attach above. Clean up OUR OWN prop reference
        -- directly here (not via the shared currentTabletProp, which could
        -- already belong to a newer generation's thread by now) so we can
        -- never delete a prop that isn't ours.
        if tabletPropGeneration ~= generation then
            if DoesEntityExist(prop) then
                DetachEntity(prop, true, false)
                DeleteEntity(prop)
            end
            if currentTabletProp == prop then currentTabletProp = nil end
            return
        end

        while tabletPropGeneration == generation do
            local currentPed = PlayerPedId()
            -- Dying (or the game handing out a brand-new ped on respawn)
            -- used to leave the prop glued to the old/corpse ped forever —
            -- this loop kept "holding the tablet" against an entity that
            -- was never getting up again. Force a real close instead of
            -- just re-attaching, so the tablet UI itself closes too rather
            -- than sitting open behind a death screen.
            if currentPed ~= ped or IsEntityDead(currentPed) then
                stopTabletProp()
                if isOpen then closeTablet() end
                return
            end
            ped = currentPed
            if not IsEntityPlayingAnim(ped, TABLET_ANIM_DICT, TABLET_ANIM_CLIP, 3) then
                TaskPlayAnim(ped, TABLET_ANIM_DICT, TABLET_ANIM_CLIP, 3.0, 3.0, -1, 49, 0, false, false, false)
            end
            Wait(150)
        end
        -- No cleanup here on purpose — stopTabletProp() already ran it
        -- synchronously the instant the generation changed (see above).
    end)
end

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    removeTabletPropNow()
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    isOpen = false
    minimized = false
end)

function closeTablet()
    if not isOpen then return end
    isOpen = false
    minimized = false
    SetNuiFocus(false, false)
    stopTabletProp()
    -- Safety net: CreateConvoy stays mounted in the background even while
    -- the tablet is closed (fixes an earlier draft-loss bug), so leaving the
    -- Route tab's own onDestroy as the only thing that tears down a route
    -- preview (see route_editor.lua) would leave stray blips/the big map
    -- stuck open if the player closes the whole tablet without switching
    -- off Route first.
    TriggerEvent('nova_convoytruck:client:tabletClosed')
end

local function openTablet()
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    startTabletProp()
    SendNUIMessage({ action = 'tablet:open' })
end

-- Fired by route_editor.lua's "Preview on Map" — the player's own map key
-- genuinely opens the real GTA map with the preview blips showing, but only
-- once NUI focus lets their keypress actually reach the game. This is a true
-- minimize, not a close: isOpen stays true so the NUI DOM never unmounts —
-- nothing about CreateConvoy/RouteBuilder's draft state or an in-progress
-- route preview gets torn down. Only the visual frame hides and NUI focus
-- releases; pressing the tablet keybind again restores it exactly where it
-- was left.
local restoreTabletFromPreview

-- While the tablet is out of the way for a preview (the projector screen size, a war zone, a route on the map, a banner) there is nothing
-- to click, so the way back is on the screen: a hint at the bottom and ENTER (or the tablet key) brings the tablet back at once.
local function showReturnHint()
    SetTextFont(4)
    SetTextScale(0.0, 0.42)
    SetTextColour(255, 255, 255, 240)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName('Press ENTER to return to the tablet')
    EndTextCommandDisplayText(0.5, 0.93)
end

local function hideTabletForPreview()
    if not isOpen or minimized then return end
    minimized = true
    SetNuiFocus(false, false)
    stopTabletProp() -- the player needs to walk/look around freely to see the preview
    SendNUIMessage({ action = 'tablet:minimize' })
    CreateThread(function()
        Wait(400)   -- the click that started the preview must not count as the "return" press
        while minimized do
            showReturnHint()
            -- ENTER brings the tablet back, except while a perimeter is being drawn: there ENTER means SAVE, and the editor returns the tablet itself when it ends
            if not NovaPerimeterEditing and (IsControlJustReleased(0, 191) or IsDisabledControlJustReleased(0, 191)) then restoreTabletFromPreview() break end
            Wait(0)
        end
    end)
end

restoreTabletFromPreview = function()
    if not minimized then return end
    minimized = false
    SetNuiFocus(true, true)
    startTabletProp()
    SendNUIMessage({ action = 'tablet:restore' })
    TriggerEvent('nova_convoytruck:client:tabletRestored')   -- a running preview (zone / projector screen) ends with it
end

AddEventHandler('nova_convoytruck:client:hideTabletForPreview', hideTabletForPreview)
AddEventHandler('nova_convoytruck:client:restoreTabletFromPreview', restoreTabletFromPreview)

-- The Announcements tab's "Preview Myself": the banner shows at the top of the screen, which the open tablet would cover,
-- so the tablet steps aside for the preview and comes back afterwards (the tablet key also brings it back at once).
RegisterNUICallback('tablet:previewHide', function(_, cb)
    hideTabletForPreview()
    cb('ok')
end)
RegisterNUICallback('tablet:previewRestore', function(_, cb)
    restoreTabletFromPreview()
    cb('ok')
end)

-- Shared with the Event Status panel (live_panel.lua) so it holds the same tablet.
exports('StartTabletProp', function() startTabletProp() end)
exports('StopTabletProp', function() stopTabletProp() end)

RegisterCommand(Config.Tablet.command, function()
    if minimized then
        restoreTabletFromPreview()
    elseif isOpen then
        closeTablet()
    else
        openTablet()
    end
end, false)

RegisterKeyMapping(Config.Tablet.command, (Config.Branding and Config.Branding.tabletKeyLabel) or 'Open Operations Hub Tablet', 'keyboard', Config.Tablet.keybind)

RegisterNUICallback('tablet:close', function(_, cb)
    closeTablet()
    cb('ok')
end)

-- Model existence can only be checked reliably client-side (streamed model
-- data isn't available on the server). Used by the Truck Config vehicle
-- catalog so a typo'd model name fails fast instead of breaking a spawn later.
RegisterNUICallback('validateModel', function(data, cb)
    local model = data and data.model
    if type(model) ~= 'string' or model == '' then
        cb({ valid = false })
        return
    end
    cb({ valid = IsModelInCdimage(GetHashKey(model)) and IsModelAVehicle(GetHashKey(model)) })
end)

RegisterNUICallback('invoke', function(data, cb)
    if type(data) ~= 'table' or type(data.name) ~= 'string' then
        cb({ ok = false, error = 'Malformed request.' })
        return
    end
    local ok, result = pcall(lib.callback.await, data.name, false, table.unpack(data.args or {}))
    if not ok then
        lib.print.error(('[NovaConvoy] NUI invoke callback error for "%s": %s'):format(tostring(data.name), tostring(result)))
        cb({ ok = false, error = tostring(result) })
        return
    end
    cb(result or { ok = false, error = 'No response from server.' })
end)

-- The User Guide tab: the text of docs/user_guide.md (read from disk by the server on every open) plus the names of every
-- command this resource registers — the server's and this client's — so a command nobody has described yet still shows.
RegisterNUICallback('guide:load', function(_, cb)
    local ok, res = pcall(lib.callback.await, 'nova_convoytruck:getUserGuide', false)
    if not ok or type(res) ~= 'table' or not res.ok then
        cb({ ok = false, error = (type(res) == 'table' and res.error) or 'The guide could not be loaded.' })
        return
    end
    local names, seen = {}, {}
    for _, list in ipairs({ res.commands or {}, NovaCommandNames or {} }) do
        for _, n in ipairs(list) do
            if not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
    end
    table.sort(names)
    res.commands = names
    cb(res)
end)

-- convoy_manager.lua's broadcastStartPeds now piggybacks this alongside its
-- own start-ped sync (every mutation already calls it) — tells whichever
-- tablet screens are open that SOME convoy's definition changed elsewhere,
-- so they know to re-fetch instead of only ever refreshing on mount or a
-- manual Refresh click.
-- The address this player is connected to: the tablet uses it to open a report PDF link in the player's own web browser
-- (the game's browser cannot save files). Config.ReportDownload.baseUrl, when set, wins over this.
RegisterNUICallback('reports:baseUrl', function(_, cb)
    cb({ ok = true, endpoint = GetCurrentServerEndpoint() })
end)

RegisterNetEvent('nova_convoytruck:client:convoyListChanged', function()
    SendNUIMessage({ action = 'convoyListChanged' })
end)

-- The server changed this player's staff access (role, permissions, enabled / revoked) or, for staff who manage
-- staff, the staff lists. The open tablet re-reads its permissions: sections appear or disappear at once and the
-- tablet closes if access is gone. The server re-checks every action anyway; this only keeps the screen honest.
RegisterNetEvent('nova_convoytruck:client:staffChanged', function(mine)
    SendNUIMessage({ action = 'staff:changed', mine = mine == true })
end)

-- A gang's roles, ranks, members or settings changed (from the admin tablet or from the gang's own Event Status panel). Both
-- panels read the same stored data, so whichever is open re-reads it now instead of waiting for its next poll.
RegisterNetEvent('nova_convoytruck:client:gangChanged', function(gangId, gangName)
    SendNUIMessage({ action = 'gang:changed', gangId = gangId, gangName = gangName })
end)

RegisterNetEvent('nova_convoytruck:client:updateEventBanners', function(banners)
    SendNUIMessage({ action = 'updateEventBanners', banners = banners })
end)

