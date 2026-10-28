-- ─── Nova Convoy — "is any event running?" flag (server) ──────────────────────
-- The client side keeps a few watchers (convoy trucks in range, hot-cargo truck protection, squad health reporting ...)
-- that only have something to do while an event is running. They read GlobalState.novaEventsActive and sleep for seconds
-- when it is false, so an idle server costs the players' clients (and resmon) nothing. This thread only flips the flag when
-- the answer changes, and checks every few seconds with four table lookups.

local last = nil

local function anyActive()
    if Runtime and Runtime.getActive then
        for _ in ipairs(Runtime.getActive()) do return true end
    end
    if TerritoryAuction and TerritoryAuction.getActiveIds then
        for _ in ipairs(TerritoryAuction.getActiveIds()) do return true end
    end
    if TerritoryWar and TerritoryWar.hasLive and TerritoryWar.hasLive() then return true end
    return false
end

CreateThread(function()
    Wait(2000)
    while true do
        local ok, now = pcall(anyActive)
        if ok and now ~= last then
            last = now
            GlobalState.novaEventsActive = now
        end
        Wait(3000)
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then GlobalState.novaEventsActive = false end
end)