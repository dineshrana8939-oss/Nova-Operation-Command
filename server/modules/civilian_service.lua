-- ─── Nova Convoy — Civilian Service (server) ──────────────────────────────────
-- Server-authoritative management for civilian participation in events,
-- civilian registration peds, and dedicated civilian leaderboard rankings.

CivilianService = {}

local FINISHED_STATUSES = { COMPLETED = true, CAPTURED = true, FAILED = true, CANCELLED = true }

function CivilianService.GetActivePeds()
    local peds = {}
    local seen = {}

    local defs = (ConvoyManager and ConvoyManager.getAll and ConvoyManager.getAll()) or {}
    for _, def in ipairs(defs) do
        if not FINISHED_STATUSES[def.status] then
            local isRace = def.kind == 'GANG_RACE'
            local isCw = def.kind == 'CONTAINER_WARS'

            if (isRace or isCw) and def.settings and def.settings.eventAccess == 'EVERYONE' then
                local pedCfg = def.settings.civilianPed
                local defaultCfg = isRace and (Config.RallyRace and Config.RallyRace.civilianPed) or (Config.ContainerWars and Config.ContainerWars.civilianPed)

                local x, y, z, h, model
                if pedCfg and pedCfg.x then
                    x = tonumber(pedCfg.x)
                    y = tonumber(pedCfg.y)
                    z = tonumber(pedCfg.z)
                    h = tonumber(pedCfg.heading) or 0.0
                    model = pedCfg.model
                elseif defaultCfg and defaultCfg.enabled ~= false and defaultCfg.coords then
                    local c = defaultCfg.coords
                    x = tonumber(c.x)
                    y = tonumber(c.y)
                    z = tonumber(c.z)
                    h = tonumber(c.w or c.heading or 0.0)
                    model = defaultCfg.model
                end

                if x and y and z and not seen[def.id] then
                    seen[def.id] = true
                    local blipCfg = (defaultCfg and defaultCfg.blip) or {
                        enabled = true,
                        sprite = isRace and 311 or 478,
                        colour = 3,
                        scale = 0.85,
                        label = 'Event Registration'
                    }

                    peds[#peds + 1] = {
                        convoyId = def.id,
                        kind = def.kind,
                        name = def.name,
                        status = def.status,
                        x = x,
                        y = y,
                        z = z,
                        heading = h or 0.0,
                        model = model or (isRace and 'a_m_y_runner_01' or 's_m_m_dockwork_01'),
                        blip = blipCfg,
                    }
                end
            end
        end
    end
    return peds
end

function CivilianService.SyncPeds(target)
    local peds = CivilianService.GetActivePeds()
    if target and target > 0 then
        TriggerClientEvent('nova_convoytruck:civilian:syncPeds', target, peds)
    else
        TriggerClientEvent('nova_convoytruck:civilian:syncPeds', -1, peds)
    end
end

function CivilianService.RegisterPlayer(source, convoyId)
    if not source or source <= 0 then return { ok = false, error = 'Invalid player.' } end
    convoyId = tonumber(convoyId)
    if not convoyId then return { ok = false, error = 'Invalid event ID.' } end

    local def = ConvoyManager.get(convoyId)
    if not def then return { ok = false, error = 'Event not found.' } end
    if FINISHED_STATUSES[def.status] then return { ok = false, error = 'Event has already concluded.' } end

    if not def.settings or def.settings.eventAccess ~= 'EVERYONE' then
        return { ok = false, error = 'This event is restricted to registered gangs only.' }
    end

    -- Police are not blocked here: the registration ped is where an officer joins a street race or Container Wars
    -- (the Event Status panel is for gangs only).

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return { ok = false, error = 'Unable to identify player.' } end
    local playerName = Bridge.GetPlayerName(source) or 'Civilian'

    if def.kind == 'GANG_RACE' then
        return CivilianService.RegisterRace(source, convoyId, def, identifier, playerName)
    elseif def.kind == 'CONTAINER_WARS' then
        return CivilianService.RegisterContainerWars(source, convoyId, def, identifier, playerName)
    else
        return { ok = false, error = 'Civilian registration is not supported for this event kind.' }
    end
end

function CivilianService.RegisterRace(source, convoyId, def, identifier, playerName)
    local rt = Runtime and Runtime.get and Runtime.get(convoyId)
    if rt then
        if rt.raceFinished then return { ok = false, error = 'Race has already finished.' } end
        if rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier] then
            return { ok = false, error = 'You are already registered for this race.' }
        end
        local totalRacers = 0
        for _ in pairs(rt.participants.identifiers or {}) do totalRacers = totalRacers + 1 end
        local cap = tonumber(rt.def.maxGangParticipants or Config.MaxGangParticipants or 20)
        if totalRacers >= cap then
            return { ok = false, error = 'Race lineup is currently full.' }
        end

        local ok, err = Runtime.registerCivilianRacer(source, convoyId)
        if not ok then return { ok = false, error = err or 'Could not join race.' } end
        return { ok = true, message = 'Registered for race! Head to the starting grid.' }
    else
        def.civilianRoster = def.civilianRoster or {}
        for _, id in ipairs(def.civilianRoster) do
            if id == identifier then
                return { ok = false, error = 'You are already pre-registered for this race.' }
            end
        end
        def.civilianRoster[#def.civilianRoster + 1] = identifier
        ConvoyManager.update(convoyId, { civilianRoster = def.civilianRoster })
        return { ok = true, message = 'Pre-registered for upcoming race! Be at the starting grid when the event goes live.' }
    end
end

function CivilianService.RegisterContainerWars(source, convoyId, def, identifier, playerName)
    local ok, err = ContainerWars.registerCivilian(convoyId, source)
    if not ok then return { ok = false, error = err or 'Could not join auction.' } end
    return { ok = true, message = 'Registered for Container Wars! You can now participate in bidding.' }
end

function CivilianService.RecordResult(identifier, playerName, playerRole, eventType, eventName, stats)
    return DB.recordCivilianResult(identifier, playerName, playerRole, eventType, eventName, stats)
end

function CivilianService.GetLeaderboard(eventType)
    return DB.getCivilianLeaderboard(eventType)
end

-- ── Callbacks & Networking ──────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:civilian:joinEvent', function(source, eventId)
    return CivilianService.RegisterPlayer(source, eventId)
end)

lib.callback.register('nova_convoytruck:getCivilianLeaderboard', function(source, eventType)
    local rows = CivilianService.GetLeaderboard(eventType)
    return { ok = true, entries = rows or {} }
end)

RegisterNetEvent('nova_convoytruck:civilian:requestPedsSync', function()
    local src = source
    CivilianService.SyncPeds(src)
end)

return CivilianService

