-- ─── Nova Convoy — Test run ────────────────────────────────────────────────────
-- An admin can run an event as a rehearsal: while it runs, everything this resource would tell the server goes to that admin ONLY
-- (banners, announcements, HUD updates, chat lines, blips...), nothing is posted to Discord, nothing is paid (money, items, XP,
-- cars), nothing is written to Event History / leaderboards, and no other event can start. The trucks, props and peds are still real
-- things in the world: a player standing next to them sees them, they just get no message about it.
--
-- How: this file is loaded first and replaces this resource's TriggerClientEvent. Each resource has its own Lua environment, so no
-- other resource is touched. A send to everyone (-1) becomes a send to the admin; a send to any other player is dropped.
-- The run ends with the event (a few seconds of grace so the closing banners still go to the admin only).
TestRun = { admin = nil, convoyId = nil }

local realTrigger = TriggerClientEvent
TriggerClientEvent = function(target, ...)
    local admin = TestRun.admin
    if not admin then return realTrigger(target, ...) end
    if target == -1 or target == '-1' then return realTrigger(admin, ...) end
    if tonumber(target) == admin then return realTrigger(target, ...) end
    -- anyone else: dropped
end

function TestRun.active() return TestRun.admin ~= nil end

function TestRun.begin(source, convoyId)
    TestRun.admin, TestRun.convoyId, TestRun.startedAt, TestRun.seen, TestRun.idleSince = source, convoyId, GetGameTimer(), false, nil
end

function TestRun.clear()
    TestRun.admin, TestRun.convoyId, TestRun.seen, TestRun.idleSince = nil, nil, false, nil
end

-- ends the run some seconds after its event is over (or never started: starting can fail late)
CreateThread(function()
    while true do
        Wait(2000)
        if TestRun.admin then
            local running = Runtime and Runtime.isActive and Runtime.isActive(TestRun.convoyId)
            if running then
                TestRun.seen, TestRun.idleSince = true, nil
            elseif TestRun.seen or GetGameTimer() - (TestRun.startedAt or 0) > 30000 then
                TestRun.idleSince = TestRun.idleSince or GetGameTimer()
                if GetGameTimer() - TestRun.idleSince > 10000 then TestRun.clear() end
            end
        end
    end
end)
