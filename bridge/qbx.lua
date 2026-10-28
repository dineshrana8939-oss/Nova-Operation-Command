-- ─── Bridge Adapter: Qbox (qbx_core) ──────────────────────────────────────────
-- Server-side only. See bridge/init.lua for the adapter contract.

local QBX = exports.qbx_core

local M = {}

function M.GetPlayer(source)
    return QBX:GetPlayer(source)
end

function M.GetIdentifier(source)
    local player = QBX:GetPlayer(source)
    return player and player.PlayerData.citizenid or nil
end

function M.GetPlayerName(source)
    local player = QBX:GetPlayer(source)
    if not player then return nil end
    local info = player.PlayerData.charinfo
    if not info then return nil end
    local name = ('%s %s'):format(info.firstname or '', info.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    -- Blank charinfo (character mid-creation, or a test account with no
    -- first/last name set) must fall through to Bridge.GetPlayerName's own
    -- fallback below, not return an empty string that displays as nothing.
    if name == '' then return nil end
    return name
end

function M.GetJobGrade(source)
    local player = QBX:GetPlayer(source)
    if not player or not player.PlayerData.job then return nil end
    local job = player.PlayerData.job
    return { name = job.name, label = job.label or job.name, grade = job.grade and job.grade.level or 0, onduty = job.onduty }
end

function M.GetPlayerGang(source)
    local player = QBX:GetPlayer(source)
    if not player or not player.PlayerData.gang then return nil end
    local gang = player.PlayerData.gang
    if gang.name == 'none' then return nil end
    return { name = gang.name, label = gang.label, grade = gang.grade and gang.grade.level or 0 }
end

function M.GetPlayers()
    local sources = {}
    for src in pairs(QBX:GetQBPlayers()) do
        sources[#sources + 1] = src
    end
    return sources
end

function M.OnPlayerLoaded(callback)
    RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
        callback(source)
    end)
end

function M.RemoveMoney(source, amount, account, reason)
    local player = QBX:GetPlayer(source)
    if not player then return false end
    return player.Functions.RemoveMoney(account or 'cash', amount, reason or 'nova_convoytruck:equipment')
end

function M.AddMoney(source, amount, account, reason)
    local player = QBX:GetPlayer(source)
    if not player then return false end
    return player.Functions.AddMoney(account or 'cash', amount, reason or 'nova_convoytruck:reward')
end

function M.GetMoney(source, account)
    local player = QBX:GetPlayer(source)
    if not player then return 0 end
    return player.Functions.GetMoney(account or 'cash') or 0
end

-- Verified against the actual installed qbx_core (server/functions.lua):
-- exports('CreateUseableItem', ...) stores the callback in QBX.UsableItems,
-- and ox_inventory's own qbx bridge (modules/bridge/qbx/server.lua) already
-- delegates item-use to exports.qbx_core:CanUseItem() — so this is the
-- correct hook point regardless of which inventory script is installed on a
-- QBX server, not something ox_inventory/qb-inventory/qs-inventory expose themselves.
function M.RegisterUsableItem(item, callback)
    QBX:CreateUseableItem(item, function(source)
        callback(source)
    end)
end

function M.HasPermission(source, permission)
    local ok, res = pcall(function()
        return QBX:HasPermission(source, permission)
    end)
    return ok and res or false
end

return M
