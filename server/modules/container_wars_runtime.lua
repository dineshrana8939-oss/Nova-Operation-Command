-- ─── Nova Convoy — Container Wars Live Event Runtime (server) ───────────────────
-- Server-authoritative state machine for Container Wars harbour auction events.
-- Supports batch staging via physical crane simulation, open gang bidding,
-- authoritative winner deduction, gang bidding leaderboard stats, individual
-- winner tracking, and winning container visual states.

ContainerWars = {}

local active = {} -- [convoyId] = rt

local function log(convoyId, msg)
    print(('[NovaConvoy][ContainerWars #%s] %s'):format(tostring(convoyId), tostring(msg)))
end

local function notify(sources, event, ...)
    for _, src in ipairs(sources or {}) do
        TriggerClientEvent(event, src, ...)
    end
end

local function allPlayers()
    return Bridge.GetPlayers() or {}
end

-- A Container Wars banner: its own harbour-green theme (kind 'containerwars' — see web/src/lib/hud/eventThemes.js) and a
-- badge on the right ("ROUND 2 / 4", "SOLD" ...) saying what just happened.
local function cwAnnounce(title, body, duration, status)
    notify(allPlayers(), 'nova_convoytruck:runtime:announce', title, body, duration, 'containerwars', nil, status)
end

-- Simple HUD notification (ox_lib:notify) for intra-event updates (drops, bids, next container, round info)
local function cwHudNotify(title, body, notifyType, duration)
    TriggerClientEvent('nova_convoytruck:client:hudNotify', -1, {
        title = title or 'CONTAINER WARS',
        description = body,
        type = notifyType or 'info',
        duration = duration or 5000,
        position = 'top-right',
    })
end

local function eligibleGang(rt, gangName)
    if not gangName or gangName == '' or gangName == 'none' then return false end
    -- an event open to EVERYONE lets every gang in: the invite list (hidden in the tablet for such events) is ignored
    if rt.def.settings and rt.def.settings.eventAccess == 'EVERYONE' then return true end
    local ag = rt.def.settings and rt.def.settings.allowedGangs
    if not ag or ag.mode ~= 'SELECTED' then return true end
    for _, name in ipairs(ag.gangs or {}) do
        if name == gangName then return true end
    end
    return false
end

function ContainerWars.isActive(convoyId)
    return active[convoyId] ~= nil
end

function ContainerWars.getActiveIds()
    local list = {}
    for id in pairs(active) do list[#list + 1] = id end
    return list
end

function ContainerWars.get(convoyId)
    return active[convoyId]
end

function ContainerWars.isParticipant(convoyId, source)
    local rt = active[convoyId]
    if not rt then return false end
    local identifier = Bridge.GetIdentifier(source)
    if rt.participants and rt.participants.civilians and identifier and rt.participants.civilians[identifier] then
        return true   -- includes an officer who registered at the civilian registration ped
    end
    if Bridge.IsPolice(source) then return false end
    local g = GangService and GangService.GetPlayerGang(source)
    return g and eligibleGang(rt, g.name) or false
end

function ContainerWars.registerCivilian(convoyId, source)
    convoyId = tonumber(convoyId)
    local rt = active[convoyId]
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false, 'Unable to identify player.' end

    if not rt then
        local def = ConvoyManager.get(convoyId)
        if not def then return false, 'Event not found.' end
        def.civilianRoster = def.civilianRoster or {}
        for _, id in ipairs(def.civilianRoster) do
            if id == identifier then return false, 'You are already registered.' end
        end
        def.civilianRoster[#def.civilianRoster + 1] = identifier
        ConvoyManager.update(convoyId, { civilianRoster = def.civilianRoster })
        return true
    end

    rt.participants = rt.participants or { identifiers = {}, civilians = {} }
    rt.participants.civilians = rt.participants.civilians or {}
    if rt.participants.civilians[identifier] then
        return false, 'You are already registered for this auction.'
    end
    rt.participants.civilians[identifier] = true
    rt.participants.identifiers = rt.participants.identifiers or {}
    rt.participants.identifiers[identifier] = 'civilian'

    TriggerClientEvent('nova_convoytruck:containerWars:client:joinParticipant', source, {
        convoyId = rt.id,
        name = rt.def.name,
    })
    return true
end

function ContainerWars.getPublicState(convoyId)
    local rt = active[convoyId]
    if not rt then return nil end
    local currentCont = rt.activeContainer
    return {
        id = rt.id,
        name = rt.def.name,
        status = 'ACTIVE',
        kind = 'CONTAINER_WARS',
        reward = rt.def.reward,
        currentRound = rt.currentRound,
        totalRounds = rt.totalRounds,
        totalContainers = rt.totalContainers,
        activeContainer = currentCont and {
            id = currentCont.id,
            containerIndex = currentCont.containerIndex,
            name = currentCont.name,
            currentBid = currentCont.currentBid or 0,
            highestBidderGang = currentCont.highestBidderGang,
            highestBidderGangName = currentCont.highestBidderGangName,
            highestBidderName = currentCont.highestBidderName,
            timeRemaining = currentCont.timeRemaining or 0,
            status = currentCont.status,
        } or nil,
        policeParticipants = 0,
        gangParticipants = #allPlayers(),
    }
end

-- Model strings are names ('prop_container_05a') or 'hash:<number>' for a map
-- container picked in the placer whose name could not be matched.
local function modelHashOf(model)
    local n = type(model) == 'string' and tonumber(model:match('^hash:(%-?%d+)$'))
    return n or joaat(model or 'tr_prop_tr_container_01a')
end

-- Creates a frozen, networked prop and WAITS until the server can see it. A server-created
-- entity is not always there on the very next line (DoesEntityExist is briefly false), and
-- skipping that check silently left the whole yard empty — no containers, no crane movement.
local function spawnProp(model, x, y, z, heading)
    local obj = CreateObjectNoOffset(modelHashOf(model), x + 0.0, y + 0.0, (z or 0.0) + 0.0, true, true, false)
    if not obj or obj == 0 then return nil end
    local deadline = GetGameTimer() + 3000
    while not DoesEntityExist(obj) and GetGameTimer() < deadline do Wait(25) end
    if not DoesEntityExist(obj) then return nil end
    SetEntityHeading(obj, (heading or 0.0) + 0.0)
    FreezeEntityPosition(obj, true)
    return obj
end

-- Doors. Only the "mb" container models have a doorless end that the door props close, so a lot is placed as its
-- door-capable twin (Config.ContainerWars.openContainer.doors.variants) and the doors are fitted by the clients.
local function doorCfg()
    return (Config.ContainerWars and Config.ContainerWars.openContainer and Config.ContainerWars.openContainer.doors) or {}
end

local function containerBodyModel(model)
    local alias = (Config.ContainerWars and Config.ContainerWars.containerModelAlias) or {}
    if alias[model] then model = alias[model] end
    local d = doorCfg()
    if d.useVariants ~= false and type(model) == 'string' and type(d.variants) == 'table' and d.variants[model] then
        return d.variants[model]
    end
    return model or 'tr_prop_tr_container_01a'
end

-- false for a model listed with opens = false in Config.ContainerWars.containerModels (see there)
local function modelOpens(model)
    for _, m in ipairs((Config.ContainerWars and Config.ContainerWars.containerModels) or {}) do
        if m.model == model then return m.opens ~= false end
    end
    return true
end

-- true when the model's open end is its back end (openEnd = 'back' in Config.ContainerWars.containerModels)
local function modelOpensAtBack(model)
    for _, m in ipairs((Config.ContainerWars and Config.ContainerWars.containerModels) or {}) do
        if m.model == model then return m.openEnd == 'back' end
    end
    return false
end

local function modelHasDoors(model)
    local d = doorCfg()
    return type(model) == 'string' and type(d.models) == 'table' and d.models[model] == true
end

-- Marks a freshly created container prop: which lot it is.
local function tagContainer(obj, rt, c, model)
    Entity(obj).state:set('container_wars_id', rt.id, true)
    Entity(obj).state:set('container_id', c.id, true)
    -- a model without doors of its own: every client fits the two door props and swings them open (container_wars_fx.lua)
    if modelHasDoors(model) then Entity(obj).state:set('cwDoors', true, true) end
end

-- ── Vehicle lots ────────────────────────────────────────────────────────────────
-- A lot whose reward is a car (and nothing else) stands in its container as a dummy crate while it is auctioned. The car is only
-- created once the winner is confirmed; the winner presses E at it to claim it (keys + garage record), or after
-- Config.ContainerWars.vehicleClaim.seconds the server puts it into the winner's garage itself (beginVehicleClaim, further down).
-- Returns the lot's car reward, or nil when the lot also holds cash / items (that lot keeps the open-the-container flow).
local function vehicleOnlyReward(c)
    local veh
    for _, r in ipairs(c.rewards or {}) do
        local t = string.upper(tostring(r.type or r.rewardType or ''))
        if t == 'VEHICLE' then
            if not veh and r.model and r.model ~= '' then veh = r end
        elseif (tonumber(r.amount or r.count) or 0) > 0 then
            return nil
        end
    end
    return veh
end

local function setDummyCrate(c, on)
    local ent = c and c.containerEntity
    if ent and DoesEntityExist(ent) then Entity(ent).state:set('cwDummyCrate', on and true or nil, true) end
end

-- A point in an entity's own frame, in world coordinates. GetOffsetFromEntityInWorldCoords is a CLIENT-only native: calling it here
-- was a script error that killed the auction thread, so the reward car never appeared (container stands flat, heading is enough).
local function entityOffset(ent, x, y, z)
    local pos, rad = GetEntityCoords(ent), math.rad(GetEntityHeading(ent))
    local s, c = math.sin(rad), math.cos(rad)
    return vector3(pos.x + x * c - y * s, pos.y + x * s + y * c, pos.z + z)
end

-- The real size of a cable model. The server cannot read model dimensions, so a client (the admin starting the
-- event) measures it once: { len = height of one piece, top = how far above its origin the piece reaches }.
-- Without it the rope assumed every piece was exactly hook.cableSegmentLength long with its origin at the bottom;
-- when it was not, the topmost pieces stuck out through the crane's cabin. Returns nil when nobody could measure
-- (the configured length is used then).
local cableDims = {}
local function measureCable(model, source)
    if cableDims[model] then return cableDims[model] end
    -- Started from the console, a ped or a schedule there is no admin to ask: any connected player can measure a model.
    local candidates = {}
    if source and source > 0 then candidates[#candidates + 1] = source end
    for _, p in ipairs(GetPlayers()) do
        local id = tonumber(p)
        if id and id ~= source then candidates[#candidates + 1] = id end
    end
    for n, target in ipairs(candidates) do
        local done, result = false, nil
        lib.callback('nova_convoytruck:cw:modelDims', target, function(r) result, done = r, true end, model)
        local waited = 0
        while not done and waited < 4000 do Wait(100) waited = waited + 100 end
        if type(result) == 'table' and tonumber(result.len) and result.len > 0.5 then
            cableDims[model] = { len = result.len, top = tonumber(result.top) or result.len }
            print(('[NovaConvoy][ContainerWars] cable "%s" measured: %.2f m long, reaches %.2f m above its origin'):format(model, result.len, cableDims[model].top))
            return cableDims[model]
        end
        if n >= 3 then break end   -- three tries is plenty
    end
    print(('[NovaConvoy][ContainerWars] could not measure cable "%s" — using hook.cableSegmentLength/cableTop from config; if the rope sticks out of the crane, set them (run /cwhooktest in game).'):format(model))
    return nil
end

-- Moves the whole gantry crane so its cabin is over (hx, hy): the frame rolls along its rails and the
-- cabin slides across it, wheels following the frame. Returns where the hook really is (the cabin's
-- position — different from the request only when the spot is beyond the crane's reach).
local function gantryApply(rt, hx, hy)
    local g = rt.gantry
    if not g then return hx, hy end
    local lay = CWGantry.layout(g.cfg, g.crane, hx, hy)
    if g.frame and DoesEntityExist(g.frame) then
        SetEntityCoords(g.frame, lay.frame.x, lay.frame.y, lay.frame.z, false, false, false, false)
    end
    if g.cabin and DoesEntityExist(g.cabin) then
        SetEntityCoords(g.cabin, lay.cabin.x, lay.cabin.y, lay.cabin.z, false, false, false, false)
        SetEntityHeading(g.cabin, lay.cabin.heading)
    end
    for i, w in ipairs(g.wheels) do
        local p = lay.wheels[i]
        if p and DoesEntityExist(w) then SetEntityCoords(w, p.x, p.y, p.z, false, false, false, false) end
    end
    if not lay.reachable and not g.warned then
        g.warned = true
        print(('[NovaConvoy][ContainerWars #%s] The gantry cannot reach %.1f, %.1f — it is beyond its rails / span (Config.ContainerWars.gantries), or its legs would hit a container stack on the way. It goes as far as it can.'):format(tostring(rt.id), hx, hy))
    end
    return lay.hook.x, lay.hook.y
end

-- The player who currently holds the top bid. Server ids are recycled after a
-- disconnect, so the stored source only counts while it is still the same
-- character; otherwise they are looked up again (they may have reconnected).
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

-- Online players belonging to a gang (police never take part in Container Wars).
local function winningGangSources(gangName)
    local out = {}
    if not gangName then return out end
    for _, src in ipairs(Bridge.GetPlayers()) do
        if not Bridge.IsPolice(src) then
            local g = GangService and GangService.GetPlayerGang(src)
            if g and g.name == gangName then out[#out + 1] = src end
        end
    end
    return out
end

local settleContainer   -- defined below, with the claim code: delivers whatever a winner did not collect
local settleRewardVehicle   -- defined below: puts an unclaimed reward car into the winning bidder's garage when the event is cleaned up
local beginVehicleClaim, settleVehicleClaim   -- defined below: the claim window of a car-only lot

local function cleanupEntities(rt)
    if not rt then return end
    if rt.craneEntity and DoesEntityExist(rt.craneEntity) then
        DeleteEntity(rt.craneEntity)
    end
    rt.craneEntity = nil
    for _, e in ipairs(rt.gantryEntities or {}) do
        if DoesEntityExist(e) then DeleteEntity(e) end
    end
    rt.gantryEntities = nil
    rt.gantry = nil
    rt.gantries = nil
    TriggerClientEvent('nova_convoytruck:containerWars:client:craneAudioState', -1, { state = 'FINISHED' })
    if rt.dummiesHeld then
        rt.dummiesHeld = false
        HarbourStore.holdDummies(rt.id, false)
    end
    for _, part in ipairs(rt.hookParts or {}) do
        for _, e in ipairs(part.entities or {}) do
            if DoesEntityExist(e) then DeleteEntity(e) end
        end
    end
    rt.hookParts = nil
    for _, c in ipairs(rt.containers or {}) do
        -- the last chance for a winner to get what they paid for: leftovers are delivered before the container goes
        if settleContainer then pcall(settleContainer, rt, c, 'event ended') end
        if settleRewardVehicle then pcall(settleRewardVehicle, rt, c) end
        if c.containerEntity and DoesEntityExist(c.containerEntity) then
            DeleteEntity(c.containerEntity)
            c.containerEntity = nil
        end
    end
    TriggerClientEvent('nova_convoytruck:containerWars:client:craneClear', -1, { convoyId = rt.id })

    -- A lot / crane / gantry thread that was mid-spawn when the event ended stores its entity on rt AFTER the pass
    -- above has run; sweep the same fields again a few times so nothing is left standing in the yard.
    CreateThread(function()
        for _, delay in ipairs({ 2500, 8000, 30000 }) do
            Wait(delay)
            local function del(e) if e and DoesEntityExist(e) then DeleteEntity(e) end end
            del(rt.craneEntity); rt.craneEntity = nil
            for _, e in ipairs(rt.gantryEntities or {}) do del(e) end
            rt.gantryEntities = nil
            for _, part in ipairs(rt.hookParts or {}) do
                for _, e in ipairs(part.entities or {}) do del(e) end
            end
            rt.hookParts = nil
            for _, c in ipairs(rt.containers or {}) do
                del(c.containerEntity); c.containerEntity = nil
            end
        end
    end)
end

-- Which gang holds the most won containers right now.
local function topGangOf(rt)
    local wins, best, top = {}, 0, nil
    for _, c in ipairs(rt.containers or {}) do
        if c.highestBidderGangName and (c.status == 'WON' or c.status == 'CLAIMED') then
            wins[c.highestBidderGangName] = (wins[c.highestBidderGangName] or 0) + 1
            if wins[c.highestBidderGangName] > best then
                best = wins[c.highestBidderGangName]
                top = c.highestBidderGangName
            end
        end
    end
    return top, best
end

-- Full after-action record for Event History / the PDF / Discord (shape and
-- wording live in report_builder.lua).
local function buildReport(rt, outcome, forcedByName)
    local top = topGangOf(rt)
    local containers = {}
    for i, c in ipairs(rt.containers or {}) do
        containers[i] = {
            id = c.id,
            containerIndex = c.containerIndex or i,
            name = c.name,
            model = c.model,
            finalBid = c.currentBid or 0,
            winningGang = c.highestBidderGang or (c.isCivilian and 'Civilian' or nil),
            winningGangName = c.highestBidderGangName or (c.isCivilian and 'civilian' or nil),
            winningPlayer = c.highestBidderName,
            winningPlayerIdentifier = c.highestBidder,
            status = c.status,
            claimed = c.status == 'CLAIMED',
            isCivilian = c.isCivilian == true,
            round = c.round,
            spotIndex = c.spotIndex,
            startingBid = c.startingBid or 5000,
            bidCount = c.bidCount or 0,
            unsoldReason = c.unsoldReason,
            claimedByName = c.claimedByName,
            rewardsText = RewardService.describeRewards(c.rewards),
        }
    end
    local topLabel = top and rt.gangStats and rt.gangStats[top] and rt.gangStats[top].label or top
    local report = ReportBuilder.containerWars({
        id = rt.id, name = rt.def.name, startedAt = rt.startedAt, endedAt = os.time(), outcome = outcome,
        startedByName = rt.startedByName, forcedByName = forcedByName,
        topGang = top, topGangLabel = topLabel,
        containers = containers, gangStats = rt.gangStats or {},
        rewards = RewardService.describeRewards(rt.def.reward),
        totalRounds = rt.totalRounds,
        timeline = DiscordLog.getTimeline(rt.id),
    })
    -- winners can still open their containers for a while after the auction closes: those payouts get their own Discord posts
    return ReportBuilder.addPayoutTable(report, rt.id, ' (CLAIMED WHEN THE AUCTION CLOSED)')
end

-- Writes the history row and posts the final Discord message (+ PDF).
local function recordEnd(rt, outcome, forcedByName)
    local report = buildReport(rt, outcome, forcedByName)
    local top, topWins = topGangOf(rt)
    local sold = report.fleet.delivered
    DB.insertConvoyHistory({
        convoyDefinitionId = rt.id,
        name = rt.def.name,
        createdBy = rt.def.createdByName or 'System',
        startedAt = rt.startedAt or os.time(),
        endedAt = os.time(),
        duration = os.time() - (rt.startedAt or os.time()),
        truckCount = rt.totalContainers or 0,
        policeParticipants = 0,
        gangParticipants = report.roster.gangCount,
        winningGang = top,
        outcome = outcome,
        rewardSummary = top and ('%s (Won %d containers)'):format(top, topWins) or 'Auction Concluded',
        destroyedTrucks = 0,
        checkpointsCompleted = rt.totalRounds or 1,
        kind = 'CONTAINER_WARS',
        reportData = report,
    })

    local fields = {
        { name = 'Event Tag', value = '[CONTAINER WARS] 🚢', inline = true },
        { name = 'Auction', value = rt.def.name, inline = true },
        { name = 'Outcome', value = outcome, inline = true },
        { name = 'Top Bidder', value = report.winner, inline = true },
        { name = 'Lots Sold', value = ('%d / %d'):format(sold, #(report.interceptions or {})), inline = true },
        { name = 'Bidding Gangs', value = tostring(report.roster.gangCount), inline = true },
        { name = 'Duration', value = report.durationText, inline = true },
        { name = 'Rewards', value = tostring(report.rewards or 'None'), inline = false },
    }
    for _, sc in ipairs(report.gangScorecard or {}) do
        if #fields < 20 then
            fields[#fields + 1] = { name = sc.label, value = ('%s lots won | %s spent | %s bids'):format(sc.cells[1], sc.cells[2], sc.cells[3]), inline = false }
        end
    end
    if report.labels and report.labels.card4 then
        table.insert(fields, 7, { name = 'Auction Total', value = ('%s — %s'):format(report.labels.card4.main or '-', report.labels.card4.sub or ''), inline = true })
    end
    for _, f in ipairs(ReportBuilder.payoutFields(rt.id)) do fields[#fields + 1] = f end
    if forcedByName then fields[#fields + 1] = { name = 'Force-Ended By', value = forcedByName, inline = true } end

    local pdfString = nil
    if Config.DiscordLogs and Config.DiscordLogs.generatePdf ~= false and PdfGenerator then
        pdfString = PdfGenerator.generateConvoyReport(report)
    end
    if pdfString then
        fields[#fields + 1] = { name = '📄 After-Action Report (PDF)', value = 'Full auction report generated and attached to this message.', inline = false }
    end
    local color = outcome == 'COMPLETED' and 0x38bdf8 or (outcome == 'CANCELLED' and 0x6b7280 or 0xef4444)
    DiscordLog.finishEvent(rt.id, ('🚢 [CONTAINER WARS] %s — %s'):format(outcome == 'CANCELLED' and 'Cancelled' or 'Concluded', rt.def.name),
        color, fields, ('🏆 %s | %s'):format(report.winner, report.durationText), pdfString, 'CONTAINER_WARS')
end

function ContainerWars.forceEnd(source, convoyId)
    local rt = active[convoyId]
    if not rt then return false, 'Event is not active.' end
    log(convoyId, 'Force ended by admin')
    DiscordLog.appendEvent(convoyId, '🛑 Auction force-ended by an administrator')
    recordEnd(rt, 'CANCELLED', source and source > 0 and Bridge.GetPlayerName(source) or nil)
    cleanupEntities(rt)
    active[convoyId] = nil
    ConvoyManager.setStatus(convoyId, 'CANCELLED')
    TriggerClientEvent('nova_convoytruck:containerWars:client:eventEnded', -1, convoyId)
    local b = {
        title = 'CONTAINER WARS CANCELLED',
        body = ('"%s" was cancelled by an administrator.'):format(rt.def.name),
        duration = 7000,
        kind = 'danger'
    }
    cwAnnounce(b.title, b.body, b.duration, 'CANCELLED')
    return true
end

function ContainerWars.finish(convoyId, outcome)
    local rt = active[convoyId]
    if not rt then return end
    outcome = outcome or 'COMPLETED'
    log(convoyId, 'Finished with outcome: ' .. outcome)

    -- Top gang = most containers actually won (paid for), same rule the report uses
    local topGang, maxWins = topGangOf(rt)

    -- Leaderboard: every gang that bid joined the event; the one holding the
    -- most containers won it, the rest bid but came away with nothing to show.
    for bidderGang in pairs(rt.bidderGangs or {}) do
        if bidderGang ~= 'civilian' then
            GangService.RecordOutcome(bidderGang, 'joined', 'CONTAINER_WARS')
            GangService.RecordOutcome(bidderGang, bidderGang == topGang and 'completed' or 'failed', 'CONTAINER_WARS')
        end
    end

    -- Civilian leaderboard: record participation for registered civilians
    if rt.participants and rt.participants.civilians and CivilianService and CivilianService.RecordResult then
        for civIdent in pairs(rt.participants.civilians) do
            local alreadyWon = false
            for _, c in ipairs(rt.containers or {}) do
                if (c.status == 'WON' or c.status == 'CLAIMED') and c.highestBidder == civIdent then
                    alreadyWon = true
                    break
                end
            end
            if not alreadyWon then
                CivilianService.RecordResult(civIdent, 'Civilian', 'container_wars', rt.def.name, {
                    wins = 0,
                    points = 5,
                    totalRewards = 0,
                    participations = 1,
                })
            end
        end
    end

    DiscordLog.appendEvent(convoyId, topGang and ('🏁 Auction concluded — top gang %s with %d container%s'):format(topGang, maxWins, maxWins == 1 and '' or 's') or '🏁 Auction concluded — no containers were sold')
    recordEnd(rt, outcome)

    ConvoyManager.setStatus(convoyId, outcome)
    TriggerClientEvent('nova_convoytruck:containerWars:client:eventEnded', -1, convoyId)

    local endMsg = topGang and ('The container wars auction has concluded! Top Gang: %s (%d containers won).'):format(topGang, maxWins)
        or 'The container wars auction has concluded.'
    cwAnnounce('CONTAINER WARS CONCLUDED', endMsg, 9000, 'CLOSED')

    CreateThread(function()
        Wait(60000) -- Keep props visible for 60s post-event for atmosphere
        cleanupEntities(rt)
        active[convoyId] = nil
    end)
end

-- ── Safe Staging Area Helpers ──────────────────────────────────────────────────
local function getVehicleSafeCoords(rt, c)
    if c and c.vehicleSafeCoords and tonumber(c.vehicleSafeCoords.x) and tonumber(c.vehicleSafeCoords.y) then
        return {
            x = tonumber(c.vehicleSafeCoords.x),
            y = tonumber(c.vehicleSafeCoords.y),
            z = tonumber(c.vehicleSafeCoords.z) or 5.9,
            heading = tonumber(c.vehicleSafeCoords.heading) or 90.0,
        }
    end
    local cw = (rt and rt.def and rt.def.containerWars) or (rt and rt.def and rt.def.settings and rt.def.settings.containerWars) or {}
    if cw.vehicleSafeCoords and tonumber(cw.vehicleSafeCoords.x) and tonumber(cw.vehicleSafeCoords.y) then
        return {
            x = tonumber(cw.vehicleSafeCoords.x),
            y = tonumber(cw.vehicleSafeCoords.y),
            z = tonumber(cw.vehicleSafeCoords.z) or 5.9,
            heading = tonumber(cw.vehicleSafeCoords.heading) or 90.0,
        }
    end
    local cfg = Config.ContainerWars or {}
    local st = cfg.vehicleSafeCoords or cfg.stagingCoords or { x = 794.5, y = -3000.2, z = 5.9, heading = 90.0 }
    return {
        x = tonumber(st.x) or 794.5,
        y = tonumber(st.y) or -3000.2,
        z = tonumber(st.z) or 5.9,
        heading = tonumber(st.heading) or 90.0,
    }
end

local function findSafeStagingCoords(rt, excludePed, c)
    local base = getVehicleSafeCoords(rt, c)
    local isBlocked = false
    for _, pid in ipairs(allPlayers()) do
        local p = tonumber(pid)
        if p and p > 0 then
            local ped = GetPlayerPed(p)
            if ped and ped ~= 0 and ped ~= excludePed and DoesEntityExist(ped) then
                local pos = GetEntityCoords(ped)
                if #(vector3(base.x, base.y, base.z) - pos) < 3.2 then
                    isBlocked = true
                    break
                end
            end
        end
    end

    if not isBlocked then
        return base
    end

    -- If players are standing directly at base coords, try adjacent parking bay offsets
    local rad = math.rad((base.heading or 0.0) + 90.0)
    for _, offsetDist in ipairs({ 3.5, -3.5, 7.0, -7.0, 10.5 }) do
        local ox = base.x + math.cos(rad) * offsetDist
        local oy = base.y + math.sin(rad) * offsetDist
        local blockedOffset = false
        for _, pid in ipairs(allPlayers()) do
            local p = tonumber(pid)
            if p and p > 0 then
                local ped = GetPlayerPed(p)
                if ped and ped ~= 0 and ped ~= excludePed and DoesEntityExist(ped) then
                    local pos = GetEntityCoords(ped)
                    if #(vector3(ox, oy, base.z) - pos) < 3.0 then
                        blockedOffset = true
                        break
                    end
                end
            end
        end
        if not blockedOffset then
            return { x = ox, y = oy, z = base.z, heading = base.heading }
        end
    end

    return base
end

-- An unclaimed reward car stands at the staging spot: the winning bidder (and, for a gang win, the gang) gets a flashing blip on the map
-- and a notice, until the car is claimed (claimVehicle clears it) or the event ends.
local function announceRewardVehicle(c, at)
    local winners = {}
    if c.highestBidderSource then winners[tonumber(c.highestBidderSource)] = true end
    if c.highestBidderGangName and c.highestBidderGangName ~= 'civilian' and GangService then
        for _, pid in ipairs(allPlayers()) do
            local p = tonumber(pid)
            local g = p and GangService.GetPlayerGang(p)
            if g and g.name == c.highestBidderGangName then winners[p] = true end
        end
    end
    for p in pairs(winners) do
        TriggerClientEvent('nova_convoytruck:containerWars:client:rewardVehicleBlip', p, { containerId = c.id, x = at.x, y = at.y, z = at.z, name = c.name })
        TriggerClientEvent('nova_convoytruck:client:hudNotify', p, {
            type = 'info', title = 'REWARD VEHICLE READY', duration = 10000,
            description = ('Your %s reward car is waiting at the staging area (flashing blip). Use the target on it to claim it.'):format(c.name or 'container'),
        })
    end
end

-- ── Round & Auction Lifecycle ──────────────────────────────────────────────────

local function runContainerWarsLifecycle(rt)
    CreateThread(function()
        local cw = rt.def.containerWars or {}
        local containersPerRound = math.max(1, math.min(10, cw.containersPerRound or 4))
        local totalContainers = #rt.containers
        local totalRounds = math.max(1, math.ceil(totalContainers / containersPerRound))
        rt.totalRounds = totalRounds
        -- The last container is announced as the FINAL ROUND, with a longer break before it. (With a single
        -- container there is nothing to build up to, so it stays an ordinary round.)
        local cwDefaults = (Config.ContainerWars and Config.ContainerWars.defaults) or {}
        local finalEnabled = cw.finalRoundEnabled ~= false and totalRounds > 1
        local finalBreak = tonumber(cw.finalRoundBreakSeconds) or tonumber(cwDefaults.finalRoundBreakSeconds) or 30
        local finalAuction = tonumber(cw.finalRoundAuctionSeconds) or tonumber(cwDefaults.finalRoundAuctionSeconds) or 0

        log(rt.id, ('Starting lifecycle: %d containers, %d per round, %d total rounds'):format(totalContainers, containersPerRound, totalRounds))

        for round = 1, totalRounds do
            if not active[rt.id] then break end
            rt.currentRound = round
            local isFinal = finalEnabled and round == totalRounds
            rt.isFinalRound = isFinal

            -- Same-spot drops: the previous round's container is cleared (its claim window has ended)
            if (cw.layout and cw.layout.mode == 'STACK' and cw.layout.dropMode == 'SAME_SPOT') and round > 1 then
                for _, prev in ipairs(rt.containers) do
                    if prev.containerEntity and DoesEntityExist(prev.containerEntity) and (prev.status == 'WON' or prev.status == 'UNSOLD' or prev.status == 'CLAIMED') then
                        -- the pad is needed again: a winner who never opened it / emptied its crate gets it delivered now
                        pcall(settleContainer, rt, prev, 'next round')
                        if prev.vehClaim then pcall(settleVehicleClaim, rt, prev, 'the next round started') end
                        DeleteEntity(prev.containerEntity)
                        prev.containerEntity = nil
                        prev.atPad = nil
                    end
                end
            end

            local startIdx = (round - 1) * containersPerRound + 1
            local endIdx = math.min(totalContainers, round * containersPerRound)
            local batchContainers = {}
            for i = startIdx, endIdx do
                local c = rt.containers[i]
                c.containerIndex = i
                batchContainers[#batchContainers + 1] = c
            end

            log(rt.id, ('Round %d/%d: Staging %d containers (index %d to %d)'):format(round, totalRounds, #batchContainers, startIdx, endIdx))

            DiscordLog.appendEvent(rt.id, isFinal
                and ('🏁 FINAL ROUND — %d container%s staged for the last auction'):format(#batchContainers, #batchContainers == 1 and '' or 's')
                or ('🚢 Round %d/%d — %d container%s staged for auction'):format(round, totalRounds, #batchContainers, #batchContainers == 1 and '' or 's'))
            -- Announce round start
            -- Each round can carry its own banner (cw.rounds[round] = { title, message }, written in the tablet next to the
            -- round's lots); {round} {rounds} {lots} {names} are filled in. Anything left empty uses the default text.
            local several = #batchContainers > 1
            local roundTitle = isFinal and 'CONTAINER WARS — FINAL ROUND' or ('CONTAINER WARS — ROUND %d / %d'):format(round, totalRounds)
            local roundDesc = isFinal
                and (several and 'The last containers come in one at a time, each auctioned before the next is dropped. This is the final round — everything is on the line.'
                    or 'The last container is being delivered. This is the final auction — everything is on the line.')
                or (several and 'The harbour crane brings the containers in one at a time; each is auctioned before the next one is dropped.' or 'The harbour crane is bringing in the container...')
            local custom = type(cw.rounds) == 'table' and (cw.rounds[round] or cw.rounds[tostring(round)]) or nil
            if type(custom) == 'table' then
                local lotNames = {}
                for _, c in ipairs(batchContainers) do lotNames[#lotNames + 1] = tostring(c.name or ('Container #' .. tostring(c.containerIndex))) end
                local function fill(s)
                    s = tostring(s)
                    s = s:gsub('{round}', function() return tostring(round) end)
                    s = s:gsub('{rounds}', function() return tostring(totalRounds) end)
                    s = s:gsub('{lots}', function() return tostring(#batchContainers) end)
                    s = s:gsub('{names}', function() return table.concat(lotNames, ', ') end)
                    return s
                end
                if type(custom.title) == 'string' and custom.title:match('%S') then roundTitle = fill(custom.title) end
                if type(custom.message) == 'string' and custom.message:match('%S') then roundDesc = fill(custom.message) end
            end
            -- a longer story stays up long enough to be read
            local roundShow = (isFinal and 9000 or 7000) + math.max(0, #roundDesc - 90) * 45
            local statusBadge = isFinal and 'FINAL ROUND' or ('ROUND %d / %d'):format(round, totalRounds)
            cwAnnounce(roundTitle, roundDesc, math.min(roundShow, 9000), statusBadge)

            -- ONE CONTAINER AT A TIME. stageContainer(c) brings a container to its drop spot with the crane,
            -- auctionContainer(c) runs its whole auction; the loop at the bottom of the round calls them in turn, so the
            -- crane never touches the next container until the previous one has been decided.
            local smoothCrane = (Config.ContainerWars and Config.ContainerWars.defaults and Config.ContainerWars.defaults.smoothCrane) ~= false
            -- the container that comes after the one being auctioned, and the extra pause before it when it starts a new round
            -- (the zone timer counts down to its drop)
            local upcoming, upcomingExtra = nil, 0.0

            local function stageContainer(c)
                if not active[rt.id] then return end
                c.status = 'CRANE_STAGING'
                c.round = round

                -- Broadcast crane move event to clients for visual synchronisation
                TriggerClientEvent('nova_convoytruck:containerWars:client:craneMove', -1, {
                    convoyId = rt.id,
                    containerId = c.id,
                    containerIndex = c.containerIndex,
                    round = round, totalRounds = totalRounds, isFinal = isFinal,
                    name = c.name,
                    model = c.model,
                    pickupCoords = c.pickupCoords,
                    dropCoords = c.dropCoords,
                    craneCoords = cw.crane,
                })

                -- Server-side entity spawn / placement with safety watchdog
                local H = (Config.ContainerWars and Config.ContainerWars.harbour) or {}
                -- the lot's SPOT (not its lot number: lots of later rounds reuse the spots of the yard)
                local spot = c.spotIndex or c.containerIndex
                local pick = c.pickupCoords or (H.pickups and H.pickups[spot])
                local targetDropIdx = (pick and tonumber(pick.assignedDrop)) or spot
                local drop = (H.drops and H.drops[targetDropIdx]) or c.dropCoords or (H.drops and H.drops[spot]) or H.drop or { x = 805.0, y = -2975.0, z = 6.0, heading = 0.0 }
                local modelHash = modelHashOf(c.model)

                -- Ensure drop pad is clear of any previous containers or vehicles before this container drops
                for _, prev in ipairs(rt.containers or {}) do
                    if prev ~= c and prev.containerEntity and DoesEntityExist(prev.containerEntity) then
                        local prevPos = GetEntityCoords(prev.containerEntity)
                        if #(prevPos - vector3(drop.x, drop.y, drop.z)) < 4.5 then
                            pcall(settleContainer, rt, prev, 'clearing drop pad')
                            DeleteEntity(prev.containerEntity)
                            prev.containerEntity = nil
                            prev.atPad = nil
                        end
                    end
                    if prev.rewardVehicleEntity and DoesEntityExist(prev.rewardVehicleEntity) then
                        local vPos = GetEntityCoords(prev.rewardVehicleEntity)
                        if #(vPos - vector3(drop.x, drop.y, drop.z)) < 6.0 then
                            local safeCoords = findSafeStagingCoords(rt, nil, prev)
                            SetEntityCoords(prev.rewardVehicleEntity, safeCoords.x + 0.0, safeCoords.y + 0.0, safeCoords.z + 0.0, false, false, false, true)
                            SetEntityHeading(prev.rewardVehicleEntity, (safeCoords.heading or 90.0) + 0.0)
                            FreezeEntityPosition(prev.rewardVehicleEntity, true)
                        end
                    end
                end

                -- The container starts at its crane pickup point (or hangs 14 m above
                -- the drop if none was set) and is lowered to the drop point.
                pick = pick or { x = drop.x, y = drop.y, z = drop.z + (tonumber(cw.craneLiftHeight) or 14.0), heading = drop.heading or 0.0 }
                local containerObj = c.containerEntity
                c.bodyModel = c.bodyModel or containerBodyModel(c.model)
                if not (containerObj and DoesEntityExist(containerObj)) then
                    containerObj = spawnProp(c.bodyModel, pick.x, pick.y, pick.z, pick.heading)
                    if not containerObj then
                        log(rt.id, ('Container #%d (%s): could not create model "%s" at %.1f, %.1f, %.1f — nothing will be visible for it.'):format(c.containerIndex or 0, c.name or '?', tostring(c.model), pick.x, pick.y, pick.z))
                    end
                end
                if containerObj and DoesEntityExist(containerObj) then
                    SetEntityHeading(containerObj, pick.heading or 0.0)
                    FreezeEntityPosition(containerObj, true)
                    tagContainer(containerObj, rt, c, c.bodyModel)
                    c.containerEntity = containerObj
                end

                -- Crane transport: smooth in/out travel over Config.ContainerWars.craneStagingTimeSeconds
                local cwDef = (Config.ContainerWars and Config.ContainerWars.defaults) or {}
                local speedMul = math.max(0.25, math.min(4.0, tonumber(cwDef.craneSpeedMultiplier) or 1.0))
                local travelSeconds = (tonumber(cw.craneTravelSeconds) or tonumber(cwDef.craneTravelSeconds) or 8) / speedMul
                -- Hoist straight up, carry across at that height, lower onto the drop:
                -- 30% / 40% / 30% of the travel time, each eased in and out.
                local steps = math.max(3, math.floor(travelSeconds * 10))
                local liftSteps = math.max(1, math.floor(steps * 0.3))
                local carrySteps = math.max(1, math.floor(steps * 0.4))
                local lowerSteps = math.max(1, steps - liftSteps - carrySteps)
                -- The empty hook: down onto the container before the lift, and back up after it is set down. Set in the
                -- tablet (seconds, then sped up / slowed with the rest of the crane); a return of 0 = the pace of the lowering.
                local function hookMs(key, default)
                    local s = tonumber(cw[key])
                    if s == nil then s = tonumber(cwDef[key]) end
                    if s == nil then s = default end
                    if s <= 0 then return nil end
                    return math.max(200, math.floor(s / speedMul * 1000))
                end
                local descendMs = hookMs('hookDescendSeconds', 0.5) or 500
                local returnMs = hookMs('hookReturnSeconds', 0) or (lowerSteps * 100)
                local descendSteps = math.max(2, math.floor(descendMs / 60))
                local returnSteps = math.max(2, math.floor(returnMs / 100))
                -- The crane that carries this one: whichever reaches both its spot and its drop (each aisle of the yard
                -- has its own). The hook starts again on the new crane rather than gliding across from the old one.
                if rt.gantries and next(rt.gantries) and rt.craneDefs then
                    local ci, reach = CWGantry.craneFor(rt.craneDefs, pick, drop)
                    local chosen = ci and rt.gantries[ci] or nil
                    if chosen and chosen ~= rt.gantry then
                        rt.gantry = chosen
                        rt.hookAt = nil
                        for _, part in ipairs(rt.hookParts or {}) do
                            if part.segLen then part.armTop = chosen.armTop end
                        end
                        if rt.ropeHolder and DoesEntityExist(rt.ropeHolder) then
                            Entity(rt.ropeHolder).state:set('cwRope', { armTop = chosen.armTop }, true)
                        end
                        log(rt.id, ('Container #%d is carried by crane #%d.'):format(c.containerIndex or 0, ci))
                    end
                    if not reach then
                        log(rt.id, ('Container #%d: no crane can reach both its spot and its drop — add a crane near it (Container Wars setup → Gantry cranes).'):format(c.containerIndex or 0))
                    end
                end
                local apexZ = math.max(pick.z, drop.z) + (tonumber(cw.craneLiftHeight) or 14.0)
                if rt.gantry then
                    -- never lift higher than the cabin lets the spreader go (the pickup may be up on a ship's deck)
                    local g = rt.gantry
                    local ceiling = g.crane.z + ((g.cfg.cabin and g.cfg.cabin.z) or 18.0) + (tonumber(g.cfg.cableTopOffset) or -1.0) - (tonumber(g.cfg.hookClearance) or 5.0)
                    apexZ = math.max(math.max(pick.z, drop.z) + 0.5, math.min(apexZ, ceiling))
                end
                local h0, h1 = pick.heading or 0.0, drop.heading or 0.0
                -- The carry: a route planned in the tablet from the real yard when there is one, else a path planned
                -- from the config (see CWGantry.chooseCarry). It leaves the way the container is facing, bends like a
                -- car and arrives along the drop heading.
                local carrySize = cwDef.containerSize or { length = 12.2, width = 2.6, height = 2.7 }
                -- The crane's legs sweep fixed lanes whatever the hook does, so it may only roll as far as those
                -- lanes stay clear of the other containers and the dummy stacks (the hook then stops there rather
                -- than the crane driving through them).
                if rt.gantry then
                    -- what actually stands in the yard right now: containers of earlier rounds are gone, later rounds' not yet
                    -- there, so only the ones with a live entity count — set down on a pad (atPad) or still waiting at a pickup
                    local standing = {}
                    for _, o in ipairs(rt.containers) do
                        if o ~= c and o.containerEntity and DoesEntityExist(o.containerEntity) then
                            o.atDrop = o.atPad == true
                            standing[#standing + 1] = o
                        end
                    end
                    local obstacles = CWGantry.carryObstacles((Config.ContainerWars or {}).harbour, standing, c, carrySize)
                    -- the other cranes stand in the yard too: this one must not roll into their legs
                    for _, o in ipairs(CWGantry.craneObstacles(rt.craneDefs, rt.gantry.index)) do obstacles[#obstacles + 1] = o end
                    local lo, hi = CWGantry.railLimits(rt.gantry.cfg, rt.gantry.crane, obstacles)
                    rt.gantry.crane.railMin, rt.gantry.crane.railMax = lo, hi
                end
                local carryAt, carryInfo = CWGantry.chooseCarry({
                    harbour = (Config.ContainerWars or {}).harbour, index = spot,
                    pick = { x = pick.x, y = pick.y, h = h0 }, drop = { x = drop.x, y = drop.y, h = h1 },
                    z = apexZ, mode = tostring(cw.carryPath or cwDef.carryPath or 'CURVE'):upper(),
                    tension = tonumber(cw.carryCurve) or tonumber(cwDef.carryCurve) or 0.4,
                    containers = rt.containers, current = c, size = carrySize,
                    gantry = rt.gantry and rt.gantry.cfg, crane = rt.gantry and rt.gantry.crane,
                })
                if carryInfo and not carryInfo.planned and (carryInfo.violations or 0) > 0 then
                    log(rt.id, ('Container #%d: its carry path may touch something in the yard — use "Plan route" for this container in the tablet.'):format(c.containerIndex or 0))
                end
                local function ease(t) return t * t * (3.0 - 2.0 * t) end
                -- the grabber + cable: every part keeps its own offset from the container
                local function moveHook(x, y, z, heading)
                    rt.hookAt = { x = x, y = y, z = z }
                    local hx, hy = gantryApply(rt, x, y)   -- the crane rolls / the cabin slides, then the rope hangs from it
                    for _, part in ipairs(rt.hookParts or {}) do
                        local baseZ = z + part.z
                        -- a stretched cable: whole pieces stacked upward from the hook, the last one tucked up against the
                        -- cabin so the rope reaches it. Props cannot be scaled, so the pieces that do not fit are hidden:
                        -- with the hook raised right up to the cabin no rope is left hanging.
                        local fit, rest, gap = nil, 0.0, 0.0
                        if part.segLen and part.armTop then
                            gap = part.armTop - baseZ
                            fit = math.max(0, math.floor(gap / part.segLen + 0.001))
                            rest = gap - fit * part.segLen
                        end
                        for k, e in ipairs(part.entities) do
                            if DoesEntityExist(e) then
                                local zk, hide = baseZ, false
                                if part.segLen then
                                    local bottomOff = (part.top or part.segLen) - part.segLen   -- lowest point of a piece, relative to its origin
                                    if fit then
                                        if k <= fit then
                                            zk = baseZ + (k - 1) * part.segLen - bottomOff
                                        elseif k == fit + 1 and ((fit >= 1 and rest > 0.3) or (fit == 0 and part.segLen - gap <= (part.overlap or 0.0))) then
                                            -- ends at the cabin; overlaps the piece below, or (nothing below) its lower end
                                            -- sticks down into the spreader/container, where it cannot be seen
                                            zk = part.armTop - (part.top or part.segLen)
                                        else
                                            hide = true                                      -- not needed right now
                                            zk = part.armTop - (part.top or part.segLen)
                                        end
                                    else
                                        zk = baseZ + (k - 1) * part.segLen
                                    end
                                end
                                -- a hidden piece is moved to a routing bucket nobody is in (underground still drew as lines in the yard)
                                part.hidden = part.hidden or {}
                                if (part.hidden[k] == true) ~= hide then
                                    part.hidden[k] = hide
                                    SetEntityRoutingBucket(e, hide and 31999 or 0)
                                end
                                SetEntityCoords(e, hx + part.x, hy + part.y, zk, false, false, false, false)
                                if heading then SetEntityHeading(e, heading + part.heading) end
                            end
                        end
                    end
                    return hx, hy
                end
                -- The container always hangs from the hook, so when the planned path leaves what the crane can
                -- reach it stops where the hook stops (rope straight, nothing floating off to the side) instead of
                -- carrying on without it.
                local function place(x, y, z, heading)
                    local hx, hy = moveHook(x, y, z, heading)
                    if c.containerEntity and DoesEntityExist(c.containerEntity) then
                        SetEntityCoords(c.containerEntity, hx, hy, z, false, false, false, false)
                        SetEntityHeading(c.containerEntity, heading)
                    end
                end
                local audioPick = function() TriggerClientEvent('nova_convoytruck:containerWars:client:craneAudioState', -1, { state = 'PICKING_UP', coords = pick }) end
                local audioMove = function() TriggerClientEvent('nova_convoytruck:containerWars:client:craneAudioState', -1, { state = 'MOVING', coords = { x = pick.x, y = pick.y, z = apexZ } }) end
                local audioPlace = function() TriggerClientEvent('nova_convoytruck:containerWars:client:craneAudioState', -1, { state = 'PLACING', coords = drop }) end
                local audioImpact = function() TriggerClientEvent('nova_convoytruck:containerWars:client:craneAudioState', -1, { state = 'IMPACT', coords = drop }) end
                local from = rt.hookAt

                if smoothCrane then
                    -- ── Smooth crane ───────────────────────────────────────────────────────────────
                    -- The whole trip, as timed segments: glide over to the container, come down onto it, lift, carry, lower,
                    -- let go. It is sent ONCE; every client near the harbour plays it back on its own local copy of the
                    -- gantry / hook / carried container at full frame rate. The server only waits the same time (to start the
                    -- bidding on schedule) and puts the real container on its drop at the end: no per-step network traffic.
                    local segs = {}
                    local function addSeg(ms, ax, ay, az, bx, by, bz, ah, bh, carry)
                        local s = { ms = ms, ax = ax, ay = ay, az = az, bx = bx, by = by, bz = bz, ah = ah, bh = bh, carry = carry }
                        segs[#segs + 1] = s
                        return s
                    end
                    local fresh = from == nil
                    if from and (math.abs(from.x - pick.x) + math.abs(from.y - pick.y)) > 1.0 then
                        addSeg(math.max(8, math.floor(travelSeconds * 10 * 0.4)) * 100, from.x, from.y, from.z, pick.x, pick.y, apexZ, h0, h0, false)
                    end
                    local iDown = #segs + 1
                    addSeg(descendMs, pick.x, pick.y, apexZ, pick.x, pick.y, pick.z, h0, h0, false)
                    local iLift = #segs + 1
                    addSeg(liftSteps * 100, pick.x, pick.y, pick.z, pick.x, pick.y, apexZ, h0, h0, true)
                    -- the carry path, sampled: the clients follow it with the same easing the server used to apply
                    local px, py, ph, prevH = {}, {}, {}, nil
                    local SAMPLES = 48
                    for i = 0, SAMPLES do
                        local x, y, hd = carryAt(i / SAMPLES)
                        hd = hd or h0
                        if prevH then hd = prevH + (((hd - prevH + 180.0) % 360.0) - 180.0) end
                        prevH = hd
                        px[#px + 1], py[#py + 1], ph[#ph + 1] = x, y, hd
                    end
                    local iCarry = #segs + 1
                    local carrySeg = addSeg(carrySteps * 100, px[1], py[1], apexZ, px[#px], py[#py], apexZ, ph[1], ph[#ph], true)
                    carrySeg.px, carrySeg.py, carrySeg.ph = px, py, ph
                    local endH = ph[#ph] + (((h1 - ph[#ph] + 180.0) % 360.0) - 180.0)   -- turn the short way onto the drop's heading
                    local iLower = #segs + 1
                    addSeg(lowerSteps * 100, px[#px], py[#py], apexZ, drop.x, drop.y, drop.z, ph[#ph], endH, true)
                    local iRelease = #segs + 1
                    -- the empty hook climbs back up (Hook Return in the tablet; by default the pace it came down with the container)
                    addSeg(returnMs, drop.x, drop.y, drop.z, drop.x, drop.y, apexZ, endH, endH, false)

                    local hasCrane = rt.gantry ~= nil
                    local ent = c.containerEntity
                    TriggerClientEvent('nova_convoytruck:containerWars:client:craneMotion', -1, {
                        convoyId = rt.id, containerId = c.id, model = c.bodyModel or c.model,
                        netId = (ent and DoesEntityExist(ent)) and NetworkGetNetworkIdFromEntity(ent) or nil,
                        crane = hasCrane and rt.gantry.index or nil,
                        rail = hasCrane and { lo = rt.gantry.crane.railMin, hi = rt.gantry.crane.railMax } or nil,
                        fresh = fresh,
                        pick = { x = pick.x, y = pick.y, z = pick.z, h = h0 },
                        drop = { x = drop.x, y = drop.y, z = drop.z, h = drop.heading or h1 },
                        segs = segs,
                    })

                    local function runSeg(i)
                        local s = segs[i]
                        if not s then return end
                        Wait(s.ms)
                        rt.hookAt = { x = s.bx, y = s.by, z = s.bz }
                    end
                    for i = 1, iDown - 1 do if active[rt.id] then runSeg(i) end end        -- glide over
                    audioPick()
                    if active[rt.id] then runSeg(iDown) end                                  -- come down onto it
                    -- from the lift on the real container is hidden on every client (its local copy rides the hook)
                    if ent and DoesEntityExist(ent) then
                        Entity(ent).state:set('cwCarry', { drop = { x = drop.x, y = drop.y, z = drop.z } }, true)
                    end
                    if active[rt.id] then runSeg(iLift) end
                    audioMove()
                    if active[rt.id] then runSeg(iCarry) end
                    audioPlace()
                    if active[rt.id] then runSeg(iLower) end

                    c.atPad = true   -- it now stands on its drop pad (the next lots' carry paths keep clear of it there)
                    -- the real container goes onto its pad, exactly, and every client swaps its local copy for it
                    if c.containerEntity and DoesEntityExist(c.containerEntity) then
                        SetEntityCoords(c.containerEntity, drop.x, drop.y, drop.z, false, false, false, true)
                        SetEntityHeading(c.containerEntity, drop.heading or 0.0)
                        FreezeEntityPosition(c.containerEntity, true)
                        Entity(c.containerEntity).state:set('cwCarry', nil, true)
                    end
                    audioImpact()
                    if active[rt.id] then runSeg(iRelease) end
                else
                    -- ── Old way: the server moves the networked props itself, ten times a second ──────────────────
                    -- the hook travels over to this container (from the previous drop, or from its start spot)...
                    if from and (math.abs(from.x - pick.x) + math.abs(from.y - pick.y)) > 1.0 then
                        local glide = math.max(8, math.floor(travelSeconds * 10 * 0.4))
                        for step = 1, glide do
                            if not active[rt.id] then break end
                            Wait(100)
                            local e = ease(step / glide)
                            moveHook(from.x + (pick.x - from.x) * e, from.y + (pick.y - from.y) * e, from.z + (apexZ - from.z) * e, h0)
                        end
                    end
                    -- ...and comes down onto it before the lift
                    audioPick()
                    for step = 1, descendSteps do
                        if not active[rt.id] then break end
                        Wait(60)
                        moveHook(pick.x, pick.y, apexZ + (pick.z - apexZ) * ease(step / descendSteps), h0)
                    end
                    for step = 1, liftSteps do
                        if not active[rt.id] then break end
                        Wait(100)
                        place(pick.x, pick.y, pick.z + (apexZ - pick.z) * ease(step / liftSteps), h0)
                    end
                    audioMove()
                    for step = 1, carrySteps do
                        if not active[rt.id] then break end
                        Wait(100)
                        local x, y, hd = carryAt(ease(step / carrySteps))
                        place(x, y, apexZ, hd)
                    end
                    audioPlace()
                    for step = 1, lowerSteps do
                        if not active[rt.id] then break end
                        Wait(100)
                        place(drop.x, drop.y, apexZ + (drop.z - apexZ) * ease(step / lowerSteps), h1)
                    end

                    c.atPad = true   -- it now stands on its drop pad (the next lots' carry paths keep clear of it there)
                    audioImpact()
                    -- let go: the hook rises back to the apex over the drop
                    for step = 1, returnSteps do
                        if not active[rt.id] then break end
                        Wait(100)
                        moveHook(drop.x, drop.y, drop.z + (apexZ - drop.z) * ease(step / returnSteps), h1)
                    end
                end

                -- Safety watchdog: Guarantee container is frozen at exact ground drop coords
                if c.containerEntity and DoesEntityExist(c.containerEntity) then
                    SetEntityCoords(c.containerEntity, drop.x, drop.y, drop.z, false, false, false, true)
                    SetEntityHeading(c.containerEntity, drop.heading or 0.0)
                    FreezeEntityPosition(c.containerEntity, true)
                end
                TriggerClientEvent('nova_convoytruck:containerWars:client:craneAudioState', -1, { state = 'FINISHED', coords = drop })
                -- The container is DOWN and still CLOSED. Nothing opens it until an auction for it has been won and a winner
                -- uses it. Its bidding only starts after the short pause below.
                c.status = 'DELIVERED'
                local settle = tonumber(cw.settleSeconds) or 2
                if vehicleOnlyReward(c) then setDummyCrate(c, true) end   -- the car is not created before the auction has a winner
                TriggerClientEvent('nova_convoytruck:containerWars:client:containerDelivered', -1, {
                    convoyId = rt.id, containerId = c.id, containerIndex = c.containerIndex, name = c.name, coords = c.dropCoords,
                    bidIn = settle + (tonumber(cw.openSeconds) or 3),   -- seconds until its bidding opens, for the zone timer
                })
                if settle > 0 and active[rt.id] then Wait(math.floor(settle * 1000)) end
            end

            local function auctionContainer(c)
                if not active[rt.id] then return end
                rt.activeContainer = c

                -- The container stands CLOSED on its pad. A short beat (people walk over, the banner is read) and then its
                -- bidding opens. Nothing here touches the doors: only a winner opening the container does that.
                local openSeconds = tonumber(cw.openSeconds) or 3
                if openSeconds > 0 then
                    cwHudNotify(('CONTAINER %d — BIDDING SOON'):format(c.containerIndex or 0),
                        ('%s has landed. Bidding opens in %d seconds.'):format(c.name, math.floor(openSeconds)), 'info', math.floor(openSeconds * 1000))
                    Wait(math.floor(openSeconds * 1000))
                end
                if not active[rt.id] then return end
                c.status = 'AUCTION_ACTIVE'
                c.currentBid = c.startingBid or 5000
                c.highestBidder = nil
                c.highestBidderSource = nil
                c.highestBidderName = nil
                c.highestBidderGang = nil
                c.highestBidderGangName = nil
                c.timeRemaining = (isFinal and finalAuction > 0) and finalAuction or c.auctionDuration or 45
                c.version = (c.version or 0) + 1
                c.lastBidAt = {}

                log(rt.id, ('Auction started for %s (#%d) (Start: $%d, Duration: %ds)'):format(c.name, c.containerIndex, c.currentBid, c.timeRemaining))

                TriggerClientEvent('nova_convoytruck:containerWars:client:auctionStarted', -1, {
                    convoyId = rt.id,
                    containerId = c.id,
                    containerIndex = c.containerIndex,
                    name = c.name,
                    currentBid = c.currentBid,
                    bidIncrement = c.minBidIncrement or 1000,
                    timeRemaining = c.timeRemaining,
                    version = c.version,
                    coords = c.dropCoords,
                    round = round, totalRounds = totalRounds, isFinal = isFinal,
                })

                -- Countdown loop
                while c.timeRemaining > 0 and active[rt.id] do
                    Wait(1000)
                    c.timeRemaining = c.timeRemaining - 1
                    TriggerClientEvent('nova_convoytruck:containerWars:client:tickTimer', -1, {
                        convoyId = rt.id,
                        containerId = c.id,
                        containerIndex = c.containerIndex,
                        timeRemaining = c.timeRemaining,
                        currentBid = c.currentBid,
                        version = c.version,
                        highestBidderGang = c.highestBidderGang or 'No Bids',
                        highestBidderGangName = c.highestBidderGangName,
                        highestBidderName = c.highestBidderName,
                    })
                end

                if not active[rt.id] then return end

                -- The server's clock decides: from here no bid is accepted, whatever is still in flight.
                c.status = 'AUCTION_CLOSING'
                c.version = (c.version or 0) + 1

                -- Auction Ended for this container
                if c.highestBidderSource and c.highestBidderSource > 0 and c.highestBidderGangName then
                    -- Process payment from the winning bidder (server ids are reused, so match the character too)
                    local winnerSrc = resolveBidderSource(c)
                    local amount = c.currentBid
                    local paid = false
                    if TestRun and TestRun.admin then paid = true   -- a test run charges nobody
                    elseif winnerSrc then
                        paid = Bridge.RemoveMoney(winnerSrc, amount, 'bank')
                        if not paid then
                            paid = Bridge.RemoveMoney(winnerSrc, amount, 'cash')
                        end
                    end

                    if paid then
                        c.status = 'WON'
                        local winMsg = ('%s%s won %s for $%s!'):format(c.highestBidderGang or 'Gang', c.highestBidderName and (' (' .. c.highestBidderName .. ')') or '', c.name, string.format('%d', amount))
                        cwHudNotify('CONTAINER WON!', winMsg, 'success', 6000)
                        log(rt.id, winMsg)

                        -- 1. Update Gang Leaderboard stats or Civilian Leaderboard stats
                        if c.highestBidderGangName ~= 'civilian' then
                            GangService.RecordContainerWarsWin(c.highestBidderGangName, amount)
                            rt.gangStats = rt.gangStats or {}
                            local gs = rt.gangStats[c.highestBidderGangName] or { label = c.highestBidderGang or c.highestBidderGangName, won = 0, spend = 0, bids = 0 }
                            gs.won = gs.won + 1
                            gs.spend = gs.spend + amount
                            rt.gangStats[c.highestBidderGangName] = gs
                        elseif CivilianService and CivilianService.RecordResult then
                            CivilianService.RecordResult(c.highestBidder, c.highestBidderName, 'container_wars', rt.def.name, {
                                wins = 1,
                                points = 25,
                                totalRewards = amount,
                                participations = 1,
                            })
                        end
                        -- Gang XP for the winning gang (event setting): a member's win counts whether the event is gang-only or open
                        -- to civilians; a civilian winner earns none (RewardService.PayGangXp checks the gang on the server)
                        local gxp = math.floor(tonumber(cw.gangXpAmount) or 0)
                        if cw.gangXpOnWin == true and gxp > 0 and c.highestBidderGangName ~= 'civilian' and winnerSrc then
                            pcall(RewardService.PayGangXp, { winnerSrc }, gxp, 'Container Win', {
                                convoyId = rt.id, convoyName = rt.def.name, runId = rt.startedAt, xpPhase = 'cwwin:' .. tostring(c.id),
                            }, { event = 'container_wars', title = 'GANG XP EARNED', name = c.name, group = 'cwwin:' .. tostring(c.id) })
                        end
                        DiscordLog.appendEvent(rt.id, ('🔨 SOLD — %s won %s (%s) for $%s'):format(c.highestBidderGang or c.highestBidderGangName, c.name, c.highestBidderName or 'bidder', string.format('%d', amount)))

                        -- 2. Store individual winner audit record in database
                        DB.insertConvoyEvent(rt.id, 'CONTAINER_WON', {
                            gangName = c.highestBidderGangName,
                            gangLabel = c.highestBidderGang,
                            playerIdentifier = c.highestBidder,
                            playerName = c.highestBidderName,
                            detail = ('Won Container #%d (%s) for $%s'):format(c.containerIndex, c.name, string.format('%d', amount)),
                        })

                        -- 3. Broadcast WINNING BID visual state event directly on container
                        TriggerClientEvent('nova_convoytruck:containerWars:client:containerWon', -1, {
                            convoyId = rt.id,
                            containerId = c.id,
                            containerIndex = c.containerIndex,
                            name = c.name,
                            winnerGang = c.highestBidderGang,
                            winnerGangName = c.highestBidderGangName,
                            winnerPlayer = c.highestBidderName,
                            finalBid = amount,
                            coords = c.dropCoords,
                        })

                        -- The winners open the container itself (ox_target on the container).
                        local containerNetId = (c.containerEntity and DoesEntityExist(c.containerEntity)) and NetworkGetNetworkIdFromEntity(c.containerEntity) or nil
                        c.containerNetId = containerNetId
                        if beginVehicleClaim(rt, c) then
                            -- a car-only lot: no opening, the car stands inside and the winner claims it (E)
                        elseif c.highestBidderGangName == 'civilian' then
                            if winnerSrc then
                                TriggerClientEvent('nova_convoytruck:containerWars:client:containerUnlocked', winnerSrc, {
                                    convoyId = rt.id,
                                    containerId = c.id,
                                    containerIndex = c.containerIndex,
                                    name = c.name,
                                    winnerGang = 'civilian',
                                    winnerGangLabel = 'Civilian',
                                    winnerPlayer = c.highestBidderName,
                                    containerNetId = containerNetId,
                                    coords = c.dropCoords,
                                })
                            end
                        else
                            for _, member in ipairs(winningGangSources(c.highestBidderGangName)) do
                                TriggerClientEvent('nova_convoytruck:containerWars:client:containerUnlocked', member, {
                                    convoyId = rt.id,
                                    containerId = c.id,
                                    containerIndex = c.containerIndex,
                                    name = c.name,
                                    winnerGang = c.highestBidderGangName,
                                    winnerGangLabel = c.highestBidderGang,
                                    winnerPlayer = c.highestBidderName,
                                    containerNetId = containerNetId,
                                    coords = c.dropCoords,
                                })
                            end
                        end
                    else
                        c.status = 'UNSOLD'
                        c.unsoldReason = 'PAYMENT_FAILED'
                        DiscordLog.appendEvent(rt.id, ('⚠️ %s — winning bidder %s could not pay, lot unsold'):format(c.name, c.highestBidderName or 'unknown'))
                        cwHudNotify('PAYMENT FAILED',
                            ('Winner of %s had insufficient funds. Container unsold.'):format(c.name), 'error', 5000)
                        TriggerClientEvent('nova_convoytruck:containerWars:client:containerUnsold', -1, {
                            convoyId = rt.id,
                            containerId = c.id,
                            containerIndex = c.containerIndex,
                            name = c.name,
                            coords = c.dropCoords,
                        })
                    end
                else
                    c.status = 'UNSOLD'
                    c.unsoldReason = 'NO_BIDS'
                    DiscordLog.appendEvent(rt.id, ('⏭️ %s received no bids — unsold'):format(c.name))
                    cwHudNotify('NO BIDS PLACED',
                        ('No bids placed for %s. Container marked unsold.'):format(c.name), 'warning', 5000)
                    TriggerClientEvent('nova_convoytruck:containerWars:client:containerUnsold', -1, {
                        convoyId = rt.id,
                        containerId = c.id,
                        containerIndex = c.containerIndex,
                        name = c.name,
                        coords = c.dropCoords,
                    })
                end

                rt.activeContainer = nil
                if c.status ~= 'WON' then setDummyCrate(c, false) end
                local lotGap = math.max(5, math.floor(tonumber(cw.lotGapSeconds) or 15))
                if upcoming and active[rt.id] then
                    -- Broadcast claim window countdown so players know how long before the next container drops
                    TriggerClientEvent('nova_convoytruck:containerWars:client:nextDrop', -1, {
                        kind = 'CLAIM_WINDOW',
                        seconds = lotGap + upcomingExtra,
                        containerIndex = upcoming.containerIndex,
                        name = upcoming.name,
                        winnerName = c.highestBidderName,
                        winnerGang = c.highestBidderGang,
                    })
                end
                Wait(math.floor(lotGap * 1000)) -- pause between auctions in the same round: allows winner to open and loot

                -- Auto-relocate unclaimed reward vehicle or unopened container vehicle reward
                -- so subsequent container crane operations never collide with or crush it.
                if c.vehClaim then
                    -- a car-only lot: the car stays in its container for the whole claim window (see beginVehicleClaim)
                elseif c.rewardVehicleEntity and DoesEntityExist(c.rewardVehicleEntity) then
                    local safeCoords = findSafeStagingCoords(rt, nil, c)
                    SetEntityCoords(c.rewardVehicleEntity, safeCoords.x + 0.0, safeCoords.y + 0.0, safeCoords.z + 0.0, false, false, false, true)
                    SetEntityHeading(c.rewardVehicleEntity, (safeCoords.heading or 90.0) + 0.0)
                    FreezeEntityPosition(c.rewardVehicleEntity, true)
                    log(rt.id, ('Unclaimed reward vehicle for %s auto-relocated to safe spot (%.1f, %.1f, %.1f)'):format(
                        c.name, safeCoords.x, safeCoords.y, safeCoords.z))
                    announceRewardVehicle(c, safeCoords)
                elseif (c.status == 'WON' or c.status == 'CLAIMED') and not c.crateOpened and not c.rewardVehicleEntity then
                    local vehReward = nil
                    for _, r in ipairs(c.rewards or {}) do
                        if string.upper(tostring(r.type or r.rewardType or '')) == 'VEHICLE' then
                            vehReward = r
                            break
                        end
                    end
                    if vehReward and vehReward.model and vehReward.model ~= '' then
                        local safeCoords = findSafeStagingCoords(rt, nil, c)
                        local veh = CreateVehicle(joaat(vehReward.model), safeCoords.x, safeCoords.y, safeCoords.z, safeCoords.heading or 0.0, true, true)
                        if veh and veh ~= 0 and DoesEntityExist(veh) then
                            c.rewardVehicleEntity = veh
                            c.vehicleReward = vehReward
                            SetVehicleNumberPlateText(veh, Bridge.NewPlate())
                            FreezeEntityPosition(veh, true)
                            Entity(veh).state:set('cwRewardVehicle', {
                                convoyId = rt.id,
                                containerId = c.id,
                                model = vehReward.model,
                                label = vehReward.pool or vehReward.model or 'Vehicle',
                                winnerGang = c.highestBidderGangName,
                                winnerGangLabel = c.highestBidderGang or c.highestBidderGangName,
                                winnerPlayer = c.highestBidderName or 'Winner',
                                containerName = c.name,
                                lotNumber = c.containerIndex,
                                finalBid = c.currentBid or c.finalBid or 0,
                            }, true)
                            log(rt.id, ('Reward vehicle for unopened container %s spawned at safe staging spot.'):format(c.name))
                            announceRewardVehicle(c, safeCoords)
                        end
                    end
                end
            end

            -- THE SEQUENCE, one container at a time: announce it, the crane delivers it (it stands closed), its auction runs
            -- and is decided — and only then does the crane go to the next container. Never two at once.
            for i, c in ipairs(batchContainers) do
                if not active[rt.id] then break end
                local lotNo = c.containerIndex or i
                cwHudNotify(('CONTAINER %d DROPPING'):format(lotNo),
                    ('%s is being delivered. Prepare for bidding.'):format(c.name or ('Container ' .. lotNo)),
                    'info', 5000)
                DiscordLog.appendEvent(rt.id, ('📦 Container %d of %d — %s is being delivered by the crane'):format(lotNo, totalContainers, c.name or '?'))
                Wait(2500)   -- the banner is read before the crane moves
                stageContainer(c)
                if not active[rt.id] then break end
                -- what comes next, for the countdown shown while this one is decided
                upcoming, upcomingExtra = batchContainers[i + 1], 0.0
                if not upcoming and round < totalRounds then
                    upcoming = rt.containers[endIdx + 1]
                    upcomingExtra = tonumber(cw.roundBreakSeconds) or tonumber(cwDefaults.roundBreakSeconds) or 10
                    if finalEnabled and round == totalRounds - 1 then upcomingExtra = math.max(upcomingExtra, finalBreak) end
                end
                auctionContainer(c)
            end

            -- Pause after the round's last container before the next round starts; the one before the final
            -- round is longer, and says so
            local breakSeconds = tonumber(cw.roundBreakSeconds) or tonumber(cwDefaults.roundBreakSeconds) or 10
            if finalEnabled and round == totalRounds - 1 and active[rt.id] then
                breakSeconds = math.max(breakSeconds, finalBreak)
                local finalLots = totalContainers - (totalRounds - 1) * containersPerRound
                cwHudNotify('FINAL ROUND INCOMING',
                    ('%s up in %d seconds. Get your money and your people ready.'):format(finalLots > 1 and ('The final %d containers go'):format(finalLots) or 'The final container goes', math.floor(breakSeconds)), 'warning', math.min(8000, math.floor(breakSeconds * 1000)))
            end
            Wait(math.floor(breakSeconds * 1000))
        end

        if active[rt.id] then
            ContainerWars.finish(rt.id, 'COMPLETED')
        end
    end)
end

function ContainerWars.start(starterSource, convoyId)
    local def = ConvoyManager.get(convoyId)
    if not def then return false, 'Event definition not found.' end
    if def.kind ~= 'CONTAINER_WARS' then return false, 'Not a Container Wars event.' end

    -- Work on a copy with the harbour layout as it is NOW: spots moved or removed in the tablet since the
    -- event was saved apply from this start on.
    local cw = ConvoyManager.stampHarbour(json.decode(json.encode(def.containerWars or {})))
    local containers = cw.containers or {}
    if #containers == 0 then
        return false, 'Add at least one container to this event before starting.'
    end

    for i, c in ipairs(containers) do
        if not c.dropCoords or not c.dropCoords.x then
            return false, ('Container #%d has no drop spot — add one in the tablet (Harbour & Perimeter > Drop spots).'):format(i)
        end
    end

    if active[convoyId] then
        return false, 'This Container Wars event is already running.'
    end

    local clonedContainers = {}
    for i, c in ipairs(containers) do
        local copy = json.decode(json.encode(c))
        copy.containerIndex = i
        clonedContainers[i] = copy
    end

    if cw.auctionOrder == 'RANDOM' then
        for i = #clonedContainers, 2, -1 do
            local j = math.random(i)
            clonedContainers[i], clonedContainers[j] = clonedContainers[j], clonedContainers[i]
        end
        for i, copy in ipairs(clonedContainers) do copy.containerIndex = i end
    end
    -- the spots belong to the PLACE in the sequence, not to the lot: after a shuffle (and for lots that reuse a spot
    -- in a later round) each lot takes the spot, drop pad and crane of its new position
    ConvoyManager.stampLots(clonedContainers)

    local rt = {
        id = convoyId,
        -- the event as it is now (harbour layout re-applied); everything else is read through to the saved definition
        def = setmetatable({ containerWars = cw }, { __index = def }),
        startedAt = os.time(),
        currentRound = 1,
        totalContainers = #containers,
        containers = clonedContainers,
        history = {},
        participants = { identifiers = {}, civilians = {} },
    }
    for _, ident in ipairs(def.civilianRoster or {}) do
        rt.participants.civilians[ident] = true
        rt.participants.identifiers[ident] = 'civilian'
    end
    active[convoyId] = rt

    -- Pre-load: every container with a pickup spot (the ship's deck, a stack...)
    -- is visibly sitting there from the start, ready for the crane.
    -- Only the FIRST lot of each spot waits there from the start: a later lot on the same spot (next round) is put
    -- there when its round begins, after the earlier round's containers have been cleared — two would overlap.
    local preloaded, failedSpawns = 0, {}
    local spotTaken = {}
    for _, c in ipairs(clonedContainers) do
        local p = c.pickupCoords
        local spotFree = not (c.spotIndex and spotTaken[c.spotIndex])
        if p and p.x and spotFree then
            if c.spotIndex then spotTaken[c.spotIndex] = true end
            c.bodyModel = containerBodyModel(c.model)
            local obj = spawnProp(c.bodyModel, p.x, p.y, p.z, p.heading)
            if obj then
                tagContainer(obj, rt, c, c.bodyModel)
                c.containerEntity = obj
                c.status = 'LOADED'
                preloaded = preloaded + 1
                log(convoyId, ('Container #%s (%s) placed at its pickup %.1f, %.1f, %.1f'):format(tostring(c.containerIndex or '?'), c.name or '?', p.x, p.y, p.z))
            else
                failedSpawns[#failedSpawns + 1] = c.name or c.id
                log(convoyId, ('Container "%s": could not create model "%s" at pickup %.1f, %.1f, %.1f'):format(c.name or '?', tostring(c.model), p.x, p.y, p.z))
            end
        end
    end
    rt.startedByName = starterSource and starterSource > 0 and Bridge.GetPlayerName(starterSource) or 'System / Dispatch'

    ConvoyManager.setStatus(convoyId, 'ACTIVE')

    -- The harbour cranes: one gantry per aisle, each a frozen frame prop with its own cabin and wheels, removed with
    -- the event (the harbour keeps none standing outside an event).
    -- The harbour's decor stacks stand only while the event runs; any admin preview of them is replaced by these
    HarbourStore.holdDummies(rt.id, true)
    rt.dummiesHeld = true
    local cwCfg = Config.ContainerWars or {}
    rt.gantryEntities = {}
    rt.gantries = {}
    local craneDefs = {}
    if type(cw.cranes) == 'table' and #cw.cranes > 0 then
        craneDefs = cw.cranes
    elseif cw.crane and cw.crane.x then
        craneDefs = { cw.crane }
    end
    rt.craneDefs = craneDefs
    local firstContainer = clonedContainers[1]
    local firstCrane = firstContainer and CWGantry.craneFor(craneDefs, firstContainer.pickupCoords, firstContainer.dropCoords) or 1
    local craneMissing = false
    -- Smooth crane: the gantry, the hook and the carried container are LOCAL props every client builds and animates itself
    -- (see client/modules/container_wars_fx.lua), so the server creates none of them and sends one plan per container.
    local smooth = (Config.ContainerWars and Config.ContainerWars.defaults and Config.ContainerWars.defaults.smoothCrane) ~= false
    for ci, craneCfg in ipairs(craneDefs) do
        if craneCfg.x and craneCfg.y and craneCfg.enabled ~= false then
            local craneModel = craneCfg.model or 'prop_dock_rtg_ld'
            local frame = nil
            if not smooth then frame = spawnProp(craneModel, craneCfg.x, craneCfg.y, craneCfg.z or 0.0, craneCfg.heading) end
            if not frame and not smooth then
                craneMissing = true
                log(convoyId, ('Crane model "%s" could not be created — check the model name in the Container Wars setup.'):format(craneModel))
            else
                if frame then
                    Entity(frame).state:set('container_wars_id', convoyId, true)
                    rt.gantryEntities[#rt.gantryEntities + 1] = frame
                    if not rt.craneEntity then rt.craneEntity = frame end
                end
                log(convoyId, ('Crane #%d "%s" placed at %.1f, %.1f, %.1f'):format(ci, craneModel, craneCfg.x, craneCfg.y, craneCfg.z or 0.0))

                -- the gantry: cabin + wheels around the frame
                local gantryCfg = CWGantry.get(craneModel)
                if gantryCfg then
                    local crane = { x = craneCfg.x, y = craneCfg.y, z = craneCfg.z or 0.0, heading = craneCfg.heading or 0.0 }
                    local g = { cfg = gantryCfg, crane = crane, frame = frame, wheels = {}, model = craneModel, index = ci }
                    g.armTop = crane.z + ((gantryCfg.cabin and gantryCfg.cabin.z) or 18.0) + (tonumber(gantryCfg.cableTopOffset) or -1.0)
                    -- parked over the first container it will carry, or in the middle of its own aisle
                    local at = (ci == firstCrane and firstContainer and (firstContainer.pickupCoords or firstContainer.dropCoords)) or crane
                    local lay = CWGantry.layout(gantryCfg, crane, at.x, at.y)
                    if frame then SetEntityCoords(frame, lay.frame.x, lay.frame.y, lay.frame.z, false, false, false, false) end
                    local cabin = (not smooth) and spawnProp(gantryCfg.cabin.model, lay.cabin.x, lay.cabin.y, lay.cabin.z, lay.cabin.heading) or nil
                    if cabin then
                        Entity(cabin).state:set('container_wars_id', convoyId, true)
                        g.cabin = cabin
                        rt.gantryEntities[#rt.gantryEntities + 1] = cabin
                    elseif not smooth then
                        log(convoyId, ('Gantry cabin "%s" could not be created.'):format(tostring(gantryCfg.cabin.model)))
                    end
                    local wheelModel = gantryCfg.wheels and gantryCfg.wheels.model
                    for _, p in ipairs(smooth and {} or lay.wheels) do
                        local w = wheelModel and spawnProp(wheelModel, p.x, p.y, p.z, p.heading)
                        if w then
                            Entity(w).state:set('container_wars_id', convoyId, true)
                            g.wheels[#g.wheels + 1] = w
                            rt.gantryEntities[#rt.gantryEntities + 1] = w
                        end
                    end
                    rt.gantries[ci] = g
                    log(convoyId, ('Gantry crane #%d ready at %.1f, %.1f heading %.1f%s: cabin %s, %d wheel(s)'):format(
                        ci, crane.x, crane.y, crane.heading, craneCfg.auto and ' (auto-aligned)' or '', cabin and 'ok' or 'MISSING', #g.wheels))
                    if craneCfg.reachable == false then
                        log(convoyId, 'WARNING: some container spots are beyond the gantry\'s reach (Config.ContainerWars.gantries span / rail). Add another crane near them, or move the spots.')
                    end
                end
            end
        end
    end
    -- the crane that carries the first container is the active one to begin with (each container picks its own later)
    rt.gantry = rt.gantries[firstCrane] or select(2, next(rt.gantries))
    local craneCfg = craneDefs[1]

    local hookCfg = cwCfg.hook
    rt.hookParts = {}
    if hookCfg and hookCfg.enabled ~= false and rt.gantry then
        local first = clonedContainers[1]
        local hp = (first and (first.pickupCoords or first.dropCoords)) or (craneCfg and craneCfg.x and { x = craneCfg.x, y = craneCfg.y, z = (craneCfg.z or 0.0) + 14.0 }) or nil
        if hp then
            local startLift = tonumber(cw.craneLiftHeight) or 14.0
            if first and (first.pickupCoords or first.dropCoords) then hp = { x = hp.x, y = hp.y, z = hp.z + startLift } end
            rt.hookAt = { x = hp.x, y = hp.y, z = hp.z }
            -- lowest point the hook will reach, to know how long the cable has to be
            local lowZ = hp.z
            for _, cc in ipairs(clonedContainers) do
                if cc.pickupCoords and cc.pickupCoords.z and cc.pickupCoords.z < lowZ then lowZ = cc.pickupCoords.z end
                if cc.dropCoords and cc.dropCoords.z and cc.dropCoords.z < lowZ then lowZ = cc.dropCoords.z end
            end
            -- the rope is fastened under the active gantry's cabin; the cable is made long enough for the tallest crane
            local armTop = rt.gantry.armTop
            local tallest = armTop
            for _, gg in pairs(rt.gantries) do tallest = math.max(tallest, gg.armTop or tallest) end
            local segLen = tonumber(hookCfg.cableSegmentLength)

            -- LINES (default): the cable is drawn by every client from the cabin down to the spreader, no cable props
            local ropeLines = tostring(hookCfg.cableMode or 'LINES'):upper() ~= 'PROPS'
            -- (smooth crane: the clients build the hook locally, nothing is spawned here)
            for _, def in ipairs(smooth and {} or (hookCfg.parts or {})) do
              if not (def.cable and ropeLines) then
                local part = { x = tonumber(def.x) or 0.0, y = tonumber(def.y) or 0.0, z = tonumber(def.z) or 0.0, heading = tonumber(def.heading) or 0.0, entities = {} }
                local count = 1
                -- fallback: the configured length; cableTop = how far a piece reaches above its origin (default: origin at the bottom)
                local len, top = segLen, tonumber(hookCfg.cableTop) or segLen
                if def.cable then
                    local m = measureCable(def.model, starterSource)
                    if m then len, top = m.len, m.top end
                end
                if def.cable and armTop and len and len > 0.5 then
                    part.segLen, part.top, part.armTop = len, top, armTop
                    part.overlap = tonumber(hookCfg.cableOverlap) or 3.0   -- how far the rope's lower end may sink into the spreader + container
                    count = math.max(1, math.min(24, math.ceil((tallest - (lowZ + part.z)) / len) + 1))
                end
                for k = 1, count do
                    local e = spawnProp(def.model, hp.x + part.x, hp.y + part.y, math.min(hp.z + part.z + (k - 1) * (part.segLen or 0.0), part.armTop and (part.armTop - (part.top or 0.0)) or math.huge), part.heading)
                    if e then
                        Entity(e).state:set('container_wars_id', convoyId, true)
                        part.entities[#part.entities + 1] = e
                    end
                end
                if #part.entities > 0 then
                    rt.hookParts[#rt.hookParts + 1] = part
                else
                    log(convoyId, ('Crane hook part "%s" could not be created.'):format(tostring(def.model)))
                end
              end
            end
            -- the spreader carries the rope: clients draw it from the cabin's underside down to this prop
            if ropeLines then
                for _, part in ipairs(rt.hookParts) do
                    local holder = part.entities[1]
                    if holder and DoesEntityExist(holder) then
                        rt.ropeHolder = holder
                        Entity(holder).state:set('cwRope', { armTop = armTop }, true)
                        break
                    end
                end
            end
        end
    end

    -- Tell whoever started it if something could not be created, instead of failing silently.
    if starterSource and starterSource > 0 and (#failedSpawns > 0 or craneMissing) then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', starterSource, {
            type = 'error', duration = 12000, title = 'Container Wars — setup problem',
            description = ('%s%s Check the model names in the setup; details are in the server console.'):format(
                #failedSpawns > 0 and ('Could not create: %s. '):format(table.concat(failedSpawns, ', ')) or '',
                craneMissing and 'A crane could not be created.' or ''),
        })
    end

    DiscordLog.startEvent(convoyId, ('🚢 Container Wars — %s'):format(def.name), 0x38bdf8,
        def.shortDescription or 'Harbour container auction underway.', {
            { name = 'Containers', value = tostring(#containers), inline = true },
            { name = 'Per Round', value = tostring(math.max(1, math.min(10, cw.containersPerRound or 4))), inline = true },
            { name = 'Started By', value = rt.startedByName, inline = true },
        })
    DiscordLog.appendEvent(convoyId, ('🚢 Container Wars "%s" opened — %d container%s up for auction (started by: %s)'):format(def.name, #containers, #containers == 1 and '' or 's', rt.startedByName))

    rt.smooth = smooth

    -- Sync to clients with full config (including bidding polygon zone and crane); the clients build the crane now so it
    -- is standing in the yard during the countdown. The same payload goes to anyone who joins later (requestSync below).
    TriggerClientEvent('nova_convoytruck:containerWars:client:eventStarted', -1, ContainerWars.syncPayload(rt))
    local setup = ContainerWars.craneSetup(rt)
    if setup then TriggerClientEvent('nova_convoytruck:containerWars:client:craneSetup', -1, setup) end

    -- START SEQUENCE: the banner counts down (Config.ContainerWars.defaults.startCountdownSeconds, or the event's own
    -- setting), and the crane does not move until it has finished. Everyone sees the same banner at the same moment
    -- because the server announces every step.
    local cwDefaults = (Config.ContainerWars and Config.ContainerWars.defaults) or {}
    local countdown = math.floor(tonumber(cw.startCountdownSeconds) or tonumber(cwDefaults.startCountdownSeconds) or 30)
    CreateThread(function()
        if countdown > 0 then
            local timeText = countdown >= 60 and (('%d minute%s'):format(math.ceil(countdown / 60), math.ceil(countdown / 60) == 1 and '' or 's')) or (('%d seconds'):format(countdown))
            cwAnnounce('CONTAINER WARS STARTING SOON', ('Harbour container auction begins in %s (%d container%s staged). Head to the docks!'):format(timeText, #containers, #containers == 1 and '' or 's'), math.min(countdown * 1000, 15000), 'STARTING SOON')
            Wait(2500) -- Allow announcement banner to appear on screen before ticking starts
            local remaining = countdown
            TriggerClientEvent('nova_convoytruck:containerWars:client:startCountdown', -1, {
                seconds = remaining,
                totalContainers = #containers,
                name = def.name,
            })
            while remaining > 0 and active[convoyId] do
                TriggerClientEvent('nova_convoytruck:containerWars:client:tickStartCountdown', -1, {
                    seconds = remaining,
                    totalContainers = #containers,
                })
                Wait(1000)
                remaining = remaining - 1
            end
        end
        if not active[convoyId] then return end
        TriggerClientEvent('nova_convoytruck:containerWars:client:tickStartCountdown', -1, {
            seconds = 0,
            totalContainers = #containers,
        })
        cwAnnounce('CONTAINER WARS STARTED', 'The harbour crane is in motion! The auction is now live at the docks.', 7000, 'EVENT ACTIVE')
        Wait(500)
        if active[convoyId] then runContainerWarsLifecycle(rt) end
    end)
    return true
end

-- What a client needs to follow a running event: the layout, every lot and the state it is in. Sent when the event
-- starts and again to anyone who joins (or restarts the resource) while it runs.
function ContainerWars.syncPayload(rt)
    local cw = (rt.def and rt.def.containerWars) or {}
    local states = {}
    for _, c in ipairs(rt.containers or {}) do
        states[c.id] = {
            status = c.status, currentBid = c.currentBid, bidIncrement = c.minBidIncrement or 1000, version = c.version,
            timeRemaining = c.timeRemaining, highestBidderGang = c.highestBidderGang, highestBidderName = c.highestBidderName,
            highestBidderGangName = c.highestBidderGangName, finalBid = (c.status == 'WON' or c.status == 'CLAIMED') and c.currentBid or nil,
            winnerGang = c.highestBidderGang, winnerGangName = c.highestBidderGangName, winnerPlayer = c.highestBidderName,
        }
    end
    return {
        convoyId = rt.id, name = rt.def.name, crane = cw.crane, cranes = cw.cranes, zone = cw.zone,
        containers = rt.containers, states = states,
    }
end

-- The crane, as the clients build it: one entry per gantry, where the hook is parked, which gantry is active.
function ContainerWars.craneSetup(rt)
    if not rt.smooth or not rt.gantries or not next(rt.gantries) then return nil end
    local list = {}
    for ci, g in pairs(rt.gantries) do
        list[#list + 1] = {
            index = ci, model = g.model, armTop = g.armTop,
            ref = { x = g.crane.x, y = g.crane.y, z = g.crane.z, heading = g.crane.heading, railMin = g.crane.railMin, railMax = g.crane.railMax },
        }
    end
    table.sort(list, function(a, b) return a.index < b.index end)
    return { convoyId = rt.id, cranes = list, active = rt.gantry and rt.gantry.index or nil, hook = rt.hookAt }
end

-- A client that joined (or restarted) while an event is running asks for the picture it missed.
RegisterNetEvent('nova_convoytruck:containerWars:server:requestSync', function()
    local src = source
    for id, rt in pairs(active) do
        TriggerClientEvent('nova_convoytruck:containerWars:client:eventStarted', src, ContainerWars.syncPayload(rt))
        local setup = ContainerWars.craneSetup(rt)
        if setup then TriggerClientEvent('nova_convoytruck:containerWars:client:craneSetup', src, setup) end
        -- a winner who crashed or rejoined: the blip of their unclaimed reward car comes back (it was only sent once, when the car was placed)
        local gang = GangService and GangService.GetPlayerGang(src)
        local ident = Bridge.GetIdentifier(src)
        for _, c in ipairs(rt.containers or {}) do
            local veh = c.rewardVehicleEntity
            if veh and DoesEntityExist(veh) then
                local mine = (c.highestBidderGangName == 'civilian' and c.highestBidder == ident)
                    or (gang and gang.name and gang.name == c.highestBidderGangName)
                if mine then
                    local at = GetEntityCoords(veh)
                    TriggerClientEvent('nova_convoytruck:containerWars:client:rewardVehicleBlip', src, { containerId = c.id, x = at.x, y = at.y, z = at.z, name = c.name })
                end
            end
        end
    end
end)

-- ── Bidding NetEvent (Open-To-All Gangs, Gang-Aware) ───────────────────────────

-- ── Bidding ─────────────────────────────────────────────────────────────────────
-- The server is the only authority. A bid is one transaction: every condition is
-- checked and the state changed in a single block with no yield in between, so two
-- bids that arrive in the same millisecond are strictly ordered — the second one
-- sees the first one's result and is rejected. Every request gets an answer
-- (client:bidResult), so a client can never be left waiting.
local bidCfg = (Config.ContainerWars and Config.ContainerWars.bidding) or {}
local BID_MIN_GAP_MS = tonumber(bidCfg.serverMinGapMs) or 300   -- per player per container: faster requests are dropped
local BID_STALE_MSG = bidCfg.staleMessage or 'Bid is no longer valid. Current bid has changed.'
local BID_COOLDOWN_MS = math.max(0, tonumber(bidCfg.bidCooldownSeconds) or 0) * 1000   -- per player, after an ACCEPTED bid

-- the bidding rules themselves live in auction_core.lua (shared with the Gang Territory Auction)
local minimumNext = AuctionCore.minimumNext
local bidOpen = AuctionCore.bidOpen

local function bidReply(src, reqId, c, ok, code, message)
    TriggerClientEvent('nova_convoytruck:containerWars:client:bidResult', src, {
        reqId = reqId,
        ok = ok == true,
        code = code,
        message = message,
        containerId = c and c.id or nil,
        version = c and c.version or nil,
        currentBid = c and c.currentBid or nil,
        minimumBid = c and minimumNext(c) or nil,
        increment = c and (c.minBidIncrement or 1000) or nil,
        canBid = c and bidOpen(c) or false,
    })
end

local function findContainer(rt, containerId)
    if rt.activeContainer and rt.activeContainer.id == containerId then return rt.activeContainer end
    for _, c in ipairs(rt.containers or {}) do
        if c.id == containerId then return c end
    end
    return nil
end

-- Who may bid right now? Returns gang, or nil + code + message.
local function bidderGang(rt, src)
    local identifier = Bridge.GetIdentifier(src)
    local isCivRegistered = rt.participants and rt.participants.civilians and identifier and rt.participants.civilians[identifier]
    local eventAccess = (rt.def.settings and rt.def.settings.eventAccess) or rt.def.eventAccess
    if Bridge.IsPolice(src) then
        -- an officer takes part only as a civilian bidder, after registering at the registration ped
        if isCivRegistered then return { name = 'civilian', label = 'Civilian', isCivilian = true } end
        return nil, 'POLICE', 'Register at the event registration ped to take part in the auction.'
    end

    local gang = GangService and GangService.GetPlayerGang(src)
    if not gang or not gang.name or gang.name == 'none' then
        if (eventAccess == 'EVERYONE' or eventAccess == 'everyone') and isCivRegistered then
            return {
                name = 'civilian',
                label = 'Civilian',
                isCivilian = true,
            }
        end
        if eventAccess == 'EVERYONE' or eventAccess == 'everyone' then
            return nil, 'NOT_REGISTERED', 'You must register at the event registration ped to participate in bidding.'
        end
        return nil, 'NO_GANG', 'You must be in a gang to bid.'
    end
    if not eligibleGang(rt, gang.name) then
        return nil, 'NOT_ELIGIBLE', 'Your gang is not eligible for this event.'
    end
    -- a gang bids only when its leader registered it (Event Status, Events tab); an event open to everyone has no such sign-up
    if eventAccess ~= 'EVERYONE' and eventAccess ~= 'everyone' and not ConvoyManager.isGangRegistered(rt.def, gang.name) then
        return nil, 'NOT_REGISTERED', 'Your gang did not register for this auction (Event Status, Events tab).'
    end
    return gang
end

-- The whole bid, as one block. No Wait(), no callback.await — nothing in here may yield.
local function applyBid(src, rt, c, amount, version)
    if not bidOpen(c) then return false, 'ENDED', 'This auction is no longer taking bids.' end

    local gang, code, msg = bidderGang(rt, src)
    if not gang then return false, code, msg end

    local snipeCfg = rt.def.containerWars or {}
    local snipeDefaults = (Config.ContainerWars and Config.ContainerWars.antiSnipe) or {}
    local ok, bcode, bmsg = AuctionCore.apply(c, {
        amount = amount, version = version, source = src,
        identifier = Bridge.GetIdentifier(src), name = Bridge.GetCharacterName(src), gang = gang,
    }, {
        staleMessage = BID_STALE_MSG,
        snipeEnabled = snipeDefaults.enabled ~= false,
        snipeWindow = tonumber(snipeCfg.antiSnipeWindowSeconds) or tonumber(snipeDefaults.triggerSeconds) or 10,
        snipeExtend = tonumber(snipeCfg.antiSnipeExtendSeconds) or tonumber(snipeDefaults.extendSeconds) or 15,
    })
    if not ok then return false, bcode, bmsg end

    rt.bidderGangs = rt.bidderGangs or {}
    rt.bidderGangs[gang.name] = true
    rt.gangStats = rt.gangStats or {}
    local bidStats = rt.gangStats[gang.name] or { label = gang.label or gang.name, won = 0, spend = 0, bids = 0 }
    bidStats.bids = bidStats.bids + 1
    rt.gangStats[gang.name] = bidStats
    return true
end

RegisterNetEvent('nova_convoytruck:containerWars:server:placeBid', function(convoyId, containerId, amount, version, reqId)
    local src = source
    reqId = tostring(reqId or ''):sub(1, 40)

    local rt = active[convoyId]
    if not rt then return bidReply(src, reqId, nil, false, 'NO_EVENT', 'Event is not active.') end
    local c = findContainer(rt, containerId)
    if not c then return bidReply(src, reqId, nil, false, 'NO_CONTAINER', 'Container not found.') end

    -- cooldown after a placed bid: stops a player spamming raises (rejected attempts do not start it)
    rt.bidCooldownUntil = rt.bidCooldownUntil or {}
    local waitMs = (rt.bidCooldownUntil[src] or 0) - GetGameTimer()
    if waitMs > 0 then
        return bidReply(src, reqId, c, false, 'COOLDOWN', ('Wait %d s before bidding again.'):format(math.ceil(waitMs / 1000)))
    end

    -- rate limit (per player per container) + one bid at a time + error guard: shared with the territory auction
    local ok, code, msg = AuctionCore.guard(c, src, BID_MIN_GAP_MS, BID_STALE_MSG, function()
        return applyBid(src, rt, c, amount, version)
    end)
    if not ok then return bidReply(src, reqId, c, false, code, msg) end
    rt.bidCooldownUntil[src] = GetGameTimer() + BID_COOLDOWN_MS

    log(rt.id, ('Bid placed: %s (%s) bid $%d on Container #%d (%s)'):format(c.highestBidderName, c.highestBidderGang, c.currentBid, c.containerIndex or 1, c.name))

    -- Push the new state to everyone (fields only — clients just update numbers)
    TriggerClientEvent('nova_convoytruck:containerWars:client:bidUpdate', -1, {
        convoyId = rt.id,
        containerId = c.id,
        containerIndex = c.containerIndex,
        currentBid = c.currentBid,
        minimumBid = minimumNext(c),
        version = c.version,
        highestBidderGang = c.highestBidderGang,
        highestBidderGangName = c.highestBidderGangName,
        highestBidderName = c.highestBidderName,
        timeRemaining = c.timeRemaining,
        bidderSource = src,
    })

    bidReply(src, reqId, c, true, 'OK', ('You are leading with $%s for %s.'):format(string.format('%d', c.currentBid), c.highestBidderGang))
end)

-- Opening the bidder window: the server confirms the player can bid and supplies the
-- numbers (and their gang) the window shows.
lib.callback.register('nova_convoytruck:containerWars:bidInfo', function(src, convoyId, containerId)
    local rt = active[convoyId]
    if not rt then return { ok = false, message = 'Event is not active.' } end
    local c = findContainer(rt, containerId)
    if not c or not bidOpen(c) then return { ok = false, message = 'This container is not actively taking bids.' } end
    local gang, _, msg = bidderGang(rt, src)
    if not gang then return { ok = false, message = msg } end
    return {
        ok = true,
        containerId = c.id,
        containerNumber = c.containerIndex or 1,
        currentBid = c.currentBid,
        minimumBid = minimumNext(c),
        increment = c.minBidIncrement or 1000,
        gang = gang.label or gang.name,
        version = c.version,
        canBid = true,
    }
end)

-- ── Paying out a container once it has been opened ──────────────────────────────
-- The loot crate: when a winner opens a container, the ITEMS of its reward go into a crate standing inside it (a stash the
-- winning gang members open with ox_target and take from); money and vehicles are paid straight away as before. If
-- the inventory cannot pre-fill stashes (only ox_inventory can), everything is paid directly as it always was.
local function crateCfg()
    return (Config.ContainerWars and Config.ContainerWars.lootCrate) or {}
end

-- One reward entry as an inventory item: name, count — or nil when it is not an item (money, vehicle ...).
local function crateEntry(reward)
    local t = string.upper(tostring(reward.type or reward.rewardType or reward.kind or ''))
    local count = math.max(1, math.floor(tonumber(reward.amount or reward.count or reward.quantity or reward.value) or 1))
    if t == 'ITEM' or t == 'ITEMS' or t == 'WEAPON' then
        local name = reward.item or reward.pool or reward.name or reward.itemName or reward.item_name or reward.weapon
        if name and name ~= '' then return tostring(name), count end
    elseif t == 'TOKENS' or t == 'TOKEN' then
        return tostring((Config.RallyRace and Config.RallyRace.tokenItem) or 'race_token'), count
    end
    return nil
end

local function itemRewards(list)
    local out = {}
    for _, it in ipairs(list or {}) do out[#out + 1] = { type = 'ITEM', item = it.name or it.item, amount = it.count or it.amount or 1 } end
    return out
end

-- Fills a stash for this container and tells every client to put a crate inside it. Returns true when the crate exists.
local function createLootCrate(rt, c, items)
    local cfg = crateCfg()
    if cfg.enabled == false or #items == 0 or not Inventory.SupportsStash() then return false end
    local stashId = ('cw_crate_%d_%s'):format(rt.id, tostring(c.id))
    local drop = c.dropCoords
    Inventory.RegisterStash(stashId, ('%s — Loot Crate'):format(c.name or 'Container'), tonumber(cfg.slots) or 30, tonumber(cfg.weight) or 400000,
        drop and vector3(drop.x, drop.y, drop.z) or nil)
    Inventory.ClearStash(stashId)
    local stored, list = 0, {}
    for _, it in ipairs(items) do
        if Inventory.AddItem(stashId, it.name, it.count) then
            stored = stored + 1
            list[#list + 1] = it
        end
    end
    if stored == 0 then return false end
    c.crateStash, c.crateItems = stashId, list
    local ent = c.containerEntity
    if ent and DoesEntityExist(ent) then
        Entity(ent).state:set('cwCrate', { stash = stashId, convoyId = rt.id, containerId = c.id, label = cfg.targetLabel or 'Search Loot Crate' }, true)
    end
    return true
end

local function claimContainer(src, rt, targetCont, gang, opts)
    opts = opts or {}
    targetCont.status = 'CLAIMED'

    local charName = Bridge.GetCharacterName(src)
    local charIdent = Bridge.GetIdentifier(src)
    targetCont.claimedByName = charName
    targetCont.claimedAt = os.time()
    DiscordLog.appendEvent(rt.id, ('📦 %s opened by %s (%s) — %s'):format(
        targetCont.name or 'Container', charName or 'Unknown', gang.label or gang.name,
        RewardService.describeRewards(targetCont.rewards)))

    -- Grant rewards
    local provenance = {
        convoyId = rt.id,
        convoyName = rt.def.name,
        containerId = targetCont.id,
        containerIndex = targetCont.containerIndex,
        containerName = targetCont.name,
        gangName = gang.name,
        gangLabel = gang.label,
        claimedBy = charIdent,
        claimedByName = charName,
        -- a car reward is owned by the bidder who won it, whoever opens the container (see RewardService.GiveVehicle)
        ownerCitizenid = targetCont.highestBidder,
        -- who won the auction: shown in /carowner so an admin knows whom a spawned reward car should be handed to
        winningBidder = targetCont.highestBidderName,
        winningBid = targetCont.currentBid,
        -- Gang XP (a "Gang XP" entry in the container's rewards): once per container per run, to the opener's gang
        runId = rt.startedAt, xpPhase = 'container:' .. tostring(targetCont.id),
    }

    -- Money, items and vehicles all go through the one payout. A SPAWN-mode car appears on the open ground beside the
    -- container (its drop spot, set sideways so it does not sit on the container); a GARAGE-mode car goes straight to
    -- the winner's garage.
    local drop = targetCont.dropCoords or { x = 805.0, y = -2975.0, z = 6.0, heading = 0.0 }
    local sideRad = math.rad((drop.heading or 0.0) + 90.0)
    provenance.spawn = {
        x = drop.x + math.cos(sideRad) * 6.0, y = drop.y + math.sin(sideRad) * 6.0,
        z = (drop.z or 0.0) + 1.0, heading = drop.heading or 0.0,
    }
    local rewards = opts.rewards or targetCont.rewards or {}
    local direct, crateItems = rewards, {}
    if not opts.direct and crateCfg().enabled ~= false and Inventory.SupportsStash() then
        direct = {}
        for _, r in ipairs(rewards) do
            local name, count = crateEntry(r)
            if name then crateItems[#crateItems + 1] = { name = name, count = count } else direct[#direct + 1] = r end
        end
    end
    local crateMade = #crateItems > 0 and createLootCrate(rt, targetCont, crateItems)
    if #crateItems > 0 and not crateMade then
        -- no crate possible: the items are paid straight to the opener like everything else
        for _, it in ipairs(crateItems) do direct[#direct + 1] = { type = 'ITEM', item = it.name, amount = it.count } end
    end
    local leftovers = {}
    if #direct > 0 then
        leftovers = RewardService.GrantContainerReward(direct, src, provenance) or {}
    end
    -- items the inventory refused (full): the crate keeps them, so nothing the winner paid for is lost (see the crate search)
    if opts.keepLeftovers and #leftovers > 0 then
        targetCont.status = 'OPENED'
        return leftovers
    end
    if crateMade then
        DiscordLog.appendEvent(rt.id, ('🧰 %s — loot crate filled: %s'):format(targetCont.name or 'Container', RewardService.describeRewards(itemRewards(crateItems))))
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'success', duration = 9000, title = 'LOOT CRATE', description = 'The container is open. Search the loot crate inside to take your items.' })
    end

    -- Insert claim audit event in DB
    DB.insertConvoyEvent(rt.id, 'CONTAINER_CLAIMED', {
        gangName = gang.name,
        gangLabel = gang.label,
        playerIdentifier = charIdent,
        playerName = charName,
        detail = ('Claimed Container #%d (%s) rewards'):format(targetCont.containerIndex or 1, targetCont.name),
    })


    TriggerClientEvent('nova_convoytruck:containerWars:client:containerClaimed', -1, {
        convoyId = rt.id,
        containerId = targetCont.id,
        containerIndex = targetCont.containerIndex,
    })

    if not crateMade then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'success', description = 'Container loot secured!' })
    end
end

-- Anything a winner did not collect is delivered when the container goes away (the next round clears the pad, or the event
-- ends), so a missed crate or a never-opened container does not cost them what they paid for.
--   · won but never opened  → the whole reward is paid straight to the winner
--   · opened, crate not emptied → what is still in the crate is put into the winner's inventory
-- The winner has to be online; failing that, an online member of the winning gang receives it. Nobody online → it is logged.
-- Records the reward car as the winning bidder's own: player database + garage. inWorld = true: it stands in the world (record says out);
-- false: it is stored in the garage. Returns ok, plateOrError, vehicleId.
local function ownRewardVehicle(c, veh, inWorld)
    local vr = c.vehicleReward or {}
    if not c.highestBidder or not vr.model or vr.model == '' then return false, 'no winner or no vehicle model' end
    local plate
    if veh and DoesEntityExist(veh) then
        plate = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+$', '')
        if plate == '' then plate = nil end
    end
    -- no source: the bidder may be offline, or the source id may belong to someone else by now
    return Bridge.AddOwnedVehicle(nil, vr.model, { citizenid = c.highestBidder, plate = plate, out = inWorld })
end

-- Event cleanup: a reward car nobody claimed goes to the winning bidder's garage and the world copy is removed.
settleRewardVehicle = function(rt, c)
    if c.vehClaim then settleVehicleClaim(rt, c, 'the event ended') return end
    local veh = c.rewardVehicleEntity
    if not (veh and DoesEntityExist(veh)) then return end
    local ok, plateOrErr = ownRewardVehicle(c, veh, false)
    if not ok then
        log(rt.id, ('Unclaimed reward car of %s could not be put in the winner garage: %s (left in the world, see /carowner)'):format(c.name or 'Container', tostring(plateOrErr)))
        return
    end
    c.rewardVehicleEntity = nil
    Entity(veh).state:set('cwRewardVehicle', nil, true)
    TriggerClientEvent('nova_convoytruck:containerWars:client:rewardVehicleBlip', -1, { containerId = c.id, clear = true })
    DeleteEntity(veh)
    DiscordLog.appendEvent(rt.id, ('🚗 %s — the unclaimed reward car was put in the garage of %s (plate %s)'):format(c.name or 'Container', c.highestBidderName or 'the winner', tostring(plateOrErr)))
    local src = resolveBidderSource(c)
    if src then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'success', duration = 12000, title = 'REWARD VEHICLE', description = ('You did not claim your %s in time, so it was put in your garage (plate %s).'):format((c.vehicleReward and (c.vehicleReward.pool or c.vehicleReward.model)) or 'car', tostring(plateOrErr)) })
    end
end

-- ── A car-only lot: claim window ───────────────────────────────────────────────
-- Everything here runs on the server: the clock, who may claim, and the garage record. The timer is a server thread, so it does not
-- care whether the winner is still connected. A claim that is waiting is also written to data/cw_vehicle_claims.json, so a crash or a
-- resource restart cannot lose the car: it is put into the winner's garage at the next start.
local CLAIM_FILE = 'data/cw_vehicle_claims.json'
local pendingClaims = {}   -- [claimId] = { id, citizenid, model, plate, name, endsAt, live }
do
    local raw = LoadResourceFile(GetCurrentResourceName(), CLAIM_FILE)
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then pendingClaims = data end
    end
end

local function savePendingClaims()
    local out = {}
    for id, e in pairs(pendingClaims) do
        out[id] = { id = e.id, citizenid = e.citizenid, model = e.model, plate = e.plate, name = e.name, endsAt = e.endsAt }
    end
    SaveResourceFile(GetCurrentResourceName(), CLAIM_FILE, json.encode(out), -1)
end

local function vehClaimCfg()
    local v = (Config.ContainerWars and Config.ContainerWars.vehicleClaim) or {}
    return {
        seconds = math.max(10, math.floor(tonumber(v.seconds) or 120)),
        maxDistance = tonumber(v.maxDistance) or 6.0,
        retryEvery = math.max(3, math.floor(tonumber(v.retrySeconds) or 10)),
        retries = math.max(1, math.floor(tonumber(v.retries) or 6)),
    }
end

local function claimNotify(src, data)
    if src then TriggerClientEvent('nova_convoytruck:client:hudNotify', src, data) end
end

-- remaining seconds, for the on-screen bar (the client counts down between these)
local function claimTick(c, left, done)
    TriggerClientEvent('nova_convoytruck:containerWars:client:vehicleClaimTick', -1, { containerId = c.id, left = math.max(0, math.floor(left)), done = done or nil })
end

-- the common end of a claim, once the record is safely written: no more state, no blip, the lot counts as collected
local function closeVehicleClaim(rt, c, claim)
    claim.done, claim.busy = true, false
    pendingClaims[claim.id] = nil
    savePendingClaims()
    c.rewardVehicleEntity = nil
    c.status = 'CLAIMED'
    TriggerClientEvent('nova_convoytruck:containerWars:client:rewardVehicleBlip', -1, { containerId = c.id, clear = true })
    claimTick(c, 0, true)
    TriggerClientEvent('nova_convoytruck:containerWars:client:containerClaimed', -1, { convoyId = rt.id, containerId = c.id, containerIndex = c.containerIndex })
end

-- Puts the car into the winning bidder's garage and removes the world copy (timeout, event end, container cleared). The record
-- comes FIRST and the car is deleted only after it succeeded; claim.busy / claim.done make sure it is recorded once, whoever gets here.
-- Returns true when the car is recorded (now or before).
settleVehicleClaim = function(rt, c, why)
    local claim = c and c.vehClaim
    if not claim then return false end
    if claim.done then return true end
    if claim.busy then return false end
    claim.busy = true
    local pok, ok, plateOrErr = pcall(Bridge.AddOwnedVehicle, nil, claim.model, { citizenid = c.highestBidder, plate = claim.plate, out = false })
    if not (pok and ok == true) then
        claim.busy = false
        claim.failures = (claim.failures or 0) + 1
        local err = pok and plateOrErr or ok
        log(rt.id, ('Reward car %s (plate %s) of %s could not be put in the garage (%s): %s'):format(claim.model, claim.plate, c.name or 'Container', why or '?', tostring(err)))
        if claim.failures == 1 then
            DiscordLog.appendEvent(rt.id, ('⚠️ %s — the %s could not be put in the garage of %s: %s (it is tried again)'):format(c.name or 'Container', claim.model, c.highestBidderName or 'the winner', tostring(err)))
        end
        return false
    end
    local veh = claim.entity
    claim.entity = nil
    closeVehicleClaim(rt, c, claim)
    if veh and DoesEntityExist(veh) then
        Entity(veh).state:set('cwRewardVehicle', nil, true)
        DeleteEntity(veh)
    end
    DiscordLog.appendEvent(rt.id, ('🚗 %s — the %s was put in the garage of %s (plate %s): %s'):format(c.name or 'Container', claim.model, c.highestBidderName or 'the winner', tostring(claim.plate), why or 'not claimed in time'))
    log(rt.id, ('Reward car %s (plate %s) registered to %s (%s)'):format(claim.model, claim.plate, c.highestBidderName or '?', why or '?'))
    claimNotify(resolveBidderSource(c), { type = 'success', duration = 12000, title = 'REWARD VEHICLE',
        description = ('Your %s was put in your garage (plate %s). You can take it out there.'):format(claim.label or 'car', tostring(claim.plate)) })
    return true
end

-- The confirmed winning bidder presses E at the car: keys + the normal ownership record, the car drives away from the container.
local function claimVehicleAsWinner(src, rt, c)
    local claim = c.vehClaim
    local cfg = vehClaimCfg()
    if claim.done then claimNotify(src, { type = 'error', description = 'This vehicle was already claimed.' }) return end
    if claim.busy then claimNotify(src, { type = 'inform', description = 'The vehicle is being processed...' }) return end
    local ident = Bridge.GetIdentifier(src)
    if not ident or ident ~= c.highestBidder then
        claimNotify(src, { type = 'error', description = 'Only the winning bidder can claim this vehicle.' })
        return
    end
    local veh = claim.entity
    if not (veh and DoesEntityExist(veh)) then claimNotify(src, { type = 'error', description = 'The vehicle could not be found.' }) return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or #(GetEntityCoords(ped) - GetEntityCoords(veh)) > cfg.maxDistance then
        claimNotify(src, { type = 'error', description = 'You are too far from the vehicle.' })
        return
    end

    claim.busy = true
    local pok, ok, plateOrErr, vehicleId = pcall(Bridge.AddOwnedVehicle, nil, claim.model, { citizenid = ident, plate = claim.plate, out = true })   -- it stands in the world: record says "out"
    if not (pok and ok == true) then
        claim.busy = false
        log(rt.id, ('Reward car %s (plate %s) could not be recorded for %s: %s'):format(claim.model, claim.plate, c.highestBidderName or '?', tostring(pok and plateOrErr or ok)))
        claimNotify(src, { type = 'error', description = 'The vehicle could not be registered right now. Try again.' })
        return
    end
    claim.entity = nil
    closeVehicleClaim(rt, c, claim)
    Entity(veh).state:set('cwRewardVehicle', nil, true)
    if vehicleId then Entity(veh).state:set('vehicleid', vehicleId, true) end
    FreezeEntityPosition(veh, false)
    Bridge.GiveVehicleKeys(src, veh)

    RewardService.RegisterSpawnedCar({
        entity = veh, model = claim.model, label = claim.label, plate = claim.plate, convoyId = rt.id, kind = 'CONTAINER_WARS',
        eventName = rt.def.name or 'Container Wars', containerName = c.name, winningBidder = c.highestBidderName,
        keyHolder = src, keyHolderName = Bridge.GetCharacterName(src), ownerName = c.highestBidderName, ownerSource = src,
    })
    DiscordLog.appendEvent(rt.id, ('🚗 %s — %s claimed the %s (plate %s)'):format(c.name or 'Container', c.highestBidderName or 'the winner', claim.model, tostring(claim.plate)))
    log(rt.id, ('Reward car %s (plate %s) claimed and registered to %s'):format(claim.model, claim.plate, c.highestBidderName or '?'))
    claimNotify(src, { type = 'success', duration = 10000, title = 'VEHICLE CLAIMED', description = 'The keys are yours and the vehicle is registered to you. Drive it out of the container.' })
end

-- A car-only lot has just been won: the dummy crate goes, the car appears inside the container, the claim clock starts.
-- Returns false for any other lot (the caller then uses the normal open-the-container flow).
beginVehicleClaim = function(rt, c)
    local vr = vehicleOnlyReward(c)
    if not vr or not c.highestBidder then return false end
    if c.vehClaim then return true end
    local cfg = vehClaimCfg()

    local plate = Bridge.NewPlate()
    local claim = { id = ('%s:%s'):format(tostring(rt.id), tostring(c.id)), state = 'AVAILABLE', plate = plate, model = vr.model, label = vr.pool or vr.model or 'Vehicle', endsAt = os.time() + cfg.seconds, failures = 0 }
    c.vehClaim, c.vehicleReward = claim, vr
    -- written before anything else can go wrong: from here the car is owed to the winner, whatever happens to the event or the server
    pendingClaims[claim.id] = { id = claim.id, citizenid = c.highestBidder, model = vr.model, plate = plate, name = c.highestBidderName, endsAt = claim.endsAt, live = true }
    savePendingClaims()

    setDummyCrate(c, false)
    local ent = c.containerEntity
    local drop = c.dropCoords or { x = 805.0, y = -2975.0, z = 6.0, heading = 0.0 }
    local vx, vy, vz, vh = drop.x, drop.y, (drop.z or 0.0) + 0.35, drop.heading or 0.0
    if ent and DoesEntityExist(ent) then
        Entity(ent).state:set('cwOpen', true, true)   -- a container with doors of its own stands open (a doorless one has nothing to open)
        local rewardsOutside = not modelOpens(c.bodyModel or c.model)
        local pos = entityOffset(ent, rewardsOutside and 4.0 or 0.0, 0.0, 0.35)
        vx, vy, vz = pos.x, pos.y, pos.z
        vh = GetEntityHeading(ent)
        if modelOpensAtBack(c.bodyModel or c.model) then vh = (vh + 180.0) % 360.0 end   -- facing the open end: it can drive straight out
    end
    local veh = CreateVehicle(joaat(vr.model), vx, vy, vz, vh, true, true)
    local deadline = GetGameTimer() + 4000
    while (not veh or veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < deadline do Wait(50) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        log(rt.id, ('Reward car %s could not be created for %s: it is put in the winner garage straight away'):format(tostring(vr.model), c.name or 'Container'))
        settleVehicleClaim(rt, c, 'the car could not be created')
        return true
    end
    claim.entity = veh
    c.rewardVehicleEntity = veh
    SetVehicleNumberPlateText(veh, plate)
    FreezeEntityPosition(veh, true)          -- stays exactly where it was put (inside the container) until it is claimed
    SetVehicleEngineOn(veh, false, true, true)
    Entity(veh).state:set('cwRewardVehicle', {
        convoyId = rt.id, containerId = c.id, model = vr.model, label = claim.label,
        winnerGang = c.highestBidderGangName, winnerGangLabel = c.highestBidderGang or c.highestBidderGangName,
        winnerPlayer = c.highestBidderName or 'Winner', winnerSrc = c.highestBidderSource,
        containerName = c.name, lotNumber = c.containerIndex, finalBid = c.currentBid or c.finalBid or 0,
        claimSeconds = cfg.seconds, plate = plate,
    }, true)
    local winnerSrc = resolveBidderSource(c)
    claimNotify(winnerSrc, { type = 'success', duration = 10000, title = 'VEHICLE WON',
        description = ('Your %s is inside the container. Walk up to it and press E within %d seconds, or it goes to your garage.'):format(claim.label, cfg.seconds) })
    claimTick(c, cfg.seconds)
    log(rt.id, ('Reward car %s (plate %s) is in %s: %s has %ds to claim it'):format(vr.model, plate, c.name or 'the container', c.highestBidderName or '?', cfg.seconds))

    CreateThread(function()
        local lastTick = os.time()
        while not claim.done do
            local left = claim.endsAt - os.time()
            if left <= 0 then break end
            if os.time() - lastTick >= 5 then lastTick = os.time() claimTick(c, left) end
            Wait(1000)
        end
        -- time is up (or the winner never came): the garage record, and only then the world copy goes. A refusal is tried again.
        local tries = 0
        while not claim.done and tries < cfg.retries do
            if settleVehicleClaim(rt, c, 'not claimed in time') then break end
            tries = tries + 1
            Wait(cfg.retryEvery * 1000)
        end
        if not claim.done then
            log(rt.id, ('Reward car %s (plate %s) could NOT be recorded after %d tries: it stays in the container and is tried again at the next resource start'):format(claim.model, claim.plate, tries))
            DiscordLog.appendEvent(rt.id, ('⚠️ %s — the %s (plate %s) could not be recorded for %s: an admin can use /carowner'):format(c.name or 'Container', claim.model, tostring(claim.plate), c.highestBidderName or 'the winner'))
        end
    end)
    return true
end

-- Cars that were still waiting when the resource stopped (restart, crash): put them into their owners' garages now.
CreateThread(function()
    Wait(15000)   -- the database is up by now
    while true do
        local waiting = false
        for id, e in pairs(pendingClaims) do
            if not e.live then
                waiting = true
                if Bridge.PlateOwned(e.plate) then
                    pendingClaims[id] = nil          -- it was recorded already (a claim whose bookkeeping did not finish)
                    savePendingClaims()
                else
                    local pok, ok, plateOrErr = pcall(Bridge.AddOwnedVehicle, nil, e.model, { citizenid = e.citizenid, plate = e.plate, out = false })
                    if pok and ok == true then
                        pendingClaims[id] = nil
                        savePendingClaims()
                        print(('[NovaConvoy][ContainerWars] Recovered an unclaimed reward car after a restart: %s (plate %s) is in the garage of %s'):format(tostring(e.model), tostring(e.plate), tostring(e.name or e.citizenid)))
                    else
                        print(('[NovaConvoy][ContainerWars] Could not put the unclaimed reward car %s (plate %s) in the garage of %s yet: %s'):format(tostring(e.model), tostring(e.plate), tostring(e.name or e.citizenid), tostring(pok and plateOrErr or ok)))
                    end
                end
            end
        end
        if not waiting then return end
        Wait(60000)
    end
end)

settleContainer = function(rt, c, why)
    if not c or c.settled then return end
    c.settled = true
    if c.vehClaim then return end   -- a car-only lot is settled by its own claim window
    local gangName = c.highestBidderGangName
    local function receiver()
        local src = resolveBidderSource(c)
        if not src and gangName and gangName ~= 'civilian' then src = winningGangSources(gangName)[1] end
        return src
    end
    local gang = gangName == 'civilian' and { name = 'civilian', label = 'Civilian' } or { name = gangName, label = c.highestBidderGang or gangName }

    if c.status == 'WON' then
        local src = receiver()
        if src then
            log(rt.id, ('%s was never opened — rewards paid to %s (%s)'):format(c.name or 'Container', Bridge.GetCharacterName(src) or 'winner', why or 'settle'))
            DiscordLog.appendEvent(rt.id, ('📦 %s was never opened — its rewards were paid out automatically (%s)'):format(c.name or 'Container', why or 'event ended'))
            claimContainer(src, rt, c, gang, { direct = true })
            TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'inform', duration = 9000, title = 'CONTAINER REWARDS', description = ('You did not open %s in time, so its rewards were paid to you automatically.'):format(c.name or 'your container') })
        else
            -- nobody online to pay: the car at least is recorded in the winning bidder's garage (a database entry needs no one online)
            for _, r in ipairs(c.rewards or {}) do
                if string.upper(tostring(r.type or r.rewardType or '')) == 'VEHICLE' and r.model and r.model ~= '' and c.highestBidder then
                    local okCar, plateOrErr = Bridge.AddOwnedVehicle(nil, r.model, { citizenid = c.highestBidder })
                    if okCar then
                        DiscordLog.appendEvent(rt.id, ('🚗 %s was never opened — the %s was put in the winner garage (%s, plate %s)'):format(c.name or 'Container', r.model, c.highestBidderName or '?', tostring(plateOrErr)))
                    else
                        DiscordLog.appendEvent(rt.id, ('⚠️ %s — the %s could not be put in the winner garage: %s'):format(c.name or 'Container', r.model, tostring(plateOrErr)))
                    end
                end
            end
            DiscordLog.appendEvent(rt.id, ('⚠️ %s was never opened and nobody from %s is online — its other rewards were NOT paid'):format(c.name or 'Container', c.highestBidderGang or 'the winner'))
        end
    elseif c.status == 'CLAIMED' and c.crateStash then
        local left = Inventory.GetStashItems(c.crateStash)
        if left == nil then   -- this inventory cannot be read: an opened crate counts as collected, an untouched one is paid out
            left = c.crateOpened and {} or (c.crateItems or {})
        end
        if #left > 0 then
            local src = receiver()
            if src then
                RewardService.GrantContainerReward(itemRewards(left), src, {
                    convoyId = rt.id, convoyName = rt.def.name, containerId = c.id, containerIndex = c.containerIndex,
                    containerName = c.name, gangName = gang.name, gangLabel = gang.label,
                })
                DiscordLog.appendEvent(rt.id, ('🧰 %s — items left in the crate were delivered to %s: %s'):format(c.name or 'Container', Bridge.GetCharacterName(src) or 'the winner', RewardService.describeRewards(itemRewards(left))))
                TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'inform', duration = 9000, title = 'LOOT CRATE', description = ('You left items in the crate of %s. They were put into your inventory.'):format(c.name or 'your container') })
            else
                DiscordLog.appendEvent(rt.id, ('⚠️ %s — items left in the crate could not be delivered (nobody from %s online): %s'):format(c.name or 'Container', c.highestBidderGang or 'the winner', RewardService.describeRewards(itemRewards(left))))
            end
        end
        Inventory.ClearStash(c.crateStash)
        c.crateStash = nil
    end
end

-- A winner searches the loot crate inside the container they opened.
RegisterNetEvent('nova_convoytruck:containerWars:server:openCrate', function(convoyId, containerId)
    local src = source
    local rt = active[convoyId]
    local c = rt and findContainer(rt, containerId)
    if not c or (c.status ~= 'OPENED' and c.status ~= 'CLAIMED') then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'There is nothing in this crate.' })
        return
    end
    local isCivWinner = c.highestBidderGangName == 'civilian' and c.highestBidder == Bridge.GetIdentifier(src)
    local gang = GangService and GangService.GetPlayerGang(src)
    if not isCivWinner and (Bridge.IsPolice(src) or not gang or gang.name ~= c.highestBidderGangName) then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'This crate belongs to the winning bidder\'s gang.' })
        return
    end
    local cc = c.dropCoords
    local ped = GetPlayerPed(src)
    local openCfg = (Config.ContainerWars and Config.ContainerWars.openContainer) or {}
    if not cc or not ped or ped == 0 or #(GetEntityCoords(ped) - vector3(cc.x, cc.y, cc.z)) > (tonumber(openCfg.maxDistance) or 9.0) + 4.0 then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'You are too far from the crate.' })
        return
    end

    -- a crate search is one at a time: a second press while the first is being paid would pay twice
    if c.crateBusy then return end
    c.crateBusy = true

    c.crateOpened = true
    local rewardsToPay = c.crateRewards or c.rewards or {}
    c.crateRewards = nil
    c.status = 'CLAIMED'

    local ent = c.containerEntity
    local crateInfo = ent and DoesEntityExist(ent) and Entity(ent).state.cwCrate or nil
    if ent and DoesEntityExist(ent) then Entity(ent).state:set('cwCrate', nil, true) end

    local leftovers = claimContainer(src, rt, c, gang or { name = 'civilian', label = 'Civilian' }, { direct = true, rewards = rewardsToPay, keepLeftovers = true })
    if type(leftovers) == 'table' and #leftovers > 0 then
        -- the inventory was full: what did not fit stays in the crate until the winner has made room
        c.crateOpened = false
        c.crateRewards = leftovers
        c.status = 'OPENED'
        if ent and DoesEntityExist(ent) and crateInfo then Entity(ent).state:set('cwCrate', crateInfo, true) end
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', duration = 9000, title = 'CRATE NOT EMPTY', description = 'Some of the loot did not fit in your inventory. It is still in the crate: make room and search it again.' })
    else
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'success', duration = 8000, title = 'LOOT SECURED', description = 'You collected the rewards from the container crate!' })
    end
    c.crateBusy = nil
end)

-- Claiming a won reward vehicle: warps player in, teleports to exit staging area, gives keys, logs for /carowner
RegisterNetEvent('nova_convoytruck:containerWars:server:claimVehicle', function(convoyId, containerId)
    local src = source
    local rt = active[convoyId]
    if not rt then return end
    local c = findContainer(rt, containerId)
    if not c then return end
    if c.vehClaim then claimVehicleAsWinner(src, rt, c) return end

    local isCivWinner = c.highestBidderGangName == 'civilian' and c.highestBidder == Bridge.GetIdentifier(src)
    local gang = GangService and GangService.GetPlayerGang(src)
    if not isCivWinner and (Bridge.IsPolice(src) or not gang or gang.name ~= c.highestBidderGangName) then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'Only members of the winning gang can claim this vehicle.' })
        return
    end

    local veh = c.rewardVehicleEntity
    if not veh or not DoesEntityExist(veh) then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'Reward vehicle not found or already claimed.' })
        return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    Entity(veh).state:set('cwRewardVehicle', nil, true)
    c.rewardVehicleEntity = nil
    TriggerClientEvent('nova_convoytruck:containerWars:client:rewardVehicleBlip', -1, { containerId = c.id, clear = true })

    -- Warp ped into driver seat if not already in vehicle
    if GetVehiclePedIsIn(ped, false) ~= veh then
        SetPedIntoVehicle(ped, veh, -1)
        Wait(150)
    end

    -- Teleport vehicle and ped to safe staging location away from the crane
    local safeCoords = findSafeStagingCoords(rt, ped)
    SetEntityCoords(veh, safeCoords.x + 0.0, safeCoords.y + 0.0, safeCoords.z + 0.0, false, false, false, true)
    SetEntityHeading(veh, (safeCoords.heading or 90.0) + 0.0)
    FreezeEntityPosition(veh, false)

    -- Give keys to player
    Bridge.GiveVehicleKeys(src, veh)

    -- Register in RewardService.SpawnedCars for /carowner
    local vehReward = c.vehicleReward or {}
    local plate = GetVehicleNumberPlateText(veh)
    local entry = {
        entity = veh,
        model = vehReward.model or 'vehicle',
        label = vehReward.pool or vehReward.model or 'Vehicle',
        plate = plate,
        convoyId = rt.id,
        kind = 'CONTAINER_WARS',
        eventName = rt.def.name or 'Container Wars',
        containerName = c.name,
        winningBidder = c.highestBidderName,
        keyHolder = src,
        keyHolderName = Bridge.GetCharacterName(src),
    }
    RewardService.RegisterSpawnedCar(entry)

    -- the car is the winning bidder's: player database + garage record (state out, it stands in the world), no admin needed
    local owned, ownedPlate, vehicleId = ownRewardVehicle(c, veh, true)
    if owned then
        entry.ownerName = c.highestBidderName   -- so /carowner does not offer it again
        entry.ownerSource = c.highestBidderSource or 0
        if vehicleId then Entity(veh).state:set('vehicleid', vehicleId, true) end
        log(rt.id, ('Reward car %s (plate %s) recorded as owned by %s'):format(entry.model, tostring(ownedPlate), c.highestBidderName or '?'))
    else
        log(rt.id, ('Reward car %s could not be recorded as owned: %s (an admin can use /carowner)'):format(entry.model, tostring(ownedPlate)))
    end

    if not c.crateRewards or #c.crateRewards == 0 then
        c.status = 'CLAIMED'
        TriggerClientEvent('nova_convoytruck:containerWars:client:containerClaimed', -1, {
            convoyId = rt.id,
            containerId = c.id,
            containerIndex = c.containerIndex,
        })
    end

    TriggerClientEvent('nova_convoytruck:client:hudNotify', src, {
        type = 'success',
        duration = 10000,
        title = 'VEHICLE CLAIMED',
        description = owned and ('You are in the vehicle at the staging area. It is registered to %s and is in the garage records.'):format(c.highestBidderName or 'the winning bidder')
            or 'You are now in the vehicle at the staging area! Its ownership could not be recorded: an admin can use /carowner.',
    })
end)

-- ── Opening a won container ─────────────────────────────────────────────────────
-- A member of the winning gang walks up to the container and uses ox_target
-- "Open Container". The server checks the gang and the distance, tells every
-- client to swing the doors open (and the opener to play the animation), waits for
-- it to finish, then prepares the crate / car for claiming.
RegisterNetEvent('nova_convoytruck:containerWars:server:openContainer', function(convoyId, containerId)
    local src = source
    local rt = active[convoyId]
    if not rt then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'Event is no longer active.' })
        return
    end

    local targetCont = nil
    for _, c in ipairs(rt.containers or {}) do
        if c.id == containerId then targetCont = c break end
    end
    if not targetCont then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'Container not found.' })
        return
    end
    if targetCont.status ~= 'WON' then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'This container is already being opened, was opened, or was not sold.' })
        return
    end

    local gang = GangService and GangService.GetPlayerGang(src)
    local isCivWinner = targetCont.highestBidderGangName == 'civilian' and targetCont.highestBidder == Bridge.GetIdentifier(src)
    if not isCivWinner then
        if Bridge.IsPolice(src) or not gang or gang.name ~= targetCont.highestBidderGangName then
            TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'Only members of the winning gang can open this container.' })
            return
        end
    else
        gang = { name = 'civilian', label = 'Civilian' }
    end

    local openCfg = (Config.ContainerWars and Config.ContainerWars.openContainer) or {}
    local maxDistance = tonumber(openCfg.maxDistance) or 9.0
    local cc = targetCont.dropCoords
    local function opennerDistance()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 or not cc then return math.huge end
        return #(GetEntityCoords(ped) - vector3(cc.x, cc.y, cc.z))
    end
    if opennerDistance() > maxDistance then
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'You are too far from the container.' })
        return
    end

    targetCont.status = 'OPENING_DOORS' -- nobody else can start it meanwhile
    local seconds = tonumber(openCfg.durationSeconds) or 4.5
    local netId = (targetCont.containerEntity and DoesEntityExist(targetCont.containerEntity)) and NetworkGetNetworkIdFromEntity(targetCont.containerEntity) or nil
    log(rt.id, ('%s (%s) is opening Container #%d'):format(Bridge.GetCharacterName(src) or 'Player', gang.name, targetCont.containerIndex or 0))
    DiscordLog.appendEvent(rt.id, ('🔓 %s (%s) is opening %s'):format(Bridge.GetCharacterName(src) or 'Player', gang.label or gang.name, targetCont.name))

    -- The doors open on the container itself (every client with it in range sees them swing; one that streams in later
    -- finds them already open, because the state is kept on the container).
    -- 'cwOpen' is set once the opening has really succeeded (below), not here: it is the "this container IS open, keep it open" flag
    -- that every client holds the opened pose from, so it must not appear while the lock is still being cut (or if it is cancelled).
    local ent = targetCont.containerEntity
    TriggerClientEvent('nova_convoytruck:containerWars:client:openSequence', -1, {
        convoyId = rt.id,
        containerId = targetCont.id,
        containerNetId = netId,
        coords = cc,
        opener = src,
        seconds = seconds,
    })

    -- The opener's client reports when the clip has really finished (the server cannot know its length): never before half the
    -- configured time (a hacked client cannot open it at once), and never later than seconds + 8 if the report does not come.
    local now = GetGameTimer()
    local minAt, maxAt = now + math.floor(seconds * 500), now + math.floor((seconds + 8) * 1000)
    targetCont.openOpener, targetCont.openDone = src, false
    while GetGameTimer() < maxAt and not (targetCont.openDone and GetGameTimer() >= minAt) do Wait(100) end
    targetCont.openOpener, targetCont.openDone = nil, nil
    if not active[convoyId] then return end
    if targetCont.status ~= 'OPENING_DOORS' then return end   -- settled / cancelled meanwhile: never pay twice

    -- The opener has to still be there (not dead, disconnected or driven away) when the doors are open.
    if opennerDistance() > maxDistance + 4.0 or (GetEntityHealth(GetPlayerPed(src)) or 0) <= 0 then
        targetCont.status = 'WON'
        if ent and DoesEntityExist(ent) then Entity(ent).state:set('cwOpen', nil, true) end
        TriggerClientEvent('nova_convoytruck:containerWars:client:openCancelled', -1, { containerId = targetCont.id })
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'error', description = 'You left the container — opening cancelled.' })
        return
    end

    targetCont.status = 'OPENED'
    -- the container stays open from now on: its doors are held open on every client (and for anyone who streams it in later)
    if ent and DoesEntityExist(ent) then Entity(ent).state:set('cwOpen', true, true) end
    local charName = Bridge.GetCharacterName(src)
    local rewards = targetCont.rewards or {}
    local vehReward = nil
    local otherRewards = {}
    for _, r in ipairs(rewards) do
        local rType = string.upper(tostring(r.type or r.rewardType or ''))
        if rType == 'VEHICLE' then vehReward = r else otherRewards[#otherRewards + 1] = r end
    end

    -- a container whose doors do not open: the rewards stand beside it, where they can be reached
    local rewardsOutside = not modelOpens(targetCont.bodyModel or targetCont.model)

    -- 1. Vehicle reward: spawn vehicle cleanly inside the container interior
    if vehReward and vehReward.model and vehReward.model ~= '' then
        local drop = targetCont.dropCoords or { x = 805.0, y = -2975.0, z = 6.0, heading = 0.0 }
        local vx, vy, vz, vHeading = drop.x, drop.y, (drop.z or 0.0) + 0.35, drop.heading or 0.0
        if ent and DoesEntityExist(ent) then
            local offsetPos = entityOffset(ent, rewardsOutside and 4.0 or 0.0, 0.0, 0.35)
            vx, vy, vz = offsetPos.x, offsetPos.y, offsetPos.z
            vHeading = GetEntityHeading(ent)
            -- face the open end, so the winner can drive straight out
            if modelOpensAtBack(targetCont.bodyModel or targetCont.model) then vHeading = (vHeading + 180.0) % 360.0 end
        end
        local veh = CreateVehicle(joaat(vehReward.model), vx, vy, vz, vHeading, true, true)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            targetCont.rewardVehicleEntity = veh
            targetCont.vehicleReward = vehReward
            SetVehicleNumberPlateText(veh, Bridge.NewPlate())
            Entity(veh).state:set('cwRewardVehicle', {
                convoyId = rt.id,
                containerId = targetCont.id,
                model = vehReward.model,
                label = vehReward.pool or vehReward.model or 'Vehicle',
                winnerGang = gang.name,
                winnerGangLabel = gang.label or gang.name,
                winnerPlayer = charName or targetCont.highestBidderName or 'Winner',
                containerName = targetCont.name,
                lotNumber = targetCont.containerIndex,
                finalBid = targetCont.currentBid or targetCont.finalBid or 0,
            }, true)
            TriggerClientEvent('nova_convoytruck:client:hudNotify', src, {
                type = 'success',
                title = 'VEHICLE REWARD',
                duration = 8000,
                description = 'The container is open! Use ox_target on the vehicle inside to claim and drive it.',
            })
        end
    end

    -- 2. Money / item / token rewards: spawn loot crate inside container
    if #otherRewards > 0 then
        targetCont.crateRewards = otherRewards
        local crateOffset = nil
        if vehReward and vehReward.model and vehReward.model ~= '' then
            -- Both vehicle and crate loot configured: safely place the crate outside near the entrance so they don't collide
            crateOffset = { x = 2.4, y = -3.2, z = 0.0 }
        end
        if rewardsOutside then
            crateOffset = { x = (vehReward and vehReward.model and vehReward.model ~= '') and -3.2 or 3.2, y = 0.0, z = 0.0 }
        end
        if ent and DoesEntityExist(ent) then
            Entity(ent).state:set('cwCrate', {
                convoyId = rt.id,
                containerId = targetCont.id,
                label = 'Claim Container Rewards',
                offset = crateOffset,
            }, true)
        end
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, {
            type = 'success',
            title = 'LOOT CRATE',
            duration = 8000,
            description = 'The container is open! Search the loot crate inside to collect your rewards.',
        })
    end

    if not vehReward and #otherRewards == 0 then
        targetCont.status = 'CLAIMED'
        TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { type = 'inform', description = 'Container opened (no loot configured).' })
    end
end)

-- /cwopenanim results from an admin's client, written to the server console
RegisterNetEvent('nova_convoytruck:containerWars:server:logOpenTest', function(lines)
    local src = source
    if not IsPlayerAceAllowed(src, 'command') or type(lines) ~= 'table' then return end
    for i = 1, math.min(#lines, 60) do
        print(('[NovaConvoy][container test] %s'):format(tostring(lines[i]):sub(1, 200)))
    end
end)

-- The opener's client: the opening clip has finished (see the wait in the open handler above).
RegisterNetEvent('nova_convoytruck:containerWars:server:openDone', function(convoyId, containerId)
    local rt = active[convoyId]
    local c = rt and findContainer(rt, containerId)
    if c and c.status == 'OPENING_DOORS' and c.openOpener == source then c.openDone = true end
end)
