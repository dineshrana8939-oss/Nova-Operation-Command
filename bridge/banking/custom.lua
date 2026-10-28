-- ─── Custom Banking Provider Template ─────────────────────────────────────────
-- Only loaded when Config.BankingProvider = 'custom' in config/config.lua.
--
-- Point this at any banking script. Every function is OPTIONAL — delete the ones
-- you don't need and the framework bank balance is used for them instead
-- (see the contract at the top of bridge/banking.lua).
--
--   * Banking script only records a STATEMENT (balance stays in the framework,
--     e.g. okokBanking / most "bank app" scripts):  implement Log() only.
--   * Banking script OWNS the balance:  implement Deposit / Withdraw /
--     GetBalance. The framework bank balance is then never touched.
--
-- source is the player's server id; Bridge.GetIdentifier(source) gives the
-- character identifier (citizenid / ESX identifier) if the script wants that.
-- Return true on success. Errors are caught and logged, and the payout then
-- falls back to the framework so a banking-script problem never eats a reward.

local M = {}

-- The resource that must be running for this provider to be used.
M.resource = 'your-banking-resource'

-- Statement-only example:
-- function M.Log(source, amount, kind, reason) -- kind: 'deposit' | 'withdraw'
--     exports['your-banking-resource']:AddTransaction(Bridge.GetIdentifier(source), amount, kind, reason)
-- end

-- Script-owned balance example:
-- function M.Deposit(source, amount, reason)
--     return exports['your-banking-resource']:AddMoney(source, amount, reason) and true or false
-- end
-- function M.Withdraw(source, amount, reason)
--     return exports['your-banking-resource']:RemoveMoney(source, amount, reason) and true or false
-- end
-- function M.GetBalance(source)
--     return exports['your-banking-resource']:GetBalance(source)
-- end

return M
