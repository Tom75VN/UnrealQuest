--[[
UnrealQuest / Quest/QuestEligibility.lua

Can this character actually be offered this quest?

The bundled world data lists every quest a giver can hand out to anyone, not
what the character in front of the screen may take. Without this filter a
world-map "still to take" marker is wrong in a very visible way: the classic
example is CLUCK! (quest 3861), started by the Chicken critter, which has 108
spawn points across 9 zones -- so every chicken in the world became a quest
marker, including for Horde characters, even though the quest's race mask is
Alliance-only.

The record fields this reads, and how many quests carry each:

  race   626 quests   bitmask, bit 2^(raceId-1)
  class  825 quests   bitmask, bit 2^(classId-1)
  min   4416 quests   minimum character level
  event  342 quests   seasonal world event id
  pre   2399 quests   prerequisite quest(s) -- deliberately NOT used, see below

The race and class bits are derived from the numeric ids the client returns,
which is measured behaviour here (UnitRace/UnitClass both return a third
numeric value). Matching localized race names would break on any non-enUS
client and is not done.

`pre` is deliberately ignored. A prerequisite check needs to know which quests
the character already completed, and this client has no completed-quest API at
all -- Quest/QuestHistory.lua only knows what it personally watched happen. On
a fresh install that history is empty, so filtering on `pre` would hide nearly
every chain quest in the game rather than a handful of unavailable ones. Over-
showing a follow-up quest is the better failure here, and it is recorded as an
open question rather than silently accepted.

There is no `bit` library in the compatibility database, so mask tests are
plain arithmetic in the conservative Lua subset.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestEligibility = UQ:NewModule("QuestEligibility")

QuestEligibility.raceBit = nil
QuestEligibility.classBit = nil
QuestEligibility.level = nil
QuestEligibility.resolved = false

local function Database()
    return UQ:GetModule("Database")
end

-- True when `mask` has `bit` set. Both are non-negative integers and bit is a
-- power of two. math.floor is the only primitive used, so this stays valid on
-- both the client and the offline test runtime.
local function HasBit(mask, bit)
    if type(mask) ~= "number" or type(bit) ~= "number" or bit < 1 then
        return false
    end
    return math.floor(mask / bit) - math.floor(mask / (bit * 2)) * 2 == 1
end

local function BitForId(id)
    if type(id) ~= "number" or id < 1 or id > 31 then
        return nil
    end
    local bit = 1
    local index = 1
    while index < id do
        bit = bit * 2
        index = index + 1
    end
    return bit
end

-- Refreshed explicitly rather than per quest: the map layer checks dozens of
-- givers per pass, and Core/Driver.lua records per-tick bursts of guarded
-- client calls as a measured stuttering hazard on this client.
function QuestEligibility:RefreshPlayer()
    local raceId = Client.GetPlayerRaceId()
    local classId = Client.GetPlayerClassId()
    self.raceBit = BitForId(raceId)
    self.classBit = BitForId(classId)
    self.level = Client.GetPlayerLevel()
    self.resolved = (self.raceBit ~= nil or self.classBit ~= nil or self.level ~= nil)
    return self.resolved
end

function QuestEligibility:ShowEventQuests()
    local config = UQ:GetModule("Config")
    if not config then
        return false
    end
    return config:Get("showEventQuests") and true or false
end

-- Returns true plus nil, or false plus the reason it was filtered out. An
-- unknown player attribute never filters: a missing race id must not blank the
-- map, so each test is skipped rather than failed when its input is absent.
function QuestEligibility:IsOfferable(questId)
    local database = Database()
    if not database then
        return true
    end
    local record = database:GetQuest(questId)
    if type(record) ~= "table" then
        return true
    end

    -- A mask of 0 or 255 means "no restriction" / "every race", so only a mask
    -- that actually excludes this character rejects the quest.
    if type(record.race) == "number" and record.race > 0 and self.raceBit then
        if not HasBit(record.race, self.raceBit) then
            return false, "race"
        end
    end

    if type(record.class) == "number" and record.class > 0 and self.classBit then
        if not HasBit(record.class, self.classBit) then
            return false, "class"
        end
    end

    if type(record.min) == "number" and type(self.level) == "number"
        and record.min > self.level then
        return false, "level"
    end

    -- Seasonal quests are only offered while their world event runs, and this
    -- client exposes no way to ask which events are active, so they are hidden
    -- by default rather than shown year round.
    if record.event ~= nil and not self:ShowEventQuests() then
        return false, "event"
    end

    return true
end

function QuestEligibility:OnEnable()
    self:RefreshPlayer()
    UQ:DeclareCapability("questEligibility", "verified",
        "race/class masks resolved from the measured numeric ids UnitRace/UnitClass return; "
        .. "prerequisite chains are not filtered because the client exposes no completed-quest history")
end
