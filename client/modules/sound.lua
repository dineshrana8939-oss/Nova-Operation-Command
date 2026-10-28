-- ─── Notification sounds (client) ─────────────────────────────────────────────
-- Picks a sound file for a server notification from Config.Sounds and has the NUI play it
-- (web/src/lib/audio/soundPlayer.js). Files live in the resource's sounds/ folder.

NovaSound = {}

local EXT = { mp3 = true, ogg = true, wav = true }
local lastFile, lastAt = nil, 0
local testing = false   -- the admin test command: never skip a repeat

-- 'file.mp3' | { file, volume } | false  ->  file, volume   (nil = nothing matched, false = silent)
local function resolve(v)
    if v == nil then return nil end
    if v == false then return false end
    -- a name from Config.Sounds.library stands for its file (and volume)
    local lib_ = Config.Sounds and Config.Sounds.library
    if type(v) == 'string' and type(lib_) == 'table' and lib_[v] ~= nil then v = lib_[v] end
    if v == false then return false end
    local file, vol = v, 1.0
    if type(v) == 'table' then file, vol = v.file, tonumber(v.volume) or 1.0 end
    -- { file = 'popup', volume = 0.4 }: the name inside a rule may be a library name too
    if type(file) == 'string' and type(lib_) == 'table' and lib_[file] ~= nil then
        local e = lib_[file]
        if e == false then return false end
        if type(e) == 'table' then file, vol = e.file, vol * (tonumber(e.volume) or 1.0) else file = e end
    end
    if type(file) ~= 'string' then return nil end
    local ext = file:match('%.(%w+)$')
    if file:find('[/\\]') or not ext or not EXT[ext:lower()] then
        print(('^1[NovaConvoy][Sounds] ignoring "%s" — use a plain file name (.mp3/.ogg/.wav) from the sounds folder^0'):format(file))
        return nil
    end
    return file, vol
end

local function first(...)
    for i = 1, select('#', ...) do
        local file, vol = resolve((select(i, ...)))
        if file == false then return false end
        if file then return file, vol end
    end
end

function NovaSound.playFile(file, volume)
    local cfg = Config.Sounds or {}
    if cfg.enabled == false then return end
    local f, v = resolve(file)
    if not f then return end
    -- a notice and a banner often fire together for the same event: don't play one file twice on top of itself
    local t = GetGameTimer()
    if not testing and lastFile == f and t - lastAt < 1200 then return end
    lastFile, lastAt = f, t
    SendNUIMessage({ action = 'playSound', file = f, volume = math.max(0.0, math.min(1.0, (tonumber(cfg.volume) or 0.7) * (volume or v or 1.0))) })
end

local function playResolved(file, vol)
    if file then NovaSound.playFile(file, vol) end
end

-- An on-screen announcement banner: title -> status badge -> kind -> routes.banner -> default
function NovaSound.banner(title, kind, status)
    local cfg = Config.Sounds or {}
    if cfg.enabled == false then return end
    local byTitle
    if type(title) == 'string' and type(cfg.byTitle) == 'table' then
        local lower = title:lower()
        for _, rule in ipairs(cfg.byTitle) do
            if type(rule.match) == 'string' and lower:find(rule.match:lower(), 1, true) then byTitle = rule.sound break end
        end
    end
    local byStatus = type(status) == 'string' and cfg.byStatus and cfg.byStatus[status:upper()] or nil
    local byKind = type(kind) == 'string' and cfg.byKind and cfg.byKind[kind] or nil
    playResolved(first(byTitle, byStatus, byKind, cfg.routes and cfg.routes.banner, cfg.default))
end

-- A named route: 'reward', 'territoryNotice' ...
function NovaSound.route(name, sub)
    local cfg = Config.Sounds or {}
    if cfg.enabled == false then return end
    playResolved(first(sub, cfg.routes and cfg.routes[name], cfg.default))
end

function NovaSound.territoryNotice(kind)
    local cfg = Config.Sounds or {}
    NovaSound.route('territoryNotice', type(kind) == 'string' and cfg.byNoticeKind and cfg.byNoticeKind[kind] or nil)
end

-- The UI click sound (Config.Sounds.uiClick). The NUI asks for it once and plays it on every click of a
-- tab / button / toggle in every panel (web/src/lib/audio/uiClickSound.js).
RegisterNUICallback('uiSoundConfig', function(_, cb)
    local cfg = Config.Sounds or {}
    local ui = cfg.uiClick
    if cfg.enabled == false or type(ui) ~= 'table' or ui.enabled == false then cb({ enabled = false }) return end
    local file, vol = resolve(ui.sound)
    if not file then cb({ enabled = false }) return end
    local v = (tonumber(cfg.volume) or 0.7) * (vol or 1.0) * (tonumber(ui.volume) or 1.0)
    cb({ enabled = true, file = file, volume = math.max(0.0, math.min(1.0, v)) })
end)

-- Other scripts:  exports.nova_convoytruck:PlaySound('rival')   -- a library name or a file name
exports('PlaySound', function(name)
    NovaSound.playFile(name)
end)

-- ── admin test command (server/modules/sound_test.lua checks the admin, this plays) ──────────────
local function say(text, kind)
    lib.notify({ title = 'Sound test', description = text, type = kind or 'inform', duration = 9000 })
end

local function describe(v)
    if v == false then return 'silent' end
    if type(v) == 'table' then return ('%s (vol %s)'):format(tostring(v.file), tostring(v.volume or 1.0)) end
    return tostring(v)
end

local function configSummary()
    local cfg = Config.Sounds or {}
    local lines = {}
    for name, v in pairs(cfg.library or {}) do lines[#lines + 1] = ('LIBRARY %s = %s'):format(name, describe(v)) end
    lines[#lines + 1] = ('default: %s'):format(describe(cfg.default))
    for name, v in pairs(cfg.routes or {}) do lines[#lines + 1] = ('route %s: %s'):format(name, describe(v)) end
    for _, tbl in ipairs({ { 'status', cfg.byStatus }, { 'kind', cfg.byKind }, { 'notice', cfg.byNoticeKind } }) do
        for k, v in pairs(tbl[2] or {}) do lines[#lines + 1] = ('%s %s: %s'):format(tbl[1], k, describe(v)) end
    end
    for _, r in ipairs(cfg.byTitle or {}) do lines[#lines + 1] = ('title "%s": %s'):format(tostring(r.match), describe(r.sound)) end
    return table.concat(lines, '\n')
end

RegisterNetEvent('nova_convoytruck:sound:test', function(args)
    args = type(args) == 'table' and args or {}
    local mode = args[1]
    if not mode or mode == 'list' or mode == 'help' then
        say(configSummary() .. '\n\nUsage: file.mp3 | status X | kind X | title X | route X | notice X')
        return
    end
    local rest = table.concat(args, ' ', 2)
    testing = true
    local ok = true
    if mode:find('%.%w+$') or (Config.Sounds and Config.Sounds.library and Config.Sounds.library[mode] ~= nil) then
        NovaSound.playFile(mode)
    elseif mode == 'status' and rest ~= '' then NovaSound.banner(nil, nil, rest)
    elseif mode == 'kind' and rest ~= '' then NovaSound.banner(nil, rest, nil)
    elseif mode == 'title' and rest ~= '' then NovaSound.banner(rest, nil, nil)
    elseif mode == 'route' and rest ~= '' then NovaSound.route(rest)
    elseif mode == 'notice' and rest ~= '' then NovaSound.territoryNotice(rest)
    else ok = false end
    testing = false
    if ok then say(('Played: %s'):format(table.concat(args, ' ')), 'success')
    else say('Usage: list | file.mp3 | status X | kind X | title X | route X | notice X', 'error') end
end)
