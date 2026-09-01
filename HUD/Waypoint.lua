--[[
UnrealQuest / HUD/Waypoint.lua

The world waypoint marker: one icon over the 3D world showing which way to walk
to reach the main quest, and how far it is.

## What this is, and what it deliberately is not

It is a **yaw projection of a world point onto the screen**. The target's
bearing is compared against the player's facing, and the difference is mapped
through the horizontal field of view onto a screen X offset, so the marker sits
over the point on the horizon where the target lies. Turn left and it slides
right; put the target behind you and it pins to the screen edge.

It is **not** a full 3D-to-2D projection, and it cannot become one on this
client. That needs the camera's yaw, pitch and field of view, and this client
publishes none: the entire documented Camera surface is setters (SetView,
SaveView, FlipCameraYaw, CameraZoomIn/Out), and a search of the whole
compatibility database for WorldToScreen returns nothing. See the
`cameraProjection` capability, which is declared "missing" precisely so this
does not get "fixed" later by reaching for an API that is not there.

## Where the facing comes from, and the one limit left

`GetPlayerFacing()` -- the character's rotation in radians, documented on the
updated client. This layer was gated off from 2026-08-22 to 2026-09-01 for the
want of exactly that call: the preceding build published no facing by any
route, so the marker could only be aimed from the direction the player was
*travelling*, which says nothing while they stand still and turn. HUD/PlayerHeading.lua
keeps that movement estimator as the fallback and reads the real facing first.
It also measures the client reading's angle convention against the estimator
rather than assuming it, because `GetPlayerFacing` is `documented`, not
`verified`, and a wrong zero axis would produce a marker that looks plausible
and points nowhere useful. That belongs there, not here: everything this file
receives from `PlayerHeading:Get` is already in the addon's convention.

The limit that remains is the camera, not the character. The marker is anchored
to where the **character** faces, and those agree whenever the camera sits
behind the character -- the normal case -- and drift apart while the player
holds right-mouse and looks around independently. There is no vertical
projection at all either: without camera pitch and target elevation the marker
can only sit on a fixed horizon band.

## Why the target is the map's own blue area

The point comes from Data/QuestTarget.lua, which is the same computation that
places the map's blue tiles -- not a second one. "Walk towards the blue area"
is the whole promise, so a separately derived centre that eventually disagreed
with the map would be a broken promise rather than a rounding difference.

## Why it hides more often than a Retail waypoint would

Both the map pins and this marker only work for direct coordinates in the
player's uniquely resolved current zone: child-area and continent transforms
are unmeasured on this client and Map/MapContext.lua refuses to guess them. On
top of that, GetPlayerMapPosition only projects the player while the world map
view is the player's own zone, so browsing the map to another zone takes the
player's position away with it. Every one of those exits is counted separately
in `hiddenReason`, and /uq waypoint prints the counts -- so "the marker never
appears" can be diagnosed without a screenshot.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Waypoint = UQ:NewModule("Waypoint")

-- Rendering ------------------------------------------------------------------

Waypoint.MARKER_SIZE = 28
-- Horizontal field of view used to map a yaw offset onto screen X. The client
-- exposes no camera FOV (see cameraProjection), so this is a setting rather
-- than a measurement; 100 degrees matches the wide default of this client's
-- presentation closely enough that the marker sits over its target, and
-- waypointFov trims it without a code change.
Waypoint.DEFAULT_FOV_DEGREES = 100
-- Fraction of half the screen width the marker is allowed to reach before it
-- is treated as off-screen and pinned. Keeps the icon fully on screen and
-- keeps tan() away from its asymptote.
Waypoint.EDGE_FRACTION = 0.92

Waypoint.frame = nil
Waypoint.shown = false
Waypoint.createFailed = false
Waypoint.placements = 0
Waypoint.placementFailures = 0
Waypoint.hiddenReason = nil
Waypoint.hiddenCounts = {}
Waypoint.lastDistanceYards = nil
Waypoint.lastRelativeAngle = nil
Waypoint.lastClamped = false
Waypoint.context = nil
Waypoint.contextReason = nil
Waypoint.lastLabelKey = nil
Waypoint.halfFov = nil
Waypoint.halfScreenWidth = nil
Waypoint.verticalOffset = nil

local RAD_PER_DEGREE = 0.017453292519943

local function Config()
    return UQ:GetModule("Config")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

local function GetPlayerHeading()
    return UQ:GetModule("PlayerHeading")
end

-- Records why the marker is not on screen. Counted rather than logged: the
-- distinction between "no main quest", "quest is in another zone" and "no
-- facing source" needs to survive to a /uq waypoint read-out, and a chat line
-- at 20Hz would not.
function Waypoint:Hide(reason)
    self.hiddenReason = reason
    if reason then
        self.hiddenCounts[reason] = (self.hiddenCounts[reason] or 0) + 1
    end
    if self.frame and self.shown then
        Client.HideObject(self.frame)
        self.shown = false
    end
end

function Waypoint:GetFrame()
    if self.frame or self.createFailed then
        return self.frame
    end
    -- The widget name must never contain a hyphen: this client rewrites "-" in
    -- widget names into a filler string.
    self.frame = Client.CreateWaypointMarker("UnrealQuestWaypointMarker", self.MARKER_SIZE)
    if not self.frame then
        self.createFailed = true
        UQ:Debug("waypoint marker could not be created")
    end
    return self.frame
end

-- Projection -----------------------------------------------------------------

-- Maps a yaw offset onto a screen X offset from the centre.
--
-- Positive `relative` means the target is to the player's LEFT (the angle
-- convention increases towards west, and west is left when facing north), so
-- the screen offset is its negation. Within the field of view the mapping is
-- the true perspective one, x = halfWidth * tan(angle) / tan(halfFov), which
-- is what makes the marker sit over its target rather than merely lean the
-- right way. Beyond it, or anywhere behind the player, the marker pins to the
-- edge -- tan() is worthless past a quarter turn and the target is not on
-- screen to sit over anyway.
--
-- Returns offsetX, clamped.
function Waypoint:ProjectToScreen(relative, halfWidth, halfFovRadians)
    local screenAngle = -relative
    local limit = halfWidth * self.EDGE_FRACTION

    if screenAngle >= halfFovRadians then
        return limit, true
    end
    if screenAngle <= -halfFovRadians then
        return -limit, true
    end

    local denominator = math.tan(halfFovRadians)
    if denominator == 0 then
        return 0, true
    end
    local offset = halfWidth * math.tan(screenAngle) / denominator
    if offset > limit then
        return limit, true
    end
    if offset < -limit then
        return -limit, true
    end
    return offset, false
end

local function FovRadians()
    local config = Config()
    local degrees = config and config:Get("waypointFov")
    if type(degrees) ~= "number" or degrees < 30 or degrees > 170 then
        degrees = Waypoint.DEFAULT_FOV_DEGREES
    end
    return degrees * RAD_PER_DEGREE * 0.5
end

local function VerticalOffset(screenHeight)
    local config = Config()
    local fraction = config and config:Get("waypointHeight")
    if type(fraction) ~= "number" or fraction < -0.5 or fraction > 0.5 then
        fraction = 0.18
    end
    return screenHeight * fraction
end

-- Formats the distance the way a player reads it, and carries the direction
-- hint in the same string rather than in a second texture. One texture with
-- two states is the idiom the map's "?" pin already uses, and it means there
-- is no second asset that can fail to load.
local function FormatLabel(distanceYards, clamped, offsetX, stale)
    local text
    if type(distanceYards) == "number" then
        if distanceYards >= 1000 then
            text = UQ.L("WAYPOINT_DISTANCE_KILOYARDS",
                string.format("%.1f", distanceYards / 1000))
        else
            -- Floored before formatting rather than handed to "%d" as a
            -- float. Vanilla's Lua tolerates that; newer ones raise "number
            -- has no integer representation", and the offline test runs on a
            -- newer one -- so this is the portable spelling as well as the
            -- correct rounding for a distance readout.
            text = UQ.L("WAYPOINT_DISTANCE_YARDS", tostring(math.floor(distanceYards)))
        end
    else
        text = ""
    end
    if clamped then
        if offsetX < 0 then
            text = "<< " .. text
        else
            text = text .. " >>"
        end
    end
    if stale and text ~= "" then
        text = text .. " ?"
    end
    return text
end

-- The refresh ----------------------------------------------------------------
--
-- Two jobs at two cadences, and the split is a performance requirement rather
-- than tidiness.
--
-- RefreshContext resolves the map view and the quest's target point. Both are
-- expensive: MapContext:Inspect allocates a report and makes about eight
-- guarded client calls, and QuestTarget:Resolve reduces up to 200 spawn
-- locations to cells and flood-fills them into components. Neither changes
-- between two frames -- only when the quest, the zone or the player's bags do.
--
-- RefreshMarker runs at the marker's own rate and does the cheap half: one
-- position read, one facing read, some arithmetic, one SetPoint. That is the
-- part that has to keep up with a turning player.
--
-- Doing the expensive half at 20Hz is precisely the per-tick burst of guarded
-- calls and allocations that docs/ARCHITECTURE.md records as having been
-- reported as visible stuttering on this client.

function Waypoint:RefreshContext()
    self.context = nil

    local config = Config()
    if config and not config:Get("waypointEnabled") then
        self.contextReason = "disabled"
        return
    end

    -- Cached here rather than read per tick: config lookups and client calls
    -- that cannot change between two frames.
    self.halfFov = FovRadians()
    local screenWidth, screenHeight = Client.GetScreenSize()
    if not screenWidth then
        self.contextReason = "noScreenSize"
        return
    end
    self.halfScreenWidth = screenWidth * 0.5
    self.verticalOffset = VerticalOffset(screenHeight)

    local mainQuest = MainQuest()
    if not mainQuest or not mainQuest:Get() then
        self.contextReason = "noMainQuest"
        return
    end
    local quest = mainQuest:GetQuest()
    if not quest then
        self.contextReason = "questNotInLog"
        return
    end
    if type(quest.questId) ~= "number" then
        self.contextReason = "questUnmatched"
        return
    end

    local mapContext = MapContext()
    if not mapContext then
        self.contextReason = "noMapContext"
        return
    end
    -- The same gate the map pins use: a uniquely resolved player area, and a
    -- view that can actually project the player. Sharing it is what keeps the
    -- marker and the blue tiles agreeing about when a quest is locatable.
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
    local target, targetWhy = questTarget:Resolve(quest, areaId)
    if not target then
        self.contextReason = targetWhy or "noTarget"
        return
    end

    -- The area has to carry recorded dimensions or neither the bearing nor the
    -- distance can be trusted. Refusing here rather than falling back to raw
    -- map percentages keeps a skewed arrow off the screen: percentages are not
    -- isotropic, so an angle taken from them is wrong by up to about 19
    -- degrees at the diagonals.
    if not questTarget:ToYards(areaId, 1, 1) then
        self.contextReason = "noZoneDimensions"
        return
    end

    self.contextReason = nil
    self.context = {
        areaId = areaId,
        targetX = target.x,
        targetY = target.y,
        complete = target.complete,
    }
end

function Waypoint:RefreshMarker()
    local context = self.context
    if not context then
        return self:Hide(self.contextReason or "noContext")
    end

    -- One module reference for the whole pass: BearingFromYards and
    -- NormalizeDelta are static helpers ON the module, so they need the module
    -- itself rather than the accessor.
    local heading = GetPlayerHeading()
    if not heading then
        return self:Hide("noPlayerHeading")
    end

    -- Read fresh every tick: this is the one input that genuinely changes
    -- between frames, and it costs a single guarded call. It is handed to
    -- Sample rather than letting Sample read it again.
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
    if not bearing then
        -- Standing on the target. Not an error, just nothing to point at.
        self.lastDistanceYards = distanceYards
        return self:Hide("atTarget")
    end

    local facing, facingSource, stale = heading:Get()
    if not facing then
        return self:Hide("noFacing")
    end

    local relative = heading.NormalizeDelta(bearing - facing)
    if not relative then
        return self:Hide("badAngle")
    end

    local offsetX, clamped = self:ProjectToScreen(
        relative, self.halfScreenWidth, self.halfFov)
    local offsetY = self.verticalOffset

    local frame = self:GetFrame()
    if not frame then
        return self:Hide("noMarkerFrame")
    end
    -- A quest ready to hand in points at its turn-in, so it wears the turn-in
    -- colour the map already uses for that: green rather than the accent.
    if context.complete then
        Client.SetWaypointColor(frame, 0.2, 1, 0.2)
    else
        Client.SetWaypointColor(frame, 1, 1, 1)
    end
    Client.SetWaypointAlpha(frame, clamped and 0.6 or 1)

    -- The label is rebuilt only when what it would say has changed. At 20Hz an
    -- unconditional rebuild allocates a string every tick for a readout that
    -- changes at walking pace.
    local labelKey = tostring(math.floor(distanceYards))
        .. (clamped and (offsetX < 0 and "L" or "R") or "-")
        .. (stale and "s" or "")
    if labelKey ~= self.lastLabelKey then
        self.lastLabelKey = labelKey
        Client.SetWaypointLabel(frame,
            FormatLabel(distanceYards, clamped, offsetX, stale))
    end

    if Client.PositionWaypointMarker(frame, offsetX, offsetY) then
        self.placements = self.placements + 1
        self.shown = true
        self.hiddenReason = nil
    else
        self.placementFailures = self.placementFailures + 1
        return self:Hide("placementFailed")
    end

    self.lastDistanceYards = distanceYards
    self.lastRelativeAngle = relative
    self.lastClamped = clamped
    self.lastFacingSource = facingSource
    self.lastTargetX = context.targetX
    self.lastTargetY = context.targetY
    self.lastAreaId = context.areaId
end

-- One call that resolves everything and then draws, at the cost of doing the
-- expensive half every time. Kept as the single entry point for the offline
-- test and for /uq waypoint; the driver deliberately does not use it.
function Waypoint:Refresh()
    self:RefreshContext()
    self:RefreshMarker()
end

-- Reporting ------------------------------------------------------------------

function Waypoint:GetReport()
    return {
        enabled = Config() and Config():Get("waypointEnabled") or false,
        created = self.frame ~= nil,
        createFailed = self.createFailed,
        shown = self.shown,
        placements = self.placements,
        placementFailures = self.placementFailures,
        hiddenReason = self.hiddenReason,
        hiddenCounts = self.hiddenCounts,
        distanceYards = self.lastDistanceYards,
        relativeAngle = self.lastRelativeAngle,
        clamped = self.lastClamped,
        facingSource = self.lastFacingSource,
        -- Built here rather than cached from RefreshMarker: it is a string, and
        -- building one per tick for a readout nobody reads until /uq waypoint
        -- runs is the allocation this file's two cadences exist to avoid.
        facingConvention = GetPlayerHeading()
            and GetPlayerHeading():ConventionLabel() or nil,
        targetX = self.lastTargetX,
        targetY = self.lastTargetY,
        areaId = self.lastAreaId,
    }
end

-- Persists enough to diagnose an invisible marker from SavedVariables alone,
-- the same way mapDiagnostics does for the map layer. Written on a slow job:
-- "placed but not visible" and "never placed" are different bugs and only the
-- counters separate them.
function Waypoint:RecordDiagnostics()
    local config = Config()
    if not config then
        return
    end
    config:SetSectionEntry("waypointDiagnostics", "placements", self.placements)
    config:SetSectionEntry("waypointDiagnostics", "placementFailures", self.placementFailures)
    config:SetSectionEntry("waypointDiagnostics", "shown", self.shown and 1 or 0)
    config:SetSectionEntry("waypointDiagnostics", "createFailed", self.createFailed and 1 or 0)
    config:SetSectionEntry("waypointDiagnostics", "hiddenReason",
        tostring(self.hiddenReason or "none"))
    config:SetSectionEntry("waypointDiagnostics", "facingSource",
        tostring(self.lastFacingSource or "none"))
    local headingModule = GetPlayerHeading()
    if headingModule then
        config:SetSectionEntry("waypointDiagnostics", "headingSamples", headingModule.samples)
        config:SetSectionEntry("waypointDiagnostics", "movementFixes", headingModule.movementFixes)
        -- Which convention the facing was read in, persisted alongside the
        -- placement counters: "the marker appears but points the wrong way"
        -- and "the marker never appears" are different bugs, and only this
        -- line separates the first from a projection error.
        config:SetSectionEntry("waypointDiagnostics", "facingConvention",
            tostring(headingModule:ConventionLabel()))
    end
end

-- Lifecycle ------------------------------------------------------------------

function Waypoint:OnEnable()
    -- Two gates, and the second one is why this layer is quiet today.
    -- `mainQuestWaypoint` owns the follow-one-quest layer as a whole and is on;
    -- `hudWorldMarker` owns this projected marker alone and is off, so the
    -- navigator can use the same main quest, target and facing without this
    -- also drawing. Both are checked because either being off means there is
    -- nothing here to schedule.
    if not UQ:IsFeatureEnabled("mainQuestWaypoint")
        or not UQ:IsFeatureEnabled("hudWorldMarker") then
        -- The expensive half of the disable. Without this the driver would run
        -- hud.waypoint at 20Hz forever -- reading the player position, sampling
        -- the heading and re-projecting -- for a marker that is never shown.
        -- Nothing else creates the marker frame either: GetFrame is lazy and is
        -- only ever reached from RefreshMarker, which is only ever reached from
        -- the job scheduled below.
        return
    end

    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end

    local config = Config()
    local interval = config and config:Get("waypointInterval")
    if type(interval) ~= "number" or interval < 0.02 or interval > 1 then
        interval = 0.05
    end

    -- Four times a second for the expensive half. A quest's target does not
    -- move, so this only has to notice that the quest, the zone or the bags
    -- changed.
    driver:Schedule("hud.waypointcontext", 0.25, function()
        Waypoint:RefreshContext()
    end)

    -- Fast, because this has to keep up with a turning player: at 20Hz the
    -- marker slides rather than steps.
    driver:Schedule("hud.waypoint", interval, function()
        Waypoint:RefreshMarker()
    end)

    driver:Schedule("hud.waypointdiagnostics", 5, function()
        Waypoint:RecordDiagnostics()
    end)

    -- A selection change should show the marker on the next tick, not up to
    -- one interval later. Same accelerator pattern the map layer uses.
    local mainQuest = MainQuest()
    if mainQuest then
        mainQuest:AddListener(function()
            -- A selection change invalidates the context, so wake that job:
            -- waking only the marker would redraw the previous target.
            driver:Wake("hud.waypointcontext")
            driver:Wake("hud.waypoint")
        end)
    end
end
