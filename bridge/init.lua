-- ─── Nova Convoy — Framework Bridge ───────────────────────────────────────────
-- Every other module talks to "Bridge", never to a framework export directly.
-- This is the ONLY file (plus its per-framework adapters) that is allowed to
-- know qbx_core/qb-core/es_extended exist. Detection runs once, on whichever
-- side requires this file first.
--
-- Adapter contract (each bridge/<name>.lua must return a table implementing):
--   GetPlayer(source)            -> opaque player handle or nil
--   GetIdentifier(source)        -> string unique id (citizenid / esx identifier)
--   GetPlayerName(source)        -> string display name
--   GetJobGrade(source)          -> { name = string, grade = number } or nil
--   GetPlayerGang(source)        -> { name = string, label = string, grade = number } or nil (nil if framework has no gang concept)
--   GetPlayers()                 -> array of online player sources
--   OnPlayerLoaded(callback)     -> registers callback(source) fired once a player finishes loading
--   RemoveMoney(source, amount, account[, reason]) -> boolean ok (account: 'cash' | 'bank')
--   AddMoney(source, amount, account[, reason])    -> boolean ok
--   (Bank-account calls made through Bridge.* are routed via bridge/banking.lua,
--   which calls these for the framework-held balance.)
--   RegisterUsableItem(item, callback)   -> registers callback(source) fired when a player uses that
--                                            item — a framework-level concept (QBX.UsableItems /
--                                            QBCore.Functions.CreateUseableItem / ESX.RegisterUsableItem),
--                                            NOT an inventory one; ox_inventory/qb-inventory/qs-inventory
--                                            all delegate item-use back to whichever of these is active.

local function detectFramework()
    if GetResourceState('qbx_core') == 'started' then return 'qbx' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return nil
end

local frameworkName = detectFramework()
local adapter = nil

if frameworkName then
    local ok, mod = pcall(require, 'bridge.' .. frameworkName)
    if ok then
        adapter = mod
    else
        lib.print.error(('[nova_convoytruck] Failed to load bridge adapter for "%s": %s'):format(frameworkName, tostring(mod)))
    end
else
    lib.print.warn('[nova_convoytruck] No supported framework detected (qbx_core / qb-core / es_extended). Player/job/gang lookups will be unavailable.')
end

Bridge = {}
Bridge.Framework = frameworkName

function Bridge.GetPlayer(source)
    if not adapter then return nil end
    return adapter.GetPlayer(source)
end

function Bridge.GetIdentifier(source)
    if not adapter then return nil end
    return adapter.GetIdentifier(source)
end

-- The name shown for a player everywhere (tablets, HUD, reports, logs): the in-game CHARACTER name only. The cfx/Steam
-- account name used to be appended in brackets; it is deliberately left out now.
function Bridge.GetPlayerName(source)
    return Bridge.GetCharacterName(source)
end

-- In-game character name ONLY (falls back to the account name when no character is loaded).
function Bridge.GetCharacterName(source)
    local charName = adapter and adapter.GetPlayerName(source) or nil
    if charName and charName ~= '' then return charName end
    local accountName = GetPlayerName(source)
    if accountName and accountName ~= '' then return accountName end
    return ('Unknown (%s)'):format(tostring(source))
end

-- Drops the " (account name)" that older rows have stored after the character name, so they display cleanly too. A
-- bracketed citizen id (8 capital letters / digits, e.g. "(H8R5Z9G3)") is kept; every other bracket is removed.
function Bridge.StripAccountName(name)
    if type(name) ~= 'string' then return name end
    local stripped = name:gsub('%s*%(([^()]*)%)', function(inner)
        if #inner == 8 and inner:match('^[A-Z0-9]+$') then return nil end
        return ''
    end)
    stripped = stripped:gsub('^%s+', ''):gsub('%s+$', '')
    return stripped ~= '' and stripped or name
end

function Bridge.GetJobGrade(source)
    if not adapter then return nil end
    return adapter.GetJobGrade(source)
end

function Bridge.GetPlayerJob(source)
    if not adapter then return nil end
    local jg = adapter.GetJobGrade(source)
    if not jg then return nil end
    return jg.label or jg.name
end

function Bridge.GetPlayerGang(source)
    if not adapter then return nil end
    return adapter.GetPlayerGang(source)
end

function Bridge.GetPlayers()
    if not adapter then return {} end
    return adapter.GetPlayers()
end

function Bridge.OnPlayerLoaded(callback)
    if not adapter then return end
    adapter.OnPlayerLoaded(callback)
end

-- Framework-only money operations. The banking bridge (bridge/banking.lua)
-- uses these for the framework-held part of a bank payout; nothing else should.
Bridge.RawMoney = {}

function Bridge.RawMoney.Add(source, amount, account, reason)
    if not adapter then return false end
    return adapter.AddMoney(source, amount, account or 'cash', reason)
end

function Bridge.RawMoney.Remove(source, amount, account, reason)
    if not adapter then return false end
    return adapter.RemoveMoney(source, amount, account or 'cash', reason)
end

function Bridge.RawMoney.Get(source, account)
    if not adapter then return 0 end
    if adapter.GetMoney then
        return adapter.GetMoney(source, account or 'cash')
    end
    return 0
end

-- Public money API used by the whole resource. Bank money is delegated to the
-- banking bridge so any banking script can be supported in one place; cash and
-- black money go straight to the framework.
function Bridge.RemoveMoney(source, amount, account)
    if account == 'bank' and Banking then return Banking.Withdraw(source, amount) end
    return Bridge.RawMoney.Remove(source, amount, account)
end

function Bridge.AddMoney(source, amount, account)
    if account == 'bank' and Banking then return Banking.Deposit(source, amount) end
    return Bridge.RawMoney.Add(source, amount, account)
end

function Bridge.GetMoney(source, account)
    if account == 'bank' and Banking then return Banking.GetBalance(source) end
    return Bridge.RawMoney.Get(source, account)
end

function Bridge.RegisterUsableItem(item, callback)
    if not adapter then
        lib.print.warn(('[NovaConvoy] No framework detected — cannot register usable item "%s".'):format(tostring(item)))
        return
    end
    adapter.RegisterUsableItem(item, callback)
end

-- ACE permissions are a native FiveM concept, not framework-specific, so admin
-- checks don't need a per-framework adapter. Config.CreatorAccess.adminIdentifiers
-- is a belt-and-suspenders path for servers where server.cfg's ACE
-- add_principal lines aren't reliably granting the permission — see config.lua.
function Bridge.IsAdmin(source, permission)
    if not source then return false end
    local srcStr = tostring(source)
    local perm = permission or (Config.CreatorAccess and Config.CreatorAccess.adminPermission) or 'admin'

    -- Check ACE permissions (including common admin aliases)
    if IsPlayerAceAllowed(srcStr, perm)
        or IsPlayerAceAllowed(srcStr, 'admin')
        or IsPlayerAceAllowed(srcStr, 'god')
        or IsPlayerAceAllowed(srcStr, 'event.admin')
        or IsPlayerAceAllowed(srcStr, 'command') then
        return true
    end

    -- Framework-specific admin check (e.g. qbx_core HasPermission)
    if adapter and adapter.HasPermission then
        if adapter.HasPermission(source, perm) or adapter.HasPermission(source, 'admin') or adapter.HasPermission(source, 'god') then
            return true
        end
    elseif exports.qbx_core and exports.qbx_core.HasPermission then
        local ok, hasPerm = pcall(function()
            return exports.qbx_core:HasPermission(source, perm) or exports.qbx_core:HasPermission(source, 'admin') or exports.qbx_core:HasPermission(source, 'god')
        end)
        if ok and hasPerm then return true end
    end

    -- Specific player identifiers allowlist
    local allowlist = Config.CreatorAccess and Config.CreatorAccess.adminIdentifiers
    if allowlist and #allowlist > 0 then
        local playerIds = GetPlayerIdentifiers(srcStr)
        for _, rawId in ipairs(playerIds) do
            local idLower = string.lower(rawId)
            for _, allowed in ipairs(allowlist) do
                local allowLower = string.lower(allowed)
                if idLower == allowLower or idLower:find(allowLower, 1, true) or allowLower:find(idLower, 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

-- Combines Config.CreatorAccess (job/grade map + admin ACE) into a single check.
-- Used both to gate opening the tablet and to re-validate every write action.
function Bridge.HasCreatorAccess(source)
    local access = Config.CreatorAccess
    if not access then return false end

    if access.admin and Bridge.IsAdmin(source, access.adminPermission) then
        return true
    end

    if access.jobs then
        local jobGrade = Bridge.GetJobGrade(source)
        if jobGrade then
            local minGrade = access.jobs[jobGrade.name]
            if minGrade and jobGrade.grade >= minGrade then
                return true
            end
        end
    end

    -- Granular Staff / User Management permissions
    if UserPermissions and UserPermissions.hasAnyPermission and UserPermissions.hasAnyPermission(source) then
        return true
    end

    return false
end

-- Gameplay notion of "police" (for participant counts / who may complete a
-- delivery) — any job listed in Config.CreatorAccess.jobs, regardless of
-- grade. Deliberately separate from HasCreatorAccess, which also checks grade
-- and admin ACE for tablet access specifically.
function Bridge.IsPolice(source)
    local access = Config.CreatorAccess
    if not access or not access.jobs then return false end
    local jobGrade = Bridge.GetJobGrade(source)
    return jobGrade ~= nil and access.jobs[jobGrade.name] ~= nil
end

-- A police job AND on duty (qbx / qbcore job.onduty). A framework without a duty flag (ESX) counts as on duty.
-- Any government job (Config.StatusPanel.govJobs + every police job in Config.CreatorAccess.jobs) while ON DUTY.
function Bridge.IsGovOnDuty(source)
    local jobGrade = Bridge.GetJobGrade(source)
    if not jobGrade or jobGrade.onduty == false then return false end
    local access = Config.CreatorAccess
    if access and access.jobs and access.jobs[jobGrade.name] ~= nil then return true end
    for _, name in ipairs((Config.StatusPanel and Config.StatusPanel.govJobs) or {}) do
        if name == jobGrade.name then return true end
    end
    return false
end

function Bridge.IsPoliceOnDuty(source)
    if not Bridge.IsPolice(source) then return false end
    local jobGrade = Bridge.GetJobGrade(source)
    return jobGrade ~= nil and jobGrade.onduty ~= false
end
