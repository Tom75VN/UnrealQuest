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

Two quests that need the same creature draw their dots on the same spawn
coordinates, so those dots stack and only the top one can be hovered. One
hover therefore describes every quest colliding with it -- one block per
quest, headings tinted with each quest's own dot colour so a line can be
matched to a dot -- rather than letting the top frame answer for a dot the
player was not pointing at. Same radius, cap and mapClusterTooltips opt-out as
the giver/turn-in clusters; see CollectClusterQuests.

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

Clicking an objective dot/tile or a "?" hands that quest to the same
QuestClicks selection path as the tracker and quest-log Following button, so
the navigator changes without a second definition of following. A shared "?"
chooses the first ready quest it carries, or the first quest-log entry when
none is ready; every carried quest has the same turn-in coordinate.

Hovering anything that belongs to a quest asks the map two questions at once,
and it answers both without touching a single colour. WHERE does this quest
start and end: its "!" and "?" grow. WHICH of everything on screen is this
quest: every pin that is not fades to a quarter opacity -- this file's dots, tiles
and markers, plus the service/rare pins and the quest-vendor pins the other
two map layers draw. Nothing is hidden and no quest changes colour; the faded
half stays readable and simply stops competing. See RefreshFocusDim.

The followed quest's objective dots keep their stable per-quest colour and
dark inner outline, with a thin gold outer rim matching the navigation
presentation. Every other quest's dots remain unchanged. A followed turn-in
keeps its yellow/grey "?" inside the bundled followed-quest circle; that
supplied image is used nowhere else -- except by the hover below, which is the
same ring. When the FOLLOWED QUEST CHANGES, that circle arrives breathing rather
than simply existing -- three eased grow/shrink cycles, so the place the player
just asked about is findable among however many other pins are on screen. See
PulseFollowedTurnInRings.

Hovering ANY quest's objective dot marks that quest's own turn-in the same way,
with a single breath: the followed quest pulses the circle it already wears, and
any other quest is LENT one while its hover focus is held. A brief dwell filters
passing dots, and a one-second release grace bridges the gaps between dots of
the same quest without restarting the circle or flashing unrelated markers.
See RequestQuestFocus and ClearHoverTurnInRings. Borders are separate mouse-disabled
file-backed Buttons, so the proven single-BACKGROUND-texture contract remains
intact and the underlying object continues to own hover and click.

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
local OBJECTIVE_FOCUS_DWELL = 0.15
local OBJECTIVE_FOCUS_RELEASE = 1
local OBJECTIVE_FOCUS_POLL = 0.05
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
-- The rim is drawn at full channel strength on the brightest two components
-- so it separates from both the dot it surrounds and the map underneath it.
-- The hue is the same gold as before; only its contrast against the terrain
-- is raised.
local GOLD_BORDER_RED = 1
local GOLD_BORDER_GREEN = 0.86
local GOLD_BORDER_BLUE = 0.05
local DOT_BORDER_PADDING = 4
local OBJECTIVE_DOT_LEVEL_BOOST = 1
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

-- The route of ONE creature, drawn because the mouse is on something that
-- names it: a service, vendor or rare pin owned by another layer
-- (Map/NpcPins.lua, Map/QuestVendorPins.lua). It gets a pool of its own rather
-- than joining the scene above because it must appear and disappear with the
-- cursor, and re-fitting the whole scene's spacing on every OnEnter would
-- restamp up to MAX_PATROL_STROKES textures to add one route. One creature is
-- also a far smaller path than a zone's worth of them -- the widest bundled
-- single-unit route is 634 waypoints -- so this bound is the same guard
-- against a pathological record the scene's is, not a routine cap.
--
-- Hit targets are deliberately NOT laid along it: the pin under the cursor is
-- already answering the hover, and invisible Buttons over the route would
-- take the mouse away from whatever the player moves onto next.
local MAX_HOVER_PATROL_STROKES = 900

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
-- The 64x64 source is displayed just under two thirds of its own size: 38px
-- leaves the 14px turn-in marker clear inside the ring without letting the
-- glow overpower it, and reads as a ring around the "?" rather than a halo
-- sitting on it.
local FOLLOWED_TURNIN_RING_SIZE = 38
local FOLLOWED_TURNIN_LEVEL_BOOST = 2
-- media/icons/questIcon.tga is also 19x32. Keep the giver "!" at the
-- confirmed pin height without stretching its artwork into a square.
local GIVER_ICON_HEIGHT = 14
local GIVER_ICON_WIDTH = GIVER_ICON_HEIGHT * 19 / 32
-- Hovering one "!" or "?" grows it so the hovered marker reads as the one
-- under the mouse. Other markers keep their own size and opacity -- area
-- tiles are untouched too, they already have their own hover presentation.
local GIVER_TURNIN_HOVER_SCALE = 1.5
-- Hovering a quest surface -- an objective dot or tile, a "!" or a "?" --
-- also answers "which of these pins are the same quest's" by fading every pin
-- that is not one of them to this frame alpha. Colour still carries quest
-- identity and nothing is hidden: the unrelated half recedes rather than
-- disappearing, and stops competing with the half the cursor is asking about.
--
-- 0.25 is a CHOSEN strength, not a measured one, and it sits below the band
-- probes 1.29.0/1.30.0 established: 0.5 was confirmed visible for a tile on
-- this client and the first 0.2 run was confirmed INVISIBLE. Frame alpha also
-- multiplies whatever the texture already carries, so an area TILE (drawn at
-- 0.5 texture alpha) lands near 0.12 here and may read as gone rather than
-- faded, while an opaque objective DOT lands at 0.25. If a tile ever needs a
-- floor of its own, it belongs here as a second constant rather than as a
-- change to this one. The fade reaches the other map layers too
-- (Map/NpcPins.lua, Map/QuestVendorPins.lua), because "every marker not
-- related to this quest" has to mean every marker, not only the ones this
-- file owns.
local FOCUS_DIM_ALPHA = 0.25
local FOCUS_FULL_ALPHA = 1
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

-- `/uq nav` leaves one diagnostic marker at the navigator's exact selected
-- database coordinate. It is intentionally larger and higher than the normal
-- quest scene: this is a debug answer about which raw node won, not another
-- quest-state icon that should blend into the layer it is diagnosing.
local NAVIGATOR_DEBUG_PIN_SIZE = 18
local NAVIGATOR_DEBUG_LEVEL_BOOST = 8

WorldMapPins.pool = {}
WorldMapPins.areaPool = {}
WorldMapPins.dotBorderPool = {}
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
-- The hovered creature's own route (see MAX_HOVER_PATROL_STROKES). Same kind
-- of stamps on the same shared layer, kept apart from the scene above so a
-- hover neither restamps it nor survives it.
WorldMapPins.hoverStrokePool = {}
WorldMapPins.hoverStrokeX = {}
WorldMapPins.hoverStrokeY = {}
WorldMapPins.turnInPool = {}
WorldMapPins.followedTurnInPool = {}
-- The hover's own copy of that ring, for a quest that is not followed.
-- Kept apart from the pool above so a gesture can never leave a mark on
-- the scene; see GetHoverTurnInRing.
WorldMapPins.hoverTurnInRingPool = {}
-- Draw-cost census (probe) ---------------------------------------------------
--
-- GetTime does not advance inside a frame on this client -- it is "updated
-- each UI draw" -- so a pass cannot time itself, and debugprofilestop always
-- returns 1. What IS measurable is the gap to the NEXT driver tick, which
-- contains the previous pass's own cost: a rebuild that stalls the client for
-- a second shows up as a one-second gap before the tick that follows it. Every
-- gap is therefore charged to the pass that preceded it, and what that pass
-- did is carried across in lastPassKind.
--
-- One worst gap is not enough to attribute anything: the load screen after a
-- /reload is itself an eight-second gap, and it charges to whichever pass ran
-- before it. So the gaps are bucketed by what the preceding pass DID, and the
-- buckets that cannot be confounded are the ones read: "create" is a rebuild
-- that constructed frames (paid once, when the pool first fills), "rebuild" is
-- one that reused every frame, "reapply" is the per-tick sweep over the
-- finished scene, and "hover" is a tick whose frame also ran the cluster scan.
-- Passes that took an early return are not charged at all.
WorldMapPins.lastPassAt = nil
WorldMapPins.lastPassKind = nil
WorldMapPins.lastPassGap = 0
WorldMapPins.passGapWorst = {}
-- How many passes of each kind ran, and how many of those were followed by a
-- gap wider than the job's own interval plus a slow frame. The worst gap alone
-- names one pass; these say which KIND of pass is in the stutter, which is the
-- difference between "the sweep costs too much" and "the rebuild does".
WorldMapPins.passCount = {}
WorldMapPins.passSlow = {}
WorldMapPins.maxRebuildCreates = 0
-- Set by OnAreaEnter, cleared by the next tick: a cluster scan runs in the
-- mouse's frame, not the driver's, so without this its cost is charged to
-- whatever sweep happened to follow it.
WorldMapPins.hoverSinceTick = false
-- Frames this pass had to construct rather than reuse. The whole question the
-- census exists to answer is whether the stall is construction (paid once, on
-- the pass that first fills the pool) or the per-tick sweep over what was
-- built (paid forever).
WorldMapPins.areaCreates = 0
-- How many dots the three candidate reductions would draw for the same scene.
-- Counted, never applied: this pass still draws dotsDrawn.
WorldMapPins.dotCensus = nil

WorldMapPins.navigatorDebugPin = nil
WorldMapPins.navigatorDebugTarget = nil
WorldMapPins.navigatorDebugVisible = false
WorldMapPins.renderEnabled = true
WorldMapPins.visibleCount = 0
WorldMapPins.areaVisibleCount = 0
WorldMapPins.dotBorderVisibleCount = 0
WorldMapPins.giverVisibleCount = 0
WorldMapPins.patrolVisibleCount = 0
WorldMapPins.strokeVisibleCount = 0
-- The width the current scene's stamps were drawn at. Set by the draw pass
-- and read by everything that restyles or re-places a stamp afterwards, so a
-- hover or a canvas resize cannot silently reset a widened line back to the
-- floor and reopen the gaps.
WorldMapPins.strokeWidth = PATROL_LINE_WIDTH
WorldMapPins.hoverStrokeVisibleCount = 0
WorldMapPins.hoverStrokeWidth = PATROL_LINE_WIDTH
-- The creature another layer's hovered pin names, and the units the scene
-- already draws a route for. The second answers whether the first needs a
-- stroke of its own or merely the scene's own highlight.
WorldMapPins.hoverPatrolUnitId = nil
WorldMapPins.patrolSceneUnitIds = {}
WorldMapPins.turnInVisibleCount = 0
WorldMapPins.followedTurnInVisibleCount = 0
WorldMapPins.hoverTurnInRingVisibleCount = 0
-- The followed quest the turn-in ring was last drawn for, and the clock the
-- ring's arrival pulse started on. The key is what tells a followed-quest
-- CHANGE apart from a redraw of the same one.
WorldMapPins.followedRingQuestKey = nil
WorldMapPins.followedRingPulseStart = nil
-- How many grow/shrink cycles the run in flight was asked for: three for the
-- followed quest's arrival, one for an objective hover.
WorldMapPins.followedRingPulseCycles = nil
WorldMapPins.dirty = true
-- Quest-model changes received while the fullscreen map is not presented are
-- held here. They are folded into one rebuild when the map next opens instead
-- of repainting a hidden scene after every progress event.
WorldMapPins.pendingSceneDirty = false
WorldMapPins.progressOnlyUpdates = 0
WorldMapPins.relevantBagItemIds = {}
WorldMapPins.lastBagSignature = nil
WorldMapPins.lastSignature = nil
WorldMapPins.canvasDetected = false
WorldMapPins.lastDiagnosticKey = nil
WorldMapPins.lastSnapshotKey = nil
WorldMapPins.hoverArea = nil
WorldMapPins.hoverFocusOwner = nil
WorldMapPins.focusQuest = nil
WorldMapPins.focusTurnInPin = nil
WorldMapPins.focusGiverPin = nil
-- Whether the last focus pass left anything faded. The whole pool walk is
-- skipped while this is false and no focus is held, which is the resting
-- state of a map nobody is pointing at.
WorldMapPins.focusDimApplied = false
WorldMapPins.hoverMarkerPin = nil
WorldMapPins.hoverPatrolMarker = nil
WorldMapPins.hoverPatrolTarget = nil
-- The exact creature source carried by the objective dot under the cursor.
-- Area tiles reduce several locations into one cell and deliberately leave
-- this nil; only a dot can identify one source honestly enough to highlight
-- that creature's already-visible patrol.
WorldMapPins.hoverObjectivePatrolUnitId = nil
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

local function ObjectiveMatch()
    return UQ:GetModule("ObjectiveMatch")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

local function QuestClicks()
    return UQ:GetModule("QuestClicks")
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

-- Every early return in Refresh calls this, and Refresh runs four times a
-- second, so without the guard a map sitting on a continent view -- or a probe
-- isolation switch, or a database not yet indexed -- walks every pooled frame
-- in the addon 240 times a minute to hide things that are already hidden.
-- Cleared by the rebuild below, which is the only thing that shows any of them.
local function HideAllPools()
    WorldMapPins:CancelQuestFocusRequest()
    if WorldMapPins.poolsHidden then
        return
    end
    WorldMapPins.poolsHidden = true
    WorldMapPins.visibleCount = HidePoolFrom(WorldMapPins.pool, 1)
    WorldMapPins.areaVisibleCount = HidePoolFrom(WorldMapPins.areaPool, 1)
    WorldMapPins.dotBorderVisibleCount = HidePoolFrom(WorldMapPins.dotBorderPool, 1)
    WorldMapPins.giverVisibleCount = HidePoolFrom(WorldMapPins.giverPool, 1)
    WorldMapPins.patrolVisibleCount = HidePoolFrom(WorldMapPins.patrolPool, 1)
    WorldMapPins.strokeVisibleCount = HidePoolFrom(WorldMapPins.strokePool, 1)
    WorldMapPins.hoverStrokeVisibleCount = HidePoolFrom(WorldMapPins.hoverStrokePool, 1)
    WorldMapPins.turnInVisibleCount = HidePoolFrom(WorldMapPins.turnInPool, 1)
    WorldMapPins.followedTurnInVisibleCount = HidePoolFrom(
        WorldMapPins.followedTurnInPool, 1)
    WorldMapPins.hoverTurnInRingVisibleCount = HidePoolFrom(
        WorldMapPins.hoverTurnInRingPool, 1)
    if WorldMapPins.navigatorDebugPin then
        Client.HideObject(WorldMapPins.navigatorDebugPin)
    end
    WorldMapPins.navigatorDebugVisible = false
    -- A hidden frame receives no OnLeave, so a focus held while the layer goes
    -- away would keep the other layers faded with nothing left to arrive and
    -- clear it.
    if WorldMapPins.hoverFocusOwner then
        Client.HideMapTooltip(WorldMapPins.hoverFocusOwner)
    end
    WorldMapPins.hoverArea = nil
    WorldMapPins.hoverFocusOwner = nil
    WorldMapPins.hoverObjectivePatrolUnitId = nil
    WorldMapPins:ApplyFocus(nil, nil, nil)
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
-- The same sweep while the map is NOT on screen. It exists to put children
-- back through the map's draw path after the fullscreen map redraws over them;
-- with the map closed there is no such redraw and nothing to force, so the walk
-- over every pooled frame buys nothing. That walk was the addon's whole
-- stutter: 988 objective dots re-placed once a second put map.worldpins in
-- fifty of the fifty-five frames over 50ms in a two-minute sample, while it ran
-- in only ninety-eight of 2065 frames.
--
-- It is slowed rather than stopped, because the test for "on screen" is the
-- game UI being hidden, which is what the fullscreen map does here but is not a
-- probe result. If that test is ever wrong, the layer still repairs itself
-- within this interval instead of staying stale forever.
local OFFSCREEN_REAPPLY_INTERVAL = 10

-- The relevant-bag signature beside the view below exists because an item-use
-- objective target is drawn only while its own item is carried. It deliberately
-- excludes every other bag item: ordinary loot cannot change this scene and
-- must not rebuild hundreds of hidden map pins.
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

local function ProfessionSignature()
    local eligibility = UQ:GetModule("QuestEligibility")
    return eligibility and eligibility:ProfessionSignature() or ""
end

local function ViewSignature(areaId, report)
    return tostring(areaId) .. "|" .. tostring(report and report.mapFile)
        .. "|" .. tostring(report and report.continent)
        .. "|" .. tostring(report and report.zoneIndex)
        -- The presentation is part of the view: switching between areas and
        -- dots changes every objective frame's texture, size and placement,
        -- and a signature that ignored it would leave the old shape on screen
        -- until something else happened to dirty the layer.
        .. "|" .. tostring(ObjectiveDotsEnabled())
        .. "|" .. tostring(ObjectiveDotSize())
        .. "|" .. tostring(LowLevelQuestsEnabled())
        .. "|" .. ProfessionSignature()
end

local function RelevantBagSignature(itemIds)
    local bagItems = BagItems()
    if not bagItems then
        return nil
    end
    return bagItems:GetTokenFor(itemIds)
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

-- A unique roaming target is represented in the bundled unit table by several
-- sampled patrol coordinates. Drawing every sample as an objective dot makes
-- one creature look like a pack and, because the route gate sees several
-- locations, also withholds the path that explains where the creature moves.
--
-- The live objective supplies the missing distinction. A source is collapsed
-- only when every unfinished line it can satisfy for this quest needs exactly
-- one result, and an item line is a guaranteed drop. The world data must also
-- attach exactly one drawable route: several routes mean several spawned
-- creatures, where the full objective cloud remains the honest answer.
--
-- The representative is the medoid -- the recorded point nearest the average
-- of this source's locations -- so the one retained dot is always somewhere
-- the data actually places the creature. This is the same rule the
-- Rare/Elite/Boss map row uses for roaming creatures.
local function CollapseSingleTargetPatrols(quest, areaId, locations)
    local database = Database()
    local objectiveMatch = ObjectiveMatch()
    if not quest or not database or not objectiveMatch
        or table.getn(locations) < 2 then
        return locations
    end

    local groups = {}
    local index = 1
    local total = table.getn(locations)
    while index <= total do
        local location = locations[index]
        if location and location.sourceType == "unit"
            and type(location.sourceId) == "number"
            and type(location.x) == "number" and type(location.y) == "number" then
            local group = groups[location.sourceId]
            if not group then
                group = { locations = {}, sumX = 0, sumY = 0 }
                groups[location.sourceId] = group
            end
            table.insert(group.locations, location)
            group.sumX = group.sumX + location.x
            group.sumY = group.sumY + location.y
        end
        index = index + 1
    end

    local replacements = {}
    local replacementCount = 0
    local unitId, group
    for unitId, group in pairs(groups) do
        local groupTotal = table.getn(group.locations)
        if groupTotal > 1 then
            local unitKey = UQ.NameKey(database:GetUnitName(unitId))
            local matches = unitKey and objectiveMatch:FindForUnit(unitKey)
            local singleTarget = false
            local safe = matches ~= nil
            local matchIndex = 1
            local matchTotal = matches and table.getn(matches) or 0
            while matchIndex <= matchTotal do
                local objective = matches[matchIndex]
                if objective.quest == quest and not objective.finished then
                    singleTarget = true
                    if objective.need ~= 1
                        or (objective.fromDatabase
                            and (type(objective.dropRate) ~= "number"
                                or objective.dropRate < 100)) then
                        safe = false
                    end
                end
                matchIndex = matchIndex + 1
            end

            local routes = safe and singleTarget
                and database:GetUnitPatrolRoutes(unitId, areaId) or nil
            local route = routes and table.getn(routes) == 1 and routes[1] or nil
            if route and type(route.points) == "table"
                and table.getn(route.points) > 1 then
                local centreX = group.sumX / groupTotal
                local centreY = group.sumY / groupTotal
                local best = nil
                local bestDistance = nil
                local pointIndex = 1
                while pointIndex <= groupTotal do
                    local point = group.locations[pointIndex]
                    local dx = point.x - centreX
                    local dy = point.y - centreY
                    local distance = dx * dx + dy * dy
                    if bestDistance == nil or distance < bestDistance then
                        best = point
                        bestDistance = distance
                    end
                    pointIndex = pointIndex + 1
                end
                replacements[unitId] = best
                replacementCount = replacementCount + 1
            end
        end
    end

    if replacementCount == 0 then
        return locations
    end

    local collapsed = {}
    local inserted = {}
    index = 1
    while index <= total do
        local location = locations[index]
        local unitId = location and location.sourceType == "unit"
            and location.sourceId or nil
        local replacement = unitId and replacements[unitId] or nil
        if replacement then
            if not inserted[unitId] then
                inserted[unitId] = true
                table.insert(collapsed, replacement)
            end
        else
            table.insert(collapsed, location)
        end
        index = index + 1
    end
    return collapsed
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
    return CollapseSingleTargetPatrols(quest, areaId, locations), unknown, usedIds
end

-- The creatures a quest sends the player after that the map can honestly draw
-- a route for: the ones with exactly ONE drawn location in this zone.
--
-- Most reach this state because the data records one spawn. The singleton
-- patrol reduction above also turns a route's sampled coordinates into one
-- honest representative dot when the live quest proves one kill completes the
-- step. A creature type with several spawned routes remains a cloud and gets
-- no route, so the Bloodscalp Mystic case still cannot carpet Stranglethorn.
--
-- Counted from the quest's own drawn locations rather than from the unit
-- record, so a source whose other spawns were withheld -- a finished creature
-- objective, an item-use target the player is not carrying -- is counted as
-- the map actually drew it.
local function CollectRoamingObjectiveUnits(locations, unitIds)
    local counts = {}
    local index = 1
    local total = table.getn(locations)
    while index <= total do
        local location = locations[index]
        if location and location.sourceType == "unit"
            and type(location.sourceId) == "number" then
            counts[location.sourceId] = (counts[location.sourceId] or 0) + 1
        end
        index = index + 1
    end
    local unitId, count
    for unitId, count in pairs(counts) do
        if count == 1 then
            unitIds[unitId] = true
        end
    end
end

-- Read-only: callers must not mutate the returned table.
function WorldMapPins:GetDefaultHiddenQuestIds()
    return DEFAULT_HIDDEN_QUEST_IDS
end

function WorldMapPins:IsQuestHidden(questId, config)
    return IsQuestMapHidden(config, questId)
end

-- The local resolver above, published for the layers that must draw from the
-- same set this one does: Map/QuestVendorPins.lua (which already deferred to
-- this name) and Map/QuestZonePresence.lua, which answers "does the map show
-- anything for this quest here" and would otherwise have to re-derive what an
-- ambiguous row is allowed to show. Read-only: the returned table is freshly
-- built per call, but callers must treat its IDs as candidates rather than as
-- a proven identity, exactly as the tiles do.
function WorldMapPins:GetQuestMapIds(quest)
    return GetQuestMapIds(quest)
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
-- Remembers a second quest that wants a dot already drawn for a first one.
-- Two quests on the same spawn used to cost two frames stacked exactly on top
-- of each other, of which only one was ever visible; the loser is recorded
-- here instead so the tooltip still names it. Deduplicated by titleKey, which
-- is also what CollectClusterQuests keys its own set on.
local function AppendSharedQuest(area, quest)
    if not area or not quest or not quest.titleKey then
        return
    end
    local owner = area.unrealQuestQuest
    if owner and owner.titleKey == quest.titleKey then
        return
    end
    local shared = area.unrealQuestSharedQuests
    if not shared then
        shared = {}
        area.unrealQuestSharedQuests = shared
    end
    local index = 1
    local total = table.getn(shared)
    while index <= total do
        if shared[index].titleKey == quest.titleKey then
            return
        end
        index = index + 1
    end
    table.insert(shared, quest)
end

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

local function PointFollowedQuest(point, mainQuest)
    if not point or not point.quests or not mainQuest then
        return nil
    end
    local index = 1
    local total = table.getn(point.quests)
    while index <= total do
        local quest = point.quests[index]
        if quest and mainQuest:IsMain(quest.titleKey) then
            return quest
        end
        index = index + 1
    end
    return nil
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
--
-- The title colour is an argument rather than a constant only so a tooltip
-- carrying SEVERAL quests can tint each heading with that quest's own dot
-- colour (see BuildObjectiveTooltipLines). Left out, the heading stays the
-- gold every other map tooltip in this file uses.
local function BuildQuestTooltipLines(database, quest, titleRed, titleGreen, titleBlue)
    local lines = {}
    local title = UQ.GetQuestDisplayTitle(quest)
    table.insert(lines, {
        text = title or UQ.L("COMMON_UNKNOWN"),
        r = titleRed or 1, g = titleGreen or 0.82, b = titleBlue or 0,
    })

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

function WorldMapPins:GetNavigatorDebugPin()
    if self.navigatorDebugPin then
        return self.navigatorDebugPin
    end
    local pin = Client.CreateWorldMapPin("NavigatorDebug", 1, 0.15, 0.85)
    if not pin then
        return nil
    end
    Client.SetWorldMapPinSize(pin, NAVIGATOR_DEBUG_PIN_SIZE,
        NAVIGATOR_DEBUG_PIN_SIZE)
    Client.RaiseWorldMapPin(pin, NAVIGATOR_DEBUG_LEVEL_BOOST)
    Client.SetWorldMapPinLabel(pin, "N")
    self.navigatorDebugPin = pin
    return pin
end

-- Stores the raw point rather than a map-frame offset. The marker therefore
-- survives opening the map after the command and is shown only when that
-- point's own area is the map being viewed.
function WorldMapPins:SetNavigatorDebugTarget(areaId, x, y, kind, title)
    if type(areaId) ~= "number" or type(x) ~= "number" or type(y) ~= "number"
        or x < 0 or x > 100 or y < 0 or y > 100 then
        self.navigatorDebugTarget = nil
        if self.navigatorDebugPin then
            Client.HideObject(self.navigatorDebugPin)
        end
        self.navigatorDebugVisible = false
        return false
    end
    self.navigatorDebugTarget = {
        areaId = areaId,
        x = x,
        y = y,
        kind = kind,
        title = title,
    }
    self.dirty = true
    self:MarkSettling()
    self:Refresh()
    return self.navigatorDebugVisible
end

function WorldMapPins:DrawNavigatorDebugTarget(mapContext, areaId, report)
    local target = self.navigatorDebugTarget
    if not target or target.areaId ~= areaId then
        if self.navigatorDebugPin then
            Client.HideObject(self.navigatorDebugPin)
        end
        self.navigatorDebugVisible = false
        return false
    end
    local x, y = mapContext:DatabaseToCurrentMap(
        areaId, target.x, target.y, report)
    local pin = x and y and self:GetNavigatorDebugPin()
    if not pin then
        self.navigatorDebugVisible = false
        return false
    end
    Client.SetWorldMapPinColor(pin, 1, 0.15, 0.85)
    self.navigatorDebugVisible = mapContext:PlaceOnWorldMap(pin, x, y)
        and true or false
    if not self.navigatorDebugVisible then
        Client.HideObject(pin)
    end
    return self.navigatorDebugVisible
end

-- Area tiles carry the same once-per-frame mouse scripts as the giver pins,
-- attached at creation for the same reason (Core/Driver.lua records freshly
-- allocated per-tick closures as a measured stuttering hazard). The quest a
-- tile currently belongs to is refreshed as a plain field write below.
--
-- Making the tiles mouse-aware does mean they consume clicks that would
-- otherwise reach WorldMapButton. They use that click to follow their quest
-- and are only ever drawn on a zone map, never on a continent view, so
-- zone-to-zone navigation is untouched.
function WorldMapPins:GetArea(index)
    local area = self.areaPool[index]
    if area then
        return area
    end
    area = Client.CreateWorldMapArea(
        index, 0.15, 0.55, 1, AREA_ALPHA, "Objective")
    if area then
        self.areaCreates = (self.areaCreates or 0) + 1
        self.areaPool[index] = area
        area.unrealQuestPoolIndex = index
        Client.SetWorldMapPinHandlers(area,
            function() WorldMapPins:OnAreaEnter(area) end,
            function() WorldMapPins:OnAreaLeave(area) end,
            function() WorldMapPins:OnAreaClick(area) end)
    end
    return area
end

function WorldMapPins:GetDotBorder(index)
    local border = self.dotBorderPool[index]
    if border then
        return border
    end
    border = Client.CreateWorldMapPin("ObjectiveBorder" .. tostring(index),
        GOLD_BORDER_RED, GOLD_BORDER_GREEN, GOLD_BORDER_BLUE)
    if border then
        self.dotBorderPool[index] = border
        -- The dot artwork's outer pixels are black, so tinting a larger copy
        -- cannot make the reference's bright gold contour. This companion
        -- texture keeps the same alpha silhouette with white colour pixels;
        -- the tint therefore becomes gold while the original dot above it
        -- preserves its coloured centre and dark inner outline.
        Client.SetWorldMapPinTexture(
            border, Client.FOLLOWED_QUEST_DOT_BORDER_TEXTURE)
        Client.SetWorldMapPinColor(
            border, GOLD_BORDER_RED, GOLD_BORDER_GREEN, GOLD_BORDER_BLUE)
        Client.SetWorldMapPinMouseEnabled(border, false)
    end
    return border
end

function WorldMapPins:GetFollowedTurnInRing(index)
    local ring = self.followedTurnInPool[index]
    if ring then
        -- Reassert on pooled reuse so no stale frame or texture state can
        -- multiply the TGA's own alpha channel.
        Client.SetWorldMapPinFullOpacity(ring)
        return ring
    end
    ring = Client.CreateWorldMapPin("FollowedTurnIn" .. tostring(index), 1, 1, 1)
    if ring then
        self.followedTurnInPool[index] = ring
        Client.SetWorldMapPinTexture(ring, Client.FOLLOWED_QUEST_CIRCLE_TEXTURE)
        Client.SetWorldMapPinFullOpacity(ring)
        Client.SetWorldMapPinPixelAligned(ring, true)
        Client.SetWorldMapPinMouseEnabled(ring, false)
        -- Above objective dots, below the '?' itself.
        Client.RaiseWorldMapPin(ring, FOLLOWED_TURNIN_LEVEL_BOOST)
        Client.SetWorldMapPinSize(
            ring, FOLLOWED_TURNIN_RING_SIZE, FOLLOWED_TURNIN_RING_SIZE)
    end
    return ring
end

-- The SAME ring, for a quest that is not followed -- and it exists only while
-- the cursor is on that quest.
--
-- The followed pool above answers a state: this quest is the one being
-- followed, so its turn-in wears a ring for as long as that is true. This pool
-- answers a gesture: the mouse is on this quest's objective RIGHT NOW, and the
-- ring is the reply. It gets a pool of its own rather than joining the one
-- above for the same reason the hovered creature's patrol route does: the
-- scene's pool is rebuilt from quest state, and folding a hover into it would
-- make a transient answer look like a permanent one -- and leave the wrong
-- rings on screen the moment the hover ended.
--
-- Its lifetime is therefore the hover's, exactly: shown by ShowHoverTurnInRings
-- and hidden by HideHoverTurnInRings, never by the draw pass.
function WorldMapPins:GetHoverTurnInRing(index)
    local ring = self.hoverTurnInRingPool[index]
    if ring then
        Client.SetWorldMapPinFullOpacity(ring)
        return ring
    end
    ring = Client.CreateWorldMapPin("HoverTurnIn" .. tostring(index), 1, 1, 1)
    if ring then
        self.hoverTurnInRingPool[index] = ring
        Client.SetWorldMapPinTexture(ring, Client.FOLLOWED_QUEST_CIRCLE_TEXTURE)
        Client.SetWorldMapPinFullOpacity(ring)
        Client.SetWorldMapPinPixelAligned(ring, true)
        Client.SetWorldMapPinMouseEnabled(ring, false)
        Client.RaiseWorldMapPin(ring, FOLLOWED_TURNIN_LEVEL_BOOST)
        Client.SetWorldMapPinSize(
            ring, FOLLOWED_TURNIN_RING_SIZE, FOLLOWED_TURNIN_RING_SIZE)
    end
    return ring
end

-- Forces every visible production pool and the optional navigator debug pin
-- back through the map's draw path, at the cadence described at SETTLE_SECONDS above. A canvas that
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
    -- Opening the map is the moment the sweep matters most, so the transition
    -- into it re-opens the full-rate window rather than waiting for whatever
    -- the interval below happens to allow.
    local hidden = Client.IsGameUIHidden()
    if hidden and self.lastGameUIHidden == false then
        self:MarkSettling()
        force = true
    end
    self.lastGameUIHidden = hidden
    if force and not resized and hidden == false and now and self.lastReapply
        and now - self.lastReapply < OFFSCREEN_REAPPLY_INTERVAL then
        force = false
    end
    if not force then
        return
    end
    self.lastReapply = now
    Client.ReapplyWorldMapPins(self.pool, self.visibleCount)
    Client.ReapplyWorldMapPins(self.areaPool, self.areaVisibleCount)
    Client.ReapplyWorldMapPins(self.dotBorderPool, self.dotBorderVisibleCount)
    Client.ReapplyWorldMapPins(self.giverPool, self.giverVisibleCount)
    Client.ReapplyWorldMapPins(self.patrolPool, self.patrolVisibleCount)
    Client.ReapplyWorldMapPins(self.turnInPool, self.turnInVisibleCount)
    Client.ReapplyWorldMapPins(
        self.followedTurnInPool, self.followedTurnInVisibleCount)
    Client.ReapplyWorldMapPins(
        self.hoverTurnInRingPool, self.hoverTurnInRingVisibleCount)
    if self.navigatorDebugVisible and self.navigatorDebugPin then
        Client.ReapplyWorldMapPin(self.navigatorDebugPin)
    end
    -- The stamps cost nothing here in the ordinary case: they hang off one
    -- layer frame, so re-anchoring and re-showing that frame carries all of
    -- them back through the map's draw path. Their own offsets are only
    -- invalidated by a canvas that changed size, and that is the one case
    -- that walks the pool.
    if self.strokeVisibleCount > 0 or self.hoverStrokeVisibleCount > 0 then
        Client.ReapplyWorldMapStrokeLayer()
        if resized then
            self:ReapplyPatrolStrokes()
            self:ReapplyHoverPatrolStrokes()
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

-- Objective dots belonging to DIFFERENT quests routinely land on the very same
-- coordinate. Two quests that need the same creature collect the same spawn
-- points -- Goretusk Liver Pie and Westfall Stew both hunt Westfall's boars --
-- and each quest deduplicates its dots only against its own (see the dotSeen
-- table in the render pass), so the two dots stack exactly and whichever frame
-- the pool placed last takes every OnEnter. The reported symptom was a yellow
-- dot answering with the red quest's tooltip, which reads as one quest having
-- two colours rather than as two quests sharing one spawn.
--
-- The fix is the one the giver and turn-in pools already use for markers a few
-- pixels apart: stop fighting for a pixel the player cannot hit and let one
-- hover describe everything colliding with it. Same radius, same cap, same
-- opt-out (mapClusterTooltips).
--
-- Deduplicated by QUEST rather than by frame: one quest owns many dots and
-- several of them can fall inside the cluster radius, which would otherwise
-- repeat that quest's block. A quest counts as seen the moment it is found, so
-- the omitted tally counts distinct quests and not leftover dots.
function WorldMapPins:CollectClusterQuests(area)
    local hovered = area and area.unrealQuestQuest
    if not hovered then
        return {}, 0
    end
    local quests = { hovered }
    if not ClusterTooltipsEnabled() then
        return quests, 0
    end
    if type(area.unrealQuestMapX) ~= "number"
        or type(area.unrealQuestMapY) ~= "number" then
        return quests, 0
    end
    local width, height = Client.GetWorldMapCanvasSize()
    if not width or not height then
        return quests, 0
    end
    local seen = {}
    if hovered.titleKey then
        seen[hovered.titleKey] = true
    end
    local omitted = 0
    local index = 1
    -- Quests that wanted this exact spawn and did not get a frame of their own
    -- (see AppendSharedQuest). They come first, before the radius scan: they
    -- are not merely near the cursor, they ARE the point under it, so if the
    -- entry limit has to drop somebody it should be a neighbour rather than
    -- one of these.
    local shared = area.unrealQuestSharedQuests
    local sharedTotal = shared and table.getn(shared) or 0
    while index <= sharedTotal do
        local sharedQuest = shared[index]
        if sharedQuest and sharedQuest.titleKey and not seen[sharedQuest.titleKey] then
            seen[sharedQuest.titleKey] = true
            if table.getn(quests) < MAX_CLUSTER_ENTRIES then
                table.insert(quests, sharedQuest)
            else
                omitted = omitted + 1
            end
        end
        index = index + 1
    end
    index = 1
    -- Visible frames only: a pooled dot that fell out of the scene on the last
    -- rebuild keeps its stale map fractions, exactly as AppendNearbyPins notes.
    local total = self.areaVisibleCount or 0
    while index <= total do
        local other = self.areaPool[index]
        local quest = other and other.unrealQuestQuest
        if quest and quest.titleKey and not seen[quest.titleKey]
            and type(other.unrealQuestMapX) == "number"
            and type(other.unrealQuestMapY) == "number" then
            local dx = (other.unrealQuestMapX - area.unrealQuestMapX) * width
            local dy = (other.unrealQuestMapY - area.unrealQuestMapY) * height
            if dx * dx + dy * dy <= CLUSTER_RADIUS_PIXELS * CLUSTER_RADIUS_PIXELS then
                seen[quest.titleKey] = true
                if table.getn(quests) < MAX_CLUSTER_ENTRIES then
                    table.insert(quests, quest)
                else
                    omitted = omitted + 1
                end
            end
        end
        index = index + 1
    end
    return quests, omitted
end

-- One block per quest, separated the same way several quests on a single giver
-- already are, so a shared spawn reads as more of the same list rather than as
-- a different kind of tooltip. The hovered quest stays first: the tooltip is
-- still about the dot under the cursor, and its title is still the line the
-- client turns into the heading.
--
-- Headings take their own dot colour ONLY once the tooltip carries more than
-- one quest. That is the single case where the player has to match a line to a
-- dot, and it is what the colour is for; a lone tooltip keeps the gold heading
-- every other map tooltip uses. Area tiles have no per-quest colour to match
-- against, so the tint is offered in dot mode alone.
function WorldMapPins:BuildObjectiveTooltipLines(database, area)
    local quests, omitted = self:CollectClusterQuests(area)
    local total = table.getn(quests)
    local tinted = total > 1 and ObjectiveDotsEnabled()
    local lines = nil
    local index = 1
    while index <= total do
        local quest = quests[index]
        local red, green, blue
        if tinted then
            red, green, blue = UQ.GetQuestColor(quest)
        end
        local block = BuildQuestTooltipLines(database, quest, red, green, blue)
        if not lines then
            lines = block
        else
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
    if lines and omitted > 0 then
        table.insert(lines, { separator = true })
        table.insert(lines, {
            text = UQ.LN("MAP_MORE_QUESTS", omitted),
            r = 0.5, g = 0.5, b = 0.5,
        })
    end
    return lines
end

function WorldMapPins:OnAreaEnter(area)
    -- Charges this frame's cost to the hover bucket, not to the sweep that
    -- happens to follow it. See the census block near the pools.
    self.hoverSinceTick = true
    local database = Database()
    local quest = area and area.unrealQuestQuest
    if not database or not quest then
        return
    end
    self.hoverArea = area
    self.hoverFocusOwner = area
    self.hoverObjectivePatrolUnitId = area.unrealQuestObjectiveUnitId
    self:SetMarkerSuppressed(area.unrealQuestMarkerPin, true)
    self:RequestQuestFocus(quest)
    -- RequestQuestFocus keeps focus while crossing dots of the same quest,
    -- but those dots can name different creatures. Restyle the route for the
    -- exact dot even when the broader quest focus did not change.
    self:RefreshPatrolHighlight()
    Client.ShowMapTooltip(area, self:BuildObjectiveTooltipLines(database, area))
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
    -- before this OnLeave, and dropping the focus unconditionally would shrink
    -- the linked quest marker between two cells of one quest.
    self.hoverObjectivePatrolUnitId = hovered and hovered.unrealQuestObjectiveUnitId or nil
    if self.hoverFocusOwner == area then
        self.hoverFocusOwner = nil
        self:RequestQuestFocus(nil)
    end
    self:RefreshPatrolHighlight()
    -- Guarded by the tooltip's own owner check, so this cannot pull a tooltip
    -- that a neighbouring tile has already taken over.
    Client.HideMapTooltip(area)
end

function WorldMapPins:FollowQuest(quest, origin)
    if not quest or not quest.titleKey or not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        return false
    end
    local clicks = QuestClicks()
    if not clicks then
        return false
    end
    local changed = clicks:Select(quest, origin)
    return changed and true or false
end

function WorldMapPins:OnAreaClick(area)
    return self:FollowQuest(area and area.unrealQuestQuest, "worldMapObjective")
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

-- Hover focus controls marker emphasis, unrelated-pin opacity and turn-in
-- rings. Tooltips and objective colours are independent of its timing.
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
-- A hovered "!" is the one focus source that has no quest TABLE to offer: the
-- quests it still hands out are, by definition, not in the player's log, so
-- they exist here only as the database IDs CollectAvailableGivers indexed. The
-- focus therefore carries both forms, and everything that asks whether a pin
-- is related checks whichever of the two it can answer with.
local focusQuestIds = {}
local focusQuestIdCount = 0

local function SetFocusQuests(quest, point, giverIds)
    focusQuestIdCount = 0
    if type(giverIds) == "table" then
        local idTotal = table.getn(giverIds)
        local idIndex = 1
        while idIndex <= idTotal do
            focusQuestIds[idIndex] = giverIds[idIndex]
            idIndex = idIndex + 1
        end
        focusQuestIdCount = idTotal
    end
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

local function FocusHoldsQuestId(questId)
    if type(questId) ~= "number" then
        return false
    end
    local index = 1
    while index <= focusQuestIdCount do
        if focusQuestIds[index] == questId then
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
    local ids = pin and pin.unrealQuestAvailableQuestIds
    if type(ids) == "table" then
        local idIndex = 1
        local idTotal = table.getn(ids)
        while idIndex <= idTotal do
            if FocusHoldsQuestId(ids[idIndex]) then
                return true
            end
            idIndex = idIndex + 1
        end
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
    if focusQuestIdCount > 0 then
        local point = pin and pin.unrealQuestTurnIn
        local quests = point and point.quests
        if type(quests) == "table" then
            local questIndex = 1
            local questTotal = table.getn(quests)
            while questIndex <= questTotal do
                local ids = GetQuestMapIds(quests[questIndex])
                local idIndex = 1
                local idTotal = table.getn(ids)
                while idIndex <= idTotal do
                    if FocusHoldsQuestId(ids[idIndex]) then
                        return true
                    end
                    idIndex = idIndex + 1
                end
                questIndex = questIndex + 1
            end
        end
    end
    return false
end

-- The focus dim ------------------------------------------------------------
--
-- Two questions the map can be asked about a quest, and this is the second.
-- The marker emphasis above answers "where does this quest start and end" by
-- growing its "!" and "?". This answers "which of everything on screen is
-- this quest" by fading everything that is not.
--
-- It is frame alpha, deliberately. Every other candidate rewrites something
-- that carries meaning of its own: a colour is the quest's identity, a size is
-- the emphasis pass's answer, and hiding a pin would remove information rather
-- than rank it. Frame alpha is owned by nothing else in the draw path -- see
-- Client.SetWorldMapPinAlpha, which also short-circuits an unchanged value, so
-- restating a thousand undimmed objective frames on every hover costs no
-- client calls at all.
--
-- Two quests are the same quest here when they are the same table, or agree on
-- questId, or agree on titleKey. Identity alone is not enough: a "?" carries
-- the quest tables its point was built with, and a rebuild replaces every one
-- of them while the hover is still held.
local function SameQuest(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    if type(a.questId) == "number" and a.questId == b.questId then
        return true
    end
    if type(a.titleKey) == "string" and a.titleKey ~= ""
        and a.titleKey == b.titleKey then
        return true
    end
    return false
end

-- Public because the vendor layer draws quest pins of its own and must reach
-- the same answer this file does rather than keep a second copy of it.
function WorldMapPins:FocusIncludesQuest(quest)
    if not quest then
        return false
    end
    local index = 1
    while index <= focusQuestCount do
        if SameQuest(quest, focusQuests[index]) then
            return true
        end
        index = index + 1
    end
    index = 1
    while index <= focusQuestIdCount do
        if QuestHasMapId(quest, focusQuestIds[index]) then
            return true
        end
        index = index + 1
    end
    return false
end

-- A giver focus carries IDs and no quest table, so both counts decide whether
-- anything is focused at all.
function WorldMapPins:HasQuestFocus()
    return focusQuestCount > 0 or focusQuestIdCount > 0
end

local function FocusRelatedQuestFrame(pin)
    return WorldMapPins:FocusIncludesQuest(pin.unrealQuestQuest)
end

local function FocusRelatedGiver(pin)
    return FocusGiverOffers(pin)
end

local function FocusRelatedTurnIn(pin)
    return FocusTakesTurnIn(pin)
end

-- Walked over the WHOLE pool, for the reason the emphasis pass gives: a
-- pooled frame that fell out of the last draw keeps its old alpha, and a
-- dimmed one handed back out by a later rebuild would return faded.
--
-- A frame the reveal flash currently owns is skipped. The flash is already
-- writing that frame's alpha several times a second and restores it itself;
-- the two writers are told apart by the base size the flash stamps on its
-- targets while it holds them.
local function ApplyPoolFocusDim(pool, visible, related, active)
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        local pin = pool[index]
        if pin and not pin.unrealQuestFlashBaseWidth then
            local alpha = FOCUS_FULL_ALPHA
            if active and index <= visible and not related(pin) then
                alpha = FOCUS_DIM_ALPHA
            end
            Client.SetWorldMapPinAlpha(pin, alpha)
        end
        index = index + 1
    end
end

-- ONE writer for the opacity of every map pin, the same way
-- RefreshMarkerEmphasis is the one writer for marker size. Called from
-- ApplyFocus, which is the only thing that changes what "related" means.
function WorldMapPins:RefreshFocusDim()
    local active = self:HasQuestFocus()
    -- Nothing is faded and nothing was: the common case, and the whole point
    -- of the flag is that it costs no pool walk at all.
    if not active and not self.focusDimApplied then
        return
    end
    self.focusDimApplied = active
    ApplyPoolFocusDim(self.areaPool, self.areaVisibleCount,
        FocusRelatedQuestFrame, active)
    ApplyPoolFocusDim(self.dotBorderPool, self.dotBorderVisibleCount,
        FocusRelatedQuestFrame, active)
    ApplyPoolFocusDim(self.giverPool, self.giverVisibleCount,
        FocusRelatedGiver, active)
    ApplyPoolFocusDim(self.turnInPool, self.turnInVisibleCount,
        FocusRelatedTurnIn, active)
    ApplyPoolFocusDim(self.followedTurnInPool, self.followedTurnInVisibleCount,
        FocusRelatedQuestFrame, active)
    -- The other two layers drawing on the same canvas. Neither is asked to
    -- decide anything: the service/rare pins carry no quest and fade as a
    -- block, and the vendor pins ask this module's own FocusIncludesQuest.
    local npcPins = UQ:GetModule("NpcPins")
    if npcPins and npcPins.SetWorldFocusDim then
        npcPins:SetWorldFocusDim(active)
    end
    local vendorPins = UQ:GetModule("QuestVendorPins")
    if vendorPins and vendorPins.SetWorldFocusDim then
        vendorPins:SetWorldFocusDim(active)
    end
end

-- ONE writer for the size of the "!" and "?" markers.
--
-- Three gestures can claim a marker: hovering it, hovering the patrol route of
-- the NPC that owns it, and hovering an objective dot, an area tile or a "?"
-- of a quest that marker belongs to. Each of them used to walk the two pools
-- and stamp its own answer over whatever the other two had written, so the
-- result depended on the order the client delivered the scripts in -- an
-- OnLeave arriving after the next OnEnter shrank the marker the new hover had
-- just grown.
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
    -- The focus link, and the reason this pass exists: the quest's own giver
    -- and turn-in grow to exactly the size a direct hover would give them, so
    -- the marker those dots belong to is found by looking without changing
    -- any quest colour or opacity.
    return FocusGiverOffers(pin) or FocusTakesTurnIn(pin)
end

-- Size is walked over the WHOLE pool.
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

local function ApplyMarkerEmphasis(pool, visible)
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
        self.giverPool, self.giverVisibleCount)
    local turnInAnimating = ApplyMarkerEmphasis(
        self.turnInPool, self.turnInVisibleCount)
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

-- The followed turn-in's arrival --------------------------------------------
--
-- Following a new quest answers a question the player just asked -- "where do
-- I hand this in" -- and the answer is one gold ring appearing somewhere on a
-- map that may already carry a hundred other pins. A ring that simply exists
-- from one frame to the next is easy to miss; the same ring breathing a few
-- times is not.
--
-- It is the reveal flash's own size easing (EaseInOutCubic, grow then shrink)
-- rather than a second animation idiom, because it is the same gesture asking
-- the same thing of the player's eye. What it deliberately does NOT reuse is
-- the flash's alpha blink: the ring's transparency comes entirely from the
-- TGA's own alpha channel (docs/WORLD-MAP-PINS-RECOVERY.md), and pulsing
-- frame alpha over it would fight that contract for no gain.
--
-- Three cycles, not a permanent pulse: this marks a CHANGE, and something
-- that never stops moving stops meaning one.
--
-- The same easing answers a second, quieter gesture: hovering one of the
-- followed quest's own objective dots pulses the ring ONCE. The hover is a
-- question about that quest, and one breath from the ring is the shortest
-- possible way to say "and this is where it ends" -- three would restate an
-- arrival the player already saw. Same shape, same rate, different count, so
-- the two read as one language rather than two effects.
local FOLLOWED_RING_PULSE_CYCLES = 3
local FOLLOWED_RING_HOVER_PULSE_CYCLES = 1
local FOLLOWED_RING_PULSE_HZ = 1.15
local FOLLOWED_RING_PULSE_MIN_SCALE = 0.9
local FOLLOWED_RING_PULSE_MAX_SCALE = 1.55

local function SetFollowedRingSize(ring, size)
    if ring then
        Client.SetWorldMapPinSize(ring, size, size)
    end
end

-- Walked over the WHOLE pool, for the emphasis pass's reason: a ring left
-- mid-pulse and handed back out by a later rebuild would return oversized.
local function RestRingPoolSizes(pool)
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        SetFollowedRingSize(pool[index], FOLLOWED_TURNIN_RING_SIZE)
        index = index + 1
    end
end

-- Both ring pools rest together. One pulse job drives whichever of them is on
-- screen, so ending it has to hand every ring back, not only the set that
-- happened to start it.
local function RestFollowedRingSizes()
    RestRingPoolSizes(WorldMapPins.followedTurnInPool)
    RestRingPoolSizes(WorldMapPins.hoverTurnInRingPool)
end

local function EndFollowedRingPulse()
    WorldMapPins.followedRingPulseStart = nil
    WorldMapPins.followedRingPulseCycles = nil
    WorldMapPins.followedRingPulseIsHover = nil
    -- Both pools rest, whichever one was moving: resting a pool that never
    -- left its size costs one skipped call per ring and removes the case where
    -- a run ends without handing something back.
    WorldMapPins.followedRingPulseOnFollowed = nil
    WorldMapPins.followedRingPulseOnHover = nil
    RestFollowedRingSizes()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Unschedule("map.followedring")
    end
end

local function FollowedRingPulseDuration()
    local cycles = WorldMapPins.followedRingPulseCycles
    if type(cycles) ~= "number" or cycles <= 0 then
        cycles = FOLLOWED_RING_PULSE_CYCLES
    end
    return cycles / FOLLOWED_RING_PULSE_HZ
end

local function RunFollowedRingPulse()
    local start = WorldMapPins.followedRingPulseStart
    local now = Client.Now()
    if not start or not now then
        EndFollowedRingPulse()
        return
    end
    local elapsed = now - start
    if elapsed < 0 or elapsed >= FollowedRingPulseDuration() then
        EndFollowedRingPulse()
        return
    end
    local cycle = elapsed * FOLLOWED_RING_PULSE_HZ
    cycle = cycle - math.floor(cycle)
    local eased
    if cycle < 0.5 then
        eased = EaseInOutCubic(cycle * 2)
    else
        eased = EaseInOutCubic((1 - cycle) * 2)
    end
    local size = FOLLOWED_TURNIN_RING_SIZE * (FOLLOWED_RING_PULSE_MIN_SCALE
        + (FOLLOWED_RING_PULSE_MAX_SCALE - FOLLOWED_RING_PULSE_MIN_SCALE) * eased)
    -- Only the pool this run was started for. A ring lent to a quest the
    -- player is merely pointing at must not set the FOLLOWED quest's own ring
    -- breathing beside it: that would say the followed quest is what changed,
    -- which is the one thing this gesture does not mean.
    local pool, index
    if WorldMapPins.followedRingPulseOnFollowed then
        pool = WorldMapPins.followedTurnInPool
        index = 1
        while index <= WorldMapPins.followedTurnInVisibleCount do
            SetFollowedRingSize(pool[index], size)
            index = index + 1
        end
    end
    if WorldMapPins.followedRingPulseOnHover then
        pool = WorldMapPins.hoverTurnInRingPool
        index = 1
        while index <= WorldMapPins.hoverTurnInRingVisibleCount do
            SetFollowedRingSize(pool[index], size)
            index = index + 1
        end
    end
end

-- Restarting replaces the existing named driver job rather than stacking a
-- second one, exactly as a repeated reveal does.
function WorldMapPins:PulseFollowedTurnInRings(cycles, isHover, onHoverPool)
    local driver = UQ:GetModule("Driver")
    local start = Client.Now()
    if not driver or not start then
        -- No timing source: the ring still appears at its resting size, which
        -- is the whole answer minus the emphasis.
        RestFollowedRingSizes()
        return false
    end
    if type(cycles) ~= "number" or cycles <= 0 then
        cycles = FOLLOWED_RING_PULSE_CYCLES
    end
    self.followedRingPulseCycles = cycles
    -- Which gesture owns the run in flight. A hover's own breath is stopped
    -- when its focus ends, after the release grace; an arrival's is not.
    self.followedRingPulseIsHover = isHover and true or nil
    -- The arrival is always the followed quest's own ring. A hover says which
    -- of the two pools it drew into.
    if onHoverPool == nil then
        self.followedRingPulseOnFollowed = true
        self.followedRingPulseOnHover = nil
    else
        self.followedRingPulseOnFollowed = onHoverPool.followed or nil
        self.followedRingPulseOnHover = onHoverPool.hover or nil
    end
    self.followedRingPulseStart = start
    driver:Schedule("map.followedring", 0, RunFollowedRingPulse)
    return true
end

-- Rings for the hovered quest's own turn-in points, borrowed for the duration
-- of the hover.
--
-- A "?" already wearing the followed quest's permanent ring is not given a
-- second one: two identical circles on one coordinate is not a stronger answer,
-- it is a thicker one. Two quests handed in to the same NPC share one marker,
-- so this is an ordinary case rather than a corner. It is reported back as the
-- second return value -- the ring the hover would have drawn is already on
-- screen, so the gesture still has something to pulse.
function WorldMapPins:ShowHoverTurnInRings(quest)
    local visible = 1
    local coincident = false
    if quest then
        local mainQuest = nil
        if UQ:IsFeatureEnabled("mainQuestWaypoint") then
            mainQuest = MainQuest()
        end
        local index = 1
        while index <= self.turnInVisibleCount do
            local pin = self.turnInPool[index]
            if pin and PointHasQuest(pin.unrealQuestTurnIn, quest)
                and type(pin.unrealQuestMapX) == "number"
                and type(pin.unrealQuestMapY) == "number" then
                if mainQuest
                    and PointFollowedQuest(pin.unrealQuestTurnIn, mainQuest) then
                    coincident = true
                else
                    local ring = self:GetHoverTurnInRing(visible)
                    if ring then
                        ring.unrealQuestQuest = quest
                        if Client.PositionWorldMapPin(
                            ring, pin.unrealQuestMapX, pin.unrealQuestMapY) then
                            visible = visible + 1
                        else
                            Client.HideObject(ring)
                        end
                    end
                end
            end
            index = index + 1
        end
    end
    self.hoverTurnInRingVisibleCount = HidePoolFrom(
        self.hoverTurnInRingPool, visible)
    return self.hoverTurnInRingVisibleCount > 0, coincident
end

-- Once hover focus ends, take its rings away without waiting for a redraw.
-- RequestQuestFocus owns the grace period between objective dots.
function WorldMapPins:HideHoverTurnInRings()
    if self.hoverTurnInRingVisibleCount == 0 then
        return false
    end
    self.hoverTurnInRingVisibleCount = HidePoolFrom(self.hoverTurnInRingPool, 1)
    return true
end

-- The hover's single breath, on whichever ring the hovered quest owns.
--
-- Two cases, one gesture. The FOLLOWED quest already has a permanent ring, so
-- its own dots simply pulse it. Any other quest has none, so one is drawn for
-- as long as that quest's hover focus is held and pulses once as it arrives --
-- which is the same sentence either way: "and this is where it ends".
--
-- Skipped while the arrival pulse is still running. That one is answering a
-- change the player just made, and cutting it short to restate a ring would
-- lose the louder message to the quieter one.
-- Reused rather than allocated per hover, for the reason Core/Driver.lua gives
-- about allocation churn: a hover fires on every dot the cursor crosses.
local hoverPulseTargets = { followed = false, hover = false }

function WorldMapPins:PulseFollowedTurnInRingsForFocus(quest)
    local followedRing = false
    local index = 1
    while index <= self.followedTurnInVisibleCount do
        local ring = self.followedTurnInPool[index]
        if ring and self:FocusIncludesQuest(ring.unrealQuestQuest) then
            followedRing = true
            index = self.followedTurnInVisibleCount
        end
        index = index + 1
    end
    local drewHoverRing, sharesFollowedRing = false, false
    if not followedRing then
        drewHoverRing, sharesFollowedRing = self:ShowHoverTurnInRings(quest)
    end
    if not followedRing and not drewHoverRing and not sharesFollowedRing then
        return false
    end
    if self.followedRingPulseStart and not self.followedRingPulseIsHover then
        return false
    end
    hoverPulseTargets.followed = followedRing or sharesFollowedRing
    hoverPulseTargets.hover = drewHoverRing
    return self:PulseFollowedTurnInRings(
        FOLLOWED_RING_HOVER_PULSE_CYCLES, true, hoverPulseTargets)
end

-- Losing focus stops the breath immediately. The ARRIVAL pulse is left alone:
-- it belongs to a followed-quest change, not to this hover.
function WorldMapPins:ClearHoverTurnInRings()
    local hid = self:HideHoverTurnInRings()
    if self.followedRingPulseIsHover and self.followedRingPulseStart then
        EndFollowedRingPulse()
    end
    self.followedRingPulseIsHover = nil
    return hid
end

local SetPatrolStrokeStyle

-- Only objective hover requests are delayed. Direct marker focus and scene
-- invalidation cancel the request even when the applied focus is unchanged.
function WorldMapPins:CancelQuestFocusRequest()
    self.pendingFocusQuest = nil
    self.pendingFocusStarted = nil
    self.pendingFocusDeadline = nil
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Unschedule("map.questfocus")
    end
end

local function RunQuestFocusRequest()
    local now = Client.Now()
    local started = WorldMapPins.pendingFocusStarted
    local deadline = WorldMapPins.pendingFocusDeadline
    if not now or not started or not deadline or now < started then
        WorldMapPins:ApplyFocus(nil, nil, nil)
        return
    end
    if now < deadline then
        return
    end
    WorldMapPins:ApplyQuestFocus(WorldMapPins.pendingFocusQuest)
end

function WorldMapPins:RequestQuestFocus(quest)
    if quest and self.focusQuest == quest and not self.focusTurnInPin
        and not self.focusGiverPin then
        -- Re-entering this quest cancels its release, preserving the current
        -- opacity, marker targets and ring pulse (including a finished pulse).
        self:CancelQuestFocusRequest()
        return
    end
    if not quest and not self.focusQuest and not self.focusTurnInPin
        and not self.focusGiverPin then
        self:CancelQuestFocusRequest()
        return
    end
    if self.pendingFocusDeadline and self.pendingFocusQuest == quest then
        return
    end
    local now = Client.Now()
    local driver = UQ:GetModule("Driver")
    if not now or not driver then
        self:ApplyQuestFocus(quest)
        return
    end
    self.pendingFocusQuest = quest
    self.pendingFocusStarted = now
    self.pendingFocusDeadline = now
        + (quest and OBJECTIVE_FOCUS_DWELL or OBJECTIVE_FOCUS_RELEASE)
    -- One reusable job, independent of dot count; it sleeps once applied or
    -- cancelled. Timing remains on the shared GetTime-based driver.
    driver:Schedule("map.questfocus", OBJECTIVE_FOCUS_POLL, RunQuestFocusRequest)
end

-- One quest (an objective hover) or one turn-in pin, whose point can carry
-- several quests handed in at the same spot. Passing neither clears the focus.
function WorldMapPins:ApplyFocus(quest, turnInPin, giverPin)
    self:CancelQuestFocusRequest()
    if self.focusQuest == quest and self.focusTurnInPin == turnInPin
        and self.focusGiverPin == giverPin then
        return
    end
    self.focusQuest = quest
    self.focusTurnInPin = turnInPin
    self.focusGiverPin = giverPin
    SetFocusQuests(quest, turnInPin and turnInPin.unrealQuestTurnIn,
        giverPin and giverPin.unrealQuestAvailableQuestIds)

    -- Hover keeps every map COLOUR stable -- colour is quest identity, and
    -- rewriting it would read as a different quest rather than the same quest
    -- emphasised. The two things a hover does change are size, so the quest's
    -- own "!" and "?" are easy to find, and the opacity of everything that is
    -- not this quest, so they are easy to find among.
    self:RefreshMarkerEmphasis()
    self:RefreshFocusDim()

    -- ...and one breath from a ring on that quest's own turn-in, so hovering an
    -- objective also says where the quest ends. The followed quest pulses the
    -- ring it already wears; any other quest is lent one for the length of the
    -- hover. Objective hovers only: the "?" and the "!" are already the marker
    -- under the cursor, and a marker pulsing at itself says nothing.
    --
    -- The guard at the top of this function makes it once per hover rather
    -- than once per dot -- one quest's dots are a cloud, and sliding across it
    -- re-enters the same quest frame after frame. Every other way out of this
    -- function is a focus that is not an objective hover, and takes the lent
    -- ring with it.
    if quest then
        -- A direct switch can skip the empty focus between two objectives.
        -- Remove the previous quest's lent ring before selecting this one's.
        self:ClearHoverTurnInRings()
        self:PulseFollowedTurnInRingsForFocus(quest)
    else
        self:ClearHoverTurnInRings()
    end
end

function WorldMapPins:ApplyQuestFocus(quest)
    self:ApplyFocus(quest, nil, nil)
end

-- Hovering a "?" focuses every quest handed in at that point: its own giver
-- and turn-in markers grow, and every pin belonging to no quest at that point
-- fades. Objective colours are unchanged.
function WorldMapPins:ApplyTurnInFocus(pin)
    self:ApplyFocus(nil, pin, nil)
end

-- Hovering a "!" focuses the quests that giver still offers. They are not in
-- the player's log, so this focus is carried as database IDs rather than quest
-- tables and usually has no objective dot of its own to keep bright -- which
-- is the honest answer: what the cursor is on is the only place that quest is
-- on this map yet.
function WorldMapPins:ApplyGiverFocus(pin)
    self:ApplyFocus(nil, nil, pin)
end

-- Reuses the positions already stamped onto the visible objective and turn-in
-- pools. Only dots belonging to the followed quest receive a gold rim, and
-- only the followed turn-in uses the supplied circle image. Area mode has no
-- objective borders.
function WorldMapPins:RefreshDotBordersAndFollowedTurnIns()
    local mainQuest = nil
    if UQ:IsFeatureEnabled("mainQuestWaypoint") then
        mainQuest = MainQuest()
    end
    -- Isolation switch for the gold contour around the followed quest's dots.
    -- Kept separate from the followed turn-in ring below because only this loop
    -- walks the whole objective pool; the ring walks the five "?" markers.
    local borders = mainQuest and self.dotBordersEnabled ~= false
    local dotIndex = 1
    local index = 1
    while borders and index <= self.areaVisibleCount do
        local dot = self.areaPool[index]
        local quest = dot and dot.unrealQuestQuest
        if dot and dot.unrealQuestDotStyle and quest
            and mainQuest:IsMain(quest.titleKey)
            and type(dot.unrealQuestMapX) == "number"
            and type(dot.unrealQuestMapY) == "number" then
            local border = self:GetDotBorder(dotIndex)
            if border then
                local borderSize = ObjectiveDotSize() + DOT_BORDER_PADDING
                border.unrealQuestQuest = quest
                Client.SetWorldMapPinSize(border, borderSize, borderSize)
                if Client.PositionWorldMapDot(border,
                    dot.unrealQuestMapX, dot.unrealQuestMapY, borderSize) then
                    dotIndex = dotIndex + 1
                else
                    Client.HideObject(border)
                end
            end
        end
        index = index + 1
    end
    self.dotBorderVisibleCount = HidePoolFrom(self.dotBorderPool, dotIndex)

    local turnInIndex = 1
    local ringQuestKey = nil
    index = 1
    while mainQuest and index <= self.turnInVisibleCount do
        local pin = self.turnInPool[index]
        local quest = pin and PointFollowedQuest(pin.unrealQuestTurnIn, mainQuest)
        if quest and type(pin.unrealQuestMapX) == "number"
            and type(pin.unrealQuestMapY) == "number" then
            local ring = self:GetFollowedTurnInRing(turnInIndex)
            if ring then
                ring.unrealQuestQuest = quest
                if Client.PositionWorldMapPin(
                    ring, pin.unrealQuestMapX, pin.unrealQuestMapY) then
                    turnInIndex = turnInIndex + 1
                    if ringQuestKey == nil then
                        ringQuestKey = quest.titleKey or quest.title
                    end
                else
                    Client.HideObject(ring)
                end
            end
        end
        index = index + 1
    end
    self.followedTurnInVisibleCount = HidePoolFrom(
        self.followedTurnInPool, turnInIndex)
    -- A ring drawn for a quest the previous pass was not drawing one for is a
    -- followed-quest CHANGE arriving on the map -- clicking a "?" or an
    -- objective dot, the tracker's Following action, the quest log, all of
    -- them reach this one place. The pulse marks that moment and nothing else:
    -- a redraw of the same followed quest, in the same or another zone, leaves
    -- the ring resting.
    if ringQuestKey then
        if ringQuestKey ~= self.followedRingQuestKey then
            self.followedRingQuestKey = ringQuestKey
            self:PulseFollowedTurnInRings()
        end
    else
        self.followedRingQuestKey = nil
        if self.followedRingPulseStart then
            EndFollowedRingPulse()
        end
    end
    self:MarkSettling()
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
local FLASH_DURATION = 5.41
local FLASH_HZ = 2.5
local FLASH_MIN_ALPHA = 0.3
local FLASH_MAX_ALPHA = 1.0
-- The blink alone is easy to miss among a screen of other pins, so each
-- target also pulses its own size through the same EaseInOutCubic used for
-- the giver/turn-in hover emphasis above -- grow, then shrink -- rather than
-- a raw sine, so the size change itself reads as an eased motion instead of a
-- mechanical wobble. Its own, slower rate (rather than sharing FLASH_HZ) is
-- what makes each bounce read as a deliberate grow/shrink instead of a jitter
-- riding on top of the faster blink.
local FLASH_SCALE_HZ = 1
local FLASH_MIN_SCALE = 0.85
local FLASH_MAX_SCALE = 1.4
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
        if target then
            if target.unrealQuestFlashBaseWidth and target.unrealQuestFlashBaseHeight then
                Client.SetWorldMapPinSize(target,
                    target.unrealQuestFlashBaseWidth, target.unrealQuestFlashBaseHeight)
            end
            target.unrealQuestFlashBaseWidth = nil
            target.unrealQuestFlashBaseHeight = nil
            if target.unrealQuestFlashRaised then
                Client.RaiseWorldMapPin(target, -FLASH_LEVEL_BOOST)
                target.unrealQuestFlashRaised = nil
            end
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
        if target then
            if Client.RaiseWorldMapPin(target, FLASH_LEVEL_BOOST) then
                target.unrealQuestFlashRaised = true
            end
            target.unrealQuestFlashBaseWidth = target.unrealQuestPixelWidth
            target.unrealQuestFlashBaseHeight = target.unrealQuestPixelHeight
        end
        index = index + 1
    end
    WorldMapPins.flashTargets = targets
end

-- Pulses every target's whole-frame alpha (Client.SetWorldMapPinAlpha, the
-- same stock SetAlpha already relied on for the waypoint marker) and, in step
-- with it, its own eased size around its
-- current base size for FLASH_DURATION seconds, then hands every target back
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
        local cycle = elapsed * FLASH_SCALE_HZ
        cycle = cycle - math.floor(cycle)
        local eased
        if cycle < 0.5 then
            eased = EaseInOutCubic(cycle * 2)
        else
            eased = EaseInOutCubic((1 - cycle) * 2)
        end
        local scale = FLASH_MIN_SCALE + (FLASH_MAX_SCALE - FLASH_MIN_SCALE) * eased
        local index = 1
        local total = table.getn(targets)
        while index <= total do
            local target = targets[index]
            Client.SetWorldMapPinAlpha(target, alpha)
            if target and target.unrealQuestFlashBaseWidth and target.unrealQuestFlashBaseHeight then
                Client.SetWorldMapPinSize(target,
                    target.unrealQuestFlashBaseWidth * scale,
                    target.unrealQuestFlashBaseHeight * scale)
            end
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
    self.hoverFocusOwner = pin
    RecordGiverHover()
    self:ApplyGiverTurnInHover(pin)
    self:ApplyPatrolHover(pin)
    -- Keyed on the PIN rather than on its quest ids, for the reason
    -- OnTurnInEnter gives: a rebuild replaces the id list, and a captured one
    -- would never compare equal again on the way out.
    self:ApplyGiverFocus(pin)
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
    -- The same guard every other leave path carries: this client can deliver
    -- the next marker's OnEnter first, and an unguarded clear would drop a
    -- focus that already belongs to it.
    if self.hoverFocusOwner == pin then
        self.hoverFocusOwner = nil
        self:ApplyGiverFocus(nil)
    end
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
-- pins, with the bundled "?" icon instead of the client's "!". Its click is a
-- following gesture, so the marker now deliberately owns the left-click that
-- used to pass through to the objective tile underneath it.
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
            function() WorldMapPins:OnTurnInClick(pin) end)
    end
    return pin
end

local function FirstTurnInQuest(point)
    local quests = point and point.quests
    local first = quests and quests[1]
    local index = 1
    local total = table.getn(quests or {})
    while index <= total do
        if quests[index] and quests[index].isComplete == 1 then
            return quests[index]
        end
        index = index + 1
    end
    return first
end

function WorldMapPins:OnTurnInClick(pin)
    return self:FollowQuest(FirstTurnInQuest(pin and pin.unrealQuestTurnIn),
        "worldMapTurnIn")
end

function WorldMapPins:OnTurnInEnter(pin)
    self.hoverFocusOwner = pin
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
    if self.hoverFocusOwner == pin then
        self.hoverFocusOwner = nil
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
-- recorded here; RefreshMarkerEmphasis is what decides every marker's size,
-- so this cannot overwrite a route highlight.
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

-- A stamp has one alpha channel, so its hover highlight is resolved here.
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
    -- An objective dot identifies its source creature exactly. When that
    -- creature owns one of the objective patrols already in the scene, the
    -- dot and route read as one hover selection.
    if unitId == nil then
        unitId = self.hoverObjectivePatrolUnitId
    end
    -- A pin owned by another layer names its creature the same way: when the
    -- scene already draws that route, hovering the pin lights it in place
    -- instead of stamping a second copy over it (see SetHoverPatrolUnit).
    if unitId == nil then
        unitId = self.hoverPatrolUnitId
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

-- The hovered creature's route ------------------------------------------------
--
-- Same stamps as the scene's, on the same shared layer, from a pool of their
-- own: see MAX_HOVER_PATROL_STROKES. Always drawn in the hover colour, because
-- this route exists only while something under the cursor names it.
function WorldMapPins:GetHoverPatrolStroke(index)
    local stroke = self.hoverStrokePool[index]
    if stroke then
        return stroke
    end
    stroke = Client.CreateWorldMapStroke()
    if stroke then
        self.hoverStrokePool[index] = stroke
    end
    return stroke
end

local function SetHoverPatrolStrokeStyle(pins, index)
    local stroke = pins.hoverStrokePool[index]
    if not stroke then
        return
    end
    Client.SetWorldMapStrokeColor(stroke,
        PATROL_LINE_HOVER_RED, PATROL_LINE_HOVER_GREEN, PATROL_LINE_HOVER_BLUE,
        PATROL_LINE_HOVER_ALPHA)
    Client.SetWorldMapStrokeSize(stroke,
        (pins.hoverStrokeWidth or PATROL_LINE_WIDTH) + PATROL_LINE_HOVER_BOOST)
end

-- Redraws whatever the current hover asks for and hides the rest of the pool,
-- so this one call covers "a pin was entered", "a pin was left" and "the scene
-- underneath was rebuilt". Nothing is drawn when the scene already carries the
-- route: RefreshPatrolHighlight lights that one in place instead.
function WorldMapPins:DrawHoverPatrol()
    local unitId = self.hoverPatrolUnitId
    if unitId == nil and self.hoverStrokeVisibleCount <= 0 then
        -- Nothing hovered and nothing left over: the rebuild that calls this
        -- must not pay for a view resolution to hide an empty pool.
        return
    end
    local placed = 1
    local database = Database()
    local mapContext = MapContext()
    -- The view is resolved ONCE here and handed to every placement below.
    -- DatabaseToCurrentMap resolves it itself when it is not given one, which
    -- would repeat that work for each of up to MAX_HOVER_PATROL_STROKES
    -- stamps; it is also what makes a hover held while the map moves to
    -- another zone draw nothing rather than draw the route in the wrong place.
    local areaId, report = nil, nil
    if mapContext then
        areaId, report = mapContext:GetViewedZone()
    end
    if type(unitId) == "number" and type(areaId) == "number"
        and database and mapContext and self.renderEnabled
        and not self.patrolSceneUnitIds[unitId]
        and Client.GetWorldMapCanvas() then
        local segments = self:CollectPatrolSegments(
            database, { [unitId] = true }, areaId)
        if table.getn(segments) > 0 then
            local spacing, pixelsPerUnit = PatrolStrokeSpacing()
            if spacing and spacing > 0 then
                spacing = FitPatrolSpacing(segments, spacing, MAX_HOVER_PATROL_STROKES)
                local width = spacing * pixelsPerUnit
                if width < PATROL_LINE_WIDTH then
                    width = PATROL_LINE_WIDTH
                elseif width > PATROL_LINE_MAX_WIDTH then
                    width = PATROL_LINE_MAX_WIDTH
                end
                self.hoverStrokeWidth = width
                local drawn = WalkPatrolPath(mapContext, areaId, segments, report,
                    spacing, MAX_HOVER_PATROL_STROKES,
                    function(index, mapX, mapY)
                        local stroke = self:GetHoverPatrolStroke(index)
                        if not stroke then
                            return false
                        end
                        if not Client.PositionWorldMapStroke(
                            stroke, mapX, mapY, width + PATROL_LINE_HOVER_BOOST) then
                            Client.HideObject(stroke)
                            return false
                        end
                        self.hoverStrokeX[index] = mapX
                        self.hoverStrokeY[index] = mapY
                        SetHoverPatrolStrokeStyle(self, index)
                        return true
                    end)
                placed = drawn + 1
            end
        end
    end
    self.hoverStrokeVisibleCount = HidePoolFrom(self.hoverStrokePool, placed)
end

-- Called by the layers that own the service, vendor and rare pins
-- (Map/NpcPins.lua, Map/QuestVendorPins.lua) when the mouse enters one. The
-- creature's route is context for the pin under the cursor, so it lives
-- exactly as long as that hover and is never left behind by a rebuild.
function WorldMapPins:SetHoverPatrolUnit(unitId)
    if type(unitId) ~= "number" then
        unitId = nil
    end
    if self.hoverPatrolUnitId == unitId then
        return
    end
    self.hoverPatrolUnitId = unitId
    self:DrawHoverPatrol()
    self:RefreshPatrolHighlight()
end

-- Leaving a pin must not drop a hover that already belongs to another one:
-- this client can deliver the next pin's OnEnter before this OnLeave. Same
-- guard the marker, tile and route hovers above use, for the same reason.
function WorldMapPins:ClearHoverPatrolUnit(unitId)
    if type(unitId) == "number" and self.hoverPatrolUnitId ~= unitId then
        return
    end
    self:SetHoverPatrolUnit(nil)
end

-- The counterpart of ReapplyPatrolStrokes for the hover pool, and needed for
-- the same one reason: a canvas that changed SIZE invalidates every recorded
-- offset at once.
function WorldMapPins:ReapplyHoverPatrolStrokes()
    if self.hoverStrokeVisibleCount <= 0 then
        return
    end
    local width = (self.hoverStrokeWidth or PATROL_LINE_WIDTH) + PATROL_LINE_HOVER_BOOST
    local index = 1
    while index <= self.hoverStrokeVisibleCount do
        local stroke = self.hoverStrokePool[index]
        local x, y = self.hoverStrokeX[index], self.hoverStrokeY[index]
        if stroke and type(x) == "number" and type(y) == "number" then
            Client.PositionWorldMapStroke(stroke, x, y, width)
            SetHoverPatrolStrokeStyle(self, index)
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
        Client.SetWorldMapPinLevelBoost(area, OBJECTIVE_DOT_LEVEL_BOOST)
    else
        Client.SetWorldMapPinTexture(area, Client.WORLD_MAP_PIN_TEXTURE)
        Client.SetWorldMapPinLevelBoost(area, 0)
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
    local borderSize = size + DOT_BORDER_PADDING
    index = 1
    while index <= self.dotBorderVisibleCount do
        Client.SetWorldMapPinSize(self.dotBorderPool[index], borderSize, borderSize)
        index = index + 1
    end
    self.dirty = true
end

-- Charges the gap since the previous driver tick to the pass that ran in it,
-- and opens a new one. See the census block near the pools for why the cost of
-- a pass can only be observed from the tick that follows it.
-- A pass costing this much on top of its own interval is a frame the player
-- can feel. Matches the driver census's own slow-frame threshold.
local SLOW_PASS = 0.05

local PASS_GAP_FIELDS = {
    create = "passGapCreate",
    rebuild = "passGapRebuild",
    reapply = "passGapReapply",
    hover = "passGapHover",
    skip = "passGapSkip",
}

local function PassGapBucket(kind, hovered)
    if type(kind) ~= "string" then
        return nil
    end
    if hovered then
        return "hover"
    end
    if string.find(kind, "reapply", 1, true) then
        return "reapply"
    end
    if string.find(kind, "+create:0", 1, true) then
        return "rebuild"
    end
    if string.find(kind, "+create:", 1, true) then
        return "create"
    end
    if string.find(kind, "skip", 1, true) then
        return "skip"
    end
    return nil
end

-- Records what this pass did, for both censuses: the local one below, and the
-- driver's, which is the only place the frame the pass ran in can be seen.
function WorldMapPins:MarkPass(kind)
    self.lastPassKind = kind
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Label("map.worldpins", PassGapBucket(kind, false) or "other")
    end
end

-- Invalidates map topology without making the closed world map do the work.
-- UIParent being visible is the observed off-screen signal already used by
-- ReapplyVisiblePools. A nil answer keeps the old eager behaviour, so an
-- unavailable signal can delay nothing.
function WorldMapPins:InvalidateScene()
    local hidden = Client.IsGameUIHidden()
    if hidden == false then
        self.pendingSceneDirty = true
        return
    end
    self.pendingSceneDirty = false
    self.dirty = true
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Wake("map.worldpins")
    end
end

function WorldMapPins:ChargePassGap()
    local now = Client.Now()
    if now and self.lastPassAt then
        local gap = now - self.lastPassAt
        self.lastPassGap = gap
        local bucket = PassGapBucket(self.lastPassKind, self.hoverSinceTick)
        if bucket then
            self.passCount[bucket] = (self.passCount[bucket] or 0) + 1
            if gap >= REFRESH_INTERVAL + SLOW_PASS then
                self.passSlow[bucket] = (self.passSlow[bucket] or 0) + 1
                local slowConfig = UQ:GetModule("Config")
                if slowConfig then
                    slowConfig:SetSectionEntry("mapDiagnostics",
                        PASS_GAP_FIELDS[bucket] .. "Slow", string.format("%d of %d",
                            self.passSlow[bucket], self.passCount[bucket]))
                end
            end
        end
        if bucket and gap > (self.passGapWorst[bucket] or 0) then
            self.passGapWorst[bucket] = gap
            -- Written here rather than from RecordDiagnostic, which dedupes:
            -- the gap that matters is charged on the tick AFTER the scene
            -- settled, by which time the diagnostic key no longer changes and
            -- nothing would reach the file.
            local config = UQ:GetModule("Config")
            if config then
                config:SetSectionEntry("mapDiagnostics", PASS_GAP_FIELDS[bucket], gap)
                config:SetSectionEntry("mapDiagnostics",
                    PASS_GAP_FIELDS[bucket] .. "Kind", tostring(self.lastPassKind))
                -- When, so a stall inside a load screen can be told from one
                -- the player actually sat through: the first tick of the
                -- session is recorded below to measure this against.
                config:SetSectionEntry("mapDiagnostics",
                    PASS_GAP_FIELDS[bucket] .. "At", now)
            end
        end
    end
    if now and not self.firstTickAt then
        self.firstTickAt = now
        local firstConfig = UQ:GetModule("Config")
        if firstConfig then
            firstConfig:SetSectionEntry("mapDiagnostics", "firstTickAt", now)
            -- Retired: one worst gap could not tell a stall apart from the
            -- loading screen it was charged to, which is why the buckets
            -- above replaced it. Cleared rather than left behind, so a saved
            -- file cannot answer with a number nothing writes any more.
            firstConfig:SetSectionEntry("mapDiagnostics", "passGapWorst", nil)
            firstConfig:SetSectionEntry("mapDiagnostics", "passGapWorstKind", nil)
        end
    end
    self.hoverSinceTick = false
    self.lastPassAt = now
    -- Overwritten by whichever exit this pass actually takes.
    self:MarkPass("skip")
    return self.areaCreates or 0
end

function WorldMapPins:Refresh()
    local createsBefore = self:ChargePassGap()
    local canvas = Client.GetWorldMapCanvas()
    if not canvas then
        HideAllPools()
        self.dirty = true
        self:MarkPass("skip:canvasMissing")
        RecordDiagnostic("canvasMissing")
        return
    end
    if not self.renderEnabled then
        HideAllPools()
        self.dirty = false
        self:MarkPass("skip:probeIsolation")
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
        self:MarkPass("skip:databaseNotReady")
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
        self:MarkPass("skip:" .. tostring(viewReason))
        RecordDiagnostic("viewUnavailable:" .. tostring(viewReason), nil, report)
        return
    end

    local signature = ViewSignature(areaId, report)
    local bagSignature = RelevantBagSignature(self.relevantBagItemIds)
    if self.pendingSceneDirty then
        local hidden = Client.IsGameUIHidden()
        -- A real view/config change still has to be applied: it may be the map
        -- opening or the player deliberately changing its presentation. Only
        -- a model invalidation against the same hidden scene is deferred.
        if hidden == false and not self.dirty
            and (not self.lastSignature or signature == self.lastSignature) then
            self:MarkPass("skip:offscreenDirty")
            return
        end
        self.pendingSceneDirty = false
        self.dirty = true
    end
    -- A relevant quest-use item changing while the map is closed is topology
    -- work too. Hold it for the next opening just like a quest-model change;
    -- an unrelated bag item is absent from this signature altogether.
    if not self.dirty and signature == self.lastSignature
        and bagSignature ~= self.lastBagSignature
        and Client.IsGameUIHidden() == false then
        self.pendingSceneDirty = true
        self:MarkPass("skip:offscreenBagChange")
        return
    end
    if not self.dirty and signature == self.lastSignature
        and bagSignature == self.lastBagSignature then
        self:MarkPass("reapply:" .. tostring(self.areaVisibleCount or 0))
        self:ReapplyVisiblePools()
        return
    end
    self.dirty = false
    self.poolsHidden = false
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
    local heldHoverArea = self.hoverFocusOwner == self.hoverArea and self.hoverArea or nil
    local heldFocusTurnIn = self.hoverFocusOwner == self.focusTurnInPin and self.focusTurnInPin or nil
    local heldFocusGiver = self.hoverFocusOwner == self.focusGiverPin and self.focusGiverPin or nil
    self.hoverArea = nil
    self.hoverObjectivePatrolUnitId = nil
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
    -- One drawn dot per distinct spawn coordinate for the WHOLE pass, not per
    -- quest: the dedup used to be quest-local, so twenty quests sharing a
    -- camp each placed their own frame on the same point and nineteen of them
    -- were invisible under the twentieth. Maps the coordinate key to the frame
    -- that owns it, so a later quest can be recorded on that frame instead of
    -- allocating another one.
    local dotOwners = {}
    -- Census only -- nothing below reads this to decide what to draw. Prices
    -- the reduction NOT taken: two coordinates closer together than one dot is
    -- wide still cost two frames that cannot be told apart on screen.
    local censusGridSeen = {}
    local censusGrid = 0
    local censusWidth, censusHeight = Client.GetWorldMapCanvasSize()
    local censusCell = ObjectiveDotSize()
    -- Roaming objective creatures, filled in by the quest pass below and drawn
    -- with the marker routes further down. See CollectRoamingObjectiveUnits.
    local objectivePatrolUnitIds = {}
    local quests = questState:GetOrderedQuests()
    self.relevantBagItemIds = self:GetRelevantBagItemIds(quests)
    self.lastBagSignature = RelevantBagSignature(self.relevantBagItemIds)
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
            -- Only while the quest is still being worked on: once it is
            -- complete these locations are its turn-in NPC's, and a route for
            -- that one is the "?" marker's business below.
            if not complete then
                CollectRoamingObjectiveUnits(locations, objectivePatrolUnitIds)
            end
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
                local locationIndex = 1
                local locationTotal = table.getn(locations)
                while AREA_RENDER_ENABLED and locationIndex <= locationTotal do
                    local location = locations[locationIndex]
                    local dotKey = tostring(location.x) .. ":" .. tostring(location.y)
                    local owner = dotOwners[dotKey]
                    if owner then
                        -- This point already has a frame. Which quest the one
                        -- visible dot belongs to is decided here rather than by
                        -- draw order: the followed quest always takes it, so
                        -- its brighter colour and its gold border cannot be
                        -- lost to whichever other quest happened to come first
                        -- in the log. Everything else keeps the first claim,
                        -- which at least makes the choice deterministic.
                        if isMain and not owner.unrealQuestIsMain then
                            local previous = owner.unrealQuestQuest
                            owner.unrealQuestQuest = quest
                            owner.unrealQuestIsMain = true
                            local r, g, b = ObjectiveColor(quest, complete, true, true)
                            Client.SetWorldMapAreaColor(owner, r, g, b, DOT_ALPHA)
                            AppendSharedQuest(owner, previous)
                        else
                            AppendSharedQuest(owner, quest)
                        end
                    else
                        local dotX, dotY = mapContext:DatabaseToCurrentMap(
                            areaId, location.x, location.y, report)
                        if dotX and dotY then
                            if censusWidth and censusHeight and censusCell > 0 then
                                local gridKey =
                                    tostring(math.floor(dotX * censusWidth / censusCell))
                                    .. ":" .. tostring(math.floor(dotY * censusHeight / censusCell))
                                if not censusGridSeen[gridKey] then
                                    censusGridSeen[gridKey] = true
                                    censusGrid = censusGrid + 1
                                end
                            end
                            local area = self:GetArea(areaIndex)
                            if area then
                                local r, g, b = ObjectiveColor(quest, complete, isMain, true)
                                ApplyObjectiveStyle(area, true)
                                Client.SetWorldMapAreaColor(area, r, g, b, DOT_ALPHA)
                                if Client.PositionWorldMapDot(area, dotX, dotY, ObjectiveDotSize()) then
                                    area.unrealQuestQuest = quest
                                    -- Pooled reuse: both of these still
                                    -- describe the frame's PREVIOUS owner
                                    -- until they are cleared, and a stale
                                    -- shared list would put a quest no longer
                                    -- on the map into this tooltip.
                                    area.unrealQuestSharedQuests = nil
                                    area.unrealQuestIsMain = isMain
                                    area.unrealQuestMarkerPin = nil
                                    area.unrealQuestObjectiveUnitId = nil
                                    if location.sourceType == "unit"
                                        and type(location.sourceId) == "number" then
                                        area.unrealQuestObjectiveUnitId = location.sourceId
                                    end
                                    dotOwners[dotKey] = area
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
                                    area.unrealQuestSharedQuests = nil
                                    area.unrealQuestIsMain = false
                                    area.unrealQuestMarkerPin = nil
                                    area.unrealQuestObjectiveUnitId = nil
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

    -- A roaming objective creature's route joins the STROKES only. It gets no
    -- hit targets, unlike a "!" or "?" route: its line is drawn across the
    -- quest's own objective cloud, and invisible Buttons laid along it would
    -- take the hover away from the tiles and dots underneath, which are what
    -- name the quest. Units the marker passes already drew are removed rather
    -- than collected twice -- a quest ender that is also somebody's objective
    -- would otherwise be stamped over itself.
    local objectiveUnitId
    for objectiveUnitId in pairs(visiblePatrolUnitIds) do
        objectivePatrolUnitIds[objectiveUnitId] = nil
    end
    local strokeSegments = patrolSegments
    local objectiveSegments = self:CollectPatrolSegments(
        database, objectivePatrolUnitIds, areaId)
    local objectiveSegmentTotal = table.getn(objectiveSegments)
    if objectiveSegmentTotal > 0 then
        strokeSegments = {}
        local copyIndex = 1
        local copyTotal = table.getn(patrolSegments)
        while copyIndex <= copyTotal do
            table.insert(strokeSegments, patrolSegments[copyIndex])
            copyIndex = copyIndex + 1
        end
        copyIndex = 1
        while copyIndex <= objectiveSegmentTotal do
            table.insert(strokeSegments, objectiveSegments[copyIndex])
            copyIndex = copyIndex + 1
        end
    end
    -- What the scene ended up carrying, for the hovered-pin route below: a
    -- creature already drawn here is lit in place rather than stamped again.
    local sceneUnitIds = {}
    for objectiveUnitId in pairs(visiblePatrolUnitIds) do
        sceneUnitIds[objectiveUnitId] = true
    end
    for objectiveUnitId in pairs(objectivePatrolUnitIds) do
        sceneUnitIds[objectiveUnitId] = true
    end
    self.patrolSceneUnitIds = sceneUnitIds

    -- The visible route over the same collected path. Drawn after the hit
    -- targets so it can read nothing they did not already establish.
    local patrolStrokeIndex, patrolStrokeFailures = self:DrawPatrolStrokes(
        mapContext, areaId, strokeSegments, report)
    pinFailures = pinFailures + patrolStrokeFailures
    -- A pin hover held across this rebuild keeps its route: the scene may now
    -- draw that creature itself, in which case this hides the separate copy.
    self:DrawHoverPatrol()

    self.visibleCount = HidePoolFrom(self.pool, markerIndex)
    self.areaVisibleCount = HidePoolFrom(self.areaPool, areaIndex)
    self.giverVisibleCount = HidePoolFrom(self.giverPool, giverMarkerIndex)
    self.patrolVisibleCount = HidePoolFrom(self.patrolPool, patrolTargetIndex)
    self.strokeVisibleCount = HidePoolFrom(self.strokePool, patrolStrokeIndex)
    self.turnInVisibleCount = HidePoolFrom(self.turnInPool, turnInMarkerIndex)
    self:RefreshDotBordersAndFollowedTurnIns()
    self:DrawNavigatorDebugTarget(mapContext, areaId, report)

    -- Pooled markers change owner between rebuilds, so a focus held across one
    -- describes the wrong frames. Cleared here, then re-applied against the
    -- finished layout below.
    self:ApplyFocus(nil, nil, nil)
    self.hoverFocusOwner = nil
    if heldFocusGiver and heldFocusGiver.unrealQuestAvailableQuestIds then
        -- Same test, same reason, over the pool that owns the "!".
        local giverFocusIndex = 1
        while giverFocusIndex <= self.giverVisibleCount do
            if self.giverPool[giverFocusIndex] == heldFocusGiver then
                self.hoverFocusOwner = heldFocusGiver
                self:ApplyGiverFocus(heldFocusGiver)
                giverFocusIndex = self.giverVisibleCount
            end
            giverFocusIndex = giverFocusIndex + 1
        end
    end
    if heldFocusTurnIn and heldFocusTurnIn.unrealQuestTurnIn then
        -- Only if that pin is still one of the drawn "?"s: a pooled pin that
        -- fell out of the visible range keeps its last point, and focusing on
        -- it would grow markers for a pin nobody can see.
        local focusIndex = 1
        while focusIndex <= self.turnInVisibleCount do
            if self.turnInPool[focusIndex] == heldFocusTurnIn then
                self.hoverFocusOwner = heldFocusTurnIn
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
    -- What this pass cost, for the tick that follows it to charge its gap to.
    local created = (self.areaCreates or 0) - createsBefore
    self:MarkPass("rebuild:" .. tostring(areaIndex - 1)
        .. "+create:" .. tostring(created))
    if created > (self.maxRebuildCreates or 0) then
        self.maxRebuildCreates = created
    end
    if rebuildConfig then
        rebuildConfig:SetSectionEntry("mapDiagnostics", "areaCreates", self.areaCreates or 0)
        rebuildConfig:SetSectionEntry("mapDiagnostics", "maxRebuildCreates",
            self.maxRebuildCreates or 0)
        if dotsMode then
            rebuildConfig:SetSectionEntry("mapDiagnostics", "dotsDrawn", areaIndex - 1)
            rebuildConfig:SetSectionEntry("mapDiagnostics", "dotsGridDistinct", censusGrid)
        end
    end
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

-- The complete bag dependency of the quest target scene. Only obj.IR use
-- items can switch the map between their acquisition source and use target;
-- ordinary loot never belongs in the scene cache key.
function WorldMapPins:GetRelevantBagItemIds(quests)
    local database = Database()
    local ids = {}
    local seen = {}
    local questIndex = 1
    local questTotal = quests and table.getn(quests) or 0
    while database and questIndex <= questTotal do
        local quest = quests[questIndex]
        if quest and quest.isComplete ~= 1 then
            local questIds = GetQuestMapIds(quest)
            local idIndex = 1
            local idTotal = table.getn(questIds)
            while idIndex <= idTotal do
                local targets = database:GetQuestItemUseTargets(questIds[idIndex])
                local targetIndex = 1
                local targetTotal = table.getn(targets)
                while targetIndex <= targetTotal do
                    local itemId = targets[targetIndex].itemId
                    if type(itemId) == "number" and not seen[itemId] then
                        seen[itemId] = true
                        table.insert(ids, itemId)
                    end
                    targetIndex = targetIndex + 1
                end
                idIndex = idIndex + 1
            end
        end
        questIndex = questIndex + 1
    end
    table.sort(ids)
    return ids
end

function WorldMapPins:GetStatus()
    return {
        visible = self.visibleCount,
        pooled = table.getn(self.pool),
        areaVisible = self.areaVisibleCount,
        areaPooled = table.getn(self.areaPool),
        dotBorders = self.dotBorderVisibleCount,
        giverVisible = self.giverVisibleCount,
        giverPooled = table.getn(self.giverPool),
        patrolVisible = self.patrolVisibleCount,
        patrolStrokes = self.strokeVisibleCount,
        patrolStrokeWidth = self.strokeWidth,
        patrolPooled = table.getn(self.patrolPool),
        turnInVisible = self.turnInVisibleCount,
        turnInPooled = table.getn(self.turnInPool),
        followedTurnIns = self.followedTurnInVisibleCount,
        inProgressTurnIns = ShowInProgressTurnIns(),
        areasEnabled = AREA_RENDER_ENABLED,
        objectiveDots = ObjectiveDotsEnabled(),
        markersEnabled = MARKER_RENDER_ENABLED,
        renderEnabled = self.renderEnabled,
        areaHovers = self.hoverCount or 0,
        giverHovers = self.giverHoverCount or 0,
        giverClicks = self.giverClickCount or 0,
        turnInHovers = self.turnInHoverCount or 0,
        navigatorDebugVisible = self.navigatorDebugVisible,
        rebuilds = self.rebuildCount or 0,
        itemUseUnknown = self.itemUseUnknown or 0,
        capped = self.visibleCount >= MAX_MARKERS
            or self.patrolVisibleCount >= MAX_PATROL_HOVER_TARGETS,
    }
end

function WorldMapPins:OnEnable()
    local state = QuestState()
    if state then
        state:AddListener(function(event, quest, targetsChanged)
            if event == "QUEST_OBJECTIVES_CHANGED" and not targetsChanged then
                WorldMapPins.progressOnlyUpdates =
                    (WorldMapPins.progressOnlyUpdates or 0) + 1
                return
            end
            WorldMapPins:InvalidateScene()
        end)
    end

    local mainQuest = MainQuest()
    if mainQuest then
        mainQuest:AddListener(function()
            if ObjectiveDotsEnabled() then
                WorldMapPins:RefreshDotBordersAndFollowedTurnIns()
            else
                WorldMapPins:WakeMapDriver()
            end
        end)
    end

    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.worldpins", REFRESH_INTERVAL, function()
            WorldMapPins:Refresh()
        end)
    end
    -- The initial scene is topology work too. If the map is closed, do not
    -- construct hundreds of invisible frames during login; the pending flag
    -- is consumed by the first driver tick after the map opens.
    self.dirty = false
    self.pendingSceneDirty = true
    self:MarkSettling()
    self:Refresh()
end
