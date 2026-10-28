-- ─── Nova Convoy — World Peds (client) ────────────────────────────────────────────
-- Keeps the permanent, event-independent peds standing (server/modules/world_peds.lua owns where they are):
--   · a ped is created when the player comes within SPAWN metres and removed again beyond DESPAWN — so it is made with the
--     ground around it loaded, never at join time while the player is on the other side of the map;
--   · it is re-created if it ever goes missing (another script clears peds, the ped streamed out, …);
--   · the map blip stays up for as long as the ped is enabled, wherever the player is;
--   · an admin moving / switching one off in the tablet applies at once for everyone (no restart).
-- A module registers what a ped DOES (WorldPeds.register) — this file only keeps it alive.

WorldPeds = {}

local TGT = exports.ox_target
local SPAWN, DESPAWN = 110.0, 150.0

local defs = {}     -- [id] = { scenario, blip = { sprite, colour, scale, label, shortRange } | nil, options = { ox_target options } }
local data = {}     -- [id] = the server's entry { x, y, z, heading, model, enabled }
local live = {}     -- [id] = { ped, key }
local blips = {}    -- [id] = blip handle
local warned = {}

function WorldPeds.register(id, def) defs[id] = def end
function WorldPeds.get(id) return data[id] end

local function keyOf(d) return ('%.2f,%.2f,%.2f,%.1f,%s'):format(d.x or 0, d.y or 0, d.z or 0, d.heading or 0, tostring(d.model)) end

local function dropPed(id)
    local cur = live[id]
    if not cur then return end
    if cur.ped and DoesEntityExist(cur.ped) then
        pcall(function() TGT:removeLocalEntity(cur.ped) end)
        DeleteEntity(cur.ped)
    end
    live[id] = nil
end

local function dropBlip(id)
    if blips[id] and DoesBlipExist(blips[id]) then RemoveBlip(blips[id]) end
    blips[id] = nil
end

local function ensureBlip(id)
    local d, def = data[id], defs[id]
    if blips[id] and DoesBlipExist(blips[id]) then return end
    if not def or not def.blip then return end
    local b = def.blip
    local blip = AddBlipForCoord(d.x, d.y, d.z)
    SetBlipSprite(blip, b.sprite or 1)
    SetBlipColour(blip, b.colour or 0)
    SetBlipScale(blip, b.scale or 0.85)
    SetBlipAsShortRange(blip, b.shortRange ~= false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(b.label or 'Ped')
    EndTextCommandSetBlipName(blip)
    blips[id] = blip
end

local function spawn(id)
    local d, def = data[id], defs[id]
    local hash = joaat(d.model or '')
    if not d.model or not IsModelInCdimage(hash) then
        if not warned[id] then
            warned[id] = true
            print(('[NovaConvoy] World ped "%s": model "%s" is not in this game build — check Config.'):format(id, tostring(d.model)))
        end
        return
    end
    lib.requestModel(hash)
    -- ask for the ground there and give it a moment, so the ped is not made over a hole in the map
    RequestCollisionAtCoord(d.x + 0.0, d.y + 0.0, d.z + 0.0)
    Wait(250)
    local ped = CreatePed(4, hash, d.x + 0.0, d.y + 0.0, d.z - 1.0, (d.heading or 0.0) + 0.0, false, true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return end
    SetEntityAsMissionEntity(ped, true, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    FreezeEntityPosition(ped, true)
    if def.scenario then TaskStartScenarioInPlace(ped, def.scenario, 0, true) end
    if def.options then TGT:addLocalEntity(ped, def.options) end
    live[id] = { ped = ped, key = keyOf(d) }
end

local function apply(list)
    local seen = {}
    for _, p in ipairs(list or {}) do
        if p.id then
            seen[p.id] = true
            local old = data[p.id]
            data[p.id] = p
            -- moved / re-modelled / switched off: the old ped and blip go; the loop below makes the new ones
            if old and (not p.enabled or keyOf(old) ~= keyOf(p)) then dropPed(p.id); dropBlip(p.id) end
        end
    end
    for id in pairs(data) do
        if not seen[id] then data[id] = nil; dropPed(id); dropBlip(id) end
    end
end

local function refresh()
    local res = lib.callback.await('nova_convoytruck:worldPeds:list', false)
    if res and res.ok then apply(res.peds) return true end
    return false
end

RegisterNetEvent('nova_convoytruck:worldPeds:changed', function(list) apply(list) end)

CreateThread(function()
    -- the server may still be starting when this client is: retry until the first answer
    Wait(1000)
    for _ = 1, 15 do
        if refresh() then break end
        Wait(3000)
    end
    local lastRefresh = GetGameTimer()
    while true do
        Wait(1500)
        if GetGameTimer() - lastRefresh > 60000 then   -- heals a missed update
            lastRefresh = GetGameTimer()
            pcall(refresh)
        end
        local me = GetEntityCoords(PlayerPedId())
        for id, d in pairs(data) do
            if defs[id] and d.enabled and d.x then
                ensureBlip(id)
                local cur = live[id]
                if cur and not DoesEntityExist(cur.ped) then live[id] = nil; cur = nil end
                local dist = #(me - vector3(d.x, d.y, d.z))
                if dist < SPAWN and not cur then
                    pcall(spawn, id)
                elseif dist > DESPAWN and cur then
                    dropPed(id)
                end
            else
                dropPed(id)
                dropBlip(id)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for id in pairs(live) do dropPed(id) end
    for id in pairs(blips) do dropBlip(id) end
end)
