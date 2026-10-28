-- ─── ox_target helpers (client) ───────────────────────────────────────────────
-- ox_target has TWO per-entity APIs and they take different things:
--   addEntity(netId, ...)        → a NETWORK id        (networked vehicles / props)
--   addLocalEntity(handle, ...)  → an ENTITY HANDLE    (local-only entities)
-- This resource used to call addEntity() with entity HANDLES. ox_target ignores
-- an id that isn't a valid network id, so those prompts (Hijack Cargo Truck,
-- Search Loot Crate, ...) silently never appeared. Everything that registers a
-- per-entity prompt now goes through these two helpers, which pick the right API.

NovaConvoy = NovaConvoy or {}

local function targetKey(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) and NetworkGetEntityIsNetworked(entity) then
        local netId = NetworkGetNetworkIdFromEntity(entity)
        if netId and netId ~= 0 then return netId end
    end
    return nil
end

--- Registers `options` on the entity. Returns the network id it was registered
--- under (pass it back to RemoveEntityTarget so removal still works after the
--- entity has despawned), or nil when it was registered as a local entity.
function NovaConvoy.AddEntityTarget(entity, options)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    local netId = targetKey(entity)
    if netId then
        exports.ox_target:addEntity(netId, options)
        return netId
    end
    exports.ox_target:addLocalEntity(entity, options)
    return nil
end

--- Removes every option this resource registered on the entity. `netId` is the
--- value AddEntityTarget returned (optional — recomputed when still possible).
function NovaConvoy.RemoveEntityTarget(entity, netId)
    netId = netId or targetKey(entity)
    if netId then
        exports.ox_target:removeEntity(netId)
    elseif entity and entity ~= 0 and DoesEntityExist(entity) then
        exports.ox_target:removeLocalEntity(entity)
    end
end
