--[[
UnrealQuest / Map/MinimapPins.lua

The same quest scene as the world map, drawn around the player on the minimap.

What it draws, and what it deliberately does not:

  * one quest-coloured DOT per quest-creature spawn from the bundled database. These are the
    raw positions that feed the world map's blue areas, but the minimap does
    not reconstruct, cluster, or otherwise approximate those areas;
  * the giver "!" and the turn-in "?", unchanged from the world map, because at
    minimap scale they are already single points;
  * creature spawns outside the current minimap view are absent, matching the
    raw-position presentation instead of piling distant mobs onto the edge;
  * giver and turn-in points beyond the minimap remain CLAMPED to the boundary
    and drawn at reduced alpha by default, so "that way, further than this"
    stays visible -- `minimapPinsClampEdge = false` hides them instead, like
    an out-of-view objective dot, for a less crowded minimap.

Hovering a pin fades every other pin that shares no quest with it to a quarter
of its own alpha -- the world map's own hover focus, on the surface where the
pins sit closest together. Nothing is hidden and no colour moves, and the fade reaches
the service/rare pins and the quest-vendor pins drawn on the same minimap. See
SetFocusPin.

Clicking a pin does what clicking the same pin on the world map does, because
it is the same code: an objective dot or a turn-in "?" follows its quest
through WorldMapPins:FollowQuest, and a giver "!" is handed to
WorldMapPins:OnGiverClick so its shift/ctrl "mark done" picker is identical on
both surfaces. This layer only decides WHICH quest was clicked -- see
OnPinClick. Whether a click on a child of Minimap reaches an addon at all is
unmeasured on this client, hence capability minimapPinInteraction and the
pinClicks counter in `/uq minimap`; the pins were already mouse-enabled for
their tooltips, so nothing new is taken away from the minimap underneath them.

Content is not decided here. Which giver still has a quest worth taking and
where a quest is handed in are policy questions the world-map layer already
answers, so this module calls WorldMapPins:CollectAvailableGivers and
:CollectTurnIns rather than reimplementing them -- the two layers may disagree
about pixels, never about what is on them.

The evidence this rests on was measured by UnrealRuntimeProbe 1.38.0, group
`minimappins`, and confirmed in game on 2026-08-23 (knowledge records
minimap.addon_children_render_unclipped and
minimap.zoom_span_zoom0_only_no_indoor_test):

  * children of Minimap render with the world-map pin contract unchanged;
  * the minimap mask does not clip them -- hence CLAMP_MARGIN below, and hence
    the fact that failing to clamp would scatter pins across the rest of the UI;
  * the Vanilla outdoor span of 466.6 yards across the minimap width at zoom 0
    is correct in Elwynn Forest; a marker anchored to a world coordinate stayed
    glued while the player walked. Other areas may still need their own
    calibration on this client.

Two limits are structural rather than unfinished, and both are visible in
`/uq minimap`:

  * ZOOM STEPS 1-5 ARE UNVERIFIED. Only zoom 0 was measured. The other steps
    use the Vanilla constants, which is an assumption this addon normally
    refuses to make -- it is made here, alone, because the alternative is a
    layer that vanishes whenever the player touches the zoom buttons, and
    because zoom 0's value being exactly right is evidence that the table is
    the right table. `spanEvidence` in the diagnostics says which step the
    current draw is using and whether it is measured.
  * INDOORS CANNOT BE DETECTED. IsIndoors and IsOutdoors are both absent from
    this client, and the indoor span is roughly 64% of the outdoor one, so pins
    inside a building or cave sit further from the player than they should.
    There is no route to fix this, only to state it.

Rotation is refused outright rather than approximated: with rotateMinimap set
this client would need a player facing to place anything, and it exposes none
by any route (docs/HUD-WAYPOINT.md). The layer hides itself and says so.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local MinimapPins = UQ:NewModule("MinimapPins")

-- Fast enough that pins track a running player smoothly, and cheap because a
-- tick only re-points existing frames -- the target list itself is rebuilt on
-- demand, not on the clock.
local REFRESH_INTERVAL = 0.1
-- The safety net for state no listener reports: a quest item entering or
-- leaving the bags changes which item-use objectives exist, and the quest-log
-- listener never fires for it. The poll is the mechanism, per the addon's
-- event rule -- but it polls the bag token and only then dirties the layer,
-- because the scene is otherwise static and rebuilding it on the clock
-- re-derived, every five seconds forever, a list that could not have changed.
local REBUILD_INTERVAL = 5

local MAX_GIVER_PINS = 16
local MAX_TURNIN_PINS = 16

-- A quest-creature spawn is a dot, not an icon. At 100%, 10.8px is 10% smaller
-- than the former 12px default; the player-facing percentage scales from there.
local DEFAULT_DOT_SIZE = 10.8
local MIN_DOT_SCALE = 50
local MAX_DOT_SCALE = 150
local DEFAULT_DOT_SCALE = 100
-- Tracker hover keeps the quest's own colour and enlarges every visible dot
-- that belongs to it. The multiplier is applied after the player's dot-size
-- setting, so the relationship remains equally obvious at every configured
-- scale rather than becoming a fixed-size second preference.
local HOVER_DOT_MULTIPLIER = 1.65
-- The followed quest's dots wear the world map's gold rim here too, built the
-- same way: the same companion texture -- the dot artwork's silhouette in
-- white pixels, so the tint reaches it -- and the same 4px of extra diameter,
-- which is a 2px stroke at either surface's default dot size.
--
-- The gold itself is the one deliberate difference. The world map's rim sits
-- on a large, mostly static tile at a comfortable size, where full-saturation
-- gold (1, 0.86, 0.05) reads as a clean stroke; the minimap draws the same
-- stroke two pixels wide over moving terrain and a crowd of other dots, and
-- at that size the saturated gold glares rather than frames. So the minimap
-- rim keeps the same hue and drops its contrast: darkened, and desaturated by
-- lifting the blue, which pulls it toward the surrounding art instead of
-- punching a hole in it. Same mark, same colour family -- one followed quest
-- still reads as one thing on both maps -- only quieter where it is smaller.
local GOLD_BORDER_RED = 0.85
local GOLD_BORDER_GREEN = 0.72
local GOLD_BORDER_BLUE = 0.28
local DOT_BORDER_PADDING = 4
-- One level BELOW the dot it surrounds. Every minimap pin is created at the
-- same measured level 120, and two siblings there leave which one draws on top
-- to creation order rather than to intent -- the rim would cover the coloured
-- centre it exists to frame. The world map settles the same tie by raising the
-- dot; here only the new pool moves, so nothing already measured changes
-- level, and 119 is still far above Minimap's own children at 3-4.
local DOT_BORDER_LEVEL_BOOST = -1
-- The bundled available-quest "!" is 19x32. Keep the existing 12px minimap
-- height while preserving that source ratio.
local GIVER_ICON_HEIGHT = 12
local GIVER_ICON_WIDTH = GIVER_ICON_HEIGHT * 19 / 32
local LOW_LEVEL_GIVER_ICON_WIDTH = GIVER_ICON_HEIGHT * 27 / 64
-- media/ActiveQuestIcon.tga is 19x32, so the "?" keeps its own aspect ratio
-- rather than being squashed into a square by SetAllPoints -- the same
-- reasoning as the world map's TURNIN_ICON_WIDTH.
local TURNIN_ICON_HEIGHT = 14
local TURNIN_ICON_WIDTH = TURNIN_ICON_HEIGHT * 19 / 32
-- How far inside the minimap edge a clamped pin sits, so a clamped icon is
-- fully on the map instead of half-way over pfUI's border.
local CLAMP_MARGIN = 2
-- A clamped giver or turn-in pin means "further than this", and the fade is
-- what says so. Exact creature positions are never clamped.
local EDGE_ALPHA = 0.55
local INSIDE_ALPHA = 1
-- What a pin unrelated to the hovered quest keeps of its own opacity while
-- that hover is held. It MULTIPLIES the alpha above rather than replacing it:
-- "further than this" and "not the quest you are pointing at" are two
-- different things a pin can be, and a clamped unrelated pin is both -- so a
-- clamped unrelated pin lands near 0.14 and is the faintest thing this layer
-- draws.
local FOCUS_DIM_FACTOR = 0.25

local OBJECTIVE_RED, OBJECTIVE_GREEN, OBJECTIVE_BLUE = UQ.GetQuestColor(nil)

-- Yards across the full width of the minimap, indexed by Minimap:GetZoom().
-- Zoom 0 is MEASURED on this client (probe 1.38.0, observation `glued`); the
-- rest are the Vanilla constants and are flagged as assumptions wherever the
-- addon reports its state. The indoor row is deliberately absent: IsIndoors
-- does not exist here, so a row that can never be selected would only look
-- like support for a case that has none.
local SPAN_OUTDOOR = {
    [0] = 466.6,
    [1] = 400,
    [2] = 333.3,
    [3] = 266.6,
    [4] = 200,
    [5] = 133.3,
}
-- The indoor row of the same Vanilla table. Its zoom-0 span is 64% of the
-- outdoor 466.6 that probe 1.38.0 measured in game, which is the ratio the
-- minimap actually changes by when the player steps inside, and the row the
-- installed pfQuest uses for the same purpose. Selected only when
-- Client.GetMinimapIndoorState says so; an unknown answer keeps the outdoor
-- row, which is what this layer used before it could tell.
local SPAN_INDOOR = {
    [0] = 300,
    [1] = 240,
    [2] = 180,
    [3] = 120,
    [4] = 80,
    [5] = 50,
}
local SPAN_MEASURED_ZOOM = 0
-- How long the client may keep returning the same player map position, while
-- it also says the player is moving, before this layer stops believing it.
-- Long enough that a quantized position (GetPlayerMapPosition is measured
-- accurate to one yard) or a single stalled frame cannot trip it, short enough
-- that the pins do not spend seconds describing nothing.
local PLAYER_POSITION_STALE_SECONDS = 1.5

-- Measured spans, keyed by area and zoom step, dialled in from inside the game
-- with "/uq minimap span <yards>" and kept in SavedVariables.
--
-- This exists because the constants above cannot be verified from Lua. The
-- minimap draws no reference this addon can read back, so nothing in here can
-- observe whether a pin is glued to the ground -- only a player walking past
-- it can. A span that is too large makes every offset undershoot, and the pin
-- creeps along in the direction of travel; too small and it slides the other
-- way. Dialling until it stops moving IS the measurement, and the value it
-- lands on is evidence of the same class as the zoom-0 walk that established
-- 466.6.
--
-- Overrides are per area and zoom step, and stored separately for indoors.
-- Zoom 0 was measured in Elwynn, but Stormwind was reported drifting at the
-- same step on 2026-09-02; treating one calibration as global would trade one
-- broken zone for another. The old area-less keys remain readable so an
-- existing player's calibration survives this change, but every new write is
-- scoped to the current area.
local SPAN_SECTION = "minimapSpans"

local function SpanEnvironmentKey(zoom, indoor)
    local prefix = "out"
    if indoor == "indoor" then
        prefix = "in"
    end
    return prefix .. tostring(zoom)
end

local function SpanOverrideKey(areaId, zoom, indoor)
    if type(areaId) ~= "number" or type(zoom) ~= "number" then
        return nil
    end
    return tostring(areaId) .. ":" .. SpanEnvironmentKey(zoom, indoor)
end

local function SpanOverride(areaId, zoom, indoor)
    local config = UQ:GetModule("Config")
    if not config or type(zoom) ~= "number" then
        return nil
    end
    local section = config:GetSection(SPAN_SECTION)
    local value = nil
    local key = SpanOverrideKey(areaId, zoom, indoor)
    if section and key then
        value = section[key]
    end
    -- Compatibility with calibrations saved before overrides became
    -- area-scoped. A reset clears this legacy fallback as well.
    if (type(value) ~= "number" or value <= 0) and section then
        value = section[SpanEnvironmentKey(zoom, indoor)]
    end
    if type(value) ~= "number" or value <= 0 then
        return nil
    end
    return value
end

MinimapPins.objectivePool = {}
-- The gold rims, pooled separately from the dots they sit behind: only the
-- followed quest has any, so one shared pool would need a per-pin "is this one
-- wearing a rim" flag and a hide pass of its own regardless.
MinimapPins.objectiveBorderPool = {}
MinimapPins.giverPool = {}
MinimapPins.turnInPool = {}
MinimapPins.objectiveVisible = 0
MinimapPins.objectiveBorderVisible = 0
MinimapPins.giverVisible = 0
MinimapPins.turnInVisible = 0
MinimapPins.targets = {}
MinimapPins.dirty = true
MinimapPins.lastAreaId = nil
MinimapPins.lastBagToken = nil
MinimapPins.relevantBagItemIds = {}
MinimapPins.lastPlayerX = nil
MinimapPins.lastPlayerY = nil
MinimapPins.playerStaleSince = nil
MinimapPins.rebuildCount = 0
MinimapPins.clampedCount = 0
MinimapPins.pinFailures = 0
MinimapPins.lastState = nil
MinimapPins.lastDiagnosticKey = nil
MinimapPins.canvasDeclared = false
MinimapPins.hoverQuestKey = nil
-- The pin the cursor is on, and what it makes "related". Hovering a quest pin
-- fades every pin belonging to no quest that pin carries, so a crowded
-- minimap answers "which of these is the one I am pointing at" without
-- hiding anything or repainting a colour. Both sets are reused tables rather
-- than allocated per hover, for the reason Core/Driver.lua gives about
-- allocation churn on this client.
MinimapPins.focusPin = nil
MinimapPins.focusQuestKeys = {}
MinimapPins.focusQuestIds = {}
MinimapPins.focusActive = false

local function Database()
    return UQ:GetModule("Database")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function WorldMapPins()
    return UQ:GetModule("WorldMapPins")
end

local function BagItems()
    return UQ:GetModule("BagItems")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

-- Pools ---------------------------------------------------------------------

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
        if pool[index] == MinimapPins.hoverPin then
            Client.HideGameTooltip(pool[index])
            MinimapPins.hoverPin = nil
        end
        -- A pin leaving the scene takes its hover focus with it. Without this
        -- the fade would outlive the pin that asked for it, and nothing would
        -- ever arrive to clear it: a hidden frame receives no OnLeave.
        if pool[index] == MinimapPins.focusPin then
            MinimapPins:ResolveFocusPin(nil)
        end
        Client.HideObject(pool[index])
        index = index + 1
    end
    return first - 1
end

-- Refresh has nine early returns and runs several times a second, so without
-- this guard a disabled layer -- or a rotating minimap, or an unresolved zone --
-- walks every pooled pin again on every one of them to hide what is already
-- hidden. Cleared by Project below, the only path that shows any of them. The
-- world map layer carries the same guard for the same measured reason.
function MinimapPins:HideAll()
    if self.poolsHidden then
        return
    end
    self.poolsHidden = true
    self.objectiveVisible = HidePoolFrom(self.objectivePool, 1)
    self.objectiveBorderVisible = HidePoolFrom(self.objectiveBorderPool, 1)
    self.giverVisible = HidePoolFrom(self.giverPool, 1)
    self.turnInVisible = HidePoolFrom(self.turnInPool, 1)
end

local function AppendTooltipBlock(lines, block)
    if not block then
        return
    end
    if table.getn(lines) > 0 then
        table.insert(lines, { separator = true })
    end
    local index = 1
    local total = table.getn(block)
    while index <= total do
        table.insert(lines, block[index])
        index = index + 1
    end
end

function MinimapPins:TooltipLines(pin)
    local worldMap = WorldMapPins()
    if not worldMap or not pin then
        return nil
    end
    if pin.unrealQuestObjectiveQuests then
        local lines = {}
        local index = 1
        local total = table.getn(pin.unrealQuestObjectiveQuests)
        while index <= total do
            AppendTooltipBlock(lines,
                worldMap:BuildQuestTooltipLines(pin.unrealQuestObjectiveQuests[index]))
            index = index + 1
        end
        return lines
    end
    if pin.unrealQuestGiver then
        -- The hint is no longer suppressed here: this "!" answers a
        -- shift-click exactly as the world map's does, so withholding the
        -- line would hide an action the pin really has.
        return worldMap:BuildGiverTooltipLines(pin.unrealQuestGiver,
            pin.unrealQuestAvailableQuestIds or {})
    end
    if pin.unrealQuestTurnIn then
        return worldMap:BuildTurnInTooltipLines(pin.unrealQuestTurnIn)
    end
    return nil
end

-- The identity a quest is compared by on this surface. The tracker hover, the
-- pin hover focus and the world map's own history all key on titleKey, and
-- the live title is the fallback for a row that has none yet.
local function QuestKey(quest)
    if type(quest) ~= "table" then
        return nil
    end
    if type(quest.titleKey) == "string" and quest.titleKey ~= "" then
        return quest.titleKey
    end
    if type(quest.title) == "string" and quest.title ~= "" then
        return quest.title
    end
    return nil
end

-- The hover focus ------------------------------------------------------------
--
-- A pin is "related" when it shares a quest with the hovered one. Two forms of
-- quest identity are collected because the three pin kinds do not carry the
-- same thing: an objective dot and a "?" carry live quest-log rows, while a
-- "!" carries only the database IDs of quests the player has not taken and
-- which therefore have no log row to name. Matching on either is what lets one
-- hover reach every marker of the same quest.
local function ClearSet(set)
    for key in pairs(set) do
        set[key] = nil
    end
end

function MinimapPins:AddFocusQuest(quest)
    local key = QuestKey(quest)
    if key then
        self.focusQuestKeys[key] = true
        self.focusActive = true
    end
    local worldMap = WorldMapPins()
    if not worldMap or not worldMap.GetQuestMapIds or not quest then
        return
    end
    local ids = worldMap:GetQuestMapIds(quest)
    local index = 1
    local total = table.getn(ids)
    while index <= total do
        self.focusQuestIds[ids[index]] = true
        self.focusActive = true
        index = index + 1
    end
end

function MinimapPins:AddFocusQuests(quests)
    if type(quests) ~= "table" then
        return
    end
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        self:AddFocusQuest(quests[index])
        index = index + 1
    end
end

-- Reads whatever the hovered pin happens to carry. Passing nil drops the
-- focus. Redraws nothing itself: the pool-hiding path calls this while it is
-- already inside a draw, and a Refresh from there would re-enter it.
function MinimapPins:ResolveFocusPin(pin)
    self.focusPin = pin
    ClearSet(self.focusQuestKeys)
    ClearSet(self.focusQuestIds)
    self.focusActive = false
    if pin then
        self:AddFocusQuests(pin.unrealQuestObjectiveQuests)
        local turnIn = pin.unrealQuestTurnIn
        if turnIn then
            self:AddFocusQuests(turnIn.quests)
        end
        local ids = pin.unrealQuestAvailableQuestIds
        if type(ids) == "table" then
            local index = 1
            local total = table.getn(ids)
            while index <= total do
                self.focusQuestIds[ids[index]] = true
                self.focusActive = true
                index = index + 1
            end
        end
    end
    -- The other two layers drawing on the same minimap. Neither is asked to
    -- decide anything the quest layer has not already decided: the service and
    -- rare pins carry no quest at all, the vendor pins ask FocusIncludesQuest
    -- below.
    local npcPins = UQ:GetModule("NpcPins")
    if npcPins and npcPins.SetMinimapFocusDim then
        npcPins:SetMinimapFocusDim(self.focusActive)
    end
    local vendorPins = UQ:GetModule("QuestVendorPins")
    if vendorPins and vendorPins.SetMinimapFocusDim then
        vendorPins:SetMinimapFocusDim(self.focusActive)
    end
end

function MinimapPins:SetFocusPin(pin)
    if self.focusPin == pin then
        return
    end
    self:ResolveFocusPin(pin)
    -- Presentation only: no target is rebuilt, the existing scene is re-drawn
    -- at its new opacities.
    self:Refresh()
end

-- Public because the vendor layer draws quest pins on this minimap too and
-- must reach the same answer rather than keep a second copy of it.
function MinimapPins:FocusIncludesQuest(quest)
    if not self.focusActive or type(quest) ~= "table" then
        return false
    end
    local key = QuestKey(quest)
    if key and self.focusQuestKeys[key] then
        return true
    end
    local worldMap = WorldMapPins()
    if not worldMap or not worldMap.GetQuestMapIds then
        return false
    end
    local ids = worldMap:GetQuestMapIds(quest)
    local index = 1
    local total = table.getn(ids)
    while index <= total do
        if self.focusQuestIds[ids[index]] then
            return true
        end
        index = index + 1
    end
    return false
end

-- One target's answer, from whichever of the three shapes it is.
function MinimapPins:IsTargetInFocus(target)
    if not self.focusActive or type(target) ~= "table" then
        return false
    end
    if target.quests then
        local index = 1
        local total = table.getn(target.quests)
        while index <= total do
            if self:FocusIncludesQuest(target.quests[index]) then
                return true
            end
            index = index + 1
        end
    end
    if target.point and type(target.point.quests) == "table" then
        local index = 1
        local total = table.getn(target.point.quests)
        while index <= total do
            if self:FocusIncludesQuest(target.point.quests[index]) then
                return true
            end
            index = index + 1
        end
    end
    if type(target.questIds) == "table" then
        local index = 1
        local total = table.getn(target.questIds)
        while index <= total do
            if self.focusQuestIds[target.questIds[index]] then
                return true
            end
            index = index + 1
        end
    end
    return false
end

function MinimapPins:OnPinEnter(pin)
    self.hoverPin = pin
    self:SetFocusPin(pin)
    local lines = self:TooltipLines(pin)
    if lines and table.getn(lines) > 0 then
        Client.ShowGameTooltip(pin, lines, "ANCHOR_LEFT")
    end
end

function MinimapPins:OnPinLeave(pin)
    if self.hoverPin == pin then
        self.hoverPin = nil
    end
    -- The same guard the world map's leave paths carry: this client can
    -- deliver the next pin's OnEnter before this OnLeave, and an unguarded
    -- clear would drop a focus that already belongs to it.
    if self.focusPin == pin then
        self:SetFocusPin(nil)
    end
    Client.HideGameTooltip(pin)
end

-- Which quest a clicked objective dot means. One database position can carry
-- several quests -- the dot is one creature, and two quests may both want it
-- -- so the choice has to be made rather than assumed. It mirrors the answer
-- the pin's own presentation already gives: the quest the player is pointing
-- at (a tracker hover keeps that dot in its quest's colour) wins, otherwise
-- the first quest listed, which is the one whose tooltip block is on top.
local function ObjectiveClickQuest(quests, hoverKey)
    if type(quests) ~= "table" then
        return nil
    end
    local first = nil
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if quest and quest.titleKey then
            if hoverKey and QuestKey(quest) == hoverKey then
                return quest
            end
            if not first then
                first = quest
            end
        end
        index = index + 1
    end
    return first
end

-- The turn-in's own answer, the same one the world map's OnTurnInClick uses:
-- a "?" can stand for several quests and the completed one is what the player
-- walked there for, so it is preferred over mere list order.
local function TurnInClickQuest(point)
    local quests = point and point.quests
    if type(quests) ~= "table" then
        return nil
    end
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        if quests[index] and quests[index].isComplete == 1 then
            return quests[index]
        end
        index = index + 1
    end
    return quests[1]
end

-- Counts clicks that actually reached a minimap pin, split by the kind of pin
-- that took them. minimapPinInteraction is unverified for the same reason
-- worldMapPinInteraction once was -- a click on a child of Minimap has never
-- been observed on this client -- and hovers are no substitute for the
-- measurement: the pins' tooltips prove the mouse arrives, not that a click
-- does. Read against the hover the player reports making:
--   zero forever  -> Minimap keeps the click; its children only get hovers
--   non-zero      -> interaction works; look at MainQuest instead
local function RecordPinClick(kind)
    MinimapPins.clickCount = (MinimapPins.clickCount or 0) + 1
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("minimapDiagnostics", "pinClicks", MinimapPins.clickCount)
    config:SetSectionEntry("minimapDiagnostics", "lastPinClickKind", kind)
    config:SetSectionEntry("minimapDiagnostics", "lastPinClickAt", Client.Now() or 0)
end

-- A click on the minimap is a click on the map: the same pin means the same
-- thing on both surfaces, so the decision of what a click DOES stays in
-- WorldMapPins and this layer only says which quest was clicked.
--
--   * an objective dot and a turn-in "?" follow their quest, exactly as the
--     world map's area tiles and "?" pins do;
--   * a giver "!" is handed to the world map's own click handler, so its
--     shift/ctrl "mark this quest done" picker behaves identically here.
--     A plain left click on a "!" follows nothing on either surface -- the
--     quests it offers are not in the log yet, so there is nothing to follow.
function MinimapPins:OnPinClick(pin)
    if not pin then
        return false
    end
    local worldMap = WorldMapPins()
    if not worldMap then
        return false
    end
    if pin.unrealQuestObjectiveQuests then
        RecordPinClick("objective")
        return worldMap:FollowQuest(
            ObjectiveClickQuest(pin.unrealQuestObjectiveQuests, self.hoverQuestKey),
            "minimapObjective")
    end
    if pin.unrealQuestTurnIn then
        RecordPinClick("turnIn")
        return worldMap:FollowQuest(TurnInClickQuest(pin.unrealQuestTurnIn),
            "minimapTurnIn")
    end
    if pin.unrealQuestGiver then
        RecordPinClick("giver")
        return worldMap:OnGiverClick(pin)
    end
    return false
end

function MinimapPins:SetPinHandlers(pin)
    Client.SetMinimapPinHandlers(pin,
        function() MinimapPins:OnPinEnter(pin) end,
        function() MinimapPins:OnPinLeave(pin) end,
        function() MinimapPins:OnPinClick(pin) end)
end

function MinimapPins:GetObjectiveDotSize(highlighted)
    local config = UQ:GetModule("Config")
    local scale = config and config:Get("minimapObjectiveDotScale")
    if type(scale) ~= "number" then
        scale = DEFAULT_DOT_SCALE
    elseif scale < MIN_DOT_SCALE then
        scale = MIN_DOT_SCALE
    elseif scale > MAX_DOT_SCALE then
        scale = MAX_DOT_SCALE
    end
    local size = DEFAULT_DOT_SIZE * scale / 100
    if highlighted then
        size = size * HOVER_DOT_MULTIPLIER
    end
    return size
end

function MinimapPins:ApplyObjectiveDotSize()
    local size = self:GetObjectiveDotSize()
    local index = 1
    while index <= table.getn(self.objectivePool) do
        Client.SetMinimapPinSize(self.objectivePool[index], size, size)
        index = index + 1
    end
    -- The rims follow the same setting from the same resting size, so a dot
    -- and the rim behind it are never a tick out of step while the slider
    -- moves.
    local borderSize = size + DOT_BORDER_PADDING
    index = 1
    while index <= table.getn(self.objectiveBorderPool) do
        Client.SetMinimapPinSize(self.objectiveBorderPool[index], borderSize, borderSize)
        index = index + 1
    end
end

function MinimapPins:IsTargetHighlighted(target)
    local hoverKey = self.hoverQuestKey
    if type(hoverKey) ~= "string" or type(target) ~= "table" then
        return false
    end
    local quests = target.quests
    local index = 1
    local total = type(quests) == "table" and table.getn(quests) or 0
    while index <= total do
        if QuestKey(quests[index]) == hoverKey then
            return true
        end
        index = index + 1
    end
    return QuestKey(target.quest) == hoverKey
end

-- Whether any quest on this target is the followed one. A dot can carry
-- several quests and the rim says "the quest you are following is here", so
-- one match is enough -- the same rule the world map applies when it decides
-- which of its dots to rim.
function MinimapPins:IsTargetFollowed(target, mainQuest)
    if not mainQuest or type(target) ~= "table" then
        return false
    end
    local quests = target.quests
    local index = 1
    local total = type(quests) == "table" and table.getn(quests) or 0
    while index <= total do
        local quest = quests[index]
        if quest and mainQuest:IsMain(quest.titleKey) then
            return true
        end
        index = index + 1
    end
    return type(target.quest) == "table" and mainQuest:IsMain(target.quest.titleKey)
end

-- Called by the tracker row's existing hover handlers. This state is
-- deliberately transient: it is never saved and changes no map content, only
-- the presentation of objective dots already selected for the minimap scene.
function MinimapPins:SetHoveredQuest(quest)
    local key = QuestKey(quest)
    if self.hoverQuestKey == key then
        return
    end
    self.hoverQuestKey = key
    self:Refresh()
end

function MinimapPins:GetObjectivePin(index)
    local pin = self.objectivePool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin("Objective" .. tostring(index), self:GetObjectiveDotSize(),
        OBJECTIVE_RED, OBJECTIVE_GREEN, OBJECTIVE_BLUE)
    if pin then
        self.objectivePool[index] = pin
        Client.SetMinimapPinTexture(pin, Client.MINIMAP_OBJECTIVE_TEXTURE)
        self:SetPinHandlers(pin)
    end
    return pin
end

-- The rim behind one objective dot. It takes no handlers, so it keeps the
-- mouse-disabled state CreateMinimapPin starts every pin in: the dot on top of
-- it owns the hover and the click, and a rim that answered either would put
-- the tooltip on the mark instead of on the objective.
function MinimapPins:GetObjectiveBorder(index)
    local border = self.objectiveBorderPool[index]
    if border then
        return border
    end
    border = Client.CreateMinimapPin("ObjectiveBorder" .. tostring(index),
        self:GetObjectiveDotSize() + DOT_BORDER_PADDING,
        GOLD_BORDER_RED, GOLD_BORDER_GREEN, GOLD_BORDER_BLUE)
    if border then
        self.objectiveBorderPool[index] = border
        Client.SetMinimapPinTexture(border, Client.FOLLOWED_QUEST_DOT_BORDER_TEXTURE)
        Client.SetMinimapPinColor(border,
            GOLD_BORDER_RED, GOLD_BORDER_GREEN, GOLD_BORDER_BLUE)
        Client.SetMinimapPinMouseEnabled(border, false)
        Client.SetMinimapPinLevelBoost(border, DOT_BORDER_LEVEL_BOOST)
    end
    return border
end

function MinimapPins:GetGiverPin(index)
    local pin = self.giverPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin("Giver" .. tostring(index), GIVER_ICON_HEIGHT, 1, 1, 1)
    if pin then
        self.giverPool[index] = pin
        Client.SetMinimapPinTexture(pin, Client.AVAILABLE_QUEST_TEXTURE)
        Client.SetMinimapPinSize(pin, GIVER_ICON_WIDTH, GIVER_ICON_HEIGHT)
        self:SetPinHandlers(pin)
    end
    return pin
end

function MinimapPins:GetTurnInPin(index)
    local pin = self.turnInPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin("TurnIn" .. tostring(index), TURNIN_ICON_HEIGHT, 1, 1, 1)
    if pin then
        self.turnInPool[index] = pin
        Client.SetMinimapPinTexture(pin, Client.ACTIVE_QUEST_TEXTURE)
        Client.SetMinimapPinSize(pin, TURNIN_ICON_WIDTH, TURNIN_ICON_HEIGHT)
        self:SetPinHandlers(pin)
    end
    return pin
end

-- Diagnostics ---------------------------------------------------------------

function MinimapPins:Record(state, extra)
    self.lastState = state
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    local key = state .. ":" .. tostring(self.objectiveVisible) .. ":"
        .. tostring(self.giverVisible) .. ":" .. tostring(self.turnInVisible)
        -- Indoor state and zoom are part of the identity of a sample, not
        -- decoration on it: without them a record captured standing outside
        -- survives untouched while the player walks around inside, and reads
        -- as evidence about indoors when it is nothing of the kind.
        .. ":" .. tostring(self.lastIndoorState) .. ":" .. tostring(self.lastZoom)
    if key == self.lastDiagnosticKey then
        return
    end
    self.lastDiagnosticKey = key
    config:SetSectionEntry("minimapDiagnostics", "state", state)
    config:SetSectionEntry("minimapDiagnostics", "objectives", self.objectiveVisible)
    config:SetSectionEntry("minimapDiagnostics", "dotBorders", self.objectiveBorderVisible)
    config:SetSectionEntry("minimapDiagnostics", "givers", self.giverVisible)
    config:SetSectionEntry("minimapDiagnostics", "turnIns", self.turnInVisible)
    config:SetSectionEntry("minimapDiagnostics", "clamped", self.clampedCount)
    config:SetSectionEntry("minimapDiagnostics", "pinFailures", self.pinFailures)
    config:SetSectionEntry("minimapDiagnostics", "rebuilds", self.rebuildCount)
    if extra then
        local key2, value
        for key2, value in pairs(extra) do
            config:SetSectionEntry("minimapDiagnostics", key2, value)
        end
    end
end

-- Scale ---------------------------------------------------------------------

-- Yards across the minimap's width at the current zoom, plus how well that
-- number is established. A zoom step the table does not cover returns nil
-- rather than a nearby guess: an unknown step means an unknown scale, and a
-- pin at an unknown scale is worse than no pin.
local function SpanForZoom(zoom, areaId)
    local indoor = Client.GetMinimapIndoorState()
    local override = SpanOverride(areaId, zoom, indoor)
    if override then
        return override, "playerCalibrated"
    end
    local steps = SPAN_OUTDOOR
    local indoorSuffix = ""
    if indoor == "indoor" then
        steps = SPAN_INDOOR
        indoorSuffix = "Indoor"
    end
    if type(zoom) ~= "number" then
        -- No zoom reading at all. The measured step is the only one that can
        -- be defended, and it is also the client's default.
        return steps[SPAN_MEASURED_ZOOM], "assumedDefaultZoom" .. indoorSuffix
    end
    local span = steps[zoom]
    if not span then
        return nil, "unknownZoom"
    end
    if zoom == SPAN_MEASURED_ZOOM and indoorSuffix == "" then
        return span, "measured"
    end
    return span, "vanillaConstant" .. indoorSuffix
end

-- Shared with Map/NpcPins.lua. Both minimap layers must use the same measured
-- zoom span rather than maintaining two tables that can drift apart.
function MinimapPins:GetSpanForZoom(zoom, areaId)
    return SpanForZoom(zoom, areaId)
end

-- Records a span the player has dialled in for the current area, zoom step and
-- environment. Passing nil clears it and returns that area to the constant.
-- Returns the key it wrote, the value, and the span now in use, so the caller
-- can report exactly what changed.
function MinimapPins:SetSpanOverride(yards)
    local config = UQ:GetModule("Config")
    if not config then
        return nil
    end
    local width, height, zoom = Client.GetMinimapGeometry()
    if type(zoom) ~= "number" then
        return nil
    end
    local mapContext = MapContext()
    local areaId = mapContext and mapContext:GetCurrentZoneView()
    if type(areaId) ~= "number" then
        return nil
    end
    local indoor = Client.GetMinimapIndoorState()
    local key = SpanOverrideKey(areaId, zoom, indoor)
    if yards and yards > 0 then
        config:SetSectionEntry(SPAN_SECTION, key, yards)
    else
        config:SetSectionEntry(SPAN_SECTION, key, nil)
        config:SetSectionEntry(SPAN_SECTION, SpanEnvironmentKey(zoom, indoor), nil)
    end
    self.dirty = true
    self:Refresh()
    local span, evidence = SpanForZoom(zoom, areaId)
    return key, zoom, indoor, span, evidence
end

-- Targets -------------------------------------------------------------------

-- The scene, in zone yards, rebuilt only when something that can change it
-- has changed. Database percentages are converted here once; projection to
-- pixels happens every tick and only subtracts the player's yard position.
function MinimapPins:BuildTargets(areaId, widthYards, heightYards, config)
    local targets = {}
    local database = Database()
    local questState = QuestState()
    local worldMap = WorldMapPins()
    if not database or not questState or not worldMap
        or type(widthYards) ~= "number" or type(heightYards) ~= "number" then
        return targets
    end

    local quests = questState:GetOrderedQuests()
    self.relevantBagItemIds = worldMap:GetRelevantBagItemIds(quests)
    local bagItems = BagItems()
    self.lastBagToken = bagItems and bagItems:GetTokenFor(self.relevantBagItemIds)

    -- Objectives: one dot for every still-needed direct objective coordinate
    -- in the database. That includes creature spawns, objects and exploration
    -- area triggers: all three are exact places the player can act. The shared
    -- collector removes a creature whose matching live objective is finished.
    -- The world map may turn the rest into blue area cells, but the minimap
    -- retains the raw positions rather than rebuilding that shape or choosing
    -- a representative centre. Completed quests use their existing turn-in
    -- "?" and therefore contribute no objective dots.
    local questIndex = 1
    local questTotal = table.getn(quests)
    local objectiveSeen = {}
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        if quest.isComplete ~= 1 then
            local questRed, questGreen, questBlue = UQ.GetQuestColor(quest)
            local locations = worldMap:CollectQuestLocations(
                quest, areaId, false, config)
            local locationIndex = 1
            local locationTotal = table.getn(locations)
            while locationIndex <= locationTotal do
                local location = locations[locationIndex]
                if type(location.x) == "number" and type(location.y) == "number" then
                    local locationKey = tostring(location.x) .. ":" .. tostring(location.y)
                    local existing = objectiveSeen[locationKey]
                    if existing then
                        if not existing.questSet[quest] then
                            existing.questSet[quest] = true
                            table.insert(existing.quests, quest)
                        end
                    else
                        local target = {
                            kind = "objective",
                            yardX = location.x * widthYards / 100,
                            yardY = location.y * heightYards / 100,
                            complete = false,
                            quest = quest,
                            quests = { quest },
                            questSet = { [quest] = true },
                            red = questRed,
                            green = questGreen,
                            blue = questBlue,
                        }
                        objectiveSeen[locationKey] = target
                        table.insert(targets, target)
                    end
                end
                locationIndex = locationIndex + 1
            end
        end
        questIndex = questIndex + 1
    end

    -- Turn-ins and givers, both straight from the world map's own policy.
    local turnIns = worldMap:CollectTurnIns(database, quests, areaId, config)
    local turnInIndex = 1
    local turnInTotal = table.getn(turnIns)
    while turnInIndex <= turnInTotal and turnInIndex <= MAX_TURNIN_PINS do
        local point = turnIns[turnInIndex]
        table.insert(targets, {
            kind = "turnin",
            yardX = point.x * widthYards / 100,
            yardY = point.y * heightYards / 100,
            complete = point.complete and true or false,
            point = point,
        })
        turnInIndex = turnInIndex + 1
    end

    local givers = worldMap:CollectAvailableGivers(database, quests, areaId, config)
    local giverIndex = 1
    local giverTotal = table.getn(givers)
    while giverIndex <= giverTotal and giverIndex <= MAX_GIVER_PINS do
        local entry = givers[giverIndex]
        table.insert(targets, {
            kind = "giver",
            yardX = entry.giver.x * widthYards / 100,
            yardY = entry.giver.y * heightYards / 100,
            lowLevel = entry.lowLevel and true or false,
            giver = entry.giver,
            questIds = entry.questIds,
        })
        giverIndex = giverIndex + 1
    end

    self.rebuildCount = self.rebuildCount + 1
    return targets
end

-- Projection ----------------------------------------------------------------

-- Places every target relative to the player.
--
-- Map UVs run east with x and SOUTH with y; the minimap runs east with x and
-- NORTH with y, so the vertical term is negated. This is the arithmetic the
-- probe's `track` variant confirmed glued to the terrain, unchanged.
function MinimapPins:Project(playerX, playerY, widthYards, heightYards, span, width, height, clampEdge)
    local pixelsPerYard = width / span
    local playerYardX = playerX * widthYards
    local playerYardY = playerY * heightYards
    local shortest = width
    local objectiveDotSize = self:GetObjectiveDotSize()
    if height < shortest then
        shortest = height
    end
    local objectiveIndex = 1
    local objectiveBorderIndex = 1
    local giverIndex = 1
    local turnInIndex = 1
    local clamped = 0
    local failures = 0
    -- Read once for the whole pass rather than per dot: the followed quest
    -- cannot change halfway through a projection, and the world map gates its
    -- own rim on the same feature.
    local mainQuest = nil
    if UQ:IsFeatureEnabled("mainQuestWaypoint") then
        mainQuest = MainQuest()
    end

    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local offsetX = (target.yardX - playerYardX) * pixelsPerYard
        local offsetY = -(target.yardY - playerYardY) * pixelsPerYard
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)

        local pin, half
        -- Non-nil only for a dot that is both drawn and followed; it carries
        -- the rim's size as well as the answer, because the rim tracks the
        -- dot's hovered size and not only the configured one.
        local borderSize
        if target.kind == "objective" then
            local highlighted = self:IsTargetHighlighted(target)
            local targetDotSize = objectiveDotSize
            if highlighted then
                targetDotSize = self:GetObjectiveDotSize(true)
            end
            half = targetDotSize / 2
            -- Visibility is decided from the configured resting size. A dot
            -- already visible at the edge must not disappear merely because
            -- the player hovered its tracker row and made it larger.
            local objectiveLimit = shortest / 2 - objectiveDotSize / 2 - CLAMP_MARGIN
            if objectiveLimit < 0 then
                objectiveLimit = 0
            end
            -- A creature point describes an exact database position. If that
            -- position is not inside the current minimap view, hiding it is
            -- accurate; clamping would turn many different distant spawns
            -- into one false pile on the edge.
            if distance <= objectiveLimit then
                pin = self:GetObjectivePin(objectiveIndex)
                if pin then
                    Client.SetMinimapPinSize(pin, targetDotSize, targetDotSize)
                    pin.unrealQuestObjectiveQuests = target.quests
                    pin.unrealQuestGiver = nil
                    pin.unrealQuestAvailableQuestIds = nil
                    pin.unrealQuestTurnIn = nil
                    if highlighted then
                        local red, green, blue = UQ.GetQuestColor(self.hoverQuestKey)
                        Client.SetMinimapPinColor(pin, red, green, blue)
                    else
                        Client.SetMinimapPinColor(pin,
                            target.red or OBJECTIVE_RED,
                            target.green or OBJECTIVE_GREEN,
                            target.blue or OBJECTIVE_BLUE)
                    end
                    if self:IsTargetFollowed(target, mainQuest) then
                        borderSize = targetDotSize + DOT_BORDER_PADDING
                    end
                end
            end
        elseif target.kind == "giver" and giverIndex <= MAX_GIVER_PINS then
            pin = self:GetGiverPin(giverIndex)
            half = GIVER_ICON_HEIGHT / 2
            if pin then
                pin.unrealQuestObjectiveQuests = nil
                pin.unrealQuestGiver = target.giver
                pin.unrealQuestAvailableQuestIds = target.questIds
                pin.unrealQuestTurnIn = nil
                if target.lowLevel then
                    Client.SetMinimapPinTexture(pin, Client.LOW_LEVEL_QUEST_TEXTURE)
                    Client.SetMinimapPinSize(pin, LOW_LEVEL_GIVER_ICON_WIDTH, GIVER_ICON_HEIGHT)
                else
                    Client.SetMinimapPinTexture(pin, Client.AVAILABLE_QUEST_TEXTURE)
                    Client.SetMinimapPinSize(pin, GIVER_ICON_WIDTH, GIVER_ICON_HEIGHT)
                end
            end
        elseif target.kind == "turnin" and turnInIndex <= MAX_TURNIN_PINS then
            pin = self:GetTurnInPin(turnInIndex)
            half = TURNIN_ICON_HEIGHT / 2
            if pin then
                pin.unrealQuestObjectiveQuests = nil
                pin.unrealQuestGiver = nil
                pin.unrealQuestAvailableQuestIds = nil
                pin.unrealQuestTurnIn = target.point
                if target.complete then
                    Client.SetMinimapPinTexture(pin, Client.COMPLETE_QUEST_TEXTURE)
                else
                    Client.SetMinimapPinTexture(pin, Client.ACTIVE_QUEST_TEXTURE)
                end
            end
        end

        if pin then
            -- Nothing clips a child of the minimap on this client, so a pin
            -- left where the arithmetic puts it would be drawn over whatever
            -- neighbours the minimap. Clamping is not presentation here, it is
            -- containment.
            local limit = shortest / 2 - half - CLAMP_MARGIN
            if limit < 0 then
                limit = 0
            end
            local onEdge = false
            local beyondEdge = target.kind ~= "objective" and distance > limit and distance > 0
            if beyondEdge and not clampEdge then
                -- Same treatment as an out-of-view objective: hidden rather
                -- than clamped, so the minimap stays uncrowded when the
                -- player has turned edge-clamping off.
                pin = nil
            elseif beyondEdge then
                local scale = limit / distance
                offsetX = offsetX * scale
                offsetY = offsetY * scale
                onEdge = true
                clamped = clamped + 1
            end
            if pin then
                local alpha = onEdge and EDGE_ALPHA or INSIDE_ALPHA
                if self.focusActive and not self:IsTargetInFocus(target) then
                    alpha = alpha * FOCUS_DIM_FACTOR
                end
                Client.SetMinimapPinAlpha(pin, alpha)
                if Client.PositionMinimapPin(pin, offsetX, offsetY) then
                    if target.kind == "objective" then
                        -- The rim rides its dot: same offset, same alpha, and
                        -- placed only after the dot itself landed, so a dot
                        -- that failed to position never leaves a bare gold
                        -- ring behind on the minimap.
                        if borderSize then
                            local border = self:GetObjectiveBorder(objectiveBorderIndex)
                            if border then
                                Client.SetMinimapPinSize(border, borderSize, borderSize)
                                Client.SetMinimapPinAlpha(border, alpha)
                                if Client.PositionMinimapPin(border, offsetX, offsetY) then
                                    objectiveBorderIndex = objectiveBorderIndex + 1
                                else
                                    Client.HideObject(border)
                                end
                            end
                        end
                        objectiveIndex = objectiveIndex + 1
                    elseif target.kind == "giver" then
                        giverIndex = giverIndex + 1
                    else
                        turnInIndex = turnInIndex + 1
                    end
                else
                    Client.HideObject(pin)
                    failures = failures + 1
                end
            end
        end
        index = index + 1
    end

    self.objectiveVisible = HidePoolFrom(self.objectivePool, objectiveIndex)
    self.objectiveBorderVisible = HidePoolFrom(
        self.objectiveBorderPool, objectiveBorderIndex)
    self.giverVisible = HidePoolFrom(self.giverPool, giverIndex)
    self.turnInVisible = HidePoolFrom(self.turnInPool, turnInIndex)
    self.poolsHidden = false
    self.clampedCount = clamped
    self.pinFailures = failures
end

-- Refresh -------------------------------------------------------------------

function MinimapPins:Refresh()
    local config = UQ:GetModule("Config")
    -- Asked on every refresh rather than once at load, so turning the setting
    -- off in game re-levels the pins that already exist instead of waiting for
    -- a reload. The call is a no-op once the state matches.
    Client.SetMinimapPinsBelowPlayerArrow(
        not config or config:Get("minimapPinsBelowArrow") ~= false)
    if not self.arrowDeclared then
        self.arrowDeclared = true
        local arrow = Client.GetMinimapPlayerArrowState()
        if arrow.arrowRaised then
            UQ:DeclareCapability("minimapPlayerArrowOrder", "detected",
                "the client handed over a minimap player arrow as a Model child of Minimap;"
                .. " it is raised to level " .. tostring(arrow.pinLevel + 5)
                .. ", above the pins, which keep their measured band")
        elseif arrow.below then
            UQ:DeclareCapability("minimapPlayerArrowOrder", "unverified",
                "no arrow handle exists here and none can: probe 1.37.0 found 7 Minimap children,"
                .. " none an arrow, and probes 1.46.1/1.47.0 (mmarrowwalk, mmarrowtrio, 2026-09-09)"
                .. " closed both remaining routes -- EnumerateFrames reaches only named objects"
                .. " (4486 of 4486) at ~1889ms per walk, GetModel returns nil on every Model, and"
                .. " the MiniWorldMapArrowFrame trio returns no object at all. See"
                .. " minimap.player_arrow_not_addressable."
                .. " So the pins are lowered to level " .. tostring(arrow.pinLevel)
                .. " instead, on the UNMEASURED hypothesis that the engine draws the arrow above"
                .. " that band. Nothing reports the arrow's own level and no probe can read it, so"
                .. " only looking at the minimap settles it; the minimapPinsBelowArrow setting"
                .. " puts the pins back at 120. /uq minimap prints the level in use")
        else
            UQ:DeclareCapability("minimapPlayerArrowOrder", "missing",
                "turned off by the player: the pins keep the measured level-120 band and draw"
                .. " over the player arrow, as they did before the setting existed")
        end
    end
    if config and not config:Get("minimapPins") then
        self:HideAll()
        self:Record("disabled")
        return
    end

    -- Refused, not approximated. See the header.
    if Client.IsMinimapRotating() then
        self:HideAll()
        self:Record("rotatingMinimap")
        return
    end

    local width, height, zoom = Client.GetMinimapGeometry()
    if not width then
        self:HideAll()
        self:Record("noMinimap")
        return
    end
    if not self.canvasDeclared then
        self.canvasDeclared = true
        UQ:DeclareCapability("minimapCanvas", "detected",
            "Minimap resolved with geometry at runtime; children of it are confirmed to render unclipped")
    end

    local mapContext = MapContext()
    local database = Database()
    local questState = QuestState()
    if not mapContext or not database or not database.available
        or not database:IsIndexReady() or not questState then
        self:HideAll()
        self:Record("databaseNotReady")
        return
    end

    -- The same guard the world map uses, and for the same reason: without a
    -- current-zone view GetPlayerMapPosition does not describe the player's
    -- own zone, and every offset computed from it would be measured from the
    -- wrong origin. Hiding is the honest answer -- a frozen pin cloud would
    -- keep looking authoritative while the player walks away from it.
    local areaId, report, viewReason = mapContext:GetCurrentZoneView()
    if not areaId then
        self:HideAll()
        self:Record("viewUnavailable:" .. tostring(viewReason))
        return
    end

    -- Persisted with every state below, not only on failure: a wrong area
    -- resolves silently -- another zone's coordinates against another zone's
    -- yard span still draws pins, they simply do not describe the ground. The
    -- route that produced it is the thing that has to be readable afterwards.
    local identity = {
        areaId = areaId,
        areaIdHow = tostring(report.areaIdHow),
        mapZoneName = tostring(report.mapZoneName),
        realZoneText = tostring(report.realZoneText),
        zoneText = tostring(report.zoneText),
        areaIdFromMapZone = tostring(report.areaIdFromMapZone),
        areaIdFromRealZoneText = tostring(report.areaIdFromRealZoneText),
        areaIdFromZoneText = tostring(report.areaIdFromZoneText),
        playerX = report.playerX,
        playerY = report.playerY,
    }
    local span, spanEvidence = SpanForZoom(zoom, areaId)
    if not span then
        self:HideAll()
        identity.zoom = tostring(zoom)
        self:Record("unknownZoom", identity)
        return
    end
    -- Indoors the minimap covers fewer yards at the same zoom step, and this
    -- client exposes no way to learn how many: the zoom CVars are measured
    -- absent, so the layer cannot rescale and would place every pin at the
    -- wrong distance -- drifting along with the player rather than staying on
    -- the ground. Withholding the pins is the honest answer, and it is the
    -- same rule this layer already applies to a rotating minimap and to a view
    -- that cannot project the player.
    if (not config or config:Get("minimapPinsHideIndoors") ~= false)
        and mapContext:IsInterior(report) then
        self:HideAll()
        identity.interior = true
        self:Record("interior", identity)
        return
    end

    local indoorState, indoorHow = Client.GetMinimapIndoorState()
    identity.indoor = tostring(indoorState)
    identity.indoorHow = tostring(indoorHow)
    local cvarOutside, cvarInside = Client.GetMinimapZoomCVars()
    identity.zoomCVarOutside = tostring(cvarOutside)
    identity.zoomCVarInside = tostring(cvarInside)
    self.lastIndoorState = indoorState
    self.lastZoom = zoom

    local yards = database:GetZoneYards(areaId)
    if type(yards) ~= "table" or type(yards[1]) ~= "number" or type(yards[2]) ~= "number" then
        self:HideAll()
        self:Record("noZoneSize", identity)
        return
    end
    identity.zoneYardsX = yards[1]
    identity.zoneYardsY = yards[2]

    -- Does the client still describe where the player IS?
    --
    -- Every offset this layer computes is (target - player), so a player
    -- position that stops updating does not degrade the pins, it inverts what
    -- they mean: each one keeps exactly the offset it had and rides along with
    -- the player, looking authoritative while describing nothing. That is the
    -- same failure the layer already refuses elsewhere -- "the pins hide rather
    -- than freeze" -- and the only one that produces markers which follow the
    -- player instead of the ground.
    --
    -- IsPlayerMoving is what makes the test safe, and it is measured on this
    -- client as tracking standing versus running: standing still is the
    -- ordinary reason for an unchanged position, and it must never hide the
    -- layer. An unavailable IsPlayerMoving returns nil, which can never
    -- accumulate staleness, so nothing changes on a client that lacks it.
    local now = Client.Now()
    local moving = Client.IsPlayerMoving()
    if report.playerX ~= self.lastPlayerX or report.playerY ~= self.lastPlayerY then
        self.lastPlayerX = report.playerX
        self.lastPlayerY = report.playerY
        self.playerStaleSince = nil
    elseif moving and now then
        if not self.playerStaleSince then
            self.playerStaleSince = now
        end
    else
        self.playerStaleSince = nil
    end
    local staleFor = 0
    if self.playerStaleSince and now then
        staleFor = now - self.playerStaleSince
    end
    identity.playerMoving = moving and true or false
    identity.playerStaleFor = staleFor
    if staleFor >= PLAYER_POSITION_STALE_SECONDS then
        self:HideAll()
        self:Record("playerPositionStale", identity)
        return
    end

    local showLowLevel = config and config:Get("showLowLevelQuests") and true or false
    if self.dirty or self.lastAreaId ~= areaId or self.lastShowLowLevel ~= showLowLevel then
        self.targets = self:BuildTargets(areaId, yards[1], yards[2], config)
        self.lastAreaId = areaId
        self.lastShowLowLevel = showLowLevel
        self.dirty = false
    end

    local clampEdge = not config or config:Get("minimapPinsClampEdge") ~= false
    self:Project(report.playerX, report.playerY, yards[1], yards[2], span, width, height, clampEdge)

    identity.zoom = tostring(zoom)
    identity.span = span
    identity.spanEvidence = spanEvidence
    -- The job that re-points these pins is on the shared driver, and
    -- Core/Driver.lua disables a job after five consecutive failures. A
    -- disabled job does not hide anything: the pins keep their last offsets
    -- from the minimap's centre, which is the player, so they appear to follow
    -- the player around instead of staying on the ground. That is invisible
    -- from the pins themselves, so the counter is persisted here.
    local driver = UQ:GetModule("Driver")
    if driver then
        local jobs = driver:GetJobReport()
        local jobIndex = 1
        local jobTotal = table.getn(jobs)
        while jobIndex <= jobTotal do
            local job = jobs[jobIndex]
            if job.name == "map.minimappins" then
                identity.jobActive = job.active and true or false
                identity.jobFailures = job.failures
            end
            jobIndex = jobIndex + 1
        end
    end
    if self.objectiveVisible > 0 or self.giverVisible > 0 or self.turnInVisible > 0 then
        self:Record("rendered", identity)
    else
        self:Record("noTargets", identity)
    end
end

function MinimapPins:GetStatus()
    local width, height, zoom = Client.GetMinimapGeometry()
    local mapContext = MapContext()
    local areaId = mapContext and mapContext:GetCurrentZoneView()
    local span, spanEvidence = SpanForZoom(zoom, areaId)
    local config = UQ:GetModule("Config")
    return {
        enabled = not config or config:Get("minimapPins") and true or false,
        state = self.lastState,
        width = width,
        areaId = areaId,
        zoom = zoom,
        span = span,
        spanEvidence = spanEvidence,
        rotating = Client.IsMinimapRotating(),
        objectives = self.objectiveVisible,
        givers = self.giverVisible,
        turnIns = self.turnInVisible,
        clamped = self.clampedCount,
        pinFailures = self.pinFailures,
        pinClicks = self.clickCount or 0,
        rebuilds = self.rebuildCount,
        targets = table.getn(self.targets),
    }
end

function MinimapPins:OnEnable()
    local state = QuestState()
    if state then
        state:AddListener(function(event, quest, targetsChanged)
            if event ~= "QUEST_OBJECTIVES_CHANGED" or targetsChanged then
                MinimapPins.dirty = true
            end
        end)
    end

    local bagItems = BagItems()
    self.lastBagToken = bagItems and bagItems:GetTokenFor(self.relevantBagItemIds)
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.minimappins", REFRESH_INTERVAL, function()
            MinimapPins:Refresh()
        end)
        -- Second job on the same shared driver rather than a second OnUpdate
        -- frame: it only flips a flag, and the refresh above picks it up.
        driver:Schedule("map.minimappins.rebuild", REBUILD_INTERVAL, function()
            local token = bagItems and bagItems:GetTokenFor(
                MinimapPins.relevantBagItemIds)
            -- No BagItems module at all means no token to compare, so the
            -- unconditional rebuild this replaced is what runs instead: the
            -- poll must never become weaker than it was when it cannot see
            -- the thing it is polling.
            if not token or token ~= MinimapPins.lastBagToken then
                MinimapPins.lastBagToken = token
                MinimapPins.dirty = true
            end
        end)
    end
    self.dirty = true
    self:Refresh()
end
