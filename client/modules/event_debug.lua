-- ─── Event debug (client) ─────────────────────────────────────────────────────
-- Prints what /eventdebug (server/modules/event_debug.lua) found into the admin's own F8 console.
local PREFIX = { ok = '^2OK  ', warn = '^3WARN', bad = '^1FAIL', info = '^7    ' }

RegisterNetEvent('nova_convoytruck:debug:eventLines', function(title, lines, quiet)
    if type(lines) ~= 'table' then return end
    print(('^5[EventDebug] %s^0'):format(tostring(title)))
    for _, l in ipairs(lines) do
        print(('%s  %s^0'):format(PREFIX[l[1]] or PREFIX.info, tostring(l[2])))
    end
end)