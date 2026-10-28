-- ─── Nova Convoy — PDF After-Action Report Generator ─────────────────────────
-- Pure Lua PDF-1.4 generator creating professional tactical audit reports
-- attached directly to Discord webhook finish events and downloadable via tablet.

PdfGenerator = {}

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function PdfGenerator.base64Encode(data)
    if not data then return '' end
    local len = #data
    local t = {}
    for i = 1, len, 3 do
        local b1 = data:byte(i)
        local b2 = i + 1 <= len and data:byte(i + 1) or 0
        local b3 = i + 2 <= len and data:byte(i + 2) or 0
        local n = (b1 * 65536) + (b2 * 256) + b3
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        t[#t + 1] = b64chars:sub(c1 + 1, c1 + 1) .. b64chars:sub(c2 + 1, c2 + 1)
        if i + 1 <= len then
            t[#t + 1] = b64chars:sub(c3 + 1, c3 + 1)
        else
            t[#t + 1] = '='
        end
        if i + 2 <= len then
            t[#t + 1] = b64chars:sub(c4 + 1, c4 + 1)
        else
            t[#t + 1] = '='
        end
    end
    return table.concat(t)
end

local function escapePdf(str)
    if not str then return '' end
    local s = tostring(str)
    -- Normalize special UTF-8 dashes and symbols into standard printable ASCII for Type 1 fonts
    s = s:gsub('—', '--'):gsub('–', '-'):gsub('•', '*'):gsub('🎒', '[Loot]'):gsub('💥', '[Destroyed]')
         :gsub('⚠️', '[Warn]'):gsub('🏴', '[Captured]'):gsub('📦', '[Crate]'):gsub('✅', '[OK]')
         :gsub('🛡️', '[Police]'):gsub('📜', '[Log]'):gsub('📄', '[Report]'):gsub('⚔️', '[PvP]')
         :gsub('🚨', '[ALERT]'):gsub('🚀', '[Start]'):gsub('🪂', '[Airdrop]')
    -- Strip any residual ambush text
    s = s:gsub(',?%s*%d+%s*[Aa]mbush%s*zones?,?', '')
    s = s:gsub('%(%s*,', '('):gsub(',%s*%)', ')')
    -- Escape PDF syntax delimiters
    s = s:gsub('\\', '\\\\'):gsub('%(', '\\('):gsub('%)', '\\)')
    -- Strip control characters
    s = s:gsub('[\r\n\t]', ' ')
    -- Strip non-ASCII characters
    s = s:gsub('[^\32-\126]', ' ')
    return s
end

-- ── Logo (Config.Branding.pdfLogoUrl, JPEG only) ─────────────────────────────────
-- Downloaded once at start-up and cached; a bad/missing/non-JPEG link just means
-- no logo in the PDF.
local logo = nil

local function parseJpeg(bytes)
    if #bytes < 4 or bytes:byte(1) ~= 0xFF or bytes:byte(2) ~= 0xD8 then return nil end
    local i = 3
    while i < #bytes - 8 do
        if bytes:byte(i) ~= 0xFF then
            i = i + 1
        else
            local m = bytes:byte(i + 1)
            if m == 0xFF then
                i = i + 1
            elseif m == 0xC0 or m == 0xC1 or m == 0xC2 then
                local h = bytes:byte(i + 5) * 256 + bytes:byte(i + 6)
                local w = bytes:byte(i + 7) * 256 + bytes:byte(i + 8)
                local comps = bytes:byte(i + 9)
                if (comps == 1 or comps == 3) and w > 0 and h > 0 then return { w = w, h = h, comps = comps } end
                return nil
            else
                i = i + 2 + (bytes:byte(i + 2) * 256 + bytes:byte(i + 3))
            end
        end
    end
    return nil
end

function PdfGenerator.loadLogo()
    local url = Config.Branding and Config.Branding.pdfLogoUrl
    if type(url) ~= 'string' or url == '' then return end
    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or type(body) ~= 'string' then
            lib.print.warn(('[NovaConvoy] PDF logo download failed (HTTP %s).'):format(tostring(status)))
            return
        end
        local info = parseJpeg(body)
        if not info then
            lib.print.warn('[NovaConvoy] Config.Branding.pdfLogoUrl must be a JPEG (RGB or grayscale) — PDF logo skipped.')
            return
        end
        info.data = body
        logo = info
    end, 'GET')
end

CreateThread(function()
    Wait(2000)
    PdfGenerator.loadLogo()
end)

function PdfGenerator.generateConvoyReport(data)
    local ok, result = pcall(function()
        local width = 595.28
        local height = 841.89
        local stream = {}

        local function rect(x, y, w, h, fillR, fillG, fillB, strokeR, strokeG, strokeB, lineWidth)
            if fillR then
                stream[#stream + 1] = ('%.2f %.2f %.2f rg'):format(fillR, fillG, fillB)
                stream[#stream + 1] = ('%.2f %.2f %.2f %.2f re f'):format(x, y, w, h)
            end
            if strokeR then
                stream[#stream + 1] = ('%.2f %.2f %.2f RG'):format(strokeR, strokeG, strokeB)
                stream[#stream + 1] = ('%.2f w'):format(lineWidth or 1)
                stream[#stream + 1] = ('%.2f %.2f %.2f %.2f re S'):format(x, y, w, h)
            end
        end

        local function line(x1, y1, x2, y2, strokeR, strokeG, strokeB, lineWidth)
            stream[#stream + 1] = ('%.2f %.2f %.2f RG'):format(strokeR or 0, strokeG or 0, strokeB or 0)
            stream[#stream + 1] = ('%.2f w'):format(lineWidth or 1)
            stream[#stream + 1] = ('%.2f %.2f m %.2f %.2f l S'):format(x1, y1, x2, y2)
        end

        local function text(font, size, x, y, str, r, g, b)
            stream[#stream + 1] = 'BT'
            stream[#stream + 1] = ('/%s %.2f Tf'):format(font, size)
            stream[#stream + 1] = ('%.2f %.2f %.2f rg'):format(r or 0, g or 0, b or 0)
            stream[#stream + 1] = ('%.2f %.2f Td'):format(x, y)
            stream[#stream + 1] = ('(%s) Tj'):format(escapePdf(str))
            stream[#stream + 1] = 'ET'
        end

        -- Page background: crisp clinical light slate
        rect(0, 0, width, height, 0.96, 0.97, 0.98)

        local branding = data.branding or (Config.Branding or {})
        local opName = branding.operationName or 'Nova Convoy'
        local docTitle = branding.pdfTitle or ('%s -- AFTER-ACTION REPORT'):format(opName:upper())
        if docTitle:find('%%s') then docTitle = docTitle:format(opName:upper()) end
        if data.kind == 'GANG_AIRDROP' then
            docTitle = ('%s -- GANG AIRDROP OPERATION REPORT'):format(opName:upper())
        elseif data.kind == 'HOT_CARGO' then
            docTitle = ('%s -- HOT CARGO OPERATION REPORT'):format(opName:upper())
        elseif data.kind == 'GANG_RACE' then
            docTitle = ('%s -- GANG RALLY / STREET RACE REPORT'):format(opName:upper())
        end
        -- Kinds that ship their own wording (TDM, Container Wars — see
        -- report_builder.lua) carry a `labels` table; everything below falls
        -- back to the Convoy / Airdrop / Hot Cargo / Rally text when absent.
        local L = data.labels or {}
        if L.docTitle then docTitle = ('%s -- %s'):format(opName:upper(), L.docTitle) end
        local docFooter = branding.pdfFooter or ('%s SYSTEM  |  CONFIDENTIAL AUTOMATED AUDIT & AFTER-ACTION REPORT'):format(opName:upper())
        if docFooter:find('%%s') then docFooter = docFooter:format(opName:upper()) end

        -- ── TOP HEADER BANNER (Tactical Command Dark Navy) ──
        rect(0, height - 74, width, 74, 0.07, 0.11, 0.20)
        -- Dynamic Accent Stripe
        local stripeR, stripeG, stripeB = 0.23, 0.51, 0.96
        if data.kind == 'GANG_AIRDROP' then
            stripeR, stripeG, stripeB = 0.54, 0.36, 0.96
        elseif data.kind == 'HOT_CARGO' then
            stripeR, stripeG, stripeB = 0.97, 0.45, 0.08
        elseif data.kind == 'GANG_RACE' then
            stripeR, stripeG, stripeB = 0.83, 0.63, 0.05
        end
        if data.outcome == 'CAPTURED' or data.outcome == 'FAILED' then
            stripeR, stripeG, stripeB = 0.89, 0.22, 0.22
        elseif data.outcome == 'COMPLETED' then
            if data.kind == 'GANG_AIRDROP' then
                stripeR, stripeG, stripeB = 0.54, 0.36, 0.96
            elseif data.kind == 'HOT_CARGO' then
                stripeR, stripeG, stripeB = 0.97, 0.45, 0.08
            elseif data.kind == 'GANG_RACE' then
                stripeR, stripeG, stripeB = 0.83, 0.63, 0.05
            else
                stripeR, stripeG, stripeB = 0.13, 0.65, 0.38
            end
        end
        if L.stripe then stripeR, stripeG, stripeB = L.stripe[1], L.stripe[2], L.stripe[3] end
        rect(0, height - 78, width, 4, stripeR, stripeG, stripeB)

        -- Title & Classification (13pt prevents overlap with right metadata)
        text('F2', 13, 36, height - 34, docTitle:upper():sub(1, 48), 1, 1, 1)
        local classLabel = data.kind == 'GANG_AIRDROP' and 'AIRDROP TACTICAL AUDIT' or (data.kind == 'HOT_CARGO' and 'HOT CARGO RUN AUDIT' or (data.kind == 'GANG_RACE' and 'GANG RALLY RACE AUDIT' or 'TACTICAL AFTER-ACTION AUDIT'))
        if L.classLabel then classLabel = L.classLabel end
        text('F1', 7.5, 36, height - 50, ('OPERATION: %s  |  REF ID: #%s  |  CLASS: %s'):format(
            tostring(data.name or 'CONVOY'):upper():sub(1, 30),
            tostring(data.id or '1'),
            classLabel
        ), 0.65, 0.75, 0.90)

        -- Header Right-Hand Metadata (safely placed at X=420)
        local startStr = tostring(data.startTimeStr or os.date('!%d %b %Y %H:%M UTC', data.startedAt or os.time())):gsub(':00 UTC', ' UTC')
        local endStr = tostring(data.endTimeStr or os.date('!%d %b %Y %H:%M UTC', data.endedAt or os.time())):gsub(':00 UTC', ' UTC')
        local metaX = logo and 396 or 420
        text('F2', 7, metaX, height - 32, 'STARTED:', 0.65, 0.75, 0.90)
        text('F1', 7, metaX + 42, height - 32, startStr:sub(1, 24), 1, 1, 1)
        text('F2', 7, metaX, height - 46, 'ENDED:', 0.65, 0.75, 0.90)
        text('F1', 7, metaX + 42, height - 46, endStr:sub(1, 24), 1, 1, 1)
        -- Server logo, top-right of the header (fitted into a 42x42 box).
        if logo then
            local box = 42
            local sc = math.min(box / logo.w, box / logo.h)
            local lw, lh = logo.w * sc, logo.h * sc
            stream[#stream + 1] = 'q'
            stream[#stream + 1] = ('%.2f 0 0 %.2f %.2f %.2f cm'):format(lw, lh, width - 36 - box + (box - lw) / 2, height - 58 + (box - lh) / 2)
            stream[#stream + 1] = '/Im1 Do'
            stream[#stream + 1] = 'Q'
        end

        -- ── METRIC CARDS (ROW OF 4) ──
        local cardY = height - 148
        local cardW = 127
        local cardH = 58
        local cardGap = 11
        local leftM = 36

        -- Card 1: Operation Outcome
        local c1X = leftM
        rect(c1X, cardY, cardW, cardH, 1, 1, 1, 0.85, 0.88, 0.92, 1)
        text('F2', 7, c1X + 10, cardY + 44, 'OPERATION OUTCOME', 0.45, 0.50, 0.58)

        local badgeR, badgeG, badgeB = 0.13, 0.65, 0.38
        local outcomeLabel = data.kind == 'GANG_AIRDROP' and 'CONCLUDED' or (data.kind == 'GANG_RACE' and 'FINISHED' or 'DELIVERED')
        if data.outcome == 'CAPTURED' then
            badgeR, badgeG, badgeB = 0.89, 0.22, 0.22
            outcomeLabel = data.kind == 'GANG_AIRDROP' and 'LOOTED' or 'CAPTURED'
        elseif data.outcome == 'FAILED' then
            badgeR, badgeG, badgeB = 0.85, 0.35, 0.15
            outcomeLabel = data.kind == 'GANG_AIRDROP' and 'EXPIRED' or (data.kind == 'HOT_CARGO' and 'UNDELIVERED' or (data.kind == 'GANG_RACE' and 'NO FINISHERS' or 'FAILED'))
        elseif data.outcome == 'CANCELLED' then
            badgeR, badgeG, badgeB = 0.45, 0.50, 0.58
            outcomeLabel = 'CANCELLED'
        elseif data.outcome == 'COMPLETED' then
            if data.kind == 'GANG_AIRDROP' then
                badgeR, badgeG, badgeB = 0.54, 0.36, 0.96
                outcomeLabel = 'COMPLETED'
            elseif data.kind == 'HOT_CARGO' then
                badgeR, badgeG, badgeB = 0.97, 0.45, 0.08
                outcomeLabel = 'DELIVERED'
            elseif data.kind == 'GANG_RACE' then
                badgeR, badgeG, badgeB = 0.83, 0.63, 0.05
                outcomeLabel = 'RACE WON'
            end
        end
        if L.outcomeLabel then
            outcomeLabel = L.outcomeLabel
            if L.badge then badgeR, badgeG, badgeB = L.badge[1], L.badge[2], L.badge[3] end
        end
        rect(c1X + 10, cardY + 12, cardW - 20, 22, badgeR, badgeG, badgeB)
        text('F2', 8.5, c1X + 16, cardY + 19, outcomeLabel:sub(1, 18), 1, 1, 1)

        -- Card 2: Primary Winner
        local c2X = c1X + cardW + cardGap
        rect(c2X, cardY, cardW, cardH, 1, 1, 1, 0.85, 0.88, 0.92, 1)
        text('F2', 7, c2X + 10, cardY + 44, L.winnerTitle or ((data.kind == 'GANG_AIRDROP' or data.kind == 'HOT_CARGO') and 'TOP GANG / VICTOR' or (data.kind == 'GANG_RACE' and 'RACE WINNER' or 'VICTOR / SECURED BY')), 0.45, 0.50, 0.58)
        local winStr = tostring(data.winner or 'None'):gsub('🛡️', ''):gsub('🏴', ''):gsub('🏆', ''):gsub('^%s*', '')
        text('F2', 8.5, c2X + 10, cardY + 26, winStr:sub(1, 21), 0.12, 0.18, 0.28)
        local subWin = data.winningGang and ('Gang: %s'):format(data.winningGang:sub(1, 18))
            or ((data.kind == 'GANG_AIRDROP' or data.kind == 'HOT_CARGO') and 'Open Gang Event')
            or (data.kind == 'GANG_RACE' and (data.outcome == 'COMPLETED' and 'Independent Racer' or 'No Finisher Recorded'))
            or (data.outcome == 'COMPLETED' and 'Law Enforcement' or 'No Faction Payout')
        if L.winnerSub then subWin = L.winnerSub end
        text('F1', 7, c2X + 10, cardY + 12, tostring(subWin):sub(1, 30), 0.45, 0.50, 0.58)

        -- Card 3: Timing & Units
        local c3X = c2X + cardW + cardGap
        rect(c3X, cardY, cardW, cardH, 1, 1, 1, 0.85, 0.88, 0.92, 1)
        text('F2', 7, c3X + 10, cardY + 44, L.forcesTitle or 'DURATION & FORCES', 0.45, 0.50, 0.58)
        text('F2', 8.5, c3X + 10, cardY + 26, ('Duration: %s'):format(data.durationText or '0m 00s'), 0.12, 0.18, 0.28)
        if L.forces then
            text('F1', 7, c3X + 10, cardY + 12, tostring(L.forces):sub(1, 30), 0.45, 0.50, 0.58)
        elseif data.kind == 'GANG_AIRDROP' then
            text('F1', 7, c3X + 10, cardY + 12, ('Gangs: %d  |  Looters: %d'):format(
                data.roster and data.roster.gangCount or 0,
                data.roster and data.roster.gangCount or 0
            ), 0.45, 0.50, 0.58)
        else
            text('F1', 7, c3X + 10, cardY + 12, ('Police: %d  |  Gangs: %d'):format(
                data.roster and data.roster.policeCount or 0,
                data.roster and data.roster.gangCount or 0
            ), 0.45, 0.50, 0.58)
        end

        -- Card 4: Fleet / Cargo
        local c4X = c3X + cardW + cardGap
        rect(c4X, cardY, cardW, cardH, 1, 1, 1, 0.85, 0.88, 0.92, 1)
        if L.card4 then
            text('F2', 7, c4X + 10, cardY + 44, tostring(L.card4.title or ''), 0.45, 0.50, 0.58)
            text('F2', 8.5, c4X + 10, cardY + 26, tostring(L.card4.main or ''):sub(1, 22), 0.12, 0.18, 0.28)
            text('F1', 7, c4X + 10, cardY + 12, tostring(L.card4.sub or ''):sub(1, 30), 0.45, 0.50, 0.58)
        elseif data.kind == 'GANG_AIRDROP' then
            text('F2', 7, c4X + 10, cardY + 44, 'SUPPLY DROPS & CRATES', 0.45, 0.50, 0.58)
            text('F2', 8.5, c4X + 10, cardY + 26, ('Drops: %d Claimed'):format(data.fleet and data.fleet.captured or 0), 0.12, 0.18, 0.28)
            text('F1', 7, c4X + 10, cardY + 12, ('Total Zones: %d'):format(data.fleet and data.fleet.total or 0), 0.45, 0.50, 0.58)
        elseif data.kind == 'HOT_CARGO' then
            text('F2', 7, c4X + 10, cardY + 44, 'CONTRABAND VEHICLES', 0.45, 0.50, 0.58)
            text('F2', 8.5, c4X + 10, cardY + 26, ('Delivered: %d  Disabled: %d'):format(data.fleet and data.fleet.delivered or 0, data.fleet and data.fleet.disabled or 0), 0.12, 0.18, 0.28)
            text('F1', 7, c4X + 10, cardY + 12, ('Spawned: %d  Hijacked: %d'):format(data.fleet and data.fleet.total or 0, data.fleet and data.fleet.hijacked or 0), 0.45, 0.50, 0.58)
        elseif data.kind == 'GANG_RACE' then
            -- No lap/checkpoint telemetry is tracked per-gang for a race
            -- (unlike trucks/drops, there's nothing in the runtime to count
            -- here) — the reward pool is real, accurate data, so that's
            -- what this card shows instead of a fabricated fleet stat.
            text('F2', 7, c4X + 10, cardY + 44, 'REWARD POOL', 0.45, 0.50, 0.58)
            text('F2', 8.5, c4X + 10, cardY + 26, tostring(data.rewards or 'None'):sub(1, 22), 0.12, 0.18, 0.28)
            text('F1', 7, c4X + 10, cardY + 12, ('Racers: %d'):format(data.roster and data.roster.gangCount or 0), 0.45, 0.50, 0.58)
        else
            text('F2', 7, c4X + 10, cardY + 44, 'FLEET & CARGO', 0.45, 0.50, 0.58)
            text('F2', 8.5, c4X + 10, cardY + 26, ('Del:%d  Cap:%d  Loss:%d'):format(
                data.fleet and data.fleet.delivered or 0,
                data.fleet and data.fleet.captured or 0,
                data.fleet and data.fleet.destroyed or 0
            ), 0.12, 0.18, 0.28)
            text('F1', 7, c4X + 10, cardY + 12, tostring(data.cargoDescription or 'Cargo'):sub(1, 22), 0.45, 0.50, 0.58)
        end

        -- ── SECTION 1: INTERCEPTIONS & CARGO AUDIT (TABLE) ──
        local interceptions = data.interceptions or {}
        local maxInterceptRows = math.min(#interceptions, 8)
        local totalW = width - 72
        -- Height: header bar (18) + column header (16) + rows (16 each) + padding (14)
        local sec1H = 18 + 16 + math.max(maxInterceptRows, 1) * 16 + 14
        local sec1Y = cardY - sec1H - 10
        rect(36, sec1Y, totalW, sec1H, 1, 1, 1, 0.85, 0.88, 0.92, 1)

        local sec1Title = L.sec1Title or (data.kind == 'GANG_AIRDROP' and 'AIRDROP DROPS & CRATE CLAIMS AUDIT' or (data.kind == 'HOT_CARGO' and 'HOT CARGO PURSUIT & REWARD AUDIT' or (data.kind == 'GANG_RACE' and 'RACE INCIDENT & PURSUIT LOG' or 'INTERCEPTIONS & CARGO AUDIT')))
        text('F2', 9.5, 46, sec1Y + sec1H - 18, sec1Title, 0.12, 0.18, 0.28)
        line(46, sec1Y + sec1H - 22, 220, sec1Y + sec1H - 22, 0.23, 0.51, 0.96, 1.5)

        -- Table Header Row
        local thY = sec1Y + sec1H - 40
        rect(36, thY, totalW, 16, 0.92, 0.94, 0.97)
        text('F2', 7, 44, thY + 5, 'TIME', 0.35, 0.40, 0.50)
        text('F2', 7, 88, thY + 5, data.kind == 'GANG_AIRDROP' and 'DROP ZONE' or (data.kind == 'HOT_CARGO' and 'TARGET / ZONE' or 'TARGET'), 0.35, 0.40, 0.50)
        text('F2', 7, 185, thY + 5, data.kind == 'GANG_AIRDROP' and 'ACCESS METHOD' or (data.kind == 'HOT_CARGO' and 'STATUS / ACTION' or 'BREACH METHOD'), 0.35, 0.40, 0.50)
        text('F2', 7, 275, thY + 5, data.kind == 'GANG_AIRDROP' and 'CLAIMING GANG & ACTOR' or (data.kind == 'HOT_CARGO' and 'OPERATIVE & GANG' or 'ACTOR & FACTION'), 0.35, 0.40, 0.50)
        text('F2', 7, 415, thY + 5, data.kind == 'GANG_AIRDROP' and 'CRATE LOOT SECURED' or (data.kind == 'HOT_CARGO' and 'DETAIL / REWARDS' or 'EVIDENCE / LOOT EXTRACTED'), 0.35, 0.40, 0.50)

        if L.sec1Cols then
            rect(36, thY, totalW, 16, 0.92, 0.94, 0.97)
            local xs = { 44, 88, 185, 275, 415 }
            for ci = 1, 5 do
                text('F2', 7, xs[ci], thY + 5, tostring(L.sec1Cols[ci] or ''), 0.35, 0.40, 0.50)
            end
        end
        local rowY = thY - 16
        if #interceptions > 0 then
            for i = 1, maxInterceptRows do
                local item = interceptions[i]
                -- Zebra or Alert highlight
                if item.isAlert or item.isPolice then
                    rect(36, rowY, totalW, 16, 1.0, 0.94, 0.94)
                elseif i % 2 == 0 then
                    rect(36, rowY, totalW, 16, 0.98, 0.99, 1.0)
                end

                text('F3', 6.8, 44, rowY + 5, tostring(item.time or '00:00'):sub(1, 8), 0.30, 0.35, 0.45)
                text('F2', 7, 88, rowY + 5, tostring(item.target or 'Target'):sub(1, 18), 0.15, 0.20, 0.30)
                
                local methColor = item.method == 'Electronic Hack' and { 0.15, 0.45, 0.65 } or { 0.35, 0.40, 0.50 }
                text('F1', 7, 185, rowY + 5, tostring(item.method or 'Access'):sub(1, 17), methColor[1], methColor[2], methColor[3])

                local actorStr = tostring(item.actorName or 'Unknown')
                if item.faction and item.faction ~= '' then
                    actorStr = actorStr .. ' [' .. tostring(item.faction) .. ']'
                end
                local actorR, actorG, actorB = 0.20, 0.25, 0.35
                if item.isPolice then
                    actorR, actorG, actorB = 0.85, 0.15, 0.15
                    actorStr = '[POLICE] ' .. actorStr
                end
                text('F1', 7, 275, rowY + 5, actorStr:sub(1, 26), actorR, actorG, actorB)

                local lootR, lootG, lootB = 0.15, 0.55, 0.25
                if item.isAlert then
                    lootR, lootG, lootB = 0.80, 0.20, 0.15
                end
                text('F1', 6.8, 415, rowY + 5, tostring(item.evidence or 'None'):sub(1, 28), lootR, lootG, lootB)

                rowY = rowY - 16
            end
            if #interceptions > maxInterceptRows then
                text('F1', 6.5, 46, rowY + 5, ('... and %d more -- continued on the following pages.'):format(#interceptions - maxInterceptRows), 0.50, 0.55, 0.65)
            end
        else
            local emptyMsg = L.sec1Empty or data.kind == 'GANG_AIRDROP'
                and '* No supply drop crates were successfully cracked or looted during this airdrop operation.'
                or (data.kind == 'HOT_CARGO'
                    and '* No contraband vehicles were successfully delivered during this Hot Cargo run.'
                    or (data.kind == 'GANG_RACE'
                        and '* No pursuit or incident events were logged during this race.'
                        or '* No individual vehicle or cargo breaches registered during this operation.'))
            text('F1', 7.5, 46, rowY + 5, emptyMsg, 0.50, 0.55, 0.65)
        end

        -- ── SECTION 2: FACTION ENGAGEMENT & SCORECARD (TABLE) ──
        local sec2Y = sec1Y - 110
        local sec2H = 100
        rect(36, sec2Y, totalW, sec2H, 1, 1, 1, 0.85, 0.88, 0.92, 1)

        text('F2', 9.5, 46, sec2Y + sec2H - 18, L.sec2Title or 'FACTION ENGAGEMENT & SCORECARD', 0.12, 0.18, 0.28)
        line(46, sec2Y + sec2H - 22, 195, sec2Y + sec2H - 22, 0.23, 0.51, 0.96, 1.5)

        local sthY = sec2Y + sec2H - 38
        rect(36, sthY, totalW, 15, 0.92, 0.94, 0.97)
        if L.sec2Cols then
            text('F2', 7, 44, sthY + 4.5, 'FACTION / GANG', 0.35, 0.40, 0.50)
            local xs2 = { 175, 250, 340, 440 }
            for ci = 1, 4 do
                text('F2', 7, xs2[ci], sthY + 4.5, tostring(L.sec2Cols[ci] or ''), 0.35, 0.40, 0.50)
            end
        elseif data.kind == 'GANG_AIRDROP' then
            text('F2', 7, 44, sthY + 4.5, 'FACTION / GANG', 0.35, 0.40, 0.50)
            text('F2', 7, 175, sthY + 4.5, 'OPERATIVES', 0.35, 0.40, 0.50)
            text('F2', 7, 240, sthY + 4.5, 'DROPS SECURED', 0.35, 0.40, 0.50)
            text('F2', 7, 340, sthY + 4.5, 'REWARDS & LOOT SUMMARY', 0.35, 0.40, 0.50)
        elseif data.kind == 'HOT_CARGO' then
            text('F2', 7, 44, sthY + 4.5, 'FACTION / GANG', 0.35, 0.40, 0.50)
            text('F2', 7, 175, sthY + 4.5, 'OPERATIVES', 0.35, 0.40, 0.50)
            text('F2', 7, 240, sthY + 4.5, 'CARGO DELIVERED', 0.35, 0.40, 0.50)
            text('F2', 7, 340, sthY + 4.5, 'REWARDS & LOOT SUMMARY', 0.35, 0.40, 0.50)
        elseif data.kind == 'GANG_RACE' then
            text('F2', 7, 44, sthY + 4.5, 'FACTION / GANG', 0.35, 0.40, 0.50)
            text('F2', 7, 175, sthY + 4.5, 'RACERS ENTERED', 0.35, 0.40, 0.50)
            text('F2', 7, 280, sthY + 4.5, 'RESULT', 0.35, 0.40, 0.50)
            text('F2', 7, 340, sthY + 4.5, 'NOTES', 0.35, 0.40, 0.50)
        else
            text('F2', 7, 44, sthY + 4.5, 'FACTION / GANG', 0.35, 0.40, 0.50)
            text('F2', 7, 175, sthY + 4.5, 'UNITS', 0.35, 0.40, 0.50)
            text('F2', 7, 220, sthY + 4.5, 'TRUCKS', 0.35, 0.40, 0.50)
            text('F2', 7, 275, sthY + 4.5, 'AIRDROPS', 0.35, 0.40, 0.50)
            text('F2', 7, 335, sthY + 4.5, 'HIJACKS', 0.35, 0.40, 0.50)
            text('F2', 7, 395, sthY + 4.5, 'REWARDS / LOOT SUMMARY', 0.35, 0.40, 0.50)
        end

        local scorecard = data.gangScorecard or {}
        local sRowY = sthY - 15
        if #scorecard > 0 then
            for i = 1, math.min(#scorecard, 3) do
                local sc = scorecard[i]
                if i % 2 == 0 then
                    rect(36, sRowY, totalW, 15, 0.98, 0.99, 1.0)
                end
                if L.sec2Cols and sc.cells then
                    text('F2', 7, 44, sRowY + 4.5, tostring(sc.label or sc.name or 'Gang'):sub(1, 24), 0.15, 0.20, 0.30)
                    local xs2 = { 175, 250, 340, 440 }
                    for ci = 1, 4 do
                        text('F1', 7, xs2[ci], sRowY + 4.5, tostring(sc.cells[ci] or ''):sub(1, 22), 0.30, 0.35, 0.45)
                    end
                elseif data.kind == 'GANG_AIRDROP' then
                    text('F2', 7, 44, sRowY + 4.5, tostring(sc.label or sc.name or 'Gang'):sub(1, 24), 0.15, 0.20, 0.30)
                    text('F1', 7, 175, sRowY + 4.5, tostring(sc.units or 0), 0.30, 0.35, 0.45)
                    text('F1', 7, 240, sRowY + 4.5, ('%d drops'):format(sc.airdropsCaptured or 0), 0.15, 0.50, 0.25)
                    text('F1', 6.8, 340, sRowY + 4.5, tostring(sc.rewardSummary or 'None'):sub(1, 42), 0.20, 0.25, 0.35)
                elseif data.kind == 'HOT_CARGO' then
                    text('F2', 7, 44, sRowY + 4.5, tostring(sc.label or sc.name or 'Gang'):sub(1, 24), 0.15, 0.20, 0.30)
                    text('F1', 7, 175, sRowY + 4.5, tostring(sc.units or 0), 0.30, 0.35, 0.45)
                    text('F1', 7, 240, sRowY + 4.5, ('%d del / %d hijack'):format(sc.trucksCaptured or sc.trucksDelivered or 0, sc.hijacks or 0), 0.15, 0.50, 0.25)
                    text('F1', 6.8, 340, sRowY + 4.5, tostring(sc.rewardSummary or 'None'):sub(1, 42), 0.20, 0.25, 0.35)
                elseif data.kind == 'GANG_RACE' then
                    -- No lap/checkpoint telemetry is tracked per-gang, so
                    -- unlike the other kinds this can only honestly report
                    -- who was entered and who actually won, not a stat count.
                    local isWinner = data.winningGang and sc.name == data.winningGang
                    text('F2', 7, 44, sRowY + 4.5, tostring(sc.label or sc.name or 'Gang'):sub(1, 24), 0.15, 0.20, 0.30)
                    text('F1', 7, 175, sRowY + 4.5, tostring(sc.units or 0), 0.30, 0.35, 0.45)
                    if isWinner then
                        text('F2', 7, 280, sRowY + 4.5, 'WINNER', 0.15, 0.50, 0.25)
                    else
                        text('F1', 7, 280, sRowY + 4.5, 'Participated', 0.30, 0.35, 0.45)
                    end
                    text('F1', 6.8, 340, sRowY + 4.5, isWinner and tostring(data.rewards or 'None'):sub(1, 42) or 'None', 0.20, 0.25, 0.35)
                else
                    text('F2', 7, 44, sRowY + 4.5, tostring(sc.label or sc.name or 'Gang'):sub(1, 24), 0.15, 0.20, 0.30)
                    text('F1', 7, 175, sRowY + 4.5, tostring(sc.units or 0), 0.30, 0.35, 0.45)
                    text('F1', 7, 220, sRowY + 4.5, tostring(sc.trucksCaptured or 0), 0.30, 0.35, 0.45)
                    text('F1', 7, 275, sRowY + 4.5, tostring(sc.airdropsCaptured or 0), 0.30, 0.35, 0.45)
                    text('F1', 7, 335, sRowY + 4.5, tostring(sc.hijacks or 0), 0.30, 0.35, 0.45)
                    text('F1', 6.8, 395, sRowY + 4.5, tostring(sc.rewardSummary or 'None'):sub(1, 32), 0.15, 0.50, 0.25)
                end
                sRowY = sRowY - 15
            end
            if #scorecard > 3 then
                text('F1', 6.5, 46, sRowY + 4.5, ('... and %d more -- continued on the following pages.'):format(#scorecard - 3), 0.50, 0.55, 0.65)
            end
        else
            local emptyScore = L.sec2Empty or data.kind == 'GANG_AIRDROP'
                and '* No gangs actively registered crate captures during this airdrop operation.'
                or (data.kind == 'HOT_CARGO'
                    and '* No rival gangs actively delivered contraband during this Hot Cargo run.'
                    or (data.kind == 'GANG_RACE'
                        and '* No gang-affiliated racers were entered in this race.'
                        or '* No hostile gang factions were actively engaged in this operation.'))
            text('F1', 7.5, 46, sRowY + 4.5, emptyScore, 0.50, 0.55, 0.65)
        end

        -- ── SECTION 3: CHRONOLOGICAL INCIDENT TIMELINE ──
        local sec3Y = 56
        local sec3H = sec2Y - 68
        rect(36, sec3Y, totalW, sec3H, 1, 1, 1, 0.85, 0.88, 0.92, 1)

        text('F2', 9.5, 46, sec3Y + sec3H - 18, 'CHRONOLOGICAL INCIDENT TIMELINE', 0.12, 0.18, 0.28)
        line(46, sec3Y + sec3H - 22, 210, sec3Y + sec3H - 22, 0.23, 0.51, 0.96, 1.5)

        local tLineY = sec3Y + sec3H - 38
        local rawTimeline = data.timeline or {}
        local timeline = {}
        for _, l in ipairs(rawTimeline) do
            local str = tostring(l)
            if not str:lower():find('ambush') then
                timeline[#timeline + 1] = str
            end
        end
        local maxLines = math.floor((sec3H - 45) / 14)
        if #timeline > maxLines then
            text('F1', 6.5, 230, sec3Y + sec3H - 18, ('(latest %d of %d entries -- the complete timeline follows on the next pages)'):format(maxLines, #timeline), 0.50, 0.55, 0.65)
        end
        local startIdx = math.max(1, #timeline - maxLines + 1)
        for i = startIdx, #timeline do
            local lineText = tostring(timeline[i])
            text('F3', 7, 46, tLineY, lineText:sub(1, 112), 0.22, 0.28, 0.38)
            tLineY = tLineY - 14
        end

        -- ── CONTINUATION PAGES ──────────────────────────────────────────────────────────
        -- Page 1 is a fixed one-page summary: it shows the first 8 rows of the first table, the first 3 gangs of the
        -- scorecard and only the LAST lines of the timeline. Whatever does not fit is continued here on extra pages
        -- (the rest of both tables, any `data.extraTables` the event brings, and the complete timeline), so a long
        -- event — a 16-lot auction, a big airdrop — loses nothing in the PDF. If anything in here fails, the report
        -- falls back to the single page above rather than losing the PDF.
        local page1 = stream
        local contPages = {}
        local okCont, errCont = pcall(function()
            local contW = width - 72
            local cursorY = nil

            local function startContPage()
                stream = {}
                contPages[#contPages + 1] = stream
                rect(0, 0, width, height, 0.96, 0.97, 0.98)
                rect(0, height - 46, width, 46, 0.07, 0.11, 0.20)
                rect(0, height - 50, width, 4, stripeR, stripeG, stripeB)
                text('F2', 11, 36, height - 28, docTitle:upper():sub(1, 56), 1, 1, 1)
                text('F1', 7, 36, height - 41, ('OPERATION: %s  |  REF ID: #%s  |  CONTINUED'):format(
                    tostring(data.name or 'EVENT'):upper():sub(1, 34), tostring(data.id or '1')), 0.65, 0.75, 0.90)
                cursorY = height - 76
            end
            local function room(h)
                if not cursorY or cursorY - h < 58 then startContPage() end
            end

            -- breaks a string into lines of at most `n` characters (at a space where there is one), at most `maxLines` lines
            local function wrapText(s, n, maxLines)
                s = tostring(s or ''):gsub('[\r\n\t]', ' ')
                local out = {}
                while #s > n and #out < maxLines - 1 do
                    local cut = n
                    for i = n, math.floor(n / 2), -1 do
                        if s:sub(i, i) == ' ' then cut = i break end
                    end
                    out[#out + 1] = s:sub(1, cut)
                    s = (s:sub(cut + 1):gsub('^%s+', ''))
                end
                if #s > n then s = s:sub(1, n - 3) .. '...' end
                out[#out + 1] = s
                return out
            end

            -- a titled table; cols = { { label, x, chars, wrap?, font? }, ... }, rows = { { cell, cell, ... }, ... }
            local function drawTable(title, cols, rows, emptyMsg)
                room(72)
                text('F2', 9.5, 36, cursorY, tostring(title):sub(1, 70), 0.12, 0.18, 0.28)
                line(36, cursorY - 5, 36 + 170, cursorY - 5, 0.23, 0.51, 0.96, 1.5)
                cursorY = cursorY - 24
                local function header()
                    rect(36, cursorY - 4, contW, 16, 0.92, 0.94, 0.97)
                    for _, c in ipairs(cols) do text('F2', 7, c.x, cursorY, tostring(c.label or ''), 0.35, 0.40, 0.50) end
                    cursorY = cursorY - 18
                end
                header()
                if #rows == 0 then
                    text('F1', 7.5, 44, cursorY, emptyMsg or '* Nothing was recorded.', 0.50, 0.55, 0.65)
                    cursorY = cursorY - 22
                    return
                end
                for i, row in ipairs(rows) do
                    local cells, nLines = {}, 1
                    for ci, c in ipairs(cols) do
                        local v = tostring(row[ci] == nil and '' or row[ci])
                        if c.wrap then
                            cells[ci] = wrapText(v, c.chars or 30, 4)
                            nLines = math.max(nLines, #cells[ci])
                        else
                            cells[ci] = { v:sub(1, c.chars or 30) }
                        end
                    end
                    local rowH = math.max(15, nLines * 9 + 6)
                    if cursorY - rowH < 58 then startContPage(); header() end
                    if i % 2 == 0 then rect(36, cursorY - rowH + 11, contW, rowH, 0.98, 0.99, 1.0) end
                    for ci, c in ipairs(cols) do
                        for li, part in ipairs(cells[ci]) do
                            text(c.font or 'F1', 7, c.x, cursorY - (li - 1) * 9, part, 0.20, 0.25, 0.35)
                        end
                    end
                    cursorY = cursorY - rowH
                end
                cursorY = cursorY - 12
            end

            -- 1. the rest of the first table (page 1 shows only the first rows)
            if #interceptions > maxInterceptRows then
                local k = data.kind
                local heads = L.sec1Cols or {
                    'TIME',
                    k == 'GANG_AIRDROP' and 'DROP ZONE' or (k == 'HOT_CARGO' and 'TARGET / ZONE' or 'TARGET'),
                    k == 'GANG_AIRDROP' and 'ACCESS METHOD' or (k == 'HOT_CARGO' and 'STATUS / ACTION' or 'BREACH METHOD'),
                    k == 'GANG_AIRDROP' and 'CLAIMING GANG & ACTOR' or (k == 'HOT_CARGO' and 'OPERATIVE & GANG' or 'ACTOR & FACTION'),
                    k == 'GANG_AIRDROP' and 'CRATE LOOT SECURED' or (k == 'HOT_CARGO' and 'DETAIL / REWARDS' or 'EVIDENCE / LOOT EXTRACTED'),
                }
                local rows = {}
                for i = maxInterceptRows + 1, #interceptions do
                    local it = interceptions[i]
                    local actor = tostring(it.actorName or 'Unknown')
                    if it.faction and it.faction ~= '' then actor = actor .. ' [' .. tostring(it.faction) .. ']' end
                    if it.isPolice then actor = '[POLICE] ' .. actor end
                    rows[#rows + 1] = { it.time or '', it.target or '', it.method or '', actor, it.evidence or '' }
                end
                drawTable(('%s (CONTINUED, %d MORE)'):format(sec1Title, #rows), {
                    { label = heads[1], x = 44, chars = 10 },
                    { label = heads[2], x = 100, chars = 26, wrap = true },
                    { label = heads[3], x = 232, chars = 18, wrap = true },
                    { label = heads[4], x = 318, chars = 28, wrap = true },
                    { label = heads[5], x = 450, chars = 26, wrap = true },
                }, rows)
            end

            -- 2. the rest of the scorecard (page 1 shows only the first 3 gangs)
            local cards = data.gangScorecard or {}
            if #cards > 3 then
                local cols, rows = nil, {}
                if L.sec2Cols then
                    cols = {
                        { label = 'FACTION / GANG', x = 44, chars = 34 },
                        { label = L.sec2Cols[1], x = 200, chars = 16 }, { label = L.sec2Cols[2], x = 290, chars = 16 },
                        { label = L.sec2Cols[3], x = 380, chars = 16 }, { label = L.sec2Cols[4], x = 460, chars = 18 },
                    }
                    for i = 4, #cards do
                        local sc = cards[i]
                        local c = sc.cells or {}
                        rows[#rows + 1] = { sc.label or sc.name or 'Gang', c[1] or '', c[2] or '', c[3] or '', c[4] or '' }
                    end
                else
                    cols = {
                        { label = 'FACTION / GANG', x = 44, chars = 30 }, { label = 'UNITS', x = 190, chars = 8 },
                        { label = 'TRUCKS', x = 236, chars = 8 }, { label = 'AIRDROPS', x = 282, chars = 9 },
                        { label = 'HIJACKS', x = 336, chars = 9 }, { label = 'REWARDS / LOOT SUMMARY', x = 390, chars = 36, wrap = true },
                    }
                    for i = 4, #cards do
                        local sc = cards[i]
                        rows[#rows + 1] = { sc.label or sc.name or 'Gang', sc.units or 0, sc.trucksCaptured or 0, sc.airdropsCaptured or 0, sc.hijacks or 0, sc.rewardSummary or 'None' }
                    end
                end
                drawTable(('%s (CONTINUED, %d MORE)'):format(L.sec2Title or 'FACTION ENGAGEMENT & SCORECARD', #rows), cols, rows)
            end

            -- 3. extra detail tables an event brings along (Container Wars: what each lot held and how it ended)
            for _, t in ipairs(data.extraTables or {}) do
                if type(t) == 'table' and type(t.cols) == 'table' and type(t.rows) == 'table' then
                    drawTable(t.title or 'DETAILS', t.cols, t.rows, t.empty)
                end
            end

            -- 4. the complete timeline (page 1 shows only its last lines)
            if #timeline > maxLines then
                room(60)
                text('F2', 9.5, 36, cursorY, ('COMPLETE INCIDENT TIMELINE (%d ENTRIES)'):format(#timeline), 0.12, 0.18, 0.28)
                line(36, cursorY - 5, 36 + 190, cursorY - 5, 0.23, 0.51, 0.96, 1.5)
                cursorY = cursorY - 22
                for _, entry in ipairs(timeline) do
                    local parts = wrapText(entry, 118, 3)
                    if cursorY - (#parts * 10 + 3) < 58 then startContPage() end
                    for pi, part in ipairs(parts) do
                        text('F3', 6.8, 46 + (pi > 1 and 10 or 0), cursorY, part, 0.22, 0.28, 0.38)
                        cursorY = cursorY - 10
                    end
                    cursorY = cursorY - 3
                end
            end
        end)
        if not okCont then
            contPages = {}
            lib.print.warn(('[NovaConvoy] PDF continuation pages failed (%s) — the report keeps its first page only.'):format(tostring(errCont)))
        end
        stream = page1

        -- ── FOOTER (every page) ──
        local pageStreams = { page1 }
        for _, st in ipairs(contPages) do pageStreams[#pageStreams + 1] = st end
        for n, st in ipairs(pageStreams) do
            stream = st
            line(36, 42, width - 36, 42, 0.82, 0.85, 0.90, 0.8)
            text('F1', 7, 36, 28, docFooter, 0.50, 0.55, 0.62)
            text('F1', 7, width - 155, 28, ('Page %d of %d  |  Official Dispatch Audit'):format(n, #pageStreams), 0.50, 0.55, 0.62)
        end
        stream = page1

        -- Objects: 1 catalog, 2 page tree, 3-5 fonts, [6 logo], then a page + its content stream for every page.
        local firstPage = logo and 7 or 6
        local kids = {}
        for n = 1, #pageStreams do kids[n] = ('%d 0 R'):format(firstPage + (n - 1) * 2) end
        local resources = ('<< /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >>%s >>'):format(logo and ' /XObject << /Im1 6 0 R >>' or '')
        local pdfObjs = {
            [1] = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
            [2] = ('2 0 obj\n<< /Type /Pages /Kids [%s] /Count %d >>\nendobj\n'):format(table.concat(kids, ' '), #pageStreams),
            [3] = '3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n',
            [4] = '4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>\nendobj\n',
            [5] = '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>\nendobj\n',
        }
        if logo then
            pdfObjs[6] = ('6 0 obj\n<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /%s /BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n%s\nendstream\nendobj\n'):format(
                logo.w, logo.h, logo.comps == 1 and 'DeviceGray' or 'DeviceRGB', #logo.data, logo.data)
        end
        for n, st in ipairs(pageStreams) do
            local pid = firstPage + (n - 1) * 2
            local content = table.concat(st, '\n')
            pdfObjs[pid] = ('%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] /Contents %d 0 R /Resources %s >>\nendobj\n'):format(pid, width, height, pid + 1, resources)
            pdfObjs[pid + 1] = ('%d 0 obj\n<< /Length %d >>\nstream\n%s\nendstream\nendobj\n'):format(pid + 1, #content, content)
        end
        local nObj = firstPage + #pageStreams * 2 - 1

        local parts = { '%PDF-1.4\n%\xE2\xE3\xCF\xD3\n' }
        local offsets = { 0 }
        local curLen = #parts[1]

        for i = 1, nObj do
            offsets[i] = curLen
            parts[#parts + 1] = pdfObjs[i]
            curLen = curLen + #pdfObjs[i]
        end

        local startXref = curLen
        parts[#parts + 1] = ('xref\n0 %d\n0000000000 65535 f \n'):format(nObj + 1)
        for i = 1, nObj do
            parts[#parts + 1] = ('%010d 00000 n \n'):format(offsets[i])
        end
        parts[#parts + 1] = ('trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n'):format(nObj + 1, startXref)

        return table.concat(parts)
    end)

    if ok and result then
        return result
    else
        lib.print.warn(('[NovaConvoy] PDF generation failed: %s'):format(tostring(result)))
        return nil
    end
end

return PdfGenerator
