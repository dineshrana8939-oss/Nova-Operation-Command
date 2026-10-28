-- ─── Nova Convoy — staff tag over the head (client) ───────────────────────────────────────────────────────────────
-- Draws the "ADMIN" / "EVENT STAFF" tag that server/modules/staff_tag.lua put in a player's state bag (novaStaffTag), over that player's
-- head, for everyone within range. The switch is in the Admin Panel → Settings; the choice is remembered on this computer (a client
-- key-value) and asked for again after joining, and the server only honours it for someone who really is an admin / staff member.

local KVP = 'nova_convoytruck:staffTag'
local RANGE = 25.0
local COLOURS = { ['ADMIN'] = { 181, 67, 62 }, ['EVENT STAFF'] = { 79, 148, 230 } }

local function remembered() return GetResourceKvpInt(KVP) == 1 end

RegisterNUICallback('staffTag:get', function(_, cb)
    local res = lib.callback.await('nova_convoytruck:staffTag:get', false)
    cb(res or { ok = false })
end)

RegisterNUICallback('staffTag:set', function(data, cb)
    local on = type(data) == 'table' and data.enabled == true
    SetResourceKvpInt(KVP, on and 1 or 0)
    TriggerServerEvent('nova_convoytruck:staffTag:set', on)
    cb({ ok = true })
end)

-- after joining (or a resource restart) put the remembered choice back; the server ignores it for anyone who may not wear a tag
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(500) end
    Wait(6000)
    if remembered() then TriggerServerEvent('nova_convoytruck:staffTag:set', true) end
end)

-- who is tagged and near: looked at four times a second; the drawing itself (every frame) only runs while someone is in range
local tagged = {}
CreateThread(function()
    local me = PlayerId()
    while true do
        local list, n = {}, 0
        local mine = GetEntityCoords(PlayerPedId())
        for _, pid in ipairs(GetActivePlayers()) do
            if pid ~= me then
                local label = Player(GetPlayerServerId(pid)).state.novaStaffTag
                if label then
                    local ped = GetPlayerPed(pid)
                    if ped ~= 0 and #(GetEntityCoords(ped) - mine) <= RANGE then n = n + 1; list[n] = { ped = ped, label = label } end
                end
            end
        end
        tagged = list
        Wait(250)
    end
end)

CreateThread(function()
    while true do
        if #tagged == 0 then
            Wait(300)
        else
            for _, t in ipairs(tagged) do
                if DoesEntityExist(t.ped) and not IsEntityDead(t.ped) then
                    local head = GetPedBoneCoords(t.ped, 31086, 0.0, 0.0, 0.0)
                    local c = COLOURS[t.label] or COLOURS['EVENT STAFF']
                    NovaDraw.label(head.x, head.y, head.z + 0.55, t.label, c[1], c[2], c[3], { scale = 0.34, maxDist = RANGE + 5.0 })
                end
            end
            Wait(0)
        end
    end
end)
