--[[
UnrealQuest / Quest/QuestClicks.lua

Clicking a quest -- in the quest log, or in the HUD tracker -- makes it the
main quest.

The two surfaces need opposite techniques, and getting that backwards is the
bug this file is shaped to avoid.

## The quest log: chain, never overlay

`QuestLogTitle<N>` rows are real Buttons whose click already means something:
it selects the quest and fills the detail pane. An addon Button laid over the
row would take that click and the row would stop working -- exactly the failure
already recorded on the map, where an area tile at the same frame level
silently swallowed the giver pin's click.

So the row's own OnClick is chained: the native handler runs first, then
UnrealQuest's. There is no `hooksecurefunc` on this client at all
(hooks.no_global_hooksecurefunc), so the chain is built by hand out of
`GetScript` + `SetScript` in Compatibility/ClientAPI.lua.

Two client facts shape the chaining:
  * `SetScript(type, nil)` does not detach a script here, so a chain can never
    be removed once installed. Installation is therefore made idempotent with a
    marker field rather than by undoing and redoing it.
  * Clicking a `QuestLogTitle` HEADER row is confirmed in game to do nothing on
    this client (questlog.header_row_onclick_does_not_collapse). That is a
    recorded fault in the native handler, so a header row may simply never
    reach our addition -- which is harmless, because a header is not a quest.

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
local MAX_LOG_ROWS = 30
local MAX_WATCH_LINES = 30
local CHAIN_MARKER = "unrealQuestMainQuestChained"

QuestClicks.surfaces = {}
QuestClicks.surfaceQuest = {}
QuestClicks.chainedRows = 0
QuestClicks.logClicks = 0
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

-- Plain left-click is the default, which is what was asked for, but it does
-- mean browsing the quest log re-points the waypoint on every row you read.
-- `mainQuestClickModifier` turns that into a held-modifier gesture without a
-- code change for anyone who would rather browse freely.
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

-- Resolves a quest log row to a quest: by the stamped quest log index when the
-- client provides one, otherwise by the row's text.
local function QuestFromLogRow(row)
    local questState = QuestState()
    if not questState then
        return nil
    end

    local id = Client.GetFrameId(row)
    if id then
        local title, _, _, isHeader = Client.GetQuestLogEntry(id)
        if title and not isHeader then
            local titleKey = UQ.NameKey(title)
            local quest = titleKey and questState:GetQuest(titleKey)
            if quest then
                return quest
            end
        end
    end

    return QuestFromText(row)
end

-- Selection ------------------------------------------------------------------

function QuestClicks:Select(quest, origin)
    if not quest or not quest.titleKey then
        return false
    end
    local mainQuest = MainQuest()
    if not mainQuest then
        return false
    end

    local wasMain = mainQuest:IsMain(quest.titleKey)
    mainQuest:Toggle(quest.titleKey)
    local title = UQ.GetQuestDisplayTitle(quest) or quest.title

    if wasMain then
        UQ:Print(UQ.L("MAINQUEST_NO_LONGER_FOLLOWING",
            "|cffffffff" .. tostring(title) .. "|r"))
    else
        UQ:Print(UQ.L("MAINQUEST_NOW_FOLLOWING",
            "|cff" .. UQ.colors.accentHex .. tostring(title) .. "|r"))
    end
    UQ:Debug("main quest click from " .. tostring(origin))
    return true
end

-- Reveal on map ---------------------------------------------------------------
--
-- Shared "take me there" gesture: the tracker window's Ctrl+click
-- (Quest/TrackerFrame.lua) and the quest log's Show button
-- (Quest/QuestLogButtons.lua) both call this rather than each having their
-- own copy, so they cannot silently drift apart.
--
-- Best-effort. Opens the map (never a guaranteed success -- see
-- Client.OpenWorldMap) and flashes the quest's own pin(s) through
-- Map/WorldMapPins.lua, which only ever flashes a pin that is ALREADY
-- rendered. A quest with no unambiguous database match, in the wrong zone, or
-- hidden from the map by the player has nothing to flash, and that is
-- reported rather than silently doing nothing -- the same honesty rule every
-- other capability in this addon follows.

-- Names every zone the static data records a location in for this quest's
-- CURRENT relation (finisher if complete, objective otherwise), regardless of
-- which zone the player is standing in or the map is currently viewing.
-- Database:GetQuestAreaIds carries none of GetQuestLocations' current-zone
-- filter, so this can answer "which zone" even when nothing can be drawn.
-- Returns nil when the data names none (an unmatched quest, or one whose
-- bundled record simply has no coordinate for this relation at all -- 174 of
-- 4433 quests have no `end` relation, see Database:GetQuestLocations).
local function DescribeQuestZones(quest)
    local database = Database()
    if not database or type(quest.questId) ~= "number" then
        return nil
    end
    local areaIds = database:GetQuestAreaIds(quest.questId, quest.isComplete == 1)
    local total = table.getn(areaIds)
    if total == 0 then
        return nil
    end
    local names = {}
    local index = 1
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
    local pins = UQ:GetModule("WorldMapPins")
    if pins and pins:FlashQuest(quest.questId) then
        return
    end
    -- Nothing is currently rendered for it -- most often because its
    -- objective or turn-in is not in the zone the map is presently viewing,
    -- the addon's map layer only ever draws in the player's own uniquely
    -- resolved current area (docs/CLIENT-COMPATIBILITY.md, "Area-ID join
    -- scope"). A pin cannot be faked into that other zone, but the static
    -- data can still be asked WHICH zone, so the player is told where to go
    -- even though nothing was drawn.
    local zones = DescribeQuestZones(quest)
    if zones then
        -- Two whole sentences rather than a shared one with the verb swapped
        -- in: a language that inflects around it cannot be built from a
        -- fragment slotted into the middle of another string.
        if quest.isComplete == 1 then
            UQ:Print(UQ.L("REVEAL_TURN_IN_ELSEWHERE", tostring(title), zones))
        else
            UQ:Print(UQ.L("REVEAL_OBJECTIVES_ELSEWHERE", tostring(title), zones))
        end
    else
        UQ:Print(UQ.L("REVEAL_NOTHING_KNOWN", tostring(title)))
    end
end

-- Quest log ------------------------------------------------------------------

function QuestClicks:InstallLogRow(index)
    local row = Client.GetNamedObject("QuestLogTitle" .. tostring(index))
    if not row then
        return false, "missing"
    end
    if Client.IsScriptChained(row, CHAIN_MARKER) then
        return true, "already"
    end

    -- The row is captured in the closure rather than read from the implicit
    -- `this` global at call time: one less client global in the hot path, and
    -- it cannot be clobbered by an event dispatch between click and handler.
    local installed = Client.ChainScript(row, "OnClick", function()
        if not ModifierSatisfied() then
            return
        end
        local quest = QuestFromLogRow(row)
        if quest then
            QuestClicks.logClicks = QuestClicks.logClicks + 1
            QuestClicks:Select(quest, "questLog")
        end
    end)
    if not installed then
        return false, "chainFailed"
    end

    Client.MarkScriptChained(row, CHAIN_MARKER)
    self.chainedRows = self.chainedRows + 1
    return true, "installed"
end

-- Walks the quest log rows and chains any that are not chained yet. Re-run
-- periodically rather than once: this client is recorded as recreating quest
-- log artwork on show, and a row created later would otherwise never be wired.
function QuestClicks:InstallLogRows()
    local index = 1
    local misses = 0
    while index <= MAX_LOG_ROWS and misses < 3 do
        local ok, reason = self:InstallLogRow(index)
        if not ok and reason == "missing" then
            misses = misses + 1
        else
            misses = 0
        end
        index = index + 1
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
        chainedRows = self.chainedRows,
        logClicks = self.logClicks,
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
    config:SetSectionEntry("clickDiagnostics", "chainedRows", self.chainedRows)
    config:SetSectionEntry("clickDiagnostics", "logClicks", self.logClicks)
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
    UQ:DeclareCapability("questLogRowClick", "documented",
        "Frame:GetScript and Frame:SetScript are both in the client API reference, which is the only "
        .. "route to adding behaviour to a native row here -- this client has no hooksecurefunc. "
        .. "Unverified in one respect worth knowing: clicking a QuestLogTitle HEADER row is confirmed "
        .. "in game to do nothing on this client, so whether a QUEST row's OnClick fires at all is "
        .. "measured by /uq main's click counters rather than assumed")
    UQ:DeclareCapability("questWatchLineClick", "detected",
        "QuestWatchFrame is a confirmed native frame and its lines are FontStrings, which cannot take "
        .. "a click on any client, so an addon-owned Button is anchored over each line. A 14x14 "
        .. "addon-owned Button is already measured to receive OnClick on this client "
        .. "(worldmap.custom_14x14_pin_receives_mouse_and_clicks); a watch-line-sized one over a "
        .. "native frame is not, and /uq main reports the click counts that decide it")
end

function QuestClicks:OnEnable()
    -- This gate check MUST stay above InstallLogRows, and it is the one gate in
    -- the addon that is not merely a performance measure.
    --
    -- InstallLogRows chains a handler onto every native QuestLogTitle row, and
    -- SetScript(type, nil) does not detach a script on this client: a chain
    -- installed once survives for the session and cannot be undone. Disabling
    -- the layer after installation would therefore leave dead closures running
    -- on every quest log click for as long as the player stays logged in. The
    -- only way to have no chain is to never install one.
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        return
    end

    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end

    self:InstallLogRows()

    -- One second: this is repair work, not a hot path. Rows that already carry
    -- the chain are skipped by their marker field.
    driver:Schedule("clicks.logrows", 1, function()
        QuestClicks:InstallLogRows()
    end)

    driver:Schedule("clicks.watchoverlay", 0.5, function()
        QuestClicks:RefreshWatchOverlay()
    end)

    driver:Schedule("clicks.diagnostics", 5, function()
        QuestClicks:RecordDiagnostics()
    end)
end
