-- ─── Bridge Adapter: QB-Core (qb-core) ────────────────────────────────────────
-- Server-side only. Written against QB-Core's documented standard API.
-- NOTE: this server only has qbx_core installed, so this adapter is untested
-- here — it mirrors bridge/qbx.lua since QB-Core and Qbox share the same
-- PlayerData shape (job/gang = { name, label, grade = { name, level } }).

local QBCore = exports['qb-core']:GetCoreObject()

local M = {}

function M.GetPlayer(source)
    return QBCore.Functions.GetPlayer(source)
end

function M.GetIdentifier(source)
    local player = QBCore.Functions.GetPlayer(source)
    return player and player.PlayerData.citizenid or nil
end

function M.GetPlayerName(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return nil end
    local info = player.PlayerData.charinfo
    if not info then return nil end
    return ('%s %s'):format(info.firstname or '', info.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

function M.GetJobGrade(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or not player.PlayerData.job then return nil end
    local job = player.PlayerData.job
    return { name = job.name, label = job.label or job.name, grade = job.grade and job.grade.level or 0, onduty = job.onduty }
end

function M.GetPlayerGang(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or not player.PlayerData.gang then return nil end
    local gang = player.PlayerData.gang
    if gang.name == 'none' then return nil end
    return { name = gang.name, label = gang.label, grade = gang.grade and gang.grade.level or 0 }
end

function M.GetPlayers()
    return QBCore.Functions.GetPlayers()
end

function M.OnPlayerLoaded(callback)
    RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
        callback(source)
    end)
end

function M.RemoveMoney(source, amount, account, reason)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false end
    return player.Functions.RemoveMoney(account or 'cash', amount, reason or 'nova_convoytruck:equipment')
end

function M.AddMoney(source, amount, account, reason)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false end
    return player.Functions.AddMoney(account or 'cash', amount, reason or 'nova_convoytruck:reward')
end

-- Container Wars bidding checks funds through Bridge.GetMoney; without this the
-- QB-Core adapter reported 0 and every bid was refused.
function M.GetMoney(source, account)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return 0 end
    return player.Functions.GetMoney(account or 'cash') or 0
end

-- Standard QB-Core API. Usable items are a framework concept in the QB
-- ecosystem (QBCore.Functions.CreateUseableItem), not something the
-- inventory script itself exposes — qb-inventory/ps-inventory/qs-inventory
-- all delegate item-use back to the core the same way ox_inventory's own
-- qbx bridge does for Qbox (see bridge/qbx.lua).
function M.GetMoney(source, account)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return 0 end
    return player.Functions.GetMoney(account or 'cash') or 0
end

function M.RegisterUsableItem(item, callback)
    QBCore.Functions.CreateUseableItem(item, function(source)
        callback(source)
    end)
end

return M
