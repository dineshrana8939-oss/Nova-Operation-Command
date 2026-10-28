-- ─── Nova Convoy — staff tag over the head (server) ───────────────────────────────────────────────────────────────
-- An admin (or a member of the event staff) can switch a small "ADMIN" / "EVENT STAFF" tag on over their own head from the Admin Panel
-- (Settings). It lives in a player state bag (novaStaffTag) that every client can read, so nothing is broadcast or polled and it
-- disappears by itself when the player leaves. The server decides WHICH tag the player may wear; the client only asks for it on or off.
--   admin (ACE / framework admin / Super Admin)  → ADMIN
--   an active member of the Staff Management list → EVENT STAFF
--   anyone else                                   → nothing, the request is ignored

StaffTag = {}

local TAG_ADMIN, TAG_STAFF = 'ADMIN', 'EVENT STAFF'

local function allowedTag(src)
    local d = UserPermissions.describe(src)
    if d.isSuperAdmin or Bridge.IsAdmin(src, (Config.CreatorAccess or {}).adminPermission) then return TAG_ADMIN end
    if d.staffRole and d.staffStatus == 'active' then return TAG_STAFF end
    return nil
end

local askedAt = {}
AddEventHandler('playerDropped', function() askedAt[source] = nil end)

lib.callback.register('nova_convoytruck:staffTag:get', function(src)
    local label = allowedTag(src)
    return { ok = true, available = label, enabled = label ~= nil and Player(src).state.novaStaffTag == label }
end)

RegisterNetEvent('nova_convoytruck:staffTag:set', function(enabled)
    local src = source
    local now = GetGameTimer()
    if askedAt[src] and now - askedAt[src] < 1000 then return end
    askedAt[src] = now
    local label = allowedTag(src)
    local want = (enabled == true and label) or nil
    if Player(src).state.novaStaffTag ~= want then Player(src).state:set('novaStaffTag', want, true) end
end)
