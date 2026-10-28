-- ─── Nova Convoy — Inventory Bridge (server) ──────────────────────────────────
-- Auto-detects an inventory resource the same way bridge/init.lua auto-detects
-- a framework, so item-based rewards and the captured/destroyed-truck loot
-- stash (see makeTruckLootable in convoy_runtime.lua) work regardless of
-- which inventory addon a server runs.
--
-- Verification status:
--   ox_inventory   -> verified against the actual copy installed on this
--                     server (exports: AddItem/RemoveItem/Items/RegisterStash,
--                     all confirmed by reading modules/inventory/server.lua).
--   qb-inventory / -> written against each script's own documented standard
--   ps-inventory      export API. NOT installed on this server, so these two
--   qs-inventory      paths are best-effort/unverified — community inventory
--                     forks vary more than ox_inventory's single-maintainer
--                     API, so double-check against your exact fork if
--                     something doesn't work.
--
-- Contract (all providers implement this shape):
--   AddItem(inv, item, count, metadata)    -> boolean ok
--     `inv` is a player source OR an inventory/stash id string (ox_inventory
--     supports adding directly into a stash by name, which is how the truck
--     loot gets pre-seeded before anyone opens it).
--   RemoveItem(inv, item, count, metadata) -> boolean ok
--   ItemExists(item)                        -> boolean
--   RegisterStash(id, label, slots, weight, coords) -> nothing meaningful returned
--   ClearStash(id)                          -> nothing meaningful returned (best-effort)

local function detectInventory()
    if GetResourceState('ox_inventory') == 'started' then return 'ox' end
    if GetResourceState('qb-inventory') == 'started' then return 'qb' end
    if GetResourceState('ps-inventory') == 'started' then return 'qb' end -- ps-inventory: qb-inventory-API-compatible fork
    if GetResourceState('qs-inventory') == 'started' then return 'qs' end
    return nil
end

local kind = detectInventory()

Inventory = {}
Inventory.Kind = kind

-- ── ox_inventory (verified) ──────────────────────────────────────────────────────
local function oxAddItem(inv, item, count, metadata)
    local ok, reason = exports.ox_inventory:AddItem(inv, item, count, metadata)
    return ok and true or false, (not ok) and reason or nil   -- reason: 'inventory_full', 'invalid_item', ...
end
local function oxRemoveItem(inv, item, count, metadata)
    local ok = exports.ox_inventory:RemoveItem(inv, item, count, metadata)
    return ok and true or false
end
local function oxItemExists(item)
    return exports.ox_inventory:Items(item) ~= nil
end
local function oxRegisterStash(id, label, slots, weight, coords)
    exports.ox_inventory:RegisterStash(id, label, slots or 10, weight or 20000, nil, nil, coords)
end
-- Wipes whatever is currently sitting in a stash — used to purge convoy
-- truck loot the moment an event ends (see Runtime.finish), so an unlooted
-- stash never survives to leak into a LATER run of the same convoy
-- definition (Edit & Reuse reuses the same truck ids, which built the exact
-- same stashId, so re-seeding it via AddItem without this would just keep
-- stacking more loot on top of whatever was never collected last time).
local function oxClearStash(id)
    pcall(function() exports.ox_inventory:ClearInventory(id) end)
end

-- ── qb-inventory / ps-inventory (documented standard API, unverified here) ───────
local function qbAddItem(inv, item, count, metadata)
    local ok = pcall(function() return exports['qb-inventory']:AddItem(inv, item, count, nil, metadata) end)
    return ok
end
local function qbRemoveItem(inv, item, count, metadata)
    local ok = pcall(function() return exports['qb-inventory']:RemoveItem(inv, item, count) end)
    return ok
end
local function qbItemExists(item)
    local ok, list = pcall(function() return exports['qb-inventory']:GetItemsList() end)
    return ok and list ~= nil and list[item] ~= nil
end
local function qbRegisterStash(id, label, slots, weight, coords)
    -- qb-inventory/ps-inventory create a stash record on first open rather
    -- than requiring server-side pre-registration — nothing to do here.
    -- Pre-seeding loot into it before anyone opens it isn't reliably
    -- supported by this API, unlike ox_inventory's stash-as-inv-id AddItem.
end
-- No documented "wipe a stash by id" export for qb-inventory/ps-inventory —
-- same unverified-backend caveat as RegisterStash above. A leftover stash
-- here just means truck loot silently doesn't get pre-cleared between runs
-- on these backends, not a crash.
local function qbClearStash(id) end

-- ── qs-inventory (documented standard API, unverified here) ──────────────────────
local function qsAddItem(inv, item, count, metadata)
    local ok = pcall(function() return exports['qs-inventory']:AddItem(inv, item, count, metadata) end)
    return ok
end
local function qsRemoveItem(inv, item, count, metadata)
    local ok = pcall(function() return exports['qs-inventory']:RemoveItem(inv, item, count, metadata) end)
    return ok
end
local function qsItemExists(item)
    local ok, list = pcall(function() return exports['qs-inventory']:GetItemList() end)
    return ok and list ~= nil and list[item] ~= nil
end
local function qsRegisterStash(id, label, slots, weight, coords)
    -- Same caveat as qb-inventory — dynamic stash creation, no reliable
    -- pre-seed-before-first-open support.
end
local function qsClearStash(id) end -- same caveat as qbClearStash above

-- ── item count (used by lockpick durability — check without consuming) ────────────
local function oxGetItemCount(inv, item)
    local ok, n = pcall(function() return exports.ox_inventory:GetItemCount(inv, item) end)
    return ok and tonumber(n) or 0
end
local function qbGetItemCount(inv, item)
    local ok, it = pcall(function() return exports['qb-inventory']:GetItemByName(inv, item) end)
    if ok and type(it) == 'table' then return tonumber(it.amount or it.count) or 0 end
    return 0
end
local function qsGetItemCount(inv, item)
    local ok, n = pcall(function() return exports['qs-inventory']:GetItemTotalAmount(inv, item) end)
    return ok and tonumber(n) or 0
end

local ADAPTERS = {
    ox = { GetItemCount = oxGetItemCount, AddItem = oxAddItem, RemoveItem = oxRemoveItem, ItemExists = oxItemExists, RegisterStash = oxRegisterStash, ClearStash = oxClearStash },
    qb = { GetItemCount = qbGetItemCount, AddItem = qbAddItem, RemoveItem = qbRemoveItem, ItemExists = qbItemExists, RegisterStash = qbRegisterStash, ClearStash = qbClearStash },
    qs = { GetItemCount = qsGetItemCount, AddItem = qsAddItem, RemoveItem = qsRemoveItem, ItemExists = qsItemExists, RegisterStash = qsRegisterStash, ClearStash = qsClearStash },
}

local adapter = ADAPTERS[kind]

function Inventory.AddItem(inv, item, count, metadata)
    if not adapter then
        lib.print.warn(('[NovaConvoy] No inventory system detected — cannot give item "%s".'):format(tostring(item)))
        return false
    end
    return adapter.AddItem(inv, item, count or 1, metadata)   -- ok, reason (reason only where the inventory tells it)
end

-- How many of `item` the player carries (0 when unknown/no inventory).
function Inventory.GetItemCount(inv, item)
    if not adapter or not adapter.GetItemCount then return 0 end
    return adapter.GetItemCount(inv, item) or 0
end

function Inventory.RemoveItem(inv, item, count, metadata)
    if not adapter then return false end
    return adapter.RemoveItem(inv, item, count or 1, metadata)
end

function Inventory.ItemExists(item)
    if not adapter then return false end
    local ok, exists = pcall(adapter.ItemExists, item)
    return ok and exists or false
end

function Inventory.RegisterStash(id, label, slots, weight, coords)
    if not adapter then return end
    adapter.RegisterStash(id, label, slots, weight, coords)
end

function Inventory.ClearStash(id)
    if not adapter then return end
    adapter.ClearStash(id)
end

-- Pre-seeded stashes (a loot crate that is filled BEFORE anyone opens it) are only reliable on ox_inventory.
function Inventory.SupportsStash()
    return kind == 'ox'
end

-- What is still sitting in a stash: a list of { name, count }, or nil when this inventory cannot be asked.
function Inventory.GetStashItems(id)
    if kind ~= 'ox' then return nil end
    local ok, items = pcall(function() return exports.ox_inventory:GetInventoryItems(id) end)
    if not ok or type(items) ~= 'table' then return nil end
    local out = {}
    for _, it in pairs(items) do
        if type(it) == 'table' and it.name and (tonumber(it.count) or 0) > 0 then
            out[#out + 1] = { name = it.name, count = tonumber(it.count) }
        end
    end
    return out
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not kind then
        lib.print.warn('[NovaConvoy] No supported inventory resource detected (ox_inventory / qb-inventory / ps-inventory / qs-inventory). Item-based rewards and truck loot will silently no-op.')
    else
        print(('[NovaConvoy] Inventory bridge: using %s.'):format(kind))
    end
end)
