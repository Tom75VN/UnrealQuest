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
  * The world map's copy moves by its header too, but cursor-driven rather
    than through StartMoving -- see "The map copy" below ResetPosition.
  * Drag the bottom-right corner to resize the window in both axes.
  * Past half the screen height the list is paged; the arrows on the bottom
    row turn the page (TurnHudPage), as on the map copy.
  * Left click a quest: follows it. Clicking a manually followed quest returns
    following to the nearest node; clicking the automatic nearest quest does
    nothing because following always has one target.
  * Alt + left click a quest: selects it in the native Quest Log and opens it.
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
local MAP_WINDOW_NAME = "UnrealQuestMapTracker"
local HANDLE_NAME = "UnrealQuestTrackerHandle"
local MAP_HANDLE_NAME = "UnrealQuestMapTrackerHandle"
local MAP_TRACKER_DEFAULT_X = -25
local MAP_TRACKER_DEFAULT_Y = -82
local GRIP_NAME = "UnrealQuestTrackerResizeGrip"
local MAP_TRACKER_WIDTH = 220
local MAP_TRACKER_MAX_HEIGHT = 520
-- The map copy never grows past this share of WorldMapFrame's height; content
-- taller than that is split into pages turned by the arrows on its bottom row.
-- MAP_TRACKER_MAX_HEIGHT is the ceiling only when the map's height is unread.
local MAP_TRACKER_PAGE_FRACTION = 0.4
-- The HUD window's share of the screen (its parent, UIParent) past which its
-- content is paged the same way. A shorter saved resize height still wins:
-- below this share the window keeps drawing only the rows that fit.
local HUD_TRACKER_PAGE_FRACTION = 0.5
-- The HUD pager keeps clear of the resize grip in the bottom-right corner,
-- and by the same amount on the left so it stays centred.
local HUD_PAGER_SIDE_CLEARANCE = 14
-- The map copy's background opacity, in percent. Fixed rather than read from
-- trackerBackgroundOpacity: the map artwork behind it needs a steady backing.
local MAP_TRACKER_OPACITY = 40

local RESIZE_MIN_WIDTH = 110
local RESIZE_MAX_WIDTH = 600
local RESIZE_MIN_HEIGHT = 60
local RESIZE_MAX_HEIGHT = 900

local COLLAPSED_QUESTS = "trackerCollapsedQuests"
local COLLAPSED_ZONES = "trackerCollapsedZones"
local HIDDEN_QUESTS = "trackerHiddenQuests"

-- Tall enough for the zone name above the section bar drawn under it.
local ZONE_ROW_HEIGHT = 18
local QUEST_ROW_HEIGHT = 16
local WRAPPED_ROW_TEXT_PADDING = 2
-- 2px taller than the text itself needs: an objective row's progress bar is
-- bottom-anchored (Compatibility/ClientAPI.lua's track/fill textures), so the
-- extra height is what actually reads as a margin-top on the bar -- the gap
-- between the counter text above it and the bar itself.
local OBJECTIVE_ROW_HEIGHT = 14
local OBJECTIVE_ROW_GAP = 1
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

-- The category name (zone/subzone) reads in full white.
local COLOR_ZONE = { 1, 1, 1 }
-- The empty-filter notice keeps the former muted grey: it is a remark, not a
-- category name.
local COLOR_ZONE_EMPTY = { 0.45, 0.45, 0.45 }
local COLOR_OBJECTIVE = { 0.78, 0.78, 0.78 }
local COLOR_OBJECTIVE_DONE = { 0.35, 0.68, 0.35 }
local COLOR_COMPLETE = { 1, 1, 1 }

-- Appended to every quest tooltip (Client.ShowGameTooltip's line-list shape,
-- see Compatibility/ClientAPI.lua RenderTooltipLines), so the gesture list is
-- something the player can actually look up instead of having to remember.
-- KEYS, not text. This table is built when the file loads, which is before
-- Core/Locale.lua has resolved the language, so a translated string baked in
-- here would be English for the whole session. Resolved per tooltip below.
local SHORTCUT_KEYS = {
    "TRACKER_HINT_LEFT_CLICK",
    "TRACKER_HINT_ALT_CLICK",
    "TRACKER_HINT_SHIFT_CLICK",
    "TRACKER_HINT_CTRL_CLICK",
    "TRACKER_HINT_RIGHT_CLICK",
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
TrackerFrame.mapHandle = nil
-- Set while the map copy's header is dragged: the cursor and the offsets the
-- drag started from, and the offsets it has reached.
TrackerFrame.mapDrag = nil
TrackerFrame.mapDrags = 0
TrackerFrame.mapPager = nil
TrackerFrame.mapPage = 1
TrackerFrame.mapPages = 1
TrackerFrame.hudPager = nil
TrackerFrame.hudPage = 1
TrackerFrame.hudPages = 1
-- Set by RevealQuest: the HUD's next paged redraw opens the page that holds
-- this quest's row, then forgets it.
TrackerFrame.hudRevealTitle = nil
TrackerFrame.pendingRevealTitle = nil
TrackerFrame.mapInitialized = false
TrackerFrame.mapDirty = true

local function Config()
    return UQ:GetModule("Config")
end

local function State()
    return UQ:GetModule("QuestState")
end

local function Watch()
    return UQ:GetModule("Tracker")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

local function ZonePresence()
    return UQ:GetModule("QuestZonePresence")
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

-- The player's own answer for `key`: true when they folded it, false when they
-- unfolded it, nil when they never said anything about it. Presence alone
-- cannot carry that third state, so an entry is stored as 1 for folded and 0
-- for unfolded rather than as a bare marker. Sections that only ever record a
-- fold (zones, hidden quests) simply never write the 0 and read back nil or
-- true exactly as before.
local function FoldChoice(section, key)
    local config = Config()
    if not config or type(key) ~= "string" then
        return nil
    end
    local folded = config:GetSection(section)
    local value = folded and folded[key]
    if value == nil then
        return nil
    end
    return value ~= 0
end

local function IsFolded(section, key)
    return FoldChoice(section, key) == true
end

local function SetFolded(section, key, folded)
    local config = Config()
    if not config or type(key) ~= "string" then
        return
    end
    config:SetSectionEntry(section, key, folded and 1 or 0)
end

local function ClearFold(section, key)
    local config = Config()
    if config and type(key) == "string" then
        config:SetSectionEntry(section, key, nil)
    end
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
        label = "[" .. UQ.FormatQuestLevel(quest.level, quest) .. "] "
    end
    return label .. (UQ.GetQuestDisplayTitle(quest) or "?")
end

-- The current-zone filter ------------------------------------------------------
--
-- `trackerCurrentZoneOnly` narrows the window to quests the player can work on
-- in the relevant zone: the zone they are standing in while the map is
-- closed, or the individual zone currently open on the fullscreen map. That
-- is asked in two ways, in order of confidence:
--
--   * when the zone's map can answer, its objective dot or tile, turn-in
--     marker or vendor pin decides (Map/QuestZonePresence.lua);
--   * otherwise the quest log's own header row is the conservative fallback,
--     including for a quest this client's absent quest ID API left unmatched.
--
-- The map question is the one that matters, because the header names the
-- zone a quest BELONGS to, not the zone its objectives are in. A quest taken
-- in Duskwood whose every kill is in Westfall was hidden for exactly the time
-- the player was in Westfall doing it. The reverse is a breadcrumb accepted
-- in Elwynn whose only remaining step is a Westfall turn-in: its Elwynn header
-- must not keep it after the map has proved there is nothing to do in Elwynn.
--
-- Both sides of the header comparison are localized strings the client
-- produced -- the quest log's header (captured onto the quest by
-- Quest/QuestState.lua) and the client's zone name -- so they are matched
-- through UQ.NameKey rather than raw equality, exactly as every other name
-- comparison in this addon is.
--
-- Indoors, this client names the ROOM ----------------------------------------
--
-- Step into a mine and both zone calls answer with the mine. Probe zoneindoor,
-- 2026-08-29, walking into Echo Ridge Mine in Elwynn Forest:
--
--            zoneText        realZoneText    subZoneText       in GetMapZones
--   outside  Elwynn Forest   Elwynn Forest   Echo Ridge Mine   yes
--   inside   Echo Ridge Mine Echo Ridge Mine (empty)           no
--
-- Both indoor names resolve UNIQUELY to area 34, a real area holding no quest
-- data, so the join looked confident and returned nothing: every quest header
-- was compared against "Echo Ridge Mine", none matched, area 34 had no map
-- points either, and the window emptied for as long as the player was inside.
--
-- Note what the subzone does: indoors it goes EMPTY and the room is promoted
-- to the zone. So "the zone and the subzone name the same place" -- the shape
-- a building suggested and the shape this filter first shipped -- never fires
-- here, and no rescue that rests on it can work. What separates the two rows
-- is membership in the client's OWN zone list for the continent, and
-- MapContext:GetStandingZone is that test plus the ordered recovery behind it
-- (the bundled parent link, the last zone the player was proven to stand in,
-- the viewed map's zone name). Its `how` is reported by /uq tracker.
--
-- When every route declines, the filter is switched off and the whole log is
-- listed. An unfiltered window is a far smaller wrong than an empty one.
--
-- Inside a DUNGEON, the client names the dungeon ----------------------------
--
-- Which is the same shape as the mine above and wants the opposite answer. A
-- mine is still in Elwynn Forest, so the last outdoor zone is the right thing
-- to filter on; a dungeon is not, and filtering on the outdoor zone the player
-- walked in from is what left this window listing the whole quest log the
-- moment anybody stepped through a portal -- every outdoor quest survived on
-- its header, or none did and the guard below listed them all anyway.
--
-- MapContext:GetStandingZone therefore answers an instance with the instance's
-- own name, on a route of its own ("instance"), ahead of every recovery that
-- can only produce an outdoor zone.
--
-- The map half cannot follow it in there. THE BUNDLED DATA HOLDS NO
-- COORDINATE INSIDE ANY INSTANCE AT ALL -- every recorded position sits in one
-- of the 50 outdoor areas this client draws a map for -- so asking
-- QuestZonePresence:HasPoints about the Deadmines' own area would answer false
-- for a Deadmines quest and hide exactly the quests the player came in to do.
-- QuestZonePresence:HasInstanceWork replaces it there, answering from the
-- creature provenance in Database/instance_only_units.lua instead of from
-- position, and the quest-log header stays the fallback underneath it exactly
-- as it is outdoors.

-- The filter may narrow the window, never empty it --------------------------
--
-- Every input above is a hypothesis this client cannot be made to confirm:
-- which zone the player is standing in, which bundled area that localized name
-- resolves to, and whether the map draws anything for a quest there. Walking
-- through a door is the case that keeps finding new ways to make one of them
-- wrong, and the cost is always the same and always the worst one -- the whole
-- window goes blank, which reads to the player as the addon having died rather
-- than as a filter being too strict.
--
-- So BuildLines enforces the outcome directly: the zone filter never leaves an
-- empty window. But "empty" has two completely different causes, and the first
-- shape of this guard could not tell them apart -- it listed the WHOLE log
-- whenever nothing survived, which turned every ordinary walk through a zone
-- the player has no quests in (a capital, a zone being crossed, a zone whose
-- quests are all finished elsewhere) into an unfiltered tracker. That is the
-- filter failing in the loud direction instead of the quiet one, and it is
-- what this split fixes:
--
--   * the zone was IDENTIFIED and simply holds nothing to do -- routes
--     "standing", "standingSpan" and "parent", each a positive identification
--     of a real zone rather than a recovery from one that could not be made.
--     The filter is right, so it stands, and the window says so in one row
--     (TRACKER_ZONE_EMPTY, appended at the end of BuildLines) instead of
--     going blank.
--   * the zone could NOT be identified -- routes "remembered", "mapZone" and
--     "unlistable", where the name is a guess, a stale memory or a map the
--     player is merely browsing. Here an empty result is evidence about the
--     GUESS, not about the zone, so the filter is dropped for that build and
--     the entire log is listed.
--
-- The second half is still deliberately a guard on the symptom rather than on
-- any one cause, so it keeps holding for causes not yet found -- a room the
-- bundled table does not know at all, a client call that starts answering
-- differently, a zone name that resolves to nothing. /uq tracker reports the
-- two outcomes separately as zonedrop=true and zoneempty=true: the first says
-- the zone the addon settled on is wrong, the second says the player has
-- nothing to do where they are standing.

local function MapContext()
    return UQ:GetModule("MapContext")
end

-- Which of GetStandingZone's routes are a positive identification of a real
-- zone, as opposed to a recovery from one that could not be made. Only these
-- three let an empty filter result stand as an answer about the ZONE -- see
-- "The filter may narrow the window, never empty it" above.
local PROVEN_ZONE_ROUTES = {
    standing = true,
    standingSpan = true,
    parent = true,
    -- GetViewedZone accepts only a named individual-zone view. Unlike the
    -- indoor recovery routes below, it never derives this from where the
    -- player is standing, so an empty result is a real answer about the map
    -- the player deliberately opened.
    viewedMap = true,
    -- The client told us the player is inside an instance, or the bundled
    -- instance table named the area. Either way the place is identified, so an
    -- empty result is an answer about the dungeon and not about a guess.
    instance = true,
}

-- Returns the normalized zone name, the resolved area ID for the map half, the
-- route the name was reached by, and -- when that route is "instance" -- the
-- dungeon or raid map ID the provenance half needs. Each may be nil
-- independently: an unresolvable area only costs the map question, an
-- unresolvable instance map only costs the provenance question, and an unnamed
-- zone disables the filter entirely.
--
-- Ungated: the filter reaches it through CurrentZone below, and with the filter
-- off BuildLines still asks it which zone's quests to list first.
local function ResolveZone()
    local mapContext = MapContext()
    if not mapContext then
        return nil
    end

    -- The fullscreen map hides the game UI on this client. While it owns the
    -- screen, both tracker windows answer the map the player is browsing, not
    -- the zone their character is standing in. GetViewedZone is deliberately
    -- used here rather than GetCurrentZoneView: the latter refuses a foreign
    -- zone because the player has no projectable position on it. On a
    -- continent/world view there is no current zone, so fall through to the
    -- standing-zone answer instead of filtering on a guess.
    if Client.IsGameUIHidden() == true then
        local viewedAreaId, report = mapContext:GetViewedZone()
        local viewedName = report and report.mapZoneName
        if type(viewedAreaId) == "number" and type(viewedName) == "string"
            and viewedName ~= "" then
            TrackerFrame.currentZoneName = viewedName
            TrackerFrame.currentZoneHow = "viewedMap"
            return UQ.NameKey(viewedName), viewedAreaId, "viewedMap", nil
        end
    end

    local name, areaId, how = mapContext:GetStandingZone()
    TrackerFrame.currentZoneName = name
    TrackerFrame.currentZoneHow = how
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local instanceMap = nil
    if how == "instance" then
        instanceMap = mapContext:GetInstanceMapForArea(areaId)
    end
    return UQ.NameKey(name), areaId, how, instanceMap
end

-- The zone the filter narrows to, or nil when the filter is off.
local function CurrentZone()
    if not Setting("trackerCurrentZoneOnly") then
        return nil
    end
    return ResolveZone()
end

-- True for a quest that has no drawable work in the current zone, falling back
-- to its quest-log header only when the map cannot answer.
--
-- A definite map answer wins in both directions. This is what makes the option
-- mean "work available here" rather than "filed here by the quest log": true
-- keeps a cross-zone objective, while false removes a breadcrumb whose header
-- names this zone but whose remaining turn-in is elsewhere. nil from HasPoints
-- means the map could not be asked (an unmatched quest, or one deliberately
-- withheld from the map), so only then does the localized header comparison
-- decide. A missing header stays visible because there is no fallback
-- comparison to make, and a missing current-zone name disables the filter.
-- The zone a quest log header sits inside, normalized, or false for one that
-- is already top level. Memoized: the walk is two static table reads, but it
-- would otherwise run per quest per 0.4s refresh, and the set of headers in a
-- log is tiny and changes only on accept or turn-in.
local headerParentKeys = {}

local function HeaderParentKey(zone, zoneKey)
    local cached = headerParentKeys[zoneKey]
    if cached ~= nil then
        return cached
    end
    local parentKey = false
    local presence = ZonePresence()
    if presence then
        local areaId = presence:ResolveArea(zone)
        if areaId then
            local parentId, parentName = presence:ResolveEnclosingArea(areaId)
            if parentName then
                parentKey = UQ.NameKey(parentName) or false
            end
        end
    end
    headerParentKeys[zoneKey] = parentKey
    return parentKey
end

-- `where` is the one table BuildLines assembles before the scan: the
-- normalized zone name every comparison here is against, the area the map half
-- asks about, whether the player is inside an instance at all, and the instance
-- map the provenance half asks about. The last two are separate on purpose --
-- the client can say "instance" for a place Database/instances.lua has no row
-- for, and that still has to switch the map half off.
local function IsOtherZone(quest, zone, where)
    local currentZoneKey = where.zoneKey
    if not currentZoneKey then
        return false
    end
    if where.inInstance then
        -- Not the map half: there is no coordinate in here to ask it about.
        if where.instanceMap then
            local presence = ZonePresence()
            if presence then
                local hasWork = presence:HasInstanceWork(quest, where.instanceMap)
                if hasWork ~= nil then
                    return not hasWork
                end
            end
        end
    elseif where.areaId then
        local presence = ZonePresence()
        if presence then
            local hasPoints = presence:HasPoints(quest, where.areaId)
            if hasPoints ~= nil then
                return not hasPoints
            end
        end
    end
    if type(zone) ~= "string" or zone == "" then
        return false
    end
    local zoneKey = UQ.NameKey(zone)
    if not zoneKey or zoneKey == currentZoneKey then
        return false
    end
    -- The header can be a SUBZONE of the zone the player is standing in: probe
    -- zoneindoor captured a log whose only header was "Northshire Valley" while
    -- the client's zone was "Elwynn Forest", so the header comparison above
    -- never matched and those quests were kept, if at all, only by the map
    -- half. Database/zones.lua files 9 under 12, which settles it directly.
    if HeaderParentKey(zone, zoneKey) == currentZoneKey then
        return false
    end
    return true
end

-- True only when the option asks for automatic folding and the live quest
-- model proves that every objective is still at zero. A counterless line is
-- undecidable and stays expanded; otherwise talk, exploration or
-- server-specific objectives could be folded merely because their text has no
-- N/M suffix for QuestState to parse.
local function ShouldAutoCollapseQuest(quest)
    if not Setting("trackerHideUnstartedQuests") or quest.isComplete == 1 then
        return false
    end

    local objectives = quest.objectives or {}
    local total = table.getn(objectives)
    if total == 0 then
        return false
    end

    local index = 1
    while index <= total do
        local objective = objectives[index]
        if not objective or objective.finished
            or type(objective.have) ~= "number"
            or type(objective.need) ~= "number" or objective.need <= 0 then
            return false
        end
        if objective.have > 0 then
            return false
        end
        index = index + 1
    end
    return true
end

-- How far along a quest is, as one number: every readable counter plus every
-- objective the client calls finished. Only used to notice that it went up, so
-- the absolute value means nothing and a counterless objective contributing 0
-- is fine -- its `finished` flag still moves the total when it completes.
local function ProgressMark(quest)
    local objectives = quest.objectives or {}
    local total = table.getn(objectives)
    local mark = 0
    local index = 1
    while index <= total do
        local objective = objectives[index]
        if objective then
            if type(objective.have) == "number" then
                mark = mark + objective.have
            end
            if objective.finished then
                mark = mark + 1
            end
        end
        index = index + 1
    end
    if quest.isComplete == 1 then
        mark = mark + 1
    end
    return mark
end

-- A fold lasts until the quest tells the player something new. Killing a mob,
-- looting a quest item or finishing an objective drops the stored fold, so the
-- row that just changed opens and shows what changed -- which is the whole
-- point of a tracker. A quest already carrying progress the first time it is
-- seen (a fresh login, a /reload) is unfolded on the same grounds: a started
-- quest is never left closed by a fold whose reason nobody can still see.
--
-- Marks are kept in memory only, per quest title, and are dropped when the
-- quest leaves the log (ForgetMissingMarks). Persisting them would freeze this
-- decision across sessions, and the fold sections are the only thing that
-- needs to survive a logout. Dropping them makes a quest abandoned and taken
-- again a first sight, which is what it is.
local progressMarks = {}

-- The build order's second input. A quest whose mark goes up is stamped with
-- the next serial, and FloatRecentFirst below floats stamped quests to the top
-- of the window, newest first, so the quest that just told the player
-- something is the one under the header rather than wherever the raw quest log
-- happens to file it. Serials are unique and strictly increasing, so a later
-- advance always outranks an earlier one.
--
-- Kept in memory beside the marks and dropped with them, for the same reason:
-- a lift is an answer to something the player just did, and restoring it a day
-- later would answer nothing.
local advanceSerials = {}
local advanceCursor = 0

local function NoteProgress(quest)
    local title = quest.title
    if type(title) ~= "string" or title == "" then
        return
    end
    local mark = ProgressMark(quest)
    local previous = progressMarks[title]
    progressMarks[title] = mark
    if previous == nil then
        -- First sight this session: a quest that is already under way clears
        -- the fold, one that has not started keeps whatever the player chose.
        if mark > 0 and FoldChoice(COLLAPSED_QUESTS, title) ~= nil then
            ClearFold(COLLAPSED_QUESTS, title)
        end
        return
    end
    if mark > previous then
        ClearFold(COLLAPSED_QUESTS, title)
        advanceCursor = advanceCursor + 1
        advanceSerials[title] = advanceCursor
    end
end

local function ForgetMissingMarks(seen)
    local stale = nil
    for title in pairs(progressMarks) do
        if not seen[title] then
            stale = stale or {}
            table.insert(stale, title)
        end
    end
    if not stale then
        return
    end
    local index = 1
    local total = table.getn(stale)
    while index <= total do
        progressMarks[stale[index]] = nil
        advanceSerials[stale[index]] = nil
        index = index + 1
    end
end

-- The whole log, before anything is ordered or filtered: a quest hidden from
-- this window still advances, and both the fold it drops and the serial it
-- earns have to be recorded before the ordering below reads them. This used to
-- run inside the drawing loop, which stamped the advance one build after the
-- order had already been decided, so the row that changed rose only on the
-- following refresh.
local function NoteProgressPass(quests)
    local seen = {}
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        NoteProgress(quest)
        if type(quest.title) == "string" then
            seen[quest.title] = true
        end
        index = index + 1
    end
    ForgetMissingMarks(seen)
end

-- Floats every quest that has advanced this session to the top of the list it
-- is in, most recent first; everything behind them keeps the quest log's own
-- order. Unstamped quests are the common case on login, where this returns the
-- list untouched.
--
-- With zone grouping on this deliberately breaks the log's zone runs: the
-- lifted quest carries its own header to the top and its zone is named twice,
-- the same trade the complete tail below already makes. Being shown what just
-- changed is the point of the lift; keeping the header count down is not.
local function FloatRecentFirst(quests)
    local lifted = {}
    local rest = {}
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if quest.title and advanceSerials[quest.title] then
            table.insert(lifted, quest)
        else
            table.insert(rest, quest)
        end
        index = index + 1
    end

    if table.getn(lifted) == 0 then
        return quests
    end

    -- Serials are unique, so the comparison is a total order and table.sort
    -- has no stability left to lose.
    table.sort(lifted, function(a, b)
        return advanceSerials[a.title] > advanceSerials[b.title]
    end)

    index = 1
    total = table.getn(rest)
    while index <= total do
        table.insert(lifted, rest[index])
        index = index + 1
    end
    return lifted
end

-- With the current-zone filter off, the quests filed under the current zone's
-- quest-log header -- or under a subzone of it, by the same parent walk the
-- filter's header half uses -- move to the top of the list they are in,
-- everything else keeping its order. "Current" is the zone ResolveZone
-- answers: the zone being viewed while the fullscreen map is open, which is
-- when the map's tracker is on screen, and the zone the player stands in
-- otherwise, which is when the HUD tracker is.
--
-- Applied to each half of OrderQuestsCompleteLast separately, so the current
-- zone heads the window and also heads the complete tail, but a complete quest
-- still never rises above work left to do. It runs after the recent-first
-- lift: a quest advanced elsewhere stays above the rest of its own half, just
-- not above the zone the player is in or looking at.
local function FloatCurrentZoneFirst(quests, zoneKey)
    if not zoneKey then
        return quests
    end
    local lifted = {}
    local rest = {}
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        local zone = quest.zone
        local questZoneKey = type(zone) == "string" and zone ~= "" and UQ.NameKey(zone)
        if questZoneKey and (questZoneKey == zoneKey
            or HeaderParentKey(zone, questZoneKey) == zoneKey) then
            table.insert(lifted, quest)
        else
            table.insert(rest, quest)
        end
        index = index + 1
    end
    if table.getn(lifted) == 0 then
        return quests
    end
    index = 1
    total = table.getn(rest)
    while index <= total do
        table.insert(lifted, rest[index])
        index = index + 1
    end
    return lifted
end

-- Stable partition that moves every complete quest after every quest still in
-- progress, so the window reads as "what is left to do" first and "ready to
-- turn in" last. The partition is global: a complete quest sinks to the very
-- bottom of the window, not merely to the bottom of its own zone's block, and
-- the relative order inside each half is the raw quest log's own.
--
-- With zone grouping on, the complete tail is re-grouped by zone as it is
-- appended -- zones in the order their first complete quest appears -- so that
-- one zone's complete quests stay contiguous and the lazy header machinery in
-- BuildLines still writes a single header for them. The cost is that a zone
-- holding both kinds is named twice, once above with what is left to do and
-- once at the bottom with what is ready to turn in; that is the price of the
-- complete quests actually being at the bottom, which is what the header
-- ordering exists to serve rather than the other way round.
--
-- Removing quests from the middle cannot break the contiguity of the ones that
-- remain, so the incomplete half keeps the log's own zone runs untouched.
--
-- `topZoneKey`, when given, floats that zone to the head of each half; see
-- FloatCurrentZoneFirst above.
local function OrderQuestsCompleteLast(quests, groupByZone, recentFirst, topZoneKey)
    local total = table.getn(quests)
    local ordered = {}
    local complete = {}

    local index = 1
    while index <= total do
        local quest = quests[index]
        if quest.isComplete == 1 then
            table.insert(complete, quest)
        else
            table.insert(ordered, quest)
        end
        index = index + 1
    end

    -- Only the half still in progress is floated. A complete quest belongs at
    -- the bottom whatever it did last, and completing one moves its mark too.
    if recentFirst then
        ordered = FloatRecentFirst(ordered)
    end
    ordered = FloatCurrentZoneFirst(ordered, topZoneKey)
    complete = FloatCurrentZoneFirst(complete, topZoneKey)

    local completeCount = table.getn(complete)
    if not groupByZone then
        index = 1
        while index <= completeCount do
            table.insert(ordered, complete[index])
            index = index + 1
        end
        return ordered
    end

    -- One pass per zone, driven by the first complete quest that names it. A
    -- quest with no zone at all is its own group under the "" key rather than
    -- being dropped: the draw loop tolerates a nil zone (it writes no header),
    -- and losing a complete quest here would silently shorten the window.
    local emitted = {}
    index = 1
    while index <= completeCount do
        local zoneKey = complete[index].zone or ""
        if not emitted[zoneKey] then
            emitted[zoneKey] = true
            local scan = index
            while scan <= completeCount do
                local other = complete[scan]
                if (other.zone or "") == zoneKey then
                    table.insert(ordered, other)
                end
                scan = scan + 1
            end
        end
        index = index + 1
    end
    return ordered
end

-- Turns the model into the flat list of rows the window draws. Everything that
-- decides what is visible -- folds, tracker filters, the objective setting,
-- zone grouping -- happens here, so the drawing pass below is pure placement.
function TrackerFrame:BuildLines()
    local lines = {}
    local state = State()
    if not state then
        return lines, 0, 0
    end

    local watch = Watch()
    local mainQuest = MainQuest()
    local showObjectives = Setting("trackerShowObjectives") or "all"
    local groupByZone = Setting("trackerGroupByZone") and true or false
    -- Decided here rather than at draw time so that turning the bars off
    -- actually changes the line list, and therefore the redraw signature
    -- Refresh compares -- a draw-time-only gate leaves the signature identical
    -- and the window never repaints.
    local progressBars = Setting("trackerProgressBar") and true or false
    local recentFirst = Setting("trackerRecentFirst") and true or false
    local currentZoneKey, currentAreaId, currentZoneHow, currentInstanceMap = CurrentZone()
    local where = {
        zoneKey = currentZoneKey,
        areaId = currentAreaId,
        inInstance = currentZoneHow == "instance",
        instanceMap = currentInstanceMap,
    }
    local mapKept = 0
    local quests = state:GetOrderedQuests()
    NoteProgressPass(quests)
    -- The map numbers quests before any view filter or display ordering is
    -- applied. Preserve that same index here so complete-last, recent-first,
    -- hidden quests and a foreign-zone map can move rows without renumbering
    -- the quest they identify.
    local questNumbers = {}
    local numberIndex = 1
    local numberTotal = table.getn(quests)
    while numberIndex <= numberTotal do
        local numberedQuest = quests[numberIndex]
        if numberedQuest and numberedQuest.titleKey then
            questNumbers[numberedQuest.titleKey] = numberIndex
        end
        numberIndex = numberIndex + 1
    end
    local topZoneKey = nil
    if not currentZoneKey then
        topZoneKey = ResolveZone()
    end
    quests = OrderQuestsCompleteLast(quests, groupByZone, recentFirst, topZoneKey)
    local total = table.getn(quests)

    -- The zone filter is decided in full before a single row is written, so
    -- that "it would have hidden everything" is knowable while it can still be
    -- undone. See "The filter may narrow the window, never empty it" above.
    -- IsOtherZone still runs exactly once per quest per build, as it did when
    -- it was called inline in the drawing loop below.
    local elsewhereFlags = {}
    local zoneFilterDropped = false
    local zoneFilterEmpty = false
    if currentZoneKey then
        local candidates = 0
        local survivors = 0
        local scan = 1
        while scan <= total do
            local quest = quests[scan]
            local flag = IsOtherZone(quest, quest.zone, where)
            elsewhereFlags[scan] = flag
            -- A quest the player shift-clicked away is not evidence about the
            -- filter: it would be gone either way. Only the quests the filter
            -- alone decides about get a vote here.
            if not IsFolded(HIDDEN_QUESTS, quest.title or "") then
                candidates = candidates + 1
                if not flag then
                    survivors = survivors + 1
                end
            end
            scan = scan + 1
        end
        if candidates > 0 and survivors == 0 then
            -- Two outcomes, decided by whether the zone was identified at all
            -- rather than by how many quests survived. An identified zone that
            -- holds nothing to do is the filter working, and answering it by
            -- listing the whole log is the loudest possible way to be wrong.
            if PROVEN_ZONE_ROUTES[currentZoneHow or ""] then
                zoneFilterEmpty = true
            else
                zoneFilterDropped = true
                elsewhereFlags = {}
            end
        end
    end
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
        -- Untracked-and-hidden or somewhere else: both reach the same lazy
        -- header machinery below, so a zone filtered out entirely writes no
        -- header row either. Unstarted quests are not part of this filter:
        -- their title remains visible and only their objectives auto-fold.
        local elsewhere = elsewhereFlags[index] and true or false
        if currentZoneKey and not zoneFilterDropped and not elsewhere and zone
            and UQ.NameKey(zone) ~= currentZoneKey then
            -- Kept by the map rather than by its header. Counted only for
            -- /uq tracker, so a player asking why a Duskwood quest is in the
            -- window while they stand in Westfall gets an answer.
            mapKept = mapKept + 1
        end
        local hidden = IsFolded(HIDDEN_QUESTS, quest.title or "") or elsewhere

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
            -- Level-difficulty colour throughout, complete or not: it is the
            -- player's answer to "is this worth my time", and a quest does
            -- not stop being that level's quest the moment it is turned in.
            -- The complete state is carried by the icon below instead of by
            -- overwriting this colour to white.
            local red, green, blue = Client.GetQuestLevelColor(quest.level)
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
                following = mainQuest and mainQuest:IsMain(quest.titleKey) or false,
                questNumber = questNumbers[quest.titleKey],
            }
            -- These remain the fallback for a malformed/out-of-range number.
            -- The normal path draws the shared POI number and, for a complete
            -- quest, keeps this bundled icon as a small status mark beside it.
            if quest.isComplete == 1 then
                line.questRed, line.questGreen, line.questBlue = 1, 1, 1
                line.questTexture = Client.COMPLETE_QUEST_TEXTURE
            else
                line.questRed, line.questGreen, line.questBlue = UQ.GetQuestColor(quest)
            end
            if line.following then
                line.questRed, line.questGreen, line.questBlue = 1, 1, 1
                line.questTexture = Client.FOLLOWING_QUEST_TEXTURE
            end
            table.insert(lines, line)

            -- The automatic fold only decides for a quest the player has not
            -- decided for themselves. Reading it as `manual or automatic`
            -- instead would make the right-click below unusable on exactly the
            -- rows it folds: unfolding one would be overruled by the automatic
            -- answer on the very same redraw.
            local questFolded = FoldChoice(COLLAPSED_QUESTS, quest.title or "")
            if questFolded == nil then
                questFolded = ShouldAutoCollapseQuest(quest)
            end
            -- A complete quest is one title row and nothing else. Its
            -- objectives are all satisfied by definition, so neither they nor a
            -- separate "ready to turn in" line carry information -- they only
            -- make the window taller. The complete icon on the row is the
            -- whole status signal; the title keeps its level-difficulty
            -- colour.
            if showObjectives ~= "none" and not questFolded and quest.isComplete ~= 1
                and (showObjectives == "all" or tracked) then
                local objectives = quest.objectives or {}
                local objectiveIndex = 1
                local objectiveCount = table.getn(objectives)
                while objectiveIndex <= objectiveCount do
                    local objective = objectives[objectiveIndex]
                    if objective and type(objective.text) == "string" and objective.text ~= "" then
                        local progress = nil
                        if progressBars and type(objective.have) == "number"
                            and type(objective.need) == "number"
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

    -- One row rather than a blank body, so a correctly empty filter still
    -- reads as a filter and not as the addon having died. Written as an
    -- objective row because it is a plain indented line with no subject: the
    -- draw loop's else-branch already clears the row's subject and progress
    -- bar, so it needs no widget pool of its own.
    if zoneFilterEmpty and visibleTotal == 0 then
        AddLine(lines, "objective", UQ.L("TRACKER_ZONE_EMPTY"),
            COLOR_ZONE_EMPTY[1], COLOR_ZONE_EMPTY[2], COLOR_ZONE_EMPTY[3])
    end

    self.currentZoneArea = currentAreaId
    self.currentInstanceMap = currentInstanceMap
    self.mapKept = mapKept
    self.zoneFilterDropped = zoneFilterDropped
    self.zoneFilterEmpty = zoneFilterEmpty
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

local function MeasuredTrackerRowHeight(kind, row, text)
    local height = RowHeight(kind)
    local measuredHeight = Client.MeasureTrackerRowTextHeight(row, text)
    if type(measuredHeight) == "number"
        and math.ceil(measuredHeight) + WRAPPED_ROW_TEXT_PADDING > height then
        height = math.ceil(measuredHeight) + WRAPPED_ROW_TEXT_PADDING
    end
    return height
end

-- Returns the exact content height needed to draw through one line, using the
-- same row and inter-group spacing as Redraw. RevealQuest uses this to grow a
-- manually shortened window just far enough to show a quest's complete block.
local function HeightThroughLine(lines, stopIndex, window, width)
    local top = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING
    local previousKind = nil
    local measuredSlots = { quest = 1, objective = 1 }
    local index = 1
    while index <= stopIndex do
        local line = lines[index]
        local kind = line.kind
        if kind == "quest" and (previousKind == "quest" or previousKind == "objective") then
            top = top + QUEST_GROUP_GAP
        elseif kind == "zone" and previousKind ~= nil then
            top = top + ZONE_GROUP_GAP
        elseif kind == "objective" and previousKind == "objective" then
            top = top + OBJECTIVE_ROW_GAP
        end
        local height = RowHeight(kind)
        if (kind == "quest" or kind == "objective")
            and window and type(width) == "number" then
            local slot = measuredSlots[kind]
            local row = Client.GetTrackerRow(window, kind, slot)
            measuredSlots[kind] = slot + 1
            if row then
                local indent = kind == "quest" and QUEST_INDENT or OBJECTIVE_INDENT
                if kind == "quest" then
                    Client.SetTrackerRowFollowing(row, line.following)
                    if not Client.SetTrackerRowQuestNumber(row, line.questNumber,
                        line.following and true or false, line.quest and line.quest.isComplete == 1) then
                        Client.SetTrackerRowQuestMark(row,
                            line.questRed, line.questGreen, line.questBlue, line.questTexture)
                    end
                end
                Client.PlaceTrackerRow(row, window, indent, top, width, height)
                Client.SetTrackerRowText(row, line.text, line.red, line.green, line.blue)
                height = MeasuredTrackerRowHeight(kind, row, line.text)
                Client.HideObject(row)
            end
        end
        top = top + height
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
    table.insert(lines, {
        text = UQ.GetQuestDisplayTitle(quest) or "?", r = 1, g = 0.82, b = 0,
    })

    if type(quest.level) == "number" and quest.level > 0 then
        local red, green, blue = Client.GetQuestLevelColor(quest.level)
        table.insert(lines, {
            left = UQ.L("TOOLTIP_LEVEL"), right = tostring(quest.level),
            rightR = red, rightG = green, rightB = blue,
        })
    end
    if type(quest.zone) == "string" and quest.zone ~= "" then
        table.insert(lines, { left = UQ.L("TOOLTIP_ZONE"), right = quest.zone })
    end
    if type(quest.questTag) == "string" and quest.questTag ~= "" then
        table.insert(lines, { left = UQ.L("TOOLTIP_TYPE"), right = quest.questTag })
    end

    local watch = Watch()
    if watch and watch:IsTracked(quest) then
        table.insert(lines, {
            left = UQ.L("TOOLTIP_TRACKED"), right = UQ.L("COMMON_YES"),
            rightR = UQ.colors.accent[1], rightG = UQ.colors.accent[2], rightB = UQ.colors.accent[3],
        })
    end

    if quest.isComplete == 1 then
        table.insert(lines, {
            left = UQ.L("TOOLTIP_STATUS"), right = UQ.L("QUEST_STATUS_READY_TO_TURN_IN"),
            rightR = COLOR_COMPLETE[1], rightG = COLOR_COMPLETE[2], rightB = COLOR_COMPLETE[3],
        })
    else
        table.insert(lines, { left = UQ.L("TOOLTIP_STATUS"), right = UQ.L("QUEST_STATUS_IN_PROGRESS"),
            rightR = 1, rightG = 0.82, rightB = 0 })
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
    local shortcutTotal = table.getn(SHORTCUT_KEYS)
    while shortcutIndex <= shortcutTotal do
        table.insert(lines, { text = UQ.L(SHORTCUT_KEYS[shortcutIndex]),
            r = 0.6, g = 0.6, b = 0.6 })
        shortcutIndex = shortcutIndex + 1
    end
    if not Setting("trackerCurrentZoneOnly") then
        table.insert(lines, { text = UQ.L("TRACKER_HINT_MAP_CLICK"),
            r = 0.6, g = 0.6, b = 0.6 })
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
        -- Toggles what the player is actually looking at, which is the
        -- automatic answer when they have never folded this quest by hand.
        -- The stored state then decides for this quest until its next
        -- objective update, which drops it again (NoteProgress).
        local title = quest.title or ""
        local folded = FoldChoice(COLLAPSED_QUESTS, title)
        if folded == nil then
            folded = ShouldAutoCollapseQuest(quest)
        end
        SetFolded(COLLAPSED_QUESTS, title, not folded)
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
    if Client.IsAltKeyDown() then
        -- SelectQuestLogEntry is documented to clear the selection rather than
        -- error when handed a bad index, and the model's index can be one poll
        -- interval stale, so a miss is harmless.
        Client.SelectQuestLogEntry(quest.index)
        Client.OpenQuestLog()
        return
    end
    -- Plain left-click owns following. Keeping Quest Log opening on Alt
    -- prevents the follow gesture from also covering the screen with a panel.
    if UQ:IsFeatureEnabled("mainQuestWaypoint") then
        local clicks = UQ:GetModule("QuestClicks")
        if clicks then
            clicks:Select(quest, "trackerWindow")
        end
    end
    -- With the current-zone filter off, the tracker lists quests from every
    -- zone, so a click made over the fullscreen map also takes the map to the
    -- quest's zone -- the same Ctrl+click reveal. With the filter on, the list
    -- already follows the viewed map (CurrentZone above). Nothing is opened
    -- when the map is closed: the plain click must not cover the screen
    -- during play.
    if not Setting("trackerCurrentZoneOnly") and Client.IsGameUIHidden() == true then
        RevealQuestOnMap(quest)
    end
end

local function OnQuestRowEnter(row)
    local quest = row and row.unrealQuestSubject
    if not quest then
        return
    end
    local minimapPins = UQ:GetModule("MinimapPins")
    if minimapPins then
        minimapPins:SetHoveredQuest(quest)
    end
    -- The world map shows the quest as if its POI circle were hovered.
    local worldMapPins = UQ:GetModule("WorldMapPins")
    if worldMapPins then
        worldMapPins:SetExternalQuestHover(quest)
    end
    Client.ShowGameTooltip(row, BuildQuestTooltipLines(quest), "ANCHOR_RIGHT")
end

local function OnQuestRowLeave(row)
    local minimapPins = UQ:GetModule("MinimapPins")
    if minimapPins then
        minimapPins:SetHoveredQuest(nil)
    end
    local worldMapPins = UQ:GetModule("WorldMapPins")
    if worldMapPins then
        worldMapPins:SetExternalQuestHover(nil)
    end
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

local function SameQuest(first, second)
    if first == second then
        return true
    end
    return first and second and first.titleKey and second.titleKey
        and first.titleKey == second.titleKey
end

-- Map objectives and the two tracker copies are views of the same quest.
-- Keep the external hover separate from a row's
-- own OnEnter extension: the pin already owns the map tooltip, so replaying
-- the row handler would open a second tooltip and alter the minimap too.
local function RefreshWindowQuestHover(window, quest)
    local pools = window and window.unrealQuestRows
    local rows = pools and pools.quest
    local matched = false
    local index = 1
    local total = table.getn(rows or {})
    while index <= total do
        local row = rows[index]
        local hover = row and row.unrealQuestHover
        if hover then
            if quest and SameQuest(row.unrealQuestSubject, quest) then
                Client.ShowObject(hover)
                matched = true
            else
                Client.HideObject(hover)
            end
        end
        index = index + 1
    end
    return matched
end

function TrackerFrame:RefreshMapQuestHover()
    local hudMatched = RefreshWindowQuestHover(self.window, self.mapHoveredQuest)
    local mapMatched = RefreshWindowQuestHover(self.mapWindow, self.mapHoveredQuest)
    return hudMatched or mapMatched
end

function TrackerFrame:SetMapHoveredQuest(quest, owner)
    self.mapHoveredQuest = quest
    self.mapHoverOwner = quest and owner or nil
    return self:RefreshMapQuestHover()
end

function TrackerFrame:ClearMapHoveredQuest(owner)
    -- Adjacent pins can deliver the new OnEnter before the old OnLeave.  The
    -- old pin must not erase the newer row highlight in that ordering.
    if owner and self.mapHoverOwner and owner ~= self.mapHoverOwner then
        return false
    end
    self.mapHoveredQuest = nil
    self.mapHoverOwner = nil
    self:RefreshMapQuestHover()
    return true
end

-- The vertical space drawn above a row, given the kind drawn just before it
-- (nil at the top of the window or of a map page).
local function GapBefore(kind, previousKind)
    if kind == "quest" and (previousKind == "quest" or previousKind == "objective") then
        return QUEST_GROUP_GAP
    elseif kind == "zone" and previousKind ~= nil then
        return ZONE_GROUP_GAP
    elseif kind == "objective" and previousKind == "objective" then
        return OBJECTIVE_ROW_GAP
    end
    return 0
end

-- `fraction` of the height of the frame the window was created in, or nil when
-- that height cannot be read or leaves no room for a single row and the pager.
local function ParentShareHeight(window, fraction)
    local parentHeight = Client.GetTrackerParentHeight(window)
    if type(parentHeight) == "number" and parentHeight > 0 then
        local height = math.floor(parentHeight * fraction)
        if height > ROW_AREA_CHROME + Client.TRACKER_PAGER_HEIGHT then
            return height
        end
    end
    return nil
end

-- The map copy's height ceiling: its share of the map window, or the fixed
-- ceiling when the map's height cannot be read.
local function MapPageHeight(window)
    return ParentShareHeight(window, MAP_TRACKER_PAGE_FRACTION) or MAP_TRACKER_MAX_HEIGHT
end

-- The HUD window's page height: its share of the screen, or the resize
-- ceiling when UIParent's height cannot be read.
local function HudPageHeight(window)
    return ParentShareHeight(window, HUD_TRACKER_PAGE_FRACTION) or RESIZE_MAX_HEIGHT
end

-- Splits the rows RedrawWindow already placed and measured into pages that fit
-- above the page row, then shows only the current page. Pure positioning: every
-- text and height was settled by the first pass. A zone header left as the
-- last row of a page moves to the next one with the quest it introduces.
-- `revealTitle`, when given and listed, overrides `wantedPage` with the page
-- holding that quest's row.
-- Returns the page count, the page shown, and the followed row's plaque edges.
local function PaginateRows(window, placed, width, pageHeight, wantedPage, revealTitle)
    local start = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING
    local limit = pageHeight - BODY_PADDING - Client.TRACKER_PAGER_HEIGHT
    local page = 1
    local bottom = start
    local previousKind = nil
    local count = table.getn(placed)
    local index = 1
    while index <= count do
        local entry = placed[index]
        local top = bottom + GapBefore(entry.kind, previousKind)
        if previousKind ~= nil and top + entry.height > limit then
            page = page + 1
            top = start
            local before = placed[index - 1]
            if before and before.kind == "zone" and not before.first then
                before.page = page
                before.top = start
                before.first = true
                top = start + before.height + GapBefore(entry.kind, "zone")
            end
        end
        entry.first = top == start
        entry.page = page
        entry.top = top
        bottom = top + entry.height
        previousKind = entry.kind
        index = index + 1
    end

    local shown = wantedPage
    if revealTitle then
        index = 1
        while index <= count do
            local entry = placed[index]
            if entry.kind == "quest" and entry.title == revealTitle then
                shown = entry.page
                break
            end
            index = index + 1
        end
    end
    if type(shown) ~= "number" or shown < 1 then
        shown = 1
    elseif shown > page then
        shown = page
    end

    local followingTop = nil
    local followingBottom = nil
    index = 1
    while index <= count do
        local entry = placed[index]
        if entry.page == shown then
            Client.PlaceTrackerRow(entry.row, window, entry.indent, entry.top, width, entry.height)
            if entry.following then
                followingTop = entry.top - 2
                followingBottom = entry.top + entry.height + 2
            end
        else
            Client.HideObject(entry.row)
        end
        index = index + 1
    end
    return page, shown, followingTop, followingBottom
end

function TrackerFrame:TurnMapPage(delta)
    local page = (self.mapPage or 1) + delta
    if page < 1 or page > (self.mapPages or 1) then
        return false
    end
    self.mapPage = page
    if self.mapWindow and self.lines then
        self:RedrawWindow(self.mapWindow, self.lines,
            self.lastQuestCount or 0, self.lastCompleted or 0, true)
        self.mapDirty = false
        self.mapInitialized = true
    end
    return true
end

function TrackerFrame:TurnHudPage(delta)
    local page = (self.hudPage or 1) + delta
    if page < 1 or page > (self.hudPages or 1) then
        return false
    end
    self.hudPage = page
    if self.window and self.lines then
        self:RedrawWindow(self.window, self.lines,
            self.lastQuestCount or 0, self.lastCompleted or 0, false)
    end
    return true
end

function TrackerFrame:RedrawWindow(window, lines, questCount, completed, mapOwned)
    if not window then
        return
    end

    local width = mapOwned and MAP_TRACKER_WIDTH or Setting("trackerWidth")
    if type(width) ~= "number" or width < 110 then
        width = 170
    end

    -- The map copy always pages at its share of the map. The HUD one pages at
    -- its share of the screen unless a shorter saved resize height caps it
    -- first, in which case rows past that height are simply not drawn.
    local targetHeight
    local paged = false
    if mapOwned then
        targetHeight = MapPageHeight(window)
        paged = true
    else
        local pageHeight = HudPageHeight(window)
        targetHeight = Setting("trackerHeight")
        if type(targetHeight) ~= "number" or targetHeight <= ROW_AREA_CHROME
            or targetHeight >= pageHeight then
            targetHeight = pageHeight
            paged = true
        end
    end
    local resizing = not mapOwned and self.resizeStartX and true or false

    local total = table.getn(lines)
    self.totalLines = total

    local collapsed = Setting("trackerCollapsed") and true or false
    if collapsed then
        targetHeight = nil
        paged = false
    end

    Client.SetTrackerTitle(window, "UnrealQuest")
    Client.SetTrackerCount(window, completed .. "/" .. questCount)
    Client.SetTrackerCollapsed(window, collapsed)
    -- A folded window is a title bar only; there is nothing to resize.
    if not mapOwned and self.grip then
        if collapsed then
            Client.HideObject(self.grip)
        else
            Client.ShowObject(self.grip)
        end
    end

    local top = Client.TRACKER_HEADER_HEIGHT + BODY_PADDING
    local used = { zone = 1, quest = 1, objective = 1 }
    -- These describe only this redraw. Leaving them implicit made them Lua
    -- globals, so a redraw containing only the current-zone empty notice
    -- reused the last followed quest's block and left its gold glow visible.
    local followingTop = nil
    local followingBottom = nil
    local dotColors = Setting("mapObjectiveDots") and true or false
    -- Tracks what was drawn immediately before, so a gap can be inserted
    -- between one quest's block and the next without also pushing a quest
    -- away from the zone header that just introduced it.
    local previousKind = nil
    -- A paged window lays out every row, then pages them (PaginateRows)
    -- instead of stopping at its height ceiling.
    local placed = {}

    local index = 1
    while not collapsed and index <= total do
        local line = lines[index]
        local kind = line.kind
        top = top + GapBefore(kind, previousKind)
        local slot = used[kind] or 1
        local row = Client.GetTrackerRow(window, kind, slot)
        if row then
            local indent = RowIndent(kind)
            local height = RowHeight(kind)
            -- The number is set before the row is placed: it decides the
            -- label's left inset, and PlaceTrackerRow is what turns that inset
            -- into the label width the Fit() calls below measure against.
            if kind == "quest" then
                Client.SetTrackerRowFollowing(row, line.following)
                if not Client.SetTrackerRowQuestNumber(row, line.questNumber,
                    line.following and true or false, line.quest and line.quest.isComplete == 1) then
                    Client.SetTrackerRowQuestMark(row,
                        line.questRed, line.questGreen, line.questBlue, line.questTexture)
                end
            end
            Client.PlaceTrackerRow(row, window, indent, top, width, height)

            local rowWidth = row.unrealQuestTextWidth or row.unrealQuestWidth or (width - indent)
            local fitted
            if kind == "quest" or kind == "objective" then
                -- Keep the complete text. The client wraps it at spaces; its
                -- rendered height below advances every following row.
                fitted = line.text
            else
                fitted = Fit(line.text, rowWidth, OBJECTIVE_CHAR_WIDTH)
            end
            Client.SetTrackerRowText(row, fitted, line.red, line.green, line.blue)

            if kind == "quest" or kind == "objective" then
                height = MeasuredTrackerRowHeight(kind, row, fitted)
                if height > RowHeight(kind) then
                    Client.PlaceTrackerRow(row, window, indent, top, width, height)
                end
            end

            -- There is no scrolling: stop once this complete, dynamically
            -- measured row would pass the resized bottom edge.
            if not paged and targetHeight and top + height > targetHeight - BODY_PADDING then
                Client.HideObject(row)
                break
            end
            used[kind] = slot + 1
            if paged then
                table.insert(placed, { row = row, kind = kind, indent = indent,
                    height = height, following = line.following,
                    title = line.quest and line.quest.title })
            end

            if line.following then
                followingTop = top - 2
                followingBottom = top + height + 2
            end

            if kind == "quest" then
                row.unrealQuestSubject = line.quest
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
                Client.SetTrackerZoneFolded(row, IsFolded(COLLAPSED_ZONES, line.key or ""))
                if not row.unrealQuestBound then
                    row.unrealQuestBound = true
                    Client.SetTrackerRowClick(row, function() OnZoneRowClick(row) end)
                end
            else
                row.unrealQuestSubject = nil
                -- In dot mode an open objective wears its quest's map-dot
                -- colour, so the row and its dots on the map read as one.
                local dotRed, dotGreen, dotBlue = nil, nil, nil
                if dotColors and line.quest and not line.progressDone then
                    dotRed, dotGreen, dotBlue = UQ.GetQuestColor(line.quest)
                end
                Client.SetTrackerRowObjectiveMark(row,
                    line.quest and (line.progressDone and "done" or "open") or nil,
                    dotRed, dotGreen, dotBlue)
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

    local pages = 1
    local page = mapOwned and self.mapPage or self.hudPage
    if paged and top + BODY_PADDING > targetHeight then
        pages, page, followingTop, followingBottom =
            PaginateRows(window, placed, width, targetHeight, page,
                not mapOwned and self.hudRevealTitle or nil)
    end
    if pages <= 1 then
        page = 1
    end
    local pageText = UQ.L("TRACKER_MAP_PAGE", page, pages)
    if mapOwned then
        self.mapPage = page
        self.mapPages = pages
        Client.SetTrackerPager(self.mapPager, page, pages, pageText)
    else
        self.hudPage = page
        self.hudPages = pages
        self.hudRevealTitle = nil
        Client.SetTrackerPager(self.hudPager, page, pages, pageText,
            width - HUD_PAGER_SIDE_CLEARANCE * 2)
    end

    Client.SetTrackerFollowingBlock(window, followingTop, followingBottom,
        mapOwned and MAP_TRACKER_OPACITY or Setting("trackerBackgroundOpacity") or 55)

    if mapOwned then
        self:RefreshMapQuestHover()
    end

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
end

function TrackerFrame:Redraw(lines, questCount, completed, drawMap)
    -- Kept for turning the map copy's page without rebuilding the lines.
    self.lastQuestCount = questCount
    self.lastCompleted = completed
    self:RedrawWindow(self.window, lines, questCount, completed, false)
    if drawMap then
        self:RedrawWindow(self.mapWindow, lines, questCount, completed, true)
        self.mapDirty = false
        self.mapInitialized = true
    else
        self.mapDirty = true
    end
    self.redraws = self.redraws + 1
end

-- The map tracker's "Show all areas" toggle: shown only while the world map
-- draws areas, and checked from the setting, which the options page can also
-- change. Touches the widget only when either answer changes.
function TrackerFrame:SyncAreaToggle()
    if not self.areaToggle then
        return
    end
    local visible = Setting("mapObjectiveAreas") and true or false
    local checked = Setting("mapShowAllAreas") and true or false
    local key = tostring(visible) .. "|" .. tostring(checked)
    if key == self.areaToggleKey then
        return
    end
    self.areaToggleKey = key
    Client.SetTrackerAreaToggle(self.areaToggle, visible, checked)
end

-- Quest acceptance reaches this through QuestState's listener while the
-- shared driver is already scanning the log. Keep the exact reveal/layout
-- behavior, but fold it into the one scheduled tracker refresh instead of
-- building the full line list here and then building it again in Refresh.
function TrackerFrame:PreparePendingReveal(lines)
    local title = self.pendingRevealTitle
    if not title then
        return
    end
    self.pendingRevealTitle = nil

    local revealIndex = nil
    local index = 1
    local total = table.getn(lines)
    while index <= total do
        local line = lines[index]
        if line.quest and line.quest.title == title then
            revealIndex = index
        end
        index = index + 1
    end
    if not revealIndex then
        return
    end

    local targetHeight = Setting("trackerHeight")
    if type(targetHeight) == "number" and targetHeight > ROW_AREA_CHROME then
        local width = Setting("trackerWidth")
        if type(width) ~= "number" or width < 110 then
            width = 170
        end
        local requiredHeight = HeightThroughLine(
            lines, revealIndex, self.window, width)
        if requiredHeight > targetHeight then
            local config = Config()
            if config then
                if requiredHeight >= HudPageHeight(self.window) then
                    config:Set("trackerHeight", 0)
                else
                    config:Set("trackerHeight", requiredHeight)
                end
            end
        end
    end
    self.hudRevealTitle = title
end

-- Rebuilds the line list and redraws only when the rendered content changes.
function TrackerFrame:Refresh()
    local window = self.window
    if not window then
        return
    end
    if not Setting("trackerEnabled") then
        Client.HideObject(window)
        Client.HideObject(self.mapWindow)
        self.mapDirty = true
        self.mapInitialized = false
        return
    end

    self:CheckPositionOnScreen()
    self:SyncAreaToggle()

    local lines, questCount, completed = self:BuildLines()
    self:PreparePendingReveal(lines)
    local parts = { tostring(questCount), tostring(completed),
        Setting("trackerCollapsed") and "1" or "0", tostring(Setting("trackerWidth")),
        tostring(Setting("trackerHeight")),
        tostring(Client.GetTrackerParentHeight(window)),
        tostring(Client.GetTrackerParentHeight(self.mapWindow)),
        Setting("mapObjectiveDots") and "1" or "0" }
    local index = 1
    local total = table.getn(lines)
    while index <= total do
        local line = lines[index]
        table.insert(parts, line.kind .. ":" .. tostring(line.text)
            .. ":" .. tostring(line.tracked) .. ":" .. tostring(line.progress)
            .. ":" .. tostring(line.following) .. ":" .. tostring(line.questNumber))
        index = index + 1
    end
    local signature = table.concat(parts, "|")
    -- The map copy receives one initial layout so its first presentation is
    -- never blank. Afterwards, model changes while the game UI is visible
    -- update only the HUD copy; the map copy catches up from the same lines on
    -- the first tracker tick after the fullscreen map hides the game UI.
    local mapPresented = Client.IsGameUIHidden()
    if mapPresented ~= true then
        local trackerVisible = Client.IsObjectVisible(self.mapWindow)
        if trackerVisible ~= nil then
            mapPresented = trackerVisible
        end
    end
    local drawMap = not self.mapInitialized or mapPresented ~= false

    if not self.dirty and signature == self.signature then
        if drawMap and self.mapDirty then
            self:RedrawWindow(self.mapWindow, lines,
                questCount, completed, true)
            self.mapDirty = false
            self.mapInitialized = true
            Client.ShowObject(self.mapWindow)
        end
        return
    end
    self.dirty = false
    self.signature = signature
    self.lines = lines
    self:Redraw(lines, questCount, completed, drawMap)
    Client.ShowObject(window)
    if drawMap then
        Client.ShowObject(self.mapWindow)
    end
end

-- Refreshes after Tracker clears the quest and zone folds for a newly tracked
-- quest. A saved height is a ceiling, so grow it through the quest's final
-- objective before redrawing; past the HUD's page height the ceiling is
-- dropped instead and the window pages, opening on the quest's page. Both a
-- Track action and a newly accepted quest reach this method through
-- Tracker:Track.
function TrackerFrame:RevealQuest(quest)
    if not quest or not quest.title then
        return false
    end
    self.pendingRevealTitle = quest.title
    self.dirty = true
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Wake("tracker.frame")
    else
        self:Refresh()
    end
    return true
end

-- Position ----------------------------------------------------------------------

-- `atLoad` skips the screen guard. At OnInit the window has not been laid out
-- yet, so its edges say nothing about where it will be, and a guard "correction"
-- taken from them was saved over a good position: the tracker came back in
-- the top-left corner on every reload (user report 2026-09-18). The guard runs
-- once later instead, from Refresh (CheckPositionOnScreen).
function TrackerFrame:ApplyStoredPosition(atLoad)
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
    local applied, placedX, placedY, moved = Client.SetFrameAnchor(window, point,
        "UIParent", type(relativePoint) == "string" and relativePoint or point, x, y,
        atLoad)
    -- A stored position that left the window off screen was pulled back on;
    -- keep the corrected one so it opens there next time too.
    if applied and moved then
        Store("trackerX", placedX)
        Store("trackerY", placedY)
    end
    return applied
end

-- The deferred half of ApplyStoredPosition's screen guard: once per session,
-- a few seconds after enable, when the window has been drawn at its real size.
local POSITION_CHECK_DELAY = 3

function TrackerFrame:CheckPositionOnScreen()
    -- Never under a drag or a resize: re-applying the stored anchor then would
    -- yank the window out from under the cursor.
    if self.positionChecked or self.dragging or self.resizeStartX then
        return
    end
    local now = Client.Now()
    if not now then
        return
    end
    if not self.positionCheckAt then
        self.positionCheckAt = now + POSITION_CHECK_DELAY
        return
    end
    if now < self.positionCheckAt then
        return
    end
    self.positionChecked = true
    self:ApplyStoredPosition()
end

function TrackerFrame:CapturePosition()
    local window = self.window
    if not window then
        return false
    end
    local point, relativeName, relativePoint, x, y = Client.GetFrameAnchor(window)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        UQ:Warn(UQ.L("TRACKER_WARN_NO_POSITION"))
        return false
    end
    -- relativeName is read but not stored. Anything the drag left the window
    -- anchored to is normalized to UIParent on the way back in, which is what
    -- makes the stored pair of numbers meaningful across sessions.
    Store("trackerPoint", point)
    Store("trackerRelativePoint", type(relativePoint) == "string" and relativePoint or point)
    Store("trackerX", x)
    Store("trackerY", y)
    -- Re-placed from what was just stored, so a drop past a screen edge snaps
    -- flush with it, as the navigator does (Client.KeepFrameOnScreen).
    self:ApplyStoredPosition()
    return true
end

function TrackerFrame:ResetPosition()
    Store("trackerPoint", "TOPRIGHT")
    Store("trackerRelativePoint", "TOPRIGHT")
    Store("trackerX", -20)
    Store("trackerY", -240)
    Store("trackerHeight", 0)
    Store("mapTrackerX", MAP_TRACKER_DEFAULT_X)
    Store("mapTrackerY", MAP_TRACKER_DEFAULT_Y)
    self.dirty = true
    self:ApplyStoredPosition()
    self:ApplyMapPosition()
end

-- The map copy ------------------------------------------------------------------
--
-- Dragged by its header, but not with StartMoving: the window is a child of
-- WorldMapFrame, which runs at scale 0.5 and whose edge coordinates mix two
-- spaces (frames.scaled_frame_edge_coordinates_mixed_space), so neither the
-- anchor StartMoving would leave nor GetFrameAnchor's edge measurement can be
-- trusted there. Instead the cursor's movement since the drag began, read in
-- the window's own units (Client.GetCursorInObjectUnits), is added to the
-- TOPRIGHT offsets the drag started from and applied on the shared driver.
-- The offsets are the only thing stored and the only thing ever read back, so
-- what the player sees mid-drag is exactly what comes back next time.
--
-- Releasing the mouse must end the drag, always. A first version moved the
-- window with its handle still riding on it, so every tick re-anchored the
-- frame the client was dragging; the client then drops the drag and its
-- OnDragStop (widgets.thumb_reposition_during_drag_breaks_drag), and the
-- window kept following the cursor after release (user report 2026-09-27).
-- unrealUI's mover hit the same thing more than once. The shape now is its
-- fix: for the length of the drag the handle is detached from the window
-- (Client.DetachTrackerHandle) and moved natively under the cursor by the
-- verified StartMoving recipe, and nothing ever re-anchors it; only the
-- visible window moves by SetPoint. The release then has every route there
-- is, and StopMapDrag is idempotent so receiving several is harmless:
--   * the handle's OnDragStop, OnMouseUp and OnClick;
--   * the map closing (the window no longer visible) on the driver tick;
--   * IsMouseButtonDown reporting the button up, where the client has it
--     (Client.IsLeftMouseButtonHeld -- unrecorded, so best effort only).

-- Keeps the title line on the map: the window's full width inside its left
-- and right edges, its header inside its top and bottom. Map and window share
-- one space (the window is a scale-1 child), and only GetWidth/GetHeight are
-- read, which are sign- and scale-safe. Unread sizes leave the offsets alone.
local function ClampMapOffsets(window, x, y)
    local map = window and window.unrealQuestParent
    local mapWidth = Client.GetObjectWidth(map)
    local mapHeight = Client.GetObjectHeight(map)
    local width = Client.GetObjectWidth(window) or 0
    if mapWidth and mapWidth > width then
        if x > 0 then
            x = 0
        elseif x < width - mapWidth then
            x = width - mapWidth
        end
    end
    if mapHeight and mapHeight > Client.TRACKER_HEADER_HEIGHT then
        if y > 0 then
            y = 0
        elseif y < Client.TRACKER_HEADER_HEIGHT - mapHeight then
            y = Client.TRACKER_HEADER_HEIGHT - mapHeight
        end
    end
    return x, y
end

-- Places the map copy at (x, y), or at its stored offsets. Never stores:
-- only a finished drag does, so a placement made before the map has been
-- laid out cannot overwrite a good position (the HUD copy's reload lesson).
function TrackerFrame:ApplyMapPosition(x, y)
    local window = self.mapWindow
    if not window then
        return false
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        x = Setting("mapTrackerX")
        y = Setting("mapTrackerY")
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        x, y = MAP_TRACKER_DEFAULT_X, MAP_TRACKER_DEFAULT_Y
    end
    return Client.SetFrameAnchor(window, "TOPRIGHT", "WorldMapFrame", "TOPRIGHT", x, y) and true
        or false
end

function TrackerFrame:StartMapDrag()
    local window = self.mapWindow
    local handle = self.mapHandle
    if not window or not handle then
        return false
    end
    -- A drag still open from a lost release is closed before a new one.
    self:StopMapDrag()
    local cursorX, cursorY = Client.GetCursorInObjectUnits(window)
    if not cursorX then
        return false
    end
    local x = Setting("mapTrackerX")
    local y = Setting("mapTrackerY")
    if type(x) ~= "number" or type(y) ~= "number" then
        x, y = MAP_TRACKER_DEFAULT_X, MAP_TRACKER_DEFAULT_Y
    end
    self.mapDrag = { cursorX = cursorX, cursorY = cursorY,
        startX = x, startY = y, x = x, y = y }
    self.mapDrags = self.mapDrags + 1
    -- Pinned where it is, then carried by the client's own move. If either
    -- is refused the drag still runs: every release route below the handle's
    -- own callbacks still ends it.
    if Client.DetachTrackerHandle(handle, "WorldMapFrame", x, y) then
        self.mapDrag.detached = true
        self.mapDrag.moving = Client.StartFrameDrag(handle)
    end
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("tracker.mapdrag", 0.02, function() TrackerFrame:UpdateMapDrag() end)
    end
    return true
end

function TrackerFrame:UpdateMapDrag()
    local drag = self.mapDrag
    local window = self.mapWindow
    if not drag or not window then
        return
    end
    -- The map closed under the drag, or the client says the button is up:
    -- either way no release callback is coming, so the drag ends here with
    -- the last place it reached.
    if not Client.IsObjectVisible(window) or Client.IsLeftMouseButtonHeld() == false then
        self:StopMapDrag()
        return
    end
    self:FollowMapDragCursor(drag)
end

-- Moves the window to where the cursor has taken the drag. Only ever moves;
-- never decides that the drag is over, so StopMapDrag can call it too.
function TrackerFrame:FollowMapDragCursor(drag)
    local window = self.mapWindow
    local cursorX, cursorY = Client.GetCursorInObjectUnits(window)
    if not cursorX then
        return
    end
    local x, y = ClampMapOffsets(window,
        drag.startX + (cursorX - drag.cursorX), drag.startY + (cursorY - drag.cursorY))
    if x == drag.x and y == drag.y then
        return
    end
    drag.x = x
    drag.y = y
    self:ApplyMapPosition(x, y)
end

function TrackerFrame:StopMapDrag()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Unschedule("tracker.mapdrag")
    end
    local drag = self.mapDrag
    if not drag then
        return
    end
    -- Cleared first, so nothing below can re-enter a drag that is ending.
    self.mapDrag = nil
    -- The release point itself, not the last tick's: a release on OnMouseUp
    -- can come up to one tick after the cursor last moved the window.
    if Client.IsObjectVisible(self.mapWindow) then
        self:FollowMapDragCursor(drag)
    end
    local handle = self.mapHandle
    if drag.moving then
        Client.StopFrameDrag(handle)
    end
    if drag.detached then
        Client.AttachTrackerHandle(handle, self.mapWindow)
    end
    Store("mapTrackerX", drag.x)
    Store("mapTrackerY", drag.y)
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

    -- No taller than the HUD's page height: past it the window pages rather
    -- than grows, so dragging further would only open blank space.
    local maxHeight = HudPageHeight(self.window)
    if maxHeight > RESIZE_MAX_HEIGHT then
        maxHeight = RESIZE_MAX_HEIGHT
    end
    local height = self.resizeStartHeight - (gripY - self.resizeStartY)
    if height < RESIZE_MIN_HEIGHT then
        height = RESIZE_MIN_HEIGHT
    elseif height > maxHeight then
        height = maxHeight
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
        Client.HideObject(self.mapWindow)
        self.mapDirty = true
        self.mapInitialized = false
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

-- The one question the OnShow guard installed below asks, on every show the
-- client performs: does the player still want the native panel gone? It reads
-- live settings rather than a captured value because the guard outlives any
-- particular answer -- a script cannot be detached on this client.
local function NativeWatchShouldHide()
    return (Setting("trackerHideNativeWatch") and Setting("trackerEnabled")) and true or false
end

-- The native five-quest panel is hidden only while this window is actually
-- up and the setting asks for it; every other combination shows it again, so
-- turning the tracker off never leaves the player with no tracker at all.
function TrackerFrame:ApplyNativeWatchVisibility()
    local hide = Setting("trackerHideNativeWatch") and true or false
    local enabled = Setting("trackerEnabled") and true or false
    -- The Hide below only answers for this moment. The client re-shows the
    -- panel on its own whenever it refreshes the watch list -- accepting a
    -- quest is the case a player notices -- so without a guard the panel
    -- flashes on and stays up until the next re-hide sweep. Installing it here
    -- (idempotent, and inert whenever this function would show the panel
    -- anyway) means it is in place before the first quest is accepted.
    Client.InstallNativeQuestWatchGuard(NativeWatchShouldHide)
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
        currentZoneOnly = Setting("trackerCurrentZoneOnly") and true or false,
        recentFirst = Setting("trackerRecentFirst") and true or false,
        currentZoneArea = self.currentZoneArea,
        currentZoneName = self.currentZoneName,
        currentZoneHow = self.currentZoneHow,
        currentInstanceMap = self.currentInstanceMap,
        mapKept = self.mapKept,
        zoneFilterDropped = self.zoneFilterDropped and true or false,
        zoneFilterEmpty = self.zoneFilterEmpty and true or false,
        hideUnstarted = Setting("trackerHideUnstartedQuests") and true or false,
        hideNativeWatch = Setting("trackerHideNativeWatch") and true or false,
        lines = self.totalLines,
        page = self.hudPage,
        pages = self.hudPages,
        redraws = self.redraws,
        clicks = self.clicks,
        drags = self.drags,
        dragFailures = self.dragFailures,
        resizes = self.resizes,
        point = Setting("trackerPoint"),
        x = Setting("trackerX"),
        y = Setting("trackerY"),
        mapDrags = self.mapDrags,
        mapX = Setting("mapTrackerX"),
        mapY = Setting("mapTrackerY"),
    }
end

-- Lifecycle -----------------------------------------------------------------------

function TrackerFrame:OnInit()
    local window = Client.CreateTrackerWindow(WINDOW_NAME)
    if not window then
        UQ:Warn(UQ.L("TRACKER_WARN_NO_WINDOW"))
        return
    end
    self.window = window

    local mapWindow = Client.CreateTrackerWindow(
        MAP_WINDOW_NAME, "WorldMapFrame", true)
    if mapWindow then
        self.mapWindow = mapWindow
    end
    self:ApplyBackgroundOpacity()

    local handle = Client.CreateTrackerHandle(window, HANDLE_NAME)
    if handle then
        self.handle = handle
        Client.SetObjectScript(handle, "OnDragStart", function()
            if Client.StartFrameDrag(window) then
                TrackerFrame.dragging = true
                TrackerFrame.drags = TrackerFrame.drags + 1
            else
                TrackerFrame.dragFailures = TrackerFrame.dragFailures + 1
                -- Visible, not debug-only. A drag that silently does nothing is
                -- the exact failure mode this client already produced once.
                UQ:Warn(UQ.L("TRACKER_WARN_DRAG_FAILED"))
            end
        end)
        -- OnMouseUp is a second release route, as on the map copy: a drop the
        -- client does not report through OnDragStop must still let go of the
        -- window. Gated on `dragging`, so a plain click on the header, or the
        -- mouse-up that follows OnDragStop, does nothing.
        local function release()
            if not TrackerFrame.dragging then
                return
            end
            Client.StopFrameDrag(window)
            TrackerFrame.dragging = false
            TrackerFrame:CapturePosition()
        end
        Client.SetObjectScript(handle, "OnDragStop", release)
        Client.SetObjectScript(handle, "OnMouseUp", release)
    else
        UQ:Warn(UQ.L("TRACKER_WARN_NO_HANDLE"))
    end

    local grip = Client.CreateTrackerResizeGrip(window, GRIP_NAME)
    if grip then
        self.grip = grip
        Client.SetObjectScript(grip, "OnDragStart", function()
            if not TrackerFrame:StartResize() then
                UQ:Warn(UQ.L("TRACKER_WARN_RESIZE_FAILED"))
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
        UQ:Warn(UQ.L("TRACKER_WARN_NO_GRIP"))
    end

    Client.SetTrackerHeaderButtons(window,
        function()
            local npcPins = UQ:GetModule("NpcPins")
            if npcPins then
                npcPins:ToggleMenu(window.unrealQuestNpcFinder)
            end
        end,
        function() TrackerFrame:ToggleCollapsed() end)
    self.hudPager = Client.CreateTrackerPager(window,
        function() TrackerFrame:TurnHudPage(-1) end,
        function() TrackerFrame:TurnHudPage(1) end)

    if mapWindow then
        -- Created before the "Show all areas" toggle, which is raised above
        -- it (Client.CreateTrackerAreaToggle) so the title line drags
        -- everywhere except on that checkbox.
        local mapHandle = Client.CreateTrackerHandle(mapWindow, MAP_HANDLE_NAME)
        if mapHandle then
            self.mapHandle = mapHandle
            Client.SetObjectScript(mapHandle, "OnDragStart", function()
                if not TrackerFrame:StartMapDrag() then
                    TrackerFrame.dragFailures = TrackerFrame.dragFailures + 1
                    UQ:Warn(UQ.L("TRACKER_WARN_DRAG_FAILED"))
                end
            end)
            -- Every release route the handle has (see "The map copy"):
            -- StopMapDrag is idempotent, so the second and third are no-ops.
            local function release()
                TrackerFrame:StopMapDrag()
            end
            Client.SetObjectScript(mapHandle, "OnDragStop", release)
            Client.SetObjectScript(mapHandle, "OnMouseUp", release)
            Client.SetObjectScript(mapHandle, "OnClick", release)
        end
        self:ApplyMapPosition()

        -- No NPC finder here: its place on the title line holds the "Show
        -- all areas" toggle instead. It writes the setting the options page
        -- does; the world map's view signature carries it, so the map rebuilds
        -- on its next refresh.
        Client.SetTrackerHeaderButtons(mapWindow, nil,
            function() TrackerFrame:ToggleCollapsed() end)
        self.areaToggle = Client.CreateTrackerAreaToggle(mapWindow,
            UQ.L("TRACKER_MAP_ALL_AREAS"),
            function(checked)
                local config = UQ:GetModule("Config")
                if config then
                    config:Set("mapShowAllAreas", checked and true or false)
                end
            end)
        self.mapPager = Client.CreateTrackerPager(mapWindow,
            function() TrackerFrame:TurnMapPage(-1) end,
            function() TrackerFrame:TurnMapPage(1) end)
    end

    if not self:ApplyStoredPosition(true) then
        self:ResetPosition()
    end
end

-- Changes only the background texture, so the tracker text, progress bars and
-- controls stay fully opaque. Called directly by the settings slider while it
-- moves; no redraw is needed because the texture already exists. The slider
-- drives the HUD window only; the map copy keeps MAP_TRACKER_OPACITY.
function TrackerFrame:ApplyBackgroundOpacity(percent)
    if type(percent) ~= "number" then
        percent = Setting("trackerBackgroundOpacity")
    end
    local applied = Client.SetTrackerBackgroundOpacity(self.window, percent or 55)
    if self.mapWindow then
        Client.SetTrackerBackgroundOpacity(self.mapWindow, MAP_TRACKER_OPACITY)
    end
    return applied
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


    local mainQuest = MainQuest()
    if mainQuest then
        mainQuest:AddListener(function()
            TrackerFrame.dirty = true
            local d = UQ:GetModule("Driver")
            if d then
                d:Wake("tracker.frame")
            end
        end)
    end

    self:ApplyNativeWatchVisibility()
    self:Refresh()
end

TrackerFrame.Fit = Fit
TrackerFrame.FitQuest = FitQuest
TrackerFrame.FitObjective = FitObjective
