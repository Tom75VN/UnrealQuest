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

-- Collects GetMapZones' varargs into a list. A named function rather than an
-- inline closure so the pcall above allocates nothing per call.
local function CollectMapZones(zones, continent)
    return { zones(continent) }
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
-- requirement is what makes this safe to apply unconditionally: real quest
-- titles in the upstream data do begin with a bracket group (translation-status
-- markers such as "unused" and "reused" -- eight of them in pfQuest's koKR
-- tables, which this addon no longer bundles), but not one of them puts a
-- digit first, so no real title in the data can be cut by this.
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

-- How many OTHER party members are on the quest at a quest log index, or nil
-- when the question does not apply -- the player is alone, the row is not a
-- quest, or nobody in the party shares it.
--
-- IsUnitOnQuest is documented as answering true when that party member has the
-- same quest as the given quest log ROW (an index into the log, not a quest
-- ID -- which this client does not expose anyway), and as yielding NO value
-- when the row is not a quest, the unit is not a player, or that player is not
-- in the party. A missing return is therefore "no", never a failure, so the
-- loop below never has to tell the two apart.
--
-- Only party1..N are asked. The documentation is explicit that the local
-- player is not counted, and there is no raid equivalent of this call here, so
-- a raid simply reports what its party sub-group can answer for.
--
-- GetNumPartyMembers counts other members and answers 0 when alone, so a solo
-- player never reaches IsUnitOnQuest at all.
function Client.GetQuestLogPartyCount(index)
    if type(index) ~= "number" then
        return nil
    end
    local ok, members = Call0("GetNumPartyMembers")
    if not ok or type(members) ~= "number" or members <= 0 then
        return nil
    end
    local fn = Resolve("IsUnitOnQuest")
    if not fn then
        return nil
    end
    -- Resolved once and called directly rather than through Call2: this is the
    -- compatibility layer itself, and the loop would otherwise re-resolve the
    -- same global on every party member of every visible row.
    local count = 0
    local member = 1
    while member <= members do
        local called, onQuest = pcall(fn, index, "party" .. member)
        if called and onQuest then
            count = count + 1
        end
        member = member + 1
    end
    if count <= 0 then
        return nil
    end
    return count
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

-- Puts the quest log selection back exactly as it was found, including back
-- to "nothing selected".
--
-- The selection is global state the native UI reads too: GetQuestLogLeaderBoard
-- and GetQuestLogQuestText answer for the selected row whenever they are not
-- given a row of their own. Leaving it parked on the last row this addon
-- happened to scan is therefore not harmless -- it silently redirects every
-- unqualified read the rest of the UI makes. SelectQuestLogEntry is documented
-- to clear the selection for an out-of-range index, which is how the cleared
-- state (GetQuestLogSelection() == 0) is restored rather than left behind.
local function RestoreQuestLogSelection(previousOk, previous)
    if not previousOk or type(previous) ~= "number" then
        return
    end
    if previous > 0 then
        Call1("SelectQuestLogEntry", previous)
    else
        Call1("SelectQuestLogEntry", 0)
    end
end

local function ReadObjectiveSelected(objectiveIndex, questIndex)
    local fn = Resolve("GetQuestLogLeaderBoard")
    if not fn then
        return nil
    end
    local previousOk, previous = Call0("GetQuestLogSelection")
    Call1("SelectQuestLogEntry", questIndex)
    local ok, text, objectiveType, isFinished = pcall(fn, objectiveIndex)
    RestoreQuestLogSelection(previousOk, previous)
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
    RestoreQuestLogSelection(previousOk, previous)
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

-- OFFICIAL_CLIENT_DOCUMENTATION: these two calls report the selected quest's
-- choice and guaranteed reward counts. Probe questrewardlayout.live_geometry.v1
-- also observed both values while walking the live quest log, including the
-- one-guaranteed-item/coin combination that needs a distinct tail row.
function Client.GetQuestLogRewardCounts()
    local choices = 0
    local rewards = 0
    local ok, value = Call0("GetNumQuestLogChoices")
    if ok and type(value) == "number" and value > 0 then
        choices = value
    end
    ok, value = Call0("GetNumQuestLogRewards")
    if ok and type(value) == "number" and value > 0 then
        rewards = value
    end
    return choices, rewards
end

-- OFFICIAL_CLIENT_DOCUMENTATION: reward and required money are separate
-- copper totals for the selected quest. They are read here so the modern
-- integration can restore a native money frame hidden during reparenting;
-- zero or an unavailable call leaves native visibility untouched.
function Client.GetQuestLogMoneyAmounts()
    local reward = 0
    local required = 0
    local ok, value = Call0("GetQuestLogRewardMoney")
    if ok and type(value) == "number" and value > 0 then
        reward = value
    end
    ok, value = Call0("GetQuestLogRequiredMoney")
    if ok and type(value) == "number" and value > 0 then
        required = value
    end
    return reward, required
end

-- Rebuilds the stock quest-log rows and detail pane. A focused runtime probe
-- called this public FrameXML helper successfully (questlogmark.public_refresh_ownership.v1,
-- BEHAVIOR_PARTIALLY_TESTED, 2026-08-27). Translation uses it only to hand
-- native text back when its language/selection changes or the option is
-- disabled; the regular presentation remains poll-driven.
function Client.RefreshQuestLog()
    local ok = Call0("QuestLog_Update")
    return ok and true or false
end

-- The DETAIL pane specifically, which QuestLog_Update does not own.
--
-- knowledge.json / questlog.native_refresh_font_colours (USER_CONFIRMED_INGAME)
-- names QuestLog_Update and QuestLog_UpdateQuestDetails as two separate
-- repaint entry points on this client, and its solution reapplies fonts after
-- BOTH -- which is what says the second one exists because the first does not
-- cover the detail fields. A caller that has replaced QuestLogQuestTitle,
-- QuestLogObjectivesText or QuestLogQuestDescription and wants the client's
-- own text back therefore has to ask for this one too.
--
-- Still only an accelerator: Quest/QuestLogTranslation.lua restores the text it
-- replaced from its own record and does not depend on either call landing.
function Client.RefreshQuestLogDetails()
    local ok = Call0("QuestLog_UpdateQuestDetails")
    return ok and true or false
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

-- Can the native tracked-objectives panel survive this quest?
--
-- QuestWatch_Update walks the watch list, takes the objective count from
-- GetNumQuestLeaderBoards(questIndex), and then reads each line with the
-- two-argument GetQuestLogLeaderBoard(objectiveIndex, questIndex), which it
-- concatenates without a nil check ("attempt to concatenate local 'text'",
-- QuestLogFrame.lua). The error is raised inside QuestLog_OnEvent on
-- QUEST_LOG_UPDATE, so no addon is on the stack and no pcall of ours can catch
-- it -- it just throws in the player's face on every quest log update.
--
-- Whether that two-argument form answers for a given row is exactly what this
-- layer already refuses to assume (see the objectiveReadout note above): this
-- addon can fall back to the selection-based path, but the native panel cannot.
-- Since this addon is what puts quests into the watch list, it asks the same
-- question the panel will ask, in the same way, and declines to feed the panel
-- a quest whose objectives do not come back.
function Client.CanNativeWatchQuest(questIndex)
    if type(questIndex) ~= "number" then
        return false
    end
    local count = Client.GetObjectiveCount(questIndex)
    if count <= 0 then
        -- The panel skips a quest with no objectives before it reads any line.
        return true
    end
    local index = 1
    while index <= count do
        local text = ReadObjectiveIndexed(index, questIndex)
        if type(text) ~= "string" or text == "" then
            return false
        end
        index = index + 1
    end
    return true
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

-- Level of any unit token. Documented, not probed here: UnitLevel returns the
-- level, -1 for a skull unit and 0 when the unit does not exist. Only a
-- positive level is returned; everything else is nil.
function Client.GetUnitLevel(unit)
    local ok, value = Call1("UnitLevel", unit)
    if ok and type(value) == "number" and value > 0 then
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

-- OFFICIAL_CLIENT_DOCUMENTATION: UnitClassification returns one of elite,
-- rareelite, worldboss, rare or normal for a live unit token. The rare-kill
-- history uses it only to reject an ordinary creature that happens to share a
-- name with a ranked database record; an unavailable or unexpected result is
-- not treated as a match.
function Client.GetUnitClassification(unit)
    local ok, value = Call1("UnitClassification", unit)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- OFFICIAL_CLIENT_DOCUMENTATION: UnitIsDead returns true for a dead unit and
-- nil for a living or missing one. Callers establish UnitExists first, so nil
-- after a successful call is the living answer; nil from this wrapper means
-- the function itself could not be called.
function Client.IsUnitDead(unit)
    local ok, value = Call1("UnitIsDead", unit)
    if not ok then
        return nil
    end
    return value and true or false
end

-- OFFICIAL_CLIENT_DOCUMENTATION: UnitAffectingCombat exposes a unit's combat
-- flag. The kill counter latches this while both player and target are alive;
-- it is corroboration that the player participated, not a claim that the API
-- identifies the killing blow.
function Client.IsUnitInCombat(unit)
    local ok, value = Call1("UnitAffectingCombat", unit)
    if not ok then
        return nil
    end
    return value and true or false
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

-- Group chat --------------------------------------------------------------
--
-- The chat type token a message to the player's own group has to carry. A
-- raid does not read "PARTY" and a party has no "RAID" channel, so the two
-- cannot be collapsed into one constant. nil means "no group", which every
-- caller treats as "there is nobody to tell" rather than as a failure.
--
-- GetNumRaidMembers is documented as counting the whole roster INCLUDING the
-- player and answering 0 for a five-player party, so it is asked first and a
-- non-zero answer settles it.
function Client.GetGroupChatChannel()
    local raidOk, raidValue = Call0("GetNumRaidMembers")
    if raidOk and type(raidValue) == "number" and raidValue > 0 then
        return "RAID"
    end
    local ok, value = Call0("GetNumPartyMembers")
    if ok and type(value) == "number" and value > 0 then
        return "PARTY"
    end
    return nil
end

function Client.HasChatSend()
    return Client.HasFunction("SendChatMessage")
end

-- Sends one line to a chat channel on the player's behalf.
--
-- THE ONE THING TO KNOW ABOUT THIS WRAPPER: the client API reference expects
-- this to FAIL from an addon. Its Communication page is explicit -- "SendChat-
-- Message is protected: it errors unless called from a secure (Blizzard UI)
-- context. DoEmote and SendAddonMessage are not." -- and the entry repeats it
-- ("addons cannot call this; only the default FrameXML UI can"). No probe has
-- exercised it, so it is documentation rather than measurement, but it is
-- documentation pointing one way.
--
-- The wrapper exists anyway because the cost of trying is one guarded call: if
-- this client turns out to allow it, the visible line is what the player asked
-- for. Quest/ObjectiveAnnounce.lua tries it first, counts the refusals, and
-- falls back to the addon channel below -- which the same sentence says is not
-- protected -- so the feature does not depend on the answer.
--
-- The message is clamped to CHAT_MESSAGE_LIMIT bytes. The client truncates or
-- rejects an over-long line itself and neither outcome is worth handing it.
local CHAT_MESSAGE_LIMIT = 255

-- Addon-to-addon messages -----------------------------------------------------
--
-- The other half of the group channel, and the half that is NOT protected: the
-- same client reference page that marks SendChatMessage protected says so in
-- one sentence -- "SendChatMessage is protected: it errors unless called from a
-- secure (Blizzard UI) context. DoEmote and SendAddonMessage are not." So this
-- is the route an addon actually has to the group, and Quest/QuestSync.lua is
-- built on it.
--
-- Documented shape here: SendAddonMessage(prefix, message, chatType), where the
-- prefix and the message are joined with a TAB by the client and sent with
-- language ADDON on chatType. There is no whisper-target argument.
--
-- RECEIVING is the unverified half. This client's reference documents no event
-- names at all and the compatibility database has no CHAT_MSG_ADDON record, so
-- whether a sent message ever comes back to another addon is settled only by
-- two clients trying it. Nothing degrades badly if it does not: an addon that
-- never hears a peer simply knows of no peer.
local ADDON_MESSAGE_LIMIT = 240

function Client.HasAddonMessages()
    return Client.HasFunction("SendAddonMessage")
end

function Client.SendAddonMessage(prefix, message, chatType)
    if type(prefix) ~= "string" or prefix == "" then
        return false
    end
    if type(message) ~= "string" or message == "" then
        return false
    end
    if type(chatType) ~= "string" or chatType == "" then
        return false
    end
    if string.len(message) > ADDON_MESSAGE_LIMIT then
        message = string.sub(message, 1, ADDON_MESSAGE_LIMIT)
    end
    local fn = Resolve("SendAddonMessage")
    if not fn then
        return false
    end
    local ok = pcall(fn, prefix, message, chatType)
    return ok and true or false
end

-- The other players in the group, by name, so a peer record can be dropped the
-- moment its player is no longer in the group. Read by polling rather than off
-- a roster event, for the reason every other read here is polled: no event on
-- this client is proven to fire.
function Client.GetGroupMemberNames()
    local names = {}
    local raidOk, raidValue = Call0("GetNumRaidMembers")
    if raidOk and type(raidValue) == "number" and raidValue > 0 then
        local index = 1
        while index <= raidValue do
            local name = Client.GetUnitName("raid" .. index)
            if name then
                names[name] = true
            end
            index = index + 1
        end
        return names
    end
    local ok, value = Call0("GetNumPartyMembers")
    if ok and type(value) == "number" and value > 0 then
        local index = 1
        while index <= value do
            local name = Client.GetUnitName("party" .. index)
            if name then
                names[name] = true
            end
            index = index + 1
        end
    end
    return names
end

function Client.SendChatMessage(text, chatType)
    if type(text) ~= "string" or text == "" then
        return false
    end
    if type(chatType) ~= "string" or chatType == "" then
        return false
    end
    if string.len(text) > CHAT_MESSAGE_LIMIT then
        text = string.sub(text, 1, CHAT_MESSAGE_LIMIT)
    end
    local ok = Call2("SendChatMessage", text, chatType)
    return ok and true or false
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
-- The second result distinguishes a confirmed hidden frame (false) from an
-- empty first line while shown (true), or an unavailable visibility read (nil).
function Client.GetGameTooltipUnitLabel()
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(tooltip.IsShown) ~= "function" then
        return nil
    end
    local shownOk, shown = pcall(tooltip.IsShown, tooltip)
    if not shownOk then
        return nil
    end
    if not shown then
        return nil, false
    end
    local label = ResolveObject("GameTooltipTextLeft1")
    if not label or type(label.GetText) ~= "function" then
        return nil, true
    end
    local ok, text = pcall(label.GetText, label)
    if not ok or type(text) ~= "string" or text == "" then
        return nil, true
    end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return text, true
end

-- Reads back one of GameTooltip's own rendered rows. Region naming
-- (GameTooltipTextLeft<i> / GameTooltipTextRight<i>) is runtime-confirmed on
-- this client by the tooltipRegions capture in probe `tooltiphide`. The row's
-- colour comes from FontString:GetTextColor, which is documented but not
-- runtime-verified here, so a failure falls back to plain white rather than
-- dropping the row.
local function ReadGameTooltipRow(name)
    local label = ResolveObject(name)
    if not label or type(label.GetText) ~= "function" then
        return nil
    end
    if type(label.IsShown) == "function" then
        local shownOk, shown = pcall(label.IsShown, label)
        if shownOk and not shown then
            return nil
        end
    end
    local ok, text = pcall(label.GetText, label)
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    local r, g, b = 1, 1, 1
    if type(label.GetTextColor) == "function" then
        local colorOk, red, green, blue = pcall(label.GetTextColor, label)
        if colorOk and type(red) == "number" and type(green) == "number"
                and type(blue) == "number" then
            r, g, b = red, green, blue
        end
    end
    return text, r, g, b
end

-- Everything GameTooltip is currently displaying, row by row, in the line
-- shape RenderTooltipLines consumes. This is GetGameTooltipUnitLabel's
-- technique widened from the first row to all of them: it can only ever
-- report what the native tooltip actually has on screen right now.
--
-- It exists so a MULTI-line native tooltip (a creature: name, level, faction,
-- and so on) can be reproduced inside the single owned replacement instead of
-- leaving the native one visible with a second panel hanging under it. Only
-- text is reproduced -- the native health status bar is not a text region and
-- has no counterpart here.
--
-- Returns nil when the tooltip is not shown or no row could be read, which is
-- the caller's signal to leave the native tooltip alone.
function Client.GetGameTooltipLines()
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(tooltip.IsShown) ~= "function" then
        return nil
    end
    local shownOk, shown = pcall(tooltip.IsShown, tooltip)
    if not shownOk or not shown then
        return nil
    end
    local count = Client.GetGameTooltipLineCount()
    if type(count) ~= "number" or count < 1 then
        return nil
    end

    local lines = {}
    local index = 1
    while index <= count do
        local leftText, r, g, b = ReadGameTooltipRow("GameTooltipTextLeft" .. index)
        if leftText then
            -- Right-hand rows exist for every line but are only populated for
            -- some of them; an empty one must stay an ordinary single line.
            local rightText, rightR, rightG, rightB =
                ReadGameTooltipRow("GameTooltipTextRight" .. index)
            if rightText then
                table.insert(lines, {
                    left = leftText, right = rightText,
                    r = r, g = g, b = b,
                    rightR = rightR, rightG = rightG, rightB = rightB,
                })
            else
                table.insert(lines, { text = leftText, r = r, g = g, b = b })
            end
        else
            -- A missing row inside NumLines is an incomplete rebuild, not a
            -- new shorter tooltip. Let the consumer retain its good snapshot.
            return nil
        end
        index = index + 1
    end

    if table.getn(lines) == 0 then
        return nil
    end
    return lines
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

-- Uses the exact boundary GetQuestLevelColor paints grey, kept as a boolean
-- so map policy never has to infer semantics back from RGB values.
function Client.IsQuestLevelTrivial(questLevel, playerLevel, greenRange)
    if type(playerLevel) ~= "number" then
        playerLevel = Client.GetPlayerLevel()
    end
    if type(questLevel) ~= "number" or type(playerLevel) ~= "number" then
        return false
    end
    if type(greenRange) ~= "number" or greenRange <= 0 then
        greenRange = Client.GetQuestGreenRange() or 5
    end
    return questLevel <= playerLevel - greenRange
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

-- The name of the zone the world map is CURRENTLY SHOWING, which is the only
-- question the pin layer actually has. Every other route to it goes through
-- the player's own position and can therefore be shadowed by a subzone: the
-- addon's persisted mapDiagnostics measured GetZoneText returning "Brill Town
-- Hall" (a real area, 2118, with no quest data) while the Tirisfal map was
-- open, which silently emptied the whole layer. The viewed map cannot lie
-- about itself.
--
-- GetMapZones is DOCUMENTED on this client ("the localized zone names loaded
-- for the currently selected continent") and GetCurrentMapZone is the index
-- into that list, exactly as the stock UI and the installed pfQuest both use
-- them. Neither is runtime-probed, so this returns nil on anything unexpected
-- and Map/MapContext.lua falls back to the name routes it used before.
--
-- The list is cached, like pfQuest's own map_zone_cache: the call returns a
-- varargs list that has to be collected into a table, and Inspect runs on
-- every map and minimap refresh -- ten times a second for the minimap, which
-- Core/Driver.lua names as exactly the place not to allocate per tick.
--
-- Cached WITH AN EXPIRY, though, and this is the load-bearing part. The
-- client's own reference says the continent argument is "required; not used"
-- and that what comes back is the list "loaded for the currently selected
-- continent". So the list is a property of client state, not of the argument,
-- and a cache keyed on the argument can hold one continent's names under
-- another continent's key if the selected continent changes before its list
-- is loaded. Every consumer of this indexes it by GetCurrentMapZone, so a
-- stale list does not fail loudly -- it names the wrong zone confidently, and
-- everything downstream then draws another zone's quests. The expiry bounds
-- that to one interval, and re-reading it costs one table every few seconds.
-- ONE slot, tagged with the continent it was actually read under -- not a
-- table keyed by continent, which is what this was and why it could hand back
-- the wrong continent's names.
--
-- The distinction is the whole point. The client's reference says the
-- continent argument is "required; not used" and that the list belongs to the
-- SELECTED continent, so the argument a caller passes is a statement of
-- intent, never a key the client honours. Storing the continent the list was
-- read under, and refusing to serve it under any other, is the only shape in
-- which the fallback below is safe.
local mapZoneNames = nil
local mapZoneNamesContinent = nil
local mapZoneNamesAt = nil
local MAP_ZONE_NAME_TTL = 5

function Client.GetMapZoneNames(continent)
    if type(continent) ~= "number" then
        return nil
    end
    local now = Client.Now()
    if mapZoneNames and mapZoneNamesContinent == continent
        and now and mapZoneNamesAt and now - mapZoneNamesAt < MAP_ZONE_NAME_TTL then
        return mapZoneNames
    end
    local zones = Resolve("GetMapZones")
    if not zones then
        return nil
    end
    local ok, list = pcall(CollectMapZones, zones, continent)
    if not ok or type(list) ~= "table" or table.getn(list) == 0 then
        -- The documentation is explicit that the list is empty until the map
        -- subsystem has been touched this session. Keep whatever was last
        -- read rather than treating an empty answer as the truth -- but only
        -- while it describes the continent being asked about, because an
        -- empty read right after a continent change is exactly when serving
        -- the previous continent's names would be worst.
        if mapZoneNamesContinent == continent then
            return mapZoneNames
        end
        return nil
    end
    mapZoneNames = list
    mapZoneNamesContinent = continent
    mapZoneNamesAt = now
    return list
end

function Client.GetMapZoneName(continent, zoneIndex)
    if type(zoneIndex) ~= "number" or zoneIndex < 1 then
        return nil
    end
    local list = Client.GetMapZoneNames(continent)
    local name = list and list[zoneIndex]
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

-- Forces the next read to go back to the client, without throwing away the
-- last good list.
--
-- Discarding it is what an earlier version did, and it turned a documented
-- transient into a visible fault: an empty GetMapZones read straight after a
-- view change left GetMapZoneNames with nothing to fall back on, so
-- MapContext could not name the viewed zone, the whole pin layer hid itself
-- on a map that had just been moved on purpose, and the parked-view logic
-- read the resulting nil as "the player navigated away". The list is kept and
-- only its freshness is dropped; GetMapZoneNames above refuses to serve it
-- under a different continent, which is the case discarding it was protecting
-- against.
function Client.InvalidateMapZoneNames()
    mapZoneNamesAt = nil
end

-- Selects what the world map is SHOWING. This is the only route this client
-- offers to a zone the player is not standing in, and Map/MapContext.lua's
-- ShowAreas is its only caller.
--
-- DOCUMENTED, not probed (OFFICIAL_CLIENT_DOCUMENTATION,
-- global:Mapping:SetMapZoom): the one-argument form sets the layer, with
-- continent ids matching GetCurrentMapContinent (0 cosmic, 1 Kalimdor,
-- 2 Eastern Kingdoms), and "the two-argument form selects a zone by 1-based
-- index into the currently loaded zone list". The same entry is explicit that
-- the continent must be selected FIRST so GetMapZones matches it before an
-- index is passed -- which is why this takes the two forms as one call and
-- the caller drives them in that order rather than guessing an index against
-- a list belonging to another continent.
--
-- pcall returning true says the call did not error, never that the view
-- moved, so the caller re-reads GetCurrentMapZone instead of trusting this.
function Client.SetWorldMapView(continent, zoneIndex)
    if type(continent) ~= "number" then
        return false
    end
    local ok
    if type(zoneIndex) == "number" and zoneIndex >= 1 then
        ok = Call2("SetMapZoom", continent, zoneIndex)
    else
        ok = Call1("SetMapZoom", continent)
    end
    if not ok then
        return false
    end
    Client.InvalidateMapZoneNames()
    return true
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
    if not ok then
        return false
    end
    -- Same reason as Client.SetWorldMapView: this can change which continent
    -- is selected, so the name lists cached per continent stop being trustable.
    Client.InvalidateMapZoneNames()
    return true
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

-- The zone name that a building or other subzone cannot shadow.
--
-- MEASURED 2026-08-26, from the addon's own persisted mapDiagnostics: standing
-- inside Brill Town Hall with the Tirisfal map open, Client.GetZoneText
-- returned "Brill Town Hall", which resolves uniquely to area 2118 in the
-- bundled zone table. Every quest location is recorded against the zone (85,
-- "Tirisfal Glades"), so the whole map layer matched its quests, found no
-- locations for area 2118 and drew nothing -- state "noLocations",
-- candidateLocations 0, with the map still showing mapFile "Tirisfal".
--
-- GetRealZoneText is DOCUMENTED on this client (Location category, "the zone's
-- real name") but has no runtime record, so it is wrapped like every other
-- unproven symbol: absent or failing, it returns nil and Map/MapContext.lua
-- falls back to GetZoneText exactly as before.
--
-- AND IT DOES NOT ACTUALLY SOLVE THE SUBZONE PROBLEM HERE. Measured returning
-- the building name indoors (a failed approach under
-- minimap.zoom_cvars_absent_client_zooms_to_3_indoors) and confirmed again by
-- probe zoneindoor 2026-08-29, which walked into Echo Ridge Mine and got
-- "Echo Ridge Mine" from this and from GetZoneText alike. It is still preferred
-- over GetZoneText because it is no worse and is right by definition wherever
-- it behaves, but no consumer may treat it as subzone-proof. The map layer
-- resolves the area from the viewed map's own zone name instead, and
-- MapContext:GetStandingZone -- which must work with the map closed -- tests
-- the name against the client's own zone list before trusting it.
function Client.GetRealZoneText()
    local ok, value = Call0("GetRealZoneText")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Is the player inside a dungeon, raid or PvP instance?
--
-- The one client-side answer to a question the zone name cannot settle on its
-- own. Inside an instance both zone calls are promoted to the instance's own
-- name -- exactly the shape probe zoneindoor measured for a mine -- and that
-- name is not in GetMapZones for the continent, so every "is this a real zone"
-- test in Map/MapContext.lua correctly says no and the standing zone falls
-- through to the last remembered outdoor one. That is right for a mine and
-- wrong for a dungeon: the player really has left the outdoor zone behind.
--
-- Returns true, false, or nil when the client has no such global. nil is not
-- false: a caller must not conclude "outdoors" from it, and Map/MapContext.lua
-- has a static fallback for exactly that case.
--
-- The client's API reference documents a plain boolean return and no instance
-- type, so nothing here may branch on dungeon versus raid versus battleground.
function Client.IsInInstance()
    local ok, value = Call0("IsInInstance")
    if not ok then
        return nil
    end
    if value == nil then
        return nil
    end
    -- Documented as a Lua boolean, but this client returns 1/nil from several
    -- of its other predicates, so both shapes are accepted.
    if value == false or value == 0 then
        return false
    end
    return true
end

-- The subzone name on its own. NOT a way to tell that the player is indoors,
-- and no module uses it for that: probe zoneindoor measured it going EMPTY the
-- moment the player stepped into Echo Ridge Mine, while both zone calls were
-- promoted to the mine's own name. Outdoors it named the mine; inside it named
-- nothing. Kept as a plain wrapper for a caller that wants the subzone label
-- itself.
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

-- Whether the game UI is currently hidden, which on this client is what the
-- fullscreen world map does. This is not a probe result and is not treated as
-- one: it is the same observation Core/Driver.lua's parent choice already
-- rests on -- the driver was moved off UIParent because the fullscreen map
-- hides it and stopped every periodic job. Used only to bucket a frame-time
-- census, never to decide what to draw, so a client that hid UIParent for some
-- other reason would blur a diagnostic and nothing else.
function Client.IsGameUIHidden()
    local parent = ResolveObject("UIParent")
    if not parent or type(parent.IsVisible) ~= "function" then
        return nil
    end
    local ok, visible = pcall(parent.IsVisible, parent)
    if not ok then
        return nil
    end
    return not visible
end

function Client.CreateWorldMapPin(index, red, green, blue)
    local canvas = Client.GetWorldMapCanvas()
    local create = Resolve("CreateFrame")
    if not canvas or not create
        or (type(index) ~= "number" and type(index) ~= "string") then
        return nil
    end
    local name = "UnrealQuestWorldMapPin" .. tostring(index)
    local ok, frame = pcall(create, "Button", name, canvas)
    if not ok or not frame then
        return nil
    end
    if type(frame.SetWidth) == "function" then pcall(frame.SetWidth, frame, 14) end
    if type(frame.SetHeight) == "function" then pcall(frame.SetHeight, frame, 14) end
    local pinLevel = 120
    if type(canvas.GetFrameLevel) == "function" and type(frame.SetFrameLevel) == "function" then
        local levelOk, level = pcall(canvas.GetFrameLevel, canvas)
        if levelOk and type(level) == "number" then
            pinLevel = level + 20
            if pinLevel < 120 then pinLevel = 120 end
            pcall(frame.SetFrameLevel, frame, pinLevel)
        else
            pcall(frame.SetFrameLevel, frame, 120)
        end
    end
    -- Pooled objective frames switch between tiles and dots. Keeping their
    -- constructor level lets that presentation change place a dot above its
    -- separate border, then restore a tile exactly instead of accumulating
    -- relative RaiseWorldMapPin calls on every switch.
    frame.unrealQuestBaseFrameLevel = pinLevel
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
function Client.CreateWorldMapArea(index, red, green, blue, alpha, poolName)
    if type(index) ~= "number" then
        return nil
    end
    local frameKey = index + 500
    if type(poolName) == "string" and poolName ~= "" then
        -- A named pool has no numeric band to run into. This lets objective
        -- frames grow to the complete active scene without ever colliding
        -- with giver, turn-in, patrol or service frames.
        frameKey = poolName .. tostring(index)
    end
    local frame = Client.CreateWorldMapPin(frameKey, red, green, blue)
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
        frame.unrealQuestPixelWidth = nil
        frame.unrealQuestPixelHeight = nil
        return false
    end
    -- The size actually on the frame, recorded so the batched stable-tick
    -- sweep below can tell an unchanged tile from one that has to be resized.
    -- Every path that sizes a pooled marker maintains this, so it never
    -- describes geometry the frame does not have.
    frame.unrealQuestPixelWidth = pixelWidth
    frame.unrealQuestPixelHeight = pixelHeight
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

-- Patrol strokes: the continuous-line presentation of a patrol route.
--
-- This client offers no line primitive. There is no CreateLine and no
-- SetVertexOffset -- both are later-expansion widgets -- and while the
-- documentation does describe the eight-argument rotated-quad form of
-- SetTexCoord, its first live visual use distorted the texture rather than
-- rotating it rigidly. Nothing in this addon uses it now; the navigator moved
-- to a pre-rotated atlas and map segments remain stamped.
--
-- What IS measured is the marker surface itself: a texture bound to
-- Interface\Buttons\WHITE8X8 and tinted with SetVertexColor, which is what
-- every pooled map marker already draws. A line is therefore built the only
-- way this client allows without a new assumption -- opaque square stamps
-- overlapping along the path, dense enough that consecutive stamps merge into
-- one stroke. Opaque stamps are deliberate: overlapping SEMI-transparent
-- stamps would accumulate alpha at every overlap and read as beads.
--
-- The stamps are plain Textures on one shared layer frame rather than pooled
-- Buttons, because a solid line needs several times the objects a spaced path
-- does, and a Texture carries no mouse, no scripts and no frame level. That
-- last point is also why hit testing is not here: a Texture cannot take the
-- mouse, so the route's hover lives on a separate pool of invisible Buttons
-- laid along the same path (Map/WorldMapPins.lua).
local WORLD_MAP_STROKE_LAYER_NAME = "UnrealQuestPatrolStrokeLayer"
local worldMapStrokeLayer = nil

-- Created on first use, never per stroke: the layer exists only once the line
-- presentation actually draws something.
function Client.GetWorldMapStrokeLayer()
    if worldMapStrokeLayer then
        return worldMapStrokeLayer
    end
    local canvas = Client.GetWorldMapCanvas()
    local create = Resolve("CreateFrame")
    if not canvas or not create then
        return nil
    end
    local ok, layer = pcall(create, "Frame", WORLD_MAP_STROKE_LAYER_NAME, canvas)
    if not ok or not layer then
        return nil
    end
    if type(layer.SetAllPoints) == "function" then
        pcall(layer.SetAllPoints, layer, canvas)
    end
    -- Below the pooled markers, which all land on max(canvasLevel + 20, 120):
    -- the route is context for the "!" and "?", never something drawn over
    -- them. EnableMouse(false) keeps the layer out of the hit test altogether,
    -- so the dash Buttons above it still answer every hover.
    if type(canvas.GetFrameLevel) == "function" and type(layer.SetFrameLevel) == "function" then
        local levelOk, level = pcall(canvas.GetFrameLevel, canvas)
        if levelOk and type(level) == "number" then
            pcall(layer.SetFrameLevel, layer, level + 1)
        end
    end
    if type(layer.EnableMouse) == "function" then
        pcall(layer.EnableMouse, layer, false)
    end
    if type(layer.Show) == "function" then
        pcall(layer.Show, layer)
    end
    worldMapStrokeLayer = layer
    return layer
end

function Client.CreateWorldMapStroke()
    local layer = Client.GetWorldMapStrokeLayer()
    if not layer or type(layer.CreateTexture) ~= "function" then
        return nil
    end
    local ok, texture = pcall(layer.CreateTexture, layer, nil, "ARTWORK")
    if not ok or not texture then
        return nil
    end
    if type(texture.SetTexture) == "function" then
        pcall(texture.SetTexture, texture, WORLD_MAP_PIN_TEXTURE)
    end
    return texture
end

function Client.SetWorldMapStrokeColor(texture, red, green, blue, alpha)
    if not texture then
        return false
    end
    local colored = false
    if type(texture.SetVertexColor) == "function" then
        colored = pcall(texture.SetVertexColor, texture, red or 1, green or 1, blue or 1)
    end
    if type(texture.SetAlpha) == "function" then
        pcall(texture.SetAlpha, texture, alpha or 1)
    end
    return colored and true or false
end

function Client.SetWorldMapStrokeSize(texture, size)
    if not texture or type(size) ~= "number" or size <= 0 then
        return false
    end
    local widthOk = type(texture.SetWidth) == "function" and pcall(texture.SetWidth, texture, size)
    local heightOk = type(texture.SetHeight) == "function" and pcall(texture.SetHeight, texture, size)
    return (widthOk and heightOk) and true or false
end

-- Same fraction-of-canvas placement as Client.PositionWorldMapPin, taken
-- against the stroke layer that covers it. Nothing is written onto the texture
-- itself: a Texture is not the field-carrying Button the pin pools use, so the
-- caller keeps its stroke bookkeeping in its own tables.
function Client.PositionWorldMapStroke(texture, x, y, size)
    local layer = Client.GetWorldMapStrokeLayer()
    if not texture or not layer or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    local width, height = Client.GetWorldMapCanvasSize()
    if not width or not height then
        return false
    end
    if not Client.SetWorldMapStrokeSize(texture, size) then
        return false
    end
    if type(texture.ClearAllPoints) ~= "function" or type(texture.SetPoint) ~= "function"
        or type(texture.Show) ~= "function" then
        return false
    end
    pcall(texture.ClearAllPoints, texture)
    local pointOk = pcall(texture.SetPoint, texture,
        "CENTER", layer, "TOPLEFT", x * width, -y * height)
    if not pointOk then
        return false
    end
    return pcall(texture.Show, texture) and true or false
end

-- The stroke equivalent of Client.ReapplyWorldMapPin, and deliberately much
-- cheaper: the stamps are anchored to the layer, not to the canvas, so one
-- re-anchored and re-shown layer carries every one of them back through the
-- map's draw path. Only a canvas that changed SIZE invalidates the stamps'
-- own offsets, and the caller repositions them itself in that case.
function Client.ReapplyWorldMapStrokeLayer()
    local canvas = Client.GetWorldMapCanvas()
    if not worldMapStrokeLayer or not canvas then
        return false
    end
    if type(worldMapStrokeLayer.SetAllPoints) == "function" then
        pcall(worldMapStrokeLayer.SetAllPoints, worldMapStrokeLayer, canvas)
    end
    if type(worldMapStrokeLayer.Show) == "function" then
        pcall(worldMapStrokeLayer.Show, worldMapStrokeLayer)
    end
    return true
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

local function PixelAlignedOffset(value)
    if value < 0 then
        return -math.floor(-value + 0.5)
    end
    return math.floor(value + 0.5)
end

function Client.SetWorldMapPinPixelAligned(frame, enabled)
    if not frame then
        return false
    end
    frame.unrealQuestPixelAligned = enabled and true or nil
    return true
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
    local offsetX = x * width
    local offsetY = -y * height
    if frame.unrealQuestPixelAligned then
        offsetX = PixelAlignedOffset(offsetX)
        offsetY = PixelAlignedOffset(offsetY)
    end
    pcall(frame.ClearAllPoints, frame)
    local pointOk = pcall(frame.SetPoint, frame, "CENTER", canvas, "TOPLEFT", offsetX, offsetY)
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

-- Batched form of Client.ReapplyWorldMapPin for the stable-tick sweep over a
-- whole pool. The placement contract is identical -- same confirmed point,
-- same suppression rule, same Show -- and only the bookkeeping around it
-- changes: the canvas and its pixel size are resolved once for the whole run
-- instead of once per marker (twice, for a sized area tile, because
-- Client.PositionWorldMapArea resolves the canvas and then calls
-- Client.PositionWorldMapPin, which resolves it again), and each marker costs
-- one pcall rather than the eight the single-frame path takes.
--
-- That difference is only visible at scale, which is exactly where it was
-- needed: with the objective-dot presentation drawing up to MAX_AREA_TILES
-- markers, the per-marker path re-entered getglobal and the canvas measurement
-- a thousand times every refresh interval.
local function ReapplyOneWorldMapPin(frame, canvas, width, height)
    local x = frame.unrealQuestMapX
    local y = frame.unrealQuestMapY
    if type(x) ~= "number" or type(y) ~= "number" then
        return
    end
    local widthPercent = frame.unrealQuestAreaWidthPercent
    local heightPercent = frame.unrealQuestAreaHeightPercent
    if type(widthPercent) == "number" and type(heightPercent) == "number" then
        local pixelWidth = width * widthPercent / 100
        local pixelHeight = height * heightPercent / 100
        if pixelWidth < 14 then pixelWidth = 14 end
        if pixelHeight < 14 then pixelHeight = 14 end
        -- Re-issuing an identical SetWidth/SetHeight still dirties the frame's
        -- layout, so the size is written only when it changed. The canvas is a
        -- fixed-size child of WorldMapPositioningGuide, so in practice this
        -- skips every tile on every stable tick.
        if frame.unrealQuestPixelWidth ~= pixelWidth
            or frame.unrealQuestPixelHeight ~= pixelHeight then
            frame:SetWidth(pixelWidth)
            frame:SetHeight(pixelHeight)
            frame.unrealQuestPixelWidth = pixelWidth
            frame.unrealQuestPixelHeight = pixelHeight
        end
    end
    local offsetX = x * width
    local offsetY = -y * height
    if frame.unrealQuestPixelAligned then
        offsetX = PixelAlignedOffset(offsetX)
        offsetY = PixelAlignedOffset(offsetY)
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", canvas, "TOPLEFT", offsetX, offsetY)
    -- Same rule as Client.PositionWorldMapPin: a suppressed marker still takes
    -- its point, only the Show is withheld.
    if frame.unrealQuestSuppressed then
        frame:Hide()
    else
        frame:Show()
    end
end

-- Returns how many of the first `count` slots were re-applied without error.
-- Methods are not type-checked per frame the way the single-frame path checks
-- them: every pooled marker came from Client.CreateWorldMapPin, and the one
-- pcall per frame still contains any failure to that frame alone.
function Client.ReapplyWorldMapPins(pool, count)
    if type(pool) ~= "table" or type(count) ~= "number" or count <= 0 then
        return 0
    end
    local canvas = Client.GetWorldMapCanvas()
    if not canvas then
        return 0
    end
    local widthOk, width = pcall(canvas.GetWidth, canvas)
    local heightOk, height = pcall(canvas.GetHeight, canvas)
    if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return 0
    end
    local applied = 0
    local index = 1
    while index <= count do
        local frame = pool[index]
        if frame and pcall(ReapplyOneWorldMapPin, frame, canvas, width, height) then
            applied = applied + 1
        end
        index = index + 1
    end
    return applied
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

function Client.SetWorldMapPinHandlers(frame, onEnter, onLeave, onClick, allowRightClick)
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
    -- assumption. Only done when a handler is supplied, so hover-only patrol
    -- targets keep taking no click tokens.
    if onClick and type(frame.RegisterForClicks) == "function" then
        if allowRightClick then
            pcall(frame.RegisterForClicks, frame, "LeftButtonUp", "RightButtonUp")
        else
            pcall(frame.RegisterForClicks, frame, "LeftButtonUp")
        end
    end
    pcall(frame.SetScript, frame, "OnEnter", onEnter)
    pcall(frame.SetScript, frame, "OnLeave", onLeave)
    pcall(frame.SetScript, frame, "OnClick", onClick)
    return true
end

-- Decorative borders and followed-quest rings are visual siblings of the
-- interactive pin they surround. Keeping their mouse disabled lets the
-- objective dot or turn-in marker continue to own hover and click.
function Client.SetWorldMapPinMouseEnabled(frame, enabled)
    if not frame or type(frame.EnableMouse) ~= "function" then
        return false
    end
    local ok = pcall(frame.EnableMouse, frame, enabled and true or false)
    return ok and true or false
end

-- Sets a pin's layer relative to the level chosen by CreateWorldMapPin. This
-- is idempotent for pooled frames that change presentation; RaiseWorldMapPin
-- remains the additive helper for transient effects such as map flashing.
function Client.SetWorldMapPinLevelBoost(frame, extraLevels)
    if not frame or type(frame.SetFrameLevel) ~= "function" then
        return false
    end
    local level = frame.unrealQuestBaseFrameLevel
    if type(level) ~= "number" then
        return false
    end
    -- Remembered, not only applied: a minimap pin can be re-levelled later
    -- when the player arrow lever changes, and a rim that forgot its -1 would
    -- come back sitting on top of the dot it exists to frame.
    frame.unrealQuestLevelBoost = extraLevels or 0
    local ok = pcall(frame.SetFrameLevel, frame, level + (extraLevels or 0))
    return ok and true or false
end

-- Lifts one pooled map child above its siblings in the hit-test order.
--
-- Every pooled child -- quest markers, area tiles and giver "!" pins alike --
-- is created by the one constructor above, and the pool index only shapes the
-- frame NAME, never the level. So they all land on exactly the same
-- max(canvasLevel + 20, 120), which the live SavedVariables confirms as 120
-- for all of them. Two mouse-enabled siblings at the SAME frame level leave
-- which one receives a click to draw order rather than to intent, and the
-- area tile takes the mouse for its quest hover/follow gesture. A giver on the
-- same coordinate must still sit above it or a shift-click meant for the "!"
-- would instead follow the tile's active quest.
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
local function RenderTooltipLines(tooltip, tooltipName, frame, lines, anchor,
                                  useNativeStyle)
    -- Nothing to say is not a tooltip. Showing one anyway draws the flat
    -- style's fill and outline around zero lines: a thin dark bar beside the
    -- hovered pin. Returning before SetOwner leaves the tooltip untouched.
    if table.getn(lines or {}) == 0 then
        return false
    end
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
    if not useNativeStyle then
        Client.ApplyFlatTooltipStyle(tooltip, tooltipName)
    end

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
-- Which frame this addon last painted GameTooltip for, or nil when the
-- tooltip is the client's own again. Tooltip/EntityTooltip.lua reads it
-- through Client.IsGameTooltipAddonOwned: the addon's GameTooltip surfaces
-- (a minimap quest pin, a tracker row) already print the quest's objectives
-- from the log, and the entity tooltip's matched progress row on top of them
-- is the same objective printed twice.
local gameTooltipOwner = nil

-- True while GameTooltip still belongs to the frame this addon painted it
-- for. IsOwned is consulted rather than trusted bookkeeping alone, because a
-- unit hover can re-own the tooltip without any Hide call of ours running --
-- the same reason the Hide paths below check it before hiding.
function Client.IsGameTooltipAddonOwned()
    if not gameTooltipOwner then
        return false
    end
    local tooltip = ResolveGameTooltip()
    if not tooltip then
        gameTooltipOwner = nil
        return false
    end
    if type(tooltip.IsOwned) == "function" then
        local ok, owned = pcall(tooltip.IsOwned, tooltip, gameTooltipOwner)
        if ok and not owned then
            gameTooltipOwner = nil
            return false
        end
    end
    if type(tooltip.IsShown) == "function" then
        local ok, shown = pcall(tooltip.IsShown, tooltip)
        if ok and not shown then
            gameTooltipOwner = nil
            return false
        end
    end
    return true
end

function Client.ShowGameTooltip(frame, lines, anchor)
    local tooltip = ResolveGameTooltip()
    if not tooltip or not frame then
        return false
    end
    local shown = RenderTooltipLines(tooltip, "GameTooltip", frame, lines, anchor)
    if shown then
        gameTooltipOwner = frame
    end
    return shown
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
    gameTooltipOwner = nil
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
        UQ.L("MAP_GIVER_MENU_MARK_ALL"), 0.8, 0.8, 0.8, Select({ all = true }))

    LayOutGiverMenuRow(menu, GetGiverMenuRow(total + 2), total + 2,
        UQ.L("COMMON_CLOSE"), 0.5, 0.5, 0.5, function() Client.HideGiverQuestMenu() end)

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
-- The available-quest "!" uses the bundled quest icon. It is an addon asset,
-- not a client API dependency, so it carries no capability/evidence requirement.
--
-- The turn-in "?" pins use bundled active and complete assets instead of the
-- client's own Interface\GossipFrame\ActiveQuestIcon. These are not client API
-- dependencies, so they carry no capability/evidence requirement.
Client.WORLD_MAP_PIN_TEXTURE = WORLD_MAP_PIN_TEXTURE
Client.AVAILABLE_QUEST_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\icons\\questIcon"
Client.LOW_LEVEL_QUEST_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\icons\\QuestIcon-lowlvl"
Client.ACTIVE_QUEST_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\ActiveQuestIcon"
Client.COMPLETE_QUEST_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\CompleteQuestIcon"
Client.MINIMAP_OBJECTIVE_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\QuestDot"
Client.FOLLOWED_QUEST_DOT_BORDER_TEXTURE =
    "Interface\\AddOns\\unrealQuest\\media\\FollowedQuestDotBorder"
Client.FOLLOWED_QUEST_CIRCLE_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\quest-circle"

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

-- Applies no Lua-side opacity or colour multiplication to an image-backed
-- pin. The texture's embedded alpha remains the only source of transparency.
-- Keep the four-component SetVertexColor call: the current client accepts it,
-- and the explicit alpha component prevents a stale pooled tint from dimming
-- the image when the frame is reused.
function Client.SetWorldMapPinFullOpacity(frame)
    local texture = frame and frame.unrealQuestTexture
    if not frame or not texture then
        return false
    end
    if type(frame.SetAlpha) ~= "function" or type(texture.SetAlpha) ~= "function"
        or type(texture.SetVertexColor) ~= "function" then
        return false
    end
    local frameOk = pcall(frame.SetAlpha, frame, 1)
    local textureOk = pcall(texture.SetAlpha, texture, 1)
    local colorOk = pcall(texture.SetVertexColor, texture, 1, 1, 1, 1)
    if frameOk then
        frame.unrealQuestAlpha = 1
    else
        frame.unrealQuestAlpha = nil
    end
    return frameOk and textureOk and colorOk and true or false
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
    if not widthOk or not heightOk then
        frame.unrealQuestPixelWidth = nil
        frame.unrealQuestPixelHeight = nil
        return false
    end
    frame.unrealQuestPixelWidth = width
    frame.unrealQuestPixelHeight = height
    return true
end

-- SetAlpha is a stock Frame method already relied on elsewhere in this file
-- (Client.SetWaypointAlpha), so this carries no new evidence requirement.
function Client.SetWorldMapPinAlpha(frame, alpha)
    if not frame or type(alpha) ~= "number" or type(frame.SetAlpha) ~= "function" then
        return false
    end
    -- Skipped when the frame already carries this alpha. A pooled marker is
    -- created at full opacity and nothing outside this wrapper writes its
    -- frame alpha, so the absent record means 1. The focus pass over a
    -- thousand-plus objective frames re-states most of them unchanged on every
    -- hover, and this is what keeps that walk free of client calls.
    local current = frame.unrealQuestAlpha
    if current == nil then
        current = 1
    end
    if current == alpha then
        return true
    end
    local ok = pcall(frame.SetAlpha, frame, alpha)
    if not ok then
        frame.unrealQuestAlpha = nil
        return false
    end
    frame.unrealQuestAlpha = alpha
    return true
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

-- Indoors or outdoors, which the minimap scale depends on --------------------
--
-- The minimap covers ~64% as many yards indoors as it does outside at the same
-- zoom step, so a layer that assumes the outdoor row places every pin at about
-- two thirds of its true distance while the player is in a building: the pins
-- huddle around the centre and barely move, which reads as them following the
-- player instead of staying on the ground.
--
-- IsIndoors and IsOutdoors are both absent here, which is why this was written
-- off as undetectable. It is not. The client keeps the player's zoom in one of
-- two CVars depending on where they are, so:
--
-- * when minimapZoom and minimapInsideZoom hold DIFFERENT values, whichever
--   one equals the live zoom names the current environment, and nothing has to
--   be written at all;
-- * when they hold the same value, that comparison cannot separate them, so
--   the zoom is nudged one step and minimapInsideZoom re-read: the client only
--   moves it if the player is inside. The zoom is restored immediately, before
--   this returns, on every path including failure.
--
-- The nudge is the technique the installed pfQuest uses on this client
-- (map.lua, minimap_indoor), which is what makes it prior art here rather than
-- a guess. It is still a WRITE to the player's minimap, so the answer is
-- cached for MINIMAP_INDOOR_TTL: the minimap layer refreshes ten times a
-- second and must not zoom the player's minimap ten times a second. Walking
-- through a door therefore takes up to one interval to register.
local MINIMAP_INDOOR_TTL = 1
local minimapIndoorState = nil
local minimapIndoorHow = nil
local minimapIndoorAt = nil
-- Set once the zoom probe has shown that this client does not move either zoom
-- CVar when the zoom changes. From then on the probe is never run again: it
-- would write the player's minimap zoom once a second to learn nothing.
local minimapZoomCVarsDead = false

local function ReadZoomCVar(name)
    local get = Resolve("GetCVar")
    if not get then
        return nil
    end
    local ok, value = pcall(get, name)
    if not ok then
        return nil
    end
    return tonumber(value)
end

local function ResolveMinimapIndoorState()
    local map = Client.GetMinimap()
    local outside = ReadZoomCVar("minimapZoom")
    local inside = ReadZoomCVar("minimapInsideZoom")
    if not map or not outside or not inside then
        return nil, "cvarUnavailable"
    end
    local zoomOk, zoom = pcall(map.GetZoom, map)
    if not zoomOk or type(zoom) ~= "number" then
        return nil, "noZoom"
    end
    if outside ~= inside then
        if zoom == inside then
            return "indoor", "cvarDistinct"
        end
        if zoom == outside then
            return "outdoor", "cvarDistinct"
        end
        return nil, "zoomMatchesNeitherCVar"
    end
    if minimapZoomCVarsDead or type(map.SetZoom) ~= "function" then
        return nil, "cvarsNotMaintained"
    end
    -- Away from whichever end of the range the zoom is at, so the nudge stays
    -- inside the client's own 0..5 steps.
    local step = 1
    if inside >= 3 then
        step = -1
    end
    if not pcall(map.SetZoom, map, zoom + step) then
        return nil, "zoomWriteFailed"
    end
    local probedInside = ReadZoomCVar("minimapInsideZoom")
    local probedOutside = ReadZoomCVar("minimapZoom")
    pcall(map.SetZoom, map, zoom)
    -- Which CVar the client moved is the whole answer, and BOTH have to be
    -- checked. Reading only the inside one cannot tell "the player is outside"
    -- from "this client does not maintain these CVars at all" -- and this
    -- client answers "0" for a CVar it does not know, so a dead pair reads as
    -- a real, equal pair and every probe would confidently report "outdoor".
    -- That is exactly what it did report, from inside a building.
    if probedInside ~= inside then
        return "indoor", "zoomProbe"
    end
    if probedOutside ~= outside then
        return "outdoor", "zoomProbe"
    end
    minimapZoomCVarsDead = true
    return nil, "cvarsNotMaintained"
end

-- Returns "indoor", "outdoor", or nil when neither can be established, plus
-- how it was reached. A nil answer means the caller keeps its outdoor
-- assumption: that is what this layer did before indoors could be detected at
-- all, so an unreadable client is never worse off than it was.
function Client.GetMinimapIndoorState()
    local now = Client.Now()
    if minimapIndoorAt and now and now - minimapIndoorAt < MINIMAP_INDOOR_TTL then
        if minimapIndoorState == false then
            return nil, minimapIndoorHow
        end
        return minimapIndoorState, minimapIndoorHow
    end
    local state, how = ResolveMinimapIndoorState()
    -- Cached as false rather than nil so an unresolved answer is not retried
    -- on every refresh: the retry would carry the zoom write with it.
    minimapIndoorState = state or false
    minimapIndoorHow = how
    minimapIndoorAt = now
    return state, how
end

-- The two zoom CVars exactly as the client returns them, for diagnostics. A
-- client that does not know a CVar answers "0" here, so a pair that reads
-- "0"/"0" forever alongside indoorHow = "cvarsNotMaintained" is the signature
-- of a client that keeps no inside/outside zoom at all.
function Client.GetMinimapZoomCVars()
    local get = Resolve("GetCVar")
    if not get then
        return nil, nil
    end
    local outOk, outside = pcall(get, "minimapZoom")
    local inOk, inside = pcall(get, "minimapInsideZoom")
    return outOk and outside or nil, inOk and inside or nil
end

-- The player arrow at the centre of the minimap ---------------------------
-- The arrow is drawn where the pins are, and by default every pin drew over
-- it: minimap pins are created in the measured level-120 band and the arrow is
-- far below that, so a dot standing on the player buried the one mark the
-- player steers by. Two levers exist, and this layer tries them in that order.
--
-- 1. RAISE THE ARROW. This is what the installed pfQuest does on Vanilla
--    (compat/client.lua: it finds the arrow among Minimap's children and calls
--    SetFrameLevel(8), commented "always keep player arrow on top"). It is the
--    right fix wherever it works, because it leaves every pin exactly where it
--    was. It needs a handle on the arrow, and on the PRECEDING build of this
--    client there was none: probe 1.37.0 walked Minimap:GetChildren() and
--    found 7 children, none of them a Model (input.no_readable_player_facing).
--    The search is still made rather than skipped -- the client has been
--    updated since, Minimap:SetPlayerModel is documented, and a handle that
--    has appeared costs one scan to find.
--
-- 2. LOWER THE PINS. The fallback when there is no arrow to raise. The pins
--    drop out of the 120 band to just above Minimap's own frame level, which
--    is the band Minimap's own children occupy (measured at 3-4), so they are
--    still drawn over the minimap terrain -- everything native at 3-4 plainly
--    is -- while an arrow drawn above that band comes out on top.
--
-- Lever 2 is a HYPOTHESIS about where the engine draws the arrow, not a
-- measurement: nothing on this client reports the arrow's own level, and no
-- probe can read it. So it is a setting the player can turn off
-- (minimapPinsBelowArrow), and `/uq minimap` reports which lever is in use and
-- the level the pins ended up at, so one look at the minimap settles it.
--
-- Nothing here ever hides a pin. A dot that shares the player's position stays
-- drawn, at full size and full alpha; only the order it is drawn in changes.
--
-- One table rather than the eight file-scope locals this would naturally be:
-- ClientAPI.lua is within a handful of locals of Lua's 200-per-chunk ceiling,
-- and the two helpers live on it for the same reason.
local minimapArrow = {
    -- The measured band, and where a found arrow is raised to: above the pins
    -- rather than merely above the native children, which is the one thing
    -- pfQuest's 8 cannot do here, since this addon's pins sit at 120.
    PIN_LEVEL = 120,
    RAISED_LEVEL = 125,
    -- Every minimap pin created so far, so a change of lever re-levels the
    -- pins already in the pools instead of reaching only later ones.
    pins = {},
    count = 0,
    below = false,
    frame = nil,
    searched = false,
    raised = false,
}

-- pfQuest's detection, with this addon's guards: any child of Minimap that is
-- an unnamed Model whose model path names the minimap arrow. Everything is
-- pcall'd, because a client without Model:GetModel would otherwise take the
-- whole layer down while looking for a frame it does not have. Searched once
-- per session -- the arrow is engine-owned and does not come and go.
-- `rescan` searches again instead of answering from the cache, for the one
-- case the cache is wrong about: another addon replacing or re-parenting the
-- minimap after this ran. `/uq minimap rescan` is that caller.
function Client.FindMinimapPlayerArrow(rescan)
    if minimapArrow.searched and not rescan then
        return minimapArrow.frame
    end
    minimapArrow.searched = true
    minimapArrow.frame = nil
    local map = Client.GetMinimap()
    if not map or type(map.GetChildren) ~= "function" then
        return nil
    end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l = pcall(map.GetChildren, map)
    if not ok then
        return nil
    end
    local children = { a, b, c, d, e, f, g, h, i, j, k, l }
    local index = 1
    while index <= 12 do
        local child = children[index]
        if child and type(child.IsObjectType) == "function"
            and type(child.GetModel) == "function" then
            local typeOk, isModel = pcall(child.IsObjectType, child, "Model")
            local named = nil
            if typeOk and isModel and type(child.GetName) == "function" then
                local nameOk, name = pcall(child.GetName, child)
                if nameOk then named = name end
            end
            if typeOk and isModel and not named then
                local modelOk, model = pcall(child.GetModel, child)
                if modelOk and type(model) == "string"
                    and string.find(string.lower(model), "minimaparrow", 1, true) then
                    minimapArrow.frame = child
                    return minimapArrow.frame
                end
            end
        end
        index = index + 1
    end
    return nil
end

-- The level a minimap pin is created at, and the level every existing pin is
-- moved to when the lever changes.
function minimapArrow.Level()
    local map = Client.GetMinimap()
    local base = nil
    if map and type(map.GetFrameLevel) == "function" then
        local ok, level = pcall(map.GetFrameLevel, map)
        if ok and type(level) == "number" then
            base = level
        end
    end
    if minimapArrow.below and not minimapArrow.raised then
        -- Just above the minimap itself, so the terrain cannot swallow the
        -- pins, and inside the band its own children already draw in.
        if base then
            return base + 1
        end
        return 2
    end
    local level = minimapArrow.PIN_LEVEL
    if base and base + 20 > level then
        level = base + 20
    end
    return level
end

-- Applies the current lever to one pin: the base level it was created at is
-- rewritten, and whatever level boost the caller had asked for is reapplied on
-- top of the new base rather than lost.
function minimapArrow.Apply(frame)
    if not frame or type(frame.SetFrameLevel) ~= "function" then
        return false
    end
    local level = minimapArrow.Level()
    frame.unrealQuestBaseFrameLevel = level
    local boost = frame.unrealQuestLevelBoost
    if type(boost) ~= "number" then
        boost = 0
    end
    return pcall(frame.SetFrameLevel, frame, level + boost) and true or false
end

-- Chooses the lever and applies it. Called by the minimap layer on every
-- refresh, so turning the setting off in game restores the measured 120 band
-- immediately instead of at the next reload; it is a no-op once the state
-- matches.
--
-- Raising the arrow, where an arrow exists, wins over lowering the pins and is
-- kept even when the setting is turned back off: an arrow above the pins is
-- the outcome the setting asks for, and it costs the pins nothing.
function Client.SetMinimapPinsBelowPlayerArrow(enabled)
    enabled = enabled and true or false
    if enabled and not minimapArrow.raised then
        local arrow = Client.FindMinimapPlayerArrow()
        if arrow and type(arrow.SetFrameLevel) == "function" then
            if pcall(arrow.SetFrameLevel, arrow, minimapArrow.RAISED_LEVEL) then
                minimapArrow.raised = true
            end
        end
    end
    if enabled == minimapArrow.below then
        return false
    end
    minimapArrow.below = enabled
    local index = 1
    while index <= minimapArrow.count do
        minimapArrow.Apply(minimapArrow.pins[index])
        index = index + 1
    end
    return true
end

-- What /uq minimap prints: which lever carried the arrow, and the level the
-- pins actually ended up at, so an arrow still buried can be told from a
-- setting that was never applied.
function Client.GetMinimapPlayerArrowState()
    return {
        below = minimapArrow.below,
        arrowFound = Client.FindMinimapPlayerArrow() ~= nil,
        arrowRaised = minimapArrow.raised,
        pinLevel = minimapArrow.Level(),
        pooledPins = minimapArrow.count,
    }
end

-- Same construction as Client.CreateWorldMapPin, against Minimap instead of
-- WorldMapButton. The pin starts mouse-disabled; a layer that gives it a
-- tooltip opts in through SetMinimapPinHandlers. The installed pfQuest uses
-- the same EnableMouse + OnEnter/OnLeave shape on its minimap nodes, while
-- wheel input on this client is handled by the binding layer rather than an
-- addon frame's mouse-wheel script.
--
-- The pin is a Button rather than a plain Frame for one reason: OnClick is a
-- Button script, and worldMapPinInteraction is verified for exactly this
-- construction -- a small addon-owned Button parented to a map canvas gets
-- both the mouse and OnClick. Nothing else changes by asking for a Button
-- here: it is a Frame subtype, no template is applied, so it carries no art
-- of its own and the measured minimap child contract
-- (minimap.addon_children_render_unclipped) is about where a child of Minimap
-- draws, not about which widget type asked to draw there. The Frame fallback
-- keeps the layer alive on a client that refuses the Button; pins created that
-- way take clicks through OnMouseUp instead (see SetMinimapPinHandlers).
function Client.CreateMinimapPin(index, size, red, green, blue)
    local map = Client.GetMinimap()
    local create = Resolve("CreateFrame")
    if not map or not create
        or (type(index) ~= "number" and type(index) ~= "string") then
        return nil
    end
    local name = "UnrealQuestMinimapPin" .. tostring(index)
    local ok, frame = pcall(create, "Button", name, map)
    if not ok or not frame then
        ok, frame = pcall(create, "Frame", name, map)
    end
    if not ok or not frame then
        return nil
    end
    if type(size) ~= "number" or size <= 0 then
        size = 14
    end
    if type(frame.SetWidth) == "function" then pcall(frame.SetWidth, frame, size) end
    if type(frame.SetHeight) == "function" then pcall(frame.SetHeight, frame, size) end
    if type(frame.EnableMouse) == "function" then pcall(frame.EnableMouse, frame, false) end
    if type(frame.SetFrameLevel) == "function" then
        -- The level is the player-arrow lever's to decide (see
        -- Client.SetMinimapPinsBelowPlayerArrow): the measured 120 band by
        -- default, or just above Minimap's own level while the pins are being
        -- kept under the arrow. It is recorded on the frame for the same
        -- reason the world map records it -- a pooled pin that has to sit
        -- under a sibling, the followed quest's dot and the gold rim behind
        -- it, asks for an ABSOLUTE offset from this level rather than
        -- accumulating relative raises across reuses.
        minimapArrow.Apply(frame)
        minimapArrow.count = minimapArrow.count + 1
        minimapArrow.pins[minimapArrow.count] = frame
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
Client.SetMinimapPinMouseEnabled = Client.SetWorldMapPinMouseEnabled
Client.SetMinimapPinLevelBoost = Client.SetWorldMapPinLevelBoost

-- Hover and click on a minimap pin. Hover is the world-map contract unchanged
-- -- EnableMouse plus OnEnter/OnLeave, already confirmed in game by the pins'
-- own tooltips -- so only the click needs anything of its own.
--
-- Two routes, because CreateMinimapPin may have had to fall back to a plain
-- Frame, which has no OnClick and no RegisterForClicks:
--
--   * a Button pin registers LeftButtonUp and takes OnClick, the same shape
--     the world-map pins use, so both surfaces answer a click identically;
--   * a Frame pin takes OnMouseUp and filters the button itself, which is the
--     only click script a Frame has.
--
-- Exactly one of the two is installed, never both, so no pin can answer one
-- click twice. As on the world map, the click tokens are only taken when a
-- handler is actually supplied: a hover-only pin keeps its clicks unclaimed
-- and the minimap's own gesture underneath it is untouched.
function Client.SetMinimapPinHandlers(frame, onEnter, onLeave, onClick)
    if not frame or type(frame.SetScript) ~= "function" then
        return false
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    pcall(frame.SetScript, frame, "OnEnter", onEnter)
    pcall(frame.SetScript, frame, "OnLeave", onLeave)
    if onClick and type(frame.RegisterForClicks) == "function" then
        pcall(frame.RegisterForClicks, frame, "LeftButtonUp")
        pcall(frame.SetScript, frame, "OnClick", onClick)
        return true
    end
    if onClick then
        pcall(frame.SetScript, frame, "OnMouseUp", function(first)
            if Client.ResolveClickButton(first) == "LeftButton" then
                onClick()
            end
        end)
    end
    return true
end

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
-- widget method here: a client without IsMouseOver reports false.
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
-- DOCUMENTED on the updated client: GetPlayerFacing() returns the CHARACTER's
-- rotation in radians (client update notes 2026-08-28, recorded in
-- input.no_readable_player_facing as OFFICIAL_CLIENT_DOCUMENTATION). That is a
-- real facing, and it is what HUD/Waypoint.lua wanted all along, so it is now
-- the marker's primary direction source.
--
-- Two things it is NOT, and both matter to the caller:
--
--   * It is not runtime-verified. It is `documented`, not `verified`: no probe
--     has yet called it and recorded its zero axis, its rotation direction or
--     its wrap point. The zero axis and direction are ASSUMED here to be this
--     addon's own convention (0 = north, increasing towards west), which is
--     what the Vanilla API surface this client emulates uses. That assumption
--     is checked at runtime against the movement estimator rather than
--     trusted -- see HUD/PlayerHeading.lua's convention calibration.
--   * It is not the camera. The update adds no camera getter of any kind, so
--     free-look rotation is still invisible; see input.no_addon_camera_or_turn_control.
--
-- The measured absence below is the PRECEDING client build, kept because it is
-- what the movement fallback exists for and what a downgraded client would hit
-- again. On that build every candidate was absent, by any route:
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
-- unnecessary. Nothing was needed in its place: the one cheap resolve of
-- GetPlayerFacing that was kept "in case a future build ever adds one" is the
-- call that now carries the feature.
--
-- HUD/PlayerHeading.lua keeps the movement estimator as the fallback for a
-- build without the symbol, and as the yardstick the convention is checked
-- against. See docs/HUD-WAYPOINT.md.

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

-- Returns the client's RAW facing reading in radians, normalized into
-- [0, 2pi), plus the name of the source -- or nil on a build without the
-- symbol.
--
-- Raw, deliberately: this layer will not claim the reading is already in the
-- addon's angle convention when no probe has established its zero axis or its
-- rotation direction. Converting it is HUD/PlayerHeading.lua's job, because
-- that is where the movement bearing lives that the conversion is measured
-- against. A caller that wants a facing in the addon's convention calls
-- PlayerHeading:Get(), not this.
--
-- A reading wildly outside one turn is rejected rather than wrapped: a source
-- handing back degrees, or a sentinel, is not reporting radians, and a silent
-- wrap would turn that into a plausible-looking angle instead of a fallback to
-- the movement estimator.
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

-- How far the native quest log list is scrolled, in entries.
--
-- The list is a FauxScrollFrame: the row widgets never move, and the client
-- refills row N from quest log entry N + offset on every update. Nothing here
-- writes to the scroll frame, and the call is guarded like every other: a
-- client that answers nothing simply leaves the callers on their row IDs.
--
-- FauxScrollFrame_GetOffset is named in the unisolated startup-crash record
-- questlog.header_row_onclick_does_not_collapse, together with installing 27
-- addon-owned Buttons over the native rows -- which of the two faulted was
-- never established. It is read here on a frame this addon neither owns nor
-- modifies, once per refresh pass, exactly as unrealUI's own quest log
-- (WORKING_SOURCE, this client) and pfQuest both already read it in
-- production.
function Client.GetQuestLogScrollOffset()
    local scroll = ResolveObject("QuestLogListScrollFrame")
    local fn = Resolve("FauxScrollFrame_GetOffset")
    if not scroll or not fn then
        return nil
    end
    local ok, value = pcall(fn, scroll)
    if not ok or type(value) ~= "number" or value < 0 then
        return nil
    end
    return math.floor(value)
end

-- Trims the visible quest row count to what the list page actually holds.
--
-- Measured, never counted. This addon does not own the row anchors on every
-- host -- unrealUI's modern Quest Log chains its own 23 rows -- but it does
-- change the row height there (Client.SetModernQuestLogRowLayout), and a
-- taller row makes a row count that was fitted to the stock height overflow
-- the page. Rather than model somebody else's layout, each shown row is asked
-- where it actually ends: the first one ending below the list frame is the
-- first that must not be drawn, and everything from there down becomes what
-- the native FauxScrollFrame scrolls instead of covering the footer buttons.
--
-- Nothing is trimmed on a short list: the walk stops at the first hidden row,
-- so a log with fewer quests than rows never lowers QUESTS_DISPLAYED and can
-- still grow back to the full page. The trim is self-limiting for the same
-- reason -- once the overflowing rows are hidden, the next pass stops there
-- and finds nothing to do.
--
-- Numbers are inline rather than file-scope constants: this file sits close to
-- Lua's 200-local limit for a main chunk.
function Client.FitQuestLogRowsToList()
    local frame = ResolveObject("QuestLogFrame")
    local scroll = ResolveObject("QuestLogListScrollFrame")
    if not frame or not scroll or not Client.IsObjectShown(frame) then
        return nil
    end
    local _, paneBottom = Client.GetObjectCorner(scroll)
    if type(paneBottom) ~= "number" then
        return nil
    end

    local fitting = 0
    local overflow = nil
    local index = 1
    local misses = 0
    while index <= 30 and misses < 3 and not overflow do
        local row = ResolveObject("QuestLogTitle" .. tostring(index))
        if not row then
            misses = misses + 1
        else
            misses = 0
            if not Client.IsObjectShown(row) then
                break
            end
            local _, bottom = Client.GetObjectCorner(row)
            if type(bottom) ~= "number" then
                -- No geometry, no opinion: leave the list exactly as it is.
                return nil
            end
            -- Half a pixel of slack: a row resting exactly on the page edge is
            -- inside it.
            if bottom < paneBottom - 0.5 then
                overflow = index
            else
                fitting = index
            end
        end
        index = index + 1
    end
    -- A page that cannot hold six rows is a measurement this should not act on.
    if not overflow or fitting < 6 then
        return nil
    end

    index = overflow
    misses = 0
    while index <= 30 and misses < 3 do
        local row = ResolveObject("QuestLogTitle" .. tostring(index))
        if not row then
            misses = misses + 1
        else
            misses = 0
            Client.HideObject(row)
        end
        index = index + 1
    end

    -- The stock row-count global, which is also what QuestLog_Update hands
    -- FauxScrollFrame_Update: lowering it is what makes the scroll bar appear
    -- for the rows that were just taken off the page.
    QUESTS_DISPLAYED = fitting
    frame.unrealQuestFittedRows = fitting
    Client.RefreshQuestLog()
    return fitting
end

-- Which quest log entry a native row is currently showing: the scrolled index
-- first, the row's own stamped ID second.
--
-- Both are returned, and neither is trustworthy on its own. The client fills
-- the row from the offset, so that is the primary answer; the ID agrees only
-- while something keeps restamping it, and every caller here verifies the
-- candidate against the row's own text before acting on it. unrealUI's quest
-- log derives the index from the offset the same way on this client, and
-- never from GetID.
function Client.GetQuestLogRowQuestIndex(row, rowIndex)
    local id = Client.GetFrameId(row)
    if type(rowIndex) ~= "number" or rowIndex < 1 then
        return id
    end
    local offset = Client.GetQuestLogScrollOffset()
    if not offset then
        return id
    end
    local scrolled = rowIndex + offset
    if scrolled == id then
        return id
    end
    return scrolled, id
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

-- Writes the text of a widget the CLIENT owns, the counterpart of
-- GetObjectText above -- not Client.SetButtonLabel, which drives the
-- unrealQuestLabel FontString this addon attaches to buttons it created
-- itself and which a native row does not have.
--
-- A native templated Button keeps its label in the FontString GetFontString
-- returns, so that region is preferred and Button:SetText is only the
-- fallback. Both are pcall'd: this is the one place in the addon that writes
-- into stock FrameXML's own widgets, and a client that refuses must leave the
-- caller with a false rather than an error.
-- A WALKED widget, exchanged for one that can actually be written to.
--
-- On this client GetRegions/GetChildren hand back a FRESH wrapper around the
-- underlying widget rather than the global object, and those wrappers carry
-- the READERS without the WRITERS. Measured, all three in the same session:
--
--   * questgiver.region_walk_returns_same_objects.v1 -- the FontString the
--     depth-2 region walk returns for the quest title is NOT (==) the
--     QuestTitleText global, while its own GetName() answers "QuestTitleText";
--   * questgivertext run 1 -- SetText read as nil on all 86 walked objects,
--     including UnrealQuestDetailReward1, a FontString THIS ADDON created and
--     had just written to;
--   * questgiver.settext_read_reports_function.v1 -- the same widgets reached
--     through their globals report SetText as a function, accept both call
--     forms, and the text changes.
--
-- So a wrapper is fine to read a widget through and useless to write through,
-- and anything that FOUND a widget by walking a frame has to go back to the
-- name before writing to it. The name comes off the wrapper itself, so this
-- exchanges one handle on a widget for another handle on that same widget and
-- never picks a different one: a caller that verified what a field is showing
-- keeps that guarantee. An object that already accepts SetText -- everything
-- resolved by name, which is most of this file -- is returned untouched, and
-- so is an unnamed or unresolvable one, leaving the caller exactly where it
-- would have been without this.
function Client.ResolveWritableObject(object)
    if not object then
        return nil
    end
    if type(object.SetText) == "function" then
        return object
    end
    local name = Client.GetObjectName(object)
    if type(name) ~= "string" or name == "" then
        return object
    end
    local named = ResolveObject(name)
    if named and type(named.SetText) == "function" then
        return named
    end
    return object
end

function Client.SetNativeObjectText(object, text)
    if not object or type(text) ~= "string" then
        return false
    end
    object = Client.ResolveWritableObject(object)
    local target = nil
    if type(object.GetFontString) == "function" then
        local resolved, value = pcall(object.GetFontString, object)
        if resolved and value and type(value.SetText) == "function" then
            target = value
        end
    end
    if not target and type(object.SetText) == "function" then
        target = object
    end
    if not target then
        return false
    end
    local ok = pcall(target.SetText, target, text)
    return ok and true or false
end

-- OFFICIAL_CLIENT_DOCUMENTATION: ScrollFrame:UpdateScrollChildRect() updates
-- its range after child text changes height. The native Quest Log detail pane
-- is a captured ScrollFrame; guarded dispatch keeps an altered skin harmless.
function Client.UpdateScrollChildRect(object)
    if not object or type(object.UpdateScrollChildRect) ~= "function" then
        return false
    end
    local ok = pcall(object.UpdateScrollChildRect, object)
    return ok and true or false
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
-- An optional beforeHandler prepares the widget before the previous handler;
-- handler always runs afterwards, including when the native handler errors.
-- Without beforeHandler the previous handler runs first. A native handler
-- that errors must not stop UnrealQuest's addition, and UnrealQuest's
-- addition must never be what breaks a native row. Vanilla script handlers
-- read the implicit `this`/`arg1` globals rather than parameters, so nothing
-- is forwarded and nothing is rewritten.
function Client.ChainScript(frame, scriptType, handler, beforeHandler)
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

    local chained = function()
        if type(beforeHandler) == "function" then
            pcall(beforeHandler)
        end
        if previous then
            pcall(previous)
        end
        pcall(handler)
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
local TRACKER_HEADER_HEIGHT = 20
local TRACKER_BUTTON_SIZE = 16
local TRACKER_HEADER_BUTTONS = 2
local TRACKER_NPC_FINDER_ICON_SIZE = TRACKER_BUTTON_SIZE * 0.9
-- The tracker uses its dedicated find-NPC icon, shipped with the addon so it
-- remains available independently of the client's icon library.
-- Keep the path extensionless: this client silently draws nothing when an
-- addon texture path includes the ".tga" suffix.
local TRACKER_NPC_FINDER_ICON_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\search-icon"
local TRACKER_ACCENT_WIDTH = 2
local TRACKER_PADDING = 6
local TRACKER_BAR_HEIGHT = 2
-- How far a quest row's title is pushed right to clear the round quest dot
-- drawn at that row's own left edge. A row whose dot is hidden gets inset 0
-- instead, so the title moves onto the left edge rather than leaving a hole
-- where the dot used to be (Client.SetTrackerRowQuestMark).
local TRACKER_QUEST_MARK_INSET = 13
-- The mark's box height in pixels -- both for the round dot (square, so this
-- is also its width) and as the bounding dimension a non-square mark texture
-- is fit into without being stretched off its own aspect ratio.
local TRACKER_QUEST_MARK_SIZE = 10
-- Native pixel size of media/CompleteQuestIcon.tga. SetAllPoints-style
-- textures on this client stretch to whatever box they are given -- fine for
-- the round dot, which is square, but this asset is a tall narrow checkmark:
-- boxing it at TRACKER_QUEST_MARK_SIZE square visibly squashed it wide. The
-- mark is instead boxed at the same height with its own width/height ratio
-- preserved (Client.SetTrackerRowQuestMark).
local TRACKER_COMPLETE_ICON_WIDTH = 19
local TRACKER_COMPLETE_ICON_HEIGHT = 32
local TRACKER_FOLLOWING_MARK_WIDTH = 13
local TRACKER_FOLLOWING_MARK_HEIGHT = 17
local QUEST_LOG_QUEST_DOT_SIZE = 10
local TRACKER_FOLLOWING_ARROW_WIDTH = 8
local TRACKER_FOLLOWING_ARROW_HEIGHT = 10

-- Extensionless addon paths: this client silently draws nothing when the
-- suffix is included. Both source PNGs are converted to alpha-preserving TGA
-- files in media/ so the legacy texture loader can consume them reliably.
local TRACKER_FOLLOWING_QUEST_TEXTURE =
    "Interface\\AddOns\\unrealQuest\\media\\icons\\quest-marker"
local TRACKER_FOLLOWING_ARROW_TEXTURE =
    "Interface\\AddOns\\unrealQuest\\media\\following-arrow"
-- The authored gold plaque that marks the followed quest in the modern quest
-- log list. It is a full-width band -- gold bevelled frame, dark interior --
-- authored at 558x34, so it replaces both the translucent accent fill and the
-- one-pixel accent border a followed row used to draw. It is stretched to the
-- row rather than nine-sliced: the end chamfers are a small fraction of the
-- width, and a row is far shorter than the source, so the bevel thins rather
-- than skewing. Not a power of two, which this client does not require
-- (media/ActiveQuestIcon.tga is 19x32 and renders).
local QUEST_LOG_FOLLOWING_PLAQUE_TEXTURE =
    "Interface\\AddOns\\unrealQuest\\media\\followed-quest"
-- The row's native title starts at x=24. Its gutter is shared deliberately:
-- the tracked bar ends at x=8, then the quest-colour dot or followed marker
-- starts at x=10. The native title is moved from x=24 to x=23 below, and the
-- plaque begins three pixels before it.
local QUEST_LOG_QUEST_MARK_OFFSET_X = 10
local QUEST_LOG_QUEST_DOT_OFFSET_X = 11
local QUEST_LOG_FOLLOWING_PLAQUE_INSET = 20
local QUEST_LOG_ROW_RIGHT_INSET = 4
-- uUI Modern only: the whole plaque sits one pixel further right there, by
-- request. Its list panel keeps a tail after the row for the scroll bar, so
-- the plaque has that room to move into; the native and Classic WoW rows have
-- no such tail and keep the plaque at its unshifted inset.
local QUEST_LOG_FOLLOWING_PLAQUE_MODERN_SHIFT_X = 1
local QUEST_LOG_TITLE_OFFSET_X = -1
local QUEST_LOG_TAG_OFFSET_X = -6
-- The row's own name, in its three template states. Both the offset pass and
-- the difficulty-colour pass below write to all of them, so a hovered or
-- disabled row never disagrees with the resting one.
local QUEST_LOG_TITLE_REGIONS = { "NormalText", "HighlightText", "DisabledText" }
-- uUI Modern extends its list panel 26 pixels beyond the native row gutter to
-- contain the scroll bar, and places its detail pane 35 pixels after the list.
-- Those two numbers are its own; both are treated as the maximum here.
--
-- The followed plaque stops four pixels before the row's right edge, so the
-- tail after it is dead space -- but only as far as the scroll bar allows. The
-- tail is measured
-- from the bar itself and keeps whatever the bar occupies plus a four-pixel
-- margin; only the remainder is reclaimed, and the detail pane moves left by
-- exactly that and grows by the same, so the panel gap and the Quest Log's
-- overall width never change. A list with no scroll bar therefore still gets
-- the tight four-pixel tail, and a list that scrolls keeps its bar inside the
-- panel where it belongs.
local MODERN_QUEST_LOG_LIST_PANEL_TAIL = 26
local MODERN_QUEST_LOG_DETAIL_OFFSET_X = 35
local MODERN_QUEST_LOG_SCROLLBAR_MARGIN = 4

Client.TRACKER_HEADER_HEIGHT = TRACKER_HEADER_HEIGHT
Client.TRACKER_PADDING = TRACKER_PADDING
Client.FOLLOWING_QUEST_TEXTURE = TRACKER_FOLLOWING_QUEST_TEXTURE

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

-- Quest-log tracked mark ----------------------------------------------------
--
-- The stock QuestLogTitleNCheck texture is not a surface an addon can own.
-- `questlog.stock_track_mark_is_native_owned_and_reanchored`
-- (BEHAVIOR_VERIFIED, probeVersion 1.40.0) captured it moving from a common
-- x=50 anchor to a title-width-dependent x=83..128 after native refreshes.
-- `questlog.tracked_check_texture_cannot_be_reanchored` separately established
-- that a bare replacement Texture cannot fix the stacking: it has no frame
-- level and only a clipped sliver survives in the row gutter.
--
-- Standalone UnrealQuest therefore owns one real Frame per native row. Its
-- fixed 3x14 accent never depends on the title or its temporary [level]
-- decoration, and its explicit frame level puts it above the native list. If
-- unrealUI has already published its equivalent `uuiTrackMark`, that existing
-- presentation wins and our standalone frame stays hidden.
local QUEST_LOG_TRACK_MARK_WIDTH = 3
local QUEST_LOG_TRACK_MARK_HEIGHT = 14
local QUEST_LOG_TRACK_MARK_OFFSET_X = 2
local QUEST_LOG_TRACK_MARK_LEVEL_OFFSET = 4

local function ConfigureQuestLogTrackMark(mark, row)
    if not mark or not row then
        return false
    end
    if not mark.unrealQuestConfigured then
        Client.SetObjectSize(mark, QUEST_LOG_TRACK_MARK_WIDTH, QUEST_LOG_TRACK_MARK_HEIGHT)
        if type(mark.ClearAllPoints) == "function" then
            pcall(mark.ClearAllPoints, mark)
        end
        if type(mark.SetPoint) == "function" then
            pcall(mark.SetPoint, mark, "LEFT", row, "LEFT", QUEST_LOG_TRACK_MARK_OFFSET_X, 0)
        end
        if type(mark.EnableMouse) == "function" then
            pcall(mark.EnableMouse, mark, false)
        end
        mark.unrealQuestConfigured = true
    end
    if type(mark.SetFrameLevel) == "function" and type(row.GetFrameLevel) == "function" then
        local ok, level = pcall(row.GetFrameLevel, row)
        if ok and type(level) == "number" then
            pcall(mark.SetFrameLevel, mark, level + QUEST_LOG_TRACK_MARK_LEVEL_OFFSET)
        end
    end
    if not mark.unrealQuestTexture then
        local accent = UQ.colors and UQ.colors.accent or { 1, 0.65, 0 }
        local texture = CreateSolid(mark, "ARTWORK", accent[1], accent[2], accent[3], 1)
        if texture and type(texture.SetAllPoints) == "function" then
            pcall(texture.SetAllPoints, texture, mark)
        end
        mark.unrealQuestTexture = texture
    end
    return mark.unrealQuestTexture and true or false
end

local function GetStandaloneQuestLogTrackMark(row, rowIndex)
    local name = "UnrealQuestQuestLogTrackMark" .. tostring(rowIndex)
    local mark = row.unrealQuestTrackMark or ResolveObject(name)
    if not mark or type(mark.Show) ~= "function" or type(mark.Hide) ~= "function" then
        local create = Resolve("CreateFrame")
        if not create then
            return nil
        end
        local ok, created = pcall(create, "Frame", name, row)
        if not ok or not created then
            return nil
        end
        mark = created
    end
    row.unrealQuestTrackMark = mark
    if not ConfigureQuestLogTrackMark(mark, row) then
        return nil
    end
    return mark
end

-- Drives UnrealQuest's unlimited tracking indicator without treating the
-- client's five-slot IsQuestWatched state as authoritative.
function Client.SetQuestLogTrackMark(rowIndex, tracked)
    if type(rowIndex) ~= "number" then
        return nil
    end
    local row = Client.GetNamedObject("QuestLogTitle" .. tostring(rowIndex))
    if not row then
        return nil
    end

    local owned = row.unrealQuestTrackMark
    local mark = row.uuiTrackMark
    local style = "unrealUI"
    if not mark or type(mark.Show) ~= "function" or type(mark.Hide) ~= "function" then
        mark = GetStandaloneQuestLogTrackMark(row, rowIndex)
        style = "standalone"
    elseif owned then
        Client.HideObject(owned)
    end
    if not mark then
        return nil
    end

    -- Once an owned mark is available, the title-width-dependent stock check
    -- must not draw beside it. Alpha is the stable suppression: the measured
    -- public QuestLog_Update changed anchors and shown state but preserved
    -- alpha. Hide closes the current frame immediately as well.
    local stock = Client.GetNamedObject("QuestLogTitle" .. tostring(rowIndex) .. "Check")
    if stock and stock ~= mark then
        if type(stock.SetAlpha) == "function" then
            pcall(stock.SetAlpha, stock, 0)
        end
        Client.HideObject(stock)
    end

    if tracked then
        Client.ShowObject(mark)
    else
        Client.HideObject(mark)
    end
    return style
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

-- Entity-objective progress is deliberately rendered in an owned tooltip, not
-- appended into GameTooltip. `tooltip.added_lines_do_not_relayout`
-- (USER_CONFIRMED_INGAME, 2026-08-26) established that Lua-added lines can
-- exist in GameTooltip's text regions without the native tooltip adopting
-- their height. World-object tooltips also repopulate while the hover remains
-- active, which would make an append-only addon race the native rebuild. This
-- owned tooltip is populated before Show, the same confirmed sequence used by
-- the map tooltips above. The native tooltip is therefore replaced visually by
-- one combined tooltip -- its own rows, read back through
-- Client.GetGameTooltipLines, reprinted above the quest rows -- without any
-- native line ever being mutated.
local ENTITY_TOOLTIP_COVER_PAD = 4
-- Mouse-out owns one simple custom delay in both cursor modes. IsShown can turn
-- false before the native renderer's last fade frame, so it starts this timer
-- rather than removing the opaque replacement immediately.
local ENTITY_TOOLTIP_FADE_HOLD = 0.7

function Client.GetEntityTooltipFadeHold()
    local host = ResolveObject("UnrealUI")
    if host and type(host.ModuleConfig) == "function" then
        local ok, config = pcall(host.ModuleConfig, "tooltip", {
            followCursor = false,
            fadeHold = 0.7,
        })
        if ok and type(config) == "table"
            and type(config.fadeHold) == "number"
            and config.fadeHold >= 0.25 and config.fadeHold <= 1 then
            return config.fadeHold
        end
    end
    return ENTITY_TOOLTIP_FADE_HOLD
end

-- The slash command and unrealUI's slider share the same host-owned value.
-- The local copy remains the fallback when unrealUI is absent.
function Client.SetEntityTooltipFadeHold(seconds)
    if type(seconds) ~= "number" or seconds < 0.25 or seconds > 1 then
        return false, Client.GetEntityTooltipFadeHold()
    end
    ENTITY_TOOLTIP_FADE_HOLD = seconds
    local host = ResolveObject("UnrealUI")
    if host and type(host.ModuleConfig) == "function" then
        local ok, config = pcall(host.ModuleConfig, "tooltip", {
            followCursor = false,
            fadeHold = 0.7,
        })
        if ok and type(config) == "table" then
            config.fadeHold = seconds
        end
    end
    return true, Client.GetEntityTooltipFadeHold()
end

-- Host integration, not a client API assumption: whether unrealUI is hosting
-- with its Dragonflight-styled `modern-wow` theme, whose Quest Log page art
-- needs some of this addon's placements nudged. Resolved on every call so a
-- late-initialising host or a theme switch is picked up; false when the host
-- or its theme accessor is absent.
function Client.IsUnrealUIModernWowTheme()
    local host = ResolveObject("UnrealUI")
    if not host or type(host.GetActiveThemeStyle) ~= "function" then
        return false
    end
    local ok, style = pcall(host.GetActiveThemeStyle)
    return ok and style == "modern-wow" or false
end

-- Host integration: the quest log's action buttons wear their textured skins
-- (Client.SetQuestLogButtonSkin) on a UI unrealUI does not theme at all, and
-- under its modern-wow theme; every other unrealUI theme keeps the flat look.
function Client.UsesQuestLogTexturedButtons()
    if not ResolveObject("UnrealUI") then
        return true
    end
    return Client.IsUnrealUIModernWowTheme()
end

function Client.GetEntityTooltipStyle()
    -- The host's world tooltip is flat in BOTH Modern and Classic WoW.
    -- ThemeStyleUsesNativeChrome describes stock windows, not tooltips; using
    -- it here selected a beveled replacement around our own quest rows.
    -- Resolve the host on each refresh so late availability also recovers.
    if ResolveObject("UnrealUI") then
        return "modern"
    end
    return "native"
end

-- Host integration, not a client API assumption. tooltipdupe v4 used this same
-- read to classify every rendered sample and measured the unstable world-object
-- anchor only while cursor-follow was enabled. nil keeps callers conservative
-- when the host is absent or still initializing.
function Client.IsWorldTooltipCursorFollowEnabled()
    local host = ResolveObject("UnrealUI")
    if not host or type(host.ModuleConfig) ~= "function" then
        return nil
    end
    local ok, config = pcall(host.ModuleConfig, "tooltip", {
        followCursor = false,
        fadeHold = 0.7,
    })
    if not ok or type(config) ~= "table" then
        return nil
    end
    return config.followCursor and true or false
end

-- Why the Modern entity tooltip is not a GameTooltipTemplate frame
-- ----------------------------------------------------------------
-- The stock tooltip background cannot be verified away on this client, so it
-- is built away instead.
--
-- Probe `tooltipfade` (v1 and v2, 3942 rendered frames over twelve mouse-offs)
-- established, and then ran out of room:
--   * The native GameTooltip is NEVER exposed. Zero uncovered frames, before
--     or after the cover, in any run; its whole 1.0 -> 0 fade happens under
--     the opaque replacement. So no stock flash can come from that frame.
--   * GetBackdropBorderColor does NOT exist here, and neither does
--     GetBackdropColor: backdrop fill and border are write-only state.
--   * GetBackdrop() reports `WHITE8X8|UI-Tooltip-Border` on every frame of
--     every run, for GameTooltip and for a template-built replacement alike.
--     SetBackdrop with a table omitting edgeFile does not remove the stock
--     edge from the backdrop TABLE either -- the other half of
--     `rendering.setbackdrop_keeps_native_edge_art` -- so the table cannot
--     discriminate a suppressed edge from a drawing one.
-- Nothing readable is left. Whether a GameTooltipTemplate frame is currently
-- drawing its tan edge is unobservable from Lua on this client.
--
-- A plain Frame has no backdrop until this addon gives it one, no
-- <name>Texture1..3 regions, and none of the template's own handlers, so there
-- is no stock chrome to suppress, to lose a race with, or to fail to observe.
-- Its GetBackdrop() reads `WHITE8X8|-`, which IS checkable. The Modern panel
-- is therefore an owned Frame with owned rows (OwnedTooltip.Render below),
-- and only the standalone `native` style -- where stock chrome is the
-- wanted look, matching the rest of an unthemed UI -- still uses the template.

-- Owned Modern tooltip: metrics, row pool and renderer.
--
-- All of it hangs off ONE table local. This chunk sits at Lua's hard 200-local
-- ceiling (knowledge.json / lua.top_level_local_limit_silent_file_failure), and
-- a handful of extra top-level locals here takes the whole file down without
-- reporting anything.
local OwnedTooltip = {
    -- Close to the native tooltip's own spacing, so the replacement does not
    -- read as a differently sized window.
    PADDING = 9,
    ROW_SPACING = 2,
    -- Smallest gap between a row's left and right text before the panel widens.
    COLUMN_GAP = 12,
    ROW_HEIGHT = 14,
    -- Space between the host-anchored health bar and the owned box's bottom.
    -- Only the inset is a constant: the bar's HEIGHT is read live at cover
    -- time, because 12 is the current host's value and not a client one.
    STATUS_BAR_INSET = 3,
    -- Text uses a stock font OBJECT through CreateFontString's inherits
    -- argument and never SetFont with a path: fonts.setfont_silent_failure
    -- records SetFont keeping the inherited font without reporting anything.
    FONT = "GameTooltipText",
    FONT_FALLBACK = "GameFontNormal",
}

function OwnedTooltip.CreateLabel(panel)
    if type(panel.CreateFontString) ~= "function" then
        return nil
    end
    local ok, label = pcall(panel.CreateFontString, panel, nil, "OVERLAY",
        OwnedTooltip.FONT)
    if not ok or not label then
        ok, label = pcall(panel.CreateFontString, panel, nil, "OVERLAY",
            OwnedTooltip.FONT_FALLBACK)
    end
    if not ok or not label then
        return nil
    end
    StripShadow(label)
    return label
end

-- The native health bar is parented to GameTooltip, so no timer on an owned
-- panel can keep it visible after the client hides that parent. Keep a small
-- owned copy inside the combined tooltip instead. It samples the native bar
-- while the unit is live, then remains unchanged through mouse-out and leaves
-- in the same Hide call as the panel.
function OwnedTooltip.CreateHealthBar(panel, name)
    local create = Resolve("CreateFrame")
    if not create then
        return nil
    end
    local ok, health = pcall(create, "Frame", name .. "Health", panel)
    if not ok or not health or type(health.CreateTexture) ~= "function" then
        return nil
    end
    local backgroundOk, background = pcall(health.CreateTexture, health, nil, "BACKGROUND")
    local fillOk, fill = pcall(health.CreateTexture, health, nil, "ARTWORK")
    if not backgroundOk or not background or not fillOk or not fill then
        Client.HideObject(health)
        return nil
    end
    pcall(background.SetAllPoints, background, health)
    pcall(background.SetTexture, background, 1, 1, 1, 1)
    pcall(fill.SetTexture, fill, 1, 1, 1, 1)
    health.unrealQuestBackground = background
    health.unrealQuestFill = fill
    panel.unrealQuestHealthBar = health
    Client.HideObject(health)
    return health
end

function OwnedTooltip.UpdateHealthBar(panel, nativeBar, width, height)
    local health = panel and panel.unrealQuestHealthBar
    if not health or not nativeBar or type(width) ~= "number" or width <= 0
            or type(height) ~= "number" or height <= 0 then
        Client.HideObject(health)
        return false
    end

    pcall(health.SetWidth, health, width)
    pcall(health.SetHeight, health, height)
    pcall(health.ClearAllPoints, health)
    pcall(health.SetPoint, health, "BOTTOMLEFT", panel, "BOTTOMLEFT",
        ENTITY_TOOLTIP_COVER_PAD, ENTITY_TOOLTIP_COVER_PAD)
    if type(panel.GetFrameLevel) == "function" and type(health.SetFrameLevel) == "function" then
        local levelOk, level = pcall(panel.GetFrameLevel, panel)
        if levelOk and type(level) == "number" then
            pcall(health.SetFrameLevel, health, level + 2)
        end
    end

    local percent = 1
    if type(nativeBar.GetValue) == "function"
            and type(nativeBar.GetMinMaxValues) == "function" then
        local valueOk, value = pcall(nativeBar.GetValue, nativeBar)
        local rangeOk, minimum, maximum = pcall(nativeBar.GetMinMaxValues, nativeBar)
        if valueOk and rangeOk and type(value) == "number"
                and type(minimum) == "number" and type(maximum) == "number"
                and maximum > minimum then
            percent = (value - minimum) / (maximum - minimum)
        end
    end
    if percent < 0 then
        percent = 0
    elseif percent > 1 then
        percent = 1
    end

    Client.SetSolidColor(health.unrealQuestBackground, 0.08, 0.08, 0.08, 1)
    Client.SetSolidColor(health.unrealQuestFill, 0.18, 0.78, 0.28, 1)
    pcall(health.unrealQuestFill.ClearAllPoints, health.unrealQuestFill)
    pcall(health.unrealQuestFill.SetPoint, health.unrealQuestFill,
        "TOPLEFT", health, "TOPLEFT", 0, 0)
    pcall(health.unrealQuestFill.SetPoint, health.unrealQuestFill,
        "BOTTOMLEFT", health, "BOTTOMLEFT", 0, 0)
    pcall(health.unrealQuestFill.SetWidth, health.unrealQuestFill,
        math.max(0.1, width * percent))
    Client.ShowObject(health.unrealQuestFill)
    Client.ShowObject(health)
    return true
end

-- One pooled row. Rows are reused across hovers rather than recreated, the
-- same pool-and-reuse shape the tracker rows and the flat border already use.
function OwnedTooltip.GetRow(panel, index)
    local pool = panel.unrealQuestRows
    if not pool then
        pool = {}
        panel.unrealQuestRows = pool
    end
    local row = pool[index]
    if row then
        return row
    end
    local left = OwnedTooltip.CreateLabel(panel)
    if not left then
        return nil
    end
    row = { left = left, right = OwnedTooltip.CreateLabel(panel) }
    pool[index] = row
    return row
end

-- Measures the row's text, then puts the real text back.
--
-- The measurement runs on the string with its colour escapes stripped. A quest
-- row carries a lot of them -- the grey dash, the progress colour, and up to
-- four more around a drop-rate suffix, some forty characters of markup on a
-- line whose visible part can be shorter than that. Whether this client's
-- GetStringWidth measures the display string or the raw one is not established
-- (Client.MeasureTrackerRowTextWidth does not have to care: a tracker title
-- carries no escapes). Measuring the stripped string is correct either way,
-- and is what keeps a heavily coloured row from inflating the panel.
--
-- Both SetText calls happen inside this one synchronous rebuild, so the
-- stripped string is never a rendered frame.
function OwnedTooltip.Measure(label, text)
    if not label or type(label.GetStringWidth) ~= "function" then
        return 0
    end
    pcall(label.SetText, label, StripColourEscapes(text or ""))
    local ok, width = pcall(label.GetStringWidth, label)
    pcall(label.SetText, label, text or "")
    if ok and type(width) == "number" and width > 0 then
        return width
    end
    return 0
end

-- Lays the lines out on the owned panel and sizes it to them. Same line shape
-- RenderTooltipLines consumes, so callers do not care which panel they hold.
-- Populated before Show, like every other tooltip route here.
function OwnedTooltip.Render(panel, lines)
    local total = table.getn(lines or {})
    if total == 0 then
        return false
    end

    local widest = 0
    local height = OwnedTooltip.PADDING
    local index = 1
    while index <= total do
        local line = lines[index]
        local row = OwnedTooltip.GetRow(panel, index)
        if not row then
            return false
        end
        local leftText, rightText = "", nil
        local r, g, b = 1, 1, 1
        if line then
            if line.separator then
                leftText = " "
            elseif type(line.left) == "string" then
                leftText = line.left
                rightText = line.right
            elseif type(line.text) == "string" then
                leftText = line.text
            end
            r = line.r or 1
            g = line.g or 1
            b = line.b or 1
        end

        pcall(row.left.SetText, row.left, leftText)
        pcall(row.left.SetTextColor, row.left, r, g, b)
        Client.ShowObject(row.left)

        local rowWidth = OwnedTooltip.Measure(row.left, leftText)
        if row.right then
            if type(rightText) == "string" and rightText ~= "" then
                pcall(row.right.SetText, row.right, rightText)
                pcall(row.right.SetTextColor, row.right,
                    line.rightR or 1, line.rightG or 1, line.rightB or 1)
                Client.ShowObject(row.right)
                rowWidth = rowWidth + OwnedTooltip.COLUMN_GAP
                    + OwnedTooltip.Measure(row.right, rightText)
            else
                pcall(row.right.SetText, row.right, "")
                Client.HideObject(row.right)
            end
        end
        if rowWidth > widest then
            widest = rowWidth
        end

        pcall(row.left.ClearAllPoints, row.left)
        pcall(row.left.SetPoint, row.left, "TOPLEFT", panel, "TOPLEFT",
            OwnedTooltip.PADDING, -height)
        if row.right then
            pcall(row.right.ClearAllPoints, row.right)
            pcall(row.right.SetPoint, row.right, "TOPRIGHT", panel, "TOPRIGHT",
                -OwnedTooltip.PADDING, -height)
        end

        -- A FIXED pitch, never FontString:GetHeight.
        --
        -- Every row here is a single line: native rows arrive already wrapped,
        -- one row each (Client.GetGameTooltipLines reads them back row by row),
        -- and the quest rows are short. Nothing needs measuring.
        --
        -- Measuring would also be a feedback loop, which is the dangerous part.
        -- These rows carry no explicit width, and GetHeight on an unsized
        -- FontString has no record on this client; the one place the addon does
        -- trust it (Client.MeasureTrackerRowTextHeight) is careful to say it
        -- reads only AFTER the label has its final width. A single over-large
        -- read here would be written straight into the panel's own height, and
        -- the next rebuild would measure rows inside that taller panel -- a
        -- tooltip that grows without bound rather than one that is wrong once.
        height = height + OwnedTooltip.ROW_HEIGHT
        if index < total then
            height = height + OwnedTooltip.ROW_SPACING
        end
        index = index + 1
    end
    height = height + OwnedTooltip.PADDING

    -- Rows left over from a taller previous hover would otherwise keep drawing
    -- outside the resized panel.
    local pool = panel.unrealQuestRows or {}
    local extra = total + 1
    while pool[extra] do
        Client.HideObject(pool[extra].left)
        Client.HideObject(pool[extra].right)
        extra = extra + 1
    end

    if type(panel.SetWidth) == "function" then
        pcall(panel.SetWidth, panel, widest + OwnedTooltip.PADDING * 2)
    end
    -- The height of the ROWS alone, kept for Client.CoverNativeEntityTooltip:
    -- it adds the contained health bar's live height on top of this on every
    -- poll, and it has to add it to a base that does not already include it.
    panel.unrealQuestContentHeight = height
    if type(panel.SetHeight) == "function" then
        pcall(panel.SetHeight, panel, height)
    end
    return true
end

function Client.CreateEntityTooltipPanel(name, style)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local modern = style == "modern"
    local ok, panel
    if modern then
        -- An owned Frame, never GameTooltipTemplate -- see the long note above
        -- OwnedTooltip.Render. No stock backdrop, no stock texture
        -- regions, no template handlers, so the native background cannot come
        -- back on any frame, whether or not this client would let us see it.
        ok, panel = pcall(create, "Frame", name, parent)
    else
        -- Standalone: stock chrome is the WANTED look here, so the template
        -- stays. A fresh GameTooltip-template frame populated before Show is a
        -- confirmed working route on this client (map tooltips, aura scanner).
        ok, panel = pcall(create, "GameTooltip", name, parent, "GameTooltipTemplate")
    end
    if not ok or not panel then
        return nil
    end
    if type(panel.SetFrameStrata) == "function" then
        pcall(panel.SetFrameStrata, panel, "TOOLTIP")
    end
    panel.unrealQuestTooltipName = name
    panel.unrealQuestEntityStyle = modern and "modern" or "native"
    panel.unrealQuestOwnedChrome = modern and true or false

    if modern then
        -- Applied once, at creation. On a frame with no prior backdrop there is
        -- no stock edge for SetBackdrop to leave behind, so unlike the template
        -- route this does not have to be redone whenever the panel repopulates.
        Client.ApplyFlatTooltipStyle(panel, nil)
    end

    -- A fully opaque sibling sits between the native tooltip and the themed
    -- replacement. The client may ignore alpha on native regions, while this
    -- addon-owned texture follows the normal rendering path already confirmed
    -- by map pins and panels.
    local coverOk, cover = pcall(create, "Frame", name .. "Cover", parent)
    if coverOk and cover and type(cover.CreateTexture) == "function" then
        local textureOk, texture = pcall(cover.CreateTexture, cover, nil, "BACKGROUND")
        if textureOk and texture then
            pcall(texture.SetAllPoints, texture, cover)
            pcall(texture.SetTexture, texture, 0.025, 0.025, 0.025, 1)
            cover.unrealQuestTexture = texture
            panel.unrealQuestCover = cover
            Client.HideObject(cover)
        end
    end
    OwnedTooltip.CreateHealthBar(panel, name)
    Client.HideObject(panel)
    return panel
end

-- The unit health bar under the combined tooltip -----------------------------
--
-- GameTooltipStatusBar is a native StatusBar whose width comes entirely from
-- its two horizontal anchors: the stock client pins TOPLEFT/TOPRIGHT to
-- GameTooltip's BOTTOMLEFT/BOTTOMRIGHT, and a host that restyles the tooltip
-- (unrealUI's tooltip module) rewrites those same two points flush at 0,0.
-- Either way the bar takes the NATIVE tooltip's width, and it hangs BELOW the
-- native bounds -- which is exactly the strip the opaque replacement above does
-- not cover, so it keeps drawing while the panel stands in for the body.
--
-- Spanning it UNDER the panel is what produced the reported "two boxes". Probe
-- `tooltipdupe` v2 (1289 rendered frames, three hovers, unrealUI and
-- unrealQuest both loaded) measured the leftover box exactly: the native
-- tooltip BODY overhung the replacement by 0px in every frame, while
-- GameTooltipStatusBar overhung its bottom edge by its own full height in
-- every one (panel and cover 205x96, bar 205x12, overhang 12). A host that
-- gives the bar a background and an outline of its own -- unrealUI does --
-- draws that strip as a second window. Probe v3 then caught the attempted
-- re-anchor already lost back to the host, plus a different failure: an NPC's
-- native body was 162px wide while the content-only replacement was 136px.
-- The stable solution is therefore containment, not another anchor race: the
-- owned rectangle includes the current native body and host-anchored bar.
--
-- The native bar's anchors and draw level are left to the host. An owned copy
-- inside the replacement supplies the visible bar while the replacement is up.

local function ResolveTooltipStatusBar()
    local bar = ResolveObject("GameTooltipStatusBar")
    return bar
end

local function CaptureStatusBarLevel(bar)
    if bar.unrealQuestRaisedFor then
        return
    end
    bar.unrealQuestNativeLevel = nil
    if type(bar.GetFrameLevel) == "function" then
        local levelOk, level = pcall(bar.GetFrameLevel, bar)
        if levelOk and type(level) == "number" then
            bar.unrealQuestNativeLevel = level
        end
    end
end

-- Leaves the bar on the host's own anchors and only lifts its draw level above
-- the owned box. tooltipdupe v3 measured why moving the anchors is not a stable
-- contract: unrealQuest still recorded the bar as "inside", but the live first
-- point was already back on GameTooltip in every worst sample. The host owns
-- that geometry and may rebuild it at any time. CoverNativeEntityTooltip now
-- contains the host-anchored rectangle instead, so there is no anchor race.
function Client.RaiseEntityTooltipStatusBar(panel)
    local name = panel and panel.unrealQuestTooltipName
    local bar = ResolveTooltipStatusBar()
    if not bar or type(name) ~= "string" then
        return false, false
    end
    CaptureStatusBarLevel(bar)

    local raised = false
    if type(bar.SetFrameLevel) == "function"
            and type(bar.GetFrameLevel) == "function"
            and type(panel.GetFrameLevel) == "function" then
        local panelOk, panelLevel = pcall(panel.GetFrameLevel, panel)
        if panelOk and type(panelLevel) == "number" then
            local barOk, barLevel = pcall(bar.GetFrameLevel, bar)
            if not barOk or type(barLevel) ~= "number" or barLevel <= panelLevel then
                pcall(bar.SetFrameLevel, bar, panelLevel + 1)
                barOk, barLevel = pcall(bar.GetFrameLevel, bar)
            end
            raised = barOk and type(barLevel) == "number" and barLevel > panelLevel
        end
    end
    bar.unrealQuestRaisedFor = raised and name or nil
    bar.unrealQuestSpanning = nil
    bar.unrealQuestInside = nil
    return true, raised
end

-- How much taller the owned box has to be to contain the host-anchored bar. The bar's
-- height is READ, never assumed: 12 is unrealUI's BAR_HEIGHT today and another
-- skin may set its own. A bar that is not shown -- an object or an item, where
-- the client leaves it hidden -- reserves nothing.
function Client.GetEntityTooltipStatusBarReserve()
    local bar = ResolveTooltipStatusBar()
    if not bar or not Client.IsObjectShown(bar) then
        return 0
    end
    local height = Client.GetObjectHeight(bar)
    if type(height) ~= "number" or height <= 0 then
        return 0
    end
    return height + OwnedTooltip.STATUS_BAR_INSET
end

-- Puts the captured draw level back. A bar this addon never raised is never
-- written to, and a panel that was not the one using it leaves it alone, so
-- hiding the unused style's panel cannot disturb the live one.
function Client.RestoreEntityTooltipStatusBar(panel)
    local bar = ResolveTooltipStatusBar()
    if not bar or not bar.unrealQuestRaisedFor then
        return false
    end
    if panel and panel.unrealQuestTooltipName ~= bar.unrealQuestRaisedFor then
        return false
    end
    if type(bar.unrealQuestNativeLevel) == "number"
            and type(bar.SetFrameLevel) == "function" then
        pcall(bar.SetFrameLevel, bar, bar.unrealQuestNativeLevel)
    end
    bar.unrealQuestRaisedFor = nil
    bar.unrealQuestNativeLevel = nil
    bar.unrealQuestSpanning = nil
    bar.unrealQuestInside = nil
    return true
end

-- Keep the replacement above the native tooltip without inheriting its frame
-- dimensions. GameTooltip is a reused native frame, and a host can leave its
-- reported width or height at the size of an earlier item tooltip. Copying
-- those stale bounds into this panel produced a large empty body even though
-- OwnedTooltip.Render had already calculated the exact content size.
--
-- What the owned rectangle has to contain is the tooltip BODY *and*
-- GameTooltipStatusBar. The bar is a separate frame that GameTooltip's own
-- GetHeight does not count, and sizing this from that height alone is what left
-- a 12px strip of native frame drawing under the replacement -- the second box
-- probe `tooltipdupe` measured. The bar's height is therefore read live here,
-- every poll, and reserved inside the panel.
function Client.CoverNativeEntityTooltip(panel)
    local tooltip = ResolveGameTooltip()
    if not panel or not panel.unrealQuestCover or not tooltip then
        return false
    end
    local cover = panel.unrealQuestCover

    -- Reassert the fill at the presentation's current owned opacity. During
    -- mouse-out Client.SyncEntityTooltipFade deliberately keeps that value at
    -- 1 until its measured hold expires, so native pixels cannot show through.
    if panel.unrealQuestEntityStyle == "modern"
            and type(panel.SetBackdropColor) == "function" then
        local fill = panel.unrealQuestAlpha
        if type(fill) ~= "number" then
            fill = 1
        end
        pcall(panel.SetBackdropColor, panel, FLAT_BACKGROUND[1], FLAT_BACKGROUND[2],
            FLAT_BACKGROUND[3], fill)
    end

    -- Establish draw order. The host keeps ownership of the native bar; the
    -- opaque replacement covers it and draws its owned snapshot above itself.
    if type(panel.SetFrameLevel) == "function" and type(tooltip.GetFrameLevel) == "function" then
        local levelOk, level = pcall(tooltip.GetFrameLevel, tooltip)
        if levelOk and type(level) == "number" then
            if cover and type(cover.SetFrameLevel) == "function" then
                pcall(cover.SetFrameLevel, cover, level + 5)
            end
            pcall(panel.SetFrameLevel, panel, level + 10)
        end
    end

    -- Contain BOTH live native rectangles. tooltipdupe v3 measured the fixed
    -- NPC case at native 162x81 against an owned 136x111 box: 30px of the body
    -- was visible on the left in every captured replacement frame. Content-only
    -- sizing can therefore never satisfy the cover contract. The panel grows to
    -- the larger of its rows and the CURRENT native body, plus the live bar
    -- height below it; the recorded content height prevents compounding.
    local nativeWidth = Client.GetObjectWidth(tooltip)
    local nativeHeight = Client.GetObjectHeight(tooltip)
    local panelWidth = Client.GetObjectWidth(panel)
    local baseHeight = panel.unrealQuestContentHeight
    if type(baseHeight) ~= "number" then
        baseHeight = Client.GetObjectHeight(panel)
        panel.unrealQuestContentHeight = baseHeight
    end
    local reserve = Client.GetEntityTooltipStatusBarReserve()
    local barHeight = reserve - OwnedTooltip.STATUS_BAR_INSET
    if barHeight < 0 then
        barHeight = 0
    end
    local finalWidth = panelWidth
    if type(nativeWidth) == "number" then
        local neededWidth = nativeWidth + 2 * ENTITY_TOOLTIP_COVER_PAD
        if type(finalWidth) ~= "number" or finalWidth < neededWidth then
            finalWidth = neededWidth
        end
    end
    if type(finalWidth) == "number" and type(panel.SetWidth) == "function" then
        pcall(panel.SetWidth, panel, finalWidth)
    end
    local finalHeight
    if type(baseHeight) == "number" then
        finalHeight = baseHeight + reserve
    end
    if type(nativeHeight) == "number" then
        local neededHeight = nativeHeight + barHeight + 2 * ENTITY_TOOLTIP_COVER_PAD
        if type(finalHeight) ~= "number" or finalHeight < neededHeight then
            finalHeight = neededHeight
        end
    end
    if type(finalHeight) == "number" and type(panel.SetHeight) == "function" then
        pcall(panel.SetHeight, panel, finalHeight)
    end

    -- The native bar stays below the opaque replacement. The owned copy is a
    -- child of the panel, so it cannot fade or disappear on a different tick.
    Client.RestoreEntityTooltipStatusBar(panel)
    OwnedTooltip.UpdateHealthBar(panel, ResolveTooltipStatusBar(),
        (finalWidth or 0) - 2 * ENTITY_TOOLTIP_COVER_PAD, barHeight)
    panel.unrealQuestStatusBarHeight = barHeight
    panel.unrealQuestCursorOffsetX = nil
    panel.unrealQuestCursorOffsetY = nil

    if type(panel.ClearAllPoints) == "function" then
        pcall(panel.ClearAllPoints, panel)
    end
    if type(panel.SetPoint) == "function" then
        pcall(panel.SetPoint, panel, "BOTTOMRIGHT", tooltip, "BOTTOMRIGHT",
            ENTITY_TOOLTIP_COVER_PAD, -(ENTITY_TOOLTIP_COVER_PAD + barHeight))
    end

    -- The cover exactly follows the containing panel. The native health bar is
    -- still on the host's anchors, but its raised frame level keeps it visible
    -- over this opaque mask.
    if cover then
        local finalWidth = Client.GetObjectWidth(panel)
        local finalHeight = Client.GetObjectHeight(panel)
        if type(finalWidth) == "number" and type(cover.SetWidth) == "function" then
            pcall(cover.SetWidth, cover, finalWidth)
        end
        if type(finalHeight) == "number" and type(cover.SetHeight) == "function" then
            pcall(cover.SetHeight, cover, finalHeight)
        end
        if type(cover.ClearAllPoints) == "function" then
            pcall(cover.ClearAllPoints, cover)
        end
        if type(cover.SetPoint) == "function" then
            pcall(cover.SetPoint, cover, "BOTTOMRIGHT", tooltip, "BOTTOMRIGHT",
                ENTITY_TOOLTIP_COVER_PAD, -(ENTITY_TOOLTIP_COVER_PAD + barHeight))
        end
        if type(cover.SetFrameStrata) == "function" then
            pcall(cover.SetFrameStrata, cover, "TOOLTIP")
        end
        Client.ShowObject(cover)
    end
    return true
end

-- A compact action picker anchored to a world-map pin. It reuses the proven
-- giver-picker frame, rows and outside-click catcher, but adds neither the
-- giver-specific "mark all" action nor any native dropdown dependency.
-- `entries` is a list of { text = label }; selecting one closes the picker and
-- passes that entry to onSelect.
function Client.ShowMapPinActionMenu(anchorFrame, entries, onSelect)
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
            Client.HideGiverQuestMenu()
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
    LayOutGiverMenuRow(menu, GetGiverMenuRow(total + 1), total + 1,
        UQ.L("COMMON_CLOSE"), 0.5, 0.5, 0.5, function() Client.HideGiverQuestMenu() end)

    local extra = total + 2
    while giverMenuRows[extra] do
        pcall(giverMenuRows[extra].Hide, giverMenuRows[extra])
        extra = extra + 1
    end

    local rowCount = total + 1
    pcall(menu.SetWidth, menu, GIVER_MENU_WIDTH)
    pcall(menu.SetHeight, menu,
        GIVER_MENU_PADDING * 2 + rowCount * GIVER_MENU_ROW_HEIGHT)
    pcall(menu.ClearAllPoints, menu)
    pcall(menu.SetPoint, menu, "TOPLEFT", anchorFrame, "BOTTOMRIGHT", 4, 0)
    Client.ApplyFlatTooltipStyle(menu, nil)
    pcall(menu.Show, menu)
    menu.unrealQuestOpenFor = anchorFrame

    local catcher = ResolveGiverMenuCatcher()
    if catcher and type(catcher.Show) == "function" then
        pcall(catcher.Show, catcher)
    end
    return true
end

-- Shows the combined entity tooltip: the panel is populated, shown, and then
-- placed over the native tooltip without adopting its possibly stale size.
-- There is no second mode.
-- This used to take a replaceNative flag whose false branch anchored the panel
-- below GameTooltip instead of over it, leaving the player looking at two
-- tooltip boxes; that branch is deliberately gone rather than merely unused, so
-- the only thing this function can produce is one box.
function Client.ShowEntityTooltipPanel(panel, lines)
    local tooltip = ResolveGameTooltip()
    local total = table.getn(lines or {})
    if not panel or not tooltip or total == 0 then
        Client.HideObject(panel)
        return false
    end

    -- Rebuild from a hidden state. This client does not contract a visible,
    -- reused GameTooltip-template frame reliably: after a taller entity the
    -- next short tooltip can keep the old width/height and draw a large empty
    -- body. Populating before Show is the already-confirmed route used by the
    -- map tooltips; Hide/Show happen in this one synchronous refresh, so no
    -- intermediate blank frame is rendered.
    Client.HideObject(panel.unrealQuestCover)
    Client.HideObject(panel)

    -- A reused panel comes back from a fade at whatever alpha it stopped at.
    Client.SetEntityTooltipAlpha(panel, 1)
    panel.unrealQuestNativeFadeStartedAt = nil

    -- Measured fresh each hover: the health bar's reserve is added to the row
    -- height of THIS tooltip, never to a previous one that already carried it.
    panel.unrealQuestContentHeight = nil

    if panel.unrealQuestOwnedChrome then
        if not OwnedTooltip.Render(panel, lines) then
            Client.HideObject(panel)
            return false
        end
        Client.ShowObject(panel)
    else
        -- Standalone. The template keeps its stock chrome deliberately: that is
        -- the look an unthemed client is supposed to have.
        if not RenderTooltipLines(panel, panel.unrealQuestTooltipName, tooltip, lines,
                "ANCHOR_NONE", true) then
            Client.HideObject(panel)
            return false
        end
    end
    panel.unrealQuestReplacing = true
    if not Client.CoverNativeEntityTooltip(panel) then
        Client.HideEntityTooltipPanel(panel)
        return false
    end
    return true
end

-- Writes one alpha across the whole owned presentation. Parent alpha does not
-- reliably reach child regions on this client (fonts/regions note in the
-- widget findings), so every piece is written directly rather than trusting
-- propagation from the panel: the panel, its own rows, the cover and the
-- cover's texture. Only addon-owned objects are touched -- GameTooltip and its
-- regions are never written, which is what keeps this safe beside a host that
-- is running its own fade on the same frame.
function Client.SetEntityTooltipAlpha(panel, alpha)
    if not panel or type(alpha) ~= "number" then
        return false
    end
    if alpha < 0 then
        alpha = 0
    elseif alpha > 1 then
        alpha = 1
    end
    if panel.unrealQuestAlpha == alpha then
        return true
    end
    panel.unrealQuestAlpha = alpha

    if type(panel.SetAlpha) == "function" then
        pcall(panel.SetAlpha, panel, alpha)
    end
    SetFlatBorderColor(panel, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3],
        FLAT_BORDER[4] * alpha)
    if panel.unrealQuestOwnedChrome and type(panel.SetBackdropColor) == "function" then
        pcall(panel.SetBackdropColor, panel, FLAT_BACKGROUND[1], FLAT_BACKGROUND[2],
            FLAT_BACKGROUND[3], alpha)
    end

    local pool = panel.unrealQuestRows
    if pool then
        local index = 1
        while pool[index] do
            local row = pool[index]
            if type(row.left.SetAlpha) == "function" then
                pcall(row.left.SetAlpha, row.left, alpha)
            end
            if row.right and type(row.right.SetAlpha) == "function" then
                pcall(row.right.SetAlpha, row.right, alpha)
            end
            index = index + 1
        end
    end

    local cover = panel.unrealQuestCover
    if cover then
        if type(cover.SetAlpha) == "function" then
            pcall(cover.SetAlpha, cover, alpha)
        end
        if cover.unrealQuestTexture then
            Client.SetSolidColor(cover.unrealQuestTexture, 0.025, 0.025, 0.025, alpha)
        end
    end
    local health = panel.unrealQuestHealthBar
    if health and type(health.SetAlpha) == "function" then
        pcall(health.SetAlpha, health, alpha)
    end
    return true
end

-- Once the native cursor tooltip begins fading, unrealUI eventually stops
-- moving both GameTooltip and its cursor guide. Preserve the last exact panel
-- offset from the real cursor, then move the owned presentation directly for
-- the rest of its hold. This produces no jump on the first held frame.
function Client.ContinueEntityTooltipCursorFollow(panel)
    if not panel or Client.IsWorldTooltipCursorFollowEnabled() ~= true then
        return false
    end
    local getCursor = Resolve("GetCursorPosition")
    local parent = ResolveObject("UIParent")
    if not getCursor or not parent or type(parent.GetEffectiveScale) ~= "function"
            or type(parent.GetLeft) ~= "function" or type(parent.GetBottom) ~= "function"
            or type(panel.GetLeft) ~= "function" or type(panel.GetBottom) ~= "function" then
        return false
    end
    local ok, cursorX, cursorY, scale, parentLeft, parentBottom, panelLeft, panelBottom =
        pcall(function()
            local x, y = getCursor()
            return x, y, parent:GetEffectiveScale(), parent:GetLeft(), parent:GetBottom(),
                panel:GetLeft(), panel:GetBottom()
        end)
    if not ok or type(cursorX) ~= "number" or type(cursorY) ~= "number"
            or type(scale) ~= "number" or scale <= 0 or type(parentLeft) ~= "number"
            or type(parentBottom) ~= "number" or type(panelLeft) ~= "number"
            or type(panelBottom) ~= "number" then
        return false
    end
    cursorX = cursorX / scale - parentLeft
    cursorY = cursorY / scale - parentBottom
    if type(panel.unrealQuestCursorOffsetX) ~= "number" then
        panel.unrealQuestCursorOffsetX = panelLeft - cursorX
        panel.unrealQuestCursorOffsetY = panelBottom - cursorY
    end
    pcall(panel.ClearAllPoints, panel)
    pcall(panel.SetPoint, panel, "BOTTOMLEFT", parent, "BOTTOMLEFT",
        cursorX + panel.unrealQuestCursorOffsetX,
        cursorY + panel.unrealQuestCursorOffsetY)
    local cover = panel.unrealQuestCover
    if cover then
        pcall(cover.ClearAllPoints, cover)
        pcall(cover.SetPoint, cover, "BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    end
    return true
end

-- Keeps the replacement fully opaque for the configured runtime delay after
-- native mouse-out, then hides it and its owned health bar in the same tick.
--
-- tooltipdupe v4 measured opacity overlap when the owned cover mirrored the
-- native alpha: the translucent cover exposed the native body fading behind
-- it. The one-box contract therefore follows native VISIBILITY, not native
-- alpha. While the custom timer is running, the panel and cover
-- stay fully opaque. IsShown is not used as the finish line: live confirmation
-- found that it turns false before the final native pixels leave the renderer.
--
-- Cursor-follow world objects that churn between two anchors are declined by
-- EntityTooltip before a replacement is shown. Native position and alpha are
-- never written here, and the native frame is never hidden here.
local function ReleaseEntityTooltipFade(panel)
    local bar = ResolveTooltipStatusBar()
    local barShown = bar and Client.IsObjectShown(bar)
    Client.HideEntityTooltipPanel(panel)
    -- GameTooltipStatusBar is a separate native frame and has been observed
    -- outliving tooltip geometry. Hide it only at the owned fade release; the
    -- client/host shows it normally again on the next unit tooltip.
    if barShown then
        Client.HideObject(bar)
    end
end

function Client.SyncEntityTooltipFade(panel)
    if not panel or not panel.unrealQuestReplacing then
        return false
    end
    if type(panel.IsShown) == "function" then
        local shownOk, shown = pcall(panel.IsShown, panel)
        if not shownOk or not shown then
            return false
        end
    end
    local tooltip = ResolveGameTooltip()
    if not tooltip then
        return false
    end
    local shownOk, shown = pcall(tooltip.IsShown, tooltip)
    local alpha = nil
    if type(tooltip.GetAlpha) == "function" then
        local alphaOk, value = pcall(tooltip.GetAlpha, tooltip)
        if alphaOk and type(value) == "number" then
            alpha = value
        end
    end

    local fading = not shownOk or not shown
        or (type(alpha) == "number" and alpha < 0.999)
    if not fading then
        panel.unrealQuestNativeFadeStartedAt = nil
        return Client.SetEntityTooltipAlpha(panel, 1), false
    end

    Client.ContinueEntityTooltipCursorFollow(panel)

    local now = Client.Now()
    if type(now) ~= "number" then
        -- GetTime is a verified capability, but do not leave a permanent box if
        -- it ever becomes unavailable during teardown.
        if shownOk and shown then
            return Client.SetEntityTooltipAlpha(panel, 1), false
        end
        ReleaseEntityTooltipFade(panel)
        return true, true
    end
    if type(panel.unrealQuestNativeFadeStartedAt) ~= "number" then
        panel.unrealQuestNativeFadeStartedAt = now
    end
    if now - panel.unrealQuestNativeFadeStartedAt >= Client.GetEntityTooltipFadeHold() then
        ReleaseEntityTooltipFade(panel)
        return true, true
    end
    return Client.SetEntityTooltipAlpha(panel, 1), false
end

-- Refresh runs every 0.1s and can observe the native frame as hidden before the
-- per-frame fade hold has expired. Keep that poll from tearing down the owned
-- presentation; SyncEntityTooltipFade remains the sole owner of fade release.
function Client.IsEntityTooltipFadeHolding(panel)
    return panel and panel.unrealQuestReplacing
        and type(panel.unrealQuestNativeFadeStartedAt) == "number"
end

-- A replacement released for a native fade may be shown again for the
-- same subject only after the native frame has returned to full opacity. Kept
-- here, at the client boundary, so the tooltip module never reads GameTooltip
-- directly.
function Client.IsNativeEntityTooltipFullyOpaque()
    local tooltip = ResolveGameTooltip()
    if not tooltip or type(tooltip.IsShown) ~= "function"
            or type(tooltip.GetAlpha) ~= "function" then
        return nil
    end
    local shownOk, shown = pcall(tooltip.IsShown, tooltip)
    if not shownOk or not shown then
        return false
    end
    local alphaOk, alpha = pcall(tooltip.GetAlpha, tooltip)
    if not alphaOk or type(alpha) ~= "number" then
        return nil
    end
    return alpha >= 0.999
end

function Client.HideEntityTooltipPanel(panel)
    if panel then
        Client.HideObject(panel.unrealQuestCover)
        Client.HideObject(panel.unrealQuestHealthBar)
        Client.RestoreEntityTooltipStatusBar(panel)
        panel.unrealQuestReplacing = false
        panel.unrealQuestNativeFadeStartedAt = nil
        panel.unrealQuestCursorOffsetX = nil
        panel.unrealQuestCursorOffsetY = nil
        panel.unrealQuestStatusBarHeight = nil
    end
    return Client.HideObject(panel)
end

function Client.SetSolidColor(texture, red, green, blue, alpha)
    if not texture or type(texture.SetVertexColor) ~= "function" then
        return false
    end
    local ok = pcall(texture.SetVertexColor, texture, red or 1, green or 1, blue or 1,
        alpha == nil and 1 or alpha)
    return ok and true or false
end

-- Applies the player's percentage setting to the tracker background and to
-- every border line drawn in the panel's own chrome colour -- the four outer
-- edges and the rule under the header -- without changing the frame's alpha
-- (which would also dim its text and controls). The lines fade with the
-- background because a fully opaque outline around an invisible panel reads as
-- a stray rectangle drawn on the world.
function Client.SetTrackerBackgroundOpacity(frame, percent)
    if not frame or type(percent) ~= "number" then
        return false
    end
    if percent < 0 then
        percent = 0
    elseif percent > 100 then
        percent = 100
    end
    local scale = percent / 100
    SetFlatBorderColor(frame, FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3],
        FLAT_BORDER[4] * scale)
    Client.SetSolidColor(frame.unrealQuestSeparator,
        FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], FLAT_BORDER[4] * scale)
    if type(Client.SetTrackerFollowingOpacity) == "function" then
        Client.SetTrackerFollowingOpacity(frame, percent)
    end
    return Client.SetSolidColor(frame.unrealQuestBackground,
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], scale)
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

local function CreateSizedButton(parent, name, width, height, text, fontTemplate)
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
            fontTemplate or "GameFontNormalSmall")
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

local function CreateLabelledButton(parent, name, size, text, fontTemplate)
    return CreateSizedButton(parent, name, size, size, text, fontTemplate)
end

-- Public creator for a text button of arbitrary width, e.g. the quest log's
-- Show/Track buttons, which read a whole word rather than a single glyph.
function Client.CreateTextButton(parent, name, width, height, text)
    return CreateSizedButton(parent, name, width, height, text)
end

-- Textured skins for the quest log's action buttons -------------------------
--
-- Red (Show, Track) and gold-rimmed red (Following) art, drawn in place of the
-- flat chrome when unrealUI is absent or hosts its modern-wow theme
-- (Quest/QuestLogButtons.lua decides which). Both atlases are 32-bit RLE
-- type-10 TGAs at fresh extensionless paths, the encoding and path rule of
-- knowledge.json textures.uncompressed_512_tga_atlas_corrupts and
-- textures.resources_cached_across_ui_reload.
--
-- Each button state in an atlas is a 291x125 bar whose RIGHT end carries the
-- bevel, plus a separate 114x125 short button whose LEFT end does, so a button
-- is drawn as three slices -- left cap from the short piece, the bar's middle
-- stretched, the bar's right cap -- selected with the four-argument
-- SetTexCoord form (textures.rle_512_tga_atlas_four_arg_supported). Cap width
-- follows the button's height at the source aspect, so the bevel reads the
-- same at the classic 18 and the modern 30 pixels. Hover swaps to the
-- atlas's recessed row by coordinates alone: Additive blending and
-- Texture:SetAlpha are both unreliable here (rendering.setblendmode_add_inert,
-- rendering.texture_setalpha_darkens_not_translucent). Measured from the
-- shipped files with an alpha > 8 bound; the red atlas is 512x2048, a size
-- no probe has rendered yet.
--
-- One table rather than separate locals: this file sits at Lua's 200
-- file-scope local limit.
local QuestLogSkin = {
    atlasWidth = 512,
    cellHeight = 125,
    barWidth = 291,
    cap = 24,
    skins = {
        red = {
            path = "Interface\\AddOns\\unrealQuest\\media\\128RedButton",
            atlasHeight = 2048,
            normal = { barTop = 523, capLeft = 392, capTop = 913 },
            hover = { barTop = 783, capLeft = 378, capTop = 1043 },
        },
        gold = {
            path = "Interface\\AddOns\\unrealQuest\\media\\128GoldRedButton",
            atlasHeight = 1024,
            normal = { barTop = 523, capLeft = 296, capTop = 523 },
            hover = { barTop = 783, capLeft = 296, capTop = 783 },
        },
    },
}

-- The flat look's border and fill, active (accent) or at rest.
function QuestLogSkin.ApplyFlat(button, active)
    if active then
        SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], 1)
        if type(button.SetBackdropColor) == "function" then
            pcall(button.SetBackdropColor, button, UQ.colors.accent[1],
                UQ.colors.accent[2], UQ.colors.accent[3], 0.10)
        end
    else
        SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2],
            FLAT_BORDER[3], FLAT_BORDER[4])
        if type(button.SetBackdropColor) == "function" then
            pcall(button.SetBackdropColor, button, FLAT_BACKGROUND[1],
                FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], FLAT_BACKGROUND[4])
        end
    end
end

function QuestLogSkin.SetSlice(texture, skin, left, right, top)
    pcall(texture.SetTexCoord, texture,
        left / QuestLogSkin.atlasWidth, right / QuestLogSkin.atlasWidth,
        top / skin.atlasHeight,
        (top + QuestLogSkin.cellHeight) / skin.atlasHeight)
end

function QuestLogSkin.Paint(button, hover)
    local skin = QuestLogSkin.skins[button.unrealQuestSkin or ""]
    local slices = button.unrealQuestSkinSlices
    if not skin or not slices then
        return
    end
    -- Rewrite coordinates only on a real change of state; a repeated
    -- OnEnter/OnLeave must not resample the atlas.
    local wanted = hover and true or false
    if button.unrealQuestSkinPainted == button.unrealQuestSkin
        and button.unrealQuestSkinHover == wanted then
        return
    end
    button.unrealQuestSkinPainted = button.unrealQuestSkin
    button.unrealQuestSkinHover = wanted
    button.unrealQuestDiagPaints = (button.unrealQuestDiagPaints or 0) + 1
    local state = hover and skin.hover or skin.normal
    local cap = QuestLogSkin.cap
    local bar = QuestLogSkin.barWidth
    QuestLogSkin.SetSlice(slices[1], skin, state.capLeft, state.capLeft + cap, state.capTop)
    QuestLogSkin.SetSlice(slices[2], skin, cap, bar - cap, state.barTop)
    QuestLogSkin.SetSlice(slices[3], skin, bar - cap, bar, state.barTop)
end

function QuestLogSkin.BuildSlices(button)
    if type(button.CreateTexture) ~= "function" then
        return nil
    end
    local slices = {}
    local index = 1
    while index <= 3 do
        local ok, texture = pcall(button.CreateTexture, button, nil, "BACKGROUND")
        if not ok or not texture or type(texture.SetTexCoord) ~= "function" then
            return nil
        end
        slices[index] = texture
        index = index + 1
    end
    local left, middle, right = slices[1], slices[2], slices[3]
    pcall(left.SetPoint, left, "TOPLEFT", button, "TOPLEFT", 0, 0)
    pcall(left.SetPoint, left, "BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    pcall(right.SetPoint, right, "TOPRIGHT", button, "TOPRIGHT", 0, 0)
    pcall(right.SetPoint, right, "BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    pcall(middle.SetPoint, middle, "TOPLEFT", left, "TOPRIGHT", 0, 0)
    pcall(middle.SetPoint, middle, "BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)
    button.unrealQuestSkinSlices = slices
    return slices
end

-- skinName is "red", "gold" or nil for the flat look. Idempotent per name and
-- height: the quest log polls this, and repainting every pass would fight the
-- button's own hover state (see Client.SetStyledTextButtonActive). Returns
-- whether the textured skin is on; a button that cannot build its slices stays
-- flat.
function Client.SetQuestLogButtonSkin(button, skinName)
    if not button then
        return false
    end
    local skin = skinName and QuestLogSkin.skins[skinName] or nil
    local height = 0
    if type(button.GetHeight) == "function" then
        local ok, value = pcall(button.GetHeight, button)
        if ok and type(value) == "number" then
            height = value
        end
    end
    local wanted = skin and skinName or nil
    if button.unrealQuestSkin == wanted and button.unrealQuestSkinHeight == height then
        return skin ~= nil
    end

    button.unrealQuestDiagApplies = (button.unrealQuestDiagApplies or 0) + 1
    local slices = button.unrealQuestSkinSlices
    if skin and not slices then
        slices = QuestLogSkin.BuildSlices(button)
    end
    if skin and slices then
        local cap = height * QuestLogSkin.cap / QuestLogSkin.cellHeight
        local index = 1
        while index <= 3 do
            pcall(slices[index].SetTexture, slices[index], skin.path)
            Client.ShowObject(slices[index])
            index = index + 1
        end
        pcall(slices[1].SetWidth, slices[1], cap)
        pcall(slices[3].SetWidth, slices[3], cap)
        -- Vertex alpha, not SetAlpha, is this client's working translucency.
        SetFlatBorderColor(button, 0, 0, 0, 0)
        if type(button.SetBackdropColor) == "function" then
            pcall(button.SetBackdropColor, button, 0, 0, 0, 0)
        end
        button.unrealQuestSkin = wanted
        -- SetTexture just ran, so the coordinates are repainted regardless of
        -- the last hover state recorded.
        button.unrealQuestSkinPainted = nil
        QuestLogSkin.Paint(button, false)
    else
        if slices then
            Client.HideObject(slices[1])
            Client.HideObject(slices[2])
            Client.HideObject(slices[3])
        end
        button.unrealQuestSkin = nil
        QuestLogSkin.ApplyFlat(button, button.unrealQuestActive)
    end
    button.unrealQuestSkinHeight = height
    return button.unrealQuestSkin ~= nil
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
        -- Diagnostic counters only, read by UnrealRuntimeProbe's
        -- questlogbtnflicker capture; never persisted.
        button.unrealQuestDiagEnters = (button.unrealQuestDiagEnters or 0) + 1
        if button.unrealQuestSkin then
            QuestLogSkin.Paint(button, true)
            return
        end
        SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], button.unrealQuestActive and 1
                or UQ.colors.accent[4])
    end)
    Client.SetObjectScript(button, "OnLeave", function()
        button.unrealQuestDiagLeaves = (button.unrealQuestDiagLeaves or 0) + 1
        if button.unrealQuestSkin then
            QuestLogSkin.Paint(button, false)
        elseif button.unrealQuestActive then
            SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
                UQ.colors.accent[3], 1)
        else
            SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2],
                FLAT_BORDER[3], FLAT_BORDER[4])
        end
    end)
    return button
end

-- Persistent gold state used by the modern quest log's Following button. The
-- small authored arrow is used instead of a font glyph so all four interface
-- languages get the same reliable face on this legacy client.
function Client.SetStyledTextButtonActive(button, active)
    if not button then
        return false
    end
    local nextActive = active and true or false
    local nextText = button.unrealQuestActiveText or ""
    button.unrealQuestActive = nextActive

    -- QuestLogButtons polls for correctness. Repainting the same border,
    -- backdrop, label and arrow every pass fights the button's OnEnter state
    -- on this client and reads as a periodic hover blink.
    if button.unrealQuestAppliedActive == nextActive
        and button.unrealQuestAppliedActiveText == nextText then
        return true
    end

    local arrow = button.unrealQuestActiveArrow
    if not arrow and type(button.CreateTexture) == "function" then
        local ok, created = pcall(button.CreateTexture, button, nil, "OVERLAY")
        if ok and created then
            pcall(created.SetTexture, created, TRACKER_FOLLOWING_ARROW_TEXTURE)
            pcall(created.SetPoint, created, "RIGHT", button, "RIGHT", -8, 0)
            pcall(created.SetWidth, created, TRACKER_FOLLOWING_ARROW_WIDTH)
            pcall(created.SetHeight, created, TRACKER_FOLLOWING_ARROW_HEIGHT)
            pcall(created.Hide, created)
            arrow = created
            button.unrealQuestActiveArrow = created
        end
    end

    -- A textured skin (Client.SetQuestLogButtonSkin) owns the border and fill;
    -- only the label and the arrow carry the active state on it.
    if not button.unrealQuestSkin then
        QuestLogSkin.ApplyFlat(button, nextActive)
    end
    if nextActive then
        Client.SetButtonLabel(button,
            nextText, 0.95, 0.78, 0.12)
        Client.ShowObject(arrow)
    else
        local label = button.unrealQuestLabel
        if label and type(label.SetTextColor) == "function" then
            pcall(label.SetTextColor, label, 0.90, 0.90, 0.90, 1.00)
        end
        Client.HideObject(arrow)
    end
    button.unrealQuestAppliedActive = nextActive
    button.unrealQuestAppliedActiveText = nextText
    return true
end

-- The two named panels exist only after unrealUI has built its modern quest
-- log. Classic WoW deliberately leaves the native frame intact and therefore
-- never creates either panel, which keeps this integration out of that path.
function Client.HasModernQuestLog()
    return ResolveObject("UnrealUIQuestLogListPanel") ~= nil
        and ResolveObject("UnrealUIQuestLogDetailPanel") ~= nil
end

-- How far past the list scroll frame the panel has to reach to contain the
-- native scroll bar, measured from the bar rather than assumed. Falls back to
-- uUI's own 26-pixel gutter whenever the bar cannot be measured, which is the
-- answer that keeps it inside; a host with no bar at all gets the bare margin.
local function ResolveModernQuestLogListTail(listScroll)
    local bar = ResolveObject("QuestLogListScrollFrameScrollBar")
    if not bar then
        return MODERN_QUEST_LOG_SCROLLBAR_MARGIN
    end
    local scrollLeft = Client.GetObjectCorner(listScroll)
    local scrollWidth = Client.GetObjectWidth(listScroll)
    local barLeft = Client.GetObjectCorner(bar)
    local barWidth = Client.GetObjectWidth(bar)
    if type(scrollLeft) ~= "number" or type(scrollWidth) ~= "number"
        or type(barLeft) ~= "number" or type(barWidth) ~= "number"
        or scrollWidth <= 0 or barWidth <= 0 then
        return MODERN_QUEST_LOG_LIST_PANEL_TAIL
    end
    local tail = (barLeft + barWidth) - (scrollLeft + scrollWidth)
        + MODERN_QUEST_LOG_SCROLLBAR_MARGIN
    if tail < MODERN_QUEST_LOG_SCROLLBAR_MARGIN then
        tail = MODERN_QUEST_LOG_SCROLLBAR_MARGIN
    end
    if tail > MODERN_QUEST_LOG_LIST_PANEL_TAIL then
        tail = MODERN_QUEST_LOG_LIST_PANEL_TAIL
    end
    return tail
end

-- Tighten only uUI's Modern two-pane surface. The named panels do not exist
-- in Classic WoW or standalone mode, so neither native layout can enter this
-- path. uUI anchors its list panel five pixels before the scroll frame and 26
-- after it; the row ends at the scroll frame's right edge and the followed
-- plaque stops four pixels before that. Keep exactly as much of the panel tail
-- as the scroll bar
-- occupies, move the detail pane left by whatever is reclaimed, and give that
-- width to its viewport and scroll child.
function Client.SetModernQuestLogPanelLayout()
    local listPanel = ResolveObject("UnrealUIQuestLogListPanel")
    local detailPanel = ResolveObject("UnrealUIQuestLogDetailPanel")
    local listScroll = ResolveObject("QuestLogListScrollFrame")
    local detail = ResolveObject("QuestLogDetailScrollFrame")
    local detailChild = ResolveObject("QuestLogDetailScrollChildFrame")
    if not listPanel or not detailPanel or not listScroll or not detail
        or type(listPanel.ClearAllPoints) ~= "function"
        or type(listPanel.SetPoint) ~= "function"
        or type(detail.ClearAllPoints) ~= "function"
        or type(detail.SetPoint) ~= "function"
        or type(detail.GetWidth) ~= "function"
        or type(detail.SetWidth) ~= "function" then
        return false
    end
    if listPanel.unrealQuestCompactListPanel == true then
        return true
    end

    local widthOk, detailWidth = pcall(detail.GetWidth, detail)
    if not widthOk or type(detailWidth) ~= "number" or detailWidth <= 0 then
        return false
    end
    local childWidth = nil
    if detailChild and type(detailChild.GetWidth) == "function"
        and type(detailChild.SetWidth) == "function" then
        local childOk, measured = pcall(detailChild.GetWidth, detailChild)
        if childOk and type(measured) == "number" and measured > 0 then
            childWidth = measured
        end
    end

    local tail = ResolveModernQuestLogListTail(listScroll)
    local reclaimed = MODERN_QUEST_LOG_LIST_PANEL_TAIL - tail

    pcall(listPanel.ClearAllPoints, listPanel)
    local topOk = pcall(listPanel.SetPoint, listPanel,
        "TOPLEFT", listScroll, "TOPLEFT", -5, 5)
    local bottomOk = pcall(listPanel.SetPoint, listPanel,
        "BOTTOMRIGHT", listScroll, "BOTTOMRIGHT", tail, -5)
    pcall(detail.ClearAllPoints, detail)
    local detailOk = pcall(detail.SetPoint, detail,
        "TOPLEFT", listScroll, "TOPRIGHT",
        MODERN_QUEST_LOG_DETAIL_OFFSET_X - reclaimed, 0)
    local widthSet = pcall(detail.SetWidth, detail, detailWidth + reclaimed)
    if childWidth then
        pcall(detailChild.SetWidth, detailChild, childWidth + reclaimed)
    end
    if topOk and bottomOk and detailOk and widthSet then
        listPanel.unrealQuestCompactListPanel = true
        return true
    end
    return false
end

-- Extended native quest log -------------------------------------------------
--
-- Extended QuestLog 3.6.1 (Copyright 2006 Daniel Rehn) established the
-- two-page parchment geometry used here. Only its artwork and layout are
-- retained: native QuestLogTitleButtonTemplate rows, the client's own
-- QuestLog_Update and UnrealQuest's existing presentation modules keep all
-- behavior on the same stock widgets.

-- One table rather than a dozen file-scope locals: this file sits close to
-- Lua's 200-local limit for a main chunk.
local EXTENDED_QUEST_LOG = {
    width = 704,
    height = 512,
    listWidth = 300,
    listHeight = 411,
    listTop = 74,
    rowLeft = 19,
    rowTop = 75,
    -- EQL3's own page budget, kept as an upper bound only: the count actually
    -- installed is measured against the list page by ResolveExtendedQuestLogRows.
    maxRows = 27,
    minRows = 6,
    defaultRowHeight = 16,
    minRowHeight = 8,
    maxRowHeight = 48,
    textureRoot = "Interface\\AddOns\\unrealQuest\\media\\QuestLog\\",
    -- How many rows the left page ended up holding. nil until the one-shot
    -- layout has run.
    rows = nil,
}

-- Read for the capability note; never persisted.
function Client.GetExtendedClassicQuestLogRows()
    return EXTENDED_QUEST_LOG.rows
end

-- nil means unrealUI has not finished publishing its active theme yet. Theme
-- changes are reload-bound there, so once activeThemeStyle exists this answer
-- stays stable for the session.
function Client.GetUnrealUIQuestLogMode()
    if ResolveObject("UnrealUIQuestLogListPanel")
        and ResolveObject("UnrealUIQuestLogDetailPanel") then
        return "modern"
    end

    local host = ResolveObject("UnrealUI")
    if not host or type(host.activeThemeStyle) ~= "string" then
        return nil
    end
    if type(host.ThemeStyleUsesNativeChrome) ~= "function" then
        return "modern"
    end
    local ok, native = pcall(host.ThemeStyleUsesNativeChrome)
    if not ok then
        return nil
    end
    return native and "classic" or "modern"
end

local function SetExtendedQuestLogAnchor(object, point, relative,
    relativePoint, x, y)
    if not object or type(object.ClearAllPoints) ~= "function"
        or type(object.SetPoint) ~= "function" then
        return false
    end
    pcall(object.ClearAllPoints, object)
    return pcall(object.SetPoint, object, point, relative,
        relativePoint, x, y) and true or false
end

local function AttachExtendedQuestLogMoney(frame, label, scrollChild,
    point, relativePoint, x, y)
    if not frame or not label or not scrollChild
        or type(frame.SetParent) ~= "function" then
        return false
    end
    if not pcall(frame.SetParent, frame, scrollChild) then
        return false
    end
    return SetExtendedQuestLogAnchor(frame, point, label, relativePoint,
        x or 0, y or 0)
end

-- The native reward template numbers guaranteed items after the choice items,
-- but starts their two-column layout again below QuestLogItemReceiveText. The
-- money tail therefore follows the left item of the final guaranteed-reward
-- row, not simply the last numbered item (which may be in the right column).
local function ResolveExtendedQuestLogMoneyAnchor(rewardText)
    local choices, rewards = Client.GetQuestLogRewardCounts()
    if rewards > 0 then
        local finalRowReward = rewards
        if math.floor(finalRowReward / 2) * 2 == finalRowReward then
            finalRowReward = finalRowReward - 1
        end
        local itemIndex = choices + finalRowReward
        local itemName = "QuestLogItem" .. tostring(itemIndex)
        local item = ResolveObject(itemName)
        -- The count can lead the visible row pool while native reward details
        -- are rebuilding. Never hang the coin frame from a hidden item: on the
        -- modern surface that takes the coins out with it. With no visible
        -- reward item, the requested stable position is immediately below
        -- "You will receive".
        if item and Client.IsObjectShown(item) then
            return item, itemName
        end
    end
    return rewardText, "QuestLogItemReceiveText"
end

local function ExtendedQuestLogAnchorMatches(object, point, relative,
    relativeName, relativePoint)
    if not object or type(object.GetPoint) ~= "function" then
        return false
    end
    local ok, actualPoint, actualRelative, actualRelativePoint =
        pcall(object.GetPoint, object, 1)
    if not ok or actualPoint ~= point
        or actualRelativePoint ~= relativePoint then
        return false
    end
    if actualRelative == relative then
        return true
    end
    -- MEASURED: this client returns the relative widget's name string rather
    -- than the widget itself. The Y value is inverted too, so deliberately do
    -- not compare offsets here; only ownership of the anchor matters.
    return type(actualRelative) == "string"
        and actualRelative == relativeName
end

local function ExtendedQuestLogParentMatches(object, parent, parentName)
    if not object or type(object.GetParent) ~= "function" then
        return false
    end
    local ok, actualParent = pcall(object.GetParent, object)
    if not ok then
        return false
    end
    if actualParent == parent then
        return true
    end
    return type(actualParent) == "string" and actualParent == parentName
end

local function CreateExtendedQuestLogTexture(parent, name, layer,
    width, height, point, x, y)
    if not parent or type(parent.CreateTexture) ~= "function" then
        return nil
    end
    local ok, texture = pcall(parent.CreateTexture, parent, nil,
        layer or "ARTWORK")
    if not ok or not texture or type(texture.SetTexture) ~= "function" then
        return nil
    end
    if not pcall(texture.SetTexture, texture,
        EXTENDED_QUEST_LOG.textureRoot .. name) then
        return nil
    end
    Client.SetObjectSize(texture, width, height)
    if type(texture.ClearAllPoints) == "function" then
        pcall(texture.ClearAllPoints, texture)
    end
    if type(texture.SetPoint) ~= "function"
        or not pcall(texture.SetPoint, texture, point, parent, point, x, y) then
        return nil
    end
    return texture
end

-- The row pitch is measured, never assumed. EQL3 chained its 27 rows with a
-- one-pixel overlap because a Vanilla QuestLogTitleButtonTemplate row is
-- exactly 16 pixels tall; this client owns its own Quest Log FrameXML, so the
-- template height is read back from the live row instead. QUESTLOG_QUEST_HEIGHT
-- is the second choice because it is what the native QuestLog_Update feeds to
-- FauxScrollFrame_Update as the scroll step, so it is the client's own idea of
-- a row.
local function ResolveExtendedQuestLogRowPitch(firstRow)
    local height = Client.GetObjectHeight(firstRow)
    if type(height) ~= "number"
        or height < EXTENDED_QUEST_LOG.minRowHeight
        or height > EXTENDED_QUEST_LOG.maxRowHeight then
        height = nil
    end
    if not height then
        local ok, stock = pcall(getglobal, "QUESTLOG_QUEST_HEIGHT")
        if ok and type(stock) == "number"
            and stock >= EXTENDED_QUEST_LOG.minRowHeight
            and stock <= EXTENDED_QUEST_LOG.maxRowHeight then
            height = stock
        end
    end
    return height or EXTENDED_QUEST_LOG.defaultRowHeight
end

-- How many rows the left page can hold without the tail spilling past the list
-- pane onto the footer buttons. Everything beyond this count is what the
-- native FauxScrollFrame scrolls: QuestLog_Update reads QUESTS_DISPLAYED for
-- both, so the drawn block and the scroll extent stay the same number.
local function ResolveExtendedQuestLogRows(pitch)
    local available = EXTENDED_QUEST_LOG.listTop
        + EXTENDED_QUEST_LOG.listHeight - EXTENDED_QUEST_LOG.rowTop
    local rows = math.floor(available / pitch)
    if rows > EXTENDED_QUEST_LOG.maxRows then
        rows = EXTENDED_QUEST_LOG.maxRows
    end
    if rows < EXTENDED_QUEST_LOG.minRows then
        rows = EXTENDED_QUEST_LOG.minRows
    end
    return rows
end

-- Returns nil while the native frame set is not available, false after a
-- concrete preparation failure, and true once the one-shot layout is live.
function Client.ApplyExtendedClassicQuestLog()
    local frame = ResolveObject("QuestLogFrame")
    local listScroll = ResolveObject("QuestLogListScrollFrame")
    local detail = ResolveObject("QuestLogDetailScrollFrame")
    local detailChild = ResolveObject("QuestLogDetailScrollChildFrame")
    local firstRow = ResolveObject("QuestLogTitle1")
    local rewardMoney = ResolveObject("QuestLogMoneyFrame")
    local rewardText = ResolveObject("QuestLogItemReceiveText")
    local rewardSpacer = ResolveObject("QuestLogSpacerFrame")
    if not frame or not listScroll or not detail or not detailChild or not firstRow
        or not rewardMoney or not rewardText or not rewardSpacer then
        return nil
    end
    if frame.unrealQuestExtendedClassic ~= nil then
        return frame.unrealQuestExtendedClassic and true or false
    end

    -- One attempt only. A partially created Texture cannot be destroyed on
    -- this client, so retrying would stack another parchment set every poll.
    frame.unrealQuestExtendedClassic = false

    local rewardAnchor = ResolveExtendedQuestLogMoneyAnchor(rewardText)

    local textureSpecs = {
        { "EQL3_TopLeft", "ARTWORK", 256, 256, "TOPLEFT", 0, 0 },
        { "EQL3_TopSwitchOn", "ARTWORK", 128, 256, "TOPLEFT", 256, 0 },
        { "EQL3_TopMiddle", "ARTWORK", 256, 256, "TOPLEFT", 384, 0 },
        { "EQL3_TopRight", "ARTWORK", 64, 256, "TOPLEFT", 640, 0 },
        { "EQL3_BottomLeft", "ARTWORK", 256, 256, "BOTTOMLEFT", 0, 0 },
        { "EQL3_BottomSwitchOn", "ARTWORK", 128, 256, "BOTTOMLEFT", 256, 0 },
        { "EQL3_BottomMiddle", "ARTWORK", 256, 256, "BOTTOMLEFT", 384, 0 },
        { "EQL3_BottomRight", "ARTWORK", 64, 256, "BOTTOMLEFT", 640, 0 },
    }
    local textures = {}
    local textureIndex = 1
    while textureIndex <= table.getn(textureSpecs) do
        local spec = textureSpecs[textureIndex]
        local texture = CreateExtendedQuestLogTexture(frame,
            spec[1], spec[2], spec[3], spec[4], spec[5], spec[6], spec[7])
        if not texture then
            frame.unrealQuestExtendedClassicTextures = textures
            return false
        end
        table.insert(textures, texture)
        textureIndex = textureIndex + 1
    end
    frame.unrealQuestExtendedClassicTextures = textures

    Client.SetObjectSize(frame, EXTENDED_QUEST_LOG.width, EXTENDED_QUEST_LOG.height)
    Client.SetObjectSize(listScroll, EXTENDED_QUEST_LOG.listWidth,
        EXTENDED_QUEST_LOG.listHeight)
    Client.SetObjectSize(detail, 300, 413)
    Client.SetObjectSize(detailChild, 300, 413)
    if not SetExtendedQuestLogAnchor(listScroll, "TOPLEFT", frame,
        "TOPLEFT", 20, -EXTENDED_QUEST_LOG.listTop)
        or not SetExtendedQuestLogAnchor(detail, "TOPLEFT", frame,
            "TOPLEFT", 350, -72)
        -- Keep the money on its own line after the full guaranteed-item block
        -- and make that complete 28-pixel line part of the scroll extent.
        -- Probe questrewardlayout.live_geometry.v1 measured the inline parent
        -- and anchor working, but the native spacer still ended too early: 7
        -- of 12 live money states were clipped by the detail pane.
        or not AttachExtendedQuestLogMoney(rewardMoney, rewardAnchor,
            detailChild, "TOPLEFT", "BOTTOMLEFT", 0, -2)
        or not SetExtendedQuestLogAnchor(rewardSpacer, "TOP", rewardMoney,
            "BOTTOM", 0, 0) then
        return false
    end

    local requiredMoney = ResolveObject("QuestLogRequiredMoneyFrame")
    local requiredText = ResolveObject("QuestLogRequiredMoneyText")
    if requiredMoney and requiredText then
        AttachExtendedQuestLogMoney(requiredMoney, requiredText,
            detailChild, "LEFT", "RIGHT", 10, 0)
    end

    -- WORKING_SOURCE evidence from unrealUI/modules/questlog.lua: this exact
    -- client accepts additional named QuestLogTitleButtonTemplate rows and the
    -- native QuestLog_Update fills them when QUESTS_DISPLAYED is raised.
    --
    -- Each row takes its own offset from the frame instead of being chained
    -- onto the row above it. EQL3 chained its 27 rows with a one-pixel nudge,
    -- which only lands where the row template is Vanilla's 16 pixels and the
    -- client applies that offset upwards; knowledge record
    -- questlog.eql3_chained_rows_leave_the_page is the USER_CONFIRMED_INGAME
    -- report that it does not hold here -- the tail of a long quest list drew
    -- over the footer buttons and off the parchment. An absolute offset per
    -- row cannot accumulate an error, and the count is measured against the
    -- page, so the block ends inside the list pane whatever a row measures.
    local pitch = ResolveExtendedQuestLogRowPitch(firstRow)
    local rows = ResolveExtendedQuestLogRows(pitch)
    local createFrame = Resolve("CreateFrame")
    local rowIndex = 1
    while rowIndex <= rows do
        local name = "QuestLogTitle" .. tostring(rowIndex)
        local row = ResolveObject(name)
        if not row and createFrame then
            local ok, created = pcall(createFrame, "Button", name, frame,
                "QuestLogTitleButtonTemplate")
            if ok then
                row = created
                Client.HideObject(row)
            end
        end
        if not row then
            return false
        end
        if type(row.SetID) == "function" then
            pcall(row.SetID, row, rowIndex)
        end
        if not SetExtendedQuestLogAnchor(row, "TOPLEFT", frame, "TOPLEFT",
            EXTENDED_QUEST_LOG.rowLeft,
            -(EXTENDED_QUEST_LOG.rowTop + (rowIndex - 1) * pitch)) then
            return false
        end
        rowIndex = rowIndex + 1
    end

    -- This is the stock FrameXML row-count global consumed by QuestLog_Update,
    -- not persisted state. The write lives inside the compatibility boundary
    -- with every other client-facing operation. It is also what the native
    -- FauxScrollFrame_Update call inside QuestLog_Update treats as the visible
    -- window, so the scroll bar appears exactly when the log outgrows the page.
    QUESTS_DISPLAYED = rows
    EXTENDED_QUEST_LOG.rows = rows

    local close = ResolveObject("QuestLogFrameCloseButton")
    if close then
        SetExtendedQuestLogAnchor(close, "TOPRIGHT", frame, "TOPRIGHT", -20, -8)
    end

    -- Keep the three stock quest actions in the parchment footer shown by the
    -- EQL3 reference: Abandon at the left, Share and Exit paired at the right.
    -- The 411/413-pixel scroll panes end 27 pixels above the frame bottom, so
    -- this 21-pixel row owns that reserved strip instead of covering quest
    -- rows or reward details.
    local abandon = ResolveObject("QuestLogFrameAbandonButton")
    local push = ResolveObject("QuestFramePushQuestButton")
    local exit = ResolveObject("QuestFrameExitButton")
    if abandon then
        Client.SetObjectSize(abandon, 125, 21)
        SetExtendedQuestLogAnchor(abandon, "BOTTOMLEFT", frame,
            "BOTTOMLEFT", 16, 5)
    end
    if exit then
        Client.SetObjectSize(exit, nil, 21)
        SetExtendedQuestLogAnchor(exit, "BOTTOMRIGHT", frame,
            "BOTTOMRIGHT", -30, 5)
    end
    if push then
        Client.SetObjectSize(push, 123, 21)
        if exit then
            SetExtendedQuestLogAnchor(push, "BOTTOMRIGHT", exit,
                "BOTTOMLEFT", -4, 0)
        else
            SetExtendedQuestLogAnchor(push, "BOTTOMRIGHT", frame,
                "BOTTOMRIGHT", -30, 5)
        end
    end
    local windows = ResolveObject("UIPanelWindows")
    if windows and type(windows.QuestLogFrame) == "table" then
        windows.QuestLogFrame.area = "doublewide"
    end

    frame.unrealQuestExtendedClassic = true
    Client.RefreshQuestLog()
    return true
end

-- The native detail refresh rewrites QuestLogSpacerFrame after every
-- selection, after this extension's one-shot layout has run. The shared-driver
-- observer calls this while the log is open; stable anchors are read-only, and
-- only a native rewrite reasserts the measured reward tail. Never replace or
-- invoke the native refresh.
function Client.RefreshExtendedClassicQuestLogRewards()
    local frame = ResolveObject("QuestLogFrame")
    local detail = ResolveObject("QuestLogDetailScrollFrame")
    local detailChild = ResolveObject("QuestLogDetailScrollChildFrame")
    local rewardText = ResolveObject("QuestLogItemReceiveText")
    local rewardMoney = ResolveObject("QuestLogMoneyFrame")
    local rewardSpacer = ResolveObject("QuestLogSpacerFrame")
    if not frame or frame.unrealQuestExtendedClassic ~= true
        or not detail or not detailChild or not rewardText
        or not rewardMoney or not rewardSpacer
        or not Client.IsObjectShown(frame)
        or not Client.IsObjectShown(rewardText) then
        return false
    end
    -- A frame hidden by Client.SetQuestLogRewardMoney still carries the spacer,
    -- so it keeps being re-placed while the quest has money to report.
    if not Client.IsObjectShown(rewardMoney)
        and not (rewardMoney.unrealQuestMoneyReplaced
            and Client.GetQuestLogMoneyAmounts() > 0) then
        return false
    end
    local rewardAnchor, rewardAnchorName =
        ResolveExtendedQuestLogMoneyAnchor(rewardText)
    if ExtendedQuestLogParentMatches(rewardMoney, detailChild,
            "QuestLogDetailScrollChildFrame")
        and ExtendedQuestLogAnchorMatches(rewardMoney, "TOPLEFT", rewardAnchor,
            rewardAnchorName, "BOTTOMLEFT")
        and ExtendedQuestLogAnchorMatches(rewardSpacer, "TOP", rewardMoney,
            "QuestLogMoneyFrame", "BOTTOM") then
        return true
    end
    if not AttachExtendedQuestLogMoney(rewardMoney, rewardAnchor,
        detailChild, "TOPLEFT", "BOTTOMLEFT", 0, -2)
        or not SetExtendedQuestLogAnchor(rewardSpacer, "TOP", rewardMoney,
            "BOTTOM", 0, 0) then
        return false
    end
    Client.UpdateScrollChildRect(detail)
    return true
end

-- Quest log reward summary ---------------------------------------------------
--
-- Draws UnrealQuest's own reward rows (experience, reputation) at the tail of
-- the native Quest Log detail pane. The client has no API for either value --
-- its Quest surface reports the item and money rewards only -- so the text
-- comes from the bundled world data and this layer owns nothing but placement.
--
-- Placement, and why it is the tail rather than woven into the reward list:
-- the stock reward block is laid out by FrameXML in a fixed order that ends
-- QuestLogRewardTitleText -> QuestLogItemReceiveText -> QuestLogItem<N> ->
-- QuestLogMoneyFrame -> QuestLogSpacerFrame, and every one of those anchors is
-- rewritten on each selection. Inserting a row between two of them would be
-- undone by the next native refresh (and would fight the money/spacer anchors
-- Quest/ExtendedQuestLog.lua re-asserts on its own poll). Anchoring below the
-- last SHOWN member of that chain instead survives the refresh, because the
-- rows are re-placed from the same chain on every poll.
--
-- QuestLogSpacerFrame is deliberately not treated as an obstacle: it carries
-- no texture and exists only to give the scroll child its extent, so these
-- rows may overlap it. UpdateScrollChildRect is called afterwards so they are
-- inside the scrollable area rather than clipped past its bottom.
-- One local, not six: this file's main chunk is close to Lua's 200-local
-- ceiling, and going over it is a load-time failure for the whole addon rather
-- than a warning. The constants and helpers live as fields on this table.
local QuestLogRewardRows = {
    rowHeight = 14,
    maxRows = 6,
    -- Two across, filled left to right, so a quest with an experience reward
    -- and one reputation costs a single line rather than two. The column width
    -- is the detail pane's own 300px split in half less a small gutter; the
    -- second column starts where the reward item grid's right button does.
    columnWidth = 145,
    columns = 2,
    -- Clearance above the first row and below the last. The item buttons carry
    -- their icon right to their own bottom edge, so a 4px gap read as touching
    -- them; 10 clears them without opening a hole in the pane.
    topMargin = 10,
    bottomMargin = 10,
    -- Upper bound on the item buttons walked when measuring where the reward
    -- block ends; the stock chain is QuestRewardItem1..10.
    maxItemButtons = 10,
    -- Extra clearance when the block ends on an item BUTTON rather than on the
    -- coin row or a label. GetBottom reports the button's own frame edge, and
    -- this client draws the button's plate and its name text past it, so the
    -- measured bottom still left the first row sitting in the reward (user
    -- confirmed in game). Measured clearance would need a probe of the drawn
    -- plate's extent, which nothing here exposes; 15px is the confirmed gap
    -- and is applied only to the case that needed it.
    itemClearance = 15,
}

-- The same rows on all three places a quest states its rewards: the Quest Log,
-- the quest-giver's offer ("Accept"), and its completion window ("Complete
-- Quest"). One layout, three sets of widget names.
--
-- The giver panels do NOT reuse the generic quest globals. Knowledge record
-- quest_dialog.detail_reward_text_globals (USER_CONFIRMED_INGAME,
-- BEHAVIOR_VERIFIED, 2026-08-20) established on this exact client that the
-- visible strings are the Detail- and Reward-prefixed names below, and that
-- QuestItemReceiveText and friends never reach them. The item-button and money
-- names are NOT covered by that record: every one is resolved by name and
-- simply falls through when absent, so a name this client does not carry costs
-- the rows their ideal anchor rather than misplacing them.
QuestLogRewardRows.surfaces = {
    log = {
        dock = "QuestLogDetailScrollChildFrame",
        scroll = "QuestLogDetailScrollFrame",
        money = "QuestLogMoneyFrame",
        -- The addon's own coin line that replaces the native money frame on
        -- this surface; see Client.SetQuestLogRewardMoney.
        moneyRow = "UnrealQuestLogRewardMoney",
        item = "QuestLogItem",
        counts = "log",
        prefix = "UnrealQuestLogReward",
        -- Only reached by a quest that hands over no items at all.
        headings = {
            "QuestLogItemReceiveText",
            "QuestLogItemChooseText",
            "QuestLogRewardTitleText",
        },
    },
    detail = {
        dock = "QuestDetailScrollChildFrame",
        scroll = "QuestDetailScrollFrame",
        money = "QuestDetailMoneyFrame",
        item = "QuestDetailItem",
        counts = "giver",
        prefix = "UnrealQuestDetailReward",
        headings = {
            "QuestDetailItemReceiveText",
            "QuestDetailItemChooseText",
            "QuestDetailRewardTitleText",
        },
    },
    complete = {
        dock = "QuestRewardScrollChildFrame",
        scroll = "QuestRewardScrollFrame",
        money = "QuestRewardMoneyFrame",
        item = "QuestRewardItem",
        counts = "giver",
        prefix = "UnrealQuestCompleteReward",
        headings = {
            "QuestRewardItemReceiveText",
            "QuestRewardItemChooseText",
            "QuestRewardRewardTitleText",
        },
    },
}

-- The item buttons are laid out two to a row, so the block's bottom edge is
-- the LEFT button of the final row -- index minus one when the count is even.
-- This is the same arithmetic ResolveExtendedQuestLogMoneyAnchor above uses to
-- put the coin row under the items, for the same reason.
function QuestLogRewardRows.FinalRowItem(count, offset)
    if count <= 0 then
        return nil
    end
    local index = count
    if math.floor(index / 2) * 2 == index then
        index = index - 1
    end
    return index + offset
end

-- The bottom of the reward block, not its heading.
--
-- Anchoring to QuestLogItemReceiveText is what a first version did, and it is
-- wrong whenever the quest hands over an item: that FontString is the "You
-- will receive:" LABEL, which sits ABOVE the item buttons, so the rows landed
-- on top of the item icon (user confirmed in game 2026-09-09). The money frame
-- is already placed under the items by FrameXML, so it is preferred when it is
-- up; with no money the last item button is used directly, and only a quest
-- with no items at all falls back to one of the headings.
-- The reward widget that sits LOWEST on screen, measured with GetBottom.
--
-- Preferring the money frame and trusting FrameXML's stacking order is what
-- the first version did, and this client does not stack it that way: on the
-- quest-giver's offer window the coin row is drawn beside "You will receive:"
-- ABOVE the item buttons, so anchoring to it put the rows back on top of the
-- reward icon -- the very thing anchoring away from the heading was meant to
-- stop (user confirmed in game, "The Prodigal Lich Returns"). Which widget
-- ends the block is a layout question, so it is answered by measuring the
-- layout rather than by assuming an order that differs per surface and per
-- client.
--
-- Every shown member of the block is a candidate: the money frame and each
-- item button, choices and guaranteed rewards alike. GetBottom is documented
-- on Region by this client (OFFICIAL_CLIENT_DOCUMENTATION) and all candidates
-- are siblings inside the same scroll child, so the comparison stays in one
-- coordinate space. Nil-tolerant throughout: a candidate that cannot be
-- measured is skipped, and if none can be, the caller falls back to the
-- assumed chain rather than to nothing.
function QuestLogRewardRows.LowestRewardWidget(surface)
    local candidates = {}
    local isItemButton = {}
    local money = ResolveObject(surface.money)
    if money and Client.IsObjectShown(money) then
        table.insert(candidates, money)
        table.insert(isItemButton, false)
    end
    local moneyRow = surface.moneyRow and ResolveObject(surface.moneyRow)
    if moneyRow and Client.IsObjectShown(moneyRow) then
        table.insert(candidates, moneyRow)
        table.insert(isItemButton, false)
    end

    local choices, rewards
    if surface.counts == "giver" then
        choices, rewards = Client.GetQuestGiverRewardCounts()
    else
        choices, rewards = Client.GetQuestLogRewardCounts()
    end
    local total = choices + rewards
    if total > QuestLogRewardRows.maxItemButtons then
        total = QuestLogRewardRows.maxItemButtons
    end
    local index = 1
    while index <= total do
        local item = ResolveObject(surface.item .. tostring(index))
        if item and Client.IsObjectShown(item) then
            table.insert(candidates, item)
            table.insert(isItemButton, true)
        end
        index = index + 1
    end

    local lowest = nil
    local lowestBottom = nil
    local lowestIsItem = false
    index = 1
    while index <= table.getn(candidates) do
        local candidate = candidates[index]
        local bottom = ReadObjectMethod(candidate, "GetBottom")
        if type(bottom) == "number"
            and (lowestBottom == nil or bottom < lowestBottom) then
            lowest = candidate
            lowestBottom = bottom
            lowestIsItem = isItemButton[index]
        end
        index = index + 1
    end
    return lowest, lowestIsItem
end

-- Returns the widget the rows hang from, plus whether it is an item BUTTON --
-- which the caller pays extra clearance for, see itemClearance above.
function QuestLogRewardRows.Anchor(surface)
    local lowest, lowestIsItem = QuestLogRewardRows.LowestRewardWidget(surface)
    if lowest then
        return lowest, lowestIsItem
    end

    local money = ResolveObject(surface.money)
    if money and Client.IsObjectShown(money) then
        return money, false
    end

    local choices, rewards
    if surface.counts == "giver" then
        choices, rewards = Client.GetQuestGiverRewardCounts()
    else
        choices, rewards = Client.GetQuestLogRewardCounts()
    end
    -- Guaranteed rewards start their own row block after the choice buttons,
    -- so their final row is measured within the reward count and then shifted
    -- past the choices; with no guaranteed reward the choice grid is the last
    -- thing on screen and is measured on its own.
    local itemIndex = QuestLogRewardRows.FinalRowItem(rewards, choices)
        or QuestLogRewardRows.FinalRowItem(choices, 0)
    if itemIndex then
        local item = ResolveObject(surface.item .. tostring(itemIndex))
        if item and Client.IsObjectShown(item) then
            return item, true
        end
    end

    local moneyRow = surface.moneyRow and ResolveObject(surface.moneyRow)
    if moneyRow and Client.IsObjectShown(moneyRow) then
        return moneyRow, false
    end

    local index = 1
    while index <= table.getn(surface.headings) do
        local object = ResolveObject(surface.headings[index])
        if object and Client.IsObjectShown(object) then
            return object
        end
        index = index + 1
    end
    return nil
end

function QuestLogRewardRows.Ensure(surface, dock, index)
    local rows = dock.unrealQuestRewardRows
    if not rows then
        rows = {}
        dock.unrealQuestRewardRows = rows
    end
    if rows[index] then
        return rows[index]
    end
    local created = QuestLogRewardRows.CreateRow(dock,
        surface.prefix .. tostring(index))
    rows[index] = created
    return created
end

function QuestLogRewardRows.CreateRow(dock, name)
    if type(dock.CreateFontString) ~= "function" then
        return nil
    end
    -- A stock font OBJECT through CreateFontString's inherits argument; this
    -- addon never sets a font by path.
    local ok, created = pcall(dock.CreateFontString, dock,
        name, "OVERLAY", "GameFontNormalSmall")
    if not ok or not created then
        return nil
    end
    -- A dark drop shadow so the experience and reputation lines read on both
    -- parchment and dark page art. unrealUI's U.SetTextShadow recipe on this
    -- client: colour first, retried without alpha for a client that refuses
    -- the fourth argument (FontString:SetShadowColor is documented as r, g, b),
    -- then a one-pixel offset.
    if type(created.SetShadowColor) == "function"
        and not pcall(created.SetShadowColor, created, 0, 0, 0, 1) then
        pcall(created.SetShadowColor, created, 0, 0, 0)
    end
    if type(created.SetShadowOffset) == "function" then
        pcall(created.SetShadowOffset, created, 1, -1)
    end
    if type(created.SetJustifyH) == "function" then
        pcall(created.SetJustifyH, created, "LEFT")
    end
    return created
end

-- The X the reward block's own TEXT starts at.
--
-- Not the scroll child's left edge: FrameXML indents "You will receive:" (and
-- "Rewards" above it) from the pane by a few pixels, so squaring the rows with
-- the pane instead of with that label left them a visible step to its left
-- (user confirmed in game 2026-09-09). The headings are tried in the same
-- order the anchor chain falls back through, so the rows line up with the
-- nearest label actually on screen.
--
-- Reading GetLeft off a FontString is sound here: this client documents it on
-- Region (OFFICIAL_CLIENT_DOCUMENTATION) and a FontString is a LayeredRegion.
-- It is DOCUMENTED, not probed, hence the nil-tolerant fallbacks. The widgets
-- compared are always siblings inside the same scroll child, which also
-- sidesteps the mixed coordinate spaces a scaled frame reports (knowledge
-- record frames.scaled_frame_edge_coordinates_mixed_space).
function QuestLogRewardRows.TextLeft(surface, dock)
    local index = 1
    while index <= table.getn(surface.headings) do
        local object = ResolveObject(surface.headings[index])
        if object and Client.IsObjectShown(object) then
            local left = ReadObjectMethod(object, "GetLeft")
            if type(left) == "number" then
                return left
            end
        end
        index = index + 1
    end
    return ReadObjectMethod(dock, "GetLeft")
end

-- How far LEFT of the anchor that text column starts.
--
-- The anchor is whatever ends the reward block, and that widget is usually
-- INDENTED further still: QuestLogMoneyFrame begins at the coin, and an item
-- button at its icon, both well right of the label. Anchoring straight to its
-- BOTTOMLEFT started the rows under the coin and pushed the second column off
-- the pane.
--
-- Only the Y comes from the anchor; the X is corrected back to the label.
-- GetLeft is the same live-geometry reader the tracker's resize grip is
-- measured with (chat.chatframe1_resize.v1), so it is used here rather than
-- assumed offsets -- and when it cannot answer for either widget the
-- correction is simply zero, which leaves the rows on the anchor rather than
-- somewhere invented.
function QuestLogRewardRows.LeftCorrection(surface, dock, anchor)
    local textLeft = QuestLogRewardRows.TextLeft(surface, dock)
    local anchorLeft = ReadObjectMethod(anchor, "GetLeft")
    if type(textLeft) ~= "number" or type(anchorLeft) ~= "number" then
        return 0
    end
    return textLeft - anchorLeft
end

-- The bottom margin has to be a real widget, not just an offset: the rows are
-- the last thing in the detail pane, and a FontString's own extent is where
-- the scroll child stops. An empty frame of the margin's height below the last
-- row is what puts that gap inside UpdateScrollChildRect's measurement, so the
-- final line is not flush against the bottom of the scrollable area.
function QuestLogRewardRows.Spacer(surface, dock, lastRow)
    local spacer = dock.unrealQuestRewardSpacer
    if not spacer then
        local createFrame = Resolve("CreateFrame")
        if not createFrame then
            return nil
        end
        local ok, created = pcall(createFrame, "Frame",
            surface.prefix .. "Spacer", dock)
        if not ok or not created then
            return nil
        end
        spacer = created
        dock.unrealQuestRewardSpacer = created
    end
    Client.SetObjectSize(spacer, 1, QuestLogRewardRows.bottomMargin)
    if type(spacer.SetPoint) == "function" then
        pcall(spacer.ClearAllPoints, spacer)
        pcall(spacer.SetPoint, spacer, "TOPLEFT", lastRow, "BOTTOMLEFT", 0, 0)
    end
    return spacer
end

-- Choice and guaranteed reward counts for the OPEN QUEST-GIVER window. Both
-- calls are in this client's own API reference (category Quest,
-- DOCUMENTED_NOT_RUNTIME_VERIFIED) and are documented to read the complete
-- window when it is showing and the detail window otherwise -- which is
-- exactly the two surfaces the reward rows are drawn on, so no separate
-- "which window" question has to be asked.
function Client.GetQuestGiverRewardCounts()
    local choices = 0
    local rewards = 0
    local ok, value = Call0("GetNumQuestChoices")
    if ok and type(value) == "number" and value > 0 then
        choices = value
    end
    ok, value = Call0("GetNumQuestRewards")
    if ok and type(value) == "number" and value > 0 then
        rewards = value
    end
    return choices, rewards
end

-- The title of the quest the giver window is currently showing.
--
-- GetTitleText() is in the client API reference (category Quest,
-- DOCUMENTED_NOT_RUNTIME_VERIFIED) as "title last received from a quest-giver
-- packet (detail, progress, or complete)". It is the ONLY join available on
-- these two panels: an offered quest is not in the quest log yet, so there is
-- no log index to read and, as everywhere else here, no quest ID API at all.
function Client.GetQuestGiverTitle()
    local ok, value = Call0("GetTitleText")
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- The two body texts of the quest the giver window is currently showing.
--
-- GetTitleText above is not a unique join: four Tirisfal quests are all called
-- "At War With The Scarlet Crusade", and an offered quest has no log index to
-- break the tie with. These are the only other live signals the giver panels
-- expose, and both are in this client's own API reference (category Quest,
-- DOCUMENTED_NOT_RUNTIME_VERIFIED): GetQuestText() as "story text from the open
-- quest-detail window" and GetObjectiveText() as "objectives blurb from the
-- open quest-detail window". Both are documented to return an empty string
-- when there is none, which is normalised to nil here, so a surface that does
-- not carry one -- the completion window is expected not to carry the story
-- text the database recorded -- costs the caller that pass rather than
-- producing a wrong string.
function Client.GetQuestGiverDescription()
    local ok, value = Call0("GetQuestText")
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

function Client.GetQuestGiverObjective()
    local ok, value = Call0("GetObjectiveText")
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- Completion paragraph from the open turn-in window. Runtime probe
-- questgivertextcomplete (2026-09-10) verified both that GetRewardText returns
-- the visible QuestRewardText paragraph and that GetQuestText/GetObjectiveText
-- are empty on this surface.
function Client.GetQuestCompletionText()
    local ok, value = Call0("GetRewardText")
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- The quest log surface. Kept as its own entry point because it is what the
-- log module and its tests already call.
function Client.SetQuestLogRewardSummary(lines)
    return Client.SetQuestRewardSummary("log", lines)
end

-- Quest log reward money ------------------------------------------------------
--
-- The native QuestLogMoneyFrame is replaced on the Quest Log by the addon's own
-- coin row, placed directly under "You will receive:". The native frame kept
-- misbehaving once it was reparented into the extended/modern detail pane
-- (user report 2026-09-13).
--
-- The row copies unrealUI's status overlay coins by request: per denomination
-- a number followed by a 12px coin, sized to the rendered number, 1px apart.
-- The coin is a slice of the shared Interface\MoneyFrame\UI-MoneyIcons atlas,
-- the path knowledge record textures.separate_coin_paths_not_rendered
-- (USER_CONFIRMED_INGAME) found rendering where the three separate
-- UI-GoldIcon/SilverIcon/CopperIcon paths stay blank. A zero denomination is
-- left out, as the native money frame does.
--
-- The native frame is hidden AND held at alpha 0: FrameXML shows it again on
-- every selection, and the alpha keeps that one poll interval invisible
-- instead of flashing the coins back. It stays parented and anchored where the
-- extended/modern layout puts it, because QuestLogSpacerFrame still hangs off
-- it for the scroll extent.
--
-- The guaranteed reward items start directly under the same label, so the
-- first of them is moved under the coin line. Only an item still anchored to
-- the label (or already to the coin line) is touched; the native refresh puts
-- it back on the next selection and the next poll repeats the move. GetPoint
-- reports the relative widget by NAME and inverts Y here (see
-- ExtendedQuestLogAnchorMatches), so only the name and X are read back.
QuestLogRewardRows.moneyLabel = "QuestLogItemReceiveText"
QuestLogRewardRows.moneyGap = 2
QuestLogRewardRows.moneyItemGap = 5
QuestLogRewardRows.coinTexture = "Interface\\MoneyFrame\\UI-MoneyIcons"
QuestLogRewardRows.coinHeight = 14
QuestLogRewardRows.coinIconSize = 12
QuestLogRewardRows.coinGap = 1
-- The numbers are full white on every denomination, by request; the coin art
-- alone says which is which.
QuestLogRewardRows.coins = {
    { copper = 10000, left = 0.00, right = 0.25, r = 1, g = 1, b = 1 },
    { copper = 100, left = 0.25, right = 0.50, r = 1, g = 1, b = 1 },
    { copper = 1, left = 0.50, right = 0.75, r = 1, g = 1, b = 1 },
}

-- No drop shadow on the coin numbers, by request, whatever unrealUI theme is
-- hosting the log. Zeroing the shadow on a FontString that inherits
-- GameFontNormalSmall is not proven to show on this client (knowledge record
-- chat.shadow_private_font_matrix_v2: "shadow mutation is not visually
-- demonstrated"). What is verified is binding a PRIVATE Font set from a stock
-- path at the text's own size (chat.native_private_font_removes_shadow,
-- BEHAVIOR_VERIFIED + USER_CONFIRMED_INGAME), with the text colour set again
-- afterwards -- a fresh Font has no reliable colour, which is the failed
-- approach that record lists. Only stock Fonts\ paths load here
-- (fonts.setfont_silent_failure), so the label's own inherited face is reused
-- when it reads back as one, else the stock FRIZQT face. One Font per label so
-- a colour on one cannot leak to another. The instance shadow is zeroed too,
-- as a harmless second line of defence if the Font route is refused.
QuestLogRewardRows.coinFontFallback = "Fonts\\FRIZQT__.TTF"
QuestLogRewardRows.coinFontSize = 10

function QuestLogRewardRows.BindShadowFreeFont(label, index)
    if type(label.SetShadowOffset) == "function" then
        pcall(label.SetShadowOffset, label, 0, 0)
    end
    if type(label.SetShadowColor) == "function"
        and not pcall(label.SetShadowColor, label, 0, 0, 0, 0) then
        pcall(label.SetShadowColor, label, 0, 0, 0)
    end

    local createFont = Resolve("CreateFont")
    if not createFont or type(label.SetFontObject) ~= "function" then
        return false
    end
    local path = QuestLogRewardRows.coinFontFallback
    local size = QuestLogRewardRows.coinFontSize
    if type(label.GetFont) == "function" then
        local ok, currentPath, currentSize = pcall(label.GetFont, label)
        if ok and type(currentPath) == "string"
            and string.find(string.lower(currentPath), "^fonts[\\/]") then
            path = currentPath
        end
        if ok and type(currentSize) == "number" and currentSize > 0 then
            size = currentSize
        end
    end
    local fontName = "UnrealQuestCoinFont" .. tostring(index)
    local font = ResolveObject(fontName)
    if not font then
        local ok, created = pcall(createFont, fontName)
        if not ok or not created then
            return false
        end
        font = created
    end
    if type(font.SetFont) ~= "function"
        or not pcall(font.SetFont, font, path, size) then
        return false
    end
    return pcall(label.SetFontObject, label, font) and true or false
end

-- A holder frame per denomination: the coin at its right edge, raised 2px
-- because the art sits low in its atlas slice, and the number right-aligned
-- against the coin and lowered back onto the text baseline.
function QuestLogRewardRows.CreateMoneyRow(dock, name)
    local createFrame = Resolve("CreateFrame")
    if not createFrame then
        return nil
    end
    local ok, row = pcall(createFrame, "Frame", name, dock)
    if not ok or not row then
        return nil
    end
    Client.SetObjectSize(row, 1, QuestLogRewardRows.coinHeight)
    row.unrealQuestCoins = {}
    local index = 1
    while index <= table.getn(QuestLogRewardRows.coins) do
        local spec = QuestLogRewardRows.coins[index]
        local holderOk, holder = pcall(createFrame, "Frame", nil, row)
        if not holderOk or not holder
            or type(holder.CreateTexture) ~= "function"
            or type(holder.CreateFontString) ~= "function" then
            return nil
        end
        Client.SetObjectSize(holder, 26, QuestLogRewardRows.coinHeight)
        local iconOk, icon = pcall(holder.CreateTexture, holder, nil, "OVERLAY")
        if iconOk and icon then
            Client.SetObjectSize(icon, QuestLogRewardRows.coinIconSize,
                QuestLogRewardRows.coinIconSize)
            pcall(icon.SetPoint, icon, "RIGHT", holder, "RIGHT", 0, 2)
            pcall(icon.SetTexture, icon, QuestLogRewardRows.coinTexture)
            pcall(icon.SetTexCoord, icon, spec.left, spec.right, 0, 1)
        end
        local labelOk, label = pcall(holder.CreateFontString, holder, nil,
            "OVERLAY", "GameFontNormalSmall")
        if not labelOk or not label then
            return nil
        end
        if iconOk and icon then
            pcall(label.SetPoint, label, "RIGHT", icon, "LEFT", -1, -2)
        else
            pcall(label.SetPoint, label, "RIGHT", holder, "RIGHT", 0, 0)
        end
        QuestLogRewardRows.BindShadowFreeFont(label, index)
        pcall(label.SetTextColor, label, spec.r, spec.g, spec.b)
        holder.label = label
        row.unrealQuestCoins[index] = holder
        index = index + 1
    end
    return row
end

-- Lays the denominations out left to right for `copper`. Returns whether any
-- widget moved, so the caller can skip the scroll-range update otherwise.
function QuestLogRewardRows.LayoutMoneyRow(row, copper)
    if row.unrealQuestMoneyCopper == copper then
        return false
    end
    row.unrealQuestMoneyCopper = copper
    local x = 0
    local index = 1
    while index <= table.getn(QuestLogRewardRows.coins) do
        local spec = QuestLogRewardRows.coins[index]
        local holder = row.unrealQuestCoins[index]
        local amount = math.floor(copper / spec.copper)
        copper = copper - amount * spec.copper
        if amount > 0 then
            local text = tostring(amount)
            pcall(holder.label.SetText, holder.label, text)
            local width = ReadObjectMethod(holder.label, "GetStringWidth")
            if type(width) ~= "number" or width <= 0 then
                width = string.len(text) * 7
            end
            width = math.ceil(width) + 1 + QuestLogRewardRows.coinIconSize
            Client.SetObjectSize(holder, width, QuestLogRewardRows.coinHeight)
            SetExtendedQuestLogAnchor(holder, "TOPLEFT", row, "TOPLEFT", x, 0)
            Client.ShowObject(holder)
            x = x + width + QuestLogRewardRows.coinGap
        else
            Client.HideObject(holder)
        end
        index = index + 1
    end
    Client.SetObjectSize(row, x > 0 and x or 1, QuestLogRewardRows.coinHeight)
    return true
end

function QuestLogRewardRows.PlaceMoneyItems(label, row, below)
    local choices, rewards = Client.GetQuestLogRewardCounts()
    if rewards <= 0 then
        return false
    end
    local item = ResolveObject("QuestLogItem" .. tostring(choices + 1))
    if not item or type(item.GetPoint) ~= "function" then
        return false
    end
    local ok, point, relative, relativePoint, x = pcall(item.GetPoint, item, 1)
    if not ok then
        return false
    end
    local relativeName = relative
    if type(relative) ~= "string" then
        relativeName = Client.GetObjectName(relative)
    end
    local rowName = QuestLogRewardRows.surfaces.log.moneyRow
    local target, targetName = label, QuestLogRewardRows.moneyLabel
    if below then
        target, targetName = row, rowName
    end
    if relativeName == targetName
        or (relativeName ~= rowName
            and relativeName ~= QuestLogRewardRows.moneyLabel) then
        return false
    end
    return SetExtendedQuestLogAnchor(item, point or "TOPLEFT", target,
        relativePoint or "BOTTOMLEFT", type(x) == "number" and x or 0,
        -QuestLogRewardRows.moneyItemGap)
end

-- replace=false hands the native frame back untouched; replace=true hides it
-- and draws `copper` (nil or 0 hides the row: no money on this quest).
function Client.SetQuestLogRewardMoney(replace, copper)
    local native = ResolveObject("QuestLogMoneyFrame")
    if native then
        if replace then
            native.unrealQuestMoneyReplaced = true
            if native.unrealQuestMoneyAlpha ~= 0
                and type(native.SetAlpha) == "function"
                and pcall(native.SetAlpha, native, 0) then
                native.unrealQuestMoneyAlpha = 0
            end
            if Client.IsObjectShown(native) then
                Client.HideObject(native)
            end
        elseif native.unrealQuestMoneyReplaced then
            native.unrealQuestMoneyReplaced = nil
            native.unrealQuestMoneyAlpha = nil
            if type(native.SetAlpha) == "function" then
                pcall(native.SetAlpha, native, 1)
            end
            if Client.GetQuestLogMoneyAmounts() > 0 then
                Client.ShowObject(native)
            end
        end
    end

    local dock = ResolveObject("QuestLogDetailScrollChildFrame")
    local label = ResolveObject(QuestLogRewardRows.moneyLabel)
    if not dock or not label then
        return false
    end
    local row = dock.unrealQuestMoneyRow
    local changed = false
    local wanted = replace and type(copper) == "number" and copper > 0
        and Client.IsObjectShown(dock) and Client.IsObjectShown(label)
    if not wanted then
        if row and Client.IsObjectShown(row) then
            Client.HideObject(row)
            QuestLogRewardRows.PlaceMoneyItems(label, row, false)
            Client.UpdateScrollChildRect(ResolveObject("QuestLogDetailScrollFrame"))
        end
        return false
    end

    if row == nil then
        -- Created once and kept even if a holder failed: a half-built frame
        -- cannot be destroyed here, so retrying would stack another each poll.
        row = QuestLogRewardRows.CreateMoneyRow(dock,
            QuestLogRewardRows.surfaces.log.moneyRow)
        dock.unrealQuestMoneyRow = row or false
    end
    if not row then
        return false
    end
    -- Above modern-wow's page art, like the native frame it replaces.
    QuestLogRewardRows.RaiseMoneyFrame(row, dock)
    if QuestLogRewardRows.LayoutMoneyRow(row, copper) then
        changed = true
    end
    if not ExtendedQuestLogAnchorMatches(row, "TOPLEFT", label,
        QuestLogRewardRows.moneyLabel, "BOTTOMLEFT") then
        SetExtendedQuestLogAnchor(row, "TOPLEFT", label, "BOTTOMLEFT",
            0, -QuestLogRewardRows.moneyGap)
        changed = true
    end
    if not Client.IsObjectShown(row) then
        Client.ShowObject(row)
        changed = true
    end
    if QuestLogRewardRows.PlaceMoneyItems(label, row, true) then
        changed = true
    end
    -- Only on a real change: re-laying the scroll child every poll is what
    -- made the detail pane flicker (questlogbuttons.scroll_flicker_bisect.v1).
    if changed then
        Client.UpdateScrollChildRect(ResolveObject("QuestLogDetailScrollFrame"))
    end
    return true
end

function Client.SetQuestRewardSummary(surfaceName, lines)
    local surface = QuestLogRewardRows.surfaces[surfaceName]
    if not surface then
        return false
    end
    local dock = ResolveObject(surface.dock)
    if not dock then
        return false
    end
    -- A panel that is not on screen gets its rows cleared rather than laid
    -- out: the giver's offer and completion windows share one frame and swap,
    -- so the hidden one must not keep a stale line.
    if not Client.IsObjectShown(dock) then
        lines = nil
    end
    local count = 0
    if type(lines) == "table" then
        count = table.getn(lines)
    end
    if count > QuestLogRewardRows.maxRows then
        count = QuestLogRewardRows.maxRows
    end

    local anchor, anchorIsItem = nil, false
    if count > 0 then
        anchor, anchorIsItem = QuestLogRewardRows.Anchor(surface)
    end
    -- An item button's drawn plate and name reach below the frame edge
    -- GetBottom reports, so that case buys itself extra room.
    local topMargin = QuestLogRewardRows.topMargin
    if anchorIsItem then
        topMargin = topMargin + QuestLogRewardRows.itemClearance
    end
    local leftCorrection = anchor
        and QuestLogRewardRows.LeftCorrection(surface, dock, anchor) or 0

    -- Lay out only on a change. This runs on a 0.3s poll, and re-anchoring the
    -- rows and the spacer plus UpdateScrollChildRect on every pass made the
    -- client draw every region in the scrolled detail pane at its UNSCROLLED
    -- position for one frame per poll -- the quest log buttons' flicker.
    -- Bisected in game: pausing this job alone stopped it
    -- (questlogbuttons.scroll_flicker_bisect.v1). Anchored rows still follow
    -- their anchor when the native layout moves it; only a new anchor, offset,
    -- text or colour needs this pass.
    local keyParts = { tostring(count), tostring(anchor),
        tostring(math.floor(leftCorrection * 2 + 0.5)), tostring(topMargin) }
    local keyIndex = 1
    while keyIndex <= count do
        local line = lines[keyIndex]
        if type(line) == "table" then
            table.insert(keyParts, tostring(line.text) .. ":" .. tostring(line.r)
                .. ":" .. tostring(line.g) .. ":" .. tostring(line.b))
        end
        keyIndex = keyIndex + 1
    end
    local layoutKey = table.concat(keyParts, "|")
    if dock.unrealQuestRewardLayoutKey == layoutKey then
        return count > 0 and anchor ~= nil
    end
    dock.unrealQuestRewardLayoutKey = layoutKey

    local lastRow = nil
    local index = 1
    while index <= QuestLogRewardRows.maxRows do
        local row = dock.unrealQuestRewardRows and dock.unrealQuestRewardRows[index]
        if index <= count and anchor then
            row = QuestLogRewardRows.Ensure(surface, dock, index)
        end
        if row then
            if index <= count and anchor then
                local line = lines[index]
                local text = nil
                if type(line) == "table" and type(line.text) == "string" then
                    text = line.text
                end
                pcall(row.SetText, row, text or "")
                if text and line.r then
                    pcall(row.SetTextColor, row, line.r, line.g, line.b)
                end
                if type(row.SetPoint) == "function" then
                    -- Grid position, not line position: column 0 or 1 across,
                    -- and only every second entry starts a new line. Derived
                    -- from floor rather than a modulo, because neither spelling
                    -- of it is portable here -- Vanilla's Lua has math.mod and
                    -- no % operator, later ones have the operator and no
                    -- math.mod.
                    local gridLine = math.floor((index - 1) / QuestLogRewardRows.columns)
                    local column = (index - 1) - gridLine * QuestLogRewardRows.columns
                    pcall(row.ClearAllPoints, row)
                    pcall(row.SetPoint, row, "TOPLEFT", anchor, "BOTTOMLEFT",
                        leftCorrection + column * QuestLogRewardRows.columnWidth,
                        -topMargin - gridLine * QuestLogRewardRows.rowHeight)
                end
                Client.ShowObject(row)
                lastRow = row
            else
                Client.HideObject(row)
            end
        end
        index = index + 1
    end

    if count > 0 and anchor and lastRow then
        local spacer = QuestLogRewardRows.Spacer(surface, dock, lastRow)
        if spacer then
            Client.ShowObject(spacer)
        end
        Client.UpdateScrollChildRect(ResolveObject(surface.scroll))
        return true
    end
    if dock.unrealQuestRewardSpacer then
        Client.HideObject(dock.unrealQuestRewardSpacer)
    end
    return false
end

-- Item rarity colour on the completion window's reward names -----------------
--
-- The stock reward buttons draw every item name in one flat colour, so a green
-- and a blue reward read alike on the one window where the player has to pick
-- between them. The quality is available: GetQuestItemInfo(rewardType, index)
-- returns name, texture, count, quality, isUsable and GetItemQualityColor
-- turns that quality index into r, g, b plus a hex tag. Both are in this
-- client's own API reference (categories Quest and Item,
-- DOCUMENTED_NOT_RUNTIME_VERIFIED) and neither has been probed, so every step
-- below falls through to leaving the button exactly as it was found.
--
-- Buttons are matched to rewards BY NAME rather than by index arithmetic. The
-- choice buttons come first and the guaranteed rewards after them -- that much
-- QuestLogRewardRows.Anchor above already leans on for placement -- but a
-- learned spell also occupies a button on that chain and its position is not
-- established anywhere here. Reading the button's own name string and looking
-- it up among the rewards cannot be knocked out of step by a button this addon
-- did not predict, and a name that matches nothing keeps the colour it had.
--
-- One local for the whole thing, for the reason stated above
-- QuestLogRewardRows: this chunk is close to Lua's 200-local ceiling.
local QuestRewardItemColors = {
    -- QuestRewardItem1..10 and their Name FontStrings are in the frame
    -- inventory of behaviour test questgiver.addon_resolves_quest.v1
    -- (USER_CONFIRMED_INGAME); anything absent resolves to nil and is skipped.
    max = 10,
}

-- Name -> quality for everything the open window is offering. Both lists are
-- read on every pass because a reward the item cache has not yet filled in
-- comes back with a nil name and quality 0, and gains both a moment later.
function QuestRewardItemColors.Collect(rewardType, count, byName)
    local index = 1
    while index <= count do
        local name, quality = Client.GetQuestGiverItemInfo(rewardType, index)
        if name and quality then
            byName[name] = quality
        end
        index = index + 1
    end
end

-- The colour a region carried before this addon first tinted it is kept, so a
-- button that stops being a coloured reward -- the option switched off, the
-- window closed, a name that matches nothing -- is handed back exactly what it
-- had rather than a guess at what the stock template wanted.
function QuestRewardItemColors.Paint(region, red, green, blue)
    if not region or type(region.SetTextColor) ~= "function" then
        return false
    end
    if region.unrealQuestRewardColor == nil
        and type(region.GetTextColor) == "function" then
        local ok, r, g, b, a = pcall(region.GetTextColor, region)
        if ok and type(r) == "number" and type(g) == "number"
            and type(b) == "number" then
            region.unrealQuestRewardColor = { r, g, b,
                type(a) == "number" and a or 1 }
        end
    end

    if type(red) ~= "number" then
        local original = region.unrealQuestRewardColor
        if not region.unrealQuestRewardTinted or not original then
            return false
        end
        region.unrealQuestRewardTinted = nil
        return pcall(region.SetTextColor, region, original[1], original[2],
            original[3], original[4]) and true or false
    end

    -- Written on every pass rather than only when the value changes: the
    -- native panel repaints these regions whenever it refreshes, so an
    -- "already this colour" short-circuit would hand the flat colour back the
    -- next time the window was opened.
    if not pcall(region.SetTextColor, region, red, green, blue) then
        return false
    end
    region.unrealQuestRewardTinted = true
    return true
end

-- name, quality for one reward on the OPEN quest-giver window. Documented to
-- return five values even when the item cache is missing the entry, with name
-- nil and quality 0; both are normalised to nil here so the caller skips the
-- button instead of painting it grey.
function Client.GetQuestGiverItemInfo(rewardType, index)
    local ok, name, texture, count, quality =
        Call2("GetQuestItemInfo", rewardType, index)
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end
    if type(quality) ~= "number" then
        return name, nil
    end
    return name, quality
end

function Client.GetItemQualityColor(quality)
    if type(quality) ~= "number" then
        return nil
    end
    local ok, red, green, blue = Call1("GetItemQualityColor", quality)
    if not ok or type(red) ~= "number" or type(green) ~= "number"
        or type(blue) ~= "number" then
        return nil
    end
    return red, green, blue
end

-- The completion window only. The offer window states rewards too, but this is
-- the surface the colour was asked for and the only one where the player picks
-- one reward over another.
--
-- Passing false restores every button, so the option can be turned off without
-- a reload and a window left open while it was on does not keep its tint.
function Client.SetQuestRewardItemQualityColors(enabled)
    local surface = QuestLogRewardRows.surfaces.complete
    local dock = ResolveObject(surface.dock)
    local byName = nil
    if enabled and dock and Client.IsObjectShown(dock) then
        local choices, rewards = Client.GetQuestGiverRewardCounts()
        byName = {}
        QuestRewardItemColors.Collect("choice", choices, byName)
        QuestRewardItemColors.Collect("reward", rewards, byName)
    end

    local painted = false
    local index = 1
    while index <= QuestRewardItemColors.max do
        local name = surface.item .. tostring(index)
        local region = ResolveObject(name .. "Name")
        local red, green, blue
        if byName and Client.IsObjectShown(ResolveObject(name)) then
            -- The text on screen is not always the name the client reported:
            -- Quest/QuestGiverTranslation.lua rewrites these same regions with
            -- the bundled localized item name, and GetQuestItemInfo keeps
            -- answering in the server's language. That module records what it
            -- replaced on the region itself, so the native string is preferred
            -- whenever it is there and a translated window keeps its colours.
            local text = region and region.unrealQuestGiverNativeText
            if type(text) ~= "string" or text == "" then
                text = Client.GetObjectText(region)
            end
            local quality = text and byName[text]
            if quality then
                red, green, blue = Client.GetItemQualityColor(quality)
            end
        end
        if QuestRewardItemColors.Paint(region, red, green, blue) then
            painted = true
        end
        index = index + 1
    end
    return painted
end

function Client.IsExtendedClassicQuestLogShown()
    local frame = ResolveObject("QuestLogFrame")
    return frame and frame.unrealQuestExtendedClassic == true
        and Client.IsObjectShown(frame) or false
end

-- Lifts every text region on a row clear of the plaque. QuestLogTitle<N> uses
-- more than the one FontString returned by Button:GetFontString(): the native
-- completion tail can be painted by another template region. Raising only the
-- primary label therefore leaves "(Complete)" underneath the later-created
-- plaque. GetRegions is the authoritative inventory on this client (and is
-- runtime-verified even though GetNumRegions always reports zero), so every
-- FontString it returns is moved together. GetFontString remains the fallback
-- for a host whose region walk fails.
local function RaiseQuestLogRowLabels(row)
    if not row or row.unrealQuestLabelRaised then
        return
    end

    local raised = false
    local regions = Client.GetRegionList(row)
    local index = 1
    while index <= table.getn(regions or {}) do
        local region = regions[index]
        if Client.GetObjectType(region) == "FontString"
            and type(region.SetDrawLayer) == "function"
            and pcall(region.SetDrawLayer, region, "OVERLAY") then
            raised = true
        end
        index = index + 1
    end

    if not raised and type(row.GetFontString) == "function" then
        local ok, label = pcall(row.GetFontString, row)
        if ok and label and type(label.SetDrawLayer) == "function"
            and pcall(label.SetDrawLayer, label, "OVERLAY") then
            raised = true
        end
    end
    row.unrealQuestLabelRaised = raised and true or nil
end

-- The anchor an object carried before this addon first moved it, cached on the
-- object under `field`.
--
-- Read once and only once: the native list re-runs its own layout constantly,
-- so a second read would hand back whatever offset was last written here as if
-- it were the client's own. GetPoint returns this client's measured INVERTED Y
-- and a relative frame as a name string, so both are normalized here and the
-- stored table can be handed straight to SetPoint.
local function QuestLogNativeAnchor(object, row, field)
    if not object or type(object.ClearAllPoints) ~= "function"
        or type(object.SetPoint) ~= "function" then
        return nil
    end
    if not object[field] and type(object.GetPoint) == "function" then
        local ok, point, relative, relativePoint, x, invertedY =
            pcall(object.GetPoint, object, 1)
        if ok and point then
            if type(relative) == "string" then
                relative = ResolveObject(relative) or row
            end
            object[field] = {
                point, relative or row, relativePoint or point,
                x or 0, -(invertedY or 0),
            }
        end
    end
    return object[field]
end

-- The stock completion state is the row's named Tag FontString. Move it six
-- pixels left (four further than the original treatment) and three down on
-- every quest row so followed and ordinary completed quests stay aligned.
local function SetQuestLogTagOffset(row)
    local rowName = Client.GetObjectName(row)
    local tag = rowName and ResolveObject(rowName .. "Tag") or nil
    local anchor = QuestLogNativeAnchor(tag, row, "unrealQuestFollowingPoint")
    if not anchor then
        return false
    end
    if tag.unrealQuestFollowingTagDown == true then
        return true
    end
    pcall(tag.ClearAllPoints, tag)
    local ok = pcall(tag.SetPoint, tag, anchor[1], anchor[2], anchor[3],
        anchor[4] + QUEST_LOG_TAG_OFFSET_X, anchor[5] - 3)
    if ok then
        tag.unrealQuestFollowingTagDown = true
    end
    return ok and true or false
end

-- The stock quest-row hover is the Button's own anonymous highlight Texture.
-- GetHighlightTexture is documented by this client
-- (DOCUMENTED_NOT_RUNTIME_VERIFIED); every method remains guarded so a row
-- without that texture keeps its native presentation. Re-anchor only when the
-- returned texture changes: unlike the quest-log poll, the native template's
-- highlight geometry is stable for the lifetime of that Texture.
local function InsetQuestLogHighlight(row)
    if not row or type(row.GetHighlightTexture) ~= "function" then
        return false
    end
    local ok, highlight = pcall(row.GetHighlightTexture, row)
    if not ok or not highlight then
        return false
    end
    if row.unrealQuestInsetHighlight == highlight then
        return true
    end
    if type(highlight.ClearAllPoints) ~= "function"
        or type(highlight.SetPoint) ~= "function" then
        return false
    end
    pcall(highlight.ClearAllPoints, highlight)
    local topOk = pcall(highlight.SetPoint, highlight,
        "TOPLEFT", row, "TOPLEFT", 0, 0)
    local bottomOk = pcall(highlight.SetPoint, highlight,
        "BOTTOMRIGHT", row, "BOTTOMRIGHT", -QUEST_LOG_ROW_RIGHT_INSET, 0)
    if not topOk or not bottomOk then
        return false
    end
    row.unrealQuestInsetHighlight = highlight
    return true
end

-- The selected quest uses FrameXML's separate QuestLogHighlightFrame: its
-- QuestLogSkillHighlight texture fills that frame, so shortening the frame is
-- what shortens the native focus artwork. Extended Quest Log 3.6.1 preserves
-- the same named-frame contract as Vanilla prior art. The lookup and methods
-- remain optional, and the original width is retained so repeated polls never
-- compound the four-pixel reduction.
function Client.SetQuestLogFocusTextureInset()
    local frame = ResolveObject("QuestLogHighlightFrame")
    if not frame or type(frame.GetWidth) ~= "function"
        or type(frame.SetWidth) ~= "function" then
        return false
    end
    local ok, width = pcall(frame.GetWidth, frame)
    if not ok or type(width) ~= "number" or width <= QUEST_LOG_ROW_RIGHT_INSET then
        return false
    end
    if type(frame.unrealQuestOriginalWidth) ~= "number" then
        frame.unrealQuestOriginalWidth = width
    end
    local target = frame.unrealQuestOriginalWidth - QUEST_LOG_ROW_RIGHT_INSET
    if width == target then
        return true
    end
    return pcall(frame.SetWidth, frame, target) and true or false
end

-- Shift only the button's title labels; the separate Tag FontString keeps its
-- horizontal position. Headers and empty pooled rows restore the native x.
local function SetQuestLogTitleRegionOffset(region, row, offset)
    local anchor = QuestLogNativeAnchor(region, row, "unrealQuestTitlePoint")
    if not anchor then
        return false
    end
    if region.unrealQuestTitleOffset == offset then
        return true
    end
    pcall(region.ClearAllPoints, region)
    local ok = pcall(region.SetPoint, region, anchor[1], anchor[2], anchor[3],
        anchor[4] + offset, anchor[5])
    if ok then
        region.unrealQuestTitleOffset = offset
    end
    return ok and true or false
end

local function SetQuestLogRowTitleOffset(row, offset)
    local rowName = Client.GetObjectName(row)
    local moved = false
    if rowName then
        local index = 1
        while index <= table.getn(QUEST_LOG_TITLE_REGIONS) do
            local region = ResolveObject(rowName .. QUEST_LOG_TITLE_REGIONS[index])
            if SetQuestLogTitleRegionOffset(region, row, offset) then
                moved = true
            end
            index = index + 1
        end
    end
    if not moved and type(row.GetFontString) == "function" then
        local ok, label = pcall(row.GetFontString, row)
        if ok then
            moved = SetQuestLogTitleRegionOffset(label, row, offset)
        end
    end
    return moved
end

-- Difficulty colour on a native list row.
--
-- The stock quest log paints each row by how hard its quest is; this client
-- cannot, because GetDifficultyColor is absent here and no addon-side shim
-- reaches the native call site (knowledge.json
-- core.getdifficultycolor_missing). uUI's Modern list then paints every row
-- one uniform bright colour on each of its own font passes. The colour itself
-- comes from Client.GetQuestLevelColor, which already derives the standard
-- bands locally from GetQuestGreenRange.
--
-- The colour found on a region before the first write is kept, so a row that
-- stops being a coloured quest row -- a header, an empty pooled row, or a host
-- that is not the modern surface -- is handed back exactly what it had rather
-- than a guess at what the theme wanted.
local function SetQuestLogTitleRegionColor(region, red, green, blue)
    if not region or type(region.SetTextColor) ~= "function" then
        return false
    end
    if region.unrealQuestTitleColor == nil and type(region.GetTextColor) == "function" then
        local ok, r, g, b, a = pcall(region.GetTextColor, region)
        if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
            region.unrealQuestTitleColor = { r, g, b, type(a) == "number" and a or 1 }
        end
    end

    if type(red) ~= "number" then
        local original = region.unrealQuestTitleColor
        if not region.unrealQuestTitleTinted or not original then
            return false
        end
        region.unrealQuestTitleTinted = nil
        return pcall(region.SetTextColor, region, original[1], original[2],
            original[3], original[4]) and true or false
    end

    -- Written on every pass rather than only when the value changes: the host
    -- theme repaints these same regions whenever the native list updates, so a
    -- "already this colour" short-circuit would leave its colour standing
    -- until the quest's level happened to change.
    if not pcall(region.SetTextColor, region, red, green, blue) then
        return false
    end
    region.unrealQuestTitleTinted = true
    return true
end

-- Passing no colour restores whatever the row carried before this addon first
-- tinted it.
function Client.SetQuestLogRowTitleColor(row, red, green, blue)
    if not row then
        return false
    end
    local rowName = Client.GetObjectName(row)
    local painted = false
    if rowName then
        local index = 1
        while index <= table.getn(QUEST_LOG_TITLE_REGIONS) do
            local region = ResolveObject(rowName .. QUEST_LOG_TITLE_REGIONS[index])
            if SetQuestLogTitleRegionColor(region, red, green, blue) then
                painted = true
            end
            index = index + 1
        end
    end
    if not painted and type(row.GetFontString) == "function" then
        local ok, label = pcall(row.GetFontString, row)
        if ok then
            painted = SetQuestLogTitleRegionColor(label, red, green, blue)
        end
    end
    return painted
end

-- Hides the party count the client draws on the row's own GroupMates
-- FontString.
--
-- The widget is QuestLogTitle<N>GroupMates, and that is measured, not guessed:
-- probe questloggrouptag (probeVersion 1.44.0, 2026-09-04) walked every quest
-- log row with GetRegions while the player stood in a party on shared quests
-- and found the "[1]" on exactly that region of rows 2, 5 and 6, anchored LEFT
-- to its row's LEFT at x=8. It is NOT the row's Tag FontString, which carries
-- the completion state and never held a count in that run.
--
-- It is hidden because the client anchors it into the row's left gutter, which
-- is where this addon's own presentation already lives, and because
-- Quest/QuestLogLevels.lua writes the same count into the row's text where it
-- lines up with the "[level] " prefix by construction. The same run measured
-- that the hide survives a public QuestLog_Update -- all three stayed hidden --
-- so this is not fighting the client for the widget; the caller's poll re-applies
-- it only for rows the list has since recycled.
--
-- Only a widget that literally reads as a bracketed number is hidden. One
-- carrying anything else is left exactly as the client left it, so a client
-- that puts something else there is never touched.
--
-- The hide is remembered on the widget, so a row that stops carrying a count is
-- not left permanently missing one.
function Client.SetQuestLogRowPartyTagHidden(row, hidden)
    local rowName = Client.GetObjectName(row)
    local tag = rowName and ResolveObject(rowName .. "GroupMates") or nil
    if not tag then
        return false
    end

    if hidden then
        local text = Client.GetObjectText(tag)
        if type(text) ~= "string"
            or not string.find(text, "^%s*%[%d+%]%s*$") then
            return false
        end
        tag.unrealQuestPartyTagHidden = true
        return Client.HideObject(tag)
    end

    if not tag.unrealQuestPartyTagHidden then
        return false
    end
    tag.unrealQuestPartyTagHidden = nil
    return Client.ShowObject(tag)
end

local function EnsureQuestLogFollowingRow(row)
    if not row or row.unrealQuestFollowingBackground then
        RaiseQuestLogRowLabels(row)
        return row and true or false
    end

    -- The authored plaque is the whole highlight: it carries its own gold edge,
    -- so the row draws no accent fill and no flat border of its own. ARTWORK
    -- keeps it above modern-wow's list-page art; the row labels are raised to
    -- OVERLAY, so the plaque still stays behind the text. It starts at the
    -- title rather than spanning the gutter, so the tracked bar and the quest
    -- dot/followed marker stay outside its gold rim.
    local background = nil
    if type(row.CreateTexture) == "function" then
        local ok, created = pcall(row.CreateTexture, row, nil, "ARTWORK")
        if ok and created then
            pcall(created.SetTexture, created, QUEST_LOG_FOLLOWING_PLAQUE_TEXTURE)
            -- Restated after creation: the layer argument to CreateTexture is
            -- what keeps the plaque above modern-wow's page art. The labels'
            -- OVERLAY layer keeps them above it in turn.
            if type(created.SetDrawLayer) == "function" then
                pcall(created.SetDrawLayer, created, "ARTWORK")
            end
            pcall(created.SetPoint, created, "TOPLEFT", row, "TOPLEFT",
                QUEST_LOG_FOLLOWING_PLAQUE_INSET, 0)
            pcall(created.SetPoint, created, "BOTTOMRIGHT", row, "BOTTOMRIGHT",
                -QUEST_LOG_ROW_RIGHT_INSET, 0)
            pcall(created.Hide, created)
            background = created
        end
    end
    row.unrealQuestFollowingBackground = background
    row.unrealQuestFollowingPlaqueShift = 0

    if type(row.CreateTexture) == "function" then
        local dotOk, dot = pcall(row.CreateTexture, row, nil, "OVERLAY")
        if dotOk and dot then
            pcall(dot.SetTexture, dot, Client.MINIMAP_OBJECTIVE_TEXTURE)
            pcall(dot.SetPoint, dot, "LEFT", row, "LEFT",
                QUEST_LOG_QUEST_DOT_OFFSET_X, 0)
            pcall(dot.SetWidth, dot, QUEST_LOG_QUEST_DOT_SIZE)
            pcall(dot.SetHeight, dot, QUEST_LOG_QUEST_DOT_SIZE)
            pcall(dot.Hide, dot)
            row.unrealQuestQuestDot = dot
        end

        local markOk, mark = pcall(row.CreateTexture, row, nil, "OVERLAY")
        if markOk and mark then
            pcall(mark.SetTexture, mark, TRACKER_FOLLOWING_QUEST_TEXTURE)
            -- The marker replaces the quest-colour dot in the quest gutter.
            pcall(mark.SetPoint, mark, "LEFT", row, "LEFT",
                QUEST_LOG_QUEST_MARK_OFFSET_X, 0)
            pcall(mark.SetWidth, mark, TRACKER_FOLLOWING_MARK_WIDTH)
            pcall(mark.SetHeight, mark, TRACKER_FOLLOWING_MARK_HEIGHT)
            pcall(mark.Hide, mark)
            row.unrealQuestFollowingMark = mark
        end

    end
    RaiseQuestLogRowLabels(row)
    return true
end

-- The modern list uses a denser native row pool. A small height increase makes
-- each quest easier to scan and click; the original height is retained so a
-- surface that is rebuilt without the modern panels can be restored cleanly.
function Client.SetModernQuestLogRowLayout(row, modern)
    if not row then
        return false
    end
    if row.unrealQuestOriginalHeight == nil and type(row.GetHeight) == "function" then
        local ok, height = pcall(row.GetHeight, row)
        if ok and type(height) == "number" then
            row.unrealQuestOriginalHeight = height
        end
    end
    if type(row.SetHeight) ~= "function" then
        return false
    end
    local height = modern and 18 or row.unrealQuestOriginalHeight
    if type(height) ~= "number" then
        return false
    end
    if type(row.GetHeight) == "function" then
        local currentOk, current = pcall(row.GetHeight, row)
        if currentOk and current == height then
            return true
        end
    end
    return pcall(row.SetHeight, row, height) and true or false
end

-- A frame reparented into the detail child must sit above modern-wow's page
-- art. The target is derived from the child rather than hardcoded, and is
-- rewritten only when native code changes it.
function QuestLogRewardRows.RaiseMoneyFrame(frame, scrollChild)
    if not frame or not scrollChild
        or type(frame.SetFrameLevel) ~= "function"
        or type(scrollChild.GetFrameLevel) ~= "function" then
        return false
    end
    local ok, base = pcall(scrollChild.GetFrameLevel, scrollChild)
    if not ok or type(base) ~= "number" then
        return false
    end
    local target = base + 2
    if type(frame.GetFrameLevel) == "function" then
        local currentOk, current = pcall(frame.GetFrameLevel, frame)
        if currentOk and current == target then
            return true
        end
    end
    return pcall(frame.SetFrameLevel, frame, target) and true or false
end

-- The native detail refresh moves the receive label (and therefore the money
-- frame anchored to it) without changing that anchor. Updating the scroll
-- range only when SetPoint changes misses this case and leaves the coin row
-- below the viewport. Compare geometry in scroll-child space so a real layout
-- move triggers one range update, while ordinary user scrolling moves both
-- objects together and stays read-only.
function QuestLogRewardRows.MoneyGeometryChanged(frame, scrollChild, amount,
    prefix, active)
    if not frame or not scrollChild or type(prefix) ~= "string" then
        return false
    end
    local relativeBottom = nil
    local relativeTop = nil
    if active then
        local frameBottom = ReadObjectMethod(frame, "GetBottom")
        local frameTop = ReadObjectMethod(frame, "GetTop")
        local childBottom = ReadObjectMethod(scrollChild, "GetBottom")
        local childTop = ReadObjectMethod(scrollChild, "GetTop")
        if type(frameBottom) == "number" and type(childBottom) == "number" then
            relativeBottom = math.floor((frameBottom - childBottom) * 10 + 0.5) / 10
        end
        if type(frameTop) == "number" and type(childTop) == "number" then
            relativeTop = math.floor((frameTop - childTop) * 10 + 0.5) / 10
        end
    end

    local amountKey = prefix .. "Amount"
    local bottomKey = prefix .. "Bottom"
    local topKey = prefix .. "Top"
    local changed = frame[amountKey] ~= amount
        or frame[bottomKey] ~= relativeBottom
        or frame[topKey] ~= relativeTop
    frame[amountKey] = amount
    frame[bottomKey] = relativeBottom
    frame[topKey] = relativeTop
    return changed
end

-- Reward money is a separate native frame. Parent AND anchor it inside the
-- modern detail scroll child: changing only the parent left the native
-- screen-space anchor intact, which put the coin row below the parchment.
-- QuestLogSpacerFrame follows the reward money so the scroll range contains
-- that complete line. The required-money frame follows its own label in the
-- same child. Stable geometry is read-only; a native refresh that rewrites an
-- anchor is repaired without reparenting an already-correct frame.
function Client.AttachModernQuestLogRewards(scrollChild)
    if not scrollChild then
        return false
    end

    local rewardMoney = ResolveObject("QuestLogMoneyFrame")
    local rewardText = ResolveObject("QuestLogItemReceiveText")
    local rewardSpacer = ResolveObject("QuestLogSpacerFrame")
    local attached = false
    local changed = false
    local rewardAmount, requiredAmount = Client.GetQuestLogMoneyAmounts()
    if rewardMoney and rewardText then
        local rewardAnchor, rewardAnchorName =
            ResolveExtendedQuestLogMoneyAnchor(rewardText)
        local parentMatches = ExtendedQuestLogParentMatches(rewardMoney,
            scrollChild, "QuestLogDetailScrollChildFrame")
        local anchorMatches = ExtendedQuestLogAnchorMatches(rewardMoney,
            "TOPLEFT", rewardAnchor, rewardAnchorName, "BOTTOMLEFT")
        if rewardMoney.unrealQuestModernRewardAnchor ~= rewardAnchor
            or not parentMatches or not anchorMatches then
            local placed = false
            if parentMatches then
                placed = SetExtendedQuestLogAnchor(rewardMoney, "TOPLEFT",
                    rewardAnchor, "BOTTOMLEFT", 0, -2)
            else
                placed = AttachExtendedQuestLogMoney(rewardMoney, rewardAnchor,
                    scrollChild, "TOPLEFT", "BOTTOMLEFT", 0, -2)
            end
            if placed then
                rewardMoney.unrealQuestModernRewardAnchor = rewardAnchor
                attached = true
                changed = true
            end
        else
            attached = true
        end
        QuestLogRewardRows.RaiseMoneyFrame(rewardMoney, scrollChild)
        -- Replaced by the addon's coin line: see Client.SetQuestLogRewardMoney.
        if rewardAmount > 0 and not rewardMoney.unrealQuestMoneyReplaced then
            Client.ShowObject(rewardMoney)
        end
        if QuestLogRewardRows.MoneyGeometryChanged(rewardMoney, scrollChild,
            rewardAmount, "unrealQuestModernReward", rewardAmount > 0) then
            changed = true
        end

        if rewardSpacer and (rewardSpacer.unrealQuestModernMoneyAnchor ~= rewardMoney
            or not ExtendedQuestLogAnchorMatches(rewardSpacer, "TOP", rewardMoney,
                "QuestLogMoneyFrame", "BOTTOM")) then
            if SetExtendedQuestLogAnchor(rewardSpacer, "TOP", rewardMoney,
                "BOTTOM", 0, 0) then
                rewardSpacer.unrealQuestModernMoneyAnchor = rewardMoney
                changed = true
            end
        end
    end

    local requiredMoney = ResolveObject("QuestLogRequiredMoneyFrame")
    local requiredText = ResolveObject("QuestLogRequiredMoneyText")
    if requiredMoney and requiredText then
        local parentMatches = ExtendedQuestLogParentMatches(requiredMoney,
            scrollChild, "QuestLogDetailScrollChildFrame")
        local anchorMatches = ExtendedQuestLogAnchorMatches(requiredMoney,
            "LEFT", requiredText, "QuestLogRequiredMoneyText", "RIGHT")
        if requiredMoney.unrealQuestModernRequiredAnchor ~= requiredText
            or not parentMatches or not anchorMatches then
            local placed = false
            if parentMatches then
                placed = SetExtendedQuestLogAnchor(requiredMoney, "LEFT",
                    requiredText, "RIGHT", 10, 0)
            else
                placed = AttachExtendedQuestLogMoney(requiredMoney, requiredText,
                    scrollChild, "LEFT", "RIGHT", 10, 0)
            end
            if placed then
                requiredMoney.unrealQuestModernRequiredAnchor = requiredText
                attached = true
                changed = true
            end
        else
            attached = true
        end
        QuestLogRewardRows.RaiseMoneyFrame(requiredMoney, scrollChild)
        if requiredAmount > 0 then
            Client.ShowObject(requiredMoney)
        end
        if QuestLogRewardRows.MoneyGeometryChanged(requiredMoney, scrollChild,
            requiredAmount, "unrealQuestModernRequired", requiredAmount > 0) then
            changed = true
        end
    end

    if changed then
        Client.UpdateScrollChildRect(ResolveObject("QuestLogDetailScrollFrame"))
    end
    return attached
end

-- unrealUI paints the native detail objectives white on every refresh. Apply
-- the live quest model immediately afterwards so finished lines use the same
-- readable green completion treatment as the reference design.
function Client.SetModernQuestLogObjectiveColors(objectives)
    local index = 1
    while index <= 10 do
        local line = ResolveObject("QuestLogObjective" .. tostring(index))
        if line and type(line.SetTextColor) == "function" then
            -- By request: #109a14 complete, #a26003 partly done (a counter
            -- above zero), #606060 not started or with no counter at all.
            local objective = objectives and objectives[index]
            if objective and objective.finished then
                pcall(line.SetTextColor, line, 16 / 255, 154 / 255, 20 / 255)
            elseif objective and type(objective.have) == "number" and objective.have > 0 then
                pcall(line.SetTextColor, line, 162 / 255, 96 / 255, 3 / 255)
            else
                pcall(line.SetTextColor, line, 96 / 255, 96 / 255, 96 / 255)
            end
        end
        index = index + 1
    end
    return true
end

-- Slides the plaque, both edges together, so it moves rather than stretches.
-- Re-anchoring is idempotent and only happens when the offset actually
-- changes, because this runs on the same poll as the rest of the row.
local function SetQuestLogFollowingPlaqueShift(row, shift)
    local plaque = row and row.unrealQuestFollowingBackground
    if not plaque or row.unrealQuestFollowingPlaqueShift == shift
        or type(plaque.ClearAllPoints) ~= "function"
        or type(plaque.SetPoint) ~= "function" then
        return false
    end
    pcall(plaque.ClearAllPoints, plaque)
    local topOk = pcall(plaque.SetPoint, plaque, "TOPLEFT", row, "TOPLEFT",
        QUEST_LOG_FOLLOWING_PLAQUE_INSET + shift, 0)
    local bottomOk = pcall(plaque.SetPoint, plaque, "BOTTOMRIGHT", row,
        "BOTTOMRIGHT", shift - QUEST_LOG_ROW_RIGHT_INSET, 0)
    if not topOk or not bottomOk then
        return false
    end
    row.unrealQuestFollowingPlaqueShift = shift
    return true
end

function Client.SetQuestLogFollowingRow(row, active, red, green, blue, modern)
    if not EnsureQuestLogFollowingRow(row) then
        return false
    end
    InsetQuestLogHighlight(row)
    SetQuestLogFollowingPlaqueShift(row,
        modern and QUEST_LOG_FOLLOWING_PLAQUE_MODERN_SHIFT_X or 0)
    local shown = active and true or false
    SetQuestLogTagOffset(row)
    SetQuestLogRowTitleOffset(row,
        type(red) == "number" and QUEST_LOG_TITLE_OFFSET_X or 0)
    -- Built one at a time rather than through a list: either part can be nil
    -- when its CreateTexture call failed, and a hole makes table.getn lie.
    local parts = {}
    local paths = {}
    if row.unrealQuestFollowingBackground then
        table.insert(parts, row.unrealQuestFollowingBackground)
        table.insert(paths, QUEST_LOG_FOLLOWING_PLAQUE_TEXTURE)
    end
    if row.unrealQuestFollowingMark then
        table.insert(parts, row.unrealQuestFollowingMark)
        table.insert(paths, TRACKER_FOLLOWING_QUEST_TEXTURE)
    end
    local index = 1
    while index <= table.getn(parts) do
        local part = parts[index]
        if shown then
            -- Under unrealUI's modern-wow theme the followed plaque did not
            -- show at all (USER_CONFIRMED_INGAME 2026-09-13). The host strips
            -- stock regions through U.HideRegion, which clears the texture and
            -- zeroes the alpha as well as hiding, and a later Show restores
            -- neither. Both are restated before showing so a strip that caught
            -- these regions cannot keep them invisible.
            if type(part.SetTexture) == "function" then
                pcall(part.SetTexture, part, paths[index])
            end
            if type(part.SetAlpha) == "function" then
                pcall(part.SetAlpha, part, 1)
            end
            Client.ShowObject(part)
        else
            Client.HideObject(part)
        end
        index = index + 1
    end
    local dot = row.unrealQuestQuestDot
    if dot then
        if shown or type(red) ~= "number" or type(green) ~= "number"
            or type(blue) ~= "number" then
            Client.HideObject(dot)
        else
            -- Restated for the same host strip as the plaque above.
            pcall(dot.SetTexture, dot, Client.MINIMAP_OBJECTIVE_TEXTURE)
            pcall(dot.SetAlpha, dot, 1)
            if type(dot.SetVertexColor) == "function" then
                pcall(dot.SetVertexColor, dot, red, green, blue, 1)
            end
            Client.ShowObject(dot)
        end
    end
    return true
end

function Client.PrepareModernQuestLogActionAnchor(anchor)
    if not anchor then
        return false
    end
    if not anchor.unrealQuestActionPrepared then
        if not Client.GrowObjectHeight(anchor, 44) then
            return false
        end
        Client.SetFontStringJustifyV(anchor, "BOTTOM")
        anchor.unrealQuestActionPrepared = true
    end
    return true
end

function Client.PlaceModernQuestLogAction(button, anchor, offsetX, width, height)
    if not button or not anchor or not Client.PrepareModernQuestLogActionAnchor(anchor) then
        return false
    end
    Client.SetObjectSize(button, width, height)
    return Client.PlaceInsideObject(button, anchor, offsetX, -7)
end

-- The detail pane's own top-right corner, where the per-quest language flag
-- goes (Quest/QuestLogButtons.lua).
--
-- The anchor is the detail VIEWPORT, QuestLogDetailScrollFrame
-- (BEHAVIOR_VERIFIED: /urp interface QuestLogFrame, capturedAt 2026-08-23),
-- on both surfaces -- the native log and unrealUI's modern one, which reuses
-- the same native frames. uUI's own UnrealUIQuestLogDetailPanel was the
-- obvious candidate for "the right-hand pane" and is deliberately NOT used:
-- it is deliberately grown 26 pixels past the viewport to contain the native
-- scroll bar, so its top-right corner is the scroll UP ARROW's, and a flag
-- anchored there would sit on a button the player needs.
function Client.GetQuestLogDetailAnchor()
    return ResolveObject("QuestLogDetailScrollFrame")
end

-- Anchored to that viewport but PARENTED TO QuestLogFrame, and the split
-- matters both ways. Not the scroll child, which is what the scroll frame
-- moves: a flag in there would slide away with the description text the first
-- time the player scrolled. Not the scroll frame either, whose children this
-- client may clip to the visible rect. QuestLogFrame is the one frame both
-- surfaces show and neither clips.
function Client.PlaceQuestLogFlag(button, anchor, offsetX, offsetY)
    local parent = ResolveObject("QuestLogFrame")
    if not button or not anchor or not parent then
        return false
    end
    if button.unrealQuestFlagParent ~= parent then
        if type(button.SetParent) ~= "function"
            or not pcall(button.SetParent, button, parent) then
            return false
        end
        button.unrealQuestFlagParent = parent
    end
    -- Re-applied every time rather than only on a parent change: SetParent is
    -- not the only thing that can move a frame level here, and a host theme
    -- owns the panels drawn over this frame.
    if type(parent.GetFrameLevel) == "function" and type(button.SetFrameLevel) == "function" then
        local ok, level = pcall(parent.GetFrameLevel, parent)
        if ok and type(level) == "number" then
            pcall(button.SetFrameLevel, button, level + 20)
        end
    end
    return Client.AnchorObject(button, "TOPRIGHT", anchor, "TOPRIGHT", offsetX, offsetY)
end

-- The quest-giver's offer window, for Quest/QuestGiverTranslation.lua --------
--
-- QuestDetailScrollFrame / QuestDetailScrollChildFrame are the same pair the
-- reward rows already anchor to on this surface (QuestLogRewardRows.surfaces
-- above), and the rows landing where they were asked to is what says these
-- names are real here. Both are still resolved by name and both still fall
-- through when absent.
function Client.GetQuestGiverDetailAnchor()
    return ResolveObject("QuestDetailScrollFrame")
end

function Client.GetQuestGiverDetailPanel()
    return ResolveObject("QuestDetailScrollChildFrame")
end

-- The TURN-IN window's counterparts. QuestRewardScrollFrame /
-- QuestRewardScrollChildFrame are the pair QuestLogRewardRows.surfaces.complete
-- already docks the experience and reputation rows to, and both were measured
-- present and shown on 2026-09-10 (questgivertextcomplete) alongside the panel's
-- own named strings -- QuestRewardTitleText, QuestRewardText,
-- QuestRewardRewardTitleText, QuestRewardItemChooseText and
-- QuestRewardItem1..10Name. Resolved by name and falling through when absent,
-- like every other name here.
function Client.GetQuestCompleteDetailAnchor()
    return ResolveObject("QuestRewardScrollFrame")
end

function Client.GetQuestCompleteDetailPanel()
    return ResolveObject("QuestRewardScrollChildFrame")
end

-- Anchored to the offer viewport but PARENTED TO QuestFrame, and the split is
-- the same one Client.PlaceQuestLogFlag makes on the log, for the same two
-- reasons: the scroll CHILD slides away under the player's scroll wheel and
-- would take the flag with it, and the scroll FRAME may clip its children to
-- the visible rect. QuestFrame is the one frame that neither moves nor clips.
function Client.PlaceQuestGiverFlag(button, anchor, offsetX, offsetY)
    local parent = ResolveObject("QuestFrame")
    if not button or not anchor or not parent then
        return false
    end
    if button.unrealQuestFlagParent ~= parent then
        if type(button.SetParent) ~= "function"
            or not pcall(button.SetParent, button, parent) then
            return false
        end
        button.unrealQuestFlagParent = parent
    end
    if type(parent.GetFrameLevel) == "function" and type(button.SetFrameLevel) == "function" then
        local ok, level = pcall(parent.GetFrameLevel, parent)
        if ok and type(level) == "number" then
            pcall(button.SetFrameLevel, button, level + 20)
        end
    end
    return Client.AnchorObject(button, "TOPRIGHT", anchor, "TOPRIGHT", offsetX, offsetY)
end

-- Every FontString under a frame, down to `depth` levels of child frames.
--
-- This exists because the quest-giver panel's body strings have no name this
-- addon has evidence for. The confirmed record quest_dialog.
-- detail_reward_text_globals names that panel's HEADINGS and nothing else, and
-- guessing the Vanilla names for the three strings under them would be exactly
-- the assumption rule 3 forbids. The caller therefore identifies its fields by
-- CONTENT -- it already knows what the client says the title, objectives and
-- description are -- and this is the inventory it matches against.
--
-- GetNumRegions() always reports zero on this client (see the note above
-- Client.GetWorldFrame), so the walk is never gated on a count; GetRegionList
-- and GetChildList both return the real varargs.
function Client.CollectFontStrings(frame, depth, out)
    out = out or {}
    if not frame or type(depth) ~= "number" or depth < 0 then
        return out
    end
    local regions = Client.GetRegionList(frame)
    local index = 1
    local total = regions and table.getn(regions) or 0
    while index <= total do
        local region = regions[index]
        if region and Client.GetObjectType(region) == "FontString" then
            table.insert(out, region)
        end
        index = index + 1
    end
    if depth > 0 then
        local children = Client.GetChildList(frame)
        index = 1
        total = children and table.getn(children) or 0
        while index <= total do
            Client.CollectFontStrings(children[index], depth - 1, out)
            index = index + 1
        end
    end
    return out
end

function Client.SetModernQuestLogActionRule(parent, anchor, shown)
    if not parent or not anchor then
        return false
    end
    local rule = parent.unrealQuestActionRule
    if not rule then
        rule = CreateSolid(parent, "ARTWORK", UQ.colors.accent[1],
            UQ.colors.accent[2], UQ.colors.accent[3], 0.28)
        if not rule then
            return false
        end
        parent.unrealQuestActionRule = rule
    end
    -- Anchored once per anchor: this is called on every quest-log poll, and
    -- re-anchoring inside the detail scroll child every pass is what flashed
    -- the scrolled pane (rendering.scroll_child_regions_flash_unscrolled_on_poll).
    if parent.unrealQuestActionRuleAnchor ~= anchor then
        if type(rule.ClearAllPoints) == "function" then
            pcall(rule.ClearAllPoints, rule)
        end
        pcall(rule.SetPoint, rule, "TOPLEFT", anchor, "TOPLEFT", 0, 0)
        pcall(rule.SetPoint, rule, "TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
        pcall(rule.SetHeight, rule, 1)
        parent.unrealQuestActionRuleAnchor = anchor
    end
    if shown then Client.ShowObject(rule) else Client.HideObject(rule) end
    return true
end

function Client.PrepareModernQuestLogLevel(parent, title)
    if not parent or not title then
        return nil
    end
    local label = parent.unrealQuestLevelLabel
    if not label and type(parent.CreateFontString) == "function" then
        local ok, created = pcall(parent.CreateFontString, parent,
            "UnrealQuestLogLevel", "OVERLAY", "GameFontNormalSmall")
        if ok and created then
            -- #109a14, by request.
            pcall(created.SetTextColor, created, 16 / 255, 154 / 255, 20 / 255)
            StripShadow(created)
            label = created
            parent.unrealQuestLevelLabel = created
        end
    end
    if not label then
        return nil
    end
    -- The level sits in its own row between the quest name and the summary
    -- (which hangs off the title's bottom edge): the title grows by 24 and the
    -- label starts 18 below the title's top, clear of the name above and the
    -- summary below. Raised from 15/15, by request, so the two no longer crowd
    -- each other. Literals, not file-scope constants: this file is at the
    -- 200-local ceiling, past which the whole file silently fails to load.
    if not title.unrealQuestLevelPrepared then
        if not Client.GrowObjectHeight(title, 24) then
            return nil
        end
        Client.SetFontStringJustifyV(title, "TOP")
        title.unrealQuestLevelPrepared = true
    end
    -- 1 right and 26 down, by request (was 0, -18). Placed once per title:
    -- this runs on every quest-log poll, and re-anchoring anything inside the
    -- detail scroll child makes the client lay its regions out for one frame
    -- at the UNSCROLLED position (probe questlogbuttons.scroll_flicker.v1).
    if label.unrealQuestLevelAnchor ~= title then
        Client.PlaceInsideObject(label, title, 1, -26)
        label.unrealQuestLevelAnchor = title
    end
    return label
end

function Client.SetModernQuestLogLevel(label, text, shown)
    if not label then
        return false
    end
    -- Only on a change, for the same scroll-child relayout reason as the
    -- label's anchor above.
    local nextText = text or ""
    if label.unrealQuestLevelText ~= nextText and type(label.SetText) == "function" then
        if pcall(label.SetText, label, nextText) then
            label.unrealQuestLevelText = nextText
        end
    end
    if shown then return Client.ShowObject(label) end
    return Client.HideObject(label)
end

function Client.SetButtonLabel(button, text, red, green, blue)
    local label = button and button.unrealQuestLabel
    if not label then
        return false
    end
    local nextText = type(text) == "string" and text or ""
    if button.unrealQuestLabelText ~= nextText and type(label.SetText) == "function" then
        local ok = pcall(label.SetText, label, nextText)
        if ok then
            button.unrealQuestLabelText = nextText
        end
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

-- Tracker controls are child frames, not regions. Pin them explicitly to the
-- parent's strata and exactly one level above it: enough for their mouse input
-- and text to clear the tracker's own regions, while remaining below the
-- measured native minimap (level 2, with children at 3-4).
local function SetTrackerChildLayer(frame, parent)
    if frame and type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "PARENT")
    end
    if frame and parent and type(parent.GetFrameLevel) == "function"
        and type(frame.SetFrameLevel) == "function" then
        local levelOk, level = pcall(parent.GetFrameLevel, parent)
        if levelOk and type(level) == "number" then
            pcall(frame.SetFrameLevel, frame, level + 1)
        end
    end
end

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

    -- BACKGROUND: the tracker is persistent HUD furniture, so unit frames must
    -- win whenever the player places it underneath them. LOW was sufficient
    -- for stock panels but shared a draw band with unit-frame layouts, where
    -- the tracker's raised row levels let its text paint over the unit frame.
    if type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "BACKGROUND")
    end
    if type(frame.SetFrameLevel) == "function" then
        pcall(frame.SetFrameLevel, frame, 0)
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

    -- The followed quest is framed as one block (title plus every visible
    -- objective), matching the reference tracker: a warm translucent fill, a
    -- crisp amber one-pixel line and two progressively softer outer rings.
    -- These are window-owned textures rather than a child frame so they stay
    -- below the pooled row Buttons and can never intercept a quest click.
    local followingBackground = CreateSolid(frame, "ARTWORK",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 0)
    if followingBackground then
        pcall(followingBackground.Hide, followingBackground)
    end
    frame.unrealQuestFollowingBackground = followingBackground
    frame.unrealQuestFollowingRings = {}
    local ringIndex = 1
    while ringIndex <= 3 do
        local ring = {}
        local edgeIndex = 1
        while edgeIndex <= 4 do
            local edge = CreateSolid(frame, "ARTWORK",
                UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 0)
            if edge then
                pcall(edge.Hide, edge)
            end
            ring[edgeIndex] = edge
            edgeIndex = edgeIndex + 1
        end
        frame.unrealQuestFollowingRings[ringIndex] = ring
        ringIndex = ringIndex + 1
    end

    -- Header: the accent stripe, the title, the counter, and the two buttons
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
            if title then
                pcall(count.SetPoint, count, "LEFT", title, "RIGHT", 5, 0)
            else
                pcall(count.SetPoint, count, "TOPLEFT", frame, "TOPLEFT",
                    TRACKER_ACCENT_WIDTH + TRACKER_PADDING, -TRACKER_PADDING - 1)
            end
            pcall(count.SetJustifyH, count, "LEFT")
            pcall(count.SetTextColor, count, 0.55, 0.55, 0.55)
            StripShadow(count)
            frame.unrealQuestCount = count
        end
    end

    local collapse = CreateLabelledButton(frame, name .. "Collapse", TRACKER_BUTTON_SIZE, "-",
        "GameFontNormal")
    if collapse then
        SetTrackerChildLayer(collapse, frame)
        pcall(collapse.SetPoint, collapse, "TOPRIGHT", frame, "TOPRIGHT", -2, -2)
        local label = collapse.unrealQuestLabel
        if label then
            if type(label.ClearAllPoints) == "function" then
                pcall(label.ClearAllPoints, label)
            end
            if type(label.SetPoint) == "function" then
                pcall(label.SetPoint, label, "CENTER", collapse, "CENTER", 0, -2)
            end
            if type(label.SetJustifyV) == "function" then
                pcall(label.SetJustifyV, label, "CENTER")
            end
        end
    end
    frame.unrealQuestCollapse = collapse

    -- A compact spyglass button opens the NPC finder list from the tracker,
    -- rather than adding another button beside the map.
    local npcFinder = CreateLabelledButton(frame, name .. "NpcFinder", TRACKER_BUTTON_SIZE, "")
    if npcFinder then
        SetTrackerChildLayer(npcFinder, frame)
        pcall(npcFinder.SetPoint, npcFinder, "TOPRIGHT", frame, "TOPRIGHT",
            -(2 + TRACKER_BUTTON_SIZE), -2)
        if type(npcFinder.CreateTexture) == "function" then
            local iconOk, icon = pcall(npcFinder.CreateTexture, npcFinder, nil, "OVERLAY")
            if iconOk and icon then
                if type(icon.SetTexture) == "function" then
                    pcall(icon.SetTexture, icon, TRACKER_NPC_FINDER_ICON_TEXTURE)
                end
                pcall(icon.SetPoint, icon, "CENTER", npcFinder, "CENTER", 0, 0)
                pcall(icon.SetWidth, icon, TRACKER_NPC_FINDER_ICON_SIZE)
                pcall(icon.SetHeight, icon, TRACKER_NPC_FINDER_ICON_SIZE)
                npcFinder.unrealQuestIcon = icon
            end
        end
    end
    frame.unrealQuestNpcFinder = npcFinder

    frame.unrealQuestRows = { zone = {}, quest = {}, objective = {} }
    pcall(frame.Hide, frame)
    return frame
end

local TRACKER_FOLLOWING_RING_ALPHA = { 0.95, 0.32, 0.12 }

local function PlaceFollowingTexture(texture, frame, left, right, top, bottom)
    if not texture then
        return
    end
    if type(texture.ClearAllPoints) == "function" then
        pcall(texture.ClearAllPoints, texture)
    end
    pcall(texture.SetPoint, texture, "TOPLEFT", frame, "TOPLEFT", left, -top)
    pcall(texture.SetPoint, texture, "BOTTOMRIGHT", frame, "TOPRIGHT", right, -bottom)
end

local function PlaceFollowingEdge(edge, frame, side, left, right, top, bottom)
    if not edge then
        return
    end
    if type(edge.ClearAllPoints) == "function" then
        pcall(edge.ClearAllPoints, edge)
    end
    if side == 1 then
        pcall(edge.SetPoint, edge, "TOPLEFT", frame, "TOPLEFT", left, -top)
        pcall(edge.SetPoint, edge, "TOPRIGHT", frame, "TOPRIGHT", right, -top)
        pcall(edge.SetHeight, edge, 1)
    elseif side == 2 then
        pcall(edge.SetPoint, edge, "BOTTOMLEFT", frame, "TOPLEFT", left, -bottom)
        pcall(edge.SetPoint, edge, "BOTTOMRIGHT", frame, "TOPRIGHT", right, -bottom)
        pcall(edge.SetHeight, edge, 1)
    elseif side == 3 then
        pcall(edge.SetPoint, edge, "TOPLEFT", frame, "TOPLEFT", left, -top)
        pcall(edge.SetPoint, edge, "BOTTOMLEFT", frame, "TOPLEFT", left, -bottom)
        pcall(edge.SetWidth, edge, 1)
    else
        pcall(edge.SetPoint, edge, "TOPRIGHT", frame, "TOPRIGHT", right, -top)
        pcall(edge.SetPoint, edge, "BOTTOMRIGHT", frame, "TOPRIGHT", right, -bottom)
        pcall(edge.SetWidth, edge, 1)
    end
end

-- Recolours the existing following block without rebuilding any rows. The
-- tracker opacity slider calls this live; at zero every glow layer and the
-- inner line are hidden, exactly like the requested invisible-background
-- state, while the quest label and arrow remain useful.
function Client.SetTrackerFollowingOpacity(frame, percent)
    if not frame or type(percent) ~= "number" then
        return false
    end
    if percent < 0 then
        percent = 0
    elseif percent > 100 then
        percent = 100
    end
    frame.unrealQuestFollowingOpacity = percent
    local active = frame.unrealQuestFollowingActive and percent > 0
    local scale = percent / 100

    local background = frame.unrealQuestFollowingBackground
    if background then
        Client.SetSolidColor(background, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], 0.14 * scale)
        if active then Client.ShowObject(background) else Client.HideObject(background) end
    end

    local rings = frame.unrealQuestFollowingRings or {}
    local ringIndex = 1
    while ringIndex <= 3 do
        local ring = rings[ringIndex] or {}
        local alpha = TRACKER_FOLLOWING_RING_ALPHA[ringIndex] * scale
        local edgeIndex = 1
        while edgeIndex <= 4 do
            local edge = ring[edgeIndex]
            if edge then
                Client.SetSolidColor(edge, UQ.colors.accent[1], UQ.colors.accent[2],
                    UQ.colors.accent[3], alpha)
                if active then Client.ShowObject(edge) else Client.HideObject(edge) end
            end
            edgeIndex = edgeIndex + 1
        end
        ringIndex = ringIndex + 1
    end
    return true
end

-- Positions the following chrome around one complete visible quest block.
-- `top` and `bottom` are offsets down from the tracker window's top edge.
function Client.SetTrackerFollowingBlock(frame, top, bottom, percent)
    if not frame then
        return false
    end
    if type(top) ~= "number" or type(bottom) ~= "number" or bottom <= top then
        frame.unrealQuestFollowingActive = false
        return Client.SetTrackerFollowingOpacity(frame,
            type(percent) == "number" and percent
                or frame.unrealQuestFollowingOpacity or 0)
    end

    frame.unrealQuestFollowingActive = true
    local left = 4
    local right = -4
    PlaceFollowingTexture(frame.unrealQuestFollowingBackground, frame,
        left, right, top, bottom)

    local rings = frame.unrealQuestFollowingRings or {}
    local ringIndex = 1
    while ringIndex <= 3 do
        local expansion = ringIndex - 1
        local ring = rings[ringIndex] or {}
        local edgeIndex = 1
        while edgeIndex <= 4 do
            PlaceFollowingEdge(ring[edgeIndex], frame, edgeIndex,
                left - expansion, right + expansion,
                top - expansion, bottom + expansion)
            edgeIndex = edgeIndex + 1
        end
        ringIndex = ringIndex + 1
    end

    return Client.SetTrackerFollowingOpacity(frame,
        type(percent) == "number" and percent
            or frame.unrealQuestFollowingOpacity or 0)
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

function Client.SetTrackerHeaderButtons(frame, onNpcFinder, onCollapse)
    if not frame then
        return false
    end
    Client.SetObjectScript(frame.unrealQuestNpcFinder, "OnClick", onNpcFinder)
    Client.SetObjectScript(frame.unrealQuestCollapse, "OnClick", onCollapse)
    return true
end

function Client.SetTrackerCollapseLabel(frame, text)
    return Client.SetButtonLabel(frame and frame.unrealQuestCollapse, text)
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
    SetTrackerChildLayer(handle, window)
    -- Covers the header strip only, so the rows below keep their own clicks.
    if type(handle.SetPoint) == "function" then
        pcall(handle.SetPoint, handle, "TOPLEFT", window, "TOPLEFT", 0, 0)
        pcall(handle.SetPoint, handle, "TOPRIGHT", window, "TOPRIGHT",
            -(TRACKER_BUTTON_SIZE * TRACKER_HEADER_BUTTONS), 0)
    end
    Client.SetObjectSize(handle, nil, TRACKER_HEADER_HEIGHT)
    -- SetTrackerChildLayer raises it by frame level, never by strata: raising
    -- the handle's strata is one of the recorded failed drag approaches.
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
-- resize surface to hook and this builds its own. That same record's working
-- resize recipe is deliberately not Frame:StartSizing: a plain Button grip is
-- dragged, and while it moves the target frame's geometry is computed from the
-- grip's own position and applied on the shared driver.
function Client.CreateTrackerResizeGrip(window, name)
    local create = Resolve("CreateFrame")
    if not create or not window or type(name) ~= "string" then
        return nil
    end
    local ok, grip = pcall(create, "Button", name, window)
    if not ok or not grip then
        return nil
    end
    SetTrackerChildLayer(grip, window)
    Client.SetObjectSize(grip, 12, 12)
    if type(grip.SetPoint) == "function" then
        pcall(grip.SetPoint, grip, "BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)
    end
    if type(grip.EnableMouse) == "function" then
        pcall(grip.EnableMouse, grip, true)
    end
    if type(grip.RegisterForDrag) == "function" then
        pcall(grip.RegisterForDrag, grip, "LeftButton")
    end
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

-- Uses the confirmed GetCursorPosition/effective-scale rectangle test rather
-- than Frame:IsMouseOver, which has no runtime record on this client.
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
    SetTrackerChildLayer(button, window)
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
            -- Wide enough to clear the round quest dot drawn below at the
            -- row's own left edge, so a title never overlaps it.
            local labelInset = kind == "quest" and TRACKER_QUEST_MARK_INSET or 0
            pcall(label.SetPoint, label, "LEFT", button, "LEFT", labelInset, 0)
            pcall(label.SetJustifyH, label, "LEFT")
            -- Quest titles and objective text deliberately retain the
            -- client's default word wrapping. Their rendered FontString
            -- height is measured during layout so every second line expands
            -- its row. Zone headers remain single-line where this optional
            -- method exists.
            if kind == "zone" and type(label.SetWordWrap) == "function" then
                pcall(label.SetWordWrap, label, false)
            end
            StripShadow(label)
            button.unrealQuestLabel = label
            button.unrealQuestLabelInset = labelInset
        end
    end
    -- Every quest gets a small colour swatch that matches its objective dots
    -- on both maps. It identifies the quest without adding a tracked-state
    -- accent rectangle to the row. It is drawn with the very same round dot
    -- asset the maps draw an objective with (Client.MINIMAP_OBJECTIVE_TEXTURE),
    -- tinted the same way, so the tracker and the two maps agree about shape
    -- as well as colour rather than pairing a square here with a dot there.
    if kind == "quest" then
        local questMark = CreateSolid(button, "OVERLAY", 1, 1, 1, 1)
        if questMark then
            if type(questMark.SetTexture) == "function" then
                pcall(questMark.SetTexture, questMark, Client.MINIMAP_OBJECTIVE_TEXTURE)
            end
            pcall(questMark.SetPoint, questMark, "LEFT", button, "LEFT", 0, 0)
            pcall(questMark.SetWidth, questMark, TRACKER_QUEST_MARK_SIZE)
            pcall(questMark.SetHeight, questMark, TRACKER_QUEST_MARK_SIZE)
            pcall(questMark.Hide, questMark)
        end
        button.unrealQuestQuestMark = questMark

    end
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
        local textWidth = rowWidth - (row.unrealQuestLabelInset or 0)
            - (row.unrealQuestFollowingInsetRight or 0)
        if textWidth < 1 then
            textWidth = 1
        end
        pcall(label.SetWidth, label, textWidth)
        row.unrealQuestTextWidth = textWidth
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

function Client.SetTrackerRowFollowing(row, following)
    if not row then
        return false
    end
    row.unrealQuestFollowingInsetRight = 0
    return true
end

-- FontString:GetStringWidth is documented by this client and measures the
-- current display string in pixels. The tracker uses it to avoid shortening a
-- quest name while it still fits in the label. Missing or failing methods
-- return nil so its arithmetic fallback can keep the row contained.
function Client.MeasureTrackerRowTextWidth(row, text)
    local label = row and row.unrealQuestLabel
    if not label or type(label.SetText) ~= "function" or type(label.GetStringWidth) ~= "function" then
        return nil
    end
    local textOk = pcall(label.SetText, label, type(text) == "string" and text or "")
    if not textOk then
        return nil
    end
    local widthOk, width = pcall(label.GetStringWidth, label)
    if not widthOk or type(width) ~= "number" or width < 0 then
        return nil
    end
    return width
end

-- Region:GetHeight is documented to return at least the measured text height
-- for a FontString on this client. Read it only after the row has its final
-- label width and text, so wrapped quest titles report their rendered height.
function Client.MeasureTrackerRowTextHeight(row, text)
    local label = row and row.unrealQuestLabel
    if not label or type(label.SetText) ~= "function" or type(label.GetHeight) ~= "function" then
        return nil
    end
    local textOk = pcall(label.SetText, label, type(text) == "string" and text or "")
    if not textOk then
        return nil
    end
    local heightOk, height = pcall(label.GetHeight, label)
    if not heightOk or type(height) ~= "number" or height <= 0 then
        return nil
    end
    return height
end

-- Moves a quest row's title to `inset` pixels from the row's left edge and
-- records it, so the next Client.PlaceTrackerRow sizes the label to match.
-- Call it before placing the row, never after: the inset is what that call
-- turns into the label's width.
local function SetTrackerRowLabelInset(row, inset)
    local label = row and row.unrealQuestLabel
    if not label or row.unrealQuestLabelInset == inset then
        return
    end
    if type(label.ClearAllPoints) == "function" then
        pcall(label.ClearAllPoints, label)
    end
    pcall(label.SetPoint, label, "LEFT", row, "LEFT", inset, 0)
    row.unrealQuestLabelInset = inset
end

-- red nil hides the mark entirely, pulling the title left onto the row edge
-- so the row reads as one clean line rather than a title indented past an
-- empty gap. `texture` swaps the mark's own image: a live quest keeps the
-- round dot (Client.MINIMAP_OBJECTIVE_TEXTURE, the default) tinted to match
-- its objective dots on both maps, while a complete quest is handed
-- Client.COMPLETE_QUEST_TEXTURE instead -- the same bundled asset the map
-- pins already use for a turned-in quest -- tinted white so the icon reads in
-- its own colours. The texture is set on every call rather than only when it
-- changes because rows are pooled by kind and index, not by quest identity: a
-- row that carried the complete icon must not still show it once reused for
-- an ordinary in-progress quest.
function Client.SetTrackerRowQuestMark(row, red, green, blue, texture)
    local mark = row and row.unrealQuestQuestMark
    if not mark then
        return false
    end
    if not red then
        SetTrackerRowLabelInset(row, 0)
        return Client.HideObject(mark)
    end
    if texture == TRACKER_FOLLOWING_QUEST_TEXTURE then
        SetTrackerRowLabelInset(row, TRACKER_FOLLOWING_MARK_WIDTH + 3)
    else
        SetTrackerRowLabelInset(row, TRACKER_QUEST_MARK_INSET)
    end
    if type(mark.SetTexture) == "function" then
        pcall(mark.SetTexture, mark, texture or Client.MINIMAP_OBJECTIVE_TEXTURE)
    end
    -- The complete icon is re-anchored 1px right of the dot's own LEFT point
    -- to align with it: the icon's narrower box (below) leaves its checkmark
    -- sitting slightly left of where the round dot's centre reads on other
    -- rows, and this is what was confirmed to true it up.
    local markX = 0
    if texture == Client.COMPLETE_QUEST_TEXTURE then
        markX = 2
    elseif texture == TRACKER_FOLLOWING_QUEST_TEXTURE then
        -- The followed-quest marker sits 2px further left than the dot's own
        -- LEFT point: its authored artwork carries transparent padding down
        -- its right side, so anchoring it flush read as pushed inward.
        markX = -1
    end
    if mark.unrealQuestMarkX ~= markX and type(mark.ClearAllPoints) == "function"
        and type(mark.SetPoint) == "function" then
        pcall(mark.ClearAllPoints, mark)
        pcall(mark.SetPoint, mark, "LEFT", row, "LEFT", markX, 0)
        mark.unrealQuestMarkX = markX
    end
    if type(mark.SetWidth) == "function" and type(mark.SetHeight) == "function" then
        if texture == Client.COMPLETE_QUEST_TEXTURE then
            pcall(mark.SetHeight, mark, TRACKER_QUEST_MARK_SIZE)
            pcall(mark.SetWidth, mark,
                TRACKER_QUEST_MARK_SIZE * (TRACKER_COMPLETE_ICON_WIDTH / TRACKER_COMPLETE_ICON_HEIGHT))
        elseif texture == TRACKER_FOLLOWING_QUEST_TEXTURE then
            pcall(mark.SetWidth, mark, TRACKER_FOLLOWING_MARK_WIDTH)
            pcall(mark.SetHeight, mark, TRACKER_FOLLOWING_MARK_HEIGHT)
        else
            pcall(mark.SetWidth, mark, TRACKER_QUEST_MARK_SIZE)
            pcall(mark.SetHeight, mark, TRACKER_QUEST_MARK_SIZE)
        end
    end
    Client.SetSolidColor(mark, red, green, blue, 1)
    return Client.ShowObject(mark)
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

-- Hiding the panel once is not enough: the client shows it again by itself.
--
-- QuestWatch_Update "immediately shows the native tracked-objectives panel"
-- (knowledge.json / questwatch.public_refresh_after_watch_change), and the
-- client calls it from its own QUEST_LOG_UPDATE handling -- so accepting a
-- quest re-shows the panel with no addon on the stack. A one-shot Hide plus a
-- periodic re-hide therefore reads on screen as the native window flashing in
-- and blinking back out, for as long as the poll interval.
--
-- The guard closes that window: an OnShow handler that hides the frame in the
-- same frame it was shown. It is installed at most once (NATIVE_WATCH_GUARD_KEY)
-- and never removed, because SetScript(type, nil) does not detach a script on
-- this client -- so it must be inert, not absent, when the player turns hiding
-- off. That is what shouldHide is for: the handler asks, on every show, whether
-- hiding is still wanted, and does nothing when it is not. The client then owns
-- the panel again exactly as it did before the guard existed.
--
-- Still nothing but the frame's own Show/Hide is touched. QuestWatchFrame's
-- native OnEvent handler is never called -- that crashes this client
-- uncatchably, and remains a standing rule of this addon.
local NATIVE_WATCH_GUARD_KEY = "unrealQuestNativeWatchGuard"

function Client.InstallNativeQuestWatchGuard(shouldHide)
    if type(shouldHide) ~= "function" then
        return false
    end
    local frame = Client.GetNativeQuestWatchFrame()
    if not frame then
        return false
    end
    if Client.IsScriptChained(frame, NATIVE_WATCH_GUARD_KEY) then
        return true
    end

    -- Hiding from inside OnShow can dispatch further script traffic on this
    -- frame; the flag keeps a re-entrant show from recursing into the hide.
    local hiding = false
    local installed = Client.ChainScript(frame, "OnShow", function()
        if hiding then
            return
        end
        local ok, wanted = pcall(shouldHide)
        if not ok or not wanted then
            return
        end
        hiding = true
        Client.HideObject(frame)
        hiding = false
    end)
    if not installed then
        return false
    end
    Client.MarkScriptChained(frame, NATIVE_WATCH_GUARD_KEY)
    return true
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
-- The footer and gutters deliberately mirror unrealUI's settings panel -- a
-- 46px footer and 12px gutters -- so the content area a page is handed is the
-- same 496x428 in both hosts and a layout tuned in one is not re-tuned for the
-- other. The header is shorter here on purpose (32px, not unrealUI's 46): this
-- window's header carries only the wordmark and the language flags, and the
-- window sizes itself around the content box, so a trimmer header leaves the
-- content box untouched and just makes the whole window 14px shorter.
--
-- Nothing about the drag is re-derived here. The handle is the same shape the
-- tracker's is (frames.movable_drag_requires_button_handle, BEHAVIOR_VERIFIED):
-- a Button parented to the frame it moves, raised with SetFrameLevel and never
-- by a strata change, dragged through Client.StartFrameDrag.

-- 30% shorter than the footer and than unrealUI's own 46px header: it holds
-- only the wordmark and the flag row, both centred in it, and the content box
-- below is unchanged (the window just loses the 14px).
local SETTINGS_HEADER_HEIGHT = 32
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

    -- HIGH, where the tracker is LOW: this is a dialog the player opened on
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
            -- Top inset centres the ~14px wordmark in the header strip -- the
            -- same half-the-slack the flag row uses on the other side, plus 4px
            -- because the FontString's cap sits above its box top and the row
            -- otherwise reads high against the flags.
            pcall(title.SetPoint, title, "TOPLEFT", frame, "TOPLEFT",
                SETTINGS_ACCENT_WIDTH + SETTINGS_PADDING,
                -(math.floor((SETTINGS_HEADER_HEIGHT - 14) / 2) + 4))
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

-- One language flag button. Two surfaces use it: the settings header's own
-- language row (Core/Settings.lua), drawn only when unrealUI is not the one
-- deciding the language, and the quest log detail pane's per-quest translation
-- toggle (Quest/QuestLogButtons.lua).
--
-- No background, no border and no hover art: the flag texture owns the whole
-- face and selection is communicated by opacity alone, which is the treatment
-- unrealUI's identical row uses. A code whose artwork will not load keeps the
-- two-letter ASCII badge instead of an empty square, the same fallback shape
-- Client.CreateMinimapButton has for its gear.
--
-- Opacity goes through SetVertexColor, never Texture:SetAlpha: every other
-- surface in this file already composites that way, and the shading here has
-- to be exact for "which one is selected" to be readable at 18x14.
function Client.CreateFlagButton(parent, name, texturePath, fallbackLabel,
    width, height, onClick)
    local create = Resolve("CreateFrame")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, button = pcall(create, "Button", name, parent)
    if not ok or not button then
        return nil
    end

    Client.SetObjectSize(button, width, height)
    if type(button.EnableMouse) == "function" then
        pcall(button.EnableMouse, button, true)
    end
    if type(button.RegisterForClicks) == "function" then
        pcall(button.RegisterForClicks, button, "LeftButtonUp")
    end
    -- Raised well above the parent. In the settings header this is redundant by
    -- design -- the drag handle is already inset to clear the row
    -- (Client.CreateSettingsHandle's rightInset), so geometry decides and this
    -- only removes the cost of being one pixel wrong about it. In the quest log
    -- detail pane it is the mechanism: the flag sits over a host-owned panel
    -- that has no such reservation.
    if type(parent.GetFrameLevel) == "function" and type(button.SetFrameLevel) == "function" then
        local levelOk, level = pcall(parent.GetFrameLevel, parent)
        if levelOk and type(level) == "number" then
            pcall(button.SetFrameLevel, button, level + 20)
        end
    end

    local drawn = false
    if type(texturePath) == "string" and type(button.CreateTexture) == "function" then
        local iconOk, icon = pcall(button.CreateTexture, button, nil, "ARTWORK")
        if iconOk and icon and type(icon.SetTexture) == "function" then
            if pcall(icon.SetTexture, icon, texturePath) then
                if type(icon.SetAllPoints) == "function" then
                    pcall(icon.SetAllPoints, icon, button)
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
            "GameFontHighlightSmall")
        if labelOk and label then
            pcall(label.SetPoint, label, "CENTER", button, "CENTER", 0, 0)
            pcall(label.SetText, label,
                type(fallbackLabel) == "string" and fallbackLabel or "?")
            StripShadow(label)
            button.unrealQuestLabel = label
        end
    end

    if type(onClick) == "function" then
        Client.SetObjectScript(button, "OnClick", onClick)
    end
    return button
end

-- The artwork on an existing flag. The language is resolved by a poll that can
-- still be waiting on unrealUI when a flag is built (Core/Locale.lua), so a
-- flag created before that poll settled has to be able to change its face
-- without being rebuilt. Falls through to the ASCII badge when the button was
-- built without artwork in the first place, so both forms stay current.
function Client.SetFlagButtonTexture(button, texturePath, fallbackLabel)
    if not button then
        return false
    end
    local icon = button.unrealQuestIcon
    if icon and type(icon.SetTexture) == "function" and type(texturePath) == "string" then
        if pcall(icon.SetTexture, icon, texturePath) then
            return true
        end
    end
    local label = button.unrealQuestLabel
    if label and type(label.SetText) == "function" then
        return pcall(label.SetText, label,
            type(fallbackLabel) == "string" and fallbackLabel or "?") and true or false
    end
    return false
end

-- Selection and hover for one of those flags. `shade` is the icon's opacity;
-- the ASCII fallback cannot be shaded the same way and takes the accent or the
-- dim grey instead, so both forms say the same thing.
function Client.SetFlagButtonShade(button, shade, selected)
    if not button then
        return false
    end
    if button.unrealQuestIcon then
        Client.SetSolidColor(button.unrealQuestIcon, 1, 1, 1, shade)
    end
    local label = button.unrealQuestLabel
    if label and type(label.SetTextColor) == "function" then
        if selected then
            pcall(label.SetTextColor, label, UQ.colors.accent[1], UQ.colors.accent[2],
                UQ.colors.accent[3])
        else
            pcall(label.SetTextColor, label, 0.6, 0.6, 0.6)
        end
    end
    return true
end

-- The drag handle. Covers the header strip only, so the page below keeps its
-- own clicks. Same five-factor recipe as the tracker's handle.
--
-- `rightInset` stops the handle short of the header's right edge, leaving that
-- strip clickable. The handle is deliberately raised ten frame levels above the
-- window (below), which is what makes a drag anywhere on the header work -- and
-- equally what would make it swallow every click meant for a control drawn in
-- the header. Reserving the space geometrically is the fix unrealUI's own
-- settings header uses for its language flags, and it does not depend on frame
-- level deciding mouse ownership.
function Client.CreateSettingsHandle(window, name, rightInset)
    local create = Resolve("CreateFrame")
    if not create or not window or type(name) ~= "string" then
        return nil
    end
    local ok, handle = pcall(create, "Button", name, window)
    if not ok or not handle then
        return nil
    end
    if type(rightInset) ~= "number" or rightInset < 0 then
        rightInset = 0
    end
    if type(handle.SetPoint) == "function" then
        pcall(handle.SetPoint, handle, "TOPLEFT", window, "TOPLEFT", 0, 0)
        pcall(handle.SetPoint, handle, "TOPRIGHT", window, "TOPRIGHT", -rightInset, 0)
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

-- A tinted, outlined band on the settings page: one fill and four one-pixel
-- edges, in the caller's colour.
--
-- TEXTURES on the page itself, never a child Frame. A frame would draw above
-- the page's own regions whatever layer it asked for, so the band would cover
-- the very line it is drawn behind. As plain textures it sits under the
-- OVERLAY font strings (Client.CreateSettingsBody / Heading) and under the
-- child-frame controls placed on top of it, which is what a background has to
-- do. The one-pixel edges are four textures rather than a backdrop edge for
-- the reason recorded above FLAT_BORDER: a fractional backdrop edgeSize is not
-- reliably rasterized on this client.
--
-- Returned as a `uuiParts` composite, the same shape Client.CreateSettingsEditBox
-- hands back, so both hosts show and hide the whole band through one entry in
-- the page's widget list.
function Client.CreateSettingsPanel(parent, offsetX, offsetY, width, height,
    red, green, blue, fillAlpha, borderAlpha)
    local fill = CreateSolid(parent, "BACKGROUND", red, green, blue, fillAlpha)
    if not fill then
        return nil
    end
    pcall(fill.SetPoint, fill, "TOPLEFT", parent, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    if type(width) == "number" and width > 0 then
        pcall(fill.SetWidth, fill, width)
    end
    if type(height) == "number" and height > 0 then
        pcall(fill.SetHeight, fill, height)
    end

    local parts = { fill }
    local index = 1
    local total = table.getn(FLAT_EDGES)
    while index <= total do
        local anchor = FLAT_EDGES[index]
        local edge = CreateSolid(parent, "BORDER", red, green, blue, borderAlpha)
        if edge then
            pcall(edge.SetPoint, edge, anchor[1], fill, anchor[1], 0, 0)
            pcall(edge.SetPoint, edge, anchor[2], fill, anchor[2], 0, 0)
            if anchor[3] == "horizontal" then
                pcall(edge.SetHeight, edge, FLAT_BORDER_THICKNESS)
            else
                pcall(edge.SetWidth, edge, FLAT_BORDER_THICKNESS)
            end
            table.insert(parts, edge)
        end
        index = index + 1
    end

    return { fill = fill, uuiParts = parts }
end

-- A top-of-page tab. It is an ordinary addon-owned Button, not a native tab
-- template; selection only changes this addon's flat border, fill and label.
function Client.CreateSettingsTab(parent, name, text, offsetX, offsetY, width, height,
    onClick)
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

function Client.SetSettingsTabSelected(button, selected)
    if not button then
        return false
    end
    button.unrealQuestActive = selected and true or false
    if button.unrealQuestActive then
        SetFlatBorderColor(button, UQ.colors.accent[1], UQ.colors.accent[2],
            UQ.colors.accent[3], 1)
        if type(button.SetBackdropColor) == "function" then
            pcall(button.SetBackdropColor, button, UQ.colors.accent[1],
                UQ.colors.accent[2], UQ.colors.accent[3], 0.10)
        end
        local label = button.unrealQuestLabel
        if label and type(label.SetTextColor) == "function" then
            pcall(label.SetTextColor, label, 0.95, 0.78, 0.12)
        end
    else
        SetFlatBorderColor(button, FLAT_BORDER[1], FLAT_BORDER[2],
            FLAT_BORDER[3], FLAT_BORDER[4])
        if type(button.SetBackdropColor) == "function" then
            pcall(button.SetBackdropColor, button, FLAT_BACKGROUND[1],
                FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], FLAT_BACKGROUND[4])
        end
        local label = button.unrealQuestLabel
        if label and type(label.SetTextColor) == "function" then
            pcall(label.SetTextColor, label, 0.90, 0.90, 0.90)
        end
    end
    return true
end

-- Minimal scriptless native text input, matching focused probe
-- widgets.editbox_minimal_search.v1 (SUPPORTED / BEHAVIOR_VERIFIED). The
-- EditBox itself receives no SetScript calls and is never focused
-- programmatically. Callers submit through a separate Button, then read and
-- clear focus through the helpers below.
function Client.CreateSettingsEditBox(parent, name, offsetX, offsetY, width, height)
    local create = Resolve("CreateFrame")
    local font = ResolveObject("GameFontHighlightSmall")
    if not create or not parent or not font or type(name) ~= "string" then
        return nil
    end
    width = type(width) == "number" and width or 280
    height = type(height) == "number" and height or 25

    local borderOk, border = pcall(create, "Frame", name .. "Border", parent)
    if not borderOk or not border then
        return nil
    end
    Client.SetObjectSize(border, width, height)
    pcall(border.SetPoint, border, "TOPLEFT", parent, "TOPLEFT",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    local fill = CreateSolid(border, "BACKGROUND", 0.10, 0.10, 0.10, 1)
    if fill and type(fill.SetAllPoints) == "function" then
        pcall(fill.SetAllPoints, fill, border)
    end
    BuildFlatBorder(border)

    local editOk, editBox = pcall(create, "EditBox", name, border)
    if not editOk or not editBox then
        return nil
    end
    -- The EditBox draws its text at the TOP of its own height, not centred in
    -- it, so a box as tall as the border leaves the text riding the top edge.
    -- Give the EditBox only a single text line of height and centre that line
    -- inside the border instead.
    local lineHeight = height - 4
    if lineHeight > 14 then
        lineHeight = 14
    end
    Client.SetObjectSize(editBox, width - 12, lineHeight)
    -- The measured glyph baseline sits 3px high of the geometric centre here,
    -- so the line is nudged down by that much to read as centred.
    pcall(editBox.SetPoint, editBox, "CENTER", border, "CENTER", 0, -3)
    pcall(editBox.SetFontObject, editBox, font)
    pcall(editBox.SetTextColor, editBox, 1, 1, 1)
    pcall(editBox.SetJustifyH, editBox, "LEFT")
    pcall(editBox.SetTextInsets, editBox, 3, 3, 0, 0)
    pcall(editBox.SetAutoFocus, editBox, false)
    pcall(editBox.SetText, editBox, "")

    return {
        editBox = editBox,
        border = border,
        uuiParts = { border, editBox },
    }
end

-- Submitting the search with the Enter key instead of the button.
--
-- Deliberately inert. The ONLY measured evidence for an addon-owned EditBox on
-- this client is widgets.editbox_minimal_search.v1 (SUPPORTED /
-- BEHAVIOR_VERIFIED), and what it measured is a box carrying NO scripts at
-- all. The opposite case is measured too: widgets.editbox_focus_crash
-- (BROKEN / RUNTIME_FAILURE_CONFIRMED / USER_CONFIRMED_INGAME) lists a script
-- set of exactly OnTextChanged + OnEscapePressed + OnEnterPressed +
-- OnEditFocusGained/OnEditFocusLost as crashing the client on the first click
-- into the field -- a native crash, so not pcall-catchable. That set is a
-- bundle, so OnEnterPressed alone is neither cleared nor convicted by it.
--
-- Until a focused probe isolates OnEnterPressed on its own, this returns false
-- and attaches nothing, so the caller can be wired for the key today and the
-- capability flipped in one place once the evidence exists.
function Client.SetSettingsEditSubmitHandler(control, handler)
    local editBox = control and control.editBox
    if not editBox or type(handler) ~= "function" then
        return false
    end
    return false
end

function Client.GetSettingsEditText(control)
    local editBox = control and control.editBox
    if not editBox or type(editBox.GetText) ~= "function" then
        return ""
    end
    local ok, text = pcall(editBox.GetText, editBox)
    if not ok or type(text) ~= "string" then
        return ""
    end
    return text
end

function Client.SetSettingsEditText(control, text)
    local editBox = control and control.editBox
    if not editBox or type(editBox.SetText) ~= "function" then
        return false
    end
    return pcall(editBox.SetText, editBox, type(text) == "string" and text or "")
        and true or false
end

function Client.ClearSettingsEditFocus(control)
    local editBox = control and control.editBox
    if not editBox or type(editBox.ClearFocus) ~= "function" then
        return false
    end
    return pcall(editBox.ClearFocus, editBox) and true or false
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
            -- Full white: the control's own text is the option, and grey is
            -- reserved for the explanatory note under it (CreateSettingsBody).
            pcall(label.SetTextColor, label, 1, 1, 1)
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
local NPC_FILTER_FALLBACK_WIDTH = 196
local NPC_FILTER_ROW_HEIGHT = 20
local NPC_FILTER_PADDING = 6
local NPC_FILTER_TRACK_MARK_WIDTH = 4
local NPC_FILTER_TRACK_MARK_HEIGHT = NPC_FILTER_ROW_HEIGHT - 6
local NPC_FILTER_LABEL_OFFSET = 14
local NPC_FILTER_LABEL_ICON_GAP = 5
local NPC_FILTER_ICON_SIZE = 14
local NPC_FILTER_ICON_RIGHT_INSET = 3
-- An entry may ask for a one-pixel rule above it, dividing the service rows
-- from the world-node rows. The rule is a solid texture on the menu itself,
-- not a row, so it cannot be clicked or measured into the menu width.
local NPC_FILTER_SEPARATOR_HEIGHT = 1
local NPC_FILTER_SEPARATOR_GAP = 3
local NPC_FILTER_SEPARATOR_BLOCK =
    NPC_FILTER_SEPARATOR_GAP * 2 + NPC_FILTER_SEPARATOR_HEIGHT
local NPC_FILTER_SEPARATOR_COLOR = { 0.26, 0.26, 0.26, 1.00 }
-- Addon TGA paths must remain extensionless on this client; see
-- textures.addon_tga_paths_require_extensionless.
local NPC_SERVICE_ICON_ROOT = "Interface\\AddOns\\unrealQuest\\media\\icons\\"
Client.NPC_SERVICE_ICON_ROOT = NPC_SERVICE_ICON_ROOT
local npcFilterMenu = nil
local npcFilterRows = {}
local npcFilterSeparators = {}
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
    if row.unrealQuestCheckMark then
        if entry.checked then
            pcall(row.unrealQuestCheckMark.Show, row.unrealQuestCheckMark)
        else
            pcall(row.unrealQuestCheckMark.Hide, row.unrealQuestCheckMark)
        end
    end
    if row.unrealQuestLabel then
        pcall(row.unrealQuestLabel.SetText, row.unrealQuestLabel, entry.label or entry.key or "?")
        pcall(row.unrealQuestLabel.SetTextColor, row.unrealQuestLabel, 0.94, 0.94, 0.94)
    end
    if row.unrealQuestIcon then
        if type(entry.icon) == "string" then
            pcall(row.unrealQuestIcon.SetTexture, row.unrealQuestIcon,
                NPC_SERVICE_ICON_ROOT .. entry.icon)
            pcall(row.unrealQuestIcon.Show, row.unrealQuestIcon)
        else
            pcall(row.unrealQuestIcon.Hide, row.unrealQuestIcon)
        end
    end
end

local function GetNpcFilterSeparator(index)
    local menu = ResolveNpcFilterMenu()
    if not menu then
        return nil
    end
    local line = npcFilterSeparators[index]
    if line then
        return line
    end
    line = CreateSolid(menu, "OVERLAY",
        NPC_FILTER_SEPARATOR_COLOR[1], NPC_FILTER_SEPARATOR_COLOR[2],
        NPC_FILTER_SEPARATOR_COLOR[3], NPC_FILTER_SEPARATOR_COLOR[4])
    if not line then
        return nil
    end
    pcall(line.SetHeight, line, NPC_FILTER_SEPARATOR_HEIGHT)
    pcall(line.Hide, line)
    npcFilterSeparators[index] = line
    return line
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
    Client.SetObjectSize(button, NPC_FILTER_FALLBACK_WIDTH - NPC_FILTER_PADDING * 2,
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

    local checkMark = CreateSolid(button, "OVERLAY",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if checkMark then
        pcall(checkMark.SetPoint, checkMark, "LEFT", button, "LEFT", 4, 0)
        pcall(checkMark.SetWidth, checkMark, NPC_FILTER_TRACK_MARK_WIDTH)
        pcall(checkMark.SetHeight, checkMark, NPC_FILTER_TRACK_MARK_HEIGHT)
        pcall(checkMark.Hide, checkMark)
        button.unrealQuestCheckMark = checkMark
    end

    if type(button.CreateFontString) == "function" then
        local labelOk, label = pcall(
            button.CreateFontString, button, nil, "OVERLAY", "GameFontHighlightSmall")
        if labelOk and label then
            pcall(label.SetPoint, label, "LEFT", button, "LEFT", NPC_FILTER_LABEL_OFFSET, 0)
            pcall(label.SetJustifyH, label, "LEFT")
            StripShadow(label)
            button.unrealQuestLabel = label
        end
    end
    if type(button.CreateTexture) == "function" then
        local iconOk, icon = pcall(button.CreateTexture, button, nil, "ARTWORK")
        if iconOk and icon then
            pcall(icon.SetWidth, icon, NPC_FILTER_ICON_SIZE)
            pcall(icon.SetHeight, icon, NPC_FILTER_ICON_SIZE)
            pcall(icon.SetPoint, icon, "RIGHT", button, "RIGHT", -NPC_FILTER_ICON_RIGHT_INSET, 0)
            button.unrealQuestIcon = icon
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

-- A menu row needs just enough room for its label, a two-pixel breathing gap,
-- and the fixed service icon. GetStringWidth measures the inherited stock font
-- actually on screen, so a longer localized or class name expands the menu
-- instead of drawing underneath the icon. If a client ever refuses that read,
-- retain the previous roomy width rather than risk an overlap.
local function GetNpcFilterMenuWidth(total)
    local widest = 0
    local index = 1
    while index <= total do
        local row = npcFilterRows[index]
        local label = row and row.unrealQuestLabel
        if not label or type(label.GetStringWidth) ~= "function" then
            return NPC_FILTER_FALLBACK_WIDTH
        end
        local ok, width = pcall(label.GetStringWidth, label)
        if not ok or type(width) ~= "number" or width < 0 then
            return NPC_FILTER_FALLBACK_WIDTH
        end
        if width > widest then widest = width end
        index = index + 1
    end
    return NPC_FILTER_PADDING * 2 + NPC_FILTER_LABEL_OFFSET + widest
        + NPC_FILTER_LABEL_ICON_GAP + NPC_FILTER_ICON_SIZE + NPC_FILTER_ICON_RIGHT_INSET
end

local function SizeNpcFilterRow(row, menuWidth)
    if not row or type(menuWidth) ~= "number" then
        return
    end
    local rowWidth = menuWidth - NPC_FILTER_PADDING * 2
    Client.SetObjectSize(row, rowWidth, NPC_FILTER_ROW_HEIGHT)
    local label = row.unrealQuestLabel
    local labelWidth = rowWidth - NPC_FILTER_LABEL_OFFSET - NPC_FILTER_LABEL_ICON_GAP
        - NPC_FILTER_ICON_SIZE - NPC_FILTER_ICON_RIGHT_INSET
    if labelWidth < 1 then labelWidth = 1 end
    if label and type(label.SetWidth) == "function" then
        pcall(label.SetWidth, label, labelWidth)
    end
    row.unrealQuestLabelWidth = labelWidth
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
        end
        index = index + 1
    end

    local menuWidth = GetNpcFilterMenuWidth(total)
    -- One pass places rows and rules against a running offset, so a rule added
    -- or removed shifts everything below it without a second layout rule.
    local offset = NPC_FILTER_PADDING
    local separators = 0
    index = 1
    while index <= total do
        local row = npcFilterRows[index]
        local entry = entries[index]
        if type(entry) == "table" and entry.separator and index > 1 then
            local line = GetNpcFilterSeparator(separators + 1)
            if line then
                pcall(line.ClearAllPoints, line)
                pcall(line.SetWidth, line, menuWidth - NPC_FILTER_PADDING * 2)
                pcall(line.SetPoint, line, "TOPLEFT", menu, "TOPLEFT",
                    NPC_FILTER_PADDING, -(offset + NPC_FILTER_SEPARATOR_GAP))
                pcall(line.Show, line)
                separators = separators + 1
                offset = offset + NPC_FILTER_SEPARATOR_BLOCK
            end
        end
        if row then
            SizeNpcFilterRow(row, menuWidth)
            pcall(row.ClearAllPoints, row)
            pcall(row.SetPoint, row, "TOPLEFT", menu, "TOPLEFT", NPC_FILTER_PADDING, -offset)
            pcall(row.Show, row)
        end
        offset = offset + NPC_FILTER_ROW_HEIGHT
        index = index + 1
    end
    while npcFilterRows[index] do
        pcall(npcFilterRows[index].Hide, npcFilterRows[index])
        index = index + 1
    end
    local extra = separators + 1
    while npcFilterSeparators[extra] do
        pcall(npcFilterSeparators[extra].Hide, npcFilterSeparators[extra])
        extra = extra + 1
    end

    menu.unrealQuestContentWidth = menuWidth
    pcall(menu.SetWidth, menu, menuWidth)
    pcall(menu.SetHeight, menu, offset + NPC_FILTER_PADDING)
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
    index = 1
    while npcFilterSeparators[index] do
        Client.HideObject(npcFilterSeparators[index])
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

-- Proximity alert panel -----------------------------------------------------
-- The on-screen card World/RareAlert.lua raises when the player walks into
-- range of a rare or elite creature's recorded spawn, plus its sound.
--
-- SOUND. PlaySound(kitName) is the only audio route this client documents: it
-- looks the name up in SoundEntries and is SILENT for a name it does not know,
-- with no return value and no error. There is no PlaySoundFile among the 1054
-- globals in the client's own API reference, so an addon cannot ship or play
-- audio of its own here. The alert plays a kit the client already has, and
-- WHICH kit is a setting precisely because "unknown names are silent" means
-- the addon cannot verify one from Lua. "/uq rare sound <kit>" auditions one
-- and keeps it.
--
-- PANEL. Built from the same flat chrome as the settings window rather than a
-- native popup: nothing in this client's FrameXML is reachable as an alert
-- template, and the addon already owns this look. It is deliberately NOT
-- modal -- it takes no keyboard, dims nothing, and blocks no input outside its
-- own small box. A creature walking past is not worth taking the player's
-- hands away for.

-- Five rows, in the order a reader needs them:
--
--   1. WHAT HAPPENED -- "A rare is nearby". The card used to open on the
--      creature's name, which tells a player who has never seen this alert
--      before nothing about why their screen just changed.
--   2. WHICH creature.
--   3. What it IS -- rank and level.
--   4. How many times this character has defeated it.
--   5. How far away it is, rewritten live.
-- The quest navigator's arrow occupies the right side and carries direction.
--
-- The final two rows can change after the card goes up, so each has its own
-- setter and the other three are written once.
local ALERT_LAYOUT = {
    FALLBACK_WIDTH = 312,
    MIN_WIDTH = 200,
    MAX_WIDTH = 420,
    HEIGHT = 104,
    PADDING = 10,
    ACCENT_WIDTH = 2,
    CLOSE_SIZE = 14,
    TEXT_RIGHT_INSET = 76,
}

local ALERT_ROW_EYEBROW = 0
local ALERT_ROW_TITLE = 15
local ALERT_ROW_SUBTITLE = 36
local ALERT_ROW_KILLS = 54
local ALERT_ROW_DISTANCE = 70

function Client.PlayAlertSound(kitName)
    local play = Resolve("PlaySound")
    if not play or type(kitName) ~= "string" or kitName == "" then
        return false
    end
    -- No return value to check and no error on an unknown name: "the call was
    -- made" is the whole of what can honestly be reported from here.
    local ok = pcall(play, kitName)
    return ok and true or false
end

function Client.HasAlertSound()
    return Client.HasFunction("PlaySound")
end

-- Creates the alert card, hidden. `name` must not contain "-": this client
-- mangles hyphenated widget names.
function Client.CreateAlertWindow(name)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, frame = pcall(create, "Frame", name, parent)
    if not ok or not frame then
        return nil
    end

    -- HIGH, like the settings window: the card is a deliberate interruption
    -- and belongs over the ordinary panels rather than under them.
    if type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "HIGH")
    end
    -- Mouse on the card itself only, so its close button can be clicked.
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, true)
    end
    Client.SetObjectSize(frame, ALERT_LAYOUT.FALLBACK_WIDTH, ALERT_LAYOUT.HEIGHT)

    local background = CreateSolid(frame, "BACKGROUND",
        FLAT_BACKGROUND[1], FLAT_BACKGROUND[2], FLAT_BACKGROUND[3], 0.94)
    if background and type(background.SetAllPoints) == "function" then
        pcall(background.SetAllPoints, background, frame)
    end
    frame.unrealQuestBackground = background
    BuildFlatBorder(frame)

    -- The accent runs the full height here rather than a header's: there is no
    -- header rule on a card this short, so the bar is what says whose UI this
    -- is.
    local accent = CreateSolid(frame, "ARTWORK",
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3], 1)
    if accent then
        pcall(accent.SetPoint, accent, "TOPLEFT", frame, "TOPLEFT", 0, 0)
        pcall(accent.SetPoint, accent, "BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        pcall(accent.SetWidth, accent, ALERT_LAYOUT.ACCENT_WIDTH)
    end
    frame.unrealQuestAccent = accent

    local left = ALERT_LAYOUT.ACCENT_WIDTH + ALERT_LAYOUT.PADDING

    local function Row(template, offsetY, red, green, blue)
        if type(frame.CreateFontString) ~= "function" then
            return nil
        end
        local rowOk, row = pcall(frame.CreateFontString, frame, nil, "OVERLAY", template)
        if not rowOk or not row then
            return nil
        end
        pcall(row.SetPoint, row, "TOPLEFT", frame, "TOPLEFT", left, offsetY)
        pcall(row.SetPoint, row, "TOPRIGHT", frame, "TOPRIGHT",
            -ALERT_LAYOUT.TEXT_RIGHT_INSET, offsetY)
        if type(row.SetJustifyH) == "function" then
            pcall(row.SetJustifyH, row, "LEFT")
        end
        if red and type(row.SetTextColor) == "function" then
            pcall(row.SetTextColor, row, red, green, blue)
        end
        StripShadow(row)
        return row
    end

    -- The accent goes on the WHY, not on the name: it is the line that has to
    -- be readable out of the corner of an eye, and the name below it is
    -- already the largest text on the card.
    frame.unrealQuestEyebrow = Row("GameFontNormalSmall",
        -(ALERT_LAYOUT.PADDING + ALERT_ROW_EYEBROW),
        UQ.colors.accent[1], UQ.colors.accent[2], UQ.colors.accent[3])
    frame.unrealQuestTitle = Row("GameFontNormal",
        -(ALERT_LAYOUT.PADDING + ALERT_ROW_TITLE), 0.96, 0.96, 0.96)
    frame.unrealQuestSubtitle = Row("GameFontHighlightSmall",
        -(ALERT_LAYOUT.PADDING + ALERT_ROW_SUBTITLE), 0.72, 0.72, 0.72)
    frame.unrealQuestKills = Row("GameFontNormalSmall",
        -(ALERT_LAYOUT.PADDING + ALERT_ROW_KILLS), 0.72, 0.72, 0.72)
    frame.unrealQuestBody = Row("GameFontNormalSmall",
        -(ALERT_LAYOUT.PADDING + ALERT_ROW_DISTANCE), 0.86, 0.86, 0.86)

    -- The quest navigator's arrow only -- no arc, distance label or separate
    -- frame. It uses the same four-atlas texture and the same frame selector,
    -- so the direction seen here cannot drift from the quest navigator's
    -- convention or rendering technique.
    if type(frame.CreateTexture) == "function" then
        local arrowOk, arrow = pcall(frame.CreateTexture, frame, nil, "ARTWORK")
        if arrowOk and arrow then
            pcall(arrow.SetTexture, arrow,
                Client.NAVIGATOR_ARROW_TEXTURE_PREFIX .. "0")
            pcall(arrow.SetPoint, arrow, "RIGHT", frame, "RIGHT",
                -10, -4)
            pcall(arrow.SetWidth, arrow, 56)
            pcall(arrow.SetHeight, arrow, 56)
            frame.unrealQuestArrow = arrow
            frame.unrealQuestArrowAtlas = 0
        end
    end

    -- The drag surface is the WHOLE card, not a header strip. This is a small
    -- card with one control on it, so there is no header worth carving out --
    -- and a card that lands over something the player is reading has to be
    -- pushable from wherever the cursor already is.
    --
    -- Same measured recipe as the tracker window (docs/QUEST-TRACKER.md): a
    -- Button, parented to the frame it moves, raised by frame LEVEL and never
    -- by strata -- raising a handle's strata is one of the recorded failed
    -- drag approaches. SetMovable and the StartMoving warm-up happen inside
    -- Client.StartFrameDrag, immediately before each drag.
    local handleOk, handle = pcall(create, "Button", name .. "Drag", frame)
    if handleOk and handle then
        if type(handle.SetFrameStrata) == "function" then
            pcall(handle.SetFrameStrata, handle, "PARENT")
        end
        -- +1, while the close button below is created at +12: the handle
        -- covers the entire card, close button included, so it has to stay
        -- underneath it or the card could never be dismissed.
        if type(frame.GetFrameLevel) == "function"
            and type(handle.SetFrameLevel) == "function" then
            local levelOk, level = pcall(frame.GetFrameLevel, frame)
            if levelOk and type(level) == "number" then
                pcall(handle.SetFrameLevel, handle, level + 1)
            end
        end
        -- Two explicit corners rather than SetAllPoints, the same way the
        -- tracker handle is anchored: this layer only ever uses SetPoint on a
        -- frame, and the card's size is fixed, so nothing is gained by the
        -- shortcut.
        if type(handle.SetPoint) == "function" then
            pcall(handle.SetPoint, handle, "TOPLEFT", frame, "TOPLEFT", 0, 0)
            pcall(handle.SetPoint, handle, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        end
        if type(handle.EnableMouse) == "function" then
            pcall(handle.EnableMouse, handle, true)
        end
        if type(handle.RegisterForDrag) == "function" then
            pcall(handle.RegisterForDrag, handle, "LeftButton")
        end
        frame.unrealQuestHandle = handle
    end

    local close = Client.CreateTextButton(frame, name .. "Close",
        ALERT_LAYOUT.CLOSE_SIZE, ALERT_LAYOUT.CLOSE_SIZE, "x")
    if close then
        pcall(close.SetPoint, close, "TOPRIGHT", frame, "TOPRIGHT", -6, -6)
        frame.unrealQuestClose = close
    end

    pcall(frame.Hide, frame)
    return frame
end

-- FontString:GetStringWidth is documented by this client and measures the
-- inherited stock font actually drawn on screen. Size from the widest localized
-- row, plus the fixed left text inset and the arrow/close-button lane on the
-- right. A bounded width keeps a very long creature name from spanning the
-- screen; failure retains the original roomy width rather than risking overlap.
function Client.SizeAlertWindowToText(frame, rows)
    local widest = 0
    local index = 1
    while index <= 5 do
        local row = rows[index]
        if not row or type(row.GetStringWidth) ~= "function" then
            Client.SetObjectSize(frame, ALERT_LAYOUT.FALLBACK_WIDTH, ALERT_LAYOUT.HEIGHT)
            return
        end
        local ok, width = pcall(row.GetStringWidth, row)
        if not ok or type(width) ~= "number" or width < 0 then
            Client.SetObjectSize(frame, ALERT_LAYOUT.FALLBACK_WIDTH, ALERT_LAYOUT.HEIGHT)
            return
        end
        if width > widest then
            widest = width
        end
        index = index + 1
    end

    local width = ALERT_LAYOUT.ACCENT_WIDTH + ALERT_LAYOUT.PADDING + widest
        + ALERT_LAYOUT.TEXT_RIGHT_INSET
    width = math.ceil(width)
    if width < ALERT_LAYOUT.MIN_WIDTH then
        width = ALERT_LAYOUT.MIN_WIDTH
    elseif width > ALERT_LAYOUT.MAX_WIDTH then
        width = ALERT_LAYOUT.MAX_WIDTH
    end
    Client.SetObjectSize(frame, width, ALERT_LAYOUT.HEIGHT)
end

function Client.SetAlertWindowText(frame, eyebrow, title, subtitle, kills, body)
    if not frame then
        return false
    end
    local rows = { frame.unrealQuestEyebrow, frame.unrealQuestTitle,
        frame.unrealQuestSubtitle, frame.unrealQuestKills, frame.unrealQuestBody }
    local texts = { eyebrow, title, subtitle, kills, body }
    local index = 1
    while index <= 5 do
        local row = rows[index]
        if row and type(row.SetText) == "function" then
            pcall(row.SetText, row, type(texts[index]) == "string" and texts[index] or "")
        end
        index = index + 1
    end
    Client.SizeAlertWindowToText(frame, rows)
    return true
end

-- The one row that is rewritten while the card is up, on its own so the live
-- tick costs a single SetText rather than four.
function Client.SetAlertWindowDistance(frame, text)
    local row = frame and frame.unrealQuestBody
    if not row or type(row.SetText) ~= "function" then
        return false
    end
    local ok = pcall(row.SetText, row, type(text) == "string" and text or "")
    return ok and true or false
end

-- A rare defeated while its card is still visible advances the count without
-- rewriting the live distance row or the other card text.
function Client.SetAlertWindowKillCount(frame, text)
    local row = frame and frame.unrealQuestKills
    if not row or type(row.SetText) ~= "function" then
        return false
    end
    local ok = pcall(row.SetText, row, type(text) == "string" and text or "")
    return ok and true or false
end

function Client.SetAlertWindowClose(frame, handler)
    local close = frame and frame.unrealQuestClose
    if not close then
        return false
    end
    return Client.SetObjectScript(close, "OnClick", handler)
end

-- Wires the card's drag handle. A refused drag is reported visibly by the
-- caller, the same rule the tracker follows: a drag that silently does nothing
-- is the exact failure mode this client already produced once.
function Client.SetAlertWindowDrag(frame, onStart, onStop)
    local handle = frame and frame.unrealQuestHandle
    if not handle then
        return false
    end
    local started = Client.SetObjectScript(handle, "OnDragStart", onStart)
    local stopped = Client.SetObjectScript(handle, "OnDragStop", onStop)
    return started and stopped and true or false
end

-- Anchors the card to a point of UIParent. This places the DEFAULT position;
-- once the player has dragged the card, World/RareAlert.lua restores it
-- through Client.SetFrameAnchor from the anchor Client.GetFrameAnchor captured
-- (which undoes this client's inverted GetPoint Y -- docs/QUEST-TRACKER.md,
-- "the two ways GetPoint lies").
function Client.PositionAlertWindow(frame, point, offsetX, offsetY)
    local parent = ResolveObject("UIParent")
    if not frame or not parent or type(frame.SetPoint) ~= "function" then
        return false
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local anchor = type(point) == "string" and point or "TOP"
    local ok = pcall(frame.SetPoint, frame, anchor, parent, anchor,
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    return ok and true or false
end

-- Quest navigator -------------------------------------------------------------
--
-- The arc-and-arrow direction display: a fixed decorative arc whose top-centre
-- ornament means "straight ahead", and an arrow rotating about the same pivot
-- to point at the followed quest. See docs/HUD-NAVIGATOR.md.
--
-- Both textures are addon-owned TGAs referenced WITHOUT their extension. That
-- is measured, not stylistic: `textures.addon_tga_paths_require_extensionless`
-- (USER_CONFIRMED_INGAME) records that appending ".tga" silently produces an
-- invisible texture here. The same record is why they are TGA rather than the
-- PNG they were authored as, and the existing 19x32 ActiveQuestIcon.tga is why
-- neither needs padding to a power of two.
-- These deliberately do not reuse either earlier arrow path. The client kept
-- drawing NavigationArrow after its file was deleted and /reload was run,
-- proving texture resources survive a UI reload. Fresh paths are required to
-- make every higher-resolution atlas decode in the current client process.
Client.NAVIGATOR_ARROW_TEXTURE_PREFIX =
    "Interface\\AddOns\\unrealQuest\\media\\NavigationArrowFrames"
Client.NAVIGATOR_ARC_TEXTURE = "Interface\\AddOns\\unrealQuest\\media\\NavigationArc"
Client.NAVIGATOR_ARROW_FRAMES = 64
Client.NAVIGATOR_ARROW_ATLASES = 4
Client.NAVIGATOR_ARROW_FRAMES_PER_ATLAS = 16
Client.NAVIGATOR_ARROW_COLUMNS = 4

-- Selects the nearest pre-rotated arrow from four 4x4 atlases.
--
-- The client accepts the documented eight-argument SetTexCoord form, but the
-- first live visual test on 2026-09-01 showed a non-rigid transform rather than
-- a turning arrow. Four-argument atlas selection is already proven by pfQuest's
-- TomTom-derived arrow on this client, and never samples outside 0..1. The atlas
-- is generated from the authored PNG by tools/make_navigator_textures.py as an
-- RLE type-10 TGA matching pfQuest's working 512x512 atlas. The full-size
-- uncompressed type-2 build drew as diagonal corruption on this client.
function Client.SetNavigatorArrowAngle(frame, angle)
    local texture = frame and frame.unrealQuestArrow
    if not texture or type(texture.SetTexCoord) ~= "function" then
        return false
    end
    if type(angle) ~= "number" or angle ~= angle then
        return false
    end

    local turn = math.pi * 2
    local normalized = angle - math.floor(angle / turn) * turn
    local cell = math.floor(normalized / turn * Client.NAVIGATOR_ARROW_FRAMES + 0.5)
    if cell >= Client.NAVIGATOR_ARROW_FRAMES then
        cell = 0
    end
    local atlas = math.floor(cell / Client.NAVIGATOR_ARROW_FRAMES_PER_ATLAS)
    local localCell = cell - atlas * Client.NAVIGATOR_ARROW_FRAMES_PER_ATLAS
    local row = math.floor(localCell / Client.NAVIGATOR_ARROW_COLUMNS)
    local column = localCell - row * Client.NAVIGATOR_ARROW_COLUMNS
    local left = column / Client.NAVIGATOR_ARROW_COLUMNS
    local right = (column + 1) / Client.NAVIGATOR_ARROW_COLUMNS
    local top = row / Client.NAVIGATOR_ARROW_COLUMNS
    local bottom = (row + 1) / Client.NAVIGATOR_ARROW_COLUMNS
    local ok = true
    if frame.unrealQuestArrowAtlas ~= atlas then
        ok = pcall(texture.SetTexture, texture,
            Client.NAVIGATOR_ARROW_TEXTURE_PREFIX .. tostring(atlas))
        if ok then
            frame.unrealQuestArrowAtlas = atlas
        end
    end
    if ok then
        ok = pcall(texture.SetTexCoord, texture, left, right, top, bottom)
    end
    if ok then
        frame.unrealQuestArrowFrame = cell
    end
    return ok and true or false
end

-- The atlas still needs the ordinary four-argument SetTexCoord form. Check it
-- once at load so a client that cannot select a frame never shows a frozen and
-- therefore actively misleading arrow.
function Client.HasNavigatorAtlasRotation()
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent then
        return false
    end
    local okFrame, probe = pcall(create, "Frame", nil, parent)
    if not okFrame or not probe or type(probe.CreateTexture) ~= "function" then
        return false
    end
    local okTexture, texture = pcall(probe.CreateTexture, probe, nil, "BACKGROUND")
    if not okTexture or not texture then
        return false
    end
    return pcall(texture.SetTexCoord, texture, 0, 0.25, 0, 0.25) and true or false
end

-- The arrow sits below the arc's centre so its tip no longer crowds the
-- forward ornament. The whole navigator renders at half scale, making these
-- fourteen authored pixels a seven-pixel visual adjustment in game.
-- Removing the one-line quest card must not pull the dial up into the card's
-- old screen position. Keep its former 74px card height plus 8px gap as a
-- transparent, mouse-disabled offset above the dial.
-- One layout record also keeps this already-large compatibility chunk below
-- Lua's 200-local compilation limit.
local NAVIGATOR_LAYOUT = { arrowOffsetY = -14, dialTopOffset = 82 }

-- Builds the navigator's arc and arrow.
--
-- One frame tree rather than two siblings, so the module moves and scales it
-- with a single anchor and the arc and arrow cannot drift apart. The container
-- owns no mouse at all -- this sits in the middle of the screen
-- over the 3D world, and a transparent frame there that swallowed clicks would
-- make the game unplayable in a way that is hard to attribute.
--
-- `withTitle` adds one caption above the arc. The quest navigator does not ask
-- for it: the quest it is following is already named by the tracker, so a
-- second copy of that title in the middle of the screen would be noise. The
-- mob navigator does, because nothing else on screen says which tracked
-- creature its arrow is aiming at.
function Client.CreateNavigator(name, arcWidth, arrowSize, withTitle)
    local create = Resolve("CreateFrame")
    local parent = ResolveObject("UIParent")
    if not create or not parent or type(name) ~= "string" then
        return nil
    end
    local ok, frame = pcall(create, "Frame", name, parent)
    if not ok or not frame then
        return nil
    end

    -- Keep the dial, distance and drag surface below ordinary interface windows.
    -- SetFrameStrata and PARENT are documented by the client's Frame reference.
    if type(frame.SetFrameStrata) == "function" then
        pcall(frame.SetFrameStrata, frame, "BACKGROUND")
    end
    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, false)
    end

    if type(arcWidth) ~= "number" or arcWidth <= 0 then
        arcWidth = 220
    end
    if type(arrowSize) ~= "number" or arrowSize <= 0 then
        arrowSize = 130
    end
    pcall(frame.SetWidth, frame, arcWidth)
    pcall(frame.SetHeight, frame, NAVIGATOR_LAYOUT.dialTopOffset + arrowSize)

    -- The arc and the arrow ------------------------------------------------
    -- The arrow is shifted down a few visual pixels from the arc's centre so
    -- its tip leaves the forward ornament clear. The arc is drawn first and one
    -- layer below so the arrow always reads over it.
    local okDial, dial = pcall(create, "Frame", name .. "Dial", frame)
    if okDial and dial then
        if type(dial.SetFrameStrata) == "function" then
            pcall(dial.SetFrameStrata, dial, "PARENT")
        end
        pcall(dial.SetPoint, dial, "TOP", frame, "TOP", 0,
            -NAVIGATOR_LAYOUT.dialTopOffset)
        pcall(dial.SetWidth, dial, arcWidth)
        pcall(dial.SetHeight, dial, arrowSize)
        if type(dial.EnableMouse) == "function" then
            pcall(dial.EnableMouse, dial, false)
        end

        local okArc, arc = pcall(dial.CreateTexture, dial, nil, "BACKGROUND")
        if okArc and arc then
            pcall(arc.SetTexture, arc, Client.NAVIGATOR_ARC_TEXTURE)
            pcall(arc.SetPoint, arc, "CENTER", dial, "CENTER", 0, 0)
            pcall(arc.SetWidth, arc, arcWidth)
            -- The source art is 512x257; holding that ratio is what keeps the
            -- top ornament centred over the arrow's pivot.
            pcall(arc.SetHeight, arc, arcWidth * 257 / 512)
        end
        frame.unrealQuestArc = arc

        local okArrow, arrow = pcall(dial.CreateTexture, dial, nil, "ARTWORK")
        if okArrow and arrow then
            pcall(arrow.SetTexture, arrow,
                Client.NAVIGATOR_ARROW_TEXTURE_PREFIX .. "0")
            frame.unrealQuestArrowAtlas = 0
            pcall(arrow.SetPoint, arrow, "CENTER", dial, "CENTER", 0,
                NAVIGATOR_LAYOUT.arrowOffsetY)
            -- Square because every pre-rotated atlas cell is square; changing
            -- the region's aspect here would stretch every direction.
            pcall(arrow.SetWidth, arrow, arrowSize)
            pcall(arrow.SetHeight, arrow, arrowSize)
        end
        frame.unrealQuestArrow = arrow

        -- The readout is anchored to the arrow rather than the dial so its
        -- horizontal centre cannot drift if either artwork region changes.
        if arrow and type(dial.CreateFontString) == "function" then
            local distanceOk, distance = pcall(
                dial.CreateFontString, dial, nil, "OVERLAY", "GameFontNormal")
            if distanceOk and distance then
                pcall(distance.SetPoint, distance, "TOP", arrow, "BOTTOM", 0, -8)
                if type(distance.SetWidth) == "function" then
                    -- The quest navigator adds a localized ETA beside the yard
                    -- count. Use the arc's width so the centred row is not clipped.
                    pcall(distance.SetWidth, distance, arcWidth)
                end
                if type(distance.SetJustifyH) == "function" then
                    pcall(distance.SetJustifyH, distance, "CENTER")
                end
                if type(distance.SetTextColor) == "function" then
                    pcall(distance.SetTextColor, distance, 1, 1, 1)
                end
                frame.unrealQuestDistance = distance
            end
        end

        -- The caption sits above the arc rather than below the distance, so
        -- the arrow keeps the bottom of the tree and a long creature name
        -- cannot push the yard readout around. It is anchored to the arc, not
        -- to the dial, for the same reason the readout is anchored to the
        -- arrow: the artwork owns the layout, so changing a region's size
        -- moves the text with it instead of leaving a gap.
        if withTitle and arc and type(dial.CreateFontString) == "function" then
            local titleOk, title = pcall(
                dial.CreateFontString, dial, nil, "OVERLAY", "GameFontNormal")
            if titleOk and title then
                pcall(title.SetPoint, title, "BOTTOM", arc, "TOP", 0, 4)
                if type(title.SetWidth) == "function" then
                    pcall(title.SetWidth, title, arcWidth)
                end
                if type(title.SetJustifyH) == "function" then
                    pcall(title.SetJustifyH, title, "CENTER")
                end
                if type(title.SetTextColor) == "function" then
                    local accent = UQ.colors and UQ.colors.accent or { 1, 0.65, 0 }
                    pcall(title.SetTextColor, title, accent[1], accent[2], accent[3])
                end
                frame.unrealQuestTitle = title
            end
        end
    end
    frame.unrealQuestDial = dial

    -- The visible dial is the drag surface. The container itself stays
    -- mouse-disabled so it cannot swallow unrelated clicks over the 3D world.
    -- The construction is
    -- the measured movable-frame recipe from docs/QUEST-TRACKER.md: a Button,
    -- parented to the frame it moves, raised by frame level, and registered for
    -- left-button dragging. StartMovable and the warm-up happen at drag time in
    -- Client.StartFrameDrag.
    local handleOk, handle = pcall(create, "Button", name .. "Drag", frame)
    if handleOk and handle and dial then
        if type(handle.SetFrameStrata) == "function" then
            pcall(handle.SetFrameStrata, handle, "PARENT")
        end
        if type(frame.GetFrameLevel) == "function"
            and type(handle.SetFrameLevel) == "function" then
            local levelOk, level = pcall(frame.GetFrameLevel, frame)
            if levelOk and type(level) == "number" then
                pcall(handle.SetFrameLevel, handle, level + 1)
            end
        end
        if type(handle.SetPoint) == "function" then
            pcall(handle.SetPoint, handle, "TOPLEFT", dial, "TOPLEFT", 0, 0)
            pcall(handle.SetPoint, handle, "BOTTOMRIGHT", dial, "BOTTOMRIGHT", 0, 0)
        end
        if type(handle.EnableMouse) == "function" then
            pcall(handle.EnableMouse, handle, true)
        end
        if type(handle.RegisterForDrag) == "function" then
            pcall(handle.RegisterForDrag, handle, "LeftButton")
        end
        frame.unrealQuestHandle = handle
    end

    pcall(frame.Hide, frame)
    return frame
end

function Client.SetNavigatorDrag(frame, onStart, onStop)
    local handle = frame and frame.unrealQuestHandle
    if not handle then
        return false
    end
    local started = Client.SetObjectScript(handle, "OnDragStart", onStart)
    local stopped = Client.SetObjectScript(handle, "OnDragStop", onStop)
    return started and stopped and true or false
end

-- Tints the arrow. Distance feedback is a colour and an alpha rather than a
-- flash: the marker sits in the middle of the view and anything strobing there
-- is unusable for the hours a levelling session lasts.
function Client.SetNavigatorArrowTint(frame, red, green, blue, alpha)
    if not frame or not frame.unrealQuestArrow then
        return false
    end
    local arrow = frame.unrealQuestArrow
    if type(arrow.SetVertexColor) ~= "function" then
        return false
    end
    return pcall(arrow.SetVertexColor, arrow, red, green, blue, alpha) and true or false
end

function Client.SetNavigatorArcAlpha(frame, alpha)
    if not frame or not frame.unrealQuestArc then
        return false
    end
    local arc = frame.unrealQuestArc
    if type(arc.SetAlpha) ~= "function" then
        return false
    end
    return pcall(arc.SetAlpha, arc, alpha) and true or false
end

function Client.RotateNavigatorArrow(frame, angle)
    return Client.SetNavigatorArrowAngle(frame, angle)
end

function Client.ShowNavigatorArrow(frame, shown)
    if not frame or not frame.unrealQuestArrow then
        return false
    end
    local arrow = frame.unrealQuestArrow
    local method = shown and arrow.Show or arrow.Hide
    if type(method) ~= "function" then
        return false
    end
    return pcall(method, arrow) and true or false
end

function Client.SetNavigatorDistanceText(frame, text)
    local label = frame and frame.unrealQuestDistance
    if not label or type(label.SetText) ~= "function" then
        return false
    end
    local value = type(text) == "string" and text or ""
    if frame.unrealQuestDistanceValue == value then
        return true
    end
    if not pcall(label.SetText, label, value) then
        return false
    end
    frame.unrealQuestDistanceValue = value
    return true
end

-- The caption above the arc. Absent on a navigator built without one, which
-- reports false rather than raising: the mob navigator is the only caller and
-- an unnamed target is a legitimate state there.
function Client.SetNavigatorTitleText(frame, text)
    local label = frame and frame.unrealQuestTitle
    if not label or type(label.SetText) ~= "function" then
        return false
    end
    local value = type(text) == "string" and text or ""
    if frame.unrealQuestTitleValue == value then
        return true
    end
    if not pcall(label.SetText, label, value) then
        return false
    end
    frame.unrealQuestTitleValue = value
    return true
end

-- Places the navigator at its saved UIParent-relative anchor and applies the
-- complete-tree scale before it is shown.
function Client.PositionNavigator(frame, offsetX, offsetY, scale, point, relativePoint)
    if not frame or type(frame.SetPoint) ~= "function" then
        return false
    end
    local parent = ResolveObject("UIParent")
    if not parent then
        return false
    end
    if type(scale) == "number" and scale > 0 and type(frame.SetScale) == "function" then
        pcall(frame.SetScale, frame, scale)
    end
    if type(frame.ClearAllPoints) == "function" then
        pcall(frame.ClearAllPoints, frame)
    end
    local ok = pcall(frame.SetPoint, frame,
        type(point) == "string" and point or "TOP", parent,
        type(relativePoint) == "string" and relativePoint or "CENTER",
        type(offsetX) == "number" and offsetX or 0,
        type(offsetY) == "number" and offsetY or 0)
    if not ok then
        return false
    end
    -- CreateNavigator leaves the frame hidden, so placing it is only half of
    -- showing it. Leaving this out produced the exact failure that is hardest
    -- to read from a bug report: every counter climbing, zero failures, and
    -- nothing on screen -- because positioning a hidden frame succeeds.
    pcall(frame.Show, frame)
    return true
end

-- Frame census -------------------------------------------------------------
-- GetNumFrames is a single cheap read that returns the client's own count of
-- live frame objects. Measured 2026-09-09 (UnrealRuntimeProbe 1.46.1, group
-- mmarrowwalk): it returned 4486, exactly the length of a full EnumerateFrames
-- walk, so it is a real count and not a stub the way GetNumRegions is.
--
-- It is a diagnostic only. Nothing in the addon branches on it -- it exists so
-- "/uq status" can show whether this addon's pools are leaking frames across a
-- session, which is otherwise invisible from inside the game. The sibling walk
-- API is deliberately NOT wrapped: a full pass costs ~1.9 s of frozen client,
-- and no question this addon has is worth that.
function Client.GetFrameCount()
    local ok, count = Call0("GetNumFrames")
    if not ok or type(count) ~= "number" or count <= 0 then
        return nil
    end
    return count
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

-- The alert sound. "documented" and no better: the client API reference
-- carries PlaySound, but an unknown SoundEntries name is silent rather than an
-- error, so nothing measurable comes back from a call and no probe can promote
-- this. Which kit actually makes a noise is settled by the player's ears --
-- "/uq rare sound <kit>".
DeclareFunction("alertSound", "PlaySound", "documented",
    "client API reference; PlaySound looks up a SoundEntries kit name and is silent for one it does "
    .. "not know, so a successful call is not evidence a sound played. No PlaySoundFile exists among "
    .. "this client's documented globals, so the addon cannot play audio of its own")
DeclareFunction("rareKillClassification", "UnitClassification", "documented",
    "client API reference; used with a localized target name to reject ordinary or ambiguous "
    .. "creatures before recording a rare-alert kill")
DeclareFunction("rareKillDeathState", "UnitIsDead", "documented",
    "client API reference; the counter observes one living target become dead, because no verified "
    .. "combat-log death event or creature GUID is available")
DeclareFunction("rareKillCombatState", "UnitAffectingCombat", "documented",
    "client API reference; both player and living target must have carried the combat flag before "
    .. "the death transition is attributed to this character")
DeclareFunction("frameCount", "GetNumFrames", "verified",
    "measured 2026-09-09: returned 4486, matching a full EnumerateFrames walk exactly, so the count "
    .. "is real rather than a stub. Diagnostic only -- reported by /uq status, never branched on")
DeclareFunction("time", "GetTime", "verified",
    "GetTime measured accurate to wall clock; sole sanctioned elapsed-time source")
DeclareFunction("questLogSize", "GetNumQuestLogEntries", "verified",
    "exercised by the questtrack probe against a live quest log")
DeclareFunction("questLogEntry", "GetQuestLogTitle", "verified",
    "six-value tuple captured by the questtrack probe and matching the client API reference")
DeclareFunction("questLogPartyPeers", "IsUnitOnQuest", "documented",
    "client API reference; answers whether one party member shares the quest at a quest log "
    .. "index, and yields no value rather than false when it cannot. Not runtime-probed, so the "
    .. "party count on a quest log row is absent rather than wrong when the call is missing")
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
DeclareFunction("mapZoneNames", "GetMapZones", "documented",
    "client API reference; not runtime-probed. With GetCurrentMapZone as the index it names the "
    .. "zone the map is showing, which no subzone can shadow -- the route the pin layer prefers")
DeclareFunction("instanceDetect", "IsInInstance", "documented",
    "client API reference: returns whether the current map is a dungeon, raid or PvP instance, and "
    .. "nothing about which kind. Not runtime-probed. Used by MapContext:GetStandingZone to keep an "
    .. "instance's own name as the standing zone instead of falling back to the last outdoor zone "
    .. "remembered before the portal, and it degrades to a static bundled-data test when absent")
DeclareFunction("zoneRealName", "GetRealZoneText", "documented",
    "client API reference; not runtime-probed. Preferred over GetZoneText, which was measured "
    .. "returning a building's own subzone name (\"Brill Town Hall\", area 2118) while the "
    .. "Tirisfal map was open, emptying the map layer")
DeclareFunction("mapSetCurrentZone", "SetMapToCurrentZone", "verified",
    "probe mapcoldstart 2026-08-23: called before the world map was ever shown post-/reload, resolved "
    .. "zoneIndex 0/GetMapInfo nil/player 0,0 into zoneIndex 14/mapFile Elwynn/a real player position")
DeclareFunction("mouseoverUnit", "UnitName", "documented",
    "UnitName accepts the documented mouseover unit token; the player form is runtime-measured")

if ResolveGameTooltip() then
    UQ:DeclareCapability("entityTooltip", "verified",
        "User-confirmed in game 2026-08-28 on the Milly's Harvest world object: identity is read from "
        .. "GameTooltipTextLeft1 (the tooltip's own rendered first line), the same technique "
        .. "Interface/AddOns/pfQuest/map.lua uses, rather than from UnitName(\"mouseover\"). The objective "
        .. "an entity satisfies is "
        .. "read out of the live quest log line itself through the questObjectivePatterns capability, so a "
        .. "direct objective needs no quest ID and no world-data record. The native tooltip is visually replaced "
        .. "by one addon-owned combined tooltip: every native row is read back from GameTooltipTextLeft<i>/Right<i> "
        .. "and reprinted above the quest rows, so a creature never shows two tooltips at once. Standalone uses "
        .. "native chrome; both UnrealUI themes use its flat tooltip style. This client does not reliably "
        .. "relayout Lua-added tooltip lines, and world-object tooltip rebuilds otherwise make native and appended "
        .. "layouts alternate. An opaque owned cover replaces all native alpha writes and region discovery. "
        .. "Brief empty or partial reads retain the last complete presentation. Unreadable initial rows draw "
        .. "nothing at all -- the attached second-panel route is deleted, so this layer cannot put two boxes "
        .. "on screen, and /uq tooltip's nativeUnreadable counts the hovers that cost. A row's colour escapes "
        .. "are stripped before UQ.NameKey compares it with the label, never before it is reprinted. "
        .. "Cover-only rendering and Modern chrome still await in-game confirmation; probe tooltipdupe "
        .. "(UnrealRuntimeProbe/TooltipDupeProbe.lua) measures both rectangles in screen pixels to supply it. "
        .. "SetUnit and AddLine are never called on GameTooltip by this layer. /uq tooltip reports live counters so a hover session can be "
        .. "diagnosed from SavedVariables instead of a screenshot")
else
    UQ:DeclareCapability("entityTooltip", "missing",
        "GameTooltip was not available at load")
end

if ResolveObject("GameTooltipStatusBar") then
    UQ:DeclareCapability("entityTooltipHealthBar", "unverified",
        "GameTooltipStatusBar is present at load. It is a frame of its own that GameTooltip's "
        .. "GetHeight does not count. Probe tooltipdupe v2 measured its full 12px height outside the "
        .. "replacement; v3 then measured an ordinary NPC's native body at 162px against a 136px "
        .. "content-only panel, leaving 30px exposed on every replacement frame. v3 also caught the "
        .. "attempted bar re-anchor already restored to GameTooltip by the host. The owned rectangle "
        .. "now contains the CURRENT native body plus the bar's LIVE height, while the host keeps "
        .. "complete ownership of the bar anchors. Only the bar's frame level is raised above that "
        .. "containing rectangle, read back, and restored on teardown; anchors are never written. "
        .. "Probe v4 confirmed ordinary NPCs covered in both cursor modes, then caught a cursor-follow "
        .. "world object switching between two native anchors. That case now keeps the native tooltip "
        .. "alone instead of starting an impossible two-position replacement. During mouse-out the "
        .. "replacement stays fully opaque for 0.7 seconds in either cursor mode. The lost mouseover "
        .. "unit plus stale NPC name no longer enters the world-object guard and bypasses that timer. "
        .. "An early hidden signal only starts the timer; native root visibility and alpha remain "
        .. "untouched. The separately drawn native health bar hides in the same release tick as the "
        .. "owned panel. "
        .. "v4 measured overlap "
        .. "when a cover instead mirrored even a "
        .. "coordinated root and bar alpha. This "
        .. "is the only native frame the tooltip layer writes to, and the one-box result awaits "
        .. "in-game confirmation: re-run probe tooltipdupe and require statusBarExposedFrames 0, "
        .. "bodyExposedFrames 0 and coveredFrames above 0")
else
    UQ:DeclareCapability("entityTooltipHealthBar", "missing",
        "GameTooltipStatusBar was not available at load")
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
if Client.HasChatSend() then
    UQ:DeclareCapability("chatSend", "unverified",
        "SendChatMessage resolves as a callable global, but the client's API reference says an addon "
        .. "call errors: \"SendChatMessage is protected: it errors unless called from a secure "
        .. "(Blizzard UI) context. DoEmote and SendAddonMessage are not.\" No probe has exercised it. "
        .. "Quest/ObjectiveAnnounce.lua tries it once per line, counts refusals and falls back to the "
        .. "addon channel, so \"/uq announce\" settles this in one grouped session and nothing depends "
        .. "on the answer")
else
    UQ:DeclareCapability("chatSend", "missing",
        "SendChatMessage is not a callable global, so no visible chat line can be posted at all")
end
if Client.HasAddonMessages() then
    UQ:DeclareCapability("addonMessages", "unverified",
        "SendAddonMessage is a callable global and the client's API reference explicitly exempts it "
        .. "from the protection on SendChatMessage, with the documented shape "
        .. "SendAddonMessage(prefix, message, chatType). RECEIVING is the open half: this client "
        .. "documents no event names at all and the compact DB has no CHAT_MSG_ADDON record, so "
        .. "whether a peer's message arrives is settled only by two UnrealQuest clients in one group. "
        .. "Quest/QuestSync.lua registers the event defensively and knows of no peer when it never "
        .. "fires; \"/uq announce\" reports peers seen and messages received")
else
    UQ:DeclareCapability("addonMessages", "missing",
        "SendAddonMessage is not a callable global, so the addon cannot tell whether anyone in the "
        .. "group shares a quest and the party report stays silent")
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

UQ:DeclareCapability("playerFacing", "documented",
    "GetPlayerFacing() is documented on the updated client as returning the CHARACTER's rotation in "
    .. "radians (client update notes 2026-08-28). DOCUMENTED, NOT VERIFIED, and it must not be promoted "
    .. "without a probe: nothing has yet recorded its zero axis, its rotation direction or its wrap "
    .. "point. The addon assumes its own convention (0 = north, increasing towards west) and then "
    .. "CHECKS that assumption at runtime against the movement estimator -- see "
    .. "playerFacingConvention. The preceding build had no facing by any route (probe 1.37.0 group "
    .. "`facing`, 2026-08-22: every candidate global nil, Minimap has no Model child, and the Model "
    .. "type itself has no GetFacing), which is why the movement fallback stays")

UQ:DeclareCapability("playerFacingConvention", "unverified",
    "which radian convention GetPlayerFacing() reports in. The addon does not guess and then hope: "
    .. "PlayerHeading votes each movement fix against both sign hypotheses in eighth-turn buckets and "
    .. "adopts the winner once it leads by a clear margin, so a client that measures rotation the other "
    .. "way round or from a different zero axis is corrected rather than pointed backwards. Until a "
    .. "vote settles, the identity convention is assumed -- and /uq waypoint prints which of the two is "
    .. "in force, so the settled answer can be read back and turned into a probe result")

UQ:DeclareCapability("playerHeadingFromMovement", "verified",
    "measured 2026-08-22: GetPlayerMapPosition tracks a walking player. It was the ONLY direction "
    .. "source the preceding build offered and is now the fallback behind playerFacing, plus the "
    .. "yardstick the facing convention is measured against. It is QUANTIZED TO ONE YARD -- observed "
    .. "steps were exactly 1/widthYards and 1/heightYards of the bundled area dimensions -- so a "
    .. "bearing taken from a single 0.05s sample snaps to about 45 degrees. The estimator accumulates "
    .. "over a multi-yard baseline instead. It reports travel direction, not facing, and is silent "
    .. "while the player stands still")

UQ:DeclareCapability("textureQuadRotation", "missing",
    "the eight-argument Texture:SetTexCoord call is accepted, but the first live visual test on "
    .. "2026-09-01 showed the navigator arrow distorting instead of rotating rigidly. Call success is "
    .. "not visual support. The navigator therefore uses 64 pre-rotated frames selected through "
    .. "the proven four-argument SetTexCoord form, following pfQuest's TomTom-derived technique")

UQ:DeclareCapability("hudNavigator", "unverified",
    "the arc-and-arrow direction display: two addon-owned TGA textures on a UIParent child over the 3D "
    .. "world. The frame, arc and arrow were USER_CONFIRMED_INGAME visible on 2026-09-01. The "
    .. "first arrow rotation method distorted rather than turned, so the complete navigator remains "
    .. "unverified until the replacement pre-rotated atlas is seen. Addon TGAs render when the path is "
    .. "passed WITHOUT the .tga suffix (textures.addon_tga_paths_require_extensionless, "
    .. "USER_CONFIRMED_INGAME). /uq nav reports created, shown and the placement counters so an "
    .. "invisible navigator can be told from one that was never placed")

UQ:DeclareCapability("hudWaypoint", "unverified",
    "an ordinary UIParent child with one file-backed BACKGROUND texture; the same material contract that "
    .. "is confirmed on the map canvas, but never yet confirmed over the 3D world on this client. "
    .. "/uq waypoint reports whether the marker was created, positioned and shown, so an invisible "
    .. "marker can be told apart from one that was never placed. It is no longer unverified BY "
    .. "CONSTRUCTION: mainQuestWaypoint was re-enabled 2026-09-01 once GetPlayerFacing arrived, so the "
    .. "marker frame is now created in the shipped build and the placement counters carry real numbers")

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
    .. "SUPPORTED/BEHAVIOR_VERIFIED): the grip is moved through the same five-factor StartMoving "
    .. "recipe the drag handle needs, and live geometry is read from its GetLeft/GetBottom")

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
        .. "trackerHideNativeWatch setting is on, and re-shown when it is turned off. Only the frame's own "
        .. "Show/Hide are called -- its native OnEvent handler never is. One OnShow guard is chained onto "
        .. "it so the client's own re-show (QUEST_LOG_UPDATE -> QuestWatch_Update) cannot flash it back on "
        .. "screen; the guard is permanent because SetScript cannot be undone on this client, and asks the "
        .. "setting on every show so it goes inert when hiding is turned off")
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
