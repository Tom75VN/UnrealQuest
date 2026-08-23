--[[
UnrealQuest / Quest/TrackerFrame.lua

The quest tracker window: a movable panel that lists EVERY quest in the
player's log, grouped by its quest log zone header, with each quest's
objectives and their progress underneath it.

Why this exists next to Quest/Tracker.lua, which is also called "tracker":
they answer different questions. `Tracker` owns the CLIENT's watch list -- the
five-quest native selection, and the persistence the client does not give it.
This file owns a DISPLAY, and it is deliberately not bound by that list: the
client caps watching at five quests, and "show me everything I am carrying" is
not a watch request. A quest that happens to be in the native watch list is
marked here with an accent stripe, nothing more.

## What it draws

    UnrealQuest                      6/12  ^ v -
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
  * Left click a quest: selects it in the native Quest Log and opens it.
  * Shift + left click a quest: toggles it on the client's native watch list
    (Quest/Tracker.lua:Toggle) -- the same call the quest log's Track/Untrack
    button uses (Quest/QuestLogButtons.lua), so the two surfaces cannot
    disagree. Untracking also removes the quest from THIS WINDOW, and
    tracking it again brings it back -- see Hiding below.
  * Ctrl + left click a quest: opens the native fullscreen map (best effort;
    see Client.OpenWorldMap) and briefly flashes that quest's own pin(s) on it.
  * Right click a quest: folds that quest's objectives away.
  * Left click a zone row: folds the whole zone away.
  * The header's - button folds the entire body to a title bar.
  * The ^ and v buttons page a log too long for the window. There is no
    mouse-wheel scrolling: it was implemented, measured and removed, and this
    client cannot support it -- see the Mouse wheel section below.
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
Tracker persists watched titles and hidden quests are keyed the same way: this
client has no quest ID, so the title is the only stable handle there is.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local TrackerFrame = UQ:NewModule("TrackerFrame")

local WINDOW_NAME = "UnrealQuestTracker"
local HANDLE_NAME = "UnrealQuestTrackerHandle"
local GRIP_NAME = "UnrealQuestTrackerResizeGrip"

-- Width bounds are the same ones /uq tracker width already validates against
-- (Core/Commands.lua) -- the grip is a second way to reach that setting, not a
-- separate range for it. Height has no slash command and so no range to
-- inherit: the floor is the title bar plus about three rows, and the ceiling
-- is generous enough for the longest realistic log without letting a wild drag
-- leave a window taller than any screen.
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
local QUEST_INDENT = 4
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

-- Everything in the window's height that is NOT row area: the title bar, plus
-- the body padding above the first row and below the last. A dragged height
-- below this has no room for a single row, which is what makes it the floor
-- for treating trackerHeight as set at all. Mirrors Redraw's own height
-- arithmetic -- change one and the other has to follow.
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
-- Last hover answer the griphover job acted on, so the common case (cursor
-- still where it was) costs one rectangle test and nothing else. Cleared,
-- never set, by the drag path -- a drag moves the mark behind this job's back,
-- and nil means "recompute on the next tick".
TrackerFrame.gripHoverShown = nil
TrackerFrame.lines = {}
TrackerFrame.offset = 0
TrackerFrame.signature = nil
TrackerFrame.dirty = true
TrackerFrame.drags = 0
TrackerFrame.dragFailures = 0
TrackerFrame.resizes = 0
TrackerFrame.redraws = 0
TrackerFrame.clicks = 0
TrackerFrame.totalLines = 0
-- How many lines the last Redraw actually placed. totalLines > linesDrawn is
-- the definition of "there is something to scroll to".
TrackerFrame.linesDrawn = 0
-- Captured when the resize grip's drag starts; resizeStartX is nil whenever a
-- drag is not in progress, which is also what tracker.resize's own job guards
-- on so it costs nothing between drags. X/Y are the GRIP's own screen corner,
-- not the cursor's -- the grip is genuinely moved by the client during a drag,
-- so its position is the authoritative record of how far the corner travelled.
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

-- An objective line's trailing "have/need" counter (the same pattern
-- QuestState.ParseProgress reads) is the single most important part of it --
-- the progress bar below the row is derived from it too. A plain end-anchored
-- Fit() would trim that counter off first on a narrow row, which defeats the
-- point of the line. When the pattern is present, it is kept intact and the
-- description ahead of it is what gets shortened instead; a line with no
-- counter (e.g. "Ready to turn in") falls straight through to plain Fit().
local function FitObjective(text, width, charWidth)
    if type(text) ~= "string" then
        return ""
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
            left = "Watched:", right = "yes",
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
        -- Toggles the client's native watch list -- the same Tracker:Toggle
        -- call the quest log's Track/Untrack button uses (Quest/QuestLogButtons.lua),
        -- so the two surfaces can never disagree about a quest's tracked
        -- state. This reverses an earlier design (see docs/QUEST-TRACKER.md)
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
    local maxLines = Setting("trackerMaxLines")
    if type(maxLines) ~= "number" or maxLines < 3 then
        maxLines = 24
    end

    -- A MAXIMUM pixel height, or nil for "no ceiling, size to whatever the log
    -- needs". Height is stored in PIXELS rather than as a row count because
    -- rows here are not one size -- objective rows are a pixel taller than
    -- quest rows and both carry group gaps -- so no row count can name an exact
    -- height, and a resize that rounds to the nearest row is a resize whose
    -- bottom edge does not stay under the cursor holding it.
    --
    -- A log SHORTER than this shrinks the window to fit rather than leaving
    -- blank panel below the last row; a log longer is cut off here and reached
    -- with the scroll buttons or the wheel. The one exception is an active grip
    -- drag (resizeStartX non-nil): while the player is holding the corner the
    -- window must be exactly as tall as they have dragged it, or the bottom
    -- edge stops tracking the cursor and the grip reads as having stopped
    -- responding -- which is the recorded failure that made this an exact
    -- height in the first place. Auto-shrink therefore applies on release, not
    -- during the drag.
    local targetHeight = Setting("trackerHeight")
    if type(targetHeight) ~= "number" or targetHeight <= ROW_AREA_CHROME then
        targetHeight = nil
    end
    local resizing = self.resizeStartX and true or false

    local total = table.getn(lines)
    self.totalLines = total

    local collapsed = Setting("trackerCollapsed") and true or false
    if collapsed then
        maxLines = 0
        targetHeight = nil
    elseif targetHeight then
        -- A height ceiling replaces the row budget as the thing that decides
        -- how much is on screen: the loop below stops on the pixel bound, and
        -- this is only a generous cap so the row budget never cuts a window
        -- short of the height the player asked for. It errs HIGH on purpose --
        -- QUEST_ROW_HEIGHT is the shortest row kind and this ignores group
        -- gaps entirely -- because drawing stops at the real pixel edge anyway.
        maxLines = math.floor((targetHeight - ROW_AREA_CHROME) / QUEST_ROW_HEIGHT)
        if maxLines < 1 then
            maxLines = 1
        end
    end

    -- Clamp the scroll offset every draw rather than only when scrolling: the
    -- list shrinks on its own whenever a quest is handed in or a zone folded,
    -- and an offset left past the end would show an empty window.
    --
    -- The clamp budget is how many lines LAST draw actually placed, not
    -- maxLines. Under a height ceiling maxLines errs high (see above), and a
    -- maxOffset built from it errs low by the same amount -- which is exactly
    -- the bug where the last few rows could not be scrolled to and the v button
    -- disappeared while there was still list below the fold. linesDrawn is the
    -- measured count, so the clamp lands on the real end of the list; it is
    -- self-correcting because the next draw measures again, and it falls back
    -- to maxLines only on the very first draw, when nothing has been measured.
    local budget = self.linesDrawn
    if budget < 1 then
        budget = maxLines
    end
    local maxOffset = total - budget
    if maxOffset < 0 then
        maxOffset = 0
    end
    if self.offset > maxOffset then
        self.offset = maxOffset
    end
    if self.offset < 0 then
        self.offset = 0
    end

    Client.SetTrackerTitle(window, "UnrealQuest")
    Client.SetTrackerCount(window, completed .. "/" .. questCount)
    Client.SetTrackerCollapseLabel(window, collapsed and "+" or "-")

    local top = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING
    local used = { zone = 1, quest = 1, objective = 1 }
    local drawn = 0
    -- Tracks what was drawn immediately before, so a gap can be inserted
    -- between one quest's block and the next without also pushing a quest
    -- away from the zone header that just introduced it.
    local previousKind = nil

    local index = self.offset + 1
    while drawn < maxLines and index <= total do
        local line = lines[index]
        local kind = line.kind
        if kind == "quest" and (previousKind == "quest" or previousKind == "objective") then
            top = top + QUEST_GROUP_GAP
        elseif kind == "zone" and previousKind ~= nil then
            top = top + ZONE_GROUP_GAP
        end
        -- Stop on the dragged edge, not on a row count. Checked before the row
        -- is placed and against this row's OWN height, so a window never draws
        -- past the bottom the player dragged it to.
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

            local rowWidth = row.unrealQuestWidth or (width - indent)
            local fitted
            if kind == "quest" then
                fitted = Fit(line.text, rowWidth, QUEST_CHAR_WIDTH)
            elseif kind == "objective" then
                fitted = FitObjective(line.text, rowWidth, OBJECTIVE_CHAR_WIDTH)
            else
                fitted = Fit(line.text, rowWidth, OBJECTIVE_CHAR_WIDTH)
            end
            Client.SetTrackerRowText(row, fitted, line.red, line.green, line.blue)

            if kind == "quest" then
                row.unrealQuestSubject = line.quest
                Client.SetTrackerRowStripe(row, line.tracked and true or false)
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
                Client.SetTrackerRowStripe(row, false)
                Client.SetTrackerRowProgress(row, nil)
                if not row.unrealQuestBound then
                    row.unrealQuestBound = true
                    Client.SetTrackerRowClick(row, function() OnZoneRowClick(row) end)
                end
            else
                row.unrealQuestSubject = nil
                Client.SetTrackerRowStripe(row, false)
                if line.progressDone then
                    Client.SetTrackerRowProgress(row, line.progress,
                        COLOR_OBJECTIVE_DONE[1], COLOR_OBJECTIVE_DONE[2], COLOR_OBJECTIVE_DONE[3])
                else
                    Client.SetTrackerRowProgress(row, line.progress,
                        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3])
                end
            end

            top = top + height
            drawn = drawn + 1
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

    -- Set from the MEASURED draw, after the loop, not from maxOffset before it.
    -- "There is more below" is exactly "the last line drawn was not the last
    -- line there is", and only the loop knows how many it managed to place --
    -- it can stop early on the pixel ceiling or on a pool that refused to grow,
    -- neither of which any up-front estimate can predict. A window folded to
    -- its title bar drew nothing and must show neither button.
    Client.SetTrackerScrollButtons(window,
        not collapsed and self.offset > 0,
        not collapsed and (self.offset + drawn) < total)

    local height = Client.TRACKER_HEADER_HEIGHT
    if collapsed then
        -- nothing but the title bar
    elseif targetHeight and resizing then
        -- Mid-drag: exactly what the cursor is holding, blank space and all,
        -- so the bottom edge never leaves the grip (see targetHeight above).
        height = targetHeight
    else
        -- `top` only grew for rows actually drawn, so this is the content's own
        -- height. The ceiling still applies -- the draw loop already stopped at
        -- it -- but a shorter log now gives a shorter window instead of blank
        -- panel below the last row.
        height = top + BODY_PADDING
        if targetHeight and height > targetHeight then
            height = targetHeight
        end
    end
    Client.SetObjectSize(window, width, height)
    -- How many of totalLines actually fit. This is what the scroll clamp and
    -- the ^/v buttons are built from -- the real drawn count rather than the
    -- maxLines budget, because the draw loop can stop early on the pixel
    -- ceiling or on a pool that refused to grow.
    self.linesDrawn = drawn
    self.redraws = self.redraws + 1
end

-- Rebuilds the line list and redraws only when what is on screen would
-- actually differ. The signature is built from the visible slice, so an
-- objective counter ticking over one row below the fold does not repaint the
-- window, and a redraw never happens twice for the same state.
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
    local maxLines = Setting("trackerMaxLines")
    if type(maxLines) ~= "number" or maxLines < 3 then
        maxLines = 24
    end

    local parts = { tostring(questCount), tostring(completed), tostring(self.offset),
        Setting("trackerCollapsed") and "1" or "0", tostring(Setting("trackerWidth")) }
    local index = self.offset + 1
    local total = table.getn(lines)
    local seen = 0
    while seen < maxLines and index <= total do
        local line = lines[index]
        table.insert(parts, line.kind .. ":" .. tostring(line.text)
            .. ":" .. tostring(line.tracked) .. ":" .. tostring(line.progress))
        index = index + 1
        seen = seen + 1
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
    -- Also drops any height a grip drag set, so "reset" gives back the compact
    -- shipped window and not just its corner.
    Store("trackerHeight", 0)
    self.dirty = true
    self:ApplyStoredPosition()
end

-- Begins a grip drag, reproducing UnrealUI's measured chat-resize recipe
-- (unrealUI/modules/chat.lua's StartResize) rather than inventing one.
--
-- The decisive part is that the grip is GENUINELY MOVED by the client:
-- Client.StartFrameDrag applies SetMovable immediately before the drag, runs
-- the StartMoving/StopMovingOrSizing warm-up pair, then calls the real
-- StartMoving -- the same five-factor recipe the header handle needs
-- (frames.movable_drag_requires_button_handle, BEHAVIOR_VERIFIED).
--
-- An earlier version of this function did NOT do that. It left the grip
-- anchored and read the cursor instead, which meant the client was never put
-- into a drag state -- so it never reported one stopping, and the window kept
-- following the cursor after the button was released. Moving the grip for real
-- is what makes OnDragStop fire, and it is why there is no button-state
-- polling or OnMouseUp fallback here any more: the chat grip needs neither.
--
-- Returns false when the client refused, and the caller reports that visibly.
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
    -- Read the grip's corner AFTER the drag has started: the warm-up pair
    -- inside StartFrameDrag can settle it a pixel or two, and a baseline taken
    -- before that would show as a jump on the first tick.
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

    -- Pin the window to the height it ALREADY has, in the same breath as
    -- switching it to a fixed height at all. This is what stops the reported
    -- jump-on-click: the ordinary redraw job can easily land between this and
    -- the drag's first tick, and a fixed-height window whose height had not
    -- been seeded yet would snap to whatever the old value was. Seeding it
    -- from the measurement above makes that redraw a no-op -- the window is
    -- already exactly that tall -- so nothing moves until the grip does.
    local config = Config()
    if config then
        config:Set("trackerHeight", height)
    end

    grip.unrealQuestResizing = true
    -- Shown explicitly rather than relying on OnEnter having already fired: a
    -- fast press-and-drag can beat the hover state, and the mark disappearing
    -- for even one tick mid-resize would read as the grip letting go.
    Client.ShowObject(grip.unrealQuestMark)
    return true
end

-- Ends a grip drag. Idempotent: OnDragStop is the only caller in normal use,
-- but a failed StartResize unwinds through here too, and stopping twice must
-- be a no-op rather than an error.
function TrackerFrame:StopResize()
    local grip = self.grip
    if grip then
        grip.unrealQuestResizing = false
        Client.StopFrameDrag(grip)
        -- The grip was moved by the client and keeps whatever point that left
        -- it on, so it has to be put back in the window's corner explicitly or
        -- it stays floating where it was dropped.
        Client.AnchorObjectToCorner(grip, self.window)
        -- The mark is pinned visible for the whole drag (the cursor leaves the
        -- 12x12 grip almost immediately), so releasing has to hide it unless
        -- the cursor came to rest back inside the window, where the hover
        -- reveal below would show it anyway.
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

-- Runs on the shared driver's "tracker.griphover" job. The grip's own
-- OnEnter/OnLeave still work and are left in place, but they only ever fire
-- for the 12x12 corner itself -- a player who never happens to put the cursor
-- on those few pixels has no way to learn the window resizes at all. So the
-- mark is offered for the WHOLE window instead: hovering anywhere over the
-- tracker reveals the corner artwork, which is the affordance.
--
-- Polled rather than driven from the window's OnEnter/OnLeave, per the
-- addon's event rule and for a concrete reason here: the window is covered by
-- mouse-enabled quest rows, so moving onto a row fires the window's OnLeave
-- and the mark would blink off over exactly the area the player is reading.
-- Client.IsCursorInsideObject is a rectangle test and stays true across every
-- child. It is deliberately not Client.IsObjectMouseOver: Frame:IsMouseOver
-- has no record on this client and the first version of this job, written
-- against it, never revealed the mark once.
function TrackerFrame:UpdateGripHover()
    local grip = self.grip
    if not grip or not grip.unrealQuestMark then
        return
    end
    -- A drag owns the mark outright (StartResize pins it, StopResize decides):
    -- the cursor is usually far outside the window by the second tick.
    if grip.unrealQuestResizing then
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

-- Runs on the shared driver's "tracker.resize" job, scheduled only while the
-- corner grip is actually being dragged.
--
-- Both axes are computed in PIXELS from the window's size at drag start, the
-- way the chat grip does it. Doing it the other way round -- turning the drag
-- into a row count and storing that -- is what made the window jump the
-- instant the grip was clicked: trackerMaxLines is a MAXIMUM, rows here are
-- not all one height, and a log drawing fewer or shorter rows than the budget
-- leaves the window shorter than its own setting implies, so seeding a drag
-- from that setting teleported the bottom edge to where the setting had always
-- said it was. Seeding from the measured height means a zero-distance drag
-- produces a zero-pixel change, which is the only thing that can never jump.
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

    -- The grip rides the window's BOTTOM edge, so dragging it downward lowers
    -- its GetBottom while making the window taller -- hence the subtraction.
    -- The grip rides the window's BOTTOM edge, so dragging it downward lowers
    -- its GetBottom while making the window taller -- hence the subtraction.
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
    self.offset = 0
    self.dirty = true
    self:Refresh()
end

function TrackerFrame:Scroll(delta)
    self.offset = self.offset + delta
    if self.offset < 0 then
        self.offset = 0
    end
    self.dirty = true
    self:Refresh()
end

-- Mouse wheel: NOT POSSIBLE ON THIS CLIENT ----------------------------------
--
-- There is no mouse-wheel scrolling here, and this section exists so the next
-- person does not implement it a third time. It was built, shipped, measured
-- in game and removed.
--
-- Wheel input never reaches an addon frame on this client -- the binding layer
-- consumes it first (chat.mousewheel_uses_binding_layer), so EnableMouseWheel
-- plus OnMouseWheel is a recorded failed approach, and CLICK bindings are
-- recorded in the same note as unimplemented. The one technique left, and the
-- one UnrealPfUI's chat uses, is to point MOUSEWHEELUP/DOWN at a real binding
-- command while the cursor is over the window. That is what used to be here.
--
-- The wheelbinding probe (behavior.json / wheelbinding.*, and the knowledge
-- record scripts.addon_wheel_binding_unavailable) measured why it never worked:
--
--   * This addon's own Bindings.xml commands are ABSENT from the client's
--     225-entry binding table. Addon-declared binding commands do not register
--     on this client at all -- unrealUI hit the identical wall with
--     UNREALUIBAR2BUTTON1-12 (actionbars.pages_without_binding_command). So
--     there was never a command to point the wheel at.
--   * SetBinding is REFUSED on MOUSEWHEELUP/MOUSEWHEELDOWN: it returns false
--     and GetBindingAction still reads CAMERAZOOMIN/OUT. Clearing the key with
--     the one-argument form first does not help. The same call on a free key
--     (MOUSEWHEELAXIS) is accepted, so this is these keys, not SetBinding.
--   * SetBinding does not validate the command name, which is why all of this
--     failed silently for as long as it did.
--
-- The key names were never the problem: MOUSEWHEELUP/DOWN are exactly what the
-- client itself has on CAMERAZOOMIN/OUT.
--
-- Do not re-add a Bindings.xml. Do not add EnableMouseWheel. The ^ / v buttons
-- and the resize grip are the scroll controls, deliberately.

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
        -- 0 means "no ceiling, as tall as the log needs"; anything else is a
        -- MAXIMUM, from the corner grip or /uq tracker height. A log shorter
        -- than it shrinks the window rather than padding it.
        height = Setting("trackerHeight"),
        linesDrawn = self.linesDrawn,
        maxLines = Setting("trackerMaxLines"),
        objectives = Setting("trackerShowObjectives"),
        groupByZone = Setting("trackerGroupByZone") and true or false,
        hideNativeWatch = Setting("trackerHideNativeWatch") and true or false,
        lines = self.totalLines,
        offset = self.offset,
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
    -- Missing, and measured missing rather than assumed: see the Mouse wheel
    -- section above. Declared unconditionally because SetBinding and
    -- GetBindingAction both RESOLVE on this client -- checking for them would
    -- report a capability the tracker demonstrably does not have.
    UQ:DeclareCapability("trackerMouseWheel", "missing",
        "measured absent, not assumed (wheelbinding probe): this addon's Bindings.xml commands "
        .. "never reach the client's 225-entry binding table, and SetBinding is refused on "
        .. "MOUSEWHEELUP/MOUSEWHEELDOWN even after clearing them, so the wheel cannot be pointed "
        .. "at addon code by any route. The tracker scrolls with its ^ and v buttons and the "
        .. "resize grip")

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
                -- Reported visibly, never to debug-only output: a resize that
                -- silently does nothing is the same class of bug as the
                -- immovable window that logging-to-debug once hid completely.
                UQ:Warn("the tracker's corner grip could not start a resize; its size can "
                    .. "still be set with /uq tracker width and /uq tracker lines")
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
            .. "/uq tracker width and /uq tracker lines")
    end

    Client.SetTrackerHeaderButtons(window,
        function() TrackerFrame:ToggleCollapsed() end,
        function() TrackerFrame:Scroll(-5) end,
        function() TrackerFrame:Scroll(5) end)

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
        -- 0.1s is a hover reveal, so it has to feel immediate; the job reads
        -- one rectangle and touches a texture only when the answer changed
        -- side.
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
TrackerFrame.FitObjective = FitObjective
