--[[
UnrealQuest / Quest/QuestClicks.lua

Quest-log rows keep their native job: selecting a quest and filling the detail
pane. They deliberately do not change the followed quest. The dedicated
Following button in Quest/QuestLogButtons.lua owns that action.

## The HUD tracker: overlay, never chain

`QuestWatchLine<N>` are FontStrings. A FontString cannot receive a click on any
client, so there is nothing to chain and an addon-owned Button over the line is
the only way. Swallowing the click is safe here for the exact reason it was
unsafe above: the native watch frame has no click behaviour to swallow.

## Which quest a widget belongs to

Neither surface hands over a quest id -- this client has none. The row's
`GetID()` is tried first, since Vanilla's QuestLog_Update stamps the quest log
index onto the row; when that is absent or stale, the widget's own text is
normalized and matched against the quest model's title keys. Because
`UQ.NameKey` strips everything but letters and digits, a row reading
"[5] Kobold Camp Cleanup" normalizes to "5koboldcampcleanup", and the quest's
own key is a suffix of it -- so the match needs no parsing of the level prefix
or of colour escapes.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestClicks = UQ:NewModule("QuestClicks")

-- Vanilla shows far fewer rows than this; scanning past the end is free
-- because a missing global simply resolves to nil.
local MAX_WATCH_LINES = 30

QuestClicks.surfaces = {}
QuestClicks.surfaceQuest = {}
QuestClicks.watchClicks = 0
QuestClicks.watchSignature = nil
QuestClicks.watchLinesMapped = 0

local function Config()
    return UQ:GetModule("Config")
end

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

local function Database()
    return UQ:GetModule("Database")
end

-- Modifier gate --------------------------------------------------------------

-- Plain left-click is the tracker default. The quest log uses its explicit
-- Following button instead, so browsing the detail pane never repoints the
-- navigator.
local function ModifierSatisfied()
    local config = Config()
    local modifier = config and config:Get("mainQuestClickModifier")
    if type(modifier) ~= "string" or modifier == "" or modifier == "none" then
        return true
    end
    if modifier == "shift" then
        return Client.IsShiftKeyDown()
    end
    if modifier == "ctrl" or modifier == "control" then
        return Client.IsControlKeyDown()
    end
    if modifier == "alt" then
        return Client.IsAltKeyDown()
    end
    return true
end

-- Identity -------------------------------------------------------------------

-- Normalized text of a widget, or nil. Colour escapes survive NameKey as
-- alphanumerics ("|cff808080" becomes "cff808080"), which is why the match
-- below is a suffix match rather than an equality test.
local function ObjectKey(object)
    local text = Client.GetObjectText(object)
    if not text then
        return nil
    end
    return UQ.NameKey(text)
end

local function KeyIsSuffix(textKey, titleKey)
    if not textKey or not titleKey then
        return false
    end
    local textLength = string.len(textKey)
    local titleLength = string.len(titleKey)
    if titleLength > textLength then
        return false
    end
    return string.sub(textKey, textLength - titleLength + 1) == titleKey
end

-- Finds the quest whose live or translated display-title key is a suffix of
-- the widget's normalized text. The second key matters only for a native Quest
-- Log row whose stamped ID is unavailable after QuestLogLevels rewrote its
-- presentation. The longest match wins, so a quest whose title is a suffix of
-- another quest's title cannot steal the click.
local function QuestFromText(object)
    local key = ObjectKey(object)
    if not key then
        return nil
    end
    local questState = QuestState()
    if not questState then
        return nil
    end

    local quests = questState:GetOrderedQuests()
    local best, bestLength = nil, 0
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        local titleKey = quest.titleKey
        local displayKey = UQ.NameKey(UQ.GetQuestDisplayTitle(quest))
        local matchedKey = nil
        if KeyIsSuffix(key, titleKey) then
            matchedKey = titleKey
        end
        if KeyIsSuffix(key, displayKey)
            and (not matchedKey or string.len(displayKey) > string.len(matchedKey)) then
            matchedKey = displayKey
        end
        if matchedKey and string.len(matchedKey) > bestLength then
            best = quest
            bestLength = string.len(matchedKey)
        end
        index = index + 1
    end
    return best
end

-- Resolves a quest log row to a quest: by the quest log index the row is
-- showing when one can be established, otherwise by the row's text.
--
-- The scrolled index comes first, and the row's stamped ID is consulted only
-- when that index names nothing at all -- the two agree only while the list is
-- unscrolled (knowledge record questlog.row_id_never_follows_the_scroll_offset).
-- A header row ends the search rather than falling through to its stale ID:
-- otherwise the followed quest's plaque appears on the header as well as on
-- the row the quest actually scrolled to.
local function QuestFromLogRow(row, rowIndex)
    local questState = QuestState()
    if not questState then
        return nil
    end

    local textQuest = QuestFromText(row)
    local primary, fallback = Client.GetQuestLogRowQuestIndex(row, rowIndex)

    local title, isHeader = nil, nil
    if primary then
        -- Kept local: a bare "_" placeholder at this scope would write a global.
        local resolved, _, _, resolvedHeader = Client.GetQuestLogEntry(primary)
        title = resolved
        isHeader = resolvedHeader
    end
    if title then
        if isHeader then
            return nil
        end
        local titleKey = UQ.NameKey(title)
        local quest = titleKey and questState:GetQuest(titleKey)
        if quest and (not textQuest or textQuest == quest) then
            return quest
        end
        return textQuest
    end

    if fallback then
        local fallbackTitle, _, _, fallbackHeader =
            Client.GetQuestLogEntry(fallback)
        if fallbackTitle and not fallbackHeader then
            local fallbackKey = UQ.NameKey(fallbackTitle)
            local quest = fallbackKey and questState:GetQuest(fallbackKey)
            if quest and (not textQuest or textQuest == quest) then
                return quest
            end
        end
    end

    return textQuest
end

-- Selection ------------------------------------------------------------------

local function RefreshFollowingSurfaces()
    local navigator = UQ:GetModule("Navigator")
    if navigator then
        navigator:Refresh()
    end
    local trackerFrame = UQ:GetModule("TrackerFrame")
    if trackerFrame then
        trackerFrame.dirty = true
        trackerFrame:Refresh()
    end
    local questLogButtons = UQ:GetModule("QuestLogButtons")
    if questLogButtons then
        questLogButtons:Refresh()
    end
end

-- Shared by the modern quest-log decoration. Keeping row identity here means
-- the highlight and the explicit Following button use the same selected quest
-- even when a skin rewrites the row text or drops its stamped ID.
function QuestClicks:GetQuestFromLogRow(row, rowIndex)
    return QuestFromLogRow(row, rowIndex)
end

function QuestClicks:Select(quest, origin)
    if not quest or not quest.titleKey then
        return false
    end
    local mainQuest = MainQuest()
    if not mainQuest then
        return false
    end

    local previousKey = mainQuest:Get()
    local wasMain = mainQuest:IsMain(quest.titleKey)
    if wasMain and mainQuest:IsAutomatic() then
        -- This is already the nearest-node answer. Clicking it cannot remove
        -- the one following state the navigator must always have.
        return false, "automaticUnchanged"
    end

    if wasMain then
        mainQuest:ReturnToAutomatic()
    else
        mainQuest:Set(quest.titleKey)
    end
    RefreshFollowingSurfaces()

    local followed = mainQuest:GetQuest()
    if followed and (not wasMain or mainQuest:Get() ~= previousKey) then
        local title = UQ.GetQuestDisplayTitle(followed) or followed.title
        UQ:Print(UQ.L("MAINQUEST_NOW_FOLLOWING",
            "|cff" .. UQ.colors.accentHex .. tostring(title) .. "|r"))
    end
    UQ:Debug("main quest click from " .. tostring(origin))
    return true, wasMain and "automatic" or "manual"
end

-- Reveal on map ---------------------------------------------------------------
--
-- Shared "take me there" gesture: the tracker window's Ctrl+click
-- (Quest/TrackerFrame.lua) and the quest log's Show button
-- (Quest/QuestLogButtons.lua) both call this rather than each having their
-- own copy, so they cannot silently drift apart.
--
-- "There" is the quest's CURRENT relation: its turn-in once it is complete,
-- its objectives while it is not. Those are routinely in different zones --
-- the report this is shaped around is quest 1088, whose head drops in
-- Ashenvale and is handed in at Sun Rock Retreat in the Stonetalon Mountains
-- -- and the map opening on the zone the player happens to be standing in is
-- exactly the wrong answer for a player asking where to go next.
--
-- So the map is taken to the zone. The world map pin layer already draws
-- whichever zone the map is SHOWING rather than the zone the player is in
-- (Map/WorldMapPins.lua, MapContext:GetViewedZone), so once the view moves,
-- the pins for the relation appear there on their own and the flash has
-- something to raise. Only the view had to change; nothing about the pin
-- layer, and no foreign-zone coordinate transform, is involved.
--
-- Moving the view is not free: everything that measures from the player's own
-- position -- minimap pins, the HUD waypoint, the rare alert -- needs the
-- open map to be the player's own zone. MapContext parks and hands back the
-- view for exactly that reason; see its "Parked view" section.
--
-- ## Order: decide the zone, then redraw, then flash. Never flash first.
--
-- The first version of this asked FlashQuest whether the quest was already on
-- screen and, if it was, returned without touching the view. That made the
-- whole feature intermittent, and the reason is the pin pools. They hold
-- whatever was drawn last, the redraw that would reassign them runs on a
-- 0.25s job, and this client is recorded leaving a frame's shown state true
-- after the fullscreen map closes (docs/WORLD-MAP-PINS-RECOVERY.md) -- so at
-- the instant of a click the pools can still be holding lit pins for a zone
-- that is no longer being viewed at all. A leftover pin from a previous
-- reveal of the same quest answered "already on screen", the map was left
-- wherever it was, and the same click on the same quest did the right thing
-- or the wrong thing depending on whether a 0.25s job had run in between.
--
-- So the target zone is now decided from the static data first, the view is
-- moved (or found already correct), the layer is redrawn for whatever view is
-- open, and only then is the flash asked to raise something. The flash reports
-- what is on screen; it no longer decides where the map points.
--
-- Still best-effort at every step. Opening the map is never a guaranteed
-- success (Client.OpenWorldMap), the zone may be one the client will not list,
-- and a quest with no unambiguous database match or one hidden from the map
-- has nothing to flash. Each of those is reported rather than silently doing
-- nothing -- the same honesty rule every other capability in this addon
-- follows.

-- Every area the static data records for this quest's current relation
-- (finisher if complete, objective otherwise), ordered by Database so the
-- first entry is the zone with the most recorded spawns. Carries none of
-- GetQuestLocations' current-zone filter, so it answers "which zone" even
-- when nothing can be drawn in the one on screen. Empty for an unmatched
-- quest, and for one whose bundled record has no coordinate for this relation
-- at all -- 174 of 4433 quests have no `end` relation, see
-- Database:GetQuestLocations.
local function QuestAreaIds(quest, complete)
    local database = Database()
    if not database or type(quest.questId) ~= "number" then
        return {}
    end
    return database:GetQuestAreaIds(quest.questId, complete)
end

-- Names the areas, in the order given, as one comma-separated string. Returns
-- nil when none of them has a name, so the caller can tell "the data says
-- nowhere" from "the data says here".
local function DescribeAreas(areaIds)
    local database = Database()
    if not database or type(areaIds) ~= "table" then
        return nil
    end
    local names = {}
    local index = 1
    local total = table.getn(areaIds)
    while index <= total do
        local name = database:GetZoneName(areaIds[index])
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
        end
        index = index + 1
    end
    if table.getn(names) == 0 then
        return nil
    end
    return table.concat(names, ", ")
end

-- Each outcome below is two whole sentences -- one for a complete quest, one
-- for a quest still being worked on -- rather than one sentence with a
-- fragment slotted into the middle of it, because a language that inflects
-- around that fragment cannot be built out of one.
--
-- Written out as six literal UQ.L calls rather than looked up from a table of
-- key names: tools/locale/gen_locales.py finds a string's call sites by
-- scanning for the literal, and a key it cannot see is reported as an unused
-- catalog entry -- which is exactly the signal that catches a real typo.
local function PrintRevealZoneOpened(complete, title, zone)
    if complete then
        UQ:Print(UQ.L("REVEAL_TURN_IN_ZONE_OPENED", tostring(title), zone))
    else
        UQ:Print(UQ.L("REVEAL_OBJECTIVES_ZONE_OPENED", tostring(title), zone))
    end
end

local function PrintRevealNotDrawn(complete, title, zone)
    if complete then
        UQ:Print(UQ.L("REVEAL_TURN_IN_NOT_DRAWN", tostring(title), zone))
    else
        UQ:Print(UQ.L("REVEAL_OBJECTIVES_NOT_DRAWN", tostring(title), zone))
    end
end

local function PrintRevealElsewhere(complete, title, zones)
    if complete then
        UQ:Print(UQ.L("REVEAL_TURN_IN_ELSEWHERE", tostring(title), zones))
    else
        UQ:Print(UQ.L("REVEAL_OBJECTIVES_ELSEWHERE", tostring(title), zones))
    end
end

function QuestClicks:RevealOnMap(quest)
    if not quest then
        return
    end
    local title = UQ.GetQuestDisplayTitle(quest) or quest.title
    if type(quest.questId) ~= "number" then
        UQ:Print(UQ.L("REVEAL_NO_QUEST_ID", tostring(title)))
        return
    end
    Client.OpenWorldMap()

    local complete = quest.isComplete == 1
    local areaIds = QuestAreaIds(quest, complete)
    if table.getn(areaIds) == 0 then
        -- The data records no coordinate for this relation, so there is no
        -- zone to go to and no pin that could exist for it either -- every
        -- pin this addon draws is built from the same records.
        UQ:Print(UQ.L("REVEAL_NOTHING_KNOWN", tostring(title)))
        return
    end

    local mapContext = UQ:GetModule("MapContext")
    local shownArea, how = nil, nil
    if mapContext then
        shownArea, how = mapContext:ShowAreas(areaIds)
        if how == "switched" then
            -- Parked before the redraw below, not after: the redraw asks
            -- MapContext what is being viewed, and the cold-start primer it
            -- goes through must already know this view was moved on purpose.
            mapContext:ParkView(shownArea)
        end
    end

    -- Redraw for whatever view is open NOW, before anything is flashed. See
    -- the order note in this file's header: without this the flash reads the
    -- previous zone's leftovers.
    local pins = UQ:GetModule("WorldMapPins")
    local flashed = false
    if pins then
        pins.dirty = true
        pins:Refresh()
        flashed = pins:FlashQuest(quest.questId) and true or false
    end

    if how == "switched" then
        PrintRevealZoneOpened(complete, title, DescribeAreas({ shownArea }))
        return
    end

    -- Nothing moved, because the map was already showing a zone this quest
    -- has a recorded location in. A pin was raised there, or the quest is
    -- hidden from the map and none exists -- either way "wrong zone" would be
    -- false, so silence or the not-drawn line, never the elsewhere line.
    if how == "alreadyViewed" then
        if not flashed then
            PrintRevealNotDrawn(complete, title, DescribeAreas({ shownArea }))
        end
        return
    end

    -- The client would not show any of the zones -- an instance, a
    -- battleground, an area with no map of its own -- or the view refused to
    -- move. If something is on screen for the quest anyway, raising it was
    -- the whole request and needs no commentary; otherwise the data still
    -- knows where to go, so the player is told.
    if flashed then
        return
    end
    local zones = DescribeAreas(areaIds)
    if zones then
        PrintRevealElsewhere(complete, title, zones)
    else
        UQ:Print(UQ.L("REVEAL_NOTHING_KNOWN", tostring(title)))
    end
end

-- HUD tracker ----------------------------------------------------------------

function QuestClicks:GetSurface(index)
    local surface = self.surfaces[index]
    if surface then
        return surface
    end
    local parent = Client.GetNamedObject("QuestWatchFrame")
    if not parent then
        return nil
    end
    surface = Client.CreateClickSurface(index, parent)
    if not surface then
        return nil
    end
    Client.ChainScript(surface, "OnClick", function()
        if not ModifierSatisfied() then
            return
        end
        local quest = QuestClicks.surfaceQuest[index]
        if quest then
            QuestClicks.watchClicks = QuestClicks.watchClicks + 1
            QuestClicks:Select(quest, "questWatch")
        end
    end)
    self.surfaces[index] = surface
    return surface
end

-- Rebuilds the overlay over the native watch lines.
--
-- The watch frame lists a quest's title and then its objective lines, with no
-- structure an addon can read. So the lines are walked in order: a line whose
-- text resolves to a quest is a title line and claims every following line
-- until the next one does. That makes an objective line clickable too, which
-- is what a player expects -- clicking any part of a tracked quest follows it.
function QuestClicks:RefreshWatchOverlay()
    local watchFrame = Client.GetNamedObject("QuestWatchFrame")
    if not watchFrame then
        return
    end

    -- Cheap change detection so the overlay is not re-anchored 30 times a
    -- second for a tracker that has not moved.
    local signature = ""
    local index = 1
    while index <= MAX_WATCH_LINES do
        local line = Client.GetNamedObject("QuestWatchLine" .. tostring(index))
        if line then
            signature = signature .. "|" ..
                (Client.IsObjectShown(line) and (Client.GetObjectText(line) or "") or "-")
        end
        index = index + 1
    end
    if signature == self.watchSignature then
        return
    end
    self.watchSignature = signature

    local currentQuest = nil
    local mapped = 0
    index = 1
    while index <= MAX_WATCH_LINES do
        local line = Client.GetNamedObject("QuestWatchLine" .. tostring(index))
        local surface = nil
        if line and Client.IsObjectShown(line) then
            local quest = QuestFromText(line)
            if quest then
                currentQuest = quest
            end
            if currentQuest then
                surface = self:GetSurface(index)
                if surface then
                    self.surfaceQuest[index] = currentQuest
                    if Client.PlaceClickSurface(surface, line) then
                        mapped = mapped + 1
                    end
                end
            end
        end
        if not surface then
            self.surfaceQuest[index] = nil
            local existing = self.surfaces[index]
            if existing then
                Client.HideObject(existing)
            end
        end
        index = index + 1
    end
    self.watchLinesMapped = mapped
end

-- Reporting ------------------------------------------------------------------

function QuestClicks:GetReport()
    return {
        watchClicks = self.watchClicks,
        watchLinesMapped = self.watchLinesMapped,
        modifier = (Config() and Config():Get("mainQuestClickModifier")) or "none",
    }
end

function QuestClicks:RecordDiagnostics()
    local config = Config()
    if not config then
        return
    end
    config:SetSectionEntry("clickDiagnostics", "watchClicks", self.watchClicks)
    config:SetSectionEntry("clickDiagnostics", "watchLinesMapped", self.watchLinesMapped)
end

-- Lifecycle ------------------------------------------------------------------

function QuestClicks:OnInit()
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        -- Same reasoning as MainQuest:OnInit -- a gated layer declares no
        -- capabilities, because it establishes nothing about this client.
        return
    end
    UQ:DeclareCapability("questWatchLineClick", "detected",
        "QuestWatchFrame is a confirmed native frame and its lines are FontStrings, which cannot take "
        .. "a click on any client, so an addon-owned Button is anchored over each line. A 14x14 "
        .. "addon-owned Button is already measured to receive OnClick on this client "
        .. "(worldmap.custom_14x14_pin_receives_mouse_and_clicks); a watch-line-sized one over a "
        .. "native frame is not, and /uq main reports the click counts that decide it")
end

function QuestClicks:OnEnable()
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        return
    end

    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end

    driver:Schedule("clicks.watchoverlay", 0.5, function()
        QuestClicks:RefreshWatchOverlay()
    end)

    driver:Schedule("clicks.diagnostics", 5, function()
        QuestClicks:RecordDiagnostics()
    end)
end
