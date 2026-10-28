-- ─── Nova Convoy — player notifications (client) ──────────────────────────────
-- Every notification this resource shows (lib.notify calls on the client, and the server's TriggerClientEvent
-- 'nova_convoytruck:client:hudNotify') is drawn by the Operations Hub HUD (web/src/lib/hud/Toast.svelte) in the same
-- look as the other HUD cards: event colour, icon plate, category · tag line, title, message and a timeout line.
-- Config.Notify.enabled = false hands everything back to ox_lib's own notifications.
--
-- `lib` is this resource's own copy of the ox_lib table, so replacing lib.notify here changes it for this resource only;
-- other resources keep using ox_lib's notifications.

local cfg = Config.Notify or {}
local oxNotify = lib.notify

local function brandingTitle()
    return (Config.Branding and Config.Branding.tabletTitle) or 'Operations Hub'
end

-- Titles that only say "this came from the script": the message itself is the headline then.
local function isGenericTitle(title)
    return title == nil or title == '' or title == 'Convoy System' or title == brandingTitle()
end

local function show(data)
    if Config.Notify and Config.Notify.enabled == false then
        return oxNotify(data)
    end
    data = type(data) == 'table' and data or { description = tostring(data) }
    local title = (not isGenericTitle(data.title)) and data.title or nil
    SendNUIMessage({
        action = 'notify',
        title = title,
        message = data.description,
        type = data.type,
        duration = tonumber(data.duration),
        category = data.category,
        tag = data.tag,
        event = data.event,
        position = (Config.Notify or {}).position,
        maxVisible = (Config.Notify or {}).maxVisible,
    })
end

NovaNotify = show
lib.notify = show

RegisterNetEvent('nova_convoytruck:client:hudNotify', function(data)
    show(data)
end)