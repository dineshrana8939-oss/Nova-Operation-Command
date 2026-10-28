-- ─── Banking provider: Renewed-Banking ────────────────────────────────────────
-- Renewed-Banking keeps a player's personal balance in the framework bank
-- account, so the framework still moves the money (see bridge/banking.lua) —
-- this provider only adds the statement line, so every payout and charge shows
-- up in the player's bank app. Verified against Renewed-Banking's server
-- export handleTransaction(account, title, amount, message, issuer, receiver,
-- transType); a personal account is identified by the character identifier
-- (qb/qbx citizenid, ESX identifier), which is what Bridge.GetIdentifier returns.

local M = {}

M.resource = 'Renewed-Banking'

local ISSUER = 'Operations Hub'

function M.Log(source, amount, kind, reason)
    local id = Bridge.GetIdentifier(source)
    if not id then return end
    local name = Bridge.GetCharacterName(source)
    local message = tostring(reason or ISSUER)
    if kind == 'deposit' then
        exports[M.resource]:handleTransaction(id, ISSUER, amount, message, ISSUER, name, 'deposit')
    else
        exports[M.resource]:handleTransaction(id, ISSUER, amount, message, name, ISSUER, 'withdraw')
    end
end

return M
