-- ─── Nova Convoy — Territory callbacks (tablet ↔ server) ───────────────────────
-- Server-only. Everything the admin tablet (Territory Control, the Rivals tab) and the gang tablet (Event Status →
-- Territory) ask of the server. Every callback decides for itself who the caller is: admin = Bridge.IsAdmin, gang = the
-- player's own gang resolved server-side (GangXP.GangOf). Nothing here believes a gang name, an owner or a price a
-- client sends — they are only ever used as lookup keys and are re-checked.

local function denied()
    return { ok = false, error = 'You are not authorized to do that.' }
end

-- The admin VIEW of the map / rivals / XP board (everything about every gang): needs one of the territory tablet sections.
-- Each admin ACTION below checks its own permission key. A player's gang membership never grants or removes this.
local function isAdmin(src)
    return UserPermissions.canAny(src, 'mapzone.view', 'territories.view', 'rivals.view') == true
end

local function can(src, key) return UserPermissions.can(src, key) == true end

-- admin, or a member of a real gang (police only if they are a gang member too — same rule as the Event Status panel)
local function caller(src)
    local admin = isAdmin(src)
    local gang = GangXP.GangOf(src, true, true)
    if not admin and not gang then return nil end
    return admin, gang
end

local function gangDirectory()
    local out = {}
    for _, g in ipairs(GangService.GetGangs() or {}) do
        out[#out + 1] = { name = g.name, label = g.label or g.name, logo = g.logo, color = g.accentColor }
    end
    return out
end

local function meFor(src, gang)
    if not gang then return nil end
    local info = GangService.GetGangByName and GangService.GetGangByName(gang.name) or nil
    return {
        name = gang.name, label = gang.label, logo = info and info.logo or nil, color = info and info.accentColor or nil,
        xp = GangXP.Total(gang.name), lifetimeXp = GangXP.Lifetime(gang.name),
        canManage = GangService.HasPermission(src, 'manageGang') == true,
    }
end

local function auctionState()
    for _, id in ipairs(TerritoryAuction.getActiveIds()) do
        local rt = TerritoryAuction.get(id)
        if rt then return TerritoryAuction.publicState(rt) end
    end
    return nil
end

-- Everything the map needs, in one go (the tablet then stays live through the pushed events).
-- `known` = { [territoryId] = shape revision } the tablet already holds. A territory whose revision still matches is sent WITHOUT its
-- painted shapes (the tablet keeps the ones it has), so reopening the map costs almost nothing once it has been loaded.
lib.callback.register('nova_convoytruck:territory:getState', function(src, known)
    local admin, gang = caller(src)
    if admin == nil then return denied() end
    local territories = {}
    for _, t in ipairs(Territory.all()) do
        local have = type(known) == 'table' and tonumber(known[t.id]) or nil
        territories[#territories + 1] = Territory.view(t, admin, have ~= nil and have == t.rev)
    end
    local cfg = Config.Territory or {}
    return {
        ok = true, isAdmin = admin, adminXpBlocked = admin and GangXP.IsGangLeader(src) or false, me = meFor(src, gang), territories = territories, gangs = gangDirectory(),
        rivals = TerritoryWar.list(false, 150),
        candidates = gang and TerritoryWar.candidates(gang.name) or {},
        auction = auctionState(),
        serverTime = os.time(),
        config = { cellSize = cfg.cellSize, brush = cfg.brush, requireConfirm = true, paint = Territory.paintConfig() },
    }
end)

-- Lighter refresh after a rivals / XP change.
-- The Gang XP shown over a territory's leader ped. Asked by a client only while it stands near that ped (at most every ~15 s per ped),
-- answered from the XP cache (no database read) and rate-limited per player. Only a gang member or staff gets the number; anyone else
-- gets nil and the ped just shows the gang's name.
local peekAt = {}
AddEventHandler('playerDropped', function() peekAt[source] = nil end)
lib.callback.register('nova_convoytruck:territory:ownerXp', function(src, territoryId)
    local now = GetGameTimer()
    if peekAt[src] and now - peekAt[src] < 1500 then return nil end
    peekAt[src] = now
    if not caller(src) then return nil end
    local t = Territory.get(tostring(territoryId or ''))
    if not t or not t.owner then return nil end
    return { xp = GangXP.Total(t.owner) }
end)

-- ── The gang leader ped's conversation (client/modules/leader_talk.lua) ─────────────────────────────────────────────
-- One read for the whole conversation, built from the live territory / war / XP state and nothing else (no invented facts). What a
-- visitor learns depends on who they are: the owning gang's members and staff get the inside picture (Gang XP, open challenges,
-- touching rivals); a rival gang member gets only the public side plus the history between the two gangs; someone with no gang gets the
-- public side. Rate-limited per player; the client never sends a gang name, only the territory id.
local talkAt = {}
local warRows, warRowsAt = nil, 0   -- the recent challenges / wars, read from the database at most once per 10 s for ALL players talking to leaders
local function recentWars()
    local now = GetGameTimer()
    if warRows and now - warRowsAt < 10000 then return warRows end
    warRows, warRowsAt = TerritoryWar.list(false, 150), now
    return warRows
end
AddEventHandler('playerDropped', function() talkAt[source] = nil end)
lib.callback.register('nova_convoytruck:territory:leaderTalk', function(src, territoryId)
    local now = GetGameTimer()
    if talkAt[src] and now - talkAt[src] < 800 then return { ok = false, error = 'busy' } end
    talkAt[src] = now
    local t = Territory.get(tostring(territoryId or ''))
    if not t then return { ok = false, error = 'gone' } end
    local staff = isAdmin(src)
    local gang = GangXP.GangOf(src, true, true)
    local v = Territory.view(t, false, true)
    local cs = (t.def and t.def.base and t.def.base.cs) or 25.0
    local cells = Territory.cellCount(t)
    local relation
    if not t.owner then relation = 'unclaimed'
    elseif gang and gang.name == t.owner then relation = 'own'
    elseif gang then relation = 'rival'
    else relation = 'outsider' end
    local inside = relation == 'own' or staff == true
    local out = {
        ok = true,
        me = { gang = gang and { name = gang.name, label = gang.label } or nil, staff = staff == true, relation = relation },
        t = {
            id = t.id, name = t.name, owner = t.owner, ownerLabel = v.ownerLabel, ownerLogo = v.ownerLogo, ownerAccent = v.ownerAccent, color = t.color,
            busy = t.war and true or false, cells = cells, areaKm2 = math.floor((cells * cs * cs / 1000000) * 100 + 0.5) / 100, xpValue = t.xpValue,
        },
    }
    if t.owner then
        local sum = Territory.ownerSummary()[t.owner]
        out.owner = { count = sum and sum.count or 1, areaKm2 = sum and sum.areaKm2 or nil, xp = inside and GangXP.Total(t.owner) or nil }
        local rows = recentWars()
        local trouble = { open = {}, touching = {} }
        local between = {}
        local fights, last = 0, nil
        for _, r in ipairs(rows) do
            local mine = r.attacker == t.owner or r.defender == t.owner
            if mine then
                if r.status == 'PENDING' or r.status == 'ACCEPTED' or r.status == 'SCHEDULED' or r.status == 'ACTIVE' then
                    if inside then
                        local e = { attacker = r.attackerLabel, defender = r.defenderLabel, territory = r.territoryName, status = r.status, at = r.warAtText,
                            secondsLeft = r.live and r.live.secondsLeft or nil, here = r.territoryId == t.id }
                        trouble.open[#trouble.open + 1] = e
                    end
                end
                if relation == 'rival' and gang and (r.status == 'PENDING' or r.status == 'ACCEPTED' or r.status == 'SCHEDULED' or r.status == 'ACTIVE')
                    and ((r.attacker == gang.name and r.defender == t.owner) or (r.defender == gang.name and r.attacker == t.owner)) then
                    between[#between + 1] = { attacker = r.attackerLabel, defender = r.defenderLabel, territory = r.territoryName, status = r.status, at = r.warAtText,
                        secondsLeft = r.live and r.live.secondsLeft or nil, here = r.territoryId == t.id }
                end
                if r.status == 'COMPLETED' and gang and (r.attacker == gang.name or r.defender == gang.name) and relation == 'rival' then
                    fights = fights + 1
                    if not last then last = r.winnerLabel or false end   -- rows come newest first
                end
            end
        end
        if inside then
            local seen = {}
            for _, c in ipairs(Territory.rivalCandidates(t.owner)) do
                if c.touching and not seen[c.rival] then seen[c.rival] = true; trouble.touching[#trouble.touching + 1] = c.rivalLabel end
            end
            out.trouble = trouble
        end
        if relation == 'rival' then out.history = { fights = fights, lastWinner = last or nil }; out.between = between end
    end
    return out
end)

lib.callback.register('nova_convoytruck:territory:getRivals', function(src)
    local admin, gang = caller(src)
    if admin == nil then return denied() end
    return {
        ok = true, rivals = TerritoryWar.list(false, 150),
        candidates = gang and TerritoryWar.candidates(gang.name) or {},
        me = meFor(src, gang), auction = auctionState(),
    }
end)

lib.callback.register('nova_convoytruck:territory:getTerritoryHistory', function(src, territoryId)
    local admin = caller(src)
    if admin == nil then return denied() end
    return { ok = true, history = Territory.history(type(territoryId) == 'string' and territoryId or nil, 100) }
end)

lib.callback.register('nova_convoytruck:territory:getAuctionHistory', function(src, eventId)
    local admin = caller(src)
    if admin == nil then return denied() end
    return { ok = true, auctions = TerritoryAuction.history(tonumber(eventId), 100) }
end)

-- ── Gang XP ──────────────────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:territory:getXpBoard', function(src)
    local admin, gang = caller(src)
    if admin == nil then return denied() end
    return { ok = true, gangs = GangXP.Leaderboard(), players = GangXP.PlayerBoard(100), myGang = gang and gang.name or nil }
end)

-- XP history: a gang member sees their OWN gang's ledger; an admin may look at any gang (or everyone's).
lib.callback.register('nova_convoytruck:territory:getXpHistory', function(src, filters)
    local admin, gang = caller(src)
    if admin == nil then return denied() end
    filters = type(filters) == 'table' and filters or {}
    local f = {}
    if admin then
        if type(filters.gang) == 'string' and filters.gang ~= '' then f.gangName = filters.gang end
        if type(filters.identifier) == 'string' and filters.identifier ~= '' then f.identifier = filters.identifier end
    else
        f.gangName = gang.name
    end
    if type(filters.sourceType) == 'string' and filters.sourceType ~= '' then f.sourceType = filters.sourceType:sub(1, 30) end
    local rows = GangXP.History(f, tonumber(filters.limit) or 200)
    local labels = {}
    for _, g in ipairs(GangService.GetGangs() or {}) do labels[g.name] = g.label or g.name end
    for _, r in ipairs(rows) do r.gang_label = labels[r.gang_name] or r.gang_name end
    return { ok = true, history = rows, balance = gang and GangXP.Total(gang.name) or nil }
end)

-- ── Gang XP notices for members who were offline ──────────────────────────────────────────────────────────────────
-- An admin XP change is announced live to the gang's online members. Members who were not online get the same banner
-- the next time they log in (once each, for NOTICE_DAYS days). Kept per gang in resource KVP.
local NOTICE_DAYS, NOTICE_MAX = 7, 20
local function noticeKey(gangName) return 'nova_gang_xp_notices_' .. tostring(gangName) end

local function loadNotices(gangName)
    local raw = GetResourceKvpString(noticeKey(gangName))
    local ok, list = pcall(json.decode, raw or '[]')
    if not ok or type(list) ~= 'table' then return {} end
    local out, cutoff = {}, os.time() - NOTICE_DAYS * 86400
    for _, n in ipairs(list) do
        if type(n) == 'table' and (tonumber(n.at) or 0) >= cutoff then out[#out + 1] = n end
    end
    return out
end

local function saveNotices(gangName, list)
    while #list > NOTICE_MAX do table.remove(list, 1) end
    SetResourceKvp(noticeKey(gangName), json.encode(list))
end

local function showNotice(member, n)
    TriggerClientEvent('nova_convoytruck:runtime:announce', member, n.title, n.body, 12000, 'territory', nil, n.status, n.color)
end

-- One banner for a whole gang: shown at once to its online members, kept for the members who are offline (delivered at their
-- next login, once each). Used for admin XP changes and admin territory ownership changes.
local function announceToGang(gangName, title, body, status, color)
    if not gangName or gangName == '' then return end
    local notice = { at = os.time(), title = title, body = body, status = status, color = color, seen = {} }
    Territory.eachGangMember(gangName, function(member)
        showNotice(member, notice)
        local id = Bridge.GetIdentifier(member)
        if id then notice.seen[id] = true end        -- already told: not repeated at their next login
    end)
    local list = loadNotices(gangName)
    list[#list + 1] = notice
    saveNotices(gangName, list)
end
TerritoryNotices = { announceToGang = announceToGang }   -- used by territory_auction.lua when an auction ends

local lastNoticeCheck = {}
RegisterNetEvent('nova_convoytruck:territory:server:xpNotices', function()
    local src = source
    local now = os.time()
    if lastNoticeCheck[src] and now - lastNoticeCheck[src] < 10 then return end
    lastNoticeCheck[src] = now
    local gang = GangXP.GangOf(src, true)
    local identifier = Bridge.GetIdentifier(src)
    if not (gang and gang.name and identifier) then return end
    local list = loadNotices(gang.name)
    local pending = {}
    for _, n in ipairs(list) do
        n.seen = type(n.seen) == 'table' and n.seen or {}
        if not n.seen[identifier] then
            n.seen[identifier] = true
            pending[#pending + 1] = n
        end
    end
    if #pending == 0 then return end
    saveNotices(gang.name, list)
    CreateThread(function()
        Wait(6000)                                    -- let the HUD settle after the login
        for i, n in ipairs(pending) do
            if not GetPlayerName(src) then return end
            showNotice(src, n)
            if i < #pending then Wait(13000) end      -- one banner at a time
        end
    end)
end)
AddEventHandler('playerDropped', function() lastNoticeCheck[source] = nil end)

-- ── Gang actions from the Map Zone (Admin Tools): message a gang, disband a gang with its territories ─────────────
local function adminName(src) return tostring(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff') end

-- A message from staff to every member of one gang: a banner now for those online, kept for anyone offline until they next log in.
-- kind: 'WARNING' (amber, for a rule breach) | 'NOTICE' (blue, for information). Needs 'territories.edit'.
lib.callback.register('nova_convoytruck:territory:adminNotifyGang', function(src, gangName, kind, message)
    if not can(src, 'territories.edit') then return denied() end
    if type(gangName) ~= 'string' or gangName == '' then return { ok = false, error = 'Pick a gang.' } end
    local gang = GangService.GetGangByName(gangName)
    if not gang then return { ok = false, error = 'Unknown gang.' } end
    message = type(message) == 'string' and message:gsub('^%s+', ''):gsub('%s+$', '') or ''
    if #message < 3 then return { ok = false, error = 'Write the message the gang will see.' } end
    message = message:sub(1, 400)
    local warning = tostring(kind or ''):upper() == 'WARNING'
    local title = warning and 'WARNING FROM STAFF' or 'MESSAGE FROM STAFF'
    announceToGang(gangName, title, message, warning and 'WARNING' or 'NOTICE', warning and '#ffb020' or '#5aa2f0')
    Territory.logDiscord(('📣 [GANG] Staff %s — %s'):format(warning and 'warning' or 'message', gang.label or gangName), {
        { name = 'Gang', value = tostring(gang.label or gangName), inline = true },
        { name = 'By admin', value = adminName(src), inline = true },
        { name = 'Message', value = message, inline = false },
    }, warning and 0xffb020 or 0x5aa2f0)
    return { ok = true }
end)

-- Disband a gang AND deal with its territories. mode: 'RELEASE' = the territories become unclaimed (they can be auctioned again),
-- 'DELETE' = they are removed from the map. Members are told first. Needs 'gangs.delete' and 'territories.manage'; refused while
-- any of the gang's territories has a war on it.
lib.callback.register('nova_convoytruck:territory:adminDisbandGang', function(src, gangName, mode, reason)
    if not (can(src, 'gangs.delete') and can(src, 'territories.manage')) then return denied() end
    if type(gangName) ~= 'string' or gangName == '' then return { ok = false, error = 'Pick a gang.' } end
    local gang = GangService.GetGangByName(gangName)
    if not gang then return { ok = false, error = 'Unknown gang.' } end
    mode = tostring(mode or ''):upper() == 'DELETE' and 'DELETE' or 'RELEASE'
    reason = type(reason) == 'string' and reason:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 160) or ''

    local owned = {}
    for _, t in ipairs(Territory.all()) do
        if t.owner == gangName then
            if t.war then return { ok = false, error = ('"%s" has a war on it. Cancel or finish the war first.'):format(t.name) } end
            owned[#owned + 1] = t
        end
    end

    -- tell the members while they can still be found as members
    local label = gang.label or gangName
    local body = ('Your gang "%s" has been disbanded by staff.%s%s'):format(label,
        #owned > 0 and (' Its %d territor%s %s.'):format(#owned, #owned == 1 and 'y' or 'ies', mode == 'DELETE' and 'were removed from the map' or 'are now unclaimed') or '',
        reason ~= '' and (' Reason: ' .. reason) or '')
    Territory.eachGangMember(gangName, function(member)
        TriggerClientEvent('nova_convoytruck:territory:client:notify', member, { kind = 'rival', title = 'GANG DISBANDED', message = body })
    end)

    local who = adminName(src)
    local names = {}
    for _, t in ipairs(owned) do
        names[#names + 1] = t.name
        if mode == 'DELETE' then
            Territory.remove(t.id)
        else
            Territory.transfer(t.id, nil, gangName, { reason = 'ADMIN', refType = 'ADMIN', winnerName = who, winnerIdentifier = Bridge.GetIdentifier(src), meta = { note = 'Gang disbanded' } })
        end
    end

    local ok, err = GangService.DeleteGang(gang.id)
    if not ok then return { ok = false, error = err or 'The gang could not be deleted.' } end

    Territory.logDiscord(('🚫 [GANG] Disbanded — %s'):format(label), {
        { name = 'Gang', value = tostring(label), inline = true },
        { name = 'Territories', value = #names > 0 and ('%s (%s)'):format(table.concat(names, ', '), mode == 'DELETE' and 'removed' or 'unclaimed') or 'None', inline = true },
        { name = 'By admin', value = who, inline = true },
        { name = 'Reason', value = reason ~= '' and reason or 'No reason given', inline = false },
    }, 0xff5d50)
    return { ok = true, territories = #owned }
end)

-- Live price of painting land (XP per cell, most cells per save). Both fields optional: nil / empty = back to config.lua.
lib.callback.register('nova_convoytruck:territory:adminSetPaintRate', function(src, xpPerCell, maxNewCells)
    if not can(src, 'territories.edit') then return denied() end
    local function num(v) if v == nil or v == '' or v == false then return nil end return tonumber(v) end
    local xp, mx = num(xpPerCell), num(maxNewCells)
    if xp ~= nil and (xp < 0 or xp > 100000) then return { ok = false, error = 'XP per cell must be between 0 and 100,000.' } end
    if mx ~= nil and (mx < 1 or mx > 80000) then return { ok = false, error = 'Cells per save must be between 1 and 80,000.' } end
    local before = Territory.paintConfig()
    local who = tostring(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff')
    local ok, res = Territory.setPaintRate(xp, mx, who)
    if not ok then return { ok = false, error = res } end
    Territory.logDiscord('🗺️ [TERRITORY] Painting price changed', {
        { name = 'XP per cell', value = ('%d → %d'):format(before.xpPerCell, res.xpPerCell), inline = true },
        { name = 'Cells per save', value = ('%d → %d'):format(before.maxNewCells, res.maxNewCells), inline = true },
        { name = 'By admin', value = who, inline = true },
    }, 0xf59e0b)
    return { ok = true, paint = res }
end)

lib.callback.register('nova_convoytruck:territory:adminAdjustXp', function(src, gangName, delta, reason)
    if not can(src, 'territories.edit') then return denied() end
    if type(gangName) ~= 'string' then return { ok = false, error = 'Pick a gang.' } end
    reason = type(reason) == 'string' and reason:gsub('^%s+', ''):gsub('%s+$', '') or ''
    delta = math.floor(tonumber(delta) or 0)
    -- Taking XP away is a punishment the gang is told about, so it must come with a reason (checked here, not only in the tablet).
    if delta < 0 and #reason < 3 then return { ok = false, error = 'Give a reason — it is shown to the gang.' } end
    local ok, res = GangXP.AdminAdjust(src, gangName, delta, reason)
    if not ok then
        local why = tostring(res)
        if why == 'ERROR' then why = 'The XP could not be saved to the database — check the server console and try again.' end
        return { ok = false, error = why }
    end

    -- Tell ONLY that gang's online members, with the admin's reason, in the announcement banner.
    local amount = type(res) == 'table' and tonumber(res.amount) or math.abs(delta)
    local total = GangXP.Total(gangName)
    if amount and amount > 0 then
        local reduced = delta < 0
        local title = reduced and 'GANG XP REDUCED' or 'GANG XP AWARDED'
        local held = {}
        for _, t in ipairs(Territory.all()) do if t.owner == gangName then held[#held + 1] = t.name end end
        local body = ('%s%s XP — %s\nGang XP is now %s.%s'):format(reduced and '−' or '+', tostring(amount), reason ~= '' and reason or 'Awarded by staff.', tostring(total),
            #held > 0 and ('\nYour territories: ' .. table.concat(held, ', ') .. '.') or '')
        announceToGang(gangName, title, body, reduced and 'XP PENALTY' or 'XP BONUS', reduced and '#ff5d50' or '#46c98b')
        Territory.logDiscord(('⭐ [GANG XP] Admin %s — %s'):format(reduced and 'removed XP' or 'added XP', gangName), {
            { name = 'Gang', value = tostring(gangName), inline = true },
            { name = 'Change', value = ('%s%d XP'):format(reduced and '-' or '+', amount), inline = true },
            { name = 'Gang XP now', value = tostring(total), inline = true },
            { name = 'Reason', value = (reason ~= '' and reason or 'No reason given'):sub(1, 400), inline = false },
            { name = 'By admin', value = ('%s\n`%s`'):format(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff', Bridge.GetIdentifier(src) or 'N/A'), inline = true },
        }, reduced and 0xff5d50 or 0x46c98b)
    end
    return { ok = true, total = total }
end)

-- ── Map editor: painting land (only gangs paint, and they pay XP) ──────────────────

lib.callback.register('nova_convoytruck:territory:paint', function(src, territoryId, spans, cost)
    if type(territoryId) ~= 'string' or type(spans) ~= 'table' then return { ok = false, error = 'Nothing to save.' } end
    local ok, a, b, c = Territory.paint(src, territoryId, spans, cost)
    if not ok then return { ok = false, code = a, error = b, extra = c } end
    return { ok = true, result = a, xp = (a and a.total) }
end)

-- ── Rival challenges ─────────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:territory:sendChallenge', function(src, mineId, theirsId)
    local ok, res = TerritoryWar.sendChallenge(src, mineId, theirsId)
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

lib.callback.register('nova_convoytruck:territory:respondChallenge', function(src, rivalId, accept, comment)
    local ok, res = TerritoryWar.respond(src, rivalId, accept == true, comment)
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

-- ── Admin: wars & territories ────────────────────────────────────────────────────

-- dateTimeLocal: "YYYY-MM-DDTHH:MM" wall-clock in the server's schedule offset — the same format and conversion as the
-- event scheduler (Scheduler.toUtcTimestamp).
lib.callback.register('nova_convoytruck:territory:adminScheduleWar', function(src, rivalId, dateTimeLocal, minutes, penaltyXp)
    if not can(src, 'rivals.manage') then return denied() end
    local y, mo, d, h, mi = tostring(dateTimeLocal or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+)')
    if not y then return { ok = false, error = 'Pick a war date and time.' } end
    local ts = Scheduler.toUtcTimestamp(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi))
    local ok, res = TerritoryWar.schedule(src, rivalId, { warAt = ts, durationMinutes = minutes, penaltyXp = penaltyXp })
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

-- accept or decline a PENDING challenge on behalf of the challenged gang
lib.callback.register('nova_convoytruck:territory:adminRespondRival', function(src, rivalId, accept)
    if not can(src, 'rivals.manage') then return denied() end
    local ok, res = TerritoryWar.adminRespond(src, rivalId, accept == true)
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

-- draw / clear the war zone of a challenge (it only appears in the world once that war starts)
lib.callback.register('nova_convoytruck:territory:adminSetWarZone', function(src, rivalId, zone)
    if not can(src, 'rivals.manage') then return denied() end
    local ok, res = TerritoryWar.setZone(src, rivalId, type(zone) == 'table' and zone or nil)
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

-- the announcement of one challenge: previewOnly = only the admin sees it; otherwise it goes to the members of the two gangs only
lib.callback.register('nova_convoytruck:territory:adminAnnounceRival', function(src, rivalId, title, body, previewOnly)
    if not can(src, 'rivals.manage') then return denied() end
    local ok, res = TerritoryWar.announce(src, rivalId, title, body, previewOnly == true)
    if not ok then return { ok = false, error = res } end
    return { ok = true, result = res }
end)

lib.callback.register('nova_convoytruck:territory:adminStartWar', function(src, rivalId)
    if not can(src, 'rivals.manage') then return denied() end
    local ok, res = TerritoryWar.manualStart(src, rivalId)
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

lib.callback.register('nova_convoytruck:territory:adminCancelRival', function(src, rivalId, note)
    if not can(src, 'rivals.manage') then return denied() end
    local ok, res = TerritoryWar.cancel(src, rivalId, type(note) == 'string' and note:sub(1, 200) or nil)
    if not ok then return { ok = false, error = res } end
    return { ok = true, rival = res }
end)

lib.callback.register('nova_convoytruck:territory:adminRemoveTerritory', function(src, territoryId)
    if not can(src, 'mapzone.delete') then return denied() end
    local before = Territory.get(tostring(territoryId or ''))
    local beforeName, beforeOwner = before and before.name, before and before.owner
    local ok, err = Territory.remove(tostring(territoryId or ''))
    if not ok then return { ok = false, error = err } end
    Territory.logDiscord(('🗺️ [TERRITORY] Admin removed — %s'):format(beforeName or tostring(territoryId)), {
        { name = 'Territory', value = beforeName or tostring(territoryId), inline = true },
        { name = 'Owner was', value = tostring(beforeOwner or 'Unclaimed'), inline = true },
        { name = 'By admin', value = tostring(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff'), inline = true },
    }, 0xff5d50)
    return { ok = true }
end)

-- Wipes the land of a territory (stale paint, an old starting area). Staff never paint, they only take land away.
lib.callback.register('nova_convoytruck:territory:adminClearLand', function(src, territoryId)
    if not can(src, 'mapzone.edit') then return denied() end
    local ok, res = Territory.clearLand(tostring(territoryId or ''), tostring(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff'))
    if not ok then return { ok = false, error = res } end
    return { ok = true, cells = res }
end)

lib.callback.register('nova_convoytruck:territory:adminCreateTerritory', function(src, data)
    if not can(src, 'mapzone.create') then return denied() end
    local ok, res = Territory.create(data)
    if not ok then return { ok = false, error = res } end
    Territory.logDiscord(('🗺️ [TERRITORY] Admin created — %s'):format(tostring(res.name)), {
        { name = 'Territory', value = tostring(res.name), inline = true },
        { name = 'Owner', value = tostring(res.owner or 'Unclaimed'), inline = true },
        { name = 'XP value', value = tostring(res.xpValue or 0), inline = true },
        { name = 'By admin', value = tostring(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff'), inline = true },
    }, 0xf59e0b)
    return { ok = true, territory = Territory.view(res, true) }
end)

-- Hands a territory to a gang (or takes the owner away) by hand — recorded in the territory history as an ADMIN change.
lib.callback.register('nova_convoytruck:territory:adminSetOwner', function(src, territoryId, gangName, reason)
    if not can(src, 'territories.manage') then return denied() end
    local t = Territory.get(tostring(territoryId or ''))
    if not t then return { ok = false, error = 'Territory not found.' } end
    if t.war then return { ok = false, error = 'A war is running on this territory.' } end
    local owner = (type(gangName) == 'string' and gangName ~= '') and gangName or nil
    if owner and not GangService.GetGangByName(owner) then return { ok = false, error = 'Unknown gang.' } end
    local before = t.owner        -- read BEFORE the transfer: it updates this same record
    local tName = t.name
    local ok, err = Territory.transfer(t.id, owner, t.owner, {
        reason = 'ADMIN', refType = 'ADMIN', winnerName = Bridge.GetCharacterName(src), winnerIdentifier = Bridge.GetIdentifier(src),
        meta = { note = type(reason) == 'string' and reason:sub(1, 160) or nil },
    })
    if not ok then return { ok = false, error = err } end

    Territory.logDiscord(('🗺️ [TERRITORY] Admin changed owner — %s'):format(tName), {
        { name = 'Territory', value = tostring(tName), inline = true },
        { name = 'From', value = tostring(before or 'Unclaimed'), inline = true },
        { name = 'To', value = tostring(owner or 'Unclaimed'), inline = true },
        { name = 'Reason', value = tostring(type(reason) == 'string' and reason ~= '' and reason:sub(1, 300) or 'No reason given'), inline = false },
        { name = 'By admin', value = tostring(Bridge.GetCharacterName(src) or Bridge.GetPlayerName(src) or 'Staff'), inline = true },
    }, 0xf59e0b)

    -- Tell BOTH gangs (online members now, the rest at their next login) with the admin's note as the reason.
    local note = type(reason) == 'string' and reason:gsub('^%s+', ''):gsub('%s+$', '') or ''
    local function labelOf(name)
        local g = name and GangService.GetGangByName(name)
        return g and (g.label or g.name) or tostring(name)
    end
    local why = note ~= '' and ('\nReason: ' .. note) or ''
    if before and before ~= owner then
        local body = owner and ('%s was taken from %s and given to %s by an administrator.%s'):format(tName, labelOf(before), labelOf(owner), why)
                           or ('%s was removed from %s by an administrator.%s'):format(tName, labelOf(before), why)
        announceToGang(before, 'TERRITORY LOST', body, 'TERRITORY LOST', '#ff5d50')
    end
    if owner and owner ~= before then
        local body = before and ('%s is now yours — an administrator moved it from %s to %s.%s'):format(tName, labelOf(before), labelOf(owner), why)
                            or ('%s is now yours — an administrator gave it to %s.%s'):format(tName, labelOf(owner), why)
        announceToGang(owner, 'TERRITORY GAINED', body, 'TERRITORY GAINED', '#46c98b')
    end
    return { ok = true }
end)

-- ── joining players ──────────────────────────────────────────────────────────────

-- A player who just finished loading gets the territory snapshot (blips / ground markers), the auction in progress and the
-- war they belong to — so a reconnect or a late join never misses the picture.
Bridge.OnPlayerLoaded(function(src)
    SetTimeout(4000, function()
        if not GetPlayerName(src) or not Territory.isReady() then return end
        local member = isAdmin(src) or GangXP.GangOf(src, true, true)
        if member or Territory.canSeeWorld(src) then Territory.snapshotFor(src) end   -- blips, rings, leader peds
        if member then
            local st = auctionState()
            if st then TriggerClientEvent('nova_convoytruck:territory:client:auctionState', src, st) end
        end
        -- the war (ring, Take Territory target, one-life rule) and any open loot: on Qbox the client's own request at session start
        -- runs BEFORE the character is loaded, so a member who loads in mid-war never got them
        if TerritoryWar and TerritoryWar.syncPlayer then pcall(TerritoryWar.syncPlayer, src) end
    end)
end)

RegisterNetEvent('nova_convoytruck:territory:server:requestSnapshot', function()
    local src = source
    local member = isAdmin(src) or GangXP.GangOf(src, true, true)
    if member or Territory.canSeeWorld(src) then Territory.snapshotFor(src) end
    if member then
        local st = auctionState()
        if st then TriggerClientEvent('nova_convoytruck:territory:client:auctionState', src, st) end
    end
end)
