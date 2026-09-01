--[[
UnrealQuest / Quest/QuestLogLevels.lua

The quest's level in front of its name on the native quest log rows --
"[24] Weapons of Choice" instead of "Weapons of Choice" -- which this client
does not draw on its own, and which the tracker window has always shown
(Quest/TrackerFrame.lua QuestLabel builds the same "[level] " prefix).

## Why the displayed text and never GetQuestLogTitle

The obvious implementation, and the one CT_QuestLevels-style addons use, is to
wrap the GetQuestLogTitle global so every reader sees a decorated title. This
module deliberately does not: the title is the ONLY join this addon has
between a quest log row and the bundled database (this client has no quest ID
API), so a decorated return value makes every quest resolve "unmatched" and
empties the map layer, the minimap layer and the waypoint. That is a
reproduced failure, not a worry -- see the long comment above
Client.CleanQuestTitle in Compatibility/ClientAPI.lua, which exists to defend
against exactly this when another addon does it.

So the decoration -- and, when enabled, the database-backed display title --
is written onto the row widget's own text and nowhere else.
Client.GetQuestLogEntry keeps returning the clean title, every matcher keeps
working, and the two row-text fallbacks that do exist
(Quest/QuestLogTracking.lua QuestFromText, Quest/QuestClicks.lua QuestFromText)
match a quest title as a SUFFIX of the row's normalized text, so a "[24] "
prefix in front of it changes no click either.

## Re-applied on a poll, not on an event

The client's own QuestLog_Update rewrites every row's text whenever the list
is refreshed, scrolled or a quest is selected, which wipes the prefix. Nothing
here waits for an event to tell it that happened (events are accelerators,
never the mechanism): the shared driver re-decorates the visible rows on the
same 0.2s cadence Quest/QuestLogTracking.lua already uses for its track marks,
and only while QuestLogFrame is shown.

## What the pass refuses to do

Every write is idempotent and fails closed:

  * A row whose text already reads as the level-prefixed title is left alone,
    so a client or an addon that decorates first can never be doubled up.
  * The row's leading indent is split off and put back in front. Stock
    FrameXML indents a quest row under its zone header by writing the spaces
    into the text itself ("  Kobold Camp Cleanup"), so a prefix built without
    them would silently un-indent the whole list.
  * A leading colour escape is split off the same way, so a skinned row keeps
    its colour and the bracket lands inside it rather than in front of the
    "|cff..." sequence.
  * The row's stamped quest log index is verified against the row's own text
    before anything is written -- if the row does not carry the title the
    index claims (a stale row mid-refresh, or a skin that rewrote it), the row
    is skipped rather than stamped with someone else's level.
  * Header rows and any row whose level is not a positive number get nothing.

No player-facing string is added: brackets and a number are not translatable,
which is why the tracker hardcodes the same format.

## The row's colour, on uUI's Modern surface only

The stock quest log tints each row by how hard its quest is. This client
cannot: GetDifficultyColor does not exist here and no addon-side shim reaches
the native call site (knowledge.json core.getdifficultycolor_missing), so the
rows arrive uncoloured, and uUI's Modern theme then paints all of them one
uniform bright colour on every one of its font passes. This module gives the
familiar red/orange/yellow/green/grey bands back to the row's own name, in the
same pass and at the same cadence as the level prefix -- the two are the same
fact about the same row, and writing them apart would show the list changing
twice after every refresh.

It is deliberately limited to that surface. The classic and standalone logs
are left with whatever colour they already carry, since nothing there is
repainting the rows, and a row that leaves the modern surface (or stops being
a quest row at all) is handed back the colour it had before the first tint --
see Client.SetQuestLogRowTitleColor in Compatibility/ClientAPI.lua. The colour
itself is Client.GetQuestLevelColor, already used by the tracker window and
the map layer, so all three surfaces cannot disagree about a quest's level.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestLogLevels = UQ:NewModule("QuestLogLevels")

local MAX_LOG_ROWS = 30
local POLL_INTERVAL = 0.2

-- How many rows this pass wrote a prefix onto, for /uq status debugging.
QuestLogLevels.decorated = 0
-- Last exact text this module wrote to each recycled native row. It lets a
-- language change safely replace its own previous translation while the row's
-- stamped quest-log index remains the authoritative identity.
QuestLogLevels.renderedRows = {}

-- Splits off everything that has to stay in front of the prefix -- the row's
-- indent, then a colour escape if there is one -- and returns it together
-- with the rest of the text.
local function SplitLeadIn(text)
    local lead = ""
    local rest = text
    local _, _, indent, afterIndent = string.find(rest, "^(%s+)(.*)$")
    if indent then
        lead = indent
        rest = afterIndent
    end
    local _, _, escape, afterEscape = string.find(rest, "^(|c%x%x%x%x%x%x%x%x)(.*)$")
    if escape then
        lead = lead .. escape
        rest = afterEscape
    end
    return lead, rest
end

-- Removes level prefixes already present: "[24] ", "[24+] ", "[15G5] ". The
-- leading-digit requirement is the same one Client.CleanQuestTitle uses, and
-- for the same reason -- a real quest title may start with a bracket group,
-- but never with a digit inside it. Bounded rather than "until it stops
-- changing", so a pathological title cannot spin here.
local function StripLevelPrefix(text)
    local cleaned = text
    local rounds = 0
    while rounds < 3 do
        local stripped = string.gsub(cleaned, "^%s*%[%d[^%]]*%]%s*", "", 1)
        if stripped == cleaned then
            break
        end
        cleaned = stripped
        rounds = rounds + 1
    end
    return cleaned
end

-- True when the row really is showing the quest its stamped index claims.
-- Compared as normalized keys and by containment, not equality: the row text
-- may still carry a trailing "|r" or a skin's own additions, and the title
-- key is alphanumeric by construction so it carries no pattern magic.
local function RowCarriesTitle(rowText, title)
    local rowKey = UQ.NameKey(rowText)
    local titleKey = UQ.NameKey(title)
    if not rowKey or not titleKey then
        return false
    end
    return string.find(rowKey, titleKey, 1, true) and true or false
end

local function DecorateRow(row)
    local text = Client.GetObjectText(row)
    if not text then
        return false
    end
    local questIndex = Client.GetFrameId(row)
    if not questIndex then
        return false
    end
    local title, level, _, isHeader = Client.GetQuestLogEntry(questIndex)
    if not title or isHeader then
        return false
    end
    if type(level) ~= "number" or level <= 0 then
        return false
    end

    local quest = nil
    local state = UQ:GetModule("QuestState")
    if state then
        quest = state:GetQuestByTitle(title)
    end
    local displayTitle = UQ.GetQuestDisplayTitle(quest or { title = title }, title) or title

    local lead, rest = SplitLeadIn(text)
    local bare = StripLevelPrefix(rest)
    local previous = QuestLogLevels.renderedRows[row]
    local isOwnText = previous and previous.questIndex == questIndex
        and previous.text == text
    if not isOwnText and not RowCarriesTitle(bare, title)
        and not RowCarriesTitle(bare, displayTitle) then
        return false
    end

    -- Keep only what followed the title (normally a colour reset or a skin's
    -- marker), never the old title itself. For our own previous rendering the
    -- saved suffix avoids having to recognize a title from another language.
    local suffix = isOwnText and (previous.suffix or "") or ""
    if not isOwnText then
        local startAt, endAt = string.find(bare, title, 1, true)
        if not startAt then
            startAt, endAt = string.find(bare, displayTitle, 1, true)
        end
        if startAt then
            suffix = string.sub(bare, endAt + 1)
        end
    end

    local decorated = lead .. "[" .. level .. "] " .. displayTitle .. suffix
    if decorated == text then
        -- Already correct, whoever wrote it. Writing it again every 0.2s
        -- would be the only thing here that could make the list flicker.
        QuestLogLevels.renderedRows[row] = {
            questIndex = questIndex, text = text, suffix = suffix,
        }
        return true
    end
    if Client.SetNativeObjectText(row, decorated) then
        QuestLogLevels.renderedRows[row] = {
            questIndex = questIndex, text = decorated, suffix = suffix,
        }
        return true
    end
    return false
end

-- Reads the level off the row's own stamped quest log index, the same join
-- DecorateRow uses. A row that is not a levelled quest row on the modern
-- surface -- a header, a hidden pooled row, or any row at all while the host
-- is not modern -- gets its original colour back instead of a band.
local function ColorRow(row, modern)
    if not modern or not Client.IsObjectShown(row) then
        return Client.SetQuestLogRowTitleColor(row)
    end
    local questIndex = Client.GetFrameId(row)
    local title, level, _, isHeader
    if questIndex then
        title, level, _, isHeader = Client.GetQuestLogEntry(questIndex)
    end
    if not title or isHeader or type(level) ~= "number" or level <= 0 then
        return Client.SetQuestLogRowTitleColor(row)
    end
    local red, green, blue = Client.GetQuestLevelColor(level)
    return Client.SetQuestLogRowTitleColor(row, red, green, blue)
end

function QuestLogLevels:Refresh()
    local log = Client.GetNamedObject("QuestLogFrame")
    if not log or not Client.IsObjectShown(log) then
        return
    end

    -- Resolved once per pass, not once per row: it is two frame lookups, and
    -- every row on screen belongs to the same surface anyway.
    local modern = Client.HasModernQuestLog()
    local decorated = 0
    local rowIndex = 1
    local misses = 0
    while rowIndex <= MAX_LOG_ROWS and misses < 3 do
        local row = Client.GetNamedObject("QuestLogTitle" .. tostring(rowIndex))
        if not row then
            misses = misses + 1
        else
            misses = 0
            ColorRow(row, modern)
            if Client.IsObjectShown(row) and DecorateRow(row) then
                decorated = decorated + 1
            end
        end
        rowIndex = rowIndex + 1
    end
    self.decorated = decorated
end

function QuestLogLevels:OnInit()
    UQ:DeclareCapability("questLogLevels", "unverified",
        "The rows exist (/urp interface QuestLogFrame, BEHAVIOR_VERIFIED, capturedAt 2026-08-23, "
        .. "lists QuestLogTitle1..6 as Buttons) and GetQuestLogTitle returns the level in "
        .. "position two, but writing the prefix back onto a stock row's own FontString needs "
        .. "one in-game visual confirmation")
end

function QuestLogLevels:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    self:Refresh()
    driver:Schedule("questlog.levels", POLL_INTERVAL, function()
        QuestLogLevels:Refresh()
    end)
end
