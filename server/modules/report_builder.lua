-- ─── Nova Convoy — After-Action report data for TDM + Container Wars ──────────────
-- Convoy / Airdrop / Hot Cargo / Gang Rally build their report in
-- convoy_runtime.lua (buildConvoyReportData). TDM and Container Wars run in
-- their own runtimes and used to store a bare record, so their Event History
-- "Report" opened empty and no PDF / Discord report existed for them.
--
-- This builds the SAME shape (interceptions / gangScorecard / timeline /
-- branding / roster / rewards ...) plus a `labels` block. `labels` is what
-- tells pdf_generator.lua and AuditReportModal.svelte to use this kind's own
-- wording and columns instead of the convoy defaults:
--   sec1Cols  5 column headings for the first table
--   sec2Cols  4 column headings for the second table (each scorecard row
--             carries matching `cells`)
--
-- Both builders also accept rows from BEFORE this existed (see
-- ReportBuilder.legacy), so old history entries open a proper report too.

ReportBuilder = {}

local function money(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return '$' .. out
end

local function durationText(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return ('%dm %02ds'):format(math.floor(sec / 60), sec % 60)
end

local function utc(ts)
    return os.date('!%a, %d %b %Y %H:%M:%S UTC', ts)
end

local function brandingBlock(docSuffix)
    local branding = Config.Branding or {}
    local operationName = branding.operationName or 'Nova Convoy'
    local pFooter = branding.pdfFooter or ('%s SYSTEM  |  CONFIDENTIAL AUTOMATED AUDIT & AFTER-ACTION REPORT'):format(operationName:upper())
    if pFooter:find('%%s') then pFooter = pFooter:format(operationName:upper()) end
    return {
        serverName = branding.serverName or 'Nova',
        operationName = operationName,
        tabletTitle = branding.tabletTitle or 'Operations Hub',
        pdfTitle = ('%s -- %s'):format(operationName:upper(), docSuffix),
        pdfFooter = pFooter,
    }
end

-- ── Shared sections: what was really paid out ────────────────────────────────
-- Read from RewardService's payout ledger (one entry per player per payout, Gang XP included). Every event kind adds the same
-- "PAYOUTS & GANG XP" table to its report and the same field to its Discord message through these two helpers.

local function payoutAggregate(convoyId)
    local rows, byKey, gangXp, gangOrder = {}, {}, {}, {}
    if not (RewardService and RewardService.GetPayouts) or convoyId == nil then return rows, gangXp, gangOrder end
    for _, e in ipairs(RewardService.GetPayouts(convoyId)) do
        local key = tostring(e.identifier or e.player) .. '|' .. tostring(e.kind or '')
        local r = byKey[key]
        if not r then
            r = { player = e.player or 'Unknown', gang = e.gang or '-', kind = e.kind or 'Payout', texts = {}, xp = 0 }
            byKey[key] = r
            rows[#rows + 1] = r
        end
        if e.text and e.text ~= '' then r.texts[#r.texts + 1] = e.text end
        if e.xp and e.xp > 0 then
            r.xp = r.xp + e.xp
            if gangXp[r.gang] == nil then gangOrder[#gangOrder + 1] = r.gang end
            gangXp[r.gang] = (gangXp[r.gang] or 0) + e.xp
        end
    end
    return rows, gangXp, gangOrder
end

-- A PDF / report table: who was paid what (and how much Gang XP), or nil when nothing was paid.
function ReportBuilder.payoutTable(convoyId)
    local rows = payoutAggregate(convoyId)
    if #rows == 0 then return nil end
    local out = {}
    for i, r in ipairs(rows) do
        if i > 80 then break end
        out[#out + 1] = { r.player, r.gang, r.kind, #r.texts > 0 and table.concat(r.texts, ' + ') or '-', r.xp > 0 and ('+%d XP'):format(r.xp) or '-' }
    end
    if #rows > 80 then out[#out + 1] = { ('... and %d more'):format(#rows - 80), '', '', '', '' } end
    return {
        title = 'PAYOUTS & GANG XP',
        cols = {
            { label = 'PLAYER', x = 44, chars = 17 }, { label = 'GANG', x = 148, chars = 15 }, { label = 'PAID FOR', x = 236, chars = 19 },
            { label = 'REWARD', x = 328, chars = 28, wrap = true }, { label = 'GANG XP', x = 480, chars = 10 },
        },
        rows = out,
        empty = '* Nothing was paid out.',
    }
end

-- Discord embed fields: a short who-got-what list and the Gang XP each gang earned (empty list when nothing was paid).
function ReportBuilder.payoutFields(convoyId)
    local rows, gangXp, gangOrder = payoutAggregate(convoyId)
    local fields = {}
    if #rows == 0 then return fields end
    local lines = {}
    for i, r in ipairs(rows) do
        if i > 8 then lines[#lines + 1] = ('... and %d more (see the report)'):format(#rows - 8) break end
        local parts = {}
        if #r.texts > 0 then parts[#parts + 1] = table.concat(r.texts, ' + ') end
        if r.xp > 0 then parts[#parts + 1] = ('+%d Gang XP'):format(r.xp) end
        lines[#lines + 1] = ('• **%s** (%s) — %s: %s'):format(r.player, r.gang, r.kind, #parts > 0 and table.concat(parts, ', ') or '-')
    end
    fields[#fields + 1] = { name = ('💰 Payouts (%d)'):format(#rows), value = table.concat(lines, '\n'):sub(1, 1000), inline = false }
    if #gangOrder > 0 then
        local xp = {}
        for _, g in ipairs(gangOrder) do xp[#xp + 1] = ('**%s** +%d XP'):format(g, gangXp[g]) end
        fields[#fields + 1] = { name = '⭐ Gang XP earned', value = table.concat(xp, '\n'):sub(1, 1000), inline = false }
    end
    return fields
end

-- One text line for the report's "rewards" summary: what was really paid, falling back to `configured`.
function ReportBuilder.payoutSummary(convoyId, configured)
    local rows, gangXp, gangOrder = payoutAggregate(convoyId)
    if #rows == 0 then return configured or 'None' end
    local parts, seen = {}, {}
    for _, r in ipairs(rows) do
        for _, t in ipairs(r.texts) do
            if not seen[t] then seen[t] = true; parts[#parts + 1] = t end
        end
    end
    for _, g in ipairs(gangOrder) do parts[#parts + 1] = ('%s: +%d Gang XP'):format(g, gangXp[g]) end
    local s = table.concat(parts, ' | ')
    if #s > 220 then s = s:sub(1, 217) .. '...' end
    return s ~= '' and s or (configured or 'None')
end

-- Adds the payout table to a report's extraTables (creating the list when the report has none yet).
function ReportBuilder.addPayoutTable(report, convoyId, titleSuffix)
    local t = ReportBuilder.payoutTable(convoyId)
    if not t then return report end
    if titleSuffix then t.title = t.title .. titleSuffix end
    report.extraTables = report.extraTables or {}
    report.extraTables[#report.extraTables + 1] = t
    return report
end

-- ── TDM ──────────────────────────────────────────────────────────────────────
-- i: { id, name, startedAt, endedAt, outcome, reason, startedByName, forcedByName,
--      gangA, gangB, gangLabelA, gangLabelB, scoreA, scoreB, matchFormat,
--      players = { {name, gang, gangLabel, kills, deaths}, ... },
--      rewards, timeline, startTimeStr?, endTimeStr? }
function ReportBuilder.tdm(i)
    local now = i.endedAt or os.time()
    local startedAt = i.startedAt or now
    local dur = i.durationSeconds or math.max(0, now - startedAt)
    local scoreA, scoreB = i.scoreA or 0, i.scoreB or 0
    local labelA, labelB = i.gangLabelA or i.gangA or 'Team A', i.gangLabelB or i.gangB or 'Team B'

    local winnerGang, winnerLabel
    if scoreA > scoreB then winnerGang, winnerLabel = i.gangA, labelA
    elseif scoreB > scoreA then winnerGang, winnerLabel = i.gangB, labelB end
    if i.winnerGang ~= nil then winnerGang = i.winnerGang end
    if i.winnerLabel ~= nil then winnerLabel = i.winnerLabel end

    local outcome = i.outcome or 'COMPLETED'
    local cancelled = outcome == 'CANCELLED'
    local winnerText
    if cancelled then winnerText = 'Cancelled by Administrator'
    elseif winnerLabel then winnerText = winnerLabel
    else winnerText = 'Draw' end

    local players = {}
    local teamStats = {
        [i.gangA or 'A'] = { label = labelA, players = 0, kills = 0, deaths = 0 },
        [i.gangB or 'B'] = { label = labelB, players = 0, kills = 0, deaths = 0 },
    }
    for _, p in ipairs(i.players or {}) do
        players[#players + 1] = p
        local t = teamStats[p.gang]
        if t then
            t.players = t.players + 1
            t.kills = t.kills + (p.kills or 0)
            t.deaths = t.deaths + (p.deaths or 0)
        end
    end
    table.sort(players, function(a, b)
        if (a.kills or 0) ~= (b.kills or 0) then return (a.kills or 0) > (b.kills or 0) end
        return (a.deaths or 0) < (b.deaths or 0)
    end)

    local interceptions = {}
    for rank, p in ipairs(players) do
        local k, d = p.kills or 0, p.deaths or 0
        interceptions[#interceptions + 1] = {
            time = ('#%d'):format(rank),
            target = p.gangLabel or p.gang or 'Team',
            method = ('%d K / %d D'):format(k, d),
            actorName = p.name or 'Player',
            actorIdentifier = p.identifier or 'N/A',
            faction = '',
            evidence = ('K/D %.2f'):format(d == 0 and k or (k / d)),
            isAlert = false,
        }
    end

    local scorecard = {}
    for _, gang in ipairs({ i.gangA, i.gangB }) do
        local t = teamStats[gang or '']
        if t then
            local result = cancelled and 'Cancelled' or (winnerGang == gang and 'WINNER' or (winnerGang and 'Lost' or 'Draw'))
            scorecard[#scorecard + 1] = {
                name = gang, label = t.label, units = t.players,
                rewardSummary = result,
                cells = { tostring(t.players), tostring(t.kills), tostring(t.deaths), result },
            }
        end
    end

    local outcomeLabel = cancelled and 'CANCELLED' or (winnerGang and 'MATCH COMPLETE' or 'DRAW')
    local badge = cancelled and { 0.45, 0.50, 0.58 } or (winnerGang and { 0.97, 0.45, 0.0 } or { 0.45, 0.50, 0.58 })
    local reasonText = ({
        KILLS_A = 'Kill limit', KILLS_B = 'Kill limit', TIME = 'Time up',
        FORFEIT_A = 'Forfeit', FORFEIT_B = 'Forfeit', CANCELLED = 'Cancelled',
    })[i.reason or ''] or (i.reason or '—')

    return {
        id = i.id,
        kind = 'TDM',
        name = i.name,
        cargoDescription = i.matchFormat == 'TOURNAMENT' and 'Tournament Match' or 'Standard Match',
        startedByName = i.startedByName or 'System / Dispatch',
        startedAt = startedAt,
        endedAt = now,
        startTimeStr = i.startTimeStr or utc(startedAt),
        endTimeStr = i.endTimeStr or utc(now),
        durationSeconds = dur,
        durationText = durationText(dur),
        outcome = outcome,
        winner = winnerText,
        winningGang = winnerGang,
        forcedByName = i.forcedByName,
        summaryLine = cancelled and ('Cancelled at %d - %d'):format(scoreA, scoreB) or ('%s %d - %d %s · %s'):format(labelA, scoreA, scoreB, labelB, reasonText),
        branding = brandingBlock('TDM MATCH REPORT'),
        fleet = { total = 0, delivered = 0, captured = 0, destroyed = 0, disabled = 0, hijacked = 0, trucks = {} },
        roster = { policeCount = 0, gangCount = #players, gangs = {} },
        interceptions = interceptions,
        gangScorecard = scorecard,
        policeAudit = {},
        pvpHijacks = {},
        airdropCaptures = {},
        rewards = i.rewards or 'None',
        timeline = i.timeline or {},
        labels = {
            docTitle = 'TDM MATCH REPORT',
            classLabel = 'TDM COMBAT AUDIT',
            stripe = { 1.0, 0.42, 0.0 },
            outcomeLabel = outcomeLabel,
            badge = badge,
            winnerTitle = 'WINNING TEAM',
            winnerSub = ('%s %d - %d %s'):format(labelA, scoreA, scoreB, labelB),
            forcesTitle = 'DURATION & PLAYERS',
            forces = ('Players: %d  |  %s'):format(#players, reasonText),
            card4 = { title = 'FINAL SCORE', main = ('%d - %d'):format(scoreA, scoreB), sub = ('%s vs %s'):format(labelA, labelB) },
            sec1Title = 'PLAYER PERFORMANCE',
            sec1Cols = { 'RANK', 'TEAM', 'KILLS / DEATHS', 'PLAYER', 'K/D' },
            sec1Empty = '* No individual player stats were recorded for this match.',
            sec2Title = 'TEAM SCORECARD',
            sec2Cols = { 'PLAYERS', 'KILLS', 'DEATHS', 'RESULT' },
            sec2Empty = '* No team data was recorded for this match.',
        },
    }
end

-- ── Container Wars ───────────────────────────────────────────────────────────
-- i: { id, name, startedAt, endedAt, outcome, startedByName, forcedByName,
--      topGang, topGangLabel,
--      containers = { {containerIndex, name, finalBid, winningGang, winningGangName,
--                      winningPlayer, status}, ... },
--      gangStats = { [gangName] = { label, won, spend, bids } },
--      rewards, timeline, startTimeStr?, endTimeStr? }
function ReportBuilder.containerWars(i)
    local now = i.endedAt or os.time()
    local startedAt = i.startedAt or now
    local dur = i.durationSeconds or math.max(0, now - startedAt)
    local outcome = i.outcome or 'COMPLETED'
    local cancelled = outcome == 'CANCELLED'

    local interceptions, soldCount, totalSpend = {}, 0, 0
    local detailRows, payouts = {}, {}
    for idx, c in ipairs(i.containers or {}) do
        local sold = c.winningGangName ~= nil and (c.status == 'WON' or c.status == 'CLAIMED')
        if sold then
            soldCount = soldCount + 1
            totalSpend = totalSpend + (c.finalBid or 0)
        end
        -- never auctioned: the event ended (or was cancelled) before this lot came up
        local reached = sold or c.status == 'UNSOLD'
        local lotNo = c.containerIndex or idx
        local timeLabel = c.round and ('R%d #%d'):format(c.round, lotNo) or ('#%d'):format(lotNo)
        local method, evidence
        if sold then
            method = money(c.finalBid)
            evidence = c.status == 'CLAIMED' and 'Won - crate claimed' or 'Won - not claimed'
        elseif not reached then
            method, evidence = '-', 'Not reached'
        elseif c.unsoldReason == 'PAYMENT_FAILED' then
            method, evidence = 'Unpaid', 'Unsold - winner could not pay'
        else
            method, evidence = 'No bids', 'Unsold - no bids'
        end
        interceptions[#interceptions + 1] = {
            time = timeLabel,
            target = c.name or ('Container %d'):format(idx),
            method = method,
            actorName = sold and (c.winningPlayer or 'Unknown') or '-',
            actorIdentifier = c.winningPlayerIdentifier or 'N/A',
            faction = sold and ((c.isCivilian or c.winningGang == 'civilian' or c.winningGangName == 'civilian') and 'Civilian' or (c.winningGang or c.winningGangName or '')) or '',
            evidence = evidence,
            isAlert = false,
        }

        local contents = c.rewardsText or 'None'
        detailRows[#detailRows + 1] = {
            '#' .. lotNo,
            c.round and ('R%d / Spot %d'):format(c.round, c.spotIndex or lotNo) or '-',
            reached and ('%s -> %s'):format(money(c.startingBid or 0), money(c.finalBid or 0)) or '-',
            tostring(c.bidCount or 0),
            contents,
            c.claimedByName or (sold and 'Not opened' or '-'),
        }
        if sold and contents ~= 'None' then
            payouts[#payouts + 1] = ('#%d: %s'):format(lotNo, contents)
        end
    end

    -- Event-level payout line: what the winning lots actually contained
    local rewardsText = i.rewards
    if (rewardsText == nil or rewardsText == 'None') and #payouts > 0 then
        rewardsText = table.concat(payouts, ' | ')
        if #rewardsText > 160 then rewardsText = rewardsText:sub(1, 157) .. '...' end
    end
    local extraTables = nil
    if #detailRows > 0 then
        extraTables = { {
            title = 'LOT DETAILS',
            cols = {
                { label = 'LOT', x = 44, chars = 6 }, { label = 'ROUND / SPOT', x = 80, chars = 16 },
                { label = 'START -> FINAL', x = 160, chars = 22 }, { label = 'BIDS', x = 258, chars = 5 },
                { label = 'CONTENTS', x = 292, chars = 44, wrap = true }, { label = 'OPENED BY', x = 470, chars = 14 },
            },
            rows = detailRows,
        } }
    end

    -- Scorecard: one row per gang that bid, most containers first.
    local statList = {}
    for name, g in pairs(i.gangStats or {}) do
        statList[#statList + 1] = { name = name, label = g.label or name, won = g.won or 0, spend = g.spend or 0, bids = g.bids or 0 }
    end
    table.sort(statList, function(a, b)
        if a.won ~= b.won then return a.won > b.won end
        return a.spend > b.spend
    end)
    local scorecard = {}
    for _, g in ipairs(statList) do
        local result = cancelled and 'Cancelled' or (g.name == i.topGang and 'TOP BIDDER' or (g.won > 0 and 'Won lots' or 'No wins'))
        scorecard[#scorecard + 1] = {
            name = g.name, label = g.label, units = g.bids,
            rewardSummary = result,
            cells = { tostring(g.won), money(g.spend), tostring(g.bids), result },
        }
    end

    local winnerText
    if cancelled then winnerText = 'Cancelled by Administrator'
    elseif i.topGang then
        local won = (i.gangStats and i.gangStats[i.topGang] and i.gangStats[i.topGang].won) or 0
        winnerText = ('%s (%d lot%s)'):format(i.topGangLabel or i.topGang, won, won == 1 and '' or 's')
    else winnerText = 'No lots sold' end

    local lotCount = #(i.containers or {})
    return {
        id = i.id,
        kind = 'CONTAINER_WARS',
        name = i.name,
        cargoDescription = 'Harbour Container Auction',
        startedByName = i.startedByName or 'System / Dispatch',
        startedAt = startedAt,
        endedAt = now,
        startTimeStr = i.startTimeStr or utc(startedAt),
        endTimeStr = i.endTimeStr or utc(now),
        durationSeconds = dur,
        durationText = durationText(dur),
        outcome = outcome,
        winner = winnerText,
        winningGang = i.topGang,
        forcedByName = i.forcedByName,
        summaryLine = cancelled and 'Cancelled by administrator' or ('%d of %d lots sold · %s total · %d bidding gang%s'):format(soldCount, lotCount, money(totalSpend), #statList, #statList == 1 and '' or 's'),
        branding = brandingBlock('CONTAINER WARS AUCTION REPORT'),
        fleet = { total = lotCount, delivered = soldCount, captured = 0, destroyed = 0, disabled = 0, hijacked = 0, trucks = {} },
        roster = { policeCount = 0, gangCount = #statList, gangs = {} },
        interceptions = interceptions,
        gangScorecard = scorecard,
        policeAudit = {},
        pvpHijacks = {},
        airdropCaptures = {},
        rewards = rewardsText or 'None',
        extraTables = extraTables,
        timeline = i.timeline or {},
        labels = {
            docTitle = 'CONTAINER WARS AUCTION REPORT',
            classLabel = 'HARBOUR AUCTION AUDIT',
            stripe = { 0.32, 0.82, 0.29 },
            outcomeLabel = cancelled and 'CANCELLED' or (soldCount > 0 and 'AUCTION CONCLUDED' or 'NO SALES'),
            badge = cancelled and { 0.45, 0.50, 0.58 } or (soldCount > 0 and { 0.32, 0.82, 0.29 } or { 0.85, 0.35, 0.15 }),
            winnerTitle = 'TOP BIDDER',
            winnerSub = i.topGang and ('Gang: %s'):format(i.topGang) or 'No winning gang',
            forcesTitle = 'DURATION & BIDDERS',
            forces = ('Bidding gangs: %d  |  Lots: %d%s'):format(#statList, lotCount, i.totalRounds and ('  |  Rounds: %d'):format(i.totalRounds) or ''),
            card4 = { title = 'AUCTION TOTALS', main = ('%s spent'):format(money(totalSpend)), sub = ('Sold %d of %d lots'):format(soldCount, lotCount) },
            sec1Title = 'CONTAINER LOT RESULTS',
            sec1Cols = { 'LOT', 'CONTAINER', 'FINAL BID', 'WINNING BIDDER & GANG', 'STATUS' },
            sec1Empty = '* No containers were put up for auction.',
            sec2Title = 'GANG BIDDING SCORECARD',
            sec2Cols = { 'LOTS WON', 'TOTAL SPEND', 'BIDS PLACED', 'RESULT' },
            sec2Empty = '* No gang placed a bid during this auction.',
        },
    }
end

-- ── Gang Territory Auction ───────────────────────────────────────────────────
-- i: same shape as ReportBuilder.containerWars, with `containers` = the territory lots
--    { containerIndex, name, finalBid, startingBid, bidCount, winningGang(Name), winningPlayer, status, unsoldReason }.
-- Built on the Container Wars report (an auction is an auction) with the territory wording.
function ReportBuilder.territoryAuction(i)
    local r = ReportBuilder.containerWars(i)
    r.kind = 'GANG_TERRITORY'
    r.cargoDescription = 'Gang Territory Auction'
    r.summaryLine = tostring(r.summaryLine or ''):gsub('lots', 'territories')
    r.branding = brandingBlock('GANG TERRITORY AUCTION REPORT')
    local l = r.labels
    l.docTitle = 'GANG TERRITORY AUCTION REPORT'
    l.classLabel = 'TERRITORY AUCTION AUDIT'
    l.stripe = { 0.90, 0.30, 0.34 }
    l.badge = (i.outcome == 'CANCELLED') and { 0.45, 0.50, 0.58 } or { 0.90, 0.30, 0.34 }
    l.winnerTitle = 'TOP BIDDER'
    l.card4 = { title = 'AUCTION TOTALS', main = l.card4 and l.card4.main or '', sub = (l.card4 and l.card4.sub or ''):gsub('lots', 'territories') }
    l.sec1Title = 'TERRITORY LOT RESULTS'
    l.sec1Cols = { 'LOT', 'TERRITORY', 'FINAL BID', 'WINNING BIDDER & GANG', 'STATUS' }
    l.sec1Empty = '* No territories were put up for auction.'
    l.sec2Title = 'GANG BIDDING SCORECARD'
    l.sec2Empty = '* No gang placed a bid during this auction.'
    r.extraTables = nil
    return r
end

-- ── Territory War ────────────────────────────────────────────────────────────
-- i: { id, name, territoryName, startedAt, endedAt, outcome (COMPLETED | CANCELLED), result (CAPTURED | DEFENDED | NO_SHOW |
--      CANCELLED), attacker, defender, attackerLabel, defenderLabel, winnerGang, winnerLabel, note, penaltyTaken,
--      members = { { name, identifier, gang, gangLabel }, ... }  (everyone seen alive in the territory),
--      timeline, startedByName }
function ReportBuilder.territoryWar(i)
    local now = i.endedAt or os.time()
    local startedAt = i.startedAt or now
    local dur = i.durationSeconds or math.max(0, now - startedAt)
    local result = i.result or 'COMPLETED'
    local cancelled = i.outcome == 'CANCELLED' or result == 'CANCELLED'
    local aLabel, dLabel = i.attackerLabel or i.attacker or 'Attacker', i.defenderLabel or i.defender or 'Defender'

    local count = { [i.attacker or 'A'] = 0, [i.defender or 'D'] = 0 }
    local interceptions = {}
    for rank, m in ipairs(i.members or {}) do
        count[m.gang] = (count[m.gang] or 0) + 1
        interceptions[#interceptions + 1] = {
            time = ('#%d'):format(rank), target = m.gangLabel or m.gang or '', method = (m.gang == i.attacker) and 'Attacker' or 'Defender',
            actorName = m.name or 'Player', actorIdentifier = m.identifier or 'N/A', faction = '', evidence = 'Present in the territory', isAlert = false,
        }
    end
    local function row(gang, label, role)
        local res = cancelled and 'Cancelled' or (i.winnerGang == gang and 'WINNER' or 'Lost')
        return { name = gang, label = label, units = count[gang] or 0, rewardSummary = res, cells = { role, tostring(count[gang] or 0), res, '' } }
    end
    local scorecard = { row(i.attacker, aLabel, 'Attacker'), row(i.defender, dLabel, 'Defender') }

    local resultText = ({
        CAPTURED = 'Attackers won the war', DEFENDED = 'Defenders won the war', NO_SHOW = 'No show — owner keeps it, XP penalty',
        CANCELLED = 'Cancelled',
    })[result] or result
    local winnerText = cancelled and 'Cancelled' or (i.winnerLabel or 'Owner keeps the territory')
    return {
        id = i.id, kind = 'GANG_TERRITORY', name = i.name, cargoDescription = 'Territory War',
        startedByName = i.startedByName or 'System / Schedule',
        startedAt = startedAt, endedAt = now, startTimeStr = utc(startedAt), endTimeStr = utc(now),
        durationSeconds = dur, durationText = durationText(dur), outcome = i.outcome or 'COMPLETED', winner = winnerText,
        winningGang = i.winnerGang, branding = brandingBlock('TERRITORY WAR REPORT'),
        summaryLine = cancelled and 'Cancelled' or ('%s vs %s over %s · %s'):format(aLabel, dLabel, i.territoryName or '?', resultText),
        fleet = { total = 0, delivered = 0, captured = 0, destroyed = 0, disabled = 0, hijacked = 0, trucks = {} },
        roster = { policeCount = 0, gangCount = 2, gangs = {} },
        interceptions = interceptions, gangScorecard = scorecard,
        policeAudit = {}, pvpHijacks = {}, airdropCaptures = {},
        rewards = ((i.penaltyTaken or 0) > 0 and ('%s lost %d Gang XP (no-show)'):format(i.winnerLabel or dLabel, i.penaltyTaken)) or i.note or 'None',
        timeline = i.timeline or {},
        labels = {
            docTitle = 'TERRITORY WAR REPORT', classLabel = 'TERRITORY WAR AUDIT', stripe = { 0.77, 0.37, 0.88 },
            outcomeLabel = cancelled and 'CANCELLED' or result, badge = cancelled and { 0.45, 0.50, 0.58 } or { 0.77, 0.37, 0.88 },
            winnerTitle = 'WAR RESULT', winnerSub = ('%s vs %s over %s'):format(aLabel, dLabel, i.territoryName or '?'),
            forcesTitle = 'DURATION & PRESENCE', forces = ('Present: %d  |  %s'):format(#(i.members or {}), resultText),
            card4 = (i.xpAwarded or 0) > 0 and { title = 'GANG XP SPOILS', main = ('+%d XP'):format(i.xpAwarded), sub = ('to %s'):format(i.winnerLabel or aLabel) }
                or { title = 'XP PENALTY', main = (i.penaltyTaken or 0) > 0 and ('-%d XP'):format(i.penaltyTaken) or 'None', sub = resultText },
            sec1Title = 'PLAYERS PRESENT IN THE TERRITORY', sec1Cols = { 'RANK', 'GANG', 'ROLE', 'PLAYER', 'STATUS' },
            sec1Empty = '* Nobody from either gang was alive in the territory.',
            sec2Title = 'GANG SCORECARD', sec2Cols = { 'ROLE', 'PRESENT', 'RESULT', '' },
            sec2Empty = '* No gang data was recorded for this war.',
        },
    }
end

-- ── Operation Crackdown (Gang vs Police) ─────────────────────────────────────
-- i: { id, name, startedAt, endedAt, fightStartedAt, outcome (COMPLETED | CANCELLED), result (GANG | POLICE | DRAW | NO_CONTEST |
--      CANCELLED), reason, gang, gangLabel, standing = { GANG, POLICE } (fighters still up at the end), totals = { GANG, POLICE },
--      winnerLabel, players = { { name, identifier, side, kills, eliminated, eliminatedReason }, ... }, timeline, startedByName,
--      forcedByName, rewardsText, zoneText, penaltyXp }
-- No points: the report lists who survived and who was eliminated (and why). Same generic shape as the territory war report.
function ReportBuilder.crackdown(i)
    local now = i.endedAt or os.time()
    local startedAt = i.startedAt or now
    local dur = math.max(0, now - startedAt)
    local result = i.result or 'COMPLETED'
    local cancelled = i.outcome == 'CANCELLED'
    local gLabel = i.gangLabel or i.gang or 'Gang'
    local st = i.standing or {}
    local tot = i.totals or {}
    local sg, sp = st.GANG or 0, st.POLICE or 0

    local kills = { GANG = 0, POLICE = 0 }
    local rows = {}
    for rank, p in ipairs(i.players or {}) do
        kills[p.side] = (kills[p.side] or 0) + (p.kills or 0)
        rows[#rows + 1] = {
            time = ('#%d'):format(rank), target = p.side == 'POLICE' and 'Police' or gLabel,
            method = p.eliminated and 'Eliminated' or 'Survived',
            actorName = p.name or 'Player', actorIdentifier = p.identifier or 'N/A', faction = '',
            evidence = p.eliminated and tostring(p.eliminatedReason or 'went down') or ((p.kills or 0) > 0 and ('%d kill%s'):format(p.kills, p.kills == 1 and '' or 's') or 'Still standing'),
            isAlert = false, isPolice = false,
        }
    end
    local function sideRow(side, label, standing)
        local res = cancelled and 'Cancelled' or (result == side and 'WINNER' or (result == 'DRAW' and 'Draw' or 'Lost'))
        return { name = side, label = label, units = tot[side] or 0, rewardSummary = res,
            cells = { label, ('%d of %d'):format(standing, tot[side] or 0), res, tostring(kills[side] or 0) } }
    end
    local resultText = ({ GANG = gLabel .. ' won', POLICE = 'The police won', DRAW = 'Draw', NO_CONTEST = 'No contest', CANCELLED = 'Cancelled' })[result] or result
    local winnerText = cancelled and 'Cancelled' or (i.winnerLabel or 'Draw')
    local penalty = tonumber(i.penaltyXp) or 0
    local rewardsText = i.rewardsText
    if not rewardsText or rewardsText == '' then rewardsText = 'None' end
    return {
        id = i.id, kind = 'CRACKDOWN', name = i.name, cargoDescription = 'Operation Crackdown',
        startedByName = i.startedByName or 'System / Schedule',
        startedAt = startedAt, endedAt = now, startTimeStr = utc(startedAt), endTimeStr = utc(now),
        durationSeconds = dur, durationText = durationText(dur), outcome = i.outcome or 'COMPLETED', winner = winnerText,
        winningGang = result == 'GANG' and i.gang or nil, branding = brandingBlock('OPERATION CRACKDOWN REPORT'),
        summaryLine = cancelled and ('Cancelled' .. (i.reason and (' — ' .. i.reason) or ''))
            or ('%s %d left — Police %d left · %s'):format(gLabel, sg, sp, resultText),
        fleet = { total = 0, delivered = 0, captured = 0, destroyed = 0, disabled = 0, hijacked = 0, trucks = {} },
        roster = { policeCount = tot.POLICE or 0, gangCount = tot.GANG or 0, gangs = {} },
        interceptions = rows, gangScorecard = { sideRow('GANG', gLabel, sg), sideRow('POLICE', 'Police', sp) },
        crackdownPlayers = i.players or {},
        policeAudit = {}, pvpHijacks = {}, airdropCaptures = {},
        rewards = rewardsText, timeline = i.timeline or {},
        labels = {
            docTitle = 'OPERATION CRACKDOWN REPORT', classLabel = 'OPERATION CRACKDOWN AUDIT', stripe = { 0.84, 0.20, 0.42 },
            outcomeLabel = cancelled and 'CANCELLED' or ((result == 'DRAW') and 'DRAW' or 'CONCLUDED'),
            badge = cancelled and { 0.45, 0.50, 0.58 } or { 0.84, 0.20, 0.42 },
            winnerTitle = 'RESULT', winnerSub = ('%s vs the Police · %s'):format(gLabel, i.zoneText or 'combat zone'),
            forcesTitle = 'STILL STANDING', forces = ('%s %d of %d  |  Police %d of %d'):format(gLabel, sg, tot.GANG or 0, sp, tot.POLICE or 0),
            card4 = penalty > 0 and { title = 'GANG XP PENALTY', main = ('-%d XP'):format(penalty), sub = gLabel }
                or { title = 'REWARDS', main = (rewardsText ~= 'None') and 'Paid' or 'None', sub = resultText },
            sec1Title = 'FIGHTERS (SURVIVORS FIRST)', sec1Cols = { 'RANK', 'SIDE', 'STATUS', 'PLAYER', 'HOW' },
            sec1Empty = '* Nobody fought in this operation.',
            sec2Title = 'SIDE SCORECARD', sec2Cols = { 'SIDE', 'STANDING', 'RESULT', 'KILLS' },
            sec2Empty = '* No fighters were recorded.',
        },
    }
end

-- ── TDM Tournament ───────────────────────────────────────────────────────────
-- i: { id, name, startedAt, endedAt, champion, championLabel, startedByName, gangs = { {gang, label}, ... },
--      matches = { { idx, label, stage, aGang, bGang, aLabel, bLabel, scoreA, scoreB, winner, winnerLabel, walkover, decidedBy,
--      reason }, ... }, rewards, timeline }
-- Same shape as the TDM match report (rows = matches, scorecard = one row per gang).
function ReportBuilder.tournament(i)
    local now = i.endedAt or os.time()
    local startedAt = i.startedAt or now
    local dur = i.durationSeconds or math.max(0, now - startedAt)
    local matches = i.matches or {}

    local stats, order = {}, {}
    local function stat(gang, label)
        if not stats[gang] then
            stats[gang] = { label = label or gang, played = 0, won = 0, lost = 0, drawn = 0, forScore = 0, againstScore = 0 }
            order[#order + 1] = gang
        end
        return stats[gang]
    end
    for _, g in ipairs(i.gangs or {}) do stat(g.gang, g.label) end

    local reasonText = { TIME = 'Time up', KILLS_A = 'Kill limit', KILLS_B = 'Kill limit', FORFEIT_A = 'Forfeit', FORFEIT_B = 'Forfeit', NO_SHOW = 'Walkover (no show)', ADMIN = 'Decided by admin' }
    local rows = {}
    local finalists = {}
    for n, m in ipairs(matches) do
        local a, b = stat(m.aGang, m.aLabel), stat(m.bGang, m.bLabel)
        a.played, b.played = a.played + 1, b.played + 1
        a.forScore, a.againstScore = a.forScore + (m.scoreA or 0), a.againstScore + (m.scoreB or 0)
        b.forScore, b.againstScore = b.forScore + (m.scoreB or 0), b.againstScore + (m.scoreA or 0)
        if m.winner == m.aGang then a.won, b.lost = a.won + 1, b.lost + 1
        elseif m.winner == m.bGang then b.won, a.lost = b.won + 1, a.lost + 1
        else a.drawn, b.drawn = a.drawn + 1, b.drawn + 1 end
        if n == #matches then finalists[m.aGang], finalists[m.bGang] = true, true end
        local how = m.walkover and 'Walkover (no show)' or (m.decidedBy == 'SEED' and 'Level - decided by seed') or reasonText[m.reason or ''] or (m.reason or 'Played')
        rows[#rows + 1] = {
            time = ('#%d'):format(m.idx or n),
            target = m.label or ('Match %d'):format(n),
            method = ('%s %d - %d %s'):format(m.aLabel or m.aGang, m.scoreA or 0, m.scoreB or 0, m.bLabel or m.bGang),
            actorName = m.winnerLabel or 'Draw', actorIdentifier = 'N/A', faction = m.winnerLabel and 'Winner' or '',
            evidence = how, isAlert = false,
        }
    end

    local scorecard = {}
    for _, gang in ipairs(order) do
        local s = stats[gang]
        local result = (gang == i.champion) and 'CHAMPION' or (finalists[gang] and 'Runner-up' or 'Eliminated')
        scorecard[#scorecard + 1] = {
            name = gang, label = s.label, units = s.played, rewardSummary = result,
            cells = { tostring(s.played), ('%d / %d / %d'):format(s.won, s.drawn, s.lost), ('%d - %d'):format(s.forScore, s.againstScore), result },
        }
    end
    table.sort(scorecard, function(x, y)
        local rank = { CHAMPION = 0, ['Runner-up'] = 1, Eliminated = 2 }
        local rx, ry = rank[x.rewardSummary] or 3, rank[y.rewardSummary] or 3
        if rx ~= ry then return rx < ry end
        return (x.units or 0) > (y.units or 0)
    end)

    local champ = i.championLabel or i.champion or '?'
    return {
        id = i.id, kind = 'TDM', name = i.name, cargoDescription = 'Tournament',
        startedByName = i.startedByName or 'System / Schedule',
        startedAt = startedAt, endedAt = now, startTimeStr = utc(startedAt), endTimeStr = utc(now),
        durationSeconds = dur, durationText = durationText(dur), outcome = 'COMPLETED', winner = champ, winningGang = i.champion,
        summaryLine = ('%s won the tournament · %d gangs · %d matches'):format(champ, #order, #matches),
        branding = brandingBlock('TDM TOURNAMENT REPORT'),
        fleet = { total = #matches, delivered = #matches, captured = 0, destroyed = 0, disabled = 0, hijacked = 0, trucks = {} },
        roster = { policeCount = 0, gangCount = #order, gangs = {} },
        interceptions = rows, gangScorecard = scorecard, policeAudit = {}, pvpHijacks = {}, airdropCaptures = {},
        rewards = i.rewards or 'None', timeline = i.timeline or {},
        labels = {
            docTitle = 'TDM TOURNAMENT REPORT', classLabel = 'TOURNAMENT AUDIT', stripe = { 1.0, 0.42, 0.0 },
            outcomeLabel = 'TOURNAMENT COMPLETE', badge = { 0.97, 0.45, 0.0 },
            winnerTitle = 'CHAMPION', winnerSub = ('%d gangs, %d matches'):format(#order, #matches),
            forcesTitle = 'DURATION & GANGS', forces = ('Gangs: %d  |  Matches: %d'):format(#order, #matches),
            card4 = { title = 'TOURNAMENT', main = ('%d matches played'):format(#matches), sub = ('%d gangs entered'):format(#order) },
            sec1Title = 'MATCH RESULTS', sec1Cols = { 'MATCH', 'STAGE', 'SCORE', 'WINNER', 'HOW IT ENDED' },
            sec1Empty = '* No match was played in this tournament.',
            sec2Title = 'GANG STANDINGS', sec2Cols = { 'PLAYED', 'W / D / L', 'SCORE FOR - AGAINST', 'RESULT' },
            sec2Empty = '* No gang took part.',
        },
    }
end

-- ── Rows saved before the builders existed ───────────────────────────────────
local function tsStr(v)
    if type(v) == 'number' then
        if v > 100000000000 then v = math.floor(v / 1000) end
        return utc(v)
    end
    return v and tostring(v) or nil
end

-- row: a nova_convoy_history row. Returns a labelled reportData, or nil when
-- the row is not TDM / Container Wars or already has one.
function ReportBuilder.legacy(row)
    if not row or (row.kind ~= 'TDM' and row.kind ~= 'CONTAINER_WARS') then return nil end
    local rd = row.reportData
    if type(rd) == 'table' and rd.labels then return rd end
    rd = type(rd) == 'table' and rd or {}
    local common = {
        id = row.id, name = row.name, outcome = row.outcome, durationSeconds = row.duration or 0,
        startedByName = row.created_by, startTimeStr = tsStr(row.started_at), endTimeStr = tsStr(row.ended_at),
        endedAt = os.time(), startedAt = os.time() - (row.duration or 0),
        rewards = row.reward_summary, timeline = rd.timeline or {},
    }
    if row.kind == 'TDM' then
        common.gangA, common.gangB = rd.gangA, rd.gangB
        common.gangLabelA, common.gangLabelB = rd.gangLabelA, rd.gangLabelB
        common.scoreA, common.scoreB = rd.scoreA, rd.scoreB
        common.matchFormat, common.reason = rd.matchFormat, rd.reason
        common.players = rd.players or {}
        common.winnerGang = row.winning_gang
        if row.outcome == 'DRAW' then common.winnerGang, common.winnerLabel = false, false end
        return ReportBuilder.tdm(common)
    end
    common.containers = rd.containers or {}
    common.topGang = rd.winningGang or row.winning_gang
    local stats = {}
    for _, c in ipairs(common.containers) do
        local g = c.winningGangName
        if g and (c.status == 'WON' or c.status == 'CLAIMED') then
            stats[g] = stats[g] or { label = c.winningGang or g, won = 0, spend = 0, bids = 0 }
            stats[g].won = stats[g].won + 1
            stats[g].spend = stats[g].spend + (c.finalBid or 0)
        end
    end
    common.gangStats = stats
    common.topGangLabel = common.topGang and stats[common.topGang] and stats[common.topGang].label or common.topGang
    return ReportBuilder.containerWars(common)
end

return ReportBuilder
