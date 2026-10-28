-- ─── Nova Convoy — Inventory Bridge (client) ───────────────────────────────────
-- Opens a stash already registered server-side via Inventory.RegisterStash
-- (bridge/inventory.lua). Auto-detects the same way. ox_inventory path is
-- verified against this server's installed copy; qb-inventory/ps-inventory/
-- qs-inventory are best-effort against each script's documented API.

local function detectInventory()
    if GetResourceState('ox_inventory') == 'started' then return 'ox' end
    if GetResourceState('qb-inventory') == 'started' then return 'qb' end
    if GetResourceState('ps-inventory') == 'started' then return 'qb' end
    if GetResourceState('qs-inventory') == 'started' then return 'qs' end
    return nil
end

local kind = detectInventory()

InventoryClient = {}
InventoryClient.Kind = kind

function InventoryClient.OpenStash(id)
    if kind == 'ox' then
        exports.ox_inventory:openInventory('stash', id)
    elseif kind == 'qb' then
        TriggerServerEvent('inventory:server:OpenInventory', 'stash', id, { maxweight = 2000000, slots = 10 })
    elseif kind == 'qs' then
        TriggerServerEvent('qs-inventory:server:openinventory', 'stash', id)
    else
        lib.notify({ title = 'Convoy System', description = 'No inventory system detected — cannot loot this truck.', type = 'error' })
    end
end
