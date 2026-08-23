--[[
UnrealQuest / Compatibility/ClientAPI.lua

The single boundary between UnrealQuest and the Unreal Azeroth client API.
Runtime modules call these wrappers; they do not call client globals directly.

Every wrapper below is backed by an entry in docs/CLIENT-COMPATIBILITY.md that
names the evidence it rests on. The layer is deliberately small: it wraps only
what UnrealQuest needs and only where client compatibility actually matters.

Ground rules enforced here:
  * Nothing is assumed to exist. Symbols are resolved through getglobal and
    every call is pcall-guarded, so a missing API degrades to nil rather than
    faulting the addon.
  * No client event is assumed to exist. Event registration is guarded, and its
    success is recorded but never required for correctness.
  * Native frame OnEvent handlers are never invoked directly: doing that is
    confirmed to crash this client rather than raise a catchable error.
]]

local UQ = UnrealQuest
local Client = {}
UQ.Client = Client

-- Symbol resolution ---------------------------------------------------------

local symbolCache = {}

local function Resolve(name)
    local cached = symbolCache[name]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    local ok, value = pcall(getglobal, name)
    if not ok or type(value) ~= "function" then
        symbolCache[name] = false
        return nil
    end
    symbolCache[name] = value
    return value
end

function Client.HasFunction(name)
    return Resolve(name) ~= nil
end

-- Drops one cached symbol resolution.
--
-- The cache above is a load-time optimisation and also caches ABSENCE, which
-- is correct for a client whose global table does not change under the addon.
-- The offline test needs to model both a client that has GetPlayerFacing and
-- one that does not, within a single run, so it needs a way to say "ask again".
-- Nothing in the addon calls this.
function Client.ForgetSymbol(name)
    symbolCache[name] = nil
end

function Client.HasObject(name)
    local ok, value = pcall(getglobal, name)
    if not ok then
        return false
    end
    return value ~= nil
end

local function ResolveObject(name)
    local ok, value = pcall(getglobal, name)
    if not ok or (type(value) ~= "table" and type(value) ~= "userdata") then
        return nil
    end
    return value
end

-- Reads one of the client's own localized format strings (QUEST_MONSTERS_KILLED
-- and friends). These are plain string globals, not functions or frames, so
-- neither Resolve nor ResolveObject above can reach them.
--
-- The client's API reference documents that GetQuestLogLeaderBoard formats its
-- objective text with these exact globals, which is what makes reading a
-- creature name back out of an objective line possible at all. They are read
-- through this wrapper rather than directly so a client that does not define
-- one degrades to nil like every other missing symbol here.
function Client.GetGlobalString(name)
    local ok, value = pcall(getglobal, name)
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- Guarded calls. Call0/1/2 keep the argument lists explicit rather than relying
-- on varargs, which keeps the layer inside the conservative Lua subset.

local function Call0(name)
    local fn = Resolve(name)
    if not fn then
        return false
    end
    return pcall(fn)
end

local function Call1(name, a)
    local fn = Resolve(name)
    if not fn then
        return false
    end
    return pcall(fn, a)
end

local function Call2(name, a, b)
    local fn = Resolve(name)
    if not fn then
        return false
    end
    return pcall(fn, a, b)
end

Client.Call0 = Call0
Client.Call1 = Call1
Client.Call2 = Call2

-- Time ----------------------------------------------------------------------
-- GetTime is measured accurate to the wall clock on this client. It is the
-- only sanctioned time source: OnUpdate handlers here receive no arguments and
-- the legacy arg1 global that carries the frame delta is overwritten by every
-- event dispatch, so an arg1-derived delta stalls unpredictably.

function Client.Now()
    local ok, value = Call0("GetTime")
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

-- Events --------------------------------------------------------------------
-- No quest-related event has any record in the runtime compatibility database
-- and the client's own API reference does not document event names at all.
-- Registration is therefore attempted defensively and its outcome reported;
-- UnrealQuest treats every event purely as an accelerator over polling.

function Client.RegisterEvent(frame, event)
    if not frame or not frame.RegisterEvent then
        return false
    end
    local ok = pcall(frame.RegisterEvent, frame, event)
    return ok and true or false
end

function Client.UnregisterEvent(frame, event)
    if not frame or not frame.UnregisterEvent then
        return false
    end
    local ok = pcall(frame.UnregisterEvent, frame, event)
    return ok and true or false
end

-- Resolves the event name for an OnEvent handler. Measured evidence on this
-- client: an OnEvent script on a plain frame receives no event string in its
-- direct arguments and the name must be read from the legacy event global.
-- Other widget callbacks do pass direct arguments, so both shapes are checked.
function Client.ResolveEventName(first, second)
    if type(first) == "string" then
        return first
    end
    if type(second) == "string" then
        return second
    end
    local ok, value = pcall(getglobal, "event")
    if ok and type(value) == "string" then
        return value
    end
    return nil
end

-- Quest log -----------------------------------------------------------------

function Client.GetQuestLogCount()
    local ok, value = Call0("GetNumQuestLogEntries")
    if ok and type(value) == "number" then
        return value
    end
    return 0
end

-- Quest log title decorations ------------------------------------------------
--
-- A quest log title does not always arrive as the quest's name. CTMod's
-- CT_QuestLevels -- and the many addons that copy it, several of them shipped
-- as standard with Russian client bundles -- hook GetQuestLogTitle and return
-- "[24] Weapons of Choice" instead of "Weapons of Choice". A ruRU tester was
-- reported on 2026-08-23 with exactly that: every tracker row showed its level
-- twice, because Quest/TrackerFrame.lua adds one bracket of its own on top of
-- the one already in the string.
--
-- The doubled bracket is the harmless half. The title is the ONLY join this
-- addon has between a quest log row and the bundled database (this client has
-- no quest ID API), so a decorated title matches no record at all: every quest
-- resolves "unmatched" and the whole map layer, minimap layer and waypoint go
-- silently empty. That is what the report was -- quests 879 and 893 drawing
-- nothing while pfQuest drew them.
--
-- Two independent defences, because neither one covers every setup:
--
--   1. UnhookedQuestLogTitle prefers the untouched function a CT_QuestLevels
--      -style addon leaves behind, so the decoration is never applied. pfQuest
--      does the same (pfQuest/compat/client.lua) and that is precisely why it
--      kept working here where this addon did not.
--   2. CleanQuestTitle strips the decoration from whatever did come back. This
--      is the only defence that helps when the client itself decorates the
--      title, or when the hooking addon leaves no original behind.
--
-- Both run on every read. Neither is trusted to be enough on its own.

-- The saved original is another addon's global, created whenever that addon
-- happens to load. Deliberately NOT routed through Resolve: that caches
-- absence for the whole session, and a miss on the first quest log scan must
-- not become permanent just because the hooking addon had not run yet.
local unhookedQuestLogTitle = nil

local function UnhookedQuestLogTitle()
    if unhookedQuestLogTitle then
        return unhookedQuestLogTitle
    end
    local ok, value = pcall(getglobal, "CT_QuestLevels_oldGetQuestLogTitle")
    if ok and type(value) == "function" then
        unhookedQuestLogTitle = value
        return value
    end
    return nil
end

-- How many reads came back decorated, for /uq quests. Zero on a clean client.
local questTitleDecorations = 0

-- A bracket group that STARTS with a digit, plus the space after it:
-- "[24] ", "[24+] ", "[24D] ", "[15G5] ", "[60R] ". The leading-digit
-- requirement is what makes this safe to apply unconditionally: eight bundled
-- koKR quest titles genuinely begin with a bracket group (translation-status
-- markers such as "unused" and "reused"), and not one of them puts a digit
-- first, so no real title in the data can be cut by this.
local function StripLevelPrefix(text)
    local stripped = string.gsub(text, "^%s*%[%d[^%]]*%]%s*", "", 1)
    return stripped
end

-- Colour escapes are not part of any bundled title. They are stripped here
-- rather than left for UQ.NameKey, which keeps them as alphanumerics
-- ("|cff808080" becomes "cff808080") and would hide the bracket behind them.
local function StripColourEscapes(text)
    local stripped = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    stripped = string.gsub(stripped, "|r", "")
    return stripped
end

-- The quest's own name, with any level decoration taken back off.
--
-- Returns the cleaned title plus whether a DECORATION was removed. Surrounding
-- whitespace is trimmed either way but never counts as decoration: UQ.NameKey
-- drops whitespace anyway, so a trim changes no match, and letting it set the
-- flag would make the /uq quests diagnostic cry wolf.
function Client.CleanQuestTitle(title)
    if type(title) ~= "string" then
        return nil, false
    end
    local trimmed = UQ.Trim(title) or title
    local cleaned = StripColourEscapes(trimmed)
    -- Bounded rather than "until it stops changing": a client that decorates
    -- and an addon that decorates on top of it produce two brackets, and the
    -- bound keeps a pathological title from spinning here.
    local rounds = 0
    while rounds < 3 do
        local stripped = StripLevelPrefix(cleaned)
        if stripped == cleaned then
            break
        end
        cleaned = stripped
        rounds = rounds + 1
    end
    cleaned = UQ.Trim(cleaned) or cleaned
    if cleaned == "" then
        -- The title was nothing but decoration. Report what the client said
        -- rather than inventing an empty name for a quest that has one.
        return title, false
    end
    return cleaned, cleaned ~= trimmed
end

function Client.GetQuestTitleDecorationCount()
    return questTitleDecorations
end

-- Returns title, level, questTag, isHeader, isCollapsed, isComplete, rawTitle.
--
-- The six-value contract is corroborated twice: the questtrack probe captured a
-- six-value return tuple with isHeader in position four, and the client API
-- reference documents the same order. Out-of-range indices yield
-- (nil, 0, nil, nil, nil, nil).
--
-- The title is the cleaned one (see above). rawTitle is the seventh value and
-- is nil unless cleaning actually changed something, so a caller can tell a
-- decorated read apart from a clean one without comparing strings itself --
-- Data/QuestMatch.lua uses it to try the client's own spelling against the
-- database first, before falling back to the cleaned one.
function Client.GetQuestLogEntry(index)
    local fn = UnhookedQuestLogTitle() or Resolve("GetQuestLogTitle")
    if not fn then
        return nil
    end
    local ok, title, level, questTag, isHeader, isCollapsed, isComplete = pcall(fn, index)
    if not ok or type(title) ~= "string" then
        return nil
    end
    local cleaned, decorated = Client.CleanQuestTitle(title)
    if not decorated then
        return cleaned or title, level, questTag, isHeader, isCollapsed, isComplete
    end
    questTitleDecorations = questTitleDecorations + 1
    return cleaned, level, questTag, isHeader, isCollapsed, isComplete, title
end

function Client.GetObjectiveCount(questIndex)
    local ok, value = Call1("GetNumQuestLeaderBoards", questIndex)
    if ok and type(value) == "number" then
        return value
    end
    return 0
end

-- Objective readout.
--
-- The two-argument GetQuestLogLeaderBoard(objectiveIndex, questIndex) form is
-- documented and is preferred because it avoids mutating the quest log
-- selection, which the native Quest Log window also reads. Whether this client
-- honours the second argument is not runtime-verified, so the first quest that
-- reports objectives but returns nothing through the two-argument path flips
-- the layer over to the selection-based path for the rest of the session, and
-- the active path is reported through the objectiveReadout capability.

local objectiveMode = "indexed"

local function ReadObjectiveIndexed(objectiveIndex, questIndex)
    local fn = Resolve("GetQuestLogLeaderBoard")
    if not fn then
        return nil
    end
    local ok, text, objectiveType, isFinished = pcall(fn, objectiveIndex, questIndex)
    if not ok then
        return nil
    end
    return text, objectiveType, isFinished
end

local function ReadObjectiveSelected(objectiveIndex, questIndex)
    local fn = Resolve("GetQuestLogLeaderBoard")
    if not fn then
        return nil
    end
    local previousOk, previous = Call0("GetQuestLogSelection")
    Call1("SelectQuestLogEntry", questIndex)
    local ok, text, objectiveType, isFinished = pcall(fn, objectiveIndex)
    if previousOk and type(previous) == "number" and previous > 0 then
        Call1("SelectQuestLogEntry", previous)
    end
    if not ok then
        return nil
    end
    return text, objectiveType, isFinished
end

function Client.GetObjective(questIndex, objectiveIndex)
    if objectiveMode == "indexed" then
        local text, objectiveType, isFinished = ReadObjectiveIndexed(objectiveIndex, questIndex)
        if type(text) == "string" and text ~= "" then
            return text, objectiveType, isFinished
        end
        -- Nothing came back. Only treat that as a failure of the indexed form
        -- when the quest genuinely has objectives to report.
        if Client.GetObjectiveCount(questIndex) >= objectiveIndex then
            objectiveMode = "selected"
            UQ:DeclareCapability("objectiveReadout", "detected",
                "two-argument GetQuestLogLeaderBoard returned nothing for a quest with objectives; using SelectQuestLogEntry")
            UQ:Debug("objective readout fell back to the selection-based path")
        else
            return text, objectiveType, isFinished
        end
    end
    return ReadObjectiveSelected(objectiveIndex, questIndex)
end

function Client.GetObjectiveMode()
    return objectiveMode
end

-- Description text of a quest log row, read via the row's own selection.
--
-- GetQuestLogQuestText() is in this client's own API reference (category
-- Quest, DOCUMENTED_NOT_RUNTIME_VERIFIED) as a no-argument call returning
-- questDescription for whichever quest is currently selected. The selection
-- is swapped to questIndex and restored afterward exactly like
-- ReadObjectiveSelected above,
-- rather than assumed to already point at the right row -- a tracker click or
-- the native Quest Log window could hold the selection at any other row.
function Client.GetQuestLogDetailText(questIndex)
    local fn = Resolve("GetQuestLogQuestText")
    if not fn then
        return nil
    end
    local previousOk, previous = Call0("GetQuestLogSelection")
    Call1("SelectQuestLogEntry", questIndex)
    local ok, text = pcall(fn)
    if previousOk and type(previous) == "number" and previous > 0 then
        Call1("SelectQuestLogEntry", previous)
    end
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    return text
end

-- The row currently selected in the native Quest Log, unguarded -- unlike the
-- two readers above, this does NOT swap the selection first. It exists so a
-- layer that draws UI alongside the detail pane (the Show/Track buttons) can
-- ask "what is the player looking at right now" without disturbing it.
function Client.GetQuestLogSelection()
    local ok, value = Call0("GetQuestLogSelection")
    if ok and type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

-- Quest watch ---------------------------------------------------------------
-- Measured: AddQuestWatch, RemoveQuestWatch and IsQuestWatched all share the
-- raw GetQuestLogTitle index space, including header rows, and round-trip
-- cleanly. Also established: the watch list itself does not survive a UI
-- reload on this client, and the client caps it at five quests.

Client.MAX_WATCHES = 5

function Client.IsQuestWatched(index)
    local ok, value = Call1("IsQuestWatched", index)
    if not ok then
        return nil
    end
    return value and true or false
end

function Client.AddQuestWatch(index)
    local ok = Call1("AddQuestWatch", index)
    return ok and true or false
end

function Client.RemoveQuestWatch(index)
    local ok = Call1("RemoveQuestWatch", index)
    return ok and true or false
end

function Client.GetWatchCount()
    local ok, value = Call0("GetNumQuestWatches")
    if ok and type(value) == "number" then
        return value
    end
    return 0
end

-- Measured 2026-08-20: AddQuestWatch changes the watch-list state but does
-- not redraw the native panel. QuestWatch_Update is the safe public refresh
-- helper; never invoke QuestWatchFrame's native OnEvent handler directly.
function Client.RefreshQuestWatch()
    local ok = Call0("QuestWatch_Update")
    return ok and true or false
end

-- Bags ----------------------------------------------------------------------
-- Needed for exactly one question: is the player carrying the item that a
-- "use this on that" objective consumes? Without it the map cannot tell a step
-- the player can take now from one they cannot reach yet.
--
-- Evidence footing is thin and the wrappers are written to say so.
-- GetContainerNumSlots and GetContainerItemLink are in the client's API
-- reference (OFFICIAL_CLIENT_DOCUMENTATION, DOCUMENTED_NOT_RUNTIME_VERIFIED)
-- and the compact database records the whole container surface as behaviour-
-- untested (bags.container_api_contract_unverified): no probe establishes the
-- tuple shapes or the nil behaviour. GetItemCount has no record at all and is
-- deliberately not used.
--
-- Both wrappers therefore return nil rather than a default on anything
-- unexpected, and callers must read nil as "unknown", never as "empty".

-- The player's own carried bags. The bank (-1) and keyring (-2) are out of
-- scope: an item in either is not on the player, so it cannot satisfy a step
-- that has to be performed in the world.
Client.FIRST_BAG = 0
Client.LAST_BAG = 4

function Client.GetBagSlotCount(bag)
    local ok, value = Call1("GetContainerNumSlots", bag)
    if ok and type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

-- Returns the numeric item ID held in bag/slot, parsed out of the item
-- hyperlink. The link is used rather than GetContainerItemInfo because only
-- the link carries an identity: the info tuple starts with a texture path,
-- which is shared by many items and is not a key.
function Client.GetBagItemId(bag, slot)
    local ok, link = Call2("GetContainerItemLink", bag, slot)
    if not ok or type(link) ~= "string" then
        return nil
    end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

function Client.HasBagScan()
    return Client.HasFunction("GetContainerNumSlots")
        and Client.HasFunction("GetContainerItemLink")
end

-- Player --------------------------------------------------------------------

function Client.GetPlayerLevel()
    local ok, value = Call1("UnitLevel", "player")
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

function Client.GetPlayerFaction()
    local ok, value = Call1("UnitFactionGroup", "player")
    if ok and type(value) == "string" then
        return value
    end
    return nil
end

function Client.GetPlayerRace()
    local ok, value = Call1("UnitRace", "player")
    if ok and type(value) == "string" then
        return value
    end
    return nil
end

function Client.GetPlayerClass()
    local ok, localized, token = Call1("UnitClass", "player")
    if not ok then
        return nil
    end
    return localized, token
end

-- Measured on this client: UnitRace("player") returns three values
-- ("Human", "Human", 1) and UnitClass("player") returns ("Warlock",
-- "WARLOCK", 9). The third value is the numeric race/class id, which is what
-- the bundled data's race and class bitmasks are built from -- bit 2^(id-1).
-- Reading the id is far more robust than matching a localized name.

function Client.GetPlayerRaceId()
    local ok, _, _, raceId = Call1("UnitRace", "player")
    if ok and type(raceId) == "number" and raceId > 0 then
        return raceId
    end
    return nil
end

function Client.GetPlayerClassId()
    local ok, _, _, classId = Call1("UnitClass", "player")
    if ok and type(classId) == "number" and classId > 0 then
        return classId
    end
    return nil
end

function Client.GetPlayerName()
    local ok, value = Call1("UnitName", "player")
    if ok and type(value) == "string" then
        return value
    end
    return nil
end

-- OFFICIAL_CLIENT_DOCUMENTATION: UnitSex(unit) returns 1 unknown/neutral,
-- 2 male or 3 female. This is used only to choose a $G quest-text branch; an
-- absent or unexpected result remains nil so QuestMatch can test both safely.
function Client.GetPlayerSex()
    local ok, value = Call1("UnitSex", "player")
    if ok and (value == 2 or value == 3) then
        return value
    end
    return nil
end

-- Locale -----------------------------------------------------------------
-- Documented (OFFICIAL_CLIENT_DOCUMENTATION) to return a WoW-style locale
-- token derived from the client's own culture: enUS, ruRU, esES, esMX, zhCN,
-- zhTW, koKR, frFR or deDE. Also runtime-probed returning "enUS" on that
-- client (core.locale.v1, BEHAVIOR_PARTIALLY_TESTED). Used to pick which
-- Database/<locale> table to read; a client whose token names a locale the
-- bundled data does not ship simply falls back to enUS at the call site.
function Client.GetLocale()
    local ok, value = Call0("GetLocale")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Raid target marks ---------------------------------------------------------
--
-- The one way left to draw something over a specific creature in the 3D world
-- on this client. Everything else was measured absent: no unit world or screen
-- position, no readable player facing, and no nameplate widget -- WorldFrame's
-- 26 children are all FrameXML furniture (docs/CLIENT-COMPATIBILITY.md item
-- 12). A raid mark is drawn engine-side over the unit itself, so it needs no
-- anchor at all.
--
-- Three documented details shape every caller here:
--
--   * SetRaidTarget(unit, index) "sends index - 1 to the server", so the mark
--     is a SERVER ROUND TRIP, not a local write. It cannot be verified by
--     reading straight back -- GetRaidTargetIndex will still answer nil for a
--     write that is about to succeed. World/QuestMarks.lua confirms on a later
--     tick instead, and that delay is the whole reason the confirmation is
--     written the way it is.
--   * index 0 is sent as -1 and clears the mark.
--   * "Does nothing if unit does not exist" -- so an absent unit is silently a
--     no-op rather than an error, and UnitExists is still checked first
--     because a stale name must never be attributed to a live creature.
--
-- Neither function is marked protected. Live evidence established that the
-- server ignores solo writes; whether it accepts a party leader or raid
-- assistant remains the open part of the capability.

function Client.HasRaidTargetMarks()
    return Client.HasFunction("SetRaidTarget") and Client.HasFunction("GetRaidTargetIndex")
end

function Client.SetRaidTargetMark(unit, index)
    local ok = Call2("SetRaidTarget", unit, index)
    return ok and true or false
end

function Client.GetRaidTargetMark(unit)
    local ok, value = Call1("GetRaidTargetIndex", unit)
    if ok and type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

function Client.UnitExists(unit)
    local ok, value = Call1("UnitExists", unit)
    return ok and value and true or false
end

function Client.UnitIsPlayer(unit)
    local ok, value = Call1("UnitIsPlayer", unit)
    return ok and value and true or false
end

function Client.GetUnitName(unit)
    local ok, value = Call1("UnitName", unit)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Whether the player is in any group at all. A raid mark is SHARED state --
-- every other member sees it and it overwrites whatever they had set -- so
-- this is what World/QuestMarks.lua gates on before marking anything
-- automatically. GetNumPartyMembers is documented as counting other members
-- and answering 0 when alone, which stays valid in a raid as well as a party.
function Client.IsInGroup()
    local ok, value = Call0("GetNumPartyMembers")
    if ok and type(value) == "number" and value > 0 then
        return true
    end
    local raidOk, raidValue = Call0("GetNumRaidMembers")
    if raidOk and type(raidValue) == "number" and raidValue > 0 then
        return true
    end
    return false
end

-- Entity tooltip support ----------------------------------------------------
-- UnitName accepts the documented "mouseover" unit token. It is deliberately
-- read only while the native GameTooltip is shown, so this never turns a
-- mouseover into a target or interferes with the client's own tooltip setup.
-- Kept for callers that specifically need a unit token (e.g. a future
-- UnitReaction/UnitLevel lookup); entity-tooltip identity itself uses
-- GetGameTooltipUnitLabel below instead -- see the comment there for why.

function Client.GetMouseoverUnitName()
    local ok, value = Call1("UnitName", "mouseover")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function ResolveGameTooltip()
    return ResolveObject("GameTooltip")
end

function Client.GetGameTooltipLineCount()
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(tooltip.NumLines) ~= "function" then
        return nil
    end
    local ok, count = pcall(tooltip.NumLines, tooltip)
    if ok and type(count) == "number" then
        return count
    end
    return nil
end

-- Identifies what GameTooltip is currently showing by reading back its own
-- first line (GameTooltipTextLeft1) instead of asking UnitName("mouseover").
-- This is not a guess: Interface/AddOns/pfQuest/map.lua does exactly this
-- (pfMap.tooltip:SetScript("OnShow", ...), reading
-- getglobal("GameTooltipTextLeft1"):GetText() and stripping colour codes) to
-- add its own quest-objective lines to a live creature's tooltip, and it is
-- the addon a side-by-side comparison confirmed working on this install where
-- UnitName("mouseover")-based detection was not. Whatever the exact reason
-- (mouseover unit-token timing on this client, most likely, given rule 4's
-- general distrust of anything time-sensitive here), reading the tooltip's
-- own rendered text sidesteps it entirely: it can only ever say what the
-- tooltip is actually, currently displaying.
function Client.GetGameTooltipUnitLabel()
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(tooltip.IsShown) ~= "function" then
        return nil
    end
    local shownOk, shown = pcall(tooltip.IsShown, tooltip)
    if not shownOk or not shown then
        return nil
    end
    local label = ResolveObject("GameTooltipTextLeft1")
    if not label or type(label.GetText) ~= "function" then
        return nil
    end
    local ok, text = pcall(label.GetText, label)
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return text
end

-- GameTooltip:SetUnit was tried here to force a full, authoritative rebuild
-- before every append (SetUnit "clears lines first" per this client's own
-- documentation). It was reverted: calling it a second time, from Lua, after
-- the client has already built the tooltip on its own, has never been
-- runtime-probed, and a user report -- a live comparison with pfQuest enabled
-- instead, which does show objective progress on the same tooltip -- pointed
-- at that second SetUnit call as the likely cause of the tooltip going blank.
-- ClearLines is documented to run before the rest of SetUnit's work, so
-- anything that goes wrong partway through leaves the tooltip cleared with
-- nothing recovering it. Client.AppendGameTooltipLines below never clears or
-- rebuilds anything for exactly this reason: it can only add to whatever is
-- already there, the same as pfQuest's own AddLine calls in map.lua do.

-- A child frame parented to GameTooltip whose OnShow fires whenever
-- GameTooltip's own effective visibility flips to shown -- ordinary
-- frame-visibility propagation, not a client event. This is the exact shape
-- of pfMap.tooltip in Interface/AddOns/pfQuest/map.lua
-- (CreateFrame("Frame", "pfMapTooltip", GameTooltip) with an OnShow script
-- that reads GameTooltipTextLeft1 and calls AddLine), which is confirmed
-- working on this install. Tooltip/EntityTooltip.lua calls Refresh directly
-- and synchronously from this callback, matching pfMap.tooltip's own
-- synchronous OnShow -> AddLine -> Show sequence, rather than only deferring
-- to the poll job. The poll remains scheduled as the correctness guarantee
-- (rule 4) in case this hook does not fire for some reason.
function Client.HookGameTooltipShow(callback)
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(callback) ~= "function" then
        return false
    end
    local ok, hook = pcall(CreateFrame, "Frame", nil, tooltip)
    if not ok or not hook then
        return false
    end
    hook:SetScript("OnShow", callback)
    return true
end

function Client.AppendGameTooltipLines(lines)
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(tooltip.AddLine) ~= "function" then
        return false
    end
    if type(tooltip.IsShown) == "function" then
        local shownOk, shown = pcall(tooltip.IsShown, tooltip)
        if not shownOk or not shown then
            return false
        end
    end

    local appended = false
    local index = 1
    local total = table.getn(lines or {})
    while index <= total do
        local line = lines[index]
        if line and type(line.text) == "string" then
            local ok = pcall(tooltip.AddLine, tooltip, line.text,
                line.r or 1, line.g or 1, line.b or 1)
            if ok then
                appended = true
            end
        end
        index = index + 1
    end

    -- The client's own reference documents AddLine as recalculating layout on
    -- an already-visible tooltip by itself. UnrealPfUI/modules/tooltip.lua
    -- (function UnrealPfUI.tooltip:Update) never trusts that claim alone and
    -- calls GameTooltip:Show() again after every AddLine -- cited here only
    -- as prior art read from its source, not as evidence it runs on this
    -- install (UnrealPfUI is not required and may not be enabled). The call
    -- is cheap and, unlike SetUnit above, cannot clear anything, so it is
    -- kept as a safe belt-and-suspenders step regardless.
    if appended and type(tooltip.Show) == "function" then
        pcall(tooltip.Show, tooltip)
    end

    return appended
end

-- Quest difficulty colouring.
--
-- GetDifficultyColor is confirmed absent on this client and cannot be shimmed
-- from an addon, so the colour is derived locally from the documented
-- GetQuestGreenRange plus the standard level bands.
function Client.GetQuestGreenRange()
    local ok, value = Call0("GetQuestGreenRange")
    if ok and type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

function Client.GetQuestLevelColor(questLevel)
    local playerLevel = Client.GetPlayerLevel()
    if type(questLevel) ~= "number" or not playerLevel then
        return 1, 1, 1
    end
    local difference = questLevel - playerLevel
    if difference >= 5 then
        return 1, 0.1, 0.1
    elseif difference >= 3 then
        return 1, 0.5, 0.25
    elseif difference >= -2 then
        return 1, 1, 0
    else
        local greenRange = Client.GetQuestGreenRange() or 5
        if questLevel > playerLevel - greenRange then
            return 0.25, 0.75, 0.25
        end
        return 0.5, 0.5, 0.5
    end
end

-- Map -----------------------------------------------------------------------
-- Measured 2026-08-20: SetMapToCurrentZone makes GetMapInfo return "Elwynn"
-- and GetPlayerMapPosition return non-zero coordinates. After reload the map
-- view is uninitialized, while GetZoneText still resolves the player's area.
-- The first pin layer therefore draws only when the viewed map projects the
-- player and only for database coordinates in that uniquely resolved area.

function Client.GetCurrentMapFile()
    local ok, name, height, width = Call0("GetMapInfo")
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end
    return name, height, width
end

function Client.GetCurrentMapContinent()
    local ok, value = Call0("GetCurrentMapContinent")
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

function Client.GetCurrentMapZone()
    local ok, value = Call0("GetCurrentMapZone")
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

-- Never called defensively on every read: it mutates what the map displays,
-- so it would fight a player who deliberately zoomed out to a continent.
-- MapContext:GetCurrentZoneView calls it at most once per session, only on
-- the login-cold signature (zoneIndex 0 AND mapFile nil) that is otherwise
-- indistinguishable from a genuine continent view. See docs/CLIENT-COMPATIBILITY.md,
-- "Map cold-start" -- probe mapcoldstart 2026-08-23 confirmed a single call
-- resolves zoneIndex 0/mapFile nil/player 0,0 into zoneIndex 14/mapFile
-- "Elwynn"/a real player position, with WorldMapFrame never shown.
function Client.SetMapToCurrentZone()
    local ok = Call0("SetMapToCurrentZone")
    return ok and true or false
end

function Client.GetPlayerMapPosition(unit)
    local ok, x, y = Call1("GetPlayerMapPosition", unit or "player")
    if not ok or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    -- The client returns 0, 0 for "no position on this view" rather than nil.
    if x == 0 and y == 0 then
        return nil
    end
    return x, y
end

function Client.GetZoneText()
    local ok, value = Call0("GetZoneText")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

function Client.GetSubZoneText()
    local ok, value = Call0("GetSubZoneText")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- WorldMapButton is the map canvas used by the installed pfQuest source. The
-- client object is resolved defensively at runtime because it may be created
-- lazily. The user's focused in-game map test confirmed that an addon-owned
-- coloured child is rendered on the fullscreen map while its view changes.
function Client.GetWorldMapCanvas()
    local canvas = ResolveObject("WorldMapButton")
    if not canvas or type(canvas.GetWidth) ~= "function" or type(canvas.GetHeight) ~= "function" then
        return nil
    end
    return canvas
end

-- Pixel size of the canvas the 0..1 pin fractions are placed against. Pin
-- fractions alone cannot answer "are these two markers too close to hover
-- apart" -- that question is in pixels, and the map canvas is neither square
-- nor a fixed size, so x and y have to be scaled independently. Same
-- defensive read as Client.PositionWorldMapPin, which already measures the
-- canvas the same way before placing anything on it.
function Client.GetWorldMapCanvasSize()
    local canvas = Client.GetWorldMapCanvas()
    if not canvas then
        return nil
    end
    local widthOk, width = pcall(canvas.GetWidth, canvas)
    local heightOk, height = pcall(canvas.GetHeight, canvas)
    if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return nil
    end
    return width, height
end

function Client.HideObject(object)
    if not object or type(object.Hide) ~= "function" then
        return false
    end
    local ok = pcall(object.Hide, object)
    return ok and true or false
end

-- Creates one pooled, non-interactive coloured map marker. The historically
-- successful geometry is a 14x14 Button with one BACKGROUND texture stretched
-- across it. Numeric solid textures later became logically present but
-- visually unreliable, so the surface uses the client-confirmed built-in
-- white texture and applies the marker colour as a vertex tint.
local WORLD_MAP_PIN_TEXTURE = "Interface\\Buttons\\WHITE8X8"
-- Extensionless, like the two texture paths above it: this client resolves an
-- addon texture by base name, and the ".tga" spelling silently drew nothing.
local TRACKER_RESIZE_GRIP_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\resize"

function Client.CreateWorldMapPin(index, red, green, blue)
    local canvas = Client.GetWorldMapCanvas()
    local create = Resolve("CreateFrame")
    if not canvas or not create or type(index) ~= "number" then
        return nil
    end
    local name = "UnrealQuestWorldMapPin" .. tostring(index)
    local ok, frame = pcall(create, "Button", name, canvas)
    if not ok or not frame then
        return nil
    end
    if type(frame.SetWidth) == "function" then pcall(frame.SetWidth, frame, 14) end
    if type(frame.SetHeight) == "function" then pcall(frame.SetHeight, frame, 14) end
    if type(canvas.GetFrameLevel) == "function" and type(frame.SetFrameLevel) == "function" then
        local levelOk, level = pcall(canvas.GetFrameLevel, canvas)
        if levelOk and type(level) == "number" then
            local pinLevel = level + 20
            if pinLevel < 120 then pinLevel = 120 end
            pcall(frame.SetFrameLevel, frame, pinLevel)
        else
            pcall(frame.SetFrameLevel, frame, 120)
        end
    end
    if type(frame.CreateTexture) == "function" then
        local textureOk, texture = pcall(frame.CreateTexture, frame, nil, "BACKGROUND")
        if textureOk and texture then
            frame.unrealQuestTexture = texture
            if type(texture.SetAllPoints) == "function" then
                pcall(texture.SetAllPoints, texture, frame)
            end
            if type(texture.SetTexture) == "function" then
                pcall(texture.SetTexture, texture, WORLD_MAP_PIN_TEXTURE)
            end
            if type(texture.SetVertexColor) == "function" then
                pcall(texture.SetVertexColor, texture, red or 1, green or 0.8, blue or 0)
            end
        end
    end
    return frame
end

function Client.SetWorldMapPinColor(frame, red, green, blue)
    local texture = frame and frame.unrealQuestTexture
    if not texture then
        return false
    end
    if type(texture.SetVertexColor) == "function" then
        local ok = pcall(texture.SetVertexColor, texture, red or 1, green or 0.8, blue or 0)
        return ok and true or false
    end
    if type(texture.SetTexture) ~= "function" then
        return false
    end
    local ok = pcall(texture.SetTexture, texture, red or 1, green or 0.8, blue or 0, 1)
    return ok and true or false
end

-- Draws a pin's icon in greyscale.
--
-- SetVertexColor cannot do this: it multiplies the texture per channel, so a
-- yellow "?" scaled down stays yellow and merely gets darker -- which is what
-- the "in progress" turn-in marker looked like, and what it was reported as.
-- Texture:SetDesaturated is the documented greyscale switch on this client
-- (OFFICIAL_CLIENT_DOCUMENTATION, DOCUMENTED_NOT_RUNTIME_VERIFIED) and is
-- specified to return true.
--
-- The return value is honoured rather than assumed: a client that has the
-- method but cannot desaturate is documented elsewhere to return false, and
-- the caller needs to know so it can fall back to dimming instead of leaving
-- an in-progress marker indistinguishable from a ready one.
-- The capability can only be settled against a real texture, so it is recorded
-- on first use rather than at load like the plain globals below.
local desaturationDeclared = false

local function DeclareDesaturation(state, note)
    if desaturationDeclared then
        return
    end
    desaturationDeclared = true
    UQ:DeclareCapability("worldMapPinDesaturation", state, note)
end

function Client.SetWorldMapPinDesaturated(frame, desaturated)
    local texture = frame and frame.unrealQuestTexture
    if not texture or type(texture.SetDesaturated) ~= "function" then
        DeclareDesaturation("missing",
            "Texture:SetDesaturated is not a method on an addon-owned map pin texture; an in-progress "
            .. "turn-in \"?\" falls back to a dimmed vertex colour, which cannot make it grey")
        return false
    end
    local ok, applied = pcall(texture.SetDesaturated, texture, desaturated and true or false)
    if not ok then
        DeclareDesaturation("missing",
            "Texture:SetDesaturated exists but faulted when called on a map pin texture")
        return false
    end
    -- nil comes back from implementations that return nothing on success; only
    -- an explicit false means the client refused.
    if applied == false then
        DeclareDesaturation("missing",
            "Texture:SetDesaturated returned false on a map pin texture; the client has the method but "
            .. "will not draw this texture in greyscale")
        return false
    end
    DeclareDesaturation("detected",
        "Texture:SetDesaturated accepted on an addon-owned map pin texture; used to draw the \"?\" of a "
        .. "quest that is not ready to hand in in real greyscale rather than as a darker yellow")
    return true
end

-- Creates the quest number lazily so area tiles, which reuse the same base
-- surface constructor, do not allocate unused text objects. The exact
-- GameFontNormalSmall overlay contract was confirmed in game by the isolated
-- questarea label and gridmarker50 probes.
function Client.SetWorldMapPinLabel(frame, text)
    if not frame then
        return false
    end
    local label = frame.unrealQuestLabel
    if not label then
        if type(frame.CreateFontString) ~= "function" then
            return false
        end
        local createOk, created = pcall(
            frame.CreateFontString, frame, nil, "OVERLAY", "GameFontNormalSmall")
        if not createOk or not created then
            return false
        end
        label = created
        frame.unrealQuestLabel = label
        if type(label.SetAllPoints) == "function" then
            pcall(label.SetAllPoints, label, frame)
        end
        if type(label.SetJustifyH) == "function" then
            pcall(label.SetJustifyH, label, "CENTER")
        end
        if type(label.SetJustifyV) == "function" then
            pcall(label.SetJustifyV, label, "MIDDLE")
        end
        if type(label.SetTextColor) == "function" then
            pcall(label.SetTextColor, label, 0.05, 0.05, 0.05)
        end
    end
    if type(label.SetText) ~= "function" then
        return false
    end
    local ok = pcall(label.SetText, label, tostring(text or ""))
    return ok and true or false
end

-- Areas deliberately reuse the same proven Button + file-backed BACKGROUND
-- texture construction as pins. Blue tint, variable geometry and 0.5 texture
-- alpha are all confirmed on the fullscreen map by sequential runtime probes.
function Client.CreateWorldMapArea(index, red, green, blue, alpha)
    local frame = Client.CreateWorldMapPin(index + 500, red, green, blue)
    if not frame then
        return nil
    end
    local texture = frame.unrealQuestTexture
    if texture and type(texture.SetAlpha) == "function" then
        pcall(texture.SetAlpha, texture, alpha or 0.5)
    end
    return frame
end

function Client.SetWorldMapAreaColor(frame, red, green, blue, alpha)
    local colored = Client.SetWorldMapPinColor(frame, red, green, blue)
    local texture = frame and frame.unrealQuestTexture
    if texture and type(texture.SetAlpha) == "function" then
        local ok = pcall(texture.SetAlpha, texture, alpha or 0.5)
        return colored and ok and true or false
    end
    return false
end

function Client.PositionWorldMapArea(frame, x, y, widthPercent, heightPercent)
    local canvas = Client.GetWorldMapCanvas()
    if not frame or not canvas or type(widthPercent) ~= "number"
        or type(heightPercent) ~= "number" then
        return false
    end
    local widthOk, width = pcall(canvas.GetWidth, canvas)
    local heightOk, height = pcall(canvas.GetHeight, canvas)
    if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return false
    end
    if type(frame.SetWidth) ~= "function" or type(frame.SetHeight) ~= "function" then
        return false
    end
    local pixelWidth = width * widthPercent / 100
    local pixelHeight = height * heightPercent / 100
    if pixelWidth < 14 then pixelWidth = 14 end
    if pixelHeight < 14 then pixelHeight = 14 end
    local sizeOk = pcall(frame.SetWidth, frame, pixelWidth)
    if sizeOk then
        sizeOk = pcall(frame.SetHeight, frame, pixelHeight)
    end
    if not sizeOk then
        return false
    end
    local positioned = Client.PositionWorldMapPin(frame, x, y)
    if positioned then
        frame.unrealQuestAreaWidthPercent = widthPercent
        frame.unrealQuestAreaHeightPercent = heightPercent
    end
    return positioned
end

-- Places a pooled area frame as a FIXED-PIXEL dot instead of a canvas-relative
-- cell, which is what the world map's second objective presentation
-- ("mapObjectiveDots") draws: the same quest scene as the blue tiles, shown as
-- one point per spawn in the minimap's own style.
--
-- Clearing the two area percentages is the load-bearing half. Client.ReapplyWorldMapPin
-- resizes anything still carrying them back to a percentage of the canvas on
-- every stable tick, so a dot that kept them would be stretched back into a
-- tile within one refresh interval.
function Client.PositionWorldMapDot(frame, x, y, size)
    if not frame or type(size) ~= "number" or size <= 0 then
        return false
    end
    frame.unrealQuestAreaWidthPercent = nil
    frame.unrealQuestAreaHeightPercent = nil
    if not Client.SetWorldMapPinSize(frame, size, size) then
        return false
    end
    return Client.PositionWorldMapPin(frame, x, y)
end

local function ReadObjectMethod(object, methodName)
    local method = object and object[methodName]
    if type(method) ~= "function" then
        return nil
    end
    local ok, value = pcall(method, object)
    if not ok then
        return nil
    end
    return value
end

local function ObjectToken(object)
    if not object then
        return ""
    end
    local ok, value = pcall(tostring, object)
    if not ok or type(value) ~= "string" then
        return ""
    end
    return value
end

function Client.GetWorldMapPinSnapshot(frame)
    local canvas = Client.GetWorldMapCanvas()
    local texture = frame and frame.unrealQuestTexture
    local parent = ReadObjectMethod(frame, "GetParent")
    return {
        canvasToken = ObjectToken(canvas),
        canvasWidth = ReadObjectMethod(canvas, "GetWidth"),
        canvasHeight = ReadObjectMethod(canvas, "GetHeight"),
        canvasLevel = ReadObjectMethod(canvas, "GetFrameLevel"),
        canvasShown = ReadObjectMethod(canvas, "IsShown") and true or false,
        canvasVisible = ReadObjectMethod(canvas, "IsVisible") and true or false,
        canvasLeft = ReadObjectMethod(canvas, "GetLeft"),
        canvasTop = ReadObjectMethod(canvas, "GetTop"),
        pinType = ReadObjectMethod(frame, "GetObjectType"),
        pinWidth = ReadObjectMethod(frame, "GetWidth"),
        pinHeight = ReadObjectMethod(frame, "GetHeight"),
        pinLevel = ReadObjectMethod(frame, "GetFrameLevel"),
        pinAlpha = ReadObjectMethod(frame, "GetAlpha"),
        pinShown = ReadObjectMethod(frame, "IsShown") and true or false,
        pinVisible = ReadObjectMethod(frame, "IsVisible") and true or false,
        pinLeft = ReadObjectMethod(frame, "GetLeft"),
        pinTop = ReadObjectMethod(frame, "GetTop"),
        parentToken = ObjectToken(parent),
        parentMatches = parent == canvas,
        textureLayer = ReadObjectMethod(texture, "GetDrawLayer"),
        textureAlpha = ReadObjectMethod(texture, "GetAlpha"),
        textureShown = ReadObjectMethod(texture, "IsShown") and true or false,
        textureVisible = ReadObjectMethod(texture, "IsVisible") and true or false,
        textureHasPath = ReadObjectMethod(texture, "GetTexture") ~= nil,
    }
end

function Client.PositionWorldMapPin(frame, x, y)
    local canvas = Client.GetWorldMapCanvas()
    if not frame or not canvas or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    local widthOk, width = pcall(canvas.GetWidth, canvas)
    local heightOk, height = pcall(canvas.GetHeight, canvas)
    if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return false
    end
    if type(frame.ClearAllPoints) ~= "function" or type(frame.SetPoint) ~= "function"
        or type(frame.Show) ~= "function" then
        return false
    end
    pcall(frame.ClearAllPoints, frame)
    local pointOk = pcall(frame.SetPoint, frame, "CENTER", canvas, "TOPLEFT", x * width, -y * height)
    if not pointOk then
        return false
    end
    -- A hover-suppressed marker still takes its point, so nothing about its
    -- placement drifts while it is withheld; only the Show is skipped.
    if frame.unrealQuestSuppressed then
        pcall(frame.Hide, frame)
    else
        local showOk = pcall(frame.Show, frame)
        if not showOk then
            return false
        end
    end
    frame.unrealQuestMapX = x
    frame.unrealQuestMapY = y
    return true
end

-- The fullscreen map can redraw after an addon child has already been
-- positioned. Reapplying the exact confirmed point forces that child back
-- through the map's draw path without changing its visual contract.
function Client.ReapplyWorldMapPin(frame)
    if not frame or type(frame.unrealQuestMapX) ~= "number"
        or type(frame.unrealQuestMapY) ~= "number" then
        return false
    end
    if type(frame.unrealQuestAreaWidthPercent) == "number"
        and type(frame.unrealQuestAreaHeightPercent) == "number" then
        return Client.PositionWorldMapArea(frame, frame.unrealQuestMapX,
            frame.unrealQuestMapY, frame.unrealQuestAreaWidthPercent,
            frame.unrealQuestAreaHeightPercent)
    end
    return Client.PositionWorldMapPin(frame, frame.unrealQuestMapX,
        frame.unrealQuestMapY)
end

-- World-map pin interaction --------------------------------------------------
-- Mouse scripts and GameTooltip are documented on this client (GameTooltip's
-- backdrop/text-rebuild behaviour is measured) but a custom Button pin
-- driving GameTooltip via SetOwner has no runtime record of its own. Wrapped
-- the same defensive way as the rest of this file: every step is pcall-guarded
-- so a failure here only means no tooltip, never a fault.

-- Withholds one marker's visibility without giving up its pooled slot, its
-- colour or its resolved map position. The flag has to be honoured by the
-- placement path itself: stable driver ticks re-apply every visible pin's
-- point and re-applying a point calls Show, so a plain Hide would be undone
-- within one refresh interval.
function Client.SetWorldMapPinSuppressed(frame, suppressed)
    if not frame then
        return false
    end
    if suppressed then
        frame.unrealQuestSuppressed = true
        return Client.HideObject(frame)
    end
    frame.unrealQuestSuppressed = nil
    return true
end

function Client.SetWorldMapPinHandlers(frame, onEnter, onLeave, onClick)
    if not frame or type(frame.SetScript) ~= "function" then
        return false
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    -- RegisterForClicks is documented here as *appending* the mouse-button
    -- tokens that may fire OnClick, which leaves the default set for a
    -- CreateFrame("Button") unstated rather than guaranteed. The installed
    -- pfQuest drives its own 14x14 map nodes from a bare SetScript("OnClick")
    -- with no registration, so the default is evidently non-empty -- but that
    -- is prior art, not a measurement of this client, and registering the
    -- token we actually rely on costs one guarded call and removes the
    -- assumption. Only done when a handler is supplied, so the mouse-aware
    -- but deliberately click-free area tiles keep taking no click tokens.
    if onClick and type(frame.RegisterForClicks) == "function" then
        pcall(frame.RegisterForClicks, frame, "LeftButtonUp")
    end
    pcall(frame.SetScript, frame, "OnEnter", onEnter)
    pcall(frame.SetScript, frame, "OnLeave", onLeave)
    pcall(frame.SetScript, frame, "OnClick", onClick)
    return true
end

-- Lifts one pooled map child above its siblings in the hit-test order.
--
-- Every pooled child -- quest markers, area tiles and giver "!" pins alike --
-- is created by the one constructor above, and the pool index only shapes the
-- frame NAME, never the level. So they all land on exactly the same
-- max(canvasLevel + 20, 120), which the live SavedVariables confirms as 120
-- for all of them. Two mouse-enabled siblings at the SAME frame level leave
-- which one receives a click to draw order rather than to intent, and the
-- area tile takes the mouse (it needs OnEnter for its tooltip) while
-- deliberately having no OnClick -- so a click landing on it is delivered to
-- a frame that ignores clicks and the gesture silently does nothing.
--
-- Raising the pin keeps the confirmed ">= 120" half of the rendering contract
-- in docs/WORLD-MAP-PINS-RECOVERY.md; only the tie against the tiles changes.
function Client.RaiseWorldMapPin(frame, extraLevels)
    if not frame or type(frame.GetFrameLevel) ~= "function"
        or type(frame.SetFrameLevel) ~= "function" then
        return false
    end
    local ok, level = pcall(frame.GetFrameLevel, frame)
    if not ok or type(level) ~= "number" then
        return false
    end
    local raised = pcall(frame.SetFrameLevel, frame, level + (extraLevels or 1))
    return raised and true or false
end

-- The fullscreen map owns its own tooltip frame. The installed pfQuest source
-- selects it by parent -- WorldMapTooltip for a WorldMapButton child,
-- GameTooltip otherwise -- which is prior art, not evidence about this client,
-- so the name is resolved defensively and GameTooltip remains the fallback.
-- Which one was actually used is reported through Client.GetMapTooltipName so
-- a silent tooltip can be diagnosed from SavedVariables rather than a
-- screenshot.
local mapTooltipName = nil

local function ResolveMapTooltip()
    local worldMap = ResolveObject("WorldMapTooltip")
    if worldMap and type(worldMap.SetOwner) == "function" then
        mapTooltipName = "WorldMapTooltip"
        return worldMap
    end
    local game = ResolveObject("GameTooltip")
    if game and type(game.SetOwner) == "function" then
        mapTooltipName = "GameTooltip"
        return game
    end
    mapTooltipName = "none"
    return nil
end

function Client.GetMapTooltipName()
    return mapTooltipName or "unresolved"
end

-- Flat tooltip styling ------------------------------------------------------
--
-- Matches unrealUI's tooltip look exactly -- near-black flat fill, one thin
-- dark outline, no stock bevel -- but reproduces it independently rather than
-- calling into that addon, so UnrealQuest keeps no runtime dependency on it.
-- The values below are the same ones unrealUI uses (core/media.lua colours,
-- core/style.lua construction).
--
-- Two client behaviours drive the construction, both recorded by unrealUI as
-- confirmed in game:
--   * A backdrop table that omits edgeFile replaces the fill but leaves the
--     frame's stock edge art drawing on top, and that art is not an
--     enumerable region. Only SetBackdropBorderColor with zero alpha removes
--     it.
--   * A fractional backdrop edgeSize is not reliably rasterized here, so the
--     outline is drawn from four plain textures at one full draw unit rather
--     than requested through the backdrop.

local FLAT_BACKGROUND = { 0.06, 0.06, 0.06, 0.85 }
local FLAT_BORDER = { 0.16, 0.16, 0.16, 1.00 }
local FLAT_BORDER_THICKNESS = 1

local FLAT_EDGES = {
    { "TOPLEFT", "TOPRIGHT", "horizontal" },
    { "BOTTOMLEFT", "BOTTOMRIGHT", "horizontal" },
    { "TOPLEFT", "BOTTOMLEFT", "vertical" },
    { "TOPRIGHT", "BOTTOMRIGHT", "vertical" },
}

local function BuildFlatBorder(frame)
    if frame.unrealQuestEdges or type(frame.CreateTexture) ~= "function" then
        return
    end
    local edges = {}
    local index = 1
    local total = table.getn(FLAT_EDGES)
    while index <= total do
        local anchor = FLAT_EDGES[index]
        local ok, edge = pcall(frame.CreateTexture, frame, nil, "OVERLAY")
        if not ok or not edge then
            return
        end
        pcall(edge.SetTexture, edge, WORLD_MAP_PIN_TEXTURE)
        pcall(edge.SetVertexColor, edge, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], FLAT_BORDER[4])
        pcall(edge.SetPoint, edge, anchor[1], frame, anchor[1], 0, 0)
        pcall(edge.SetPoint, edge, anchor[2], frame, anchor[2], 0, 0)
        if anchor[3] == "horizontal" then
            pcall(edge.SetHeight, edge, FLAT_BORDER_THICKNESS)
        else
            pcall(edge.SetWidth, edge, FLAT_BORDER_THICKNESS)
        end
        edges[index] = edge
        index = index + 1
    end
    frame.unrealQuestEdges = edges
end

local function SetFlatBorderColor(frame, red, green, blue, alpha)
    local edges = frame and frame.unrealQuestEdges
    if not edges then
        return
    end
    local index = 1
    local total = table.getn(edges)
    while index <= total do
        pcall(edges[index].SetVertexColor, edges[index], red, green, blue, alpha)
        index = index + 1
    end
end

-- The stock corner art lives on numbered Texture regions named after the
-- tooltip itself; unrealUI measured exactly three on this client's tooltip.
local function HideStockTooltipArt(tooltipName)
    if type(tooltipName) ~= "string" then
        return
    end
    local index = 1
    while index <= 3 do
        local region = ResolveObject(tooltipName .. "Texture" .. index)
        if region and type(region.SetTexture) == "function" then
            pcall(region.SetTexture, region, nil)
        end
        index = index + 1
    end
end

-- Idempotent, and cheap enough to run on every tooltip show: the native edge
-- art comes back whenever the frame repopulates, so styling once at load is a
-- recorded failed approach.
function Client.ApplyFlatTooltipStyle(frame, tooltipName)
    if not frame then
        return false
    end
    if type(frame.SetBackdrop) == "function" then
        local ok = pcall(frame.SetBackdrop, frame, {
            bgFile = WORLD_MAP_PIN_TEXTURE,
            tile = false,
            tileSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        if ok and type(frame.SetBackdropColor) == "function" then
            pcall(frame.SetBackdropColor, frame, FLAT_BACKGROUND[1], FLAT_BACKGROUND[2],
                FLAT_BACKGROUND[3], FLAT_BACKGROUND[4])
        end
    end
    if type(frame.SetBackdropBorderColor) == "function" then
        pcall(frame.SetBackdropBorderColor, frame, 0, 0, 0, 0)
    end
    BuildFlatBorder(frame)
    HideStockTooltipArt(tooltipName)
    return true
end

-- Hides every pooled separator texture from a previous ShowMapTooltip call.
-- GameTooltip:ClearLines wipes font strings but not textures a caller created
-- on the frame, so leftover separators from a prior, longer tooltip would
-- otherwise keep drawing under whatever now occupies that row.
local function HideMapTooltipSeparators(tooltip)
    local pool = tooltip.unrealQuestSeparators
    if not pool then
        return
    end
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        pcall(pool[index].Hide, pool[index])
        index = index + 1
    end
end

-- Returns the Nth pooled separator texture, creating it the first time it is
-- needed and reusing it on every later call -- the same pool-and-reuse shape
-- as BuildFlatBorder's edges, just sized to the tallest tooltip seen so far
-- instead of a fixed four.
local function GetMapTooltipSeparator(tooltip, poolIndex)
    if type(tooltip.CreateTexture) ~= "function" then
        return nil
    end
    local pool = tooltip.unrealQuestSeparators
    if not pool then
        pool = {}
        tooltip.unrealQuestSeparators = pool
    end
    local tex = pool[poolIndex]
    if not tex then
        local ok, created = pcall(tooltip.CreateTexture, tooltip, nil, "OVERLAY")
        if not ok or not created then
            return nil
        end
        pcall(created.SetTexture, created, WORLD_MAP_PIN_TEXTURE)
        pcall(created.SetVertexColor, created, 0.5, 0.5, 0.5, 1)
        pcall(created.SetHeight, created, 1)
        pool[poolIndex] = created
        tex = created
    end
    return tex
end

-- Each entry is either a single line { text, r, g, b, wrap }, a label/value
-- pair { left, right, r, g, b, rightR, rightG, rightB }, or a divider
-- { separator = true }. The first entry becomes the tooltip title through
-- SetText; the rest are appended. A separator reserves a blank row and draws
-- a 1px grey line under it, spanning the tooltip -- used to break up several
-- quests' worth of lines stacked in one tooltip.
-- anchor lets a caller steer the tooltip away from something it would
-- otherwise sit on top of (a highlighted quest area, for the turn-in "?");
-- every existing caller that omits it keeps the original ANCHOR_RIGHT.
--
-- Shared by Client.ShowMapTooltip and Client.ShowGameTooltip below: the
-- content shape and the flat-styling call are identical either way, only
-- which tooltip OBJECT gets decorated differs, and that choice is already
-- made by the caller before this runs.
local function RenderTooltipLines(tooltip, tooltipName, frame, lines, anchor)
    local ok = pcall(tooltip.SetOwner, tooltip, frame, anchor or "ANCHOR_RIGHT")
    if not ok then
        return false
    end
    if type(tooltip.ClearLines) == "function" then
        pcall(tooltip.ClearLines, tooltip)
    end
    HideMapTooltipSeparators(tooltip)

    local separatorRows = {}
    local index = 1
    local total = table.getn(lines or {})
    while index <= total do
        local line = lines[index]
        if line then
            if line.separator then
                if type(tooltip.AddLine) == "function" then
                    pcall(tooltip.AddLine, tooltip, " ", 1, 1, 1)
                    table.insert(separatorRows, index)
                end
            elseif type(line.left) == "string" and type(tooltip.AddDoubleLine) == "function" then
                pcall(tooltip.AddDoubleLine, tooltip, line.left, line.right or "",
                    line.r or 0.8, line.g or 0.8, line.b or 0.8,
                    line.rightR or 1, line.rightG or 1, line.rightB or 1)
            elseif type(line.left) == "string" and type(tooltip.AddLine) == "function" then
                -- AddDoubleLine is documented but not runtime-verified here.
                pcall(tooltip.AddLine, tooltip, line.left .. " " .. tostring(line.right or ""),
                    line.r or 0.8, line.g or 0.8, line.b or 0.8)
            elseif type(line.text) == "string" then
                if index == 1 and type(tooltip.SetText) == "function" then
                    pcall(tooltip.SetText, tooltip, line.text, line.r, line.g, line.b)
                elseif type(tooltip.AddLine) == "function" then
                    pcall(tooltip.AddLine, tooltip, line.text, line.r, line.g, line.b, line.wrap)
                end
            end
        end
        index = index + 1
    end

    local sIndex = 1
    local sTotal = table.getn(separatorRows)
    while sIndex <= sTotal do
        local row = separatorRows[sIndex]
        local rowLabel = ResolveObject((tooltipName or "") .. "TextLeft" .. row)
        local tex = GetMapTooltipSeparator(tooltip, sIndex)
        if rowLabel and tex then
            pcall(tex.ClearAllPoints, tex)
            pcall(tex.SetPoint, tex, "LEFT", tooltip, "LEFT", 8, 0)
            pcall(tex.SetPoint, tex, "RIGHT", tooltip, "RIGHT", -8, 0)
            pcall(tex.SetPoint, tex, "TOP", rowLabel, "TOP", 0, 0)
            pcall(tex.Show, tex)
        end
        sIndex = sIndex + 1
    end

    -- Styled after the content is in place and before the frame is shown: the
    -- stock edge art returns whenever the tooltip repopulates, so this cannot
    -- be done once at load.
    Client.ApplyFlatTooltipStyle(tooltip, tooltipName)

    if type(tooltip.Show) == "function" then
        pcall(tooltip.Show, tooltip)
    end
    return true
end

function Client.ShowMapTooltip(frame, lines, anchor)
    local tooltip = ResolveMapTooltip()
    if not tooltip or not frame then
        return false
    end
    return RenderTooltipLines(tooltip, mapTooltipName, frame, lines, anchor)
end

function Client.HideMapTooltip(frame)
    local tooltip = ResolveMapTooltip()
    if not tooltip then
        return false
    end
    if frame and type(tooltip.IsOwned) == "function" then
        local ok, owned = pcall(tooltip.IsOwned, tooltip, frame)
        if ok and not owned then
            return false
        end
    end
    if type(tooltip.Hide) == "function" then
        pcall(tooltip.Hide, tooltip)
    end
    return true
end

-- A plain-GameTooltip twin of Client.ShowMapTooltip, for content anchored
-- anywhere OTHER than the fullscreen map's own canvas (the quest tracker
-- window, in particular). Deliberately does NOT go through
-- ResolveMapTooltip/ResolveMapTooltip's WorldMapTooltip preference: that
-- preference exists because GameTooltip anchored to a WorldMapButton CHILD
-- was confirmed to render nothing while WorldMapTooltip, on the same child,
-- worked (worldmap.custom_pin_gametooltip_never_appeared) -- a finding about
-- the map canvas specifically, not about GameTooltip in general. GameTooltip
-- is the tooltip already confirmed working elsewhere on this client outside
-- that context (Tooltip/EntityTooltip.lua), so it is used directly.
function Client.ShowGameTooltip(frame, lines, anchor)
    local tooltip = ResolveGameTooltip()
    if not tooltip or not frame then
        return false
    end
    return RenderTooltipLines(tooltip, "GameTooltip", frame, lines, anchor)
end

function Client.HideGameTooltip(frame)
    local tooltip = ResolveGameTooltip()
    if not tooltip then
        return false
    end
    if frame and type(tooltip.IsOwned) == "function" then
        local ok, owned = pcall(tooltip.IsOwned, tooltip, frame)
        if ok and not owned then
            return false
        end
    end
    if type(tooltip.Hide) == "function" then
        pcall(tooltip.Hide, tooltip)
    end
    return true
end

-- Giver quest-picker menu -----------------------------------------------
-- Opened by shift- or Ctrl-clicking a "!" that offers more than one quest:
-- one row per quest, so the player picks which single quest to mark done
-- rather than the click silently taking every quest on that pin with it.
-- A pin offering exactly one quest has nothing to disambiguate and is marked
-- directly, with no menu -- see WorldMapPins:OnGiverClick.
--
-- Built from the same CreateFrame/CreateTexture/CreateFontString primitives
-- already confirmed working for every other pooled map child in this file
-- (Client.CreateWorldMapPin, Client.CreateWaypointMarker) rather than the
-- client's native dropdown menu -- query_compat.py has no runtime record at
-- all of ToggleDropDownMenu, UIDropDownMenu or any *DropDown global on this
-- client, so that surface stays unverified and unused.
--
-- One pooled frame, reused for whichever giver last opened it: only one menu
-- can usefully be open at a time, the same singleton shape as the map
-- tooltip.
--
-- Three things about this menu are corrections of a measured first attempt
-- that opened and vanished within a few frames, and none may be reintroduced:
--
--   * Its frame level must clear the PINS, not the canvas. Every pooled map
--     child lands on max(canvasLevel + 20, 120) -- confirmed as 120 in the
--     live SavedVariables -- and a giver "!" is raised above that again. A
--     menu built at canvasLevel + a small offset therefore opens UNDERNEATH
--     the pins and tiles it was summoned from. GIVER_MENU_LEVEL_BOOST is
--     applied to PinFloorLevel(), the same floor the pins use, never to the
--     raw canvas level.
--   * It must NOT close on its own OnLeave. The menu opens beside the pin
--     rather than under the cursor, so the pointer is never inside it to
--     begin with, and moving onto one of its own child rows reads as leaving
--     the parent -- either one fires OnLeave and hides the menu instantly.
--   * A click meant to dismiss the menu (anywhere else on the map) must not
--     also land on whatever pin or tile is under it -- an outside click that
--     both closes the menu and marks a different quest done is worse than
--     the menu staying open. GIVER_MENU_CATCHER_LEVEL sits between the pins
--     and the menu for exactly that: it swallows the first click outside the
--     menu instead of letting it fall through to the map underneath.
--
-- Closing overall: picking a row, the menu's own "Close" row, clicking the
-- same "!" again to toggle, clicking anywhere else on the map (the catcher),
-- or hovering a different giver.
local GIVER_MENU_ROW_HEIGHT = 18
local GIVER_MENU_WIDTH = 220
local GIVER_MENU_PADDING = 6
local GIVER_MENU_LEVEL_BOOST = 30
local GIVER_MENU_CATCHER_LEVEL_BOOST = 20
local giverMenuFrame = nil
local giverMenuRows = {}
local giverMenuCatcher = nil

-- The floor Client.CreateWorldMapPin's pins sit on: max(canvasLevel + 20, 120),
-- the same 120 the live SavedVariables confirmed. Shared so the menu, its
-- rows and its outside-click catcher all measure "above the pins" from the
-- same number instead of three separately guessed ones.
local function PinFloorLevel(canvas)
    local level = 120
    if canvas and type(canvas.GetFrameLevel) == "function" then
        local ok, canvasLevel = pcall(canvas.GetFrameLevel, canvas)
        if ok and type(canvasLevel) == "number" and canvasLevel + 20 > level then
            level = canvasLevel + 20
        end
    end
    return level
end

local function ResolveGiverMenu()
    if giverMenuFrame then
        return giverMenuFrame
    end
    local canvas = Client.GetWorldMapCanvas()
    local create = Resolve("CreateFrame")
    if not canvas or not create then
        return nil
    end
    local ok, frame = pcall(create, "Frame", "UnrealQuestGiverMenu", canvas)
    if not ok or not frame then
        return nil
    end
    if type(frame.SetFrameLevel) == "function" then
        pcall(frame.SetFrameLevel, frame, PinFloorLevel(canvas) + GIVER_MENU_LEVEL_BOOST)
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    pcall(frame.Hide, frame)
    giverMenuFrame = frame
    return frame
end

-- One transparent, canvas-sized Button beneath the menu and above every pin.
-- The same "invisible click-catching Button" primitive Client.CreateClickSurface
-- already uses for the HUD tracker's unclickable FontString lines, applied at
-- map-canvas size instead of over one native region.
local function ResolveGiverMenuCatcher()
    if giverMenuCatcher then
        return giverMenuCatcher
    end
    local canvas = Client.GetWorldMapCanvas()
    local create = Resolve("CreateFrame")
    if not canvas or not create then
        return nil
    end
    local ok, frame = pcall(create, "Button", "UnrealQuestGiverMenuCatcher", canvas)
    if not ok or not frame then
        return nil
    end
    if type(frame.SetFrameLevel) == "function" then
        pcall(frame.SetFrameLevel, frame, PinFloorLevel(canvas) + GIVER_MENU_CATCHER_LEVEL_BOOST)
    end
    if type(frame.SetAllPoints) == "function" then
        pcall(frame.SetAllPoints, frame, canvas)
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    if type(frame.RegisterForClicks) == "function" then
        pcall(frame.RegisterForClicks, frame, "LeftButtonUp", "RightButtonUp")
    end
    pcall(frame.SetScript, frame, "OnClick", function() Client.HideGiverQuestMenu() end)
    pcall(frame.Hide, frame)
    giverMenuCatcher = frame
    return frame
end

local function GetGiverMenuRow(rowIndex)
    local menu = ResolveGiverMenu()
    if not menu then
        return nil
    end
    local row = giverMenuRows[rowIndex]
    if row then
        return row
    end
    local create = Resolve("CreateFrame")
    if not create then
        return nil
    end
    local ok, button = pcall(create, "Button", "UnrealQuestGiverMenuRow" .. tostring(rowIndex), menu)
    if not ok or not button then
        return nil
    end
    -- Explicit, not inherited: a row has to win the mouse over the menu's own
    -- background and over the outside-click catcher beneath it, and this file
    -- does not rely on a child frame's default level for anything else either.
    if type(button.SetFrameLevel) == "function" and type(menu.GetFrameLevel) == "function" then
        local levelOk, menuLevel = pcall(menu.GetFrameLevel, menu)
        if levelOk and type(menuLevel) == "number" then
            pcall(button.SetFrameLevel, button, menuLevel + 1)
        end
    end
    pcall(button.SetWidth, button, GIVER_MENU_WIDTH - GIVER_MENU_PADDING * 2)
    pcall(button.SetHeight, button, GIVER_MENU_ROW_HEIGHT)
    if type(button.CreateFontString) == "function" then
        local labelOk, label = pcall(
            button.CreateFontString, button, nil, "OVERLAY", "GameFontHighlightSmall")
        if labelOk and label then
            pcall(label.SetPoint, label, "LEFT", button, "LEFT", 2, 0)
            pcall(label.SetJustifyH, label, "LEFT")
            button.unrealQuestLabel = label
            if type(button.SetFontString) == "function" then
                pcall(button.SetFontString, button, label)
            end
        end
    end
    if type(button.SetHighlightTexture) == "function" then
        pcall(button.SetHighlightTexture, button, WORLD_MAP_PIN_TEXTURE, "ADD")
    end
    giverMenuRows[rowIndex] = button
    return button
end

-- Places one already-pooled row and gives it its text, colour and handler.
-- Colour is written on EVERY show, never only when a row is first created:
-- rows are pooled by position, so the greyed "Close" row at the bottom of a
-- three-quest menu becomes an ordinary quest row in the next four-quest one
-- and would otherwise still be wearing the grey.
local function LayOutGiverMenuRow(menu, row, slot, text, red, green, blue, onClick)
    if not row then
        return
    end
    if row.unrealQuestLabel then
        pcall(row.unrealQuestLabel.SetTextColor, row.unrealQuestLabel, red, green, blue)
        pcall(row.unrealQuestLabel.SetText, row.unrealQuestLabel,
            type(text) == "string" and text or "?")
    end
    pcall(row.ClearAllPoints, row)
    pcall(row.SetPoint, row, "TOPLEFT", menu, "TOPLEFT",
        GIVER_MENU_PADDING, -(GIVER_MENU_PADDING + (slot - 1) * GIVER_MENU_ROW_HEIGHT))
    pcall(row.SetScript, row, "OnClick", onClick)
    pcall(row.Show, row)
end

-- entries is a list of { id = questId, text = title }. onSelect(entry) runs
-- when a row is clicked and receives the whole entry, so the caller can tell
-- a quest row from the synthesised "mark them all" row (which carries
-- all = true and no id). The caller owns hiding the menu afterwards
-- (Client.HideGiverQuestMenu), same as any other click handler in this file.
function Client.ShowGiverQuestMenu(anchorFrame, entries, onSelect)
    local menu = ResolveGiverMenu()
    if not menu or not anchorFrame or type(entries) ~= "table" then
        return false
    end
    local total = table.getn(entries)
    if total <= 0 then
        return false
    end

    local function Select(entry)
        return function()
            if type(onSelect) == "function" then
                onSelect(entry)
            end
        end
    end

    local slot = 1
    while slot <= total do
        local entry = entries[slot]
        if entry then
            LayOutGiverMenuRow(menu, GetGiverMenuRow(slot), slot,
                entry.text, 1, 0.82, 0, Select(entry))
        end
        slot = slot + 1
    end

    -- Keeps the old bulk gesture reachable now that a multi-quest click asks
    -- instead of assuming: same effect the unconditional shift-click had.
    LayOutGiverMenuRow(menu, GetGiverMenuRow(total + 1), total + 1,
        "Mark all as done", 0.8, 0.8, 0.8, Select({ all = true }))

    LayOutGiverMenuRow(menu, GetGiverMenuRow(total + 2), total + 2,
        "Close", 0.5, 0.5, 0.5, function() Client.HideGiverQuestMenu() end)

    -- A row pool can only grow across the session, so a shorter menu than
    -- last time leaves stale rows below it that must be hidden explicitly.
    local extra = total + 3
    while giverMenuRows[extra] do
        pcall(giverMenuRows[extra].Hide, giverMenuRows[extra])
        extra = extra + 1
    end

    local rowCount = total + 2
    if type(menu.SetWidth) == "function" then
        pcall(menu.SetWidth, menu, GIVER_MENU_WIDTH)
    end
    if type(menu.SetHeight) == "function" then
        pcall(menu.SetHeight, menu, GIVER_MENU_PADDING * 2 + rowCount * GIVER_MENU_ROW_HEIGHT)
    end
    pcall(menu.ClearAllPoints, menu)
    pcall(menu.SetPoint, menu, "TOPLEFT", anchorFrame, "BOTTOMRIGHT", 4, 0)
    Client.ApplyFlatTooltipStyle(menu, nil)
    pcall(menu.Show, menu)
    menu.unrealQuestOpenFor = anchorFrame

    -- Shown every time the menu is, not just once at creation: the catcher
    -- has to exist for a click outside the menu to close it at all.
    local catcher = ResolveGiverMenuCatcher()
    if catcher and type(catcher.Show) == "function" then
        pcall(catcher.Show, catcher)
    end
    return true
end

function Client.HideGiverQuestMenu()
    if not giverMenuFrame then
        return false
    end
    giverMenuFrame.unrealQuestOpenFor = nil
    local hidden = Client.HideObject(giverMenuFrame)
    if giverMenuCatcher then
        Client.HideObject(giverMenuCatcher)
    end
    return hidden
end

function Client.IsGiverQuestMenuOpenFor(anchorFrame)
    if not giverMenuFrame or not anchorFrame or giverMenuFrame.unrealQuestOpenFor ~= anchorFrame then
        return false
    end
    if type(giverMenuFrame.IsShown) ~= "function" then
        return true
    end
    local ok, shown = pcall(giverMenuFrame.IsShown, giverMenuFrame)
    return ok and shown and true or false
end

-- Replaces a pin's surface image while keeping every other property of the
-- confirmed rendering contract (14x14 Button, one BACKGROUND texture,
-- SetAllPoints, level 120+). The vertex tint is reset to white so an icon
-- renders in its own colours instead of the marker tint.
--
-- Interface\GossipFrame\AvailableQuestIcon is the client's own available-quest
-- "!" icon. The client's documentation establishes this folder's naming for
-- gossip icons, but the file itself is not runtime-verified here; if it fails
-- to load the pin renders empty. Rolling back is a one-line change: pass
-- Client.WORLD_MAP_PIN_TEXTURE instead and restore the vertex tint.
--
-- The active-quest "?" pin uses a bundled addon asset instead of the client's
-- own Interface\GossipFrame\ActiveQuestIcon -- this is not a client API
-- dependency, so it carries no capability/evidence requirement. Rolling back
-- to the client's icon is still a one-line change: swap the path back to
-- "Interface\\GossipFrame\\ActiveQuestIcon".
Client.WORLD_MAP_PIN_TEXTURE = WORLD_MAP_PIN_TEXTURE
Client.AVAILABLE_QUEST_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon"
Client.ACTIVE_QUEST_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\ActiveQuestIcon"
Client.MINIMAP_OBJECTIVE_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\QuestDot"

function Client.SetWorldMapPinTexture(frame, path)
    local texture = frame and frame.unrealQuestTexture
    if not texture or type(texture.SetTexture) ~= "function" or type(path) ~= "string" then
        return false
    end
    local ok = pcall(texture.SetTexture, texture, path)
    if not ok then
        return false
    end
    if type(texture.SetVertexColor) == "function" then
        pcall(texture.SetVertexColor, texture, 1, 1, 1)
    end
    return true
end

-- Resizes a pin frame away from the default 14x14 square Client.CreateWorldMapPin
-- builds. SetWorldMapPinTexture's texture uses SetAllPoints, which stretches
-- the source image to fill whatever size the frame is -- fine for a square
-- icon, but a non-square source comes out visibly squashed. media/ActiveQuestIcon.tga
-- (the turn-in "?") is 19x32 and is the case that forced this.
function Client.SetWorldMapPinSize(frame, width, height)
    if not frame or type(width) ~= "number" or type(height) ~= "number" then
        return false
    end
    local widthOk = type(frame.SetWidth) == "function" and pcall(frame.SetWidth, frame, width)
    local heightOk = type(frame.SetHeight) == "function" and pcall(frame.SetHeight, frame, height)
    return widthOk and heightOk and true or false
end

-- SetAlpha is a stock Frame method already relied on elsewhere in this file
-- (Client.SetWaypointAlpha), so this carries no new evidence requirement.
function Client.SetWorldMapPinAlpha(frame, alpha)
    if not frame or type(alpha) ~= "number" or type(frame.SetAlpha) ~= "function" then
        return false
    end
    local ok = pcall(frame.SetAlpha, frame, alpha)
    return ok and true or false
end

-- Minimap pins ---------------------------------------------------------------
-- MEASURED 2026-08-23 (probe 1.38.0, group `minimappins`, confirmed in game):
--
--   * an addon-created child of Minimap RENDERS, using the world-map pin
--     contract unchanged -- a Button carrying one file-backed WHITE8X8
--     BACKGROUND texture tinted through SetVertexColor, at frame level 120.
--     Minimap itself sits at level 2 in BACKGROUND strata and its seven native
--     children at levels 3-4, so 120 draws over all of them;
--   * the minimap mask does NOT clip children. Nine squares, including two
--     84.9px from a 70px inscribed radius and two entirely off the minimap,
--     were all visible -- one of them on top of the world-map button. Clipping
--     is this addon's job, not the client's;
--   * Minimap:GetZoom() indexes the Vanilla span table and its zoom-0 outdoor
--     value of 466.6 yards across the minimap's width is correct here: a
--     marker anchored to a world coordinate stayed glued while the player
--     walked. Zoom steps 1-5 are NOT verified;
--   * IsIndoors and IsOutdoors are ABSENT, so the indoor row of that table can
--     never be selected.
--
-- Geometry is read on every call rather than cached: pfUI reshapes the minimap
-- (it was masked square on 2026-08-17 and its module was not even loaded on
-- 2026-08-23), so a width captured once is a width that goes stale.
local MINIMAP_PIN_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local minimapDeclared = false

function Client.GetMinimap()
    local map = ResolveObject("Minimap")
    if not map or type(map.GetWidth) ~= "function" or type(map.GetHeight) ~= "function" then
        return nil
    end
    if not minimapDeclared then
        minimapDeclared = true
        UQ:DeclareCapability("minimapCanvas", "detected",
            "Minimap resolved with geometry; addon children of it are confirmed to render unclipped (probe 1.38.0)")
    end
    return map
end

-- Width, height and the current zoom step. Zoom is what indexes the span
-- table; a client that will not report it leaves it nil rather than 0, because
-- 0 is a real zoom step and guessing it would silently pick a scale.
function Client.GetMinimapGeometry()
    local map = Client.GetMinimap()
    if not map then
        return nil
    end
    local widthOk, width = pcall(map.GetWidth, map)
    local heightOk, height = pcall(map.GetHeight, map)
    if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return nil
    end
    local zoom = nil
    if type(map.GetZoom) == "function" then
        local zoomOk, value = pcall(map.GetZoom, map)
        if zoomOk and type(value) == "number" then
            zoom = value
        end
    end
    return width, height, zoom
end

-- True while the minimap turns with the player. That case is unsupportable
-- here rather than merely unimplemented: this client exposes no player facing
-- by any route (see the facing section below), so a rotated pin cannot be
-- placed at all. The caller must hide its pins, not guess north.
function Client.IsMinimapRotating()
    local get = Resolve("GetCVar")
    if not get then
        return nil
    end
    local ok, value = pcall(get, "rotateMinimap")
    if not ok then
        return nil
    end
    return value == "1" or value == 1
end

-- Same construction as Client.CreateWorldMapPin, against Minimap instead of
-- WorldMapButton. Frame, not Button: nothing on the minimap has a confirmed
-- click surface, and a mouse-enabled child would be the first thing to steal
-- the minimap's own scroll-zoom -- an open question in the knowledge record.
function Client.CreateMinimapPin(index, size, red, green, blue)
    local map = Client.GetMinimap()
    local create = Resolve("CreateFrame")
    if not map or not create or type(index) ~= "number" then
        return nil
    end
    local name = "UnrealQuestMinimapPin" .. tostring(index)
    local ok, frame = pcall(create, "Frame", name, map)
    if not ok or not frame then
        return nil
    end
    if type(size) ~= "number" or size <= 0 then
        size = 14
    end
    if type(frame.SetWidth) == "function" then pcall(frame.SetWidth, frame, size) end
    if type(frame.SetHeight) == "function" then pcall(frame.SetHeight, frame, size) end
    if type(frame.EnableMouse) == "function" then pcall(frame.EnableMouse, frame, false) end
    if type(map.GetFrameLevel) == "function" and type(frame.SetFrameLevel) == "function" then
        local levelOk, level = pcall(map.GetFrameLevel, map)
        local pinLevel = 120
        if levelOk and type(level) == "number" and level + 20 > pinLevel then
            pinLevel = level + 20
        end
        pcall(frame.SetFrameLevel, frame, pinLevel)
    end
    if type(frame.CreateTexture) == "function" then
        local textureOk, texture = pcall(frame.CreateTexture, frame, nil, "BACKGROUND")
        if textureOk and texture then
            frame.unrealQuestTexture = texture
            if type(texture.SetAllPoints) == "function" then
                pcall(texture.SetAllPoints, texture, frame)
            end
            if type(texture.SetTexture) == "function" then
                pcall(texture.SetTexture, texture, MINIMAP_PIN_TEXTURE)
            end
            if type(texture.SetVertexColor) == "function" then
                pcall(texture.SetVertexColor, texture, red or 1, green or 0.8, blue or 0)
            end
        end
    end
    return frame
end

-- Places a pin at a pixel offset from the minimap's centre. The caller has
-- already clamped it; this only refuses offsets that are not numbers.
function Client.PositionMinimapPin(frame, offsetX, offsetY)
    local map = Client.GetMinimap()
    if not frame or not map or type(offsetX) ~= "number" or type(offsetY) ~= "number" then
        return false
    end
    if type(frame.ClearAllPoints) ~= "function" or type(frame.SetPoint) ~= "function"
        or type(frame.Show) ~= "function" then
        return false
    end
    pcall(frame.ClearAllPoints, frame)
    local pointOk = pcall(frame.SetPoint, frame, "CENTER", map, "CENTER", offsetX, offsetY)
    if not pointOk then
        return false
    end
    local showOk = pcall(frame.Show, frame)
    if not showOk then
        return false
    end
    frame.unrealQuestMinimapX = offsetX
    frame.unrealQuestMinimapY = offsetY
    return true
end

-- The tint, image, size and alpha setters are surface operations on
-- frame.unrealQuestTexture and carry nothing map-specific, so a minimap pin
-- reuses them rather than growing a second copy that could drift. The aliases
-- exist so no module has to call something named "WorldMap" on a minimap pin.
Client.SetMinimapPinColor = Client.SetWorldMapPinColor
Client.SetMinimapPinTexture = Client.SetWorldMapPinTexture
Client.SetMinimapPinSize = Client.SetWorldMapPinSize
Client.SetMinimapPinAlpha = Client.SetWorldMapPinAlpha

function Client.IsShiftKeyDown()
    local ok, value = Call0("IsShiftKeyDown")
    if ok then
        return value and true or false
    end
    return false
end

function Client.IsControlKeyDown()
    local ok, value = Call0("IsControlKeyDown")
    if ok then
        return value and true or false
    end
    return false
end

function Client.IsAltKeyDown()
    local ok, value = Call0("IsAltKeyDown")
    if ok then
        return value and true or false
    end
    return false
end

-- Screen and HUD ------------------------------------------------------------
-- The waypoint marker is an ordinary UIParent child, not a map-canvas child,
-- so it is deliberately NOT built to the world-map pin contract in
-- docs/WORLD-MAP-PINS-RECOVERY.md -- that contract describes what survives on
-- WorldMapButton. What is carried over is the part that is about the client's
-- material handling rather than the map: one BACKGROUND texture with
-- SetAllPoints, a real texture FILE rather than a numeric solid, and no
-- IsShown/IsVisible gate anywhere in the refresh path.

function Client.GetScreenSize()
    local okWidth, width = Call0("GetScreenWidth")
    local okHeight, height = Call0("GetScreenHeight")
    if not okWidth or not okHeight
        or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return nil
    end
    return width, height
end

-- Whether the cursor is currently over `object`. Guarded like every other
-- widget method here: a client without IsMouseOver reports false, which for
-- the one caller (the resize grip deciding whether to keep its hover mark
-- visible after a drag ends) degrades to "hide it", the same thing OnLeave
-- would have done anyway.
function Client.IsObjectMouseOver(object)
    if not object or type(object.IsMouseOver) ~= "function" then
        return false
    end
    local ok, over = pcall(object.IsMouseOver, object)
    if not ok then
        return false
    end
    return over and true or false
end

-- Key bindings: deliberately not wrapped -------------------------------------
--
-- There is no Client.SetBindingTo/GetBindingActionFor here any more, and adding
-- one back would be re-opening a closed question. The tracker used them to
-- borrow MOUSEWHEELUP/DOWN while hovered -- the technique UnrealPfUI's chat
-- uses and the only one wheel input allows here at all
-- (chat.mousewheel_uses_binding_layer). The wheelbinding probe measured it dead
-- on this client from both ends: addon-declared Bindings.xml commands never
-- reach the client's 225-entry binding table, and SetBinding is REFUSED on the
-- wheel keys themselves, cleared first or not (see
-- scripts.addon_wheel_binding_unavailable, RUNTIME_FAILURE_CONFIRMED, and the
-- Mouse wheel section in Quest/TrackerFrame.lua).

Client.WAYPOINT_TEXTURE = "Interface\\GossipFrame\\ActiveQuestIcon"

-- Creates the single HUD marker: a mouse-transparent Frame over the 3D world.
--
-- Frame, not Button: this sits on top of the game world, and a mouse-enabled
-- widget there would eat clicks meant for the terrain and for units. The map
-- pins learned that lesson in the opposite direction (a tile at the same frame
-- level silently swallowed the giver click), and the cheapest way not to
-- repeat it is to own no mouse at all.
--
-- Parented to UIParent rather than WorldFrame on purpose: this is UI, and it
-- must disappear when the player hides the interface or opens the fullscreen
-- map. Only the shared driver needs WorldFrame, so that it keeps ticking while
-- this is hidden.
function Client.CreateWaypointMarker(name, size)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, frame = pcall(create, "Frame", name, parent)
    if not ok or not frame then
        return nil
    end

    if type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "HIGH")
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, false)
    end
    if type(size) ~= "number" or size <= 0 then
        size = 28
    end
    if type(frame.SetWidth) == "function" then
        pcall(frame.SetWidth, frame, size)
        pcall(frame.SetHeight, frame, size)
    end

    if type(frame.CreateTexture) == "function" then
        local okTexture, texture = pcall(frame.CreateTexture, frame, nil, "BACKGROUND")
        if okTexture and texture then
            if type(texture.SetTexture) == "function" then
                pcall(texture.SetTexture, texture, Client.WAYPOINT_TEXTURE)
            end
            if type(texture.SetAllPoints) == "function" then
                pcall(texture.SetAllPoints, texture, frame)
            end
            frame.unrealQuestTexture = texture
        end
    end

    if type(frame.CreateFontString) == "function" then
        local okLabel, label = pcall(
            frame.CreateFontString, frame, nil, "OVERLAY", "GameFontNormalSmall")
        if okLabel and label then
            if type(label.SetPoint) == "function" then
                pcall(label.SetPoint, label, "TOP", frame, "BOTTOM", 0, -2)
            end
            if type(label.SetJustifyH) == "function" then
                pcall(label.SetJustifyH, label, "CENTER")
            end
            -- White rather than the map label's near-black: this one is read
            -- against the game world, not against a bright map tile.
            if type(label.SetTextColor) == "function" then
                pcall(label.SetTextColor, label, 1, 1, 1)
            end
            frame.unrealQuestLabel = label
        end
    end

    pcall(frame.Hide, frame)
    return frame
end

function Client.SetWaypointColor(frame, red, green, blue)
    if not frame or not frame.unrealQuestTexture then
        return false
    end
    local texture = frame.unrealQuestTexture
    if type(texture.SetVertexColor) ~= "function" then
        return false
    end
    local ok = pcall(texture.SetVertexColor, texture, red, green, blue)
    return ok and true or false
end

function Client.SetWaypointAlpha(frame, alpha)
    if not frame or type(frame.SetAlpha) ~= "function" then
        return false
    end
    local ok = pcall(frame.SetAlpha, frame, alpha)
    return ok and true or false
end

function Client.SetWaypointLabel(frame, text)
    if not frame or not frame.unrealQuestLabel then
        return false
    end
    local label = frame.unrealQuestLabel
    if type(label.SetText) ~= "function" then
        return false
    end
    local ok = pcall(label.SetText, label, text or "")
    return ok and true or false
end

-- Places the marker at screen coordinates measured from the screen centre.
-- SetPoint against UIParent's CENTER keeps the arithmetic independent of the
-- player's UI scale, which a BOTTOMLEFT-relative pixel offset would not be.
function Client.PositionWaypointMarker(frame, offsetX, offsetY)
    if not frame or type(frame.SetPoint) ~= "function"
        or type(offsetX) ~= "number" or type(offsetY) ~= "number" then
        return false
    end
    local parent = ResolveObject("UIParent")
    if not parent then
        return false
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local ok = pcall(frame.SetPoint, frame, "CENTER", parent, "CENTER", offsetX, offsetY)
    if not ok then
        return false
    end
    pcall(frame.Show, frame)
    return true
end

-- Player facing -------------------------------------------------------------
-- MEASURED 2026-08-22 (probe 1.37.0, group `facing`): this client exposes NO
-- readable player facing, by any route. Not "undocumented" -- absent.
--
--   GetPlayerFacing, GetUnitFacing, UnitFacing, GetPlayerAngle,
--   GetPlayerOrientation, GetCameraYaw, GetCameraPitch, GetCameraFacing,
--   GetCameraPosition, WorldToScreen, UnitPosition, GetPlayerWorldPosition,
--   MiniMapCompassRing, MinimapCompassTexture ......... all nil
--   Minimap:GetChildren() -> 7 children, none a Model: tracking, meeting
--     stone, mail, battlefield and friends. The player arrow is engine-side,
--     exactly as the documented Minimap:SetPlayerModel hints.
--   CreateFrame("Model") -> SetFacing yes, SetRotation yes, GetFacing NO.
--   CreateWorldMapArrowFrame(host) -> creates a PlayerModel child; it has no
--     GetFacing either.
--
-- That last pair is what closes the question rather than merely leaving it
-- open. The installed pfQuest reads Vanilla's facing off the minimap arrow
-- Model's GetFacing (compat/client.lua:76-86); on this client that METHOD
-- does not exist on the Model type at all, so there is no arrow to find and
-- finding one would not help. The facing plainly exists inside the engine --
-- UpdateWorldMapArrowFrames is documented to rotate the arrow to it -- but
-- nothing hands it to Lua.
--
-- The compass-ring and minimap-arrow scanning that used to live here has been
-- REMOVED rather than left in looking harmless, the same way the
-- ReassertHidden machinery was removed from the map layer once measured
-- unnecessary. One cheap resolve of GetPlayerFacing is kept: it costs a
-- negative-cached symbol lookup, and it means the addon starts using a real
-- facing by itself if a future client build ever adds one.
--
-- HUD/PlayerHeading.lua carries the actual mechanism: a heading derived from
-- movement. See docs/HUD-WAYPOINT.md.

local TWO_PI = 6.2831853071796

-- Normalizes any radian reading into [0, 2pi). A source that hands back a
-- number wildly outside one turn is not reporting radians and is rejected
-- rather than silently wrapped into a plausible-looking angle.
local function NormalizeFacing(value)
    if type(value) ~= "number" then
        return nil
    end
    if value ~= value then
        return nil
    end
    if value < -TWO_PI * 2 or value > TWO_PI * 2 then
        return nil
    end
    while value < 0 do
        value = value + TWO_PI
    end
    while value >= TWO_PI do
        value = value - TWO_PI
    end
    return value
end

-- Returns the player's facing in radians (0 = north, increasing towards west)
-- plus the name of the source, or nil -- which, as of the measurement above,
-- is what this client actually returns.
function Client.GetPlayerFacing()
    local ok, value = Call0("GetPlayerFacing")
    if ok then
        local normalized = NormalizeFacing(value)
        if normalized then
            return normalized, "GetPlayerFacing"
        end
    end
    return nil
end

function Client.GetPlayerFacingSource()
    if Client.HasFunction("GetPlayerFacing") then
        return "GetPlayerFacing"
    end
    return nil
end

-- Whether the player is feeding movement input. Documented in the client's
-- `Azeroth` category as reporting INPUT, not pawn velocity, and measured by
-- probe 1.37.0 returning a real boolean that tracked standing vs. running.
--
-- The heading estimator uses it to tell "this heading is current" from "this
-- heading is the last one I measured, and the player has stopped" -- which a
-- time threshold alone cannot do.
function Client.IsPlayerMoving()
    local ok, value = Call0("IsPlayerMoving")
    if not ok then
        return nil
    end
    return value and true or false
end

-- Native frame interrogation ------------------------------------------------
-- Used by the click surfaces to work out which quest a native row belongs to.

function Client.GetNamedObject(name)
    return ResolveObject(name)
end

-- Another addon's SavedVariables table, by global name.
--
-- Deliberately a separate wrapper from GetNamedObject even though both end in
-- ResolveObject, because the two carry different assumptions and only one of
-- them is about frames. What this one assumes:
--
--   * The client writes each addon's declared SavedVariables to its own file
--     and loads it back into a plain Lua global before addon files run.
--     Established by inspecting this client's own save directory, which holds
--     one file per addon (account-wide) plus per-character copies under
--     Emberveil/<character>/SavedVariables. That is FILESYSTEM evidence, not a
--     probe result: no runtime record establishes the loader's behaviour, so
--     callers treat nil as "not available", never as "the player has none".
--   * A global belonging to an addon the player has DISABLED is not loaded at
--     all -- its save file still exists on disk but nothing reads it, and this
--     client exposes no call to read an arbitrary file. An import that needs a
--     foreign addon's data therefore needs that addon enabled, and callers say
--     so rather than reporting the data as absent.
--
-- Returns the table or nil, never a userdata: a SavedVariables global is
-- always plain data.
function Client.GetSavedVariableTable(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local value = ResolveObject(name)
    if type(value) ~= "table" then
        return nil
    end
    return value
end

function Client.GetFrameId(frame)
    if not frame or type(frame.GetID) ~= "function" then
        return nil
    end
    local ok, value = pcall(frame.GetID, frame)
    if not ok or type(value) ~= "number" or value <= 0 then
        return nil
    end
    return value
end

function Client.GetObjectText(object)
    if not object or type(object.GetText) ~= "function" then
        return nil
    end
    local ok, value = pcall(object.GetText, object)
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

function Client.IsObjectShown(object)
    if not object or type(object.IsShown) ~= "function" then
        return false
    end
    local ok, value = pcall(object.IsShown, object)
    return ok and value and true or false
end

-- WorldFrame inspection -----------------------------------------------------
--
-- Read-only. Every function here observes and none writes, because what they
-- exist for is one open question and not a feature: *what are this client's
-- floating nameplates, if they are Lua widgets at all?*
--
-- The history that makes that a question rather than an assumption is in
-- docs/CLIENT-COMPATIBILITY.md item 12. Short version: a structural classifier
-- of the kind every Vanilla nameplate addon uses adopted five WorldFrame
-- children on this client whose name FontString read "Item Name" over 1204
-- polls. Those five are not nameplates. Until something says what they ARE --
-- and whether a real plate is in that child list at all -- nothing may act on
-- them, so this layer deliberately offers no way to.
--
-- Note that Frame:GetNumRegions() ALWAYS returns 0 here
-- (docs/CLIENT-COMPATIBILITY.md, "Native widget scripting"), so a region walk
-- must never be gated on the count. GetRegions itself returns the real varargs.

function Client.GetWorldFrame()
    local frame = ResolveObject("WorldFrame")
    if not frame or type(frame.GetNumChildren) ~= "function"
        or type(frame.GetChildren) ~= "function" then
        return nil
    end
    return frame
end

function Client.GetChildCount(frame)
    if not frame or type(frame.GetNumChildren) ~= "function" then
        return nil
    end
    local ok, value = pcall(frame.GetNumChildren, frame)
    if not ok or type(value) ~= "number" then
        return nil
    end
    return value
end

function Client.GetChildList(frame)
    if not frame or type(frame.GetChildren) ~= "function" then
        return nil
    end
    local ok, list = pcall(function() return { frame:GetChildren() } end)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return list
end

function Client.GetRegionList(frame)
    if not frame or type(frame.GetRegions) ~= "function" then
        return nil
    end
    local ok, list = pcall(function() return { frame:GetRegions() } end)
    if not ok or type(list) ~= "table" then
        return nil
    end
    return list
end

function Client.GetObjectType(object)
    if not object or type(object.GetObjectType) ~= "function" then
        return nil
    end
    local ok, value = pcall(object.GetObjectType, object)
    if not ok or type(value) ~= "string" then
        return nil
    end
    return value
end

-- Widgets are auto-named on this runtime (GeneratedLuaUIObject_NNNN appears in
-- the compatibility database), so a name is a clue about provenance and never
-- an identity test.
function Client.GetObjectName(object)
    if not object or type(object.GetName) ~= "function" then
        return nil
    end
    local ok, value = pcall(object.GetName, object)
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- Diagnostic only (used by /uq questlog to enumerate the real QuestLogFrame
-- layout on this client, since no probe anchors a foreign widget to any of
-- its named children yet). Never trust GetText for anything but a printout.
function Client.GetWidgetText(object)
    if not object or type(object.GetText) ~= "function" then
        return nil
    end
    local ok, value = pcall(object.GetText, object)
    if not ok or type(value) ~= "string" then
        return nil
    end
    return value
end

-- Diagnostic only, see Client.GetWidgetText above.
function Client.GetPointInfo(object, index)
    if not object or type(object.GetPoint) ~= "function" then
        return nil
    end
    local ok, point, relativeTo, relativePoint, x, y =
        pcall(object.GetPoint, object, index or 1)
    if not ok then
        return nil
    end
    local relativeName = relativeTo and Client.GetObjectName(relativeTo)
    return point, relativeName, relativePoint, x, y
end

function Client.GetTexturePath(texture)
    if not texture or type(texture.GetTexture) ~= "function" then
        return nil
    end
    local ok, value = pcall(texture.GetTexture, texture)
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- True when the object carries a status-bar style value getter. The reported
-- objectType is not trusted for this on its own.
function Client.HasBarValue(object)
    if not object then
        return false
    end
    local ok, isFunction = pcall(function() return type(object.GetValue) == "function" end)
    return ok and isFunction and true or false
end

function Client.GetObjectAlpha(object)
    if not object or type(object.GetAlpha) ~= "function" then
        return nil
    end
    local ok, value = pcall(object.GetAlpha, object)
    if not ok or type(value) ~= "number" then
        return nil
    end
    return value
end

-- Installs an additional handler on a native widget's script slot, keeping the
-- existing one.
--
-- This is the whole reason the quest log can be clicked at all here: the
-- client has NO hooksecurefunc (knowledge.json / hooks.no_global_hooksecurefunc),
-- so the ordinary Vanilla post-hook idiom is unavailable. GetScript is
-- documented and returns the stored handler, so the chain is built by hand.
--
-- The previous handler runs FIRST and its failure is contained: a native
-- handler that errors must not stop UnrealQuest's addition, and UnrealQuest's
-- addition must never be what breaks a native row. Vanilla script handlers
-- read the implicit `this`/`arg1` globals rather than parameters, so nothing
-- is forwarded and nothing is rewritten.
function Client.ChainScript(frame, scriptType, handler)
    if not frame or type(handler) ~= "function"
        or type(frame.SetScript) ~= "function" then
        return false
    end

    local previous = nil
    if type(frame.GetScript) == "function" then
        local ok, existing = pcall(frame.GetScript, frame, scriptType)
        if ok and type(existing) == "function" then
            previous = existing
        end
    end

    local chained
    if previous then
        chained = function()
            pcall(previous)
            pcall(handler)
        end
    else
        chained = function()
            pcall(handler)
        end
    end

    local ok = pcall(frame.SetScript, frame, scriptType, chained)
    return ok and true or false
end

-- Marks a widget as carrying UnrealQuest's chained handler, so a re-scan does
-- not install a second copy. SetScript(type, nil) does not detach a script on
-- this client, so removing the chain is not an option and idempotence has to
-- come from the flag.
function Client.MarkScriptChained(frame, key)
    if not frame then
        return false
    end
    local ok = pcall(function() frame[key] = true end)
    return ok and true or false
end

function Client.IsScriptChained(frame, key)
    if not frame then
        return false
    end
    local ok, value = pcall(function() return frame[key] end)
    return ok and value and true or false
end

-- Creates one pooled transparent click surface over a native region.
--
-- The HUD quest tracker is FontStrings (QuestWatchLine1..N), and a FontString
-- cannot receive a click on any client. So the only way to click a tracked
-- quest is an addon-owned Button anchored over the line. Swallowing the click
-- is harmless here precisely because the native watch frame has no click
-- behaviour of its own to swallow -- the opposite of the quest log, where the
-- native row click already means "select this quest" and is chained instead.
function Client.CreateClickSurface(index, parent)
    local create = Resolve("CreateFrame")
    if not create or type(index) ~= "number" or not parent then
        return nil
    end
    local name = "UnrealQuestClickSurface" .. tostring(index)
    local ok, frame = pcall(create, "Button", name, parent)
    if not ok or not frame then
        return nil
    end
    if type(frame.SetFrameLevel) == "function" and type(parent.GetFrameLevel) == "function" then
        local okLevel, level = pcall(parent.GetFrameLevel, parent)
        if okLevel and type(level) == "number" then
            pcall(frame.SetFrameLevel, frame, level + 5)
        end
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    if type(frame.RegisterForClicks) == "function" then
        -- RegisterForClicks is documented on this client as *appending* the
        -- tokens that may fire OnClick, leaving a plain Button's default set
        -- unstated. The giver pins needed this exact call before their
        -- shift-click arrived, so it is treated as removing an assumption.
        pcall(frame.RegisterForClicks, frame, "LeftButtonUp")
    end
    pcall(frame.Hide, frame)
    return frame
end

-- Anchors a click surface exactly over a native region and shows it.
function Client.PlaceClickSurface(frame, region)
    if not frame or not region
        or type(frame.SetPoint) ~= "function"
        or type(region.GetWidth) ~= "function"
        or type(region.GetHeight) ~= "function" then
        return false
    end
    local okWidth, width = pcall(region.GetWidth, region)
    local okHeight, height = pcall(region.GetHeight, region)
    if not okWidth or not okHeight
        or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return false
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local ok = pcall(frame.SetPoint, frame, "TOPLEFT", region, "TOPLEFT", 0, 0)
    if not ok then
        return false
    end
    pcall(frame.SetWidth, frame, width)
    pcall(frame.SetHeight, frame, height)
    pcall(frame.Show, frame)
    return true
end

-- Anchors an addon-owned frame's BOTTOMLEFT to another region's TOPLEFT, i.e.
-- directly above it. Used for the quest log's Show/Track buttons, which sit
-- above QuestLogDetailScrollFrame rather than overlaying anything native.
function Client.PlaceAboveObject(frame, region, offsetX, offsetY)
    if not frame or not region or type(frame.SetPoint) ~= "function" then
        return false
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local ok = pcall(frame.SetPoint, frame, "BOTTOMLEFT", region, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    return ok and true or false
end

-- Grows a region's own height by extraHeight, one-way (idempotency is the
-- caller's job -- see QuestLogButtons.lua, which only calls this once per
-- login via a guard flag, matching pfQuest's own once-only SetHeight call).
function Client.GrowObjectHeight(object, extraHeight)
    if not object or type(object.GetHeight) ~= "function"
        or type(object.SetHeight) ~= "function" then
        return false
    end
    local ok, height = pcall(object.GetHeight, object)
    if not ok or type(height) ~= "number" then
        return false
    end
    local setOk = pcall(object.SetHeight, object, height + (extraHeight or 0))
    return setOk and true or false
end

function Client.SetFontStringJustifyV(object, justify)
    if not object or type(object.SetJustifyV) ~= "function" then
        return false
    end
    local ok = pcall(object.SetJustifyV, object, justify)
    return ok and true or false
end

-- Anchors an addon-owned frame's TOPLEFT to another region's TOPLEFT with an
-- offset, i.e. inside it. Fallback for Client.PlaceAboveObject when the
-- intended anchor region is not found on this client.
function Client.PlaceInsideObject(frame, region, offsetX, offsetY)
    if not frame or not region or type(frame.SetPoint) ~= "function" then
        return false
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local ok = pcall(frame.SetPoint, frame, "TOPLEFT", region, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    return ok and true or false
end

-- Quest tracker window ------------------------------------------------------
--
-- The widgets behind Quest/TrackerFrame.lua: one movable window, a header with
-- a drag handle and three small buttons, and three pools of rows (zone, quest,
-- objective). The module above owns what goes in them; this owns every client
-- call that puts them on screen.
--
-- Four measured client facts shape the construction, and none may be dropped:
--
--   * A drag handle must be a BUTTON PARENTED TO THE FRAME IT MOVES
--     (frames.movable_drag_requires_button_handle, BEHAVIOR_VERIFIED). The
--     failed shape was a mouse-enabled plain Frame parented to UIParent raised
--     with SetFrameStrata: it never received OnDragStart and the frame could
--     not be moved at all. The working recipe changed five things at once and
--     the decisive one was never isolated, so all five are reproduced here:
--     Button widget type, parented to the moved frame, raised with
--     SetFrameLevel rather than a strata change, SetMovable(true) applied
--     immediately before each drag rather than once at registration, and the
--     real StartMoving preceded by a StartMoving/StopMovingOrSizing warm-up
--     pair. A drag that fails reports through UQ:Warn, not UQ:Debug -- the
--     recorded failure was invisible precisely because it was logged to debug.
--   * GetPoint answers with the relative frame as a NAME STRING and with the Y
--     offset SIGN INVERTED against the SetPoint that produced it
--     (frames.getpoint_relative_name_y_inverted, BEHAVIOR_VERIFIED).
--     Client.GetFrameAnchor normalizes both so a captured position can be
--     stored and re-applied; the same record also warns against recapturing
--     and immediately re-applying a point, so nothing here does.
--   * A plain Button can expose SetText and still have no FontString to draw
--     it (buttons.plain_settext_no_fontstring), so every button below creates
--     and owns its own label instead of calling SetText.
--   * SetFont can silently keep the inherited font (fonts.setfont_silent_
--     failure), so text uses stock font-object templates through
--     CreateFontString's inherits argument and never sets a font by path.
--
-- Mouse-wheel scrolling: NOT AVAILABLE, and not for want of trying. Wheel input
-- is consumed by the binding layer before an addon frame sees it
-- (chat.mousewheel_uses_binding_layer), so EnableMouseWheel/OnMouseWheel is a
-- recorded failed approach; and the binding swap that would have replaced it is
-- measured impossible here too -- addon Bindings.xml commands never reach the
-- client's binding table and SetBinding is refused on the wheel keys
-- (scripts.addon_wheel_binding_unavailable, RUNTIME_FAILURE_CONFIRMED). The two
-- scroll buttons and the resize grip are the scroll controls. There are
-- deliberately no binding wrappers in this file for anything to reach for.

local TRACKER_HEADER_HEIGHT = 20
local TRACKER_BUTTON_SIZE = 16
local TRACKER_ACCENT_WIDTH = 2
local TRACKER_PADDING = 6
local TRACKER_BAR_HEIGHT = 2

Client.TRACKER_HEADER_HEIGHT = TRACKER_HEADER_HEIGHT
Client.TRACKER_PADDING = TRACKER_PADDING

-- Both non-header rows use a "Small" stock template rather than GameFontNormal:
-- the panel lists the whole quest log at once, so its footprint matters more
-- here than in a five-line native watch frame. Hierarchy still reads from
-- colour and indent (Client.GetQuestLevelColor on the quest line, dimmer grey
-- on zone headers), not from a size jump.
local TRACKER_ROW_FONTS = {
    zone = "GameFontNormalSmall",
    quest = "GameFontNormalSmall",
    objective = "GameFontHighlightSmall",
}

-- Deliberately more transparent than FLAT_BACKGROUND's 0.85: that value was
-- tuned for a tooltip, which is meant to read as solid chrome over anything
-- behind it. This panel sits on screen for the whole play session, so it is
-- tuned to let the game world show through while the panel is idle.
local TRACKER_BACKGROUND_ALPHA = 0.55

function Client.ShowObject(object)
    if not object or type(object.Show) ~= "function" then
        return false
    end
    local ok = pcall(object.Show, object)
    return ok and true or false
end

function Client.SetObjectSize(object, width, height)
    if not object then
        return false
    end
    local applied = false
    if type(width) == "number" and width > 0 and type(object.SetWidth) == "function" then
        applied = pcall(object.SetWidth, object, width) or applied
    end
    if type(height) == "number" and height > 0 and type(object.SetHeight) == "function" then
        applied = pcall(object.SetHeight, object, height) or applied
    end
    return applied and true or false
end

-- Creates one solid tinted texture. Same material contract as the map pins: a
-- real texture FILE plus a vertex tint, never a numeric solid, because numeric
-- solids became logically present but visually unreliable here.
local function CreateSolid(parent, layer, red, green, blue, alpha)
    if not parent or type(parent.CreateTexture) ~= "function" then
        return nil
    end
    local ok, texture = pcall(parent.CreateTexture, parent, nil, layer or "ARTWORK")
    if not ok or not texture then
        return nil
    end
    if type(texture.SetTexture) == "function" then
        pcall(texture.SetTexture, texture, WORLD_MAP_PIN_TEXTURE)
    end
    if type(texture.SetVertexColor) == "function" then
        pcall(texture.SetVertexColor, texture, red or 1, green or 1, blue or 1, alpha or 1)
    end
    return texture
end

-- Removes the drop shadow every stock font template here carries by default.
-- Documented (DOCUMENTED_NOT_RUNTIME_VERIFIED); guarded like every other
-- widget method in this file, so a client without it simply keeps the
-- template's shadow rather than erroring.
local function StripShadow(fontString)
    if not fontString or type(fontString.SetShadowOffset) ~= "function" then
        return
    end
    pcall(fontString.SetShadowOffset, fontString, 0, 0)
end

function Client.SetSolidColor(texture, red, green, blue, alpha)
    if not texture or type(texture.SetVertexColor) ~= "function" then
        return false
    end
    local ok = pcall(texture.SetVertexColor, texture, red or 1, green or 1, blue or 1,
        alpha == nil and 1 or alpha)
    return ok and true or false
end

-- Applies the player's percentage setting to the tracker background without
-- changing the frame's alpha (which would also dim its text and controls).
function Client.SetTrackerBackgroundOpacity(frame, percent)
    if not frame or type(percent) ~= "number" then
        return false
    end
    if percent < 0 then
        percent = 0
    elseif percent > 100 then
        percent = 100
    end
    return Client.SetSolidColor(frame.unrealQuestBackground,
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], percent / 100)
end

-- Anchor capture and re-application ------------------------------------------
-- GetPoint's two documented deviations on this client are undone here so the
-- rest of the addon can treat an anchor as an ordinary SetPoint tuple.

function Client.GetFrameAnchor(frame)
    if not frame or type(frame.GetPoint) ~= "function" then
        return nil
    end
    local ok, point, relative, relativePoint, offsetX, offsetY = pcall(frame.GetPoint, frame, 1)
    if not ok or type(point) ~= "string" then
        return nil
    end
    local relativeName = nil
    if type(relative) == "string" then
        relativeName = relative
    elseif relative and type(relative.GetName) == "function" then
        local nameOk, name = pcall(relative.GetName, relative)
        if nameOk and type(name) == "string" then
            relativeName = name
        end
    end
    if type(offsetX) ~= "number" then
        offsetX = 0
    end
    if type(offsetY) ~= "number" then
        offsetY = 0
    end
    -- The sign inversion, undone: this returns the offset SetPoint would have
    -- to be given to reproduce the frame's current position.
    return point, relativeName, relativePoint, offsetX, -offsetY
end

function Client.SetFrameAnchor(frame, point, relativeName, relativePoint, offsetX, offsetY)
    if not frame or type(frame.SetPoint) ~= "function" or type(point) ~= "string" then
        return false
    end
    local relative = nil
    if type(relativeName) == "string" then
        relative = ResolveObject(relativeName)
    end
    if not relative then
        relative = ResolveObject("UIParent")
    end
    if not relative then
        return false
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local ok = pcall(frame.SetPoint, frame, point, relative,
        type(relativePoint) == "string" and relativePoint or point,
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    return ok and true or false
end

-- Buttons ---------------------------------------------------------------------

local function CreateSizedButton(parent, name, width, height, text)
    local create = Resolve("CreateFrame")
    if not create or not parent then
        return nil
    end
    local ok, button = pcall(create, "Button", name, parent)
    if not ok or not button then
        return nil
    end
    Client.SetObjectSize(button, width, height)
    if type(parent.GetFrameLevel) == "function" and type(button.SetFrameLevel) == "function" then
        local levelOk, level = pcall(parent.GetFrameLevel, parent)
        if levelOk and type(level) == "number" then
            pcall(button.SetFrameLevel, button, level + 12)
        end
    end
    if type(button.EnableMouse) == "function" then
        pcall(button.EnableMouse, button, true)
    end
    if type(button.RegisterForClicks) == "function" then
        pcall(button.RegisterForClicks, button, "LeftButtonUp")
    end
    -- Own the FontString rather than calling SetText: an untemplated Button
    -- here can expose SetText and still draw nothing.
    if type(button.CreateFontString) == "function" then
        local labelOk, label = pcall(button.CreateFontString, button, nil, "OVERLAY",
            "GameFontNormalSmall")
        if labelOk and label then
            if type(label.SetAllPoints) == "function" then
                pcall(label.SetAllPoints, label, button)
            end
            if type(label.SetJustifyH) == "function" then
                pcall(label.SetJustifyH, label, "CENTER")
            end
            if type(label.SetText) == "function" then
                pcall(label.SetText, label, text or "")
            end
            if type(label.SetTextColor) == "function" then
                pcall(label.SetTextColor, label, 0.65, 0.65, 0.65)
            end
            StripShadow(label)
            button.unrealQuestLabel = label
        end
    end
    -- No hover highlight on the header buttons at all -- the hover effect on
    -- this window is scoped to the quest name only (Client.GetTrackerRow).
    return button
end

local function CreateLabelledButton(parent, name, size, text)
    return CreateSizedButton(parent, name, size, size, text)
end

-- Public creator for a text button of arbitrary width, e.g. the quest log's
-- Show/Track buttons, which read a whole word rather than a single glyph.
function Client.CreateTextButton(parent, name, width, height, text)
    return CreateSizedButton(parent, name, width, height, text)
end

-- A text button in the same flat "modern" look as the tracker window and
-- native-frame tooltips (FLAT_BACKGROUND/BuildFlatBorder above): near-black
-- fill, one thin dark outline, orange accent (UQ.colors.accent) on hover. For
-- the quest log's Show/Track buttons, which sit on the native paper-textured
-- quest log and need to read as unrealQuest's own chrome rather than blend
-- into it -- unlike the plain single-glyph tracker header buttons, which stay
-- unstyled on purpose (see the comment at the end of CreateSizedButton).
function Client.CreateStyledTextButton(parent, name, width, height, text)
    local button = CreateSizedButton(parent, name, width, height, text)
    if not button then
        return nil
    end
    if type(button.SetBackdrop) == "function" then
        local ok = pcall(button.SetBackdrop, button, {
            bgFile = WORLD_MAP_PIN_TEXTURE,
            tile = false,
            tileSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        if ok and type(button.SetBackdropColor) == "function" then
            pcall(button.SetBackdropColor, button, FLAT_BACKGROUND[1], FLAT_BACKGROUND[2],
                FLAT_BACKGROUND[3], FLAT_BACKGROUND[4])
        end
        if type(button.SetBackdropBorderColor) == "function" then
            pcall(button.SetBackdropBorderColor, button, 0, 0, 0, 0)
        end
    end
    BuildFlatBorder(button)
    SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], FLAT_BORDER[4])
    local label = button.unrealQuestLabel
    if label then
        if type(label.SetTextColor) == "function" then
            pcall(label.SetTextColor, label, 0.90, 0.90, 0.90, 1.00)
        end
        -- CreateSizedButton's SetAllPoints label stretches the FontString over
        -- the full button, but this client centres a FontString's glyphs
        -- within its own line height rather than their cap-height, so a
        -- SetAllPoints label reads a couple of pixels above true visual
        -- centre (the same fixed correction unrealUI's own button labels
        -- apply, core/style.lua U.BUTTON_LABEL_OFFSET_Y). A CENTER anchor
        -- lets that offset be applied directly.
        if type(label.ClearAllPoints) == "function" then
            pcall(label.ClearAllPoints, label)
        end
        if type(label.SetPoint) == "function" then
            pcall(label.SetPoint, label, "CENTER", button, "CENTER", 0, -2)
        end
        if type(label.SetJustifyH) == "function" then
            pcall(label.SetJustifyH, label, "CENTER")
        end
        if type(label.SetJustifyV) == "function" then
            pcall(label.SetJustifyV, label, "MIDDLE")
        end
    end
    Client.SetObjectScript(button, "OnEnter", function()
        SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], UQ.colors.accent[4])
    end)
    Client.SetObjectScript(button, "OnLeave", function()
        SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], FLAT_BORDER[4])
    end)
    return button
end

function Client.SetButtonLabel(button, text, red, green, blue)
    local label = button and button.unrealQuestLabel
    if not label then
        return false
    end
    if type(label.SetText) == "function" then
        pcall(label.SetText, label, type(text) == "string" and text or "")
    end
    if red and type(label.SetTextColor) == "function" then
        pcall(label.SetTextColor, label, red, green, blue)
    end
    return true
end

function Client.SetObjectScript(object, scriptType, handler)
    if not object or type(object.SetScript) ~= "function" or type(scriptType) ~= "string" then
        return false
    end
    local ok = pcall(object.SetScript, object, scriptType, handler)
    return ok and true or false
end

-- The window -------------------------------------------------------------------

function Client.CreateTrackerWindow(name)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, frame = pcall(create, "Frame", name, parent)
    if not ok or not frame then
        return nil
    end

    -- MEDIUM, not HIGH: this is an ordinary UI panel and must sit under
    -- tooltips and dialogs rather than over them.
    if type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "MEDIUM")
    end
    -- The window itself owns no mouse. Only the drag handle, the header
    -- buttons and the rows do, so the empty parts of the panel never swallow a
    -- click meant for whatever is underneath them.
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, false)
    end

    local background = CreateSolid(frame, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], TRACKER_BACKGROUND_ALPHA)
    if background and type(background.SetAllPoints) == "function" then
        pcall(background.SetAllPoints, background, frame)
    end
    frame.unrealQuestBackground = background
    BuildFlatBorder(frame)

    -- Header: the accent stripe, the title, the counter, and the three buttons
    -- laid out from the right edge inwards.
    local accent = CreateSolid(frame, "ARTWORK",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if accent then
        pcall(accent.SetPoint, accent, "TOPLEFT", frame, "TOPLEFT", 0, 0)
        pcall(accent.SetWidth, accent, TRACKER_ACCENT_WIDTH)
        pcall(accent.SetHeight, accent, TRACKER_HEADER_HEIGHT)
    end
    frame.unrealQuestAccent = accent

    local separator = CreateSolid(frame, "ARTWORK",
        FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], 1)
    if separator then
        pcall(separator.SetPoint, separator, "TOPLEFT", frame, "TOPLEFT", 0, -TRACKER_HEADER_HEIGHT)
        pcall(separator.SetPoint, separator, "TOPRIGHT", frame, "TOPRIGHT", 0, -TRACKER_HEADER_HEIGHT)
        pcall(separator.SetHeight, separator, 1)
    end
    frame.unrealQuestSeparator = separator

    if type(frame.CreateFontString) == "function" then
        local titleOk, title = pcall(frame.CreateFontString, frame, nil, "OVERLAY", "GameFontNormal")
        if titleOk and title then
            pcall(title.SetPoint, title, "TOPLEFT", frame, "TOPLEFT",
                TRACKER_ACCENT_WIDTH + TRACKER_PADDING, -TRACKER_PADDING + 1)
            pcall(title.SetJustifyH, title, "LEFT")
            pcall(title.SetTextColor, title, UQ.colors.accent[1], UQ.colors.accent[2],
                UQ.colors.accent[3])
            StripShadow(title)
            frame.unrealQuestTitle = title
        end
        local countOk, count = pcall(frame.CreateFontString, frame, nil, "OVERLAY",
            "GameFontNormalSmall")
        if countOk and count then
            pcall(count.SetPoint, count, "TOPRIGHT", frame, "TOPRIGHT",
                -(TRACKER_PADDING + TRACKER_BUTTON_SIZE * 3), -TRACKER_PADDING - 1)
            pcall(count.SetJustifyH, count, "RIGHT")
            pcall(count.SetTextColor, count, 0.55, 0.55, 0.55)
            StripShadow(count)
            frame.unrealQuestCount = count
        end
    end

    local collapse = CreateLabelledButton(frame, name .. "Collapse", TRACKER_BUTTON_SIZE, "-")
    if collapse then
        pcall(collapse.SetPoint, collapse, "TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    end
    frame.unrealQuestCollapse = collapse

    local scrollDown = CreateLabelledButton(frame, name .. "ScrollDown", TRACKER_BUTTON_SIZE, "v")
    if scrollDown then
        pcall(scrollDown.SetPoint, scrollDown, "TOPRIGHT", frame, "TOPRIGHT",
            -(2 + TRACKER_BUTTON_SIZE), -2)
        pcall(scrollDown.Hide, scrollDown)
    end
    frame.unrealQuestScrollDown = scrollDown

    local scrollUp = CreateLabelledButton(frame, name .. "ScrollUp", TRACKER_BUTTON_SIZE, "^")
    if scrollUp then
        pcall(scrollUp.SetPoint, scrollUp, "TOPRIGHT", frame, "TOPRIGHT",
            -(2 + TRACKER_BUTTON_SIZE * 2), -2)
        pcall(scrollUp.Hide, scrollUp)
    end
    frame.unrealQuestScrollUp = scrollUp

    frame.unrealQuestRows = { zone = {}, quest = {}, objective = {} }
    pcall(frame.Hide, frame)
    return frame
end

function Client.SetTrackerTitle(frame, text)
    local title = frame and frame.unrealQuestTitle
    if not title or type(title.SetText) ~= "function" then
        return false
    end
    local ok = pcall(title.SetText, title, type(text) == "string" and text or "")
    return ok and true or false
end

function Client.SetTrackerCount(frame, text)
    local count = frame and frame.unrealQuestCount
    if not count or type(count.SetText) ~= "function" then
        return false
    end
    local ok = pcall(count.SetText, count, type(text) == "string" and text or "")
    return ok and true or false
end

function Client.SetTrackerHeaderButtons(frame, onCollapse, onScrollUp, onScrollDown)
    if not frame then
        return false
    end
    Client.SetObjectScript(frame.unrealQuestCollapse, "OnClick", onCollapse)
    Client.SetObjectScript(frame.unrealQuestScrollUp, "OnClick", onScrollUp)
    Client.SetObjectScript(frame.unrealQuestScrollDown, "OnClick", onScrollDown)
    return true
end

function Client.SetTrackerCollapseLabel(frame, text)
    return Client.SetButtonLabel(frame and frame.unrealQuestCollapse, text)
end

function Client.SetTrackerScrollButtons(frame, upEnabled, downEnabled)
    if not frame then
        return false
    end
    if frame.unrealQuestScrollUp then
        if upEnabled then
            Client.ShowObject(frame.unrealQuestScrollUp)
        else
            Client.HideObject(frame.unrealQuestScrollUp)
        end
    end
    if frame.unrealQuestScrollDown then
        if downEnabled then
            Client.ShowObject(frame.unrealQuestScrollDown)
        else
            Client.HideObject(frame.unrealQuestScrollDown)
        end
    end
    return true
end

-- The drag handle ---------------------------------------------------------------

function Client.CreateTrackerHandle(window, name)
    local create = Resolve("CreateFrame")
    if not create or not window or type(name) ~= "string" then
        return nil
    end
    -- Button, and parented to the window it moves. Both come from the recorded
    -- working recipe; the shape that failed was a plain Frame on UIParent.
    local ok, handle = pcall(create, "Button", name, window)
    if not ok or not handle then
        return nil
    end
    -- Covers the header strip only, so the rows below keep their own clicks.
    if type(handle.SetPoint) == "function" then
        pcall(handle.SetPoint, handle, "TOPLEFT", window, "TOPLEFT", 0, 0)
        pcall(handle.SetPoint, handle, "TOPRIGHT", window, "TOPRIGHT",
            -(TRACKER_BUTTON_SIZE * 3), 0)
    end
    Client.SetObjectSize(handle, nil, TRACKER_HEADER_HEIGHT)
    -- Raised with SetFrameLevel, never with a strata change: raising the handle
    -- by strata is one of the recorded failed approaches.
    if type(window.GetFrameLevel) == "function" and type(handle.SetFrameLevel) == "function" then
        local levelOk, level = pcall(window.GetFrameLevel, window)
        if levelOk and type(level) == "number" then
            pcall(handle.SetFrameLevel, handle, level + 10)
        end
    end
    if type(handle.EnableMouse) == "function" then
        pcall(handle.EnableMouse, handle, true)
    end
    if type(handle.RegisterForClicks) == "function" then
        pcall(handle.RegisterForClicks, handle, "LeftButtonUp", "RightButtonUp")
    end
    if type(handle.RegisterForDrag) == "function" then
        pcall(handle.RegisterForDrag, handle, "LeftButton")
    end
    return handle
end

-- The resize grip -----------------------------------------------------------
--
-- This client's native chat frame resize furniture (ChatFrame<N>ResizeBottom)
-- was tried and found to expose no visible resize option at all, even after
-- Show() and EnableMouse(true) (chat.native_chatframe_direct_resize,
-- BEHAVIOR_VERIFIED) -- so, same as the drag handle above, there is no native
-- resize surface to hook and this builds its own. That same record's WORKING
-- resize recipe is deliberately NOT `Frame:StartSizing` (documented on this
-- client, but never runtime-verified, and the working chat grip never used
-- it either): a plain Button grip is dragged, and while it drags, the target
-- frame's geometry is computed from the grip's OWN drag and applied on the
-- shared driver -- never only on release, which the same record's failed
-- approach list names explicitly ("resizing worked and persisted, but the
-- grip moved alone during the drag and the chat jumped only after release").
--
-- This grip does not reproduce that shape exactly, and takes advantage of a
-- simplification the chat frame did not have: because the grip is anchored
-- BOTTOMRIGHT of the window it resizes (never re-anchored during the drag,
-- matching the other explicit rule in that same record: "never ClearAllPoints/
-- SetPoint the moving grip itself"), applying a new width to the WINDOW every
-- tick automatically carries the grip along with it through that anchor --
-- there is no separate grip position to keep in sync by hand at all.
function Client.CreateTrackerResizeGrip(window, name)
    local create = Resolve("CreateFrame")
    if not create or not window or type(name) ~= "string" then
        return nil
    end
    local ok, grip = pcall(create, "Button", name, window)
    if not ok or not grip then
        return nil
    end
    Client.SetObjectSize(grip, 12, 12)
    if type(grip.SetPoint) == "function" then
        pcall(grip.SetPoint, grip, "BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)
    end
    -- Raised with SetFrameLevel, matching the drag handle above -- raising
    -- by strata change is a recorded failed approach for this client's drag
    -- widgets.
    if type(window.GetFrameLevel) == "function" and type(grip.SetFrameLevel) == "function" then
        local levelOk, level = pcall(window.GetFrameLevel, window)
        if levelOk and type(level) == "number" then
            pcall(grip.SetFrameLevel, grip, level + 10)
        end
    end
    if type(grip.EnableMouse) == "function" then
        pcall(grip.EnableMouse, grip, true)
    end
    if type(grip.RegisterForDrag) == "function" then
        pcall(grip.RegisterForDrag, grip, "LeftButton")
    end
    -- Invisible until hovered, then show the supplied resize artwork. The
    -- mark is toggled manually rather than through Button:SetHighlightTexture
    -- (see Client.GetTrackerRow for why GetHighlightTexture stays unused).
    local mark
    if type(grip.CreateTexture) == "function" then
        local markOk, created = pcall(grip.CreateTexture, grip, nil, "OVERLAY")
        if markOk and created then
            if type(created.SetTexture) == "function" then
                pcall(created.SetTexture, created, TRACKER_RESIZE_GRIP_TEXTURE)
            end
            mark = created
        end
    end
    if mark then
        pcall(mark.SetAllPoints, mark, grip)
        pcall(mark.Hide, mark)
    end
    grip.unrealQuestMark = mark
    pcall(grip.SetScript, grip, "OnEnter", function()
        if grip.unrealQuestMark then
            pcall(grip.unrealQuestMark.Show, grip.unrealQuestMark)
        end
    end)
    pcall(grip.SetScript, grip, "OnLeave", function()
        -- Never hides while a drag is in progress: the cursor is very often
        -- outside the 12x12 grip by the second tick of a real drag, and the
        -- mark disappearing mid-resize would read as the grip letting go.
        if grip.unrealQuestMark and not grip.unrealQuestResizing then
            pcall(grip.unrealQuestMark.Hide, grip.unrealQuestMark)
        end
    end)
    return grip
end

-- Begins a drag of `window`. Returns false when the client refused, and the
-- caller reports that visibly -- a drag failure logged to debug output only is
-- exactly how the original immovable-frame bug stayed hidden.
function Client.StartFrameDrag(window)
    if not window or type(window.StartMoving) ~= "function" then
        return false
    end
    -- Immediately before the drag, never once at registration.
    if type(window.SetMovable) == "function" then
        pcall(window.SetMovable, window, true)
    end
    -- The warm-up pair from the working recipe. Which of its five changed
    -- factors is decisive was never isolated, so this stays.
    if type(window.StopMovingOrSizing) == "function" then
        pcall(window.StartMoving, window)
        pcall(window.StopMovingOrSizing, window)
    end
    local ok = pcall(window.StartMoving, window)
    return ok and true or false
end

function Client.StopFrameDrag(window)
    if not window or type(window.StopMovingOrSizing) ~= "function" then
        return false
    end
    local ok = pcall(window.StopMovingOrSizing, window)
    return ok and true or false
end

-- Reads an object's current drawn size. The resize grip seeds its drag from
-- these MEASURED pixels rather than from the stored width/row settings -- see
-- Quest/TrackerFrame.lua's ApplyResize for why seeding from the settings made
-- the window jump the moment the grip was clicked.
function Client.GetObjectWidth(object)
    if not object or type(object.GetWidth) ~= "function" then
        return nil
    end
    local ok, width = pcall(object.GetWidth, object)
    if not ok or type(width) ~= "number" then
        return nil
    end
    return width
end

function Client.GetObjectHeight(object)
    if not object or type(object.GetHeight) ~= "function" then
        return nil
    end
    local ok, height = pcall(object.GetHeight, object)
    if not ok or type(height) ~= "number" then
        return nil
    end
    return height
end

-- Reads an object's screen-space bottom-left corner. This is how the resize
-- grip is tracked during a drag: the grip is genuinely MOVED by the client
-- (Client.StartFrameDrag, same recipe as the header handle), so its own
-- GetLeft/GetBottom are the authoritative record of how far the corner has
-- travelled. Reading the cursor instead was the earlier, broken approach --
-- see Quest/TrackerFrame.lua's ApplyResize.
function Client.GetObjectCorner(object)
    if not object or type(object.GetLeft) ~= "function"
        or type(object.GetBottom) ~= "function" then
        return nil
    end
    local okLeft, left = pcall(object.GetLeft, object)
    local okBottom, bottom = pcall(object.GetBottom, object)
    if not okLeft or not okBottom
        or type(left) ~= "number" or type(bottom) ~= "number" then
        return nil
    end
    return left, bottom
end

-- Whether the cursor is inside `object`'s drawn rectangle, computed from the
-- cursor position rather than asked of the widget.
--
-- Frame:IsMouseOver has NO record on this client at all -- not probed, not
-- documented (query_compat.py "IsMouseOver": no matches) -- and an earlier
-- version of the tracker's hover reveal used it and silently never fired,
-- because Client.IsObjectMouseOver degrades a missing method to false. This
-- takes the measured route instead: GetCursorPosition divided by the frame's
-- GetEffectiveScale and compared against its edges is confirmed in-game to
-- locate a point inside a frame (api.getcursorposition_usable_for_hit_testing,
-- BEHAVIOR_VERIFIED).
--
-- It is a rectangle test, so it stays true over the object's children -- which
-- is exactly what a "hovering anywhere in this window" question needs, and
-- what OnEnter/OnLeave on a frame full of mouse-enabled rows cannot give.
-- Returns false, never nil, whenever anything is missing or not yet laid out.
function Client.IsCursorInsideObject(object)
    if not object or type(object.GetLeft) ~= "function"
        or type(object.GetBottom) ~= "function" then
        return false
    end
    local okCursor, cursorX, cursorY = Call0("GetCursorPosition")
    if not okCursor or type(cursorX) ~= "number" or type(cursorY) ~= "number" then
        return false
    end
    local left, bottom = Client.GetObjectCorner(object)
    if not left then
        return false
    end
    -- The far edges come from the drawn SIZE, never from GetRight/GetTop.
    -- Those two are recorded as not describing a scaled frame's position here
    -- (frames.scaled_frame_edge_coordinates_mixed_space: extent unscaled,
    -- origin in the parent's space), and its own stated remedy is to use
    -- GetWidth/GetHeight instead of differencing edges. Nothing in this addon
    -- calls SetScale, so this is belt-and-braces rather than a live bug -- but
    -- it costs nothing and survives a window that is scaled later.
    local width = Client.GetObjectWidth(object)
    local height = Client.GetObjectHeight(object)
    if not width or not height or width <= 0 or height <= 0 then
        return false
    end
    local scale = 1
    if type(object.GetEffectiveScale) == "function" then
        local okScale, value = pcall(object.GetEffectiveScale, object)
        if okScale and type(value) == "number" and value > 0 then
            scale = value
        end
    end
    local x = cursorX / scale
    local y = cursorY / scale
    if x < left or x > left + width or y < bottom or y > bottom + height then
        return false
    end
    return true
end

-- Puts the grip back in the window's corner after a drag. A grip that was
-- moved by the client keeps whatever point the move left it on, so without
-- this it stays floating wherever it was dropped instead of following the
-- window it belongs to.
function Client.AnchorObjectToCorner(object, window)
    if not object or not window or type(object.SetPoint) ~= "function" then
        return false
    end
    if type(object.ClearAllPoints) == "function" then
        pcall(object.ClearAllPoints, object)
    end
    local ok = pcall(object.SetPoint, object, "BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)
    return ok and true or false
end

-- Rows ---------------------------------------------------------------------------
-- Pooled per window and per kind. Kind decides the font template, which is
-- fixed at creation: SetFont is recorded as able to fail silently here, so a
-- row never changes its own font -- it is drawn from the pool that already has
-- the right one.

function Client.GetTrackerRow(window, kind, index)
    if not window or type(index) ~= "number" then
        return nil
    end
    local pools = window.unrealQuestRows
    local pool = pools and pools[kind]
    if not pool then
        return nil
    end
    local row = pool[index]
    if row then
        return row
    end
    local create = Resolve("CreateFrame")
    if not create then
        return nil
    end
    local name = "UnrealQuestTrackerRow" .. kind .. tostring(index)
    local ok, button = pcall(create, "Button", name, window)
    if not ok or not button then
        return nil
    end
    if type(window.GetFrameLevel) == "function" and type(button.SetFrameLevel) == "function" then
        local levelOk, level = pcall(window.GetFrameLevel, window)
        if levelOk and type(level) == "number" then
            pcall(button.SetFrameLevel, button, level + 5)
        end
    end
    if type(button.EnableMouse) == "function" then
        pcall(button.EnableMouse, button, true)
    end
    if type(button.RegisterForClicks) == "function" then
        pcall(button.RegisterForClicks, button, "LeftButtonUp", "RightButtonUp")
    end
    if type(button.CreateFontString) == "function" then
        local labelOk, label = pcall(button.CreateFontString, button, nil, "OVERLAY",
            TRACKER_ROW_FONTS[kind] or "GameFontHighlightSmall")
        if labelOk and label then
            pcall(label.SetPoint, label, "LEFT", button, "LEFT", 0, 0)
            pcall(label.SetJustifyH, label, "LEFT")
            -- Never wrap: a wrapped second line would draw over the row below
            -- it rather than stay inside this row's own height. Undocumented
            -- on this client (no compat-DB record either way), so it is
            -- called defensively like every other widget method here -- a
            -- client without it simply keeps whatever its default is, and the
            -- Fit() trim in Quest/TrackerFrame.lua is what actually keeps a
            -- long name inside the window regardless.
            if type(label.SetWordWrap) == "function" then
                pcall(label.SetWordWrap, label, false)
            end
            StripShadow(label)
            button.unrealQuestLabel = label
        end
    end
    -- The tracked marker: a two-unit accent stripe down the left of the row.
    local stripe = CreateSolid(button, "ARTWORK",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if stripe then
        pcall(stripe.SetPoint, stripe, "LEFT", button, "LEFT", -TRACKER_PADDING, 0)
        pcall(stripe.SetWidth, stripe, TRACKER_ACCENT_WIDTH)
        pcall(stripe.SetHeight, stripe, 10)
        pcall(stripe.Hide, stripe)
    end
    button.unrealQuestStripe = stripe

    local track = CreateSolid(button, "ARTWORK", 1, 1, 1, 0.12)
    if track then
        pcall(track.SetPoint, track, "BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
        pcall(track.SetHeight, track, TRACKER_BAR_HEIGHT)
        pcall(track.Hide, track)
    end
    button.unrealQuestBarTrack = track

    local fill = CreateSolid(button, "OVERLAY",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if fill then
        pcall(fill.SetPoint, fill, "BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
        pcall(fill.SetHeight, fill, TRACKER_BAR_HEIGHT)
        pcall(fill.Hide, fill)
    end
    button.unrealQuestBarFill = fill

    -- Hover is scoped to the quest name only -- zone headers and objective
    -- lines never get it -- and is drawn as an addon-owned overlay tinted
    -- with the accent colour rather than through Button:SetHighlightTexture.
    -- SetHighlightTexture itself is fine (used elsewhere in this file on the
    -- map's giver menu), but tinting one means reading it back through
    -- GetHighlightTexture, and that exact call is the one a native Blizzard
    -- row template on this client was confirmed to crash on
    -- (frames.friendsframe_row_touch_crashes_client, RUNTIME_FAILURE_
    -- CONFIRMED). Whether that is specific to the native template or a
    -- general hazard was never isolated, so it stays unused here; toggling a
    -- plain Show/Hide texture via OnEnter/OnLeave is the same technique
    -- already confirmed safe on the map's area tiles (worldMapAreaHover,
    -- BEHAVIOR_VERIFIED).
    if kind == "quest" then
        local hover = CreateSolid(button, "OVERLAY",
            UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 0.16)
        if hover then
            pcall(hover.SetAllPoints, hover, button)
            pcall(hover.Hide, hover)
        end
        button.unrealQuestHover = hover
        -- unrealQuestOnEnter/OnLeave are optional extension points, not
        -- another script slot: Quest/TrackerFrame.lua wants to show a quest
        -- tooltip on the same hover, but SetScript replaces whatever handler
        -- was here, and SetScript(type, nil) does not detach one on this
        -- client (rule 9), so there is no safe way for a second caller to
        -- install its own OnEnter/OnLeave beside this one. Reading an
        -- app-supplied field back is a plain table lookup, not a client call,
        -- so it does not need to live behind this compatibility layer at all
        -- -- only the SetScript calls themselves do.
        pcall(button.SetScript, button, "OnEnter", function()
            if button.unrealQuestHover then
                pcall(button.unrealQuestHover.Show, button.unrealQuestHover)
            end
            if type(button.unrealQuestOnEnter) == "function" then
                button.unrealQuestOnEnter()
            end
        end)
        pcall(button.SetScript, button, "OnLeave", function()
            if button.unrealQuestHover then
                pcall(button.unrealQuestHover.Hide, button.unrealQuestHover)
            end
            if type(button.unrealQuestOnLeave) == "function" then
                button.unrealQuestOnLeave()
            end
        end)
    end
    pcall(button.Hide, button)
    pool[index] = button
    return button
end

-- Places one row and shows it. Geometry is measured from the window's own
-- TOPLEFT with explicit offsets rather than from edge coordinates: GetTop and
-- friends do not describe a scaled frame's position on this client
-- (frames.scaled_frame_edge_coordinates_mixed_space).
function Client.PlaceTrackerRow(row, window, indent, top, width, height)
    if not row or not window or type(row.SetPoint) ~= "function" then
        return false
    end
    if type(width) ~= "number" or type(height) ~= "number" then
        return false
    end
    if type(row.ClearAllPoints) == "function" then
        pcall(row.ClearAllPoints, row)
    end
    local offset = indent or 0
    local ok = pcall(row.SetPoint, row, "TOPLEFT", window, "TOPLEFT",
        TRACKER_PADDING + offset, -(top or 0))
    if not ok then
        return false
    end
    local rowWidth = width - TRACKER_PADDING * 2 - offset
    if rowWidth < 1 then
        rowWidth = 1
    end
    Client.SetObjectSize(row, rowWidth, height)
    local label = row.unrealQuestLabel
    if label and type(label.SetWidth) == "function" then
        pcall(label.SetWidth, label, rowWidth)
    end
    if row.unrealQuestBarTrack and type(row.unrealQuestBarTrack.SetWidth) == "function" then
        pcall(row.unrealQuestBarTrack.SetWidth, row.unrealQuestBarTrack, rowWidth)
    end
    row.unrealQuestWidth = rowWidth
    pcall(row.Show, row)
    return true
end

function Client.SetTrackerRowText(row, text, red, green, blue)
    local label = row and row.unrealQuestLabel
    if not label then
        return false
    end
    if type(label.SetText) == "function" then
        pcall(label.SetText, label, type(text) == "string" and text or "")
    end
    if red and type(label.SetTextColor) == "function" then
        pcall(label.SetTextColor, label, red, green, blue)
    end
    return true
end

function Client.SetTrackerRowStripe(row, shown, red, green, blue)
    local stripe = row and row.unrealQuestStripe
    if not stripe then
        return false
    end
    if not shown then
        return Client.HideObject(stripe)
    end
    if red then
        Client.SetSolidColor(stripe, red, green, blue, 1)
    end
    return Client.ShowObject(stripe)
end

-- fraction nil hides the bar entirely: an objective whose text carries no
-- counter has no progress to draw and must not get an empty bar.
function Client.SetTrackerRowProgress(row, fraction, red, green, blue)
    local track = row and row.unrealQuestBarTrack
    local fill = row and row.unrealQuestBarFill
    if not track or not fill then
        return false
    end
    if type(fraction) ~= "number" then
        Client.HideObject(track)
        Client.HideObject(fill)
        return true
    end
    if fraction < 0 then
        fraction = 0
    end
    if fraction > 1 then
        fraction = 1
    end
    local width = row.unrealQuestWidth or 0
    Client.ShowObject(track)
    if fraction <= 0 or width <= 0 then
        Client.HideObject(fill)
        return true
    end
    if red then
        Client.SetSolidColor(fill, red, green, blue, 1)
    end
    if type(fill.SetWidth) == "function" then
        pcall(fill.SetWidth, fill, width * fraction)
    end
    Client.ShowObject(fill)
    return true
end

function Client.SetTrackerRowClick(row, handler)
    return Client.SetObjectScript(row, "OnClick", handler)
end

-- Hides every pooled row of one kind from `from` upwards. Pooled rows are
-- reused across redraws, so a shorter list has to actively retire the rows the
-- longer one before it left on screen.
function Client.HideTrackerRows(window, kind, from)
    local pools = window and window.unrealQuestRows
    local pool = pools and pools[kind]
    if not pool then
        return 0
    end
    local hidden = 0
    local index = from or 1
    while pool[index] do
        Client.HideObject(pool[index])
        hidden = hidden + 1
        index = index + 1
    end
    return hidden
end

-- Which mouse button delivered an OnClick. The client passes it as the
-- handler's argument on a widget callback and falls back to the legacy global
-- -- the same two shapes Client.ResolveEventName already has to cope with.
function Client.ResolveClickButton(first)
    if type(first) == "string" and first ~= "" then
        return first
    end
    local ok, value = pcall(getglobal, "arg1")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return "LeftButton"
end

-- Native quest log and watch frame ------------------------------------------------

-- Documented: selects a quest log row, and clears the selection when handed a
-- header or an out-of-range index. The tracker uses it so a click on one of its
-- own rows leaves the native Quest Log showing that quest.
function Client.SelectQuestLogEntry(index)
    if type(index) ~= "number" then
        return false
    end
    local ok = Call1("SelectQuestLogEntry", index)
    return ok and true or false
end

-- Opens the native Quest Log if the client offers a way to. Every candidate is
-- tried in turn and the first that works wins; a client with none of them
-- simply leaves the quest selected without opening anything.
function Client.OpenQuestLog()
    local frame = ResolveObject("QuestLogFrame")
    if frame and type(frame.IsShown) == "function" then
        local shownOk, shown = pcall(frame.IsShown, frame)
        if shownOk and shown then
            return true
        end
    end
    if frame and Client.HasFunction("ShowUIPanel") then
        local ok = Call1("ShowUIPanel", frame)
        if ok then
            return true
        end
    end
    if Client.HasFunction("ToggleQuestLog") then
        local ok = Call0("ToggleQuestLog")
        if ok then
            return true
        end
    end
    if frame then
        return Client.ShowObject(frame)
    end
    return false
end

-- Opens the native fullscreen map WITHOUT toggling it. ToggleWorldMap exists
-- and is confirmed present (context.globals.ToggleWorldMap), but it is
-- deliberately not called here: docs/WORLD-MAP-PINS-RECOVERY.md records that
-- WorldMapFrame:IsShown()/IsVisible() do not reliably reflect this client's
-- fullscreen presentation, so there is no safe way to check "is it already
-- open" before deciding whether a toggle would open it or close it. Calling
-- a genuine toggle blind risks closing a map the player already had up --
-- the opposite of what a Ctrl+click "show me on the map" gesture should ever
-- do. ShowUIPanel is documented to manage a UIPanelWindows-registered
-- frame's open state without toggling (the same call Client.OpenQuestLog
-- above already relies on for exactly this reason), so it is used instead.
function Client.OpenWorldMap()
    local frame = ResolveObject("WorldMapFrame")
    if not frame then
        return false
    end
    if Client.HasFunction("ShowUIPanel") then
        local ok = Call1("ShowUIPanel", frame)
        if ok then
            return true
        end
    end
    return Client.ShowObject(frame)
end

-- The native tracked-objectives panel, confirmed in game to be QuestWatchFrame
-- (questwatch.native_root_user_confirmed). UnrealQuest's own window lists the
-- whole quest log, so the five-quest native panel is redundant while it is up.
-- Hiding it is a setting, and it is re-shown the moment that setting is turned
-- off or the tracker is disabled.
function Client.GetNativeQuestWatchFrame()
    return ResolveObject("QuestWatchFrame")
end

function Client.SetNativeQuestWatchShown(shown)
    local frame = Client.GetNativeQuestWatchFrame()
    if not frame then
        return false
    end
    if shown then
        return Client.ShowObject(frame)
    end
    return Client.HideObject(frame)
end

-- The settings window ------------------------------------------------------------
--
-- UnrealQuest's own options window, built ONLY when unrealUI is not installed.
-- When it is, Core/Settings.lua hands the same page builder to unrealUI's
-- settings window instead. These primitives exist so that one builder can lay a
-- page out without knowing which of the two windows it landed in: every creator
-- here takes the host frame as an argument and anchors to it, and nothing
-- reaches for a window by name.
--
-- The geometry deliberately mirrors unrealUI's settings panel -- a 46px header,
-- a 46px footer and 12px gutters -- so the content area a page is handed is the
-- same size in both hosts and a layout tuned in one is not re-tuned for the
-- other.
--
-- Nothing about the drag is re-derived here. The handle is the same shape the
-- tracker's is (frames.movable_drag_requires_button_handle, BEHAVIOR_VERIFIED):
-- a Button parented to the frame it moves, raised with SetFrameLevel and never
-- by a strata change, dragged through Client.StartFrameDrag.

local SETTINGS_HEADER_HEIGHT = 46
local SETTINGS_FOOTER_HEIGHT = 46
local SETTINGS_PADDING = 12
local SETTINGS_ACCENT_WIDTH = 2
-- Near-solid, unlike the tracker's 0.55: the tracker sits on screen for a whole
-- session and is tuned to let the world show through, while this window is
-- opened, read and closed again.
local SETTINGS_BACKGROUND_ALPHA = 0.94

-- The header/footer/gutter budget, so a caller can size a window whose content
-- box matches unrealUI's without copying the numbers.
function Client.GetSettingsMetrics()
    return SETTINGS_HEADER_HEIGHT, SETTINGS_FOOTER_HEIGHT, SETTINGS_PADDING
end

-- Anchors one region to another OBJECT. Client.SetFrameAnchor takes the
-- relative frame by NAME because it re-applies a persisted anchor, where a live
-- object cannot be stored; page layout has the object in hand and must not have
-- to round-trip it through the global table to place a label.
function Client.AnchorObject(object, point, relative, relativePoint, offsetX, offsetY)
    if not object or type(object.SetPoint) ~= "function"
        or type(point) ~= "string" or not relative then
        return false
    end
    if type(object.ClearAllPoints) == "function" then
        pcall(object.ClearAllPoints, object)
    end
    local ok = pcall(object.SetPoint, object, point, relative,
        type(relativePoint) == "string" and relativePoint or point,
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    return ok and true or false
end

function Client.CreateSettingsWindow(name, width, height)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, frame = pcall(create, "Frame", name, parent)
    if not ok or not frame then
        return nil
    end

    -- HIGH, where the tracker is MEDIUM: this is a dialog the player opened on
    -- purpose and it belongs over the ordinary panels, which is also the strata
    -- unrealUI gives its own settings panel.
    if type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "HIGH")
    end
    -- Mouse enabled on the WINDOW here, the opposite of the tracker's choice. A
    -- dialog that let clicks through to the world behind it would turn the
    -- player while they read it.
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    Client.SetObjectSize(frame, width, height)

    local background = CreateSolid(frame, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], SETTINGS_BACKGROUND_ALPHA)
    if background and type(background.SetAllPoints) == "function" then
        pcall(background.SetAllPoints, background, frame)
    end
    frame.unrealQuestBackground = background
    BuildFlatBorder(frame)

    local accent = CreateSolid(frame, "ARTWORK",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if accent then
        pcall(accent.SetPoint, accent, "TOPLEFT", frame, "TOPLEFT", 0, 0)
        pcall(accent.SetWidth, accent, SETTINGS_ACCENT_WIDTH)
        pcall(accent.SetHeight, accent, SETTINGS_HEADER_HEIGHT)
    end
    frame.unrealQuestAccent = accent

    local headerRule = CreateSolid(frame, "ARTWORK",
        FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], 1)
    if headerRule then
        pcall(headerRule.SetPoint, headerRule, "TOPLEFT", frame, "TOPLEFT",
            0, -SETTINGS_HEADER_HEIGHT)
        pcall(headerRule.SetPoint, headerRule, "TOPRIGHT", frame, "TOPRIGHT",
            0, -SETTINGS_HEADER_HEIGHT)
        pcall(headerRule.SetHeight, headerRule, 1)
    end
    frame.unrealQuestHeaderRule = headerRule

    local footerRule = CreateSolid(frame, "ARTWORK",
        FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], 1)
    if footerRule then
        pcall(footerRule.SetPoint, footerRule, "BOTTOMLEFT", frame, "BOTTOMLEFT",
            0, SETTINGS_FOOTER_HEIGHT)
        pcall(footerRule.SetPoint, footerRule, "BOTTOMRIGHT", frame, "BOTTOMRIGHT",
            0, SETTINGS_FOOTER_HEIGHT)
        pcall(footerRule.SetHeight, footerRule, 1)
    end
    frame.unrealQuestFooterRule = footerRule

    if type(frame.CreateFontString) == "function" then
        local titleOk, title = pcall(frame.CreateFontString, frame, nil, "OVERLAY", "GameFontNormal")
        if titleOk and title then
            pcall(title.SetPoint, title, "TOPLEFT", frame, "TOPLEFT",
                SETTINGS_ACCENT_WIDTH + SETTINGS_PADDING, -(SETTINGS_PADDING + 4))
            pcall(title.SetJustifyH, title, "LEFT")
            pcall(title.SetTextColor, title, UQ.colors.accent[1], UQ.colors.accent[2],
                UQ.colors.accent[3])
            StripShadow(title)
            frame.unrealQuestTitle = title
        end
    end

    pcall(frame.Hide, frame)
    return frame
end

function Client.SetSettingsTitle(frame, text)
    local title = frame and frame.unrealQuestTitle
    if not title or type(title.SetText) ~= "function" then
        return false
    end
    local ok = pcall(title.SetText, title, type(text) == "string" and text or "")
    return ok and true or false
end

-- The drag handle. Covers the header strip only, so the page below keeps its
-- own clicks. Same five-factor recipe as the tracker's handle.
function Client.CreateSettingsHandle(window, name)
    local create = Resolve("CreateFrame")
    if not create or not window or type(name) ~= "string" then
        return nil
    end
    local ok, handle = pcall(create, "Button", name, window)
    if not ok or not handle then
        return nil
    end
    if type(handle.SetPoint) == "function" then
        pcall(handle.SetPoint, handle, "TOPLEFT", window, "TOPLEFT", 0, 0)
        pcall(handle.SetPoint, handle, "TOPRIGHT", window, "TOPRIGHT", 0, 0)
    end
    Client.SetObjectSize(handle, nil, SETTINGS_HEADER_HEIGHT)
    -- SetFrameLevel, never a strata change: raising a drag handle by strata is
    -- one of the recorded failed approaches on this client.
    if type(window.GetFrameLevel) == "function" and type(handle.SetFrameLevel) == "function" then
        local levelOk, level = pcall(window.GetFrameLevel, window)
        if levelOk and type(level) == "number" then
            pcall(handle.SetFrameLevel, handle, level + 10)
        end
    end
    if type(handle.EnableMouse) == "function" then
        pcall(handle.EnableMouse, handle, true)
    end
    if type(handle.RegisterForClicks) == "function" then
        pcall(handle.RegisterForClicks, handle, "LeftButtonUp")
    end
    if type(handle.RegisterForDrag) == "function" then
        pcall(handle.RegisterForDrag, handle, "LeftButton")
    end
    return handle
end

-- The content area: a positioning anchor and nothing else. Its children are
-- shown and hidden through the page's own widget list, never through this
-- frame -- the same contract unrealUI's content frame has, because this client
-- does not propagate a parent's visibility to its children.
function Client.CreateSettingsContent(window, name)
    local create = Resolve("CreateFrame")
    if not create or not window or type(name) ~= "string" then
        return nil
    end
    local ok, content = pcall(create, "Frame", name, window)
    if not ok or not content then
        return nil
    end
    if type(content.SetPoint) == "function" then
        pcall(content.SetPoint, content, "TOPLEFT", window, "TOPLEFT",
            SETTINGS_PADDING, -SETTINGS_HEADER_HEIGHT)
        pcall(content.SetPoint, content, "BOTTOMRIGHT", window, "BOTTOMRIGHT",
            -SETTINGS_PADDING, SETTINGS_FOOTER_HEIGHT)
    end
    -- No mouse: it is an anchor, and a mouse-enabled anchor would eat the
    -- clicks meant for the controls parented to it.
    if type(content.EnableMouse) == "function" then
        pcall(content.EnableMouse, content, false)
    end
    return content
end

local function CreateSettingsFontString(parent, template, offsetX, offsetY, width)
    if not parent or type(parent.CreateFontString) ~= "function" then
        return nil
    end
    local ok, label = pcall(parent.CreateFontString, parent, nil, "OVERLAY", template)
    if not ok or not label then
        return nil
    end
    pcall(label.SetPoint, label, "TOPLEFT", parent, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    pcall(label.SetJustifyH, label, "LEFT")
    if type(width) == "number" and width > 0 and type(label.SetWidth) == "function" then
        pcall(label.SetWidth, label, width)
    end
    StripShadow(label)
    return label
end

-- A page heading, in the shared accent colour.
function Client.CreateSettingsHeading(parent, text, offsetX, offsetY)
    local label = CreateSettingsFontString(parent, "GameFontNormal", offsetX, offsetY)
    if not label then
        return nil
    end
    if type(label.SetTextColor) == "function" then
        pcall(label.SetTextColor, label, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3])
    end
    if type(label.SetText) == "function" then
        pcall(label.SetText, label, type(text) == "string" and text or "")
    end
    return label
end

-- A body line. width is the wrap width in pixels; nil leaves the line unwrapped.
function Client.CreateSettingsBody(parent, text, offsetX, offsetY, width)
    local label = CreateSettingsFontString(parent, "GameFontHighlightSmall",
        offsetX, offsetY, width)
    if not label then
        return nil
    end
    if type(label.SetTextColor) == "function" then
        pcall(label.SetTextColor, label, 0.70, 0.70, 0.70)
    end
    if type(label.SetText) == "function" then
        pcall(label.SetText, label, type(text) == "string" and text or "")
    end
    return label
end

-- A 1px horizontal rule, the settings page's section divider. A plain texture,
-- never a backdrop edge: this client does not rasterize fractional backdrop
-- edges (rendering.backdrop_edge_fractional_not_rasterized), which is the same
-- reason every other line in this file is drawn as one.
function Client.CreateSettingsRule(parent, offsetX, offsetY, width)
    local rule = CreateSolid(parent, "ARTWORK",
        FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], 1)
    if not rule then
        return nil
    end
    pcall(rule.SetPoint, rule, "TOPLEFT", parent, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    if type(width) == "number" and width > 0 then
        pcall(rule.SetWidth, rule, width)
    end
    pcall(rule.SetHeight, rule, 1)
    return rule
end

-- Addon registry ------------------------------------------------------------
--
-- Reading, and changing, whether ANOTHER addon is enabled. Needed by exactly
-- one caller: Quest/PfQuestImport.lua, which cannot read pfQuest's saved quest
-- history unless pfQuest is enabled, and most players disable pfQuest the day
-- they install this addon.
--
-- What the client documents (Addon category, all
-- DOCUMENTED_NOT_RUNTIME_VERIFIED -- none of these has a probe result yet):
--   GetAddOnInfo(index or name)              -> folder name, or nil if unknown
--   GetAddOnEnableState(character, index)    -> 0, 1 or 2
--   IsAddOnLoaded(index or name)             -> boolean
--   EnableAddOn / DisableAddOn(name, char)   -> pending until SaveAddOns
--   SaveAddOns()                             -> commits the pending flags
--
-- Two documented facts shape the whole flow above these wrappers:
--   * A change is PENDING until SaveAddOns() and does not take effect until
--     the UI reloads. Enabling an addon does not make its saved variables
--     appear in this session.
--   * ReloadUI is PROTECTED on this client -- "addons cannot call this; only
--     the default FrameXML UI can". So the addon can flip the flag and must
--     then ASK the player to type /reload. There is no way to do it for them,
--     and no wrapper here pretends otherwise.

local function AddOnFolder(name)
    local ok, folder = Call1("GetAddOnInfo", name)
    if not ok or type(folder) ~= "string" or folder == "" then
        return nil
    end
    return folder
end

-- Whether the addon exists in the registry at all, enabled or not.
function Client.IsAddOnInstalled(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    return AddOnFolder(name) ~= nil
end

-- Whether the addon's files are in memory NOW. The only question with a
-- definite answer this session -- enabled state describes the next load.
function Client.IsAddOnLoaded(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local ok, loaded = Call1("IsAddOnLoaded", name)
    if not ok then
        return nil
    end
    return loaded and true or false
end

-- Whether the addon is enabled for this character. GetAddOnEnableState returns
-- 0/1/2 -- 0 is off, and both 1 and 2 (per-character and all-characters) are
-- forms of on. nil when the call is unavailable, which callers must not read
-- as "disabled": an unknown state is a reason to do nothing, not a reason to
-- start flipping another addon's flags.
function Client.IsAddOnEnabled(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local ok, state = Call2("GetAddOnEnableState", nil, name)
    if not ok or type(state) ~= "number" then
        return nil
    end
    return state ~= 0
end

-- Flips another addon's enabled flag and commits it. Returns true only when
-- both the flip and the commit went through, because a flip that was never
-- saved is a flag the next load will not see -- and a caller that believed it
-- would leave the player waiting for a reload that changes nothing.
--
-- The change is pending until the UI reloads. This never claims otherwise and
-- never reloads: see the protection note above.
function Client.SetAddOnEnabled(name, enabled)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local ok = Call1(enabled and "EnableAddOn" or "DisableAddOn", name)
    if not ok then
        return false
    end
    local saved = Call0("SaveAddOns")
    if not saved then
        return false
    end
    return true
end

-- Rewrites a body line built by Client.CreateSettingsBody. The settings page is
-- built once per host and then kept, so a line that reports live state -- how
-- many quests an import would bring in, say -- has to be updated in place.
-- Rebuilding it would orphan the region the host is already showing and hiding
-- by hand.
function Client.SetSettingsBodyText(label, text)
    if not label or type(label.SetText) ~= "function" then
        return false
    end
    local ok = pcall(label.SetText, label, type(text) == "string" and text or "")
    return ok and true or false
end

-- An action button on the settings page: the same flat chrome as the quest
-- log's Show/Track buttons (Client.CreateStyledTextButton), anchored TOPLEFT to
-- the page like every other region the page cursor places.
--
-- An action, not a setting. A checkbox stores a value the page re-reads on
-- every open; this runs something once and has nothing to sync back, so it
-- takes a handler and returns no state. onClick reads no arguments and no
-- `this` -- handler argument shape is not guaranteed on this client
-- (scripts.handler_arguments_direct) -- so it closes over what it needs.
function Client.CreateSettingsButton(parent, name, text, offsetX, offsetY, width, height, onClick)
    local button = Client.CreateStyledTextButton(parent, name, width, height, text)
    if not button then
        return nil
    end
    pcall(button.SetPoint, button, "TOPLEFT", parent, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    if type(onClick) == "function" then
        Client.SetObjectScript(button, "OnClick", function()
            onClick()
        end)
    end
    return button
end

-- Checkboxes ------------------------------------------------------------------
--
-- A plain Button plus owned textures, not a native CheckButton and not
-- SetCheckedTexture. That is the shape unrealUI's own settings checkboxes use
-- and the one this file already applies everywhere else here: the checked state
-- is an OVERLAY texture this addon shows and hides by hand, on the same
-- file-backed-texture-plus-vertex-tint material contract as every other solid
-- in this layer.
--
-- The label is parented to the PAGE, not to the box, and handed back as
-- `.label`. Nothing may rely on a parent's visibility reaching its children
-- here (rendering.parent_alpha_not_propagated), so both hosts toggle the label
-- explicitly -- `.label` is exactly the field unrealUI's own page code looks
-- for, so one control satisfies both.

local SETTINGS_CHECKBOX_SIZE = 14
local SETTINGS_CHECKBOX_INSET = 3

function Client.SetSettingsCheckbox(box, checked)
    if not box then
        return false
    end
    box.unrealQuestChecked = checked and true or false
    local mark = box.unrealQuestMark
    if not mark then
        return false
    end
    if box.unrealQuestChecked then
        return Client.ShowObject(mark)
    end
    return Client.HideObject(mark)
end

function Client.GetSettingsCheckbox(box)
    if not box then
        return false
    end
    return box.unrealQuestChecked and true or false
end

-- The shared body of both toggles. `markInset` is the only visual difference
-- between them (see Client.CreateSettingsRadio) and `onClick` is the only
-- behavioural one, so the construction itself -- which is the part carrying
-- this client's material and label contracts -- exists once.
local function CreateSettingsToggle(parent, name, text, offsetX, offsetY, width,
    markInset, onClick)
    local create = Resolve("CreateFrame")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, box = pcall(create, "Button", name, parent)
    if not ok or not box then
        return nil
    end

    Client.SetObjectSize(box, SETTINGS_CHECKBOX_SIZE, SETTINGS_CHECKBOX_SIZE)
    pcall(box.SetPoint, box, "TOPLEFT", parent, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    if type(box.EnableMouse) == "function" then
        pcall(box.EnableMouse, box, true)
    end
    if type(box.RegisterForClicks) == "function" then
        pcall(box.RegisterForClicks, box, "LeftButtonUp")
    end

    local fill = CreateSolid(box, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], 1)
    if fill and type(fill.SetAllPoints) == "function" then
        pcall(fill.SetAllPoints, fill, box)
    end
    BuildFlatBorder(box)

    local mark = CreateSolid(box, "OVERLAY",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if mark then
        pcall(mark.SetPoint, mark, "TOPLEFT", box, "TOPLEFT",
            markInset, -markInset)
        pcall(mark.SetPoint, mark, "BOTTOMRIGHT", box, "BOTTOMRIGHT",
            -markInset, markInset)
        pcall(mark.Hide, mark)
    end
    box.unrealQuestMark = mark
    box.unrealQuestChecked = false

    if type(parent.CreateFontString) == "function" then
        local labelOk, label = pcall(parent.CreateFontString, parent, nil, "OVERLAY",
            "GameFontHighlightSmall")
        if labelOk and label then
            pcall(label.SetPoint, label, "LEFT", box, "RIGHT", 6, 0)
            pcall(label.SetJustifyH, label, "LEFT")
            if type(width) == "number" and width > 0 and type(label.SetWidth) == "function" then
                pcall(label.SetWidth, label, width)
            end
            pcall(label.SetText, label, type(text) == "string" and text or "")
            pcall(label.SetTextColor, label, 0.85, 0.85, 0.85)
            StripShadow(label)
            box.label = label
        end
    end

    Client.SetObjectScript(box, "OnEnter", function()
        SetFlatBorderColor(box, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], UQ.colors.accent[4])
    end)
    Client.SetObjectScript(box, "OnLeave", function()
        SetFlatBorderColor(box, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], FLAT_BORDER[4])
    end)
    Client.SetObjectScript(box, "OnClick", function()
        onClick(box)
    end)

    return box
end

-- onChange is called with the NEW value after a click. The handler reads no
-- arguments and no `this`: handler argument shape is not guaranteed on this
-- client (scripts.handler_arguments_direct), so it closes over the box instead.
function Client.CreateSettingsCheckbox(parent, name, text, offsetX, offsetY, width, onChange)
    return CreateSettingsToggle(parent, name, text, offsetX, offsetY, width,
        SETTINGS_CHECKBOX_INSET,
        function(box)
            Client.SetSettingsCheckbox(box, not box.unrealQuestChecked)
            if type(onChange) == "function" then
                onChange(box.unrealQuestChecked)
            end
        end)
end

-- Radio buttons ----------------------------------------------------------------
--
-- One setting with two or more mutually exclusive values, where a checkbox
-- would have to name one of them and leave the other implicit. Deliberately
-- the SAME widget as the checkbox: a Button carrying a flat fill, a border and
-- an accent OVERLAY mark, on the material contract this whole layer keeps. No
-- native CheckButton, no round texture -- the client's own radio art
-- (Interface\Buttons\UI-RadioButton) has no runtime record here, and a
-- control that renders empty is worse than one that reads as a smaller square.
--
-- Two things separate a radio from a checkbox, and they are the two arguments
-- above: the mark is inset further so a selected row is visibly a dot rather
-- than a filled box, and clicking always SELECTS rather than toggling -- a
-- radio row cannot turn itself off, because that would leave the group
-- describing no value at all. Clearing the siblings is the caller's job: only
-- the page knows which buttons form the group.
local SETTINGS_RADIO_INSET = 4

function Client.SetSettingsRadio(button, selected)
    return Client.SetSettingsCheckbox(button, selected)
end

function Client.GetSettingsRadio(button)
    return Client.GetSettingsCheckbox(button)
end

-- onSelect is called only when the click actually changes this row from
-- unselected to selected, so a page never has to re-apply a value the player
-- merely clicked twice.
function Client.CreateSettingsRadio(parent, name, text, offsetX, offsetY, width, onSelect)
    return CreateSettingsToggle(parent, name, text, offsetX, offsetY, width,
        SETTINGS_RADIO_INSET,
        function(button)
            if button.unrealQuestChecked then
                return
            end
            Client.SetSettingsRadio(button, true)
            if type(onSelect) == "function" then
                onSelect()
            end
        end)
end

-- Slider ------------------------------------------------------------------------
--
-- Standalone import of unrealUI's U.CreateSlider component. The structure and
-- public surface deliberately match it: a caption, flat track, draggable
-- Button thumb, min/max labels, display-only value box, `uuiParts`, `current`,
-- `SetPoint` and silent `SetValue`. Core/Settings.lua uses the real
-- UnrealUI.CreateSlider when that addon hosts the page and this import when it
-- does not, so changing hosts never changes the control.
--
-- The thumb uses the same measured Button drag recipe as unrealUI and the
-- tracker resize grip. RefreshDrag is the one UnrealQuest addition: its shared
-- driver calls it while the thumb is moving, allowing a bound setting to apply
-- in real time without adding an OnUpdate frame.
function Client.CreateSettingsSlider(parent, options)
    options = options or {}
    local create = Resolve("CreateFrame")
    if not create or not parent then
        return nil
    end

    local width = tonumber(options.width) or 200
    local minimum = tonumber(options.min) or 0
    local maximum = tonumber(options.max) or 100
    local step = tonumber(options.step) or 1
    local control = { min = minimum, max = maximum, step = step, uuiParts = {} }

    local function Part(region)
        if region then
            table.insert(control.uuiParts, region)
        end
        return region
    end

    local function Clamp(raw)
        raw = tonumber(raw)
        if not raw then
            return minimum
        end
        raw = math.floor((raw - minimum) / step + 0.5) * step + minimum
        if raw < minimum then
            raw = minimum
        elseif raw > maximum then
            raw = maximum
        end
        return raw
    end

    local caption = Part(CreateSettingsFontString(parent, "GameFontNormalSmall", 0, 0, width))
    if caption then
        pcall(caption.SetTextColor, caption, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3])
        pcall(caption.SetText, caption, type(options.text) == "string" and options.text or "")
    end
    control.caption = caption

    local trackOk, track = pcall(create, "Frame",
        options.name and (options.name .. "Track") or nil, parent)
    if not trackOk or not track then
        return nil
    end
    Client.SetObjectSize(track, width, 8)
    local trackFill = Part(CreateSolid(track, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], 1))
    if trackFill and type(trackFill.SetAllPoints) == "function" then
        pcall(trackFill.SetAllPoints, trackFill, track)
    end
    BuildFlatBorder(track)
    Part(track)
    control.track = track

    local thumbOk, thumb = pcall(create, "Button",
        options.name and (options.name .. "Thumb") or nil, track)
    if not thumbOk or not thumb then
        return nil
    end
    Client.SetObjectSize(thumb, 12, 14)
    if type(thumb.EnableMouse) == "function" then
        pcall(thumb.EnableMouse, thumb, true)
    end
    if type(thumb.RegisterForDrag) == "function" then
        pcall(thumb.RegisterForDrag, thumb, "LeftButton")
    end
    local thumbFill = Part(CreateSolid(thumb, "BACKGROUND",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1))
    if thumbFill and type(thumbFill.SetAllPoints) == "function" then
        pcall(thumbFill.SetAllPoints, thumbFill, thumb)
    end
    BuildFlatBorder(thumb)
    Part(thumb)
    control.thumb = thumb

    Client.SetObjectScript(thumb, "OnEnter", function()
        SetFlatBorderColor(thumb, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], UQ.colors.accent[4])
    end)
    Client.SetObjectScript(thumb, "OnLeave", function()
        SetFlatBorderColor(thumb, FLAT_BORDER[1], FLAT_BORDER[2],
            FLAT_BORDER[3], FLAT_BORDER[4])
    end)

    local minLabel = Part(CreateSettingsFontString(parent, "GameFontNormalSmall", 0, 0, width / 2))
    if minLabel then
        pcall(minLabel.SetTextColor, minLabel, 0.55, 0.55, 0.55)
        pcall(minLabel.SetText, minLabel, tostring(minimum))
    end
    local maxLabel = Part(CreateSettingsFontString(parent, "GameFontNormalSmall", 0, 0, width / 2))
    if maxLabel then
        pcall(maxLabel.SetJustifyH, maxLabel, "RIGHT")
        pcall(maxLabel.SetTextColor, maxLabel, 0.55, 0.55, 0.55)
        pcall(maxLabel.SetText, maxLabel, tostring(maximum))
    end

    local boxWidth = tonumber(options.boxWidth) or 74
    local boxOk, box = pcall(create, "Frame",
        options.name and (options.name .. "Value") or nil, parent)
    if not boxOk or not box then
        return nil
    end
    Client.SetObjectSize(box, boxWidth, 16)
    local boxFill = Part(CreateSolid(box, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], 1))
    if boxFill and type(boxFill.SetAllPoints) == "function" then
        pcall(boxFill.SetAllPoints, boxFill, box)
    end
    BuildFlatBorder(box)
    Part(box)
    control.box = box
    control.width = width
    control.boxWidth = boxWidth

    local readout = Part(CreateSettingsFontString(box, "GameFontNormalSmall", 0, 0, boxWidth - 6))
    if readout then
        if type(readout.ClearAllPoints) == "function" then
            pcall(readout.ClearAllPoints, readout)
        end
        pcall(readout.SetPoint, readout, "CENTER", box, "CENTER", 0, 0)
        pcall(readout.SetJustifyH, readout, "CENTER")
        pcall(readout.SetTextColor, readout, 0.85, 0.85, 0.85)
    end
    control.readout = readout

    local function UpdateReadout(raw)
        local value = Clamp(raw)
        control.current = value
        if readout then
            pcall(readout.SetText, readout, tostring(value))
        end
        return value
    end

    local function PlaceThumb(raw)
        local value = Clamp(raw)
        local usable = width - 12
        local offset = 0
        if maximum > minimum and usable > 0 then
            offset = (value - minimum) / (maximum - minimum) * usable
        end
        if type(thumb.ClearAllPoints) == "function" then
            pcall(thumb.ClearAllPoints, thumb)
        end
        pcall(thumb.SetPoint, thumb, "LEFT", track, "LEFT", offset, 0)
    end

    local function ReadThumbValue()
        if type(thumb.GetLeft) ~= "function" or type(track.GetLeft) ~= "function"
            or type(track.GetWidth) ~= "function" then
            return nil
        end
        local thumbOkRead, thumbLeft = pcall(thumb.GetLeft, thumb)
        local trackOkRead, trackLeft = pcall(track.GetLeft, track)
        local widthOk, trackWidth = pcall(track.GetWidth, track)
        if not (thumbOkRead and trackOkRead and widthOk and tonumber(thumbLeft)
            and tonumber(trackLeft) and tonumber(trackWidth)) then
            return nil
        end
        local usable = trackWidth - 12
        if usable <= 0 then
            return nil
        end
        local offset = thumbLeft - trackLeft
        if offset < 0 then
            offset = 0
        elseif offset > usable then
            offset = usable
        end
        return minimum + offset / usable * (maximum - minimum)
    end

    control.RefreshDrag = function()
        if not control.dragging then
            return control.current
        end
        local value = ReadThumbValue()
        if value then
            return UpdateReadout(value)
        end
        return control.current
    end

    control.SetValue = function(raw)
        local value = UpdateReadout(raw)
        PlaceThumb(value)
    end

    control.SetPoint = function(point, relative, relativePoint, offsetX, offsetY)
        if type(track.ClearAllPoints) == "function" then
            pcall(track.ClearAllPoints, track)
        end
        pcall(track.SetPoint, track, point, relative, relativePoint, offsetX, offsetY)
        if caption then
            if type(caption.ClearAllPoints) == "function" then
                pcall(caption.ClearAllPoints, caption)
            end
            pcall(caption.SetPoint, caption, "BOTTOMLEFT", track, "TOPLEFT", 0, 4)
        end
        if minLabel then
            if type(minLabel.ClearAllPoints) == "function" then
                pcall(minLabel.ClearAllPoints, minLabel)
            end
            pcall(minLabel.SetPoint, minLabel, "TOPLEFT", track, "BOTTOMLEFT", 0, -3)
        end
        if maxLabel then
            if type(maxLabel.ClearAllPoints) == "function" then
                pcall(maxLabel.ClearAllPoints, maxLabel)
            end
            pcall(maxLabel.SetPoint, maxLabel, "TOPRIGHT", track, "BOTTOMRIGHT", 0, -3)
        end
        if type(box.ClearAllPoints) == "function" then
            pcall(box.ClearAllPoints, box)
        end
        pcall(box.SetPoint, box, "TOP", track, "BOTTOM", 0, -2)
    end

    Client.SetObjectScript(thumb, "OnDragStart", function()
        if Client.StartFrameDrag(thumb) then
            control.dragging = true
        end
    end)
    Client.SetObjectScript(thumb, "OnDragStop", function()
        control.RefreshDrag()
        control.dragging = false
        Client.StopFrameDrag(thumb)
        local value = ReadThumbValue()
        if value then
            value = UpdateReadout(value)
            PlaceThumb(value)
            if type(options.onChange) == "function" then
                options.onChange(value)
            end
        else
            PlaceThumb(control.current or minimum)
        end
    end)

    control.SetValue(options.value == nil and minimum or options.value)
    return control
end

function Client.SetSettingsText(label, text)
    if not label or type(label.SetText) ~= "function" then
        return false
    end
    local ok = pcall(label.SetText, label, type(text) == "string" and text or "")
    return ok and true or false
end

-- The minimap settings button ----------------------------------------------------
--
-- Created immediately while Settings waits for a late unrealUI, then hidden
-- if that host is detected. It is anchored exactly the way unrealUI's is, for
-- a reason that is recorded rather than cosmetic:
-- knowledge.json / minimap.render_pass_under_ordinary_frames says the map
-- surface is drawn in a special pass BENEATH ordinary frames, so a button
-- sitting on top of the map would cover that part of it whatever its frame
-- level. It therefore goes beside the map, on its left edge, clear of the stock
-- chrome that hangs off the right side.
--
-- Parented to UIParent rather than to Minimap. The addon's minimap PINS are
-- children of Minimap because they have to travel with it and are confirmed to
-- render unclipped there (minimapCanvas, probe 1.38.0); this button is chrome
-- that sits outside the map and has no such requirement, and unrealUI's
-- equivalent is a UIParent child too.

local MINIMAP_BUTTON_SIZE = 24
local MINIMAP_BUTTON_INSET = 1

-- Every candidate is tried in turn and the first that takes the anchor wins. A
-- client with no minimap at all still gets a button, parked in the corner,
-- rather than an invisible one anchored to nothing.
local function AnchorMinimapButton(button)
    local minimap = ResolveObject("Minimap")
    if minimap then
        if pcall(button.SetPoint, button, "TOPRIGHT", minimap, "TOPLEFT", -6, 0) then
            return "Minimap"
        end
    end
    local cluster = ResolveObject("MinimapCluster")
    if cluster then
        if pcall(button.SetPoint, button, "TOPRIGHT", cluster, "TOPLEFT", -6, -6) then
            return "MinimapCluster"
        end
    end
    local parent = ResolveObject("UIParent")
    if parent and pcall(button.SetPoint, button, "TOPRIGHT", parent, "TOPRIGHT", -8, -8) then
        return "UIParent (no minimap found)"
    end
    return nil
end

-- Same fallback chain as AnchorMinimapButton above, offset one more button
-- width and gap to the left so the button lands immediately beside (to the
-- left of) wherever the settings icon itself sits -- including when
-- unrealUI owns that icon rather than this addon's own standalone button,
-- since unrealUI's equivalent uses this same TOPRIGHT-of-minimap anchor
-- point (see the comment on Client.CreateMinimapButton below). Used for the
-- NPC finder HUD button's default position, before the player ever drags it.
local BESIDE_SETTINGS_ICON_GAP = 4

local function AnchorButtonBesideSettingsIcon(button)
    local offset = -(MINIMAP_BUTTON_SIZE + BESIDE_SETTINGS_ICON_GAP)
    local minimap = ResolveObject("Minimap")
    if minimap then
        if pcall(button.SetPoint, button, "TOPRIGHT", minimap, "TOPLEFT", -6 + offset, 0) then
            return "Minimap"
        end
    end
    local cluster = ResolveObject("MinimapCluster")
    if cluster then
        if pcall(button.SetPoint, button, "TOPRIGHT", cluster, "TOPLEFT", -6 + offset, -6) then
            return "MinimapCluster"
        end
    end
    local parent = ResolveObject("UIParent")
    if parent and pcall(button.SetPoint, button, "TOPRIGHT", parent, "TOPRIGHT", -8 + offset, -8) then
        return "UIParent (no minimap found)"
    end
    return nil
end

function Client.AnchorHudButtonBesideSettingsIcon(button)
    if not button then
        return nil
    end
    return AnchorButtonBesideSettingsIcon(button)
end

-- Returns the button and the name of whatever it ended up anchored to, so the
-- caller can report the fallback rather than leave it silent.
--
-- texturePath is the icon. The standalone settings button uses the same stock
-- gear and UV crop as unrealUI's minimap settings button, so changing hosts
-- does not change its appearance. If that texture is refused, the label uses
-- unrealUI's "UI" fallback rather than leaving an empty square.
function Client.CreateMinimapButton(name, texturePath, fallbackLabel)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, button = pcall(create, "Button", name, parent)
    if not ok or not button then
        return nil
    end

    Client.SetObjectSize(button, MINIMAP_BUTTON_SIZE, MINIMAP_BUTTON_SIZE)
    if type(button.SetFrameStrata) == "function" then
        pcall(button.SetFrameStrata, button, "MEDIUM")
    end
    if type(button.EnableMouse) == "function" then
        pcall(button.EnableMouse, button, true)
    end
    if type(button.RegisterForClicks) == "function" then
        pcall(button.RegisterForClicks, button, "LeftButtonUp")
    end

    local background = CreateSolid(button, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], FLAT_BACKGROUND[4])
    if background and type(background.SetAllPoints) == "function" then
        pcall(background.SetAllPoints, background, button)
    end
    button.unrealQuestBackground = background
    BuildFlatBorder(button)

    local drawn = false
    if type(texturePath) == "string" and type(button.CreateTexture) == "function" then
        local iconOk, icon = pcall(button.CreateTexture, button, nil, "ARTWORK")
        if iconOk and icon and type(icon.SetTexture) == "function" then
            if pcall(icon.SetTexture, icon, texturePath) then
                pcall(icon.SetPoint, icon, "TOPLEFT", button, "TOPLEFT",
                    MINIMAP_BUTTON_INSET, -MINIMAP_BUTTON_INSET)
                pcall(icon.SetPoint, icon, "BOTTOMRIGHT", button, "BOTTOMRIGHT",
                    -MINIMAP_BUTTON_INSET, MINIMAP_BUTTON_INSET)
                if type(icon.SetTexCoord) == "function" then
                    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
                end
                button.unrealQuestIcon = icon
                drawn = true
            else
                pcall(icon.Hide, icon)
            end
        end
    end
    if not drawn and type(button.CreateFontString) == "function" then
        local labelOk, label = pcall(button.CreateFontString, button, nil, "OVERLAY",
            "GameFontNormal")
        if labelOk and label then
            pcall(label.SetPoint, label, "CENTER", button, "CENTER", 0, -1)
            pcall(label.SetText, label,
                type(fallbackLabel) == "string" and fallbackLabel or "UI")
            pcall(label.SetTextColor, label, UQ.colors.accent[1], UQ.colors.accent[2],
                UQ.colors.accent[3])
            StripShadow(label)
            button.unrealQuestLabel = label
        end
    end

    -- Same hover treatment as the tracker's header buttons: the flat border
    -- takes the accent colour. Not Button:SetHighlightTexture, which the rest of
    -- this file already avoids on this client.
    Client.SetObjectScript(button, "OnEnter", function()
        SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], UQ.colors.accent[4])
    end)
    Client.SetObjectScript(button, "OnLeave", function()
        SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], FLAT_BORDER[4])
    end)

    local anchor = AnchorMinimapButton(button)
    pcall(button.Hide, button)
    return button, anchor
end

-- A free HUD button uses the same measured flat icon-button surface as the
-- standalone settings button, then its caller replaces the temporary minimap
-- anchor with a persisted UIParent-relative one. Keeping one constructor
-- means the two buttons cannot drift into different rendering contracts.
function Client.CreateHudButton(name, texturePath, fallbackLabel)
    local button = Client.CreateMinimapButton(name, texturePath, fallbackLabel)
    return button
end

-- Registers the drag token on an addon-owned Button. The caller still owns
-- OnDragStart/OnDragStop and moves the object through StartFrameDrag below,
-- preserving the measured five-part movable-frame recipe.
function Client.EnableFrameDragging(frame)
    if not frame or type(frame.RegisterForDrag) ~= "function" then
        return false
    end
    local ok = pcall(frame.RegisterForDrag, frame, "LeftButton")
    return ok and true or false
end

-- Full-size interactive child for a movable HUD button. The proven drag
-- recipe requires a Button handle parented to the frame it moves; using the
-- visual root as its own handle would skip that measured parent/child shape.
function Client.CreateHudButtonHandle(button, name)
    local create = Resolve("CreateFrame")
    if not create or not button or type(name) ~= "string" then
        return nil
    end
    local ok, handle = pcall(create, "Button", name, button)
    if not ok or not handle then
        return nil
    end
    if type(handle.SetAllPoints) == "function" then
        pcall(handle.SetAllPoints, handle, button)
    elseif type(handle.SetPoint) == "function" then
        pcall(handle.SetPoint, handle, "TOPLEFT", button, "TOPLEFT", 0, 0)
        pcall(handle.SetPoint, handle, "BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    end
    if type(button.GetFrameLevel) == "function" and type(handle.SetFrameLevel) == "function" then
        local levelOk, level = pcall(button.GetFrameLevel, button)
        if levelOk and type(level) == "number" then
            pcall(handle.SetFrameLevel, handle, level + 10)
        end
    end
    if type(handle.EnableMouse) == "function" then
        pcall(handle.EnableMouse, handle, true)
    end
    if type(handle.RegisterForClicks) == "function" then
        pcall(handle.RegisterForClicks, handle, "LeftButtonUp")
    end
    Client.EnableFrameDragging(handle)
    return handle
end

function Client.SetHudButtonHovered(button, hovered)
    if not button then
        return false
    end
    if hovered then
        SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], UQ.colors.accent[4])
    else
        SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2],
            FLAT_BORDER[3], FLAT_BORDER[4])
    end
    return true
end

-- Nearby-NPC filter menu ----------------------------------------------------
--
-- Native UIDropDownMenu behaviour is not established on this client. This is
-- therefore a small addon-owned multi-select menu built from the same proven
-- Button/FontString/file-backed-texture primitives as the settings window and
-- giver picker. It remains open while rows are toggled; the HUD button closes
-- it explicitly.
local NPC_FILTER_MENU_WIDTH = 196
local NPC_FILTER_ROW_HEIGHT = 20
local NPC_FILTER_PADDING = 6
local npcFilterMenu = nil
local npcFilterRows = {}
local npcFilterMenuCatcher = nil

-- A full-screen, invisible click-catcher shown only while the menu is open,
-- strata "HIGH" -- above every addon-owned button (all "MEDIUM", the strata
-- Client.CreateMinimapButton/CreateHudButton use) but below the menu itself
-- ("DIALOG"), so a click anywhere except the menu's own rows reaches this
-- frame instead and closes the menu, while clicks on the menu keep it open.
local function ResolveNpcFilterMenuCatcher()
    if npcFilterMenuCatcher then
        return npcFilterMenuCatcher
    end
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent then
        return nil
    end
    local ok, catcher = pcall(create, "Button", "UnrealQuestNpcFilterMenuCatcher", parent)
    if not ok or not catcher then
        return nil
    end
    if type(catcher.SetFrameStrata) == "function" then
        pcall(catcher.SetFrameStrata, catcher, "HIGH")
    end
    if type(catcher.SetAllPoints) == "function" then
        pcall(catcher.SetAllPoints, catcher, parent)
    end
    if type(catcher.EnableMouse) == "function" then
        pcall(catcher.EnableMouse, catcher, true)
    end
    if type(catcher.RegisterForClicks) == "function" then
        pcall(catcher.RegisterForClicks, catcher, "LeftButtonUp")
    end
    pcall(catcher.SetScript, catcher, "OnClick", function()
        Client.HideNpcFilterMenu()
    end)
    pcall(catcher.Hide, catcher)
    npcFilterMenuCatcher = catcher
    return catcher
end

local function ResolveNpcFilterMenu()
    if npcFilterMenu then
        return npcFilterMenu
    end
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent then
        return nil
    end
    local ok, menu = pcall(create, "Frame", "UnrealQuestNpcFilterMenu", parent)
    if not ok or not menu then
        return nil
    end
    if type(menu.SetFrameStrata) == "function" then
        pcall(menu.SetFrameStrata, menu, "DIALOG")
    end
    if type(menu.EnableMouse) == "function" then
        pcall(menu.EnableMouse, menu, true)
    end
    local background = CreateSolid(menu, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], 0.94)
    if background and type(background.SetAllPoints) == "function" then
        pcall(background.SetAllPoints, background, menu)
    end
    BuildFlatBorder(menu)
    pcall(menu.Hide, menu)
    npcFilterMenu = menu
    return menu
end

local function PaintNpcFilterRow(row)
    local entry = row and row.unrealQuestEntry
    if not row or not entry then
        return
    end
    if row.unrealQuestCheck then
        pcall(row.unrealQuestCheck.SetText, row.unrealQuestCheck,
            entry.checked and "[x]" or "[ ]")
        if entry.checked then
            pcall(row.unrealQuestCheck.SetTextColor, row.unrealQuestCheck,
                UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3])
        else
            pcall(row.unrealQuestCheck.SetTextColor, row.unrealQuestCheck, 0.55, 0.55, 0.55)
        end
    end
    if row.unrealQuestLabel then
        pcall(row.unrealQuestLabel.SetText, row.unrealQuestLabel, entry.label or entry.key or "?")
        pcall(row.unrealQuestLabel.SetTextColor, row.unrealQuestLabel, 0.94, 0.94, 0.94)
    end
    if row.unrealQuestColor then
        pcall(row.unrealQuestColor.SetVertexColor, row.unrealQuestColor,
            entry.red or 1, entry.green or 1, entry.blue or 1, 1)
    end
end

local function GetNpcFilterRow(index)
    local menu = ResolveNpcFilterMenu()
    if not menu then
        return nil
    end
    local row = npcFilterRows[index]
    if row then
        return row
    end
    local create = Resolve("CreateFrame")
    if not create then
        return nil
    end
    local ok, button = pcall(create, "Button",
        "UnrealQuestNpcFilterRow" .. tostring(index), menu)
    if not ok or not button then
        return nil
    end
    Client.SetObjectSize(button, NPC_FILTER_MENU_WIDTH - NPC_FILTER_PADDING * 2,
        NPC_FILTER_ROW_HEIGHT)
    if type(menu.GetFrameLevel) == "function" and type(button.SetFrameLevel) == "function" then
        local levelOk, level = pcall(menu.GetFrameLevel, menu)
        if levelOk and type(level) == "number" then
            pcall(button.SetFrameLevel, button, level + 1)
        end
    end
    if type(button.EnableMouse) == "function" then
        pcall(button.EnableMouse, button, true)
    end
    if type(button.RegisterForClicks) == "function" then
        pcall(button.RegisterForClicks, button, "LeftButtonUp")
    end

    if type(button.CreateFontString) == "function" then
        local checkOk, check = pcall(
            button.CreateFontString, button, nil, "OVERLAY", "GameFontHighlightSmall")
        if checkOk and check then
            pcall(check.SetPoint, check, "LEFT", button, "LEFT", 2, 0)
            pcall(check.SetJustifyH, check, "LEFT")
            StripShadow(check)
            button.unrealQuestCheck = check
        end
        local labelOk, label = pcall(
            button.CreateFontString, button, nil, "OVERLAY", "GameFontHighlightSmall")
        if labelOk and label then
            pcall(label.SetPoint, label, "LEFT", button, "LEFT", 28, 0)
            pcall(label.SetJustifyH, label, "LEFT")
            StripShadow(label)
            button.unrealQuestLabel = label
        end
    end
    if type(button.CreateTexture) == "function" then
        local colorOk, color = pcall(button.CreateTexture, button, nil, "ARTWORK")
        if colorOk and color then
            pcall(color.SetTexture, color, WORLD_MAP_PIN_TEXTURE)
            pcall(color.SetWidth, color, 9)
            pcall(color.SetHeight, color, 9)
            pcall(color.SetPoint, color, "RIGHT", button, "RIGHT", -3, 0)
            button.unrealQuestColor = color
        end
        local hoverOk, hover = pcall(button.CreateTexture, button, nil, "BACKGROUND")
        if hoverOk and hover then
            pcall(hover.SetTexture, hover, WORLD_MAP_PIN_TEXTURE)
            pcall(hover.SetVertexColor, hover, 1, 1, 1, 0.08)
            pcall(hover.SetAllPoints, hover, button)
            pcall(hover.Hide, hover)
            button.unrealQuestHover = hover
        end
    end
    pcall(button.SetScript, button, "OnEnter", function()
        if button.unrealQuestHover then pcall(button.unrealQuestHover.Show, button.unrealQuestHover) end
    end)
    pcall(button.SetScript, button, "OnLeave", function()
        if button.unrealQuestHover then pcall(button.unrealQuestHover.Hide, button.unrealQuestHover) end
    end)
    pcall(button.SetScript, button, "OnClick", function()
        local entry = button.unrealQuestEntry
        if not entry then
            return
        end
        entry.checked = not entry.checked
        PaintNpcFilterRow(button)
        if type(npcFilterMenu.unrealQuestOnToggle) == "function" then
            npcFilterMenu.unrealQuestOnToggle(entry)
        end
    end)
    npcFilterRows[index] = button
    return button
end

function Client.ShowNpcFilterMenu(anchorFrame, entries, onToggle)
    local menu = ResolveNpcFilterMenu()
    if not menu or not anchorFrame or type(entries) ~= "table" then
        return false
    end
    local total = table.getn(entries)
    if total <= 0 then
        return false
    end
    menu.unrealQuestOnToggle = onToggle

    local index = 1
    while index <= total do
        local row = GetNpcFilterRow(index)
        if row then
            row.unrealQuestEntry = entries[index]
            PaintNpcFilterRow(row)
            pcall(row.ClearAllPoints, row)
            pcall(row.SetPoint, row, "TOPLEFT", menu, "TOPLEFT", NPC_FILTER_PADDING,
                -(NPC_FILTER_PADDING + (index - 1) * NPC_FILTER_ROW_HEIGHT))
            pcall(row.Show, row)
        end
        index = index + 1
    end
    while npcFilterRows[index] do
        pcall(npcFilterRows[index].Hide, npcFilterRows[index])
        index = index + 1
    end

    pcall(menu.SetWidth, menu, NPC_FILTER_MENU_WIDTH)
    pcall(menu.SetHeight, menu, NPC_FILTER_PADDING * 2 + total * NPC_FILTER_ROW_HEIGHT)
    pcall(menu.ClearAllPoints, menu)
    local screenWidth = Client.GetScreenSize()
    local left = nil
    if type(anchorFrame.GetLeft) == "function" then
        local leftOk, value = pcall(anchorFrame.GetLeft, anchorFrame)
        if leftOk and type(value) == "number" then left = value end
    end
    if type(screenWidth) == "number" and type(left) == "number" and left < screenWidth / 2 then
        pcall(menu.SetPoint, menu, "TOPLEFT", anchorFrame, "TOPRIGHT", 5, 0)
    else
        pcall(menu.SetPoint, menu, "TOPRIGHT", anchorFrame, "TOPLEFT", -5, 0)
    end
    pcall(menu.Show, menu)
    local catcher = ResolveNpcFilterMenuCatcher()
    if catcher then
        pcall(catcher.Show, catcher)
    end
    return true
end

function Client.HideNpcFilterMenu()
    if not npcFilterMenu then
        return false
    end
    npcFilterMenu.unrealQuestOnToggle = nil
    -- This client does not reliably propagate a parent's hidden state to its
    -- child widgets, so the pooled rows are hidden explicitly as well.
    local index = 1
    while npcFilterRows[index] do
        Client.HideObject(npcFilterRows[index])
        index = index + 1
    end
    if npcFilterMenuCatcher then
        Client.HideObject(npcFilterMenuCatcher)
    end
    return Client.HideObject(npcFilterMenu)
end

function Client.IsNpcFilterMenuShown()
    if not npcFilterMenu or type(npcFilterMenu.IsShown) ~= "function" then
        return false
    end
    local ok, shown = pcall(npcFilterMenu.IsShown, npcFilterMenu)
    return ok and shown and true or false
end

-- Capability declarations ---------------------------------------------------
-- Recorded once at load so /uq status reports the layer's real footing.

local function DeclareFunction(key, globalName, state, note)
    if Client.HasFunction(globalName) then
        UQ:DeclareCapability(key, state, note)
    else
        UQ:DeclareCapability(key, "missing", globalName .. " is not a callable global on this client")
    end
end

DeclareFunction("time", "GetTime", "verified",
    "GetTime measured accurate to wall clock; sole sanctioned elapsed-time source")
DeclareFunction("questLogSize", "GetNumQuestLogEntries", "verified",
    "exercised by the questtrack probe against a live quest log")
DeclareFunction("questLogEntry", "GetQuestLogTitle", "verified",
    "six-value tuple captured by the questtrack probe and matching the client API reference")
DeclareFunction("objectiveCount", "GetNumQuestLeaderBoards", "documented",
    "client API reference; not runtime-probed")
DeclareFunction("objectiveReadout", "GetQuestLogLeaderBoard", "documented",
    "client API reference; two-argument form not runtime-probed")
DeclareFunction("questWatchAdd", "AddQuestWatch", "verified",
    "AddQuestWatch/RemoveQuestWatch/IsQuestWatched round-trip on the raw quest log index")
DeclareFunction("questWatchRemove", "RemoveQuestWatch", "verified",
    "round-tripped with AddQuestWatch by the questtrack probe")
DeclareFunction("questWatchQuery", "IsQuestWatched", "verified",
    "raw quest log index space; watch list does not survive a UI reload")
DeclareFunction("questWatchCount", "GetNumQuestWatches", "documented",
    "client API reference; watch list capped at five quests")
DeclareFunction("questWatchRefresh", "QuestWatch_Update", "verified",
    "measured 2026-08-20: safely redraws QuestWatchFrame after AddQuestWatch")
if Client.HasBagScan() then
    UQ:DeclareCapability("bagScan", "documented",
        "GetContainerNumSlots and GetContainerItemLink are in the client API reference but the compact DB "
        .. "records the container surface as behaviour-untested (bags.container_api_contract_unverified). "
        .. "Used only to decide whether an item-use objective target is reachable yet; a nil read counts as "
        .. "unknown, and unknown draws nothing")
else
    UQ:DeclareCapability("bagScan", "missing",
        "GetContainerNumSlots or GetContainerItemLink is not a callable global; item-use objective targets "
        .. "stay hidden because the addon cannot tell whether the required item is carried")
end
DeclareFunction("playerLevel", "UnitLevel", "documented",
    "client API reference; unit API partially exercised by other probe groups")
DeclareFunction("playerRaceId", "UnitRace", "verified",
    "measured: UnitRace(\"player\") returns three values, the third a numeric race id (Human = 1), "
    .. "which yields the bundled data's race bitmask bit as 2^(id-1)")
DeclareFunction("playerClassId", "UnitClass", "verified",
    "measured: UnitClass(\"player\") returns three values, the third a numeric class id (Warlock = 9), "
    .. "which yields the bundled data's class bitmask bit as 2^(id-1)")
DeclareFunction("playerSex", "UnitSex", "documented",
    "client API reference: 1 unknown/neutral, 2 male, 3 female; used only for $G quest-text substitution")
DeclareFunction("questGreenRange", "GetQuestGreenRange", "documented",
    "client API reference; used because GetDifficultyColor is confirmed absent")
DeclareFunction("mapCurrent", "GetMapInfo", "verified",
    "measured 2026-08-20 after SetMapToCurrentZone; uninitialized immediately after reload")
DeclareFunction("mapPlayerPosition", "GetPlayerMapPosition", "verified",
    "measured non-zero on the current-zone map and absent when the view is uninitialized")
DeclareFunction("mapSetCurrentZone", "SetMapToCurrentZone", "verified",
    "probe mapcoldstart 2026-08-23: called before the world map was ever shown post-/reload, resolved "
    .. "zoneIndex 0/GetMapInfo nil/player 0,0 into zoneIndex 14/mapFile Elwynn/a real player position")
DeclareFunction("mouseoverUnit", "UnitName", "documented",
    "UnitName accepts the documented mouseover unit token; the player form is runtime-measured")

if ResolveGameTooltip() then
    UQ:DeclareCapability("entityTooltip", "documented",
        "GameTooltip is present; AddLine, NumLines and reading GameTooltipTextLeft1 back are documented, but "
        .. "this exact entity-objective sequence is not yet runtime-probed. Identity is read from "
        .. "GameTooltipTextLeft1 (the tooltip's own rendered first line), the same technique "
        .. "Interface/AddOns/pfQuest/map.lua uses and which a side-by-side comparison confirmed working on "
        .. "this install, rather than from UnitName(\"mouseover\"). The objective a creature satisfies is "
        .. "read out of the live quest log line itself through the questObjectivePatterns capability, so a "
        .. "kill objective needs no quest ID and no world-data record. Only AddLine is used to add content -- "
        .. "SetUnit was tried to force a full rebuild and reverted after that same comparison pointed at it as "
        .. "the likely cause of the tooltip going blank with unrealQuest enabled. /uq tooltip reports live "
        .. "counters so a hover session can be diagnosed from SavedVariables instead of a screenshot")
else
    UQ:DeclareCapability("entityTooltip", "missing",
        "GameTooltip was not available at load")
end

if Client.GetWorldMapCanvas() then
    UQ:DeclareCapability("worldMapCanvas", "detected",
        "WorldMapButton exists with measurable geometry; addon-owned child rendering confirmed in game")
else
    UQ:DeclareCapability("worldMapCanvas", "unverified",
        "WorldMapButton was not available at load and may be created lazily when the fullscreen map opens")
end

if Client.HasRaidTargetMarks() then
    UQ:DeclareCapability("questRaidMark", "unverified",
        "SetRaidTarget(unit, index) and GetRaidTargetIndex(unit) are in the client API reference "
        .. "(category Raid) and neither is marked protected. This is the ONLY way left to draw anything "
        .. "over one specific creature in the 3D world here: no unit world or screen position exists, no "
        .. "player facing is readable, and this client's nameplates are not Lua widgets -- a full "
        .. "inventory found WorldFrame's 26 children to be FrameXML furniture with no plate among them "
        .. "(docs/CLIENT-COMPATIBILITY.md item 12). Live evidence on 2026-08-23 established that the "
        .. "server ignores solo writes: nine writes against a correctly matched Kobold Tunneler produced "
        .. "zero confirmations and no visible mark. Party leader or raid assistant remains unverified. "
        .. "The call is a "
        .. "server round trip (\"the client sends index - 1 to the server\") so it cannot be verified by "
        .. "reading straight back. /uq marks reports writes, confirmations and refusals")
else
    UQ:DeclareCapability("questRaidMark", "missing",
        "SetRaidTarget or GetRaidTargetIndex is not a callable global, so nothing can be drawn over a "
        .. "specific creature in the world at all on this client")
end
UQ:DeclareCapability("questIdentity", "missing",
    "the client exposes no quest ID API; quest log rows are matched to the static database by title")
UQ:DeclareCapability("completedQuestHistory", "missing",
    "the client exposes no completed-quest query; history must be observed and stored by the addon")
UQ:DeclareCapability("questEvents", "verified",
    "measured 2026-08-20: QUEST_LOG_UPDATE, UNIT_QUEST_LOG_CHANGED, QUEST_WATCH_UPDATE, QUEST_FINISHED, "
    .. "QUEST_COMPLETE and PLAYER_LEVEL_UP fire; QUEST_ACCEPTED and QUEST_ITEM_UPDATE did not in that session. "
    .. "Poll remains the correctness guarantee -- see docs/CLIENT-COMPATIBILITY.md \"Quest events\"")
UQ:DeclareCapability("worldMapPinTooltip", "verified",
    "user confirmed in game 2026-08-22: a tooltip anchored to a custom map-canvas child displays, but "
    .. "only through WorldMapTooltip -- the identical construction on GameTooltip showed nothing, which "
    .. "was the original failure (worldmap.custom_pin_gametooltip_never_appeared)")
UQ:DeclareCapability("worldMapAreaHover", "verified",
    "user confirmed in game 2026-08-22 on the quest-area tiles: EnableMouse/OnEnter/OnLeave on an "
    .. "addon-owned child of WorldMapButton do receive the mouse; hovers are counted into "
    .. "mapDiagnostics.areaHovers")
UQ:DeclareCapability("worldMapPinInteraction", "verified",
    "measured 2026-08-22 in the live SavedVariables: giverHovers 1, giverClicks 3 with the shift flag "
    .. "reading true, turnInHovers 7 -- all written only from scripts on 14x14 pins, so a pin that small "
    .. "does win the mouse and OnClick is delivered on a map-canvas child "
    .. "(worldmap.custom_14x14_pin_receives_mouse_and_clicks)")
UQ:DeclareCapability("worldMapPinIcons", "verified",
    "user confirmed in game 2026-08-22: Interface\\GossipFrame\\ActiveQuestIcon draws on a custom 14x14 "
    .. "pin with pinFailures 0, so the client's own gossip \"!\"/\"?\" art resolves as a pin BACKGROUND "
    .. "texture rather than rendering empty (worldmap.gossip_quest_icon_textures_render_on_custom_pin)")

-- Waypoint / HUD capabilities ------------------------------------------------

DeclareFunction("screenSize", "GetScreenWidth", "documented",
    "GetScreenWidth/GetScreenHeight are in the client API reference (System); the waypoint marker needs "
    .. "them only to convert a yaw offset into a screen offset, and falls back to the frame's own "
    .. "UIParent geometry when they are absent")
DeclareFunction("scriptChaining", "getglobal", "verified",
    "Frame:GetScript is documented to return the stored handler and Frame:SetScript is exercised "
    .. "throughout this addon, which is the only way to add behaviour to a native widget here: this "
    .. "client has NO hooksecurefunc at all (knowledge.json / hooks.no_global_hooksecurefunc), so the "
    .. "usual Vanilla post-hook idiom does not exist")

-- Deliberately declared "missing" rather than left unmentioned. A true 3D
-- world-position-to-screen marker needs the camera's yaw, pitch and field of
-- view, and this client publishes none of it: the documented Camera surface is
-- SetView / SaveView / ResetView / NextView / PrevView / FlipCameraYaw /
-- CameraZoomIn / CameraZoomOut -- every one a setter -- and a search of the
-- whole compatibility database for WorldToScreen returns nothing. The waypoint
-- marker is therefore projected from the PLAYER's facing, not the camera's,
-- which is correct whenever the camera sits behind the character and drifts
-- while the player free-looks. Recording this here is what stops a later
-- session from "fixing" the marker by reaching for an API that does not exist.
UQ:DeclareCapability("cameraProjection", "missing",
    "no WorldToScreen and no camera getter anywhere in the client API reference or the compatibility "
    .. "database; the documented Camera category is setters only. The HUD waypoint projects the target "
    .. "through the player's facing instead, and cannot track free-look camera rotation")

UQ:DeclareCapability("playerFacing", "missing",
    "measured 2026-08-22 by UnrealRuntimeProbe 1.37.0 group `facing`: no readable player facing exists "
    .. "on this client. GetPlayerFacing and every camera getter are absent; Minimap has 7 children and "
    .. "none is a Model; and CreateFrame(\"Model\") carries SetFacing/SetRotation but NOT GetFacing, so "
    .. "the technique the installed pfQuest uses on Vanilla has no method to call here. A 60-sample run "
    .. "recorded the player turning a full circle with every candidate source unchanged. HUD waypoint "
    .. "direction therefore comes from movement (see playerHeadingFromMovement)")

UQ:DeclareCapability("playerHeadingFromMovement", "verified",
    "measured 2026-08-22: GetPlayerMapPosition tracks a walking player and is the only direction source "
    .. "this client offers. It is QUANTIZED TO ONE YARD -- observed steps were exactly 1/widthYards and "
    .. "1/heightYards of the bundled area dimensions -- so a bearing taken from a single 0.05s sample "
    .. "snaps to about 45 degrees. The estimator accumulates over a multi-yard baseline instead. It "
    .. "reports travel direction, not facing, and is silent while the player stands still")

UQ:DeclareCapability("hudWaypoint", "unverified",
    "an ordinary UIParent child with one file-backed BACKGROUND texture; the same material contract that "
    .. "is confirmed on the map canvas, but never yet confirmed over the 3D world on this client. "
    .. "/uq waypoint reports whether the marker was created, positioned and shown, so an invisible "
    .. "marker can be told apart from one that was never placed. NOTE: the only layer that would have "
    .. "settled this is gated off (UQ.features.mainQuestWaypoint), so this stays unverified by "
    .. "construction rather than by neglect -- no marker frame is created at all in the shipped build")

-- Quest tracker capabilities --------------------------------------------------

UQ:DeclareCapability("trackerWindowDrag", "verified",
    "the drag recipe is measured, not assumed (frames.movable_drag_requires_button_handle, "
    .. "BEHAVIOR_VERIFIED): a Button handle parented to the moved frame, raised with SetFrameLevel, "
    .. "SetMovable(true) applied immediately before each drag, and the real StartMoving preceded by a "
    .. "StartMoving/StopMovingOrSizing warm-up pair. The failed shape -- a mouse-enabled plain Frame on "
    .. "UIParent raised by strata -- never received OnDragStart at all. Which of the five factors is "
    .. "decisive was never isolated, so all five are reproduced")

UQ:DeclareCapability("trackerPositionMemory", "verified",
    "GetPoint here returns the relative frame as a NAME STRING and inverts the Y offset against the "
    .. "SetPoint that produced it (frames.getpoint_relative_name_y_inverted, BEHAVIOR_VERIFIED); "
    .. "Client.GetFrameAnchor undoes both, and capturing UIParent-relative through that reader is "
    .. "confirmed end to end to survive a reload. Only the anchor point name and two numbers are "
    .. "persisted -- never a path, per the SavedVariables backslash hazard")

UQ:DeclareCapability("trackerWindowResize", "verified",
    "the corner grip reproduces UnrealUI's measured chat-resize recipe (chat.chatframe1_resize.v1, "
    .. "SUPPORTED/BEHAVIOR_VERIFIED) rather than inventing one: the grip is GENUINELY MOVED by the "
    .. "client through the same five-factor StartMoving recipe the drag handle needs, and the live "
    .. "geometry is read back from the grip's own GetLeft/GetBottom. The failed shape -- leaving the "
    .. "grip anchored and reading GetCursorPosition instead -- never put the client into a drag state, "
    .. "so OnDragStop never fired and the window kept following the cursor after the button was "
    .. "released. Moving the grip for real is what makes the release report at all")

if Client.HasFunction("SelectQuestLogEntry") then
    UQ:DeclareCapability("questLogSelect", "documented",
        "SelectQuestLogEntry is in the client API reference (category Quest) and is documented to clear "
        .. "the selection when handed a header or an out-of-range index; not runtime-probed. A tracker "
        .. "row click selects the quest and then tries to open QuestLogFrame")
else
    UQ:DeclareCapability("questLogSelect", "missing",
        "SelectQuestLogEntry is not a callable global; clicking a tracker row cannot open that quest")
end

if Client.HasFunction("CT_QuestLevels_oldGetQuestLogTitle") then
    UQ:DeclareCapability("questLogTitleUnhooked", "detected",
        "CT_QuestLevels_oldGetQuestLogTitle is present, so a level-prefixing addon has hooked "
        .. "GetQuestLogTitle. Quest log rows are read through the saved original instead, the way pfQuest "
        .. "does, so titles reach the matcher undecorated")
else
    UQ:DeclareCapability("questLogTitleUnhooked", "missing",
        "No CT_QuestLevels-style saved original was present AT LOAD -- an addon that hooks "
        .. "GetQuestLogTitle later is still picked up at read time, so this line is a load-order "
        .. "snapshot, not the path in use. Either way quest log rows have any level decoration "
        .. "stripped from them (Client.CleanQuestTitle); /uq quests reports how many were seen")
end

if Client.HasFunction("GetQuestLogQuestText") then
    UQ:DeclareCapability("questLogDetailText", "documented",
        "GetQuestLogQuestText is in the client API reference (category Quest) as a no-argument reader of "
        .. "the selected quest's description and objectives text together; not runtime-probed. "
        .. "Data/QuestMatch.lua checks the result by substring against both the bundled detail and "
        .. "objectives strings rather than assuming which one it returns, and only accepts a match when "
        .. "exactly one candidate agrees")
else
    UQ:DeclareCapability("questLogDetailText", "missing",
        "GetQuestLogQuestText is not a callable global; same-title quest chains stay ambiguous")
end

if Client.GetNativeQuestWatchFrame() then
    UQ:DeclareCapability("nativeQuestWatchFrame", "verified",
        "QuestWatchFrame confirmed in game as the native tracked-objectives root "
        .. "(questwatch.native_root_user_confirmed). Hidden while UnrealQuest's own window is up if the "
        .. "trackerHideNativeWatch setting is on, and re-shown when it is turned off. Only Hide/Show are "
        .. "used -- no script is ever attached to it, because SetScript cannot be undone on this client")
else
    UQ:DeclareCapability("nativeQuestWatchFrame", "missing",
        "QuestWatchFrame was not available at load, so the native tracked-objectives panel cannot be "
        .. "hidden and may draw alongside the addon's own window")
end

if Client.HasFunction("ShowUIPanel") and Client.HasObject("WorldMapFrame") then
    UQ:DeclareCapability("worldMapOpen", "documented",
        "Ctrl+click on a tracker row calls Client.OpenWorldMap, which uses ShowUIPanel(WorldMapFrame) -- "
        .. "the same open-not-toggle idiom Client.OpenQuestLog already relies on. ToggleWorldMap is "
        .. "confirmed present but deliberately unused: WorldMapFrame:IsShown()/IsVisible() do not "
        .. "reliably reflect this client's fullscreen presentation "
        .. "(docs/WORLD-MAP-PINS-RECOVERY.md), so a blind toggle could close a map the player already "
        .. "had open. This exact ShowUIPanel(WorldMapFrame) call is not itself runtime-probed")
else
    UQ:DeclareCapability("worldMapOpen", "missing",
        "ShowUIPanel or WorldMapFrame is not available at load; Ctrl+click can still flash an already-"
        .. "rendered pin but cannot open the map for the player")
end
