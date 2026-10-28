-- ─── Nova Convoy — Local Role Cache (client) ──────────────────
-- The client has no way to know on its own whether the local player is police
-- or an admin (those are server-side framework/ACE checks) — but a few purely
-- cosmetic client-side things, like the shop/trigger ped map blips, must only
-- ever be drawn for police and admins. The server broadcasts this player's own
-- role once it's known (on load and on resource start); this caches it so any
-- client module can gate on it without its own round-trip.
--
-- NovaConvoy.Roles.isPolice / isAdmin are the only things that should read
-- this. Everything gameplay-affecting is still enforced server-side — this is
-- purely for deciding what to DRAW for this one client.
NovaConvoy = NovaConvoy or {}
NovaConvoy.Roles = { isPolice = false, isAdmin = false, resolved = false }

-- The ONE place the cache is written. Every path that learns the role funnels
-- through here so they all consistently fire rolesResolved — modules that draw
-- a blip at spawn time (before the role was known) listen for that to redraw.
-- (Previously roleSync set the cache but never fired rolesResolved, and the
-- only handler that DID fire it listened on an event nothing ever sent — so
-- the blips were never redrawn after roles resolved. That's the bug fixed here.)
local function applyRoles(roles)
    if type(roles) ~= 'table' then return end
    NovaConvoy.Roles.isPolice = roles.isPolice == true
    NovaConvoy.Roles.isAdmin = roles.isAdmin == true
    NovaConvoy.Roles.resolved = true
    TriggerEvent('nova_convoytruck:client:rolesResolved')
end
RegisterNetEvent('nova_convoytruck:client:roleSync', function(roles)
    applyRoles(roles)
end)

-- Police OR admin — the audience for the shop/trigger ped map blips.
function NovaConvoy.Roles.canSeeStaffBlips()
    return NovaConvoy.Roles.isPolice or NovaConvoy.Roles.isAdmin
end
-- Ask the server for our role immediately on start, so a client that loaded
-- before the server's own on-load broadcast ever fired (e.g. resource restart
-- while already connected) still gets gated correctly instead of defaulting
-- to hiding staff blips forever.
CreateThread(function()
    Wait(500)
    local res = lib.callback.await('nova_convoytruck:getMyRoles', false)
    applyRoles(res)
end)

-- Re-ask whenever the player's job could have changed — a player who joins as
-- a civilian and later goes on-duty isn't sent a fresh broadcast, so without
-- this their blips would never appear until they reconnected.
RegisterNetEvent('QBCore:Client:OnJobUpdate', function() TriggerServerEvent('nova_convoytruck:server:requestRoleSync') end)
RegisterNetEvent('qbx_core:client:playerJobUpdated', function() TriggerServerEvent('nova_convoytruck:server:requestRoleSync') end)
RegisterNetEvent('esx:setJob', function() TriggerServerEvent('nova_convoytruck:server:requestRoleSync') end)

-- Re-ask on every full player load too — the server's own on-load broadcast
-- can arrive before this client script is even running (or after a resource
-- restart), so this is the belt-and-suspenders path that guarantees we end up
-- knowing our real role.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() TriggerServerEvent('nova_convoytruck:server:requestRoleSync') end)
RegisterNetEvent('qbx_core:client:playerLoaded', function() TriggerServerEvent('nova_convoytruck:server:requestRoleSync') end)
RegisterNetEvent('esx:playerLoaded', function() TriggerServerEvent('nova_convoytruck:server:requestRoleSync') end)
