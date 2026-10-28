-- ─── Nova Convoy — Gang Territory (client) ─────────────────────────────────────
-- World side of the Gang Territory system:
--   · blips + coloured ground rings for every territory (owner colour, live — they change the moment ownership does)
--   · the auction house: host ped + zone where eligible gang members open the bidder window (the Container Wars bidder
--     NUI, reused) while an auction is running
--   · territory wars: the territory leader ped + props appear ONLY while a war is on (local entities for the two gangs),
--     ox_target "Take Territory" for the attackers, the war HUD
-- The server decides everything (who may bid, who captures, who wins); this file only shows it and relays the key presses.

local territories = {}      -- [id] = light view (id, name, owner, ownerLabel, color, center, location, blip, level, war)
local blips = {}            -- [id] = blip handle
local auction = nil         -- the running auction's public state
local auctionBlip = nil
local war = nil             -- the war this player belongs to (local copy)
local warPed, warProps, warBlip, warTargetNet = nil, {}, nil, nil
local warRadiusBlip = nil
local myRole = nil
local myEliminated = false
local removeLeaderPed = nil

local function cfg() return Config.Territory or {} end

local function notify(kind, title, text, duration)
    lib.notify({ title = title, description = text, type = kind or 'inform', duration = duration or 7000 })
end

-- ── helpers ──────────────────────────────────────────────────────────────────────

local function hexToRgb(hex, fallback)
    local h = tostring(hex or ''):gsub('#', '')
    if #h == 3 then h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2) end
    local r, g, b = tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
    if not (r and g and b) then return table.unpack(fallback or { 229, 72, 77 }) end
    return r, g, b
end

-- GTA blips only have a fixed palette; pick the entry closest to the territory's colour.
local BLIP_PALETTE = {
    { 0, 255, 255, 255 }, { 1, 224, 50, 50 }, { 2, 114, 204, 114 }, { 3, 93, 182, 229 }, { 5, 240, 200, 80 },
    { 6, 194, 80, 80 }, { 7, 156, 110, 175 }, { 8, 255, 123, 196 }, { 17, 234, 142, 80 }, { 25, 77, 117, 77 },
    { 27, 106, 83, 163 }, { 29, 53, 86, 165 }, { 38, 53, 86, 165 }, { 40, 77, 77, 77 }, { 46, 240, 220, 120 },
}
local function nearestBlipColour(hex)
    local r, g, b = hexToRgb(hex)
    local best, bestD = 0, math.huge
    for _, p in ipairs(BLIP_PALETTE) do
        local d = (p[2] - r) ^ 2 + (p[3] - g) ^ 2 + (p[4] - b) ^ 2
        if d < bestD then best, bestD = p[1], d end
    end
    return best
end

local function setBlipLabel(blip, text)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(blip)
end

-- ── territory blips ──────────────────────────────────────────────────────────────

local function removeBlip(id)
    if blips[id] and DoesBlipExist(blips[id]) then RemoveBlip(blips[id]) end
    blips[id] = nil
end

local function drawBlip(t)
    removeBlip(t.id)
    local b = t.blip or {}
    if b.enabled == false then return end
    local at = t.location or t.center
    if not at or not at.x then return end
    local blip = AddBlipForCoord(at.x + 0.0, at.y + 0.0, (at.z or 0.0) + 0.0)
    SetBlipSprite(blip, tonumber(b.sprite) or (cfg().blip or {}).sprite or 310)
    SetBlipScale(blip, tonumber(b.scale) or (cfg().blip or {}).scale or 0.85)
    SetBlipColour(blip, b.colour ~= nil and tonumber(b.colour) or nearestBlipColour(t.ownerAccent or t.color))
    SetBlipAsShortRange(blip, b.shortRange ~= false)
    local owner = t.ownerLabel and (' — ' .. t.ownerLabel) or ' — Unclaimed'
    setBlipLabel(blip, (b.label and b.label ~= '' and b.label or t.name) .. owner)
    blips[t.id] = blip
end

local function redrawAllBlips()
    for id in pairs(blips) do removeBlip(id) end
    for _, t in pairs(territories) do drawBlip(t) end
end

local function lightOf(v)
    -- an upsert carries the full view; keep only what the world needs
    return {
        id = v.id, name = v.name, owner = v.owner, ownerLabel = v.ownerLabel, ownerAccent = v.ownerAccent, color = v.color,
        level = v.level, center = v.center, location = v.location, blip = v.blip, war = v.busy,
        ped = v.ped,
    }
end

-- Once the player's role / gang is known after a login, ask for any Gang XP notices (an admin adding or removing XP) that
-- were sent while they were away. The server sends each one only once per member.
RegisterNetEvent('nova_convoytruck:client:rolesResolved', function()
    TriggerServerEvent('nova_convoytruck:territory:server:xpNotices')
end)

RegisterNetEvent('nova_convoytruck:territory:client:snapshot', function(list)
    territories = {}
    for _, t in ipairs(list or {}) do territories[t.id] = t end
    redrawAllBlips()
end)

RegisterNetEvent('nova_convoytruck:territory:client:upsert', function(list)
    for _, v in ipairs(list or {}) do
        territories[v.id] = lightOf(v)
        drawBlip(territories[v.id])
    end
    SendNUIMessage({ action = 'territory:upsert', territories = list })
end)

-- Players who are not in a gang get only the world side (blip, ground ring, leader ped) — Config.Territory.visibleTo
RegisterNetEvent('nova_convoytruck:territory:client:upsertWorld', function(list)
    for _, v in ipairs(list or {}) do
        territories[v.id] = v
        drawBlip(v)
    end
end)

RegisterNetEvent('nova_convoytruck:territory:client:remove', function(id)
    territories[id] = nil
    removeBlip(id)
    if removeLeaderPed then removeLeaderPed(id) end
    SendNUIMessage({ action = 'territory:remove', id = id })
end)

RegisterNetEvent('nova_convoytruck:territory:client:xp', function(payload)
    SendNUIMessage({ action = 'territory:xp', gang = payload.gang, total = payload.total, lifetime = payload.lifetime })
end)

RegisterNetEvent('nova_convoytruck:territory:client:xpBoard', function(rows)
    SendNUIMessage({ action = 'territory:xpBoard', gangs = rows })
end)

RegisterNetEvent('nova_convoytruck:territory:client:rivalsChanged', function()
    SendNUIMessage({ action = 'territory:rivalsChanged' })
end)

RegisterNetEvent('nova_convoytruck:territory:client:notify', function(n)
    if type(n) ~= 'table' then return end
    local kind = 'inform'
    if n.kind == 'rival' or n.kind == 'challenge' or n.kind == 'war-reminder' or n.kind == 'capture' then kind = 'warning'
    elseif n.kind == 'expansion' or n.kind == 'challenge-accepted' or n.kind == 'auction-won' then kind = 'success'
    elseif n.kind == 'war-cancelled' or n.kind == 'challenge-declined' then kind = 'error' end
    notify(kind, n.title, n.message, 11000)
    NovaSound.territoryNotice(n.kind)
    SendNUIMessage({ action = 'territory:toast', kind = n.kind, title = n.title, message = n.message, rivalId = n.rivalId })
end)

-- ── ground markers (a ring in the territory's colour near each territory) ────────

CreateThread(function()
    while true do
        local mk = cfg().worldMarker or {}
        local sleep = 800
        if mk.enabled ~= false and next(territories) then
            local pos = GetEntityCoords(PlayerPedId())
            local range = tonumber(mk.drawDistance) or 150.0
            for _, t in pairs(territories) do
                -- the ring sits UNDER the leader ped (where the ped really stands), not at the territory centre
                local at = (t.ped and t.ped.x and t.ped) or t.location or t.center
                if at and at.x then
                    local d = #(pos - vec3(at.x + 0.0, at.y + 0.0, pos.z))
                    if d < range then
                        sleep = 0
                        local r, g, b = hexToRgb(t.ownerAccent or t.color)      -- the owning gang's colour
                        -- the ground height is looked up once per territory while it is near (not every frame)
                        if not t.gz then
                            local found, gz = GetGroundZFor_3dCoord(at.x + 0.0, at.y + 0.0, (at.z or pos.z) + 50.0, false)
                            if found then t.gz = gz end
                        end
                        DrawMarker(tonumber(mk.type) or 1, at.x + 0.0, at.y + 0.0, (t.gz or at.z or pos.z) + 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            (tonumber(mk.size) or 6.0) * 1.0, (tonumber(mk.size) or 6.0) * 1.0, tonumber(mk.height) or 1.2, r, g, b, tonumber(mk.alpha) or 110, false, false, 2, false, nil, nil, false)
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

-- ── the auction house ────────────────────────────────────────────────────────────

local bid = { open = false, opening = false, reqId = nil, seq = 0, territoryId = nil, version = 0, lastPress = 0 }
local BID_TIMEOUT_MS = tonumber(((Config.ContainerWars or {}).bidding or {}).requestTimeoutMs) or 5000

local function closeBidder()
    if bid.open then
        bid.open = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'bidder:close' })
    end
end

-- The zone that is being bid on right now is made impossible to miss on the map: a big, bright, flashing blip on its centre
-- and a flashing circle over its area (both also show on the minimap). They last as long as the bidding on that zone.
local spot = { id = nil, blip = nil, area = nil, calm = nil }

local function clearSpotlight()
    if spot.blip and DoesBlipExist(spot.blip) then RemoveBlip(spot.blip) end
    if spot.area and DoesBlipExist(spot.area) then RemoveBlip(spot.area) end
    spot.id, spot.blip, spot.area, spot.calm = nil, nil, nil, nil
end

local function removeAuctionWorld()
    closeBidder()
    clearSpotlight()
    if auctionBlip and DoesBlipExist(auctionBlip) then RemoveBlip(auctionBlip) end
    auctionBlip = nil
end

local function openBidder()
    if not auction or bid.open or bid.opening then return end
    local now = GetGameTimer()
    if now - bid.lastPress < 400 then return end
    bid.lastPress = now
    bid.opening = true
    local token = now
    SetTimeout(BID_TIMEOUT_MS, function()
        if bid.opening and bid.token == token then
            bid.opening = false
            notify('error', 'TERRITORY AUCTION', 'Bid request timed out')
        end
    end)
    bid.token = token
    lib.callback('nova_convoytruck:territory:bidInfo', false, function(info)
        if not (bid.opening and bid.token == token) then return end
        bid.opening = false
        if not info or not info.ok then
            notify('error', 'TERRITORY AUCTION', (info and info.message) or 'You cannot bid right now.')
            return
        end
        bid.open, bid.territoryId, bid.version = true, info.territoryId, info.version
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = 'bidder:open', containerId = info.territoryId, containerNumber = info.lotNumber, lotName = info.lotName,
            currentBid = info.currentBid, minimumBid = info.minimumBid, increment = info.increment, gang = info.gang, canBid = info.canBid,
            eyebrow = 'Gang Territory Auction', submitEvent = 'territory:submitBid', closeEvent = 'territory:closeBidder',
        })
    end, auction.eventId, auction.lot and auction.lot.territoryId or nil)
end

-- The auction house is just a zone (the bidder opens with a key while you stand in it) and a map blip. The projector prop
-- is NOT interactive: the server spawns / removes it, and it only anchors where the floating auction panel is shown.
local function buildAuctionWorld()
    removeAuctionWorld()
    if not auction or not auction.location then return end
    local loc = auction.location
    local ab = (cfg().auction or {}).blip or {}
    auctionBlip = AddBlipForCoord(loc.x + 0.0, loc.y + 0.0, (loc.z or 0.0) + 0.0)
    SetBlipSprite(auctionBlip, tonumber(ab.sprite) or 500)
    SetBlipColour(auctionBlip, tonumber(ab.colour) or 5)
    SetBlipScale(auctionBlip, tonumber(ab.scale) or 0.95)
    SetBlipAsShortRange(auctionBlip, false)
    setBlipLabel(auctionBlip, ab.label or 'Territory Auction')
end

-- The bidding range is the PERIMETER the admin drew in Auction Setup (the server checks the same polygon when a bid arrives). Only an
-- event without a drawn perimeter falls back to a circle of zoneRadius metres around the auction location.
local function insidePolygon(x, y, pts)
    local inside, j = false, #pts
    for i = 1, #pts do
        local xi, yi, xj, yj = pts[i].x, pts[i].y, pts[j].x, pts[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / ((yj - yi) ~= 0 and (yj - yi) or 1e-9) + xi) then inside = not inside end
        j = i
    end
    return inside
end

local function distToPolygon(x, y, pts)
    local best, j = math.huge, #pts
    for i = 1, #pts do
        local ax, ay, bx, by = pts[j].x, pts[j].y, pts[i].x, pts[i].y
        local abx, aby = bx - ax, by - ay
        local l2 = abx * abx + aby * aby
        local u = l2 > 0 and math.max(0.0, math.min(1.0, ((x - ax) * abx + (y - ay) * aby) / l2)) or 0.0
        local d = math.sqrt((x - (ax + u * abx)) ^ 2 + (y - (ay + u * aby)) ^ 2)
        if d < best then best = d end
        j = i
    end
    return best
end

local function inAuctionZone()
    if not auction then return false end
    local p = GetEntityCoords(PlayerPedId())
    local pts = auction.zone
    if type(pts) == 'table' and #pts >= 3 then
        if not insidePolygon(p.x, p.y, pts) then return false end
        return math.abs(p.z - (pts[1].z or p.z)) <= 25.0
    end
    if not auction.location then return false end
    local loc = auction.location
    local dx, dy = p.x - loc.x, p.y - loc.y
    local r = tonumber(auction.zoneRadius) or 12.0
    return (dx * dx + dy * dy) <= r * r
end

-- how far outside the bidding range the player stands (0 = inside); the open bidder closes when it is more than a few metres
local function metresOutsideZone()
    if not auction then return 0.0 end
    local p = GetEntityCoords(PlayerPedId())
    local pts = auction.zone
    if type(pts) == 'table' and #pts >= 3 then
        if insidePolygon(p.x, p.y, pts) then return 0.0 end
        return distToPolygon(p.x, p.y, pts)
    end
    if not auction.location then return 0.0 end
    local loc = auction.location
    return math.max(0.0, math.sqrt((p.x - loc.x) ^ 2 + (p.y - loc.y) ^ 2) - (tonumber(auction.zoneRadius) or 12.0))
end

-- ── the auction board: a hologram screen over the projector ─────────────────────────
-- The board is a web page (web/src/AuctionDui.svelte, loaded with ?dui=auction). The game renders it into a texture (a DUI)
-- and this thread draws that texture in the world as an upright screen over the projector, always turned toward the viewer,
-- while the player is within viewDistance. The DUI exists only while someone is near it. Nothing is drawn on the player's
-- own screen. The page gets the same state messages the normal UI would, forwarded with SendDuiMessage.
local tv = { dui = nil, txd = nil, tex = nil, ready = false, canBid = nil }
local tvSeq = 0

-- scale: the admin's "screen size" for this event (Projectors tab); 1.0 = the width / height in Config.Territory.auction.screen
local function tvConfig(scale)
    local s = (cfg().auction or {}).screen or {}
    local k = math.min(tonumber(s.maxScale) or 3.0, math.max(tonumber(s.minScale) or 0.4, tonumber(scale) or 1.0))
    return {
        width = (tonumber(s.width) or 6.4) * k, height = (tonumber(s.height) or 3.6) * k, lift = tonumber(s.lift) or 3.0,
        alpha = math.floor(math.min(255, math.max(40, tonumber(s.alpha) or 245))),
        pw = math.floor(tonumber(s.pixelWidth) or 1600), ph = math.floor(tonumber(s.pixelHeight) or 900),
    }
end

local function tvSend(msg)
    if tv.dui and tv.ready then SendDuiMessage(tv.dui, json.encode(msg)) end
end

-- the whole picture (state + whether this player can bid from where they stand)
local function tvPush()
    if not (tv.dui and tv.ready and auction) then return end
    tv.canBid = inAuctionZone()
    tvSend({ action = 'territory:auctionState', state = auction })
    tvSend({ action = 'territory:auctionView', visible = true, canBid = tv.canBid })
end

local function tvDestroy()
    if tv.dui then DestroyDui(tv.dui) end
    tv.dui, tv.tex, tv.ready, tv.canBid = nil, nil, false, nil
end

local function tvCreate()
    local c = tvConfig()
    tvSeq = tvSeq + 1
    tv.tex = ('screen_%d'):format(tvSeq)                          -- a fresh texture name each time: the old one belonged to a destroyed DUI
    tv.txd = tv.txd or CreateRuntimeTxd('nova_auction_tv')
    tv.dui = CreateDui(('nui://%s/html/index.html?dui=auction'):format(GetCurrentResourceName()), c.pw, c.ph)
    CreateRuntimeTextureFromDuiHandle(tv.txd, tv.tex, GetDuiHandle(tv.dui))
    tv.ready = false
    local mine = tv.dui
    CreateThread(function()
        local waited = 0
        while tv.dui == mine and not IsDuiAvailable(mine) and waited < 10000 do Wait(100); waited = waited + 100 end
        if tv.dui ~= mine then return end
        Wait(700)                                                 -- the page needs a moment to start listening
        if tv.dui ~= mine then return end
        tv.ready = true
        tvPush()
        Wait(2500)                                                -- and once more, in case the first message arrived early
        if tv.dui == mine then tvPush() end
    end)
end

-- The projector prop is a networked object; whoever has control of it first sets it on the REAL ground once (the saved placement is only
-- a height typed in the placer, and the server cannot see the ground), then every client reads where it really stands: its base and its
-- height, so the beam starts at the top of the prop and the board stands above it.
local proj = { ent = nil, checkedAt = 0, base = nil, height = nil }

local function snapProjector(ent)
    if not NetworkHasControlOfEntity(ent) then NetworkRequestControlOfEntity(ent) return end   -- retried on the next check
    local c = GetEntityCoords(ent)
    local mn = GetModelDimensions(GetEntityModel(ent))
    RequestCollisionAtCoord(c.x, c.y, c.z)
    SetEntityCollision(ent, false, false)   -- so the probe does not land on the prop itself
    local found, gz = false, 0.0
    for _, lift in ipairs({ 4.0, 1.5 }) do
        found, gz = GetGroundZFor_3dCoord(c.x, c.y, c.z + lift, false)
        if found then break end
    end
    SetEntityCollision(ent, true, true)
    if found and math.abs(gz - (c.z + mn.z)) < 15.0 then
        SetEntityCoordsNoOffset(ent, c.x, c.y, gz - mn.z, false, false, false)
        FreezeEntityPosition(ent, true)
    end
    Entity(ent).state:set('nova_proj_snapped', true, true)
end

local function projectorFrame(at)
    local now = GetGameTimer()
    if now - proj.checkedAt > 1000 then
        proj.checkedAt = now
        local found
        for _, o in ipairs(GetGamePool('CObject')) do
            if NetworkGetEntityIsNetworked(o) and Entity(o).state.nova_territory_projector then found = o break end
        end
        proj.ent = found
        if found then
            if not Entity(found).state.nova_proj_snapped then snapProjector(found) end
            local mn, mx = GetModelDimensions(GetEntityModel(found))
            local c = GetEntityCoords(found)
            proj.base, proj.height = vector3(c.x, c.y, c.z + mn.z), mx.z - mn.z
        else
            proj.base, proj.height = nil, nil
        end
    end
    if proj.ent and DoesEntityExist(proj.ent) and proj.base then
        -- the lamp: a point in the prop's own frame (a tilted work light carries its lamp in front of and above its middle)
        local mn, mx = GetModelDimensions(GetEntityModel(proj.ent))
        local o = (cfg().auction or {}).lensOffset or {}
        local ox, oy = proj.lensX or tonumber(o.x) or 0.0, proj.lensY or tonumber(o.y) or 0.0
        local oz = proj.lensZ or tonumber(o.z) or (mx.z * 0.92)
        return proj.base, proj.height, GetOffsetFromEntityInWorldCoords(proj.ent, ox, oy, oz)
    end
    return at, nil, nil
end

-- /projlens <x> <y> <z>: moves the lamp of the projector in front of you (until the next restart) and prints the line for config.lua
RegisterCommand('projlens', function(_, args)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (x and y and z) then print('[projlens] usage: /projlens <x> <y> <z>  (metres in the prop own frame: +y = the way it faces, +z = up)') return end
    proj.lensX, proj.lensY, proj.lensZ = x, y, z
    print(('[projlens] paste into Config.Territory.auction:  lensOffset = { x = %.2f, y = %.2f, z = %.2f },'):format(x, y, z))
end, false)

-- Two triangles, drawn with both windings so the screen shows whichever way the game culls them. `at` is the projector's base.
local function tvDraw(at, c, height, lensPos)
    local cam = GetGameplayCamCoord()
    local fx, fy = at.x - cam.x, at.y - cam.y
    local len = math.sqrt(fx * fx + fy * fy)
    if len < 0.4 then return end
    fx, fy = fx / len, fy / len
    local rx, ry = fy, -fx                                        -- the viewer's right, so the screen always faces them
    local hw = c.width * 0.5
    local lx, ly, rx2, ry2 = at.x - rx * hw, at.y - ry * hw, at.x + rx * hw, at.y + ry * hw
    local b = ((cfg().auction or {}).beam) or {}
    local lensZ = lensPos and lensPos.z or (at.z + (height and height * 0.92 or (tonumber(b.lensLift) or 0.9)))   -- the lamp
    local z0 = math.max(at.z + c.lift, lensZ + 0.8)
    local z1 = z0 + c.height
    local a, dict, tex = c.alpha, 'nova_auction_tv', tv.tex
    local function drawBoard()
    DrawSpritePoly(lx, ly, z1, rx2, ry2, z1, lx, ly, z0, 255, 255, 255, a, dict, tex, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 1.0)
    DrawSpritePoly(rx2, ry2, z1, rx2, ry2, z0, lx, ly, z0, 255, 255, 255, a, dict, tex, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0)
    DrawSpritePoly(lx, ly, z1, lx, ly, z0, rx2, ry2, z1, 255, 255, 255, a, dict, tex, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0, 1.0)
    DrawSpritePoly(rx2, ry2, z1, lx, ly, z0, rx2, ry2, z0, 255, 255, 255, a, dict, tex, 1.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0)
    end

    -- The projector beam: light thrown from the lamp at the top of the prop onto the WHOLE board, like a real projector - a pyramid from the
    -- lens to the four corners of the screen, drawn as soft see-through layers that are brightest at the lens and fade towards the board.
    -- It takes the colour of the zone being bid on. No outlines, no marker: only light.
    if b.enabled ~= false then
        local lens = lensPos or vector3(at.x, at.y, lensZ)
        local cr, cg, cb = 196, 94, 224
        -- the colour the territory wears on the map: its owning gang's colour, else the territory's own, else the lot's
        local terr = auction and auction.lot and territories[auction.lot.territoryId]
        local col = (terr and (terr.ownerAccent or terr.color)) or (auction and auction.lot and auction.lot.color)
        if col then cr, cg, cb = hexToRgb(col, { 196, 94, 224 }) end
        if type(b.colour) == 'table' then cr, cg, cb = b.colour[1] or cr, b.colour[2] or cg, b.colour[3] or cb end
        local baseA = math.floor(math.min(120, math.max(4, tonumber(b.alpha) or 34)))
        local corners = {
            vector3(lx, ly, z0), vector3(rx2, ry2, z0), vector3(rx2, ry2, z1), vector3(lx, ly, z1),
        }
        local bands = 8
        local function at_(p, t) return lens.x + (p.x - lens.x) * t, lens.y + (p.y - lens.y) * t, lens.z + (p.z - lens.z) * t end
        for face = 1, 4 do
            local pA, pB = corners[face], corners[face % 4 + 1]
            for i = 0, bands - 1 do
                local t0, t1 = i / bands, (i + 1) / bands
                local ax, ay, az = at_(pA, t0)
                local bx, by, bz = at_(pB, t0)
                local cx, cy, cz = at_(pA, t1)
                local dx, dy, dz = at_(pB, t1)
                local fall = (1.0 - t0) ^ 2                      -- the light dies away before it reaches the board: the board stays bright and crisp
                local al = math.floor(baseA * fall)
                DrawPoly(ax, ay, az, bx, by, bz, cx, cy, cz, cr, cg, cb, al)
                DrawPoly(bx, by, bz, dx, dy, dz, cx, cy, cz, cr, cg, cb, al)
                DrawPoly(cx, cy, cz, bx, by, bz, ax, ay, az, cr, cg, cb, al)
                DrawPoly(cx, cy, cz, dx, dy, dz, bx, by, bz, cr, cg, cb, al)
            end
        end
        DrawLightWithRange(lens.x, lens.y, lens.z, cr, cg, cb, tonumber(b.lightRange) or 3.0, tonumber(b.lightIntensity) or 0.35)
    end
    drawBoard()                                                  -- last, on top of the beam: nothing tints or dims the board
end

CreateThread(function()
    local checkedAt = 0
    while true do
        local at = nil
        if auction and auction.projectorLive and auction.phase ~= 'ENDED' then at = auction.projector or auction.location end
        local near = false
        if at then
            local p = GetEntityCoords(PlayerPedId())
            local dx, dy = p.x - at.x, p.y - at.y
            local range = tonumber(auction.viewDistance) or 80.0
            near = (dx * dx + dy * dy) <= range * range
        end
        if not near then
            if tv.dui then tvDestroy() end
            Wait(500)
        else
            if not tv.dui then tvCreate() end
            if tv.ready then
                local base, height, lensPos = projectorFrame(at)
                tvDraw(base, tvConfig(auction.projectorScale), height, lensPos)
            end
            local now = GetGameTimer()
            if now - checkedAt > 500 then                        -- "press E to bid" appears when the player steps into the zone
                checkedAt = now
                if tv.ready and inAuctionZone() ~= tv.canBid then tvPush() end
            end
            Wait(0)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then tvDestroy() end
end)

-- ── size preview for the admin (Projectors tab → "Preview size in-world") ─────────────────────────────────────────
-- The tablet steps aside and a see-through board of the chosen size is drawn where the projector stands (with a 1.8 m mark to read
-- the scale from), then the tablet comes back. The real board is drawn the same way (see tvDraw), so what you see here is what players see.
RegisterNUICallback('territory:previewScreen', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' or not tonumber(data.x) or not tonumber(data.y) or not tonumber(data.z) then return end
    local c = tvConfig(data.scale)
    local at = vector3(data.x + 0.0, data.y + 0.0, data.z + 0.0)
    local untilAt = GetGameTimer() + 25000
    local handler = AddEventHandler('nova_convoytruck:client:tabletRestored', function() untilAt = 0 end)   -- ENTER / the tablet key ends the preview at once
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    CreateThread(function()
        while GetGameTimer() < untilAt do
            local cam = GetGameplayCamCoord()
            local fx, fy = at.x - cam.x, at.y - cam.y
            local len = math.sqrt(fx * fx + fy * fy)
            if len > 0.4 then
                fx, fy = fx / len, fy / len
                local rx, ry = fy, -fx
                local hw = c.width * 0.5
                local lx, ly, rx2, ry2 = at.x - rx * hw, at.y - ry * hw, at.x + rx * hw, at.y + ry * hw
                local z0 = at.z + c.lift
                local z1 = z0 + c.height
                -- a firmer see-through fill and thick edges (NovaDraw.line keeps the same thickness on screen at any distance)
                DrawPoly(lx, ly, z1, rx2, ry2, z1, lx, ly, z0, 255, 255, 255, 80)
                DrawPoly(rx2, ry2, z1, rx2, ry2, z0, lx, ly, z0, 255, 255, 255, 80)
                DrawPoly(lx, ly, z0, rx2, ry2, z1, lx, ly, z1, 255, 255, 255, 80)
                DrawPoly(lx, ly, z0, rx2, ry2, z0, rx2, ry2, z1, 255, 255, 255, 80)
                NovaDraw.line(lx, ly, z0, rx2, ry2, z0, 255, 255, 255, 255, 3.5); NovaDraw.line(rx2, ry2, z0, rx2, ry2, z1, 255, 255, 255, 255, 3.5)
                NovaDraw.line(rx2, ry2, z1, lx, ly, z1, 255, 255, 255, 255, 3.5); NovaDraw.line(lx, ly, z1, lx, ly, z0, 255, 255, 255, 255, 3.5)
                NovaDraw.line(lx, ly, z0, rx2, ry2, z1, 255, 255, 255, 120, 1.5); NovaDraw.line(lx, ly, z1, rx2, ry2, z0, 255, 255, 255, 120, 1.5)   -- the diagonals
                NovaDraw.line(at.x, at.y, at.z, at.x, at.y, z0, 255, 255, 255, 220, 3.0)                       -- base to the board
                NovaDraw.line(at.x + rx * 1.2, at.y + ry * 1.2, at.z, at.x + rx * 1.2, at.y + ry * 1.2, at.z + 1.8, 255, 200, 87, 255, 4.0)   -- 1.8 m
                local on, sx, sy = World3dToScreen2d(at.x, at.y, z1 + 0.35)
                if on then
                    SetTextScale(0.0, 0.5); SetTextFont(4); SetTextColour(255, 255, 255, 255); SetTextCentre(true); SetTextOutline()
                    BeginTextCommandDisplayText('STRING')
                    AddTextComponentSubstringPlayerName(('Auction screen %.1f x %.1f m   (%d%%)'):format(c.width, c.height, math.floor((tonumber(data.scale) or 1.0) * 100 + 0.5)))
                    EndTextCommandDisplayText(sx, sy)
                end
            end
            Wait(0)
        end
        RemoveEventHandler(handler)
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
    end)
end)

local bidKey = ((cfg().auction or {}).bidKey) or 'E'
lib.addKeybind({
    name = 'nova_territory_bid', description = 'Territory auction: open the bidder', defaultKey = bidKey,
    onReleased = function()
        if auction and auction.lot and auction.lot.status == 'AUCTION_ACTIVE' and inAuctionZone() then openBidder() end
    end,
})

local function spotlightKey() return ((cfg().auction or {}).mapKey) or 'F7' end

-- Flash the zone that has just come up for bidding (and tell the player how to see it). Called on every auction state.
local function spotlightLot(lot)
    if not lot or lot.status ~= 'AUCTION_ACTIVE' then
        if spot.id then clearSpotlight() end
        return
    end
    if spot.id == lot.territoryId then return end
    clearSpotlight()
    local t = territories[lot.territoryId]
    local x = lot.x or (t and t.center and t.center.x)
    local y = lot.y or (t and t.center and t.center.y)
    if not x or not y then return end
    local z = (t and t.center and t.center.z) or 0.0
    local sc = (cfg().auction or {}).spotlight or {}
    local colour = tonumber(sc.colour) or 5
    spot.id = lot.territoryId

    spot.area = AddBlipForRadius(x + 0.0, y + 0.0, z + 0.0, tonumber(sc.radius) or 140.0)
    SetBlipColour(spot.area, colour)
    SetBlipAlpha(spot.area, tonumber(sc.areaAlpha) or 120)
    SetBlipFlashes(spot.area, true)

    spot.blip = AddBlipForCoord(x + 0.0, y + 0.0, z + 0.0)
    SetBlipSprite(spot.blip, tonumber(sc.sprite) or 310)
    SetBlipColour(spot.blip, colour)
    SetBlipScale(spot.blip, tonumber(sc.scale) or 1.0)
    SetBlipAsShortRange(spot.blip, false)
    SetBlipPriority(spot.blip, 12)
    SetBlipFlashes(spot.blip, true)
    SetBlipFlashInterval(spot.blip, 250)                        -- a fast blink while the zone has just come up ...
    setBlipLabel(spot.blip, ('AUCTION: %s'):format(tostring(lot.name or 'Territory')))
    local mine = spot.blip
    SetTimeout((tonumber(sc.fastSeconds) or 20) * 1000, function()   -- ... then a calmer one for the rest of the bidding
        if spot.blip == mine and DoesBlipExist(mine) then SetBlipFlashInterval(mine, 700) end
    end)

    PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    notify('inform', 'TERRITORY UP FOR BIDDING', ('%s is flashing on your map. Press %s to open the map.'):format(tostring(lot.name or 'A territory'), spotlightKey()), 9000)
end

-- Opens the game map so the flashing zone can be looked at straight away (key set in Config.Territory.auction.mapKey; players
-- can rebind it in the game's key settings).
local function openMapOnZone()
    if not (auction and auction.lot and spot.id) then
        notify('inform', 'TERRITORY AUCTION', 'No territory is up for bidding right now.', 4000)
        return
    end
    if IsPauseMenuActive() then return end
    ActivateFrontendMenu(`FE_MENU_VERSION_MP_PAUSE`, false, -1)
    Wait(150)
    PauseMenuceptionGoDeeper(0)                                 -- straight to the Map tab
end

lib.addKeybind({
    name = 'nova_territory_map', description = 'Territory auction: open the map on the zone being bid on', defaultKey = spotlightKey(),
    onReleased = openMapOnZone,
})

local introUntil, endUntil, introShown = nil, nil, false
CreateThread(function()
    while true do
        -- while bidding runs: how long the WHOLE auction has left (it ends then, whatever lots are still unsold)
        if endUntil and auction and not introUntil and auction.phase ~= 'ENDED' and (auction.phase == 'BIDDING' or auction.phase == 'BREAK' or auction.phase == 'RESULT') then
            local left = math.max(0, math.ceil((endUntil - GetGameTimer()) / 1000))
            local sold, total = 0, #(auction.lots or {})
            for _, l in ipairs(auction.lots or {}) do if l.status == 'WON' then sold = sold + 1 end end
            SendNUIMessage({ action = 'cwTimer:frame', visible = true, tone = left <= 120 and 'warn' or 'live', title = 'TERRITORY AUCTION', label = 'AUCTION ENDS IN', seconds = left, sub = ('%d of %d territories sold'):format(sold, total) })
            introShown = true
            Wait(250)
        elseif introUntil and auction then
            local left = math.max(0, math.ceil((introUntil - GetGameTimer()) / 1000))
            if left > 0 then
                SendNUIMessage({ action = 'cwTimer:frame', visible = true, tone = 'wait', title = 'TERRITORY AUCTION', label = 'AUCTION STARTS IN', seconds = left, sub = ('%d territor%s up for auction'):format(#(auction.lots or {}), #(auction.lots or {}) == 1 and 'y' or 'ies') })
                introShown = true
                Wait(250)
            else
                introUntil = nil
            end
        else
            if introShown then SendNUIMessage({ action = 'cwTimer:frame', visible = false }) introShown = false end
            Wait(500)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:territory:client:auctionState', function(state)
    local first = auction == nil or auction.eventId ~= (state and state.eventId)
    auction = state
    -- the 'auction starts in' timer: the server says how many seconds of the opening buffer are left, this client counts them down
    introUntil = (state and (tonumber(state.introLeft) or 0) > 0) and (GetGameTimer() + math.floor(state.introLeft * 1000)) or nil
    endUntil = (state and (tonumber(state.endsIn) or 0) > 0) and (GetGameTimer() + math.floor(state.endsIn * 1000)) or nil
    if first then buildAuctionWorld() end
    spotlightLot(state and state.lot or nil)
    SendNUIMessage({ action = 'territory:auctionState', state = state })
    tvPush()             -- the board in the world follows every change
end)
-- an admin changed the price of painting land: every open Map Zone re-prices at once
RegisterNetEvent('nova_convoytruck:territory:client:paintConfig', function(paint)
    SendNUIMessage({ action = 'territory:paintConfig', paint = paint })
end)

RegisterNetEvent('nova_convoytruck:territory:client:auctionTick', function(t)
    if not auction or not auction.lot or auction.lot.territoryId ~= t.territoryId then return end
    local l = auction.lot
    l.timeRemaining, l.currentBid, l.version = t.timeRemaining, t.currentBid, t.version
    l.leadingGang, l.leadingGangLabel, l.leadingPlayer = t.leadingGang, t.leadingGangLabel, t.leadingPlayer
    auction.endsIn = t.endsIn
    if bid.open and bid.territoryId == t.territoryId then bid.version = t.version end
    SendNUIMessage({ action = 'territory:auctionTick', tick = t })
    tvSend({ action = 'territory:auctionTick', tick = t })
end)

-- ── bid animation over the bidder's head ─────────────────────────────────────────────
-- When a gang member places a bid, everyone nearby sees a pulsing ring, a spinning arrow and "BID $amount" above that player for a few
-- seconds, in their gang's colour. Config.Territory.auction.bidFx = { enabled, seconds, range }.
local bidFx = {}      -- [serverId] = { untilAt, amount, label, r, g, b }

local function bidFxCfg() return ((cfg().auction or {}).bidFx) or {} end

local function drawText3d(x, y, z, text, r, g, b, scale)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.0, scale)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(r, g, b, 255)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

-- The bid tag over a bidder's head: a small dark glass card in the gang's colour (accent bar on the left, soft edge, a thin stem down to the
-- head) with the gang name in small type and the amount large. It pops in, floats a little and fades out. Drawn in screen space at the
-- head's position, so it scales down with distance and never turns away from the viewer.
local function cardText(str, x, y, size, r, g, b, a)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextScale(0.0, size)
    SetTextColour(r, g, b, a)
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

local function drawBidCard(x, y, z, amount, label, r, g, b, fade, k)
    SetDrawOrigin(x, y, z, 0)
    local w, h = 0.088 * k, 0.052 * k
    local A = math.floor(255 * fade)
    DrawRect(0.0, 0.0, w + 0.0016, h + 0.0028, r, g, b, math.floor(80 * fade))              -- soft edge in the gang's colour
    DrawRect(0.0, 0.0, w, h, 13, 16, 22, math.floor(230 * fade))                           -- the glass body
    DrawRect(-w * 0.5 + 0.0022 * k, 0.0, 0.0040 * k, h, r, g, b, A)                          -- accent bar
    DrawRect(0.0, h * 0.5 + 0.0070 * k, 0.0012, 0.0120 * k, r, g, b, math.floor(200 * fade)) -- stem down to the head
    cardText(string.upper(label and label ~= '' and ('BID  ·  ' .. label) or 'BID'), 0.0036 * k, -h * 0.40, 0.26 * k, 170, 178, 192, A)
    cardText(('$%s'):format(tostring(amount)), 0.0036 * k, -h * 0.20, 0.56 * k, 255, 255, 255, A)
    ClearDrawOrigin()
end

-- The tag over a territory's leader ped (a small compact card): a square in the gang's colour, the gang's name and its Gang XP.
-- (The territory name is not on it any more.) Only drawn within a few metres of the ped, from a thread that sleeps (500 ms) whenever no leader ped is that close.
local function drawGangTag(x, y, z, title, _unused, xpText, r, g, b, k)
    SetDrawOrigin(x, y, z, 0)
    if #title > 18 then title = title:sub(1, 17) .. '…' end
    local w, h = 0.082 * k, 0.036 * k
    DrawRect(0.0, 0.0, w + 0.0014, h + 0.0024, r, g, b, 70)                       -- soft edge
    DrawRect(0.0, 0.0, w, h, 13, 16, 22, 232)                                       -- the glass body
    -- the gang's colour as a small square at the left (about square on a 16:9 screen)
    local sw, sh = 0.0090 * k, 0.0160 * k
    DrawRect(-w * 0.5 + 0.0070 * k + sw * 0.5, 0.0, sw + 0.0010, sh + 0.0018, 255, 255, 255, 90)   -- its thin light frame
    DrawRect(-w * 0.5 + 0.0070 * k + sw * 0.5, 0.0, sw, sh, r, g, b, 255)
    cardText(title, 0.0095 * k, -h * 0.40, 0.33 * k, 255, 255, 255, 255)           -- gang name
    if xpText then cardText(xpText, 0.0095 * k, h * 0.02, 0.25 * k, 190, 198, 212, 255) end   -- Gang XP
    DrawRect(0.0, h * 0.5 + 0.0050 * k, 0.0010, 0.0090 * k, r, g, b, 190)           -- stem to the head
    ClearDrawOrigin()
end

local bidFxRunning = false
local function runBidFx()
    if bidFxRunning then return end
    bidFxRunning = true
    CreateThread(function()
        while true do
            local now = GetGameTimer()
            local any, me = false, GetEntityCoords(PlayerPedId())
            local range = tonumber(bidFxCfg().range) or 60.0
            for id, fx in pairs(bidFx) do
                if now >= fx.untilAt then
                    bidFx[id] = nil
                else
                    any = true
                    local pl = GetPlayerFromServerId(id)
                    local ped = pl ~= -1 and GetPlayerPed(pl) or 0
                    if ped ~= 0 and DoesEntityExist(ped) then
                        local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)            -- SKEL_Head
                        local dx, dy, dz = head.x - me.x, head.y - me.y, head.z - me.z
                        if dx * dx + dy * dy + dz * dz <= range * range then
                            local life = 1.0 - (fx.untilAt - now) / fx.total             -- 0 -> 1 over the effect
                            local pulse = (now % 900) / 900.0                            -- one ring every 0.9 s
                            local bob = math.sin(now / 260.0) * 0.06
                            local fade = life > 0.8 and (1.0 - (life - 0.8) / 0.2) or 1.0
                            local a = math.floor(255 * fade)
                            local base = head.z + 0.62 + bob
                            -- a soft ring that grows and fades, flat above the head (the only 3D part)
                            local s = 0.35 + pulse * 0.9
                            DrawMarker(25, head.x, head.y, head.z + 0.42, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, s, s, 0.4, fx.r, fx.g, fx.b, math.floor((1.0 - pulse) * 110 * fade), false, false, 2, false, nil, nil, false)
                            -- the tag pops in over the first 0.4 s, and shrinks a little with distance
                            local pop = math.min(1.0, life * fx.total / 400.0)
                            local ease = 1.0 - (1.0 - pop) ^ 3
                            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                            local k = math.max(0.5, math.min(1.0, 12.0 / math.max(dist, 1.0))) * (0.7 + 0.3 * ease)
                            drawBidCard(head.x, head.y, base, fx.amount, fx.label, fx.r, fx.g, fx.b, fade * ease, k)
                        end
                    end
                end
            end
            if not any then bidFxRunning = false return end
            Wait(0)
        end
    end)
end

local function commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

RegisterNetEvent('nova_convoytruck:territory:client:bidUpdate', function(d)
    if auction and auction.lot and auction.lot.territoryId == d.territoryId then
        auction.lot.currentBid, auction.lot.version = d.currentBid, d.version
    end
    local fxc = bidFxCfg()
    if fxc.enabled ~= false and d.bidderSource then
        local secs = tonumber(fxc.seconds) or 6.0
        local r, g, b = 255, 200, 87
        if auction and auction.lot and auction.lot.color then r, g, b = hexToRgb(auction.lot.color, { 255, 200, 87 }) end
        bidFx[d.bidderSource] = { untilAt = GetGameTimer() + math.floor(secs * 1000), total = secs * 1000.0, amount = commas(d.currentBid), label = d.leadingGangLabel, r = r, g = g, b = b }
        runBidFx()
    end
    if bid.open and bid.territoryId == d.territoryId then
        bid.version = d.version
        SendNUIMessage({ action = 'bidder:update', currentBid = d.currentBid, minimumBid = d.minimumBid, increment = auction and auction.lot and auction.lot.increment, canBid = true })
    end
    SendNUIMessage({ action = 'territory:auctionTick', tick = d })
    tvSend({ action = 'territory:auctionTick', tick = d })
end)

RegisterNetEvent('nova_convoytruck:territory:client:auctionEnded', function()
    auction, introUntil, endUntil = nil, nil, nil
    removeAuctionWorld()
    tvDestroy()
    SendNUIMessage({ action = 'territory:auctionEnded' })
end)

RegisterNUICallback('territory:closeBidder', function(_, cb)
    closeBidder()
    cb('ok')
end)

RegisterNUICallback('territory:submitBid', function(data, cb)
    if bid.reqId then return cb({ ok = false, message = 'Your previous bid is still being processed.' }) end
    if not (bid.open and auction and auction.lot and auction.lot.territoryId == bid.territoryId) then
        return cb({ ok = false, message = 'Bidding is not available.' })
    end
    local amount = math.floor(tonumber(data and data.amount) or 0)
    if amount <= 0 then return cb({ ok = false, message = 'Enter a valid bid amount.' }) end
    bid.seq = bid.seq + 1
    local reqId = ('%d-%d'):format(GetPlayerServerId(PlayerId()), bid.seq)
    bid.reqId = reqId
    -- the version we last saw: the server rejects the bid if the auction has moved on since
    TriggerServerEvent('nova_convoytruck:territory:server:placeBid', auction.eventId, bid.territoryId, amount, bid.version, reqId)
    cb({ ok = true })
    SetTimeout(BID_TIMEOUT_MS, function()
        if bid.reqId == reqId then
            bid.reqId = nil
            if bid.open then SendNUIMessage({ action = 'bidder:rejected', message = 'Bid request timed out' }) end
        end
    end)
end)

RegisterNetEvent('nova_convoytruck:territory:client:bidResult', function(res)
    if not res then return end
    if res.version and res.territoryId == bid.territoryId then bid.version = res.version end
    if res.reqId ~= bid.reqId then
        if res.ok then notify('success', 'TERRITORY AUCTION', res.message or 'Bid placed.') end
        return
    end
    bid.reqId = nil
    if res.ok then
        SendNUIMessage({ action = 'bidder:accepted' })
        closeBidder()
        notify('success', 'TERRITORY AUCTION', res.message or 'Bid placed.')
    else
        PlaySoundFrontend(-1, 'ERROR', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
        if bid.open then
            SendNUIMessage({ action = 'bidder:rejected', message = res.message, currentBid = res.currentBid, minimumBid = res.minimumBid, increment = res.increment, canBid = res.canBid })
        else
            notify('error', 'TERRITORY AUCTION', res.message or 'Bid rejected.')
        end
    end
end)

-- walking away from the auction house closes the window (the server would refuse the bid anyway)
CreateThread(function()
    while true do
        Wait(1000)
        if bid.open and auction and (auction.location or auction.zone) then
            if metresOutsideZone() > 8.0 then closeBidder() end
        end
    end
end)

-- ── territory war: leader ped, props, "Take Territory", HUD ──────────────────────

-- The height of the real surface at x, y (nil when the game cannot tell yet). It looks from just above the saved point first, so a
-- roof or a bridge higher up is not picked over the street the ped was placed on; a wider search is the fallback.
local function surfaceZ(x, y, z)
    RequestCollisionAtCoord(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
    local deadline = GetGameTimer() + 2500
    local from = z or 50.0
    while GetGameTimer() < deadline do
        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, from + 3.0, false)
        if not found then found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, from + 40.0, false) end
        if found then return gz end
        Wait(50)
    end
    return nil
end

-- Where to create a ped so it STANDS on the surface. CreatePed takes the height of the ground under the feet. The surface height is
-- used as it is; only a saved player position (about 1 m above the ground, taken with GetEntityCoords) needs the 1 m taken off.
local function pedBaseZ(x, y, z)
    local gz = surfaceZ(x, y, z)
    if gz then return gz end
    return (z or 0.0) - 1.0
end

local function clearWarWorld()
    if warPed and DoesEntityExist(warPed) then
        NovaConvoy.RemoveEntityTarget(warPed)
        DeleteEntity(warPed)
    end
    warPed = nil
    for _, e in ipairs(warProps) do
        if DoesEntityExist(e) then DeleteEntity(e) end
    end
    warProps = {}
    if warBlip and DoesBlipExist(warBlip) then RemoveBlip(warBlip) end
    warBlip = nil
    if warRadiusBlip and DoesBlipExist(warRadiusBlip) then RemoveBlip(warRadiusBlip) end
    warRadiusBlip = nil
    myEliminated = false
    SendNUIMessage({ action = 'territory:outOfBounds', active = false })
    SendNUIMessage({ action = 'territory:eliminatedBlocked', active = false })
end

local function spawnProp(p)
    local model = joaat(p.model)
    if not IsModelInCdimage(model) then return end
    lib.requestModel(model)
    local rx, ry, rz = tonumber(p.rx) or 0.0, tonumber(p.ry) or 0.0, tonumber(p.heading) or 0.0
    local pieces = (p.kind == 'vehicle') and 1 or math.max(1, math.min(10, math.floor(tonumber(p.stack) or 1)))
    local step = tonumber(p.step) or 2.6
    for k = 0, pieces - 1 do
        local ent
        if p.kind == 'vehicle' then
            ent = CreateVehicle(model, p.x + 0.0, p.y + 0.0, p.z + 0.0, rz + 0.0, false, false)
            if ent and ent ~= 0 then
                SetVehicleDoorsLocked(ent, 10); SetVehicleEngineOn(ent, false, true, true); SetEntityInvincible(ent, true)
            end
        else
            ent = CreateObjectNoOffset(model, p.x + 0.0, p.y + 0.0, p.z + k * step, false, false, false)
        end
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            if rx ~= 0.0 or ry ~= 0.0 then SetEntityRotation(ent, rx + 0.0, ry + 0.0, rz + 0.0, 2, true) else SetEntityHeading(ent, rz + 0.0) end
            FreezeEntityPosition(ent, true)
            if p.collision == false then SetEntityCollision(ent, false, false) end
            warProps[#warProps + 1] = ent
        end
    end
    SetModelAsNoLongerNeeded(model)
end

-- The war's combat zone: an admin-drawn zone (a circle, or a square: size = half the side) when the server sent one, otherwise the round ring
-- around the capture point. zc = its centre, size = radius / half side.
local function zoneOf(w)
    local rz = (w and w.ringZone) or {}
    local zc = (rz.custom and rz.point) or (w and w.capture and w.capture.point) or rz.point
    return zc, tonumber(rz.radius) or 160.0, (rz.shape == 'square') and 'square' or 'circle'
end

-- draws the zone in the world: a see-through round column, or four walls around a square (one call per frame)
local function drawZoneWorld(zc, r, shape, z, cr, cg, cb, ca)
    if shape == 'square' then
        local x1, y1, x2, y2 = zc.x - r, zc.y - r, zc.x + r, zc.y + r
        local zb, zt = z - 8.0, z + 10.0
        local corners = { { x1, y1 }, { x2, y1 }, { x2, y2 }, { x1, y2 } }
        for i = 1, 4 do
            local a, b = corners[i], corners[i % 4 + 1]
            DrawPoly(a[1], a[2], zt, b[1], b[2], zt, a[1], a[2], zb, cr, cg, cb, ca)
            DrawPoly(b[1], b[2], zt, b[1], b[2], zb, a[1], a[2], zb, cr, cg, cb, ca)
            DrawPoly(a[1], a[2], zb, b[1], b[2], zt, a[1], a[2], zt, cr, cg, cb, ca)
            DrawPoly(a[1], a[2], zb, b[1], b[2], zb, b[1], b[2], zt, cr, cg, cb, ca)
            DrawLine(a[1], a[2], zt, b[1], b[2], zt, cr, cg, cb, 255)
        end
    else
        DrawMarker(1, zc.x + 0.0, zc.y + 0.0, z - 8.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 18.0, cr, cg, cb, ca, false, false, 2, false, nil, nil, false)
    end
end

local function inZone(zc, size, shape, x, y)
    if shape == 'square' then return math.abs(x - zc.x) <= size and math.abs(y - zc.y) <= size end
    local dx, dy = x - zc.x, y - zc.y
    return dx * dx + dy * dy <= size * size
end


-- ── war zone preview for the admin ───────────────────────────────────────────────────────────────────────────────
-- The tablet steps aside and the zone is drawn (green) in the world and on the map for about 30 s, so the admin can walk to its edge and
-- judge it; the tablet comes back by itself. The zone is only drawn for real once that war starts.
RegisterNUICallback('territory:previewWarZone', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' or not tonumber(data.x) or not tonumber(data.y) then return end
    local zc = { x = data.x + 0.0, y = data.y + 0.0, z = (tonumber(data.z) or 0.0) + 0.0 }
    local size = math.max(20.0, tonumber(data.size) or 100.0)
    local shape = data.shape == 'square' and 'square' or 'circle'
    local blip = (shape == 'square') and AddBlipForArea(zc.x, zc.y, zc.z, size * 2.0, size * 2.0) or AddBlipForRadius(zc.x, zc.y, zc.z, size)
    SetBlipColour(blip, 2)
    SetBlipAlpha(blip, 90)
    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')
    local untilAt = GetGameTimer() + 30000
    local handler = AddEventHandler('nova_convoytruck:client:tabletRestored', function() untilAt = 0 end)   -- ENTER / the tablet key ends the preview at once
    CreateThread(function()
        while GetGameTimer() < untilAt do
            if #(GetEntityCoords(PlayerPedId()) - vec3(zc.x, zc.y, zc.z)) < size * 1.5 + 120.0 then
                drawZoneWorld(zc, size, shape, zc.z, 60, 190, 110, 70)
                Wait(0)
            else
                Wait(400)
            end
        end
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        RemoveEventHandler(handler)
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
    end)
end)

local function buildWarWorld()
    clearWarWorld()
    if not war or not war.capture or war.capture.enabled == false then return end
    local cap = war.capture
    local pt = cap.point or {}
    if not pt.x then return end

    -- the capture point on the map, for everyone in the war
    local wb = cap.blip or {}
    warBlip = AddBlipForCoord(pt.x + 0.0, pt.y + 0.0, (pt.z or 0.0) + 0.0)
    SetBlipSprite(warBlip, tonumber(wb.sprite) or 310)
    SetBlipColour(warBlip, tonumber(wb.colour) or 1)
    SetBlipScale(warBlip, tonumber(wb.scale) or 1.0)
    SetBlipAsShortRange(warBlip, false)
    SetBlipFlashes(warBlip, true)
    setBlipLabel(warBlip, wb.label or 'Territory Capture Point')

    -- Big Combat Ring Zone map blip
    local rz = war.ringZone or {}
    local zc, ringRadius, zshape = zoneOf(war)
    zc = zc or pt
    if rz.enabled ~= false and rz.showMapBlip ~= false and ringRadius > 0 then
        if zshape == 'square' then
            warRadiusBlip = AddBlipForArea(zc.x + 0.0, zc.y + 0.0, (zc.z or 0.0) + 0.0, ringRadius * 2.0, ringRadius * 2.0)
        else
            warRadiusBlip = AddBlipForRadius(zc.x + 0.0, zc.y + 0.0, (zc.z or 0.0) + 0.0, ringRadius + 0.0)
        end
        SetBlipColour(warRadiusBlip, tonumber(rz.blipColor) or 1)
        SetBlipAlpha(warRadiusBlip, tonumber(rz.blipAlpha) or 80)
        SetBlipAsShortRange(warRadiusBlip, false)
    end

    local thisWar = war

    -- Combat Ring World Perimeter Marker
    CreateThread(function()
        if rz.enabled == false or rz.drawWorldRing == false then return end
        local r = ringRadius
        local col = rz.worldRingColor or { r = 255, g = 50, b = 50, a = 60 }
        while war == thisWar do
            local playerPed = PlayerPedId()
            local coords = GetEntityCoords(playerPed)
            local dist = #(coords - vec3(zc.x + 0.0, zc.y + 0.0, coords.z))
            if dist < ((zshape == 'square' and r * 1.45 or r) + 70.0) then
                local z = (zc.z or coords.z)
                drawZoneWorld(zc, r, zshape, z, col.r or 255, col.g or 50, col.b or 50, col.a or 60)
                Wait(0)
            else
                Wait(600)
            end
        end
    end)

    -- Out-of-Bounds Enforcement Thread
    CreateThread(function()
        if rz.enabled == false then return end
        local r = ringRadius
        local maxBuffer = tonumber(rz.bufferSeconds) or 35
        local hasEnteredZone = false
        local isOob = false
        local oobSecondsLeft = maxBuffer

        while war == thisWar do
            if (myRole == 'ATTACKER' or myRole == 'DEFENDER') and not myEliminated and not IsEntityDead(PlayerPedId()) then
                local coords = GetEntityCoords(PlayerPedId())
                if inZone(zc, r, zshape, coords.x, coords.y) then
                    if not hasEnteredZone then
                        hasEnteredZone = true
                        PlaySoundFrontend(-1, "CHECKPOINT_PERFECT", "HUD_MINI_GAME_SOUNDS", true)
                        lib.notify({
                            type = 'inform',
                            title = 'RIVAL ZONE',
                            description = 'You entered the combat ring zone. Do not leave the zone during the war!',
                            duration = 7000,
                        })
                    end
                    if isOob then
                        isOob = false
                        oobSecondsLeft = maxBuffer
                        PlaySoundFrontend(-1, "CHECKPOINT_PERFECT", "HUD_MINI_GAME_SOUNDS", true)
                        lib.notify({
                            type = 'success',
                            title = 'RIVAL ZONE',
                            description = 'You returned to the combat zone!',
                            duration = 4000,
                        })
                        SendNUIMessage({ action = 'territory:outOfBounds', active = false })
                    end
                    Wait(800)
                else
                    if hasEnteredZone then
                        if not isOob then
                            isOob = true
                            oobSecondsLeft = maxBuffer
                            PlaySoundFrontend(-1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS", true)
                        end

                        SendNUIMessage({
                            action = 'territory:outOfBounds',
                            active = true,
                            secondsLeft = oobSecondsLeft,
                            maxSeconds = maxBuffer,
                        })

                        PlaySoundFrontend(-1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS", true)

                        if oobSecondsLeft <= 0 then
                            isOob = false
                            SendNUIMessage({ action = 'territory:outOfBounds', active = false })
                            SetEntityHealth(PlayerPedId(), 0)
                            TriggerServerEvent('nova_convoytruck:territory:server:outOfBoundsEliminated', thisWar.warId)
                            lib.notify({
                                type = 'error',
                                title = 'ELIMINATED',
                                description = 'You were eliminated for deserting the rival zone!',
                                duration = 10000,
                            })
                            break
                        end

                        oobSecondsLeft = oobSecondsLeft - 1
                        Wait(1000)
                    else
                        Wait(1000)
                    end
                end
            else
                if isOob then
                    isOob = false
                    SendNUIMessage({ action = 'territory:outOfBounds', active = false })
                end
                Wait(1000)
            end
        end

        SendNUIMessage({ action = 'territory:outOfBounds', active = false })
    end)

    -- the ped and props exist only near the player (local entities: nothing is left standing in the world between wars)
    CreateThread(function()
        local spawned = false
        while war == thisWar do
            local pos = GetEntityCoords(PlayerPedId())
            local d = #(pos - vec3(pt.x + 0.0, pt.y + 0.0, pos.z))
            if d < 110.0 and not spawned then
                spawned = true
                local z = pedBaseZ(pt.x, pt.y, pt.z)
                local model = joaat(cap.model or 'g_m_y_mexgoon_01')
                lib.requestModel(model)
                local ped = CreatePed(4, model, pt.x + 0.0, pt.y + 0.0, z, (cap.ped and cap.ped.heading) or 0.0, false, true)
                if ped and DoesEntityExist(ped) then
                    SetEntityInvincible(ped, true)
                    SetBlockingOfNonTemporaryEvents(ped, true)
                    FreezeEntityPosition(ped, true)
                    SetPedCanRagdoll(ped, false)
                    SetModelAsNoLongerNeeded(model)
                    local a = cap.anim or {}
                    if a.dict and a.dict ~= '' and a.clip and a.clip ~= '' then
                        lib.requestAnimDict(a.dict)
                        TaskPlayAnim(ped, a.dict, a.clip, 8.0, -8.0, -1, 1, 0.0, false, false, false)
                    else
                        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_GUARD_STAND', 0, true)
                    end
                    warPed = ped
                    NovaConvoy.AddEntityTarget(ped, { {
                        label = cap.targetLabel or 'Take Territory', icon = cap.targetIcon or 'fa-solid fa-flag',
                        distance = tonumber(cap.interactDistance) or 2.5,
                        -- only the attackers get the option, and only while this war is live and not eliminated
                        canInteract = function() return war == thisWar and myRole == 'ATTACKER' and not myEliminated end,
                        onSelect = function() TriggerServerEvent('nova_convoytruck:territory:server:beginCapture', thisWar.warId) end,
                    } })
                end
                for _, p in ipairs(cap.props or {}) do
                    if type(p) == 'table' and p.model and p.x and p.y and p.z then pcall(spawnProp, p) end
                end
            elseif d > 220.0 and spawned then
                spawned = false
                if warPed and DoesEntityExist(warPed) then NovaConvoy.RemoveEntityTarget(warPed); DeleteEntity(warPed) end
                warPed = nil
                for _, e in ipairs(warProps) do if DoesEntityExist(e) then DeleteEntity(e) end end
                warProps = {}
            end
            Wait(1000)
        end
    end)
end

-- ── Death & Downed State Detection (One-Life Rule) ──────────────────────────────
CreateThread(function()
    while true do
        if war and (myRole == 'ATTACKER' or myRole == 'DEFENDER') and not myEliminated then
            local ped = PlayerPedId()
            local dead = IsEntityDead(ped) or IsPedFatallyInjured(ped) or (GetEntityHealth(ped) <= 100)
            if not dead then
                local st = LocalPlayer.state
                if st.isDead == true or st.dead == true or st.isDowned == true or st.inLastStand == true then
                    dead = true
                end
            end
            if dead then
                myEliminated = true
                TriggerServerEvent('nova_convoytruck:territory:server:playerDiedInWar', war.warId)
                SendNUIMessage({
                    action = 'territory:eliminatedState',
                    eliminated = true,
                })
                lib.notify({
                    type = 'error',
                    title = 'ELIMINATED',
                    description = 'You have fallen and are eliminated from this rival war! Revived players cannot re-enter the zone.',
                    duration = 10000,
                })
            end
        end
        Wait(500)
    end
end)

-- ── Anti-Re-entry Repulsion & Perimeter Enforcement Thread ──────────────────────
CreateThread(function()
    local lastAlert = 0
    local wasBlocked = false
    while true do
        if war and myEliminated and (myRole == 'ATTACKER' or myRole == 'DEFENDER') then
            local warCfg = (Config.Territory and Config.Territory.war) or {}
            local oneLife = warCfg.oneLife or {}
            local zc, ringR, zshape = zoneOf(war)
            local pt = zc

            if oneLife.enabled ~= false and pt and pt.x then
                local ped = PlayerPedId()
                local coords = GetEntityCoords(ped)
                if inZone(pt, ringR + 5.0, zshape, coords.x, coords.y) then
                    -- Disarm and disable weapon usage
                    if oneLife.disarmOnApproach ~= false then
                        SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
                        DisablePlayerFiring(PlayerId(), true)
                        DisableControlAction(0, 24, true)  -- Attack
                        DisableControlAction(0, 25, true)  -- Aim
                        DisableControlAction(0, 140, true) -- Melee Light
                        DisableControlAction(0, 141, true) -- Melee Heavy
                        DisableControlAction(0, 142, true) -- Melee Alt
                    end

                    -- Repel outside combat ring zone
                    if oneLife.blockReentry ~= false then
                        local pushDist = (zshape == 'square' and ringR * 1.42 or ringR) + (tonumber(oneLife.repelDistance) or 15.0)
                        local angle = math.atan2(coords.y - pt.y, coords.x - pt.x)
                        local pushX = pt.x + math.cos(angle) * pushDist
                        local pushY = pt.y + math.sin(angle) * pushDist
                        local pushZ = groundZ(pushX, pushY, coords.z)

                        local veh = GetVehiclePedIsIn(ped, false)
                        if veh ~= 0 and DoesEntityExist(veh) and GetPedInVehicleSeat(veh, -1) == ped then
                            SetEntityCoords(veh, pushX, pushY, pushZ + 0.5, false, false, false, false)
                            SetVehicleForwardSpeed(veh, 0.0)
                        else
                            SetEntityCoords(ped, pushX, pushY, pushZ, false, false, false, false)
                            ClearPedTasks(ped)
                        end

                        if not wasBlocked then
                            wasBlocked = true
                            SendNUIMessage({
                                action = 'territory:eliminatedBlocked',
                                active = true,
                                message = oneLife.notifyMessage or 'ACCESS DENIED: You were eliminated from this rival war!',
                            })
                        end

                        local nowSec = GetGameTimer()
                        if nowSec - lastAlert > 4000 then
                            lastAlert = nowSec
                            PlaySoundFrontend(-1, "ERROR", "HUD_AMMO_SHOP_SOUNDSET", true)
                            lib.notify({
                                type = 'error',
                                title = 'ACCESS DENIED',
                                description = oneLife.notifyMessage or 'You were eliminated from this rival war! Revived players cannot re-enter the combat zone.',
                                duration = 5000,
                            })
                        end
                    end
                    Wait(0)
                else
                    if wasBlocked then
                        wasBlocked = false
                        SendNUIMessage({
                            action = 'territory:eliminatedBlocked',
                            active = false,
                        })
                    end
                    Wait(300)
                end
            else
                Wait(1000)
            end
        else
            if wasBlocked then
                wasBlocked = false
                SendNUIMessage({
                    action = 'territory:eliminatedBlocked',
                    active = false,
                })
            end
            Wait(1000)
        end
    end
end)

RegisterNetEvent('nova_convoytruck:territory:client:warStart', function(w)
    if type(w) ~= 'table' then return end
    war, myRole = w, w.role
    myEliminated = (w.eliminated == true)
    buildWarWorld()
    SendNUIMessage({ action = 'territory:warStart', war = w })
end)

RegisterNetEvent('nova_convoytruck:territory:client:warTick', function(t)
    if not war or war.warId ~= t.warId then return end
    myRole = t.role or myRole
    if t.eliminated ~= nil then
        myEliminated = t.eliminated
    end
    SendNUIMessage({ action = 'territory:warTick', tick = t })
end)

RegisterNetEvent('nova_convoytruck:territory:client:eliminatedState', function(data)
    if not war or war.warId ~= data.warId then return end
    myEliminated = data.eliminated
    SendNUIMessage({
        action = 'territory:eliminatedState',
        eliminated = myEliminated,
    })
end)

RegisterNetEvent('nova_convoytruck:territory:client:warEnd', function(r)
    if war and war.warId == (r and r.warId) then
        war, myRole = nil, nil
        myEliminated = false
        clearWarWorld()
    end
    SendNUIMessage({ action = 'territory:outOfBounds', active = false })
    SendNUIMessage({ action = 'territory:eliminatedBlocked', active = false })
    SendNUIMessage({ action = 'territory:warEnd', result = r })
end)

-- ── Leader Peds & Post-War Looting ──────────────────────────────────────────────

local postWarLoots = {}       -- [warId] = lootData
local myLootEligible = {}     -- [territoryId] = warId
local leaderPeds = {}         -- [territoryId] = pedEntity

removeLeaderPed = function(id)
    if leaderPeds[id] and DoesEntityExist(leaderPeds[id]) then
        NovaConvoy.RemoveEntityTarget(leaderPeds[id])
        DeleteEntity(leaderPeds[id])
    end
    leaderPeds[id] = nil
end

local function clearAllLeaderPeds()
    for id in pairs(leaderPeds) do removeLeaderPed(id) end
end

-- Logging out of a character (multichar switch) mid-war: the war belongs to the character that left. Without this the out-of-bounds
-- thread kept running for the NEW character and could kill it after its timer.
local function resetWarForCharacterChange()
    war, myRole, myEliminated = nil, nil, false
    pcall(clearWarWorld)
end
RegisterNetEvent('nova_convoytruck:client:characterUnloaded', resetWarForCharacterChange)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', resetWarForCharacterChange)

RegisterNetEvent('nova_convoytruck:territory:client:postWarLoot', function(loot, isWinner)
    if type(loot) ~= 'table' then return end
    postWarLoots[loot.warId] = loot
    if isWinner then
        myLootEligible[loot.territoryId] = loot.warId
    else
        myLootEligible[loot.territoryId] = nil
    end
end)

RegisterNetEvent('nova_convoytruck:territory:client:lootFinished', function(warId)
    local wid = tonumber(warId)
    local loot = postWarLoots[wid]
    if loot then
        myLootEligible[loot.territoryId] = nil
        postWarLoots[wid] = nil
    end
end)

-- Proximity loop to spawn Leader Ped at each territory
CreateThread(function()
    while true do
        local sleep = 1000
        local pos = GetEntityCoords(PlayerPedId())
        if next(territories) then
            for id, t in pairs(territories) do
                -- Don't spawn permanent leader ped if a war is currently running on this territory (warPed handles it)
                local inWar = war and war.territoryId == id
                local coords = (t.ped and t.ped.x and t.ped) or (t.location and t.location.x and t.location) or (t.center and t.center.x and t.center)
                if coords and coords.x and not inWar then
                    local d = #(pos - vec3(coords.x + 0.0, coords.y + 0.0, pos.z))
                    if d < 80.0 then
                        sleep = 200
                        if not leaderPeds[id] or not DoesEntityExist(leaderPeds[id]) then
                            local z = pedBaseZ(coords.x, coords.y, coords.z)
                            local model = joaat((t.ped and t.ped.model) or 'g_m_y_mexgoon_01')
                            lib.requestModel(model)
                            local ped = CreatePed(4, model, coords.x + 0.0, coords.y + 0.0, z, coords.heading or 0.0, false, true)
                            if ped and DoesEntityExist(ped) then
                                SetEntityInvincible(ped, true)
                                SetBlockingOfNonTemporaryEvents(ped, true)
                                FreezeEntityPosition(ped, true)
                                SetPedCanRagdoll(ped, false)
                                SetModelAsNoLongerNeeded(model)

                                -- Check if defeated / surrender state
                                local isLootActive = myLootEligible[id] ~= nil
                                if isLootActive then
                                    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_BUM_STANDING', 0, true)
                                else
                                    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_GUARD_STAND', 0, true)
                                end

                                leaderPeds[id] = ped

                                local warCfg = (Config.Territory and Config.Territory.war) or {}
                                local pcfg = warCfg.postWarLoot or {}

                                NovaConvoy.AddEntityTarget(ped, {
                                    {
                                        label = pcfg.targetLabel or 'Loot Gang XP',
                                        icon = pcfg.targetIcon or 'fa-solid fa-sack-dollar',
                                        distance = 2.5,
                                        canInteract = function()
                                            return myLootEligible[id] ~= nil
                                        end,
                                        onSelect = function()
                                            local wid = myLootEligible[id]
                                            if not wid then return end
                                            local dur = (tonumber(pcfg.durationSeconds) or 5) * 1000
                                            local success = false
                                            if lib and lib.progressBar then
                                                success = lib.progressBar({
                                                    duration = dur,
                                                    label = 'Looting Gang XP...',
                                                    useWhileDead = false,
                                                    canCancel = true,
                                                    disable = { move = true, car = true, combat = true },
                                                    anim = { dict = 'anim@heists@ornate_bank@grab_cash', clip = 'grab' },
                                                })
                                            else
                                                Wait(dur)
                                                success = true
                                            end
                                            if success then
                                                TriggerServerEvent('nova_convoytruck:territory:server:claimLoot', wid)
                                            end
                                        end,
                                    },
                                    -- the leader conversation (client/modules/leader_talk.lua): four choices, hidden while the post-war loot option is on
                                    {
                                        name = 'nova_leader_respect', label = 'Pay Respects', icon = 'fa-solid fa-hand-fist', distance = 2.5,
                                        canInteract = function() return myLootEligible[id] == nil and not LeaderTalk.busy() end,
                                        onSelect = function() LeaderTalk.respect(ped, id) end,
                                    },
                                    {
                                        name = 'nova_leader_speak', label = 'Speak to Leader', icon = 'fa-solid fa-comments', distance = 2.5,
                                        canInteract = function() return myLootEligible[id] == nil and not LeaderTalk.busy() end,
                                        onSelect = function() LeaderTalk.open(ped, id, 'root') end,
                                    },
                                    {
                                        name = 'nova_leader_territory', label = 'Ask About Territory', icon = 'fa-solid fa-map-location-dot', distance = 2.5,
                                        canInteract = function() return myLootEligible[id] == nil and not LeaderTalk.busy() end,
                                        onSelect = function() LeaderTalk.open(ped, id, 'territory') end,
                                    },
                                    {
                                        name = 'nova_leader_trouble', label = 'Ask About Trouble', icon = 'fa-solid fa-triangle-exclamation', distance = 2.5,
                                        canInteract = function() return myLootEligible[id] == nil and not LeaderTalk.busy() end,
                                        onSelect = function() LeaderTalk.open(ped, id, 'trouble') end,
                                    },
                                })
                            end
                        end
                    elseif d > 120.0 and leaderPeds[id] then
                        removeLeaderPed(id)
                    end
                elseif inWar and leaderPeds[id] then
                    removeLeaderPed(id)
                end
            end
        end
        Wait(sleep)
    end
end)

-- The head tags of the leader peds. A ped is checked only while one stands within TAG_RANGE of the player; its owner's Gang XP is asked for
-- once now and again every 20 s while the player stays near it (a cached read on the server).
local TAG_RANGE = 18.0
local tagXp = {}   -- [territoryId] = { xp, at, asking }
CreateThread(function()
    while true do
        local nearest = {}
        local me = GetEntityCoords(PlayerPedId())
        for id, ped in pairs(leaderPeds) do
            if ped and DoesEntityExist(ped) then
                local pc = GetEntityCoords(ped)
                local dx, dy, dz = pc.x - me.x, pc.y - me.y, pc.z - me.z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 <= TAG_RANGE * TAG_RANGE then nearest[#nearest + 1] = { id = id, ped = ped, d = math.sqrt(d2) } end
            end
        end
        if #nearest == 0 then
            Wait(500)
        else
            local now = GetGameTimer()
            for _, n in ipairs(nearest) do
                local t = territories[n.id]
                local c = tagXp[n.id]
                if t and t.owner and (not c or (now - c.at > 20000 and not c.asking)) then
                    c = c or { at = 0 }
                    tagXp[n.id] = c
                    c.asking, c.at = true, now
                    lib.callback('nova_convoytruck:territory:ownerXp', false, function(res)
                        c.asking = false
                        c.xp = res and res.xp or nil
                    end, n.id)
                end
                if t and not (war and war.territoryId == n.id) then
                    local head = GetPedBoneCoords(n.ped, 31086, 0.0, 0.0, 0.0)
                    local r, g, b = hexToRgb(t.color or t.ownerAccent, { 255, 200, 87 })
                    local title = t.ownerLabel or 'Unclaimed'
                    local xpText = (t.owner and c and c.xp) and ('XP  ' .. commas(c.xp)) or nil
                    local k = math.max(0.5, math.min(1.0, 5.0 / math.max(n.d, 1.0)))
                    drawGangTag(head.x, head.y, head.z + 0.42, title, t.name or 'Territory', xpText, r, g, b, k)
                end
            end
            Wait(0)
        end
    end
end)

-- ── boot / reconnect ─────────────────────────────────────────────────────────────

local function requestWorld()
    TriggerServerEvent('nova_convoytruck:territory:server:requestSnapshot')
    TriggerServerEvent('nova_convoytruck:territory:server:requestWarSync')
    TriggerServerEvent('nova_convoytruck:territory:server:requestAuctionSync')
end

-- a resource restart leaves a client with an empty picture: ask for it again as soon as we are in the game
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(500) end
    Wait(3000)
    requestWorld()
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(blips) do removeBlip(id) end
    removeAuctionWorld()
    clearWarWorld()
    clearAllLeaderPeds()
end)
