-- ─── Nova Convoy — Tournament Engine (pure logic) ─────────────────────────────
-- Draw, group fixtures, standings, qualification, knockout bracket and result
-- progression for the TDM Tournament feature. Deliberately free of any FiveM
-- native, database or player concern so it can be exercised on its own — the
-- runtime that starts real TDM matches and persists state is tournament.lua.
--
-- Shape of a tournament instance table (`inst`) this module reads/writes:
--   cfg      = { gangs, groupCount, advance, legs, scoring, tieBreak }
--   draw     = { groups = { { name = 'A', gangs = { 'alpha', ... } }, ... } }
--   matches  = ordered list, group-stage matches first then knockout rounds
--   qualified= nil until the group stage is over, then a seed-ordered list
--   champion = gang name once the final is decided

TournamentEngine = {}
local E = TournamentEngine

local MAX_GANGS = 32

function E.groupLetter(i)
    local letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    if i <= 26 then return letters:sub(i, i) end
    return tostring(i)
end

-- ── Config ───────────────────────────────────────────────────────────────────

local TIEBREAK_KEYS = { diff = true, kills = true, wins = true }

-- Returns a cleaned config or nil, errorMessage. `raw.gangs` must already be
-- gang names the caller validated exist.
function E.sanitizeConfig(raw)
    raw = raw or {}
    local seen, gangs = {}, {}
    for _, g in ipairs(raw.gangs or {}) do
        g = tostring(g)
        if not seen[g] then seen[g] = true gangs[#gangs + 1] = g end
    end
    if #gangs < 2 then return nil, 'Select at least 2 participating gangs.' end
    if #gangs > MAX_GANGS then return nil, ('A tournament supports at most %d gangs.'):format(MAX_GANGS) end

    local groupCount = math.floor(tonumber(raw.groupCount) or 1)
    if groupCount < 1 then groupCount = 1 end
    if groupCount > math.floor(#gangs / 2) then
        return nil, ('%d gangs cannot fill %d groups — every group needs at least 2 gangs.'):format(#gangs, groupCount)
    end
    local smallest = math.floor(#gangs / groupCount)
    local advance = math.floor(tonumber(raw.advance) or 2)
    if advance < 1 then advance = 1 end
    if advance > smallest then
        return nil, ('Only %d gang(s) fit in the smallest group, so at most %d can advance from each.'):format(smallest, smallest)
    end
    if groupCount * advance < 2 then
        return nil, 'At least 2 teams must qualify for the knockout stage.'
    end

    local scoring = raw.scoring or {}
    local tieBreak, seenTb = {}, {}
    for _, k in ipairs(raw.tieBreak or { 'diff', 'kills', 'wins' }) do
        k = tostring(k)
        if TIEBREAK_KEYS[k] and not seenTb[k] then seenTb[k] = true tieBreak[#tieBreak + 1] = k end
    end
    for k in pairs(TIEBREAK_KEYS) do
        if not seenTb[k] then tieBreak[#tieBreak + 1] = k end
    end

    return {
        gangs = gangs, groupCount = groupCount, advance = advance,
        legs = (tonumber(raw.legs) == 2) and 2 or 1,
        scoring = {
            win = math.floor(tonumber(scoring.win) or 3),
            draw = math.floor(tonumber(scoring.draw) or 1),
            loss = math.floor(tonumber(scoring.loss) or 0),
        },
        tieBreak = tieBreak,
    }
end

-- ── Draw ─────────────────────────────────────────────────────────────────────

function E.shuffle(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    for i = #out, 2, -1 do
        local j = math.random(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

-- Randomises the gangs and deals them across the groups one at a time, so
-- group sizes never differ by more than 1.
function E.buildDraw(gangs, groupCount)
    local groups = {}
    for i = 1, groupCount do groups[i] = { name = E.groupLetter(i), gangs = {} } end
    for i, g in ipairs(E.shuffle(gangs)) do
        local grp = groups[((i - 1) % groupCount) + 1]
        grp.gangs[#grp.gangs + 1] = g
    end
    return { groups = groups }
end

-- ── Fixtures ─────────────────────────────────────────────────────────────────

-- Circle-method round robin: returns rounds, each a list of { a, b } pairs.
-- Odd counts get a phantom "rest" slot whose pairings are dropped.
local function roundRobin(teams)
    local list = {}
    for i, t in ipairs(teams) do list[i] = t end
    if #list % 2 == 1 then list[#list + 1] = false end
    local n = #list
    local rounds = {}
    for r = 1, n - 1 do
        local pairs_ = {}
        for i = 1, n / 2 do
            local a, b = list[i], list[n - i + 1]
            if a and b then pairs_[#pairs_ + 1] = { a, b } end
        end
        rounds[r] = pairs_
        -- rotate everything except the first slot
        local last = table.remove(list)
        table.insert(list, 2, last)
    end
    return rounds
end

local function roundName(size)
    if size == 2 then return 'FINAL', 'F' end
    if size == 4 then return 'SEMI FINAL', 'SF' end
    if size == 8 then return 'QUARTER FINAL', 'QF' end
    return 'ROUND OF ' .. size, 'R' .. size
end

local function seedOrder(size)
    local order = { 1, 2 }
    while #order < size do
        local m = #order * 2 + 1
        local nxt = {}
        for _, s in ipairs(order) do
            nxt[#nxt + 1] = s
            nxt[#nxt + 1] = m - s
        end
        order = nxt
    end
    return order
end

local function seedLabel(seed, groupCount)
    local rank = math.ceil(seed / groupCount)
    local gi = ((seed - 1) % groupCount) + 1
    return ('GROUP %s #%d'):format(E.groupLetter(gi), rank)
end

-- Fills inst.matches with every group fixture and the whole (still-unresolved)
-- knockout skeleton. Safe to call only before any match has been played.
function E.buildFixtures(inst)
    local cfg = inst.cfg
    local matches = {}

    -- Group stage: matchday-major, then group, so A and B alternate.
    local perGroupRounds, maxRounds = {}, 0
    for gi, grp in ipairs(inst.draw.groups) do
        local rounds = roundRobin(grp.gangs)
        perGroupRounds[gi] = rounds
        if #rounds > maxRounds then maxRounds = #rounds end
    end
    local order = 0
    for leg = 1, cfg.legs do
        for r = 1, maxRounds do
            for gi, grp in ipairs(inst.draw.groups) do
                local rounds = perGroupRounds[gi]
                for pi, pr in ipairs(rounds[r] or {}) do
                    order = order + 1
                    local a, b = pr[1], pr[2]
                    if leg == 2 then a, b = b, a end
                    local matchday = (leg - 1) * maxRounds + r
                    matches[#matches + 1] = {
                        id = ('G%s-%d-%d'):format(grp.name, matchday, pi),
                        stage = 'GROUP', group = gi, groupName = grp.name, round = matchday,
                        label = ('GROUP %s · MATCHDAY %d'):format(grp.name, matchday),
                        order = order, status = 'READY',
                        a = { gang = a }, b = { gang = b },
                    }
                end
            end
        end
    end

    -- Knockout skeleton.
    local numQ = cfg.groupCount * cfg.advance
    local size = 2
    while size < numQ do size = size * 2 end
    local seeds = seedOrder(size)
    local roundsTotal = 0
    do local s = size while s > 1 do s = s // 2 roundsTotal = roundsTotal + 1 end end

    local prevIds = {}
    for rnd = 1, roundsTotal do
        local teamsInRound = size >> (rnd - 1)
        local name, short = roundName(teamsInRound)
        local count = teamsInRound // 2
        local ids = {}
        for i = 1, count do
            order = order + 1
            local m = {
                id = ('K%d-%d'):format(rnd, i), stage = 'KO', round = rnd, index = i,
                roundName = name, shortName = short, order = order, status = 'PENDING',
                label = (count > 1) and ('%s %02d'):format(name, i) or name,
                a = {}, b = {},
            }
            if rnd == 1 then
                local sa, sb = seeds[2 * i - 1], seeds[2 * i]
                m.a.src = { t = 'seed', seed = sa, label = seedLabel(sa, cfg.groupCount) }
                m.b.src = { t = 'seed', seed = sb, label = seedLabel(sb, cfg.groupCount) }
            else
                local pa, pb = prevIds[2 * i - 1], prevIds[2 * i]
                m.a.src = { t = 'winner', match = pa.id, label = 'WINNER ' .. pa.short .. (pa.count > 1 and pa.index or '') }
                m.b.src = { t = 'winner', match = pb.id, label = 'WINNER ' .. pb.short .. (pb.count > 1 and pb.index or '') }
            end
            matches[#matches + 1] = m
            ids[i] = { id = m.id, short = short, index = i, count = count }
        end
        prevIds = ids
    end

    inst.matches = matches
    inst.koSize = size
    inst.qualified = nil
    inst.champion = nil
end

-- ── Lookups ──────────────────────────────────────────────────────────────────

function E.matchById(inst, id)
    for _, m in ipairs(inst.matches or {}) do
        if m.id == id then return m end
    end
    return nil
end

function E.groupStageComplete(inst)
    local any = false
    for _, m in ipairs(inst.matches or {}) do
        if m.stage == 'GROUP' then
            any = true
            if m.status ~= 'COMPLETE' then return false end
        end
    end
    return any
end

-- ── Standings ────────────────────────────────────────────────────────────────

-- Returns standings[groupIndex] = ordered rows, computed from completed
-- group matches only — never stored, so it can never drift from the results.
function E.standings(inst)
    local cfg = inst.cfg
    local out = {}
    for gi, grp in ipairs(inst.draw.groups) do
        local rows, byGang = {}, {}
        for i, g in ipairs(grp.gangs) do
            local row = { gang = g, drawIndex = i, played = 0, won = 0, drawn = 0, lost = 0,
                          points = 0, kf = 0, ka = 0, diff = 0 }
            rows[#rows + 1] = row
            byGang[g] = row
        end
        for _, m in ipairs(inst.matches or {}) do
            if m.stage == 'GROUP' and m.group == gi and m.status == 'COMPLETE' then
                local ra, rb = byGang[m.a.gang], byGang[m.b.gang]
                if ra and rb then
                    ra.played, rb.played = ra.played + 1, rb.played + 1
                    local sa, sb = m.scoreA or 0, m.scoreB or 0
                    ra.kf, ra.ka = ra.kf + sa, ra.ka + sb
                    rb.kf, rb.ka = rb.kf + sb, rb.ka + sa
                    if m.doubleForfeit then
                        ra.lost, rb.lost = ra.lost + 1, rb.lost + 1
                        ra.points, rb.points = ra.points + cfg.scoring.loss, rb.points + cfg.scoring.loss
                    elseif m.winner == m.a.gang then
                        ra.won, rb.lost = ra.won + 1, rb.lost + 1
                        ra.points, rb.points = ra.points + cfg.scoring.win, rb.points + cfg.scoring.loss
                    elseif m.winner == m.b.gang then
                        rb.won, ra.lost = rb.won + 1, ra.lost + 1
                        rb.points, ra.points = rb.points + cfg.scoring.win, ra.points + cfg.scoring.loss
                    else
                        ra.drawn, rb.drawn = ra.drawn + 1, rb.drawn + 1
                        ra.points, rb.points = ra.points + cfg.scoring.draw, rb.points + cfg.scoring.draw
                    end
                end
            end
        end
        for _, r in ipairs(rows) do r.diff = r.kf - r.ka end

        local function metric(row, key)
            if key == 'diff' then return row.diff end
            if key == 'kills' then return row.kf end
            return row.won
        end
        table.sort(rows, function(x, y)
            if x.points ~= y.points then return x.points > y.points end
            for _, key in ipairs(cfg.tieBreak) do
                local mx, my = metric(x, key), metric(y, key)
                if mx ~= my then return mx > my end
            end
            return x.drawIndex < y.drawIndex
        end)
        for rank, r in ipairs(rows) do r.rank = rank end
        out[gi] = rows
    end
    return out
end

-- ── Result application & progression ─────────────────────────────────────────

local function sideGang(side) return side and side.gang end

-- Records a finished match. opts.noShow = 'A' | 'B' | 'BOTH' marks a
-- walkover (that side failed to field anyone).
function E.applyResult(inst, m, scoreA, scoreB, opts)
    opts = opts or {}
    m.scoreA, m.scoreB = scoreA or 0, scoreB or 0
    m.walkover = opts.noShow
    m.doubleForfeit = nil
    m.winner, m.decidedBy = nil, nil

    local aGang, bGang = sideGang(m.a), sideGang(m.b)
    local function bySeed()
        local sa, sb = m.a.seed or 999, m.b.seed or 999
        if sa <= sb then return aGang, m.a.seed else return bGang, m.b.seed end
    end

    if opts.forcedWinner == 'A' then
        m.winner, m.decidedBy = aGang, 'FORFEIT'   -- an opponent forfeited mid-match: the real score stays, the winner is the side that stayed
    elseif opts.forcedWinner == 'B' then
        m.winner, m.decidedBy = bGang, 'FORFEIT'
    elseif opts.noShow == 'A' then
        m.winner = bGang
    elseif opts.noShow == 'B' then
        m.winner = aGang
    elseif opts.noShow == 'BOTH' then
        if m.stage == 'GROUP' then m.doubleForfeit = true
        else m.winner = bySeed() m.decidedBy = 'SEED' end
    elseif m.scoreA > m.scoreB then
        m.winner = aGang
    elseif m.scoreB > m.scoreA then
        m.winner = bGang
    elseif m.stage == 'KO' then
        -- A knockout needs a winner: a level score goes to the better seed.
        m.winner = bySeed()
        m.decidedBy = 'SEED'
    end
    -- (a level GROUP match keeps winner = nil, i.e. a draw)

    if m.winner then
        m.winnerSeed = (m.winner == aGang) and m.a.seed or m.b.seed
    end
    m.status = 'COMPLETE'
    E.resolve(inst)
end

-- Idempotent: brings qualification, bracket slots, byes and the champion in
-- line with whatever results currently exist.
function E.resolve(inst)
    local cfg = inst.cfg

    if not inst.qualified and E.groupStageComplete(inst) then
        local standings = E.standings(inst)
        local q = {}
        for rank = 1, cfg.advance do
            for gi = 1, cfg.groupCount do
                local row = standings[gi] and standings[gi][rank]
                if row then
                    q[#q + 1] = {
                        seed = (rank - 1) * cfg.groupCount + gi, gang = row.gang,
                        group = gi, groupName = E.groupLetter(gi), rank = rank,
                    }
                end
            end
        end
        inst.qualified = q
    end

    local bySeed = {}
    for _, e in ipairs(inst.qualified or {}) do bySeed[e.seed] = e end
    local numQ = cfg.groupCount * cfg.advance

    local changed = true
    while changed do
        changed = false
        for _, m in ipairs(inst.matches or {}) do
            if m.stage == 'KO' then
                for _, side in ipairs({ m.a, m.b }) do
                    if not side.gang and not side.bye and side.src then
                        if side.src.t == 'seed' then
                            local e = bySeed[side.src.seed]
                            if e then
                                side.gang, side.seed, changed = e.gang, e.seed, true
                            elseif side.src.seed > numQ then
                                side.bye, changed = true, true
                            end
                        else
                            local src = E.matchById(inst, side.src.match)
                            if src and src.status == 'COMPLETE' and src.winner then
                                side.gang, side.seed, changed = src.winner, src.winnerSeed, true
                            end
                        end
                    end
                end
                if m.status ~= 'COMPLETE' then
                    if (m.a.bye and m.b.gang) or (m.b.bye and m.a.gang) then
                        m.winner = m.a.gang or m.b.gang
                        m.winnerSeed = m.a.gang and m.a.seed or m.b.seed
                        m.walkover, m.decidedBy = 'BYE', 'BYE'
                        m.scoreA, m.scoreB = 0, 0
                        m.status, changed = 'COMPLETE', true
                    elseif m.status == 'PENDING' and m.a.gang and m.b.gang then
                        m.status, changed = 'READY', true
                    end
                end
            end
        end
    end

    -- Champion = winner of the very last match.
    local last = inst.matches and inst.matches[#inst.matches]
    if last and last.stage == 'KO' and last.status == 'COMPLETE' and last.winner then
        inst.champion = last.winner
    end
end

-- Next match that is ready to be played (nil while one is live or nothing is
-- ready yet).
function E.nextMatch(inst)
    local best
    for _, m in ipairs(inst.matches or {}) do
        if m.status == 'LIVE' then return nil end
        if m.status == 'READY' and (not best or m.order < best.order) then best = m end
    end
    return best
end

function E.liveMatch(inst)
    for _, m in ipairs(inst.matches or {}) do
        if m.status == 'LIVE' then return m end
    end
    return nil
end

function E.hasActivity(inst)
    for _, m in ipairs(inst.matches or {}) do
        if m.status == 'LIVE' or m.status == 'COMPLETE' then return true end
    end
    return false
end

-- Ordered list of stage names for the stage indicator, then which one is
-- current. Dynamic: a 16-gang cup shows QUARTER FINAL, an 8-gang one doesn't.
function E.stageInfo(inst)
    local stages = { { key = 'GROUP', label = 'GROUP STAGE' } }
    local seen = {}
    for _, m in ipairs(inst.matches or {}) do
        if m.stage == 'KO' and not seen[m.round] then
            seen[m.round] = true
            stages[#stages + 1] = { key = 'KO' .. m.round, label = m.roundName, round = m.round }
        end
    end
    stages[#stages + 1] = { key = 'CHAMPION', label = 'CHAMPION' }

    local current = 'GROUP'
    if inst.champion then
        current = 'CHAMPION'
    elseif inst.qualified then
        local minRound
        for _, m in ipairs(inst.matches or {}) do
            if m.stage == 'KO' and m.status ~= 'COMPLETE' and (not minRound or m.round < minRound) then
                minRound = m.round
            end
        end
        current = minRound and ('KO' .. minRound) or 'CHAMPION'
    end
    return stages, current
end

return E
