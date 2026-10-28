-- ─── Nova Convoy — System Boot ─────────────────────────────────────────────────
-- Initializes persistence, the gang provider and the convoy definition
-- registry once oxmysql is ready. The legacy single-convoy flow that used to
-- share this file (and its ox_target ped, GlobalState.ConvoyTruckCooldown
-- flow, shared/client.lua+shared.lua+server.lua) has been retired — see
-- legacy_archive/ for its last working state.

-- Without this, math.random() on the SERVER runs on Lua's default fixed
-- seed, which FiveM never randomizes on its own — every resource restart
-- starts this Lua VM's random state fresh from the exact same point, so
-- EVERY math.random() call anywhere server-side (Hot Cargo's spawn-zone
-- shuffle in doStartHotCargo, guard placement angles, reward chance rolls,
-- all of it) produces the identical sequence every single restart. That's
-- exactly "trucks spawn at the same zones every time I restart" — the
-- shuffle itself was never broken, it was just deterministic. Confirmed:
-- client/modules/minigames.lua already had this EXACT same seeding fix for
-- the client-side Lua VM ("that's the actual reason Convoy, Airdrop and Hot
-- Cargo all always got the same minigame") — this is the server-side half
-- of that same bug class, never applied there. os.time() (wall-clock
-- seconds), not GetGameTimer() (ms since THIS resource started) — the
-- latter tends to land on a similar small value on every restart since this
-- file runs at roughly the same point in the boot sequence every time,
-- which would barely improve on the original problem.
math.randomseed(os.time())

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        -- Yield 50ms so FXServer completes the resource start tick with 0ms hitch
        Wait(50)

        -- If the SQL server is down or still coming up when this resource
        -- starts (XAMPP MySQL lagging behind FXServer, a crash/restart), every
        -- query below throws or returns nothing — ConvoyManager.loadAll() then
        -- caches an EMPTY event list that stays empty until the next resource
        -- restart, which looks exactly like "all my events vanished" while
        -- the rows are still sitting in nova_convoy_definitions. Block here
        -- until the DB actually answers (up to ~2 min) instead.
        local dbReady = false
        for attempt = 1, 60 do
            local ok, res = pcall(function() return MySQL.scalar.await('SELECT 1') end)
            if ok and res == 1 then dbReady = true break end
            if attempt == 1 then print('[NovaConvoy] Waiting for the database to come up...') end
            Wait(2000)
        end
        if not dbReady then
            print('^1[NovaConvoy] Database never became reachable — events were NOT loaded. Fix the SQL server and restart this resource.^0')
        end

        DB.init()
        Wait(20)
        GangService.init()
        Wait(20)
        Scheduler.loadSettings()
        Wait(20)
        ConvoyManager.loadAll()
        Wait(20)
        pcall(SavedRoutes.seedPrebuiltTracks)
        Wait(20)
        pcall(Runtime.sweepOrphans) -- delete convoy entities a crash left in the world, BEFORE recovery respawns trucks
        Runtime.recoverAll()
        Wait(20)
        Tournament.init()
        Wait(20)
        -- Persistent territories (owners + expansion levels survive every event and every restart) and the rival
        -- challenges / wars that are still open.
        Territory.load()
        Wait(20)
        TerritoryWar.load()
        Wait(20)
        for _, src in ipairs(Bridge.GetPlayers()) do
            if Territory.canSeeWorld(src) or GangXP.GangOf(src, true, true) then
                Territory.snapshotFor(src)
            end
        end

        -- Without this, a restart leaves every ALREADY-connected officer's
        -- client with an empty start-ped list — their own client script
        -- resets too, and broadcastStartPeds() otherwise only ever fires
        -- reactively (an admin editing/scheduling a convoy, or a player
        -- freshly joining via OnPlayerLoaded) — restarting the resource
        -- itself was never one of those triggers, so the ped(s) just stayed
        -- missing until the next unrelated convoy edit happened to resync them.
        ConvoyManager.broadcastStartPeds()

        -- Optional: let players open the Convoy Status panel (used by both
        -- police and gangs) by using a physical inventory item. No-op unless
        -- an admin both enables this AND has actually added the item to
        -- their inventory's item list (see config.lua).
        if Config.StatusPanelItem and Config.StatusPanelItem.enabled and Config.StatusPanelItem.item then
            Bridge.RegisterUsableItem(Config.StatusPanelItem.item, function(source)
                TriggerClientEvent('nova_convoytruck:client:openStatusPanelFromItem', source)
            end)
        end

        -- Take over the LOCKPICK item so using it at a Hot Cargo truck / broken-down
        -- truck / loot crate runs THIS resource's minigame, not the vehicle-keys
        -- script's generic ox_lib skill check (see Runtime.useLockpickItem). Anywhere
        -- else it falls straight through to the framework's normal behaviour.
        -- A usable item has exactly one handler and the LAST registration wins, so
        -- it is registered after the framework's own scripts have had time to load,
        -- again later as a safety net, and again whenever one of them restarts.
        local function takeOverLockpickItem()
            local theft = Config.HotCargoTheft or {}
            if theft.takeOverLockpickItem == false then return end
            if Bridge.Framework ~= 'qbx' and Bridge.Framework ~= 'qbcore' then return end
            Bridge.RegisterUsableItem(theft.lockpickItem or 'lockpick', function(source)
                if Runtime.useLockpickItem(source) then return end
                -- Not at one of our trucks/crates: do exactly what the framework does.
                TriggerClientEvent('lockpicks:UseLockpick', source, false)
                TriggerEvent('lockpicks:UseLockpick', source, false)
            end)
        end
        SetTimeout(3000, takeOverLockpickItem)
        SetTimeout(20000, takeOverLockpickItem)
        AddEventHandler('onResourceStart', function(res)
            if res == 'qbx_smallresources' or res == 'qb-smallresources' or res == 'qbx_core' or res == 'qb-core' or res == 'qbx_vehiclekeys' then
                SetTimeout(2000, takeOverLockpickItem)
            end
        end)

        print('[NovaConvoy] Operations Hub ready (' .. (Bridge.Framework or 'no framework detected') .. ').')

        -- A restart resets every client's local role cache too — resync every
        -- already-connected player so staff-only map blips come back without
        -- waiting for an unrelated trigger.
        for _, src in ipairs(Bridge.GetPlayers()) do
            TriggerClientEvent('nova_convoytruck:client:roleSync', src, ConvoyManager.rolesFor(src))
        end
    end)
end)

-- Tells each player their own police/admin status as soon as they finish
-- loading, so purely cosmetic staff-only client things (the shop/trigger ped
-- map blips) draw on the very first open instead of only after an unrelated
-- convoy edit happens to resync them.
Bridge.OnPlayerLoaded(function(source)
    TriggerClientEvent('nova_convoytruck:client:roleSync', source, ConvoyManager.rolesFor(source))
end)