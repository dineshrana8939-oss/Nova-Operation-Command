-- ─── Nova Convoy — Operation Crackdown (event runtime) ─────────────────────────
-- Server-only. The runtime of the CRACKDOWN event kind: ONE gang against the police on duty, inside a combat zone (a circle or a
-- square the admin placed). It is a hard push from both sides — there are NO points:
--   * a fighter who DIES (the framework / medical script says they are down or dead) is ELIMINATED from the operation. They then
--     respawn or are revived by EMS like any other player, but they are out: they no longer count, and they cannot shoot inside the zone.
--   * a fighter who stays OUTSIDE the zone for the event's "outside seconds" is eliminated too (nobody is killed or moved).
--   * the operation is won by the side that still has fighters when the other side has none. If time runs out, the side with more
--     fighters still standing wins; equal numbers (or both sides wiped out together) are a DRAW and nobody is paid.
-- Nothing is forced on anybody: no team picking, no teleporting. Who fights:
--   * police = a police job AND on duty right now (Bridge.IsPoliceOnDuty);  gang = the online members of the event's target gang
--     (an on-duty officer who is also in that gang fights for the police).
--   * the roster is taken during PREP and LOCKED when the fight opens: someone who arrives after that does not join, and a fighter
--     who goes off duty / leaves the server for longer than the grace period is eliminated.
--
--   phases:  PREP (countdown, both sides gather) -> ACTIVE (the fight) -> ENDED
--   reused:  Bridge duty/job checks, GangXP (membership + penalty), RewardService, DiscordLog, ReportBuilder/PdfGenerator,
--            DB.insertConvoyHistory, the Rival War out-of-zone overlay, the runtime announcement banner.

Crackdown = {}

local active = {}   -- [eventId] = rt
local EVT = 'nova_convoytruck:crackdown:client:'

local function cfg() return Config.Crackdown or {} end
local function now() return os.time() end

local function log(id, msg)
    print(('[NovaConvoy][Crackdown #%s] %s'):format(tostring(id), tostring(msg)))
end

local function clock(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return ('%d:%02d'):format(math.floor(sec / 60), sec % 60)
end

-- the announcement texts live in Config.Crackdown.messages (config.lua); {name} {gang} {minutes} {prep} are filled in
local function say(rt, key, vars)
    local raw = (cfg().messages and cfg().messages[key]) or ''
    vars = vars or {}
    vars.name = vars.name or rt.def.name
    vars.gang = vars.gang or rt.gangLabel
    return (raw:gsub('{(%w+)}', function(k) return tostring(vars[k] or '') end))
end

local function announce(rt, title, body, duration, status)
    if rt.def.settings and rt.def.settings.announcements == false then return end
    for _, src in ipairs(Bridge.GetPlayers()) do
        TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body, duration, 'crackdown', nil, status)
    end
end

-- Same "is this player down" rule Rival Wars uses: the framework / medical flags, or the ped at the GTA dead-health line.
local function isAlive(src)
    local st = Player(src).state
    if st.isDead == true or st.dead == true or st.isDowned == true or st.inLastStand == true then return false end
    local v = st.convoyVitals
    if type(v) == 'table' and v.dead then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return GetEntityHealth(ped) > 100
end

local function inZone(zone, x, y)
    local c = zone and zone.center
    if not c then return true end
    local dx, dy = x - c.x, y - c.y
    if zone.shape == 'square' then
        local h = tonumber(zone.size) or 100.0
        return math.abs(dx) <= h and math.abs(dy) <= h
    end
    local r = tonumber(zone.radius) or 100.0
    return (dx * dx + dy * dy) <= r * r
end

-- point in polygon (ray casting); pts = { {x,y}, ... }
local function inPoly(pts, x, y)
    local inside, j = false, #pts
    for i = 1, #pts do
        local a, b = pts[i], pts[j]
        if (a.y > y) ~= (b.y > y) and x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x then inside = not inside end
        j = i
    end
    return inside
end

-- the start area of a side (nil = none drawn for that side)
local function startAreaOf(rt, side)
    return rt.startZones and rt.startZones[side == 'POLICE' and 'police' or 'gang'] or nil
end

-- which side a player fights for right now (nil = not a fighter). Police first: an officer in the target gang is police.
local function sideOf(rt, src)
    if Bridge.IsPoliceOnDuty(src) then return 'POLICE' end
    local g = GangXP.GangOf(src, true)
    if g and g.name == rt.gang then return 'GANG' end
    return nil
end

local function sideLabel(rt, side)
    return side == 'POLICE' and 'Police' or rt.gangLabel
end

-- fighters of a side: how many are on the roster, how many are still standing (not eliminated)
local function tally(rt)
    local t = { GANG = { total = 0, standing = 0, online = 0 }, POLICE = { total = 0, standing = 0, online = 0 } }
    for _, rec in pairs(rt.players) do
        local s = t[rec.side]
        s.total = s.total + 1
        if not rec.eliminated then s.standing = s.standing + 1 end
        if rec.src and rec.here then s.online = s.online + 1 end
    end
    return t
end

function Crackdown.isActive(id) return active[id] ~= nil end
function Crackdown.get(id) return active[id] end
function Crackdown.getActiveIds()
    local list = {}
    for id in pairs(active) do list[#list + 1] = id end
    return list
end

function Crackdown.isParticipant(id, src)
    local rt = active[id]
    if not rt then return false end
    local ident = Bridge.GetIdentifier(src)
    return ident ~= nil and rt.players[ident] ~= nil
end

-- The shape the Event Status "Events" list reads for a live event.
function Crackdown.getPublicState(id)
    local rt = active[id]
    if not rt then return nil end
    local t = tally(rt)
    return {
        id = rt.id, name = rt.def.name, status = 'ACTIVE', kind = 'CRACKDOWN', reward = rt.def.reward,
        currentRouteIndex = 0, totalRoutePoints = 0,
        deliveryTimeRemaining = rt.phase == 'PREP' and math.max(0, rt.prepEndsAt - now()) or math.max(0, rt.endsAt - now()),
        crackdown = { phase = rt.phase, gang = rt.gangLabel, gangStanding = t.GANG.standing, policeStanding = t.POLICE.standing },
        policeParticipants = t.POLICE.total, gangParticipants = t.GANG.total,
    }
end

-- ── what the clients get ────────────────────────────────────────────────────────

local function staticPayload(rt, side)
    return {
        id = rt.id, name = rt.def.name, gang = rt.gang, gangLabel = rt.gangLabel, side = side,
        zone = rt.zone, outsideSeconds = rt.cd.outsideSeconds, startZones = rt.startZones,
        warning = say(rt, 'warning'),
    }
end

local function tickPayload(rt, m, t)
    local left
    if rt.phase == 'ACTIVE' and m.alive and not m.inside and not m.rec.eliminated then
        left = math.max(0, rt.cd.outsideSeconds - (m.rec.outsideSec or 0))
    end
    return {
        id = rt.id, phase = rt.phase, side = m.side,
        secondsLeft = rt.phase == 'PREP' and math.max(0, rt.prepEndsAt - now()) or math.max(0, rt.endsAt - now()),
        gangStanding = t.GANG.standing, gangTotal = t.GANG.total, policeStanding = t.POLICE.standing, policeTotal = t.POLICE.total,
        gangLabel = rt.gangLabel, name = rt.def.name,
        inside = m.inside, outsideLeft = left, alive = m.alive, hasStart = m.hasStart, inStart = m.inStart,
        eliminated = m.rec.eliminated == true, eliminatedReason = m.rec.eliminatedReason,
        kills = m.rec.kills,
        feed = rt.feed,
    }
end

local function pushFeed(rt, text)
    rt.feed[#rt.feed + 1] = { t = now(), text = text }
    while #rt.feed > 5 do table.remove(rt.feed, 1) end
end

-- ── eliminations ────────────────────────────────────────────────────────────────

local function eliminate(rt, rec, reason)
    if rec.eliminated then return end
    rec.eliminated = true
    rec.eliminatedAt = now()
    rec.eliminatedReason = reason
    rec.outsideSec = 0
    local line = ('%s (%s) is ELIMINATED — %s'):format(rec.name or 'Player', sideLabel(rt, rec.side), reason)
    pushFeed(rt, line)
    DiscordLog.appendEvent(rt.id, '💀 ' .. line)
    log(rt.id, line)
    if rec.src and GetPlayerName(rec.src) then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', rec.src, {
            type = 'error', title = 'ELIMINATED', description = ('You are out of Operation Crackdown (%s). You can respawn or be revived, but you cannot fight on.'):format(reason), duration = 9000,
        })
    end
end

-- ── the close-out: report, history, PDF, Discord ────────────────────────────────

local RESULT_TEXT = { GANG = 'Gang victory', POLICE = 'Police victory', DRAW = 'Draw', NO_CONTEST = 'No contest', CANCELLED = 'Cancelled' }

local function buildReport(rt, result, reason, forcedByName)
    local players = {}
    for _, ident in ipairs(rt.order) do players[#players + 1] = rt.players[ident] end
    -- survivors first, then by who stayed in the fight longest
    table.sort(players, function(a, b)
        local ae, be = a.eliminated and 1 or 0, b.eliminated and 1 or 0
        if ae ~= be then return ae < be end
        if a.eliminated and b.eliminated and a.eliminatedAt ~= b.eliminatedAt then return (a.eliminatedAt or 0) > (b.eliminatedAt or 0) end
        return (a.kills or 0) > (b.kills or 0)
    end)
    local t = tally(rt)
    local winnerLabel = (result == 'GANG' and rt.gangLabel) or (result == 'POLICE' and 'Police') or nil
    return ReportBuilder.crackdown({
        id = rt.id, name = rt.def.name, startedAt = rt.startedAt, endedAt = now(), fightStartedAt = rt.fightStartedAt,
        outcome = (result == 'CANCELLED' or result == 'NO_CONTEST') and 'CANCELLED' or 'COMPLETED',
        result = result, reason = reason, gang = rt.gang, gangLabel = rt.gangLabel,
        standing = { GANG = t.GANG.standing, POLICE = t.POLICE.standing }, totals = { GANG = t.GANG.total, POLICE = t.POLICE.total },
        winnerLabel = winnerLabel, players = players, timeline = DiscordLog.getTimeline(rt.id),
        startedByName = rt.startedByName, forcedByName = forcedByName, rewardsText = rt.rewardsText,
        zoneText = rt.zoneText, penaltyXp = rt.penaltyXp,
    }), winnerLabel
end

local function recordEnd(rt, result, reason, forcedByName)
    local report, winnerLabel = buildReport(rt, result, reason, forcedByName)
    local t = tally(rt)
    DB.insertConvoyHistory({
        convoyDefinitionId = rt.id, name = rt.def.name, createdBy = rt.def.createdByName or 'System',
        startedAt = rt.startedAt, endedAt = now(), duration = now() - rt.startedAt,
        truckCount = 0, policeParticipants = t.POLICE.total, gangParticipants = t.GANG.total,
        winningGang = result == 'GANG' and rt.gang or nil, outcome = report.outcome,
        rewardSummary = report.rewards ~= 'None' and report.rewards or (RESULT_TEXT[result] or result),
        destroyedTrucks = 0, checkpointsCompleted = 0, kind = 'CRACKDOWN', reportData = report,
    })
    local fields = {
        { name = 'Event Tag', value = '[OPERATION CRACKDOWN] 🚔', inline = true },
        { name = 'Operation', value = rt.def.name, inline = true },
        { name = 'Result', value = RESULT_TEXT[result] or result, inline = true },
        { name = 'Still standing', value = ('%s %d / %d — Police %d / %d'):format(rt.gangLabel, t.GANG.standing, t.GANG.total, t.POLICE.standing, t.POLICE.total), inline = true },
        { name = 'Winner', value = winnerLabel or '—', inline = true },
        { name = 'Duration', value = report.durationText or '-', inline = true },
    }
    if reason and reason ~= '' then fields[#fields + 1] = { name = 'Ended because', value = tostring(reason):sub(1, 300), inline = false } end
    if forcedByName then fields[#fields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true } end
    do
        local lines = {}
        for i, p in ipairs(report.crackdownPlayers or {}) do
            if i > 14 then lines[#lines + 1] = '...' break end
            lines[#lines + 1] = ('%s %s (%s) — %s'):format(p.eliminated and '💀' or '✅', p.name or 'Player', p.side == 'POLICE' and 'Police' or rt.gangLabel,
                p.eliminated and (p.eliminatedReason or 'eliminated') or 'survived')
        end
        if #lines > 0 then fields[#fields + 1] = { name = 'Fighters', value = table.concat(lines, '\n'):sub(1, 1000), inline = false } end
    end
    if report.rewards and report.rewards ~= 'None' then fields[#fields + 1] = { name = 'Rewards / penalties', value = tostring(report.rewards):sub(1, 900), inline = false } end
    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(report)
    end
    if pdfString then fields[#fields + 1] = { name = '📄 After-Action Report (PDF)', value = 'Full report generated and attached to this message.', inline = false } end
    local color = (result == 'CANCELLED' or result == 'NO_CONTEST') and 0x6b7280 or (result == 'POLICE' and 0x4f94e6 or (result == 'GANG' and 0xe5484d or 0xd6a21d))
    DiscordLog.finishEvent(rt.id, ('🚔 [OPERATION CRACKDOWN] %s — %s'):format(RESULT_TEXT[result] or result, rt.def.name),
        color, fields, ('🏆 %s | %s'):format(winnerLabel or RESULT_TEXT[result] or result, report.durationText or '-'), pdfString, 'CRACKDOWN')
end

-- ── rewards and penalties ───────────────────────────────────────────────────────

-- everyone of that side who fought and is online now (eliminated fighters are paid too: they took part)
local function sourcesOf(rt, side)
    local list = {}
    for _, ident in ipairs(rt.order) do
        local p = rt.players[ident]
        if p.side == side and p.src and GetPlayerName(p.src) and Bridge.GetIdentifier(p.src) == ident then list[#list + 1] = p.src end
    end
    return list
end

local function payOut(rt, result)
    local texts = {}
    if result == 'GANG' then
        local recipients = sourcesOf(rt, 'GANG')
        if #recipients > 0 and rt.def.reward and #rt.def.reward > 0 then
            RewardService.GrantGangReward(rt.gang, rt.def, recipients, rt.gangLabel,
                { event = 'crackdown', title = 'CRACKDOWN VICTORY', runId = rt.runId, xpPhase = 'crackdown' }, rt.def.reward)
            texts[#texts + 1] = ('%s: %s (to %d member%s)'):format(rt.gangLabel, RewardService.describeRewards(rt.def.reward), #recipients, #recipients == 1 and '' or 's')
        end
    elseif result == 'POLICE' then
        local recipients = sourcesOf(rt, 'POLICE')
        if #recipients > 0 and rt.cd.policeReward and #rt.cd.policeReward > 0 then
            RewardService.GrantGangReward(nil, rt.def, recipients, 'Police',
                { event = 'crackdown', title = 'CRACKDOWN VICTORY', runId = rt.runId, xpPhase = 'crackdown-police' }, rt.cd.policeReward)
            texts[#texts + 1] = ('Police: %s (to %d officer%s)'):format(RewardService.describeRewards(rt.cd.policeReward), #recipients, #recipients == 1 and '' or 's')
        end
        local pen = tonumber(rt.cd.gangLoseXpPenalty) or 0
        if pen > 0 then
            local ok, res = GangXP.Penalty(rt.gang, pen, {
                sourceType = 'CRACKDOWN', sourceId = rt.id, sourceName = 'Operation Crackdown Penalty',
                reason = ('Lost Operation Crackdown "%s" to the police'):format(rt.def.name),
                dedupeKey = ('crackdown:%d:%d'):format(rt.id, rt.runId or 0),
            })
            rt.penaltyXp = ok and res.amount or 0
            if (rt.penaltyXp or 0) > 0 then texts[#texts + 1] = ('%s lost %d Gang XP'):format(rt.gangLabel, rt.penaltyXp) end
        end
    end
    rt.rewardsText = #texts > 0 and table.concat(texts, ' | ') or 'None'
end

-- ── the end ─────────────────────────────────────────────────────────────────────

local function finish(rt, result, reason, forcedByName)
    if active[rt.id] ~= rt or rt.phase == 'ENDED' then return end
    rt.phase = 'ENDED'
    log(rt.id, ('Finished: %s (%s)'):format(result, tostring(reason)))
    -- payments first (they feed the report); nothing here may keep the event alive if it throws
    local okPay, errPay = pcall(payOut, rt, result)
    if not okPay then print(('^1[NovaConvoy][Crackdown] payout failed: %s^0'):format(tostring(errPay))) end
    DiscordLog.appendEvent(rt.id, ('🏁 Over — %s%s'):format(RESULT_TEXT[result] or result, reason and (' (' .. tostring(reason) .. ')') or ''))
    local okRec, errRec = pcall(recordEnd, rt, result, reason, forcedByName)
    if not okRec then print(('^1[NovaConvoy][Crackdown] report failed: %s^0'):format(tostring(errRec))) end
    active[rt.id] = nil
    ConvoyManager.setStatus(rt.id, (result == 'CANCELLED' or result == 'NO_CONTEST') and 'CANCELLED' or 'COMPLETED')

    local t = tally(rt)
    local title, body, status
    local left = ('%s %d left — Police %d left.'):format(rt.gangLabel, t.GANG.standing, t.POLICE.standing)
    if result == 'GANG' then
        title, status, body = say(rt, 'winGang'), 'GANG WINS', ('%s %s'):format(left, reason or '')
    elseif result == 'POLICE' then
        title, status, body = say(rt, 'winPolice'), 'POLICE WIN', ('%s %s'):format(left, reason or '')
    elseif result == 'DRAW' then
        title, status, body = say(rt, 'draw'), 'DRAW', ('%s %s'):format(left, reason or '')
    else
        title, status, body = say(rt, 'cancelled'), 'CANCELLED', reason or ('"%s" was called off.'):format(rt.def.name)
    end
    announce(rt, title, body, 12000, status)
    local winnerLabel = (result == 'GANG' and rt.gangLabel) or (result == 'POLICE' and 'Police') or nil
    for src in pairs(rt.sent) do
        TriggerClientEvent(EVT .. 'end', src, { id = rt.id, result = result, winnerLabel = winnerLabel, message = body })
    end
    rt.sent = {}
end

function Crackdown.forceEnd(source, eventId)
    local rt = active[eventId]
    if not rt then return false, 'Event is not active.' end
    DiscordLog.appendEvent(eventId, '🛑 Operation force-ended by an administrator')
    local who = source and source > 0 and Bridge.GetPlayerName(source) or nil
    -- a stopped operation has no winner (nothing is paid); the report still lists who was standing and who was eliminated
    finish(rt, 'CANCELLED', rt.phase == 'ACTIVE' and 'Ended early by an administrator.' or 'Called off by an administrator before the fight opened.', who)
    return true
end

-- who has won? nil = still fighting. atTime: the clock ran out.
local function decide(rt, atTime)
    local t = tally(rt)
    local g, p = t.GANG.standing, t.POLICE.standing
    if g == 0 and p == 0 then return 'DRAW', 'Both sides were wiped out.' end
    if g == 0 then return 'POLICE', ('Every %s fighter was eliminated.'):format(rt.gangLabel) end
    if p == 0 then return 'GANG', 'Every police fighter was eliminated.' end
    if atTime then
        if g > p then return 'GANG', ('Time ran out — %d fighters still standing against %d.'):format(g, p) end
        if p > g then return 'POLICE', ('Time ran out — %d fighters still standing against %d.'):format(p, g) end
        return 'DRAW', ('Time ran out with %d standing on each side.'):format(g)
    end
    return nil
end

-- ── the one-second loop ─────────────────────────────────────────────────────────

local function tick(rt)
    local t0 = now()
    local members = {}
    for _, rec in pairs(rt.players) do rec.here = false end
    for _, src in ipairs(Bridge.GetPlayers()) do
        local ident = Bridge.GetIdentifier(src)
        if ident then
            local rec = rt.players[ident]
            local side = sideOf(rt, src)
            -- the roster is open during PREP and locked once the fight opens
            if not rec and side and rt.phase == 'PREP' then
                rec = { identifier = ident, side = side, kills = 0, joinedAt = t0, outsideSec = 0 }
                rt.players[ident] = rec
                rt.order[#rt.order + 1] = ident
            end
            -- a registered fighter who is now on the other side's job (went on / off duty) is no longer that fighter
            if rec and side == rec.side then
                rec.src = src
                rec.here = true
                rec.lastSeenAt = t0
                rec.name = Bridge.GetCharacterName(src) or rec.name or ('Player %d'):format(src)
                local alive = isAlive(src)
                local ped = GetPlayerPed(src)
                local inside = true
                local area = startAreaOf(rt, side)
                local inStart = area == nil
                if ped and ped ~= 0 then
                    local c = GetEntityCoords(ped)
                    inside = inZone(rt.zone, c.x, c.y)
                    if area then inStart = inPoly(area, c.x, c.y) end
                end
                rec.inside, rec.alive, rec.inStart = inside, alive, inStart
                members[src] = { rec = rec, side = side, alive = alive, inside = inside, inStart = inStart, hasStart = area ~= nil }
            end
        end
    end

    -- a player who stopped being a fighter (went off duty, left the gang) is released from the HUD
    for src in pairs(rt.sent) do
        if not members[src] then
            rt.sent[src] = nil
            TriggerClientEvent(EVT .. 'end', src, { id = rt.id, silent = true })
        end
    end

    if rt.phase == 'PREP' then
        if t0 >= rt.prepEndsAt then
            -- start areas: only the fighters standing inside their own side's box right now take part (and are paid)
            if rt.startZones then
                local kept = {}
                for _, ident in ipairs(rt.order) do
                    local rec = rt.players[ident]
                    if rec and startAreaOf(rt, rec.side) and not rec.inStart then
                        rt.players[ident] = nil
                        if rec.src then
                            members[rec.src] = nil
                            rt.sent[rec.src] = nil
                            TriggerClientEvent(EVT .. 'end', rec.src, { id = rt.id, silent = true })
                            TriggerClientEvent('nova_convoytruck:runtime:announce', rec.src, 'OPERATION CRACKDOWN', say(rt, 'startOut'), 9000, 'crackdown', nil, 'NOT IN THE START AREA')
                        end
                    else
                        kept[#kept + 1] = ident
                    end
                end
                rt.order = kept
            end
            local t = tally(rt)
            if t.GANG.online < rt.cd.minGang or t.POLICE.online < rt.cd.minPolice or t.GANG.total == 0 or t.POLICE.total == 0 then
                finish(rt, 'NO_CONTEST', ('Not enough fighters when the countdown ended (%s: %d here, need %d · police on duty: %d here, need %d).%s'):format(
                    rt.gangLabel, t.GANG.online, rt.cd.minGang, t.POLICE.online, rt.cd.minPolice,
                    rt.startZones and ' Only fighters standing inside their own start area count.' or ''))
                return
            end
            rt.phase = 'ACTIVE'
            rt.fightStartedAt = t0
            rt.endsAt = t0 + rt.durationSec
            announce(rt, say(rt, 'startTitle'), say(rt, 'startBody', { minutes = tostring(math.floor(rt.durationSec / 60)) }), 10000, 'LIVE')
            DiscordLog.appendEvent(rt.id, ('⚔️ The fight is on — %d %s vs %d police. The roster is locked.'):format(t.GANG.total, rt.gangLabel, t.POLICE.total))
        end
    elseif rt.phase == 'ACTIVE' then
        local grace = tonumber(cfg().leaveGraceSeconds) or 60
        for _, rec in pairs(rt.players) do
            if not rec.eliminated then
                if rec.here then
                    if not rec.alive then
                        -- down or dead: out of the operation (they respawn / get revived as usual, but they cannot fight on)
                        eliminate(rt, rec, rec.killerName and ('killed by %s'):format(rec.killerName) or 'went down')
                    elseif not rec.inside then
                        rec.outsideSec = (rec.outsideSec or 0) + 1
                        if rec.outsideSec >= rt.cd.outsideSeconds then eliminate(rt, rec, 'left the combat zone') end
                    else
                        rec.outsideSec = 0
                    end
                elseif rec.lastSeenAt and t0 - rec.lastSeenAt >= grace then
                    eliminate(rt, rec, 'left the operation (off duty or disconnected)')
                end
            end
        end
        local result, reason = decide(rt, t0 >= rt.endsAt)
        if result then
            finish(rt, result, reason)
            return
        end
    end

    local t = tally(rt)
    for src, m in pairs(members) do
        if not rt.sent[src] then
            rt.sent[src] = true
            TriggerClientEvent(EVT .. 'state', src, staticPayload(rt, m.side))
        end
        TriggerClientEvent(EVT .. 'tick', src, tickPayload(rt, m, t))
    end
end

-- ── start ───────────────────────────────────────────────────────────────────────

function Crackdown.start(starterSource, eventId)
    local def = ConvoyManager.get(eventId)
    if not def then return false, 'Event definition not found.' end
    if def.kind ~= 'CRACKDOWN' then return false, 'Not an Operation Crackdown event.' end
    if active[eventId] then return false, 'This event is already running.' end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then return false, 'Only draft or scheduled events can be started.' end
    for _, other in pairs(active) do
        return false, ('"%s" is already running — only one Operation Crackdown can run at a time.'):format(other.def.name)
    end

    local cd = def.crackdown or {}
    if not cd.targetGang or cd.targetGang == '' then return false, 'No target gang is set (Operation Setup tab).' end
    local gangRow = DB.getGangByName(cd.targetGang)
    if not gangRow then return false, ('The target gang "%s" no longer exists.'):format(cd.targetGang) end
    local zone = cd.zone
    if not (zone and zone.center and zone.center.x) then return false, 'The combat zone is not placed (Combat Zone tab).' end

    local startedByName = 'Automated Schedule'
    if starterSource and starterSource > 0 then
        startedByName = ('%s (%s)'):format(Bridge.GetPlayerName(starterSource) or 'Admin', Bridge.GetIdentifier(starterSource) or 'N/A')
    end

    local durationSec = math.max(60, math.floor(tonumber(def.eventDuration) or ((tonumber(cfg().defaults and cfg().defaults.durationMinutes) or 20) * 60)))
    local rt = {
        id = eventId, def = def, cd = cd, gang = cd.targetGang, gangLabel = gangRow.label or cd.targetGang,
        zone = zone, startZones = nil, phase = 'PREP', startedAt = now(), startedByName = startedByName,
        prepEndsAt = now() + math.max(10, math.floor(tonumber(cd.prepSeconds) or 120)), durationSec = durationSec,
        players = {}, order = {}, sent = {}, feed = {},
        zoneText = zone.shape == 'square' and ('Square, %dx%d m'):format(math.floor((zone.size or 0) * 2), math.floor((zone.size or 0) * 2))
            or ('Circle, %d m radius'):format(math.floor(zone.radius or 0)),
    }
    rt.runId = rt.startedAt
    -- the drawn start areas (a side without one is not restricted); nil when neither side has one
    local sz = cd.startZones or {}
    if sz.gang and sz.gang.points or sz.police and sz.police.points then
        rt.startZones = { gang = sz.gang and sz.gang.points or nil, police = sz.police and sz.police.points or nil }
    end
    active[eventId] = rt
    ConvoyManager.setStatus(eventId, 'ACTIVE')

    local prepText = clock(rt.prepEndsAt - now())
    announce(rt, say(rt, 'prepTitle'), say(rt, 'prepBody', { prep = prepText }), 12000, 'PREPARE')
    DiscordLog.startEvent(eventId, ('🚔 [OPERATION CRACKDOWN] Live — %s'):format(def.name), 0x4f94e6,
        ('%s vs the Police.'):format(rt.gangLabel), {
            { name = 'Operation', value = def.name, inline = true }, { name = 'Target gang', value = rt.gangLabel, inline = true },
            { name = 'Started by', value = startedByName, inline = true }, { name = 'Zone', value = rt.zoneText, inline = true },
            { name = 'Prep', value = prepText, inline = true }, { name = 'Duration', value = ('%d min'):format(math.floor(durationSec / 60)), inline = true },
        })
    DiscordLog.appendEvent(eventId, ('🚔 Operation Crackdown started — %s vs the Police, prep %s'):format(rt.gangLabel, prepText))
    log(eventId, ('Started: %s vs police, prep %ds, fight %ds'):format(rt.gang, rt.prepEndsAt - now(), durationSec))

    CreateThread(function()
        while active[eventId] == rt do
            local ok, err = pcall(tick, rt)
            if not ok then print(('^1[NovaConvoy][Crackdown] tick error: %s^0'):format(tostring(err))) end
            Wait(1000)
        end
    end)
    return true
end

-- ── who killed a fighter (reported by the victim's client; used for the kill feed and the report only) ──
-- Eliminations never depend on this report: the server sees the fighter go down on its own. The report just names the killer, if the
-- game says a player did it, when the killer is a fighter of the other side.

RegisterNetEvent('nova_convoytruck:crackdown:server:died', function(eventId, killerSrc)
    local src = source
    local rt = active[tonumber(eventId)]
    if not rt or rt.phase ~= 'ACTIVE' then return end
    local ident = Bridge.GetIdentifier(src)
    local rec = ident and rt.players[ident]
    if not rec or rec.src ~= src or rec.killerName then return end
    local k = tonumber(killerSrc)
    if not k or k == src then return end
    local kIdent = Bridge.GetIdentifier(k)
    local krec = kIdent and rt.players[kIdent]
    if not krec or krec.src ~= k or krec.side == rec.side or krec.eliminated then return end
    -- only for a fighter who is down right now or went down in the last few seconds
    if not rec.eliminated and isAlive(src) then return end
    if rec.eliminated and now() - (rec.eliminatedAt or 0) > 10 then return end
    rec.killerName = krec.name
    krec.kills = (krec.kills or 0) + 1
    if rec.eliminated then
        rec.eliminatedReason = ('killed by %s'):format(krec.name)
        pushFeed(rt, ('%s (%s) eliminated %s (%s)'):format(krec.name, sideLabel(rt, krec.side), rec.name, sideLabel(rt, rec.side)))
        DiscordLog.appendEvent(rt.id, ('🎯 %s eliminated %s'):format(krec.name, rec.name))
    end
end)

-- a fighter who leaves the server simply stops being "here"; the leave grace in the tick decides when they are out
AddEventHandler('playerDropped', function()
    local src = source
    for _, rt in pairs(active) do rt.sent[src] = nil end
end)

-- A Crackdown exists only in memory. If the resource restarted while one was running, its database row still says ACTIVE, so Manage
-- Events would show a live operation that nothing is running. A few seconds after start (the event cache is loaded by then) any such
-- row is closed as CANCELLED. Nothing was paid, nothing is lost: it can simply be started again (Edit & Reuse from Event History).
CreateThread(function()
    Wait(8000)
    local defs = (ConvoyManager.getAll and ConvoyManager.getAll()) or {}
    for _, d in ipairs(defs) do
        if d.kind == 'CRACKDOWN' and d.status == 'ACTIVE' and not active[d.id] then
            ConvoyManager.setStatus(d.id, 'CANCELLED')
            log(d.id, 'was still marked ACTIVE after a restart — closed as CANCELLED')
        end
    end
end)

-- the resource stopping mid-event: tell every fighter's screen it is over
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, rt in pairs(active) do
        for src in pairs(rt.sent) do TriggerClientEvent(EVT .. 'end', src, { id = rt.id, silent = true }) end
    end
end)
