-- ─── Nova Convoy — Banking Bridge ─────────────────────────────────────────────
-- Server-side. The single place that knows how a player's BANK money is paid,
-- charged and read. Bridge.AddMoney / RemoveMoney / GetMoney hand every
-- account == 'bank' call here, so nothing else in the resource touches a
-- banking script directly (cash and black money never come through here).
--
-- Two kinds of banking script exist, and a provider module covers either:
--   * the balance lives in the framework (qbx/qb/esx "bank" account) and the
--     script only records a statement  -> provide Log(); the framework moves
--     the money, the provider just makes it show up in the bank app
--   * the script owns the balance itself -> provide Deposit / Withdraw /
--     GetBalance and the framework balance is never touched
--
-- Provider contract (bridge/banking/<name>.lua returns a table with):
--   resource                          string  resource that must be 'started'
--   Log(source, amount, kind, reason) optional  kind = 'deposit' | 'withdraw'
--   Deposit(source, amount, reason)   optional  -> boolean ok
--   Withdraw(source, amount, reason)  optional  -> boolean ok
--   GetBalance(source)                optional  -> number
-- Every function is optional; whatever a provider leaves out falls back to the
-- framework. A provider that errors is logged and the framework path is used,
-- so a banking script problem can never swallow a payout.

Banking = {}

-- Order matters for Config.BankingProvider = 'auto'.
local AUTO_DETECT = {
    { name = 'renewed', resource = 'Renewed-Banking' },
}

local loaded = {}
local resolvedKey, resolvedProvider = nil, nil
local warned = {}

local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    lib.print.warn(('[nova_convoytruck][Banking] %s'):format(msg))
end

local function loadProvider(name)
    if loaded[name] ~= nil then return loaded[name] or nil end
    local ok, mod = pcall(require, 'bridge.banking.' .. name)
    if not ok or type(mod) ~= 'table' then
        warnOnce('load:' .. name, ('could not load provider "%s": %s'):format(name, tostring(mod)))
        loaded[name] = false
        return nil
    end
    loaded[name] = mod
    return mod
end

-- Provider currently in effect, or nil for "framework only". Re-checked on
-- every call because a banking script may start after this resource does; the
-- result is cached per (setting, resource state) so the check stays cheap.
local function provider()
    local setting = tostring(Config.BankingProvider or 'auto')
    if setting == 'framework' then return nil end

    local name, mod
    if setting == 'auto' then
        for _, entry in ipairs(AUTO_DETECT) do
            if GetResourceState(entry.resource) == 'started' then
                name = entry.name
                break
            end
        end
        if not name then return nil end
    else
        name = setting
    end

    mod = loadProvider(name)
    if not mod then return nil end
    if mod.resource and GetResourceState(mod.resource) ~= 'started' then
        warnOnce('state:' .. name, ('provider "%s" selected but resource "%s" is not started — using the framework bank balance'):format(name, mod.resource))
        return nil
    end

    local key = name .. ':' .. tostring(mod.resource)
    if resolvedKey ~= key then
        resolvedKey, resolvedProvider = key, mod
        lib.print.info(('[nova_convoytruck][Banking] using "%s"%s'):format(name, mod.resource and (' (' .. mod.resource .. ')') or ''))
    end
    return mod
end

function Banking.GetProvider()
    local p = provider()
    return p and resolvedKey or 'framework'
end

local function attempt(p, fn, ...)
    if not (p and p[fn]) then return false end
    local ok, a = pcall(p[fn], ...)
    if not ok then
        warnOnce('err:' .. tostring(resolvedKey) .. ':' .. fn, ('provider error in %s: %s — using the framework balance instead'):format(fn, tostring(a)))
        return false
    end
    return true, a
end

-- Pays `amount` into the player's bank. -> boolean ok
function Banking.Deposit(source, amount, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 then return false end
    reason = reason or 'nova_convoytruck:reward'
    local p = provider()

    local used, ok = attempt(p, 'Deposit', source, amount, reason)
    if used then return ok ~= false end

    ok = Bridge.RawMoney.Add(source, amount, 'bank', reason)
    if ok ~= false then attempt(p, 'Log', source, amount, 'deposit', reason) end
    return ok ~= false
end

-- Takes `amount` from the player's bank. -> boolean ok (false = not enough)
function Banking.Withdraw(source, amount, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 then return false end
    reason = reason or 'nova_convoytruck:purchase'
    local p = provider()

    local used, ok = attempt(p, 'Withdraw', source, amount, reason)
    if used then return ok ~= false end

    ok = Bridge.RawMoney.Remove(source, amount, 'bank', reason)
    if ok then attempt(p, 'Log', source, amount, 'withdraw', reason) end
    return ok and true or false
end

-- Current bank balance. -> number
function Banking.GetBalance(source)
    local p = provider()
    local used, bal = attempt(p, 'GetBalance', source)
    if used and tonumber(bal) then return tonumber(bal) end
    return Bridge.RawMoney.Get(source, 'bank') or 0
end
