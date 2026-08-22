--[[
UnrealQuest / World/QuestMarks.lua

Puts a raid target mark over a creature an active quest wants, so looking at a
mob tells you whether it is one of yours.

WHY A RAID MARK, AND NOT AN ICON WE DRAW
----------------------------------------
Because there is nowhere to draw one. Everything an addon would anchor to was
measured absent on this client, and each of those is a closed question rather
than an untried idea (docs/CLIENT-COMPATIBILITY.md):

  * no unit world position and no unit screen position, by any route;
  * no readable player facing -- 60 samples of a player turning a full circle
    with every candidate source unchanged;
  * no nameplate widget. A full inventory of WorldFrame found 26 children, all
    of them identifiable FrameXML furniture, with no plate among them. The five
    a structural classifier adopts here are GroupLootFrame1..4 -- whose
    template default text is literally "Item Name" -- plus ShopFrameScanTooltip.

A raid mark needs none of that: the engine draws it over the unit itself, and
the addon only has to name the unit. That is the whole reason this file exists
in this shape, and the reason it should not be "improved" into a texture later.

WHAT IS KNOWN, AND WHAT REMAINS OPEN
------------------------------------
`SetRaidTarget(unit, index)` is documented and unprotected, but live evidence
now limits where it is worth calling:

  1. **The server ignores the write while the player is solo.** On 2026-08-23
     the live addon identified Kobold Tunneler as a quest objective and sent
     nine writes, but GetRaidTargetIndex confirmed none and the user saw no
     mark. The module therefore never writes while solo. Whether a party
     leader or raid assistant is accepted remains unverified.
  2. **The write is a server round trip.** The reference says the client
     "sends index - 1 to the server", so `GetRaidTargetIndex` will still answer
     nil immediately after a write that is about to succeed. Confirmation is
     therefore read on a LATER pass, never straight back. Reading back too
     early and calling it a refusal is the obvious way to get this wrong.

A MARK IS SHARED STATE
----------------------
Every other group member sees a raid mark, and setting one overwrites whatever
they had put there. The server rejects the safe solo case, so the only remaining
route is deliberately opt-in (`questMarksInGroup`, off): a player leading a
quest group may enable it, while ordinary group play is never changed silently.

Nothing here ever clears a mark it did not set. If a creature already carries
some other mark, that is somebody's deliberate choice and it is left alone.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestMarks = UQ:NewModule("QuestMarks")

-- Fast enough that a mark appears while you are still looking at the creature,
-- slow enough that a pass costs two UnitName reads in the common case.
local POLL_INTERVAL = 0.25

-- How long to wait before a write counts as unconfirmed. The call is a server
-- round trip, so this is a latency budget, not a frame count.
local CONFIRM_SECONDS = 3.0

-- After this many writes with not one confirmation, stop. The caller opted
-- into group marking, but the current role may lack leader/assistant rights or
-- the server may not honour the API at all; either makes further writes noise.
-- One confirmation resets the count, so a single laggy write costs nothing.
local MAX_UNCONFIRMED = 6

-- The units the addon can name. There is no way to enumerate creatures around
-- the player, so "which mob am I looking at" reduces to these two.
local UNITS = { "mouseover", "target" }

-- State ---------------------------------------------------------------------

QuestMarks.turnInKeys = {}
QuestMarks.turnInStamp = nil

-- What we last wrote, per creature name, so a mark can be cleared again when
-- the quest stops wanting the creature -- and so a mark somebody else set is
-- never touched. Keyed by name because a unit token is transient and a name is
-- the only identity this client offers.
QuestMarks.written = {}

QuestMarks.pendingUnit = nil
QuestMarks.pendingIndex = nil
QuestMarks.pendingAt = nil

QuestMarks.stats = {
    writes = 0,
    confirmed = 0,
    cleared = 0,
    unconfirmed = 0,
    skippedInGroup = 0,
    lastMarked = nil,
    lastKind = nil,
}
QuestMarks.refused = false

-- Quest interest -------------------------------------------------------------

-- Turn-in NPCs of the quests whose objectives are done, rebuilt only when the
-- quest model changes. ObjectiveMatch already stamps that for its own cache,
-- so this borrows the stamp rather than adding a second listener.
function QuestMarks:RefreshTurnInKeys()
    local matcher = UQ:GetModule("ObjectiveMatch")
    local stamp = matcher and matcher.questStamp or 0
    if self.turnInStamp == stamp then
        return
    end
    self.turnInStamp = stamp

    local keys = {}
    self.turnInKeys = keys

    local state = UQ:GetModule("QuestState")
    local database = UQ:GetModule("Database")
    if not state or not database then
        return
    end

    local quests = state:GetOrderedQuests()
    local questIndex = 1
    local questTotal = table.getn(quests)
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        if quest and quest.isComplete == 1 and type(quest.questId) == "number" then
            local relation = database:GetQuestFinishers(quest.questId)
            if type(relation) == "table" and type(relation.U) == "table" then
                local _, unitId
                for _, unitId in pairs(relation.U) do
                    local key = UQ.NameKey(database:GetUnitName(unitId))
                    if key then
                        keys[key] = true
                    end
                end
            end
        end
        questIndex = questIndex + 1
    end
end

-- "objective" when the creature satisfies an objective of a quest in the log,
-- "turnin" when it takes a finished one, nil when the log wants nothing with
-- it. The objective answer comes from Data/ObjectiveMatch.lua -- the same
-- module Tooltip/EntityTooltip.lua asks -- so the mark over a creature and the
-- line on its tooltip can never disagree.
function QuestMarks:WantedKind(unitKey)
    if not unitKey then
        return nil
    end
    local matcher = UQ:GetModule("ObjectiveMatch")
    if matcher and matcher:FindForUnit(unitKey) then
        return "objective"
    end
    if self.turnInKeys[unitKey] then
        return "turnin"
    end
    return nil
end

-- Settings -------------------------------------------------------------------

local function ConfigNumber(key, fallback)
    local config = UQ:GetModule("Config")
    local value = config and config:Get(key)
    if type(value) ~= "number" or value < 1 or value > 8 then
        return fallback
    end
    return value
end

function QuestMarks:IndexFor(kind)
    if kind == "turnin" then
        return ConfigNumber("questMarkTurnInIndex", 3)
    end
    return ConfigNumber("questMarkIndex", 1)
end

function QuestMarks:IsEnabled()
    local config = UQ:GetModule("Config")
    if config and config:Get("questMarks") == false then
        return false
    end
    return Client.HasRaidTargetMarks() and not self.refused
end

function QuestMarks:AllowedHere()
    if not Client.IsInGroup() then
        -- Measured unsupported on 2026-08-23: nine writes against a correctly
        -- matched quest creature, zero read-back confirmations, no visible
        -- mark. Do not keep sending known-inert server traffic while solo.
        return false
    end
    local config = UQ:GetModule("Config")
    return config and config:Get("questMarksInGroup") == true
end

-- Confirmation ---------------------------------------------------------------

-- A write is confirmed by reading the mark back on a LATER pass, never
-- immediately: the reference says the client sends the value to the server, so
-- an instant read reports nil for a write that is about to land.
function QuestMarks:CheckPending()
    if not self.pendingUnit then
        return
    end
    local now = Client.Now()
    if not now or not self.pendingAt then
        return
    end

    if Client.GetRaidTargetMark(self.pendingUnit) == self.pendingIndex then
        self.stats.confirmed = self.stats.confirmed + 1
        self.stats.unconfirmed = 0
        self.pendingUnit = nil
        return
    end

    if (now - self.pendingAt) < CONFIRM_SECONDS then
        return
    end

    -- Timed out. The unit may simply have gone away, which is not evidence
    -- about the server, so this only counts when the unit is still there.
    if Client.UnitExists(self.pendingUnit) then
        self.stats.unconfirmed = self.stats.unconfirmed + 1
        if self.stats.unconfirmed >= MAX_UNCONFIRMED and self.stats.confirmed == 0 then
            self.refused = true
            UQ:Warn("raid marks are not being accepted -- see /uq marks")
        end
    end
    self.pendingUnit = nil
end

function QuestMarks:Write(unit, index)
    if not Client.SetRaidTargetMark(unit, index) then
        return false
    end
    self.stats.writes = self.stats.writes + 1
    self.pendingUnit = unit
    self.pendingIndex = index
    self.pendingAt = Client.Now()
    return true
end

-- One unit -------------------------------------------------------------------

function QuestMarks:Visit(unit)
    if not Client.UnitExists(unit) or Client.UnitIsPlayer(unit) then
        return
    end
    local name = Client.GetUnitName(unit)
    local unitKey = UQ.NameKey(name)
    if not unitKey then
        return
    end

    local kind = self:WantedKind(unitKey)
    local current = Client.GetRaidTargetMark(unit)
    local ours = self.written[unitKey]

    if kind then
        local desired = self:IndexFor(kind)
        if current == desired then
            return
        end
        -- A write already in flight for this unit reads back as "no mark" until
        -- the server answers, so without this the poll would re-send the same
        -- mark four times a second for the whole round trip. CheckPending is
        -- what eventually clears it, whether it lands or times out.
        if self.pendingUnit == unit and self.pendingIndex == desired then
            return
        end
        if current and current ~= ours then
            -- Somebody marked this creature deliberately. Leave it.
            return
        end
        if self:Write(unit, desired) then
            self.written[unitKey] = desired
            self.stats.lastMarked = name
            self.stats.lastKind = kind
        end
        return
    end

    -- Not wanted any more. Clear, but only a mark this addon put there.
    if current and ours and current == ours then
        if Client.SetRaidTargetMark(unit, 0) then
            self.written[unitKey] = nil
            self.stats.cleared = self.stats.cleared + 1
        end
    end
end

function QuestMarks:Poll()
    if not self:IsEnabled() then
        return
    end
    if not self:AllowedHere() then
        if Client.IsInGroup() then
            self.stats.skippedInGroup = self.stats.skippedInGroup + 1
        end
        return
    end

    self:CheckPending()
    self:RefreshTurnInKeys()

    local index = 1
    local total = table.getn(UNITS)
    while index <= total do
        self:Visit(UNITS[index])
        index = index + 1
    end
end

-- Clears every mark this addon set that is still reachable. Only the two
-- nameable units can be reached, so this is a best effort by construction --
-- said out loud because "turn it off and the marks vanish" is not a promise
-- this client lets the addon keep.
function QuestMarks:ClearReachable()
    local index = 1
    local total = table.getn(UNITS)
    while index <= total do
        local unit = UNITS[index]
        if Client.UnitExists(unit) then
            local unitKey = UQ.NameKey(Client.GetUnitName(unit))
            local ours = unitKey and self.written[unitKey]
            if ours and Client.GetRaidTargetMark(unit) == ours then
                Client.SetRaidTargetMark(unit, 0)
                self.written[unitKey] = nil
                self.stats.cleared = self.stats.cleared + 1
            end
        end
        index = index + 1
    end
end

-- Diagnostics ----------------------------------------------------------------

function QuestMarks:Record()
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("questMarkDiagnostics", "writes", self.stats.writes)
    config:SetSectionEntry("questMarkDiagnostics", "confirmed", self.stats.confirmed)
    config:SetSectionEntry("questMarkDiagnostics", "cleared", self.stats.cleared)
    config:SetSectionEntry("questMarkDiagnostics", "unconfirmed", self.stats.unconfirmed)
    config:SetSectionEntry("questMarkDiagnostics", "refused", self.refused)
    config:SetSectionEntry("questMarkDiagnostics", "inGroup", Client.IsInGroup())
    config:SetSectionEntry("questMarkDiagnostics", "lastMarked",
        self.stats.lastMarked or "<none>")
    config:SetSectionEntry("questMarkDiagnostics", "lastKind",
        self.stats.lastKind or "<none>")
end

local MARK_NAMES = {
    "star", "circle", "diamond", "triangle", "moon", "square", "cross", "skull",
}

function QuestMarks:MarkName(index)
    return MARK_NAMES[index] or ("mark " .. tostring(index))
end

function QuestMarks:GetStatus()
    local config = UQ:GetModule("Config")
    return {
        available = Client.HasRaidTargetMarks(),
        enabled = not (config and config:Get("questMarks") == false),
        refused = self.refused,
        inGroup = Client.IsInGroup(),
        allowedHere = self:AllowedHere(),
        objectiveIndex = self:IndexFor("objective"),
        turnInIndex = self:IndexFor("turnin"),
        writes = self.stats.writes,
        confirmed = self.stats.confirmed,
        cleared = self.stats.cleared,
        unconfirmed = self.stats.unconfirmed,
        skippedInGroup = self.stats.skippedInGroup,
        lastMarked = self.stats.lastMarked,
        lastKind = self.stats.lastKind,
    }
end

-- Lifecycle -------------------------------------------------------------------

function QuestMarks:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("world.questmarks", POLL_INTERVAL, function()
        QuestMarks:Poll()
        QuestMarks:Record()
    end)
end
