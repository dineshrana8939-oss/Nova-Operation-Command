-- ─── Nova Convoy — Race Token Vendor (client) ─────────────────────────────────
-- Vendor ped where players trade the tokens they won by finishing gang rallies for a special vehicle. Prices and the vehicle
-- list live in Config.TokenVendor; the server validates and takes the tokens, this side shows the showroom
-- (client/modules/showroom.lua) and picks a clear, safe spot near the vendor. The server creates the vehicle there, records it
-- as the buyer's own car (garage table + keys, so it can be parked and taken out again) and seats them in it.
-- The ped itself is a permanent "world ped" (client/modules/world_peds.lua): it stands wherever an admin placed it
-- (tablet → World Peds), all the time, whether or not any race event exists.

local function openShop()
    local info = lib.callback.await('nova_convoytruck:tokenVendor:getInfo', false)
    if not info or not info.ok then
        lib.notify({ title = 'Race Tokens', description = (info and info.error) or 'The vendor is unavailable.', type = 'error' })
        return
    end
    if info.gangOnly and not info.isGangMember then
        lib.notify({ title = 'Race Tokens', description = 'Only gang members can trade race tokens.', type = 'error' })
        return
    end
    local vendor = WorldPeds.get('token_vendor')
    if not vendor or not vendor.x then return end

    Showroom.open({
        shop = 'tokens',
        title = 'Race Token Exchange',
        subtitle = 'Trade the tokens you won racing for a ride',
        pedName = 'Mechanic',
        loc = { x = vendor.x, y = vendor.y, z = vendor.z, heading = vendor.heading },
        wallet = { kind = 'tokens', amount = info.tokens or 0, hint = 'Finish gang rallies in a good position to win more.' },
        vehicles = info.vehicles or {},
        onBuy = function(index)
            local spot = Showroom.safeSpot(vendor)
            -- the server creates the car, records it as the buyer's own (garage + keys) and moves the player into it, so
            -- the player must not be held still for that moment
            Showroom.releasePlayer()
            local res = lib.callback.await('nova_convoytruck:tokenVendor:redeem', false, index, spot)
            if not (res and res.ok) then
                Showroom.holdPlayer()
                return { ok = false, error = (res and res.error) or 'Trade failed.' }
            end
            info.tokens = (info.tokens or 0) - (res.cost or 0)
            -- let the "traded" message show for a moment, then fade out / back in around the move
            CreateThread(function() Wait(900); Showroom.claim(spot, nil) end)
            return { ok = true, message = ('%s is yours — plate %s. Keys are in your pocket and it is saved to your garage.'):format(res.label, res.plate or '?'), tokens = info.tokens }
        end,
    })
end

local cfg = Config.TokenVendor or {}
WorldPeds.register('token_vendor', {
    scenario = 'WORLD_HUMAN_CLIPBOARD',
    blip = cfg.blip ~= false and { sprite = 523, colour = 46, scale = 0.8, shortRange = true, label = 'Race Token Exchange' } or nil,
    options = { {
        label = 'Trade Race Tokens',
        icon = 'fa-solid fa-ticket',
        distance = 2.5,
        onSelect = openShop,
    } },
})
