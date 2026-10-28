-- ─── Custom Gang Provider Template ────────────────────────────────────────────
-- Only loaded when Config.GangProvider = 'custom' in config/config.lua.
--
-- Fill each function in below to point at your own gang resource's exports.
-- This is the ONLY file you need to touch to wire nova_convoytruck into a
-- third-party gang system — every other module talks to GangService, which
-- calls whatever is returned here.
--
-- Return value shapes must match server/modules/gang_service.lua's contract
-- (see the comment block at the top of that file).

local M = {}

function M.GetGangs()
    -- Example: return exports['your-gang-script']:GetAllGangs()
    error('bridge/gangs/custom.lua: GetGangs() is not implemented yet.')
end

function M.GetGangByName(name)
    error('bridge/gangs/custom.lua: GetGangByName() is not implemented yet.')
end

function M.GetPlayerGang(source)
    error('bridge/gangs/custom.lua: GetPlayerGang() is not implemented yet.')
end

function M.CreateGang(name, label, maxMembers)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.DeleteGang(gangId)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.UpdateGang(gangId, fields)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.AddMember(gangId, source, rank)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.RemoveMember(gangId, identifier)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.SetLeader(gangId, identifier)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.SetMemberRank(gangId, identifier, rank)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.RecordOutcome(gangName, outcome)
    -- no-op by default
end

-- Race tokens earned by a gang (Gang Rally leaderboard) — no-op by default.
function M.RecordTokens(gangName, amount)
end

-- TDM kills/deaths aggregated per gang (leaderboard) — no-op by default.
function M.RecordTdmStats(gangName, kills, deaths)
end

function M.SetLogo(gangId, logo)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.SetAccentColor(gangId, color)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

-- Role permissions (see GangService's InternalProvider for the full contract).
-- Return an empty map from GetRolePermissions rather than erroring — the server
-- calls it on every access check, and a hard error there would break the whole
-- panel instead of just disabling delegation for this provider.
function M.GetRolePermissions(gangId)
    return {}
end

function M.SetRolePermission(gangId, rank, permission, enabled)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.ClearRolePermissions(gangId, rank)
    return false, 'Not implemented: bridge/gangs/custom.lua'
end

function M.RoleHasPermission(gangId, rank, permission)
    return false
end

return M
