--[[
UnrealQuest / Quest/TrackerFrame.lua

The quest tracker window: a movable panel that lists EVERY quest in the
player's log, grouped by its quest log zone header, with each quest's
objectives and their progress underneath it.

Why this exists next to Quest/Tracker.lua, which is also called "tracker":
they answer different questions. `Tracker` owns UnrealQuest's unlimited saved
selection and mirrors up to five entries into the capped native watch list.
This file owns the DISPLAY. An addon-tracked quest is marked here with an
accent stripe whether or not it fits in the native mirror.

## What it draws

    UnrealQuest                      6/12  [spyglass] -
    ELWYNN FOREST
      [5] Kobold Camp Cleanup
          Kobold Vermin slain: 2/5   [====      ]
      [7] Wolves Across the Border
          Ready to turn in
    WESTFALL
      ...

Zone rows, quest rows and objective rows come from three separate widget pools
because each has its own font, and a row may not change its own font: SetFont
is recorded as able to return without error while silently keeping the
inherited one (fonts.setfont_silent_failure). A row is therefore drawn from
the pool that already has the right font rather than restyled.

## The model, not the quest log

Every line comes from Quest/QuestState.lua's model, never from a fresh read of
the quest log. That model already polls, diffs and round-robins objective
refreshes, and it already knows the two things a naive tracker gets wrong here:
a collapsed header hides its quests from the log entirely, and quest log
indices shift under any accept or turn-in. This file redraws when the model
says something changed, and on a slow timer regardless -- events are
accelerators, never the mechanism.

## Interaction

  * Drag the header to move the window. The position is captured through
    Client.GetFrameAnchor, which undoes this client's inverted GetPoint Y and
    its name-string relative frame, and is stored as a point name plus two
    numbers -- never a path, per the SavedVariables backslash hazard.
  * Drag the bottom-right corner to resize the window in both axes.
  * Left click a quest: selects it in the native Quest Log and opens it.
  * Shift + left click a quest: toggles it in UnrealQuest's unlimited tracked
    set (Quest/Tracker.lua:Toggle) -- the same call the quest log's
    Track/Untrack button uses (Quest/QuestLogButtons.lua), so the two surfaces
    cannot disagree. Untracking also removes the quest from THIS WINDOW, and
    tracking it again brings it back -- see Hiding below.
  * Ctrl + left click a quest: opens the native fullscreen map (best effort;
    see Client.OpenWorldMap) and briefly flashes that quest's own pin(s) on it.
  * Right click a quest: folds that quest's objectives away.
  * Left click a zone row: folds the whole zone away.
  * The header's - button folds the entire body to a title bar.
  * Hovering a quest name shows its detail tooltip: level, zone, status,
    objectives and the gesture list above, through Client.ShowGameTooltip.

## Hiding a quest from this window

Untracking a quest -- through shift-click here, the quest log's Untrack
button, or `/uq untrack` -- also hides it from THIS WINDOW; tracking it again
unhides it. This is Quest/Tracker.lua:Track/Untrack's job, not this file's: it
writes the same trackerHiddenQuests section this file's BuildLines filters by
(a per-title entry, "key present" meaning hidden), so every surface that
tracks or untracks a quest keeps the window in sync for free. An earlier
version of this file made shift-click its own, separate "hide from my
personal index" gesture, unrelated to the watch list, specifically because
the two were found to be different requests wearing the same gesture -- this
reverses that split by explicit request, so the two are one request again.
`/uq tracker unhideall` still clears the whole section, e.g. to bring back
quests untracked before this addon had a Track button to re-track them with.
A zone whose every quest is hidden draws no header either -- see the "any
quest survived the filter" check in BuildLines -- so hiding the last quest in
a zone does not leave an empty label behind.

Fold state is persisted per quest title and per zone name, for the same reason
Tracker persists tracked titles and hidden quests are keyed the same way: this
client has no quest ID, so the title is the only stable handle there is.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local TrackerFrame = UQ:NewModule("TrackerFrame")

local WINDOW_NAME = "UnrealQuestTracker"
local HANDLE_NAME = "UnrealQuestTrackerHandle"
local GRIP_NAME = "UnrealQuestTrackerResizeGrip"

local RESIZE_MIN_WIDTH = 110
local RESIZE_MAX_WIDTH = 600
local RESIZE_MIN_HEIGHT = 60
local RESIZE_MAX_HEIGHT = 900

local COLLAPSED_QUESTS = "trackerCollapsedQuests"
local COLLAPSED_ZONES = "trackerCollapsedZones"
local HIDDEN_QUESTS = "trackerHiddenQuests"

local ZONE_ROW_HEIGHT = 13
local QUEST_ROW_HEIGHT = 13
-- 2px taller than the text itself needs: an objective row's progress bar is
-- bottom-anchored (Compatibility/ClientAPI.lua's track/fill textures), so the
-- extra height is what actually reads as a margin-top on the bar -- the gap
-- between the counter text above it and the bar itself.
local OBJECTIVE_ROW_HEIGHT = 14
-- Quest rows sit almost flush with the zone header above them: the round
-- quest dot is drawn at the row's own left edge, so a wider indent read as
-- dead space down the whole left side of the window.
local QUEST_INDENT = 1
local OBJECTIVE_INDENT = 14
local BODY_PADDING = 5

-- Extra vertical space inserted before every quest row except the first one
-- drawn. Without it the whole log reads as one unbroken block of text; this
-- is what separates one quest (and its objectives) from the next.
local QUEST_GROUP_GAP = 5
-- Same idea for a zone header: space above it (except when it is the very
-- first row visible, where the extra gap would just be dead space under the
-- title bar) so one zone's quests read as visually separate from the next
-- zone's.
local ZONE_GROUP_GAP = 5

local ROW_AREA_CHROME = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING * 2

-- Rough advance width per character for the stock font sizes used here. The
-- client offers no text measurement this addon can trust -- GetStringWidth
-- has no record at all and SetFont is recorded as able to lie about what was
-- applied -- so a long line is shortened arithmetically instead. Erring
-- narrow: a clipped row is a rendering bug, an over-trimmed one is only a
-- shorter sentence. Quest rows now share the objective row's "Small" font
-- template (Compatibility/ClientAPI.lua TRACKER_ROW_FONTS), so they share its
-- advance width too.
-- Quest rows share the objective row's "Small" font template (see
-- Compatibility/ClientAPI.lua TRACKER_ROW_FONTS), so they share its advance
-- width too. A one-character cushion is subtracted in Fit() itself on top of
-- this, which is what actually protects a long name from running past the
-- row's own edge -- tuning this estimate wider instead would trim ordinary,
-- non-overflowing titles for no reason (a real regression the first pass at
-- this made: "[6] Kobold Camp Cleanup" no longer fit at 156px width).
local QUEST_CHAR_WIDTH = 5.6
local OBJECTIVE_CHAR_WIDTH = 5.4
-- A uniform extra cushion on top of the per-kind estimate above, applied in
-- Fit() itself: it is what keeps a long name inside the window even when the
-- per-character tuning above is still slightly off for a particular glyph
-- mix, rather than relying on that tuning to be exact.
local FIT_SAFETY_CHARS = 1

local COLOR_ZONE = { 0.45, 0.45, 0.45 }
local COLOR_OBJECTIVE = { 0.78, 0.78, 0.78 }
local COLOR_OBJECTIVE_DONE = { 0.35, 0.68, 0.35 }
local COLOR_COMPLETE = { 0.35, 0.78, 0.35 }

-- Appended to every quest tooltip (Client.ShowGameTooltip's line-list shape,
-- see Compatibility/ClientAPI.lua RenderTooltipLines), so the gesture list is
-- something the player can actually look up instead of having to remember.
local SHORTCUT_LINES = {
    { text = "Left-Click: open in Quest Log", r = 0.6, g = 0.6, b = 0.6 },
    { text = "Shift-Click: remove from tracker", r = 0.6, g = 0.6, b = 0.6 },
    { text = "Ctrl-Click: show on the map", r = 0.6, g = 0.6, b = 0.6 },
    { text = "Right-Click: fold objectives", r = 0.6, g = 0.6, b = 0.6 },
}

TrackerFrame.window = nil
TrackerFrame.handle = nil
TrackerFrame.grip = nil
TrackerFrame.gripHoverShown = nil
TrackerFrame.lines = {}
TrackerFrame.signature = nil
TrackerFrame.dirty = true
TrackerFrame.drags = 0
TrackerFrame.dragFailures = 0
TrackerFrame.resizes = 0
TrackerFrame.redraws = 0
TrackerFrame.clicks = 0
TrackerFrame.totalLines = 0
TrackerFrame.resizeStartX = nil
TrackerFrame.resizeStartY = nil
TrackerFrame.resizeStartWidth = nil
TrackerFrame.resizeStartHeight = nil

local function Config()
    return UQ:GetModule("Config")
end

local function State()
    return UQ:GetModule("QuestState")
end

local function Watch()
    return UQ:GetModule("Tracker")
end

local function Setting(key)
    local config = Config()
    if not config then
        return nil
    end
    return config:Get(key)
end

local function Store(key, value)
    local config = Config()
    if config then
        config:Set(key, value)
    end
end

local function IsFolded(section, key)
    local config = Config()
    if not config or type(key) ~= "string" then
        return false
    end
    local folded = config:GetSection(section)
    return (folded and folded[key]) ~= nil
end

local function ToggleFolded(section, key)
    local config = Config()
    if not config or type(key) ~= "string" then
        return
    end
    if IsFolded(section, key) then
        config:SetSectionEntry(section, key, nil)
    else
        config:SetSectionEntry(section, key, 1)
    end
end

-- Shortens `text` to something that fits `width` at the given character
-- advance. Byte-wise, like UQ.NameKey and for the same reason: string.sub on a
-- multi-byte character would cut it in half, so the last byte kept is walked
-- back off any UTF-8 continuation sequence before the ellipsis is added.
local function Fit(text, width, charWidth)
    if type(text) ~= "string" then
        return ""
    end
    local budget = math.floor(width / charWidth) - FIT_SAFETY_CHARS
    if budget < 4 then
        budget = 4
    end
    local length = string.len(text)
    if length <= budget then
        return text
    end
    local cut = budget - 3
    while cut > 1 do
        local byte = string.byte(text, cut + 1)
        -- 128..191 is a UTF-8 continuation byte; keeping the cut there would
        -- leave a broken character at the end of the line.
        if not byte or byte < 128 or byte > 191 then
            break
        end
        cut = cut - 1
    end
    return string.sub(text, 1, cut) .. "..."
end

-- Quest titles can use the documented pixel measurement on their own label.
-- The estimate remains the fallback for a client that does not provide it.
-- Searching the largest byte prefix keeps the whole available label width in
-- use while retaining Fit()'s protection against splitting a UTF-8 character.
local function FitQuest(text, width, charWidth, row)
    if type(text) ~= "string" then
        return ""
    end
    local measured = Client.MeasureTrackerRowTextWidth(row, text)
    if type(measured) ~= "number" then
        return Fit(text, width, charWidth)
    end
    if measured <= width then
        return text
    end

    local low = 1
    local high = string.len(text) - 3
    local best = "..."
    while low <= high do
        local probe = math.floor((low + high) / 2)
        local cut = probe
        while cut > 1 do
            local byte = string.byte(text, cut + 1)
            if not byte or byte < 128 or byte > 191 then
                break
            end
            cut = cut - 1
        end
        local candidate = string.sub(text, 1, cut) .. "..."
        local candidateWidth = Client.MeasureTrackerRowTextWidth(row, candidate)
        if type(candidateWidth) ~= "number" then
            return Fit(text, width, charWidth)
        end
        if candidateWidth <= width then
            best = candidate
            low = probe + 1
        else
            high = probe - 1
        end
    end
    return best
end

-- An objective line's trailing "have/need" counter (the same pattern
-- QuestState.ParseProgress reads) is the single most important part of it --
-- the progress bar below the row is derived from it too. The measured route
-- searches the largest description prefix whose ellipsis AND counter still
-- fit together; this avoids the large blank gap produced by reserving both
-- pieces with an average character width. The arithmetic path remains the
-- fallback when the documented pixel measurement is unavailable.
local function FitObjective(text, width, charWidth, row)
    if type(text) ~= "string" then
        return ""
    end
    local measured = Client.MeasureTrackerRowTextWidth(row, text)
    if type(measured) == "number" then
        if measured <= width then
            return text
        end
        local measuredStart = string.find(text, "%d+%s*/%s*%d+%s*$")
        if not measuredStart then
            return FitQuest(text, width, charWidth, row)
        end
        local measuredSuffix = string.sub(text, measuredStart)
        local measuredLead = UQ.Trim(string.sub(text, 1, measuredStart - 1)) or ""
        local low = 1
        local high = string.len(measuredLead) - 3
        local best = nil
        while low <= high do
            local probe = math.floor((low + high) / 2)
            local cut = probe
            while cut > 1 do
                local byte = string.byte(measuredLead, cut + 1)
                if not byte or byte < 128 or byte > 191 then
                    break
                end
                cut = cut - 1
            end
            local candidate = string.sub(measuredLead, 1, cut) .. "... " .. measuredSuffix
            local candidateWidth = Client.MeasureTrackerRowTextWidth(row, candidate)
            if type(candidateWidth) ~= "number" then
                break
            end
            if candidateWidth <= width then
                best = candidate
                low = probe + 1
            else
                high = probe - 1
            end
        end
        if best then
            return best
        end
        return FitQuest(text, width, charWidth, row)
    end

    local budget = math.floor(width / charWidth) - FIT_SAFETY_CHARS
    if budget < 4 then
        budget = 4
    end
    if string.len(text) <= budget then
        return text
    end
    local start = string.find(text, "%d+%s*/%s*%d+%s*$")
    if not start then
        return Fit(text, width, charWidth)
    end
    local suffix = string.sub(text, start)
    local lead = UQ.Trim(string.sub(text, 1, start - 1)) or ""
    local leadBudget = budget - string.len(suffix) - 1
    if leadBudget < 4 then
        -- Not enough room to keep any description at all once the counter is
        -- reserved; fall back to the plain trim so at least something legible
        -- remains rather than showing the counter alone with nothing before it.
        return Fit(text, width, charWidth)
    end
    return Fit(lead, leadBudget * charWidth, charWidth) .. " " .. suffix
end

-- Line building ---------------------------------------------------------------

local function AddLine(lines, kind, text, red, green, blue, quest, key, progress, progressDone)
    table.insert(lines, {
        kind = kind,
        text = text,
        red = red,
        green = green,
        blue = blue,
        quest = quest,
        key = key,
        progress = progress,
        progressDone = progressDone,
    })
end

local function QuestLabel(quest)
    local label = ""
    if type(quest.level) == "number" and quest.level > 0 then
        label = "[" .. quest.level .. "] "
    end
    return label .. (quest.title or "?")
end

-- Turns the model into the flat list of rows the window draws. Everything that
-- decides what is visible -- folds, the objective setting, zone grouping --
-- happens here, so the drawing pass below is pure placement.
function TrackerFrame:BuildLines()
    local lines = {}
    local state = State()
    if not state then
        return lines, 0, 0
    end

    local watch = Watch()
    local showObjectives = Setting("trackerShowObjectives") or "all"
    local groupByZone = Setting("trackerGroupByZone") and true or false
    local quests = state:GetOrderedQuests()
    local total = table.getn(quests)
    local visibleTotal = 0
    local completed = 0
    local lastZone = nil
    -- A zone header is written lazily, on the first quest of that zone that
    -- actually survives the hidden-quest filter below -- not the moment the
    -- zone changes. Writing it eagerly (the original shape of this loop)
    -- would leave an empty "ELWYNN FOREST" label on screen for a zone whose
    -- only quest the player just shift-clicked away.
    local pendingZone = nil

    local index = 1
    while index <= total do
        local quest = quests[index]
        local zone = quest.zone
        local hidden = IsFolded(HIDDEN_QUESTS, quest.title or "")

        if groupByZone and zone and zone ~= lastZone then
            lastZone = zone
            pendingZone = zone
        end

        if not hidden then
        visibleTotal = visibleTotal + 1
        if pendingZone then
            AddLine(lines, "zone", pendingZone, COLOR_ZONE[1], COLOR_ZONE[2], COLOR_ZONE[3],
                nil, pendingZone)
            pendingZone = nil
        end

        local zoneFolded = false
        if groupByZone and zone then
            zoneFolded = IsFolded(COLLAPSED_ZONES, zone)
        end

        if quest.isComplete == 1 then
            completed = completed + 1
        end

        if not zoneFolded then
            local red, green, blue
            if quest.isComplete == 1 then
                red, green, blue = COLOR_COMPLETE[1], COLOR_COMPLETE[2], COLOR_COMPLETE[3]
            else
                red, green, blue = Client.GetQuestLevelColor(quest.level)
            end
            local tracked = false
            if watch then
                tracked = watch:IsTracked(quest) and true or false
            end
            local line = {
                kind = "quest",
                text = QuestLabel(quest),
                red = red,
                green = green,
                blue = blue,
                quest = quest,
                key = quest.title,
                tracked = tracked,
            }
            line.questRed, line.questGreen, line.questBlue = UQ.GetQuestColor(quest)
            table.insert(lines, line)

            local questFolded = IsFolded(COLLAPSED_QUESTS, quest.title or "")
            if showObjectives ~= "none" and not questFolded
                and (showObjectives == "all" or tracked or quest.isComplete == 1) then
                if quest.isComplete == 1 then
                    AddLine(lines, "objective", "Ready to turn in",
                        COLOR_COMPLETE[1], COLOR_COMPLETE[2], COLOR_COMPLETE[3], quest)
                end
                local objectives = quest.objectives or {}
                local objectiveIndex = 1
                local objectiveCount = table.getn(objectives)
                while objectiveIndex <= objectiveCount do
                    local objective = objectives[objectiveIndex]
                    if objective and type(objective.text) == "string" and objective.text ~= "" then
                        local progress = nil
                        if type(objective.have) == "number" and type(objective.need) == "number"
                            and objective.need > 0 then
                            progress = objective.have / objective.need
                        end
                        if objective.finished then
                            AddLine(lines, "objective", objective.text,
                                COLOR_OBJECTIVE_DONE[1], COLOR_OBJECTIVE_DONE[2],
                                COLOR_OBJECTIVE_DONE[3], quest, nil, progress, true)
                        else
                            AddLine(lines, "objective", objective.text,
                                COLOR_OBJECTIVE[1], COLOR_OBJECTIVE[2], COLOR_OBJECTIVE[3],
                                quest, nil, progress, false)
                        end
                    end
                    objectiveIndex = objectiveIndex + 1
                end
            end
        end
        end

        index = index + 1
    end

    return lines, visibleTotal, completed
end

-- Drawing ----------------------------------------------------------------------

local function RowHeight(kind)
    if kind == "zone" then
        return ZONE_ROW_HEIGHT
    elseif kind == "quest" then
        return QUEST_ROW_HEIGHT
    end
    return OBJECTIVE_ROW_HEIGHT
end

-- Returns the exact content height needed to draw through one line, using the
-- same row and inter-group spacing as Redraw. RevealQuest uses this to grow a
-- manually shortened window just far enough to show a quest's complete block.
local function HeightThroughLine(lines, stopIndex)
    local top = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING
    local previousKind = nil
    local index = 1
    while index <= stopIndex do
        local kind = lines[index].kind
        if kind == "quest" and (previousKind == "quest" or previousKind == "objective") then
            top = top + QUEST_GROUP_GAP
        elseif kind == "zone" and previousKind ~= nil then
            top = top + ZONE_GROUP_GAP
        end
        top = top + RowHeight(kind)
        previousKind = kind
        index = index + 1
    end
    return top + BODY_PADDING
end

local function RowIndent(kind)
    if kind == "zone" then
        return 0
    elseif kind == "quest" then
        return QUEST_INDENT
    end
    return OBJECTIVE_INDENT
end

-- Builds the hover tooltip for one quest row: title, level, zone, watch
-- status, hand-in status, live objectives, then the shortcut list. Mirrors
-- Map/WorldMapPins.lua's own BuildQuestTooltipLines (same shape, same
-- colours for the shared ideas -- level colour, done-green) but reads
-- entirely off the quest-log model already on `quest`, since the tracker
-- never needs a database lookup for any of this the way the map's giver/
-- turn-in tooltips sometimes do.
local function BuildQuestTooltipLines(quest)
    local lines = {}
    table.insert(lines, { text = quest.title or "?", r = 1, g = 0.82, b = 0 })

    if type(quest.level) == "number" and quest.level > 0 then
        local red, green, blue = Client.GetQuestLevelColor(quest.level)
        table.insert(lines, {
            left = "Level:", right = tostring(quest.level),
            rightR = red, rightG = green, rightB = blue,
        })
    end
    if type(quest.zone) == "string" and quest.zone ~= "" then
        table.insert(lines, { left = "Zone:", right = quest.zone })
    end
    if type(quest.questTag) == "string" and quest.questTag ~= "" then
        table.insert(lines, { left = "Type:", right = quest.questTag })
    end

    local watch = Watch()
    if watch and watch:IsTracked(quest) then
        table.insert(lines, {
            left = "Tracked:", right = "yes",
            rightR = UQ.colors.accent[1], rightG = UQ.colors.accent[2], rightB = UQ.colors.accent[3],
        })
    end

    if quest.isComplete == 1 then
        table.insert(lines, {
            left = "Status:", right = "Ready to turn in",
            rightR = COLOR_COMPLETE[1], rightG = COLOR_COMPLETE[2], rightB = COLOR_COMPLETE[3],
        })
    else
        table.insert(lines, { left = "Status:", right = "In progress", rightR = 1, rightG = 0.82, rightB = 0 })
    end

    local objectives = quest.objectives or {}
    local index = 1
    local total = table.getn(objectives)
    while index <= total do
        local objective = objectives[index]
        if objective and type(objective.text) == "string" and objective.text ~= "" then
            if objective.finished then
                table.insert(lines, { text = "- " .. objective.text,
                    r = COLOR_OBJECTIVE_DONE[1], g = COLOR_OBJECTIVE_DONE[2], b = COLOR_OBJECTIVE_DONE[3] })
            else
                table.insert(lines, { text = "- " .. objective.text, r = 1, g = 1, b = 1 })
            end
        end
        index = index + 1
    end

    table.insert(lines, { separator = true })
    local shortcutIndex = 1
    local shortcutTotal = table.getn(SHORTCUT_LINES)
    while shortcutIndex <= shortcutTotal do
        table.insert(lines, SHORTCUT_LINES[shortcutIndex])
        shortcutIndex = shortcutIndex + 1
    end

    return lines
end

-- Ctrl+click: best-effort "take me there", via QuestClicks:RevealOnMap --
-- shared with the quest log's own Show button (Quest/QuestLogButtons.lua) so
-- the two surfaces cannot drift apart.
local function RevealQuestOnMap(quest)
    local clicks = UQ:GetModule("QuestClicks")
    if clicks then
        clicks:RevealOnMap(quest)
    end
end

-- Row click handlers are installed ONCE per pooled row, never per redraw.
-- Two reasons, both recorded: SetScript(type, nil) does not detach a script on
-- this client, so a handler set repeatedly is only ever added to; and a burst
-- of freshly allocated closures has been reported as visible stuttering here.
-- A row therefore keeps one handler for life and its subject is swapped
-- underneath it -- which is safe because the pools are keyed by row kind, so a
-- quest row is never reused as a zone row. Hover (OnEnter/OnLeave) is bound
-- the same once-only way, right alongside the click handler.
local function OnQuestRowClick(row, first)
    local quest = row and row.unrealQuestSubject
    if not quest then
        return
    end
    TrackerFrame.clicks = TrackerFrame.clicks + 1
    local button = Client.ResolveClickButton(first)
    if button == "RightButton" then
        ToggleFolded(COLLAPSED_QUESTS, quest.title or "")
        TrackerFrame.dirty = true
        TrackerFrame:Refresh()
        return
    end
    if Client.IsShiftKeyDown() then
        -- Toggles UnrealQuest's unlimited tracked set -- the same
        -- Tracker:Toggle call the quest log's Track/Untrack button uses
        -- (Quest/QuestLogButtons.lua), so the two surfaces can never disagree
        -- about a quest's tracked state. This reverses an earlier design
        -- (see docs/QUEST-TRACKER.md)
        -- that moved shift-click to a per-window hide instead, precisely to
        -- avoid this gesture meaning two different things -- superseded by
        -- explicit user request to unify it with the log button.
        local tracker = Watch()
        if tracker then
            tracker:Toggle(quest)
        end
        local logButtons = UQ:GetModule("QuestLogButtons")
        if logButtons then
            logButtons:Refresh()
        end
        TrackerFrame.dirty = true
        TrackerFrame:Refresh()
        return
    end
    if Client.IsControlKeyDown() then
        RevealQuestOnMap(quest)
        return
    end
    -- A plain click opens the quest. SelectQuestLogEntry is documented to clear
    -- the selection rather than error when handed a bad index, and the model's
    -- index can be one poll interval stale, so a miss is harmless.
    Client.SelectQuestLogEntry(quest.index)
    Client.OpenQuestLog()
end

local function OnQuestRowEnter(row)
    local quest = row and row.unrealQuestSubject
    if not quest then
        return
    end
    Client.ShowGameTooltip(row, BuildQuestTooltipLines(quest), "ANCHOR_RIGHT")
end

local function OnQuestRowLeave(row)
    Client.HideGameTooltip(row)
end

local function OnZoneRowClick(row)
    local zone = row and row.unrealQuestSubject
    if type(zone) ~= "string" then
        return
    end
    TrackerFrame.clicks = TrackerFrame.clicks + 1
    ToggleFolded(COLLAPSED_ZONES, zone)
    TrackerFrame.dirty = true
    TrackerFrame:Refresh()
end

function TrackerFrame:Redraw(lines, questCount, completed)
    local window = self.window
    if not window then
        return
    end

    local width = Setting("trackerWidth")
    if type(width) ~= "number" or width < 110 then
        width = 170
    end

    local targetHeight = Setting("trackerHeight")
    if type(targetHeight) ~= "number" or targetHeight <= ROW_AREA_CHROME then
        targetHeight = nil
    end
    local resizing = self.resizeStartX and true or false

    local total = table.getn(lines)
    self.totalLines = total

    local collapsed = Setting("trackerCollapsed") and true or false
    if collapsed then
        targetHeight = nil
    end

    Client.SetTrackerTitle(window, "UnrealQuest")
    Client.SetTrackerCount(window, completed .. "/" .. questCount)
    Client.SetTrackerCollapseLabel(window, collapsed and "+" or "-")

    local top = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING
    local used = { zone = 1, quest = 1, objective = 1 }
    -- Tracks what was drawn immediately before, so a gap can be inserted
    -- between one quest's block and the next without also pushing a quest
    -- away from the zone header that just introduced it.
    local previousKind = nil

    local index = 1
    while not collapsed and index <= total do
        local line = lines[index]
        local kind = line.kind
        if kind == "quest" and (previousKind == "quest" or previousKind == "objective") then
            top = top + QUEST_GROUP_GAP
        elseif kind == "zone" and previousKind ~= nil then
            top = top + ZONE_GROUP_GAP
        end
        -- The window still resizes exactly as before, but there is no scrolling:
        -- begin at the first line and stop once the next complete row would pass
        -- the resized bottom edge.
        if targetHeight and top + RowHeight(kind) > targetHeight - BODY_PADDING then
            break
        end
        local slot = used[kind] or 1
        local row = Client.GetTrackerRow(window, kind, slot)
        if row then
            used[kind] = slot + 1
            local indent = RowIndent(kind)
            local height = RowHeight(kind)
            Client.PlaceTrackerRow(row, window, indent, top, width, height)

            local rowWidth = row.unrealQuestTextWidth or row.unrealQuestWidth or (width - indent)
            local fitted
            if kind == "quest" then
                fitted = FitQuest(line.text, rowWidth, QUEST_CHAR_WIDTH, row)
            elseif kind == "objective" then
                fitted = FitObjective(line.text, rowWidth, OBJECTIVE_CHAR_WIDTH, row)
            else
                fitted = Fit(line.text, rowWidth, OBJECTIVE_CHAR_WIDTH)
            end
            Client.SetTrackerRowText(row, fitted, line.red, line.green, line.blue)

            if kind == "quest" then
                row.unrealQuestSubject = line.quest
                Client.SetTrackerRowQuestMark(row,
                    line.questRed, line.questGreen, line.questBlue)
                Client.SetTrackerRowProgress(row, nil)
                if not row.unrealQuestBound then
                    row.unrealQuestBound = true
                    Client.SetTrackerRowClick(row, function(first) OnQuestRowClick(row, first) end)
                    -- Plain field assignments, not a client call -- see the
                    -- comment on Client.GetTrackerRow's OnEnter/OnLeave in
                    -- Compatibility/ClientAPI.lua for why hover is wired this
                    -- way instead of a second SetScript.
                    row.unrealQuestOnEnter = function() OnQuestRowEnter(row) end
                    row.unrealQuestOnLeave = function() OnQuestRowLeave(row) end
                end
            elseif kind == "zone" then
                row.unrealQuestSubject = line.key
                Client.SetTrackerRowProgress(row, nil)
                if not row.unrealQuestBound then
                    row.unrealQuestBound = true
                    Client.SetTrackerRowClick(row, function() OnZoneRowClick(row) end)
                end
            else
                row.unrealQuestSubject = nil
                if line.progressDone then
                    Client.SetTrackerRowProgress(row, line.progress,
                        COLOR_OBJECTIVE_DONE[1], COLOR_OBJECTIVE_DONE[2], COLOR_OBJECTIVE_DONE[3])
                else
                    Client.SetTrackerRowProgress(row, line.progress,
                        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3])
                end
            end

            top = top + height
            previousKind = kind
        else
            -- The pool refused to grow. Stop rather than spin: every later row
            -- would fail the same way and the window is already consistent.
            break
        end
        index = index + 1
    end

    Client.HideTrackerRows(window, "zone", used.zone)
    Client.HideTrackerRows(window, "quest", used.quest)
    Client.HideTrackerRows(window, "objective", used.objective)

    local height = Client.TRACKER_HEADER_HEIGHT
    if collapsed then
        -- title bar only
    elseif targetHeight and resizing then
        -- Keep the bottom edge under the grip while it is held, including blank
        -- space when the requested height exceeds the content.
        height = targetHeight
    else
        height = top + BODY_PADDING
        if targetHeight and height > targetHeight then
            height = targetHeight
        end
    end
    Client.SetObjectSize(window, width, height)
    self.redraws = self.redraws + 1
end

-- Rebuilds the line list and redraws only when the rendered content changes.
function TrackerFrame:Refresh()
    local window = self.window
    if not window then
        return
    end
    if not Setting("trackerEnabled") then
        Client.HideObject(window)
        return
    end

    local lines, questCount, completed = self:BuildLines()
    local parts = { tostring(questCount), tostring(completed),
        Setting("trackerCollapsed") and "1" or "0", tostring(Setting("trackerWidth")),
        tostring(Setting("trackerHeight")) }
    local index = 1
    local total = table.getn(lines)
    while index <= total do
        local line = lines[index]
        table.insert(parts, line.kind .. ":" .. tostring(line.text)
            .. ":" .. tostring(line.tracked) .. ":" .. tostring(line.progress))
        index = index + 1
    end
    local signature = table.concat(parts, "|")

    if not self.dirty and signature == self.signature then
        return
    end
    self.dirty = false
    self.signature = signature
    self.lines = lines
    self:Redraw(lines, questCount, completed)
    Client.ShowObject(window)
end

-- Refreshes after Tracker clears the quest and zone folds for a newly tracked
-- quest. A saved height is a ceiling, so grow it through the quest's final
-- objective before redrawing; both a Track action and a newly accepted quest
-- reach this method through Tracker:Track.
function TrackerFrame:RevealQuest(quest)
    if not quest or not quest.title then
        return false
    end
    local lines = self:BuildLines()
    local revealIndex = nil
    local index = 1
    local total = table.getn(lines)
    while index <= total do
        local line = lines[index]
        if line.quest and line.quest.title == quest.title then
            -- Objective lines carry the same quest, so retaining the last
            -- match reveals the whole block rather than only its title row.
            revealIndex = index
        end
        index = index + 1
    end
    if not revealIndex then
        return false
    end

    local targetHeight = Setting("trackerHeight")
    if type(targetHeight) == "number" and targetHeight > ROW_AREA_CHROME then
        local requiredHeight = HeightThroughLine(lines, revealIndex)
        if requiredHeight > targetHeight then
            local config = Config()
            if config then
                if requiredHeight > RESIZE_MAX_HEIGHT then
                    config:Set("trackerHeight", 0)
                else
                    config:Set("trackerHeight", requiredHeight)
                end
            end
        end
    end

    self.dirty = true
    self:Refresh()
    return true
end

-- Position ----------------------------------------------------------------------

function TrackerFrame:ApplyStoredPosition()
    local window = self.window
    if not window then
        return false
    end
    local point = Setting("trackerPoint")
    local relativePoint = Setting("trackerRelativePoint")
    local x = Setting("trackerX")
    local y = Setting("trackerY")
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    -- Always UIParent-relative. The stored anchor is a point name and two
    -- numbers and nothing else: a relative frame is a live object that cannot
    -- be persisted, and anchoring to some other addon's frame would break the
    -- moment that addon is not loaded.
    return Client.SetFrameAnchor(window, point, "UIParent",
        type(relativePoint) == "string" and relativePoint or point, x, y)
end

function TrackerFrame:CapturePosition()
    local window = self.window
    if not window then
        return false
    end
    local point, relativeName, relativePoint, x, y = Client.GetFrameAnchor(window)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        UQ:Warn("the tracker window could not report its position; it will reopen where it was")
        return false
    end
    -- relativeName is read but not stored. Anything the drag left the window
    -- anchored to is normalized to UIParent on the way back in, which is what
    -- makes the stored pair of numbers meaningful across sessions.
    Store("trackerPoint", point)
    Store("trackerRelativePoint", type(relativePoint) == "string" and relativePoint or point)
    Store("trackerX", x)
    Store("trackerY", y)
    return true
end

function TrackerFrame:ResetPosition()
    Store("trackerPoint", "TOPRIGHT")
    Store("trackerRelativePoint", "TOPRIGHT")
    Store("trackerX", -20)
    Store("trackerY", -240)
    Store("trackerHeight", 0)
    self.dirty = true
    self:ApplyStoredPosition()
end

function TrackerFrame:StartResize()
    local window = self.window
    local grip = self.grip
    if not window or not grip then
        return false
    end
    local width = Client.GetObjectWidth(window)
    local height = Client.GetObjectHeight(window)
    if not width or not height then
        return false
    end

    if not Client.StartFrameDrag(grip) then
        Client.AnchorObjectToCorner(grip, window)
        return false
    end
    local gripX, gripY = Client.GetObjectCorner(grip)
    if not gripX then
        Client.StopFrameDrag(grip)
        Client.AnchorObjectToCorner(grip, window)
        return false
    end

    self.resizeStartX = gripX
    self.resizeStartY = gripY
    self.resizeStartWidth = width
    self.resizeStartHeight = height

    local config = Config()
    if config then
        config:Set("trackerHeight", height)
    end

    grip.unrealQuestResizing = true
    Client.ShowObject(grip.unrealQuestMark)
    return true
end

function TrackerFrame:StopResize()
    local grip = self.grip
    if grip then
        grip.unrealQuestResizing = false
        Client.StopFrameDrag(grip)
        Client.AnchorObjectToCorner(grip, self.window)
        if grip.unrealQuestMark and not Client.IsCursorInsideObject(self.window) then
            Client.HideObject(grip.unrealQuestMark)
        end
        self.gripHoverShown = nil
    end
    if not self.resizeStartX then
        return
    end
    self.resizeStartX = nil
    self.resizeStartY = nil
    self.resizeStartWidth = nil
    self.resizeStartHeight = nil
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Unschedule("tracker.resize")
    end
end

function TrackerFrame:UpdateGripHover()
    local grip = self.grip
    if not grip or not grip.unrealQuestMark or grip.unrealQuestResizing then
        return
    end
    local window = self.window
    local over = window and Client.IsObjectShown(window)
        and Client.IsCursorInsideObject(window) or false
    if over == self.gripHoverShown then
        return
    end
    self.gripHoverShown = over
    if over then
        Client.ShowObject(grip.unrealQuestMark)
    else
        Client.HideObject(grip.unrealQuestMark)
    end
end

function TrackerFrame:ApplyResize()
    if not self.resizeStartX or not self.window or not self.grip then
        return
    end
    local config = Config()
    if not config then
        return
    end
    local gripX, gripY = Client.GetObjectCorner(self.grip)
    if not gripX then
        return
    end

    local width = self.resizeStartWidth + (gripX - self.resizeStartX)
    if width < RESIZE_MIN_WIDTH then
        width = RESIZE_MIN_WIDTH
    elseif width > RESIZE_MAX_WIDTH then
        width = RESIZE_MAX_WIDTH
    end

    local height = self.resizeStartHeight - (gripY - self.resizeStartY)
    if height < RESIZE_MIN_HEIGHT then
        height = RESIZE_MIN_HEIGHT
    elseif height > RESIZE_MAX_HEIGHT then
        height = RESIZE_MAX_HEIGHT
    end

    config:Set("trackerWidth", width)
    config:Set("trackerHeight", height)
    self.dirty = true
    self:Refresh()
end

-- Public control ----------------------------------------------------------------

function TrackerFrame:SetShown(shown)
    Store("trackerEnabled", shown and true or false)
    if not self.window then
        return false
    end
    if shown then
        self.dirty = true
        self:Refresh()
    else
        Client.HideObject(self.window)
    end
    self:ApplyNativeWatchVisibility()
    return true
end

function TrackerFrame:IsShown()
    return Setting("trackerEnabled") and true or false
end

function TrackerFrame:ToggleCollapsed()
    Store("trackerCollapsed", not (Setting("trackerCollapsed") and true or false))
    self.dirty = true
    self:Refresh()
end

-- The native five-quest panel is hidden only while this window is actually
-- up and the setting asks for it; every other combination shows it again, so
-- turning the tracker off never leaves the player with no tracker at all.
function TrackerFrame:ApplyNativeWatchVisibility()
    local hide = Setting("trackerHideNativeWatch") and true or false
    local enabled = Setting("trackerEnabled") and true or false
    if hide and enabled then
        Client.SetNativeQuestWatchShown(false)
    else
        Client.SetNativeQuestWatchShown(true)
    end
end

function TrackerFrame:GetReport()
    return {
        created = self.window and true or false,
        enabled = Setting("trackerEnabled") and true or false,
        collapsed = Setting("trackerCollapsed") and true or false,
        width = Setting("trackerWidth"),
        height = Setting("trackerHeight"),
        objectives = Setting("trackerShowObjectives"),
        groupByZone = Setting("trackerGroupByZone") and true or false,
        hideNativeWatch = Setting("trackerHideNativeWatch") and true or false,
        lines = self.totalLines,
        redraws = self.redraws,
        clicks = self.clicks,
        drags = self.drags,
        dragFailures = self.dragFailures,
        resizes = self.resizes,
        point = Setting("trackerPoint"),
        x = Setting("trackerX"),
        y = Setting("trackerY"),
    }
end

-- Lifecycle -----------------------------------------------------------------------

function TrackerFrame:OnInit()
    local window = Client.CreateTrackerWindow(WINDOW_NAME)
    if not window then
        UQ:Warn("the quest tracker window could not be created; the tracker is unavailable")
        return
    end
    self.window = window
    self:ApplyBackgroundOpacity()

    local handle = Client.CreateTrackerHandle(window, HANDLE_NAME)
    if handle then
        self.handle = handle
        Client.SetObjectScript(handle, "OnDragStart", function()
            if Client.StartFrameDrag(window) then
                TrackerFrame.drags = TrackerFrame.drags + 1
            else
                TrackerFrame.dragFailures = TrackerFrame.dragFailures + 1
                -- Visible, not debug-only. A drag that silently does nothing is
                -- the exact failure mode this client already produced once.
                UQ:Warn("the tracker window refused to move (StartMoving failed)")
            end
        end)
        Client.SetObjectScript(handle, "OnDragStop", function()
            Client.StopFrameDrag(window)
            TrackerFrame:CapturePosition()
        end)
    else
        UQ:Warn("the tracker window has no drag handle; it cannot be moved")
    end

    local grip = Client.CreateTrackerResizeGrip(window, GRIP_NAME)
    if grip then
        self.grip = grip
        Client.SetObjectScript(grip, "OnDragStart", function()
            if not TrackerFrame:StartResize() then
                UQ:Warn("the tracker's corner grip could not start a resize; its size can "
                    .. "still be set with /uq tracker width and /uq tracker height")
                return
            end
            TrackerFrame.resizes = TrackerFrame.resizes + 1
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Schedule("tracker.resize", 0.02, function() TrackerFrame:ApplyResize() end)
            end
        end)
        Client.SetObjectScript(grip, "OnDragStop", function()
            TrackerFrame:StopResize()
        end)
    else
        UQ:Warn("the tracker window has no resize grip; its size can still be set with "
            .. "/uq tracker width and /uq tracker height")
    end

    Client.SetTrackerHeaderButtons(window,
        function()
            local npcPins = UQ:GetModule("NpcPins")
            if npcPins then
                npcPins:ToggleMenu(window.unrealQuestNpcFinder)
            end
        end,
        function() TrackerFrame:ToggleCollapsed() end)

    if not self:ApplyStoredPosition() then
        self:ResetPosition()
    end
end

-- Changes only the background texture, so the tracker text, progress bars and
-- controls stay fully opaque. Called directly by the settings slider while it
-- moves; no redraw is needed because the texture already exists.
function TrackerFrame:ApplyBackgroundOpacity(percent)
    if type(percent) ~= "number" then
        percent = Setting("trackerBackgroundOpacity")
    end
    return Client.SetTrackerBackgroundOpacity(self.window, percent or 55)
end

function TrackerFrame:OnEnable()
    if not self.window then
        return
    end

    local driver = UQ:GetModule("Driver")
    if driver then
        -- 0.4s is the correctness guarantee, not the mechanism: the model's own
        -- listener wakes this job the moment it notices anything, and the timer
        -- is what makes the window right on a client where no quest event ever
        -- fires.
        driver:Schedule("tracker.frame", 0.4, function() TrackerFrame:Refresh() end)
        -- Scheduled unconditionally, and gated INSIDE the job rather than
        -- around it. Gating the schedule meant a player who turned hiding on
        -- later with /uq tracker native got the one-shot hide and no job to
        -- keep it hidden, so the client's own re-show (which is why this job
        -- exists at all) put the panel straight back. The job costs one
        -- settings read every two seconds when hiding is off, and never
        -- touches the frame in that case -- the client owns it then, and
        -- re-Showing it on a timer would force an empty native panel on a
        -- player who has nothing tracked.
        driver:Schedule("tracker.griphover", 0.1, function()
            TrackerFrame:UpdateGripHover()
        end)
        driver:Schedule("tracker.nativewatch", 2.0, function()
            if Setting("trackerHideNativeWatch") then
                TrackerFrame:ApplyNativeWatchVisibility()
            end
        end)
    end

    local state = State()
    if state then
        state:AddListener(function(event)
            if event == "QUEST_ADDED" or event == "QUEST_REMOVED"
                or event == "QUEST_COMPLETED" or event == "QUEST_OBJECTIVES_CHANGED"
                or event == "QUEST_LOG_CHANGED" then
                TrackerFrame.dirty = true
                local d = UQ:GetModule("Driver")
                if d then
                    d:Wake("tracker.frame")
                end
            end
        end)
    end

    self:ApplyNativeWatchVisibility()
    self:Refresh()
end

TrackerFrame.Fit = Fit
TrackerFrame.FitQuest = FitQuest
TrackerFrame.FitObjective = FitObjective
