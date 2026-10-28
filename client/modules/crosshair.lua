-- Custom crosshair: /crosshair opens a designer panel (colour, shape, size,
-- thickness, gap, opacity, outline, centre dot, recoil pulse). The chosen design
-- is saved per player (client KVP) and drawn by the NUI while the player is in a
-- TDM match or a Practice Range session — the game's own reticle is hidden then.
-- NovaInTdm / NovaInPractice are set by tdm.lua / practice_range.lua.

local KVP = 'nova_convoytruck:crosshair'

local SHAPES = { cross = true, tshape = true, dot = true, circle = true, diamond = true, chevron = true }

local DEFAULT = {
    enabled = true,
    shape = 'cross',
    color = '#d8b45c',
    size = 10,        -- arm length / radius
    thickness = 2,
    gap = 5,
    opacity = 100,
    outline = true,
    centerDot = false,
    dotSize = 2,
    pulse = true,     -- gap kicks outwards while firing
}

local cfg = {}
local panelOpen = false
local shown = false

local function clamp(v, lo, hi, fallback)
    v = tonumber(v)
    if not v then return fallback end
    return math.max(lo, math.min(hi, v))
end

-- Whatever the NUI (or a corrupt KVP) sends, only known keys / sane ranges are kept.
local function sanitize(t)
    t = type(t) == 'table' and t or {}
    local out = {}
    out.enabled = t.enabled ~= false
    out.shape = SHAPES[t.shape] and t.shape or DEFAULT.shape
    out.color = (type(t.color) == 'string' and t.color:match('^#%x%x%x%x%x%x$')) and t.color or DEFAULT.color
    out.size = clamp(t.size, 2, 40, DEFAULT.size)
    out.thickness = clamp(t.thickness, 1, 10, DEFAULT.thickness)
    out.gap = clamp(t.gap, 0, 30, DEFAULT.gap)
    out.opacity = clamp(t.opacity, 10, 100, DEFAULT.opacity)
    out.outline = t.outline ~= false
    out.centerDot = t.centerDot == true
    out.dotSize = clamp(t.dotSize, 1, 8, DEFAULT.dotSize)
    out.pulse = t.pulse ~= false
    return out
end

local function load()
    local raw = GetResourceKvpString(KVP)
    local ok, decoded = false, nil
    if raw and raw ~= '' then ok, decoded = pcall(json.decode, raw) end
    cfg = sanitize(ok and decoded or DEFAULT)
end

local function pushConfig()
    SendNUIMessage({ action = 'crosshairConfig', cfg = cfg })
end

local function isArmed()
    local weapon = GetSelectedPedWeapon(PlayerPedId())
    return weapon ~= 0 and weapon ~= `WEAPON_UNARMED`
end

local function wanted()
    return cfg.enabled and not panelOpen and (NovaInTdm or NovaInPractice) and isArmed()
        and not IsPauseMenuActive()
end

-- ── Panel ────────────────────────────────────────────────────────────────────

local openedFromTablet = false   -- true when the Gang Tablet's Settings button opened it: the tablet keeps the mouse afterwards

local function openPanel(fromTablet)
    if panelOpen then return end
    if not cfg.shape then load() end
    panelOpen = true
    openedFromTablet = fromTablet == true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'crosshairPanel', open = true, cfg = cfg })
end

RegisterCommand('crosshair', function() openPanel(false) end, false)

-- The Gang Tablet's Settings → "Open Crosshair Designer" button.
RegisterNUICallback('crosshair:openPanel', function(_, cb)
    openPanel(true)
    cb({ ok = true })
end)

RegisterNUICallback('crosshair:save', function(data, cb)
    cfg = sanitize(data)
    SetResourceKvp(KVP, json.encode(cfg))
    pushConfig()
    cb('ok')
end)

-- The Gang Tablet's "Custom Crosshair" switch. It flips ONLY `enabled` on this client's own saved design (and saves it
-- to this player's KVP like the designer does), so it can never overwrite a design with the UI's defaults. The same
-- `enabled` flag the designer panel edits, so the two always agree.
RegisterNUICallback('crosshair:setEnabled', function(data, cb)
    if not cfg.shape then load() end
    cfg.enabled = type(data) == 'table' and data.enabled == true
    SetResourceKvp(KVP, json.encode(cfg))
    pushConfig()
    cb({ ok = true, enabled = cfg.enabled })
end)

-- Lets the tablet show the real saved state when it opens (the push at resource start can land before the UI exists).
RegisterNUICallback('crosshair:getConfig', function(_, cb)
    if not cfg.shape then load() end
    pushConfig()
    cb({ ok = true, cfg = cfg })
end)

RegisterNUICallback('crosshair:close', function(_, cb)
    panelOpen = false
    -- back to the Gang Tablet it was opened from (it still needs the mouse), otherwise release the game
    SetNuiFocus(openedFromTablet, openedFromTablet)
    openedFromTablet = false
    SendNUIMessage({ action = 'crosshairPanel', open = false })
    cb('ok')
end)

-- ── Live drawing ─────────────────────────────────────────────────────────────

CreateThread(function()
    load()
    Wait(1500)
    pushConfig()
    local lastShot = 0
    while true do
        if wanted() then
            if not shown then
                shown = true
                SendNUIMessage({ action = 'crosshairShow', show = true })
            end
            HideHudComponentThisFrame(14) -- the game's own reticle
            if cfg.pulse and IsPedShooting(PlayerPedId()) then
                local now = GetGameTimer()
                if now - lastShot > 70 then
                    lastShot = now
                    SendNUIMessage({ action = 'crosshairShot' })
                end
            end
            Wait(0)
        else
            if shown then
                shown = false
                SendNUIMessage({ action = 'crosshairShow', show = false })
            end
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if panelOpen then SetNuiFocus(false, false) end
end)
