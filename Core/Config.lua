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
]]

local UQ = UnrealQuest
local Config = UQ:NewModule("Config")

local SCHEMA = 1
local MAX_SET_ENTRIES = 250

local defaults = {
    debug = false,
    pollInterval = 0.5,
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

    -- Main quest and the HUD waypoint marker ---------------------------------

    -- Which gesture on a quest log row or a tracker line makes that quest the
    -- main quest. "none" is a plain left click, which is the requested
    -- default; the trade-off is that browsing the quest log re-points the
    -- waypoint on every row read. "shift", "ctrl" or "alt" turn it into a
    -- held-modifier gesture and leave plain clicks alone.
    mainQuestClickModifier = "none",

    -- Whether selecting a main quest also adds it to the native watch list.
    -- Off by default and deliberately so: with plain-click selection this
    -- would fill the client's five-quest watch list simply by browsing the
    -- quest log. Following a quest and watching it are separate ideas.
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
local function SanitizeSection(section)
    local clean = {}
    local count = 0
    for key, value in pairs(section) do
        if count >= MAX_SET_ENTRIES then
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
                clean[key] = SanitizeSection(value)
            end
        end
    end
    return clean
end

function Config:OnInit()
    if type(UnrealQuestDB) ~= "table" then
        UnrealQuestDB = {}
    end

    if UnrealQuestDB.schema and UnrealQuestDB.schema ~= SCHEMA then
        -- No migration path exists yet. Rather than reading a shape this build
        -- does not understand, start clean and say so.
        UQ:Warn("saved settings were written by schema " .. tostring(UnrealQuestDB.schema)
            .. "; resetting to schema " .. SCHEMA)
        UnrealQuestDB = {}
    end

    UnrealQuestDB = Sanitize(UnrealQuestDB)
    UnrealQuestDB.schema = SCHEMA
    UnrealQuestDB.version = UQ.version

    for key, value in pairs(defaults) do
        if UnrealQuestDB[key] == nil then
            UnrealQuestDB[key] = value
        end
    end

    self.store = UnrealQuestDB
    UQ.debug = UnrealQuestDB.debug and true or false
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
        UQ:Warn("refused to persist an unsupported value for " .. tostring(key))
        return false
    end
    self.store[key] = value
    return true
end

-- Named set of scalars, e.g. remembered tracked quest titles.
function Config:GetSection(name)
    if not self.store then
        return nil
    end
    if type(self.store[name]) ~= "table" then
        self.store[name] = {}
    end
    return self.store[name]
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
    if section[key] == nil and count >= MAX_SET_ENTRIES then
        UQ:Warn("section " .. tostring(name) .. " is full; entry not stored")
        return false
    end
    section[key] = value
    return true
end

function Config:ClearSection(name)
    if not self.store then
        return
    end
    self.store[name] = {}
end

Config.IsSafeScalar = IsSafeScalar
Config.defaults = defaults
