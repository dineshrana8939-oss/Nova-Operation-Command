-- ─── Nova Convoy — TDM Match Runtime (server) ──────────────────────────────────
-- Deliberately its own module, not folded into convoy_runtime.lua — TDM shares
-- almost none of that file's truck/route/checkpoint machinery, and keeping the
-- combat loop self-contained means it can't regress anything already live for
-- Convoy/Airdrop/Hot Cargo/Race. Wired in from convoy_runtime.lua's doStart
-- (dispatches here for kind == 'TDM') and Runtime.forceEnd/isActive/getActive/
-- getPublicState/isParticipant (all check this module's own `active` table
-- too, since it's entirely separate from convoy_runtime.lua's own).
--
-- EMS isolation: a TDM participant's ped is SetEntityInvincible for the whole
-- match (client/modules/tdm.lua) — native GTA health/armour never reaches a
-- lethal state, so qbx_medical/qbx_ambulancejob/ps-dispatch never see a death
-- to react to. Kills/deaths instead come from a virtual HP pool tracked here,
-- drained only by a server-computed weapon-damage lookup (Config.TDM.
-- weaponDamage) — the client only ever reports WHO shot WHOM with WHAT, never
-- an amount, so a modified client cannot inflate its own kill count or fake a
-- weapon's damage.

Tdm = {}

local active = {} -- [convoyId] = rt

-- Precomputed once at boot: weapon hash -> damage / display label, so a hit
-- report (which only ever carries a raw weapon hash) resolves to a
-- server-trusted amount instead of anything the client sent.
local weaponDamageByHash = {}
local weaponLabelByHash = {}
for name, dmg in pairs((Config.TDM and Config.TDM.weaponDamage) or {}) do
    weaponDamageByHash[joaat(name)] = dmg
end
for _, item in ipairs((Config.TDM and Config.TDM.weaponVendor and Config.TDM.weaponVendor.items) or {}) do
    weaponLabelByHash[joaat(item.weapon)] = item.label
end

local function findSourceByIdentifier(identifier)
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Bridge.GetIdentifier(src) == identifier then return src end
    end
    return nil
end

local function maxHealth()
    return (Config.TDM and Config.TDM.maxHealth) or 100
end

-- Kills by the same attacker within this many seconds of each other count
-- as a "multi-kill" (2 = DOUBLE, 3+ = TRIPLE) — independent of `streak`
-- (consecutive kills without dying, which can span the whole match).
local MULTIKILL_WINDOW_SECONDS = 4

-- Highest kills right now, tie-broken by fewest deaths, among still-online
-- participants only — nil while nobody has a kill yet (no MVP strip shown).
local function computeMvp(rt)
    local best = nil
    for _, p in pairs(rt.players) do
        if p.online ~= false and p.kills > 0 then
            if not best or p.kills > best.kills or (p.kills == best.kills and p.deaths < best.deaths) then
                best = p
            end
        end
    end
    if not best then return nil end
    return { name = best.name, kills = best.kills, deaths = best.deaths }
end

-- Pushes the score/clock/self-stat/MVP HUD to every currently-tracked
-- player — each gets their OWN kills/deaths, everything else (team scores/
-- labels/clock/MVP) is shared.
local function pushHudUpdate(rt, isStart)
    local teamA = { label = rt.gangLabelA, score = rt.scoreA }
    local teamB = { label = rt.gangLabelB, score = rt.scoreB }
    local mvp = computeMvp(rt)
    for _, p in pairs(rt.players) do
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:hudUpdate', p.source, {
                action = isStart and 'start' or 'update',
                seconds = rt.timeRemaining, teamA = teamA, teamB = teamB,
                myKills = p.kills, myDeaths = p.deaths, mvp = mvp,
            })
        end
    end
end

local function polyCentroid(points)
    if not points or #points == 0 then return nil end
    local sx, sy, sz = 0, 0, 0
    for _, p in ipairs(points) do
        sx = sx + (p.x or 0)
        sy = sy + (p.y or 0)
        sz = sz + (p.z or 0)
    end
    return {
        x = sx / #points,
        y = sy / #points,
        z = sz / #points
    }
end

-- A team base perimeter (TDM Match Setup, Team Respawns): the team spawns SPREAD INSIDE it, one spot each, at least a couple of metres apart
-- (shared/zone_spawn.lua; the tablet's Preview draws the same spots). Returns nil when the team has no perimeter drawn.
local ZONE_SPOTS = 40
local function zoneSpawn(rt, team, index, random)
    local baseZone = team == 'A' and rt.respawnZoneRed or rt.respawnZoneBlue
    if not (baseZone and baseZone.points and #baseZone.points >= 3) then return nil end
    rt.zoneSpots = rt.zoneSpots or {}
    local list = rt.zoneSpots[team]
    if not list then
        list = ZoneSpawn.spots(baseZone.points, ZONE_SPOTS)
        rt.zoneSpots[team] = list
    end
    if #list == 0 then return nil end
    local spot = random and list[math.random(1, #list)] or list[((math.max(1, index) - 1) % #list) + 1]
    local arena = rt.zone and rt.zone.points and polyCentroid(rt.zone.points)
    local heading = 0.0
    if arena then heading = (math.deg(math.atan2(arena.y - spot.y, arena.x - spot.x)) - 90.0) % 360.0 end
    return { x = spot.x, y = spot.y, z = spot.z + 0.3, heading = heading }
end

local function computeDistributedSpawn(rt, team, index, random)
    index = math.max(1, tonumber(index) or 1)
    local inZone = zoneSpawn(rt, team, index, random)
    if inZone then return inZone end

    local discreteList = team == 'A' and rt.spawnPointsRed or rt.spawnPointsBlue
    if not discreteList or #discreteList == 0 then
        discreteList = rt.spawnPoints
    end

    local anchor = nil
    local baseZone = team == 'A' and rt.respawnZoneRed or rt.respawnZoneBlue
    if baseZone and baseZone.points and #baseZone.points >= 3 then
        anchor = polyCentroid(baseZone.points)
    end

    if not anchor and discreteList and #discreteList > 0 then
        if discreteList[index] then
            return {
                x = discreteList[index].x,
                y = discreteList[index].y,
                z = discreteList[index].z,
                heading = discreteList[index].heading or 0.0
            }
        end
        anchor = discreteList[((index - 1) % #discreteList) + 1]
    end

    if not anchor then
        local arenaCentroid = rt.zone and rt.zone.points and polyCentroid(rt.zone.points)
        anchor = arenaCentroid or { x = 0.0, y = 0.0, z = 72.0, heading = 0.0 }
    end

    -- Tactical non-overlapping grid formation (4 columns wide, 2.8m spacing)
    local col = (index - 1) % 4
    local row = math.floor((index - 1) / 4)
    local spacing = 2.8
    local ox = (col - 1.5) * spacing
    local oy = (row - 1.5) * spacing

    local arenaCentroid = rt.zone and rt.zone.points and polyCentroid(rt.zone.points)
    local heading = anchor.heading or 0.0
    if arenaCentroid then
        local dx = arenaCentroid.x - (anchor.x + ox)
        local dy = arenaCentroid.y - (anchor.y + oy)
        heading = (math.deg(math.atan2(dy, dx)) - 90.0) % 360.0
    end

    return {
        x = anchor.x + ox,
        y = anchor.y + oy,
        z = anchor.z,
        heading = heading
    }
end

local function randomSpawnPoint(rt, team)
    return computeDistributedSpawn(rt, team, math.random(1, 8), true)
end

local function respawnPlayer(rt, p)
    p.alive = true
    p.hp = maxHealth()
    if p.online ~= false then
        TriggerClientEvent('nova_convoytruck:tdm:client:hp', p.source, p.hp, maxHealth())
    end
    p.respawnProtectedUntil = os.time() + ((Config.TDM and Config.TDM.respawnInvulnSeconds) or 3)
    local spawn = computeDistributedSpawn(rt, p.team, math.random(1, 8), true)
    if p.online ~= false then
        TriggerClientEvent('nova_convoytruck:tdm:client:respawn', p.source, spawn)
    end
end

-- ── Match end / cleanup ─────────────────────────────────────────────────────────

local function purgePlayerTdmEquipment(p)
    if not p or not p.source or not p.tdmPurchasedItems or #p.tdmPurchasedItems == 0 then return end
    for _, entry in ipairs(p.tdmPurchasedItems) do
        if entry.item then
            -- Remove only the TDM-related weapon and ammo issued during this match
            pcall(function()
                Inventory.RemoveItem(p.source, entry.item, entry.count or 1, { tdm = true })   -- only the copy bought here, never a personal weapon of the same name
            end)
        end
    end
    p.tdmPurchasedItems = {}
end

local function purgeMatchTdmEquipment(rt)
    if not rt or not rt.players then return end
    for _, p in pairs(rt.players) do
        if p.online ~= false and p.source then
            purgePlayerTdmEquipment(p)
        end
    end
end

local function endEveryonesCombatState(rt)
    purgeMatchTdmEquipment(rt)
    for _, p in pairs(rt.players) do
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:endMatch', p.source)
        end
    end
end

-- Full after-action record for Event History / the PDF / Discord (shape and
-- wording live in report_builder.lua).
local function buildReport(rt, outcome, reason, winnerGang, winnerLabel)
    local players = {}
    for _, p in pairs(rt.players) do
        players[#players + 1] = {
            name = p.name, identifier = p.identifier, gang = p.gang,
            gangLabel = p.team == 'A' and rt.gangLabelA or rt.gangLabelB,
            kills = p.kills or 0, deaths = p.deaths or 0,
        }
    end
    -- A tournament match pays nothing by itself (the champion is paid once, when the whole tournament ends); a standard match
    -- pays what the ledger recorded.
    local rewardsText
    if rt.tournament then rewardsText = 'None for this match (the champion is paid when the tournament ends)'
    else rewardsText = ReportBuilder.payoutSummary(rt.id, RewardService.describeRewards(rt.def.reward)) end
    local report = ReportBuilder.tdm({
        id = rt.id, name = rt.tournament and rt.tournament.title or rt.def.name,
        startedAt = rt.startedAt, endedAt = os.time(), outcome = outcome, reason = reason,
        startedByName = rt.startedByName,
        gangA = rt.gangA, gangB = rt.gangB, gangLabelA = rt.gangLabelA, gangLabelB = rt.gangLabelB,
        scoreA = rt.scoreA, scoreB = rt.scoreB,
        winnerGang = winnerGang or false, winnerLabel = winnerLabel or false,
        matchFormat = rt.tournament and 'TOURNAMENT' or 'STANDARD',
        players = players,
        rewards = rewardsText,
        timeline = DiscordLog.getTimeline(rt.id),
    })
    return ReportBuilder.addPayoutTable(report, rt.id)
end

-- reason: 'TIME' | 'KILLS_A' | 'KILLS_B' | 'FORFEIT_A' | 'FORFEIT_B' | 'CANCELLED'
-- (A/B suffix on FORFEIT/KILLS names the WINNING side, same as elsewhere here).
local function finishMatch(rt, reason)
    if rt.phase == 'COMPLETE' then return end
    rt.phase = 'COMPLETE'
    active[rt.id] = nil
    if EventProps then EventProps.stop(rt.id) end   -- the arena's placed props (a tournament match never changes the event's status)

    local winnerTeam = nil
    if reason == 'KILLS_A' or reason == 'FORFEIT_A' then
        winnerTeam = 'A'
    elseif reason == 'KILLS_B' or reason == 'FORFEIT_B' then
        winnerTeam = 'B'
    elseif reason == 'TIME' then
        if rt.scoreA > rt.scoreB then winnerTeam = 'A'
        elseif rt.scoreB > rt.scoreA then winnerTeam = 'B' end
    end
    local winnerGang = winnerTeam == 'A' and rt.gangA or (winnerTeam == 'B' and rt.gangB or nil)
    local winnerLabel = winnerTeam == 'A' and rt.gangLabelA or (winnerTeam == 'B' and rt.gangLabelB or nil)

    -- what each player was paid (Gang XP) by the payout below, for the results cards: [source] = { xp, share }
    local payMap = {}

    -- Everything from here to the clean-up is bookkeeping (stats, rewards, report, Discord, results screen). If any of it throws
    -- (database, PDF, Discord ...) the players must still be released and a tournament must still be told the match is over.
    local okReport, errReport = pcall(function()
    if reason ~= 'CANCELLED' then
        if winnerGang then
            local loserGang = winnerTeam == 'A' and rt.gangB or rt.gangA
            GangService.RecordOutcome(winnerGang, 'won', 'TDM')
            GangService.RecordOutcome(loserGang, 'lost', 'TDM')
        end
        -- A tournament match never pays the template's reward per match — the
        -- champion gets it once, when the whole tournament ends (tournament.lua).
        if winnerGang and not rt.tournament then
            -- Paid PER PLAYER by kills (server/modules/tdm_rewards.lua): every online member of the winning gang gets a share (the best killer the
            -- whole reward), and the losing gang gets the configured lower share, again by kills. runId: the match's own start time: Gang XP is
            -- paid once per run per player.
            local loserGang = winnerTeam == 'A' and rt.gangB or rt.gangA
            local loserLabel = winnerTeam == 'A' and rt.gangLabelB or rt.gangLabelA
            local winners, losers = {}, {}
            for _, p in pairs(rt.players) do
                if p.online ~= false and p.source then
                    local row = { source = p.source, kills = p.kills or 0 }
                    if p.gang == winnerGang then winners[#winners + 1] = row else losers[#losers + 1] = row end
                end
            end
            for src, r in pairs(TdmRewards.payTeam(rt.def, winnerGang, winnerLabel, winners, true, rt.startedAt, 'TDM VICTORY')) do payMap[src] = r end
            for src, r in pairs(TdmRewards.payTeam(rt.def, loserGang, loserLabel, losers, false, rt.startedAt, 'TDM MATCH PLAYED')) do payMap[src] = r end
        end
        GangService.RecordOutcome(rt.gangA, 'played', 'TDM')
        GangService.RecordOutcome(rt.gangB, 'played', 'TDM')

        local killsByGang, deathsByGang = {}, {}
        local onlineCount = 0
        for _, p in pairs(rt.players) do
            killsByGang[p.gang] = (killsByGang[p.gang] or 0) + p.kills
            deathsByGang[p.gang] = (deathsByGang[p.gang] or 0) + p.deaths
            if p.online ~= false then onlineCount = onlineCount + 1 end
        end
        GangService.RecordTdmStats(rt.gangA, killsByGang[rt.gangA] or 0, deathsByGang[rt.gangA] or 0)
        GangService.RecordTdmStats(rt.gangB, killsByGang[rt.gangB] or 0, deathsByGang[rt.gangB] or 0)

        if not rt.tournament then ConvoyManager.setStatus(rt.id, 'COMPLETED') end

        local historyOutcome = reason == 'TIME' and (winnerGang and 'COMPLETED' or 'DRAW') or 'COMPLETED'
        DiscordLog.appendEvent(rt.id, ('🏁 Match over (%s) — %s %d - %d %s%s'):format(
            reason, rt.gangLabelA, rt.scoreA, rt.scoreB, rt.gangLabelB, winnerLabel and (' — ' .. winnerLabel .. ' wins') or ' — draw'))
        local reportData = buildReport(rt, historyOutcome, reason, winnerGang, winnerLabel)
        DB.insertConvoyHistory({
            convoyDefinitionId = rt.id,
            name = rt.tournament and rt.tournament.title or rt.def.name,
            createdBy = rt.def.createdBy,
            startedAt = rt.startedAt,
            endedAt = os.time(),
            duration = os.time() - rt.startedAt,
            truckCount = 0,
            policeParticipants = 0,
            gangParticipants = onlineCount,
            winningGang = winnerGang,
            outcome = historyOutcome,
            rewardSummary = ('%s %d - %d %s'):format(rt.gangLabelA, rt.scoreA, rt.scoreB, rt.gangLabelB),
            destroyedTrucks = 0,
            checkpointsCompleted = 0,
            kind = 'TDM',
            reportData = reportData,
        })

        local title = winnerLabel and ('TDM MATCH COMPLETE — %s WINS'):format(winnerLabel) or 'TDM MATCH COMPLETE — DRAW'
        local body = ('%s %d - %d %s'):format(rt.gangLabelA, rt.scoreA, rt.scoreB, rt.gangLabelB)
        for _, p in pairs(rt.players) do
            if p.online ~= false then
                TriggerClientEvent('nova_convoytruck:runtime:announce', p.source, title, body, 9000, 'tdm')
            end
        end

        local pdfString = nil
        if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
            pdfString = PdfGenerator.generateConvoyReport(reportData)
        end
        local endFields = {
            { name = 'Result', value = body, inline = false },
            { name = 'Winner', value = winnerLabel or 'Draw', inline = true },
            { name = 'Reason', value = reason, inline = true },
            { name = 'Format', value = rt.tournament and 'Tournament match' or 'Standard match', inline = true },
            { name = 'Duration', value = reportData.durationText, inline = true },
            { name = 'Players', value = tostring(#(reportData.interceptions or {})), inline = true },
        }
        for _, p in ipairs({ table.unpack(reportData.interceptions or {}, 1, 3) }) do
            endFields[#endFields + 1] = { name = ('%s — top performer'):format(p.time), value = ('%s [%s] — %s'):format(p.actorName, p.target, p.method), inline = false }
        end
        if rt.tournament then
            endFields[#endFields + 1] = { name = 'Tournament', value = tostring(rt.tournament.title or 'Tournament'), inline = true }
        end
        for _, f in ipairs(ReportBuilder.payoutFields(rt.id)) do endFields[#endFields + 1] = f end
        if pdfString then
            endFields[#endFields + 1] = { name = '📄 After-Action Report (PDF)', value = 'Full match report generated and attached to this message.', inline = false }
        end
        DiscordLog.finishEvent(rt.id, ('TDM Match Complete — %s'):format(rt.tournament and rt.tournament.title or rt.def.name), 0xff6a00,
            endFields, ('🏆 %s | %s'):format(winnerLabel and (winnerLabel .. ' wins') or 'Draw', body), pdfString, 'TDM')
        RewardService.ClearPayouts(rt.id)
    elseif not rt.tournament then
        ConvoyManager.setStatus(rt.id, 'CANCELLED')
        DB.deleteRuntime(rt.id)
        local reportData = buildReport(rt, 'CANCELLED', reason, nil, nil)
        DB.insertConvoyHistory({
            convoyDefinitionId = rt.id, name = rt.def.name, createdBy = rt.def.createdBy,
            startedAt = rt.startedAt, endedAt = os.time(), duration = os.time() - rt.startedAt,
            truckCount = 0, policeParticipants = 0, gangParticipants = #(reportData.interceptions or {}),
            winningGang = nil, outcome = 'CANCELLED',
            rewardSummary = ('%s %d - %d %s'):format(rt.gangLabelA, rt.scoreA, rt.scoreB, rt.gangLabelB),
            destroyedTrucks = 0, checkpointsCompleted = 0, kind = 'TDM', reportData = reportData,
        })
        local pdfString = nil
        if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
            pdfString = PdfGenerator.generateConvoyReport(reportData)
        end
        DiscordLog.finishEvent(rt.id, ('TDM Match Cancelled — %s'):format(rt.def.name), 0x6b7280, {
            { name = 'Outcome', value = 'CANCELLED', inline = true },
            { name = 'Score at cancel', value = ('%s %d - %d %s'):format(rt.gangLabelA, rt.scoreA, rt.scoreB, rt.gangLabelB), inline = true },
        }, '🛑 Match cancelled', pdfString, 'TDM')
    end

    if reason ~= 'CANCELLED' then
        -- Post-match results screen (shared/html.lua's ConvoyUI.showMatchResults
        -- equivalent, reused from Practice Range) — each recipient gets their
        -- own row flagged `you = true`. Points are a display-only formula, not
        -- used anywhere else (gang stats/rewards above already ran off raw
        -- kills/deaths).
        local duration = rt.startedAt and (os.time() - rt.startedAt) or 0
        local durationLabel = ('%d:%02d'):format(math.floor(duration / 60), duration % 60)
        local teamLabel = { A = rt.gangLabelA, B = rt.gangLabelB }
        local function nameOf(p)
            if p.online ~= false and p.source then
                local ok, cn = pcall(Bridge.GetCharacterName, p.source)
                if ok and cn and cn ~= '' then return cn end
            end
            return p.name
        end
        local function pointsOf(p) return math.max(0, p.kills * 100 - p.deaths * 20) end
        -- best player per side, for the Victory/Defeat splash
        local mvp = {}
        for _, p in pairs(rt.players) do
            local cur = mvp[p.team]
            if not cur or pointsOf(p) > cur.points then
                mvp[p.team] = { name = nameOf(p), kills = p.kills, deaths = p.deaths, points = pointsOf(p) }
            end
        end
        local reasonText = ({
            KILLS_A = 'ENEMIES ELIMINATED', KILLS_B = 'ENEMIES ELIMINATED',
            FORFEIT_A = 'OPPONENT FORFEITED', FORFEIT_B = 'OPPONENT FORFEITED',
            TIME = winnerTeam and "TIME'S UP" or "TIME'S UP - NO WINNER",
        })[reason] or 'MATCH COMPLETE'
        local target = (rt.killLimit or 0) > 0 and rt.killLimit or math.max(rt.scoreA, rt.scoreB, 1)
        -- The WINS / DEFEATED banner + the overhead player cards of the recipient's OWN team (best killers first). Everything comes from the
        -- server's own result: the outcome, the kills / deaths, and the Gang XP the payout above really gave.
        local maxCards = math.max(1, math.min(10, math.floor(tonumber((Config.TDM or {}).outcomeCards) or 5)))
        local function cardsFor(team)
            local list = {}
            for _, p in pairs(rt.players) do
                if p.team == team and p.online ~= false and p.source then list[#list + 1] = p end
            end
            table.sort(list, function(a, b)
                if (a.kills or 0) ~= (b.kills or 0) then return (a.kills or 0) > (b.kills or 0) end
                return (a.deaths or 0) < (b.deaths or 0)
            end)
            local out = {}
            for i, p in ipairs(list) do
                if i > maxCards then break end
                local gp = GangService.GetPlayerGang(p.source)
                local paid = payMap[p.source]
                out[#out + 1] = { sid = p.source, name = nameOf(p), rank = gp and gp.rank or nil, xp = paid and paid.xp or nil, kills = p.kills or 0, deaths = p.deaths or 0, place = i }
            end
            return out
        end
        local function bannerFor(recipient)
            local gangName = recipient.team == 'A' and rt.gangA or rt.gangB
            local gangLabel = recipient.team == 'A' and rt.gangLabelA or rt.gangLabelB
            local info = gangName and GangService.GetGangByName(gangName) or nil
            return {
                result = winnerTeam == nil and 'draw' or (recipient.team == winnerTeam and 'win' or 'loss'),
                gangName = gangLabel, logo = info and info.logo or nil, accent = info and info.accentColor or nil,
                eventName = rt.tournament and rt.tournament.title or rt.def.name,
                seconds = math.max(3, math.min(30, math.floor(tonumber((Config.TDM or {}).outcomeSeconds) or 10))),
                cards = cardsFor(recipient.team),
            }
        end
        for _, recipient in pairs(rt.players) do
            if recipient.online ~= false then
                local players = {}
                for _, p in pairs(rt.players) do
                    players[#players + 1] = {
                        name = nameOf(p), team = teamLabel[p.team],
                        kills = p.kills, deaths = p.deaths,
                        points = pointsOf(p),
                        you = (p.source == recipient.source),
                    }
                end
                TriggerClientEvent('nova_convoytruck:tdm:client:matchResults', recipient.source, {
                    mode = 'event', eventName = rt.tournament and rt.tournament.title or rt.def.name, duration = durationLabel,
                    scoreA = rt.scoreA, scoreB = rt.scoreB, players = players,
                    banner = bannerFor(recipient),
                    outcome = {
                        result = winnerTeam == nil and 'draw' or (recipient.team == winnerTeam and 'victory' or 'defeat'),
                        reasonText = reasonText, myTeam = recipient.team,
                        labelA = rt.gangLabelA, labelB = rt.gangLabelB,
                        scoreA = rt.scoreA, scoreB = rt.scoreB, target = target,
                        mvpA = mvp.A, mvpB = mvp.B,
                    },
                })
            end
        end
    end

    end)
    if not okReport then print(('^1[NovaConvoy] TDM match #%s finished, but its bookkeeping failed: %s^0'):format(tostring(rt.id), tostring(errReport))) end

    endEveryonesCombatState(rt)
    for _, p in pairs(rt.players) do
        if p.online ~= false and p.source then TriggerClientEvent('nova_convoytruck:tdm:client:despawnVendor', p.source) end
    end

    -- Hand the raw outcome to the tournament engine last, after all combat
    -- state is torn down, so whatever it does next (e.g. auto-starting the
    -- following match) starts from a clean slate.
    if rt.tournament and rt.tournament.onFinish then
        local stats = {}
        for identifier, p in pairs(rt.players) do
            stats[#stats + 1] = { identifier = identifier, name = p.name, gang = p.gang, kills = p.kills or 0, deaths = p.deaths or 0 }
        end
        rt.tournament.onFinish({
            cancelled = reason == 'CANCELLED', reason = reason,
            scoreA = rt.scoreA, scoreB = rt.scoreB, winnerTeam = winnerTeam, players = stats,
        })
    end
end

-- ── Combat start ─────────────────────────────────────────────────────────────

local function matchTimerThread(rt)
    CreateThread(function()
        while active[rt.id] == rt and rt.phase == 'ACTIVE' do
            Wait(1000)
            if active[rt.id] ~= rt or rt.phase ~= 'ACTIVE' then return end
            rt.timeRemaining = rt.timeRemaining - 1
            if rt.timeRemaining <= 0 then
                rt.timeRemaining = 0
                pushHudUpdate(rt)
                finishMatch(rt, 'TIME')
                return
            end
            pushHudUpdate(rt)
        end
    end)
end

-- defined below; checkStagingReadiness's countdown thread calls it, and a plain local function further down is not visible up here
local beginCombat

local function checkStagingReadiness(rt)
    if not rt or rt.phase ~= 'STAGING' then return end

    local readyA, readyB = 0, 0
    for _, p in pairs(rt.players) do
        if p.online ~= false and p.inStaging then
            if p.team == 'A' then readyA = readyA + 1 else readyB = readyB + 1 end
        end
    end

    local req = rt.stagingRequiredPerTeam or 10
    local isReady = (readyA >= req and readyB >= req)

    -- Broadcast staging status update to everyone
    for _, p in pairs(rt.players) do
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:stagingUpdate', p.source, {
                readyA = readyA,
                readyB = readyB,
                required = req,
                countdown = rt.stagingCountdown,
                gangLabelA = rt.gangLabelA,
                gangLabelB = rt.gangLabelB
            })
        end
    end

    if isReady and not rt.stagingCountdownRunning then
        rt.stagingCountdownRunning = true
        CreateThread(function()
            local cd = 10
            while cd > 0 and active[rt.id] == rt and rt.phase == 'STAGING' do
                rt.stagingCountdown = cd

                -- Check if still ready
                local curA, curB = 0, 0
                for _, p in pairs(rt.players) do
                    if p.online ~= false and p.inStaging then
                        if p.team == 'A' then curA = curA + 1 else curB = curB + 1 end
                    end
                end

                if curA < req or curB < req then
                    -- Cancel countdown
                    rt.stagingCountdownRunning = false
                    rt.stagingCountdown = nil
                    for _, p in pairs(rt.players) do
                        if p.online ~= false then
                            TriggerClientEvent('nova_convoytruck:tdm:client:stagingUpdate', p.source, {
                                readyA = curA,
                                readyB = curB,
                                required = req,
                                countdown = nil,
                                gangLabelA = rt.gangLabelA,
                                gangLabelB = rt.gangLabelB
                            })
                            TriggerClientEvent('nova_convoytruck:client:notify', p.source, 'Player left the Staging Zone! Countdown cancelled.', 'warn')
                        end
                    end
                    return
                end

                for _, p in pairs(rt.players) do
                    if p.online ~= false then
                        TriggerClientEvent('nova_convoytruck:tdm:client:stagingUpdate', p.source, {
                            readyA = curA,
                            readyB = curB,
                            required = req,
                            countdown = cd,
                            gangLabelA = rt.gangLabelA,
                            gangLabelB = rt.gangLabelB
                        })
                    end
                end

                Wait(1000)
                cd = cd - 1
            end

            if active[rt.id] == rt and rt.phase == 'STAGING' then
                rt.stagingCountdownRunning = false
                rt.stagingCountdown = nil
                for _, p in pairs(rt.players) do
                    if p.online ~= false then
                        TriggerClientEvent('nova_convoytruck:runtime:announce', p.source, 'MATCH COMMENCING', 'All fighters ready! Deploying to bases.', 4000, 'tdm')
                    end
                end
                Wait(500)
                beginCombat(rt)
            end
        end)
    end
end

function beginCombat(rt)
    if active[rt.id] ~= rt then return end
    do
        -- players who dropped during the countdown / staging: a match must not run its whole clock against nobody
        local onA, onB = false, false
        for _, pp in pairs(rt.players) do
            if pp.online ~= false then if pp.team == 'A' then onA = true else onB = true end end
        end
        if not onA and not onB then finishMatch(rt, 'TIME') return end
        if not onA then finishMatch(rt, 'FORFEIT_B') return end
        if not onB then finishMatch(rt, 'FORFEIT_A') return end
    end
    rt.phase = 'ACTIVE'

    for _, p in pairs(rt.players) do
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:endStaging', p.source)
        end
    end

    local teamCountA, teamCountB = 0, 0
    for _, p in pairs(rt.players) do
        p.hp = maxHealth()
        p.alive = true
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:hp', p.source, p.hp, maxHealth())
            TriggerClientEvent('nova_convoytruck:tdm:client:beginCombat', p.source, rt.id, rt.zone)

            local spawn = nil
            if p.team == 'A' then
                teamCountA = teamCountA + 1
                spawn = computeDistributedSpawn(rt, 'A', teamCountA)
            else
                teamCountB = teamCountB + 1
                spawn = computeDistributedSpawn(rt, 'B', teamCountB)
            end
            TriggerClientEvent('nova_convoytruck:tdm:client:respawn', p.source, spawn)
        end
    end

    pushHudUpdate(rt, true)

    -- rt.weaponVendorRed / Blue already hold the right per-team spot (see the legacy-fallback note where rt is built);
    -- falling back to the legacy single vendor here would put an unplaced team's ped on top of the other team's.
    local vendorRed = rt.weaponVendorRed
    local vendorBlue = rt.weaponVendorBlue
    local weapons = rt.weapons or (rt.def.tdm and rt.def.tdm.weapons)

    for _, p in pairs(rt.players) do
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:spawnVendors', p.source, vendorRed, vendorBlue, weapons, p.team)
        end
    end

    matchTimerThread(rt)
end

-- ── Public API ───────────────────────────────────────────────────────────────

function Tdm.isActive(convoyId)
    return active[tonumber(convoyId)] ~= nil
end

function Tdm.getActiveIds()
    local list = {}
    for id in pairs(active) do list[#list + 1] = id end
    return list
end

function Tdm.isParticipant(convoyId, source)
    local rt = active[tonumber(convoyId)]
    if not rt then return false end
    local identifier = Bridge.GetIdentifier(source)
    return identifier ~= nil and rt.players[identifier] ~= nil
end

function Tdm.getPublicState(convoyId)
    local rt = active[tonumber(convoyId)]
    if not rt then return nil end
    local gangCount = 0
    for _, p in pairs(rt.players) do
        if p.online ~= false then gangCount = gangCount + 1 end
    end
    return {
        id = rt.id, name = rt.tournament and rt.tournament.title or rt.def.name, status = 'ACTIVE', kind = 'TDM',
        cargo = rt.def.cargo, reward = rt.def.reward,
        currentRouteIndex = 0, totalRoutePoints = 0,
        -- checkpointTimeRemaining deliberately omitted (not just 0) — the
        -- live panel's ConvoyDrawer renders a "Checkpoint" timer box
        -- whenever this field is non-null, which TDM has no equivalent of.
        deliveryTimeRemaining = rt.timeRemaining,
        policeParticipants = 0, gangParticipants = gangCount,
        maxGangParticipants = rt.def.maxGangParticipants, gangPvp = true,
        distinctGangs = 2, maxGangs = 2,
        joinedPoliceEscorts = 0, maxPoliceParticipants = 0,
        tdm = {
            phase = rt.phase, scoreA = rt.scoreA, scoreB = rt.scoreB,
            gangA = rt.gangA, gangB = rt.gangB, gangLabelA = rt.gangLabelA, gangLabelB = rt.gangLabelB,
        },
    }
end

-- Returns the match a given ONLINE source is currently registered in and
-- actively fighting (ACTIVE phase only) — used to gate the weapon vendor.
local function matchForSource(src)
    local identifier = Bridge.GetIdentifier(src)
    if not identifier then return nil end
    for _, rt in pairs(active) do
        if rt.phase == 'ACTIVE' and rt.players[identifier] and rt.players[identifier].source == src then
            return rt, rt.players[identifier]
        end
    end
    return nil
end

-- Scoreboard for the TAB overlay: both teams with every player's kills/deaths.
-- Only an ACTIVE-match participant gets data (matchForSource gates that).
function Tdm.getScoreboard(src)
    local rt = matchForSource(src)
    if not rt then return nil end
    local function row(p)
        local name = p.name
        if p.online ~= false and p.source then
            local ok, cn = pcall(Bridge.GetCharacterName, p.source)
            if ok and cn and cn ~= '' then name = cn end
        end
        return {
            name = name, team = p.team, kills = p.kills or 0, deaths = p.deaths or 0,
            points = math.max(0, (p.kills or 0) * 100 - (p.deaths or 0) * 20),
            alive = p.alive ~= false, you = (p.source == src),
        }
    end
    local A, B = {}, {}
    for _, p in pairs(rt.players) do
        local r = row(p)
        if p.team == 'A' then A[#A + 1] = r else B[#B + 1] = r end
    end
    local function byScore(a, b)
        if a.points ~= b.points then return a.points > b.points end
        return a.kills > b.kills
    end
    table.sort(A, byScore)
    table.sort(B, byScore)
    return {
        mode = 'tdm', title = rt.def and rt.def.name or 'Team Deathmatch',
        seconds = rt.timeRemaining, killLimit = rt.killLimit or 0,
        teams = {
            { key = 'A', label = rt.gangLabelA or 'Team A', score = rt.scoreA or 0, players = A },
            { key = 'B', label = rt.gangLabelB or 'Team B', score = rt.scoreB or 0, players = B },
        },
    }
end

-- Shared by the standalone Standard match (Tdm.start) and by a Tournament
-- match (Tdm.startTournamentMatch): checks the template has a usable arena.
local function setupError(tdmCfg)
    if not tdmCfg.zone or not tdmCfg.zone.points or #tdmCfg.zone.points < 3 then
        return 'Place the combat zone polygon (at least 3 points, Match Setup tab) before starting.'
    end
    local hasSpawns = (tdmCfg.spawnPointsRed and #tdmCfg.spawnPointsRed > 0)
                   or (tdmCfg.spawnPointsBlue and #tdmCfg.spawnPointsBlue > 0)
                   or (tdmCfg.spawnPoints and #tdmCfg.spawnPoints > 0)
                   or (tdmCfg.respawnZoneRed and tdmCfg.respawnZoneRed.points and #tdmCfg.respawnZoneRed.points >= 3)
                   or (tdmCfg.respawnZoneBlue and tdmCfg.respawnZoneBlue.points and #tdmCfg.respawnZoneBlue.points >= 3)
    if not hasSpawns then
        return 'Place at least one respawn spawn point or draw a team base perimeter before starting.'
    end
    return nil
end

-- Every currently-online member of a gang, resolved from the gang's own
-- member list — a tournament has no per-event roster, whoever is online for
-- their gang plays.
function Tdm.onlineGangSources(gangName)
    local list = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        -- On-duty police are never gang participants (same rule as gang
        -- roster management elsewhere in this resource).
        if not Bridge.IsPolice(src) then
            local g = GangService.GetPlayerGang(src)
            if g and g.name == gangName then list[#list + 1] = src end
        end
    end
    return list
end

-- Builds the runtime for a match between two gangs and kicks off the
-- countdown. tournament (optional) = { title, onFinish } marks it as a
-- tournament match — see finishMatch for what that changes.
local function launchMatch(def, convoyId, gangA, gangB, sourcesA, sourcesB, source, tournament)
    local tdmCfg = def.tdm or {}
    local gangLabelA = (GangService.GetGangByName(gangA) or {}).label or gangA
    local gangLabelB = (GangService.GetGangByName(gangB) or {}).label or gangB

    local rt = {
        id = convoyId, def = def, tournament = tournament,
        gangA = gangA, gangB = gangB, gangLabelA = gangLabelA, gangLabelB = gangLabelB,
        scoreA = 0, scoreB = 0,
        duration = tonumber(tdmCfg.duration) or 600,
        timeRemaining = tonumber(tdmCfg.duration) or 600,
        killLimit = tonumber(tdmCfg.killLimit) or 0,
        zone = tdmCfg.zone,
        stagingZone = tdmCfg.stagingZone,
        respawnZoneRed = tdmCfg.respawnZoneRed,
        respawnZoneBlue = tdmCfg.respawnZoneBlue,
        spawnPoints = tdmCfg.spawnPoints or {},
        spawnPointsRed = (tdmCfg.spawnPointsRed and #tdmCfg.spawnPointsRed > 0) and tdmCfg.spawnPointsRed or (tdmCfg.spawnPoints or {}),
        spawnPointsBlue = (tdmCfg.spawnPointsBlue and #tdmCfg.spawnPointsBlue > 0) and tdmCfg.spawnPointsBlue or (tdmCfg.spawnPoints or {}),
        -- The single legacy vendor (tdmCfg.weaponVendor) is only a fallback for an old event with NO per-team vendor at all.
        -- Once either team has its own, the legacy field is just a copy of the Red one — a Blue vendor that was never placed
        -- must stay empty, not appear on top of the Red base (which read as the Blue ped spawning "somewhere else").
        weaponVendorRed = (tdmCfg.weaponVendorRed and tdmCfg.weaponVendorRed.x) and tdmCfg.weaponVendorRed
            or (not (tdmCfg.weaponVendorBlue and tdmCfg.weaponVendorBlue.x) and tdmCfg.weaponVendor or nil),
        weaponVendorBlue = (tdmCfg.weaponVendorBlue and tdmCfg.weaponVendorBlue.x) and tdmCfg.weaponVendorBlue
            or (not (tdmCfg.weaponVendorRed and tdmCfg.weaponVendorRed.x) and tdmCfg.weaponVendor or nil),
        weapons = (tdmCfg.weapons and #tdmCfg.weapons > 0) and tdmCfg.weapons or ((Config.TDM and Config.TDM.weaponVendor and Config.TDM.weaponVendor.items) or {}),
        players = {},
        phase = 'COUNTDOWN',
        startedAt = os.time(),
        startedBySource = source,
    }

    -- Register any custom weapons in damage & label cache
    if rt.weapons then
        for _, it in ipairs(rt.weapons) do
            if it.weapon then
                local h = joaat(it.weapon)
                if not weaponDamageByHash[h] then
                    local cat = tostring(it.type or ''):lower()
                    if cat:find('sniper') then weaponDamageByHash[h] = 75
                    elseif cat:find('shotgun') then weaponDamageByHash[h] = 40
                    elseif cat:find('smg') then weaponDamageByHash[h] = 26
                    elseif cat:find('pistol') then weaponDamageByHash[h] = 28
                    else weaponDamageByHash[h] = 34 end
                end
                if not weaponLabelByHash[h] then
                    weaponLabelByHash[h] = it.label or it.weapon
                end
            end
        end
    end

    local function registerSide(sources, gangName, team)
        for _, src in ipairs(sources) do
            local identifier = Bridge.GetIdentifier(src)
            if identifier then
                rt.players[identifier] = {
                    source = src, identifier = identifier, name = Bridge.GetPlayerName(src) or 'Player',
                    gang = gangName, team = team, kills = 0, deaths = 0, alive = true, online = true,
                    hp = maxHealth(),
                    -- streak: consecutive kills without dying, reset to 0 on
                    -- this player's own death. recentKills: timestamps of
                    -- this player's last few kills, pruned to a trailing
                    -- window — how many fall in that window right now is the
                    -- "multi-kill" count (2 = DOUBLE, 3+ = TRIPLE).
                    streak = 0, recentKills = {},
                }
            end
        end
    end
    registerSide(sourcesA, gangA, 'A')
    registerSide(sourcesB, gangB, 'B')

    active[convoyId] = rt
    if not tournament then ConvoyManager.setStatus(convoyId, 'ACTIVE') end
    if EventProps then EventProps.start(convoyId) end   -- idempotent; a tournament match does not go through setStatus

    rt.startedByName = Bridge.GetPlayerName(source) or 'System / Dispatch'
    DiscordLog.startEvent(convoyId, ('TDM Match — %s'):format(tournament and tournament.title or def.name), 0xff6a00,
        def.shortDescription or 'Team deathmatch underway.', {
            { name = 'Gangs', value = ('%s vs %s'):format(gangLabelA, gangLabelB), inline = true },
            { name = 'Duration', value = ('%dm'):format(math.floor(rt.duration / 60)), inline = true },
        })

    DiscordLog.appendEvent(convoyId, ('⚔️ %s vs %s — match begins (kill limit %s, %dm)'):format(gangLabelA, gangLabelB, rt.killLimit > 0 and tostring(rt.killLimit) or 'none', math.floor(rt.duration / 60)))

    local stagingEnabled = tdmCfg.stagingZone and tdmCfg.stagingZone.enabled and tdmCfg.stagingZone.points and #tdmCfg.stagingZone.points >= 3
    if stagingEnabled then
        rt.phase = 'STAGING'
        rt.stagingRequiredPerTeam = math.max(1, tonumber(tdmCfg.stagingZone.requiredPerTeam) or 10)
        rt.stagingCountdown = nil
        rt.stagingCountdownRunning = false

        -- A staging phase must not wait forever for players that never come (a tournament gang with fewer online players than
        -- the arena needs would block every later fixture). After Config.TDM.stagingTimeoutSeconds the match starts with the
        -- players who are in the zone; a side with nobody in the zone forfeits.
        local timeout = tonumber(Config.TDM and Config.TDM.stagingTimeoutSeconds) or 300
        CreateThread(function()
            Wait(timeout * 1000)
            if active[rt.id] ~= rt or rt.phase ~= 'STAGING' then return end
            local inA, inB = 0, 0
            for _, pp in pairs(rt.players) do
                if pp.online ~= false and pp.inStaging then if pp.team == 'A' then inA = inA + 1 else inB = inB + 1 end end
            end
            if inA > 0 and inB > 0 then
                for _, pp in pairs(rt.players) do
                    if pp.online ~= false then TriggerClientEvent('nova_convoytruck:runtime:announce', pp.source, 'STAGING TIME UP', 'Starting with the fighters who are ready.', 4000, 'tdm') end
                end
                beginCombat(rt)
            elseif inA > 0 then finishMatch(rt, 'FORFEIT_A')
            elseif inB > 0 then finishMatch(rt, 'FORFEIT_B')
            else finishMatch(rt, 'TIME') end
        end)

        for _, p in pairs(rt.players) do
            p.inStaging = false
            if p.online ~= false then
                TriggerClientEvent('nova_convoytruck:tdm:client:enterStaging', p.source, rt.id, rt.stagingZone, rt.stagingRequiredPerTeam, p.team, rt.gangLabelA, rt.gangLabelB)
                TriggerClientEvent('nova_convoytruck:runtime:announce', p.source, 'TDM STAGING OPEN',
                    ('Step into the Staging Zone! Need %d %s & %d %s to begin.'):format(rt.stagingRequiredPerTeam, rt.gangLabelA, rt.stagingRequiredPerTeam, rt.gangLabelB),
                    8000, 'tdm')
            end
        end

        return true
    end

    -- 3-2-1-GO — reuses the exact same prep-countdown NUI path Convoy/Race
    -- already use (see shared/html.lua's ConvoyUI.startPrepCountdown).
    local prep = (Config.TDM and Config.TDM.prepCountdownSeconds) or 5
    for _, p in pairs(rt.players) do
        TriggerClientEvent('nova_convoytruck:runtime:startPrepCountdown', p.source, prep)
    end

    CreateThread(function()
        Wait(prep * 1000)
        beginCombat(rt)
    end)

    return true
end

-- Called from convoy_runtime.lua's doStart for def.kind == 'TDM' — a
-- standalone Standard match between exactly two admin-picked gangs. A
-- Tournament-format definition is only ever a template for the Tournaments
-- tab (tournament.lua), never started directly.
function Tdm.start(source, convoyId)
    local def = ConvoyManager.get(convoyId)
    if not def or def.kind ~= 'TDM' then return false, 'Not a TDM event.' end
    if active[convoyId] then return false, 'This TDM match is already running.' end

    local tdmCfg = def.tdm or {}
    if tostring(tdmCfg.matchFormat or 'STANDARD'):upper() == 'TOURNAMENT' then
        return false, 'This is a tournament template — create and start the tournament from the Tournaments tab.'
    end
    local err = setupError(tdmCfg)
    if err then return false, err end

    local ag = def.settings and def.settings.allowedGangs
    local gangs = (ag and ag.mode == 'SELECTED') and (ag.gangs or {}) or {}
    local gangA = (tdmCfg.teamRedGang and tdmCfg.teamRedGang ~= '') and tdmCfg.teamRedGang or gangs[1]
    local gangB = (tdmCfg.teamBlueGang and tdmCfg.teamBlueGang ~= '') and tdmCfg.teamBlueGang or gangs[2]
    if (not gangA or not gangB) and #gangs == 2 then
        gangA, gangB = gangs[1], gangs[2]
    end
    if not gangA or not gangB or gangA == gangB then
        return false, 'Standard TDM requires exactly 2 distinct participating gangs (Team Red and Team Blue).'
    end

    local function onlineSources(gangName)
        local list = {}
        for _, ident in ipairs((def.roster and def.roster[gangName]) or {}) do
            local src = findSourceByIdentifier(ident)
            if src then list[#list + 1] = src end
        end
        return list
    end
    local sourcesA, sourcesB = onlineSources(gangA), onlineSources(gangB)
    if #sourcesA == 0 or #sourcesB == 0 then
        return false, 'Both gangs need at least one online, registered member to start.'
    end

    launchMatch(def, convoyId, gangA, gangB, sourcesA, sourcesB, source, nil)
    return true, def
end

-- Tournament entry point. Uses the template definition's arena/duration/kill
-- limit but the tournament's own two gangs and every online member of each.
-- Returns ok, err, noShow — noShow = 'A' | 'B' | 'BOTH' when a side has
-- nobody online (the engine turns that into a walkover, not an error).
function Tdm.startTournamentMatch(templateId, gangA, gangB, tournament)
    local def = ConvoyManager.get(templateId)
    if not def or def.kind ~= 'TDM' then return false, "The tournament's TDM template no longer exists." end
    if active[templateId] then return false, 'Another TDM match is already running on this template.' end
    local err = setupError(def.tdm or {})
    if err then return false, err end

    local sourcesA, sourcesB = Tdm.onlineGangSources(gangA), Tdm.onlineGangSources(gangB)
    if #sourcesA == 0 or #sourcesB == 0 then
        local noShow = (#sourcesA == 0 and #sourcesB == 0) and 'BOTH' or (#sourcesA == 0 and 'A' or 'B')
        return false, 'No online members', noShow
    end
    launchMatch(def, templateId, gangA, gangB, sourcesA, sourcesB, nil, tournament)
    return true
end

-- Read-only numbers for /eventdebug (never used by the game itself).
function Tdm.debugState(convoyId)
    local rt = active[tonumber(convoyId)]
    if not rt then return nil end
    local aTotal, bTotal, aOn, bOn = 0, 0, 0, 0
    for _, p in pairs(rt.players) do
        if p.team == 'A' then aTotal = aTotal + 1; if p.online ~= false then aOn = aOn + 1 end
        else bTotal = bTotal + 1; if p.online ~= false then bOn = bOn + 1 end end
    end
    return {
        phase = rt.phase, timeRemaining = rt.timeRemaining, scoreA = rt.scoreA, scoreB = rt.scoreB, killLimit = rt.killLimit,
        gangA = rt.gangA, gangB = rt.gangB, aTotal = aTotal, aOn = aOn, bTotal = bTotal, bOn = bOn,
        stagingCountdown = rt.stagingCountdown, stagingRequired = rt.stagingRequiredPerTeam, startedAt = rt.startedAt,
        tournament = rt.tournament and rt.tournament.title or nil, zonePoints = rt.zone and rt.zone.points and #rt.zone.points or 0,
    }
end

-- Live numbers for the tournament page while a match is running.
function Tdm.getLive(convoyId)
    local rt = active[tonumber(convoyId)]
    if not rt then return nil end
    return {
        phase = rt.phase, scoreA = rt.scoreA, scoreB = rt.scoreB,
        timeRemaining = rt.timeRemaining, duration = rt.duration,
        gangA = rt.gangA, gangB = rt.gangB,
    }
end

function Tdm.forceEnd(source, convoyId)
    local rt = active[tonumber(convoyId)]
    if not rt then return false, 'That TDM match is not running.' end
    finishMatch(rt, 'CANCELLED')
    return true
end

-- Called by client/modules/tdm.lua whenever the LOCAL player's client sees
-- itself land a hit on another player ped while it believes it's in an
-- active TDM match — validated fully here: match must actually be ACTIVE,
-- both players must actually be tracked participants on OPPOSING teams, and
-- the damage amount is looked up from Config.TDM.weaponDamage by the raw
-- weapon hash, never trusted from the client. This is the actual kill/score
-- authority the spec asks for — a modified client can at most choose WHEN to
-- report a real hit it landed, never invent damage or a kill outright.
-- wasHeadshot is a client-reported cosmetic flag ONLY (see tdm.lua) — it
-- never changes the damage amount below, only the kill-feed tag/personal
-- flash, so claiming a false headshot gains nothing but a fancier tag.
local lastHitAt = {}   -- [attacker source] = server time of the last accepted hit report (ms)
AddEventHandler('playerDropped', function() lastHitAt[source] = nil end)

function Tdm.reportHit(source, convoyId, victimServerId, weaponHash, wasHeadshot)
    local rt = active[tonumber(convoyId)]
    if not rt or rt.phase ~= 'ACTIVE' then return end

    local attackerIdentifier = Bridge.GetIdentifier(source)
    local attacker = attackerIdentifier and rt.players[attackerIdentifier]
    if not attacker or attacker.source ~= source or not attacker.alive then return end

    -- The client reports its own hits, so the server bounds what a modified client can do with the event: no faster than the
    -- fastest real weapon fires (Config.TDM.minHitGapMs), and only against someone who is really within reach.
    local nowMs = GetGameTimer()
    local gap = tonumber(Config.TDM and Config.TDM.minHitGapMs) or 45
    if lastHitAt[source] and nowMs - lastHitAt[source] < gap then return end
    local pa, pv = GetPlayerPed(source), GetPlayerPed(tonumber(victimServerId) or -1)
    if pa and pa ~= 0 and pv and pv ~= 0 then
        local maxRange = tonumber(Config.TDM and Config.TDM.maxHitDistance) or 600.0
        if #(GetEntityCoords(pa) - GetEntityCoords(pv)) > maxRange then return end
    end
    lastHitAt[source] = nowMs

    local victim, victimIdentifier
    for ident, p in pairs(rt.players) do
        if p.source == victimServerId then victim, victimIdentifier = p, ident break end
    end
    if not victim or not victim.alive then return end
    if victim.team == attacker.team then return end -- no friendly-fire scoring
    if victim.respawnProtectedUntil and os.time() < victim.respawnProtectedUntil then return end

    local dmg = weaponDamageByHash[tonumber(weaponHash)] or (Config.TDM and Config.TDM.defaultDamage) or 20
    victim.hp = (victim.hp or maxHealth()) - dmg
    if victim.online ~= false then
        TriggerClientEvent('nova_convoytruck:tdm:client:hp', victim.source, math.max(0, victim.hp), maxHealth())
    end
    if victim.hp > 0 then return end -- hit registered, not a kill yet

    victim.alive = false
    victim.deaths = victim.deaths + 1
    victim.streak = 0
    attacker.kills = attacker.kills + 1
    attacker.streak = (attacker.streak or 0) + 1
    if attacker.team == 'A' then rt.scoreA = rt.scoreA + 1 else rt.scoreB = rt.scoreB + 1 end

    -- Report / Discord timeline: first blood, then a score line every 10 team
    -- kills. One line per kill would PATCH the Discord message constantly.
    if not rt.firstBloodLogged then
        rt.firstBloodLogged = true
        DiscordLog.appendEvent(rt.id, ('🩸 First blood — %s (%s) eliminated %s'):format(attacker.name, attacker.gang, victim.name))
    end
    local totalKills = rt.scoreA + rt.scoreB
    if totalKills % 10 == 0 then
        DiscordLog.appendEvent(rt.id, ('📊 Score update — %s %d - %d %s'):format(rt.gangLabelA, rt.scoreA, rt.scoreB, rt.gangLabelB))
    end

    -- Multi-kill window: prune this attacker's kill timestamps older than
    -- the window, then count what's left (including this one).
    local now = os.time()
    attacker.recentKills = attacker.recentKills or {}
    table.insert(attacker.recentKills, now)
    for i = #attacker.recentKills, 1, -1 do
        if now - attacker.recentKills[i] > MULTIKILL_WINDOW_SECONDS then table.remove(attacker.recentKills, i) end
    end
    local multiKillCount = #attacker.recentKills

    -- Same priority order as the reference HUD's own addKill(): headshot
    -- beats a multi-kill, multi-kill beats a bare streak badge.
    local tag, flashType = '', ''
    if wasHeadshot then
        tag, flashType = 'HEAD', 'head'
    elseif multiKillCount >= 3 then
        tag, flashType = 'TRIPLE', 'triple'
    elseif multiKillCount == 2 then
        tag, flashType = 'DOUBLE', 'double'
    elseif attacker.streak >= 4 then
        tag, flashType = (attacker.streak .. 'X'), 'streak'
    end
    local feedType = ({ head = 'headshot', triple = 'triple', double = 'double', streak = 'streak' })[flashType] or ''
    -- seconds a downed player waits before respawning (Config.TDM.respawnDelaySeconds, default 3)
    local respawnDelay = (Config.TDM and Config.TDM.respawnDelaySeconds) or 3
    -- every kill gets a personal "ELIMINATED +100" banner; the special ones above
    -- replace it with their own title
    if flashType == '' then flashType = 'kill' end

    local weaponLabel = weaponLabelByHash[tonumber(weaponHash)] or 'Weapon'
    local attackerTeamLabel = attacker.team == 'A' and rt.gangLabelA or rt.gangLabelB
    local victimTeamLabel = victim.team == 'A' and rt.gangLabelA or rt.gangLabelB
    for _, p in pairs(rt.players) do
        if p.online ~= false then
            TriggerClientEvent('nova_convoytruck:tdm:client:killFeed', p.source, {
                killer = attacker.name, killerTeam = attackerTeamLabel,
                victim = victim.name, victimTeam = victimTeamLabel,
                weapon = weaponLabel, tag = tag, type = feedType, duration = 4000,
            })
        end
    end
    if flashType ~= '' and attacker.online ~= false then
        TriggerClientEvent('nova_convoytruck:tdm:client:eventFlash', attacker.source, flashType, attacker.streak, victim.name, attacker.name)
    end
    -- tell the victim too: they are invincible (server-tracked HP), so without
    -- this nothing on their screen says they were taken out before the respawn
    if victim.online ~= false then
        TriggerClientEvent('nova_convoytruck:tdm:client:eliminated', victim.source, attacker.name, respawnDelay)
    end

    pushHudUpdate(rt)

    local limit = rt.killLimit or 0
    if limit > 0 then
        if rt.scoreA >= limit then finishMatch(rt, 'KILLS_A') return end
        if rt.scoreB >= limit then finishMatch(rt, 'KILLS_B') return end
    end

    -- Small beat before respawn so the kill feed/toast isn't instantly
    -- overwritten by a "back in the fight" toast landing the same frame.
    SetTimeout(respawnDelay * 1000, function()
        if active[rt.id] == rt and not victim.alive then respawnPlayer(rt, victim) end
    end)
end

RegisterNetEvent('nova_convoytruck:tdm:server:reportHit', function(convoyId, victimServerId, weaponHash, wasHeadshot)
    Tdm.reportHit(source, convoyId, victimServerId, weaponHash, wasHeadshot)
end)

RegisterNetEvent('nova_convoytruck:tdm:server:updateStagingPresence', function(convoyId, inZone)
    local src = source
    local rt = active[tonumber(convoyId)]
    if not rt or rt.phase ~= 'STAGING' then return end

    local identifier = Bridge.GetIdentifier(src)
    local p = identifier and rt.players[identifier]
    if not p then return end

    p.inStaging = (inZone == true)
    checkStagingReadiness(rt)
end)

-- Weapon purchase — server-authoritative price/ammo, same cash/bank submenu
-- pattern as server/modules/equipment.lua's police tactical vendor, gated to
-- an alive, currently-ACTIVE-match participant instead of an on-duty officer.
RegisterNetEvent('nova_convoytruck:tdm:server:purchase', function(itemIndex, account)
    local src = source
    local rt, p = matchForSource(src)
    if not rt or not p then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'You must be an active TDM participant to buy weapons.', 'error')
        return
    end
    if not p.alive then
        TriggerClientEvent('nova_convoytruck:client:notify', src, 'You cannot buy weapons while eliminated.', 'error')
        return
    end

    local cfg = Config.TDM and Config.TDM.weaponVendor
    account = (account == 'bank' or account == 'cash') and account or ((cfg and cfg.moneyAccount) or 'cash')

    local items = (rt.weapons and #rt.weapons > 0) and rt.weapons or ((cfg and cfg.items) or {})
    local idx = tonumber(itemIndex) or 0
    local item = items[idx]
    if not item then return end

    local price = tonumber(item.price) or 0
    local ok = Bridge.RemoveMoney(src, price, account)
    if not ok then
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Insufficient %s funds.'):format(account), 'error')
        return
    end

    local itemName = tostring(item.weapon or ''):lower()
    local ammoCount = tonumber(item.ammo) or 60
    -- ONE weapon carrying its ammo (passing the ammo as the item COUNT handed out up to 999 weapons / failed on ox_inventory)
    local given = Inventory.AddItem(src, itemName, 1, { tdm = true, matchId = rt.id, ammo = ammoCount })
    if not given then
        Bridge.AddMoney(src, price, account) -- refund
        TriggerClientEvent('nova_convoytruck:client:notify', src, ('Could not give "%s" — item not found in your inventory system, refunded.'):format(itemName), 'error')
        return
    end

    -- Track TDM-issued weapon and ammo so they are removed cleanly on match end without touching player's personal weapons
    p.tdmPurchasedItems = p.tdmPurchasedItems or {}
    p.tdmPurchasedItems[#p.tdmPurchasedItems + 1] = {
        item = itemName,
        count = 1,
        ammo = ammoCount,
    }

    TriggerClientEvent('nova_convoytruck:client:notify', src, ('Purchased %s (%d ammo) [TDM Match Only].'):format(item.label or item.weapon, ammoCount), 'success')
end)

-- A disconnecting participant just goes offline in place (never removed from
-- `players`, so their final kills/deaths still count toward their gang's
-- totals at finishMatch) — if that empties one whole side, the match ends as
-- a forfeit instead of running out the clock against nobody.
local function playerLeftMatch(src)
    if not src then return end
    -- Looked up by server id, not by citizen id: when a player drops, qbx_core can already have removed the character, so
    -- Bridge.GetIdentifier(src) is nil by now and the player used to stay 'online' (no forfeit, events sent to a stale id).
    for _, rt in pairs(active) do
        for _, p in pairs(rt.players) do
            if p.source == src and p.online ~= false then
                purgePlayerTdmEquipment(p)
                p.online = false
                -- a character switch keeps this client alive: end the match for it (zone lock, invincibility, HUD)
                TriggerClientEvent('nova_convoytruck:tdm:client:endMatch', src)
                -- a side with nobody left online forfeits, in the countdown / staging phase just like in combat
                if rt.phase ~= 'COMPLETE' then
                    local anyOnlineA, anyOnlineB = false, false
                    for _, pp in pairs(rt.players) do
                        if pp.online ~= false then
                            if pp.team == 'A' then anyOnlineA = true else anyOnlineB = true end
                        end
                    end
                    if not anyOnlineA and not anyOnlineB then finishMatch(rt, 'TIME')
                    elseif not anyOnlineA then finishMatch(rt, 'FORFEIT_B')
                    elseif not anyOnlineB then finishMatch(rt, 'FORFEIT_A') end
                end
            end
        end
    end
end

AddEventHandler('playerDropped', function() playerLeftMatch(source) end)
-- switching to another character (multichar) is leaving the match for the old one
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src) pcall(playerLeftMatch, src) end)

return Tdm
