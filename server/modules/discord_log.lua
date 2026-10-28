-- ─── Nova Convoy — Discord Webhook Logs ────────────────────────────────────────
-- Mirrors convoy and airdrop activity to a Discord channel via incoming webhook.
-- Activity during one run lives in a single Discord message that updates in-place.
-- Upon completion, an After-Action Report PDF is attached to the final message.

DiscordLog = {}

local function enabled()
    local cfg = Config.DiscordLogs
    return cfg and cfg.enabled and cfg.webhookUrl and cfg.webhookUrl ~= ''
end

local function getBranding()
    return Config.Branding or {}
end

local function getBotName()
    local b = getBranding()
    local cfg = Config.DiscordLogs or {}
    return cfg.botName or b.discordBotName or b.operationName or 'Nova Convoy'
end

-- Server logo (Config.Branding.logoUrl). Empty/nil = no logo anywhere.
local function getLogoUrl()
    local cfg = Config.DiscordLogs or {}
    local url = cfg.avatarUrl or getBranding().logoUrl
    if type(url) ~= 'string' or url == '' then return nil end
    return url
end

local function getFooter()
    local logo = getLogoUrl()
    return { text = (getBranding().discordFooter or getBranding().operationName or 'Nova Convoy'), icon_url = logo }
end

local function getFooterText()
    local b = getBranding()
    return b.discordFooter or b.operationName or 'Nova Convoy'
end

-- kind (optional): names the attached PDF after the actual event kind
-- (hot_cargo_report_12.pdf, airdrop_report_12.pdf, gang_rally_report_12.pdf)
-- instead of always the server's branding name. Every report's own title
-- page already says "HOT CARGO OPERATION REPORT" / "GANG RALLY RACE REPORT"
-- etc. at the top (see buildConvoyReportData) — the Discord attachment
-- filename saying "..._convoy_report_..." for a Hot Cargo or Airdrop run
-- regardless read as a bug (wrong file for what's actually inside), not
-- branding. kind-less callers (Convoy, or anywhere old) keep the original
-- operationName-based name.
local KIND_FILE_SLUGS = { HOT_CARGO = 'hot_cargo', GANG_AIRDROP = 'airdrop', GANG_RACE = 'gang_rally', TDM = 'tdm_match', CONTAINER_WARS = 'container_wars', GANG_TERRITORY = 'territory_auction', CRACKDOWN = 'operation_crackdown' }
local function getReportFileName(convoyId, kind)
    local slug = KIND_FILE_SLUGS[kind]
    if not slug then
        local b = getBranding()
        slug = (b.operationName or 'convoy'):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    end
    return ('%s_report_%s.pdf'):format(slug, convoyId or 'final')
end

-- convoyId -> { title, color, description, fields, timeline, messageId }
local events = {}

local TIMELINE_CHAR_LIMIT = 1000

local function buildEmbed(entry)
    local fields = {}
    for _, f in ipairs(entry.fields or {}) do
        if #fields < 24 and f.name then
            local name = tostring(f.name):sub(1, 256)
            local rawVal = tostring(f.value or '')
            -- Clean out any residual ambush zones text from route details or custom fields
            rawVal = rawVal:gsub(',?%s*%d+%s*[Aa]mbush%s*zones?,?', '')
            rawVal = rawVal:gsub('%(%s*,', '('):gsub(',%s*%)', ')')
            if rawVal:match('^%s*$') then rawVal = 'None' end
            local value = #rawVal > 1020 and (rawVal:sub(1, 1017) .. '...') or rawVal
            fields[#fields + 1] = {
                name = name,
                value = value,
                inline = f.inline == true,
            }
        end
    end
    if entry.timeline and #entry.timeline > 0 then
        local filteredTimeline = {}
        for _, l in ipairs(entry.timeline) do
            local s = tostring(l)
            if not s:lower():find('ambush') then
                filteredTimeline[#filteredTimeline + 1] = s
            end
        end
        local text = table.concat(filteredTimeline, '\n')
        while #text > TIMELINE_CHAR_LIMIT and #filteredTimeline > 1 do
            table.remove(filteredTimeline, 1)
            text = table.concat(filteredTimeline, '\n')
        end
        if #filteredTimeline > 0 then
            fields[#fields + 1] = { name = '📜 Operation Timeline', value = text, inline = false }
        end
    end
    return {
        title = entry.title,
        description = entry.description,
        color = entry.color or 0x3b82f6,
        fields = fields,
        footer = getFooter(), thumbnail = getLogoUrl() and { url = getLogoUrl() } or nil,
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
end

local function buildMultipartBody(boundary, payloadJson, fileBytes, fileName)
    local parts = {
        '--' .. boundary .. '\r\n',
        'Content-Disposition: form-data; name="payload_json"\r\n',
        'Content-Type: application/json\r\n\r\n',
        payloadJson .. '\r\n',
        '--' .. boundary .. '\r\n',
        ('Content-Disposition: form-data; name="files[0]"; filename="%s"\r\n'):format(fileName or 'report.pdf'),
        'Content-Type: application/pdf\r\n\r\n',
        fileBytes .. '\r\n',
        '--' .. boundary .. '--\r\n',
    }
    return table.concat(parts)
end

function DiscordLog.send(title, description, color, fields, pdfString, fileName)
    if TestRun and TestRun.admin then return end   -- a test run posts nothing
    if not enabled() then return end
    local cfg = Config.DiscordLogs
    local actualFileName = fileName or getReportFileName()
    if pdfString and #pdfString > 0 then
        local boundary = '----WebKitFormBoundary' .. tostring(os.time()) .. tostring(math.random(10000, 99999))
        local payload = json.encode({
            username = getBotName(),
            avatar_url = getLogoUrl(),
            embeds = { { title = title, description = description, color = color or 0x3b82f6, fields = fields or {},
                footer = getFooter(), thumbnail = getLogoUrl() and { url = getLogoUrl() } or nil, timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ') } },
        })
        local body = buildMultipartBody(boundary, payload, pdfString, actualFileName)
        PerformHttpRequest(cfg.webhookUrl, function(statusCode)
            if statusCode ~= 200 and statusCode ~= 204 then
                lib.print.warn(('[NovaConvoy] Discord webhook returned status %s.'):format(tostring(statusCode)))
            end
        end, 'POST', body, { ['Content-Type'] = 'multipart/form-data; boundary=' .. boundary })
    else
        local payload = json.encode({
            username = getBotName(),
            avatar_url = getLogoUrl(),
            embeds = { { title = title, description = description, color = color or 0x3b82f6, fields = fields or {},
                footer = getFooter(), thumbnail = getLogoUrl() and { url = getLogoUrl() } or nil, timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ') } },
        })
        PerformHttpRequest(cfg.webhookUrl, function(statusCode)
            if statusCode ~= 200 and statusCode ~= 204 then
                lib.print.warn(('[NovaConvoy] Discord webhook returned status %s.'):format(tostring(statusCode)))
            end
        end, 'POST', payload, { ['Content-Type'] = 'application/json' })
    end
end

local function patchEvent(convoyId, pdfString, fileName)
    local entry = events[convoyId]
    if not entry or not entry.messageId then return end
    local cfg = Config.DiscordLogs
    local actualFileName = fileName or getReportFileName(convoyId)
    if pdfString and #pdfString > 0 then
        local boundary = '----WebKitFormBoundary' .. tostring(os.time()) .. tostring(math.random(10000, 99999))
        local payload = json.encode({
            embeds = { buildEmbed(entry) },
            attachments = {},
        })
        local body = buildMultipartBody(boundary, payload, pdfString, actualFileName)
        PerformHttpRequest(('%s/messages/%s'):format(cfg.webhookUrl, entry.messageId), function(statusCode)
            if statusCode ~= 200 and statusCode ~= 204 then
                lib.print.warn(('[NovaConvoy] Discord webhook edit returned status %s.'):format(tostring(statusCode)))
            end
        end, 'PATCH', body, { ['Content-Type'] = 'multipart/form-data; boundary=' .. boundary })
    else
        local payload = json.encode({ embeds = { buildEmbed(entry) } })
        PerformHttpRequest(('%s/messages/%s'):format(cfg.webhookUrl, entry.messageId), function(statusCode)
            if statusCode ~= 200 and statusCode ~= 204 then
                lib.print.warn(('[NovaConvoy] Discord webhook edit returned status %s.'):format(tostring(statusCode)))
            end
        end, 'PATCH', payload, { ['Content-Type'] = 'application/json' })
    end
end

function DiscordLog.startEvent(convoyId, title, color, description, fields)
    if TestRun and TestRun.admin then return end   -- no Discord message, no timeline: a test run leaves no report
    -- a new run: forget the payouts of the previous run of this event (the report reads them back at the end)
    if RewardService and RewardService.ClearPayouts then RewardService.ClearPayouts(convoyId) end
    local cfg = Config.DiscordLogs
    local entry = { title = title, color = color, description = description, fields = fields or {}, timeline = {} }
    -- the timeline is kept even with Discord off: the PDF and Event History report are built from it
    events[convoyId] = entry
    if not enabled() then return end
    local payload = json.encode({
        username = getBotName(),
        avatar_url = getLogoUrl(),
        embeds = { buildEmbed(entry) },
    })
    PerformHttpRequest(cfg.webhookUrl .. '?wait=true', function(statusCode, response)
        if statusCode ~= 200 then
            lib.print.warn(('[NovaConvoy] Discord webhook returned status %s while starting an event log.'):format(tostring(statusCode)))
            return
        end
        local ok, decoded = pcall(json.decode, response)
        if ok and decoded and decoded.id and events[convoyId] then
            events[convoyId].messageId = decoded.id
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

function DiscordLog.appendEvent(convoyId, line)
    if TestRun and TestRun.admin then return end
    if tostring(line):lower():find('ambush') then return end
    local entry = events[convoyId]
    if not entry then return end
    entry.timeline[#entry.timeline + 1] = line
    if enabled() then patchEvent(convoyId) end
end

function DiscordLog.getTimeline(convoyId)
    local entry = events[convoyId]
    if not entry or not entry.timeline then return {} end
    local list = {}
    for _, l in ipairs(entry.timeline) do
        local s = tostring(l)
        if not s:lower():find('ambush') then
            list[#list + 1] = s
        end
    end
    return list
end

function DiscordLog.finishEvent(convoyId, title, color, fields, finalLine, pdfString, kind)
    if TestRun and TestRun.admin then events[convoyId] = nil return end
    if not enabled() then events[convoyId] = nil return end
    local entry = events[convoyId]
    local fileName = getReportFileName(convoyId, kind)
    if not entry then
        DiscordLog.send(title, nil, color, fields, pdfString, fileName)
        return
    end
    entry.title = title or entry.title
    entry.color = color or entry.color
    entry.fields = fields or entry.fields
    if finalLine then entry.timeline[#entry.timeline + 1] = finalLine end

    CreateThread(function()
        local attempts = 0
        while not entry.messageId and attempts < 5 do
            Wait(400)
            attempts = attempts + 1
        end
        if entry.messageId then
            patchEvent(convoyId, pdfString, fileName)
        else
            DiscordLog.send(entry.title, entry.description, entry.color, buildEmbed(entry).fields, pdfString, fileName)
        end
        events[convoyId] = nil
    end)
end

function DiscordLog.postEventGriefingAlert(title, description, fields)
    if TestRun and TestRun.admin then return end
    if not enabled() then return end
    DiscordLog.send(title or '🚨 [POST-EVENT SENTRY AUDIT — SUSPECTED GRIEFING]', description, 0xef4444, fields)
end

return DiscordLog
