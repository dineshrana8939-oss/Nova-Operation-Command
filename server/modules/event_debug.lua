-- ─── Event debug (admin) — every event kind ───────────────────────────────────────────
-- /eventdebug                 watch every running event: phase, timers, scores, players, and a warning when one stops progressing
-- /eventdebug off            stop watching
-- /eventdebug check          pre-flight check of ALL events' set-up (zone, spawns, gangs, vendors, routes ...) — no event needs to run
-- /eventdebug check <id>     the same for one event (the id shown on its card in Manage Events)
-- /eventdebug status         one-off snapshot of everything running right now (events, tournaments, rival wars)
--
-- Works for Convoy, Hot Cargo, Gang Airdrop, Gang Rally, TDM (and its tournaments), Container Wars, Territory Auction and
-- Rival Wars. The convoy route view stays /convoydebug. Everything here only READS the running state; it never changes how an
-- event plays. Output goes to the admin's F8 console, the server console, and one short notification with the totals.

EventDebug = {}

local watchers = {}     -- [src] = true
local progress = {}     -- [key] = { sig, since, warned }
local lastBlock = 0

local function cfg() return Config.EventDebug or {} end

local function isAdmin(src)
    return Bridge.IsAdmin(src, Config.CreatorAccess and Config.CreatorAccess.adminPermission)
end

local function notify(src, text, kind)
    TriggerClientEvent('nova_convoytruck:client:hudNotify', src, { title = 'Event debug', description = text, type = kind or 'inform', duration = 7000 })
end

local COLOR = { ok = '^2', warn = '^3', bad = '^1', info = '^7' }
local MARK = { ok = 'OK  ', warn = 'WARN', bad = 'FAIL', info = '    ' }

-- lines = { { level, text }, ... }  ->  console + the admin's F8, and the totals as a notification
local function emit(src, title, lines)
    local bad, warn = 0, 0
    print(('^5[EventDebug] %s^0'):format(title))
    for _, l in ipairs(lines) do
        if l[1] == 'bad' then bad = bad + 1 elseif l[1] == 'warn' then warn = warn + 1 end
        print(('%s[EventDebug]  %s  %s^0'):format(COLOR[l[1]] or '', MARK[l[1]] or '    ', l[2]))
    end
    if src and src > 0 then
        TriggerClientEvent('nova_convoytruck:debug:eventLines', src, title, lines)
        if bad > 0 then notify(src, ('%s: %d problem(s), %d warning(s). Details in F8.'):format(title, bad, warn), 'error')
        elseif warn > 0 then notify(src, ('%s: %d warning(s). Details in F8.'):format(title, warn), 'warning')
        else notify(src, ('%s: nothing wrong found.'):format(title), 'success') end
    end
end

-- ── pre-flight checks ───────────────────────────────────────────────────────────────────

local function add(list, level, text) list[#list + 1] = { level, text } end
local function placed(p) return type(p) == 'table' and tonumber(p.x) ~= nil and tonumber(p.y) ~= nil and not (tonumber(p.x) == 0 and tonumber(p.y) == 0) end
local function count(t) return type(t) == 'table' and #t or 0 end

local function gangExists(name)
    if not name or name == '' then return false end
    local ok, g = pcall(GangService.GetGangByName, name)
    return ok and g ~= nil
end

local function checkCommon(def, out)
    if not def.name or #tostring(def.name) < 3 then add(out, 'bad', 'The event needs a name (3+ characters).') end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' and def.status ~= 'COMPLETED' and def.status ~= 'CANCELLED' and def.status ~= nil then
        add(out, 'info', ('Status is %s (it is running or finished).'):format(tostring(def.status)))
    end
    if def.reward and #def.reward == 0 and def.kind ~= 'TDM' then add(out, 'warn', 'No reward is configured.') end
end

local function checkTdm(def, out)
    local t = def.tdm or {}
    local format = tostring(t.matchFormat or 'STANDARD'):upper()
    if not t.zone or count(t.zone.points) < 3 then add(out, 'bad', 'Combat zone: draw a polygon with at least 3 points (Match Setup tab).') else add(out, 'ok', ('Combat zone has %d points.'):format(#t.zone.points)) end
    local shared, red, blue = count(t.spawnPoints), count(t.spawnPointsRed), count(t.spawnPointsBlue)
    local zr = (t.respawnZoneRed and count(t.respawnZoneRed.points) >= 3) and 1 or 0
    local zb = (t.respawnZoneBlue and count(t.respawnZoneBlue.points) >= 3) and 1 or 0
    if zr + zb > 0 then add(out, 'ok', ('Team base perimeters drawn: %s - those teams spawn spread inside them.'):format((zr == 1 and zb == 1) and 'red and blue' or (zr == 1 and 'red' or 'blue'))) end
    if shared + red + blue + zr + zb == 0 then add(out, 'bad', 'No respawn / spawn points are placed and no team base perimeter is drawn.')
    else
        add(out, 'ok', ('Spawn points: %d shared, %d red, %d blue.'):format(shared, red, blue))
        if red == 0 or blue == 0 then add(out, 'warn', 'One team has no spawn point of its own; it uses the shared list.') end
    end
    if t.stagingZone and t.stagingZone.enabled then
        if count(t.stagingZone.points) < 3 then add(out, 'bad', 'The staging zone is ON but has fewer than 3 points - the match can never leave staging.')
        else add(out, 'ok', ('Staging zone on: %d points, %d players per team needed to start.'):format(#t.stagingZone.points, tonumber(t.stagingZone.requiredPerTeam) or 10)) end
    end
    local vendorRed = placed(t.weaponVendorRed) or placed(t.weaponVendor)
    local vendorBlue = placed(t.weaponVendorBlue) or placed(t.weaponVendor)
    if not vendorRed or not vendorBlue then add(out, 'warn', 'A weapon vendor is not placed for ' .. ((not vendorRed and not vendorBlue) and 'either team' or (not vendorRed and 'Team Red' or 'Team Blue')) .. ' (players cannot buy weapons there).') end
    local weapons = count(t.weapons)
    if weapons == 0 and not (Config.TDM and Config.TDM.weaponVendor and count(Config.TDM.weaponVendor.items) > 0) then add(out, 'warn', 'No weapon catalogue (event or Config.TDM.weaponVendor.items).') end
    add(out, 'info', ('Duration %ds, kill limit %s, format %s.'):format(tonumber(t.duration) or 600, (tonumber(t.killLimit) or 0) > 0 and tostring(t.killLimit) or 'none', format))
    if format == 'TOURNAMENT' then
        add(out, 'info', 'Tournament format: this is only the arena template; start it from the Tournaments tab.')
        local used = false
        local ok, list = pcall(Tournament.debugSummary)
        if ok then for _, ti in ipairs(list) do if ti.templateId == def.id then used = true end end end
        if not used then add(out, 'warn', 'No tournament uses this arena yet.') end
    else
        local ag = def.settings and def.settings.allowedGangs
        local gangs = (ag and ag.mode == 'SELECTED') and (ag.gangs or {}) or {}
        local gA = (t.teamRedGang and t.teamRedGang ~= '') and t.teamRedGang or gangs[1]
        local gB = (t.teamBlueGang and t.teamBlueGang ~= '') and t.teamBlueGang or gangs[2]
        if not gA or not gB or gA == gB then add(out, 'bad', 'Standard TDM needs two DIFFERENT gangs (Team Red and Team Blue).')
        else
            for _, g in ipairs({ gA, gB }) do
                if not gangExists(g) then add(out, 'bad', ('Gang "%s" does not exist.'):format(g))
                else
                    local n = count(def.roster and def.roster[g])
                    add(out, n > 0 and 'ok' or 'bad', ('%s: %d registered roster member(s)%s.'):format(g, n, n == 0 and ' - the match refuses to start with an empty side' or ''))
                end
            end
        end
    end
end

local function checkTerritory(def, out)
    local tcfg = def.territory or {}
    local a = tcfg.auction or {}
    local areas = tcfg.areas or {}
    if #areas == 0 then add(out, 'bad', 'No territory is defined (Territories tab).') else add(out, 'ok', ('%d territory area(s).'):format(#areas)) end
    if not placed(a.location) then add(out, 'warn', 'Auction house location is not placed (gangs cannot open the bidding window).') end
    if count(a.zonePoints) < 3 then add(out, 'warn', 'Bidding perimeter has fewer than 3 points.') end
    if not a.projector or not placed(a.projector) then add(out, 'warn', 'The auction projector prop is not placed (Prop Placer, context territory_projector).') end
    if a.date == '' or a.startTime == '' then add(out, 'info', 'Auction date / start time not set (fine when you start it by hand).') end
    for _, ar in ipairs(areas) do
        local pre = ('"%s": '):format(ar.name or ar.id)
        local cells = (ar.base and TerritoryGeo.count(ar.base.spans)) or 0
        if cells == 0 then add(out, 'bad', pre .. 'no painted area (base is empty).') end
        if not placed(ar.location) and cells == 0 then add(out, 'warn', pre .. 'no location.') end
        if ar.capture and ar.capture.enabled ~= false and not (ar.capture.ped and ar.capture.ped.x) then add(out, 'warn', pre .. 'war capture ped is not placed (rival wars cannot be fought here).') end
        if ar.startingOwner and ar.startingOwner ~= '' and not gangExists(ar.startingOwner) then add(out, 'bad', pre .. ('starting owner "%s" does not exist.'):format(ar.startingOwner)) end
    end
    local gangs = 0
    for _ in ipairs(GangService.GetGangs() or {}) do gangs = gangs + 1 end
    if gangs < 2 then add(out, 'warn', 'Fewer than 2 gangs exist: an auction has nobody to bid against and a rival war has no opponent.') end
end

local function checkHotCargo(def, out)
    local hc = def.hotCargo or {}
    local zones, validZones = hc.spawnZones or {}, 0
    for _, z in ipairs(zones) do if placed(z) then validZones = validZones + 1 end end
    local drops, validDrops = hc.dropoffZones or {}, 0
    for _, d in ipairs(drops) do if placed(d) then validDrops = validDrops + 1 end end
    if #(hc.trucks or {}) == 0 then add(out, 'bad', 'No cargo truck is added.') else add(out, 'ok', ('%d cargo truck(s).'):format(#hc.trucks)) end
    if validDrops == 0 then add(out, 'bad', 'No dropoff zone is placed.') else add(out, 'ok', ('%d dropoff zone(s) placed.'):format(validDrops)) end
    local random = 0
    for _, t in ipairs(hc.trucks or {}) do
        if t.mode == 'MANUAL' then
            if not placed(t) then add(out, 'bad', ('Manual truck "%s" is not placed.'):format(t.name or '?')) end
        else random = random + 1 end
        if (t.model or '') == '' then add(out, 'bad', ('Truck "%s" has no vehicle model.'):format(t.name or '?')) end
    end
    if random > 0 and validZones < random then add(out, 'bad', ('%d random truck(s) but only %d placed spawn zone(s).'):format(random, validZones)) end
    if validZones > 0 then add(out, 'ok', ('%d spawn zone(s) placed.'):format(validZones)) end
end

local function checkAirdrop(def, out)
    local zones, ok = def.airdropZones or {}, 0
    for _, z in ipairs(zones) do if placed(z) then ok = ok + 1 end end
    if #zones == 0 then add(out, 'bad', 'No drop zone is added.')
    elseif ok < #zones then add(out, 'bad', ('%d of %d drop zones are not placed.'):format(#zones - ok, #zones))
    else add(out, 'ok', ('%d drop zone(s) placed.'):format(ok)) end
    if def.settings and def.settings.gangPvp == false then add(out, 'warn', 'Gang PvP is off: the event requires it on.') end
end

local function checkRally(def, out)
    local stages = def.rallyStages or {}
    local unplaced, hasStart, hasFinish = 0, false, false
    for _, s in ipairs(stages) do
        if not placed(s) then unplaced = unplaced + 1 end
        if s.kind == 'START' then hasStart = true elseif s.kind == 'DESTINATION' then hasFinish = true end
    end
    if #stages < 2 then add(out, 'bad', 'A race needs at least a start and a finish.') else add(out, 'ok', ('%d stage(s).'):format(#stages)) end
    if unplaced > 0 then add(out, 'bad', ('%d stage(s) are not placed.'):format(unplaced)) end
    if not hasStart then add(out, 'warn', 'No stage is marked Start.') end
    if not hasFinish then add(out, 'warn', 'No stage is marked Finish.') end
end

local function checkConvoy(def, out)
    local route = def.route or {}
    local hasStart, hasDest, cps, unplaced = false, false, 0, 0
    for _, p in ipairs(route) do
        if p.type == 'START' then hasStart = true elseif p.type == 'DESTINATION' then hasDest = true elseif p.type == 'CHECKPOINT' then cps = cps + 1 end
        if not placed(p) then unplaced = unplaced + 1 end
    end
    if #route < 2 then add(out, 'bad', 'The route needs at least two points.') else add(out, 'ok', ('Route: %d points, %d checkpoint(s).'):format(#route, cps)) end
    if not hasStart then add(out, 'warn', 'The route has no START point.') end
    if not hasDest then add(out, 'bad', 'The route has no DESTINATION point.') end
    if unplaced > 0 then add(out, 'bad', ('%d route point(s) are not placed.'):format(unplaced)) end
    if #(def.trucks or {}) == 0 then add(out, 'bad', 'No convoy truck is added.') else add(out, 'ok', ('%d truck(s).'):format(#def.trucks)) end
    add(out, 'info', 'To see whether the trucks can really drive the route use /convoydebug while it runs.')
end

local function checkContainerWars(def, out)
    local cw = def.containerWars or {}
    local lots = count(cw.containers)
    if lots == 0 then add(out, 'bad', 'No container lot is added.') else add(out, 'ok', ('%d container lot(s).'):format(lots)) end
    local harbour = (Config.ContainerWars or {}).harbour
    if not harbour then add(out, 'warn', 'Config.ContainerWars.harbour is missing (crane / yard).')
    else
        if count(harbour.pickups) == 0 then add(out, 'warn', 'The yard has no container pickup spots (/cwspot) - lots cannot be placed.') end
        if not harbour.crane then add(out, 'warn', 'The yard has no crane set up.') end
    end
    if cw.zone and count(cw.zone.points) > 0 and count(cw.zone.points) < 3 then add(out, 'warn', 'The bidding zone has fewer than 3 points.') end
end

local function checkCrackdown(def, out)
    local cd = def.crackdown or {}
    if not cd.targetGang or cd.targetGang == '' then add(out, 'bad', 'No target gang is set (Operation Setup).')
    elseif not DB.getGangByName(cd.targetGang) then add(out, 'bad', ('The target gang "%s" does not exist.'):format(cd.targetGang)) end
    if not (cd.zone and cd.zone.center and cd.zone.center.x) then add(out, 'bad', 'The combat zone is not placed (Combat Zone).') end
    if (tonumber(def.eventDuration) or 0) < 60 then add(out, 'bad', 'The duration is under one minute.') end
    if (tonumber(cd.outsideSeconds) or 0) < 5 then add(out, 'warn', 'The time allowed outside the zone is under 5 seconds.') end
    if not def.reward or #def.reward == 0 then add(out, 'warn', 'No gang reward is set (the winning gang is paid nothing).') end
    if not cd.policeReward or #cd.policeReward == 0 then add(out, 'info', 'No police reward is set.') end
end

local CHECKS = {
    CRACKDOWN = checkCrackdown, TDM = checkTdm, GANG_TERRITORY = checkTerritory, HOT_CARGO = checkHotCargo, GANG_AIRDROP = checkAirdrop,
    GANG_RACE = checkRally, CONVOY = checkConvoy, CONTAINER_WARS = checkContainerWars,
}

local KIND_LABEL = {
    CRACKDOWN = 'Operation Crackdown', TDM = 'TDM', GANG_TERRITORY = 'Territory Auction', HOT_CARGO = 'Hot Cargo', GANG_AIRDROP = 'Gang Airdrop',
    GANG_RACE = 'Gang Rally', CONVOY = 'Convoy', CONTAINER_WARS = 'Container Wars',
}

function EventDebug.check(def)
    local out = {}
    local ok, err = pcall(function()
        checkCommon(def, out)
        local fn = CHECKS[def.kind or 'CONVOY'] or checkConvoy
        fn(def, out)
    end)
    if not ok then add(out, 'bad', 'The check itself failed: ' .. tostring(err)) end
    return out
end

-- ── live snapshots ───────────────────────────────────────────────────────────────────────

local function mmss(s) s = math.max(0, math.floor(tonumber(s) or 0)); return ('%d:%02d'):format(s // 60, s % 60) end

-- one progress key per event: the same signature for 30 s while it should be moving = a warning
local function stall(key, sig, out, what)
    local p = progress[key]
    if not p or p.sig ~= sig then progress[key] = { sig = sig, since = os.time() } return end
    if os.time() - p.since >= 30 and not p.warned then
        p.warned = true
        add(out, 'bad', ('No progress for %d s (%s). The event looks stuck.'):format(os.time() - p.since, what))
    end
end

local function runtimeLines(id, def, out)
    local rt = nil
    pcall(function() rt = Runtime.get(id) end)
    local kind = def and def.kind or '?'
    local name = def and def.name or ('#' .. tostring(id))
    local head = ('%s #%s "%s"'):format(KIND_LABEL[kind] or kind, tostring(id), name)
    if kind == 'TDM' then
        local s = Tdm.debugState(id)
        if not s then return end
        add(out, 'info', ('%s - %s%s | %s %d : %d %s | time left %s%s | online A %d/%d, B %d/%d'):format(head, s.phase, s.tournament and (' [' .. s.tournament .. ']') or '',
            tostring(s.gangA), s.scoreA or 0, s.scoreB or 0, tostring(s.gangB), mmss(s.timeRemaining), (s.killLimit or 0) > 0 and (' | kill limit ' .. s.killLimit) or '', s.aOn, s.aTotal, s.bOn, s.bTotal))
        if s.phase == 'STAGING' then
            add(out, 'info', ('    staging: need %s per team%s'):format(tostring(s.stagingRequired), s.stagingCountdown and (', countdown ' .. s.stagingCountdown) or ''))
            stall('tdm' .. id, 'STAGING', out, 'waiting in the staging zone; both teams need enough players inside')
        elseif s.phase == 'ACTIVE' then
            stall('tdm' .. id, tostring(s.timeRemaining), out, 'the match timer is not counting down')
            if s.aOn == 0 or s.bOn == 0 then add(out, 'warn', 'One side has nobody online: the match should end as a forfeit.') end
        else
            stall('tdm' .. id, tostring(s.phase), out, 'phase ' .. tostring(s.phase))
        end
        return
    end
    if kind == 'CONTAINER_WARS' then
        local ok, st = pcall(ContainerWars.getPublicState, id)
        if ok and st then
            add(out, 'info', ('%s - %s'):format(head, (json.encode(st) or ''):sub(1, 260)))
            stall('cw' .. id, tostring(st.status) .. tostring(st.timeRemaining or st.deliveryTimeRemaining or ''), out, 'status/timer unchanged')
        end
        return
    end
    if kind == 'CRACKDOWN' then
        local ok, st = pcall(Crackdown.getPublicState, id)
        if ok and st then
            add(out, 'info', ('%s - %s'):format(head, (json.encode(st) or ''):sub(1, 260)))
            stall('cd' .. id, tostring(st.crackdown and st.crackdown.phase) .. tostring(st.deliveryTimeRemaining or ''), out, 'phase / timer unchanged')
        end
        return
    end
    if kind == 'GANG_TERRITORY' then
        local ok, st = pcall(TerritoryAuction.getPublicState, id)
        if ok and st then
            local s = st.territory and st or st
            add(out, 'info', ('%s - %s'):format(head, (json.encode(s) or ''):sub(1, 260)))
            stall('ta' .. id, tostring(st.status) .. tostring(st.deliveryTimeRemaining or ''), out, 'auction state unchanged')
        else
            local ap = nil
            pcall(function() ap = TerritoryAuction.get(id) end)
            if ap then
                add(out, 'info', ('%s - phase %s, ends in %s s, projector %s'):format(head, tostring(ap.phase), tostring(math.max(0, (ap.deadline or 0) - os.time())), ap.projectorLive and 'LIVE' or 'not spawned'))
                stall('ta' .. id, tostring(ap.phase) .. tostring(ap.deadline), out, 'auction phase and deadline unchanged')
            end
        end
        return
    end
    if not rt then return end
    local gangs, police = 0, 0
    for _ in pairs(rt.participants and rt.participants.identifiers or {}) do gangs = gangs + 1 end
    for _ in pairs(rt.participants and rt.participants.policeIdentifiers or {}) do police = police + 1 end
    local extra = ''
    if kind == 'HOT_CARGO' then
        local total, hij, deliv, destroyed = 0, 0, 0, 0
        for _, t in pairs(rt.trucks or {}) do
            total = total + 1
            if t.hijacked then hij = hij + 1 end
            if t.delivered then deliv = deliv + 1 end
            if t.destroyed then destroyed = destroyed + 1 end
        end
        extra = (' | trucks %d (hijacked %d, delivered %d, destroyed %d)'):format(total, hij, deliv, destroyed)
    elseif kind == 'GANG_AIRDROP' then
        local n = 0
        for _ in pairs(rt.airdrops or {}) do n = n + 1 end
        extra = (' | drop zones %d, anything looted: %s'):format(n, tostring(rt.anyZoneLooted == true))
    elseif kind == 'CONVOY' then
        local total, delivered, destroyed = 0, 0, 0
        for _, t in pairs(rt.trucks or {}) do
            total = total + 1
            if t.delivered then delivered = delivered + 1 end
            if t.destroyed then destroyed = destroyed + 1 end
        end
        extra = (' | trucks %d (delivered %d, destroyed %d), route point %s/%s'):format(total, delivered, destroyed, tostring(rt.currentRouteIndex or 0), tostring(rt.route and #rt.route or 0))
    end
    add(out, 'info', ('%s - %s | gang players %d, police %d%s'):format(head, tostring(rt.status), gangs, police, extra))
    if kind == 'CONVOY' then
        stall('rt' .. id, tostring(rt.status) .. tostring(rt.currentRouteIndex), out, 'status and route point unchanged (use /convoydebug to see why)')
    else
        stall('rt' .. id, tostring(rt.status), out, 'status unchanged')
    end
end

function EventDebug.snapshot()
    local out = {}
    local seen = {}
    local ids = {}
    pcall(function() for _, id in ipairs(Runtime.getActive()) do ids[#ids + 1] = id end end)
    pcall(function() for _, id in ipairs(TerritoryAuction.getActiveIds()) do ids[#ids + 1] = id end end)
    for _, id in ipairs(ids) do
        if not seen[id] then
            seen[id] = true
            local def = ConvoyManager.get(id)
            local ok, err = pcall(runtimeLines, id, def, out)
            if not ok then add(out, 'bad', ('Reading event #%s failed: %s'):format(tostring(id), tostring(err))) end
        end
    end
    local okT, tours = pcall(Tournament.debugSummary)
    if okT then
        for _, ti in ipairs(tours) do
            if ti.status == 'LIVE' or ti.status == 'SCHEDULED' then
                add(out, 'info', ('Tournament #%d "%s" - %s | %d gangs | matches %d/%d%s%s'):format(ti.id, tostring(ti.name), tostring(ti.status), ti.gangs, ti.played, ti.total,
                    ti.live and (' | LIVE: ' .. ti.live) or '', ti.nextMatch and (' | next: ' .. ti.nextMatch) or ''))
                if ti.lastError then add(out, 'bad', ('Tournament #%d cannot start its next match: %s'):format(ti.id, tostring(ti.lastError))) end
                if ti.status == 'SCHEDULED' and not ti.locked then add(out, 'warn', ('Tournament #%d: the draw is not locked, so it will not start by itself.'):format(ti.id)) end
                if ti.status == 'LIVE' and ti.autoAdvance == false then add(out, 'warn', ('Tournament #%d is LIVE with auto-advance off: start each match by hand.'):format(ti.id)) end
            end
        end
    end
    local okW, wars = pcall(TerritoryWar.list, true, 30)
    if okW then
        for _, w in ipairs(wars) do
            add(out, 'info', ('Rival war #%d %s vs %s for "%s" - %s%s'):format(w.id, tostring(w.attackerLabel), tostring(w.defenderLabel), tostring(w.territoryName), tostring(w.status), w.warAtText and (' | at ' .. w.warAtText) or ''))
            if w.live then stall('war' .. w.id, (json.encode(w.live) or ''):sub(1, 120), out, 'war state unchanged') add(out, 'info', '    live: ' .. (json.encode(w.live) or ''):sub(1, 220)) end
        end
    end
    if #out == 0 then add(out, 'info', 'Nothing is running right now.') end
    return out
end

function EventDebug.checkAll()
    local out, defs = {}, {}
    for _, def in ipairs(ConvoyManager.getAll()) do defs[#defs + 1] = def end
    table.sort(defs, function(a, b) return a.id < b.id end)
    for _, def in ipairs(defs) do
        local list = EventDebug.check(def)
        local worst = 'ok'
        for _, l in ipairs(list) do if l[1] == 'bad' then worst = 'bad' elseif l[1] == 'warn' and worst ~= 'bad' then worst = 'warn' end end
        add(out, worst == 'bad' and 'bad' or (worst == 'warn' and 'warn' or 'ok'), ('#%d %s "%s" [%s]'):format(def.id, KIND_LABEL[def.kind or 'CONVOY'] or tostring(def.kind), tostring(def.name), tostring(def.status)))
        for _, l in ipairs(list) do if l[1] ~= 'ok' and l[1] ~= 'info' then add(out, l[1], '      ' .. l[2]) end end
    end
    if #defs == 0 then add(out, 'info', 'There are no events yet.') end
    return out
end

-- ── command + watch loop ─────────────────────────────────────────────────────────────────

local cmd = cfg().command
if cmd == nil then cmd = 'eventdebug' end
if type(cmd) == 'string' and cmd ~= '' then
    RegisterCommand(cmd, function(source, args)
        if source == 0 then print(('[NovaConvoy] /%s is used in game.'):format(cmd)) return end
        if not isAdmin(source) then notify(source, 'Admins only.', 'error') return end
        local a = tostring(args[1] or ''):lower()
        if a == 'off' or (a == '' and watchers[source]) then
            watchers[source] = nil
            notify(source, 'Event debug watching is off.')
            return
        end
        if a == 'check' then
            local id = tonumber(args[2])
            if id then
                local def = ConvoyManager.get(id)
                if not def then notify(source, ('No event with id %s.'):format(tostring(args[2])), 'error') return end
                emit(source, ('Check #%d %s "%s"'):format(def.id, KIND_LABEL[def.kind or 'CONVOY'] or tostring(def.kind), tostring(def.name)), EventDebug.check(def))
            else
                emit(source, 'Check of all events', EventDebug.checkAll())
            end
            return
        end
        if a == 'status' then
            emit(source, 'Running now', EventDebug.snapshot())
            return
        end
        watchers[source] = true
        notify(source, ('Watching every running event. Output in F8 every %d s; run /%s again to stop.'):format(tonumber(cfg().intervalSeconds) or 10, cmd), 'success')
        emit(source, 'Running now', EventDebug.snapshot())
    end, false)
end

CreateThread(function()
    while true do
        Wait(2000)
        if next(watchers) then
            local interval = math.max(3, tonumber(cfg().intervalSeconds) or 10)
            if os.time() - lastBlock >= interval then
                lastBlock = os.time()
                local ok, lines = pcall(EventDebug.snapshot)
                if ok then
                    for src in pairs(watchers) do
                        if not GetPlayerName(src) then watchers[src] = nil
                        else
                            TriggerClientEvent('nova_convoytruck:debug:eventLines', src, 'Running now', lines, true)
                        end
                    end
                    -- the console copy: only the warnings/failures, the full block is in the admin's F8
                    for _, l in ipairs(lines) do
                        if l[1] == 'bad' or l[1] == 'warn' then print(('%s[EventDebug]  %s  %s^0'):format(COLOR[l[1]], MARK[l[1]], l[2])) end
                    end
                end
            end
        else
            Wait(4000)
        end
    end
end)

AddEventHandler('playerDropped', function() watchers[source] = nil end)

return EventDebug
