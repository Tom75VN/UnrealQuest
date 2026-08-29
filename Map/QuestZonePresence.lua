--[[
UnrealQuest / Map/QuestZonePresence.lua

"Would this zone's map draw anything at all for this quest?" -- one answer,
for the tracker's current-zone filter.

The tracker used to decide that from the quest log's own header row alone: a
quest filed under "Duskwood" is a Duskwood quest, and standing anywhere else
hid it. The quest log's grouping is the zone the quest BELONGS to, which is
routinely not the zone its objectives are in -- a quest taken in Duskwood whose
every kill is in Westfall disappeared from the tracker for exactly the time the
player was actually doing it.

So the filter asks the map instead, and this module is that question. It is
deliberately not a second opinion about where a quest is: it calls the very
collectors the map layers draw from, so a "yes" here means the player really
can see something for that quest on that zone's map, and a "no" means the map
is empty of it:

  * the objective cloud, through Data/QuestTarget.lua's CollectLocations --
    the same call Map/WorldMapPins.lua's tiles and dots come from, so a source
    whose objective is already finished, or an item-use target the player is
    not carrying, is absent here exactly as it is absent on the map;
  * the turn-in relation, drawn as green tiles for a quest ready to hand in and
    as the "?" marker for one still in progress (that half follows the
    showInProgressTurnIns setting, because that is what decides whether the
    marker exists);
  * vendor points for bought objective items, when questVendorPins is on,
    filtered by the same "is the item still wanted" and faction tests
    Map/QuestVendorPins.lua applies.

THREE ANSWERS, NOT TWO. true and false mean the map has something / has
nothing. nil means the question could not be asked at all -- the quest matched
no database record, or every record it could be is hidden from the map (CLUCK!
and the hiddenMapQuests overrides). An empty map is not evidence about the zone
in those cases, so the caller must fall back to what it did before rather than
read nil as "not here".

Nothing in here reads the client. The zone name the area is resolved from is
read by the caller and resolved through Map/MapContext.lua, like every other
area lookup. The rest is arithmetic over the bundled database and the live
quest model, so the offline smoke test exercises it in full.

COST. The tracker asks this every 0.4s, so the answers are memoized on the
quest's own state -- its match, its completion, and every objective's finished
flag and counter -- keyed by area and by the bag token, and the whole table is
dropped whenever the player changes zone or the carried set moves. A steady
state is therefore one table lookup per quest per refresh, and the underlying
database walks are themselves cached for the session by Data/Database.lua.
]]

local UQ = UnrealQuest
local QuestZonePresence = UQ:NewModule("QuestZonePresence")

-- A guard against unbounded growth, not a tuning knob: twenty quests moving
-- through a handful of states each never approaches it, and reaching it simply
-- starts the memo over.
local MAX_CACHE_ENTRIES = 240

QuestZonePresence.cache = {}
QuestZonePresence.cacheCount = 0
QuestZonePresence.cacheAreaId = nil
QuestZonePresence.cacheToken = nil
QuestZonePresence.hits = 0
QuestZonePresence.computes = 0

local function Database()
    return UQ:GetModule("Database")
end

local function Config()
    return UQ:GetModule("Config")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function QuestTarget()
    return UQ:GetModule("QuestTarget")
end

local function WorldMapPins()
    return UQ:GetModule("WorldMapPins")
end

local function QuestVendorPins()
    return UQ:GetModule("QuestVendorPins")
end

local function QuestEligibility()
    return UQ:GetModule("QuestEligibility")
end

local function BagItems()
    return UQ:GetModule("BagItems")
end

-- The area whose map the PLAYER's zone would show, from a name the caller has
-- already read off the client. GetRealZoneText is the name to hand over, for
-- the reason Map/MapContext.lua gives: inside a building GetZoneText answers
-- with the building, which resolves to a real area with no quest data at all.
--
-- This is deliberately not GetCurrentZoneView: that question is about the map
-- view that is open, and the tracker's filter must keep working with the map
-- closed.
function QuestZonePresence:ResolveArea(name)
    local mapContext = MapContext()
    if not mapContext or type(name) ~= "string" or name == "" then
        return nil
    end
    return mapContext:ResolveAreaId(name)
end

-- The zone that encloses an area the player's own position produced, so the
-- tracker's filter survives the player walking into a mine or an inn. Same
-- delegation as ResolveArea above: the walk is Map/MapContext.lua's, because
-- every area lookup in this addon is.
function QuestZonePresence:ResolveEnclosingArea(areaId)
    local mapContext = MapContext()
    if not mapContext then
        return nil
    end
    return mapContext:ResolveEnclosingArea(areaId)
end

-- Database IDs this live quest row is allowed to draw, taken from the map
-- layer itself so an ambiguous row's candidate union is the same set here as
-- it is on the map. The fallback covers the map layer not being loaded yet,
-- and shows only what was actually proven.
local function QuestMapIds(quest)
    local worldMapPins = WorldMapPins()
    if worldMapPins and worldMapPins.GetQuestMapIds then
        return worldMapPins:GetQuestMapIds(quest)
    end
    local ids = {}
    if quest and type(quest.questId) == "number" then
        table.insert(ids, quest.questId)
    end
    return ids
end

local function IsMapHidden(config, questId)
    local worldMapPins = WorldMapPins()
    if worldMapPins and worldMapPins.IsQuestHidden then
        return worldMapPins:IsQuestHidden(questId, config) and true or false
    end
    return false
end

local function ShowsInProgressTurnIns(config)
    if not config then
        return true
    end
    return config:Get("showInProgressTurnIns") and true or false
end

local function ShowsVendorPins(config)
    -- Absent config is the addon still coming up, not a player who turned this
    -- off; the default is on, so the pins count.
    return not config or config:Get("questVendorPins") ~= false
end

-- Everything about the quest that can change what the map draws for it. The
-- area and the bag token are the cache's other two dimensions and are checked
-- separately, so they are deliberately not in here.
local function QuestSignature(quest)
    local parts = { tostring(quest.questId), tostring(quest.titleKey or quest.title),
        tostring(quest.matchConfidence), tostring(quest.isComplete) }
    local objectives = quest.objectives or {}
    local index = 1
    local total = table.getn(objectives)
    while index <= total do
        local objective = objectives[index]
        if objective then
            table.insert(parts, tostring(objective.finished) .. ":" .. tostring(objective.have))
        end
        index = index + 1
    end
    return table.concat(parts, "|")
end

-- Any turn-in coordinate in this area. The `end` relation is what both the
-- green tiles of a completed quest and the "?" marker of one in progress are
-- drawn from, so one lookup answers for both. No limit is passed: the map caps
-- how many markers it will place, but presence only asks whether there is one.
local function HasTurnInPoint(database, questId, areaId)
    return table.getn(database:GetQuestLocations(questId, true, areaId)) > 0
end

-- Any objective coordinate in this area, through the collector the map's tiles
-- and dots use, so a finished creature objective or an uncarried item-use
-- target is missing here exactly as it is missing on the map.
local function HasObjectivePoint(quest, questId, areaId)
    local questTarget = QuestTarget()
    if not questTarget then
        return false
    end
    local locations = questTarget:CollectLocations({
        questId = questId,
        objectives = quest.objectives,
        objectiveOwner = quest,
    }, areaId, false)
    return table.getn(locations) > 0
end

-- Any vendor of a still-wanted bought objective item, in this area. Same three
-- tests Map/QuestVendorPins.lua applies before it places a pin: the item is
-- still wanted, the player's faction may trade with the seller, and the seller
-- has a recorded spawn here.
local function HasVendorPoint(database, quest, questId, areaId)
    local vendorPins = QuestVendorPins()
    if not vendorPins or not vendorPins.ItemNeeded then
        return false
    end
    local eligibility = QuestEligibility()
    local rows = database:GetQuestVendorTargets(questId)
    local index = 1
    local total = table.getn(rows)
    while index <= total do
        local row = rows[index]
        if row and vendorPins:ItemNeeded(quest, row)
            and (not eligibility
                or eligibility:MatchesGiverFaction({ faction = row.faction })) then
            if table.getn(database:GetEntityLocations("unit", row.unitId, areaId)) > 0 then
                return true
            end
        end
        index = index + 1
    end
    return false
end

-- true / false / nil, as described in the file header. Uncached; callers want
-- HasPoints below.
function QuestZonePresence:Compute(quest, areaId)
    local database = Database()
    if not database or not database.available then
        return nil
    end
    local ids = QuestMapIds(quest)
    local idTotal = table.getn(ids)
    if idTotal == 0 then
        return nil
    end

    local config = Config()
    local complete = quest.isComplete == 1
    local turnIns = complete or ShowsInProgressTurnIns(config)
    local vendors = not complete and ShowsVendorPins(config)
    local drawable = 0

    local index = 1
    while index <= idTotal do
        local questId = ids[index]
        if not IsMapHidden(config, questId) then
            drawable = drawable + 1
            if turnIns and HasTurnInPoint(database, questId, areaId) then
                return true
            end
            -- A quest ready to hand in shows its ender and nothing else: its
            -- objective cloud is off the map by then, and it has finished
            -- shopping.
            if not complete then
                if HasObjectivePoint(quest, questId, areaId) then
                    return true
                end
                if vendors and HasVendorPoint(database, quest, questId, areaId) then
                    return true
                end
            end
        end
        index = index + 1
    end

    if drawable == 0 then
        -- Every candidate is deliberately withheld from the map, so the empty
        -- map says nothing about where the quest is.
        return nil
    end
    return false
end

-- Memoized Compute. The stored value is wrapped because nil is one of the
-- three answers and a bare nil in the table would read as "not cached yet".
function QuestZonePresence:HasPoints(quest, areaId)
    if type(quest) ~= "table" or type(areaId) ~= "number" then
        return nil
    end

    local bagItems = BagItems()
    local token = "noBags"
    if bagItems and bagItems.GetToken then
        token = bagItems:GetToken()
    end
    if self.cacheAreaId ~= areaId or self.cacheToken ~= token
        or self.cacheCount >= MAX_CACHE_ENTRIES then
        self.cache = {}
        self.cacheCount = 0
        self.cacheAreaId = areaId
        self.cacheToken = token
    end

    local key = QuestSignature(quest)
    local entry = self.cache[key]
    if entry then
        self.hits = self.hits + 1
        return entry.value
    end

    local value = self:Compute(quest, areaId)
    self.cache[key] = { value = value }
    self.cacheCount = self.cacheCount + 1
    self.computes = self.computes + 1
    return value
end

function QuestZonePresence:GetStatus()
    return {
        areaId = self.cacheAreaId,
        entries = self.cacheCount,
        hits = self.hits,
        computes = self.computes,
    }
end
