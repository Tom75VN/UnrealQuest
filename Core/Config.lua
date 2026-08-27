--[[
UnrealQuest / Core/Config.lua

SavedVariables access.

Persistence constraints established for this client:
  * The SavedVariables writer does not escape backslashes safely, so stored
    asset paths can lose separators or turn into control characters after a
    reload. UnrealQuest therefore never persists a media path. Anything that
    needs one stores a stable key and rebuilds the path at runtime, and
    Sanitize rejects any string containing a backslash on the way in and out.
  * Nested tables themselves round-trip through the client writer correctly.
    The store is still deliberately shallow (profile -> section -> scalar or a
    keyed set of scalars), so that the saved file cannot grow into an arbitrary
    object graph and so a corrupted branch can be dropped without losing the
    rest of the file.

TWO STORES, AND THE LINE BETWEEN THEM.

  * `UnrealQuestDB` (`## SavedVariables`) is per ACCOUNT and holds settings.
    A player who sets a tracker width or picks an objective style means it for
    the whole account, and having to set it again on every alt would be a bug.
  * `UnrealQuestCharDB` (`## SavedVariablesPerCharacter`) is per CHARACTER and
    holds what a character DID: the quest-completion record and the state of
    the pfQuest import that can seed it. A completion is a fact about one
    character; sharing it across an account marks quests done on a level-1 alt
    that has never left its starting zone.

`CHARACTER_SECTIONS` below is the whole of that split -- naming a section there
is what moves it, and every caller keeps using GetSection/SetSectionEntry
unchanged. The per-character file layout is established from disk (see the
`savedvariables.per_addon_files_and_foreign_globals` knowledge record): this
client writes `## SavedVariablesPerCharacter` globals to
`Saved/Account/<account>/<realm>/<character>/SavedVariables/<AddonName>.lua`,
which is how pfQuest's own per-character history is stored.
]]

local UQ = UnrealQuest
local Config = UQ:NewModule("Config")

local SCHEMA = 1
local MAX_SET_ENTRIES = 250

-- Per-section overrides of MAX_SET_ENTRIES.
--
-- 250 is the right ceiling for a section that holds a working set -- the
-- quests the player is tracking, hiding or folding right now. It is the wrong
-- ceiling for the quest-history sections, which hold one entry per quest the
-- character has ever finished and grow monotonically: 250 is reached by a
-- character who is nowhere near done, and everything past it is silently
-- refused. Importing pfQuest's history (Quest/PfQuestImport.lua) hits that
-- wall immediately, since it arrives as a whole career at once.
--
-- The bound is the bundled data itself: Database/quests.lua carries 4433
-- Vanilla quests, so a history can never legitimately name more than that.
-- 6000 leaves headroom for IDs the data does not know without being an open
-- door -- these sections stay bounded, they are just bounded by the world
-- rather than by a working-set number that never applied to them.
local SECTION_LIMITS = {
    questHistory = 6000,
    questHistoryManual = 6000,
    questHistoryImported = 6000,
}

local function SectionLimit(name)
    return SECTION_LIMITS[name] or MAX_SET_ENTRIES
end

-- Sections that live in the per-character store rather than the account one.
-- See the header: this table is the entire account/character split.
local CHARACTER_SECTIONS = {
    questHistory = true,
    questHistoryManual = true,
    questHistoryImported = true,
}

local defaults = {
    debug = false,
    pollInterval = 0.5,

    -- Interface language, as one of the four-letter codes Core/Locale.lua
    -- registers. Account-wide like every other setting here: a language is a
    -- reading preference, not an alt's layout.
    --
    -- Only ever read when unrealUI is NOT installed. With unrealUI present the
    -- language is whatever is set there and this value is left untouched, so
    -- uninstalling unrealUI later returns the player to their own last choice
    -- rather than to English.
    --
    -- The default is English, but a first run with no unrealUI seeds it from
    -- GetLocale instead, so a French client opens in French without the player
    -- having to find the flag row first.
    language = "enUS",

    restoreTracking = true,
    -- Seasonal quests are hidden by default: the client cannot report which
    -- world events are running, so they would otherwise show all year.
    showEventQuests = false,
    -- A quest that is ready to hand in always gets its turn-in "?" marker.
    -- This adds the dimmed "?" for quests still in progress, which is where a
    -- quest the player is carrying will eventually be handed in. On by
    -- default: "where do I turn this in" is a question worth answering before
    -- the last objective ticks over, and the dim tint keeps it from reading as
    -- an available hand-in.
    showInProgressTurnIns = true,

    -- How the world map draws quest objectives. true (the default) is one dot
    -- per spawn point, in the same style the minimap already uses -- exact
    -- positions, which is also the presentation the two map layers then share.
    -- false swaps that for the blue area: the spawn cloud reduced to 2.5%
    -- cells and painted edge to edge, which says "somewhere in here" instead.
    -- Both presentations are drawn by the same pooled frames in
    -- Map/WorldMapPins.lua and carry the same colours and the same hover
    -- tooltip; nothing else about the map layer changes with this setting.
    mapObjectiveDots = true,

    -- Percentage of the 9px world-map objective dot. 100 is 10% smaller than
    -- the former 10px default; the settings slider allows 50-150.
    mapObjectiveDotScale = 100,

    -- Markers whose icons collide on the world map cannot be hovered apart,
    -- so hovering any of them describes all of them in one tooltip. On by
    -- default: without it, whichever pin the pool happened to place last
    -- answers for the whole spot and the others are simply unreachable.
    -- false restores the strict one-marker-one-tooltip behaviour, at the cost
    -- of the markers underneath. See Map/WorldMapPins.lua.
    mapClusterTooltips = true,

    -- The same quest scene as the world map, drawn around the player on the
    -- minimap: one dot per raw quest-creature spawn plus the "!" and "?" markers,
    -- creature positions are shown only while actually in view; distant
    -- giver and turn-in markers remain clamped to the minimap edge. On by
    -- default -- it is the only layer on this client that can say "that way"
    -- while the player is standing still, since there is no readable facing
    -- for a HUD arrow. See Map/MinimapPins.lua for the two structural limits:
    -- zoom steps other than 0 use unverified Vanilla constants, and indoors
    -- cannot be detected at all.
    minimapPins = true,

    -- Off-view giver "!" and turn-in "?" pins default to CLAMPED at the
    -- minimap edge (faded), pointing "that way, further than this". false
    -- hides them instead once they leave the view, matching how objective
    -- dots already behave, for a less crowded minimap. Creature objective
    -- dots are never clamped either way -- this only affects the two icon
    -- pools. See Map/MinimapPins.lua.
    minimapPinsClampEdge = true,
    -- Deliberately not on the options page: the page is at its height budget,
    -- and this is an escape hatch rather than a preference -- "/uq minimap
    -- indoors on|off" -- for the case where the interior test misfires.
    minimapPinsHideIndoors = true,

    -- Vendor points for quest items that are bought rather than killed for or
    -- looted -- see Map/QuestVendorPins.lua. On by default: without them the
    -- map has nothing at all to say about such a quest, and the points come
    -- and go with the objective instead of standing there permanently.
    questVendorPins = true,

    -- Percentage of the 10.8px minimap objective dot. 100 is 10% smaller than
    -- the former 12px default; the settings slider allows 50-150.
    minimapObjectiveDotScale = 100,

    -- Nearby service NPCs ---------------------------------------------------
    --
    -- The movable HUD button opens a compact multi-select menu. Categories
    -- start disabled so installing the addon does not add a second map scene
    -- until the player asks for one. The selection and button position both
    -- survive a reload.
    npcCategoryAuctioneer = false,
    npcCategoryBanker = false,
    npcCategoryBattlemaster = false,
    npcCategoryFlight = false,
    npcCategoryInnkeeper = false,
    npcCategoryMailbox = false,
    npcCategoryMeetingstone = false,
    npcCategoryRepair = false,
    npcCategorySpirithealer = false,
    npcCategoryStablemaster = false,
    npcCategoryVendor = false,
    npcCategoryTrainer = false,

    -- World nodes, kept below the service rows in the same menu. These read
    -- the bundled meta relations chests/fish/herbs/mines/rares rather than a
    -- service relation, and a single zone can hold hundreds of them, so they
    -- are only gathered from the database while the row is checked.
    npcCategoryChests = false,
    npcCategoryHerbs = false,
    npcCategoryMines = false,
    npcCategoryFish = false,
    npcCategoryRares = false,

    -- No default point/x/y here on purpose: until the player drags the
    -- button, NpcPins:OnInit re-anchors it live beside wherever the settings
    -- icon actually lands (Client.AnchorHudButtonBesideSettingsIcon), which a
    -- fixed default here would fight with. A drag persists real values
    -- through Config:Set, same as the tracker window.

    -- Raid target marks over quest creatures -------------------------------
    --
    -- The only way left to draw anything over one specific creature in the 3D
    -- world on this client: no unit position, no player facing, and no
    -- nameplate widget exists (docs/CLIENT-COMPATIBILITY.md item 12). The
    -- engine draws a raid mark over the unit itself, so the addon only has to
    -- name the unit.
    questMarks = true,

    -- Which of the eight marks. 1 star, 2 circle, 3 diamond, 4 triangle,
    -- 5 moon, 6 square, 7 cross, 8 skull.
    questMarkIndex = 1,
    questMarkTurnInIndex = 3,

    -- A raid mark is SHARED state: every group member sees it and setting one
    -- overwrites whatever they had put there. The realm ignores SetRaidTarget
    -- while solo, so group leader / assistant is the only remaining route and
    -- it stays opt-in rather than changing shared group marks silently.
    questMarksInGroup = false,

    -- Rare / elite proximity alert -------------------------------------------
    --
    -- See World/RareAlert.lua. This is a PROXIMITY alert over the bundled
    -- spawn data, not a sighting: this client has no way to enumerate the
    -- creatures around the player, so "in range" means "within rareAlertRange
    -- yards of a spawn point recorded for this creature".
    rareAlert = true,

    -- Yards. 120 is about a quarter of the minimap's measured 466.6-yard
    -- zoom-0 span, so the creature's own minimap dot is on screen when the
    -- card lands. World/RareAlert.lua clamps this to 20-500.
    rareAlertRange = 120,

    -- Ordinary elites (rank 1) are 816 of the 1182 creatures the alert can
    -- see -- every elite camp in the open world. Alerting on them by default
    -- would make the card furniture, so rare (257), rare elite (81) and boss
    -- (28) are always on and this adds the fourth rank.
    rareAlertElites = false,

    -- Seconds the card stays up on its own. Clamped to 3-60.
    rareAlertSeconds = 12,

    -- A SoundEntries KIT NAME, never a file path. This client documents
    -- PlaySound only -- there is no PlaySoundFile among its globals -- and it
    -- is silent for a kit name it does not know, with no error and no return
    -- value. So nothing in the addon can verify that this name makes a noise;
    -- "/uq rare sound <kit>" is how the player's ears settle it.
    rareAlertSound = "RaidWarning",

    -- Quest tracker window ---------------------------------------------------
    --
    -- The addon's own movable tracker, which lists every quest in the log
    -- rather than the five the client's watch list can hold. See
    -- docs/QUEST-TRACKER.md.
    trackerEnabled = true,
    trackerWidth = 130,

    -- Percentage opacity of the tracker window's near-black background.
    -- Kept as 0-100 because that is the value the settings slider displays;
    -- TrackerFrame converts it to the texture's 0-1 alpha at the view edge.
    trackerBackgroundOpacity = 55,

    -- A maximum window height in pixels, or 0 for no ceiling. The corner grip
    -- writes a real height on its first drag, /uq tracker height sets it
    -- directly, and /uq tracker reset returns it to 0. Rows below a shorter
    -- ceiling are not drawn; enlarging the window reveals them again.
    trackerHeight = 0,

    -- "all", "tracked" or "none". "tracked" shows objectives only under the
    -- quests in the client's own watch list (plus any quest ready to hand in),
    -- which turns the window into a compact index of the whole log.
    trackerShowObjectives = "all",

    trackerGroupByZone = true,
    trackerCollapsed = false,

    -- Restricts the window to the quests filed under the player's current zone
    -- in the quest log, so a full log reads as "what can I do here" instead of
    -- a career summary. On by default: the tracker is a fixed, unscrolled box
    -- and a 20-quest log overflows it long before the ceiling is reached.
    --
    -- The comparison is between two localized strings -- the quest log's own
    -- zone header and the client's zone name -- and everything that is NOT a
    -- confirmed other zone stays visible: a quest with no header, a header the
    -- bundled zone table does not know as an area (class and profession
    -- groupings), and every quest at all when the client will not name the
    -- current zone. See Quest/TrackerFrame.lua.
    trackerCurrentZoneOnly = true,

    -- The native five-quest panel is redundant while this window is up, and is
    -- restored the moment either this setting or trackerEnabled is turned off.
    trackerHideNativeWatch = true,

    -- Captured through Client.GetFrameAnchor, which undoes this client's
    -- inverted GetPoint Y. Always UIParent-relative: a relative frame is a
    -- live object and cannot be persisted.
    trackerPoint = "TOPRIGHT",
    trackerRelativePoint = "TOPRIGHT",
    trackerX = -20,
    trackerY = -240,

    -- Settings window ---------------------------------------------------------
    --
    -- Only ever used by UnrealQuest's OWN options window, which is only built
    -- when unrealUI is not installed -- when it is, the page is drawn inside
    -- unrealUI's settings panel and that window owns its own position. Same
    -- persistence rule as the tracker: an anchor point name and two numbers,
    -- always UIParent-relative, never a live frame.
    -- The settings button beside the minimap. Also unrealUI-absent only: when
    -- unrealUI is installed its own button is already in that spot and opens
    -- the window that now holds UnrealQuest's page, so a second one would be
    -- two buttons for one destination.
    minimapButton = true,

    settingsPoint = "CENTER",
    settingsRelativePoint = "CENTER",
    settingsX = 0,
    settingsY = 0,

    -- Main quest and the HUD waypoint marker ---------------------------------

    -- Which gesture on a quest log row or a tracker line makes that quest the
    -- main quest. "none" is a plain left click, which is the requested
    -- default; the trade-off is that browsing the quest log re-points the
    -- waypoint on every row read. "shift", "ctrl" or "alt" turn it into a
    -- held-modifier gesture and leave plain clicks alone.
    mainQuestClickModifier = "none",

    -- Whether selecting a main quest also adds it to UnrealQuest's tracked
    -- set. Off by default and deliberately so: with plain-click selection
    -- this would track every quest merely browsed in the log. Following a
    -- quest and tracking it are separate ideas.
    mainQuestAutoTrack = false,

    waypointEnabled = true,

    -- 20Hz. Fast enough that the marker slides rather than steps while the
    -- player turns; the job body allocates nothing per tick beyond its label.
    waypointInterval = 0.05,

    -- Horizontal field of view, in degrees, used to turn a bearing offset into
    -- a screen position. This is a setting rather than a measurement because
    -- the client publishes no camera FOV -- see the cameraProjection
    -- capability. Lower it if the marker consistently leads its target,
    -- raise it if it lags.
    waypointFov = 100,

    -- Where the marker sits vertically, as a fraction of screen height above
    -- centre. There is no vertical projection available (that needs camera
    -- pitch and target elevation, neither of which this client exposes), so
    -- the marker rides a fixed horizon band.
    waypointHeight = 0.18,
}

local function IsSafeString(value)
    if type(value) ~= "string" then
        return false
    end
    if string.find(value, "\\", 1, true) then
        return false
    end
    return true
end

local function IsSafeScalar(value)
    local kind = type(value)
    if kind == "number" or kind == "boolean" then
        return true
    end
    if kind == "string" then
        return IsSafeString(value)
    end
    return false
end

-- One level of nesting is allowed and its contents must be scalars. Keys of a
-- nested set are game data (quest titles), which is exactly the class of string
-- the backslash hazard applies to, so keys are validated as well as values.
local function SanitizeSection(section, limit)
    local clean = {}
    local count = 0
    for key, value in pairs(section) do
        if count >= limit then
            break
        end
        local keyOk = type(key) == "number" or IsSafeString(key)
        if keyOk and IsSafeScalar(value) then
            clean[key] = value
            count = count + 1
        end
    end
    return clean
end

local function Sanitize(store)
    local clean = {}
    for key, value in pairs(store) do
        if IsSafeString(key) then
            if IsSafeScalar(value) then
                clean[key] = value
            elseif type(value) == "table" then
                clean[key] = SanitizeSection(value, SectionLimit(key))
            end
        end
    end
    return clean
end

-- The three history sections used to live in the account store, because that
-- is the only store there was. Every character that logs in after this update
-- inherits that record ONCE and then keeps its own; from there the two never
-- meet again.
--
-- The account copy is deliberately NOT deleted. It was built by whichever
-- characters played, there is no way to know which of them have logged in
-- since the update, and deleting it would silently strip the record from every
-- character that has not. It is a legacy seed that goes unread once a
-- character is migrated, and costs one flag to ignore.
local function MigrateHistoryToCharacter(account, character)
    if character.historyMigrated then
        return
    end
    character.historyMigrated = true
    for name in pairs(CHARACTER_SECTIONS) do
        local legacy = account[name]
        if type(legacy) == "table" and type(character[name]) ~= "table" then
            local copy = {}
            local key, value
            for key, value in pairs(legacy) do
                copy[key] = value
            end
            character[name] = copy
        end
    end
end

function Config:OnInit()
    if type(UnrealQuestDB) ~= "table" then
        UnrealQuestDB = {}
    end
    if type(UnrealQuestCharDB) ~= "table" then
        UnrealQuestCharDB = {}
    end

    if UnrealQuestDB.schema and UnrealQuestDB.schema ~= SCHEMA then
        -- No migration path exists yet. Rather than reading a shape this build
        -- does not understand, start clean and say so.
        -- One of the few lines in this addon that can print before
        -- Core/Locale.lua has resolved the language, because it runs inside
        -- Config's own OnInit -- the phase the language is read FROM. It goes
        -- through the catalog anyway, and simply answers in English when it
        -- lands that early.
        UQ:Warn(UQ.L("CONFIG_SCHEMA_RESET", tostring(UnrealQuestDB.schema),
            tostring(SCHEMA)))
        UnrealQuestDB = {}
    end

    UnrealQuestDB = Sanitize(UnrealQuestDB)
    UnrealQuestDB.schema = SCHEMA
    UnrealQuestDB.version = UQ.version

    UnrealQuestCharDB = Sanitize(UnrealQuestCharDB)
    UnrealQuestCharDB.schema = SCHEMA
    MigrateHistoryToCharacter(UnrealQuestDB, UnrealQuestCharDB)

    for key, value in pairs(defaults) do
        if UnrealQuestDB[key] == nil then
            UnrealQuestDB[key] = value
        end
    end

    -- trackerWidth's default has moved four times across sessions (260 -> 156
    -- -> 130 -> 170 -> 130). The 170 was a deliberate +30% widen that was
    -- reverted once the corner resize grip landed: the grip is now the way to
    -- get a wider window, so the shipped default stays at the compact 130. The fill loop above
    -- only writes a MISSING key, so a value an earlier version already wrote
    -- as ITS default stays stuck at that number even after the default changes
    -- underneath it. This forces the correction exactly once per change, gated
    -- by its own version counter rather than SCHEMA (so it does not force a
    -- full settings reset), and only touches a value still equal to a KNOWN
    -- prior default -- never a width the player set deliberately through
    -- /uq tracker width or by dragging the grip.
    local TRACKER_WIDTH_DEFAULT_VERSION = 5
    if type(UnrealQuestDB.trackerWidthDefaultVersion) ~= "number"
        or UnrealQuestDB.trackerWidthDefaultVersion < TRACKER_WIDTH_DEFAULT_VERSION then
        local width = UnrealQuestDB.trackerWidth
        if width == 260 or width == 156 or width == 170 then
            UnrealQuestDB.trackerWidth = defaults.trackerWidth
        end
        UnrealQuestDB.trackerWidthDefaultVersion = TRACKER_WIDTH_DEFAULT_VERSION
    end

    self.store = UnrealQuestDB
    self.characterStore = UnrealQuestCharDB
    UQ.debug = UnrealQuestDB.debug and true or false
end

-- Which store a section belongs to. Everything else about a section -- the
-- entry limit, the sanitizer, the scalar-only rule -- is identical either way,
-- so this is the only place that has to know.
function Config:StoreFor(name)
    if CHARACTER_SECTIONS[name] then
        return self.characterStore
    end
    return self.store
end

-- Per-character scalars, for state that belongs to one character but is not a
-- keyed set: the pfQuest import's pending flag and the addon state it has to
-- put back. Same safety rules as Config:Set.
function Config:GetCharacter(key)
    if not self.characterStore then
        return nil
    end
    return self.characterStore[key]
end

function Config:SetCharacter(key, value)
    if not self.characterStore then
        return false
    end
    if value == nil then
        self.characterStore[key] = nil
        return true
    end
    if not IsSafeScalar(value) then
        UQ:Warn(UQ.L("CONFIG_UNSUPPORTED_VALUE", tostring(key)))
        return false
    end
    self.characterStore[key] = value
    return true
end

function Config:Get(key)
    if not self.store then
        return defaults[key]
    end
    local value = self.store[key]
    if value == nil then
        return defaults[key]
    end
    return value
end

function Config:Set(key, value)
    if not self.store then
        return false
    end
    if not IsSafeScalar(value) then
        UQ:Warn(UQ.L("CONFIG_UNSUPPORTED_VALUE", tostring(key)))
        return false
    end
    self.store[key] = value
    return true
end

-- Named set of scalars, e.g. remembered tracked quest titles. Which of the two
-- stores it comes from is decided by CHARACTER_SECTIONS, not by the caller.
function Config:GetSection(name)
    local store = self:StoreFor(name)
    if not store then
        return nil
    end
    if type(store[name]) ~= "table" then
        store[name] = {}
    end
    return store[name]
end

function Config:SetSectionEntry(name, key, value)
    local section = self:GetSection(name)
    if not section then
        return false
    end
    if value == nil then
        section[key] = nil
        return true
    end
    if not IsSafeString(key) and type(key) ~= "number" then
        return false
    end
    if not IsSafeScalar(value) then
        return false
    end
    local count = 0
    for _ in pairs(section) do
        count = count + 1
    end
    if section[key] == nil and count >= SectionLimit(name) then
        UQ:Warn(UQ.L("CONFIG_SECTION_FULL", tostring(name)))
        return false
    end
    section[key] = value
    return true
end

function Config:ClearSection(name)
    local store = self:StoreFor(name)
    if not store then
        return
    end
    store[name] = {}
end

Config.IsSafeScalar = IsSafeScalar
Config.defaults = defaults
