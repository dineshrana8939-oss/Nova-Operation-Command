-- ─── Nova Convoy — Gang XP ledger ──────────────────────────────────────────────
-- Server-only. Persistent XP for every gang (nova_gang_xp) plus the ledger of every change (nova_gang_xp_transactions).
--
--   • XP is EARNED through the existing events: a "Gang XP" entry in an event's reward list is paid by RewardService.
--     Nothing in here knows about convoys / TDM / races — it only receives "pay N XP to these players".
--   • XP is SPENT on territory expansions (GangXP.Spend) and LOST to war no-show penalties (GangXP.Penalty).
--   • The gang is always resolved HERE from the player's server id — never from anything a client / NUI sent.
--   • Civilians (no gang) always earn 0 Gang XP; so does on-duty police unless Config.Territory.gangXp.policeEarnXp.
--   • Every award carries a dedupe key, enforced by a UNIQUE index in SQL: the same result submitted twice (retry,
--     reconnect, restart, hostile request) can only pay once.

GangXP = {}

local function cfg() return (Config.Territory and Config.Territory.gangXp) or {} end

local NO_GANG = { [''] = true, none = true, civilian = true, independent = true }

function GangXP.isRealGang(name)
    return type(name) == 'string' and not NO_GANG[name:lower()]
end

-- ── Who is this player's gang? (the ONLY membership check) ───────────────────────
-- Returns { name, label, id } or nil. nil for civilians, for anyone not in a gang, and for on-duty police.
-- Membership comes from the gang provider (a database query for the internal provider), so a short per-player cache keeps
-- UI-only callers (who gets a live map update, who sees a banner) cheap. `fresh` skips the cache: every decision that moves
-- XP, ownership or money (awards, expansions, bids, challenges, capture) passes fresh = true.
local gangCache = {}   -- [source] = { identifier, gang (table | false), at }
local GANG_CACHE_TTL = 5

function GangXP.GangOf(source, allowPolice, fresh)
    if not source or not GetPlayerName(source) then return nil end
    if not allowPolice and not cfg().policeEarnXp and Bridge.IsPolice(source) then return nil end
    local identifier = Bridge.GetIdentifier(source)
    local c = gangCache[source]
    local g
    if c and not fresh and c.identifier == identifier and os.time() - c.at <= GANG_CACHE_TTL then
        g = c.gang or nil
    else
        g = GangService and GangService.GetPlayerGang(source) or nil
        gangCache[source] = { identifier = identifier, gang = g or false, at = os.time() }
    end
    if not g or not GangXP.isRealGang(g.name) then return nil end
    return { name = g.name, label = g.label or g.name, id = tonumber(g.id) }
end

AddEventHandler('playerDropped', function() gangCache[source] = nil end)

-- ── Totals (cached; every write in here refreshes the cache) ─────────────────────
local cache = {}   -- gangName -> { total, lifetime, at }
local CACHE_TTL = 10

local function remember(gangName, total, lifetime)
    DB.bustGangXp()
    cache[gangName] = { total = tonumber(total) or 0, lifetime = tonumber(lifetime) or (cache[gangName] and cache[gangName].lifetime) or 0, at = os.time() }
end

function GangXP.Total(gangName)
    if not GangXP.isRealGang(gangName) then return 0 end
    local c = cache[gangName]
    if c and os.time() - c.at <= CACHE_TTL then return c.total end
    local row = DB.gangXpGet(gangName)
    remember(gangName, row and row.total_xp or 0, row and row.lifetime_xp or 0)
    return cache[gangName].total
end

function GangXP.Lifetime(gangName)
    GangXP.Total(gangName)
    return cache[gangName] and cache[gangName].lifetime or 0
end

-- Pushes the new balance to every online member of the gang so an open map / tablet shows it at once.
function GangXP.Push(gangName)
    local payload = { gang = gangName, total = GangXP.Total(gangName), lifetime = GangXP.Lifetime(gangName) }
    for _, src in ipairs(Bridge.GetPlayers()) do
        local g = GangXP.GangOf(src, true)
        if g and g.name == gangName then
            TriggerClientEvent('nova_convoytruck:territory:client:xp', src, payload)
        end
    end
    GangXP.ScheduleBoard()
end

-- Every admin and every gang member watching the Map Zone sees the whole XP table move, not just their own gang's balance.
-- Debounced: a TDM / convoy payout credits many recipients in the same instant and must cost one broadcast, not dozens.
local boardPending = false
function GangXP.BroadcastBoard()
    boardPending = false
    local rows = GangXP.Leaderboard()
    for _, src in ipairs(Territory.audience()) do
        TriggerClientEvent('nova_convoytruck:territory:client:xpBoard', src, rows)
    end
end

function GangXP.ScheduleBoard()
    if boardPending then return end
    boardPending = true
    SetTimeout(750, GangXP.BroadcastBoard)
end

local function labelFor(sourceType)
    local labels = cfg().sourceLabels or {}
    return labels[sourceType] or tostring(sourceType)
end

local function clampAmount(amount)
    amount = math.floor(tonumber(amount) or 0)
    local cap = tonumber(cfg().maxPerAward) or 1000000
    if amount > cap then amount = cap end
    return amount
end

-- opts: { identifier, playerName, sourceType, sourceId, sourceName, reason, metadata, dedupeKey, txType, gangId, quiet }
-- Returns true, { amount, total } | false, 'DUPLICATE' | 'INVALID' | 'ERROR'
function GangXP.Award(gangName, amount, opts)
    opts = opts or {}
    amount = clampAmount(amount)
    if amount <= 0 or not GangXP.isRealGang(gangName) then return false, 'INVALID' end
    local ok, total = DB.gangXpAward({
        gangName = gangName, gangId = opts.gangId, identifier = opts.identifier, playerName = opts.playerName,
        sourceType = opts.sourceType, sourceId = opts.sourceId, sourceName = opts.sourceName or labelFor(opts.sourceType),
        amount = amount, txType = opts.txType or 'AWARD', reason = opts.reason, metadata = opts.metadata, dedupeKey = opts.dedupeKey,
    })
    if not ok then return false, total end
    -- a REFUND returns spent XP to the balance; it is not newly earned, so lifetime XP does not grow
    remember(gangName, total, GangXP.Lifetime(gangName) + (opts.txType == 'REFUND' and 0 or amount))
    if not opts.quiet then GangXP.Push(gangName) end
    print(('[NovaConvoy][GangXP] +%d XP → %s (%s) — %s'):format(amount, gangName, tostring(opts.playerName or '-'), tostring(opts.sourceName or opts.sourceType)))
    return true, { amount = amount, total = total }
end

-- Spends XP (an expansion). Fails with 'INSUFFICIENT' when the gang does not have it.
function GangXP.Spend(gangName, amount, opts)
    opts = opts or {}
    amount = clampAmount(amount)
    if amount <= 0 or not GangXP.isRealGang(gangName) then return false, 'INVALID' end
    local ok, total = DB.gangXpSpend({
        gangName = gangName, gangId = opts.gangId, identifier = opts.identifier, playerName = opts.playerName,
        sourceType = opts.sourceType or 'TERRITORY', sourceId = opts.sourceId, sourceName = opts.sourceName or 'Territory Expansion',
        amount = amount, txType = opts.txType or 'SPEND', reason = opts.reason, metadata = opts.metadata, dedupeKey = opts.dedupeKey,
    }, tonumber((Config.Territory.expansion or {}).minRemainingXp) or 0)
    if not ok then return false, total end
    remember(gangName, total)
    GangXP.Push(gangName)
    print(('[NovaConvoy][GangXP] -%d XP ← %s (%s) — %s'):format(amount, gangName, tostring(opts.playerName or '-'), tostring(opts.reason or opts.sourceName)))
    return true, { amount = amount, total = total }
end

-- War no-show penalty: takes up to `amount` (never below zero). Returns true, { amount = actuallyTaken, total }.
function GangXP.Penalty(gangName, amount, opts)
    opts = opts or {}
    amount = clampAmount(amount)
    if amount <= 0 or not GangXP.isRealGang(gangName) then return true, { amount = 0, total = GangXP.Total(gangName) } end
    local ok, taken, total = DB.gangXpPenalty({
        gangName = gangName, gangId = opts.gangId, identifier = opts.identifier, playerName = opts.playerName,
        sourceType = opts.sourceType or 'TERRITORY', sourceId = opts.sourceId, sourceName = opts.sourceName or 'Territory War Penalty',
        reason = opts.reason, metadata = opts.metadata, dedupeKey = opts.dedupeKey, amount = amount, txType = 'PENALTY',
    })
    if not ok then return false, taken end
    remember(gangName, total)
    GangXP.Push(gangName)
    print(('[NovaConvoy][GangXP] -%d XP (penalty) ← %s — %s'):format(taken, gangName, tostring(opts.reason)))
    return true, { amount = taken, total = total }
end

-- Does this player lead a gang? (the leader check every gang permission already uses — works for every gang provider)
function GangXP.IsGangLeader(source)
    if not source or not GangService or not GangService.GetPermissionContext then return false end
    local ok, ctx = pcall(GangService.GetPermissionContext, source, false)
    return ok and ctx and ctx.isLeader == true or false
end

GangXP.LEADER_BLOCK_MESSAGE = 'You lead a gang, so you cannot add or remove Gang XP for any gang — that would be a conflict of interest. Ask another administrator.'

-- Admin correction (positive = ADD, negative = REDUCE). Always recorded as an ADMIN row with the admin's name.
-- An administrator who is also a gang leader may do neither: the check is here (server-side), not in the tablet.
function GangXP.AdminAdjust(adminSource, gangName, delta, reason)
    delta = math.floor(tonumber(delta) or 0)
    if adminSource and GangXP.IsGangLeader(adminSource) then return false, GangXP.LEADER_BLOCK_MESSAGE end
    if delta == 0 or not GangXP.isRealGang(gangName) then return false, 'Enter a gang and a non-zero amount.' end
    local who = adminSource and Bridge.GetPlayerName(adminSource) or 'Console'
    local ident = adminSource and Bridge.GetIdentifier(adminSource) or nil
    -- The ledger row keeps the reason exactly as the admin typed it (it is also what the gang is shown in the announcement);
    -- the admin's in-game character name is the row's player. `who` is the character name, never the account name.
    local text = (reason and reason ~= '') and tostring(reason):sub(1, 160) or 'No reason given'
    local meta = { admin = who, announced = true }
    if delta > 0 then
        local ok, res = GangXP.Award(gangName, delta, { sourceType = 'ADMIN', sourceName = 'Admin adjustment (added)', reason = text, txType = 'ADMIN', identifier = ident, playerName = who, metadata = meta })
        return ok, ok and res or tostring(res)
    end
    local ok, taken = GangXP.Penalty(gangName, -delta, { sourceType = 'ADMIN', sourceName = 'Admin adjustment (removed)', reason = text, identifier = ident, playerName = who, metadata = meta })
    return ok, ok and taken or tostring(taken)
end

-- ── Reward integration ───────────────────────────────────────────────────────────
-- Called by RewardService for every { type = 'GANG_XP', amount } entry in a reward list.
--   recipients : server ids the reward is paid to
--   ctx        : { kind (event kind), eventId, eventName, runId, phase, reason }
-- Returns a map [serverId] = xpPaid for the players who actually earned some (civilians / duplicates are absent).
function GangXP.PayReward(recipients, amount, ctx)
    ctx = ctx or {}
    amount = clampAmount(amount)
    local paid = {}
    if amount <= 0 or type(recipients) ~= 'table' then return paid end

    local eligible, perGang = {}, {}
    for _, src in ipairs(recipients) do
        local g = GangXP.GangOf(src, false, true)   -- server-side, uncached membership: a civilian / no gang is simply skipped
        if g then
            eligible[#eligible + 1] = { src = src, gang = g }
            perGang[g.name] = (perGang[g.name] or 0) + 1
        end
    end

    local sourceType = tostring(ctx.kind or 'OTHER')
    for _, e in ipairs(eligible) do
        local each = amount
        if cfg().splitAmongRecipients then each = math.max(1, math.floor(amount / perGang[e.gang.name])) end
        local identifier = Bridge.GetIdentifier(e.src)
        if identifier then
            local dedupe = table.concat({ sourceType, tostring(ctx.eventId or '-'), tostring(ctx.runId or '-'), tostring(ctx.phase or 'default'), identifier }, ':')
            local ok, res = GangXP.Award(e.gang.name, each, {
                gangId = e.gang.id, identifier = identifier, playerName = Bridge.GetCharacterName(e.src),
                sourceType = sourceType, sourceId = ctx.eventId, sourceName = labelFor(sourceType),
                reason = ctx.reason or ctx.eventName, dedupeKey = dedupe,
                metadata = { event = ctx.eventName, run = ctx.runId, phase = ctx.phase },
                quiet = true,
            })
            if ok then paid[e.src] = res.amount end
        end
    end
    -- one live balance push per gang that actually got paid (the awards above were quiet)
    local pushed = {}
    for _, e in ipairs(eligible) do
        if paid[e.src] and not pushed[e.gang.name] then
            pushed[e.gang.name] = true
            GangXP.Push(e.gang.name)
        end
    end
    return paid
end

-- ── Reads for the tablets ────────────────────────────────────────────────────────
function GangXP.History(filters, limit)
    return DB.gangXpHistory(filters, limit or cfg().historyLimit or 300)
end

-- Gang ranking: total XP, lifetime XP, controlled territories, territory level (sum of unlocked expansion levels).
function GangXP.Leaderboard()
    local xp = {}
    for _, r in ipairs(DB.gangXpAll()) do xp[r.gang_name] = r end
    local owned = (Territory and Territory.ownerSummary and Territory.ownerSummary()) or {}
    local rows = {}
    for _, g in ipairs(GangService.GetGangs() or {}) do
        local x = xp[g.name]
        local o = owned[g.name] or {}
        rows[#rows + 1] = {
            gang = g.name, label = g.label or g.name, logo = g.logo, color = g.accentColor,
            totalXp = x and tonumber(x.total_xp) or 0, lifetimeXp = x and tonumber(x.lifetime_xp) or 0,
            territories = o.count or 0, territoryLevel = o.level or 0,
            cells = o.cells or 0, areaKm2 = o.areaKm2 or 0,
        }
    end
    table.sort(rows, function(a, b)
        if a.totalXp ~= b.totalXp then return a.totalXp > b.totalXp end
        if a.territories ~= b.territories then return a.territories > b.territories end
        return a.label < b.label
    end)
    for i, r in ipairs(rows) do r.rank = i end
    return rows
end

function GangXP.PlayerBoard(limit)
    local labels = {}
    for _, g in ipairs(GangService.GetGangs() or {}) do labels[g.name] = g.label or g.name end
    local rows = DB.gangXpPlayerBoard(limit or 100)
    for i, r in ipairs(rows) do
        r.rank = i
        r.xp = tonumber(r.xp) or 0
        r.gangLabel = labels[r.gang_name] or r.gang_name
    end
    return rows
end

return GangXP
