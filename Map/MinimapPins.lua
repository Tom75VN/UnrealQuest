--[[
UnrealQuest / Map/MinimapPins.lua

The same quest scene as the world map, drawn around the player on the minimap.

What it draws, and what it deliberately does not:

  * one DOT per quest-creature spawn from the bundled database. These are the
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
-- listener never fires for it.
local REBUILD_INTERVAL = 5

local MAX_GIVER_PINS = 16
local MAX_TURNIN_PINS = 16
-- Frame-name bands, exactly as the world map separates its pools. Names must
-- stay unique per pool; the client mangles nothing here but a collision would
-- silently hand two pools the same frame.
local OBJECTIVE_INDEX_OFFSET = 0
local GIVER_INDEX_OFFSET = 1000
local TURNIN_INDEX_OFFSET = 2000

-- A quest-creature spawn is a dot, not the 14x14 the icons keep: at minimap
-- scale several nearby spawns can land close together and full-size squares
-- would merge into one blob.
local DOT_SIZE = 6
local ICON_SIZE = 12
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

local OBJECTIVE_RED, OBJECTIVE_GREEN, OBJECTIVE_BLUE = 0.12, 0.55, 1

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
local SPAN_MEASURED_ZOOM = 0

MinimapPins.objectivePool = {}
MinimapPins.giverPool = {}
MinimapPins.turnInPool = {}
MinimapPins.objectiveVisible = 0
MinimapPins.giverVisible = 0
MinimapPins.turnInVisible = 0
MinimapPins.targets = {}
MinimapPins.dirty = true
MinimapPins.lastAreaId = nil
MinimapPins.rebuildCount = 0
MinimapPins.clampedCount = 0
MinimapPins.pinFailures = 0
MinimapPins.lastState = nil
MinimapPins.lastDiagnosticKey = nil
MinimapPins.canvasDeclared = false

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

-- Pools ---------------------------------------------------------------------

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
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

function MinimapPins:GetObjectivePin(index)
    local pin = self.objectivePool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin(index + OBJECTIVE_INDEX_OFFSET, DOT_SIZE,
        OBJECTIVE_RED, OBJECTIVE_GREEN, OBJECTIVE_BLUE)
    if pin then
        self.objectivePool[index] = pin
        Client.SetMinimapPinTexture(pin, Client.MINIMAP_OBJECTIVE_TEXTURE)
    end
    return pin
end

function MinimapPins:GetGiverPin(index)
    local pin = self.giverPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin(index + GIVER_INDEX_OFFSET, ICON_SIZE, 1, 1, 1)
    if pin then
        self.giverPool[index] = pin
        Client.SetMinimapPinTexture(pin, Client.AVAILABLE_QUEST_TEXTURE)
    end
    return pin
end

function MinimapPins:GetTurnInPin(index)
    local pin = self.turnInPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin(index + TURNIN_INDEX_OFFSET, TURNIN_ICON_HEIGHT, 1, 1, 1)
    if pin then
        self.turnInPool[index] = pin
        Client.SetMinimapPinTexture(pin, Client.ACTIVE_QUEST_TEXTURE)
        Client.SetMinimapPinSize(pin, TURNIN_ICON_WIDTH, TURNIN_ICON_HEIGHT)
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
    if type(zoom) ~= "number" then
        -- No zoom reading at all. The measured step is the only one that can
        -- be defended, and it is also the client's default.
        return SPAN_OUTDOOR[SPAN_MEASURED_ZOOM], "assumedDefaultZoom"
    end
    local span = SPAN_OUTDOOR[zoom]
    if not span then
        return nil, "unknownZoom"
    end
    if zoom == SPAN_MEASURED_ZOOM then
        return span, "measured"
    end
    return span, "vanillaConstant"
end

-- Shared with Map/NpcPins.lua. Both minimap layers must use the same measured
-- zoom span rather than maintaining two tables that can drift apart.
function MinimapPins:GetSpanForZoom(zoom)
    return SpanForZoom(zoom)
end

-- Targets -------------------------------------------------------------------

-- The scene, in database percentages, rebuilt only when something that can
-- change it has changed. Projection to pixels happens every tick; this does
-- not.
function MinimapPins:BuildTargets(areaId, config)
    local targets = {}
    local database = Database()
    local questState = QuestState()
    local worldMap = WorldMapPins()
    if not database or not questState or not worldMap then
        return targets
    end

    local quests = questState:GetOrderedQuests()

    -- Objectives: one dot for every raw creature spawn in the database. The
    -- world map turns these coordinates into blue area cells, but the minimap
    -- must retain the creature positions rather than rebuilding that shape or
    -- choosing a representative centre. Completed quests use their existing
    -- turn-in "?" and therefore contribute no objective dots.
    local questIndex = 1
    local questTotal = table.getn(quests)
    local objectiveSeen = {}
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        if quest.isComplete ~= 1 then
            local locations = worldMap:CollectQuestLocations(
                quest, areaId, false, config)
            local locationIndex = 1
            local locationTotal = table.getn(locations)
            while locationIndex <= locationTotal do
                local location = locations[locationIndex]
                if location.sourceType == "unit"
                    and type(location.x) == "number" and type(location.y) == "number" then
                    local locationKey = tostring(location.x) .. ":" .. tostring(location.y)
                    if not objectiveSeen[locationKey] then
                        objectiveSeen[locationKey] = true
                        table.insert(targets, {
                            kind = "objective",
                            x = location.x,
                            y = location.y,
                            complete = false,
                        })
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
            x = point.x,
            y = point.y,
            complete = point.complete and true or false,
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
            x = entry.giver.x,
            y = entry.giver.y,
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
    local yardsPerPixel = span / width
    local shortest = width
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
        local offsetX = ((target.x / 100) - playerX) * widthYards / yardsPerPixel
        local offsetY = -(((target.y / 100) - playerY) * heightYards) / yardsPerPixel
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)

        local pin, half
        if target.kind == "objective" then
            half = DOT_SIZE / 2
            local objectiveLimit = shortest / 2 - half - CLAMP_MARGIN
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
                    Client.SetMinimapPinColor(pin,
                        OBJECTIVE_RED, OBJECTIVE_GREEN, OBJECTIVE_BLUE)
                end
            end
        elseif target.kind == "giver" and giverIndex <= MAX_GIVER_PINS then
            pin = self:GetGiverPin(giverIndex)
            half = ICON_SIZE / 2
        elseif target.kind == "turnin" and turnInIndex <= MAX_TURNIN_PINS then
            pin = self:GetTurnInPin(turnInIndex)
            half = TURNIN_ICON_HEIGHT / 2
            if pin then
                -- Same two states as the world map's "?", by the same route:
                -- greyscale for a quest still in progress, full colour once it
                -- is ready to hand in.
                if target.complete then
                    Client.SetWorldMapPinDesaturated(pin, false)
                else
                    Client.SetWorldMapPinDesaturated(pin, true)
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

    local yards = database:GetZoneYards(areaId)
    if type(yards) ~= "table" or type(yards[1]) ~= "number" or type(yards[2]) ~= "number" then
        self:HideAll()
        self:Record("noZoneSize")
        return
    end

    if self.dirty or self.lastAreaId ~= areaId then
        self.targets = self:BuildTargets(areaId, config)
        self.lastAreaId = areaId
        self.dirty = false
    end

    local clampEdge = not config or config:Get("minimapPinsClampEdge") ~= false
    self:Project(report.playerX, report.playerY, yards[1], yards[2], span, width, height, clampEdge)

    if self.objectiveVisible > 0 or self.giverVisible > 0 or self.turnInVisible > 0 then
        self:Record("rendered", { zoom = tostring(zoom), span = span, spanEvidence = spanEvidence })
    else
        self:Record("noTargets", { zoom = tostring(zoom), span = span, spanEvidence = spanEvidence })
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

    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.minimappins", REFRESH_INTERVAL, function()
            MinimapPins:Refresh()
        end)
        -- Second job on the same shared driver rather than a second OnUpdate
        -- frame: it only flips a flag, and the refresh above picks it up.
        driver:Schedule("map.minimappins.rebuild", REBUILD_INTERVAL, function()
            MinimapPins.dirty = true
        end)
    end
    self.dirty = true
    self:Refresh()
end
