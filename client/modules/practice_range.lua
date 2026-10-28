-- ─── Nova Convoy — Practice Range (client) ─────────────────────────────────────
-- Squad aim-training feature: an instructor ped anyone can approach to open
-- the Armory (PracticeArmory.svelte) — pick a training area, invite
-- squadmates, everyone picks their own weapon, host deploys the whole squad
-- together. Room/roster/invite/kill-count bookkeeping lives server-side
-- (server/modules/practice_range.lua, the only piece that genuinely needs
-- to be authoritative); everything else — teleport, bot spawning, combat,
-- invincibility, weapon loadout — is client-side, same as the original solo
-- version this replaced.
--
-- The player is kept from ever dying for the whole session (invincible + damage
-- proofs + health top-up, all re-asserted every 150ms because medical scripts
-- reset them) — that is what keeps EVERY ambulance/medical script out of it,
-- not just one framework's: they all trigger off health reaching zero. If a
-- death somehow gets through anyway, the guard revives the player after
-- Config.PracticeRange.reviveDelaySeconds and nudges whichever ambulance
-- scripts are installed (Config.PracticeRange.reviveEvents). The squad also
-- lives in its own routing bucket (server module), so nobody outside can see
-- or reach them.
--
-- Weapons: the player's own real weapons are NEVER touched/removed (no
-- RemoveAllPedWeapons — that risks desyncing whatever inventory system owns
-- them). Instead the chosen practice weapon is given purely via
-- GiveWeaponToPed (never Inventory.AddItem, so nothing here ever reaches the
-- real economy) with infinite ammo, and a watchdog thread forces the ped's
-- selected weapon back to it if the player tries to switch to something
-- else from their own inventory — the practice weapon is genuinely the only
-- thing usable for the session, without ever having to touch their real
-- loadout at all.
--
-- Bots are networked peds (isNetwork=true) so every squad member can
-- perceive and fight them, but only the HOST's client ever spawns, tasks, or
-- despawns them — entity control never needs to migrate since nobody else
-- issues combat tasks to them. Kills are detected via gameEventTriggered
-- (CEventNetworkEntityDamage), not polling — each client only reports a
-- kill it itself landed, so a shared bot's death can never be double-counted
-- across squadmates the way a polling loop would.

local TGT = exports.ox_target
local NS = 'nova_convoytruck:practice'

local instructorPed = nil
local activeSession = nil -- { locationId, locationLabel, bots={}, isHost, kills, streak, recentKills, weaponHash, weaponLabel }

-- Same standard community bone tag used in client/modules/tdm.lua — see
-- that file's own comment for why this is best-effort/cosmetic-only.
local HEAD_BONE_TAG = 31086

-- AddRelationshipGroup is idempotent by name — safe to call here too rather
-- than depend on npc_relationships.lua's own registerGroups() having already
-- run first (both fire on the same onClientResourceStart event; this just
-- removes any dependency on load/registration order between the two files).
-- The groups themselves (and their hostility to each other / neutrality to
-- everything else) are declared once, centrally, in npc_relationships.lua.
local function ensurePracticeGroups()
    AddRelationshipGroup('nova_practice_bot')
    AddRelationshipGroup('nova_practice_target')
    -- 5 = hate. Without this the bots have no "hated targets" and just stand there.
    local bot, target = joaat('nova_practice_bot'), joaat('nova_practice_target')
    SetRelationshipBetweenGroups(5, bot, target)
    SetRelationshipBetweenGroups(5, target, bot)
    SetRelationshipBetweenGroups(0, bot, bot)
end

-- Lean, local-only subset of npc_relationships.lua's AGGRESSIVENESS_PROFILES —
-- not reused directly because that file's profile application (and the
-- combat-ped event contract around it) is built around control-migration
-- handling for entities that change owning client; here the host always
-- stays the owner/controller, so only the plain combat natives are needed.
local AGGRO_PROFILES = {
    -- shootRate is the game's own fire-rate scale (lower = slower, fewer bullets); how MANY bots shoot at once is limited
    -- separately (Config.PracticeRange.maxActiveShooters), so a fight comes in waves instead of a wall of fire.
    low = { ability = 0, range = 0, accuracy = 8, shootRate = 8, movement = 1 },
    medium = { ability = 0, range = 1, accuracy = 18, shootRate = 14, movement = 1 },
    high = { ability = 1, range = 1, accuracy = 28, shootRate = 22, movement = 2 },
    extreme = { ability = 1, range = 2, accuracy = 42, shootRate = 32, movement = 2 },
}

-- Gives a bot exactly ONE weapon: the one the squad picked (the same gun the player holds, so the fight is fair). Whatever
-- the ped model spawns with is removed first, the bot cannot swap to anything else, and it drops nothing when it dies.
local function armBot(ped, weapon)
    local hash = joaat(weapon)
    RemoveAllPedWeapons(ped, true)
    GiveWeaponToPed(ped, hash, 9999, false, true)
    SetCurrentPedWeapon(ped, hash, true)
    SetPedCanSwitchWeapon(ped, false)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedInfiniteAmmoClip(ped, true)
end

local function setupBotCombat(ped, weapon, aggressiveness)
    local profile = AGGRO_PROFILES[aggressiveness] or AGGRO_PROFILES.medium
    SetPedRelationshipGroupHash(ped, joaat('nova_practice_bot'))
    armBot(ped, weapon)
    SetPedCombatAbility(ped, profile.ability)
    SetPedCombatRange(ped, profile.range)
    SetPedAccuracy(ped, profile.accuracy)
    SetPedShootRate(ped, profile.shootRate)
    SetPedCombatMovement(ped, profile.movement)
    SetPedFiringPattern(ped, `FIRING_PATTERN_BURST_FIRE`)
    SetPedCombatAttributes(ped, 0, true)  -- BF_CanUseCover
    SetPedCombatAttributes(ped, 5, true)  -- BF_AlwaysFight
    SetPedCombatAttributes(ped, 46, false) -- NOT BF_AlwaysEquipBestWeapon: it must keep the picked weapon
    SetPedFleeAttributes(ped, 0, false)
    SetPedSeeingRange(ped, 65.0)
    SetPedHearingRange(ped, 65.0)
    SetPedAlertness(ped, 2)
    SetPedKeepTask(ped, true)
    pcall(SetCanAttackFriendly, ped, false, false)
end

-- Real ground height at x,y: probes downward from well above the configured Z
-- (terrain/props can sit far from a guessed value) and falls back to the
-- configured Z if nothing is found. Collision must be streamed in first.
local function groundZ(x, y, z)
    RequestCollisionAtCoord(x, y, z)
    for _ = 1, 10 do
        for _, lift in ipairs({ 60.0, 25.0, 5.0 }) do
            local found, gz = GetGroundZFor_3dCoord(x, y, z + lift, false)
            if found then return gz end
        end
        Wait(60)
    end
    return z
end

-- Either a hand-typed spawn from botSpawns, or a point on the location's
-- botRing (centre/radius) — the ring means new areas need only a centre.
local function pickBotSpawn(location)
    local spawns = location.botSpawns
    if spawns and #spawns > 0 then
        local p = spawns[math.random(#spawns)]
        return p.x, p.y, p.z
    end
    local ring = location.botRing
    if ring and ring.center then
        local a = math.random() * 2.0 * math.pi
        local r = ring.radius * (0.6 + math.random() * 0.4)
        return ring.center.x + math.cos(a) * r, ring.center.y + math.sin(a) * r, ring.center.z
    end
    return nil
end

-- Where a new bot appears: out of the player's sight, on a ring around THEM, and each new bot on a different bearing
-- (golden-angle steps), so the enemy arrives from all sides instead of popping up together at one spot.
local function pickSpreadSpawn(session)
    local me = PlayerPedId()
    local pc = GetEntityCoords(me)
    session.spawnN = (session.spawnN or 0) + 1
    local cfg = Config.PracticeRange
    local minR, maxR = cfg.botSpawnMinDistance or 48.0, cfg.botSpawnMaxDistance or 80.0
    local best
    local cam = math.rad(GetGameplayCamRot(2).z)
    local fx, fy = -math.sin(cam), math.cos(cam)   -- where the player is looking
    for try = 0, 7 do
        local a = (session.spawnN * 2.399963 + try * 0.9 + (math.random() - 0.5) * 0.5) % (2.0 * math.pi)
        local dx, dy = math.cos(a), math.sin(a)
        -- the first tries never pick a bearing within ~60 degrees of the view: the enemy comes from the sides and from behind
        if not (try < 6 and dx * fx + dy * fy > 0.5) then
            local r = minR + math.random() * (maxR - minR)
            local x, y = pc.x + dx * r, pc.y + dy * r
            RequestCollisionAtCoord(x, y, pc.z)
            local found, gz
            for _ = 1, 3 do   -- the ground 50-80 m away is often not streamed in yet: give it a moment instead of failing
                for _, lift in ipairs({ 40.0, 12.0 }) do
                    found, gz = GetGroundZFor_3dCoord(x, y, pc.z + lift, false)
                    if found then break end
                end
                if found then break end
                Wait(60)
            end
            if not found then gz = pc.z end   -- spawnBot's groundZ() settles the height once the ground is there
            if math.abs(gz - pc.z) < 30.0 then
                local isWater, wh = GetWaterHeight(x, y, gz)
                if not (found and isWater and wh > gz - 0.5) then
                    best = best or { x, y, gz }
                    if not IsSphereVisible(x, y, gz + 1.0, 2.0) then return x, y, gz end   -- not in the player's view: take it
                end
            end
        end
        Wait(0)
    end
    if best then return best[1], best[2], best[3] end
    return nil
end

local function pickPlayerSpawn(location)
    if not location then return nil end
    if location.playerSpawns and #location.playerSpawns > 0 then
        return location.playerSpawns[math.random(1, #location.playerSpawns)]
    end
    return location.playerSpawn
end

-- Networked (isNetwork=true, netMissionEntity=true) so squadmates other than
-- the host can perceive and fight it — only the host ever calls this.
-- A point in a ring around the PLAYER. Used when a configured spawn is nowhere
-- near them (the coordinate is wrong for this map) or creation keeps failing, so
-- bots always appear somewhere the player can actually fight them.
local function nearPlayerSpawn(minR, maxR)
    local pc = GetEntityCoords(PlayerPedId())
    local cam = math.rad(GetGameplayCamRot(2).z)
    local a = math.atan(math.cos(cam), -math.sin(cam)) + math.pi + (math.random() - 0.5) * 2.0   -- behind the view, +-57 degrees
    local r = minR + math.random() * (maxR - minR)
    return pc.x + math.cos(a) * r, pc.y + math.sin(a) * r, pc.z
end

-- Creates one bot, or returns nil after 3 failed attempts (logged to F8).
-- Every attempt is pcall-guarded: one bad model/coordinate must never abort the
-- rest of the session's spawning.
local function spawnBot(location, slot, weaponName, session)
    pcall(ensurePracticeGroups)
    for attempt = 1, 3 do
        local x, y, z
        if attempt < 3 and session then x, y, z = pickSpreadSpawn(session) end
        if not x and attempt < 3 then x, y, z = pickBotSpawn(location) end
        local pc = GetEntityCoords(PlayerPedId())
        if not x or #(vec3(x, y, z) - pc) > 110.0 or attempt == 3 then
            x, y, z = nearPlayerSpawn(26.0, 48.0)
        end
        z = groundZ(x, y, z)

        -- Attempts 1-2 make a networked ped (squadmates can see it). If the game
        -- refuses to keep a networked one, attempt 3 makes a local-only ped so the
        -- host at least always has something to fight.
        local networked = attempt < 3
        local ok, ped = pcall(function()
            lib.requestModel(location.botModel)
            local p = CreatePed(4, joaat(location.botModel), x, y, z, math.random(0, 359) + 0.0, networked, true)
            SetModelAsNoLongerNeeded(location.botModel)
            return p
        end)

        if ok and ped and ped ~= 0 and DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, true, true)
            SetEntityVisible(ped, true, false)
            SetEntityCollision(ped, true, true)
            FreezeEntityPosition(ped, false)
            -- the bot holds the gun the squad picked (the area's own botWeapon is only the fallback)
            setupBotCombat(ped, weaponName or location.botWeapon, location.aggressiveness)
            -- a new bot starts "holding" (advancing without firing); manageBots lets a few at a time open fire
            SetBlockingOfNonTemporaryEvents(ped, true)
            TaskGoToEntity(ped, PlayerPedId(), -1, 20.0, 2.0, 1073741824, 0)
            -- "Bot 1", "Bot 2"... — a stable slot number replicated through the
            -- entity's state bag so whichever squad member kills it can name it
            -- in the feed. Wait for the entity to be networked first.
            if slot then
                local t = GetGameTimer() + 500
                while not NetworkGetEntityIsNetworked(ped) and GetGameTimer() < t do Wait(25) end
                pcall(function() Entity(ped).state:set('nova_bot_slot', slot, true) end)
            end
            -- have the server put it in the practice bucket, or nobody in the
            -- private world can see it
            if NetworkGetEntityIsNetworked(ped) then
                TriggerServerEvent(NS .. ':server:botSpawned', NetworkGetNetworkIdFromEntity(ped))
            else
                print(('[nova_convoytruck] practice bot %s: created but not networked'):format(tostring(slot)))
            end
            return ped
        end
        print(('[nova_convoytruck] practice bot %s: spawn attempt %d failed (model=%s ok=%s ped=%s exists=%s at %.1f, %.1f, %.1f)'):format(
            tostring(slot), attempt, tostring(location.botModel), tostring(ok), tostring(ped),
            tostring(ok and ped and ped ~= 0 and DoesEntityExist(ped) or false), x, y, z))
        Wait(250)
    end
    return nil
end

local function findLocation(id)
    for _, loc in ipairs(Config.PracticeRange.locations) do
        if loc.id == id then return loc end
    end
    return nil
end

-- Keeps every numbered slot filled. Runs at session start and every 2s from the
-- host loop, so a bot that failed to spawn, was culled, or was deleted by some
-- other script comes straight back. Slots waiting on their kill-respawn delay
-- are left alone. Bots are spawned gradually so players are not overwhelmed at once.
local function ensureBots(session)
    if session.ensuring then return end
    session.ensuring = true
    CreateThread(function()
        local location = findLocation(session.locationId)
        if location and activeSession == session then
            local target = session.botTarget or Config.PracticeRange.sessionBotCount or 4

            -- Clean up dead/deleted bots
            for slot = 1, target do
                local existing = session.slotPed[slot]
                if existing and DoesEntityExist(existing) and IsEntityDead(existing) then
                    session.deadSince = session.deadSince or {}
                    local since = session.deadSince[existing] or GetGameTimer()
                    session.deadSince[existing] = since
                    if GetGameTimer() - since > 2000 then
                        session.deadSince[existing] = nil
                        session.bots[existing] = nil
                        session.botSlots[existing] = nil
                        DeleteEntity(existing)
                        session.slotPed[slot] = nil
                        existing = nil
                    end
                elseif existing and not DoesEntityExist(existing) then
                    session.bots[existing] = nil
                    session.botSlots[existing] = nil
                    session.slotPed[slot] = nil
                    existing = nil
                end
            end

            -- Count active bots alive right now
            local currentAlive = 0
            for slot = 1, target do
                local p = session.slotPed[slot]
                if p and DoesEntityExist(p) and not IsEntityDead(p) then
                    currentAlive = currentAlive + 1
                end
            end

            -- Spawn missing slots gradually
            for slot = 1, target do
                if activeSession ~= session then break end
                local existing = session.slotPed[slot]
                if not session.slotPending[slot] and not (existing and DoesEntityExist(existing)) then
                    session.slotPed[slot] = nil
                    local okSpawn, bot = pcall(spawnBot, location, slot, session.weaponName, session)
                    if not okSpawn then
                        print(('[nova_convoytruck] practice bot %s: spawn error: %s'):format(tostring(slot), tostring(bot)))
                        bot = nil
                    end
                    if bot then
                        session.bots[bot] = true
                        session.botSlots[bot] = slot
                        session.slotPed[slot] = bot
                        currentAlive = currentAlive + 1
                    end

                    -- Gradual delay: initial 2 bots spawn with small delay, subsequent bots stagger by 1.8s
                    if currentAlive < target and activeSession == session then
                        Wait(currentAlive < 2 and 1200 or 2500)
                    end
                end
            end
        end
        if session then session.ensuring = false end
    end)
end

-- Host changed the practice weapon mid-session: every bot already standing switches to the new gun too.
local function rearmBots(session)
    if not session or not session.isHost or not session.weaponName then return end
    for bot in pairs(session.bots) do
        if DoesEntityExist(bot) and not IsEntityDead(bot) then armBot(bot, session.weaponName) end
    end
end

local function toast(icon, title, message, warn, duration)
    SendNUIMessage({ action = 'showToast', icon = icon, title = title, message = message or '', type = warn and 'warn' or 'success', duration = duration or 3000 })
end

-- ── Weapon loadout (practice weapon only, real weapons never touched) ──────────

local function applyWeaponLoadout(session, weaponName, weaponLabel)
    local ped = PlayerPedId()
    local hash = joaat(weaponName)
    if session.weaponHash and session.weaponHash ~= hash then
        SetPedInfiniteAmmo(ped, false, session.weaponHash)
        RemoveWeaponFromPed(ped, session.weaponHash)
    end
    GiveWeaponToPed(ped, hash, 250, false, true)
    -- Suppressed = silent to IsPedCurrentWeaponSilenced, which is what stops
    -- most police-dispatch scripts from raising "shots fired" calls.
    if Config.PracticeRange.silenceWeapons ~= false then
        for _, w in ipairs(Config.PracticeRange.weapons) do
            if w.weapon == weaponName and w.suppressor then
                GiveWeaponComponentToPed(ped, hash, joaat(w.suppressor))
                break
            end
        end
    end
    -- NOT infinite: a big finite reserve (Config.PracticeRange.reserveClips clips)
    -- so the player still has to reload. The game caps a weapon's total ammo, so
    -- the reserve is clamped to that cap.
    SetPedInfiniteAmmo(ped, false, hash)
    SetPedInfiniteAmmoClip(ped, false)
    local clip = GetWeaponClipSize(hash)
    if not clip or clip <= 0 then clip = 30 end
    local ammo = clip * (Config.PracticeRange.reserveClips or 2500)
    local okMax, maxAmmo = GetMaxAmmo(ped, hash)
    if okMax and maxAmmo and maxAmmo > 0 and ammo > maxAmmo then ammo = maxAmmo end
    SetPedAmmo(ped, hash, ammo)
    SetAmmoInClip(ped, hash, clip)
    SetCurrentPedWeapon(ped, hash, true)
    session.weaponHash = hash
    session.weaponName = weaponName
    session.weaponLabel = weaponLabel
end

local function clearWeaponLoadout(session)
    local ped = PlayerPedId()
    if session.weaponHash then
        SetPedInfiniteAmmo(ped, false, session.weaponHash)
        RemoveWeaponFromPed(ped, session.weaponHash)
    end
    SetPedInfiniteAmmoClip(ped, false)
end

-- Forces the ped's SELECTED weapon back to the practice one if the player
-- tries to switch to a real weapon from their own inventory via the wheel —
-- the only way "only the practice weapon is usable" holds without ever
-- calling RemoveAllPedWeapons on their actual loadout. Unarmed is allowed
-- through (harmless, no ammo to exploit).
CreateThread(function()
    while true do
        Wait(activeSession and 300 or 1500)
        if activeSession and activeSession.weaponHash and not activeSession.reviving then
            local ped = PlayerPedId()
            -- Inventory scripts (ox_inventory calls RemoveAllPedWeapons on several
            -- events) can strip a natively-given weapon. If the practice gun is
            -- gone, hand it straight back — with a fresh reserve.
            if not HasPedGotWeapon(ped, activeSession.weaponHash, false) then
                applyWeaponLoadout(activeSession, activeSession.weaponName, activeSession.weaponLabel)
            else
                local current = GetSelectedPedWeapon(ped)
                if current ~= activeSession.weaponHash and current ~= `WEAPON_UNARMED` then
                    SetCurrentPedWeapon(ped, activeSession.weaponHash, true)
                end
            end
        end
    end
end)

-- Host-only: keeps every bot slot filled and decides WHO is shooting. A real firefight is not twelve people holding the
-- trigger at once: only Config.PracticeRange.maxActiveShooters bots fire at a time (a few more per extra squadmate). The
-- others keep advancing on the player without shooting ("hold"), and take their turn after a short pause, so the fire
-- arrives in waves from different directions instead of one continuous spray.
local function nearestPlayerPed(bot)
    local me = PlayerPedId()
    local bc = GetEntityCoords(bot)
    local best, bestD = me, #(bc - GetEntityCoords(me))
    for _, pid in ipairs(GetActivePlayers()) do
        local p = GetPlayerPed(pid)
        if p ~= 0 and p ~= me and not IsEntityDead(p) then
            local d = #(bc - GetEntityCoords(p))
            if d < bestD then best, bestD = p, d end
        end
    end
    return best, bestD
end

local function botOpenFire(bot)
    SetBlockingOfNonTemporaryEvents(bot, false)
    local target = nearestPlayerPed(bot)
    TaskCombatPed(bot, target, 0, 16)
    SetPedKeepTask(bot, true)
end

-- A bot that is not firing keeps MOVING: it runs to a point on a ring around the player, a little further round from where it is, so
-- the bots circle and flank instead of standing in a row like pedestrians. Reached it? The manager below sends it to the next one.
local function botHoldFire(bot)
    local target = nearestPlayerPed(bot)
    local tc, bc = GetEntityCoords(target), GetEntityCoords(bot)
    SetBlockingOfNonTemporaryEvents(bot, true)       -- a bot that is not reacting does not shoot
    ClearPedTasks(bot)
    local dist = #(bc - tc)
    if dist > 34.0 then
        TaskGoToEntity(bot, target, -1, 18.0 + math.random() * 8.0, 2.0, 1073741824, 0)   -- still far: close the gap first
    else
        local a = math.atan(bc.y - tc.y, bc.x - tc.x) + (math.random() < 0.5 and 1 or -1) * (0.5 + math.random() * 0.9)
        local r = 14.0 + math.random() * 10.0
        TaskGoToCoordAnyMeans(bot, tc.x + math.cos(a) * r, tc.y + math.sin(a) * r, tc.z, 2.5, 0, false, 786603, 0.0)
    end
    SetPedKeepTask(bot, true)
end

CreateThread(function()
    local tick = 0
    while true do
        Wait(activeSession and 1000 or 2000)
        local session = activeSession
        if session and session.isHost then
            tick = tick + 1
            if tick % 2 == 0 then ensureBots(session) end
            if activeSession == session then
                local cfg = Config.PracticeRange
                local maxActive = (cfg.maxActiveShooters or 3) + (cfg.activeShootersPerExtraPlayer or 2) * math.max(0, (session.squadSize or 1) - 1)
                local fireMin, fireMax = (cfg.shooterBurstSeconds and cfg.shooterBurstSeconds[1] or 5), (cfg.shooterBurstSeconds and cfg.shooterBurstSeconds[2] or 9)
                local holdMin, holdMax = (cfg.shooterPauseSeconds and cfg.shooterPauseSeconds[1] or 3), (cfg.shooterPauseSeconds and cfg.shooterPauseSeconds[2] or 6)
                session.botMode = session.botMode or {}
                local now = GetGameTimer()

                -- pass 1: forget gone bots, retire shooters whose turn is over, count who is still firing
                local active, waiting = 0, {}
                for bot, st in pairs(session.botMode) do
                    if not DoesEntityExist(bot) or IsEntityDead(bot) then
                        session.botMode[bot] = nil
                    end
                end
                for bot in pairs(session.bots) do
                    if DoesEntityExist(bot) and not IsEntityDead(bot) then
                        local st = session.botMode[bot]
                        if not st then
                            st = { mode = 'hold', untilT = now + math.random(0, 2500) }      -- new bots start by advancing
                            session.botMode[bot] = st
                        end
                        if st.mode == 'active' then
                            if now > st.untilT then
                                st.mode, st.untilT = 'hold', now + math.random(holdMin * 1000, holdMax * 1000)
                                botHoldFire(bot)
                            else
                                active = active + 1
                                if not IsPedInCombat(bot, PlayerPedId()) then botOpenFire(bot) end   -- dropped its task: re-issue
                            end
                        else
                            waiting[#waiting + 1] = { bot = bot, st = st }
                        end
                    end
                end

                -- pass 2: whoever has waited longest gets the free firing slots
                table.sort(waiting, function(a, b) return a.st.untilT < b.st.untilT end)
                for _, w in ipairs(waiting) do
                    if active < maxActive and now > w.st.untilT then
                        w.st.mode, w.st.untilT = 'active', now + math.random(fireMin * 1000, fireMax * 1000)
                        botOpenFire(w.bot)
                        active = active + 1
                    elseif not IsPedWalking(w.bot) and not IsPedRunning(w.bot) then
                        botHoldFire(w.bot)                                                   -- stopped: next point on the ring
                    end
                end
            end
        end
    end
end)

-- Virtual health bar (horizontal HUD) — PlayerHealthBar.svelte
-- The bar always reads 0-100 (Config.PracticeRange.playerHealth), but the pool behind it is bigger
-- (× Config.PracticeRange.hiddenHealthMultiplier, 2 = 200 real points), so a practice match lasts longer than the
-- number suggests. session.hp is in POOL points; the bar shows it scaled back down.
local function hpShown() return Config.PracticeRange.playerHealth or 100 end
local function hpPool() return hpShown() * math.max(1.0, Config.PracticeRange.hiddenHealthMultiplier or 2.0) end

local function pushHp(session)
    local shown, pool = hpShown(), hpPool()
    local hp = session.hp or pool
    SendNUIMessage({ action = 'playerHealth', hp = math.max(0, math.ceil(hp / pool * shown)), max = shown })
end

-- bot hit → virtual HP (defined further down, used by the guard thread below)
local onBotHitPlayer

-- ── Never-die protection + 2s revive safety net ─────────────────────────────────

local function applyProtection(ped)
    SetEntityInvincible(ped, true)
    SetPlayerInvincible(PlayerId(), true)
    SetEntityCanBeDamaged(ped, true)
    -- Fully proofed, bullets included. The player's REAL health must never change: any damage event on the player is
    -- picked up by the installed medical script (qbx_medical etc.), which then bleeds, ragdolls and finally kills them
    -- ("hold E to respawn for $2000"). A bot's hit is therefore not read from the game at all — see the incoming-fire
    -- check further down, which takes it from the virtual health pool.
    SetEntityProofs(ped, true, true, true, true, true, true, true, true)
    SetPedCanRagdoll(ped, false)
end

local function removeProtection(ped)
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)
    SetPedCanRagdoll(ped, true)
end

-- ox_inventory polices weapons every 200ms: any weapon it doesn't own gets
-- Weapon.Disarm -> RemoveAllPedWeapons, which stripped the practice gun the
-- moment it was given (so it "couldn't be used"). Its weapon-wheel mode exists
-- for exactly this kind of native-weapon situation (weaponised vehicles,
-- minigames) and switches that enforcement off. We turn it on for the session
-- and back off on the way out; the real inventory stays locked either way.
local function allowNativeWeapons(state)
    if GetResourceState('ox_inventory') == 'started' then
        pcall(function() exports.ox_inventory:weaponWheel(state) end)
    end
end

-- Locks the real inventory for the whole session. ox_inventory reads the
-- 'invBusy' / 'invHotkeys' state bags (it resets invBusy after its own actions,
-- so this is re-asserted by the guard thread); 'inv_busy' is the equivalent
-- for qb/qbx-style inventories. Nothing in the inventory is ever touched.
local function lockInventory()
    if Config.PracticeRange.lockInventory == false then return end
    local state = LocalPlayer.state
    -- only write when something flipped it (ox resets invBusy after its own
    -- actions) — avoids replicating three state bags every 150ms
    if state.invBusy ~= true then state:set('invBusy', true, true) end
    if state.invHotkeys ~= false then state:set('invHotkeys', false, false) end
    if state.inv_busy ~= true then state:set('inv_busy', true, true) end
end

local function unlockInventory()
    allowNativeWeapons(false)
    local state = LocalPlayer.state
    state:set('invBusy', false, true)
    state:set('invHotkeys', true, false)
    state:set('inv_busy', false, true)
end

-- One-time at session start: shut the inventory and holster whatever real
-- weapon is equipped BEFORE locking, so the lock can't strand a drawn gun.
local function clearInventoryOnEntry()
    if Config.PracticeRange.lockInventory == false then return end
    if GetResourceState('ox_inventory') == 'started' then
        pcall(function() exports.ox_inventory:closeInventory() end)
        TriggerEvent('ox_inventory:disarm', true)
        Wait(150)
    end
    lockInventory()
    allowNativeWeapons(true)
end

local function isDown(ped)
    if IsEntityDead(ped) or IsPedDeadOrDying(ped, true) or IsPedFatallyInjured(ped) then return true end
    -- the medical script's own dead / last-stand state (it can put the player "down" without the ped being dead)
    local s = LocalPlayer.state
    return s.isDead == true or s.isLastStand == true or s.isLaststand == true
end

-- Brings the player back on the spot, then tells every installed ambulance
-- script to drop its dead/laststand state. Runs once per death.
local function revivePracticePlayer(session)
    session.reviving = true
    Wait(math.floor((Config.PracticeRange.reviveDelaySeconds or 2) * 1000))
    if activeSession ~= session then return end

    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    NetworkResurrectLocalPlayer(c.x, c.y, c.z, heading, true, false)
    ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    ClearPedBloodDamage(ped)
    ResetPedVisibleDamage(ped)
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    applyProtection(ped)
    -- back on their feet = full bar again
    session.hp = hpPool()
    session.lastHit = GetGameTimer()
    session.graceUntil = GetGameTimer() + 3000
    pushHp(session)

    pcall(function()
        if exports.qbx_medical then exports.qbx_medical:revive() end
    end)
    for _, hook in ipairs(Config.PracticeRange.reviveEvents or {}) do
        if GetResourceState(hook.resource) == 'started' then
            TriggerEvent(hook.event, hook.arg)
        end
    end

    -- medical scripts can re-flip invincibility / weapons while clearing their
    -- state, so restore everything once they're done
    Wait(250)
    if activeSession ~= session then return end
    ped = PlayerPedId()
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    applyProtection(ped)
    applyWeaponLoadout(session, session.weaponName, session.weaponLabel)
    session.hp = hpPool()
    pushHp(session)
    session.reviving = false
end

CreateThread(function()
    while true do
        Wait(activeSession and 100 or 750)
        local session = activeSession
        if session and not session.reviving then
            local ped = PlayerPedId()
            if isDown(ped) then
                CreateThread(function() revivePracticePlayer(session) end)
            else
                -- re-assert: medical scripts can reset invincibility; real ped
                -- stays full health, while virtual HP tracks combat damage
                applyProtection(ped)
                lockInventory()
                local maxHealth = GetEntityMaxHealth(ped)
                if GetEntityHealth(ped) < maxHealth then SetEntityHealth(ped, maxHealth) end

                -- virtual HP creeps back up when nobody has hit the player for a few seconds
                local pool = hpPool()
                if (session.hp or pool) < pool and GetGameTimer() - (session.lastHit or 0) > 4000 then
                    session.hp = math.min(pool, (session.hp or pool) + 3)
                    pushHp(session)
                end
            end
        end
    end
end)

-- ── Exit point: map blip + ground marker + [E] to return ────────────────────────

local exitBlip, exitRadiusBlip, exitPos, exitHintShown, exitWaypoint = nil, nil, nil, false, false

local function clearExit()
    if exitBlip and DoesBlipExist(exitBlip) then RemoveBlip(exitBlip) end
    if exitRadiusBlip and DoesBlipExist(exitRadiusBlip) then RemoveBlip(exitRadiusBlip) end
    exitBlip, exitRadiusBlip, exitPos = nil, nil, nil
    if exitHintShown then
        exitHintShown = false
        lib.hideTextUI()
    end
    -- only remove the route WE set, never one the player placed themselves
    if exitWaypoint then
        exitWaypoint = false
        SetWaypointOff()
    end
end

local function createExit(location)
    clearExit()
    local cfg = Config.PracticeRange.exitBlip or {}
    local p = location.exitPoint or location.playerSpawn
    local z = groundZ(p.x, p.y, p.z)
    exitPos = vec3(p.x, p.y, z)

    exitBlip = AddBlipForCoord(exitPos.x, exitPos.y, exitPos.z)
    SetBlipSprite(exitBlip, cfg.sprite or 408)
    SetBlipColour(exitBlip, cfg.colour or 2)
    SetBlipScale(exitBlip, cfg.scale or 1.1)
    SetBlipAsShortRange(exitBlip, false)
    SetBlipHighDetail(exitBlip, true)
    SetBlipDisplay(exitBlip, 4)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(cfg.label or 'Practice Arena Exit')
    EndTextCommandSetBlipName(exitBlip)
    -- a soft coloured circle under the icon so the exit is easy to spot on the map
    exitRadiusBlip = AddBlipForRadius(exitPos.x, exitPos.y, exitPos.z, 14.0)
    SetBlipColour(exitRadiusBlip, cfg.colour or 2)
    SetBlipAlpha(exitRadiusBlip, 110)
end

-- Local-only teardown: clears this client's own world state (bots if host,
-- weapon, invincibility, relationship group, HUD). Does NOT talk to the
-- server — used both for a server-driven teardown (someone else ended the
-- session) and for resource shutdown, where a further round trip would be
-- pointless or impossible.
local function localCleanup(showEndToast)
    if not activeSession then return false end
    if activeSession.isHost then
        for bot in pairs(activeSession.bots) do
            if DoesEntityExist(bot) then DeleteEntity(bot) end
        end
    end
    local kills = activeSession.kills
    clearWeaponLoadout(activeSession)
    activeSession = nil
    NovaInPractice = false
    clearExit()
    local ped = PlayerPedId()
    removeProtection(ped)
    unlockInventory()
    SetPedRelationshipGroupHash(ped, joaat('PLAYER'))
    ConvoyUI.practiceHudHide()
    SendNUIMessage({ action = 'playerHealthHide' })
    if showEndToast then
        toast('🎯', 'Practice Session Ended', ('%d bot kill%s'):format(kills, kills == 1 and '' or 's'))
    end
    return true
end

-- exact = true: land on precisely pos (no ground re-snap). Used for the admin-set
-- return vector, which is trusted as-is — a downward probe from 60m up can hit a
-- roof or overhang and "correct" the player to the wrong height.
local function teleportPlayerTo(pos, noJitter, exact)
    local ped = PlayerPedId()
    RequestCollisionAtCoord(pos.x, pos.y, pos.z)
    -- Small per-player jitter so a full squad doesn't stack on the exact
    -- same coordinate.
    local jx, jy = 0.0, 0.0
    if not noJitter then jx, jy = (math.random(-15, 15)) / 10.0, (math.random(-15, 15)) / 10.0 end
    local veh = GetVehiclePedIsIn(ped, false)
    local entity = veh ~= 0 and veh or ped
    local tx, ty = pos.x + jx, pos.y + jy
    SetEntityCoords(entity, tx, ty, pos.z, false, false, false, true)
    if pos.w then SetEntityHeading(entity, pos.w) end

    -- A long jump lands before the destination's ground has streamed in, and
    -- the player would fall through the map. Hold them still until collision
    -- is there (max 2.5s), then re-snap to the real ground height.
    FreezeEntityPosition(entity, true)
    local timeout = GetGameTimer() + 2500
    while not HasCollisionLoadedAroundEntity(entity) and GetGameTimer() < timeout do
        RequestCollisionAtCoord(tx, ty, pos.z)
        Wait(50)
    end
    if exact then
        SetEntityCoords(entity, tx, ty, pos.z, false, false, false, true)
        if pos.w then SetEntityHeading(entity, pos.w) end
    else
        local gz = groundZ(tx, ty, pos.z)
        if math.abs(gz - pos.z) > 0.75 then
            SetEntityCoords(entity, tx, ty, gz + 0.3, false, false, false, true)
        end
    end
    FreezeEntityPosition(entity, false)
end

-- Set when this client ended a REAL session on its own (as opposed to only
-- closing the Armory) so the server's sessionEnded reply knows to walk them
-- back to the instructor once their routing bucket is normal again.
local pendingReturn = false

-- Puts the player back in front of the practice ped, facing it. Called only
-- after the server has already moved them out of the practice bucket, so they
-- land in the normal world.
local function returnToInstructor()
    -- Always in front of the practice ped, wherever an admin placed it (tablet → World Peds), facing it. Config
    -- returnCoords is only the fallback for when no ped position is known at all.
    local wp = WorldPeds.get('practice')
    local dest
    if wp and wp.x then
        local h = math.rad(wp.heading or 0.0)
        -- a step in front of the ped, with a little sideways spread so players leaving together do not stack
        local side = (math.random() - 0.5) * 1.0
        local x = wp.x - math.sin(h) * 1.8 + math.cos(h) * side
        local y = wp.y + math.cos(h) * 1.8 + math.sin(h) * side
        dest = vec4(x, y, groundZ(x, y, wp.z) + 0.3, ((wp.heading or 0.0) + 180.0) % 360.0)
    elseif Config.PracticeRange.returnCoords then
        local r = Config.PracticeRange.returnCoords
        dest = vec4(r.x, r.y, r.z, r.w or 0.0)
    else
        local c = Config.PracticeRange.pedCoords
        dest = vec4(c.x, c.y, c.z, c.w or 0.0)
    end
    DoScreenFadeOut(250)
    local t = GetGameTimer() + 600
    while not IsScreenFadedOut() and GetGameTimer() < t do Wait(0) end
    teleportPlayerTo(dest, true, false)
    DoScreenFadeIn(350)
    -- back in the normal world: the server can forget this player was ever in a session
    TriggerServerEvent(NS .. ':server:practiceDone')
end

-- Player-initiated leave/end (ped option, /endpractice, closing the Armory
-- before deploying) — tells the server too, which decides whether that just
-- removes this one member or tears down the whole squad (host leaving does).
local function leavePracticeSquad()
    pendingReturn = localCleanup(false) == true
    TriggerServerEvent(NS .. ':server:leaveSession')
    if pendingReturn then
        -- The server's sessionEnded reply normally triggers the walk back to the
        -- ped. If it is slow or lost, still get the player out after 3 seconds
        -- (the flag is cleared by the reply, so this never double-fires).
        SetTimeout(3000, function()
            if pendingReturn then
                pendingReturn = false
                returnToInstructor()
            end
        end)
    end
end

-- Draws the exit marker and handles [E]. Cheap when far away (500ms tick),
-- per-frame only when the marker is near enough to draw.
CreateThread(function()
    while true do
        local sleep = 500
        if activeSession and exitPos then
            local dist = #(GetEntityCoords(PlayerPedId()) - exitPos)
            local radius = Config.PracticeRange.exitRadius or 2.0
            -- Bright and visible from far away: pulsing ground ring, a tall
            -- light beam, and a real light that glows on nearby surfaces.
            if dist < 250.0 then
                sleep = 0
                local g = Config.PracticeRange.exitGlow or { r = 80, g = 255, b = 140 }
                local pulse = 0.5 + 0.5 * math.sin(GetGameTimer() / 280.0)
                local ringAlpha = math.floor(150 + pulse * 90)
                DrawMarker(1, exitPos.x, exitPos.y, exitPos.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    radius * 2.0, radius * 2.0, 1.4, g.r, g.g, g.b, ringAlpha, false, false, 2, false, nil, nil, false)
                DrawMarker(1, exitPos.x, exitPos.y, exitPos.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.7, 0.7, 70.0, g.r, g.g, g.b, math.floor(70 + pulse * 50), false, false, 2, false, nil, nil, false)
                if dist < 60.0 then
                    DrawLightWithRange(exitPos.x, exitPos.y, exitPos.z + 1.0, g.r, g.g, g.b, 12.0, 3.0 + pulse * 3.0)
                end
            end
            if dist <= radius then
                if not exitHintShown then
                    exitHintShown = true
                    lib.showTextUI('[E]  Leave the Practice Range', { position = 'right-center', icon = 'door-open' })
                end
                if IsControlJustReleased(0, 38) then
                    leavePracticeSquad()
                end
            elseif exitHintShown then
                exitHintShown = false
                lib.hideTextUI()
            end
        elseif exitHintShown then
            exitHintShown = false
            lib.hideTextUI()
        end
        Wait(sleep)
    end
end)

-- /endpractice and F6: walk to the exit marker and press [E]. The blip flashes
-- and a GPS route is set so it can be found from anywhere in the area.
local function guideToExit()
    if not exitPos then return leavePracticeSquad() end
    SetNewWaypoint(exitPos.x, exitPos.y)
    exitWaypoint = true
    if exitBlip and DoesBlipExist(exitBlip) then
        SetBlipFlashes(exitBlip, true)
        local blip = exitBlip
        SetTimeout(10000, function()
            if DoesBlipExist(blip) then SetBlipFlashes(blip, false) end
        end)
    end
    toast('🚪', 'Practice Range', 'Head to the flashing exit marker and press [E] to return.', false, 5000)
end


local function startPracticeSession(location, weaponName, weaponLabel, isHost, squadSize)
    -- Snap the spawn to real ground so a guessed Z can never bury the player.
    local sp = pickPlayerSpawn(location) or location.playerSpawn
    local spawn = vec4(sp.x, sp.y, groundZ(sp.x, sp.y, sp.z) + 0.5, sp.w or 0.0)
    teleportPlayerTo(spawn)
    createExit(location)
    local ped = PlayerPedId()
    applyProtection(ped)
    clearInventoryOnEntry()
    ensurePracticeGroups()
    SetPedRelationshipGroupHash(ped, joaat('nova_practice_target'))

    local session = { locationId = location.id, locationLabel = location.label, bots = {}, botSlots = {}, slotPed = {}, slotPending = {}, isHost = isHost, kills = 0, streak = 0 }
    -- more players, more bots (kill-feed naming supports Bot 1..32)
    local base = Config.PracticeRange.sessionBotCount or 4
    local extra = Config.PracticeRange.botsPerExtraPlayer or 0
    session.botTarget = math.min(32, base + extra * math.max(0, (squadSize or 1) - 1))
    session.squadSize = squadSize or 1
    activeSession = session
    NovaInPractice = true
    session.hp = hpPool()
    pushHp(session)
    applyWeaponLoadout(session, weaponName, weaponLabel)

    if isHost then
        ensureBots(session)
        local alive = 0
        for bot in pairs(session.bots) do if DoesEntityExist(bot) then alive = alive + 1 end end
        print(('[nova_convoytruck] practice session at %s: %d bot(s) spawned'):format(tostring(location.id), alive))
        if alive == 0 then
            toast('⚠️', 'Practice Range', 'No bots could be spawned — check the F8 console for errors.', true, 6000)
        end
    end

    toast('🎯', 'Practice Session Started', ('%s — %s'):format(location.label, weaponLabel))
    ConvoyUI.practiceHudUpdate(session.kills, location.label)
end

-- ── Server-driven room/roster events ────────────────────────────────────────

RegisterNetEvent(NS .. ':client:openArmory', function(roster, isHostFlag)
    SetNuiFocus(true, true)
    ConvoyUI.openPracticeArmory(Config.PracticeRange.locations, Config.PracticeRange.weapons, roster, isHostFlag)
end)

RegisterNetEvent(NS .. ':client:squadUpdate', function(roster)
    ConvoyUI.updatePracticeSquad(roster)
end)

RegisterNetEvent(NS .. ':client:invitePrompt', function(hostSrc, hostName)
    local accepted = lib.alertDialog({
        header = 'Practice Squad Invite',
        content = ('%s invited you to practice together.'):format(hostName),
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })
    if accepted == 'confirm' then
        TriggerServerEvent(NS .. ':server:acceptInvite', hostSrc)
    else
        TriggerServerEvent(NS .. ':server:declineInvite', hostSrc)
    end
end)

RegisterNetEvent(NS .. ':client:notify', function(message, warn)
    toast('🎯', 'Practice Range', message, warn, 3500)
end)

RegisterNetEvent(NS .. ':client:sessionEnded', function(reason)
    if not NovaResultsOpen then SetNuiFocus(false, false) end
    ConvoyUI.closePracticeArmory()
    -- Ended by the host / a kick / a disconnect-side teardown (session still
    -- running here) OR by this player's own leave (pendingReturn) — either
    -- way they were inside the range, so send them back to the ped. Merely
    -- closing the Armory before deploying never left the ped, so no teleport.
    local wasInSession = localCleanup(false) or pendingReturn
    pendingReturn = false
    if wasInSession then returnToInstructor() end
    if reason then toast('🎯', 'Practice Range', reason, true, 3500) end
end)

-- After a crash / disconnect / restart in the middle of a session: the server found this character's unfinished-session
-- marker and has already put them back in the normal world. Undo anything the session left on this client and walk
-- them to the practice ped.
RegisterNetEvent(NS .. ':client:recover', function()
    if activeSession then return end
    local ped = PlayerPedId()
    removeProtection(ped)
    unlockInventory()
    SetPedRelationshipGroupHash(ped, joaat('PLAYER'))
    ConvoyUI.practiceHudHide()
    SendNUIMessage({ action = 'playerHealthHide' })
    clearExit()
    returnToInstructor()
    toast('🎯', 'Practice Range', 'Your practice session was interrupted — you are back at the range.', false, 4500)
end)

-- Ask the server whether this character left a practice session unfinished (login, character load, resource restart).
RegisterNetEvent('nova_convoytruck:client:rolesResolved', function()
    if activeSession then return end
    TriggerServerEvent(NS .. ':server:recover')
end)

RegisterNetEvent(NS .. ':client:deploy', function(payload)
    SetNuiFocus(false, false)
    ConvoyUI.closePracticeArmory()
    local weaponLabel = 'Weapon'
    for _, w in ipairs(Config.PracticeRange.weapons) do
        if w.weapon == payload.weapon then weaponLabel = w.label break end
    end
    startPracticeSession(payload.location, payload.weapon, weaponLabel, payload.isHost, payload.roster and #payload.roster or 1)
end)

RegisterNetEvent(NS .. ':client:matchResults', function(payload)
    NovaResultsOpen = true
    SetNuiFocus(true, true)
    ConvoyUI.showMatchResults(payload.mode, payload.eventName, payload.duration, payload.players)
end)

-- Closing the results screen (ESC or the Close button in MatchResults.svelte)
-- hands the mouse/keyboard back to the game. Shared with the TDM results.
RegisterNUICallback('matchResults:close', function(_, cb)
    NovaResultsOpen = false
    SetNuiFocus(false, false)
    cb('ok')
end)

-- Host-only: a squadmate's kill on a shared bot was validated/counted
-- server-side, and this is that bot's netId being relayed back to whoever
-- actually owns it (spawn/despawn) — never fires for a non-host client.
RegisterNetEvent(NS .. ':client:botDown', function(netId)
    if not activeSession or not activeSession.isHost then return end
    local bot = NetworkGetEntityFromNetworkId(netId)
    local slot = nil
    local session = activeSession
    if bot and DoesEntityExist(bot) then
        slot = session.botSlots[bot] or Entity(bot).state.nova_bot_slot
        session.bots[bot] = nil
        session.botSlots[bot] = nil
        DeleteEntity(bot)
    end
    if slot then
        session.slotPed[slot] = nil
        session.slotPending[slot] = true
    end
    -- the slot is refilled by ensureBots once the respawn delay is up
    SetTimeout((Config.PracticeRange.botRespawnDelaySeconds or 4) * 1000, function()
        if activeSession == session then
            if slot then session.slotPending[slot] = nil end
            CreateThread(function() ensureBots(session) end)
        end
    end)
end)

RegisterNetEvent(NS .. ':client:killCount', function(kills)
    if activeSession then
        activeSession.kills = kills
        ConvoyUI.practiceHudUpdate(kills, activeSession.locationLabel or '')
    end
end)

RegisterNetEvent(NS .. ':client:killFeed', function(payload)
    ConvoyUI.tdmKillFeedEntry(payload)
end)

RegisterNetEvent(NS .. ':client:eventFlash', function(flashType, streak, victim)
    ConvoyUI.tdmEventFlash(flashType, streak, victim)
end)

-- ── Getting put down by a bot ──────────────────────────────────────────────
-- The ped stays invincible (see applyProtection); "down" is visual: ragdoll, no
-- firing, respawn countdown, then back up at full HP with a short grace period.
local function downPlayer(session, killerName)
    if session.reviving then return end
    session.reviving = true
    TriggerServerEvent(NS .. ':server:reportDown')
    local secs = 2 -- 2 seconds down/respawn countdown as requested
    local ped = PlayerPedId()
    SetPedCanRagdoll(ped, true)
    SetPedToRagdoll(ped, secs * 1000, secs * 1000, 0, false, false, false)
    local untilT = GetGameTimer() + secs * 1000
    SendNUIMessage({ action = 'tdmRespawnStart', seconds = secs, killer = killerName or 'Bot' })

    while GetGameTimer() < untilT and activeSession == session do
        DisablePlayerFiring(PlayerId(), true)
        DisableControlAction(0, 24, true)
        DisableControlAction(0, 25, true)
        DisableControlAction(0, 37, true)
        DisableControlAction(0, 45, true)
        Wait(0)
    end
    SendNUIMessage({ action = 'tdmRespawnHide' })
    if activeSession ~= session then return end

    ped = PlayerPedId()
    ClearPedTasksImmediately(ped)

    -- Respawn somewhere in the same arena area
    local location = findLocation(session.locationId)
    local sp = location and (pickPlayerSpawn(location) or location.playerSpawn)
    if sp then
        local angle = math.random() * 2.0 * math.pi
        local dist = math.random(3, 10)
        local rx, ry = sp.x + math.cos(angle) * dist, sp.y + math.sin(angle) * dist
        local rz = groundZ(rx, ry, sp.z)
        SetEntityCoords(ped, rx, ry, rz, false, false, false, true)
        SetEntityHeading(ped, sp.w or 0.0)
    end

    -- Clear medical / death state from installed ambulance scripts
    pcall(function()
        if exports.qbx_medical then exports.qbx_medical:revive() end
    end)
    for _, hook in ipairs(Config.PracticeRange.reviveEvents or {}) do
        if GetResourceState(hook.resource) == 'started' then
            TriggerEvent(hook.event, hook.arg)
        end
    end

    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
    ResetPedVisibleDamage(ped)
    applyProtection(ped)
    session.hp = hpPool()
    pushHp(session)
    session.lastHit = GetGameTimer()
    session.graceUntil = GetGameTimer() + 3000 -- 3 seconds of spawn protection
    session.reviving = false
end

-- Heavier guns hurt more (Config.PracticeRange.botWeaponDamageScale, keyed by weapon name; anything unlisted is ×1).
local scaleByHash
local function botDamageScale(attacker)
    local tbl = Config.PracticeRange.botWeaponDamageScale
    if not tbl then return 1.0 end
    if not scaleByHash then
        scaleByHash = {}
        for name, s in pairs(tbl) do scaleByHash[joaat(name)] = s end
    end
    local w = (attacker and attacker ~= 0 and DoesEntityExist(attacker)) and GetSelectedPedWeapon(attacker) or 0
    return scaleByHash[w] or 1.0
end

onBotHitPlayer = function(attacker)
    local session = activeSession
    if not session or session.reviving then return end
    if session.graceUntil and GetGameTimer() < session.graceUntil then return end
    local pool = hpPool()
    local dmg = (Config.PracticeRange.botHitDamage or 8) * botDamageScale(attacker)      -- in pool points
    if not session.sawFirstHit then
        session.sawFirstHit = true
        print('[nova_convoytruck] practice: first bot hit on the player registered')
    end
    session.hp = math.max(0, (session.hp or pool) - dmg)
    session.lastHit = GetGameTimer()
    pushHp(session)
    if session.hp <= 0 then
        local slot = nil
        if attacker and DoesEntityExist(attacker) then
            slot = Entity(attacker).state.nova_bot_slot
        end
        CreateThread(function() downPlayer(session, slot and ('Bot ' .. slot) or 'Bot') end)
    end
end

-- ── Incoming fire ──────────────────────────────────────────────────────────────────────────────────────────────
-- The player is fully proofed (no damage events, so the medical script never reacts), which means a bot's hit has to be
-- worked out here: a bot that is firing, faces the player and has a clear line to them lands a hit with a chance that
-- shrinks with distance (Config.PracticeRange.botHitChance). Each hit takes botHitDamage off the virtual pool.
CreateThread(function()
    local candidates, scannedAt, lastEval = {}, 0, {}
    while true do
        -- every frame: IsPedShooting is true for ONE frame per shot, so a 60 ms poll caught about one shot in eight and the bar hardly moved
        Wait(activeSession and 0 or 750)
        local session = activeSession
        if session and not session.reviving then
            local now = GetGameTimer()
            local me = PlayerPedId()
            if now - scannedAt > 1000 then
                scannedAt, candidates = now, {}
                local botGroup = joaat('nova_practice_bot')
                for _, p in ipairs(GetGamePool('CPed')) do
                    if p ~= me and not IsPedAPlayer(p) and (GetPedRelationshipGroupHash(p) == botGroup or Entity(p).state.nova_bot_slot ~= nil) then
                        candidates[#candidates + 1] = p
                    end
                end
            end
            local cfg = Config.PracticeRange
            local mc = GetEntityCoords(me)
            for i = 1, #candidates do
                local bot = candidates[i]
                if DoesEntityExist(bot) and not IsEntityDead(bot) and IsPedShooting(bot) and now - (lastEval[bot] or 0) >= (cfg.botHitCooldownMs or 140) then
                    local bc = GetEntityCoords(bot)
                    local dist = #(bc - mc)
                    if dist > 0.5 and dist <= (cfg.botFireRange or 90.0) then
                        local fwd = GetEntityForwardVector(bot)
                        local facing = (fwd.x * (mc.x - bc.x) + fwd.y * (mc.y - bc.y)) / dist
                        if facing > 0.6 and HasEntityClearLosToEntity(bot, me, 17) then
                            lastEval[bot] = now
                            local chance = (cfg.botHitChance or 0.3) * math.max(0.35, math.min(1.0, 1.3 - dist / 70.0))
                            if math.random() < chance then onBotHitPlayer(bot) end
                        end
                    end
                end
            end
        end
    end
end)

-- ── Kill detection (event-based — each client only reports its OWN kills) ──

AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' or not activeSession then return end
    local victim, attacker, isFatal, weaponHash = args[1], args[2], args[6] == 1, args[7]
    -- (a bot's hit on the player is NOT read from here: the player is fully proofed, see the incoming-fire check above)
    if victim == PlayerPedId() then return end
    if not isFatal then return end
    if attacker ~= PlayerPedId() then return end
    if not DoesEntityExist(victim) or GetEntityType(victim) ~= 1 then return end
    if GetPedRelationshipGroupHash(victim) ~= joaat('nova_practice_bot') then return end

    local netId = NetworkGetNetworkIdFromEntity(victim)
    local hasBone, boneId = GetPedLastDamageBone(victim)
    local wasHeadshot = hasBone and boneId == HEAD_BONE_TAG or false
    local slot = Entity(victim).state.nova_bot_slot
    local botName = slot and ('Bot ' .. slot) or 'Bot'
    TriggerServerEvent(NS .. ':server:reportKill', activeSession.weaponLabel or 'Weapon', wasHeadshot, netId, botName)
end)

-- ── NUI callbacks (PracticeArmory.svelte, via web/src/lib/api/practice.js) ──

RegisterNUICallback('practiceArmory:close', function(_, cb)
    leavePracticeSquad()
    cb('ok')
end)

RegisterNUICallback('practiceArmory:invite', function(data, cb)
    if data and type(data.name) == 'string' and data.name ~= '' then
        TriggerServerEvent(NS .. ':server:invite', data.name)
    end
    cb('ok')
end)

RegisterNUICallback('practiceArmory:kick', function(data, cb)
    if data and data.source then
        TriggerServerEvent(NS .. ':server:kick', tonumber(data.source))
    end
    cb('ok')
end)

RegisterNUICallback('practiceArmory:selectWeapon', function(data, cb)
    if data and type(data.weapon) == 'string' then
        TriggerServerEvent(NS .. ':server:selectWeapon', data.weapon)
    end
    cb('ok')
end)

RegisterNUICallback('practiceArmory:deploy', function(data, cb)
    if data and data.locationId then
        TriggerServerEvent(NS .. ':server:deploy', data.locationId, data.weapon)
    end
    cb('ok')
end)

-- ── Mid-session weapon change (unchanged from the solo version) ────────────

local function openChangeWeaponMenu()
    if not activeSession then return end
    local options = {}
    for _, w in ipairs(Config.PracticeRange.weapons) do
        options[#options + 1] = {
            title = w.label,
            icon = 'fa-solid fa-gun',
            onSelect = function()
                applyWeaponLoadout(activeSession, w.weapon, w.label)
                rearmBots(activeSession)
                toast('🔫', 'Weapon Changed', w.label)
            end,
        }
    end
    lib.registerContext({ id = 'nova_practice_weapon_change', title = 'Change Practice Weapon', options = options })
    lib.showContext('nova_practice_weapon_change')
end

-- ── Instructor ped ───────────────────────────────────────────────────────────

local function openArmoryAsHost()
    if activeSession then
        toast('🎯', 'Practice Range', 'You are already in a practice session.', true, 2500)
        return
    end
    TriggerServerEvent(NS .. ':server:createRoom')
end

-- The instructor is a permanent "world ped" (client/modules/world_peds.lua): it stands wherever an admin placed it (tablet →
-- World Peds), all the time and for everyone, tied to no event. This only says what it does and how its map blip looks.
local function registerInstructorPed()
    local b = Config.PracticeRange.pedBlip or {}
    WorldPeds.register('practice', {
        -- Map blip (radar_rampage, red) so the range can be found from anywhere.
        blip = b.enabled ~= false and { sprite = b.sprite or 84, colour = b.colour or 1, scale = b.scale or 0.9, shortRange = b.shortRange ~= false, label = b.label or 'Practice Range' } or nil,
        options = { {
            label = 'Start Practice Session',
            icon = 'fa-solid fa-crosshairs',
            onSelect = openArmoryAsHost,
        }, {
            label = 'Change Practice Weapon',
            icon = 'fa-solid fa-gun',
            canInteract = function() return activeSession ~= nil end,
            onSelect = openChangeWeaponMenu,
        }, {
            label = 'End Practice Session',
            icon = 'fa-solid fa-stop',
            canInteract = function() return activeSession ~= nil end,
            onSelect = leavePracticeSquad,
        } },
    })
end

-- Command + keybind to end a session from anywhere — walking all the way
-- back to the instructor ped just to leave was real friction once you're
-- deep in a practice zone.
RegisterCommand('endpractice', function()
    if not activeSession then
        toast('🎯', 'Practice Range', 'No practice session is active.', true, 2500)
        return
    end
    if Config.PracticeRange.endRequiresExit == false then
        leavePracticeSquad()
    else
        guideToExit()
    end
end, false)
RegisterKeyMapping('endpractice', 'Practice Range: Find Exit / End Session', 'keyboard', 'F6')

CreateThread(function()
    if not (Config.PracticeRange and Config.PracticeRange.enabled) then return end
    ensurePracticeGroups()
    registerInstructorPed()
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    -- Same invariant as TDM: a player must never be left permanently
    -- invincible (or holding an unremovable practice weapon) just because
    -- this resource restarted mid-session. Local-only — the server's own
    -- onResourceStop handler resets every routing bucket it tracked.
    localCleanup(false)
end)
