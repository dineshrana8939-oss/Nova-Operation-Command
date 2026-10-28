-- ─── Nova Operations Hub — System Configuration ──────────────────────────────
Config = {}

-- ═══════════════════════════════════════════════════════════════════════════════
-- TABLE OF CONTENTS
--   SECTION 1: CORE PLATFORM & SHARED SYSTEMS
--              Branding, Discord, Tablet, Permissions, Banking, Scheduler,
--              Features, Minigames, Lockpicking, Turrets, Prop Placer, HUD,
--              Map Blips & NPC Tactical Combat
--   SECTION 2: EVENT — CONTAINER WARS (Harbour Auction Yard, Crane & Vehicle Rewards)
--   SECTION 3: EVENT — ARMORED CONVOY (Escort Route, Checkpoints, Barricades & Stash Loot)
--   SECTION 4: EVENT — HOT CARGO HEIST (Contraband Trucks, Hijacking & Drops)
--   SECTION 5: EVENT — GANG AIRDROP CRATES (Cargo Plane, Parachute Crates & Locations)
--   SECTION 6: EVENT — GANG RALLY RACE (Street Stages, Tokens, Vehicle Rental & Toasts)
--   SECTION 7: EVENT — TEAM DEATHMATCH (TDM Arena, HP Pool, Vendors & Brackets)
--   SECTION 8: EVENT — GANG TERRITORY AUCTION & RIVAL WARS (Painted Grid, XP & Captures)
--   SECTION 9: EVENT — PRACTICE RANGE & TACTICAL TRAINING (Aim Drills & Squad Buckets)
--   SECTION 10: SYSTEM ANNOUNCEMENT BANNERS (Full-Screen Banners & Audio Cues)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- SECTION 1: CORE PLATFORM & SHARED SYSTEMS
-- Branding, Discord, Tablet, Frameworks, Permissions, Scheduler, HUD & Combat
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── Server & Operation Branding ─────────────────────────────────────────────

Config.Branding = {
    -- The core server/community name (e.g. 'Nova', 'Kailaasa', 'TNRP', 'State Police')
    serverName = 'Nova',

    -- Primary operation name used in banners, logs, and UI (e.g. 'Nova Convoy', 'Kailaasa Convoy', 'TNRP Convoy', 'Police Convoy')
    operationName = 'Nova Convoy',

    -- Tablet / Command Terminal title bar label (shown in the top bar of the tablet).
    -- Neutral name: the tablet runs convoys, hot cargo, airdrops and rallies.
    -- ── Admin / organiser tablet (opened with Config.Tablet.command) ──
    tabletTitle = 'Operations Hub', -- title in the tablet header, e.g. 'Kailaasa Operations Hub'
    tabletBadge = '',               -- small tag beside the title (e.g. 'ADMIN'); '' hides it
    -- ── Gang / police status tablet (opened with Config.StatusPanel.command or its item) ──
    statusPanelTitle = 'Event Status',
    statusPanelBadge = 'LIVE',      -- '' hides it
    -- Key-binding menu text for the two tablets.
    tabletKeyLabel = 'Open Operations Hub Tablet',
    statusPanelKeyLabel = 'Open Event Status Panel',

    -- Your server logo, as a direct image link (https://…/logo.png).
    --  • Discord: used as the webhook avatar (unless Config.DiscordLogs.avatarUrl is set),
    --    the embed thumbnail and the footer icon. PNG / JPG / GIF / WEBP all work.
    --  • PDF report: drawn in the header. PDFs can only embed a JPEG here, so
    --    use pdfLogoUrl below (a .jpg link) — leave '' for no logo in the PDF.
    logoUrl = '',
    pdfLogoUrl = '',

    -- PDF title displayed in the top header of the After-Action Report
    -- Supports %s which gets replaced with the uppercase operationName (e.g. "KAILAASA CONVOY -- AFTER-ACTION REPORT")
    pdfTitle = '%s -- AFTER-ACTION REPORT',

    -- PDF confidential footer notice
    pdfFooter = '%s SYSTEM  |  CONFIDENTIAL AUTOMATED AUDIT & AFTER-ACTION REPORT',

    -- Discord Webhook sender name and footer (defaults to operationName if nil)
    discordBotName = 'Nova Convoy',
    discordFooter = 'Nova Convoy',
}

-- ── Report PDF download ─────────────────────────────────────────────────────
-- "Download PDF" in Event History cannot save a file from inside the game's browser, so the server serves the PDF on this
-- resource's own web address for a few minutes and the tablet opens that link in the player's normal browser.
-- baseUrl: the address a player's browser can reach this server on, e.g. 'http://123.45.67.89:30120' or
-- 'https://play.myserver.com'. Leave it empty to use the address the player is connected to (works for most servers).
Config.ReportDownload = {
    baseUrl = '',
}

-- ── Discord Webhook Logging ─────────────────────────────────────────────────

Config.DiscordLogs = {
    enabled = true,
    webhookUrl = '', -- paste your Discord webhook URL here (keep it private; never commit a real one)
    botName = nil, -- Defaults to Config.Branding.discordBotName or Config.Branding.operationName if nil
    avatarUrl = nil,
    generatePdf = true, -- Attach downloadable PDF After-Action Report upon event completion
    -- What every event's end-of-run message and report contain: the result, who took part, the real payouts (money, items,
    -- tokens and the Gang XP each gang earned) and the full timeline. TDM tournaments and Territory wars / auctions get the
    -- same treatment, and each one is also kept in Event History (Report and PDF buttons there).
    territoryChanges = true, -- also post gang XP expansions, painted / erased land, XP refunds, admin edits of the territory map and changes to the painting price (XP per cell)
    gangChanges = true,      -- also post members added to a gang from a tablet (admin Invite Member, or a gang leader adding by server ID / name)
}

-- ── Convoy route debug (admin) ───────────────────────────────────────────────
-- /convoydebug draws the running convoy's route as lines in the world, every truck with the point it is heading for, how far
-- it is from the route line, the path it really drove, and why it is or is not moving. Set command = false to turn it off.
Config.ConvoyDebug = {
    command = 'convoydebug',
    onRouteMeters = 30.0,   -- a moving truck within this many metres of the drawn route counts as on the route
}

-- ── Drive-by ──────────────────────────────────────────────────────────────────────────
-- true (default): while any event is running, every player in a vehicle may shoot from it (driver included — pistols / SMGs from the driver seat; rifles from the passenger seats. The old data/weapons.meta patch that tried to allow rifles for the driver is switched off because it crashed the game client).
-- false: only players who joined an event (or sit in a convoy truck) get it.
Config.DriveBy = {
    everyoneDuringEvents = true,
}

-- ── Event debug (admin) — every event kind ──────────────────────────────────────────
-- /eventdebug            watch every running event (phase, timers, scores, players, stuck warnings) in your F8 console
-- /eventdebug check      pre-flight check of ALL events' set-up (zones, spawns, gangs, vendors, routes) - nothing has to run
-- /eventdebug check <id> the same for one event;  /eventdebug status = one snapshot;  /eventdebug off = stop
-- Covers Convoy, Hot Cargo, Gang Airdrop, Gang Rally, TDM + tournaments, Container Wars, Territory Auction and Rival Wars.
-- Set command = false to turn it off. (The convoy route view stays /convoydebug.)
Config.EventDebug = {
    command = 'eventdebug',
    intervalSeconds = 10,   -- how often the watch prints (seconds)
}

-- ── Tablet & Status Panel Access ────────────────────────────────────────────

Config.Tablet = {
    command = 'eventhub',
    keybind = 'F7',
}

-- Gang roles (shared by the admin tablet's Gang Management and the gang's Event Status panel). Every gang always has the two built-in
-- roles, Leader (the gang leader only) and Member (the default). maxCustomRoles = how many roles of its own a gang may add on top of
-- those, so a gang cannot pile up dozens. A gang already above the limit keeps its roles; it just cannot add more.
Config.GangRoles = {
    maxCustomRoles = 5,
}

Config.StatusPanel = {
    command = 'eventstatus',
    keybind = 'F6',
    -- A player in a gang who ALSO holds one of these jobs while ON DUTY (job.onduty = true) opens the Event Status panel as a
    -- government worker: no gang tabs, no gang tools, and only the Convoy, Rally Race and Container Wars events are listed.
    -- (In RP they ask their leader to take their gang role away; off duty, or without the job, they are an ordinary member.)
    -- Every job in Config.CreatorAccess.jobs (police) counts too.
    govJobs = { 'police', 'sheriff', 'bcso', 'sasp', 'lspd', 'state', 'ambulance', 'ems', 'doctor', 'fire', 'firefighter', 'doj', 'judge', 'government' },
    -- the event kinds that government workers see in the panel
    govEventKinds = { CONVOY = true, GANG_RACE = true, CONTAINER_WARS = true, CRACKDOWN = true },
    -- true = such a player cannot open the panel at all and is told they have the police role (instead of the events-only view)
    govBlockOpen = false,
}

-- ── Event Status Item (using it opens the Event Status panel) ────────────────

Config.StatusPanelItem = {
    enabled = true,
    item = 'event_status_tablet', -- must exist in your inventory's item list
}

-- ── Framework Providers (Gangs & Banking) ───────────────────────────────────
-- Gangs:
--   'internal'  -> standalone gang system managed within this resource
--   'framework' -> reads framework jobs/gangs (Qbox / QB-Core)
--   'custom'    -> delegates to bridge/gangs/custom.lua
Config.GangProvider = 'internal'

-- Banking:
--   'auto'      -> use a recognised banking script if one is running (Renewed-Banking),
--                  otherwise the framework's own bank balance
--   'framework' -> framework bank balance only, no banking-script integration
--   'renewed'   -> Renewed-Banking: framework balance + statement entries
--   'custom'    -> delegates to bridge/banking/custom.lua
Config.BankingProvider = 'auto'

-- ── Staff & Event Creator Access Permissions ────────────────────────────────

Config.CreatorAccess = {
    -- Job name -> minimum grade required. Any job not listed has no access.
    jobs = {
        police = 0,
        lspd = 0,
        bcso = 0,
        sheriff = 0,
        state = 0,
        sasp = 0,
        sahp = 0,
        rangers = 0,
    },

    -- Allow server administrators holding the ACE permission full tablet access
    admin = true,
    adminPermission = 'admin',

    -- Specific player identifiers that always grant admin access
    -- Example: { 'license:abc123...', 'discord:000000000000000000' }
    adminIdentifiers = {
        -- 'license:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
        -- 'discord:000000000000000000',
    },

    -- No longer used: which tablet sections a person sees (and what they may do in them) now comes from their staff
    -- role in the tablet's Staff Management section. Real admins (the ACE permission / adminIdentifiers above) keep
    -- full access and are never listed there. Left in place only so an old config.lua does not break.
    adminOnlyTabs = { 'gangs', 'settings', 'worldpeds', 'announcements', 'tournaments', 'tournamenthistory', 'territories', 'mapzone', 'rivals', 'leaderboard', 'civilianleaderboard' },
}


-- ── Global Minigames & Lockpicking ──────────────────────────────────────────────────

-- ═══════════════════════════════════════════════════════════════════════════════
-- ── Minigames ──────────────────────────────────────────────────────────────────
-- Every interactive lock/hack in every event (Hot Cargo hijack, truck loot, airdrop
-- crates and their hack variants) draws its minigame through ONE function, using these
-- rules. The suite has 70 games; each attempt picks one at random, independently per
-- player.
Config.Minigames = {
    -- 'all'    = every game can appear in every event (default)
    -- 'themed' = picking events only draw lockpick-style games, hacking events only
    --            hack-style games (smaller pools)
    mode = 'all',
    -- Never repeat any of the last N games a player was given.
    avoidRepeats = 3,
    -- Game names to leave out of the draw, e.g. { 'archery', 'parry' }.
    disabled = {},
    -- Debugging: set a game name (e.g. 'keypad') to always play that one.
    force = nil,
}


-- ── Lockpick durability ────────────────────────────────────────────────────────
-- Applies to every lockpick minigame (convoy trucks, airdrop crates, hot cargo).
-- A lockpick only snaps after this many FAILED attempts; gang members share a
-- crate/truck's lock progress, so a teammate can carry on with their own pick.

Config.Lockpick = {
    -- Fallback when an event has no difficulty set.
    maxFailures = 4,
    -- Failed attempts one lockpick survives, by the event's difficulty.
    maxFailuresByDifficulty = {
        EASY = 4,
        MEDIUM = 3,
        HARD = 2,
        EXTREME = 1,
    },
}

-- ── Global Automation & Event Scheduler ─────────────────────────────────────
-- UTC offset in hours for scheduled convoys/airdrops (e.g. 5.5 for IST, 0 for UTC, -5 for EST).
-- Set to nil to automatically detect the server host machine's real-world timezone offset.
Config.ScheduleUtcOffsetHours = nil
Config.SchedulePollIntervalSeconds = 15

-- ── Feature Toggles ─────────────────────────────────────────────────────────

Config.Features = {
    GangPvp     = true,
    NpcPolice   = true,
    ArmySupport = true,
    Airdrops    = true,
}

-- ── Restricted Heavy Military & Turret Vehicles ─────────────────────────────

Config.RestrictedTurretVehicles = {
    enabled = true,
    models = {
        'insurgent', 'insurgent2', 'insurgent3',       -- Insurgent Pick-Up / armored / Pick-Up Custom
        'technical', 'technical2', 'technical3',       -- Technical / Aqua / Custom
        'halftrack',                                   -- Half-track
        'barrage',                                      -- Barrage
        'limo2',                                         -- Turreted Limo
        'tampa3',                                        -- Weaponized Tampa
        'apc',                                            -- APC
        'khanjali',                                       -- TM-02 Khanjali (tank)
        'rhino',                                          -- Rhino Tank
        'chernobog',                                      -- Chernobog (missile truck)
        'scarab',                                         -- Scarab (Doomsday tank)
    },
}


-- ── Shared Prop Placer System ───────────────────────────────────────────────────────

-- Every "Place" button in the tablet (checkpoint barricades + decor vehicles, Hot Cargo truck spots,
-- Container Wars dummy stacks, the Props tab of every event) opens the same placer
-- (client/modules/prop_placer.lua + web/src/lib/placer/PropPlacer.svelte). What changes between events
-- is only WHICH objects it offers: that is the `contexts` table below.
--
--   categories  the filter chips in the asset browser (id, label). "Everything" is added automatically.
--   assets      every placeable model: { model, label, category, stackable?, dupOffset?, step? }
--                 stackable  = it can be stacked 1..maxStack high (container pods / containers)
--                 dupOffset  = metres its duplicate is moved along its right-hand side (default: duplicateOffset)
--                 step       = metres between the pieces of a stack (default: measured from the model)
--               Models this game build does not have are hidden automatically. Any other model name can
--               also be typed into the search box of the placer.
--               The lists Config.CheckpointBarricadeProps, Config.ContainerWars.containerModels and
--               Config.ContainerWars.harbour.dummyModels are merged in as well, so nothing is entered twice.
--   contexts    what one kind of placement may use:
--                 categories  limit the browser to these category ids (nil = everything)
--                 vehicles    false hides vehicles, true shows them (default true)
--                 stack       false hides the stack-height control (default true: shown for stackable assets)
--                 maxStack    tallest stack allowed (default 6) — the 1 / 2 / 3 … buttons stop here
--                 collision   false hides the "solid" switch (default true; a prop that is not solid can be walked through)
--                 maxObjects  most objects in one layout (default maxObjects below)
--                 dupOffset   this context's duplicate distance (default duplicateOffset below)
Config.PropPlacer = {
    maxObjects = 150,           -- most objects one layout may hold
    duplicateOffset = 1.0,      -- metres a duplicate is moved along the object's right-hand side
    moveStep = 0.25,            -- metres one arrow-key nudge moves (Shift = a tenth, Ctrl = ten times)
    rotateStep = 5.0,           -- degrees one rotate step turns
    gridSize = 0.5,             -- metres of the grid when "Grid" is switched on
    camera = {
        fov = 60.0,
        speed = 14.0,           -- metres per second while flying (hold the right mouse button + W A S D Q E)
        fastMultiplier = 4.0,   -- Shift while flying
        lookSensitivity = 0.22, -- degrees per pixel of mouse movement
        startDistance = 14.0,   -- how far from the work area the camera starts
        startHeight = 9.0,
    },

    categories = {
        { id = 'barricades',   label = 'Barricades' },
        { id = 'containers',   label = 'Containers' },
        { id = 'construction', label = 'Construction' },
        { id = 'electrical',   label = 'Electrical' },
        { id = 'equipment',    label = 'Equipment' },
        { id = 'garage',       label = 'Garage' },
        { id = 'industrial',   label = 'Industrial' },
        { id = 'interior',     label = 'Interior' },
        { id = 'road',         label = 'Road' },
        { id = 'military',     label = 'Military' },
        { id = 'event',        label = 'Event' },
        { id = 'vehicles',     label = 'Vehicles' },
        { id = 'convoy',       label = 'Convoy' },
        { id = 'misc',         label = 'Misc' },
    },

    -- Config.CheckpointBarricadeProps uses the older category names; they are mapped to the ids above.
    categoryAlias = { barricade = 'barricades', cone = 'road' },

    assets = {
        -- ── the prop list from the Prop Placer reference (names used exactly as listed there) ──
        -- A name this game build does not have is simply hidden (and printed once in F8 when the placer opens).
        { model = 'prop_barrier_work05',  label = 'Barrier Work 05',    category = 'barricades' },
        { model = 'prop_barrier_work01',  label = 'Barrier Work 01',    category = 'barricades' },
        { model = 'prop_container_01',    label = 'Container Cargo',    category = 'containers', stackable = true, dupOffset = 2.6 },
        { model = 'prop_container_03',    label = 'Container Open',     category = 'containers', stackable = true, dupOffset = 2.6 },
        { model = 'prop_crane_01',        label = 'Crane Construction', category = 'construction' },
        { model = 'prop_roadcone02a',     label = 'Road Cone',          category = 'road' },
        { model = 'prop_mp_barrier_02',   label = 'Road Barrier',       category = 'road' },
        { model = 'prop_worklight_03b',   label = 'Light Tower',        category = 'electrical' },
        { model = 'prop_pallet_02a',      label = 'Pallet',             category = 'industrial' },
        { model = 'prop_forklift_01',     label = 'Forklift',           category = 'equipment' },
        { model = 'prop_crate_11e',       label = 'Crate',              category = 'industrial' },
        { model = 'prop_generator_01',    label = 'Generator',          category = 'electrical' },
        { model = 'prop_table_03',        label = 'Table',              category = 'interior' },
        { model = 'prop_chair_01',        label = 'Chair',              category = 'interior' },
        { model = 'prop_sign_road_01a',   label = 'Sign Event',         category = 'event' },
        { model = 'prop_barrel_02a',      label = 'Barrel',             category = 'industrial' },
        { model = 'prop_dumpster_01a',    label = 'Dumpster',           category = 'industrial' },
        { model = 'prop_streetlight_01',  label = 'Streetlight',        category = 'road' },
        { model = 'prop_tent_01',         label = 'Tent',               category = 'event' },
        { model = 'event_vehicle_dummy',  label = 'Truck Dummy',        category = 'vehicles' },

        -- ── more real GTA models that are known to exist ──
        -- barricades / road
        { model = 'prop_barrier_work01a',  label = 'Road Work Barrier (1A)',  category = 'barricades' },
        { model = 'prop_barrier_work02a',  label = 'Road Work Barrier (2A)',  category = 'barricades' },
        { model = 'prop_barrier_work04a',  label = 'Road Work Barrier (4A)',  category = 'barricades' },
        { model = 'prop_mp_barrier_02b',   label = 'Multiplayer Barrier',     category = 'barricades' },
        { model = 'prop_barrier_wat_03b',  label = 'Water Barrier',           category = 'barricades' },
        { model = 'prop_roadcone02b',      label = 'Traffic Cone (B)',        category = 'road' },
        { model = 'prop_sign_road_01a',    label = 'Road Sign',               category = 'road' },
        { model = 'prop_streetlight_01',   label = 'Street Light',            category = 'road' },
        -- containers (the auctioned models are merged in from Config.ContainerWars.containerModels)
        { model = 'prop_container_04a',    label = 'Shipping Container 04A',  category = 'containers', stackable = true, dupOffset = 2.6 },
        -- construction / industrial / equipment
        { model = 'prop_worklight_03b',    label = 'Work Light Tower',        category = 'construction' },
        { model = 'prop_skip_01a',         label = 'Skip',                    category = 'construction' },
        { model = 'prop_scafold_01a',      label = 'Scaffold',                category = 'construction' },
        { model = 'prop_pallet_02a',       label = 'Pallet',                  category = 'industrial' },
        { model = 'prop_barrel_02a',       label = 'Barrel',                  category = 'industrial' },
        { model = 'prop_barrel_01a',       label = 'Oil Barrel',              category = 'industrial' },
        { model = 'prop_gascyl_01a',       label = 'Gas Cylinder',            category = 'industrial' },
        { model = 'prop_box_wood02a',      label = 'Wooden Crate',            category = 'industrial' },
        { model = 'prop_boxpile_06a',      label = 'Box Pile',                category = 'industrial' },
        { model = 'prop_crate_11e',        label = 'Crate',                   category = 'industrial' },
        { model = 'prop_generator_01a',    label = 'Generator',               category = 'electrical' },
        { model = 'prop_generator_03b',    label = 'Large Generator',         category = 'electrical' },
        { model = 'prop_toolchest_01',     label = 'Tool Chest',              category = 'equipment' },
        { model = 'prop_sandbag_01',       label = 'Sandbag',                 category = 'military' },
        { model = 'prop_barrier_conc_02a', label = 'Concrete Block',          category = 'military' },
        -- interior / event
        { model = 'prop_table_03',         label = 'Table',                   category = 'interior' },
        { model = 'prop_chair_01a',        label = 'Chair',                   category = 'interior' },
        { model = 'prop_gazebo_01',        label = 'Gazebo',                  category = 'event' },
        { model = 'prop_beachflag_01',     label = 'Flag',                    category = 'event' },
        -- the Gang Territory Auction projector (placed in the event's Auction Setup → Projector Placement)
        { model = 'h4_prop_battle_lights_floor', label = 'Auction Projector (battle floor lights)', category = 'event' },
        { model = 'xm_prop_lab_cyllight01', label = 'Auction Projector (lab cylinder light)', category = 'event' },
        { model = 'prop_worklight_02a',    label = 'Auction Projector (work light)', category = 'event' },
        { model = 'prop_worklight_03b',    label = 'Auction Projector (light tower)', category = 'event' },
        { model = 'prop_worklight_04b',    label = 'Auction Projector (flood light)', category = 'event' },
        { model = 'prop_spot_01',          label = 'Auction Projector (spotlight)',   category = 'event' },
        { model = 'prop_runlight_g',       label = 'Auction Projector (old: a small red light)', category = 'event' },
        -- vehicles (also the "decoration vehicles" of a checkpoint)
        { model = 'police',    label = 'Police Cruiser',          category = 'vehicles' },
        { model = 'police2',   label = 'Police Cruiser (Alt)',    category = 'vehicles' },
        { model = 'police3',   label = 'Police Interceptor',      category = 'vehicles' },
        { model = 'police4',   label = 'Unmarked Police Cruiser', category = 'vehicles' },
        { model = 'sheriff',   label = 'Sheriff Cruiser',         category = 'vehicles' },
        { model = 'sheriff2',  label = 'Sheriff SUV',             category = 'vehicles' },
        { model = 'fbi',       label = 'FIB Sedan',               category = 'vehicles' },
        { model = 'fbi2',      label = 'FIB SUV',                 category = 'vehicles' },
        { model = 'riot',      label = 'Police Riot Van',         category = 'vehicles' },
        { model = 'barracks',  label = 'Army Transport Truck',    category = 'vehicles' },
        { model = 'barracks2', label = 'Army Cargo Truck',        category = 'vehicles' },
        { model = 'crusader',  label = 'Army Patrol Truck',       category = 'vehicles' },
        { model = 'stockade',  label = 'Armoured Truck',          category = 'convoy' },
        { model = 'hauler',    label = 'Hauler (tractor)',        category = 'convoy' },
        { model = 'packer',    label = 'Packer (tractor)',        category = 'convoy' },
        { model = 'trailers2', label = 'Trailer (box)',           category = 'convoy' },
        { model = 'trailers3', label = 'Trailer (curtain)',       category = 'convoy' },
        { model = 'docktrailer', label = 'Dock Trailer',          category = 'convoy' },
        { model = 'flatbed',   label = 'Flatbed',                 category = 'convoy' },
    },

    contexts = {
        -- a convoy checkpoint: barricades + decoration vehicles
        convoy         = { label = 'Convoy checkpoint', maxObjects = 80 },
        -- the Props tab of any event (spawn when the event starts, removed when it ends)
        event          = { label = 'Event props' },
        hotcargo       = { label = 'Hot Cargo' },
        tdm            = { label = 'Team Deathmatch arena' },
        airdrop        = { label = 'Gang Airdrop' },
        rally          = { label = 'Gang Rally' },
        container_wars = { label = 'Container Wars' },
        -- the dummy container stacks of the harbour yard (built when a Container Wars event starts, removed when it ends)
        container_yard = { label = 'Harbour dummy containers', categories = { 'containers', 'barricades', 'road', 'construction', 'industrial', 'equipment', 'military' }, vehicles = false,
                           stack = true, maxStack = 6, collision = true, dupOffset = 3.2,
                           maxObjects = 150 },   -- = ContainerWars.harbour.maxDummies: a lower cap here would cut the saved stacks short when the placer opens, and saving would delete the rest
        -- the Gang Territory Auction projector: exactly one object, nothing else offered (Move / Rotate / Height / Confirm / Cancel are the placer's own)
        territory_projector = { label = 'Territory auction projector', categories = { 'event' }, vehicles = false, stack = false, maxObjects = 1, collision = true },
        -- one truck (+ its trailer) at a Hot Cargo spawn spot
        hotcargo_truck = { label = 'Hot Cargo truck spot', categories = { 'convoy', 'vehicles' }, maxObjects = 1 },
        -- the /propplacer admin command and exports.nova_convoytruck:OpenPropPlacer with no context
        generic        = { label = 'Prop placer' },
    },
}


-- ── HUD Configuration & Keybinds ────────────────────────────────────────────
Config.HUD = {
    -- Default position for Health / Squad HUD (pixels from screen edges)
    defaultPosition = { x = 24, y = 120 },
    -- Keyboard controls for HUD interaction
    toggleKey = 'L',        -- Key to show / reopen health scoreboard
    hideKey = 'X',          -- Key to hide / close health scoreboard
    cursorKey = 'SEMICOLON', -- Key to toggle mouse cursor for dragging HUD
    showHintBadge = true,   -- Display on-screen shortcut hint badge
}

-- ── World Map & Radar Blips ─────────────────────────────────────────────────

--   46=LightYellow  47=Violet  56=Teal
Config.MapBlips = {

    -- Convoy trucks (moving) — flashing heavy truck icon.
    -- flashColour is the alternate colour when blip blinks (SetBlipFlashes=true).
    convoyTruck = {
        sprite      = 477,   -- radar_truck (heavy transport rig)
        colour      = 1,     -- Red (high-priority objective)
        flashColour = 38,    -- Purple — alternates red↔purple on each flash
        scale       = 1.0,
        flash       = false, -- steady icon; set true to blink between colour and flashColour
        flashTimer  = 500,   -- Blink speed in ms (lower = faster)
        priority    = 11,    -- Higher number = rendered on top of other blips
        label       = 'Convoy Truck',
    },

    -- Convoy staging/spawn zone — radius circle shown while trucks are parked
    -- before departure. Removed once the convoy starts moving.
    stagingZone = {
        sprite  = 1,     -- radar_level (centre dot for the staging point)
        colour  = 2,     -- Green — safe staging area, not a threat
        scale   = 0.9,
        label   = 'Convoy Staging Area',
        -- Radius blip drawn as a circle overlay around the staging centre point.
        -- radiusColour and radiusAlpha control the filled circle's appearance.
        radiusColour = 2,     -- Green fill
        radiusAlpha  = 70,    -- 0–255 opacity of the radius fill
    },

    -- Active checkpoint that trucks must reach — flashing star.
    -- Sent to BOTH police and gang audiences (see cpAudience in
    -- convoy_runtime.lua's runCheckpoint) — the NPC guard blips spawned at
    -- the same checkpoint stay police-only (see addNpcBlip), but the zone
    -- itself is meant to be visible to whoever's converging on it.
    checkpoint = {
        sprite = 38,    -- checkered flag, the same icon on every checkpoint (police route overview and the active one)
        colour = 5,     -- Yellow
        scale  = 0.95,
        flash  = true,
        label  = 'Convoy Checkpoint',   -- shown as "Convoy Checkpoint 2/3"
        -- Soft yellow fill for the checkpoint hold zone (lower = more see-through)
        radiusColour = 5,    -- Yellow fill
        radiusAlpha  = 90,
    },

    -- Route markers police / admins see (Config.PoliceRouteBlips), drawn like a GTA Online race: every stage is a
    -- light-yellow dot on the road, the next one is bigger and flashing with the GPS line to it, the destination is the
    -- checkered flag. Sprite 1 is the plain dot, 38 the checkered flag — both already used and verified here.
    -- Colours: 0 white, 2 green, 3 blue, 5 yellow, 46 light yellow, 1 red.
    policeRoute = {
        start      = { sprite = 1,   colour = 2, scale = 0.8,  label = 'Convoy Start' },
        checkpoint = { sprite = 1,   colour = 46, scale = 0.8, label = 'Convoy Checkpoint' },
        rest       = { sprite = 1,   colour = 3, scale = 0.8,  label = 'Convoy Rest Stop' },
        waypoint   = { sprite = 1,   colour = 46, scale = 0.5, label = 'Convoy Route' },
        destination = { sprite = 38, colour = 0, scale = 1.0, label = 'Convoy Destination' },
        gpsColour  = 5,      -- colour of the GPS line to the next route point
    },

    -- Delivery destination — where police deliver the truck at the end.
    deliveryZone = {
        sprite = 478,   -- radar_truck_open (truck+destination flag)
        colour = 2,     -- Green — safe destination
        scale  = 1.0,
        flash  = true,
        label  = 'Convoy Drop Location',
    },

    -- Active airdrop crate on the map — supply crate icon.
    airdrop = {
        sprite = 501,   -- radar_crate_drop_bg (supply crate)
        colour = 5,     -- Yellow — available loot
        scale  = 1.0,
        flash  = true,
        -- "Hunting circle" radius overlay (radius itself is Config.Airdrop.zoneRadius).
        radiusColour = 5,
        radiusAlpha  = 130,
    },

    -- Container Wars Harbour Auction Yard
    containerWars = {
        sprite       = 473,   -- radar_cargobob / cargo container
        colour       = 3,     -- Cyan
        scale        = 1.0,
        flash        = true,
        label        = 'Container Wars — Gantry Crane',   -- the blip sits on the gantry crane while an event runs
        radius       = 85.0,  -- metres: an expanded tinted circle around the gantry (0 = no circle)
        radiusColour = 3,
        radiusAlpha  = 65,
    },

    -- NPC Police support units at checkpoints (police-only visible).
    npcPolice = {
        sprite = 272,   -- radar_police_station (police shield/building)
        colour = 3,     -- Blue
        scale  = 0.85,
        label  = 'NPC Police Support',
    },

    -- NPC Army escort units.
    npcArmy = {
        sprite = 421,   -- radar_fort_zancudo (army/base crest)
        colour = 25,    -- Dark Blue
        scale  = 0.85,
        label  = 'NPC Army Escort',
    },

    -- Ambush wave hostiles — flashing danger icon.
    npcAmbush = {
        sprite = 84,    -- radar_enemy_heli (danger skull)
        colour = 1,     -- Red
        scale  = 0.85,
        flash  = true,
        label  = 'Ambush — Hostiles',
    },

    -- Airdrop guard NPCs — hostile to everyone (shoot on sight).
    npcAirdropGuard = {
        sprite = 84,    -- radar_skull (hostile enemy guard sprite)
        colour = 1,     -- Red — hostile threat
        scale  = 0.7,
        flash  = false,
        label  = 'Airdrop Guard',
    },
}


-- ── NPC Tactical Combat & Long-Range AI Perception ──────────────────────────
-- Controls perception, eyesight, hearing, accuracy, and tactical tracking so NPC
-- police, army guards, and airdrop ambushers can spot and engage hostiles
-- shooting from distant hilltops, elevation, or behind cover.
-- Player notifications. true = this script draws its own (event-coloured card with icon, category, title, message and a timeout line);
-- false = ox_lib's standard notifications. position: 'top-left' | 'top-right' | 'bottom-left' | 'bottom-right'.
Config.Notify = {
    enabled    = true,
    position   = 'top-right',
    maxVisible = 4,      -- notifications shown at once; older ones leave first
}

Config.NpcCombat = {
    -- Perception & Senses
    seeingRange = 250.0,       -- Sight distance in meters (default GTA V is ~40-60m; 250m spots hill snipers)
    hearingRange = 250.0,      -- Hearing distance in meters (reacts to rifle shots up hills instantly)
    highlyPerceptive = true,   -- Detects enemies despite partial cover, darkness, rocks, or bushes
    alertness = 3,             -- 3 = Maximum tactical alertness
    combatRange = 2,           -- 0 = Close, 1 = Medium, 2 = Far (engages at rifle/sniper ranges)
    combatMovement = 2,        -- 0 = Stationary, 1 = Defensive, 2 = Offensive (advances and repositions)

    -- Precision Marksmanship (0-100)
    policeAccuracy = 75,       -- Police NPC accuracy
    armyAccuracy = 85,         -- Army NPC accuracy (sharpshooter precision)
    airdropAccuracy = 80,      -- Airdrop guard accuracy
    shootRate = 100,           -- Aggressive return-fire rate
    firingPattern = joaat('FIRING_PATTERN_BURST_FIRE_RIFLE'), -- Controlled high-accuracy bursts up elevation

    -- Checkpoint / roadside NPC police & army: shoot every player who is not police (civilians, bystanders and gang
    -- members who never registered). On-duty police are never targeted. false = only registered gang participants.
    shootNonPolice = true,

    -- Tactical AI Attributes
    huntPlayerDown = true,     -- Continuously tracks target if they duck behind hill crest or rocks
    alwaysFight = true,        -- Never breaks combat or flees
    canUseCover = true,        -- Uses terrain, barricades, and vehicles for cover
}



-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 2: EVENT — CONTAINER WARS
-- Harbour / Container Yard Gang-vs-Gang Auction, Crane Logistics & Vehicle Rewards
-- ═══════════════════════════════════════════════════════════════════════════════════

Config.ContainerWars = {
    -- Most auction LOTS one event can hold. Lots are not tied to a spot of their own: lot N uses spot
    -- ((N-1) mod number-of-spots)+1, so a yard of 4 spots can run 4 rounds of 4 lots (16 lots) — the
    -- containers of a round are cleared before the next round puts its lots on the same spots.
    maxLots = 40,

    -- ── Defaults for a new Container Wars event ───────────────────────────────
    -- Everything the setup form starts with, and what the server falls back to when a value is
    -- missing. The tablet reads this block, so changing a number here changes the form.
    defaults = {
        maxContainers = 10,             -- most SPOTS the yard can have (harbour.maxContainers below); the most auction LOTS is maxLots at the top
        containersPerRound = 4,         -- lots a new event starts with. The per-round setting itself (how many lots one round holds, at most one per spot) starts at 1 in the tablet

        startingBid = 5000,             -- $ — opening bid of a container
        minBidIncrement = 1000,         -- $ — smallest raise
        auctionDuration = 45,           -- seconds each container is auctioned

        craneTravelSeconds = 8,         -- lift, carry and lower one container
        craneLiftHeight = 12,           -- metres it is raised while travelling (the gantry's cabin is 18 m up)
        hookReturnSeconds = 0,          -- seconds the empty hook takes to climb back up after setting a container down (0 = the same pace as the lowering)
        hookDescendSeconds = 0.5,       -- seconds the empty hook takes to come down onto the container before lifting it
        -- How fast the crane and the container move, as a multiplier on every event's "Crane trip" time:
        -- 1.0 = exactly the time set in the event, 1.25 = a quarter faster, 0.8 = slower. Applies to events
        -- already saved too (0.25 – 4.0). The hoist, carry and lowering all follow it.
        craneSpeedMultiplier = 1.25,
        -- Start sequence: when an admin starts Container Wars the banner counts down this many seconds
        -- ("Starting in 30 seconds" ... "Starting now") before the crane moves at all. 0 = no countdown.
        startCountdownSeconds = 30,
        settleSeconds = 2,              -- wait after landing
        openSeconds = 3,                -- pause after a container has landed (closed) before its bidding opens
        lotGapSeconds = 15,             -- pause / claim window between two containers
        roundBreakSeconds = 10,         -- pause after a round's last container

        -- Final round: the last container is announced as the FINAL ROUND (banner + Discord), and the break
        -- before it is at least finalRoundBreakSeconds. finalRoundAuctionSeconds = 0 keeps the container's own
        -- auction time, a number replaces it for that last container only.
        finalRoundEnabled = true,
        finalRoundBreakSeconds = 30,
        finalRoundAuctionSeconds = 0,

        -- The carry from the pickup to the drop. 'CURVE' (default) is planned like a car: the container leaves along its
        -- own length, bends round and arrives along the drop's heading (rotate a spot's hologram to change that), and
        -- the path keeps clear of the other containers and dummies. For the REAL yard (the map's own stacks, other
        -- gantries) press "Plan route" for a container in the tablet: the game scans the yard and finds an open lane.
        -- 'STRAIGHT' is the old straight line. carryCurve = how long the straight run-out / run-in at each end is, as
        -- a fraction of the distance (0.1 - 1.0).
        carryPath = 'CURVE',
        carryCurve = 0.4,
        containerSize = { length = 12.2, width = 2.6, height = 2.7 },   -- an auction container, metres (used to keep the carry clear)

        -- Crane animation. true (default): the server sends ONE move plan per container and every nearby client animates its
        -- own local copy of the gantry, the hook and the carried container at full frame rate: smooth, and almost no network
        -- traffic. false: the old way, the server moves the networked props ten times a second (visible stutter).
        smoothCrane = true,
    },

    -- ── Anti-Snipe Buffer ──────────────────────────────────────────────────────
    -- Extends auction time if a bid arrives in the final seconds to prevent last-second sniping.
    antiSnipe = {
        enabled = true,                 -- false turns the extension off for every event
        triggerSeconds = 10,            -- A valid bid with this many seconds or LESS left extends the auction
        extendSeconds = 15,             -- Seconds added to that container's countdown
        -- These are the defaults for new events; each event can override them in its Container Wars setup.
    },

    -- Configurable civilian registration ped for "Open to Everyone" Container Wars
    civilianPed = {
        enabled = true,
        model = 's_m_m_dockwork_01',
        coords = vec4(925.2, -3105.8, 5.9, 90.0),
        blip = { enabled = true, sprite = 478, colour = 3, scale = 0.85, label = 'Event Registration' },
    },

    -- ── The harbour yard — the ONLY place Container Wars runs ─────────────────────
    -- Nothing here is placed from the tablet any more: the crane, the drop spot and the container
    -- spots belong to the harbour and are set once, here. The tablet only chooses what is auctioned
    -- (containers, bids, rewards, timing) and the bidding perimeter.
    harbour = {
        label = 'Terminal harbour',
        maxContainers = 10,   -- most container SPOTS (pickups) and drop pads the yard can have; lots reuse them round after round (see maxLots)

        -- The moving gantry crane, built and driven by the script (see gantries below). x/y/z/heading is
        -- the frame's reference position: its rails run along the heading's RIGHT-hand side and its cabin
        -- slides across the heading's FORWARD side. Put it where the harbour has room for it; hook spots
        -- further than the rails / span allow are clamped and logged.
        -- auto = true: the gantry works out its own position and heading from the container spots and the drop
        -- spot below, so that all of them are inside its reach (see CWGantry.resolveCrane in shared/gantry.lua).
        -- auto = false: it stands exactly at x / y / z / heading.
        crane = { model = 'prop_dock_rtg_ld', auto = true, x = 886.7531, y = -2912.9597, z = 5.9005, heading = 269.7151 },

        -- Real map cranes standing near the gantry are hidden while an event runs so they do not overlap it.
        hideMap = { radius = 60.0, models = { 'prop_dock_crane_02', 'prop_dock_crane_04', 'prop_dock_crane_01' } },

        -- Where each container is set down: drops[i] is for container i (a point ON the ground).
        -- If there is no entry for a container, the single `drop` below is used.
        drops = {
            { x = 962.0273, y = -3107.2090, z = 5.9008, heading = 182.1101 },
            { x = 954.8867, y = -3106.9214, z = 5.7674, heading = 183.7130 },
            { x = 947.9315, y = -3106.3191, z = 5.9008, heading = 181.5273 },
            { x = 939.0914, y = -3106.2310, z = 5.9008, heading = 183.8192 },
        },
        drop = { x = 962.0273, y = -3107.2090, z = 5.9008, heading = 182.1101 },
        -- Metres added to the drop spot's height when a container is set down. A container that ends up
        -- sunk into the ground needs a positive number (half its height, about 1.3, if its origin is in the
        -- middle); one that floats needs a negative number.
        dropZOffset = 0.0,

        -- Where the prize containers wait: container 1 uses the first line, container 2 the second...
        -- mapModel = the real harbour container standing there; it is hidden while the event runs and ours
        -- replaces it. Stand next to a container in game and run /cwspot to print a line to paste here.
        -- A container with no line is simply lowered by the crane from above the drop spot.
        pickups = {
            { x = 917.3794, y = -3093.3625, z = 14.3277, heading = 89.7916 },
            { x = 932.4832, y = -3096.3882, z = 17.1478, heading = 91.4734 },
            { x = 945.3083, y = -3096.1270, z = 14.3277, heading = 82.1003 },
            { x = 901.1194, y = -3093.3667, z = 11.5116, heading = 87.9239 },
            -- add  mapModel = 'prop_container_01a'  to a line if a real container already stands there:
            -- it is then hidden during the event and ours replaces it.
        },

        -- Dummy containers: pure decoration that makes the yard look lived-in. They are placed with holograms in
        -- the tablet (Harbour & Perimeter > Dummy containers), each one a stack of 1-6 pods, and they STAY in the
        -- world all the time — built when the resource starts, whether or not an event is running. They have
        -- nothing to do with the auctioned containers.
        dummyModels = {                      -- the models the tablet offers for a dummy (any model name also works there)
            { model = 'port_xr_contpod_01', label = 'Container pod 1' },
            { model = 'port_xr_contpod_02', label = 'Container pod 2' },
            { model = 'port_xr_contpod_03', label = 'Container pod 3' },
            -- add more lines here: { model = 'port_xr_contpod_04', label = 'Container pod 4' },
        },
        dummyModel = 'port_xr_contpod_01',   -- the one a new dummy starts with
        dummyStep = 2.6,        -- metres between the pods of a stack, if the real model height could not be measured
        maxDummies = 150,        -- most dummy stacks
        maxDummyPods = 500,     -- most pods in total (every pod is a networked object)

        -- Default bidding perimeter, used when an event does not draw its own.
        zone = { points = {} },
    },

    -- The gantry crane model, described part by part. All offsets are in metres, relative to the frame.
    -- These are starting values — check them with /cwgantrytest and adjust here.
    gantries = {
        prop_dock_rtg_ld = {
            cabin = { model = 'p_dock_rtg_ld_cab', x = -0.1, z = 18.0, heading = 0.0 },  -- the trolley on top
            span = { min = -8.0, max = 8.0 },        -- how far the cabin slides across the frame (the frame is ~18 m wide)
            hookClearance = 4.9,                     -- metres from a carried container's origin up to the cabin's underside when fully raised (the spreader sits at +3.5..+4.7, so ~5.2 puts it right under the cabin with no rope showing; raise it by the same amount as the spreader's z)
            rail = { min = -60.0, max = 60.0 },      -- how far the whole crane may roll from its reference spot
            cableTopOffset = -1.0,                   -- the rope is fastened this far below the cabin's origin
            wheels = {
                model = 'p_dock_rtg_ld_wheel',
                positions = {
                    { x = -5.0, y = -9.02, z = 0.65 }, { x = -3.58, y = -9.02, z = 0.65 },
                    { x = 3.3, y = -9.02, z = 0.65 },  { x = 4.7, y = -9.02, z = 0.65 },
                    { x = -5.0, y = 9.46, z = 0.65 },  { x = -3.58, y = 9.46, z = 0.65 },
                    { x = 3.3, y = 9.46, z = 0.65 },   { x = 4.7, y = 9.46, z = 0.65 },
                },
            },
        },
    },

    -- Container models offered in the tablet.
    -- Only the models in containerModels below are auctioned: every one of them opens (the tr_prop_tr_container_* models have their own
    -- hinged doors + opening animation; prop_container_ld is a big container with a doorless end: its reward car / crate appear inside it).
    -- vehicleSafe = true: big enough to hold a reward car. A lot with a VEHICLE reward is only ever given a vehicleSafe model.
    -- opens = false: the doors of this model do not open (check with /cwopenanim). Its reward car / loot crate then stand BESIDE the
    -- container instead of inside it, so winners can still reach them.
    -- Any other container model is for the Prop Placer only; if one still reaches an auction
    -- (an old saved event) it is swapped for a working model here, or by the first-entry fallback in convoy_manager.lua.
    containerModelAlias = {
        prop_container_01a = 'tr_prop_tr_container_01a',
        prop_container_01b = 'tr_prop_tr_container_01c',
        prop_container_02a = 'tr_prop_tr_container_01a',
        prop_container_03a = 'tr_prop_tr_container_01c',
        prop_container_03b = 'tr_prop_tr_container_01f',
        prop_container_03mb = 'tr_prop_tr_container_01c',
        prop_container_04a = 'tr_prop_tr_container_01g',
        prop_container_04mb = 'tr_prop_tr_container_01g',
        prop_container_05a = 'tr_prop_tr_container_01h',
        prop_container_05mb = 'tr_prop_tr_container_01h',
        prop_container_01mb = 'prop_container_ld',   -- 01mb is a shut box that cannot open (tested); ld has a doorless end and fits a car
    },
    containerModels = {
        -- Container models with functional hinged doors and opening animation
        { model = 'tr_prop_tr_container_01a', label = 'Red Cargo Container with Doors (tr_prop_tr_container_01a)' },
        { model = 'tr_prop_tr_container_01c', label = 'Blue Cargo Container with Doors (tr_prop_tr_container_01c)' },
        { model = 'tr_prop_tr_container_01f', label = 'Green Cargo Container with Doors (tr_prop_tr_container_01f)' },
        { model = 'tr_prop_tr_container_01g', label = 'Orange Cargo Container with Doors (tr_prop_tr_container_01g)' },
        { model = 'tr_prop_tr_container_01h', label = 'Yellow Cargo Container with Doors (tr_prop_tr_container_01h)' },
        { model = 'tr_prop_tr_container_01i', label = 'Steel Cargo Container with Doors (tr_prop_tr_container_01i)' },
        -- Large container: opens with the fitted door props (see openContainer.doors); the one used for vehicle rewards
        -- Big container (12.2 m, tested in game with /cwprobe + /cwopentest): one end is open, so the reward car / loot crate that appear
        -- when a winner opens the lot are simply there to see. The door props (prop_container_door_mb_*) are far too small for it: not used.
        -- openEnd = 'back': the open end is the model's back (-Y) end, so a reward car is turned to face it and can drive straight out
        -- (checked with /cwcartest ... flip). Leave it out for a model whose open end is at the front.
        { model = 'prop_container_ld', label = 'Large Open-End Container (prop_container_ld)', vehicleSafe = true, openEnd = 'back' },
    },
    -- ── Bidding window & anti-spam ─────────────────────────────────────────────
    -- E on a container opens the bidder window on the left of the screen. The server
    -- is the only authority on bids; these values only tune how forgiving it is.
    bidding = {
        bidDistance = 12.0,             -- how close to the container you must be to press E
        windowCloseDistance = 16.0,     -- the open bidder window closes if you walk further than this
        debounceMs = 400,               -- client: minimum gap between E presses / Confirm clicks
        requestTimeoutMs = 5000,        -- client: give up waiting for the server (shows 'Bid request timed out')
        rejectShowMs = 2000,            -- how long the E hint shows BID REJECTED before going back to PLACE BID
        serverMinGapMs = 300,           -- server: per player, per container — faster bid requests are dropped
        bidCooldownSeconds = 6,         -- after a player's bid is accepted they must wait this long before bidding again (server-enforced; 0 = off)
        feedbackDistance = 80.0,        -- metres: the bid sound / effect on a new bid only plays for players this close to the container (or with its bidder open)
        staleMessage = 'Bid is no longer valid. Current bid has changed.',
    },
    -- ── Hook ───────────────────────────────────────────────────────────────────
    -- The grabber and the cable that hang from the crane arm. They come down onto each container,
    -- ride up with it, and rise back after it lands. Offsets are in metres from the CONTAINER's
    -- origin (x east, y north, z up); heading is added to the container's. Tune them with
    -- /cwhooktest and /cwhookset (client/modules/container_wars.lua), then paste the printed lines here.
    hook = {
        enabled = true,
        cableMode = 'LINES',
        rope = {
            width = 0.07,                 -- metres, thickness of each cable
            color = { 14, 14, 14 },
            drawDistance = 220.0,         -- only drawn for players closer than this
            lengthFactor = 0.43,          -- how far out along the spreader the cables hang (0 = middle, 1 = its very ends); raise to spread them, lower to bring them in
            sink = 0.35,                  -- metres the cable ends sink into the spreader's roller blocks
        },
        cableSegmentLength = 11.7,
        cableTop = 5.8,
        cableOverlap = 3.0,
        parts = {
            { model = 'p_dock_crane_sld_s', x = 0.0, y = 0.0, z = 3.20, heading = 0.0 },   -- was 2.30 (sat inside the container), then 3.50 (left a small gap above the container): 3.20 closes the gap, the container rides ~0.3 m closer to the hook
            { model = 'p_dock_crane_cabl_s', x = 0.0, y = 0.0, z = 4.4, heading = 0.0, cable = true },
        },
    },

    -- A lot whose reward is a car (and nothing else). It stands in its container as a dummy crate while it is auctioned; the car is
    -- created only once the winner is confirmed. The winner presses E at it (keys + garage record), or after `seconds` the server
    -- puts it into the winner's garage and removes the world copy. All of it is decided on the server.
    vehicleClaim = {
        seconds = 120,          -- how long the winning bidder has to claim the car
        maxDistance = 6.0,      -- server check: how close the winner has to stand to claim it
        retrySeconds = 10,      -- if the garage / database refuses the record, try again this often...
        retries = 6,            -- ...this many times (then it is logged, and tried again at the next resource start)
    },

    -- The loot crate inside an opened container.
    lootCrate = {
        enabled = true,
        model = 'prop_box_wood05a',  -- realistic wooden cargo shipping crate inside the container (no gun/ammo crate)
        offset = { x = 0.0, y = 0.0, z = 0.0 },
        depth = 4.2,                 -- metres in from the container's open end (bigger = deeper inside)
        turn = 0.0,                  -- degrees the crate is turned: 0 = its labelled face toward the open end (you), 90 = long side along the container (more room to walk past)
        floorLift = 0.32,            -- how far above the floor the crate's origin sits (lower it if it floats, raise it if it sinks)
        slots = 30,
        weight = 400000,
        targetLabel = 'Search Loot Crate',
        targetIcon = 'fa-solid fa-box-open',
        targetDistance = 2.5,
    },

    -- Winners open the container itself with ox_target ("Open Container").
    openContainer = {
        label = 'Open Container',
        icon = 'fas fa-door-open',
        targetDistance = 3.5,           -- ox_target interaction distance
        maxDistance = 9.0,              -- server check: how far the opener may be
        walkInWhenOpen = true,          -- an opened container has no collision, so players can walk in (the model keeps the shut doors' collision otherwise: an invisible wall at the entrance). false = solid walls, entrance blocked
        durationSeconds = 11.5,         -- length of realistic angle grinder lock-cutting scene
        anim = { dict = 'anim@scripted@player@mission@tunf_train_ig1_container_p1@male@', clip = 'action' },
        doors = {
            useVariants = false,        -- Respect exact container model chosen in the tablet setup
            left = { model = 'prop_container_door_mb_l', flip = false },
            right = { model = 'prop_container_door_mb_r', flip = false },
            -- ONLY the models that have no doors of their own get the two door props fitted. The tr_prop_tr_container_* models
            -- already have hinged doors and their own opening animation: listing them here fitted a second pair of doors on top of
            -- them (the loose steel slabs seen on a container before it was opened). They open with that animation instead, and the
            -- opened pose is held (container_wars_fx.lua).
            models = {
                -- (empty on purpose: the door props are small plates that fit none of the big containers; see containerModels)
            },
            variants = {
                prop_container_01a = 'tr_prop_tr_container_01a',
                prop_container_01b = 'tr_prop_tr_container_01c',
                prop_container_02a = 'tr_prop_tr_container_01a',
                prop_container_03a = 'tr_prop_tr_container_01c',
                prop_container_03b = 'tr_prop_tr_container_01f',
                prop_container_04a = 'tr_prop_tr_container_01g',
                prop_container_05a = 'tr_prop_tr_container_01h',
            },
            openAngle = 110.0,
            swingSeconds = 2.4,
            zOffset = 0.0,              -- raise / lower the hinges relative to the container's base
            atFront = false,            -- true = hinges on the container's front end instead of the back
            backOffset = nil,           -- hinge distance from the container origin along its length (nil = the model's back end)
        },
    },

    -- ── Vehicle Claim & Staging Teleport ──────────────────────────────────────
    -- When a player wins and claims a vehicle container reward, they are warped inside the vehicle
    -- and teleported here so they are safely out of the active crane/auction area.
    stagingCoords = { x = 794.5, y = -3000.2, z = 5.9, heading = 90.0 },
    vehicleSafeCoords = { x = 794.5, y = -3000.2, z = 5.9, heading = 90.0 },

    -- ── Bidding Perimeter ─────────────────────────────────────────────────────
    -- The polygon itself is drawn per event in the tablet (or comes from harbour.zone).
    biddingZone = {
        thickness = 30.0,               -- height of the 3D zone, in metres
    },

    -- ── 3D World Visuals & Winning State ───────────────────────────────────────
    visuals = {
        show3DWorldMarker = true,       -- Show the gold winner chevron over a won container (the info panel is always shown)
        drawDistance = 75.0,            -- Maximum distance in meters the container info panel is shown (increased for dock visibility)
        infoHeight = 3.6,               -- Metres above the container where the info panel's pointer sits
        winningMarkerType = 2,          -- 2 = downward pointing chevron marker / trophy
        winningColor = { r = 255, g = 215, b = 0, a = 220 }, -- Gold highlight
    },

    -- ── Crane audio ───────────────────────────────────────────────────────────
    -- The gantry crane makes a winch / rumble loop while it works and a thump + clank when a container lands.
    -- Two layers: the game's own sounds (they need audio banks that are not always loaded, and when they are
    -- not the game stays silent) and a synthesised crane sound made by the tablet page, which always plays.
    -- /cwcranesound plays every stage at your feet to check; the F8 console says whether each bank loaded.
    craneAudio = {
        synth = true,                -- the synthesised crane sound (always audible). false = game sounds only
        native = true,               -- the game's own sounds (silent if their bank is missing)
        volume = 0.40,               -- balanced volume (lowered from 1.0 to avoid loud noise)
        maxDistance = 150.0,         -- metres: beyond this the crane cannot be heard
        banks = { 'DOCKS_HEIST_SOUNDS', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS' },
        sounds = {
            hoist = { name = 'DOCK_CRANE_LOOP', bank = 'DOCKS_HEIST_SOUNDS' },
            drop = { name = 'CONTAINER_LAND_HEAVY', bank = 'DOCKS_HEIST_SOUNDS' },
            winch = { name = 'WINCH_LOOP', bank = 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS' },
        },
    },

    -- ── Audio & Sound Effects ─────────────────────────────────────────────────
    sounds = {
        winSound = { name = 'Challenge_Passed', bank = 'HUD_AWARDS' },
        roundStartSound = { name = 'TIMER_STOP', bank = 'HUD_MINI_GAME_SOUNDSET' },
    },

    -- ── Example auction (reference copy of the tablet's "Load Example Auction") ──
    -- Names, models, bids and rewards only. Positions are NOT part of it: set them per event.
    defaultOceanDocksPresets = {
        containers = {
            {
                name = 'Container #1 — High-Grade Contraband',
                model = 'tr_prop_tr_container_01a',
                startingBid = 10000, minBidIncrement = 2500, auctionDuration = 45,
                rewards = { { type = 'MONEY', amount = 80000 }, { type = 'ITEM', amount = 1, pool = 'weapon_assaultrifle' } },
            },
            {
                name = 'Container #2 — Weapons Cache',
                model = 'tr_prop_tr_container_01c',
                startingBid = 15000, minBidIncrement = 2500, auctionDuration = 45,
                rewards = { { type = 'MONEY', amount = 100000 }, { type = 'ITEM', amount = 2, pool = 'weapon_carbinerifle' } },
            },
            {
                name = 'Container #3 — Armored Muscle Vehicle',
                model = 'tr_prop_tr_container_01f',
                startingBid = 25000, minBidIncrement = 5000, auctionDuration = 50,
                rewards = { { type = 'VEHICLE', model = 'dominator3', pool = 'Dominator GTX' } },
            },
            {
                name = 'Container #4 — Mystery Jackpot Crate',
                model = 'tr_prop_tr_container_01g',
                startingBid = 30000, minBidIncrement = 5000, auctionDuration = 60,
                rewards = { { type = 'MONEY', amount = 200000 }, { type = 'ITEM', amount = 5, pool = 'armor' } },
            },
        },
    },
}


-- ── Container Wars — Physical Vehicle Rewards & Pickup Interaction ──────────────────

Config.VehicleRewards = {
    defaultMode = 'GARAGE',
    garage = 'motelgarage',          -- the garage a GARAGE-mode car is stored in (a garage name of qbx_garages / qb-garages)
    platePrefix = 'CW',              -- plates are this + random digits, e.g. CW482913 (max 8 characters in all)
    -- Keys for a spawned car: 'auto' (qbx_vehiclekeys, or QB-Core's vehiclekeys when that is what runs), 'qbx_vehiclekeys',
    -- 'qb-vehiclekeys', 'custom' (any other key script: fill in GiveKeys in bridge/vehicles/custom.lua) or 'none'.
    keys = 'auto',
    -- Where an owned (GARAGE-mode) car is stored: 'auto' (qbx_vehicles, else the framework's own table: QB-Core
    -- player_vehicles / ESX owned_vehicles), 'custom' (any other garage script: AddToGarage in bridge/vehicles/custom.lua)
    -- or 'none' (garage rewards off — those cars are spawned beside the container instead).
    garageProvider = 'auto',
    -- shown as suggestions in the reward editor (any other model name can be typed): { model, label }
    suggestions = {
        { model = 'sultanrs',   label = 'Sultan RS' },
        { model = 'jester',     label = 'Jester' },
        { model = 'comet2',     label = 'Comet' },
        { model = 'zentorno',   label = 'Zentorno' },
        { model = 'adder',      label = 'Adder' },
        { model = 'dominator3', label = 'Dominator GTX' },
        { model = 'buffalo2',   label = 'Buffalo S' },
        { model = 'kuruma',     label = 'Kuruma' },
        { model = 'rebla',      label = 'Rebla GTS' },
        { model = 'hellion',    label = 'Hellion' },
        { model = 'sandking',   label = 'Sandking XL' },
        { model = 'bati',       label = 'Bati 801 (bike)' },
        { model = 'sanchez',    label = 'Sanchez (dirt bike)' },
        { model = 'insurgent2', label = 'Insurgent' },
        { model = 'mesa3',      label = 'Merryweather Mesa' },
        { model = 'sultan3',    label = 'Sultan Classic' },
        -- add your own / addon cars here, e.g. { model = 'mycar', label = 'My Custom Car' },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- SECTION 3: EVENT — ARMORED CONVOY
-- Police Escort vs Gang Ambush, Heavy Trucks, Checkpoints, Barricades & Stash Loot
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── Convoy System Limits & Participant Capacity ─────────────────────────────
Config.MaxConvoys            = 30
Config.MaxTrucksPerConvoy    = 10
Config.MaxCheckpoints        = 20
-- How a gang signs up for each kind of event (Event Status panel, Events tab):
--   Hot Cargo, Gang Airdrop, Operation Crackdown   no registration at all (open to everyone / decided by the server)
--   Container Wars, Gang Territory Auction          the GANG registers with one click (no member list); every member of a registered gang may bid
--   Convoy, Rally Race, TDM                         the leader (or a role with "register roster") picks the members who take part
-- required = false: an auction no longer needs a registered gang to bid (any eligible gang may bid, as before).
Config.AuctionRegistration = { required = true }

Config.MaxGangParticipants   = 35
Config.MaxPoliceParticipants = 35

-- ── Convoy Route Rules & Checkpoint Defaults ────────────────────────────────
Config.DefaultCheckpointRadius   = 80.0
Config.DefaultCheckpointWaitTime = 60

-- Police see every checkpoint's and the destination's map sprite for the
-- whole convoy, from the moment it departs — full tactical overview, not
-- discovered progressively like gang does. Gang still only sees each
-- checkpoint once the trucks actually arrive there, and only sees the
-- destination once the lead truck gets this close to it (meters) — see the
-- destinationProximityGang/destinationProximityPolice banners above for the
-- matching heads-up announcements fired at that same moment. Airdrop zones
-- are unaffected by either of these — always gang-only, only once triggered.
Config.PoliceAlwaysSeeRouteZones       = true

-- Race-style route guidance for police / admins (needs PoliceAlwaysSeeRouteZones). The next point of the convoy's route
-- carries a flashing blip with a GPS line, so officers follow the route the convoy actually drives instead of cutting
-- across town; passed points drop off the map. Sprites/colours per point type are in Config.MapBlips.policeRoute.
Config.PoliceRouteBlips = {
    gps               = true,   -- GPS line to the next route point (moves on as the convoy passes each point)
    waypoints         = true,   -- light-yellow dots for the next plain route points on the road (race style). false = only stages and the GPS line
    waypointLookahead = 10,     -- how many upcoming plain route points get a dot
}

-- ── Checkpoint beacon ──────────────────────────────────────────────────────────────
-- A tall pillar of light from the sky down to the ground on every convoy checkpoint (a ground ring marks the zone), so
-- the spot the convoy will stop on can be seen in the world, not only on the map. Police / admins see every checkpoint's
-- beacon from the moment the convoy departs; the checkpoint the convoy is HOLDING at lights up for everyone taking part
-- (gangs included). showToGangsFromStart = true also gives gangs every beacon from departure (it reveals the route).
Config.CheckpointBeacon = {
    enabled              = true,
    showToGangsFromStart = false,
    color                = { r = 255, g = 215, b = 0 },     -- idle / upcoming checkpoint (Dragon Ball Gold)
    activeColor          = { r = 255, g = 180, b = 20 },    -- active checkpoint holding area (Super Saiyan Vibrant Gold Aura)
    beamHeight           = 600.0,                            -- metres of the pillar
    beamWidth            = 2.4,                              -- slender, refined golden beam (reduced thickness)
    drawDistance         = 1500.0,                           -- not drawn when the player is farther than this
}

-- How trucks behave on a checkpoint. They are not moved by script: each drives to the marker on its own route, stops
-- there and is held where it stands, then leaves one at a time when the timer ends.
-- How the convoy NPC trucks follow the route you built.
--   'ROUTE' (default) The route AS YOU BUILT IT. A truck is never handed to the road network (which at a ramp, a split carriageway or a
--           slip lane chooses the road IT prefers). It drives to a point a short way down the drawn leg, then on to the next, so it
--           stays on the line through ramps, left/right lanes and diverts. Trucks still brake for traffic and steer round blockers.
--           Route points should therefore be drawn along the lane the trucks should use.
--   'AUTO'  Trucks use the game's road network, on the correct side. A route point on the OTHER side of the road is
--           detected and the truck crosses over and drives against the flow to reach it; a point beside the lane is aimed
--           at the nearest lane. Before each order the truck asks the game whether the roads join it to the point; if they
--           do not (split carriageway, median, one-way ramp) or only the long way round, it drives the drawn route straight across.
--   'EXACT' Trucks drive the route exactly as drawn: point to point in a straight line, in any lane, ignoring road
--           direction and lane rules (they still steer around cars, peds and props). Use it when the road network keeps
--           failing to path (one-way ramps, split carriageways, off-road shortcuts). Route points should be close together.
--   'ROADS' Only the game's road network, same side, no crossing over (the pre-2026-10-10 behaviour).
Config.TruckRouteFollowing = 'ROUTE'
-- ROUTE mode: how far down the drawn line (metres) a truck aims. It grows with the truck's speed (15 m + 2.5 x speed in m/s) between these two.
Config.TruckRouteLockHopMin = 25.0   -- shorter hops: a straight hop across a bend of the route cuts the corner (a bridge rail, a ramp edge)
Config.TruckRouteLockHopMax = 55.0
-- In AUTO a truck may cut straight across to a route point the roads only reach the long way round, but only when the point is
-- this close (metres): a median / split carriageway. A farther point is left to the roads, so a point drawn off-road no longer
-- sends the convoy across open ground.
Config.TruckStraightAcrossMax = 80.0
-- true (default) = the NPC driver holds its lane and follows the route point to point: it brakes behind traffic and steers
-- around a stopped blocker, but does not weave or pull into the oncoming lane to pass (that looked like random lane changes).
-- false = the old "overtake like a human" style (swerving + oncoming lane). Crossing to an opposite-side route point still works either way.
Config.TruckLaneDiscipline = true
-- Road-following trucks are sent along the drawn route in hops of about this many metres (0 = off, one order per route point).
-- One order to a route point hundreds of metres away lets the game choose ITS OWN road to it, which at a junction can be a
-- side street that is "shorter" than the straight road the route was drawn along. With a hop only this far ahead, on the
-- line between the two route points, the road that continues the line is the only sensible way to the hop.
Config.TruckRouteHop = 110.0
-- Follow the LANE the route was drawn in. A route point that lies in a lane (within TruckDrawnLaneMax metres of the road's own lane line)
-- used to be moved to the lane the game thinks is the right one, so a route drawn down the left or the right lane of a wide road, or
-- around a divert, was driven in whatever lane the AI preferred. Now the truck is driven to the drawn point itself, in short hops of
-- TruckDrawnLaneHop metres along the drawn line. A point further off the road than TruckDrawnLaneMax (a shoulder, a pavement) is still
-- moved onto the road. false = the old behaviour.
Config.TruckFollowDrawnLane = true
Config.TruckDrawnLaneMax = 7.0
Config.TruckDrawnLaneHop = 40.0

-- THE SCRIPT NEVER MOVES A CONVOY TRUCK (default false). A convoy is only a convoy when its trucks really drive: no teleporting a truck
-- back onto the route, no sliding it along when it stands still, no nudging one that nobody is near. When this is false the three
-- helpers below (StuckSlide, RouteRecoveryDistance and the "nudge an unobserved truck" step) are OFF whatever their own values are.
-- true = bring those helpers back (they exist only as an emergency measure for a route the AI can never drive).
Config.TruckScriptMoves = false

-- A convoy truck is driven by the AI of a PLAYER'S client (the server has no driving of its own). With nobody within TruckCullingRadius (below) -
-- any player, police or not - it has no owner and stands still. true = such a truck is advanced along its route by the server (a straight slide,
-- ~every 2 s), which nobody can see; the moment a player comes within range the AI takes it back. Only when the convoy has "Require Police Escort
-- Proximity" OFF. false = an unwatched truck simply waits until someone is near.
Config.TruckAdvanceUnobserved = true

-- Last resort (only when TruckScriptMoves = true): after 20 s standing still (8 s after the first time) the server slides the truck
-- along the drawn route for 6 s, then hands it back.
Config.StuckSlide = true

-- Only when TruckScriptMoves = true: a truck more than this many metres off the drawn route for 8 checks in a row is put back on the route (0 = off).
Config.RouteRecoveryDistance = 120.0

-- Rescue of a truck that is LOST (works with TruckScriptMoves = false): a truck that fell off a bridge into a ditch, or is stranded far from the
-- drawn route, and stands / crawls (under 2 m/s) for `seconds` is put back on the nearest point of the drawn route. 'offRouteMeters' = how far
-- from the route it counts as lost; 'belowMeters' = how far below / above the route (a truck under a bridge is only a few metres off in
-- the map, but 8 m lower). A truck that is merely taking a corner badly is never touched. enabled = false: trucks are never moved.
Config.TruckRescue = { enabled = true, seconds = 20, offRouteMeters = 40.0, belowMeters = 6.0 }
-- A convoy truck (and its driver) stays streamed to - and driven by - any player within this many metres. Without it a
-- truck left behind by the column, out of everyone's normal range, has no owner and its AI stops ("NOBODY SIMULATES").
Config.TruckCullingRadius = 1500.0

Config.CheckpointRelease = {
    startInCircle      = true,   -- the checkpoint starts (trucks slow down, settle on the marker, then the timer runs) the moment the first truck is inside the checkpoint's own circle. false: only within 35 m of the marker
    parkRadius         = 15.0,   -- a truck this close to the marker, and almost stopped, is frozen there (it also parks when stopped in the zone behind another truck)
    parkInCircle       = false,  -- true: freeze trucks at the circle's edge instead of letting them settle on the marker
    arrivalWaitSeconds = 600,    -- the checkpoint (banners, hold timer, attack window) only starts once EVERY cargo truck is on the marker; trucks that arrive first wait parked for the rest. Safety limit in seconds if a truck never arrives (0 = wait with no limit)
    staggerSeconds     = 1.0,    -- gap between one truck leaving the checkpoint and the next (0 = all at once)
    requirePoliceInCircle = true, -- the checkpoint hold timer only runs while at least one living on-duty officer is inside the checkpoint circle (no officer online = no rule). The convoy therefore cannot be pushed through a stage without an escort there
}
Config.DestinationProximityWarningDistance = 120.0
-- Delivery safety nets (Config.DeliveryRadius below is the normal arrival circle): a truck this close that has slowed down is
-- delivered, and so is one that stood still for DeliveryStallSeconds anywhere within DeliveryStallRadius of the destination.
-- Kept tight on purpose: trucks drive right up to the destination marker and are delivered THERE, not a street away.
-- An NPC-driven truck is delivered ONLY when it has driven onto the destination mark and stands there: inside the ring (DeliveryRadius
-- below) and almost still (DeliveryStandSpeed m/s) for DeliveryStandSeconds. Nothing delivers it before that. The two "close enough"
-- nets below are therefore OFF (0); set a distance to bring one back (a truck that stopped that close, or stood still that close, is
-- delivered even though it never reached the mark - for a marker the road cannot reach).
Config.DeliveryStandSeconds = 2.0
Config.DeliveryStandSpeed   = 1.5
Config.DeliveryNearRadius   = 0
Config.DeliveryStallRadius  = 0
Config.DeliveryStallSeconds = 8
-- A truck is delivered automatically (removed + "Truck Delivered" banner) as
-- soon as it drives within this many metres of the DESTINATION marker. A
-- truck parked still within DeliveryNearRadius / DeliveryStallRadius also counts, for markers the
-- road can't quite reach. The convoy ends once every cargo truck is resolved.
Config.DeliveryRadius = 20.0

-- Tactical barrier props spawned at active checkpoints


-- ── Armored Convoy Truck Durability & Driver Restrictions ───────────────────────────

Config.DefaultTruckHealth        = 15000.0 -- Armored fortress: absorbs thousands of rifle bullets
Config.DefaultEngineHealth       = 5000.0
-- How much of the damage a convoy truck takes is applied (bullets, collisions): 1.0 = full, so the truck's Health value in the
-- convoy settings is what decides how tough it is and the health bar follows the real damage. It used to be hard-wired to
-- 0.05 / 0.25, which made a truck lose almost nothing whatever health it was given. Lower it to make every truck sturdier.
Config.TruckDamageModifier       = 1.0
-- Distance (metres) from which a convoy truck's floating name + health bar is shown.
Config.TruckLabelRange           = 90.0
-- How fast the number above a truck follows its real health, in percentage points per second: the readout counts down 99, 98, 97 ...
-- to the real value (and to 0 when the truck is disabled) instead of jumping. Higher = snappier, 0 = no smoothing.
Config.TruckHealthBarSpeed       = 30.0
-- Closed-gate detection for the NPC-driven trucks: a truck slows down for a closed gate ahead, stops short of it, waits (hooting now and
-- then) and drives on the moment it opens. After TruckGateWaitSeconds it gives up waiting and drives on (a gate that never opens).
-- Only real gates count: large fixed objects. Placed props and decoration of the event, loot crates, cones and small debris do not.
Config.TruckGateDetection        = true
Config.TruckGateWaitSeconds      = 12.0
-- Only police and administrators may sit in a convoy truck's driver seat (the NPC
-- driver, or the officer at the wheel of a player-driven truck). Anyone else who
-- takes the wheel is moved out. Disabled/captured trucks are exempt.
Config.ConvoyDriverPoliceOnly = true
Config.DefaultTruckSpeed         = 0.6 -- cruise speed multiplier (0.2 to 2.0)


-- ── Convoy Formation Spacing & Lead Truck Pacing ────────────────────────────────────

Config.ConvoySpacing = {
    -- Minimum gap between trucks (metres). 18m = safe for all 10-12m military rigs.
    baseSpacing = 18.0,
    -- Extra metres added per additional truck (keeps long convoys from spreading too far).
    scalePerTruck = 1.1,
    -- Hard maximum gap cap in metres (prevents 10-truck convoys from sprawling into side-streets).
    maxSpacing = 30.0,
}

-- Convoy truck heavy armor & anti-ram physics


-- ── Heavy Armored Truck Physics & Ramming Resistance ────────────────────────────────

Config.TruckPhysics = {
    enabled = true,
    mass = 45000.0,          -- Heavy mass prevents trucks from being pushed or rammed off road
    gravityAmount = 25.0,     -- Extra downforce/gravity to stick truck firmly to the road
    centerOfMassZ = -0.5,     -- Lower center of mass prevents tipping and rollover
    strongVehicle = true,     -- Resists chassis deformation and keeps axles strong
    antiRollWatchdog = true,  -- Automatically uprights truck if forced into extreme tilt
}

-- ── Map Blip Sprites & Colours ────────────────────────────────────────────────
-- Configurable blip appearance for every marker type.
-- Change sprite IDs and colours here — no runtime code changes needed.
--
-- SPRITE QUICK-REFERENCE (https://docs.fivem.net/docs/game-references/blips/):
--   1   = radar_level         (plain dot)
--   4   = radar_wanted_radius (radius zone outline)
--   9   = radar_radius_blip   (filled radius zone)
--   60  = radar_police_car    (police car)
--   84  = radar_enemy_heli    (danger skull)
--   272 = radar_police_station(police shield/building)
--   352 = radar_coke          (checkpoint star)
--   407 = radar_corona_launch (parachute/airdrop)
--   417 = radar_military      (military star)
--   421 = radar_fort_zancudo  (army/base crest)
--   477 = radar_truck         (heavy transport truck)
--   478 = radar_truck_open    (truck at destination flag)
--   501 = radar_crate_drop_bg (supply crate, airdrop)
--
-- COLOUR QUICK-REFERENCE (SetBlipColour):
--   0=White  1=Red   2=Green  3=Blue   5=Yellow
--   25=DarkBlue  27=Orange  38=Purple  42=DarkGreen


-- ── Tactical Checkpoint Barricades & Prop Definitions ───────────────────────────────

Config.CheckpointBarricades = {
    enabled = true,
    defaultMode = 'random', -- 'random' (script places around radius) or 'manual' (admin placed props)
    defaultModel = 'prop_barrier_work05',
    count = 6,
    ringRadiusFactor = 0.55,
}

-- Extensible list of props available for checkpoint barricade setup.
-- Developers can add custom props here with id, label, model, and category.
Config.CheckpointBarricadeProps = {
    { id = 'barrier_work', label = 'Road Work Barrier', model = 'prop_barrier_work05', category = 'barricade' },
    { id = 'barrier_wood', label = 'Wooden Barrier', model = 'prop_barrier_work06a', category = 'barricade' },
    { id = 'barrier_jersey', label = 'Concrete Jersey Barrier', model = 'prop_barier_conc_05c', category = 'barricade' },
    { id = 'traffic_cone', label = 'Standard Traffic Cone', model = 'prop_roadcone02a', category = 'cone' },
    { id = 'traffic_cone_tall', label = 'Tall Traffic Cone', model = 'prop_roadcone01a', category = 'cone' },
    { id = 'military_block', label = 'Military Concrete Block', model = 'prop_barrier_conc_01a', category = 'military' },
    { id = 'military_sandbags', label = 'Military Sandbag Wall', model = 'prop_sandbag_02', category = 'military' },
    { id = 'military_fence', label = 'Security Perimeter Fence', model = 'prop_fncsec_04crnr1', category = 'military' },
}


-- ── Ped models used when nothing more specific is set ─────────────────────────────
-- Every vendor / event ped has its own pedModel in its section below (Escort Shop, Police Equipment, Token Vendor, Race
-- Vehicle Shop, TDM weapon vendor, Practice Range, Territory leader). These are the models for the peds that have no section
-- of their own, and the fallbacks the scripts use when a saved ped has no model.
Config.Peds = {
    thug         = 'g_m_y_mexgoon_01',  -- TDM weapon vendors + the Practice Range instructor (street-gang look, not police)
    convoyStart  = 's_m_y_cop_01',      -- the police-gated convoy start ped
    raceStart    = 'g_m_m_chicold_01',  -- the Gang Rally start ped
    civilianRace = 'a_m_y_runner_01',   -- the registered civilian ped of a race
    civilianDock = 's_m_m_dockwork_01', -- the registered civilian ped of every other event
    territoryLeader = 'g_m_y_mexgoon_01', -- default Territory leader ped
}

-- ── Police Escort Vehicle Shop ──────────────────────────────────────────────────────

Config.EscortVehicleShop = {
    enabled = true,
    -- Health of a police escort vehicle taken from the shop ped (1000 = a stock car). The convoy's own "Escort Vehicle Health" setting
    -- overrides this. Escort vehicles also get unpuncturable tyres, a strong body and an armoured fuel tank; they have no health bar.
    health = 5000.0,
    pedModel = 's_m_y_cop_01',
    pedCoords = vec4(452.6, -981.2, 30.6, 90.0), -- Mission Row PD motor pool
    moneyAccount = 'cash',
    vehicles = {
        { label = 'Police Cruiser', model = 'police', price = 0 },
        { label = 'Police SUV', model = 'police3', price = 0 },
        { label = 'Police Motorcycle', model = 'policeb', price = 0 },
        { label = 'Police Riot', model = 'riot', price = 0 },
        { label = 'RCV (Riot Control Vehicle)', model = 'rcv', price = 0 },
        { label = 'Barracks', model = 'barracks', price = 0 },
        { label = 'Police Crusader', model = 'crusader', price = 0 },
    },
}

-- ── Police Equipment & Tactical Field Armory ────────────────────────────────

Config.PoliceEquipment = {
    enabled = true,
    pedModel = 's_m_y_cop_01',
    pedCoords = vec4(441.6, -982.0, 30.6, 90.0), -- Mission Row PD front entrance
    moneyAccount = 'cash', -- 'cash' or 'bank'
    items = {
        { label = 'Smoke Grenade', weapon = 'WEAPON_SMOKEGRENADE', ammo = 1, price = 5 },
        { label = 'Flashbang', weapon = 'WEAPON_BZGAS', ammo = 1, price = 5 },
    },
}

-- ── Captured Convoy Truck Stash Loot ─────────────────────────────────────────

-- Capacity of the Hot Cargo drop-off crate (the convoy truck cargo stash is Config.CapturedTruckLoot below).
Config.HotCargoStashSlots  = 100
Config.HotCargoStashWeight = 300000 -- grams

Config.CapturedTruckLoot = {
    enabled = true,
    slots = 100,
    weight = 300000, -- grams (ox_inventory); 300 kg
    items = {
        { item = 'lockpick', count = 1 },
    },

    requireLockpick = true,
    lockpickItem = 'lockpick',
    skillCheckDifficulty = { 'easy', 'easy', 'medium' },
    lockpicksRequired = 1,
    policeBypass = true,    -- true = on-duty police and admins open the cargo stash directly (no lockpick item, no minigame); false = they pick the lock like a gang
    inspectLiveTrucks = true, -- true = police/admins get an "Inspect Truck Cargo" ox_target prompt on a convoy truck that is still running (no lockpick, no minigame)
    -- Plain base-game crate (no DLC streaming dependency).
    destroyedProp = 'prop_box_wood05a',
}

-- ── Convoy Announcement Timers & Stand-Down ─────────────────────────────────

-- Default delay (in seconds) before broadcasting convoy departure server-wide
Config.ConvoyStartAnnounceDelaySeconds = 60

-- How long before a SCHEDULED event's due time to fire a "starting soon"
-- banner (server-wide) built from its General tab's Announced Start/End
-- Time + Custom Announcement Message — applies to CONVOY, HOT_CARGO, and
-- GANG_AIRDROP alike. 0/nil disables this pre-announce entirely (the event
-- still auto-starts on schedule either way, this is purely a heads-up).
Config.PreScheduleAnnounceSeconds = 300

-- Convoy End Stand-Down Banner Configuration (also aliased in Config.AnnouncementBanners.standDown)
Config.ConvoyEndStandDown = {
    enabled = true,
    title = '🚚 Stand Down',
    body = 'All convoy operations completed. Area is clear.',
    duration = 8000,
    kind = 'info',
}



-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 4: EVENT — HOT CARGO HEIST
-- Covert Contraband Runs, Semi-Truck Hijacking, Police Pursuits & Salvage Drops
-- ═══════════════════════════════════════════════════════════════════════════════════

Config.HotCargoTheft = {
    enabled = true,
    requireLockpick = true,
    lockpickItem = 'lockpick',
    -- On QBX/QBCore the lockpick ITEM is owned by the vehicle-keys script, which runs
    -- ox_lib's generic skill check on any locked vehicle. true = this resource takes the
    -- item over: used at a Hot Cargo truck / broken-down truck / loot crate it runs OUR
    -- minigame, used anywhere else it behaves exactly as before.
    takeOverLockpickItem = true,
    skillCheckDifficulty = { 'easy', 'medium', 'medium' },
    -- Hot cargo trucks are as tough as convoy trucks (nil = Config.DefaultTruckHealth /
    -- Config.DefaultEngineHealth). Set a number to override just for hot cargo.
    truckHealth = nil,
    engineHealth = nil,
    -- A truck never blows up from damage: when its health drops to this % of max it
    -- BREAKS DOWN instead (engine dead, locked, can't be delivered). A banner tells
    -- everyone, and the run continues with the remaining trucks.
    breakdownHealthPct = 8,
    -- The delivery reward set in the form is the MAXIMUM. On delivery it is scaled by
    -- the truck's real health (the same % the on-screen health card shows), e.g. a
    -- $50,000 reward at 20% health pays $10,000. Set false to always pay the full amount.
    rewardScalesWithHealth = true,
    -- Also scale ITEM rewards (count x health %, never below 1 while the truck is alive).
    -- false = items are always paid in full and only money scales.
    scaleItemRewards = true,
    -- Vehicle protection (applied by whichever client owns the truck). The truck stays
    -- damageable and still breaks down at breakdownHealthPct — none of this makes it
    -- invulnerable, and none of it ever protects a player who is out of the truck.
    protection = {
        bulletproofTyres = true,   -- tyres can't be shot out (truck AND its trailer)
        reinforcedWindows = true,  -- people seated inside can't be shot through the glass
        damageModifier = 0.25,     -- body durability: lower = tougher, 1.0 = stock
    },
    -- Radius (metres) of the map circle shown over each spawn location before its truck
    -- is hijacked. The circle is offset from the truck, so it marks an area, not a spot.
    searchRadius = 150.0,
    -- Speed cap (m/s) for a player-driven Hot Cargo truck, so it drives like a heavy
    -- cargo truck (16 m/s ~ 58 km/h). Applies to whoever hijacks it. 0 = no cap.
    maxSpeed = 16.0,
    -- Vehicles offered in the Hot Cargo creator's "Contraband Vehicle" picker.
    -- To add your own truck: put its model in stream/ (see ADDON_VEHICLES.md), then add
    -- a line here with its exact spawn name. (Trucks registered in the tablet's Trucks tab
    -- -> Vehicle Catalog also show up in the picker automatically.)
    vehicles = {
        { model = 'brickade', label = 'Brickade',  note = 'Armored contraband truck' },
        { model = 'packer',   label = 'Packer',    note = 'Heavy semi tractor' },
        { model = 'benson',   label = 'Benson',    note = 'Cargo van' },
        { model = 'hauler',   label = 'Hauler',    note = 'Heavy rig' },
        { model = 'pounder',  label = 'Pounder',   note = 'Freight box truck' },
        { model = 'mule',     label = 'Mule',      note = 'Delivery truck' },
        -- { model = 'mycustomtruck', label = 'My Custom Truck', note = 'Custom addon' },
    },
    -- Tractor-unit models that tow a trailer in vanilla GTA (Hauler/Packer) —
    -- spawning just the cab looks obviously incomplete. Any model NOT listed
    -- here (Brickade, Benson, Pounder, Mule — all self-contained box
    -- trucks/vans) spawns alone as normal. Add your own tractor model here
    -- with its matching trailer to extend this.
    trailerModels = {
        hauler = 'trailers2',
        packer = 'trailers3',
    },
}



-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 5: EVENT — GANG AIRDROP CRATES
-- Cargo Plane Flyovers, Parachute Physics, Flares, Armored Crates & Contested Loot
-- ═══════════════════════════════════════════════════════════════════════════════════

Config.Airdrop = {
    prop = 'prop_box_wood05a', -- same reasoning as CapturedTruckLoot.destroyedProp above
    -- Single fixed model, used verbatim if set. Leave nil (default) to pick
    -- randomly per guard from guardModels below instead — a believable mix
    -- of GTA V mercenary/security peds rather than one repeated clone.
    guardModel = nil,
    guardModels = {
        's_m_y_blackops_01', 's_m_y_blackops_02', 's_m_y_blackops_03', -- Merryweather-style hired security
        'g_m_y_lost_01',
    },
    guardWeapon = 'WEAPON_MICROSMG',
    guardCount = 3,

    -- Radius of the zone circle shown on the map around an active drop
    -- (colour/alpha: Config.MapBlips.airdrop).
    zoneRadius = 35.0,

    -- AIRDROP route points are side events, not stops: the trucks never
    -- drive to, slow for, or wait on them. A drop fires once, when any
    -- convoy truck comes within this many metres of it (or, if it's placed
    -- further off the road than that, once the convoy reaches the next
    -- route point after it).
    triggerDistance = 250.0,

    -- Seconds the zone circle + crate stay on the map before the drop expires
    -- unlooted (a per-point/per-zone duration overrides this).
    duration = 420,

    requireLockpick = true,
    lockpickItem = 'lockpick',
    skillCheckDifficulty = { 'easy', 'easy', 'medium' },
    lockpicksRequired = 1,
    minigame = 'random',        -- 'random' or a specific game: 'lockpick', 'skillcheck', 'quicktime', 'keypad', etc.
    minigamePool = 'lockpick',   -- 'lockpick' | 'hack' | 'all'
    defaultRewards = {
        { type = 'money', amount = 15000 },
        { type = 'item', item = 'lockpick', amount = 2 },
    },

    plane = {
        enabled = true,
        model = 'cuban800',  
        flightHeight = 150.0,
        -- Flyover distance each side of the drop; flyover time = 2 * this / speed.
        approachDistance = 450.0,
        -- Plane speed in m/s.
        speed = 55.0,
        -- Seconds between the "AIRDROP INCOMING" banner (with the zone circle on the map) and the plane appearing, so players
        -- can get to the zone in time to see the flyover and the parachute drop. 0 = the plane comes at once. Total time from the
        -- banner to the crate landing = leadSeconds + (approachDistance / speed) + (parachuteHeight / descendSpeed).
        leadSeconds = 15,
        -- The flyover is drawn by each player's own game (nothing is networked or flown by anyone), for every player within this
        -- many metres of the drop. Players further away just see the plane's blip on the map.
        viewDistance = 2500.0,
        -- Ped seated as the pilot (any valid ped model).
        pilotModel = 's_m_m_pilot_02',
        parachuteHeight = 120.0,
        -- Parachute descent speed in m/s. The crate falls from flightHeight (150 m), so 8.0 ≈ 19 s, 6.0 ≈ 25 s.
        descendSpeed = 8.0,
        -- Military cargo parachute prop.
        parachuteProp = 'p_cargo_chute_s',
        -- (The crate is released at the exact moment the plane is directly above the centre of the zone, and starts falling from there.)
        -- Seconds the plane keeps flying after letting go of the crate before
        -- it is removed.
        postDropSeconds = 12,

        -- The plane's own moving map blip (see flyAirdropPlane/airdropPlaneSpawn) —
        -- shown to both police and gang for a regular convoy's in-route airdrop,
        -- gang-only for a standalone GANG_AIRDROP event (matching that kind's
        -- police-invisible design).
            blipSprite = 423, -- radar_plane
        blipColour = 5,   -- Yellow
        blipScale  = 1.1,
        label      = 'Supply Plane',

        smoke = {
            enabled = true,
            particleDict = 'core',
            particleName = 'exp_grd_bzgas_smoke',
            color = { r = 1.0, g = 0.1, b = 0.1 },
            -- Size of the red smoke column. This is a big gas-cloud effect: at 3.0 it fills the screen with overlapping particles and
            -- costs frames whenever you look at the crate. 1.5 keeps it clearly visible from a distance; raise it only if FPS allows.
            scale = 1.5,
        },
    },

    -- Seconds the flare beacon burns beside a landed, lootable crate (0 = no
    -- flare). Read as Config.Airdrop.flareDurationSeconds (client's
    -- runLootCrateFlareBeacon) — must stay at THIS level, not nested under
    -- plane{} above, or changing it here silently does nothing (it did until
    -- this was moved: the client never looked inside plane{} for it). The
    -- crate's blip and label last for the whole drop regardless.
    flareDurationSeconds = 160,

    -- ── Predefined Airdrop Locations Pool ─────────────────────────────────────────
    -- EVERY San Andreas coordinate the airdrop script picks from lives in this one list (the tablet
    -- reads it too, so "Auto-Add Zones" / "Generate Drops" and the server always agree).
    -- It is used ONLY when:
    --   * an event has "Rotate Spots Every Run" (randomizeLocations) switched ON — the server then
    --     samples `airdropCount` spots from here at start (the saved zones are NOT touched), or
    --   * you press Auto-Add Zones / Generate Drops in the editor.
    -- With the toggle OFF, an event drops at exactly the zones you placed and nothing from this list.
    -- Add, remove or edit rows freely. Fields: id (unique), label, name, area, coords = vector3(x, y, z).
    -- To move a spot, just change its vector3. Tip: stand where you want a drop, copy the
    -- coordinates from the tablet's "pin to my position" / your coords tool and paste them in.
    -- (server/modules/airdrop_locations.lua keeps a built-in copy of the same 25 spots, used only
    -- if this list is deleted or empty.)
    predefinedLocations = {
        { id = 'loc_1',  label = 'Sandy Shores Airfield Hangar',     name = 'Sandy Shores Airfield',       area = 'Sandy Shores', coords = vector3(1733.24, 3307.72, 41.22) },
        { id = 'loc_2',  label = 'Grapeseed Grain Silos',            name = 'Grapeseed Farms',             area = 'Grapeseed', coords = vector3(2443.15, 4976.22, 46.56) },
        { id = 'loc_3',  label = 'Grand Senora Desert Oil Pumps',    name = 'Grand Senora Desert',         area = 'Grand Senora Desert', coords = vector3(606.32, 2858.45, 39.95) },
        { id = 'loc_4',  label = 'Mount Chiliad Trail Foothills',    name = 'Mount Chiliad Foothills',     area = 'Mount Chiliad', coords = vector3(-771.55, 5598.12, 33.48) },
        { id = 'loc_5',  label = 'Paleto Bay Lumber Yard',           name = 'Paleto Bay Sawmill',          area = 'Paleto Bay', coords = vector3(-551.98, 5326.11, 73.60) },
        { id = 'loc_6',  label = 'Lago Zancudo Wetlands',            name = 'Lago Zancudo Marsh',          area = 'Lago Zancudo', coords = vector3(-2286.14, 2521.88, 3.42) },
        { id = 'loc_7',  label = 'Tataviam Reservoir Hillside',      name = 'Tataviam Mountains',          area = 'Tataviam Mountains', coords = vector3(1985.44, 533.82, 161.02) },
        { id = 'loc_8',  label = 'Cypress Flats Freight Depot',      name = 'Cypress Flats Rail Yard',     area = 'Cypress Flats', coords = vector3(987.32, -2125.41, 30.48) },
        { id = 'loc_9',  label = 'Murrieta Oil Field Pumps',         name = 'Murrieta Oil Fields',         area = 'Murrieta Heights', coords = vector3(1560.12, -1802.77, 88.54) },
        { id = 'loc_10', label = 'Elysian Island Cargo Pier',        name = 'Elysian Island Docks',        area = 'Elysian Island', coords = vector3(142.18, -2900.56, 5.90) },
        { id = 'loc_11', label = 'LSIA South Perimeter Fence',       name = 'LSIA Runway Perimeter',       area = 'Los Santos Airport', coords = vector3(-982.41, -2995.12, 13.95) },
        { id = 'loc_12', label = 'Terminal Island Dry Docks',        name = 'Terminal Industrial Basin',   area = 'Terminal', coords = vector3(1134.62, -3194.22, 5.90) },
        { id = 'loc_13', label = 'Palmer-Taylor Power Substation',   name = 'Palmer-Taylor Power Station', area = 'Palmer-Taylor', coords = vector3(2695.88, 1662.34, 24.52) },
        { id = 'loc_14', label = 'Redwood Lights Dirt Track',        name = 'Redwood Lights Construction', area = 'Redwood Lights', coords = vector3(893.22, 2073.44, 53.60) },
        { id = 'loc_15', label = 'Davis Quartz Stone Quarry',        name = 'Davis Quartz Quarry',         area = 'Davis Quartz', coords = vector3(2954.12, 2788.65, 39.12) },
        { id = 'loc_16', label = 'Alamo Sea North Beach',            name = 'Alamo Sea Shoreline',         area = 'Alamo Sea', coords = vector3(1325.45, 4310.88, 38.15) },
        { id = 'loc_17', label = 'Mount Josiah River Valley',        name = 'Mount Josiah Valley',         area = 'Mount Josiah', coords = vector3(-1108.32, 2694.15, 19.82) },
        { id = 'loc_18', label = 'Tongva Valley Vineyard Slopes',    name = 'Tongva Valley Hills',         area = 'Tongva Hills', coords = vector3(-1475.22, 1502.88, 114.25) },
        { id = 'loc_19', label = 'Banham Canyon Coastal Overlook',   name = 'Banham Canyon Clearing',      area = 'Banham Canyon', coords = vector3(-2180.45, -395.12, 13.20) },
        { id = 'loc_20', label = 'Land Act Dam Overlook Ridge',      name = 'Land Act Dam Spillway',       area = 'Land Act Reservoir', coords = vector3(1654.88, 19.45, 167.35) },
        { id = 'loc_21', label = 'El Burro Heights Scrap Field',     name = 'El Burro Scrap Yard',         area = 'El Burro Heights', coords = vector3(1390.22, -2065.77, 52.00) },
        { id = 'loc_22', label = 'Paleto Forest Mountain Trail',     name = 'Paleto Forest Clearing',      area = 'Paleto Forest', coords = vector3(-415.65, 6325.12, 12.45) },
        { id = 'loc_23', label = 'Mount Gordo Ridge Clearing',       name = 'Mount Gordo Ridge',           area = 'Mount Gordo', coords = vector3(2110.35, 4775.22, 41.20) },
        { id = 'loc_24', label = 'San Chianski Beach Cove',          name = 'San Chianski Mountain Pass',  area = 'San Chianski', coords = vector3(3325.12, 5160.88, 18.42) },
        { id = 'loc_25', label = 'Chumash Coastal Highway Bluff',    name = 'Chumash Coastal Bluff',       area = 'Chumash', coords = vector3(-3150.22, 1115.45, 20.65) },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 6: EVENT — GANG RALLY RACE
-- Street Racing Stages, Vehicle Classes, Checkpoints, Podium Tokens & Racer Notifications
-- ═══════════════════════════════════════════════════════════════════════════════════



-- ── Gang Rally Race Configuration ───────────────────────────────────────────────────

Config.RallyRace = {
    tokenItem = 'race_token',
    -- Tokens for 1st / 2nd / 3rd … ; every other finisher gets finishTokens.
    tokensByPosition = { [1] = 5, [2] = 3, [3] = 2 },
    finishTokens = 1,
    -- After the FIRST racer crosses the line, everyone else has this many seconds
    -- to finish so their position (and tokens) count. 0 = the race ends at once.
    finishWindowSeconds = 60,
    -- Once every racer has finished, wait this long before the "race ended / event
    -- concluded" announcements so each racer's own finish banner shows first.
    concludeDelaySeconds = 8,
    -- Heads-up before a MANUALLY started race: "starts in N minutes" banners go out
    -- and the green flag drops after this many seconds. 0 = start immediately.
    -- An event's own start delay (General tab) overrides it. Scheduled races use
    -- Config.PreScheduleAnnounceSeconds instead.
    startLeadSeconds = 0,
    -- Reminder banners (seconds before the green flag) sent to gangs during the lead time.
    leadReminders = { 600, 300, 180, 120, 60, 30, 10 },
    -- Start grid: the 3-2-1-GO countdown begins once every racer is within gridRadius
    -- metres of the START marker, or after gridWaitSeconds at the latest.
    gridRadius = 40.0,
    gridWaitSeconds = 180,
    -- true: the countdown starts by itself once everyone is in position.
    -- false: it only starts when an organiser presses "Start Countdown" (event list
    -- or event form) or runs the command below.
    autoCountdown = true,
    -- Admin/organiser command: /racestart [eventId] starts the countdown now.
    -- Without an id it uses the one race waiting on the grid. '' disables it.
    countdownCommand = 'racestart',
    -- Big centred banner a racer sees the moment they cross the line
    -- ("1ST PLACE — TIME 02:31 | +5 RACE TOKENS"). seconds = how long it stays.
    finishBanner = { enabled = true, seconds = 6 },
    -- F1-style standings tower: how many racers it lists (your own row is always shown).
    scoreboardRows = 8,
    -- Racer-vs-racer collision is chosen per race in the event form (Collision On / Off).
    -- With it Off, racers' vehicles pass through each other and are drawn at this
    -- opacity (0-255; 255 = fully solid).
    ghostAlpha = 170,
    -- How far outside a checkpoint's radius the server still accepts a racer's
    -- checkpoint report (covers speed + sync lag).
    reportPadding = 45.0,
    -- Configurable civilian registration ped for "Open to Everyone" races
    civilianPed = {
        enabled = true,
        model = 'a_m_y_runner_01',
        coords = vec4(-1158.0, -2020.0, 13.2, 160.0),
        -- the ped is a registration desk for every event open to civilians (races AND Container Wars): its window lists them all
        blip = { enabled = true, sprite = 311, colour = 3, scale = 0.85, label = 'Event Registration' },
    },
}

-- ── Race Token Vendor ──────────────────────────────────────────────────────────
-- Gang members trade race tokens (Config.RallyRace) for a special vehicle here.
-- Move the ped in-game with /settokenvendor (admins: stand where it should be) or
-- from the rally builder's Race Setup tab; pedCoords is only the default before
-- that. vehicles: { model = spawn name, label = menu text, tokens = price }
Config.TokenVendor = {
    enabled = true,
    gangOnly = false,   -- false = anyone with race tokens can trade them; true = gang members only
    blip = true,
    pedModel = 's_m_y_xmech_02',
    pedCoords = vec4(-1155.8, -2024.4, 13.2, 160.0),
    vehicles = {
        { model = 'bmx',      label = 'BMX — Stunt Bicycle',              tokens = 1, icon = 'fa-solid fa-bicycle' },
        { model = 'bati',     label = 'Pegassi Bati 801 — Race Bike',     tokens = 2, icon = 'fa-solid fa-motorcycle' },
        { model = 'sultanrs', label = 'Karin Sultan RS — Tuner',          tokens = 3 },
        { model = 'elegy',    label = 'Annis Elegy Retro — Street Racer', tokens = 4 },
        { model = 'jester',   label = 'Dinka Jester — Track Weapon',      tokens = 6 },
    },
}

-- ── Rally Race Vehicle Rental Shop ──────────────────────────────────────────────────

Config.RaceVehicleShop = {
    pedModel = 's_m_m_autoshop_02',
    -- Where the vehicle appears, in metres in front of the ped.
    spawnDistance = 6.0,
    -- Map sprite of the vehicle ped (shown while its race is set up; gone with the ped). sprite 225 = car, colour 3 = blue.
    blip = { enabled = true, sprite = 225, colour = 3, scale = 0.85, shortRange = true, label = 'Race Vehicles' },
}

-- ── Gang Rally — Corner Toast Notifications (client/modules/rally_race.lua) ──────
-- These are ox_lib lib.notify() toasts (small corner popups), NOT the big NUI
-- announcement banners above — they use lib.notify's own shape (title,
-- description, type, duration) rather than AnnouncementBanners' (title, body,
-- kind). Purely client-side (racer/police-facing feedback during a run), so
-- they're kept in their own table instead of mixed into AnnouncementBanners.
Config.RallyNotifications = {
    -- Shown to a racer when the race is live but the start grid is still filling.
    raceGrid = {
        enabled = true,
        title = '🏁 HEAD TO THE START',
        description = 'Drive to the start line. The race begins once every racer is in position.',
        type = 'info',
        duration = 7000,
    },

    -- %d = seconds remaining in the countdown (3, 2, 1)
    raceCountdown = {
        enabled = true,
        title = '🏁 RACE START',
        description = 'Starting in %d...',
        type = 'info',
        duration = 1000,
    },

    raceGo = {
        enabled = true,
        title = '🟢 GO GO GO!',
        description = 'Floor it! First racer across the line wins!',
        type = 'success',
        duration = 2000,
    },

    -- Shown to a racer when race tokens are added for their finishing position.
    -- %d = tokens, %d = position
    raceTokens = {
        enabled = true,
        title = '🎟️ RACE TOKENS EARNED',
        description = 'Position %d — %d race token(s) added to your inventory.',
        type = 'success',
        duration = 5000,
    },

    raceFinished = {
        enabled = true,
        title = '🏁 FINISHED!',
        description = 'You have crossed the finish line! Awaiting final race standings...',
        type = 'success',
        duration = 7000,
    },

    -- Corner toast that accompanies the police-only pursuit blip/banner —
    -- see Config.AnnouncementBanners.rallyPolicePursuitEnd for the big banner.
    policePursuitAlert = {
        enabled = true,
        title = '🚨 10-99: ILLEGAL STREET RACE TERMINATED',
        description = 'Suspects are fleeing from the race finish line! Pursuit blip marked on your GPS.',
        type = 'error',
        duration = 10000,
    },
}



-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 7: EVENT — TEAM DEATHMATCH (TDM)
-- Gang vs Gang Arena Battles, Tournament Brackets, Loadouts & Weapon Vendors
-- ═══════════════════════════════════════════════════════════════════════════════════

Config.TDM = {
    -- A TDM player is invincible for the whole match (so no ambulance / dispatch script ever reacts); kills come from a
    -- server-side HP pool instead. Damage is looked up HERE by weapon, never taken from the client.
    maxHealth = 100,                 -- virtual HP of every participant
    defaultDamage = 20,              -- damage of a weapon that is not listed in weaponDamage
    respawnDelaySeconds = 3,         -- how long a downed player waits before respawning
    respawnInvulnSeconds = 3,        -- protection right after a respawn
    prepCountdownSeconds = 5,        -- the 3-2-1-GO before combat starts
    -- Rewards are paid PER PLAYER by kills (server/modules/tdm_rewards.lua). These are the defaults; every TDM event (and the tournaments built
    -- on it) can change them in the form: Match Setup → Match Reward.
    --   winners: the best killer gets the whole reward, the others winnerMinPercent .. 100 % of it by their kills
    --   losers : every member gets loserPercent of the reward (0 = nothing), the best killer of the side the most, the others loserMinPercent .. 100 % of that
    rewardScaling = { enabled = true, winnerMinPercent = 40, loserPercent = 25, loserMinPercent = 40 },
    -- the WINS / DEFEATED banner and the overhead player cards after a match: seconds on screen (then the results window opens), and how many
    -- players of the team get a card (best killers first)
    outcomeSeconds = 10,
    outcomeCards = 5,
    -- damage per hit (virtual HP taken), by weapon name
    weaponDamage = {
        WEAPON_PISTOL = 22, WEAPON_COMBATPISTOL = 24, WEAPON_APPISTOL = 18, WEAPON_PISTOL50 = 38, WEAPON_HEAVYPISTOL = 32,
        WEAPON_MICROSMG = 14, WEAPON_SMG = 17, WEAPON_ASSAULTSMG = 19,
        WEAPON_CARBINERIFLE = 26, WEAPON_ASSAULTRIFLE = 28, WEAPON_ADVANCEDRIFLE = 27, WEAPON_SPECIALCARBINE = 27,
        WEAPON_PUMPSHOTGUN = 48, WEAPON_SAWNOFFSHOTGUN = 55,
        WEAPON_COMBATMG = 24, WEAPON_SNIPERRIFLE = 75, WEAPON_MARKSMANRIFLE = 55,
        WEAPON_KNIFE = 35, WEAPON_BAT = 28,
    },
    -- the weapon vendor ped of a match (its position is set per event in the tablet: Match Setup → Peds)
    weaponVendor = {
        pedModel = Config.Peds.thug, -- a street-gang ped, not police (see Config.Peds)
        -- map sprite of the vendor (only exists while a match is running). sprite 110 = gun shop, colour 1 = red
        blip = { enabled = true, sprite = 110, colour = 1, scale = 0.85, shortRange = true, label = 'TDM Weapon Vendor' },
        moneyAccount = 'cash',       -- 'cash' or 'bank' (the buyer can pick either in the menu)
        items = {                    -- label, weapon (also the inventory item name, lower-cased), ammo given, price in $
            { label = 'Combat Pistol', weapon = 'WEAPON_COMBATPISTOL', ammo = 60, price = 400 },
            { label = 'Micro SMG', weapon = 'WEAPON_MICROSMG', ammo = 120, price = 900 },
            { label = 'SMG', weapon = 'WEAPON_SMG', ammo = 120, price = 1200 },
            { label = 'Carbine Rifle', weapon = 'WEAPON_CARBINERIFLE', ammo = 120, price = 2200 },
            { label = 'Assault Rifle', weapon = 'WEAPON_ASSAULTRIFLE', ammo = 120, price = 2400 },
            { label = 'Pump Shotgun', weapon = 'WEAPON_PUMPSHOTGUN', ammo = 32, price = 1500 },
            { label = 'Sniper Rifle', weapon = 'WEAPON_SNIPERRIFLE', ammo = 20, price = 3500 },
        },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 8: EVENT — GANG TERRITORY AUCTION & RIVAL WARS
-- Existing events pay Gang XP → the auction hands out the first territories → XP buys the
-- predefined expansions → touching territories can be challenged → admin schedules the war →
-- ox_target capture decides the owner. Every number below is a DEFAULT: each event / war can
-- override it in the tablet, and nothing in the code hardcodes a territory, gang, colour or cost.
-- ═══════════════════════════════════════════════════════════════════════════════════

Config.Territory = {
    enabled = true,

    -- ── Gang Leader conversation ────────────────────────────────────────────────
    -- The leader ped's ox_target choices (Pay Respects / Speak to Leader / Ask About Territory / Ask About Trouble) and the talk panel on the
    -- left of the screen. Everything the leader says comes from live territory / war / Gang XP data; what a visitor may learn depends on
    -- whether they belong to the owning gang. false = the ped only shows the post-war loot option.
    leaderTalk = {
        enabled = true,
        maxDistance = 6.0,      -- the talk ends by itself if the player ends up further than this (+4 m) from the leader
    },

    -- ── Painted map ──────────────────────────────────────────────────────────────
    -- A territory is painted on a world grid: every painted cell is cellSize x cellSize metres.
    -- Smaller = finer paint (and a bigger save), larger = chunkier. Changing it later only affects
    -- shapes painted afterwards (each shape stores the cell size it was painted with).
    cellSize = 25.0,
    maxCellsPerTerritory = 80000,   -- base + every expansion together
    maxAreas = 100,                 -- territories one event can define
    -- (maxExpansions is gone: there are no expansion levels any more, a territory grows by painting land)
    defaultColor = '#e5484d',
    brush = { min = 20.0, max = 400.0, default = 90.0 },   -- metres (radius of the paint / eraser brush)

    -- ── Gang XP ledger ───────────────────────────────────────────────────────────
    gangXp = {
        -- false: every gang member who is paid a Gang XP reward gets the full amount (gang total = amount x members).
        -- true : the configured amount is the gang's total and is split between the paid members.
        splitAmongRecipients = false,
        maxPerAward = 1000000,      -- safety cap on a single reward entry
        policeEarnXp = false,       -- on-duty police never earn Gang XP, even if they are also in a gang
        -- names shown in the XP history ("TDM Victory", "Hot Cargo" ...). Anything missing falls back to the event name.
        sourceLabels = {
            CONVOY = 'Convoy', GANG_AIRDROP = 'Airdrop', HOT_CARGO = 'Hot Cargo', GANG_RACE = 'Rally Race',
            TDM = 'TDM Victory', CONTAINER_WARS = 'Container Wars', GANG_TERRITORY = 'Territory', CRACKDOWN = 'Operation Crackdown',
        },
        historyLimit = 300,         -- rows the tablet loads at once
    },

    -- ── Territory auction (reuses the Container Wars bidding rules) ──────────────
    auction = {
        defaults = {
            startingBid = 100000,
            minBidIncrement = 10000,
            lotSeconds = 90,         -- bidding time of one territory
            lotGapSeconds = 20,      -- pause between two territories
            introSeconds = 30,       -- countdown after the event starts, before the first territory opens
            eventMinutes = 30,       -- Auction Duration the form starts with
        },
        antiSnipe = { enabled = true, triggerSeconds = 10, extendSeconds = 15 },
        bidding = { serverMinGapMs = 300, staleMessage = 'Bid is no longer valid. Current bid has changed.' },
        -- true (default): when a territory is SOLD at the auction, whatever land it had (an old starting area, the previous owner's paint)
        -- is wiped and the winner paints it themselves from the leader ped. false = it is sold as it stands.
        clearLandOnSale = true,
        zoneRadius = 12.0,           -- metres around the auction location where eligible gangs can open the bidder (key prompt, no ox_target)
        -- The projector is ONLY the physical anchor of the auction: it is spawned when bidding really starts (after the intro /
        -- buffer) and removed when the whole event ends. It is not interactive. The floating auction panel shows for eligible gang
        -- members within viewDistance metres of it.
        -- (a placement that still holds the old 'prop_runlight_g', a small red light that read as a dot, is spawned as this model instead)
        projectorModel = 'h4_prop_battle_lights_floor',
        -- Tried in order when projectorModel does not exist in this server's game build (h4_ props need the Cayo Perico build, 2189 or later;
        -- xm_ props need 2060 or later). The last one is in every build. A server on a newer build simply never reaches them.
        projectorModelFallbacks = { 'xm_prop_lab_cyllight01', 'prop_worklight_03b' },
        -- true: the model chosen in the Prop Placer is used as placed. false (default): EVERY auction uses projectorModel above, whatever the
        -- placement saved (the placer then only sets where it stands and which way it faces).
        projectorModelFromPlacement = false,
        -- Where the light comes from, in the prop's own frame (metres from its origin; +y = the way the prop faces, +z = up). The light head of a
        -- tilted lamp sits in front of and above the middle of the prop: y/z = nil -> the middle of the top (z = 92% of the prop's height).
        -- Tune it live with /projlens <x> <y> <z> (prints the line to paste here).
        lensOffset = { x = 0.0, y = nil, z = nil },
        viewDistance = 80.0,
        -- The auction board is a hologram screen standing over the projector (a DUI: the game renders the board page into a
        -- texture and draws it in the world, always turned toward the viewer). width/height are metres, lift = metres from
        -- the projector's base to the bottom edge, alpha 0-255, pixelWidth/pixelHeight = texture size (keep the 16:9 ratio).
        -- minScale / maxScale: the range of the admin's "screen size" slider (Projectors tab); the size chosen there is saved with the event.
        screen = { width = 6.4, height = 3.6, lift = 3.0, alpha = 255, pixelWidth = 1600, pixelHeight = 900, minScale = 0.4, maxScale = 3.0 },
        -- The zone being bid on flashes on the map: a blip on its centre plus a flashing circle over its area, and a sound +
        -- notice when it comes up. sprite = a GTA blip sprite (310 = the territory icon; try 84, 106, 374, 437), scale 0.6-1.2,
        -- colour = a GTA blip colour (5 = yellow, 1 = red, 3 = blue), radius in metres, fastSeconds = how long the quick blink
        -- lasts before it settles to a calmer one.
        spotlight = { sprite = 310, colour = 5, scale = 1.0, radius = 140.0, areaAlpha = 110, fastSeconds = 20 },
        -- The light thrown from the projector prop up to the board. It takes the colour of the zone being bid on (set colour = { r, g, b }
        -- to force one), alpha 4-120 is how visible the cone is, lensLift = metres above the prop's base where the beam starts.
        beam = { enabled = true, alpha = 14, lensLift = 0.9, lightRange = 3.0, lightIntensity = 0.35 },
        -- When a gang member places a bid, a pulsing ring, a spinning arrow and "BID $amount" appear above their head for everyone
        -- within range metres (in the colour of the zone being bid on), for this many seconds.
        bidFx = { enabled = true, seconds = 6.0, range = 60.0 },
        -- When the whole auction has ended, every member of a gang that bought territory gets a personal congratulation (a toast with a
        -- sound while online, and the same text as a gang notice for anyone offline) that names what they bought and points to the gang
        -- tablet / Config.StatusPanel.command. false = off.
        congratulate = true,
        mapKey = 'F7',               -- opens the game map while a zone is up for bidding (players can rebind it in the game's key settings)
        bidKey = 'E',                -- opens the bidder window while standing in the auction zone
        blip = { sprite = 500, colour = 5, scale = 0.95, label = 'Territory Auction' },
    },

    -- ── Who may spend Gang XP on painting land ───────────────────────────────────
    expansion = {
        requireLeaderOrPermission = true,   -- only a leader / member with the manageGang role may spend gang XP (painting)
        minRemainingXp = 0,                 -- XP that must be left after paying (0 = may spend everything)
    },

    -- ── Map editor (Map Zone tab) ────────────────────────────────────────────────
    -- A gang leader (or a member with the manageGang role) can PAINT extra land onto a territory their gang owns, in the gang's
    -- colour, paying Gang XP per painted cell (one cell = cellSize x cellSize metres). The new land must touch the territory
    -- (a territory with no land yet starts at its leader ped), may not overlap another territory, and the gang can erase what it
    -- painted for an XP refund. Admins never paint: they create territories and hand them out (by hand or through an auction).
    -- This is how a territory is EXPANDED (there are no expansion levels): the more land a gang paints, the more Gang XP is taken
    -- from it. These two numbers are only the DEFAULTS: an admin can change both live in the tablet (Map Zone -> Admin tools ->
    -- Painting cost), the change is saved in the database and reaches every gang that can paint at once; "Use config.lua" there
    -- drops the live setting and these values apply again.
    paint = {
        enabled = true,
        xpPerCell = 200,        -- Gang XP per painted cell (25 m cell = 625 m2; 320,000 XP per km2). Admins can change it live: Map Zone -> Expansion XP
        maxNewCells = 2500,     -- most cells one save may add
    },

    -- ── Rival challenges ─────────────────────────────────────────────────────────
    rival = {
        challengeCooldownSeconds = 3600,    -- same attacker -> same territory, after a decline / finished war
        maxOpenPerGang = 3,                 -- challenges a gang may have open (pending/accepted/scheduled/active)
        expireSeconds = 172800,             -- a pending challenge nobody answers lapses after this long (0 = never)
        acceptedExpireSeconds = 259200,     -- an ACCEPTED challenge no admin schedules lapses after this long (0 = never; default 3 days)
        requireLeaderOrPermission = true,   -- who may send / answer a challenge for the gang
    },

    -- ── Territory war ────────────────────────────────────────────────────────────
    war = {
        defaultDurationMinutes = 15, minDurationMinutes = 3, maxDurationMinutes = 90,
        -- "both gangs are responsible for being present": reminders go to both gangs this long before the war
        reminderMinutes = { 30, 10, 2 },
        -- Players closer than this to the territory's capture point count as "in the territory" at the end of the timer
        presenceRadius = 120.0,
        -- Nobody from either gang alive in the territory when the timer ends -> the owner keeps the territory and
        noShowPenalty = { mode = 'FLAT', xp = 250, percent = 10 },   -- mode FLAT = xp, mode PERCENT = percent of the gang's XP
        -- ── Combat Ring Zone & Out-of-Bounds Enforcement ────────────────────────
        ringZone = {
            enabled = true,
            radius = 160.0,                 -- Radius in meters around leader ped for the combat ring zone
            bufferSeconds = 35,             -- Buffer grace time (30 to 45s) to get back inside before elimination
            showMapBlip = true,             -- Show circular colored ring area blip on the map
            blipColor = 1,                  -- Map blip area color (1 = Red)
            blipAlpha = 80,                 -- Map blip area transparency (0-255)
            drawWorldRing = true,           -- Draw visual perimeter cylinder ring in world
            worldRingColor = { r = 255, g = 50, b = 50, a = 60 }, -- RGBA for world ring boundary
        },
        -- ── One-Life & Anti-Revive Re-entry System ──────────────────────────────────
        oneLife = {
            enabled = true,
            blockReentry = true,            -- Physically repel and block revived/eliminated players from re-entering
            repelDistance = 15.0,           -- Boundary buffer distance where repulsion triggers
            disarmOnApproach = true,        -- Disarm and disable weapon firing if eliminated players approach the perimeter
            notifyMessage = 'You were eliminated from this rival war! Revived players cannot re-enter the combat zone.',
        },
        -- ── Post-war loot: what a war is worth ─────────────────────────────────────
        -- NOBODY LOSES A TERRITORY IN A WAR. The winning gang walks to the Leader Ped and loots: that is the moment the LOSER pays the
        -- WINNER Gang XP and the loser's painted land (the coloured zone on the map) shrinks from its outer edge. If the winner never
        -- loots inside the window, nothing moves.
        postWarLoot = {
            enabled = true,
            windowMinutes = 5,              -- the winning gang has this long after the war to loot the Leader Ped
            targetLabel = 'Loot Gang XP',
            targetIcon = 'fa-solid fa-sack-dollar',
            durationSeconds = 5,            -- progress bar duration in seconds
            lootXpPercent = 20,             -- the loser pays this % of its Gang XP to the winner ...
            minLootXp = 500,                -- ... never less than this ...
            maxLootXp = 25000,              -- ... never more than this (and never more than the loser really has)
            zoneShrinkPercent = 25,         -- the loser's territory loses this % of its land, outermost cells first
            minCellsLeft = 20,              -- the shrink never leaves a territory smaller than this many cells
            pairCooldownHours = 24,         -- the same two gangs only play for stakes once per this many hours (0 = no limit)
            tauntMessage = 'Better luck next time "lilBro"', -- what the Leader Ped says to everyone who is not the winner
        },
        -- A scheduled war that is overdue by more than this (the server was down at its time) is NOT started: it goes back to
        -- "accepted" so an admin can schedule it again.
        lateStartGraceMinutes = 10,
        capture = {
            seconds = 60,                   -- time the attackers must hold the point
            radius = 6.0,                   -- metres: attackers count inside it while capturing; defenders inside it contest
            interactDistance = 2.5,         -- ox_target distance of "Take Territory"
            contestRule = 'PAUSE',          -- PAUSE: progress freezes while contested | RESET: starts over | DECAY: drops back
            decayPerSecond = 2.0,           -- seconds of progress lost every second under DECAY
            abandonSeconds = 8,             -- every attacker left / died: after this long the capture is dropped and starts over
            pedModel = Config.Peds.territoryLeader,  -- default territory leader ped
            anim = { dict = 'amb@world_human_hang_out_street@male_c@base', clip = 'base' },
            targetLabel = 'Take Territory',
            targetIcon = 'fa-solid fa-flag',
            blip = { sprite = 310, colour = 1, scale = 1.0, label = 'Territory Capture Point' },
        },
        banners = {
            scheduled = { title = 'TERRITORY WAR SCHEDULED', duration = 12000 },
            reminder  = { title = 'TERRITORY WAR IN %d MIN', duration = 10000 },
            started   = { title = 'TERRITORY WAR', duration = 10000 },
            contested = { title = 'TERRITORY CONTESTED', duration = 6000 },
            captured  = { title = '👑 %s IS THE BOSS!', duration = 12000 },
            defended  = { title = '👑 %s IS THE BOSS!', duration = 12000 },
            noShow    = { title = 'TERRITORY WAR — NO SHOW', duration = 12000 },
            looted    = { title = '👑 %s IS THE BOSS!', duration = 12000 },
        },
    },

    -- ── World / map presentation ─────────────────────────────────────────────────
    -- Who sees the territories in the world — the map blip (sprite + "Territory — Owner gang" name), the coloured ground ring and
    -- the leader ped standing at each territory:
    --   'everyone' = every player on the server (civilians and police included)
    --   'gangs'    = only gang members and admins
    -- The painted land shapes, Gang XP, the Map Zone tab and the auction window stay gang + admin only either way.
    visibleTo = 'everyone',
    blip = { sprite = 310, scale = 0.85, shortRange = true, showToAllGangMembers = true },
    -- Draw a coloured ground ring under each territory's leader ped while near it (follows visibleTo above)
    worldMarker = { enabled = true, drawDistance = 150.0, type = 1, size = 1.8, height = 0.12, alpha = 150 },   -- a small flat disc under the leader ped (size = its diameter in metres)
}

-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 9: EVENT — PRACTICE RANGE & TACTICAL TRAINING
-- Shooting Range Drills, Pop-Up Targets, Instructor Peds, Leaderboards & Weapon Racks
-- ═══════════════════════════════════════════════════════════════════════════════════

-- ── Practice Range ──────────────────────────────────────────────────────────────
-- Always-on squad aim training, independent of TDM/gangs/convoys — the instructor
-- ped is permanent and anyone can use it at any time, with or without any event
-- running. Flow: pick an area + weapon in the Armory, the host deploys, and the
-- whole squad is moved into its OWN routing bucket (server/modules/
-- practice_range.lua) — a private world with no ambient population, invisible to
-- and unreachable by everyone else, including EMS and police. The player is kept
-- from ever dying (so no ambulance script is ever triggered, whichever one the
-- server runs); if a death still slips through they are revived after
-- reviveDelaySeconds. Ending the session returns the player to the normal bucket
-- and walks them back to the instructor ped. Bots are client-side peds owned by
-- the host; no DB rows.
--
-- IMPORTANT: pedCoords and every location's coords below are approximate
-- starting points, not verified in-game — nobody could test exact ground
-- placement without a live server. Check/adjust them once in-game before
-- relying on this (a ped sunk into terrain, or a bot spawn point inside a
-- rock, is the likely failure mode if a coordinate is off).

Config.PracticeRange = {
    enabled = true,
    -- Weapon catalog for the practice weapon-choice menu — the player's own
    -- real weapons are locked out for the session (see client/modules/
    -- practice_range.lua's weapon-lock watchdog) and never touched/removed;
    -- these are given purely via the GiveWeaponToPed native (never
    -- Inventory.AddItem), so nothing here ever reaches the real economy —
    -- infinite ammo, free, gone the moment the session ends.
    weapons = {
        -- suppressor = the component fitted in the range (see silenceWeapons).
        { label = 'Combat Pistol', weapon = 'WEAPON_COMBATPISTOL', suppressor = 'COMPONENT_AT_PI_SUPP' },
        { label = 'Micro SMG', weapon = 'WEAPON_MICROSMG', suppressor = 'COMPONENT_AT_AR_SUPP_02' },
        { label = 'SMG', weapon = 'WEAPON_SMG', suppressor = 'COMPONENT_AT_PI_SUPP' },
        { label = 'Carbine Rifle', weapon = 'WEAPON_CARBINERIFLE', suppressor = 'COMPONENT_AT_AR_SUPP' },
        { label = 'Assault Rifle', weapon = 'WEAPON_ASSAULTRIFLE', suppressor = 'COMPONENT_AT_AR_SUPP_02' },
        { label = 'Pump Shotgun', weapon = 'WEAPON_PUMPSHOTGUN', suppressor = 'COMPONENT_AT_SR_SUPP' },
        { label = 'Combat MG', weapon = 'WEAPON_COMBATMG' }, -- no suppressor exists for this gun
        { label = 'Sniper Rifle', weapon = 'WEAPON_SNIPERRIFLE', suppressor = 'COMPONENT_AT_AR_SUPP_02' },
    },
    -- A street-gang ped (not police). Two guessed "shooting range instructor" names were invalid on this build
    -- (s_m_y_range_mo_01, mp_m_shooting_01); this model is one already confirmed working on this server.
    pedModel = Config.Peds.thug,
    pedCoords = vec4(19.0, -1113.0, 29.8, 160.0), -- Vespucci gun range area
    -- Map blip for the practice ped: radar_rampage (sprite 84), red (colour 1).
    pedBlip = { enabled = true, sprite = 84, colour = 1, scale = 0.9, shortRange = true, label = 'Practice Range' },
    -- Where a player is put back (normal world, normal bucket) when they leave or
    -- end a practice session. Admins: change this vector to move the landing spot.
    returnCoords = vec4(19.4108, -1112.2354, 29.7970, 21.8282),
    -- Bots alive at once per session; a dead bot is replaced from the same
    -- location's botSpawns list after botRespawnDelaySeconds so practice
    -- stays continuous until the player ends the session themselves.
    -- Bots can put the player "down": a virtual HP pool (the real ped stays
    -- invincible so ambulance/dispatch scripts never fire). Each bot hit costs
    -- botHitDamage; at 0 the player ragdolls for downedSeconds with a respawn
    -- countdown, then gets back up. HP slowly regenerates between fights.
    -- The bar always shows 0-100 (playerHealth). The real pool behind it is playerHealth × hiddenHealthMultiplier
    -- (2 = 200 points), so a practice match lasts longer than the number on screen suggests.
    -- botHitDamage is in pool points: at the default 8 and a ×2 pool, one bot hit takes 4 off the bar.
    playerHealth = 100,
    hiddenHealthMultiplier = 2.0,
    botHitDamage = 8,
    -- How a bot's fire turns into hits on the (fully proofed) player. A firing bot that faces the player with a clear line
    -- lands a hit with chance botHitChance (less at long range), at most once per botHitCooldownMs per bot.
    botHitChance = 0.15,
    botHitCooldownMs = 200,
    botFireRange = 90.0,
    -- Heavier guns hurt more: × botHitDamage (weapon name → factor; anything unlisted is ×1).
    botWeaponDamageScale = {
        WEAPON_PUMPSHOTGUN = 2.2, WEAPON_SNIPERRIFLE = 3.0, WEAPON_CARBINERIFLE = 1.2, WEAPON_ASSAULTRIFLE = 1.3,
        WEAPON_COMBATMG = 0.9, WEAPON_MICROSMG = 0.8, WEAPON_SMG = 0.9,
    },
    -- Waves instead of a wall of fire: only this many bots shoot at once (plus activeShootersPerExtraPlayer for every
    -- squadmate beyond the host). A shooter fires for shooterBurstSeconds {min, max}, then pauses for shooterPauseSeconds
    -- (advancing without firing) while another takes its turn.
    maxActiveShooters = 3,
    activeShootersPerExtraPlayer = 2,
    shooterBurstSeconds = { 5, 9 },
    shooterPauseSeconds = { 3, 6 },
    -- New bots appear on a ring around the player, out of sight where possible, each on a different bearing.
    botSpawnMinDistance = 48.0,
    botSpawnMaxDistance = 80.0,
    downedSeconds = 3,
    sessionBotCount = 12,
    -- Extra bots added for every squadmate beyond the host (capped at 32 total).
    botsPerExtraPlayer = 4,
    -- Spare magazines given with the practice gun (no infinite ammo — reloading is
    -- part of the practice). The game clamps total ammo to the weapon's maximum.
    reserveClips = 2500,
    botRespawnDelaySeconds = 2,
    -- If the player ever goes down anyway (every ambulance/medical script keys
    -- off health reaching 0), they are revived on the spot after this many
    -- seconds. The session ALSO keeps them invincible + topped up so this is a
    -- safety net, not the normal path — and since they never die, no EMS call
    -- is ever raised in the first place.
    reviveDelaySeconds = 2,
    -- Police dispatch: nothing said or shot in the range should ever reach it.
    --   1. Server-side: everyone in a session carries the state bag
    --      Player(src).state.novaPractice (and exports.nova_convoytruck:IsInPractice(src));
    --      ps-dispatch is patched to ignore them. For any OTHER dispatch script
    --      (cd_dispatch, core_dispatch, qs-dispatch, ...) add one line at the top
    --      of its server-side alert entry point:
    --          if Player(src).state.novaPractice then return end
    --   2. Client-side, script-independent: practice weapons get a suppressor,
    --      which nearly every dispatch script already treats as "silent" via
    --      IsPedCurrentWeaponSilenced. Set false to keep normal gun sound.
    silenceWeapons = true,
    -- Every practice area has an EXIT marker + map blip (at the area's
    -- exitPoint, or its playerSpawn if none is set). Standing on it and pressing
    -- [E] returns the player to the normal world — an extra way out.
    -- /endpractice and F6 ALSO end the session straight away and send the player
    -- back to the practice ped. Set endRequiresExit = true if you'd rather those
    -- two only guide the player to the exit marker instead.
    endRequiresExit = false,
    -- Exit marker blip: sprite 408 (radar_exit_door / doorway), colour 2 (green)
    exitBlip = { sprite = 408, colour = 2, scale = 1.1, label = 'Practice Arena Exit' },
    exitGlow = { r = 80, g = 255, b = 140 }, -- marker / beam / light colour
    exitRadius = 2.0,
    -- While in a session the player's REAL inventory is locked: no opening it,
    -- no hotbar, no using items, no real weapons. Only the practice gun (given
    -- natively, infinite ammo) exists. Nothing is added, removed or moved.
    lockInventory = true,
    -- Ambulance / medical scripts to nudge after that revive so their own
    -- "dead" state is cleared. Only resources that are actually started are
    -- triggered; add your own here for any script not listed.
    reviveEvents = {
        { resource = 'qbx_medical', event = 'qbx_medical:client:playerRevived' },
        { resource = 'qb-ambulancejob', event = 'hospital:client:Revive' },
        { resource = 'qbx_ambulancejob', event = 'hospital:client:Revive' },
        { resource = 'esx_ambulancejob', event = 'esx_ambulancejob:revive' },
        { resource = 'wasabi_ambulance', event = 'wasabi_ambulance:revive' },
        { resource = 'ars_ambulancejob', event = 'ars_ambulancejob:healPlayer', arg = { revive = true } },
        { resource = 'osp_ambulance', event = 'osp_ambulance:revive' },
        { resource = 'brutal_ambulancejob', event = 'brutal_ambulancejob:revive' },
    },
    locations = {
        {
            id = 'sandy_quarry',
            label = 'Sandy Shores Quarry',
            tag = 'OPEN AREA',
            -- ── Player Spawning Locations ──────────────────────────────────
            -- Primary spawn vector: vec4(x, y, z, heading)
            playerSpawn = vec4(2965.6543, 2758.1255, 43.1856, 188.0962),
            -- Multiple player spawn vectors (for squad members / arena respawns):
            -- Admins: alter these vectors to customize where players spawn in this arena.
            playerSpawns = {
                vec4(2965.6543, 2758.1255, 43.1856, 188.0962),
                vec4(2972.5000, 2752.3000, 43.1856, 180.0000),
                vec4(2960.2000, 2764.8000, 43.2000, 205.0000),
                vec4(2955.1000, 2750.4000, 43.2000, 160.0000),
            },
            exitPoint = vec4(2965.6543, 2758.1255, 43.1856, 188.0962),
            botSpawns = {
                vec3(2985.0, 2745.0, 43.5),
                vec3(2990.0, 2775.0, 43.5),
                vec3(2950.0, 2790.0, 43.5),
                vec3(2940.0, 2740.0, 43.5),
            },
            botModel = 'g_m_y_lost_01',
            botWeapon = 'WEAPON_CARBINERIFLE',
            aggressiveness = 'medium', -- low | medium | high | extreme — see AGGRESSIVENESS_PROFILES in npc_relationships.lua
        },
        {
            id = 'elysian_docks',
            label = 'Elysian Island Docks',
            tag = 'URBAN',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(356.5568, -2564.1060, 9.8601, 188.8200),
            playerSpawns = {
                vec4(356.5568, -2564.1060, 9.8601, 188.8200),
                vec4(362.4000, -2558.2000, 9.8600, 180.0000),
                vec4(350.1000, -2570.8000, 9.8600, 195.0000),
                vec4(345.8000, -2560.5000, 9.8600, 170.0000),
            },
            exitPoint = vec4(356.5568, -2564.1060, 9.8601, 188.8200),
            botSpawns = {
                vec3(370.0, -2555.0, 6.0),
                vec3(375.0, -2590.0, 6.0),
                vec3(320.0, -2600.0, 6.0),
                vec3(310.0, -2555.0, 6.0),
            },
            botModel = 'g_m_y_ballas_01',
            botWeapon = 'WEAPON_MICROSMG',
            aggressiveness = 'medium',
        },
        {
            id = 'grapeseed_farmland',
            label = 'Grapeseed Farmland',
            tag = 'HOSTILE',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(2436.5569, 4961.8335, 46.8105, 303.3507),
            playerSpawns = {
                vec4(2436.5569, 4961.8335, 46.8105, 303.3507),
                vec4(2442.2000, 4968.1000, 46.8100, 290.0000),
                vec4(2430.8000, 4955.4000, 46.8100, 315.0000),
                vec4(2425.6000, 4965.0000, 46.8100, 280.0000),
            },
            exitPoint = vec4(2436.5569, 4961.8335, 46.8105, 303.3507),
            botSpawns = {
                vec3(2470.0, 4980.0, 46.0),
                vec3(2470.0, 4950.0, 46.0),
                vec3(2410.0, 4950.0, 46.0),
                vec3(2410.0, 4980.0, 46.0),
            },
            botModel = 's_m_y_blackops_01',
            botWeapon = 'WEAPON_ASSAULTRIFLE',
            aggressiveness = 'high',
        },

        -- ── More areas ─────────────────────────────────────────────────────
        -- These use botRing instead of a hand-typed botSpawns list: bots are
        -- placed on a ring around `center` at session start, and every spawn
        -- height (player and bots) is snapped to the real ground at runtime, so
        -- a slightly-off Z here can't bury anyone in terrain. playerSpawn and
        -- center are approximate — adjust once you've stood in them in-game.
        {
            id = 'sandy_airfield',
            label = 'Sandy Shores Airfield',
            tag = 'OPEN AREA',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(1734.9016, 3315.8604, 41.2235, 174.8430),
            playerSpawns = {
                vec4(1734.9016, 3315.8604, 41.2235, 174.8430),
                vec4(1742.0000, 3320.0000, 41.2200, 170.0000),
                vec4(1728.0000, 3310.0000, 41.2200, 180.0000),
            },
            exitPoint = vec4(1734.9016, 3315.8604, 41.2235, 174.8430),
            botRing = { center = vec3(1745.0, 3260.0, 41.1), radius = 30.0, count = 8 },
            botModel = 'g_m_y_mexgoon_01',
            botWeapon = 'WEAPON_SMG',
            aggressiveness = 'medium',
        },
        {
            id = 'alamo_shore',
            label = 'Alamo Sea Shore',
            tag = 'OPEN AREA',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(1320.3608, 3583.4902, 34.8094, 281.1339),
            playerSpawns = {
                vec4(1320.3608, 3583.4902, 34.8094, 281.1339),
                vec4(1328.0000, 3588.0000, 34.8100, 275.0000),
                vec4(1312.0000, 3578.0000, 34.8100, 290.0000),
            },
            exitPoint = vec4(1320.3608, 3583.4902, 34.8094, 281.1339),
            botRing = { center = vec3(1290.0, 3590.0, 34.9), radius = 28.0, count = 8 },
            botModel = 'g_m_y_lost_02',
            botWeapon = 'WEAPON_PUMPSHOTGUN',
            aggressiveness = 'medium',
        },
        {
            id = 'mckenzie_airfield',
            label = 'McKenzie Airfield',
            tag = 'OPEN AREA',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(2112.0, 4790.0, 40.21, 281.13),
            playerSpawns = {
                vec4(2112.0, 4790.0, 40.21, 281.13),
                vec4(2118.0, 4795.0, 40.21, 270.00),
                vec4(2106.0, 4785.0, 40.21, 290.00),
            },
            exitPoint = vec4(2112.0, 4790.0, 40.21, 281.13),
            botRing = { center = vec3(2140.0, 4790.0, 41.1), radius = 30.0, count = 8 },
            botModel = 'g_m_y_salvagoon_01',
            botWeapon = 'WEAPON_ASSAULTRIFLE',
            aggressiveness = 'high',
        },
        {
            id = 'port_container_yard',
            label = 'Port of LS Container Yard',
            tag = 'URBAN',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(1000.0, -3055.0, 5.9, 0.0),
            playerSpawns = {
                vec4(1000.0, -3055.0, 5.9, 0.0),
                vec4(1006.0, -3050.0, 5.9, 10.0),
                vec4(994.0, -3060.0, 5.9, 350.0),
            },
            exitPoint = vec4(1000.0, -3055.0, 5.9, 0.0),
            botRing = { center = vec3(1020.0, -3030.0, 5.9), radius = 22.0, count = 8 },
            botModel = 'g_m_y_armgoon_02',
            botWeapon = 'WEAPON_MICROSMG',
            aggressiveness = 'medium',
        },
        {
            id = 'cypress_warehouses',
            label = 'Cypress Flats Warehouses',
            tag = 'URBAN',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(860.0, -2160.0, 30.4, 350.0),
            playerSpawns = {
                vec4(860.0, -2160.0, 30.4, 350.0),
                vec4(866.0, -2155.0, 30.4, 340.0),
                vec4(854.0, -2165.0, 30.4, 0.0),
            },
            exitPoint = vec4(860.0, -2160.0, 30.4, 350.0),
            botRing = { center = vec3(880.0, -2135.0, 30.4), radius = 22.0, count = 8 },
            botModel = 'g_m_m_chigoon_01',
            botWeapon = 'WEAPON_CARBINERIFLE',
            aggressiveness = 'high',
        },
        {
            id = 'paleto_sawmill',
            label = 'Paleto Sawmill',
            tag = 'WOODS',
            -- ── Player Spawning Locations ──────────────────────────────────
            playerSpawn = vec4(-508.5078, 5268.1226, 80.6100, 165.6957),
            playerSpawns = {
                vec4(-508.5078, 5268.1226, 80.6100, 165.6957),
                vec4(-514.0000, 5272.0000, 80.6100, 160.0000),
                vec4(-502.0000, 5264.0000, 80.6100, 175.0000),
            },
            exitPoint = vec4(-508.5078, 5268.1226, 80.6100, 165.6957),
            botRing = { center = vec3(-555.0, 5325.0, 70.4), radius = 24.0, count = 8 },
            botModel = 'g_m_y_pologoon_01',
            botWeapon = 'WEAPON_COMBATMG',
            aggressiveness = 'high',
        },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 10: SYSTEM ANNOUNCEMENT BANNERS
-- Global Screen Banners, Event Lifecycle Alerts, Audio Cues & Stand-Down Notifications
-- ═══════════════════════════════════════════════════════════════════════════════════

-- ── In-Game Announcement Banners ────────────────────────────────────────────────
-- Centralized configuration for in-game announcement banner strings, durations (ms),
-- and styles ('start', 'success', 'danger', 'warn', 'info', 'checkpoint').
Config.AnnouncementBanners = {
    -- %d = trucks still deliverable
    hotCargoTruckBroken = {
        enabled = true,
        title = 'HOT CARGO TRUCK BROKEN DOWN',
        body = 'One of the contraband trucks has broken down and can no longer be delivered. %d truck(s) still out there — find them and deliver!',
        duration = 8000,
        kind = 'warn',
    },

    -- ── Gang Rally lead-in (sent to gang members + admins only) ──
    -- %s = event name, %s = time until the start (e.g. '2 minutes')
    rallyStartingSoon = {
        enabled = true,
        title = '🏁 GANG RALLY STARTING SOON',
        -- the second %s is the time left as HH:MM:SS
        body = 'The street race "%s" starts in %s. Participants, be ready! Head to the flashing start zone.',
        duration = 9000,
        kind = 'rally',
    },
    -- Race over (shown at once when the race finishes). %s = event, winner, winner's gang.
    rallyEnded = {
        enabled = true,
        title = '🏁 GANG RALLY ENDED',
        body = '"%s" is over. Winner: %s (%s).',
        duration = 9000,
        kind = 'success',
    },
    rallyEndedNoWinner = {
        enabled = true,
        title = '🏁 GANG RALLY ENDED',
        body = '"%s" is over. Nobody finished in time.',
        duration = 8000,
        kind = 'warn',
    },
    rallyEndedCancelled = {
        enabled = true,
        title = '🏁 GANG RALLY CANCELLED',
        body = 'The race "%s" was cancelled by an administrator.',
        duration = 8000,
        kind = 'danger',
    },
    -- Sent once before a SCHEDULED race (Config.PreScheduleAnnounceSeconds ahead).
    rallyScheduledSoon = {
        enabled = true,
        title = '🏁 UPCOMING GANG RALLY',
        body = 'A street race is scheduled to start soon — get your ride ready.',
        duration = 9000,
        kind = 'rally',
    },

    -- ── Container Wars ──
    -- Only the "upcoming" notice is set here. The in-event banners (round start, bidding open, lot opening / won / unsold,
    -- final round) are written by server/modules/container_wars_runtime.lua; a round's own title and story come from the
    -- event setup (Auction Rules → each round). `kind = 'containerwars'` is the event's harbour-green banner theme
    -- (web/src/lib/hud/eventThemes.js).
    upcomingContainerWars = {
        title = 'Upcoming Container Wars: %s',   -- %s = event name
        duration = 10000,
        kind = 'containerwars',
    },

    -- ── Gang Territory Auction ──
    -- Pre-event notice. The in-event banners (auction open, territory sold, rival challenge, war scheduled / starting /
    -- captured) are written by server/modules/territory_*.lua; their titles and durations live in Config.Territory.
    upcomingTerritory = {
        title = 'Upcoming Gang Territory Auction: %s',   -- %s = event name
        duration = 10000,
        kind = 'territory',
    },

    -- ── Convoy Lifecycle ──
    -- %s = cargo description (e.g. 'Bank Reserve Gold Bullion')
    convoyStart = {
        enabled = true,
        title = '🚚 HIGH-VALUE CONVOY DEPARTED',
        body = 'A transport convoy carrying %s has departed under armed escort. Intercept the convoy or protect the shipment!',
        duration = 8000,
        kind = 'start',
    },

    convoyDelivered = {
        enabled = true,
        title = '🚚 Convoy Delivered',
        body = 'The convoy was successfully delivered.',
        duration = 8000,
        kind = 'success',
    },

    -- %s = capturing gang name/label
    convoyCaptured = {
        enabled = true,
        title = '🚚 Convoy Captured',
        body = '%s successfully captured the convoy.',
        fallbackBody = 'The convoy has been intercepted.',
        duration = 8000,
        kind = 'danger',
    },

    convoyFailed = {
        enabled = true,
        title = '🚚 Convoy Failed',
        body = 'The convoy did not reach its destination in time.',
        duration = 8000,
        kind = 'danger',
    },

    convoyCancelled = {
        enabled = true,
        title = '🚚 Convoy Cancelled',
        body = 'The convoy was terminated by an administrator.',
        duration = 8000,
        kind = 'danger',
    },

    standDown = {
        enabled = true,
        delaySeconds = 6,
        title = '🚚 Convoy Event Concluded',
        body = 'All participants and police are requested to clear the area immediately. Do not engage in further shootouts or hostilities — the convoy event has ended.',
        duration = 9000,
        kind = 'info',
    },

    convoyStandDown = {
        enabled = true,
        delaySeconds = 6,
        title = '🚚 Convoy Event Concluded',
        body = 'All participants and police are requested to clear the area immediately. Do not engage in further shootouts or hostilities — the convoy event has ended.',
        duration = 9000,
        kind = 'info',
    },

    rallyStandDown = {
        enabled = true,
        delaySeconds = 6,
        title = 'Gang Rally Concluded',
        body = 'All units stand down. Scene cleared and race operation terminated.',
        duration = 9000,
        kind = 'info',
    },

    airdropStandDown = {
        enabled = true,
        delaySeconds = 6,
        title = 'Airdrop Operation Concluded',
        body = 'All participants are requested to clear the drop zones immediately. Airdrop operation terminated.',
        duration = 9000,
        kind = 'info',
    },

    hotCargoStandDown = {
        enabled = true,
        delaySeconds = 6,
        title = '🔥 Hot Cargo Run Concluded',
        body = 'Contraband run terminated. All units stand down.',
        duration = 9000,
        kind = 'info',
    },

    -- ── Hot Cargo Run Lifecycle ──
    hotCargoStart = {
        enabled = true,
        title = '🔥 HOT CARGO STARTED',
        body = 'A contraband operation "%s" is active! Search the marked zones and hijack the cargo trucks.',
        duration = 8000,
        kind = 'start',
    },

    hotCargoEventStarted = {
        enabled = true,
        title = '🔥 HOT CARGO STARTED',
        body = 'A contraband operation "%s" is active! Search the marked zones and hijack the cargo trucks.',
        duration = 8000,
        kind = 'start',
    },

    -- 1st %s = gang name, 2nd %s = truck number
    hotCargoHijacked = {
        enabled = true,
        title = '🔥 HOT CARGO',
        body = '%s has hijacked Cargo Truck #%s.',
        duration = 8000,
        kind = 'danger',
    },

    hotCargoTruckHijacked = {
        enabled = true,
        title = '🔥 HOT CARGO',
        body = '%s has hijacked Cargo Truck #%s.',
        duration = 8000,
        kind = 'danger',
    },

    -- %s = truck number
    hotCargoTruckDisabled = {
        enabled = true,
        title = '🔥 HOT CARGO — TRUCK DISABLED',
        body = 'Cargo Truck #%s has broken down and is no longer moving. Participating gangs can attempt to loot the truck.',
        duration = 8000,
        kind = 'danger',
    },

    hotCargoTruckBroken = {
        enabled = true,
        title = '🔥 HOT CARGO — TRUCK DISABLED',
        body = 'Cargo Truck #%s has broken down and is no longer moving. Participating gangs can attempt to loot the truck.',
        duration = 8000,
        kind = 'danger',
    },

    -- 1st %s = truck number, 2nd %s = driver name, 3rd %s = gang name
    hotCargoTruckCritical = {
        enabled = true,
        title = '🔥 HOT CARGO: TRUCK CRITICAL',
        body = 'Cargo Truck #%s driven by %s (%s) is taking heavy damage and about to break down!',
        duration = 7000,
        kind = 'danger',
    },

    -- 1st %s = truck number, 2nd %s = gang name
    policeHotCargoAlert = {
        enabled = true,
        title = '🚨 POLICE DISPATCH: HOT CARGO ALERT',
        body = 'Cargo Truck #%s has been hijacked by %s! GPS tracking enabled.',
        duration = 8000,
        kind = 'danger',
    },

    -- %s = gang name/label
    hotCargoSecured = {
        enabled = true,
        title = '🔥 HOT CARGO SECURED',
        body = '%s delivered the contraband shipment! Loot crate dropped at the delivery site. Protected by server rules for 60 minutes.',
        duration = 9000,
        kind = 'success',
    },

    -- 1st %s = gang name, 2nd %s = how it was opened ('cracked'/'hacked'), 3rd %s = truck name
    hotCargoTruckLooted = {
        enabled = true,
        title = '🔥 HOT CARGO — TRUCK LOOTED',
        body = '%s has %s the cargo of %s.',
        duration = 7000,
        kind = 'success',
    },

    -- Gang-facing version of the critical warning (no driver name). 1st %s = truck number, 2nd %s = gang name
    hotCargoTruckCriticalGang = {
        enabled = true,
        title = '🔥 HOT CARGO: TRUCK CRITICAL',
        body = 'Cargo Truck #%s held by %s is taking heavy damage and about to break down!',
        duration = 7000,
        kind = 'danger',
    },

    -- Shown to whoever is driving the truck when it's nearly out of health
    hotCargoVehicleCritical = {
        enabled = true,
        title = '🔥 HOT CARGO — VEHICLE CRITICAL',
        body = 'Your cargo truck is about to break down — get ready to bail out!',
        duration = 6000,
        kind = 'danger',
    },

    hotCargoCompleted = {
        enabled = true,
        title = '🔥 HOT CARGO COMPLETED',
        body = 'Contraband shipment was successfully delivered to the dropoff zone! Unlocked reward crate is secured.',
        duration = 8000,
        kind = 'success',
    },

    hotCargoFailed = {
        enabled = true,
        title = '🔥 HOT CARGO FAILED',
        body = 'Time expired or all contraband vehicles were lost before delivery.',
        duration = 8000,
        kind = 'warn',
    },

    hotCargoCancelled = {
        enabled = true,
        title = '🔥 HOT CARGO CANCELLED',
        body = 'The contraband operation was terminated by an administrator.',
        duration = 8000,
        kind = 'danger',
    },

    hotCargoScheduledSoon = {
        enabled = true,
        title = '🔥 UPCOMING HOT CARGO RUN: %s',
        body = 'A contraband operation is scheduled to start soon — prepare your crew.',
        duration = 9000,
        kind = 'hotcargo',
    },

    -- ── Container Wars Lifecycle ──
    -- %s = auction event name
    containerWarsStart = {
        enabled = true,
        title = '📦 CONTAINER WARS STARTED',
        body = 'The harbour container auction "%s" has officially started! Enter the bidding perimeter to compete.',
        duration = 8000,
        kind = 'start',
    },

    -- 1st %d = current round, 2nd %d = total rounds, 3rd %d = batch container count
    containerWarsRoundStart = {
        enabled = true,
        title = '📦 CONTAINER WARS — ROUND %d / %d',
        body = 'Round %d has begun! Staging %d containers for auction.',
        duration = 7000,
        kind = 'info',
    },

    -- 1st %s = gang name, 2nd %s = container name, 3rd %s = final bid amount
    containerWarsContainerWon = {
        enabled = true,
        title = '🏆 CONTAINER WON',
        body = '%s won %s for $%s!',
        duration = 8000,
        kind = 'success',
    },

    -- 1st %s = top gang name, 2nd %d = containers won
    containerWarsEnded = {
        enabled = true,
        title = '📦 CONTAINER WARS CONCLUDED',
        body = 'The container auction has ended! Top Gang: %s (%d containers won).',
        duration = 9000,
        kind = 'success',
    },

    containerWarsCancelled = {
        enabled = true,
        title = '📦 CONTAINER WARS CANCELLED',
        body = 'The container auction was terminated by an administrator.',
        duration = 8000,
        kind = 'danger',
    },

    containerWarsStandDown = {
        enabled = true,
        delaySeconds = 6,
        title = '📦 Container Wars Concluded',
        body = 'All participants are requested to clear the harbour container yard. Bidding and auction operations terminated.',
        duration = 9000,
        kind = 'info',
    },

    containerWarsScheduledSoon = {
        enabled = true,
        title = '📦 UPCOMING CONTAINER WARS AUCTION: %s',
        body = 'A container wars harbour auction is scheduled to start soon — prepare your gang funds.',
        duration = 9000,
        kind = 'info',
    },

    -- %s = truck label / role (e.g. 'Primary Cargo Truck' or 'Cargo Truck #1')
    truckDisabledLootable = {
        enabled = true,
        title = '🚚 CONVOY — TRUCK DISABLED',
        body = '%s has broken down and is no longer moving. Participating gangs can attempt to loot the truck.',
        duration = 8000,
        kind = 'danger',
    },

    destinationReached = {
        enabled = true,
        title = '🚚 Convoy Update',
        body = 'Convoy destination reached. Delivery zone is active.',
        duration = 7000,
        kind = 'info',
    },

    -- Fires once per convoy, the moment the lead truck gets within
    -- Config.DestinationProximityWarningDistance of the destination — a
    -- heads-up BEFORE actual arrival (destinationReached above), not a
    -- duplicate of it. This is also the moment gang first gets to see the
    -- destination zone sprite at all (police can already see it — see
    -- Config.PoliceAlwaysSeeRouteZones).
    destinationProximityGang = {
        enabled = true,
        title = '🚚 Almost There',
        body = 'Be quick — the trucks will be delivered soon!',
        duration = 7000,
        kind = 'warn',
    },

    destinationProximityPolice = {
        enabled = true,
        title = '🚚 Nice Work',
        body = "You've almost got it — safely escort the trucks the rest of the way!",
        duration = 7000,
        kind = 'success',
    },

    -- 1st %d = trucks delivered so far, 2nd %d = total cargo trucks, 3rd %d = trucks still on the road, %s = plural 's'.
    -- Shown to every joined police officer, the joined gangs and on-duty admins (it used to skip police that had not joined).
    truckDelivered = {
        enabled = true,
        title = '🚚 Truck Delivered %d/%d',
        body = 'Truck delivered (%d/%d) — %d truck%s remaining.',
        duration = 5000,
        kind = 'success',
    },

    -- 1st %s = gang name, 2nd %s = method ('cracked' or 'hacked')
    truckCaptured = {
        enabled = true,
        title = '🚚 Convoy Truck Captured',
        body = "%s has successfully captured the convoy truck's cargo (%s open).",
        duration = 7000,
        kind = 'success',
    },

    truckDestroyed = {
        enabled = true,
        title = '🚚 Convoy Truck Lost',
        body = 'A convoy truck has been destroyed. Police: leave it and continue escorting the rest of the convoy.',
        duration = 6500,
        kind = 'danger',
    },

    truckOverturned = {
        enabled = true,
        title = '🚚 Convoy Truck Overturned',
        body = 'A convoy truck has overturned and is disabled! Gangs can intercept the cargo.',
        duration = 6500,
        kind = 'danger',
    },

    -- %s = truck condition (e.g. 'critical' or 'disabled')
    truckStatusUpdate = {
        enabled = true,
        title = '🚚 Convoy Update',
        body = 'A convoy truck is %s.',
        duration = 5000,
        kind = 'warn',
    },

    -- Sent only to the human officer actually driving a CRITICAL-health truck
    -- (not the whole convoy) — see truckStatusUpdate above for the general
    -- banner everyone else gets.
    vehicleCritical = {
        enabled = true,
        title = '🚚 VEHICLE CRITICAL',
        body = 'Your truck is about to explode — bail out now!',
        duration = 6000,
        kind = 'danger',
    },

    -- %s = capturing gang name/label
    truckLost = {
        enabled = true,
        title = '🚚 Convoy Truck Lost',
        body = 'A convoy truck has been intercepted by %s and is lost. Police: leave it and continue escorting the rest of the convoy.',
        duration = 8000,
        kind = 'danger',
    },

    allCargoLost = {
        enabled = true,
        title = '🚚 Convoy Update',
        body = 'All cargo trucks are down, but the convoy presses on.',
        duration = 6000,
        kind = 'warn',
    },

    -- %s = checkpoint name
    checkpointSecured = {
        enabled = true,
        title = '🚚 Checkpoint Secured',
        body = '%s - Convoy truck secured. Defend the position!',
        duration = 8000,
        kind = 'checkpoint',
    },

    -- 1st %s = checkpoint name
    checkpointPoliceArrived = {
        enabled = true,
        title = '🚚 CHECKPOINT REACHED',
        body = '%s reached. Convoy trucks secured! Start protecting the convoy from incoming hostiles.',
        duration = 8000,
        kind = 'checkpoint',
    },

    -- 1st %s = checkpoint name, 2nd %s = duration text (e.g. '2 minutes')
    checkpointGangAlert = {
        enabled = true,
        title = '🚚 CONVOY HELD AT CHECKPOINT',
        body = 'The convoy has stopped at %s and will hold here for %s. Intercept the trucks now!',
        duration = 8000,
        kind = 'danger',
    },

    -- %s = checkpoint name
    checkpointCleared = {
        enabled = true,
        title = '🚚 Checkpoint Cleared',
        body = '%s survived — police and the convoy truck are proceeding to the next checkpoint.',
        duration = 6000,
        kind = 'success',
    },

    -- %s = checkpoint name/label
    checkpointBreak = {
        enabled = true,
        title = '%s',
        body = 'Convoy is taking a short break. Hold position.',
        duration = 5000,
        kind = 'warn',
    },

    -- %s = ambush name/label
    ambushAlert = {
        enabled = true,
        title = '🚚 Convoy Alert',
        body = '%s — hostiles incoming, stay alert!',
        duration = 6000,
        kind = 'danger',
    },

    -- ── Gang Airdrop Event Lifecycle ──
    gangAirdropStart = {
        enabled = true,
        title = '📦 AIRDROP EVENT ACTIVE',
        body = 'Supply drops have been dispatched across the territory. Compete to secure the loot!',
        duration = 8000,
        kind = 'start',
    },

    gangAirdropCompleted = {
        enabled = true,
        title = '📦 Airdrop Event Ended',
        body = "At least one gang made off with a drop's contents.",
        duration = 8000,
        kind = 'success',
    },

    gangAirdropFailed = {
        enabled = true,
        title = '📦 Airdrop Event Ended',
        body = 'Nobody claimed any of the drops in time.',
        duration = 8000,
        kind = 'warn',
    },

    gangAirdropCancelled = {
        enabled = true,
        title = '📦 Airdrop Event Cancelled',
        body = 'The event was terminated by an administrator.',
        duration = 8000,
        kind = 'danger',
    },

    -- ── Airdrop Drops ──
    -- %s = drop or zone name/label
    airdropInbound = {
        enabled = true,
        title = '📦 Incoming Airdrop',
        body = 'A supply plane has been spotted inbound for %s.',
        duration = 6000,
        kind = 'info',
    },

    airdropActive = {
        enabled = true,
        title = '📦 Airdrop',
        body = 'An emergency supply drop (%s) has appeared — hostiles are guarding it.',
        duration = 7000,
        kind = 'info',
    },

    airdropLanded = {
        enabled = true,
        title = '📦 Airdrop Landed',
        body = '%s has landed — hostiles are guarding it. Look for the red smoke.',
        duration = 7000,
        kind = 'danger',
    },

    -- 1st %s = gang or player name, 2nd %s = drop/zone name, 3rd %s = method ('cracked' or 'hacked')
    airdropCaptured = {
        enabled = true,
        title = '📦 Airdrop Captured',
        body = '%s has successfully captured %s (%s open).',
        duration = 7000,
        kind = 'success',
    },

    -- Shown after a Gang Airdrop event ends: one banner for each gang that looted drops (most drops first), with no reward details.
    -- title: %s = gang name.  body: %d = how many drops it secured, %s = their names (the first four, then "and N more").
    airdropCongrats = {
        enabled = true,
        title = '🏆 Congratulations, %s!',
        body = 'Drops secured: %d — %s',
        duration = 8000,
        kind = 'airdrop',
    },

    -- ── Upcoming Event Broadcasts ──
    -- %s = event name
    upcomingConvoy = {
        enabled = true,
        title = '🚚 Upcoming Convoy Event: %s',
        duration = 10000,
        kind = 'convoy',
    },

    upcomingAirdrop = {
        enabled = true,
        title = '📦 Upcoming Gang Airdrop: %s',
        duration = 10000,
        kind = 'airdrop',
    },

    upcomingHotCargo = {
        enabled = true,
        title = '🔥 Upcoming Hot Cargo Run: %s',
        duration = 10000,
        kind = 'hotcargo',
    },

    -- ── Gang Rally / Street Race Event Lifecycle ──
    upcomingRally = {
        enabled = true,
        title = '🏁 Upcoming Gang Rally: %s',
        duration = 10000,
        kind = 'rally',
    },

    rallyStart = {
        enabled = true,
        title = '🏁 GANG RALLY STARTED',
        body = 'The green flag is down! Racers are off the line — compete to claim 1st place!',
        duration = 8000,
        kind = 'start',
    },

    rallyCheckpoint = {
        enabled = true,
        title = 'Checkpoint Reached',
        body = '%s has punched through %s!',
        duration = 5000,
        kind = 'info',
    },

    rallyWinner = {
        enabled = true,
        title = '🏆 GANG RALLY CHAMPION',
        body = '%s (%s) has taken 1st place and claimed the prize!',
        duration = 9000,
        kind = 'success',
    },

    -- Fired ONLY to police after the race concludes (NFS-style pursuit alert).
    -- %s = race name, %s = finish stage name
    rallyPolicePursuitEnd = {
        enabled = true,
        title = '🚨 10-99: ILLEGAL RACE TERMINATED — SUSPECTS FLEEING',
        body = 'An illegal street race ("%s") just concluded at %s! Racers and modified vehicles are fleeing the scene. Converge and initiate high-speed pursuit!',
        duration = 9000,
        kind = 'danger',
    },

    rallyFailed = {
        enabled = true,
        title = 'Gang Rally Concluded',
        body = 'No racers crossed the finish line before the timer expired.',
        duration = 8000,
        kind = 'warn',
    },

    rallyCancelled = {
        enabled = true,
        title = 'Gang Rally Cancelled',
        body = 'The rally event was terminated by an administrator.',
        duration = 8000,
        kind = 'danger',
    },
}

-- ═══════════════════════════════════════════════════════════════════════════════════
-- SECTION 11: NOTIFICATION SOUNDS
-- 1) Put any .mp3 / .ogg / .wav into the resource's  sounds/  folder.
-- 2) Give it a short name in  library  below.
-- 3) Use that name anywhere in the rules (default / routes / byKind / byStatus / byTitle / byNoticeKind).
-- ═══════════════════════════════════════════════════════════════════════════════════
--
-- A sound value in the rules can be:
--   'popup'                           a name from the library (a plain file name from sounds/ also works)
--   { file = 'popup', volume = 0.5 }  the same at its own volume (0.0 – 1.0, multiplied with Config.Sounds.volume)
--   false                             silent
--   (nil / not listed)                fall through to the next rule
--
-- On-screen announcement banners pick their sound in this order (first match wins):
--   1. byTitle   2. byStatus   3. byKind   4. routes.banner   5. default
Config.Sounds = {
    enabled = true,
    volume  = 0.7,                           -- master volume for every sound below

    -- Your sounds:  name = 'file in the sounds/ folder'   (or { file = '...', volume = 0.6 })
    -- Other scripts can play one too:  exports.nova_convoytruck:PlaySound('rival')
    library = {
        popup = 'simple_notification.mp3',   -- the standard notification pop
        rival = 'fahhh.mp3',                 -- gang rival war results
        click = 'ui_click.mp3',              -- mouse click on any tab / button in every panel (see uiClick below)
        -- alarm = 'my_alarm.mp3',           -- add more here, then use 'alarm' in the rules below
    },

    default = 'popup',                       -- used when nothing more specific matches

    -- Click sound for every interactive panel of the script (admin tablet, event status panel, armory, bidder,
    -- results, registration, showroom ...): tabs, buttons, toggles, dropdowns, list rows and links.
    -- Swap the sound by pointing `sound` at another library name / file in sounds/ (false or enabled = false = off).
    uiClick = {
        enabled = true,
        sound   = 'click',                   -- library name (or a plain file name from sounds/)
        volume  = 0.6,                       -- 0.0 – 1.0, multiplied with Config.Sounds.volume
    },

    -- Admin command to hear the sounds (false = no command). In game:
    --   /soundtest list                    show the library and every rule
    --   /soundtest popup                   play a library name, or any file in the sounds folder (e.g. fahhh.mp3)
    --   /soundtest status CAPTURED         play what a banner with that badge would play
    --   /soundtest kind danger             ... a banner of that kind
    --   /soundtest title Convoy Captured   ... a banner with that title
    --   /soundtest route reward            play a route (banner / reward / territoryNotice)
    --   /soundtest notice war-cancelled    ... a territory notice of that kind
    testCommand = 'soundtest',

    -- One entry per kind of server notification
    routes = {
        banner          = 'popup',   -- every on-screen announcement banner (convoy, hot cargo, airdrop, race, TDM, Container Wars, territory, admin announcements)
        reward          = 'popup',   -- the "you were paid" reward card
        territoryNotice = 'popup',   -- gang / territory pop-up notices (challenges, capture alerts, loot ready ...)
    },

    -- By the banner's colour theme / kind: start, success, danger, warn, info, checkpoint, rally, tdm, territory, containerwars
    -- Every kind is listed so you can change any of them by swapping the name (e.g. danger = 'alarm', or { file = 'popup', volume = 0.4 }).
    byKind = {
        start        = 'popup',   -- convoy / event started
        success      = 'popup',   -- delivered, completed, winner
        danger       = 'popup',   -- captured, failed, cancelled, truck disabled
        warn         = 'popup',   -- warnings
        info         = 'popup',   -- general info and admin announcements
        checkpoint   = 'popup',   -- checkpoint secured / released
        rally        = 'popup',   -- gang rally / street race
        tdm          = 'popup',   -- TDM and tournament
        territory    = 'popup',   -- territory auction and war
        containerwars = 'popup',  -- Container Wars
    },

    -- By the badge text on the right of the banner (upper-case). Gang rival war results: CAPTURED = the attackers won,
    -- DEFENDED = the defenders won — everybody on the server hears it.
    byStatus = {
        CAPTURED = 'rival',
        DEFENDED = 'rival',
        VICTORY  = 'rival',             -- the winning gang's own "loot Gang XP" banner
        -- ['NO SHOW'] = 'popup',       -- add any other badge text the same way
    },

    -- By words in the banner title (plain text, not case sensitive). Use this to give ONE specific announcement its own sound.
    byTitle = {
        -- { match = 'Convoy Captured',  sound = 'rival' },
        -- { match = 'HOT CARGO',        sound = { file = 'popup', volume = 0.5 } },
    },

    -- By the kind of a territory notice (set a kind to false for silent).
    byNoticeKind = {
        ['rival']              = 'popup',   -- a rival challenge involving your gang
        ['rival-admin']        = 'popup',   -- admin copy of a challenge
        ['challenge']          = 'popup',   -- you were challenged
        ['challenge-sent']     = 'popup',   -- your challenge was sent
        ['challenge-accepted'] = 'popup',
        ['challenge-declined'] = 'popup',
        ['war-scheduled']      = 'popup',
        ['war-reminder']       = 'popup',
        ['war-cancelled']      = 'popup',
        ['capture']            = 'popup',   -- your territory is being taken
        ['expansion']          = 'popup',
        ['loot-ready']         = 'popup',
        ['error']              = 'popup',
    },
}

-- ── Operation Crackdown (Gang vs Police) ─────────────────────────────────────────────────────────────────────────
-- One gang against the police on duty, inside a combat zone the admin draws (circle or square). A hard push from both sides, NO points:
-- a fighter who dies (down / dead, the same rule Rival Wars uses) or stays outside the zone too long is ELIMINATED from the operation
-- (they respawn or EMS revives them, but they are out and cannot shoot inside the zone). The side with fighters left when the other has
-- none wins; at the time limit the side with more fighters standing wins, equal numbers are a draw. Nobody is placed or teleported.
-- Start areas: the admin can draw a box for the gang and a box for the police (Combat Zone tab). Only the fighters standing inside their
-- own box when the countdown ends take part (and are paid); the others are told and left out. No box drawn = the old rule (everyone present).
Config.Crackdown = {
    -- the defaults the admin form starts from (every one of them can be changed per event)
    defaults = {
        prepSeconds = 120,           -- preparation countdown before the fight opens (the roster is taken here and locked when it ends)
        durationMinutes = 20,        -- how long the fight runs
        outsideSeconds = 30,         -- seconds a fighter may stay outside the zone before being eliminated
        minGang = 1,                 -- members of the target gang that must be there when the fight opens
        minPolice = 1,               -- officers on duty that must be there when the fight opens
        zoneRadius = 120.0,          -- circle radius, metres
        zoneSize = 120.0,            -- square half-side, metres
        gangLoseXpPenalty = 0,       -- Gang XP the target gang loses when it loses (0 = none)
    },
    limits = { prepMax = 1800, outsideMax = 300, radiusMax = 600.0 },
    leaveGraceSeconds = 60,          -- a fighter who goes off duty / disconnects is eliminated after this long
    messages = {   -- {name} {gang} {minutes} {prep} are filled in. These are the ONLY announcement texts: the event form has no text boxes for them.
        prepTitle = 'OPERATION CRACKDOWN',
        prepBody = '{gang} vs the Police — {name}. The fight opens in {prep}. Get to the combat zone: the roster is locked when it starts.',
        startTitle = 'CRACKDOWN: FIGHT!',
        startBody = 'The combat zone is live for {minutes} minutes. {gang} vs the Police — if you go down, you are out.',
        warning = 'You are outside the combat zone! Return now or you are eliminated.',
        winGang = '{gang} WINS THE CRACKDOWN!',
        winPolice = 'THE POLICE WIN THE CRACKDOWN!',
        draw = 'CRACKDOWN ENDS IN A DRAW',
        cancelled = 'OPERATION CRACKDOWN CANCELLED',
        startOut = 'You were not inside your start area when the countdown ended, so you are not part of this operation.',
    },
}

-- Sync standDown alias between AnnouncementBanners and ConvoyEndStandDown
Config.AnnouncementBanners.standDown = Config.ConvoyEndStandDown

return Config
