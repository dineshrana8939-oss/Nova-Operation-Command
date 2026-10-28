<!--
  USER GUIDE — this file is the text of the tablet's "User Guide" tab.
  Edit it freely: save the file and reopen the Guide tab in the tablet (or press Reload). No restart and no rebuild needed.
  Three lines are filled in from the code itself, so they never go out of date: @tabs (the sidebar), @eventtypes (the
  Create Event types) and @commands (every command the script registers that this text does not mention).

  Each topic starts with "# Title" followed by id / group / icon / tag lines. Then:
    plain text          a paragraph               **bold**  `code`
    ## Heading          a small heading
    1. step             a numbered list           - item   a bullet list
    | a | b |           a table (the second line is |---|---|)
    > tip: text         a blue tip                > warn: text   a yellow warning
    @facts … @end       the "at a glance" box, one "Label :: text" per line
    @cards … @end       clickable cards, one "topic-id | Title | text" per line

  {{name}} is filled in from config.lua, so commands, keys and numbers here always match your config (a change to
  config.lua shows after the resource restarts). Names you can use:
    tabletCmd tabletKey statusCmd statusKey raceStartCmd soundTestCmd maxGang maxPolice deliveryRadius startDelay
    preSchedule hcSearchRadius hcBreakdownPct hcMaxSpeed raceTokensText raceRemindersText raceGridRadius raceGridWait
    raceFinishWindow tdmHp tdmPrep tdmRespawn tdmInvuln cwCountdown antiSnipeTrigger antiSnipeExtend lockText
    policeJobsText splitXpText
-->

# What this script does
id: welcome
group: Start here
icon: grid
tag: The big picture, in one page

Operations Hub is a complete live-event system for a roleplay server. From one tablet, an admin creates and runs eight different kinds of events. Players take part as police, gang members or civilians, and the script looks after everything around the event: announcements, rewards, gang XP, leaderboards, reports and logs.

## The eight events

@cards
convoy | Escort Convoy | Police escort armored cargo trucks along a route while gangs try to stop them.
hotcargo | Hot Cargo Run | Gangs hunt and hijack contraband trucks and deliver them before police catch them.
airdrop | Gang Airdrop | A plane drops loot crates by parachute; gangs fight for them.
race | Rally Race | A street race with checkpoints; the finishing position pays race tokens.
tdm | TDM Match | Two gangs fight a team deathmatch in an arena, or a tournament bracket.
containerwars | Container Wars | A harbour yard where a crane lifts containers and gangs bid for them.
territory | Territory Auction | Gangs bid for map territory, grow it with XP and fight rival wars over it.
crackdown | Operation Crackdown | One gang against the police on duty, inside a combat zone.
@end

## What sits around the events

@cards
police | Police alerts | Which events tell police, when, and how. See it in one table.
practice | Practice Range | A private aim-training area for a gang member or a whole squad.
gangs | Gangs, XP & leaderboards | Gang rosters, permissions, the Gang XP ledger and the standings.
announcements | Announcements, sounds & reports | Banners, audio cues, scheduling, Discord logs and PDF after-action reports.
peds | Peds & placing things | Vendors and event peds, and how to place them with a hologram.
@end

> tip: New here? Read "Your first event in 6 steps", then the page of the event you want to run. Every event page follows the same layout: what it is, who takes part, how it plays out, what you set up, and what it needs.

# What you need installed
id: requirements
group: Start here
icon: gear
tag: Resources, items and database

The script detects your framework, inventory and banking automatically when it starts. Nothing needs to be switched on by hand unless you want a non-default setup.

| Resource | Needed? | Used for |
|---|---|---|
| qbx_core, qb-core or es_extended | One of them | Players, jobs, money and gangs. Detected automatically. |
| ox_lib | Required | Callbacks, notifications and menus. |
| oxmysql | Required | The database. The script creates its own tables the first time it starts. |
| ox_target | Required for peds and objects | Talking to vendors and peds, opening crates, capturing territory. |
| ox_inventory | Recommended | Item rewards and the loot stash. Fully tested. qb-inventory, ps-inventory and qs-inventory work too, but are less tested. |
| Renewed-Banking | Optional | Bank statement entries. Without it the framework's own bank balance is used. |
| qbx_vehiclekeys and qbx_vehicles | Optional, detected | Keys and garage records for reward and token cars. Other key or garage scripts can be wired in through bridge/vehicles/custom.lua. |

## Server artifact and game build
The script runs on any recent FXServer artifact (Lua 5.4 needs artifact 4752 or later, and OneSync must be on because trucks, peds and props are created by the server) and on any game build. When the resource starts, the server console prints the artifact, the enforced game build and OneSync, and warns about anything missing. Things that depend on the game build have fallbacks: if the auction projector model (Config.Territory.auction.projectorModel, a Cayo Perico prop that needs game build 2189 or later) is not in your build, the models in projectorModelFallbacks are tried in order and the last one is in every build; the prop placer does the same when it creates the projector; the outline of selected props (a native some builds lack) is switched off by itself and the coloured boxes still show the selection. The tablet is built for the game browser of recent artifacts, and for older ones every colour that uses a newer CSS function has a plain fallback, so nothing disappears.

## Inventory items to create

- lockpick: used on Hot Cargo trucks, broken-down trucks, loot crates and airdrop crates.
- race_token: what Rally Races pay and the token vendor takes.
- event_status_tablet: optional. Using it opens the Event Status panel (see Config.StatusPanelItem).
- Any item you choose as an event reward must also exist in your inventory.

> warn: If the database is offline while the server starts, saved events will not load. Start the database first, then restart this resource.

> tip: Custom (addon) vehicles: put the model in stream/ and follow ADDON_VEHICLES.md. A car that players will own (rewards, race tokens) must also be added to qbx_core's shared vehicles, or the garage script cannot store it.

# Your first event in 6 steps
id: first-steps
group: Start here
icon: play
tag: From a fresh install to a running event

1. Make yourself an admin. Give your account the "admin" ACE permission, or add your identifier to Config.CreatorAccess.adminIdentifiers in config.lua.
2. Open the tablet with {{tabletCmd}} (key {{tabletKey}}). The menu across the top lists everything you can do.
3. Create your gangs in Gang Management (if Config.GangProvider is "internal"), or point the script at your framework's gangs. Gangs are who events pay and who competes.
4. Place the permanent peds in World Peds (the race token vendor and the practice range instructor), so they exist before any event does.
5. Open Create Event, choose the event type, fill in its tabs and press Save. Each event type has its own tabs, described on its page in this guide.
6. Go to Manage Events and start it, or give it a date and time and let the scheduler start it. Players get announcement banners before and during the event, and rewards are paid when it ends.

> tip: Saved Routes lets you reuse a convoy route you have already built. Event History keeps every finished event with its results and an after-action report.

## Event types you can create (read from the tablet)

@eventtypes

# Who can do what
id: roles
group: Start here
icon: shield
tag: Admin, police, staff and players

| Who | How they get it | What they can open |
|---|---|---|
| Admin | The "admin" ACE permission, or an identifier in Config.CreatorAccess.adminIdentifiers | Everything in the Operations Hub, including Settings. |
| Police | A job listed in Config.CreatorAccess.jobs ({{policeJobsText}}, at the grades set there) | Dashboard, Create Event (Escort Convoy only), Manage Events, Saved Routes, Event History and Active Participants. |
| Staff | An admin adds them in Staff Management and gives them a role | Only the tabs and actions their role (plus any personal overrides) allows (below). Being in a gang changes nothing about this. |
| Gang member | Being in a gang | The Event Status panel, their gang's tools and the territory map. They do not open the Operations Hub. |
| Civilian | No gang, no police job | Events marked "Open to Everyone" through the registration ped. They never see staff tabs. |

## Staff, roles and permissions (Staff Management)

Open Staff Management in the menu (System). It has three tabs: **Staffs** (everyone with access, with search and filters), **Roles** (roles and their permissions) and **Activity** (who changed what, and when).

1. Press Add Staff, pick an online player and a role. Adding staff never changes the player's gang, job, rank or faction.
2. Edit a person to change their role, or to override single permissions. An override either grants one permission the role lacks or takes one away; everything else follows the role.
3. Use the switch to disable someone temporarily, Revoke access to take the Admin Tablet away (their record is kept so you can grant it again), or Remove to delete them from the staff list. None of these touch the player's character or gang.

| Default role | For |
|---|---|
| Owner | Everything, including Staff Management. Protected: it cannot be edited or deleted, and the last active Owner can never be removed, disabled or demoted. |
| Administrator | Every section except Staff Management and the scheduling settings. |
| Moderator | Runs Convoy events, reads history, posts announcements and reads the leaderboards. |

You can create, rename, edit and delete your own roles. Before deleting a role that people still use, you choose another role to move them to.

Every section lists only the permissions that apply to it:

| Permission | Means |
|---|---|
| Visible | The section appears in the menu. A hidden section cannot be opened any other way either. |
| View | Open the section and read it. |
| Create | Add new records or start supported actions. |
| Edit | Change existing records. |
| Delete | Remove records. |
| Manage | The privileged actions of that section, such as starting events or changing gang members (the hint under each section says exactly what). |

Turning any action on also turns on Visible and View; turning View off removes the rest. Plain Convoy events need Create Event → Create; every other event kind also needs Create Event → Manage.

The rules that keep this safe, all enforced on the server and not only in the tablet:

- You can only give someone permissions you hold yourself, and you cannot change your own access.
- Only an Owner or a real server administrator can change an Owner or hand out the Owner role.
- Real server administrators (the "admin" ACE permission, or an identifier in Config.CreatorAccess.adminIdentifiers) always keep full access and are not part of this list, so the server can never lock everyone out.
- Police keep their escort-convoy tools through their job, and any staff role is added on top.
- A change reaches an online person at once: sections appear or disappear on their tablet, and the tablet closes if their access was revoked.

> warn: An admin who also leads a gang cannot add or remove Gang XP for any gang. The server enforces this to avoid a conflict of interest.

# The two tablets
id: tablets
group: Start here
icon: list
tag: Operations Hub and Event Status

|  | Operations Hub | Event Status |
|---|---|---|
| Who uses it | Admins, police and staff | Gang members and police |
| Open it with | {{tabletCmd}} or {{tabletKey}} | {{statusCmd}}, {{statusKey}}, or the event_status_tablet item |
| What it is for | Creating, running and reviewing events; managing gangs, peds, banners and territory | Seeing live events, your gang's roster and permissions, the territory map, Gang XP and rival wars |

The window titles and badges can be renamed in Config.Branding, so the tablet carries your server's name.

> tip: In the Operations Hub Settings, Staff tag over my head puts a small ADMIN tag (admins) or EVENT STAFF tag (members of the Staff Management list) floating over your head for the players near you. Only you switch it, it is remembered on this computer and comes back when you join, and the server decides which tag you may wear.
> tip: Both windows have a Settings tab with Appearance and UI Click Sounds. There are three themes, all dark, flat and rectangular: Black + White (white buttons, black button text), Black + Blue (blue buttons, white text, the default) and Black + Gold (gold buttons, black text). Pick one, look at the live preview, then press Apply Theme. Reset to Default restores Black + Blue. The same colours mean the same thing everywhere: green creates or confirms, blue edits or views, red deletes, grey cancels or goes back. Each window keeps its own theme and its own click-sound switch, saved in that player's game browser, so the Operations Hub and Event Status can differ. The crosshair editor, the registration window and the vendor shops follow the Event Status theme. In Event Status, Settings also has a Custom Crosshair switch (your own saved crosshair, TDM and Practice Range only) and a Guide tab written for gang players.

> tip: Who registers for what (Event Status, Events tab). Hot Cargo, Gang Airdrop and Operation Crackdown have no registration at all: the table says "Open to everyone" and shows no Register button. A Container Wars event or a race set to "Open to Everyone" also needs no gang sign-up (civilians and everyone else register at the registration ped), so it shows "Open to everyone" too; the Register button only appears when the event is for gangs. Container Wars (for gangs) and the Territory Auction are registered by the gang as a whole (Register Gang / Unregister Gang, one click). Convoys, Rally Races and TDM matches use a roster: the leader picks the members who take part.

> tip: Notifications (roster, rewards, warnings...) appear as small cards in the top-right corner, coloured by the event they are about (Config.Notify changes the corner, how many show at once, or switches back to the standard ones).

> tip: The team health panel can be hidden with X, shown with L and moved with ; (then drag it, Esc or Lock to finish). If a key is taken by another script, use the chat commands /hudhide, /hudshow and /hudmove. /drivebycheck prints why drive-by is or is not available in the vehicle you are sitting in.

> tip: Debugging events (admins, in game). /convoydebug draws a convoy's route and why each truck is or is not moving. /eventdebug does the same kind of job for every other event: it watches Hot Cargo, Gang Airdrop, Rally, TDM, tournaments, Container Wars, Territory Auctions and Rival Wars (phase, timers, scores, players online, a warning when an event stops progressing) and prints into your F8 console. /eventdebug check runs a pre-flight check of every event's set-up (zone drawn, spawns placed, vendors, both gangs exist and have a roster, routes complete) so you can find problems without needing other players; /eventdebug check <id> checks one event, /eventdebug status prints a single snapshot, /eventdebug off stops watching. Config.EventDebug and Config.ConvoyDebug in config.lua rename or turn these off.

> tip: Several characters. The Event Status (gang) panel, gang roster actions and the police escort actions follow the character you are playing: a medic character cannot open the gang panel, and a gang member who also works an ON-DUTY government job (police, EMS, fire, DOJ... see Config.StatusPanel.govJobs) gets a government view of it: no gang tabs or gang tools, and only the Convoy, Rally Race and Container Wars events are listed (a leader can take their gang role away; going off duty gives the gang tabs back; Config.StatusPanel.govBlockOpen = true refuses to open it instead), and switching character clears the forced drive-by, the NPC-hostile gang group and any open tablet. Police and administrators open a convoy truck's cargo stash without a lockpick (Config.CapturedTruckLoot.policeBypass), and a running convoy truck shows them an "Inspect Truck Cargo" target prompt (Config.CapturedTruckLoot.inspectLiveTrucks) so they can look inside without disabling it first. In the truck editor, "Cruise Speed" is set in km/h (the multiplier is worked out for you). The NPC driver holds its lane and drives point to point (Config.TruckLaneDiscipline), trucks are delivered close to the destination marker (Config.DeliveryRadius / DeliveryNearRadius), and every delivery shows a "Truck Delivered 1/3" banner to police, gangs and admins. When any event ends or is force-ended, all of its trucks, trailers, crates, props and NPCs are removed (a delivered Hot Cargo reward crate stays for its 60-minute protection window unless the event is force-ended).

> tip: Performance. The script sleeps when nothing is running: its watchers check the server's 'an event is running' flag and idle for seconds otherwise, so resmon shows 0.00 ms with no event active.

# Escort Convoy
id: convoy
group: Events
icon: truck
tag: Police escort armored trucks; gangs try to stop them

A convoy of armored cargo trucks drives a route from a start point to a destination, with NPC drivers. Police escort it and protect it. Gangs ambush it, disable trucks, loot them and try to stop the delivery.

@facts
Who takes part :: Police (the escort) and gangs (the ambush). Up to {{maxPolice}} police and {{maxGang}} gang players. Police are joined automatically when the convoy starts (or when they come on duty during it): there is no sign-up. Gangs register through the Event Status panel.
You set up :: Route and checkpoints, the trucks and their health, the destination, the vendor peds, rewards, and when it starts.
It needs :: A police job in Config.CreatorAccess.jobs, ox_target, and an inventory for loot and item rewards.
Rewards :: Cash, items, vehicles or Gang XP, paid when the event ends.
Configure :: config.lua, Section 3 (Escort Route, Checkpoints, Barricades & Stash Loot).
@end

## How it plays out

1. The event is started by an admin or the scheduler. Banners warn players first (the start delay is {{startDelay}} by default).
2. The trucks spawn and follow the route with NPC drivers. Only police (and admins) may take a truck's driver seat.
3. The convoy only keeps moving while a police escort is within 150 m of the trucks. If nobody is near, a "Convoy Halted" banner goes out to everyone and the trucks stop until an officer gets close again ("Convoy Resuming"). An event can switch this rule off.
3b. The NPC trucks follow the route you built, exactly. By default (Config.TruckRouteFollowing = ROUTE) a truck is never left to the game's road network, which at a ramp, a split carriageway or a slip lane picks its own road. It drives to a point a short way down your drawn line and on to the next one before it arrives, so it stays on the line you drew through ramps, left and right lanes and diverts. Draw the route points along the lane the trucks should use. Trucks still brake for traffic and steer round blockers. AUTO, EXACT and ROADS are still available (see config.lua).
3d. A truck that wanders more than 120 m off the drawn route is put back on it (Config.RouteRecoveryDistance, 0 = off).
3c. The script never moves a convoy truck: no teleporting it back onto the route, no sliding it along, no nudging it. A truck that gets stuck is helped by its own driver (it re-plans, backs up a little and drives on). Config.TruckScriptMoves = true brings the old emergency helpers back. A truck that nobody is near is not simulated by the game, so it waits until a player comes within range (Config.TruckCullingRadius keeps trucks streamed from a long way off).
4. Police have to go through every stage: the hold timer of a checkpoint only runs while at least one living on-duty officer is inside its circle (Config.CheckpointRelease.requirePoliceInCircle). If none is there the timer pauses and police are told to get into the zone. One box under the convoy clock at the top left shows trucks delivered, checkpoints cleared and route points crossed, with a row of stage boxes for every checkpoint and the destination (gold = done, blinking = current). A checkpoint starts as soon as the first truck is inside its circle (the yellow zone on the map). Every truck then slows down and settles onto the marker and is frozen there, and a truck a player is driving is slowed the same way even with the throttle held. The checkpoint timer only starts once EVERY cargo truck is on it: trucks that arrive first wait parked for the rest (police see "Waiting for the convoy" every 30 seconds), and destroyed, captured or disabled trucks no longer count. If a truck never arrives, the checkpoint starts anyway after the limit in Config.CheckpointRelease.arrivalWaitSeconds (600 seconds, 0 = wait with no limit). Then the convoy holds for {{cpWait}}. Police get "CHECKPOINT REACHED: start protecting the convoy". Gangs get "CONVOY HELD AT CHECKPOINT: intercept the trucks now!". A checkpoint can have NPC police or army guards, barricades and hostile ambush fighters.
5. When the hold ends, police get "Checkpoint Cleared" and gangs get "Convoy Moving Again". The trucks are released one at a time.
6. Gangs attack the trucks. A truck goes from healthy to damaged to critical to disabled. A disabled truck stops and participating gangs can loot it. A truck a gang captures is lost, and everyone is told, so police leave it and escort the rest.
7. Police can see the destination from the start. Gangs only learn where it is when a truck is within {{destWarn}} m of it: gangs get "Almost There" and police get "Nice Work: escort the trucks the rest of the way".
8. The convoy is delivered when the trucks reach the destination (delivery radius {{deliveryRadius}} m). An NPC-driven truck is delivered only when it has driven onto the destination mark and stands there for a couple of seconds: nothing delivers it before that, however close it got. A truck a police officer is driving is delivered by that officer pressing [E] at the drop zone. It fails if every cargo truck is lost (or the escort carries on, depending on the event's failure setting) or if the delivery timer runs out. When some of several cargo trucks were lost, two extra banners follow the result before "Convoy Event Concluded": how many trucks police actually delivered, then a congratulation to the gang(s) that took the rest and the rewards. A stand-down banner goes out and rewards are paid.

## What police see and are told

- The START and the DESTINATION point can be dressed like a checkpoint: in the route list their card has the same props / decoration vehicles (Prop Placer) and NPC police / army guards, without a name, radius or hold time (they are not checkpoints and are never counted as one). The start's dressing is built right when the event starts, the destination's when the convoy is two route points away; everything is removed when the event ends or is force-ended. Guards there only stand watch unless "NPC guards shoot non-police here" is switched on (it is on by default for checkpoints): then they open fire on anyone who is not on-duty police while that person is inside the point's circle (its radius), and stand down a few seconds after the last intruder leaves. The destination is also outlined with a red ring in the world (and a red circle on the tablet map), and so is a race's finish.
- Police always see the route ahead on the map (Config.PoliceAlwaysSeeRouteZones): drawn like a GTA Online race: every checkpoint stage and the next route points are light-yellow dots on the road (the checkpoint keeps its hold circle), the start and rest stops have their own marker and the destination is the checkered flag (Config.MapBlips.policeRoute). The checkpoint being held flashes instead of getting a second icon. The next route point flashes and carries a GPS line (Config.PoliceRouteBlips), so officers follow the route the convoy actually drives instead of cutting across town. Points the convoy has passed drop off the map. The NPC police and army support units show on the map to police only.
- Every on-duty officer is joined to the escort automatically and gets the truck blips. Gangs only see what they have discovered.
- Police are the ones the convoy waits for: without an escort nearby it stops.

## The peds that belong to a convoy

- Equipment Vendor: police buy smoke grenades and flashbangs.
- Escort Vehicle Shop: police check out a vehicle for the convoy. Free loaners, or paid and refunded when returned. It opens the vehicle showroom. Escort vehicles are not added to the player's garage. Each escort vehicle gets the convoy's "Escort Vehicle Health" (set in the convoy form, 1000 = a stock car), tyres that cannot be shot flat, a strong body and an armoured fuel tank. They have no health bar.
- Start ped: a police-gated ped that physically starts the convoy.

> tip: Build the route once and save it under Saved Routes. The route recorder lets you drive the route and drop checkpoints from the car. You place every ped with a hologram (see Peds & placing things).

> tip: Tick the boxes on route points (or on Saved Routes) and use Delete Selected to remove several at once. Numbers always renumber themselves: after you delete, add, insert or drag a route point, checkpoint, drop zone, spawn zone, dropoff or container, the automatic names (Checkpoint 1, Spawn Zone 02, Container #3 and so on) follow the new order with no gaps or repeats. A name you typed yourself is never changed.

# Hot Cargo Run
id: hotcargo
group: Events
icon: flame
tag: Hijack contraband trucks and deliver them

One or more contraband trucks are hidden around the map. Gangs search for them, pick the lock, hijack them and drive them to a drop-off. Police hunt the same trucks and try to stop them.

@facts
Who takes part :: Gangs (the thieves) against police.
Police :: Not told the event started and never shown the search areas. They are alerted only after a truck is hijacked (see below).
You set up :: The contraband vehicle, where each truck waits, the drop-off, the reward and the difficulty. Trucks and trailers are placed with an in-world placer.
It needs :: The lockpick item for gang players. Addon trucks need a streamed model.
Rewards :: The reward you set is the maximum. It is scaled by the truck's health on delivery, so a damaged truck pays less (switchable).
Configure :: config.lua, Section 4 (Hot Cargo Heist).
@end

## How it plays out

1. Gangs see a search circle ({{hcSearchRadius}} m by default) offset from each hidden truck, so they know the area and not the exact spot. A circle is also shown for any configured spawn zone that got no truck this run, so every area has to be checked. Police are not told the event has started and do not see these circles.
2. A gang player lockpicks the truck with a minigame. Cracking it hijacks it. A truck can be defended by NPC guards.
3. When a truck is hijacked a banner names the driver, the gang and the truck number. The driver is warned: "Contraband in motion! Police tracking activates in N seconds."
4. The stealth head start: the truck runs untracked for a set time (45 seconds by default, 0 to 600 per event). Then the police alert fires.
5. The police alert: every police player gets a chime, a "HOT CARGO ALERT: Cargo Truck #n has been hijacked by [gang]! GPS tracking enabled" banner, and the truck's live position on their map. The driver is told "Police have tracked the vehicle GPS! Incoming interceptors!". An event can switch the Police Alert off, and then police never hear about it.
6. The gang drives the truck to the drop-off. A hijacked truck is speed-limited so it drives like a heavy rig ({{hcMaxSpeed}} m/s by default).
7. At 25% health police and gangs both get a "TRUCK CRITICAL" banner and the driver is told to get ready to bail out. Heavy damage never blows the truck up: at {{hcBreakdownPct}}% health it breaks down (engine dead, locked, no longer deliverable) and can be lockpicked and looted where it stands. A banner says how many trucks are still out there.
8. A drop-off can be guarded by hostile NPCs. The truck cannot be delivered until they are dealt with ("Dropoff under hostile guard!").
9. Delivery pays the reward, scaled by the truck's remaining health.

> tip: To add your own truck, add its spawn name to Config.HotCargoTheft.vehicles. Tractor units such as the Hauler and Packer are spawned with their matching trailer automatically.

# Gang Airdrop
id: airdrop
group: Events
icon: parachute
tag: A plane drops crates; gangs fight for the loot

A cargo plane flies over a chosen zone and drops loot crates on parachutes, marked with flares. Armed NPC guards defend the landing area. Gangs race there, fight, open the crates and take the loot.

@facts
Who takes part :: Gangs, against each other and the NPC guards.
Police :: Never. This event is closed to police: they are not told, see nothing on the map, and cannot loot a crate.
You set up :: Which drop locations to use, how many crates, the loot, and when it happens.
It needs :: Config.Features.Airdrops switched on. Crates open with a minigame (lockpick or hack style).
Rewards :: Whatever you put in the crates: cash, items, vehicles or Gang XP.
Configure :: config.lua, Section 5 (Gang Airdrop Crates), under Config.Airdrop.predefinedLocations. All 25 preset San Andreas locations are listed there as vector3 coordinates; edit, remove or add rows freely.
@end

## Fixed spots or random spots

An airdrop event works in one of two ways, chosen by the **Rotate Spots Every Run** switch (Airdrop Zones tab, Runtime Randomization card):

| Switch | What a run does |
|---|---|
| Off (Fixed Locations) | Drops at exactly the zones you placed in the zone list, however many that is. Nothing is taken from the preset list, and the Drop Crate Quantity number is ignored. |
| On (Active Rotation) | Each time the event starts, the server picks Drop Crate Quantity of the zones you placed, at random and in a random order (never more than you have), and only those drop. Your zones are not changed or deleted, and a zone that was not picked does not drop and its props do not appear. |

> tip: The random picks are made fresh at every start and are never saved into the event, so switching the rotation off later brings back your own zones untouched.

## Changing the preset locations

The preset list lives in config.lua, under Config.Airdrop.predefinedLocations. Each row looks like this:

`{ id = 'loc_1', label = 'Sandy Shores Airfield Hangar', name = 'Sandy Shores Airfield', area = 'Sandy Shores', coords = vector3(1733.24, 3307.72, 41.22) }`

- To move a spot, change its vector3.
- To add a spot, copy a row, give it a new unique id and set its vector3.
- To remove a spot, delete its row.
- The list fills the zone list for you through the Auto-Add Zones and Generate buttons (Rotate Spots Every Run picks from your own zones, not from this list). Restart the resource after editing config.lua.

## Dressing a drop zone with props

Every zone card has a **Prop Placer** button (the number in brackets is how many props that zone holds). It opens the Prop Placer with the camera over that zone and the crate's landing spot marked, so you can add crates, barriers, tents, vehicles and other scenery around it. Save in the placer and the props are kept with that zone. The props appear when the event starts and are removed when it ends, the same as the props from the Props tab, which lists them too.

> tip: Props belong to the zone they were placed on. In a random run only the picked zones drop, and only their props appear. Deleting a zone deletes its props.

## Setting up the drop zones

- **Drop Crate Quantity** is how many of your zones drop in a randomised run (never more than you have). The Generate button replaces the zone list with that many random spots from the preset locations. With "Rotate Spots Every Run" off, every zone drops and this number is not used.
- **Main settings** (guards and rewards) belong to no zone. New zones start from them. Tick the zones you want and press Apply guards, Apply rewards or both: only the ticked zones change, and nothing keeps overwriting them afterwards, so each zone can still be customised on its own card. "Use Main guards / rewards" on a zone card resets just that zone. "Load Main from a zone" fills the Main settings from an existing zone.

## How it plays out

1. An admin starts the event (or the scheduler does). Each drop zone can have its own delay before it activates. Only gang members get the banners and map markers.
2. A banner announces "AIRDROP INCOMING" with the zone name, and a circle marks the zone on the map for gang members.
3. After a short lead time ({{airdropLead}} seconds by default, so gangs can get to the zone), a cargo plane flies straight over the zone. The moment it is directly above the zone's centre the crate is released on a parachute and falls onto the zone. Everyone within about 2.5 km of the zone sees the plane and the drop, and the plane also shows on the map for gang members.
4. At touchdown a "TOUCHDOWN" banner goes out and red smoke marks the crate.
5. {{airdropGuards}} armed NPC guards defend the crate by default. They are hostile to every gang, and their markers appear once you are inside the zone.
6. To open the crate a gang member needs a lockpick and wins a minigame. {{airdropLockpicks}} successful pick(s) are needed by default. A zone can instead be set not to need a lockpick: then one harder hack check opens it and the reward is guaranteed.
7. Opening the crate gives a shot at the reward, by the zone's chance (100% by default). The player sees "Jackpot" or "The crate is empty. Bad luck." The crate is used up either way, and the opener's gang is credited on the leaderboard for a win.
8. If nobody opens it, the crate and its circle disappear after {{airdropDuration}}.
9. When the event ends, a congratulations banner goes out for each gang that looted drops, most drops first. It names the gang and the drops it secured; rewards are not shown.

> tip: A lockpick only snaps after a set number of failed attempts, which depends on the event difficulty ({{lockText}} by default). Gang members share a crate's lock progress, so a teammate can carry on with their own pick.

# Rally Race
id: race
group: Events
icon: flag
tag: Street race with checkpoints and position tokens

A street race on a checkpoint route. Racers line up on a start grid, a 3-2-1-GO countdown runs, and the finishing position decides how many race tokens each racer earns. Tokens are traded at the Race Token Exchange for a vehicle.

@facts
Who takes part :: Gang racers, or everyone if the race is "Open to Everyone" (civilians register at the registration ped).
Police :: Hear nothing while the race is set up and run, and are alerted only after it ends (see the last step). An officer who wants to race joins at the registration ped, like a civilian (the Event Status panel is for gangs only), and then counts as a racer, not a pursuer.
You set up :: The route and checkpoints, the start grid, collision on or off, whether racers bring their own vehicle or use provided vehicles, and rewards.
It needs :: The race_token item, and for provided vehicles a vehicle ped for the race.
Rewards :: Race tokens by position ({{raceTokensText}}, by default), plus any other rewards.
Configure :: config.lua, Section 6 (Gang Rally Race).
@end

## How it plays out

1. When an admin presses Start, a pre-start wait begins if one is set (Pre-Start Countdown in the race form, or Config.RallyRace.startLeadSeconds). A server announcement says "The race starts in HH:MM:SS. Participants, be ready!" with reminders at {{raceRemindersText}} before the start, a live HH:MM:SS timer shows on screen, and the start zone blinks on the map and as a ring on the ground. Gang races show this to gang members and admins; a race open to everyone shows it to every player except on-duty police. With no wait set, the grid opens at once.
2. Racers get their ride, from their own garage or the race vehicle ped, and gather at the start.
3. The countdown starts by itself once everyone is within {{raceGridRadius}} m of the line, or after {{raceGridWait}} at most. Turn auto-start off to start it by hand with the Start Countdown button or {{raceStartCmd}}.
4. The first racer to finish starts a {{raceFinishWindow}}-second finish window; everyone else must finish in it for their position to count.
5. Each racer gets a finish banner with their place, time, race tokens and, for gang members, the Gang XP that position earns for their gang. The Gang XP itself is paid when the race concludes. A live standings tower shows the top racers during the race.
6. When the race is over, everyone involved gets an "event ended" banner naming the winner.
7. Only now are police alerted. Every police player gets "10-99: illegal race terminated, suspects fleeing" as a banner and a corner alert, and a blinking GPS marker appears at the finish line so they can start a pursuit.

## The Race Token Exchange

A permanent vendor ped (placed in World Peds, not tied to any race) opens a car showroom. A racer picks a vehicle and pays the tokens. The vehicle is created at a safe spot close to the vendor with the player seated in it, registered as their own, with keys, so they can park it in a garage and take it out later. The vehicle list and token prices are in Config.TokenVendor.

# TDM Match & Tournaments
id: tdm
group: Events
icon: crosshair
tag: Team deathmatch in an arena, or a bracket

Two gangs fight a team deathmatch inside a marked arena. Everybody is invincible for the whole match; kills come from a server-side virtual HP pool, so no ambulance or dispatch script ever reacts. The first side to the target wins.

@facts
Who takes part :: Two gangs.
Police :: Not involved. On-duty police never join a match, and because players are invincible nothing reaches dispatch.
You set up :: The match rules and rewards, the arena zone and team spawns (a red and a blue zone), the ped positions and the weapon shop.
It needs :: Money for the weapon shop (cash or bank), and a weapon item that exists in your inventory.
Rewards :: Cash, items and Gang XP for the winning gang.
Configure :: Config.TDM in config.lua, Section 7 (virtual HP, damage per weapon, respawn times and the weapon shop).
@end

## How it plays out

1. Both gangs gather; a prep countdown ({{tdmPrep}} seconds) runs before combat starts.
2. Each player has {{tdmHp}} virtual HP. Every hit takes the damage listed for that weapon in Config.TDM.weaponDamage. At 0 HP the player is down.
3. After {{tdmRespawn}} seconds the player respawns at their team spawn with {{tdmInvuln}} seconds of protection.

> tip: Team spawns. Draw a Base PolyZone Perimeter for each team (Match Setup, Team Respawn Points) and the script spreads that team INSIDE it, one spot each at least a couple of metres apart, instead of stacking players on one point. Preview in the perimeter row hides the tablet and shows the area with numbered gold dots, the spots where a team of the "players per team" size would stand (the server uses the same spots); Enter returns to the tablet. The recorded spawn dots (Record Red / Blue Spawns) are used only for a team with no perimeter, and their own Preview Spawns button shows them numbered in the world.
4. Each team has a weapon vendor ped at its base (red and blue). Players buy weapons there with cash or bank money.
5. The kill feed, a TAB scoreboard and a streak and multi-kill badge run during the match. Every time you eliminate an enemy, a "Kill Confirmed" skull emblem with your name and theirs pops up at the bottom centre of your screen. At the end a Victory, Defeat or Draw screen shows, then the full results.

6. After the match the screen shows the gang's logo and name with a big green WINS or red DEFEATED, and a card over the head of each of your team's best players (their name, rank, Gang XP earned, kills and deaths) that follows them in the world, for Config.TDM.outcomeSeconds seconds; then the results window opens. Everything comes from the server's own result.
7. The reward is shared by kills (Match Setup → Reward by Kills, defaults in Config.TDM.rewardScaling): every online member of the winning team is paid, the best killer the whole reward and the others at least the set lowest share, and the losing team gets a lower percentage by the same rule, so the best fighter of the losing side earns the most of it. A vehicle goes to the best killer of the winners. Switch it off and the winners all get the full reward and the losers nothing. A tournament counts kills over all its matches and pays the champion gang and then the other gangs when it ends.

## Tournaments

The Tournaments tab runs brackets of TDM matches: create the tournament, add gangs, shuffle and lock the draw, and report scores. Its table lists every tournament with its stage, gangs, groups and start; press Open on a row (or the row itself) to manage one. The next match is set up as an arena match and its players are sent there. Finished tournaments are kept under Tournament History.

The live tree has its own page, Tournament Tree (Tournaments menu). Pick any tournament from the row at the top (filter by Live, Upcoming or Completed) and the tree below redraws for it: the groups, the knockout bracket, the match on the arena now, the next match and the champion, with a progress bar of matches played. It refreshes by itself while the tournament is live. Open in Tournaments jumps to the same tournament where you can report scores, shuffle the draw and export. Gang members see the same tree, highlighted for their own gang, in the Tournaments tab of Event Status.

# Container Wars
id: containerwars
group: Events
icon: box
tag: A harbour yard, a crane and an auction

A harbour yard where a gantry crane lifts containers into view one at a time. Gangs bid for each container in a live auction. The winner collects what is inside: items, cash or a vehicle.

@facts
Who takes part :: Gangs bid. The gang registers as a whole in Event Status, Events tab (Register Gang, one click, no member list; the leader or a role with Register for Events does it); every member of a registered gang may bid, and a gang that did not register cannot (Config.AuctionRegistration.required = false turns that off). Civilians can take part too if the event is open to them (they register at the registration ped).
Police :: An officer can take part by registering at the registration ped, as a civilian bidder. They cannot join from the Event Status panel.
You set up :: The auction rules (starting bid, minimum raise, auction time), the timers and pacing (including the crane trip time and how fast the empty hook comes down onto a container and climbs back up after the drop), the bidding perimeter and the peds, and the lots with their rewards. The yard itself (crane, container spots, drop spots) is placed with holograms.
It needs :: Pickup spots for the yard (use /cwspot) and a yard layout. Vehicle rewards need keys and garage support.
Rewards :: Each lot has its own reward. A vehicle reward goes to the winner's garage, or is spawned beside the container if no garage is available.
Vehicle lots :: A lot whose only reward is a car shows a dummy crate in its container while it is auctioned. The car is created only after the winning bidder is confirmed. The winning bidder (nobody else) walks up to it and presses E within 120 seconds (Config.ContainerWars.vehicleClaim.seconds) to get the keys and the normal garage record. The countdown is kept by the server and shown on a bar at the top of the screen (/cwvehicle hides or shows it). If it is not claimed in time, even if the winner has left the server, the server puts the car in the winner garage and removes it from the container. A car that is still waiting when the resource restarts is put in the garage at the next start. A lot that also holds cash or items keeps the open-the-container flow.
Gang XP :: In Auction Lots, turn on "Gang XP for the winning gang of each container" and set the amount. Whenever a gang member wins a container's bidding, their gang earns that XP (car lots too), whether the event is gang-only or open to civilians. A civilian winner earns none. It is paid once per container per run, when the bid is settled.
Full inventory :: If a winner has no room for the items in a loot crate, what did not fit stays in the crate and they can search it again after making room (they are told so).
Harbour decor :: The decorative container stacks (Props tab) and the gantry cranes stand in the harbour only while a Container Wars event is running and are removed when it ends. Turn on Prop Spawn Mode in the Props tab to preview them in the world before an event; starting an event replaces the preview with the real ones, so nothing is doubled.
Configure :: config.lua, Section 2 (Container Wars). The setup form reads its defaults from there.
@end

## How it plays out

1. An admin starts the event; a banner counts down ({{cwCountdown}} seconds by default) before the crane moves.
2. The crane lifts a container and sets it in place. Bidding opens after a short pause.
3. Players bid from the bidder window on the left of the screen. A bid in the last {{antiSnipeTrigger}} seconds adds {{antiSnipeExtend}} seconds, so nobody can win by sniping at the last second.
4. The winner opens the container with the target prompt and receives the reward. The next lot starts after a short gap.
5. A round ends after its last container. The final container is announced as the FINAL ROUND. A yard of 4 spots can run several rounds of lots.

> tip: Use /carowner (admin) to hand a spawned reward car to the player who really won it, if it was created for someone else.

# Territory & Rival Wars
id: territory
group: Events
icon: pin
tag: Own map territory, grow it with XP, fight for it

Territory is the long game. Gangs earn Gang XP from every other event. A Territory Auction hands out the first territories. A gang grows a territory by painting land onto it, and every cell painted costs Gang XP, so the bigger the area, the more XP is taken. A gang can challenge any other gang, an admin schedules a war, and the winner of the war loots the loser's Gang XP and shrinks the loser's painted land. Nobody loses a territory in a war: owners change only through an auction or when an admin hands a territory over. Admins create territories and give them out; they never paint. The gangs colour in and maintain their own land.

@facts
Who takes part :: Gangs (online members, and admins who manage it). For the auction the gang registers as a whole in Event Status, Events tab (Register Gang, one click, no member list); every member of a registered gang may bid, and a gang that did not register cannot.
Police :: Cannot take part in the auction.
You set up :: The territories painted on the map (Map Zone), the auction (Territories, Projectors and Bidding & Anti-snipe tabs; the projector is the floating screen that shows the auction in the world), and the wars (Rival Wars & Challenges).
It needs :: Gang XP flowing from other events, and for the auction a projector spot (a prop placed with the prop placer).
Rewards :: Owning territory raises a gang's Territory Level, shown on the Gang Leaderboard.
Configure :: config.lua, Section 8. Every number there is a default; each event and war can override it in the tablet.
@end

## The cycle

1. Events pay Gang XP into each gang's account (see Gangs, XP & leaderboards).
2. A Territory Auction event sells the first territories to the highest bidders. The auction board is a hologram screen hanging over the projector (it is not drawn on your own screen): it shows the zone being bid on, a map of where it is, the bids and the countdown. Each zone that comes up flashes on the game map and the minimap with a big bright blip and a circle over its area, and a notice tells you to press F7 to open the map (the key can be changed in config.lua and in the game's key settings). Gang members stand in the auction zone, press E to open the bidder window and bid. Police cannot bid.
   Who can bid where: a gang member can bid only while standing INSIDE the bidding perimeter the admin drew in Auction Setup (the same area the server checks when the bid arrives). An event with no perimeter drawn falls back to a circle around the auction location. The projector is a real prop (a light tower by default) set on the ground; its beam lights the whole board from its lamp. A bid shows as a small tag over the bidder's head with the gang name and the amount.
   Talking to the leader: the leader ped offers four choices on the target key (Pay Respects, Speak to Leader, Ask About Territory, Ask About Trouble). Pay Respects plays a short gesture and the leader acknowledges it. The other three open a conversation panel on the left of the screen while the leader ped stays in view; press 1-9 or click to answer, Esc to walk away. You only turn to face the ped, you are never moved. What the leader says is read from the live game: who owns the territory, its land and XP value, whether a war is on. Members of the owning gang (and staff) also hear the inside picture: the gang's Gang XP, open challenges and war times, and rival gangs touching its border. A rival gang member gets only the public side plus how many wars the two gangs have fought; a player with no gang gets the public side. Turn it off with Config.Territory.leaderTalk.enabled = false. While the post-war loot option is available the talk choices are hidden.
   Leader ped tag: walk up to a territory's leader ped (within about 18 m) and a compact card floats over its head: a square in the owning gang colour, the gang name and its Gang XP (the XP is shown only to gang members and staff; everyone else sees the name). It is drawn on your screen only, and the XP is refreshed from the server at most every 20 seconds while you stand near.
   Projector prop: the auction projector is the model in Config.Territory.auction.projectorModel (default h4_prop_battle_lights_floor, the battle floor lights) whatever the Prop Placer saved; the placer only sets where it stands and which way it faces. The beam starts at the lamp, which is placed with lensOffset (metres in the prop's own frame); if the lamp of a tilted prop is not where the beam starts, use /projlens <x> <y> <z> in game and paste the printed line into the config.
   Screen size: on the Projectors tab, once the projector is placed, the Screen size slider (40%–300%) sets how big the auction board is drawn over it. The picture beside the slider shows the board to scale next to a 1.8 m person, and Preview Size In-World hides the tablet and draws the board at that size next to the projector for about 25 seconds so you can judge it standing there. The size is saved with the event and used when bidding starts.
   Auction starts in: once the auction event goes live, every player sees the same small countdown timer used by Container Wars ("AUCTION STARTS IN", with how many territories are up) for the length of the opening buffer (Intro / Buffer Before Bidding in Auction Setup). It disappears when bidding opens.
   Congratulations banner: when the auction ends (also when an admin closes it early) the winning gang members get their personal congratulation, and a small banner for the whole server names the new owners, for example \"Ballas: Davis Yard   •   Vagos: Pillbox\", just after the auction-concluded banner. Config.Territory.auction.congratulate = false turns both off.
   Auction ends in: while bidding runs, the same timer card shows how long the WHOLE auction has left ("AUCTION ENDS IN", with how many territories are sold, turning amber in the last 2 minutes). Auction Duration 0 means the default length (30 minutes), never a one-minute auction. When the time is up, or an admin force-ends it, the timer disappears for everyone; every territory already sold stays with the winning gang (the winners are congratulated), and only the lot being bid on at that moment is void.
3. Gangs grow a territory by painting. There are no expansion levels: a gang leader, or a member with the manage-gang role, paints extra land next to a territory the gang owns and pays Gang XP for each cell. The price per cell is set in config.lua (Config.Territory.paint) and an admin can change it live in the Map Zone (Expansion XP tab): it reaches every gang that can paint at once, and a gang that is painting sees the new price straight away. Land the gang painted can be rubbed out again with the eraser, and the XP for those cells goes straight back to the gang's balance (refunds do not count as newly earned lifetime XP). Erase from the outer edge inwards so the painted land always stays joined to the territory. A territory that staff created with no land yet is painted outwards from its leader ped.
4. A gang leader challenges any other gang's territory (it does not have to touch yours; touching ones are marked "Adjacent"). The war is fought on the smaller gang's own territory, so the challenged gang can be the side that attacks. A gang can have {{maxOpenChallenges}} challenges open, a repeat challenge on the same territory waits {{challengeCooldown}}, and an unanswered challenge lapses after {{challengeExpire}}.
5. When the other gang accepts, an admin schedules the war under Rival Wars & Challenges.

## How a war plays out

1. Both gangs get a "TERRITORY WAR SCHEDULED" banner, then reminders {{warReminders}} before the start. Both gangs are responsible for being there.
2. When it starts, a "TERRITORY WAR" banner goes out. A war lasts {{warMinutes}} minutes by default (an admin sets it, from 3 to 90).
3. A combat ring of {{ringRadius}} m marks the war zone. A player who leaves it has {{ringBuffer}} seconds to get back before being eliminated. Each player has one life: an eliminated or revived player cannot re-enter the ring.
   Rival Wars tab (Event Status): every gang member sees the invitations their gang received, their own open challenges and wars, and recent results. The gang leader (or a role with Manage Gang) accepts or declines an invitation; a box opens first where they can write a comment for the admins. That comment shows on the admin Rival Wars tab under that challenge (Manage), together with who answered, so staff can pick a good date.
   Admin side (Rival Wars → Manage): Teleport to leader ped puts you next to the leader ped of the battleground. Draw war zone sets the area the war is fought in: a circle (radius) or a square (half the side), with the centre set from the leader ped or from where you stand, the size typed or taken from your distance when you stand at the edge, and Preview in the world drawing it in green for about 30 seconds. The zone is saved with the challenge, is only drawn and enforced once that war starts (leaving it eliminates a fighter after the usual buffer) and replaces the round ring around the leader ped. Set War Date schedules the war and Start War Now starts it at once. Announce sends a banner (the same look as the other event announcements; Preview myself first) to the online members of the two gangs only.
4. Attackers hold the capture point (the leader ped, "Take Territory") for {{captureSeconds}} seconds. If a defender stands in the point, {{contestText}}. A "TERRITORY CONTESTED" banner goes out.
5. If the attackers finish the capture, they win the war. If the timer ends first, the side with more fighters in the zone wins, and a tie goes to the home gang. Either way a banner names the winner. Nobody loses a territory.
6. If nobody from either gang is alive in the territory when the timer ends, it is a no-show: the owner keeps the territory, but loses {{noShowText}} for not defending it (an admin can set a different amount for a war).
7. The winning gang then has {{lootWindow}} minutes to loot the leader ped. Only when they loot does anything move: the loser pays {{lootPercent}}% of its Gang XP to the winner, and the loser's own painted land (the coloured zone on the map) shrinks by {{shrinkPercent}}% from its outer edge. The loser keeps the territory itself, its owner and its ped. If nobody loots in time, nothing changes.
8. The same two gangs play for stakes only once every {{pairCooldownHours}} hours, so two friendly gangs cannot pass XP back and forth. A war inside that time is still fought, but it pays nothing.
9. A war whose start time passed while the server was offline does not start late: it goes back to Accepted and an admin schedules it again.

## Setting up territories (Create Event, Gang Territory Auction, Territories tab)

Every territory is one compact row: colour, name, starting owner, starting bid, and whether its Leader Ped is placed. You can add a whole map without opening a single row: press Add Territory, type the name, pick the owner and bid, then press the eye button on the row to place the Leader Ped with the hologram (the arrow button teleports you to a placed ped). Press Edit on a row only when you need the rest: the identity and bidding details, the war capture settings, the ped model, the colour and the map blip.

The Leader Ped is the gang boss NPC standing at the territory, and where you place him is where the territory is. That one spot is the map blip every player sees (sprite, name and owner), the war capture point (attackers talk to him and hold the capture radius around him), the spot the winning gang loots Gang XP from after a war, and the centre of the coloured ground ring.

## Admin tools (Territory → Map Zone tabs)

The Map Zone is one page for the whole territory system. Its pages are the row of tabs under the Territory menu: **Territory Map**, **Rival Wars**, **Auction Results**, **XP Log**, **Ownership Log**, **XP Rankings** and **Painting Price** (most-used first). Everything about one gang lives in Community → Gang Management. The admin Map Zone always shows the overview (territories, claimed, unclaimed, wars, top Gang XP): gang numbers such as "Your territories" or "Gang XP rank" belong to Event Status, even if you are in a gang yourself.

The Map tab gives the map the whole width and height; it grows with the window. Press Details (top right of the map) for the selected territory and the full list. Create Territory (above the map, admins only) is the one place to add a territory. The admin Map Zone is view-only for land: it shows which gangs hold how much (Land by gang) and never lets you paint. All painting is done by gangs in their own tablet (Event Status → Map Zone), paid in Gang XP. The gang tablet's map never shows Create Territory, even for an admin who is in a gang. To change the shape a territory STARTS with, edit it in the event (Create Event → Gang Territory Auction → Territories).

- Who sees war alerts: anyone with the Rival Wars & Challenges permission in Staff Management (View or Manage), not only full server admins. They get the "new challenge" and "challenge accepted" messages, a live war view with the ring and scores while a war is fought, and the live map updates. View is enough to watch; Manage is needed to schedule, start and cancel wars.
- Speed: the Map Zone only downloads a territory's painted land when it is new or has changed. Opening the tablet again, a new owner, a war starting or ending, or a gang changing its colour do not send the land again.
- Rival Wars page, Manage on a challenge: shows who challenged whom and where it is fought. An admin with the Rival Wars Manage permission can Accept or Decline a PENDING challenge on behalf of the challenged gang (both gangs are told an administrator did it), set the war date (on a pending challenge this accepts it first), Start War Now, or Cancel the challenge.
- Painting Price page: the Gang XP one painted cell costs and how many cells one save may add. Changing it applies to every gang that can paint, live. Use config.lua puts the config.lua value back. A calculator shows what an area costs at the current price. The change is posted to Discord.
- Gang Management (Community tab): one table of every gang (leader, members, online, Gang XP, territories, status) with a Manage button on each row. Manage opens that gang's own view, with the gang's name at the top and an All gangs button back, and these tabs: Members (roster, invite, promote, remove, ranks in use), Territory Control (the gang's own territory: change its owner, jump to it or delete it; or assign it a free one), Gang XP (an XP Overview page with rank, totals and the top earners, an XP History page with the full ledger, and an Add / Remove XP page; the gang is told why), Notices & Warnings (one page: pick Notice or Warning from the Type list and write the message every member sees) and Administration (name, logo, colour, member limit, participation and the one Disband gang button; with the territory permission it also tells the members and makes the gang's territories unclaimed or removes them). The gang stays the same while you switch tabs, so an action can never land on another gang. The XP Rankings page of the Territory tab lists every gang and every player by XP.
- Gang XP: add or remove XP. Removing needs a reason. The reason is shown to that gang in a banner (online members at once, others when they next log in) and is recorded in the XP history.
- A new territory has no land at all. Admins only place its marker and capture spot; the gang that owns it paints the land. A starting shape that an older event kept is ignored (it used to stay on the map wherever it had been drawn).
- Clear painted land (Map Zone, Details panel of the selected territory): wipes ALL the land of a territory, the old starting area and every cell the gangs painted. Staff never paint, this only takes stale land away; the owner keeps the territory and paints it again from the leader ped. When a territory is SOLD at an auction its land is wiped the same way (Config.Territory.auction.clearLandOnSale), so the winner starts clean.
- Manage the selected territory: hand it to another gang or take it away (Change owner), jump to it (Go there) or delete it. Both gangs are told by banner, and the map, colours and history change live. A territory cannot be moved while a war is running on it.

> tip: Banner colours: the territory auction is violet; everything about a rival challenge or war (challenge sent / accepted, war scheduled, reminders, contested, captured, defended) is royal blue with its own banner picture (Announcements → Event Banner Images → Gang Rivals; the file is images/event_announcement_banner_images/rivals.jpg). The picture, its framing and its Test HUD button work like every other event's.

> tip: Every player on the server sees each territory in the world: its map blip (sprite and "Territory - Owner" name), a coloured ground ring when near, and the leader ped standing there. Set Config.Territory.visibleTo to 'gangs' if only gang members and admins should see them. The painted land, Gang XP and the Map Zone tab stay gang and admin only.

> tip: On the map, a territory is painted in its owning gang's colour. Its logo is the territory's own logo if it has one, otherwise the owner's gang logo.

# Operation Crackdown
id: crackdown
group: Events
icon: shield
tag: One gang against the police on duty — last side standing

Operation Crackdown puts one target gang against the police inside a combat zone you draw on the map. It is a hard push from both sides, with no points: a fighter who goes down is eliminated from the operation. Nobody is assigned or teleported: the police are whoever has a police job and is on duty, the gang is the target gang's online members.

@facts
Who takes part :: The target gang (members who are there) and every police officer on duty, recognised automatically. Civilians and other gangs do not take part.
You set up :: Create Event, Operation Crackdown: Operation Setup (name, target gang, preparation time, duration), Combat Zone (a large map: circle or square zone, plus two start areas: a box for the gang and a box for the police, drawn in game with Draw Perimeter, Preview Here, Teleport & Preview and Clear, the same as the TDM zones), Rewards & Rules (time allowed outside the zone, minimum fighters, gang reward, police reward, Gang XP the gang loses if the police win). The announcement texts are built by the script (Config.Crackdown.messages in config.lua); there are no text boxes for them. Whoever wins, every fighter of the winning side who is still online is paid, including those who were eliminated; the banner for this event is images/event_announcement_banner_images/crackdown.jpg (changeable in Announcements → Event Banner Images).
It needs :: At least the minimum number of gang members and officers on duty when the preparation countdown ends, otherwise it ends as "no contest" and nobody is paid.
Rewards :: The winning side is paid its reward. If the police win, the target gang can also lose Gang XP. A draw or a cancelled operation pays nothing.
Configure :: config.lua, Config.Crackdown (the defaults the form starts from and the standard announcement texts). Each event can override them in the tablet.
@end

## How it plays out

1. Start it from Manage Events (or schedule it). The whole server gets the Operation Crackdown banner and the preparation countdown begins. Gang members and officers on duty see the HUD, the combat zone and the two start areas (the gang's box in orange, the police box in blue, in the world and on the map). The last ten seconds of the countdown are shown big in the middle of the screen.
2. When the countdown ends, the fighters standing inside their own side's start area are the roster; anyone outside it is told and left out (and is not paid). A side with no start area drawn is not restricted. The roster is then locked and the fight opens ("FIGHT!" is shown). Someone who arrives later does not join.
3. A fighter who dies or is downed is eliminated. They respawn or are revived by EMS like anyone else, but they are out of the operation and cannot shoot inside the zone any more. Nothing else is done to them.
4. A fighter who stays outside the zone gets the warning bar; if the time runs out they are eliminated too (nobody is killed or moved). A fighter who goes off duty or disconnects is eliminated after a minute.
5. The operation ends when one side has no fighters left: the other side wins. If the time is up first, the side with more fighters still standing wins; equal numbers are a draw.
6. The result banner goes to the server, the rewards are paid, and the operation is saved in Event History with its report (who survived, who was eliminated and how) and PDF, and posted to Discord.

> tip: Only one Operation Crackdown can run at a time. It cannot be test-run (it is fought between real players). Force End calls it off with no winner and no payout. If the server or the resource restarts while one is running, it is closed as cancelled automatically a few seconds after start.

> tip: The banner for this event uses the image images/event_announcement_banner_images/crackdown.jpg. Replace the file with another image of the same name, or change it in Announcements, Event Banner Images.

# Practice Range
id: practice
group: Systems
icon: crosshair
tag: Private aim training with bots

A gang member talks to the practice instructor ped, picks a training area and a weapon, optionally invites squadmates, and deploys. Everyone enters a private world with bots to fight. Nothing here touches the real economy or the real inventory.

@facts
Who uses it :: Gang members and admins. Not part of an event.
You set up :: Place the instructor in World Peds. Training areas, weapons, bot count and difficulty are in config.lua, Section 9.
It needs :: Nothing special. Weapons are given for the session only.
@end

## How it plays out

1. A gang member (or an admin) talks to the instructor ped and opens the Armory. They become the host of a new squad.
2. In the Armory the host picks a training area, and every squad member picks their own weapon.
3. The host can invite squadmates by character name or server ID. They get a prompt and accept or decline.
4. When the host presses Enter training area, the whole squad is moved into a private world. Nobody outside can see or reach them, and no police or dispatch script hears anything from the range.
5. Bots spawn around the players, from different directions, and attack in waves. Each kill is counted and shown in the kill feed. If a bot's fire empties the health bar, the player goes down for a few seconds and respawns with a full bar.
6. The session ends when the host ends it, or a player leaves at the exit marker. A results screen shows kills, deaths and points, for the squad's own interest only.

## Good to know

- Bots hold the same weapon the player chose, appear from different directions and attack in waves, not all at once.
- The health bar always shows 100, but there is more health behind it, so a session lasts longer than the number suggests (Config.PracticeRange.hiddenHealthMultiplier).
- The player's real inventory is locked during the session and nothing from it is removed.
- Players leave at the green exit marker, or with /endpractice (F6) which marks the way. They return next to the practice ped.
- If a player crashes or disconnects mid-session, they are moved back to the normal world and next to the practice ped the next time they log in.

# Gangs, XP & leaderboards
id: gangs
group: Systems
icon: users
tag: Who competes, what they earn, how they rank

Gangs are the teams that events pay and rank. With Config.GangProvider set to "internal" this script manages gangs itself (Gang Management tab). "framework" reads your framework's gangs, and "custom" lets you plug in your own through bridge/gangs/custom.lua.

## Gang roles and permissions

- A role is a rank name (Member, Captain ...) plus what it may do: **Manage Gang** (members, roles, logo) and **Register for Events** (sign the gang up and edit its event roster). Every gang has two built-in roles: **Leader** (only the gang leader holds it, it has every permission and cannot be edited, given to anyone else or reused as a name) and **Member** (the default every new member starts with; it cannot be renamed or deleted).
- A gang can add only a few roles of its own on top of those two (Config.GangRoles.maxCustomRoles, 5 by default), so the list cannot fill up with dozens. Both panels show "n of 5 own roles used" and the Create role button is disabled at the limit; delete a role to add another.
- Every gang member can SEE the roles and what each allows in Event Status → My Gang; only a role with Manage Gang can change them. If a tool is missing in Event Status (no Register buttons, no My Registrations), a yellow notice at the top says why: an on-duty government job, or the member's role not having "Register for Events".
- There is ONE list of roles per gang. The gang leader edits it in Event Status (My Gang); an admin edits it in Community → Gang Management → (the gang) → Roles & Permissions. Both panels read the same data and update live when either side changes something, so the two can never disagree.
- A member can only be given a role that exists: create the role first, then choose it for the member (Invite member, or the role picker in the Members tab). Without "Register for Events" a member sees no register buttons and no My Registrations tab in Event Status.
- A gang member who works an on-duty government job (police, EMS ...) gets no gang permissions until they are off duty.

## Gang XP

- Every event can pay Gang XP as a reward. {{splitXpText}} On-duty police never earn Gang XP.
- XP is spent on painting land to grow a territory (the price per cell is set under Territory → Map Zone → Expansion XP) and can be removed as a penalty.
- The XP history lists every change with its source, the reason and the player's in-game character name. Admin changes are recorded under the admin's character name with the reason you typed. It is on the Map Zone tab.

## Leaderboards

The Gang Leaderboard ranks gangs per event type (for example captures in Convoy, wins in Rally and TDM, containers won in Container Wars, completions in Hot Cargo and Airdrop). The Gang XP and territory standings are on the Map Zone. The Civilian Leaderboard ranks civilians who took part in events open to them. Both leaderboards are admin-only tabs unless a staff member has the Leaderboard Access permission.

## Adding members

Admins use Gang Management → the gang → Members → Invite Member: pick an online player from the list, or type their **server ID** (or name) in the "Or type a server ID" box, choose the rank and press Add. A gang leader (or a member with the manage-gang permission) does the same from Event Status → My Gang → Add Member, where one box takes a server ID or a name. Only players who are online, not in a gang and not on-duty police can be added; the server checks again when you press Add and tells you what is wrong. Every member added this way is also posted to Discord (see Discord logs).

## Participants

Active Participants lists who is registered for each event, with their in-game name and gang. You can filter by event type, status (draft, scheduled, active, completed) and gang.

# Police alerts at a glance
id: police
group: Systems
icon: shield
tag: Which events tell police, when, and how

Police are central to some events and kept completely out of others. This table is the whole picture.

| Event | Are police told? | What they get |
|---|---|---|
| Escort Convoy | Yes, they are the escort | Every convoy banner. They always see every checkpoint and the destination, plus the truck blips and the NPC police support units. The convoy halts if no officer is within 150 m. |
| Hot Cargo Run | Only after a hijack | Nothing at the start and no search areas. After the stealth head start (45 seconds by default, 0 to 600 per event) they get a chime, a HOT CARGO ALERT banner and the truck's live GPS position. They also get a truck-critical banner. An event can switch the alert off. |
| Gang Airdrop | Never | The event is hidden from police. They cannot loot a crate. |
| Rally Race | Only after it ends | A 10-99 "illegal race terminated, suspects fleeing" banner, a corner alert and a blinking GPS marker at the finish line. An officer who registered at the registration ped is a racer and gets no pursuit alert. |
| TDM Match | Never | Players are invincible, so no death or dispatch call ever happens. On-duty police cannot join. |
| Container Wars | Only if they register | Police are not told. An officer can bid as a civilian after registering at the registration ped. |
| Territory Auction | Never | Police cannot bid. |
| Practice Range | Never | Nothing said or shot in the range reaches police or dispatch. |

> tip: To change when police are told for a Hot Cargo run, open the event and change its Police Alert and stealth head start. The banner wording for every alert is in Config.AnnouncementBanners.

# Announcements & sounds
id: announcements
group: Systems
icon: megaphone
tag: Banners, audio, scheduling, Discord and PDF

## Announcement banners

The full-screen banners players see (event starting soon, truck broken down, race ended, territory lost and so on) are written in Config.AnnouncementBanners, with a title, body, duration and style for each. The Announcements tab lets an admin send a custom banner to everyone, with its own colour and image, and create "upcoming event" banners.

## Sounds

Banner and notification sounds are named in Config.Sounds, so you can add your own sound files and use them by name. Run {{soundTestCmd}} followed by a sound name to hear it in game.

Every tab, button, toggle and dropdown in every panel (the admin tablet, the event status panel, the armory, results, bidder and so on) plays a short mouse-click sound. It is set in Config.Sounds.uiClick: change `sound` to another library name to swap it, lower `volume` to make it quieter, or set `enabled = false` to turn it off.

## Scheduling

Events can be started by hand from Manage Events or scheduled for a date and time. The scheduler uses your server's timezone automatically, or the fixed offset in Config.ScheduleUtcOffsetHours. Players are warned before a scheduled event ({{preSchedule}} by default).

Test run: a Draft or Scheduled event has a Test run button next to Start (not for territory auctions). After you confirm, the event runs for real but every notification, banner and announcement goes to YOU only; nobody else on the server receives anything. Nothing is posted to Discord, no money, XP, items or cars are paid, a Container Wars winner is not charged, and nothing is saved to Event History or the leaderboards. No other event can start until the test run ends (Force End ends it). The trucks, props and peds are still real objects in the world, so a player standing next to them can see them.

## Discord logs and PDF reports

With Config.DiscordLogs set up, every event posts its lifecycle to your Discord channel and attaches a downloadable PDF after-action report when it ends. Titles, footers and the logo come from Config.Branding.

What the end-of-event message and the report contain, for every event type (Escort Convoy, Hot Cargo, Airdrop, Rally Race, TDM match and tournament, Container Wars, Territory auction and war, Operation Crackdown):

- The result in that event's own terms (trucks delivered, drops claimed, final race standings, the score, lots or territories sold, the war result).
- Who took part, and the full timeline.
- What was really paid: every player's money, items, tokens and the Gang XP each gang earned. Hot Cargo shows each delivery's truck condition and what its crate actually held, because the reward scales with the truck's health.
- Territory changes outside an event also get a Discord post: XP expansions, painted and erased land with the XP spent or refunded, a war's post-war loot and the land the loser lost, admin hand-overs, and changes to the painting price (XP per cell). Set Config.DiscordLogs.territoryChanges to false to stop those.

Everything finished is kept in Event History. Its list shows the result and the reward actually paid, the Report button opens the same report, and the PDF button downloads it. If your game browser blocks the download, open the report and use Send to Discord to get the PDF in the channel again.

> warn: The Discord webhook URL in config.lua is a secret. Do not paste it anywhere public.

# Peds & placing things
id: peds
group: Systems
icon: user
tag: Vendors, event peds and the placement hologram

Every ped in the system is placed in the world by an admin, with a hologram: a see-through copy of the ped that appears in front of you and follows your crosshair.

## Placing a ped

1. Press Place with Hologram (or Move with Hologram) on the ped's row. The tablet steps aside and the hologram appears at your crosshair, in front of you.
2. Aim where it should stand. Press F to freeze it, G to drop it to the ground, then E to confirm.
3. The tablet returns and the ped is moved for everyone online at once, with no restart.

## Two kinds of ped

- World Peds belong to no event and stay in the world all the time: the Race Token Vendor and the Practice Range Instructor. They are on the World Peds tab, where each can be turned off.
- Event peds belong to one event and are placed in that event's form: convoy vendors and start ped, TDM weapon vendors, race vehicle ped, Container Wars peds, the territory leader ped.

The ped models are set in config.lua: Config.Peds holds the shared ones, and each vendor also has its own pedModel.

## Props

The Prop Placer (/propplacer, admin) places props for events: barricades, checkpoint props, Container Wars dummy stacks, the territory projector and the Hot Cargo truck. It works the same way as the ped hologram. For a Rally Race or a Convoy the placer also draws the route in the world: a green ring for the start, blue rings for the checkpoints, a gold ring for the finish, and a line with arrows joining them, so you can see where racers drive while you place props. Props can stand on the route.

# Every tablet tab
id: tabs
group: Reference
icon: list
tag: The menu, tab by tab

| Group | Tab | What it does |
|---|---|---|
| Operations | Dashboard | Live overview of running events, with quick actions. |
| Event Management | Create Event | Choose an event type and build it. |
|  | Manage Events | Your events: start, test run, announce (opens its announcement window), cancel, edit (Draft only), reuse. |
|  | Active Participants | Who is registered for each event, with filters. |
|  | Saved Routes | Convoy routes you saved, ready to reuse. |
|  | Event History | Finished events with results and reports. |
| Tournaments | Tournaments | Brackets of TDM matches. |
|  | Tournament Tree | Pick a tournament and watch its groups, bracket and champion update live. |
|  | Tournament History | Finished tournaments. |
| Territory System | Map Zone | The live territory map and its tabs: Expansion XP (price of painting land), Admin Tools (hand over, delete, Gang XP), XP history, ranking and ownership history. |
|  | Rival Wars & Challenges | Challenges between gangs and the war schedule. |
|  | Auction Results | One row per auction. View result shows which gang bought which territory, for how much, and every lot. |
| Gangs & Community | Gang Management | Create gangs, roster, member levels and permissions. |
| Leaderboards | Gang Leaderboard | Gang standings per event type. |
|  | Civilian Leaderboard | Civilian standings. |
| System & Administration | Announcements | Custom and upcoming-event banners. |
|  | World Peds | Place the permanent peds. |
|  | Staff Management | Staff, roles, permissions and the activity log. |
|  | Settings | Your own look (one of three themes, click sounds), table preferences and the server scheduling settings. |
| Help | User Guide | This guide. |

The menu is a floating bar of group tabs across the top of the tablet (Events, Tournaments, Territory ...). The pages of the open group appear as chips under it, so nothing needs scrolling. Prefer the old side rail? Settings → Menu layout.

## The tabs in your menu right now (read from the tablet)

@tabs

# Commands & keys
id: commands
group: Reference
icon: gear
tag: Everything you can type

| Command or key | Who | What it does |
|---|---|---|
| {{tabletCmd}} ({{tabletKey}}) | Staff | Opens the Operations Hub. |
| {{statusCmd}} ({{statusKey}}) | Gangs and police | Opens the Event Status panel. |
| {{raceStartCmd}} [event id] | Organisers and admins | Starts the countdown for a race waiting on the grid. |
| /crosshair | Players | Opens the crosshair settings used in TDM and the Practice Range. |
| TAB | Players in TDM or practice | Shows the scoreboard. |
| /endpractice (F6) | Practice players | Marks the way to the exit, where you press E to leave. |
| /eventregistration | Civilians | Opens the event registration window. |
| /propplacer | Admins | Opens the Prop Placer. |
| /settokenvendor | Admins | Moves the Race Token Vendor to where you stand. |
| /carowner | Admins | Hands a spawned Container Wars reward car to its winner. |
| /cwcarlot [car] [container] | Anyone (test) | Runs a car lot in front of you that only you see: the container with its dummy crate, then the crate goes and the car appears inside with a claim target. Default `sultan` in `prop_container_ld`. It clears itself 3 seconds after you target the car, or after 60 seconds; `/cwcarlot clear` removes it at once. |
| /cwlootest [model] | Anyone (test) | Spawns a container only you can see, plays the opening scene, holds it open and shows the loot crate with a target, to check the open pose and that the crate can be reached. It clears itself 3 seconds after you target the crate, or after 60 seconds; `/cwlootest clear` removes it at once. |
| {{soundTestCmd}} [name] | Admins | Plays a configured sound. |
| convoydebug [off or id] | Admins | Draws the running convoy's route as lines in the world (grey = passed, yellow = driving now, cyan = ahead), every route point numbered, each truck with the point it is heading for, how far it is from the route line, the path it really drove, and why it is or is not moving. The server console also prints an "on the route line X% of the time" score per truck every 15 seconds, and a warning when a truck stands still without a reason. Each truck line also shows what the truck itself is doing (engine, revs, gear, wheel speed, drive order, who controls it). `/convoydebug physics off` switches the heavy-truck handling off for every convoy truck live (and `physics on` brings it back), to test whether it is what slows them. A truck that stands still far from its target without a drive order is given one again automatically, and the overlay says what it did ("keeper"). It also checks the route against the game's road network near you: each point shows how far it is from a drivable road, "NO ROAD PATH" is drawn between two points the roads do not connect, and the findings are printed in the server console. Run it again to hide it. |
| /minigametest [name] | Testing | Plays a minigame so you can try it. |
| /cwspot and /cwscan | Admins | Container Wars yard setup helpers (pickup spots and scanning the yard). |
| /convoy_hud_hide and /convoy_hud_show | Players | Hides or shows the event HUD. |

> tip: The commands and keys for the two tablets are set in Config.Tablet and Config.StatusPanel, and the values on this page follow them.

## Other commands this script registers (found automatically)

Anything the script registers that is not described above shows here, so a new command appears without anyone editing this file. Many are helpers bound to keys while you record a route or place a yard.

@commands

# Commands by event
id: eventcommands
group: Reference
icon: gear
tag: Which command belongs to which event

The list below is sorted by event, so you can see at a glance what to type (or press) for the event in front of you. Commands marked "test" or "setup" are for admins building an event; they change nothing for players. Keys can be rebound in the game's own keybind settings (FiveM Settings, Key Bindings, FiveM).

## Every event

| Command or key | Who | What it does |
|---|---|---|
| {{tabletCmd}} ({{tabletKey}}) | Staff | Opens the Operations Hub, where every event is created, started, scheduled and ended. |
| {{statusCmd}} ({{statusKey}}) | Gangs and police | Opens the Event Status panel: the live events, your gang's registration, leaderboard and territory. |
| /eventdebug | Admins | Watches every running event in your F8 console: phase, timers, scores, players, and a warning when one stops progressing. |
| /eventdebug check [event id] | Admins | Pre-flight check of the set-up of all events (or one): zones, spawns, gangs, vendors, routes. Nothing needs to be running. |
| /eventdebug status | Admins | One snapshot of everything running right now (events, tournaments, rival wars). |
| /eventdebug off | Admins | Stops the watching. |
| /eventregistration | Civilians | Opens the event registration window. |
| {{soundTestCmd}} [name] | Admins | Plays one of the configured notification sounds. |
| /propplacer | Admins | Opens the Prop Placer used by every event that has props (Props tab, checkpoint props, Hot Cargo, Container Wars). |
| /convoy_hud_hide and /convoy_hud_show (X and L) | Players | Hides or shows the team health bar of the event HUD. |
| /hudmove (;) | Players | Lets you drag the HUD to another place; press Esc or Lock to finish. |
| /hudhide and /hudshow | Players | The same as X and L, for when another script already uses those keys. |
| /fixcontrols | Players | "I cannot shoot or reload": clears anything this script left on your controls and says which one was stuck. |
| /drivebycheck | Players | Prints why drive-by shooting is or is not available in the vehicle you are in. |
| /minigametest [name or all] | Admins (test) | Plays a minigame so you can try it. Nothing is rewarded. |

## Drawing zones and routes (setup, used by every event form)

| Key | Where | What it does |
|---|---|---|
| E | Route recorder | Drops a route point where you stand. |
| K | Route recorder | Drops an airdrop point (Gang Airdrop). |
| E and K | Zone recorder | Drops a primary and a secondary zone. |
| Backspace | Route and zone recorders, perimeter editor | Undoes the last point. |
| Enter | Route and zone recorders, perimeter editor | Finishes and returns to the tablet (the perimeter editor saves with at least 3 points). |
| Left click | Perimeter editor | Drops a corner of a box or perimeter where the marker is. This is the tool behind **Draw Perimeter**: the TDM zones, the Container Wars zone, and the Crackdown gang and police start areas. |
| Esc | Perimeter editor | Cancels. |
| E or Enter, Backspace, F, G | Harbour placer | Confirm, cancel, freeze or follow the aim, drop to the ground. |

## Escort Convoy

| Command | Who | What it does |
|---|---|---|
| /convoydebug [off or event id] | Admins | Draws the running convoy's route as lines in the world, each truck with its target point, its distance from the route and why it is or is not moving. Run again to hide. |
| /convoydebug physics off or on | Admins | Switches the heavy-truck handling off (or back on) for every convoy truck, to test whether it is what slows them. |
| /convoydebugmore | Admins | Switches the debug overlay between compact and full detail. |

## Hot Cargo

Hot Cargo has no command of its own. Start it from Manage Events; use /eventdebug check to test its set-up and /propplacer to place its truck and trailer props.

## Gang Airdrop

No command of its own. Drop points are placed with the route recorder (K) or in the Airdrop zones tab; /eventdebug watches a running drop.

## Rally Race

| Command | Who | What it does |
|---|---|---|
| {{raceStartCmd}} [event id] | Organisers and admins | Starts the countdown for the race waiting on the grid (the id is only needed when more than one is waiting). |
| /settokenvendor | Admins | Moves the Race Token Vendor to where you stand. |

## TDM Match, Tournaments and the Practice Range

| Command or key | Who | What it does |
|---|---|---|
| TAB | Players in a match or in practice | Shows or hides the scoreboard. |
| /crosshair | Players | Opens the crosshair settings. |
| /endpractice (F6) | Practice players | Marks the way to the exit; press E there to leave. |

The end-of-match banner (gang logo, WINS or DEFEATED, player cards) and the results window open on their own; there is nothing to type.

## Operation Crackdown

Operation Crackdown has no command of its own, and nothing is typed in game: the two start areas and the combat zone are set from the event form (Combat Zone tab, Draw Perimeter) with the perimeter editor keys above. Start it from Manage Events; /eventdebug check tells you if a zone or gang is missing.

## Container Wars

| Command | Who | What it does |
|---|---|---|
| /carowner | Admins | Opens a menu of the cars spawned by container events, to hand one to the player who really won it. |
| /cwspot | Admins (setup) | Aim at a harbour container and run it: prints the line to paste into the config's harbour pickups. |
| /cwscan [radius] | Admins (setup) | Looks for containers around you (default 70 m) and lists them nearest first, ready to paste; they are numbered in the world for 25 seconds. |
| /cwinfo or /cwhud | Players | Shows or hides the Container Wars civilian info panel. |
| /cwmove | Players | Lets you drag that panel to another place. |
| /cwvehicle | Players | Shows or hides the vehicle claim bar. |
| /cwcarlot [car] [container] | Anyone (test) | Runs a car lot in front of you that only you see: the container, its dummy crate, then the car with a claim target. `/cwcarlot clear` removes it. |
| /cwlootest [model] | Anyone (test) | Spawns a container only you see, plays the opening scene and shows the loot crate with a target. `/cwlootest clear` removes it. |
| /cwopentest [model] | Admins (test) | A closed container with its doors fitted in front of you that opens, shuts and goes: checks the hinge position. |
| /cwopenanim [model] | Admins (test) | Tests the opened pose on every auctionable container model in turn and prints one result line per model. |
| /cwprobe [model ...] | Admins (test) | Measures container models: size, whether a car fits, whether an end is open. |
| /cwcartest [car] [container] [flip] | Admins (test) | Puts a dummy car inside a container for 25 seconds, where the server places it when a car lot opens. |
| /cwcranesound | Admins (test) | Plays every stage of the crane sound at your feet. |
| /cwgantrytest and /cwgantryclear | Admins (test) | Runs the gantry crane once in front of you, and removes it. |
| /cwhooktest, /cwhookset, /cwhookclear | Admins (test) | Shows the crane hook parts, moves one part and prints its config line, removes the test. |

## Territory Auction and Rival Wars

| Command | Who | What it does |
|---|---|---|
| /projlens x y z | Admins (setup) | Moves the lamp of the auction projector in front of you (until the next restart) and prints the line for the config. |

Territory paint, rival wars and the leader ped need no commands: they are used through the tablets and the target menu.

# Where things live in config
id: config
group: Reference
icon: fileText
tag: A map of the config file

config.lua is divided into numbered sections, each with a comment header. Most things are also editable from the tablet; the config holds the defaults.

| Section | Main tables | Holds |
|---|---|---|
| 1. Core | Config.Branding, DiscordLogs, Tablet, StatusPanel, GangProvider, BankingProvider, CreatorAccess, Minigames, Lockpick, Features, PropPlacer, HUD, MapBlips, NpcCombat | Names and logos, Discord, who is an admin, framework providers, minigames, feature switches. |
| 2. Container Wars | Config.ContainerWars, VehicleRewards | Auction defaults, crane timings, anti-snipe, reward vehicles. |
| 3. Escort Convoy | Config.Max*, DefaultTruck*, CheckpointBarricades, Peds, EscortVehicleShop, PoliceEquipment, CapturedTruckLoot | Limits, truck health and speed, checkpoints, vendors, loot. |
| 4. Hot Cargo | Config.HotCargoTheft | Truck list, breakdown, reward scaling, protection. |
| 5. Airdrop | Config.Airdrop | Crate prop, guards, plane, and the preset locations (predefinedLocations, as vector3 coords). |
| 6. Rally Race | Config.RallyRace, TokenVendor, RaceVehicleShop, RallyNotifications | Tokens, grid, countdown, the vendor and rental ped. |
| 7. TDM | Config.TDM | Virtual HP, damage per weapon, weapon shop. |
| 8. Territory | Config.Territory | Painted map, Gang XP, auction, wars. |
| 8b. Operation Crackdown | Config.Crackdown | Default timing, outside-the-zone timer, minimum fighters, leave grace, standard announcement texts. |
| 9. Practice Range | Config.PracticeRange | Areas, weapons, bots, health. |
| 10. Banners & sounds | Config.AnnouncementBanners, Sounds | Every banner text and every sound. |

> tip: After changing config.lua, restart the resource. Changes made in the tablet apply immediately.

# Troubleshooting
id: trouble
group: Reference
icon: warning
tag: The questions that come up first

| Problem | Check |
|---|---|
| Events are missing after a restart | The database was probably offline when the server started. Start it, then restart this resource. |
| The tablet will not open | Are you an admin, police or staff? See "Who can do what". Check Config.Tablet.command. |
| A vendor or ped does not show | World Peds: is it turned on and placed? For an event ped, was it placed in that event's form? ox_target must be running. |
| A hijack or crate will not open | The player needs the lockpick item, and it must exist in your inventory. |
| A reward item is not given | The item must exist in your inventory. Check the server console for the line naming the missing item. |
| A car cannot be stored in a garage | The model is missing from qbx_core's shared vehicles. Add it there. |
| An addon car does not spawn | The vehicle resource or the stream/ files must be started on the server. See ADDON_VEHICLES.md. |
| A player is stuck in the Practice Range | They are moved back automatically the next time they log in. An admin can also restart the resource. |
| Gang XP change shows an error | Read the server console for the database error behind it. |
