-- ─── Nova Convoy — Practice Range (server) ─────────────────────────────────────
-- Squad room/roster/invite/kill-relay state machine, plus the routing-bucket
-- isolation this feature always needed. Everything else (bots, teleport,
-- combat, invincibility, weapon loadout) stays entirely client-side (client/
-- modules/practice_range.lua) — this module exists because SetPlayerRoutingBucket,
-- reliable player-name lookup (invite), and a shared kill/streak count across
-- a squad all need a server-side source of truth.
--
-- A "room" is keyed by its host's source id. The host is whoever first
-- interacted with the instructor ped to start a NEW session (not someone who
-- joined via invite) — only the host can invite, kick, pick the location, and
-- Deploy; everyone (host included) picks their own weapon. Deploying puts the
-- WHOLE room into one shared routing bucket (so squadmates can actually see
-- each other and the host's bots), starts a shared kill/streak count, and
-- ends only when the host ends it — a member can leave early without ending
-- it for anyone else.
--
-- Bots are spawned/owned entirely by the host's client (networked peds so
-- squadmates can perceive/fight them too — see client/modules/
-- practice_range.lua) — this module never touches a bot entity directly,
-- only relays "this bot died, netId X" back to the host so exactly one
-- client manages despawn/respawn.

local NS = 'nova_convoytruck:practice'
local DEFAULT_BUCKET = 0
local MULTIKILL_WINDOW_SECONDS = 4

local rooms = {}       -- [hostSource] = room
local memberRoom = {}  -- [source] = hostSource (every member, including the host, maps to their room's host id)
local inPracticeBucket = {} -- [source] = true — only players THIS feature moved, so a stop/disconnect never touches a bucket some other system assigned
local originalBucket = {} -- [source] = original routing bucket before entering practice

local function practiceBucketFor(hostSrc)
    -- Comfortably clear of bucket 0 and of small hand-picked bucket numbers
    -- another resource might already use. Shared by the whole room (not
    -- per-member) so squadmates actually see each other and the host's bots.
    return 9000 + hostSrc
end

local function roomFor(src)
    local host = memberRoom[src]
    return host and rooms[host] or nil
end

local function buildRoster(room)
    local roster = {}
    for m in pairs(room.members) do
        roster[#roster + 1] = {
            source = m,
            name = Bridge.GetCharacterName(m) or 'Player',      -- the in-game character name, never the Steam / account name
            ping = GetPlayerPing(m) or 0,
            isHost = (m == room.host),
        }
    end
    table.sort(roster, function(a, b)
        if a.isHost ~= b.isHost then return a.isHost end
        return a.source < b.source
    end)
    return roster
end

local function pushRoster(room)
    local roster = buildRoster(room)
    for m in pairs(room.members) do
        TriggerClientEvent(NS .. ':client:squadUpdate', m, roster)
    end
end

-- Server-authoritative "this player is inside a practice session" flag. Read by
-- dispatch scripts (see Config.PracticeRange notes) so nothing the player does
-- in the range reaches police or EMS.
local function setPracticeFlag(src, on)
    pcall(function() Player(src).state:set('novaPractice', on and true or nil, true) end)
end

exports('IsInPractice', function(src)
    return inPracticeBucket[tonumber(src)] == true
end)

-- Moves a player to a routing bucket and CHECKS that it took (a change can be refused while the player's entity is still
-- loading in). Retries a few times; returns whether the player really is in that bucket now.
local function setBucket(src, bucket)
    for _ = 1, 5 do
        if not GetPlayerName(src) then return false end          -- already disconnected: nothing to move
        pcall(SetPlayerRoutingBucket, src, bucket)
        local ok, now = pcall(GetPlayerRoutingBucket, src)
        if ok and now == bucket then return true end
        Wait(120)
    end
    print(('[nova_convoytruck][Practice] could not move player %s to routing bucket %s'):format(tostring(src), tostring(bucket)))
    return false
end

local function releaseBucket(src)
    if inPracticeBucket[src] then
        local prev = originalBucket[src] or DEFAULT_BUCKET
        if prev >= 9000 then prev = DEFAULT_BUCKET end     -- never "return" a player to another practice world
        setBucket(src, prev)
        originalBucket[src] = nil
        inPracticeBucket[src] = nil
        setPracticeFlag(src, false)
    end
end

-- ── Crash / disconnect recovery ───────────────────────────────────────────────────────────────────────────────
-- While a player is inside a session a marker is kept for their character (resource KVP, so it survives a server or
-- resource restart). The client clears it once the player is back at the ped. If the game crashed, the player was kicked
-- or the server restarted mid-session the marker is still there at the next login: the player is put back in the normal
-- world and walked to the practice ped instead of waking up inside the arena.
local function markerKey(identifier) return 'nova_practice_active_' .. tostring(identifier) end

local function markActive(src, originalB)
    local id = Bridge.GetIdentifier(src)
    if id then SetResourceKvp(markerKey(id), json.encode({ orig = originalB or DEFAULT_BUCKET, at = os.time() })) end
end

local function clearMarker(src)
    local id = Bridge.GetIdentifier(src)
    if id then DeleteResourceKvp(markerKey(id)) end
end

-- Sends each member their OWN personalized results payload (their row
-- flagged `you = true`) — only meaningful once the room actually deployed;
-- a room that never left the Armory has nothing to report.
local function sendResults(room)
    if not room.active then return end
    local duration = room.startedAt and (os.time() - room.startedAt) or 0
    local durationLabel = ('%d:%02d'):format(math.floor(duration / 60), duration % 60)
    for m in pairs(room.members) do
        local players = {}
        for mm in pairs(room.members) do
            players[#players + 1] = {
                name = Bridge.GetCharacterName(mm),
                kills = room.kills[mm] or 0,
                deaths = room.deaths and room.deaths[mm] or 0,
                points = (room.kills[mm] or 0) * 100,
                you = (mm == m),
            }
        end
        TriggerClientEvent(NS .. ':client:matchResults', m, {
            mode = 'practice', eventName = 'Practice Range', duration = durationLabel, players = players,
        })
    end
end

local function teardownRoom(room, reason)
    sendResults(room)
    for m in pairs(room.members) do
        releaseBucket(m)
        memberRoom[m] = nil
        TriggerClientEvent(NS .. ':client:sessionEnded', m, reason)
    end
    rooms[room.host] = nil
    -- Bots belong to the host's client; if that client crashed or left they would stay in the (now empty) practice world.
    -- Sweep whatever is still standing in this room's bucket.
    if room.active then
        local bucket = practiceBucketFor(room.host)
        CreateThread(function()
            Wait(800)
            for _, ent in ipairs(GetAllPeds()) do
                if DoesEntityExist(ent) and not IsPedAPlayer(ent) and GetEntityRoutingBucket(ent) == bucket then DeleteEntity(ent) end
            end
        end)
    end
end

-- Host leaving/ending always tears down the whole room (with results, if it
-- had gone active). A non-host member leaving just removes themselves —
-- the rest of the squad keeps going.
local function doLeave(src, reason)
    local room = roomFor(src)
    if not room then return end
    if room.host == src then
        teardownRoom(room, reason or 'Host ended the practice session.')
        return
    end
    room.members[src] = nil
    room.weapons[src] = nil
    memberRoom[src] = nil
    releaseBucket(src)
    TriggerClientEvent(NS .. ':client:sessionEnded', src, reason or 'You left the practice squad.')
    pushRoster(room)
end

-- ── Room lifecycle ──────────────────────────────────────────────────────────

-- The practice range is for gang members (admins may always test it). Decided here, not just in the ped's menu, so a
-- modified client cannot skip it.
local function inGangOrAdmin(src)
    local gang = GangService and GangService.GetPlayerGang(src)
    if gang and gang.name then return true end
    return Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission) == true
end

RegisterNetEvent(NS .. ':server:createRoom', function()
    local src = source
    if not inGangOrAdmin(src) then
        TriggerClientEvent(NS .. ':client:notify', src, 'You are not in a gang.', true)
        return
    end
    local existing = roomFor(src)
    if existing then
        TriggerClientEvent(NS .. ':client:openArmory', src, buildRoster(existing), existing.host == src)
        return
    end
    local room = { host = src, members = { [src] = true }, weapons = {}, kills = {}, streaks = {}, recentKills = {}, active = false }
    rooms[src] = room
    memberRoom[src] = src
    TriggerClientEvent(NS .. ':client:openArmory', src, buildRoster(room), true)
end)

RegisterNetEvent(NS .. ':server:closeArmory', function()
    doLeave(source)
end)

RegisterNetEvent(NS .. ':server:leaveSession', function()
    doLeave(source)
end)

RegisterNetEvent(NS .. ':server:selectWeapon', function(weapon)
    local src = source
    local room = roomFor(src)
    if room and not room.active and type(weapon) == 'string' and weapon ~= '' then
        room.weapons[src] = weapon
    end
end)

-- ── Invites ──────────────────────────────────────────────────────────────────
-- Host-only, matched by a case-insensitive substring against every online
-- player's name (server-side, so it can't be spoofed by a client claiming a
-- different display name) — deliberately not a proximity/target pick, since
-- the squadmate you want to invite might not be standing next to you yet.

RegisterNetEvent(NS .. ':server:invite', function(nameQuery)
    local src = source
    local room = roomFor(src)
    if not room or room.host ~= src or room.active then return end
    if type(nameQuery) ~= 'string' or nameQuery == '' then return end

    local query = nameQuery:lower()
    local target = nil
    for _, plyId in ipairs(GetPlayers()) do
        local plySrc = tonumber(plyId)
        if plySrc and plySrc ~= src and not room.members[plySrc] then
            -- matched on the in-game character name (partial, any case) or an exact server ID
            local pname = (Bridge.GetCharacterName(plySrc) or ''):lower()
            if pname:find(query, 1, true) or tostring(plySrc) == query then
                target = plySrc
                break
            end
        end
    end
    if not target then
        TriggerClientEvent(NS .. ':client:notify', src, 'No matching online player found.', true)
        return
    end
    if memberRoom[target] then
        TriggerClientEvent(NS .. ':client:notify', src, 'That player is already in a practice squad.', true)
        return
    end
    TriggerClientEvent(NS .. ':client:invitePrompt', target, src, Bridge.GetCharacterName(src) or 'A player')
end)

RegisterNetEvent(NS .. ':server:acceptInvite', function(hostSrc)
    local src = source
    if not inGangOrAdmin(src) then
        TriggerClientEvent(NS .. ':client:notify', src, 'You are not in a gang.', true)
        return
    end
    local room = rooms[tonumber(hostSrc)]
    if not room or room.active then
        TriggerClientEvent(NS .. ':client:notify', src, 'That practice squad is no longer available.', true)
        return
    end
    if memberRoom[src] then return end
    room.members[src] = true
    memberRoom[src] = room.host
    TriggerClientEvent(NS .. ':client:openArmory', src, buildRoster(room), false)
    pushRoster(room)
end)

RegisterNetEvent(NS .. ':server:declineInvite', function(hostSrc)
    TriggerClientEvent(NS .. ':client:notify', tonumber(hostSrc), (Bridge.GetCharacterName(source) or 'Player') .. ' declined the invite.', false)
end)

RegisterNetEvent(NS .. ':server:kick', function(targetSrc)
    local src = source
    local room = roomFor(src)
    targetSrc = tonumber(targetSrc)
    if not room or room.host ~= src or not targetSrc or targetSrc == src then return end
    if not room.members[targetSrc] then return end
    room.members[targetSrc] = nil
    room.weapons[targetSrc] = nil
    memberRoom[targetSrc] = nil
    releaseBucket(targetSrc)
    TriggerClientEvent(NS .. ':client:sessionEnded', targetSrc, 'You were removed from the squad by the host.')
    pushRoster(room)
end)

-- ── Deploy ───────────────────────────────────────────────────────────────────

RegisterNetEvent(NS .. ':server:deploy', function(locationId, weapon)
    local src = source
    local room = roomFor(src)
    if not room or room.host ~= src or room.active then return end

    local location = nil
    for _, loc in ipairs(Config.PracticeRange.locations) do
        if loc.id == locationId then location = loc break end
    end
    if not location then return end
    if type(weapon) == 'string' and weapon ~= '' then room.weapons[src] = weapon end

    room.active = true
    room.startedAt = os.time()
    local bucket = practiceBucketFor(room.host)
    -- A private world: no ambient peds/traffic wandering into the range, and
    -- nothing from the main world (EMS, police, other players) shares it.
    SetRoutingBucketPopulationEnabled(bucket, false)
    local failed = {}
    for m in pairs(room.members) do
        if not inPracticeBucket[m] then originalBucket[m] = GetPlayerRoutingBucket(m) end
        markActive(m, originalBucket[m])
        if setBucket(m, bucket) then
            inPracticeBucket[m] = true
            setPracticeFlag(m, true)
            room.kills[m] = 0
        else
            failed[#failed + 1] = m
        end
    end
    -- Anyone who could not be moved is left out (and stays where they are, in the normal world) instead of
    -- being teleported into an arena they cannot be seen in.
    for _, m in ipairs(failed) do
        clearMarker(m)
        originalBucket[m] = nil
        if m == room.host then
            teardownRoom(room, 'Could not start the practice session — try again.')
            return
        end
        room.members[m] = nil
        room.weapons[m] = nil
        memberRoom[m] = nil
        TriggerClientEvent(NS .. ':client:sessionEnded', m, 'Could not join the practice session — try again.')
    end

    local roster = buildRoster(room)
    local defaultWeapon = Config.PracticeRange.weapons[1] and Config.PracticeRange.weapons[1].weapon
    for m in pairs(room.members) do
        TriggerClientEvent(NS .. ':client:deploy', m, {
            location = location,
            weapon = room.weapons[m] or defaultWeapon,
            isHost = (m == room.host),
            roster = roster,
        })
    end
end)

-- ── Bot routing bucket ───────────────────────────────────────────────────────
-- Bots are created by the host's CLIENT. A client-created entity is not
-- guaranteed to land in the creator's routing bucket, and one left in bucket 0
-- is invisible to everyone inside the private practice bucket. The host reports
-- each bot's netId and the server moves that entity into the room's bucket.
RegisterNetEvent(NS .. ':server:botSpawned', function(netId)
    local src = source
    local room = roomFor(src)
    if not room or not room.active or room.host ~= src then return end
    netId = tonumber(netId)
    if not netId then return end
    local bucket = practiceBucketFor(room.host)
    CreateThread(function()
        -- the entity reaches the server a moment after the client creates it
        for _ = 1, 40 do
            local ent = NetworkGetEntityFromNetworkId(netId)
            if ent and ent ~= 0 and DoesEntityExist(ent) then
                if GetEntityType(ent) == 1 and GetEntityRoutingBucket(ent) ~= bucket then
                    SetEntityRoutingBucket(ent, bucket)
                end
                return
            end
            Wait(100)
        end
    end)
end)

-- ── Kills ────────────────────────────────────────────────────────────────────
-- Reported by whichever squad member's own client saw itself land the fatal
-- hit (event-based, not polled — see client/modules/practice_range.lua) so a
-- shared bot's death is never double-counted across squadmates. netId (if
-- given) is relayed only to the host, since only the host's client owns bot
-- despawn/respawn.

RegisterNetEvent(NS .. ':server:reportKill', function(weaponLabel, wasHeadshot, netId, botName)
    local src = source
    local room = roomFor(src)
    if not room or not room.active then return end

    -- Only "Bot <1-32>" is accepted from the client — anything else becomes a
    -- plain "Bot" so a modified client can't put arbitrary text in everyone's feed.
    local slotNum = type(botName) == 'string' and tonumber(botName:match('^Bot (%d+)$')) or nil
    local victimName = (slotNum and slotNum >= 1 and slotNum <= 32) and ('Bot ' .. math.floor(slotNum)) or 'Bot'

    room.kills[src] = (room.kills[src] or 0) + 1
    room.streaks[src] = (room.streaks[src] or 0) + 1
    room.recentKills[src] = room.recentKills[src] or {}
    local now = os.time()
    table.insert(room.recentKills[src], now)
    for i = #room.recentKills[src], 1, -1 do
        if now - room.recentKills[src][i] > MULTIKILL_WINDOW_SECONDS then table.remove(room.recentKills[src], i) end
    end
    local multiKillCount = #room.recentKills[src]

    -- Same priority order as tdm_runtime.lua's own reportHit: headshot beats
    -- a multi-kill, multi-kill beats a bare streak badge.
    local tag, flashType = '', ''
    if wasHeadshot then
        tag, flashType = 'HEAD', 'head'
    elseif multiKillCount >= 3 then
        tag, flashType = 'TRIPLE', 'triple'
    elseif multiKillCount == 2 then
        tag, flashType = 'DOUBLE', 'double'
    elseif room.streaks[src] >= 4 then
        tag, flashType = (room.streaks[src] .. 'X'), 'streak'
    end
    local feedType = ({ head = 'headshot', triple = 'triple', double = 'double', streak = 'streak' })[flashType] or ''
    if flashType == '' then flashType = 'kill' end

    local killerName = Bridge.GetCharacterName(src)
    for m in pairs(room.members) do
        TriggerClientEvent(NS .. ':client:killFeed', m, {
            killer = killerName, killerTeam = '',
            victim = victimName, victimTeam = '',
            weapon = weaponLabel or '', tag = tag, type = feedType, duration = 4000,
        })
    end
    if flashType ~= '' then
        TriggerClientEvent(NS .. ':client:eventFlash', src, flashType, room.streaks[src], victimName)
    end
    TriggerClientEvent(NS .. ':client:killCount', src, room.kills[src])
    if netId then
        TriggerClientEvent(NS .. ':client:botDown', room.host, netId)
    end
end)

-- A bot put this player down (virtual HP hit zero) — counted for the scoreboard.
RegisterNetEvent(NS .. ':server:reportDown', function()
    local src = source
    local room = roomFor(src)
    if not room or not room.active then return end
    room.deaths = room.deaths or {}
    room.deaths[src] = (room.deaths[src] or 0) + 1
end)

-- TAB scoreboard (client/modules/scoreboard.lua). Answers for whichever mode the
-- player is in: an active TDM match first, else their practice squad.
RegisterNetEvent('nova_convoytruck:scoreboard:request', function()
    local src = source
    local payload = Tdm.getScoreboard and Tdm.getScoreboard(src) or nil
    if not payload then
        local room = roomFor(src)
        if room and room.active then
            local list = {}
            for m in pairs(room.members) do
                local kills = room.kills[m] or 0
                local deaths = room.deaths and room.deaths[m] or 0
                list[#list + 1] = {
                    name = Bridge.GetCharacterName(m), kills = kills, deaths = deaths,
                    points = kills * 100, alive = true, you = (m == src),
                }
            end
            table.sort(list, function(a, b)
                if a.points ~= b.points then return a.points > b.points end
                return a.kills > b.kills
            end)
            payload = {
                mode = 'practice', title = 'Practice Range',
                seconds = room.startedAt and (os.time() - room.startedAt) or 0,
                players = list,
            }
        end
    end
    TriggerClientEvent('nova_convoytruck:scoreboard:data', src, payload)
end)

-- ── Recovery after a crash ─────────────────────────────────────────────────────

-- The client is back at the practice ped (normal exit, or recovery): the marker has done its job.
RegisterNetEvent(NS .. ':server:practiceDone', function()
    local src = source
    if memberRoom[src] or inPracticeBucket[src] then return end   -- still in a session: leave the marker alone
    clearMarker(src)
end)

-- Asked by every client each time its role resolves (login, character load, resource restart). Only acts when this
-- character still has a session marker and is not actually in a session.
RegisterNetEvent(NS .. ':server:recover', function()
    local src = source
    if memberRoom[src] or inPracticeBucket[src] then return end
    local id = Bridge.GetIdentifier(src)
    if not id then return end                                    -- character not loaded yet; asked again once it is
    local raw = GetResourceKvpString(markerKey(id))
    if not raw then return end
    local ok, info = pcall(json.decode, raw)
    local back = (ok and type(info) == 'table' and tonumber(info.orig)) or DEFAULT_BUCKET
    if back >= 9000 then back = DEFAULT_BUCKET end
    if GetPlayerRoutingBucket(src) ~= back then setBucket(src, back) end
    setPracticeFlag(src, false)
    print(('[nova_convoytruck][Practice] recovering %s (%s) from an unfinished practice session'):format(GetPlayerName(src) or src, id))
    TriggerClientEvent(NS .. ':client:recover', src)
end)

-- ── Cleanup ──────────────────────────────────────────────────────────────────

AddEventHandler('playerDropped', function()
    local src = source
    releaseBucket(src)
    doLeave(src, 'Disconnected from the practice squad.')
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for src in pairs(inPracticeBucket) do
        local prev = originalBucket[src] or DEFAULT_BUCKET
        SetPlayerRoutingBucket(src, prev)
        setPracticeFlag(src, false)
    end
end)
