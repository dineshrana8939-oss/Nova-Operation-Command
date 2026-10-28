-- ─── Sound test command (admin) ───────────────────────────────────────────────
-- /<Config.Sounds.testCommand> ...  lets an admin hear the notification sounds set in Config.Sounds.
-- Only the admin check lives here; the client (client/modules/sound.lua) resolves and plays the sound.

local cmd = Config.Sounds and Config.Sounds.testCommand
if type(cmd) == 'string' and cmd ~= '' then
    RegisterCommand(cmd, function(source, args)
        if source == 0 then
            print(('[NovaConvoy] /%s is used in game.'):format(cmd))
            return
        end
        if not Bridge.IsAdmin(source, Config.CreatorAccess and Config.CreatorAccess.adminPermission) then
            TriggerClientEvent('nova_convoytruck:client:hudNotify', source, { title = 'Sounds', description = 'Admins only.', type = 'error' })
            return
        end
        local clean = {}
        for i = 1, math.min(#args, 12) do clean[i] = tostring(args[i]):sub(1, 80) end
        TriggerClientEvent('nova_convoytruck:sound:test', source, clean)
    end, false)
end
