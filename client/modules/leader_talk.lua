-- ─── Nova Convoy — Gang Leader conversation (client) ──────────────────────────────────────────────────────────────
-- The territory leader ped (spawned by client/modules/territory.lua) offers four ox_target choices: Pay Respects, Speak to Leader,
-- Ask About Territory, Ask About Trouble. This file runs them. The talk panel itself is web/src/lib/hud/LeaderTalk.svelte, drawn
-- on the left of the screen so the ped stays in view; the facts come from ONE server read (nova_convoytruck:territory:leaderTalk) that
-- is built from the live territory / war / XP state, so nothing the leader says is made up and nothing is shown to someone who may not know it.
--
--   LeaderTalk.open(ped, territoryId, topic)   topic: 'speak' | 'territory' | 'trouble'
--   LeaderTalk.respect(ped, territoryId)       the animation + a short acknowledgement (no panel)
--   LeaderTalk.busy()                          true while a conversation is open
--
-- The conversation never moves the player: they only turn to face the ped. NUI focus is taken while the panel is open (Esc, or Leave,
-- ends it) and the ped goes back to its post (heading, freeze, guard scenario) afterwards.

LeaderTalk = {}

local session = nil   -- { ped, territoryId, ctx, node, heading }

local function tcfg() return (Config.Territory or {}) end
local function enabled() return ((tcfg().leaderTalk or {}).enabled) ~= false end
local function maxRange() return tonumber((tcfg().leaderTalk or {}).maxDistance) or 6.0 end

local function dictReady(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local untilAt = GetGameTimer() + 1500
    while not HasAnimDictLoaded(dict) and GetGameTimer() < untilAt do Wait(0) end
    return HasAnimDictLoaded(dict)
end

local function say(kind, title, text)
    lib.notify({ type = kind, title = title, description = text, duration = 4500 })
end

-- ── the leader's post ─────────────────────────────────────────────────────────────────────────────────────────────

local function faceEachOther(ped)
    local me = PlayerPedId()
    FreezeEntityPosition(ped, false)
    ClearPedTasks(ped)
    TaskTurnPedToFaceEntity(ped, me, 900)
    TaskTurnPedToFaceEntity(me, ped, 700)
    Wait(750)
    if DoesEntityExist(ped) then TaskLookAtEntity(ped, me, -1, 2048, 3) end
end

local function backToPost(ped, heading)
    if not (ped and DoesEntityExist(ped)) then return end
    ClearPedTasks(ped)
    TaskClearLookAt(ped)
    if heading then SetEntityHeading(ped, heading) end
    FreezeEntityPosition(ped, true)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_GUARD_STAND', 0, true)
end

local GESTURE = { own = 'gesture_pleased', rival = 'gesture_displeased', outsider = 'gesture_displeased', unclaimed = 'gesture_shrug_hard' }
local function gesture(ped, relation, clip)
    if not (ped and DoesEntityExist(ped)) then return end
    local dict = 'gestures@m@standing@casual'
    if not dictReady(dict) then return end
    TaskPlayAnim(ped, dict, clip or GESTURE[relation] or 'gesture_hand_down', 8.0, -8.0, 1800, 48, 0.0, false, false, false)
end

-- ── wording (every number comes from ctx or from Config.Territory.war) ───────────────────────────────────────────

local function km(n) return n and ('%.2f km²'):format(n) or '—' end
local function clock(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return ('%d:%02d'):format(math.floor(sec / 60), sec % 60)
end
local function plural(n, one, many) return n == 1 and one or many end
local function money(n) return '$' .. tostring(math.floor(tonumber(n) or 0)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '') end

-- the leader does not repeat himself word for word every visit: one of a few lines, chosen once per conversation
local function oneOf(list, salt)
    local seed = (session and session.seed) or 1
    return list[((seed + (salt or 0)) % #list) + 1]
end

local STATUS_WORDS = {
    PENDING = 'waiting for an answer', ACCEPTED = 'accepted, no date yet', SCHEDULED = 'war booked', ACTIVE = 'war on right now',
}

local function openLine(e)
    local s = STATUS_WORDS[e.status] or e.status
    if e.status == 'SCHEDULED' and e.at then s = 'war at ' .. e.at end
    if e.status == 'ACTIVE' and e.secondsLeft then s = ('war on now, %s left'):format(clock(e.secondsLeft)) end
    return ('%s vs %s over %s (%s)'):format(e.attacker or '?', e.defender or '?', e.territory or '?', s)
end

local function refusal()
    return ((((tcfg().war or {}).postWarLoot or {}).tauntMessage)) or 'That is none of your business.'
end

local function inside(ctx) return ctx.me.relation == 'own' or ctx.me.staff == true end
local BACK = { id = 'root', label = 'Back' }

local function nodeRoot(ctx)
    local rel, t = ctx.me.relation, ctx.t
    local gang = t.ownerLabel or 'Nobody'
    local line, options
    if rel == 'own' or (ctx.me.staff and t.owner) then
        if t.busy then
            line = ('Not a good time. There is a war on %s right now.'):format(t.name)
        else
            line = oneOf({
                ('Good to see you. %s is still ours.'):format(t.name),
                'There you are. Pull up a bit of wall and talk to me.',
                ('Quiet day on %s so far. What is on your mind?'):format(t.name),
            })
        end
        options = {
            { id = 'territory', label = ('How is %s holding up?'):format(t.name) },
            { id = 'gang', label = 'How is the family doing?' },
            { id = 'trouble', label = 'Any trouble I should know about?' },
            { id = 'advice', label = 'What should I be doing for the gang?' },
            { id = 'leave', label = 'Just checking in.' },
        }
    elseif rel == 'rival' then
        local h = ctx.history
        if t.busy then
            line = ('There is a war on %s. Stand clear, or get caught in it.'):format(t.name)
        elseif h and h.fights and h.fights > 0 then
            line = ('You again. %s and your gang have fought %d %s.%s'):format(gang, h.fights, plural(h.fights, 'war', 'wars'),
                h.lastWinner and (' The last one went to ' .. h.lastWinner .. '.') or '')
        else
            line = oneOf({
                ('You are standing on %s ground. Say what you came to say.'):format(gang),
                ('Wrong colours for this street. What do you want?'),
                ('%s does not get visitors from your side. Talk fast.'):format(gang),
            })
        end
        options = { { id = 'territory', label = 'Whose ground is this?' } }
        if ctx.between and #ctx.between > 0 then
            options[#options + 1] = { id = 'between', label = 'About the challenge between us.' }
        else
            options[#options + 1] = { id = 'take', label = 'How would someone take this place?' }
        end
        options[#options + 1] = { id = 'trouble', label = 'What is going on between us?' }
        options[#options + 1] = { id = 'leave', label = 'Nothing. I am leaving.' }
    elseif rel == 'outsider' then
        line = oneOf({
            ('I do not know your face. This is %s ground, keep it moving.'):format(gang),
            ('Lost? This block belongs to %s.'):format(gang),
            'You are not from here. State your business or walk.',
        })
        options = {
            { id = 'territory', label = 'Whose ground is this?' },
            { id = 'take', label = 'How does somebody take ground around here?' },
            { id = 'join', label = 'How do I get in with a gang?' },
            { id = 'leave', label = 'Fair enough.' },
        }
    else   -- unclaimed (or staff looking at a ped nobody owns)
        line = oneOf({
            ('Nobody holds %s right now. It is there for whoever takes it.'):format(t.name),
            ('%s has no flag on it. Nobody has paid for it, nobody has fought for it.'):format(t.name),
        })
        options = {
            { id = 'territory', label = 'Tell me about this place.' },
            { id = 'take', label = 'How do I claim it?' },
            { id = 'leave', label = 'Thanks.' },
        }
    end
    return { line = line, options = options }
end

local function nodeTerritory(ctx)
    local t, o = ctx.t, ctx.owner
    local rel = ctx.me.relation
    local facts = {
        { k = 'Territory', v = t.name },
        { k = 'Held by', v = t.owner and (t.ownerLabel or t.owner) or 'Nobody' },
        { k = 'Land', v = ('%s (%d cells)'):format(km(t.areaKm2), t.cells or 0) },
    }
    if (tonumber(t.xpValue) or 0) > 0 then facts[#facts + 1] = { k = 'Worth', v = ('%s Gang XP'):format(tostring(t.xpValue)) } end
    facts[#facts + 1] = { k = 'Right now', v = t.busy and 'War in progress' or 'Quiet' }
    if o then
        facts[#facts + 1] = { k = 'Holdings', v = ('%d %s · %s'):format(o.count or 1, plural(o.count or 1, 'territory', 'territories'), km(o.areaKm2)) }
        if inside(ctx) and o.xp then facts[#facts + 1] = { k = 'Gang XP', v = tostring(o.xp) } end
    end
    local line
    if rel == 'own' then
        line = ('%s is ours: %s of ground.'):format(t.name, km(t.areaKm2))
    elseif not t.owner then
        line = ('%s has no owner. %s of ground.'):format(t.name, km(t.areaKm2))
    elseif rel == 'rival' then
        line = ('%s belongs to %s. Remember that.'):format(t.name, t.ownerLabel or 'someone')
    else
        line = ('%s belongs to %s. Everyone around here knows it.'):format(t.name, t.ownerLabel or 'someone')
    end
    return { line = line, facts = facts, options = { BACK, { id = 'leave', label = 'That is all.' } } }
end

-- "How is the family doing?": the owning gang's own numbers (insiders only; the server sends none to anyone else)
local function nodeGang(ctx)
    local o = ctx.owner
    if not (inside(ctx) and o) then
        return { line = refusal(), options = { BACK, { id = 'leave', label = 'Never mind.' } } }
    end
    local facts = {
        { k = 'Territories', v = tostring(o.count or 1) },
        { k = 'Land held', v = km(o.areaKm2) },
    }
    if o.xp then facts[#facts + 1] = { k = 'Gang XP', v = tostring(o.xp) } end
    local line
    if (o.count or 1) > 1 then
        line = ('We hold %d territories. People notice that.'):format(o.count)
    else
        line = ('%s is all we hold for now. Make it count.'):format(ctx.t.name)
    end
    return { line = line, facts = facts, options = { BACK, { id = 'leave', label = 'Good to know.' } } }
end

local function nodeTrouble(ctx)
    local tr = ctx.trouble
    if not tr then
        local line
        if not ctx.t.owner then line = 'There is nothing to report: nobody holds this ground.'
        else line = refusal() end
        return { line = line, options = { BACK, { id = 'leave', label = 'Never mind.' } } }
    end
    local facts = {}
    for i, e in ipairs(tr.open) do
        if i > 4 then break end
        facts[#facts + 1] = { k = e.here and 'On this ground' or 'Challenge', v = openLine(e) }
    end
    if #tr.open > 4 then facts[#facts + 1] = { k = 'And', v = ('%d more'):format(#tr.open - 4) } end
    if #tr.touching > 0 then facts[#facts + 1] = { k = 'On our border', v = table.concat(tr.touching, ', ') } end
    local line
    if #facts == 0 then
        line = oneOf({ 'Quiet. No challenge is open and nobody is pushing on our border.', 'Nothing. Not a whisper, not a challenge. Enjoy it.' }, 1)
    elseif ctx.t.busy then
        line = ('There is a war on %s right now. That is the trouble.'):format(ctx.t.name)
    else
        line = 'This is what I am watching.'
    end
    return { line = line, facts = facts, options = { BACK, { id = 'leave', label = 'Thanks.' } } }
end

-- "What should I be doing?": advice built only from what is true right now
local function nodeAdvice(ctx)
    local tr, o = ctx.trouble, ctx.owner
    if not (inside(ctx) and tr) then
        return { line = refusal(), options = { BACK, { id = 'leave', label = 'Never mind.' } } }
    end
    local tips = {}
    for _, e in ipairs(tr.open) do
        if e.status == 'SCHEDULED' and e.at then tips[#tips + 1] = { k = 'War booked', v = ('%s vs %s at %s. Be there, everyone.'):format(e.attacker or '?', e.defender or '?', e.at) }
        elseif e.status == 'ACTIVE' then tips[#tips + 1] = { k = 'War now', v = 'It is happening. Get to the fight.' }
        elseif e.status == 'PENDING' then tips[#tips + 1] = { k = 'Challenge', v = ('%s vs %s is waiting for an answer.'):format(e.attacker or '?', e.defender or '?') }
        elseif e.status == 'ACCEPTED' then tips[#tips + 1] = { k = 'Challenge', v = 'Accepted, waiting for staff to set a date.' } end
        if #tips >= 3 then break end
    end
    if #tr.touching > 0 and #tips < 4 then tips[#tips + 1] = { k = 'Border', v = ('%s is next to us. Watch the edges.'):format(table.concat(tr.touching, ', ')) } end
    if o and o.xp and o.xp > 0 and #tips < 4 then tips[#tips + 1] = { k = 'Gang XP', v = ('%s in the bank: paint more ground from the tablet.'):format(tostring(o.xp)) } end
    local line
    if #tips == 0 then line = 'Nothing pressing. Run events, bank the XP, keep our people sharp.'
    else line = 'Here is what matters right now.' end
    return { line = line, facts = tips, options = { BACK, { id = 'leave', label = 'Understood.' } } }
end

-- how ground changes hands, from the real settings (public: it is how the server works, not a secret)
local function nodeTake(ctx)
    local war = tcfg().war or {}
    local loot = war.postWarLoot or {}
    local cap = (war.capture or {}).seconds
    local facts = {
        { k = 'Auction', v = 'Staff put ground up for auction: the highest bid wins it.' },
        { k = 'Challenge', v = 'A gang leader challenges a rival gang from the tablet; staff set the date.' },
    }
    if cap then facts[#facts + 1] = { k = 'The fight', v = ('Attackers must hold the leader for %d seconds.'):format(cap) } end
    if loot.lootXpPercent then
        facts[#facts + 1] = { k = 'The spoils', v = ('The winner loots %d%% of the loser\'s Gang XP and the loser loses %d%% of their painted land.'):format(loot.lootXpPercent, loot.zoneShrinkPercent or 0) }
    end
    local line
    if ctx.me.relation == 'rival' then line = 'You want to know how to take this from us? Fine, it is no secret.'
    elseif not ctx.t.owner then line = 'Unclaimed ground goes to auction. Here is how it all works.'
    else line = 'Ground only changes hands two ways. Here they are.' end
    return { line = line, facts = facts, options = { BACK, { id = 'leave', label = 'Got it.' } } }
end

-- a rival asking about the challenge that is already open between the two gangs
local function nodeBetween(ctx)
    local list = ctx.between or {}
    if #list == 0 then return nodeTake(ctx) end
    local facts = {}
    for i, e in ipairs(list) do
        if i > 3 then break end
        facts[#facts + 1] = { k = e.here and 'Over this ground' or 'Challenge', v = openLine(e) }
    end
    local e = list[1]
    local line
    if e.status == 'ACTIVE' then line = 'It is on. Do not stand around talking.'
    elseif e.status == 'SCHEDULED' and e.at then line = ('We will see you at %s. Bring everyone you have.'):format(e.at)
    elseif e.status == 'PENDING' then line = 'The challenge has not been answered yet. That is between our leaders.'
    else line = 'It is accepted. Now we wait for staff to name the day.' end
    return { line = line, facts = facts, options = { BACK, { id = 'leave', label = 'See you there.' } } }
end

local function nodeJoin(ctx)
    return {
        line = 'Gangs take people in through their own leaders. Find a leader, earn some trust. It will not come from me.',
        facts = {}, options = { BACK, { id = 'leave', label = 'Fair enough.' } },
    }
end

local NODES = { root = nodeRoot, territory = nodeTerritory, trouble = nodeTrouble, gang = nodeGang, advice = nodeAdvice, take = nodeTake, between = nodeBetween, join = nodeJoin }

-- ── the panel ─────────────────────────────────────────────────────────────────────────────────────────────────────

local function speaker(ctx)
    local t = ctx.t
    return {
        label = t.owner and ((t.ownerLabel or t.owner) .. ' leader') or 'Territory contact',
        sub = t.name,
        color = t.ownerAccent or t.color,
        logo = t.ownerLogo,
        gang = t.ownerLabel,
        staff = ctx.me.staff and ctx.me.relation ~= 'own' or false,
    }
end

local function show(id)
    if not session then return end
    local build = NODES[id] or nodeRoot
    local node = build(session.ctx)
    session.node = id
    gesture(session.ped, session.ctx.me.relation, id == 'trouble' and not session.ctx.trouble and 'gesture_displeased' or nil)
    SendNUIMessage({
        action = 'leaderTalk:show', speaker = speaker(session.ctx), line = node.line, facts = node.facts or {}, options = node.options or {},
        node = id,
    })
end

local function close()
    local s = session
    if not s then return end
    session = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'leaderTalk:close' })
    backToPost(s.ped, s.heading)
end

function LeaderTalk.busy() return session ~= nil end

local function fetch(territoryId)
    local ctx = lib.callback.await('nova_convoytruck:territory:leaderTalk', false, territoryId)
    if type(ctx) ~= 'table' or not ctx.ok then return nil end
    return ctx
end

function LeaderTalk.open(ped, territoryId, topic)
    if session or not enabled() or not (ped and DoesEntityExist(ped)) then return end
    CreateThread(function()
        local ctx = fetch(territoryId)
        if not ctx then say('error', 'Gang Leader', 'They have nothing to say to you right now.') return end
        if session or not DoesEntityExist(ped) then return end
        session = { ped = ped, territoryId = territoryId, ctx = ctx, heading = GetEntityHeading(ped), seed = GetGameTimer() % 97 }
        faceEachOther(ped)
        if not session then return end
        SetNuiFocus(true, true)
        show(NODES[topic] and topic or 'root')
    end)
end

function LeaderTalk.respect(ped, territoryId)
    if session or not enabled() or not (ped and DoesEntityExist(ped)) then return end
    CreateThread(function()
        local ctx = fetch(territoryId)
        if not ctx or session or not DoesEntityExist(ped) then return end
        local heading = GetEntityHeading(ped)
        session = { ped = ped, territoryId = territoryId, ctx = ctx, heading = heading, quiet = true }   -- blocks a second prompt while the gesture plays
        faceEachOther(ped)
        local me = PlayerPedId()
        if session and session.quiet then
            local rel = ctx.me.relation
            if dictReady('anim@mp_player_intincarsalutestd@ds@') then
                TaskPlayAnim(me, 'anim@mp_player_intincarsalutestd@ds@', 'idle_a', 8.0, -8.0, 2600, 49, 0.0, false, false, false)
            elseif dictReady('mp_common') then
                TaskPlayAnim(me, 'mp_common', 'givetake1_a', 8.0, -8.0, 2200, 48, 0.0, false, false, false)
            end
            gesture(ped, rel, rel == 'own' and 'gesture_nod_yes_soft' or (rel == 'rival' and 'gesture_displeased' or 'gesture_nod_yes_soft'))
            local t, gang = ctx.t, ctx.t.ownerLabel or 'the gang'
            local line
            if rel == 'own' then line = 'Respect. Good to see you looking after the family.'
            elseif rel == 'rival' then line = ('%s noticed. Do not mistake manners for weakness.'):format(gang)
            elseif rel == 'outsider' then line = 'Respect noted. Now keep walking.'
            else line = ('Nobody to answer you here. %s has no owner.'):format(t.name) end
            Wait(1200)
            say(rel == 'rival' and 'inform' or 'success', ctx.t.owner and ((ctx.t.ownerLabel or ctx.t.owner) .. ' leader') or 'Gang Leader', line)
            Wait(1600)
            ClearPedTasks(me)
        end
        if session and session.quiet then session = nil; backToPost(ped, heading) end
    end)
end

-- ── NUI + safety ──────────────────────────────────────────────────────────────────────────────────────────────────

RegisterNUICallback('leaderTalk:pick', function(data, cb)
    cb('ok')
    if not session or type(data) ~= 'table' then return end
    if data.id == 'leave' then close() return end
    if NODES[data.id] then show(data.id) end
end)

RegisterNUICallback('leaderTalk:close', function(_, cb)
    cb('ok')
    close()
end)

-- the conversation ends by itself if the ped is gone (despawned / a war started), the player died, or they ended up far away
CreateThread(function()
    while true do
        if session and not session.quiet then
            local me = PlayerPedId()
            if not DoesEntityExist(session.ped) or IsEntityDead(me) or #(GetEntityCoords(me) - GetEntityCoords(session.ped)) > maxRange() + 4.0 then
                close()
            end
            Wait(250)
        else
            Wait(1000)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not session then return end
    SetNuiFocus(false, false)
    local ped = session.ped
    session = nil
    if ped and DoesEntityExist(ped) then FreezeEntityPosition(ped, true) end
end)
