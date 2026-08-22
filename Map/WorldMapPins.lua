--[[
UnrealQuest / Map/WorldMapPins.lua

Quest areas and numbered markers on the native fullscreen map.

Scope is intentionally narrow and evidence-bounded:
  * only active quests with a non-ambiguous database match;
  * only direct coordinates in the player's uniquely resolved current area;
  * only while GetPlayerMapPosition confirms that area is the selected view;
  * no child-area transforms, continent projection, minimap or waypoint arrow.

Nearby objective locations are merged into translucent blue areas; a completed
quest uses green. Area tiles are pooled and refreshed on the shared driver.

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
stacking. The client's own "?" colours mean "hand it in now"; a quest still in
progress gets the same icon in greyscale, which is the state the icon already
means in the client's gossip list. Greyscale, not a darker tint: SetVertexColor
only multiplies, so scaling the client's yellow "?" leaves it yellow. See
Client.SetWorldMapPinDesaturated and capability worldMapPinDesaturation. The
grey half is opt-out through showInProgressTurnIns.

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
local MAX_AREA_TILES = 180
local MAX_LOCATIONS_PER_QUEST = 200
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

local MAX_GIVER_MARKERS = 40
-- Offset so giver pin frame names never collide with the quest markers
-- (1..MAX_MARKERS) or the area tiles (+500), which share the same
-- CreateWorldMapPin naming scheme.
local GIVER_INDEX_OFFSET = 1000
-- How far a giver "!" is lifted above the area tiles it can overlap, so the
-- tile cannot win the click. Small on purpose: it only has to break a tie
-- between siblings, and the pins stay well inside the confirmed ">= 120"
-- rendering contract either way.
local GIVER_LEVEL_BOOST = 4

local MAX_TURNIN_MARKERS = 40
-- Same collision reasoning as GIVER_INDEX_OFFSET, one band further out: the
-- giver pins own 1001..1040 under MAX_GIVER_MARKERS.
local TURNIN_INDEX_OFFSET = 2000
-- Above the tiles for the same hit-test reason as the "!", but deliberately
-- below it. An NPC that both hands out one quest and takes another draws both
-- markers on one coordinate, and the "!" is the one carrying a shift-click,
-- so it must win that tie rather than leave it to draw order.
local TURNIN_LEVEL_BOOST = 3
-- A quest ender is a named NPC, not a spawn cloud like the CLUCK! chicken, so
-- this bound is a guard against a pathological record rather than a routine
-- cap. Kept well under MAX_LOCATIONS_PER_QUEST so one quest can never consume
-- the whole turn-in pool.
local MAX_TURNIN_LOCATIONS_PER_QUEST = 8
-- media/ActiveQuestIcon.tga (the turn-in "?") is a 19x32 portrait image, not
-- the square the other pins' 14x14 contract assumes. Height keeps the
-- confirmed 14 and width is derived from the source's own aspect ratio, so
-- Client.SetWorldMapPinSize stops SetAllPoints from squashing the glyph into
-- a square.
local TURNIN_ICON_HEIGHT = 14
local TURNIN_ICON_WIDTH = TURNIN_ICON_HEIGHT * 19 / 32
-- The multiply-only fallback for a client that will not desaturate. Only ever
-- reached when SetDesaturated is refused: there the icon keeps its own colour
-- and brightness is the last signal left, so the two states would otherwise be
-- identical. When greyscale works, the "?" is drawn at full brightness like
-- the "!" and this is never applied -- see the turn-in pass below.
local TURNIN_DIM = 0.55
-- Hovering one "!" or "?" grows it and dims every other "!"/"?" to half
-- opacity, so the hovered marker reads as the one under the mouse. Area
-- tiles are untouched -- they already have their own hover presentation.
local GIVER_TURNIN_HOVER_SCALE = 1.5
local GIVER_TURNIN_DIM_ALPHA = 0.5
-- Hovering a "?" is the mirror of hovering its area: the objective tiles for
-- whichever quest that turn-in point carries lighten towards white and go
-- more opaque, recomputed every Refresh tick (area colour is, unlike pin
-- size/alpha) rather than set once, so the highlight survives a rebuild.
local AREA_HIGHLIGHT_LIGHTEN = 0.5
local AREA_HIGHLIGHT_ALPHA = 0.85
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
WorldMapPins.turnInPool = {}
WorldMapPins.renderEnabled = true
WorldMapPins.visibleCount = 0
WorldMapPins.areaVisibleCount = 0
WorldMapPins.giverVisibleCount = 0
WorldMapPins.turnInVisibleCount = 0
WorldMapPins.dirty = true
WorldMapPins.lastSignature = nil
WorldMapPins.canvasDetected = false
WorldMapPins.lastDiagnosticKey = nil
WorldMapPins.lastSnapshotKey = nil
WorldMapPins.hoverArea = nil
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
    WorldMapPins.turnInVisibleCount = HidePoolFrom(WorldMapPins.turnInPool, 1)
end

local function ReapplyVisiblePool(pool, visibleCount)
    local index = 1
    while index <= visibleCount do
        Client.ReapplyWorldMapPin(pool[index])
        index = index + 1
    end
end

-- The bag token is part of the view because an item-use objective target is
-- drawn only while its item is carried: looting or consuming that item changes
-- what the map should show without anything about the quest log or the view
-- itself moving. The token only advances when the carried set's membership
-- changes, so an ordinary bag shuffle does not force a rebuild.
local function ViewSignature(areaId, report)
    local bagItems = BagItems()
    return tostring(areaId) .. "|" .. tostring(report and report.mapFile)
        .. "|" .. tostring(report and report.continent)
        .. "|" .. tostring(report and report.zoneIndex)
        .. "|" .. tostring(bagItems and bagItems:GetToken())
end

local function IsResolvedQuest(quest)
    return quest and type(quest.questId) == "number"
        and (quest.matchConfidence == "unique" or quest.matchConfidence == "levelDisambiguated")
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

-- Read-only: callers must not mutate the returned table.
function WorldMapPins:GetDefaultHiddenQuestIds()
    return DEFAULT_HIDDEN_QUEST_IDS
end

function WorldMapPins:IsQuestHidden(questId, config)
    return IsQuestMapHidden(config, questId)
end

-- Quest IDs from one giver that this character could actually pick up now:
-- not already in the quest log, not recorded done, not excluded by the
-- quest's own race/class/level/event restrictions, and not map-hidden -- a
-- quest withheld from the map should never resurface as a giver "!" either,
-- e.g. CLUCK! offered again by a chicken once the quest has left the log.
-- Order is preserved so the tooltip and the bulk mark-done act on the same
-- list.
local function FilterAvailableQuestIds(questIds, activeQuestIds, questHistory, eligibility, config)
    local out = {}
    local index = 1
    local total = table.getn(questIds)
    while index <= total do
        local questId = questIds[index]
        if type(questId) == "number" and not activeQuestIds[questId]
            and not (questHistory and questHistory:IsDone(questId))
            and not (eligibility and not eligibility:IsOfferable(questId))
            and not IsQuestMapHidden(config, questId) then
            table.insert(out, questId)
        end
        index = index + 1
    end
    return out
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
        if IsResolvedQuest(quest) and not IsQuestMapHidden(config, quest.questId)
            and (complete or includeInProgress) then
            local locations = database:GetQuestLocations(
                quest.questId, true, areaId, MAX_TURNIN_LOCATIONS_PER_QUEST)
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
                table.insert(point.quests, quest)
                if complete then
                    point.complete = true
                end
                index = index + 1
            end
        end
        questIndex = questIndex + 1
    end
    return ordered
end

-- True when a turn-in point carries the given quest among the (possibly
-- several) quests that end there.
local function PointHasQuest(point, questId)
    if not point or not point.quests or not questId then
        return false
    end
    local index = 1
    local total = table.getn(point.quests)
    while index <= total do
        local quest = point.quests[index]
        if quest and quest.questId == questId then
            return true
        end
        index = index + 1
    end
    return false
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
local function BuildGiverTooltipLines(database, giver, availableQuestIds)
    local lines = {}
    local name = giver.sourceType == "unit" and database:GetUnitName(giver.sourceId)
        or database:GetObjectName(giver.sourceId)
    table.insert(lines, { text = name or "Unknown", r = 0.3, g = 1, b = 0.8 })

    if giver.sourceType == "unit" then
        local unit = database:GetUnit(giver.sourceId)
        -- The bundled data stores unit levels as strings, and some are ranges
        -- ("5-8") rather than a single value, so the raw text is passed through
        -- instead of being coerced to a number.
        local level = unit and unit.lvl
        if level ~= nil and level ~= "" then
            table.insert(lines, { left = "Level:", right = tostring(level) })
        end
        table.insert(lines, { left = "Type:", right = "Unit" })
    else
        table.insert(lines, { left = "Type:", right = "Object" })
    end

    local index = 1
    local total = table.getn(availableQuestIds)
    while index <= total do
        local questId = availableQuestIds[index]
        local title = database:GetQuestTitle(questId)
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
                    left = "- Level: " .. tostring(record.lvl or "?"),
                    right = "Required: " .. tostring(record.min or "?"),
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
    if total > 1 then
        table.insert(lines, {
            text = "Shift-click to choose which quest is already done",
            r = 0.5, g = 0.5, b = 0.5,
        })
    elseif total > 0 then
        table.insert(lines, {
            text = "Shift-click to mark as already done",
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
    table.insert(lines, { text = name or "Unknown", r = 0.3, g = 1, b = 0.8 })

    if point.sourceType == "unit" then
        local unit = database:GetUnit(point.sourceId)
        -- Levels are strings in the bundled data, ranges included, so the raw
        -- text is passed through rather than coerced (see BuildGiverTooltipLines).
        local level = unit and unit.lvl
        if level ~= nil and level ~= "" then
            table.insert(lines, { left = "Level:", right = tostring(level) })
        end
        table.insert(lines, { left = "Type:", right = "Unit" })
    else
        table.insert(lines, { left = "Type:", right = "Object" })
    end
    table.insert(lines, { left = "Turns in:", right = tostring(table.getn(point.quests)) })

    local index = 1
    local total = table.getn(point.quests)
    while index <= total do
        local quest = point.quests[index]
        local title = quest.title
        if not title and type(quest.questId) == "number" then
            title = database:GetQuestTitle(quest.questId)
        end
        if index > 1 then
            table.insert(lines, { separator = true })
        end
        if quest.isComplete == 1 then
            table.insert(lines, { text = "[?] " .. (title or "Unknown"), r = 1, g = 0.82, b = 0 })
            table.insert(lines, {
                left = "- Status:", right = "Ready to turn in",
                rightR = 0.2, rightG = 1, rightB = 0.2,
            })
        else
            table.insert(lines, { text = "[?] " .. (title or "Unknown"), r = 0.6, g = 0.6, b = 0.6 })
            table.insert(lines, {
                left = "- Status:", right = "In progress",
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
    local title = quest.title
    if not title and type(quest.questId) == "number" then
        title = database:GetQuestTitle(quest.questId)
    end
    table.insert(lines, { text = title or "Unknown", r = 1, g = 0.82, b = 0 })

    if type(quest.level) == "number" then
        local red, green, blue = Client.GetQuestLevelColor(quest.level)
        table.insert(lines, {
            left = "Level:", right = tostring(quest.level),
            rightR = red, rightG = green, rightB = blue,
        })
    end
    if type(quest.questTag) == "string" and quest.questTag ~= "" then
        table.insert(lines, { left = "Type:", right = quest.questTag })
    end

    local complete = quest.isComplete == 1
    if complete then
        table.insert(lines, {
            left = "Status:", right = "Ready to turn in",
            rightR = 0.2, rightG = 1, rightB = 0.2,
        })
    else
        table.insert(lines, {
            left = "Status:", right = "In progress",
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
-- observed (docs/CLIENT-COMPATIBILITY.md, open question 8). Shift state is
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
    area = Client.CreateWorldMapArea(index, 0.15, 0.55, 1, AREA_ALPHA)
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
    -- Growing the "?" this quest hands in at links the objective area to its
    -- turn-in point the same way hovering a pin links it to itself.
    self:ApplyTurnInHoverForQuest(quest.questId)
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
    -- Same guard for the linked "?": only drop the highlight once nothing is
    -- still hovering a tile of the same quest, otherwise sliding across the
    -- tile seam between two of its own cells would flicker it off and on.
    local hoveredQuest = hovered and hovered.unrealQuestQuest
    local leavingQuest = area.unrealQuestQuest
    if not hoveredQuest or not leavingQuest or hoveredQuest.questId ~= leavingQuest.questId then
        self:ApplyTurnInHoverForQuest(nil)
    end
    -- Guarded by the tooltip's own owner check, so this cannot pull a tooltip
    -- that a neighbouring tile has already taken over.
    Client.HideMapTooltip(area)
end

-- Grows the "?" turn-in pin(s) carrying the given quest and dims every other
-- "?" to half opacity, mirroring ApplyGiverTurnInHover's own-pin-hover
-- treatment but keyed off a quest instead of a specific pin -- one turn-in
-- point can carry several quests, and a quest's turn-in can in principle be
-- split across more than one pooled pin. Passing nil restores every "?" to
-- its base size and full opacity. The "!" pool is untouched: an objective
-- area only ever links forward to where the quest is handed in.
function WorldMapPins:ApplyTurnInHoverForQuest(questId)
    local pool = self.turnInPool
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        local pin = pool[index]
        if pin and pin.unrealQuestBaseWidth and pin.unrealQuestBaseHeight then
            if questId and PointHasQuest(pin.unrealQuestTurnIn, questId) then
                Client.SetWorldMapPinSize(pin,
                    pin.unrealQuestBaseWidth * GIVER_TURNIN_HOVER_SCALE,
                    pin.unrealQuestBaseHeight * GIVER_TURNIN_HOVER_SCALE)
                Client.SetWorldMapPinAlpha(pin, 1)
            else
                Client.SetWorldMapPinSize(pin, pin.unrealQuestBaseWidth, pin.unrealQuestBaseHeight)
                Client.SetWorldMapPinAlpha(pin, questId and GIVER_TURNIN_DIM_ALPHA or 1)
            end
        end
        index = index + 1
    end
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
        -- The client's own available-quest "!" icon replaces the tinted solid
        -- surface. Everything else in the confirmed pin contract is unchanged:
        -- same 14x14 Button, same single BACKGROUND texture with SetAllPoints,
        -- same frame level -- only the image file and the tint differ, and no
        -- FontString label is created at all.
        Client.SetWorldMapPinTexture(pin, Client.AVAILABLE_QUEST_TEXTURE)
        -- A "!" is small and frequently sits inside a quest area, and every
        -- pool is otherwise created at the identical frame level, so without
        -- this the tile underneath can win the hit test and swallow the
        -- shift-click -- it takes the mouse for its own tooltip but has no
        -- OnClick to run. See Client.RaiseWorldMapPin.
        Client.RaiseWorldMapPin(pin, GIVER_LEVEL_BOOST)
        -- Base size the hover grow/shrink scales from and returns to.
        pin.unrealQuestBaseWidth = 14
        pin.unrealQuestBaseHeight = 14
        Client.SetWorldMapPinHandlers(pin,
            function() WorldMapPins:OnGiverEnter(pin) end,
            function() WorldMapPins:OnGiverLeave(pin) end,
            function() WorldMapPins:OnGiverClick(pin) end)
    end
    return pin
end

function WorldMapPins:OnGiverEnter(pin)
    RecordGiverHover()
    self:ApplyGiverTurnInHover(pin)
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
    local lines = BuildGiverTooltipLines(database, pin.unrealQuestGiver, pin.unrealQuestAvailableQuestIds or {})
    Client.ShowMapTooltip(pin, lines)
end

function WorldMapPins:OnGiverLeave(pin)
    self:ApplyGiverTurnInHover(nil)
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
    -- Redraw on the next tick instead of waiting out the refresh interval, so
    -- the "!" goes away as the player clicks it rather than up to a quarter
    -- second later. pfQuest does the same thing on its own mark-done click
    -- (pfMap.queue_update = GetTime()). Waking a job is the sanctioned way to
    -- accelerate the driver; it never replaces the poll.
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Wake("map.worldpins")
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
            local title = database:GetQuestTitle(questId)
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
    -- Mirrors OnAreaEnter's own-quest link, the other direction: the "?"
    -- highlights the objective tiles for every quest it hands in. Tracks the
    -- PIN, not its .unrealQuestTurnIn point: WakeMapDriver forces an
    -- immediate Refresh, which rebuilds CollectTurnInPoints into fresh point
    -- tables every tick, so a point captured here would already be a
    -- different object by the time OnTurnInLeave compares against it and the
    -- highlight would never clear. The pin's own identity is stable across
    -- rebuilds; Refresh reads its CURRENT .unrealQuestTurnIn each tick.
    self.hoverTurnInPin = pin
    self:WakeMapDriver()
    local database = Database()
    if not database or not pin.unrealQuestTurnIn then
        return
    end
    Client.ShowMapTooltip(pin, BuildTurnInTooltipLines(database, pin.unrealQuestTurnIn),
        self:ChooseTurnInTooltipAnchor(pin))
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
            and PointHasQuest(point, area.unrealQuestQuest.questId) then
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
    self:ApplyGiverTurnInHover(nil)
    if self.hoverTurnInPin == pin then
        self.hoverTurnInPin = nil
        self:WakeMapDriver()
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

-- Grows the hovered "!"/"?" and dims every other one to half opacity, so the
-- one under the mouse reads as distinct from the rest of the layer. Passing
-- nil restores every pin in both pools to its base size and full opacity.
-- Reapplied over the whole pool on every enter/leave rather than tracked
-- incrementally, matching the once-per-hover cost of the area tooltip path
-- above and staying correct across pool rebuilds without extra bookkeeping.
function WorldMapPins:ApplyGiverTurnInHover(hoveredPin)
    local pools = { self.giverPool, self.turnInPool }
    local poolIndex = 1
    while poolIndex <= table.getn(pools) do
        local pool = pools[poolIndex]
        local index = 1
        local total = table.getn(pool)
        while index <= total do
            local pin = pool[index]
            if pin and pin.unrealQuestBaseWidth and pin.unrealQuestBaseHeight then
                if pin == hoveredPin then
                    Client.SetWorldMapPinSize(pin,
                        pin.unrealQuestBaseWidth * GIVER_TURNIN_HOVER_SCALE,
                        pin.unrealQuestBaseHeight * GIVER_TURNIN_HOVER_SCALE)
                    Client.SetWorldMapPinAlpha(pin, 1)
                else
                    Client.SetWorldMapPinSize(pin, pin.unrealQuestBaseWidth, pin.unrealQuestBaseHeight)
                    Client.SetWorldMapPinAlpha(pin, hoveredPin and GIVER_TURNIN_DIM_ALPHA or 1)
                end
            end
            index = index + 1
        end
        poolIndex = poolIndex + 1
    end
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

    local areaId, report, viewReason = mapContext:GetCurrentZoneView()
    if not areaId then
        HideAllPools()
        self.dirty = true
        RecordDiagnostic("viewUnavailable:" .. tostring(viewReason), nil, report)
        return
    end

    local signature = ViewSignature(areaId, report)
    if not self.dirty and signature == self.lastSignature then
        ReapplyVisiblePool(self.pool, self.visibleCount)
        ReapplyVisiblePool(self.areaPool, self.areaVisibleCount)
        ReapplyVisiblePool(self.giverPool, self.giverVisibleCount)
        ReapplyVisiblePool(self.turnInPool, self.turnInVisibleCount)
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
    end
    self.lastSignature = signature

    -- A rebuild reassigns every pooled tile and marker, so hover state, which
    -- is per-quest, never carries over into the new layout. The held hover is
    -- re-resolved against the finished layout at the end of this pass.
    local heldHoverArea = self.hoverArea
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
    local quests = questState:GetOrderedQuests()
    local questIndex = 1
    local questTotal = table.getn(quests)

    -- Built once per refresh and reused by the giver pass below: a quest
    -- already in the player's log is never also "still to take".
    local activeQuestIds = {}
    while questIndex <= questTotal do
        local activeQuest = quests[questIndex]
        if IsResolvedQuest(activeQuest) then
            activeQuestIds[activeQuest.questId] = true
        end
        questIndex = questIndex + 1
    end
    questIndex = 1

    -- A hidden quest stays fully active (activeQuestIds above is unaffected,
    -- so its giver never reappears as "still to take"); only its own area
    -- tiles and turn-in marker are withheld below.
    while questIndex <= questTotal and markerIndex <= MAX_MARKERS do
        local quest = quests[questIndex]
        if IsResolvedQuest(quest) and not IsQuestMapHidden(rebuildConfig, quest.questId) then
            matchedQuests = matchedQuests + 1
            local complete = quest.isComplete == 1
            local locations, unknown = questTarget:CollectLocations(
                quest, areaId, complete)
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
            local componentIndex = 1
            local componentTotal = table.getn(components)
            while componentIndex <= componentTotal do
                local component = components[componentIndex]
                local cellIndex = 1
                local cellTotal = table.getn(component.cells)
                while AREA_RENDER_ENABLED and cellIndex <= cellTotal and areaIndex <= MAX_AREA_TILES do
                    local cell = component.cells[cellIndex]
                    local areaX, areaY = mapContext:DatabaseToCurrentMap(
                        areaId, cell.x, cell.y, report)
                    if areaX and areaY then
                        local area = self:GetArea(areaIndex)
                        if area then
                            local r, g, b, a
                            if complete and isMain then
                                r, g, b, a = 0.55, 1, 0.55, MAIN_AREA_ALPHA
                            elseif complete then
                                r, g, b, a = 0.2, 1, 0.2, COMPLETE_AREA_ALPHA
                            elseif isMain then
                                -- Alpha alone would not separate this from the
                                -- other blue tiles, so the main quest shifts
                                -- towards a paler blue as well. Alpha stays at
                                -- the 0.5 probe 1.29.0 confirmed visible: the
                                -- first 0.2 run was confirmed INVISIBLE on this
                                -- client, so nothing here may go below it.
                                r, g, b, a = 0.45, 0.82, 1, MAIN_AREA_ALPHA
                            else
                                r, g, b, a = 0.12, 0.55, 1, AREA_ALPHA
                            end
                            -- Hovering the "?" this quest hands in highlights
                            -- its own objective tiles. Recomputed here, every
                            -- tick, rather than set once on hover: this colour
                            -- assignment already runs every Refresh, so a
                            -- one-shot highlight would be overwritten within
                            -- one REFRESH_INTERVAL exactly like the marker
                            -- suppression case above.
                            local hoverPoint = self.hoverTurnInPin and self.hoverTurnInPin.unrealQuestTurnIn
                            if hoverPoint and PointHasQuest(hoverPoint, quest.questId) then
                                r = r + (1 - r) * AREA_HIGHLIGHT_LIGHTEN
                                g = g + (1 - g) * AREA_HIGHLIGHT_LIGHTEN
                                b = b + (1 - b) * AREA_HIGHLIGHT_LIGHTEN
                                a = AREA_HIGHLIGHT_ALPHA
                            end
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
    if database:IsGiverIndexReady() then
        local questHistory = QuestHistory()
        local eligibility = QuestEligibility()
        -- Once per pass, not once per giver: the player snapshot behind the
        -- race/class/level tests costs guarded client calls to build.
        if eligibility then
            eligibility:RefreshPlayer()
        end
        local givers = database:GetAreaQuestGivers(areaId, MAX_LOCATIONS_PER_QUEST)
        local giverIndex = 1
        local giverTotal = table.getn(givers)
        while giverIndex <= giverTotal and giverMarkerIndex <= MAX_GIVER_MARKERS do
            local giver = givers[giverIndex]
            local availableQuestIds = FilterAvailableQuestIds(
                giver.questIds, activeQuestIds, questHistory, eligibility, rebuildConfig)
            if table.getn(availableQuestIds) > 0 then
                local markerX, markerY = mapContext:DatabaseToCurrentMap(areaId, giver.x, giver.y, report)
                if markerX and markerY then
                    local pin = self:GetGiverPin(giverMarkerIndex)
                    if pin then
                        pin.unrealQuestGiver = giver
                        pin.unrealQuestAvailableQuestIds = availableQuestIds
                        if mapContext:PlaceOnWorldMap(pin, markerX, markerY) then
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
    -- walks the quest log, not the database, and every quest it reads has
    -- already been resolved to an ID by the matcher, which is only possible
    -- once the title index is ready -- a condition Refresh checked above.
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
                -- The icon carries its own colours, so "ready" is simply the
                -- untinted file and "still in progress" is the same file in
                -- grey -- one texture, two states, no second asset to fail to
                -- load.
                --
                -- Grey means greyscale, not "darker yellow". Scaling the
                -- vertex colour multiplies the client's yellow "?" and leaves
                -- it yellow, which is how the in-progress marker was reported
                -- as looking active. SetDesaturated is the real switch.
                --
                -- Both states are drawn at full brightness, the same (1, 1, 1)
                -- the giver "!" is created with. Multiplying the vertex colour
                -- on top of greyscale only added a shadow that read as dirt on
                -- the map rather than as "not ready yet" -- greyscale alone
                -- already carries that, and the dim survives solely as the
                -- fallback for a client that refuses to desaturate at all.
                if point.complete then
                    Client.SetWorldMapPinDesaturated(pin, false)
                    Client.SetWorldMapPinColor(pin, 1, 1, 1)
                else
                    local greyscale = Client.SetWorldMapPinDesaturated(pin, true)
                    if greyscale then
                        Client.SetWorldMapPinColor(pin, 1, 1, 1)
                    else
                        Client.SetWorldMapPinColor(
                            pin, TURNIN_DIM, TURNIN_DIM, TURNIN_DIM)
                    end
                end
                if mapContext:PlaceOnWorldMap(pin, markerX, markerY) then
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

    self.visibleCount = HidePoolFrom(self.pool, markerIndex)
    self.areaVisibleCount = HidePoolFrom(self.areaPool, areaIndex)
    self.giverVisibleCount = HidePoolFrom(self.giverPool, giverMarkerIndex)
    self.turnInVisibleCount = HidePoolFrom(self.turnInPool, turnInMarkerIndex)

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

-- Whether a quest has a database match confident enough to draw. A hypothesis
-- with a confidence, never an identity -- see the addon's matching rules.
function WorldMapPins:IsResolvedQuest(quest)
    return IsResolvedQuest(quest)
end

-- Quest IDs already in the player's log, which is what makes a giver's quest
-- "taken" rather than "still to take".
function WorldMapPins:BuildActiveQuestIds(quests)
    local active = {}
    local index = 1
    local total = table.getn(quests or {})
    while index <= total do
        local quest = quests[index]
        if IsResolvedQuest(quest) then
            active[quest.questId] = true
        end
        index = index + 1
    end
    return active
end

-- Givers in one area with at least one quest this character could take now.
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
    local source = database:GetAreaQuestGivers(areaId, maxLocations or MAX_LOCATIONS_PER_QUEST)
    local index = 1
    local total = table.getn(source)
    while index <= total do
        local giver = source[index]
        local availableQuestIds = FilterAvailableQuestIds(
            giver.questIds, activeQuestIds, questHistory, eligibility, config)
        if table.getn(availableQuestIds) > 0 then
            table.insert(givers, { giver = giver, questIds = availableQuestIds })
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
        turnInVisible = self.turnInVisibleCount,
        turnInPooled = table.getn(self.turnInPool),
        inProgressTurnIns = ShowInProgressTurnIns(),
        areasEnabled = AREA_RENDER_ENABLED,
        markersEnabled = MARKER_RENDER_ENABLED,
        renderEnabled = self.renderEnabled,
        areaHovers = self.hoverCount or 0,
        giverHovers = self.giverHoverCount or 0,
        giverClicks = self.giverClickCount or 0,
        turnInHovers = self.turnInHoverCount or 0,
        rebuilds = self.rebuildCount or 0,
        itemUseUnknown = self.itemUseUnknown or 0,
        capped = self.visibleCount >= MAX_MARKERS or self.areaVisibleCount >= MAX_AREA_TILES,
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
    self:Refresh()
end
