-- ─── Nova Convoy — NUI Callbacks ──────────────────────────────────────────────
-- Server-only. Every callback re-validates Bridge.HasCreatorAccess(source)
-- itself — never trust that the client only shows the tablet to authorized
-- players. This is the single choke point the Svelte tablet talks to.

local function denied()
    return { ok = false, error = 'You are not authorized to do that.' }
end

-- Permission checks. Keys are 'section.action' (see server/modules/user_permissions.lua): roles + per-person overrides,
-- and real server administrators hold every key. Gang / job membership never changes the answer.
local function can(source, key) return UserPermissions.can(source, key) end
local function canAny(source, ...) return UserPermissions.canAny(source, ...) end
-- The specialised event kinds (everything but a plain Convoy) additionally need Create Event → Manage.
local function kindAllowed(source, kind) return kind == nil or kind == 'CONVOY' or can(source, 'create.manage') end

-- ── gang roster toast helpers ──────────────────────────────────────────────────

local function findSourceByIdentifier(identifier)
    if not identifier then return nil end
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Bridge.GetIdentifier(src) == identifier then return src end
    end
    return nil
end

local function gangById(gangId)
    for _, g in ipairs(GangService.GetGangs()) do
        if g.id == gangId then return g end
    end
    return nil
end

local function toastPlayer(target, icon, title, message, warn)
    if target then TriggerClientEvent('nova_convoytruck:gang:toast', target, icon, title, message, warn) end
end

-- Roles, ranks, members and settings of a gang live in ONE place (the database) and are shown in two panels: the admin tablet's
-- Gang Management and the gang's own Event Status panel. Whatever changes it, from either side, tells everyone who has one of
-- the two open (the gang's own members, and staff who can see gangs) so both redraw from the same data at once.
local function notifyGangChanged(gangId)
    local gang = gangById(gangId)
    local name = gang and gang.name or nil
    for _, src in ipairs(Bridge.GetPlayers()) do
        local mine = name and GangService.GetPlayerGang(src)
        if (mine and mine.name == name) or can(src, 'gangs.view') then
            TriggerClientEvent('nova_convoytruck:client:gangChanged', src, gangId, name)
        end
    end
end

-- Notifies the affected member (if online) and the gang leader (if online and
-- not the same person) of a roster change — a small toast, not the big
-- convoy-event banner, since this is routine bookkeeping, not a live event.
local function notifyGangRosterChange(gangId, affectedIdentifier, added)
    notifyGangChanged(gangId)
    local gang = gangById(gangId)
    local label = gang and gang.label or 'the gang'
    local icon = added and '✓' or '✕'

    local affectedSource = findSourceByIdentifier(affectedIdentifier)
    local affectedName = affectedSource and Bridge.GetPlayerName(affectedSource) or 'A member'
    toastPlayer(affectedSource, icon, 'Gang Update',
        added and ('You were added to %s.'):format(label) or ('You were removed from %s.'):format(label),
        not added)

    if gang and gang.leaderIdentifier and gang.leaderIdentifier ~= affectedIdentifier then
        local leaderSource = findSourceByIdentifier(gang.leaderIdentifier)
        toastPlayer(leaderSource, icon, 'Gang Update',
            added and ('%s joined %s.'):format(affectedName, label) or ('%s was removed from %s.'):format(affectedName, label),
            not added)
    end
end

lib.callback.register('nova_convoytruck:hasAccess', function(source)
    return Bridge.HasCreatorAccess(source)
end)

-- This player's own police/admin status, used only to decide which cosmetic
-- map blips their client draws (shop/trigger peds are staff-only on the map).
lib.callback.register('nova_convoytruck:getMyRoles', function(source)
    return ConvoyManager.rolesFor(source)
end)

RegisterNetEvent('nova_convoytruck:server:requestRoleSync', function()
    local src = source
    if not src then return end
    TriggerClientEvent('nova_convoytruck:client:roleSync', src, ConvoyManager.rolesFor(src))
end)

-- A client whose role only resolved AFTER its start-ped sync arrived asks for
-- a fresh sync so the ped's blip gets drawn. Re-checks the audience here too —
-- never hand start peds to a caller who isn't police/admin just because they
-- asked.
RegisterNetEvent('nova_convoytruck:server:requestStartPedsSync', function()
    local src = source
    if not src then return end
    if Bridge.IsPolice(src) or Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission) then
        ConvoyManager.sendStartPedsTo(src)
    end
end)

-- The User Guide: the text of docs/user_guide.md is read from disk on EVERY call, so an edit to the file shows the next time the
-- guide tab is opened (no restart, no rebuild). The server's command names go along; the tablet's client adds its own.
lib.callback.register('nova_convoytruck:getUserGuide', function(source)
    if not can(source, 'guide.view') then return denied() end
    local text = LoadResourceFile(GetCurrentResourceName(), 'docs/user_guide.md')
    if not text or text == '' then
        return { ok = false, error = 'The guide file docs/user_guide.md was not found in the resource.' }
    end
    return { ok = true, text = text, commands = NovaCommandNames or {} }
end)

lib.callback.register('nova_convoytruck:getBootstrap', function(source)
    if not Bridge.HasCreatorAccess(source) then return denied() end
    local isAdm = Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission)
    local who = UserPermissions.describe(source)
    local perms = who.perms
    return {
        ok = true,
        playerName = Bridge.GetPlayerName(source),
        isAdmin = isAdm,
        isPolice = Bridge.IsPolice(source),
        -- every 'section.action' key this player holds, decided here on the server; the tablet only shows what is listed
        perms = perms,
        permissions = perms,
        staffRole = who.staffRole,
        canDeleteEvents = perms['convoys.delete'] == true,
        canManageEvents = perms['convoys.manage'] == true,
        canManageBanners = perms['announcements.edit'] == true,
        canViewLeaderboards = perms['leaderboard.view'] == true,
        canManageGangs = perms['gangs.manage'] == true,
        canManageTournaments = perms['tournaments.manage'] == true,
        canManageTerritories = perms['territories.manage'] == true,
        adminOnlyTabs = {},
        features = Config.Features,
        limits = {
            maxConvoys = Config.MaxConvoys,
            maxTrucksPerConvoy = Config.MaxTrucksPerConvoy,
            maxCheckpoints = Config.MaxCheckpoints,
            maxGangParticipants = Config.MaxGangParticipants,
            maxPoliceParticipants = Config.MaxPoliceParticipants,
        },
        gangProvider = Config.GangProvider,
        access = { admin = Config.CreatorAccess.admin, adminPermission = Config.CreatorAccess.adminPermission, jobs = Config.CreatorAccess.jobs },
        tablet = Config.Tablet,
        -- the numbers, commands and keys the User Guide quotes, read from config.lua so the guide never goes out of date
        guide = (function()
            local sp, rr, hc, td = Config.StatusPanel or {}, Config.RallyRace or {}, Config.HotCargoTheft or {}, Config.TDM or {}
            local cw = Config.ContainerWars or {}
            local jobs = {}
            for name in pairs((Config.CreatorAccess or {}).jobs or {}) do jobs[#jobs + 1] = name end
            table.sort(jobs)
            return {
                statusCmd = sp.command, statusKey = sp.keybind,
                raceStartCmd = rr.countdownCommand, soundTestCmd = Config.Sounds and Config.Sounds.testCommand or nil,
                deliveryRadius = Config.DeliveryRadius, startAnnounceDelay = Config.ConvoyStartAnnounceDelaySeconds,
                preScheduleSeconds = Config.PreScheduleAnnounceSeconds,
                hcSearchRadius = hc.searchRadius, hcBreakdownPct = hc.breakdownHealthPct, hcMaxSpeed = hc.maxSpeed,
                raceTokens = rr.tokensByPosition, raceFinishTokens = rr.finishTokens, raceFinishWindow = rr.finishWindowSeconds,
                raceGridRadius = rr.gridRadius, raceGridWait = rr.gridWaitSeconds, raceReminders = rr.leadReminders,
                tdmHp = td.maxHealth, tdmPrep = td.prepCountdownSeconds, tdmRespawn = td.respawnDelaySeconds, tdmInvuln = td.respawnInvulnSeconds,
                cwCountdown = (cw.defaults or {}).startCountdownSeconds,
                antiSnipeTrigger = (cw.antiSnipe or {}).triggerSeconds, antiSnipeExtend = (cw.antiSnipe or {}).extendSeconds,
                lockFailures = (Config.Lockpick or {}).maxFailuresByDifficulty,
                policeJobs = jobs,
                practiceMult = (Config.PracticeRange or {}).hiddenHealthMultiplier,
                splitXp = ((Config.Territory or {}).gangXp or {}).splitAmongRecipients == true,
                cpWait = Config.DefaultCheckpointWaitTime, destWarn = Config.DestinationProximityWarningDistance,
                airdropDuration = (Config.Airdrop or {}).duration, airdropGuards = (Config.Airdrop or {}).guardCount,
                airdropLockpicks = (Config.Airdrop or {}).lockpicksRequired,
                airdropLead = ((Config.Airdrop or {}).plane or {}).leadSeconds,
                war = (function()
                    local w = (Config.Territory or {}).war or {}
                    local rv = (Config.Territory or {}).rival or {}
                    return {
                        minutes = w.defaultDurationMinutes, reminders = w.reminderMinutes, noShow = w.noShowPenalty,
                        captureSeconds = (w.capture or {}).seconds, contestRule = (w.capture or {}).contestRule,
                        ringRadius = (w.ringZone or {}).radius, ringBuffer = (w.ringZone or {}).bufferSeconds,
                        lootWindow = (w.postWarLoot or {}).windowMinutes, lootPercent = (w.postWarLoot or {}).lootXpPercent,
                        shrinkPercent = (w.postWarLoot or {}).zoneShrinkPercent, pairCooldownHours = (w.postWarLoot or {}).pairCooldownHours,
                        challengeCooldown = rv.challengeCooldownSeconds, maxOpen = rv.maxOpenPerGang, expire = rv.expireSeconds,
                    }
                end)(),
            }
        end)(),
        branding = Config.Branding or {},
        hotCargoVehicles = (Config.HotCargoTheft and Config.HotCargoTheft.vehicles) or {},
        -- flattened to plain x/y/z by AirdropLocations (the config rows hold vector3 `coords`, which the tablet's JSON can't read)
        predefinedAirdrops = (AirdropLocations and AirdropLocations.GetPool()) or nil,
        -- the vehicle-reward editor: suggested cars, where a garage-mode car is stored, the default mode
        vehicleRewards = {
            defaultMode = (Config.VehicleRewards and Config.VehicleRewards.defaultMode) or 'GARAGE',
            garage = Config.VehicleRewards and Config.VehicleRewards.garage or nil,
            suggestions = (Config.VehicleRewards and Config.VehicleRewards.suggestions) or {},
        },
        barricadeProps = Config.CheckpointBarricadeProps or {},
        -- every model the Prop Placer treats as a vehicle: the tablet files a stored entry as a vehicle (not a prop) by this
        placerVehicleModels = (function()
            local out = {}
            if EventProps and EventProps.vehicleModels then
                for m in pairs(EventProps.vehicleModels()) do out[#out + 1] = m end
                table.sort(out)
            end
            return out
        end)(),
        checkpointBarricades = Config.CheckpointBarricades or {},
        -- the ped model of each placeable ped, so the tablet's placement hologram shows the real ped
        pedModels = {
            equipmentVendor = Config.PoliceEquipment and Config.PoliceEquipment.pedModel or nil,
            escortShop = Config.EscortVehicleShop and Config.EscortVehicleShop.pedModel or nil,
            tokenVendor = Config.TokenVendor and Config.TokenVendor.pedModel or nil,
            raceVehicle = Config.RaceVehicleShop and Config.RaceVehicleShop.pedModel or nil,
            tdmVendor = Config.TDM and Config.TDM.weaponVendor and Config.TDM.weaponVendor.pedModel or nil,
            territoryLeader = Config.Territory and Config.Territory.war and Config.Territory.war.capture and Config.Territory.war.capture.pedModel or nil,
        },
        -- Gang Territory Auction form: limits, brush, defaults — every number the editor starts with comes from config
        territory = (function()
            local t = Config.Territory or {}
            local w = t.war or {}
            return {
                enabled = t.enabled ~= false,
                cellSize = t.cellSize, maxCellsPerTerritory = t.maxCellsPerTerritory, maxAreas = t.maxAreas, maxExpansions = t.maxExpansions,
                defaultColor = t.defaultColor, brush = t.brush,
                auction = { defaults = (t.auction or {}).defaults, antiSnipe = (t.auction or {}).antiSnipe, zoneRadius = (t.auction or {}).zoneRadius, projectorModel = (t.auction or {}).projectorModel, projectorModelFallbacks = (t.auction or {}).projectorModelFallbacks, viewDistance = (t.auction or {}).viewDistance, screen = (t.auction or {}).screen },
                war = {
                    defaultDurationMinutes = w.defaultDurationMinutes, minDurationMinutes = w.minDurationMinutes, maxDurationMinutes = w.maxDurationMinutes,
                    noShowPenalty = w.noShowPenalty, reminderMinutes = w.reminderMinutes,
                    capture = { seconds = (w.capture or {}).seconds, radius = (w.capture or {}).radius, interactDistance = (w.capture or {}).interactDistance,
                                contestRule = (w.capture or {}).contestRule, pedModel = (w.capture or {}).pedModel, anim = (w.capture or {}).anim },
                },
                blip = t.blip,
            }
        end)(),
        -- Container Wars setup form: model lists, defaults and the example auction all come from config
        containerWars = (function()
            local cw = Config.ContainerWars or {}
            local nSpots = #((cw.harbour and cw.harbour.pickups) or {})
            local cranes = CWGantry.resolveCranes(cw.harbour, nSpots)
            return {
                containerModels = cw.containerModels or {},
                containerModelAlias = cw.containerModelAlias or {},
                maxLots = tonumber(cw.maxLots) or 40,
                harbour = cw.harbour or {},
                craneResolved = cranes[1] or CWGantry.resolveCrane(cw.harbour, nSpots),
                cranesResolved = cranes,
                craneAssign = CWGantry.assignCranes(cw.harbour or {}, cranes, math.max(nSpots, #((cw.harbour and cw.harbour.drops) or {}))),
                gantries = cw.gantries or {},
                defaults = cw.defaults or {},
                antiSnipe = cw.antiSnipe or {},
                example = cw.defaultOceanDocksPresets or {},
            }
        end)(),
        scheduleUtcOffsetHours = Scheduler.getSettings().utcOffsetHours,
        dashboard = ConvoyManager.getDashboardStats(),
    }
end)

-- ── Convoys ──────────────────────────────────────────────────────────────────────

-- GANG_AIRDROP-kind convoys are completely invisible to anyone with the
-- police job — this is the choke point for the admin tablet's own Manage
-- Convoys / Create Convoy edit lists; getActiveConvoys/getConvoyHistory
-- below apply the same filter to the live panel and past-run history.
-- Admins are exempt even if their job also happens to be a police one —
-- getConvoyHistory's own SQL-side version of this rule already carves out
-- that exemption (db.lua), so an admin/police player could find a past
-- airdrop in History but not the live one they just created, and got
-- "Convoy not found" the moment they tried to open/edit it. This is the
-- ONE kind-based visibility rule in the whole tablet — nothing else here
-- hides a CONVOY or HOT_CARGO event from anyone with creator access.
local function visibleToCaller(source, def)
    -- a plain Convoy is visible to everyone who can see events; the specialised kinds only to Create Event → Manage
    return kindAllowed(source, def.kind)
end

-- The caller is a gang member working an on-duty government job (see getStatusPanelAccess): they see the Event Status panel's
-- government view — only the event kinds in Config.StatusPanel.govEventKinds, nothing gang-related.
local function govStatusView(source)
    if Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission) then return false end
    if not GangService.GetPlayerGang(source) then
        -- no gang: a police officer is the original user of this panel (pre-registering for / joining convoys as an escort);
        -- any other government character (EMS, fire, DOJ ... on duty — Config.StatusPanel.govJobs) gets the same events-only view
        return Bridge.IsPolice(source) or Bridge.IsGovOnDuty(source)
    end
    return Bridge.IsGovOnDuty(source)
end
local function govKindVisible(kind)
    local kinds = (Config.StatusPanel and Config.StatusPanel.govEventKinds) or { CONVOY = true, GANG_RACE = true, CONTAINER_WARS = true }
    return kinds[kind or 'CONVOY'] == true
end

-- Resolves def.roster (gang name -> [identifier]) into actual member names
-- for the admin tablet — def.roster itself only ever stores identifiers
-- (that's what Runtime.joinGang checks against), so without this an admin
-- had no way to see WHO a gang leader actually signed up, only that a
-- roster save happened. Returns a shallow copy with `rosterResolved`
-- attached rather than mutating the cached definition.
-- identifier -> name over every gang member. Built ONCE per request and handed to withRosterResolved: it used to rebuild it (a
-- database read of every gang and its members) for EACH event of the list, so opening Manage Events / Dashboard / History cost
-- one full gang read per event.
local function gangMemberNames()
    local nameByIdentifier = {}
    for _, g in ipairs(GangService.GetGangs()) do
        for _, m in ipairs(g.members or {}) do nameByIdentifier[m.identifier] = m.name end
    end
    return nameByIdentifier
end

local function withRosterResolved(def, nameByIdentifier)
    nameByIdentifier = nameByIdentifier or gangMemberNames()
    local resolved = {}
    for gangName, identifiers in pairs(def.roster or {}) do
        local list = {}
        for _, identifier in ipairs(identifiers) do
            list[#list + 1] = { identifier = identifier, name = nameByIdentifier[identifier] or identifier }
        end
        resolved[gangName] = list
    end
    -- Police self-register via Runtime.registerPolice, which writes
    -- { identifier, name } — but rows saved before that (or when the name
    -- lookup failed at registration time) have no `name` at all, which is
    -- what rendered as "undefined" in the participants panel. Fill any
    -- missing/blank name in from the live player list, and fall back to the
    -- identifier so the chip is never empty.
    local policeResolved = {}
    for _, entry in ipairs(def.policeRoster or {}) do
        local id = type(entry) == 'table' and entry.identifier or entry
        local name = type(entry) == 'table' and entry.name or nil
        if not name or name == '' or name == 'Unknown' then name = nameByIdentifier[id] end
        if not name or name == '' or name == 'Unknown' then
            local src = findSourceByIdentifier(id)
            if src then name = Bridge.GetPlayerName(src) end
        end
        policeResolved[#policeResolved + 1] = {
            identifier = id,
            name = (name and name ~= '' and name ~= 'Unknown' and name) or id or 'Officer',
            registeredAt = type(entry) == 'table' and entry.registeredAt or nil,
        }
    end
    local out = {}
    for k, v in pairs(def) do out[k] = v end
    out.rosterResolved = resolved
    out.policeResolved = policeResolved
    return out
end

lib.callback.register('nova_convoytruck:getConvoys', function(source)
    if not canAny(source, 'convoys.view', 'create.view', 'dashboard.view', 'participants.view', 'completed.view') then return denied() end
    local all = ConvoyManager.getAll()
    local visible = {}
    local names = gangMemberNames()
    for _, def in ipairs(all) do
        if visibleToCaller(source, def) then
            local d = withRosterResolved(def, names)
            d.racePending = Runtime.isRacePending(def.id) or nil -- race in its "starts in N minutes" lead-in
            visible[#visible + 1] = d
        end
    end
    return { ok = true, convoys = visible }
end)

lib.callback.register('nova_convoytruck:getConvoy', function(source, id)
    if not canAny(source, 'convoys.view', 'create.view') then return denied() end
    local def = ConvoyManager.get(id)
    if not def or not visibleToCaller(source, def) then return { ok = false, error = 'Event not found.' } end
    return { ok = true, convoy = withRosterResolved(def) }
end)

lib.callback.register('nova_convoytruck:createConvoy', function(source, input)
    if not can(source, 'create.create') then return denied() end
    if type(input) ~= 'table' then return { ok = false, error = 'Invalid payload.' } end
    if not kindAllowed(source, input.kind or 'CONVOY') then
        return { ok = false, error = 'You can only create Convoy events. The other event kinds need the Create Event → Manage permission.' }
    end

    local ok, result = ConvoyManager.create(source, input)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

lib.callback.register('nova_convoytruck:updateConvoy', function(source, id, input)
    if not canAny(source, 'create.edit', 'convoys.edit') then return denied() end
    if type(input) ~= 'table' then return { ok = false, error = 'Invalid payload.' } end
    local def = ConvoyManager.get(id)
    if not def then return { ok = false, error = 'Event not found.' } end
    if not kindAllowed(source, def.kind) or not kindAllowed(source, input.kind) then
        return { ok = false, error = 'You can only manage Convoy events. The other event kinds need the Create Event → Manage permission.' }
    end

    local ok, result = ConvoyManager.update(source, id, input)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

-- Resets a cancelled/completed/captured/failed convoy back to Draft so it
-- can be started again with the exact same trucks/route/settings — see
-- ConvoyManager.reuse for why this is its own endpoint instead of going
-- through updateConvoy.
lib.callback.register('nova_convoytruck:reuseConvoy', function(source, id)
    if not can(source, 'convoys.manage') then return denied() end
    local def = ConvoyManager.get(id)
    if def and not kindAllowed(source, def.kind) then
        return { ok = false, error = 'Only staff with Create Event → Manage can reuse this kind of event.' }
    end
    local ok, result = ConvoyManager.reuse(id)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

lib.callback.register('nova_convoytruck:cloneConvoy', function(source, id, newName)
    if not can(source, 'convoys.manage') then return denied() end
    local def = ConvoyManager.get(id)
    if def and not kindAllowed(source, def.kind) then
        return { ok = false, error = 'Only staff with Create Event → Manage can clone this kind of event.' }
    end
    local ok, result = ConvoyManager.clone(source, id, newName)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

-- dateTimeLocal: the raw value of an HTML <input type="datetime-local">
-- ("YYYY-MM-DDTHH:MM") — interpreted as wall-clock time in the zone
-- Config.ScheduleUtcOffsetHours describes, converted to true UTC here via
-- Scheduler.toUtcTimestamp before being handed to ConvoyManager.schedule.
lib.callback.register('nova_convoytruck:scheduleConvoy', function(source, id, dateTimeLocal)
    if not can(source, 'convoys.manage') then return denied() end
    local def = ConvoyManager.get(id)
    if def and not kindAllowed(source, def.kind) then
        return { ok = false, error = 'Only staff with Create Event → Manage can schedule this kind of event.' }
    end
    local y, mo, d, h, mi = tostring(dateTimeLocal or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+)')
    if not y then return { ok = false, error = 'Invalid date/time.' } end
    local timestamp = Scheduler.toUtcTimestamp(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi))
    local ok, result = ConvoyManager.schedule(source, id, timestamp)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

-- Activates a recurring convoy's schedule using its own cadence rule to
-- compute the first fire time — see ConvoyManager.scheduleRecurring.
lib.callback.register('nova_convoytruck:scheduleRecurringConvoy', function(source, id)
    if not can(source, 'convoys.manage') then return denied() end
    local def = ConvoyManager.get(id)
    if def and not kindAllowed(source, def.kind) then
        return { ok = false, error = 'Only staff with Create Event → Manage can schedule this kind of event.' }
    end
    local ok, result = ConvoyManager.scheduleRecurring(source, id)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

lib.callback.register('nova_convoytruck:unscheduleConvoy', function(source, id)
    if not can(source, 'convoys.manage') then return denied() end
    local def = ConvoyManager.get(id)
    if def and not kindAllowed(source, def.kind) then
        return { ok = false, error = 'Only staff with Create Event → Manage can unschedule this kind of event.' }
    end
    local ok, result = ConvoyManager.unschedule(source, id)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = result }
end)

lib.callback.register('nova_convoytruck:deleteConvoy', function(source, id)
    if not can(source, 'convoys.delete') then
        return { ok = false, error = 'You do not have permission to delete events.' }
    end
    local def = ConvoyManager.get(id)
    if not def then return { ok = false, error = 'Event not found.' } end
    if Runtime.isActive(id) then return { ok = false, error = 'Cannot delete an event that is currently running.' } end
    local ok, err = ConvoyManager.delete(id)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- ── Live Runtime ─────────────────────────────────────────────────────────────────

-- Access check for the Convoy Status panel (Config.StatusPanel.command). Server-authoritative:
-- the client only asks, it never decides. Three tiers —
--   admin  : full access (admin gang management lives in the tablet's admin panel)
--   leader : a gang leader — sees the board AND manages their own gang here
--   member : an ordinary gang member — sees the board, but no gang tooling
-- Anyone with no gang and no admin ACE is refused outright.
--
-- On-duty police are deliberately excluded: they get the tablet's escort view
-- instead, and IsPolice is true for every job in CreatorAccess.jobs.
lib.callback.register('nova_convoytruck:getStatusPanelAccess', function(source)
    local isAdmin = Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission) or false

    -- NOTE: this no longer skips gang lookup for police. A gang leader who is
    -- ALSO on a police-job (or an admin who leads a gang) is a legitimate
    -- combination — skipping the lookup left isLeader false, so their own gang
    -- management silently vanished from the panel. Police status still gates
    -- the gang-management CAPABILITY below; it must not blind us to who leads
    -- what.
    local gang, isLeader = nil, false
    gang = GangService.GetPlayerGang(source)
    if gang then
        local identifier = Bridge.GetIdentifier(source)
        for _, g in ipairs(GangService.GetGangs()) do
            if g.name == gang.name then
                isLeader = (g.leaderIdentifier ~= nil and g.leaderIdentifier == identifier)
                break
            end
        end
    end

    -- A gang member counts for access only when they're not on-duty police
    -- (police get the tablet's escort view instead). An admin is always
    -- allowed. isGangMember captures "is a civilian gang member OR a gang
    -- leader" without the police caveat applied to leadership itself.
    -- A gang member who ALSO works an on-duty government job (police, EMS, ... — Config.StatusPanel.govJobs; the character kept
    -- its gang when it took the job) gets the GOVERNMENT view of this panel: no gang tabs and no gang tools, only the Convoy,
    -- Rally Race and Container Wars events (Config.StatusPanel.govEventKinds). Leaders included. Off duty they are an ordinary
    -- member again. Admins are exempt. Config.StatusPanel.govBlockOpen = true refuses to open it at all instead, with a message.
    local govView = govStatusView(source)
    local blockOpen = govView and gang ~= nil and (Config.StatusPanel or {}).govBlockOpen == true
    local isGangMember = (gang ~= nil) and not blockOpen
    -- A police officer (no gang) opens the same government view: this panel is where they pre-register for a convoy and
    -- join it as an escort. They get no gang tabs and no gang tools.
    local allowed = isAdmin or isGangMember or (govView and gang == nil)
    local denyReason = blockOpen and 'police_on_duty' or nil
    if govView then isLeader = false end

    -- Capabilities come from the gang's own role permissions, not from being a
    -- leader — a leader can grant manageGang / registerRoster to any custom
    -- role via the Roles & Permissions section, and those holders should get
    -- exactly the same panel affordances the leader does. Admins fall back to
    -- the leader-equivalent capability set only when they actually lead a gang
    -- (GetPermissionContext treats a gangless admin as fully capable so the
    -- admin view still works).
    local ctx = { canManageGang = isLeader, canRegisterRoster = isLeader }
    if gang then
        ctx = GangService.GetPermissionContext(source, isAdmin)
    elseif isAdmin then
        ctx = { canManageGang = true, canRegisterRoster = true }
    end

    -- WHY the register / role tools are missing, so the panel can say it instead of silently hiding them: either the character
    -- works an on-duty government job (govJob = its name), or the gang role simply has no "Register for Events" (rank = the role).
    local govJob = nil
    if govView and gang then
        local jg = Bridge.GetJobGrade(source)
        govJob = jg and (jg.label or jg.name) or 'government job'
    end
    local missing = nil
    if gang and not govView and not ctx.canRegisterRoster then missing = 'role' end

    return {
        ok = true,
        allowed = allowed,
        denyReason = denyReason,
        govView = govView,
        govJob = govJob,
        missing = missing,
        isAdmin = isAdmin,
        canManageGang = ctx.canManageGang == true,
        -- Signing the gang up for events on the leader's behalf.
        canRegisterRoster = ctx.canRegisterRoster == true,
        isLeader = isLeader,
        gangRank = ctx.gangRank,
        gangName = gang and gang.name or nil,
        gangLabel = gang and gang.label or nil,
    }
end)

lib.callback.register('nova_convoytruck:startRaceCountdown', function(source, id)
    if not can(source, 'convoys.manage') then return denied() end
    local ok, err = Runtime.startRaceCountdown(source, id)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- Chat/console command (Config.RallyRace.countdownCommand): /racestart [eventId]
do
    local cmd = Config.RallyRace and Config.RallyRace.countdownCommand
    if cmd and cmd ~= '' then
        RegisterCommand(cmd, function(source, args)
            local id = tonumber(args[1]) or Runtime.findGridRace()
            local function say(msg)
                if source and source > 0 then TriggerClientEvent('chat:addMessage', source, { args = { 'Race', msg } }) else print('[NovaConvoy] ' .. msg) end
            end
            if not id then say('No single race is waiting on the grid — use /' .. cmd .. ' <eventId>.') return end
            local ok, err = Runtime.startRaceCountdown(source, id)
            say(ok and ('Countdown started for event #' .. id .. '.') or tostring(err))
        end, false)
    end
end

lib.callback.register('nova_convoytruck:startConvoy', function(source, id)
    if not can(source, 'convoys.manage') then return denied() end
    local ok, result = Runtime.start(source, id)
    if not ok then return { ok = false, error = result } end
    return { ok = true, convoy = ConvoyManager.get(id) }
end)

lib.callback.register('nova_convoytruck:testRunConvoy', function(source, id)
    if not can(source, 'convoys.manage') then return denied() end
    local ok, err = Runtime.testRun(source, id)
    if not ok then return { ok = false, error = err } end
    return { ok = true, convoy = ConvoyManager.get(id) }
end)

lib.callback.register('nova_convoytruck:forceEndConvoy', function(source, id)
    local success, ok, err = pcall(Runtime.forceEnd, source, id)
    if not success then
        lib.print.error(('[NovaConvoy] Error in Runtime.forceEnd: %s'):format(tostring(ok)))
        return { ok = false, error = ('Internal error: %s'):format(tostring(ok)) }
    end
    if not ok then return { ok = false, error = err or 'Could not force end event.' } end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:joinConvoyGang', function(source, id)
    local ok, err = Runtime.joinGang(source, id)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- A Container Wars event or a race set to "Open to Everyone" needs no gang sign-up at all (civilians use the registration ped).
local function openToEveryone(def)
    return (def.kind == 'CONTAINER_WARS' or def.kind == 'GANG_RACE') and def.settings ~= nil
        and tostring(def.settings.eventAccess or def.eventAccess or ''):upper() == 'EVERYONE'
end

-- Gang-leader-only: convoys still open for roster sign-up (DRAFT/SCHEDULED,
-- gangPvp on), plus the leader's own gang member list to pick from. Not
-- gated by HasCreatorAccess — gang leaders are civilians, not tablet users.
lib.callback.register('nova_convoytruck:getRosterConvoys', function(source)
    -- On-duty police never get gang-leader tooling, even from a gang they're
    -- nominally attached to — see myLedGang/Runtime.joinGang for the same rule.
    if Bridge.IsPolice(source) or govStatusView(source) then return { ok = true, isLeader = false, convoys = {} } end
    local gang = GangService.GetPlayerGang(source)
    if not gang then return { ok = true, isLeader = false, convoys = {} } end

    local myGang
    for _, g in ipairs(GangService.GetGangs()) do
        if g.name == gang.name then myGang = g break end
    end
    if not myGang then return { ok = true, isLeader = false, convoys = {} } end
    -- Every gang member may SEE their own gang's roster (My Gang tab); only a
    -- role the leader granted 'registerRoster' additionally gets the list of
    -- events to sign the gang up for.
    local canRegister = GangService.HasPermission(source, 'registerRoster')

    -- TDM's allowedGangs is a hard invite-only gate (see setGangRoster) — a
    -- gang not on the admin's list should not even see it listed as open.
    local function tdmEligible(def)
        if def.kind ~= 'TDM' then return true end
        -- A Tournament-format TDM is a template the Tournaments tab plays
        -- matches on, never something a gang signs up for directly.
        if def.tdm and def.tdm.matchFormat == 'TOURNAMENT' then return false end
        local ag = def.settings and def.settings.allowedGangs
        if not ag or ag.mode ~= 'SELECTED' then return true end
        for _, name in ipairs(ag.gangs or {}) do
            if name == gang.name then return true end
        end
        return false
    end

    local list = {}
    for _, def in ipairs(ConvoyManager.getAll()) do
        if canRegister and (def.status == 'DRAFT' or def.status == 'SCHEDULED') and (def.settings.gangPvp or def.kind == 'GANG_RACE') and def.kind ~= 'GANG_AIRDROP' and def.kind ~= 'HOT_CARGO' and def.kind ~= 'GANG_TERRITORY' and def.kind ~= 'CRACKDOWN' and def.kind ~= 'CONTAINER_WARS' and not openToEveryone(def) and tdmEligible(def) then
            list[#list + 1] = {
                id = def.id,
                name = def.name,
                kind = def.kind or 'CONVOY',
                shortDescription = def.shortDescription,
                maxGangParticipants = ConvoyManager.rosterCapFor(def, gang.name),
                roster = (def.roster and def.roster[gang.name]) or {},
            }
        end
    end

    -- isLeader must reflect ACTUAL leadership, not "was allowed to read this
    -- list" — a member granted registerRoster gets here, but they are not the
    -- leader, and the UI keys leader-only controls (promote, transfer) off
    -- this flag. canManageGang/canRegisterRoster carry the delegated rights.
    local isLeader = myGang.leaderIdentifier == Bridge.GetIdentifier(source)
    local ctx = GangService.GetPermissionContext(source)

    return {
        ok = true,
        isLeader = isLeader,
        canManageGang = ctx.canManageGang == true,
        canRegisterRoster = ctx.canRegisterRoster == true,
        gangRank = ctx.gangRank,
        gangName = gang.name,
        gangLabel = myGang.label,
        gangLogo = myGang.logo,
        gangAccentColor = myGang.accentColor,
        leaderIdentifier = myGang.leaderIdentifier,
        members = myGang.members or {},
        convoys = list,
    }
end)

-- Roster sign-up is a different concept from gang MEMBERSHIP (see
-- ConvoyManager.setGangRoster's own comments) — being on a gang doesn't
-- automatically flag you in for any given convoy, so a member newly added/
-- removed here needs its own toast, separate from notifyGangRosterChange
-- (which only ever fires for gang membership changes, above).
-- Container Wars / Territory Auction: the gang registers (or unregisters) as a whole
lib.callback.register('nova_convoytruck:setGangRegistered', function(source, id, on)
    local ok, err = ConvoyManager.setGangRegistered(source, tonumber(id), on == true)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:setConvoyRoster', function(source, id, identifiers)
    local ok, def, added, removed = ConvoyManager.setGangRoster(source, id, identifiers)
    if not ok then return { ok = false, error = def } end
    for _, identifier in ipairs(added or {}) do
        toastPlayer(findSourceByIdentifier(identifier), '✓', 'Convoy Roster',
            ('You\'ve been signed up for "%s" — join it from the live panel once it departs.'):format(def.name), false)
    end
    for _, identifier in ipairs(removed or {}) do
        toastPlayer(findSourceByIdentifier(identifier), '✕', 'Convoy Roster',
            ('You were removed from "%s"\'s roster.'):format(def.name), true)
    end
    return { ok = true }
end)

-- Open to any online player (both gangs and police) — DRAFT/SCHEDULED
-- convoys not yet departed, so both sides can see what's coming and
-- pre-register before it goes live instead of only finding out once it's
-- already active. GANG_AIRDROP stays invisible to police even here, same
-- rule as everywhere else this event kind surfaces (see visibleToCaller).
lib.callback.register('nova_convoytruck:getUpcomingConvoys', function(source)
    local isPolice = Bridge.IsPolice(source)
    local govView = govStatusView(source)
    local identifier = Bridge.GetIdentifier(source)
    -- Not police-gated the same way rosters are — a non-leader gang member
    -- has no picker access at all (that's the leader's roster card), so
    -- this is the ONLY way they can even tell they've already been signed
    -- up, let alone back out of it themselves (see unregisterSelfFromGang
    -- below).
    local myGangName = (not isPolice and not govView) and (function()
        local g = GangService.GetPlayerGang(source)
        return g and g.name or nil
    end)() or nil
    -- Same hard invite-only gate as getRosterConvoys — a gang not on the
    -- admin's TDM allow-list shouldn't even see it listed as upcoming.
    local function tdmVisible(def)
        if def.kind ~= 'TDM' then return true end
        if def.tdm and def.tdm.matchFormat == 'TOURNAMENT' then return false end
        local ag = def.settings and def.settings.allowedGangs
        if not ag or ag.mode ~= 'SELECTED' then return true end
        if not myGangName then return false end
        for _, name in ipairs(ag.gangs or {}) do
            if name == myGangName then return true end
        end
        return false
    end
    local list = {}
    for _, def in ipairs(ConvoyManager.getAll()) do
        if (def.status == 'DRAFT' or def.status == 'SCHEDULED') and visibleToCaller(source, def) and tdmVisible(def)
            and (not govView or govKindVisible(def.kind)) then
            local registered = false
            for _, entry in ipairs(def.policeRoster or {}) do
                if entry.identifier == identifier then registered = true break end
            end
            local gangRegistered = false
            local gangRegisteredCount = 0
            if myGangName then
                local myGangRoster = (def.roster and def.roster[myGangName]) or {}
                gangRegisteredCount = #myGangRoster
                for _, ident in ipairs(myGangRoster) do
                    if ident == identifier then gangRegistered = true break end
                end
                if not gangRegistered and gangRegisteredCount > 0 then
                    -- For gang leaders or members with register permission, consider it registered if gang has a roster
                    local myGang = GangService.GetGangByName(myGangName)
                    if myGang and (myGang.leaderIdentifier == identifier or GangService.HasPermission(source, 'registerRoster')) then
                        gangRegistered = true
                    end
                end
            end
            -- how this kind is signed up for (see Config.AuctionRegistration): NONE / GANG (one click for the whole gang) / ROSTER (members picked)
            local mode = 'ROSTER'
            if def.kind == 'GANG_AIRDROP' or def.kind == 'HOT_CARGO' or def.kind == 'CRACKDOWN' or openToEveryone(def) then mode = 'NONE'
            elseif def.kind == 'CONTAINER_WARS' or def.kind == 'GANG_TERRITORY' then mode = 'GANG' end
            local gangsRegistered = 0
            for _, list in pairs(def.roster or {}) do if #list > 0 then gangsRegistered = gangsRegistered + 1 end end
            if mode == 'GANG' then gangRegistered = gangRegisteredCount > 0 end
            local maxGangCap = (def.maxGangParticipants and tonumber(def.maxGangParticipants) > 0) and tonumber(def.maxGangParticipants) or (Config.MaxGangParticipants or 20)
            local maxPoliceCap = (def.maxPoliceParticipants and tonumber(def.maxPoliceParticipants) > 0) and tonumber(def.maxPoliceParticipants) or (Config.MaxPoliceParticipants or 20)
            list[#list + 1] = {
                id = def.id, name = def.name, shortDescription = def.shortDescription,
                cargo = def.cargo, difficulty = def.difficulty, kind = def.kind, tdm = def.tdm,
                status = def.status, scheduledAt = def.scheduledAt,
                maxGangParticipants = maxGangCap, maxPoliceParticipants = maxPoliceCap,
                gangPvp = def.settings.gangPvp,
                policeRegisteredCount = #(def.policeRoster or {}),
                policeRegistered = registered,
                gangRegistered = gangRegistered,
                gangRegisteredCount = gangRegisteredCount,
                registrationMode = mode, gangsRegistered = gangsRegistered,
            }
        end
    end
    return { ok = true, convoys = list, isPolice = isPolice, govView = govView }
end)

-- A non-leader gang member removing themselves from a convoy their leader
-- signed them up for — see ConvoyManager.selfUnregisterGang. Deliberately
-- separate from setConvoyRoster (leader-only, replaces the whole list).
lib.callback.register('nova_convoytruck:unregisterSelfFromGangConvoy', function(source, id)
    local ok, result = ConvoyManager.selfUnregisterGang(source, id)
    if not ok then return { ok = false, error = result } end
    return { ok = true }
end)

-- Individual self-registration — no leader concept for police, so (unlike
-- setConvoyRoster above) this is the officer acting on their own behalf,
-- same as joinConvoyPolice is for an already-active convoy.
-- Retired: police no longer sign up for anything through the Event Status panel. They take part in a Convoy
-- automatically (autoJoinPolice in convoy_runtime.lua) and join a street race / Container Wars at the civilian
-- registration ped. Kept registered so an old client gets a clear answer instead of an error.
lib.callback.register('nova_convoytruck:registerPoliceForConvoy', function()
    return { ok = false, error = 'Police take part in convoys automatically — no sign-up needed.' }
end)

lib.callback.register('nova_convoytruck:unregisterPoliceForConvoy', function()
    return { ok = false, error = 'Police take part in convoys automatically — no sign-up needed.' }
end)

-- ── Server-Wide Announcements ────────────────────────────────────────────────────
-- Admin-only (Bridge.IsAdmin, not the broader police-inclusive
-- HasCreatorAccess) — this reaches EVERY connected player regardless of
-- convoy/gang/police involvement, so it needs the same tighter gate as
-- other server-wide-impact settings this session (scheduling, Gang Airdrop
-- creation).

lib.callback.register('nova_convoytruck:announceUpcomingConvoy', function(source, id, customTitle, customMessage, targetAudience)
    if not can(source, 'convoys.manage') then return denied() end
    local def = ConvoyManager.get(id)
    if not def then return { ok = false, error = 'Event not found.' } end
    if not kindAllowed(source, def.kind) then return denied() end
    if def.status ~= 'DRAFT' and def.status ~= 'SCHEDULED' then
        return { ok = false, error = 'Only upcoming (not yet departed) events can be announced this way.' }
    end

    -- Default body resolution from settings/schedule
    local settings = def.settings or {}
    local body
    if settings.announceStartTime and settings.announceStartTime ~= '' then
        body = ('Starts %s.'):format(settings.announceStartTime)
    elseif def.status == 'SCHEDULED' and def.scheduledAt then
        body = ('Starts %s.'):format(Scheduler.formatLocal(def.scheduledAt))
    else
        body = 'No fixed start time yet — keep an eye out.'
    end
    if settings.announceEndTime and settings.announceEndTime ~= '' then
        body = body .. (' Ends %s.'):format(settings.announceEndTime)
    end
    if settings.announceMessage and settings.announceMessage ~= '' then
        body = body .. '\n' .. settings.announceMessage
    end
    if def.shortDescription and def.shortDescription ~= '' then
        body = def.shortDescription .. '\n' .. body
    end

    local isAirdrop = def.kind == 'GANG_AIRDROP'
    local isHotCargo = def.kind == 'HOT_CARGO'
    local isTdm = def.kind == 'TDM'
    local isContainerWars = def.kind == 'CONTAINER_WARS'
    local isRace = def.kind == 'GANG_RACE'
    local isTerritory = def.kind == 'GANG_TERRITORY'
    local isCrackdown = def.kind == 'CRACKDOWN'

    local defaultTitle
    local defaultKind
    local bCfg
    if isCrackdown then
        defaultTitle = 'Operation Crackdown: %s'
        defaultKind = 'crackdown'   -- the event's own banner theme + image (eventThemes.js / Event Banner Images)
    elseif isTerritory then
        defaultTitle = 'Upcoming Gang Territory Auction: %s'
        defaultKind = 'territory'
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingTerritory
    elseif isAirdrop then
        defaultTitle = 'Upcoming Gang Airdrop: %s'
        defaultKind = 'airdrop'
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingAirdrop
    elseif isHotCargo then
        defaultTitle = 'Upcoming Hot Cargo Run: %s'
        defaultKind = 'hotcargo'
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingHotCargo
    elseif isTdm then
        defaultTitle = 'Upcoming TDM Match: %s'
        defaultKind = 'tdm'
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingTdm
    elseif isContainerWars then
        defaultTitle = 'Upcoming Container Wars: %s'
        defaultKind = 'containerwars'   -- the event's own banner theme (eventThemes.js)
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingContainerWars
    elseif isRace then
        defaultTitle = 'Upcoming Street Race: %s'
        defaultKind = 'rally'
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingRace
    else
        defaultTitle = 'Upcoming Convoy Event: %s'
        defaultKind = 'convoy'
        bCfg = Config.AnnouncementBanners and Config.AnnouncementBanners.upcomingConvoy
    end

    local titleTemplate = (bCfg and bCfg.title) or defaultTitle
    local duration = (bCfg and (bCfg.duration or bCfg.durationMs)) or 10000
    local kind = (bCfg and bCfg.kind) or defaultKind
    local ok, title = pcall(string.format, titleTemplate, def.name)
    if not ok then title = defaultTitle:format(def.name) end

    -- Allow admin custom overrides
    if customTitle and type(customTitle) == 'string' and customTitle:match('%S') then
        title = customTitle:sub(1, 100)
    end
    if customMessage and type(customMessage) == 'string' and customMessage:match('%S') then
        body = customMessage:sub(1, 500)
    end

    targetAudience = targetAudience or 'EVERYONE'

    for _, src in ipairs(Bridge.GetPlayers()) do
        if targetAudience == 'GANG_ONLY' then
            local g = GangService and GangService.GetPlayerGang(src)
            if g and g.name and g.name ~= 'independent' and g.name ~= 'civilian' then
                TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body, duration, kind)
            end
        else
            TriggerClientEvent('nova_convoytruck:runtime:announce', src, title, body, duration, kind)
        end
    end
    if DiscordLog and DiscordLog.appendEvent then
        DiscordLog.appendEvent(id, ('📢 [ANNOUNCEMENT] (%s) %s — %s'):format(targetAudience, title, body))
    end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:civilian:getAvailableEvents', function(source)
    local defs = (ConvoyManager and ConvoyManager.getAll and ConvoyManager.getAll()) or {}
    local available = {}
    local identifier = Bridge.GetIdentifier(source)

    for _, def in ipairs(defs) do
        local isRace = def.kind == 'GANG_RACE'
        local isCw = def.kind == 'CONTAINER_WARS'

        if (isRace or isCw) and (def.settings and def.settings.eventAccess == 'EVERYONE') then
            if def.status ~= 'COMPLETED' and def.status ~= 'CANCELLED' and def.status ~= 'FAILED' and def.status ~= 'CAPTURED' then
                local rt = Runtime and Runtime.get and Runtime.get(def.id)
                local cwRt = ContainerWars and ContainerWars.get and ContainerWars.get(def.id)
                local isRegistered = false

                if isRace then
                    if rt and rt.participants and rt.participants.identifiers and rt.participants.identifiers[identifier] then
                        isRegistered = true
                    elseif def.civilianRoster then
                        for _, id in ipairs(def.civilianRoster) do
                            if id == identifier then isRegistered = true break end
                        end
                    end
                elseif isCw then
                    if cwRt and cwRt.participants and cwRt.participants.civilians and cwRt.participants.civilians[identifier] then
                        isRegistered = true
                    elseif def.civilianRoster then
                        for _, id in ipairs(def.civilianRoster) do
                            if id == identifier then isRegistered = true break end
                        end
                    end
                end

                local participantCount = 0
                if isRace then
                    if rt and rt.participants and rt.participants.identifiers then
                        for _ in pairs(rt.participants.identifiers) do participantCount = participantCount + 1 end
                    elseif def.civilianRoster then
                        participantCount = #def.civilianRoster
                    end
                elseif isCw then
                    if cwRt and cwRt.participants and cwRt.participants.identifiers then
                        for _ in pairs(cwRt.participants.identifiers) do participantCount = participantCount + 1 end
                    end
                end

                local maxParticipants = tonumber(def.maxGangParticipants or Config.MaxGangParticipants or 20)

                available[#available + 1] = {
                    id = def.id,
                    name = def.name,
                    kind = def.kind,
                    status = (rt and (rt.phase or 'ACTIVE')) or (cwRt and 'ACTIVE') or def.status,
                    scheduledAt = def.scheduledAt,
                    recurrence = def.recurrence,
                    shortDescription = def.shortDescription or '',
                    locationName = (def.settings and def.settings.locationName) or (isRace and 'City Streets' or 'Terminal / Docks'),
                    entryFee = tonumber(def.settings and def.settings.entryFee) or 0,
                    participantCount = participantCount,
                    maxParticipants = maxParticipants,
                    isRegistered = isRegistered,
                    settings = def.settings,
                }
            end
        end
    end
    return { ok = true, events = available }
end)

lib.callback.register('nova_convoytruck:sendServerAnnouncement', function(source, title, body, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom)
    if not can(source, 'announcements.create') then return denied() end
    if type(title) ~= 'string' or title == '' then return { ok = false, error = 'Title is required.' } end
    local color = type(bannerColor) == 'string' and bannerColor:sub(1, 20) or nil
    local img = type(imageUrl) == 'string' and imageUrl:sub(1, 2048) or nil
    local pos = type(imagePosition) == 'string' and imagePosition:sub(1, 50) or nil
    local fit = type(imageFit) == 'string' and imageFit:sub(1, 20) or nil
    local px = type(posX) == 'number' and posX or nil
    local py = type(posY) == 'number' and posY or nil
    local zm = type(zoom) == 'number' and zoom or nil
    for _, src in ipairs(Bridge.GetPlayers()) do
        TriggerClientEvent('nova_convoytruck:runtime:announce', src, title:sub(1, 100), tostring(body or ''):sub(1, 500), 10000, 'info', nil, nil, color, img, pos, fit, px, py, zm)
    end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:previewServerAnnouncement', function(source, title, body, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom)
    if not can(source, 'announcements.create') then return denied() end
    if type(title) ~= 'string' or title == '' then return { ok = false, error = 'Title is required.' } end
    local color = type(bannerColor) == 'string' and bannerColor:sub(1, 20) or nil
    local img = type(imageUrl) == 'string' and imageUrl:sub(1, 2048) or nil
    local pos = type(imagePosition) == 'string' and imagePosition:sub(1, 50) or nil
    local fit = type(imageFit) == 'string' and imageFit:sub(1, 20) or nil
    local px = type(posX) == 'number' and posX or nil
    local py = type(posY) == 'number' and posY or nil
    local zm = type(zoom) == 'number' and zoom or nil
    TriggerClientEvent('nova_convoytruck:runtime:announce', source, title:sub(1, 100), tostring(body or ''):sub(1, 500), 10000, 'info', nil, nil, color, img, pos, fit, px, py, zm)
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:getEventBanners', function(source)
    return { ok = true, banners = DB.getEventBanners() }
end)

lib.callback.register('nova_convoytruck:saveEventBanner', function(source, eventKey, imageUrl, posX, posY, zoom, fit)
    if not can(source, 'announcements.edit') then return denied() end
    if not eventKey or type(eventKey) ~= 'string' then return { ok = false, error = 'Event key is required.' } end
    local ok = DB.saveEventBanner(eventKey, imageUrl, posX, posY, zoom, fit)
    if not ok then return { ok = false, error = 'Failed to save event banner.' } end

    local banners = DB.getEventBanners()
    TriggerClientEvent('nova_convoytruck:client:updateEventBanners', -1, banners)
    return { ok = true, banners = banners }
end)

-- Resolves the caller's own gang and confirms they hold the required
-- permission, or returns a ready-to-send error. Civilian gang members manage
-- their own roster from the live panel, not the admin tablet, so these are
-- deliberately NOT HasCreatorAccess-gated.
--
-- `permission` defaults to 'manageGang' (the historical behaviour, when only
-- the leader could get here). Passing 'registerRoster' lets a leader-granted
-- custom role sign the gang up for events without also handing them member
-- management — see GangService.SetRolePermission.
local function myPermittedGang(source, permission)
    permission = permission or 'manageGang'

    -- Same rule as Runtime.joinGang/ConvoyManager.setGangRoster — an on-duty
    -- officer must never be able to manage a gang's roster, even one they're
    -- nominally a leader/member of from earlier testing/other characters.
    if Bridge.IsPolice(source) then return nil, { ok = false, error = 'On-duty police cannot manage a gang.' } end
    local gang = GangService.GetPlayerGang(source)
    if not gang then return nil, { ok = false, error = 'You are not in a gang.' } end
    local myGang
    for _, g in ipairs(GangService.GetGangs()) do
        if g.name == gang.name then myGang = g break end
    end
    if not myGang then return nil, { ok = false, error = 'Gang not found.' } end

    -- Delegates to the central resolver so a leader-granted role works here
    -- exactly as it does everywhere else, and so the leader is always allowed.
    if not GangService.HasPermission(source, permission) then
        if permission == 'registerRoster' then
            return nil, { ok = false, error = 'You do not have permission to register your gang for events.' }
        end
        return nil, { ok = false, error = 'You do not have permission to manage this gang.' }
    end
    return myGang
end

-- Kept as a thin alias: member-management callbacks below read better with
-- the older name, and it pins the permission explicitly.
local function myLedGang(source)
    return myPermittedGang(source, 'manageGang')
end

-- Resolves a target player either by numeric server ID or partial/exact player name
local function resolveTargetPlayer(targetInput)
    if not targetInput then return nil end
    local str = tostring(targetInput):gsub('^%s*(.-)%s*$', '%1')
    if str == '' then return nil end

    local num = tonumber(str)
    if num and GetPlayerName(num --[[@as string]]) then
        return num
    end

    local targetLower = str:lower()
    local players = Bridge.GetPlayers()
    for _, src in ipairs(players) do
        local name = Bridge.GetPlayerName(src)
        if name and name:lower() == targetLower then
            return src
        end
    end
    for _, src in ipairs(players) do
        local name = Bridge.GetPlayerName(src)
        if name and name:lower():find(targetLower, 1, true) then
            return src
        end
    end
    return nil
end

-- Discord post for a member added through a tablet (the admin tablet's Invite Member, or a gang leader's Add Member). The
-- player can be named by server ID, by name, or picked from the online list - all end here. Config.DiscordLogs.gangChanges = false turns it off.
local function logGangMemberAdded(gangId, targetSource, rank, actorSource, byLeader)
    if (Config.DiscordLogs or {}).gangChanges == false then return end
    if not (DiscordLog and DiscordLog.send) then return end
    local gangLabel = tostring(gangId)
    for _, g in ipairs(GangService.GetGangs() or {}) do
        if g.id == gangId then gangLabel = g.label or g.name or gangLabel break end
    end
    local who = tostring(Bridge.GetCharacterName(actorSource) or Bridge.GetPlayerName(actorSource) or 'Unknown')
    pcall(DiscordLog.send, ('👥 [GANG] Member added — %s'):format(gangLabel), nil, 0x5aa2f0, {
        { name = 'Player', value = ('%s (server ID %s)\n`%s`'):format(tostring(Bridge.GetPlayerName(targetSource) or 'Unknown'), tostring(targetSource), tostring(Bridge.GetIdentifier(targetSource) or 'N/A')), inline = true },
        { name = 'Rank', value = tostring(rank or 'Member'), inline = true },
        { name = byLeader and 'Added by gang leader' or 'Added by admin', value = who, inline = true },
    })
end

-- ── Roles: ONE set of rules for both panels ────────────────────────────────────────
-- A gang's roles are its rank names plus what each may do (manageGang / registerRoster). The leader edits them in Event Status,
-- an admin in the tablet's Gang Management; both go through the functions below, so the checks cannot differ.
--   · 'Member' is the default role everyone starts with: it cannot be renamed or deleted.
--   · 'Leader' is a role of its own that only the gang's leader holds, whatever rank is stored for them. It has every permission,
--     cannot be edited, assigned to anyone else, or used as a name for a new role.
--   · A gang may have at most Config.GangRoles.maxCustomRoles roles of its own on top of those two (default 5), so a gang cannot
--     fill the list with dozens of roles. The limit counts roles that exist, wherever they were created.
--   · A rank can only be given to a member if that role exists (no free-typed ranks).
local DEFAULT_ROLE = 'Member'
local LEADER_ROLE = 'Leader'

local function maxCustomRoles()
    local n = tonumber((Config.GangRoles or {}).maxCustomRoles)
    if n == nil then n = 5 end
    return math.max(0, math.floor(n))
end

-- the role a member really holds: the leader is always 'Leader'; nobody else can hold that name
local function roleOfMember(gang, m)
    if m.identifier == gang.leaderIdentifier then return LEADER_ROLE end
    local r = m.rank or DEFAULT_ROLE
    if r == LEADER_ROLE then return DEFAULT_ROLE end
    return r
end

local function gangRoleExists(gang, rank)
    if rank == DEFAULT_ROLE then return true end
    if rank == LEADER_ROLE then return false end      -- never assignable
    for _, m in ipairs(gang.members or {}) do
        if roleOfMember(gang, m) == rank then return true end
    end
    local perms = GangService.GetRolePermissions(gang.id) or {}
    return perms[rank] ~= nil
end

local function roleName(value)
    if type(value) ~= 'string' then return nil end
    local s = value:gsub('^%s+', ''):gsub('%s+$', ''):gsub('[%c]', ' ')
    s = s:sub(1, 40)
    if s == '' then return nil end
    return s
end

-- The role list of a gang with a head-count each, the Leader and Member roles always present. Also returns the permission map and
-- how many roles the gang has of its own (counted against the limit).
local function buildGangRoles(gang)
    local ranks, seen = {}, {}
    local function add(name, leaderRole)
        if not seen[name] then
            seen[name] = { name = name, count = 0, isLeaderRole = leaderRole == true }
            ranks[#ranks + 1] = seen[name]
        end
        return seen[name]
    end
    add(LEADER_ROLE, true)
    add(DEFAULT_ROLE, false)
    for _, m in ipairs(gang.members or {}) do
        local e = add(roleOfMember(gang, m), false)
        e.count = e.count + 1
    end
    -- roles created before anyone holds them
    local permissionMap = GangService.GetRolePermissions(gang.id) or {}
    for rankName in pairs(permissionMap) do
        if rankName ~= LEADER_ROLE then add(rankName, false) end
    end
    table.sort(ranks, function(a, b)
        if a.isLeaderRole ~= b.isLeaderRole then return a.isLeaderRole end
        if (a.name == DEFAULT_ROLE) ~= (b.name == DEFAULT_ROLE) then return a.name == DEFAULT_ROLE end
        return tostring(a.name) < tostring(b.name)
    end)
    local custom = 0
    for _, r in ipairs(ranks) do
        if not r.isLeaderRole and r.name ~= DEFAULT_ROLE then custom = custom + 1 end
    end
    return ranks, permissionMap, custom
end

local function rolesPayload(gang)
    local ranks, permissionMap, custom = buildGangRoles(gang)
    return { permissions = permissionMap, ranks = ranks, customRoles = custom, maxRoles = maxCustomRoles() }
end

local function applyRolePermission(gang, rank, permission, enabled)
    rank = roleName(rank)
    if not rank then return { ok = false, error = 'A role name is required.' } end
    if rank == LEADER_ROLE then return { ok = false, error = 'The leader already has every permission.' } end
    if not gangRoleExists(gang, rank) then return { ok = false, error = 'That role does not exist.' } end
    local ok, err = GangService.SetRolePermission(gang.id, rank, permission, enabled)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gang.id)
    return { ok = true }
end

local function applyRoleSave(gang, rank, permissionsTable)
    rank = roleName(rank)
    if not rank then return { ok = false, error = 'Role name is required.' } end
    if rank:lower() == LEADER_ROLE:lower() then return { ok = false, error = '"Leader" is reserved for the gang leader.' } end
    if not gangRoleExists(gang, rank) then
        local _, _, custom = buildGangRoles(gang)
        local limit = maxCustomRoles()
        if custom >= limit then
            return { ok = false, error = ('A gang can have at most %d roles of its own (besides Leader and Member). Delete one first.'):format(limit) }
        end
    end
    local ok, err = GangService.SetRolePermissions(gang.id, rank, type(permissionsTable) == 'table' and permissionsTable or {})
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gang.id)
    return { ok = true }
end

local function applyRoleRename(gang, oldRank, newRank)
    oldRank, newRank = roleName(oldRank), roleName(newRank)
    if not oldRank then return { ok = false, error = 'Current role name required.' } end
    if not newRank then return { ok = false, error = 'New role name required.' } end
    if oldRank == DEFAULT_ROLE then return { ok = false, error = 'The default Member role cannot be renamed.' } end
    if oldRank == LEADER_ROLE then return { ok = false, error = 'The leader\'s role cannot be renamed.' } end
    if newRank:lower() == LEADER_ROLE:lower() then return { ok = false, error = '"Leader" is reserved for the gang leader.' } end
    if oldRank ~= newRank and gangRoleExists(gang, newRank) then return { ok = false, error = 'A role with that name already exists.' } end
    local ok, err = GangService.RenameRole(gang.id, oldRank, newRank)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gang.id)
    return { ok = true }
end

local function applyRoleDelete(gang, rank)
    rank = roleName(rank)
    if not rank then return { ok = false, error = 'Role name required.' } end
    if rank == DEFAULT_ROLE then return { ok = false, error = 'The default Member role cannot be deleted.' } end
    if rank == LEADER_ROLE then return { ok = false, error = 'The leader\'s role cannot be deleted.' } end
    local ok, err = GangService.DeleteRole(gang.id, rank)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gang.id)
    return { ok = true }
end

-- targetServerId: in-game server id or player name
lib.callback.register('nova_convoytruck:addOwnGangMember', function(source, targetServerId, rank)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    rank = roleName(rank) or DEFAULT_ROLE
    if not gangRoleExists(myGang, rank) then return { ok = false, error = 'That role does not exist — create it first.' } end

    local targetSource = resolveTargetPlayer(targetServerId)
    if not targetSource then
        return { ok = false, error = 'Player not found or not online.' }
    end
    local ok, addErr = GangService.AddMember(myGang.id, targetSource, rank)
    if not ok then return { ok = false, error = addErr } end
    notifyGangRosterChange(myGang.id, Bridge.GetIdentifier(targetSource), true)
    logGangMemberAdded(myGang.id, targetSource, rank, source, true)
    return { ok = true }
end)

-- Self-service recruit picker: online players eligible to be added, so the
-- leader clicks a name instead of typing a raw Server ID blind. Same
-- eligibility GangService.AddMember itself enforces (not already in any
-- gang) — this is just what populates the list; the server still validates
-- again at add time. On-duty police are excluded since they can never
-- actually be added (myLedGang/joinGang both reject police either side).
lib.callback.register('nova_convoytruck:getAvailableGangRecruits', function(source)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    local list = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        if src ~= source and not Bridge.IsPolice(src) then
            local identifier = Bridge.GetIdentifier(src)
            if identifier and not GangService.GetPlayerGang(src) then
                list[#list + 1] = { serverId = src, name = Bridge.GetPlayerName(src) or ('Player %d'):format(src) }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return { ok = true, players = list }
end)

lib.callback.register('nova_convoytruck:removeOwnGangMember', function(source, identifier)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    if identifier == Bridge.GetIdentifier(source) then
        return { ok = false, error = 'You cannot remove yourself as leader.' }
    end

    local ok, removeErr = GangService.RemoveMember(myGang.id, identifier)
    if not ok then return { ok = false, error = removeErr } end
    notifyGangRosterChange(myGang.id, identifier, false)
    return { ok = true }
end)

-- Transfers leadership — the caller must already BE the leader (myLedGang),
-- and there's only one leaderIdentifier column, so promoting someone new
-- means the caller stops being leader themselves the moment this succeeds.
lib.callback.register('nova_convoytruck:setOwnGangLeader', function(source, identifier)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    -- A role granted manageGang can run the roster but must never be able to
    -- take or hand over the gang's leadership — that stays with the leader.
    if myGang.leaderIdentifier ~= Bridge.GetIdentifier(source) then
        return { ok = false, error = 'Only the gang leader can transfer leadership.' }
    end
    if identifier == Bridge.GetIdentifier(source) then
        return { ok = false, error = 'You are already the leader.' }
    end
    local ok, setErr = GangService.SetLeader(myGang.id, identifier)
    if not ok then return { ok = false, error = setErr } end
    notifyGangChanged(myGang.id)
    toastPlayer(findSourceByIdentifier(identifier), '👑', 'Gang Update', ('You are now the leader of %s.'):format(myGang.label), false)
    return { ok = true }
end)

-- Assigns one of the gang's existing roles (a rank string) to a member. Needs
-- manageGang; the leader's own role can't be changed here, and only the leader may
-- change their own... nobody's own role but the leader's, so a manager cannot
-- promote themselves into a role with more rights.
lib.callback.register('nova_convoytruck:setOwnGangMemberRank', function(source, identifier, rank)
    local myGang, err = myLedGang(source)
    if not myGang then return err end

    rank = tostring(rank or ''):sub(1, 40)
    if rank == '' then return { ok = false, error = 'Pick a role.' } end
    if type(identifier) ~= 'string' then return { ok = false, error = 'Invalid member.' } end

    local callerId = Bridge.GetIdentifier(source)
    local isLeader = myGang.leaderIdentifier == callerId
    if identifier == myGang.leaderIdentifier then return { ok = false, error = 'The leader\'s role cannot be changed.' } end
    if identifier == callerId and not isLeader then return { ok = false, error = 'You cannot change your own role.' } end

    local isMember = false
    for _, m in ipairs(myGang.members or {}) do
        if m.identifier == identifier then isMember = true end
    end
    if not isMember then return { ok = false, error = 'That player is not in your gang.' } end
    if not gangRoleExists(myGang, rank) then return { ok = false, error = 'That role does not exist — create it first.' } end

    GangService.SetMemberRank(myGang.id, identifier, rank)
    notifyGangChanged(myGang.id)
    return { ok = true }
end)

-- ── Role Permissions ────────────────────────────────────────────────────────────
-- A gang leader can grant, per RANK, either of two permissions to the roles he
-- creates (ranks are just the rank strings already assigned via
-- setOwnGangMemberRank — no separate role list to keep in sync):
--   manageGang     — add/remove/promote members, edit gang settings
--   registerRoster — register the gang for events on the leader's behalf
-- The leader always holds both and cannot revoke them from himself.
--
-- Managing the permission map itself requires 'manageGang', so a role granted
-- only 'registerRoster' cannot escalate itself into member management.

-- Read-only view of the whole map plus the caller's own effective rights, so
-- the UI can render the permission grid and decide which tabs to show.
lib.callback.register('nova_convoytruck:getGangRolePermissions', function(source)
    if Bridge.IsPolice(source) then return { ok = false, error = 'On-duty police cannot manage a gang.' } end
    local gang = GangService.GetPlayerGang(source)
    if not gang then return { ok = false, error = 'You are not in a gang.' } end

    local isAdmin = Bridge.IsAdmin(source, Config.CreatorAccess.adminPermission) or false
    local ctx = GangService.GetPermissionContext(source, isAdmin)

    -- Every member of the gang may SEE the roles and what each allows (so they can tell what they or a teammate may do and who to
    -- ask); only manageGang changes anything (the write callbacks check it themselves). canManage tells the UI which one it is.
    local myGang
    for _, g in ipairs(GangService.GetGangs()) do
        if g.name == gang.name then myGang = g break end
    end
    if not myGang then return { ok = false, error = 'Gang not found.' } end

    -- the same role list the admin tablet's Gang Management shows (buildGangRoles)
    local out = rolesPayload(myGang)
    out.ok = true
    out.myRank = ctx.gangRank
    out.isLeader = ctx.isLeader
    out.canManage = ctx.canManageGang == true
    return out
end)

-- permission is validated against a fixed allow-list inside GangService, so a
-- crafted call can't write arbitrary keys into the JSON blob.
lib.callback.register('nova_convoytruck:setGangRolePermission', function(source, rank, permission, enabled)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    return applyRolePermission(myGang, rank, permission, enabled)
end)

lib.callback.register('nova_convoytruck:saveGangRole', function(source, rank, permissionsTable)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    return applyRoleSave(myGang, rank, permissionsTable)
end)

lib.callback.register('nova_convoytruck:renameGangRole', function(source, oldRank, newRank)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    return applyRoleRename(myGang, oldRank, newRank)
end)

lib.callback.register('nova_convoytruck:deleteGangRole', function(source, rank)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    return applyRoleDelete(myGang, rank)
end)

-- Open to any player — gang standings aren't sensitive, and both the gang
-- live panel and the admin tablet's Leaderboard tab read this same list.
-- kind (optional): 'CONVOY' (default) | 'HOT_CARGO' | 'GANG_AIRDROP' | 'GANG_RACE' | 'TDM' | 'CONTAINER_WARS' — which
-- event kind's win count the list is sorted by. Every gang's full stats
-- (all three kinds) come back regardless, so the client can switch kind
-- tabs locally without another round-trip; only the sort order changes.
lib.callback.register('nova_convoytruck:getGangLeaderboard', function(source, kind)
    local list = {}
    -- Gang XP (spendable balance + lifetime) rides along on every row so both leaderboards show the same XP column.
    local xpByGang = {}
    for _, r in ipairs(DB.gangXpAll() or {}) do xpByGang[r.gang_name] = r end
    local owned = (Territory and Territory.ownerSummary and Territory.ownerSummary()) or {}
    for _, g in ipairs(GangService.GetGangs()) do
        local leaderName = nil
        if g.leaderIdentifier then
            for _, m in ipairs(g.members or {}) do
                if m.identifier == g.leaderIdentifier then
                    leaderName = m.name
                    break
                end
            end
        end
        local o = owned[g.name] or {}
        list[#list + 1] = {
            name = g.name, label = g.label, logo = g.logo, accentColor = g.accentColor, stats = g.stats,
            leaderName = leaderName, memberCount = #(g.members or {}),
            xp = xpByGang[g.name] and tonumber(xpByGang[g.name].total_xp) or 0,
            lifetimeXp = xpByGang[g.name] and tonumber(xpByGang[g.name].lifetime_xp) or 0,
            territories = o.count or 0,
            areaKm2 = o.areaKm2 or 0,
        }
    end
    local function wins(entry)
        local s = entry.stats
        if not s then return 0 end
        if kind == 'HOT_CARGO' then return (s.HOT_CARGO and s.HOT_CARGO.completed) or 0 end
        if kind == 'GANG_AIRDROP' then return (s.GANG_AIRDROP and s.GANG_AIRDROP.completed) or 0 end
        if kind == 'GANG_RACE' then return (s.GANG_RACE and s.GANG_RACE.wins) or 0 end
        if kind == 'TDM' then return (s.TDM and s.TDM.wins) or 0 end
        if kind == 'CONTAINER_WARS' then return (s.CONTAINER_WARS and s.CONTAINER_WARS.wins) or 0 end
        return s.convoysCaptured or 0
    end
    table.sort(list, function(a, b) return wins(a) > wins(b) end)
    return { ok = true, gangs = list }
end)

-- 400KB is generous for a downscaled logo (the client resizes to a small
-- square canvas before encoding) and cheap insurance against someone hand-
-- crafting a request with a multi-megabyte data URL straight to the callback.
local MAX_LOGO_LENGTH = 400 * 1024

lib.callback.register('nova_convoytruck:setOwnGangLogo', function(source, logo)
    local myGang, err = myLedGang(source)
    if not myGang then return err end
    if logo and #logo > MAX_LOGO_LENGTH then return { ok = false, error = 'Logo image is too large.' } end
    local ok, setErr = GangService.SetLogo(myGang.id, logo or nil)
    if not ok then return { ok = false, error = setErr } end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:leaveConvoyGang', function(source, id)
    local ok, err = Runtime.leaveGang(source, id)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- Retired along with the pre-registration above (see autoJoinPolice in convoy_runtime.lua).
lib.callback.register('nova_convoytruck:joinConvoyPolice', function()
    return { ok = false, error = 'Police are joined to convoys automatically.' }
end)

lib.callback.register('nova_convoytruck:leaveConvoyPolice', function()
    return { ok = false, error = 'Police take part in convoys automatically.' }
end)

-- Live state for the police/gang tablets — any online player may read this
-- (it's the whole point of the live view), but it only ever exposes the
-- fields Runtime.getPublicState chooses to expose, never raw convoy internals.
lib.callback.register('nova_convoytruck:getActiveConvoys', function(source)
    local list = {}
    -- Per-gang participation breakdown is admin/creator-access only (see
    -- getPublicState) — this is the ONLY place that decides who gets it, so
    -- the gang-facing tablet never receives it in the first place rather
    -- than receiving-but-hiding it.
    -- Needs a tablet section that shows event participation — NOT just "has some tablet access", so a limited staff
    -- member who is also in a gang never receives other gangs' data.
    local showGangBreakdown = canAny(source, 'participants.view', 'convoys.view', 'dashboard.view')
    local isPolice = Bridge.IsPolice(source)
    local govView = govStatusView(source)
    for _, id in ipairs(Runtime.getActive()) do
        local def = ConvoyManager.get(id)
        -- GANG_AIRDROP, GANG_RACE, TDM, and CONTAINER_WARS are invisible to police — not
        -- listed, not joinable, no live-panel entry at all.
        -- The government view of the Event Status panel (a gang member on an on-duty government job) lists ONLY
        -- Config.StatusPanel.govEventKinds (Convoy, Rally Race, Container Wars), whatever else is running.
        if def and govView then
            if govKindVisible(def.kind) then
                local state = Runtime.getPublicState(id, false)
                if state then
                    state.joined = Runtime.isParticipant(id, source)
                    state.policeJoined = Runtime.isPoliceParticipant(id, source)
                    list[#list + 1] = state
                end
            end
        elseif def and ((def.kind ~= 'GANG_AIRDROP' and def.kind ~= 'GANG_RACE' and def.kind ~= 'TDM' and def.kind ~= 'CONTAINER_WARS' and def.kind ~= 'GANG_TERRITORY') or not isPolice or can(source, 'create.manage')) then
            local state = Runtime.getPublicState(id, showGangBreakdown)
            if state then
                state.joined = Runtime.isParticipant(id, source)
                state.policeJoined = Runtime.isPoliceParticipant(id, source)
                list[#list + 1] = state
            end
        end
    end
    -- On-duty police never see themselves as "in a gang" here, even if
    -- they're nominally attached to one from earlier testing/other
    -- characters — this is what drives the "Join Convoy" button on the live
    -- panel, and gang participation is police-side-exclusive (see
    -- Runtime.joinGang for the same rule server-enforced on the join itself).
    local myGang = (Bridge.IsPolice(source) or govView) and nil or GangService.GetPlayerGang(source)
    return { ok = true, convoys = list, isPolice = Bridge.IsPolice(source), myGang = myGang, govView = govView }
end)

lib.callback.register('nova_convoytruck:getConvoyHistory', function(source, limit)
    if not canAny(source, 'completed.view', 'dashboard.view') then return denied() end
    -- the specialised kinds' history is only shown to Create Event → Manage; everyone else gets Convoy history only
    local forPolice = not can(source, 'create.manage')
    local rows = DB.getConvoyHistory(limit, forPolice)
    -- The list rows are light (no full report): the three things the table shows come from the report as summary_line / report_winner /
    -- report_rewards, and the report itself is fetched when a row is opened. A TDM / Container Wars row saved before ReportBuilder existed
    -- has no summary line: it is rebuilt once here (at most a handful per visit) and the line is kept on the row.
    local rebuilt = 0
    for _, hrow in ipairs(rows) do
        if not hrow.summary_line and (hrow.kind == 'TDM' or hrow.kind == 'CONTAINER_WARS') and ReportBuilder and not hrow.legacyDone and rebuilt < 8 then
            hrow.legacyDone = true
            rebuilt = rebuilt + 1
            local full = DB.getConvoyHistoryById(hrow.id)
            local ok, rd = pcall(ReportBuilder.legacy, full)
            if ok and type(rd) == 'table' then
                hrow.summary_line, hrow.report_winner = rd.summaryLine, rd.winner
                if rd.rewards and rd.rewards ~= 'None' then hrow.report_rewards = tostring(rd.rewards) end
            end
        end
    end
    -- currentStatus: the UNDERLYING DEFINITION's live status right now, not
    -- this past run's own (frozen-forever) outcome column. Without this the
    -- tablet has no way to tell "still sitting cancelled, Reuse will work"
    -- apart from "already Reuse'd once already (now Draft/Scheduled again),
    -- clicking Reuse a second time will just fail" — both look identical in
    -- this table otherwise, since a definition can be reused/run again any
    -- number of times while its old history rows never change.
    for _, row in ipairs(rows) do
        local def = row.convoy_definition_id and ConvoyManager.get(row.convoy_definition_id)
        row.currentStatus = def and def.status or nil
    end
    return { ok = true, history = rows }
end)

-- Permanently removes one past-run record from Convoy History — the
-- underlying convoy definition (if it still exists) and any OTHER history
-- rows for it are untouched, only this specific run entry disappears.
lib.callback.register('nova_convoytruck:deleteConvoyHistory', function(source, id)
    if not can(source, 'completed.delete') then return denied() end
    if not id then return { ok = false, error = 'Missing history id.' } end
    if not DB.deleteConvoyHistory(id) then
        return { ok = false, error = 'Database delete failed — check the server console for a SQL error.' }
    end
    return { ok = true }
end)

-- Wipes every past-run record at once — the History tab's "Clear All" button.
lib.callback.register('nova_convoytruck:clearConvoyHistory', function(source)
    if not can(source, 'completed.manage') then return denied() end
    if not DB.clearConvoyHistory() then
        return { ok = false, error = 'Database delete failed — check the server console for a SQL error.' }
    end
    return { ok = true }
end)

-- The saved report of one Event History row, as the report builders expect it. Rows saved before TDM / Container Wars had a
-- report are rebuilt from their columns; a row with no saved report at all gets a minimal one so the PDF still opens.
local function reportForHistoryRow(row)
    local reportData = row.reportData
    if (row.kind == 'TDM' or row.kind == 'CONTAINER_WARS') and ReportBuilder then
        local ok, rebuilt = pcall(ReportBuilder.legacy, row)
        if ok and rebuilt then reportData = rebuilt end
    end
    if not reportData then
        local durSec = row.duration or 0
        local durText = ('%dm %02ds'):format(math.floor(durSec / 60), durSec % 60)
        reportData = {
            id = row.id,
            name = row.name,
            kind = row.kind or 'CONVOY',
            startedByName = row.created_by or 'System',
            startedAt = os.time() - durSec,
            endedAt = os.time(),
            durationSeconds = durSec,
            durationText = durText,
            outcome = row.outcome,
            winner = row.winning_gang or 'None',
            winningGang = row.winning_gang,
            rewards = row.reward_summary or 'None',
            fleet = {
                total = row.truck_count or 0,
                delivered = row.outcome == 'COMPLETED' and (row.truck_count or 0) or 0,
                captured = row.outcome == 'CAPTURED' and (row.truck_count or 0) or 0,
                destroyed = row.destroyed_trucks or 0,
            },
            roster = {
                policeCount = row.police_participants or 0,
                gangCount = row.gang_participants or 0,
            },
            interceptions = {},
            gangScorecard = {},
            timeline = {},
        }
    end
    return reportData
end

local REPORT_FILE_SLUGS = { HOT_CARGO = 'hot_cargo', GANG_AIRDROP = 'airdrop', GANG_RACE = 'gang_rally', TDM = 'tdm_match', CONTAINER_WARS = 'container_wars', GANG_TERRITORY = 'territory_auction', CRACKDOWN = 'operation_crackdown' }
local function reportFileNameFor(row)
    local branding = Config.Branding or {}
    local slug = (branding.operationName or 'convoy'):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    if REPORT_FILE_SLUGS[row.kind] then slug = REPORT_FILE_SLUGS[row.kind] end
    return ('%s_report_%s.pdf'):format(slug, tostring(row.id))
end

-- withPdf (default true): the PDF is only generated and sent when asked for — opening the report on screen does not need it.
lib.callback.register('nova_convoytruck:getReportPdf', function(source, id, withPdf)
    if not can(source, 'completed.view') then return denied() end
    if not id then return { ok = false, error = 'Missing history id.' } end
    local row = DB.getConvoyHistoryById(id)
    if not row then return { ok = false, error = 'History record not found.' } end
    local reportData = reportForHistoryRow(row)
    if withPdf == false then return { ok = true, reportData = reportData, fileName = reportFileNameFor(row) } end

    local pdfBytes = PdfGenerator.generateConvoyReport(reportData)
    if not pdfBytes then return { ok = false, error = 'Failed to generate PDF document.' } end
    return { ok = true, base64 = PdfGenerator.base64Encode(pdfBytes), fileName = reportFileNameFor(row), reportData = reportData }
end)

-- "Download PDF": the game's own browser cannot save files, so this returns a short-lived link to the PDF on this
-- resource's HTTP endpoint (server/modules/report_links.lua); the tablet opens it in the player's normal web browser.
-- Config.ReportDownload.baseUrl (optional) overrides the address the player's browser should use; empty = the address
-- the player is connected to.
lib.callback.register('nova_convoytruck:getReportLink', function(source, id)
    if not can(source, 'completed.view') then return denied() end
    if not id then return { ok = false, error = 'Missing history id.' } end
    local row = DB.getConvoyHistoryById(id)
    if not row then return { ok = false, error = 'History record not found.' } end
    local pdfBytes = PdfGenerator.generateConvoyReport(reportForHistoryRow(row))
    if not pdfBytes then return { ok = false, error = 'Failed to generate PDF document.' } end
    local fileName = reportFileNameFor(row)
    local path = ReportLinks.create(pdfBytes, fileName)
    local base = Config.ReportDownload and Config.ReportDownload.baseUrl
    if type(base) ~= 'string' or base == '' then base = nil end
    return { ok = true, path = path, baseUrl = base, fileName = fileName }
end)

-- Posts the PDF report of a finished event to the Discord channel again (a reliable way to get the file when the game's own
-- browser will not save downloads).
lib.callback.register('nova_convoytruck:sendReportToDiscord', function(source, id)
    if not can(source, 'completed.manage') then return denied() end
    if not id then return { ok = false, error = 'Missing history id.' } end
    local cfg = Config.DiscordLogs
    if not (cfg and cfg.enabled and cfg.webhookUrl and cfg.webhookUrl ~= '') then
        return { ok = false, error = 'Discord logging is turned off (Config.DiscordLogs).' }
    end
    local row = DB.getConvoyHistoryById(id)
    if not row then return { ok = false, error = 'History record not found.' } end
    local reportData = reportForHistoryRow(row)
    local pdfBytes = PdfGenerator.generateConvoyReport(reportData)
    if not pdfBytes then return { ok = false, error = 'Failed to generate PDF document.' } end
    local who = Bridge.GetCharacterName(source) or Bridge.GetPlayerName(source) or 'Staff'
    DiscordLog.send(('📄 After-Action Report — %s'):format(row.name or 'Event'),
        ('Report re-sent by %s from Event History.'):format(who), 0x3b82f6, {
            { name = 'Event', value = tostring(row.name or 'Event'), inline = true },
            { name = 'Outcome', value = tostring(row.outcome or '-'), inline = true },
            { name = 'Result', value = tostring(reportData.summaryLine or reportData.winner or '-'):sub(1, 250), inline = false },
        }, pdfBytes, reportFileNameFor(row))
    return { ok = true }
end)

-- Per-event log for one convoy definition (truck/airdrop lockpick
-- successes, who captured it) — separate from the one-row-per-run history
-- summary above, for exactly the fairness case an admin needs it for: a
-- gang killed after looting doesn't erase the record of who actually did
-- the looting.
lib.callback.register('nova_convoytruck:getConvoyEvents', function(source, convoyDefinitionId)
    if not canAny(source, 'completed.view', 'convoys.view') then return denied() end
    return { ok = true, events = DB.getConvoyEvents(convoyDefinitionId) }
end)

lib.callback.register('nova_convoytruck:getDashboard', function(source)
    if not can(source, 'dashboard.view') then return denied() end
    return { ok = true, dashboard = ConvoyManager.getDashboardStats() }
end)

-- ── Gang Management ─────────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:getGangs', function(source)
    if not can(source, 'gangs.view') then return denied() end
    local online = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        local identifier = Bridge.GetIdentifier(src)
        if identifier then online[identifier] = true end
    end
    local gangs = GangService.GetGangs()
    for _, g in ipairs(gangs) do
        local count = 0
        for _, m in ipairs(g.members or {}) do
            m.online = online[m.identifier] == true
            if m.online then count = count + 1 end
        end
        g.onlineCount = count
    end
    return { ok = true, gangs = gangs, provider = Config.GangProvider }
end)

lib.callback.register('nova_convoytruck:createGang', function(source, name, label, maxMembers)
    if not can(source, 'gangs.create') then return denied() end
    if type(name) ~= 'string' or #name < 2 then return { ok = false, error = 'Gang name is too short.' } end
    local ok, result = GangService.CreateGang(name:lower():gsub('%s+', '_'), label or name, maxMembers)
    if not ok then return { ok = false, error = result } end
    return { ok = true, gang = result }
end)

lib.callback.register('nova_convoytruck:updateGang', function(source, gangId, fields)
    if not can(source, 'gangs.edit') then return denied() end
    local ok, err = GangService.UpdateGang(gangId, fields or {})
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gangId)
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:deleteGang', function(source, gangId)
    if not can(source, 'gangs.delete') then return denied() end
    local ok, err = GangService.DeleteGang(gangId)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- targetServerId: in-game server id or player name
lib.callback.register('nova_convoytruck:addGangMember', function(source, gangId, targetServerId, rank)
    if not can(source, 'gangs.manage') then return denied() end
    local gang = gangById(tonumber(gangId) or gangId)
    if not gang then return { ok = false, error = 'Gang not found.' } end
    rank = roleName(rank) or DEFAULT_ROLE
    if not gangRoleExists(gang, rank) then return { ok = false, error = 'That role does not exist — create it under Roles first.' } end
    local targetSource = resolveTargetPlayer(targetServerId)
    if not targetSource then
        return { ok = false, error = 'Player not found or not online.' }
    end
    local ok, err = GangService.AddMember(gangId, targetSource, rank)
    if not ok then return { ok = false, error = err } end
    notifyGangRosterChange(gangId, Bridge.GetIdentifier(targetSource), true)
    logGangMemberAdded(gangId, targetSource, rank, source, false)
    return { ok = true }
end)

-- Admin "Invite Member" picker: the online players who can be added to a gang right now (same eligibility the gang
-- leader's own picker uses: not already in a gang, not on-duty police). AddMember still validates again at add time.
lib.callback.register('nova_convoytruck:getGangRecruitsAdmin', function(source)
    if not can(source, 'gangs.manage') then return denied() end
    local list = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        if not Bridge.IsPolice(src) then
            local identifier = Bridge.GetIdentifier(src)
            if identifier and not GangService.GetPlayerGang(src) then
                list[#list + 1] = { serverId = src, name = Bridge.GetPlayerName(src) or ('Player %d'):format(src) }
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return { ok = true, players = list }
end)

lib.callback.register('nova_convoytruck:removeGangMember', function(source, gangId, identifier)
    if not can(source, 'gangs.manage') then return denied() end
    local ok, err = GangService.RemoveMember(gangId, identifier)
    if not ok then return { ok = false, error = err } end
    notifyGangRosterChange(gangId, identifier, false)
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:setGangLeader', function(source, gangId, identifier)
    if not can(source, 'gangs.manage') then return denied() end
    local ok, err = GangService.SetLeader(gangId, identifier)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gangId)
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:setGangLogo', function(source, gangId, logo)
    if not can(source, 'gangs.edit') then return denied() end
    if logo and #logo > MAX_LOGO_LENGTH then return { ok = false, error = 'Logo image is too large.' } end
    local ok, err = GangService.SetLogo(gangId, logo or nil)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gangId)
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:setGangAccentColor', function(source, gangId, color)
    if not can(source, 'gangs.edit') then return denied() end
    local ok, err = GangService.SetAccentColor(gangId, color or nil)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gangId)
    return { ok = true }
end)

-- Same rule as the leader's version in Event Status: a rank can only be given if that role exists (create it under Roles).
lib.callback.register('nova_convoytruck:setGangMemberRank', function(source, gangId, identifier, rank)
    if not can(source, 'gangs.manage') then return denied() end
    local gang = gangById(tonumber(gangId) or gangId)
    if not gang then return { ok = false, error = 'Gang not found.' } end
    rank = roleName(rank)
    if not rank then return { ok = false, error = 'Pick a role.' } end
    if identifier == gang.leaderIdentifier then return { ok = false, error = 'The leader\'s role cannot be changed.' } end
    if not gangRoleExists(gang, rank) then return { ok = false, error = 'That role does not exist — create it under Roles first.' } end
    local ok, err = GangService.SetMemberRank(gang.id, identifier, rank)
    if not ok then return { ok = false, error = err } end
    notifyGangChanged(gang.id)
    return { ok = true }
end)

-- ── Roles & permissions, admin side ─────────────────────────────────────────────────
-- The very same roles the gang's leader edits in Event Status (one stored list, one set of rules: buildGangRoles /
-- applyRole* above); an admin only addresses the gang by id. Every change pushes both panels to redraw.
local function adminRolesGang(source, gangId)
    if not can(source, 'gangs.manage') then return nil, denied() end
    local gang = gangById(tonumber(gangId) or gangId)
    if not gang then return nil, { ok = false, error = 'Gang not found.' } end
    return gang
end

lib.callback.register('nova_convoytruck:getAdminGangRoles', function(source, gangId)
    if not can(source, 'gangs.view') then return denied() end
    local gang = gangById(tonumber(gangId) or gangId)
    if not gang then return { ok = false, error = 'Gang not found.' } end
    local out = rolesPayload(gang)
    out.ok = true
    return out
end)

lib.callback.register('nova_convoytruck:setAdminGangRolePermission', function(source, gangId, rank, permission, enabled)
    local gang, err = adminRolesGang(source, gangId)
    if not gang then return err end
    return applyRolePermission(gang, rank, permission, enabled)
end)

lib.callback.register('nova_convoytruck:saveAdminGangRole', function(source, gangId, rank, permissionsTable)
    local gang, err = adminRolesGang(source, gangId)
    if not gang then return err end
    return applyRoleSave(gang, rank, permissionsTable)
end)

lib.callback.register('nova_convoytruck:renameAdminGangRole', function(source, gangId, oldRank, newRank)
    local gang, err = adminRolesGang(source, gangId)
    if not gang then return err end
    return applyRoleRename(gang, oldRank, newRank)
end)

lib.callback.register('nova_convoytruck:deleteAdminGangRole', function(source, gangId, rank)
    local gang, err = adminRolesGang(source, gangId)
    if not gang then return err end
    return applyRoleDelete(gang, rank)
end)

-- ── Vehicle Catalog ──────────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:getVehicleCatalog', function(source)
    if not canAny(source, 'create.view', 'convoys.view') then return denied() end
    return { ok = true, vehicles = DB.getVehicleCatalog() }
end)

lib.callback.register('nova_convoytruck:addVehicleCatalogEntry', function(source, model, label, category, imageUrl)
    if not can(source, 'create.edit') then return denied() end
    if type(model) ~= 'string' or model == '' then return { ok = false, error = 'Model is required.' } end
    model = model:lower():gsub('%s+', '')
    if DB.getVehicleCatalogEntryByModel(model) then return { ok = false, error = 'That model is already in the catalog.' } end
    local id = DB.addVehicleCatalogEntry(model, label or model, category or 'CUSTOM', imageUrl)
    return { ok = true, id = id }
end)

lib.callback.register('nova_convoytruck:deleteVehicleCatalogEntry', function(source, id)
    if not can(source, 'create.edit') then return denied() end
    DB.deleteVehicleCatalogEntry(id)
    return { ok = true }
end)

-- ── NPC Spawn Zones ──────────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:getSpawnZones', function(source)
    if not can(source, 'create.view') then return denied() end
    return { ok = true, zones = NpcManager.getZones() }
end)

-- Uses the caller's OWN current position server-side (never a client-supplied
-- coordinate) — walk to the spot in-game, then "Add Zone Here" in the tablet.
lib.callback.register('nova_convoytruck:createSpawnZone', function(source, label, kind, radius)
    if not can(source, 'create.edit') then return denied() end
    if type(label) ~= 'string' or #label < 2 then return { ok = false, error = 'Zone name is too short.' } end
    local ped = GetPlayerPed(source --[[@as string]])
    if not ped or ped == 0 then return { ok = false, error = 'Could not locate you in the world.' } end
    local coords = GetEntityCoords(ped)
    local zoneType = (kind == 'ARMY') and 'ARMY' or 'POLICE'
    local id = DB.createSpawnZone(label, zoneType, coords.x, coords.y, coords.z, math.max(5.0, tonumber(radius) or 25.0))
    return { ok = true, id = id }
end)

lib.callback.register('nova_convoytruck:deleteSpawnZone', function(source, id)
    if not can(source, 'create.edit') then return denied() end
    DB.deleteSpawnZone(id)
    return { ok = true }
end)

-- ── Equipment Vendor Location ────────────────────────────────────────────────────
-- The throwables shop ped (client/modules/equipment.lua), not a convoy
-- checkpoint NPC. Open to every client (not just admins) since anyone
-- connecting needs to know where to spawn the ped locally.

-- Where a ped goes: the position the admin placed with the tablet's hologram ({ x, y, z, heading }), or — as before —
-- where the admin is standing. A ped is saved by its middle, 1 m above the ground (peds are spawned at z - 1.0), which is
-- also what the player's own position is, so the two are interchangeable. Global: token_vendor.lua uses it too.
function PedSpot(source, placed)
    if type(placed) == 'table' and tonumber(placed.x) and tonumber(placed.y) and tonumber(placed.z) then
        return tonumber(placed.x) + 0.0, tonumber(placed.y) + 0.0, tonumber(placed.z) + 0.0, (tonumber(placed.heading) or 0.0) + 0.0
    end
    local ped = GetPlayerPed(source --[[@as string]])
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return c.x, c.y, c.z, GetEntityHeading(ped)
end

lib.callback.register('nova_convoytruck:getEquipmentVendorLocation', function(source)
    return DB.getEquipmentVendorLocation()
end)

-- Uses the caller's own current position server-side, same pattern as
-- createSpawnZone — walk to the spot, then "Set to My Position" in the tablet.
-- Broadcasts to every connected client so the ped moves immediately, no
-- restart required.
lib.callback.register('nova_convoytruck:setEquipmentVendorLocation', function(source, placed)
    if not can(source, 'create.edit') then return denied() end
    local cx, cy, cz, heading = PedSpot(source, placed)
    if not cx then return { ok = false, error = 'Could not locate you in the world.' } end
    local coords = { x = cx, y = cy, z = cz }
    -- Only broadcasts the move (and reports success) once the DB write is
    -- actually confirmed — previously this always reported ok=true and
    -- moved the ped for everyone currently online even if the write failed,
    -- which just meant it silently reverted the next time anyone reloaded
    -- the location (a fresh join, or reopening the tablet's Settings tab).
    if not DB.setEquipmentVendorLocation(coords.x, coords.y, coords.z, heading) then
        return { ok = false, error = 'Database write failed — check the server console for a SQL error (nova_equipment_vendor table).' }
    end
    local location = { x = coords.x, y = coords.y, z = coords.z, heading = heading }
    TriggerClientEvent('nova_convoytruck:equipment:moveVendor', -1, location)
    return { ok = true, location = location }
end)

-- Live on/off switch — Config.PoliceEquipment.enabled used to be the only
-- toggle, which meant flipping it required editing config.lua and
-- restarting the whole resource. This takes effect immediately for every
-- connected client (spawns/despawns the ped without a restart).
lib.callback.register('nova_convoytruck:setEquipmentVendorEnabled', function(source, enabled)
    if not can(source, 'create.edit') then return denied() end
    if not DB.setEquipmentVendorEnabled(enabled and true or false) then
        return { ok = false, error = 'Database write failed — check the server console for a SQL error (nova_equipment_vendor table).' }
    end
    TriggerClientEvent('nova_convoytruck:equipment:setEnabled', -1, enabled and true or false)
    return { ok = true }
end)

-- ── Escort Vehicle Shop Location ─────────────────────────────────────────────────
-- Same pattern as the equipment vendor above — see client/modules/escort_shop.lua.

lib.callback.register('nova_convoytruck:getEscortShopLocation', function(source)
    return DB.getEscortShopLocation()
end)

lib.callback.register('nova_convoytruck:setEscortShopLocation', function(source, placed)
    if not can(source, 'create.edit') then return denied() end
    local cx, cy, cz, heading = PedSpot(source, placed)
    if not cx then return { ok = false, error = 'Could not locate you in the world.' } end
    local coords = { x = cx, y = cy, z = cz }
    if not DB.setEscortShopLocation(coords.x, coords.y, coords.z, heading) then
        return { ok = false, error = 'Database write failed — check the server console for a SQL error (nova_escort_shop table).' }
    end
    local location = { x = coords.x, y = coords.y, z = coords.z, heading = heading }
    TriggerClientEvent('nova_convoytruck:escortShop:moveVendor', -1, location)
    return { ok = true, location = location }
end)

lib.callback.register('nova_convoytruck:setEscortShopEnabled', function(source, enabled)
    if not can(source, 'create.edit') then return denied() end
    if not DB.setEscortShopEnabled(enabled and true or false) then
        return { ok = false, error = 'Database write failed — check the server console for a SQL error (nova_escort_shop table).' }
    end
    TriggerClientEvent('nova_convoytruck:escortShop:setEnabled', -1, enabled and true or false)
    return { ok = true }
end)

-- ── Scheduling Settings ──────────────────────────────────────────────────────────
-- Admin-ONLY, not the wider HasCreatorAccess (which police also get via their
-- job grade) — this governs how the server interprets every admin-entered
-- schedule date/time server-wide, not just this one police officer's own
-- convoys, so only a real admin (Config.CreatorAccess.adminPermission ACE, or
-- the adminIdentifiers allowlist) may view/change it.

-- ── Saved Route Templates ─────────────────────────────────────────────────────────

lib.callback.register('nova_convoytruck:getSavedRoutes', function(source)
    if not canAny(source, 'savedroutes.view', 'create.view') then return denied() end
    local all = SavedRoutes.getAll()
    if not can(source, 'create.manage') then
        local filtered = {}
        for _, r in ipairs(all or {}) do
            if r.kind == 'CONVOY' then filtered[#filtered + 1] = r end
        end
        return { ok = true, routes = filtered }
    end
    return { ok = true, routes = all }
end)

-- Read-only detail fetch for the Saved Routes tab's own map preview — unlike
-- importRouteTemplate, this never remaps ids or touches anything; it's just
-- the raw saved payload for RoutePreviewMap to draw, with no event being
-- built or replaced. Returns every kind's fields regardless of the row's own
-- kind (whichever are null for that kind, RoutePreviewMap already ignores —
-- it only draws hotCargo/zones/route based on which ones are non-empty).
lib.callback.register('nova_convoytruck:getSavedRouteDetail', function(source, id)
    if not canAny(source, 'savedroutes.view', 'create.view') then return denied() end
    local saved = DB.getSavedRoute(id)
    if not saved then return { ok = false, error = 'Saved route not found.' } end
    if not kindAllowed(source, saved.kind) then
        return denied()
    end
    local props = saved.eventProps or (saved.containerWars and saved.containerWars.yard and saved.containerWars.yard.props) or {}
    return {
        ok = true, kind = saved.kind or 'CONVOY',
        route = saved.route, checkpoints = saved.checkpoints, airdrops = saved.airdrops,
        spawnZones = saved.spawnZones, dropoffZones = saved.dropoffZones, airdropZones = saved.airdropZones,
        rallyStages = saved.rallyStages,
        containerWars = saved.containerWars,
        eventProps = props,
        props = props,
    }
end)

-- payload shape depends on kind — see SavedRoutes.save's own doc comment.
lib.callback.register('nova_convoytruck:saveRouteTemplate', function(source, name, kind, payload)
    if not can(source, 'savedroutes.create') then return denied() end
    if not kindAllowed(source, kind) then
        return { ok = false, error = 'You can only save Convoy route templates. The other kinds need Create Event → Manage.' }
    end
    local pOk, okOrErr, result = pcall(SavedRoutes.save, source, name, kind, payload)
    if not pOk then
        lib.print.error(('[NovaConvoy] saveRouteTemplate error: %s'):format(tostring(okOrErr)))
        return { ok = false, error = ('Server error: %s'):format(tostring(okOrErr)) }
    end
    if not okOrErr then return { ok = false, error = result } end
    return { ok = true, id = result }
end)

lib.callback.register('nova_convoytruck:updateRouteTemplate', function(source, id, payload)
    if not can(source, 'savedroutes.edit') then return denied() end
    local saved = DB.getSavedRoute(id)
    if saved and not kindAllowed(source, saved.kind) then
        return { ok = false, error = 'You can only update Convoy route templates. The other kinds need Create Event → Manage.' }
    end
    local pOk, okOrErr, result = pcall(SavedRoutes.update, source, id, payload)
    if not pOk then
        lib.print.error(('[NovaConvoy] updateRouteTemplate error: %s'):format(tostring(okOrErr)))
        return { ok = false, error = ('Server error: %s'):format(tostring(okOrErr)) }
    end
    if not okOrErr then return { ok = false, error = result } end
    return { ok = true, id = result }
end)

lib.callback.register('nova_convoytruck:importRouteTemplate', function(source, id)
    if not canAny(source, 'savedroutes.view', 'create.view') then return denied() end
    local ok, result = SavedRoutes.import(source, id)
    if not ok then return { ok = false, error = result } end
    if not kindAllowed(source, result.kind) then
        return { ok = false, error = 'You can only import Convoy route templates. The other kinds need Create Event → Manage.' }
    end
    return {
        ok = true, id = result.id, prebuilt = result.prebuilt,
        kind = result.kind, name = result.name,
        route = result.route, checkpoints = result.checkpoints, airdrops = result.airdrops,
        spawnZones = result.spawnZones, dropoffZones = result.dropoffZones,
        airdropZones = result.airdropZones,
        rallyStages = result.rallyStages,
        yard = result.yard, zone = result.zone,
        eventProps = result.eventProps or result.props or {},
        props = result.props or result.eventProps or {},
    }
end)

lib.callback.register('nova_convoytruck:deleteRouteTemplate', function(source, id)
    if not can(source, 'savedroutes.delete') then return denied() end
    local ok, err = SavedRoutes.delete(source, id)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:deleteAllRouteTemplates', function(source)
    if not can(source, 'savedroutes.manage') then return denied() end
    local ok, err = SavedRoutes.deleteAll(source)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

lib.callback.register('nova_convoytruck:getScheduleSettings', function(source)
    if not can(source, 'settings.view') then return denied() end
    return { ok = true, settings = Scheduler.getSettings() }
end)

lib.callback.register('nova_convoytruck:setScheduleSettings', function(source, utcOffsetHours, pollIntervalSeconds)
    if not can(source, 'settings.manage') then return denied() end
    local ok, err = Scheduler.setSettings(utcOffsetHours, pollIntervalSeconds)
    if not ok then return { ok = false, error = err } end
    return { ok = true, settings = Scheduler.getSettings() }
end)

-- The Review tab's "Server time now" readout and its schedule-in-the-past
-- validation used to trust the NUI browser's own Date() as if it WERE the
-- server clock — really just the admin's own PC clock, which silently
-- drifts from the actual FXServer host whenever that PC's clock is wrong.
-- This hands back the real authoritative UTC instant (Scheduler.nowUtc(),
-- the exact same source of truth the scheduler poll loop itself uses) so the
-- client can anchor its live-ticking display to the true server time instead.
lib.callback.register('nova_convoytruck:getServerTime', function(source)
    if not Bridge.HasCreatorAccess(source) then return denied() end
    return { ok = true, utc = Scheduler.nowUtc() }
end)

lib.callback.register('nova_convoytruck:getEscortShopVehicles', function(source)
    return { ok = true, vehicles = Runtime.getEscortShopVehicles(source) }
end)

lib.callback.register('nova_convoytruck:requestEscortVehicle', function(source, vehicleData, account, spot)
    local ok, result = Runtime.requestEscortVehicle(source, vehicleData, account, spot)
    if not ok then return { ok = false, error = result } end
    return { ok = true, vehicle = result }
end)

lib.callback.register('nova_convoytruck:hasEscortVehicle', function(source)
    return Runtime.hasEscortVehicle(source)
end)

lib.callback.register('nova_convoytruck:returnEscortVehicle', function(source)
    local ok, result = Runtime.returnEscortVehicle(source)
    if not ok then return { ok = false, error = result } end
    return { ok = true, refunded = result }
end)

lib.callback.register('nova_convoytruck:propPlacer:access', function(source)
    return canAny(source, 'create.edit', 'worldpeds.edit', 'worldpeds.create')
end)

-- Staff, roles and permissions are managed through the staff:* callbacks in server/modules/user_permissions.lua.
