-- ─── Nova Convoy — Persistent Territory State ──────────────────────────────────
-- Server-only. The persistent half of the Gang Territory system. A "Gang Territory Auction" EVENT only carries the
-- configuration (areas, painted shapes, expansion costs, capture point); the moment it is published, each area becomes a
-- row in nova_territories and from then on belongs to this module:
--
--   owner ........................... persists after the event ends, changes only through Territory.transfer (auction or admin;
--                                     a war never changes it)
--   geometry ........................ painted cell spans (territory_geo.lua), base + predefined expansion levels
--   adjacency ....................... computed here, server-side, from the painted cells — never from the client
--   history ......................... every owner change / expansion is a row in nova_territory_history
--   live sync ....................... every change is pushed to every admin and gang member at once (no refresh needed)
--
-- Auctions (territory_auction.lua) and wars (territory_war.lua) change owners ONLY through Territory.transfer.

Territory = {}

local state = {}          -- [territoryId] = t
local ready = false
local paintOverride = nil  -- { xpPerCell, maxNewCells } an admin set live (Map Zone -> Admin tools); a nil field = the config.lua value

local function cfg() return Config.Territory or {} end
local function now() return os.time() end

-- ── geometry helpers ─────────────────────────────────────────────────────────────

-- Painted cells of a territory at a given expansion level (base + expansions 1..level), cached per level.
local function compiled(t, level)
    level = math.max(0, math.min(level or t.level, #t.def.expansions))
    t.cache = t.cache or {}
    local c = t.cache[level]
    if not c then
        local lists = { t.clearBase and {} or t.def.base.spans }   -- clearBase: the starting land was wiped (Clear painted land / a sale)
        for l = 1, level do
            local ex = t.def.expansions[l]
            if ex then lists[#lists + 1] = ex.spans end
        end
        -- land painted in the Map Zone editor: extra cells on top, cut-away cells removed
        if t.custom and #t.custom > 0 then lists[#lists + 1] = t.custom end
        local set = TerritoryGeo.cellSet(table.unpack(lists))
        if t.cut and #t.cut > 0 then
            for k in pairs((TerritoryGeo.cellSet(t.cut))) do set[k] = nil end
            lists = { TerritoryGeo.setToSpans(set) }
        end
        c = { set = set, rows = TerritoryGeo.rowIndex(table.unpack(lists)), lists = lists }
        t.cache[level] = c
    end
    return c
end

-- Re-grids a cell set painted with cell size `from` onto cell size `to` (only used when two territories were painted with
-- different cell sizes, e.g. after Config.Territory.cellSize was changed).
local function regrid(set, from, to)
    local out = {}
    for k in pairs(set) do
        local ix, iy = TerritoryGeo.unkey(k)
        out[TerritoryGeo.key(math.floor((ix + 0.5) * from / to), math.floor((iy + 0.5) * from / to))] = true
    end
    return out
end

local function spansEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] or a[i][3] ~= b[i][3] then return false end
    end
    return true
end

local function sameGeometry(da, db)
    if not da or not db then return false end
    if (da.base.cs or 0) ~= (db.base.cs or 0) or not spansEqual(da.base.spans or {}, db.base.spans or {}) then return false end
    if #da.expansions ~= #db.expansions then return false end
    for i, ex in ipairs(da.expansions) do
        local ox = db.expansions[i]
        if (ex.xpCost or 0) ~= (ox.xpCost or 0) or (ex.name or '') ~= (ox.name or '') or not spansEqual(ex.spans or {}, ox.spans or {}) then return false end
    end
    return true
end

local function cleanDefinition(a)
    return {
        description = a.description or '', image = a.image or '', imagePos = a.imagePos, showName = a.showName ~= false,
        location = a.location, blip = a.blip or {}, auctioned = a.auctioned ~= false, startingOwner = a.startingOwner or '',
        startingBid = a.startingBid, minBidIncrement = a.minBidIncrement, order = a.order,
        spriteType = a.spriteType or 'GTA_SPRITE', customLogo = a.customLogo or '',
        -- no starting land (a shape an older event stored is ignored): land is grown by painting. Only the cell size is kept.
        base = { cs = (a.base and a.base.cs) or cfg().cellSize or 25.0, spans = {} }, expansions = {},
        capture = a.capture or {}, props = a.props or {},
    }
end

-- ── lookups ──────────────────────────────────────────────────────────────────────

function Territory.get(id) return state[id] end

function Territory.all()
    local list = {}
    for _, t in pairs(state) do list[#list + 1] = t end
    table.sort(list, function(a, b) return (a.def.order or 0) < (b.def.order or 0) or ((a.def.order or 0) == (b.def.order or 0) and a.id < b.id) end)
    return list
end

local function gangLabel(name)
    if not name then return nil end
    local g = GangService and GangService.GetGangByName(name)
    return g and g.label or name
end
Territory.gangLabel = gangLabel

-- A gang's label / logo / colour as the map shows it. Each lookup is a database read and a map refresh asks for every territory, so
-- it is kept for a few seconds; Territory.refreshOwnerLook (a gang was edited) empties it at once.
local metaCache = {}
local META_TTL_MS = 10000
local function gangMeta(name)
    if not name then return {} end
    local now = GetGameTimer()
    local hit = metaCache[name]
    if hit and now - hit.at < META_TTL_MS then return hit.meta end
    local g = GangService and GangService.GetGangByName(name)
    local meta = { label = g and g.label or name, logo = g and g.logo or nil, accent = g and g.accentColor or nil }
    metaCache[name] = { at = now, meta = meta }
    return meta
end

-- Where the territory is: its explicit world location, else the centre of its painted base.
function Territory.center(t)
    if t.def.location and t.def.location.x then return t.def.location.x, t.def.location.y, t.def.location.z or 0.0 end
    local m = TerritoryGeo.metrics(t.def.base.cs or 25.0, table.unpack(compiled(t, t.level).lists))
    if m then return m.x, m.y, 0.0 end
    return 0.0, 0.0, 0.0
end

function Territory.contains(id, x, y)
    local t = state[id]
    if not t then return false end
    return TerritoryGeo.rowsContain(compiled(t, t.level).rows, t.def.base.cs or 25.0, x, y)
end

-- Per owner: how many territories they control and the sum of their unlocked expansion levels (the "Territory Level").
function Territory.ownerSummary()
    local out = {}
    for _, t in pairs(state) do
        if t.owner then
            local o = out[t.owner] or { count = 0, level = 0, xp = 0, cells = 0, areaKm2 = 0 }
            o.count = o.count + 1
            o.level = o.level + (t.level or 0)
            o.xp = o.xp + (t.xpValue or 0)
            o.cells = o.cells + Territory.cellCount(t)
            o.areaKm2 = math.floor((o.cells * 0.000625) * 1000 + 0.5) / 1000
            out[t.owner] = o
        end
    end
    return out
end

-- Cells in the territory's current shape (base + the expansions it has unlocked + custom paint); used by the rival-war matchmaking.
function Territory.cellCount(t)
    local cur = t and compiled(t, t.level)
    if not cur then return 0 end
    if not cur.n then   -- counted once per shape (the cache is dropped whenever the shape changes)
        local n = 0
        for _ in pairs(cur.set) do n = n + 1 end
        cur.n = n
    end
    return cur.n
end

-- ── what the tablets receive ─────────────────────────────────────────────────────

-- The painted shapes of one territory, as the tablets draw them. Building them is the expensive part of a view (cut cells are
-- removed, spans are rebuilt from the cell set), so the result is kept until the territory's shape revision moves.
local function geoOf(t)
    local c = t.geoCache
    if c and c.rev == t.rev and c.level == t.level then return c.geo end
    local def = t.def
    local geo = { cs = def.base.cs, base = def.base.spans, expansions = {}, custom = t.custom or {} }
    -- cells an admin cut away are removed from every layer the gangs see
    local cutSet = (t.cut and #t.cut > 0) and (TerritoryGeo.cellSet(t.cut)) or nil
    local function without(spans)
        if not cutSet then return spans end
        local set = TerritoryGeo.cellSet(spans)
        for k in pairs(cutSet) do set[k] = nil end
        return TerritoryGeo.setToSpans(set)
    end
    geo.base = t.clearBase and {} or without(def.base.spans)
    for l, ex in ipairs(def.expansions) do
        geo.expansions[l] = { level = l, name = ex.name, xpCost = ex.xpCost, spans = without(ex.spans), unlocked = l <= t.level }
    end
    -- the territory's CURRENT shape as one span list (what the Map Zone editor starts from)
    local cur = compiled(t, t.level)
    geo.active = (#cur.lists == 1) and cur.lists[1] or TerritoryGeo.setToSpans(cur.set)
    t.geoCache = { rev = t.rev, level = t.level, geo = geo }
    return geo
end

-- forAdmin adds the capture-point configuration (a gang must not be able to read where the capture point is in advance).
-- noGeo leaves the painted shapes out: the caller knows the tablet already holds them (nothing about the land changed, or the
-- tablet said it has this revision), which is most of the weight of a view.
function Territory.view(t, forAdmin, noGeo)
    local meta = gangMeta(t.owner)
    local def = t.def
    local v = {
        id = t.id, eventId = t.eventId, name = t.name, description = def.description,
        owner = t.owner, ownerLabel = meta.label, ownerLogo = meta.logo, ownerAccent = meta.accent,
        level = t.level, maxLevel = #def.expansions, xpValue = t.xpValue, color = t.color, rev = t.rev,
        image = def.image, imagePos = def.imagePos, showName = def.showName, location = def.location, blip = def.blip,
        spriteType = def.spriteType or 'GTA_SPRITE', customLogo = def.customLogo or '',
        ped = def.capture and def.capture.ped,
        order = def.order, auctioned = def.auctioned,
        geo = (not noGeo) and geoOf(t) or nil,
        busy = t.war and true or false,   -- a war is on this territory right now
    }
    local cx, cy = Territory.center(t)
    v.center = { x = cx, y = cy }
    if forAdmin then
        v.capture = def.capture
        v.startingOwner = def.startingOwner
    end
    return v
end

-- Everything the world needs (blips, ground markers) without the painted shapes — sent to a player who just joined.
function Territory.lightView(t)
    local meta = gangMeta(t.owner)
    local cx, cy, cz = Territory.center(t)
    local pedData = (t.def.capture and t.def.capture.ped) or (t.def.location and { x = t.def.location.x, y = t.def.location.y, z = t.def.location.z, heading = t.def.location.heading or 0.0, model = (t.def.capture and t.def.capture.model) or 'g_m_y_mexgoon_01' })
    return {
        id = t.id, name = t.name, owner = t.owner, ownerLabel = meta.label, ownerAccent = meta.accent, color = t.color,
        level = t.level, center = { x = cx, y = cy, z = cz }, location = t.def.location, blip = t.def.blip, war = t.war and true or false,
        ped = pedData,
    }
end

function Territory.snapshotFor(src)
    local list = {}
    for _, t in pairs(state) do list[#list + 1] = Territory.lightView(t) end
    TriggerClientEvent('nova_convoytruck:territory:client:snapshot', src, list)
end

-- Staff who may open the territory tablet pages: server admins AND staff-role holders (Staff Management). The same rule the tablet
-- callbacks use, so everyone who can open the admin Map Zone also receives its live updates.
function Territory.isStaff(src)
    if UserPermissions and UserPermissions.canAny then
        return UserPermissions.canAny(src, 'mapzone.view', 'territories.view', 'rivals.view') == true
    end
    return Bridge.IsAdmin(src, Config.CreatorAccess.adminPermission) == true
end

-- Who gets live map updates: every admin / staff member and every gang member (Event Status / Gang Tablet users).
function Territory.audience()
    local out = {}
    for _, src in ipairs(Bridge.GetPlayers()) do
        if Territory.isStaff(src) or GangXP.GangOf(src, true) then out[#out + 1] = src end
    end
    return out
end

-- Config.Territory.visibleTo: 'everyone' (default) = every player sees the territory blips, ground rings and leader peds in
-- the world; 'gangs' = only gang members and admins do. The painted shapes / Gang XP / tablets are gang + admin only either way.
function Territory.visibleToAll()
    return tostring(cfg().visibleTo or 'everyone'):lower() ~= 'gangs'
end

-- May this player receive the world side (blips, rings, leader peds)?
function Territory.canSeeWorld(src)
    if Territory.visibleToAll() or Territory.isStaff(src) then return true end
    return GangXP.GangOf(src, true) and true or false
end

-- noGeo = the land itself did not change (a new owner, a war started or ended, a gang changed its colour): the update carries no
-- painted shapes and the tablets keep the ones they have.
function Territory.broadcast(ids, noGeo)
    if not ids or #ids == 0 then return end
    -- each view is built once (the painted shapes are the expensive part), one for admins and one for gang members
    local plain, admin = {}, {}
    for _, id in ipairs(ids) do
        local t = state[id]
        if t then
            plain[#plain + 1] = Territory.view(t, false, noGeo)
            admin[#admin + 1] = Territory.view(t, true, noGeo)
        end
    end
    if #plain == 0 then return end
    local audience = Territory.audience()
    local inAudience = {}
    for _, src in ipairs(audience) do
        inAudience[src] = true
        TriggerClientEvent('nova_convoytruck:territory:client:upsert', src, Territory.isStaff(src) and admin or plain)
    end
    -- everybody else only gets what the world needs (blip, ring, leader ped) — no painted shapes, no tablet data
    if Territory.visibleToAll() then
        local light
        for _, src in ipairs(Bridge.GetPlayers()) do
            if not inAudience[src] then
                if not light then
                    light = {}
                    for _, id in ipairs(ids) do
                        local t = state[id]
                        if t then light[#light + 1] = Territory.lightView(t) end
                    end
                end
                TriggerClientEvent('nova_convoytruck:territory:client:upsertWorld', src, light)
            end
        end
    end
    -- ownership / level changed: the per-gang territory counts in the XP table moved too
    if GangXP and GangXP.ScheduleBoard then GangXP.ScheduleBoard() end
end

function Territory.broadcastRemoved(id)
    local targets = Territory.audience()
    if Territory.visibleToAll() then targets = Bridge.GetPlayers() end
    for _, src in ipairs(targets) do
        TriggerClientEvent('nova_convoytruck:territory:client:remove', src, id)
    end
end

-- Tells every online member of one gang something (banner + NUI event).
function Territory.eachGangMember(gangName, fn)
    for _, src in ipairs(Bridge.GetPlayers()) do
        local g = GangXP.GangOf(src, true)
        if g and g.name == gangName then fn(src) end
    end
end

-- ── history ──────────────────────────────────────────────────────────────────────

local function addHistory(t, previousOwner, newOwner, reason, info)
    info = info or {}
    local ok, err = pcall(DB.territoryHistoryInsert, {
        territoryId = t.id, territoryName = t.name, previousOwner = previousOwner, newOwner = newOwner, reason = reason,
        refType = info.refType, refId = info.refId, winnerIdentifier = info.winnerIdentifier, winnerName = info.winnerName,
        amount = info.amount, meta = info.meta,
    })
    if not ok then print(('^1[NovaConvoy][Territory] history write failed for %s: %s^0'):format(t.id, tostring(err))) end
end

-- One small Discord post for a change to the territory map that is not part of an event's own log (XP expansions, painted /
-- erased land, admin edits). Turn off with Config.DiscordLogs.territoryChanges = false.
function Territory.logDiscord(title, fields, color)
    if not DiscordLog or not DiscordLog.send then return end
    if (Config.DiscordLogs or {}).territoryChanges == false then return end
    pcall(DiscordLog.send, title, nil, color or 0xc45ee0, fields)
end

function Territory.history(id, limit)
    local rows = DB.territoryHistory(id, limit)
    for _, r in ipairs(rows) do
        r.previousLabel = gangLabel(r.previous_owner)
        r.newLabel = gangLabel(r.new_owner)
    end
    return rows
end

-- An owner changed or a territory was deleted: open challenges that aimed at it may be void now, and every open tablet's list of
-- rival territories (who it can challenge) just changed.
local function ownershipChanged()
    if TerritoryWar and TerritoryWar.voidStale then pcall(TerritoryWar.voidStale) end
    for _, src in ipairs(Territory.audience()) do
        TriggerClientEvent('nova_convoytruck:territory:client:rivalsChanged', src)
    end
end

-- Wipes ALL the land of a territory: its starting land, the gangs' paint and the cut-outs. The next owner paints it again, starting at
-- the leader ped. clearBase keeps the starting land (which an event republish would bring back) switched off. Returns true | false.
local function wipeLand(t)
    local geo = { custom = {}, cut = {}, clearBase = true }
    if not DB.territorySetCustom(t.id, geo, t.rev) then return false end
    t.custom, t.cut, t.clearBase, t.rev, t.cache = {}, {}, true, t.rev + 1, nil
    return true
end

-- A gang changed its colour, logo or name: every territory it owns is redrawn on every tablet and on the map. Debounced, because
-- one edit in the tablet can write several fields.
local lookPending = false
function Territory.refreshOwnerLook()
    metaCache = {}   -- the next view reads the gang's new colour / logo / name
    if lookPending then return end
    lookPending = true
    SetTimeout(500, function()
        lookPending = false
        local ids = {}
        for id, t in pairs(state) do if t.owner then ids[#ids + 1] = id end end
        Territory.broadcast(ids, true)   -- only the look changed, the land did not
    end)
end

-- ── boot ─────────────────────────────────────────────────────────────────────────

local function rowToState(r)
    local def = cleanDefinition(r.definition or {})
    return {
        id = r.territory_id, eventId = r.event_id, name = r.name, owner = (r.owner_gang and r.owner_gang ~= '') and r.owner_gang or nil,
        level = tonumber(r.expansion_level) or 0, xpValue = tonumber(r.xp_value) or 0, color = r.color or cfg().defaultColor,
        -- a stored starting shape is dropped by cleanDefinition: a new revision makes tablets that cached it fetch the empty land
        rev = (tonumber(r.geo_rev) or 1) + ((type(r.definition) == 'table' and type(r.definition.base) == 'table' and type(r.definition.base.spans) == 'table' and #r.definition.base.spans > 0) and 1 or 0), def = def,
        custom = (type(r.custom_geo) == 'table' and r.custom_geo.custom) or {}, cut = (type(r.custom_geo) == 'table' and r.custom_geo.cut) or {},
        clearBase = (type(r.custom_geo) == 'table' and r.custom_geo.clearBase == true) or nil,
    }
end

function Territory.load()
    local ok, rows = pcall(DB.territoriesAll)
    if not ok then
        print(('^1[NovaConvoy][Territory] could not load territories: %s^0'):format(tostring(rows)))
        return
    end
    state = {}
    for _, r in ipairs(rows) do
        local t = rowToState(r)
        if t.level > #t.def.expansions then t.level = #t.def.expansions end
        state[t.id] = t
    end
    local okS, row = pcall(DB.getTerritorySettings)
    if okS and row then paintOverride = { xpPerCell = tonumber(row.xp_per_cell), maxNewCells = tonumber(row.max_new_cells) } end
    ready = true
    print(('[NovaConvoy] Loaded %d territor%s.'):format(#rows, #rows == 1 and 'y' or 'ies'))
end

function Territory.isReady() return ready end

-- ── event → persistent state ─────────────────────────────────────────────────────

-- Creates / refreshes the territories an event defines. A territory that already exists keeps its owner and expansion
-- level; only its configuration (name, painted shapes, costs, capture point ...) follows the event. A brand-new one starts
-- with the event's "starting owner". Safe to call any number of times.
function Territory.syncFromEvent(def)
    if not def or def.kind ~= 'GANG_TERRITORY' then return 0 end
    local areas = (def.territory and def.territory.areas) or {}
    local changed = {}
    for _, a in ipairs(areas) do
        local newDef = cleanDefinition(a)
        local t = state[a.id]
        if not t then
            local owner = (a.startingOwner and a.startingOwner ~= '') and a.startingOwner or nil
            DB.territoryInsert({ id = a.id, eventId = def.id, name = a.name, ownerGang = owner, xpValue = a.xpValue, color = a.color, definition = newDef })
            t = { id = a.id, eventId = def.id, name = a.name, owner = owner, level = 0, xpValue = a.xpValue or 0, color = a.color, rev = 1, def = newDef, custom = {}, cut = {} }
            state[a.id] = t
            if owner then addHistory(t, nil, owner, 'INITIAL', { refType = 'EVENT', refId = def.id, meta = { event = def.name } }) end
        else
            local geoChanged = not sameGeometry(t.def, newDef)
            if geoChanged and t.clearBase then
                -- the admin changed the event's starting land: that new starting land applies (only the OLD one had been wiped)
                t.clearBase = nil
                pcall(DB.territorySetCustom, t.id, { custom = t.custom or {}, cut = t.cut or {} }, t.rev)
            end
            t.eventId, t.name, t.xpValue, t.color, t.def = def.id, a.name, a.xpValue or 0, a.color, newDef
            t.cache = nil
            if geoChanged then t.rev = t.rev + 1 end
            DB.territoryUpdateDefinition({ id = t.id, eventId = def.id, name = t.name, xpValue = t.xpValue, color = t.color, definition = newDef }, geoChanged)
            if t.level > #newDef.expansions then
                -- an expansion level was removed from the configuration: the territory falls back to the highest one left
                if t.owner and DB.territorySetLevel(t.id, t.owner, t.level, #newDef.expansions) then t.level = #newDef.expansions end
            end
        end
        changed[#changed + 1] = a.id
    end
    Territory.broadcast(changed)
    print(('[NovaConvoy][Territory] event #%s synced %d territor%s'):format(tostring(def.id), #changed, #changed == 1 and 'y' or 'ies'))
    return #changed
end

-- Admin: delete a territory for good (its history stays). Refuses while a war is on it.
function Territory.remove(id)
    local t = state[id]
    if not t then return false, 'Territory not found.' end
    if t.war then return false, 'A war is running on this territory.' end
    DB.territoryDelete(id)
    state[id] = nil
    Territory.broadcastRemoved(id)
    ownershipChanged()
    return true
end

-- Admin: create a new territory directly from the Map Zone tab.
function Territory.create(data)
    if not data or type(data.name) ~= 'string' or data.name == '' then return false, 'Name is required.' end
    local id = ('t_%d_%04d'):format(os.time(), math.random(1000, 9999))
    local owner = (type(data.owner) == 'string' and data.owner ~= '') and data.owner or nil
    local pedData = data.ped or (data.location and { x = data.location.x, y = data.location.y, z = data.location.z, heading = data.location.heading or 0, model = data.pedModel or 'g_m_y_mexgoon_01' })
    local loc = data.location or (pedData and pedData.x and { x = pedData.x, y = pedData.y, z = pedData.z })
    local newDef = cleanDefinition({
        description = data.description or '',
        startingOwner = owner or '',
        color = data.color or '#c45ee0',
        xpValue = data.xpValue or 500,
        startingBid = data.startingBid or 100000,
        minBidIncrement = data.minBidIncrement or 10000,
        location = loc,
        capture = {
            enabled = true,
            ped = pedData or { model = data.pedModel or 'g_m_y_mexgoon_01', x = nil, y = nil, z = nil, heading = 0 },
            seconds = data.captureSeconds or 60,
            radius = data.captureRadius or 15.0,
            contestRule = data.contestRule or 'PAUSE',
        },
        blip = {
            enabled = true,
            sprite = tonumber(data.sprite) or 310,
            scale = 0.85,
        },
        spriteType = data.spriteType or 'GTA_SPRITE',
        customLogo = data.customLogo or '',
        image = data.customLogo or '',
        base = { cs = cfg().cellSize or 25.0, spans = {} },
    })
    DB.territoryInsert({ id = id, eventId = nil, name = data.name, ownerGang = owner, xpValue = data.xpValue or 500, color = data.color or '#c45ee0', definition = newDef })
    local t = { id = id, eventId = nil, name = data.name, owner = owner, level = 0, xpValue = data.xpValue or 500, color = data.color or '#c45ee0', rev = 1, def = newDef, custom = {}, cut = {} }
    state[id] = t
    if owner then addHistory(t, nil, owner, 'INITIAL', { refType = 'ADMIN', meta = { note = 'Manual territory creation' } }) end
    Territory.broadcast({ id })
    return true, t
end

-- ── ownership ────────────────────────────────────────────────────────────────────

-- The ONLY way an owner changes (auction result, war result, admin). Optimistic: it only applies while the owner is
-- still what the caller saw (`expectedOwner`, nil = unowned), so two results can never both claim the same territory.
-- info: { reason, refType, refId, winnerIdentifier, winnerName, amount, meta, keepLevel }
-- Returns true | false, message
function Territory.transfer(id, newOwner, expectedOwner, info)
    info = info or {}
    local t = state[id]
    if not t then return false, 'Territory not found.' end
    if newOwner == '' then newOwner = nil end
    if expectedOwner == '' then expectedOwner = nil end
    if t.owner ~= expectedOwner then return false, 'The territory changed hands in the meantime.' end
    -- a war is fought on it: nothing may sell or hand it over until the war is over (a war itself never changes the owner)
    if t.war then return false, 'A war is running on this territory.' end

    local newLevel = t.level
    if not DB.territorySetOwner(id, newOwner, expectedOwner, newLevel) then return false, 'The territory could not be updated.' end

    local previous = t.owner
    t.owner, t.level, t.rev, t.cache = newOwner, newLevel, t.rev + 1, nil
    addHistory(t, previous, newOwner, info.reason or 'ADMIN', info)
    -- a sale wipes the land the territory had (info.clearLand): the buyer starts from a clean slate and paints it themselves
    local cleared = false
    if info.clearLand and Territory.cellCount(t) > 0 then cleared = wipeLand(t) end
    Territory.broadcast({ id }, not cleared)   -- a new owner on the same land: no shapes in the update
    ownershipChanged()
    print(('[NovaConvoy][Territory] %s: %s → %s (%s)'):format(t.name, tostring(previous), tostring(newOwner), tostring(info.reason)))
    return true
end

-- The shape of a territory right now, as one span list (the auction board draws it).
function Territory.shapeSpans(t)
    local cur = compiled(t, t.level)
    return (#cur.lists == 1) and cur.lists[1] or TerritoryGeo.setToSpans(cur.set)
end

-- Admin: wipe a territory's land (stale paint, an old starting area). Staff never paint; this only takes land away.
function Territory.clearLand(id, by)
    local t = state[id]
    if not t then return false, 'Territory not found.' end
    if t.war then return false, 'A war is running on this territory.' end
    if t.expanding then return false, 'A change is already being processed for this territory.' end
    local had = Territory.cellCount(t)
    if not wipeLand(t) then return false, 'The land could not be cleared.' end
    addHistory(t, t.owner, t.owner, 'PAINT', { refType = 'ADMIN', amount = 0, winnerName = by, meta = { cleared = had } })
    Territory.broadcast({ id })
    Territory.logDiscord(('🗺️ [TERRITORY] Land cleared — %s'):format(t.name), {
        { name = 'Territory', value = t.name, inline = true },
        { name = 'Owner', value = tostring(t.owner or 'Unclaimed'), inline = true },
        { name = 'Cells removed', value = tostring(had), inline = true },
        { name = 'By admin', value = tostring(by or 'Staff'), inline = true },
    }, 0xf59e0b)
    return true, had
end

-- ── Map Zone editor: painting land ───────────────────────────────────────────────
-- ONLY gangs paint: a gang pays Gang XP per painted cell to grow a territory it owns. Admins create territories and hand them out
-- (by hand or through an auction) but never paint. A save ends in commitShape, which stores the shape as "custom" (cells outside
-- the territory's defined layers) and "cut" (defined cells that were removed) — so republishing the event (which refreshes the
-- base layer) never loses the painted land.

-- The price of painting land. Config.Territory.paint is the DEFAULT; an admin can change both numbers live in the tablet
-- (Territory.setPaintRate) and that wins until it is reset. 'fromConfig' tells the tablet which one is in force.
local function paintCfg()
    local p = cfg().paint or {}
    local o = paintOverride or {}
    return {
        enabled = p.enabled ~= false,
        xpPerCell = math.max(0, math.floor(tonumber(o.xpPerCell) or tonumber(p.xpPerCell) or 20)),
        maxNewCells = math.max(1, math.floor(tonumber(o.maxNewCells) or tonumber(p.maxNewCells) or 2500)),
        configXpPerCell = math.max(0, math.floor(tonumber(p.xpPerCell) or 20)),
        configMaxNewCells = math.max(1, math.floor(tonumber(p.maxNewCells) or 2500)),
        fromConfig = not (o.xpPerCell or o.maxNewCells),
    }
end
Territory.paintConfig = paintCfg

-- Admin: set the painting price live (nil = back to the config.lua value). Every admin and gang member with a tablet gets the
-- new price at once, so an open Map Zone editor re-prices its preview on the spot. A save in flight at the old price is refused
-- by Territory.paint ("The price changed") and simply asked again.
function Territory.setPaintRate(xpPerCell, maxNewCells, by)
    local xp = xpPerCell ~= nil and math.max(0, math.min(100000, math.floor(tonumber(xpPerCell) or 0))) or nil
    local mx = maxNewCells ~= nil and math.max(1, math.min(80000, math.floor(tonumber(maxNewCells) or 1))) or nil
    local okDb, err = pcall(DB.setTerritorySettings, xp or -1, mx or -1, by)
    if not okDb then return false, ('Could not save the setting: %s'):format(tostring(err)) end
    paintOverride = (xp or mx) and { xpPerCell = xp, maxNewCells = mx } or nil
    local view = paintCfg()
    for _, src in ipairs(Territory.audience()) do
        TriggerClientEvent('nova_convoytruck:territory:client:paintConfig', src, view)
    end
    return true, view
end

local function countSet(set) local n = 0 for _ in pairs(set) do n = n + 1 end return n end

-- The first OTHER territory whose current cells overlap `set` (painted land may never overlap another territory), or nil.
local function overlapsOther(t, set)
    local cs = t.def.base.cs or 25.0
    for _, o in pairs(state) do
        if o.id ~= t.id then
            local oc = compiled(o, o.level)
            local ocs = o.def.base.cs or 25.0
            local oset = (ocs == cs) and oc.set or regrid(oc.set, ocs, cs)
            for k in pairs(set) do
                if oset[k] then return o end
            end
        end
    end
    return nil
end

-- Does every `added` cell reach `current` through added cells (side or corner neighbours)? Returns ok, unreachableCount.
local function allConnected(current, added)
    local SPAN = TerritoryGeo.SPAN
    local queue, head, seen = {}, 1, {}
    for k in pairs(added) do
        local touch = false
        for dy = -1, 1 do
            for dx = -1, 1 do
                if (dx ~= 0 or dy ~= 0) and current[k + dy * SPAN + dx] then touch = true end
            end
        end
        if touch then seen[k] = true; queue[#queue + 1] = k end
    end
    while head <= #queue do
        local k = queue[head]; head = head + 1
        for dy = -1, 1 do
            for dx = -1, 1 do
                local nk = k + dy * SPAN + dx
                if (dx ~= 0 or dy ~= 0) and added[nk] and not seen[nk] then seen[nk] = true; queue[#queue + 1] = nk end
            end
        end
    end
    local total = countSet(added)
    return #queue == total, total - #queue
end

-- Stores `newSet` as the territory's shape. Optimistic on the shape revision: false when it moved in the meantime.
local function commitShape(t, newSet)
    local lists = { t.clearBase and {} or t.def.base.spans }
    for l = 1, t.level do
        local ex = t.def.expansions[l]
        if ex then lists[#lists + 1] = ex.spans end
    end
    local defSet = TerritoryGeo.cellSet(table.unpack(lists))
    local custom, cut = {}, {}
    for k in pairs(newSet) do if not defSet[k] then custom[k] = true end end
    for k in pairs(defSet) do if not newSet[k] then cut[k] = true end end
    local geo = { custom = TerritoryGeo.setToSpans(custom), cut = TerritoryGeo.setToSpans(cut), clearBase = t.clearBase or nil }
    if not DB.territorySetCustom(t.id, geo, t.rev) then return false end
    t.custom, t.cut, t.rev, t.cache = geo.custom, geo.cut, t.rev + 1, nil
    return true
end

-- A gang member reshapes the land their gang painted onto a territory they own. `spans` is the territory's whole painted-by-the-
-- gang layer: every NEW cell costs Gang XP and every cell taken out of that layer gives the same XP back (at today's price per
-- cell). expectCost is the NET price the player SAW and confirmed (negative = a refund).
-- Returns true, info | false, code, message, extra
-- (the one-save-at-a-time lock is held by Territory.paint below, from before the first database read to after the last write)
local function paintLand(src, id, spans, expectCost)
    local pc = paintCfg()
    if not pc.enabled then return false, 'DISABLED', 'Painting land is turned off on this server.' end
    local gang = GangXP.GangOf(src, true, true)
    if not gang then return false, 'NO_GANG', 'You are not in a gang.' end
    local t = state[id]
    if not t then return false, 'NOT_FOUND', 'Territory not found.' end
    if t.owner ~= gang.name then return false, 'NOT_OWNER', 'Your gang does not own this territory.' end
    if t.war then return false, 'WAR', 'This territory is in a war — it cannot be changed right now.' end
    if (cfg().expansion or {}).requireLeaderOrPermission ~= false and not GangService.HasPermission(src, 'manageGang') then
        return false, 'PERMISSION', 'Only your gang leader (or a role with the Manage Gang permission) can spend Gang XP.'
    end

    local maxCells = cfg().maxCellsPerTerritory or 80000
    local clean, _, truncated = TerritoryGeo.normalizeSpans(spans, maxCells)
    if truncated then return false, 'TOO_BIG', 'That shape is too large.' end
    local proposed = TerritoryGeo.cellSet(clean)
    local cur = compiled(t, t.level).set
    local oldCustom = TerritoryGeo.cellSet(t.custom or {})

    -- land the gang painted earlier and has now rubbed out (only the gang's own painted layer can be erased)
    local removed, nRemoved = {}, 0
    for k in pairs(oldCustom) do
        if not proposed[k] then removed[k] = true; nRemoved = nRemoved + 1 end
    end
    local added, nAdded = {}, 0
    for k in pairs(proposed) do
        if not cur[k] then added[k] = true; nAdded = nAdded + 1 end
    end
    if nAdded == 0 and nRemoved == 0 then return false, 'NOTHING', 'Paint or erase some land first.' end
    if nAdded > pc.maxNewCells then return false, 'TOO_MANY', ('You can add at most %d cells at a time.'):format(pc.maxNewCells), { max = pc.maxNewCells } end

    local newSet = {}
    for k in pairs(cur) do if not removed[k] then newSet[k] = true end end
    for k in pairs(added) do newSet[k] = true end
    if countSet(newSet) > maxCells then return false, 'TOO_BIG', 'That would make the territory too large.' end
    if nAdded > 0 then
        local other = overlapsOther(t, added)
        if other then return false, 'OVERLAP', ('That land belongs to %s.'):format(other.name) end
    end
    -- everything the gang painted must still join the territory's own land (so erase from the outer edge inwards)
    local solid, custom = {}, {}
    for k in pairs(cur) do if not oldCustom[k] then solid[k] = true end end
    if next(solid) == nil then
        -- a territory with no land of its own yet (staff only create territories, they never paint) starts at its leader ped
        local loc = t.def.location
        if not (loc and loc.x and loc.y) then
            return false, 'NO_ANCHOR', 'This territory has no leader ped position yet — ask staff to place it, then paint outwards from there.'
        end
        local cs = t.def.base.cs or 25.0
        solid[TerritoryGeo.key(math.floor(loc.x / cs), math.floor(loc.y / cs))] = true
    end
    for k in pairs(newSet) do if not solid[k] then custom[k] = true end end
    if not allConnected(solid, custom) then
        return false, 'NOT_CONNECTED', 'Painted land must stay joined to the territory — paint outwards from its edge, and erase from the outer edge inwards.'
    end

    local net = (nAdded - nRemoved) * pc.xpPerCell
    if tonumber(expectCost) ~= net then
        return false, 'STALE', 'The price changed — review it and confirm again.', { cells = nAdded, erased = nRemoved, cost = net }
    end
    local have = GangXP.Total(gang.name)
    if net > 0 and have < net then return false, 'INSUFFICIENT', 'INSUFFICIENT GANG XP', { required = net, available = have } end

    local identifier, name = Bridge.GetIdentifier(src), Bridge.GetCharacterName(src)
    local ok, res = false, nil
    local okCall, err = pcall(function()
        local total = have
        local paid = false
        if net > 0 then
            local spent, spendRes = GangXP.Spend(gang.name, net, {
                gangId = gang.id, identifier = identifier, playerName = name,
                sourceType = 'TERRITORY', sourceId = t.id, sourceName = 'Territory Painting',
                reason = ('%s — painted %d cells'):format(t.name, nAdded), metadata = { territory = t.id, cells = nAdded, erased = nRemoved },
            })
            if not spent then
                if spendRes == 'INSUFFICIENT' then
                    res = { code = 'INSUFFICIENT', message = 'INSUFFICIENT GANG XP', extra = { required = net, available = GangXP.Total(gang.name) } }
                else
                    res = { code = 'ERROR', message = 'The land could not be paid. Try again.' }
                end
                return
            end
            paid = true
            total = spendRes.total
        end
        if not commitShape(t, newSet) then
            if paid then
                GangXP.Award(gang.name, net, {
                    gangId = gang.id, identifier = identifier, playerName = name, sourceType = 'TERRITORY', sourceId = t.id,
                    sourceName = 'Territory Painting Refund', reason = ('%s — refund'):format(t.name), txType = 'REFUND',
                })
            end
            res = { code = 'STALE', message = 'The territory changed while you were paying — your XP was refunded.' }
            return
        end
        -- erased more than painted: the shape is saved, now pay the difference back into the gang's balance - but only up to what
        -- THIS gang paid for painting here since it took the territory (admin-painted or previous-owner land refunds nothing)
        if net < 0 then
            local okB, budget = pcall(DB.territoryPaintBudget, t.id, gang.name)
            local refund = math.min(-net, okB and budget or 0)
            net = -refund
            local gave, giveRes = GangXP.Award(gang.name, refund, {
                gangId = gang.id, identifier = identifier, playerName = name, sourceType = 'TERRITORY', sourceId = t.id,
                sourceName = 'Territory Land Refund', reason = ('%s — erased %d cells'):format(t.name, nRemoved), txType = 'REFUND',
                metadata = { territory = t.id, cells = nAdded, erased = nRemoved },
            })
            if gave then
                total = giveRes.total
            elseif refund > 0 then
                print(('^1[NovaConvoy][Territory] refund of %d XP to %s FAILED (%s) after erasing %d cells on %s^0'):format(refund, gang.name, tostring(giveRes), nRemoved, t.id))
            end
        end
        addHistory(t, gang.name, gang.name, 'PAINT', {
            refType = 'PAINT', refId = nAdded, winnerIdentifier = identifier, winnerName = name, amount = net, meta = { cells = nAdded, erased = nRemoved },
        })
        ok = true
        res = { cells = nAdded, erased = nRemoved, xpCost = net, total = total }
    end)
    if not okCall then
        print(('^1[NovaConvoy][Territory] paint error: %s^0'):format(tostring(err)))
        return false, 'ERROR', 'The change failed. Try again.'
    end
    if not ok then return false, res.code, res.message, res.extra end

    Territory.broadcast({ id })
    local msg
    if nAdded > 0 and nRemoved > 0 then
        msg = ('%s reshaped %s: +%d / -%d cells (%s%d XP).'):format(name or 'A member', t.name, nAdded, nRemoved, net > 0 and '-' or '+', math.abs(net))
    elseif nRemoved > 0 then
        msg = ('%s erased %d painted cells from %s (+%d XP refunded).'):format(name or 'A member', nRemoved, t.name, -net)
    else
        msg = ('%s painted %d new cells onto %s (-%d XP).'):format(name or 'A member', nAdded, t.name, net)
    end
    Territory.eachGangMember(gang.name, function(member)
        TriggerClientEvent('nova_convoytruck:territory:client:notify', member, {
            kind = 'expansion', title = nAdded > 0 and 'TERRITORY GROWN' or 'TERRITORY TRIMMED', message = msg,
        })
    end)
    if nAdded > 0 then Territory.announceRivalContact(gang.name, t) end
    Territory.logDiscord(('🗺️ [TERRITORY] Land %s — %s'):format(nAdded > 0 and (nRemoved > 0 and 'reshaped' or 'painted') or 'erased', t.name), {
        { name = 'Gang', value = gang.label or gang.name, inline = true },
        { name = 'Territory', value = t.name, inline = true },
        { name = 'Cells', value = ('+%d painted / -%d erased'):format(nAdded, nRemoved), inline = true },
        { name = 'Gang XP', value = net > 0 and ('-%d XP spent'):format(net) or (net < 0 and ('+%d XP refunded'):format(-net) or 'No change'), inline = true },
        { name = 'Gang XP now', value = tostring(tonumber(res.total) or 0), inline = true },
        { name = 'By', value = ('%s\n`%s`'):format(name or 'Unknown', identifier or 'N/A'), inline = true },
    }, net < 0 and 0x46c98b or 0xc45ee0)
    return true, res
end

-- One save at a time per territory. The lock is taken BEFORE the first database read (paying reads the gang's XP, which can yield)
-- and released after the last write, so two members saving at the same instant can never both be charged for one shape.
function Territory.paint(src, id, spans, expectCost)
    local t = state[id]
    if t then
        if t.expanding then return false, 'BUSY', 'A change is already being processed for this territory.' end
        t.expanding = true
    end
    local r = table.pack(pcall(paintLand, src, id, spans, expectCost))
    if t then t.expanding = nil end
    if not r[1] then
        print(('^1[NovaConvoy][Territory] paint error: %s^0'):format(tostring(r[2])))
        return false, 'ERROR', 'The change failed. Try again.'
    end
    return table.unpack(r, 2, r.n)
end

-- ── rival detection ──────────────────────────────────────────────────────────────

-- Do two territories touch at their CURRENT painted shape? Returns touching, contactCells.
function Territory.touching(a, b)
    local ca, cb = compiled(a, a.level), compiled(b, b.level)
    local csA, csB = a.def.base.cs or 25.0, b.def.base.cs or 25.0
    if csA == csB then return TerritoryGeo.touching(ca.set, cb.set) end
    local cs = math.max(csA, csB)
    return TerritoryGeo.touching(csA == cs and ca.set or regrid(ca.set, csA, cs), csB == cs and cb.set or regrid(cb.set, csB, cs))
end

-- A lost war shrinks the loser's land (the coloured zone on the map): the outermost `percent`% of its cells go, never leaving fewer
-- than `minLeft` cells, and only the part still joined to the cell nearest the middle is kept. The loser keeps the territory
-- itself: its owner, its leader ped and its name. Returns true, cellsRemoved | false, message.
function Territory.shrinkZone(territoryId, percent, minLeft, warId)
    local t = state[territoryId]
    if not t then return false, 'Territory not found.' end
    percent = math.max(1, math.min(100, tonumber(percent) or 25))
    minLeft = math.max(1, math.floor(tonumber(minLeft) or 20))

    local cur = compiled(t, t.level).set
    local cells, sx, sy = {}, 0, 0
    for k in pairs(cur) do
        local ix, iy = TerritoryGeo.unkey(k)
        cells[#cells + 1] = { k = k, ix = ix, iy = iy }
        sx, sy = sx + ix, sy + iy
    end
    local total = #cells
    local drop = math.min(math.floor(total * percent / 100), total - minLeft)
    if drop <= 0 then return true, 0 end

    local mx, my = sx / total, sy / total   -- the middle of the land itself (the ped can stand far from it)
    for _, c in ipairs(cells) do c.d2 = (c.ix - mx) ^ 2 + (c.iy - my) ^ 2 end
    table.sort(cells, function(a, b) return a.d2 > b.d2 end)   -- outermost first
    local keep = {}
    for i = drop + 1, total do keep[cells[i].k] = true end

    local SPAN = TerritoryGeo.SPAN
    local start = cells[total].k
    local newSet, queue, head = { [start] = true }, { start }, 1
    while head <= #queue do
        local k = queue[head]; head = head + 1
        for dy = -1, 1 do
            for dx = -1, 1 do
                local nk = k + dy * SPAN + dx
                if (dx ~= 0 or dy ~= 0) and keep[nk] and not newSet[nk] then newSet[nk] = true; queue[#queue + 1] = nk end
            end
        end
    end

    if not commitShape(t, newSet) then return false, 'The territory changed in the meantime.' end
    local removed = total - #queue
    -- reason PAINT + ref WAR: it is not an ownership change and it leaves the gang's paint-refund budget alone
    addHistory(t, t.owner, t.owner, 'PAINT', { refType = 'WAR', refId = warId, amount = 0, meta = { shrunk = removed, percent = percent } })
    Territory.broadcast({ t.id })
    print(('[NovaConvoy][Territory] %s lost %d of %d cells after a war (%d%%)'):format(t.name, removed, total, percent))
    return true, removed
end

-- Every (my territory, rival territory) pair of two DIFFERENT gangs.
-- Any gang can challenge based on size and XP — touching borders is no longer required.
local touchCache = {}
function Territory.rivalCandidates(gangName, onlyMine)
    local out = {}
    local myXp = GangXP.Total(gangName)
    for _, mine in pairs(state) do
        if mine.owner == gangName and (not onlyMine or mine.id == onlyMine.id) then
            local mineCs = mine.def.base.cs or 25.0
            local mineCells = Territory.cellCount(mine)
            local mineKm2 = math.floor((mineCells * mineCs * mineCs / 1000000) * 100 + 0.5) / 100

            for _, other in pairs(state) do
                if other.owner and other.owner ~= gangName and other.id ~= mine.id then
                    local otherCs = other.def.base.cs or 25.0
                    local otherCells = Territory.cellCount(other)
                    local otherKm2 = math.floor((otherCells * otherCs * otherCs / 1000000) * 100 + 0.5) / 100
                    local otherXp = GangXP.Total(other.owner)
                    -- the geometry test is the expensive part: cached per pair until either shape changes
                    local ck = mine.id .. '|' .. other.id
                    local cached = touchCache[ck]
                    if not cached or cached.a ~= mine.rev or cached.b ~= other.rev then
                        local tc, cc = Territory.touching(mine, other)
                        cached = { a = mine.rev, b = other.rev, touch = tc, contact = cc }
                        touchCache[ck] = cached
                    end
                    local touch, contact = cached.touch, cached.contact

                    out[#out + 1] = {
                        mineId = mine.id, mineName = mine.name, mineCells = mineCells, mineKm2 = mineKm2, mineXp = myXp,
                        theirsId = other.id, theirsName = other.name, theirsCells = otherCells, theirsKm2 = otherKm2, theirsXp = otherXp,
                        rival = other.owner, rivalLabel = gangLabel(other.owner),
                        touching = touch, contact = contact,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.mineId .. a.theirsId < b.mineId .. b.theirsId end)
    return out
end

-- After a territory of `gangName` grew: tell its members which rival territories it now TOUCHES (the candidate list holds every
-- rival pair, touching or not). Never starts a war.
function Territory.announceRivalContact(gangName, t)
    local seen, names = {}, {}
    for _, c in ipairs(Territory.rivalCandidates(gangName, t)) do
        if c.touching and not seen[c.rival] then seen[c.rival] = true; names[#names + 1] = c.rivalLabel end
    end
    if #names == 0 then return end
    Territory.eachGangMember(gangName, function(member)
        TriggerClientEvent('nova_convoytruck:territory:client:notify', member, {
            kind = 'rival', title = 'RIVAL TERRITORY',
            message = ('Your territory %s is touching %s. A rival challenge can be sent from the Territory tab.'):format(t.name, table.concat(names, ', ')),
        })
        TriggerClientEvent('nova_convoytruck:territory:client:rivalsChanged', member)
    end)
end

-- A war on a territory flags it (blocks painting, a second war and any sale) until the war ends.
function Territory.setWar(id, warId)
    local t = state[id]
    if t then t.war = warId end
end

return Territory
