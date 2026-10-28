-- ─── Bridge Adapter: ESX (es_extended) ────────────────────────────────────────
-- Server-side only. Written against ESX's documented standard API.
-- NOTE: this server only has qbx_core installed, so this adapter is untested
-- here. ESX has no native gang concept, so GetPlayerGang always returns nil —
-- set Config.GangProvider = 'internal' (or 'custom') on ESX servers.

local ESX = exports.es_extended:getSharedObject()

local M = {}

function M.GetPlayer(source)
    return ESX.GetPlayerFromId(source)
end

function M.GetIdentifier(source)
    local player = ESX.GetPlayerFromId(source)
    return player and player.identifier or nil
end

function M.GetPlayerName(source)
    local player = ESX.GetPlayerFromId(source)
    if not player then return nil end
    if player.getName then return player.getName() end
    if player.variables then
        local full = ('%s %s'):format(player.variables.firstName or '', player.variables.lastName or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if full ~= '' then return full end
    end
    return nil
end

function M.GetJobGrade(source)
    local player = ESX.GetPlayerFromId(source)
    if not player or not player.job then return nil end
    -- Mainline esx_legacy's job.grade is a plain number, but some forks use a
    -- table ({level=..}/{grade=..}) instead — normalize either shape so the
    -- `jobGrade.grade >= minGrade` comparison in Bridge.HasCreatorAccess
    -- never ends up comparing a table to a number.
    local grade = player.job.grade
    if type(grade) == 'table' then grade = grade.level or grade.grade or 0 end
    return { name = player.job.name, label = player.job.label or player.job.name, grade = tonumber(grade) or 0 }
end

function M.GetPlayerGang(source)
    -- ESX has no built-in gang system.
    return nil
end

function M.GetPlayers()
    return ESX.GetPlayers()
end

function M.OnPlayerLoaded(callback)
    RegisterNetEvent('esx:playerLoaded', function(playerId)
        callback(playerId)
    end)
end

function M.RemoveMoney(source, amount, account)
    local player = ESX.GetPlayerFromId(source)
    if not player then return false end
    if account == 'bank' then
        local bank = player.getAccount('bank')
        if not bank or bank.money < amount then return false end
        player.removeAccountMoney('bank', amount)
        return true
    end
    if player.getMoney() < amount then return false end
    player.removeMoney(amount)
    return true
end

function M.GetMoney(source, account)
    local player = ESX.GetPlayerFromId(source)
    if not player then return 0 end
    if account == 'bank' then
        local bank = player.getAccount('bank')
        return bank and bank.money or 0
    end
    return player.getMoney() or 0
end

function M.AddMoney(source, amount, account, reason)
    local player = ESX.GetPlayerFromId(source)
    if not player then return false end
    if account == 'bank' then
        player.addAccountMoney('bank', amount, reason)
        return true
    end
    player.addMoney(amount)
    return true
end

-- Standard ESX Legacy API. Usable items are registered on the framework
-- (ESX.RegisterUsableItem), not on ox_inventory/qb-inventory/qs-inventory
-- themselves — same pattern as the QBX/QB-Core adapters.
function M.RegisterUsableItem(item, callback)
    ESX.RegisterUsableItem(item, function(source)
        callback(source)
    end)
end

return M
