-- ─── Nova Convoy — Scheduling Engine (server) ─────────────────────────────────
-- Automatically initiates scheduled convoys when scheduledAt time is reached.

Scheduler = {}

-- Days since the Unix epoch for a given proleptic-Gregorian date (Howard
-- Hinnant's days_from_civil algorithm). Pure arithmetic, independent of the
-- host clock/timezone entirely — unlike os.time(), which interprets a date
-- table using the HOST's local timezone.
local function daysFromCivil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function computeHostUtcOffset()
    local now = os.time()
    local utc = os.date('!*t', now)
    local localT = os.date('*t', now)
    local utcSec = daysFromCivil(utc.year, utc.month, utc.day) * 86400 + utc.hour * 3600 + utc.min * 60 + utc.sec
    local localSec = daysFromCivil(localT.year, localT.month, localT.day) * 86400 + localT.hour * 3600 + localT.min * 60 + localT.sec
    return (localSec - utcSec) / 3600
end

function Scheduler.getHostUtcOffset()
    return computeHostUtcOffset()
end

local settings = {
    utcOffsetHours = Config.ScheduleUtcOffsetHours ~= nil and Config.ScheduleUtcOffsetHours or computeHostUtcOffset(),
    pollIntervalSeconds = Config.SchedulePollIntervalSeconds or 15,
}

function Scheduler.getSettings()
    return { utcOffsetHours = settings.utcOffsetHours, pollIntervalSeconds = settings.pollIntervalSeconds }
end

-- Called once from main.lua's onResourceStart, after DB.init() — pulls the
-- persisted row (if any) over the config.lua-seeded defaults above.
function Scheduler.loadSettings()
    local saved = DB.getScheduleSettings()
    if saved and saved.utcOffsetHours ~= nil then
        settings.utcOffsetHours = saved.utcOffsetHours
        settings.pollIntervalSeconds = saved.pollIntervalSeconds or 15
    else
        settings.utcOffsetHours = Config.ScheduleUtcOffsetHours ~= nil and Config.ScheduleUtcOffsetHours or computeHostUtcOffset()
    end
end

-- Validates and persists new values; returns ok, err. The new poll interval
-- only takes effect on the NEXT tick of the poll loop below (it re-reads
-- settings.pollIntervalSeconds each iteration) — a currently-sleeping Wait()
-- always runs to completion, same as any other live-tunable interval.
function Scheduler.setSettings(utcOffsetHours, pollIntervalSeconds)
    utcOffsetHours = tonumber(utcOffsetHours)
    pollIntervalSeconds = tonumber(pollIntervalSeconds)
    if not utcOffsetHours or utcOffsetHours < -14 or utcOffsetHours > 14 then
        return false, 'UTC offset must be between -14 and 14.'
    end
    if not pollIntervalSeconds or pollIntervalSeconds < 5 or pollIntervalSeconds > 3600 then
        return false, 'Poll interval must be between 5 and 3600 seconds.'
    end
    if not DB.setScheduleSettings(utcOffsetHours, pollIntervalSeconds) then
        return false, 'Database write failed — check the server console for a SQL error (nova_schedule_settings table).'
    end
    settings.utcOffsetHours = utcOffsetHours
    settings.pollIntervalSeconds = pollIntervalSeconds
    return true
end

-- Converts a wall-clock date/time — interpreted as being in the timezone
-- Config.ScheduleUtcOffsetHours describes — into a true UTC unix timestamp.
-- This is what a future scheduling UI should call with the fields an admin
-- typed in, rather than building the timestamp with os.time() (which would
-- reintroduce the host-timezone dependency this exists to avoid).
function Scheduler.toUtcTimestamp(year, month, day, hour, minute, second)
    local days = daysFromCivil(year, month, day)
    local assumedLocalSeconds = days * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
    return assumedLocalSeconds - math.floor(settings.utcOffsetHours * 3600)
end

-- Current true UTC unix timestamp, independent of the host machine's
-- configured timezone.
function Scheduler.nowUtc()
    local t = os.date('!*t')
    return daysFromCivil(t.year, t.month, t.day) * 86400 + t.hour * 3600 + t.min * 60 + t.sec
end

-- Reverse of toUtcTimestamp — formats a stored UTC timestamp back into the
-- configured-offset wall-clock string, for player-facing messages (e.g. the
-- start-trigger ped telling an early officer when to come back).
function Scheduler.formatLocal(utcTimestamp)
    if not utcTimestamp then return 'an unset time' end
    local offsetSeconds = math.floor(settings.utcOffsetHours * 3600)
    local text = os.date('!%Y-%m-%d %H:%M', utcTimestamp + offsetSeconds)
    local offsetHours = settings.utcOffsetHours
    if offsetHours == 0 then return text .. ' UTC' end
    return ('%s (UTC%+g)'):format(text, offsetHours)
end

-- Returns a human-readable schedule summary. If configured with a random time
-- window, it intentionally displays the active window range (e.g. "Daily between 8:00 PM and 10:00 PM")
-- without revealing the exact trigger minute to keep the launch unpredictable.
function Scheduler.formatScheduleSummary(def)
    local r = def and def.recurrence
    if not r or not r.enabled then
        if def and def.scheduledAt then
            return Scheduler.formatLocal(def.scheduledAt)
        end
        return 'Not scheduled'
    end

    local freq = (r.type == 'DAILY' and 'Daily') or (r.type == 'WEEKLY' and 'Weekly') or (r.type == 'YEARLY' and 'Yearly') or 'Monthly'
    if r.type == 'WEEKLY' then
        local dayNames = { [0] = 'Sunday', [1] = 'Monday', [2] = 'Tuesday', [3] = 'Wednesday', [4] = 'Thursday', [5] = 'Friday', [6] = 'Saturday' }
        freq = ('Every %s'):format(dayNames[r.dayOfWeek or 0] or 'week')
    elseif r.type == 'MONTHLY' then
        freq = ('Monthly on day %d'):format(r.dayOfMonth or 1)
    elseif r.type == 'YEARLY' then
        local monthNames = { 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December' }
        freq = ('Yearly on %s %d'):format(monthNames[r.month or 1] or 'January', r.dayOfMonth or 1)
    end

    if r.mode == 'WINDOW' then
        local sh = r.windowStartHour or 0
        local sm = r.windowStartMinute or 0
        local eh = r.windowEndHour or 0
        local em = r.windowEndMinute or 0
        local function fmtTime(h, m)
            local ampm = h >= 12 and 'PM' or 'AM'
            local h12 = h % 12
            if h12 == 0 then h12 = 12 end
            return ('%d:%02d %s'):format(h12, m, ampm)
        end
        return ('%s between %s and %s (Unpredictable Window)'):format(freq, fmtTime(sh, sm), fmtTime(eh, em))
    else
        local h = r.hour or 0
        local m = r.minute or 0
        local ampm = h >= 12 and 'PM' or 'AM'
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        return ('%s at %d:%02d %s'):format(freq, h12, m, ampm)
    end
end

-- Computes the next UTC timestamp at/after `fromUtc` that matches a recurrence rule.
-- Supports both 'EXACT' (fixed time) and 'WINDOW' (random time window).
-- When 'WINDOW' is used, a cryptographically random time within the configured window
-- (e.g. 8:00 PM to 10:00 PM) is rolled for that cycle.
-- forceNextCycle: when true (e.g. from Scheduler.rearm after an event completes),
-- skips today's cycle entirely and advances to tomorrow/next occurrence.
function Scheduler.nextOccurrence(recurrence, fromUtc, forceNextCycle)
    local offsetSeconds = math.floor(settings.utcOffsetHours * 3600)
    local localNow = fromUtc + offsetSeconds
    local t = os.date('!*t', localNow)
    local isWindow = (recurrence.mode == 'WINDOW')

    local startSec = (recurrence.windowStartHour or 0) * 3600 + (recurrence.windowStartMinute or 0) * 60
    local endSec = (recurrence.windowEndHour or 0) * 3600 + (recurrence.windowEndMinute or 0) * 60
    if isWindow and endSec <= startSec then
        endSec = math.min(86399, startSec + 3600)
    end

    local function rollSecondForDay(isToday)
        if not isWindow then
            local exactSec = (recurrence.hour or 0) * 3600 + (recurrence.minute or 0) * 60
            if isToday then
                local secPassedToday = t.hour * 3600 + t.min * 60 + t.sec
                if secPassedToday + 60 > exactSec then
                    return nil
                end
            end
            return exactSec
        end
        local low = startSec
        if isToday then
            local secPassedToday = t.hour * 3600 + t.min * 60 + t.sec
            if secPassedToday + 60 > low then
                low = secPassedToday + 60
            end
        end
        if low >= endSec then return nil end
        return math.random(low, endSec)
    end

    if recurrence.type == 'DAILY' then
        local todayDays = daysFromCivil(t.year, t.month, t.day)
        if not forceNextCycle then
            local sec = rollSecondForDay(true)
            if sec ~= nil then
                return todayDays * 86400 + sec - offsetSeconds
            end
        end
        -- Advance to tomorrow and roll a fresh random time within the window
        local secTomorrow = rollSecondForDay(false)
        return (todayDays + 1) * 86400 + secTomorrow - offsetSeconds

    elseif recurrence.type == 'MONTHLY' then
        local day = math.min(recurrence.dayOfMonth or 1, 28)
        local isToday = (t.day == day)
        if isToday and not forceNextCycle then
            local sec = rollSecondForDay(true)
            if sec ~= nil then
                return daysFromCivil(t.year, t.month, day) * 86400 + sec - offsetSeconds
            end
        end
        local y, m = t.year, t.month
        if isToday or day < t.day then
            m = m + 1
            if m > 12 then m, y = 1, y + 1 end
        end
        local sec = rollSecondForDay(false)
        return daysFromCivil(y, m, day) * 86400 + sec - offsetSeconds

    elseif recurrence.type == 'YEARLY' then
        -- Unlike MONTHLY, the day isn't capped to 28 — a specific month is
        -- picked too (via the calendar-grid UI, which already only lets an
        -- admin click a day that actually exists in that month), so e.g.
        -- December 25th is a perfectly valid day 25.
        local day = recurrence.dayOfMonth or 1
        local month = recurrence.month or 1
        local isToday = (t.day == day and t.month == month)
        if isToday and not forceNextCycle then
            local sec = rollSecondForDay(true)
            if sec ~= nil then
                return daysFromCivil(t.year, month, day) * 86400 + sec - offsetSeconds
            end
        end
        local y = t.year
        local pastThisYear = isToday or (t.month > month) or (t.month == month and t.day > day)
        if pastThisYear then y = y + 1 end
        local sec = rollSecondForDay(false)
        return daysFromCivil(y, month, day) * 86400 + sec - offsetSeconds

    else -- WEEKLY
        local wantDow = recurrence.dayOfWeek or 0
        local curDow = t.wday - 1 -- 0=Sun..6=Sat
        local diff = (wantDow - curDow) % 7
        local todayDays = daysFromCivil(t.year, t.month, t.day)

        if diff == 0 and not forceNextCycle then
            local sec = rollSecondForDay(true)
            if sec ~= nil then
                return todayDays * 86400 + sec - offsetSeconds
            end
            diff = 7
        elseif diff == 0 and forceNextCycle then
            diff = 7
        end

        local sec = rollSecondForDay(false)
        return (todayDays + diff) * 86400 + sec - offsetSeconds
    end
end

-- Called once a recurring convoy/airdrop/hotcargo reaches a terminal outcome.
-- Advances to the NEXT scheduled occurrence (forceNextCycle = true so it rolls
-- for the next day/week rather than re-triggering today).
function Scheduler.rearm(convoyId, def)
    local r = def and def.recurrence
    if not r or not r.enabled then return end
    local nextAt = Scheduler.nextOccurrence(r, Scheduler.nowUtc(), true)
    def.roster = {}
    def.policeRoster = {}
    DB.updateConvoyDefinition(convoyId, def)
    ConvoyManager.scheduleInternal(convoyId, nextAt)
end

local firing = {} -- convoyId -> true while a due-fire is in flight, blocks a duplicate trigger within the same poll tick

-- convoyId .. ':' .. scheduledAt -> true once its pre-start "starting soon"
-- banner has fired, so it doesn't repeat every poll tick between the lead
-- window opening and the event actually going live. Keyed on scheduledAt
-- itself (not just convoyId) so rescheduling to a new time is naturally a
-- fresh, unannounced entry rather than needing an explicit reset anywhere.
local preAnnounced = {}

local function pollPreAnnounce()
    local lead = Config.PreScheduleAnnounceSeconds
    if not lead or lead <= 0 then return end
    local now = Scheduler.nowUtc()
    for _, def in ipairs(ConvoyManager.getAll()) do
        if def.status == 'SCHEDULED' and def.scheduledAt and not Runtime.isActive(def.id) then
            local key = def.id .. ':' .. def.scheduledAt
            if now >= def.scheduledAt - lead and now < def.scheduledAt and not preAnnounced[key] then
                preAnnounced[key] = true
                Runtime.announceScheduled(def)
            end
        end
    end
end

local function pollDueConvoys()
    local now = Scheduler.nowUtc()
    for _, def in ipairs(ConvoyManager.getAll()) do
        if def.status == 'SCHEDULED' and def.scheduledAt and def.scheduledAt <= now and not firing[def.id] and not Runtime.isActive(def.id) then
            firing[def.id] = true
            local ok, err = Runtime.startScheduled(def.id)
            if not ok then
                lib.print.warn(('[NovaConvoy] Scheduled convoy #%d failed to auto-start: %s'):format(def.id, tostring(err)))
                -- A recurring convoy that fails to start (e.g. its airdrop
                -- zones got cleared) still gets rearmed for its next
                -- occurrence instead of falling back to DRAFT forever — an
                -- admin fixing it later shouldn't also have to remember to
                -- re-enable the recurrence.
                if def.recurrence and def.recurrence.enabled then
                    Scheduler.rearm(def.id, def)
                else
                    ConvoyManager.setStatus(def.id, 'DRAFT')
                end
            end
            firing[def.id] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(settings.pollIntervalSeconds * 1000)
        pollPreAnnounce()
        pollDueConvoys()
    end
end)

return Scheduler
