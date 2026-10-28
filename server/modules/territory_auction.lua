-- ─── Nova Convoy — Gang Territory Auction (event runtime) ──────────────────────
-- Server-only. The runtime of the GANG_TERRITORY event kind. It auctions the event's territories one after another to the
-- participating gangs; every winner becomes the territory's owner (Territory.transfer), and the ownership outlives the
-- event. Bidding is NOT a second engine: every bid goes through AuctionCore (the same versioned, race-safe,
-- anti-snipe bidding Container Wars uses), a territory lot just has the same fields a container has.
--
--   physical:  eligible gang members stand in the auction zone (Auction Setup → location) and open the bidder window
--   timeline:  intro countdown → for each territory: bidding (anti-snipe extends it) → result + payment → gap → next
--   limits:    the event's Auction Duration stops NEW territories from opening once it has run out
--   result:    highest valid gang bid wins; the winning bidder pays (bank, then cash); a failed payment leaves the
--              territory unsold; every result is a row in nova_territory_auctions with its bid history

TerritoryAuction = {}

local active = {}   -- [eventId] = rt

local function tcfg() return Config.Territory or {} end
local function acfg() return tcfg().auction or {} end

local function log(id, msg)
    print(('[NovaConvoy][TerritoryAuction #%s] %s'):format(tostring(id), tostring(msg)))
end

local function money(n)
    local s = tostring(math.floor((tonumber(n) or 0) + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return '$' .. out
end

-- A territory banner (its own red theme: kind 'territory' — web/src/lib/hud/eventThemes.js). Respects the event's
-- "Server announcements" switch and the per-banner switches in Auction Setup.
local function announce(rt, key, title, body, duration, status)
    local def = rt.def
    if def.settings and def.settings.announcements == false then return end
    local flags = (def.territory and def.territory.auction and def.territory.auction.announce) or {}
    if key and flags[key] == false then return end
    local img = def.territory and def.territory.auction and def.territory.auction.bannerUrl
    if img == '' then img = nil end
    for _, src in ipairs(Bridge.GetPlayers()) do
        TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body, duration, 'territory', nil, status, nil, img)
    end
end

local function push(event, payload)
    for _, src in ipairs(Territory.audience()) do TriggerClientEvent(event, src, payload) end
end

-- ── eligibility ──────────────────────────────────────────────────────────────────

local function eligibleGang(def, gangName)
    if not GangXP.isRealGang(gangName) then return false end
    local ag = def.settings and def.settings.allowedGangs
    if not ag or ag.mode ~= 'SELECTED' then return true end
    for _, name in ipairs(ag.gangs or {}) do
        if name == gangName then return true end
    end
    return false
end

local function auctionSpot(def)
    return def.territory and def.territory.auction and def.territory.auction.location
end

local function pointInPolygon(px, py, poly)
    if not poly or #poly < 3 then return false end
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local pi, pj = poly[i], poly[j]
        if ((pi.y > py) ~= (pj.y > py)) and (px < (pj.x - pi.x) * (py - pi.y) / (pj.y - pi.y) + pi.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Is this player physically at the auction house? (server-side position — never the client's word)
local function atAuction(rt, src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)

    local auc = rt.def and rt.def.territory and rt.def.territory.auction
    local pts = auc and ((auc.zone and auc.zone.points) or auc.zonePoints)
    if pts and #pts >= 3 then
        if pointInPolygon(c.x, c.y, pts) then
            local z0 = pts[1].z or c.z
            if math.abs(c.z - z0) <= 25.0 then return true end
        end
    end

    local loc = auctionSpot(rt.def)
    if not loc then return false end
    local radius = (tonumber(auc and auc.zoneRadius) or tonumber(acfg().zoneRadius) or 12.0) + 8.0
    local dx, dy = c.x - loc.x, c.y - loc.y
    if (dx * dx + dy * dy) > radius * radius then return false end
    if loc.z and loc.z ~= 0 and math.abs(c.z - loc.z) > 20.0 then return false end
    return true
end

-- Who may bid right now? Returns gang, or nil + code + message.
local function bidderGang(rt, src)
    if Bridge.IsPolice(src) then return nil, 'POLICE', 'Police officers cannot participate in the auction.' end
    local gang = GangXP.GangOf(src, false, true)
    if not gang then return nil, 'NO_GANG', 'You must be in a gang to bid.' end
    if not eligibleGang(rt.def, gang.name) then return nil, 'NOT_ELIGIBLE', 'Your gang is not taking part in this auction.' end
    if not ConvoyManager.isGangRegistered(rt.def, gang.name) then return nil, 'NOT_REGISTERED', 'Your gang did not register for this auction (Event Status, Events tab).' end
    if not atAuction(rt, src) then return nil, 'ZONE', 'You must be at the auction house to bid.' end
    return gang
end

local function resolveBidderSource(c)
    local src = c.highestBidderSource
    if src then
        local ok, id = pcall(Bridge.GetIdentifier, src)
        if ok and id and id == c.highestBidder then return src end
    end
    for _, p in ipairs(Bridge.GetPlayers()) do
        local ok, id = pcall(Bridge.GetIdentifier, p)
        if ok and id and id == c.highestBidder then return p end
    end
    return nil
end

-- ── public state (what the tablets / HUD / world interaction see) ────────────────

local function lotView(c)
    if not c then return nil end
    return {
        territoryId = c.territoryId, name = c.name, lotIndex = c.lotIndex, startingBid = c.startingBid,
        x = c.x, y = c.y,
        increment = c.minBidIncrement, status = c.status, currentBid = c.currentBid or c.startingBid,
        minimumBid = AuctionCore.minimumNext(c), version = c.version, timeRemaining = c.timeRemaining or 0,
        leadingGang = c.highestBidderGangName, leadingGangLabel = c.highestBidderGang, leadingPlayer = c.highestBidderName,
        bidCount = c.bidCount or 0, owner = c.owner, ownerLabel = c.owner and Territory.gangLabel(c.owner) or nil,
        finalBid = (c.status == 'WON') and c.currentBid or nil,
        -- what the big screen lists for EVERY zone (not just the live one): worth, colour, how far it can be expanded
        xpValue = c.xpValue, color = c.color, description = c.description,
        preview = c.preview,   -- the territory's painted base + its location, for the panel's mini map
    }
end

function TerritoryAuction.publicState(rt)
    local lots = {}
    for _, c in ipairs(rt.lots) do lots[#lots + 1] = lotView(c) end
    local a = rt.def.territory.auction
    return {
        eventId = rt.id, name = rt.def.name, phase = rt.phase, totalLots = #rt.lots,
        lot = lotView(rt.activeLot), lots = lots,
        endsIn = math.max(0, rt.deadline - os.time()),
        location = a.location, zoneRadius = a.zoneRadius,
        -- seconds until bidding opens (only while the opening buffer runs): the clients show it as the 'auction starts in' timer
        introLeft = (rt.phase == 'INTRO' and rt.introEndsAt) and math.max(0, rt.introEndsAt - os.time()) or 0,
        -- the bidding perimeter the admin drew (Auction Setup): standing inside it is what lets a gang member bid
        zone = (function()
            local pts = (a.zone and a.zone.points) or a.zonePoints
            if type(pts) ~= 'table' or #pts < 3 then return nil end
            local out = {}
            for _, p in ipairs(pts) do out[#out + 1] = { x = p.x, y = p.y, z = p.z } end
            return out
        end)(),
        inviteOnly = (rt.def.settings and rt.def.settings.allowedGangs and rt.def.settings.allowedGangs.mode == 'SELECTED') or false,
        viewDistance = tonumber(acfg().viewDistance) or 80.0,
        -- the projector exists (and the floating auction panel shows) only while bidding is really on: not during the intro
        projectorLive = rt.projectorLive == true,
        projector = (rt.projectorLive and a.projector) and { x = a.projector.x, y = a.projector.y, z = a.projector.z } or nil,
        projectorScale = tonumber(a.projector and a.projector.screenScale) or 1.0,
    }
end

-- ── the projector (physical anchor of the floating auction panel — never interactive) ──
-- Spawned when the auction really starts (after the intro / buffer), kept for EVERY territory of the event (bids, anti-snipe
-- extensions, the gaps between lots), removed when the whole event ends. Its saved placement is configuration and is never touched.
local function spawnProjector(rt)
    local p = rt.def.territory and rt.def.territory.auction and rt.def.territory.auction.projector
    if not p or not p.x or not EventProps then return end
    -- the model of the config, then its fallbacks: a game build that does not have it simply moves on to the next one
    local models = { (acfg().projectorModelFromPlacement == true and p.model and p.model ~= 'prop_runlight_g') and p.model or acfg().projectorModel or 'prop_worklight_03b' }
    for _, m in ipairs(acfg().projectorModelFallbacks or {}) do models[#models + 1] = m end
    models[#models + 1] = 'prop_worklight_03b'
    local made = {}
    for _, model in ipairs(models) do
        made = EventProps.spawnEntry({
            model = model, kind = 'object',
            x = p.x, y = p.y, z = p.z, heading = p.heading, rx = p.rx, ry = p.ry, collision = p.collision,
        })
        if #made > 0 then
            if model ~= models[1] then log(rt.id, ('Projector model %s is not available in this game build: using %s'):format(tostring(models[1]), model)) end
            break
        end
    end
    rt.projectorEntities = made
    for _, e in ipairs(made) do
        if DoesEntityExist(e) then
            Entity(e).state:set('nova_territory_projector', { eventId = rt.id, propId = p.uid, territoryId = p.territoryId }, true)
        end
    end
    rt.projectorLive = true
    log(rt.id, ('Projector spawned (%d entity)'):format(#made))
end

local function removeProjector(rt)
    for _, e in ipairs(rt.projectorEntities or {}) do
        if DoesEntityExist(e) then DeleteEntity(e) end
    end
    rt.projectorEntities = nil
    rt.projectorLive = false
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, rt in pairs(active) do removeProjector(rt) end
end)

function TerritoryAuction.isActive(id) return active[id] ~= nil end
function TerritoryAuction.get(id) return active[id] end
function TerritoryAuction.getActiveIds()
    local list = {}
    for id in pairs(active) do list[#list + 1] = id end
    return list
end

-- The shape the Event Status "Events" list reads for a live event.
function TerritoryAuction.getPublicState(id)
    local rt = active[id]
    if not rt then return nil end
    local c = rt.activeLot
    return {
        id = rt.id, name = rt.def.name, status = 'ACTIVE', kind = 'GANG_TERRITORY', reward = rt.def.reward,
        currentRouteIndex = rt.lotIndex or 0, totalRoutePoints = #rt.lots,
        deliveryTimeRemaining = math.max(0, rt.deadline - os.time()),
        territory = { phase = rt.phase, lot = c and c.name or nil, bid = c and c.currentBid or nil, leading = c and c.highestBidderGang or nil },
        policeParticipants = 0, gangParticipants = #Territory.audience(),
    }
end

-- ── one territory ────────────────────────────────────────────────────────────────

-- Pays mount from the player: bank, else cash, else a mix (the bid check counts bank + cash together, so a split payment must work).
local function payAmount(src, amount)
    if Bridge.RemoveMoney(src, amount, 'bank') then return true end
    if Bridge.RemoveMoney(src, amount, 'cash') then return true end
    local bank, cash = Bridge.GetMoney(src, 'bank') or 0, Bridge.GetMoney(src, 'cash') or 0
    if bank + cash < amount then return false end
    local fromBank = math.min(bank, amount)
    if fromBank > 0 and not Bridge.RemoveMoney(src, fromBank, 'bank') then return false end
    local rest = amount - fromBank
    if rest > 0 and not Bridge.RemoveMoney(src, rest, 'cash') then
        if fromBank > 0 then Bridge.AddMoney(src, fromBank, 'bank') end
        return false
    end
    return true
end

local function closeLot(rt, c)
    -- The server's clock decides: from here no bid is accepted, whatever is still in flight.
    c.status = 'AUCTION_CLOSING'
    c.version = (c.version or 0) + 1

    local result = { status = 'UNSOLD', winningGang = nil, finalBid = 0, bidCount = c.bidCount or 0 }
    local territory = Territory.get(c.territoryId)

    if c.highestBidder and c.highestBidderGangName and territory then
        local winnerSrc = resolveBidderSource(c)
        local amount = c.currentBid
        local paid = false
        if winnerSrc then
            paid = payAmount(winnerSrc, amount)
        end
        if paid then
            local previous = territory.owner
            local okT, ok, why = pcall(Territory.transfer, c.territoryId, c.highestBidderGangName, previous, {
                reason = 'AUCTION', refType = 'AUCTION', refId = c.auctionId,
                winnerIdentifier = c.highestBidder, winnerName = c.highestBidderName, amount = amount,
                meta = { event = rt.def.name, lot = c.lotIndex },
                -- the land the territory had (old starting land, the previous owner's paint) is wiped: the winner paints it themselves
                clearLand = acfg().clearLandOnSale ~= false,
            })
            if not okT then why = ok; ok = false end   -- the transfer threw: refunded below like any other failed transfer
            if ok then
                c.status = 'WON'
                result = { status = 'WON', winningGang = c.highestBidderGangName, winningIdentifier = c.highestBidder,
                           winningPlayer = c.highestBidderName, finalBid = amount, bidCount = c.bidCount or 0 }
                rt.gangStats[c.highestBidderGangName] = rt.gangStats[c.highestBidderGangName] or { label = c.highestBidderGang, won = 0, spend = 0, bids = 0 }
                local gs = rt.gangStats[c.highestBidderGangName]
                gs.won, gs.spend = gs.won + 1, gs.spend + amount
            else
                -- the territory changed hands while the lot was closing: the money goes straight back
                Bridge.AddMoney(winnerSrc, amount, 'bank')
                c.status, c.unsoldReason = 'UNSOLD', 'CHANGED'
                result.status = 'CANCELLED'
                log(rt.id, ('%s could not be transferred (%s) — %s refunded'):format(c.name, tostring(why), money(amount)))
            end
        else
            c.status, c.unsoldReason = 'UNSOLD', 'PAYMENT_FAILED'
            result.status = 'PAYMENT_FAILED'
        end
    else
        c.status, c.unsoldReason = 'UNSOLD', c.highestBidder and 'CHANGED' or 'NO_BIDS'
    end

    if c.auctionId then
        pcall(DB.territoryAuctionClose, c.auctionId, result)
    end
    return result
end

local function runLot(rt, c)
    local a = rt.def.territory.auction
    rt.activeLot = c
    rt.lotIndex = c.lotIndex

    local auctionId, prior = DB.territoryAuctionOpen({
        eventId = rt.id, runId = rt.runId, territoryId = c.territoryId, territoryName = c.name,
        lotIndex = c.lotIndex, startingBid = c.startingBid,
    })
    if prior ~= 'OPEN' then
        -- this lot already has a result for this run (a restarted event): do not auction it twice
        c.status = 'UNSOLD'
        c.unsoldReason = 'ALREADY_DECIDED'
        return
    end
    c.auctionId = auctionId

    local terr = Territory.get(c.territoryId)
    c.owner = (terr or {}).owner
    if terr then
        local cx, cy = Territory.center(terr)
        c.preview = { cs = terr.def.base.cs, spans = Territory.shapeSpans(terr), color = terr.color, x = cx, y = cy }
    end
    c.status = 'AUCTION_ACTIVE'
    c.currentBid = c.startingBid
    c.highestBidder, c.highestBidderSource, c.highestBidderName, c.highestBidderGang, c.highestBidderGangName = nil, nil, nil, nil, nil
    c.timeRemaining = math.floor(c.auctionDuration)
    c.version = (c.version or 0) + 1
    c.bidCount = 0
    c.lastBidAt = {}
    rt.phase = 'BIDDING'

    announce(rt, 'lots', ('TERRITORY %d OF %d — BIDDING OPEN'):format(c.lotIndex, #rt.lots),
        ('%s is up for auction. Starting bid %s. Eligible gangs: head to the auction house.'):format(c.name, money(c.startingBid)),
        math.min(9000, c.timeRemaining * 1000), 'BIDDING OPEN')
    log(rt.id, ('Lot %d/%d "%s" open — start %s, %ds'):format(c.lotIndex, #rt.lots, c.name, money(c.startingBid), c.timeRemaining))
    push('nova_convoytruck:territory:client:auctionState', TerritoryAuction.publicState(rt))

    while c.timeRemaining > 0 and active[rt.id] == rt do
        Wait(1000)
        c.timeRemaining = c.timeRemaining - 1
        push('nova_convoytruck:territory:client:auctionTick', {
            eventId = rt.id, territoryId = c.territoryId, timeRemaining = c.timeRemaining, currentBid = c.currentBid,
            version = c.version, leadingGang = c.highestBidderGangName, leadingGangLabel = c.highestBidderGang,
            leadingPlayer = c.highestBidderName, endsIn = math.max(0, rt.deadline - os.time()),
        })
    end
    if active[rt.id] ~= rt then return end

    local result = closeLot(rt, c)
    rt.phase = 'RESULT'
    if result.status == 'WON' then
        local label = c.highestBidderGang or c.highestBidderGangName
        announce(rt, 'result', 'TERRITORY SOLD', ('%s%s won %s for %s!'):format(label, c.highestBidderName and (' (' .. c.highestBidderName .. ')') or '', c.name, money(result.finalBid)), 9000, 'SOLD')
        DiscordLog.appendEvent(rt.id, ('🔨 SOLD — %s won %s (%s) for %s'):format(label, c.name, c.highestBidderName or 'bidder', money(result.finalBid)))
        DB.insertConvoyEvent(rt.id, 'TERRITORY_WON', {
            gangName = c.highestBidderGangName, gangLabel = c.highestBidderGang, playerIdentifier = c.highestBidder,
            playerName = c.highestBidderName, detail = ('Won %s for %s'):format(c.name, money(result.finalBid)),
        })
    elseif result.status == 'PAYMENT_FAILED' then
        announce(rt, 'result', 'PAYMENT FAILED', ('The winner of %s could not pay. The territory stays unsold.'):format(c.name), 7000, 'UNPAID')
        DiscordLog.appendEvent(rt.id, ('⚠️ %s — winning bidder %s could not pay, territory unsold'):format(c.name, c.highestBidderName or 'unknown'))
    elseif result.status == 'CANCELLED' then
        announce(rt, 'result', 'AUCTION VOID', ('%s could not be sold (it changed hands or a war started on it) — all bids were returned.'):format(c.name), 7000, 'VOID')
    else
        announce(rt, 'result', 'NO BIDS PLACED', ('Nobody bid on %s. The territory stays as it was.'):format(c.name), 6000, 'UNSOLD')
        DiscordLog.appendEvent(rt.id, ('⏭️ %s received no bids — unsold'):format(c.name))
    end
    push('nova_convoytruck:territory:client:auctionState', TerritoryAuction.publicState(rt))
end

-- ── the event ────────────────────────────────────────────────────────────────────

local function buildReport(rt, outcome, forcedByName)
    local lots, topGang, topWins = {}, nil, 0
    local wins = {}
    for _, c in ipairs(rt.lots) do
        if c.status == 'WON' and c.highestBidderGangName then
            wins[c.highestBidderGangName] = (wins[c.highestBidderGangName] or 0) + 1
            if wins[c.highestBidderGangName] > topWins then topWins, topGang = wins[c.highestBidderGangName], c.highestBidderGangName end
        end
        lots[#lots + 1] = {
            id = c.territoryId, containerIndex = c.lotIndex, name = c.name, finalBid = c.currentBid or 0,
            startingBid = c.startingBid, bidCount = c.bidCount or 0,
            winningGang = c.status == 'WON' and c.highestBidderGang or nil, winningGangName = c.status == 'WON' and c.highestBidderGangName or nil,
            winningPlayer = c.highestBidderName, winningPlayerIdentifier = c.highestBidder,
            status = c.status, unsoldReason = c.unsoldReason, rewardsText = 'Territory ownership',
        }
    end
    local topLabel = topGang and rt.gangStats[topGang] and rt.gangStats[topGang].label or topGang
    -- what the auction really produced: which gang now owns which territory (not a fixed label)
    local ownership = {}
    for _, c in ipairs(rt.lots) do
        if c.status == 'WON' then ownership[#ownership + 1] = ('%s -> %s'):format(c.name, c.highestBidderGang or c.highestBidderGangName or '?') end
    end
    local rewardsText = #ownership > 0 and table.concat(ownership, ' | ') or 'No territory changed hands'
    if #rewardsText > 220 then rewardsText = rewardsText:sub(1, 217) .. '...' end
    return ReportBuilder.territoryAuction({
        id = rt.id, name = rt.def.name, startedAt = rt.startedAt, endedAt = os.time(), outcome = outcome,
        startedByName = rt.startedByName, forcedByName = forcedByName, topGang = topGang, topGangLabel = topLabel,
        containers = lots, gangStats = rt.gangStats, rewards = rewardsText, timeline = DiscordLog.getTimeline(rt.id),
    }), topGang, topWins
end

local function recordEnd(rt, outcome, forcedByName)
    local report, topGang, topWins = buildReport(rt, outcome, forcedByName)
    local sold = 0
    for _, c in ipairs(rt.lots) do if c.status == 'WON' then sold = sold + 1 end end
    DB.insertConvoyHistory({
        convoyDefinitionId = rt.id, name = rt.def.name, createdBy = rt.def.createdByName or 'System',
        startedAt = rt.startedAt, endedAt = os.time(), duration = os.time() - rt.startedAt,
        truckCount = #rt.lots, policeParticipants = 0, gangParticipants = report.roster and report.roster.gangCount or 0,
        winningGang = topGang, outcome = outcome,
        rewardSummary = report.rewards or ('%d of %d territories sold'):format(sold, #rt.lots),
        destroyedTrucks = 0, checkpointsCompleted = sold, kind = 'GANG_TERRITORY', reportData = report,
    })
    local fields = {
        { name = 'Event Tag', value = '[GANG TERRITORY] 🗺️', inline = true },
        { name = 'Auction', value = rt.def.name, inline = true },
        { name = 'Outcome', value = outcome, inline = true },
        { name = 'Territories sold', value = ('%d / %d'):format(sold, #rt.lots), inline = true },
        { name = 'Top bidder', value = report.winner or 'None', inline = true },
        { name = 'Duration', value = report.durationText or '-', inline = true },
    }
    -- every lot: who won it and for how much (or why it stayed unsold)
    do
        local lines = {}
        for _, c in ipairs(rt.lots) do
            if #lines >= 12 then lines[#lines + 1] = '...' break end
            if c.status == 'WON' then
                lines[#lines + 1] = ('🔨 **%s** — %s (%s) for %s, %d bid%s'):format(c.name, c.highestBidderGang or c.highestBidderGangName or '?', c.highestBidderName or 'bidder', money(c.currentBid or 0), c.bidCount or 0, (c.bidCount or 0) == 1 and '' or 's')
            elseif c.status == 'PAYMENT_FAILED' or c.unsoldReason == 'PAYMENT_FAILED' then
                lines[#lines + 1] = ('⚠️ **%s** — winner could not pay, unsold'):format(c.name)
            elseif c.status == 'UNSOLD' then
                lines[#lines + 1] = ('⏭️ **%s** — no bids, unsold'):format(c.name)
            else
                lines[#lines + 1] = ('▫️ **%s** — not reached'):format(c.name)
            end
        end
        if #lines > 0 then fields[#fields + 1] = { name = 'Territory results', value = table.concat(lines, '\n'):sub(1, 1000), inline = false } end
        if report.labels and report.labels.card4 then fields[#fields + 1] = { name = 'Auction total', value = ('%s — %s'):format(report.labels.card4.main or '-', report.labels.card4.sub or ''), inline = true } end
        for _, st in ipairs(report.gangScorecard or {}) do
            if #fields < 20 and st.cells then fields[#fields + 1] = { name = st.label, value = ('%s won | %s spent | %s bids'):format(st.cells[1], st.cells[2], st.cells[3]), inline = true } end
        end
    end
    if forcedByName then fields[#fields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true } end
    -- the same After-Action PDF Container Wars / TDM attach to their Discord log (also what Event History's "PDF" downloads)
    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(report)
    end
    if pdfString then
        fields[#fields + 1] = { name = '📄 After-Action Report (PDF)', value = 'Full auction report generated and attached to this message.', inline = false }
    end
    local color = outcome == 'COMPLETED' and 0xc45ee0 or 0x6b7280
    DiscordLog.finishEvent(rt.id, ('🗺️ [GANG TERRITORY] %s — %s'):format(outcome == 'CANCELLED' and 'Cancelled' or 'Concluded', rt.def.name),
        color, fields, ('🏆 %s | %s'):format(report.winner or 'No winner', report.durationText or '-'), pdfString, 'GANG_TERRITORY')
end

-- A personal congratulation for every member of each gang that bought something: a toast with a sound for those online, and the
-- same text as a gang notice that members who are offline get when they next log in. One message per gang, listing every territory
-- it bought. Config.Territory.auction.congratulate = false turns it off.
local function joinNames(list)
    if #list == 1 then return list[1] end
    return table.concat(list, ', ', 1, #list - 1) .. ' and ' .. list[#list]
end

local function congratulateWinners(rt)
    if (acfg().congratulate) == false then return end
    local byGang, order = {}, {}
    for _, c in ipairs(rt.lots) do
        if c.status == 'WON' and c.highestBidderGangName then
            local g = byGang[c.highestBidderGangName]
            if not g then g = { label = c.highestBidderGang or c.highestBidderGangName, names = {} } byGang[c.highestBidderGangName] = g order[#order + 1] = c.highestBidderGangName end
            g.names[#g.names + 1] = tostring(c.name)
        end
    end
    local cmd = (Config.StatusPanel or {}).command or 'eventstatus'
    for _, gangName in ipairs(order) do
        local g = byGang[gangName]
        local one = #g.names == 1
        local title = one and 'TERRITORY WON' or 'TERRITORIES WON'
        local body = ('Congratulations! Your gang bought %s. Open your gang tablet (or type /%s) and go to Map Zone to see %s.'):format(
            joinNames(g.names), cmd, one and 'your territory' or 'your territories')
        Territory.eachGangMember(gangName, function(src)
            TriggerClientEvent('nova_convoytruck:territory:client:notify', src, { kind = 'auction-won', title = title, message = body })
        end)
        if TerritoryNotices and TerritoryNotices.announceToGang then
            pcall(TerritoryNotices.announceToGang, gangName, title, body, 'WON', '#46c98b')
        end
        log(rt.id, ('Congratulated %s: %s'):format(g.label, table.concat(g.names, ', ')))
    end
    -- and a small banner for the whole server naming the new owners, shown just after the 'auction concluded' banner so the two do not overlap
    if #order > 0 then
        local parts = {}
        for _, gangName in ipairs(order) do
            local g = byGang[gangName]
            parts[#parts + 1] = ('%s: %s'):format(g.label, joinNames(g.names))
        end
        local body = table.concat(parts, '   •   '):sub(1, 220)
        SetTimeout(9500, function() announce(rt, 'ended', 'CONGRATULATIONS', body, 7000, 'NEW OWNERS') end)
    end
end

local function finish(rt, outcome, forcedByName)
    if active[rt.id] ~= rt then return end
    rt.phase = 'ENDED'
    rt.activeLot = nil
    removeProjector(rt)    -- the placement stays saved in the event configuration; only the world copy goes
    log(rt.id, 'Finished: ' .. outcome)
    -- the report / PDF / Discord must never keep the event alive: if it throws the event would stay 'running' for good
    local okRec, errRec = pcall(recordEnd, rt, outcome, forcedByName)
    if not okRec then print(('^1[NovaConvoy][Territory] auction report failed: %s^0'):format(tostring(errRec))) end
    active[rt.id] = nil
    ConvoyManager.setStatus(rt.id, outcome == 'CANCELLED' and 'CANCELLED' or 'COMPLETED')
    push('nova_convoytruck:territory:client:auctionEnded', { eventId = rt.id })
    if outcome == 'COMPLETED' then
        local sold, total = 0, #rt.lots
        for _, c in ipairs(rt.lots) do if c.status == 'WON' then sold = sold + 1 end end
        announce(rt, 'ended', 'GANG TERRITORY AUCTION CONCLUDED', ('%d of %d territories found a new owner. The territory map is in the Event Status tablet.'):format(sold, total), 9000, 'CLOSED')
        pcall(congratulateWinners, rt)
    else
        -- ended early by an administrator: every territory already sold stays with its new owner (the sale is final the moment its lot closes);
        -- only the lot being bid on at that moment is void. The winners are congratulated as usual.
        local sold = 0
        for _, c in ipairs(rt.lots) do if c.status == 'WON' then sold = sold + 1 end end
        if sold > 0 then
            announce(rt, 'ended', 'TERRITORY AUCTION ENDED', ('"%s" was closed by an administrator. The %d territor%s already sold stay%s with the winning gang%s.'):format(rt.def.name, sold, sold == 1 and 'y' or 'ies', sold == 1 and 's' or '', sold == 1 and '' or 's'), 9000, 'CLOSED')
            pcall(congratulateWinners, rt)
        else
            announce(rt, 'ended', 'TERRITORY AUCTION CANCELLED', ('"%s" was cancelled by an administrator.'):format(rt.def.name), 7000, 'CANCELLED')
        end
    end
end

function TerritoryAuction.forceEnd(source, eventId)
    local rt = active[eventId]
    if not rt then return false, 'Event is not active.' end
    -- the lot in progress is void: nobody pays, nobody wins
    if rt.activeLot and rt.activeLot.status == 'AUCTION_ACTIVE' then
        rt.activeLot.status, rt.activeLot.unsoldReason = 'UNSOLD', 'CANCELLED'
        if rt.activeLot.auctionId then pcall(DB.territoryAuctionClose, rt.activeLot.auctionId, { status = 'CANCELLED', finalBid = 0, bidCount = rt.activeLot.bidCount or 0 }) end
    end
    DiscordLog.appendEvent(eventId, '🛑 Auction force-ended by an administrator')
    finish(rt, 'CANCELLED', source and source > 0 and Bridge.GetPlayerName(source) or nil)
    return true
end

function TerritoryAuction.start(starterSource, eventId)
    local def = ConvoyManager.get(eventId)
    if not def then return false, 'Event definition not found.' end
    if def.kind ~= 'GANG_TERRITORY' then return false, 'Not a Gang Territory event.' end
    if active[eventId] then return false, 'This event is already running.' end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then return false, 'Only draft or scheduled events can be started.' end

    local terr = def.territory or {}
    local auction = terr.auction or {}
    local zonePts = (auction.zone and auction.zone.points) or auction.zonePoints
    if not auction.location and zonePts and #zonePts >= 3 then
        local cx, cy, cz = 0.0, 0.0, 0.0
        for _, p in ipairs(zonePts) do
            cx = cx + p.x
            cy = cy + p.y
            cz = cz + (p.z or 0.0)
        end
        auction.location = { x = cx / #zonePts, y = cy / #zonePts, z = cz / #zonePts }
    end
    if not auction.location then return false, 'Set the auction location or perimeter first (Auction Setup tab).' end

    local lots = {}
    for _, area in ipairs(terr.areas or {}) do
        if area.auctioned ~= false then
            -- where the zone is: its pin on the big screen's map (blinks when the zone comes up)
            local lx, ly
            local live = Territory.get(area.id)
            if live then
                local okC, cx, cy = pcall(Territory.center, live)
                if okC then lx, ly = cx, cy end
            end
            if not lx and area.location and area.location.x then lx, ly = area.location.x, area.location.y end
            lots[#lots + 1] = {
                x = lx, y = ly,
                territoryId = area.id, name = area.name, lotIndex = #lots + 1, startingBid = area.startingBid,
                minBidIncrement = area.minBidIncrement, auctionDuration = auction.lotSeconds or 90,
                status = 'PENDING', currentBid = area.startingBid, version = 0, bidCount = 0, timeRemaining = 0,
                xpValue = tonumber(area.xpValue) or 0, color = area.color, description = area.description,
            }
        end
    end
    if #lots == 0 then return false, 'No territory is set to be auctioned. Add territories in the Gang Areas tab.' end

    local startedByName = 'Automated Schedule'
    if starterSource and starterSource > 0 then
        startedByName = ('%s (%s)'):format(Bridge.GetPlayerName(starterSource) or 'Admin', Bridge.GetIdentifier(starterSource) or 'N/A')
    end

    local rt = {
        id = eventId, def = def, lots = lots, phase = 'INTRO', startedAt = os.time(), startedByName = startedByName,
        gangStats = {}, activeLot = nil, lotIndex = 0,
    }
    rt.runId = rt.startedAt
    -- 0 / empty Auction Duration = the default (Config.Territory.auction.defaults.eventMinutes, 30), never a one-minute auction
    local durationSeconds = tonumber(def.eventDuration) or 0
    if durationSeconds <= 0 then durationSeconds = (tonumber(acfg().defaults and acfg().defaults.eventMinutes) or 30) * 60 end
    rt.deadline = rt.startedAt + math.max(60, durationSeconds)
    active[eventId] = rt
    rt.introEndsAt = os.time() + math.max(0, math.floor(tonumber(auction.introSeconds) or 0))   -- end of the 'bidding opens in...' buffer

    -- the event's territories exist on every map from now on (ConvoyManager also syncs when it flips to ACTIVE)
    pcall(Territory.syncFromEvent, def)
    ConvoyManager.setStatus(eventId, 'ACTIVE')

    push('nova_convoytruck:territory:client:auctionState', TerritoryAuction.publicState(rt))
    announce(rt, 'start', 'GANG TERRITORY AUCTION', ('"%s" is open. %d territor%s up for auction — eligible gangs, report to the auction house.'):format(def.name, #lots, #lots == 1 and 'y is' or 'ies are'), 10000, 'AUCTION OPEN')
    -- the live Discord log for this event (every lot result is appended to it; the final PDF is attached when it ends)
    DiscordLog.startEvent(eventId, ('🗺️ [GANG TERRITORY] Auction live — %s'):format(def.name), 0xc45ee0,
        ('%d territor%s up for auction.'):format(#lots, #lots == 1 and 'y is' or 'ies are'), {
            { name = 'Event', value = def.name, inline = true }, { name = 'Started by', value = startedByName, inline = true },
            { name = 'Territories', value = tostring(#lots), inline = true },
        })
    DiscordLog.appendEvent(eventId, ('🗺️ Gang Territory Auction started — %d territories'):format(#lots))

    CreateThread(function()
        local intro = math.floor(tonumber(auction.introSeconds) or 0)
        local gap = math.floor(tonumber(auction.lotGapSeconds) or 15)
        if intro > 0 then
            announce(rt, 'start', 'AUCTION STARTING', ('Bidding opens in %d seconds.'):format(intro), math.min(8000, intro * 1000), 'STARTING SOON')
            for _ = 1, intro do
                if active[eventId] ~= rt then return end
                Wait(1000)
            end
        end
        -- the buffer is over: bidding is about to start, so the projector appears now (and stays until the event ends)
        if active[eventId] ~= rt then return end
        local okP, errP = pcall(spawnProjector, rt)
        if not okP then print(('^1[NovaConvoy][TerritoryAuction] projector spawn failed: %s^0'):format(tostring(errP))) end
        push('nova_convoytruck:territory:client:auctionState', TerritoryAuction.publicState(rt))
        for i, c in ipairs(rt.lots) do
            if active[eventId] ~= rt then return end
            if os.time() >= rt.deadline then
                -- the Auction Duration has run out: the territories not yet reached stay as they were
                for j = i, #rt.lots do rt.lots[j].status, rt.lots[j].unsoldReason = 'UNSOLD', 'TIME' end
                announce(rt, 'ended', 'AUCTION TIME UP', 'The auction duration is over. The remaining territories were not sold.', 8000, 'TIME UP')
                break
            end
            local ok, err = pcall(runLot, rt, c)
            if not ok then
                print(('^1[NovaConvoy][TerritoryAuction] lot "%s" failed: %s^0'):format(c.name, tostring(err)))
                c.status, c.unsoldReason = 'UNSOLD', 'ERROR'
            end
            if active[eventId] ~= rt then return end
            if i < #rt.lots then
                rt.phase = 'BREAK'
                rt.activeLot = nil
                push('nova_convoytruck:territory:client:auctionState', TerritoryAuction.publicState(rt))
                for _ = 1, gap do
                    if active[eventId] ~= rt then return end
                    Wait(1000)
                end
            end
        end
        if active[eventId] == rt then finish(rt, 'COMPLETED') end
    end)
    return true
end

-- ── bidding (events from the bidder window) ──────────────────────────────────────

local bidCfg = acfg().bidding or {}
local BID_MIN_GAP_MS = tonumber(bidCfg.serverMinGapMs) or 300
local BID_STALE_MSG = bidCfg.staleMessage or 'Bid is no longer valid. Current bid has changed.'

local function findLot(rt, territoryId)
    if rt.activeLot and rt.activeLot.territoryId == territoryId then return rt.activeLot end
    for _, c in ipairs(rt.lots) do
        if c.territoryId == territoryId then return c end
    end
    return nil
end

local function bidReply(src, reqId, c, ok, code, message)
    TriggerClientEvent('nova_convoytruck:territory:client:bidResult', src, {
        reqId = reqId, ok = ok == true, code = code, message = message,
        territoryId = c and c.territoryId or nil, version = c and c.version or nil, currentBid = c and c.currentBid or nil,
        minimumBid = c and AuctionCore.minimumNext(c) or nil, increment = c and c.minBidIncrement or nil,
        canBid = c and AuctionCore.bidOpen(c) or false,
    })
end

local function applyBid(src, rt, c, amount, version, reqId)
    if not AuctionCore.bidOpen(c) then return false, 'ENDED', 'This auction is no longer taking bids.' end
    local gang, code, msg = bidderGang(rt, src)
    if not gang then return false, code, msg end
    -- pointless bids: raising your own lead, or buying a territory your gang already owns
    if c.highestBidderGangName and c.highestBidderGangName == gang.name then return false, 'LEADING', 'Your gang already has the highest bid.' end
    local lotTerritory = Territory.get(c.territoryId)
    if lotTerritory and lotTerritory.owner == gang.name then return false, 'OWN', 'Your gang already owns this territory.' end

    local a = rt.def.territory.auction
    local ok, bcode, bmsg = AuctionCore.apply(c, {
        amount = amount, version = version, source = src,
        identifier = Bridge.GetIdentifier(src), name = Bridge.GetCharacterName(src), gang = gang,
    }, {
        staleMessage = BID_STALE_MSG, snipeEnabled = a.antiSnipeEnabled ~= false,
        snipeWindow = a.antiSnipeWindowSeconds, snipeExtend = a.antiSnipeExtendSeconds,
    })
    if not ok then return false, bcode, bmsg end

    local gs = rt.gangStats[gang.name] or { label = gang.label or gang.name, won = 0, spend = 0, bids = 0 }
    gs.bids = gs.bids + 1
    rt.gangStats[gang.name] = gs
    -- bid history (async: a bid never waits for the database)
    if c.auctionId then
        DB.territoryBidInsert({ auctionId = c.auctionId, identifier = c.highestBidder, name = c.highestBidderName, gangName = gang.name,
                                amount = c.currentBid, version = c.version, reqId = reqId })
    end
    return true
end

RegisterNetEvent('nova_convoytruck:territory:server:placeBid', function(eventId, territoryId, amount, version, reqId)
    local src = source
    reqId = tostring(reqId or ''):sub(1, 40)
    local rt = active[tonumber(eventId)]
    if not rt then return bidReply(src, reqId, nil, false, 'NO_EVENT', 'The auction is not running.') end
    local c = findLot(rt, tostring(territoryId or ''))
    if not c then return bidReply(src, reqId, nil, false, 'NO_LOT', 'Territory not found.') end

    -- rate limit (per player per lot) + one bid at a time + error guard: shared with Container Wars
    local ok, code, msg = AuctionCore.guard(c, src, BID_MIN_GAP_MS, BID_STALE_MSG, function()
        return applyBid(src, rt, c, amount, version, reqId)
    end)
    if not ok then return bidReply(src, reqId, c, false, code, msg) end

    log(rt.id, ('Bid: %s (%s) %s on %s'):format(c.highestBidderName, c.highestBidderGang, money(c.currentBid), c.name))
    push('nova_convoytruck:territory:client:bidUpdate', {
        eventId = rt.id, territoryId = c.territoryId, currentBid = c.currentBid, minimumBid = AuctionCore.minimumNext(c),
        version = c.version, timeRemaining = c.timeRemaining, leadingGang = c.highestBidderGangName,
        leadingGangLabel = c.highestBidderGang, leadingPlayer = c.highestBidderName, bidCount = c.bidCount, bidderSource = src,
    })
    bidReply(src, reqId, c, true, 'OK', ('You are leading with %s for %s.'):format(money(c.currentBid), c.highestBidderGang))
end)

-- Opening the bidder window: the server confirms the player may bid and supplies the numbers and their gang.
lib.callback.register('nova_convoytruck:territory:bidInfo', function(src, eventId, territoryId)
    local rt = active[tonumber(eventId)]
    if not rt then return { ok = false, message = 'The auction is not running.' } end
    local c = rt.activeLot
    if not c or (territoryId and c.territoryId ~= territoryId) or not AuctionCore.bidOpen(c) then
        return { ok = false, message = 'No territory is open for bidding right now.' }
    end
    local gang, _, msg = bidderGang(rt, src)
    if not gang then return { ok = false, message = msg } end
    return {
        ok = true, eventId = rt.id, territoryId = c.territoryId, lotNumber = c.lotIndex, lotName = c.name,
        currentBid = c.currentBid, minimumBid = AuctionCore.minimumNext(c), increment = c.minBidIncrement,
        gang = gang.label or gang.name, version = c.version, canBid = true,
    }
end)

-- A joining client asks for the auction in progress.
RegisterNetEvent('nova_convoytruck:territory:server:requestAuctionSync', function()
    local src = source
    for _, rt in pairs(active) do
        TriggerClientEvent('nova_convoytruck:territory:client:auctionState', src, TerritoryAuction.publicState(rt))
    end
end)

-- Auction results for the admin tab / the gang tablet.
function TerritoryAuction.history(eventId, limit)
    local rows = DB.territoryAuctionsList(eventId, limit)
    for _, r in ipairs(rows) do r.winningLabel = Territory.gangLabel(r.winning_gang) end
    return rows
end

return TerritoryAuction
