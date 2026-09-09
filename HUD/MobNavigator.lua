--[[
UnrealQuest / HUD/MobNavigator.lua

The mob navigator: a SECOND arc-and-arrow dial, independent of the quest
navigator, aimed at the nearest recorded spawn of a creature the player is
tracking from the options page's Mob tracking tab.

## Why a second dial rather than a mode on the first one

The two answer different questions at the same time. "Which way is my quest?"
and "which way is the creature I came here to find?" are both live while the
player is hunting a specific mob for a drop, a rare, or a skinning target -- so
a single dial that had to choose between them would be wrong half the time, and
a dial that alternated would be unreadable.

Everything is therefore duplicated rather than shared: its own frame, its own
saved anchor, its own scale, its own refresh interval and its own enable
switch. Nothing here reads or writes a `navigator*` setting. The two can be
dragged to opposite corners and neither knows about the other. The shipped
default puts this one a dial's width to the left of the quest navigator, so a
player who tracks their first mob sees two dials instead of one dial with a
second hidden exactly behind it.

What IS shared is the widget construction and the rotation technique, both from
`Compatibility/ClientAPI.lua`: `Client.CreateNavigator` is already
name-parameterized, and the 64-cell pre-rotated atlas is a client fact rather
than a quest fact. Forking either would double the maintenance of the one part
of this layer that is measured rather than chosen (see docs/HUD-NAVIGATOR.md,
"The rotation").

Two visible differences from the quest dial, both so a glance can tell them
apart without reading the numbers:

  * the arrow wears the accent gold that `Map/NpcPins.lua` already gives a
    tracked-mob pin, rather than the quest arrow's white;
  * a caption above the arc names the creature. The quest navigator has no
    caption because the tracker already names the followed quest; nothing else
    on screen names the tracked mob this arrow chose.

## The target, and what "nearest" can honestly mean here

There is no API on this client that finds a live creature. The arrow therefore
aims at a recorded SPAWN POINT from the bundled world data -- the same
coordinates `Map/NpcPins.lua` draws as tracked-mob pins -- and not at the mob
itself, which may be dead, wandering, or at the far end of its patrol. That is
the whole of what this data supports, and the mark on the map exists partly to
say so: the pin the ring is around is the exact point the arrow is aiming at,
so the player can see it is aiming at a place rather than at a creature.

Tracking is single-select (`Map/NpcPins.lua`, `SetMobTracked`), and that rule
exists FOR this dial: with several creatures tracked, the arrow re-picked the
nearest spawn of any of them four times a second, so it changed target as the
player moved and the caption named a different creature every few steps. That
reads as a bug rather than as a feature. One creature, one arrow, one ring.

The nearest spawn OF THAT ONE CREATURE is still re-picked at the context
cadence, because a creature has many recorded spawns and walking past one
should hand the arrow to the next.

A saved file written before single-select may still hold several tracked IDs.
Nothing here rejects that: the scene is built from the whole list, so the arrow
keeps working until the player next taps a row, which collapses the list to
one.

## Two cadences

Same split, and the same reason, as the quest navigator: `mobnav.context` at
4Hz picks the nearest spawn from a cached scene, and `mobnav.arrow` at 20Hz
does one position read, one facing read and one rotation. The scene is rebuilt
only when the tracked set or the zone changes -- both of which are cheap
strings to compare, unlike the quest scene's spawn-location walk.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local MobNavigator = UQ:NewModule("MobNavigator")

-- Same knob, same reason, as HUD/Navigator.lua's: art whose rest orientation
-- is not "up" is corrected here rather than in the angle arithmetic.
local ROTATION_OFFSET = 0

local BASE_RENDER_SCALE = 0.5

local ALPHA_ALIGNED = 1
local ALPHA_OPPOSITE = 0.45
local ARC_ALPHA = 0.65
local ARC_ALPHA_AT_TARGET = 0.35

local DIAL_WIDTH = 220
local ARROW_SIZE = 130

-- The same ceiling Map/NpcPins.lua puts on its whole pin budget. A tracked
-- creature with hundreds of recorded spawns in one zone -- Kobold Vermin has
-- them -- must not turn the 4Hz nearest-spawn pass into a long walk, and the
-- nearest of the first 480 recorded points is the nearest in practice.
local MAX_SPAWNS = 480

MobNavigator.frame = nil
MobNavigator.createFailed = false
MobNavigator.shown = false
MobNavigator.context = nil
MobNavigator.contextReason = nil
MobNavigator.scene = nil
MobNavigator.sceneSignature = nil
MobNavigator.sceneBuilds = 0
MobNavigator.hiddenReason = nil
MobNavigator.hiddenCounts = {}
MobNavigator.placements = 0
MobNavigator.placementFailures = 0
MobNavigator.rotations = 0
MobNavigator.rotationFailures = 0
MobNavigator.lastRelativeAngle = nil
MobNavigator.lastDistanceYards = nil
MobNavigator.lastFacingSource = nil
MobNavigator.lastTargetName = nil
MobNavigator.dragging = false
MobNavigator.drags = 0
MobNavigator.dragFailures = 0

local function Config()
    return UQ:GetModule("Config")
end

local function Database()
    return UQ:GetModule("Database")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

local function NpcPins()
    return UQ:GetModule("NpcPins")
end

local function PlayerHeading()
    return UQ:GetModule("PlayerHeading")
end

function MobNavigator:Hide(reason)
    self.hiddenReason = reason
    if reason then
        self.hiddenCounts[reason] = (self.hiddenCounts[reason] or 0) + 1
    end
    if self.frame and self.shown then
        Client.HideObject(self.frame)
        self.shown = false
    end
end

function MobNavigator:GetFrame()
    if self.frame or self.createFailed then
        return self.frame
    end
    -- No hyphen in the widget name: this client rewrites "-" in widget names
    -- into a filler string.
    self.frame = Client.CreateNavigator("UnrealQuestMobNavigator", DIAL_WIDTH,
        ARROW_SIZE, true)
    if not self.frame then
        self.createFailed = true
        UQ:Debug("mob navigator could not be created")
    elseif not Client.SetNavigatorDrag(self.frame, function()
        MobNavigator:StartDrag()
    end, function()
        MobNavigator:StopDrag()
    end) then
        UQ:Warn(UQ.L("MOBNAV_WARN_NO_HANDLE"))
    end
    return self.frame
end

function MobNavigator:StartDrag()
    if not self.frame then
        return false
    end
    if not Client.StartFrameDrag(self.frame) then
        self.dragFailures = self.dragFailures + 1
        UQ:Warn(UQ.L("MOBNAV_WARN_DRAG_FAILED"))
        return false
    end
    self.dragging = true
    self.drags = self.drags + 1
    return true
end

function MobNavigator:CapturePosition()
    local config = Config()
    if not self.frame or not config then
        return false
    end
    local point, relativeName, relativePoint, x, y =
        Client.GetFrameAnchor(self.frame)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        UQ:Warn(UQ.L("MOBNAV_WARN_NO_POSITION"))
        return false
    end
    -- relativeName is deliberately not persisted, for the reason every other
    -- movable frame here gives: a live frame reference does not survive a
    -- reload, so every saved anchor is reapplied against UIParent.
    config:Set("mobNavigatorPoint", point)
    config:Set("mobNavigatorRelativePoint",
        type(relativePoint) == "string" and relativePoint or point)
    config:Set("mobNavigatorX", x)
    config:Set("mobNavigatorY", y)
    return true
end

function MobNavigator:StopDrag()
    if not self.frame then
        return false
    end
    Client.StopFrameDrag(self.frame)
    self.dragging = false
    return self:CapturePosition()
end

-- The slow half ---------------------------------------------------------------

-- One string that changes exactly when the cached spawn scene would. The
-- tracked set is a handful of IDs, so comparing it costs far less than the
-- database walk it avoids -- and unlike the quest scene, nothing else can
-- invalidate this one.
local function SceneSignature(areaId, unitIds)
    local signature = tostring(areaId)
    local index = 1
    local total = table.getn(unitIds)
    while index <= total do
        signature = signature .. ":" .. tostring(unitIds[index])
        index = index + 1
    end
    return signature
end

function MobNavigator:BuildScene(areaId, unitIds, signature)
    local database = Database()
    if not database or not database.available then
        return false, "databaseUnavailable"
    end
    local spawns = database:GetTrackedMobLocations(areaId, unitIds, MAX_SPAWNS)
    self.scene = {
        areaId = areaId,
        spawns = spawns,
        spawnCount = table.getn(spawns),
    }
    self.sceneSignature = signature
    self.sceneBuilds = self.sceneBuilds + 1
    return true
end

-- The nearest recorded spawn, in zone yards. The first candidate wins an exact
-- tie, which makes the result follow the database's own record order rather
-- than hash iteration order.
function MobNavigator:FindNearestSpawn(playerU, playerV,
    eastPerPercent, southPerPercent)
    local scene = self.scene
    if not scene then
        return nil, "noScene"
    end
    if type(playerU) ~= "number" or type(playerV) ~= "number" then
        return nil, "playerNotOnView"
    end

    local playerX = playerU * 100
    local playerY = playerV * 100
    local best = nil
    local bestDistanceSquared = nil

    local index = 1
    local total = scene.spawnCount
    while index <= total do
        local spawn = scene.spawns[index]
        if type(spawn) == "table" and type(spawn.x) == "number"
            and type(spawn.y) == "number" then
            local east = (spawn.x - playerX) * eastPerPercent
            local south = (spawn.y - playerY) * southPerPercent
            local distanceSquared = east * east + south * south
            if not best or distanceSquared < bestDistanceSquared then
                best = spawn
                bestDistanceSquared = distanceSquared
            end
        end
        index = index + 1
    end

    if not best then
        return nil, "noTrackedMobsInArea"
    end
    return best
end

function MobNavigator:RefreshContext()
    self.context = nil

    local config = Config()
    if config and config:Get("mobNavigatorEnabled") == false then
        self.contextReason = "disabledBySetting"
        return
    end
    -- Asked of the quest navigator rather than re-probed: whether this client
    -- accepts four-argument atlas selection is one client fact, and two
    -- modules caching two answers to it could disagree.
    local navigator = UQ:GetModule("Navigator")
    if navigator and not navigator:RotationSupported() then
        self.contextReason = "noRotation"
        return
    end

    local pins = NpcPins()
    if not pins then
        self.contextReason = "noNpcPins"
        return
    end
    local unitIds = pins:GetTrackedMobIds()
    if table.getn(unitIds) == 0 then
        self.contextReason = "noTrackedMobs"
        return
    end

    local mapContext = MapContext()
    if not mapContext then
        self.contextReason = "noMapContext"
        return
    end
    -- The same gate the map pins and the quest navigator use: a uniquely
    -- resolved player area, and a view that can project the player.
    local areaId, _, why = mapContext:GetCurrentZoneView()
    if not areaId then
        self.contextReason = why or "noZoneView"
        return
    end

    local questTarget = QuestTarget()
    if not questTarget then
        self.contextReason = "noQuestTarget"
        return
    end
    local eastPerPercent, southPerPercent = questTarget:ToYards(areaId, 1, 1)
    if not eastPerPercent or not southPerPercent then
        self.contextReason = "noZoneDimensions"
        return
    end

    local signature = SceneSignature(areaId, unitIds)
    if signature ~= self.sceneSignature or not self.scene then
        local built, buildWhy = self:BuildScene(areaId, unitIds, signature)
        if not built then
            self.contextReason = buildWhy or "noScene"
            return
        end
    end

    local playerU, playerV = Client.GetPlayerMapPosition("player")
    if not playerU then
        self.contextReason = "playerNotOnView"
        return
    end
    local target, targetWhy = self:FindNearestSpawn(playerU, playerV,
        eastPerPercent, southPerPercent)
    if not target then
        self.contextReason = targetWhy or "noTarget"
        return
    end

    if not self:GetFrame() then
        self.contextReason = "noMobNavigatorFrame"
        return
    end

    self.contextReason = nil
    self.context = {
        areaId = areaId,
        targetX = target.x,
        targetY = target.y,
        unitId = target.sourceId,
        name = target.name,
    }
end

-- The exact spawn the arrow is currently aiming at, or nil. Read by
-- Map/NpcPins.lua on every draw to put its ring around the matching pin;
-- returning the raw point rather than pushing a notification keeps the two
-- surfaces from having to agree about ordering, and costs one table read.
--
-- Gated on `shown` rather than on the context alone, so the map never marks a
-- point the player has no arrow for -- a stale ring around one spawn out of a
-- field of them is worse than no ring.
function MobNavigator:GetTarget()
    if not self.shown then
        return nil
    end
    local context = self.context
    if not context then
        return nil
    end
    return context.areaId, context.targetX, context.targetY, context.unitId,
        context.name
end

-- The fast half ---------------------------------------------------------------

local function DirectionAlpha(frameIndex)
    if type(frameIndex) ~= "number" then
        return ALPHA_ALIGNED
    end
    local frameCount = Client.NAVIGATOR_ARROW_FRAMES
    local halfTurn = frameCount / 2
    local stepDistance = frameIndex
    if stepDistance > halfTurn then
        stepDistance = frameCount - stepDistance
    end
    if stepDistance < 0 then
        stepDistance = 0
    elseif stepDistance > halfTurn then
        stepDistance = halfTurn
    end
    return ALPHA_ALIGNED
        - (ALPHA_ALIGNED - ALPHA_OPPOSITE) * stepDistance / halfTurn
end

function MobNavigator:RefreshArrow()
    local context = self.context
    if not context then
        return self:Hide(self.contextReason or "noContext")
    end

    local heading = PlayerHeading()
    if not heading then
        return self:Hide("noPlayerHeading")
    end

    local playerU, playerV = Client.GetPlayerMapPosition("player")
    heading:Sample(context.areaId, playerU, playerV)
    if not playerU then
        return self:Hide("playerNotOnView")
    end

    local questTarget = QuestTarget()
    if not questTarget then
        return self:Hide("noQuestTarget")
    end
    local eastYards, southYards = questTarget:ToYards(context.areaId,
        context.targetX - playerU * 100, context.targetY - playerV * 100)
    if not eastYards or not southYards then
        return self:Hide("noZoneDimensions")
    end

    local distanceYards = math.sqrt(eastYards * eastYards + southYards * southYards)
    local bearing = heading.BearingFromYards(eastYards, southYards)
    local facing, facingSource = heading:Get()
    if not facing then
        return self:Hide("noFacing")
    end

    local frame = self:GetFrame()
    if not frame then
        return self:Hide("noMobNavigatorFrame")
    end

    local config = Config()
    local alpha = ALPHA_ALIGNED

    if bearing then
        -- Positive means the target is to the player's LEFT, and a positive
        -- angle turns the texture counter-clockwise, so this goes straight in.
        local relative = heading.NormalizeDelta(bearing - facing)
        if not relative then
            return self:Hide("badAngle")
        end
        if Client.RotateNavigatorArrow(frame, relative + ROTATION_OFFSET) then
            self.rotations = self.rotations + 1
            alpha = DirectionAlpha(frame.unrealQuestArrowFrame)
        else
            self.rotationFailures = self.rotationFailures + 1
            return self:Hide("rotationFailed")
        end
        Client.ShowNavigatorArrow(frame, true)
        self.lastRelativeAngle = relative
    else
        -- Standing on the spawn point. With this client's one-yard position
        -- quantization a bearing taken from under a yard of displacement is
        -- noise, so the arrow goes rather than spinning on it.
        Client.ShowNavigatorArrow(frame, false)
        self.lastRelativeAngle = nil
    end

    -- The accent gold Map/NpcPins.lua already gives a tracked-mob pin, so the
    -- two dials are told apart by colour before either number is read.
    local accent = UQ.colors.accent
    Client.SetNavigatorArrowTint(frame, accent[1], accent[2], accent[3], alpha)
    Client.SetNavigatorDistanceText(frame, UQ.L("NAV_DISTANCE",
        math.floor(distanceYards + 0.5)))
    Client.SetNavigatorTitleText(frame,
        type(context.name) == "string" and context.name or "")

    if frame.unrealQuestArc then
        local showArc = not config or config:Get("mobNavigatorShowArc") ~= false
        if showArc then
            Client.ShowObject(frame.unrealQuestArc)
            Client.SetNavigatorArcAlpha(frame,
                bearing and ARC_ALPHA or ARC_ALPHA_AT_TARGET)
        else
            Client.HideObject(frame.unrealQuestArc)
        end
    end

    -- StartMoving owns the anchor while the mouse is down. Reapplying the
    -- stored point at 20Hz would pin the frame under the cursor and make a
    -- correctly wired drag look broken.
    if not self.dragging then
        local offsetX, offsetY, scale, point, relativePoint = self:Placement()
        if Client.PositionNavigator(frame, offsetX, offsetY, scale,
            point, relativePoint) then
            self.placements = self.placements + 1
            self.shown = true
            self.hiddenReason = nil
        else
            self.placementFailures = self.placementFailures + 1
            return self:Hide("placementFailed")
        end
    end

    self.lastDistanceYards = distanceYards
    self.lastFacingSource = facingSource
    self.lastTargetName = context.name
end

function MobNavigator:Placement()
    local config = Config()
    local offsetX = config and config:Get("mobNavigatorX")
    local offsetY = config and config:Get("mobNavigatorY")
    local scale = config and config:Get("mobNavigatorScale")
    local point = config and config:Get("mobNavigatorPoint")
    local relativePoint = config and config:Get("mobNavigatorRelativePoint")
    if type(offsetX) ~= "number" or offsetX < -2000 or offsetX > 2000 then
        offsetX = -170
    end
    if type(offsetY) ~= "number" or offsetY < -2000 or offsetY > 2000 then
        offsetY = 150
    end
    if type(scale) ~= "number" or scale < 0.5 or scale > 2.5 then
        scale = 1
    end
    if type(point) ~= "string" then
        point = "TOP"
    end
    if type(relativePoint) ~= "string" then
        relativePoint = "CENTER"
    end
    return offsetX, offsetY, scale * BASE_RENDER_SCALE, point, relativePoint
end

-- One call that resolves everything and then draws. The single entry point for
-- the offline test and for `/uq mobnav`; the driver deliberately does not use
-- it, because the expensive half does not belong at 20Hz.
function MobNavigator:Refresh()
    self.sceneSignature = nil
    self:RefreshContext()
    self:RefreshArrow()
end

-- Reporting -------------------------------------------------------------------

function MobNavigator:GetReport()
    local config = Config()
    local pins = NpcPins()
    return {
        enabled = config and config:Get("mobNavigatorEnabled") ~= false or false,
        created = self.frame ~= nil,
        createFailed = self.createFailed,
        shown = self.shown,
        trackedMobs = pins and pins:GetTrackedMobCount() or 0,
        placements = self.placements,
        placementFailures = self.placementFailures,
        rotations = self.rotations,
        rotationFailures = self.rotationFailures,
        dragging = self.dragging,
        drags = self.drags,
        dragFailures = self.dragFailures,
        hiddenReason = self.hiddenReason,
        hiddenCounts = self.hiddenCounts,
        relativeAngle = self.lastRelativeAngle,
        distanceYards = self.lastDistanceYards,
        facingSource = self.lastFacingSource,
        targetName = self.lastTargetName,
        targetAreaId = self.context and self.context.areaId,
        targetX = self.context and self.context.targetX,
        targetY = self.context and self.context.targetY,
        targetUnitId = self.context and self.context.unitId,
        sceneBuilds = self.sceneBuilds,
        sceneSpawns = self.scene and self.scene.spawnCount or 0,
    }
end

-- Persists enough to diagnose an invisible dial from SavedVariables alone, the
-- same way navigatorDiagnostics does for the quest one: "placed but not drawn"
-- and "never placed" are different bugs and only the counters separate them.
function MobNavigator:RecordDiagnostics()
    local config = Config()
    if not config then
        return
    end
    config:SetSectionEntry("mobNavigatorDiagnostics", "placements", self.placements)
    config:SetSectionEntry("mobNavigatorDiagnostics", "placementFailures",
        self.placementFailures)
    config:SetSectionEntry("mobNavigatorDiagnostics", "rotations", self.rotations)
    config:SetSectionEntry("mobNavigatorDiagnostics", "rotationFailures",
        self.rotationFailures)
    config:SetSectionEntry("mobNavigatorDiagnostics", "drags", self.drags)
    config:SetSectionEntry("mobNavigatorDiagnostics", "dragFailures",
        self.dragFailures)
    config:SetSectionEntry("mobNavigatorDiagnostics", "shown", self.shown and 1 or 0)
    config:SetSectionEntry("mobNavigatorDiagnostics", "createFailed",
        self.createFailed and 1 or 0)
    config:SetSectionEntry("mobNavigatorDiagnostics", "hiddenReason",
        tostring(self.hiddenReason or "none"))
    config:SetSectionEntry("mobNavigatorDiagnostics", "targetName",
        tostring(self.lastTargetName or "none"))
    config:SetSectionEntry("mobNavigatorDiagnostics", "sceneBuilds", self.sceneBuilds)
    config:SetSectionEntry("mobNavigatorDiagnostics", "sceneSpawns",
        self.scene and self.scene.spawnCount or 0)
end

-- Lifecycle -------------------------------------------------------------------

function MobNavigator:OnInit()
    if not UQ:IsFeatureEnabled("mobNavigator") then
        return
    end
    UQ:DeclareCapability("mobNavigatorDial", "unverified",
        "the tracked-creature arc and arrow, built from the same name-parameterized "
        .. "Client.CreateNavigator widget and the same 64-cell pre-rotated atlas as the quest "
        .. "navigator. Its construction inherits that layer's evidence; the second instance, its "
        .. "caption and its independent drag anchor have not yet been confirmed in game")
end

function MobNavigator:OnEnable()
    if not UQ:IsFeatureEnabled("mobNavigator") then
        -- Without this the driver would run mobnav.arrow at 20Hz forever for a
        -- widget that is never shown. Nothing else creates the frame either:
        -- GetFrame is lazy and is only reached from the jobs below.
        return
    end

    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end

    local config = Config()
    local interval = config and config:Get("mobNavigatorInterval")
    if type(interval) ~= "number" or interval < 0.02 or interval > 1 then
        interval = 0.05
    end

    driver:Schedule("mobnav.context", 0.25, function()
        local buildsBefore = MobNavigator.sceneBuilds
        MobNavigator:RefreshContext()
        driver:Label("mobnav.context",
            MobNavigator.sceneBuilds > buildsBefore and "rebuild" or "select")
    end)

    driver:Schedule("mobnav.arrow", interval, function()
        MobNavigator:RefreshArrow()
    end)

    driver:Schedule("mobnav.diagnostics", 5, function()
        MobNavigator:RecordDiagnostics()
    end)
end
