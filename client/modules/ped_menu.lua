-- ─── Nova Convoy — Ped Menu (client) ──────────────────────────────────────────
-- One themed shop window (web/src/lib/hud/PedMenu.svelte) for the vendor peds that used to open a plain ox_lib list: the TDM weapon
-- vendor and the police tactical equipment vendor. Same look as the tablet (the Event Status theme).
--   PedMenu.open({ title, subtitle, items = { { id, label, desc, price, tag } }, accounts = true, onPick = function(id, account) end })
-- The list is only a picker: the server still validates and charges every purchase (onPick fires the same server event as before).

PedMenu = {}

local current = nil

function PedMenu.open(spec)
    if current or type(spec) ~= 'table' then return end
    current = spec
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'pedMenu:open',
        title = spec.title or 'Shop', subtitle = spec.subtitle or '',
        items = spec.items or {}, accounts = spec.accounts ~= false,
    })
end

local function close()
    if not current then return end
    current = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'pedMenu:close' })
end

RegisterNUICallback('pedMenu:close', function(_, cb)
    cb('ok')
    close()
end)

RegisterNUICallback('pedMenu:pick', function(data, cb)
    cb('ok')
    local spec = current
    if not spec or type(data) ~= 'table' then return end
    local account = data.account == 'bank' and 'bank' or 'cash'
    -- the window stays open so several items can be bought in a row; Esc / Close ends it
    if spec.onPick then spec.onPick(data.id, account) end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and current then SetNuiFocus(false, false) end
end)
