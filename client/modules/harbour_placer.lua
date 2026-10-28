-- ─── Harbour hologram placer (client) ──────────────────────────────────────────
-- Places one thing of the harbour yard with a hologram (a see-through copy that follows the crosshair):
--   kind 'crane'   — the gantry crane (frame + cabin + wheels). Spots that it could not reach turn its lines red.
--   kind 'pickup'  — a container waiting spot (a container hologram)
--   kind 'drop'    — a container drop spot (a container hologram)
-- (Dummy container stacks are no longer placed here: they use the shared Prop Placer, prop_placer.lua,
--  context 'container_yard' — with the stack height, preview and duplicate built in.)
-- The tablet starts it with the startHarbourPlacer NUI call and saves the answer on the server
-- (server/modules/harbour_store.lua). Controls:
--   (A saved spot opens frozen at its saved point, even from far away; a new spot starts at the crosshair.)
--   Aim            the hologram follows the crosshair          [F]  freeze it where it is / follow again
--                                                                    (it carries on from where it stands and never jumps;
--                                                                     Shift+F puts it under the crosshair)
--   [Arrows]       nudge (camera-relative)                     [PgUp] / [PgDn]  raise / lower
--   [Scroll] or [ [ ] ]  rotate                                [G]  drop to the ground below
--   [Shift] fine   [Ctrl] fast                                 [E] / [Enter]  confirm    [Backspace] / [Esc]  cancel
-- Also: the saved layout arrives here from the server (harbour:sync) and is laid over the local config.

local active = false
local want = { confirm = false, cancel = false, freeze = false, ground = false }
local held = { up = false, down = false, rotL = false, rotR = false }

RegisterCommand('convoy_harbour_confirm', function() if active then want.confirm = true end end, false)
RegisterKeyMapping('convoy_harbour_confirm', 'Harbour Placer: Confirm Position', 'keyboard', 'E')
RegisterCommand('convoy_harbour_enter', function() if active then want.confirm = true end end, false)
RegisterKeyMapping('convoy_harbour_enter', 'Harbour Placer: Confirm (Enter)', 'keyboard', 'RETURN')
RegisterCommand('convoy_harbour_cancel', function() if active then want.cancel = true end end, false)
RegisterKeyMapping('convoy_harbour_cancel', 'Harbour Placer: Cancel', 'keyboard', 'BACK')
RegisterCommand('convoy_harbour_freeze', function()
    if active then
        want.freeze = true
        want.freezeSnap = IsControlPressed(0, 21)   -- Shift+F: after unfreezing, put it under the crosshair
    end
end, false)
RegisterKeyMapping('convoy_harbour_freeze', 'Harbour Placer: Freeze / Follow Aim', 'keyboard', 'F')
RegisterCommand('convoy_harbour_ground', function() if active then want.ground = true end end, false)
RegisterKeyMapping('convoy_harbour_ground', 'Harbour Placer: Drop To Ground', 'keyboard', 'G')
for _, h in ipairs({
    { 'up', 'PRIOR', 'Raise' }, { 'down', 'NEXT', 'Lower' },
    { 'rotL', 'LBRACKET', 'Rotate Left' }, { 'rotR', 'RBRACKET', 'Rotate Right' },
}) do
    RegisterCommand('+convoy_harbour_' .. h[1], function() if active then held[h[1]] = true end end, false)
    RegisterCommand('-convoy_harbour_' .. h[1], function() held[h[1]] = false end, false)
    RegisterKeyMapping('+convoy_harbour_' .. h[1], 'Harbour Placer: ' .. h[3], 'keyboard', h[2])
end

local function harbour()
    return (Config.ContainerWars and Config.ContainerWars.harbour) or {}
end

-- Where the crosshair points (a point in the world, 40 m out at most).
-- `skip` is a set of entities the ray must pass through — the holograms themselves. Without it the ray hit the
-- hologram it was moving, which pushed the hologram toward the camera and made it jump out of position.
local function aimPoint(maxDistance, skip)
    local camPos = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local rx, rz = math.rad(camRot.x), math.rad(camRot.z)
    local dx, dy, dz = -math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx)
    local ex, ey, ez = camPos.x + dx * maxDistance, camPos.y + dy * maxDistance, camPos.z + dz * maxDistance
    local sx, sy, sz = camPos.x, camPos.y, camPos.z
    for _ = 1, 6 do
        local ray = StartShapeTestRay(sx, sy, sz, ex, ey, ez, -1, PlayerPedId(), 0)
        local _, hit, pos, _, ent = GetShapeTestResult(ray)
        if hit ~= 1 then return ex, ey, ez end
        if skip and ent and ent ~= 0 and skip[ent] then
            sx, sy, sz = pos.x + dx * 0.3, pos.y + dy * 0.3, pos.z + dz * 0.3   -- carry on past the hologram
        else
            return pos.x, pos.y, pos.z
        end
    end
    return ex, ey, ez
end

local function angleDiff(a, b)   -- shortest signed turn from b to a, degrees
    return ((a - b + 180.0) % 360.0) - 180.0
end

local function ghostOf(name, alpha)
    local hash = joaat(name)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 8000) then return nil end
    local obj = CreateObject(hash, 0.0, 0.0, 0.0, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    SetEntityAlpha(obj, alpha or 170, false)
    SetEntityCollision(obj, false, false)
    FreezeEntityPosition(obj, true)
    SetEntityLodDist(obj, 3000)
    NovaDraw.outline(obj, true)
    NovaDraw.outlineColor(255, 200, 60, 255)
    return obj
end

-- A see-through, frozen copy of a ped for the ped hologram (kind 'ped': the tablet's "Place with hologram" on every ped
-- of every event). Peds are saved by their middle (the player's own position when "Move to my position" is used) and
-- spawned 1 m lower, so the hologram works in the same terms: see zOff in the placer.
local function ghostPedOf(name, alpha)
    local hash = type(name) == 'number' and name or joaat(tostring(name))
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    local ok = pcall(lib.requestModel, hash, 8000)
    if not ok then return nil end
    local ped = CreatePed(4, hash, 0.0, 0.0, 0.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    SetEntityAlpha(ped, alpha or 170, false)
    SetEntityCollision(ped, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    -- Note: Never call SetEntityDrawOutline on a CPed in GTA V / FiveM, as it causes an instant engine crash
    return ped
end

local function ghostVehOf(name, alpha)
    local hash = joaat(name)
    if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 8000) then return nil end
    local veh = CreateVehicle(hash, 0.0, 0.0, 0.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    SetEntityAlpha(veh, alpha or 170, false)
    SetEntityCollision(veh, false, false)
    FreezeEntityPosition(veh, true)
    SetEntityInvincible(veh, true)
    SetEntityLodDist(veh, 3000)
    NovaDraw.outline(veh, true)
    NovaDraw.outlineColor(50, 180, 255, 255)
    return veh
end

-- a name in the world: bold text on a dark plate with a coloured edge (client/modules/draw_util.lua)
local function label(x, y, z, text, r, g, b)
    NovaDraw.label(x, y, z, text, r or 255, g or 255, b or 255)
end

-- the four ground corners of a rectangle { x, y, heading, L along the heading, W across }
local function rectPoints(x, y, heading, L, W)
    local a = math.rad(heading)
    local fx, fy, rx, ry = -math.sin(a), math.cos(a), math.cos(a), math.sin(a)
    local hl, hw = L / 2.0, W / 2.0
    local pts = {}
    for _, s in ipairs({ { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 } }) do
        pts[#pts + 1] = { x + fx * hl * s[1] + rx * hw * s[2], y + fy * hl * s[1] + ry * hw * s[2] }
    end
    return pts
end

-- The real surface below a point: a ray straight down from just above it (then from higher up, in case it sits
-- inside something), passing through the hologram itself. Returns the surface height, or nil. This is what [G] uses:
-- PlaceObjectOnGroundProperly on a see-through ghost with no collision lands in odd places.
-- flags: 1 = the map only (the ground proper — real cranes, containers and vehicles standing there are ignored, so
-- they cannot be mistaken for the ground); 1+2+16+256 = anything solid (used by Shift+G to land ON a stack).
local GROUND_ONLY, ANYTHING_SOLID = 1, 1 + 2 + 16 + 256

local function probeDown(x, y, z, skip, flags)
    for _, top in ipairs({ z + 3.0, z + 60.0 }) do
        local sx, sy, sz = x, y, top
        for _ = 1, 8 do
            local h = StartExpensiveSynchronousShapeTestLosProbe(sx, sy, sz, x, y, z - 300.0, flags, 0, 4)
            local _, hit, pos, _, ent = GetShapeTestResult(h)
            if hit ~= 1 then break end
            if skip and ent and ent ~= 0 and skip[ent] then
                sx, sy, sz = pos.x, pos.y, pos.z - 0.05
            else
                return pos.z
            end
        end
    end
    return nil
end

-- Collision around a point is not always loaded the instant it is asked for, so this gives the game a few frames
-- before giving up (it yields, so call it from the placer thread).
local function surfaceBelow(x, y, z, skip, flags)
    for attempt = 1, 10 do
        RequestCollisionAtCoord(x, y, z)
        local s = probeDown(x, y, z, skip, flags)
        if s then return s end
        if attempt < 10 then Wait(50) end
    end
    if flags == GROUND_ONLY then
        -- some yards are built from props rather than map: fall back to anything solid, then to the engine's own
        -- ground lookup
        local s = probeDown(x, y, z, skip, ANYTHING_SOLID)
        if s then return s end
        local found, gzFound = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
        if found then return gzFound end
    end
    return nil
end

RegisterNUICallback('startHarbourPlacer', function(data, cb)
    if active then cb({ ok = false, error = 'busy' }) return end
    data = data or {}
    local kind = data.kind
    if kind ~= 'crane' and kind ~= 'pickup' and kind ~= 'drop' and kind ~= 'ped' and kind ~= 'vehicle' then cb({ ok = false, error = 'bad_kind' }) return end
    local H = harbour()
    local index = tonumber(data.index) or 1

    TriggerEvent('nova_convoytruck:client:hideTabletForPreview')

    -- ghosts ------------------------------------------------------------------
    local ghosts, ghostFrame, ghostCabin, ghostWheels, ghostBox = {}, nil, nil, {}, nil
    local gantry
    local function track(o) if o then ghosts[#ghosts + 1] = o end return o end
    local label0
    if kind == 'crane' then
        local craneModel = (H.crane and H.crane.model) or 'prop_dock_rtg_ld'
        gantry = CWGantry.get(craneModel)
        if not gantry then
            TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
            lib.notify({ title = 'Harbour', description = 'The crane model has no gantry description in config.lua.', type = 'error' })
            cb({ ok = false, error = 'no_gantry' })
            return
        end
        ghostFrame = track(ghostOf(craneModel, 150))
        ghostCabin = track(ghostOf(gantry.cabin.model, 150))
        for _ = 1, #((gantry.wheels and gantry.wheels.positions) or {}) do
            local w = gantry.wheels and gantry.wheels.model and track(ghostOf(gantry.wheels.model, 150))
            if w then ghostWheels[#ghostWheels + 1] = w end
        end
        label0 = (#(H.cranes or {}) > 1 or index > 1) and ('GANTRY CRANE #' .. index) or 'GANTRY CRANE'
        if not ghostFrame then
            for _, o in ipairs(ghosts) do DeleteEntity(o) end
            TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
            lib.notify({ title = 'Could not spawn preview', description = ('The game could not create %s here.'):format(craneModel), type = 'error', duration = 6000 })
            cb({ ok = false, error = 'spawn_failed' })
            return
        end
    elseif kind == 'ped' then
        local pedModel = tostring(data.model or '')
        if pedModel ~= '' then
            ghostBox = track(ghostPedOf(pedModel, 170))
        end
        if not ghostBox then
            ghostBox = track(ghostPedOf('g_m_y_mexgoon_01', 170)) or track(ghostPedOf('a_m_y_runner_01', 170))
        end
        label0 = 'PED' .. ((data.label and tostring(data.label) ~= '') and (' — ' .. tostring(data.label):upper()) or '')
        if not ghostBox then
            TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
            lib.notify({ title = 'Could not spawn preview', description = 'The game could not create the ped model.', type = 'error', duration = 6000 })
            cb({ ok = false, error = 'spawn_failed' })
            return
        end
    elseif kind == 'vehicle' then
        local vehModel = tostring(data.model or 'sultan')
        ghostBox = track(ghostVehOf(vehModel, 170)) or track(ghostOf(vehModel, 170))
        label0 = (data.label and tostring(data.label) ~= '') and tostring(data.label):upper() or ('VEHICLE — ' .. vehModel:upper())
        if not ghostBox then
            TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
            lib.notify({ title = 'Could not spawn preview', description = ('The game could not create vehicle model %s.'):format(vehModel), type = 'error', duration = 6000 })
            cb({ ok = false, error = 'spawn_failed' })
            return
        end
    else
        ghostBox = track(ghostOf(data.model or 'prop_container_05a', 170))
        label0 = (kind == 'pickup' and 'CONTAINER SPOT #' or 'DROP SPOT #') .. index
        if not ghostBox then
            TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')
            lib.notify({ title = 'Could not spawn preview', description = ('The game could not create %s here.'):format(tostring(data.model)), type = 'error', duration = 6000 })
            cb({ ok = false, error = 'spawn_failed' })
            return
        end
    end

    active = true
    want.confirm, want.cancel, want.freeze, want.ground, want.freezeSnap = false, false, false, false, false
    held.up, held.down, held.rotL, held.rotR = false, false, false, false

    CreateThread(function()
        local result
        local okRun, errRun = pcall(function()
            local ped = PlayerPedId()
            -- a ped is saved by its middle (1 m above the ground it stands on) and spawned at that height minus 1, so the
            -- placer works on the GROUND point and adds / removes this 1 m when it reads and writes the saved value
            local zOff = (kind == 'ped') and 1.0 or 0.0
            local heading = tonumber(data.heading) or GetEntityHeading(ped)
            local gx, gy, gz
            local frozen = false
            local grab = { 0.0, 0.0, 0.0 }   -- how far the hologram stands from the crosshair when it follows again
            if tonumber(data.x) and tonumber(data.y) and tonumber(data.z) then
                local sx, sy, sz = tonumber(data.x), tonumber(data.y), tonumber(data.z)
                -- A saved spot always opens frozen exactly where it is saved, however far away it is — it never jumps
                -- to the crosshair. [F] unfreezes it (it then carries on from where it stands); Shift+F snaps it to the
                -- crosshair. A brand-new spot has no coordinates and starts at the crosshair instead.
                gx, gy, gz, frozen = sx, sy, sz - zOff, true
                RequestCollisionAtCoord(sx, sy, sz)
                lib.notify({ title = 'Hologram', description = 'Placed at its saved point and frozen. Press F to unfreeze and move it.', type = 'inform', duration = 5000 })
            end
            local lastHint = 0
            local placing = true
            local skip = {}
            for _, o in ipairs(ghosts) do skip[o] = true end
            -- A NEW ped (no saved heading) turns to face the player as it follows the crosshair, so the ped you place is looking
            -- at you — in your point of view — instead of standing with its back to you (it used to copy the player's own
            -- heading). Rotating by hand (scroll, [ ], Ctrl/Shift turns) takes over and it stops auto-facing.
            local autoFace = (kind == 'ped') and (tonumber(data.heading) == nil)
            local dispH = heading          -- the heading shown on the hologram eases toward the real one
            local nudgeHold = 0.0          -- how long a nudge key has been held: taps are fine, holding speeds up

            while placing do
                Wait(0)
                local dt = GetFrameTime()
                local shift, ctrl = IsControlPressed(0, 21), IsControlPressed(0, 36)
                DisableControlAction(0, 200, true)
                DisableControlAction(0, 199, true)
                if IsPauseMenuActive() then SetPauseMenuActive(false) end

                local ax, ay, az = aimPoint(40.0, skip)
                if want.freeze then
                    want.freeze = false
                    frozen = not frozen
                    if not frozen and gx then
                        -- Following again: it carries on from where it stands and moves with the crosshair,
                        -- it does not fly off to wherever the crosshair points now. Shift+F snaps it to the crosshair.
                        if want.freezeSnap then grab = { 0.0, 0.0, 0.0 } else grab = { gx - ax, gy - ay, gz - az } end
                    end
                    want.freezeSnap = false
                end

                if not gx then
                    gx, gy, gz = ax, ay, az
                elseif not frozen then
                    local tx, ty, tz = ax + grab[1], ay + grab[2], az + grab[3]
                    local ddx, ddy, ddz = tx - gx, ty - gy, tz - gz
                    -- frame-rate independent easing; tiny aim noise is ignored so the hologram does not tremble
                    if ddx * ddx + ddy * ddy + ddz * ddz > 0.0036 then
                        local follow = 1.0 - math.exp(-dt * 9.0)
                        gx, gy, gz = gx + ddx * follow, gy + ddy * follow, gz + ddz * follow
                    end
                end

                -- nudging (arrows camera-relative, PgUp / PgDn height)
                local fwd, right = 0.0, 0.0
                if IsControlPressed(0, 172) then fwd = fwd + 1.0 end
                if IsControlPressed(0, 173) then fwd = fwd - 1.0 end
                if IsControlPressed(0, 175) then right = right + 1.0 end
                if IsControlPressed(0, 174) then right = right - 1.0 end
                local dz = (held.up and 1.0 or 0.0) - (held.down and 1.0 or 0.0)
                if fwd ~= 0.0 or right ~= 0.0 or dz ~= 0.0 then
                    frozen = true
                    nudgeHold = nudgeHold + dt
                    -- starts slow (a tap moves a few centimetres) and speeds up while the key stays down
                    local ramp = 0.3 + math.min(nudgeHold, 1.6) * 0.85
                    local base = ctrl and 7.0 or (shift and 0.5 or 1.8)
                    local speed = base * ramp * ((dz ~= 0.0 and fwd == 0.0 and right == 0.0) and 0.6 or 1.0)
                    local camZ = math.rad(GetGameplayCamRot(2).z)
                    local fx, fy = -math.sin(camZ), math.cos(camZ)
                    local sx, sy = math.cos(camZ), math.sin(camZ)
                    gx = gx + (fx * fwd + sx * right) * speed * dt
                    gy = gy + (fy * fwd + sy * right) * speed * dt
                    gz = gz + dz * speed * dt
                else
                    nudgeHold = 0.0
                end

                -- [G] also read straight from the control, so a stale key binding saved from an earlier version
                -- of the mapping cannot leave it dead
                if IsControlJustPressed(0, 47) or IsDisabledControlJustPressed(0, 47) then want.ground = true end

                -- rotating
                local notch = ctrl and 15.0 or (shift and 1.0 or 5.0)
                if IsControlJustPressed(0, 14) then heading = (heading - notch) % 360.0; autoFace = false end
                if IsControlJustPressed(0, 15) then heading = (heading + notch) % 360.0; autoFace = false end
                local turn = (ctrl and 90.0 or (shift and 8.0 or 38.0)) * dt
                if held.rotL then heading = (heading - turn) % 360.0; autoFace = false end
                if held.rotR then heading = (heading + turn) % 360.0; autoFace = false end
                if autoFace then
                    local pcx = GetEntityCoords(ped)
                    local fdx, fdy = pcx.x - gx, pcx.y - gy
                    if fdx * fdx + fdy * fdy > 0.25 then heading = math.deg(math.atan(-fdx, fdy)) % 360.0 end
                end

                -- the ghosts ------------------------------------------------------
                dispH = (dispH + angleDiff(heading, dispH) * (1.0 - math.exp(-dt * 16.0))) % 360.0
                local ref = { x = gx, y = gy, z = gz, heading = heading }                 -- the real values (reach checks)
                local refShown = { x = gx, y = gy, z = gz, heading = dispH }              -- what the hologram shows
                if kind == 'crane' then
                    local lay = CWGantry.layout(gantry, refShown, gx, gy)
                    SetEntityCoords(ghostFrame, lay.frame.x, lay.frame.y, lay.frame.z, false, false, false, false)
                    SetEntityHeading(ghostFrame, lay.frame.heading)
                    if ghostCabin then
                        SetEntityCoords(ghostCabin, lay.cabin.x, lay.cabin.y, lay.cabin.z, false, false, false, false)
                        SetEntityHeading(ghostCabin, lay.cabin.heading)
                    end
                    for i, w in ipairs(ghostWheels) do
                        local p = lay.wheels[i]
                        if p then SetEntityCoords(w, p.x, p.y, p.z, false, false, false, false) SetEntityHeading(w, p.heading) end
                    end
                else
                    SetEntityCoords(ghostBox, gx, gy, gz + zOff, false, false, false, false)
                    SetEntityHeading(ghostBox, dispH)
                end

                if want.ground then
                    want.ground = false
                    local surface = surfaceBelow(gx, gy, gz, skip, shift and ANYTHING_SOLID or GROUND_ONLY)
                    if surface then
                        if kind == 'crane' or kind == 'ped' then
                            gz = surface                       -- the crane's reference point is its base; a ped stands on it
                        else
                            -- the container's bottom edge rests on the surface (its origin is not always at the bottom)
                            local mn = GetModelDimensions(joaat(data.model or 'prop_container_05a'))
                            gz = surface - ((mn and mn.z) or 0.0)
                        end
                        grab = { gx - ax, gy - ay, gz - az }   -- following again starts from here
                        PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                    else
                        lib.notify({ title = 'Hologram', description = 'No ground found below it (is the area loaded?). Move closer and try again.', type = 'inform', duration = 3500 })
                    end
                    frozen = true
                end

                -- guides: the point itself, its forward line, and the rest of the yard ---------
                local hr = math.rad(heading)
                -- the hologram's own outline on the ground (the container's footprint, or the crane's two legs), a bold
                -- line out of its front with an arrow head, and a post straight up so it can be found from far away
                if kind == 'crane' then
                    for _, leg in ipairs(CWGantry.legBoxes(gantry, { x = gx, y = gy, z = gz, heading = heading }, 0.0)) do
                        NovaDraw.rect(rectPoints(leg.x, leg.y, leg.h, leg.L, leg.W), gz, 2.5, 255, 200, 60, 50, 255, 1.2)
                    end
                elseif kind == 'ped' then
                    NovaDraw.rect(rectPoints(gx, gy, heading, 0.9, 0.9), gz, 1.9, 255, 200, 60, 50, 255, 1.2)
                elseif kind == 'vehicle' then
                    NovaDraw.rect(rectPoints(gx, gy, heading, 4.8, 2.1), gz, 1.6, 50, 180, 255, 50, 255, 1.2)
                else
                    NovaDraw.rect(rectPoints(gx, gy, heading, 12.2, 2.6), gz, 2.7, 255, 200, 60, 50, 255, 1.2)
                end
                -- a ped is small, vehicle is car-length: appropriate forward direction line
                local isPed = kind == 'ped'
                local isVeh = kind == 'vehicle'
                local tipLen = isPed and 2.0 or (isVeh and 4.2 or 10.0)
                local headLen = isPed and 0.5 or (isVeh and 1.0 or 2.2)
                local tipX, tipY = gx - math.sin(hr) * tipLen, gy + math.cos(hr) * tipLen
                local arrowR, arrowG, arrowB = isVeh and 50 or 255, isVeh and 180 or 200, isVeh and 255 or 60
                NovaDraw.line(gx, gy, gz + 0.3, tipX, tipY, gz + 0.3, arrowR, arrowG, arrowB, 255, 1.4)
                for _, side in ipairs({ -1, 1 }) do
                    local back = hr + math.rad(180 + side * 28)
                    NovaDraw.line(tipX, tipY, gz + 0.3, tipX - math.sin(back) * headLen, tipY + math.cos(back) * headLen, gz + 0.3, arrowR, arrowG, arrowB, 255, 1.4)
                end
                DrawMarker(1, gx, gy, gz - 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, (isPed or isVeh) and 1.0 or 1.2, (isPed or isVeh) and 1.0 or 1.2, 0.4, arrowR, arrowG, arrowB, 140, false, false, 2, false, nil, nil, false)
                NovaDraw.line(gx, gy, gz, gx, gy, gz + 60.0, arrowR, arrowG, arrowB, 230, 1.0)
                local pc = GetEntityCoords(ped)
                label(gx, gy, gz + (isPed and 2.6 or (isVeh and 2.4 or 6.0)), ('%s  ·  %d m away'):format(label0, math.floor(#(vector3(pc.x, pc.y, pc.z) - vector3(gx, gy, gz)))), arrowR, arrowG, arrowB)

                -- the other cranes already placed (each reaches its own aisle) — not for a ped or standalone vehicle
                for i, c in ipairs((isPed or isVeh) and {} or (H.cranes or {})) do
                    if not (kind == 'crane' and i == index) and tonumber(c.x) and tonumber(c.y) then
                        DrawMarker(1, c.x, c.y, (tonumber(c.z) or gz) - 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.6, 1.6, 0.5, 240, 180, 60, 150, false, false, 2, false, nil, nil, false)
                        label(c.x, c.y, (tonumber(c.z) or gz) + 3.0, ('CRANE #%d'):format(i), 240, 180, 60)
                    end
                end
                for i, p in ipairs((isPed or isVeh) and {} or (H.pickups or {})) do
                    if not (kind == 'pickup' and i == index) then
                        local reach = true
                        if kind == 'crane' then reach = CWGantry.layout(gantry, ref, p.x, p.y).reachable end
                        local r, g, b = reach and 90 or 255, reach and 160 or 70, reach and 255 or 70
                        DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, r, g, b, 220, false, false, 2, false, nil, nil, false)
                        label(p.x, p.y, p.z + 1.4, kind == 'crane' and ('CONTAINER SPOT %d  ·  %s'):format(i, reach and 'IN REACH' or 'OUT OF REACH') or ('CONTAINER SPOT %d'):format(i), r, g, b)
                        if kind == 'crane' then NovaDraw.line(gx, gy, gz + 18.0, p.x, p.y, p.z, r, g, b, 200, 0.8) end
                    end
                end
                for i, p in ipairs((isPed or isVeh) and {} or (H.drops or {})) do
                    if not (kind == 'drop' and i == index) then
                        local reach = true
                        if kind == 'crane' then reach = CWGantry.layout(gantry, ref, p.x, p.y).reachable end
                        local r, g, b = reach and 70 or 255, reach and 214 or 70, reach and 154 or 70
                        DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, r, g, b, 220, false, false, 2, false, nil, nil, false)
                        label(p.x, p.y, p.z + 1.4, kind == 'crane' and ('DROP SPOT %d  ·  %s'):format(i, reach and 'IN REACH' or 'OUT OF REACH') or ('DROP SPOT %d'):format(i), r, g, b)
                        if kind == 'crane' then NovaDraw.line(gx, gy, gz + 18.0, p.x, p.y, p.z, r, g, b, 200, 0.8) end
                    end
                end

                -- on-screen help
                local now = GetGameTimer()
                if now - lastHint > 150 then
                    lastHint = now
                    NovaConvoy.ShowKeyHelp('PLACE ' .. label0, {
                        { { 'Aim', 'move it' }, { 'F', frozen and 'follow again, from here (Shift+F: to crosshair)' or 'freeze it here' },
                          { 'Arrows', 'nudge' }, { 'PgUp / PgDn', 'raise / lower' } },
                        { { 'Scroll or [ ]', 'rotate' }, { 'G', 'drop to the ground (Shift+G: onto what is below)' }, { 'Shift / Ctrl', 'fine / fast' } },
                        { { 'E / Enter', 'CONFIRM — saves it' }, { 'Backspace / Esc', 'CANCEL' } },
                    }, {
                        status = frozen and 'FROZEN' or 'FOLLOWING AIM',
                        info = ('X %.2f   Y %.2f   Z %.2f   Heading %.1f°'):format(gx, gy, gz + zOff, heading)
                            .. (kind == 'crane' and '  \nBlue / green lines = spots the crane can reach, red = it cannot.' or ''),
                        icon = 'arrows-up-down-left-right',
                    })
                end

                if want.cancel or IsDisabledControlJustPressed(0, 200) then placing = false
                elseif want.confirm then
                    -- A ped aimed at the sky / far past the 40 m reach (no surface under the crosshair) would be saved floating
                    -- in mid-air, far from where the player is looking, and then spawn "somewhere else". On confirm it drops
                    -- to whatever solid surface is directly below it (ground, a roof, a floor).
                    if kind == 'ped' then
                        local below = surfaceBelow(gx, gy, gz, skip, ANYTHING_SOLID)
                        if below and below < gz - 0.3 then
                            gz = below
                            lib.notify({ title = 'Hologram', description = 'The ped was in mid-air — dropped to the surface below it.', type = 'inform', duration = 3500 })
                        end
                    end
                    result = { ok = true, x = gx, y = gy, z = gz + zOff, heading = heading }   -- a ped: the saved value is its middle
                    placing = false
                end
            end
        end)

        active = false
        lib.hideTextUI()
        for _, o in ipairs(ghosts) do if DoesEntityExist(o) then DeleteEntity(o) end end
        TriggerEvent('nova_convoytruck:client:restoreTabletFromPreview')

        if not okRun then
            print(('[nova_convoytruck] harbour placer error: %s'):format(tostring(errRun)))
            lib.notify({ title = 'Placer stopped', description = 'Something went wrong while placing; nothing was changed.', type = 'error', duration = 5000 })
            cb({ ok = false, error = 'placer_error' })
        elseif result then
            PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
            result.x = tonumber(('%.4f'):format(result.x))
            result.y = tonumber(('%.4f'):format(result.y))
            result.z = tonumber(('%.4f'):format(result.z))
            result.heading = tonumber(('%.4f'):format(result.heading))
            cb(result)
        else
            cb({ ok = false })
        end
    end)
end)

-- The saved layout from the server (sent to everyone after a save, and once when this client asks).
RegisterNetEvent('nova_convoytruck:harbour:sync', function(snap)
    CWGantry.applyLayout(harbour(), snap)
end)

CreateThread(function()
    Wait(2500)
    TriggerServerEvent('nova_convoytruck:harbour:request')
end)

-- Dummy containers marked "not solid" (state cw_dummy = 0) have their collision switched off here, as they stream in.
AddStateBagChangeHandler('cw_dummy', nil, function(bagName, _, value)
    if value ~= 0 then return end
    CreateThread(function()
        local deadline = GetGameTimer() + 8000
        local ent = 0
        while ent == 0 and GetGameTimer() < deadline do
            ent = GetEntityFromStateBagName(bagName)
            if ent == 0 then Wait(100) end
        end
        if ent ~= 0 and DoesEntityExist(ent) then SetEntityCollision(ent, false, false) end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if active then lib.hideTextUI() end
end)
