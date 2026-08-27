--[[
UnrealQuest / Map/WorldMapPins.lua

Quest areas and numbered markers on the native fullscreen map.

Scope is intentionally narrow and evidence-bounded:
  * active quests with either one resolved database match or the safe union of
    every still-possible same-title candidate;
  * only direct coordinates in the player's uniquely resolved current area;
  * only while GetPlayerMapPosition confirms that area is the selected view;
  * no child-area transforms, continent projection, minimap or waypoint arrow.

Nearby objective locations are merged into translucent blue areas; a completed
quest uses green. Area tiles are pooled and refreshed on the shared driver.

TWO PRESENTATIONS, ONE SCENE. The `mapObjectiveDots` setting decides which is
drawn, and it DEFAULTS TO THE DOTS: one dot per raw still-needed spawn point, in the
minimap's own style, so both map layers show the player the same shape. Turning
it off restores the areas above -- the same quests and hover tooltip, a region
instead of positions. Dots use stable per-quest colours; areas keep their
blue/in-progress and green/complete state colours. It is a presentation switch and nothing more: the same pooled frames
carry both shapes (see ApplyObjectiveStyle), so hovering, the turn-in link,
Ctrl+click flashing and /uq map's counters are identical either way, and no
other layer -- givers, turn-ins, the minimap, the waypoint -- can tell which
one is on screen.

One class of objective is deliberately conditional. Where a quest requires an
item to be *used* on a unit or object (Data/Database.lua, GetQuestItemUseTargets)
that target is left out of the objective pass entirely and added back only
while BagItems reports the item in the player's bags. Marla's Last Wish is the
case that forced it: its grave sat permanently on Deathknell from the moment
the quest was accepted, on top of the quest's own turn-in NPC, and read as a
second quest area for a step the player could not yet take.

Hovering a quest area shows that quest's own tooltip: title, level, status and
live objective progress read from the player's quest log. Confirmed working in
game on 2026-08-22, which is also what retired the numbered markers -- see
MARKER_RENDER_ENABLED below.

A second, separate pool marks quest GIVERS still worth visiting: one "!" per
giver with at least one quest that is neither in the player's quest log nor
recorded done in QuestHistory. This client has no completed-quest history API
at all (docs/CLIENT-COMPATIBILITY.md, "No quest ID API"), so "still to take"
can only ever be as good as what QuestHistory has personally observed or the
player has marked -- never a full account of the character's past. Hovering a
"!" shows the giver, its available quest(s) and a greyed hint; shift- or
Ctrl-clicking it marks a quest done.

When a visible "!" or "?" belongs to a moving NPC with bundled permanent patrol
data, a grey path shows every recorded patrol segment in the current zone. The
path remains while any marker for that NPC remains visible, including while
travelling back to hand a quest in. Object markers and stationary NPCs add no
path. Multi-zone patrols draw only their real in-zone segments, never a
shortcut across the map.

That path is one continuous stroke, but this client has no line widget of any
kind, so it is not a rotated segment -- it is a row of small opaque stamps
drawn dense enough to merge, on cheap Textures rather than pooled Buttons. A
Texture cannot take the mouse, so a pool of invisible Buttons is laid along the
same path underneath it: they are the route's hit test and the tooltip anchor's
geometry both, and they never paint.

WHICH quest is asked, not assumed. A "!" is per-giver and its tooltip lists
every quest that giver still offers, so on a pin carrying more than one the
click opens a picker naming each -- Client.ShowGiverQuestMenu, built from this
addon's own pooled Frame/Button primitives rather than the client's native
dropdown menu, which has no runtime record in the compatibility database at
all. Only a pin offering exactly one quest is marked directly. The bulk
"mark them all" that the click used to perform unconditionally is now a row
inside that picker, chosen rather than inferred.

The mouse scripts behind the click gestures are still unverified client
surface -- see capability worldMapPinInteraction, and giverHovers /
giverClicks in mapDiagnostics for telling a dead hit test apart from a dead
click.

A fourth pool answers the other half of that question: where a quest already
in the log gets handed in. One "?" per turn-in point -- one spawn coordinate
of one quest ender in this area -- carrying every active quest that ends
there, so two quests handed in to the same NPC share one marker instead of
stacking. An active quest uses the bundled ActiveQuestIcon; as soon as at least
one quest at that point is ready to hand in, the pin swaps to the bundled
CompleteQuestIcon. In-progress markers are opt-out through
showInProgressTurnIns.

Unlike the "!", a "?" has no click gesture at all. Turning a quest in needs
the NPC, and QuestHistory records the completion by itself when the quest
leaves the log while complete, so there is nothing for a click to correct.
The pins therefore register no click tokens and hover only.

Giver and turn-in pins are lifted above the area tiles on purpose. Every pool
is otherwise built at the same frame level, and the tile takes the mouse for
its own tooltip while having no OnClick, so an unraised "!" could have its
shift-click swallowed by the tile underneath it -- the 2026-08-22 report of
exactly that. The "!" is lifted higher than the "?" for the same reason: where
both land on one NPC, the tie has to go to the marker that owns a gesture.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local WorldMapPins = UQ:NewModule("WorldMapPins")

local MAX_MARKERS = 40
local REFRESH_INTERVAL = 0.25
-- Tile size is deliberately NOT a constant here: it must equal the cell size
-- Data/QuestTarget.lua reduces spawns to, and it is read from that module at
-- draw time so the two can never drift apart. Probe 1.31.0 showed overlapping
-- translucent tiles compounding into visibly darker bands and 1.32.0 confirmed
-- an edge-to-edge grid is uniform, so "tile size equals cell size" is a
-- measured requirement rather than a tidy coincidence.
local AREA_ALPHA = 0.5
local COMPLETE_AREA_ALPHA = 0.5
-- The main quest's tiles. Probe 1.29.0 confirmed 0.5 alpha visible on this
-- client and the first 0.2 run confirmed INVISIBLE, so this stays inside the
-- measured band rather than leaning on transparency to signal selection.
local MAIN_AREA_ALPHA = 0.5

-- The second objective presentation, chosen by the `mapObjectiveDots` setting.
--
-- The blue area above answers "somewhere in here". This answers "exactly
-- here", drawing one dot per raw spawn point in the same style the minimap
-- already uses -- Client.MINIMAP_OBJECTIVE_TEXTURE, tinted with the very same
-- colours the tiles are tinted with, so the two modes disagree about shape and
-- about nothing else.
--
-- They also share the pool. A dot is an areaPool frame with a different
-- texture and a fixed pixel size, which is what keeps the hover tooltip, the
-- turn-in link, /uq map's counters and Ctrl+click flashing working in both
-- modes without a second copy of any of it.
-- The 100% default is 10% smaller than the former fixed 10px dot. The same
-- 50-150% range as the minimap control scales it from this baseline.
local DEFAULT_DOT_SIZE = 9
local MIN_DOT_SCALE = 50
local MAX_DOT_SCALE = 150
local DEFAULT_DOT_SCALE = 100
local DOT_ALPHA = 1
-- Raw spawns are not reduced to cells. Neither an individual quest nor the
-- complete active scene is cropped: the objective pool grows to every
-- distinct coordinate it has to draw. Its frames use a named pool rather than
-- a numeric band, so growth cannot collide with any other map-pin pool.

local MAX_GIVER_MARKERS = 100
local MAX_GIVER_LOCATIONS = 200
-- Objective frames now own a named namespace. This numeric offset only has to
-- stay clear of the retired numbered quest markers and the other bounded
-- non-objective pools.
local GIVER_INDEX_OFFSET = 2000
-- How far a giver "!" is lifted above the area tiles it can overlap, so the
-- tile cannot win the click. Small on purpose: it only has to break a tie
-- between siblings, and the pins stay well inside the confirmed ">= 120"
-- rendering contract either way.
local GIVER_LEVEL_BOOST = 4

-- A patrol route draws as ONE thing -- the stroke below. What this pool is for
-- is the other half of it: the mouse.
--
-- A stroke is made of Textures, and a Texture cannot take the mouse, so the
-- route's hover -- the highlight, the reverse link to its "!" and "?", the
-- quest tooltip -- needs Buttons underneath it. These are those Buttons, laid
-- along the same path at a spacing close enough to their own size that their
-- hit boxes touch, and they draw NOTHING: the texture is created at alpha 0
-- once and never painted again. Their geometry is also what
-- ChoosePatrolTooltipAnchor reads to pick a tooltip side, so their spacing
-- still describes where the route is even though nothing here is visible.
local MAX_PATROL_HOVER_TARGETS = 500
local PATROL_HOVER_TARGET_SIZE = 8
local PATROL_HOVER_TARGET_SPACING = 1.15
-- A linked giver must outweigh the entire bounded route when the tooltip has
-- to choose which of the two to cover. If one side is free of both, the normal
-- dot scores still choose it; if not, preserving the "!" wins.
local PATROL_TOOLTIP_MARKER_WEIGHT = MAX_PATROL_HOVER_TARGETS * 20

-- The visible route: one continuous stroke over the same collected path the
-- hover targets above are laid along.
--
-- Why stamps and not a real line: see Client.CreateWorldMapStroke. This client
-- has no line widget, and its one rotated-texture form is documented but never
-- probed, so the line is opaque WHITE8X8 squares overlapping by more than half
-- their width. Spacing is derived from the stroke width in PIXELS rather than
-- from the route's own percentage units, so the overlap -- and therefore
-- whether the stamps actually merge -- is the same on every zone map.
-- The stamps only read as a line while they still touch, and the pool bound is
-- what can stop them: FitPatrolSpacing widens the spacing to fit the budget,
-- and past roughly 1600 length units of visible route that widening used to
-- push consecutive stamps apart and turn the stroke back into the beads it
-- replaced. So the width is not a constant here -- it is the floor. When the
-- budget forces the spacing wider than the stamps, the stamps grow with it up
-- to PATROL_LINE_MAX_WIDTH, which trades a slightly heavier line for one that
-- is still a line. Two axis-aligned squares of side w whose centres are d
-- apart overlap whenever d < w, and a diagonal run is more forgiving than
-- that, so matching the width to the spacing is sufficient in every direction.
local MAX_PATROL_STROKES = 2500
local PATROL_LINE_WIDTH = 3
local PATROL_LINE_MAX_WIDTH = 6
local PATROL_LINE_HOVER_BOOST = 2
local PATROL_LINE_OVERLAP = 0.4
local PATROL_LINE_RED = 0.78
local PATROL_LINE_GREEN = 0.78
local PATROL_LINE_BLUE = 0.78
local PATROL_LINE_ALPHA = 0.9
local PATROL_LINE_HOVER_RED = 0.98
local PATROL_LINE_HOVER_GREEN = 0.98
local PATROL_LINE_HOVER_BLUE = 0.98
local PATROL_LINE_HOVER_ALPHA = 1

local MAX_TURNIN_MARKERS = 100
-- Same collision reasoning as GIVER_INDEX_OFFSET, one band further out: the
-- giver pins own 2001..2100 under MAX_GIVER_MARKERS.
local TURNIN_INDEX_OFFSET = 3000
-- Above the tiles for the same hit-test reason as the "!", but deliberately
-- below it. An NPC that both hands out one quest and takes another draws both
-- markers on one coordinate, and the "!" is the one carrying a shift-click,
-- so it must win that tie rather than leave it to draw order.
local TURNIN_LEVEL_BOOST = 3
-- A quest ender is a named NPC, not a spawn cloud like the CLUCK! chicken, so
-- this bound is a guard against a pathological record rather than a routine
-- cap. Kept well under the complete objective-location path because turn-in
-- icons are a separate bounded non-objective surface.
local MAX_TURNIN_LOCATIONS_PER_QUEST = 8
-- media/ActiveQuestIcon.tga (the turn-in "?") is a 19x32 portrait image, not
-- the square the other pins' 14x14 contract assumes. Height keeps the
-- confirmed 14 and width is derived from the source's own aspect ratio, so
-- Client.SetWorldMapPinSize stops SetAllPoints from squashing the glyph into
-- a square.
local TURNIN_ICON_HEIGHT = 14
local TURNIN_ICON_WIDTH = TURNIN_ICON_HEIGHT * 19 / 32
-- media/icons/questIcon.tga is also 19x32. Keep the giver "!" at the
-- confirmed pin height without stretching its artwork into a square.
local GIVER_ICON_HEIGHT = 14
local GIVER_ICON_WIDTH = GIVER_ICON_HEIGHT * 19 / 32
-- Hovering one "!" or "?" grows it so the hovered marker reads as the one
-- under the mouse. Other markers keep their own size and opacity -- area
-- tiles are untouched too, they already have their own hover presentation.
local GIVER_TURNIN_HOVER_SCALE = 1.5
-- The grow answers quickly, then settles softly at full size. Returning to the
-- base size eases at both ends so an OnLeave does not look like a snap in the
-- opposite direction. Both animations run on the single shared driver and
-- unschedule themselves as soon as every marker reaches its target.
local MARKER_EMPHASIS_DURATION = 0.16
-- Two markers whose centres are closer together than this many pixels on the
-- canvas cannot be separated with the mouse, so hovering either one describes
-- both. Half the pins' own 14x14 width, deliberately: the criterion is icons
-- that actually collide -- centres inside each other's glyph -- not merely
-- icons that are near neighbours. A full pin width was tried first and swept
-- in markers a player can still pick apart, which made busy corners produce
-- tooltips carrying far more quests than the spot under the cursor holds.
local CLUSTER_RADIUS_PIXELS = 7
-- How many markers one tooltip will describe, the hovered one included. A busy
-- town corner can stack more quest text than fits on screen; past this the
-- tooltip reports how many it left out instead of running off the map.
local MAX_CLUSTER_ENTRIES = 4

-- Hovering anything that names a quest -- an objective dot or tile, or the "?"
-- where a quest is handed in -- fades every marker unrelated to that quest,
-- without hiding it: a player can still see the surrounding work and the map
-- stays readable. This stays comfortably above the alpha that made isolated
-- area probes vanish.
--
-- ONE idiom, deliberately. The "?" used to answer instead by lightening its
-- quest's tiles towards white, which read as a different quest rather than as
-- the same quest emphasised, and left two unrelated hover languages on one
-- map. It also had to be recomputed by a full rebuild, because area colour is
-- only assigned there -- re-collecting every quest's locations and re-placing
-- every frame in all five pools, once per hover.
local UNRELATED_MARKER_ALPHA = 0.3825
-- Runtime probes confirmed this exact presentation independently and then in
-- combination: file-backed blue tiles at 0.5 alpha, edge-to-edge without
-- overlap, plus one opaque numbered marker above the area.
local AREA_RENDER_ENABLED = true

-- The yellow numbered square above each area is retired. Once hovering an area
-- was confirmed in game to show the quest itself, the number was a second,
-- weaker identity for something the map already names on demand -- and unlike
-- the tooltip it sat permanently on top of the terrain it points at.
--
-- The marker construction stays in place rather than being deleted: it is the
-- confirmed recovery baseline in docs/WORLD-MAP-PINS-RECOVERY.md, the giver
-- "!" pins are built from the same constructor, and restoring the numbers --
-- with the hover behaviour that hides them again -- is this one flag.
local MARKER_RENDER_ENABLED = false

WorldMapPins.pool = {}
WorldMapPins.areaPool = {}
WorldMapPins.giverPool = {}
WorldMapPins.patrolPool = {}
-- The line presentation's stamps. Textures, not Buttons, so none of the
-- per-marker fields the pin pools rely on exist here -- the unit each stamp
-- belongs to, its resolved point and its focus state are kept in these
-- parallel tables instead, indexed the same way as the pool.
WorldMapPins.strokePool = {}
WorldMapPins.strokeUnitIds = {}
WorldMapPins.strokeX = {}
WorldMapPins.strokeY = {}
WorldMapPins.strokeFaded = {}
WorldMapPins.turnInPool = {}
WorldMapPins.renderEnabled = true
WorldMapPins.visibleCount = 0
WorldMapPins.areaVisibleCount = 0
WorldMapPins.giverVisibleCount = 0
WorldMapPins.patrolVisibleCount = 0
WorldMapPins.strokeVisibleCount = 0
-- The width the current scene's stamps were drawn at. Set by the draw pass
-- and read by everything that restyles or re-places a stamp afterwards, so a
-- hover or a canvas resize cannot silently reset a widened line back to the
-- floor and reopen the gaps.
WorldMapPins.strokeWidth = PATROL_LINE_WIDTH
WorldMapPins.turnInVisibleCount = 0
WorldMapPins.dirty = true
WorldMapPins.lastSignature = nil
WorldMapPins.canvasDetected = false
WorldMapPins.lastDiagnosticKey = nil
WorldMapPins.lastSnapshotKey = nil
WorldMapPins.hoverArea = nil
WorldMapPins.focusQuest = nil
WorldMapPins.focusTurnInPin = nil
WorldMapPins.hoverMarkerPin = nil
WorldMapPins.hoverPatrolMarker = nil
WorldMapPins.hoverPatrolTarget = nil
WorldMapPins.hoverCount = 0
WorldMapPins.lastHoverKey = nil
WorldMapPins.giverClickCount = 0
WorldMapPins.giverHoverCount = 0
WorldMapPins.turnInHoverCount = 0
WorldMapPins.rebuildCount = 0
WorldMapPins.itemUseUnknown = 0

local function Database()
    return UQ:GetModule("Database")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function QuestHistory()
    return UQ:GetModule("QuestHistory")
end

local function QuestEligibility()
    return UQ:GetModule("QuestEligibility")
end

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

local function BagItems()
    return UQ:GetModule("BagItems")
end

local function MinimapPins()
    return UQ:GetModule("MinimapPins")
end

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
        Client.HideObject(pool[index])
        index = index + 1
    end
    return first - 1
end

local function HideAllPools()
    WorldMapPins.visibleCount = HidePoolFrom(WorldMapPins.pool, 1)
    WorldMapPins.areaVisibleCount = HidePoolFrom(WorldMapPins.areaPool, 1)
    WorldMapPins.giverVisibleCount = HidePoolFrom(WorldMapPins.giverPool, 1)
    WorldMapPins.patrolVisibleCount = HidePoolFrom(WorldMapPins.patrolPool, 1)
    WorldMapPins.strokeVisibleCount = HidePoolFrom(WorldMapPins.strokePool, 1)
    WorldMapPins.turnInVisibleCount = HidePoolFrom(WorldMapPins.turnInPool, 1)
end

-- Stable-tick re-application ------------------------------------------------
--
-- Retaining every resolved position and re-applying it on stable driver ticks
-- is what forces the fullscreen map back through its draw path; it is the
-- measure that made the production overlay appear at all, and the client is
-- recorded as taking more than a second to settle its first draw after the map
-- opens. That is why the sweep cannot simply stop once everything is placed:
-- nothing here can tell when the map is being presented (WorldMapFrame and
-- WorldMapButton both report shown while it is closed), so the forcing has to
-- keep happening blind.
--
-- What it does not have to do is happen at full rate forever. After anything
-- that could have changed what is on the canvas the sweep runs on every tick
-- for SETTLE_SECONDS -- covering exactly the slow first draw above -- and then
-- drops to IDLE_REAPPLY_INTERVAL, which is still shorter than that measured
-- settle time. With a thousand objective dots on screen this is the difference
-- between re-anchoring the whole layer four times a second forever and doing
-- it once a second, and it is what the "map is laggy with many dots" report
-- was about.
local SETTLE_SECONDS = 3
local IDLE_REAPPLY_INTERVAL = 1

-- The bag token is part of the view because an item-use objective target is
-- drawn only while its item is carried: looting or consuming that item changes
-- what the map should show without anything about the quest log or the view
-- itself moving. The token only advances when the carried set's membership
-- changes, so an ordinary bag shuffle does not force a rebuild.
-- Whether objectives are drawn as dots rather than as blue areas. Read on
-- every refresh rather than latched at load: the options page writes the
-- setting straight to the config, and the view signature below carries the
-- answer so flipping it repaints on the next tick with nothing to notify.
local function ObjectiveDotsEnabled()
    local config = UQ:GetModule("Config")
    if not config then
        return false
    end
    return config:Get("mapObjectiveDots") and true or false
end

local function ObjectiveDotSize()
    local config = UQ:GetModule("Config")
    local scale = config and config:Get("mapObjectiveDotScale")
    if type(scale) ~= "number" then
        scale = DEFAULT_DOT_SCALE
    elseif scale < MIN_DOT_SCALE then
        scale = MIN_DOT_SCALE
    elseif scale > MAX_DOT_SCALE then
        scale = MAX_DOT_SCALE
    end
    return DEFAULT_DOT_SIZE * scale / 100
end

-- Whether one hover describes every marker whose icon collides with it. Read
-- per hover, like ObjectiveDotsEnabled above and for the same reason: the
-- options page writes straight to the config, and a tooltip is built fresh
-- every time, so flipping the setting takes effect on the next hover with
-- nothing here to notify.
local function ClusterTooltipsEnabled()
    local config = UQ:GetModule("Config")
    if not config then
        return true
    end
    return config:Get("mapClusterTooltips") and true or false
end

local function LowLevelQuestsEnabled(config)
    if not config then
        config = UQ:GetModule("Config")
    end
    return config and config:Get("showLowLevelQuests") and true or false
end

local function ViewSignature(areaId, report)
    local bagItems = BagItems()
    return tostring(areaId) .. "|" .. tostring(report and report.mapFile)
        .. "|" .. tostring(report and report.continent)
        .. "|" .. tostring(report and report.zoneIndex)
        .. "|" .. tostring(bagItems and bagItems:GetToken())
        -- The presentation is part of the view: switching between areas and
        -- dots changes every objective frame's texture, size and placement,
        -- and a signature that ignored it would leave the old shape on screen
        -- until something else happened to dirty the layer.
        .. "|" .. tostring(ObjectiveDotsEnabled())
        .. "|" .. tostring(ObjectiveDotSize())
        .. "|" .. tostring(LowLevelQuestsEnabled())
end

local function IsResolvedQuest(quest)
    return quest and type(quest.questId) == "number"
        and (quest.matchConfidence == "unique" or quest.matchConfidence == "levelDisambiguated"
            or quest.matchConfidence == "eligibilityDisambiguated"
            or quest.matchConfidence == "textDisambiguated"
            or quest.matchConfidence == "objectiveDisambiguated"
            or quest.matchConfidence == "textObjectiveDisambiguated")
end

-- Quests kept off the world map for every player by default: their objective
-- locations are a "spawn cloud" rather than a real place to go, so the tiles
-- are pure clutter rather than useful information. CLUCK! (3861) is the
-- canonical case -- see MAX_TURNIN_LOCATIONS_PER_QUEST above and the file
-- header -- and is the only entry until another quest is reported doing the
-- same thing.
local DEFAULT_HIDDEN_QUEST_IDS = {
    [3861] = true, -- CLUCK!
}

-- Whether questId's pins should be withheld this refresh: a per-player
-- /uq hide|unhide override in the "hiddenMapQuests" config section wins when
-- present (true hides, false forces a default-hidden quest back on screen);
-- otherwise DEFAULT_HIDDEN_QUEST_IDS decides.
local function IsQuestMapHidden(config, questId)
    if config then
        local section = config:GetSection("hiddenMapQuests")
        local override = section[questId]
        if override ~= nil then
            return override == true
        end
    end
    return DEFAULT_HIDDEN_QUEST_IDS[questId] == true
end

-- Database IDs whose locations are safe to draw for one live quest row.
--
-- A resolved row contributes its one ID. An honestly ambiguous row contributes
-- every same-title candidate instead: the map is allowed to over-show the
-- union of possible locations, but identity-sensitive consumers must keep
-- using IsResolvedQuest and must not pretend one of these IDs was proven.
-- This conservative fallback is specific to UnrealQuest. pfQuest's active
-- quest-log path takes the first best-scoring candidate; it is prior art for
-- text-token normalization, not for candidate-union map rendering.
local function GetQuestMapIds(quest)
    local ids = {}
    if IsResolvedQuest(quest) then
        table.insert(ids, quest.questId)
        return ids
    end
    if not quest or quest.matchConfidence ~= "ambiguous" then
        return ids
    end

    local candidates = quest.matchMapCandidates or quest.matchCandidates
    if type(candidates) ~= "table" then
        return ids
    end

    local seen = {}
    local index = 1
    local total = table.getn(candidates)
    while index <= total do
        local questId = candidates[index]
        if type(questId) == "number" and not seen[questId] then
            seen[questId] = true
            table.insert(ids, questId)
        end
        index = index + 1
    end
    return ids
end

-- Union and deduplicate the still-needed locations of every drawable
-- candidate. Ambiguity must not introduce a hidden per-row crop that a
-- resolved quest no longer has, while a finished live creature objective may
-- safely remove the matching source from every candidate's union.
local function CollectQuestMapLocations(quest, areaId, complete, config)
    local questTarget = QuestTarget()
    if not questTarget then
        return {}, 0, 0
    end
    local ids = GetQuestMapIds(quest)
    local locations = {}
    local seen = {}
    local unknown = 0
    local usedIds = 0
    local idIndex = 1
    local idTotal = table.getn(ids)
    while idIndex <= idTotal do
        local questId = ids[idIndex]
        if not IsQuestMapHidden(config, questId) then
            usedIds = usedIds + 1
            local candidate = {
                questId = questId,
                objectives = quest and quest.objectives,
                objectiveOwner = quest,
            }
            local found, withheld = questTarget:CollectLocations(candidate, areaId, complete)
            unknown = unknown + withheld
            local locationIndex = 1
            local locationTotal = table.getn(found)
            while locationIndex <= locationTotal do
                local location = found[locationIndex]
                local key = tostring(location.sourceType) .. ":" .. tostring(location.sourceId)
                    .. ":" .. tostring(location.x) .. ":" .. tostring(location.y)
                if not seen[key] then
                    seen[key] = true
                    table.insert(locations, location)
                end
                locationIndex = locationIndex + 1
            end
        end
        idIndex = idIndex + 1
    end
    return locations, unknown, usedIds
end

-- Read-only: callers must not mutate the returned table.
function WorldMapPins:GetDefaultHiddenQuestIds()
    return DEFAULT_HIDDEN_QUEST_IDS
end

function WorldMapPins:IsQuestHidden(questId, config)
    return IsQuestMapHidden(config, questId)
end

-- Quest IDs from one giver that this character could actually pick up now:
-- not already in the quest log, not recorded done, not excluded by the
-- quest's own race/class/level/event restrictions, no recorded prerequisite
-- currently active, and not map-hidden -- a quest withheld from the map
-- should never resurface as a giver "!" either,
-- e.g. CLUCK! offered again by a chicken once the quest has left the log.
-- Order is preserved so the tooltip and the bulk mark-done act on the same
-- list.
local function FilterAvailableQuestIds(questIds, activeQuestIds, questHistory, eligibility, config)
    local out = {}
    local lowLevelCount = 0
    local showLowLevel = LowLevelQuestsEnabled(config)
    local index = 1
    local total = table.getn(questIds)
    while index <= total do
        local questId = questIds[index]
        local lowLevel = eligibility and eligibility:IsLowLevel(questId)
        if type(questId) == "number" and (not lowLevel or showLowLevel)
            and not activeQuestIds[questId]
            and not (questHistory and questHistory:IsDone(questId))
            and not (eligibility
                and not eligibility:IsOfferable(questId, activeQuestIds, questHistory))
            and not IsQuestMapHidden(config, questId) then
            table.insert(out, questId)
            if lowLevel then
                lowLevelCount = lowLevelCount + 1
            end
        end
        index = index + 1
    end
    return out, table.getn(out) > 0 and lowLevelCount == table.getn(out)
end

-- Adds the targets of the quest's item-use steps to an objective location
-- list, but only the ones whose item is in the player's bags right now.
--
-- Database:GetQuestLocations deliberately leaves these out (see
-- GetQuestItemUseTargets there): "use Samuel's Remains on Marla's Grave" is not
-- a place to go until the remains exist, and drawing it from the moment the
-- quest is accepted put a permanent objective area over Deathknell -- on top
-- of the quest's own turn-in NPC, which is what it ended up looking like.
--
-- BagItems:Carries returns nil when the bags could not be read at all. That is
-- treated as "do not draw", the same as not carrying the item: the container
-- API is documented but not runtime-verified on this client, and a target the
-- addon cannot justify is one it does not place. The count of targets withheld
-- for an unreadable bag is reported through mapDiagnostics.itemUseUnknown so a
-- dead container API is diagnosable rather than silent.
local function ShowInProgressTurnIns()
    local config = UQ:GetModule("Config")
    if not config then
        return true
    end
    return config:Get("showInProgressTurnIns") and true or false
end

-- Turn-in points for the quests currently in the log, keyed so that one ender
-- spawn is one marker no matter how many quests end there.
--
-- The ender coordinates come from Database:GetQuestLocations with isComplete
-- forced true -- that argument selects the quest's `end` relation over `obj`,
-- which is precisely the turn-in relation, whatever the quest's live state.
-- Reusing it means the "?" needs no index of its own: the set being walked is
-- the player's own quest log, a handful of rows, not the 4433-quest database
-- the "!" has to be indexed out of ahead of time.
--
-- A point is "complete" when at least one quest handed in there can be handed
-- in now; that is what decides the marker's tint. Order follows quest-log
-- order rather than hash order, so the same map draws the same pins in the
-- same pool slots on every rebuild.
local function CollectTurnInPoints(database, quests, areaId, includeInProgress, config)
    local points = {}
    local ordered = {}
    local questIndex = 1
    local questTotal = table.getn(quests)
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        local complete = quest and quest.isComplete == 1
        if quest and (complete or includeInProgress) then
            local ids = GetQuestMapIds(quest)
            local idIndex = 1
            local idTotal = table.getn(ids)
            while idIndex <= idTotal do
                local questId = ids[idIndex]
                local locations = {}
                if not IsQuestMapHidden(config, questId) then
                    locations = database:GetQuestLocations(
                        questId, true, areaId, MAX_TURNIN_LOCATIONS_PER_QUEST)
                end
                local index = 1
                local total = table.getn(locations)
                while index <= total do
                    local location = locations[index]
                    local key = location.sourceType .. ":" .. tostring(location.sourceId)
                        .. ":" .. tostring(location.x) .. ":" .. tostring(location.y)
                    local point = points[key]
                    if not point then
                        point = {
                            x = location.x,
                            y = location.y,
                            areaId = areaId,
                            sourceType = location.sourceType,
                            sourceId = location.sourceId,
                            quests = {},
                            complete = false,
                        }
                        points[key] = point
                        table.insert(ordered, point)
                    end
                    local carriesQuest = false
                    local carriedIndex = 1
                    local carriedTotal = table.getn(point.quests)
                    while carriedIndex <= carriedTotal do
                        if point.quests[carriedIndex] == quest then
                            carriesQuest = true
                        end
                        carriedIndex = carriedIndex + 1
                    end
                    if not carriesQuest then
                        table.insert(point.quests, quest)
                    end
                    if complete then
                        point.complete = true
                    end
                    index = index + 1
                end
                idIndex = idIndex + 1
            end
        end
        questIndex = questIndex + 1
    end
    return ordered
end

-- True when a turn-in point carries the given quest among the (possibly
-- several) quests that end there.
local function PointHasQuest(point, wanted)
    if not point or not point.quests or not wanted then
        return false
    end
    local index = 1
    local total = table.getn(point.quests)
    while index <= total do
        local quest = point.quests[index]
        if type(wanted) == "table" and quest == wanted then
            return true
        end
        if type(wanted) == "number" and quest and quest.questId == wanted then
            return true
        end
        index = index + 1
    end
    return false
end

-- Unit identity shared by the two quest-marker pools. Patrol lifetime and
-- hover links follow rendered markers, so a giver "!" and a turn-in "?" for
-- the same moving NPC intentionally resolve to the same route owner.
local function MarkerUnitId(pin)
    if not pin then
        return nil
    end
    local giver = pin.unrealQuestGiver
    if giver and giver.sourceType == "unit" then
        return giver.sourceId
    end
    local point = pin.unrealQuestTurnIn
    if point and point.sourceType == "unit" then
        return point.sourceId
    end
    return nil
end

-- Mirrors the label/value layout of the client's own unit tooltips: a teal
-- title, then greyed labels with white values, then one block per offered
-- quest, and finally the greyed shift-click hint.
--
-- That hint was deliberately withheld while worldMapPinInteraction was
-- unverified, on the grounds that the addon should not advertise a gesture it
-- had never seen work. It is advertised now because the gesture is the only
-- way to mark a quest done by hand, and an unadvertised feature is
-- indistinguishable from a broken one -- which is exactly how it was reported.
-- The hint is worded as an instruction, not a promise about the client.
local function BuildGiverTooltipLines(database, giver, availableQuestIds, suppressHint)
    local lines = {}
    local name = giver.sourceType == "unit" and database:GetUnitName(giver.sourceId)
        or database:GetObjectName(giver.sourceId)
    table.insert(lines, { text = name or UQ.L("COMMON_UNKNOWN"), r = 0.3, g = 1, b = 0.8 })

    if giver.sourceType == "unit" then
        local unit = database:GetUnit(giver.sourceId)
        -- The bundled data stores unit levels as strings, and some are ranges
        -- ("5-8") rather than a single value, so the raw text is passed through
        -- instead of being coerced to a number.
        local level = unit and unit.lvl
        if level ~= nil and level ~= "" then
            table.insert(lines, { left = UQ.L("TOOLTIP_LEVEL"), right = tostring(level) })
        end
        table.insert(lines, { left = UQ.L("TOOLTIP_TYPE"), right = UQ.L("TOOLTIP_TYPE_UNIT") })
    else
        table.insert(lines, { left = UQ.L("TOOLTIP_TYPE"), right = UQ.L("TOOLTIP_TYPE_OBJECT") })
    end

    local index = 1
    local total = table.getn(availableQuestIds)
    while index <= total do
        local questId = availableQuestIds[index]
        local title = UQ.GetQuestDisplayTitle(questId)
        if title then
            if index > 1 then
                table.insert(lines, { separator = true })
            end
            table.insert(lines, { text = "[!] " .. title, r = 1, g = 0.82, b = 0 })
            local text = database:GetQuestText(questId)
            if text and type(text.O) == "string" and text.O ~= "" then
                table.insert(lines, { text = text.O, r = 1, g = 1, b = 1, wrap = true })
            end
            local record = database:GetQuest(questId)
            if record and (record.lvl ~= nil or record.min ~= nil) then
                table.insert(lines, {
                    left = "- " .. UQ.L("TOOLTIP_LEVEL") .. " " .. tostring(record.lvl or "?"),
                    right = UQ.L("TOOLTIP_REQUIRED") .. " " .. tostring(record.min or "?"),
                    r = 1, g = 0.82, b = 0,
                    rightR = 0.3, rightG = 1, rightB = 0.3,
                })
            end
        end
        index = index + 1
    end

    -- Greyed, on its own, last: the client's own tooltips put an interaction
    -- hint below the content it acts on, and grey keeps it from reading as
    -- another quest line. The wording tracks what the click will actually do
    -- on THIS pin -- promising a straight mark-done on a giver that is about
    -- to open a picker instead is how the gesture came to read as broken.
    if suppressHint then
        -- A neighbour's block inside a clustered tooltip. The gesture acts on
        -- whatever the cursor is actually over, so advertising it under a
        -- marker the player is not hovering would promise the wrong thing.
    elseif total > 1 then
        table.insert(lines, {
            text = UQ.L("MAP_HINT_SHIFT_CLICK_CHOOSE"),
            r = 0.5, g = 0.5, b = 0.5,
        })
    elseif total > 0 then
        table.insert(lines, {
            text = UQ.L("MAP_HINT_SHIFT_CLICK_MARK"),
            r = 0.5, g = 0.5, b = 0.5,
        })
    end

    return lines
end

-- The turn-in counterpart of BuildGiverTooltipLines, laid out identically so
-- the two markers read as one family: teal NPC title, greyed label/value
-- pairs, then one block per quest handed in here.
--
-- Objective progress is deliberately absent. The area tile covering this same
-- quest already carries it, in full, from the player's own quest log; this
-- tooltip answers "what can I hand in here", and a green "Ready to turn in"
-- against a grey "In progress" is the whole of that answer. There is no
-- shift-click hint either, because these pins take no clicks.
local function BuildTurnInTooltipLines(database, point)
    local lines = {}
    local name = point.sourceType == "unit" and database:GetUnitName(point.sourceId)
        or database:GetObjectName(point.sourceId)
    table.insert(lines, { text = name or UQ.L("COMMON_UNKNOWN"), r = 0.3, g = 1, b = 0.8 })

    if point.sourceType == "unit" then
        local unit = database:GetUnit(point.sourceId)
        -- Levels are strings in the bundled data, ranges included, so the raw
        -- text is passed through rather than coerced (see BuildGiverTooltipLines).
        local level = unit and unit.lvl
        if level ~= nil and level ~= "" then
            table.insert(lines, { left = UQ.L("TOOLTIP_LEVEL"), right = tostring(level) })
        end
        table.insert(lines, { left = UQ.L("TOOLTIP_TYPE"), right = UQ.L("TOOLTIP_TYPE_UNIT") })
    else
        table.insert(lines, { left = UQ.L("TOOLTIP_TYPE"), right = UQ.L("TOOLTIP_TYPE_OBJECT") })
    end
    table.insert(lines, { left = UQ.L("TOOLTIP_TURNS_IN"), right = tostring(table.getn(point.quests)) })

    local index = 1
    local total = table.getn(point.quests)
    while index <= total do
        local quest = point.quests[index]
        local title = UQ.GetQuestDisplayTitle(quest)
        if index > 1 then
            table.insert(lines, { separator = true })
        end
        if quest.isComplete == 1 then
            table.insert(lines, { text = "[?] " .. (title or UQ.L("COMMON_UNKNOWN")),
                r = 1, g = 0.82, b = 0 })
            table.insert(lines, {
                left = "- " .. UQ.L("TOOLTIP_STATUS"), right = UQ.L("QUEST_STATUS_READY_TO_TURN_IN"),
                rightR = 0.2, rightG = 1, rightB = 0.2,
            })
        else
            table.insert(lines, { text = "[?] " .. (title or UQ.L("COMMON_UNKNOWN")),
                r = 0.6, g = 0.6, b = 0.6 })
            table.insert(lines, {
                left = "- " .. UQ.L("TOOLTIP_STATUS"), right = UQ.L("QUEST_STATUS_IN_PROGRESS"),
                rightR = 1, rightG = 0.82, rightB = 0,
            })
        end
        index = index + 1
    end

    return lines
end

-- The quest-area counterpart of BuildGiverTooltipLines, deliberately laid out
-- the same way so both map surfaces read alike: coloured title, greyed
-- label/value pairs, then one line per objective.
--
-- Progress comes from the player's own quest log, which is the only
-- authoritative source for it; the bundled database is consulted only for the
-- objective prose, and only when the log reports no objective lines at all
-- (a "go and speak to" quest has none).
local function BuildQuestTooltipLines(database, quest)
    local lines = {}
    local title = UQ.GetQuestDisplayTitle(quest)
    table.insert(lines, { text = title or UQ.L("COMMON_UNKNOWN"), r = 1, g = 0.82, b = 0 })

    if type(quest.level) == "number" then
        local red, green, blue = Client.GetQuestLevelColor(quest.level)
        table.insert(lines, {
            left = UQ.L("TOOLTIP_LEVEL"), right = tostring(quest.level),
            rightR = red, rightG = green, rightB = blue,
        })
    end
    if type(quest.questTag) == "string" and quest.questTag ~= "" then
        table.insert(lines, { left = UQ.L("TOOLTIP_TYPE"), right = quest.questTag })
    end

    local complete = quest.isComplete == 1
    if complete then
        table.insert(lines, {
            left = UQ.L("TOOLTIP_STATUS"), right = UQ.L("QUEST_STATUS_READY_TO_TURN_IN"),
            rightR = 0.2, rightG = 1, rightB = 0.2,
        })
    else
        table.insert(lines, {
            left = UQ.L("TOOLTIP_STATUS"), right = UQ.L("QUEST_STATUS_IN_PROGRESS"),
            rightR = 1, rightG = 0.82, rightB = 0,
        })
    end

    local objectives = quest.objectives or {}
    local index = 1
    local total = table.getn(objectives)
    while index <= total do
        local objective = objectives[index]
        if objective and type(objective.text) == "string" and objective.text ~= "" then
            if objective.finished then
                table.insert(lines, { text = "- " .. objective.text, r = 0.2, g = 1, b = 0.2 })
            else
                table.insert(lines, { text = "- " .. objective.text, r = 1, g = 1, b = 1 })
            end
        end
        index = index + 1
    end

    if total == 0 and type(quest.questId) == "number" then
        local text = database:GetQuestText(quest.questId)
        if text and type(text.O) == "string" and text.O ~= "" then
            table.insert(lines, { text = text.O, r = 1, g = 1, b = 1, wrap = true })
        end
    end

    return lines
end

-- Persisted so that whether an area hover ever fires on this client can be
-- settled from SavedVariables instead of a screenshot: the compatibility
-- database still records "custom pin OnEnter produced no tooltip in game" as
-- a confirmed runtime failure, and an area tile is a far larger hit target
-- than the 14x14 pin that failure was measured on. Consecutive hovers of the
-- same quest are collapsed so moving across one area's tiles is one write.
local function RecordHover(quest)
    local key = tostring(quest.questId) .. "|" .. tostring(quest.title)
    if key == WorldMapPins.lastHoverKey then
        return
    end
    WorldMapPins.lastHoverKey = key
    WorldMapPins.hoverCount = (WorldMapPins.hoverCount or 0) + 1
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("mapDiagnostics", "areaHovers", WorldMapPins.hoverCount)
    config:SetSectionEntry("mapDiagnostics", "lastAreaHover", quest.title or "")
    config:SetSectionEntry("mapDiagnostics", "lastAreaHoverAt", Client.Now() or 0)
end

-- Counts every OnClick delivered to a giver "!" pin, shift held or not, so a
-- session of shift-clicking markers that never disappear can be told apart
-- from "the click never reached the addon" purely from SavedVariables --
-- worldMapPinInteraction is unverified precisely because that has never been
-- observed (docs/CLIENT-COMPATIBILITY.md, open question 9). Shift state is
-- recorded separately because a click reaching the addon without the shift
-- flag reading true would isolate a modifier-detection problem instead.
-- The discriminator for the open worldMapPinInteraction question. areaHovers
-- proves the mouse reaches a 2.5%-map tile, which says nothing about a 14x14
-- pin. Read against giverClicks:
--   both zero      -> the mouse never reaches a pin this small (hit test)
--   hovers only    -> the pin gets the mouse, the CLICK specifically is lost
--   both non-zero  -> interaction works; look at QuestHistory instead
local function RecordGiverHover()
    WorldMapPins.giverHoverCount = (WorldMapPins.giverHoverCount or 0) + 1
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("mapDiagnostics", "giverHovers", WorldMapPins.giverHoverCount)
end

-- The "?" pins take no clicks, so hovers are the only signal they produce.
-- Counted separately from giverHovers rather than folded into it: both pools
-- are 14x14 map-canvas children, but only this one is routinely drawn on top
-- of a green area tile, so "the tile keeps winning the mouse" and "a 14x14 pin
-- never gets the mouse" stay distinguishable from SavedVariables alone.
local function RecordTurnInHover()
    WorldMapPins.turnInHoverCount = (WorldMapPins.turnInHoverCount or 0) + 1
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("mapDiagnostics", "turnInHovers", WorldMapPins.turnInHoverCount)
end

local function RecordGiverClick(shiftHeld)
    WorldMapPins.giverClickCount = (WorldMapPins.giverClickCount or 0) + 1
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("mapDiagnostics", "giverClicks", WorldMapPins.giverClickCount)
    config:SetSectionEntry("mapDiagnostics", "lastGiverClickShift", shiftHeld and 1 or 0)
    config:SetSectionEntry("mapDiagnostics", "lastGiverClickAt", Client.Now() or 0)
end

-- The area-component reduction that used to live here now lives in
-- Data/QuestTarget.lua, unchanged. It moved so that the HUD waypoint marker
-- and these tiles cannot disagree about where a quest is: both call the same
-- BuildComponents/SelectPrimary over the same locations, rather than each
-- computing "the middle of the area" for itself.

local function RecordSnapshot(config)
    if not config then
        return
    end
    -- Samples whichever pool actually owns a child: with the numbered markers
    -- retired the area tiles are the only quest layer on the canvas, and a
    -- snapshot of an absent marker would report the map as empty.
    local snapshot = Client.GetWorldMapPinSnapshot(
        WorldMapPins.pool[1] or WorldMapPins.areaPool[1])
    local key = tostring(snapshot.canvasToken) .. "|" .. tostring(snapshot.parentToken)
        .. "|" .. tostring(snapshot.canvasShown) .. "|" .. tostring(snapshot.canvasVisible)
        .. "|" .. tostring(snapshot.pinShown) .. "|" .. tostring(snapshot.pinVisible)
        .. "|" .. tostring(snapshot.textureShown) .. "|" .. tostring(snapshot.textureVisible)
        .. "|" .. tostring(snapshot.canvasLeft) .. "|" .. tostring(snapshot.canvasTop)
        -- The sampled frame's own geometry is part of the key because the two
        -- objective presentations differ in exactly that: without it, the
        -- persisted pinWidth/pinHeight would still describe the shape the map
        -- was drawn in before the player switched modes.
        .. "|" .. tostring(snapshot.pinWidth) .. "|" .. tostring(snapshot.pinHeight)
    if key == WorldMapPins.lastSnapshotKey then
        return
    end
    WorldMapPins.lastSnapshotKey = key
    local field, value
    for field, value in pairs(snapshot) do
        if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
            config:SetSectionEntry("mapDiagnostics", field, value)
        end
    end
    config:SetSectionEntry("mapDiagnostics", "snapshotAt", Client.Now() or 0)
end

local function RecordDiagnostic(state, areaId, report, matchedQuests, candidates, failures)
    local visible = WorldMapPins.visibleCount or 0
    local areaVisible = WorldMapPins.areaVisibleCount or 0
    local key = tostring(state) .. "|" .. tostring(areaId) .. "|" .. tostring(visible)
        .. "|" .. tostring(areaVisible)
        .. "|" .. tostring(WorldMapPins.giverVisibleCount or 0)
        .. "|" .. tostring(WorldMapPins.turnInVisibleCount or 0)
        .. "|" .. tostring(matchedQuests or 0) .. "|" .. tostring(candidates or 0)
        .. "|" .. tostring(failures or 0)
        .. "|" .. tostring(WorldMapPins.itemUseUnknown or 0)
    if key == WorldMapPins.lastDiagnosticKey then
        return
    end
    WorldMapPins.lastDiagnosticKey = key
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("mapDiagnostics", "state", state)
    config:SetSectionEntry("mapDiagnostics", "areaId", areaId or 0)
    config:SetSectionEntry("mapDiagnostics", "mapFile", report and report.mapFile or "")
    config:SetSectionEntry("mapDiagnostics", "visiblePins", visible)
    config:SetSectionEntry("mapDiagnostics", "pooledPins", table.getn(WorldMapPins.pool))
    config:SetSectionEntry("mapDiagnostics", "visibleAreas", areaVisible)
    config:SetSectionEntry("mapDiagnostics", "pooledAreas", table.getn(WorldMapPins.areaPool))
    config:SetSectionEntry("mapDiagnostics", "visibleGivers", WorldMapPins.giverVisibleCount or 0)
    config:SetSectionEntry("mapDiagnostics", "pooledGivers", table.getn(WorldMapPins.giverPool))
    -- Same "placed but invisible" vs "never placed" discriminator the giver
    -- pins get, and the first thing to read if the map shows no "?" at all:
    -- a non-zero count with nothing on screen means the icon file did not
    -- resolve, not that the turn-in pass found nothing.
    config:SetSectionEntry("mapDiagnostics", "visibleTurnIns", WorldMapPins.turnInVisibleCount or 0)
    config:SetSectionEntry("mapDiagnostics", "pooledTurnIns", table.getn(WorldMapPins.turnInPool))
    -- Which tooltip frame the giver pins resolved to. "GameTooltip" here means
    -- WorldMapTooltip was absent, which is the first thing to check if hovering
    -- a "!" shows nothing on the fullscreen map.
    config:SetSectionEntry("mapDiagnostics", "mapTooltip", Client.GetMapTooltipName())
    config:SetSectionEntry("mapDiagnostics", "matchedQuests", matchedQuests or 0)
    config:SetSectionEntry("mapDiagnostics", "candidateLocations", candidates or 0)
    config:SetSectionEntry("mapDiagnostics", "pinFailures", failures or 0)
    -- Item-use targets left off the map because the bags were unreadable, not
    -- because the item is missing. This is the discriminator for "the grave
    -- never appears even though I am carrying the remains": non-zero here
    -- means the container API, and /uq status will show bagScan with it.
    config:SetSectionEntry("mapDiagnostics", "itemUseUnknown",
        WorldMapPins.itemUseUnknown or 0)
    config:SetSectionEntry("mapDiagnostics", "renderMode",
        AREA_RENDER_ENABLED and (MARKER_RENDER_ENABLED
                and "fileBackedAreasAndNumberedMarkersV1"
                or "fileBackedAreasHoverTooltipV1")
            or "componentMarkersBaselineAreaDisabled")
    -- Which of the two objective presentations the pool is currently painted
    -- with. Persisted alongside renderMode so a screenshot of "no blue area"
    -- can be told apart from "the area is drawn as dots".
    config:SetSectionEntry("mapDiagnostics", "objectiveStyle",
        ObjectiveDotsEnabled() and "dots" or "areas")
    config:SetSectionEntry("mapDiagnostics", "presentationTrace", "questAreaIsolationV1")
    RecordSnapshot(config)
    config:SetSectionEntry("mapDiagnostics", "recordedAt", Client.Now() or 0)
end

function WorldMapPins:GetPin(index)
    local pin = self.pool[index]
    if pin then
        return pin
    end
    pin = Client.CreateWorldMapPin(index, 1, 0.75, 0.1)
    if pin then
        self.pool[index] = pin
    end
    return pin
end

-- Area tiles carry the same once-per-frame mouse scripts as the giver pins,
-- attached at creation for the same reason (Core/Driver.lua records freshly
-- allocated per-tick closures as a measured stuttering hazard). The quest a
-- tile currently belongs to is refreshed as a plain field write below.
--
-- Making the tiles mouse-aware does mean they consume clicks that would
-- otherwise reach WorldMapButton. They are only ever drawn on a zone map,
-- never on a continent view, so the click they can swallow is the one the
-- stock UI does nothing with; zone-to-zone navigation is untouched.
function WorldMapPins:GetArea(index)
    local area = self.areaPool[index]
    if area then
        return area
    end
    area = Client.CreateWorldMapArea(
        index, 0.15, 0.55, 1, AREA_ALPHA, "Objective")
    if area then
        self.areaPool[index] = area
        area.unrealQuestPoolIndex = index
        Client.SetWorldMapPinHandlers(area,
            function() WorldMapPins:OnAreaEnter(area) end,
            function() WorldMapPins:OnAreaLeave(area) end,
            nil)
    end
    return area
end

-- Forces every visible marker in all five pools back through the map's draw
-- path, at the cadence described at SETTLE_SECONDS above. A canvas that
-- changed size forces a pass on its own: the placement is a fraction of the
-- canvas, so a resize invalidates every point at once.
function WorldMapPins:ReapplyVisiblePools()
    local now = Client.Now()
    local width, height = Client.GetWorldMapCanvasSize()
    local force = false
    local resized = false
    if width ~= self.lastCanvasWidth or height ~= self.lastCanvasHeight then
        self.lastCanvasWidth = width
        self.lastCanvasHeight = height
        force = true
        resized = true
    elseif not now then
        -- No clock: fall back to the unconditional every-tick sweep this
        -- replaced rather than to no sweep at all.
        force = true
    elseif self.settleUntil and now < self.settleUntil then
        force = true
    elseif not self.lastReapply or now - self.lastReapply >= IDLE_REAPPLY_INTERVAL then
        force = true
    end
    if not force then
        return
    end
    self.lastReapply = now
    Client.ReapplyWorldMapPins(self.pool, self.visibleCount)
    Client.ReapplyWorldMapPins(self.areaPool, self.areaVisibleCount)
    Client.ReapplyWorldMapPins(self.giverPool, self.giverVisibleCount)
    Client.ReapplyWorldMapPins(self.patrolPool, self.patrolVisibleCount)
    Client.ReapplyWorldMapPins(self.turnInPool, self.turnInVisibleCount)
    -- The stamps cost nothing here in the ordinary case: they hang off one
    -- layer frame, so re-anchoring and re-showing that frame carries all of
    -- them back through the map's draw path. Their own offsets are only
    -- invalidated by a canvas that changed size, and that is the one case
    -- that walks the pool.
    if self.strokeVisibleCount > 0 then
        Client.ReapplyWorldMapStrokeLayer()
        if resized then
            self:ReapplyPatrolStrokes()
        end
    end
end

-- Opens the full-rate window above. Called wherever the layer has just been
-- rewritten, so the slow first draw after the map opens is met with the same
-- every-tick forcing it always had.
function WorldMapPins:MarkSettling()
    local now = Client.Now()
    if now then
        self.settleUntil = now + SETTLE_SECONDS
    else
        self.settleUntil = nil
    end
end

-- A suppressed marker keeps its slot, its colour and its position and only
-- withholds its visibility, so restoring it is a re-apply of the point it
-- already holds rather than a fresh placement.
function WorldMapPins:SetMarkerSuppressed(pin, suppressed)
    if not pin then
        return
    end
    Client.SetWorldMapPinSuppressed(pin, suppressed)
    if not suppressed then
        Client.ReapplyWorldMapPin(pin)
    end
end

function WorldMapPins:OnAreaEnter(area)
    local database = Database()
    local quest = area and area.unrealQuestQuest
    if not database or not quest then
        return
    end
    self.hoverArea = area
    self:SetMarkerSuppressed(area.unrealQuestMarkerPin, true)
    self:ApplyQuestFocus(quest)
    Client.ShowMapTooltip(area, BuildQuestTooltipLines(database, quest))
    RecordHover(quest)
end

function WorldMapPins:OnAreaLeave(area)
    if not area then
        return
    end
    if self.hoverArea == area then
        self.hoverArea = nil
    end
    -- One quest's tiles sit edge to edge and share a single marker, and the
    -- client may deliver the next tile's OnEnter before this OnLeave. Restore
    -- the marker only when nothing is hovering it any more, otherwise sliding
    -- the mouse across an area would flicker the number back on.
    local hovered = self.hoverArea
    if not hovered or hovered.unrealQuestMarkerPin ~= area.unrealQuestMarkerPin then
        self:SetMarkerSuppressed(area.unrealQuestMarkerPin, false)
    end
    -- Same guard, for the same reason: the next tile's OnEnter may arrive
    -- before this OnLeave, and dropping the focus unconditionally would flash
    -- the whole layer back to full opacity between two cells of one quest.
    self:ApplyQuestFocus(hovered and hovered.unrealQuestQuest or nil)
    -- Guarded by the tooltip's own owner check, so this cannot pull a tooltip
    -- that a neighbouring tile has already taken over.
    Client.HideMapTooltip(area)
end

local function QuestHasMapId(quest, questId)
    if not quest or type(questId) ~= "number" then
        return false
    end
    local ids = GetQuestMapIds(quest)
    local index = 1
    local total = table.getn(ids)
    while index <= total do
        if ids[index] == questId then
            return true
        end
        index = index + 1
    end
    return false
end

local function GiverOffersQuest(pin, quest)
    local ids = pin and pin.unrealQuestAvailableQuestIds
    if type(ids) ~= "table" then
        return false
    end
    local index = 1
    local total = table.getn(ids)
    while index <= total do
        if QuestHasMapId(quest, ids[index]) then
            return true
        end
        index = index + 1
    end
    return false
end

-- Asked by unit id rather than by frame: the route on screen is made of
-- Textures, which carry no fields of their own, so the focus pass over it has
-- only the id from the parallel table to work with.
function WorldMapPins:IsPatrolUnitRelatedToQuest(unitId, quest)
    if unitId == nil or not quest then
        return false
    end
    local index = 1
    while index <= self.turnInVisibleCount do
        local pin = self.turnInPool[index]
        if MarkerUnitId(pin) == unitId and PointHasQuest(pin.unrealQuestTurnIn, quest) then
            return true
        end
        index = index + 1
    end
    return false
end

-- Fades every marker unrelated to the hovered quest, leaving its own at full
-- opacity: nothing is hidden, so the surrounding work stays visible and the
-- map stays readable. The frame alpha layers over the tiles' own measured
-- texture alpha rather than replacing it.
--
-- This is applied DIRECTLY to the already-visible pools, never through a
-- rebuild. That is the whole difference from the brightening highlight this
-- replaced: state that only a rebuild can express costs a full recompute of
-- every quest's locations per hover, and with a large objective pool that is
-- the most expensive thing the map can be asked to do. Frame alpha is per-frame
-- and immediate, so the pass is a plain walk -- and Client.SetWorldMapPinAlpha
-- drops the client call for every frame already carrying the value, which is
-- most of them on most hovers.
--
-- The quest guard makes the common gesture free: one quest's dots sit in a
-- cloud and its tiles sit edge to edge, so sliding the cursor across it fires
-- OnEnter per frame with the same quest. The guard is safe only because a
-- rebuild, which reassigns pooled frames to other quests, always clears the
-- focus below before anything can hold it.
-- The focused quest set, reused rather than reallocated: a focus change
-- happens on every hover that crosses to another quest, and Core/Driver.lua
-- records per-hover allocation churn as a measured stutter hazard here. Only
-- the first focusQuestCount entries are ever read, so stale tail entries left
-- by a wider previous focus are harmless.
local focusQuests = {}
local focusQuestCount = 0

local function SetFocusQuests(quest, point)
    if quest then
        focusQuests[1] = quest
        focusQuestCount = 1
        return
    end
    local total = 0
    if point and point.quests then
        total = table.getn(point.quests)
        local index = 1
        while index <= total do
            focusQuests[index] = point.quests[index]
            index = index + 1
        end
    end
    focusQuestCount = total
end

local function FocusHasQuest(quest)
    local index = 1
    while index <= focusQuestCount do
        if focusQuests[index] == quest then
            return true
        end
        index = index + 1
    end
    return false
end

local function FocusGiverOffers(pin)
    local index = 1
    while index <= focusQuestCount do
        if GiverOffersQuest(pin, focusQuests[index]) then
            return true
        end
        index = index + 1
    end
    return false
end

local function FocusTakesTurnIn(pin)
    local index = 1
    while index <= focusQuestCount do
        if PointHasQuest(pin.unrealQuestTurnIn, focusQuests[index]) then
            return true
        end
        index = index + 1
    end
    return false
end

-- ONE writer for the size and the opacity of the "!" and "?" markers.
--
-- Three gestures can claim a marker: hovering it, hovering the patrol route of
-- the NPC that owns it, and hovering an objective dot, an area tile or a "?"
-- of a quest that marker belongs to. Each of them used to walk the two pools
-- and stamp its own answer over whatever the other two had written, so the
-- result depended on the order the client delivered the scripts in -- an
-- OnLeave arriving after the next OnEnter shrank the marker the new hover had
-- just grown, and the hover passes' unconditional alpha 1 undid the focus dim.
-- None of them writes any more. Each records its own state and calls this,
-- which reads all three and applies the single answer they add up to.
function WorldMapPins:MarkerEmphasized(pin)
    if not pin then
        return false
    end
    if self.hoverMarkerPin == pin then
        return true
    end
    -- Only the ROUTE's own hover reaches its siblings. A hovered "!" also
    -- records a patrol unit (for the stroke), and reading that here would grow
    -- every other marker of the same NPC on a plain marker hover -- which the
    -- marker hover has never done and does not mean.
    local target = self.hoverPatrolTarget
    local unitId = target and target.unrealQuestPatrolUnitId
    if unitId ~= nil and MarkerUnitId(pin) == unitId then
        return true
    end
    -- The focus link, and the reason this pass exists: the quest under the
    -- cursor dims the rest of the map, and its own giver and turn-in grow to
    -- exactly the size a direct hover would give them, so the marker those
    -- dots belong to is found by looking rather than by reading every icon
    -- that was left lit.
    return FocusGiverOffers(pin) or FocusTakesTurnIn(pin)
end

-- Size is walked over the WHOLE pool, opacity only over the visible part.
-- A pooled marker that fell out of the last draw keeps its old point and its
-- old quests, so asking whether it is related would fade or grow a frame
-- nobody can see -- but it also keeps its old SIZE, and a grown one handed
-- back out by a later rebuild would come back oversized. Resetting size past
-- the visible range costs one call per spare frame and removes that case.
local function ClampUnit(value)
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function EaseOutCubic(progress)
    local inverse = 1 - ClampUnit(progress)
    return 1 - inverse * inverse * inverse
end

local function EaseInOutCubic(progress)
    progress = ClampUnit(progress)
    if progress < 0.5 then
        return 4 * progress * progress * progress
    end
    local inverse = -2 * progress + 2
    return 1 - inverse * inverse * inverse / 2
end

local function SetMarkerEmphasisScale(pin, scale)
    pin.unrealQuestEmphasisScale = scale
    Client.SetWorldMapPinSize(pin,
        pin.unrealQuestBaseWidth * scale,
        pin.unrealQuestBaseHeight * scale)
end

local function SetMarkerEmphasisTarget(pin, target, animate)
    local current = pin.unrealQuestEmphasisScale or 1
    if not animate then
        pin.unrealQuestEmphasisFrom = target
        pin.unrealQuestEmphasisTarget = target
        pin.unrealQuestEmphasisElapsed = 0
        if current ~= target then
            SetMarkerEmphasisScale(pin, target)
        end
        return false
    end
    if pin.unrealQuestEmphasisTarget ~= target then
        pin.unrealQuestEmphasisFrom = current
        pin.unrealQuestEmphasisTarget = target
        pin.unrealQuestEmphasisElapsed = 0
    end
    return current ~= target
end

local function ApplyMarkerEmphasis(pool, visible, Related)
    local focused = focusQuestCount > 0
    local animating = false
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        local pin = pool[index]
        if pin and pin.unrealQuestBaseWidth and pin.unrealQuestBaseHeight then
            local scale = 1
            if index <= visible and WorldMapPins:MarkerEmphasized(pin) then
                scale = GIVER_TURNIN_HOVER_SCALE
            end
            if SetMarkerEmphasisTarget(pin, scale, index <= visible) then
                animating = true
            end
            if index <= visible then
                Client.SetWorldMapPinAlpha(pin,
                    (not focused or Related(pin)) and 1 or UNRELATED_MARKER_ALPHA)
            end
        end
        index = index + 1
    end
    return animating
end

local function AnimateMarkerPool(pool, elapsed)
    local animating = false
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        local pin = pool[index]
        local current = pin and pin.unrealQuestEmphasisScale
        local target = pin and pin.unrealQuestEmphasisTarget
        if type(current) == "number" and type(target) == "number" and current ~= target then
            local from = pin.unrealQuestEmphasisFrom or current
            local animationElapsed = (pin.unrealQuestEmphasisElapsed or 0) + elapsed
            local progress = ClampUnit(animationElapsed / MARKER_EMPHASIS_DURATION)
            local eased
            if target > from then
                eased = EaseOutCubic(progress)
            else
                eased = EaseInOutCubic(progress)
            end
            pin.unrealQuestEmphasisElapsed = animationElapsed
            if progress >= 1 then
                SetMarkerEmphasisScale(pin, target)
            else
                SetMarkerEmphasisScale(pin, from + (target - from) * eased)
                animating = true
            end
        end
        index = index + 1
    end
    return animating
end

function WorldMapPins:AnimateMarkerEmphasis(elapsed)
    if type(elapsed) ~= "number" or elapsed < 0 then
        elapsed = 0
    end
    local giverAnimating = AnimateMarkerPool(self.giverPool, elapsed)
    local turnInAnimating = AnimateMarkerPool(self.turnInPool, elapsed)
    self.markerEmphasisAnimating = giverAnimating or turnInAnimating
    if not self.markerEmphasisAnimating then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("map.markeremphasis")
        end
    end
end

local function RunMarkerEmphasisAnimation(elapsed)
    WorldMapPins:AnimateMarkerEmphasis(elapsed)
end

function WorldMapPins:RefreshMarkerEmphasis()
    local giverAnimating = ApplyMarkerEmphasis(
        self.giverPool, self.giverVisibleCount, FocusGiverOffers)
    local turnInAnimating = ApplyMarkerEmphasis(
        self.turnInPool, self.turnInVisibleCount, FocusTakesTurnIn)
    self.markerEmphasisAnimating = giverAnimating or turnInAnimating
    local driver = UQ:GetModule("Driver")
    if not driver then
        -- With no timing source, preserve the interaction instead of leaving
        -- a marker stranded between its base and emphasized sizes.
        self:AnimateMarkerEmphasis(MARKER_EMPHASIS_DURATION)
    elseif self.markerEmphasisAnimating then
        driver:Schedule("map.markeremphasis", 0, RunMarkerEmphasisAnimation)
    else
        driver:Unschedule("map.markeremphasis")
    end
end

-- Declared here because ApplyFocus below has to fold the fade into the stamp
-- colour, and the stamp styling itself lives down with the rest of the patrol
-- drawing.
local SetPatrolStrokeStyle

local function FocusRunsPatrolUnit(unitId)
    local index = 1
    while index <= focusQuestCount do
        if WorldMapPins:IsPatrolUnitRelatedToQuest(unitId, focusQuests[index]) then
            return true
        end
        index = index + 1
    end
    return false
end

-- One quest (an objective hover) or one turn-in pin, whose point can carry
-- several quests handed in at the same spot. Passing neither clears the focus.
function WorldMapPins:ApplyFocus(quest, turnInPin)
    if self.focusQuest == quest and self.focusTurnInPin == turnInPin then
        return
    end
    self.focusQuest = quest
    self.focusTurnInPin = turnInPin
    SetFocusQuests(quest, turnInPin and turnInPin.unrealQuestTurnIn)
    local focused = focusQuestCount > 0

    local index = 1
    while index <= self.areaVisibleCount do
        local area = self.areaPool[index]
        Client.SetWorldMapPinAlpha(area,
            (not focused or FocusHasQuest(area.unrealQuestQuest)) and 1 or UNRELATED_MARKER_ALPHA)
        index = index + 1
    end

    index = 1
    while index <= self.visibleCount do
        local pin = self.pool[index]
        Client.SetWorldMapPinAlpha(pin,
            (not focused or FocusHasQuest(pin.unrealQuestQuest)) and 1 or UNRELATED_MARKER_ALPHA)
        index = index + 1
    end

    -- The "!" and "?" take both halves of their answer from one place: the
    -- fade this focus asks for, and the grow that says WHICH marker the
    -- focused quest belongs to.
    self:RefreshMarkerEmphasis()

    -- The patrol hover targets are skipped: they are invisible by construction,
    -- so there is nothing on them to fade. The route's own fade is the stroke's,
    -- and it cannot take it the way every pool above does -- a Texture has one
    -- alpha, so the value is recorded here and folded into the stamp's own
    -- colour by SetPatrolStrokeStyle instead of layering over it.
    local highlightedUnitId = self:HighlightedPatrolUnitId()
    index = 1
    while index <= self.strokeVisibleCount do
        local unitId = self.strokeUnitIds[index]
        self.strokeFaded[index] =
            (focused and not FocusRunsPatrolUnit(unitId)) and true or nil
        SetPatrolStrokeStyle(self, index, unitId ~= nil and unitId == highlightedUnitId)
        index = index + 1
    end
end

function WorldMapPins:ApplyQuestFocus(quest)
    self:ApplyFocus(quest, nil)
end

-- Hovering a "?" focuses every quest handed in at that point, so its
-- objectives, its giver and its patrol stay lit while the rest of the map
-- dims -- the same answer an objective hover gives, from the other end.
function WorldMapPins:ApplyTurnInFocus(pin)
    self:ApplyFocus(nil, pin)
end

-- Ctrl+click on a tracker row (Quest/TrackerFrame.lua) calls this to make a
-- quest's own map presence easy to spot among however many other pins are on
-- screen. Both pools that can carry the quest are collected -- the area tile
-- (where the objective is) and the "?" (where it hands in) -- because the
-- click does not know which one the player actually needs, and a quest ready
-- to turn in may have no area tile left at all.
--
-- This never opens the map itself (Client.OpenWorldMap is a separate,
-- best-effort call from the tracker) and never invents a pin: if nothing
-- carrying questId is currently rendered -- wrong zone, hidden, no unambiguous
-- match, or the map's current-zone-only join simply does not cover it -- there
-- is nothing to collect and this reports that honestly rather than guessing
-- at a location.
local FLASH_DURATION = 2.2
local FLASH_HZ = 2.5
local FLASH_MIN_ALPHA = 0.3
local FLASH_MAX_ALPHA = 1.0
-- Normal UnrealQuest marks top out six levels above the shared pin floor
-- (service, mob and vendor pins). A revealed quest must win every overlap for
-- the whole flash, whether its target is an objective dot/area or a turn-in
-- icon. The original level is restored exactly when the flash ends.
local FLASH_LEVEL_BOOST = 10

local function CollectFlashTargets(questId)
    local targets = {}
    local pool = WorldMapPins.areaPool
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        local area = pool[index]
        if area and area.unrealQuestQuest and area.unrealQuestQuest.questId == questId
            and Client.IsObjectShown(area) then
            table.insert(targets, area)
        end
        index = index + 1
    end
    pool = WorldMapPins.turnInPool
    index = 1
    total = table.getn(pool)
    while index <= total do
        local pin = pool[index]
        if pin and PointHasQuest(pin.unrealQuestTurnIn, questId) and Client.IsObjectShown(pin) then
            table.insert(targets, pin)
        end
        index = index + 1
    end
    return targets
end

local function RestoreFlashTargets()
    local targets = WorldMapPins.flashTargets
    if not targets then
        return
    end
    local index = 1
    local total = table.getn(targets)
    while index <= total do
        local target = targets[index]
        Client.SetWorldMapPinAlpha(target, 1)
        if target and target.unrealQuestFlashRaised then
            Client.RaiseWorldMapPin(target, -FLASH_LEVEL_BOOST)
            target.unrealQuestFlashRaised = nil
        end
        index = index + 1
    end
    WorldMapPins.flashTargets = nil
end

local function RaiseFlashTargets(targets)
    local index = 1
    local total = table.getn(targets)
    while index <= total do
        local target = targets[index]
        if target and Client.RaiseWorldMapPin(target, FLASH_LEVEL_BOOST) then
            target.unrealQuestFlashRaised = true
        end
        index = index + 1
    end
    WorldMapPins.flashTargets = targets
end

-- Pulses every target's whole-frame alpha (Client.SetWorldMapPinAlpha, the
-- same stock SetAlpha already relied on for the waypoint marker and the
-- turn-in hover dim) for FLASH_DURATION seconds, then hands every target back
-- to WorldMapPins' OWN redraw by marking the layer dirty rather than trying to
-- remember or recompute whatever alpha each one should settle back to -- the
-- next scheduled refresh already knows that.
function WorldMapPins:FlashQuest(questId)
    if type(questId) ~= "number" then
        return false
    end
    local targets = CollectFlashTargets(questId)
    if table.getn(targets) == 0 then
        return false
    end
    local driver = UQ:GetModule("Driver")
    local start = Client.Now()
    if not driver or not start then
        return false
    end
    -- Scheduling another reveal replaces the existing named driver job. Hand
    -- the previous targets back first so repeated Show actions never stack the
    -- boost or leave an earlier quest stranded above the map.
    RestoreFlashTargets()
    RaiseFlashTargets(targets)
    driver:Schedule("map.questflash", 0.05, function()
        local now = Client.Now()
        local elapsed = now and (now - start) or FLASH_DURATION
        if elapsed < 0 or elapsed >= FLASH_DURATION then
            RestoreFlashTargets()
            WorldMapPins.dirty = true
            local d = UQ:GetModule("Driver")
            if d then
                d:Unschedule("map.questflash")
            end
            return
        end
        local phase = elapsed * FLASH_HZ * 2 * math.pi
        local alpha = FLASH_MIN_ALPHA
            + (FLASH_MAX_ALPHA - FLASH_MIN_ALPHA) * (0.5 + 0.5 * math.sin(phase))
        local index = 1
        local total = table.getn(targets)
        while index <= total do
            Client.SetWorldMapPinAlpha(targets[index], alpha)
            index = index + 1
        end
    end)
    return true
end

-- Mouse scripts are attached once per pooled pin, at creation, never inside
-- the refresh loop: Core/Driver.lua documents freshly allocated per-tick
-- closures as a measured stuttering hazard on this client. Giver/quest data
-- for the handlers to read is refreshed as plain field writes on the same
-- frame table every tick instead.
function WorldMapPins:GetGiverPin(index)
    local pin = self.giverPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateWorldMapPin(index + GIVER_INDEX_OFFSET, 1, 1, 1)
    if pin then
        self.giverPool[index] = pin
        -- The bundled available-quest "!" replaces the tinted solid surface.
        -- Its 19x32 source keeps its own ratio; the Button, BACKGROUND texture,
        -- frame level and interaction contract stay unchanged.
        Client.SetWorldMapPinTexture(pin, Client.AVAILABLE_QUEST_TEXTURE)
        Client.SetWorldMapPinSize(pin, GIVER_ICON_WIDTH, GIVER_ICON_HEIGHT)
        -- A "!" is small and frequently sits inside a quest area, and every
        -- pool is otherwise created at the identical frame level, so without
        -- this the tile underneath can win the hit test and swallow the
        -- shift-click -- it takes the mouse for its own tooltip but has no
        -- OnClick to run. See Client.RaiseWorldMapPin.
        Client.RaiseWorldMapPin(pin, GIVER_LEVEL_BOOST)
        -- Base size the hover grow/shrink scales from and returns to.
        pin.unrealQuestBaseWidth = GIVER_ICON_WIDTH
        pin.unrealQuestBaseHeight = GIVER_ICON_HEIGHT
        pin.unrealQuestEmphasisScale = 1
        pin.unrealQuestEmphasisTarget = 1
        Client.SetWorldMapPinHandlers(pin,
            function() WorldMapPins:OnGiverEnter(pin) end,
            function() WorldMapPins:OnGiverLeave(pin) end,
            function() WorldMapPins:OnGiverClick(pin) end)
    end
    return pin
end

local function ApplyGiverAppearance(pin, lowLevel)
    if not pin then
        return
    end
    local width = GIVER_ICON_WIDTH
    local texture = Client.AVAILABLE_QUEST_TEXTURE
    if lowLevel then
        width = GIVER_ICON_HEIGHT * 27 / 64
        texture = Client.LOW_LEVEL_QUEST_TEXTURE
    end
    Client.SetWorldMapPinTexture(pin, texture)
    Client.SetWorldMapPinSize(pin, width, GIVER_ICON_HEIGHT)
    pin.unrealQuestBaseWidth = width
    pin.unrealQuestBaseHeight = GIVER_ICON_HEIGHT
end

-- Which builder a pooled pin's own content calls for. The two pin pools never
-- swap roles, so the field that is present is the marker's kind.
local function BuildPinTooltipLines(database, pin, isNeighbour)
    if not pin then
        return nil
    end
    if pin.unrealQuestGiver then
        return BuildGiverTooltipLines(database, pin.unrealQuestGiver,
            pin.unrealQuestAvailableQuestIds or {}, isNeighbour)
    end
    if pin.unrealQuestTurnIn then
        return BuildTurnInTooltipLines(database, pin.unrealQuestTurnIn)
    end
    return nil
end

-- Markers a few pixels apart cannot be hovered apart -- two NPCs standing
-- beside each other in a town land within one pin's width of each other, and
-- whichever pin the pool placed last simply takes every OnEnter. Rather than
-- fight for pixel precision, hovering anywhere in such a cluster describes
-- every marker in it, so the player never has to hit the right one.
--
-- Only visible pins are considered: a pooled pin that fell out of range on
-- the last rebuild keeps its stale map fractions, and the visible counts are
-- the only thing that separates a placed marker from a hidden one.
function WorldMapPins:AppendNearbyPins(cluster, hovered, pool, visibleCount, width, height)
    local omitted = 0
    local index = 1
    local total = visibleCount or 0
    while index <= total do
        local other = pool[index]
        if other and other ~= hovered
            and type(other.unrealQuestMapX) == "number"
            and type(other.unrealQuestMapY) == "number" then
            local dx = (other.unrealQuestMapX - hovered.unrealQuestMapX) * width
            local dy = (other.unrealQuestMapY - hovered.unrealQuestMapY) * height
            if dx * dx + dy * dy <= CLUSTER_RADIUS_PIXELS * CLUSTER_RADIUS_PIXELS then
                if table.getn(cluster) < MAX_CLUSTER_ENTRIES then
                    table.insert(cluster, other)
                else
                    omitted = omitted + 1
                end
            end
        end
        index = index + 1
    end
    return omitted
end

-- The hovered marker always comes first, so the tooltip still reads as being
-- about the thing under the cursor and its title line is still the one the
-- client turns into the tooltip's heading.
function WorldMapPins:CollectClusterPins(pin)
    local cluster = { pin }
    if not ClusterTooltipsEnabled() then
        return cluster, 0
    end
    if type(pin.unrealQuestMapX) ~= "number" or type(pin.unrealQuestMapY) ~= "number" then
        return cluster, 0
    end
    local width, height = Client.GetWorldMapCanvasSize()
    if not width or not height then
        return cluster, 0
    end
    local omitted = self:AppendNearbyPins(
        cluster, pin, self.giverPool, self.giverVisibleCount, width, height)
    omitted = omitted + self:AppendNearbyPins(
        cluster, pin, self.turnInPool, self.turnInVisibleCount, width, height)
    return cluster, omitted
end

-- One tooltip, one block per marker in the cluster, separated the same way
-- several quests on a single giver already are -- so a cluster reads as more
-- of the same list rather than as a different kind of tooltip.
function WorldMapPins:BuildClusterTooltipLines(database, pin)
    local cluster, omitted = self:CollectClusterPins(pin)
    local lines = BuildPinTooltipLines(database, pin, false)
    if not lines then
        return nil
    end
    local index = 2
    local total = table.getn(cluster)
    while index <= total do
        local block = BuildPinTooltipLines(database, cluster[index], true)
        if block then
            table.insert(lines, { separator = true })
            local lineIndex = 1
            local lineTotal = table.getn(block)
            while lineIndex <= lineTotal do
                table.insert(lines, block[lineIndex])
                lineIndex = lineIndex + 1
            end
        end
        index = index + 1
    end
    if omitted > 0 then
        table.insert(lines, { separator = true })
        table.insert(lines, {
            text = UQ.LN("MAP_MORE_MARKERS", omitted),
            r = 0.5, g = 0.5, b = 0.5,
        })
    end
    return lines
end

function WorldMapPins:OnGiverEnter(pin)
    RecordGiverHover()
    self:ApplyGiverTurnInHover(pin)
    self:ApplyPatrolHover(pin)
    -- A stale picker menu left open from a different "!" reads as it having
    -- lost track of what it was pointing at; hovering any other giver closes
    -- it, the same way opening a new one on click replaces it.
    if not Client.IsGiverQuestMenuOpenFor(pin) then
        Client.HideGiverQuestMenu()
    end
    local database = Database()
    if not database or not pin.unrealQuestGiver then
        return
    end
    Client.ShowMapTooltip(pin, self:BuildClusterTooltipLines(database, pin),
        self:ChoosePatrolTooltipAnchor(pin, pin.unrealQuestGiver.sourceId))
end

function WorldMapPins:OnGiverLeave(pin)
    self:ClearGiverTurnInHover(pin)
    self:ApplyPatrolHover(nil)
    Client.HideMapTooltip(pin)
end

-- Marks one quest done and redraws, shared by the shift-click bulk path and
-- the Ctrl+click per-quest picker below. Goes through MarkDoneManually, not
-- MarkDone, so /uq resetmarked can find and undo it later without touching
-- quests QuestHistory completed on its own by watching the log.
function WorldMapPins:MarkGiverQuestDone(questId)
    local questHistory = QuestHistory()
    if not questHistory or questId == nil then
        return
    end
    questHistory:MarkDoneManually(questId)
    self.dirty = true
    -- The minimap draws the same giver from the same CollectAvailableGivers
    -- policy, but caches the result in its own target list and only rebuilds
    -- it when QuestState fires or the bags change. Marking done touches
    -- neither, so without this the "!" stays on the minimap until some
    -- unrelated quest event happens to invalidate it. /uq resetmarked already
    -- invalidates both sides for the same reason.
    local minimap = MinimapPins()
    if minimap then
        minimap.dirty = true
    end
    -- Redraw on the next tick instead of waiting out the refresh interval, so
    -- the "!" goes away as the player clicks it rather than up to a quarter
    -- second later. pfQuest does the same thing on its own mark-done click
    -- (pfMap.queue_update = GetTime()). Waking a job is the sanctioned way to
    -- accelerate the driver; it never replaces the poll.
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Wake("map.worldpins")
        driver:Wake("map.minimappins")
    end
end

-- Marks every quest a "!" currently offers as done, in one action. Reached
-- from a click on a single-quest giver and from the picker's own "mark them
-- all" row, never from an unconditional click on a multi-quest pin.
function WorldMapPins:MarkAllGiverQuestsDone(ids)
    local index = 1
    local total = table.getn(ids or {})
    while index <= total do
        self:MarkGiverQuestDone(ids[index])
        index = index + 1
    end
end

-- Shift- or Ctrl-clicking a "!" marks the quest it offers as done in
-- QuestHistory. Which quest that is has to be asked rather than assumed: the
-- pin is per-GIVER, its tooltip lists every quest that giver is still
-- offering, and one click cannot mean all of them without silently discarding
-- the ones the player did not intend. So:
--
--   * exactly one quest offered -- nothing to disambiguate, mark it directly;
--   * several quests offered -- open the picker naming each one, which also
--     carries a "mark them all" row for the old bulk behaviour.
--
-- Clicking the same "!" again while its picker is open closes it, so the
-- gesture is its own escape hatch. The map tooltip is dismissed on open: it
-- is anchored to this same pin and would otherwise sit on top of the menu it
-- just produced.
function WorldMapPins:OnGiverClick(pin)
    local shiftHeld = Client.IsShiftKeyDown()
    local ctrlHeld = Client.IsControlKeyDown()
    RecordGiverClick(shiftHeld)
    if not shiftHeld and not ctrlHeld then
        return
    end

    local ids = pin.unrealQuestAvailableQuestIds
    if not ids then
        return
    end
    local total = table.getn(ids)
    if total <= 0 then
        return
    end

    if Client.IsGiverQuestMenuOpenFor(pin) then
        Client.HideGiverQuestMenu()
        return
    end

    if total == 1 then
        Client.HideGiverQuestMenu()
        self:MarkGiverQuestDone(ids[1])
        return
    end

    -- Titles come from the bundled data, so a quest the database cannot name
    -- would produce an unlabelled row. Falling back to the bulk mark is worse
    -- than a partial list, so only the nameable ones become rows -- and if
    -- none of them are nameable there is nothing to choose between and the
    -- old bulk behaviour is the only honest option left.
    local database = Database()
    local entries = {}
    if database then
        local index = 1
        while index <= total do
            local questId = ids[index]
            local title = UQ.GetQuestDisplayTitle(questId)
            if title then
                table.insert(entries, { id = questId, text = title })
            end
            index = index + 1
        end
    end
    if table.getn(entries) == 0 then
        self:MarkAllGiverQuestsDone(ids)
        return
    end

    Client.HideMapTooltip(pin)
    local shown = Client.ShowGiverQuestMenu(pin, entries, function(entry)
        if entry and entry.all then
            self:MarkAllGiverQuestsDone(ids)
        elseif entry then
            self:MarkGiverQuestDone(entry.id)
        end
        Client.HideGiverQuestMenu()
    end)
    -- A client that refused to build the menu frame at all must not leave the
    -- gesture inert; the bulk mark is the documented behaviour it replaces.
    if not shown then
        self:MarkAllGiverQuestsDone(ids)
    end
end

-- Same construction and same once-at-creation script attachment as the giver
-- pins, with two deliberate differences: a bundled "?" icon instead of the
-- client's "!", and no OnClick at all. Passing nil for the click handler also stops
-- Client.SetWorldMapPinHandlers registering click tokens, so these pins leave
-- clicks to whatever is underneath them rather than swallowing them the way a
-- mouse-aware frame with no handler does -- the exact failure that made the
-- "!" shift-click look broken.
function WorldMapPins:GetTurnInPin(index)
    local pin = self.turnInPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateWorldMapPin(index + TURNIN_INDEX_OFFSET, 1, 1, 1)
    if pin then
        self.turnInPool[index] = pin
        Client.SetWorldMapPinTexture(pin, Client.ACTIVE_QUEST_TEXTURE)
        Client.SetWorldMapPinSize(pin, TURNIN_ICON_WIDTH, TURNIN_ICON_HEIGHT)
        Client.RaiseWorldMapPin(pin, TURNIN_LEVEL_BOOST)
        -- Base size the hover grow/shrink scales from and returns to.
        pin.unrealQuestBaseWidth = TURNIN_ICON_WIDTH
        pin.unrealQuestBaseHeight = TURNIN_ICON_HEIGHT
        pin.unrealQuestEmphasisScale = 1
        pin.unrealQuestEmphasisTarget = 1
        Client.SetWorldMapPinHandlers(pin,
            function() WorldMapPins:OnTurnInEnter(pin) end,
            function() WorldMapPins:OnTurnInLeave(pin) end,
            nil)
    end
    return pin
end

function WorldMapPins:OnTurnInEnter(pin)
    RecordTurnInHover()
    self:ApplyGiverTurnInHover(pin)
    self:ApplyPatrolHover(pin)
    -- Mirrors OnAreaEnter's own-quest link, the other direction. Keyed on the
    -- PIN, not on its .unrealQuestTurnIn point: a rebuild replaces every point
    -- table, so a point captured here would already be a different object by
    -- the time OnTurnInLeave compared against it and the focus would never
    -- clear. The pin's own identity is stable across rebuilds, and ApplyFocus
    -- reads its CURRENT .unrealQuestTurnIn.
    self:ApplyTurnInFocus(pin)
    local database = Database()
    if not database or not pin.unrealQuestTurnIn then
        return
    end
    local fallbackAnchor = self:ChooseTurnInTooltipAnchor(pin)
    Client.ShowMapTooltip(pin, self:BuildClusterTooltipLines(database, pin),
        self:ChoosePatrolTooltipAnchor(pin, MarkerUnitId(pin), fallbackAnchor))
end

-- Picks the side of the "?" that keeps the tooltip off the objective tiles
-- it just highlighted. ANCHOR_RIGHT/LEFT only move the tooltip horizontally,
-- so this only ever needs the pins'/areas' stored map-X fraction (0 = left
-- edge of the canvas, 1 = right edge) rather than full screen geometry.
function WorldMapPins:ChooseTurnInTooltipAnchor(pin)
    local point = pin.unrealQuestTurnIn
    if not point or type(pin.unrealQuestMapX) ~= "number" then
        return "ANCHOR_RIGHT"
    end
    local pool = self.areaPool
    local index = 1
    local total = table.getn(pool)
    local linkedRight, linkedLeft = false, false
    while index <= total do
        local area = pool[index]
        if area and area.unrealQuestQuest and type(area.unrealQuestMapX) == "number"
            and PointHasQuest(point, area.unrealQuestQuest) then
            if area.unrealQuestMapX >= pin.unrealQuestMapX then
                linkedRight = true
            else
                linkedLeft = true
            end
        end
        index = index + 1
    end
    if linkedRight and not linkedLeft then
        return "ANCHOR_LEFT"
    end
    if linkedLeft and not linkedRight then
        return "ANCHOR_RIGHT"
    end
    -- Tiles on both sides, or none linked (e.g. the objective is outside the
    -- current map view): fall back to opening away from whichever half of
    -- the canvas the pin itself sits in.
    if pin.unrealQuestMapX > 0.5 then
        return "ANCHOR_LEFT"
    end
    return "ANCHOR_RIGHT"
end

function WorldMapPins:OnTurnInLeave(pin)
    self:ClearGiverTurnInHover(pin)
    self:ApplyPatrolHover(nil)
    if self.focusTurnInPin == pin then
        self:ApplyTurnInFocus(nil)
    end
    Client.HideMapTooltip(pin)
end

-- Same acceleration OnGiverClick already uses: forces the next Refresh to
-- take the full recompute path rather than the dirty/signature fast-path
-- ReapplyVisiblePool takes (which never touches area colour), then wakes the
-- shared driver so that redraw lands on the next tick instead of waiting out
-- REFRESH_INTERVAL.
function WorldMapPins:WakeMapDriver()
    self.dirty = true
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Wake("map.worldpins")
    end
end

-- Grows the hovered "!"/"?" so the one under the mouse reads as distinct
-- from the rest of the layer. Passing nil drops the hover. The pin is only
-- recorded here; RefreshMarkerEmphasis is what decides every marker's size and
-- opacity, so this can no longer overwrite a focus dim or a route highlight.
function WorldMapPins:ApplyGiverTurnInHover(hoveredPin)
    self.hoverMarkerPin = hoveredPin
    self:RefreshMarkerEmphasis()
end

-- Leaving a marker must not drop a hover that already belongs to another one:
-- this client can deliver the next marker's OnEnter before this OnLeave, and
-- an unguarded clear would shrink the pin the mouse is actually on. The same
-- guard the tile hover and the turn-in focus already use, for the same reason.
function WorldMapPins:ClearGiverTurnInHover(pin)
    if self.hoverMarkerPin ~= pin then
        return
    end
    self:ApplyGiverTurnInHover(nil)
end

-- Alpha 0 is applied once, here, and never touched again: nothing in the draw
-- pass restyles a hover target, because there is no state of one that is
-- visible. The alpha goes on the TEXTURE rather than the frame so that a
-- zero-alpha surface still leaves its Button in the hit test.
function WorldMapPins:GetPatrolHoverTarget(index)
    local target = self.patrolPool[index]
    if target then
        return target
    end
    target = Client.CreateWorldMapArea(index, 1, 1, 1, 0, "Patrol")
    if target then
        self.patrolPool[index] = target
        Client.SetWorldMapPinHandlers(target,
            function() WorldMapPins:OnPatrolEnter(target) end,
            function() WorldMapPins:OnPatrolLeave(target) end)
        Client.SetWorldMapAreaColor(target, 1, 1, 1, 0)
        Client.SetWorldMapPinSize(target,
            PATROL_HOVER_TARGET_SIZE, PATROL_HOVER_TARGET_SIZE)
    end
    return target
end

-- The stroke pool has no constructor arguments and no handlers: a stamp is a
-- bare Texture that never takes the mouse. Everything the dash pool needs a
-- Button for -- hover, tooltip, the reverse link to the quest markers -- stays
-- on the dash at the same index band underneath.
function WorldMapPins:GetPatrolStroke(index)
    local stroke = self.strokePool[index]
    if stroke then
        return stroke
    end
    stroke = Client.CreateWorldMapStroke()
    if stroke then
        self.strokePool[index] = stroke
    end
    return stroke
end

-- A stamp has one alpha channel, not the frame-plus-texture pair a pooled
-- Button gives the dashes, so the hover highlight and the focus fade have to
-- be resolved into a single value here rather than layered by the client.
function SetPatrolStrokeStyle(pins, index, highlighted)
    local stroke = pins.strokePool[index]
    if not stroke then
        return
    end
    local width = pins.strokeWidth or PATROL_LINE_WIDTH
    local red, green, blue, alpha, size
    if highlighted then
        red, green, blue = PATROL_LINE_HOVER_RED, PATROL_LINE_HOVER_GREEN, PATROL_LINE_HOVER_BLUE
        alpha, size = PATROL_LINE_HOVER_ALPHA, width + PATROL_LINE_HOVER_BOOST
    else
        red, green, blue = PATROL_LINE_RED, PATROL_LINE_GREEN, PATROL_LINE_BLUE
        alpha, size = PATROL_LINE_ALPHA, width
    end
    if pins.strokeFaded[index] then
        alpha = alpha * UNRELATED_MARKER_ALPHA
    end
    Client.SetWorldMapStrokeColor(stroke, red, green, blue, alpha)
    -- Growing a stamp does not move it: every stamp is anchored by its CENTRE,
    -- so a wider stroke thickens around the same path instead of drifting off
    -- it.
    Client.SetWorldMapStrokeSize(stroke, size)
end

-- A quest-marker hover and its patrol are one visual selection. Styling the
-- already-visible pool directly makes the response immediate; the draw pass
-- below also reads hoverPatrolMarker so a rebuild held under the cursor
-- preserves the same highlight for either "!" or "?".
function WorldMapPins:ApplyPatrolHover(pin)
    self.hoverPatrolMarker = pin
    self:RefreshPatrolHighlight()
end

-- The unit whose route is currently held, from either direction of the link:
-- a hovered "!"/"?" or a hovered dash. Both the draw pass and the immediate
-- restyle below read it, which is what lets a rebuild under the cursor keep
-- the same route lit.
function WorldMapPins:HighlightedPatrolUnitId()
    local unitId = MarkerUnitId(self.hoverPatrolMarker)
    if unitId == nil and self.hoverPatrolTarget then
        unitId = self.hoverPatrolTarget.unrealQuestPatrolUnitId
    end
    return unitId
end

function WorldMapPins:RefreshPatrolHighlight()
    local unitId = self:HighlightedPatrolUnitId()
    local index = 1
    while index <= self.strokeVisibleCount do
        SetPatrolStrokeStyle(self, index,
            unitId ~= nil and self.strokeUnitIds[index] == unitId)
        index = index + 1
    end
end

function WorldMapPins:FindPatrolMarkerPin(unitId)
    local pools = {
        { pool = self.giverPool, visible = self.giverVisibleCount },
        { pool = self.turnInPool, visible = self.turnInVisibleCount },
    }
    local poolIndex = 1
    while poolIndex <= table.getn(pools) do
        local entry = pools[poolIndex]
        local index = 1
        while index <= entry.visible do
            local pin = entry.pool[index]
            if MarkerUnitId(pin) == unitId then
                return pin
            end
            index = index + 1
        end
        poolIndex = poolIndex + 1
    end
    return nil
end

-- Chooses the tooltip side with the least associated patrol content. Nearby
-- elements weigh more than distant ones, and a "!" weighs more than one route
-- dot because hiding the quest giver defeats the purpose of the reverse link.
-- With relevant content on both sides this is best-effort; ANCHOR_LEFT/RIGHT
-- cannot move a tooltip vertically on this client surface.
function WorldMapPins:ChoosePatrolTooltipAnchor(owner, unitId, fallbackAnchor)
    if not owner or type(owner.unrealQuestMapX) ~= "number" or type(unitId) ~= "number" then
        return fallbackAnchor or "ANCHOR_RIGHT"
    end
    local ownerX = owner.unrealQuestMapX
    local leftScore, rightScore = 0, 0
    local hasPatrol = false

    local function Add(frame, weight)
        if not frame or frame == owner or type(frame.unrealQuestMapX) ~= "number" then
            return
        end
        local dx = frame.unrealQuestMapX - ownerX
        local score = weight / (0.04 + math.abs(dx))
        if dx < 0 then
            leftScore = leftScore + score
        elseif dx > 0 then
            rightScore = rightScore + score
        else
            leftScore = leftScore + score * 0.5
            rightScore = rightScore + score * 0.5
        end
    end

    local index = 1
    while index <= self.patrolVisibleCount do
        local dash = self.patrolPool[index]
        if dash and dash.unrealQuestPatrolUnitId == unitId then
            hasPatrol = true
            Add(dash, 1)
        end
        index = index + 1
    end
    if not hasPatrol then
        return fallbackAnchor or "ANCHOR_RIGHT"
    end

    local markerPools = {
        { pool = self.giverPool, visible = self.giverVisibleCount },
        { pool = self.turnInPool, visible = self.turnInVisibleCount },
    }
    local poolIndex = 1
    while poolIndex <= table.getn(markerPools) do
        local entry = markerPools[poolIndex]
        index = 1
        while index <= entry.visible do
            local pin = entry.pool[index]
            if MarkerUnitId(pin) == unitId then
                Add(pin, PATROL_TOOLTIP_MARKER_WEIGHT)
            end
            index = index + 1
        end
        poolIndex = poolIndex + 1
    end

    if leftScore < rightScore then
        return "ANCHOR_LEFT"
    end
    if rightScore < leftScore then
        return "ANCHOR_RIGHT"
    end
    if ownerX > 0.5 then
        return "ANCHOR_LEFT"
    end
    return "ANCHOR_RIGHT"
end

function WorldMapPins:OnPatrolEnter(dash)
    self.hoverPatrolTarget = dash
    self:RefreshPatrolHighlight()
    local unitId = dash and dash.unrealQuestPatrolUnitId
    -- Reverse link from a route point to every visible marker owned by that
    -- NPC. One unit can own several spawn markers and both marker types, so
    -- every matching "!" and "?" grows rather than one guessed pool slot.
    self:RefreshMarkerEmphasis()
    local database = Database()
    local markerPin = self:FindPatrolMarkerPin(unitId)
    if database and markerPin then
        Client.ShowMapTooltip(dash,
            self:BuildClusterTooltipLines(database, markerPin),
            self:ChoosePatrolTooltipAnchor(dash, unitId))
    end
end

function WorldMapPins:OnPatrolLeave(dash)
    if self.hoverPatrolTarget == dash then
        self.hoverPatrolTarget = nil
        self:RefreshPatrolHighlight()
        self:RefreshMarkerEmphasis()
    end
    Client.HideMapTooltip(dash)
end

-- Ordered line segments for every moving NPC with a visible quest marker in
-- this area. unitIds is a set so a creature with several spawn markers,
-- several quests or both "!" and "?" contributes its patrol once. Point[6] is
-- the route's original waypoint order; a gap there means the missing points
-- belong to another zone, so the two visible points must not be joined across
-- the current map.
function WorldMapPins:CollectPatrolSegments(database, unitIds, areaId)
    local segments = {}
    if not database or not database.GetUnitPatrolRoutes or type(unitIds) ~= "table" then
        return segments
    end

    local orderedUnitIds = {}
    local unitId
    for unitId in pairs(unitIds) do
        if type(unitId) == "number" then
            table.insert(orderedUnitIds, unitId)
        end
    end
    table.sort(orderedUnitIds)

    local function Append(unit, routeId, left, right, requireAdjacent)
        if type(left) ~= "table" or type(right) ~= "table"
            or type(left[1]) ~= "number" or type(left[2]) ~= "number"
            or type(right[1]) ~= "number" or type(right[2]) ~= "number" then
            return
        end
        if requireAdjacent and type(left[6]) == "number" and type(right[6]) == "number"
            and right[6] ~= left[6] + 1 then
            return
        end
        local dx = right[1] - left[1]
        local dy = right[2] - left[2]
        if dx == 0 and dy == 0 then
            return
        end
        table.insert(segments, {
            x1 = left[1], y1 = left[2],
            x2 = right[1], y2 = right[2],
            unitId = unit, routeId = routeId,
            length = math.sqrt(dx * 1.5 * dx * 1.5 + dy * dy),
        })
    end

    local unitIndex = 1
    local unitTotal = table.getn(orderedUnitIds)
    while unitIndex <= unitTotal do
        unitId = orderedUnitIds[unitIndex]
        local routes = database:GetUnitPatrolRoutes(unitId, areaId)
        local routeIndex = 1
        local routeTotal = table.getn(routes)
        while routeIndex <= routeTotal do
            local route = routes[routeIndex]
            local points = route.points
            local pointIndex = 2
            local pointTotal = table.getn(points)
            while pointIndex <= pointTotal do
                Append(unitId, route.routeId, points[pointIndex - 1], points[pointIndex], true)
                pointIndex = pointIndex + 1
            end
            if route.closed and pointTotal > 2 then
                Append(unitId, route.routeId, points[pointTotal], points[1], false)
            end
            routeIndex = routeIndex + 1
        end
        unitIndex = unitIndex + 1
    end
    return segments
end

-- One pass along the collected route, stamping at a fixed spacing. Contiguous
-- segments share the running distance, so a stamp never restarts at a shared
-- endpoint and the source's many short segments produce an evenly spaced path
-- rather than a cluster at every join; a break in unit, route or endpoint
-- resets it. `visit` returns true when it placed a stamp, false when the
-- placement failed, and nil when there was nothing to place -- the three
-- outcomes the dash pass counted before both presentations shared this walk.
local function WalkPatrolPath(mapContext, areaId, segments, report, spacing, limit, visit)
    local placed = 0
    local failures = 0
    local distanceToNext = 0
    local previousSegment = nil
    local segmentIndex = 1
    local segmentTotal = table.getn(segments)
    while segmentIndex <= segmentTotal and placed < limit do
        local segment = segments[segmentIndex]
        local continues = previousSegment
            and previousSegment.unitId == segment.unitId
            and previousSegment.routeId == segment.routeId
            and previousSegment.x2 == segment.x1 and previousSegment.y2 == segment.y1
        if not continues then
            distanceToNext = 0
        end
        while distanceToNext <= segment.length and placed < limit do
            local progress = distanceToNext / segment.length
            local x = segment.x1 + (segment.x2 - segment.x1) * progress
            local y = segment.y1 + (segment.y2 - segment.y1) * progress
            local mapX, mapY = mapContext:DatabaseToCurrentMap(areaId, x, y, report)
            if mapX and mapY then
                local result = visit(placed + 1, mapX, mapY, segment)
                if result then
                    placed = placed + 1
                elseif result == false then
                    failures = failures + 1
                end
            end
            distanceToNext = distanceToNext + spacing
        end
        distanceToNext = distanceToNext - segment.length
        previousSegment = segment
        segmentIndex = segmentIndex + 1
    end
    return placed, failures
end

-- Total path length and the number of separate chains in it. A chain costs one
-- stamp that no spacing can amortise -- its own start point -- so the budget
-- left for spacing is the pool minus the chain count, not the whole pool.
local function PatrolPathMetrics(segments)
    local totalLength = 0
    local chainCount = 0
    local segmentIndex = 1
    local segmentTotal = table.getn(segments)
    while segmentIndex <= segmentTotal do
        local segment = segments[segmentIndex]
        totalLength = totalLength + segment.length
        local previous = segments[segmentIndex - 1]
        if not previous or previous.unitId ~= segment.unitId
            or previous.routeId ~= segment.routeId
            or previous.x2 ~= segment.x1 or previous.y2 ~= segment.y1 then
            chainCount = chainCount + 1
        end
        segmentIndex = segmentIndex + 1
    end
    return totalLength, chainCount
end

-- Widens the requested spacing just enough that the whole scene fits the pool,
-- which simplifies a long patrol uniformly instead of chopping its tail off at
-- the bound. Shared by both presentations, and it is also what keeps the dense
-- line honest: a pathological zone degrades towards a coarser path rather
-- than towards a truncated route.
local function FitPatrolSpacing(segments, spacing, limit)
    local totalLength, chainCount = PatrolPathMetrics(segments)
    local extraBudget = limit - chainCount
    if extraBudget > 0 and totalLength / extraBudget > spacing then
        return totalLength / extraBudget
    end
    return spacing
end

-- The route's own units are area percentages; a stroke width is pixels.
-- CollectPatrolSegments already scales x by the map's 1.5 aspect when it
-- measures a segment, so one length unit is one percent of the canvas HEIGHT,
-- and the measured canvas is what converts between the two. Without this the
-- single spacing constant would leave the stamps separated on a tall map and
-- waste most of the pool on a short one.
-- Returns the requested spacing and the pixels-per-length-unit it converted
-- through, because the caller has to convert the FINAL spacing back into
-- pixels to decide how wide the stamps must be to still touch at it.
local function PatrolStrokeSpacing()
    local canvasWidth, canvasHeight = Client.GetWorldMapCanvasSize()
    if not canvasHeight or canvasHeight <= 0 then
        return nil
    end
    local pixelsPerUnit = canvasHeight / 100
    return PATROL_LINE_WIDTH * PATROL_LINE_OVERLAP / pixelsPerUnit, pixelsPerUnit
end

-- Lays the invisible hit targets along the route, widening their spacing when
-- needed so a long patrol stays hoverable end to end instead of losing its
-- tail at the pool bound. Nothing here paints: see GetPatrolHoverTarget.
function WorldMapPins:DrawPatrolHoverTargets(mapContext, areaId, segments, report)
    if table.getn(segments) == 0 then
        return 1, 0
    end
    local spacing = FitPatrolSpacing(
        segments, PATROL_HOVER_TARGET_SPACING, MAX_PATROL_HOVER_TARGETS)
    local placed, failures = WalkPatrolPath(mapContext, areaId, segments, report,
        spacing, MAX_PATROL_HOVER_TARGETS,
        function(index, mapX, mapY, segment)
            local target = self:GetPatrolHoverTarget(index)
            if not target then
                return false
            end
            if not Client.PositionWorldMapDot(
                target, mapX, mapY, PATROL_HOVER_TARGET_SIZE) then
                Client.HideObject(target)
                return false
            end
            target.unrealQuestPatrolUnitId = segment.unitId
            target.unrealQuestPatrolRouteId = segment.routeId
            return true
        end)
    return placed + 1, failures
end

-- The route as the player sees it.
function WorldMapPins:DrawPatrolStrokes(mapContext, areaId, segments, report)
    if table.getn(segments) == 0 then
        return 1, 0
    end
    local spacing, pixelsPerUnit = PatrolStrokeSpacing()
    if not spacing or spacing <= 0 then
        -- No measured canvas means no pixel-to-percent conversion, and a
        -- guessed one would either scatter the stamps or exhaust the pool.
        -- Drawing nothing is the honest outcome: the hover targets are still
        -- placed, so the route's tooltip and highlight survive a frame that
        -- could not be measured.
        return 1, 0
    end
    spacing = FitPatrolSpacing(segments, spacing, MAX_PATROL_STROKES)
    -- What the budget left, in pixels, is what the stamps have to span.
    local spacingPixels = spacing * pixelsPerUnit
    local width = PATROL_LINE_WIDTH
    if spacingPixels > width then
        width = spacingPixels
        if width > PATROL_LINE_MAX_WIDTH then
            width = PATROL_LINE_MAX_WIDTH
        end
    end
    self.strokeWidth = width
    local highlightedUnitId = self:HighlightedPatrolUnitId()
    local placed, failures = WalkPatrolPath(mapContext, areaId, segments, report,
        spacing, MAX_PATROL_STROKES,
        function(index, mapX, mapY, segment)
            local stroke = self:GetPatrolStroke(index)
            if not stroke then
                return false
            end
            if not Client.PositionWorldMapStroke(stroke, mapX, mapY, width) then
                Client.HideObject(stroke)
                return false
            end
            self.strokeUnitIds[index] = segment.unitId
            self.strokeX[index] = mapX
            self.strokeY[index] = mapY
            -- A stamp takes its fade only from ApplyFocus, which the rebuild
            -- clears and re-applies immediately after this pass.
            self.strokeFaded[index] = nil
            SetPatrolStrokeStyle(self, index, highlightedUnitId == segment.unitId)
            return true
        end)
    return placed + 1, failures
end

-- Puts every visible stamp back on its recorded point. Only a canvas that
-- changed SIZE needs this: the stamps are anchored to the stroke layer, which
-- fills the canvas, so an unchanged canvas keeps every offset valid and
-- Client.ReapplyWorldMapStrokeLayer alone is enough.
function WorldMapPins:ReapplyPatrolStrokes()
    if self.strokeVisibleCount <= 0 then
        return
    end
    local highlightedUnitId = self:HighlightedPatrolUnitId()
    local index = 1
    while index <= self.strokeVisibleCount do
        local stroke = self.strokePool[index]
        local x, y = self.strokeX[index], self.strokeY[index]
        if stroke and type(x) == "number" and type(y) == "number" then
            Client.PositionWorldMapStroke(stroke, x, y, self.strokeWidth or PATROL_LINE_WIDTH)
            SetPatrolStrokeStyle(self, index, highlightedUnitId == self.strokeUnitIds[index])
        end
        index = index + 1
    end
end

-- Dots identify their quest through the shared stable palette. Area tiles keep
-- the older blue/in-progress and green/complete state colours. The alpha this
-- returns belongs to the tiles; a dot is opaque.
local function ObjectiveColor(quest, complete, isMain, dots)
    local r, g, b, a
    if dots then
        r, g, b = UQ.GetQuestColor(quest)
        a = DOT_ALPHA
    elseif complete and isMain then
        r, g, b, a = 0.55, 1, 0.55, MAIN_AREA_ALPHA
    elseif complete then
        r, g, b, a = 0.2, 1, 0.2, COMPLETE_AREA_ALPHA
    elseif isMain then
        -- Alpha alone would not separate this from the other blue tiles, so
        -- the main quest shifts towards a paler blue as well. Alpha stays at
        -- the 0.5 probe 1.29.0 confirmed visible: the first 0.2 run was
        -- confirmed INVISIBLE on this client, so nothing here may go below it.
        r, g, b, a = 0.45, 0.82, 1, MAIN_AREA_ALPHA
    else
        r, g, b, a = 0.12, 0.55, 1, AREA_ALPHA
    end
    -- No hover term: a quest's colour is its identity, and hover is answered
    -- entirely by frame alpha (WorldMapPins:ApplyFocus). Keeping the two apart
    -- is what lets a hover skip the rebuild this assignment lives in.
    return r, g, b, a
end

-- Swaps one pooled objective frame between the two presentations. Guarded on
-- the flag it stores: SetTexture is the only call in this path that is not a
-- field write, and a pool that never changes mode must not pay for one on
-- every rebuild.
local function ApplyObjectiveStyle(area, dots)
    if not area or area.unrealQuestDotStyle == dots then
        return
    end
    area.unrealQuestDotStyle = dots
    if dots then
        Client.SetWorldMapPinTexture(area, Client.MINIMAP_OBJECTIVE_TEXTURE)
    else
        Client.SetWorldMapPinTexture(area, Client.WORLD_MAP_PIN_TEXTURE)
    end
end

function WorldMapPins:ApplyObjectiveDotSize()
    local size = ObjectiveDotSize()
    local index = 1
    while index <= self.areaVisibleCount do
        local area = self.areaPool[index]
        if area and area.unrealQuestDotStyle then
            Client.SetWorldMapPinSize(area, size, size)
        end
        index = index + 1
    end
    self.dirty = true
end

function WorldMapPins:Refresh()
    local canvas = Client.GetWorldMapCanvas()
    if not canvas then
        HideAllPools()
        self.dirty = true
        RecordDiagnostic("canvasMissing")
        return
    end
    if not self.renderEnabled then
        HideAllPools()
        self.dirty = false
        RecordDiagnostic("probeIsolation", nil, nil, 0, 0, 0)
        return
    end
    if not self.canvasDetected then
        self.canvasDetected = true
        UQ:DeclareCapability("worldMapCanvas", "detected",
            "WorldMapButton resolved with geometry; Lua shown/visible flags do not reflect this client's fullscreen presentation")
    end
    RecordSnapshot(UQ:GetModule("Config"))

    local database = Database()
    local mapContext = MapContext()
    local questState = QuestState()
    local questTarget = QuestTarget()
    -- Gated with the rest of the layer. MainQuest holds no selection while the
    -- gate is off, so isMain would already be false everywhere below -- but
    -- resolving it to nil here drops a method call per quest per redraw instead
    -- of relying on that, and makes the map's independence from the layer
    -- explicit rather than incidental.
    local mainQuest = nil
    if UQ:IsFeatureEnabled("mainQuestWaypoint") then
        mainQuest = MainQuest()
    end
    if not database or not database.available or not database:IsIndexReady()
        or not mapContext or not questState or not questTarget then
        HideAllPools()
        self.dirty = true
        RecordDiagnostic("databaseNotReady")
        return
    end

    -- The zone the MAP is showing, not the zone the player is standing in:
    -- this layer only converts database percentages to UVs on the canvas in
    -- front of it, so opening Westfall's map from Elwynn Forest draws
    -- Westfall's quest markers. The minimap layer and the HUD waypoint still
    -- ask for the player's own zone -- both measure from the player's
    -- position, which a foreign view cannot supply. See MapContext.
    local areaId, report, viewReason = mapContext:GetViewedZone()
    if not areaId then
        HideAllPools()
        self.dirty = true
        RecordDiagnostic("viewUnavailable:" .. tostring(viewReason), nil, report)
        return
    end

    local signature = ViewSignature(areaId, report)
    if not self.dirty and signature == self.lastSignature then
        self:ReapplyVisiblePools()
        return
    end
    self.dirty = false
    -- Persisted un-deduped, unlike RecordDiagnostic: this is what separates
    -- "the rebuild never ran" from "the rebuild ran and the map did not
    -- repaint", and a deduped counter cannot answer that. Rebuilds are rare
    -- (only a dirty flag or a changed view reaches here), so the write is not
    -- on a hot path.
    self.rebuildCount = (self.rebuildCount or 0) + 1
    local rebuildConfig = UQ:GetModule("Config")
    if rebuildConfig then
        rebuildConfig:SetSectionEntry("mapDiagnostics", "rebuilds", self.rebuildCount)
        -- The zone this pass drew, which is the open map's and no longer
        -- necessarily the player's. Without it a foreign-zone map that came
        -- out empty is indistinguishable from one drawn for the wrong area.
        rebuildConfig:SetSectionEntry("mapDiagnostics", "areaId", areaId)
    end
    self.lastSignature = signature

    -- A rebuild reassigns every pooled tile and marker, so hover state, which
    -- is per-quest, never carries over into the new layout. The held hover is
    -- re-resolved against the finished layout at the end of this pass.
    local heldHoverArea = self.hoverArea
    local heldFocusTurnIn = self.focusTurnInPin
    self.hoverArea = nil
    local clearIndex = 1
    local clearTotal = table.getn(self.pool)
    while clearIndex <= clearTotal do
        Client.SetWorldMapPinSuppressed(self.pool[clearIndex], false)
        clearIndex = clearIndex + 1
    end

    local markerIndex = 1
    local areaIndex = 1
    local matchedQuests = 0
    local candidateLocations = 0
    local pinFailures = 0
    -- Item-use targets withheld because the bags could not be read. Non-zero
    -- with a quest that has one means the container API, not the data, is what
    -- is keeping the target off the map.
    local itemUseUnknown = 0
    -- Resolved once per rebuild, not once per quest: the setting cannot change
    -- half way through a pass, and the signature above already forced this
    -- rebuild if it changed since the last one.
    local dotsMode = ObjectiveDotsEnabled()
    local quests = questState:GetOrderedQuests()
    local questIndex = 1
    local questTotal = table.getn(quests)

    -- Built once per refresh and reused by the giver pass below: a quest
    -- already in the player's log is never also "still to take".
    local activeQuestIds = {}
    while questIndex <= questTotal do
        local activeQuest = quests[questIndex]
        local activeIds = GetQuestMapIds(activeQuest)
        local activeIdIndex = 1
        local activeIdTotal = table.getn(activeIds)
        while activeIdIndex <= activeIdTotal do
            activeQuestIds[activeIds[activeIdIndex]] = true
            activeIdIndex = activeIdIndex + 1
        end
        questIndex = questIndex + 1
    end
    questIndex = 1

    -- A hidden quest stays fully active (activeQuestIds above is unaffected,
    -- so its giver never reappears as "still to take"); only its own area
    -- tiles and turn-in marker are withheld below.
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        local locations, unknown, usedIds = CollectQuestMapLocations(
            quest, areaId, quest and quest.isComplete == 1, rebuildConfig)
        if usedIds > 0 then
            matchedQuests = matchedQuests + 1
            local complete = quest.isComplete == 1
            itemUseUnknown = itemUseUnknown + unknown
            candidateLocations = candidateLocations + table.getn(locations)
            local components = questTarget:BuildComponents(locations)
            local markerComponent = MARKER_RENDER_ENABLED
                and questTarget:SelectPrimary(components)
            -- The main quest's tiles are drawn brighter than the rest, so the
            -- quest the HUD waypoint is pointing at can be identified on the
            -- map without hovering every area in the zone.
            local isMain = mainQuest and mainQuest:IsMain(quest.titleKey) or false
            -- Every tile this quest places lands in one contiguous run of pool
            -- slots, which is what lets the marker be handed back to them once
            -- it is known to have been placed.
            local questAreaFirst = areaIndex
            if dotsMode then
                -- One dot per raw spawn point, deduplicated by coordinate.
                -- These are the very points BuildComponents reduces to cells
                -- above; drawing them unreduced is the whole difference
                -- between the two presentations.
                local dotSeen = {}
                local locationIndex = 1
                local locationTotal = table.getn(locations)
                while AREA_RENDER_ENABLED and locationIndex <= locationTotal do
                    local location = locations[locationIndex]
                    local dotKey = tostring(location.x) .. ":" .. tostring(location.y)
                    if not dotSeen[dotKey] then
                        dotSeen[dotKey] = true
                        local dotX, dotY = mapContext:DatabaseToCurrentMap(
                            areaId, location.x, location.y, report)
                        if dotX and dotY then
                            local area = self:GetArea(areaIndex)
                            if area then
                                local r, g, b = ObjectiveColor(quest, complete, isMain, true)
                                ApplyObjectiveStyle(area, true)
                                Client.SetWorldMapAreaColor(area, r, g, b, DOT_ALPHA)
                                if Client.PositionWorldMapDot(area, dotX, dotY, ObjectiveDotSize()) then
                                    area.unrealQuestQuest = quest
                                    area.unrealQuestMarkerPin = nil
                                    areaIndex = areaIndex + 1
                                else
                                    pinFailures = pinFailures + 1
                                end
                            else
                                pinFailures = pinFailures + 1
                            end
                        end
                    end
                    locationIndex = locationIndex + 1
                end
            else
                local componentIndex = 1
                local componentTotal = table.getn(components)
                while componentIndex <= componentTotal do
                    local component = components[componentIndex]
                    local cellIndex = 1
                    local cellTotal = table.getn(component.cells)
                    while AREA_RENDER_ENABLED and cellIndex <= cellTotal do
                        local cell = component.cells[cellIndex]
                        local areaX, areaY = mapContext:DatabaseToCurrentMap(
                            areaId, cell.x, cell.y, report)
                        if areaX and areaY then
                            local area = self:GetArea(areaIndex)
                            if area then
                                local r, g, b, a = ObjectiveColor(quest, complete, isMain, false)
                                ApplyObjectiveStyle(area, false)
                                Client.SetWorldMapAreaColor(area, r, g, b, a)
                                if Client.PositionWorldMapArea(
                                    area, areaX, areaY,
                                    questTarget.CELL_PERCENT, questTarget.CELL_PERCENT) then
                                    area.unrealQuestQuest = quest
                                    area.unrealQuestMarkerPin = nil
                                    areaIndex = areaIndex + 1
                                else
                                    pinFailures = pinFailures + 1
                                end
                            else
                                pinFailures = pinFailures + 1
                            end
                        end
                        cellIndex = cellIndex + 1
                    end

                    componentIndex = componentIndex + 1
                end
            end

            local markerPin = nil
            if MARKER_RENDER_ENABLED and markerComponent and markerIndex <= MAX_MARKERS then
                local markerX, markerY = mapContext:DatabaseToCurrentMap(
                    areaId, markerComponent.x, markerComponent.y, report)
                if markerX and markerY then
                    local pin = self:GetPin(markerIndex)
                    if pin then
                        if complete then
                            Client.SetWorldMapPinColor(pin, 0.2, 1, 0.2)
                        else
                            Client.SetWorldMapPinColor(pin, 1, 0.75, 0.1)
                        end
                        local labeled = Client.SetWorldMapPinLabel(pin, questIndex)
                        if labeled and mapContext:PlaceOnWorldMap(pin, markerX, markerY) then
                            markerPin = pin
                            markerIndex = markerIndex + 1
                        else
                            Client.HideObject(pin)
                            pinFailures = pinFailures + 1
                        end
                    else
                        pinFailures = pinFailures + 1
                    end
                end
            end

            -- Which number a tile hides on hover, resolved only now that the
            -- marker is known to have been placed; a quest whose marker was
            -- capped or failed simply has nothing to hide.
            local assignIndex = questAreaFirst
            while assignIndex < areaIndex do
                self.areaPool[assignIndex].unrealQuestMarkerPin = markerPin
                assignIndex = assignIndex + 1
            end
        end
        questIndex = questIndex + 1
    end

    local giverMarkerIndex = 1
    -- The patrol set records successfully placed markers, not merely database
    -- candidates. A route therefore lives exactly as long as at least one
    -- visible "!" or "?" for its NPC, including a turn-in marker after the
    -- giver marker has disappeared.
    local visiblePatrolUnitIds = {}
    if database:IsGiverIndexReady() then
        local questHistory = QuestHistory()
        local eligibility = QuestEligibility()
        -- Once per pass, not once per giver: the player snapshot behind the
        -- race/class/level tests costs guarded client calls to build.
        if eligibility then
            eligibility:RefreshPlayer()
        end
        local givers = database:GetAreaQuestGivers(areaId, MAX_GIVER_LOCATIONS)
        local giverIndex = 1
        local giverTotal = table.getn(givers)
        while giverIndex <= giverTotal and giverMarkerIndex <= MAX_GIVER_MARKERS do
            local giver = givers[giverIndex]
            local availableQuestIds = {}
            local lowLevel = false
            if not eligibility or eligibility:MatchesGiverFaction(giver) then
                availableQuestIds, lowLevel = FilterAvailableQuestIds(
                    giver.questIds, activeQuestIds, questHistory, eligibility, rebuildConfig)
            end
            if table.getn(availableQuestIds) > 0 then
                local markerX, markerY = mapContext:DatabaseToCurrentMap(areaId, giver.x, giver.y, report)
                if markerX and markerY then
                    local pin = self:GetGiverPin(giverMarkerIndex)
                    if pin then
                        pin.unrealQuestGiver = giver
                        pin.unrealQuestAvailableQuestIds = availableQuestIds
                        pin.unrealQuestLowLevel = lowLevel
                        ApplyGiverAppearance(pin, lowLevel)
                        if mapContext:PlaceOnWorldMap(pin, markerX, markerY) then
                            if giver.sourceType == "unit" then
                                visiblePatrolUnitIds[giver.sourceId] = true
                            end
                            giverMarkerIndex = giverMarkerIndex + 1
                        else
                            Client.HideObject(pin)
                            pinFailures = pinFailures + 1
                        end
                    else
                        pinFailures = pinFailures + 1
                    end
                end
            end
            giverIndex = giverIndex + 1
        end
    end

    -- Turn-in "?" markers. This pass needs no readiness gate of its own: it
    -- walks the quest log, not the database, and every resolved or ambiguous
    -- candidate set it reads exists only after the title index is ready -- a
    -- condition Refresh checked above.
    local turnInMarkerIndex = 1
    local turnInPoints = CollectTurnInPoints(
        database, quests, areaId, ShowInProgressTurnIns(), rebuildConfig)
    local turnInIndex = 1
    local turnInTotal = table.getn(turnInPoints)
    while turnInIndex <= turnInTotal and turnInMarkerIndex <= MAX_TURNIN_MARKERS do
        local point = turnInPoints[turnInIndex]
        local markerX, markerY = mapContext:DatabaseToCurrentMap(areaId, point.x, point.y, report)
        if markerX and markerY then
            local pin = self:GetTurnInPin(turnInMarkerIndex)
            if pin then
                pin.unrealQuestTurnIn = point
                if point.complete then
                    Client.SetWorldMapPinTexture(pin, Client.COMPLETE_QUEST_TEXTURE)
                else
                    Client.SetWorldMapPinTexture(pin, Client.ACTIVE_QUEST_TEXTURE)
                end
                if mapContext:PlaceOnWorldMap(pin, markerX, markerY) then
                    if point.sourceType == "unit" then
                        visiblePatrolUnitIds[point.sourceId] = true
                    end
                    turnInMarkerIndex = turnInMarkerIndex + 1
                else
                    Client.HideObject(pin)
                    pinFailures = pinFailures + 1
                end
            else
                pinFailures = pinFailures + 1
            end
        end
        turnInIndex = turnInIndex + 1
    end

    -- Draw after both quest-marker passes so a moving quest ender keeps its
    -- route visible while the player is returning to it. Once the last marker
    -- for that NPC is filtered, capped or otherwise not placed, its unit ID is
    -- absent from the set and the path disappears on this same rebuild.
    local patrolSegments = self:CollectPatrolSegments(
        database, visiblePatrolUnitIds, areaId)
    local patrolTargetIndex, patrolFailures = self:DrawPatrolHoverTargets(
        mapContext, areaId, patrolSegments, report)
    pinFailures = pinFailures + patrolFailures
    -- The visible route over the same collected path. Drawn after the hit
    -- targets so it can read nothing they did not already establish.
    local patrolStrokeIndex, patrolStrokeFailures = self:DrawPatrolStrokes(
        mapContext, areaId, patrolSegments, report)
    pinFailures = pinFailures + patrolStrokeFailures

    self.visibleCount = HidePoolFrom(self.pool, markerIndex)
    self.areaVisibleCount = HidePoolFrom(self.areaPool, areaIndex)
    self.giverVisibleCount = HidePoolFrom(self.giverPool, giverMarkerIndex)
    self.patrolVisibleCount = HidePoolFrom(self.patrolPool, patrolTargetIndex)
    self.strokeVisibleCount = HidePoolFrom(self.strokePool, patrolStrokeIndex)
    self.turnInVisibleCount = HidePoolFrom(self.turnInPool, turnInMarkerIndex)

    -- Pooled markers change owner between rebuilds, so a focus held across one
    -- describes the wrong frames. Cleared here, then re-applied against the
    -- finished layout below.
    self:ApplyFocus(nil, nil)
    if heldFocusTurnIn and heldFocusTurnIn.unrealQuestTurnIn then
        -- Only if that pin is still one of the drawn "?"s: a pooled pin that
        -- fell out of the visible range keeps its last point, and focusing on
        -- it would dim the map around a marker nobody can see.
        local focusIndex = 1
        while focusIndex <= self.turnInVisibleCount do
            if self.turnInPool[focusIndex] == heldFocusTurnIn then
                self:ApplyTurnInFocus(heldFocusTurnIn)
                focusIndex = self.turnInVisibleCount
            end
            focusIndex = focusIndex + 1
        end
    end

    -- A hover held across the rebuild is re-applied against the new layout,
    -- rather than left with a stale tooltip and a number that came back under
    -- the cursor. A tile that fell out of the visible range loses its tooltip.
    if heldHoverArea then
        if type(heldHoverArea.unrealQuestPoolIndex) == "number"
            and heldHoverArea.unrealQuestPoolIndex < areaIndex
            and heldHoverArea.unrealQuestQuest then
            self:OnAreaEnter(heldHoverArea)
        else
            Client.HideMapTooltip(heldHoverArea)
        end
    end
    self.itemUseUnknown = itemUseUnknown
    -- The layer was just rewritten, so every visible marker is re-forced on
    -- every tick for the next few seconds before the sweep idles down.
    self:MarkSettling()
    -- "rendered" means the quest layer put something on the canvas. With the
    -- numbered markers retired the areas are that layer, so keying this on the
    -- marker pool alone would report every drawn map as empty.
    if self.visibleCount > 0 or self.areaVisibleCount > 0 then
        RecordDiagnostic("rendered", areaId, report, matchedQuests, candidateLocations, pinFailures)
    else
        RecordDiagnostic("noLocations", areaId, report, matchedQuests, candidateLocations, pinFailures)
    end
end

-- Shared with Map/MinimapPins.lua ------------------------------------------
--
-- The minimap draws the same scene at a different scale, and the one thing it
-- must not do is decide for itself which "!" is still worth visiting or where
-- a quest is handed in. Both answers are policy, not geometry: they fold in
-- the quest log, the observed history, eligibility and the map-hidden set. So
-- they are exported here rather than reimplemented there, and the two layers
-- can disagree about pixels but never about content.
--
-- These are thin wrappers over the locals above and hold no state of their
-- own; calling them does not disturb this layer's own refresh cycle.

-- Whether a quest has one resolved database identity. Ambiguous candidates
-- are intentionally false here even though CollectQuestLocations can draw
-- their union; identity-sensitive consumers must never confuse the two.
function WorldMapPins:IsResolvedQuest(quest)
    return IsResolvedQuest(quest)
end

-- The database IDs one live quest row may be DRAWN for: its own when it
-- resolved, the union of its same-title candidates when it is honestly
-- ambiguous. Public so a second spatial layer -- Map/QuestVendorPins.lua --
-- reads ambiguity the same way this one does instead of writing its own rule;
-- the identity warning on GetQuestMapIds applies to every caller.
function WorldMapPins:GetQuestMapIds(quest)
    return GetQuestMapIds(quest)
end

-- Quest IDs already in the player's log, which is what makes a giver's quest
-- "taken" rather than "still to take".
function WorldMapPins:BuildActiveQuestIds(quests)
    local active = {}
    local index = 1
    local total = table.getn(quests or {})
    while index <= total do
        local quest = quests[index]
        local ids = GetQuestMapIds(quest)
        local idIndex = 1
        local idTotal = table.getn(ids)
        while idIndex <= idTotal do
            active[ids[idIndex]] = true
            idIndex = idIndex + 1
        end
        index = index + 1
    end
    return active
end

-- Safe location set for map-like consumers. Ambiguous identity remains
-- unresolved everywhere else; only spatial renderers consume this union.
function WorldMapPins:CollectQuestLocations(quest, areaId, complete, config)
    return CollectQuestMapLocations(quest, areaId, complete, config)
end

-- Tooltip content is shared by the world map and minimap. Keeping these
-- builders here makes both surfaces describe the same quest, giver and
-- turn-in policy while each surface chooses its own tooltip frame.
function WorldMapPins:BuildQuestTooltipLines(quest)
    local database = Database()
    if not database or not quest then
        return nil
    end
    return BuildQuestTooltipLines(database, quest)
end

function WorldMapPins:BuildGiverTooltipLines(giver, questIds, suppressHint)
    local database = Database()
    if not database or not giver then
        return nil
    end
    return BuildGiverTooltipLines(database, giver, questIds or {}, suppressHint)
end

function WorldMapPins:BuildTurnInTooltipLines(point)
    local database = Database()
    if not database or not point then
        return nil
    end
    return BuildTurnInTooltipLines(database, point)
end

-- Givers in one area with at least one quest this character could take now.
-- The giver entity's own faction is a second eligibility gate: some bundled
-- Horde/Alliance quests omit a race mask even though the NPC is not usable by
-- the other faction.
-- Returns a list of { giver = <database giver>, questIds = <ordered ids> }.
function WorldMapPins:CollectAvailableGivers(database, quests, areaId, config, maxLocations)
    local givers = {}
    if not database or not database.IsGiverIndexReady or not database:IsGiverIndexReady() then
        return givers
    end
    local questHistory = QuestHistory()
    local eligibility = QuestEligibility()
    -- Once per pass, not once per giver: the player snapshot behind the
    -- race/class/level tests costs guarded client calls to build.
    if eligibility then
        eligibility:RefreshPlayer()
    end
    local activeQuestIds = self:BuildActiveQuestIds(quests)
    local source = database:GetAreaQuestGivers(areaId, maxLocations or MAX_GIVER_LOCATIONS)
    local index = 1
    local total = table.getn(source)
    while index <= total do
        local giver = source[index]
        if not eligibility or eligibility:MatchesGiverFaction(giver) then
            local availableQuestIds, lowLevel = FilterAvailableQuestIds(
                giver.questIds, activeQuestIds, questHistory, eligibility, config)
            if table.getn(availableQuestIds) > 0 then
                table.insert(givers, {
                    giver = giver,
                    questIds = availableQuestIds,
                    lowLevel = lowLevel,
                })
            end
        end
        index = index + 1
    end
    return givers
end

-- Where the quests currently in the log get handed in, in this area.
function WorldMapPins:CollectTurnIns(database, quests, areaId, config)
    return CollectTurnInPoints(database, quests, areaId, ShowInProgressTurnIns(), config)
end

function WorldMapPins:GetStatus()
    return {
        visible = self.visibleCount,
        pooled = table.getn(self.pool),
        areaVisible = self.areaVisibleCount,
        areaPooled = table.getn(self.areaPool),
        giverVisible = self.giverVisibleCount,
        giverPooled = table.getn(self.giverPool),
        patrolVisible = self.patrolVisibleCount,
        patrolStrokes = self.strokeVisibleCount,
        patrolStrokeWidth = self.strokeWidth,
        patrolPooled = table.getn(self.patrolPool),
        turnInVisible = self.turnInVisibleCount,
        turnInPooled = table.getn(self.turnInPool),
        inProgressTurnIns = ShowInProgressTurnIns(),
        areasEnabled = AREA_RENDER_ENABLED,
        objectiveDots = ObjectiveDotsEnabled(),
        markersEnabled = MARKER_RENDER_ENABLED,
        renderEnabled = self.renderEnabled,
        areaHovers = self.hoverCount or 0,
        giverHovers = self.giverHoverCount or 0,
        giverClicks = self.giverClickCount or 0,
        turnInHovers = self.turnInHoverCount or 0,
        rebuilds = self.rebuildCount or 0,
        itemUseUnknown = self.itemUseUnknown or 0,
        capped = self.visibleCount >= MAX_MARKERS
            or self.patrolVisibleCount >= MAX_PATROL_HOVER_TARGETS,
    }
end

function WorldMapPins:OnEnable()
    local state = QuestState()
    if state then
        state:AddListener(function()
            WorldMapPins.dirty = true
        end)
    end

    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.worldpins", REFRESH_INTERVAL, function()
            WorldMapPins:Refresh()
        end)
    end
    self.dirty = true
    self:MarkSettling()
    self:Refresh()
end
