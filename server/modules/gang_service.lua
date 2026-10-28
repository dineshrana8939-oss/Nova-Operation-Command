-- ─── Nova Convoy — Gang Service ───────────────────────────────────────────────
-- Server-only. Single interface the rest of the resource talks to for anything
-- gang-related. Backed by a pluggable provider selected via Config.GangProvider:
--   'internal'  -> standalone DB-backed gangs managed from the tablet (default)
--   'framework' -> reads the framework's native job/gang groups (Qbox/QB-Core)
--   'custom'    -> delegates to bridge/gangs/custom.lua for a third-party gang resource
--
-- Contract (all providers implement this shape):
--   GetGangs()                              -> array of { id, name, label, leaderIdentifier, maxMembers, canParticipate, members = { {identifier, name, rank} }, stats }
--   GetGangByName(name)                     -> single gang or nil
--   GetPlayerGang(source)                   -> { id, name, label, rank } or nil
--   CreateGang(name, label, maxMembers)     -> ok, gangOrError
--   DeleteGang(gangId)                      -> ok, error
--   UpdateGang(gangId, fields)              -> ok, error
--   AddMember(gangId, source, rank)         -> ok, error
--   RemoveMember(gangId, identifier)        -> ok, error
--   SetLeader(gangId, identifier)           -> ok, error
--   SetMemberRank(gangId, identifier, rank) -> ok, error
--   RecordOutcome(gangName, outcome, kind)  -> updates joined/captured/failed counters for
--                                               kind ('CONVOY' default | 'HOT_CARGO' | 'GANG_AIRDROP' | 'GANG_RACE' | 'TDM')
--   SetLogo(gangId, logo)                   -> ok, error (logo is a data: URL or external image URL, or nil to clear)
--   SetAccentColor(gangId, color)           -> ok, error (hex string, or nil to clear)

GangService = {}

local provider = nil

-- ── Internal provider (default) ──────────────────────────────────────────────────
local function InternalProvider()
    local P = {}

    -- ── read cache ───────────────────────────────────────────────────────────────
    -- GetGangs / GetGangByName / GetPlayerGang / the role permissions are asked for by almost every tablet call, every territory view
    -- and every permission check, and each used to be a database read (the gang list alone is two). They are now answered from memory
    -- for a few seconds and the cache is dropped the moment anything in here changes a gang, a member, a role or a stat (bust()), so a
    -- change made through this script is visible at once; only an edit made straight in the database waits up to the TTL.
    local TTL_MS = 8000
    local cache = { gangs = nil, gangsAt = 0, byName = {}, member = {}, memberN = 0, perms = {} }
    local function fresh(at) return at and (GetGameTimer() - at) < TTL_MS end
    local function bust() cache = { gangs = nil, gangsAt = 0, byName = {}, member = {}, memberN = 0, perms = {} } end

    local function gangRows()
        if cache.gangs and fresh(cache.gangsAt) then return cache.gangs end
        cache.gangs, cache.gangsAt = DB.getAllGangs(), GetGameTimer()
        return cache.gangs
    end
    local function gangRow(name)
        local c = cache.byName[name]
        if c and fresh(c.at) then return c.row or nil end
        local row = DB.getGangByName(name)
        cache.byName[name] = { row = row or false, at = GetGameTimer() }
        return row
    end
    local function memberRow(identifier)
        local c = cache.member[identifier]
        if c and fresh(c.at) then return c.row or nil end
        local row = DB.getGangMember(identifier)
        if cache.memberN > 300 then cache.member, cache.memberN = {}, 0 end   -- a long-running server: forget old players
        if not c then cache.memberN = cache.memberN + 1 end
        cache.member[identifier] = { row = row or false, at = GetGameTimer() }
        return row
    end
    local function permsOf(gangId)   -- read-only view; the writers below read straight from the database
        local c = cache.perms[gangId]
        if c and fresh(c.at) then return c.perms end
        local perms = DB.getGangRolePermissions(gangId) or {}
        cache.perms[gangId] = { perms = perms, at = GetGameTimer() }
        return perms
    end

    function P.GetGangs()
        local rows = gangRows()
        local gangs = {}
        for i, row in ipairs(rows) do
            gangs[i] = {
                id = row.id,
                name = row.name,
                label = row.label,
                leaderIdentifier = row.leader_identifier,
                canParticipate = row.can_participate == 1 or row.can_participate == true,
                members = row.members or {},
                logo = row.logo,
                accentColor = row.accent_color,
                -- Broken out per event kind — CONVOY/HOT_CARGO/GANG_AIRDROP
                -- are three genuinely different games (roster-based escort vs.
                -- open-participation hijack vs. open-participation loot race),
                -- so one combined captured/failed count was really just the
                -- CONVOY numbers with the other two kinds silently never
                -- contributing anything at all. convoysJoined/Captured/Failed
                -- kept at the top level too, unchanged, for anything that
                -- still reads the old flat shape.
                stats = {
                    convoysJoined = row.convoys_joined,
                    convoysCaptured = row.convoys_captured,
                    convoysFailed = row.convoys_failed,
                    CONVOY = { joined = row.convoys_joined or 0, captured = row.convoys_captured or 0, failed = row.convoys_failed or 0 },
                    HOT_CARGO = { completed = row.hotcargo_completed or 0, failed = row.hotcargo_failed or 0 },
                    GANG_AIRDROP = { completed = row.airdrop_completed or 0, failed = row.airdrop_failed or 0 },
                    GANG_RACE = { completed = row.rally_completed or 0, wins = row.rally_wins or 0, tokens = row.rally_tokens or 0, failed = row.rally_failed or 0, joined = row.rally_joined or 0 },
                    TDM = {
                        wins = row.tdm_wins or 0, losses = row.tdm_losses or 0, matches = row.tdm_matches or 0,
                        kills = row.tdm_kills or 0, deaths = row.tdm_deaths or 0,
                        tournamentWins = row.tdm_tournament_wins or 0, tournamentPlayed = row.tdm_tournament_played or 0,
                    },
                    CONTAINER_WARS = {
                        joined = row.containerwars_joined or 0,
                        completed = row.containerwars_completed or 0,
                        failed = row.containerwars_failed or 0,
                        wins = row.containerwars_won or 0,
                        winningBids = row.containerwars_won or 0,
                        totalSpend = row.containerwars_spend or 0,
                    },
                },
            }
        end
        return gangs
    end

    function P.GetGangByName(name)
        local row = gangRow(name)
        if not row then return nil end
        return { id = row.id, name = row.name, label = row.label, leaderIdentifier = row.leader_identifier, maxMembers = row.max_members, logo = row.logo, accentColor = row.accent_color }
    end

    function P.GetPlayerGang(source)
        local identifier = Bridge.GetIdentifier(source)
        if not identifier then return nil end
        local row = memberRow(identifier)
        if not row then return nil end
        return { id = row.gang_id, name = row.gang_name, label = row.gang_label, rank = row.rank, logo = row.gang_logo, accentColor = row.gang_accent_color }
    end

    -- ── Role permissions ─────────────────────────────────────────────────────
    -- A gang's roles are simply the distinct rank strings on its members — the
    -- leader already assigns those via SetMemberRank (see the tablet's Gang
    -- Management screen), so inventing a second parallel "role list" would let
    -- a role exist with no members and a rank exist with no permissions. The
    -- permission map is keyed BY rank name for exactly that reason.
    --
    -- Permissions:
    --   manageGang      — add/remove/promote members, edit gang settings
    --   registerRoster  — sign the gang up for events on the leader's behalf
    -- The leader implicitly holds both and cannot be locked out of them.
    -- Only permissions something actually checks. The old list also carried
    -- viewEvents/createEvents/editEvents/... which no code path ever read, so
    -- toggling them looked like it worked and did nothing.
    local VALID_PERMISSIONS = {
        manageGang = true,
        registerRoster = true,
    }

    -- Returns only the live permissions: stale keys saved under the old, longer
    -- list are dropped on read so they can never resurface in the UI.
    function P.GetRolePermissions(gangId)
        local stored = permsOf(gangId)
        local clean = {}
        for rank, perms in pairs(stored) do
            clean[rank] = {}
            for key in pairs(VALID_PERMISSIONS) do
                if perms[key] ~= nil then clean[rank][key] = perms[key] == true end
            end
        end
        return clean
    end

    function P.SetRolePermission(gangId, rank, permission, enabled)
        if type(rank) ~= 'string' or rank == '' then return false, 'A role name is required.' end
        if not VALID_PERMISSIONS[permission] then
            return false, 'Unknown permission.'
        end
        local perms = DB.getGangRolePermissions(gangId) or {}
        perms[rank] = perms[rank] or {}
        perms[rank][permission] = enabled and true or false
        DB.setGangRolePermissions(gangId, perms)
        bust()
        return true
    end

    function P.SetRolePermissions(gangId, rank, permissionsTable)
        if type(rank) ~= 'string' or rank == '' then return false, 'A role name is required.' end
        local perms = DB.getGangRolePermissions(gangId) or {}
        perms[rank] = perms[rank] or {}
        for perm, _ in pairs(VALID_PERMISSIONS) do
            if permissionsTable[perm] ~= nil then
                perms[rank][perm] = permissionsTable[perm] and true or false
            end
        end
        DB.setGangRolePermissions(gangId, perms)
        bust()
        return true
    end

    function P.RenameRole(gangId, oldRank, newRank)
        if type(oldRank) ~= 'string' or oldRank == '' then return false, 'Current role name required.' end
        if type(newRank) ~= 'string' or newRank == '' then return false, 'New role name required.' end
        if oldRank == newRank then return true end

        local perms = DB.getGangRolePermissions(gangId) or {}
        if perms[oldRank] then
            perms[newRank] = perms[oldRank]
            perms[oldRank] = nil
            DB.setGangRolePermissions(gangId, perms)
        end

        MySQL.update.await('UPDATE nova_gang_members SET rank = ? WHERE gang_id = ? AND rank = ?', { newRank, gangId, oldRank })
        bust()
        return true
    end

    function P.DeleteRole(gangId, rank)
        if type(rank) ~= 'string' or rank == '' then return false, 'Role name required.' end
        local perms = DB.getGangRolePermissions(gangId) or {}
        perms[rank] = nil
        DB.setGangRolePermissions(gangId, perms)
        MySQL.update.await('UPDATE nova_gang_members SET rank = ? WHERE gang_id = ? AND rank = ?', { 'Member', gangId, rank })
        bust()
        return true
    end

    -- Drops a role's permissions entirely — called when the last member holding
    -- that rank is removed/renamed, so a deleted role can't leave a stale grant
    -- behind that a future member of the same name would silently inherit.
    function P.ClearRolePermissions(gangId, rank)
        if type(rank) ~= 'string' or rank == '' then return false end
        local perms = DB.getGangRolePermissions(gangId)
        if perms[rank] == nil then return true end
        perms[rank] = nil
        DB.setGangRolePermissions(gangId, perms)
        bust()
        return true
    end

    -- True when the gang has AT LEAST ONE non-leader role holding this
    -- permission — used by the UI to decide whether the feature is worth
    -- surfacing, and by the server as a cheap pre-check.
    function P.RoleHasPermission(gangId, rank, permission)
        if type(rank) ~= 'string' or rank == '' then return false end
        local perms = permsOf(gangId)
        local entry = perms[rank]
        return entry ~= nil and entry[permission] == true
    end

    function P.CreateGang(name, label, maxMembers)
        if DB.getGangByName(name) then return false, 'A gang with that name already exists.' end
        local id = DB.createGang(name, label, maxMembers)
        bust()
        return true, { id = id, name = name, label = label }
    end

    function P.DeleteGang(gangId)
        DB.deleteGang(gangId)
        bust()
        return true
    end

    function P.UpdateGang(gangId, fields)
        local ok, err = DB.updateGang(gangId, fields)
        bust()
        if not ok then return false, 'Failed to save gang settings — check server console.' end
        if Territory and Territory.refreshOwnerLook then Territory.refreshOwnerLook() end   -- its territories change colour / name on every tablet
        return true
    end

    function P.AddMember(gangId, source, rank)
        local identifier = Bridge.GetIdentifier(source)
        if not identifier then return false, 'Player identifier unavailable.' end
        if DB.getGangMember(identifier) then return false, 'Player is already in a gang.' end
        DB.addGangMember(gangId, identifier, Bridge.GetPlayerName(source), rank)
        bust()
        return true
    end

    function P.RemoveMember(gangId, identifier)
        DB.removeGangMember(gangId, identifier)
        bust()
        return true
    end

    function P.SetLeader(gangId, identifier)
        DB.setGangLeader(gangId, identifier)
        bust()
        return true
    end

    function P.SetMemberRank(gangId, identifier, rank)
        DB.setGangMemberRank(gangId, identifier, rank)
        bust()
        return true
    end

    -- outcome: 'joined' | 'captured' | 'failed'. kind: 'CONVOY' (default) |
    -- 'HOT_CARGO' | 'GANG_AIRDROP' | 'GANG_RACE' | 'TDM' — picks which
    -- per-event-kind column set gets incremented.
    function P.RecordOutcome(gangName, outcome, kind)
        local row = gangRow(gangName)
        if not row then return end
        local column
        if kind == 'HOT_CARGO' then
            column = outcome == 'failed' and 'hotcargo_failed' or (outcome == 'captured' and 'hotcargo_completed' or nil)
        elseif kind == 'GANG_AIRDROP' then
            column = outcome == 'failed' and 'airdrop_failed' or (outcome == 'captured' and 'airdrop_completed' or nil)
        elseif kind == 'GANG_RACE' then
            -- 'completed' = the gang FINISHED the race, 'won' = a racer took 1st,
            -- 'failed' = entered but nobody finished, 'joined' = entered.
            column = ({ failed = 'rally_failed', completed = 'rally_completed', won = 'rally_wins', joined = 'rally_joined' })[outcome]
        elseif kind == 'TDM' then
            -- 'won'/'lost' = a Standard match (or one bracket matchup) decided,
            -- 'played' = the gang took part in a match regardless of outcome,
            -- 'tournamentWon'/'tournamentPlayed' = the tournament as a whole,
            -- tracked separately since a gang can win/lose Standard matches
            -- without ever entering a tournament.
            column = ({ won = 'tdm_wins', lost = 'tdm_losses', played = 'tdm_matches', tournamentWon = 'tdm_tournament_wins', tournamentPlayed = 'tdm_tournament_played' })[outcome]
        elseif kind == 'CONTAINER_WARS' then
            column = ({ won = 'containerwars_won', joined = 'containerwars_joined', captured = 'containerwars_completed', completed = 'containerwars_completed', failed = 'containerwars_failed' })[outcome]
        else
            column = outcome == 'captured' and 'convoys_captured' or (outcome == 'failed' and 'convoys_failed' or 'convoys_joined')
        end
        if not column then return end
        MySQL.update.await(('UPDATE nova_gangs SET %s = %s + 1 WHERE id = ?'):format(column, column), { row.id })
        bust()
    end

    -- Race tokens a gang earned by finishing position (Gang Rally leaderboard).
    function P.RecordTokens(gangName, amount)
        amount = math.floor(tonumber(amount) or 0)
        if amount <= 0 then return end
        local row = gangRow(gangName)
        if not row then return end
        MySQL.update.await('UPDATE nova_gangs SET rally_tokens = rally_tokens + ? WHERE id = ?', { amount, row.id })
        bust()
    end

    -- Container Wars winning bid & spend (Container Wars gang bidding leaderboard).
    function P.RecordContainerWarsWin(gangName, finalBid)
        if TestRun and TestRun.admin then return end
        finalBid = math.floor(tonumber(finalBid) or 0)
        local row = gangRow(gangName)
        if not row then return end
        MySQL.update.await([[
            UPDATE nova_gangs 
            SET containerwars_won = containerwars_won + 1,
                containerwars_spend = containerwars_spend + ?
            WHERE id = ?
        ]], { finalBid, row.id })
        bust()
    end

    -- TDM kills/deaths aggregated across every match a gang's members played
    -- in — a bulk per-match increment, unlike RecordOutcome's fixed +1 (a
    -- gang can rack up many kills/deaths in one single match).
    function P.RecordTdmStats(gangName, kills, deaths)
        kills = math.floor(tonumber(kills) or 0)
        deaths = math.floor(tonumber(deaths) or 0)
        if kills <= 0 and deaths <= 0 then return end
        local row = gangRow(gangName)
        if not row then return end
        MySQL.update.await('UPDATE nova_gangs SET tdm_kills = tdm_kills + ?, tdm_deaths = tdm_deaths + ? WHERE id = ?', { kills, deaths, row.id })
        bust()
    end

    -- Dedicated setters (rather than routing through UpdateGang's fixed-column
    -- fields object) so a logo/color change never has to carry the rest of the
    -- gang's settings along with it, and can never accidentally clobber them.
    function P.SetLogo(gangId, logo)
        DB.setGangLogo(gangId, logo)
        bust()
        if Territory and Territory.refreshOwnerLook then Territory.refreshOwnerLook() end
        return true
    end

    function P.SetAccentColor(gangId, color)
        DB.setGangAccentColor(gangId, color)
        bust()
        if Territory and Territory.refreshOwnerLook then Territory.refreshOwnerLook() end
        return true
    end

    return P
end
-- ── Framework provider (Qbox / QB-Core native gang groups) ────────────────────────
local function FrameworkProvider()
    local P = {}

    function P.GetGangs()
        lib.print.warn('[nova_convoytruck] GangProvider "framework" only exposes gang membership, not roster management. Use the tablet to view participation only.')
        return {}
    end

    function P.GetGangByName(name) return nil end

    function P.GetPlayerGang(source)
        local gang = Bridge.GetPlayerGang(source)
        if not gang then return nil end
        return { id = gang.name, name = gang.name, label = gang.label, rank = gang.grade }
    end

    function P.CreateGang() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.DeleteGang() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.UpdateGang() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.AddMember() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.RemoveMember() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.SetLeader() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.SetMemberRank() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.RecordOutcome() end
    function P.RecordTokens() end
    function P.RecordTdmStats() end
    function P.SetLogo() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.SetAccentColor() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    -- Framework gangs have no tablet-managed roles — their ranks are the
    -- framework's own job grades, which this resource must not write to.
    function P.GetRolePermissions() return {} end
    function P.SetRolePermission() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.ClearRolePermissions() return false end
    function P.RoleHasPermission() return false end
    -- the tablet calls these on whatever provider is active; framework gangs have no tablet-managed roles or container-wars stats
    function P.SetRolePermissions() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.RenameRole() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.DeleteRole() return false, 'Framework gangs are managed in the framework config, not this tablet.' end
    function P.RecordContainerWarsWin() end

    return P
end

function GangService.init()
    local mode = Config.GangProvider
    if mode == 'framework' then
        if Bridge.Framework == 'esx' then
            lib.print.warn('[nova_convoytruck] Config.GangProvider is "framework" but ESX has no native gang system. Falling back to "internal".')
            provider = InternalProvider()
        else
            provider = FrameworkProvider()
        end
    elseif mode == 'custom' then
        local ok, custom = pcall(require, 'bridge.gangs.custom')
        if ok and custom then
            provider = custom
        else
            lib.print.error('[nova_convoytruck] Config.GangProvider is "custom" but bridge/gangs/custom.lua could not be loaded. Falling back to "internal".')
            provider = InternalProvider()
        end
    else
        provider = InternalProvider()
    end
end

-- ── Central permission resolver ─────────────────────────────────────────────────
-- The single place that answers "may this player do X in their gang?". Every
-- gate in the resource calls this rather than re-deriving leadership, so the
-- leader-granted custom roles can't be bypassed from a code path that only
-- checked isLeader.
--
-- Rules:
--   • the gang LEADER always has every permission
--   • anyone else gets exactly what their RANK grants them
--   • no gang → no permissions
--
-- This is deliberately independent of admin ACE: an admin moderating another
-- gang is a different question (handled at the tablet level), not a gang role.
function GangService.HasPermission(source, permission)
    if not provider then GangService.init() end
    local gang = provider.GetPlayerGang(source)
    if not gang then return false end
    -- a gang member working as on-duty government (police / EMS / ...) holds no gang rights until they are off duty
    if Bridge.IsGovOnDuty(source) and not Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission) then return false end

    local identifier = Bridge.GetIdentifier(source)
    local isLeader = false
    for _, g in ipairs(provider.GetGangs()) do
        if g.name == gang.name then
            isLeader = (g.leaderIdentifier ~= nil and g.leaderIdentifier == identifier)
            break
        end
    end
    if isLeader then return true end

    return provider.RoleHasPermission(gang.id, gang.rank, permission) == true
end

-- Resolves just the caller's role context, for the UI to render against.
-- Returns { gangId, gangName, rank, isLeader, canManageGang, canRegisterRoster }.
function GangService.GetPermissionContext(source, isAdmin)
    if not provider then GangService.init() end
    local gang = provider.GetPlayerGang(source)
    if not gang then
        return { gangId = nil, gangName = nil, rank = nil, isLeader = false, canManageGang = isAdmin or false, canRegisterRoster = isAdmin or false }
    end
    if Bridge.IsGovOnDuty(source) and not isAdmin then
        return { gangId = gang.id, gangName = gang.name, gangRank = gang.rank, isLeader = false, canManageGang = false, canRegisterRoster = false, govOnDuty = true }
    end

    local identifier = Bridge.GetIdentifier(source)
    local isLeader = false
    for _, g in ipairs(provider.GetGangs()) do
        if g.name == gang.name then
            isLeader = (g.leaderIdentifier ~= nil and g.leaderIdentifier == identifier)
            break
        end
    end

    local perms = provider.GetRolePermissions(gang.id) or {}
    local rolePerms = perms[gang.rank] or {}

    return {
        gangId = gang.id,
        gangName = gang.name,
        gangRank = gang.rank,
        isLeader = isLeader,
        canManageGang = isLeader or rolePerms.manageGang == true,
        canRegisterRoster = isLeader or rolePerms.registerRoster == true,
    }
end

setmetatable(GangService, {
    __index = function(_, key)
        return function(...)
            if not provider then GangService.init() end
            return provider[key](...)
        end
    end
})

return GangService
