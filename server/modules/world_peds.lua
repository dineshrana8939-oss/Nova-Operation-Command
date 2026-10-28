-- ─── Nova Convoy — World Peds (server) ────────────────────────────────────────────
-- Permanent peds that belong to NO event: they stand in the world all the time, wherever an admin placed them (tablet →
-- World Peds), whether or not any race / TDM event exists.
--   token_vendor   the Race Token Vendor — gang members trade race tokens for a special vehicle
--   practice       the Practice Range instructor — starts the solo / squad TDM practice sessions
-- A position and an on/off switch are saved per ped (resource KVP, so they survive restarts). The Config.* values are only
-- the defaults before an admin places one. Every change is pushed to every client at once, no restart needed.
-- (The race "vehicle ped" is NOT here — that one belongs to a race event and is placed in the race builder.)

WorldPeds = {}

-- The token vendor keeps the KVP keys it has always used, so a position saved earlier is still where it was.
local DEFS = {
    token_vendor = { label = 'Race Token Vendor', locKey = 'nova_token_vendor_location', enKey = 'nova_token_vendor_enabled' },
    practice     = { label = 'Practice Range Instructor', locKey = 'nova_world_ped_practice_location', enKey = 'nova_world_ped_practice_enabled' },
}
local ORDER = { 'token_vendor', 'practice' }

local function configOf(id)
    local c = (id == 'token_vendor' and Config.TokenVendor) or (id == 'practice' and Config.PracticeRange) or {}
    return c.pedModel, c.pedCoords, c.enabled ~= false
end

local function decode(raw)
    if not raw then return nil end
    local ok, t = pcall(json.decode, raw)
    if ok and type(t) == 'table' and tonumber(t.x) and tonumber(t.y) and tonumber(t.z) then
        return { x = tonumber(t.x) + 0.0, y = tonumber(t.y) + 0.0, z = tonumber(t.z) + 0.0, heading = (tonumber(t.heading) or 0.0) + 0.0 }
    end
    return nil
end

function WorldPeds.get(id)
    local def = DEFS[id]
    if not def then return nil end
    local model, coords, defaultOn = configOf(id)
    local loc = decode(GetResourceKvpString(def.locKey))
    if not loc and coords then loc = { x = coords.x, y = coords.y, z = coords.z, heading = coords.w or 0.0 } end
    local saved = GetResourceKvpString(def.enKey)
    local enabled = defaultOn
    if saved == '1' then enabled = true elseif saved == '0' then enabled = false end
    return {
        id = id, label = def.label, model = model, enabled = enabled,
        x = loc and loc.x or nil, y = loc and loc.y or nil, z = loc and loc.z or nil, heading = loc and loc.heading or 0.0,
    }
end

function WorldPeds.list()
    local out = {}
    for _, id in ipairs(ORDER) do out[#out + 1] = WorldPeds.get(id) end
    return out
end

local function broadcast()
    TriggerClientEvent('nova_convoytruck:worldPeds:changed', -1, WorldPeds.list())
end
WorldPeds.broadcast = broadcast

function WorldPeds.setLocation(id, loc)
    local def = DEFS[id]
    if not def then return false end
    SetResourceKvp(def.locKey, json.encode({ x = loc.x, y = loc.y, z = loc.z, heading = loc.heading or 0.0 }))
    broadcast()
    return true
end

function WorldPeds.setEnabled(id, enabled)
    local def = DEFS[id]
    if not def then return false end
    SetResourceKvp(def.enKey, enabled and '1' or '0')
    broadcast()
    return true
end

-- Everyone's client needs the list (to keep the peds standing); it holds nothing secret.
lib.callback.register('nova_convoytruck:worldPeds:list', function()
    return { ok = true, peds = WorldPeds.list() }
end)

-- Tablet → World Peds. `placed` is the spot picked with the placement hologram; without it, where the admin stands.
lib.callback.register('nova_convoytruck:worldPeds:set', function(source, id, placed)
    if not UserPermissions.can(source, 'worldpeds.edit') then return { ok = false, error = 'Not authorized.' } end
    if not DEFS[tostring(id)] then return { ok = false, error = 'Unknown ped.' } end
    local x, y, z, heading = PedSpot(source, placed)
    if not x then return { ok = false, error = 'Could not locate you in the world.' } end
    WorldPeds.setLocation(tostring(id), { x = x, y = y, z = z, heading = heading })
    print(('[NovaConvoy] World ped "%s" moved by %s to %.1f, %.1f, %.1f'):format(tostring(id), Bridge.GetPlayerName(source) or 'Unknown', x, y, z))
    return { ok = true, ped = WorldPeds.get(tostring(id)) }
end)

lib.callback.register('nova_convoytruck:worldPeds:setEnabled', function(source, id, enabled)
    if not UserPermissions.can(source, 'worldpeds.edit') then return { ok = false, error = 'Not authorized.' } end
    if not DEFS[tostring(id)] then return { ok = false, error = 'Unknown ped.' } end
    WorldPeds.setEnabled(tostring(id), enabled == true)
    return { ok = true, ped = WorldPeds.get(tostring(id)) }
end)
