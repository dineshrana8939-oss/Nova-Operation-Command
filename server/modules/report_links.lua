-- ─── Report download links ─────────────────────────────────────────────────────────────────────────────────
-- FiveM's in-game browser (the tablet) cannot save files, so "Download PDF" cannot write to the player's disk from
-- there. Instead the server keeps the generated PDF for a few minutes behind a long random link served by this
-- resource's own HTTP endpoint (http://<server>/<resource>/reports/<token>/<file>.pdf); the tablet opens that link in
-- the player's normal web browser, which downloads it like any other file.
--
-- A link only exists after the permission check in the callback that creates it (see getReportLink in callbacks.lua),
-- is unguessable, expires after TTL seconds and stops working after a few downloads.

ReportLinks = {}

local TTL = 600                  -- seconds a link stays valid
local MAX_HITS = 6               -- a browser may fetch twice (preview + save); a handful is plenty
local MAX_LINKS = 60             -- never hold more PDFs in memory than this

local links = {}                 -- token -> { bytes, fileName, expires, hits }
local counter = 0

math.randomseed((os.time() * 1000) + (GetGameTimer() % 1000))

local function newToken()
    counter = counter + 1
    local parts = {}
    for i = 1, 32 do parts[i] = ('%x'):format(math.random(0, 15)) end
    -- mixed with a counter and the clock so two links made in the same moment can never collide
    return table.concat(parts) .. ('%x%x'):format(counter % 4096, math.floor(os.clock() * 1000) % 65536)
end

local function prune()
    local now = os.time()
    local n = 0
    for token, link in pairs(links) do
        if link.expires < now then links[token] = nil else n = n + 1 end
    end
    -- over the cap: drop the oldest
    while n >= MAX_LINKS do
        local oldestToken, oldest
        for token, link in pairs(links) do
            if not oldest or link.expires < oldest then oldestToken, oldest = token, link.expires end
        end
        if not oldestToken then break end
        links[oldestToken] = nil
        n = n - 1
    end
end

-- Returns the URL path (relative to the server address) for this PDF.
function ReportLinks.create(bytes, fileName)
    prune()
    local token = newToken()
    local safeName = tostring(fileName or 'report.pdf'):gsub('[^%w%._%-]', '_')
    if not safeName:lower():match('%.pdf$') then safeName = safeName .. '.pdf' end
    links[token] = { bytes = bytes, fileName = safeName, expires = os.time() + TTL, hits = 0 }
    return ('/%s/reports/%s/%s'):format(GetCurrentResourceName(), token, safeName), token
end

SetHttpHandler(function(request, response)
    local token = tostring(request.path or ''):match('^/reports/(%x+)')
    local link = token and links[token] or nil
    if request.method ~= 'GET' or not link or link.expires < os.time() or link.hits >= MAX_HITS then
        if link and (link.expires < os.time() or link.hits >= MAX_HITS) then links[token] = nil end
        response.writeHead(404, { ['Content-Type'] = 'text/plain; charset=utf-8', ['Cache-Control'] = 'no-store' })
        response.send('This report link has expired. Open the report in the tablet and press Download PDF again.')
        return
    end
    link.hits = link.hits + 1
    response.writeHead(200, {
        ['Content-Type'] = 'application/pdf',
        ['Content-Disposition'] = ('attachment; filename="%s"'):format(link.fileName),
        ['Content-Length'] = tostring(#link.bytes),
        ['Cache-Control'] = 'no-store',
        ['X-Content-Type-Options'] = 'nosniff',
    })
    response.send(link.bytes)
end)

return ReportLinks
