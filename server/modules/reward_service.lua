-- ─── Nova Convoy — Reward Hooks ───────────────────────────────────────────────
-- Handles reward distributions (cash and items) for police and gang participants.

RewardService = {}

local function log(kind, payload)
    print(('[NovaConvoy][Reward] %s: %s'):format(kind, json.encode(payload)))
end

-- Names the actual recipients for the Discord embed — "who got what" needs
-- real player names, not just a list of server ids. Recipients have always
-- already disconnected-checked themselves in by the time they reach here
-- (findSourceByIdentifier / online-only filtering happens in convoy_runtime.lua),
-- so every source here is expected to still be a valid online player.
local function recipientNames(recipients)
    local names = {}
    for _, source in ipairs(recipients or {}) do
        names[#names + 1] = Bridge.GetPlayerName(source) or ('#' .. tostring(source))
    end
    return #names > 0 and table.concat(names, ', ') or 'nobody (no online recipients)'
end

local function rewardLine(reward)
    local rawType = string.upper(tostring(reward.type or reward.rewardType or reward.kind or ''))
    local rawAmount = tonumber(reward.amount or reward.count or reward.quantity or reward.value) or 1
    local rawItem = reward.item or reward.pool or reward.name or reward.itemName or reward.weapon or 'item'
    if rawType == 'MONEY' or rawType == 'CASH' or rawType == 'BANK' or rawType == 'BLACK_MONEY' then
        return ('$%s'):format(rawAmount)
    end
    if rawType == 'ITEM' or rawType == 'ITEMS' or rawType == 'WEAPON' then
        return ('%sx %s'):format(rawAmount, rawItem)
    end
    if rawType == 'TOKENS' or rawType == 'TOKEN' then
        return ('%d Tokens'):format(math.floor(rawAmount))
    end
    if rawType == 'GANG_XP' then
        return ('%d Gang XP'):format(math.floor(rawAmount))
    end
    if rawType == 'VEHICLE' then
        return ('%dx vehicle %s'):format(math.max(1, math.floor(rawAmount)), tostring(reward.pool ~= '' and reward.pool or reward.model or 'car'))
    end
    return tostring(rawType ~= '' and rawType or 'Reward')
end

-- Exported so other modules (e.g. convoy_runtime.lua's own "Convoy Captured"
-- embed) can name the exact same reward list in their own log without
-- duplicating this formatting.
function RewardService.describeRewards(rewards)
    if not rewards or #rewards == 0 then return 'None' end
    local lines = {}
    for _, r in ipairs(rewards) do lines[#lines + 1] = rewardLine(r) end
    return table.concat(lines, ', ')
end

-- kind: GiveConvoyReward / GrantGangReward / GiveAirdropReward. When
-- provenance.convoyId is set, this folds into that convoy run's own single
-- running Discord message (see discord_log.lua's appendEvent) as one more
-- timeline line instead of posting a separate message — every reward payout
-- during a run shows up in the same place as everything else that happened
-- in it. Only falls back to a standalone message if there's no convoy run
-- to attach to.
local function logToDiscord(kind, rewards, recipients, provenance)
    if not rewards or #rewards == 0 then return end
    local gangPart = (provenance and provenance.gangLabel) and (' (%s)'):format(provenance.gangLabel) or ''
    local line = ('🎁 %s%s — %s → %s'):format(kind, gangPart, RewardService.describeRewards(rewards), recipientNames(recipients))
    if provenance and provenance.convoyId then
        DiscordLog.appendEvent(provenance.convoyId, line)
        return
    end
    local fields = {
        { name = 'Convoy', value = (provenance and provenance.convoyName) or 'Unknown', inline = true },
        { name = 'Reward', value = RewardService.describeRewards(rewards), inline = true },
        { name = 'Recipients', value = recipientNames(recipients), inline = false },
    }
    if provenance and provenance.gangLabel then
        table.insert(fields, 2, { name = 'Gang', value = provenance.gangLabel, inline = true })
    end
    DiscordLog.send(('Reward Paid — %s'):format(kind), nil, 0xf59e0b, fields)
end

local function payMoney(recipients, amount, account)
    for _, source in ipairs(recipients or {}) do
        if not Bridge.AddMoney(source, amount, account) then
            print(('[NovaConvoy][Reward] Could not pay $%s (%s) to player %s — no framework, or the account is unavailable.'):format(tostring(amount), tostring(account), tostring(source)))
        end
    end
end

-- ── Vehicle rewards ───────────────────────────────────────────────────────────
-- reward: { model, pool (display name), mode = 'GARAGE' | 'SPAWN' }. GARAGE puts the car in the player's garage (they
-- own it); SPAWN (and the fallback when a garage entry cannot be made) puts it in the world at `spawn`
-- ({ x, y, z, heading }, e.g. beside the container) or next to the player, with the keys. Returns ok, info.
local function cleanModel(model)
    return (tostring(model or ''):gsub('[^%w_%-]', ''):sub(1, 50))
end

-- Every reward car that was put in the WORLD (SPAWN mode, or the fallback when a garage entry could not be made) is
-- remembered here, so an admin can hand its ownership to the player who really won it (/carowner). Memory only: the
-- cars themselves do not survive a restart either.
RewardService.SpawnedCars = {}
local nextSpawnedCarId = 0

function RewardService.GiveVehicle(source, reward, spawn, provenance)
    if TestRun and TestRun.admin then return false, 'test run' end
    local model = cleanModel(reward.model)
    if model == '' then
        print('[NovaConvoy][Reward] VEHICLE reward has no model set — nothing paid out.')
        return false, 'no model'
    end
    local label = (reward.pool and reward.pool ~= '' and reward.pool) or model
    local vcfg = Config.VehicleRewards or {}
    local mode = reward.mode
    if mode ~= 'GARAGE' and mode ~= 'SPAWN' then mode = (vcfg.defaultMode == 'SPAWN') and 'SPAWN' or 'GARAGE' end

    if mode == 'GARAGE' then
        -- provenance.ownerCitizenid: the car belongs to this player (the auction's winning bidder) whoever receives the payout
        local ownerId = provenance and provenance.ownerCitizenid
        local ok, plateOrErr = Bridge.AddOwnedVehicle(source, model, { citizenid = ownerId })
        if ok then
            local mine = not ownerId or ownerId == Bridge.GetIdentifier(source)
            local text = mine and '%s was added to your garage (%s). Plate: %s' or '%s was added to the winning bidder garage (%s). Plate: %s'
            TriggerClientEvent('nova_convoytruck:client:hudNotify', source, { type = 'success', title = 'Vehicle reward', description = text:format(label, vcfg.garage or 'garage', plateOrErr) })
            return true, { mode = 'GARAGE', plate = plateOrErr }
        end
        print(('[NovaConvoy][Reward] Could not add "%s" to a garage (%s) — spawning it instead.'):format(model, tostring(plateOrErr)))
    end

    local x, y, z, heading
    if spawn and tonumber(spawn.x) and tonumber(spawn.y) then
        x, y, z, heading = spawn.x + 0.0, spawn.y + 0.0, (tonumber(spawn.z) or 0.0) + 0.0, tonumber(spawn.heading) or 0.0
    else
        local ped = GetPlayerPed(source)
        if not ped or ped == 0 then return false, 'player not found' end
        local c = GetEntityCoords(ped)
        local h = GetEntityHeading(ped)
        local rad = math.rad(h + 90.0)
        x, y, z, heading = c.x + math.cos(rad) * 4.0, c.y + math.sin(rad) * 4.0, c.z, h
    end
    local veh = CreateVehicle(joaat(model), x, y, z, heading, true, true)
    local deadline = GetGameTimer() + 3000
    while (not veh or veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < deadline do Wait(50) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        print(('[NovaConvoy][Reward] Vehicle model "%s" could not be created — check the model name (and that an addon car is streamed).'):format(model))
        TriggerClientEvent('nova_convoytruck:client:hudNotify', source, { type = 'error', title = 'Vehicle reward', description = ('The reward vehicle (%s) could not be created. Tell an admin.'):format(label) })
        return false, 'spawn failed'
    end
    local plate = Bridge.NewPlate()
    SetVehicleNumberPlateText(veh, plate)
    Bridge.GiveVehicleKeys(source, veh)
    TriggerClientEvent('nova_convoytruck:client:hudNotify', source, { type = 'success', title = 'Vehicle reward', description = ('%s is waiting for you. Plate: %s'):format(label, plate) })

    nextSpawnedCarId = nextSpawnedCarId + 1
    local def = provenance and provenance.convoyId and ConvoyManager and ConvoyManager.get and ConvoyManager.get(provenance.convoyId) or nil
    RewardService.SpawnedCars[#RewardService.SpawnedCars + 1] = {
        id = nextSpawnedCarId,
        entity = veh,
        model = model,
        label = label,
        plate = plate,
        convoyId = provenance and provenance.convoyId or nil,
        kind = def and def.kind or nil,
        eventName = (provenance and provenance.convoyName) or (def and def.name) or 'Unknown event',
        containerName = provenance and provenance.containerName or nil,
        winningBidder = provenance and provenance.winningBidder or nil,
        keyHolder = source,                                  -- who got the keys when it spawned
        keyHolderName = Bridge.GetCharacterName(source) or Bridge.GetPlayerName(source),
        at = os.time(),
        ownerSource = nil, ownerName = nil,                  -- set once an admin has handed it over
    }
    return true, { mode = 'SPAWN', plate = plate, entity = veh }
end

function RewardService.RegisterSpawnedCar(entry)
    nextSpawnedCarId = nextSpawnedCarId + 1
    entry.id = nextSpawnedCarId
    entry.at = os.time()
    RewardService.SpawnedCars[#RewardService.SpawnedCars + 1] = entry
    return entry.id
end

-- ── /carowner: handing a spawned reward car to the player who won it ───────────
-- The car is already standing in the world with its own plate. Ownership is a garage record for that same plate, saved
-- as "out" (it is not in any garage, so it cannot be pulled out a second time); the world car is tagged with the record
-- so the key script and the garage recognise it as the owner's. The winner can then lock / unlock it with their keys
-- and store it in any garage.

-- The cars an admin can choose from: Container Wars reward cars that still exist, newest first.
function RewardService.ListSpawnedCars()
    local out = {}
    for i = #RewardService.SpawnedCars, 1, -1 do
        local c = RewardService.SpawnedCars[i]
        if not (c.entity and DoesEntityExist(c.entity)) then
            table.remove(RewardService.SpawnedCars, i)   -- the car is gone (despawned, destroyed, restart): forget it
        elseif c.kind == 'CONTAINER_WARS' then
            out[#out + 1] = {
                id = c.id, model = c.model, label = c.label, plate = c.plate,
                eventName = c.eventName, containerName = c.containerName,
                winningBidder = c.winningBidder, keyHolderName = c.keyHolderName,
                ownerName = c.ownerName, at = c.at,
            }
        end
    end
    return out
end

-- Returns ok, message (shown to the admin).
function RewardService.TransferSpawnedCar(adminSource, carId, targetSource)
    local entry
    for _, c in ipairs(RewardService.SpawnedCars) do
        if c.id == tonumber(carId) then entry = c break end
    end
    if not entry then return false, 'That car is no longer in the list.' end
    if not (entry.entity and DoesEntityExist(entry.entity)) then return false, 'That car no longer exists in the world.' end
    if entry.ownerSource then return false, ('Already handed to %s.'):format(entry.ownerName or 'a player') end

    targetSource = tonumber(targetSource)
    if not targetSource or not GetPlayerName(targetSource) then return false, 'No player with that server ID is online.' end
    if not Bridge.GetIdentifier(targetSource) then return false, 'That player has no active character yet.' end

    local ok, plateOrErr, vehicleId = Bridge.AddOwnedVehicle(targetSource, entry.model, { plate = entry.plate, out = true })
    if not ok then return false, ('Could not record the ownership: %s'):format(tostring(plateOrErr)) end

    -- the world car belongs to the record now (qbx: the key script and the garages look the owner up from this)
    if vehicleId then Entity(entry.entity).state:set('vehicleid', vehicleId, true) end

    -- keys to the new owner; the player who got them when the car spawned loses them
    Bridge.GiveVehicleKeys(targetSource, entry.entity)
    if entry.keyHolder and entry.keyHolder ~= targetSource and GetPlayerName(entry.keyHolder) then
        Bridge.RemoveVehicleKeys(entry.keyHolder, entry.entity)
    end

    entry.ownerSource = targetSource
    entry.ownerName = Bridge.GetCharacterName(targetSource) or Bridge.GetPlayerName(targetSource)

    TriggerClientEvent('nova_convoytruck:client:hudNotify', targetSource, {
        type = 'success', title = 'This car is yours', duration = 12000,
        description = ('The %s (plate %s) belongs to you. Use your keys to lock or unlock it, and you can store it in a garage.'):format(entry.label, plateOrErr),
    })
    print(('[NovaConvoy][CarOwner] %s handed %s (plate %s) from "%s" to %s (id %d)'):format(
        Bridge.GetPlayerName(adminSource) or tostring(adminSource), entry.model, tostring(plateOrErr), entry.eventName, entry.ownerName or '?', targetSource))
    if DiscordLog and DiscordLog.appendEvent and entry.convoyId then
        DiscordLog.appendEvent(entry.convoyId, ('🚗 %s (%s) was handed to %s by admin %s'):format(entry.label, tostring(plateOrErr), entry.ownerName or '?', Bridge.GetPlayerName(adminSource) or '?'))
    end
    return true, ('%s (%s) now belongs to %s.'):format(entry.label, tostring(plateOrErr), entry.ownerName or ('player ' .. targetSource))
end

-- provenance (optional): { convoyId, convoyName, gangName, gangLabel,
-- lootedBy, lootedByName } — stamped onto the item's own metadata (ox/qb/qs
-- inventory all accept arbitrary metadata; a bridge that doesn't support it
-- just ignores the extra argument, no crash). This is what actually survives
-- a trade or a kill-and-loot afterward: the item itself carries who it was
-- originally paid out to, checkable any time via your inventory's own
-- admin item inspector, even if it's since changed hands. It is NOT a live
-- "who currently holds item X" search across the server — that would need
-- inventory-specific lookups this bridge doesn't expose, and isn't
-- guaranteed to exist the same way across ox/qb/qs/ps inventory.
local function payItem(recipients, itemName, count, provenance)
    if not itemName or itemName == '' then
        print('[NovaConvoy][Reward] ITEM reward has no item name set — nothing paid out.')
        return true   -- nothing to deliver, so nothing to keep for a retry
    end
    if Inventory.ItemExists and not Inventory.ItemExists(itemName) then
        print(('[NovaConvoy][Reward] Note: item "%s" not found in inventory index (%s) — attempting to add directly.'):format(itemName, tostring(Inventory.Kind)))
    end
    local metadata = provenance and {
        description = provenance.gangLabel and ('Looted by %s (%s)'):format(provenance.lootedByName or '?', provenance.gangLabel) or nil,
        novaConvoyOrigin = provenance,
    } or nil
    local failed = false
    for _, source in ipairs(recipients or {}) do
        local ok, reason = Inventory.AddItem(source, itemName, count or 1, metadata)
        if not ok then
            local player = Bridge.GetPlayer(source)
            if player and player.Functions and player.Functions.AddItem then
                local okFw, res = pcall(function() return player.Functions.AddItem(itemName, count or 1, nil, metadata) end)
                ok = okFw and res ~= false
            elseif player and player.addInventoryItem then
                ok = pcall(function() player.addInventoryItem(itemName, count or 1) end)
            end
        end
        if not ok then
            -- never silent: the player was told the reward was paid, so say it did not fit, and keep the reason in the console
            -- an item the inventory does not know can never be delivered, so it is not kept for another try
            local unknown = reason == 'invalid_item'
            if not unknown then failed = true end
            print(('[NovaConvoy][Reward] Could not give %dx "%s" to player %s: %s'):format(count or 1, itemName, tostring(source), tostring(reason or 'the inventory refused it')))
            TriggerClientEvent('nova_convoytruck:client:hudNotify', source, {
                type = 'error', duration = 9000, title = unknown and 'REWARD ITEM MISSING' or 'INVENTORY FULL',
                description = unknown and ('The reward item "%s" does not exist on this server. Tell an admin.'):format(tostring(itemName))
                    or ('%dx %s did not fit in your inventory. Make room and collect it again.'):format(count or 1, tostring(itemName)),
            })
        end
    end
    return not failed
end

-- ── Payout ledger ─────────────────────────────────────────────────────────────
-- Every payout (money, items, tokens, vehicles, Gang XP) is also written here, per player, under the event it belongs to. The
-- Discord end-of-event message and the PDF / Event History report read it back (ReportBuilder.payoutTable / payoutField), so
-- they show what was ACTUALLY paid — to whom, and how much Gang XP each gang earned — instead of the configured maximum.
-- entry: { kind (what it was for), player, identifier, gang (label), text (reward), xp, at }
RewardService.Ledger = {}

function RewardService.ClearPayouts(convoyId)
    if convoyId ~= nil then RewardService.Ledger[convoyId] = nil end
end

function RewardService.RecordPayout(convoyId, entry)
    if convoyId == nil or type(entry) ~= 'table' then return end
    local list = RewardService.Ledger[convoyId]
    if not list then list = {}; RewardService.Ledger[convoyId] = list end
    entry.at = entry.at or os.time()
    list[#list + 1] = entry
end

-- Raw entries for one event (a copy of the list; the entries themselves are shared).
function RewardService.GetPayouts(convoyId)
    local out = {}
    for i, e in ipairs(RewardService.Ledger[convoyId] or {}) do out[i] = e end
    return out
end

local KIND_LABELS = {
    GiveConvoyReward = 'Convoy delivered', GrantGangReward = 'Gang reward', GiveRaceReward = 'Race finish',
    GiveAirdropReward = 'Airdrop claimed', HotCargoDelivered = 'Hot Cargo delivered',
}
local function kindLabel(kind, provenance)
    if provenance and provenance.payoutLabel then return provenance.payoutLabel end
    if KIND_LABELS[kind] then return KIND_LABELS[kind] end
    local s = tostring(kind or 'Payout'):gsub('(%l)(%u)', '%1 %2')
    return s
end

-- Who a source is, for the ledger: name, identifier, gang label ('Police' / 'Civilian' when they have none).
local function ledgerIdentity(src)
    local name = (Bridge.GetCharacterName and Bridge.GetCharacterName(src)) or Bridge.GetPlayerName(src) or ('#' .. tostring(src))
    local ident = Bridge.GetIdentifier(src) or 'N/A'
    local gang
    local g = GangXP and GangXP.GangOf and GangXP.GangOf(src, true)
    if g then gang = g.label
    elseif Bridge.IsPolice and Bridge.IsPolice(src) then gang = 'Police'
    else gang = 'Civilian' end
    return name, ident, gang
end

-- ── Reward announcements ──────────────────────────────────────────────────────
-- ONE reusable "you were paid" card for every event type. Every payout in this
-- resource goes through handlePayout below (or calls RewardService.Announce
-- directly, like Hot Cargo's crate), so there is exactly one place that decides
-- what the player sees:
--   Event completed → reward calculated → reward given → card shown to the
--   player who received it (and only them).
-- The card is { event, title, name, stats = {{label,value,tone}}, rewards =
-- {{kind,label,value}}, note, group }. `event` picks the colour/icon on the
-- client (convoy / airdrop / hotcargo / rally / tdm ...), `group` lets payouts
-- that land together (e.g. a race's cash + its tokens) merge into one card
-- instead of stacking several.
local ACCOUNT_LABELS = { bank = 'Bank deposit', cash = 'Cash', black_money = 'Dirty money' }
local MERGE_WINDOW_MS = 900
local pendingCards = {}

local function formatMoney(amount)
    local s = tostring(math.floor((tonumber(amount) or 0) + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    out = out:gsub('^,', '')
    return '$' .. out
end

local function prettyItem(name)
    local s = tostring(name or 'item'):gsub('_', ' ')
    return (s:gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b end))
end

-- One line of the card for a single reward entry; nil when it pays nothing.
local function rewardCardLine(reward, payAccount)
    local rawType = string.upper(tostring(reward.type or reward.rewardType or reward.kind or ''))
    local rawAmount = tonumber(reward.amount or reward.count or reward.quantity or reward.value) or 1
    local rawItem = reward.item or reward.pool or reward.name or reward.itemName or reward.item_name or reward.weapon or ''
    if rawType == 'MONEY' or rawType == 'CASH' or rawType == 'BANK' or rawType == 'BLACK_MONEY' then
        if rawAmount <= 0 then return nil end
        return { kind = 'money', label = ACCOUNT_LABELS[payAccount] or 'Cash', value = formatMoney(rawAmount) }
    elseif rawType == 'ITEM' or rawType == 'ITEMS' or rawType == 'WEAPON' then
        if rawItem == '' or rawAmount <= 0 then return nil end
        return { kind = 'item', label = prettyItem(rawItem), value = ('×%d'):format(math.floor(rawAmount)) }
    elseif rawType == 'TOKENS' or rawType == 'TOKEN' then
        if rawAmount <= 0 then return nil end
        return { kind = 'token', label = 'Race tokens', value = ('×%d'):format(math.floor(rawAmount)) }
    elseif rawType == 'VEHICLE' then
        local label = (reward.pool and reward.pool ~= '' and reward.pool) or (reward.model and prettyItem(reward.model)) or 'Vehicle'
        local n = math.max(1, math.floor(rawAmount))
        local where = (reward.mode == 'SPAWN') and 'keys received' or 'in your garage'
        return { kind = 'vehicle', label = label, value = n > 1 and ('×%d · %s'):format(n, where) or where }
    end
    return nil
end

local function cloneCard(card)
    local c = {}
    for k, v in pairs(card) do c[k] = v end
    c.rewards, c.stats = {}, {}
    for _, r in ipairs(card.rewards or {}) do c.rewards[#c.rewards + 1] = r end
    for _, s in ipairs(card.stats or {}) do c.stats[#c.stats + 1] = s end
    return c
end

local function queueCard(src, card)
    local key = ('%s|%s'):format(src, card.group or ((card.event or '') .. ':' .. (card.title or '')))
    local pending = pendingCards[key]
    if pending then
        -- Same payout moment → fold into the card that's already waiting.
        for _, r in ipairs(card.rewards or {}) do pending.rewards[#pending.rewards + 1] = r end
        for _, s in ipairs(card.stats or {}) do
            local dup = false
            for _, e in ipairs(pending.stats) do if e.label == s.label then dup = true break end end
            if not dup then pending.stats[#pending.stats + 1] = s end
        end
        if (not pending.note or pending.note == '') and card.note then pending.note = card.note end
        return
    end
    pendingCards[key] = cloneCard(card)
    SetTimeout(MERGE_WINDOW_MS, function()
        local out = pendingCards[key]
        pendingCards[key] = nil
        if out and #out.rewards > 0 and GetPlayerName(src) then
            TriggerClientEvent('nova_convoytruck:client:rewardAnnouncement', src, out)
        end
    end)
end

-- recipients: list of server ids — each one gets their OWN copy of the card, so
-- nobody sees a reward that wasn't paid to them.
function RewardService.Announce(recipients, card)
    if type(card) ~= 'table' or type(recipients) ~= 'table' then return end
    for _, src in ipairs(recipients) do
        if src then queueCard(src, card) end
    end
end

-- Formats a reward list exactly as it is shown on the card (used by events that
-- place the reward somewhere other than the player's account, e.g. Hot Cargo's
-- crate, so the card still names the real amounts).
function RewardService.CardLines(rewards, payAccount)
    local lines = {}
    for _, reward in ipairs(rewards or {}) do
        local line = rewardCardLine(reward, payAccount)
        if line then lines[#lines + 1] = line end
    end
    return lines
end

-- Race cash and race tokens are paid by two separate code paths a moment
-- apart; both use this group so they land on the player's screen as one card.
function RewardService.RaceGroup(convoyId)
    return 'race:' .. tostring(convoyId)
end

-- ── Gang XP (reward type GANG_XP) ─────────────────────────────────────────────
-- A Gang XP entry is paid per RECIPIENT, and only to recipients the SERVER can prove are in a gang (GangXP.GangOf) — a
-- civilian in the same recipient list gets their normal money / items and exactly 0 XP. Each earner gets their own
-- "+N XP" line, merged into the reward card the same payout already shows.

-- Identity of the current RUN of an event, so a reused event (Edit & Reuse) is a new run and may pay XP again, while a
-- repeated submission of the same run's result can not (see the dedupe key in GangXP.PayReward).
function RewardService.runIdFor(convoyId)
    if not convoyId then return nil end
    local rt = (Runtime and Runtime.get and Runtime.get(convoyId)) or (ContainerWars and ContainerWars.get and ContainerWars.get(convoyId))
    if rt and rt.startedAt then return rt.startedAt end
    return nil
end

local EVENT_CARD_KEY = {
    CONVOY = 'convoy', GANG_AIRDROP = 'airdrop', HOT_CARGO = 'hotcargo', GANG_RACE = 'rally', TDM = 'tdm',
    CONTAINER_WARS = 'container_wars', GANG_TERRITORY = 'territory', CRACKDOWN = 'crackdown',
}

-- amount: the configured XP of ONE reward entry. kind: label of the payout (log only). provenance: { convoyId, convoyName,
-- runId?, xpPhase? }. announce: the card the payout shows (its group doubles as the dedupe phase).
function RewardService.PayGangXp(recipients, amount, kind, provenance, announce)
    if TestRun and TestRun.admin then return {} end
    if not GangXP then return {} end
    local convoyId = provenance and provenance.convoyId
    local def = convoyId and ConvoyManager and ConvoyManager.get(convoyId) or nil
    local runId = (provenance and provenance.runId) or RewardService.runIdFor(convoyId)
    if runId == nil then
        print(('[NovaConvoy][Reward] GANG_XP for event %s has no run id — duplicate protection falls back to once per event definition.'):format(tostring(convoyId)))
    end
    local paid = GangXP.PayReward(recipients, amount, {
        kind = def and def.kind or 'OTHER',
        eventId = convoyId,
        eventName = (provenance and provenance.convoyName) or (def and def.name),
        runId = runId,
        phase = (provenance and provenance.xpPhase) or (announce and announce.group) or kind,
    })
    local cardEvent = (announce and announce.event) or EVENT_CARD_KEY[def and def.kind or ''] or 'convoy'
    for src, xp in pairs(paid) do
        if convoyId ~= nil then
            local pName, pIdent, pGang = ledgerIdentity(src)
            RewardService.RecordPayout(convoyId, { kind = kindLabel(kind, provenance), player = pName, identifier = pIdent, gang = pGang, xp = xp })
        end
        RewardService.Announce({ src }, {
            event = cardEvent,
            title = (announce and announce.title) or 'GANG XP EARNED',
            name = (announce and announce.name) or (def and def.name),
            group = (announce and announce.group) or ('xp:' .. tostring(convoyId)),
            rewards = { { kind = 'xp', label = 'Gang XP', value = ('+%d XP'):format(xp) } },
        })
    end
    return paid
end

-- rewards: a LIST of {type, amount, pool/item} entries — every entry pays out
-- independently, so a MONEY entry and an ITEMS entry (or several ITEMS
-- entries) can all fire from the same reward.
-- announce (optional card, see above): when given, every recipient is shown what
-- THEY were paid right after the payout, listing each reward on its own line.
local function handlePayout(kind, rewards, recipients, account, provenance, announce)
    if TestRun and TestRun.admin then print(('[NovaConvoy][TestRun] %s: reward not paid (test run)'):format(tostring(kind))) return {} end
    local lines = {}
    local leftovers = {}   -- item / token rewards that did not fit in the inventory: the caller may keep them to be collected again
    for _, reward in ipairs(rewards or {}) do
        local rawType = string.upper(tostring(reward.type or reward.rewardType or reward.kind or ''))
        local rawAmount = tonumber(reward.amount or reward.count or reward.quantity or reward.value) or 1
        local rawItem = reward.item or reward.pool or reward.name or reward.itemName or reward.item_name or reward.weapon or ''
        local payAccount = account or 'bank'

        if rawType == 'MONEY' or rawType == 'CASH' or rawType == 'BANK' or rawType == 'BLACK_MONEY' then
            if rawType == 'CASH' or reward.account == 'cash' then
                payAccount = 'cash'
            elseif rawType == 'BANK' or reward.account == 'bank' then
                payAccount = 'bank'
            elseif rawType == 'BLACK_MONEY' or reward.account == 'black_money' or reward.pool == 'black_money' then
                payAccount = 'black_money'
            end
            if rawAmount > 0 then
                payMoney(recipients, rawAmount, payAccount)
            end
        elseif rawType == 'ITEM' or rawType == 'ITEMS' or rawType == 'WEAPON' then
            if not payItem(recipients, tostring(rawItem), rawAmount, provenance) then leftovers[#leftovers + 1] = reward end
        elseif rawType == 'TOKENS' or rawType == 'TOKEN' then
            local tokenItem = (Config.RallyRace and Config.RallyRace.tokenItem) or 'race_token'
            if not payItem(recipients, tokenItem, math.max(1, math.floor(rawAmount)), provenance) then leftovers[#leftovers + 1] = reward end
        elseif rawType == 'GANG_XP' then
            -- not a payout to the player: credited to the gang's XP ledger (and the member's own history)
            if rawAmount > 0 then RewardService.PayGangXp(recipients, rawAmount, kind, provenance, announce) end
        elseif rawType == 'VEHICLE' then
            -- provenance.spawn: where a SPAWN-mode car appears (e.g. beside the container); otherwise next to the player
            local copies = math.max(1, math.min(5, math.floor(rawAmount)))
            for _, source in ipairs(recipients or {}) do
                for _ = 1, copies do
                    RewardService.GiveVehicle(source, reward, provenance and provenance.spawn or nil, provenance)
                end
            end
        else
            print(('[NovaConvoy][Reward] REWARD BACKEND REQUIRED: %s has reward type "%s" with no payout integration (only MONEY/ITEMS/TOKENS/WEAPON/VEHICLE/GANG_XP are wired).'):format(kind, tostring(reward.type or reward.rewardType)))
        end

        local line = rewardCardLine(reward, payAccount)
        if line then lines[#lines + 1] = line end
    end

    -- ledger: what each recipient got besides Gang XP (that is recorded by PayGangXp, only for the members who really earned it)
    local convoyId = provenance and provenance.convoyId
    if convoyId ~= nil then
        local plain = {}
        for _, reward in ipairs(rewards or {}) do
            local t = string.upper(tostring(reward.type or reward.rewardType or reward.kind or ''))
            if t ~= 'GANG_XP' then plain[#plain + 1] = reward end
        end
        local text = RewardService.describeRewards(plain)
        if text ~= 'None' then
            for _, src in ipairs(recipients or {}) do
                if GetPlayerName(src) then
                    local pName, pIdent, pGang = ledgerIdentity(src)
                    RewardService.RecordPayout(convoyId, { kind = kindLabel(kind, provenance), player = pName, identifier = pIdent, gang = pGang, text = text })
                end
            end
        end
    end

    if announce and #lines > 0 then
        local card = cloneCard(announce)
        for _, l in ipairs(lines) do card.rewards[#card.rewards + 1] = l end
        RewardService.Announce(recipients, card)
    end
    return leftovers
end

-- Called once when a convoy is delivered successfully.
function RewardService.GiveConvoyReward(convoyDef, recipients, customRewards, runId)
    local rewards = customRewards or convoyDef.reward
    log('GiveConvoyReward', { convoy = convoyDef.name, reward = rewards, recipients = recipients })
    local provenance = { convoyId = convoyDef.id, convoyName = convoyDef.name, runId = runId }
    handlePayout('GiveConvoyReward', rewards, recipients, 'bank', provenance, {
        event = 'convoy', title = 'CONVOY COMPLETED', name = convoyDef.name, group = 'run:' .. tostring(convoyDef.id),
    })
    logToDiscord('Convoy Delivered', rewards, recipients, provenance)
end

-- Pays an arbitrary reward list to a single recipient — used for GANG_RACE's
-- per-finishing-position rewards (def.positionRewards.first/second/third/
-- participation), which are separate lists from convoyDef.reward, so
-- GiveConvoyReward (which always reads convoyDef.reward specifically) can't
-- be reused directly for them.
function RewardService.GiveRaceReward(convoyDef, rewards, recipient, label, runId)
    if not rewards or #rewards == 0 then return end
    -- the finishing position is part of the XP dedupe phase: one position reward per racer per run
    local provenance = { convoyId = convoyDef.id, convoyName = convoyDef.name, runId = runId, xpPhase = 'race:' .. tostring(label or 'finish'),
        payoutLabel = label and ('Race — %s'):format(label) or nil }
    handlePayout('GiveRaceReward', rewards, { recipient }, 'bank', provenance, {
        event = 'rally', title = 'RALLY RACE COMPLETED', name = convoyDef.name, group = RewardService.RaceGroup(convoyDef.id),
        stats = label and { { label = 'Finish', value = label } } or nil,
    })
    logToDiscord(('Gang Rally — %s'):format(label or 'Finisher'), rewards, { recipient }, provenance)
end

-- Called if a reward needs to be revoked/rolled back (e.g. admin cancels after payout).
-- Deliberately not implemented: clawing back money already spent/laundered is
-- its own can of worms (insufficient funds, account already emptied) and
-- nothing in this resource currently calls this after a real payout has
-- happened, so it stays a log-only stub rather than a false promise.
function RewardService.RemoveConvoyReward(convoyDef, recipients)
    log('RemoveConvoyReward', { convoy = convoyDef.name, reward = convoyDef.reward, recipients = recipients })
end

-- Called when a gang successfully captures a convoy (also TDM winners and
-- tournament champions). `recipients` is the list of online player sources
-- belonging to the winning gang. `opts` (optional) overrides the announcement
-- card — event / title / name — for callers that aren't a plain convoy capture.
function RewardService.GrantGangReward(gangName, convoyDef, recipients, gangLabel, opts, customRewards)
    local rewards = customRewards or convoyDef.reward
    log('GrantGangReward', { gang = gangName, convoy = convoyDef.name, reward = rewards, recipients = recipients })
    -- opts.runId / opts.xpPhase are bookkeeping for Gang XP duplicate protection, not part of the card
    local provenance = { convoyId = convoyDef.id, convoyName = convoyDef.name, gangName = gangName, gangLabel = gangLabel,
        runId = opts and opts.runId, xpPhase = opts and opts.xpPhase,
        payoutLabel = (opts and opts.title) or (convoyDef.kind == 'TDM' and 'TDM victory') or nil }
    local isTdm = convoyDef.kind == 'TDM'
    local card = {
        event = isTdm and 'tdm' or 'convoy',
        title = isTdm and 'TDM VICTORY' or 'CONVOY CAPTURED',
        name = convoyDef.name,
        group = 'gang:' .. tostring(convoyDef.id) .. ':' .. tostring(gangName),
        stats = gangLabel and { { label = 'Gang', value = gangLabel } } or nil,
    }
    for k, v in pairs(opts or {}) do
        if k ~= 'runId' and k ~= 'xpPhase' then card[k] = v end
    end
    handlePayout('GrantGangReward', rewards, recipients, 'cash', provenance, card)
    logToDiscord('Convoy Captured', rewards, recipients, provenance)
end

-- Called when someone successfully cracks open an airdrop crate AND its own
-- percentage roll hits (see Route tab's per-airdrop chance field) — a
-- distinct, usually smaller reward LIST from the convoy's own main reward,
-- paid directly to whoever looted it rather than the whole gang. `opts`
-- (optional) overrides the announcement card (Hot Cargo's salvage uses this).
function RewardService.GiveAirdropReward(rewards, recipients, provenance, opts)
    log('GiveAirdropReward', { rewards = rewards, recipients = recipients })
    local card = {
        event = 'airdrop', title = 'AIRDROP LOOTED', name = provenance and provenance.convoyName or nil,
        group = 'loot:' .. tostring(provenance and provenance.convoyId or '?'),
    }
    for k, v in pairs(opts or {}) do card[k] = v end
    handlePayout('GiveAirdropReward', rewards, recipients, 'cash', provenance, card)
    logToDiscord('Airdrop Looted', rewards, recipients, provenance)
end

function RewardService.GrantContainerReward(rewards, recipientSource, provenance, opts)
    log('GrantContainerReward', { rewards = rewards, recipient = recipientSource })
    if provenance and not provenance.payoutLabel and provenance.containerName then provenance.payoutLabel = ('Container - %s'):format(provenance.containerName) end
    local card = {
        event = 'container_wars',
        title = 'CONTAINER REWARD CLAIMED',
        name = provenance and provenance.containerName or (provenance and provenance.convoyName) or 'Container Wars',
        group = 'container:' .. tostring(provenance and provenance.containerId or '?'),
        stats = provenance and provenance.gangLabel and { { label = 'Gang', value = provenance.gangLabel } } or nil,
    }
    for k, v in pairs(opts or {}) do card[k] = v end
    local leftovers = handlePayout('GrantContainerReward', rewards, { recipientSource }, 'cash', provenance, card)
    logToDiscord('Container Reward Claimed', rewards, { recipientSource }, provenance)
    return leftovers   -- the item rewards that did not fit (empty when everything was paid)
end

return RewardService
