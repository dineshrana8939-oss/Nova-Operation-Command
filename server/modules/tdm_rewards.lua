-- ─── Nova Convoy — TDM reward scaling (server) ───────────────────────────────────────────────────────────────────
-- Pays the reward list of a TDM template (or the champion / other gangs of a tournament built on it) PER PLAYER, by how well each one did:
--
--   winning team   every online member is paid. The best killer of the team gets the whole reward; the others get
--                  winnerMinPercent + (100 - winnerMinPercent) x (their kills / the best killer's kills)  of it.
--   losing team    every online member is paid loserPercent of the reward, scaled the same way with loserMinPercent
--                  (so the top fighter of the losing side earns the most, the one with no kills the least). 0 = the losers get nothing.
--   nobody scored  everyone on a side counts as equal (the top share).
--
-- Money, items, tokens and Gang XP amounts are scaled (rounded, at least 1 for the winners); a vehicle goes to the best killer(s) of the
-- winning team only. The three percentages live in the event form (TDM Match Setup → Match Reward) and default to Config.TDM.rewardScaling.
-- With "scale by kills" switched off the winners all get the full reward and the losers nothing, exactly as before.

TdmRewards = {}

local function pct(v, fallback)
    v = tonumber(v)
    if v == nil then v = fallback end
    return math.max(0, math.min(100, v))
end

function TdmRewards.settings(def)
    local d = (Config.TDM or {}).rewardScaling or {}
    local r = (def and def.tdm and def.tdm.rewardScaling) or {}
    local enabled
    if r.enabled == nil then enabled = d.enabled ~= false else enabled = r.enabled ~= false end
    return {
        enabled = enabled,
        winnerMinPercent = pct(r.winnerMinPercent, d.winnerMinPercent or 40),
        loserPercent = pct(r.loserPercent, d.loserPercent or 25),
        loserMinPercent = pct(r.loserMinPercent, d.loserMinPercent or 40),
    }
end

-- members: { { source, kills } } of ONE team. Returns share (0..1) per source, and the best share.
function TdmRewards.shares(members, isWinner, sc)
    local out, best, top = {}, 0.0, 0
    for _, p in ipairs(members) do if (p.kills or 0) > top then top = p.kills end end
    local base = isWinner and 1.0 or (sc.loserPercent / 100)
    local minF = (isWinner and sc.winnerMinPercent or sc.loserMinPercent) / 100
    for _, p in ipairs(members) do
        local f = top > 0 and ((p.kills or 0) / top) or 1.0
        local share
        if not sc.enabled then share = isWinner and 1.0 or 0.0 else share = base * (minF + (1 - minF) * f) end
        out[p.source] = share
        if share > best then best = share end
    end
    return out, best
end

local function typeOf(r) return string.upper(tostring(r.type or r.rewardType or r.kind or '')) end
local function amountOf(r) return tonumber(r.amount or r.count or r.quantity or r.value) or 1 end

-- a scaled COPY of the reward list for one player; also the Gang XP it contains (for the results cards)
function TdmRewards.scale(rewards, share, isWinner, isBest)
    local out, xp = {}, 0
    for _, r in ipairs(rewards or {}) do
        local t = typeOf(r)
        if t == 'VEHICLE' then
            if isWinner and isBest and share > 0 then out[#out + 1] = r end
        elseif share > 0 then
            local amount = amountOf(r)
            local n = math.floor(amount * share + 0.5)
            if n < 1 and amount > 0 and isWinner then n = 1 end
            if n >= 1 then
                local c = {}
                for k, v in pairs(r) do c[k] = v end
                c.amount, c.count, c.quantity, c.value = n, nil, nil, nil
                out[#out + 1] = c
                if t == 'GANG_XP' then xp = xp + n end
            end
        end
    end
    return out, xp
end

-- Pays one team. members: { { source, kills } }. Returns { [source] = { xp, share } }.
function TdmRewards.payTeam(def, gangName, gangLabel, members, isWinner, runId, title)
    local result = {}
    if not def or #members == 0 then return result end
    local sc = TdmRewards.settings(def)
    local shares, best = TdmRewards.shares(members, isWinner, sc)
    for _, p in ipairs(members) do
        local share = shares[p.source] or 0
        local list, xp = TdmRewards.scale(def.reward, share, isWinner, share >= best - 0.0001)
        if #list > 0 then
            RewardService.GrantGangReward(gangName, def, { p.source }, gangLabel, {
                runId = runId, xpPhase = isWinner and 'tdm-win' or 'tdm-lose', title = title,
            }, list)
        end
        result[p.source] = { xp = xp, share = share }
    end
    return result
end
