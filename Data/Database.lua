--[[
UnrealQuest / Data/Database.lua

Adapter over the bundled world data in Database/.

The data is world data only: quest records, the creatures, objects and items
that start, end or satisfy them, and the zone tables needed to place a
coordinate. It says nothing about what this client's API can do, and is never
treated as evidence that a client API exists.

Origin and licensing are in Database/CREDITS.md and LICENSE. The tables load
from the addon's own .toc onto the global UnrealQuestData; nothing outside this
file should touch that global.

Table shapes this adapter depends on:
  quests[id]        lvl, min, race, class, pre, event, close, and the relation
                    tables start / end / obj, each shaped
                    { U = { unitId, ... }, O = { objectId, ... }, I = { itemId, ... } }
  quests_enUS[id]   T title, O objectives text, D description
  units[id]         coords = { { x, y, zoneId, respawn }, ... }, lvl
  objects[id]       coords = { { x, y, zoneId, respawn }, ... }, fac
  items[id]         U = { unitId = dropRate }, O = { objectId = dropRate }
  zones[zoneId]     parentZoneOrContinent, width, height, xOffset, yOffset
  zones_enUS[id]    localized area name
  minimap[zoneId]   zone width and height in yards

The database is keyed by quest ID, and this client exposes no quest ID API.
Resolving a quest log row to a database record is therefore a title match, and
lives in Data/QuestMatch.lua rather than here.

Index building is chunked across driver ticks rather than done in one pass. A
synchronous burst of work has been reported as visible stuttering on this
client, and there is no reason to pay for the whole title index during login.
]]

local UQ = UnrealQuest
local Database = UQ:NewModule("Database")

local INDEX_CHUNK = 400

Database.available = false
Database.titleIndex = nil
Database.indexReady = false
Database.indexedCount = 0

-- giverIndex[sourceType..":"..sourceId] = { sourceType, sourceId, questIds = {...} }
-- areaGiverIndex[areaId] = { giverKey, giverKey, ... }
-- Built from quests[id].start the same way GetQuestLocations reads obj/end,
-- just indexed by area up front so WorldMapPins never has to walk every quest
-- in the database on every refresh.
Database.giverIndex = nil
Database.areaGiverIndex = nil
Database.giverIndexReady = false

local db = nil
local indexCursor = nil
local giverIndexCursor = nil

function Database:OnInit()
    -- The data ships with the addon and loads before this file, so an absent
    -- or malformed table means a broken install rather than a missing
    -- dependency. Report it and degrade instead of faulting: the quest log
    -- model works without any database at all, only without identity
    -- resolution.
    local ok, value = pcall(getglobal, "UnrealQuestData")
    if not ok or type(value) ~= "table" or type(value.quests) ~= "table" then
        self.available = false
        UQ:DeclareCapability("questDatabase", "missing",
            "bundled world data did not load; quest records, coordinates and objective sources are unavailable")
        return
    end

    db = value
    self.available = true

    UQ:DeclareCapability("questDatabase", "detected",
        "bundled world data loaded; keyed by quest ID, so quest log rows reach it only through title matching")
end

function Database:OnEnable()
    if not self.available then
        return
    end
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("database.index", 0, function() Database:IndexChunk() end)
        driver:Schedule("database.giverindex", 0, function() Database:IndexGiverChunk() end)
    end
end

-- Raw table access ----------------------------------------------------------

function Database:GetQuest(questId)
    if not db then
        return nil
    end
    return db.quests[questId]
end

function Database:GetQuestText(questId)
    if not db or type(db.quests_enUS) ~= "table" then
        return nil
    end
    return db.quests_enUS[questId]
end

function Database:GetQuestTitle(questId)
    local text = self:GetQuestText(questId)
    if not text then
        return nil
    end
    return text.T
end

-- Relation accessors. "end" is a Lua keyword, so the raw field can only be
-- reached by string index; wrapping the three relations here keeps that detail
-- out of every caller.

function Database:GetQuestStarters(questId)
    local record = self:GetQuest(questId)
    if not record then
        return nil
    end
    return record["start"]
end

function Database:GetQuestFinishers(questId)
    local record = self:GetQuest(questId)
    if not record then
        return nil
    end
    return record["end"]
end

function Database:GetQuestObjectiveSources(questId)
    local record = self:GetQuest(questId)
    if not record then
        return nil
    end
    return record["obj"]
end

-- Maps each creature that can satisfy an objective to the normalized text
-- that identifies its live objective line. Direct kill objectives use the
-- creature name; item objectives use the item name while still mapping the
-- creature that drops it. This keeps tooltip matching independent of the raw
-- generated table shapes and avoids guessing from the formatted quest text.
function Database:GetQuestObjectiveUnitLinks(questId)
    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" then
        return {}
    end

    local links = {}

    local function LinkUnit(unitId, objectiveName)
        if type(unitId) ~= "number" or type(objectiveName) ~= "string" then
            return
        end
        local unitKey = UQ.NameKey(self:GetUnitName(unitId))
        local objectiveKey = UQ.NameKey(objectiveName)
        if not unitKey or not objectiveKey then
            return
        end
        local objectives = links[unitKey]
        if not objectives then
            objectives = {}
            links[unitKey] = objectives
        end
        objectives[objectiveKey] = true
    end

    if type(relation.U) == "table" then
        local _, unitId
        for _, unitId in pairs(relation.U) do
            LinkUnit(unitId, self:GetUnitName(unitId))
        end
    end

    if type(relation.I) == "table" then
        local _, itemId
        for _, itemId in pairs(relation.I) do
            local item = self:GetItem(itemId)
            local itemName = self:GetItemName(itemId)
            if type(item) == "table" and type(item.U) == "table" then
                local unitId
                for unitId in pairs(item.U) do
                    LinkUnit(unitId, itemName)
                end
            end
        end
    end

    return links
end

function Database:GetUnit(unitId)
    if not db or type(db.units) ~= "table" then
        return nil
    end
    return db.units[unitId]
end

function Database:GetUnitName(unitId)
    if not db or type(db.units_enUS) ~= "table" then
        return nil
    end
    return db.units_enUS[unitId]
end

function Database:GetObject(objectId)
    if not db or type(db.objects) ~= "table" then
        return nil
    end
    return db.objects[objectId]
end

function Database:GetObjectName(objectId)
    if not db or type(db.objects_enUS) ~= "table" then
        return nil
    end
    return db.objects_enUS[objectId]
end

function Database:GetItem(itemId)
    if not db or type(db.items) ~= "table" then
        return nil
    end
    return db.items[itemId]
end

function Database:GetItemName(itemId)
    if not db or type(db.items_enUS) ~= "table" then
        return nil
    end
    return db.items_enUS[itemId]
end

-- The whole area-name table, for callers that need to build a reverse index.
-- Exposed here so nothing outside this file has to reach for the data global.
function Database:GetZoneNames()
    if not db or type(db.zones_enUS) ~= "table" then
        return nil
    end
    return db.zones_enUS
end

function Database:GetZoneName(zoneId)
    if not db or type(db.zones_enUS) ~= "table" then
        return nil
    end
    return db.zones_enUS[zoneId]
end

-- { parentZoneOrContinent, width, height, xOffset, yOffset } for placing a
-- sub-zone coordinate onto its parent map. Consumed by the map layer once map
-- identification is runtime-verified.
function Database:GetZoneTransform(zoneId)
    if not db or type(db.zones) ~= "table" then
        return nil
    end
    return db.zones[zoneId]
end

-- Zone width and height in yards, needed for minimap-relative distance work.
function Database:GetZoneYards(zoneId)
    if not db or type(db.minimap) ~= "table" then
        return nil
    end
    return db.minimap[zoneId]
end

-- Item-use objectives -------------------------------------------------------
-- A third kind of objective hides inside the `obj` relation. Besides "kill
-- this" (obj.U) and "loot that" (obj.I), some quests require an item to be
-- *used* on a fixed unit or object. `obj.IR` names the item; the separate
-- quests-itemreq table maps that item to what it is used on, encoding a game
-- object as a negative key and a creature as a positive one.
--
-- These targets have to be told apart from ordinary objective sources because
-- they are conditional: the step does not exist until the item is in the bag.
-- Marla's Last Wish (6395) is the reference case. Its obj.O names Marla's
-- Grave at 31.2/65.1 in Tirisfal, twenty yards from Novice Elreth, the NPC who
-- both starts and ends the quest -- so drawing it like any other objective put
-- a permanent objective area on top of Deathknell from the moment the quest
-- was accepted, pointing at a place the player cannot act on until Samuel's
-- Remains drop, and reading as if the turn-in itself were an objective.
--
-- Returns a list of { itemId = n, sourceType = "unit"|"object", sourceId = n }.
-- The list is empty for the 4227 of 4433 bundled quests with no obj.IR.
function Database:GetQuestItemUseTargets(questId)
    local targets = {}
    if not db or type(db["quests-itemreq"]) ~= "table" then
        return targets
    end
    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" or type(relation.IR) ~= "table" then
        return targets
    end

    local requirements = db["quests-itemreq"]
    local _, itemId
    for _, itemId in pairs(relation.IR) do
        local uses = type(itemId) == "number" and requirements[itemId]
        if type(uses) == "table" then
            local target
            for target in pairs(uses) do
                -- The sign is the type tag, so zero is meaningless here and is
                -- dropped rather than guessed at.
                if type(target) == "number" and target < 0 then
                    table.insert(targets, {
                        itemId = itemId,
                        sourceType = "object",
                        sourceId = -target,
                    })
                elseif type(target) == "number" and target > 0 then
                    table.insert(targets, {
                        itemId = itemId,
                        sourceType = "unit",
                        sourceId = target,
                    })
                end
            end
        end
    end

    return targets
end

-- Builds a bounded list of direct database coordinates for one active quest
-- in one area. Item objectives are expanded through their unit/object source
-- tables here so the map layer never depends on the generated data shapes.
-- Coordinates in child areas are deliberately excluded until transforms are
-- runtime-verified; this first map slice is current-zone-only.
--
-- Item-use targets (see GetQuestItemUseTargets) are excluded from the
-- objective pass entirely. They are not unconditional objective sources, and
-- the map layer adds them back through GetEntityLocations once it knows the
-- required item is carried.
function Database:GetQuestLocations(questId, isComplete, areaId, limit)
    if not db or type(questId) ~= "number" or type(areaId) ~= "number" then
        return {}
    end
    -- Written as a branch, not as `isComplete and finishers or objectives`.
    -- 174 of the 4433 bundled quests carry no `end` relation at all, 53 of
    -- them while still carrying `obj`, and the and/or idiom silently falls
    -- through to the second operand whenever the first is nil -- so asking
    -- one of those 53 for its turn-in point returned the creatures its
    -- objectives are killed on instead. "No turn-in location recorded" has to
    -- come back empty, not come back as something else entirely.
    local relation
    if isComplete then
        relation = self:GetQuestFinishers(questId)
    else
        relation = self:GetQuestObjectiveSources(questId)
    end
    if type(relation) ~= "table" then
        return {}
    end

    limit = type(limit) == "number" and limit or 200
    local locations = {}
    local visited = {}

    -- Targets of an item-use step, keyed the same way as `visited`. Seeding
    -- them as already-visited is what keeps Marla's Grave out of the obj.O
    -- pass without a second branch in every loop below.
    if not isComplete then
        local targets = self:GetQuestItemUseTargets(questId)
        local targetIndex = 1
        local targetTotal = table.getn(targets)
        while targetIndex <= targetTotal do
            local target = targets[targetIndex]
            visited[target.sourceType .. tostring(target.sourceId)] = true
            targetIndex = targetIndex + 1
        end
    end

    local function AppendEntity(sourceType, sourceId, record)
        if table.getn(locations) >= limit or type(sourceId) ~= "number" or type(record) ~= "table" then
            return
        end
        local visitKey = sourceType .. tostring(sourceId)
        if visited[visitKey] then
            return
        end
        visited[visitKey] = true
        local coords = record.coords
        if type(coords) ~= "table" then
            return
        end
        local index = 1
        local total = table.getn(coords)
        while index <= total and table.getn(locations) < limit do
            local coordinate = coords[index]
            if type(coordinate) == "table" and type(coordinate[1]) == "number"
                and type(coordinate[2]) == "number" and coordinate[3] == areaId then
                table.insert(locations, {
                    x = coordinate[1],
                    y = coordinate[2],
                    areaId = coordinate[3],
                    sourceType = sourceType,
                    sourceId = sourceId,
                })
            end
            index = index + 1
        end
    end

    local function AppendRelationSources(sourceType, sources)
        if type(sources) ~= "table" then
            return
        end
        local sourceId
        for _, sourceId in pairs(sources) do
            if sourceType == "unit" then
                AppendEntity(sourceType, sourceId, self:GetUnit(sourceId))
            else
                AppendEntity(sourceType, sourceId, self:GetObject(sourceId))
            end
        end
    end

    AppendRelationSources("unit", relation.U)
    AppendRelationSources("object", relation.O)

    if type(relation.I) == "table" then
        local _, itemId
        for _, itemId in pairs(relation.I) do
            if table.getn(locations) >= limit then
                break
            end
            local item = self:GetItem(itemId)
            if type(item) == "table" then
                if type(item.U) == "table" then
                    local unitId
                    for unitId in pairs(item.U) do
                        AppendEntity("unit", unitId, self:GetUnit(unitId))
                    end
                end
                if type(item.O) == "table" then
                    local objectId
                    for objectId in pairs(item.O) do
                        AppendEntity("object", objectId, self:GetObject(objectId))
                    end
                end
            end
        end
    end

    return locations
end

-- Coordinates for one named entity in one area, in the same row shape
-- GetQuestLocations produces. Used by the map layer to place an item-use
-- target once it has established the required item is carried, which is a
-- decision about live player state and so cannot be made in here.
function Database:GetEntityLocations(sourceType, sourceId, areaId, limit)
    local locations = {}
    if not db or type(sourceId) ~= "number" or type(areaId) ~= "number" then
        return locations
    end

    local record
    if sourceType == "unit" then
        record = self:GetUnit(sourceId)
    elseif sourceType == "object" then
        record = self:GetObject(sourceId)
    end
    if type(record) ~= "table" or type(record.coords) ~= "table" then
        return locations
    end

    limit = type(limit) == "number" and limit or 200
    local coords = record.coords
    local index = 1
    local total = table.getn(coords)
    while index <= total and table.getn(locations) < limit do
        local coordinate = coords[index]
        if type(coordinate) == "table" and type(coordinate[1]) == "number"
            and type(coordinate[2]) == "number" and coordinate[3] == areaId then
            table.insert(locations, {
                x = coordinate[1],
                y = coordinate[2],
                areaId = coordinate[3],
                sourceType = sourceType,
                sourceId = sourceId,
            })
        end
        index = index + 1
    end

    return locations
end

-- Title index ---------------------------------------------------------------
-- Quest titles are not unique in the source data, so the index maps a
-- normalized title to a list of candidate quest IDs. Disambiguation is the
-- matcher's job.

function Database:IndexChunk()
    if not self.available or self.indexReady then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("database.index")
        end
        return
    end

    if not self.titleIndex then
        self.titleIndex = {}
    end

    local texts = db.quests_enUS
    if type(texts) ~= "table" then
        self.indexReady = true
        return
    end

    local processed = 0
    while processed < INDEX_CHUNK do
        local questId, record = next(texts, indexCursor)
        if questId == nil then
            self.indexReady = true
            UQ:Debug("title index complete: " .. self.indexedCount .. " quests")
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Unschedule("database.index")
            end
            return
        end
        indexCursor = questId

        if type(record) == "table" then
            local key = UQ.NameKey(record.T)
            if key then
                local bucket = self.titleIndex[key]
                if not bucket then
                    bucket = {}
                    self.titleIndex[key] = bucket
                end
                table.insert(bucket, questId)
                self.indexedCount = self.indexedCount + 1
            end
        end

        processed = processed + 1
    end
end

function Database:IsIndexReady()
    return self.indexReady
end

-- Giver index -----------------------------------------------------------
-- One quest giver (a unit or object) can start several quests, so the index
-- is keyed by giver, not by quest: a giver is only looked up in coords once,
-- the first time it is met, and every quest it starts is appended to its list.

local function GiverKey(sourceType, sourceId)
    return sourceType .. ":" .. tostring(sourceId)
end

function Database:IndexOneGiver(questId, sourceType, sourceId)
    if type(sourceId) ~= "number" then
        return
    end
    local key = GiverKey(sourceType, sourceId)
    local giver = self.giverIndex[key]
    if not giver then
        giver = { sourceType = sourceType, sourceId = sourceId, questIds = {} }
        self.giverIndex[key] = giver

        local entity = sourceType == "unit" and self:GetUnit(sourceId) or self:GetObject(sourceId)
        local coords = entity and entity.coords
        if type(coords) == "table" then
            local index = 1
            local total = table.getn(coords)
            while index <= total do
                local coordinate = coords[index]
                if type(coordinate) == "table" and type(coordinate[3]) == "number" then
                    local bucket = self.areaGiverIndex[coordinate[3]]
                    if not bucket then
                        bucket = {}
                        self.areaGiverIndex[coordinate[3]] = bucket
                    end
                    table.insert(bucket, key)
                end
                index = index + 1
            end
        end
    end
    table.insert(giver.questIds, questId)
end

function Database:IndexGiverChunk()
    if not self.available or self.giverIndexReady then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("database.giverindex")
        end
        return
    end

    if not self.giverIndex then
        self.giverIndex = {}
        self.areaGiverIndex = {}
    end

    local quests = db.quests
    if type(quests) ~= "table" then
        self.giverIndexReady = true
        return
    end

    local processed = 0
    while processed < INDEX_CHUNK do
        local questId, record = next(quests, giverIndexCursor)
        if questId == nil then
            self.giverIndexReady = true
            UQ:Debug("giver index complete")
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Unschedule("database.giverindex")
            end
            return
        end
        giverIndexCursor = questId

        if type(record) == "table" and type(record["start"]) == "table" then
            local relation = record["start"]
            if type(relation.U) == "table" then
                local _, sourceId
                for _, sourceId in pairs(relation.U) do
                    self:IndexOneGiver(questId, "unit", sourceId)
                end
            end
            if type(relation.O) == "table" then
                local _, sourceId
                for _, sourceId in pairs(relation.O) do
                    self:IndexOneGiver(questId, "object", sourceId)
                end
            end
        end

        processed = processed + 1
    end
end

function Database:IsGiverIndexReady()
    return self.giverIndexReady
end

-- Bounded list of quest givers with a direct coordinate in areaId. Each entry
-- is { x, y, areaId, sourceType, sourceId, questIds }; questIds is the giver's
-- own list and must be treated as read-only by callers.
function Database:GetAreaQuestGivers(areaId, limit)
    if not self.giverIndex or not self.areaGiverIndex or type(areaId) ~= "number" then
        return {}
    end
    local keys = self.areaGiverIndex[areaId]
    if not keys then
        return {}
    end

    limit = type(limit) == "number" and limit or 200
    local locations = {}
    local keyIndex = 1
    local keyTotal = table.getn(keys)
    while keyIndex <= keyTotal and table.getn(locations) < limit do
        local giver = self.giverIndex[keys[keyIndex]]
        if giver then
            local entity = giver.sourceType == "unit" and self:GetUnit(giver.sourceId)
                or self:GetObject(giver.sourceId)
            local coords = entity and entity.coords
            if type(coords) == "table" then
                local coordIndex = 1
                local coordTotal = table.getn(coords)
                while coordIndex <= coordTotal and table.getn(locations) < limit do
                    local coordinate = coords[coordIndex]
                    if type(coordinate) == "table" and coordinate[3] == areaId
                        and type(coordinate[1]) == "number" and type(coordinate[2]) == "number" then
                        table.insert(locations, {
                            x = coordinate[1],
                            y = coordinate[2],
                            areaId = areaId,
                            sourceType = giver.sourceType,
                            sourceId = giver.sourceId,
                            questIds = giver.questIds,
                        })
                    end
                    coordIndex = coordIndex + 1
                end
            end
        end
        keyIndex = keyIndex + 1
    end
    return locations
end

-- Returns the list of quest IDs whose title normalizes to key, or nil.
function Database:FindQuestIdsByTitleKey(key)
    if not self.titleIndex or not key then
        return nil
    end
    return self.titleIndex[key]
end

function Database:GetStatus()
    if not self.available then
        return "missing"
    end
    if not self.indexReady then
        return "indexing"
    end
    return "ready"
end
