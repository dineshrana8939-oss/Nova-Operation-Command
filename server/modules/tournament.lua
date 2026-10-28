-- ─── Nova Convoy — TDM Tournaments (server runtime) ───────────────────────────
-- The competition layer on top of the TDM match layer:
--
--   Tournament  decides WHO plays, WHICH group, WHICH match, who advances,
--               who is eliminated, who plays the final, who is champion.
--   Tdm         (tdm_runtime.lua) plays the actual match — countdown, combat,
--               kills, timer — and hands back a raw result.
--
-- All bracket maths lives in tournament_engine.lua. This file owns lifecycle
-- (draw → schedule → live → champion), persistence, recurring daily/weekly
-- instances, announcements, gang stats/reward hooks and the NUI callbacks.
-- The admin Tournaments tab and the gang tablet read the exact same
-- instance through the exact same callbacks — there is one source of truth.

Tournament = {}

local E = TournamentEngine
local cache = {} -- [id] = instance

local TICK_MS = 5000
local MAX_LOG = 80
local DEFAULT_GAP_SECONDS = 45

local function now() return Scheduler.nowUtc() end

-- The admin VIEW of tournaments (drafts, every gang's data). Each admin action below checks its own permission key;
-- a player's gang membership never grants or removes any of it.
local function isAdmin(source)
    return UserPermissions.canAny(source, 'tournaments.view', 'tournamenthistory.view') == true
end

local function can(source, key) return UserPermissions.can(source, key) == true end

local function denied()
    return { ok = false, error = 'Only administrators can manage tournaments.' }
end

local function gangLabel(name)
    local g = GangService.GetGangByName(name)
    return (g and g.label) or name
end

local function persist(inst)
    DB.saveTournament(inst)
end

local function addLog(inst, text)
    inst.log = inst.log or {}
    table.insert(inst.log, 1, { t = now(), text = text })
    while #inst.log > MAX_LOG do table.remove(inst.log) end
end

-- scope: 'all' = every connected player, 'gangs' = only online members of the
-- gangs taking part. Goes through the same client banner every other
-- EventHub announcement uses; kind 'tdm' gives it the TDM styling.
local function announce(inst, title, body, scope)
    addLog(inst, title .. (body and body ~= '' and (' — ' .. body) or ''))
    local targets = {}
    if scope == 'gangs' then
        local wanted = {}
        for _, g in ipairs(inst.cfg.gangs) do wanted[g] = true end
        for _, src in ipairs(Bridge.GetPlayers()) do
            local pg = GangService.GetPlayerGang(src)
            if pg and wanted[pg.name] then targets[#targets + 1] = src end
        end
    else
        targets = Bridge.GetPlayers()
    end
    for _, src in ipairs(targets) do
        TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body or '', 9000, 'tdm')
    end
end

local function anyLive(exceptId)
    for id, inst in pairs(cache) do
        if inst.status == 'LIVE' and id ~= exceptId then return inst end
    end
    return nil
end

local function templateInfo(templateId)
    local def = ConvoyManager.get(templateId)
    if not def or def.kind ~= 'TDM' then return nil end
    local tdm = def.tdm or {}
    return {
        id = def.id, name = def.name,
        zoneOk = tdm.zone and tdm.zone.points and #tdm.zone.points >= 3 or false,
        -- same rule as Tdm's own setupError: the shared list OR either team's own spawn list counts
        spawnOk = ((tdm.spawnPoints and #tdm.spawnPoints > 0) or (tdm.spawnPointsRed and #tdm.spawnPointsRed > 0) or (tdm.spawnPointsBlue and #tdm.spawnPointsBlue > 0)
            or (tdm.respawnZoneRed and tdm.respawnZoneRed.points and #tdm.respawnZoneRed.points >= 3) or (tdm.respawnZoneBlue and tdm.respawnZoneBlue.points and #tdm.respawnZoneBlue.points >= 3)) and true or false,
        duration = tdm.duration, killLimit = tdm.killLimit,
        isTournamentFormat = tdm.matchFormat == 'TOURNAMENT',
    }
end

-- ── Match flow ───────────────────────────────────────────────────────────────

local function matchTitle(inst, m)
    return ('%s — %s'):format(inst.name, m.label)
end

local function finishTournament(inst)
    if inst.status == 'COMPLETED' then return end
    inst.status = 'COMPLETED'
    inst.completedAt = now()
    inst.currentMatchId = nil
    persist(inst)

    local champLabel = gangLabel(inst.champion)

    if not inst.statsRecorded then
        inst.statsRecorded = true
        for _, g in ipairs(inst.cfg.gangs) do
            GangService.RecordOutcome(g, 'tournamentPlayed', 'TDM')
        end
        GangService.RecordOutcome(inst.champion, 'tournamentWon', 'TDM')

        -- The template's reward list pays out once, to the champion gang's
        -- online members — per-match wins pay nothing (see Tdm finishMatch).
        -- Paid per player by kills over the tournament (server/modules/tdm_rewards.lua): the champion gang gets the winners' shares, every
        -- other gang in the tournament the lower share set in the event form (Match Reward); 0 % there = only the champion is paid.
        local def = ConvoyManager.get(inst.templateId)
        if def and def.reward and #def.reward > 0 then
            RewardService.ClearPayouts(def.id)   -- the report below reads back what THIS payout gave
            for _, g in ipairs(inst.cfg.gangs) do
                local members = {}
                for _, src in ipairs(Tdm.onlineGangSources(g)) do
                    local ident = Bridge.GetIdentifier(src)
                    local st = ident and inst.playerStats and inst.playerStats[ident]
                    members[#members + 1] = { source = src, kills = st and st.kills or 0 }
                end
                if #members > 0 then
                    TdmRewards.payTeam(def, g, gangLabel(g), members, g == inst.champion, 'tournament' .. tostring(inst.id),
                        g == inst.champion and 'TOURNAMENT CHAMPIONS' or 'TOURNAMENT PLAYED')   -- each tournament instance is its own run
                end
            end
        end
    end

    local finalMatch = inst.matches[#inst.matches]
    local body = finalMatch and ('%s %d - %d %s'):format(
        gangLabel(finalMatch.a.gang or '?'), finalMatch.scoreA or 0, finalMatch.scoreB or 0, gangLabel(finalMatch.b.gang or '?')) or ''
    announce(inst, 'TOURNAMENT COMPLETE', ('%s is the %s champion.'):format(champLabel, inst.name), 'all')
    announce(inst, 'TOURNAMENT CHAMPION — ' .. champLabel, body, 'all')
    persist(inst)

    -- After-action: a report row in Event History, the PDF, and the Discord summary (champion, every match, who was paid what)
    pcall(function()
        local def = ConvoyManager.get(inst.templateId)
        local matches, gangs = {}, {}
        for idx, m in ipairs(inst.matches or {}) do
            if m.a and m.b and m.a.gang and m.b.gang and m.scoreA ~= nil then
                matches[#matches + 1] = {
                    idx = idx, label = m.label, stage = m.stage, aGang = m.a.gang, bGang = m.b.gang,
                    aLabel = gangLabel(m.a.gang), bLabel = gangLabel(m.b.gang), scoreA = m.scoreA or 0, scoreB = m.scoreB or 0,
                    winner = m.winner, winnerLabel = m.winner and gangLabel(m.winner) or nil,
                    walkover = m.walkover, decidedBy = m.decidedBy, reason = m.reason,
                }
            end
        end
        for _, g in ipairs(inst.cfg.gangs or {}) do gangs[#gangs + 1] = { gang = g, label = gangLabel(g) } end
        local payoutId = def and def.id
        local report = ReportBuilder.tournament({
            id = inst.id, name = inst.name or 'Tournament', startedAt = inst.startedAt, endedAt = inst.completedAt or now(),
            champion = inst.champion, championLabel = champLabel, gangs = gangs, matches = matches,
            rewards = payoutId and ReportBuilder.payoutSummary(payoutId, 'None (no reward configured)') or 'None',
            timeline = (function()
                local out = {}
                for i = #(inst.log or {}), 1, -1 do out[#out + 1] = tostring(inst.log[i].text or '') end   -- oldest first
                return out
            end)(),
        })
        if payoutId then ReportBuilder.addPayoutTable(report, payoutId) end
        DB.insertConvoyHistory({
            convoyDefinitionId = nil, name = ('%s (Tournament)'):format(inst.name or 'Tournament'), createdBy = 'Tournament System',
            startedAt = inst.startedAt or now(), endedAt = inst.completedAt or now(), duration = (inst.completedAt or now()) - (inst.startedAt or now()),
            truckCount = 0, policeParticipants = 0, gangParticipants = #gangs, winningGang = inst.champion, outcome = 'COMPLETED',
            rewardSummary = report.rewards, destroyedTrucks = 0, checkpointsCompleted = 0, kind = 'TDM', reportData = report,
        })

        if DiscordLog and DiscordLog.send then
            local lines = {}
            for _, m in ipairs(matches) do
                if #lines >= 14 then lines[#lines + 1] = '...' break end
                lines[#lines + 1] = ('%d. %s %d - %d %s'):format(m.idx, m.aLabel, m.scoreA, m.scoreB, m.bLabel)
            end
            local results = table.concat(lines, '\n')
            if #results > 1000 then results = results:sub(1, 997) .. '...' end
            local gangNames = {}
            for _, g in ipairs(gangs) do gangNames[#gangNames + 1] = g.label end
            local fields = {
                { name = 'Champion', value = champLabel, inline = true },
                { name = 'Final', value = body ~= '' and body or '—', inline = true },
                { name = 'Matches', value = tostring(#matches), inline = true },
                { name = 'Gangs', value = tostring(#gangNames), inline = true },
                { name = 'Participants', value = table.concat(gangNames, ', '):sub(1, 1000), inline = false },
            }
            if results ~= '' then fields[#fields + 1] = { name = 'Match results', value = results, inline = false } end
            if payoutId then for _, f in ipairs(ReportBuilder.payoutFields(payoutId)) do fields[#fields + 1] = f end end
            local pdfString = nil
            if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
                pdfString = PdfGenerator.generateConvoyReport(report)
            end
            if pdfString then fields[#fields + 1] = { name = '📄 After-Action Report (PDF)', value = 'Full tournament report generated and attached to this message.', inline = false } end
            DiscordLog.send(('🏆 TDM Tournament Complete — %s'):format(inst.name or 'Tournament'), nil, 0xff6a00, fields, pdfString, 'tdm_tournament_report_' .. tostring(inst.id) .. '.pdf')
        end
        if payoutId then RewardService.ClearPayouts(payoutId) end
    end)
end
-- Runs after ANY match becomes COMPLETE (played, walkover or forced).
local function afterResult(inst, m, qualifiedWasSet)
    inst.currentMatchId = nil
    inst.nextMatchAt = now() + (inst.matchGapSeconds or DEFAULT_GAP_SECONDS)

    if m.stage == 'GROUP' then
        announce(inst, ('GROUP %s MATCH COMPLETE'):format(m.groupName),
            ('%s %d - %d %s'):format(gangLabel(m.a.gang), m.scoreA or 0, m.scoreB or 0, gangLabel(m.b.gang)), 'gangs')
    end
    if not qualifiedWasSet and inst.qualified then
        announce(inst, 'GROUP STAGE COMPLETE', 'Qualification has been calculated.', 'all')
        announce(inst, 'KNOCKOUT STAGE READY', 'The knockout bracket is set.', 'all')
    end
    if inst.champion then
        finishTournament(inst)
    else
        persist(inst)
    end
end

function Tournament.onMatchFinished(instId, matchId, res)
    local inst = cache[instId]
    if not inst then return end
    local m = E.matchById(inst, matchId)
    if not m or m.status ~= 'LIVE' then return end

    if res.cancelled then
        -- An admin ended the match early: nothing counts, it goes back to the
        -- queue exactly as it was.
        m.status = 'READY'
        inst.currentMatchId = nil
        inst.nextMatchAt = now() + (inst.matchGapSeconds or DEFAULT_GAP_SECONDS)
        addLog(inst, ('%s was cancelled and returned to the schedule.'):format(m.label))
        persist(inst)
        return
    end

    -- every player's kills over the whole tournament: the champion and the other gangs are paid by them when it ends (tdm_rewards.lua)
    inst.playerStats = inst.playerStats or {}
    for _, p in ipairs(res.players or {}) do
        local cur = inst.playerStats[p.identifier] or { kills = 0, deaths = 0 }
        cur.kills, cur.deaths, cur.name, cur.gang = cur.kills + (p.kills or 0), cur.deaths + (p.deaths or 0), p.name, p.gang
        inst.playerStats[p.identifier] = cur
    end

    local hadQualified = inst.qualified ~= nil
    m.reason = res.reason
    -- a forfeit (the other side left mid-match) is decided by who stayed, not by the score at that moment
    local forced = (tostring(res.reason or ''):find('^FORFEIT') and res.winnerTeam) or nil
    E.applyResult(inst, m, res.scoreA, res.scoreB, forced and { forcedWinner = forced } or nil)
    afterResult(inst, m, hadQualified)
end

-- Starts a specific READY match. Returns ok, err.
local function startMatch(inst, m)
    if inst.status ~= 'LIVE' then return false, 'The tournament is not live.' end
    if E.liveMatch(inst) then return false, 'A match is already in progress.' end
    if m.status ~= 'READY' then return false, 'That match is not ready to be played.' end

    local ok, err, noShow = Tdm.startTournamentMatch(inst.templateId, m.a.gang, m.b.gang, {
        title = matchTitle(inst, m),
        onFinish = function(res) Tournament.onMatchFinished(inst.id, m.id, res) end,
    })

    if ok then
        m.status = 'LIVE'
        m.startedAt = now()
        inst.currentMatchId = m.id
        inst.lastError = nil

        local body = ('%s vs %s'):format(gangLabel(m.a.gang), gangLabel(m.b.gang))
        if m.stage == 'KO' then
            inst.flags = inst.flags or {}
            local key = 'live' .. m.round
            if not inst.flags[key] then
                inst.flags[key] = true
                local title = (m.roundName == 'FINAL') and 'FINAL MATCH LIVE' or (m.roundName .. 'S LIVE')
                announce(inst, title, body, 'all')
            end
        end
        addLog(inst, ('%s started: %s'):format(m.label, body))
        persist(inst)
        return true
    end

    if noShow then
        -- Nobody online for one (or both) sides: a walkover, not an error —
        -- the tournament must be able to progress without them.
        local hadQualified = inst.qualified ~= nil
        m.reason = 'NO_SHOW'
        E.applyResult(inst, m, 0, 0, { noShow = noShow })
        local who = noShow == 'BOTH' and 'both gangs' or gangLabel(noShow == 'A' and m.a.gang or m.b.gang)
        addLog(inst, ('%s: walkover — no players online for %s.'):format(m.label, who))
        afterResult(inst, m, hadQualified)
        return true
    end

    inst.lastError = err
    return false, err
end

local function beginTournament(inst)
    inst.status = 'LIVE'
    inst.startedAt = now()
    inst.nextMatchAt = now()
    inst.flags = inst.flags or {}
    announce(inst, 'TDM TOURNAMENT STARTING', inst.name, 'all')
    announce(inst, 'GROUP STAGE LIVE', ('%d gangs across %d groups.'):format(#inst.cfg.gangs, inst.cfg.groupCount), 'all')
    persist(inst)
    if DiscordLog and DiscordLog.send then
        local names = {}
        for _, g in ipairs(inst.cfg.gangs or {}) do names[#names + 1] = gangLabel(g) end
        DiscordLog.send(('🏟️ TDM Tournament Started — %s'):format(inst.name or 'Tournament'), nil, 0xff6a00, {
            { name = 'Gangs', value = tostring(#names), inline = true },
            { name = 'Groups', value = tostring(inst.cfg.groupCount or 0), inline = true },
            { name = 'Participants', value = table.concat(names, ', '):sub(1, 1000), inline = false },
        })
    end
end

-- ── Instances ────────────────────────────────────────────────────────────────

local function newInstance(fields)
    return {
        name = fields.name, status = 'DRAFT', templateId = fields.templateId,
        schedule = fields.schedule, cfg = fields.cfg,
        autoAdvance = fields.autoAdvance ~= false,
        matchGapSeconds = fields.matchGapSeconds or DEFAULT_GAP_SECONDS,
        draw = nil, matches = {}, qualified = nil, champion = nil,
        seriesId = fields.seriesId, edition = fields.edition or 1,
        log = {}, flags = {}, createdAt = now(), createdBy = fields.createdBy,
    }
end

local function lockDraw(inst)
    inst.draw.locked = true
    inst.status = 'SCHEDULED'
    announce(inst, 'DRAW COMPLETE', inst.name, 'gangs')
end

local function drawAndBuild(inst)
    inst.draw = E.buildDraw(inst.cfg.gangs, inst.cfg.groupCount)
    inst.draw.locked = false
    E.buildFixtures(inst)
    inst.currentMatchId = nil
end

-- Daily/weekly: the moment an instance goes live, the following occurrence is
-- created as its own fresh instance (auto-shuffled and locked, since no admin
-- is there to do it) so there is always an upcoming one. Previous instances
-- are never touched.
local function spawnNextOccurrence(inst)
    local sType = inst.schedule and inst.schedule.type
    if (sType ~= 'DAILY' and sType ~= 'WEEKLY') or inst.nextSpawned then return end
    inst.nextSpawned = true

    local offset = math.floor(Scheduler.getSettings().utcOffsetHours * 3600)
    local t = os.date('!*t', inst.schedule.startAt + offset)
    local rec = { type = sType, mode = 'EXACT', hour = t.hour, minute = t.min, dayOfWeek = t.wday - 1 }
    local nextAt = Scheduler.nextOccurrence(rec, inst.schedule.startAt, true)
    local guard = 0
    while nextAt <= now() and guard < 400 do
        nextAt = Scheduler.nextOccurrence(rec, nextAt, true)
        guard = guard + 1
    end

    -- A gang deleted since the last edition just drops out of the next one.
    local existing = {}
    for _, g in ipairs(GangService.GetGangs()) do existing[g.name] = true end
    local gangs = {}
    for _, g in ipairs(inst.cfg.gangs) do if existing[g] then gangs[#gangs + 1] = g end end
    local cfgRaw = {}
    for k, v in pairs(inst.cfg) do cfgRaw[k] = v end
    cfgRaw.gangs = gangs
    local cfg = E.sanitizeConfig(cfgRaw)
    if not cfg then
        addLog(inst, 'The next occurrence could not be created — too few gangs remain.')
        return
    end

    local regLead = (inst.schedule.regOpenAt and inst.schedule.startAt) and (inst.schedule.startAt - inst.schedule.regOpenAt) or nil
    local nextInst = newInstance({
        name = inst.name, templateId = inst.templateId, cfg = cfg,
        autoAdvance = inst.autoAdvance, matchGapSeconds = inst.matchGapSeconds,
        seriesId = inst.seriesId or inst.id, edition = (inst.edition or 1) + 1,
        createdBy = inst.createdBy,
        schedule = {
            type = sType, startAt = nextAt,
            regOpenAt = regLead and (nextAt - regLead) or nil,
            durationMinutes = inst.schedule.durationMinutes,
        },
    })
    drawAndBuild(nextInst)
    nextInst.draw.locked = true
    nextInst.status = 'SCHEDULED'
    nextInst.id = DB.insertTournament(nextInst)
    if not nextInst.id then
        addLog(inst, 'The next occurrence could not be saved (database error).')
        return
    end
    cache[nextInst.id] = nextInst
    DB.saveTournament(nextInst)
    addLog(inst, ('Next occurrence scheduled: %s.'):format(Scheduler.formatLocal(nextAt)))
end

-- ── Tick ─────────────────────────────────────────────────────────────────────

local function tick()
    local t = now()
    local ids = {}
    for id in pairs(cache) do ids[#ids + 1] = id end   -- spawnNextOccurrence adds to cache while we loop
    for _, id in ipairs(ids) do
        local inst = cache[id]
        if inst then
        if inst.status == 'SCHEDULED' and inst.draw and inst.draw.locked then
            local reg = inst.schedule.regOpenAt
            if (not reg or t >= reg) and not inst.flags.regAnnounced then
                inst.flags.regAnnounced = true
                announce(inst, 'REGISTRATION OPEN', ('%s — starts %s.'):format(inst.name, Scheduler.formatLocal(inst.schedule.startAt)), 'all')
                persist(inst)
            end
            if inst.schedule.startAt and t >= inst.schedule.startAt and not anyLive(id) then
                beginTournament(inst)
                spawnNextOccurrence(inst)
                persist(inst)
            end
        elseif inst.status == 'LIVE' then
            if inst.autoAdvance and not E.liveMatch(inst) and t >= (inst.nextMatchAt or 0) then
                local m = E.nextMatch(inst)
                if m then
                    local ok = startMatch(inst, m)
                    if not ok then
                        -- Don't hammer a broken setup every tick.
                        inst.nextMatchAt = t + 60
                        persist(inst)
                    end
                end
            end
        end
        end
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local ok, err = pcall(tick)
        if not ok then lib.print.warn(('[NovaConvoy] Tournament tick failed: %s'):format(tostring(err))) end
    end
end)

-- ── Boot ─────────────────────────────────────────────────────────────────────

function Tournament.init()
    for _, inst in ipairs(DB.getTournaments()) do
        inst.flags = inst.flags or {}
        inst.log = inst.log or {}
        inst.matches = inst.matches or {}
        -- A match that was mid-play when the resource stopped lost its combat
        -- runtime — put it back in the queue rather than leaving it "live"
        -- forever.
        for _, m in ipairs(inst.matches) do
            if m.status == 'LIVE' then
                m.status = 'READY'
                addLog(inst, ('%s was interrupted by a restart and returned to the schedule.'):format(m.label))
            end
        end
        inst.currentMatchId = nil
        if inst.status == 'LIVE' then inst.nextMatchAt = now() + 30 end
        cache[inst.id] = inst
    end
end

-- ── View building ────────────────────────────────────────────────────────────

-- Read-only list for /eventdebug.
function Tournament.debugSummary()
    local out = {}
    for id, inst in pairs(cache) do
        local live = E.liveMatch(inst)
        local nextM = E.nextMatch(inst)
        local played, total = 0, 0
        for _, m in ipairs(inst.matches or {}) do
            if m.decidedBy ~= 'BYE' then total = total + 1; if m.status == 'COMPLETE' then played = played + 1 end end
        end
        out[#out + 1] = {
            id = id, name = inst.name, status = inst.status, templateId = inst.templateId, gangs = #(inst.cfg and inst.cfg.gangs or {}),
            locked = inst.draw and inst.draw.locked or false, startAt = inst.schedule and inst.schedule.startAt, nextMatchAt = inst.nextMatchAt,
            live = live and live.label or nil, nextMatch = nextM and nextM.label or nil, played = played, total = total,
            lastError = inst.lastError, autoAdvance = inst.autoAdvance,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
local function gangMeta(names)
    local out = {}
    for _, name in ipairs(names) do
        local g = GangService.GetGangByName(name)
        out[name] = { name = name, label = (g and g.label) or name, accentColor = g and g.accentColor or nil }
    end
    return out
end

local function summary(inst)
    local stages, current = E.stageInfo(inst)
    local currentLabel
    for _, s in ipairs(stages) do if s.key == current then currentLabel = s.label end end
    local played, total = 0, 0
    for _, m in ipairs(inst.matches or {}) do
        if not (m.decidedBy == 'BYE') then
            total = total + 1
            if m.status == 'COMPLETE' then played = played + 1 end
        end
    end
    local live = E.liveMatch(inst)
    return {
        id = inst.id, name = inst.name, status = inst.status, edition = inst.edition, seriesId = inst.seriesId,
        scheduleType = inst.schedule and inst.schedule.type,
        startAt = inst.schedule and inst.schedule.startAt,
        startLabel = inst.schedule and inst.schedule.startAt and Scheduler.formatLocal(inst.schedule.startAt) or nil,
        stage = currentLabel, gangCount = #inst.cfg.gangs, groupCount = inst.cfg.groupCount,
        drawLocked = inst.draw and inst.draw.locked or false,
        registrationOpen = inst.status == 'SCHEDULED' and inst.draw and inst.draw.locked
            and (not inst.schedule.regOpenAt or now() >= inst.schedule.regOpenAt) or false,
        champion = inst.champion, championLabel = inst.champion and gangLabel(inst.champion) or nil,
        playedMatches = played, totalMatches = total,
        liveMatchLabel = live and live.label or nil,
        completedAt = inst.completedAt, createdAt = inst.createdAt,
    }
end

function Tournament.buildView(inst)
    local stages, current = E.stageInfo(inst)
    local standings = (inst.draw and inst.draw.groups) and E.standings(inst) or {}
    local groups = {}
    for gi, grp in ipairs((inst.draw and inst.draw.groups) or {}) do
        groups[gi] = { name = grp.name, gangs = grp.gangs, standings = standings[gi] or {} }
    end

    local live = E.liveMatch(inst)
    local currentMatch
    if live then
        local l = Tdm.getLive(inst.templateId)
        currentMatch = {
            id = live.id,
            live = l and {
                phase = l.phase, scoreA = l.scoreA, scoreB = l.scoreB,
                timeRemaining = l.timeRemaining, duration = l.duration,
            } or nil,
        }
    end
    local nextM = E.nextMatch(inst)

    local tpl = templateInfo(inst.templateId)
    local view = summary(inst)
    view.templateId = inst.templateId
    view.templateName = tpl and tpl.name or nil
    view.templateOk = tpl and tpl.zoneOk and tpl.spawnOk or false
    view.cfg = inst.cfg
    view.autoAdvance = inst.autoAdvance
    view.matchGapSeconds = inst.matchGapSeconds
    view.schedule = {
        type = inst.schedule.type, startAt = inst.schedule.startAt, regOpenAt = inst.schedule.regOpenAt,
        durationMinutes = inst.schedule.durationMinutes,
        startLabel = inst.schedule.startAt and Scheduler.formatLocal(inst.schedule.startAt) or nil,
        regLabel = inst.schedule.regOpenAt and Scheduler.formatLocal(inst.schedule.regOpenAt) or nil,
    }
    view.gangs = gangMeta(inst.cfg.gangs)
    view.groups = groups
    view.matches = inst.matches
    view.qualified = inst.qualified
    view.stages = stages
    view.currentStage = current
    view.currentMatch = currentMatch
    view.nextMatchId = nextM and nextM.id or nil
    view.nextMatchAt = inst.nextMatchAt
    view.hasActivity = E.hasActivity(inst)
    view.log = inst.log
    view.startedAt = inst.startedAt
    view.lastError = inst.lastError
    view.serverNow = now()
    return view
end

-- ── Callbacks ────────────────────────────────────────────────────────────────

local function sortedList(filterFn)
    local list = {}
    for _, inst in pairs(cache) do
        if not filterFn or filterFn(inst) then list[#list + 1] = inst end
    end
    table.sort(list, function(a, b)
        return (a.schedule and a.schedule.startAt or 0) > (b.schedule and b.schedule.startAt or 0)
    end)
    return list
end

-- Admins see everything (including drafts); every other player only sees
-- tournaments that have been drawn and locked.
lib.callback.register('nova_convoytruck:tournament:list', function(source)
    local admin = isAdmin(source)
    local out = {}
    for _, inst in ipairs(sortedList(function(i) return admin or (i.draw and i.draw.locked and i.status ~= 'CANCELLED') end)) do
        out[#out + 1] = summary(inst)
    end
    return { ok = true, tournaments = out, isAdmin = admin }
end)

lib.callback.register('nova_convoytruck:tournament:get', function(source, id)
    local inst = cache[tonumber(id)]
    local admin = isAdmin(source)
    if not inst or (not admin and not (inst.draw and inst.draw.locked)) then
        return { ok = false, error = 'Tournament not found.' }
    end
    local pg = GangService.GetPlayerGang(source)
    local myGang = pg and pg.name or nil
    return { ok = true, tournament = Tournament.buildView(inst), isAdmin = admin, myGang = myGang }
end)

-- TDM definitions marked Tournament format — the arenas a tournament can
-- be played on.
lib.callback.register('nova_convoytruck:tournament:templates', function(source)
    if not UserPermissions.canAny(source, 'tournaments.create', 'tournaments.edit') then return denied() end
    local list = {}
    for _, def in ipairs(ConvoyManager.getAll()) do
        if def.kind == 'TDM' and def.tdm and def.tdm.matchFormat == 'TOURNAMENT' then
            list[#list + 1] = templateInfo(def.id)
        end
    end
    return { ok = true, templates = list }
end)

local function parseLocal(str)
    if str == nil or str == '' then return nil end
    local y, mo, d, h, mi = tostring(str):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+)')
    if not y then return nil end
    return Scheduler.toUtcTimestamp(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi))
end

local function sameConfig(a, b)
    if a.groupCount ~= b.groupCount or a.advance ~= b.advance or a.legs ~= b.legs then return false end
    if #a.gangs ~= #b.gangs then return false end
    local set = {}
    for _, g in ipairs(a.gangs) do set[g] = true end
    for _, g in ipairs(b.gangs) do if not set[g] then return false end end
    return true
end

lib.callback.register('nova_convoytruck:tournament:save', function(source, input)
    if type(input) ~= 'table' then return { ok = false, error = 'Invalid payload.' } end
    -- an id means editing an existing tournament, no id means creating a new one
    if not can(source, input.id and 'tournaments.edit' or 'tournaments.create') then return denied() end

    local name = tostring(input.name or ''):sub(1, 100)
    if #name < 3 then return { ok = false, error = 'Tournament name must be at least 3 characters.' } end

    local tpl = templateInfo(tonumber(input.templateId))
    if not tpl then return { ok = false, error = 'Pick a TDM arena (a TDM event set to Tournament format).' } end

    -- Only gangs that actually exist may be entered.
    local existing = {}
    for _, g in ipairs(GangService.GetGangs()) do existing[g.name] = true end
    local gangs = {}
    for _, g in ipairs(input.gangs or {}) do
        if existing[g] then gangs[#gangs + 1] = g end
    end
    local cfg, err = E.sanitizeConfig({
        gangs = gangs, groupCount = input.groupCount, advance = input.advance, legs = input.legs,
        scoring = input.scoring, tieBreak = input.tieBreak,
    })
    if not cfg then return { ok = false, error = err } end

    local sType = tostring(input.scheduleType or 'ONE_TIME'):upper()
    if sType ~= 'ONE_TIME' and sType ~= 'DAILY' and sType ~= 'WEEKLY' then sType = 'ONE_TIME' end
    local startAt = parseLocal(input.startLocal)
    if not startAt then return { ok = false, error = 'Pick a valid start date and time.' } end
    local regOpenAt = parseLocal(input.regOpenLocal)
    if regOpenAt and regOpenAt > startAt then
        return { ok = false, error = 'Registration must open before the tournament starts.' }
    end

    local fields = {
        name = name, templateId = tpl.id, cfg = cfg,
        autoAdvance = input.autoAdvance ~= false,
        matchGapSeconds = math.max(10, math.min(600, math.floor(tonumber(input.matchGapSeconds) or DEFAULT_GAP_SECONDS))),
        schedule = {
            type = sType, startAt = startAt, regOpenAt = regOpenAt,
            durationMinutes = math.max(0, math.min(1440, math.floor(tonumber(input.durationMinutes) or 0))),
        },
    }

    local inst = input.id and cache[tonumber(input.id)] or nil
    if input.id and not inst then return { ok = false, error = 'Tournament not found.' } end

    if inst then
        if inst.status ~= 'DRAFT' and inst.status ~= 'SCHEDULED' then
            return { ok = false, error = 'A live or finished tournament cannot be edited.' }
        end
        local changedStructure = not inst.cfg or not sameConfig(inst.cfg, cfg)
        inst.name, inst.templateId, inst.cfg = fields.name, fields.templateId, fields.cfg
        inst.autoAdvance, inst.matchGapSeconds, inst.schedule = fields.autoAdvance, fields.matchGapSeconds, fields.schedule
        inst.flags.regAnnounced = nil
        if changedStructure then
            -- Different gangs/groups means the old draw no longer applies.
            inst.draw, inst.matches, inst.qualified, inst.status = nil, {}, nil, 'DRAFT'
        else
            inst.cfg.scoring, inst.cfg.tieBreak = cfg.scoring, cfg.tieBreak
        end
        persist(inst)
    else
        fields.createdBy = Bridge.GetIdentifier(source)
        inst = newInstance(fields)
        inst.id = DB.insertTournament(inst)
        if not inst.id then return { ok = false, error = 'Database write failed — check the server console.' } end
        cache[inst.id] = inst
        DB.saveTournament(inst)
    end
    return { ok = true, tournament = Tournament.buildView(inst) }
end)

lib.callback.register('nova_convoytruck:tournament:shuffle', function(source, id)
    if not can(source, 'tournaments.manage') then return denied() end
    local inst = cache[tonumber(id)]
    if not inst then return { ok = false, error = 'Tournament not found.' } end
    if inst.status ~= 'DRAFT' and inst.status ~= 'SCHEDULED' then
        return { ok = false, error = 'The draw cannot be changed once the tournament is live.' }
    end
    if E.hasActivity(inst) then return { ok = false, error = 'Matches have already been played.' } end
    drawAndBuild(inst)
    inst.status = 'DRAFT' -- reshuffling always un-locks the draw
    persist(inst)
    return { ok = true, tournament = Tournament.buildView(inst) }
end)

lib.callback.register('nova_convoytruck:tournament:lock', function(source, id)
    if not can(source, 'tournaments.manage') then return denied() end
    local inst = cache[tonumber(id)]
    if not inst then return { ok = false, error = 'Tournament not found.' } end
    if not inst.draw then return { ok = false, error = 'Shuffle the draw first.' } end
    if inst.status ~= 'DRAFT' then return { ok = false, error = 'The draw is already locked.' } end
    local tpl = templateInfo(inst.templateId)
    if not tpl or not tpl.zoneOk or not tpl.spawnOk then
        return { ok = false, error = 'The chosen TDM arena still needs a combat zone (3+ points) and at least one spawn point.' }
    end
    lockDraw(inst)
    persist(inst)
    return { ok = true, tournament = Tournament.buildView(inst) }
end)

-- ── Export ───────────────────────────────────────────────────────────────────
-- The tablet builds the PNG / PDF / CSV in the browser; NUI can't be relied on
-- to honour a normal download, so it also hands the bytes here to be written
-- next to the resource (data/tournament_exports_*). Filename and extension are
-- rebuilt from a whitelist — nothing the client sends becomes a path.

local B64 = {}
do
    local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    for i = 1, #chars do B64[chars:byte(i)] = i - 1 end
end

local function base64Decode(data)
    data = data:gsub('[^%w%+/]', '')
    local out, n = {}, 0
    for i = 1, #data, 4 do
        local a, b = B64[data:byte(i)], B64[data:byte(i + 1)]
        local c, d = B64[data:byte(i + 2)], B64[data:byte(i + 3)]
        if not a or not b then break end
        n = n + 1
        out[n] = string.char(((a << 2) | (b >> 4)) & 0xFF)
        if c then
            n = n + 1
            out[n] = string.char((((b & 15) << 4) | (c >> 2)) & 0xFF)
            if d then
                n = n + 1
                out[n] = string.char((((c & 3) << 6) | d) & 0xFF)
            end
        end
    end
    return table.concat(out)
end

local MAX_EXPORT_BASE64 = 12 * 1024 * 1024
local EXPORT_EXT = { png = true, pdf = true, csv = true }

lib.callback.register('nova_convoytruck:tournament:saveExport', function(source, id, fileName, base64)
    if not isAdmin(source) then return denied() end
    local inst = cache[tonumber(id)]
    if not inst then return { ok = false, error = 'Tournament not found.' } end
    if type(base64) ~= 'string' or #base64 == 0 or #base64 > MAX_EXPORT_BASE64 then
        return { ok = false, error = 'Export data is missing or too large.' }
    end
    local ext = tostring(fileName or ''):match('%.(%a+)$')
    ext = ext and ext:lower()
    if not ext or not EXPORT_EXT[ext] then return { ok = false, error = 'Unsupported export type.' } end

    local slug = inst.name:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if slug == '' then slug = 'tournament' end
    local path = ('data/tournament_exports_%s_edition%02d_%d.%s'):format(slug, inst.edition or 1, inst.id, ext)

    local bytes = base64Decode(base64)
    local ok = SaveResourceFile(GetCurrentResourceName(), path, bytes, #bytes)
    if not ok then return { ok = false, error = 'The server could not write the file.' } end
    return { ok = true, path = ('%s/%s'):format(GetCurrentResourceName(), path) }
end)

-- Everything an admin can do to an existing tournament that isn't editing it.
lib.callback.register('nova_convoytruck:tournament:action', function(source, id, action, payload)
    if action == 'delete' then
        if not UserPermissions.canAny(source, 'tournaments.delete', 'tournamenthistory.delete') then return denied() end
    elseif not can(source, 'tournaments.manage') then
        return denied()
    end
    local inst = cache[tonumber(id)]
    if not inst then return { ok = false, error = 'Tournament not found.' } end
    payload = type(payload) == 'table' and payload or {}

    if action == 'startNow' then
        if inst.status ~= 'SCHEDULED' then return { ok = false, error = 'Only a locked, scheduled tournament can be started.' } end
        local other = anyLive(inst.id)
        if other then return { ok = false, error = ('"%s" is already live — only one tournament can run at a time.'):format(other.name) } end
        beginTournament(inst)
        spawnNextOccurrence(inst)

    elseif action == 'startNext' then
        local m = payload.matchId and E.matchById(inst, payload.matchId) or E.nextMatch(inst)
        if not m then return { ok = false, error = 'No match is ready to be played.' } end
        local ok, err = startMatch(inst, m)
        if not ok then return { ok = false, error = err or 'Could not start the match.' } end

    elseif action == 'endMatch' then
        local live = E.liveMatch(inst)
        if not live then return { ok = false, error = 'No match is in progress.' } end
        Tdm.forceEnd(source, inst.templateId) -- fires onMatchFinished(cancelled)

    elseif action == 'setResult' then
        -- Manual result for a match that has not been played (walkover / a
        -- recovery after something went wrong). Never for a running match.
        local m = E.matchById(inst, payload.matchId)
        if not m then return { ok = false, error = 'Match not found.' } end
        if m.status ~= 'READY' then return { ok = false, error = 'Only a match that is waiting to be played can be given a result.' } end
        local hadQualified = inst.qualified ~= nil
        local noShow = payload.noShow
        if noShow ~= 'A' and noShow ~= 'B' and noShow ~= 'BOTH' then noShow = nil end
        local sa = math.max(0, math.min(999, math.floor(tonumber(payload.scoreA) or 0)))
        local sb = math.max(0, math.min(999, math.floor(tonumber(payload.scoreB) or 0)))
        m.reason = 'ADMIN'
        E.applyResult(inst, m, sa, sb, { noShow = noShow })
        addLog(inst, ('Admin set the result of %s.'):format(m.label))
        afterResult(inst, m, hadQualified)

    elseif action == 'pause' then
        inst.autoAdvance = false
    elseif action == 'resume' then
        inst.autoAdvance = true
        inst.nextMatchAt = now()

    elseif action == 'cancel' then
        if inst.status == 'COMPLETED' or inst.status == 'CANCELLED' then return { ok = false, error = 'Already finished.' } end
        if E.liveMatch(inst) then Tdm.forceEnd(source, inst.templateId) end
        inst.status = 'CANCELLED'
        inst.currentMatchId = nil
        announce(inst, 'TOURNAMENT CANCELLED', inst.name, 'gangs')

    elseif action == 'delete' then
        if inst.status == 'LIVE' then return { ok = false, error = 'Cancel a live tournament before deleting it.' } end
        cache[inst.id] = nil
        DB.deleteTournament(inst.id)
        return { ok = true, deleted = true }
    else
        return { ok = false, error = 'Unknown action.' }
    end

    persist(inst)
    return { ok = true, tournament = Tournament.buildView(inst) }
end)

return Tournament
