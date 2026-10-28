-- ─── Nova Convoy — Native Skill Minigames (Client) ──────────────────────────
-- 20-game built-in minigame suite. Completely self-contained under Dinesh
-- as per fxmanifest.lua — no other resource's minigame UI is
-- ever called (see PlayMinigame below).

NovaConvoy = NovaConvoy or {}

-- Without this, math.random() below runs on Lua's default fixed seed, which
-- FiveM never randomizes on its own — every client's Lua state starts fresh
-- on join/resource-restart, so pool[math.random(#pool)] picked the exact
-- same index every single time. That's the actual reason Convoy, Airdrop and
-- Hot Cargo all "always got the same minigame" — they all funnel through
-- this one function. GetGameTimer() varies per client/session, unlike
-- os.time() which several players joining in the same second would share.
math.randomseed(GetGameTimer())

local activePromise = nil
local isMinigameOpen = false

-- 'lockpick' (a MINIGAME_POOLS key) and the individual game named 'lockpick'
-- below are different namespaces — a pool groups game names, it doesn't
-- collide with one.
--
-- Resolution always happens client-side, independently per player (see
-- PlayMinigame's math.random below) — two gang members hitting the same
-- crate at the same moment can land on two different games, and the pool
-- is deliberately wide so the same game doesn't keep repeating for players
-- grinding the same event type over and over.
local ALL_GAMES = {
    'lugnuts', 'skillcheck', 'quicktime', 'hotwire', 'reaction',
    'keypad', 'livewire', 'lockpick', 'mash', 'targets', 'lightsout',
    'stacker', 'slidepuzzle', 'vaultspin', 'pulse', 'breachmatrix',
    'cascade', 'tripwire', 'constellation', 'fingerprint',
    -- Extended pack (original 9)
    'thermite', 'lasergrid', 'forge', 'archery', 'parry',
    'cuttheright', 'decrypt', 'vaultdrill', 'pickpocket',
    -- Additional games from D:\html (41 new games, 70 total)
    'animus', 'beltsort', 'bluff', 'bonepin', 'breathalyzer', 'cashcount',
    'chopshop', 'cooking', 'counterfeit', 'crafting', 'crane', 'daemonrun',
    'dataheist', 'deadcalm', 'diving', 'drilling', 'eaglevision', 'fishing',
    'flatline', 'gaslight', 'getaway', 'ghostsignal', 'harvest', 'hottrace',
    'intrusion', 'jammer', 'locksmith', 'mining', 'overflow', 'override',
    'packing', 'paintspray', 'partsort', 'pillpress', 'resonance', 'steadydose',
    'suture', 'titration', 'toolbox', 'vitals', 'welding',
}
local MINIGAME_POOLS = {
    lockpick = { 'skillcheck', 'quicktime', 'hotwire', 'lockpick', 'keypad', 'vaultspin', 'fingerprint', 'vaultdrill', 'forge', 'cuttheright', 'locksmith', 'bonepin', 'crane', 'drilling' },
    hack = { 'hotwire', 'quicktime', 'skillcheck', 'livewire', 'keypad', 'breachmatrix', 'pulse', 'cascade', 'decrypt', 'lasergrid', 'thermite', 'daemonrun', 'dataheist', 'ghostsignal', 'hottrace', 'intrusion', 'jammer', 'overflow', 'override' },
    all = ALL_GAMES,
}
NovaConvoy.MINIGAME_POOLS = MINIGAME_POOLS

-- Last few games actually played (any pool), most-recent first — reported
-- as "even with 20+ minigames, only the same few keep appearing" across
-- several airdrops looted back-to-back. A single math.random(#pool) pick
-- is honestly random, which means real repeats ARE expected some of the
-- time (with even a wide pool, back-to-back-to-back draws collide more
-- often than intuition expects) — but "expected sometimes" still reads as
-- "broken" to a player grinding several drops in a row. This makes an
-- immediate repeat of the last couple of games actually impossible, not
-- just less likely, on top of the wider 'all' pool now used for airdrops.
local recentGames = {}

-- Config.Minigames (all optional): how many of the last games to never repeat.
local function avoidCount()
    local n = tonumber((Config.Minigames or {}).avoidRepeats)
    return n and math.max(0, math.floor(n)) or 2
end

local function pickGame(pool)
    local avoid = avoidCount()
    if #pool <= avoid + 1 then
        return pool[math.random(#pool)]
    end
    local pick
    for _ = 1, 20 do
        pick = pool[math.random(#pool)]
        local recently = false
        for _, g in ipairs(recentGames) do
            if g == pick then recently = true break end
        end
        if not recently then break end
    end
    table.insert(recentGames, 1, pick)
    while #recentGames > avoid do
        table.remove(recentGames)
    end
    return pick
end

-- Which games may be drawn for this call. Config.Minigames.mode decides:
--   'all'    (default) every game in the suite, whatever the event asked for
--   'themed' honour the event's pool name ('lockpick' / 'hack')
-- An explicit table pool passed by a caller is always respected. Games listed in
-- Config.Minigames.disabled are removed either way (and never emptied out).
local function resolvePool(requested)
    local cfg = Config.Minigames or {}
    local pool = MINIGAME_POOLS.all
    if type(requested) == 'table' and #requested > 0 then
        pool = requested
    elseif type(requested) == 'string' and MINIGAME_POOLS[requested] and cfg.mode == 'themed' then
        pool = MINIGAME_POOLS[requested]
    end
    local off = {}
    for _, g in ipairs(cfg.disabled or {}) do off[g] = true end
    if next(off) then
        local filtered = {}
        for _, g in ipairs(pool) do
            if not off[g] then filtered[#filtered + 1] = g end
        end
        if #filtered > 0 then pool = filtered end
    end
    return pool
end

--- Runs a native minigame synchronously and returns true if succeeded, false if failed/cancelled.
--- @param gameType string|nil 'random' | 'lugnuts' | 'skillcheck' | 'quicktime' | 'hotwire' | 'reaction'
--- @param options table|nil { difficulty = 1|2|3, title = string, duration = number, pool = table|string }
--- @return boolean success
function NovaConvoy.PlayMinigame(gameType, options)
    options = options or {}
    local diff = 2
    if options.difficulty then
        if type(options.difficulty) == 'number' then
            diff = math.max(1, math.min(5, math.floor(options.difficulty)))
        elseif type(options.difficulty) == 'table' then
            -- Support ox_lib style array: { 'easy', 'medium', 'hard' }
            diff = #options.difficulty >= 3 and 3 or (#options.difficulty == 2 and 2 or 1)
        elseif type(options.difficulty) == 'string' then
            local lower = options.difficulty:lower()
            diff = (lower == 'hard' and 3) or (lower == 'easy' and 1) or 2
        end
    end

    local pool = resolvePool(options.pool)

    -- A specific game named by the caller (e.g. Config.Airdrop.minigame = 'keypad') or
    -- forced for debugging wins; otherwise every attempt draws one at random.
    local chosenGame = (not options.ignoreForce and (Config.Minigames or {}).force) or gameType
    if not chosenGame or chosenGame == 'random' then
        chosenGame = pickGame(pool)
    end

    if isMinigameOpen and activePromise then
        activePromise:resolve(false)
        activePromise = nil
    end

    isMinigameOpen = true
    activePromise = promise.new()

    SetNuiFocus(true, true)
    -- The HUD cursor toggle (runtime_client.lua, setHudCursor) switches
    -- keep-input ON, which sends every key to the GAME instead of the NUI
    -- page. A minigame needs the keyboard itself, so make sure it's off.
    SetNuiFocusKeepInput(false)
    local duration = options.duration or (math.max(12, 22 - diff * 2))
    -- Temporary diagnostic: a report of "NUI focus grabs (screen blurs,
    -- player frozen) but no overlay ever appears" needs proof of which side
    -- of the bridge actually failed. This print always fires right before
    -- the message is sent — if it's missing from F8 entirely, this function
    -- was never reached at all; if it's present but the matching
    -- '[minigame] start received' from App.svelte's console never shows,
    -- the message didn't reach (or wasn't handled by) the NUI page; if BOTH
    -- show but no overlay appears, the bug is inside MinigameOverlay's own
    -- render path specifically.
    print(('[NovaConvoy] PlayMinigame: sending minigame:start (game=%s difficulty=%s duration=%s)'):format(tostring(chosenGame), tostring(diff), tostring(duration)))
    SendNUIMessage({
        action = 'minigame:start',
        game = chosenGame,
        difficulty = diff,
        title = options.title or 'SECURITY CHALLENGE',
        duration = duration,
    })

    -- Safety net: if the NUI page never renders the overlay for any reason
    -- (a JS exception before it wires up, a dropped SendNUIMessage, a
    -- resource restart racing the callback) there was previously NO way back
    -- — Citizen.Await(activePromise) would hang forever with NUI focus still
    -- captured, which is exactly "the minigame doesn't appear and my screen
    -- froze" with no way to recover short of reconnecting. This force-fails
    -- and releases focus a few seconds past the minigame's own on-screen
    -- timer, which would otherwise have auto-failed it itself.
    local myPromise = activePromise

    -- Focus guard: another script/resource (or a stray SetNuiFocus(false)
    -- elsewhere) can take NUI focus away mid-game, after which neither mouse
    -- nor keyboard reaches the overlay. Re-assert it while this game is open.
    CreateThread(function()
        while isMinigameOpen and activePromise == myPromise do
            Wait(250)
            if isMinigameOpen and activePromise == myPromise and not IsNuiFocused() then
                SetNuiFocus(true, true)
                SetNuiFocusKeepInput(false)
            end
        end
    end)

    local timeoutMs = (duration * 1000) + 8000
    CreateThread(function()
        Wait(timeoutMs)
        if activePromise == myPromise and isMinigameOpen then
            print('[NovaConvoy] Minigame watchdog: overlay never resolved — force-releasing NUI focus.')
            SendNUIMessage({ action = 'minigame:close' })
            isMinigameOpen = false
            SetNuiFocus(false, false)
            activePromise = nil
            myPromise:resolve(false)
        end
    end)

    local result = Citizen.Await(myPromise)
    isMinigameOpen = false
    SetNuiFocus(false, false)
    return result == true
end

-- Manual bail-out: lets a player recover from a stuck minigame themselves
-- (matching the watchdog above) instead of having to wait it out or
-- reconnect. Backspace since that's already this project's convention for
-- "cancel/undo" during other in-world recording flows (route_recorder.lua,
-- zone_recorder.lua).
RegisterCommand('convoy_minigame_cancel', function()
    if isMinigameOpen and activePromise then
        local p = activePromise
        activePromise = nil
        isMinigameOpen = false
        SendNUIMessage({ action = 'minigame:close' })
        SetNuiFocus(false, false)
        p:resolve(false)
    end
end, false)
RegisterKeyMapping('convoy_minigame_cancel', 'Cancel Stuck Minigame (Emergency)', 'keyboard', 'BACK')

-- Sent by the overlay's input probe when a game has been on screen for 8s
-- without a single mouse press or key press reaching it.
RegisterNUICallback('nova_convoytruck:minigame:noInput', function(data, cb)
    cb({ ok = true })
    print(('^1[NovaConvoy] Minigame "%s": NO input reached the overlay. IsNuiFocused=%s (should be true)^0'):format(
        tostring(data and data.game), tostring(IsNuiFocused())))
end)

-- /minigametest            -> lists every game
-- /minigametest <game>     -> plays just that one
-- /minigametest all        -> plays every game in turn and prints PASS/FAIL
-- Use it to check, game by game, that mouse and keyboard work. Watch F8 for
-- "[minigame] input OK" (or the NO input warning). Nothing is rewarded.
RegisterCommand('minigametest', function(_, args)
    local arg = args[1] and args[1]:lower() or nil
    if not arg then
        print('[NovaConvoy] /minigametest <game|all>. Games: ' .. table.concat(ALL_GAMES, ', '))
        return
    end
    local list = {}
    if arg == 'all' then
        for _, g in ipairs(ALL_GAMES) do list[#list + 1] = g end
    else
        local found = false
        for _, g in ipairs(ALL_GAMES) do if g == arg then found = true break end end
        if not found then
            print(('[NovaConvoy] Unknown game "%s". Games: %s'):format(arg, table.concat(ALL_GAMES, ', ')))
            return
        end
        list[1] = arg
    end
    CreateThread(function()
        for i, g in ipairs(list) do
            local ok = NovaConvoy.PlayMinigame(g, { title = ('TEST %d/%d: %s'):format(i, #list, g:upper()), difficulty = 1, ignoreForce = true })
            print(('[NovaConvoy] minigametest %-14s %s'):format(g, ok and 'PASS' or 'FAIL/cancelled'))
            Wait(700)
        end
        print('[NovaConvoy] minigametest finished.')
    end)
end, false)

-- Export for internal or external resource calls
exports('PlayMinigame', function(gameType, options)
    return NovaConvoy.PlayMinigame(gameType, options)
end)

-- NUI Finish Callback
RegisterNUICallback('nova_convoytruck:minigame:finish', function(data, cb)
    SetNuiFocus(false, false)
    isMinigameOpen = false
    cb({ ok = true })

    if activePromise then
        local p = activePromise
        activePromise = nil
        p:resolve(data and data.success == true)
    end
end)

-- Clean up on resource stop
AddEventHandler('onResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    if isMinigameOpen then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'minigame:close' })
        if activePromise then
            activePromise:resolve(false)
            activePromise = nil
        end
    end
end)
