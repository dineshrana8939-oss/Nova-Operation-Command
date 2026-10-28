-- ─── Nova Convoy — Saved Route Templates (server) ─────────────────────────────
-- Build a layout once — a CONVOY's route/checkpoints/airdrops, a HOT_CARGO's
-- spawn+dropoff zones, or a GANG_AIRDROP's drop zones — save it under a
-- name, then import that exact layout into any other event of the SAME kind
-- afterward instead of rebuilding it from scratch every time. Originally
-- only covered CONVOY (the only screen with a "Route" tab at all); this
-- covers all three, sharing one table/list/search/delete-all UI (the Saved
-- Routes tab) with a `kind` column deciding which fields on a given row
-- actually mean anything.

SavedRoutes = {}

local VALID_KINDS = { CONVOY = true, HOT_CARGO = true, GANG_AIRDROP = true, GANG_RACE = true, CONTAINER_WARS = true }

function SavedRoutes.getAll()
    return DB.getSavedRoutesList()
end

-- payload shape depends on kind:
--   CONVOY:       { route, checkpoints, airdrops }  (RouteBuilder's own shape)
--   HOT_CARGO:    { spawnZones, dropoffZones }
--   GANG_AIRDROP: { airdropZones }
--   GANG_RACE:    { rallyStages }
--   CONTAINER_WARS: { yard = { crane, pickups, drops, dummies, carry }, zone = { points } } — a whole harbour yard
--                   layout (container spots, drops, dummy stacks, planned crane routes) plus the bidding perimeter
-- Snapshot, not a live link — later edits on the source event never touch
-- what's saved here.
function SavedRoutes.save(source, name, kind, payload)
    if not Bridge.HasCreatorAccess(source) then return false, 'Not authorized.' end
    name = tostring(name or ''):sub(1, 100)
    if #name < 2 then return false, 'Give the template a name (at least 2 characters).' end
    kind = VALID_KINDS[kind] and kind or 'CONVOY'
    payload = payload or {}

    -- a CONTAINER_WARS payload arrives as { yard, zone }; it is stored whole in the container_wars column
    if kind == 'CONTAINER_WARS' then
        local yard = type(payload.yard) == 'table' and payload.yard or {}
        payload.containerWars = { yard = yard, zone = type(payload.zone) == 'table' and payload.zone or { points = {} } }
    end

    local rawProps = payload.eventProps or payload.props or (payload.yard and payload.yard.props)
    if type(rawProps) == 'table' then
        payload.eventProps = (EventProps and EventProps.sanitize) and EventProps.sanitize(rawProps) or rawProps
        if kind == 'CONTAINER_WARS' and payload.containerWars and payload.containerWars.yard then
            payload.containerWars.yard.props = payload.eventProps
        end
    end

    local isEmpty
    if kind == 'CONTAINER_WARS' then
        local y = payload.containerWars.yard
        isEmpty = #(y.pickups or {}) == 0 and #(y.drops or {}) == 0 and #(y.dummies or {}) == 0 and #(y.cranes or {}) == 0 and #(payload.eventProps or {}) == 0
    elseif kind == 'HOT_CARGO' then
        isEmpty = (#(payload.spawnZones or {}) == 0) and (#(payload.dropoffZones or {}) == 0)
    elseif kind == 'GANG_AIRDROP' then
        isEmpty = #(payload.airdropZones or {}) == 0
    elseif kind == 'GANG_RACE' then
        isEmpty = #(payload.rallyStages or {}) == 0
    else
        isEmpty = #(payload.route or {}) == 0
    end
    if isEmpty then return false, 'Nothing to save — there\'s nothing configured yet.' end

    -- Names are unique (case-insensitive) so the picker never shows two
    -- entries that look identical with no way to tell them apart. Checked
    -- across ALL kinds, not just this one — one shared name list is simpler
    -- to reason about than "unique per kind."
    for _, existing in ipairs(DB.getSavedRoutesList()) do
        if existing.name:lower() == name:lower() then
            return false, ('A saved template named "%s" already exists — pick a different name.'):format(existing.name)
        end
    end

    local createdBy = Bridge.GetIdentifier(source)
    local createdByName = Bridge.GetCharacterName(source)
    -- pcall + the real error text surfaced to the admin (not swallowed into
    -- a generic "failed" message) — a save failure here has no console
    -- access from the tablet side to fall back on, so whatever actually
    -- went wrong (a bad column, an oversized JSON payload, anything) needs
    -- to reach the UI directly to be diagnosable at all.
    local ok, id = pcall(DB.createSavedRoute, name, kind, payload, createdBy, createdByName)
    if not ok then
        lib.print.error(('[NovaConvoy] SavedRoutes.save DB error: %s'):format(tostring(id)))
        return false, ('Database write failed: %s'):format(tostring(id))
    end
    if not id then return false, 'Database write failed — insert returned no id (check the server console for a SQL error).' end
    return true, id
end

function SavedRoutes.update(source, id, payload)
    if not Bridge.HasCreatorAccess(source) then return false, 'Not authorized.' end
    id = tonumber(id)
    if not id then return false, 'Invalid template ID.' end
    local saved = DB.getSavedRoute(id)
    if not saved then return false, 'Saved template not found.' end
    if saved.prebuilt then return false, 'Prebuilt tracks are built in and cannot be overwritten.' end

    local kind = saved.kind or 'CONVOY'
    payload = payload or {}

    if kind == 'CONTAINER_WARS' then
        local yard = type(payload.yard) == 'table' and payload.yard or {}
        payload.containerWars = { yard = yard, zone = type(payload.zone) == 'table' and payload.zone or { points = {} } }
    end

    local rawProps = payload.eventProps or payload.props or (payload.yard and payload.yard.props)
    if type(rawProps) == 'table' then
        payload.eventProps = (EventProps and EventProps.sanitize) and EventProps.sanitize(rawProps) or rawProps
        if kind == 'CONTAINER_WARS' and payload.containerWars and payload.containerWars.yard then
            payload.containerWars.yard.props = payload.eventProps
        end
    end

    local updatedByName = Bridge.GetCharacterName(source)
    local ok, err = pcall(DB.updateSavedRoute, id, payload, updatedByName)
    if not ok then
        lib.print.error(('[NovaConvoy] SavedRoutes.update DB error: %s'):format(tostring(err)))
        return false, ('Database update failed: %s'):format(tostring(err))
    end
    return true, id
end

-- Regenerates every id in the saved payload before handing it back —
-- importing the SAME template twice (into two different events, or twice
-- into the same one) must never let ids collide, since every screen keys
-- its {#each} lists and its own config lookups (checkpoints/airdrops off a
-- route point's id, in CONVOY's case) off exactly those ids.
function SavedRoutes.import(source, id)
    if not Bridge.HasCreatorAccess(source) then return false, 'Not authorized.' end
    local saved = DB.getSavedRoute(id)
    if not saved then return false, 'Saved template not found.' end
    local kind = saved.kind or 'CONVOY'

    local function freshId(prefix, i)
        return ('%s_import_%d_%d_%d'):format(prefix, os.time(), math.random(0, 999999), i)
    end

    local function remapProps(list)
        local out = {}
        for i, p in ipairs(list or {}) do
            local copy = {}
            for k, v in pairs(p) do copy[k] = v end
            copy.uid = freshId('prop', i)
            out[i] = copy
        end
        return out
    end

    if kind == 'CONTAINER_WARS' then
        -- positions only (nothing refers to an id): handed back as it was saved
        local cw = saved.containerWars or {}
        local yardProps = remapProps(saved.eventProps or (cw.yard and cw.yard.props) or {})
        local yard = cw.yard or {}
        if #yardProps > 0 then yard.props = yardProps end
        return true, {
            id = saved.id, prebuilt = saved.prebuilt,
            kind = kind, name = saved.name, yard = yard, zone = cw.zone or { points = {} },
            props = yardProps, eventProps = yardProps,
        }
    end

    if kind == 'HOT_CARGO' then
        local function remapZones(list, prefix)
            local out = {}
            for i, z in ipairs(list or {}) do
                local copy = {}
                for k, v in pairs(z) do copy[k] = v end
                copy.id = freshId(prefix, i)
                out[i] = copy
            end
            return out
        end
        local hotProps = remapProps(saved.eventProps)
        return true, {
            id = saved.id, prebuilt = saved.prebuilt,
            kind = kind, name = saved.name,
            spawnZones = remapZones(saved.spawnZones, 'spawn'),
            dropoffZones = remapZones(saved.dropoffZones, 'dropoff'),
            props = hotProps, eventProps = hotProps,
        }
    elseif kind == 'GANG_AIRDROP' then
        local out = {}
        for i, z in ipairs(saved.airdropZones or {}) do
            local copy = {}
            for k, v in pairs(z) do copy[k] = v end
            copy.id = freshId('drop', i)
            out[i] = copy
        end
        local airdropProps = remapProps(saved.eventProps)
        return true, { id = saved.id, prebuilt = saved.prebuilt, kind = kind, name = saved.name, airdropZones = out, props = airdropProps, eventProps = airdropProps }
    elseif kind == 'GANG_RACE' then
        local out = {}
        for i, s in ipairs(saved.rallyStages or {}) do
            local copy = {}
            for k, v in pairs(s) do copy[k] = v end
            copy.id = freshId('stage', i)
            copy.order = i - 1
            out[i] = copy
        end
        local raceProps = remapProps(saved.eventProps)
        return true, { id = saved.id, prebuilt = saved.prebuilt, kind = kind, name = saved.name, rallyStages = out, props = raceProps, eventProps = raceProps }
    end

    -- CONVOY: route points cross-reference each other (checkpoints/airdrops
    -- attach via a route point's own id), so this one needs a real id MAP,
    -- not just a fresh id per entry — every reference has to follow its
    -- point to the new id, not just get a new id of its own.
    local idMap = {}
    local newRoute = {}
    for i, p in ipairs(saved.route or {}) do
        local newPointId = freshId('pt', i)
        idMap[p.id] = newPointId
        local copy = {}
        for k, v in pairs(p) do copy[k] = v end
        copy.id = newPointId
        copy.order = i - 1
        newRoute[i] = copy
    end

    local function remapByRoutePointId(list)
        local out = {}
        for _, item in ipairs(list or {}) do
            local newPointId = idMap[item.routePointId]
            if newPointId then
                local copy = {}
                for k, v in pairs(item) do copy[k] = v end
                copy.routePointId = newPointId
                out[#out + 1] = copy
            end
            -- An entry whose routePointId doesn't map to anything in
            -- newRoute (a stale/orphaned config from before) is silently
            -- dropped rather than imported — it wouldn't have anything to
            -- attach to anyway.
        end
        return out
    end

    local convoyProps = remapProps(saved.eventProps)
    return true, {
        id = saved.id, prebuilt = saved.prebuilt,
        kind = kind, name = saved.name,
        route = newRoute,
        checkpoints = remapByRoutePointId(saved.checkpoints),
        airdrops = remapByRoutePointId(saved.airdrops),
        props = convoyProps,
        eventProps = convoyProps,
    }
end

function SavedRoutes.delete(source, id)
    if not Bridge.HasCreatorAccess(source) then return false, 'Not authorized.' end
    local saved = DB.getSavedRoute(id)
    if saved and saved.prebuilt then return false, 'Prebuilt tracks are built in and cannot be deleted.' end
    DB.deleteSavedRoute(id)
    return true
end

function SavedRoutes.deleteAll(source)
    if not Bridge.HasCreatorAccess(source) then return false, 'Not authorized.' end
    DB.deleteAllSavedRoutes() -- removes custom templates only; prebuilt tracks are kept
    return true
end

-- ── Prebuilt race tracks ───────────────────────────────────────────────────────
-- data/tracks/ holds a collection of ready-made race tracks (credit + licence
-- note in data/tracks/CREDITS.md). Each one is added to Saved Routes ONCE as a
-- Gang Rally template named "[Prebuilt] <category> - <track>", so it shows up in
-- the race builder's template picker (with a map preview) and in the Saved
-- Routes tab like any other template. Prebuilt tracks are PROTECTED: they cannot
-- be deleted (single or "Delete All" — only templates users created can be), and
-- any that are missing (e.g. a wiped table) are added back on the next restart.
-- Tracks added to the folder later are picked up the same way.

-- One checkpoint per track point. The gate's half-width (distance between its
-- left and right offset markers) becomes the checkpoint radius.
local function trackToStages(points)
    local stages, n = {}, #points
    for i, p in ipairs(points) do
        local c = p.coords or {}
        local radius = 20.0
        local l, r = p.offset and p.offset.left, p.offset and p.offset.right
        if l and r and l.x and l.y and r.x and r.y then
            local half = math.sqrt((l.x - r.x) ^ 2 + (l.y - r.y) ^ 2) / 2
            radius = math.max(5.0, math.min(100.0, math.floor(half * 10 + 0.5) / 10))
        end
        local kind = (i == 1 and 'START') or (i == n and 'DESTINATION') or 'CHECKPOINT'
        local name = (kind == 'START' and 'Grid Start Line') or (kind == 'DESTINATION' and 'Finish Line') or ('Checkpoint ' .. i)
        stages[i] = {
            id = 'stage_' .. i, order = i - 1, kind = kind, name = name, label = name,
            x = c.x, y = c.y, z = c.z, heading = ((c.h or 0.0) % 360.0), radius = radius,
        }
    end
    return stages
end

function SavedRoutes.seedPrebuiltTracks()
    local resource = GetCurrentResourceName()
    local rawIndex = LoadResourceFile(resource, 'data/tracks/index.json')
    if not rawIndex then return end
    local okIdx, index = pcall(json.decode, rawIndex)
    if not okIdx or type(index) ~= 'table' then return end

    local existing = {}
    for _, row in ipairs(DB.getSavedRoutesList()) do existing[row.name:lower()] = true end

    local added = 0
    for _, entry in ipairs(index) do
        local category = tostring(entry.category or ''):gsub('/', ' ')
        local name = ('[Prebuilt] %s - %s'):format(category, entry.name)
        if not existing[name:lower()] then
            local raw = LoadResourceFile(resource, entry.file)
            local ok, points = pcall(json.decode, raw or '')
            if ok and type(points) == 'table' and #points >= 2 then
                local okIns = pcall(DB.createSavedRoute, name, 'GANG_RACE', { rallyStages = trackToStages(points) }, 'prebuilt', 'Prebuilt Tracks')
                if okIns then
                    added = added + 1
                    if added % 8 == 0 then Wait(0) end
                end
            end
        end
    end

    if added > 0 then
        print(('[NovaConvoy] Added %d prebuilt race track(s) to Saved Routes.'):format(added))
    end
end

return SavedRoutes
