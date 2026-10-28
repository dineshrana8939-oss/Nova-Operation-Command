-- ─── Nova Convoy — Rival Challenges & Territory Wars ───────────────────────────
-- Server-only. When two gangs' painted territories touch, the gang that grew can send a RIVAL CHALLENGE for the
-- neighbouring territory. The defender accepts or declines; an accepted challenge shows up in the admin's Rivals
-- tab, where the admin sets the war date / time / duration (or starts it by hand). At that time the war begins:
-- the attackers use ox_target "Take Territory" on the territory leader ped and hold the point; defenders inside the
-- capture radius CONTEST it. The server owns every step — adjacency, who may challenge / answer, the schedule, who is
-- present and alive, the capture progress and the result. Deaths and revives are the normal FiveM / EMS ones: nothing
-- here respawns anyone.
--
--   PENDING → ACCEPTED → SCHEDULED → ACTIVE → COMPLETED        (DECLINED / CANCELLED can end it earlier)
--
-- War result (NOBODY LOSES A TERRITORY; the stakes are paid when the winner loots the Leader Ped, see claimLoot):
--   capture completes ........ the attacking side wins (CAPTURED)
--   timer ends, someone there  the side with more fighters in the zone wins; a tie goes to the home gang (DEFENDED)
--   looting ................... the loser pays the winner Gang XP and the loser's painted land shrinks
--   home turf ................. the battleground is the smaller gang's own territory, so the challenged gang attacks it; whoever wins
--                              the fight wins the stakes, whichever side they started on
--   timer ends, NOBODY from either gang alive in the territory → the owner keeps the territory and its position, and
--                              loses Gang XP as the configured no-show penalty (Config.Territory.war.noShowPenalty,
--                              or the amount the admin set for this war)

TerritoryWar = {}

local OPEN = { PENDING = true, ACCEPTED = true, SCHEDULED = true, ACTIVE = true }
local open = {}          -- [rivalId] = row (every open challenge, kept in sync with the database)
local wars = {}          -- [rivalId] = live war runtime
local reminded = {}      -- 'rivalId:minutes' = true
local activeLoots = {}   -- [rivalId] = post-war loot session

local function tcfg() return Config.Territory or {} end
local function wcfg() return tcfg().war or {} end
local function rcfg() return tcfg().rival or {} end
local function now() return os.time() end

local function log(msg) print(('[NovaConvoy][TerritoryWar] %s'):format(tostring(msg))) end

local function label(g) return Territory.gangLabel(g) or g end

local function money(n)
    local s = tostring(math.floor((tonumber(n) or 0) + 0.5))
    return '$' .. s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

-- ── who is alive / where ─────────────────────────────────────────────────────────
-- Normal FiveM / EMS mechanics: a player is "down" when the framework / medical script says so (the same flags the convoy
-- squad HUD reads), or when their ped is at / below the GTA dead health line.
local function isAlive(src)
    local st = Player(src).state
    if st.isDead == true or st.dead == true or st.isDowned == true or st.inLastStand == true then return false end
    local v = st.convoyVitals
    if type(v) == 'table' and v.dead then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return GetEntityHealth(ped) > 100
end

local function dist2d(c, x, y)
    local dx, dy = c.x - x, c.y - y
    return math.sqrt(dx * dx + dy * dy)
end

-- ── notifications ────────────────────────────────────────────────────────────────

-- Who gets the staff side of a war: the "new challenge / accepted" toasts and the live war view (ring, timer, scores, the
-- spectator role). Anyone who holds the Rival Wars & Challenges permission (View or Manage) in Staff Management — a staff role, not
-- only a full server admin. Server admins hold every permission, so they are still included.
local function isWarStaff(src)
    if UserPermissions and UserPermissions.canAny then
        return UserPermissions.canAny(src, 'rivals.view', 'rivals.manage') == true
    end
    return Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission) == true
end

local function toGang(gangName, payload, banner)
    Territory.eachGangMember(gangName, function(src)
        TriggerClientEvent('nova_convoytruck:territory:client:notify', src, payload)
        if banner then
            TriggerClientEvent('nova_convoytruck:runtime:announce', src, banner.title, banner.body, banner.duration or 9000, 'territory', nil, banner.status)
        end
    end)
end

local function toAdmins(payload)
    for _, src in ipairs(Bridge.GetPlayers()) do
        if isWarStaff(src) then
            TriggerClientEvent('nova_convoytruck:territory:client:notify', src, payload)
        end
    end
end

local function toEveryone(title, body, duration, status)
    for _, src in ipairs(Bridge.GetPlayers()) do
        TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body, duration or 9000, 'territory', nil, status)
    end
end

-- Tells every open tablet "the rivals list changed" (live: no refresh, no reopen).
local function rivalsChanged()
    for _, src in ipairs(Territory.audience()) do
        TriggerClientEvent('nova_convoytruck:territory:client:rivalsChanged', src)
    end
end

-- ── views ────────────────────────────────────────────────────────────────────────

local function liveInfo(war)
    if not war then return nil end
    local cap = war.capture
    return {
        secondsLeft = math.max(0, war.endsAt - now()), state = cap.state, progress = math.floor(cap.progress * 10) / 10, captureSeconds = cap.seconds,
        attackersPresent = war.lastAttackers or 0, defendersPresent = war.lastDefenders or 0,
        attackersAlive = war.lastAttackersAlive or 0, defendersAlive = war.lastDefendersAlive or 0,
        attackersTotal = war.lastAttackersTotal or 0, defendersTotal = war.lastDefendersTotal or 0,
    }
end

-- The war zone an admin drew for a challenge: a circle (size = radius) or an axis-aligned square (size = half the side), in metres.
-- It only exists in the world while that war is running; stored as JSON on the challenge.
function TerritoryWar.cleanZone(z)
    if type(z) ~= 'table' then return nil end
    local x, y, zz, size = tonumber(z.x), tonumber(z.y), tonumber(z.z), tonumber(z.size)
    if not (x and y and size) then return nil end
    local shape = z.shape == 'square' and 'square' or 'circle'
    size = math.max(20.0, math.min(shape == 'square' and 450.0 or 600.0, size))
    return { shape = shape, x = x, y = y, z = zz or 0.0, size = size }
end

function TerritoryWar.decodeZone(raw)
    if type(raw) ~= 'string' or raw == '' then return nil end
    local ok, z = pcall(json.decode, raw)
    return ok and TerritoryWar.cleanZone(z) or nil
end

local function inWarZone(war, c)
    local z = war.zone
    if not z then return false end
    if z.shape == 'square' then return math.abs(c.x - z.x) <= z.size and math.abs(c.y - z.y) <= z.size end
    return dist2d(c, z.x, z.y) <= z.size
end

function TerritoryWar.view(row)
    local t = Territory.get(row.territory_id)
    local ta = row.attacker_territory_id and Territory.get(row.attacker_territory_id) or nil
    return {
        id = row.id, attacker = row.attacker_gang, attackerLabel = label(row.attacker_gang),
        defender = row.defender_gang, defenderLabel = label(row.defender_gang),
        territoryId = row.territory_id, territoryName = t and t.name or row.territory_id,
        attackerTerritoryId = row.attacker_territory_id, attackerTerritoryName = ta and ta.name or row.attacker_territory_id,
        status = row.status, warAt = tonumber(row.war_at), durationSec = tonumber(row.war_duration), penaltyXp = tonumber(row.penalty_xp),
        createdAt = tonumber(row.created_at), respondedAt = tonumber(row.responded_at), startedAt = tonumber(row.started_at), endedAt = tonumber(row.ended_at),
        createdByName = row.created_by_name, respondedByName = row.responded_by_name, scheduledBy = row.scheduled_by,
        winner = row.winner_gang, winnerLabel = row.winner_gang and label(row.winner_gang) or nil, result = row.result, note = row.result_note,
        live = liveInfo(wars[row.id]),
        comment = row.response_comment, zone = TerritoryWar.decodeZone(row.war_zone),
        warAtText = row.war_at and Scheduler.formatLocal(tonumber(row.war_at)) or nil,
    }
end

function TerritoryWar.list(onlyOpen, limit)
    local rows = DB.rivalList(onlyOpen, limit or 200)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = TerritoryWar.view(r) end
    return out
end

local function reload(id)
    local row = DB.rivalGet(id)
    if row and OPEN[row.status] then open[id] = row else open[id] = nil end
    return row
end

-- ── permissions ──────────────────────────────────────────────────────────────────

-- May `src` act for their gang (send / answer a challenge)? Returns gang, or nil + message. Always fresh membership.
local function actingGang(src)
    local gang = GangXP.GangOf(src, true, true)
    if not gang then return nil, 'You are not in a gang.' end
    if rcfg().requireLeaderOrPermission ~= false and not GangService.HasPermission(src, 'manageGang') then
        return nil, 'Only your gang leader (or a role with the Manage Gang permission) can do that.'
    end
    return gang
end

local function openCountFor(gangName)
    local n = 0
    for _, r in pairs(open) do
        if r.attacker_gang == gangName or r.defender_gang == gangName then n = n + 1 end
    end
    return n
end

-- ── challenge ────────────────────────────────────────────────────────────────────

-- The rival territories a gang could challenge right now (touching, not already in a challenge / war), for the tablet.
function TerritoryWar.candidates(gangName)
    local out = {}
    -- the recent challenges are read ONCE per call (it used to be one database query per territory pair)
    local cdSeconds = tonumber(rcfg().challengeCooldownSeconds) or 0
    local recent = cdSeconds > 0 and DB.rivalList(false, 60) or {}
    for _, c in ipairs(Territory.rivalCandidates(gangName)) do
        local theirs = Territory.get(c.theirsId)
        local blocked
        if theirs and theirs.war then blocked = 'A war is already running on this territory.' end
        if not blocked then
            for _, r in pairs(open) do
                if r.territory_id == c.theirsId or (theirs and r.attacker_gang == gangName and r.defender_gang == theirs.owner) then blocked = 'A challenge for this territory is already open.' break end
            end
        end
        if not blocked then
            local cd = cdSeconds
            if cd > 0 then
                for _, r in ipairs(recent) do
                    if r.attacker_gang == gangName and (r.territory_id == c.theirsId or (theirs and r.defender_gang == theirs.owner)) and (r.status == 'DECLINED' or r.status == 'COMPLETED')
                        and (now() - (tonumber(r.ended_at) or tonumber(r.responded_at) or tonumber(r.created_at) or 0)) < cd then
                        blocked = 'You challenged this territory recently — try again later.'
                        break
                    end
                end
            end
        end
        c.blocked = blocked
        out[#out + 1] = c
    end
    return out
end

function TerritoryWar.sendChallenge(src, mineId, theirsId)
    local gang, err = actingGang(src)
    if not gang then return false, err end
    local mine, theirs = Territory.get(tostring(mineId or '')), Territory.get(tostring(theirsId or ''))
    if not mine or not theirs then return false, 'Territory not found.' end
    if mine.owner ~= gang.name then return false, 'Your gang does not own that territory.' end
    if not theirs.owner then return false, 'That territory has no owner to challenge.' end
    if theirs.owner == gang.name then return false, 'You cannot challenge your own territory.' end
    if mine.war or theirs.war then return false, 'A war is already running on one of these territories.' end
    for _, r in pairs(open) do
        -- (the battle territory stored on a challenge can be the challenger's own, so the same gang pair counts too)
        if r.territory_id == theirs.id or (r.attacker_gang == gang.name and r.defender_gang == theirs.owner) then return false, 'A challenge for this territory is already open.' end
    end
    if openCountFor(gang.name) >= (tonumber(rcfg().maxOpenPerGang) or 3) then
        return false, ('Your gang already has the maximum of %d open challenges.'):format(tonumber(rcfg().maxOpenPerGang) or 3)
    end
    local cd = tonumber(rcfg().challengeCooldownSeconds) or 0
    if cd > 0 then
        for _, r in ipairs(DB.rivalList(false, 60)) do
            if r.attacker_gang == gang.name and (r.territory_id == theirs.id or r.defender_gang == theirs.owner) and (r.status == 'DECLINED' or r.status == 'COMPLETED')
                and (now() - (tonumber(r.ended_at) or tonumber(r.responded_at) or tonumber(r.created_at) or 0)) < cd then
                return false, 'You challenged this territory recently — try again later.'
            end
        end
    end

    -- Tactical home-turf advantage:
    -- If challenger is smaller (fewer cells or less XP), war is fought at challenger's home turf (mine.id) so they have tactical advantage!
    -- If challenged gang is smaller or equal, war is fought at defender's turf (theirs.id).
    local mineCells = Territory.cellCount(mine)
    local theirsCells = Territory.cellCount(theirs)
    local mineXp = GangXP.Total(gang.name)
    local theirsXp = GangXP.Total(theirs.owner)

    local mineIsSmaller = (mineCells < theirsCells) or (mineCells == theirsCells and mineXp < theirsXp)
    local battleTerritory = mineIsSmaller and mine or theirs

    local id = DB.rivalInsert({
        attackerGang = gang.name, defenderGang = theirs.owner, attackerTerritoryId = mine.id, defenderTerritoryId = theirs.id, territoryId = battleTerritory.id,
        createdBy = Bridge.GetIdentifier(src), createdByName = Bridge.GetCharacterName(src), createdAt = now(),
    })
    reload(id)
    log(('Challenge #%d: %s → %s [Battleground: %s (%s)]'):format(id, gang.name, theirs.owner, battleTerritory.name, mineIsSmaller and 'challenger home advantage' or 'defender home turf'))

    local challengeMsg = mineIsSmaller
        and ('%s has challenged your gang! Since %s is the smaller gang, the war will take place on their home turf %s for tactical fair play. Open the Territory tab to ACCEPT or DECLINE.'):format(gang.label, gang.label, mine.name)
        or ('%s has challenged your territory %s. Open the Territory tab to ACCEPT or DECLINE.'):format(gang.label, theirs.name)

    toGang(theirs.owner, {
        kind = 'challenge', title = 'TERRITORY RIVAL CHALLENGE', rivalId = id,
        message = challengeMsg,
    }, { title = 'TERRITORY RIVAL CHALLENGE', body = challengeMsg, duration = 9000, status = 'CHALLENGE' })

    local sentMsg = mineIsSmaller
        and ('Your challenge was sent to %s. For fair tactical advantage, the war will take place at your home turf %s!'):format(label(theirs.owner), mine.name)
        or ('Your challenge for %s was sent to %s. They must accept before an admin can schedule the war.'):format(theirs.name, label(theirs.owner))

    toGang(gang.name, {
        kind = 'challenge-sent', title = 'CHALLENGE SENT', rivalId = id,
        message = sentMsg,
    })
    toAdmins({ kind = 'rival-admin', title = 'NEW RIVAL CHALLENGE', message = ('%s → %s (Battleground: %s)'):format(gang.label, label(theirs.owner), battleTerritory.name) })
    rivalsChanged()
    return true, TerritoryWar.view(DB.rivalGet(id))
end

function TerritoryWar.respond(src, rivalId, accept, comment)
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    if row.status ~= 'PENDING' then return false, 'This challenge was already answered.' end
    local gang, err = actingGang(src)
    if not gang then return false, err end
    if gang.name ~= row.defender_gang then return false, 'Only the challenged gang can answer.' end
    local t = Territory.get(row.territory_id)
    if not t or (t.owner ~= row.defender_gang and t.owner ~= row.attacker_gang) then
        DB.rivalUpdate(row.id, { status = 'CANCELLED', result = 'VOID', result_note = 'The territory changed hands.', ended_at = now() }, 'PENDING')
        reload(row.id); rivalsChanged()
        return false, 'The battleground territory no longer belongs to either gang — the challenge was cancelled.'
    end

    local newStatus = accept and 'ACCEPTED' or 'DECLINED'
    -- the answering gang may leave the admins a note (shown under the challenge on the admin Rival Wars tab)
    comment = type(comment) == 'string' and comment:gsub('[%c]+', ' '):match('^%s*(.-)%s*$') or ''
    if #comment > 300 then comment = comment:sub(1, 300) end
    local ok = DB.rivalUpdate(row.id, {
        status = newStatus, responded_by = Bridge.GetIdentifier(src), responded_by_name = Bridge.GetCharacterName(src), responded_at = now(),
        ended_at = (not accept) and now() or nil, response_comment = comment ~= '' and comment or nil,
    }, 'PENDING')
    if not ok then return false, 'This challenge was already answered.' end
    reload(row.id)

    local tname = t.name
    if accept then
        toGang(row.attacker_gang, { kind = 'challenge-accepted', title = 'CHALLENGE ACCEPTED', rivalId = row.id,
            message = ('%s accepted your challenge for %s. An admin will schedule the war.'):format(label(row.defender_gang), tname) })
        toGang(row.defender_gang, { kind = 'challenge-accepted', title = 'CHALLENGE ACCEPTED', rivalId = row.id,
            message = ('You accepted the challenge for %s. An admin will schedule the war — both gangs must be present when it starts.'):format(tname) })
        toAdmins({ kind = 'rival-admin', title = 'CHALLENGE ACCEPTED', message = ('%s vs %s — %s is ready to be scheduled.%s'):format(label(row.attacker_gang), label(row.defender_gang), tname,
            comment ~= '' and (' ' .. label(row.defender_gang) .. ' says: "' .. comment .. '"') or '') })
    else
        toGang(row.attacker_gang, { kind = 'challenge-declined', title = 'CHALLENGE DECLINED', rivalId = row.id,
            message = ('%s declined your challenge for %s.'):format(label(row.defender_gang), tname) })
        toGang(row.defender_gang, { kind = 'challenge-declined', title = 'CHALLENGE DECLINED', rivalId = row.id,
            message = ('You declined the challenge for %s.'):format(tname) })
    end
    rivalsChanged()
    return true, TerritoryWar.view(DB.rivalGet(row.id))
end

-- ── admin: answer / schedule / start / cancel ───────────────────────────────────

-- An administrator answers a PENDING challenge on behalf of the challenged gang (it is not answering, or an admin wants to settle it).
-- Recorded under the admin's name; both gangs are told it was an administrator.
function TerritoryWar.adminRespond(adminSrc, rivalId, accept)
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    if row.status ~= 'PENDING' then return false, 'This challenge was already answered.' end
    local t = Territory.get(row.territory_id)
    if not t or (t.owner ~= row.defender_gang and t.owner ~= row.attacker_gang) then
        DB.rivalUpdate(row.id, { status = 'CANCELLED', result = 'VOID', result_note = 'The territory changed hands.', ended_at = now() }, 'PENDING')
        reload(row.id); rivalsChanged()
        return false, 'The battleground territory no longer belongs to either gang - the challenge was cancelled.'
    end
    local who = (Bridge.GetCharacterName(adminSrc) or 'Admin') .. ' (admin)'
    local ok = DB.rivalUpdate(row.id, {
        status = accept and 'ACCEPTED' or 'DECLINED', responded_by = Bridge.GetIdentifier(adminSrc), responded_by_name = who, responded_at = now(),
        ended_at = (not accept) and now() or nil,
    }, 'PENDING')
    if not ok then return false, 'This challenge was already answered.' end
    reload(row.id)
    local msg = accept
        and ('An administrator accepted the challenge for %s on behalf of %s. A war date will be set.'):format(t.name, label(row.defender_gang))
        or ('An administrator declined the challenge for %s on behalf of %s.'):format(t.name, label(row.defender_gang))
    local kind = accept and 'challenge-accepted' or 'challenge-declined'
    local title = accept and 'CHALLENGE ACCEPTED' or 'CHALLENGE DECLINED'
    toGang(row.attacker_gang, { kind = kind, title = title, rivalId = row.id, message = msg })
    toGang(row.defender_gang, { kind = kind, title = title, rivalId = row.id, message = msg })
    log(('Challenge #%d %s by an administrator (%s)'):format(row.id, accept and 'accepted' or 'declined', who))
    rivalsChanged()
    return true, TerritoryWar.view(DB.rivalGet(row.id))
end

-- opts: { warAt (UTC unix), durationMinutes, penaltyXp (nil = the configured rule) }
function TerritoryWar.schedule(adminSrc, rivalId, opts)
    opts = opts or {}
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    if row.status == 'PENDING' then   -- the admin sets the date straight away: that accepts it for the challenged gang
        local okA, errA = TerritoryWar.adminRespond(adminSrc, row.id, true)
        if not okA then return false, errA end
        row = DB.rivalGet(row.id)
    end
    if row.status ~= 'ACCEPTED' and row.status ~= 'SCHEDULED' then return false, 'Only an accepted challenge can be scheduled.' end
    local t = Territory.get(row.territory_id)
    if not t or (t.owner ~= row.defender_gang and t.owner ~= row.attacker_gang) then return false, 'The battleground territory no longer belongs to either gang.' end

    local warAt = tonumber(opts.warAt)
    if not warAt then return false, 'Pick a war date and time.' end
    if warAt <= Scheduler.nowUtc() + 30 then return false, 'The war time must be in the future.' end
    local w = wcfg()
    local minutes = math.floor(tonumber(opts.durationMinutes) or tonumber(w.defaultDurationMinutes) or 15)
    minutes = math.max(tonumber(w.minDurationMinutes) or 3, math.min(tonumber(w.maxDurationMinutes) or 90, minutes))
    local penalty = opts.penaltyXp
    if penalty == '' then penalty = nil end
    penalty = penalty ~= nil and math.max(0, math.floor(tonumber(penalty) or 0)) or nil

    local who = Bridge.GetCharacterName(adminSrc) or 'Admin'
    if not DB.rivalUpdate(row.id, { territory_id = row.territory_id, status = 'SCHEDULED', war_at = warAt, war_duration = minutes * 60, penalty_xp = (penalty == nil) and false or penalty, scheduled_by = who }, row.status) then
        return false, 'The challenge changed in the meantime — refresh and try again.'
    end
    for m in pairs(reminded) do if m:match('^' .. row.id .. ':') then reminded[m] = nil end end
    reload(row.id)

    local start = Scheduler.formatLocal(warAt)
    local body = ('%s VS %s — Territory: %s — Start: %s — Duration: %d minutes. Both gangs are responsible for being present before the battle begins.')
        :format(label(row.attacker_gang):upper(), label(row.defender_gang):upper(), t.name, start, minutes)
    local sb = (wcfg().banners or {}).scheduled or {}
    local stitle = sb.title or 'TERRITORY WAR SCHEDULED'
    toGang(row.attacker_gang, { kind = 'war-scheduled', title = stitle, rivalId = row.id, message = body },
        { title = stitle, body = body, duration = sb.duration or 12000, status = 'SCHEDULED' })
    toGang(row.defender_gang, { kind = 'war-scheduled', title = stitle, rivalId = row.id, message = body },
        { title = stitle, body = body, duration = sb.duration or 12000, status = 'SCHEDULED' })
    -- the rest of the server hears about it too (server announcement)
    for _, src in ipairs(Bridge.GetPlayers()) do
        local g = GangXP.GangOf(src, true)
        if not g or (g.name ~= row.attacker_gang and g.name ~= row.defender_gang) then
            TriggerClientEvent('nova_convoytruck:runtime:announce', src, stitle,
                ('%s vs %s over %s — %s.'):format(label(row.attacker_gang), label(row.defender_gang), t.name, start), 9000, 'territory', nil, 'SCHEDULED')
        end
    end
    log(('War #%d scheduled for %s by %s'):format(row.id, start, who))
    rivalsChanged()
    return true, TerritoryWar.view(DB.rivalGet(row.id))
end

function TerritoryWar.cancel(adminSrc, rivalId, note)
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    if not OPEN[row.status] then return false, 'This challenge is already finished.' end
    local war = wars[row.id]
    if war then
        TerritoryWar.conclude(war, 'CANCELLED', { note = note or 'Cancelled by an administrator.' })
        return true, TerritoryWar.view(DB.rivalGet(row.id))
    end
    DB.rivalUpdate(row.id, { status = 'CANCELLED', result = 'CANCELLED', result_note = note or 'Cancelled by an administrator.', ended_at = now() }, row.status)
    reload(row.id)
    toGang(row.attacker_gang, { kind = 'war-cancelled', title = 'CHALLENGE CANCELLED', rivalId = row.id, message = ('The challenge for %s was cancelled by an administrator.'):format((Territory.get(row.territory_id) or {}).name or row.territory_id) })
    toGang(row.defender_gang, { kind = 'war-cancelled', title = 'CHALLENGE CANCELLED', rivalId = row.id, message = ('The challenge for %s was cancelled by an administrator.'):format((Territory.get(row.territory_id) or {}).name or row.territory_id) })
    rivalsChanged()
    return true, TerritoryWar.view(DB.rivalGet(row.id))
end

-- An administrator draws (or clears) the war zone of a challenge. It is stored with the challenge and only drawn / enforced once the war starts.
function TerritoryWar.setZone(adminSrc, rivalId, zone)
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    if not OPEN[row.status] then return false, 'This challenge is over.' end
    local clean = zone ~= nil and TerritoryWar.cleanZone(zone) or nil
    if zone ~= nil and not clean then return false, 'The zone needs a centre and a size.' end
    local fields = { war_zone = clean and json.encode(clean) or false }
    if not DB.rivalUpdate(row.id, fields) then return false, 'The zone could not be saved.' end
    reload(row.id); rivalsChanged()
    return true, TerritoryWar.view(DB.rivalGet(row.id))
end

-- The announcement for ONE challenge goes to the members of the two gangs only (previewOnly: just to the admin who is looking at it).
function TerritoryWar.announce(adminSrc, rivalId, title, body, previewOnly)
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    title = tostring(title or ''):gsub('[%c]+', ' '):sub(1, 100)
    body = tostring(body or ''):gsub('[%c]+', ' '):sub(1, 500)
    if title == '' then return false, 'A title is needed.' end
    if previewOnly then
        TriggerClientEvent('nova_convoytruck:runtime:announce', adminSrc, title, body, 10000, 'territory', nil, 'ADMIN PREVIEW')
        return true, { sent = 0 }
    end
    local sent = 0
    for _, src in ipairs(Bridge.GetPlayers()) do
        local g = GangXP.GangOf(src, true)
        if g and (g.name == row.attacker_gang or g.name == row.defender_gang) then
            TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body, 10000, 'territory', nil, 'RIVAL WAR')
            sent = sent + 1
        end
    end
    log(('Announcement for challenge #%d sent to %d member(s) of %s and %s'):format(row.id, sent, row.attacker_gang, row.defender_gang))
    return true, { sent = sent }
end

-- ── the war ──────────────────────────────────────────────────────────────────────

local function capturePoint(t)
    local cap = t.def.capture or {}
    local p = cap.ped
    if p and p.x and p.y then return { x = p.x, y = p.y, z = p.z, fromPed = true } end
    local x, y, z = Territory.center(t)
    return { x = x, y = y, z = (t.def.location and t.def.location.z) or nil, fromPed = false }
end

local function warPayload(war, role, src)
    local t = Territory.get(war.territoryId)
    local cap = (t and t.def.capture) or {}
    local w = wcfg().capture or {}
    local ident = src and Bridge.GetIdentifier(src)
    local isElim = (ident and war.eliminated and war.eliminated[ident] ~= nil) or false
    return {
        warId = war.id, territoryId = war.territoryId, territoryName = t and t.name or war.territoryId,
        attacker = war.attacker, attackerLabel = label(war.attacker), defender = war.defender, defenderLabel = label(war.defender),
        role = role, secondsLeft = math.max(0, war.endsAt - now()), durationSec = war.durationSec,
        eliminated = isElim,
        capture = {
            enabled = cap.enabled ~= false, point = war.point, ped = cap.ped and cap.ped.x and cap.ped or nil,
            model = (cap.ped and cap.ped.model) or w.pedModel, anim = cap.anim, props = cap.props or (t and t.def.props) or {},
            seconds = war.capture.seconds, radius = war.capture.radius, interactDistance = war.capture.interactDistance,
            targetLabel = w.targetLabel, targetIcon = w.targetIcon, blip = w.blip,
        },
        ringZone = (function()
            local rz = wcfg().ringZone or {}
            local z = war.zone
            if z then   -- the zone an admin drew for this war replaces the round ring around the leader ped: same rules, green, any centre
                return {
                    enabled = true, shape = z.shape, radius = z.size,
                    bufferSeconds = math.max(10, math.min(120, tonumber(rz.bufferSeconds) or 35)),
                    showMapBlip = true, blipColor = 2, blipAlpha = 90, drawWorldRing = true,
                    worldRingColor = { r = 60, g = 190, b = 110, a = 70 },
                    point = { x = z.x, y = z.y, z = z.z }, custom = true,
                }
            end
            return {
                enabled = rz.enabled ~= false,
                radius = tonumber(rz.radius) or 160.0,
                bufferSeconds = math.max(10, math.min(120, tonumber(rz.bufferSeconds) or 35)),
                showMapBlip = rz.showMapBlip ~= false,
                blipColor = tonumber(rz.blipColor) or 1,
                blipAlpha = tonumber(rz.blipAlpha) or 80,
                drawWorldRing = rz.drawWorldRing ~= false,
                worldRingColor = rz.worldRingColor or { r = 255, g = 50, b = 50, a = 60 },
                point = war.point,
            }
        end)(),
        state = war.capture.state, progress = war.capture.progress,
        attackersTotal = war.lastAttackersTotal or 0, defendersTotal = war.lastDefendersTotal or 0,
        attackersAlive = war.lastAttackersAlive or 0, defendersAlive = war.lastDefendersAlive or 0,
        attackersPresent = war.lastAttackers or 0, defendersPresent = war.lastDefenders or 0,
    }
end

-- Sends a message to the people in a war: both gangs and every admin.
local function eachParticipant(war, fn)
    for _, src in ipairs(Bridge.GetPlayers()) do
        local g = GangXP.GangOf(src, true)
        if g and g.name == war.attacker then fn(src, 'ATTACKER')
        elseif g and g.name == war.defender then fn(src, 'DEFENDER')
        elseif isWarStaff(src) then fn(src, 'ADMIN') end
    end
end

local function presence(war)
    local w = wcfg()
    local cap, pt = war.capture, war.point
    local presenceRadius = tonumber(w.presenceRadius) or 120.0
    local oneLifeCfg = w.oneLife or {}
    local oneLifeEnabled = oneLifeCfg.enabled ~= false
    local rzRadius = (tonumber(w.ringZone and w.ringZone.radius) or 160.0) + 30.0
    local res = {
        attackersCapture = {}, defendersCapture = {},
        attackersIn = 0, defendersIn = 0,
        attackersAlive = 0, defendersAlive = 0,
        attackersTotal = 0, defendersTotal = 0,
    }
    for _, src in ipairs(Bridge.GetPlayers()) do
        local g = GangXP.GangOf(src, true)
        if g then
            local isAttacker = (g.name == war.attacker)
            local isDefender = (g.name == war.defender)
            if isAttacker or isDefender then
                local ident = Bridge.GetIdentifier(src)
                local isEliminated = (ident and war.eliminated and war.eliminated[ident] ~= nil) or false

                if isAttacker then res.attackersTotal = res.attackersTotal + 1 end
                if isDefender then res.defendersTotal = res.defendersTotal + 1 end

                local alive = isAlive(src)
                -- Auto-detect casualty if a war participant dies during the war
                if oneLifeEnabled and not alive and not isEliminated then
                    local ped = GetPlayerPed(src)
                    local c = (ped and ped ~= 0 and DoesEntityExist(ped)) and GetEntityCoords(ped) or nil
                    local d = c and dist2d(c, pt.x, pt.y) or 99999.0
                    local inOrNear = (c and (d <= rzRadius or Territory.contains(war.territoryId, c.x, c.y) or inWarZone(war, c)))
                    if war.seen[ident] or inOrNear then
                        isEliminated = true
                        if ident and war.eliminated then
                            local charName = Bridge.GetCharacterName(src) or ('Player %d'):format(src)
                            war.eliminated[ident] = {
                                name = charName,
                                gang = g.name,
                                gangLabel = g.label,
                                time = now(),
                            }
                            TriggerClientEvent('nova_convoytruck:client:hudNotify', src, {
                                type = 'error',
                                title = 'ELIMINATED FROM WAR',
                                description = oneLifeCfg.notifyMessage or 'You died and are eliminated from this rival war! Revived players cannot re-enter the zone.',
                                duration = 10000,
                            })
                            TriggerClientEvent('nova_convoytruck:territory:client:eliminatedState', src, {
                                warId = war.id,
                                eliminated = true,
                            })
                            local msg = ('%s (%s) has fallen and is ELIMINATED from the war!'):format(charName, g.label)
                            eachParticipant(war, function(participantSrc)
                                TriggerClientEvent('nova_convoytruck:client:hudNotify', participantSrc, {
                                    type = 'warning',
                                    title = 'RIVAL CASUALTY',
                                    description = msg,
                                    duration = 6000,
                                })
                            end)
                            DiscordLog.appendEvent(war.logKey, ('💀 %s'):format(msg))
                            log(('War #%d: %s'):format(war.id, msg))
                        end
                    end
                end

                -- A player who is eliminated is NOT fightingAlive, even if revived by EMS or respawned
                local fightingAlive = alive and not isEliminated
                if fightingAlive then
                    if isAttacker then res.attackersAlive = res.attackersAlive + 1 end
                    if isDefender then res.defendersAlive = res.defendersAlive + 1 end

                    local ped = GetPlayerPed(src)
                    local c = GetEntityCoords(ped)
                    local d = dist2d(c, pt.x, pt.y)
                    local near = d <= cap.radius and (not pt.z or math.abs(c.z - pt.z) <= 12.0)
                    local inTerritory = near or d <= presenceRadius or Territory.contains(war.territoryId, c.x, c.y) or inWarZone(war, c)
                    if inTerritory then
                        if isAttacker then res.attackersIn = res.attackersIn + 1 end
                        if isDefender then res.defendersIn = res.defendersIn + 1 end
                        if ident and not war.seen[ident] then
                            war.seen[ident] = { name = Bridge.GetCharacterName(src), identifier = ident, gang = g.name, gangLabel = g.label }
                            war.seenOrder[#war.seenOrder + 1] = ident
                        end
                    end
                    if near then
                        if isAttacker then res.attackersCapture[#res.attackersCapture + 1] = src end
                        if isDefender then res.defendersCapture[#res.defendersCapture + 1] = src end
                    end
                end
            end
        end
    end
    return res
end

local function penaltyFor(row, ownerGang)
    if row.penalty_xp ~= nil then return math.max(0, math.floor(tonumber(row.penalty_xp) or 0)) end
    local p = wcfg().noShowPenalty or {}
    if tostring(p.mode or 'FLAT'):upper() == 'PERCENT' then
        return math.floor(GangXP.Total(ownerGang) * (tonumber(p.percent) or 0) / 100)
    end
    return math.max(0, math.floor(tonumber(p.xp) or 0))
end

-- ── what a war is worth ──────────────────────────────────────────────────────────
-- NOBODY LOSES A TERRITORY IN A WAR. When the winning gang loots the Leader Ped afterwards (claimLoot below) the loser pays the winner
-- Gang XP and the loser's painted land shrinks from its outer edge. The territory that shrinks is the loser's own one in this
-- challenge: the battleground if the loser owns it, else the one the loser put forward.
local NO_STAKES = 'No stakes'   -- marks a war that paid nothing (pairPlayedRecently reads it back)

local function loserTerritory(row, loser)
    if not row then return nil end
    for _, id in ipairs({ row.territory_id, row.attacker_territory_id, row.defender_territory_id }) do
        local lt = id and Territory.get(id)
        if lt and lt.owner == loser then return lt end
    end
    return nil
end

-- The same two gangs play for stakes only once per Config.Territory.war.postWarLoot.pairCooldownHours (stops two friendly gangs from
-- passing XP back and forth by throwing wars).
local function pairPlayedRecently(row, hours)
    if not row or hours <= 0 then return false end
    for _, r in ipairs(DB.rivalList(false, 60)) do
        local samePair = (r.attacker_gang == row.attacker_gang and r.defender_gang == row.defender_gang)
            or (r.attacker_gang == row.defender_gang and r.defender_gang == row.attacker_gang)
        if samePair and r.id ~= row.id and r.status == 'COMPLETED' and (r.result == 'CAPTURED' or r.result == 'DEFENDED')
            and not tostring(r.result_note or ''):find(NO_STAKES, 1, true)
            and (now() - (tonumber(r.ended_at) or 0)) < hours * 3600 then
            return true
        end
    end
    return false
end

-- The loot session is sent per player: the client only offers 'Loot Gang XP' on the leader ped when it is told it is on the winning side.
local function sendPostWarLoot(src, loot)
    local g = GangXP.GangOf(src, true)
    TriggerClientEvent('nova_convoytruck:territory:client:postWarLoot', src, loot, (g and g.name == loot.winner) == true)
end

-- Ends a war with a result: CAPTURED (the attacking side won) | DEFENDED (the defending side won) | NO_SHOW | CANCELLED.
function TerritoryWar.conclude(war, result, extra)
    if wars[war.id] ~= war then return end
    extra = extra or {}
    wars[war.id] = nil
    local row = DB.rivalGet(war.id)
    local t = Territory.get(war.territoryId)
    local tname = t and t.name or war.territoryId
    local winner, note = nil, extra.note
    local aLabel, dLabel = label(war.attacker), label(war.defender)
    local loser, lootOpen

    if result == 'CAPTURED' or result == 'DEFENDED' then
        -- the war has a winner and a loser; nobody loses a territory, the winner's loot comes after (claimLoot)
        winner = (result == 'CAPTURED') and war.attacker or war.defender
        loser = (winner == war.attacker) and war.defender or war.attacker
        local pc = wcfg().postWarLoot or {}
        local st
        if pc.enabled == false then
            st = NO_STAKES .. '.'
        elseif pairPlayedRecently(row, tonumber(pc.pairCooldownHours) or 0) then
            st = ('%s: these gangs already played for stakes in the last %d hours.'):format(NO_STAKES, tonumber(pc.pairCooldownHours) or 0)
        else
            lootOpen = true
            st = ('%s can now loot Gang XP from the Leader Ped (%d min).'):format(label(winner), tonumber(pc.windowMinutes) or 5)
        end
        extra.stakesText = st
        note = note and (note .. ' ' .. st) or st
    elseif result == 'NO_SHOW' then
        winner = t and t.owner or war.defender
        local owner = winner
        local amount = penaltyFor(row or {}, owner)
        if amount > 0 then
            local ok, res = GangXP.Penalty(owner, amount, {
                sourceType = 'TERRITORY', sourceId = war.id, sourceName = 'Territory War Penalty',
                reason = ('No-show: nobody from %s or %s was in %s when the war ended'):format(aLabel, dLabel, tname),
                dedupeKey = ('war:%d:noshow'):format(war.id),
            })
            extra.penaltyTaken = ok and res.amount or 0
        end
        note = note or ('Nobody from either gang was alive in the territory when the timer ended. %s keeps %s%s.'):format(
            label(owner), tname, (extra.penaltyTaken or 0) > 0 and (' and loses %d Gang XP'):format(extra.penaltyTaken) or '')
    end

    local status = (result == 'CANCELLED') and 'CANCELLED' or 'COMPLETED'
    DB.rivalUpdate(war.id, { status = status, result = result, result_note = note and tostring(note):sub(1, 250) or nil, winner_gang = winner, ended_at = now() })
    reload(war.id)
    Territory.setWar(war.territoryId, nil)
    Territory.broadcast({ war.territoryId }, true)

    local winnerLabel = winner and label(winner) or 'UNKNOWN'
    local title, body, bannerKey, bstatus
    if result == 'CAPTURED' then
        title = ('👑 %s IS THE BOSS!'):format(winnerLabel:upper())
        bannerKey, bstatus = 'captured', 'CAPTURED'
        body = ('%s WON THE WAR AGAINST %s OVER %s! %s'):format(winnerLabel:upper(), dLabel:upper(), tname:upper(), extra.stakesText or '')
    elseif result == 'DEFENDED' then
        title = ('👑 %s IS THE BOSS!'):format(winnerLabel:upper())
        bannerKey, bstatus = 'defended', 'DEFENDED'
        body = ('%s HELD THEIR GROUND AGAINST %s OVER %s! %s'):format(winnerLabel:upper(), aLabel:upper(), tname:upper(), extra.stakesText or '')
    elseif result == 'NO_SHOW' then
        title, bannerKey, bstatus = 'TERRITORY WAR — NO SHOW', 'noShow', 'NO SHOW'
        body = note
    else
        title, bannerKey, bstatus = 'TERRITORY WAR CANCELLED', nil, 'CANCELLED'
        body = ('The war for %s was cancelled. %s'):format(tname, note or '')
    end
    local bcfg = bannerKey and (wcfg().banners or {})[bannerKey] or {}
    local dur = bcfg.duration or 12000
    if bcfg.title and winnerLabel then
        if bcfg.title:find('%%s') then
            title = bcfg.title:format(winnerLabel:upper())
        else
            title = bcfg.title
        end
    end
    toEveryone(title, body, dur, bstatus)
    eachParticipant(war, function(src)
        TriggerClientEvent('nova_convoytruck:territory:client:warEnd', src, { warId = war.id, territoryId = war.territoryId, result = result, winner = winner, winnerLabel = winnerLabel, message = body })
    end)
    log(('War #%d ended: %s (%s)'):format(war.id, result, tostring(winner)))

    -- ── Post-War Loot Session ──────────────────────────────────────────────
    if lootOpen then
        local lootCfg = wcfg().postWarLoot or {}
        local windowSec = (tonumber(lootCfg.windowMinutes) or 5) * 60
        local lt = loserTerritory(row, loser)
        activeLoots[war.id] = {
            warId = war.id,
            territoryId = war.territoryId,          -- the ped the winners loot (the battleground's)
            loserTerritoryId = lt and lt.id or nil, -- the land that shrinks (the loser's own territory in this challenge)
            winner = winner,
            loser = loser,
            winnerLabel = label(winner),
            loserLabel = label(loser),
            point = war.point,
            expiresAt = now() + windowSec,
            looted = false,
        }
        for _, s in ipairs(Bridge.GetPlayers()) do pcall(sendPostWarLoot, s, activeLoots[war.id]) end
        toGang(winner, {
            kind = 'loot-ready',
            title = 'LOOT GANG XP AVAILABLE',
            message = ('You defeated %s! Go to the Leader Ped to Loot Gang XP (expires in %d min). Looting takes their XP and shrinks their land.'):format(label(loser), math.floor(windowSec / 60))
        }, {
            title = 'LOOT GANG XP AVAILABLE',
            body = ('Go to the Leader Ped to Loot Gang XP from %s!'):format(label(loser)),
            duration = 10000,
            status = 'VICTORY'
        })
    end

    TerritoryWar.record(war, result, { winner = winner, winnerLabel = winnerLabel, note = note, penaltyTaken = extra.penaltyTaken, territoryName = tname, capturerName = extra.capturerName })
    rivalsChanged()
end

-- Close-out of a war: the after-action report + PDF, a row in Event History (the admin tablet's History tab lists it with its
-- Report / PDF buttons, exactly like an auction) and the Discord log with the PDF attached.
function TerritoryWar.record(war, result, info)
    local ok, err = pcall(function()
        local aLabel, dLabel = label(war.attacker), label(war.defender)
        local logKey = war.logKey or ('war' .. tostring(war.id))
        local endedAt = now()
        local members = {}
        for _, ident in ipairs(war.seenOrder or {}) do members[#members + 1] = war.seen[ident] end
        DiscordLog.appendEvent(logKey, ('🏁 War over — %s%s'):format(result, info.winnerLabel and (' — winner ' .. info.winnerLabel) or ''))
        local report = ReportBuilder.territoryWar({
            id = war.id, name = ('Territory War: %s vs %s — %s'):format(aLabel, dLabel, info.territoryName or war.territoryId),
            territoryName = info.territoryName, startedAt = war.startedAtTs or war.startedAt, endedAt = endedAt,
            outcome = result == 'CANCELLED' and 'CANCELLED' or 'COMPLETED', result = result,
            attacker = war.attacker, defender = war.defender, attackerLabel = aLabel, defenderLabel = dLabel,
            winnerGang = info.winner, winnerLabel = info.winnerLabel, note = info.note, penaltyTaken = info.penaltyTaken,
            xpAwarded = info.xpAwarded, capturerName = info.capturerName,
            members = members, timeline = DiscordLog.getTimeline(logKey),
        })
        DB.insertConvoyHistory({
            convoyDefinitionId = nil, name = report.name, createdBy = 'Territory System',
            startedAt = war.startedAtTs or war.startedAt, endedAt = endedAt, duration = endedAt - (war.startedAtTs or war.startedAt),
            truckCount = 0, policeParticipants = 0, gangParticipants = #members, winningGang = info.winner,
            outcome = report.outcome, rewardSummary = report.labels and report.labels.outcomeLabel or result,
            destroyedTrucks = 0, checkpointsCompleted = 0, kind = 'GANG_TERRITORY', reportData = report,
        })
        local pdfString = nil
        if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
            pdfString = PdfGenerator.generateConvoyReport(report)
        end
        local fields = {
            { name = 'Territory', value = info.territoryName or war.territoryId, inline = true },
            { name = 'Attacker', value = aLabel, inline = true }, { name = 'Defender', value = dLabel, inline = true },
            { name = 'Result', value = result, inline = true }, { name = 'Winner', value = info.winnerLabel or '—', inline = true },
            { name = 'Present', value = tostring(#members), inline = true },
            { name = 'Note', value = tostring(info.note or '—'):sub(1, 900), inline = false },
        }
        if (info.penaltyTaken or 0) > 0 then fields[#fields + 1] = { name = 'XP penalty', value = ('-%d Gang XP'):format(info.penaltyTaken), inline = true } end
        if (info.xpAwarded or 0) > 0 then fields[#fields + 1] = { name = 'Gang XP spoils', value = ('%s +%d Gang XP%s'):format(info.winnerLabel or aLabel, info.xpAwarded, info.capturerName and (' (point held by ' .. info.capturerName .. ')') or ''), inline = true } end
        if (info.cellsLost or 0) > 0 then fields[#fields + 1] = { name = 'Land lost by the loser', value = ('-%d cells'):format(info.cellsLost), inline = true } end
        if #members > 0 then
            local lines = {}
            for i, m in ipairs(members) do
                if i > 12 then lines[#lines + 1] = ('... and %d more'):format(#members - 12) break end
                lines[#lines + 1] = ('• %s (%s)'):format(m.name or 'Player', m.gangLabel or m.gang or '?')
            end
            fields[#fields + 1] = { name = 'Players present', value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
        end
        if pdfString then fields[#fields + 1] = { name = '📄 After-Action Report (PDF)', value = 'Full war report generated and attached to this message.', inline = false } end
        DiscordLog.finishEvent(logKey, ('🗺️ [TERRITORY WAR] %s — %s vs %s'):format(result, aLabel, dLabel),
            result == 'CANCELLED' and 0x6b7280 or 0xc45ee0, fields, ('🏆 %s'):format(info.winnerLabel or result), pdfString, 'GANG_TERRITORY')
    end)
    if not ok then print(('^1[NovaConvoy][TerritoryWar] could not write the war report: %s^0'):format(tostring(err))) end
end

local function tickWar(war)
    local cap = war.capture
    local p = presence(war)
    war.lastAttackers, war.lastDefenders = p.attackersIn, p.defendersIn
    local attackersAtPoint, defendersAtPoint = #p.attackersCapture, #p.defendersCapture
    local prevState = cap.state

    if cap.armed then
        if attackersAtPoint == 0 then
            -- nobody left to hold it: after a short grace the capture is dropped and starts over
            cap.abandonFor = (cap.abandonFor or 0) + 1
            if cap.abandonFor >= (tonumber(wcfg().capture and wcfg().capture.abandonSeconds) or 8) then
                cap.armed, cap.progress, cap.state, cap.abandonFor = false, 0.0, 'IDLE', 0
            end
        else
            cap.abandonFor = 0
            if defendersAtPoint > 0 then
                cap.state = 'CONTESTED'
                if cap.rule == 'RESET' then cap.progress = 0.0
                elseif cap.rule == 'DECAY' then cap.progress = math.max(0.0, cap.progress - (tonumber(wcfg().capture and wcfg().capture.decayPerSecond) or 2.0)) end
                -- PAUSE: progress simply stays where it is
            else
                cap.state = 'CAPTURING'
                cap.progress = cap.progress + 1.0
            end
        end
    end

    if cap.state ~= prevState then
        if cap.state == 'CONTESTED' then
            DiscordLog.appendEvent(war.logKey, ('🛡️ Capture contested by %s (%d defender%s at the point)'):format(label(war.defender), defendersAtPoint, defendersAtPoint == 1 and '' or 's'))
            local b = (wcfg().banners or {}).contested or {}
            local msg = ('Defenders are contesting %s. Attackers must regain control of the capture point.'):format((Territory.get(war.territoryId) or {}).name or '')
            eachParticipant(war, function(src)
                TriggerClientEvent('nova_convoytruck:runtime:announce', src, b.title or 'TERRITORY CONTESTED', msg, b.duration or 6000, 'territory', nil, 'CONTESTED')
            end)
        end
    end

    war.lastAttackersAlive, war.lastDefendersAlive = p.attackersAlive, p.defendersAlive
    war.lastAttackersTotal, war.lastDefendersTotal = p.attackersTotal, p.defendersTotal

    eachParticipant(war, function(src, role)
        local ident = Bridge.GetIdentifier(src)
        local isElim = (ident and war.eliminated and war.eliminated[ident] ~= nil) or false
        TriggerClientEvent('nova_convoytruck:territory:client:warTick', src, {
            warId = war.id, secondsLeft = math.max(0, war.endsAt - now()), state = cap.state, progress = cap.progress,
            captureSeconds = cap.seconds,
            attackersPresent = p.attackersIn, defendersPresent = p.defendersIn,
            attackersAlive = p.attackersAlive, defendersAlive = p.defendersAlive,
            attackersTotal = p.attackersTotal, defendersTotal = p.defendersTotal,
            role = role,
            eliminated = isElim,
        })
    end)

    if cap.armed and cap.progress >= cap.seconds then
        local first = p.attackersCapture[1]
        TerritoryWar.conclude(war, 'CAPTURED', {
            capturerIdentifier = cap.capturerIdentifier or (first and Bridge.GetIdentifier(first)),
            capturerName = cap.capturerName or (first and Bridge.GetCharacterName(first)),
        })
        return
    end

    if now() >= war.endsAt then
        if p.attackersIn == 0 and p.defendersIn == 0 then
            -- nobody turned up: the owner keeps the territory and pays the no-show penalty. (It used to be decided by how many
            -- members each gang had alive ANYWHERE on the map, so a gang could win a war by staying at home.)
            TerritoryWar.conclude(war, 'NO_SHOW', { note = 'Nobody from either gang was in the territory when the timer ended.' })
        elseif p.attackersIn > p.defendersIn then
            -- Attacker has more alive fighters in the territory! A hiding player cannot stall for a win!
            TerritoryWar.conclude(war, 'CAPTURED', {
                note = ('War time expired! %s won by territory dominance (%d alive in zone vs %d for %s).'):format(label(war.attacker), p.attackersIn, p.defendersIn, label(war.defender))
            })
        elseif p.defendersIn > p.attackersIn then
            -- Defender has more alive fighters in the territory!
            TerritoryWar.conclude(war, 'DEFENDED', {
                note = ('War time expired! %s successfully defended by territory dominance (%d alive in zone vs %d for %s).'):format(label(war.defender), p.defendersIn, p.attackersIn, label(war.attacker))
            })
        else
            -- Tied count alive in territory: defender holds their turf
            TerritoryWar.conclude(war, 'DEFENDED', {
                note = ('War time expired in a tie (%d vs %d alive in territory). %s successfully defended their turf!'):format(p.defendersIn, p.attackersIn, label(war.defender))
            })
        end
        return
    end
end

local function runWar(row, remainingSeconds)
    local t = Territory.get(row.territory_id)
    local capCfg = (t and t.def.capture) or {}
    local w = wcfg().capture or {}

    -- Home turf tactical advantage: whichever gang owns the battle territory is defending it
    local isAttackerHome = t and (t.owner == row.attacker_gang)
    local warDefender = isAttackerHome and row.attacker_gang or row.defender_gang
    local warAttacker = isAttackerHome and row.defender_gang or row.attacker_gang

    local war = {
        id = row.id, territoryId = row.territory_id,
        attacker = warAttacker, defender = warDefender,
        originalChallenger = row.attacker_gang,
        seen = {}, seenOrder = {}, eliminated = {}, startedAtTs = now(), startedAt = now(),
        durationSec = tonumber(row.war_duration) or ((tonumber(wcfg().defaultDurationMinutes) or 15) * 60),
        point = capturePoint(t),
        zone = TerritoryWar.decodeZone(row.war_zone),
        capture = {
            state = 'IDLE', progress = 0.0, armed = false,
            seconds = tonumber(capCfg.seconds) or tonumber(w.seconds) or 60,
            radius = tonumber(capCfg.radius) or tonumber(w.radius) or 6.0,
            interactDistance = tonumber(capCfg.interactDistance) or tonumber(w.interactDistance) or 2.5,
            rule = tostring(capCfg.contestRule or w.contestRule or 'PAUSE'):upper(),
        },
    }
    war.endsAt = war.startedAt + (remainingSeconds or war.durationSec)
    wars[row.id] = war
    Territory.setWar(row.territory_id, row.id)
    Territory.broadcast({ row.territory_id }, true)

    local aLabel, dLabel = label(war.attacker), label(war.defender)
    local mins = math.floor((remainingSeconds or war.durationSec) / 60)
    local startBody = ('%s VS %s — %s — %02d:%02d'):format(aLabel:upper(), dLabel:upper(), t.name:upper(), mins, (remainingSeconds or war.durationSec) % 60)
    toEveryone((wcfg().banners.started or {}).title or 'TERRITORY WAR', startBody, (wcfg().banners.started or {}).duration or 10000, 'WAR')
    eachParticipant(war, function(src, role)
        TriggerClientEvent('nova_convoytruck:territory:client:warStart', src, warPayload(war, role, src))
    end)
    log(('War #%d started: %s vs %s for %s (%ds)'):format(row.id, war.attacker, war.defender, t.name, remainingSeconds or war.durationSec))
    war.logKey = 'war' .. tostring(row.id)
    DiscordLog.startEvent(war.logKey, ('🗺️ [TERRITORY WAR] %s vs %s — %s'):format(aLabel, dLabel, t.name), 0xc45ee0, 'Territory war in progress.', {
        { name = 'Territory', value = t.name, inline = true }, { name = 'Attacker', value = aLabel, inline = true }, { name = 'Defender', value = dLabel, inline = true },
        { name = 'Duration', value = ('%d min'):format(math.floor((remainingSeconds or war.durationSec) / 60)), inline = true },
    })
    DiscordLog.appendEvent(war.logKey, ('⚔️ War started — %s vs %s over %s'):format(aLabel, dLabel, t.name))
    rivalsChanged()

    CreateThread(function()
        while wars[row.id] == war do
            Wait(1000)
            if wars[row.id] ~= war then return end
            local ok, err = pcall(tickWar, war)
            if not ok then print(('^1[NovaConvoy][TerritoryWar] tick error: %s^0'):format(tostring(err))) end
        end
    end)
end

-- Starts a war now (the schedule reached it, or the admin pressed Start).
function TerritoryWar.start(row, startedBy)
    if wars[row.id] then return false, 'This war is already running.' end
    local t = Territory.get(row.territory_id)
    if not t then
        DB.rivalUpdate(row.id, { status = 'CANCELLED', result = 'VOID', result_note = 'The territory no longer exists.', ended_at = now() }, row.status)
        reload(row.id); rivalsChanged()
        return false, 'The territory no longer exists.'
    end
    if t.owner ~= row.defender_gang and t.owner ~= row.attacker_gang then
        DB.rivalUpdate(row.id, { status = 'CANCELLED', result = 'VOID', result_note = 'The territory changed hands before the war.', ended_at = now() }, row.status)
        reload(row.id); rivalsChanged()
        return false, 'The territory changed hands — the war was cancelled.'
    end
    if t.war then return false, 'Another war is already running on this territory.' end
    local duration = tonumber(row.war_duration) or ((tonumber(wcfg().defaultDurationMinutes) or 15) * 60)
    if not DB.rivalUpdate(row.id, { status = 'ACTIVE', started_at = now(), war_duration = duration }, row.status) then
        return false, 'The challenge changed in the meantime.'
    end
    row = reload(row.id)
    runWar(row)
    return true
end

function TerritoryWar.manualStart(adminSrc, rivalId)
    local row = DB.rivalGet(tonumber(rivalId))
    if not row then return false, 'Challenge not found.' end
    if row.status == 'PENDING' then   -- starting it now accepts it for the challenged gang
        local okA, errA = TerritoryWar.adminRespond(adminSrc, row.id, true)
        if not okA then return false, errA end
        row = DB.rivalGet(row.id)
    end
    if row.status ~= 'ACCEPTED' and row.status ~= 'SCHEDULED' then return false, 'Only an accepted or scheduled challenge can be started.' end
    local ok, err = TerritoryWar.start(row, Bridge.GetCharacterName(adminSrc))
    if not ok then return false, err end
    return true, TerritoryWar.view(DB.rivalGet(row.id))
end

-- ── "Take Territory" (ox_target on the leader ped, only in a live war) ───────────

RegisterNetEvent('nova_convoytruck:territory:server:beginCapture', function(warId)
    local src = source
    local war = wars[tonumber(warId)]
    local function say(msg, kind) TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = kind or 'error', title = 'TERRITORY WAR', description = msg }) end
    if not war then return say('There is no war running here.') end
    local gang = GangXP.GangOf(src, true, true)
    if not gang or gang.name ~= war.attacker then return say('Only the attacking gang can take this territory.') end
    if not isAlive(src) then return say('You cannot capture while down.') end
    local ident = Bridge.GetIdentifier(src)
    if ident and war.eliminated and war.eliminated[ident] then return say('You were eliminated from this war and cannot capture!') end
    local cap = war.capture
    local c = GetEntityCoords(GetPlayerPed(src))
    if dist2d(c, war.point.x, war.point.y) > cap.interactDistance + 4.0 then return say('Get closer to the territory leader.') end
    if cap.armed then return say('The territory is already being taken.', 'inform') end

    cap.armed, cap.state, cap.progress, cap.abandonFor = true, 'CAPTURING', 0.0, 0
    cap.capturerIdentifier, cap.capturerName = ident, Bridge.GetCharacterName(src)
    local tname = (Territory.get(war.territoryId) or {}).name or ''
    eachParticipant(war, function(member)
        TriggerClientEvent('nova_convoytruck:territory:client:notify', member, {
            kind = 'capture', title = 'TAKING TERRITORY...', message = ('%s is taking %s. Defenders: get to the capture point and contest it!'):format(label(war.attacker), tname),
        })
    end)
    log(('War #%d: %s started the capture'):format(war.id, cap.capturerName or '?'))
    DiscordLog.appendEvent(war.logKey, ('🚩 %s (%s) began taking the territory'):format(cap.capturerName or '?', label(war.attacker)))
end)

-- ── Combat Ring Out-of-Bounds Desertion / Elimination ───────────────────────────

RegisterNetEvent('nova_convoytruck:territory:server:outOfBoundsEliminated', function(warId)
    local src = source
    local war = wars[tonumber(warId)]
    if not war then return end
    local g = GangXP.GangOf(src, true, true)
    if not g or (g.name ~= war.attacker and g.name ~= war.defender) then return end

    local ident = Bridge.GetIdentifier(src)
    local charName = Bridge.GetCharacterName(src) or ('Player %d'):format(src)
    if ident and war.eliminated then
        war.eliminated[ident] = {
            name = charName,
            gang = g.name,
            gangLabel = g.label,
            time = now(),
        }
    end

    local ped = GetPlayerPed(src)
    if ped and DoesEntityExist(ped) and GetEntityHealth(ped) > 0 then
        SetEntityHealth(ped, 0)
    end

    TriggerClientEvent('nova_convoytruck:territory:client:eliminatedState', src, {
        warId = war.id,
        eliminated = true,
    })

    local msg = ('%s (%s) was ELIMINATED for deserting the rival zone!'):format(charName, g.label)
    eachParticipant(war, function(participantSrc)
        TriggerClientEvent('nova_convoytruck:client:hudNotify', participantSrc, {
            type = 'error',
            title = 'RIVAL ZONE ELIMINATION',
            description = msg,
            duration = 8000,
        })
    end)
    DiscordLog.appendEvent(war.logKey, ('💀 %s'):format(msg))
    log(('War #%d: %s'):format(war.id, msg))
end)

-- ── One-Life Casualty Elimination NetEvent ─────────────────────────────────────

RegisterNetEvent('nova_convoytruck:territory:server:playerDiedInWar', function(warId)
    local src = source
    local war = wars[tonumber(warId)]
    if not war then return end
    local g = GangXP.GangOf(src, true, true)
    if not g or (g.name ~= war.attacker and g.name ~= war.defender) then return end
    local ident = Bridge.GetIdentifier(src)
    if not ident or not war.eliminated or war.eliminated[ident] then return end

    local charName = Bridge.GetCharacterName(src) or ('Player %d'):format(src)
    war.eliminated[ident] = {
        name = charName,
        gang = g.name,
        gangLabel = g.label,
        time = now(),
    }

    TriggerClientEvent('nova_convoytruck:territory:client:eliminatedState', src, {
        warId = war.id,
        eliminated = true,
    })

    local msg = ('%s (%s) has fallen and is ELIMINATED from the war!'):format(charName, g.label)
    eachParticipant(war, function(participantSrc)
        TriggerClientEvent('nova_convoytruck:client:hudNotify', participantSrc, {
            type = 'warning',
            title = 'RIVAL CASUALTY',
            description = msg,
            duration = 6000,
        })
    end)
    DiscordLog.appendEvent(war.logKey, ('💀 %s'):format(msg))
    log(('War #%d: %s'):format(war.id, msg))
end)

-- A player who joined / reconnected during a war gets the war they belong to.
-- A player who joined / reconnected / switched character gets the war they belong to (also called after a character loads).
function TerritoryWar.syncPlayer(src)
    local g = GangXP.GangOf(src, true, true)
    local admin = isWarStaff(src)
    for _, war in pairs(wars) do
        local role = admin and 'ADMIN'
        if g and g.name == war.attacker then role = 'ATTACKER' elseif g and g.name == war.defender then role = 'DEFENDER' end
        if role then TriggerClientEvent('nova_convoytruck:territory:client:warStart', src, warPayload(war, role, src)) end
    end
    for _, loot in pairs(activeLoots) do
        if not loot.looted and now() <= loot.expiresAt then
            pcall(sendPostWarLoot, src, loot)
        end
    end
end

RegisterNetEvent('nova_convoytruck:territory:server:requestWarSync', function()
    TerritoryWar.syncPlayer(source)
end)

RegisterNetEvent('nova_convoytruck:territory:server:claimLoot', function(warId)
    local src = source
    local loot = activeLoots[tonumber(warId)]
    if not loot then
        TriggerClientEvent('nova_convoytruck:territory:client:notify', src, {
            kind = 'error', title = 'GANG LEADER', message = 'No active loot available on this ped.'
        })
        return
    end
    if loot.looted then
        TriggerClientEvent('nova_convoytruck:territory:client:notify', src, {
            kind = 'error', title = 'GANG LEADER', message = 'This leader has already been looted!'
        })
        return
    end
    if now() > loot.expiresAt then
        TriggerClientEvent('nova_convoytruck:territory:client:notify', src, {
            kind = 'error', title = 'GANG LEADER', message = 'The post-war loot window has expired.'
        })
        return
    end
    if loot.claiming then return end   -- another winner is already claiming (the lookup below can yield)
    loot.claiming = true
    local gang = GangXP.GangOf(src, true)
    if not gang or gang.name ~= loot.winner then
        loot.claiming = false
        TriggerClientEvent('nova_convoytruck:territory:client:notify', src, {
            kind = 'error', title = 'GANG LEADER', message = (wcfg().postWarLoot or {}).tauntMessage or 'Better luck next time "lilBro"'
        })
        return
    end

    local ped = GetPlayerPed(src)
    local c = GetEntityCoords(ped)
    local d = dist2d(c, loot.point.x, loot.point.y)
    if d > 15.0 then
        loot.claiming = false
        TriggerClientEvent('nova_convoytruck:territory:client:notify', src, {
            kind = 'error', title = 'GANG LEADER', message = 'You are too far from the Leader Ped.'
        })
        return
    end

    loot.looted = true
    local pcfg = (wcfg().postWarLoot) or {}
    local loserTotal = GangXP.Total(loot.loser)
    local pct = tonumber(pcfg.lootXpPercent) or 20
    local amount = math.floor(loserTotal * (pct / 100))
    amount = math.max(tonumber(pcfg.minLootXp) or 500, math.min(tonumber(pcfg.maxLootXp) or 25000, amount))
    if loserTotal > 0 and amount > loserTotal then amount = loserTotal end

    local ident = Bridge.GetIdentifier(src)
    local name = Bridge.GetCharacterName(src)

    if amount > 0 then
        -- what the loser really had is what moves: the winner is paid exactly what was taken (the minimum loot amount no longer
        -- creates XP out of nothing for a loser with little or none)
        local okP, resP = GangXP.Penalty(loot.loser, amount, {
            sourceType = 'TERRITORY', sourceId = loot.warId, sourceName = 'Territory War Defeat',
            reason = ('Raid Defeat: %d XP looted by %s'):format(amount, loot.winnerLabel),
            dedupeKey = ('war:%d:loot:penalty'):format(loot.warId),
        })
        local taken = (okP and type(resP) == 'table' and tonumber(resP.amount)) or 0
        amount = taken
        if taken > 0 then
            GangXP.Award(loot.winner, taken, {
                identifier = ident, playerName = name,
                sourceType = 'TERRITORY', sourceId = loot.warId, sourceName = 'Territory War Spoils',
                reason = ('Looted %d XP from %s'):format(taken, loot.loserLabel),
                dedupeKey = ('war:%d:loot:award'):format(loot.warId),
            })
        end
    end

    -- Shrink the LOSER's painted land. Nobody loses a territory: the loser keeps it, its owner and its ped; only the coloured zone
    -- gets smaller. It is the loser's own territory in this challenge (not necessarily the one the war was fought on).
    local shrinkPct = tonumber(pcfg.zoneShrinkPercent) or 25
    local shrunk, cellsLost = false, 0
    local tShr = loot.loserTerritoryId and Territory.get(loot.loserTerritoryId)
    if tShr and tShr.owner == loot.loser then
        local okS, removed = Territory.shrinkZone(tShr.id, shrinkPct, pcfg.minCellsLeft, loot.warId)
        if okS and removed > 0 then shrunk, cellsLost = true, removed
        elseif not okS then log(('War #%d: the loser\'s land could not shrink (%s)'):format(loot.warId, tostring(removed))) end
    end

    -- Discord: the post-war loot is part of the war's outcome (XP moves between the gangs and the loser's zone shrinks)
    do
        local tInfo = tShr or Territory.get(loot.territoryId)
        DiscordLog.send(('💰 [TERRITORY WAR] Post-war loot — %s'):format(tInfo and tInfo.name or loot.territoryId), nil, 0xc45ee0, {
            { name = 'Territory', value = tInfo and tInfo.name or tostring(loot.territoryId), inline = true },
            { name = 'Winner', value = tostring(loot.winnerLabel or loot.winner), inline = true },
            { name = 'Loser', value = tostring(loot.loserLabel or loot.loser), inline = true },
            { name = 'Gang XP looted', value = amount > 0 and ('+%d XP to %s, -%d XP from %s'):format(amount, loot.winnerLabel or loot.winner, amount, loot.loserLabel or loot.loser) or 'None (the loser had no XP)', inline = false },
            { name = 'Looted by', value = ('%s\n`%s`'):format(name or 'Unknown', ident or 'N/A'), inline = true },
            { name = 'Loser land lost', value = shrunk and ('-%d cells'):format(cellsLost) or 'none', inline = true },
        })
    end

    -- Server-wide announcement
    local bcfg = (wcfg().banners or {}).looted or {}
    local title = (tostring(bcfg.title or 'TERRITORY RAID SPOILS'):gsub('%%s', function() return tostring(loot.winnerLabel or ''):upper() end))
    local body = ('%s looted %d Gang XP from %s!%s'):format(
        tostring(loot.winnerLabel):upper(), amount, tostring(loot.loserLabel):upper(), shrunk and (' ' .. tostring(loot.loserLabel) .. ' lost ' .. cellsLost .. ' cells of land.') or ''
    )
    toEveryone(title, body, bcfg.duration or 12000, 'LOOTED')

    TriggerClientEvent('nova_convoytruck:territory:client:lootFinished', -1, loot.warId)
    activeLoots[loot.warId] = nil
    log(('War #%d: %s looted %d XP from %s, %d cells of land lost'):format(loot.warId, loot.winner, amount, loot.loser, cellsLost))
end)

function TerritoryWar.hasLive() return next(wars) ~= nil end

-- A territory was sold, handed over or deleted: every open challenge whose battleground no longer belongs to either of its two gangs
-- is void (it would only block the territory and the gang's open slots until it expired). A running war cannot reach here: nothing
-- may change hands during one. Territory calls this (the tablets are told by Territory itself).
function TerritoryWar.voidStale()
    for id, row in pairs(open) do
        if row.status ~= 'ACTIVE' then
            local t = Territory.get(row.territory_id)
            if not t or (t.owner ~= row.defender_gang and t.owner ~= row.attacker_gang) then
                if DB.rivalUpdate(id, { status = 'CANCELLED', result = 'VOID', result_note = 'The territory changed hands.', ended_at = now() }, row.status) then
                    reload(id)
                    local msg = ('The challenge for %s was cancelled: the territory changed hands.'):format(t and t.name or row.territory_id)
                    toGang(row.attacker_gang, { kind = 'war-cancelled', title = 'CHALLENGE CANCELLED', rivalId = id, message = msg })
                    toGang(row.defender_gang, { kind = 'war-cancelled', title = 'CHALLENGE CANCELLED', rivalId = id, message = msg })
                end
            end
        end
    end
end

-- ── scheduler (reminders, due wars, expiring challenges) ─────────────────────────

local function poll()
    local t = now()
    for id, row in pairs(open) do
        if row.status == 'SCHEDULED' and row.war_at then
            local warAt = tonumber(row.war_at)
            local utcNow = Scheduler.nowUtc()
            local graceSec = (tonumber(wcfg().lateStartGraceMinutes) or 10) * 60
            if warAt <= utcNow - graceSec and not wars[id] then
                -- the war time passed long ago (the server was down at its time): nobody was told it was starting, so it must not
                -- start now and charge a no-show penalty. It goes back to "accepted" and an admin schedules it again.
                if DB.rivalUpdate(id, { status = 'ACCEPTED', war_at = false, war_duration = false, scheduled_by = false }, 'SCHEDULED') then
                    reload(id)
                    local msg = ('The war between %s and %s missed its start time (the server was offline). An admin will schedule it again.'):format(label(row.attacker_gang), label(row.defender_gang))
                    toGang(row.attacker_gang, { kind = 'war-cancelled', title = 'WAR MISSED ITS TIME', rivalId = id, message = msg })
                    toGang(row.defender_gang, { kind = 'war-cancelled', title = 'WAR MISSED ITS TIME', rivalId = id, message = msg })
                    toAdmins({ kind = 'rival-admin', title = 'WAR MISSED ITS TIME', message = msg })
                    log(('War #%d missed its start time — back to ACCEPTED'):format(id))
                    rivalsChanged()
                end
            elseif warAt <= utcNow and not wars[id] then
                local ok, err = TerritoryWar.start(row, 'schedule')
                if not ok then log(('Scheduled war #%d could not start: %s'):format(id, tostring(err))) end
            else
                -- "both gangs are responsible for being present": reminders before the war starts
                for _, minutes in ipairs(wcfg().reminderMinutes or {}) do
                    local key = id .. ':' .. minutes
                    if not reminded[key] and utcNow >= warAt - minutes * 60 and utcNow < warAt then
                        reminded[key] = true
                        local tr = Territory.get(row.territory_id)
                        local msg = ('%s VS %s over %s starts in %d minute%s. Both gangs are responsible for being present.'):format(
                            label(row.attacker_gang), label(row.defender_gang), tr and tr.name or row.territory_id, minutes, minutes == 1 and '' or 's')
                        local b = (wcfg().banners or {}).reminder or {}
                        local banner = { title = (b.title or 'TERRITORY WAR IN %d MIN'):format(minutes), body = msg, duration = b.duration or 10000, status = 'REMINDER' }
                        toGang(row.attacker_gang, { kind = 'war-reminder', title = banner.title, rivalId = id, message = msg }, banner)
                        toGang(row.defender_gang, { kind = 'war-reminder', title = banner.title, rivalId = id, message = msg }, banner)
                    end
                end
            end
        elseif row.status == 'ACCEPTED' then
            -- accepted but never scheduled by an admin: it must not hold one of the gang's open slots (and block the territory) forever
            local expireA = tonumber(rcfg().acceptedExpireSeconds) or 259200
            local since = tonumber(row.responded_at) or tonumber(row.created_at) or t
            if expireA > 0 and t - since > expireA then
                if DB.rivalUpdate(id, { status = 'CANCELLED', result = 'EXPIRED', result_note = 'No war was scheduled in time.', ended_at = t }, 'ACCEPTED') then
                    reload(id)
                    rivalsChanged()
                end
            end
        elseif row.status == 'PENDING' then
            local expire = tonumber(rcfg().expireSeconds) or 0
            if expire > 0 and t - (tonumber(row.created_at) or t) > expire then
                if DB.rivalUpdate(id, { status = 'CANCELLED', result = 'EXPIRED', result_note = 'Nobody answered the challenge in time.', ended_at = t }, 'PENDING') then
                    reload(id)
                    rivalsChanged()
                end
            end
        end
    end
    for id, loot in pairs(activeLoots) do
        if not loot.looted and t > loot.expiresAt then
            activeLoots[id] = nil
            TriggerClientEvent('nova_convoytruck:territory:client:lootFinished', -1, id)
        end
    end
end

CreateThread(function()
    while true do
        Wait(5000)
        if Territory.isReady() then
            local ok, err = pcall(poll)
            if not ok then print(('^1[NovaConvoy][TerritoryWar] poll error: %s^0'):format(tostring(err))) end
        end
    end
end)

-- ── boot ─────────────────────────────────────────────────────────────────────────

function TerritoryWar.load()
    open = {}
    for _, row in ipairs(DB.rivalList(true, 500)) do open[row.id] = row end
    -- a war that was running when the resource stopped: resume it with the time it has left, or close it if it ran out
    for id, row in pairs(open) do
        if row.status == 'ACTIVE' then
            local endsAt = (tonumber(row.started_at) or now()) + (tonumber(row.war_duration) or 900)
            local remaining = endsAt - now()
            if remaining > 20 and Territory.get(row.territory_id) then
                runWar(row, remaining)
                log(('War #%d resumed after a restart (%ds left)'):format(id, remaining))
            else
                DB.rivalUpdate(id, { status = 'CANCELLED', result = 'VOID', result_note = 'The server restarted during the war.', ended_at = now() }, 'ACTIVE')
                reload(id)
            end
        end
    end
    log(('Loaded %d open challenge(s).'):format((function() local n = 0 for _ in pairs(open) do n = n + 1 end return n end)()))
end

return TerritoryWar
