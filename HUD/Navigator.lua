--[[
UnrealQuest / HUD/Navigator.lua

The quest navigator: a fixed arc whose top ornament means "straight ahead", and
an arrow rotating about the same pivot to point at the nearest active node of
the followed quest. With no manual choice, following stays automatic and moves
to whichever quest owns the nearest drawable node in the current zone.

## What it answers, and the one thing it deliberately refuses to say

It answers exactly one question: **which way do I turn to reach the next node
of the quest I am following?**

It is not a compass. The arc is never labelled N/E/S/W, never rotates, and
never encodes world orientation. Its top-centre ornament is the player's own
forward direction, so the arrow's angle is read directly as "turn this far
left" or "turn this far right", with no mental step through north. Mixing a
forward reference and a north reference in one widget would make both harder to
read than either alone, so this one does not.

## Why this shape and not a projected world marker

The marker this replaced (HUD/Waypoint.lua, gated off behind `hudWorldMarker`)
projected the target onto the screen. Half of that projection is buildable here
and half is not, and the missing half cannot be fixed by trying harder:

  * the horizontal half works. It needs a bearing and a facing, and
    `GetPlayerFacing` supplies the second since the 2026-08-28 client update.
  * the vertical half is impossible for TWO independent reasons. There is no
    camera pitch, position or FOV getter -- the whole documented Camera
    category is setters, and every camera mover in the `Azeroth` category is
    marked protected. And the bundled world data carries no elevation at all:
    `units[id].coords` entries are `{x%, y%, areaId, respawn}`. So even a
    complete camera API would have no target Z to project, and importing Z
    would still leave no PLAYER Z to subtract it from.

A marker correct horizontally and pinned to an arbitrary horizon band
vertically reads as broken rather than as partial. A bearing relative to the
player is the whole of what this client can honestly support, so that is what
this draws -- the same reason pfQuest's TomTom-derived arrow works well here
while a world marker does not. Its arrow consumes exactly one number too:
`atan2` of the x/y delta, minus the facing.

## The rotation

There is no `Texture:SetRotation` here; the documented Texture surface is
GetTexture, SetBlendMode, SetDesaturated, SetGradientAlpha, SetTexCoord and
SetTexture. The documented eight-argument `SetTexCoord` call was tried first.
The client accepted it, but the 2026-09-01 live visual test showed the arrow
distorting instead of turning rigidly. Call success was not visual support.

The navigator therefore uses the same proven technique as pfQuest's
TomTom-derived arrow: pre-rotated frames selected with ordinary four-argument
`SetTexCoord`. `media/NavigationArrowFrames0.tga` through `Frames3.tga` hold 64
frames across four 4x4 atlases generated from the authored PNG by
`tools/make_navigator_textures.py`. Each 128x128 cell is a 5.625-degree step,
square, and sampled wholly inside 0..1. The atlases are RLE TGA type 10,
matching pfQuest's working 512x512 atlas: the live client drew the 1 MiB
uncompressed type-2 build as diagonal corruption. Their distinct filenames are
also required because decoded textures stay cached across `/reload`.

## Angle convention

`PlayerHeading:Get` and `BearingFromYards` both work in this addon's
convention: radians, 0 = north, increasing towards west. Their difference,
normalized into (-pi, pi], is positive when the target is to the player's LEFT.
The atlas frames increase counter-clockwise, so the relative angle is handed
straight to `Client.SetNavigatorArrowAngle` with no sign flip.
`ROTATION_OFFSET` exists for art whose rest orientation is not "up"; it is zero
for the shipped texture and is the one knob to reach for if the arrow is
consistently rotated by a constant.

## Two cadences

Same split, and the same reason, as the tracker and the retired marker.
`nav.context` at 4Hz chooses the nearest eligible node from a cached active-quest scene.
The shared map collector may walk hundreds of spawn locations, so that cache is
rebuilt immediately on quest changes and otherwise at most once a second.
`nav.arrow` at 20Hz does one position read, one facing read and one rotation,
which is the part that has to keep up with a turning player.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Navigator = UQ:NewModule("Navigator")

-- Added to the computed angle before the arrow is rotated. Zero for the
-- shipped art, which rests pointing straight up. This is the knob the design
-- brief anticipates: if the arrow is ever consistently off by a constant --
-- new art resting at another angle, say -- correct it here rather than by
-- negating the angle arithmetic, which is pinned by the offline test.
local ROTATION_OFFSET = 0

-- The authored layout was visually twice the desired HUD footprint. Keep its
-- internal geometry intact and scale the complete frame tree instead: the arc,
-- arrow and drag surface then all shrink by exactly the same factor.
local BASE_RENDER_SCALE = 0.5

-- Directional emphasis: the arrow is solid when the player is aligned with
-- the target and fades one increment per atlas step towards this alpha as the
-- target moves behind them. It never flashes; this sits in the middle of the
-- view for the length of a levelling session.
local ALPHA_ALIGNED = 1
local ALPHA_OPPOSITE = 0.45
local ARC_ALPHA = 0.65
local ARC_ALPHA_AT_TARGET = 0.35

-- The arc is 512x257; the arrow region is square. These are the authored
-- dimensions before BASE_RENDER_SCALE is applied.
local DIAL_WIDTH = 220
local ARROW_SIZE = 130

Navigator.frame = nil
Navigator.createFailed = false
Navigator.rotationSupported = nil
Navigator.shown = false
Navigator.context = nil
Navigator.contextReason = nil
Navigator.scene = nil
Navigator.sceneDirty = true
Navigator.sceneBuiltAt = nil
Navigator.sceneBuilds = 0
Navigator.hiddenReason = nil
Navigator.hiddenCounts = {}
Navigator.placements = 0
Navigator.placementFailures = 0
Navigator.rotations = 0
Navigator.rotationFailures = 0
Navigator.lastRelativeAngle = nil
Navigator.lastDistanceYards = nil
Navigator.lastFacingSource = nil
Navigator.lastTargetKind = nil
Navigator.lastTargetTitle = nil
Navigator.dragging = false
Navigator.drags = 0
Navigator.dragFailures = 0

local function Config()
    return UQ:GetModule("Config")
end

local function Database()
    return UQ:GetModule("Database")
end

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

local function WorldMapPins()
    return UQ:GetModule("WorldMapPins")
end

local function PlayerHeading()
    return UQ:GetModule("PlayerHeading")
end

-- Records why the navigator is not on screen. Counted rather than logged, the
-- same way the retired marker did it: at 20Hz a chat line is useless, but the
-- difference between "no quest followed", "quest is in another zone" and "this
-- client refused the rotation" has to survive to a /uq nav read-out.
function Navigator:Hide(reason)
    self.hiddenReason = reason
    if reason then
        self.hiddenCounts[reason] = (self.hiddenCounts[reason] or 0) + 1
    end
    if self.frame and self.shown then
        Client.HideObject(self.frame)
        self.shown = false
    end
end

function Navigator:GetFrame()
    if self.frame or self.createFailed then
        return self.frame
    end
    -- The widget name must never contain a hyphen: this client rewrites "-" in
    -- widget names into a filler string.
    self.frame = Client.CreateNavigator("UnrealQuestNavigator", DIAL_WIDTH,
        ARROW_SIZE)
    if not self.frame then
        self.createFailed = true
        UQ:Debug("navigator could not be created")
    elseif not Client.SetNavigatorDrag(self.frame, function()
        Navigator:StartDrag()
    end, function()
        Navigator:StopDrag()
    end) then
        UQ:Warn(UQ.L("NAV_WARN_NO_HANDLE"))
    end
    return self.frame
end

function Navigator:StartDrag()
    if not self.frame then
        return false
    end
    if not Client.StartFrameDrag(self.frame) then
        self.dragFailures = self.dragFailures + 1
        UQ:Warn(UQ.L("NAV_WARN_DRAG_FAILED"))
        return false
    end
    self.dragging = true
    self.drags = self.drags + 1
    return true
end

function Navigator:CapturePosition()
    local config = Config()
    if not self.frame or not config then
        return false
    end
    local point, relativeName, relativePoint, x, y =
        Client.GetFrameAnchor(self.frame)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        UQ:Warn(UQ.L("NAV_WARN_NO_POSITION"))
        return false
    end
    -- relativeName is deliberately not persisted. A live frame reference is
    -- not stable across reloads, so every saved anchor is reapplied against
    -- UIParent, exactly like the tracker and rare-alert positions.
    config:Set("navigatorPoint", point)
    config:Set("navigatorRelativePoint",
        type(relativePoint) == "string" and relativePoint or point)
    config:Set("navigatorX", x)
    config:Set("navigatorY", y)
    return true
end

function Navigator:StopDrag()
    if not self.frame then
        return false
    end
    Client.StopFrameDrag(self.frame)
    self.dragging = false
    return self:CapturePosition()
end

-- Whether this client accepts four-argument atlas selection. Asked once and
-- cached: an arrow frozen on one atlas cell is not a navigator worth drawing.
function Navigator:RotationSupported()
    if self.rotationSupported == nil then
        self.rotationSupported = Client.HasNavigatorAtlasRotation() and true or false
        if not self.rotationSupported then
            UQ:Debug("navigator disabled: this client refused atlas frame selection")
        end
    end
    return self.rotationSupported
end

-- The slow half ---------------------------------------------------------------

-- Considers one exact database coordinate for the route. The first candidate
-- wins an exact-distance tie, which makes the result follow quest-log and
-- location order instead of hash iteration order.
local function ConsiderTarget(best, point, quest, kind, complete,
    playerX, playerY, eastPerPercent, southPerPercent)
    if type(point) ~= "table" or type(point.x) ~= "number"
        or type(point.y) ~= "number" then
        return best
    end

    local east = (point.x - playerX) * eastPerPercent
    local south = (point.y - playerY) * southPerPercent
    local distanceSquared = east * east + south * south
    if best and distanceSquared >= best.distanceSquared then
        return best
    end

    return {
        x = point.x,
        y = point.y,
        distanceSquared = distanceSquared,
        complete = complete and true or false,
        kind = kind,
        quest = quest,
    }
end

-- Builds the same active-quest spatial scene the map and minimap use. Objective
-- location arrays stay grouped by quest instead of being copied into one large
-- flat list; the nearest-node pass can then run four times a second without
-- allocating one wrapper table per spawn.
function Navigator:BuildTargetScene(areaId)
    local database = Database()
    local questState = QuestState()
    local worldMap = WorldMapPins()
    if not database or not database.available or not questState or not worldMap then
        return false, "questSceneUnavailable"
    end

    local quests = questState:GetOrderedQuests()
    local config = Config()
    local groups = {}
    local nodeCount = 0
    local questIndex = 1
    local questTotal = table.getn(quests)
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        local complete = quest and quest.isComplete == 1
        local locations = worldMap:CollectQuestLocations(
            quest, areaId, complete, config)
        local locationTotal = table.getn(locations)
        if locationTotal > 0 then
            table.insert(groups, {
                quest = quest,
                complete = complete,
                locations = locations,
            })
            nodeCount = nodeCount + locationTotal
        end
        questIndex = questIndex + 1
    end

    local turnIns = worldMap:CollectTurnIns(database, quests, areaId, config)
    nodeCount = nodeCount + table.getn(turnIns)
    self.scene = {
        areaId = areaId,
        groups = groups,
        turnIns = turnIns,
        questCount = questTotal,
        nodeCount = nodeCount,
    }
    self.sceneDirty = false
    self.sceneBuiltAt = Client.Now()
    self.sceneBuilds = self.sceneBuilds + 1
    return true
end

-- Chooses the nearest exact node from the cached scene. Objectives are the
-- still-needed raw creature/object/trigger coordinates. A turn-in is eligible
-- only for a quest that is complete: showInProgressTurnIns may keep the future
-- ender visible on the maps, but routing there before the current objective is
-- done points the player away from the work still owed. This is intentionally
-- a node choice, not QuestTarget:SelectPrimary's stable densest-cluster choice:
-- the navigator now mirrors pfQuest's route behavior and may change target as
-- the player moves.
function Navigator:FindNearestTarget(areaId, playerU, playerV,
    eastPerPercent, southPerPercent, followingKey)
    local scene = self.scene
    if not scene or scene.areaId ~= areaId then
        return nil, "questSceneUnavailable"
    end
    if type(playerU) ~= "number" or type(playerV) ~= "number" then
        return nil, "playerNotOnView"
    end

    local playerX = playerU * 100
    local playerY = playerV * 100
    local best = nil

    local groupIndex = 1
    local groupTotal = table.getn(scene.groups)
    while groupIndex <= groupTotal do
        local group = scene.groups[groupIndex]
        local quest = group.quest
        local complete = group.complete
        local locations = group.locations
        if not followingKey or (quest and quest.titleKey == followingKey) then
            local locationIndex = 1
            local locationTotal = table.getn(locations)
            while locationIndex <= locationTotal do
                best = ConsiderTarget(best, locations[locationIndex], quest,
                    complete and "turnin" or "objective", complete,
                    playerX, playerY, eastPerPercent, southPerPercent)
                locationIndex = locationIndex + 1
            end
        end
        groupIndex = groupIndex + 1
    end

    -- Turn-ins are separate pins in the map scene. Completed quests may
    -- duplicate a coordinate collected above; strict-less tie handling keeps
    -- the earlier quest-owned candidate and changes nothing. Future turn-ins
    -- remain map context only: select a quest from a shared point only when
    -- that particular quest is complete (point.complete is an aggregate and
    -- can be true because a different quest at the same NPC is complete).
    local turnIns = scene.turnIns
    local turnInIndex = 1
    local turnInTotal = table.getn(turnIns)
    while turnInIndex <= turnInTotal do
        local point = turnIns[turnInIndex]
        local quest = nil
        local pointQuests = point and point.quests or {}
        local pointQuestIndex = 1
        local pointQuestTotal = table.getn(pointQuests)
        while pointQuestIndex <= pointQuestTotal and not quest do
            local candidate = pointQuests[pointQuestIndex]
            if candidate and candidate.isComplete == 1
                and (not followingKey or candidate.titleKey == followingKey) then
                quest = candidate
            end
            pointQuestIndex = pointQuestIndex + 1
        end
        if quest then
            best = ConsiderTarget(best, point, quest, "turnin", true,
                playerX, playerY,
                eastPerPercent, southPerPercent)
        end
        turnInIndex = turnInIndex + 1
    end

    if not best then
        if followingKey then
            return nil, "noFollowingQuestNodesInArea"
        end
        return nil, scene.questCount == 0 and "noQuests" or "noQuestNodesInArea"
    end
    return best
end

function Navigator:RefreshContext()
    self.context = nil

    local config = Config()
    if config and config:Get("navigatorEnabled") == false then
        self.contextReason = "disabledBySetting"
        return
    end
    if not self:RotationSupported() then
        self.contextReason = "noRotation"
        return
    end

    local mapContext = MapContext()
    if not mapContext then
        self.contextReason = "noMapContext"
        return
    end
    -- The same gate the map pins and the retired marker use: a uniquely
    -- resolved player area, and a view that can project the player. Sharing it
    -- is what keeps the arrow and the map's blue tiles agreeing about when a
    -- quest is locatable at all.
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

    -- Candidate collection is the expensive half. Rebuild immediately for a
    -- quest-model change or zone transition and at most once a second for bag
    -- and map-visibility changes; choosing the nearest cached coordinate still
    -- runs at the full 0.25s context cadence.
    local now = Client.Now()
    local sceneExpired = type(now) == "number" and type(self.sceneBuiltAt) == "number"
        and now >= self.sceneBuiltAt + 1
    if self.sceneDirty or not self.scene or self.scene.areaId ~= areaId
        or sceneExpired then
        local built, sceneWhy = self:BuildTargetScene(areaId)
        if not built then
            self.contextReason = sceneWhy or "questSceneUnavailable"
            return
        end
    end

    -- The target order depends on the player's position, unlike the old
    -- densest-component main-quest target. Re-evaluating at the 0.25s context
    -- cadence is responsive while keeping database collection out of the 20Hz
    -- arrow tick.
    local playerU, playerV = Client.GetPlayerMapPosition("player")
    if not playerU then
        self.contextReason = "playerNotOnView"
        return
    end
    local mainQuest = UQ:GetModule("MainQuest")
    local followingKey = mainQuest and mainQuest:Get() or nil
    local automatic = mainQuest and mainQuest:IsAutomatic() or false
    local targetFollowingKey = followingKey
    if automatic then
        targetFollowingKey = nil
    end
    local target, targetWhy = self:FindNearestTarget(areaId, playerU, playerV,
        eastPerPercent, southPerPercent, targetFollowingKey)
    if not target then
        self.contextReason = targetWhy or "noTarget"
        return
    end

    if not self:GetFrame() then
        self.contextReason = "noNavigatorFrame"
        return
    end

    -- A fresh character has no selection yet. The closest drawable node is
    -- the default, and becomes the same followed quest every other surface
    -- reads. Automatic following keeps evaluating the whole scene as the
    -- player moves; a click switches it to a manual selection and later passes
    -- filter to that quest alone.
    if not followingKey and target.quest and target.quest.titleKey and mainQuest then
        mainQuest:SetDefault(target.quest.titleKey)
        followingKey = target.quest.titleKey
    elseif automatic and target.quest and target.quest.titleKey and mainQuest then
        mainQuest:UpdateDefault(target.quest.titleKey)
        followingKey = target.quest.titleKey
    end

    self.contextReason = nil
    self.context = {
        areaId = areaId,
        targetX = target.x,
        targetY = target.y,
        complete = target.complete,
        targetKind = target.kind,
        targetTitle = target.quest and target.quest.title,
        targetTitleKey = target.quest and target.quest.titleKey,
    }
end

-- The fast half ---------------------------------------------------------------

-- A linear fade across the selected atlas steps. Cell 0 is straight ahead;
-- cell 32 is directly behind. Reading the chosen cell rather than the raw
-- angle keeps each opacity change synchronized with a visible arrow step.
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

function Navigator:RefreshArrow()
    local context = self.context
    if not context then
        return self:Hide(self.contextReason or "noContext")
    end

    local heading = PlayerHeading()
    if not heading then
        return self:Hide("noPlayerHeading")
    end

    -- Read fresh every tick and hand it to Sample rather than letting Sample
    -- read it again: this is the one input that genuinely changes between
    -- frames, and it costs a single guarded call.
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
        return self:Hide("noNavigatorFrame")
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
        -- Standing on the target. There is no direction left to point in, so
        -- the arrow goes rather than spinning on noise.
        Client.ShowNavigatorArrow(frame, false)
        self.lastRelativeAngle = nil
    end

    -- A quest ready to hand in still wears the turn-in colour the map already
    -- uses for that, rather than the accent gold.
    if context.complete then
        Client.SetNavigatorArrowTint(frame, 0.45, 1, 0.45, alpha)
    else
        Client.SetNavigatorArrowTint(frame, 1, 1, 1, alpha)
    end
    Client.SetNavigatorDistanceText(frame, UQ.L("NAV_DISTANCE",
        math.floor(distanceYards + 0.5)))

    if frame.unrealQuestArc then
        local showArc = not config or config:Get("navigatorShowArc") ~= false
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
    self.lastTargetKind = context.targetKind
    self.lastTargetTitle = context.targetTitle
end

function Navigator:Placement()
    local config = Config()
    local offsetX = config and config:Get("navigatorX")
    local offsetY = config and config:Get("navigatorY")
    local scale = config and config:Get("navigatorScale")
    local point = config and config:Get("navigatorPoint")
    local relativePoint = config and config:Get("navigatorRelativePoint")
    if type(offsetX) ~= "number" or offsetX < -2000 or offsetX > 2000 then
        offsetX = 0
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

-- One call that resolves everything and then draws. Kept as the single entry
-- point for the offline test and for /uq nav; the driver deliberately does not
-- use it, because the expensive half does not belong at 20Hz.
function Navigator:Refresh()
    self.sceneDirty = true
    self:RefreshContext()
    self:RefreshArrow()
end

-- `/uq nav` is also the visual debugger for the chosen raw node. Refresh the
-- slow context first so the map mark cannot describe a target from the
-- previous zone or an expired quest scene.
function Navigator:ShowDebugMapTarget()
    self:RefreshContext()
    local worldMap = WorldMapPins()
    if not worldMap then
        return false
    end
    local context = self.context
    if not context then
        worldMap:SetNavigatorDebugTarget(nil)
        return false
    end
    return worldMap:SetNavigatorDebugTarget(context.areaId,
        context.targetX, context.targetY, context.targetKind,
        context.targetTitle)
end

-- Reporting -------------------------------------------------------------------

function Navigator:GetReport()
    local config = Config()
    local worldMap = WorldMapPins()
    return {
        enabled = config and config:Get("navigatorEnabled") ~= false or false,
        rotationSupported = self.rotationSupported,
        created = self.frame ~= nil,
        createFailed = self.createFailed,
        shown = self.shown,
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
        targetKind = self.lastTargetKind,
        targetTitle = self.lastTargetTitle,
        targetAreaId = self.context and self.context.areaId,
        targetX = self.context and self.context.targetX,
        targetY = self.context and self.context.targetY,
        debugMapShown = worldMap and worldMap.navigatorDebugVisible or false,
        sceneBuilds = self.sceneBuilds,
        sceneNodes = self.scene and self.scene.nodeCount or 0,
    }
end

-- Persists enough to diagnose an invisible navigator from SavedVariables alone,
-- the same way mapDiagnostics does for the map layer: "rotated but not visible"
-- and "never placed" are different bugs and only the counters separate them.
function Navigator:RecordDiagnostics()
    local config = Config()
    if not config then
        return
    end
    config:SetSectionEntry("navigatorDiagnostics", "placements", self.placements)
    config:SetSectionEntry("navigatorDiagnostics", "placementFailures",
        self.placementFailures)
    config:SetSectionEntry("navigatorDiagnostics", "rotations", self.rotations)
    config:SetSectionEntry("navigatorDiagnostics", "rotationFailures",
        self.rotationFailures)
    config:SetSectionEntry("navigatorDiagnostics", "drags", self.drags)
    config:SetSectionEntry("navigatorDiagnostics", "dragFailures", self.dragFailures)
    config:SetSectionEntry("navigatorDiagnostics", "shown", self.shown and 1 or 0)
    config:SetSectionEntry("navigatorDiagnostics", "createFailed",
        self.createFailed and 1 or 0)
    config:SetSectionEntry("navigatorDiagnostics", "rotationSupported",
        self.rotationSupported and 1 or 0)
    config:SetSectionEntry("navigatorDiagnostics", "hiddenReason",
        tostring(self.hiddenReason or "none"))
    config:SetSectionEntry("navigatorDiagnostics", "targetKind",
        tostring(self.lastTargetKind or "none"))
    config:SetSectionEntry("navigatorDiagnostics", "targetTitle",
        tostring(self.lastTargetTitle or "none"))
    config:SetSectionEntry("navigatorDiagnostics", "sceneBuilds", self.sceneBuilds)
    config:SetSectionEntry("navigatorDiagnostics", "sceneNodes",
        self.scene and self.scene.nodeCount or 0)
end

-- Lifecycle -------------------------------------------------------------------

function Navigator:OnInit()
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        return
    end
    UQ:DeclareCapability("navigatorArrowRotation",
        Client.HasNavigatorAtlasRotation() and "unverified" or "missing",
        "the navigator's 64 pre-rotated frames across four high-resolution atlases, selected through four-argument SetTexCoord. "
        .. "That technique is proven on this client by pfQuest's TomTom-derived arrow, but this "
        .. "specific atlas remains unverified until its direction and visual stability are confirmed "
        .. "in game. `missing` means the navigator hides with reason noRotation")
end

function Navigator:OnEnable()
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        -- The expensive half of the disable: without this the driver would run
        -- nav.arrow at 20Hz forever for a widget that is never shown. Nothing
        -- else creates the frame either -- GetFrame is lazy and is only ever
        -- reached from the jobs scheduled below.
        return
    end

    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end

    local config = Config()
    local interval = config and config:Get("navigatorInterval")
    if type(interval) ~= "number" or interval < 0.02 or interval > 1 then
        interval = 0.05
    end

    -- Four times a second for the expensive half. The database nodes do not
    -- move, but which one is nearest changes with the player; this also notices
    -- quest, objective, zone, bag and map-visibility changes.
    driver:Schedule("nav.context", 0.25, function()
        Navigator:RefreshContext()
    end)

    -- Fast, because this has to keep up with a turning player: at 20Hz the
    -- arrow sweeps rather than steps.
    driver:Schedule("nav.arrow", interval, function()
        Navigator:RefreshArrow()
    end)

    driver:Schedule("nav.diagnostics", 5, function()
        Navigator:RecordDiagnostics()
    end)

    -- Quest additions, removals, completion and objective progress can all
    -- change the nearest node. Wake immediately when the model notices one;
    -- polling remains the correctness mechanism when no event fires.
    local questState = QuestState()
    if questState then
        questState:AddListener(function()
            Navigator.sceneDirty = true
            driver:Wake("nav.context")
            driver:Wake("nav.arrow")
        end)
    end


    -- Following changes alter the eligible target even when the quest scene
    -- itself did not change. Wake both halves immediately so the tracker and
    -- the arrow switch on the same interaction.
    local mainQuest = UQ:GetModule("MainQuest")
    if mainQuest then
        mainQuest:AddListener(function()
            driver:Wake("nav.context")
            driver:Wake("nav.arrow")
        end)
    end
end
