-- ─── NUI Bridge for Nova Convoy Truck ────────────────────────────────────────
-- All UI calls go through this file so client/main.lua stays clean.

ConvoyUI = {} -- Global for maximum compatibility

-- ── Internal helper ──────────────────────────────────────────────────────────
local function send(msg)
    if IsDuplicityVersion() then return end -- Don't run on server
    SendNUIMessage(msg)
end

-- ── Checkpoint Timer HUD ─────────────────────────────────────────────────────

function ConvoyUI.showTimer(seconds, index, total)
    send({ action = 'startCheckpointTimer', time = seconds, index = index, total = total })
end

function ConvoyUI.syncTimer(seconds)
    send({ action = 'updateCheckpointTimer', time = seconds })
end

function ConvoyUI.pauseTimer(paused)
    if paused then
        send({ action = 'pauseCheckpointTimer' })
    else
        send({ action = 'resumeCheckpointTimer' })
    end
end

function ConvoyUI.hideTimer()
    send({ action = 'hideCheckpointTimer' })
end

-- ── Delivery Timer HUD ───────────────────────────────────────────────────────

-- kind: nil/'DELIVERY' (default — CONVOY/HOT_CARGO) or 'AIRDROP' (Gang
-- Airdrop's own overall event clock, which has no delivery phase at all —
-- see DeliveryTimer.svelte for the label/icon this actually changes).
function ConvoyUI.startDeliveryTimer(seconds, kind)
    send({ action = 'startDeliveryTimer', time = seconds, kind = kind })
end

function ConvoyUI.updateDeliveryTimer(seconds, kind)
    send({ action = 'updateDeliveryTimer', time = seconds, kind = kind })
end

function ConvoyUI.hideDeliveryTimer()
    send({ action = 'hideDeliveryTimer' })
end

-- ── Pre-Start Countdown (police-facing "get ready") ─────────────────────────
-- Fires the instant a convoy is triggered (Start button or the physical
-- start-ped), well before the public "Convoy Started" banner (delayed by
-- Config.ConvoyStartAnnounceDelaySeconds) — gives police who are already
-- online a themed on-screen countdown to actually get into position before
-- gangs are alerted that anything is happening.

function ConvoyUI.startPrepCountdown(seconds)
    send({ action = 'startPrepCountdown', time = seconds })
end

function ConvoyUI.hidePrepCountdown()
    send({ action = 'hidePrepCountdown' })
end

-- ── Announcement Banner ──────────────────────────────────────────────────────

-- type: 'start' | 'success' | 'checkpoint' | 'warn' | 'danger' | 'info' (default)
-- gang (optional): { name, label, logo } — shows that gang's logo on the banner
-- instead of the generic type icon (e.g. a convoy capture).
-- `status` (optional) is the text of the badge on the right of the banner, e.g. "ROUND 2 / 4"; without it the badge
-- is worked out from the title.
function ConvoyUI.announce(title, body, duration, kind, gang, status, bannerColor, imageUrl, imagePosition, imageFit, posX, posY, zoom)
    send({
        action = 'announce',
        title = title,
        message = body,
        duration = duration or 7000,
        type = kind or 'info',
        gang = gang,
        status = status,
        bannerColor = bannerColor,
        imageUrl = imageUrl,
        imagePosition = imagePosition,
        imageFit = imageFit,
        posX = posX,
        posY = posY,
        zoom = zoom
    })
end

-- ── Toast Notifications ──────────────────────────────────────────────────────

function ConvoyUI.toast(icon, title, sub, warn, duration)
    send({ action = 'showToast', icon = icon, title = title, message = sub, type = warn and 'warn' or 'success', duration = duration or 5000 })
end

-- ── TDM Match HUD ────────────────────────────────────────────────────────────
-- teamA/teamB: { label, score }. mvp (optional): { name, kills, deaths } —
-- server-computed, shared by everyone. Its own store/clock client-side
-- (hudStore.js's tdmHud) — deliberately not routed through
-- startDeliveryTimer/updateDeliveryTimer so this can't affect the
-- already-live Convoy/Airdrop/Hot Cargo delivery timer.

function ConvoyUI.startTdmMatch(seconds, teamA, teamB, myKills, myDeaths, mvp)
    send({ action = 'startTdmMatch', time = seconds, teamA = teamA, teamB = teamB, myKills = myKills, myDeaths = myDeaths, mvp = mvp })
end

function ConvoyUI.updateTdmMatch(seconds, teamA, teamB, myKills, myDeaths, mvp)
    send({ action = 'updateTdmMatch', time = seconds, teamA = teamA, teamB = teamB, myKills = myKills, myDeaths = myDeaths, mvp = mvp })
end

function ConvoyUI.hideTdmMatch()
    send({ action = 'hideTdmMatch' })
end

-- Generic kill-feed card — used by BOTH TDM (broadcast to every match
-- participant) and the solo Practice Range (entirely local to one client,
-- player-vs-bot). weapon is a display label already resolved by the caller
-- (never a raw weapon hash). tag/type (optional): 'HEAD'/'headshot',
-- 'DOUBLE'/'double', 'TRIPLE'/'triple', '<n>X'/'streak' — blank for a plain
-- kill with no notable tag.
function ConvoyUI.tdmKillFeedEntry(payload)
    send({
        action = 'tdmKillFeedEntry',
        killer = payload.killer, killerTeam = payload.killerTeam,
        victim = payload.victim, victimTeam = payload.victimTeam,
        weapon = payload.weapon, tag = payload.tag, type = payload.type,
        duration = payload.duration,
    })
end

-- Personal-only feedback (never broadcast) — flashType: 'head'|'double'|
-- 'triple'|'streak'. streak (optional): current kill streak, only shown as
-- its own badge once it reaches 4. Same reuse across TDM and Practice Range
-- as the kill feed above.
function ConvoyUI.tdmEventFlash(flashType, streak, victim)
    send({ action = 'tdmEventFlash', flashType = flashType, streak = streak, victim = victim })
end

-- TDM only: the killer's bottom-centre "Kill Confirmed" emblem, shown on every kill.
function ConvoyUI.tdmKillConfirm(killer, victim)
    send({ action = 'tdmKillConfirm', killer = killer, victim = victim })
end

-- ── Practice Range HUD ───────────────────────────────────────────────────────
-- Its own small persistent readout — no team score/timer, practice is
-- solo/unscored. Kill feed/flash/streak above are reused as-is.

function ConvoyUI.practiceHudUpdate(kills, location)
    send({ action = 'practiceHudUpdate', kills = kills, location = location })
end

function ConvoyUI.practiceHudHide()
    send({ action = 'practiceHudHide' })
end

-- ── Practice Armory (squad join-UI) ──────────────────────────────────────────
-- locations: [{ id, label, tag }]. weapons: [{ weapon, label, ... }] — same
-- shape as Config.PracticeRange.weapons. squad: [{ source, name, ping,
-- status, isHost }]. isHost: only the host sees the Deploy button; everyone
-- else sees a "waiting for host" message (PracticeArmory.svelte).

function ConvoyUI.openPracticeArmory(locations, weapons, squad, isHost)
    send({ action = 'practiceArmory:open', locations = locations, weapons = weapons, squad = squad, isHost = isHost })
end

function ConvoyUI.closePracticeArmory()
    send({ action = 'practiceArmory:close' })
end

-- Pushed to every squad member whenever someone joins/leaves/is kicked so
-- their roster list stays live without re-opening the whole screen.
function ConvoyUI.updatePracticeSquad(squad)
    send({ action = 'practiceArmory:squadUpdate', squad = squad })
end

-- ── Match Results (post-match screen) ────────────────────────────────────────
-- mode: 'practice' | 'event'. players: [{ name, team, kills, deaths, points,
-- you, mvp }]. scoreA/scoreB (event mode only): final team scores.

function ConvoyUI.showMatchResults(mode, eventName, duration, players, scoreA, scoreB, outcome)
    send({ action = 'matchResults:show', mode = mode, eventName = eventName, duration = duration, players = players, scoreA = scoreA, scoreB = scoreB, outcome = outcome })
end

function ConvoyUI.hideMatchResults()
    send({ action = 'matchResults:hide' })
end

-- ── Convenience wrappers ─────────────────────────────────────────────────────

function ConvoyUI.checkpointReached(index, total, seconds)
    ConvoyUI.announce(
        'Checkpoint Secured',
        string.format('Checkpoint %d / %d\nConvoy truck secured. Defend the position!', index, total),
        8000,
        'checkpoint'
    )
    ConvoyUI.showTimer(seconds, index, total)
end

function ConvoyUI.checkpointCleared(nextIndex, total)
    ConvoyUI.hideTimer()
end
