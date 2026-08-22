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

-- Returns title, level, questTag, isHeader, isCollapsed, isComplete.
--
-- The six-value contract is corroborated twice: the questtrack probe captured a
-- six-value return tuple with isHeader in position four, and the client API
-- reference documents the same order. Out-of-range indices yield
-- (nil, 0, nil, nil, nil, nil).
function Client.GetQuestLogEntry(index)
    local fn = Resolve("GetQuestLogTitle")
    if not fn then
        return nil
    end
    local ok, title, level, questTag, isHeader, isCollapsed, isComplete = pcall(fn, index)
    if not ok or type(title) ~= "string" then
        return nil
    end
    return title, level, questTag, isHeader, isCollapsed, isComplete
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
function Client.ShowMapTooltip(frame, lines, anchor)
    local tooltip = ResolveMapTooltip()
    if not tooltip or not frame then
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
        local rowLabel = ResolveObject((mapTooltipName or "") .. "TextLeft" .. row)
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
    Client.ApplyFlatTooltipStyle(tooltip, mapTooltipName)

    if type(tooltip.Show) == "function" then
        pcall(tooltip.Show, tooltip)
    end
    return true
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
DeclareFunction("questGreenRange", "GetQuestGreenRange", "documented",
    "client API reference; used because GetDifficultyColor is confirmed absent")
DeclareFunction("mapCurrent", "GetMapInfo", "verified",
    "measured 2026-08-20 after SetMapToCurrentZone; uninitialized immediately after reload")
DeclareFunction("mapPlayerPosition", "GetPlayerMapPosition", "verified",
    "measured non-zero on the current-zone map and absent when the view is uninitialized")
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
