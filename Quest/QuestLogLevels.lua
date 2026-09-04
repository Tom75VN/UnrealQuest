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

## Which quest a row is showing: the offset, not the stamped ID

The list is a FauxScrollFrame. The row widgets never move; the client refills
row N from quest log entry N + offset. A row's stamped ID says the same thing
only for as long as something keeps restamping it, and at the top of an
unscrolled list the two are identical -- so a join through GetID alone works
perfectly until the moment the list is first scrolled, and then points every
row at a quest the player is not looking at. That is exactly what
USER_CONFIRMED_INGAME as "the level disappears when I scroll": with the index
naming the wrong quest, the title check below rejects every row and the whole
visible list goes bare rather than wrong.

So Client.GetQuestLogRowQuestIndex offers both -- the scrolled index first,
the stamped ID second -- and neither is taken on faith: a candidate is used
only when the row is already carrying that quest's title. Whichever of the two
the client keeps correct, the row is decorated from it, and if neither agrees
with the row the row is left alone. unrealUI's own quest log derives the index
from the offset the same way on this client, and never from GetID.

## The canary, so a scroll never shows a bare list

That 0.2s is the correctness mechanism, and on its own it is also 0.2s of
undecorated rows after every rewrite. A click already avoids that: the
shift-click chain in Quest/QuestLogTracking.lua reapplies the prefix and the
track mark inside the same click. Scrolling had no such path, and scrolling is
continuous -- USER_CONFIRMED_INGAME the levels were simply gone from the list
for as long as the wheel kept turning.

So one row is watched every driver tick: the first row this module decorated,
together with the exact text it left there. A native rewrite rewrites EVERY
row, so that one row no longer matching is proof the whole page needs doing
again -- one GetText per tick, no event, and no assumption about which client
call did the rewriting. The poll stays exactly as it was underneath it; the
watch only decides that the next pass happens now instead of within 0.2s.

The other two row presentations are reapplied in the same tick, because the
rewrite that wiped the prefix also moved every quest to a different row: the
track mark (Quest/QuestLogTracking.lua) and the followed-quest plaque
(Quest/QuestLogButtons.lua) would otherwise sit on the wrong quest until their
own polls came round. That is the same pairing the shift-click chain makes.

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
  * The quest log index the row is showing is verified against the row's own
    text before anything is written -- if the row does not carry the title the
    index claims (a stale row mid-refresh, or a skin that rewrote it), the row
    is skipped rather than stamped with someone else's level. See below for
    why there are two candidate indices and not one.
  * Header rows and any row whose level is not a positive number get nothing.

No player-facing string is added: brackets and a number are not translatable,
which is why the tracker hardcodes the same format.

## The party count in front of the level

In a party the row reads "[1] [24] Weapons of Choice", the count greyed: how
many OTHER members of the party are on that same quest, then the level, then
the name.

The count is worked out here, through Client.GetQuestLogPartyCount, which asks
the client's own IsUnitOnQuest about each party member -- so it is the client's
answer about the real party, not an addon-to-addon sync, and a member who does
not run this addon is counted exactly like one who does.

The client draws that same count itself, on QuestLogTitle<N>GroupMates, and
that copy is hidden (Client.SetQuestLogRowPartyTagHidden). It has to be: the
client puts it in the row's left gutter at x=8, which is where this module's
own presentation already lives. Written into the text instead, the count cannot
drift from the level it sits in front of, because the two are one string.

Which widget that is was measured, not guessed -- probe questloggrouptag, see
docs/CLIENT-COMPATIBILITY.md. It is not the row's Tag FontString, which is what
the first attempt hid, to no effect.

It is greyed with an inline |cff888888 escape rather than by tinting a widget,
for the same reason: it is part of a string, so it takes its colour the way a
string does. The escape is closed with |r before the rest of the title, so a
skin's own colour on the row still applies to the title and not to the count --
which is why SplitLeadIn hands the indent and the escape back separately, with
the count belonging between them.

StripLevelPrefix already removes any number of leading bracketed groups, so
nothing here doubles up.

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
-- |cff888888, the grey every subdued line in this addon already uses. Not a
-- player-facing string: it is a colour escape, and the count itself is
-- brackets and a number, which is why the level prefix beside it is hardcoded
-- the same way.
local PARTY_COUNT_COLOR = "|cff888888"
local POLL_INTERVAL = 0.2
-- 0 is every driver tick. The watch itself is one GetText and one string
-- compare; the full pass it triggers is the same one the poll runs.
local WATCH_INTERVAL = 0

-- How many rows this pass wrote a prefix onto, for /uq status debugging.
QuestLogLevels.decorated = 0
-- The watched row, the exact text the last pass left on it, and how many
-- native rewrites that watch has caught. See "The canary" above.
QuestLogLevels.canaryRow = nil
QuestLogLevels.canaryText = nil
QuestLogLevels.rewrites = 0
-- Last exact text this module wrote to each recycled native row. It lets a
-- language change safely replace its own previous translation while the row's
-- stamped quest-log index remains the authoritative identity.
QuestLogLevels.renderedRows = {}

-- Splits off everything that has to stay in front of the level prefix and
-- returns the row's indent, its colour escape and the rest, in that order.
--
-- The two are handed back separately because the party count goes BETWEEN
-- them: after the indent, so a quest stays indented under its zone header, but
-- in front of a skin's colour escape, so the count keeps its own grey and the
-- skin keeps the title.
--
-- A count this module wrote on an earlier pass is dropped here rather than
-- carried forward, so the one rebuilt below is always the one the client's tag
-- reads right now.
local function SplitLeadIn(text)
    local indent = ""
    local rest = text
    local _, _, foundIndent, afterIndent = string.find(rest, "^(%s+)(.*)$")
    if foundIndent then
        indent = foundIndent
        rest = afterIndent
    end
    local _, _, afterCount = string.find(rest,
        "^|c%x%x%x%x%x%x%x%x%[%d+%]|r%s*(.*)$")
    if afterCount then
        rest = afterCount
    end
    local escape = ""
    local _, _, foundEscape, afterEscape =
        string.find(rest, "^(|c%x%x%x%x%x%x%x%x)(.*)$")
    if foundEscape then
        escape = foundEscape
        rest = afterEscape
    end
    return indent, escape, rest
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

-- Which quest a row is showing, verified against the row's own text.
--
-- Client.GetQuestLogRowQuestIndex offers the scrolled index and the row's
-- stamped ID, in that order, because the two agree only at the top of an
-- unscrolled list. Taking either on faith would stamp a row with another
-- quest's level as soon as the list is scrolled, so the candidate is accepted
-- only when the row is already carrying that quest's title -- or when this
-- module wrote the row's current text for that same index itself, which is
-- how a translated title stays recognizable.
local function ResolveRowEntry(row, rowIndex, text, bare)
    local primary, fallback = Client.GetQuestLogRowQuestIndex(row, rowIndex)
    local previous = QuestLogLevels.renderedRows[row]
    local candidate = primary
    local attempt = 1
    while attempt <= 2 do
        if candidate then
            local title, level, _, isHeader = Client.GetQuestLogEntry(candidate)
            if title and not isHeader then
                local quest = nil
                local state = UQ:GetModule("QuestState")
                if state then
                    quest = state:GetQuestByTitle(title)
                end
                local displayTitle = UQ.GetQuestDisplayTitle(
                    quest or { title = title }, title) or title
                local isOwnText = previous and previous.questIndex == candidate
                    and previous.text == text
                if isOwnText or RowCarriesTitle(bare, title)
                    or RowCarriesTitle(bare, displayTitle) then
                    return candidate, title, level, displayTitle, isOwnText
                end
            end
        end
        candidate = fallback
        fallback = nil
        attempt = attempt + 1
    end
    return nil
end

-- Returns whether the row now reads as "[count] [level] title", and the level
-- the row resolved to. The caller paints the colour band from that same level,
-- so the two halves of the row's presentation cannot describe different quests.
--
-- grouped is resolved once per pass by the caller: with nobody else in the
-- group there is no count to ask about on any row.
local function DecorateRow(row, rowIndex, grouped)
    local text = Client.GetObjectText(row)
    if not text then
        return false
    end

    local indent, escape, rest = SplitLeadIn(text)
    local bare = StripLevelPrefix(rest)
    local questIndex, title, level, displayTitle, isOwnText =
        ResolveRowEntry(row, rowIndex, text, bare)
    if not questIndex then
        return false
    end
    if type(level) ~= "number" or level <= 0 then
        return false
    end
    local previous = QuestLogLevels.renderedRows[row]

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

    -- Asked per row, not per pass: two rows of the same log rarely have the
    -- same peers on them, and nothing is asked at all while solo.
    local count = ""
    if grouped then
        local partyCount = Client.GetQuestLogPartyCount(questIndex)
        if partyCount then
            count = PARTY_COUNT_COLOR .. "[" .. partyCount .. "]|r "
        end
    end
    local decorated = indent .. count .. escape
        .. "[" .. level .. "] " .. displayTitle .. suffix
    if decorated == text then
        -- Already correct, whoever wrote it. Writing it again every 0.2s
        -- would be the only thing here that could make the list flicker.
        QuestLogLevels.renderedRows[row] = {
            questIndex = questIndex, text = text, suffix = suffix,
        }
        return true, level
    end
    if Client.SetNativeObjectText(row, decorated) then
        QuestLogLevels.renderedRows[row] = {
            questIndex = questIndex, text = decorated, suffix = suffix,
        }
        return true, level
    end
    return false, level
end

-- Paints the row from the level DecorateRow already resolved for it, so the
-- band and the prefix always describe the same quest. A row that is not a
-- levelled quest row on the modern surface -- a header, a hidden pooled row,
-- one whose quest could not be resolved, or any row at all while the host is
-- not modern -- gets its original colour back instead of a band.
local function ColorRow(row, modern, level)
    if not modern or not Client.IsObjectShown(row)
        or type(level) ~= "number" or level <= 0 then
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
    -- Same reasoning as modern above: the party is a fact about the player,
    -- not about a row, so it is one call per pass rather than one per row.
    local grouped = Client.IsInGroup()
    local decorated = 0
    local canaryRow = nil
    local rowIndex = 1
    local misses = 0
    while rowIndex <= MAX_LOG_ROWS and misses < 3 do
        local row = Client.GetNamedObject("QuestLogTitle" .. tostring(rowIndex))
        if not row then
            misses = misses + 1
        else
            misses = 0
            local level = nil
            if Client.IsObjectShown(row) then
                local rowDecorated, rowLevel =
                    DecorateRow(row, rowIndex, grouped)
                level = rowLevel
                if rowDecorated then
                    decorated = decorated + 1
                    if not canaryRow then
                        canaryRow = row
                    end
                end
            end
            ColorRow(row, modern, level)
            -- Outside the shown branch on purpose: a row that stops carrying a
            -- count -- scrolled away, turned into a header, or the player left
            -- the party -- is exactly the row whose own tag has to come back.
            Client.SetQuestLogRowPartyTagHidden(row, grouped)
        end
        rowIndex = rowIndex + 1
    end
    self.decorated = decorated

    -- A decorated row is the sharpest canary there is: the client rewrites it
    -- to the bare title, which can never equal what was just written here.
    -- With nothing decorated there is also nothing to lose, so the first row
    -- is watched instead, purely so a list that becomes decoratable is picked
    -- up on the next tick rather than the next poll.
    if not canaryRow then
        canaryRow = Client.GetNamedObject("QuestLogTitle1")
    end
    -- Read back rather than remembering what was written. The two are the same
    -- string on this client, but a host that normalized it would otherwise
    -- leave the watch permanently dissatisfied and run a full pass every tick.
    self.canaryRow = canaryRow
    self.canaryText = canaryRow and Client.GetObjectText(canaryRow) or nil
end

-- Cheap enough to run on every tick: it reads one row and returns.
function QuestLogLevels:Watch()
    local row = self.canaryRow
    if not row then
        return false
    end
    local log = Client.GetNamedObject("QuestLogFrame")
    if not log or not Client.IsObjectShown(log) then
        return false
    end
    if Client.GetObjectText(row) == self.canaryText then
        return false
    end

    self.rewrites = self.rewrites + 1
    self:Refresh()

    -- Same rewrite, same frame: a scroll has just moved every quest onto a
    -- different row, so the track mark and the followed-quest plaque belong to
    -- different rows now too. Quest/QuestLogTracking.lua's shift-click chain
    -- reapplies this same pair for the same reason.
    local tracking = UQ:GetModule("QuestLogTracking")
    if tracking then
        tracking:RefreshMarks()
    end
    local buttons = UQ:GetModule("QuestLogButtons")
    if buttons then
        buttons:Refresh()
    end
    return true
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
    driver:Schedule("questlog.levels.watch", WATCH_INTERVAL, function()
        QuestLogLevels:Watch()
    end)
end
