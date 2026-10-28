-- ─── Nova Convoy — Shared auction bidding core ─────────────────────────────────
-- Server-only. The ONE bidding engine of this resource. Container Wars (container_wars_runtime.lua) and the Gang
-- Territory Auction (territory_auction.lua) both auction a "lot" and both run their bids through here, so the rules —
-- versioned bids, minimum increment, funds check, anti-snipe, per-player rate limit, one bid at a time per lot — exist
-- exactly once.
--
-- A lot is a plain table with the fields a bid reads and writes:
--   status ('AUCTION_ACTIVE' while open) · timeRemaining · currentBid · minBidIncrement · version · bidCount
--   highestBidder (identifier) · highestBidderSource · highestBidderName · highestBidderGang (label) · highestBidderGangName
--
-- The server is the only authority. A bid is one transaction: every condition is checked and the state changed in a
-- single block with no yield in between, so two bids that arrive in the same millisecond are strictly ordered — the
-- second one sees the first one's result and is rejected.

AuctionCore = {}

function AuctionCore.minimumNext(c)
    return (c.currentBid or 0) + (c.minBidIncrement or 1000)
end

function AuctionCore.bidOpen(c)
    return c.status == 'AUCTION_ACTIVE' and (c.timeRemaining or 0) > 0
end

-- bid: { amount, version, identifier, source, name, gang = { name, label } }
-- opts: { staleMessage, snipeEnabled, snipeWindow, snipeExtend }
-- Returns true | false, code, message   (codes: ENDED STALE INVALID MIN FUNDS)
-- The caller has ALREADY decided that this player may bid for this gang (event access / eligibility rules differ).
function AuctionCore.apply(c, bid, opts)
    opts = opts or {}
    local stale = opts.staleMessage or 'Bid is no longer valid. Current bid has changed.'

    if not AuctionCore.bidOpen(c) then return false, 'ENDED', 'This auction is no longer taking bids.' end

    -- Stale: someone else's bid (or the closing bell) changed the auction after this client last saw it.
    if tonumber(bid.version) ~= c.version then return false, 'STALE', stale end

    local amount = tonumber(bid.amount)
    if not amount or amount ~= amount or amount <= 0 or amount > 2000000000 then
        return false, 'INVALID', 'Enter a valid bid amount.'
    end
    amount = math.floor(amount)

    -- Equal or lower than what is already standing: the same "someone beat you to it" case.
    if amount <= (c.currentBid or 0) then return false, 'STALE', stale end

    local minRequired = AuctionCore.minimumNext(c)
    if amount < minRequired then
        return false, 'MIN', ('Minimum bid is $%s.'):format(string.format('%d', minRequired))
    end

    if bid.source and (Bridge.GetMoney(bid.source, 'bank') + Bridge.GetMoney(bid.source, 'cash')) < amount then
        return false, 'FUNDS', 'You do not have enough funds to place this bid.'
    end

    -- Accept: gang-aware — any member of an eligible gang may raise the bid, the leading gang stays the same while the
    -- leading bidder changes.
    c.currentBid = amount
    c.highestBidder = bid.identifier
    c.highestBidderSource = bid.source
    c.highestBidderName = bid.name
    c.highestBidderGang = bid.gang and (bid.gang.label or bid.gang.name) or nil
    c.highestBidderGangName = bid.gang and bid.gang.name or nil
    c.version = (c.version or 0) + 1
    c.bidCount = (c.bidCount or 0) + 1

    -- Anti-snipe: a valid bid in the last seconds adds time ("N seconds or less remaining" — inclusive)
    local extend = tonumber(opts.snipeExtend) or 0
    if opts.snipeEnabled == false then extend = 0 end
    if extend > 0 and c.timeRemaining <= (tonumber(opts.snipeWindow) or 0) then
        c.timeRemaining = c.timeRemaining + extend
    end
    return true
end

-- Wraps one bid request: per-player rate limit, one bid at a time per lot, and a pcall so an error can never leave the
-- lot locked. `fn` performs the bid and returns what AuctionCore.apply returns. Returns ok, code, message.
function AuctionCore.guard(c, src, minGapMs, staleMessage, fn)
    -- Per player, per lot: drop machine-gun requests (a different player is never affected).
    local now = GetGameTimer()
    c.lastBidAt = c.lastBidAt or {}
    local last = c.lastBidAt[src]
    c.lastBidAt[src] = now
    if last and (now - last) < (tonumber(minGapMs) or 300) then
        return false, 'RATE', 'Too many bid requests. Please wait a moment.'
    end

    if c.bidBusy then
        -- another bid is being applied right now; by the time it lands this one is stale
        return false, 'STALE', staleMessage or 'Bid is no longer valid. Current bid has changed.'
    end
    c.bidBusy = true
    local called, ok, code, msg = pcall(fn)
    c.bidBusy = false
    if not called then
        print(('[nova_convoytruck] auction bid error: %s'):format(tostring(ok)))
        return false, 'ERROR', 'Bid failed. Please try again.'
    end
    return ok, code, msg
end

return AuctionCore
