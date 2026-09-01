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
    is correct here; a marker anchored to a world coordinate stayed glued while
    the player walked.

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

-- Measured spans, keyed by zoom step, dialled in from inside the game with
-- "/uq minimap span <yards>" and kept in SavedVariables.
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
-- Overrides are per zoom step and stored separately for indoors, because this
-- client selects a different zoom step inside (measured: 3 inside Brill Town
-- Hall against 0 outdoors) AND appears to use a different span at that same
-- step. Neither is guessed at here: an unmeasured combination simply falls
-- back to the Vanilla constant it used before.
local SPAN_SECTION = "minimapSpans"

local function SpanOverrideKey(zoom, indoor)
    local prefix = "out"
    if indoor == "indoor" then
        prefix = "in"
    end
    return prefix .. tostring(zoom)
end

local function SpanOverride(zoom, indoor)
    local config = UQ:GetModule("Config")
    if not config or type(zoom) ~= "number" then
        return nil
    end
    local section = config:GetSection(SPAN_SECTION)
    local value = section and section[SpanOverrideKey(zoom, indoor)]
    if type(value) ~= "number" or value <= 0 then
        return nil
    end
    return value
end

MinimapPins.objectivePool = {}
MinimapPins.giverPool = {}
MinimapPins.turnInPool = {}
MinimapPins.objectiveVisible = 0
MinimapPins.giverVisible = 0
MinimapPins.turnInVisible = 0
MinimapPins.targets = {}
MinimapPins.dirty = true
MinimapPins.lastAreaId = nil
MinimapPins.lastBagToken = nil
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

-- Pools ---------------------------------------------------------------------

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
        if pool[index] == MinimapPins.hoverPin then
            Client.HideGameTooltip(pool[index])
            MinimapPins.hoverPin = nil
        end
        Client.HideObject(pool[index])
        index = index + 1
    end
    return first - 1
end

function MinimapPins:HideAll()
    self.objectiveVisible = HidePoolFrom(self.objectivePool, 1)
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
        -- Minimap pins have no click gesture, so the world-map shift-click
        -- hint would advertise an action this surface deliberately lacks.
        return worldMap:BuildGiverTooltipLines(pin.unrealQuestGiver,
            pin.unrealQuestAvailableQuestIds or {}, true)
    end
    if pin.unrealQuestTurnIn then
        return worldMap:BuildTurnInTooltipLines(pin.unrealQuestTurnIn)
    end
    return nil
end

function MinimapPins:OnPinEnter(pin)
    self.hoverPin = pin
    local lines = self:TooltipLines(pin)
    if lines and table.getn(lines) > 0 then
        Client.ShowGameTooltip(pin, lines, "ANCHOR_LEFT")
    end
end

function MinimapPins:OnPinLeave(pin)
    if self.hoverPin == pin then
        self.hoverPin = nil
    end
    Client.HideGameTooltip(pin)
end

function MinimapPins:SetTooltipHandlers(pin)
    Client.SetWorldMapPinHandlers(pin,
        function() MinimapPins:OnPinEnter(pin) end,
        function() MinimapPins:OnPinLeave(pin) end,
        nil)
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
end

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
        self:SetTooltipHandlers(pin)
    end
    return pin
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
        self:SetTooltipHandlers(pin)
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
        self:SetTooltipHandlers(pin)
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
local function SpanForZoom(zoom)
    local indoor = Client.GetMinimapIndoorState()
    local override = SpanOverride(zoom, indoor)
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
function MinimapPins:GetSpanForZoom(zoom)
    return SpanForZoom(zoom)
end

-- Records a span the player has dialled in for the zoom step and environment
-- they are standing in right now. Passing nil clears it and returns the layer
-- to the constant. Returns the key it wrote, the value, and the span now in
-- use, so the caller can report exactly what changed.
function MinimapPins:SetSpanOverride(yards)
    local config = UQ:GetModule("Config")
    if not config then
        return nil
    end
    local width, height, zoom = Client.GetMinimapGeometry()
    if type(zoom) ~= "number" then
        return nil
    end
    local indoor = Client.GetMinimapIndoorState()
    local key = SpanOverrideKey(zoom, indoor)
    if yards and yards > 0 then
        config:SetSectionEntry(SPAN_SECTION, key, yards)
    else
        config:SetSectionEntry(SPAN_SECTION, key, nil)
    end
    self.dirty = true
    self:Refresh()
    local span, evidence = SpanForZoom(zoom)
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
    local giverIndex = 1
    local turnInIndex = 1
    local clamped = 0
    local failures = 0

    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local offsetX = (target.yardX - playerYardX) * pixelsPerYard
        local offsetY = -(target.yardY - playerYardY) * pixelsPerYard
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)

        local pin, half
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
                Client.SetMinimapPinAlpha(pin, onEdge and EDGE_ALPHA or INSIDE_ALPHA)
                if Client.PositionMinimapPin(pin, offsetX, offsetY) then
                    if target.kind == "objective" then
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
    self.giverVisible = HidePoolFrom(self.giverPool, giverIndex)
    self.turnInVisible = HidePoolFrom(self.turnInPool, turnInIndex)
    self.clampedCount = clamped
    self.pinFailures = failures
end

-- Refresh -------------------------------------------------------------------

function MinimapPins:Refresh()
    local config = UQ:GetModule("Config")
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

    local span, spanEvidence = SpanForZoom(zoom)
    if not span then
        self:HideAll()
        self:Record("unknownZoom", { zoom = tostring(zoom) })
        return
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
    local span, spanEvidence = SpanForZoom(zoom)
    local config = UQ:GetModule("Config")
    return {
        enabled = not config or config:Get("minimapPins") and true or false,
        state = self.lastState,
        width = width,
        zoom = zoom,
        span = span,
        spanEvidence = spanEvidence,
        rotating = Client.IsMinimapRotating(),
        objectives = self.objectiveVisible,
        givers = self.giverVisible,
        turnIns = self.turnInVisible,
        clamped = self.clampedCount,
        pinFailures = self.pinFailures,
        rebuilds = self.rebuildCount,
        targets = table.getn(self.targets),
    }
end

function MinimapPins:OnEnable()
    local state = QuestState()
    if state then
        state:AddListener(function()
            MinimapPins.dirty = true
        end)
    end

    local bagItems = BagItems()
    self.lastBagToken = bagItems and bagItems:GetToken()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.minimappins", REFRESH_INTERVAL, function()
            MinimapPins:Refresh()
        end)
        -- Second job on the same shared driver rather than a second OnUpdate
        -- frame: it only flips a flag, and the refresh above picks it up.
        driver:Schedule("map.minimappins.rebuild", REBUILD_INTERVAL, function()
            local token = bagItems and bagItems:GetToken()
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
