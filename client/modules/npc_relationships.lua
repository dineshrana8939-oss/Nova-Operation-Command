-- ─── Nova Convoy — NPC Relationship Groups & Tactical Combat AI (client) ──────
-- Handles tactical long-range combat AI, hill/cover threat detection, and strict
-- relationship group assignments so Police/Army NPCs only engage gang hostiles,
-- while Airdrop NPCs engage all approaching players.

local registered = false
local syncedPlayerRelationships = {}
local activeCombatPeds = {}
local loggedCanAttackFriendlyError = false
-- netId -> true while a bounded control-request retry loop is already
-- running for that ped (background watchdog below) — stops a new 3s tick
-- from stacking a second overlapping retry thread on top of one already in
-- flight for the same ped.
local requestingControl = {}
-- How long a tracked guard may stay unseen on this client (not streamed in, or already deleted by the server) before it is forgotten.
local GUARD_TRACK_TTL_MS = 600000

local function registerGroups()
    if registered then return end
    registered = true

    AddRelationshipGroup('nova_convoy_npc')
    AddRelationshipGroup('nova_convoy_gang')
    AddRelationshipGroup('nova_convoy_police')
    AddRelationshipGroup('nova_convoy_npc_passive')
    AddRelationshipGroup('nova_convoy_ambush')
    AddRelationshipGroup('nova_convoy_airdrop_guard')

    local npcGroupHash = joaat('nova_convoy_npc')
    local gangGroupHash = joaat('nova_convoy_gang')
    local policeGroupHash = joaat('nova_convoy_police')
    local passiveGroupHash = joaat('nova_convoy_npc_passive')
    local ambushGroupHash = joaat('nova_convoy_ambush')
    local airdropGroupHash = joaat('nova_convoy_airdrop_guard')

    -- In FiveM / GTA V, relationship 0 is COMPANION (never attack allies).
    -- Setting 0 between members of the same group guarantees NPCs in the same squad
    -- will never turn on each other, even when caught in crossfire.
    for _, g in ipairs({ npcGroupHash, gangGroupHash, policeGroupHash, passiveGroupHash, ambushGroupHash, airdropGroupHash }) do
        SetRelationshipBetweenGroups(0, g, g)
    end

    -- ── 1. Police & Army NPCs (nova_convoy_npc) ──
    -- HATES gang participants (shoots gangs on sight)
    SetRelationshipBetweenGroups(5, npcGroupHash, gangGroupHash)
    SetRelationshipBetweenGroups(5, gangGroupHash, npcGroupHash)

    -- RESPECTS / ALLIED with real on-duty police players (NEVER shoots police)
    SetRelationshipBetweenGroups(1, npcGroupHash, policeGroupHash)
    SetRelationshipBetweenGroups(1, policeGroupHash, npcGroupHash)

    -- Everyone who is NOT police (civilians, bystanders, gang members who never joined) is shot on sight
    -- (Config.NpcCombat.shootNonPolice, default ON). Real police stay safe because the server puts every on-duty
    -- officer in nova_convoy_police (NpcManager.syncPoliceGroups), which these guards respect. Set the option
    -- to false to bring back the old "only registered gang participants are hostile" behaviour.
    local npcVsPlayer = ((Config.NpcCombat or {}).shootNonPolice ~= false) and 5 or 0
    SetRelationshipBetweenGroups(npcVsPlayer, npcGroupHash, `PLAYER`)
    SetRelationshipBetweenGroups(npcVsPlayer, `PLAYER`, npcGroupHash)
    SetRelationshipBetweenGroups(npcVsPlayer, npcGroupHash, joaat('PLAYER'))
    SetRelationshipBetweenGroups(npcVsPlayer, joaat('PLAYER'), npcGroupHash)

    -- HATES ambushers & airdrop guards
    SetRelationshipBetweenGroups(5, npcGroupHash, ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, npcGroupHash)

    -- ── 2. Real Police Players (nova_convoy_police) ──
    -- Hostile to gangs and ambushers
    SetRelationshipBetweenGroups(5, policeGroupHash, gangGroupHash)
    SetRelationshipBetweenGroups(5, gangGroupHash, policeGroupHash)
    SetRelationshipBetweenGroups(5, policeGroupHash, ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, policeGroupHash)

    -- ── 3. Passive Checkpoint NPCs (gangAttackEnabled = false) ──
    SetRelationshipBetweenGroups(0, passiveGroupHash, gangGroupHash)
    SetRelationshipBetweenGroups(0, gangGroupHash, passiveGroupHash)
    SetRelationshipBetweenGroups(0, passiveGroupHash, `PLAYER`)
    SetRelationshipBetweenGroups(0, `PLAYER`, passiveGroupHash)
    SetRelationshipBetweenGroups(0, passiveGroupHash, joaat('PLAYER'))
    SetRelationshipBetweenGroups(0, joaat('PLAYER'), passiveGroupHash)
    SetRelationshipBetweenGroups(1, passiveGroupHash, policeGroupHash)
    SetRelationshipBetweenGroups(1, policeGroupHash, passiveGroupHash)

    -- ── 4. Airdrop Guards / Ambush NPCs (nova_convoy_ambush) ──
    -- Hostile to EVERYONE: civilians, gangs, police, and convoy NPCs
    SetRelationshipBetweenGroups(5, ambushGroupHash, `PLAYER`)
    SetRelationshipBetweenGroups(5, `PLAYER`, ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, joaat('PLAYER'))
    SetRelationshipBetweenGroups(5, joaat('PLAYER'), ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, gangGroupHash)
    SetRelationshipBetweenGroups(5, gangGroupHash, ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, policeGroupHash)
    SetRelationshipBetweenGroups(5, policeGroupHash, ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, npcGroupHash)
    SetRelationshipBetweenGroups(5, npcGroupHash, ambushGroupHash)
    SetRelationshipBetweenGroups(5, ambushGroupHash, passiveGroupHash)
    SetRelationshipBetweenGroups(5, passiveGroupHash, ambushGroupHash)

    -- ── 4b. Standalone Gang Airdrop Guards (nova_convoy_airdrop_guard) ──
    -- Hostile to players/gangs/police-players ONLY — deliberately its OWN
    -- group, not a reuse of nova_convoy_ambush above. A Gang Airdrop is a
    -- standalone event with no concept of "this convoy's own escort" (see
    -- doStartGangAirdrop server-side — it never spawns police/army NPCs of
    -- its own), so there is nothing legitimate for its guards to be
    -- fighting except the players contesting the crate. Reusing the
    -- regular ambush group meant an airdrop's guards mutually HATE
    -- nova_convoy_npc (a REGULAR convoy's own police/army escort) by that
    -- section's own design — intentional there (a convoy's escort should
    -- fight off an ambush wave attacking ITS convoy), but with both
    -- features sharing one group, any unrelated convoy's escort or ambush
    -- wave that ends up within combat range (250m seeing/hearing range) of
    -- an active airdrop will fight the airdrop's own guards — which reads
    -- exactly like "the guards are shooting each other", except it's
    -- actually two different NPC factions from two unrelated features
    -- fighting each other, not friendly fire within one. A small test map
    -- with several features active at once makes this collision far more
    -- likely than it would be on a full-size live server.
    SetRelationshipBetweenGroups(5, airdropGroupHash, `PLAYER`)
    SetRelationshipBetweenGroups(5, `PLAYER`, airdropGroupHash)
    SetRelationshipBetweenGroups(5, airdropGroupHash, joaat('PLAYER'))
    SetRelationshipBetweenGroups(5, joaat('PLAYER'), airdropGroupHash)
    SetRelationshipBetweenGroups(5, airdropGroupHash, gangGroupHash)
    SetRelationshipBetweenGroups(5, gangGroupHash, airdropGroupHash)
    SetRelationshipBetweenGroups(5, airdropGroupHash, policeGroupHash)
    SetRelationshipBetweenGroups(5, policeGroupHash, airdropGroupHash)
    -- Explicit NEUTRAL toward regular convoy police/army escorts and the
    -- other ambush group — not just "unset", since an unset relationship
    -- between two custom groups isn't guaranteed to default to neutral.
    SetRelationshipBetweenGroups(0, airdropGroupHash, npcGroupHash)
    SetRelationshipBetweenGroups(0, npcGroupHash, airdropGroupHash)
    SetRelationshipBetweenGroups(0, airdropGroupHash, ambushGroupHash)
    SetRelationshipBetweenGroups(0, ambushGroupHash, airdropGroupHash)
    SetRelationshipBetweenGroups(0, airdropGroupHash, passiveGroupHash)
    SetRelationshipBetweenGroups(0, passiveGroupHash, airdropGroupHash)

    -- ── 4c. Hot Cargo Guards (nova_convoy_hotcargo_hostile / _selective) ──
    -- Same problem, same fix, as the airdrop guards in 4b above: Hot Cargo's
    -- dropoff/vehicle guards (spawnHotCargoDropoffGuards/spawnHotCargoVehicle
    -- Guards, server-side) used to reuse nova_convoy_ambush (its "shootAnyone"
    -- ON mode) or nova_convoy_npc (its "shootAnyone" OFF mode) directly — both
    -- shared groups that hate one or more of the OTHER unrelated NPC
    -- factions above by design. A Hot Cargo run has no escort of its own
    -- either, so its guards have nothing legitimate to fight except the
    -- players/gangs actually contesting it. Two dedicated groups preserve
    -- the existing "shootAnyone" toggle's two behaviours, just without the
    -- cross-feature collision risk.
    AddRelationshipGroup('nova_convoy_hotcargo_hostile')
    AddRelationshipGroup('nova_convoy_hotcargo_selective')
    local hotCargoHostileHash = joaat('nova_convoy_hotcargo_hostile')
    local hotCargoSelectiveHash = joaat('nova_convoy_hotcargo_selective')
    SetRelationshipBetweenGroups(0, hotCargoHostileHash, hotCargoHostileHash)
    SetRelationshipBetweenGroups(0, hotCargoSelectiveHash, hotCargoSelectiveHash)

    -- "shootAnyone" ON — hostile to players/gangs/police-players, same as
    -- airdrop guards, and likewise neutral toward every other NPC faction.
    for _, g in ipairs({ `PLAYER`, joaat('PLAYER'), gangGroupHash, policeGroupHash }) do
        SetRelationshipBetweenGroups(5, hotCargoHostileHash, g)
        SetRelationshipBetweenGroups(5, g, hotCargoHostileHash)
    end
    for _, g in ipairs({ npcGroupHash, ambushGroupHash, airdropGroupHash, passiveGroupHash }) do
        SetRelationshipBetweenGroups(0, hotCargoHostileHash, g)
        SetRelationshipBetweenGroups(0, g, hotCargoHostileHash)
    end

    -- "shootAnyone" OFF — hates gangs only (a security-detail posture, not
    -- "shoot on sight"), respects real on-duty police, neutral to civilians
    -- — same behaviour nova_convoy_npc gave it before, just without also
    -- inheriting that group's own hatred of nova_convoy_ambush.
    SetRelationshipBetweenGroups(5, hotCargoSelectiveHash, gangGroupHash)
    SetRelationshipBetweenGroups(5, gangGroupHash, hotCargoSelectiveHash)
    SetRelationshipBetweenGroups(1, hotCargoSelectiveHash, policeGroupHash)
    SetRelationshipBetweenGroups(1, policeGroupHash, hotCargoSelectiveHash)
    for _, g in ipairs({ `PLAYER`, joaat('PLAYER'), npcGroupHash, ambushGroupHash, airdropGroupHash, passiveGroupHash }) do
        SetRelationshipBetweenGroups(0, hotCargoSelectiveHash, g)
        SetRelationshipBetweenGroups(0, g, hotCargoSelectiveHash)
    end

    -- ── 5. Convoy truck drivers (nova_convoy_driver) ──
    -- Drivers used to be put in nova_convoy_npc as 'police' combat peds —
    -- which made every client's watchdog below re-issue
    -- TaskCombatHatedTargetsAroundPed on them every 3s. That REPLACES the
    -- drive task: the moment anything they hate was in range (airdrop
    -- guards right next to the route especially), the driver stopped
    -- driving to "fight" from the seat, which is the truck braking/slowing
    -- near an airdrop zone. Drivers now sit in their own group that nothing
    -- is hostile to and that is hostile to nothing — the airdrop is a side
    -- event for gangs, not something the convoy stops for.
    AddRelationshipGroup('nova_convoy_driver')
    local driverGroupHash = joaat('nova_convoy_driver')
    for _, other in ipairs({ npcGroupHash, policeGroupHash, passiveGroupHash, ambushGroupHash, airdropGroupHash, hotCargoHostileHash, hotCargoSelectiveHash }) do
        SetRelationshipBetweenGroups(1, driverGroupHash, other)
        SetRelationshipBetweenGroups(1, other, driverGroupHash)
    end
    SetRelationshipBetweenGroups(0, driverGroupHash, gangGroupHash)
    SetRelationshipBetweenGroups(0, gangGroupHash, driverGroupHash)
    SetRelationshipBetweenGroups(0, driverGroupHash, `PLAYER`)
    SetRelationshipBetweenGroups(0, `PLAYER`, driverGroupHash)
    SetRelationshipBetweenGroups(0, driverGroupHash, joaat('PLAYER'))
    SetRelationshipBetweenGroups(0, joaat('PLAYER'), driverGroupHash)

    -- ── 6. Practice Range (client/modules/practice_range.lua) ──
    -- Solo aim-training bots — hostile ONLY to a dedicated "practice target"
    -- group the practicing player's own ped is temporarily switched into for
    -- the session (never the generic PLAYER group), so a bot can never
    -- aggro a bystander who wanders near the range, and the practicing
    -- player's temporary group can never get pulled into an unrelated
    -- convoy/airdrop/hot-cargo fight happening elsewhere on the map.
    AddRelationshipGroup('nova_practice_bot')
    AddRelationshipGroup('nova_practice_target')
    local practiceBotGroupHash = joaat('nova_practice_bot')
    local practiceTargetGroupHash = joaat('nova_practice_target')
    SetRelationshipBetweenGroups(0, practiceBotGroupHash, practiceBotGroupHash)
    SetRelationshipBetweenGroups(0, practiceTargetGroupHash, practiceTargetGroupHash)
    SetRelationshipBetweenGroups(5, practiceBotGroupHash, practiceTargetGroupHash)
    SetRelationshipBetweenGroups(5, practiceTargetGroupHash, practiceBotGroupHash)
    for _, g in ipairs({ npcGroupHash, gangGroupHash, policeGroupHash, passiveGroupHash, ambushGroupHash, airdropGroupHash, hotCargoHostileHash, hotCargoSelectiveHash, driverGroupHash, `PLAYER`, joaat('PLAYER') }) do
        SetRelationshipBetweenGroups(0, practiceBotGroupHash, g)
        SetRelationshipBetweenGroups(0, g, practiceBotGroupHash)
        SetRelationshipBetweenGroups(0, practiceTargetGroupHash, g)
        SetRelationshipBetweenGroups(0, g, practiceTargetGroupHash)
    end
end

-- Truck driver netIds this client should keep in nova_convoy_driver.
-- Relationship group is applied on EVERY client (not just the owner) since
-- a guard's AI runs on whichever client owns the guard, and it's that
-- client's view of the driver's group that decides whether it shoots.
local convoyDrivers = {}
local function applyDriverGroup(netId)
    if not NetworkDoesNetworkIdExist(netId) then return false end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    if GetPedRelationshipGroupHash(ped) ~= `nova_convoy_driver` then
        SetPedRelationshipGroupHash(ped, `nova_convoy_driver`)
    end
    if GetPedRelationshipGroupHash(ped) ~= joaat('nova_convoy_driver') then
        SetPedRelationshipGroupHash(ped, joaat('nova_convoy_driver'))
    end
    return true
end

RegisterNetEvent('nova_convoytruck:client:setDriverGroup', function(netId)
    registerGroups()
    convoyDrivers[netId] = true
    activeCombatPeds[netId] = nil -- never a combat ped
    applyDriverGroup(netId)
end)

-- ── Tactical Long-Range Combat AI Configuration ──────────────────────────────
-- Injects long-range eyesight, hearing, anti-cover perception, and precision aim
-- so NPCs can identify and engage hostiles peeking from hilltops or behind cover.
local function applyCombatCapabilities(ped, kind, groupName)
    if not ped or not DoesEntityExist(ped) then return end
    registerGroups()

    local cfg = Config.NpcCombat or {}
    local seeingRange = cfg.seeingRange or 250.0
    local hearingRange = cfg.hearingRange or 250.0

    SetPedRelationshipGroupHash(ped, joaat(groupName))
    -- A guard can never be hurt by its own side: bullets that miss the target fly on through the guard standing behind it. Together
    -- with the relationship groups this stops guards from killing each other (the zone guards switch between the neutral and the
    -- hostile group, so both are covered for them).
    pcall(SetEntityCanBeDamagedByRelationshipGroup, ped, false, joaat(groupName))
    if groupName == 'nova_convoy_npc' or groupName == 'nova_convoy_npc_passive' then
        pcall(SetEntityCanBeDamagedByRelationshipGroup, ped, false, joaat('nova_convoy_npc'))
        pcall(SetEntityCanBeDamagedByRelationshipGroup, ped, false, joaat('nova_convoy_npc_passive'))
    end

    -- Senses: 250m vision & hearing with 360 degree situational awareness
    SetPedSeeingRange(ped, seeingRange)
    SetPedHearingRange(ped, hearingRange)
    SetPedVisualFieldMinAngle(ped, -180.0)
    SetPedVisualFieldMaxAngle(ped, 180.0)

    -- Perception: detects targets despite darkness, foliage, bushes, and partial cover
    SetPedHighlyPerceptive(ped, cfg.highlyPerceptive ~= false)
    SetPedAlertness(ped, cfg.alertness or 3)

    -- Combat ranges & movement (Far combat engagement + tactical offensive advances)
    SetPedCombatRange(ped, cfg.combatRange or 2)
    SetPedCombatMovement(ped, cfg.combatMovement or 2)

    -- Tactical Combat Attributes
    SetPedCombatAttributes(ped, 0, cfg.canUseCover ~= false)    -- BF_CanUseCover
    SetPedCombatAttributes(ped, 1, true)                        -- BF_CanUseVehicles
    SetPedCombatAttributes(ped, 2, true)                        -- BF_CanDoDrivebys
    SetPedCombatAttributes(ped, 3, true)                        -- BF_CanLeaveVehicle
    SetPedCombatAttributes(ped, 5, cfg.alwaysFight ~= false)    -- BF_AlwaysFight
    SetPedCombatAttributes(ped, 39, true)                       -- BF_Aggressive
    SetPedCombatAttributes(ped, 46, true)                       -- BF_AlwaysEquipBestWeapon / CanFightArmed
    SetPedCombatAttributes(ped, 52, true)                       -- BF_CanUseDynamicStrafeToAdvance
    -- BF_CanHuntPlayerDown (142) — this game build's own SET_PED_COMBAT_
    -- ATTRIBUTES rejects it outright ("invalid attribute index was passed
    -- (142), should be from 0 to 91"), confirmed live and spamming that
    -- warning on every single combat ped, every time this runs. The valid
    -- attribute range on THIS build tops out at 91, so 142 was never a real
    -- flag here regardless of whether it's documented for other builds —
    -- removed rather than guessed at a replacement index.

    SetPedFleeAttributes(ped, 0, false)
    SetPedKeepTask(ped, true)
    SetPedAsEnemy(ped, true)

    -- Relationship groups only decide who a ped VOLUNTARILY picks as a
    -- target; they do nothing about a ped's REACTION to actually taking
    -- damage. GTA's stock combat AI treats being hit as hostile intent from
    -- whoever fired, even a same-group ally — a stray round from a guard on
    -- the far side of the ring (or simple splash/explosion) is enough to
    -- flip that guard onto attacking one of its own, regardless of how
    -- correctly SetRelationshipBetweenGroups is configured above. This is
    -- exactly "airdrop guards shooting each other instead of the player."
    -- SetCanAttackFriendly(false) is the actual fix: it tells the ped to
    -- never retaliate against its own relationship group no matter what
    -- damage it takes from them. Logged once (not pcall'd silently) if this
    -- native ever fails — guards were still reported shooting each other
    -- after this was added, and a silently-swallowed pcall failure here
    -- (wrong native name/signature on this game build) would look
    -- IDENTICAL to the fix simply not working, with no way to tell them
    -- apart without this.
    local cafOk, cafErr = pcall(SetCanAttackFriendly, ped, false, false)
    if not cafOk and not loggedCanAttackFriendlyError then
        loggedCanAttackFriendlyError = true
        print(('[NovaConvoy] SetCanAttackFriendly failed: %s'):format(tostring(cafErr)))
    end

    -- Precision Marksmanship
    local accuracy = 75
    if kind == 'army' then
        accuracy = cfg.armyAccuracy or 85
    elseif kind == 'police' then
        accuracy = cfg.policeAccuracy or 75
    elseif groupName == 'nova_convoy_ambush' or groupName == 'nova_convoy_airdrop_guard' or groupName == 'nova_convoy_hotcargo_hostile' then
        accuracy = cfg.airdropAccuracy or 80
    end
    SetPedAccuracy(ped, accuracy)
    SetPedShootRate(ped, cfg.shootRate or 100)
    SetPedFiringPattern(ped, cfg.firingPattern or `FIRING_PATTERN_BURST_FIRE_RIFLE`)
    SetPedFiringPattern(ped, cfg.firingPattern or joaat('FIRING_PATTERN_BURST_FIRE_RIFLE'))

    -- If this client controls the ped entity, issue target scanning
    if NetworkHasControlOfEntity(ped) and groupName ~= 'nova_convoy_npc_passive' then
        TaskCombatHatedTargetsAroundPed(ped, seeingRange, 0)
    end
end

-- ── Admin-configured aggressiveness tuning (checkpoint police/army, ambush
-- waves, airdrop guards) — layered ON TOP of applyCombatCapabilities' own
-- kind-based baseline above. Was server/modules/npc_manager.lua's
-- NpcManager.applyCombatAttributes: SetPedCombatAbility/SetPedAccuracy/etc.
-- are ped AI natives that only exist client-side (same reason
-- applyCombatCapabilities above already has to run here, not server-side),
-- so the server now just broadcasts the netId + chosen aggressiveness and
-- this client applies it locally.
local AGGRESSIVENESS_PROFILES = {
    low = {
        combatAbility = 0,    -- 0 = Poor
        combatRange = 0,      -- 0 = Near
        accuracy = 25,
        shootRate = 25,
        combatMovement = 1,   -- 1 = Defensive
        armour = 0,
    },
    medium = {
        combatAbility = 1,    -- 1 = Average
        combatRange = 1,      -- 1 = Medium
        accuracy = 45,
        shootRate = 50,
        combatMovement = 2,   -- 2 = Will advance
        armour = 50,
    },
    high = {
        combatAbility = 2,    -- 2 = Professional
        combatRange = 2,      -- 2 = Far
        accuracy = 70,
        shootRate = 75,
        combatMovement = 3,   -- 3 = Offensive
        armour = 100,
    },
    extreme = {
        combatAbility = 2,    -- 2 = Professional
        combatRange = 2,      -- 2 = Far
        accuracy = 90,
        shootRate = 100,
        combatMovement = 3,   -- 3 = Offensive
        armour = 100,
    },
}

local function applyAggressivenessProfile(ped, aggressiveness, isHostile)
    if not ped or not DoesEntityExist(ped) then return end
    local profile = AGGRESSIVENESS_PROFILES[aggressiveness] or AGGRESSIVENESS_PROFILES.medium

    SetPedCombatAbility(ped, profile.combatAbility)
    SetPedCombatRange(ped, profile.combatRange)
    SetPedAccuracy(ped, profile.accuracy)
    SetPedShootRate(ped, profile.shootRate)
    SetPedCombatMovement(ped, profile.combatMovement)
    if profile.armour and profile.armour > 0 then
        SetPedArmour(ped, profile.armour)
    end

    SetPedCombatAttributes(ped, 0, true)   -- BF_CanUseCover
    SetPedCombatAttributes(ped, 5, true)   -- BF_AlwaysFight
    SetPedCombatAttributes(ped, 46, true)  -- BF_AlwaysEquipBestWeapon
    SetPedFleeAttributes(ped, 0, false)

    if profile.combatAbility >= 2 then
        SetPedCombatAttributes(ped, 39, true)  -- BF_Aggressive
        SetPedCombatAttributes(ped, 52, true)  -- BF_CanUseDynamicStrafeToAdvance
    end
    if aggressiveness == 'extreme' or isHostile then
        -- BF_CanHuntPlayerDown (142) removed — invalid on this build, see
        -- applyCombatCapabilities' own comment above for the confirmed
        -- warning and why it wasn't replaced with a guessed index.
        SetPedAlertness(ped, 3)
    end
end

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    registerGroups()
end)

-- ── Configures an NPC ped's relationship group & tactical combat stats ────────
RegisterNetEvent('nova_convoytruck:client:setPedRelationshipGroup', function(netId, groupName, kind)
    registerGroups()
    activeCombatPeds[netId] = { groupName = groupName, kind = kind, addedAt = GetGameTimer() }
    local ped = NetworkGetEntityFromNetworkId(netId)
    if ped and DoesEntityExist(ped) then
        applyCombatCapabilities(ped, kind, groupName)
    end
end)

RegisterNetEvent('nova_convoytruck:client:applyPedCombatAttributes', function(netId, aggressiveness, isHostile)
    -- remembered, so a guard that streams in on this client later gets the same profile (see the watchdog below)
    local tracked = activeCombatPeds[netId]
    if tracked then tracked.aggr = { aggressiveness, isHostile } end
    if not NetworkDoesNetworkIdExist(netId) then return end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        applyAggressivenessProfile(ped, aggressiveness, isHostile)
    end
end)

-- Server/modules/npc_manager.lua's assignPedTask — TaskGuardCurrentPosition/
-- TaskWanderStandard/TaskCombatHatedTargetsAroundPed are ped task natives
-- that only exist client-side (same reason as everything else in this
-- file). Was previously called directly on the server, where it doesn't
-- exist at all — for checkpoint police/army NPCs specifically, that crash
-- happened on the very first ped spawned, aborting the entire checkpoint
-- (no banner, no map sprite, no timer, truck stuck retrying forever). For
-- ambush waves it was silently eating the airdrop-guard spawn instead.
-- netId -> true while a guard is being put on the ground: the combat task that follows it must wait, or the guard task (issued last)
-- would replace it and the guard would hold its spot instead of engaging
local pendingGuard = {}
RegisterNetEvent('nova_convoytruck:client:applyPedTask', function(netId, taskName)
    if not NetworkDoesNetworkIdExist(netId) then return end
    if taskName == 'guard' then pendingGuard[netId] = true end
    CreateThread(function()
        local timeout = GetGameTimer() + 3000
        while not NetworkDoesNetworkIdExist(netId) and GetGameTimer() < timeout do Wait(50) end
        local ped = NetworkGetEntityFromNetworkId(netId)
        if not ped or ped == 0 or not DoesEntityExist(ped) then pendingGuard[netId] = nil return end

        if taskName == 'combat' then
            local waitUntil = GetGameTimer() + 3000
            while pendingGuard[netId] and GetGameTimer() < waitUntil do Wait(50) end
        end
        local controlTimeout = GetGameTimer() + 2500
        while not NetworkHasControlOfEntity(ped) and GetGameTimer() < controlTimeout do
            NetworkRequestControlOfEntity(ped)
            Wait(50)
        end
        if not DoesEntityExist(ped) then pendingGuard[netId] = nil return end

        if taskName == 'wander' then
            TaskWanderStandard(ped, 10.0, 10)
        elseif taskName == 'guard' then
            -- The server cannot read the ground height, so a guard it placed on a slope, a kerb or a dip floated above the road or
            -- stood sunk in it. The client that controls the ped puts it on the real ground first (collision around it is requested
            -- and waited for), then it holds that spot.
            if NetworkHasControlOfEntity(ped) and not IsPedInAnyVehicle(ped, false) and not IsEntityDead(ped) then
                local c = GetEntityCoords(ped)
                local found, gz = false, c.z
                local giveUp = GetGameTimer() + 1500
                repeat
                    RequestCollisionAtCoord(c.x, c.y, c.z)
                    found, gz = GetGroundZFor_3dCoord(c.x, c.y, c.z + 2.0, false)
                    if not found then Wait(100) end
                until found or GetGameTimer() > giveUp or not DoesEntityExist(ped)
                if found and DoesEntityExist(ped) and math.abs(gz - c.z) > 0.3 and math.abs(gz - c.z) < 8.0 then
                    SetEntityCoordsNoOffset(ped, c.x, c.y, gz + 1.0, false, false, false)
                end
            end
            TaskGuardCurrentPosition(ped, 25.0, 15.0, true)
            pendingGuard[netId] = nil
        elseif taskName == 'combat' then
            local seeing = (Config.NpcCombat and Config.NpcCombat.seeingRange) or 250.0
            TaskCombatHatedTargetsAroundPed(ped, seeing, 0)
            local myPed = cache.ped or PlayerPedId()
            if myPed and #(GetEntityCoords(myPed) - GetEntityCoords(ped)) < 150.0 and not IsPedDeadOrDying(myPed, true) then
                TaskCombatPed(ped, myPed, 0, 16)
            end
        end
    end)
end)

-- ── Synchronizes player relationship groups across all clients ────────────────
-- Solves the FiveM desync where remote clients still perceive a hostile gang
-- member as group 'PLAYER'. When broadcast, every client updates the remote ped.
RegisterNetEvent('nova_convoytruck:client:updatePlayerRelationship', function(targetServerId, groupName)
    registerGroups()
    if groupName and groupName ~= 'PLAYER' then
        syncedPlayerRelationships[targetServerId] = groupName
    else
        syncedPlayerRelationships[targetServerId] = nil
    end

    local playerIndex = GetPlayerFromServerId(targetServerId)
    if playerIndex and playerIndex ~= -1 then
        local ped = GetPlayerPed(playerIndex)
        if ped and DoesEntityExist(ped) then
            SetPedRelationshipGroupHash(ped, groupName and joaat(groupName) or `PLAYER`)
            SetPedRelationshipGroupHash(ped, groupName and joaat(groupName) or joaat('PLAYER'))
        end
    end
end)

-- Background watchdog: ensures combat peds & streaming remote players stay synchronized
-- Was a 1000ms tick — reported as "guards don't shoot until I aim at them":
-- a freshly-spawned ped keeps whatever weak vanilla perception/combat stats
-- CreatePed gave it (narrow visual field, low alertness, not aggressive)
-- until SOMEONE actually gains NetworkHasControlOfEntity, since that's the
-- gate both the real perception setup (applyCombatCapabilities, below) and
-- the direct TaskCombatPed re-issue sit behind. At 1000ms plus the control
-- request's own up-to-2000ms retry window, a player walking up could easily
-- wait 2-3 real seconds before the ped actually became dangerous — long
-- enough to read as "it only reacts once I do something else" (aiming, which
-- also happens to be the moment you're closest/most camera-relevant, i.e.
-- exactly when OneSync tends to hand you control anyway). 300ms closes most
-- of that gap.
CreateThread(function()
    local playerGroupHash = joaat('PLAYER')
    while true do
        -- nothing tracked (no checkpoint NPCs, drivers or hostile players): wake once a second, not three times
        Wait((next(activeCombatPeds) or next(convoyDrivers) or next(syncedPlayerRelationships)) and 300 or 1000)
        -- Keep active combat NPCs responsive to hated targets within 250m.
        -- Also retroactively applies combat capabilities to peds that were not
        -- yet streamed in when setPedRelationshipGroup fired (late-stream fix).
        local nowMs = GetGameTimer()
        for netId, data in pairs(activeCombatPeds) do
            data.addedAt = data.addedAt or nowMs
            if NetworkDoesNetworkIdExist(netId) then
                local ped = NetworkGetEntityFromNetworkId(netId)
                if ped and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
                    data.lastSeen = nowMs
                    local myPed = cache.ped or PlayerPedId()
                    local myCoords = GetEntityCoords(myPed)
                    local dist = #(myCoords - GetEntityCoords(ped))
                    -- First time THIS client sees this ped (it streamed in after the spawn broadcast, which is what happens to
                    -- every guard you approach from a distance): put it in its group and make it immune to its own side's
                    -- bullets here, whoever controls it. Without this a late-streamed guard kept its model's default group and
                    -- could be shot by (and shoot back at) the guards around it on this client.
                    if data.handle ~= ped then
                        data.handle = ped
                        SetPedRelationshipGroupHash(ped, joaat(data.groupName))
                        pcall(SetEntityCanBeDamagedByRelationshipGroup, ped, false, joaat(data.groupName))
                    end
                    -- full combat setup once per ped for whichever client controls it (control can move to this client later)
                    if NetworkHasControlOfEntity(ped) and data.capsHandle ~= ped then
                        data.capsHandle = ped
                        applyCombatCapabilities(ped, data.kind, data.groupName)
                        if data.aggr then applyAggressivenessProfile(ped, data.aggr[1], data.aggr[2]) end
                    end
                    if NetworkHasControlOfEntity(ped) then
                        local currentGroup = GetPedRelationshipGroupHash(ped)
                        if currentGroup == 0 or currentGroup == playerGroupHash then
                            -- Ped exists but group was never assigned — streamed in late, apply now
                            applyCombatCapabilities(ped, data.kind, data.groupName)
                        else
                            -- SetCanAttackFriendly (set inside applyCombatCapabilities) is a
                            -- combat-AI decision flag, same category as SetPedCombatAbility/
                            -- SetPedAccuracy elsewhere in this file — it only actually governs
                            -- behaviour for whichever client is CURRENTLY simulating the ped's
                            -- AI. The relationship-group hash above is visible/replicated to
                            -- every perceiving client regardless of who controls the ped, so
                            -- the "never assigned yet" check above doesn't catch a ped whose
                            -- control has since migrated to a different client that never ran
                            -- applyCombatCapabilities itself — that client's own local copy of
                            -- the ped never got SetCanAttackFriendly, and it's now the one
                            -- actually deciding whether to retaliate against a friendly-fire
                            -- hit. Cheap to re-assert every tick for whichever client currently
                            -- has control, so it can never go missing after a control handoff.
                            local cafOk2, cafErr2 = pcall(SetCanAttackFriendly, ped, false, false)
                            if not cafOk2 and not loggedCanAttackFriendlyError then
                                loggedCanAttackFriendlyError = true
                                print(('[NovaConvoy] SetCanAttackFriendly failed: %s'):format(tostring(cafErr2)))
                            end
                        end
                        if data.groupName ~= 'nova_convoy_npc_passive' and currentGroup ~= 0 and currentGroup ~= playerGroupHash then
                            if (data.groupName == 'nova_convoy_ambush' or data.kind == 'ambush' or data.groupName == 'nova_convoy_airdrop_guard') and dist < 150.0 and not IsPedDeadOrDying(myPed, true) then
                                TaskCombatPed(ped, myPed, 0, 16)
                            else
                                TaskCombatHatedTargetsAroundPed(ped, Config.NpcCombat and Config.NpcCombat.seeingRange or 250.0, 0)
                            end
                        end
                    elseif not requestingControl[netId] then
                        if dist < 150.0 then
                            requestingControl[netId] = true
                            CreateThread(function()
                                local timeout = GetGameTimer() + 2000
                                while not NetworkHasControlOfEntity(ped) and DoesEntityExist(ped) and GetGameTimer() < timeout do
                                    NetworkRequestControlOfEntity(ped)
                                    Wait(50)
                                end
                                requestingControl[netId] = nil
                            end)
                        end
                    end
                elseif ped and DoesEntityExist(ped) then
                    activeCombatPeds[netId] = nil -- dead
                elseif nowMs - (data.lastSeen or data.addedAt) > GUARD_TRACK_TTL_MS then
                    activeCombatPeds[netId] = nil
                end
            else
                -- Not streamed in on this client (yet). It used to be forgotten right here, so a guard that appeared later never
                -- got its group or combat setup. Keep waiting; give up only after a long time unseen (guard gone / event over).
                if nowMs - (data.lastSeen or data.addedAt) > GUARD_TRACK_TTL_MS then
                    activeCombatPeds[netId] = nil
                end
            end
        end

        -- Late-streamed truck drivers: group only, no combat setup/tasks.
        for netId in pairs(convoyDrivers) do
            if not NetworkDoesNetworkIdExist(netId) then
                convoyDrivers[netId] = nil
            else
                applyDriverGroup(netId)
            end
        end

        -- Sync any newly streamed-in player peds with their assigned group
        for sId, gName in pairs(syncedPlayerRelationships) do
            local pIndex = GetPlayerFromServerId(sId)
            if pIndex and pIndex ~= -1 then
                local ped = GetPlayerPed(pIndex)
                if ped and DoesEntityExist(ped) then
                    if GetPedRelationshipGroupHash(ped) ~= joaat(gName) then
                        SetPedRelationshipGroupHash(ped, joaat(gName))
                    end
                end
            end
        end
    end
end)

-- ── Checkpoint zone guards ───────────────────────────────────────────────────
-- Checkpoint / start / destination guards with "shoot non-police here" on carry a cp_zone state ({ x, y, r }: the circle).
-- They stand neutral; the client that controls a guard turns it hostile (nova_convoy_npc) while any non-police player is
-- inside the circle and back to neutral a few seconds after the last one has left. Config.NpcCombat.shootNonPolice = false
-- narrows "non-police" to registered gang members.
local ZONE_HOLD_MS = 4000
CreateThread(function()
    registerGroups()
    local policeHash = joaat('nova_convoy_police')
    local gangHash = joaat('nova_convoy_gang')
    local npcHash = joaat('nova_convoy_npc')
    while true do
        Wait(next(activeCombatPeds) and 400 or 1500)
        if next(activeCombatPeds) then
            local anyZone = false
            local intruders
            for netId, data in pairs(activeCombatPeds) do
                if NetworkDoesNetworkIdExist(netId) then
                    local ped = NetworkGetEntityFromNetworkId(netId)
                    if ped and ped ~= 0 and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) and NetworkHasControlOfEntity(ped) then
                        local zone = Entity(ped).state.cp_zone
                        if type(zone) == 'table' and zone.x then
                            if not intruders then
                                intruders = {}
                                local everyone = (Config.NpcCombat or {}).shootNonPolice ~= false
                                for _, pid in ipairs(GetActivePlayers()) do
                                    local pp = GetPlayerPed(pid)
                                    if pp ~= 0 and DoesEntityExist(pp) and not IsEntityDead(pp) then
                                        local g = GetPedRelationshipGroupHash(pp)
                                        if g ~= policeHash and (everyone or g == gangHash) then
                                            intruders[#intruders + 1] = GetEntityCoords(pp)
                                        end
                                    end
                                end
                            end
                            local inside = false
                            local r2 = (tonumber(zone.r) or 40.0) ^ 2
                            for _, c in ipairs(intruders) do
                                if (c.x - zone.x) ^ 2 + (c.y - zone.y) ^ 2 <= r2 then inside = true break end
                            end
                            local now = GetGameTimer()
                            if inside then data.hotUntil = now + ZONE_HOLD_MS end
                            local hot = data.hotUntil and now < data.hotUntil
                            local want = hot and 'nova_convoy_npc' or 'nova_convoy_npc_passive'
                            if data.groupName ~= want then
                                data.groupName = want
                                SetPedRelationshipGroupHash(ped, joaat(want))
                                if hot then
                                    TaskCombatHatedTargetsAroundPed(ped, (Config.NpcCombat or {}).seeingRange or 250.0, 0)
                                else
                                    ClearPedTasks(ped)
                                    TaskGuardCurrentPosition(ped, 25.0, 15.0, true)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ── Same-group NPCs can never hurt each other ────────────────────────────────
-- Relationship groups and SetCanAttackFriendly only stop a ped from CHOOSING
-- to shoot an ally. They don't stop physical bullets: guards ringed around an
-- airdrop all fire at whoever is near the crate, and every round that misses
-- flies on through the guard standing on the far side — which reads as the
-- guards "firing at themselves". So the damage itself is undone: whenever a
-- tracked combat ped is hurt by another NPC of its OWN relationship group,
-- the controlling client puts its health/armour back to the last snapshot and
-- forgets who hit it (so it doesn't retaliate either). Different factions
-- (e.g. an ambush wave vs a convoy's police escort) still hurt each other.
local guardVitals = {} -- [ped] = { hp, armour }

CreateThread(function()
    while true do
        Wait(next(activeCombatPeds) and 100 or 1000)
        if next(activeCombatPeds) then
            for netId in pairs(activeCombatPeds) do
                if NetworkDoesNetworkIdExist(netId) then
                    local ped = NetworkGetEntityFromNetworkId(netId)
                    if ped and ped ~= 0 and DoesEntityExist(ped) and NetworkHasControlOfEntity(ped) and not IsPedDeadOrDying(ped, true) then
                        local snap = guardVitals[ped]
                        if not snap then snap = {} guardVitals[ped] = snap end
                        snap.hp = GetEntityHealth(ped)
                        snap.armour = GetPedArmour(ped)
                    end
                end
            end
        elseif next(guardVitals) then
            guardVitals = {}
        end
    end
end)

local function isTrackedCombatPed(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) or not IsEntityAPed(ped) or IsPedAPlayer(ped) then return false end
    local netId = NetworkGetNetworkIdFromEntity(ped)
    return netId ~= nil and netId ~= 0 and activeCombatPeds[netId] ~= nil
end

AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    if not next(activeCombatPeds) then return end   -- no convoy NPCs around: every damage event in the world ends here
    local victim, attacker = args[1], args[2]
    if not victim or not attacker or victim == attacker then return end
    if not isTrackedCombatPed(victim) or not isTrackedCombatPed(attacker) then return end
    if GetPedRelationshipGroupHash(victim) ~= GetPedRelationshipGroupHash(attacker) then return end
    if not NetworkHasControlOfEntity(victim) or IsPedDeadOrDying(victim, true) then return end
    local snap = guardVitals[victim]
    if snap and snap.hp and snap.hp > 0 then
        SetEntityHealth(victim, snap.hp)
        SetPedArmour(victim, snap.armour or 0)
    end
    ClearEntityLastDamageEntity(victim)
    ClearEntityLastWeaponDamage(victim)
    -- Immediately clear any retaliation task against the friendly attacker
    local myPed = cache.ped or PlayerPedId()
    if myPed and DoesEntityExist(myPed) and not IsPedDeadOrDying(myPed, true) and #(GetEntityCoords(myPed) - GetEntityCoords(victim)) < 150.0 then
        TaskCombatPed(victim, myPed, 0, 16)
    else
        TaskCombatHatedTargetsAroundPed(victim, Config.NpcCombat and Config.NpcCombat.seeingRange or 250.0, 0)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    SetPedRelationshipGroupHash(PlayerPedId(), `PLAYER`)
    SetPedRelationshipGroupHash(PlayerPedId(), joaat('PLAYER'))
    for sId in pairs(syncedPlayerRelationships) do
        local pIndex = GetPlayerFromServerId(sId)
        if pIndex and pIndex ~= -1 then
            local ped = GetPlayerPed(pIndex)
            if ped and DoesEntityExist(ped) then
                SetPedRelationshipGroupHash(ped, `PLAYER`)
                SetPedRelationshipGroupHash(ped, joaat('PLAYER'))
            end
        end
    end
end)
